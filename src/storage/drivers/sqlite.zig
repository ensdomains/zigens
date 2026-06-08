//! SQLite implementation of the statement seam (`backend.StmtVTable`).
//!
//! Phase 0: wraps the exact prepare/bind/step/column logic the old `Query`
//! used — `sqlite3_prepare_v2`, `SQLITE_STATIC` text binds, the per-`Database`
//! prepared-statement cache — behind the backend-agnostic vtable. No behaviour
//! change. The `@cImport` is shared from `database.zig` for now (it moves here
//! once the legacy raw-C modules are ported in Phase 1).

const std = @import("std");
const constants = @import("../../constants.zig");
const db_mod = @import("../database.zig");
const c = db_mod.c;
const Database = db_mod.Database;
const backend = @import("../backend.zig");
const Statement = backend.Statement;

inline fn asStmt(ctx: *anyopaque) *c.sqlite3_stmt {
    return @ptrCast(@alignCast(ctx));
}

fn bindText(ctx: *anyopaque, idx: c_int, ptr: [*]const u8, len: usize) bool {
    return c.sqlite3_bind_text(asStmt(ctx), idx, ptr, @intCast(len), c.SQLITE_STATIC) == c.SQLITE_OK;
}

fn bindInt64(ctx: *anyopaque, idx: c_int, value: i64) bool {
    return c.sqlite3_bind_int64(asStmt(ctx), idx, value) == c.SQLITE_OK;
}

fn bindInt(ctx: *anyopaque, idx: c_int, value: i32) bool {
    return c.sqlite3_bind_int(asStmt(ctx), idx, value) == c.SQLITE_OK;
}

fn bindNull(ctx: *anyopaque, idx: c_int) bool {
    return c.sqlite3_bind_null(asStmt(ctx), idx) == c.SQLITE_OK;
}

fn exec(ctx: *anyopaque) bool {
    return c.sqlite3_step(asStmt(ctx)) == c.SQLITE_DONE;
}

fn step(ctx: *anyopaque) backend.StepOutcome {
    return switch (c.sqlite3_step(asStmt(ctx))) {
        c.SQLITE_ROW => .row,
        c.SQLITE_DONE => .done,
        else => .failed,
    };
}

fn changes(ctx: *anyopaque) u32 {
    return @intCast(c.sqlite3_changes(c.sqlite3_db_handle(asStmt(ctx))));
}

fn columnIsNull(ctx: *anyopaque, col: c_int) bool {
    return c.sqlite3_column_type(asStmt(ctx), col) == c.SQLITE_NULL;
}

fn columnText(ctx: *anyopaque, col: c_int) ?[]const u8 {
    const stmt = asStmt(ctx);
    if (c.sqlite3_column_type(stmt, col) == c.SQLITE_NULL) return null;
    const text_ptr = c.sqlite3_column_text(stmt, col);
    if (text_ptr == null) return null;
    const len = c.sqlite3_column_bytes(stmt, col);
    return text_ptr[0..@intCast(len)];
}

fn columnInt64(ctx: *anyopaque, col: c_int) i64 {
    return c.sqlite3_column_int64(asStmt(ctx), col);
}

fn columnInt(ctx: *anyopaque, col: c_int) i32 {
    return c.sqlite3_column_int(asStmt(ctx), col);
}

fn lastError(ctx: *anyopaque) [:0]const u8 {
    return std.mem.span(c.sqlite3_errmsg(c.sqlite3_db_handle(asStmt(ctx))));
}

fn reset(ctx: *anyopaque) void {
    _ = c.sqlite3_reset(asStmt(ctx));
    _ = c.sqlite3_clear_bindings(asStmt(ctx));
}

fn finalize(ctx: *anyopaque) void {
    _ = c.sqlite3_finalize(asStmt(ctx));
}

// ── Connection-level vtable (open/close/exec/prepare) ───────────────────────

/// Open a SQLite connection at `path`. The driver owns the connection lifecycle;
/// `Database.init`/`initWithoutSchema` store the returned handle in `Database.db`.
pub fn openConnection(allocator: std.mem.Allocator, path: []const u8) !?*c.sqlite3 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(path_z.ptr, &db) != c.SQLITE_OK) {
        std.log.err("Failed to open database: {s}", .{c.sqlite3_errmsg(db)});
        return error.DatabaseOpenFailed;
    }
    return db;
}

/// Apply the standard connection PRAGMAs (WAL, busy_timeout, synchronous,
/// cache_size, foreign_keys, temp_store, recursive_triggers). `recursive_triggers`
/// is load-bearing for the reorg undo-log (see reorg_undo.zig).
pub fn applyPragmas(database: *Database) !void {
    try database.exec("PRAGMA journal_mode=WAL;");
    try database.exec(std.fmt.comptimePrint("PRAGMA busy_timeout = {d};", .{constants.SQLite.busy_timeout_ms}));
    try database.exec("PRAGMA synchronous = NORMAL;");
    try database.exec(std.fmt.comptimePrint("PRAGMA cache_size = {d};", .{constants.SQLite.cache_size_kb}));
    try database.exec("PRAGMA foreign_keys = ON;");
    try database.exec("PRAGMA temp_store = memory;");
    try database.exec("PRAGMA recursive_triggers = ON;");
}

