//! Tests for the init-gap heal ledger (src/storage/heal_targets.zig): the
//! durable per-target accounting that replaced the task-level backfill_status
//! markers for resolver/subregistry init-gap sweeps. Clock-free: retry spacing
//! is driven by explicit timestamps, never wall time.

const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers");
const lib = @import("lib");

const TASK_A = "resolver_init_gaps";
const TASK_B = "subregistry_init_gaps";
const CAP: u32 = 8;
// A retry_before far past any timestamp used here: spacing never hides rows.
const ANY_TIME: i64 = 1_000_000;
// A per-cycle cap high enough never to bind: these tests assert queue semantics,
// not the cap. The cap itself is covered by its own test below.
const NO_LIMIT: usize = 10_000;

test "enqueue registers a target once; re-enqueue is a no-op" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const hex = try helpers.TEST_OWNER_1.toHex(allocator);
    defer allocator.free(hex);

    try database.enqueueHealTarget(TASK_A, .v2, hex);
    try database.enqueueHealTarget(TASK_A, .v2, hex);

    var pending = try database.pendingHealTargets(allocator, TASK_A, .v2, CAP, ANY_TIME, NO_LIMIT);
    defer pending.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), pending.items.len);
    try testing.expectEqualSlices(u8, &helpers.TEST_OWNER_1.bytes, &pending.items[0].addr.bytes);
    try testing.expect(try database.hasPendingHealTargets(.v2, CAP, ANY_TIME));
}

test "recorded success completes the target and survives re-enqueue" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const hex = try helpers.TEST_OWNER_1.toHex(allocator);
    defer allocator.free(hex);

    try database.enqueueHealTarget(TASK_A, .v2, hex);
    try database.recordHealTargetSuccess(TASK_A, .v2, hex);
    // A later seeding pass must not reopen a completed target.
    try database.enqueueHealTarget(TASK_A, .v2, hex);

    var pending = try database.pendingHealTargets(allocator, TASK_A, .v2, CAP, ANY_TIME, NO_LIMIT);
    defer pending.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), pending.items.len);
    try testing.expect(!(try database.hasPendingHealTargets(.v2, CAP, ANY_TIME)));
}

test "success without prior enqueue upserts a completed row" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const hex = try helpers.TEST_OWNER_1.toHex(allocator);
    defer allocator.free(hex);

    // Discovery-time success records directly, with no seeding beforehand.
    try database.recordHealTargetSuccess(TASK_B, .v2, hex);

    var pending = try database.pendingHealTargets(allocator, TASK_B, .v2, CAP, ANY_TIME, NO_LIMIT);
    defer pending.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), pending.items.len);
    try testing.expectEqual(@as(u32, 0), try database.countExhaustedHealTargets(TASK_B, .v2, CAP));
}

test "failure bumps attempts and creates the row when missing" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const hex = try helpers.TEST_OWNER_1.toHex(allocator);
    defer allocator.free(hex);

    // Discovery-time failure on a never-enqueued target creates it at attempt 1.
    try testing.expectEqual(@as(u32, 1), try database.recordHealTargetFailure(TASK_A, .v2, hex, 100));
    try testing.expectEqual(@as(u32, 2), try database.recordHealTargetFailure(TASK_A, .v2, hex, 200));

    var pending = try database.pendingHealTargets(allocator, TASK_A, .v2, CAP, ANY_TIME, NO_LIMIT);
    defer pending.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), pending.items.len);
}

test "retry spacing hides freshly failed targets until retry_before passes" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const hex = try helpers.TEST_OWNER_1.toHex(allocator);
    defer allocator.free(hex);

    try database.enqueueHealTarget(TASK_A, .v2, hex);
    _ = try database.recordHealTargetFailure(TASK_A, .v2, hex, 500);

    // retry_before earlier than the failure: target is resting.
    var resting = try database.pendingHealTargets(allocator, TASK_A, .v2, CAP, 499, NO_LIMIT);
    defer resting.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), resting.items.len);
    try testing.expect(!(try database.hasPendingHealTargets(.v2, CAP, 499)));

    // retry_before at/after the failure: due again.
    var due = try database.pendingHealTargets(allocator, TASK_A, .v2, CAP, 500, NO_LIMIT);
    defer due.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), due.items.len);
}

