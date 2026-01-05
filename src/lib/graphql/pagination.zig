/// Generic cursor-based pagination implementation
/// Follows GraphQL Cursor Connections Specification (Relay spec)
/// https://relay.dev/graphql/connections.htm
const std = @import("std");
const base64 = std.base64;

/// Cursor type - opaque string that encodes pagination state
pub const Cursor = []const u8;

/// Page direction for pagination
pub const Direction = enum {
    forward, // Using first/after
    backward, // Using last/before
};

/// Pagination parameters extracted from GraphQL query
pub const PaginationParams = struct {
    direction: Direction,
    limit: usize,
    cursor: ?Cursor,

    /// Parse pagination arguments from GraphQL query
    /// Validates that only compatible arguments are provided
    pub fn parse(
        first: ?i64,
        after: ?Cursor,
        last: ?i64,
        before: ?Cursor,
        default_limit: usize,
        max_limit: usize,
    ) !PaginationParams {
        // Validate argument compatibility
        if (first != null and last != null) {
            return error.InvalidPaginationArgs; // Cannot use both first and last
        }
        if (after != null and before != null) {
            return error.InvalidPaginationArgs; // Cannot use both after and before
        }
        if (first != null and before != null) {
            return error.InvalidPaginationArgs; // first with before is invalid
        }
        if (last != null and after != null) {
            return error.InvalidPaginationArgs; // last with after is invalid
        }

        // Determine direction and limit
        const direction: Direction = if (last != null) .backward else .forward;
        const raw_limit = if (first) |f| f else if (last) |l| l else @as(i64, @intCast(default_limit));

        // Validate and cap limit
        if (raw_limit < 0) {
            return error.NegativeLimit;
        }
        const limit = @min(@as(usize, @intCast(raw_limit)), max_limit);

        return PaginationParams{
            .direction = direction,
            .limit = limit,
            .cursor = if (after) |a| a else before,
        };
    }
};

/// Generic edge type for pagination
pub fn Edge(comptime T: type) type {
    return struct {
        cursor: Cursor,
        node: T,
    };
}

/// PageInfo type containing pagination metadata
pub const PageInfo = struct {
    has_next_page: bool,
    has_previous_page: bool,
    start_cursor: ?Cursor,
    end_cursor: ?Cursor,
};

/// Generic connection type for paginated results
pub fn Connection(comptime T: type) type {
    return struct {
        edges: []Edge(T),
        page_info: PageInfo,
        total_count: ?usize,

        pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
            for (self.edges) |edge| {
                allocator.free(edge.cursor);
            }
            allocator.free(self.edges);
            if (self.page_info.start_cursor) |cursor| {
                allocator.free(cursor);
            }
            if (self.page_info.end_cursor) |cursor| {
                allocator.free(cursor);
            }
        }
    };
}

/// Cursor encoder/decoder for different ID types
pub const CursorCodec = struct {
    /// Encode a cursor from an ID (integer)
    pub fn encodeInt(allocator: std.mem.Allocator, id: i64) !Cursor {
        // Format: base64("int:<id>")
        const plain = try std.fmt.allocPrint(allocator, "int:{d}", .{id});
        defer allocator.free(plain);

        const encoder = base64.standard.Encoder;
        const encoded_len = encoder.calcSize(plain.len);
        const encoded = try allocator.alloc(u8, encoded_len);
        errdefer allocator.free(encoded);

        return encoder.encode(encoded, plain);
    }

    /// Encode a cursor from an ID (string)
    pub fn encodeString(allocator: std.mem.Allocator, id: []const u8) !Cursor {
        // Format: base64("str:<id>")
        const plain = try std.fmt.allocPrint(allocator, "str:{s}", .{id});
        defer allocator.free(plain);

        const encoder = base64.standard.Encoder;
        const encoded_len = encoder.calcSize(plain.len);
        const encoded = try allocator.alloc(u8, encoded_len);
        errdefer allocator.free(encoded);

        return encoder.encode(encoded, plain);
    }

    /// Decode an integer cursor
    pub fn decodeInt(allocator: std.mem.Allocator, cursor: Cursor) !i64 {
        const decoder = base64.standard.Decoder;
        const decoded_len = try decoder.calcSizeForSlice(cursor);
        const decoded = try allocator.alloc(u8, decoded_len);
        defer allocator.free(decoded);

        try decoder.decode(decoded, cursor);

        // Expected format: "int:<id>"
        if (!std.mem.startsWith(u8, decoded, "int:")) {
            return error.InvalidCursor;
        }

        const id_str = decoded[4..];
        return std.fmt.parseInt(i64, id_str, 10) catch error.InvalidCursor;
    }

    /// Decode a string cursor
    pub fn decodeString(allocator: std.mem.Allocator, cursor: Cursor) ![]const u8 {
        const decoder = base64.standard.Decoder;
        const decoded_len = try decoder.calcSizeForSlice(cursor);
        const decoded = try allocator.alloc(u8, decoded_len);
        errdefer allocator.free(decoded);

        try decoder.decode(decoded, cursor);

        // Expected format: "str:<id>"
        if (!std.mem.startsWith(u8, decoded, "str:")) {
            allocator.free(decoded);
            return error.InvalidCursor;
        }

        // Return the ID part, caller owns memory
        const id_str = decoded[4..];
        const result = try allocator.dupe(u8, id_str);
        allocator.free(decoded);
        return result;
    }
};

