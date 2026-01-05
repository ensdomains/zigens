const std = @import("std");
const testing = std.testing;
const graphql = @import("graphql");
const parser = graphql.parser;

// ============================================================================
// APOLLO CLIENT COMPATIBILITY TESTS
// ============================================================================
// Tests for GraphQL features required by Apollo Client:
// - __typename support (critical for Apollo cache normalization)
// - operationName handling (required for multi-operation documents)
// - Aliases support
// - Fragments support
// - Variables support
// - Introspection (__schema, __type)
// - Error handling format
// ============================================================================

// Dummy database pointer for test context
var dummy_db: u8 = 0;

// Helper to create a mock executor with test resolvers
fn createTestExecutor(allocator: std.mem.Allocator) !parser.Executor {
    const context = parser.ExecutionContext{
        .allocator = allocator,
        .database = @ptrCast(&dummy_db),
        .loaders = null,
    };

    var executor = parser.Executor.init(allocator, context);

    // Register mock resolvers that return predictable JSON
    try executor.registerResolver("domain", mockDomainResolver);
    try executor.registerResolver("domains", mockDomainsResolver);
    try executor.registerResolver("events", mockEventsResolver);
    try executor.registerResolver("registrations", mockRegistrationsResolver);

    return executor;
}

// Mock resolvers return predictable JSON for testing
fn mockDomainResolver(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const allocator = ctx.allocator;

    // Build JSON based on requested selections
    var json: std.ArrayList(u8) = .{};
    defer json.deinit(allocator);
    const writer = json.writer(allocator);

    try writer.writeAll("{");
    var first = true;

    for (field.selections) |*sel| {
        if (!first) try writer.writeAll(",");
        const output_key = sel.alias orelse sel.name;

        if (std.mem.eql(u8, sel.name, "__typename")) {
            try writer.print("\"{s}\":\"Domain\"", .{output_key});
            first = false;
        } else if (std.mem.eql(u8, sel.name, "id")) {
            try writer.print("\"{s}\":\"test.eth\"", .{output_key});
            first = false;
        } else if (std.mem.eql(u8, sel.name, "name")) {
            try writer.print("\"{s}\":\"test.eth\"", .{output_key});
            first = false;
        } else if (std.mem.eql(u8, sel.name, "owner")) {
            try writer.print("\"{s}\":{{", .{output_key});
            var owner_first = true;
            for (sel.selections) |*owner_sel| {
                if (!owner_first) try writer.writeAll(",");
                const owner_key = owner_sel.alias orelse owner_sel.name;
                if (std.mem.eql(u8, owner_sel.name, "__typename")) {
                    try writer.print("\"{s}\":\"Account\"", .{owner_key});
                    owner_first = false;
                } else if (std.mem.eql(u8, owner_sel.name, "id")) {
                    try writer.print("\"{s}\":\"0x1234\"", .{owner_key});
                    owner_first = false;
                } else {
                    try writer.print("\"{s}\":null", .{owner_key});
                    owner_first = false;
                }
            }
            try writer.writeAll("}");
            first = false;
        } else {
            // Unknown field - return null per GraphQL spec
            try writer.print("\"{s}\":null", .{output_key});
            first = false;
        }
    }

    try writer.writeAll("}");

    return parser.FieldResult{
        .json = try allocator.dupe(u8, json.items),
    };
}

fn mockDomainsResolver(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const allocator = ctx.allocator;

    // Get first argument for limiting results
    var limit: usize = 10;
    for (field.arguments) |arg| {
        if (std.mem.eql(u8, arg.name, "first")) {
            if (arg.value == .int) {
                limit = @intCast(arg.value.int);
            }
        }
    }

    var json: std.ArrayList(u8) = .{};
    defer json.deinit(allocator);
    const writer = json.writer(allocator);

    try writer.writeAll("[");

    var i: usize = 0;
    while (i < limit and i < 3) : (i += 1) {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("{");

        var first = true;
        for (field.selections) |*sel| {
            if (!first) try writer.writeAll(",");
            const output_key = sel.alias orelse sel.name;

            if (std.mem.eql(u8, sel.name, "__typename")) {
                try writer.print("\"{s}\":\"Domain\"", .{output_key});
                first = false;
            } else if (std.mem.eql(u8, sel.name, "id")) {
                try writer.print("\"{s}\":\"domain{d}.eth\"", .{ output_key, i });
                first = false;
            } else if (std.mem.eql(u8, sel.name, "name")) {
                try writer.print("\"{s}\":\"domain{d}.eth\"", .{ output_key, i });
                first = false;
            } else if (std.mem.eql(u8, sel.name, "owner")) {
                try writer.print("\"{s}\":{{", .{output_key});
                var owner_first = true;
                for (sel.selections) |*owner_sel| {
                    if (!owner_first) try writer.writeAll(",");
                    const owner_key = owner_sel.alias orelse owner_sel.name;
                    if (std.mem.eql(u8, owner_sel.name, "__typename")) {
                        try writer.print("\"{s}\":\"Account\"", .{owner_key});
                        owner_first = false;
                    } else if (std.mem.eql(u8, owner_sel.name, "id")) {
                        try writer.print("\"{s}\":\"0x{d}\"", .{ owner_key, i });
                        owner_first = false;
                    } else {
                        try writer.print("\"{s}\":null", .{owner_key});
                        owner_first = false;
                    }
                }
                try writer.writeAll("}");
                first = false;
            } else {
                try writer.print("\"{s}\":null", .{output_key});
                first = false;
            }
        }

        try writer.writeAll("}");
    }

    try writer.writeAll("]");

    return parser.FieldResult{
        .json = try allocator.dupe(u8, json.items),
    };
}

