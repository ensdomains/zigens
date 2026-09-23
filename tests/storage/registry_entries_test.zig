/// Tests for the on-chain Entry mirror + reachability cascade introduced in
/// migration 025 to fix orphaned descendants on subregistry repoint.
///
/// These exercise the storage layer directly (`upsertSubregistry`,
/// `collectSubtreeRooted`, `setRegistriesReachability`) — i.e. the primitives
/// the V2 SubregistryUpdated handler uses to invalidate Domain rows when a
/// parent label repoints its subregistry pointer. Driver-level handler tests
/// would require RPC log fixtures; these isolate the invariants that matter
/// for the bug fix.
const std = @import("std");
const testing = std.testing;
const lib = @import("lib");
const helpers = @import("helpers");
const Database = lib.Database;
const Address = lib.Address;
const Hash = lib.Hash;
const models = lib.models;

const ETH_REGISTRY = Address{ .bytes = [_]u8{0xE7} ** 20 };
const SUB_A = Address{ .bytes = [_]u8{0xAA} ** 20 };
const SUB_B = Address{ .bytes = [_]u8{0xBB} ** 20 };
const SUB_A1 = Address{ .bytes = [_]u8{0xA1} ** 20 };
const OWNER_1 = helpers.TEST_OWNER_1;

const FRESH_CANONICAL_ID: u256 = 0xF1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1_00000000;
const ONE_CANONICAL_ID: u256 = 0x0101010101010101010101010101010101010101010101010101010101_000000;

/// Build a Name record under a given subregistry for use as a "descendant of A".
/// `parent_name` is plain text ("fresh.eth"); the full name is built as
/// `<label>.<parent_name>`.
fn insertChildName(
    allocator: std.mem.Allocator,
    database: *Database,
    label: []const u8,
    parent_name: []const u8,
    subregistry: Address,
    owner: Address,
    token_id: u256,
) !Hash {
    const full_name = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ label, parent_name });
    defer allocator.free(full_name);

    const nh = try lib.namehash(allocator, full_name);
    const parent_nh = try lib.namehash(allocator, parent_name);
    const label_hash = try lib.labelhash(allocator, label);

    try database.insertName(models.Name{
        .name = full_name,
        .namehash = nh,
        .label = label,
        .label_hash = label_hash,
        .parent_name = parent_name,
        .parent_namehash = parent_nh,
        .protocol = .v2,
        .registry = subregistry,
        .owner = owner,
        .registrant = owner,
        .resolver = Address.zero,
        .token_id = token_id,
        .canonical_id = token_id & ~@as(u256, 0xFFFFFFFF),
        .token_version = @intCast(token_id & 0xFFFFFFFF),
        .expiry = 0,
        .registry_locked = false,
        .migrated = false,
        .created_block = 1000,
        .created_at = 1700000000,
        .registered_at = 1700000000,
        .updated_block = 1000,
        .updated_at = 1700000000,
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    });
    return nh;
}

test "upsertSubregistry returns prev=0 on initial pointer set (paired with LabelRegistered _register call)" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    // Initial SubregistryUpdated fired from `_register` with no prior entry:
    // prev should be Address.zero, signaling "not a repoint, do not cascade".
    const prev = try database.upsertRegistryEntrySubregistry(.v2, ETH_REGISTRY, FRESH_CANONICAL_ID, SUB_A, 1000, 1700000000);
    try testing.expect(prev.isZero());

    // Sanity: read-back matches.
    const stored = try database.getRegistryEntrySubregistry(.v2, ETH_REGISTRY, FRESH_CANONICAL_ID);
    try testing.expect(stored.eql(SUB_A));
}

test "upsertSubregistry returns prev=A on repoint A → B" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    _ = try database.upsertRegistryEntrySubregistry(.v2, ETH_REGISTRY, FRESH_CANONICAL_ID, SUB_A, 1000, 1700000000);

    const prev = try database.upsertRegistryEntrySubregistry(.v2, ETH_REGISTRY, FRESH_CANONICAL_ID, SUB_B, 1001, 1700000600);
    try testing.expect(prev.eql(SUB_A));

    const stored = try database.getRegistryEntrySubregistry(.v2, ETH_REGISTRY, FRESH_CANONICAL_ID);
    try testing.expect(stored.eql(SUB_B));
}

test "collectSubtreeRooted returns only the root when no descendants are tracked" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const subtree = try database.collectSubregistrySubtree(allocator, .v2, SUB_A);
    defer allocator.free(subtree);
    try testing.expectEqual(@as(usize, 1), subtree.len);
    try testing.expect(subtree[0].eql(SUB_A));
}

test "collectSubtreeRooted walks multi-level subregistry chains A → A1" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    // .eth → fresh entry points to A
    _ = try database.upsertRegistryEntrySubregistry(.v2, ETH_REGISTRY, FRESH_CANONICAL_ID, SUB_A, 1000, 1700000000);
    // A → "1" entry points to A1
    _ = try database.upsertRegistryEntrySubregistry(.v2, SUB_A, ONE_CANONICAL_ID, SUB_A1, 1001, 1700000060);

    const subtree = try database.collectSubregistrySubtree(allocator, .v2, SUB_A);
    defer allocator.free(subtree);

    try testing.expectEqual(@as(usize, 2), subtree.len);
    // Root first, then descendant (BFS order)
    try testing.expect(subtree[0].eql(SUB_A));
    try testing.expect(subtree[1].eql(SUB_A1));
}

test "scenario 1: register foo on A while fresh→A; foo is reachable" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    _ = try database.upsertRegistryEntrySubregistry(.v2, ETH_REGISTRY, FRESH_CANONICAL_ID, SUB_A, 1000, 1700000000);
    const foo_nh = try insertChildName(allocator, database, "foo", "fresh.eth", SUB_A, OWNER_1, 0x1100);

    const found = try database.getNameByNamehash(foo_nh);
    try testing.expect(found != null);
    var n = found.?;
    defer n.deinit(allocator);
    try testing.expect(n.is_reachable);
    try testing.expect(n.registry.eql(SUB_A));
}

