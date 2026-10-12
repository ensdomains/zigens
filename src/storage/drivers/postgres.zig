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

// synchronous_commit knob: bulk indexing can trade per-commit WAL durability for speed on
// a remote/managed PG. DATABASE_SYNCHRONOUS_COMMIT = on|off|local|remote_write|remote_apply;
// unset/blank leaves the server default (on). Safe for an indexer — it re-syncs from the
// chain on restart, so a lost just-committed batch is simply re-indexed. Returns a static
// (canonical) slice so it needs no ownership; null = don't touch the setting.
/// Whether a statement timeout is actually in force on this connection.
///
/// `applySessionSettings` issues `SET statement_timeout` ONCE per connection. A pooler
/// that does not carry connection-scoped settings across its multiplexing loses that SET,
/// and then no timeout is in force at all. Reading the value back in a SEPARATE statement
/// detects exactly that — and ONLY that; see `warnIfSessionStateIsLost` for why it is not
/// a general "am I pooled" test.
///
/// Tests "in effect at all" rather than the exact value: `SHOW` normalises units
/// (30000 -> "30s"), so comparing the number back would be brittle. Null means the probe
/// itself could not run — it never decides anything on its own.
///
/// NOTE the interaction with either recommended fix. Both ways of making the timeout
/// pooler-proof — setting it on the role (`ALTER ROLE ... SET statement_timeout`, applied
/// by the server at connection time) or having the pooler enforce it (PgDog's per-user
/// `statement_timeout` in users.toml) — leave a timeout in force regardless of whether the
/// connection-scoped SET survived. This probe then stays quiet. That is the correct answer
/// to the question it asks, so the fix RETIRES the probe rather than complementing it; it
/// is only informative while the timeout still rides on `applySessionSettings`.
fn statementTimeoutInEffect(self: *PgConn) ?bool {
    // Runs through the same single-group path as everything else, so the probe cannot be
    // the thing that leaves this pinned connection mid-response. Best effort: any failure
    // (a pooler that intercepts or rejects `SHOW`, for instance) reports "unknown".
    var affected: i64 = 0;
    const rows = runStatementGroup(self, self.allocator, "SHOW statement_timeout", &.{}, "", &affected) catch return null;
    defer freeRows(self.allocator, rows);
    if (rows.len == 0 or rows[0].len == 0) return null;
    const got = switch (rows[0][0]) {
        .text => |t| t,
        else => return null,
    };
    const t = std.mem.trim(u8, got, " \t");
    return !(t.len == 0 or std.mem.eql(u8, t, "0"));
}

/// Say so, loudly, when session state does not survive between statements.
///
/// BEST EFFORT, AND SILENCE PROVES NOTHING. Measured against PgDog 0.1.60 in
/// `pooler_mode = "transaction"`: six concurrent clients multiplexed onto ONE server
/// connection each saw their own `SET statement_timeout` persist, so PgDog virtualises
/// session parameters and this probe stays quiet on it. It fires for a pooler that does
/// NOT track them (pgbouncer in transaction mode without `track_extra_parameters`), which
/// is worth catching but is not the dangerous case here.
///
/// It says nothing about prepared statements, which is the OTHER pooling hazard and the
/// one that actually bites. MEASURED end to end with this binary, 320 concurrent
/// requests per configuration: direct Postgres 320 ok / 0 errors; PgDog 0.1.26 in
/// transaction mode on its default `prepared_statements` (extended) 207 failed with
/// SQLSTATE 08P01 ("bind message supplies N parameters, but prepared statement \"\"
/// requires M") and 26000; `extended_anonymous` 320 ok; `full` 289 failed; session mode
/// 320 ok. That was the UNNAMED statement, and `preparePossiblyCached` no longer uses it
/// — every statement is named, which took the same workload to 0 failures on the pooler's
/// default settings. Kept in this comment because no boot probe can see any of it, and
/// because one requirement survives: the pooler must track NAMED statements (PgDog does
/// by default; pgbouncer needs max_prepared_statements > 0).
/// Separately, that slot also dies on a DIRECT connection if a simple query runs between
/// a prepare and its bind (begin/commit/rollback, exec with no parameters, SET, SHOW).
/// Non-fatal by design: a diagnostic must not be the reason a service cannot boot.
fn warnIfSessionStateIsLost(allocator: std.mem.Allocator, self: *PgConn) void {
    if (statementTimeoutSecs(allocator) == 0) return; // nothing was set; nothing to verify
    const in_effect = statementTimeoutInEffect(self) orelse return;
    if (in_effect) return;
    std.log.err("postgres: `SET statement_timeout` did not survive to the next statement — " ++
        "this connection is behind a pooler that does not carry session state across " ++
        "statements. NO statement timeout is in force. Set it where the connection cannot " ++
        "lose it: on the role (ALTER ROLE <user> SET statement_timeout), or enforced by the " ++
        "pooler per user, or point this service at the DIRECT / session-mode endpoint.", .{});
}

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
    };

    // After the Backend exists: the probe runs its query through the same single-group
    // path as everything else, which needs the connection wrapper, not the raw handle.
    warnIfSessionStateIsLost(allocator, self);

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
    replaceConnection(self);
}

