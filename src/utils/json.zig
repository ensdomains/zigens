const std = @import("std");

/// Escapes a string for safe inclusion in JSON (RFC 8259 compliant)
/// Properly escapes ALL control characters (0x00-0x1F, 0x7F), quotes, backslashes, and handles Unicode correctly
/// This implementation follows the same escaping rules as std.json.Stringify but optimized for string-only escaping
pub fn escapeString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = std.ArrayList(u8){};
    errdefer result.deinit(allocator);

    // RFC 8259 compliant escaping
    for (input) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            '\x08' => try result.appendSlice(allocator, "\\b"),  // backspace
            '\x0C' => try result.appendSlice(allocator, "\\f"),  // form feed
            // All other control characters (0x00-0x1F except the ones above, plus 0x7F) must be escaped as \uXXXX
            0x00...0x07, 0x0B, 0x0E...0x1F, 0x7F => {
                try result.writer(allocator).print("\\u{x:0>4}", .{c});
            },
            else => try result.append(allocator, c),
        }
    }

    return result.toOwnedSlice(allocator);
}

test "escapeString handles quotes" {
    const allocator = std.testing.allocator;
    const input = "hello\"world";
    const output = try escapeString(allocator, input);
    defer allocator.free(output);
    try std.testing.expectEqualStrings("hello\\\"world", output);
}

test "escapeString handles backslashes" {
    const allocator = std.testing.allocator;
    const input = "path\\to\\file";
    const output = try escapeString(allocator, input);
    defer allocator.free(output);
    try std.testing.expectEqualStrings("path\\\\to\\\\file", output);
}

test "escapeString handles newlines" {
    const allocator = std.testing.allocator;
    const input = "line1\nline2";
    const output = try escapeString(allocator, input);
    defer allocator.free(output);
    try std.testing.expectEqualStrings("line1\\nline2", output);
}

test "escapeString handles control characters" {
    const allocator = std.testing.allocator;
    const input = "tab\there";
    const output = try escapeString(allocator, input);
    defer allocator.free(output);
    try std.testing.expectEqualStrings("tab\\there", output);
}

test "escapeString handles unicode" {
    const allocator = std.testing.allocator;
    const input = "hello 世界";
    const output = try escapeString(allocator, input);
    defer allocator.free(output);
    // Unicode should pass through unchanged
    try std.testing.expectEqualStrings("hello 世界", output);
}
