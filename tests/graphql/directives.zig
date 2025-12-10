const std = @import("std");
const testing = std.testing;
const parser = @import("../../src/api/graphql_parser.zig");

// ============================================================================
// DIRECTIVE TESTS
// Tests for GraphQL directives: @skip and @include
// ============================================================================

test "parse @skip directive with boolean literal" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  domain(id: "test.eth") {
        \\    name
        \\    owner @skip(if: true) {
        \\      id
        \\    }
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const domain_field = &doc.operations[0].fields[0];
    try testing.expectEqual(@as(usize, 2), domain_field.selections.len);

    // First field has no directives
    try testing.expectEqual(@as(usize, 0), domain_field.selections[0].directives.len);

    // Second field has @skip directive
    const owner_field = &domain_field.selections[1];
    try testing.expectEqual(@as(usize, 1), owner_field.directives.len);
    try testing.expectEqualStrings("skip", owner_field.directives[0].name);
    try testing.expectEqual(@as(usize, 1), owner_field.directives[0].arguments.len);
    try testing.expectEqualStrings("if", owner_field.directives[0].arguments[0].name);
    try testing.expect(owner_field.directives[0].arguments[0].value.boolean == true);
}

test "parse @include directive with boolean literal" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  domain(id: "test.eth") {
        \\    name @include(if: false)
        \\    id
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const domain_field = &doc.operations[0].fields[0];

    // First field has @include directive
    const name_field = &domain_field.selections[0];
    try testing.expectEqual(@as(usize, 1), name_field.directives.len);
    try testing.expectEqualStrings("include", name_field.directives[0].name);
    try testing.expect(name_field.directives[0].arguments[0].value.boolean == false);

    // Second field has no directives
    try testing.expectEqual(@as(usize, 0), domain_field.selections[1].directives.len);
}

test "parse directive with variable reference" {
    const allocator = testing.allocator;

    const query =
        \\query GetDomain($showOwner: Boolean!) {
        \\  domain(id: "test.eth") {
        \\    name
        \\    owner @include(if: $showOwner) {
        \\      id
        \\    }
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const domain_field = &doc.operations[0].fields[0];
    const owner_field = &domain_field.selections[1];

    try testing.expectEqual(@as(usize, 1), owner_field.directives.len);
    try testing.expectEqualStrings("include", owner_field.directives[0].name);

    // Check variable reference
    const arg_value = owner_field.directives[0].arguments[0].value;
    try testing.expectEqualStrings("showOwner", arg_value.variable);
}

test "parse multiple directives on same field" {
    const allocator = testing.allocator;

    // Note: This is valid GraphQL syntax, though unusual
    const query =
        \\{
        \\  domain(id: "test.eth") {
        \\    name @skip(if: false) @include(if: true)
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const domain_field = &doc.operations[0].fields[0];
    const name_field = &domain_field.selections[0];

    try testing.expectEqual(@as(usize, 2), name_field.directives.len);
    try testing.expectEqualStrings("skip", name_field.directives[0].name);
    try testing.expectEqualStrings("include", name_field.directives[1].name);
}

test "shouldSkip returns true for @skip(if: true)" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  field @skip(if: true)
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];
    try testing.expect(field.shouldSkip(null) == true);
}

test "shouldSkip returns false for @skip(if: false)" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  field @skip(if: false)
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];
    try testing.expect(field.shouldSkip(null) == false);
}

test "shouldSkip returns false for @include(if: true)" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  field @include(if: true)
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];
    try testing.expect(field.shouldSkip(null) == false);
}

test "shouldSkip returns true for @include(if: false)" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  field @include(if: false)
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];
    try testing.expect(field.shouldSkip(null) == true);
}

test "shouldSkip with variable - variable provided" {
    const allocator = testing.allocator;

    const query =
        \\query ($skip: Boolean!) {
        \\  field @skip(if: $skip)
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];

    // Create a variables map with skip = true
    var variables = std.StringHashMap(std.json.Value).init(allocator);
    defer variables.deinit();
    try variables.put("skip", std.json.Value{ .bool = true });

    try testing.expect(field.shouldSkip(&variables) == true);

    // Change to false
    try variables.put("skip", std.json.Value{ .bool = false });
    try testing.expect(field.shouldSkip(&variables) == false);
}

test "shouldSkip with variable - variable not provided defaults to false" {
    const allocator = testing.allocator;

    const query =
        \\query ($skip: Boolean!) {
        \\  field @skip(if: $skip)
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];

    // Empty variables map
    var variables = std.StringHashMap(std.json.Value).init(allocator);
    defer variables.deinit();

    // Should default to false (don't skip)
    try testing.expect(field.shouldSkip(&variables) == false);
}

test "shouldSkip returns false for field without directives" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  field
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];
    try testing.expect(field.shouldSkip(null) == false);
}

test "parse directive on fragment spread" {
    const allocator = testing.allocator;

    const query =
        \\fragment Fields on Domain {
        \\  name
        \\}
        \\
        \\query ($show: Boolean!) {
        \\  domain(id: "test.eth") {
        \\    id
        \\    ...Fields @include(if: $show)
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const domain_field = &doc.operations[0].fields[0];
    const spread = &domain_field.selections[1];

    try testing.expect(spread.fragment_spread != null);
    try testing.expectEqual(@as(usize, 1), spread.directives.len);
    try testing.expectEqualStrings("include", spread.directives[0].name);
}

test "parse directive on inline fragment" {
    const allocator = testing.allocator;

    const query =
        \\query ($showDetails: Boolean!) {
        \\  domain(id: "test.eth") {
        \\    id
        \\    ... on Domain @include(if: $showDetails) {
        \\      name
        \\      owner { id }
        \\    }
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const domain_field = &doc.operations[0].fields[0];
    const inline_frag = &domain_field.selections[1];

    try testing.expectEqualStrings("Domain", inline_frag.name);
    try testing.expectEqual(@as(usize, 1), inline_frag.directives.len);
    try testing.expectEqualStrings("include", inline_frag.directives[0].name);
}
