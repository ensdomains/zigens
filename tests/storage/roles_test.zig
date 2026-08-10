/// Storage tests for roles.zig
/// Tests EAC role assignment operations
const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers");
const lib = @import("lib");
const Database = lib.Database;
const roles = lib.storage.roles;
const models = lib.models;
const Address = lib.Address;
const Hash = lib.Hash;
const eac_roles = lib.api.eac_roles;

// ============================================================================
// ROLE UPSERT OPERATIONS
// ============================================================================

test "upsertEACRole inserts new role" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const resource = "123456"; // canonical_id as string
    const account = helpers.TEST_OWNER_1;
    const role_bitmap = "0x01"; // Admin role
    const tx_hash = helpers.randomHash();

    try roles.upsertEACRole(
        database,
        .v2,
        resource,
        account,
        role_bitmap,
        1000,
        tx_hash,
        0,
        helpers.TEST_RESOLVER,
    );

    // Verify by querying
    const role_list = try roles.getRolesByResource(database, .v2, resource);
    defer {
        for (role_list) |*r| r.deinit(allocator);
        allocator.free(role_list);
    }

    try testing.expectEqual(@as(usize, 1), role_list.len);
    try testing.expectEqualStrings(role_bitmap, role_list[0].role_bitmap);
}

test "upsertEACRole updates existing role bitmap" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const resource = "789012";
    const account = helpers.TEST_OWNER_1;
    const tx_hash = helpers.randomHash();

    // Insert initial role
    try roles.upsertEACRole(database, .v2, resource, account, "0x01", 1000, tx_hash, 0, helpers.TEST_RESOLVER);

    // Update role bitmap
    const tx_hash2 = helpers.randomHash();
    try roles.upsertEACRole(database, .v2, resource, account, "0x03", 2000, tx_hash2, 0, helpers.TEST_RESOLVER);

    // Verify updated
    const role_list = try roles.getRolesByResource(database, .v2, resource);
    defer {
        for (role_list) |*r| r.deinit(allocator);
        allocator.free(role_list);
    }

    try testing.expectEqual(@as(usize, 1), role_list.len);
    try testing.expectEqualStrings("0x03", role_list[0].role_bitmap);
}

// ============================================================================
// ROLE QUERY OPERATIONS
// ============================================================================

test "getRolesByResource returns roles for resource" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const resource = "111222";
    const tx_hash = helpers.randomHash();

    // Assign multiple accounts to same resource
    try roles.upsertEACRole(database, .v2, resource, helpers.TEST_OWNER_1, "0x01", 1000, tx_hash, 0, helpers.TEST_RESOLVER);
    try roles.upsertEACRole(database, .v2, resource, helpers.TEST_OWNER_2, "0x02", 1000, tx_hash, 1, helpers.TEST_RESOLVER);

    const role_list = try roles.getRolesByResource(database, .v2, resource);
    defer {
        for (role_list) |*r| r.deinit(allocator);
        allocator.free(role_list);
    }

    try testing.expectEqual(@as(usize, 2), role_list.len);
}

test "getRolesByAccount returns roles for account" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const tx_hash = helpers.randomHash();

    // Assign account to multiple resources
    try roles.upsertEACRole(database, .v2, "resource1", helpers.TEST_OWNER_1, "0x01", 1000, tx_hash, 0, helpers.TEST_RESOLVER);
    try roles.upsertEACRole(database, .v2, "resource2", helpers.TEST_OWNER_1, "0x02", 1000, tx_hash, 1, helpers.TEST_RESOLVER);
    try roles.upsertEACRole(database, .v2, "resource3", helpers.TEST_OWNER_1, "0x04", 1000, tx_hash, 2, helpers.TEST_RESOLVER);

    const role_list = try roles.getRolesByAccount(database, .v2, helpers.TEST_OWNER_1);
    defer {
        for (role_list) |*r| r.deinit(allocator);
        allocator.free(role_list);
    }

    try testing.expectEqual(@as(usize, 3), role_list.len);
}

test "getRolesByAccount with unknown account returns empty" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const unknown_account = helpers.randomAddress();
    const role_list = try roles.getRolesByAccount(database, .v2, unknown_account);
    defer allocator.free(role_list);

    try testing.expectEqual(@as(usize, 0), role_list.len);
}

// ============================================================================
// ROLE DELETE OPERATIONS
// ============================================================================

test "deleteEACRole removes role assignment" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const resource = "delete_test";
    const tx_hash = helpers.randomHash();

    // Insert role
    try roles.upsertEACRole(database, .v2, resource, helpers.TEST_OWNER_1, "0x01", 1000, tx_hash, 0, helpers.TEST_RESOLVER);

    // Verify exists
    {
        const role_list = try roles.getRolesByResource(database, .v2, resource);
        defer {
            for (role_list) |*r| r.deinit(allocator);
            allocator.free(role_list);
        }
        try testing.expectEqual(@as(usize, 1), role_list.len);
    }

    // Delete
    try roles.deleteEACRole(database, .v2, resource, helpers.TEST_OWNER_1, helpers.TEST_RESOLVER);

    // Verify deleted
    const role_list = try roles.getRolesByResource(database, .v2, resource);
    defer allocator.free(role_list);

    try testing.expectEqual(@as(usize, 0), role_list.len);
}

