/// Storage tests for names.zig
/// Tests name insertion, querying, updates, and subdomain operations
const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers");
const lib = @import("lib");
const Database = lib.Database;
const models = lib.models;
const Address = lib.Address;
const Hash = lib.Hash;
const namehash_fn = lib.namehash;
const labelhash_fn = lib.labelhash;

// ============================================================================
// REGISTRY OPERATIONS
// ============================================================================

test "insertRegistry creates new registry" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const registry_addr = helpers.TEST_REGISTRY;
    const nh = try namehash_fn(allocator, "eth");

    try helpers.createTestRegistry(database, .v2, registry_addr, "eth", nh);

    // Verify registry was created by querying
    const registries = try database.getRegistriesByOwner(.v2, helpers.TEST_OWNER_1);
    defer {
        for (registries) |*r| r.deinit(allocator);
        allocator.free(registries);
    }
    // Note: getRegistriesByOwner joins on names table, so this might be empty
    // The test verifies no error on insert
}

test "insertRegistry updates existing registry on conflict" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const registry_addr = helpers.TEST_REGISTRY;
    const nh = try namehash_fn(allocator, "eth");

    // Insert first time
    try helpers.createTestRegistry(database, .v2, registry_addr, "eth", nh);

    // Insert again with same address - should update, not fail
    try database.insertRegistry(models.Registry{
        .protocol = .v2,
        .address = registry_addr,
        .name = "eth-updated",
        .namehash = nh,
        .parent_registry = Address.zero,
        .created_block = 2000,
        .created_at = 1700001000,
    });
    // No error means upsert worked
}

test "getRegistriesByOwner returns empty for unknown owner" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const unknown_owner = helpers.randomAddress();
    const registries = try database.getRegistriesByOwner(.v2, unknown_owner);
    defer allocator.free(registries);

    try testing.expectEqual(@as(usize, 0), registries.len);
}

// ============================================================================
// NAME INSERT/UPDATE OPERATIONS
// ============================================================================

test "insertName creates name with all fields" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try helpers.createTestName(allocator, database, "test.eth", helpers.TEST_OWNER_1);

    // Verify name was created
    const name_opt = try database.getNameByNamehash(nh);
    try testing.expect(name_opt != null);

    var name = name_opt.?;
    defer name.deinit(allocator);

    try testing.expectEqualStrings("test.eth", name.name.?);
    try testing.expect(std.mem.eql(u8, &name.owner.bytes, &helpers.TEST_OWNER_1.bytes));
}

test "insertName with null optional fields" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try namehash_fn(allocator, "minimal.eth");
    const label_hash = try labelhash_fn(allocator, "minimal");
    const parent_nh = try namehash_fn(allocator, "eth");

    try database.insertName(models.Name{
        .protocol = .v2,
        .name = "minimal.eth",
        .namehash = nh,
        .label = "minimal",
        .label_hash = label_hash,
        .parent_name = "eth",
        .parent_namehash = parent_nh,
        .registry = Address.zero,
        .owner = helpers.TEST_OWNER_1,
        .registrant = helpers.TEST_OWNER_1,
        .resolver = Address.zero,
        .token_id = 0,
        .canonical_id = 0,
        .token_version = 1,
        .expiry = 0,
        .registry_locked = false,
        .migrated = false,
        .created_block = 1000,
        .created_at = 1700000000,
        .registered_at = 1700000000,
        .updated_block = 1000,
        .updated_at = 1700000000,
        .is_wrapped = false,
        .wrapper_fuses = null, // null optional
        .wrapper_expiry = null, // null optional
        .is_v1_name = false,
        .v1_label_hash = null, // null optional
    });

    const name_opt = try database.getNameByNamehash(nh);
    try testing.expect(name_opt != null);
    var name = name_opt.?;
    defer name.deinit(allocator);

    try testing.expect(name.wrapper_fuses == null);
    try testing.expect(name.wrapper_expiry == null);
}

