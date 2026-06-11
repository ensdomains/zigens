const std = @import("std");

/// Canonical ENS name join: `label` under `parent_name`. The root's name is
/// the empty string, so a root child is the bare label — a blind "{s}.{s}"
/// join produces "eth.", which fails ENSIP-15 normalization (trailing empty
/// label) and hides the row from default listings. Null and empty parents
/// both mean "no parent suffix". Caller owns the returned slice.
pub fn join(allocator: std.mem.Allocator, label: []const u8, parent_name: ?[]const u8) ![]u8 {
    const parent = parent_name orelse "";
    if (parent.len == 0) return try allocator.dupe(u8, label);
    return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ label, parent });
}

test "join: root parent (empty or null) yields the bare label" {
    const allocator = std.testing.allocator;

    const tld = try join(allocator, "eth", "");
    defer allocator.free(tld);
    try std.testing.expectEqualStrings("eth", tld);

    const orphan = try join(allocator, "eth", null);
    defer allocator.free(orphan);
    try std.testing.expectEqualStrings("eth", orphan);
}

test "join: non-root parent yields label.parent" {
    const allocator = std.testing.allocator;
    const name = try join(allocator, "alice", "eth");
    defer allocator.free(name);
    try std.testing.expectEqualStrings("alice.eth", name);
}
