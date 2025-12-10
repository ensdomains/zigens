const std = @import("std");
const testing = std.testing;
const parser = @import("../../src/api/graphql_parser.zig");

// ============================================================================
// INLINE FRAGMENT TESTS
// Tests for GraphQL inline fragments: `... on Type { fields }`
// ============================================================================

test "parse inline fragment with type condition" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  domain(id: "test.eth") {
        \\    id
        \\    ... on Domain {
        \\      name
        \\      owner {
        \\        id
        \\      }
        \\    }
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const domain_field = &doc.operations[0].fields[0];
    try testing.expectEqual(@as(usize, 2), domain_field.selections.len);

    // First is regular field
    try testing.expectEqualStrings("id", domain_field.selections[0].name);

    // Second is inline fragment - stored with type condition as name
    const inline_frag = &domain_field.selections[1];
    try testing.expectEqualStrings("Domain", inline_frag.name);
    try testing.expect(inline_frag.fragment_spread == null); // Not a named spread
    try testing.expectEqual(@as(usize, 2), inline_frag.selections.len);

    // Check inline fragment fields
    try testing.expectEqualStrings("name", inline_frag.selections[0].name);
    try testing.expectEqualStrings("owner", inline_frag.selections[1].name);
}

test "parse multiple inline fragments" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  node(id: "123") {
        \\    id
        \\    ... on Domain {
        \\      name
        \\    }
        \\    ... on Account {
        \\      domains {
        \\        id
        \\      }
        \\    }
        \\    ... on Resolver {
        \\      address
        \\    }
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const node_field = &doc.operations[0].fields[0];
    try testing.expectEqual(@as(usize, 4), node_field.selections.len);

    // Regular field
    try testing.expectEqualStrings("id", node_field.selections[0].name);

    // Inline fragments with different type conditions
    try testing.expectEqualStrings("Domain", node_field.selections[1].name);
    try testing.expectEqualStrings("Account", node_field.selections[2].name);
    try testing.expectEqualStrings("Resolver", node_field.selections[3].name);
}

test "parse nested inline fragments" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  domain(id: "test.eth") {
        \\    ... on Domain {
        \\      owner {
        \\        ... on Account {
        \\          id
        \\          domains {
        \\            name
        \\          }
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const domain_field = &doc.operations[0].fields[0];
    try testing.expectEqual(@as(usize, 1), domain_field.selections.len);

    // Outer inline fragment
    const outer_frag = &domain_field.selections[0];
    try testing.expectEqualStrings("Domain", outer_frag.name);
    try testing.expectEqual(@as(usize, 1), outer_frag.selections.len);

    // Owner field
    const owner_field = &outer_frag.selections[0];
    try testing.expectEqualStrings("owner", owner_field.name);
    try testing.expectEqual(@as(usize, 1), owner_field.selections.len);

    // Inner inline fragment
    const inner_frag = &owner_field.selections[0];
    try testing.expectEqualStrings("Account", inner_frag.name);
    try testing.expectEqual(@as(usize, 2), inner_frag.selections.len);
}

test "parse inline fragment mixed with named spread" {
    const allocator = testing.allocator;

    const query =
        \\fragment OwnerFields on Account {
        \\  id
        \\}
        \\
        \\{
        \\  domain(id: "test.eth") {
        \\    name
        \\    ... on Domain {
        \\      labelName
        \\    }
        \\    owner {
        \\      ...OwnerFields
        \\    }
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    // Should have 1 fragment definition
    try testing.expectEqual(@as(usize, 1), doc.fragments.len);

    const domain_field = &doc.operations[0].fields[0];
    try testing.expectEqual(@as(usize, 3), domain_field.selections.len);

    // Regular field
    try testing.expectEqualStrings("name", domain_field.selections[0].name);
    try testing.expect(domain_field.selections[0].fragment_spread == null);

    // Inline fragment (no fragment_spread, has type condition as name)
    try testing.expectEqualStrings("Domain", domain_field.selections[1].name);
    try testing.expect(domain_field.selections[1].fragment_spread == null);

    // Owner with nested spread
    const owner = &domain_field.selections[2];
    try testing.expectEqualStrings("owner", owner.name);
    try testing.expectEqual(@as(usize, 1), owner.selections.len);
    try testing.expect(owner.selections[0].fragment_spread != null);
    try testing.expectEqualStrings("OwnerFields", owner.selections[0].fragment_spread.?);
}

test "inline fragment with empty selections" {
    const allocator = testing.allocator;

    // Edge case: inline fragment with single field
    const query =
        \\{
        \\  domain(id: "test.eth") {
        \\    ... on Domain {
        \\      name
        \\    }
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const domain_field = &doc.operations[0].fields[0];
    try testing.expectEqual(@as(usize, 1), domain_field.selections.len);

    const inline_frag = &domain_field.selections[0];
    try testing.expectEqualStrings("Domain", inline_frag.name);
    try testing.expectEqual(@as(usize, 1), inline_frag.selections.len);
    try testing.expectEqualStrings("name", inline_frag.selections[0].name);
}
