const std = @import("std");
const testing = std.testing;
const parser = @import("../../src/api/graphql_parser.zig");

// ============================================================================
// LIST TYPE MODIFIER TESTS
// Tests for GraphQL list type parsing: [Type], [Type!], [Type]!, [Type!]!
// ============================================================================

test "parse nullable list of nullable items [String]" {
    const allocator = testing.allocator;

    const query =
        \\query GetDomains($ids: [String]) {
        \\  domains(ids: $ids) {
        \\    name
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const var_def = &doc.operations[0].variables[0];
    try testing.expectEqualStrings("ids", var_def.name);
    try testing.expectEqualStrings("String", var_def.type_name);
    try testing.expect(var_def.is_list == true);
    try testing.expect(var_def.list_item_required == false);
    try testing.expect(var_def.required == false);
}

test "parse nullable list of required items [String!]" {
    const allocator = testing.allocator;

    const query =
        \\query GetDomains($ids: [String!]) {
        \\  domains(ids: $ids) {
        \\    name
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const var_def = &doc.operations[0].variables[0];
    try testing.expectEqualStrings("ids", var_def.name);
    try testing.expectEqualStrings("String", var_def.type_name);
    try testing.expect(var_def.is_list == true);
    try testing.expect(var_def.list_item_required == true);
    try testing.expect(var_def.required == false);
}

test "parse required list of nullable items [String]!" {
    const allocator = testing.allocator;

    const query =
        \\query GetDomains($ids: [String]!) {
        \\  domains(ids: $ids) {
        \\    name
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const var_def = &doc.operations[0].variables[0];
    try testing.expectEqualStrings("ids", var_def.name);
    try testing.expectEqualStrings("String", var_def.type_name);
    try testing.expect(var_def.is_list == true);
    try testing.expect(var_def.list_item_required == false);
    try testing.expect(var_def.required == true);
}

test "parse required list of required items [String!]!" {
    const allocator = testing.allocator;

    const query =
        \\query GetDomains($ids: [String!]!) {
        \\  domains(ids: $ids) {
        \\    name
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const var_def = &doc.operations[0].variables[0];
    try testing.expectEqualStrings("ids", var_def.name);
    try testing.expectEqualStrings("String", var_def.type_name);
    try testing.expect(var_def.is_list == true);
    try testing.expect(var_def.list_item_required == true);
    try testing.expect(var_def.required == true);
}

test "parse list of Int type [Int!]!" {
    const allocator = testing.allocator;

    const query =
        \\query GetItems($limits: [Int!]!) {
        \\  items(limits: $limits) {
        \\    id
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const var_def = &doc.operations[0].variables[0];
    try testing.expectEqualStrings("limits", var_def.name);
    try testing.expectEqualStrings("Int", var_def.type_name);
    try testing.expect(var_def.is_list == true);
    try testing.expect(var_def.list_item_required == true);
    try testing.expect(var_def.required == true);
}

test "parse list of custom type [Domain!]" {
    const allocator = testing.allocator;

    const query =
        \\query GetRelated($domains: [Domain!]) {
        \\  related(domains: $domains) {
        \\    name
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const var_def = &doc.operations[0].variables[0];
    try testing.expectEqualStrings("domains", var_def.name);
    try testing.expectEqualStrings("Domain", var_def.type_name);
    try testing.expect(var_def.is_list == true);
    try testing.expect(var_def.list_item_required == true);
    try testing.expect(var_def.required == false);
}

test "parse simple type is not a list" {
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

    const var_def = &doc.operations[0].variables[0];
    try testing.expect(var_def.is_list == false);
    try testing.expect(var_def.list_item_required == false);
}

test "parse mixed list and non-list variables" {
    const allocator = testing.allocator;

    const query =
        \\query GetDomains($id: String!, $ids: [String!]!, $limit: Int) {
        \\  domains(id: $id, ids: $ids, limit: $limit) {
        \\    name
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    try testing.expectEqual(@as(usize, 3), doc.operations[0].variables.len);

    // $id: String! - not a list
    const id_var = &doc.operations[0].variables[0];
    try testing.expect(id_var.is_list == false);
    try testing.expect(id_var.required == true);

    // $ids: [String!]! - required list of required strings
    const ids_var = &doc.operations[0].variables[1];
    try testing.expect(ids_var.is_list == true);
    try testing.expect(ids_var.list_item_required == true);
    try testing.expect(ids_var.required == true);

    // $limit: Int - nullable non-list
    const limit_var = &doc.operations[0].variables[2];
    try testing.expect(limit_var.is_list == false);
    try testing.expect(limit_var.required == false);
}

test "VariableDefinition typeString for list types" {
    const allocator = testing.allocator;

    const query =
        \\query Test($a: [String], $b: [String!], $c: [String]!, $d: [String!]!) {
        \\  test
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    // [String]
    const type_a = try doc.operations[0].variables[0].typeString(allocator);
    defer allocator.free(type_a);
    try testing.expectEqualStrings("[String]", type_a);

    // [String!]
    const type_b = try doc.operations[0].variables[1].typeString(allocator);
    defer allocator.free(type_b);
    try testing.expectEqualStrings("[String!]", type_b);

    // [String]!
    const type_c = try doc.operations[0].variables[2].typeString(allocator);
    defer allocator.free(type_c);
    try testing.expectEqualStrings("[String]!", type_c);

    // [String!]!
    const type_d = try doc.operations[0].variables[3].typeString(allocator);
    defer allocator.free(type_d);
    try testing.expectEqualStrings("[String!]!", type_d);
}

test "parse list type with default value" {
    const allocator = testing.allocator;

    // Note: List defaults are currently not fully supported (returns null)
    // This test documents the current behavior
    const query =
        \\query GetDomains($ids: [String!] = ["a", "b"]) {
        \\  domains(ids: $ids) {
        \\    name
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const var_def = &doc.operations[0].variables[0];
    try testing.expect(var_def.is_list == true);
    // Default value is parsed as a list
    try testing.expect(var_def.default_value != null);
    try testing.expect(var_def.default_value.? == .list);
}