test "deleteEACRole with nonexistent role is no-op" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    // Should not error
    try roles.deleteEACRole(database, .v2, "nonexistent", helpers.TEST_OWNER_1, helpers.TEST_RESOLVER);
}

// ============================================================================
// PERMISSION DECODING (WEB-399)
// ============================================================================

test "stored role defaults to registry contract_kind and decodes registry names" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const resource = "perm_registry";
    const tx_hash = helpers.randomHash();
    // ROLE_SET_RESOLVER = 1 << 24 on a registry.
    const bitmap_hex = "0x0000000000000000000000000000000000000000000000000000000001000000";
    try roles.upsertEACRole(database, .v2, resource, helpers.TEST_OWNER_1, bitmap_hex, 1000, tx_hash, 0, helpers.TEST_RESOLVER);

    const role_list = try roles.getRolesByResource(database, .v2, resource);
    defer {
        for (role_list) |*r| r.deinit(allocator);
        allocator.free(role_list);
    }

    try testing.expectEqual(@as(usize, 1), role_list.len);
    // Contract not registered as a resolver → classified as registry.
    try testing.expectEqual(models.EACContractKind.registry, role_list[0].contract_kind);

    const perms = try eac_roles.decodeHex(allocator, role_list[0].role_bitmap, role_list[0].contract_kind);
    defer eac_roles.freePermissions(allocator, perms);
    try testing.expectEqual(@as(usize, 1), perms.len);
    try testing.expectEqualStrings("SET_RESOLVER", perms[0]);
}

test "live Sepolia ALL_ROLES bitmap decodes to full resolver permission set" {
    const allocator = testing.allocator;
    // The 22 live Sepolia resolver-EAC rows all carry roleBitmap = 0x11..11.
    const all_roles_hex = "0x1111111111111111111111111111111111111111111111111111111111111111";
    const perms = try eac_roles.decodeHex(allocator, all_roles_hex, .resolver);
    defer eac_roles.freePermissions(allocator, perms);

    // 11 resolver roles + 11 admin counterparts.
    try testing.expectEqual(@as(usize, 22), perms.len);

    // Spot-check a couple of resolver-specific names are present.
    var has_set_addr = false;
    var has_set_name = false;
    for (perms) |p| {
        if (std.mem.eql(u8, p, "SET_ADDR")) has_set_addr = true;
        if (std.mem.eql(u8, p, "SET_NAME")) has_set_name = true;
    }
    try testing.expect(has_set_addr);
    try testing.expect(has_set_name);
}

test "EAC row from a known resolver classifies as resolver and decodes resolver names" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    // Mark the emitting contract as a known resolver — this is the same set the
    // indexer routes resolver events from, so it is the classification key.
    var resolver_buf: [42]u8 = undefined;
    const resolver_hex = helpers.TEST_RESOLVER.toHexBuf(&resolver_buf);
    try database.registerResolver(.v2, resolver_hex, 1);

    // Contract-global admin role (resource = 0, EAC ROOT_RESOURCE) — the live
    // Sepolia shape — which previously failed the resolvers name-binding JOIN.
    const resource = "0x0000000000000000000000000000000000000000000000000000000000000000";
    const tx_hash = helpers.randomHash();
    // 1 << 24 = nybble 6 → SET_NAME on a resolver (SET_RESOLVER on a registry).
    const bitmap_hex = "0x0000000000000000000000000000000000000000000000000000000001000000";
    try roles.upsertEACRole(database, .v2, resource, helpers.TEST_OWNER_1, bitmap_hex, 1000, tx_hash, 0, helpers.TEST_RESOLVER);

    const role_list = try roles.getRolesByResource(database, .v2, resource);
    defer {
        for (role_list) |*r| r.deinit(allocator);
        allocator.free(role_list);
    }

    try testing.expectEqual(@as(usize, 1), role_list.len);
    // Emitting contract is a known resolver → classified as resolver, NOT registry.
    try testing.expectEqual(models.EACContractKind.resolver, role_list[0].contract_kind);

    const perms = try eac_roles.decodeHex(allocator, role_list[0].role_bitmap, role_list[0].contract_kind);
    defer eac_roles.freePermissions(allocator, perms);
    try testing.expectEqual(@as(usize, 1), perms.len);
    // Resolver name for nybble 6 — the bug previously yielded registry's SET_RESOLVER.
    try testing.expectEqualStrings("SET_NAME", perms[0]);
}

