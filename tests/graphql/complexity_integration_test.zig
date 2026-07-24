const std = @import("std");
const testing = std.testing;
const graphql = @import("graphql");
const parser = graphql.parser;
const complexity = graphql.complexity;

// ============================================================================
// INTEGRATION TESTS - Query Complexity with Real Queries
// ============================================================================

test "normal query passes complexity check" {
    const allocator = testing.allocator;

    // Realistic query that should pass
    const query =
        \\query {
        \\  domains(first: 2) {
        \\    name
        \\    owner { id }
        \\  }
        \\}
    ;

    var document = try parser.parseQuery(allocator, query);
    defer document.deinit(allocator);

    const limits = complexity.ComplexityLimits{
        .max_depth = 10,
        .max_cost = 1000,
    };
    var analyzer = complexity.ComplexityAnalyzer.init(allocator, limits);
    const analysis = try analyzer.analyzeDocument(&document, null);

    // Should be within limits
    try testing.expect(analysis.isValid());
    try testing.expect(analysis.depth <= 10);
    try testing.expect(analysis.cost <= 1000);

    // Verify reasonable cost (2 domains × 4 fields ≈ 8)
    try testing.expect(analysis.cost < 20);
}

test "expensive nested query is rejected" {
    const allocator = testing.allocator;

    // Very expensive query with nested pagination
    const query =
        \\query {
        \\  domains(first: 100) {
        \\    name
        \\    owner { id }
        \\    resolver { address }
        \\    registrant { id }
        \\    subdomains(first: 100) {
        \\      name
        \\      owner { id }
        \\    }
        \\  }
        \\}
    ;

    var document = try parser.parseQuery(allocator, query);
    defer document.deinit(allocator);

    const limits = complexity.ComplexityLimits{
        .max_depth = 10,
        .max_cost = 1000,
    };
    var analyzer = complexity.ComplexityAnalyzer.init(allocator, limits);
    const analysis = try analyzer.analyzeDocument(&document, null);

    // Should exceed cost limit
    try testing.expect(!analysis.isValid());
    try testing.expect(analysis.exceeded_cost);
    try testing.expect(analysis.cost > 1000);

    // Verify error message contains cost
    const error_msg = try analysis.errorMessage(allocator);
    defer allocator.free(error_msg);
    try testing.expect(std.mem.indexOf(u8, error_msg, "complexity") != null);
    try testing.expect(std.mem.indexOf(u8, error_msg, "exceeds") != null);
}

test "query with moderate pagination is allowed" {
    const allocator = testing.allocator;

    // Moderate query that should pass
    const query =
        \\query {
        \\  domains(first: 10) {
        \\    name
        \\    owner { id }
        \\    subdomains(first: 10) {
        \\      name
        \\    }
        \\  }
        \\}
    ;

    var document = try parser.parseQuery(allocator, query);
    defer document.deinit(allocator);

    const limits = complexity.ComplexityLimits{
        .max_depth = 10,
        .max_cost = 1000,
    };
    var analyzer = complexity.ComplexityAnalyzer.init(allocator, limits);
    const analysis = try analyzer.analyzeDocument(&document, null);

    // Should be within limits
    try testing.expect(analysis.isValid());
    try testing.expect(!analysis.exceeded_cost);
    try testing.expect(!analysis.exceeded_depth);
}

test "query with no pagination has low cost" {
    const allocator = testing.allocator;

    // Single domain query without pagination
    const query =
        \\query {
        \\  domain(id: "test.eth") {
        \\    name
        \\    owner { id }
        \\    resolver { address }
        \\  }
        \\}
    ;

    var document = try parser.parseQuery(allocator, query);
    defer document.deinit(allocator);

    const limits = complexity.ComplexityLimits{};
    var analyzer = complexity.ComplexityAnalyzer.init(allocator, limits);
    const analysis = try analyzer.analyzeDocument(&document, null);

    // Should be very cheap
    try testing.expect(analysis.isValid());
    try testing.expect(analysis.cost < 10);
    try testing.expect(analysis.depth <= 3);
}

test "multiple root fields sum complexity" {
    const allocator = testing.allocator;

    // Query with multiple root operations
    const query =
        \\query {
        \\  domains(first: 10) { name }
        \\  registrations(first: 10) { name }
        \\  events(first: 10) { id type }
        \\}
    ;

    var document = try parser.parseQuery(allocator, query);
    defer document.deinit(allocator);

    const limits = complexity.ComplexityLimits{};
    var analyzer = complexity.ComplexityAnalyzer.init(allocator, limits);
    const analysis = try analyzer.analyzeDocument(&document, null);

    // Should sum all operations
    try testing.expect(analysis.isValid());
    try testing.expect(analysis.cost > 10); // More than single operation
    try testing.expect(analysis.cost < 100); // But still reasonable
}

test "complexity limits can be customized" {
    const allocator = testing.allocator;

    const query =
        \\query {
        \\  domains(first: 50) {
        \\    name
        \\    owner { id }
        \\  }
        \\}
    ;

    var document = try parser.parseQuery(allocator, query);
    defer document.deinit(allocator);

    // Very strict limits
    const strict_limits = complexity.ComplexityLimits{
        .max_depth = 5,
        .max_cost = 100,
    };
    var strict_analyzer = complexity.ComplexityAnalyzer.init(allocator, strict_limits);
    const strict_analysis = try strict_analyzer.analyzeDocument(&document, null);

    // Should fail with strict limits
    try testing.expect(!strict_analysis.isValid());

    // Lenient limits
    const lenient_limits = complexity.ComplexityLimits{
        .max_depth = 20,
        .max_cost = 10000,
    };
    var lenient_analyzer = complexity.ComplexityAnalyzer.init(allocator, lenient_limits);
    const lenient_analysis = try lenient_analyzer.analyzeDocument(&document, null);

    // Should pass with lenient limits
    try testing.expect(lenient_analysis.isValid());
}