/// Replace the pinned connection unconditionally. Used both for a dead socket and for a
/// connection whose PROTOCOL state is unknown — one whose reply was not fully consumed is
/// unusable, because the next statement would read this one's tail as its own result.
fn replaceConnection(self: *PgConn) void {
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
    const self = asConn(ctx);
    // Plain BEGIN; PG locks lazily (no BEGIN IMMEDIATE). A transport-dead
    // failure replaces the pinned connection before erroring (staging fix) —
    // the caller's batch retry then runs on a live session.
    self.conn.begin() catch |err| {
        reviveConnection(self, err);
        return err;
    };
    if (mode == .read_snapshot) {
        // First statement in the tx: upgrade to a stable read-only snapshot. Best-effort —
        // if a pooler rejects it the read simply runs at the default isolation, never worse.
        _ = self.conn.exec("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY", .{}) catch |err|
            std.log.warn("postgres: could not set read-snapshot isolation: {}", .{err});
    }
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
    var affected: i64 = 0;
    const lens = [_]i32{@intCast(table.len)};
    const rows = try runStatementGroup(self, allocator, sql, &lens, table, &affected);
    defer freeRows(allocator, rows);

    var list: std.ArrayList(ColumnInfo) = .empty;
    errdefer {
        for (list.items) |col| {
            allocator.free(col.name);
            allocator.free(col.sql_type);
        }
        list.deinit(allocator);
    }
    for (rows) |row| {
        if (row.len < 4) return error.InvalidMessageFormat;
        const name = try allocator.dupe(u8, textOf(row[0]) orelse return error.InvalidMessageFormat);
        errdefer allocator.free(name);
        const sql_type = try allocator.dupe(u8, textOf(row[1]) orelse return error.InvalidMessageFormat);
        errdefer allocator.free(sql_type);
        // information_schema.columns.is_generated is 'ALWAYS' for GENERATED columns,
        // 'NEVER' otherwise. (SQLite's table_info omits generated columns entirely.)
        const is_generated = std.mem.eql(u8, textOf(row[3]) orelse "", "ALWAYS");
        try list.append(allocator, .{
            .name = name,
            .sql_type = sql_type,
            .pk_pos = switch (row[2]) {
                .int => |i| i,
                else => 0,
            },
            .is_generated = is_generated,
        });
    }
    return list.toOwnedSlice(allocator);
}

/// The bytes of a text-decoded column, or null when it was NULL or an integer.
fn textOf(v: MatValue) ?[]const u8 {
    return switch (v) {
        .text => |t| t,
        else => null,
    };
}

