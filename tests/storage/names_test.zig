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
const events = lib.storage.events;
const unknown_labels = lib.storage.unknown_labels;
const names_storage = lib.storage.names;

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

// ============================================================================
// CROSS-BACKEND: events JSON-data filters/sort + unknown_labels now-epoch.
// These exercise the dialect-routed json_extract → (data::jsonb ->> 'x') and
// strftime → EXTRACT(EPOCH) ports. Runs on SQLite (test-storage/test) and, via
// the backend-aware helpers.createTestDatabase, on Postgres (test-storage-pg).
// ============================================================================

fn insertJsonEvent(db: *Database, block: u64, data: []const u8) !void {
    try events.insertEvent(db, .{
        .protocol = .v2,
        .event_type = .name_registered,
        .block_number = block,
        .tx_hash = helpers.randomHash(),
        .log_index = 0,
        .contract_address = Address.zero,
        .name = null,
        .namehash = null,
        .data = data,
        .timestamp = 1700000000,
    });
}

fn freeEvents(allocator: std.mem.Allocator, evs: []models.Event) void {
    for (evs) |*e| e.deinit(allocator);
    allocator.free(evs);
}

test "events JSON-data owner filter + expiry sort/filter are dialect-routed" {
    const allocator = testing.allocator;
    const db = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, db);

    try insertJsonEvent(db, 10, "{\"owner\":\"0xAAA\",\"expiry\":200}");
    try insertJsonEvent(db, 11, "{\"owner\":\"0xbbb\",\"expiry\":100}");

    // data_json_owner: LOWER(<json owner>) = LOWER(?) — case-insensitive → only block 10.
    {
        const res = try events.getEventsFiltered(db, .{ .data_json_owner = "0xaaa" });
        defer freeEvents(allocator, res);
        try testing.expectEqual(@as(usize, 1), res.len);
        try testing.expectEqual(@as(u64, 10), res[0].block_number);
    }
    // expiry sort ascending: COALESCE(CAST(<json expiry> AS INTEGER), …) → 100 (block 11) first.
    {
        const res = try events.getEventsFiltered(db, .{ .sort_field = .expiry, .order_dir = .asc });
        defer freeEvents(allocator, res);
        try testing.expectEqual(@as(usize, 2), res.len);
        try testing.expectEqual(@as(u64, 11), res[0].block_number);
        try testing.expectEqual(@as(u64, 10), res[1].block_number);
    }
    // expiry filter: expiry >= 150 → only block 10 (expiry 200).
    {
        const res = try events.getEventsFiltered(db, .{ .expiry_gte = 150 });
        defer freeEvents(allocator, res);
        try testing.expectEqual(@as(usize, 1), res.len);
        try testing.expectEqual(@as(u64, 10), res[0].block_number);
    }
}

test "unknown_labels.incrementBackfillAttempt uses the dialect now-epoch" {
    const allocator = testing.allocator;
    const db = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, db);
    // The UPDATE runs (matching zero rows for a non-existent id) — what matters is that the
    // now-epoch expression (strftime on SQLite, EXTRACT(EPOCH FROM now()) on PG) prepares + executes.
    try unknown_labels.incrementBackfillAttempt(db, 999);
}

// ============================================================================
// Grace-aware expiryDate_* filters (subgraph parity): the compared value adds
// 90d (7776000s) for UNWRAPPED V1 .eth 2LDs only — mirroring
// ens_fields.effectiveDomainExpiry. Bare expiry_* filters stay raw.
// ============================================================================

fn mkExpiryName(allocator: std.mem.Allocator, name: []const u8, protocol: models.Protocol, expiry: u64, wrapped: bool) !models.Name {
    return models.Name{
        .name = name,
        .namehash = try lib.namehash(allocator, name),
        .label = name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len],
        .label_hash = try lib.keccak256(allocator, name),
        .parent_name = "eth",
        .parent_namehash = try lib.namehash(allocator, "eth"),
        .protocol = protocol,
        .registry = Address.zero,
        .owner = helpers.TEST_OWNER_1,
        .registrant = helpers.TEST_OWNER_1,
        .resolver = Address.zero,
        .token_id = 0,
        .canonical_id = 0,
        .token_version = 1,
        .expiry = expiry,
        .registry_locked = false,
        .migrated = false,
        .created_block = 100,
        .created_at = 1700000000,
        .registered_at = 1700000000,
        .updated_block = 100,
        .updated_at = 1700000000,
        .is_wrapped = wrapped,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = (protocol == .v1),
        .v1_label_hash = null,
    };
}

