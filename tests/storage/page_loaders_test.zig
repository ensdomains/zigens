//! Tests for the API-page batch loaders. Each one must be an exact mirror of the
//! point query it replaces, per key:
//!   - events.getEventsForNamehashesPage vs getEventsFiltered(.namehash = X) — same
//!     predicate tree, sort + tiebreak order and limit/skip window, per namehash;
//!   - names.getDomainsByResolvers vs getDomainByResolver — the single reachable,
//!     normalized, non-root row with the lowest namehash, per resolver.
//! Runs on SQLite (test-storage) and, via helpers.createTestDatabase, on Postgres
//! (test-storage-pg) — the window-function SQL must behave identically on both.

const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers");
const lib = @import("lib");
const Database = lib.Database;
const models = lib.models;
const Address = lib.Address;
const Hash = lib.Hash;
const events = lib.storage.events;
const names_storage = lib.storage.names;
const EventFilterOptions = events.EventFilterOptions;

fn nthHash(n: u8) Hash {
    var h = Hash{ .bytes = [_]u8{0} ** 32 };
    h.bytes[0] = 0x0D;
    h.bytes[31] = n;
    return h;
}

fn nthAddress(n: u8) Address {
    var a = Address{ .bytes = [_]u8{0} ** 20 };
    a.bytes[0] = 0xD0;
    a.bytes[19] = n;
    return a;
}

fn txHash(seq: u8) Hash {
    var h = Hash{ .bytes = [_]u8{0} ** 32 };
    h.bytes[0] = 0xE0;
    h.bytes[31] = seq;
    return h;
}

const OWNER = Address{ .bytes = [_]u8{0xA1} ** 20 };

fn fixtureName(namehash: Hash, name_str: []const u8, resolver: Address, reachable: bool, normalized: bool) models.Name {
    return models.Name{
        .protocol = .v2,
        .name = name_str,
        .namehash = namehash,
        .label = name_str,
        .label_hash = namehash,
        .parent_name = "",
        .parent_namehash = Hash.zero,
        .registry = helpers.TEST_REGISTRY,
        .owner = OWNER,
        .registrant = OWNER,
        .resolver = resolver,
        .token_id = 0,
        .canonical_id = 0,
        .token_version = 1,
        .expiry = 0,
        .registry_locked = false,
        .migrated = false,
        .created_block = 100,
        .created_at = 1700000000,
        .registered_at = 1700000000,
        .updated_block = 100,
        .updated_at = 1700000000,
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
        .is_reachable = reachable,
        .is_normalized = normalized,
    };
}

const FixtureEvent = struct {
    seq: u8,
    event_type: models.EventType,
    namehash: ?Hash,
    name: ?[]const u8,
    block: u64,
    log_index: u32,
    timestamp: i64,
    data: []const u8 = "{}",
};

fn insertFixtureEvent(db: *Database, ev: FixtureEvent) !void {
    try db.insertEvent(.{
        .protocol = .v2,
        .event_type = ev.event_type,
        .block_number = ev.block,
        .tx_hash = txHash(ev.seq),
        .log_index = ev.log_index,
        .contract_address = helpers.TEST_REGISTRY,
        .name = ev.name,
        .namehash = ev.namehash,
        .data = ev.data,
        .timestamp = ev.timestamp,
    });
}

// ============================================================================
// getEventsForNamehashesPage
// ============================================================================

const NH_A = nthHash(1); // five events, mixed types, non-monotonic timestamps
const NH_B = nthHash(2); // three events
const NH_C = nthHash(3); // one event
const NH_D = nthHash(4); // a name with zero events
const NH_MISSING = nthHash(5); // in neither names nor events
const NH_NOISE = nthHash(6); // has events but is never queried