test "scenario 2: setSubregistry(fresh, B) where B != A marks foo.fresh.eth unreachable" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    _ = try database.upsertRegistryEntrySubregistry(.v2, ETH_REGISTRY, FRESH_CANONICAL_ID, SUB_A, 1000, 1700000000);
    const foo_nh = try insertChildName(allocator, database, "foo", "fresh.eth", SUB_A, OWNER_1, 0x1100);

    // Repoint
    const prev = try database.upsertRegistryEntrySubregistry(.v2, ETH_REGISTRY, FRESH_CANONICAL_ID, SUB_B, 1002, 1700000120);
    try testing.expect(prev.eql(SUB_A));

    // Handler logic: collect A's subtree (just [A] here) and invalidate.
    const subtree = try database.collectSubregistrySubtree(allocator, .v2, SUB_A);
    defer allocator.free(subtree);
    _ = try database.setRegistriesReachability(.v2, subtree, false, 1002, 1700000120);

    const found = try database.getNameByNamehash(foo_nh);
    try testing.expect(found != null);
    var n = found.?;
    defer n.deinit(allocator);
    try testing.expect(!n.is_reachable);
    try testing.expect(n.unreachable_since != null);
    try testing.expectEqual(@as(i64, 1700000120), n.unreachable_since.?);
}

test "scenario 3: setSubregistry(fresh, A) again reactivates foo.fresh.eth" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    _ = try database.upsertRegistryEntrySubregistry(.v2, ETH_REGISTRY, FRESH_CANONICAL_ID, SUB_A, 1000, 1700000000);
    const foo_nh = try insertChildName(allocator, database, "foo", "fresh.eth", SUB_A, OWNER_1, 0x1100);

    // Repoint to B, invalidate.
    _ = try database.upsertRegistryEntrySubregistry(.v2, ETH_REGISTRY, FRESH_CANONICAL_ID, SUB_B, 1002, 1700000120);
    {
        const subtree = try database.collectSubregistrySubtree(allocator, .v2, SUB_A);
        defer allocator.free(subtree);
        _ = try database.setRegistriesReachability(.v2, subtree, false, 1002, 1700000120);
    }

    // Re-point back to A, reactivate.
    _ = try database.upsertRegistryEntrySubregistry(.v2, ETH_REGISTRY, FRESH_CANONICAL_ID, SUB_A, 1003, 1700000240);
    {
        const subtree = try database.collectSubregistrySubtree(allocator, .v2, SUB_A);
        defer allocator.free(subtree);
        _ = try database.setRegistriesReachability(.v2, subtree, true, 1003, 1700000240);
    }

    const found = try database.getNameByNamehash(foo_nh);
    try testing.expect(found != null);
    var n = found.?;
    defer n.deinit(allocator);
    try testing.expect(n.is_reachable);
    try testing.expect(n.unreachable_since == null);
}

test "scenario 5: foo on A (orphaned) and bar on B (reachable) coexist with different reachability" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    // fresh.eth → A; register foo under A.
    _ = try database.upsertRegistryEntrySubregistry(.v2, ETH_REGISTRY, FRESH_CANONICAL_ID, SUB_A, 1000, 1700000000);
    const foo_nh = try insertChildName(allocator, database, "foo", "fresh.eth", SUB_A, OWNER_1, 0x1100);

    // Repoint fresh to B and invalidate A's subtree.
    _ = try database.upsertRegistryEntrySubregistry(.v2, ETH_REGISTRY, FRESH_CANONICAL_ID, SUB_B, 1002, 1700000120);
    {
        const subtree = try database.collectSubregistrySubtree(allocator, .v2, SUB_A);
        defer allocator.free(subtree);
        _ = try database.setRegistriesReachability(.v2, subtree, false, 1002, 1700000120);
    }

    // Register bar under B (the new active subregistry).
    const bar_nh = try insertChildName(allocator, database, "bar", "fresh.eth", SUB_B, OWNER_1, 0x2200);

    const foo = try database.getNameByNamehash(foo_nh);
    try testing.expect(foo != null);
    var f = foo.?;
    defer f.deinit(allocator);
    try testing.expect(!f.is_reachable);

    const bar = try database.getNameByNamehash(bar_nh);
    try testing.expect(bar != null);
    var b = bar.?;
    defer b.deinit(allocator);
    try testing.expect(b.is_reachable);
}

test "scenario 6: multi-level A→A1, repoint fresh to B invalidates both 1.fresh.eth and bar.1.fresh.eth" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    // fresh.eth → A; A's "1" entry → A1.
    _ = try database.upsertRegistryEntrySubregistry(.v2, ETH_REGISTRY, FRESH_CANONICAL_ID, SUB_A, 1000, 1700000000);
    _ = try database.upsertRegistryEntrySubregistry(.v2, SUB_A, ONE_CANONICAL_ID, SUB_A1, 1001, 1700000060);

    const one_nh = try insertChildName(allocator, database, "1", "fresh.eth", SUB_A, OWNER_1, 0x1100);
    const bar_nh = try insertChildName(allocator, database, "bar", "1.fresh.eth", SUB_A1, OWNER_1, 0x2200);

    // Repoint fresh to B and cascade.
    _ = try database.upsertRegistryEntrySubregistry(.v2, ETH_REGISTRY, FRESH_CANONICAL_ID, SUB_B, 1002, 1700000120);
    const subtree = try database.collectSubregistrySubtree(allocator, .v2, SUB_A);
    defer allocator.free(subtree);
    try testing.expectEqual(@as(usize, 2), subtree.len);
    _ = try database.setRegistriesReachability(.v2, subtree, false, 1002, 1700000120);

    const one = try database.getNameByNamehash(one_nh);
    try testing.expect(one != null);
    var o = one.?;
    defer o.deinit(allocator);
    try testing.expect(!o.is_reachable);

    const bar = try database.getNameByNamehash(bar_nh);
    try testing.expect(bar != null);
    var b = bar.?;
    defer b.deinit(allocator);
    try testing.expect(!b.is_reachable);
}

