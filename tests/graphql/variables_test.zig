const std = @import("std");
const testing = std.testing;
const graphql = @import("graphql");
const parser = graphql.parser;

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

// ============================================================================
// VARIABLE RESOLUTION TESTS (Executor-level)
// ============================================================================
// These tests verify that variables are correctly substituted at runtime,
// including variables nested inside object and list values.

test "executor resolves variable in simple argument" {
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

    // Create executor with mock context
    const ctx = parser.ExecutionContext{
        .allocator = allocator,
        .database = undefined,
        .loaders = null,
    };
    var executor = parser.Executor.init(allocator, ctx);
    defer executor.deinit();

    // Create variable map with test value
    var variables_map = std.StringHashMap(std.json.Value).init(allocator);
    defer variables_map.deinit();
    try variables_map.put("limit", std.json.Value{ .integer = 25 });

    // Set variables on executor
    executor.variables = &variables_map;

    // Resolve the field arguments
    const field = &document.operations[0].fields[0];
    const resolved_args = try executor.resolveFieldArguments(field);
    defer allocator.free(resolved_args);

    // Verify variable was resolved to the actual value
    try testing.expectEqual(@as(usize, 1), resolved_args.len);
    try testing.expectEqualStrings("first", resolved_args[0].name);
    try testing.expect(resolved_args[0].value == .int);
    try testing.expectEqual(@as(i64, 25), resolved_args[0].value.int);
}

test "executor resolves variable inside where object" {
    const allocator = testing.allocator;

    // This is the key test case - variable inside a where filter object
    const query =
        \\query($name: String!) {
        \\  domains(where: {name: $name}) {
        \\    name
        \\  }
        \\}
    ;

    var p = try parser.Parser.init(allocator, query);
    var document = try p.parseDocument();
    defer document.deinit(allocator);

    // Create executor with mock context
    const ctx = parser.ExecutionContext{
        .allocator = allocator,
        .database = undefined,
        .loaders = null,
    };
    var executor = parser.Executor.init(allocator, ctx);
    defer executor.deinit();

    // Create variable map with test value
    var variables_map = std.StringHashMap(std.json.Value).init(allocator);
    defer variables_map.deinit();
    try variables_map.put("name", std.json.Value{ .string = "test.eth" });

    // Set variables on executor
    executor.variables = &variables_map;

    // Resolve the field arguments
    const field = &document.operations[0].fields[0];
    const resolved_args = try executor.resolveFieldArguments(field);
    defer {
        // Need to free nested object allocations
        for (resolved_args) |arg| {
            if (arg.value == .object) {
                allocator.free(arg.value.object);
            }
        }
        allocator.free(resolved_args);
    }

    // Verify where argument was resolved
    try testing.expectEqual(@as(usize, 1), resolved_args.len);
    try testing.expectEqualStrings("where", resolved_args[0].name);
    try testing.expect(resolved_args[0].value == .object);

    // Check that the nested variable was resolved inside the object
    const where_obj = resolved_args[0].value.object;
    try testing.expectEqual(@as(usize, 1), where_obj.len);
    try testing.expectEqualStrings("name", where_obj[0].name);
    try testing.expect(where_obj[0].value == .string);
    try testing.expectEqualStrings("test.eth", where_obj[0].value.string);
}

test "executor resolves multiple variables inside where object" {
    const allocator = testing.allocator;

    const query =
        \\query($name: String!, $owner: String!) {
        \\  domains(where: {name: $name, owner: $owner}) {
        \\    name
        \\  }
        \\}
    ;

    var p = try parser.Parser.init(allocator, query);
    var document = try p.parseDocument();
    defer document.deinit(allocator);

    const ctx = parser.ExecutionContext{
        .allocator = allocator,
        .database = undefined,
        .loaders = null,
    };
    var executor = parser.Executor.init(allocator, ctx);
    defer executor.deinit();

    var variables_map = std.StringHashMap(std.json.Value).init(allocator);
    defer variables_map.deinit();
    try variables_map.put("name", std.json.Value{ .string = "example.eth" });
    try variables_map.put("owner", std.json.Value{ .string = "0x1234567890abcdef" });

    executor.variables = &variables_map;

    const field = &document.operations[0].fields[0];
    const resolved_args = try executor.resolveFieldArguments(field);
    defer {
        for (resolved_args) |arg| {
            if (arg.value == .object) {
                allocator.free(arg.value.object);
            }
        }
        allocator.free(resolved_args);
    }

    // Check where object has both resolved values
    const where_obj = resolved_args[0].value.object;
    try testing.expectEqual(@as(usize, 2), where_obj.len);

    // Find and verify each field (order may vary)
    var found_name = false;
    var found_owner = false;
    for (where_obj) |field_arg| {
        if (std.mem.eql(u8, field_arg.name, "name")) {
            try testing.expect(field_arg.value == .string);
            try testing.expectEqualStrings("example.eth", field_arg.value.string);
            found_name = true;
        } else if (std.mem.eql(u8, field_arg.name, "owner")) {
            try testing.expect(field_arg.value == .string);
            try testing.expectEqualStrings("0x1234567890abcdef", field_arg.value.string);
            found_owner = true;
        }
    }
    try testing.expect(found_name);
    try testing.expect(found_owner);
}

