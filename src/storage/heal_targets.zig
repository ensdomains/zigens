//! Durable per-target ledger for init-gap heal sweeps.
//!
//! A row in `init_gap_heal_targets` is one (task, protocol, address) sweep the
//! indexer owes: resolver/subregistry contracts whose initialization events
//! predate their first sighting. Discovery-time backfills record their outcome
//! here (success or failure), and the drain in `event_fetchers.zig` retries
//! failed targets with attempt caps and spacing — so a transient RPC failure
//! can never silently become a permanent data gap, which is exactly what the
//! old task-level `backfill_status` marker allowed (it was written `completed`
//! even when every per-target sweep had failed).
//!
//! Clock-free by design: callers pass timestamps in, so tests drive retry
//! spacing deterministically.

const std = @import("std");
const db_module = @import("database.zig");
const Database = db_module.Database;
const Query = db_module.Query;
const models = @import("../types/models.zig");
const Address = @import("../types/address.zig").Address;

const ALL_COLS = [_][]const u8{ "task", "protocol", "address", "completed", "attempts", "last_error_at" };

/// Canonicalize an address to the lowercase `Address.toHex` form before it
/// touches the table. The ledger PK must match the drain's toHex round-trip
/// exactly (a case-divergent row would stay pending forever next to a
/// completed twin), and an unparseable address must never enter the ledger
/// (the drain could not sweep it, so it would hold the per-cycle pending
/// gate — and with it the reorg-cursor disarm — open on every poll).
/// Returns an owned slice.
fn canonicalAddress(db: *Database, address: []const u8) ![]u8 {
    const addr = Address.fromHex(address) catch return error.InvalidHealTargetAddress;
    return addr.toHex(db.allocator);
}

/// Register a target that needs a sweep. No-op if the target already has a row
/// (completed or not) — a completed target stays completed.
pub fn enqueueHealTarget(db: *Database, task: []const u8, protocol: models.Protocol, address: []const u8) !void {
    const canon = try canonicalAddress(db, address);
    defer db.allocator.free(canon);
    const sql = try db.upsertSql(db.allocator, "init_gap_heal_targets", &ALL_COLS, .ignore);
    defer db.allocator.free(sql);
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindTextStatic(task);
    try q.bindTextStatic(protocol.toString());
    try q.bindTextStatic(canon);
    try q.bindInt(0);
    try q.bindInt(0);
    try q.bindInt64(0);
    try q.exec();
}

/// Mark a target's sweep as done. Upserts, so a discovery-time success needs no
/// prior `enqueueHealTarget`; attempts reset with it.
pub fn recordHealTargetSuccess(db: *Database, task: []const u8, protocol: models.Protocol, address: []const u8) !void {
    const canon = try canonicalAddress(db, address);
    defer db.allocator.free(canon);
    const sql = try db.upsertSql(db.allocator, "init_gap_heal_targets", &ALL_COLS, .replace);
    defer db.allocator.free(sql);
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindTextStatic(task);
    try q.bindTextStatic(protocol.toString());
    try q.bindTextStatic(canon);
    try q.bindInt(1);
    try q.bindInt(0);
    try q.bindInt64(0);
    try q.exec();
}

/// Count a failed sweep attempt and stamp it for retry spacing. Creates the row
/// if the target was never enqueued (discovery-time failure). Returns the
/// target's attempt count after the bump so the caller can log when a target
/// crosses the cap and parks.
pub fn recordHealTargetFailure(db: *Database, task: []const u8, protocol: models.Protocol, address: []const u8, now: i64) !u32 {
    const canon = try canonicalAddress(db, address);
    defer db.allocator.free(canon);
    {
        // completed = 0: a failure recorded against a completed row must
        // reopen it — silently absorbing it would be the exact trust break
        // this ledger exists to prevent (load-bearing once reorg rollback
        // re-arms targets).
        var q = try Query.init(db,
            \\UPDATE init_gap_heal_targets
            \\SET attempts = attempts + 1, last_error_at = ?, completed = 0
            \\WHERE task = ? AND protocol = ? AND address = ?
        );
        defer q.deinit();
        try q.bindInt64(now);
        try q.bindTextStatic(task);
        try q.bindTextStatic(protocol.toString());
        try q.bindTextStatic(canon);
        try q.exec();
        if (q.changes() > 0) {
            var r = try Query.init(db, "SELECT attempts FROM init_gap_heal_targets WHERE task = ? AND protocol = ? AND address = ?");
            defer r.deinit();
            try r.bindTextStatic(task);
            try r.bindTextStatic(protocol.toString());
            try r.bindTextStatic(canon);
            if (try r.step()) return @intCast(r.getInt(0));
            return 1;
        }
    }

    const sql = try db.upsertSql(db.allocator, "init_gap_heal_targets", &ALL_COLS, .ignore);
    defer db.allocator.free(sql);
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindTextStatic(task);
    try q.bindTextStatic(protocol.toString());
    try q.bindTextStatic(canon);
    try q.bindInt(0);
    try q.bindInt(1);
    try q.bindInt64(now);
    try q.exec();
    return 1;
}

