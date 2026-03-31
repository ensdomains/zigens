const std = @import("std");
const testing = std.testing;

// Import modules via lib
const lib = @import("lib");
const Address = lib.Address;
const Hash = lib.Hash;
const models = lib.models;
const Database = lib.Database;
const namehash = lib.namehash;
const keccak256 = lib.keccak256;

test "Database integration - full workflow" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create in-memory database
    var database = try Database.init(allocator, ":memory:");
    defer database.deinit();

    // Test 1: Insert a registry
    const eth_registry = models.Registry{
        .address = try Address.fromHex("0x0000000000000000000000000000000000000001"),
        .chain = .l2,
        .name = "eth",
        .namehash = try namehash(allocator, "eth"),
        .parent_registry = Address.zero,
        .created_block = 100,
        .created_at = std.time.timestamp(),
    };

    try database.insertRegistry(eth_registry);
    std.debug.print("✓ Registry inserted\n", .{});

    // Test 2: Insert a name
    const ts = std.time.timestamp();
    {
        var alice_eth = models.Name{
            .name = try allocator.dupe(u8, "alice.eth"),
            .namehash = try namehash(allocator, "alice.eth"),
            .label = try allocator.dupe(u8, "alice"),
            .label_hash = try keccak256(allocator, "alice"),
            .parent_name = try allocator.dupe(u8, "eth"),
            .parent_namehash = try namehash(allocator, "eth"),
            .chain = .l2,
            .registry = try Address.fromHex("0x0000000000000000000000000000000000000001"),
            .owner = try Address.fromHex("0x0000000000000000000000000000000000000123"),
            .registrant = try Address.fromHex("0x0000000000000000000000000000000000000123"),
            .resolver = try Address.fromHex("0x0000000000000000000000000000000000000456"),
            .token_id = 12345,
            .canonical_id = 12345,
            .token_version = 1,
            .expiry = @intCast(ts + 31536000), // 1 year from now
            .registry_locked = false,
            .migrated = true,
            .ejected = false,
            .created_block = 101,
            .created_at = ts,
            .registered_at = ts,
            .updated_block = 101,
            .updated_at = ts,
            .is_wrapped = false,
            .wrapper_fuses = null,
            .wrapper_expiry = null,
            .is_v1_name = false,
            .v1_label_hash = null,
        };
        defer alice_eth.deinit(allocator);

        try database.insertName(alice_eth);
    }
    std.debug.print("✓ Name inserted\n", .{});

    // Test 3: Query name by namehash
    const nh = try namehash(allocator, "alice.eth");
    const retrieved = try database.getNameByNamehash(nh);

    try testing.expect(retrieved != null);
    if (retrieved) |n| {
        var name = n;
        defer name.deinit(allocator);
        try testing.expectEqualStrings("alice.eth", name.name.?);
        try testing.expect(name.chain == .l2);
        try testing.expect(!name.ejected);
        try testing.expect(name.migrated);
        std.debug.print("✓ Name retrieved successfully\n", .{});
    }

    // Test 4: Insert an event
    {
        var event = models.Event{
            .event_type = .name_registered,
            .chain = .l2,
            .block_number = 101,
            .tx_hash = try Hash.fromHex("0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"),
            .log_index = 0,
            .contract_address = try Address.fromHex("0x0000000000000000000000000000000000000001"),
            .name = try allocator.dupe(u8, "alice.eth"),
            .namehash = try namehash(allocator, "alice.eth"),
            .data = try allocator.dupe(u8, "{}"),
            .timestamp = ts,
        };
        defer event.deinit(allocator);

        try database.insertEvent(event);
    }
    std.debug.print("✓ Event inserted\n", .{});

    // Test 5: Sync state management
    try database.setSyncState(.l2, 200);
    const sync_state = try database.getSyncState(.l2);
    try testing.expect(sync_state != null);
    try testing.expectEqual(@as(u64, 200), sync_state.?);
    std.debug.print("✓ Sync state managed correctly\n", .{});

    std.debug.print("\n✅ All database integration tests passed!\n", .{});
}

