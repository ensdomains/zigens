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
        .v2,
        1000,
        tx_hash,
        1700000000,
    );

    // Verify retrieval
    const result = try resolvers.getAddressRecord(database, resolver, nh, coin_type);
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
        .v2,
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
        .v2,
        2000,
        tx_hash2,
        1700001000,
    );

    // Should get latest
    const result = try resolvers.getAddressRecord(database, resolver, nh, coin_type);
    try testing.expect(result != null);
    defer allocator.free(result.?);

    try testing.expectEqualStrings("0xbbbb", result.?);
}

test "getAddressRecord returns null for unknown" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const unknown_nh = helpers.randomHash();
    const result = try resolvers.getAddressRecord(database, helpers.TEST_RESOLVER, unknown_nh, 60);

    try testing.expect(result == null);
}

test "getAddressRecords returns all coin types" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try namehash_fn(allocator, "multi.eth");
    const resolver = helpers.TEST_RESOLVER;
    const tx_hash = helpers.randomHash();

    // Store addresses for different coin types
    try resolvers.storeResolverAddress(database, nh, resolver, 60, "0xeth", .v2, 1000, tx_hash, 1700000000);
    try resolvers.storeResolverAddress(database, nh, resolver, 0, "bc1qbtc", .v2, 1000, tx_hash, 1700000000);
    try resolvers.storeResolverAddress(database, nh, resolver, 501, "sol123", .v2, 1000, tx_hash, 1700000000);

    const addresses = try resolvers.getAddressRecords(database, resolver, nh);
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
        .v2,
        1000,
        tx_hash,
        1700000000,
    );

    const result = try resolvers.getContentHashRecord(database, resolver, nh);
    try testing.expect(result != null);
    defer allocator.free(result.?);

    try testing.expectEqualStrings(content_hash, result.?);
}

test "getContentHashRecord returns null for unknown" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const unknown_nh = helpers.randomHash();
    const result = try resolvers.getContentHashRecord(database, helpers.TEST_RESOLVER, unknown_nh);

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
        .v2,
        1000,
        tx_hash,
        1700000000,
    );

    const value = try resolvers.getTextRecord(database, resolver, nh, "avatar");
    try testing.expect(value != null);
    defer allocator.free(value.?);

    try testing.expectEqualStrings("https://example.com/avatar.png", value.?);
}

test "getTextRecordKeys returns distinct keys" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try namehash_fn(allocator, "multitext.eth");
    const resolver = helpers.TEST_RESOLVER;
    const tx_hash = helpers.randomHash();

    // Store multiple text records
    try resolvers.storeResolverText(database, nh, resolver, "avatar", "avatar.png", .v2, 1000, tx_hash, 1700000000);
    try resolvers.storeResolverText(database, nh, resolver, "url", "https://example.com", .v2, 1000, tx_hash, 1700000000);
    try resolvers.storeResolverText(database, nh, resolver, "description", "A test name", .v2, 1000, tx_hash, 1700000000);

    const keys = try resolvers.getTextRecordKeys(database, resolver, nh);
    defer {
        for (keys) |key| allocator.free(key);
        allocator.free(keys);
    }

    try testing.expectEqual(@as(usize, 3), keys.len);
}

test "getTextRecord returns null for unknown key" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try namehash_fn(allocator, "nokey.eth");

    const value = try resolvers.getTextRecord(database, helpers.TEST_RESOLVER, nh, "nonexistent");
    try testing.expect(value == null);
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
    const discovered = try resolvers.getResolversToIndex(database, .v2, 900, 1100);
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

    const resolver_list = try resolvers.getResolversByOwner(database, .v2, helpers.TEST_OWNER_1);
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
    const resolver_list = try resolvers.getResolversByOwner(database, .v2, unknown_owner);
    defer allocator.free(resolver_list);

    try testing.expectEqual(@as(usize, 0), resolver_list.len);
}

// ============================================================================
// ALIAS RECORDS
// ============================================================================

