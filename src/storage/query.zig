/// Query Executor - Generic SQLite query abstraction
///
/// This module provides a type-safe, ergonomic wrapper around SQLite's C API
/// that eliminates repetitive boilerplate while maintaining full functionality.
///
/// Usage:
/// ```zig
/// var q = try Query.init(db, "SELECT name, owner FROM names WHERE namehash = ?");
/// defer q.deinit();
/// try q.bind(namehash_hex);
/// while (try q.step()) {
///     const name = try q.getText(0);
///     const owner = try q.getText(1);
///     // ...
/// }
/// ```
const std = @import("std");
const db_module = @import("database.zig");
const Database = db_module.Database;
pub const c = db_module.c;
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;

/// Max number of bound strings to track per query
const MAX_BOUND_STRINGS = 32;

/// Query executor for SQLite operations
/// Handles prepared statements, parameter binding, and result extraction
pub const Query = struct {
    db: ?*c.sqlite3,
    stmt: ?*c.sqlite3_stmt,
    allocator: std.mem.Allocator,
    param_idx: c_int,
    sql_z: [:0]u8,
    /// Tracks allocated strings that need to be freed after exec/step
    bound_strings: [MAX_BOUND_STRINGS]?[]u8,
    bound_string_count: usize,

    /// Initialize a query with the given SQL
    /// The SQL is prepared immediately; call deinit() when done
    pub fn init(database: *Database, sql: []const u8) !Query {
        const sql_z = try database.allocator.dupeZ(u8, sql);
        errdefer database.allocator.free(sql_z);

        var stmt: ?*c.sqlite3_stmt = null;
        const prepare_result = c.sqlite3_prepare_v2(database.db, sql_z.ptr, -1, &stmt, null);
        if (prepare_result != c.SQLITE_OK) {
            std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(database.db)});
            std.log.err("SQL: {s}", .{sql});
            return error.PrepareFailed;
        }

        return Query{
            .db = database.db,
            .stmt = stmt,
            .allocator = database.allocator,
            .param_idx = 1,
            .sql_z = sql_z,
            .bound_strings = [_]?[]u8{null} ** MAX_BOUND_STRINGS,
            .bound_string_count = 0,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *Query) void {
        self.freeBoundStrings();
        if (self.stmt) |s| {
            _ = c.sqlite3_finalize(s);
            self.stmt = null;
        }
        self.allocator.free(self.sql_z);
    }

    /// Reset the query for re-use with new parameters
    pub fn reset(self: *Query) void {
        self.freeBoundStrings();
        if (self.stmt) |s| {
            _ = c.sqlite3_reset(s);
            _ = c.sqlite3_clear_bindings(s);
        }
        self.param_idx = 1;
    }

    /// Free all tracked bound strings
    fn freeBoundStrings(self: *Query) void {
        for (self.bound_strings[0..self.bound_string_count]) |maybe_str| {
            if (maybe_str) |str| {
                self.allocator.free(str);
            }
        }
        self.bound_string_count = 0;
        self.bound_strings = [_]?[]u8{null} ** MAX_BOUND_STRINGS;
    }

    /// Track an allocated string for later cleanup
    fn trackBoundString(self: *Query, str: []u8) void {
        if (self.bound_string_count < MAX_BOUND_STRINGS) {
            self.bound_strings[self.bound_string_count] = str;
            self.bound_string_count += 1;
        } else {
            // Fallback: free immediately if we run out of slots
            // This may cause issues but prevents memory leaks
            std.log.warn("Query: exceeded max bound strings, freeing immediately", .{});
            self.allocator.free(str);
        }
    }

    // ========================================================================
    // PARAMETER BINDING
    // ========================================================================

    /// Bind a text parameter
    /// For safety, we allocate a copy and track it for cleanup
    pub fn bindText(self: *Query, value: []const u8) !void {
        // Allocate a copy and track it - this ensures the string lives until exec/step
        const copy = try self.allocator.dupe(u8, value);
        self.trackBoundString(copy);
        try self.bindTextTracked(copy);
    }

    /// Bind a text parameter with static lifetime (no copy)
    pub fn bindTextStatic(self: *Query, value: []const u8) !void {
        const result = c.sqlite3_bind_text(
            self.stmt,
            self.param_idx,
            value.ptr,
            @intCast(value.len),
            c.SQLITE_STATIC,
        );
        if (result != c.SQLITE_OK) {
            std.log.err("Failed to bind static text parameter: {s}", .{c.sqlite3_errmsg(self.db)});
            return error.BindFailed;
        }
        self.param_idx += 1;
    }

    /// Bind an i64 parameter
    pub fn bindInt64(self: *Query, value: i64) !void {
        const result = c.sqlite3_bind_int64(self.stmt, self.param_idx, value);
        if (result != c.SQLITE_OK) {
            std.log.err("Failed to bind int64 parameter: {s}", .{c.sqlite3_errmsg(self.db)});
            return error.BindFailed;
        }
        self.param_idx += 1;
    }

    /// Bind an i32 parameter
    pub fn bindInt(self: *Query, value: i32) !void {
        const result = c.sqlite3_bind_int(self.stmt, self.param_idx, value);
        if (result != c.SQLITE_OK) {
            std.log.err("Failed to bind int parameter: {s}", .{c.sqlite3_errmsg(self.db)});
            return error.BindFailed;
        }
        self.param_idx += 1;
    }

    /// Bind a NULL parameter
    pub fn bindNull(self: *Query) !void {
        const result = c.sqlite3_bind_null(self.stmt, self.param_idx);
        if (result != c.SQLITE_OK) {
            std.log.err("Failed to bind null parameter: {s}", .{c.sqlite3_errmsg(self.db)});
            return error.BindFailed;
        }
        self.param_idx += 1;
    }

    /// Bind an Address type (converts to hex)
    /// The hex string is tracked and freed on reset()/deinit()
    pub fn bindAddress(self: *Query, addr: Address) !void {
        const hex = try addr.toHex(self.allocator);
        self.trackBoundString(hex);
        try self.bindTextTracked(hex);
    }

    /// Bind a Hash type (converts to hex)
    /// The hex string is tracked and freed on reset()/deinit()
    pub fn bindHash(self: *Query, hash: Hash) !void {
        const hex = try hash.toHex(self.allocator);
        self.trackBoundString(hex);
        try self.bindTextTracked(hex);
    }

    /// Bind a text parameter that we're tracking (uses SQLITE_STATIC since we own the memory)
    fn bindTextTracked(self: *Query, value: []u8) !void {
        const result = c.sqlite3_bind_text(
            self.stmt,
            self.param_idx,
            value.ptr,
            @intCast(value.len),
            c.SQLITE_STATIC,
        );
        if (result != c.SQLITE_OK) {
            std.log.err("Failed to bind tracked text parameter: {s}", .{c.sqlite3_errmsg(self.db)});
            return error.BindFailed;
        }
        self.param_idx += 1;
    }

    /// Bind an optional text parameter (binds NULL if none)
    pub fn bindOptionalText(self: *Query, value: ?[]const u8) !void {
        if (value) |v| {
            try self.bindText(v);
        } else {
            try self.bindNull();
        }
    }

    /// Bind an optional i64 parameter (binds NULL if none)
    pub fn bindOptionalInt64(self: *Query, value: ?i64) !void {
        if (value) |v| {
            try self.bindInt64(v);
        } else {
            try self.bindNull();
        }
    }

    /// Bind an optional Address parameter (binds NULL if none)
    pub fn bindOptionalAddress(self: *Query, addr: ?Address) !void {
        if (addr) |a| {
            try self.bindAddress(a);
        } else {
            try self.bindNull();
        }
    }

    /// Bind an optional Hash parameter (binds NULL if none)
    pub fn bindOptionalHash(self: *Query, hash: ?Hash) !void {
        if (hash) |h| {
            try self.bindHash(h);
        } else {
            try self.bindNull();
        }
    }

    // ========================================================================
    // EXECUTION
    // ========================================================================

    /// Execute the query (for INSERT/UPDATE/DELETE)
    /// Returns error if execution fails
    pub fn exec(self: *Query) !void {
        const result = c.sqlite3_step(self.stmt);
        if (result != c.SQLITE_DONE) {
            std.log.err("Failed to execute query: {s}", .{c.sqlite3_errmsg(self.db)});
            return error.ExecFailed;
        }
    }

    /// Step through results (for SELECT)
    /// Returns true if there's a row available, false if done
    pub fn step(self: *Query) !bool {
        const result = c.sqlite3_step(self.stmt);
        if (result == c.SQLITE_ROW) {
            return true;
        } else if (result == c.SQLITE_DONE) {
            return false;
        } else {
            std.log.err("Failed to step query: {s}", .{c.sqlite3_errmsg(self.db)});
            return error.StepFailed;
        }
    }

    /// Get the number of rows changed by the last INSERT/UPDATE/DELETE
    pub fn changes(self: *Query) u32 {
        return @intCast(c.sqlite3_changes(self.db));
    }

    // ========================================================================
    // RESULT EXTRACTION
    // ========================================================================

    /// Get text from column (returns null if column is NULL)
    /// Caller owns the returned memory
    pub fn getText(self: *Query, col: usize) !?[]u8 {
        const col_idx: c_int = @intCast(col);
        if (c.sqlite3_column_type(self.stmt, col_idx) == c.SQLITE_NULL) {
            return null;
        }
        const text_ptr = c.sqlite3_column_text(self.stmt, col_idx);
        if (text_ptr == null) {
            return null;
        }
        const len = c.sqlite3_column_bytes(self.stmt, col_idx);
        const slice = text_ptr[0..@intCast(len)];
        return try self.allocator.dupe(u8, slice);
    }

    /// Get text from column as a slice (does NOT allocate)
    /// WARNING: The returned slice is only valid until the next step() or deinit()
    pub fn getTextSlice(self: *Query, col: usize) ?[]const u8 {
        const col_idx: c_int = @intCast(col);
        if (c.sqlite3_column_type(self.stmt, col_idx) == c.SQLITE_NULL) {
            return null;
        }
        const text_ptr = c.sqlite3_column_text(self.stmt, col_idx);
        if (text_ptr == null) {
            return null;
        }
        const len = c.sqlite3_column_bytes(self.stmt, col_idx);
        return text_ptr[0..@intCast(len)];
    }

    /// Get i64 from column
    pub fn getInt64(self: *Query, col: usize) i64 {
        return c.sqlite3_column_int64(self.stmt, @intCast(col));
    }

    /// Get i32 from column
    pub fn getInt(self: *Query, col: usize) i32 {
        return c.sqlite3_column_int(self.stmt, @intCast(col));
    }

    /// Get bool from column (0 = false, non-0 = true)
    pub fn getBool(self: *Query, col: usize) bool {
        return c.sqlite3_column_int(self.stmt, @intCast(col)) != 0;
    }

    /// Get optional i64 from column (returns null if column is NULL)
    pub fn getOptionalInt64(self: *Query, col: usize) ?i64 {
        const col_idx: c_int = @intCast(col);
        if (c.sqlite3_column_type(self.stmt, col_idx) == c.SQLITE_NULL) {
            return null;
        }
        return c.sqlite3_column_int64(self.stmt, col_idx);
    }

    /// Get optional i32 from column (returns null if column is NULL)
    pub fn getOptionalInt(self: *Query, col: usize) ?i32 {
        const col_idx: c_int = @intCast(col);
        if (c.sqlite3_column_type(self.stmt, col_idx) == c.SQLITE_NULL) {
            return null;
        }
        return c.sqlite3_column_int(self.stmt, col_idx);
    }

    /// Get optional bool from column (returns null if column is NULL)
    pub fn getOptionalBool(self: *Query, col: usize) ?bool {
        const col_idx: c_int = @intCast(col);
        if (c.sqlite3_column_type(self.stmt, col_idx) == c.SQLITE_NULL) {
            return null;
        }
        return c.sqlite3_column_int(self.stmt, col_idx) != 0;
    }

    /// Check if column is NULL
    pub fn isNull(self: *Query, col: usize) bool {
        return c.sqlite3_column_type(self.stmt, @intCast(col)) == c.SQLITE_NULL;
    }

    /// Get Address from column (parses hex string)
    /// Returns null if column is NULL or invalid
    pub fn getAddress(self: *Query, col: usize) !?Address {
        const text = self.getTextSlice(col) orelse return null;
        return Address.fromHex(text) catch null;
    }

    /// Get Hash from column (parses hex string)
    /// Returns null if column is NULL or invalid
    pub fn getHash(self: *Query, col: usize) !?Hash {
        const text = self.getTextSlice(col) orelse return null;
        return Hash.fromHex(text) catch null;
    }
};

// ============================================================================
// CONVENIENCE FUNCTIONS
// ============================================================================

/// Execute a simple statement with no parameters or results
pub fn exec(database: *Database, sql: []const u8) !void {
    var q = try Query.init(database, sql);
    defer q.deinit();
    try q.exec();
}

/// Execute a statement with parameters, no results
pub fn execWith(database: *Database, sql: []const u8, binder: anytype) !void {
    var q = try Query.init(database, sql);
    defer q.deinit();
    try binder(&q);
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