fn seedEventFixtures(db: *Database) !void {
    try db.insertName(fixtureName(NH_A, "a.eth", Address.zero, true, true));
    try db.insertName(fixtureName(NH_B, "b.eth", Address.zero, true, true));
    try db.insertName(fixtureName(NH_C, "c.eth", Address.zero, true, true));
    try db.insertName(fixtureName(NH_D, "d.eth", Address.zero, true, true));

    // Timestamps deliberately disagree with block order so a timestamp sort is a
    // different permutation from the block_number sort; expiry lives in data for
    // some rows only so the JSON sort expression sees both values and NULLs.
    const fixtures = [_]FixtureEvent{
        .{ .seq = 1, .event_type = .transfer, .namehash = NH_A, .name = "a.eth", .block = 10, .log_index = 0, .timestamp = 5000 },
        .{ .seq = 2, .event_type = .name_registered, .namehash = NH_A, .name = "a.eth", .block = 10, .log_index = 1, .timestamp = 4000, .data = "{\"expiry\":900}" },
        .{ .seq = 3, .event_type = .transfer, .namehash = NH_A, .name = "a.eth", .block = 11, .log_index = 3, .timestamp = 6000 },
        .{ .seq = 4, .event_type = .text_changed, .namehash = NH_A, .name = "a.eth", .block = 12, .log_index = 0, .timestamp = 3000 },
        .{ .seq = 5, .event_type = .name_renewed, .namehash = NH_A, .name = "a.eth", .block = 15, .log_index = 0, .timestamp = 7000, .data = "{\"expiry\":300}" },
        .{ .seq = 6, .event_type = .transfer, .namehash = NH_B, .name = "b.eth", .block = 9, .log_index = 2, .timestamp = 6500 },
        .{ .seq = 7, .event_type = .name_renewed, .namehash = NH_B, .name = "b.eth", .block = 13, .log_index = 1, .timestamp = 2000, .data = "{\"expiry\":100}" },
        .{ .seq = 8, .event_type = .text_changed, .namehash = NH_B, .name = null, .block = 13, .log_index = 0, .timestamp = 2500 },
        .{ .seq = 9, .event_type = .name_registered, .namehash = NH_C, .name = "c.eth", .block = 11, .log_index = 7, .timestamp = 4500, .data = "{\"expiry\":500}" },
        .{ .seq = 10, .event_type = .transfer, .namehash = NH_NOISE, .name = "noise.eth", .block = 10, .log_index = 0, .timestamp = 5000 },
        .{ .seq = 11, .event_type = .transfer, .namehash = null, .name = null, .block = 10, .log_index = 5, .timestamp = 5000 },
    };
    for (fixtures) |ev| try insertFixtureEvent(db, ev);
}

