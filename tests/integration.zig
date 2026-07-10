const std = @import("std");
const zsys = @import("lib").zsys;
const testing = std.testing;

// Import modules via lib
const lib = @import("lib");
const Address = lib.Address;
const Hash = lib.Hash;
const models = lib.models;
const Database = lib.Database;
const namehash = lib.namehash;
const keccak256 = lib.keccak256;

/// Per-test database. SQLite (:memory:) by default; when TEST_BACKEND=postgres, opens the
/// local `ensv2_test` in a fresh, UNIQUELY-NAMED schema set as the connection's search_path.
/// Each call gets its own schema, so tests that hold two databases at once (the reorg
/// reconcile tests) stay isolated — unlike `public`, which they'd clobber. The schema name
/// is monotonic across the binary's sequential tests; DROP IF EXISTS makes re-runs idempotent.
var pg_schema_seq: usize = 0;

fn testDb(allocator: std.mem.Allocator) !Database {
    const want_pg = blk: {
        const v = zsys.getEnvOwned(allocator, "TEST_BACKEND") catch break :blk false;
        defer allocator.free(v);
        break :blk std.ascii.eqlIgnoreCase(v, "postgres");
    };
    if (!want_pg) {
        const force_fallback = blk: {
            const v = zsys.getEnvOwned(allocator, "TEST_FORCE_WRITE_PATH_UNDO") catch break :blk false;
            defer allocator.free(v);
            break :blk std.mem.eql(u8, v, "1");
        };
        if (force_fallback) {
            // Forced-fallback lane (test-integration-fallback): no capture
            // triggers; the storage mutators' write-path capture must keep the
            // reorg suite green.
            var be = try lib.storage.sqlite.open(allocator, ":memory:");
            be.caps.server_side_undo = false;
            return Database.initWithBackend(allocator, be);
        }
        return Database.init(allocator, ":memory:");
    }

    const be = try lib.storage.postgres.open(allocator, .{ .database = "ensv2_test", .password = "postgres" });
    // Close `be` on any failure before initWithBackend takes ownership (it closes `be`
    // itself on its own error, so don't double-close after handing it over).
    pg_schema_seq += 1;
    const setup = std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS it_{d} CASCADE; CREATE SCHEMA it_{d}; SET search_path TO it_{d}", .{ pg_schema_seq, pg_schema_seq, pg_schema_seq }) catch |err| {
        be.vtable.close(be.ptr);
        return err;
    };
    defer allocator.free(setup);
    be.vtable.execRaw(be.ptr, setup) catch |err| {
        be.vtable.close(be.ptr);
        return err;
    };
    return Database.initWithBackend(allocator, be); // loads schema/postgres into search_path + reorg
}

