const std = @import("std");

/// Validates that a string is valid UTF-8 and contains no control characters
/// (except tab, newline, and carriage return which are allowed)
/// Returns error if validation fails
pub fn validateString(input: []const u8) !void {
    // First check if it's valid UTF-8
    if (!std.unicode.utf8ValidateSlice(input)) {
        return error.InvalidUTF8;
    }

    // Check for disallowed control characters
    // Allow: tab (0x09), newline (0x0A), carriage return (0x0D)
    // Disallow: other control characters (0x00-0x08, 0x0B-0x0C, 0x0E-0x1F, 0x7F)
    for (input) |byte| {
        switch (byte) {
            // Null byte - explicitly disallowed
            0x00 => return error.NullByteNotAllowed,
            // Other control characters (except tab, newline, carriage return)
            0x01...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F => return error.ControlCharacterNotAllowed,
            else => {},
        }
    }
}

/// Validates an ENS name/label string
/// More strict than validateString - disallows all control characters including newlines
pub fn validateName(name: []const u8) !void {
    // First check if it's valid UTF-8
    if (!std.unicode.utf8ValidateSlice(name)) {
        return error.InvalidUTF8;
    }

    // Names should not contain ANY control characters
    for (name) |byte| {
        switch (byte) {
            0x00...0x1F, 0x7F => return error.ControlCharacterInName,
            else => {},
        }
    }
}

test "validateString accepts valid UTF-8" {
    try validateString("hello world");
    try validateString("hello 世界");
    try validateString("emoji: 🚀");
}

test "validateString rejects invalid UTF-8" {
    const invalid_utf8 = [_]u8{ 0xFF, 0xFE };
    try std.testing.expectError(error.InvalidUTF8, validateString(&invalid_utf8));
}

test "validateString allows tab, newline, carriage return" {
    try validateString("hello\tworld");
    try validateString("hello\nworld");
    try validateString("hello\rworld");
}

test "validateString rejects null bytes" {
    const with_null = [_]u8{ 'h', 'e', 'l', 'l', 'o', 0x00, 'w', 'o', 'r', 'l', 'd' };
    try std.testing.expectError(error.NullByteNotAllowed, validateString(&with_null));
}

test "validateString rejects other control characters" {
    const with_control = [_]u8{ 'h', 'e', 'l', 'l', 'o', 0x01, 'w', 'o', 'r', 'l', 'd' };
    try std.testing.expectError(error.ControlCharacterNotAllowed, validateString(&with_control));
}

test "validateName rejects newlines" {
    try std.testing.expectError(error.ControlCharacterInName, validateName("hello\nworld"));
}

test "validateName accepts valid names" {
    try validateName("example");
    try validateName("hello-world");
    try validateName("test123");
}

pub const REPLACEMENT_CHAR = "\xEF\xBF\xBD";

/// Return `input` as valid UTF-8: every byte that does not start a well-formed
/// sequence becomes U+FFFD. On-chain strings (labels, text keys/values, DNS
/// names) are arbitrary bytes and the contracts hash them as such, so the
/// indexer keeps the raw bytes for every hash preimage and lookup; this is
/// applied only where a database column requires valid UTF-8 (the text bind
/// layer), identically on both backends. Valid input is returned as-is (not
/// copied); the caller owns the result only when `result.ptr != input.ptr`.
pub fn sanitizeUtf8(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(input)) return input;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, input.len + 8);
    var i: usize = 0;
    while (i < input.len) {
        const len = std.unicode.utf8ByteSequenceLength(input[i]) catch {
            try out.appendSlice(allocator, REPLACEMENT_CHAR);
            i += 1;
            continue;
        };
        if (i + len <= input.len and std.unicode.utf8ValidateSlice(input[i .. i + len])) {
            try out.appendSlice(allocator, input[i .. i + len]);
            i += len;
        } else {
            try out.appendSlice(allocator, REPLACEMENT_CHAR);
            i += 1;
        }
    }
    return try out.toOwnedSlice(allocator);
}

test "sanitizeUtf8 leaves valid input untouched and replaces invalid bytes" {
    const a = std.testing.allocator;
    const ok = "vitalik.eth \u{1F600} caf\u{e9}";
    const same = try sanitizeUtf8(a, ok);
    try std.testing.expect(same.ptr == ok.ptr);

    // The staging poison: a lone 0xEF lead byte followed by ASCII.
    const poison = "key\xEF\x58\x17tail";
    const fixed = try sanitizeUtf8(a, poison);
    defer a.free(fixed);
    try std.testing.expect(std.unicode.utf8ValidateSlice(fixed));
    try std.testing.expectEqualStrings("key\xEF\xBF\xBDX\x17tail", fixed);

    // Truncated multi-byte sequence at the end, overlong/continuation garbage.
    const trunc = try sanitizeUtf8(a, "ab\xE2\x82");
    defer a.free(trunc);
    try std.testing.expectEqualStrings("ab\xEF\xBF\xBD\xEF\xBF\xBD", trunc);
    const cont = try sanitizeUtf8(a, "\x80\xBFz");
    defer a.free(cont);
    try std.testing.expectEqualStrings("\xEF\xBF\xBD\xEF\xBF\xBDz", cont);
}