/// Every event in `batch` whose namehash is `nh`, in batch order.
fn collectForNamehash(allocator: std.mem.Allocator, batch: []const models.Event, nh: Hash) ![]const models.Event {
    var out: std.ArrayList(models.Event) = .empty;
    errdefer out.deinit(allocator);
    for (batch) |ev| {
        if (ev.namehash) |h| {
            if (h.eql(nh)) try out.append(allocator, ev);
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn expectSameRows(expected: []const models.Event, actual: []const models.Event) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| {
        try testing.expect(e.tx_hash.eql(a.tx_hash));
        try testing.expectEqual(e.log_index, a.log_index);
        try testing.expectEqual(e.block_number, a.block_number);
        try testing.expectEqual(e.event_type, a.event_type);
        try testing.expectEqual(e.timestamp, a.timestamp);
        try testing.expectEqualStrings(e.data, a.data);
    }
}

/// Each namehash must occupy one contiguous run of the batch (ORDER BY namehash, rn).
fn expectGroupedByNamehash(batch: []const models.Event) !void {
    var i: usize = 0;
    while (i < batch.len) : (i += 1) {
        const nh = batch[i].namehash.?;
        if (i > 0 and batch[i - 1].namehash.?.eql(nh)) continue;
        var j: usize = 0;
        while (j < i) : (j += 1) try testing.expect(!batch[j].namehash.?.eql(nh));
    }
}

/// The batch loader over `query_hashes` must equal getEventsFiltered(.namehash = X)
/// for every X, with no stray rows from unqueried namehashes.
fn expectPageMirrorsPointQuery(allocator: std.mem.Allocator, db: *Database, query_hashes: []const Hash, filter: EventFilterOptions) !void {
    const batch = try events.getEventsForNamehashesPage(db, query_hashes, filter, allocator);
    defer events.freeEvents(allocator, batch);
    try expectGroupedByNamehash(batch);

    // A namehash listed twice must appear once in the batch (dedup happens
    // before chunking), so the expected total counts each distinct hash once.
    var counted: std.ArrayList(Hash) = .empty;
    defer counted.deinit(allocator);
    var expected_total: usize = 0;
    for (query_hashes) |nh| {
        var already = false;
        for (counted.items) |c| {
            if (c.eql(nh)) already = true;
        }
        if (already) continue;
        try counted.append(allocator, nh);
        var hex_buf: [66]u8 = undefined;
        var point_filter = filter;
        point_filter.namehash = nh.toHexBuf(&hex_buf);
        const expected = try db.getEventsFiltered(point_filter);
        defer events.freeEvents(db.allocator, expected);

        const actual = try collectForNamehash(allocator, batch, nh);
        defer allocator.free(actual);
        try expectSameRows(expected, actual);
        expected_total += expected.len;
    }
    try testing.expectEqual(expected_total, batch.len);
}

test "getEventsForNamehashesPage mirrors getEventsFiltered per namehash across filter variants" {
    const allocator = testing.allocator;
    const db = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, db);
    try seedEventFixtures(db);

    const query_hashes = [_]Hash{ NH_A, NH_B, NH_C, NH_D, NH_MISSING };

    const or_children = [_]EventFilterOptions{ .{ .event_type = "Transfer" }, .{ .event_type = "NameRenewed" } };
    const type_list = [_][]const u8{ "Transfer", "NameRenewed" };
    const variants = [_]EventFilterOptions{
        .{},
        .{ .order_dir = .asc },
        .{ .sort_field = .timestamp, .order_dir = .desc },
        .{ .sort_field = .timestamp, .order_dir = .asc, .limit = 2 },
        .{ .sort_field = .name, .order_dir = .asc },
        .{ .sort_field = .expiry, .order_dir = .asc },
        .{ .sort_field = .expiry, .order_dir = .desc, .limit = 1 },
        .{ .event_type = "Transfer" },
        .{ .event_type_not = "Transfer", .order_dir = .asc },
        .{ .event_types = &type_list },
        .{ .limit = 2, .skip = 1 },
        .{ .limit = 1, .skip = 0, .order_dir = .asc },
        .{ .limit = 0 },
        .{ .skip = 50 },
        .{ .block_number_gt = 10 },
        .{ .block_number_gte = 10, .block_number_lte = 12, .order_dir = .asc },
        .{ .timestamp_lt = 5000, .sort_field = .timestamp },
        .{ .protocol = .v2, .contract_address = "0xaabbccddeeff00112233445566778899aabbccdd" },
        .{ .expiry_gte = 300, .sort_field = .expiry, .order_dir = .asc },
        .{ .block_number_gte = 10, .or_group = &or_children },
        // A caller-supplied namehash is overridden per namehash, exactly as the point
        // query's `.namehash = X` would be — so every queried namehash still answers.
        .{ .namehash = "0x0d00000000000000000000000000000000000000000000000000000000000002" },
    };
    for (variants) |filter| try expectPageMirrorsPointQuery(allocator, db, &query_hashes, filter);
}

test "getEventsForNamehashesPage: empty input, unknown-only input, and multi-chunk input" {
    const allocator = testing.allocator;
    const db = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, db);
    try seedEventFixtures(db);

    {
        const batch = try events.getEventsForNamehashesPage(db, &.{}, .{}, allocator);
        defer events.freeEvents(allocator, batch);
        try testing.expectEqual(@as(usize, 0), batch.len);
    }
    {
        const batch = try events.getEventsForNamehashesPage(db, &.{ NH_D, NH_MISSING }, .{}, allocator);
        defer events.freeEvents(allocator, batch);
        try testing.expectEqual(@as(usize, 0), batch.len);
    }

    // 450 namehashes → three IN-list statements; the seeded ones sit in different
    // chunks and the rest are absent, so the concatenation must still mirror the
    // point query exactly.
    var many: [450]Hash = undefined;
    for (&many, 0..) |*h, i| {
        h.* = Hash{ .bytes = [_]u8{0} ** 32 };
        h.bytes[0] = 0x4E;
        h.bytes[30] = @intCast(i / 256);
        h.bytes[31] = @intCast(i % 256);
    }
    many[0] = NH_A;
    many[205] = NH_B;
    many[449] = NH_C;
    try expectPageMirrorsPointQuery(allocator, db, &many, .{});
    try expectPageMirrorsPointQuery(allocator, db, &many, .{ .limit = 2, .skip = 1, .sort_field = .timestamp, .order_dir = .asc });

    // The same namehash straddling two chunks (a v1/v2 twin page) yields its
    // window exactly once, not once per chunk.
    many[210] = NH_A;
    many[448] = NH_A;
    try expectPageMirrorsPointQuery(allocator, db, &many, .{});
    try expectPageMirrorsPointQuery(allocator, db, &many, .{ .limit = 3, .sort_field = .timestamp, .order_dir = .desc });
}

// ============================================================================
// getDomainsByResolvers
// ============================================================================

const RES_SHARED = nthAddress(0x51); // two reachable rows → lowest namehash wins
const RES_MIXED = nthAddress(0x52); // unreachable + non-normalized rows sort lower than the eligible one
const RES_UNREACHABLE_ONLY = nthAddress(0x53);
const RES_UNNORMALIZED_ONLY = nthAddress(0x54);
const RES_ROOT_ONLY = nthAddress(0x55); // only the root row (namehash 0x00…0) points here
const RES_UNKNOWN = nthAddress(0x56);

