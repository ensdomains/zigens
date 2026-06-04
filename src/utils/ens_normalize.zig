/// ENS Name Normalization Utility
///
/// Wraps the z_ens_normalize library to provide ENSIP-15 compliant
/// name normalization. Names that fail normalization are flagged
/// as non-normalized but still stored.
const std = @import("std");
const ens = @import("ens_normalize");

/// Result of attempting to normalize an ENS name
pub const NormalizeResult = struct {
    /// The normalized name (null if normalization failed)
    normalized: ?[]const u8,
    /// Whether the name is valid according to ENSIP-15
    is_valid: bool,
    /// Error message if normalization failed
    error_message: ?[]const u8,

    pub fn deinit(self: *NormalizeResult, allocator: std.mem.Allocator) void {
        if (self.normalized) |n| allocator.free(n);
        if (self.error_message) |e| allocator.free(e);
    }
};

/// Attempt to normalize an ENS name according to ENSIP-15
/// Returns the normalized name if valid, or marks as invalid with error
pub fn normalizeName(allocator: std.mem.Allocator, name: []const u8) NormalizeResult {
    const normalized = ens.normalize(allocator, name) catch |err| {
        // Normalization failed - name is not ENSIP-15 compliant
        const error_msg = switch (err) {
            error.OutOfMemory => allocator.dupe(u8, "out of memory") catch null,
            else => allocator.dupe(u8, "normalization failed") catch null,
        };
        return NormalizeResult{
            .normalized = null,
            .is_valid = false,
            .error_message = error_msg,
        };
    };

    return NormalizeResult{
        .normalized = normalized,
        .is_valid = true,
        .error_message = null,
    };
}

/// Normalize a single label (not a full name)
pub fn normalizeLabel(allocator: std.mem.Allocator, label: []const u8) NormalizeResult {
    // For labels, we don't want to split on dots
    // A dot in a label is invalid
    if (std.mem.indexOfScalar(u8, label, '.') != null) {
        return NormalizeResult{
            .normalized = null,
            .is_valid = false,
            .error_message = allocator.dupe(u8, "label contains dot") catch null,
        };
    }

    return normalizeName(allocator, label);
}

/// Check if a name is normalized without allocating the result
pub fn isNormalized(allocator: std.mem.Allocator, name: []const u8) bool {
    const normalized = ens.normalize(allocator, name) catch return false;
    defer allocator.free(normalized);
    return std.mem.eql(u8, name, normalized);
}

/// Normalization status for the indexer's `names.is_normalized` column. False when
/// the name is null/empty or its label is unknown (`[0x..]` placeholder), else the
/// ENSIP-15 `name == normalize(name)` check. The single helper every ingest path uses.
pub fn nameIsNormalized(allocator: std.mem.Allocator, name: ?[]const u8) bool {
    const n = name orelse return false;
    if (n.len == 0) return false;
    // An unhealed labelhash placeholder ("[0x…]") is not a normalized human name.
    if (std.mem.indexOfScalar(u8, n, '[') != null) return false;
    return isNormalized(allocator, n);
}

/// Check if a label contains invalid characters (quick check)
pub fn hasInvalidLabelChars(label: []const u8) bool {
    // Quick check for obviously invalid characters
    for (label) |c| {
        // Dot is not allowed in labels
        if (c == '.') return true;
        // Null byte is not allowed
        if (c == 0) return true;
    }
    return false;
}

// Tests
test "normalize simple name" {
    const allocator = std.testing.allocator;
    var result = normalizeName(allocator, "Nick.ETH");
    defer result.deinit(allocator);

    try std.testing.expect(result.is_valid);
    try std.testing.expectEqualStrings("nick.eth", result.normalized.?);
}

test "normalize name with dot in label" {
    const allocator = std.testing.allocator;
    var result = normalizeLabel(allocator, "fotobank.eth");
    defer result.deinit(allocator);

    try std.testing.expect(!result.is_valid);
    try std.testing.expect(result.normalized == null);
}

test "check is normalized" {
    const allocator = std.testing.allocator;

    try std.testing.expect(isNormalized(allocator, "nick.eth"));
    try std.testing.expect(!isNormalized(allocator, "Nick.ETH"));
}

test "has invalid label chars" {
    try std.testing.expect(hasInvalidLabelChars("fotobank.eth"));
    try std.testing.expect(!hasInvalidLabelChars("fotobank"));
    try std.testing.expect(!hasInvalidLabelChars("vitalik"));
}

test "nameIsNormalized: the indexer is_normalized column value" {
    const a = std.testing.allocator;
    // Normalized human names.
    try std.testing.expect(nameIsNormalized(a, "nick.eth"));
    try std.testing.expect(nameIsNormalized(a, "alice.eth"));
    // Non-normalized: uppercase / mixed case.
    try std.testing.expect(!nameIsNormalized(a, "Nick.eth"));
    try std.testing.expect(!nameIsNormalized(a, "VITALIK"));
    // Unknown / placeholder / empty: never normalized.
    try std.testing.expect(!nameIsNormalized(a, null));
    try std.testing.expect(!nameIsNormalized(a, ""));
    try std.testing.expect(!nameIsNormalized(a, "[af2caa1c…].eth"));
}

// ENSIP-15 conformance vectors (#18). Curated from the official adraffy/ens-normalize.js
// validation suite (v2025-09-14, CLDR 47): emoji/ZWJ/ZWNJ sequences, fullwidth + combining
// (UTS-46) mappings, and ~870 validation-error rules. The FULL 29,643-case suite passes the
// vendored z_ens_normalize lib with 0 failures (measured 2026-06-02) — see docs; this committed
// subset is the CI regression guard. Refetch the full suite from the URL in docs to re-verify.
test "ENSIP-15 normalization vectors (UTS-46 / emoji / ZWJ)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, a, @embedFile("ens_normalize_vectors.json"), .{});
    var pass: usize = 0;
    var fails: usize = 0;
    for (parsed.value.array.items) |item| {
        const obj = item.object;
        const name = obj.get("name").?.string;
        const is_err = if (obj.get("error")) |e| (e == .bool and e.bool) else false;
        if (is_err) {
            if (ens.normalize(a, name)) |_| {
                std.debug.print("ENSIP-15: expected ERROR but normalized: <{s}>\n", .{name});
                fails += 1;
            } else |_| pass += 1;
        } else {
            const want = obj.get("norm").?.string;
            if (ens.normalize(a, name)) |got| {
                if (std.mem.eql(u8, got, want)) pass += 1 else {
                    std.debug.print("ENSIP-15: <{s}> want <{s}> got <{s}>\n", .{ name, want, got });
                    fails += 1;
                }
            } else |_| {
                std.debug.print("ENSIP-15: <{s}> expected <{s}> but errored\n", .{ name, want });
                fails += 1;
            }
        }
    }
    std.debug.print("✓ ENSIP-15 vectors: {d}/{d} passed (emoji/ZWJ/ZWNJ/fullwidth/combining + validation rules)\n", .{ pass, pass + fails });
    try std.testing.expectEqual(@as(usize, 0), fails);
}