// ── One statement, one message group ─────────────────────────────────────────
//
// Every statement goes out as a single extended-protocol message group:
//
//     Parse("")  Bind(portal "")  Describe(portal "")  Execute("")  Sync
//
// which is what libpq's PQexecParams sends. Two properties follow, and both are the
// reason this is written by hand instead of using pg.zig's Stmt:
//
//  1. NOTHING THE STATEMENT CREATES OUTLIVES THE GROUP. The unnamed statement and the
//     unnamed portal are gone by the time Sync is answered, so there is no server-side
//     state for a connection pooler to lose, mis-route, or hand to another client. This
//     is correct on a direct connection and behind any pooler in any mode, with no
//     pooler configuration and no named-statement tracking. The previous design split
//     Parse+Describe+Sync from Bind+Execute+Sync, so a transaction-mode pooler could
//     serve the two halves from different backends (SQLSTATE 08P01/26000 — and silently
//     wrong rows when two colliding statements took the same parameter count).
//  2. IT IS ONE ROUND TRIP INSTEAD OF TWO. The old path had to read the parameter
//     description before it could encode binds. We know our own parameter types (the
//     bind* calls say so), so we skip Describe-on-statement entirely.
//
// Parameters are sent in TEXT format with their types unspecified — exactly what the old
// Parse did (it also declared zero parameter types), so server-side type inference is
// unchanged. Results come back in TEXT format too: a single group cannot pick per-column
// binary formats, because RowDescription only arrives in the reply. Every column in the
// generated schema is TEXT, BIGINT or SMALLINT, all of which decode losslessly from
// text; a BYTEA column would need binary handling and the schema has none.

fn msgStart(b: *std.ArrayList(u8), a: std.mem.Allocator, tag: u8) !usize {
    try b.append(a, tag);
    const at = b.items.len;
    try b.appendSlice(a, &.{ 0, 0, 0, 0 }); // length, back-filled by msgEnd
    return at;
}

fn msgEnd(b: *std.ArrayList(u8), at: usize) void {
    // The length covers itself and the payload, but not the type byte.
    std.mem.writeInt(u32, b.items[at..][0..4], @intCast(b.items.len - at), .big);
}

fn appendI16(b: *std.ArrayList(u8), a: std.mem.Allocator, v: i16) !void {
    var tmp: [2]u8 = undefined;
    std.mem.writeInt(i16, &tmp, v, .big);
    try b.appendSlice(a, &tmp);
}

fn appendI32(b: *std.ArrayList(u8), a: std.mem.Allocator, v: i32) !void {
    var tmp: [4]u8 = undefined;
    std.mem.writeInt(i32, &tmp, v, .big);
    try b.appendSlice(a, &tmp);
}

/// Build the whole group. `lens` holds one entry per parameter — a byte count into
/// `bytes`, or PARAM_NULL for SQL NULL — in bind order.
fn writeStatementGroup(
    b: *std.ArrayList(u8),
    a: std.mem.Allocator,
    sql: []const u8,
    lens: []const i32,
    bytes: []const u8,
) !void {
    { // Parse: unnamed statement, zero parameter type OIDs (the server infers them)
        const at = try msgStart(b, a, 'P');
        try b.append(a, 0);
        try b.appendSlice(a, sql);
        try b.append(a, 0);
        try appendI16(b, a, 0);
        msgEnd(b, at);
    }
    { // Bind: unnamed portal from the unnamed statement
        const at = try msgStart(b, a, 'B');
        try b.append(a, 0); // portal name
        try b.append(a, 0); // statement name
        try appendI16(b, a, 0); // 0 parameter format codes = every parameter is text
        try appendI16(b, a, @intCast(lens.len));
        var off: usize = 0;
        for (lens) |len| {
            try appendI32(b, a, len);
            if (len > 0) {
                const n: usize = @intCast(len);
                try b.appendSlice(a, bytes[off..][0..n]);
                off += n;
            }
        }
        try appendI16(b, a, 0); // 0 result format codes = every column is text
        msgEnd(b, at);
    }
    { // Describe the PORTAL, so RowDescription arrives in this same reply
        const at = try msgStart(b, a, 'D');
        try b.append(a, 'P');
        try b.append(a, 0);
        msgEnd(b, at);
    }
    { // Execute with no row limit
        const at = try msgStart(b, a, 'E');
        try b.append(a, 0);
        try appendI32(b, a, 0);
        msgEnd(b, at);
    }
    try b.appendSlice(a, &.{ 'S', 0, 0, 0, 4 }); // Sync
}