test "updateNameExpiry updates expiry timestamp" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try helpers.createTestName(allocator, database, "expiry.eth", helpers.TEST_OWNER_1);

    // Update expiry
    const new_expiry: u64 = 1800000000;
    try database.updateNameExpiry(nh, new_expiry);

    // Verify
    const name_opt = try database.getNameByNamehash(nh);
    try testing.expect(name_opt != null);
    var name = name_opt.?;
    defer name.deinit(allocator);

    try testing.expectEqual(new_expiry, name.expiry);
}

test "updateNameExpiry clamps u64 > i64::max to 0 (never expires)" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try helpers.createTestName(allocator, database, "forever.eth", helpers.TEST_OWNER_1);

    // Update with a value exceeding i64::max — should be stored as 0
    const huge_expiry: u64 = @as(u64, @intCast(std.math.maxInt(i64))) + 1;
    try database.updateNameExpiry(nh, huge_expiry);

    const name_opt = try database.getNameByNamehash(nh);
    try testing.expect(name_opt != null);
    var name = name_opt.?;
    defer name.deinit(allocator);

    // Stored as 0 — which means "never expires"
    try testing.expectEqual(@as(u64, 0), name.expiry);
    try testing.expect(!name.isExpired());
}

test "updateNameExpiry with maxInt(u64) stores as 0 (never expires)" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try helpers.createTestName(allocator, database, "maxexpiry.eth", helpers.TEST_OWNER_1);

    try database.updateNameExpiry(nh, std.math.maxInt(u64));

    const name_opt = try database.getNameByNamehash(nh);
    try testing.expect(name_opt != null);
    var name = name_opt.?;
    defer name.deinit(allocator);

    try testing.expectEqual(@as(u64, 0), name.expiry);
    try testing.expect(!name.isExpired());
}

test "updateNameExpiry with normal u64 value stores correctly" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try helpers.createTestName(allocator, database, "normal.eth", helpers.TEST_OWNER_1);

    // A normal future timestamp (within i64 range)
    const normal_expiry: u64 = 1900000000;
    try database.updateNameExpiry(nh, normal_expiry);

    const name_opt = try database.getNameByNamehash(nh);
    try testing.expect(name_opt != null);
    var name = name_opt.?;
    defer name.deinit(allocator);

    try testing.expectEqual(normal_expiry, name.expiry);
}

test "expiry 0 means never expires" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try helpers.createTestName(allocator, database, "noexpiry.eth", helpers.TEST_OWNER_1);

    // Default expiry from createTestName is 0
    const name_opt = try database.getNameByNamehash(nh);
    try testing.expect(name_opt != null);
    var name = name_opt.?;
    defer name.deinit(allocator);

    try testing.expectEqual(@as(u64, 0), name.expiry);
    try testing.expect(!name.isExpired());
}

test "insertName with expiry > i64::max stores as 0 (never expires)" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try namehash_fn(allocator, "hugeinsert.eth");
    const label_hash = try labelhash_fn(allocator, "hugeinsert");
    const parent_nh = try namehash_fn(allocator, "eth");

    const huge_expiry: u64 = @as(u64, @intCast(std.math.maxInt(i64))) + 100;

    try database.insertName(models.Name{
        .protocol = .v2,
        .name = "hugeinsert.eth",
        .namehash = nh,
        .label = "hugeinsert",
        .label_hash = label_hash,
        .parent_name = "eth",
        .parent_namehash = parent_nh,
        .registry = Address.zero,
        .owner = helpers.TEST_OWNER_1,
        .registrant = helpers.TEST_OWNER_1,
        .resolver = Address.zero,
        .token_id = 0,
        .canonical_id = 0,
        .token_version = 1,
        .expiry = huge_expiry,
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

    const name_opt = try database.getNameByNamehash(nh);
    try testing.expect(name_opt != null);
    var name = name_opt.?;
    defer name.deinit(allocator);

    // Should be clamped to 0 (never expires)
    try testing.expectEqual(@as(u64, 0), name.expiry);
    try testing.expect(!name.isExpired());
}

test "updateNameWrapperState with expiry > i64::max stores as 0" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try helpers.createTestName(allocator, database, "wrapped.eth", helpers.TEST_OWNER_1);

    const names_storage = @import("lib").storage.names;
    const huge_expiry: u64 = @as(u64, @intCast(std.math.maxInt(i64))) + 1;
    try names_storage.updateNameWrapperState(database, nh, 196608, huge_expiry);

    const name_opt = try database.getNameByNamehash(nh);
    try testing.expect(name_opt != null);
    var name = name_opt.?;
    defer name.deinit(allocator);

    try testing.expect(name.is_wrapped);
    try testing.expectEqual(@as(i64, 0), name.wrapper_expiry.?);
}

