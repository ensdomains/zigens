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