test "scenario 9: initial SubregistryUpdated (prev=0) does not flip anything" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    // Pre-existing name with is_reachable=true (would be created earlier in the same tx
    // by LabelRegistered) — must not be invalidated by the initial pointer set.
    const fresh_nh = try insertChildName(allocator, database, "fresh", "eth", ETH_REGISTRY, OWNER_1, FRESH_CANONICAL_ID);

    // Initial pointer set: prev should be 0, so handler skips cascade.
    const prev = try database.upsertRegistryEntrySubregistry(.v2, ETH_REGISTRY, FRESH_CANONICAL_ID, SUB_A, 1000, 1700000000);
    try testing.expect(prev.isZero());

    const stored = try database.getNameByNamehash(fresh_nh);
    try testing.expect(stored != null);
    var n = stored.?;
    defer n.deinit(allocator);
    try testing.expect(n.is_reachable);
}

test "default getFilteredNames hides unreachable names; includeUnreachable surfaces them" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    _ = try database.upsertRegistryEntrySubregistry(.v2, ETH_REGISTRY, FRESH_CANONICAL_ID, SUB_A, 1000, 1700000000);
    _ = try insertChildName(allocator, database, "foo", "fresh.eth", SUB_A, OWNER_1, 0x1100);

    // Default — both reachable.
    {
        const found = try database.getFilteredNames(.{ .name_ends_with = ".fresh.eth" }, 0, 50, .desc, .created_at);
        defer {
            for (found) |*n| n.deinit(allocator);
            allocator.free(found);
        }
        try testing.expectEqual(@as(usize, 1), found.len);
    }

    // Repoint → invalidate.
    _ = try database.upsertRegistryEntrySubregistry(.v2, ETH_REGISTRY, FRESH_CANONICAL_ID, SUB_B, 1002, 1700000120);
    const subtree = try database.collectSubregistrySubtree(allocator, .v2, SUB_A);
    defer allocator.free(subtree);
    _ = try database.setRegistriesReachability(.v2, subtree, false, 1002, 1700000120);

    // Default — foo hidden.
    {
        const found = try database.getFilteredNames(.{ .name_ends_with = ".fresh.eth" }, 0, 50, .desc, .created_at);
        defer {
            for (found) |*n| n.deinit(allocator);
            allocator.free(found);
        }
        try testing.expectEqual(@as(usize, 0), found.len);
    }

    // includeUnreachable — foo visible, marked unreachable.
    {
        const found = try database.getFilteredNames(.{ .name_ends_with = ".fresh.eth", .include_unreachable = true }, 0, 50, .desc, .created_at);
        defer {
            for (found) |*n| n.deinit(allocator);
            allocator.free(found);
        }
        try testing.expectEqual(@as(usize, 1), found.len);
        try testing.expect(!found[0].is_reachable);
    }
}

test "getSubdomains excludes unreachable rows by default" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    _ = try database.upsertRegistryEntrySubregistry(.v2, ETH_REGISTRY, FRESH_CANONICAL_ID, SUB_A, 1000, 1700000000);
    _ = try insertChildName(allocator, database, "foo", "fresh.eth", SUB_A, OWNER_1, 0x1100);
    _ = try insertChildName(allocator, database, "bar", "fresh.eth", SUB_A, OWNER_1, 0x2200);

    {
        const subs = try database.getSubdomains("fresh.eth", 0, 50);
        defer {
            for (subs) |*n| n.deinit(allocator);
            allocator.free(subs);
        }
        try testing.expectEqual(@as(usize, 2), subs.len);
    }

    _ = try database.upsertRegistryEntrySubregistry(.v2, ETH_REGISTRY, FRESH_CANONICAL_ID, SUB_B, 1002, 1700000120);
    const subtree = try database.collectSubregistrySubtree(allocator, .v2, SUB_A);
    defer allocator.free(subtree);
    _ = try database.setRegistriesReachability(.v2, subtree, false, 1002, 1700000120);

    const subs = try database.getSubdomains("fresh.eth", 0, 50);
    defer {
        for (subs) |*n| n.deinit(allocator);
        allocator.free(subs);
    }
    try testing.expectEqual(@as(usize, 0), subs.len);
}

// ============================================================================
// Audit #37: the "Multi-parent subregistry" warning is gated on the
// registry_entries LIVE mirror (getLiveParents), not the append-only
// `registries` history the handlers' reverse-lookup reads. These pin the
// gate's decision input for both sides: a true simultaneous multi-parent
// yields both conflicting pairs; a benign sequential repoint yields one.
// ============================================================================

test "getLiveParents: true simultaneous multi-parent returns both conflicting pairs" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const PARENT_2 = Address{ .bytes = [_]u8{0xE8} ** 20 };

    // Two different (parent, canonical_id) entries point at SUB_A at once —
    // the VerifiableFactory one-instance-per-name convention violation.
    _ = try database.upsertRegistryEntrySubregistry(.v2, ETH_REGISTRY, FRESH_CANONICAL_ID, SUB_A, 1000, 1700000000);
    _ = try database.upsertRegistryEntrySubregistry(.v2, PARENT_2, ONE_CANONICAL_ID, SUB_A, 1001, 1700000001);

    var sub_hex_buf: [42]u8 = undefined;
    const sub_hex = SUB_A.toHexBuf(&sub_hex_buf);
    const parents = try database.getRegistryEntryLiveParents(allocator, .v2, sub_hex);
    defer lib.storage.registry_entries.freeLiveParents(allocator, parents);

    try testing.expectEqual(@as(usize, 2), parents.len);
    var parent1_hex_buf: [42]u8 = undefined;
    var parent2_hex_buf: [42]u8 = undefined;
    const p1 = ETH_REGISTRY.toHexBuf(&parent1_hex_buf);
    const p2 = PARENT_2.toHexBuf(&parent2_hex_buf);
    // Newest-first (updated_block DESC): PARENT_2 then ETH_REGISTRY.
    try testing.expectEqualStrings(p2, parents[0].parent_registry);
    try testing.expectEqualStrings(p1, parents[1].parent_registry);
    try testing.expect(parents[0].canonical_id.len == 66);
}