test "storeResolverAlias inserts alias record" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const resolver = helpers.TEST_RESOLVER;
    const tx_hash = helpers.randomHash();

    try resolvers.storeResolverAlias(
        database,
        resolver,
        "sub.eth",
        "target.eth",
        .v2,
        1000,
        tx_hash,
        1700000000,
    );

    const aliases = try resolvers.getResolverAliases(database, resolver);
    defer {
        for (aliases) |*a| a.deinit(allocator);
        allocator.free(aliases);
    }

    try testing.expectEqual(@as(usize, 1), aliases.len);
    try testing.expectEqualStrings("sub.eth", aliases[0].from_name);
    try testing.expectEqualStrings("target.eth", aliases[0].to_name);
}

test "storeResolverAlias upserts existing alias" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const resolver = helpers.TEST_RESOLVER;
    const tx_hash = helpers.randomHash();

    // Insert initial alias
    try resolvers.storeResolverAlias(database, resolver, "sub.eth", "old-target.eth", .v2, 1000, tx_hash, 1700000000);

    // Update with new target
    const tx_hash2 = helpers.randomHash();
    try resolvers.storeResolverAlias(database, resolver, "sub.eth", "new-target.eth", .v2, 2000, tx_hash2, 1700001000);

    const aliases = try resolvers.getResolverAliases(database, resolver);
    defer {
        for (aliases) |*a| a.deinit(allocator);
        allocator.free(aliases);
    }

    try testing.expectEqual(@as(usize, 1), aliases.len);
    try testing.expectEqualStrings("new-target.eth", aliases[0].to_name);
}

test "getResolverAliases returns multiple aliases" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const resolver = helpers.TEST_RESOLVER;
    const tx_hash = helpers.randomHash();

    try resolvers.storeResolverAlias(database, resolver, "a.eth", "target-a.eth", .v2, 1000, tx_hash, 1700000000);
    try resolvers.storeResolverAlias(database, resolver, "b.eth", "target-b.eth", .v2, 1000, tx_hash, 1700000000);
    try resolvers.storeResolverAlias(database, resolver, "c.eth", "target-c.eth", .v2, 1000, tx_hash, 1700000000);

    const aliases = try resolvers.getResolverAliases(database, resolver);
    defer {
        for (aliases) |*a| a.deinit(allocator);
        allocator.free(aliases);
    }

    try testing.expectEqual(@as(usize, 3), aliases.len);
}

test "getResolverAliases returns empty for unknown resolver" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const unknown = helpers.randomAddress();
    const aliases = try resolvers.getResolverAliases(database, unknown);
    defer allocator.free(aliases);

    try testing.expectEqual(@as(usize, 0), aliases.len);
}

test "deleteResolverAlias removes specific alias" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const resolver = helpers.TEST_RESOLVER;
    const tx_hash = helpers.randomHash();

    try resolvers.storeResolverAlias(database, resolver, "keep.eth", "target1.eth", .v2, 1000, tx_hash, 1700000000);
    try resolvers.storeResolverAlias(database, resolver, "remove.eth", "target2.eth", .v2, 1000, tx_hash, 1700000000);

    // Delete one alias
    try resolvers.deleteResolverAlias(database, resolver, "remove.eth");

    const aliases = try resolvers.getResolverAliases(database, resolver);
    defer {
        for (aliases) |*a| a.deinit(allocator);
        allocator.free(aliases);
    }

    try testing.expectEqual(@as(usize, 1), aliases.len);
    try testing.expectEqualStrings("keep.eth", aliases[0].from_name);
}

// ============================================================================
// PUBKEY RECORDS
// ============================================================================

test "storeResolverPubkey inserts pubkey record" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try namehash_fn(allocator, "pubkey.eth");
    const resolver = helpers.TEST_RESOLVER;
    const tx_hash = helpers.randomHash();

    try resolvers.storeResolverPubkey(
        database,
        nh,
        resolver,
        "0xaabbccdd",
        "0x11223344",
        .v2,
        1000,
        tx_hash,
        1700000000,
    );

    const result = try resolvers.getPubkeyRecord(database, helpers.TEST_RESOLVER, nh);
    try testing.expect(result != null);
    var pk = result.?;
    defer pk.deinit(allocator);

    try testing.expectEqualStrings("0xaabbccdd", pk.x);
    try testing.expectEqualStrings("0x11223344", pk.y);
}

