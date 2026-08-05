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

test "enqueue registers a target once; re-enqueue is a no-op" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const hex = try helpers.TEST_OWNER_1.toHex(allocator);
    defer allocator.free(hex);

    try database.enqueueHealTarget(TASK_A, .v2, hex);
    try database.enqueueHealTarget(TASK_A, .v2, hex);

    var pending = try database.pendingHealTargets(allocator, TASK_A, .v2, CAP, ANY_TIME);
    defer pending.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), pending.items.len);
    try testing.expectEqualSlices(u8, &helpers.TEST_OWNER_1.bytes, &pending.items[0].bytes);
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

    var pending = try database.pendingHealTargets(allocator, TASK_A, .v2, CAP, ANY_TIME);
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

    var pending = try database.pendingHealTargets(allocator, TASK_B, .v2, CAP, ANY_TIME);
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

    var pending = try database.pendingHealTargets(allocator, TASK_A, .v2, CAP, ANY_TIME);
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
    var resting = try database.pendingHealTargets(allocator, TASK_A, .v2, CAP, 499);
    defer resting.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), resting.items.len);
    try testing.expect(!(try database.hasPendingHealTargets(.v2, CAP, 499)));

    // retry_before at/after the failure: due again.
    var due = try database.pendingHealTargets(allocator, TASK_A, .v2, CAP, 500);
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

    var pending = try database.pendingHealTargets(allocator, TASK_A, .v2, CAP, ANY_TIME);
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

    var pending = try database.pendingHealTargets(allocator, TASK_A, .v2, CAP, ANY_TIME);
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

    var pending = try database.pendingHealTargets(allocator, TASK_A, .v2, CAP, ANY_TIME);
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
    try database.resetHealTargets(.v2);
    var task_a = try database.pendingHealTargets(allocator, TASK_A, .v2, CAP, ANY_TIME);
    defer task_a.deinit(allocator);
    var task_b = try database.pendingHealTargets(allocator, TASK_B, .v2, CAP, ANY_TIME);
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

    var pending = try database.pendingHealTargets(allocator, TASK_A, .v2, CAP, ANY_TIME);
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

    var task_a = try database.pendingHealTargets(allocator, TASK_A, .v2, CAP, ANY_TIME);
    defer task_a.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), task_a.items.len);
    try testing.expectEqualSlices(u8, &helpers.TEST_OWNER_1.bytes, &task_a.items[0].bytes);

    var task_b = try database.pendingHealTargets(allocator, TASK_B, .v2, CAP, ANY_TIME);
    defer task_b.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), task_b.items.len);
    try testing.expectEqualSlices(u8, &helpers.TEST_OWNER_2.bytes, &task_b.items[0].bytes);

    // Completing every v2 target leaves only the v1 row; the v2 gate goes quiet.
    try database.recordHealTargetSuccess(TASK_A, .v2, hex_1);
    try database.recordHealTargetSuccess(TASK_B, .v2, hex_2);
    try testing.expect(!(try database.hasPendingHealTargets(.v2, CAP, ANY_TIME)));
    try testing.expect(try database.hasPendingHealTargets(.v1, CAP, ANY_TIME));
}