test "getLiveParents: benign sequential repoint leaves exactly one live parent" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const PARENT_2 = Address{ .bytes = [_]u8{0xE8} ** 20 };

    // History: ETH_REGISTRY pointed at SUB_A, then repointed away to SUB_B
    // (in-place entry update); later PARENT_2 claims SUB_A. The `registries`
    // table would now show two historical parents for SUB_A (the old
    // false-positive); the live mirror must show exactly one.
    _ = try database.upsertRegistryEntrySubregistry(.v2, ETH_REGISTRY, FRESH_CANONICAL_ID, SUB_A, 1000, 1700000000);
    _ = try database.upsertRegistryEntrySubregistry(.v2, ETH_REGISTRY, FRESH_CANONICAL_ID, SUB_B, 1010, 1700000010);
    _ = try database.upsertRegistryEntrySubregistry(.v2, PARENT_2, ONE_CANONICAL_ID, SUB_A, 1020, 1700000020);

    var sub_hex_buf: [42]u8 = undefined;
    const sub_hex = SUB_A.toHexBuf(&sub_hex_buf);
    const parents = try database.getRegistryEntryLiveParents(allocator, .v2, sub_hex);
    defer lib.storage.registry_entries.freeLiveParents(allocator, parents);

    try testing.expectEqual(@as(usize, 1), parents.len);
    var parent2_hex_buf: [42]u8 = undefined;
    try testing.expectEqualStrings(PARENT_2.toHexBuf(&parent2_hex_buf), parents[0].parent_registry);

    // And after the only live parent also repoints away, zero remain.
    _ = try database.upsertRegistryEntrySubregistry(.v2, PARENT_2, ONE_CANONICAL_ID, SUB_B, 1030, 1700000030);
    const none = try database.getRegistryEntryLiveParents(allocator, .v2, sub_hex);
    defer lib.storage.registry_entries.freeLiveParents(allocator, none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "subregistry_pointer filter: getFilteredNames returns names referencing a registry (RegistryInfo.referencedBy)" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const PARENT = Address{ .bytes = [_]u8{0xE7} ** 20 }; // registry that minted these names
    const TARGET = Address{ .bytes = [_]u8{0x46} ** 20 }; // the subregistry under test
    const OTHER = Address{ .bytes = [_]u8{0xCC} ** 20 };

    const t1: u256 = 0x1111111111111111111111111111111111111111111111111111111100000000;
    const t2: u256 = 0x2222222222222222222222222222222222222222222222222222222200000000;
    const t3: u256 = 0x3333333333333333333333333333333333333333333333333333333300000000;
    const mask = ~@as(u256, 0xFFFFFFFF);

    // refuse.eth and loker.eth point at TARGET; other.eth points elsewhere.
    _ = try insertChildName(allocator, database, "refuse", "eth", PARENT, OWNER_1, t1);
    _ = try insertChildName(allocator, database, "loker", "eth", PARENT, OWNER_1, t2);
    _ = try insertChildName(allocator, database, "other", "eth", PARENT, OWNER_1, t3);
    _ = try database.upsertRegistryEntrySubregistry(.v2, PARENT, t1 & mask, TARGET, 1000, 1700000000);
    _ = try database.upsertRegistryEntrySubregistry(.v2, PARENT, t2 & mask, TARGET, 1000, 1700000000);
    _ = try database.upsertRegistryEntrySubregistry(.v2, PARENT, t3 & mask, OTHER, 1000, 1700000000);

    // Inverse lookup: exactly the two names that point at TARGET; one at OTHER.
    try testing.expectEqual(@as(usize, 2), try database.getFilteredNameCount(.{ .subregistry_pointer = TARGET }));
    try testing.expectEqual(@as(usize, 1), try database.getFilteredNameCount(.{ .subregistry_pointer = OTHER }));

    const names = try database.getFilteredNames(.{ .subregistry_pointer = TARGET }, 0, 50, .desc, .created_at);
    defer {
        for (names) |*n| {
            var m = n.*;
            m.deinit(allocator);
        }
        allocator.free(names);
    }
    try testing.expectEqual(@as(usize, 2), names.len);
    for (names) |n| {
        const nm = n.name.?;
        try testing.expect(std.mem.eql(u8, nm, "refuse.eth") or std.mem.eql(u8, nm, "loker.eth"));
    }

    // Composes with a `where` predicate: narrows the inverse set.
    try testing.expectEqual(@as(usize, 1), try database.getFilteredNameCount(.{ .subregistry_pointer = TARGET, .name = "refuse.eth" }));
}

// ============================================================================
// Tree-derived reachability: isRegistryReachable (the canonical upward walk)
// and reconcileV2Reachability (the order-independent authority that backstops
// the per-event cascade against the indexer's phase/chunk ordering).
// ============================================================================

test "isRegistryReachable: root, reachable subregistry, and orphaned (incl. deep chain)" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    const roots = [_]Address{ETH_REGISTRY};

    // A root is always reachable, even with no edges.
    try testing.expect(try database.isRegistryReachable(allocator, .v2, ETH_REGISTRY, &roots));

    // fresh.eth → SUB_A → SUB_A1 (a 2-level chain), both reachable from the root.
    _ = try database.upsertRegistryEntrySubregistry(.v2, ETH_REGISTRY, FRESH_CANONICAL_ID, SUB_A, 1000, 1700000000);
    _ = try database.upsertRegistryEntrySubregistry(.v2, SUB_A, 0x2200, SUB_A1, 1001, 1700000060);
    try testing.expect(try database.isRegistryReachable(allocator, .v2, SUB_A, &roots));
    try testing.expect(try database.isRegistryReachable(allocator, .v2, SUB_A1, &roots));

    // A registry nothing points to is unreachable.
    try testing.expect(!try database.isRegistryReachable(allocator, .v2, SUB_B, &roots));

    // Repoint fresh.eth away from SUB_A: the WHOLE SUB_A subtree (SUB_A and the
    // deeper SUB_A1) is now unreachable. A single-level "is it pointed-to by
    // anyone" check would wrongly call SUB_A1 reachable — SUB_A still points to
    // it — which is exactly the band-aid this upward walk avoids.
    _ = try database.upsertRegistryEntrySubregistry(.v2, ETH_REGISTRY, FRESH_CANONICAL_ID, SUB_B, 1002, 1700000120);
    try testing.expect(!try database.isRegistryReachable(allocator, .v2, SUB_A, &roots));
    try testing.expect(!try database.isRegistryReachable(allocator, .v2, SUB_A1, &roots));
}

