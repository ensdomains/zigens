/// JSON string escaping shared by the GraphQL response writers.
const std = @import("std");

/// Escape a string for JSON output (RFC 8259 compliant)
/// Properly escapes ALL control characters (0x00-0x1F, 0x7F), quotes, backslashes
pub fn escapeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (input) |char| {
        switch (char) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            '\x08' => try result.appendSlice(allocator, "\\b"), // backspace
            '\x0C' => try result.appendSlice(allocator, "\\f"), // form feed
            // All other control characters (0x00-0x1F except the ones above, plus 0x7F) must be escaped as \uXXXX
            0x00...0x07, 0x0B, 0x0E...0x1F, 0x7F => {
                try result.print(allocator, "\\u{x:0>4}", .{char});
            },
            else => try result.append(allocator, char),
        }
    }

    return result.toOwnedSlice(allocator);
}
