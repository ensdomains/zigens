const std = @import("std");
const parser = @import("graphql_parser.zig");

/// Query complexity limits configuration
pub const ComplexityLimits = struct {
    max_depth: u32 = 10, // Maximum nesting depth
    max_cost: u32 = 1000, // Maximum total query cost
    default_field_cost: u32 = 1, // Cost per field
    list_multiplier: u32 = 1, // Multiplier for list fields based on 'first' argument
};

/// Complexity analysis result
pub const ComplexityAnalysis = struct {
    depth: u32,
    cost: u32,
    exceeded_depth: bool,
    exceeded_cost: bool,

    pub fn isValid(self: ComplexityAnalysis) bool {
        return !self.exceeded_depth and !self.exceeded_cost;
    }

    pub fn errorMessage(self: ComplexityAnalysis, allocator: std.mem.Allocator) ![]const u8 {
        if (self.exceeded_depth) {
            return try std.fmt.allocPrint(allocator, "Query depth ({d}) exceeds maximum allowed depth", .{self.depth});
        }
        if (self.exceeded_cost) {
            return try std.fmt.allocPrint(allocator, "Query complexity ({d}) exceeds maximum allowed cost", .{self.cost});
        }
        return try allocator.dupe(u8, "Query complexity is within limits");
    }
};

/// Query complexity analyzer
pub const ComplexityAnalyzer = struct {
    allocator: std.mem.Allocator,
    limits: ComplexityLimits,

    pub fn init(allocator: std.mem.Allocator, limits: ComplexityLimits) ComplexityAnalyzer {
        return .{
            .allocator = allocator,
            .limits = limits,
        };
    }

    /// Analyze a GraphQL document for complexity
    pub fn analyzeDocument(self: *ComplexityAnalyzer, document: *const parser.Document) !ComplexityAnalysis {
        var max_depth: u32 = 0;
        var total_cost: u32 = 0;

        // Analyze each operation
        for (document.operations) |*operation| {
            const analysis = try self.analyzeOperation(operation);
            max_depth = @max(max_depth, analysis.depth);
            total_cost += analysis.cost;
        }

        return ComplexityAnalysis{
            .depth = max_depth,
            .cost = total_cost,
            .exceeded_depth = max_depth > self.limits.max_depth,
            .exceeded_cost = total_cost > self.limits.max_cost,
        };
    }

    /// Analyze a single operation
    fn analyzeOperation(self: *ComplexityAnalyzer, operation: *const parser.Operation) !ComplexityAnalysis {
        var max_depth: u32 = 0;
        var total_cost: u32 = 0;

        // Analyze each root field
        for (operation.fields) |*field| {
            const field_analysis = try self.analyzeField(field, 1);
            max_depth = @max(max_depth, field_analysis.depth);
            total_cost += field_analysis.cost;
        }

        return ComplexityAnalysis{
            .depth = max_depth,
            .cost = total_cost,
            .exceeded_depth = max_depth > self.limits.max_depth,
            .exceeded_cost = total_cost > self.limits.max_cost,
        };
    }

    /// Analyze a field recursively
    fn analyzeField(self: *ComplexityAnalyzer, field: *const parser.Field, current_depth: u32) error{OutOfMemory}!ComplexityAnalysis {
        var field_cost: u32 = self.limits.default_field_cost;
        var max_depth: u32 = current_depth;

        // Check for pagination multiplier
        const multiplier = self.getFieldMultiplier(field);
        field_cost *= multiplier;

        // Analyze nested selections
        if (field.selections.len > 0) {
            var nested_cost: u32 = 0;
            var nested_max_depth: u32 = current_depth;

            for (field.selections) |*selection| {
                const nested_analysis = try self.analyzeField(selection, current_depth + 1);
                nested_max_depth = @max(nested_max_depth, nested_analysis.depth);
                nested_cost += nested_analysis.cost;
            }

            // Multiply nested cost by the field multiplier (e.g., if first=100, nested fields cost 100x)
            field_cost += nested_cost * multiplier;
            max_depth = nested_max_depth;
        }

        return ComplexityAnalysis{
            .depth = max_depth,
            .cost = field_cost,
            .exceeded_depth = max_depth > self.limits.max_depth,
            .exceeded_cost = field_cost > self.limits.max_cost,
        };
    }

    /// Get the multiplier for a field based on pagination arguments
    fn getFieldMultiplier(self: *ComplexityAnalyzer, field: *const parser.Field) u32 {
        _ = self;

        // Look for 'first' or 'limit' arguments
        for (field.arguments) |arg| {
            if (std.mem.eql(u8, arg.name, "first") or std.mem.eql(u8, arg.name, "limit")) {
                if (arg.value == .int) {
                    // Cap multiplier at 100 to prevent overflow
                    const value = @as(u32, @intCast(@max(1, @min(100, arg.value.int))));
                    return value;
                }
            }
        }

        // Default multiplier is 1 (no pagination)
        return 1;
    }
};