test "reconcileV2Reachability heals an orphan the repoint cascade never marked (phase-ordering gap)" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    const roots = [_]Address{ETH_REGISTRY};
    const OTHER_CANONICAL_ID: u256 = 0xC2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2_00000000;

    // foo.fresh.eth registered under SUB_A while fresh.eth → SUB_A (reachable).
    _ = try database.upsertRegistryEntrySubregistry(.v2, ETH_REGISTRY, FRESH_CANONICAL_ID, SUB_A, 1000, 1700000000);
    const foo_nh = try insertChildName(allocator, database, "foo", "fresh.eth", SUB_A, OWNER_1, 0x1100);
    // bar.other.eth under SUB_B, which stays reachable throughout.
    _ = try database.upsertRegistryEntrySubregistry(.v2, ETH_REGISTRY, OTHER_CANONICAL_ID, SUB_B, 1001, 1700000060);
    const bar_nh = try insertChildName(allocator, database, "bar", "other.eth", SUB_B, OWNER_1, 0x2200);

    // fresh.eth repoints away from SUB_A — but the per-event cascade does NOT run
    // (the phase/chunk case: the repoint was processed before foo was inserted),
    // so foo is left wrongly reachable.
    _ = try database.upsertRegistryEntrySubregistry(.v2, ETH_REGISTRY, FRESH_CANONICAL_ID, SUB_B, 1002, 1700000120);
    {
        const before = try database.getNameByNamehash(foo_nh);
        try testing.expect(before != null);
        var n = before.?;
        defer n.deinit(allocator);
        try testing.expect(n.is_reachable); // still wrongly reachable
    }

    // The order-independent reconciliation recomputes from the final tree and
    // marks exactly the one orphaned-subtree name unreachable.
    const fixed = try database.reconcileV2Reachability(allocator, &roots, 1003, 1700000180);
    try testing.expectEqual(@as(u64, 1), fixed);

    {
        const f = try database.getNameByNamehash(foo_nh);
        var n = f.?;
        defer n.deinit(allocator);
        try testing.expect(!n.is_reachable); // foo (under orphaned SUB_A) now unreachable
        try testing.expectEqual(@as(i64, 1700000180), n.unreachable_since.?);
    }
    {
        const b = try database.getNameByNamehash(bar_nh);
        var n = b.?;
        defer n.deinit(allocator);
        try testing.expect(n.is_reachable); // bar (under reachable SUB_B) untouched
    }
}

test "recompute: repointing a user entry away from a shared registry must not orphan it (2026-08-12 incident)" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const ROOT = Address{ .bytes = [_]u8{0x11} ** 20 };
    const USER_REG = Address{ .bytes = [_]u8{0x22} ** 20 };
    const ELSEWHERE = Address{ .bytes = [_]u8{0x33} ** 20 };
    const roots = [_]Address{ ETH_REGISTRY, ROOT };

    // Deployment shape: ROOT --eth--> ETH_REGISTRY; a 2LD lives under it.
    _ = try database.upsertRegistryEntrySubregistry(.v2, ROOT, ONE_CANONICAL_ID, ETH_REGISTRY, 1000, 1700000000);
    const ragnarok = try insertChildName(allocator, database, "ragnarok", "eth", ETH_REGISTRY, OWNER_1, FRESH_CANONICAL_ID);

    // Incident: a user's own entry points at ROOT, then away. Mirror first,
    // recompute after (as in the handler).
    _ = try database.upsertRegistryEntrySubregistry(.v2, USER_REG, FRESH_CANONICAL_ID, ROOT, 2000, 1700001000);
    const prev = try database.upsertRegistryEntrySubregistry(.v2, USER_REG, FRESH_CANONICAL_ID, ELSEWHERE, 2001, 1700001100);
    try testing.expect(prev.eql(ROOT));

    const seeds = [_]Address{ prev, ELSEWHERE };
    const rc = try database.recomputeSubtreeReachability(allocator, .v2, &seeds, &roots, 2001, 1700001100);
    try testing.expectEqual(@as(u64, 0), rc.names_marked_unreachable);

    const row = (try database.getNameByNamehashAndProtocol(ragnarok, .v2)) orelse return error.MissingRow;
    var row_mut = row;
    defer row_mut.deinit(database.allocator);
    try testing.expect(row.is_reachable);
}

test "recompute: genuinely orphaned subtree still goes unreachable when the last parent leaves" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const ROOT = Address{ .bytes = [_]u8{0x11} ** 20 };
    const SHARED = Address{ .bytes = [_]u8{0x55} ** 20 };
    const ELSEWHERE = Address{ .bytes = [_]u8{0x33} ** 20 };
    const roots = [_]Address{ROOT};

    _ = try database.upsertRegistryEntrySubregistry(.v2, ROOT, FRESH_CANONICAL_ID, SHARED, 1001, 1700000100);
    const child = try insertChildName(allocator, database, "kid", "shared.eth", SHARED, OWNER_1, ONE_CANONICAL_ID);

    const prev = try database.upsertRegistryEntrySubregistry(.v2, ROOT, FRESH_CANONICAL_ID, ELSEWHERE, 2001, 1700001100);
    try testing.expect(prev.eql(SHARED));
    const seeds = [_]Address{ prev, ELSEWHERE };
    const rc = try database.recomputeSubtreeReachability(allocator, .v2, &seeds, &roots, 2001, 1700001100);
    try testing.expect(rc.names_marked_unreachable >= 1);

    const row = (try database.getNameByNamehashAndProtocol(child, .v2)) orelse return error.MissingRow;
    var row_mut = row;
    defer row_mut.deinit(database.allocator);
    try testing.expect(!row.is_reachable);
}