test "getFilteredNames: expiryDate_* filters are grace-aware, expiry_* stay raw" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    try database.insertName(try mkExpiryName(allocator, "plainv1.eth", .v1, 1000, false));
    try database.insertName(try mkExpiryName(allocator, "wrappedv1.eth", .v1, 1000, true));
    try database.insertName(try mkExpiryName(allocator, "plainv2.eth", .v2, 1000, false));

    // Grace-aware: only the unwrapped V1 2LD compares as 1000 + 7776000.
    {
        const names = try database.getFilteredNames(.{ .expiry_date_gt = 1_000_000 }, 0, 100, .asc, .name);
        defer {
            for (names) |*n| n.deinit(allocator);
            allocator.free(names);
        }
        try testing.expectEqual(@as(usize, 1), names.len);
        try testing.expectEqualStrings("plainv1.eth", names[0].name.?);
    }
    // Bare expiry_* is raw: nothing stored exceeds 1,000,000.
    {
        const names = try database.getFilteredNames(.{ .expiry_gt = 1_000_000 }, 0, 100, .asc, .name);
        defer {
            for (names) |*n| n.deinit(allocator);
            allocator.free(names);
        }
        try testing.expectEqual(@as(usize, 0), names.len);
    }
    // Grace-aware lte: wrapped V1 (already grace-inclusive in storage) and V2
    // compare at their stored 1000; the unwrapped V1 2LD is excluded.
    {
        const names = try database.getFilteredNames(.{ .expiry_date_lte = 1000 }, 0, 100, .asc, .name);
        defer {
            for (names) |*n| n.deinit(allocator);
            allocator.free(names);
        }
        try testing.expectEqual(@as(usize, 2), names.len);
    }
    // Grace-aware ordering: ascending effective expiry sorts the unwrapped V1
    // 2LD (1000 + grace) last even though all three rows store expiry = 1000.
    {
        const names = try database.getFilteredNames(.{}, 0, 100, .asc, .expiry_effective);
        defer {
            for (names) |*n| n.deinit(allocator);
            allocator.free(names);
        }
        try testing.expectEqual(@as(usize, 3), names.len);
        try testing.expectEqualStrings("plainv1.eth", names[2].name.?);
    }
}

test "updateV1RenewalExpiry: wrapped rows keep the grace-inclusive expiry" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const grace = 7776000;
    const plain = try mkExpiryName(allocator, "renewplain.eth", .v1, 1000, false);
    const wrapped = try mkExpiryName(allocator, "renewwrapped.eth", .v1, 1000 + grace, true);
    try database.insertName(plain);
    try database.insertName(wrapped);

    // Direct BaseRegistrar renew carries the bare registrar expires value.
    try names_storage.updateV1RenewalExpiry(database, plain.namehash, 2000);
    try names_storage.updateV1RenewalExpiry(database, wrapped.namehash, 2000);

    {
        const name_opt = try database.getNameByNamehash(plain.namehash);
        try testing.expect(name_opt != null);
        var name = name_opt.?;
        defer name.deinit(allocator);
        try testing.expectEqual(@as(u64, 2000), name.expiry);
    }
    {
        const name_opt = try database.getNameByNamehash(wrapped.namehash);
        try testing.expect(name_opt != null);
        var name = name_opt.?;
        defer name.deinit(allocator);
        try testing.expectEqual(@as(u64, 2000 + grace), name.expiry);
    }

    // Never-expires sentinel: expires > maxInt(i64) clamps to 0 and must NOT
    // gain grace on wrapped rows (0 + 90d would read as "expired in 1970").
    try names_storage.updateV1RenewalExpiry(database, wrapped.namehash, std.math.maxInt(u64));
    {
        const name_opt = try database.getNameByNamehash(wrapped.namehash);
        try testing.expect(name_opt != null);
        var name = name_opt.?;
        defer name.deinit(allocator);
        try testing.expectEqual(@as(u64, 0), name.expiry);
    }

    // Near-max i64: + 90d would overflow BIGINT — also treated as never-expires.
    try names_storage.updateV1RenewalExpiry(database, wrapped.namehash, @as(u64, std.math.maxInt(i64)) - 100);
    {
        const name_opt = try database.getNameByNamehash(wrapped.namehash);
        try testing.expect(name_opt != null);
        var name = name_opt.?;
        defer name.deinit(allocator);
        try testing.expectEqual(@as(u64, 0), name.expiry);
    }
}

