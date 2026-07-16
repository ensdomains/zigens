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
        const explicit_limit: ?i64 = if (first) |f| f else last;
        const raw_limit = explicit_limit orelse @as(i64, @intCast(default_limit));

        // Validate and cap limit. If the caller explicitly asked for more than max_limit,
        // surface that as an error rather than silently truncating — silent truncation
        // hides query intent and produces deceptively-incomplete pages.
        if (raw_limit < 0) {
            return error.NegativeLimit;
        }
        if (explicit_limit) |e| {
            if (@as(usize, @intCast(e)) > max_limit) return error.LimitExceeded;
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

    /// Decoded keyset cursor: the sort-field discriminator, an optional cached
    /// totalCount snapshot, and the last row's (sort_value, namehash). Slices borrow
    /// the decode buffer; see decodeKeyset.
    pub const Keyset = struct {
        field: u8,
        /// Fingerprint of the active filter set + order direction. A cursor is only a
        /// valid anchor for a request whose filters produce the same fingerprint;
        /// reusing it against a changed `where` must fall through to a fresh page.
        filter_hash: u64,
        total_count: ?usize,
        sort_value: []const u8,
        namehash: []const u8,
        buf: []const u8, // backing allocation; free via deinit
        pub fn deinit(self: Keyset, allocator: std.mem.Allocator) void {
            allocator.free(self.buf);
        }
    };

    /// Encode a keyset cursor: base64 of
    /// "kf\n<field>\n<filter_hash>\n<count>\n<namehash>\n<sort_value>". `filter_hash` is a
    /// hex fingerprint of the active filter set + order direction (reject on mismatch);
    /// `count` is the totalCount snapshot (empty when unknown); `namehash` is 0x-hex (no
    /// '\n'); `sort_value` is placed last so it may contain any bytes. `field` is an opaque
    /// sort-field discriminator the caller assigns. The "kf" magic distinguishes this from
    /// the older filterless "ks" format, which now decodes as InvalidCursor (→ fresh page).
    pub fn encodeKeyset(allocator: std.mem.Allocator, field: u8, filter_hash: u64, total_count: ?usize, sort_value: []const u8, namehash: []const u8) !Cursor {
        const plain = if (total_count) |tc|
            try std.fmt.allocPrint(allocator, "kf\n{c}\n{x}\n{d}\n{s}\n{s}", .{ field, filter_hash, tc, namehash, sort_value })
        else
            try std.fmt.allocPrint(allocator, "kf\n{c}\n{x}\n\n{s}\n{s}", .{ field, filter_hash, namehash, sort_value });
        defer allocator.free(plain);
        const encoder = base64.standard.Encoder;
        const encoded = try allocator.alloc(u8, encoder.calcSize(plain.len));
        errdefer allocator.free(encoded);
        return encoder.encode(encoded, plain);
    }

    /// Decode a keyset cursor produced by encodeKeyset. Returns error.InvalidCursor
    /// for any non-keyset or malformed cursor (e.g. an old bare-namehash cursor).
    pub fn decodeKeyset(allocator: std.mem.Allocator, cursor: Cursor) !Keyset {
        const decoder = base64.standard.Decoder;
        const decoded_len = decoder.calcSizeForSlice(cursor) catch return error.InvalidCursor;
        const buf = try allocator.alloc(u8, decoded_len);
        errdefer allocator.free(buf);
        decoder.decode(buf, cursor) catch return error.InvalidCursor;

        if (!std.mem.startsWith(u8, buf, "kf\n") or buf.len < 6) return error.InvalidCursor;
        const field = buf[3];
        if (buf[4] != '\n') return error.InvalidCursor;
        // rest = "<filter_hash>\n<count>\n<namehash>\n<sort_value>"
        const rest = buf[5..];
        const nlf = std.mem.indexOfScalar(u8, rest, '\n') orelse return error.InvalidCursor;
        const filter_hash = std.fmt.parseInt(u64, rest[0..nlf], 16) catch return error.InvalidCursor;
        const rest_c = rest[nlf + 1 ..];
        const nl1 = std.mem.indexOfScalar(u8, rest_c, '\n') orelse return error.InvalidCursor;
        const count_str = rest_c[0..nl1];
        const rest2 = rest_c[nl1 + 1 ..];
        const nl2 = std.mem.indexOfScalar(u8, rest2, '\n') orelse return error.InvalidCursor;
        return .{
            .field = field,
            .filter_hash = filter_hash,
            .total_count = if (count_str.len > 0) (std.fmt.parseInt(usize, count_str, 10) catch null) else null,
            .namehash = rest2[0..nl2],
            .sort_value = rest2[nl2 + 1 ..],
            .buf = buf,
        };
    }
};