test "Database integration - full workflow" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create in-memory database
    var database = try testDb(allocator);
    defer database.deinit();

    // Test 1: Insert a registry
    const eth_registry = models.Registry{
        .address = try Address.fromHex("0x0000000000000000000000000000000000000001"),
        .protocol = .v2,
        .name = "eth",
        .namehash = try namehash(allocator, "eth"),
        .parent_registry = Address.zero,
        .created_block = 100,
        .created_at = zsys.timestamp(),
    };

    try database.insertRegistry(eth_registry);
    std.debug.print("✓ Registry inserted\n", .{});

    // Test 2: Insert a name
    const ts = zsys.timestamp();
    {
        var alice_eth = models.Name{
            .name = try allocator.dupe(u8, "alice.eth"),
            .namehash = try namehash(allocator, "alice.eth"),
            .label = try allocator.dupe(u8, "alice"),
            .label_hash = try keccak256(allocator, "alice"),
            .parent_name = try allocator.dupe(u8, "eth"),
            .parent_namehash = try namehash(allocator, "eth"),
            .protocol = .v2,
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
        try testing.expect(name.protocol == .v2);
        try testing.expect(name.migrated);
        std.debug.print("✓ Name retrieved successfully\n", .{});
    }

    // Test 4: Insert an event
    {
        var event = models.Event{
            .event_type = .name_registered,
            .protocol = .v2,
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
    try database.setSyncState(.v2, 200);
    const sync_state = try database.getSyncState(.v2);
    try testing.expect(sync_state != null);
    try testing.expectEqual(@as(u64, 200), sync_state.?);
    std.debug.print("✓ Sync state managed correctly\n", .{});

    std.debug.print("\n✅ All database integration tests passed!\n", .{});
}

test "Namehash computation" {
    var gpa = std.heap.DebugAllocator(.{}){};
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
    var gpa = std.heap.DebugAllocator(.{}){};
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
    };

    for (event_types) |et| {
        const str = et.toString();
        try testing.expect(str.len > 0);
        std.debug.print("✓ Event type '{s}' converted\n", .{str});
    }

    std.debug.print("\n✅ All event type tests passed!\n", .{});
}

test "Chain type conversion" {
    const l1 = models.Protocol.v1;
    const l2 = models.Protocol.v2;

    try testing.expectEqualStrings("v1", l1.toString());
    try testing.expectEqualStrings("v2", l2.toString());

    const l1_parsed = try models.Protocol.fromString("v1");
    const l2_parsed = try models.Protocol.fromString("v2");

    try testing.expect(l1_parsed == .v1);
    try testing.expect(l2_parsed == .v2);

    std.debug.print("✓ Chain types converted correctly\n", .{});
    std.debug.print("\n✅ All protocol type tests passed!\n", .{});
}

test "Multiple name insertions and queries" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try testDb(allocator);
    defer database.deinit();

    const names = [_][]const u8{ "alice.eth", "bob.eth", "charlie.eth" };

    // Insert multiple names
    for (names, 0..) |name_str, i| {
        const loop_ts = zsys.timestamp();
        var name = models.Name{
            .name = try allocator.dupe(u8, name_str),
            .namehash = try namehash(allocator, name_str),
            .label = try allocator.dupe(u8, name_str[0 .. name_str.len - 4]), // Remove .eth
            .label_hash = try keccak256(allocator, name_str[0 .. name_str.len - 4]),
            .parent_name = try allocator.dupe(u8, "eth"),
            .parent_namehash = try namehash(allocator, "eth"),
            .protocol = .v2,
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
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const ts = zsys.timestamp();

    // Create expired name
    const expired_name = models.Name{
        .name = try allocator.dupe(u8, "expired.eth"),
        .namehash = try namehash(allocator, "expired.eth"),
        .label = try allocator.dupe(u8, "expired"),
        .label_hash = try keccak256(allocator, "expired"),
        .parent_name = try allocator.dupe(u8, "eth"),
        .parent_namehash = try namehash(allocator, "eth"),
        .protocol = .v2,
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
        .protocol = .v2,
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

// ============================================================================
// Regression tests for reorg rollback (task #1)
// ============================================================================

test "reorg rollback deletes derived state created after the block" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try testDb(allocator);
    defer database.deinit();

    // Insert a name created at block 200
    var n200 = models.Name{
        .name = try allocator.dupe(u8, "late.eth"),
        .namehash = try namehash(allocator, "late.eth"),
        .label = try allocator.dupe(u8, "late"),
        .label_hash = try keccak256(allocator, "late"),
        .parent_name = try allocator.dupe(u8, "eth"),
        .parent_namehash = try namehash(allocator, "eth"),
        .protocol = .v2,
        .registry = try Address.fromHex("0x0000000000000000000000000000000000000001"),
        .owner = try Address.fromHex("0x0000000000000000000000000000000000000aaa"),
        .registrant = try Address.fromHex("0x0000000000000000000000000000000000000aaa"),
        .resolver = Address.zero,
        .token_id = 1,
        .canonical_id = 1,
        .token_version = 1,
        .expiry = 0,
        .registry_locked = false,
        .migrated = false,
        .created_block = 200,
        .created_at = 1700000200,
        .registered_at = 1700000200,
        .updated_block = 200,
        .updated_at = 1700000200,
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    };
    defer n200.deinit(allocator);
    try database.insertName(n200);

    // Insert a name at block 100 (pre-reorg)
    var n100 = models.Name{
        .name = try allocator.dupe(u8, "early.eth"),
        .namehash = try namehash(allocator, "early.eth"),
        .label = try allocator.dupe(u8, "early"),
        .label_hash = try keccak256(allocator, "early"),
        .parent_name = try allocator.dupe(u8, "eth"),
        .parent_namehash = try namehash(allocator, "eth"),
        .protocol = .v2,
        .registry = try Address.fromHex("0x0000000000000000000000000000000000000001"),
        .owner = try Address.fromHex("0x0000000000000000000000000000000000000bbb"),
        .registrant = try Address.fromHex("0x0000000000000000000000000000000000000bbb"),
        .resolver = Address.zero,
        .token_id = 2,
        .canonical_id = 2,
        .token_version = 1,
        .expiry = 0,
        .registry_locked = false,
        .migrated = false,
        .created_block = 100,
        .created_at = 1700000100,
        .registered_at = 1700000100,
        .updated_block = 100,
        .updated_at = 1700000100,
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    };
    defer n100.deinit(allocator);
    try database.insertName(n100);

    // Also seed an event after the reorg block
    const late_event = models.Event{
        .event_type = .name_registered,
        .protocol = .v2,
        .block_number = 200,
        .tx_hash = try Hash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000abc"),
        .log_index = 0,
        .contract_address = Address.zero,
        .name = "late.eth",
        .namehash = try namehash(allocator, "late.eth"),
        .data = "{}",
        .timestamp = 1700000200,
    };
    try database.insertEvent(late_event);

    // Rollback to block 150 — should delete late.eth + late event but keep early.eth
    try lib.storage.sync.rollbackToBlock(&database, .v2, 150);

    try testing.expect((try database.getNameByNamehash(try namehash(allocator, "late.eth"))) == null);
    if (try database.getNameByNamehash(try namehash(allocator, "early.eth"))) |found| {
        var owned = found;
        owned.deinit(allocator);
    } else {
        try testing.expect(false);
    }

    std.debug.print("✓ Reorg rollback correctly preserves pre-reorg state and deletes post-reorg state\n", .{});
}

// ============================================================================
// Reorg undo-log: in-place mutation reversal (#6/#7 correctness fix)
// rollbackToBlock(N) must reverse UPDATEs to rows that existed at/before N, not
// just delete created-after rows. The undo-log captures each mutation (tagged by
// the per-protocol cursor) so rollback restores the row's state as of N.
// ============================================================================

fn makeReorgName(allocator: std.mem.Allocator, name: []const u8, protocol: models.Protocol, owner: Address, block: u64) !models.Name {
    return models.Name{
        .name = try allocator.dupe(u8, name),
        .namehash = try namehash(allocator, name),
        .label = try allocator.dupe(u8, name),
        .label_hash = try keccak256(allocator, name),
        .parent_name = try allocator.dupe(u8, "eth"),
        .parent_namehash = try namehash(allocator, "eth"),
        .protocol = protocol,
        .registry = try Address.fromHex("0x0000000000000000000000000000000000000001"),
        .owner = owner,
        .registrant = owner,
        .resolver = Address.zero,
        .token_id = 0,
        .canonical_id = 0,
        .token_version = 1,
        .expiry = 0,
        .registry_locked = false,
        .migrated = false,
        .created_block = block,
        .created_at = @intCast(1700000000 + block),
        .registered_at = @intCast(1700000000 + block),
        .updated_block = block,
        .updated_at = @intCast(1700000000 + block),
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = (protocol == .v1),
        .v1_label_hash = null,
    };
}

fn ownerOf(allocator: std.mem.Allocator, database: *Database, nh: Hash) !Address {
    var n = (try database.getNameByNamehash(nh)) orelse return error.NameVanished;
    defer n.deinit(allocator);
    return n.owner;
}

fn expectInPlaceOwnerReversed(protocol: models.Protocol) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try testDb(allocator);
    defer database.deinit();

    const owner_a = try Address.fromHex("0x00000000000000000000000000000000000000aa");
    const owner_b = try Address.fromHex("0x00000000000000000000000000000000000000bb");
    const nh = try namehash(allocator, "foo.eth");

    // Block 100: created with owner A (INSERT — not captured; covered by created_block delete).
    try lib.storage.reorg_undo.setCursor(&database, protocol, 100);
    var n = try makeReorgName(allocator, "foo.eth", protocol, owner_a, 100);
    defer n.deinit(allocator);
    try database.insertName(n);

    // Block 200: owner changed to B (in-place UPDATE — captured, tagged block 200).
    try lib.storage.reorg_undo.setCursor(&database, protocol, 200);
    try database.updateNameOwner(nh, owner_b);
    try testing.expectEqualSlices(u8, &owner_b.bytes, &(try ownerOf(allocator, &database, nh)).bytes);

    // Reorg to 150: the block-200 update is reversed; the name (created 100) survives.
    try lib.storage.sync.rollbackToBlock(&database, protocol, 150);
    try testing.expectEqualSlices(u8, &owner_a.bytes, &(try ownerOf(allocator, &database, nh)).bytes);
}

test "reorg undo-log reverses an in-place owner update (v2)" {
    try expectInPlaceOwnerReversed(.v2);
    std.debug.print("✓ v2 in-place owner update reversed on reorg (B→A)\n", .{});
}

test "reorg undo-log reverses an in-place owner update (v1)" {
    try expectInPlaceOwnerReversed(.v1);
    std.debug.print("✓ v1 in-place owner update reversed on reorg (B→A)\n", .{});
}

// Seed a wrapped V1 name whose wrapper_expiry (with the PARENT_CANNOT_CONTROL
// fuse) exceeds its current expiry, so materializePccDomainExpiry will mirror it.
fn seedWrappedPccName(allocator: std.mem.Allocator, database: *Database, name: []const u8, block: u64) !Hash {
    var n = try makeReorgName(allocator, name, .v1, try Address.fromHex("0x00000000000000000000000000000000000000aa"), block);
    defer n.deinit(allocator);
    n.is_wrapped = true;
    n.wrapper_fuses = try allocator.dupe(u8, "65536"); // 0x10000 = PARENT_CANNOT_CONTROL
    n.wrapper_expiry = 2000000000;
    n.expiry = 1000000000; // below wrapper_expiry, so materialize raises it
    try database.insertName(n);
    return n.namehash;
}

fn nameExpiry(database: *Database, allocator: std.mem.Allocator, nh: Hash) !u64 {
    var n = (try database.getNameByNamehash(nh)) orelse return error.NameVanished;
    defer n.deinit(allocator);
    return n.expiry;
}

// W4: the one-shot PCC Domain.expiry mirror is a derived recompute, not block
// processing — Indexer.materializePccUncaptured disarms the reorg cursor around
// it (reorg_undo.clearCursor) so it never self-captures. This test mirrors that
// disarm and asserts a later reorg does NOT revert the materialized expiry, while
// a genuinely-captured mutation in the same window IS reversed.
test "reorg undo-log: uncaptured PCC materialize survives a later reorg" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try testDb(allocator);
    defer database.deinit();

    // Block 100: create the wrapped name (INSERT — not captured).
    try lib.storage.reorg_undo.setCursor(&database, .v1, 100);
    const nh = try seedWrappedPccName(allocator, &database, "wrapped.eth", 100);
    try testing.expectEqual(@as(u64, 1000000000), try nameExpiry(&database, allocator, nh));

    // The fix: disarm the cursor (as Indexer.materializePccUncaptured does), then
    // run the one-shot materialize. No undo row is captured for this UPDATE.
    try lib.storage.reorg_undo.clearCursor(&database, .v1);
    try testing.expectEqual(@as(u32, 1), try database.materializePccDomainExpiry());
    try testing.expectEqual(@as(u64, 2000000000), try nameExpiry(&database, allocator, nh));

    // Re-arm and make a genuinely-captured mutation at block 200.
    const owner_b = try Address.fromHex("0x00000000000000000000000000000000000000bb");
    try lib.storage.reorg_undo.setCursor(&database, .v1, 200);
    try database.updateNameOwner(nh, owner_b);

    // Reorg to 150: the owner update reverses (proves rollback ran), but the
    // materialized expiry is untouched (it was never captured).
    try lib.storage.sync.rollbackToBlock(&database, .v1, 150);
    try testing.expectEqualSlices(u8, &(try Address.fromHex("0x00000000000000000000000000000000000000aa")).bytes, &(try ownerOf(allocator, &database, nh)).bytes);
    try testing.expectEqual(@as(u64, 2000000000), try nameExpiry(&database, allocator, nh));
    std.debug.print("✓ uncaptured PCC materialize survives a later reorg (expiry kept)\n", .{});
}

// Control proving the test above is non-vacuous and documenting the bug W4 fixes:
// if the materialize runs with the cursor still armed (the pre-fix behaviour), the
// UPDATE IS captured and a later reorg wrongly reverts expiry to its pre-mirror value.
test "reorg undo-log: PCC materialize WITH the cursor armed is wrongly reverted (pre-fix control)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try testDb(allocator);
    defer database.deinit();

    try lib.storage.reorg_undo.setCursor(&database, .v1, 100);
    const nh = try seedWrappedPccName(allocator, &database, "wrapped.eth", 100);

    // Cursor left armed at 200 (as the unfixed indexer leaves it), then materialize
    // → the UPDATE is captured, tagged block 200.
    try lib.storage.reorg_undo.setCursor(&database, .v1, 200);
    try testing.expectEqual(@as(u32, 1), try database.materializePccDomainExpiry());
    try testing.expectEqual(@as(u64, 2000000000), try nameExpiry(&database, allocator, nh));

    // Reorg to 150 replays the captured undo row → expiry reverts to its pre-mirror
    // value. This is exactly the regression W4's disarm prevents.
    try lib.storage.sync.rollbackToBlock(&database, .v1, 150);
    try testing.expectEqual(@as(u64, 1000000000), try nameExpiry(&database, allocator, nh));
    std.debug.print("✓ control: armed-cursor materialize is reverted by reorg (the W4 bug)\n", .{});
}

fn unknownLabelCount(database: *Database) !i64 {
    var q = try lib.storage.Query.init(database, "SELECT COUNT(*) FROM unknown_labels");
    defer q.deinit();
    _ = try q.step();
    return q.getInt64(0);
}

fn firstUnknownLabelBlock(database: *Database) !i64 {
    var q = try lib.storage.Query.init(database, "SELECT block_number FROM unknown_labels");
    defer q.deinit();
    if (!try q.step()) return error.NoUnknownLabel;
    return q.getInt64(0);
}

