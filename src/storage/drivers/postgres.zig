//! PostgreSQL backend driver (Phase 4) — adapts pg.zig onto the storage `Backend`
//! SPI (`../backend.zig`). Storage code is written for SQLite's `?` placeholders +
//! typed column getters; this driver translates: `?`→`$N` at prepare time
//! (`postgres_dialect.renumberPlaceholders`), sequential `stmt.bind`, and read-side
//! coercing getters that dispatch on the column OID so a `getInt64`/`getInt`/`getText`
//! works regardless of the exact PG width (int2/int4/int8/text).
//!
//! Ownership rules (verified against pg.zig, see memory pgzig-api-verified):
//!  - `stmt.execute()` transfers the Stmt's arena to the returned `*Result`; after a
//!    successful execute we free the Result, never the Stmt.
//!  - a Result must be drained (rows read to null, or `drain()`) before the connection
//!    is reused, else the next op fails with UnexpectedDBMessage.
const std = @import("std");
const pg = @import("pg");
const backend = @import("../backend.zig");
const pg_dialect_mod = @import("postgres_dialect.zig");

const Statement = backend.Statement;
const StepOutcome = backend.StepOutcome;
const ColumnInfo = backend.ColumnInfo;

// Well-known PostgreSQL type OIDs (pg_type.oid) used by the coercing getters.
const OID = struct {
    const bool_: i32 = 16;
    const int8: i32 = 20;
    const int2: i32 = 21;
    const int4: i32 = 23;
    const text: i32 = 25;
    const varchar: i32 = 1043;
    const bpchar: i32 = 1042;
    const name: i32 = 19;
    const bytea: i32 = 17;
    const json: i32 = 114;
    const jsonb: i32 = 3802;
};

// ── Connection ──────────────────────────────────────────────────────────────

pub const ConnectOpts = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 5432,
    username: []const u8 = "postgres",
    password: ?[]const u8 = null,
    database: []const u8,
    pool_size: u16 = 1,
};

const PgConn = struct {
    allocator: std.mem.Allocator,
    pool: *pg.Pool,
    conn: *pg.Conn, // single writer connection, pinned for this Backend's lifetime
    // Owned copies of the connection params. pg.Pool only copies the opts STRUCT, not the
    // strings (it dupes host only when TLS is on), so it borrows these for its lifetime —
    // we own them here and free them in close() after the pool is torn down. This makes
    // the Backend self-contained (independent of the caller's ConnectOpts/URL lifetime).
    host: []u8,
    username: []u8,
    password: ?[]u8,
    database: []u8,
};

/// Parse `postgres://[user[:password]@]host[:port]/database[?...]` into ConnectOpts.
/// The returned string fields BORROW from `url` (open() dupes them into the Backend),
/// so `url` need only outlive this call, not the Backend. Percent-encoding is not
/// decoded and IPv6 host literals are unsupported — neither appears in our setups.
pub fn parseUrl(url: []const u8) !ConnectOpts {
    var rest = url;
    if (std.mem.startsWith(u8, rest, "postgresql://")) {
        rest = rest["postgresql://".len..];
    } else if (std.mem.startsWith(u8, rest, "postgres://")) {
        rest = rest["postgres://".len..];
    } else {
        return error.InvalidPostgresUrl;
    }

    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.MissingDatabase;
    const authority = rest[0..slash];
    var db = rest[slash + 1 ..];
    if (std.mem.indexOfScalar(u8, db, '?')) |q| db = db[0..q];
    if (db.len == 0) return error.MissingDatabase;

    var opts = ConnectOpts{ .database = db };

    var hostport = authority;
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| {
        const userinfo = authority[0..at];
        hostport = authority[at + 1 ..];
        if (userinfo.len > 0) {
            if (std.mem.indexOfScalar(u8, userinfo, ':')) |colon| {
                opts.username = userinfo[0..colon];
                opts.password = userinfo[colon + 1 ..];
            } else {
                opts.username = userinfo;
            }
        }
    }
    if (hostport.len > 0) {
        if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |colon| {
            opts.host = hostport[0..colon];
            opts.port = std.fmt.parseInt(u16, hostport[colon + 1 ..], 10) catch return error.InvalidPort;
        } else {
            opts.host = hostport;
        }
    }
    return opts;
}