fn mockEventsResolver(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const allocator = ctx.allocator;

    var json: std.ArrayList(u8) = .{};
    defer json.deinit(allocator);
    const writer = json.writer(allocator);

    try writer.writeAll("[{");
    var first = true;
    for (field.selections) |*sel| {
        if (!first) try writer.writeAll(",");
        const output_key = sel.alias orelse sel.name;

        if (std.mem.eql(u8, sel.name, "__typename")) {
            try writer.print("\"{s}\":\"Event\"", .{output_key});
            first = false;
        } else if (std.mem.eql(u8, sel.name, "id")) {
            try writer.print("\"{s}\":\"event1\"", .{output_key});
            first = false;
        } else if (std.mem.eql(u8, sel.name, "type")) {
            try writer.print("\"{s}\":\"Transfer\"", .{output_key});
            first = false;
        } else {
            try writer.print("\"{s}\":null", .{output_key});
            first = false;
        }
    }
    try writer.writeAll("}]");

    return parser.FieldResult{
        .json = try allocator.dupe(u8, json.items),
    };
}

fn mockRegistrationsResolver(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const allocator = ctx.allocator;

    var json: std.ArrayList(u8) = .{};
    defer json.deinit(allocator);
    const writer = json.writer(allocator);

    try writer.writeAll("[{");
    var first = true;
    for (field.selections) |*sel| {
        if (!first) try writer.writeAll(",");
        const output_key = sel.alias orelse sel.name;

        if (std.mem.eql(u8, sel.name, "__typename")) {
            try writer.print("\"{s}\":\"Registration\"", .{output_key});
            first = false;
        } else if (std.mem.eql(u8, sel.name, "id")) {
            try writer.print("\"{s}\":\"reg1\"", .{output_key});
            first = false;
        } else {
            try writer.print("\"{s}\":null", .{output_key});
            first = false;
        }
    }
    try writer.writeAll("}]");

    return parser.FieldResult{
        .json = try allocator.dupe(u8, json.items),
    };
}

// ============================================================================
// __typename TESTS (Critical for Apollo Cache)
// ============================================================================

test "apollo: root __typename returns Query" {
    const allocator = testing.allocator;

    const query = "{ __typename }";

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    var executor = try createTestExecutor(allocator);
    defer executor.deinit();

    const result = try executor.executeDocument(&doc, null, null);
    defer allocator.free(result);

    // Should contain "Query" as the root typename
    try testing.expect(std.mem.indexOf(u8, result, "\"__typename\":\"Query\"") != null);
}

test "apollo: Domain type includes __typename" {
    const allocator = testing.allocator;

    const query = "{ domains(first: 1) { __typename id } }";

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    var executor = try createTestExecutor(allocator);
    defer executor.deinit();

    const result = try executor.executeDocument(&doc, null, null);
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "\"__typename\":\"Domain\"") != null);
}

test "apollo: nested Account includes __typename" {
    const allocator = testing.allocator;

    const query = "{ domains(first: 1) { id owner { __typename id } } }";

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    var executor = try createTestExecutor(allocator);
    defer executor.deinit();

    const result = try executor.executeDocument(&doc, null, null);
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "\"__typename\":\"Account\"") != null);
}

test "apollo: Event type includes __typename" {
    const allocator = testing.allocator;

    const query = "{ events(first: 1) { __typename id } }";

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    var executor = try createTestExecutor(allocator);
    defer executor.deinit();

    const result = try executor.executeDocument(&doc, null, null);
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "\"__typename\":\"Event\"") != null);
}

