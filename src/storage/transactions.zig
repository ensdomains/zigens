const db_module = @import("database.zig");
const Database = db_module.Database;

// ============================================================================
// TRANSACTION OPERATIONS
// ============================================================================
//
// Thin wrappers that dispatch through the backend vtable, preserving the
// `db.beginTransaction()` / `commitTransaction()` / `rollbackTransaction()`
// call-site API (used by the indexer's batch loop). The `Tx` RAII guard in
// backend.zig is the preferred form for new code.

/// Begin a deferred transaction (batch insert/update for memory efficiency).
pub fn beginTransaction(db: *Database) !void {
    return db.backend.vtable.begin(db, .deferred);
}

pub fn commitTransaction(db: *Database) !void {
    return db.backend.vtable.commit(db);
}

pub fn rollbackTransaction(db: *Database) void {
    db.backend.vtable.rollback(db);
}