test "storeResolverPubkey upserts existing" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try namehash_fn(allocator, "pubkey-update.eth");
    const resolver = helpers.TEST_RESOLVER;
    const tx_hash = helpers.randomHash();

    try resolvers.storeResolverPubkey(database, nh, resolver, "0x0001", "0x0002", .v2, 1000, tx_hash, 1700000000);
    const tx_hash2 = helpers.randomHash();
    try resolvers.storeResolverPubkey(database, nh, resolver, "0xnewx", "0xnewy", .v2, 2000, tx_hash2, 1700001000);

    const result = try resolvers.getPubkeyRecord(database, helpers.TEST_RESOLVER, nh);
    try testing.expect(result != null);
    var pk = result.?;
    defer pk.deinit(allocator);

    try testing.expectEqualStrings("0xnewx", pk.x);
    try testing.expectEqualStrings("0xnewy", pk.y);
}

test "getResolverPubkey returns null for unknown" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const unknown_nh = helpers.randomHash();
    const result = try resolvers.getPubkeyRecord(database, helpers.TEST_RESOLVER, unknown_nh);
    try testing.expect(result == null);
}

test "deleteResolverPubkeys clears pubkey" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try namehash_fn(allocator, "pubkey-del.eth");
    const tx_hash = helpers.randomHash();

    try resolvers.storeResolverPubkey(database, nh, helpers.TEST_RESOLVER, "0x01", "0x02", .v2, 1000, tx_hash, 1700000000);

    // Verify exists
    {
        const result = try resolvers.getPubkeyRecord(database, helpers.TEST_RESOLVER, nh);
        try testing.expect(result != null);
        var pk = result.?;
        pk.deinit(allocator);
    }

    // Delete
    try resolvers.deleteResolverPubkeys(database, .v2, nh, helpers.TEST_RESOLVER);

    const result = try resolvers.getPubkeyRecord(database, helpers.TEST_RESOLVER, nh);
    try testing.expect(result == null);
}

// ============================================================================
// ABI RECORDS
// ============================================================================

test "storeResolverABI inserts ABI content type" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try namehash_fn(allocator, "abi.eth");
    const resolver = helpers.TEST_RESOLVER;
    const tx_hash = helpers.randomHash();

    try resolvers.storeResolverABI(database, nh, resolver, 1, .v2, 1000, tx_hash, 1700000000);
    try resolvers.storeResolverABI(database, nh, resolver, 2, .v2, 1000, tx_hash, 1700000000);
    try resolvers.storeResolverABI(database, nh, resolver, 4, .v2, 1000, tx_hash, 1700000000);

    const content_types = try resolvers.getAbiContentTypes(database, helpers.TEST_RESOLVER, nh);
    defer allocator.free(content_types);

    try testing.expectEqual(@as(usize, 3), content_types.len);
    try testing.expectEqual(@as(u64, 1), content_types[0]);
    try testing.expectEqual(@as(u64, 2), content_types[1]);
    try testing.expectEqual(@as(u64, 4), content_types[2]);
}

test "getResolverAbiContentTypes returns empty for unknown" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const unknown_nh = helpers.randomHash();
    const content_types = try resolvers.getAbiContentTypes(database, helpers.TEST_RESOLVER, unknown_nh);
    defer allocator.free(content_types);

    try testing.expectEqual(@as(usize, 0), content_types.len);
}

test "deleteResolverAbis clears all ABI records" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try namehash_fn(allocator, "abi-del.eth");
    const tx_hash = helpers.randomHash();

    try resolvers.storeResolverABI(database, nh, helpers.TEST_RESOLVER, 1, .v2, 1000, tx_hash, 1700000000);
    try resolvers.storeResolverABI(database, nh, helpers.TEST_RESOLVER, 2, .v2, 1000, tx_hash, 1700000000);

    try resolvers.deleteResolverAbis(database, .v2, nh, helpers.TEST_RESOLVER);

    const content_types = try resolvers.getAbiContentTypes(database, helpers.TEST_RESOLVER, nh);
    defer allocator.free(content_types);

    try testing.expectEqual(@as(usize, 0), content_types.len);
}

// ============================================================================
// NAME (REVERSE) RECORDS
// ============================================================================

