const std = @import("std");
const testing = std.testing;
const parser = @import("../../src/api/graphql_parser.zig");

// ============================================================================
// FRAGMENT TESTS
// Tests for GraphQL fragment definitions and spreads
// ============================================================================

test "parse fragment definition" {
    const allocator = testing.allocator;

    const query =
        \\fragment DomainFields on Domain {
        \\  id
        \\  name
        \\  owner {
        \\    id
        \\  }
        \\}
        \\
        \\query {
        \\  domain(id: "test.eth") {
        \\    ...DomainFields
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    // Check fragment was parsed
    try testing.expectEqual(@as(usize, 1), doc.fragments.len);

    const frag = &doc.fragments[0];
    try testing.expectEqualStrings("DomainFields", frag.name);
    try testing.expectEqualStrings("Domain", frag.type_condition);
    try testing.expectEqual(@as(usize, 3), frag.selections.len);

    // Check fragment fields
    try testing.expectEqualStrings("id", frag.selections[0].name);
    try testing.expectEqualStrings("name", frag.selections[1].name);
    try testing.expectEqualStrings("owner", frag.selections[2].name);
}

test "parse fragment spread" {
    const allocator = testing.allocator;

    const query =
        \\fragment NameFields on Domain {
        \\  name
        \\  labelName
        \\}
        \\
        \\{
        \\  domain(id: "test.eth") {
        \\    id
        \\    ...NameFields
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    // Check operation has the spread
    const domain_field = &doc.operations[0].fields[0];
    try testing.expectEqual(@as(usize, 2), domain_field.selections.len);

    // First is regular field
    try testing.expectEqualStrings("id", domain_field.selections[0].name);
    try testing.expect(domain_field.selections[0].fragment_spread == null);

    // Second is fragment spread
    const spread = &domain_field.selections[1];
    try testing.expect(spread.fragment_spread != null);
    try testing.expectEqualStrings("NameFields", spread.fragment_spread.?);
}

test "parse multiple fragments" {
    const allocator = testing.allocator;

    const query =
        \\fragment BasicFields on Domain {
        \\  id
        \\  name
        \\}
        \\
        \\fragment OwnerFields on Domain {
        \\  owner {
        \\    id
        \\  }
        \\}
        \\
        \\fragment ResolverFields on Domain {
        \\  resolver {
        \\    address
        \\  }
        \\}
        \\
        \\{
        \\  domain(id: "test.eth") {
        \\    ...BasicFields
        \\    ...OwnerFields
        \\    ...ResolverFields
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    // Check all 3 fragments were parsed
    try testing.expectEqual(@as(usize, 3), doc.fragments.len);
    try testing.expectEqualStrings("BasicFields", doc.fragments[0].name);
    try testing.expectEqualStrings("OwnerFields", doc.fragments[1].name);
    try testing.expectEqualStrings("ResolverFields", doc.fragments[2].name);

    // Check spreads in query
    const domain_field = &doc.operations[0].fields[0];
    try testing.expectEqual(@as(usize, 3), domain_field.selections.len);

    for (domain_field.selections) |*sel| {
        try testing.expect(sel.fragment_spread != null);
    }
}

test "parse nested fragment spreads" {
    const allocator = testing.allocator;

    const query =
        \\fragment AddressFields on Account {
        \\  id
        \\}
        \\
        \\fragment OwnerFields on Domain {
        \\  owner {
        \\    ...AddressFields
        \\  }
        \\}
        \\
        \\{
        \\  domain(id: "test.eth") {
        \\    ...OwnerFields
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), doc.fragments.len);

    // Check OwnerFields fragment has nested spread
    const owner_frag = &doc.fragments[1];
    try testing.expectEqualStrings("OwnerFields", owner_frag.name);
    try testing.expectEqual(@as(usize, 1), owner_frag.selections.len);

    const owner_field = &owner_frag.selections[0];
    try testing.expectEqualStrings("owner", owner_field.name);
    try testing.expectEqual(@as(usize, 1), owner_field.selections.len);

    const nested_spread = &owner_field.selections[0];
    try testing.expect(nested_spread.fragment_spread != null);
    try testing.expectEqualStrings("AddressFields", nested_spread.fragment_spread.?);
}

test "fragment isFragmentSpread helper" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  domain(id: "test.eth") {
        \\    name
        \\    ...SomeFragment
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const domain_field = &doc.operations[0].fields[0];

    // Regular field
    try testing.expect(!domain_field.selections[0].isFragmentSpread());

    // Fragment spread
    try testing.expect(domain_field.selections[1].isFragmentSpread());
}