inline fn asConn(ctx: *anyopaque) *PgConn {
    return @ptrCast(@alignCast(ctx));
}

/// Open a PostgreSQL backend: one pinned connection from a size-1 pool. Caller owns
/// the returned `Backend` and must `close` it via `vtable.close`.
pub fn open(allocator: std.mem.Allocator, opts: ConnectOpts) !backend.Backend {
    // Own the connection params (pg.Pool borrows them) — freed in close() after teardown.
    const host = try allocator.dupe(u8, opts.host);
    errdefer allocator.free(host);
    const username = try allocator.dupe(u8, opts.username);
    errdefer allocator.free(username);
    const password: ?[]u8 = if (opts.password) |p| try allocator.dupe(u8, p) else null;
    errdefer if (password) |p| allocator.free(p);
    const database = try allocator.dupe(u8, opts.database);
    errdefer allocator.free(database);

    const pool = try pg.Pool.init(allocator, .{
        .size = opts.pool_size,
        .connect = .{ .host = host, .port = opts.port },
        .auth = .{ .username = username, .password = password, .database = database },
    });
    errdefer pool.deinit();

    const conn = try pool.acquire();
    errdefer pool.release(conn);

    const self = try allocator.create(PgConn);
    self.* = .{
        .allocator = allocator,
        .pool = pool,
        .conn = conn,
        .host = host,
        .username = username,
        .password = password,
        .database = database,
    };

    return backend.Backend{ .ptr = self, .vtable = &vtable, .dialect = &pg_dialect_mod.pg_dialect };
}

fn close(ctx: *anyopaque) void {
    const self = asConn(ctx);
    self.pool.release(self.conn);
    self.pool.deinit(); // tears down all connections — params no longer referenced after this
    self.allocator.free(self.host);
    self.allocator.free(self.username);
    if (self.password) |p| self.allocator.free(p);
    self.allocator.free(self.database);
    self.allocator.destroy(self);
}

fn execRaw(ctx: *anyopaque, sql: []const u8) anyerror!void {
    const self = asConn(ctx);
    // Parameterless DDL/DML; the simple-query protocol handles multi-statement input
    // and drains itself.
    _ = self.conn.exec(sql, .{}) catch |err| {
        std.log.err("postgres execRaw failed: {}\nSQL: {s}", .{ err, sql });
        return error.ExecFailed;
    };
}

fn begin(ctx: *anyopaque, mode: backend.TxMode) anyerror!void {
    _ = mode; // PG locks lazily; isolation handles serialization (no BEGIN IMMEDIATE)
    try asConn(ctx).conn.begin();
}

fn commit(ctx: *anyopaque) anyerror!void {
    try asConn(ctx).conn.commit();
}

fn rollback(ctx: *anyopaque) void {
    asConn(ctx).conn.rollback() catch |err| {
        std.log.err("CRITICAL: postgres rollback failed: {}", .{err});
    };
}

fn lastInsertId(ctx: *anyopaque) i64 {
    _ = ctx;
    // PostgreSQL has no last_insert_rowid; callers use RETURNING instead (the dialect
    // reports caps.returning = true). Never expected to be called on this backend.
    std.log.warn("postgres lastInsertId() called — use RETURNING instead", .{});
    return -1;
}

