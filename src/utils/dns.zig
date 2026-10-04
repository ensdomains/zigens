/// DNS wire format decoder for ENS names.
///
/// DNS-encoded names use length-prefixed labels: [len][label_bytes][len][label_bytes]...[0x00]
/// Example: "vitalik.eth" → \x07vitalik\x03eth\x00
///
/// Used by NameWrapper's NameWrapped event which emits the full name in this format.
const std = @import("std");

/// Encode a dot-separated name into DNS wire format: [len][label]...[0x00].
/// Example: "vitalik.eth" → \x07vitalik\x03eth\x00. The empty name encodes to the
/// single root terminator "\x00" (ENSIP-10 name for the root). This is the `name`
/// argument for the Universal Resolver's `resolve(bytes name, bytes data)`.
///
/// The caller is responsible for passing an ALREADY-normalized name (ENSIP-15) —
/// this is a pure byte-layout encoder, not a normalizer. Each label must be
/// 1..=255 bytes; an empty interior label (e.g. "a..b") or an over-long label is
/// rejected. Caller owns the returned slice.
pub fn encodeDNSName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    if (name.len != 0) {
        var it = std.mem.splitScalar(u8, name, '.');
        while (it.next()) |label| {
            if (label.len == 0 or label.len > 255) return error.InvalidLabel;
            try out.append(allocator, @intCast(label.len));
            try out.appendSlice(allocator, label);
        }
    }
    try out.append(allocator, 0); // root terminator
    return out.toOwnedSlice(allocator);
}

/// Decode a DNS wire-format encoded name into its component labels.
/// Returns a slice of labels (e.g., ["vitalik", "eth"]).
/// Caller owns the returned slice and each label string (all allocated from `allocator`).
pub fn decodeDNSName(allocator: std.mem.Allocator, data: []const u8) ![][]const u8 {
    var labels: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (labels.items) |l| allocator.free(l);
        labels.deinit(allocator);
    }

    var offset: usize = 0;
    while (offset < data.len) {
        const len = data[offset];
        offset += 1;

        if (len == 0) break; // Root label terminator

        if (offset + len > data.len) return error.InvalidDNSEncoding;

        const label = data[offset .. offset + len];
        try labels.append(allocator, try allocator.dupe(u8, label));
        offset += len;
    }

    return labels.toOwnedSlice(allocator);
}

/// Decode a DNS wire-format name and return the full dot-separated name string.
/// Example: \x07vitalik\x03eth\x00 → "vitalik.eth"
/// Caller owns the returned string.
/// `null` means THE ROOT NAME and nothing else. A malformed encoding propagates
/// `error.InvalidDNSEncoding`.
///
/// These were folded together — `decodeDNSName` already distinguishes them
/// (it errors on a truncated label and returns zero labels for `0x00`) and this
/// wrapper threw that away with `catch return null`. A caller then could not
/// tell "the default record" from "garbage", so `handleNamedResourceKind`
/// discarded three legitimate root-name records as undecodable while
/// `handleLinked`, reading the same null, correctly treated it as the default
/// binding. Keeping the two outcomes distinct is what lets each caller choose,
/// and `utils.isMalformedEventError` lists the error so a genuinely malformed
/// payload skips one event with its coordinates instead of aborting the batch.
pub fn decodeDNSNameToString(allocator: std.mem.Allocator, data: []const u8) !?[]const u8 {
    const labels = try decodeDNSName(allocator, data);
    defer {
        for (labels) |l| allocator.free(l);
        allocator.free(labels);
    }

    if (labels.len == 0) return null;

    // Calculate total length
    var total_len: usize = 0;
    for (labels, 0..) |l, i| {
        total_len += l.len;
        if (i < labels.len - 1) total_len += 1; // dot separator
    }

    const result = try allocator.alloc(u8, total_len);
    var pos: usize = 0;
    for (labels, 0..) |l, i| {
        @memcpy(result[pos .. pos + l.len], l);
        pos += l.len;
        if (i < labels.len - 1) {
            result[pos] = '.';
            pos += 1;
        }
    }

    return result;
}

/// Decode a DNS wire-format name and return just the first label.
/// Example: \x07vitalik\x03eth\x00 → "vitalik"
/// Caller owns the returned string.
pub fn decodeDNSFirstLabel(allocator: std.mem.Allocator, data: []const u8) !?[]const u8 {
    if (data.len < 2) return null; // Need at least length byte + 1 char

    const len = data[0];
    if (len == 0) return null;
    if (1 + len > data.len) return null;

    return try allocator.dupe(u8, data[1 .. 1 + len]);
}

// ============================================================================
// TESTS
// ============================================================================

test "decode simple DNS name" {
    const allocator = std.testing.allocator;

    // "vitalik.eth" → \x07vitalik\x03eth\x00
    const data = "\x07vitalik\x03eth\x00";
    const labels = try decodeDNSName(allocator, data);
    defer {
        for (labels) |l| allocator.free(l);
        allocator.free(labels);
    }

    try std.testing.expectEqual(@as(usize, 2), labels.len);
    try std.testing.expectEqualStrings("vitalik", labels[0]);
    try std.testing.expectEqualStrings("eth", labels[1]);
}

test "decode DNS name to string" {
    const allocator = std.testing.allocator;

    const data = "\x07vitalik\x03eth\x00";
    const name = try decodeDNSNameToString(allocator, data);
    defer if (name) |n| allocator.free(n);

    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("vitalik.eth", name.?);
}

test "decode subdomain DNS name" {
    const allocator = std.testing.allocator;

    // "sub.vitalik.eth" → \x03sub\x07vitalik\x03eth\x00
    const data = "\x03sub\x07vitalik\x03eth\x00";
    const name = try decodeDNSNameToString(allocator, data);
    defer if (name) |n| allocator.free(n);

    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("sub.vitalik.eth", name.?);
}

test "decode first label" {
    const allocator = std.testing.allocator;

    const data = "\x07vitalik\x03eth\x00";
    const label = try decodeDNSFirstLabel(allocator, data);
    defer if (label) |l| allocator.free(l);

    try std.testing.expect(label != null);
    try std.testing.expectEqualStrings("vitalik", label.?);
}

test "root name decodes to null; a malformed encoding errors instead" {
    const allocator = std.testing.allocator;

    // `0x00` is zero labels — the root — and must be reported as such.
    try std.testing.expectEqual(@as(?[]const u8, null), try decodeDNSNameToString(allocator, "\x00"));
    try std.testing.expectEqual(@as(?[]const u8, null), try decodeDNSNameToString(allocator, ""));

    // A label length that runs past the buffer is malformed, and must NOT be
    // reported as the root: that conflation dropped real records.
    try std.testing.expectError(error.InvalidDNSEncoding, decodeDNSNameToString(allocator, "\x05ab"));
}

test "decodeDNSNameToString keeps the raw label bytes: DNS labels are not required to be UTF-8" {
    const allocator = std.testing.allocator;
    const wire = "\x04k\xEFX\x17\x03eth\x00";
    const name = (try decodeDNSNameToString(allocator, wire)) orelse return error.TestUnexpectedResult;
    defer allocator.free(name);
    try std.testing.expectEqualSlices(u8, "k\xEFX\x17.eth", name);
    const label = (try decodeDNSFirstLabel(allocator, wire)) orelse return error.TestUnexpectedResult;
    defer allocator.free(label);
    try std.testing.expectEqualSlices(u8, "k\xEFX\x17", label);
}