test "executor resolves variable inside list argument" {
    const allocator = testing.allocator;

    const query =
        \\query($owners: [String!]!) {
        \\  domains(where: {owner_in: $owners}) {
        \\    name
        \\  }
        \\}
    ;

    var p = try parser.Parser.init(allocator, query);
    var document = try p.parseDocument();
    defer document.deinit(allocator);

    const ctx = parser.ExecutionContext{
        .allocator = allocator,
        .database = undefined,
        .loaders = null,
    };
    var executor = parser.Executor.init(allocator, ctx);
    defer executor.deinit();

    // Create a JSON array value using std.json.Array (which is Managed(Value))
    var arr = std.json.Array.init(allocator);
    defer arr.deinit();
    try arr.append(std.json.Value{ .string = "0xabc" });
    try arr.append(std.json.Value{ .string = "0xdef" });

    var variables_map = std.StringHashMap(std.json.Value).init(allocator);
    defer variables_map.deinit();
    try variables_map.put("owners", std.json.Value{ .array = arr });

    executor.variables = &variables_map;

    const field = &document.operations[0].fields[0];
    const resolved_args = try executor.resolveFieldArguments(field);
    defer {
        for (resolved_args) |arg| {
            if (arg.value == .object) {
                for (arg.value.object) |obj_arg| {
                    if (obj_arg.value == .list) {
                        allocator.free(obj_arg.value.list);
                    }
                }
                allocator.free(arg.value.object);
            }
        }
        allocator.free(resolved_args);
    }

    // Verify the list was resolved inside the where object
    const where_obj = resolved_args[0].value.object;
    try testing.expectEqual(@as(usize, 1), where_obj.len);
    try testing.expectEqualStrings("owner_in", where_obj[0].name);
    try testing.expect(where_obj[0].value == .list);

    const list = where_obj[0].value.list;
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expect(list[0] == .string);
    try testing.expectEqualStrings("0xabc", list[0].string);
    try testing.expect(list[1] == .string);
    try testing.expectEqualStrings("0xdef", list[1].string);
}

test "executor resolves mixed literal and variable in where object" {
    const allocator = testing.allocator;

    const query =
        \\query($name: String!) {
        \\  domains(where: {name: $name, first: 10}) {
        \\    name
        \\  }
        \\}
    ;

    var p = try parser.Parser.init(allocator, query);
    var document = try p.parseDocument();
    defer document.deinit(allocator);

    const ctx = parser.ExecutionContext{
        .allocator = allocator,
        .database = undefined,
        .loaders = null,
    };
    var executor = parser.Executor.init(allocator, ctx);
    defer executor.deinit();

    var variables_map = std.StringHashMap(std.json.Value).init(allocator);
    defer variables_map.deinit();
    try variables_map.put("name", std.json.Value{ .string = "mixed.eth" });

    executor.variables = &variables_map;

    const field = &document.operations[0].fields[0];
    const resolved_args = try executor.resolveFieldArguments(field);
    defer {
        for (resolved_args) |arg| {
            if (arg.value == .object) {
                allocator.free(arg.value.object);
            }
        }
        allocator.free(resolved_args);
    }

    const where_obj = resolved_args[0].value.object;
    try testing.expectEqual(@as(usize, 2), where_obj.len);

    // Verify both variable and literal are correctly resolved
    var found_name = false;
    var found_first = false;
    for (where_obj) |field_arg| {
        if (std.mem.eql(u8, field_arg.name, "name")) {
            try testing.expect(field_arg.value == .string);
            try testing.expectEqualStrings("mixed.eth", field_arg.value.string);
            found_name = true;
        } else if (std.mem.eql(u8, field_arg.name, "first")) {
            try testing.expect(field_arg.value == .int);
            try testing.expectEqual(@as(i64, 10), field_arg.value.int);
            found_first = true;
        }
    }
    try testing.expect(found_name);
    try testing.expect(found_first);
}

test "executor fails on undefined variable" {
    const allocator = testing.allocator;

    const query =
        \\query($name: String!) {
        \\  domains(where: {name: $name}) {
        \\    name
        \\  }
        \\}
    ;

    var p = try parser.Parser.init(allocator, query);
    var document = try p.parseDocument();
    defer document.deinit(allocator);

    const ctx = parser.ExecutionContext{
        .allocator = allocator,
        .database = undefined,
        .loaders = null,
    };
    var executor = parser.Executor.init(allocator, ctx);
    defer executor.deinit();

    // Empty variable map - variable is not defined
    var variables_map = std.StringHashMap(std.json.Value).init(allocator);
    defer variables_map.deinit();

    executor.variables = &variables_map;

    const field = &document.operations[0].fields[0];

    // Should fail with UndefinedVariable error
    const result = executor.resolveFieldArguments(field);
    try testing.expectError(error.UndefinedVariable, result);
}