/// Build a connection from a slice of items with integer IDs
pub fn buildConnectionInt(
    comptime T: type,
    allocator: std.mem.Allocator,
    items: []const T,
    params: PaginationParams,
    /// Extract ID from item (for cursor generation)
    getId: fn (T) i64,
    /// Optional total count
    total_count: ?usize,
) !Connection(T) {
    if (items.len == 0) {
        return Connection(T){
            .edges = &[_]Edge(T){},
            .page_info = PageInfo{
                .has_next_page = false,
                .has_previous_page = params.cursor != null,
                .start_cursor = null,
                .end_cursor = null,
            },
            .total_count = total_count,
        };
    }

    // Build edges with cursors
    const edges = try allocator.alloc(Edge(T), items.len);
    errdefer {
        for (edges) |edge| {
            allocator.free(edge.cursor);
        }
        allocator.free(edges);
    }

    for (items, 0..) |item, i| {
        const id = getId(item);
        edges[i] = Edge(T){
            .cursor = try CursorCodec.encodeInt(allocator, id),
            .node = item,
        };
    }

    // Determine if there are more pages
    // If we got exactly limit items, there might be more
    const has_more = items.len == params.limit;

    const page_info = PageInfo{
        .has_next_page = if (params.direction == .forward) has_more else false,
        .has_previous_page = if (params.direction == .backward) has_more else params.cursor != null,
        .start_cursor = if (edges.len > 0) try allocator.dupe(u8, edges[0].cursor) else null,
        .end_cursor = if (edges.len > 0) try allocator.dupe(u8, edges[edges.len - 1].cursor) else null,
    };

    return Connection(T){
        .edges = edges,
        .page_info = page_info,
        .total_count = total_count,
    };
}

/// Build a connection from a slice of items with string IDs
pub fn buildConnectionString(
    comptime T: type,
    allocator: std.mem.Allocator,
    items: []const T,
    params: PaginationParams,
    /// Extract ID from item (for cursor generation)
    getId: fn (T) []const u8,
    /// Optional total count
    total_count: ?usize,
) !Connection(T) {
    if (items.len == 0) {
        return Connection(T){
            .edges = &[_]Edge(T){},
            .page_info = PageInfo{
                .has_next_page = false,
                .has_previous_page = params.cursor != null,
                .start_cursor = null,
                .end_cursor = null,
            },
            .total_count = total_count,
        };
    }

    // Build edges with cursors
    const edges = try allocator.alloc(Edge(T), items.len);
    errdefer {
        for (edges) |edge| {
            allocator.free(edge.cursor);
        }
        allocator.free(edges);
    }

    for (items, 0..) |item, i| {
        const id = getId(item);
        edges[i] = Edge(T){
            .cursor = try CursorCodec.encodeString(allocator, id),
            .node = item,
        };
    }

    // Determine if there are more pages
    const has_more = items.len == params.limit;

    const page_info = PageInfo{
        .has_next_page = if (params.direction == .forward) has_more else false,
        .has_previous_page = if (params.direction == .backward) has_more else params.cursor != null,
        .start_cursor = if (edges.len > 0) try allocator.dupe(u8, edges[0].cursor) else null,
        .end_cursor = if (edges.len > 0) try allocator.dupe(u8, edges[edges.len - 1].cursor) else null,
    };

    return Connection(T){
        .edges = edges,
        .page_info = page_info,
        .total_count = total_count,
    };
}

// ============================================================================
// TESTS
// ============================================================================

test "CursorCodec.encodeInt and decodeInt" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cursor = try CursorCodec.encodeInt(allocator, 42);
    defer allocator.free(cursor);

    const decoded = try CursorCodec.decodeInt(allocator, cursor);
    try testing.expectEqual(@as(i64, 42), decoded);
}

test "CursorCodec.encodeString and decodeString" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cursor = try CursorCodec.encodeString(allocator, "test-id-123");
    defer allocator.free(cursor);

    const decoded = try CursorCodec.decodeString(allocator, cursor);
    defer allocator.free(decoded);

    try testing.expectEqualStrings("test-id-123", decoded);
}

test "PaginationParams.parse - forward pagination" {
    const params = try PaginationParams.parse(10, null, null, null, 100, 1000);
    try std.testing.expectEqual(Direction.forward, params.direction);
    try std.testing.expectEqual(@as(usize, 10), params.limit);
    try std.testing.expectEqual(@as(?Cursor, null), params.cursor);
}

test "PaginationParams.parse - max limit cap" {
    const params = try PaginationParams.parse(5000, null, null, null, 100, 1000);
    try std.testing.expectEqual(@as(usize, 1000), params.limit); // Capped at max
}

test "PaginationParams.parse - invalid args" {
    const result = PaginationParams.parse(10, null, 10, null, 100, 1000);
    try std.testing.expectError(error.InvalidPaginationArgs, result);
}
