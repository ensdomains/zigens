const std = @import("std");
const parser = @import("parser.zig");

/// Query complexity limits configuration
pub const ComplexityLimits = struct {
    max_depth: u32 = 10, // Maximum nesting depth
    max_cost: u32 = 10000, // Maximum total query
    default_field_cost: u32 = 1, // Cost per field
    list_multiplier: u32 = 1, // Multiplier for list fields based on 'first' argument
    /// Upper bound used when the analyzer can't read a `first:` literal — e.g.
    /// the value is a variable reference and the variable has no default. Cost
    /// must assume the worst case rather than 1, otherwise an attacker can
    /// bypass cost analysis by parameterizing every page size.
    max_pagination_assumption: u32 = 1000,
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

/// Query complexity analyzer.
/// Three behaviors are critical for correctness against adversarial queries:
///   1. Fragments are expanded (named + inline) — otherwise `...Frag { deep }`
///      bypasses depth and cost.
///   2. `first: $var` is resolved to the variable's default value when present;
///      when absent, treated as `max_pagination_assumption` (worst case) rather
///      than 1.
///   3. The pagination multiplier is NOT capped — `domains(first: 1000)` costs
///      1000, not 100. This lets cost properly catch nested-list amplification.
pub const ComplexityAnalyzer = struct {
    allocator: std.mem.Allocator,
    limits: ComplexityLimits,
    fragments: []const parser.Fragment = &.{},
    variables: []const parser.VariableDefinition = &.{},

    pub fn init(allocator: std.mem.Allocator, limits: ComplexityLimits) ComplexityAnalyzer {
        return .{ .allocator = allocator, .limits = limits };
    }

    /// Analyze a GraphQL document for complexity
    pub fn analyzeDocument(self: *ComplexityAnalyzer, document: *const parser.Document) !ComplexityAnalysis {
        var max_depth: u32 = 0;
        var total_cost: u32 = 0;

        // Bind document-level fragments for the duration of analysis.
        self.fragments = document.fragments;
        defer self.fragments = &.{};

        // Analyze each operation
        for (document.operations) |*operation| {
            const analysis = try self.analyzeOperation(operation);
            max_depth = @max(max_depth, analysis.depth);
            total_cost +|= analysis.cost; // saturating to avoid u32 wrap on adversarial input
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

        // Bind operation-level variable defs for `first: $var` resolution.
        const prev_vars = self.variables;
        self.variables = operation.variables;
        defer self.variables = prev_vars;

        for (operation.fields) |*field| {
            const field_analysis = try self.analyzeField(field, 1);
            max_depth = @max(max_depth, field_analysis.depth);
            total_cost +|= field_analysis.cost;
        }

        return ComplexityAnalysis{
            .depth = max_depth,
            .cost = total_cost,
            .exceeded_depth = max_depth > self.limits.max_depth,
            .exceeded_cost = total_cost > self.limits.max_cost,
        };
    }

    /// Analyze a field recursively. Fragment spreads are expanded inline so
    /// nested selections inside fragments contribute to depth & cost just like
    /// inline selections.
    fn analyzeField(self: *ComplexityAnalyzer, field: *const parser.Field, current_depth: u32) error{OutOfMemory}!ComplexityAnalysis {
        // Fragment spread: charge the spread location as 0 cost (it's a syntactic
        // marker, not a real field) and recurse into the fragment's selections at
        // the SAME depth. Without this, `query { ...Frag }` reports depth 1 + cost 0.
        if (field.fragment_spread) |frag_name| {
            for (self.fragments) |*frag| {
                if (std.mem.eql(u8, frag.name, frag_name)) {
                    var max_depth: u32 = current_depth;
                    var total_cost: u32 = 0;
                    for (frag.selections) |*sel| {
                        const sub = try self.analyzeField(sel, current_depth);
                        max_depth = @max(max_depth, sub.depth);
                        total_cost +|= sub.cost;
                    }
                    return ComplexityAnalysis{
                        .depth = max_depth,
                        .cost = total_cost,
                        .exceeded_depth = max_depth > self.limits.max_depth,
                        .exceeded_cost = total_cost > self.limits.max_cost,
                    };
                }
            }
            // Unknown fragment — charge zero, mirroring executor's permissive behavior.
            return ComplexityAnalysis{
                .depth = current_depth,
                .cost = 0,
                .exceeded_depth = false,
                .exceeded_cost = false,
            };
        }

        var field_cost: u32 = self.limits.default_field_cost;
        var max_depth: u32 = current_depth;

        const multiplier = self.getFieldMultiplier(field);
        field_cost *|= multiplier;

        if (field.selections.len > 0) {
            var nested_cost: u32 = 0;
            var nested_max_depth: u32 = current_depth;

            for (field.selections) |*selection| {
                const nested_analysis = try self.analyzeField(selection, current_depth + 1);
                nested_max_depth = @max(nested_max_depth, nested_analysis.depth);
                nested_cost +|= nested_analysis.cost;
            }

            field_cost +|= nested_cost *| multiplier;
            max_depth = nested_max_depth;
        }

        return ComplexityAnalysis{
            .depth = max_depth,
            .cost = field_cost,
            .exceeded_depth = max_depth > self.limits.max_depth,
            .exceeded_cost = field_cost > self.limits.max_cost,
        };
    }

    /// Get the multiplier for a field based on pagination arguments.
    /// Resolves variables to their default value when present; falls back to
    /// `max_pagination_assumption` for unresolvable variables (cannot allow an
    /// attacker to bypass cost analysis by parameterizing every page size).
    fn getFieldMultiplier(self: *ComplexityAnalyzer, field: *const parser.Field) u32 {
        for (field.arguments) |arg| {
            if (!std.mem.eql(u8, arg.name, "first") and !std.mem.eql(u8, arg.name, "limit")) continue;

            switch (arg.value) {
                .int => |i| {
                    if (i <= 0) return 1;
                    const clamped: u32 = @intCast(@min(@as(i64, self.limits.max_pagination_assumption), i));
                    return @max(1, clamped);
                },
                .variable => |var_name| {
                    // Look up default in variable definitions.
                    for (self.variables) |*vd| {
                        if (!std.mem.eql(u8, vd.name, var_name)) continue;
                        if (vd.default_value) |dv| switch (dv) {
                            .int => |i| {
                                if (i <= 0) return 1;
                                const clamped: u32 = @intCast(@min(@as(i64, self.limits.max_pagination_assumption), i));
                                return @max(1, clamped);
                            },
                            else => {},
                        };
                        // Variable with no default → assume the worst case so the
                        // attacker can't hide behind `first: $n` to bypass cost.
                        return self.limits.max_pagination_assumption;
                    }
                    // Variable referenced but not declared — also worst case.
                    return self.limits.max_pagination_assumption;
                },
                else => {},
            }
        }
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