// W6: unknown_labels lacks a `protocol` column and (before this fix) was in no
// reorg trigger array, so a post-N row whose `name_id` is null or points at a
// pre-N name had no rollback delete path (no `ON DELETE CASCADE`, no created-block
// delete) and persisted as a stale row. Adding it to REORG_ACTIVE_TABLES captures
// its inserts (op-'I'), so replayUndo deletes the post-N row by id on rollback.
test "reorg undo-log: unknown_labels post-N insert removed, pre-N kept (cascade gap)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try testDb(allocator);
    defer database.deinit();

    const tx = try keccak256(allocator, "tx");
    const owner = try Address.fromHex("0x00000000000000000000000000000000000000c9");
    const parent = try namehash(allocator, "eth");
    const lh_keep = try keccak256(allocator, "keep");
    const lh_drop = try keccak256(allocator, "drop");
    const nh_keep = try namehash(allocator, "keep.eth");
    const nh_drop = try namehash(allocator, "drop.eth");

    // Block 100 (pre-N): an unresolved label discovered at/before N — must survive.
    // name_id is null, so ON DELETE CASCADE can never reach it.
    try lib.storage.reorg_undo.setCursor(&database, .v1, 100);
    try lib.storage.unknown_labels.insertUnknownLabel(&database, null, tx, lh_keep, nh_keep, parent, owner, 100);

    // Block 200 (post-N): a label discovered after N — must be removed on rollback.
    try lib.storage.reorg_undo.setCursor(&database, .v1, 200);
    try lib.storage.unknown_labels.insertUnknownLabel(&database, null, tx, lh_drop, nh_drop, parent, owner, 200);

    try testing.expectEqual(@as(i64, 2), try unknownLabelCount(&database));

    // Reorg to 150: the block-200 op-'I' capture is reversed (deleted by id); the
    // block-100 row (tagged ≤ 150) is untouched.
    try lib.storage.sync.rollbackToBlock(&database, .v1, 150);

    try testing.expectEqual(@as(i64, 1), try unknownLabelCount(&database));
    try testing.expectEqual(@as(i64, 100), try firstUnknownLabelBlock(&database));
    std.debug.print("✓ unknown_labels post-N insert removed on reorg, pre-N kept\n", .{});
}

fn registrationExpiry(database: *Database) !i64 {
    var q = try lib.storage.Query.init(database, "SELECT expiry FROM registrations");
    defer q.deinit();
    if (!try q.step()) return error.NoRegistration;
    return q.getInt64(0);
}

// W5: `registrations` is already in PROTECTED_TABLES, so its in-place expiry
// renewal (an UPDATE to a pre-N row) is captured and reversed on rollback. This
// guards that protection at runtime (the comptime coverage assert in sync.zig
// guards it at build time). A renewal that lands after the reorg block must not
// survive a rollback to before it.
test "reorg undo-log: registrations renew (in-place expiry update) reversed on reorg" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try testDb(allocator);
    defer database.deinit();

    const nh = try namehash(allocator, "renew.eth");
    const registrant = try Address.fromHex("0x00000000000000000000000000000000000000d4");
    const tx = try Hash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000def");

    // Block 100 (pre-N): registered with expiry 1e9 (INSERT — not captured).
    try lib.storage.reorg_undo.setCursor(&database, .v1, 100);
    try database.insertRegistration(.v1, nh, "renew", "eth", registrant, 1700000100, 1000000000, 100, tx, 0, .name_registered);
    // Block 200 (post-N): renewed to expiry 2e9 (in-place UPDATE — captured at 200).
    try lib.storage.reorg_undo.setCursor(&database, .v1, 200);
    try database.updateRegistrationExpiry(.v1, nh, 2000000000);
    try testing.expectEqual(@as(i64, 2000000000), try registrationExpiry(&database));

    // Reorg to 150: the renewal is reversed; expiry returns to its as-of-N value.
    try lib.storage.sync.rollbackToBlock(&database, .v1, 150);
    try testing.expectEqual(@as(i64, 1000000000), try registrationExpiry(&database));
    std.debug.print("✓ registrations renew reversed on reorg (expiry 2e9→1e9)\n", .{});
}

// W7-discovered gap: orphaned_registrations is a deferred-registration queue whose
// rows are deleted in place when a subregistry is discovered (processOrphanedRegistrations
// promotes them to names, then deleteOrphanedRegistrations). It was NOT reorg-captured, so
// an orphan queued at/before N and resolved-then-deleted after N was lost on rollback (the
// pre-N source NameRegistered is never re-processed on re-sync → a name goes missing). The
// coverage guard forced the fix: orphaned_registrations is now a PROTECTED table, so the
// post-N delete of the pre-N orphan is captured and reversed.
test "reorg undo-log: orphaned_registrations pre-N row deleted post-N is restored on rollback" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try testDb(allocator);
    defer database.deinit();

    const subreg = "0x00000000000000000000000000000000000000e5";
    const owner = try Address.fromHex("0x00000000000000000000000000000000000000e6");
    const tx = try Hash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000e57");

    // Block 100 (pre-N): an orphan is queued (subregistry not yet known).
    try lib.storage.reorg_undo.setCursor(&database, .v2, 100);
    try database.insertOrphanedRegistration(.v2, subreg, 42, "orphanlabel", 0, owner, 100, tx, 0);
    try testing.expectEqual(@as(i64, 1), try countAll(&database, "orphaned_registrations"));

    // Block 200 (post-N): the subregistry is discovered → the orphan is resolved and
    // deleted (captured as op-'D' now that the table is PROTECTED).
    try lib.storage.reorg_undo.setCursor(&database, .v2, 200);
    try database.deleteOrphanedRegistrations(.v2, subreg);
    try testing.expectEqual(@as(i64, 0), try countAll(&database, "orphaned_registrations"));

    // Reorg to 150: the post-N deletion of the pre-N orphan is reversed — the orphan
    // returns so re-sync can re-resolve it (without the fix it stayed lost).
    try lib.storage.sync.rollbackToBlock(&database, .v2, 150);
    try testing.expectEqual(@as(i64, 1), try countAll(&database, "orphaned_registrations"));
    std.debug.print("✓ orphaned_registrations pre-N delete-after-N reversed on reorg\n", .{});
}

// W10: the Postgres reorg triggers are generated (as DDL strings) from the same
// PROTECTED_TABLES / REORG_ACTIVE_TABLES the SQLite triggers use. Pure string gen —
// executed against a real Postgres only in Phase 4 — so this golden test pins the
// settled design: two generic PL/pgSQL functions (cursor gate in the body, to_jsonb
// snapshot, op via TG_ARGV), the SQLite-matching trigger-name scheme, protected {U,D}
// vs active {I,U,D}, and that the per-table counts track the arrays.
test "reorg undo-log: pgTriggerInstallSql generates the settled Postgres trigger DDL" {
    const allocator = testing.allocator;
    const sql = try lib.storage.reorg_undo.pgTriggerInstallSql(allocator);
    defer allocator.free(sql);

    const has = struct {
        fn f(hay: []const u8, needle: []const u8) bool {
            return std.mem.indexOf(u8, hay, needle) != null;
        }
    }.f;

    // Two generic PL/pgSQL capture functions.
    try testing.expect(has(sql, "CREATE OR REPLACE FUNCTION reorg_capture_protocol() RETURNS trigger"));
    try testing.expect(has(sql, "CREATE OR REPLACE FUNCTION reorg_capture_active() RETURNS trigger"));
    // Cursor/active gate lives in the body (PG WHEN forbids subqueries) + to_jsonb snapshot.
    try testing.expect(has(sql, "SELECT block_number INTO cur_block FROM reorg_cursor WHERE protocol = OLD.protocol"));
    try testing.expect(has(sql, "to_jsonb(OLD)::text"));
    try testing.expect(has(sql, "to_jsonb(CASE WHEN TG_OP = 'INSERT' THEN NEW ELSE OLD END)::text"));
    // The op letter is derived from the firing event so it can't disagree with it.
    try testing.expect(has(sql, "LEFT(TG_OP, 1)"));
    // Representative protected triggers: UPDATE+DELETE only, SQLite-matching name scheme.
    try testing.expect(has(sql, "CREATE TRIGGER \"names_reorg_undo_u\" AFTER UPDATE ON \"names\" FOR EACH ROW EXECUTE FUNCTION reorg_capture_protocol();"));
    try testing.expect(has(sql, "CREATE TRIGGER \"names_reorg_undo_d\" AFTER DELETE ON \"names\" FOR EACH ROW EXECUTE FUNCTION reorg_capture_protocol();"));
    // The orphaned_registrations fix is reflected (now a PROTECTED table).
    try testing.expect(has(sql, "CREATE TRIGGER \"orphaned_registrations_reorg_undo_u\" AFTER UPDATE ON \"orphaned_registrations\""));
    // Representative reorg_active triggers: INSERT+UPDATE+DELETE via reorg_capture_active.
    try testing.expect(has(sql, "CREATE TRIGGER \"accounts_reorg_undo_i\" AFTER INSERT ON \"accounts\" FOR EACH ROW EXECUTE FUNCTION reorg_capture_active();"));
    try testing.expect(has(sql, "CREATE TRIGGER \"unknown_labels_reorg_undo_d\" AFTER DELETE ON \"unknown_labels\" FOR EACH ROW EXECUTE FUNCTION reorg_capture_active();"));
    // Protected tables get NO AFTER INSERT trigger (inserts handled by created-after delete).
    try testing.expect(std.mem.indexOf(u8, sql, "\"names_reorg_undo_i\"") == null);
    // Every CREATE TRIGGER is paired with an idempotent DROP, and counts track the arrays.
    const expected = lib.storage.reorg_undo.PROTECTED_TABLES.len * 2 + lib.storage.reorg_undo.REORG_ACTIVE_TABLES.len * 3;
    try testing.expectEqual(expected, std.mem.count(u8, sql, "CREATE TRIGGER "));
    try testing.expectEqual(expected, std.mem.count(u8, sql, "DROP TRIGGER IF EXISTS "));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, sql, "CREATE OR REPLACE FUNCTION "));
    std.debug.print("✓ pgTriggerInstallSql: {d} triggers + 2 capture functions\n", .{std.mem.count(u8, sql, "CREATE TRIGGER ")});
}