test "registerResolverIfNew reports first sighting exactly once" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    var resolver_buf: [42]u8 = undefined;
    const resolver_hex = helpers.TEST_RESOLVER.toHexBuf(&resolver_buf);

    // First sighting must report new: this is what queues the historical
    // backfill that recovers initialize()-time EACRolesChanged grants emitted
    // before the resolver was attached to any name (the deploy→attach gap
    // that left factory-set roles out of resolver.roles).
    try testing.expect(try database.registerResolverIfNew(.v2, resolver_hex, 100));
    // Every later ResolverUpdated re-registration: not new, no re-backfill.
    try testing.expect(!try database.registerResolverIfNew(.v2, resolver_hex, 200));
    // The same address under the other protocol is its own first sighting.
    try testing.expect(try database.registerResolverIfNew(.v1, resolver_hex, 300));
}

// ============================================================================
// CONTRACT SCOPING (getRolesFiltered)
// ============================================================================
// The same resource value — ROOT (0x0) on every EAC-enabled contract being the
// guaranteed case — can carry role rows on MANY contracts. These pin the
// disambiguation: contract_address is populated on every returned row, and the
// contract filter isolates one emitting contract.

test "rows carry the emitting contract and the contract filter isolates it" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const root_resource = "0x0000000000000000000000000000000000000000000000000000000000000000";
    const contract_a = Address{ .bytes = [_]u8{0xAA} ** 20 };
    const contract_b = Address{ .bytes = [_]u8{0xBB} ** 20 };

    try roles.upsertEACRole(database, .v2, root_resource, helpers.TEST_OWNER_1, "0x01", 1000, helpers.randomHash(), 0, contract_a);
    try roles.upsertEACRole(database, .v2, root_resource, helpers.TEST_OWNER_2, "0x02", 1000, helpers.randomHash(), 1, contract_b);

    // Unscoped: both contracts' rows, each stamped with its emitting contract.
    const all = try roles.getRolesFiltered(database, .v2, .{ .resource = root_resource });
    defer {
        for (all) |*r| r.deinit(allocator);
        allocator.free(all);
    }
    try testing.expectEqual(@as(usize, 2), all.len);
    for (all) |r| {
        const expected: Address = if (r.account.eql(helpers.TEST_OWNER_1)) contract_a else contract_b;
        try testing.expectEqualSlices(u8, &expected.bytes, &r.contract_address.bytes);
    }

    // Scoped: exactly the one contract's row.
    const scoped = try roles.getRolesFiltered(database, .v2, .{ .resource = root_resource, .contract_address = contract_b });
    defer {
        for (scoped) |*r| r.deinit(allocator);
        allocator.free(scoped);
    }
    try testing.expectEqual(@as(usize, 1), scoped.len);
    try testing.expectEqualSlices(u8, &contract_b.bytes, &scoped[0].contract_address.bytes);
    try testing.expectEqualSlices(u8, &helpers.TEST_OWNER_2.bytes, &scoped[0].account.bytes);
}

test "contract filter combines with account and works alone" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const contract_a = Address{ .bytes = [_]u8{0xAA} ** 20 };
    const contract_b = Address{ .bytes = [_]u8{0xBB} ** 20 };

    // Same account holds roles on two contracts; a second account on one.
    try roles.upsertEACRole(database, .v2, "0x01", helpers.TEST_OWNER_1, "0x01", 1000, helpers.randomHash(), 0, contract_a);
    try roles.upsertEACRole(database, .v2, "0x02", helpers.TEST_OWNER_1, "0x01", 1000, helpers.randomHash(), 1, contract_b);
    try roles.upsertEACRole(database, .v2, "0x03", helpers.TEST_OWNER_2, "0x01", 1000, helpers.randomHash(), 2, contract_b);

    const by_account_and_contract = try roles.getRolesFiltered(database, .v2, .{ .account = helpers.TEST_OWNER_1, .contract_address = contract_b });
    defer {
        for (by_account_and_contract) |*r| r.deinit(allocator);
        allocator.free(by_account_and_contract);
    }
    try testing.expectEqual(@as(usize, 1), by_account_and_contract.len);
    try testing.expectEqualStrings("0x02", by_account_and_contract[0].resource);

    const by_contract = try roles.getRolesFiltered(database, .v2, .{ .contract_address = contract_b });
    defer {
        for (by_contract) |*r| r.deinit(allocator);
        allocator.free(by_contract);
    }
    try testing.expectEqual(@as(usize, 2), by_contract.len);
}

test "equal-timestamp rows order deterministically (id tiebreak)" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const resource = "0xdead";
    // Same block => same timestamp; insertion order fixes ids.
    try roles.upsertEACRole(database, .v2, resource, helpers.TEST_OWNER_1, "0x01", 1000, helpers.randomHash(), 0, helpers.TEST_RESOLVER);
    try roles.upsertEACRole(database, .v2, resource, helpers.TEST_OWNER_2, "0x02", 1000, helpers.randomHash(), 1, helpers.TEST_RESOLVER);

    const list = try roles.getRolesFiltered(database, .v2, .{ .resource = resource });
    defer {
        for (list) |*r| r.deinit(allocator);
        allocator.free(list);
    }
    try testing.expectEqual(@as(usize, 2), list.len);
    // timestamp DESC, id DESC: the later insert (higher id) comes first.
    try testing.expect(list[0].id > list[1].id);
}