test "attempt cap parks a target and counts it exhausted" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const hex = try helpers.TEST_OWNER_1.toHex(allocator);
    defer allocator.free(hex);

    try database.enqueueHealTarget(TASK_A, .v2, hex);
    var attempt: i64 = 1;
    while (attempt <= CAP) : (attempt += 1) {
        _ = try database.recordHealTargetFailure(TASK_A, .v2, hex, attempt);
    }

    var pending = try database.pendingHealTargets(allocator, TASK_A, .v2, CAP, ANY_TIME, NO_LIMIT);
    defer pending.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), pending.items.len);
    try testing.expect(!(try database.hasPendingHealTargets(.v2, CAP, ANY_TIME)));
    try testing.expectEqual(@as(u32, 1), try database.countExhaustedHealTargets(TASK_A, .v2, CAP));
}

test "success after failures clears pending and exhausted" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const hex = try helpers.TEST_OWNER_1.toHex(allocator);
    defer allocator.free(hex);

    try database.enqueueHealTarget(TASK_A, .v2, hex);
    var attempt: i64 = 1;
    while (attempt <= CAP) : (attempt += 1) {
        _ = try database.recordHealTargetFailure(TASK_A, .v2, hex, attempt);
    }
    // Operator re-arm or a late sweep success must fully retire the target.
    try database.recordHealTargetSuccess(TASK_A, .v2, hex);

    var pending = try database.pendingHealTargets(allocator, TASK_A, .v2, CAP, ANY_TIME, NO_LIMIT);
    defer pending.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), pending.items.len);
    try testing.expectEqual(@as(u32, 0), try database.countExhaustedHealTargets(TASK_A, .v2, CAP));
}

test "failure on a completed target reopens it" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const hex = try helpers.TEST_OWNER_1.toHex(allocator);
    defer allocator.free(hex);

    try database.recordHealTargetSuccess(TASK_A, .v2, hex);
    try testing.expect(!(try database.hasPendingHealTargets(.v2, CAP, ANY_TIME)));

    // A later failure recorded against the same target (e.g. after a reorg
    // re-arm path re-swept it) must reopen it, never be silently absorbed.
    _ = try database.recordHealTargetFailure(TASK_A, .v2, hex, 100);

    var pending = try database.pendingHealTargets(allocator, TASK_A, .v2, CAP, ANY_TIME, NO_LIMIT);
    defer pending.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), pending.items.len);
}

test "reset re-arms completed and parked targets with a fresh budget" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const hex_1 = try helpers.TEST_OWNER_1.toHex(allocator);
    defer allocator.free(hex_1);
    const hex_2 = try helpers.TEST_OWNER_2.toHex(allocator);
    defer allocator.free(hex_2);

    // One completed target, one parked (attempts exhausted) target.
    try database.recordHealTargetSuccess(TASK_A, .v2, hex_1);
    try database.enqueueHealTarget(TASK_B, .v2, hex_2);
    var attempt: i64 = 1;
    while (attempt <= CAP) : (attempt += 1) {
        _ = try database.recordHealTargetFailure(TASK_B, .v2, hex_2, attempt);
    }
    try testing.expect(!(try database.hasPendingHealTargets(.v2, CAP, ANY_TIME)));

    // The reorg-rollback re-arm: both come back pending, exhausted count clears.
    // Rollback to 0 is the unconditional case — nothing can have a gap window
    // below it, so every target re-arms exactly as the old blanket reset did.
    try database.resetHealTargets(.v2, 0);
    var task_a = try database.pendingHealTargets(allocator, TASK_A, .v2, CAP, ANY_TIME, NO_LIMIT);
    defer task_a.deinit(allocator);
    var task_b = try database.pendingHealTargets(allocator, TASK_B, .v2, CAP, ANY_TIME, NO_LIMIT);
    defer task_b.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), task_a.items.len);
    try testing.expectEqual(@as(usize, 1), task_b.items.len);
    try testing.expectEqual(@as(u32, 0), try database.countExhaustedHealTargets(TASK_B, .v2, CAP));
}