test "updateNameWrapperExpiry with expiry > i64::max stores as 0" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try helpers.createTestName(allocator, database, "wrapexp.eth", helpers.TEST_OWNER_1);

    const names_storage = @import("lib").storage.names;
    // First wrap the name
    try names_storage.updateNameWrapperState(database, nh, 196608, 1800000000);

    // Then extend expiry with huge value
    const huge_expiry: u64 = @as(u64, @intCast(std.math.maxInt(i64))) + 1;
    try names_storage.updateNameWrapperExpiry(database, nh, huge_expiry);

    const name_opt = try database.getNameByNamehash(nh);
    try testing.expect(name_opt != null);
    var name = name_opt.?;
    defer name.deinit(allocator);

    try testing.expectEqual(@as(i64, 0), name.wrapper_expiry.?);
}

test "updateNameExpiry with exactly i64::max stores correctly (not clamped)" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try helpers.createTestName(allocator, database, "boundary.eth", helpers.TEST_OWNER_1);

    // Exactly i64::max should fit — should NOT be clamped to 0
    const max_valid: u64 = @intCast(std.math.maxInt(i64));
    try database.updateNameExpiry(nh, max_valid);

    const name_opt = try database.getNameByNamehash(nh);
    try testing.expect(name_opt != null);
    var name = name_opt.?;
    defer name.deinit(allocator);

    try testing.expectEqual(max_valid, name.expiry);
}

test "updateNameExpiry via namehash clamps u64 > i64::max to 0" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try namehash_fn(allocator, "canonical.eth");
    const label_hash = try labelhash_fn(allocator, "canonical");
    const parent_nh = try namehash_fn(allocator, "eth");

    try database.insertName(models.Name{
        .protocol = .v2,
        .name = "canonical.eth",
        .namehash = nh,
        .label = "canonical",
        .label_hash = label_hash,
        .parent_name = "eth",
        .parent_namehash = parent_nh,
        .registry = Address.zero,
        .owner = helpers.TEST_OWNER_1,
        .registrant = helpers.TEST_OWNER_1,
        .resolver = Address.zero,
        .token_id = 0,
        .canonical_id = 12345,
        .token_version = 1,
        .expiry = 1700000000,
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

    // Update with huge expiry via namehash
    const huge_expiry: u64 = @as(u64, @intCast(std.math.maxInt(i64))) + 1;
    try database.updateNameExpiry(nh, huge_expiry);

    const name_opt = try database.getNameByNamehash(nh);
    try testing.expect(name_opt != null);
    var name = name_opt.?;
    defer name.deinit(allocator);

    try testing.expectEqual(@as(u64, 0), name.expiry);
    try testing.expect(!name.isExpired());
}

test "insertOrphanedRegistration with expiry > i64::max stores as 0 and reads back as 0" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const sync_storage = @import("lib").storage.sync;
    const huge_expiry: u64 = @as(u64, @intCast(std.math.maxInt(i64))) + 1;
    const tx_hash = helpers.randomHash();

    try sync_storage.insertOrphanedRegistration(
        database,
        .v2,
        "0xaaaa",
        42,
        "testlabel",
        huge_expiry,
        helpers.TEST_OWNER_1,
        1000,
        tx_hash,
        0,
    );

    const orphans = try sync_storage.getOrphanedRegistrations(database, .v2, "0xaaaa");
    defer {
        for (orphans) |*o| o.deinit(allocator);
        allocator.free(orphans);
    }

    try testing.expectEqual(@as(usize, 1), orphans.len);
    try testing.expectEqual(@as(u64, 0), orphans[0].expiry);
}

