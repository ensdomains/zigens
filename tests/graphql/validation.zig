const std = @import("std");
const testing = std.testing;
const parser = @import("../../src/api/graphql_parser.zig");

// ============================================================================
// TYPE VALIDATION TESTS
// Tests for GraphQL argument type validation helpers
// ============================================================================

test "getRequiredStringArg returns string value" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  domain(id: "test.eth") {
        \\    name
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];
    const value = try parser.getRequiredStringArg(field, "id");
    try testing.expectEqualStrings("test.eth", value);
}

test "getRequiredStringArg returns error for missing argument" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  domain {
        \\    name
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];
    const result = parser.getRequiredStringArg(field, "id");
    try testing.expectError(parser.ValidationError.MissingRequiredArgument, result);
}

test "getRequiredStringArg returns error for wrong type" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  domain(id: 123) {
        \\    name
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];
    const result = parser.getRequiredStringArg(field, "id");
    try testing.expectError(parser.ValidationError.InvalidArgumentType, result);
}

test "getRequiredIntArg returns int value" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  domains(first: 10) {
        \\    name
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];
    const value = try parser.getRequiredIntArg(field, "first");
    try testing.expectEqual(@as(i64, 10), value);
}

test "getRequiredIntArg returns error for missing argument" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  domains {
        \\    name
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];
    const result = parser.getRequiredIntArg(field, "first");
    try testing.expectError(parser.ValidationError.MissingRequiredArgument, result);
}

test "getRequiredIntArg returns error for wrong type" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  domains(first: "ten") {
        \\    name
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];
    const result = parser.getRequiredIntArg(field, "first");
    try testing.expectError(parser.ValidationError.InvalidArgumentType, result);
}

test "getRequiredBoolArg returns bool value true" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  domains(active: true) {
        \\    name
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];
    const value = try parser.getRequiredBoolArg(field, "active");
    try testing.expect(value == true);
}

test "getRequiredBoolArg returns bool value false" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  domains(active: false) {
        \\    name
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];
    const value = try parser.getRequiredBoolArg(field, "active");
    try testing.expect(value == false);
}

test "getRequiredBoolArg returns error for wrong type" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  domains(active: "yes") {
        \\    name
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];
    const result = parser.getRequiredBoolArg(field, "active");
    try testing.expectError(parser.ValidationError.InvalidArgumentType, result);
}

test "validateValueType accepts correct String type" {
    const value = parser.Value{ .string = "test" };
    try parser.validateValueType(value, "String", false);
    try parser.validateValueType(value, "String", true);
}

test "validateValueType accepts correct Int type" {
    const value = parser.Value{ .int = 42 };
    try parser.validateValueType(value, "Int", false);
    try parser.validateValueType(value, "Int", true);
}

test "validateValueType accepts correct Boolean type" {
    const value = parser.Value{ .boolean = true };
    try parser.validateValueType(value, "Boolean", false);
    try parser.validateValueType(value, "Boolean", true);
}

test "validateValueType accepts Int for Float (coercion)" {
    const value = parser.Value{ .int = 42 };
    try parser.validateValueType(value, "Float", false);
}

test "validateValueType accepts Float for Float" {
    const value = parser.Value{ .float = 3.14 };
    try parser.validateValueType(value, "Float", false);
}

test "validateValueType accepts ID as String" {
    const value = parser.Value{ .string = "abc123" };
    try parser.validateValueType(value, "ID", false);
}

test "validateValueType rejects wrong type" {
    const value = parser.Value{ .string = "test" };
    const result = parser.validateValueType(value, "Int", false);
    try testing.expectError(parser.ValidationError.InvalidArgumentType, result);
}

test "validateValueType allows null for nullable type" {
    const value = parser.Value.null_value;
    try parser.validateValueType(value, "String", false);
}

test "validateValueType rejects null for required type" {
    const value = parser.Value.null_value;
    const result = parser.validateValueType(value, "String", true);
    try testing.expectError(parser.ValidationError.NullNotAllowed, result);
}

test "hasArg returns true when argument exists" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  domain(id: "test.eth") {
        \\    name
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];
    try testing.expect(parser.hasArg(field, "id") == true);
    try testing.expect(parser.hasArg(field, "nonexistent") == false);
}

test "getValueTypeName returns correct type names" {
    try testing.expectEqualStrings("Int", parser.getValueTypeName(parser.Value{ .int = 0 }));
    try testing.expectEqualStrings("Float", parser.getValueTypeName(parser.Value{ .float = 0.0 }));
    try testing.expectEqualStrings("String", parser.getValueTypeName(parser.Value{ .string = "" }));
    try testing.expectEqualStrings("Boolean", parser.getValueTypeName(parser.Value{ .boolean = true }));
    try testing.expectEqualStrings("Null", parser.getValueTypeName(parser.Value.null_value));
    try testing.expectEqualStrings("List", parser.getValueTypeName(parser.Value{ .list = &.{} }));
    try testing.expectEqualStrings("Object", parser.getValueTypeName(parser.Value{ .object = &.{} }));
    try testing.expectEqualStrings("Variable", parser.getValueTypeName(parser.Value{ .variable = "x" }));
}

test "getStringArg returns value or default" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  domain(id: "test.eth") {
        \\    name
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];

    // Existing arg returns value
    const id = parser.getStringArg(field, "id", "default");
    try testing.expectEqualStrings("test.eth", id.?);

    // Missing arg returns default
    const missing = parser.getStringArg(field, "nonexistent", "default");
    try testing.expectEqualStrings("default", missing.?);

    // Missing arg with null default returns null
    const null_default = parser.getStringArg(field, "nonexistent", null);
    try testing.expect(null_default == null);
}

test "getIntArg returns value or default" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  domains(first: 10) {
        \\    name
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];

    // Existing arg returns value
    const first = parser.getIntArg(field, "first", 100);
    try testing.expectEqual(@as(i64, 10), first.?);

    // Missing arg returns default
    const missing = parser.getIntArg(field, "nonexistent", 100);
    try testing.expectEqual(@as(i64, 100), missing.?);

    // Missing arg with null default returns null
    const null_default = parser.getIntArg(field, "nonexistent", null);
    try testing.expect(null_default == null);
}

test "getBoolArg returns value or default" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  domains(active: true) {
        \\    name
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];

    // Existing arg returns value
    const active = parser.getBoolArg(field, "active", false);
    try testing.expect(active.? == true);

    // Missing arg returns default
    const missing = parser.getBoolArg(field, "nonexistent", false);
    try testing.expect(missing.? == false);

    // Missing arg with null default returns null
    const null_default = parser.getBoolArg(field, "nonexistent", null);
    try testing.expect(null_default == null);
}