fn introspectColumns(ctx: *anyopaque, allocator: std.mem.Allocator, table: []const u8) anyerror![]ColumnInfo {
    const self = asConn(ctx);
    // information_schema columns are domain types (sql_identifier/character_data over
    // varchar; cardinal_number over int4). pg.zig's native row.get is OID-strict, so
    // cast to plain text/bigint to match the []const u8 / i64 decoders exactly.
    const sql =
        \\SELECT c.column_name::text, c.data_type::text,
        \\       COALESCE((SELECT kcu.ordinal_position FROM information_schema.table_constraints tc
        \\                 JOIN information_schema.key_column_usage kcu
        \\                   ON kcu.constraint_name = tc.constraint_name
        \\                 WHERE tc.table_name = c.table_name AND tc.constraint_type = 'PRIMARY KEY'
        \\                   AND kcu.column_name = c.column_name), 0)::bigint
        \\FROM information_schema.columns c
        \\WHERE c.table_name = $1 AND c.table_schema = 'public'
        \\ORDER BY c.ordinal_position
    ;
    var result = try self.conn.query(sql, .{table});
    defer result.deinit();

    var list: std.ArrayList(ColumnInfo) = .{};
    errdefer {
        for (list.items) |col| {
            allocator.free(col.name);
            allocator.free(col.sql_type);
        }
        list.deinit(allocator);
    }
    while (try result.next()) |row| {
        const name = try allocator.dupe(u8, try row.get([]const u8, 0));
        errdefer allocator.free(name);
        const sql_type = try allocator.dupe(u8, try row.get([]const u8, 1));
        errdefer allocator.free(sql_type);
        try list.append(allocator, .{ .name = name, .sql_type = sql_type, .pk_pos = try row.get(i64, 2) });
    }
    return list.toOwnedSlice(allocator);
}

fn prepare(ctx: *anyopaque, sql: []const u8, cached: bool) anyerror!Statement {
    _ = cached; // PG re-prepares each call (no client-side reuse); server cache is future work.
    const self = asConn(ctx);

    const renumbered = try pg_dialect_mod.renumberPlaceholders(self.allocator, sql);
    errdefer self.allocator.free(renumbered);

    var stmt = self.conn.prepare(renumbered) catch |err| {
        std.log.err("postgres prepare failed: {}\nSQL: {s}", .{ err, renumbered });
        return error.PrepareFailed;
    };
    errdefer stmt.deinit();

    const ps = try self.allocator.create(PgStmt);
    ps.* = .{ .allocator = self.allocator, .sql = renumbered, .stmt = stmt };
    return Statement{ .ctx = ps, .vtable = &stmt_vtable, .allocator = self.allocator };
}

pub const vtable = backend.VTable{
    .close = close,
    .execRaw = execRaw,
    .prepare = prepare,
    .begin = begin,
    .commit = commit,
    .rollback = rollback,
    .lastInsertId = lastInsertId,
    .introspectColumns = introspectColumns,
};

// ── Statement ─────────────────────────────────────────────────────────────────

// A single materialized column value. Decoded eagerly at execute() time using pg.zig's
// own getters (so we never re-implement the binary wire format), then owned by the
// statement's allocator. Materializing the whole result set up front is what lets a
// Statement release the connection immediately — the storage/indexer layer routinely
// iterates one query while issuing others, which a single pinned PG connection cannot do
// with a live server-side cursor (SQLite allows many concurrent live statements; PG does
// not). See finalize/doExecute.
const MatValue = union(enum) {
    null,
    int: i64,
    text: []u8, // owned
};
const MatRow = []MatValue;

const PgStmt = struct {
    allocator: std.mem.Allocator,
    sql: []u8, // owned (renumbered)
    stmt: pg.Stmt,
    executed: bool = false,
    // Materialized rows (owned). `cursor` is the next row step() will return; `cur` is
    // the row most recently returned (what the column getters read from).
    rows: []MatRow = &.{},
    cursor: usize = 0,
    cur: ?MatRow = null,
    last_err: [256]u8 = undefined,
    last_err_len: usize = 0,
};