test "updateNameOwner transfers ownership" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try helpers.createTestName(allocator, database, "transfer.eth", helpers.TEST_OWNER_1);

    // Transfer to new owner
    try database.updateNameOwner(nh, helpers.TEST_OWNER_2);

    // Verify
    const name_opt = try database.getNameByNamehash(nh);
    try testing.expect(name_opt != null);
    var name = name_opt.?;
    defer name.deinit(allocator);

    try testing.expect(std.mem.eql(u8, &name.owner.bytes, &helpers.TEST_OWNER_2.bytes));
}

test "updateNameResolver changes resolver address" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try helpers.createTestName(allocator, database, "resolver.eth", helpers.TEST_OWNER_1);

    // Update resolver
    try database.updateNameResolver(nh, helpers.TEST_RESOLVER);

    // Verify
    const name_opt = try database.getNameByNamehash(nh);
    try testing.expect(name_opt != null);
    var name = name_opt.?;
    defer name.deinit(allocator);

    try testing.expect(std.mem.eql(u8, &name.resolver.bytes, &helpers.TEST_RESOLVER.bytes));
}

// ============================================================================
// NAME QUERY OPERATIONS
// ============================================================================

test "getNameByNamehash returns name" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try helpers.createTestName(allocator, database, "lookup.eth", helpers.TEST_OWNER_1);

    const name_opt = try database.getNameByNamehash(nh);
    try testing.expect(name_opt != null);

    var name = name_opt.?;
    defer name.deinit(allocator);

    try testing.expectEqualStrings("lookup.eth", name.name.?);
}

test "getNameByNamehash returns null for unknown" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const unknown_nh = helpers.randomHash();
    const name_opt = try database.getNameByNamehash(unknown_nh);

    try testing.expect(name_opt == null);
}

test "getNamesByOwner returns all owner names" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    // Create multiple names for same owner
    _ = try helpers.createTestName(allocator, database, "one.eth", helpers.TEST_OWNER_1);
    _ = try helpers.createTestName(allocator, database, "two.eth", helpers.TEST_OWNER_1);
    _ = try helpers.createTestName(allocator, database, "three.eth", helpers.TEST_OWNER_1);

    // Create one for different owner
    _ = try helpers.createTestName(allocator, database, "other.eth", helpers.TEST_OWNER_2);

    const names = try database.getNamesByOwner(helpers.TEST_OWNER_1, null);
    defer {
        for (names) |*n| n.deinit(allocator);
        allocator.free(names);
    }

    try testing.expectEqual(@as(usize, 3), names.len);
}

test "getNamesByOwner with limit" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    // Create multiple names
    _ = try helpers.createTestName(allocator, database, "a.eth", helpers.TEST_OWNER_1);
    _ = try helpers.createTestName(allocator, database, "b.eth", helpers.TEST_OWNER_1);
    _ = try helpers.createTestName(allocator, database, "c.eth", helpers.TEST_OWNER_1);

    const names = try database.getNamesByOwner(helpers.TEST_OWNER_1, 2);
    defer {
        for (names) |*n| n.deinit(allocator);
        allocator.free(names);
    }

    try testing.expectEqual(@as(usize, 2), names.len);
}

test "getAllNames returns all names" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    _ = try helpers.createTestName(allocator, database, "first.eth", helpers.TEST_OWNER_1);
    _ = try helpers.createTestName(allocator, database, "second.eth", helpers.TEST_OWNER_2);

    const names = try database.getAllNames(null, 0, 100);
    defer {
        for (names) |*n| n.deinit(allocator);
        allocator.free(names);
    }

    // Only the two test names. The synthetic root domain inserted by
    // `Database.migrate` is hidden from default listings — see
    // `appendNameFilterConditions` / `getAllNamesWithOrder`.
    try testing.expectEqual(@as(usize, 2), names.len);
}

// ============================================================================
// SUBDOMAIN OPERATIONS
// ============================================================================