test "reorg undo-log: created-after removed AND updated pre-reorg restored together" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try testDb(allocator);
    defer database.deinit();

    const owner_a = try Address.fromHex("0x00000000000000000000000000000000000000aa");
    const owner_b = try Address.fromHex("0x00000000000000000000000000000000000000bb");
    const x = try namehash(allocator, "x.eth");
    const y = try namehash(allocator, "y.eth");

    // X created at 100 (owner A); Y created at 300 (owner A); X updated to B at 200.
    try lib.storage.reorg_undo.setCursor(&database, .v2, 100);
    var nx = try makeReorgName(allocator, "x.eth", .v2, owner_a, 100);
    defer nx.deinit(allocator);
    try database.insertName(nx);

    try lib.storage.reorg_undo.setCursor(&database, .v2, 300);
    var ny = try makeReorgName(allocator, "y.eth", .v2, owner_a, 300);
    defer ny.deinit(allocator);
    try database.insertName(ny);

    try lib.storage.reorg_undo.setCursor(&database, .v2, 200);
    try database.updateNameOwner(x, owner_b);

    // Reorg to 150: X (created 100) restored to owner A; Y (created 300) deleted.
    try lib.storage.sync.rollbackToBlock(&database, .v2, 150);

    try testing.expectEqualSlices(u8, &owner_a.bytes, &(try ownerOf(allocator, &database, x)).bytes);
    try testing.expect((try database.getNameByNamehash(y)) == null);
    std.debug.print("✓ created-after removed + updated pre-reorg restored compose correctly\n", .{});
}

test "reorg undo-log: rollback is idempotent" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try testDb(allocator);
    defer database.deinit();

    const owner_a = try Address.fromHex("0x00000000000000000000000000000000000000aa");
    const owner_b = try Address.fromHex("0x00000000000000000000000000000000000000bb");
    const nh = try namehash(allocator, "foo.eth");

    try lib.storage.reorg_undo.setCursor(&database, .v2, 100);
    var n = try makeReorgName(allocator, "foo.eth", .v2, owner_a, 100);
    defer n.deinit(allocator);
    try database.insertName(n);
    try lib.storage.reorg_undo.setCursor(&database, .v2, 200);
    try database.updateNameOwner(nh, owner_b);

    try lib.storage.sync.rollbackToBlock(&database, .v2, 150);
    try lib.storage.sync.rollbackToBlock(&database, .v2, 150); // second time = no-op
    try testing.expectEqualSlices(u8, &owner_a.bytes, &(try ownerOf(allocator, &database, nh)).bytes);
    std.debug.print("✓ rollback idempotent\n", .{});
}

fn resolverAddrCount(database: *Database, nh: Hash) !i64 {
    var nh_buf: [66]u8 = undefined;
    const nh_hex = nh.toHexBuf(&nh_buf);
    var q = try lib.storage.Query.init(database, "SELECT COUNT(*) FROM resolver_addresses WHERE namehash = ?");
    defer q.deinit();
    try q.bindText(nh_hex);
    _ = try q.step();
    return q.getInt64(0);
}

test "reorg undo-log re-inserts a resolver record cleared after the reorg block" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try testDb(allocator);
    defer database.deinit();

    const nh = try namehash(allocator, "foo.eth");
    const resolver = try Address.fromHex("0x00000000000000000000000000000000000000cc");
    const tx = try Hash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000abc");

    // Block 100: resolver addr record created (INSERT — not captured).
    try lib.storage.reorg_undo.setCursor(&database, .v2, 100);
    try database.storeResolverAddress(nh, resolver, 60, "0x00000000000000000000000000000000000000dd", .v2, 100, tx, 1700000100);
    try testing.expectEqual(@as(i64, 1), try resolverAddrCount(&database, nh));

    // Block 200: cleared (DELETE — captured by the AFTER DELETE trigger, tagged 200).
    try lib.storage.reorg_undo.setCursor(&database, .v2, 200);
    try database.deleteResolverAddresses(nh, resolver);
    try testing.expectEqual(@as(i64, 0), try resolverAddrCount(&database, nh));

    // Reorg to 150: the cleared record (created 100 ≤ 150) is re-inserted.
    try lib.storage.sync.rollbackToBlock(&database, .v2, 150);
    try testing.expectEqual(@as(i64, 1), try resolverAddrCount(&database, nh));
    std.debug.print("✓ resolver clear-DELETE re-inserted on reorg\n", .{});
}

test "reorg undo-log restores exact state-as-of-N across multiple updates" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try testDb(allocator);
    defer database.deinit();

    const a = try Address.fromHex("0x00000000000000000000000000000000000000aa");
    const b = try Address.fromHex("0x00000000000000000000000000000000000000bb");
    const c = try Address.fromHex("0x00000000000000000000000000000000000000cc");
    const d = try Address.fromHex("0x00000000000000000000000000000000000000dd");
    const nh = try namehash(allocator, "foo.eth");

    try lib.storage.reorg_undo.setCursor(&database, .v2, 100);
    var n = try makeReorgName(allocator, "foo.eth", .v2, a, 100);
    defer n.deinit(allocator);
    try database.insertName(n);

    // owner A→B@200, B→C@250, C→D@300.
    try lib.storage.reorg_undo.setCursor(&database, .v2, 200);
    try database.updateNameOwner(nh, b);
    try lib.storage.reorg_undo.setCursor(&database, .v2, 250);
    try database.updateNameOwner(nh, c);
    try lib.storage.reorg_undo.setCursor(&database, .v2, 300);
    try database.updateNameOwner(nh, d);

    // Reorg to 220: last update ≤ 220 was @200 (→B), so owner must be B (not A, not C/D).
    try lib.storage.sync.rollbackToBlock(&database, .v2, 220);
    try testing.expectEqualSlices(u8, &b.bytes, &(try ownerOf(allocator, &database, nh)).bytes);
    std.debug.print("✓ multi-update reverse restores exact state-as-of-N (owner B)\n", .{});
}

test "reorg undo-log: rolling back one protocol leaves the other untouched" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try testDb(allocator);
    defer database.deinit();

    const a = try Address.fromHex("0x00000000000000000000000000000000000000aa");
    const b = try Address.fromHex("0x00000000000000000000000000000000000000bb");
    const v1nh = try namehash(allocator, "v1name.eth");
    const v2nh = try namehash(allocator, "v2name.eth");

    // A v1 name and a v2 name, both created @100, both updated to B @200.
    try lib.storage.reorg_undo.setCursor(&database, .v1, 100);
    var nv1 = try makeReorgName(allocator, "v1name.eth", .v1, a, 100);
    defer nv1.deinit(allocator);
    try database.insertName(nv1);
    try lib.storage.reorg_undo.setCursor(&database, .v2, 100);
    var nv2 = try makeReorgName(allocator, "v2name.eth", .v2, a, 100);
    defer nv2.deinit(allocator);
    try database.insertName(nv2);

    try lib.storage.reorg_undo.setCursor(&database, .v1, 200);
    try database.updateNameOwner(v1nh, b);
    try lib.storage.reorg_undo.setCursor(&database, .v2, 200);
    try database.updateNameOwner(v2nh, b);

    // Reorg ONLY v2 to 150: v2 reverts to A; v1 stays at B.
    try lib.storage.sync.rollbackToBlock(&database, .v2, 150);
    try testing.expectEqualSlices(u8, &a.bytes, &(try ownerOf(allocator, &database, v2nh)).bytes);
    try testing.expectEqualSlices(u8, &b.bytes, &(try ownerOf(allocator, &database, v1nh)).bytes);
    std.debug.print("✓ per-protocol rollback isolation (v2 reverted, v1 intact)\n", .{});
}

// ============================================================================
// Regression tests for where.name filter (task #2)
// ============================================================================

test "where.name filter combined with isMigrated respects both" {
    // This is a unit-level test via getFilteredNames, which is the code path
    // the resolver now routes through when name is combined with other filters.
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try testDb(allocator);
    defer database.deinit();

    // Insert two names with the same label but different migrated status... wait, they can't have
    // the same namehash. Let's do two different names where one is migrated and one isn't.
    var foo_eth = models.Name{
        .name = try allocator.dupe(u8, "foo.eth"),
        .namehash = try namehash(allocator, "foo.eth"),
        .label = try allocator.dupe(u8, "foo"),
        .label_hash = try keccak256(allocator, "foo"),
        .parent_name = try allocator.dupe(u8, "eth"),
        .parent_namehash = try namehash(allocator, "eth"),
        .protocol = .v2,
        .registry = try Address.fromHex("0x0000000000000000000000000000000000000001"),
        .owner = try Address.fromHex("0x0000000000000000000000000000000000000111"),
        .registrant = try Address.fromHex("0x0000000000000000000000000000000000000111"),
        .resolver = Address.zero,
        .token_id = 10,
        .canonical_id = 10,
        .token_version = 1,
        .expiry = 0,
        .registry_locked = false,
        .migrated = false, // NOT migrated
        .created_block = 100,
        .created_at = 1700000100,
        .registered_at = 1700000100,
        .updated_block = 100,
        .updated_at = 1700000100,
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    };
    defer foo_eth.deinit(allocator);
    try database.insertName(foo_eth);

    // Filter: name=foo.eth AND migrated=true → should return empty
    const results_strict = try lib.storage.names.getFilteredNames(
        &database,
        .{ .name = "foo.eth", .migrated = true },
        0,
        10,
        .desc,
        .created_at,
    );
    defer {
        for (results_strict) |*r| {
            var rc = r.*;
            rc.deinit(allocator);
        }
        allocator.free(results_strict);
    }
    try testing.expectEqual(@as(usize, 0), results_strict.len);

    // Filter: name=foo.eth AND migrated=false → should return foo.eth
    const results_match = try lib.storage.names.getFilteredNames(
        &database,
        .{ .name = "foo.eth", .migrated = false },
        0,
        10,
        .desc,
        .created_at,
    );
    defer {
        for (results_match) |*r| {
            var rc = r.*;
            rc.deinit(allocator);
        }
        allocator.free(results_match);
    }
    try testing.expectEqual(@as(usize, 1), results_match.len);

    std.debug.print("✓ where.name + isMigrated filter combo works correctly\n", .{});
}

