//! SQLite backend driver.
//!
//! Owns the SQLite connection state (`SqliteConn`: the `sqlite3` handle + the
//! prepared-statement cache) and the `@cImport(sqlite3.h)`. `Database` holds
//! only a `Backend` (an opaque `ptr` to a `SqliteConn` + the vtable); the raw
//! handle no longer leaks past this driver. Implements both the connection-level
//! `backend.VTable` (open/close/exec/prepare/tx/lastInsertId) and the
//! per-statement `backend.StmtVTable`.

const std = @import("std");
const constants = @import("../../constants.zig");
const backend = @import("../backend.zig");
const Statement = backend.Statement;

const c = @cImport({
    @cInclude("sqlite3.h");
});

/// Driver-owned connection state, heap-allocated and referenced by `Backend.ptr`.
pub const SqliteConn = struct {
    allocator: std.mem.Allocator,
    db: ?*c.sqlite3,
    stmt_cache: std.StringHashMap(*c.sqlite3_stmt),
};

inline fn asConn(ctx: *anyopaque) *SqliteConn {
    return @ptrCast(@alignCast(ctx));
}

inline fn asStmt(ctx: *anyopaque) *c.sqlite3_stmt {
    return @ptrCast(@alignCast(ctx));
}

// ── Per-statement vtable (ctx = the sqlite3_stmt) ───────────────────────────

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

fn stmtExec(ctx: *anyopaque) bool {
    return c.sqlite3_step(asStmt(ctx)) == c.SQLITE_DONE;
}

fn step(ctx: *anyopaque) backend.StepOutcome {
    return switch (c.sqlite3_step(asStmt(ctx))) {
        c.SQLITE_ROW => .row,
        c.SQLITE_DONE => .done,
        else => .failed,
    };
}

fn stmtChanges(ctx: *anyopaque) u32 {
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

fn stmtLastError(ctx: *anyopaque) [:0]const u8 {
    return std.mem.span(c.sqlite3_errmsg(c.sqlite3_db_handle(asStmt(ctx))));
}

fn stmtReset(ctx: *anyopaque) void {
    _ = c.sqlite3_reset(asStmt(ctx));
    _ = c.sqlite3_clear_bindings(asStmt(ctx));
}

fn stmtFinalize(ctx: *anyopaque) void {
    _ = c.sqlite3_finalize(asStmt(ctx));
}

pub const stmt_vtable = backend.StmtVTable{
    .bindText = bindText,
    .bindInt64 = bindInt64,
    .bindInt = bindInt,
    .bindNull = bindNull,
    .exec = stmtExec,
    .step = step,
    .changes = stmtChanges,
    .columnIsNull = columnIsNull,
    .columnText = columnText,
    .columnInt64 = columnInt64,
    .columnInt = columnInt,
    .lastError = stmtLastError,
    .reset = stmtReset,
    .finalize = stmtFinalize,
};

fn wrap(stmt: *c.sqlite3_stmt, allocator: std.mem.Allocator, cached: bool) Statement {
    return Statement{
        .ctx = @ptrCast(stmt),
        .vtable = &stmt_vtable,
        .allocator = allocator,
        .is_cached = cached,
    };
}

// ── Connection-level vtable (ctx = *SqliteConn) ─────────────────────────────

/// Prepare a statement, optionally via the per-connection cache. Cached statements
/// are reset+rebound on reuse and owned by the cache (reset, not finalized, on deinit).
fn prepare(ctx: *anyopaque, sql: []const u8, cached: bool) anyerror!Statement {
    const conn = asConn(ctx);
    if (cached) {
        if (conn.stmt_cache.get(sql)) |cached_stmt| {
            _ = c.sqlite3_reset(cached_stmt);
            _ = c.sqlite3_clear_bindings(cached_stmt);
            return wrap(cached_stmt, conn.allocator, true);
        }
    }

    const sql_z = try conn.allocator.dupeZ(u8, sql);
    defer conn.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(conn.db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) {
        std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(conn.db)});
        std.log.err("SQL: {s}", .{sql});
        return error.PrepareFailed;
    }

    if (cached) {
        // Finalize the freshly-prepared stmt if caching it fails, else it leaks.
        errdefer _ = c.sqlite3_finalize(stmt.?);
        const sql_key = try conn.allocator.dupe(u8, sql);
        errdefer conn.allocator.free(sql_key);
        try conn.stmt_cache.put(sql_key, stmt.?);
        return wrap(stmt.?, conn.allocator, true);
    }

    return wrap(stmt.?, conn.allocator, false);
}