test "countDirectSubdomains returns correct count" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    // Create parent
    _ = try helpers.createTestName(allocator, database, "parent.eth", helpers.TEST_OWNER_1);

    // Create subdomains
    _ = try helpers.createTestName(allocator, database, "sub1.parent.eth", helpers.TEST_OWNER_1);
    _ = try helpers.createTestName(allocator, database, "sub2.parent.eth", helpers.TEST_OWNER_1);

    const count = try database.countDirectSubdomains("parent.eth");
    try testing.expectEqual(@as(usize, 2), count);
}

test "hasDirectSubdomains returns true when exists" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    _ = try helpers.createTestName(allocator, database, "parent.eth", helpers.TEST_OWNER_1);
    _ = try helpers.createTestName(allocator, database, "child.parent.eth", helpers.TEST_OWNER_1);

    const has_subs = try database.hasDirectSubdomains("parent.eth");
    try testing.expect(has_subs);
}

test "hasDirectSubdomains returns false when empty" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    _ = try helpers.createTestName(allocator, database, "lonely.eth", helpers.TEST_OWNER_1);

    const has_subs = try database.hasDirectSubdomains("lonely.eth");
    try testing.expect(!has_subs);
}

test "getSubdomains returns paginated list" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    _ = try helpers.createTestName(allocator, database, "main.eth", helpers.TEST_OWNER_1);
    _ = try helpers.createTestName(allocator, database, "a.main.eth", helpers.TEST_OWNER_1);
    _ = try helpers.createTestName(allocator, database, "b.main.eth", helpers.TEST_OWNER_1);
    _ = try helpers.createTestName(allocator, database, "c.main.eth", helpers.TEST_OWNER_1);

    const subdomains = try database.getSubdomains("main.eth", 0, 2);
    defer {
        for (subdomains) |*s| s.deinit(allocator);
        allocator.free(subdomains);
    }

    try testing.expectEqual(@as(usize, 2), subdomains.len);
}

// ============================================================================
// EDGE CASES
// ============================================================================

test "insertName and query roundtrip preserves data" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const original_name = "roundtrip.eth";
    const nh = try helpers.createTestName(allocator, database, original_name, helpers.TEST_OWNER_1);

    const retrieved_opt = try database.getNameByNamehash(nh);
    try testing.expect(retrieved_opt != null);

    var retrieved = retrieved_opt.?;
    defer retrieved.deinit(allocator);

    // Verify key fields match
    try testing.expectEqualStrings(original_name, retrieved.name.?);
    try testing.expect(std.mem.eql(u8, &retrieved.namehash.bytes, &nh.bytes));
    try testing.expect(std.mem.eql(u8, &retrieved.owner.bytes, &helpers.TEST_OWNER_1.bytes));
}