// ============================================================================
// Reorg undo-log: post-audit coverage closure (2026-06-02)
// Tests for the gaps the adversarial audit found: INSERT-OR-REPLACE overwrite
// capture (recursive_triggers), newly-protected tables, post-N insert removal,
// and the cross-protocol accounts path.
// ============================================================================

fn resolverTextValue(allocator: std.mem.Allocator, database: *Database, nh: Hash, key: []const u8) !?[]u8 {
    var nh_buf: [66]u8 = undefined;
    const nh_hex = nh.toHexBuf(&nh_buf);
    var q = try lib.storage.Query.init(database, "SELECT value FROM resolver_texts WHERE namehash = ? AND key = ?");
    defer q.deinit();
    try q.bindText(nh_hex);
    try q.bindText(key);
    if (!(try q.step())) return null;
    const v = q.getTextSlice(0) orelse return null;
    return try allocator.dupe(u8, v);
}

fn reverseNamehashHex(allocator: std.mem.Allocator, database: *Database, addr: Address) !?[]u8 {
    var ab: [42]u8 = undefined;
    const ah = addr.toHexBuf(&ab);
    var q = try lib.storage.Query.init(database, "SELECT namehash FROM reverse_records WHERE address = LOWER(?)");
    defer q.deinit();
    try q.bindText(ah);
    if (!(try q.step())) return null;
    const v = q.getTextSlice(0) orelse return null;
    return try allocator.dupe(u8, v);
}

fn countAll(database: *Database, comptime table: []const u8) !i64 {
    var q = try lib.storage.Query.init(database, "SELECT COUNT(*) FROM " ++ table);
    defer q.deinit();
    _ = try q.step();
    return q.getInt64(0);
}

// THE core blocker: resolver records are written with INSERT OR REPLACE. Without
// recursive_triggers=ON the implicit DELETE fires no trigger, so an overwrite of a
// pre-N record was never captured and rollback would lose the old value entirely.
test "reorg undo-log reverses a resolver text OVERWRITE (INSERT OR REPLACE)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try testDb(allocator);
    defer database.deinit();

    const nh = try namehash(allocator, "foo.eth");
    const resolver = try Address.fromHex("0x00000000000000000000000000000000000000cc");
    const tx = try Hash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000abc");

    // Block 100: text "url" = "old" (first insert; not captured).
    try lib.storage.reorg_undo.setCursor(&database, .v2, 100);
    try database.storeResolverText(nh, resolver, "url", "old", .v2, 100, tx, 1700000100);

    // Block 200: overwrite to "new" via INSERT OR REPLACE — implicit DELETE of the
    // old row must fire the AFTER DELETE undo trigger (recursive_triggers=ON).
    try lib.storage.reorg_undo.setCursor(&database, .v2, 200);
    try database.storeResolverText(nh, resolver, "url", "new", .v2, 200, tx, 1700000200);
    {
        const cur = (try resolverTextValue(allocator, &database, nh, "url")).?;
        defer allocator.free(cur);
        try testing.expectEqualStrings("new", cur);
    }

    // Reorg to 150: the overwrite is reversed; the record (created 100 ≤ 150) keeps "old".
    try lib.storage.sync.rollbackToBlock(&database, .v2, 150);
    const restored = (try resolverTextValue(allocator, &database, nh, "url")) orelse return error.RecordVanished;
    defer allocator.free(restored);
    try testing.expectEqualStrings("old", restored);
    std.debug.print("✓ resolver text INSERT-OR-REPLACE overwrite reversed on reorg (new→old)\n", .{});
}

test "reorg undo-log: reverse_records overwrite reversed + post-N insert removed" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try testDb(allocator);
    defer database.deinit();

    const addr_x = try Address.fromHex("0x00000000000000000000000000000000000000a1");
    const addr_y = try Address.fromHex("0x00000000000000000000000000000000000000a2");
    const nh1 = try namehash(allocator, "one.eth");
    const nh2 = try namehash(allocator, "two.eth");
    const tx = try Hash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000abc");

    // X → one.eth @100 (insert), then X → two.eth @200 (in-place overwrite via upsert).
    try lib.storage.reorg_undo.setCursor(&database, .v2, 100);
    try database.upsertReverseRecord(.v2, addr_x, nh1, 100, tx, 0, 1700000100);
    try lib.storage.reorg_undo.setCursor(&database, .v2, 200);
    try database.upsertReverseRecord(.v2, addr_x, nh2, 200, tx, 0, 1700000200);
    // Y → some.eth @200 (insert created after the reorg point).
    try database.upsertReverseRecord(.v2, addr_y, nh1, 200, tx, 0, 1700000200);

    try lib.storage.sync.rollbackToBlock(&database, .v2, 150);

    // X reverted to one.eth (created 100); Y (created 200) removed.
    const xnh = (try reverseNamehashHex(allocator, &database, addr_x)) orelse return error.RecordVanished;
    defer allocator.free(xnh);
    var nh1_buf: [66]u8 = undefined;
    try testing.expectEqualStrings(nh1.toHexBuf(&nh1_buf), xnh);
    try testing.expect((try reverseNamehashHex(allocator, &database, addr_y)) == null);
    std.debug.print("✓ reverse_records overwrite reversed + post-N insert removed\n", .{});
}

test "reorg undo-log: resolver_authorisations post-N insert removed" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try testDb(allocator);
    defer database.deinit();

    const nh = try namehash(allocator, "foo.eth");
    const resolver = try Address.fromHex("0x00000000000000000000000000000000000000cc");
    const owner = try Address.fromHex("0x00000000000000000000000000000000000000aa");
    const target = try Address.fromHex("0x00000000000000000000000000000000000000bb");
    const tx = try Hash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000abc");

    try lib.storage.reorg_undo.setCursor(&database, .v2, 200);
    try database.storeResolverAuthorisation(.v2, nh, resolver, owner, target, true, 200, tx, 0, 1700000200);
    try testing.expectEqual(@as(i64, 1), try countAll(&database, "resolver_authorisations"));

    try lib.storage.sync.rollbackToBlock(&database, .v2, 150);
    try testing.expectEqual(@as(i64, 0), try countAll(&database, "resolver_authorisations"));
    std.debug.print("✓ resolver_authorisations post-N insert removed on reorg\n", .{});
}

test "reorg undo-log: registrations + registry_entries post-N inserts removed" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try testDb(allocator);
    defer database.deinit();

    const nh_keep = try namehash(allocator, "keep.eth");
    const nh_drop = try namehash(allocator, "drop.eth");
    const registrant = try Address.fromHex("0x00000000000000000000000000000000000000aa");
    const parent = try Address.fromHex("0x0000000000000000000000000000000000000001");
    const tx = try Hash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000abc");

    // One registration before the reorg point, one after.
    try lib.storage.reorg_undo.setCursor(&database, .v2, 100);
    try database.insertRegistration(.v2, nh_keep, "keep", "eth", registrant, 1700000100, 0, 100, tx, 0, .name_registered);
    try lib.storage.reorg_undo.setCursor(&database, .v2, 200);
    try database.insertRegistration(.v2, nh_drop, "drop", "eth", registrant, 1700000200, 0, 200, tx, 1, .name_registered);
    // A registry_entries row first-seen after the reorg point.
    _ = try database.upsertRegistryEntrySubregistry(.v2, parent, 7, parent, 200, 1700000200);

    try testing.expectEqual(@as(i64, 2), try countAll(&database, "registrations"));
    try testing.expectEqual(@as(i64, 1), try countAll(&database, "registry_entries"));

    try lib.storage.sync.rollbackToBlock(&database, .v2, 150);

    // The pre-N registration survives; the post-N one and the post-N registry_entry are gone.
    try testing.expectEqual(@as(i64, 1), try countAll(&database, "registrations"));
    try testing.expectEqual(@as(i64, 0), try countAll(&database, "registry_entries"));
    std.debug.print("✓ registrations + registry_entries post-N inserts removed\n", .{});
}

test "reorg undo-log: accounts first-seen-after-N removed, pre-N kept" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try testDb(allocator);
    defer database.deinit();

    const a_keep = "0x00000000000000000000000000000000000000a1";
    const a_drop = "0x00000000000000000000000000000000000000a2";

    try lib.storage.reorg_undo.setCursor(&database, .v2, 100);
    try database.upsertAccount(.v2, a_keep, 100, 1700000100);
    try lib.storage.reorg_undo.setCursor(&database, .v2, 200);
    try database.upsertAccount(.v2, a_drop, 200, 1700000200);

    try lib.storage.sync.rollbackToBlock(&database, .v2, 150);

    const keep = try database.getAccount(a_keep);
    try testing.expect(keep != null);
    if (keep) |k| {
        var kk = k;
        kk.deinit(allocator);
    }
    const drop = try database.getAccount(a_drop);
    try testing.expect(drop == null);
    std.debug.print("✓ accounts first-seen-after-N removed, pre-N kept\n", .{});
}

