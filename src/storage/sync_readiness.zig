//! Per-protocol "initial sync finished" marker that gates the GraphQL API.
//!
//! The indexer clears its protocol's row when it enters bulk mode (a sync gap large
//! enough to drop indexes) and sets it once the initial sync and its one-shot heals
//! complete. The API runs in a separate process, so the flag lives in the database
//! rather than in `Indexer.initial_sync_complete`. Created via `ensureSchema` (like
//! finality_state), so it is not part of the drop-and-reindex base schema.

const std = @import("std");
const zsys = @import("../utils/system.zig");
const db_module = @import("database.zig");
const Database = db_module.Database;
const Query = db_module.Query;
const models = @import("../types/models.zig");

pub fn ensureSchema(db: *Database) !void {
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS sync_readiness (
        \\  protocol TEXT NOT NULL PRIMARY KEY,
        \\  ready BIGINT NOT NULL,
        \\  updated_at BIGINT NOT NULL
        \\)
    );
}

pub fn setSyncReady(db: *Database, protocol: models.Protocol, ready: bool) !void {
    const sql = try db.upsertSql(db.allocator, "sync_readiness", &.{ "protocol", "ready", "updated_at" }, .replace);
    defer db.allocator.free(sql);

    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindInt64(@intFromBool(ready));
    try q.bindInt64(zsys.timestamp());
    try q.exec();
}

/// True once at least one protocol has finished its initial sync and none is mid
/// bulk sync. A protocol that is not indexed by this deployment never writes a row,
/// so it does not hold the gate shut.
pub fn isSyncReady(db: *Database) !bool {
    var q = try Query.init(db, "SELECT COUNT(*), COALESCE(MIN(ready), 0) FROM sync_readiness");
    defer q.deinit();
    if (!try q.step()) return false;
    return q.getInt64(0) > 0 and q.getInt64(1) == 1;
}

test "isSyncReady: closed until a protocol finishes, reopens only when all have" {
    const a = std.testing.allocator;
    var database = try Database.init(a, ":memory:");
    defer database.deinit();

    try std.testing.expect(!try isSyncReady(&database));

    try setSyncReady(&database, .v2, false);
    try std.testing.expect(!try isSyncReady(&database));

    try setSyncReady(&database, .v2, true);
    try std.testing.expect(try isSyncReady(&database));

    try setSyncReady(&database, .v1, false);
    try std.testing.expect(!try isSyncReady(&database));

    try setSyncReady(&database, .v1, true);
    try std.testing.expect(try isSyncReady(&database));
}
