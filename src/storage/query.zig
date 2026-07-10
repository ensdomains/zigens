/// Query Executor — backend-agnostic prepared-statement abstraction.
///
/// `Query` is now an alias for `backend.Statement`: the executor logic moved to
/// `backend.zig` (the backend-agnostic surface) and `drivers/sqlite.zig` (the
/// SQLite implementation of the statement vtable). Call sites are unchanged.
///
/// Usage:
/// ```zig
/// var q = try Query.init(db, "SELECT name, owner FROM names WHERE namehash = ?");
/// defer q.deinit();
/// try q.bindText(namehash_hex);
/// while (try q.step()) {
///     const name = try q.getTextSlice(0);
///     const owner = try q.getTextSlice(1);
/// }
/// ```
const std = @import("std");
const db_module = @import("database.zig");
const Database = db_module.Database;
const backend = @import("backend.zig");

/// Backend-agnostic prepared statement. Defined in `backend.zig`; aliased here
/// so existing `query.Query` / `db.Query` call sites keep working unchanged.
pub const Query = backend.Statement;

// ============================================================================
// CONVENIENCE FUNCTIONS
// ============================================================================

/// Build a parameterized SQL `IN`/`NOT IN` clause: `<column> <op> (?, ?, …)`.
///
/// Caller owns the returned slice (free with `allocator.free`). `op` is the
/// uppercase phrase to insert between column and parenthesised placeholders,
/// typically `"IN"` or `"NOT IN"`. `count` is the number of placeholders;
/// callers should special-case `count == 0` themselves (this helper returns
/// a syntactically valid but always-empty clause when count is 0).
pub fn buildInClause(allocator: std.mem.Allocator, column: []const u8, op: []const u8, count: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, column);
    try out.append(allocator, ' ');
    try out.appendSlice(allocator, op);
    try out.appendSlice(allocator, " (");
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (i > 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, "?");
    }
    try out.appendSlice(allocator, ")");
    return try out.toOwnedSlice(allocator);
}

/// "(a<sep>b<sep>c)" — wrap a joined list of SQL fragments in parentheses. Used by the
/// recursive `and`/`or` boolean-filter builders (names/events/registrations).
pub fn joinWrapped(allocator: std.mem.Allocator, items: []const []const u8, sep: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '(');
    for (items, 0..) |it, i| {
        if (i > 0) try buf.appendSlice(allocator, sep);
        try buf.appendSlice(allocator, it);
    }
    try buf.append(allocator, ')');
    return buf.toOwnedSlice(allocator);
}

/// Execute a simple statement with no parameters or results
pub fn exec(database: *Database, sql: []const u8) !void {
    var q = try Query.init(database, sql);
    defer q.deinit();
    try q.exec();
}

/// Query a single value
pub fn queryOne(comptime T: type, database: *Database, sql: []const u8, binder: anytype) !?T {
    var q = try Query.init(database, sql);
    defer q.deinit();
    try binder(&q);
    if (try q.step()) {
        return switch (T) {
            i64 => q.getInt64(0),
            i32 => q.getInt(0),
            bool => q.getBool(0),
            else => @compileError("queryOne only supports i64, i32, bool"),
        };
    }
    return null;
}

/// Query a single text value
pub fn queryText(database: *Database, sql: []const u8, binder: anytype) !?[]u8 {
    var q = try Query.init(database, sql);
    defer q.deinit();
    try binder(&q);
    if (try q.step()) {
        return try q.getText(0);
    }
    return null;
}

// ============================================================================
// TESTS
// ============================================================================

test "Query basic operations" {
    // This test would require a real database connection
    // For now, just verify the module compiles
}
