//! PostgreSQL backend driver (Phase 4) — adapts pg.zig onto the storage `Backend`
//! SPI (`../backend.zig`). Storage code is written for SQLite's `?` placeholders +
//! typed column getters; this driver translates: `?`→`$N` at prepare time
//! (`postgres_dialect.renumberPlaceholders`), sequential `stmt.bind`, and read-side
//! coercing getters that dispatch on the column OID so a `getInt64`/`getInt`/`getText`
//! works regardless of the exact PG width (int2/int4/int8/text).
//!
//! Ownership rules (verified against pg.zig master a4e1264):
//!  - `stmt.execute()` transfers the Stmt's arena to the returned `*Result`; after a
//!    successful execute we free the Result, never the Stmt.
//!  - a Result must be drained (rows read to null, or `drain()`) before the connection
//!    is reused, else the next op fails with UnexpectedDBMessage.
//!  - `pg.Pool.init(io, ...)` dupes all connection strings into its own arena, and its
//!    sockets + reconnector run on the passed `Io` — the Backend owns a private
//!    `std.Io.Threaded` that must outlive `pool.deinit()`.
const std = @import("std");
const zsys = @import("../../utils/system.zig");
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

/// How to negotiate TLS with the server, derived from the URL `sslmode` (libpq
/// names). `.require` encrypts without certificate verification; `.verify_full`
/// verifies the server cert against the system CA bundle (ca-certificates).
/// TLS only actually happens when the build links OpenSSL (`zig build -Dpg-tls=true`),
/// which managed Postgres (e.g. Neon) requires; a plain build leaves it plaintext.
pub const TlsMode = enum { off, require, verify_full };

/// Map a URL `sslmode` value to a TlsMode. Absent/`disable`/`allow`/`prefer` → off
/// (suits a local non-TLS Postgres); `require` → encrypt only; `verify-ca`/
/// `verify-full` → verify against system CAs. An unrecognized-but-present value
/// fails safe to `.require` (encrypt rather than silently fall back to plaintext).
pub fn tlsModeFromSslmode(sslmode: ?[]const u8) TlsMode {
    const m = sslmode orelse return .off;
    if (std.ascii.eqlIgnoreCase(m, "disable") or std.ascii.eqlIgnoreCase(m, "allow") or std.ascii.eqlIgnoreCase(m, "prefer")) return .off;
    if (std.ascii.eqlIgnoreCase(m, "require")) return .require;
    if (std.ascii.eqlIgnoreCase(m, "verify-ca") or std.ascii.eqlIgnoreCase(m, "verify-full")) return .verify_full;
    return .require;
}

/// Find a `name=value` parameter in a `&`-separated URL query (value may be empty;
/// a bare `name` flag returns ""). Returns null if `query` is null or absent.
fn queryParam(query: ?[]const u8, name: []const u8) ?[]const u8 {
    const q = query orelse return null;
    var it = std.mem.splitScalar(u8, q, '&');
    while (it.next()) |pair| {
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
            if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
        } else if (std.mem.eql(u8, pair, name)) {
            return "";
        }
    }
    return null;
}

pub const ConnectOpts = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 5432,
    username: []const u8 = "postgres",
    password: ?[]const u8 = null,
    database: []const u8,
    pool_size: u16 = 1,
    /// TLS negotiation mode, parsed from the URL `sslmode` (default off).
    tls: TlsMode = .off,
};

const PgConn = struct {
    allocator: std.mem.Allocator,
    // The pool's sockets, timeouts and reconnector thread all run on this Io; it must
    // stay alive until pool.deinit() returns, so close() deinits it AFTER the pool.
    threaded: *std.Io.Threaded,
    pool: *pg.Pool,
    conn: *pg.Conn, // single writer connection, pinned for this Backend's lifetime
    stmt_cache: bool, // reuse server-side prepared statements (DATABASE_STMT_CACHE)
};