fn freeRows(allocator: std.mem.Allocator, rows: []MatRow) void {
    for (rows) |row| {
        for (row) |v| switch (v) {
            .text => |t| allocator.free(t),
            else => {},
        };
        allocator.free(row);
    }
    allocator.free(rows);
}

inline fn asStmt(ctx: *anyopaque) *PgStmt {
    return @ptrCast(@alignCast(ctx));
}

fn recordErr(self: *PgStmt, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.bufPrint(&self.last_err, fmt, args) catch "postgres error";
    self.last_err_len = msg.len;
}

fn bindText(ctx: *anyopaque, idx: c_int, ptr: [*]const u8, len: usize) bool {
    _ = idx; // pg.Stmt binds sequentially; our Statement binds in order
    const self = asStmt(ctx);
    self.stmt.bind(ptr[0..len]) catch |err| {
        recordErr(self, "bindText: {}", .{err});
        return false;
    };
    return true;
}

fn bindInt64(ctx: *anyopaque, idx: c_int, value: i64) bool {
    _ = idx;
    const self = asStmt(ctx);
    self.stmt.bind(value) catch |err| {
        recordErr(self, "bindInt64: {}", .{err});
        return false;
    };
    return true;
}

fn bindInt(ctx: *anyopaque, idx: c_int, value: i32) bool {
    _ = idx;
    const self = asStmt(ctx);
    self.stmt.bind(value) catch |err| {
        recordErr(self, "bindInt: {}", .{err});
        return false;
    };
    return true;
}

fn bindNull(ctx: *anyopaque, idx: c_int) bool {
    _ = idx;
    const self = asStmt(ctx);
    self.stmt.bind(null) catch |err| {
        recordErr(self, "bindNull: {}", .{err});
        return false;
    };
    return true;
}

fn materializeValue(allocator: std.mem.Allocator, row: pg.Row, c: usize) !MatValue {
    if (row.values[c].is_null) return .null;
    // Integer-class OIDs decode through pg.zig's own getters (no binary-format
    // re-implementation); everything else (text/varchar/bpchar/name/json/bytea) is the
    // raw bytes, which for text formats is exactly the string we want.
    return switch (row.oids[c]) {
        OID.int2 => .{ .int = @intCast(row.get(i16, c) catch 0) },
        OID.int4 => .{ .int = @intCast(row.get(i32, c) catch 0) },
        OID.int8 => .{ .int = row.get(i64, c) catch 0 },
        OID.bool_ => .{ .int = @intFromBool(row.get(bool, c) catch false) },
        else => .{ .text = try allocator.dupe(u8, row.values[c].data) },
    };
}

fn materializeRow(allocator: std.mem.Allocator, row: pg.Row) !MatRow {
    const n = row.values.len;
    const out = try allocator.alloc(MatValue, n);
    errdefer allocator.free(out);
    var i: usize = 0;
    errdefer for (out[0..i]) |v| switch (v) {
        .text => |t| allocator.free(t),
        else => {},
    };
    while (i < n) : (i += 1) out[i] = try materializeValue(allocator, row, i);
    return out;
}

fn doExecute(self: *PgStmt) !void {
    if (self.executed) return;
    // Mark executed only AFTER a successful execute(): on error the Stmt arena is NOT
    // transferred to a Result (pg.zig contract), so it must be freed via stmt.deinit() in
    // finalize — which only happens on the executed==false branch. Setting the flag first
    // would route a failed execute into the freeRows branch and leak the arena.
    const result = try self.stmt.execute();
    self.executed = true;
    // Copy every row into owned memory, then release the result — which returns the
    // pinned connection to idle so the next statement can run. This is what makes the
    // "iterate query A while issuing query B per row" pattern (pervasive in the storage
    // layer, e.g. backfillFromExistingData) work on a single-connection PG backend.
    defer result.deinit();
    var list: std.ArrayList(MatRow) = .{};
    errdefer {
        for (list.items) |row| {
            for (row) |v| switch (v) {
                .text => |t| self.allocator.free(t),
                else => {},
            };
            self.allocator.free(row);
        }
        list.deinit(self.allocator);
    }
    while (try result.next()) |row| {
        const mr = try materializeRow(self.allocator, row);
        errdefer {
            for (mr) |v| switch (v) {
                .text => |t| self.allocator.free(t),
                else => {},
            };
            self.allocator.free(mr);
        }
        try list.append(self.allocator, mr);
    }
    self.rows = try list.toOwnedSlice(self.allocator);
}