/// Build a connection from a slice of items with integer IDs.
///
/// `has_more` must be computed by the caller from the pre-trim fetch result
/// (typically: fetch limit+1 items, `has_more = fetched.len > limit`, then
/// pass the trimmed limit-sized slice here). Inferring has_more from `items.len ==
/// params.limit` after trimming is ambiguous — it can't distinguish "end of data"
/// from "more available" when the dataset size is an exact multiple of limit.
pub fn buildConnectionInt(
    comptime T: type,
    allocator: std.mem.Allocator,
    items: []const T,
    params: PaginationParams,
    has_more: bool,
    /// Extract ID from item (for cursor generation)
    getId: fn (T) i64,
    /// Optional total count
    total_count: ?usize,
) !Connection(T) {
    if (items.len == 0) {
        // No edges, but `has_more` and the cursor still inform whether there's data
        // beyond what was returned. With `first: 0` (or any limit that intentionally
        // returns zero edges), pageInfo must still surface the existence of more rows.
        return Connection(T){
            .edges = &[_]Edge(T){},
            .page_info = PageInfo{
                .has_next_page = if (params.direction == .forward) has_more else (params.cursor != null),
                .has_previous_page = if (params.direction == .backward) has_more else (params.cursor != null),
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

    const page_info = PageInfo{
        .has_next_page = if (params.direction == .forward) has_more else (params.cursor != null),
        .has_previous_page = if (params.direction == .backward) has_more else (params.cursor != null),
        .start_cursor = if (edges.len > 0) try allocator.dupe(u8, edges[0].cursor) else null,
        .end_cursor = if (edges.len > 0) try allocator.dupe(u8, edges[edges.len - 1].cursor) else null,
    };

    return Connection(T){
        .edges = edges,
        .page_info = page_info,
        .total_count = total_count,
    };
}

/// Build a connection from a slice of items with string IDs. See buildConnectionInt
/// for the has_more contract.
pub fn buildConnectionString(
    comptime T: type,
    allocator: std.mem.Allocator,
    items: []const T,
    params: PaginationParams,
    has_more: bool,
    /// Extract ID from item (for cursor generation)
    getId: fn (T) []const u8,
    /// Optional total count
    total_count: ?usize,
) !Connection(T) {
    if (items.len == 0) {
        // No edges, but `has_more` and the cursor still inform whether there's data
        // beyond what was returned. With `first: 0` (or any limit that intentionally
        // returns zero edges), pageInfo must still surface the existence of more rows.
        return Connection(T){
            .edges = &[_]Edge(T){},
            .page_info = PageInfo{
                .has_next_page = if (params.direction == .forward) has_more else (params.cursor != null),
                .has_previous_page = if (params.direction == .backward) has_more else (params.cursor != null),
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

    const page_info = PageInfo{
        .has_next_page = if (params.direction == .forward) has_more else (params.cursor != null),
        .has_previous_page = if (params.direction == .backward) has_more else (params.cursor != null),
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

test "CursorCodec keyset round-trips field/filter_hash/count/namehash/sort_value" {
    const a = std.testing.allocator;
    const cur = try CursorCodec.encodeKeyset(a, 'n', 0xDEADBEEFCAFE, 42, "value\nwith\nnewlines", "0xabcd");
    defer a.free(cur);
    const ks = try CursorCodec.decodeKeyset(a, cur);
    defer ks.deinit(a);
    try std.testing.expectEqual(@as(u8, 'n'), ks.field);
    try std.testing.expectEqual(@as(u64, 0xDEADBEEFCAFE), ks.filter_hash);
    try std.testing.expectEqual(@as(?usize, 42), ks.total_count);
    try std.testing.expectEqualStrings("0xabcd", ks.namehash);
    try std.testing.expectEqualStrings("value\nwith\nnewlines", ks.sort_value); // sort_value may hold '\n'

    // A null totalCount round-trips as null.
    const cur2 = try CursorCodec.encodeKeyset(a, 'e', 7, null, "sv", "0x00");
    defer a.free(cur2);
    const ks2 = try CursorCodec.decodeKeyset(a, cur2);
    defer ks2.deinit(a);
    try std.testing.expectEqual(@as(?usize, null), ks2.total_count);
    try std.testing.expectEqual(@as(u64, 7), ks2.filter_hash);

    // The legacy filterless "ks\n" format is rejected (→ caller starts fresh).
    const legacy = try Cursor_fromPlain(a, "ks\nn\n\n0xabcd\nsv");
    defer a.free(legacy);
    try std.testing.expectError(error.InvalidCursor, CursorCodec.decodeKeyset(a, legacy));
}

fn Cursor_fromPlain(allocator: std.mem.Allocator, plain: []const u8) !Cursor {
    const encoder = base64.standard.Encoder;
    const out = try allocator.alloc(u8, encoder.calcSize(plain.len));
    return encoder.encode(out, plain);
}

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

test "PaginationParams.parse - explicit first exceeding max errors" {
    const result = PaginationParams.parse(5000, null, null, null, 100, 1000);
    try std.testing.expectError(error.LimitExceeded, result);
}

test "PaginationParams.parse - explicit first at max passes" {
    const params = try PaginationParams.parse(1000, null, null, null, 100, 1000);
    try std.testing.expectEqual(@as(usize, 1000), params.limit);
}

test "PaginationParams.parse - invalid args" {
    const result = PaginationParams.parse(10, null, 10, null, 100, 1000);
    try std.testing.expectError(error.InvalidPaginationArgs, result);
}