/// Parse `postgres://[user[:password]@]host[:port]/database[?...]` into ConnectOpts.
/// The returned string fields BORROW from `url` (pg.Pool.init dupes everything it
/// keeps into its own arena), so `url` need only outlive the open() call, not the
/// Backend. Percent-encoding is not decoded and IPv6 host literals are unsupported —
/// neither appears in our setups.
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
    const path_and_query = rest[slash + 1 ..];
    var db = path_and_query;
    var query: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, path_and_query, '?')) |q| {
        db = path_and_query[0..q];
        query = path_and_query[q + 1 ..];
    }
    if (db.len == 0) return error.MissingDatabase;

    var opts = ConnectOpts{ .database = db, .tls = tlsModeFromSslmode(queryParam(query, "sslmode")) };

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

/// Max pool-init attempts before giving up (covers a managed-PG cold start).
const max_connect_attempts: u32 = 5;

/// Open a PostgreSQL backend: one pinned connection from a size-1 pool. Caller owns
/// the returned `Backend` and must `close` it via `vtable.close`.
// Operational safeguard knob: bound every statement so a stuck query (lock wait, a
// dropped managed-PG connection, or a transaction-mode pooler stall) fails loudly
// instead of hanging forever. Seconds; default 120, 0 disables. Read here (not via
// Config) to keep it a self-contained driver concern with no config/test churn.
fn statementTimeoutSecs(allocator: std.mem.Allocator) u32 {
    const v = zsys.getEnvOwned(allocator, "DATABASE_STATEMENT_TIMEOUT") catch return 120;
    defer allocator.free(v);
    return std.fmt.parseInt(u32, std.mem.trim(u8, v, " \t\r\n"), 10) catch 120;
}

// Server-side prepared-statement reuse (see preparePossiblyCached). On by default; set
// DATABASE_STMT_CACHE=0/false/off to disable (kill-switch — it reaches into pinned
// pg.zig internals). Caps the per-connection cache so dynamically-built cached SQL can't
// grow it unbounded; beyond the cap, statements fall back to one-shot prepares.
const MAX_CACHED_STMTS: usize = 1024;

fn stmtCacheEnabled(allocator: std.mem.Allocator) bool {
    const v = zsys.getEnvOwned(allocator, "DATABASE_STMT_CACHE") catch return true;
    defer allocator.free(v);
    const t = std.mem.trim(u8, v, " \t\r\n");
    return !(std.ascii.eqlIgnoreCase(t, "0") or std.ascii.eqlIgnoreCase(t, "false") or std.ascii.eqlIgnoreCase(t, "off"));
}

// synchronous_commit knob: bulk indexing can trade per-commit WAL durability for speed on
// a remote/managed PG. DATABASE_SYNCHRONOUS_COMMIT = on|off|local|remote_write|remote_apply;
// unset/blank leaves the server default (on). Safe for an indexer — it re-syncs from the
// chain on restart, so a lost just-committed batch is simply re-indexed. Returns a static
// (canonical) slice so it needs no ownership; null = don't touch the setting.
fn synchronousCommitSetting(allocator: std.mem.Allocator) ?[]const u8 {
    const v = zsys.getEnvOwned(allocator, "DATABASE_SYNCHRONOUS_COMMIT") catch return null;
    defer allocator.free(v);
    const t = std.mem.trim(u8, v, " \t\r\n");
    if (t.len == 0) return null;
    const allowed = [_][]const u8{ "on", "off", "local", "remote_write", "remote_apply" };
    for (allowed) |a| {
        if (std.ascii.eqlIgnoreCase(t, a)) return a;
    }
    std.log.warn("postgres: ignoring invalid DATABASE_SYNCHRONOUS_COMMIT='{s}' (use on|off|local|remote_write|remote_apply)", .{t});
    return null;
}

