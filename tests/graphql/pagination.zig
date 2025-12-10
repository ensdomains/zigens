const std = @import("std");
const testing = std.testing;
const pagination = @import("../../src/api/pagination.zig");

// ============================================================================
// PAGINATION TESTS
// Tests for GraphQL cursor-based pagination (Relay spec)
// Includes forward pagination (first/after) and backward pagination (last/before)
// ============================================================================

// ----------------------------------------------------------------------------
// DIRECTION TESTS
// ----------------------------------------------------------------------------

test "Direction enum has forward and backward" {
    try testing.expect(pagination.Direction.forward != pagination.Direction.backward);
}

// ----------------------------------------------------------------------------
// PAGINATION PARAMS TESTS
// ----------------------------------------------------------------------------

test "PaginationParams.parse - forward with first only" {
    const params = try pagination.PaginationParams.parse(
        10, // first
        null, // after
        null, // last
        null, // before
        100, // default_limit
        1000, // max_limit
    );

    try testing.expectEqual(pagination.Direction.forward, params.direction);
    try testing.expectEqual(@as(usize, 10), params.limit);
    try testing.expect(params.cursor == null);
}

test "PaginationParams.parse - forward with first and after" {
    const after_cursor = "abc123";
    const params = try pagination.PaginationParams.parse(
        10, // first
        after_cursor, // after
        null, // last
        null, // before
        100, // default_limit
        1000, // max_limit
    );

    try testing.expectEqual(pagination.Direction.forward, params.direction);
    try testing.expectEqual(@as(usize, 10), params.limit);
    try testing.expectEqualStrings(after_cursor, params.cursor.?);
}

test "PaginationParams.parse - backward with last only" {
    const params = try pagination.PaginationParams.parse(
        null, // first
        null, // after
        5, // last
        null, // before
        100, // default_limit
        1000, // max_limit
    );

    try testing.expectEqual(pagination.Direction.backward, params.direction);
    try testing.expectEqual(@as(usize, 5), params.limit);
    try testing.expect(params.cursor == null);
}

test "PaginationParams.parse - backward with last and before" {
    const before_cursor = "xyz789";
    const params = try pagination.PaginationParams.parse(
        null, // first
        null, // after
        5, // last
        before_cursor, // before
        100, // default_limit
        1000, // max_limit
    );

    try testing.expectEqual(pagination.Direction.backward, params.direction);
    try testing.expectEqual(@as(usize, 5), params.limit);
    try testing.expectEqualStrings(before_cursor, params.cursor.?);
}

test "PaginationParams.parse - uses default limit when no limit specified" {
    const params = try pagination.PaginationParams.parse(
        null, // first
        null, // after
        null, // last
        null, // before
        42, // default_limit
        1000, // max_limit
    );

    try testing.expectEqual(pagination.Direction.forward, params.direction);
    try testing.expectEqual(@as(usize, 42), params.limit);
}

test "PaginationParams.parse - caps limit at max_limit" {
    const params = try pagination.PaginationParams.parse(
        5000, // first - exceeds max
        null, // after
        null, // last
        null, // before
        100, // default_limit
        1000, // max_limit
    );

    try testing.expectEqual(@as(usize, 1000), params.limit); // Capped at max
}

test "PaginationParams.parse - caps backward limit at max_limit" {
    const params = try pagination.PaginationParams.parse(
        null, // first
        null, // after
        2000, // last - exceeds max
        null, // before
        100, // default_limit
        500, // max_limit
    );

    try testing.expectEqual(@as(usize, 500), params.limit); // Capped at max
}

// ----------------------------------------------------------------------------
// INVALID PAGINATION ARGS TESTS
// ----------------------------------------------------------------------------

test "PaginationParams.parse - error for first and last together" {
    const result = pagination.PaginationParams.parse(
        10, // first
        null, // after
        10, // last - invalid with first
        null, // before
        100, // default_limit
        1000, // max_limit
    );
    try testing.expectError(error.InvalidPaginationArgs, result);
}

test "PaginationParams.parse - error for after and before together" {
    const result = pagination.PaginationParams.parse(
        10, // first
        "after_cursor", // after
        null, // last
        "before_cursor", // before - invalid with after
        100, // default_limit
        1000, // max_limit
    );
    try testing.expectError(error.InvalidPaginationArgs, result);
}

test "PaginationParams.parse - error for first with before" {
    const result = pagination.PaginationParams.parse(
        10, // first
        null, // after
        null, // last
        "before_cursor", // before - invalid with first
        100, // default_limit
        1000, // max_limit
    );
    try testing.expectError(error.InvalidPaginationArgs, result);
}

test "PaginationParams.parse - error for last with after" {
    const result = pagination.PaginationParams.parse(
        null, // first
        "after_cursor", // after - invalid with last
        10, // last
        null, // before
        100, // default_limit
        1000, // max_limit
    );
    try testing.expectError(error.InvalidPaginationArgs, result);
}