fn seedResolverFixtures(db: *Database) !void {
    try db.insertName(fixtureName(nthHash(0x21), "shared-hi.eth", RES_SHARED, true, true));
    try db.insertName(fixtureName(nthHash(0x20), "shared-lo.eth", RES_SHARED, true, true));

    try db.insertName(fixtureName(nthHash(0x2E), "mixed-unnormalized.eth", RES_MIXED, true, false));
    try db.insertName(fixtureName(nthHash(0x2F), "mixed-unreachable.eth", RES_MIXED, false, true));
    try db.insertName(fixtureName(nthHash(0x30), "mixed-eligible.eth", RES_MIXED, true, true));

    try db.insertName(fixtureName(nthHash(0x40), "orphan.eth", RES_UNREACHABLE_ONLY, false, true));
    try db.insertName(fixtureName(nthHash(0x41), "unnormalized.eth", RES_UNNORMALIZED_ONLY, true, false));
    try db.insertName(fixtureName(Hash.zero, "", RES_ROOT_ONLY, true, true));
}

fn expectDomainsMirrorPointQuery(allocator: std.mem.Allocator, db: *Database, resolvers: []const Address) !void {
    const batch = try names_storage.getDomainsByResolvers(db, resolvers, allocator);
    defer {
        for (batch) |*n| n.deinit(allocator);
        allocator.free(batch);
    }

    var expected_rows: usize = 0;
    var seen_resolvers: std.ArrayList(Address) = .empty;
    defer seen_resolvers.deinit(allocator);
    for (resolvers) |resolver| {
        var already = false;
        for (seen_resolvers.items) |s| {
            if (s.eql(resolver)) already = true;
        }
        if (already) continue;
        try seen_resolvers.append(allocator, resolver);

        var expected = try db.getDomainByResolver(resolver);
        defer if (expected) |*e| e.deinit(db.allocator);
        if (expected != null) expected_rows += 1;

        var matches: usize = 0;
        for (batch) |row| {
            if (!row.resolver.eql(resolver)) continue;
            matches += 1;
            const e = expected orelse return error.UnexpectedRowForResolver;
            try testing.expect(e.namehash.eql(row.namehash));
            try testing.expectEqualStrings(e.name.?, row.name.?);
            try testing.expectEqual(e.is_reachable, row.is_reachable);
            try testing.expectEqual(e.is_normalized, row.is_normalized);
        }
        try testing.expectEqual(@as(usize, if (expected != null) 1 else 0), matches);
    }
    try testing.expectEqual(expected_rows, batch.len);
}

test "getDomainsByResolvers mirrors getDomainByResolver per resolver" {
    const allocator = testing.allocator;
    const db = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, db);
    try seedResolverFixtures(db);

    const resolvers = [_]Address{ RES_SHARED, RES_MIXED, RES_UNREACHABLE_ONLY, RES_UNNORMALIZED_ONLY, RES_ROOT_ONLY, RES_UNKNOWN };
    try expectDomainsMirrorPointQuery(allocator, db, &resolvers);

    // Spot-check the tie-break and the visibility filters directly.
    const batch = try names_storage.getDomainsByResolvers(db, &resolvers, allocator);
    defer {
        for (batch) |*n| n.deinit(allocator);
        allocator.free(batch);
    }
    try testing.expectEqual(@as(usize, 2), batch.len);
    for (batch) |row| {
        if (row.resolver.eql(RES_SHARED)) {
            try testing.expectEqualStrings("shared-lo.eth", row.name.?);
        } else if (row.resolver.eql(RES_MIXED)) {
            try testing.expectEqualStrings("mixed-eligible.eth", row.name.?);
        } else {
            return error.UnexpectedResolverInBatch;
        }
    }
}

test "getDomainsByResolvers: empty input, duplicates, and multi-chunk input" {
    const allocator = testing.allocator;
    const db = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, db);
    try seedResolverFixtures(db);

    {
        const batch = try names_storage.getDomainsByResolvers(db, &.{}, allocator);
        defer allocator.free(batch);
        try testing.expectEqual(@as(usize, 0), batch.len);
    }
    // A resolver listed twice is still one partition → one row.
    try expectDomainsMirrorPointQuery(allocator, db, &.{ RES_SHARED, RES_UNKNOWN, RES_SHARED });

    // 300 addresses → two IN-list statements with the seeded resolvers split across them.
    var many: [300]Address = undefined;
    for (&many, 0..) |*a, i| {
        a.* = Address{ .bytes = [_]u8{0} ** 20 };
        a.bytes[0] = 0x4E;
        a.bytes[18] = @intCast(i / 256);
        a.bytes[19] = @intCast(i % 256);
    }
    many[3] = RES_SHARED;
    many[199] = RES_UNREACHABLE_ONLY;
    many[200] = RES_MIXED;
    many[299] = RES_ROOT_ONLY;
    try expectDomainsMirrorPointQuery(allocator, db, &many);

    // A resolver repeated across the chunk boundary still yields one row.
    many[250] = RES_SHARED;
    try expectDomainsMirrorPointQuery(allocator, db, &many);
}