/// Consume messages until ReadyForQuery, discarding them. An ErrorResponse mid-drain is
/// expected (the server reports it, then still sends ReadyForQuery), so it does not stop
/// the drain. Bounded so a misbehaving peer cannot spin here forever.
fn drainToReadyForQuery(conn: *pg.Conn) !void {
    var guard: usize = 0;
    while (guard < 1_000_000) : (guard += 1) {
        const msg = conn.read() catch |err| {
            if (err == error.PG) continue; // ErrorResponse; ReadyForQuery still follows
            return err;
        };
        if (msg.type == 'Z') return;
    }
    return error.DrainLimitExceeded;
}

/// Column type OIDs from a RowDescription payload. Only the type OID of each field is
/// kept — it is all the text decoder needs.
fn parseRowDescription(a: std.mem.Allocator, data: []const u8) ![]i32 {
    if (data.len < 2) return error.InvalidMessageFormat;
    const n = std.mem.readInt(u16, data[0..2], .big);
    const out = try a.alloc(i32, n);
    errdefer a.free(out);
    var off: usize = 2;
    for (out) |*oid| {
        const name_end = std.mem.indexOfScalarPos(u8, data, off, 0) orelse return error.InvalidMessageFormat;
        off = name_end + 1 + 4 + 2; // name, table OID, column attribute number
        if (off + 4 > data.len) return error.InvalidMessageFormat;
        oid.* = std.mem.readInt(i32, data[off..][0..4], .big);
        off += 4 + 2 + 4 + 2; // type OID, type size, type modifier, format code
    }
    return out;
}

/// Decode one text-format column value. Integer and boolean columns become `.int` so the
/// getters stay integer-typed; everything else keeps its bytes. In text format `json` and
/// `jsonb` both arrive as plain JSON (no binary version header), which is exactly what
/// columnText should return.
fn decodeTextValue(a: std.mem.Allocator, oid: i32, bytes: []const u8) !MatValue {
    return switch (oid) {
        OID.int2, OID.int4, OID.int8 => .{ .int = std.fmt.parseInt(i64, bytes, 10) catch 0 },
        OID.bool_ => .{ .int = @intFromBool(bytes.len > 0 and (bytes[0] == 't' or bytes[0] == 'T' or bytes[0] == '1')) },
        OID.bytea => decodeBytea(a, bytes),
        else => .{ .text = try a.dupe(u8, bytes) },
    };
}

/// bytea in TEXT format is the hex escape `\x<pairs>`; decode it to the raw bytes the
/// binary format used to deliver, so a caller reading a bytea column sees its content and
/// not the escape sequence. The generated schema has no bytea column today — this keeps
/// adding one from silently changing what columnText returns. Anything that is not a
/// well-formed hex escape is passed through verbatim (PG's older `escape` output format,
/// which a server could be configured for).
fn decodeBytea(a: std.mem.Allocator, bytes: []const u8) !MatValue {
    if (bytes.len < 2 or bytes[0] != '\\' or bytes[1] != 'x' or (bytes.len - 2) % 2 != 0) {
        return .{ .text = try a.dupe(u8, bytes) };
    }
    const hex = bytes[2..];
    const out = try a.alloc(u8, hex.len / 2);
    errdefer a.free(out);
    _ = std.fmt.hexToBytes(out, hex) catch return .{ .text = try a.dupe(u8, bytes) };
    return .{ .text = out };
}

/// Materialize one DataRow. Values are copied out of the reader's buffer immediately —
/// the next read may reuse it.
fn parseDataRow(a: std.mem.Allocator, data: []const u8, oids: []const i32) !MatRow {
    if (data.len < 2) return error.InvalidMessageFormat;
    const n = std.mem.readInt(u16, data[0..2], .big);
    const out = try a.alloc(MatValue, n);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |v| switch (v) {
            .text => |t| a.free(t),
            else => {},
        };
        a.free(out);
    }
    var off: usize = 2;
    while (filled < n) : (filled += 1) {
        if (off + 4 > data.len) return error.InvalidMessageFormat;
        const len = std.mem.readInt(i32, data[off..][0..4], .big);
        off += 4;
        if (len == PARAM_NULL) {
            out[filled] = .null;
            continue;
        }
        const size: usize = @intCast(len);
        if (off + size > data.len) return error.InvalidMessageFormat;
        const oid: i32 = if (filled < oids.len) oids[filled] else OID.text;
        out[filled] = try decodeTextValue(a, oid, data[off..][0..size]);
        off += size;
    }
    return out;
}

