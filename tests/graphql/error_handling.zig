const std = @import("std");
const testing = std.testing;
const parser = @import("../../src/api/graphql_parser.zig");

// ============================================================================
// ERROR HANDLING TESTS
// Tests for GraphQL error types and validation error handling
// Note: Error response format (JSON with locations, path, extensions) is
// tested via integration tests as it requires the HTTP handler.
// ============================================================================

test "ValidationError enum has all expected error types" {
    // Verify all expected error types exist
    const errors = [_]parser.ValidationError{
        parser.ValidationError.MissingRequiredArgument,
        parser.ValidationError.InvalidArgumentType,
        parser.ValidationError.NullNotAllowed,
    };

    // Just verify they're all distinct
    try testing.expect(errors[0] != errors[1]);
    try testing.expect(errors[1] != errors[2]);
    try testing.expect(errors[0] != errors[2]);
}

test "ParseError enum has all expected error types" {
    // Verify all expected parse error types exist
    const errors = [_]parser.ParseError{
        parser.ParseError.UnexpectedToken,
        parser.ParseError.UnexpectedEndOfInput,
        parser.ParseError.InvalidSyntax,
        parser.ParseError.OutOfMemory,
    };

    // Just verify they're all distinct
    try testing.expect(errors[0] != errors[1]);
    try testing.expect(errors[1] != errors[2]);
    try testing.expect(errors[2] != errors[3]);
}

test "parser returns error for invalid syntax - unclosed brace" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  domain(id: "test.eth") {
        \\    name
        \\
    ;

    const result = parser.parseQuery(allocator, query);
    try testing.expectError(parser.ParseError.UnexpectedEndOfInput, result);
}

test "parser returns error for invalid syntax - missing field name" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  (id: "test.eth") {
        \\    name
        \\  }
        \\}
    ;

    const result = parser.parseQuery(allocator, query);
    try testing.expectError(parser.ParseError.InvalidSyntax, result);
}

test "getRequiredStringArg propagates validation error" {
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

test "getRequiredIntArg propagates type mismatch error" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  domains(first: "not a number") {
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

test "validateValueType returns specific error for null in required field" {
    const value = parser.Value.null_value;
    const result = parser.validateValueType(value, "String", true);
    try testing.expectError(parser.ValidationError.NullNotAllowed, result);
}

test "validateValueType returns specific error for type mismatch" {
    const value = parser.Value{ .string = "hello" };
    const result = parser.validateValueType(value, "Int", false);
    try testing.expectError(parser.ValidationError.InvalidArgumentType, result);
}

test "parser handles empty query gracefully" {
    const allocator = testing.allocator;

    const query = "";
    const result = parser.parseQuery(allocator, query);
    try testing.expectError(parser.ParseError.UnexpectedEndOfInput, result);
}

test "parser handles whitespace-only query" {
    const allocator = testing.allocator;

    const query = "   \n\t  ";
    const result = parser.parseQuery(allocator, query);
    try testing.expectError(parser.ParseError.UnexpectedEndOfInput, result);
}

test "parser handles query with only comments" {
    const allocator = testing.allocator;

    const query =
        \\# This is a comment
        \\# Another comment
    ;

    const result = parser.parseQuery(allocator, query);
    try testing.expectError(parser.ParseError.UnexpectedEndOfInput, result);
}

test "multiple validation errors can be detected sequentially" {
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

    // First check for required string arg
    const result1 = parser.getRequiredStringArg(field, "id");
    try testing.expectError(parser.ValidationError.MissingRequiredArgument, result1);

    // Then check for another missing arg
    const result2 = parser.getRequiredIntArg(field, "limit");
    try testing.expectError(parser.ValidationError.MissingRequiredArgument, result2);
}