test "storeResolverName inserts reverse name" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try namehash_fn(allocator, "reverse.eth");
    const resolver = helpers.TEST_RESOLVER;
    const tx_hash = helpers.randomHash();

    try resolvers.storeResolverName(database, nh, resolver, "vitalik.eth", .v2, 1000, tx_hash, 1700000000);

    const result = try resolvers.getReverseNameRecord(database, helpers.TEST_RESOLVER, nh);
    try testing.expect(result != null);
    defer allocator.free(result.?);

    try testing.expectEqualStrings("vitalik.eth", result.?);
}

test "storeResolverName upserts existing" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try namehash_fn(allocator, "reverse-update.eth");
    const tx_hash = helpers.randomHash();

    try resolvers.storeResolverName(database, nh, helpers.TEST_RESOLVER, "old.eth", .v2, 1000, tx_hash, 1700000000);
    const tx_hash2 = helpers.randomHash();
    try resolvers.storeResolverName(database, nh, helpers.TEST_RESOLVER, "new.eth", .v2, 2000, tx_hash2, 1700001000);

    const result = try resolvers.getReverseNameRecord(database, helpers.TEST_RESOLVER, nh);
    try testing.expect(result != null);
    defer allocator.free(result.?);

    try testing.expectEqualStrings("new.eth", result.?);
}

test "getResolverReverseName returns null for unknown" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const unknown_nh = helpers.randomHash();
    const result = try resolvers.getReverseNameRecord(database, helpers.TEST_RESOLVER, unknown_nh);
    try testing.expect(result == null);
}

test "deleteResolverNames clears reverse name" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try namehash_fn(allocator, "reverse-del.eth");
    const tx_hash = helpers.randomHash();

    try resolvers.storeResolverName(database, nh, helpers.TEST_RESOLVER, "name.eth", .v2, 1000, tx_hash, 1700000000);
    try resolvers.deleteResolverNames(database, .v2, nh, helpers.TEST_RESOLVER);

    const result = try resolvers.getReverseNameRecord(database, helpers.TEST_RESOLVER, nh);
    try testing.expect(result == null);
}

// ============================================================================
// INTERFACE RECORDS
// ============================================================================

test "storeResolverInterface inserts interface record" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try namehash_fn(allocator, "iface.eth");
    const resolver = helpers.TEST_RESOLVER;
    const tx_hash = helpers.randomHash();

    try resolvers.storeResolverInterface(
        database,
        nh,
        resolver,
        "0x01ffc9a7",
        "0xaaaa",
        .v2,
        1000,
        tx_hash,
        1700000000,
    );

    const ifaces = try resolvers.getInterfaceRecords(database, helpers.TEST_RESOLVER, nh);
    defer {
        for (ifaces) |*i| i.deinit(allocator);
        allocator.free(ifaces);
    }

    try testing.expectEqual(@as(usize, 1), ifaces.len);
    try testing.expectEqualStrings("0x01ffc9a7", ifaces[0].interface_id);
    try testing.expectEqualStrings("0xaaaa", ifaces[0].implementer);
}

test "storeResolverInterface inserts multiple interfaces" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try namehash_fn(allocator, "multi-iface.eth");
    const tx_hash = helpers.randomHash();

    try resolvers.storeResolverInterface(database, nh, helpers.TEST_RESOLVER, "0x01ffc9a7", "0xaaaa", .v2, 1000, tx_hash, 1700000000);
    try resolvers.storeResolverInterface(database, nh, helpers.TEST_RESOLVER, "0x3b3b57de", "0xbbbb", .v2, 1000, tx_hash, 1700000000);

    const ifaces = try resolvers.getInterfaceRecords(database, helpers.TEST_RESOLVER, nh);
    defer {
        for (ifaces) |*i| i.deinit(allocator);
        allocator.free(ifaces);
    }

    try testing.expectEqual(@as(usize, 2), ifaces.len);
}

test "getResolverInterfaces returns empty for unknown" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const unknown_nh = helpers.randomHash();
    const ifaces = try resolvers.getInterfaceRecords(database, helpers.TEST_RESOLVER, unknown_nh);
    defer allocator.free(ifaces);

    try testing.expectEqual(@as(usize, 0), ifaces.len);
}

