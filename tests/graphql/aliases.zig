const std = @import("std");
const testing = std.testing;
const parser = @import("../../src/api/graphql_parser.zig");

// ============================================================================
// FIELD ALIAS TESTS
// Tests for GraphQL field alias parsing: `alias: fieldName`
// ============================================================================

test "parse simple field alias" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  myName: name
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), doc.operations.len);
    try testing.expectEqual(@as(usize, 1), doc.operations[0].fields.len);

    const field = &doc.operations[0].fields[0];
    try testing.expectEqualStrings("name", field.name);
    try testing.expectEqualStrings("myName", field.alias.?);
}

test "parse alias with arguments" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  avatar: text(key: "avatar")
        \\  description: text(key: "description")
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), doc.operations[0].fields.len);

    // First field
    const field1 = &doc.operations[0].fields[0];
    try testing.expectEqualStrings("text", field1.name);
    try testing.expectEqualStrings("avatar", field1.alias.?);
    try testing.expectEqual(@as(usize, 1), field1.arguments.len);
    try testing.expectEqualStrings("key", field1.arguments[0].name);
    try testing.expectEqualStrings("avatar", field1.arguments[0].value.string);

    // Second field
    const field2 = &doc.operations[0].fields[1];
    try testing.expectEqualStrings("text", field2.name);
    try testing.expectEqualStrings("description", field2.alias.?);
}

test "parse alias with nested selections" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  myDomain: domain(id: "test.eth") {
        \\    domainName: name
        \\    domainOwner: owner {
        \\      ownerAddress: id
        \\    }
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const domain_field = &doc.operations[0].fields[0];
    try testing.expectEqualStrings("domain", domain_field.name);
    try testing.expectEqualStrings("myDomain", domain_field.alias.?);

    // Check nested fields
    try testing.expectEqual(@as(usize, 2), domain_field.selections.len);

    const name_field = &domain_field.selections[0];
    try testing.expectEqualStrings("name", name_field.name);
    try testing.expectEqualStrings("domainName", name_field.alias.?);

    const owner_field = &domain_field.selections[1];
    try testing.expectEqualStrings("owner", owner_field.name);
    try testing.expectEqualStrings("domainOwner", owner_field.alias.?);

    // Check deeply nested field
    try testing.expectEqual(@as(usize, 1), owner_field.selections.len);
    const id_field = &owner_field.selections[0];
    try testing.expectEqualStrings("id", id_field.name);
    try testing.expectEqualStrings("ownerAddress", id_field.alias.?);
}

test "parse field without alias returns null alias" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  name
        \\  id
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), doc.operations[0].fields.len);
    try testing.expect(doc.operations[0].fields[0].alias == null);
    try testing.expect(doc.operations[0].fields[1].alias == null);
}

test "parse multiple aliases for same field" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  first: domain(id: "a.eth") { name }
        \\  second: domain(id: "b.eth") { name }
        \\  third: domain(id: "c.eth") { name }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    try testing.expectEqual(@as(usize, 3), doc.operations[0].fields.len);
    try testing.expectEqualStrings("first", doc.operations[0].fields[0].alias.?);
    try testing.expectEqualStrings("second", doc.operations[0].fields[1].alias.?);
    try testing.expectEqualStrings("third", doc.operations[0].fields[2].alias.?);

    // All should have the same field name
    for (doc.operations[0].fields) |*field| {
        try testing.expectEqualStrings("domain", field.name);
    }
}