fn exec(ctx: *anyopaque) bool {
    const self = asStmt(ctx);
    doExecute(self) catch |err| {
        recordErr(self, "execute: {}", .{err});
        return false;
    };
    return true; // materialized (0 rows for INSERT/UPDATE/DDL); connection already idle
}

fn step(ctx: *anyopaque) StepOutcome {
    const self = asStmt(ctx);
    doExecute(self) catch |err| {
        recordErr(self, "execute: {}", .{err});
        return .failed;
    };
    if (self.cursor >= self.rows.len) {
        self.cur = null;
        return .done;
    }
    self.cur = self.rows[self.cursor];
    self.cursor += 1;
    return .row;
}

fn changes(ctx: *anyopaque) u32 {
    _ = ctx;
    // TODO(phase4): surface CommandComplete affected-row count; not yet exposed by the
    // Result we hold. Callers that gate on changes() are validated in the A/B lane.
    return 0;
}

fn columnIsNull(ctx: *anyopaque, col: c_int) bool {
    const self = asStmt(ctx);
    const row = self.cur orelse return true;
    return switch (row[@intCast(col)]) {
        .null => true,
        else => false,
    };
}

fn columnText(ctx: *anyopaque, col: c_int) ?[]const u8 {
    const self = asStmt(ctx);
    const row = self.cur orelse return null;
    return switch (row[@intCast(col)]) {
        .text => |t| t,
        else => null,
    };
}

/// Read an integer column (already coerced to i64 at materialize time per the column OID).
fn columnInt64(ctx: *anyopaque, col: c_int) i64 {
    const self = asStmt(ctx);
    const row = self.cur orelse return 0;
    return switch (row[@intCast(col)]) {
        .int => |n| n,
        else => 0,
    };
}

fn columnInt(ctx: *anyopaque, col: c_int) i32 {
    return @intCast(columnInt64(ctx, col));
}

fn lastError(ctx: *anyopaque) [:0]const u8 {
    const self = asStmt(ctx);
    if (self.last_err_len == 0) return "";
    // The buffer isn't sentinel-terminated; return a fixed message slice instead of
    // risking an unterminated [:0] cast. Detailed errors are already logged.
    return "postgres statement error";
}

fn reset(ctx: *anyopaque) void {
    _ = ctx; // PG statements are not reused (prepare re-runs each call); nothing to reset.
}

fn finalize(ctx: *anyopaque) void {
    const self = asStmt(ctx);
    if (self.executed) {
        // The result set was materialized + the pg.Result (and its arena) released back
        // in doExecute; only the owned row buffers remain to free here.
        freeRows(self.allocator, self.rows);
    } else {
        self.stmt.deinit(); // never executed (e.g. bind error) — free the prepared stmt
    }
    self.allocator.free(self.sql);
    self.allocator.destroy(self);
}

pub const stmt_vtable = backend.StmtVTable{
    .bindText = bindText,
    .bindInt64 = bindInt64,
    .bindInt = bindInt,
    .bindNull = bindNull,
    .exec = exec,
    .step = step,
    .changes = changes,
    .columnIsNull = columnIsNull,
    .columnText = columnText,
    .columnInt64 = columnInt64,
    .columnInt = columnInt,
    .lastError = lastError,
    .reset = reset,
    .finalize = finalize,
};