test "recompute: a DESCENDANT with an outside parent survives its ancestor subtree being orphaned" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const ROOT = Address{ .bytes = [_]u8{0x11} ** 20 };
    const MID = Address{ .bytes = [_]u8{0x66} ** 20 };
    const DEEP = Address{ .bytes = [_]u8{0x77} ** 20 };
    const ELSEWHERE = Address{ .bytes = [_]u8{0x33} ** 20 };
    const roots = [_]Address{ROOT};

    // ROOT --m--> MID --d--> DEEP, and ALSO ROOT --d2--> DEEP (outside parent).
    _ = try database.upsertRegistryEntrySubregistry(.v2, ROOT, FRESH_CANONICAL_ID, MID, 1000, 1700000000);
    const D_ID: u256 = 0x4444444444444444444444444444444444444444444444444444444444_000000;
    _ = try database.upsertRegistryEntrySubregistry(.v2, MID, D_ID, DEEP, 1001, 1700000100);
    _ = try database.upsertRegistryEntrySubregistry(.v2, ROOT, ONE_CANONICAL_ID, DEEP, 1002, 1700000200);
    const mid_name = try insertChildName(allocator, database, "mid", "eth", MID, OWNER_1, FRESH_CANONICAL_ID);
    const deep_name = try insertChildName(allocator, database, "deep", "mid.eth", DEEP, OWNER_1, D_ID);

    // MID's only parent leaves: MID's subtree is orphaned — but DEEP is not,
    // it keeps its outside parent. A blanket cascade over subtree(MID) would
    // wrongly take DEEP down; the per-node recompute must not.
    const prev = try database.upsertRegistryEntrySubregistry(.v2, ROOT, FRESH_CANONICAL_ID, ELSEWHERE, 2000, 1700001000);
    try testing.expect(prev.eql(MID));
    const seeds = [_]Address{ prev, ELSEWHERE };
    _ = try database.recomputeSubtreeReachability(allocator, .v2, &seeds, &roots, 2000, 1700001000);

    const mid_row = (try database.getNameByNamehashAndProtocol(mid_name, .v2)) orelse return error.MissingRow;
    var mid_mut = mid_row;
    defer mid_mut.deinit(database.allocator);
    try testing.expect(!mid_row.is_reachable);

    const deep_row = (try database.getNameByNamehashAndProtocol(deep_name, .v2)) orelse return error.MissingRow;
    var deep_mut = deep_row;
    defer deep_mut.deinit(database.allocator);
    try testing.expect(deep_row.is_reachable);
}

test "recompute: re-link through an ORPHANED parent must not resurrect the target subtree" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const ROOT = Address{ .bytes = [_]u8{0x11} ** 20 };
    const ORPHAN = Address{ .bytes = [_]u8{0x88} ** 20 };
    const TARGET = Address{ .bytes = [_]u8{0x99} ** 20 };
    const roots = [_]Address{ROOT};

    // TARGET starts orphaned (no path to ROOT); its name is unreachable.
    const t_name = try insertChildName(allocator, database, "target", "eth", TARGET, OWNER_1, ONE_CANONICAL_ID);
    _ = try database.setRegistriesReachability(.v2, &[_]Address{TARGET}, false, 1000, 1700000000);

    // An ORPHANED registry (also no path to ROOT) points an entry at TARGET.
    // The old blanket re-link cascade would mark subtree(TARGET) reachable;
    // the per-node recompute must see there is still no path to a root.
    _ = try database.upsertRegistryEntrySubregistry(.v2, ORPHAN, FRESH_CANONICAL_ID, TARGET, 2000, 1700001000);
    const seeds = [_]Address{TARGET};
    const rc = try database.recomputeSubtreeReachability(allocator, .v2, &seeds, &roots, 2000, 1700001000);
    try testing.expectEqual(@as(u64, 0), rc.names_marked_reachable);

    const row = (try database.getNameByNamehashAndProtocol(t_name, .v2)) orelse return error.MissingRow;
    var row_mut = row;
    defer row_mut.deinit(database.allocator);
    try testing.expect(!row.is_reachable);

    // …and a re-link from ROOT genuinely resurrects it.
    _ = try database.upsertRegistryEntrySubregistry(.v2, ROOT, ONE_CANONICAL_ID, TARGET, 3000, 1700002000);
    const rc2 = try database.recomputeSubtreeReachability(allocator, .v2, &seeds, &roots, 3000, 1700002000);
    try testing.expect(rc2.names_marked_reachable >= 1);
    const row2 = (try database.getNameByNamehashAndProtocol(t_name, .v2)) orelse return error.MissingRow;
    var row2_mut = row2;
    defer row2_mut.deinit(database.allocator);
    try testing.expect(row2.is_reachable);
}

// ============================================================================
// BATCH READERS (API page loaders): each regroups to exactly the point read
// ============================================================================

const registry_entries = lib.storage.registry_entries;
const names_registry = lib.storage.names_registry;
const events = lib.storage.events;

fn canonicalIdAt(i: u64) u256 {
    return (@as(u256, i) + 1) << 32;
}

fn addressAt(i: u64) Address {
    var out = Address{ .bytes = [_]u8{0x50} ** 20 };
    out.bytes[18] = @intCast(i >> 8);
    out.bytes[19] = @intCast(i & 0xFF);
    return out;
}

fn hashAt(i: u64) Hash {
    var out = Hash{ .bytes = [_]u8{0x60} ** 32 };
    out.bytes[30] = @intCast(i >> 8);
    out.bytes[31] = @intCast(i & 0xFF);
    return out;
}

fn findSubregistryRow(rows: []const registry_entries.SubregistryRow, parent: Address, canonical_id: u256) ?Address {
    var parent_buf: [42]u8 = undefined;
    const parent_hex = parent.toHexBuf(&parent_buf);
    var canonical_buf: [66]u8 = undefined;
    const canonical_hex = std.fmt.bufPrint(&canonical_buf, "0x{x:0>64}", .{canonical_id}) catch unreachable;
    for (rows) |r| {
        if (std.mem.eql(u8, r.parent_registry, parent_hex) and std.mem.eql(u8, r.canonical_id, canonical_hex)) {
            return Address.fromHex(r.subregistry) catch unreachable;
        }
    }
    return null;
}

