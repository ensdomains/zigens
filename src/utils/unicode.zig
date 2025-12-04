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
