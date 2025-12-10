const std = @import("std");
const testing = std.testing;
const parser = @import("../../src/api/graphql_parser.zig");

// ============================================================================
// VARIABLE TESTS
// Tests for GraphQL variable definitions and default values
// ============================================================================

test "parse simple variable definition" {
    const allocator = testing.allocator;

    const query =
        \\query GetDomain($id: String!) {
        \\  domain(id: $id) {
        \\    name
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), doc.operations[0].variables.len);

    const var_def = &doc.operations[0].variables[0];
    try testing.expectEqualStrings("id", var_def.name);
    try testing.expectEqualStrings("String", var_def.type_name);
    try testing.expect(var_def.required == true);
    try testing.expect(var_def.is_list == false);
    try testing.expect(var_def.default_value == null);
}

test "parse nullable variable" {
    const allocator = testing.allocator;

    const query =
        \\query GetDomain($id: String) {
        \\  domain(id: $id) {
        \\    name
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const var_def = &doc.operations[0].variables[0];
    try testing.expectEqualStrings("id", var_def.name);
    try testing.expectEqualStrings("String", var_def.type_name);
    try testing.expect(var_def.required == false);
}

test "parse multiple variables" {
    const allocator = testing.allocator;

    const query =
        \\query GetDomains($first: Int!, $after: String, $owner: String!) {
        \\  domains(first: $first, after: $after, owner: $owner) {
        \\    id
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    try testing.expectEqual(@as(usize, 3), doc.operations[0].variables.len);

    // first: Int!
    try testing.expectEqualStrings("first", doc.operations[0].variables[0].name);
    try testing.expectEqualStrings("Int", doc.operations[0].variables[0].type_name);
    try testing.expect(doc.operations[0].variables[0].required == true);

    // after: String
    try testing.expectEqualStrings("after", doc.operations[0].variables[1].name);
    try testing.expectEqualStrings("String", doc.operations[0].variables[1].type_name);
    try testing.expect(doc.operations[0].variables[1].required == false);

    // owner: String!
    try testing.expectEqualStrings("owner", doc.operations[0].variables[2].name);
    try testing.expectEqualStrings("String", doc.operations[0].variables[2].type_name);
    try testing.expect(doc.operations[0].variables[2].required == true);
}

test "parse variable with string default value" {
    const allocator = testing.allocator;

    const query =
        \\query GetDomain($id: String = "vitalik.eth") {
        \\  domain(id: $id) {
        \\    name
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const var_def = &doc.operations[0].variables[0];
    try testing.expectEqualStrings("id", var_def.name);
    try testing.expect(var_def.default_value != null);
    try testing.expectEqualStrings("vitalik.eth", var_def.default_value.?.string);
}

test "parse variable with int default value" {
    const allocator = testing.allocator;

    const query =
        \\query GetDomains($first: Int = 10) {
        \\  domains(first: $first) {
        \\    id
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const var_def = &doc.operations[0].variables[0];
    try testing.expectEqualStrings("first", var_def.name);
    try testing.expect(var_def.default_value != null);
    try testing.expectEqual(@as(i64, 10), var_def.default_value.?.int);
}

test "parse variable with boolean default value" {
    const allocator = testing.allocator;

    const query =
        \\query GetDomain($showOwner: Boolean = true) {
        \\  domain(id: "test.eth") {
        \\    name
        \\    owner @include(if: $showOwner) { id }
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const var_def = &doc.operations[0].variables[0];
    try testing.expectEqualStrings("showOwner", var_def.name);
    try testing.expectEqualStrings("Boolean", var_def.type_name);
    try testing.expect(var_def.default_value != null);
    try testing.expect(var_def.default_value.?.boolean == true);
}

test "parse variable with false boolean default" {
    const allocator = testing.allocator;

    const query =
        \\query GetDomain($skip: Boolean = false) {
        \\  domain(id: "test.eth") {
        \\    name @skip(if: $skip)
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const var_def = &doc.operations[0].variables[0];
    try testing.expect(var_def.default_value != null);
    try testing.expect(var_def.default_value.?.boolean == false);
}

test "parse variable with null default value" {
    const allocator = testing.allocator;

    const query =
        \\query GetDomain($filter: String = null) {
        \\  domains(filter: $filter) {
        \\    id
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const var_def = &doc.operations[0].variables[0];
    try testing.expect(var_def.default_value != null);
    try testing.expect(var_def.default_value.? == .null_value);
}

test "parse variable reference in argument" {
    const allocator = testing.allocator;

    const query =
        \\query GetDomain($id: String!) {
        \\  domain(id: $id) {
        \\    name
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const domain_field = &doc.operations[0].fields[0];
    try testing.expectEqual(@as(usize, 1), domain_field.arguments.len);

    const arg = &domain_field.arguments[0];
    try testing.expectEqualStrings("id", arg.name);
    try testing.expectEqualStrings("id", arg.value.variable);
}

test "parse mixed variables with and without defaults" {
    const allocator = testing.allocator;

    const query =
        \\query GetDomains($first: Int = 10, $after: String, $owner: String!) {
        \\  domains(first: $first, after: $after, owner: $owner) {
        \\    id
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    try testing.expectEqual(@as(usize, 3), doc.operations[0].variables.len);

    // first: Int = 10
    try testing.expect(doc.operations[0].variables[0].default_value != null);
    try testing.expectEqual(@as(i64, 10), doc.operations[0].variables[0].default_value.?.int);

    // after: String (no default)
    try testing.expect(doc.operations[0].variables[1].default_value == null);

    // owner: String! (no default, required)
    try testing.expect(doc.operations[0].variables[2].default_value == null);
    try testing.expect(doc.operations[0].variables[2].required == true);
}

test "parse different variable types" {
    const allocator = testing.allocator;

    const query =
        \\query Test($str: String!, $int: Int!, $float: Float!, $bool: Boolean!, $id: ID!) {
        \\  test
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    try testing.expectEqual(@as(usize, 5), doc.operations[0].variables.len);
    try testing.expectEqualStrings("String", doc.operations[0].variables[0].type_name);
    try testing.expectEqualStrings("Int", doc.operations[0].variables[1].type_name);
    try testing.expectEqualStrings("Float", doc.operations[0].variables[2].type_name);
    try testing.expectEqualStrings("Boolean", doc.operations[0].variables[3].type_name);
    try testing.expectEqualStrings("ID", doc.operations[0].variables[4].type_name);
}

test "VariableDefinition typeString for simple types" {
    const allocator = testing.allocator;

    const query =
        \\query Test($a: String, $b: String!) {
        \\  test
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    // Nullable type
    const type_str_a = try doc.operations[0].variables[0].typeString(allocator);
    defer allocator.free(type_str_a);
    try testing.expectEqualStrings("String", type_str_a);

    // Required type
    const type_str_b = try doc.operations[0].variables[1].typeString(allocator);
    defer allocator.free(type_str_b);
    try testing.expectEqualStrings("String!", type_str_b);
}