test "addresses are canonicalized to one row regardless of input case" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    // Same address, different spellings. If canonicalization ever broke, the
    // success below would create a completed twin and leave the original row
    // pending — so the 0-pending assertion is the discriminating check.
    try database.enqueueHealTarget(TASK_A, .v2, "0xABABABABABABABABABABABABABABABABABABABAB");
    try database.recordHealTargetSuccess(TASK_A, .v2, "0xabababababababababababababababababababab");

    var pending = try database.pendingHealTargets(allocator, TASK_A, .v2, CAP, ANY_TIME, NO_LIMIT);
    defer pending.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), pending.items.len);
    try testing.expect(!(try database.hasPendingHealTargets(.v2, CAP, ANY_TIME)));

    // Garbage can never enter the ledger (a pending row the drain cannot
    // parse would hold the per-cycle gate open forever).
    try testing.expectError(error.InvalidHealTargetAddress, database.enqueueHealTarget(TASK_A, .v2, "not-an-address"));
    try testing.expect(!(try database.hasPendingHealTargets(.v2, CAP, ANY_TIME)));
}

test "tasks and protocols are isolated" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const hex_1 = try helpers.TEST_OWNER_1.toHex(allocator);
    defer allocator.free(hex_1);
    const hex_2 = try helpers.TEST_OWNER_2.toHex(allocator);
    defer allocator.free(hex_2);

    try database.enqueueHealTarget(TASK_A, .v2, hex_1);
    try database.enqueueHealTarget(TASK_B, .v2, hex_2);
    try database.enqueueHealTarget(TASK_A, .v1, hex_2);

    var task_a = try database.pendingHealTargets(allocator, TASK_A, .v2, CAP, ANY_TIME, NO_LIMIT);
    defer task_a.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), task_a.items.len);
    try testing.expectEqualSlices(u8, &helpers.TEST_OWNER_1.bytes, &task_a.items[0].addr.bytes);

    var task_b = try database.pendingHealTargets(allocator, TASK_B, .v2, CAP, ANY_TIME, NO_LIMIT);
    defer task_b.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), task_b.items.len);
    try testing.expectEqualSlices(u8, &helpers.TEST_OWNER_2.bytes, &task_b.items[0].addr.bytes);

    // Completing every v2 target leaves only the v1 row; the v2 gate goes quiet.
    try database.recordHealTargetSuccess(TASK_A, .v2, hex_1);
    try database.recordHealTargetSuccess(TASK_B, .v2, hex_2);
    try testing.expect(!(try database.hasPendingHealTargets(.v2, CAP, ANY_TIME)));
    try testing.expect(try database.hasPendingHealTargets(.v1, CAP, ANY_TIME));
}

// The sweep ceiling: pendingHealTargets LEFT JOINs the task's `known_*` table to
// report when each contract became known. That block bounds the init gap — the
// window of events emitted BEFORE the indexer knew the contract. Sweeping past
// it re-scans blocks the ordinary path already covered, which on staging meant
// ~9x the block ranges and ~25k redundant event dispatches per heal pass.
test "pendingHealTargets reports the contract's first-seen block as the sweep ceiling" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const hex = try helpers.TEST_OWNER_1.toHex(allocator);
    defer allocator.free(hex);

    try database.registerResolver(.v2, hex, 11_750_000);
    try database.enqueueHealTarget(TASK_A, .v2, hex);

    var pending = try database.pendingHealTargets(allocator, TASK_A, .v2, CAP, ANY_TIME, NO_LIMIT);
    defer pending.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), pending.items.len);
    try testing.expectEqual(@as(u64, 11_750_000), pending.items[0].first_seen_block);
}

test "pendingHealTargets returns 0 when no known_* row exists, so the caller widens to the head" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const hex = try helpers.TEST_OWNER_1.toHex(allocator);
    defer allocator.free(hex);

    // Enqueued but never registered: the join finds nothing.
    try database.enqueueHealTarget(TASK_A, .v2, hex);

    var pending = try database.pendingHealTargets(allocator, TASK_A, .v2, CAP, ANY_TIME, NO_LIMIT);
    defer pending.deinit(allocator);
    // The row must still come back — an INNER JOIN would drop it from the sweep
    // entirely, turning a redundant scan into a permanent init gap.
    try testing.expectEqual(@as(usize, 1), pending.items.len);
    try testing.expectEqual(@as(u64, 0), pending.items[0].first_seen_block);
}