test "getSubregistriesForPairs regroups to exactly getSubregistry per pair (missing pair absent, duplicate collapsed)" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const fresh_canonical = canonicalIdAt(7);
    const one_canonical = canonicalIdAt(8);
    const missing_canonical = canonicalIdAt(9);
    // Entries are written from versioned token ids; the batch takes the
    // caller-derived canonical ids.
    _ = try database.upsertRegistryEntrySubregistry(.v2, ETH_REGISTRY, fresh_canonical | 3, SUB_A, 1000, 1700000000);
    _ = try database.upsertRegistryEntrySubregistry(.v2, SUB_A, one_canonical | 1, SUB_A1, 1001, 1700000600);
    // Same pair under the other protocol must not leak into a v2 read.
    _ = try database.upsertRegistryEntrySubregistry(.v1, ETH_REGISTRY, missing_canonical, SUB_B, 1002, 1700001200);

    const parents = [_]Address{ ETH_REGISTRY, SUB_A, ETH_REGISTRY, ETH_REGISTRY };
    const ids = [_]u256{ fresh_canonical, one_canonical, missing_canonical, fresh_canonical };
    const rows = try registry_entries.getSubregistriesForPairs(database, .v2, &parents, &ids, allocator);
    defer registry_entries.freeSubregistryRows(allocator, rows);

    // Two live pairs, ordered by (parent_registry, canonical_id): SUB_A (0xaa…)
    // sorts before ETH_REGISTRY (0xe7…).
    try testing.expectEqual(@as(usize, 2), rows.len);
    var sub_a_buf: [42]u8 = undefined;
    try testing.expectEqualStrings(SUB_A.toHexBuf(&sub_a_buf), rows[0].parent_registry);
    var eth_buf: [42]u8 = undefined;
    try testing.expectEqualStrings(ETH_REGISTRY.toHexBuf(&eth_buf), rows[1].parent_registry);

    for (parents, ids) |parent, canonical_id| {
        const expected = try database.getRegistryEntrySubregistry(.v2, parent, canonical_id | 5);
        const got = findSubregistryRow(rows, parent, canonical_id) orelse Address.zero;
        try testing.expect(expected.eql(got));
    }
    try testing.expect(findSubregistryRow(rows, ETH_REGISTRY, missing_canonical) == null);
    try testing.expect((findSubregistryRow(rows, ETH_REGISTRY, fresh_canonical) orelse Address.zero).eql(SUB_A));
    try testing.expect((findSubregistryRow(rows, SUB_A, one_canonical) orelse Address.zero).eql(SUB_A1));
}

test "getSubregistriesForPairs spans the 200-pair chunk boundary" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const total: usize = 250;
    var parents: [total + 2]Address = undefined;
    var ids: [total + 2]u256 = undefined;
    for (0..total) |i| {
        parents[i] = ETH_REGISTRY;
        ids[i] = canonicalIdAt(i);
        _ = try database.upsertRegistryEntrySubregistry(.v2, ETH_REGISTRY, canonicalIdAt(i), addressAt(i), 1000 + i, 1700000000);
    }
    // One pair with no entry, one duplicate of the very first pair.
    parents[total] = SUB_B;
    ids[total] = canonicalIdAt(0);
    parents[total + 1] = ETH_REGISTRY;
    ids[total + 1] = canonicalIdAt(0);

    const rows = try registry_entries.getSubregistriesForPairs(database, .v2, &parents, &ids, allocator);
    defer registry_entries.freeSubregistryRows(allocator, rows);

    try testing.expectEqual(total, rows.len);
    // Ordered by canonical_id within the single parent: zero-padded hex order
    // is numeric order.
    var canonical_buf: [66]u8 = undefined;
    for (rows, 0..) |r, i| {
        const expected_hex = try std.fmt.bufPrint(&canonical_buf, "0x{x:0>64}", .{canonicalIdAt(i)});
        try testing.expectEqualStrings(expected_hex, r.canonical_id);
        const expected = try database.getRegistryEntrySubregistry(.v2, ETH_REGISTRY, canonicalIdAt(i));
        try testing.expect(expected.eql(try Address.fromHex(r.subregistry)));
        try testing.expect(expected.eql(addressAt(i)));
    }
    try testing.expect(findSubregistryRow(rows, SUB_B, canonicalIdAt(0)) == null);
}

fn insertRegistryRow(database: *Database, protocol: models.Protocol, address: Address, name: []const u8, namehash: Hash, created_block: u64) !void {
    try database.insertRegistry(.{
        .protocol = protocol,
        .address = address,
        .name = name,
        .namehash = namehash,
        .parent_registry = ETH_REGISTRY,
        .created_block = created_block,
        .created_at = @intCast(1700000000 + created_block),
    });
}

fn expectRegistryEql(expected: models.Registry, got: models.Registry) !void {
    try testing.expect(expected.address.eql(got.address));
    try testing.expectEqual(expected.protocol, got.protocol);
    try testing.expectEqualStrings(expected.name, got.name);
    try testing.expect(expected.namehash.eql(got.namehash));
    try testing.expect(expected.parent_registry.eql(got.parent_registry));
    try testing.expectEqual(expected.created_block, got.created_block);
    try testing.expectEqual(expected.created_at, got.created_at);
}

/// First row of `rows` for `address` (rows are ordered by address, then the
/// point read's created_block DESC), or null when the address is absent.
fn firstRegistryRow(rows: []const models.Registry, address: Address) ?models.Registry {
    for (rows) |r| if (r.address.eql(address)) return r;
    return null;
}