/// Execute a parameterless statement. Swallows "duplicate column" errors so
/// idempotent ALTER-based migrations are safe to re-run.
fn execOnConn(conn: *SqliteConn, sql: []const u8) anyerror!void {
    const sql_z = try conn.allocator.dupeZ(u8, sql);
    defer conn.allocator.free(sql_z);

    var err_msg: [*c]u8 = null;
    const result = c.sqlite3_exec(conn.db, sql_z.ptr, null, null, &err_msg);
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

fn execRaw(ctx: *anyopaque, sql: []const u8) anyerror!void {
    return execOnConn(asConn(ctx), sql);
}

fn begin(ctx: *anyopaque, mode: backend.TxMode) anyerror!void {
    const conn = asConn(ctx);
    const sql = switch (mode) {
        .deferred => "BEGIN TRANSACTION",
        .immediate => "BEGIN IMMEDIATE TRANSACTION",
    };
    if (c.sqlite3_exec(conn.db, sql, null, null, null) != c.SQLITE_OK) {
        std.log.err("Failed to begin transaction: {s}", .{c.sqlite3_errmsg(conn.db)});
        return error.BeginTransactionFailed;
    }
}

fn commit(ctx: *anyopaque) anyerror!void {
    const conn = asConn(ctx);
    if (c.sqlite3_exec(conn.db, "COMMIT", null, null, null) != c.SQLITE_OK) {
        std.log.err("Failed to commit transaction: {s}", .{c.sqlite3_errmsg(conn.db)});
        return error.CommitFailed;
    }
    std.log.debug("Transaction committed successfully", .{});
}

fn rollback(ctx: *anyopaque) void {
    const conn = asConn(ctx);
    if (c.sqlite3_exec(conn.db, "ROLLBACK", null, null, null) != c.SQLITE_OK) {
        std.log.err("CRITICAL: Failed to rollback transaction: {s}", .{c.sqlite3_errmsg(conn.db)});
    }
}

fn lastInsertId(ctx: *anyopaque) i64 {
    return c.sqlite3_last_insert_rowid(asConn(ctx).db);
}

/// Finalize all cached statements (+ free keys), close the connection, free the
/// connection state. Statements MUST be finalized before sqlite3_close.
fn close(ctx: *anyopaque) void {
    const conn = asConn(ctx);
    var it = conn.stmt_cache.iterator();
    while (it.next()) |entry| {
        _ = c.sqlite3_finalize(entry.value_ptr.*);
        conn.allocator.free(entry.key_ptr.*);
    }
    conn.stmt_cache.deinit();
    if (conn.db) |handle| {
        _ = c.sqlite3_close(handle);
    }
    const allocator = conn.allocator;
    allocator.destroy(conn);
}

pub const vtable = backend.VTable{
    .close = close,
    .execRaw = execRaw,
    .prepare = prepare,
    .begin = begin,
    .commit = commit,
    .rollback = rollback,
    .lastInsertId = lastInsertId,
};

// ── SQL dialect builders (emit today's exact SQLite SQL) ────────────────────

fn appendQuotedIdent(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), ident: []const u8) !void {
    try buf.append(allocator, '"');
    try buf.appendSlice(allocator, ident);
    try buf.append(allocator, '"');
}

fn appendInsertInto(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), table: []const u8, cols: []const []const u8, action: backend.ConflictAction) !void {
    try buf.appendSlice(allocator, switch (action) {
        .replace => "INSERT OR REPLACE INTO ",
        .ignore => "INSERT OR IGNORE INTO ",
    });
    try appendQuotedIdent(allocator, buf, table);
    try buf.appendSlice(allocator, " (");
    for (cols, 0..) |col, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try appendQuotedIdent(allocator, buf, col);
    }
    try buf.append(allocator, ')');
}

fn dialectUpsert(allocator: std.mem.Allocator, table: []const u8, cols: []const []const u8, value_exprs: []const []const u8, conflict_cols: []const []const u8, action: backend.ConflictAction) anyerror![]u8 {
    // SQLite INSERT OR REPLACE/IGNORE does not take a conflict-key list.
    _ = conflict_cols;
    std.debug.assert(value_exprs.len == 0 or value_exprs.len == cols.len);
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    try appendInsertInto(allocator, &buf, table, cols, action);
    try buf.appendSlice(allocator, " VALUES (");
    for (cols, 0..) |_, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, if (value_exprs.len == 0) "?" else value_exprs[i]);
    }
    try buf.append(allocator, ')');
    return buf.toOwnedSlice(allocator);
}

