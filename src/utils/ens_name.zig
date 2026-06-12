const std = @import("std");
const unicode = @import("unicode.zig");

/// Canonical representation of "this name's parent is the root". The root's
/// stored name is the empty string, and the `names.parent_name` column is
/// NOT NULL, so every layer (in-memory model, SQL, GraphQL joins) agrees on
/// `""` — never `null` — for a root child. Storage coerces a null to this at
/// the bind boundary so the invariant cannot be violated by any caller.
pub const ROOT_PARENT: []const u8 = "";

/// Canonical ENS name join: `label` under `parent_name`. A root child (parent
/// is null or empty) is the bare label — a blind "{label}.{parent}" join
/// produces "eth.", which fails ENSIP-15 normalization (trailing empty label)
/// and hides the row from default listings. Caller owns the returned slice.
///
/// `label` is assumed already structurally valid (see `validateLabel`, which
/// the indexer applies at the on-chain ingestion boundary); join itself does
/// not re-validate so it stays usable for internally-synthesized labels
/// (`[labelhash]` placeholders, reverse-address labels).
pub fn join(allocator: std.mem.Allocator, label: []const u8, parent_name: ?[]const u8) ![]u8 {
    const parent = parent_name orelse ROOT_PARENT;
    if (parent.len == 0) return try allocator.dupe(u8, label);
    return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ label, parent });
}

/// Structural validity of a single ENS label as it enters the indexer from an
/// on-chain event. Beyond UTF-8/control-character hygiene (`unicode.validateName`),
/// a label must be non-empty and must not contain the `.` separator: either
/// would let `join` synthesize a malformed name (".eth", "foo..eth", "eth.")
/// whose namehash collides with a different name (the namehash algorithm skips
/// empty labels), letting a crafted event overwrite an unrelated row on upsert.
pub fn validateLabel(label: []const u8) !void {
    try unicode.validateName(label);
    if (label.len == 0) return error.EmptyLabel;
    if (std.mem.indexOfScalar(u8, label, '.') != null) return error.LabelContainsSeparator;
}

test "join: root parent (empty or null) yields the bare label" {
    const allocator = std.testing.allocator;

    const tld = try join(allocator, "eth", ROOT_PARENT);
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

test "validateLabel: accepts real labels and internal placeholders" {
    try validateLabel("eth");
    try validateLabel("vitalik");
    try validateLabel("[9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501]");
    try validateLabel("d8da6bf26964af9d7eed9e03e53415d37aa96045"); // reverse-address label
}

test "validateLabel: rejects empty and separator-bearing labels" {
    try std.testing.expectError(error.EmptyLabel, validateLabel(""));
    try std.testing.expectError(error.LabelContainsSeparator, validateLabel("foo.bar"));
    try std.testing.expectError(error.LabelContainsSeparator, validateLabel("foo."));
    try std.testing.expectError(error.LabelContainsSeparator, validateLabel(".eth"));
}
