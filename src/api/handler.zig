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
const schema_validator_mod = @import("schema_validator.zig");

pub const GraphQLHandler = struct {
    allocator: std.mem.Allocator,
    database: *db.Database,
    executor: parser.Executor,
    schema_validator: schema_validator_mod.SchemaValidator,
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
        try executor.registerResolver("accounts", resolvers.resolveAccounts);
        try executor.registerResolver("registrations", resolvers.resolveRegistrations);
        try executor.registerResolver("registrationConnection", resolvers.resolveRegistrationConnection);
        try executor.registerResolver("events", resolvers.resolveEvents);
        try executor.registerResolver("eventConnection", resolvers.resolveEventConnection);
        // Subgraph-parity per-type top-level event queries (S7-S9).
        try executor.registerResolver("transfers", resolvers.resolveTransfers);
        try executor.registerResolver("nameRegistereds", resolvers.resolveNameRegistereds);
        try executor.registerResolver("nameReneweds", resolvers.resolveNameReneweds);
        try executor.registerResolver("textChangeds", resolvers.resolveTextChangeds);
        try executor.registerResolver("addressChangeds", resolvers.resolveAddressChangeds);
        try executor.registerResolver("nameWrappeds", resolvers.resolveNameWrappeds);
        try executor.registerResolver("nameUnwrappeds", resolvers.resolveNameUnwrappeds);
        try executor.registerResolver("fusesSets", resolvers.resolveFusesSets);
        try executor.registerResolver("expiryUpdateds", resolvers.resolveExpiryUpdateds);
        try executor.registerResolver("resolverUpdateds", resolvers.resolveResolverUpdateds);
        try executor.registerResolver("labelRegistereds", resolvers.resolveLabelRegistereds);
        try executor.registerResolver("reverseClaimeds", resolvers.resolveReverseClaimeds);
        try executor.registerResolver("registryTransfers", resolvers.resolveRegistryTransfers);
        try executor.registerResolver("roles", resolvers.resolveRoles);
        try executor.registerResolver("roleConnection", resolvers.resolveRolesConnection);
        try executor.registerResolver("resolversByOwner", resolvers.resolveResolversByOwner);
        try executor.registerResolver("resolvers", resolvers.resolveResolvers);
        try executor.registerResolver("resolver", resolvers.resolveResolver);
        try executor.registerResolver("registries", resolvers.resolveRegistries);
        try executor.registerResolver("registry", resolvers.resolveRegistry);
        try executor.registerResolver("metadata", resolvers.resolveMetadata);
        try executor.registerResolver("approvals", resolvers.resolveApprovals);
        try executor.registerResolver("wrappedDomains", resolvers.resolveWrappedDomains);
        try executor.registerResolver("_meta", resolvers.resolveMeta);

        // Build the schema validator once from the embedded introspection JSON.
        // It indexes the introspection types into hash maps used to reject
        // missing-required-arg / unknown-arg / unknown-input-object-field
        // before the query reaches the executor.
        const introspection_json = @embedFile("introspection.json");
        var schema_validator = try schema_validator_mod.SchemaValidator.init(allocator, introspection_json);
        errdefer schema_validator.deinit();

        return .{
            .allocator = allocator,
            .database = database,
            .executor = executor,
            .schema_validator = schema_validator,
            .complexity_max_depth = max_depth,
            .complexity_max_cost = max_cost,
            .metrics = metrics_mod.Metrics.init(allocator, metrics_enabled),
        };
    }

    pub fn deinit(self: *GraphQLHandler) void {
        self.metrics.deinit();
        self.executor.deinit();
        self.schema_validator.deinit();
    }

    /// Walk the parsed operations and validate each root field against the
    /// schema. The validator skips meta fields (`__typename`, `__schema`, …)
    /// and unknown root field names (those are surfaced separately by the
    /// executor as `UnknownRootField`).
    fn validateDocumentArgs(self: *GraphQLHandler, document: *const parser.Document) schema_validator_mod.SchemaValidator.Error!void {
        for (document.operations) |op| {
            for (op.fields) |*field| {
                try self.schema_validator.validateRootField(field);
            }
        }
    }

    /// Handle a GraphQL query with optional variables
    pub fn handleQuery(self: *GraphQLHandler, query: []const u8, variables: ?std.json.Value, operation_name: ?[]const u8) ![]u8 {
        // Start timing for metrics
        var timer = metrics_mod.QueryTimer.start();

        // Introspection (__schema / __type) is detected AFTER parsing, from the
        // parsed root fields — see below. Matching on the raw query text here would
        // false-positive whenever the substring appears in a string-argument value
        // (e.g. where:{name_contains:"__schema"}) or an operation name.

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

        // Introspection routing: detect __schema / __type from the PARSED root
        // fields, not a raw-text substring match. The executor has no __schema/
        // __type resolver (only __typename), so these must be intercepted here —
        // before complexity analysis, validation, and execution.
        intro: {
            const op: *const parser.Operation = sel: {
                if (operation_name) |nm| {
                    for (document.operations) |*o| {
                        if (o.name != null and std.mem.eql(u8, o.name.?, nm)) break :sel o;
                    }
                    break :intro; // named op not found -> let the executor report it
                }
                if (document.operations.len == 1) break :sel &document.operations[0];
                break :intro; // multiple unnamed ops -> let the executor error
            };
            for (op.fields) |*f| {
                if (std.mem.eql(u8, f.name, "__schema")) return try self.handleIntrospectionQuery();
            }
            for (op.fields) |*f| {
                if (std.mem.eql(u8, f.name, "__type")) return try self.handleTypeIntrospectionQuery(f);
            }
        }

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

        // Schema validation pass — runs against the parsed document before any
        // resolver runs. Catches missing required args, unknown args, and
        // unknown fields inside input objects. Replaces per-resolver manual
        // checks for the generic-cases (specific InvalidAddress / TooManyNames
        // / etc. type errors stay in the resolvers — they need value-level
        // context that schema validation can't see).
        if (self.validateDocumentArgs(&document)) {} else |val_err| {
            self.metrics.recordError();
            const msg = switch (val_err) {
                error.MissingRequiredArg => "Missing required argument: see the schema for the required `Type!`-marked fields.",
                error.UnknownArgument => "Unknown argument: the query references a root-field argument that does not exist in the schema.",
                error.UnknownInputObjectField => "Unknown field in input object: the `where` (or similar input) contains a field not declared in its filter type.",
                else => "Query validation failed",
            };
            return try self.buildErrorResponseWithCode(msg, ErrorCode.VALIDATION_ERROR);
        }

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
            } else if (err == error.UnknownRootField) {
                return try self.buildErrorResponseWithCode("Unknown root field: query references a Query field that does not exist in the schema. Check the schema or run an introspection query.", ErrorCode.VALIDATION_ERROR);
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

    fn handleTypeIntrospectionQuery(self: *GraphQLHandler, field: *const parser.Field) ![]u8 {
        // Read the requested type name from the parsed __type(name: "...") field.
        const type_name = parser.getStringArg(field, "name", null) orelse
            return try self.buildErrorResponseWithCode("Invalid __type query: missing name argument", ErrorCode.VALIDATION_ERROR);

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

const testing = std.testing;

// Build a handler over a fresh in-memory DB (full schema loaded by Database.init),
// run a query end-to-end through handleQuery, and assert the response is a DATA
// response — NOT the static introspection schema. Guards #23: introspection must be
// detected from parsed root fields, never from a raw-text substring match.
fn expectQueryReturnsData(query: []const u8, op_name: ?[]const u8) !void {
    const allocator = testing.allocator;
    var database = try db.Database.init(allocator, ":memory:");
    defer database.deinit();
    var handler = try GraphQLHandler.init(allocator, &database, 10, 10000, false);
    defer handler.deinit();

    const result = try handler.handleQuery(query, null, op_name);
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "\"data\"") != null);
    // Introspection markers from the static introspection.json must be absent.
    try testing.expect(std.mem.indexOf(u8, result, "\"queryType\"") == null);
    try testing.expect(std.mem.indexOf(u8, result, "\"__schema\"") == null);
}

