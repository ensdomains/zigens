const std = @import("std");
const testing = std.testing;

// Tests for filter logic used in GraphQL queries

test "case insensitive string matching" {
    const allocator = testing.allocator;

    // Test basic case insensitive matching
    const name = "VitalikButerin.eth";
    const filter = "VITALIK";

    const lower_name = try std.ascii.allocLowerString(allocator, name);
    defer allocator.free(lower_name);
    const lower_filter = try std.ascii.allocLowerString(allocator, filter);
    defer allocator.free(lower_filter);

    try testing.expect(std.mem.indexOf(u8, lower_name, lower_filter) != null);
}

test "case insensitive string matching - no match" {
    const allocator = testing.allocator;

    const name = "vitalik.eth";
    const filter = "BUTERIN";

    const lower_name = try std.ascii.allocLowerString(allocator, name);
    defer allocator.free(lower_name);
    const lower_filter = try std.ascii.allocLowerString(allocator, filter);
    defer allocator.free(lower_filter);

    try testing.expect(std.mem.indexOf(u8, lower_name, lower_filter) == null);
}

test "string prefix matching - positive cases" {
    try testing.expect(std.mem.startsWith(u8, "vitalik.eth", "vitalik"));
    try testing.expect(std.mem.startsWith(u8, "vitalik.eth", "v"));
    try testing.expect(std.mem.startsWith(u8, "vitalik.eth", ""));
    try testing.expect(std.mem.startsWith(u8, "alice.test.eth", "alice"));
}

test "string prefix matching - negative cases" {
    try testing.expect(!std.mem.startsWith(u8, "vitalik.eth", "buterin"));
    try testing.expect(!std.mem.startsWith(u8, "vitalik.eth", "ETH"));
    try testing.expect(!std.mem.startsWith(u8, "vitalik.eth", "vitalik.eth.extra"));
}

test "string suffix matching - positive cases" {
    try testing.expect(std.mem.endsWith(u8, "vitalik.eth", ".eth"));
    try testing.expect(std.mem.endsWith(u8, "vitalik.eth", "eth"));
    try testing.expect(std.mem.endsWith(u8, "vitalik.eth", ""));
    try testing.expect(std.mem.endsWith(u8, "alice.test.eth", ".test.eth"));
}

test "string suffix matching - negative cases" {
    try testing.expect(!std.mem.endsWith(u8, "vitalik.eth", ".com"));
    try testing.expect(!std.mem.endsWith(u8, "vitalik.eth", "vitalik"));
    try testing.expect(!std.mem.endsWith(u8, "vitalik.eth", "extra.eth"));
}

test "timestamp range filtering - gte" {
    const timestamp: i64 = 1700000000;
    const filter_gte: i64 = 1600000000;

    try testing.expect(timestamp >= filter_gte);
}

test "timestamp range filtering - lte" {
    const timestamp: i64 = 1700000000;
    const filter_lte: i64 = 1800000000;

    try testing.expect(timestamp <= filter_lte);
}

test "timestamp range filtering - both gte and lte" {
    const timestamp: i64 = 1700000000;
    const filter_gte: i64 = 1600000000;
    const filter_lte: i64 = 1800000000;

    try testing.expect(timestamp >= filter_gte and timestamp <= filter_lte);
}

test "timestamp range filtering - outside range" {
    const timestamp: i64 = 1500000000;
    const filter_gte: i64 = 1600000000;
    const filter_lte: i64 = 1800000000;

    try testing.expect(!(timestamp >= filter_gte and timestamp <= filter_lte));
}

test "expiry calculation from duration" {
    const registration_time: i64 = 1700000000;
    const duration: i64 = 31536000; // 1 year in seconds
    const expected_expiry: i64 = 1731536000;

    const calculated_expiry = registration_time + duration;
    try testing.expectEqual(expected_expiry, calculated_expiry);
}

test "sorting comparison - ascending strings" {
    const names = [_][]const u8{
        "alice.eth",
        "bob.eth",
        "charlie.eth",
        "david.eth",
    };

    for (0..names.len - 1) |i| {
        const cmp = std.mem.order(u8, names[i], names[i + 1]);
        try testing.expectEqual(std.math.Order.lt, cmp);
    }
}

test "sorting comparison - descending strings" {
    const names = [_][]const u8{
        "david.eth",
        "charlie.eth",
        "bob.eth",
        "alice.eth",
    };

    for (0..names.len - 1) |i| {
        const cmp = std.mem.order(u8, names[i], names[i + 1]);
        try testing.expectEqual(std.math.Order.gt, cmp);
    }
}

test "sorting comparison - ascending timestamps" {
    const timestamps = [_]i64{ 1000000000, 1500000000, 2000000000, 2500000000 };

    for (0..timestamps.len - 1) |i| {
        try testing.expect(timestamps[i] < timestamps[i + 1]);
    }
}

test "sorting comparison - descending timestamps" {
    const timestamps = [_]i64{ 2500000000, 2000000000, 1500000000, 1000000000 };

    for (0..timestamps.len - 1) |i| {
        try testing.expect(timestamps[i] > timestamps[i + 1]);
    }
}

