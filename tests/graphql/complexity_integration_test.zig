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
    const analysis = try analyzer.analyzeDocument(&document);

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
    const analysis = try analyzer.analyzeDocument(&document);

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
    const analysis = try analyzer.analyzeDocument(&document);

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
    const analysis = try analyzer.analyzeDocument(&document);

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
    const analysis = try analyzer.analyzeDocument(&document);

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
    const strict_analysis = try strict_analyzer.analyzeDocument(&document);

    // Should fail with strict limits
    try testing.expect(!strict_analysis.isValid());

    // Lenient limits
    const lenient_limits = complexity.ComplexityLimits{
        .max_depth = 20,
        .max_cost = 10000,
    };
    var lenient_analyzer = complexity.ComplexityAnalyzer.init(allocator, lenient_limits);
    const lenient_analysis = try lenient_analyzer.analyzeDocument(&document);

    // Should pass with lenient limits
    try testing.expect(lenient_analysis.isValid());
}

test "variables do not affect complexity calculation" {
    const allocator = testing.allocator;

    // Query with variables
    const query =
        \\query($limit: Int!) {
        \\  domains(first: $limit) {
        \\    name
        \\    owner { id }
        \\  }
        \\}
    ;

    var document = try parser.parseQuery(allocator, query);
    defer document.deinit(allocator);

    const limits = complexity.ComplexityLimits{};
    var analyzer = complexity.ComplexityAnalyzer.init(allocator, limits);
    const analysis = try analyzer.analyzeDocument(&document);

    // Variables are not resolved during complexity analysis
    // So the multiplier will be 1 (default)
    try testing.expect(analysis.isValid());
    try testing.expect(analysis.cost < 10);
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

test "pagination argument caps at 100" {
    const allocator = testing.allocator;

    // Query with excessive pagination
    const query =
        \\query {
        \\  domains(first: 10000) {
        \\    name
        \\  }
        \\}
    ;

    var document = try parser.parseQuery(allocator, query);
    defer document.deinit(allocator);

    const limits = complexity.ComplexityLimits{};
    var analyzer = complexity.ComplexityAnalyzer.init(allocator, limits);
    const analysis = try analyzer.analyzeDocument(&document);

    // Multiplier should be capped at 100, not 10000
    // So cost should be reasonable (100 × 2 fields = 200)
    try testing.expect(analysis.cost < 300);
}