test "multiple names with same owner different chains" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try namehash_fn(allocator, "multichain.eth");
    const label_hash = try labelhash_fn(allocator, "multichain");
    const parent_nh = try namehash_fn(allocator, "eth");

    // Insert on L2
    try database.insertName(models.Name{
        .protocol = .v2,
        .name = "multichain.eth",
        .namehash = nh,
        .label = "multichain",
        .label_hash = label_hash,
        .parent_name = "eth",
        .parent_namehash = parent_nh,
        .registry = Address.zero,
        .owner = helpers.TEST_OWNER_1,
        .registrant = helpers.TEST_OWNER_1,
        .resolver = Address.zero,
        .token_id = 0,
        .canonical_id = 0,
        .token_version = 1,
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

    // Insert on L1
    try database.insertName(models.Name{
        .protocol = .v1,
        .name = "multichain.eth",
        .namehash = nh,
        .label = "multichain",
        .label_hash = label_hash,
        .parent_name = "eth",
        .parent_namehash = parent_nh,
        .registry = Address.zero,
        .owner = helpers.TEST_OWNER_1,
        .registrant = helpers.TEST_OWNER_1,
        .resolver = Address.zero,
        .token_id = 0,
        .canonical_id = 0,
        .token_version = 1,
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

    // Query all names for owner (getNamesByOwner doesn't filter by protocol)
    const all_names = try database.getNamesByOwner(helpers.TEST_OWNER_1, null);
    defer {
        for (all_names) |*n| n.deinit(allocator);
        allocator.free(all_names);
    }
    // Both L1 and L2 names should be returned since function doesn't filter by protocol
    try testing.expectEqual(@as(usize, 2), all_names.len);
}

// ============================================================================
// T3 REGRESSION: re-registration must preserve created_at / created_block
// ============================================================================
//
// On re-registration after expiry, the V2 LabelRegistered handler builds a fresh
// Name struct with the current block's timestamp. The insertName SQL uses
// ON CONFLICT(protocol, namehash) DO UPDATE SET — and the SET list intentionally
// excludes created_at + created_block so they're preserved across the conflict.
// This test pins that behavior so a future "fix" doesn't accidentally add them
// to the SET list and silently start clobbering historical timestamps.

test "insertName ON CONFLICT preserves created_at and created_block" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try namehash_fn(allocator, "preserve.eth");
    const label_hash = try labelhash_fn(allocator, "preserve");
    const parent_nh = try namehash_fn(allocator, "eth");

    // First insert — first registration. created_at/created_block are the
    // historical values we expect to survive the re-mint below.
    try database.insertName(models.Name{
        .protocol = .v2,
        .name = "preserve.eth",
        .namehash = nh,
        .label = "preserve",
        .label_hash = label_hash,
        .parent_name = "eth",
        .parent_namehash = parent_nh,
        .registry = Address.zero,
        .owner = helpers.TEST_OWNER_1,
        .registrant = helpers.TEST_OWNER_1,
        .resolver = Address.zero,
        .token_id = 0x1111_0000_0000_0000,
        .canonical_id = 0x1111_0000_0000_0000,
        .token_version = 0,
        .expiry = 1700_010_000,
        .registry_locked = false,
        .migrated = false,
        .created_block = 9_000_000,
        .created_at = 1700_000_000,
        .registered_at = 1700_000_000,
        .updated_block = 9_000_000,
        .updated_at = 1700_000_000,
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    });

    // Second insert — simulates re-registration after expiry. Same (protocol,
    // namehash), but later block + later timestamp + new owner. ON CONFLICT
    // should update everything in the SET list (including registered_at) but
    // leave created_at and created_block at their original values.
    try database.insertName(models.Name{
        .protocol = .v2,
        .name = "preserve.eth",
        .namehash = nh,
        .label = "preserve",
        .label_hash = label_hash,
        .parent_name = "eth",
        .parent_namehash = parent_nh,
        .registry = Address.zero,
        .owner = helpers.TEST_OWNER_1,
        .registrant = helpers.TEST_OWNER_1,
        .resolver = Address.zero,
        .token_id = 0x1111_0000_0000_0001, // new version bit
        .canonical_id = 0x1111_0000_0000_0000,
        .token_version = 1,
        .expiry = 1800_010_000,
        .registry_locked = false,
        .migrated = false,
        .created_block = 10_000_000, // new value — must be IGNORED on conflict
        .created_at = 1800_000_000, // new value — must be IGNORED on conflict
        .registered_at = 1800_000_000, // new value — must overwrite (current tenancy)
        .updated_block = 10_000_000,
        .updated_at = 1800_000_000,
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    });

    // Read back and assert created_* preserved, registered_at advanced.
    const stored = try database.getNameByNamehash(nh);
    try testing.expect(stored != null);
    var stored_mut = stored.?;
    defer stored_mut.deinit(allocator);

    try testing.expectEqual(@as(i64, 1700_000_000), stored_mut.created_at);
    try testing.expectEqual(@as(u64, 9_000_000), stored_mut.created_block);
    try testing.expectEqual(@as(i64, 1800_000_000), stored_mut.registered_at);
    try testing.expectEqual(@as(u32, 1), stored_mut.token_version);
}

// ============================================================================
// BOOLEAN FILTER TREE (and / or) — #25
// ============================================================================

test "getFilteredNames: or_group matches any sub-filter" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    _ = try helpers.createTestName(allocator, database, "alpha.eth", helpers.TEST_OWNER_1);
    _ = try helpers.createTestName(allocator, database, "beta.eth", helpers.TEST_OWNER_1);
    _ = try helpers.createTestName(allocator, database, "gamma.eth", helpers.TEST_OWNER_2);

    const or_children = [_]Database.NameFilters{
        .{ .name = "alpha.eth" },
        .{ .name = "gamma.eth" },
    };
    const names = try database.getFilteredNames(.{ .or_group = &or_children }, 0, 100, .asc, .name);
    defer {
        for (names) |*n| n.deinit(allocator);
        allocator.free(names);
    }

    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("alpha.eth", names[0].name.?);
    try testing.expectEqualStrings("gamma.eth", names[1].name.?);

    // Count must agree (cursor pagination relies on it).
    try testing.expectEqual(@as(usize, 2), try database.getFilteredNameCount(.{ .or_group = &or_children }));
}

test "getFilteredNames: scalar AND or_group  ->  owner AND (a OR b)" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    _ = try helpers.createTestName(allocator, database, "alpha.eth", helpers.TEST_OWNER_1);
    _ = try helpers.createTestName(allocator, database, "beta.eth", helpers.TEST_OWNER_1);
    _ = try helpers.createTestName(allocator, database, "gamma.eth", helpers.TEST_OWNER_2);

    // owner=OWNER_1 AND (name~"alph" OR name~"bet") -> alpha, beta (gamma is OWNER_2).
    // Also exercises mixed bind order: an Address bind (owner) before the OR's text binds.
    const or_children = [_]Database.NameFilters{
        .{ .name_contains = "alph" },
        .{ .name_contains = "bet" },
    };
    const names = try database.getFilteredNames(.{ .owner = helpers.TEST_OWNER_1, .or_group = &or_children }, 0, 100, .asc, .name);
    defer {
        for (names) |*n| n.deinit(allocator);
        allocator.free(names);
    }

    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("alpha.eth", names[0].name.?);
    try testing.expectEqualStrings("beta.eth", names[1].name.?);
}

