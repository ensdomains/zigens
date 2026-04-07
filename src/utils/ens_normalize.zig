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
