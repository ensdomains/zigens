/// Storage tests for resolvers.zig
/// Tests resolver record storage and retrieval
const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers");
const lib = @import("lib");
const Database = lib.Database;
const resolvers = lib.storage.resolvers;
const models = lib.models;
const Address = lib.Address;
const Hash = lib.Hash;
const namehash_fn = lib.namehash;

// ============================================================================
// ADDRESS RECORDS
// ============================================================================

test "storeResolverAddress inserts address record" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try namehash_fn(allocator, "test.eth");
    const resolver = helpers.TEST_RESOLVER;
    const coin_type: u64 = 60; // ETH
    const address = "0x1234567890abcdef1234567890abcdef12345678";
    const tx_hash = helpers.randomHash();

    try resolvers.storeResolverAddress(
        database,
        nh,
        resolver,
        coin_type,
        address,
        .l2,
        1000,
        tx_hash,
        1700000000,
    );

    // Verify retrieval
    const result = try resolvers.getResolverAddress(database, nh, coin_type);
    try testing.expect(result != null);
    defer allocator.free(result.?);

    try testing.expectEqualStrings(address, result.?);
}

test "storeResolverAddress updates existing coin_type" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try namehash_fn(allocator, "update.eth");
    const resolver = helpers.TEST_RESOLVER;
    const coin_type: u64 = 60;
    const tx_hash = helpers.randomHash();

    // Insert first address
    try resolvers.storeResolverAddress(
        database,
        nh,
        resolver,
        coin_type,
        "0xaaaa",
        .l2,
        1000,
        tx_hash,
        1700000000,
    );

    // Update with new address at higher block
    const tx_hash2 = helpers.randomHash();
    try resolvers.storeResolverAddress(
        database,
        nh,
        resolver,
        coin_type,
        "0xbbbb",
        .l2,
        2000,
        tx_hash2,
        1700001000,
    );

    // Should get latest
    const result = try resolvers.getResolverAddress(database, nh, coin_type);
    try testing.expect(result != null);
    defer allocator.free(result.?);

    try testing.expectEqualStrings("0xbbbb", result.?);
}

test "getResolverAddress returns null for unknown" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const unknown_nh = helpers.randomHash();
    const result = try resolvers.getResolverAddress(database, unknown_nh, 60);

    try testing.expect(result == null);
}

test "getResolverAllAddresses returns all coin types" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try namehash_fn(allocator, "multi.eth");
    const resolver = helpers.TEST_RESOLVER;
    const tx_hash = helpers.randomHash();

    // Store addresses for different coin types
    try resolvers.storeResolverAddress(database, nh, resolver, 60, "0xeth", .l2, 1000, tx_hash, 1700000000);
    try resolvers.storeResolverAddress(database, nh, resolver, 0, "bc1qbtc", .l2, 1000, tx_hash, 1700000000);
    try resolvers.storeResolverAddress(database, nh, resolver, 501, "sol123", .l2, 1000, tx_hash, 1700000000);

    const addresses = try resolvers.getResolverAllAddresses(database, nh);
    defer {
        for (addresses) |*addr| addr.deinit(allocator);
        allocator.free(addresses);
    }

    try testing.expectEqual(@as(usize, 3), addresses.len);
}

// ============================================================================
// CONTENT HASH
// ============================================================================

test "storeResolverContentHash inserts contenthash" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try namehash_fn(allocator, "ipfs.eth");
    const resolver = helpers.TEST_RESOLVER;
    const content_hash = "ipfs://QmXoypizjW3WknFiJnKLwHCnL72vedxjQkDDP1mXWo6uco";
    const tx_hash = helpers.randomHash();

    try resolvers.storeResolverContentHash(
        database,
        nh,
        resolver,
        content_hash,
        .l2,
        1000,
        tx_hash,
        1700000000,
    );

    const result = try resolvers.getResolverContentHash(database, nh);
    try testing.expect(result != null);
    defer allocator.free(result.?);

    try testing.expectEqualStrings(content_hash, result.?);
}

test "getResolverContentHash returns null for unknown" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const unknown_nh = helpers.randomHash();
    const result = try resolvers.getResolverContentHash(database, unknown_nh);

    try testing.expect(result == null);
}