test "getFilteredNames: and_group requires all sub-filters" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    _ = try helpers.createTestName(allocator, database, "alpha.eth", helpers.TEST_OWNER_1);
    _ = try helpers.createTestName(allocator, database, "beta.eth", helpers.TEST_OWNER_1);
    _ = try helpers.createTestName(allocator, database, "gamma.eth", helpers.TEST_OWNER_1);

    // name~"a" AND name~"l" -> only alpha.eth (beta/gamma have no 'l').
    const and_children = [_]Database.NameFilters{
        .{ .name_contains = "a" },
        .{ .name_contains = "l" },
    };
    const names = try database.getFilteredNames(.{ .and_group = &and_children }, 0, 100, .asc, .name);
    defer {
        for (names) |*n| n.deinit(allocator);
        allocator.free(names);
    }

    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("alpha.eth", names[0].name.?);
}

test "getFilteredNames: nested or within and (deep tree, bind order)" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    _ = try helpers.createTestName(allocator, database, "alpha.eth", helpers.TEST_OWNER_1);
    _ = try helpers.createTestName(allocator, database, "beta.eth", helpers.TEST_OWNER_1);
    _ = try helpers.createTestName(allocator, database, "gamma.eth", helpers.TEST_OWNER_2);

    // (name~"a") AND ( owner=OWNER_2 OR name~"bet" )
    //   alpha: O1, no "bet" -> excluded
    //   beta:  O1, has "bet" -> included
    //   gamma: O2 -> included
    const inner_or = [_]Database.NameFilters{
        .{ .owner = helpers.TEST_OWNER_2 },
        .{ .name_contains = "bet" },
    };
    const and_children = [_]Database.NameFilters{
        .{ .name_contains = "a" },
        .{ .or_group = &inner_or },
    };
    const names = try database.getFilteredNames(.{ .and_group = &and_children }, 0, 100, .asc, .name);
    defer {
        for (names) |*n| n.deinit(allocator);
        allocator.free(names);
    }

    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("beta.eth", names[0].name.?);
    try testing.expectEqualStrings("gamma.eth", names[1].name.?);
}