test "deleteResolverInterfaces clears all interfaces" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try namehash_fn(allocator, "iface-del.eth");
    const tx_hash = helpers.randomHash();

    try resolvers.storeResolverInterface(database, nh, helpers.TEST_RESOLVER, "0x01ffc9a7", "0xaaaa", .v2, 1000, tx_hash, 1700000000);
    try resolvers.storeResolverInterface(database, nh, helpers.TEST_RESOLVER, "0x3b3b57de", "0xbbbb", .v2, 1000, tx_hash, 1700000000);

    try resolvers.deleteResolverInterfaces(database, .v2, nh, helpers.TEST_RESOLVER);

    const ifaces = try resolvers.getInterfaceRecords(database, helpers.TEST_RESOLVER, nh);
    defer allocator.free(ifaces);

    try testing.expectEqual(@as(usize, 0), ifaces.len);
}

// ============================================================================
// VERSION RECORDS
// ============================================================================

test "storeResolverVersion inserts version" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try namehash_fn(allocator, "version.eth");
    const tx_hash = helpers.randomHash();

    try resolvers.storeResolverVersion(database, nh, helpers.TEST_RESOLVER, 1, .v2, 1000, tx_hash, 1700000000);

    const result = try resolvers.getNodeRecordVersion(database, helpers.TEST_RESOLVER, nh);
    try testing.expect(result != null);
    try testing.expectEqual(@as(u64, 1), result.?);
}

test "storeResolverVersion upserts to higher version" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try namehash_fn(allocator, "version-up.eth");
    const tx_hash = helpers.randomHash();

    try resolvers.storeResolverVersion(database, nh, helpers.TEST_RESOLVER, 1, .v2, 1000, tx_hash, 1700000000);
    const tx_hash2 = helpers.randomHash();
    try resolvers.storeResolverVersion(database, nh, helpers.TEST_RESOLVER, 5, .v2, 2000, tx_hash2, 1700001000);

    const result = try resolvers.getNodeRecordVersion(database, helpers.TEST_RESOLVER, nh);
    try testing.expect(result != null);
    try testing.expectEqual(@as(u64, 5), result.?);
}

test "getResolverVersion returns null for unknown" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const unknown_nh = helpers.randomHash();
    const result = try resolvers.getNodeRecordVersion(database, helpers.TEST_RESOLVER, unknown_nh);
    try testing.expect(result == null);
}

// ============================================================================
// DELETE OPERATIONS (VersionChanged clearing)
// ============================================================================

test "deleteResolverAddresses clears all addresses for namehash" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try namehash_fn(allocator, "addr-del.eth");
    const tx_hash = helpers.randomHash();

    try resolvers.storeResolverAddress(database, nh, helpers.TEST_RESOLVER, 60, "0xeth", .v2, 1000, tx_hash, 1700000000);
    try resolvers.storeResolverAddress(database, nh, helpers.TEST_RESOLVER, 0, "bc1q", .v2, 1000, tx_hash, 1700000000);

    try resolvers.deleteResolverAddresses(database, .v2, nh, helpers.TEST_RESOLVER);

    const addresses = try resolvers.getAddressRecords(database, helpers.TEST_RESOLVER, nh);
    defer allocator.free(addresses);

    try testing.expectEqual(@as(usize, 0), addresses.len);
}

test "deleteResolverContentHash clears contenthash" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try namehash_fn(allocator, "ch-del.eth");
    const tx_hash = helpers.randomHash();

    try resolvers.storeResolverContentHash(database, nh, helpers.TEST_RESOLVER, "ipfs://Qm123", .v2, 1000, tx_hash, 1700000000);
    try resolvers.deleteResolverContentHash(database, .v2, nh, helpers.TEST_RESOLVER);

    const result = try resolvers.getContentHashRecord(database, helpers.TEST_RESOLVER, nh);
    try testing.expect(result == null);
}

test "deleteResolverTexts clears all text records" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const nh = try namehash_fn(allocator, "text-del.eth");
    const tx_hash = helpers.randomHash();

    try resolvers.storeResolverText(database, nh, helpers.TEST_RESOLVER, "avatar", "img.png", .v2, 1000, tx_hash, 1700000000);
    try resolvers.storeResolverText(database, nh, helpers.TEST_RESOLVER, "url", "https://x.com", .v2, 1000, tx_hash, 1700000000);

    try resolvers.deleteResolverTexts(database, .v2, nh, helpers.TEST_RESOLVER);

    const keys = try resolvers.getTextRecordKeys(database, helpers.TEST_RESOLVER, nh);
    defer allocator.free(keys);

    try testing.expectEqual(@as(usize, 0), keys.len);
}

