const std = @import("std");
const db = @import("../storage/database.zig");
const json_utils = @import("../utils/json.zig");

// Import generic GraphQL library
const parser = @import("../lib/graphql/parser.zig");
const complexity = @import("../lib/graphql/complexity.zig");
const metrics_mod = @import("../lib/graphql/metrics.zig");

// Import ENS-specific resolvers
const resolvers = @import("resolvers/resolvers.zig");

/// GraphQL query handler for ENSv2 Indexer
/// Provides subgraph-compatible GraphQL API
pub const GraphQLHandler = struct {
    allocator: std.mem.Allocator,
    database: *db.Database,
    executor: parser.Executor,
    complexity_max_depth: u32,
    complexity_max_cost: u32,
    metrics: metrics_mod.Metrics,

    pub fn init(allocator: std.mem.Allocator, database: *db.Database, max_depth: u32, max_cost: u32, metrics_enabled: bool) !GraphQLHandler {
        // Create execution context (loaders are set per-request, not globally)
        const ctx = parser.ExecutionContext{
            .allocator = allocator,
            .database = @ptrCast(database),
            .loaders = null, // Will be set per request for request-scoped caching
        };

        // Initialize executor
        var executor = parser.Executor.init(allocator, ctx);

        // Register all resolvers (imported from resolvers.zig)
        try executor.registerResolver("domain", resolvers.resolveDomain);
        try executor.registerResolver("domains", resolvers.resolveDomains);
        try executor.registerResolver("domainConnection", resolvers.resolveDomainConnection);
        try executor.registerResolver("account", resolvers.resolveAccount);
        try executor.registerResolver("registrations", resolvers.resolveRegistrations);
        try executor.registerResolver("registrationConnection", resolvers.resolveRegistrationConnection);
        try executor.registerResolver("events", resolvers.resolveEvents);
        try executor.registerResolver("eventConnection", resolvers.resolveEventConnection);
        try executor.registerResolver("roles", resolvers.resolveRoles);
        try executor.registerResolver("roleConnection", resolvers.resolveRolesConnection);
        try executor.registerResolver("resolvers", resolvers.resolveResolvers);
        try executor.registerResolver("resolver", resolvers.resolveResolver);
        try executor.registerResolver("registries", resolvers.resolveRegistries);
        try executor.registerResolver("metadata", resolvers.resolveMetadata);
        try executor.registerResolver("approvals", resolvers.resolveApprovals);

        return .{
            .allocator = allocator,
            .database = database,
            .executor = executor,
            .complexity_max_depth = max_depth,
            .complexity_max_cost = max_cost,
            .metrics = metrics_mod.Metrics.init(allocator, metrics_enabled),
        };
    }

    pub fn deinit(self: *GraphQLHandler) void {
        self.metrics.deinit();
        self.executor.deinit();
    }

    /// Handle a GraphQL query with optional variables
    pub fn handleQuery(self: *GraphQLHandler, query: []const u8, variables: ?std.json.Value, operation_name: ?[]const u8) ![]u8 {
        // Start timing for metrics
        var timer = metrics_mod.QueryTimer.start();

        // Handle introspection queries for autocomplete/schema exploration
        if (std.mem.indexOf(u8, query, "__schema") != null or std.mem.indexOf(u8, query, "IntrospectionQuery") != null) {
            return try self.handleIntrospectionQuery();
        }

        // Handle __type introspection queries (but not __typename)
        if (std.mem.indexOf(u8, query, "__type(") != null) {
            return try self.handleTypeIntrospectionQuery(query);
        }

        // Per-request arena allocator: all short-lived request allocations (parsing,
        // execution, dataloaders, resolver intermediates) go here instead of the GPA.
        // Backed by page_allocator so pages return directly to the OS when the
        // request completes, eliminating GPA fragmentation from thread-per-connection.
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const request_alloc = arena.allocator();

        // Create request-scoped DataLoader context for batching and caching
        const dataloader_mod = @import("loaders.zig");
        var loader_context = try dataloader_mod.LoaderContext.init(request_alloc, self.database);
        defer loader_context.deinit();

        // Create a per-request executor copy to avoid race conditions when
        // multiple threads handle requests concurrently. The shared executor's
        // resolvers map is read-only and safe to share; per-request state
        // (fragments, variables, loaders) lives on this stack copy.
        var request_executor = self.executor;
        request_executor.allocator = request_alloc;
        request_executor.context.allocator = request_alloc;
        request_executor.context.loaders = @ptrCast(loader_context);

        // Parse the query using the arena allocator
        var document = parser.parseQuery(request_alloc, query) catch |err| {
            std.log.err("Failed to parse GraphQL query: {}", .{err});
            self.metrics.recordError();
            return try self.buildErrorResponseWithCode("Invalid GraphQL syntax", ErrorCode.SYNTAX_ERROR);
        };
        defer document.deinit(request_alloc);

        // Analyze query complexity to prevent DoS attacks
        const limits = complexity.ComplexityLimits{
            .max_depth = self.complexity_max_depth,
            .max_cost = self.complexity_max_cost,
        };
        var analyzer = complexity.ComplexityAnalyzer.init(request_alloc, limits);
        const analysis = try analyzer.analyzeDocument(&document, variables);

        if (!analysis.isValid()) {
            // Error message allocated on GPA since it's returned to the caller
            const error_msg = try analysis.errorMessage(self.allocator);
            defer self.allocator.free(error_msg);
            std.log.warn("Query complexity violation: {s}", .{error_msg});
            self.metrics.recordRejection(analysis.depth, analysis.cost);
            return try self.buildErrorResponseWithCode(error_msg, ErrorCode.COMPLEXITY_LIMIT_EXCEEDED);
        }

        std.log.debug("Query complexity: depth={d}, cost={d}", .{ analysis.depth, analysis.cost });

        // Execute the parsed query with the per-request executor (arena-backed)
        const result = request_executor.executeDocument(&document, variables, operation_name) catch |err| {
            std.log.err("Failed to execute GraphQL query: {}", .{err});
            self.metrics.recordError();
            if (err == error.OperationNotFound) {
                return try self.buildErrorResponseWithCode("Operation not found", ErrorCode.VALIDATION_ERROR);
            } else if (err == error.OperationNameRequired) {
                return try self.buildErrorResponseWithCode("Must provide operation name when query contains multiple operations", ErrorCode.VALIDATION_ERROR);
            } else if (err == error.InvalidContractAddress) {
                return try self.buildErrorResponseWithCode("Invalid contractAddress: must be a valid Ethereum address (40 hex characters with 0x prefix)", ErrorCode.INVALID_ARGUMENT);
            } else if (err == error.InvalidAddress) {
                return try self.buildErrorResponseWithCode("Invalid address: must be 40 hex characters with 0x prefix", ErrorCode.INVALID_ARGUMENT);
            } else if (err == error.InvalidNamehash) {
                return try self.buildErrorResponseWithCode("Invalid namehash: must be 64 hex characters with 0x prefix", ErrorCode.INVALID_ARGUMENT);
            } else if (err == error.NegativeLimit) {
                return try self.buildErrorResponseWithCode("Pagination 'first'/'last' must be non-negative", ErrorCode.INVALID_ARGUMENT);
            } else if (err == error.LimitExceeded) {
                return try self.buildErrorResponseWithCode("Pagination 'first'/'last' exceeds the maximum allowed value", ErrorCode.INVALID_ARGUMENT);
            } else if (err == error.InvalidCursor) {
                return try self.buildErrorResponseWithCode("Invalid cursor: malformed or unparseable", ErrorCode.INVALID_ARGUMENT);
            } else if (err == error.InvalidProtocol) {
                return try self.buildErrorResponseWithCode("Invalid protocol: must be 'v1' or 'v2'", ErrorCode.INVALID_ARGUMENT);
            } else if (err == error.TooManyNames) {
                return try self.buildErrorResponseWithCode("name_in: too many names (cap is 1000 per query)", ErrorCode.INVALID_ARGUMENT);
            } else if (err == error.SubSelectionOnScalar) {
                // Common porting mistake from the ENS subgraph, which exposes
                // `texts { key value }`. Our schema declares `texts: [String!]`
                // (keys only) and `text(key:): String` for value lookup; same
                // for `abis: [Int!]`. Tell the client what's actually wrong.
                return try self.buildErrorResponseWithCode(
                    "A scalar or list-of-scalar field cannot have a subselection. " ++
                        "Note: `texts: [String!]` returns keys only — call `text(key: \"...\")` " ++
                        "for values; `abis: [Int!]` returns content-type IDs.",
                    ErrorCode.VALIDATION_ERROR,
                );
            }
            return try self.buildErrorResponseWithCode("Query execution failed", ErrorCode.EXECUTION_ERROR);
        };

        // Record successful query with timing
        const duration_us = timer.elapsedMicroseconds();
        self.metrics.recordQuery(duration_us, analysis.depth, analysis.cost);

        // Dupe result from arena to GPA for the caller (arena is freed on return)
        return try self.allocator.dupe(u8, result);
    }

    fn handleIntrospectionQuery(self: *GraphQLHandler) ![]u8 {
        // Return GraphQL introspection response for autocomplete
        // Generated from schema.graphql at build time
        const introspection_response = @embedFile("introspection.json");
        return try self.allocator.dupe(u8, introspection_response);
    }

    fn handleTypeIntrospectionQuery(self: *GraphQLHandler, query: []const u8) ![]u8 {
        // Extract type name from __type(name: "TypeName") query
        // Look for pattern: __type(name: "..." or __type(name: '...'
        const type_name = blk: {
            // Find __type(name:
            const start_marker = "__type(name:";
            const start_pos = std.mem.indexOf(u8, query, start_marker) orelse
                return try self.buildErrorResponseWithCode("Invalid __type query: missing name argument", ErrorCode.VALIDATION_ERROR);

            const after_marker = query[start_pos + start_marker.len ..];

            // Skip whitespace
            var i: usize = 0;
            while (i < after_marker.len and (after_marker[i] == ' ' or after_marker[i] == '\t')) : (i += 1) {}

            if (i >= after_marker.len)
                return try self.buildErrorResponseWithCode("Invalid __type query: missing name value", ErrorCode.VALIDATION_ERROR);

            // Check for quote character
            const quote_char = after_marker[i];
            if (quote_char != '"' and quote_char != '\'')
                return try self.buildErrorResponseWithCode("Invalid __type query: name must be a string", ErrorCode.VALIDATION_ERROR);

            // Find closing quote
            const name_start = i + 1;
            const name_end = std.mem.indexOfScalarPos(u8, after_marker, name_start, quote_char) orelse
                return try self.buildErrorResponseWithCode("Invalid __type query: unterminated string", ErrorCode.VALIDATION_ERROR);

            break :blk after_marker[name_start..name_end];
        };

        // Load and parse introspection data
        const introspection_json = @embedFile("introspection.json");
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, introspection_json, .{}) catch {
            return try self.buildErrorResponseWithCode("Failed to parse introspection data", ErrorCode.INTERNAL_ERROR);
        };
        defer parsed.deinit();

        // Find the requested type
        const types = parsed.value.object.get("data").?.object.get("__schema").?.object.get("types").?.array;

        var found_type: ?std.json.Value = null;
        for (types.items) |type_val| {
            const name = type_val.object.get("name").?.string;
            if (std.mem.eql(u8, name, type_name)) {
                found_type = type_val;
                break;
            }
        }

        if (found_type == null) {
            // Type not found - return null per GraphQL spec
            return try self.allocator.dupe(u8, "{\"data\":{\"__type\":null}}");
        }

        // Serialize the type object to JSON
        const type_json = std.json.Stringify.valueAlloc(self.allocator, found_type.?, .{}) catch {
            return try self.buildErrorResponseWithCode("Failed to serialize type data", ErrorCode.INTERNAL_ERROR);
        };
        defer self.allocator.free(type_json);

        // Build response
        return try std.fmt.allocPrint(self.allocator, "{{\"data\":{{\"__type\":{s}}}}}", .{type_json});
    }

    const ErrorLocation = struct {
        line: u32,
        column: u32,
    };

    pub const ErrorCode = enum {
        SYNTAX_ERROR,
        VALIDATION_ERROR,
        COMPLEXITY_LIMIT_EXCEEDED,
        EXECUTION_ERROR,
        INVALID_ARGUMENT,
        NOT_FOUND,
        INTERNAL_ERROR,

        pub fn toString(self: ErrorCode) []const u8 {
            return switch (self) {
                .SYNTAX_ERROR => "SYNTAX_ERROR",
                .VALIDATION_ERROR => "VALIDATION_ERROR",
                .COMPLEXITY_LIMIT_EXCEEDED => "COMPLEXITY_LIMIT_EXCEEDED",
                .EXECUTION_ERROR => "EXECUTION_ERROR",
                .INVALID_ARGUMENT => "INVALID_ARGUMENT",
                .NOT_FOUND => "NOT_FOUND",
                .INTERNAL_ERROR => "INTERNAL_ERROR",
            };
        }
    };

    fn buildErrorResponseWithCode(self: *GraphQLHandler, message: []const u8, code: ErrorCode) ![]u8 {
        const extensions = try std.fmt.allocPrint(self.allocator, "{{\"code\":\"{s}\"}}", .{code.toString()});
        defer self.allocator.free(extensions);
        return self.buildErrorResponseFull(message, null, null, extensions);
    }

    /// Build a full GraphQL spec-compliant error response with all optional fields
    fn buildErrorResponseFull(
        self: *GraphQLHandler,
        message: []const u8,
        locations: ?[]const ErrorLocation,
        path: ?[]const []const u8,
        extensions: ?[]const u8,
    ) ![]u8 {
        var response: std.ArrayList(u8) = .{};
        errdefer response.deinit(self.allocator);

        const message_escaped = try json_utils.escapeString(self.allocator, message);
        defer self.allocator.free(message_escaped);

        const writer = response.writer(self.allocator);

        // Start errors array
        try writer.writeAll("{\"errors\":[{\"message\":\"");
        try writer.writeAll(message_escaped);
        try writer.writeAll("\"");

        // Add locations if provided
        if (locations) |locs| {
            try writer.writeAll(",\"locations\":[");
            for (locs, 0..) |loc, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("{{\"line\":{d},\"column\":{d}}}", .{ loc.line, loc.column });
            }
            try writer.writeAll("]");
        }

        // Add path if provided
        if (path) |p| {
            try writer.writeAll(",\"path\":[");
            for (p, 0..) |segment, i| {
                if (i > 0) try writer.writeAll(",");
                const escaped_segment = try json_utils.escapeString(self.allocator, segment);
                defer self.allocator.free(escaped_segment);
                try writer.print("\"{s}\"", .{escaped_segment});
            }
            try writer.writeAll("]");
        }

        // Add extensions if provided
        if (extensions) |ext| {
            try writer.writeAll(",\"extensions\":");
            try writer.writeAll(ext);
        }

        // Close error object and array, add null data
        try writer.writeAll("}],\"data\":null}");

        return response.toOwnedSlice(self.allocator);
    }
};
