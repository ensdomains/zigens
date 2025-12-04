const std = @import("std");
const testing = std.testing;
const parser = @import("graphql_parser.zig");

// ============================================================================
// VARIABLE PARSING TESTS
// ============================================================================

test "parse query with single variable definition" {
    const allocator = testing.allocator;

    const query =
        \\query($id: String!) {
        \\  domain(id: $id) {
        \\    name
        \\  }
        \\}
    ;

    var p = try parser.Parser.init(allocator, query);
    var document = try p.parseDocument();
    defer document.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), document.operations.len);
    const operation = document.operations[0];

    // Check variable definition
    try testing.expectEqual(@as(usize, 1), operation.variables.len);
    const var_def = operation.variables[0];
    try testing.expectEqualStrings("id", var_def.name);
    try testing.expectEqualStrings("String", var_def.type_name);
    try testing.expect(var_def.required);
}

test "parse query with multiple variable definitions" {
    const allocator = testing.allocator;

    const query =
        \\query($first: Int!, $pattern: String) {
        \\  domains(first: $first, where: {name_contains_nocase: $pattern}) {
        \\    name
        \\  }
        \\}
    ;

    var p = try parser.Parser.init(allocator, query);
    var document = try p.parseDocument();
    defer document.deinit(allocator);

    const operation = document.operations[0];

    // Check we have 2 variables
    try testing.expectEqual(@as(usize, 2), operation.variables.len);

    // Check first variable
    const var1 = operation.variables[0];
    try testing.expectEqualStrings("first", var1.name);
    try testing.expectEqualStrings("Int", var1.type_name);
    try testing.expect(var1.required);

    // Check second variable
    const var2 = operation.variables[1];
    try testing.expectEqualStrings("pattern", var2.name);
    try testing.expectEqualStrings("String", var2.type_name);
    try testing.expect(!var2.required); // Not required (no !)
}

test "parse variable reference in arguments" {
    const allocator = testing.allocator;

    const query =
        \\query($limit: Int!) {
        \\  domains(first: $limit) {
        \\    name
        \\  }
        \\}
    ;

    var p = try parser.Parser.init(allocator, query);
    var document = try p.parseDocument();
    defer document.deinit(allocator);

    const operation = document.operations[0];
    const field = operation.fields[0];

    // Check argument uses variable
    try testing.expectEqual(@as(usize, 1), field.arguments.len);
    const arg = field.arguments[0];
    try testing.expectEqualStrings("first", arg.name);
    try testing.expect(arg.value == .variable);
    try testing.expectEqualStrings("limit", arg.value.variable);
}

test "parse query with optional variable" {
    const allocator = testing.allocator;

    const query =
        \\query($filter: String) {
        \\  domains(where: {name_contains_nocase: $filter}) {
        \\    name
        \\  }
        \\}
    ;

    var p = try parser.Parser.init(allocator, query);
    var document = try p.parseDocument();
    defer document.deinit(allocator);

    const operation = document.operations[0];
    try testing.expectEqual(@as(usize, 1), operation.variables.len);

    const var_def = operation.variables[0];
    try testing.expectEqualStrings("filter", var_def.name);
    try testing.expectEqualStrings("String", var_def.type_name);
    try testing.expect(!var_def.required); // Optional (no !)
}

test "parse query with mixed literal and variable arguments" {
    const allocator = testing.allocator;

    const query =
        \\query($limit: Int!) {
        \\  domains(first: $limit, skip: 10) {
        \\    name
        \\  }
        \\}
    ;

    var p = try parser.Parser.init(allocator, query);
    var document = try p.parseDocument();
    defer document.deinit(allocator);

    const field = document.operations[0].fields[0];
    try testing.expectEqual(@as(usize, 2), field.arguments.len);

    // First argument is variable
    try testing.expect(field.arguments[0].value == .variable);
    try testing.expectEqualStrings("limit", field.arguments[0].value.variable);

    // Second argument is literal
    try testing.expect(field.arguments[1].value == .int);
    try testing.expectEqual(@as(i64, 10), field.arguments[1].value.int);
}

// ============================================================================
// INTEGRATION TESTS
// ============================================================================

test "parse query with variables and execute successfully" {
    const allocator = testing.allocator;

    // Test that a query with variables parses successfully
    const query =
        \\query($limit: Int!, $pattern: String) {
        \\  domains(first: $limit, where: {name_contains_nocase: $pattern}) {
        \\    name
        \\  }
        \\}
    ;

    var p = try parser.Parser.init(allocator, query);
    var document = try p.parseDocument();
    defer document.deinit(allocator);

    // Verify parsing succeeded
    try testing.expectEqual(@as(usize, 1), document.operations.len);
    const operation = document.operations[0];

    // Verify variables were parsed
    try testing.expectEqual(@as(usize, 2), operation.variables.len);

    // Verify field has variable references
    const field = operation.fields[0];
    var has_variable_arg = false;
    for (field.arguments) |arg| {
        if (arg.value == .variable) {
            has_variable_arg = true;
            break;
        }
    }
    try testing.expect(has_variable_arg);
}

test "query without variables still works" {
    const allocator = testing.allocator;

    // Test backward compatibility - queries without variables should still work
    const query =
        \\query {
        \\  domains(first: 10) {
        \\    name
        \\  }
        \\}
    ;

    var p = try parser.Parser.init(allocator, query);
    var document = try p.parseDocument();
    defer document.deinit(allocator);

    const operation = document.operations[0];

    // Should have no variables
    try testing.expectEqual(@as(usize, 0), operation.variables.len);

    // Field should have literal argument
    const field = operation.fields[0];
    try testing.expectEqual(@as(usize, 1), field.arguments.len);
    try testing.expect(field.arguments[0].value == .int);
}
