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
/// The vtable ctx is `db.backend.ptr` (the driver's connection), NOT `db` — same as the
/// `Tx` guard and every other vtable call site. Passing `db` cast to the driver's conn
/// struct happened to land benignly on SQLite but is a garbage `*pg.Conn` on Postgres
/// (segfault at `conn.begin`).
pub fn beginTransaction(db: *Database) !void {
    return db.backend.vtable.begin(db.backend.ptr, .deferred);
}

pub fn commitTransaction(db: *Database) !void {
    return db.backend.vtable.commit(db.backend.ptr);
}

pub fn rollbackTransaction(db: *Database) void {
    db.backend.vtable.rollback(db.backend.ptr);
}