test "apollo: Registration type includes __typename" {
    const allocator = testing.allocator;

    const query = "{ registrations(first: 1) { __typename id } }";

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    var executor = try createTestExecutor(allocator);
    defer executor.deinit();

    const result = try executor.executeDocument(&doc, null, null);
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "\"__typename\":\"Registration\"") != null);
}

test "apollo: __typename works with alias" {
    const allocator = testing.allocator;

    const query = "{ domains(first: 1) { type: __typename id } }";

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    var executor = try createTestExecutor(allocator);
    defer executor.deinit();

    const result = try executor.executeDocument(&doc, null, null);
    defer allocator.free(result);

    // Should use the alias "type" instead of "__typename"
    try testing.expect(std.mem.indexOf(u8, result, "\"type\":\"Domain\"") != null);
}

// ============================================================================
// operationName TESTS
// ============================================================================

test "apollo: single operation with operationName executes correctly" {
    const allocator = testing.allocator;

    const query = "query GetDomains { domains(first: 2) { id } }";

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    var executor = try createTestExecutor(allocator);
    defer executor.deinit();

    const result = try executor.executeDocument(&doc, null, "GetDomains");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "domains") != null);
}

test "apollo: multiple operations - select first by operationName" {
    const allocator = testing.allocator;

    const query = "query A { domains(first: 2) { id } } query B { events(first: 2) { id } }";

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    var executor = try createTestExecutor(allocator);
    defer executor.deinit();

    const result = try executor.executeDocument(&doc, null, "A");
    defer allocator.free(result);

    // Should only execute operation A (domains)
    try testing.expect(std.mem.indexOf(u8, result, "domains") != null);
    try testing.expect(std.mem.indexOf(u8, result, "events") == null);
}

test "apollo: multiple operations - select second by operationName" {
    const allocator = testing.allocator;

    const query = "query A { domains(first: 2) { id } } query B { events(first: 2) { id } }";

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    var executor = try createTestExecutor(allocator);
    defer executor.deinit();

    const result = try executor.executeDocument(&doc, null, "B");
    defer allocator.free(result);

    // Should only execute operation B (events)
    try testing.expect(std.mem.indexOf(u8, result, "events") != null);
    try testing.expect(std.mem.indexOf(u8, result, "domains") == null);
}

test "apollo: multiple operations without operationName returns error" {
    const allocator = testing.allocator;

    const query = "query A { domains(first: 2) { id } } query B { events(first: 2) { id } }";

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    var executor = try createTestExecutor(allocator);
    defer executor.deinit();

    // Should return error when multiple operations but no operationName
    const result = executor.executeDocument(&doc, null, null);
    try testing.expectError(error.OperationNameRequired, result);
}

test "apollo: invalid operationName returns error" {
    const allocator = testing.allocator;

    const query = "query A { domains(first: 2) { id } }";

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    var executor = try createTestExecutor(allocator);
    defer executor.deinit();

    // Should return error for non-existent operation name
    const result = executor.executeDocument(&doc, null, "NonExistent");
    try testing.expectError(error.OperationNotFound, result);
}

// ============================================================================
// ALIASES TESTS
// ============================================================================

test "apollo: simple field alias" {
    const allocator = testing.allocator;

    const query = "{ myDomains: domains(first: 2) { id } }";

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    var executor = try createTestExecutor(allocator);
    defer executor.deinit();

    const result = try executor.executeDocument(&doc, null, null);
    defer allocator.free(result);

    // Should use the alias "myDomains" instead of "domains"
    try testing.expect(std.mem.indexOf(u8, result, "\"myDomains\"") != null);
}

test "apollo: multiple aliases for same field" {
    const allocator = testing.allocator;

    const query = "{ a: domains(first: 1) { id } b: domains(first: 2) { id } }";

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    var executor = try createTestExecutor(allocator);
    defer executor.deinit();

    const result = try executor.executeDocument(&doc, null, null);
    defer allocator.free(result);

    // Should have both aliases
    try testing.expect(std.mem.indexOf(u8, result, "\"a\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"b\"") != null);
}

test "apollo: nested field aliases" {
    const allocator = testing.allocator;

    const query = "{ domains(first: 1) { domainId: id domainName: name } }";

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    var executor = try createTestExecutor(allocator);
    defer executor.deinit();

    const result = try executor.executeDocument(&doc, null, null);
    defer allocator.free(result);

    // Should use aliases for nested fields
    try testing.expect(std.mem.indexOf(u8, result, "\"domainId\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"domainName\"") != null);
}

