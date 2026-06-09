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
};

inline fn asConn(ctx: *anyopaque) *PgConn {
    return @ptrCast(@alignCast(ctx));
}

/// Open a PostgreSQL backend: one pinned connection from a size-1 pool. Caller owns
/// the returned `Backend` and must `close` it via `vtable.close`.
pub fn open(allocator: std.mem.Allocator, opts: ConnectOpts) !backend.Backend {
    const pool = try pg.Pool.init(allocator, .{
        .size = opts.pool_size,
        .connect = .{ .host = opts.host, .port = opts.port },
        .auth = .{ .username = opts.username, .password = opts.password, .database = opts.database },
    });
    errdefer pool.deinit();

    const conn = try pool.acquire();
    errdefer pool.release(conn);

    const self = try allocator.create(PgConn);
    self.* = .{ .allocator = allocator, .pool = pool, .conn = conn };

    return backend.Backend{ .ptr = self, .vtable = &vtable, .dialect = &pg_dialect_mod.pg_dialect };
}

fn close(ctx: *anyopaque) void {
    const self = asConn(ctx);
    self.pool.release(self.conn);
    self.pool.deinit();
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
    const sql =
        \\SELECT c.column_name, c.data_type,
        \\       COALESCE((SELECT kcu.ordinal_position FROM information_schema.table_constraints tc
        \\                 JOIN information_schema.key_column_usage kcu
        \\                   ON kcu.constraint_name = tc.constraint_name
        \\                 WHERE tc.table_name = c.table_name AND tc.constraint_type = 'PRIMARY KEY'
        \\                   AND kcu.column_name = c.column_name), 0)
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

const PgStmt = struct {
    allocator: std.mem.Allocator,
    sql: []u8, // owned (renumbered)
    stmt: pg.Stmt,
    executed: bool = false,
    result: ?*pg.Result = null,
    row: ?pg.Row = null,
    last_err: [256]u8 = undefined,
    last_err_len: usize = 0,
};

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

fn doExecute(self: *PgStmt) !void {
    if (self.executed) return;
    self.result = try self.stmt.execute();
    self.executed = true;
}

fn exec(ctx: *anyopaque) bool {
    const self = asStmt(ctx);
    doExecute(self) catch |err| {
        recordErr(self, "execute: {}", .{err});
        return false;
    };
    // No rows to read; drain so the connection can be reused.
    if (self.result) |res| res.drain() catch |err| {
        recordErr(self, "drain: {}", .{err});
        return false;
    };
    return true;
}

fn step(ctx: *anyopaque) StepOutcome {
    const self = asStmt(ctx);
    doExecute(self) catch |err| {
        recordErr(self, "execute: {}", .{err});
        return .failed;
    };
    const res = self.result orelse return .failed;
    self.row = res.next() catch |err| {
        recordErr(self, "next: {}", .{err});
        return .failed;
    };
    return if (self.row == null) .done else .row;
}

fn changes(ctx: *anyopaque) u32 {
    _ = ctx;
    // TODO(phase4): surface CommandComplete affected-row count; not yet exposed by the
    // Result we hold. Callers that gate on changes() are validated in the A/B lane.
    return 0;
}

fn columnIsNull(ctx: *anyopaque, col: c_int) bool {
    const self = asStmt(ctx);
    const row = self.row orelse return true;
    return row.values[@intCast(col)].is_null;
}

fn columnText(ctx: *anyopaque, col: c_int) ?[]const u8 {
    const self = asStmt(ctx);
    const row = self.row orelse return null;
    const c: usize = @intCast(col);
    if (row.values[c].is_null) return null;
    // Text-typed columns (incl. our hex hash/address TEXT) decode straight to the bytes.
    return row.get([]const u8, c) catch null;
}

/// Read an integer column regardless of its PG width (coercing getter).
fn columnInt64(ctx: *anyopaque, col: c_int) i64 {
    const self = asStmt(ctx);
    const row = self.row orelse return 0;
    const c: usize = @intCast(col);
    if (row.values[c].is_null) return 0;
    return switch (row.oids[c]) {
        OID.int2 => @intCast(row.get(i16, c) catch return 0),
        OID.int4 => @intCast(row.get(i32, c) catch return 0),
        OID.int8 => row.get(i64, c) catch 0,
        OID.bool_ => @intFromBool(row.get(bool, c) catch return 0),
        else => row.get(i64, c) catch 0,
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
        if (self.result) |res| {
            // Drain any rows the caller didn't iterate so the connection returns to
            // idle (a no-op if already exhausted); deinit then frees the arena that
            // execute() transferred to the Result.
            res.drain() catch {};
            res.deinit();
        }
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
