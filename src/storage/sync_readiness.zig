//! Per-protocol "initial sync finished" marker that gates the GraphQL API.
//!
//! The indexer clears its protocol's row when it starts a bulk sync of a database
//! that has never indexed anything, and sets it once the initial sync and its
//! one-shot heals complete. The API runs in a separate process, so the flag lives in
//! the database rather than in `Indexer.initial_sync_complete`. Created via
//! `ensureSchema` (like finality_state), so it is not part of the drop-and-reindex
//! base schema.
//!
//! What the gate is for: a FIRST index, where `sync_state` advances while entities
//! are still buffered and the one-shot heals have not run — queries would see a
//! half-built database. It deliberately does not close over a re-sync of an
//! already-indexed database: that data is complete as of an older block, and
//! `_coverage.stale` / `ensv2_coverage_stale` already say so.

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
/// bulk sync. A protocol this deployment does not index never writes a row, so it
/// does not hold the gate shut.
///
/// An absent or empty table is NOT "not ready". This table is created by the
/// indexer's `ensureSchema`; the API's pool never migrates (see storage/pool.zig),
/// so on an already-indexed deployment the API reads it before any upgraded indexer
/// has written a row — gating a complete database behind a marker nobody has written
/// yet. Fall back to what is already indexed, the same way `_finality` degrades on an
/// absent `finality_state`. A database that has never synced stays gated.
pub fn isSyncReady(db: *Database) !bool {
    var q = Query.init(db, "SELECT COUNT(*), COALESCE(MIN(ready), 0) FROM sync_readiness") catch
        return everSynced(db);
    defer q.deinit();
    // Postgres surfaces a missing relation at step, not at prepare.
    const have_row = q.step() catch return everSynced(db);
    if (!have_row or q.getInt64(0) == 0) return everSynced(db);
    return q.getInt64(1) == 1;
}

/// Whether any protocol has ever committed a block to this database.
fn everSynced(db: *Database) bool {
    return ((db.getSyncState(.v1) catch null) orelse 0) > 0 or
        ((db.getSyncState(.v2) catch null) orelse 0) > 0;
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

test "isSyncReady: an absent or empty marker falls back to what is already indexed" {
    const a = std.testing.allocator;
    var database = try Database.init(a, ":memory:");
    defer database.deinit();

    // The state the API sees on the first deploy of this feature, and on any
    // deployment whose indexer still runs an older build.
    try database.exec("DROP TABLE sync_readiness");
    try std.testing.expect(!try isSyncReady(&database));

    try database.setSyncState(.v2, 12_345);
    try std.testing.expect(try isSyncReady(&database));

    // An empty table reads the same as an absent one...
    try ensureSchema(&database);
    try std.testing.expect(try isSyncReady(&database));

    // ...but an explicit "not ready" row still wins over the fallback, which is what
    // keeps a first bulk sync gated once sync_state starts advancing.
    try setSyncReady(&database, .v2, false);
    try std.testing.expect(!try isSyncReady(&database));
}