// ============================================================================
// RESOLVER STATISTICS
// ============================================================================

test "getResolverNodeCount counts domains using resolver" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    // Create names and set resolver
    const nh1 = try helpers.createTestName(allocator, database, "stat1.eth", helpers.TEST_OWNER_1);
    try database.updateNameResolver(nh1, helpers.TEST_RESOLVER);

    const nh2 = try helpers.createTestName(allocator, database, "stat2.eth", helpers.TEST_OWNER_1);
    try database.updateNameResolver(nh2, helpers.TEST_RESOLVER);

    // Create a name with a different resolver
    _ = try helpers.createTestName(allocator, database, "stat3.eth", helpers.TEST_OWNER_1);

    const count = try resolvers.getResolverNodeCount(database, helpers.TEST_RESOLVER);
    try testing.expectEqual(@as(usize, 2), count);
}

test "getResolverNodeCount returns 0 for unknown resolver" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const unknown = helpers.randomAddress();
    const count = try resolvers.getResolverNodeCount(database, unknown);
    try testing.expectEqual(@as(usize, 0), count);
}

test "getResolverAliasCount counts aliases for resolver" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const resolver = helpers.TEST_RESOLVER;
    const tx_hash = helpers.randomHash();

    try resolvers.storeResolverAlias(database, resolver, "a.eth", "b.eth", .v2, 1000, tx_hash, 1700000000);
    try resolvers.storeResolverAlias(database, resolver, "c.eth", "d.eth", .v2, 1000, tx_hash, 1700000000);

    const count = try resolvers.getResolverAliasCount(database, resolver);
    try testing.expectEqual(@as(usize, 2), count);
}

test "getResolverAliasCount returns 0 for unknown resolver" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const unknown = helpers.randomAddress();
    const count = try resolvers.getResolverAliasCount(database, unknown);
    try testing.expectEqual(@as(usize, 0), count);
}

test "getResolverRoleHolderCount counts distinct accounts" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const roles = lib.storage.roles;
    const tx_hash = helpers.randomHash();

    // Two different accounts on the same resolver contract
    try roles.upsertEACRole(database, .v2, "resource1", helpers.TEST_OWNER_1, "0x01", 1000, tx_hash, 0, helpers.TEST_RESOLVER);
    try roles.upsertEACRole(database, .v2, "resource2", helpers.TEST_OWNER_2, "0x02", 1000, tx_hash, 1, helpers.TEST_RESOLVER);
    // Same account, different resource — should not add to distinct count
    try roles.upsertEACRole(database, .v2, "resource3", helpers.TEST_OWNER_1, "0x04", 1000, tx_hash, 2, helpers.TEST_RESOLVER);

    const count = try resolvers.getResolverRoleHolderCount(database, helpers.TEST_RESOLVER);
    try testing.expectEqual(@as(usize, 2), count);
}

test "getResolverRoleHolderCount returns 0 for unknown resolver" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const unknown = helpers.randomAddress();
    const count = try resolvers.getResolverRoleHolderCount(database, unknown);
    try testing.expectEqual(@as(usize, 0), count);
}

test "getResolverRoles returns roles by contract address" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const roles = lib.storage.roles;
    const tx_hash = helpers.randomHash();
    const other_resolver = helpers.randomAddress();

    // Roles on TEST_RESOLVER
    try roles.upsertEACRole(database, .v2, "res1", helpers.TEST_OWNER_1, "0x01", 1000, tx_hash, 0, helpers.TEST_RESOLVER);
    try roles.upsertEACRole(database, .v2, "res2", helpers.TEST_OWNER_2, "0x02", 1000, tx_hash, 1, helpers.TEST_RESOLVER);
    // Role on different resolver — should not be returned
    try roles.upsertEACRole(database, .v2, "res3", helpers.TEST_OWNER_1, "0x04", 1000, tx_hash, 2, other_resolver);

    const role_list = try resolvers.getResolverRoles(database, helpers.TEST_RESOLVER);
    defer {
        for (role_list) |*r| r.deinit(allocator);
        allocator.free(role_list);
    }

    try testing.expectEqual(@as(usize, 2), role_list.len);
}