fn prepare(ctx: *anyopaque, sql: []const u8, cached: bool) anyerror!Statement {
    const self = asConn(ctx);
    // `cached` is accepted for the SPI (SQLite uses it) and deliberately ignored: a
    // statement that outlives its message group is exactly what this driver no longer
    // creates. Reuse would mean a named server-side statement, which is the thing a
    // transaction-mode pooler cannot be relied on to carry.
    _ = cached;

    // No wire traffic here. The SQL is renumbered and kept; Parse travels with Bind and
    // Execute in one group at first step()/exec(), once the parameters are known.
    const renumbered = try pg_dialect_mod.renumberPlaceholders(self.allocator, sql);
    errdefer self.allocator.free(renumbered);

    const ps = try self.allocator.create(PgStmt);
    ps.* = .{ .allocator = self.allocator, .owner = self, .sql = renumbered };
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

/// A parameter is a byte count into `param_bytes`, in bind order; PARAM_NULL means SQL
/// NULL and consumes no bytes.
const PARAM_NULL: i32 = -1;

const PgStmt = struct {
    allocator: std.mem.Allocator,
    owner: *PgConn, // borrowed; owns the connection this statement runs on
    sql: []u8, // owned (renumbered)
    // Parameters, accumulated by the bind* calls and sent with Parse in one group.
    param_bytes: std.ArrayList(u8) = .empty,
    param_lens: std.ArrayList(i32) = .empty,
    executed: bool = false,
    // Materialized rows (owned). `cursor` is the next row step() will return; `cur` is
    // the row most recently returned (what the column getters read from).
    rows: []MatRow = &.{},
    cursor: usize = 0,
    cur: ?MatRow = null,
    // Affected-row count from the CommandComplete tag (changes()).
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

fn freeRow(allocator: std.mem.Allocator, row: MatRow) void {
    for (row) |v| switch (v) {
        .text => |t| allocator.free(t),
        else => {},
    };
    allocator.free(row);
}

fn freeRows(allocator: std.mem.Allocator, rows: []MatRow) void {
    for (rows) |row| freeRow(allocator, row);
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
        if (self.owner.conn.err) |e| {
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

/// Record one text-format parameter. Binds never touch the socket — they fill the buffer
/// that Bind is built from at execute time.
fn pushParam(self: *PgStmt, bytes: []const u8) bool {
    self.param_bytes.appendSlice(self.allocator, bytes) catch |err| {
        recordErr(self, "bind: {}", .{err});
        return false;
    };
    self.param_lens.append(self.allocator, @intCast(bytes.len)) catch |err| {
        recordErr(self, "bind: {}", .{err});
        return false;
    };
    return true;
}

fn bindText(ctx: *anyopaque, idx: c_int, ptr: [*]const u8, len: usize) bool {
    _ = idx; // parameters are positional, in bind order
    return pushParam(asStmt(ctx), ptr[0..len]);
}

fn bindInt64(ctx: *anyopaque, idx: c_int, value: i64) bool {
    _ = idx;
    const self = asStmt(ctx);
    var buf: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable; // i64 fits
    return pushParam(self, text);
}

fn bindInt(ctx: *anyopaque, idx: c_int, value: i32) bool {
    _ = idx;
    const self = asStmt(ctx);
    var buf: [12]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable; // i32 fits
    return pushParam(self, text);
}

fn bindNull(ctx: *anyopaque, idx: c_int) bool {
    _ = idx;
    const self = asStmt(ctx);
    self.param_lens.append(self.allocator, PARAM_NULL) catch |err| {
        recordErr(self, "bindNull: {}", .{err});
        return false;
    };
    return true;
}

/// Send one statement as a single message group and materialize everything it returns.
/// This is the ONLY place the driver issues a parameterized statement — the Statement
/// path and the driver's own internal queries both come through here, so nothing can
/// quietly take a different, pooler-unsafe route.
///
/// Rows are copied out as they arrive and the connection is idle again the moment
/// ReadyForQuery lands, which is what lets the storage layer iterate one query while
/// issuing others on the same pinned connection.
fn runStatementGroup(
    owner: *PgConn,
    allocator: std.mem.Allocator,
    sql: []const u8,
    lens: []const i32,
    bytes: []const u8,
    affected: *i64,
) ![]MatRow {
    const conn = owner.conn;

    var batch: std.ArrayList(u8) = .empty;
    defer batch.deinit(allocator);
    try writeStatementGroup(&batch, allocator, sql, lens, bytes);

    // Give the reader an allocator for the exchange, so a row wider than its static
    // buffer can be read (and the dynamic buffer reused across rows).
    try conn._reader.startFlow(allocator, null);
    defer conn._reader.endFlow() catch {
        conn._state = .fail; // only affects the next statement; the pool recovers
    };

    conn.write(batch.items) catch |err| {
        reviveConnection(owner, err);
        return err;
    };

    return readStatementReply(owner, allocator, affected) catch |err| {
        // Whatever went wrong — a server ErrorResponse, a malformed message, or running
        // out of memory while materializing — the REST OF THE REPLY IS STILL IN THE
        // SOCKET. Consume it, or retire the connection. Reading one statement's tail as
        // the next statement's result is exactly the corruption this design exists to
        // prevent, so there is no path here that leaves the connection half-read.
        drainToReadyForQuery(conn) catch |drain_err| {
            // The reply could not be consumed — in practice because the session is gone
            // (an admin termination or a dead socket ends the drain with EndOfStream).
            // Either way this connection's protocol position is unknown, so retire it.
            std.log.warn("postgres: statement reply not drainable ({}); replacing the connection", .{drain_err});
            replaceConnection(owner);
        };
        return err;
    };
}

/// Read one statement group's reply, materializing its rows.
fn readStatementReply(owner: *PgConn, allocator: std.mem.Allocator, affected: *i64) ![]MatRow {
    const conn = owner.conn;
    var oids: []i32 = &.{};
    defer allocator.free(oids);
    var list: std.ArrayList(MatRow) = .empty;
    errdefer {
        for (list.items) |row| freeRow(allocator, row);
        list.deinit(allocator);
    }

    while (true) {
        const msg = conn.read() catch |err| {
            // read() turns ErrorResponse into error.PG after recording it. The caller
            // drains whatever follows (the server still owes us a ReadyForQuery).
            reviveConnection(owner, err);
            return err;
        };
        switch (msg.type) {
            '1', '2', 'n' => {}, // ParseComplete, BindComplete, NoData
            'T' => { // RowDescription, from the portal Describe in our group
                allocator.free(oids);
                oids = try parseRowDescription(allocator, msg.data);
            },
            'D' => { // DataRow
                const row = try parseDataRow(allocator, msg.data, oids);
                errdefer freeRow(allocator, row);
                try list.append(allocator, row);
            },
            'C' => affected.* = affectedFromCommandTag(msg.data), // CommandComplete
            'Z' => break, // ReadyForQuery — read() has restored the connection state
            // Unreachable against a conformant server. Mark the connection failed
            // (parity with pg.zig) so a desynced one is replaced rather than reused.
            else => return conn.unexpectedDBMessage(),
        }
    }

    return list.toOwnedSlice(allocator);
}

fn doExecute(self: *PgStmt) !void {
    if (self.executed) return;
    // Set before sending: a statement whose group failed must not re-send on what may be
    // a replaced connection. The caller surfaces the error; a retry re-prepares.
    self.executed = true;
    self.rows = try runStatementGroup(
        self.owner,
        self.allocator,
        self.sql,
        self.param_lens.items,
        self.param_bytes.items,
        &self.affected,
    );
}

fn doExec(self: *PgStmt) !void {
    // Writes travel the same group as reads; the CommandComplete tag carries the
    // affected-row count and a write returns no DataRows to keep.
    return doExecute(self);
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
    // Nothing is held on the server: the unnamed statement and portal died with the
    // group's Sync, so teardown is purely local memory.
    freeRows(self.allocator, self.rows);
    self.param_bytes.deinit(self.allocator);
    self.param_lens.deinit(self.allocator);
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