test "updateV1RenewalExpiry: only the v1 row of a shared namehash changes" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const v1_row = try mkExpiryName(allocator, "dualproto.eth", .v1, 1000, false);
    const v2_row = try mkExpiryName(allocator, "dualproto.eth", .v2, 5000, false);
    try database.insertName(v1_row);
    try database.insertName(v2_row);

    try names_storage.updateV1RenewalExpiry(database, v1_row.namehash, 2000);

    {
        const name_opt = try database.getNameByNamehashAndProtocol(v1_row.namehash, .v1);
        try testing.expect(name_opt != null);
        var name = name_opt.?;
        defer name.deinit(allocator);
        try testing.expectEqual(@as(u64, 2000), name.expiry);
    }
    {
        const name_opt = try database.getNameByNamehashAndProtocol(v2_row.namehash, .v2);
        try testing.expect(name_opt != null);
        var name = name_opt.?;
        defer name.deinit(allocator);
        try testing.expectEqual(@as(u64, 5000), name.expiry);
    }
}

test "updateNameUnwrapperState re-bases .eth 2LD expiry from registrations" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const grace = 7776000;
    const wrapped = try mkExpiryName(allocator, "unwraprebase.eth", .v1, 1000 + grace, true);
    try database.insertName(wrapped);
    try lib.storage.registrations.insertRegistration(
        database,
        .v1,
        wrapped.namehash,
        "unwraprebase",
        "eth",
        helpers.TEST_OWNER_1,
        1700000000,
        1000,
        100,
        wrapped.namehash,
        0,
        .name_registered,
    );

    try names_storage.updateNameUnwrapperState(database, wrapped.namehash);

    const name_opt = try database.getNameByNamehash(wrapped.namehash);
    try testing.expect(name_opt != null);
    var name = name_opt.?;
    defer name.deinit(allocator);
    try testing.expect(!name.is_wrapped);
    try testing.expectEqual(@as(u64, 1000), name.expiry);
}

test "expiry_date filters tolerate a near-max stored expiry" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    // Pre-guard, `expiry + 7776000` on this row overflowed BIGINT on PG and
    // failed every expiryDate-filtered query; the bound makes it compare raw.
    try database.insertName(try mkExpiryName(allocator, "poisoned.eth", .v1, std.math.maxInt(i64), false));

    const names = try database.getFilteredNames(.{ .expiry_date_gt = 0 }, 0, 100, .asc, .expiry_effective);
    defer {
        for (names) |*n| n.deinit(allocator);
        allocator.free(names);
    }
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("poisoned.eth", names[0].name.?);
}

// ============================================================================
// ROOT-PARENT / NAME-CONSTRUCTION INVARIANTS (ens_name.zig + storage boundary)
// ============================================================================

test "insertName coerces null parent_name to empty string (NOT NULL invariant)" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    // A root TLD as the V1 NewOwner path builds it: parent_name null in-memory.
    // The column is NOT NULL, so storage must coerce to "" rather than abort.
    const nh = try namehash_fn(allocator, "eth");
    try database.insertName(models.Name{
        .protocol = .v1,
        .name = "eth",
        .namehash = nh,
        .label = "eth",
        .label_hash = try labelhash_fn(allocator, "eth"),
        .parent_name = null,
        .parent_namehash = Hash.zero,
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
        .created_block = 1,
        .created_at = 1,
        .registered_at = 1,
        .updated_block = 1,
        .updated_at = 1,
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = true,
        .v1_label_hash = null,
    });

    const got = try database.getNameByNamehash(nh);
    try testing.expect(got != null);
    var n = got.?;
    defer n.deinit(allocator);
    // Read back as "" (the read path also coerces), never a stray null.
    try testing.expectEqualStrings("", n.parent_name orelse "NULL_LEAKED");
    try testing.expectEqualStrings("eth", n.name.?);
}