// accounts has no `protocol` column, so it's captured via the single-row reorg_active
// context. A v2 sighting that flips seen_v2 on an address first seen in v1 must be
// reverted on a v2 reorg, leaving seen_v1 and first_seen intact.
test "reorg undo-log: accounts seen-flag flip reversed via reorg_active" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try testDb(allocator);
    defer database.deinit();

    const addr = "0x00000000000000000000000000000000000000b7";

    // Block 100: first seen in v1 (seen_v1=1, seen_v2=0, first_seen=100).
    try lib.storage.reorg_undo.setCursor(&database, .v1, 100);
    try database.upsertAccount(.v1, addr, 100, 1700000100);
    // Block 200: seen in v2 → in-place UPDATE flips seen_v2 (captured under reorg_active=v2@200).
    try lib.storage.reorg_undo.setCursor(&database, .v2, 200);
    try database.upsertAccount(.v2, addr, 200, 1700000200);
    {
        const mid = (try database.getAccount(addr)).?;
        var m = mid;
        defer m.deinit(allocator);
        try testing.expect(m.seen_v2);
    }

    // Reorg v2 to 150: the seen_v2 flip is reversed; seen_v1 + first_seen survive.
    try lib.storage.sync.rollbackToBlock(&database, .v2, 150);
    const after = (try database.getAccount(addr)) orelse return error.AccountVanished;
    var aft = after;
    defer aft.deinit(allocator);
    try testing.expect(aft.seen_v1);
    try testing.expect(!aft.seen_v2);
    try testing.expectEqual(@as(u64, 100), aft.first_seen_block);
    std.debug.print("✓ accounts seen_v2 flip reversed on v2 reorg (seen_v1 + first_seen intact)\n", .{});
}

// Regression for the audit's data-loss bug: rollback is PER-protocol and independent,
// so a v1 rollback must NOT delete an account that only v2 ever saw (v2 is still synced).
test "reorg undo-log: per-protocol rollback preserves the other protocol's accounts" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try testDb(allocator);
    defer database.deinit();

    const v2_only = "0x00000000000000000000000000000000000000e1";

    // First seen ONLY by v2 at block 120 (after the v1 rollback point 100).
    try lib.storage.reorg_undo.setCursor(&database, .v2, 120);
    try database.upsertAccount(.v2, v2_only, 120, 1700000120);

    // An INDEPENDENT v1 rollback to 100 must leave the v2-only account untouched.
    try lib.storage.sync.rollbackToBlock(&database, .v1, 100);

    const acc = (try database.getAccount(v2_only)) orelse return error.V2AccountWronglyDeleted;
    var a = acc;
    defer a.deinit(allocator);
    try testing.expect(a.seen_v2);
    std.debug.print("✓ per-protocol rollback preserves the other protocol's accounts (no cross-protocol delete)\n", .{});
}

// Shared address first seen by v2@200 then v1@250; a v2 reorg to 150 must clear ONLY
// v2's flag and keep the row (v1 never rolled back) — no data loss.
test "reorg undo-log: shared account — v2 reorg clears only seen_v2, keeps the row" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try testDb(allocator);
    defer database.deinit();

    const addr = "0x00000000000000000000000000000000000000e2";

    try lib.storage.reorg_undo.setCursor(&database, .v2, 200);
    try database.upsertAccount(.v2, addr, 200, 1700000200); // 'I' tagged v2@200
    try lib.storage.reorg_undo.setCursor(&database, .v1, 250);
    try database.upsertAccount(.v1, addr, 250, 1700000250); // 'U' tagged v1@250 (sets seen_v1)

    try lib.storage.sync.rollbackToBlock(&database, .v2, 150);

    const acc = (try database.getAccount(addr)) orelse return error.SharedAccountWronglyDeleted;
    var a = acc;
    defer a.deinit(allocator);
    try testing.expect(a.seen_v1); // v1 sighting survives (v1 not rolled back)
    try testing.expect(!a.seen_v2); // v2 sighting reverted
    std.debug.print("✓ shared account: v2 reorg clears only seen_v2, keeps seen_v1 (no data loss)\n", .{});
}

// v1_controllers drives which contracts get indexed (getActiveControllers). A reorged-out
// ControllerAdded/Removed must be wound back: added-after-N dropped, removed-after-N reactivated.
test "reorg undo-log: v1_controllers wound back on reorg" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try testDb(allocator);
    defer database.deinit();

    const c_old = try Address.fromHex("0x00000000000000000000000000000000000000c1");
    const c_new = try Address.fromHex("0x00000000000000000000000000000000000000c2");
    const tx = "0x0000000000000000000000000000000000000000000000000000000000000abc";

    // c_old added @100 (pre-N), removed @200 (after N=150); c_new added @200 (after N).
    // The cursor is set per event (as the live indexer does) so the undo-log captures.
    try lib.storage.reorg_undo.setCursor(&database, .v1, 100);
    try lib.storage.v1_controllers.addController(&database, c_old, 100, tx);
    try lib.storage.reorg_undo.setCursor(&database, .v1, 200);
    try lib.storage.v1_controllers.removeController(&database, c_old, 200, tx);
    try lib.storage.v1_controllers.addController(&database, c_new, 200, tx);

    try lib.storage.sync.rollbackToBlock(&database, .v1, 150);

    const active = try lib.storage.v1_controllers.getActiveControllers(allocator, &database);
    defer allocator.free(active);
    var has_old = false;
    var has_new = false;
    for (active) |a| {
        if (std.mem.eql(u8, &a.bytes, &c_old.bytes)) has_old = true;
        if (std.mem.eql(u8, &a.bytes, &c_new.bytes)) has_new = true;
    }
    try testing.expect(has_old); // removal @200 reverted → active again as of 150
    try testing.expect(!has_new); // added @200 → dropped by rollback
    std.debug.print("✓ v1_controllers wound back on reorg (reactivate removed-after-N, drop added-after-N)\n", .{});
}

// The hard case the column-predicate fix could not handle: a controller removed THEN
// re-added straddling N. The undo-log captures each mutation, so rollback restores the
// exact as-of-N state (removed), not the post-readd state (active).
test "reorg undo-log: v1_controllers remove-then-readd straddling N restores removed state" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try testDb(allocator);
    defer database.deinit();

    const c = try Address.fromHex("0x00000000000000000000000000000000000000c3");
    const tx = "0x0000000000000000000000000000000000000000000000000000000000000abc";

    // added@100, removed@200, re-added@300; reorg to 250 → as-of-250 state is REMOVED.
    try lib.storage.reorg_undo.setCursor(&database, .v1, 100);
    try lib.storage.v1_controllers.addController(&database, c, 100, tx);
    try lib.storage.reorg_undo.setCursor(&database, .v1, 200);
    try lib.storage.v1_controllers.removeController(&database, c, 200, tx);
    try lib.storage.reorg_undo.setCursor(&database, .v1, 300);
    try lib.storage.v1_controllers.addController(&database, c, 300, tx); // re-add

    try lib.storage.sync.rollbackToBlock(&database, .v1, 250);

    const active = try lib.storage.v1_controllers.getActiveControllers(allocator, &database);
    defer allocator.free(active);
    var has_c = false;
    for (active) |a| {
        if (std.mem.eql(u8, &a.bytes, &c.bytes)) has_c = true;
    }
    try testing.expect(!has_c); // re-add@300 reverted → controller is removed/inactive at 250
    std.debug.print("✓ v1_controllers remove-then-readd straddle restores as-of-N removed state\n", .{});
}

// eac_roles reorg coverage: the table is in PROTECTED_TABLES with a (protocol,
// resource, account, contract_address) business key in schema_keys, so an
// overwrite/revoke straddling N must roll back to its as-of-N state. (Previously
// wired but never behaviorally exercised — both DBs compared empty in reconcile.)

fn eacRoleCount(allocator: std.mem.Allocator, database: *Database, resource: []const u8) !usize {
    const rs = try database.getRolesByResource(.v2, resource);
    defer {
        for (rs) |*r| r.deinit(allocator);
        allocator.free(rs);
    }
    return rs.len;
}

fn expectSingleRoleBitmap(allocator: std.mem.Allocator, database: *Database, resource: []const u8, expected: []const u8) !void {
    const rs = try database.getRolesByResource(.v2, resource);
    defer {
        for (rs) |*r| r.deinit(allocator);
        allocator.free(rs);
    }
    try testing.expectEqual(@as(usize, 1), rs.len);
    try testing.expectEqualStrings(expected, rs[0].role_bitmap);
}

test "reorg undo-log reverses an eac_roles overwrite (v2)" {
    const allocator = testing.allocator;
    var database = try testDb(allocator);
    defer database.deinit();

    const account = try Address.fromHex("0x00000000000000000000000000000000000000aa");
    const contract = try Address.fromHex("0x00000000000000000000000000000000000000cc");
    const tx = try Hash.fromHex("0x1111111111111111111111111111111111111111111111111111111111111111");
    const resource = "0x0000000000000000000000000000000000000000000000000000000000000001";
    const bitmap_v1 = "0x0000000000000000000000000000000000000000000000000000000001000000";
    const bitmap_v2 = "0x1111111111111111111111111111111111111111111111111111111111111111";

    // Block 100: grant a role (survives a rollback to 150).
    try lib.storage.reorg_undo.setCursor(&database, .v2, 100);
    try database.upsertEACRole(.v2, resource, account, bitmap_v1, 100, tx, 0, contract);

    // Block 200: overwrite the bitmap (ON CONFLICT DO UPDATE — captured, tagged 200).
    try lib.storage.reorg_undo.setCursor(&database, .v2, 200);
    try database.upsertEACRole(.v2, resource, account, bitmap_v2, 200, tx, 1, contract);
    try expectSingleRoleBitmap(allocator, &database, resource, bitmap_v2);

    // Reorg to 150: the block-200 overwrite is reversed; the role (granted 100) is back at v1.
    try lib.storage.sync.rollbackToBlock(&database, .v2, 150);
    try expectSingleRoleBitmap(allocator, &database, resource, bitmap_v1);
}