/// Targets still owing a sweep: not completed, attempts under `max_attempts`,
/// and last failure at or before `retry_before` (fresh rows carry 0, so they
/// always qualify). Write-time canonicalization guarantees every stored
/// address parses; the skip below is belt-and-braces against hand-edited rows.
pub fn pendingHealTargets(db: *Database, allocator: std.mem.Allocator, task: []const u8, protocol: models.Protocol, max_attempts: u32, retry_before: i64) !std.ArrayList(Address) {
    var targets: std.ArrayList(Address) = .empty;
    errdefer targets.deinit(allocator);

    var q = try Query.init(db,
        \\SELECT address FROM init_gap_heal_targets
        \\WHERE task = ? AND protocol = ? AND completed = 0 AND attempts < ? AND last_error_at <= ?
        \\ORDER BY address
    );
    defer q.deinit();
    try q.bindTextStatic(task);
    try q.bindTextStatic(protocol.toString());
    try q.bindInt(@intCast(max_attempts));
    try q.bindInt64(retry_before);
    while (try q.step()) {
        const addr_slice = q.getTextSlice(0) orelse continue;
        const addr = Address.fromHex(addr_slice) catch continue;
        try targets.append(allocator, addr);
    }
    return targets;
}

/// Cheap per-cycle gate: is any sweep currently due for `protocol`, across all
/// tasks? Lets the sync loop skip the reorg-cursor disarm and drain entirely on
/// the (typical) no-work cycle.
pub fn hasPendingHealTargets(db: *Database, protocol: models.Protocol, max_attempts: u32, retry_before: i64) !bool {
    var q = try Query.init(db,
        \\SELECT 1 FROM init_gap_heal_targets
        \\WHERE protocol = ? AND completed = 0 AND attempts < ? AND last_error_at <= ?
        \\LIMIT 1
    );
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindInt(@intCast(max_attempts));
    try q.bindInt64(retry_before);
    return try q.step();
}

/// Re-arm every target for `protocol` after a reorg rollback: heal sweeps
/// write with undo capture deliberately disarmed, so the rollback may have
/// deleted healed rows — a surviving `completed` marker would make that loss
/// permanent. One idempotent full re-sweep converges the projections to the
/// surviving chain; attempts reset too, since prior failures say nothing
/// about it.
pub fn resetHealTargets(db: *Database, protocol: models.Protocol) !void {
    var q = try Query.init(db,
        \\UPDATE init_gap_heal_targets
        \\SET completed = 0, attempts = 0, last_error_at = 0
        \\WHERE protocol = ?
    );
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.exec();
}

/// Targets that exhausted their attempts without ever succeeding — each one is
/// a real data gap that needs an operator (or a raised cap). For err-level
/// reporting.
pub fn countExhaustedHealTargets(db: *Database, task: []const u8, protocol: models.Protocol, max_attempts: u32) !u32 {
    var q = try Query.init(db,
        \\SELECT COUNT(*) FROM init_gap_heal_targets
        \\WHERE task = ? AND protocol = ? AND completed = 0 AND attempts >= ?
    );
    defer q.deinit();
    try q.bindTextStatic(task);
    try q.bindTextStatic(protocol.toString());
    try q.bindInt(@intCast(max_attempts));
    if (try q.step()) return @intCast(q.getInt(0));
    return 0;
}