test "handleQuery: __schema inside a string argument is data, not introspection" {
    try expectQueryReturnsData("{ domains(where:{name_contains:\"__schema\"}){ id name } }", null);
}

test "handleQuery: operation named IntrospectionQuery still executes its data fields" {
    try expectQueryReturnsData("query IntrospectionQuery { domains(first:1){ id } }", "IntrospectionQuery");
}

test "handleQuery: __type( inside a string argument is data, not introspection" {
    try expectQueryReturnsData("{ domains(where:{name_contains:\"__type(\"}){ id } }", null);
}

test "handleQuery: real __schema query still returns introspection" {
    const allocator = testing.allocator;
    var database = try db.Database.init(allocator, ":memory:");
    defer database.deinit();
    var handler = try GraphQLHandler.init(allocator, &database, 10, 10000, false);
    defer handler.deinit();

    const result = try handler.handleQuery("{ __schema { queryType { name } } }", null, null);
    defer allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "\"queryType\"") != null);
}

test "handleQuery: real __type(name:) returns the requested type via parsed arg" {
    const allocator = testing.allocator;
    var database = try db.Database.init(allocator, ":memory:");
    defer database.deinit();
    var handler = try GraphQLHandler.init(allocator, &database, 10, 10000, false);
    defer handler.deinit();

    const found = try handler.handleQuery("{ __type(name:\"Domain\"){ name kind } }", null, null);
    defer allocator.free(found);
    try testing.expect(std.mem.indexOf(u8, found, "\"__type\"") != null);
    try testing.expect(std.mem.indexOf(u8, found, "Domain") != null);

    const missing = try handler.handleQuery("{ __type(name:\"NoSuchType\"){ name } }", null, null);
    defer allocator.free(missing);
    try testing.expectEqualStrings("{\"data\":{\"__type\":null}}", missing);
}