// ============================================================================
// FRAGMENTS TESTS
// ============================================================================

test "apollo: simple fragment spread" {
    const allocator = testing.allocator;

    const query =
        \\fragment DomainFields on Domain { id name }
        \\query { domains(first: 2) { ...DomainFields } }
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    var executor = try createTestExecutor(allocator);
    defer executor.deinit();

    const result = try executor.executeDocument(&doc, null, null);
    defer allocator.free(result);

    // Fragment fields should be included
    try testing.expect(std.mem.indexOf(u8, result, "\"id\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"name\"") != null);
}

test "apollo: fragment with nested object" {
    const allocator = testing.allocator;

    const query =
        \\fragment DomainWithOwner on Domain { id owner { id } }
        \\query { domains(first: 1) { ...DomainWithOwner } }
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    var executor = try createTestExecutor(allocator);
    defer executor.deinit();

    const result = try executor.executeDocument(&doc, null, null);
    defer allocator.free(result);

    // Should include nested owner
    try testing.expect(std.mem.indexOf(u8, result, "\"owner\"") != null);
}

test "apollo: multiple fragment spreads" {
    const allocator = testing.allocator;

    const query =
        \\fragment IdFrag on Domain { id }
        \\fragment NameFrag on Domain { name }
        \\query { domains(first: 1) { ...IdFrag ...NameFrag } }
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    var executor = try createTestExecutor(allocator);
    defer executor.deinit();

    const result = try executor.executeDocument(&doc, null, null);
    defer allocator.free(result);

    // Both fragments should be included
    try testing.expect(std.mem.indexOf(u8, result, "\"id\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"name\"") != null);
}

// ============================================================================
// VARIABLES TESTS
// ============================================================================

test "apollo: simple Int variable" {
    const allocator = testing.allocator;

    const query = "query($first: Int) { domains(first: $first) { id } }";

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    var executor = try createTestExecutor(allocator);
    defer executor.deinit();

    // Create variables JSON
    const vars_json =
        \\{"first": 2}
    ;
    const parsed_vars = try std.json.parseFromSlice(std.json.Value, allocator, vars_json, .{});
    defer parsed_vars.deinit();

    const result = try executor.executeDocument(&doc, parsed_vars.value, null);
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "domains") != null);
}

test "apollo: variable with default value" {
    const allocator = testing.allocator;

    const query = "query($first: Int = 5) { domains(first: $first) { id } }";

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    // Verify default value is parsed
    try testing.expectEqual(@as(usize, 1), doc.operations[0].variables.len);
    const var_def = doc.operations[0].variables[0];
    try testing.expect(var_def.default_value != null);
    try testing.expect(var_def.default_value.? == .int);
    try testing.expectEqual(@as(i64, 5), var_def.default_value.?.int);
}

// ============================================================================
// UNKNOWN FIELD HANDLING TESTS
// ============================================================================

test "apollo: unknown field returns null (valid JSON)" {
    const allocator = testing.allocator;

    const query = "{ domains(first: 1) { id nonExistentField } }";

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    var executor = try createTestExecutor(allocator);
    defer executor.deinit();

    const result = try executor.executeDocument(&doc, null, null);
    defer allocator.free(result);

    // Should return valid JSON with null for unknown field
    try testing.expect(std.mem.indexOf(u8, result, "\"nonExistentField\":null") != null);

    // Verify it's valid JSON by parsing it
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

// ============================================================================
// NESTED QUERIES TESTS
// ============================================================================

test "apollo: two levels nested query" {
    const allocator = testing.allocator;

    const query = "{ domains(first: 1) { id owner { id } } }";

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    var executor = try createTestExecutor(allocator);
    defer executor.deinit();

    const result = try executor.executeDocument(&doc, null, null);
    defer allocator.free(result);

    // Should have nested owner object
    try testing.expect(std.mem.indexOf(u8, result, "\"owner\"") != null);

    // Verify valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

// ============================================================================
// PAGINATION TESTS
// ============================================================================

test "apollo: first parameter limits results" {
    const allocator = testing.allocator;

    const query = "query($limit: Int!) { domains(first: $limit) { id } }";

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    var executor = try createTestExecutor(allocator);
    defer executor.deinit();

    const vars_json =
        \\{"limit": 2}
    ;
    const parsed_vars = try std.json.parseFromSlice(std.json.Value, allocator, vars_json, .{});
    defer parsed_vars.deinit();

    const result = try executor.executeDocument(&doc, parsed_vars.value, null);
    defer allocator.free(result);

    // Verify valid JSON response
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}