pub fn open(allocator: std.mem.Allocator, opts: ConnectOpts) !backend.Backend {
    const threaded = try allocator.create(std.Io.Threaded);
    errdefer allocator.destroy(threaded);
    threaded.* = std.Io.Threaded.init(allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    // Map our backend-neutral TlsMode onto pg.zig's TLS union. `.verify_full = null`
    // verifies the server cert against the system CA bundle (ca-certificates). TLS
    // only takes effect when the build links OpenSSL (`-Dpg-tls=true`).
    const pg_tls: pg.Conn.Opts.TLS = switch (opts.tls) {
        .off => .off,
        .require => .require,
        .verify_full => .{ .verify_full = null },
    };

    // Managed Postgres (e.g. Neon) suspends idle computes; the first connect after
    // idle can take a few seconds or transiently fail while the compute wakes. Retry
    // the pool init with exponential backoff (0.5s,1s,2s,4s → ~7.5s) before failing.
    var attempt: u32 = 1;
    const pool = while (true) : (attempt += 1) {
        const p = pg.Pool.init(io, allocator, .{
            .size = opts.pool_size,
            .connect = .{ .host = opts.host, .port = opts.port, .tls = pg_tls },
            .auth = .{ .username = opts.username, .password = opts.password, .database = opts.database },
        }) catch |err| {
            if (attempt >= max_connect_attempts) {
                std.log.err("postgres: connect failed after {d} attempts: {}", .{ attempt, err });
                return err;
            }
            const backoff_ms: u64 = @as(u64, 500) * (@as(u64, 1) << @intCast(attempt - 1));
            std.log.warn("postgres: connect attempt {d}/{d} failed ({}); retrying in {d}ms", .{ attempt, max_connect_attempts, err, backoff_ms });
            zsys.sleep(backoff_ms * std.time.ns_per_ms);
            continue;
        };
        break p;
    };
    errdefer pool.deinit();

    const conn = try pool.acquire();
    errdefer pool.release(conn);

    applySessionSettings(allocator, conn);

    const self = try allocator.create(PgConn);
    self.* = .{
        .allocator = allocator,
        .threaded = threaded,
        .pool = pool,
        .conn = conn,
        .stmt_cache = stmtCacheEnabled(allocator),
    };

    return backend.Backend{ .ptr = self, .vtable = &vtable, .dialect = &pg_dialect_mod.pg_dialect, .caps = capabilities };
}

pub const capabilities = backend.Capabilities{
    .placeholder = .dollar,
    .returning = true,
    .savepoints = true,
    .server_side_undo = true,
    .pooled = true,
};

/// Session GUCs applied to the pinned connection — at open() AND after every
/// reconnect (session settings die with the session; see the Neon lost-GUCs
/// incident). Best-effort: a failed SET must not block startup or recovery.
fn applySessionSettings(allocator: std.mem.Allocator, conn: *pg.Conn) void {
    // Bound statement runtime so a stuck query fails loudly (see statementTimeoutSecs).
    // Non-fatal: on a transaction-mode pooler a session SET may not persist — the real
    // fix there is a session/direct endpoint — but a failed SET must not block startup.
    const stmt_timeout_s = statementTimeoutSecs(allocator);
    if (stmt_timeout_s > 0) {
        var tbuf: [64]u8 = undefined;
        const tsql = std.fmt.bufPrint(&tbuf, "SET statement_timeout = {d}", .{@as(u64, stmt_timeout_s) * 1000}) catch unreachable;
        _ = conn.exec(tsql, .{}) catch |err| {
            std.log.warn("postgres: could not set statement_timeout ({d}s): {}", .{ stmt_timeout_s, err });
        };
    }

    // Optional durability/speed trade-off for bulk sync (see synchronousCommitSetting).
    if (synchronousCommitSetting(allocator)) |sc| {
        var scbuf: [64]u8 = undefined;
        const scsql = std.fmt.bufPrint(&scbuf, "SET synchronous_commit = {s}", .{sc}) catch unreachable;
        _ = conn.exec(scsql, .{}) catch |err| {
            std.log.warn("postgres: could not set synchronous_commit={s}: {}", .{ sc, err });
        };
    }
}

/// Transport-layer failures that mean the pinned connection's socket/TLS session
/// is dead (Neon idles out or restarts connections; networks blip). Server-side
/// SQL errors (error.PG) and everything else are NOT connection deaths.
fn isConnectionDead(err: anyerror) bool {
    return switch (err) {
        error.SSLWriteFailed,
        error.SSLReadFailed,
        error.WriteFailed,
        error.ReadFailed,
        error.BrokenPipe,
        error.ConnectionResetByPeer,
        error.ConnectionRefused,
        error.ConnectionTimedOut,
        error.EndOfStream,
        error.NotOpenForWriting,
        error.NotOpenForReading,
        => true,
        else => false,
    };
}

/// Replace the dead pinned connection with a fresh one. The statement that
/// observed the death still FAILS to its caller — the indexer's batch machinery
/// rolls back and retries the whole batch, which is the only correct recovery
/// (the dead session took any in-flight transaction with it; transparently
/// retrying a single statement would resume mid-batch outside a transaction).
/// Without this, every subsequent statement failed on the same corpse forever —
/// the observed staging SSLWriteFailed loop.
fn reviveConnection(self: *PgConn, err: anyerror) void {
    if (!isConnectionDead(err)) return;
    std.log.warn("postgres: pinned connection lost ({}); reconnecting", .{err});
    // Mark the corpse failed so pool.release destroys it and provisions a
    // replacement instead of returning it to the free list. Release BEFORE
    // acquire: the pool is size 1 (single pinned writer), so acquiring while
    // still holding the corpse would block on ourselves.
    self.conn._state = .fail;
    self.pool.release(self.conn);
    // The old conn is destroyed now — self.conn must not be used until
    // replaced. A single-writer indexer cannot make progress without a DB
    // connection, so wait as long as it takes (same philosophy as the RPC
    // outage absorber): the pool's background reconnector keeps provisioning,
    // and each failed acquire backs off before retrying.
    var attempt: u32 = 0;
    const fresh = while (true) {
        if (self.pool.acquire()) |c| break c else |aerr| {
            attempt += 1;
            const backoff_s: u64 = @min(60, @as(u64, 5) * attempt);
            std.log.warn("postgres: reconnect attempt {d} failed ({}); retrying in {d}s", .{ attempt, aerr, backoff_s });
            zsys.sleep(backoff_s * std.time.ns_per_s);
        }
    };
    applySessionSettings(self.allocator, fresh);
    self.conn = fresh;
    std.log.info("postgres: connection re-established", .{});
}

fn close(ctx: *anyopaque) void {
    const self = asConn(ctx);
    self.pool.release(self.conn);
    self.pool.deinit(); // joins the reconnector + closes sockets — still needs the Io alive
    self.threaded.deinit();
    self.allocator.destroy(self.threaded);
    self.allocator.destroy(self);
}

fn execRaw(ctx: *anyopaque, sql: []const u8) anyerror!void {
    const self = asConn(ctx);
    // Parameterless DDL/DML; the simple-query protocol handles multi-statement input
    // and drains itself.
    _ = self.conn.exec(sql, .{}) catch |err| {
        if (err == error.PG) {
            if (self.conn.err) |e| {
                std.log.err("postgres execRaw failed [{s} {s}]: {s}\nSQL: {s}", .{ e.severity, e.code, e.message, sql });
                return error.ExecFailed;
            }
        }
        std.log.err("postgres execRaw failed: {}\nSQL: {s}", .{ err, sql });
        reviveConnection(self, err);
        return error.ExecFailed;
    };
}

fn begin(ctx: *anyopaque, mode: backend.TxMode) anyerror!void {
    _ = mode; // PG locks lazily; isolation handles serialization (no BEGIN IMMEDIATE)
    const self = asConn(ctx);
    self.conn.begin() catch |err| {
        reviveConnection(self, err);
        return err;
    };
}

fn commit(ctx: *anyopaque) anyerror!void {
    const self = asConn(ctx);
    self.conn.commit() catch |err| {
        reviveConnection(self, err);
        return err;
    };
}

fn rollback(ctx: *anyopaque) void {
    const self = asConn(ctx);
    self.conn.rollback() catch |err| {
        // A rollback on a DEAD connection is not critical: the server already
        // aborted the transaction when the session died; replacing the
        // connection is the recovery. Genuine rollback failures stay loud.
        if (isConnectionDead(err)) {
            std.log.warn("postgres rollback on dead connection ({}); session abort already discarded the transaction", .{err});
            reviveConnection(self, err);
            return;
        }
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
    // Scope to the connection's active schema (current_schema() = first existing schema in
    // search_path) rather than a hardcoded 'public', so a connection using a non-default
    // search_path (e.g. per-test isolation schemas) introspects its OWN tables. The PK
    // subquery is constrained to the same schema so a same-named table elsewhere can't leak
    // a wrong PK position.
    const sql =
        \\SELECT c.column_name::text, c.data_type::text,
        \\       COALESCE((SELECT kcu.ordinal_position FROM information_schema.table_constraints tc
        \\                 JOIN information_schema.key_column_usage kcu
        \\                   ON kcu.constraint_name = tc.constraint_name AND kcu.table_schema = tc.table_schema
        \\                 WHERE tc.table_name = c.table_name AND tc.table_schema = c.table_schema
        \\                   AND tc.constraint_type = 'PRIMARY KEY'
        \\                   AND kcu.column_name = c.column_name), 0)::bigint,
        \\       c.is_generated::text
        \\FROM information_schema.columns c
        \\WHERE c.table_name = $1 AND c.table_schema = COALESCE(current_schema(), 'public')
        \\ORDER BY c.ordinal_position
    ;
    var result = try self.conn.query(sql, .{table});
    defer result.deinit();

    var list: std.ArrayList(ColumnInfo) = .empty;
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
        // information_schema.columns.is_generated is 'ALWAYS' for GENERATED columns,
        // 'NEVER' otherwise. (SQLite's table_info omits generated columns entirely.)
        const is_generated = std.mem.eql(u8, try row.get([]const u8, 3), "ALWAYS");
        try list.append(allocator, .{ .name = name, .sql_type = sql_type, .pk_pos = try row.get(i64, 2), .is_generated = is_generated });
    }
    return list.toOwnedSlice(allocator);
}

// Reuse server-side prepared statements for `cached` queries, keyed by a hash of the
// (already `?`→`$N` renumbered) SQL in pg.zig's per-connection cache. A cache HIT skips
// the Parse+Describe round-trip and the server re-plan, ~halving round-trips per
// statement — the dominant cost against a remote DB. pg.zig only wires this caching into
// its inline-values API (queryOpts); our incremental-bind path replicates that exact flow
// here. Gated by DATABASE_STMT_CACHE; the cache is bounded by MAX_CACHED_STMTS and freed
// with the connection (pg.Conn.deinit frees _prepared_statements).
fn preparePossiblyCached(self: *PgConn, sql: []const u8, cached: bool) !pg.Stmt {
    const conn = self.conn;
    if (!cached or !self.stmt_cache) return conn.prepare(sql);

    var name_buf: [18]u8 = undefined; // 'z' + up to 16 hex digits
    const name = std.fmt.bufPrint(&name_buf, "z{x}", .{std.hash.Wyhash.hash(0, sql)}) catch
        return conn.prepare(sql);

    if (conn._prepared_statements.getEntry(name)) |entry| {
        // HIT: re-execute the already-prepared statement (no Parse). `entry.key_ptr` is
        // the cache-owned name (lives with the entry) so the Stmt's `.name` won't dangle.
        var stmt = try pg.Stmt.fromDescribe(conn, entry.value_ptr, .{ .cache_name = entry.key_ptr.* });
        errdefer stmt.deinit();
        try conn._reader.startFlow(stmt.arena.allocator(), null);
        try conn.write(&.{ 'S', 0, 0, 0, 4 }); // Sync
        stmt.buf.reset();
        try stmt.prepareForBind(@intCast(entry.value_ptr.param_oids.len));
        return stmt;
    }

    // MISS: keep the cache bounded; beyond the cap fall back to a one-shot prepare.
    if (conn._prepared_statements.count() >= MAX_CACHED_STMTS) return conn.prepare(sql);
    var stmt = try pg.Stmt.init(conn, .{ .cache_name = name });
    errdefer stmt.deinit();
    var describe_arena = std.heap.ArenaAllocator.init(conn._allocator);
    errdefer describe_arena.deinit();
    try stmt.prepare(sql, describe_arena.allocator());
    const owned_name = try describe_arena.allocator().dupe(u8, name);
    try conn._prepared_statements.put(conn._allocator, owned_name, .{
        .param_oids = stmt.param_oids,
        .arena = describe_arena,
        .result_state = stmt.result_state,
    });
    stmt.name = owned_name; // re-point off the stack buffer to the cache-owned copy
    return stmt;
}

fn prepare(ctx: *anyopaque, sql: []const u8, cached: bool) anyerror!Statement {
    const self = asConn(ctx);

    const renumbered = try pg_dialect_mod.renumberPlaceholders(self.allocator, sql);
    errdefer self.allocator.free(renumbered);

    var stmt = preparePossiblyCached(self, renumbered, cached) catch |err| {
        // warn, not err: the caller receives error.PrepareFailed and reports with
        // its own context (and the conformance suite exercises this path — the
        // default test runner fails any test that emits an err-level log).
        std.log.warn("postgres prepare failed: {}\nSQL: {s}", .{ err, renumbered });
        // A dead socket/TLS session is replaced before failing, so the batch
        // retry runs on a live connection instead of the corpse forever.
        reviveConnection(self, err);
        return error.PrepareFailed;
    };
    errdefer stmt.deinit();

    const ps = try self.allocator.create(PgStmt);
    ps.* = .{ .allocator = self.allocator, .conn = self.conn, .sql = renumbered, .stmt = stmt };
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
    conn: *pg.Conn, // borrowed (the pinned connection) — used by exec()'s affected-row drain
    sql: []u8, // owned (renumbered)
    stmt: pg.Stmt,
    executed: bool = false,
    // Materialized rows (owned). `cursor` is the next row step() will return; `cur` is
    // the row most recently returned (what the column getters read from).
    rows: []MatRow = &.{},
    cursor: usize = 0,
    cur: ?MatRow = null,
    // Affected-row count from the last exec()'s CommandComplete (changes()). 0 for the
    // step()/read path, which never feeds changes() in the storage layer.
    affected: i64 = 0,
    last_err: [256]u8 = undefined,
    last_err_len: usize = 0,
};

/// Extract the affected-row count from a CommandComplete tag ("UPDATE 3", "INSERT 0 5",
/// "DELETE 2", possibly NUL-terminated): the trailing run of digits. Mirrors pg.zig's
/// proto.CommandComplete.rowsAffected without reaching into its non-public proto module.
fn affectedFromCommandTag(data: []const u8) i64 {
    var end = data.len;
    while (end > 0 and !std.ascii.isDigit(data[end - 1])) end -= 1; // strip NUL / trailing non-digits
    if (end == 0) return 0; // e.g. "CREATE TABLE" — no count
    var start = end;
    while (start > 0 and std.ascii.isDigit(data[start - 1])) start -= 1;
    return std.fmt.parseInt(i64, data[start..end], 10) catch 0;
}

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
    const cap = self.last_err.len - 1; // reserve a slot for the NUL terminator
    const msg = std.fmt.bufPrint(self.last_err[0..cap], fmt, args) catch self.last_err[0..cap];
    self.last_err_len = msg.len;
    self.last_err[self.last_err_len] = 0; // NUL-terminate so lastError() returns a valid [:0]
}