test "PaginationParams.parse - error for negative limit" {
    const result = pagination.PaginationParams.parse(
        -5, // first - negative
        null, // after
        null, // last
        null, // before
        100, // default_limit
        1000, // max_limit
    );
    try testing.expectError(error.NegativeLimit, result);
}

test "PaginationParams.parse - error for negative last" {
    const result = pagination.PaginationParams.parse(
        null, // first
        null, // after
        -10, // last - negative
        null, // before
        100, // default_limit
        1000, // max_limit
    );
    try testing.expectError(error.NegativeLimit, result);
}

// ----------------------------------------------------------------------------
// CURSOR CODEC TESTS
// ----------------------------------------------------------------------------

test "CursorCodec.encodeInt - encodes integer to base64" {
    const allocator = testing.allocator;

    const cursor = try pagination.CursorCodec.encodeInt(allocator, 42);
    defer allocator.free(cursor);

    // Verify it's valid base64
    try testing.expect(cursor.len > 0);
    // Decode and verify
    const decoded = try pagination.CursorCodec.decodeInt(allocator, cursor);
    try testing.expectEqual(@as(i64, 42), decoded);
}

test "CursorCodec.encodeInt - handles large numbers" {
    const allocator = testing.allocator;

    const cursor = try pagination.CursorCodec.encodeInt(allocator, 9007199254740991);
    defer allocator.free(cursor);

    const decoded = try pagination.CursorCodec.decodeInt(allocator, cursor);
    try testing.expectEqual(@as(i64, 9007199254740991), decoded);
}

test "CursorCodec.encodeInt - handles zero" {
    const allocator = testing.allocator;

    const cursor = try pagination.CursorCodec.encodeInt(allocator, 0);
    defer allocator.free(cursor);

    const decoded = try pagination.CursorCodec.decodeInt(allocator, cursor);
    try testing.expectEqual(@as(i64, 0), decoded);
}

test "CursorCodec.encodeInt - handles negative numbers" {
    const allocator = testing.allocator;

    const cursor = try pagination.CursorCodec.encodeInt(allocator, -42);
    defer allocator.free(cursor);

    const decoded = try pagination.CursorCodec.decodeInt(allocator, cursor);
    try testing.expectEqual(@as(i64, -42), decoded);
}

test "CursorCodec.encodeString - encodes string to base64" {
    const allocator = testing.allocator;

    const cursor = try pagination.CursorCodec.encodeString(allocator, "test-id-123");
    defer allocator.free(cursor);

    const decoded = try pagination.CursorCodec.decodeString(allocator, cursor);
    defer allocator.free(decoded);

    try testing.expectEqualStrings("test-id-123", decoded);
}

test "CursorCodec.encodeString - handles ENS domain ID" {
    const allocator = testing.allocator;

    const domain_id = "0x93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae";
    const cursor = try pagination.CursorCodec.encodeString(allocator, domain_id);
    defer allocator.free(cursor);

    const decoded = try pagination.CursorCodec.decodeString(allocator, cursor);
    defer allocator.free(decoded);

    try testing.expectEqualStrings(domain_id, decoded);
}

test "CursorCodec.encodeString - handles empty string" {
    const allocator = testing.allocator;

    const cursor = try pagination.CursorCodec.encodeString(allocator, "");
    defer allocator.free(cursor);

    const decoded = try pagination.CursorCodec.decodeString(allocator, cursor);
    defer allocator.free(decoded);

    try testing.expectEqualStrings("", decoded);
}

test "CursorCodec.decodeInt - error for invalid cursor format" {
    const allocator = testing.allocator;

    // Not a valid cursor (not base64 encoded int:xxx format)
    const result = pagination.CursorCodec.decodeInt(allocator, "invalid");
    try testing.expectError(error.InvalidCursor, result);
}

// ----------------------------------------------------------------------------
// PAGE INFO TESTS
// ----------------------------------------------------------------------------

test "PageInfo struct has all required fields" {
    const page_info = pagination.PageInfo{
        .has_next_page = true,
        .has_previous_page = false,
        .start_cursor = "start",
        .end_cursor = "end",
    };

    try testing.expect(page_info.has_next_page == true);
    try testing.expect(page_info.has_previous_page == false);
    try testing.expectEqualStrings("start", page_info.start_cursor.?);
    try testing.expectEqualStrings("end", page_info.end_cursor.?);
}

test "PageInfo with null cursors" {
    const page_info = pagination.PageInfo{
        .has_next_page = false,
        .has_previous_page = false,
        .start_cursor = null,
        .end_cursor = null,
    };

    try testing.expect(page_info.start_cursor == null);
    try testing.expect(page_info.end_cursor == null);
}

// ----------------------------------------------------------------------------
// EDGE TYPE TESTS
// ----------------------------------------------------------------------------

