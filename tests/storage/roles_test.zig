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