/// Finalize all cached statements (+ free their keys), then close the connection.
/// Statements MUST be finalized before sqlite3_close (which fails on open stmts).
fn close(database: *Database) void {
    var it = database.stmt_cache.iterator();
    while (it.next()) |entry| {
        _ = c.sqlite3_finalize(entry.value_ptr.*);
        database.allocator.free(entry.key_ptr.*);
    }
    database.stmt_cache.deinit();
    if (database.db) |handle| {
        _ = c.sqlite3_close(handle);
    }
}

/// Execute a statement with no parameters/results. Swallows "duplicate column"
/// errors so idempotent ALTER-based migrations are safe to re-run.
fn execRaw(database: *Database, sql: []const u8) anyerror!void {
    const sql_z = try database.allocator.dupeZ(u8, sql);
    defer database.allocator.free(sql_z);

    var err_msg: [*c]u8 = null;
    const result = c.sqlite3_exec(database.db, sql_z.ptr, null, null, &err_msg);
    if (result != c.SQLITE_OK) {
        defer c.sqlite3_free(err_msg);
        if (err_msg != null) {
            const err_str = std.mem.span(err_msg);
            if (std.mem.indexOf(u8, err_str, "duplicate column name") != null) {
                std.log.debug("Skipping duplicate column: {s}", .{err_msg});
                return;
            }
        }
        std.log.err("SQL error: {s}", .{err_msg});
        return error.SqlExecFailed;
    }
}

fn begin(database: *Database, mode: backend.TxMode) anyerror!void {
    const sql = switch (mode) {
        .deferred => "BEGIN TRANSACTION",
        .immediate => "BEGIN IMMEDIATE TRANSACTION",
    };
    if (c.sqlite3_exec(database.db, sql, null, null, null) != c.SQLITE_OK) {
        std.log.err("Failed to begin transaction: {s}", .{c.sqlite3_errmsg(database.db)});
        return error.BeginTransactionFailed;
    }
}

fn commit(database: *Database) anyerror!void {
    if (c.sqlite3_exec(database.db, "COMMIT", null, null, null) != c.SQLITE_OK) {
        std.log.err("Failed to commit transaction: {s}", .{c.sqlite3_errmsg(database.db)});
        return error.CommitFailed;
    }
    std.log.debug("Transaction committed successfully", .{});
}

fn rollback(database: *Database) void {
    if (c.sqlite3_exec(database.db, "ROLLBACK", null, null, null) != c.SQLITE_OK) {
        std.log.err("CRITICAL: Failed to rollback transaction: {s}", .{c.sqlite3_errmsg(database.db)});
    }
}

fn lastInsertId(database: *Database) i64 {
    return c.sqlite3_last_insert_rowid(database.db);
}

/// The connection-level vtable `Database` dispatches through.
pub const vtable = backend.VTable{
    .close = close,
    .execRaw = execRaw,
    .prepare = prepare,
    .begin = begin,
    .commit = commit,
    .rollback = rollback,
    .lastInsertId = lastInsertId,
};

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

fn wrap(stmt: *c.sqlite3_stmt, allocator: std.mem.Allocator, cached: bool) Statement {
    return Statement{
        .ctx = @ptrCast(stmt),
        .vtable = &stmt_vtable,
        .allocator = allocator,
        .is_cached = cached,
    };
}

/// Prepare a statement, optionally via the per-`Database` cache. Mirrors the
/// old `Query.init`/`Query.initCached`: prepares with `sqlite3_prepare_v2`;
/// cached statements are reset+rebound on reuse and owned by the cache (reset,
/// not finalized, on `Statement.deinit`).
pub fn prepare(database: *Database, sql: []const u8, cached: bool) anyerror!Statement {
    if (cached) {
        if (database.stmt_cache.get(sql)) |cached_stmt| {
            _ = c.sqlite3_reset(cached_stmt);
            _ = c.sqlite3_clear_bindings(cached_stmt);
            return wrap(cached_stmt, database.allocator, true);
        }
    }

    const sql_z = try database.allocator.dupeZ(u8, sql);
    defer database.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(database.db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) {
        std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(database.db)});
        std.log.err("SQL: {s}", .{sql});
        return error.PrepareFailed;
    }

    if (cached) {
        // Finalize the freshly-prepared stmt if caching it fails (OOM on the
        // key dupe or the cache put), otherwise it would leak.
        errdefer _ = c.sqlite3_finalize(stmt.?);
        const sql_key = try database.allocator.dupe(u8, sql);
        errdefer database.allocator.free(sql_key);
        try database.stmt_cache.put(sql_key, stmt.?);
        return wrap(stmt.?, database.allocator, true);
    }

    return wrap(stmt.?, database.allocator, false);
}
