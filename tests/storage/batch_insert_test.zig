//! Equivalence tests for the bulk-flush batch insert paths
//! (insertEventsBatch / insertNamesBatch): multi-row statements must be
//! indistinguishable from sequential single-row inserts — including
//! conflict-ignore/update semantics, intra-slice duplicates (which Postgres
//! would reject inside one statement without the batch fns' dedup), and
//! chunk-boundary crossings.

const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers");
const lib = @import("lib");
const models = lib.models;
const Address = lib.Address;
const Hash = lib.Hash;

fn nthHash(n: u8) Hash {
    var h = Hash{ .bytes = [_]u8{0} ** 32 };
    h.bytes[31] = n;
    h.bytes[0] = 0x0B; // keep away from Hash.zero
    return h;
}

fn nthEvent(n: u8) models.Event {
    return models.Event{
        .event_type = .transfer,
        .protocol = .v2,
        .block_number = 1000 + @as(u64, n),
        .tx_hash = nthHash(n),
        .log_index = n,
        .contract_address = Address{ .bytes = [_]u8{0xEE} ** 20 },
        .name = null,
        .namehash = nthHash(n),
        .data = "{}",
        .timestamp = 1700000000,
    };
}

test "insertEventsBatch matches sequential semantics across chunks and duplicates" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    // Pre-existing row: the batch must conflict-ignore it, exactly like a
    // second sequential insertEvent would.
    try database.insertEvent(nthEvent(0));

    // 95 rows: crosses the 90-row chunk boundary. Slice[0] duplicates the
    // pre-existing row; slice[1] and slice[2] duplicate each other (the
    // intra-statement case Postgres rejects without keep-first dedup).
    var events_buf: [95]models.Event = undefined;
    for (&events_buf, 0..) |*e, i| e.* = nthEvent(@intCast(i));
    events_buf[2] = events_buf[1];

    try database.insertEventsBatch(&events_buf);

    // Distinct keys in the slice: 95 - 1 intra dup = 94; one already existed.
    const all = try database.getEventsFiltered(.{ .limit = 1000 });
    defer {
        for (all) |*e| e.deinit(database.allocator);
        database.allocator.free(all);
    }
    try testing.expectEqual(@as(usize, 94), all.len);
}

fn nthName(n: u8, owner: Address, name_str: []const u8) models.Name {
    return models.Name{
        .protocol = .v2,
        .name = name_str,
        .namehash = nthHash(n),
        .label = name_str,
        .label_hash = nthHash(n),
        .parent_name = "",
        .parent_namehash = Hash.zero,
        .registry = Address{ .bytes = [_]u8{0xCC} ** 20 },
        .owner = owner,
        .registrant = owner,
        .resolver = Address.zero,
        .token_id = n,
        .canonical_id = n,
        .token_version = 1,
        .expiry = 0,
        .registry_locked = false,
        .migrated = false,
        .created_block = 999,
        .created_at = 1700000000,
        .registered_at = 1700000000,
        .updated_block = 2000,
        .updated_at = 1700000500,
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    };
}

test "insertNamesBatch matches insertName semantics: conflict update, created preservation, keep-last dedup" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const owner_a = Address{ .bytes = [_]u8{0xA1} ** 20 };
    const owner_b = Address{ .bytes = [_]u8{0xB2} ** 20 };

    // Pre-existing row for key 7 with the fields the conflict tail treats
    // specially: created_block must survive the update, resolved_address must
    // COALESCE-keep its old value against the batch row's null.
    var pre = nthName(7, owner_a, "pre.eth");
    pre.created_block = 111;
    pre.resolved_address = Address{ .bytes = [_]u8{0xDD} ** 20 };
    try database.insertName(pre);

    // 35 rows: crosses the 30-row chunk boundary. Keys are 1..35, so key 7 is
    // slice index 6. Index 20 re-uses key 5 with a different owner — the
    // intra-slice duplicate; sequential semantics = last write wins.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var names_buf: [35]models.Name = undefined;
    for (&names_buf, 0..) |*n, i| {
        const key: u8 = @intCast(i + 1);
        const name_str = try std.fmt.allocPrint(arena.allocator(), "n{d}.eth", .{key});
        n.* = nthName(key, owner_a, name_str);
    }
    names_buf[20] = nthName(5, owner_b, "n5b.eth");

    try database.insertNamesBatch(&names_buf);

    // Every distinct key exists with the batch's fields. Key 21 was displaced
    // by the duplicate row at index 20 and is deliberately absent.
    var key: u8 = 1;
    while (key <= 35) : (key += 1) {
        if (key == 21) continue;
        const row = (try database.getNameByNamehashAndProtocol(nthHash(key), .v2)) orelse return error.MissingRow;
        var mut = row;
        defer mut.deinit(database.allocator);
        const expected_owner = if (key == 5) owner_b else owner_a;
        try testing.expect(row.owner.eql(expected_owner));
    }

    // Conflict-update semantics on the pre-existing key 7.
    const updated = (try database.getNameByNamehashAndProtocol(nthHash(7), .v2)) orelse return error.MissingRow;
    var updated_mut = updated;
    defer updated_mut.deinit(database.allocator);
    try testing.expect(updated.owner.eql(owner_a));
    try testing.expectEqual(@as(u64, 111), updated.created_block); // preserved, not 999
    try testing.expect(updated.resolved_address != null); // COALESCE kept the old value
    try testing.expect(updated.resolved_address.?.eql(Address{ .bytes = [_]u8{0xDD} ** 20 }));
    try testing.expectEqual(@as(u64, 2000), updated.updated_block); // regular column updated
}