test "first: $var resolves from runtime variables, worst-case without them" {
    const allocator = testing.allocator;

    const var_query =
        \\query($limit: Int!) {
        \\  domains(first: $limit) {
        \\    name
        \\    owner { id }
        \\  }
        \\}
    ;
    const inline_query =
        \\query {
        \\  domains(first: 2) {
        \\    name
        \\    owner { id }
        \\  }
        \\}
    ;

    var var_doc = try parser.parseQuery(allocator, var_query);
    defer var_doc.deinit(allocator);
    var inline_doc = try parser.parseQuery(allocator, inline_query);
    defer inline_doc.deinit(allocator);

    const limits = complexity.ComplexityLimits{};

    // With the runtime value bound, the parameterized query costs exactly what
    // the inline literal costs — benign clients with small pages pay small cost.
    var parsed_vars = try std.json.parseFromSlice(std.json.Value, allocator, "{\"limit\":2}", .{});
    defer parsed_vars.deinit();
    var var_analyzer = complexity.ComplexityAnalyzer.init(allocator, limits);
    const var_analysis = try var_analyzer.analyzeDocument(&var_doc, parsed_vars.value);
    var inline_analyzer = complexity.ComplexityAnalyzer.init(allocator, limits);
    const inline_analysis = try inline_analyzer.analyzeDocument(&inline_doc, null);
    try testing.expectEqual(inline_analysis.cost, var_analysis.cost);

    // Without a value the analyzer must assume the worst case, not multiplier 1 —
    // otherwise parameterizing every page size bypasses cost analysis entirely.
    var blind_analyzer = complexity.ComplexityAnalyzer.init(allocator, limits);
    const blind_analysis = try blind_analyzer.analyzeDocument(&var_doc, null);
    try testing.expect(blind_analysis.cost >= limits.max_pagination_assumption);
    try testing.expect(blind_analysis.cost > var_analysis.cost);
}

test "complexity error message format" {
    const allocator = testing.allocator;

    // Test depth exceeded
    {
        const depth_analysis = complexity.ComplexityAnalysis{
            .depth = 15,
            .cost = 100,
            .exceeded_depth = true,
            .exceeded_cost = false,
        };

        const msg = try depth_analysis.errorMessage(allocator);
        defer allocator.free(msg);

        try testing.expect(std.mem.indexOf(u8, msg, "depth") != null);
        try testing.expect(std.mem.indexOf(u8, msg, "15") != null);
    }

    // Test cost exceeded
    {
        const cost_analysis = complexity.ComplexityAnalysis{
            .depth = 5,
            .cost = 5000,
            .exceeded_depth = false,
            .exceeded_cost = true,
        };

        const msg = try cost_analysis.errorMessage(allocator);
        defer allocator.free(msg);

        try testing.expect(std.mem.indexOf(u8, msg, "complexity") != null);
        try testing.expect(std.mem.indexOf(u8, msg, "5000") != null);
    }

    // Test valid query
    {
        const valid_analysis = complexity.ComplexityAnalysis{
            .depth = 3,
            .cost = 50,
            .exceeded_depth = false,
            .exceeded_cost = false,
        };

        const msg = try valid_analysis.errorMessage(allocator);
        defer allocator.free(msg);

        try testing.expect(std.mem.indexOf(u8, msg, "within limits") != null);
    }
}

test "pagination multiplier is uncapped: oversized first pays proportionally" {
    const allocator = testing.allocator;

    const big_query =
        \\query {
        \\  domains(first: 10000) {
        \\    name
        \\  }
        \\}
    ;
    const page_query =
        \\query {
        \\  domains(first: 100) {
        \\    name
        \\  }
        \\}
    ;

    var big_doc = try parser.parseQuery(allocator, big_query);
    defer big_doc.deinit(allocator);
    var page_doc = try parser.parseQuery(allocator, page_query);
    defer page_doc.deinit(allocator);

    const ceiling_query =
        \\query {
        \\  domains(first: 1000) {
        \\    name
        \\  }
        \\}
    ;
    var ceiling_doc = try parser.parseQuery(allocator, ceiling_query);
    defer ceiling_doc.deinit(allocator);

    const limits = complexity.ComplexityLimits{};
    var big_analyzer = complexity.ComplexityAnalyzer.init(allocator, limits);
    const big_analysis = try big_analyzer.analyzeDocument(&big_doc, null);
    var page_analyzer = complexity.ComplexityAnalyzer.init(allocator, limits);
    const page_analysis = try page_analyzer.analyzeDocument(&page_doc, null);
    var ceiling_analyzer = complexity.ComplexityAnalyzer.init(allocator, limits);
    const ceiling_analysis = try ceiling_analyzer.analyzeDocument(&ceiling_doc, null);

    // Page size prices proportionally up to max_pagination_assumption (1000),
    // then clamps: `first: 10000` costs exactly what `first: 1000` costs, and
    // both dwarf a default-page query. A default-page query stays valid.
    try testing.expectEqual(ceiling_analysis.cost, big_analysis.cost);
    try testing.expect(big_analysis.cost >= limits.max_pagination_assumption);
    try testing.expect(big_analysis.cost > page_analysis.cost);
    try testing.expect(page_analysis.isValid());
}