test "Namehash computation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test empty string (root)
    const root = try namehash(allocator, "");
    try testing.expect(root.isZero());
    std.debug.print("✓ Root namehash is zero\n", .{});

    // Test eth
    const eth = try namehash(allocator, "eth");
    try testing.expect(!eth.isZero());
    std.debug.print("✓ ETH namehash computed\n", .{});

    // Test alice.eth
    const alice_eth = try namehash(allocator, "alice.eth");
    try testing.expect(!alice_eth.isZero());
    try testing.expect(!alice_eth.eql(eth));
    std.debug.print("✓ alice.eth namehash computed\n", .{});

    // Test foo.alice.eth
    const foo_alice_eth = try namehash(allocator, "foo.alice.eth");
    try testing.expect(!foo_alice_eth.isZero());
    try testing.expect(!foo_alice_eth.eql(alice_eth));
    std.debug.print("✓ foo.alice.eth namehash computed\n", .{});

    std.debug.print("\n✅ All namehash tests passed!\n", .{});
}

test "Address formatting" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test zero address
    const zero = Address.zero;
    try testing.expect(zero.isZero());
    std.debug.print("✓ Zero address detected\n", .{});

    // Test address parsing
    const addr = try Address.fromHex("0x0000000000000000000000000000000000000001");
    try testing.expect(!addr.isZero());
    try testing.expect(addr.bytes[19] == 1);
    std.debug.print("✓ Address parsed correctly\n", .{});

    // Test address formatting
    const hex = try addr.toHex(allocator);
    defer allocator.free(hex);
    try testing.expectEqualStrings("0x0000000000000000000000000000000000000001", hex);
    std.debug.print("✓ Address formatted correctly\n", .{});

    std.debug.print("\n✅ All address tests passed!\n", .{});
}

test "Event type conversion" {
    const event_types = [_]models.EventType{
        .new_subname,
        .subregistry_update,
        .resolver_update,
        .transfer,
        .name_registered,
        .name_renewed,
        .name_migrated,
        .name_ejected_to_l1,
        .name_returned_to_l2,
    };

    for (event_types) |et| {
        const str = et.toString();
        try testing.expect(str.len > 0);
        std.debug.print("✓ Event type '{s}' converted\n", .{str});
    }

    std.debug.print("\n✅ All event type tests passed!\n", .{});
}

test "Chain type conversion" {
    const l1 = models.Chain.l1;
    const l2 = models.Chain.l2;

    try testing.expectEqualStrings("l1", l1.toString());
    try testing.expectEqualStrings("l2", l2.toString());

    const l1_parsed = try models.Chain.fromString("l1");
    const l2_parsed = try models.Chain.fromString("l2");

    try testing.expect(l1_parsed == .l1);
    try testing.expect(l2_parsed == .l2);

    std.debug.print("✓ Chain types converted correctly\n", .{});
    std.debug.print("\n✅ All chain type tests passed!\n", .{});
}