test "Edge type parameterization" {
    // Test that Edge works with different node types
    const IntEdge = pagination.Edge(i32);
    const edge: IntEdge = .{
        .cursor = "test_cursor",
        .node = 42,
    };

    try testing.expectEqualStrings("test_cursor", edge.cursor);
    try testing.expectEqual(@as(i32, 42), edge.node);
}

// ----------------------------------------------------------------------------
// CONNECTION BUILDER TESTS
// ----------------------------------------------------------------------------

const TestItem = struct {
    id: i64,
    name: []const u8,
};

fn getTestItemId(item: TestItem) i64 {
    return item.id;
}

test "buildConnectionInt - empty items" {
    const allocator = testing.allocator;

    const items: []const TestItem = &.{};
    const params = try pagination.PaginationParams.parse(10, null, null, null, 100, 1000);

    const conn = try pagination.buildConnectionInt(
        TestItem,
        allocator,
        items,
        params,
        getTestItemId,
        null,
    );
    // Empty connection doesn't need deinit

    try testing.expectEqual(@as(usize, 0), conn.edges.len);
    try testing.expect(conn.page_info.has_next_page == false);
    try testing.expect(conn.page_info.has_previous_page == false);
    try testing.expect(conn.page_info.start_cursor == null);
    try testing.expect(conn.page_info.end_cursor == null);
}

test "buildConnectionInt - with items" {
    const allocator = testing.allocator;

    const items = [_]TestItem{
        .{ .id = 1, .name = "first" },
        .{ .id = 2, .name = "second" },
        .{ .id = 3, .name = "third" },
    };

    const params = try pagination.PaginationParams.parse(10, null, null, null, 100, 1000);

    const conn = try pagination.buildConnectionInt(
        TestItem,
        allocator,
        &items,
        params,
        getTestItemId,
        @as(?usize, 3),
    );
    defer conn.deinit(allocator);

    try testing.expectEqual(@as(usize, 3), conn.edges.len);
    try testing.expectEqual(@as(i64, 1), conn.edges[0].node.id);
    try testing.expectEqual(@as(i64, 2), conn.edges[1].node.id);
    try testing.expectEqual(@as(i64, 3), conn.edges[2].node.id);
    try testing.expectEqual(@as(?usize, 3), conn.total_count);
    try testing.expect(conn.page_info.start_cursor != null);
    try testing.expect(conn.page_info.end_cursor != null);
}

test "buildConnectionInt - has_next_page when at limit" {
    const allocator = testing.allocator;

    const items = [_]TestItem{
        .{ .id = 1, .name = "first" },
        .{ .id = 2, .name = "second" },
    };

    // Request exactly 2 items (same as what we have)
    const params = try pagination.PaginationParams.parse(2, null, null, null, 100, 1000);

    const conn = try pagination.buildConnectionInt(
        TestItem,
        allocator,
        &items,
        params,
        getTestItemId,
        null,
    );
    defer conn.deinit(allocator);

    // When we get exactly limit items, there might be more
    try testing.expect(conn.page_info.has_next_page == true);
}

test "buildConnectionInt - no has_next_page when under limit" {
    const allocator = testing.allocator;

    const items = [_]TestItem{
        .{ .id = 1, .name = "first" },
    };

    // Request 10 but only get 1
    const params = try pagination.PaginationParams.parse(10, null, null, null, 100, 1000);

    const conn = try pagination.buildConnectionInt(
        TestItem,
        allocator,
        &items,
        params,
        getTestItemId,
        null,
    );
    defer conn.deinit(allocator);

    // When we get less than limit, no more pages
    try testing.expect(conn.page_info.has_next_page == false);
}

test "buildConnectionInt - backward pagination page info" {
    const allocator = testing.allocator;

    const items = [_]TestItem{
        .{ .id = 1, .name = "first" },
        .{ .id = 2, .name = "second" },
    };

    // Backward pagination with last=2
    const params = try pagination.PaginationParams.parse(null, null, 2, null, 100, 1000);

    const conn = try pagination.buildConnectionInt(
        TestItem,
        allocator,
        &items,
        params,
        getTestItemId,
        null,
    );
    defer conn.deinit(allocator);

    // Backward at limit means there might be previous pages
    try testing.expect(conn.page_info.has_previous_page == true);
    try testing.expect(conn.page_info.has_next_page == false);
}

test "buildConnectionInt - has_previous_page with cursor" {
    const allocator = testing.allocator;

    const items = [_]TestItem{
        .{ .id = 1, .name = "first" },
    };

    // Forward pagination with cursor means we came from somewhere
    const params = try pagination.PaginationParams.parse(10, "some_cursor", null, null, 100, 1000);

    const conn = try pagination.buildConnectionInt(
        TestItem,
        allocator,
        &items,
        params,
        getTestItemId,
        null,
    );
    defer conn.deinit(allocator);

    // When we have a cursor, there are previous pages
    try testing.expect(conn.page_info.has_previous_page == true);
}