test "reorg undo-log reverses an eac_roles delete (v2)" {
    const allocator = testing.allocator;
    var database = try testDb(allocator);
    defer database.deinit();

    const account = try Address.fromHex("0x00000000000000000000000000000000000000aa");
    const contract = try Address.fromHex("0x00000000000000000000000000000000000000cc");
    const tx = try Hash.fromHex("0x1111111111111111111111111111111111111111111111111111111111111111");
    const resource = "0x0000000000000000000000000000000000000000000000000000000000000002";
    const bitmap = "0x0000000000000000000000000000000000000000000000000000000001000000";

    // Block 100: grant a role.
    try lib.storage.reorg_undo.setCursor(&database, .v2, 100);
    try database.upsertEACRole(.v2, resource, account, bitmap, 100, tx, 0, contract);

    // Block 200: revoke it (DELETE — captured, tagged 200).
    try lib.storage.reorg_undo.setCursor(&database, .v2, 200);
    try database.deleteEACRole(.v2, resource, account, contract);
    try testing.expectEqual(@as(usize, 0), try eacRoleCount(allocator, &database, resource));

    // Reorg to 150: the delete is reversed (delete+reinsert on the business UNIQUE — the
    // PG restore path), so the role is restored with its block-100 bitmap.
    try lib.storage.sync.rollbackToBlock(&database, .v2, 150);
    try expectSingleRoleBitmap(allocator, &database, resource, bitmap);
}

// ============================================================================
// Reorg undo-log: the reconcile invariant (#9, RPC-free)
//
// The property the whole undo-log exists to guarantee: rolling a DB back to block
// N must leave it byte-identical to a DB that only ever indexed up to N. This builds
// two DBs from the same baseline (≤ N), drives one past N and rolls it back, and
// diffs EVERY chain-derived table. It's the regression guard that locks the undo-log:
// a future change that breaks any table's rollback fails here.
// ============================================================================

// Chain-derived tables to reconcile. Operational/cache tables (sync_state, block_hashes,
// reorg_*, rainbow_*, v1_labels, backfill_status, unknown_labels, temp_*, token_observers)
// are excluded — they're not part of the indexed entity state.
const RECONCILE_TABLES = [_][]const u8{
    "names",                "registries",              "registrations",           "registry_entries",
    "resolvers",            "resolver_addresses",      "resolver_contenthashes",  "resolver_texts",
    "resolver_aliases",     "resolver_pubkeys",        "resolver_abis",           "resolver_names",
    "resolver_interfaces",  "resolver_versions",       "resolver_metadata",       "resolver_approvals",
    "resolver_dns_records", "resolver_dns_zonehashes", "resolver_authorisations", "reverse_records",
    "approvals",            "eac_roles",               "accounts",                "v1_controllers",
    "name_history",
};

// Volatile columns excluded from the content comparison: the autoincrement id (insertion
// order differs) and the wall-clock columns set via zsys.timestamp() on write
// (names.updated_at, and the internal timestamps of approvals/eac_roles/resolvers/
// resolver_metadata). Deterministic block-derived columns (block_number, *_block, expiry,
// registered_at, first_seen_timestamp, …) ARE compared.
const RECONCILE_IGNORE = [_][]const u8{ "id", "created_at", "updated_at", "set_at", "timestamp" };

fn reconcileIgnored(col: []const u8) bool {
    for (RECONCILE_IGNORE) |ig| if (std.mem.eql(u8, ig, col)) return true;
    return false;
}

/// Canonical dump of a table's content: every non-volatile column, every row, ordered
/// by full content so two DBs built from the same events produce identical bytes.
fn dumpTable(allocator: std.mem.Allocator, db: *Database, table: []const u8) ![]u8 {
    var cols: std.ArrayList([]u8) = .empty;
    defer {
        for (cols.items) |c| allocator.free(c);
        cols.deinit(allocator);
    }
    {
        // Dialect-agnostic column list (SQLite PRAGMA / PG information_schema), in
        // definition order on both backends — so the dump is comparable across two DBs of
        // the same backend.
        const info = try db.introspectColumns(allocator, table);
        defer lib.storage.backend.freeColumnInfo(allocator, info);
        for (info) |col| {
            if (reconcileIgnored(col.name)) continue;
            try cols.append(allocator, try allocator.dupe(u8, col.name));
        }
    }

    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);
    try sql.appendSlice(allocator, "SELECT ");
    for (cols.items, 0..) |c, i| {
        if (i > 0) try sql.appendSlice(allocator, ", ");
        try sql.print(allocator, "\"{s}\"", .{c});
    }
    try sql.print(allocator, " FROM \"{s}\" ORDER BY ", .{table});
    for (cols.items, 0..) |c, i| {
        if (i > 0) try sql.appendSlice(allocator, ", ");
        try sql.print(allocator, "\"{s}\"", .{c});
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var q = try lib.storage.Query.init(db, sql.items);
    defer q.deinit();
    while (try q.step()) {
        for (cols.items, 0..) |_, i| {
            const v = q.getTextSlice(i) orelse "\x00NULL";
            try out.appendSlice(allocator, v);
            try out.append(allocator, 0x1f); // unit separator
        }
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

/// True if every reconciled table is content-identical between the two DBs.
fn reconcileEqual(allocator: std.mem.Allocator, db_a: *Database, db_b: *Database, print_on_diff: bool) !bool {
    for (RECONCILE_TABLES) |table| {
        const a = try dumpTable(allocator, db_a, table);
        defer allocator.free(a);
        const b = try dumpTable(allocator, db_b, table);
        defer allocator.free(b);
        if (!std.mem.eql(u8, a, b)) {
            if (print_on_diff) {
                std.debug.print("reconcile MISMATCH in '{s}':\n  expected (clean):\n{s}\n  actual (rolled-back):\n{s}\n", .{ table, a, b });
            }
            return false;
        }
    }
    return true;
}

// Mutations at or before N=150 — the canonical state a clean sync would produce at 150.
fn applyReconcileBaseline(allocator: std.mem.Allocator, db: *Database) !void {
    const a = try Address.fromHex("0x00000000000000000000000000000000000000aa");
    const b = try Address.fromHex("0x00000000000000000000000000000000000000bb");
    const resolver = try Address.fromHex("0x00000000000000000000000000000000000000cc");
    const c1 = try Address.fromHex("0x00000000000000000000000000000000000000c1");
    const nh_foo = try namehash(allocator, "foo.eth");
    const tx = try Hash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000abc");
    const txs = "0x0000000000000000000000000000000000000000000000000000000000000abc";
    const acc = "0x00000000000000000000000000000000000000a1";

    try lib.storage.reorg_undo.setCursor(db, .v2, 100);
    var n = try makeReorgName(allocator, "foo.eth", .v2, a, 100);
    defer n.deinit(allocator);
    try db.insertName(n);
    try db.storeResolverText(nh_foo, resolver, "url", "a", .v2, 100, tx, 1700000100);
    try db.upsertAccount(.v2, acc, 100, 1700000100);

    try lib.storage.reorg_undo.setCursor(db, .v1, 110);
    try lib.storage.v1_controllers.addController(db, c1, 110, txs);

    try lib.storage.reorg_undo.setCursor(db, .v2, 120);
    try db.updateNameOwner(nh_foo, b); // in-place update, ≤ N

    try lib.storage.reorg_undo.setCursor(db, .v2, 130);
    try db.upsertReverseRecord(.v2, a, nh_foo, 130, tx, 0, 1700000130);

    try lib.storage.reorg_undo.setCursor(db, .v2, 140);
    try db.insertRegistration(.v2, nh_foo, "foo", "eth", a, 1700000140, 0, 140, tx, 0, .name_registered);
}

// Mutations after N=150 — must be fully reversed by the rollback.
fn applyReconcileReorged(allocator: std.mem.Allocator, db: *Database) !void {
    const a = try Address.fromHex("0x00000000000000000000000000000000000000aa");
    const cc_owner = try Address.fromHex("0x00000000000000000000000000000000000000dd");
    const resolver = try Address.fromHex("0x00000000000000000000000000000000000000cc");
    const c1 = try Address.fromHex("0x00000000000000000000000000000000000000c1");
    const nh_foo = try namehash(allocator, "foo.eth");
    const nh_bar = try namehash(allocator, "bar.eth");
    const tx = try Hash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000abc");
    const txs = "0x0000000000000000000000000000000000000000000000000000000000000abc";
    const acc_z = "0x00000000000000000000000000000000000000a2";

    try lib.storage.reorg_undo.setCursor(db, .v2, 200);
    try db.updateNameOwner(nh_foo, cc_owner); // owner B→new (revert to B)
    try db.storeResolverText(nh_foo, resolver, "url", "b", .v2, 200, tx, 1700000200); // overwrite (revert to "a")
    try db.upsertAccount(.v2, acc_z, 200, 1700000200); // new account (remove)
    var bar = try makeReorgName(allocator, "bar.eth", .v2, a, 200); // new name (remove)
    defer bar.deinit(allocator);
    try db.insertName(bar);
    try db.insertRegistration(.v2, nh_bar, "bar", "eth", a, 1700000200, 0, 200, tx, 1, .name_registered); // new reg (remove)
    try db.upsertReverseRecord(.v2, a, nh_bar, 200, tx, 0, 1700000200); // reverse overwrite (revert to foo)

    try lib.storage.reorg_undo.setCursor(db, .v1, 210);
    try lib.storage.v1_controllers.removeController(db, c1, 210, txs); // remove (revert to active)
}

test "reorg undo-log: rollback(N) equals a clean build at N across all entity tables" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var clean = try testDb(allocator);
    defer clean.deinit();
    try applyReconcileBaseline(allocator, &clean);

    var reorged = try testDb(allocator);
    defer reorged.deinit();
    try applyReconcileBaseline(allocator, &reorged);
    try applyReconcileReorged(allocator, &reorged);
    // Both protocols roll back (v1 controller + v2 entities), as a real chain reorg would.
    try lib.storage.sync.rollbackToBlock(&reorged, .v2, 150);
    try lib.storage.sync.rollbackToBlock(&reorged, .v1, 150);

    try testing.expect(try reconcileEqual(allocator, &clean, &reorged, true));
    std.debug.print("✓ rollback(N) == clean build at N across all 25 entity tables\n", .{});
}

// Negative control: prove the comparator actually detects drift (so the invariant
// test above can't pass vacuously).
test "reorg undo-log: reconcile comparator detects planted drift" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var a = try testDb(allocator);
    defer a.deinit();
    try applyReconcileBaseline(allocator, &a);

    var b = try testDb(allocator);
    defer b.deinit();
    try applyReconcileBaseline(allocator, &b);
    // Plant one extra in-place change in b only.
    try lib.storage.reorg_undo.setCursor(&b, .v2, 145);
    try b.updateNameOwner(try namehash(allocator, "foo.eth"), try Address.fromHex("0x00000000000000000000000000000000000000ee"));

    try testing.expect(!(try reconcileEqual(allocator, &a, &b, false)));
    std.debug.print("✓ reconcile comparator detects planted drift (negative control)\n", .{});
}

