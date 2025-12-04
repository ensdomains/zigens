const std = @import("std");
const db_module = @import("database.zig");
const Database = db_module.Database;
const c = db_module.c;

// ============================================================================
// TRANSACTION OPERATIONS (3 functions)
// ============================================================================

/// Batch insert/update for memory efficiency
pub fn beginTransaction(db: *Database) !void {
    const sql = "BEGIN TRANSACTION";
    if (c.sqlite3_exec(db.db, sql, null, null, null) != c.SQLITE_OK) {
        std.log.err("Failed to begin transaction: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.BeginTransactionFailed;
    }
}

pub fn commitTransaction(db: *Database) !void {
    const sql = "COMMIT";
    if (c.sqlite3_exec(db.db, sql, null, null, null) != c.SQLITE_OK) {
        std.log.err("Failed to commit transaction: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.CommitFailed;
    }
    std.log.debug("Transaction committed successfully", .{});
}

pub fn rollbackTransaction(db: *Database) void {
    const sql = "ROLLBACK";
    const result = c.sqlite3_exec(db.db, sql, null, null, null);
    if (result != c.SQLITE_OK) {
        std.log.err("CRITICAL: Failed to rollback transaction: {s}", .{c.sqlite3_errmsg(db.db)});
    }
}