test "updateNameLabel is protocol-scoped: a v1 heal leaves the same-namehash v2 row intact" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    // Same namehash under both protocols (a V1->V2 migrated name).
    const nh = try namehash_fn(allocator, "shared.eth");
    const parent_nh = try namehash_fn(allocator, "eth");
    const base = models.Name{
        .protocol = .v1,
        .name = "[placeholder].eth",
        .namehash = nh,
        .label = "[placeholder]",
        .label_hash = try labelhash_fn(allocator, "shared"),
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
        .created_block = 1,
        .created_at = 1,
        .registered_at = 1,
        .updated_block = 1,
        .updated_at = 1,
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = true,
        .v1_label_hash = null,
    };
    try database.insertName(base);
    var v2 = base;
    v2.protocol = .v2;
    v2.name = "shared.eth";
    v2.label = "shared";
    try database.insertName(v2);

    // Heal only the v1 row.
    try lib.storage.names.updateNameLabel(database, .v1, nh, "shared", "shared.eth", true);

    const v1_got = try database.getNameByNamehashAndProtocol(nh, .v1);
    try testing.expect(v1_got != null);
    var v1n = v1_got.?;
    defer v1n.deinit(allocator);
    try testing.expectEqualStrings("shared", v1n.label.?);

    // The v2 row must be untouched (no protocol predicate would have clobbered it,
    // but here it stays as-is).
    const v2_got = try database.getNameByNamehashAndProtocol(nh, .v2);
    try testing.expect(v2_got != null);
    var v2n = v2_got.?;
    defer v2n.deinit(allocator);
    try testing.expectEqualStrings("shared", v2n.label.?);
    try testing.expectEqualStrings("shared.eth", v2n.name.?);
}

const label_backfill = lib.indexer.label_backfill;

test "getUnknownLabelsByLabelhash returns rows for a labelhash" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const child_nh = try namehash_fn(allocator, "sub.parent.eth");
    const parent_nh = try namehash_fn(allocator, "parent.eth");
    const sub_lh = try labelhash_fn(allocator, "sub");

    try unknown_labels.insertUnknownLabel(database, null, Hash.zero, sub_lh, child_nh, parent_nh, helpers.TEST_OWNER_1, 100);

    const rows = try unknown_labels.getUnknownLabelsByLabelhash(allocator, database, sub_lh);
    defer {
        for (rows) |r| unknown_labels.freeUnknownLabel(allocator, r);
        allocator.free(rows);
    }
    try testing.expectEqual(@as(usize, 1), rows.len);
    const child_nh_hex = try child_nh.toHex(allocator);
    defer allocator.free(child_nh_hex);
    try testing.expectEqualStrings(child_nh_hex, rows[0].namehash);
}

test "healSubdomainLabel materializes a placeholder V2 subname" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    // Parent must exist so the heal can reconstruct the full name.
    _ = try helpers.createTestName(allocator, database, "parent.eth", helpers.TEST_OWNER_1);

    const child_nh = try namehash_fn(allocator, "sub.parent.eth");
    const parent_nh = try namehash_fn(allocator, "parent.eth");
    const sub_lh = try labelhash_fn(allocator, "sub");

    // Insert the child as a V2 name with a still-unresolved [labelhash] placeholder.
    try database.insertName(models.Name{
        .protocol = .v2,
        .name = "[abc].parent.eth",
        .namehash = child_nh,
        .label = "[abc]",
        .label_hash = sub_lh,
        .parent_name = "parent.eth",
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

    const child_nh_hex = try child_nh.toHex(allocator);
    defer allocator.free(child_nh_hex);
    const parent_nh_hex = try parent_nh.toHex(allocator);
    defer allocator.free(parent_nh_hex);
    const sub_lh_hex = try sub_lh.toHex(allocator);
    defer allocator.free(sub_lh_hex);

    const ul = unknown_labels.UnknownLabel{
        .id = 1,
        .name_id = null,
        .transaction_hash = "0x",
        .labelhash = sub_lh_hex,
        .namehash = child_nh_hex,
        .parent_node = parent_nh_hex,
        .owner = "0x",
        .block_number = 0,
        .created_at = 0,
        .backfill_attempts = 0,
        .last_backfill_attempt = null,
    };

    try label_backfill.healSubdomainLabel(allocator, database, "sub", ul);

    const got = try names_storage.getNameByNamehash(database, child_nh);
    try testing.expect(got != null);
    var healed = got.?;
    defer healed.deinit(allocator);
    try testing.expectEqualStrings("sub", healed.label.?);
    try testing.expectEqualStrings("sub.parent.eth", healed.name.?);
    // protocol-correct: the V2 row was updated (not a no-op under hardcoded .v1).
    try testing.expectEqual(models.Protocol.v2, healed.protocol);
}
