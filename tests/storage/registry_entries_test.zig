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