test "pendingHealTargets scopes the first-seen join by protocol" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const hex = try helpers.TEST_OWNER_1.toHex(allocator);
    defer allocator.free(hex);

    // known_* is keyed (protocol, address): a v1 sighting must not supply a
    // ceiling for a v2 target, or the sweep would stop at the wrong block.
    try database.registerResolver(.v1, hex, 9_000_000);
    try database.enqueueHealTarget(TASK_A, .v2, hex);

    var pending = try database.pendingHealTargets(allocator, TASK_A, .v2, CAP, ANY_TIME, NO_LIMIT);
    defer pending.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), pending.items.len);
    try testing.expectEqual(@as(u64, 0), pending.items[0].first_seen_block);
}

test "pendingHealTargets joins the subregistry task against known_subregistries" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const hex = try helpers.TEST_OWNER_2.toHex(allocator);
    defer allocator.free(hex);

    try database.registerSubregistry(.v2, hex, 11_700_500, 11_700_500);
    try database.enqueueHealTarget(TASK_B, .v2, hex);

    var pending = try database.pendingHealTargets(allocator, TASK_B, .v2, CAP, ANY_TIME, NO_LIMIT);
    defer pending.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), pending.items.len);
    try testing.expectEqual(@as(u64, 11_700_500), pending.items[0].first_seen_block);
}

// The reorg re-arm, narrowed. A heal sweep stops at the contract's first-seen
// block, so a target whose whole gap window sits at or below the rollback point
// wrote nothing the created-after deletes could reach — its `completed` marker
// is still honest. Re-arming it anyway cost a full re-sweep per reorg: on
// staging one 1-block Sepolia reorg re-opened 2,406 targets and blocked
// head-following for 54 minutes.
test "rollback re-arm skips targets whose gap window ends below the rollback point" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const hex = try helpers.TEST_OWNER_1.toHex(allocator);
    defer allocator.free(hex);

    // Swept window is [anchor, 11_750_000-1]; the rollback lands far above it.
    try database.registerResolver(.v2, hex, 11_750_000);
    try database.enqueueHealTarget(TASK_A, .v2, hex);
    try database.recordHealTargetSuccess(TASK_A, .v2, hex);

    try database.resetHealTargets(.v2, 11_813_276);

    var pending = try database.pendingHealTargets(allocator, TASK_A, .v2, CAP, ANY_TIME, NO_LIMIT);
    defer pending.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), pending.items.len);
}

test "rollback re-arm reopens a target whose gap window reaches above the rollback point" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const hex = try helpers.TEST_OWNER_1.toHex(allocator);
    defer allocator.free(hex);

    // first_seen 600 => the sweep could have written up to 599. A rollback to
    // 500 may have deleted rows in 501..599, which no re-index will recreate.
    try database.registerResolver(.v2, hex, 600);
    try database.enqueueHealTarget(TASK_A, .v2, hex);
    try database.recordHealTargetSuccess(TASK_A, .v2, hex);

    try database.resetHealTargets(.v2, 500);

    var pending = try database.pendingHealTargets(allocator, TASK_A, .v2, CAP, ANY_TIME, NO_LIMIT);
    defer pending.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), pending.items.len);
}

test "rollback re-arm boundary: a window ending exactly at the rollback point is left alone" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const hex = try helpers.TEST_OWNER_1.toHex(allocator);
    defer allocator.free(hex);

    // first_seen 501 => highest written block 500 == the rollback point, which
    // the created-after deletes (strictly greater than) never touch.
    try database.registerResolver(.v2, hex, 501);
    try database.enqueueHealTarget(TASK_A, .v2, hex);
    try database.recordHealTargetSuccess(TASK_A, .v2, hex);
    try database.resetHealTargets(.v2, 500);

    var kept = try database.pendingHealTargets(allocator, TASK_A, .v2, CAP, ANY_TIME, NO_LIMIT);
    defer kept.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), kept.items.len);

    // One block higher must reopen. A second address, because first_seen_block is
    // deliberately immutable on conflict — registerResolver records the FIRST
    // sighting, which is exactly the property the ceiling relies on.
    const hex2 = try helpers.TEST_OWNER_2.toHex(allocator);
    defer allocator.free(hex2);
    try database.registerResolver(.v2, hex2, 502);
    try database.enqueueHealTarget(TASK_A, .v2, hex2);
    try database.recordHealTargetSuccess(TASK_A, .v2, hex2);

    try database.resetHealTargets(.v2, 500);
    var reopened = try database.pendingHealTargets(allocator, TASK_A, .v2, CAP, ANY_TIME, NO_LIMIT);
    defer reopened.deinit(allocator);
    // Only the 502 target comes back; the 501 one is still correctly skipped.
    try testing.expectEqual(@as(usize, 1), reopened.items.len);
    try testing.expectEqualSlices(u8, &helpers.TEST_OWNER_2.bytes, &reopened.items[0].addr.bytes);
}

