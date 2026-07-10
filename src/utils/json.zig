const std = @import("std");

/// Escapes a string for safe inclusion in JSON (RFC 8259 compliant)
/// Properly escapes ALL control characters (0x00-0x1F, 0x7F), quotes, backslashes, and handles Unicode correctly
/// This implementation follows the same escaping rules as std.json.Stringify but optimized for string-only escaping
pub fn escapeString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    // RFC 8259 compliant escaping
    for (input) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            '\x08' => try result.appendSlice(allocator, "\\b"), // backspace
            '\x0C' => try result.appendSlice(allocator, "\\f"), // form feed
            // All other control characters (0x00-0x1F except the ones above, plus 0x7F) must be escaped as \uXXXX
            0x00...0x07, 0x0B, 0x0E...0x1F, 0x7F => {
                try result.print(allocator, "\\u{x:0>4}", .{c});
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

// ============================================================================
// TARGETED EXTRACTORS
// Used in resolver hot paths where a single field is needed from a flat JSON
// object — avoids the cost of building a full json.Value tree per row.
// Designed for ENS event.data blobs (flat objects, no nested arrays/objects).
// Returns null if the key is missing or the value type doesn't match.
// ============================================================================

/// Locate a top-level key's value-start position in a flat JSON object.
/// Guards against substring matches (e.g., "owner" inside "ownership") by
/// requiring the key to be preceded by `{` or `,` (with optional whitespace).
fn findKeyValueStart(data: []const u8, key: []const u8) ?usize {
    var search_from: usize = 0;
    while (search_from < data.len) {
        // Find the next "key" occurrence
        const quote_at = std.mem.indexOfPos(u8, data, search_from, key) orelse return null;
        if (quote_at == 0) {
            search_from = quote_at + key.len;
            continue;
        }
        // Must be inside quotes: data[quote_at-1] == '"' and data[quote_at+key.len] == '"'
        if (data[quote_at - 1] != '"') {
            search_from = quote_at + 1;
            continue;
        }
        if (quote_at + key.len >= data.len or data[quote_at + key.len] != '"') {
            search_from = quote_at + 1;
            continue;
        }
        // Must be a top-level key: scan backward past the opening quote and any
        // whitespace; must hit `{` or `,`.
        var prev = quote_at -| 2; // before the opening "
        while (prev > 0 and (data[prev] == ' ' or data[prev] == '\t' or data[prev] == '\n' or data[prev] == '\r')) prev -|= 1;
        if (data[prev] != '{' and data[prev] != ',') {
            search_from = quote_at + 1;
            continue;
        }
        // Must be followed by `:` (with optional whitespace)
        var pos = quote_at + key.len + 1; // after the closing "
        while (pos < data.len and (data[pos] == ' ' or data[pos] == '\t')) pos += 1;
        if (pos >= data.len or data[pos] != ':') {
            search_from = quote_at + 1;
            continue;
        }
        pos += 1;
        while (pos < data.len and (data[pos] == ' ' or data[pos] == '\t')) pos += 1;
        return pos;
    }
    return null;
}

/// Extract a string value for a top-level key from a flat JSON object.
/// Returns a slice into `data` (no allocation). Handles `\"` and `\\` escapes
/// by returning null for now (callers fall back to full parse). For typical
/// ENS event.data (hex strings, unescaped), this is hit-rate ~100%.
pub fn extractStringField(data: []const u8, key: []const u8) ?[]const u8 {
    const value_start = findKeyValueStart(data, key) orelse return null;
    if (value_start >= data.len or data[value_start] != '"') return null;
    const start = value_start + 1;
    var pos = start;
    while (pos < data.len) : (pos += 1) {
        if (data[pos] == '\\') return null; // escape — let caller fall back
        if (data[pos] == '"') return data[start..pos];
    }
    return null;
}

/// Extract an integer value for a top-level key from a flat JSON object.
pub fn extractIntField(data: []const u8, key: []const u8) ?i64 {
    const value_start = findKeyValueStart(data, key) orelse return null;
    var pos = value_start;
    if (pos < data.len and data[pos] == '-') pos += 1;
    const num_start = pos;
    while (pos < data.len and std.ascii.isDigit(data[pos])) pos += 1;
    if (pos == num_start) return null;
    return std.fmt.parseInt(i64, data[value_start..pos], 10) catch null;
}

/// Extract a numeric value as a borrowed digit slice (handles u256 range).
/// Returns the raw decimal digits (with optional leading `-`) — works whether
/// the source value is a JSON number or a quoted string containing digits.
/// Used by typed event-data accessors that need to surface large ints as
/// GraphQL strings without losing precision.
pub fn extractNumericStringField(data: []const u8, key: []const u8) ?[]const u8 {
    const value_start = findKeyValueStart(data, key) orelse return null;
    if (value_start >= data.len) return null;
    var pos = value_start;
    // Skip an optional opening quote (when the source stored the number as a string).
    if (data[pos] == '"') pos += 1;
    const start = pos;
    if (pos < data.len and data[pos] == '-') pos += 1;
    while (pos < data.len and std.ascii.isDigit(data[pos])) pos += 1;
    if (pos == start) return null;
    return data[start..pos];
}

test "extractStringField finds top-level keys, ignores substrings" {
    const data = "{\"owner\":\"0xabc\",\"ownership\":\"x\",\"foo\":\"bar\"}";
    try std.testing.expectEqualStrings("0xabc", extractStringField(data, "owner").?);
    try std.testing.expectEqualStrings("x", extractStringField(data, "ownership").?);
    try std.testing.expectEqualStrings("bar", extractStringField(data, "foo").?);
    try std.testing.expect(extractStringField(data, "missing") == null);
}

test "extractIntField parses positive and negative ints" {
    const data = "{\"duration\":31536000,\"count\":-5,\"label\":\"hello\"}";
    try std.testing.expectEqual(@as(?i64, 31536000), extractIntField(data, "duration"));
    try std.testing.expectEqual(@as(?i64, -5), extractIntField(data, "count"));
    try std.testing.expect(extractIntField(data, "label") == null); // string, not int
}

test "extractStringField with whitespace" {
    const data = "{ \"owner\" : \"0xdef\" , \"x\" : 1 }";
    try std.testing.expectEqualStrings("0xdef", extractStringField(data, "owner").?);
}

test "extractStringField bails on escapes" {
    const data = "{\"name\":\"hello\\\"world\"}";
    // Has an escape — extractor returns null so caller falls back to full parse.
    try std.testing.expect(extractStringField(data, "name") == null);
}