// Capture the real Postgres error behind `error.PG` — SQLSTATE + message, plus the
// constraint/detail when present — which pg.zig parses into conn.err, into last_err so
// the storage layer's "Failed to {execute,step} query: {s}" log (via lastError(), in
// backend.zig) is diagnosable instead of the opaque "postgres statement error". Records
// only (no logging) so the raw exec()/step() vtable stays log-silent — the Statement
// wrappers do the logging. Non-PG errors (bind/protocol/io) fall back to the Zig tag.
fn recordPgErr(self: *PgStmt, comptime op: []const u8, err: anyerror) void {
    if (err == error.PG) {
        if (self.conn.err) |e| {
            if (e.constraint) |c|
                recordErr(self, op ++ ": {s} (SQLSTATE {s}, constraint {s})", .{ e.message, e.code, c })
            else if (e.detail) |d|
                recordErr(self, op ++ ": {s} (SQLSTATE {s}) — {s}", .{ e.message, e.code, d })
            else
                recordErr(self, op ++ ": {s} (SQLSTATE {s})", .{ e.message, e.code });
            return;
        }
    }
    recordErr(self, op ++ ": {}", .{err});
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
        OID.jsonb => {
            // jsonb binary format = 1-byte version header (currently 1) + JSON
            // text. Strip the header so columnText yields parseable JSON, like
            // SQLite's json_object and PG's plain `json` type (OID 114) do.
            const data = row.values[c].data;
            const body = if (data.len > 0 and data[0] == 1) data[1..] else data;
            return .{ .text = try allocator.dupe(u8, body) };
        },
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
    var list: std.ArrayList(MatRow) = .empty;
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

// Execute a write (INSERT/UPDATE/DELETE/DDL) and capture its affected-row count. Unlike
// the materializing step() path, this drains the response directly off the connection so
// the CommandComplete tag's row count survives (pg.zig's Result.next() consumes and
// discards it). Writes return no DataRows, so there is nothing to decode — any 'D' is just
// counted, mirroring pg.zig's own conn.exec drain. Reads-then-deinit (the natural order):
// all messages are consumed in-flow, then result.deinit() ends the reader flow.
fn doExec(self: *PgStmt) !void {
    if (self.executed) return;
    const result = try self.stmt.execute(); // leak-safe: flag set only after success
    self.executed = true;
    defer result.deinit();

    var affected: i64 = 0;
    while (true) {
        const msg = self.conn.read() catch |err| {
            if (err == error.PG) self.conn.readyForQuery() catch {}; // drain to ReadyForQuery
            return err;
        };
        switch (msg.type) {
            'C' => affected = affectedFromCommandTag(msg.data), // CommandComplete
            'D' => affected += 1, // DataRow (only with RETURNING; we don't keep them)
            'T' => affected = 0, // RowDescription resets, like conn.exec
            'Z' => break, // ReadyForQuery — read() set the conn back to idle
            // Unreachable against a conformant server; mark the conn failed (parity with
            // pg.zig's unexpectedDBMessage) so a desynced connection isn't reused.
            else => return self.conn.unexpectedDBMessage(),
        }
    }
    self.affected = affected;
}

fn exec(ctx: *anyopaque) bool {
    const self = asStmt(ctx);
    doExec(self) catch |err| {
        recordPgErr(self, "exec", err);
        return false;
    };
    return true; // connection drained back to idle; affected-row count captured
}

fn step(ctx: *anyopaque) StepOutcome {
    const self = asStmt(ctx);
    doExecute(self) catch |err| {
        recordPgErr(self, "step", err);
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
    const self = asStmt(ctx);
    // Affected rows from the last exec()'s CommandComplete. Negative is impossible for a
    // row count; clamp defensively. 0 on the read path (matches SQLite, where changes()
    // after a SELECT is 0).
    if (self.affected <= 0) return 0;
    return std.math.cast(u32, self.affected) orelse std.math.maxInt(u32);
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
    // recordErr() NUL-terminates last_err at last_err_len, so this [:0] slice is valid.
    // Carries the real Postgres error (SQLSTATE + message) for the storage-layer logs.
    return self.last_err[0..self.last_err_len :0];
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