test "rollback re-arm reopens a target with no known_* row (unknown window, fail safe)" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const hex = try helpers.TEST_OWNER_1.toHex(allocator);
    defer allocator.free(hex);

    // Never registered: without a ceiling the sweep ran to the head, so it could
    // have written anywhere. Must re-arm.
    try database.enqueueHealTarget(TASK_A, .v2, hex);
    try database.recordHealTargetSuccess(TASK_A, .v2, hex);

    try database.resetHealTargets(.v2, 11_813_276);

    var pending = try database.pendingHealTargets(allocator, TASK_A, .v2, CAP, ANY_TIME, NO_LIMIT);
    defer pending.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), pending.items.len);
}

test "rollback re-arm still resets attempts on a skipped target" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const hex = try helpers.TEST_OWNER_2.toHex(allocator);
    defer allocator.free(hex);

    // A target below the rollback point keeps `completed`, but a prior failure
    // still says nothing about the surviving chain, so attempts must clear —
    // that was the old semantics and narrowing must not change it.
    try database.registerSubregistry(.v2, hex, 11_700_500, 11_700_500);
    try database.enqueueHealTarget(TASK_B, .v2, hex);
    var attempt: i64 = 1;
    while (attempt <= CAP) : (attempt += 1) {
        _ = try database.recordHealTargetFailure(TASK_B, .v2, hex, attempt);
    }
    try testing.expectEqual(@as(u32, 1), try database.countExhaustedHealTargets(TASK_B, .v2, CAP));

    try database.resetHealTargets(.v2, 11_813_276);
    try testing.expectEqual(@as(u32, 0), try database.countExhaustedHealTargets(TASK_B, .v2, CAP));
}

// The per-cycle target cap. The drain runs inside the sync loop, so an unbounded
// pass is time the indexer spends not following the chain head. The cap bounds
// the anchor-bisection phase specifically, which runs over every target in the
// slice before the first group sweeps.
test "pendingHealTargets caps a cycle's slice and resumes from the ledger" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    // Five targets, deterministic address order.
    var hexes: [5][]u8 = undefined;
    for (&hexes, 0..) |*h, i| {
        var addr = helpers.TEST_OWNER_1;
        addr.bytes[19] = @intCast(i + 1);
        h.* = try addr.toHex(allocator);
        try database.enqueueHealTarget(TASK_A, .v2, h.*);
    }
    defer for (hexes) |h| allocator.free(h);

    var first = try database.pendingHealTargets(allocator, TASK_A, .v2, CAP, ANY_TIME, 2);
    defer first.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), first.items.len);

    // Completing that slice advances the window: the ledger is the resume state,
    // so no extra bookkeeping is needed to continue where the cycle stopped.
    for (first.items) |t| {
        const hex = try t.addr.toHex(allocator);
        defer allocator.free(hex);
        try database.recordHealTargetSuccess(TASK_A, .v2, hex);
    }

    var second = try database.pendingHealTargets(allocator, TASK_A, .v2, CAP, ANY_TIME, 2);
    defer second.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), second.items.len);
    // Different targets from the first slice.
    for (second.items) |t2| {
        for (first.items) |t1| try testing.expect(!std.mem.eql(u8, &t1.addr.bytes, &t2.addr.bytes));
    }

    // The tail comes back on the third cycle, and nothing is lost.
    for (second.items) |t| {
        const hex = try t.addr.toHex(allocator);
        defer allocator.free(hex);
        try database.recordHealTargetSuccess(TASK_A, .v2, hex);
    }
    var third = try database.pendingHealTargets(allocator, TASK_A, .v2, CAP, ANY_TIME, 2);
    defer third.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), third.items.len);
}