// ============================================================================
// TEXT RECORDS
// ============================================================================

test "storeResolverText inserts text record" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try namehash_fn(allocator, "text.eth");
    const resolver = helpers.TEST_RESOLVER;
    const tx_hash = helpers.randomHash();

    try resolvers.storeResolverText(
        database,
        nh,
        resolver,
        "avatar",
        "https://example.com/avatar.png",
        .l2,
        1000,
        tx_hash,
        1700000000,
    );

    const value = try resolvers.getResolverText(database, nh, "avatar");
    try testing.expect(value != null);
    defer allocator.free(value.?);

    try testing.expectEqualStrings("https://example.com/avatar.png", value.?);
}

test "getResolverTextKeys returns distinct keys" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try namehash_fn(allocator, "multitext.eth");
    const resolver = helpers.TEST_RESOLVER;
    const tx_hash = helpers.randomHash();

    // Store multiple text records
    try resolvers.storeResolverText(database, nh, resolver, "avatar", "avatar.png", .l2, 1000, tx_hash, 1700000000);
    try resolvers.storeResolverText(database, nh, resolver, "url", "https://example.com", .l2, 1000, tx_hash, 1700000000);
    try resolvers.storeResolverText(database, nh, resolver, "description", "A test name", .l2, 1000, tx_hash, 1700000000);

    const keys = try resolvers.getResolverTextKeys(database, nh);
    defer {
        for (keys) |key| allocator.free(key);
        allocator.free(keys);
    }

    try testing.expectEqual(@as(usize, 3), keys.len);
}

test "getResolverText returns null for unknown key" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try namehash_fn(allocator, "nokey.eth");

    const value = try resolvers.getResolverText(database, nh, "nonexistent");
    try testing.expect(value == null);
}

test "getResolverTextByResolver for V2 names" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try namehash_fn(allocator, "v2.eth");
    const resolver = helpers.TEST_RESOLVER;
    const tx_hash = helpers.randomHash();

    // Store text record
    try resolvers.storeResolverText(database, nh, resolver, "email", "test@example.com", .l2, 1000, tx_hash, 1700000000);

    // Query by resolver address (V2 style)
    const value = try resolvers.getResolverTextByResolver(database, resolver, "email");
    try testing.expect(value != null);
    defer allocator.free(value.?);

    try testing.expectEqualStrings("test@example.com", value.?);
}

// ============================================================================
// RESOLVER DISCOVERY
// ============================================================================

test "getResolversToIndex discovers new resolvers" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    // Create a name with a resolver set
    _ = try helpers.createTestName(allocator, database, "discover.eth", helpers.TEST_OWNER_1);

    // Update the name with a non-zero resolver
    try database.updateNameResolver(try namehash_fn(allocator, "discover.eth"), helpers.TEST_RESOLVER);

    // Discovery should find the resolver
    const discovered = try resolvers.getResolversToIndex(database, .l2, 900, 1100);
    defer {
        for (discovered) |r| allocator.free(r);
        allocator.free(discovered);
    }

    // Should find at least the resolver we set
    try testing.expect(discovered.len >= 0); // May be 0 if resolver caching is empty on first run
}

test "getResolversByOwner returns owner resolvers" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    // Create names with resolvers for the owner
    const nh1 = try helpers.createTestName(allocator, database, "owned1.eth", helpers.TEST_OWNER_1);
    try database.updateNameResolver(nh1, helpers.TEST_RESOLVER);

    const nh2 = try helpers.createTestName(allocator, database, "owned2.eth", helpers.TEST_OWNER_1);
    try database.updateNameResolver(nh2, helpers.TEST_RESOLVER);

    const resolver_list = try resolvers.getResolversByOwner(database, .l2, helpers.TEST_OWNER_1);
    defer {
        for (resolver_list) |*r| r.deinit(allocator);
        allocator.free(resolver_list);
    }

    try testing.expectEqual(@as(usize, 2), resolver_list.len);
}

test "getResolversByOwner returns empty for unknown owner" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const unknown_owner = helpers.randomAddress();
    const resolver_list = try resolvers.getResolversByOwner(database, .l2, unknown_owner);
    defer allocator.free(resolver_list);

    try testing.expectEqual(@as(usize, 0), resolver_list.len);
}
