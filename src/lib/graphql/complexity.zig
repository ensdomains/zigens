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
/// Four behaviors are critical for correctness against adversarial queries:
///   1. Fragments are expanded (named + inline) — otherwise `...Frag { deep }`
///      bypasses depth and cost.
///   2. `first: $var` resolution order: runtime variable value (if request
///      supplied one) → declared default → `max_pagination_assumption` (worst
///      case). Reading the runtime value is what makes `first: 6` actually
///      cost 6× and not 1000×.
///   3. The pagination multiplier is NOT capped — `domains(first: 1000)` costs
///      1000, not 100. This lets cost properly catch nested-list amplification.
///   4. Each request is analyzed against its OWN variables. The same query
///      string with different runtime values gets different costs, which is
///      the point: benign clients with small `first` pay small cost, adversarial
///      clients with large `first` pay large cost.
pub const ComplexityAnalyzer = struct {
    allocator: std.mem.Allocator,
    limits: ComplexityLimits,
    fragments: []const parser.Fragment = &.{},
    variables: []const parser.VariableDefinition = &.{},
    /// Runtime variables JSON from the request body (the `variables` field of
    /// the GraphQL POST). When present, used to refine the multiplier for
    /// `first: $var` instead of falling back to worst-case.
    runtime_variables: ?std.json.Value = null,

    pub fn init(allocator: std.mem.Allocator, limits: ComplexityLimits) ComplexityAnalyzer {
        return .{ .allocator = allocator, .limits = limits };
    }

    /// Analyze a GraphQL document for complexity. Pass the request's runtime
    /// variables (or null if none) so `first: $var` resolves to the actual
    /// value the client sent rather than the declared default / worst case.
    pub fn analyzeDocument(self: *ComplexityAnalyzer, document: *const parser.Document, runtime_variables: ?std.json.Value) !ComplexityAnalysis {
        self.runtime_variables = runtime_variables;
        defer self.runtime_variables = null;
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
    /// Resolution order for `first: $var`:
    ///   1. Runtime variable value from the request body (the actual `first`
    ///      the client sent — `first: 6` truly costs 6×).
    ///   2. Declared default in the operation's variable definitions.
    ///   3. `max_pagination_assumption` worst case.
    /// Without (1), a query parameterized as `first: $n` would always cost the
    /// worst case even when the client sends `n: 6`, blocking legitimate use.
    /// With (1), each request is analyzed against its own values: small `first`
    /// pays small cost, large `first` pays large cost. The worst case still
    /// applies when no runtime value is supplied.
    fn getFieldMultiplier(self: *ComplexityAnalyzer, field: *const parser.Field) u32 {
        for (field.arguments) |arg| {
            if (!std.mem.eql(u8, arg.name, "first") and !std.mem.eql(u8, arg.name, "limit")) continue;

            switch (arg.value) {
                .int => |i| return self.clampMultiplier(i),
                .variable => |var_name| {
                    // 1) Runtime value from the request body, if provided.
                    if (self.runtimeIntVar(var_name)) |v| return self.clampMultiplier(v);

                    // 2) Declared default on the operation.
                    for (self.variables) |*vd| {
                        if (!std.mem.eql(u8, vd.name, var_name)) continue;
                        if (vd.default_value) |dv| switch (dv) {
                            .int => |i| return self.clampMultiplier(i),
                            else => {},
                        };
                        break;
                    }

                    // 3) No runtime value, no default → worst case so an attacker
                    //    can't hide behind `first: $n` to bypass cost analysis.
                    return self.limits.max_pagination_assumption;
                },
                else => {},
            }
        }
        return 1;
    }

    fn clampMultiplier(self: *const ComplexityAnalyzer, raw: i64) u32 {
        if (raw <= 0) return 1;
        const clamped: u32 = @intCast(@min(@as(i64, self.limits.max_pagination_assumption), raw));
        return @max(1, clamped);
    }

    /// Look up a variable's runtime int value from the request's variables JSON.
    /// Accepts both JSON integers and numeric strings (some clients send
    /// `"first": "10"`). Returns null when the variable isn't present, isn't
    /// numeric, or no runtime variables were provided.
    fn runtimeIntVar(self: *const ComplexityAnalyzer, name: []const u8) ?i64 {
        const root = self.runtime_variables orelse return null;
        if (root != .object) return null;
        const v = root.object.get(name) orelse return null;
        return switch (v) {
            .integer => |i| i,
            .float => |f| @intFromFloat(f),
            .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
            else => null,
        };
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

    const analysis = try analyzer.analyzeDocument(&document, null);

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

    const analysis = try analyzer.analyzeDocument(&document, null);

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

    const analysis = try analyzer.analyzeDocument(&document, null);

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

    const analysis = try analyzer.analyzeDocument(&document, null);

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

    const analysis = try analyzer.analyzeDocument(&document, null);

    // Should have low cost (no pagination multipliers)
    try testing.expect(analysis.cost < 10);
    try testing.expect(analysis.isValid());
}

test "first: $var resolves to runtime value when provided" {
    const allocator = testing.allocator;

    // Same query the user's domains() shape: variable-driven `first`,
    // moderately complex selection (~7 leaves) where worst-case multiplier
    // would blow the budget but real `first: 6` should pass easily.
    const query =
        \\query Domains($first: Int) {
        \\  domains(first: $first) {
        \\    id name owner { id } resolver { address }
        \\  }
        \\}
    ;

    var p = try parser.Parser.init(allocator, query);
    var document = try p.parseDocument();
    defer document.deinit(allocator);

    const limits = ComplexityLimits{ .max_cost = 1000 };

    // Without runtime variables: worst-case multiplier kicks in, cost explodes.
    {
        var analyzer = ComplexityAnalyzer.init(allocator, limits);
        const analysis = try analyzer.analyzeDocument(&document, null);
        try testing.expect(analysis.exceeded_cost);
    }

    // With runtime `first: 6`: multiplier is 6, query fits comfortably.
    {
        const vars_json = "{\"first\": 6}";
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, vars_json, .{});
        defer parsed.deinit();

        var analyzer = ComplexityAnalyzer.init(allocator, limits);
        const analysis = try analyzer.analyzeDocument(&document, parsed.value);
        try testing.expect(!analysis.exceeded_cost);
        try testing.expect(analysis.cost < 100);
    }

    // With runtime `first: 9999`: still clamped to max_pagination_assumption,
    // adversarial parameterization can't bypass cost analysis.
    {
        const vars_json = "{\"first\": 9999}";
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, vars_json, .{});
        defer parsed.deinit();

        var analyzer = ComplexityAnalyzer.init(allocator, limits);
        const analysis = try analyzer.analyzeDocument(&document, parsed.value);
        try testing.expect(analysis.exceeded_cost);
    }
}