test "Multiple name insertions and queries" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try Database.init(allocator, ":memory:");
    defer database.deinit();

    const names = [_][]const u8{ "alice.eth", "bob.eth", "charlie.eth" };

    // Insert multiple names
    for (names, 0..) |name_str, i| {
        const loop_ts = std.time.timestamp();
        var name = models.Name{
            .name = try allocator.dupe(u8, name_str),
            .namehash = try namehash(allocator, name_str),
            .label = try allocator.dupe(u8, name_str[0 .. name_str.len - 4]), // Remove .eth
            .label_hash = try keccak256(allocator, name_str[0 .. name_str.len - 4]),
            .parent_name = try allocator.dupe(u8, "eth"),
            .parent_namehash = try namehash(allocator, "eth"),
            .chain = .l2,
            .registry = try Address.fromHex("0x0000000000000000000000000000000000000001"),
            .owner = try Address.fromHex("0x0000000000000000000000000000000000000123"),
            .registrant = try Address.fromHex("0x0000000000000000000000000000000000000123"),
            .resolver = try Address.fromHex("0x0000000000000000000000000000000000000456"),
            .token_id = @intCast(i + 1),
            .canonical_id = @intCast(i + 1),
            .token_version = 1,
            .expiry = @intCast(loop_ts + 31536000),
            .registry_locked = false,
            .migrated = true,
            .ejected = false,
            .created_block = @intCast(100 + i),
            .created_at = loop_ts,
            .registered_at = loop_ts,
            .updated_block = @intCast(100 + i),
            .updated_at = loop_ts,
            .is_wrapped = false,
            .wrapper_fuses = null,
            .wrapper_expiry = null,
            .is_v1_name = false,
            .v1_label_hash = null,
        };
        defer name.deinit(allocator);

        try database.insertName(name);
        std.debug.print("✓ Inserted {s}\n", .{name_str});
    }

    // Query each name
    for (names) |name_str| {
        const nh = try namehash(allocator, name_str);
        const retrieved = try database.getNameByNamehash(nh);

        try testing.expect(retrieved != null);
        if (retrieved) |n| {
            var name = n;
            defer name.deinit(allocator);
            try testing.expectEqualStrings(name_str, name.name.?);
            std.debug.print("✓ Retrieved {s}\n", .{name_str});
        }
    }

    std.debug.print("\n✅ All multiple name tests passed!\n", .{});
}

test "Name expiry checking" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const ts = std.time.timestamp();

    // Create expired name
    const expired_name = models.Name{
        .name = try allocator.dupe(u8, "expired.eth"),
        .namehash = try namehash(allocator, "expired.eth"),
        .label = try allocator.dupe(u8, "expired"),
        .label_hash = try keccak256(allocator, "expired"),
        .parent_name = try allocator.dupe(u8, "eth"),
        .parent_namehash = try namehash(allocator, "eth"),
        .chain = .l2,
        .registry = Address.zero,
        .owner = Address.zero,
        .registrant = Address.zero,
        .resolver = Address.zero,
        .token_id = 1,
        .canonical_id = 1,
        .token_version = 1,
        .expiry = @intCast(ts - 1), // Already expired
        .registry_locked = false,
        .migrated = false,
        .ejected = false,
        .created_block = 100,
        .created_at = ts,
        .registered_at = ts,
        .updated_block = 100,
        .updated_at = ts,
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    };

    try testing.expect(expired_name.isExpired());
    std.debug.print("✓ Expired name detected\n", .{});

    // Create valid name
    const valid_name = models.Name{
        .name = try allocator.dupe(u8, "valid.eth"),
        .namehash = try namehash(allocator, "valid.eth"),
        .label = try allocator.dupe(u8, "valid"),
        .label_hash = try keccak256(allocator, "valid"),
        .parent_name = try allocator.dupe(u8, "eth"),
        .parent_namehash = try namehash(allocator, "eth"),
        .chain = .l2,
        .registry = Address.zero,
        .owner = Address.zero,
        .registrant = Address.zero,
        .resolver = Address.zero,
        .token_id = 1,
        .canonical_id = 1,
        .token_version = 1,
        .expiry = @intCast(ts + 31536000), // 1 year from now
        .registry_locked = false,
        .migrated = false,
        .ejected = false,
        .created_block = 100,
        .created_at = ts,
        .registered_at = ts,
        .updated_block = 100,
        .updated_at = ts,
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    };

    try testing.expect(!valid_name.isExpired());
    std.debug.print("✓ Valid name not expired\n", .{});

    // Clean up
    var expired_copy = expired_name;
    expired_copy.deinit(allocator);
    var valid_copy = valid_name;
    valid_copy.deinit(allocator);

    std.debug.print("\n✅ All expiry tests passed!\n", .{});
}
