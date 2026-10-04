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
/// A target owed a sweep, with the block at which the contract became known.
///
/// `first_seen_block` is the sweep's CEILING: the init gap is exactly the events
/// a contract emitted before the indexer knew about it, so everything from
/// `first_seen_block` onward was already indexed by the ordinary path. 0 means
/// the join found no row, and the caller must fall back to the sync head rather
/// than treat it as "sweep nothing".
pub const PendingTarget = struct {
    addr: Address,
    first_seen_block: u64,
};

/// Task → the `known_*` table recording when each of its contracts was first
/// seen. One source of truth: both the ceiling join and the rollback re-arm read
/// it, and a task missing from here keeps the unbounded behaviour in both.
const FIRST_SEEN_TABLES = .{
    .{ "resolver_init_gaps", "known_resolvers" },
    .{ "subregistry_init_gaps", "known_subregistries" },
};

/// The `known_*` table for a task, or null when it has none — in which case
/// every target falls back to the sync head.
fn firstSeenTable(task: []const u8) ?[]const u8 {
    inline for (FIRST_SEEN_TABLES) |pair| {
        if (std.mem.eql(u8, task, pair[0])) return pair[1];
    }
    return null;
}

/// `max_targets` bounds one cycle's slice of the queue. It exists because the
/// anchor-bisection phase runs over EVERY target before the first group sweeps,
/// so a wall-clock budget on the sweep alone cannot bound a pass: 1,724 targets
/// cost ~128 s of eth_getCode probes up front. Ordering is by address, so the
/// window is deterministic, and the attempts/retry-spacing filters move failing
/// rows out of it rather than letting them starve the rest.
pub fn pendingHealTargets(db: *Database, allocator: std.mem.Allocator, task: []const u8, protocol: models.Protocol, max_attempts: u32, retry_before: i64, max_targets: usize) !std.ArrayList(PendingTarget) {
    var targets: std.ArrayList(PendingTarget) = .empty;
    errdefer targets.deinit(allocator);

    // LEFT JOIN, deliberately: a target with no `known_*` row must come back with
    // first_seen_block = 0 so the caller falls back to the sync head. An INNER
    // JOIN would silently drop it from the sweep — a permanent init gap.
    const sql = if (firstSeenTable(task)) |tbl|
        try std.fmt.allocPrint(
            db.allocator,
            "SELECT t.address, COALESCE(k.first_seen_block, 0) FROM init_gap_heal_targets t " ++
                "LEFT JOIN {s} k ON k.address = t.address AND k.protocol = t.protocol " ++
                "WHERE t.task = ? AND t.protocol = ? AND t.completed = 0 AND t.attempts < ? AND t.last_error_at <= ? " ++
                "ORDER BY t.address LIMIT ?",
            .{tbl},
        )
    else
        try db.allocator.dupe(u8, "SELECT address, 0 FROM init_gap_heal_targets " ++
            "WHERE task = ? AND protocol = ? AND completed = 0 AND attempts < ? AND last_error_at <= ? " ++
            "ORDER BY address");
    defer db.allocator.free(sql);

    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindTextStatic(task);
    try q.bindTextStatic(protocol.toString());
    try q.bindInt(@intCast(max_attempts));
    try q.bindInt64(retry_before);
    try q.bindInt64(@intCast(max_targets));
    while (try q.step()) {
        const addr_slice = q.getTextSlice(0) orelse continue;
        const addr = Address.fromHex(addr_slice) catch continue;
        const first_seen = q.getInt64(1);
        try targets.append(allocator, .{
            .addr = addr,
            .first_seen_block = if (first_seen > 0) @intCast(first_seen) else 0,
        });
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
pub fn resetHealTargets(db: *Database, protocol: models.Protocol, rollback_block: u64) !void {
    // Only targets whose sweep could have written a row the rollback deleted AND
    // that the ordinary path will NOT re-create need re-arming.
    //
    // A sweep covers [anchor, first_seen_block-1] — the window before the
    // indexer knew the contract. So:
    //   * rows it wrote sit at or below first_seen_block-1. If that is <= the
    //     rollback point, the created-after deletes could not have touched them,
    //     and the `completed` marker is still honest.
    //   * a group sweeps to its highest member's ceiling, so a low-ceiling member
    //     can see events ABOVE its own ceiling. Those are at or above its
    //     first_seen_block, which means the ordinary path indexed them too — and
    //     rollbackToBlock rewinds sync_state to `rollback_block` immediately
    //     after this call, so re-indexing recreates them. They need no re-arm.
    // Hence: re-arm iff first_seen_block - 1 > rollback_block.
    //
    // Fail safe in the unknown direction: first_seen_block 0 (no known_* row)
    // re-arms, because without a ceiling the sweep runs to the head and could
    // have written anywhere. Passing rollback_block = 0 re-arms everything,
    // which is the old blanket behaviour.
    //
    // `attempts`/`last_error_at` still reset for every row regardless: a prior
    // failure says nothing about the surviving chain, and that was the old
    // semantics too.
    inline for (FIRST_SEEN_TABLES) |pair| {
        const task = pair[0];
        const first_seen = "COALESCE((SELECT k.first_seen_block FROM " ++ pair[1] ++ " k " ++
            "WHERE k.address = init_gap_heal_targets.address " ++
            "AND k.protocol = init_gap_heal_targets.protocol), 0)";
        const sql = "UPDATE init_gap_heal_targets SET completed = CASE WHEN " ++
            first_seen ++ " = 0 OR " ++ first_seen ++ " > ? + 1 THEN 0 ELSE completed END, " ++
            "attempts = 0, last_error_at = 0 WHERE protocol = ? AND task = ?";
        var q = try Query.init(db, sql);
        defer q.deinit();
        try q.bindInt64(@intCast(rollback_block));
        try q.bindTextStatic(protocol.toString());
        try q.bindTextStatic(task);
        try q.exec();
    }

    // Any other task has no first-seen table to bound it, so it keeps the
    // unconditional re-arm.
    {
        var q = try Query.init(db,
            \\UPDATE init_gap_heal_targets
            \\SET completed = 0, attempts = 0, last_error_at = 0
            \\WHERE protocol = ? AND task NOT IN ('resolver_init_gaps', 'subregistry_init_gaps')
        );
        defer q.deinit();
        try q.bindTextStatic(protocol.toString());
        try q.exec();
    }
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