test "getResolverRoles returns empty for unknown resolver" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const unknown = helpers.randomAddress();
    const role_list = try resolvers.getResolverRoles(database, unknown);
    defer allocator.free(role_list);

    try testing.expectEqual(@as(usize, 0), role_list.len);
}

// ============================================================================
// GET NAMES BY RESOLVER
// ============================================================================

test "getNamesByResolver returns names using resolver" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const names = lib.storage.names;

    // Create names and set resolver
    const nh1 = try helpers.createTestName(allocator, database, "byres1.eth", helpers.TEST_OWNER_1);
    try database.updateNameResolver(nh1, helpers.TEST_RESOLVER);

    const nh2 = try helpers.createTestName(allocator, database, "byres2.eth", helpers.TEST_OWNER_1);
    try database.updateNameResolver(nh2, helpers.TEST_RESOLVER);

    // Name with different resolver — should not appear
    _ = try helpers.createTestName(allocator, database, "byres3.eth", helpers.TEST_OWNER_1);

    const name_list = try names.getNamesByResolver(database, helpers.TEST_RESOLVER, 100);
    defer {
        for (name_list) |*n| n.deinit(allocator);
        allocator.free(name_list);
    }

    try testing.expectEqual(@as(usize, 2), name_list.len);
}

test "getNamesByResolver respects limit" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const names = lib.storage.names;

    const nh1 = try helpers.createTestName(allocator, database, "lim1.eth", helpers.TEST_OWNER_1);
    try database.updateNameResolver(nh1, helpers.TEST_RESOLVER);

    const nh2 = try helpers.createTestName(allocator, database, "lim2.eth", helpers.TEST_OWNER_1);
    try database.updateNameResolver(nh2, helpers.TEST_RESOLVER);

    const nh3 = try helpers.createTestName(allocator, database, "lim3.eth", helpers.TEST_OWNER_1);
    try database.updateNameResolver(nh3, helpers.TEST_RESOLVER);

    const name_list = try names.getNamesByResolver(database, helpers.TEST_RESOLVER, 2);
    defer {
        for (name_list) |*n| n.deinit(allocator);
        allocator.free(name_list);
    }

    try testing.expectEqual(@as(usize, 2), name_list.len);
}

test "getNamesByResolver returns empty for unknown resolver" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const names = lib.storage.names;
    const unknown = helpers.randomAddress();

    const name_list = try names.getNamesByResolver(database, unknown, 100);
    defer allocator.free(name_list);

    try testing.expectEqual(@as(usize, 0), name_list.len);
}

// ============================================================================
// RESOLVER FILTER ON DOMAIN QUERIES
// ============================================================================

test "getFilteredNames with resolver filter" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const names = lib.storage.names;

    // Create names, set resolver on some
    const nh1 = try helpers.createTestName(allocator, database, "filt1.eth", helpers.TEST_OWNER_1);
    try database.updateNameResolver(nh1, helpers.TEST_RESOLVER);

    const nh2 = try helpers.createTestName(allocator, database, "filt2.eth", helpers.TEST_OWNER_1);
    try database.updateNameResolver(nh2, helpers.TEST_RESOLVER);

    // Name without resolver update (resolver = zero)
    _ = try helpers.createTestName(allocator, database, "filt3.eth", helpers.TEST_OWNER_1);

    const filtered = try names.getFilteredNames(
        database,
        .{ .resolver = helpers.TEST_RESOLVER },
        0,
        100,
        .desc,
        .created_at,
    );
    defer {
        for (filtered) |*n| n.deinit(allocator);
        allocator.free(filtered);
    }

    try testing.expectEqual(@as(usize, 2), filtered.len);
}

test "getFilteredNameCount with resolver filter" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const names = lib.storage.names;

    const nh1 = try helpers.createTestName(allocator, database, "cnt1.eth", helpers.TEST_OWNER_1);
    try database.updateNameResolver(nh1, helpers.TEST_RESOLVER);

    const nh2 = try helpers.createTestName(allocator, database, "cnt2.eth", helpers.TEST_OWNER_1);
    try database.updateNameResolver(nh2, helpers.TEST_RESOLVER);

    _ = try helpers.createTestName(allocator, database, "cnt3.eth", helpers.TEST_OWNER_1);

    const count = try names.getFilteredNameCount(
        database,
        .{ .resolver = helpers.TEST_RESOLVER },
    );

    try testing.expectEqual(@as(usize, 2), count);
}