fn dialectInsertSelect(allocator: std.mem.Allocator, table: []const u8, cols: []const []const u8, select_body: []const u8, conflict_cols: []const []const u8, action: backend.ConflictAction) anyerror![]u8 {
    // SQLite INSERT OR REPLACE/IGNORE does not take a conflict-key list.
    _ = conflict_cols;
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    try appendInsertInto(allocator, &buf, table, cols, action);
    try buf.append(allocator, ' ');
    try buf.appendSlice(allocator, select_body);
    return buf.toOwnedSlice(allocator);
}

fn dialectReturning(allocator: std.mem.Allocator, col: []const u8) anyerror![]u8 {
    return std.fmt.allocPrint(allocator, " RETURNING {s}", .{col});
}

fn dialectJsonObject(allocator: std.mem.Allocator, cols: []const []const u8, alias: []const u8) anyerror![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "json_object(");
    for (cols, 0..) |col, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.writer(allocator).print("'{s}', {s}.\"{s}\"", .{ col, alias, col });
    }
    try buf.append(allocator, ')');
    return buf.toOwnedSlice(allocator);
}

fn dialectJsonExtract(allocator: std.mem.Allocator, src: []const u8, col: []const u8) anyerror![]u8 {
    return std.fmt.allocPrint(allocator, "json_extract({s}, '$.{s}')", .{ src, col });
}

pub const sqlite_dialect = backend.Dialect{
    .placeholder = .qmark,
    .nowEpoch = "strftime('%s', 'now')",
    .upsert = dialectUpsert,
    .insertSelect = dialectInsertSelect,
    .returning = dialectReturning,
    .jsonObject = dialectJsonObject,
    .jsonExtract = dialectJsonExtract,
};

// ── Open / global config ────────────────────────────────────────────────────

/// Apply the standard connection PRAGMAs (WAL, busy_timeout, synchronous,
/// cache_size, foreign_keys, temp_store, recursive_triggers). `recursive_triggers`
/// is load-bearing for the reorg undo-log (see reorg_undo.zig).
fn applyPragmas(conn: *SqliteConn) !void {
    try execOnConn(conn, "PRAGMA journal_mode=WAL;");
    try execOnConn(conn, std.fmt.comptimePrint("PRAGMA busy_timeout = {d};", .{constants.SQLite.busy_timeout_ms}));
    try execOnConn(conn, "PRAGMA synchronous = NORMAL;");
    try execOnConn(conn, std.fmt.comptimePrint("PRAGMA cache_size = {d};", .{constants.SQLite.cache_size_kb}));
    try execOnConn(conn, "PRAGMA foreign_keys = ON;");
    try execOnConn(conn, "PRAGMA temp_store = memory;");
    try execOnConn(conn, "PRAGMA recursive_triggers = ON;");
}

/// Open a SQLite connection at `path`, apply PRAGMAs, and return a `Backend`
/// owning the connection state. The driver owns the connection lifecycle.
pub fn open(allocator: std.mem.Allocator, path: []const u8) !backend.Backend {
    const conn = try allocator.create(SqliteConn);
    errdefer allocator.destroy(conn);
    conn.* = .{
        .allocator = allocator,
        .db = null,
        .stmt_cache = std.StringHashMap(*c.sqlite3_stmt).init(allocator),
    };
    errdefer conn.stmt_cache.deinit();

    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const rc = c.sqlite3_open(path_z.ptr, &conn.db);
    errdefer _ = c.sqlite3_close(conn.db);
    if (rc != c.SQLITE_OK) {
        std.log.err("Failed to open database: {s}", .{c.sqlite3_errmsg(conn.db)});
        return error.DatabaseOpenFailed;
    }

    try applyPragmas(conn);
    return backend.Backend{ .ptr = conn, .vtable = &vtable, .dialect = &sqlite_dialect };
}

/// Configure SQLite for serialized (thread-safe) mode. Must be called once at
/// process start, BEFORE opening any connection (it is a global pre-init option).
pub fn configureSerialized() void {
    const rc = c.sqlite3_config(c.SQLITE_CONFIG_SERIALIZED);
    if (rc == c.SQLITE_OK) {
        std.log.info("SQLite configured for serialized (thread-safe) mode", .{});
    } else {
        std.log.warn("Failed to configure SQLite thread safety: {d}", .{rc});
    }
}