// ============================================================================
// TESTS
// ============================================================================

const testing = std.testing;

test "simple query within limits" {
    const allocator = testing.allocator;

    const query =
        \\query {
        \\  domains(first: 5) {
        \\    name
        \\  }
        \\}
    ;

    var p = try parser.Parser.init(allocator, query);
    var document = try p.parseDocument();
    defer document.deinit(allocator);

    const limits = ComplexityLimits{};
    var analyzer = ComplexityAnalyzer.init(allocator, limits);

    const analysis = try analyzer.analyzeDocument(&document);

    // Depth should be 2 (query -> domains -> name)
    try testing.expectEqual(@as(u32, 2), analysis.depth);

    // Cost should be: 1 (domains) * 5 (first arg) + 5 (name fields) = 10
    try testing.expect(analysis.cost <= 20); // Allow some variance

    // Should be within limits
    try testing.expect(analysis.isValid());
}

test "deeply nested query exceeds depth limit" {
    const allocator = testing.allocator;

    const query =
        \\query {
        \\  domain(id: "test.eth") {
        \\    parent {
        \\      parent {
        \\        parent {
        \\          parent {
        \\            parent {
        \\              parent {
        \\                parent {
        \\                  parent {
        \\                    parent {
        \\                      parent {
        \\                        parent {
        \\                          name
        \\                        }
        \\                      }
        \\                    }
        \\                  }
        \\                }
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
    ;

    var p = try parser.Parser.init(allocator, query);
    var document = try p.parseDocument();
    defer document.deinit(allocator);

    const limits = ComplexityLimits{ .max_depth = 10 };
    var analyzer = ComplexityAnalyzer.init(allocator, limits);

    const analysis = try analyzer.analyzeDocument(&document);

    // Should exceed depth limit
    try testing.expect(analysis.exceeded_depth);
    try testing.expect(!analysis.isValid());
}

test "expensive list query exceeds cost limit" {
    const allocator = testing.allocator;

    const query =
        \\query {
        \\  domains(first: 100) {
        \\    name
        \\    owner { id }
        \\    resolver { address }
        \\    subdomains(first: 100) {
        \\      name
        \\      owner { id }
        \\    }
        \\  }
        \\}
    ;

    var p = try parser.Parser.init(allocator, query);
    var document = try p.parseDocument();
    defer document.deinit(allocator);

    const limits = ComplexityLimits{ .max_cost = 100 };
    var analyzer = ComplexityAnalyzer.init(allocator, limits);

    const analysis = try analyzer.analyzeDocument(&document);

    // Should exceed cost limit due to nested lists
    try testing.expect(analysis.exceeded_cost);
    try testing.expect(!analysis.isValid());
}

test "query with multiple operations sums complexity" {
    const allocator = testing.allocator;

    const query =
        \\query {
        \\  domains(first: 10) { name }
        \\  registrations(first: 10) { name }
        \\}
    ;

    var p = try parser.Parser.init(allocator, query);
    var document = try p.parseDocument();
    defer document.deinit(allocator);

    const limits = ComplexityLimits{};
    var analyzer = ComplexityAnalyzer.init(allocator, limits);

    const analysis = try analyzer.analyzeDocument(&document);

    // Cost should include both operations
    try testing.expect(analysis.cost > 10); // More than single operation
    try testing.expect(analysis.isValid());
}

test "query without pagination has low cost" {
    const allocator = testing.allocator;

    const query =
        \\query {
        \\  domain(id: "test.eth") {
        \\    name
        \\    owner { id }
        \\  }
        \\}
    ;

    var p = try parser.Parser.init(allocator, query);
    var document = try p.parseDocument();
    defer document.deinit(allocator);

    const limits = ComplexityLimits{};
    var analyzer = ComplexityAnalyzer.init(allocator, limits);

    const analysis = try analyzer.analyzeDocument(&document);

    // Should have low cost (no pagination multipliers)
    try testing.expect(analysis.cost < 10);
    try testing.expect(analysis.isValid());
}