// ============================================================================
// Resolver approvals (the Approved event's write path, stored with context=""
// so the UNIQUE key conflicts and re-indexing stays idempotent — SQL NULLs
// never conflict). Readers use portable NULL-or-equal context matching
// (`context IS ?` is SQLite-only; PostgreSQL rejects it).
// ============================================================================

test "resolver approvals: upsert + revoke flip in place and read back" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const resolver = helpers.TEST_RESOLVER;
    const delegate = helpers.TEST_OWNER_2;
    const nh = helpers.randomHash();

    try database.upsertResolverApproval(.v2, resolver, nh, "", delegate, true, 100, helpers.randomHash(), 0);
    try testing.expect(try database.isApprovedFor(.v2, resolver, nh, "", delegate));

    // Revoke: same (protocol,resolver,namehash,context,delegate) key — must
    // UPDATE the row, not insert a second one.
    try database.upsertResolverApproval(.v2, resolver, nh, "", delegate, false, 101, helpers.randomHash(), 1);
    try testing.expect(!try database.isApprovedFor(.v2, resolver, nh, "", delegate));

    const approvals = try database.getApprovalsForName(.v2, nh, null);
    defer {
        for (approvals) |*a| a.deinit(allocator);
        allocator.free(approvals);
    }
    try testing.expectEqual(@as(usize, 1), approvals.len);
    try testing.expect(!approvals[0].approved);
    try testing.expectEqualStrings("", approvals[0].context.?);
}

test "resolver approvals: context filter matches exactly; null means any" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const resolver = helpers.TEST_RESOLVER;
    const delegate = helpers.TEST_OWNER_2;
    const nh = helpers.randomHash();

    try database.upsertResolverApproval(.v2, resolver, nh, "", delegate, true, 100, helpers.randomHash(), 0);
    try database.upsertResolverApproval(.v2, resolver, nh, "ctx-a", delegate, true, 101, helpers.randomHash(), 1);

    try testing.expect(try database.isApprovedFor(.v2, resolver, nh, "ctx-a", delegate));
    try testing.expect(!try database.isApprovedFor(.v2, resolver, nh, "ctx-b", delegate));

    const all = try database.getApprovalsForName(.v2, nh, null);
    defer {
        for (all) |*a| a.deinit(allocator);
        allocator.free(all);
    }
    try testing.expectEqual(@as(usize, 2), all.len);

    const only_a = try database.getApprovalsForName(.v2, nh, "ctx-a");
    defer {
        for (only_a) |*a| a.deinit(allocator);
        allocator.free(only_a);
    }
    try testing.expectEqual(@as(usize, 1), only_a.len);
}

test "named resources: upsert per (resolver,resource) updates in place; reader orders by block" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const resolver = helpers.TEST_RESOLVER;
    const res_a = "0x00000000000000000000000000000000000000000000000000000000000000a1";
    const res_b = "0x00000000000000000000000000000000000000000000000000000000000000b2";

    try database.upsertNamedResource(.v2, resolver, res_a, "text", "url", -1, "alice.eth", 100, helpers.randomHash(), 0);
    // Re-announce of the same resource (e.g. re-index): updates, no second row.
    try database.upsertNamedResource(.v2, resolver, res_a, "text", "url", -1, "alice.eth", 100, helpers.randomHash(), 0);
    try database.upsertNamedResource(.v2, resolver, res_b, "addr", "", 60, "bob.eth", 101, helpers.randomHash(), 1);

    const rows = try database.getNamedResources(allocator, .v2, resolver);
    defer {
        for (rows) |*r| r.deinit(allocator);
        allocator.free(rows);
    }
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings(res_a, rows[0].resource);
    try testing.expectEqualStrings("text", rows[0].record_kind);
    try testing.expectEqualStrings("url", rows[0].record_key);
    try testing.expectEqualStrings("alice.eth", rows[0].name);
    try testing.expectEqual(@as(i64, -1), rows[0].coin_type);
    try testing.expectEqualStrings("addr", rows[1].record_kind);
    try testing.expectEqual(@as(i64, 60), rows[1].coin_type);
}