test "getRegistriesByAddresses first row per address equals getRegistry (two rows, unknown address, duplicate)" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const two_rows = SUB_A;
    const one_row = SUB_B;
    const unknown = SUB_A1;
    // Inserted older-first so the point read's ORDER BY, not insert order,
    // decides the answer.
    try insertRegistryRow(database, .v2, two_rows, "old.eth", hashAt(1), 1000);
    try insertRegistryRow(database, .v2, two_rows, "new.eth", hashAt(2), 2000);
    try insertRegistryRow(database, .v2, one_row, "only.eth", hashAt(3), 1500);
    // Other-protocol row for a queried address must not appear.
    try insertRegistryRow(database, .v1, unknown, "v1.eth", hashAt(4), 3000);

    const addresses = [_]Address{ two_rows, one_row, unknown, two_rows };
    const rows = try names_registry.getRegistriesByAddresses(database, .v2, &addresses, allocator);
    defer {
        for (rows) |*r| r.deinit(allocator);
        allocator.free(rows);
    }

    // All three v2 rows, ordered by address (SUB_A 0xaa… < SUB_B 0xbb…), then
    // created_block DESC within SUB_A.
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expect(rows[0].address.eql(two_rows));
    try testing.expectEqual(@as(u64, 2000), rows[0].created_block);
    try testing.expect(rows[1].address.eql(two_rows));
    try testing.expectEqual(@as(u64, 1000), rows[1].created_block);
    try testing.expect(rows[2].address.eql(one_row));

    for (addresses) |address| {
        var expected = try database.getRegistry(.v2, address);
        defer if (expected) |*e| e.deinit(allocator);
        const got = firstRegistryRow(rows, address);
        if (expected) |e| {
            try expectRegistryEql(e, got.?);
        } else {
            try testing.expect(got == null);
        }
    }
    try testing.expect(firstRegistryRow(rows, unknown) == null);
    try testing.expectEqualStrings("new.eth", firstRegistryRow(rows, two_rows).?.name);
}

test "getRegistriesByAddresses spans the 200-address chunk boundary" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    // 205 addresses queried; only every 50th has a row, including one in the
    // second chunk.
    const total: usize = 205;
    var addresses: [total]Address = undefined;
    var seeded: usize = 0;
    for (0..total) |i| {
        addresses[i] = addressAt(i);
        if (i % 50 == 0) {
            try insertRegistryRow(database, .v2, addressAt(i), "chunk.eth", hashAt(i), 1000 + i);
            seeded += 1;
        }
    }

    const rows = try names_registry.getRegistriesByAddresses(database, .v2, &addresses, allocator);
    defer {
        for (rows) |*r| r.deinit(allocator);
        allocator.free(rows);
    }
    try testing.expectEqual(seeded, rows.len);
    for (0..total) |i| {
        var expected = try database.getRegistry(.v2, addressAt(i));
        defer if (expected) |*e| e.deinit(allocator);
        const got = firstRegistryRow(rows, addressAt(i));
        if (expected) |e| try expectRegistryEql(e, got.?) else try testing.expect(got == null);
    }
}

fn insertEventFor(database: *Database, protocol: models.Protocol, namehash: ?Hash, seq: u32) !void {
    try database.insertEvent(.{
        .protocol = protocol,
        .event_type = .transfer,
        .block_number = 1000 + seq,
        .tx_hash = hashAt(1000 + seq),
        .log_index = seq,
        .contract_address = helpers.TEST_REGISTRY,
        .name = null,
        .namehash = namehash,
        .data = "{}",
        .timestamp = 1700000000,
    });
}

fn countRowFor(rows: []const events.NamehashCountRow, namehash: Hash) ?u64 {
    for (rows) |r| if (r.namehash.eql(namehash)) return r.count;
    return null;
}

test "countEventsForNamehashes equals countEventsByNamehash for 0, 1 and 3 events (absent = 0, duplicate collapsed)" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const three = hashAt(1);
    const one = hashAt(2);
    const zero = hashAt(3);
    const noise = hashAt(4);
    try insertEventFor(database, .v2, three, 1);
    try insertEventFor(database, .v2, three, 2);
    // The point read has no protocol filter, so a v1 event counts too.
    try insertEventFor(database, .v1, three, 3);
    try insertEventFor(database, .v2, one, 4);
    try insertEventFor(database, .v2, noise, 5);
    try insertEventFor(database, .v2, null, 6);

    const namehashes = [_]Hash{ three, one, zero, three };
    const rows = try events.countEventsForNamehashes(database, &namehashes, allocator);
    defer allocator.free(rows);

    // Ordered by namehash hex: hashAt(1) < hashAt(2).
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expect(rows[0].namehash.eql(three));
    try testing.expectEqual(@as(u64, 3), rows[0].count);
    try testing.expect(rows[1].namehash.eql(one));
    try testing.expectEqual(@as(u64, 1), rows[1].count);

    for (namehashes) |nh| {
        const expected: u64 = @intCast(try database.countEventsByNamehash(nh));
        try testing.expectEqual(expected, countRowFor(rows, nh) orelse 0);
    }
    try testing.expect(countRowFor(rows, zero) == null);
    try testing.expect(countRowFor(rows, noise) == null);
}

test "countEventsForNamehashes spans the 200-namehash chunk boundary" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const total: usize = 205;
    var namehashes: [total]Hash = undefined;
    var seq: u32 = 0;
    var seeded: usize = 0;
    for (0..total) |i| {
        namehashes[i] = hashAt(i);
        if (i % 50 == 0) {
            // i/50 + 1 events each: 1, 2, 3, 4, 5.
            for (0..(i / 50 + 1)) |_| {
                seq += 1;
                try insertEventFor(database, .v2, hashAt(i), seq);
            }
            seeded += 1;
        }
    }

    const rows = try events.countEventsForNamehashes(database, &namehashes, allocator);
    defer allocator.free(rows);
    try testing.expectEqual(seeded, rows.len);
    for (0..total) |i| {
        const expected: u64 = @intCast(try database.countEventsByNamehash(hashAt(i)));
        try testing.expectEqual(expected, countRowFor(rows, hashAt(i)) orelse 0);
    }
    try testing.expectEqual(@as(u64, 5), countRowFor(rows, hashAt(200)).?);
}