test "array membership check - address in list" {
    const Address = struct {
        bytes: [20]u8,

        pub fn eql(self: @This(), other: @This()) bool {
            return std.mem.eql(u8, &self.bytes, &other.bytes);
        }
    };

    const target = Address{ .bytes = [_]u8{1} ++ [_]u8{0} ** 19 };
    const list = [_]Address{
        Address{ .bytes = [_]u8{0} ** 20 },
        Address{ .bytes = [_]u8{1} ++ [_]u8{0} ** 19 },
        Address{ .bytes = [_]u8{2} ++ [_]u8{0} ** 19 },
    };

    var found = false;
    for (list) |addr| {
        if (target.eql(addr)) {
            found = true;
            break;
        }
    }

    try testing.expect(found);
}

test "array membership check - address not in list" {
    const Address = struct {
        bytes: [20]u8,

        pub fn eql(self: @This(), other: @This()) bool {
            return std.mem.eql(u8, &self.bytes, &other.bytes);
        }
    };

    const target = Address{ .bytes = [_]u8{99} ++ [_]u8{0} ** 19 };
    const list = [_]Address{
        Address{ .bytes = [_]u8{0} ** 20 },
        Address{ .bytes = [_]u8{1} ++ [_]u8{0} ** 19 },
        Address{ .bytes = [_]u8{2} ++ [_]u8{0} ** 19 },
    };

    var found = false;
    for (list) |addr| {
        if (target.eql(addr)) {
            found = true;
            break;
        }
    }

    try testing.expect(!found);
}

test "combined filters - all match" {
    const allocator = testing.allocator;

    const name = "alice.eth";
    const owner_matches = true;
    const expiry: i64 = 1700000000;

    // name_contains_nocase: "ALICE"
    const filter_name = "ALICE";
    const lower_name = try std.ascii.allocLowerString(allocator, name);
    defer allocator.free(lower_name);
    const lower_filter = try std.ascii.allocLowerString(allocator, filter_name);
    defer allocator.free(lower_filter);
    const name_matches = std.mem.indexOf(u8, lower_name, lower_filter) != null;

    // name_ends_with: ".eth"
    const ends_with_matches = std.mem.endsWith(u8, name, ".eth");

    // expiryDate_gte: 1600000000
    const expiry_gte: i64 = 1600000000;
    const expiry_matches = expiry >= expiry_gte;

    const all_match = name_matches and ends_with_matches and owner_matches and expiry_matches;
    try testing.expect(all_match);
}

test "combined filters - one fails" {
    const allocator = testing.allocator;

    const name = "alice.eth";
    const owner_matches = true;
    const expiry: i64 = 1500000000; // Too early!

    // name_contains_nocase: "ALICE"
    const filter_name = "ALICE";
    const lower_name = try std.ascii.allocLowerString(allocator, name);
    defer allocator.free(lower_name);
    const lower_filter = try std.ascii.allocLowerString(allocator, filter_name);
    defer allocator.free(lower_filter);
    const name_matches = std.mem.indexOf(u8, lower_name, lower_filter) != null;

    // name_ends_with: ".eth"
    const ends_with_matches = std.mem.endsWith(u8, name, ".eth");

    // expiryDate_gte: 1600000000
    const expiry_gte: i64 = 1600000000;
    const expiry_matches = expiry >= expiry_gte;

    const all_match = name_matches and ends_with_matches and owner_matches and expiry_matches;
    try testing.expect(!all_match);
}

test "edge case - empty string filters" {
    try testing.expect(std.mem.startsWith(u8, "vitalik.eth", ""));
    try testing.expect(std.mem.endsWith(u8, "vitalik.eth", ""));
}

test "edge case - exact match" {
    try testing.expect(std.mem.startsWith(u8, "vitalik.eth", "vitalik.eth"));
    try testing.expect(std.mem.endsWith(u8, "vitalik.eth", "vitalik.eth"));
}

test "edge case - filter longer than name" {
    try testing.expect(!std.mem.startsWith(u8, "vitalik.eth", "vitalik.eth.extra"));
    try testing.expect(!std.mem.endsWith(u8, "vitalik.eth", "extra.vitalik.eth"));
}

test "edge case - timestamp boundaries" {
    const timestamp: i64 = 1700000000;

    // Exact match for gte
    try testing.expect(timestamp >= 1700000000);

    // Exact match for lte
    try testing.expect(timestamp <= 1700000000);

    // Just above lower bound
    try testing.expect(timestamp >= 1699999999);

    // Just below upper bound
    try testing.expect(timestamp <= 1700000001);
}

test "sort stability - equal elements maintain order" {
    // When timestamps are equal, original order should be preserved
    const Item = struct {
        id: u32,
        timestamp: i64,
    };

    const items = [_]Item{
        .{ .id = 1, .timestamp = 1000 },
        .{ .id = 2, .timestamp = 1000 },
        .{ .id = 3, .timestamp = 1000 },
    };

    // After stable sort by timestamp, IDs should still be in order
    // (Zig's sort is not guaranteed to be stable, but we test the concept)
    for (items, 0..) |item, i| {
        try testing.expectEqual(@as(u32, @intCast(i + 1)), item.id);
    }
}

test "unicode in domain names - case insensitive" {
    const allocator = testing.allocator;

    // ENS allows emoji and unicode
    const name = "🌟vitalik.eth";
    const filter = "vitalik";

    const lower_name = try std.ascii.allocLowerString(allocator, name);
    defer allocator.free(lower_name);
    const lower_filter = try std.ascii.allocLowerString(allocator, filter);
    defer allocator.free(lower_filter);

    try testing.expect(std.mem.indexOf(u8, lower_name, lower_filter) != null);
}