// ============================================================================
// Normalization enforcement (#19/#20): is_normalized is stored + filterable, and
// non-normalized names are default-hidden (opt-in via includeUnnormalized).
// ============================================================================

fn filteredNameCount(allocator: std.mem.Allocator, database: *Database, filters: lib.storage.names.NameFilters) !usize {
    const names = try lib.storage.names.getFilteredNames(database, filters, 0, 100, .desc, .created_at);
    defer {
        for (names) |*n| {
            var nn = n.*;
            nn.deinit(allocator);
        }
        allocator.free(names);
    }
    return names.len;
}

test "normalization: default-hides non-normalized names; opt-in shows them" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try testDb(allocator);
    defer database.deinit();

    const owner = try Address.fromHex("0x00000000000000000000000000000000000000aa");

    // A normalized name (is_normalized defaults true) and a non-normalized one.
    var norm = try makeReorgName(allocator, "alice.eth", .v2, owner, 100);
    defer norm.deinit(allocator);
    try database.insertName(norm);

    var weird = try makeReorgName(allocator, "Alice.eth", .v2, owner, 101);
    defer weird.deinit(allocator);
    weird.is_normalized = false;
    try database.insertName(weird);

    // Default: only the normalized name.
    try testing.expectEqual(@as(usize, 1), try filteredNameCount(allocator, &database, .{ .owner = owner }));
    // includeUnnormalized: both.
    try testing.expectEqual(@as(usize, 2), try filteredNameCount(allocator, &database, .{ .owner = owner, .include_unnormalized = true }));
    // isNormalized: false → only the non-normalized one (overrides default-hide).
    try testing.expectEqual(@as(usize, 1), try filteredNameCount(allocator, &database, .{ .owner = owner, .is_normalized = false }));
    // isNormalized: true → only the normalized one.
    try testing.expectEqual(@as(usize, 1), try filteredNameCount(allocator, &database, .{ .owner = owner, .is_normalized = true }));

    // The stored flag round-trips through getNameByNamehash (parseNameRow → isNormalized field).
    const reread = (try database.getNameByNamehash(weird.namehash)) orelse return error.NameVanished;
    var rr = reread;
    defer rr.deinit(allocator);
    try testing.expect(!rr.is_normalized);

    // It must ALSO round-trip through getFilteredNames (parseNameRows — a separate SELECT
    // + parser): under includeUnnormalized the returned Name carries the real flag, not the
    // model default. (Regression guard for the SELECT/parser that initially omitted it.)
    const listed = try lib.storage.names.getFilteredNames(&database, .{ .owner = owner, .include_unnormalized = true }, 0, 100, .desc, .created_at);
    defer {
        for (listed) |*n| {
            var nn = n.*;
            nn.deinit(allocator);
        }
        allocator.free(listed);
    }
    var saw_weird = false;
    for (listed) |*n| {
        if (std.mem.eql(u8, &n.namehash.bytes, &weird.namehash.bytes)) {
            saw_weird = true;
            try testing.expect(!n.is_normalized); // real stored value, via parseNameRows
        }
    }
    try testing.expect(saw_weird);
    std.debug.print("✓ non-normalized names default-hidden, opt-in via includeUnnormalized/isNormalized; flag persists through both SELECT paths\n", .{});
}

// ============================================================================
// Reorg undo-log: adversarial hard sites (plan "A/B Lane 3"). Each part runs in
// BOTH lanes — trigger capture (test-integration) and write-path capture
// (test-integration-fallback) — and pins the four sites the rest of the suite
// did not reach: the dynamic-IN-list reachability flip (the only runtime-binder
// capture), the names delete with unknown_labels cascade children, the
// key-scoped resolver_texts delete, and the created_block lowering that defeats
// the created-after delete net.
// ============================================================================

test "reorg undo-log: bulk reachability flip is reverted (dynamic IN-list capture)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try testDb(allocator);
    defer database.deinit();

    try lib.storage.reorg_undo.setCursor(&database, .v2, 100);
    var n = try makeReorgName(allocator, "reach.eth", .v2, try Address.fromHex("0x00000000000000000000000000000000000000aa"), 100);
    defer n.deinit(allocator);
    n.is_reachable = true;
    try database.insertName(n);

    try lib.storage.reorg_undo.setCursor(&database, .v2, 200);
    const registries = [_]Address{n.registry};
    const flipped = try lib.storage.registry_entries.setRegistriesReachability(&database, .v2, &registries, false, 200, 1700000200);
    try testing.expectEqual(@as(u64, 1), flipped);
    {
        var got = (try database.getNameByNamehash(n.namehash)) orelse return error.NameVanished;
        defer got.deinit(allocator);
        try testing.expect(!got.is_reachable);
    }

    try lib.storage.sync.rollbackToBlock(&database, .v2, 150);
    var got = (try database.getNameByNamehash(n.namehash)) orelse return error.NameVanished;
    defer got.deinit(allocator);
    try testing.expect(got.is_reachable);
}

test "reorg undo-log: names delete restores unknown_labels cascade children" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try testDb(allocator);
    defer database.deinit();

    try lib.storage.reorg_undo.setCursor(&database, .v1, 100);
    var n = try makeReorgName(allocator, "gcparent.eth", .v1, try Address.fromHex("0x00000000000000000000000000000000000000aa"), 100);
    defer n.deinit(allocator);
    try database.insertName(n);

    const name_id: i64 = blk: {
        var q = try lib.storage.Query.init(&database, "SELECT id FROM names WHERE namehash = ?");
        defer q.deinit();
        try q.bindHash(n.namehash);
        try testing.expect(try q.step());
        break :blk q.getInt64(0);
    };
    try lib.storage.unknown_labels.insertUnknownLabel(&database, name_id, try namehash(allocator, "txh"), try keccak256(allocator, "lbl"), n.namehash, n.parent_namehash, n.owner, 100);
    try testing.expectEqual(@as(i64, 1), try unknownLabelCount(&database));

    // Block 200: delete the parent — the FK cascade removes the child row too.
    try lib.storage.reorg_undo.setCursor(&database, .v1, 200);
    try lib.storage.names.deleteNameByNamehash(&database, n.namehash);
    try testing.expectEqual(@as(i64, 0), try unknownLabelCount(&database));
    try testing.expect((try database.getNameByNamehash(n.namehash)) == null);

    // Rollback to 150: parent restored (same surrogate id) AND the cascade
    // child restored — the class the explicit cascade capture exists for.
    try lib.storage.sync.rollbackToBlock(&database, .v1, 150);
    var got = (try database.getNameByNamehash(n.namehash)) orelse return error.NameVanished;
    defer got.deinit(allocator);
    try testing.expectEqual(@as(i64, 1), try unknownLabelCount(&database));
}

test "reorg undo-log: key-scoped resolver text delete and created_block lowering revert" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try testDb(allocator);
    defer database.deinit();

    const resolver = try Address.fromHex("0x00000000000000000000000000000000000000cc");
    const nh = try namehash(allocator, "texty.eth");

    // Block 100: text record exists.
    try lib.storage.reorg_undo.setCursor(&database, .v1, 100);
    try lib.storage.resolvers.storeResolverText(&database, nh, resolver, "url", "https://a", .v1, 100, try namehash(allocator, "t1"), 1700000100);

    // Block 200: empty-value TextChanged clears just that key (4-term WHERE).
    try lib.storage.reorg_undo.setCursor(&database, .v1, 200);
    try lib.storage.resolvers.deleteResolverText(&database, .v1, nh, resolver, "url");
    {
        var q = try lib.storage.Query.init(&database, "SELECT value FROM resolver_texts WHERE namehash = ? AND key = 'url'");
        defer q.deinit();
        try q.bindHash(nh);
        try testing.expect(!(try q.step()));
    }

    // Also at block 200: a name created AFTER N gets its created_block lowered
    // below N — without undo capture the created_block>N delete would miss it.
    var n = try makeReorgName(allocator, "lowered.eth", .v1, try Address.fromHex("0x00000000000000000000000000000000000000aa"), 180);
    defer n.deinit(allocator);
    try database.insertName(n);
    try lib.storage.names.updateNameCreationDateIfEarlier(&database, n.namehash, 50, 1700000050);

    try lib.storage.sync.rollbackToBlock(&database, .v1, 150);

    // Text record restored with its original value.
    {
        var q = try lib.storage.Query.init(&database, "SELECT value FROM resolver_texts WHERE namehash = ? AND key = 'url'");
        defer q.deinit();
        try q.bindHash(nh);
        try testing.expect(try q.step());
        try testing.expectEqualStrings("https://a", q.getTextSlice(0).?);
    }
    // The lowered name is GONE: replay restored created_block=180, then the
    // created-after delete removed it — rollback ≡ clean-sync-at-150.
    try testing.expect((try database.getNameByNamehash(n.namehash)) == null);
}
