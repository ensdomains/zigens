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
const query_validator = @import("query_validator.zig");

pub const GraphQLHandler = struct {
    allocator: std.mem.Allocator,
    executor: parser.Executor,
    schema_validator: schema_validator_mod.SchemaValidator,
    /// introspection.json parsed ONCE at init and reused by __type introspection,
    /// instead of re-parsing the whole document per request.
    introspection_parsed: std.json.Parsed(std.json.Value),
    complexity_max_depth: u32,
    complexity_max_cost: u32,
    metrics: metrics_mod.Metrics,

    pub fn init(allocator: std.mem.Allocator, max_depth: u32, max_cost: u32, metrics_enabled: bool) !GraphQLHandler {
        // Create execution context. The database is per-request: handleQuery sets it
        // on its stack copy of the executor (pool session) before any resolver runs,
        // so this template value is never read.
        const ctx = parser.ExecutionContext{
            .allocator = allocator,
            .database = undefined,
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
        try executor.registerResolver("_finality", resolvers.resolveFinality);
        try executor.registerResolver("_coverage", resolvers.resolveCoverage);

        // Build the schema validator once from the embedded introspection JSON.
        // It indexes the introspection types into hash maps used to reject
        // missing-required-arg / unknown-arg / unknown-input-object-field
        // before the query reaches the executor.
        const introspection_json = @embedFile("introspection.json");
        var schema_validator = try schema_validator_mod.SchemaValidator.init(allocator, introspection_json);
        errdefer schema_validator.deinit();

        const introspection_parsed = try std.json.parseFromSlice(std.json.Value, allocator, introspection_json, .{});
        errdefer introspection_parsed.deinit();

        return .{
            .allocator = allocator,
            .executor = executor,
            .schema_validator = schema_validator,
            .introspection_parsed = introspection_parsed,
            .complexity_max_depth = max_depth,
            .complexity_max_cost = max_cost,
            .metrics = metrics_mod.Metrics.init(allocator, metrics_enabled),
        };
    }

    pub fn deinit(self: *GraphQLHandler) void {
        self.metrics.deinit();
        self.executor.deinit();
        self.schema_validator.deinit();
        self.introspection_parsed.deinit();
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

    /// Handle a GraphQL query with optional variables.
    ///
    /// `strict` mirrors the server's content negotiation (true when the client Accepts
    /// `application/graphql-response+json`). It only gates spec-strict request-error
    /// behavior that the legacy `application/json` contract must NOT see — currently the
    /// variable-coercion check below. The error envelope itself is unchanged here; the
    /// server strips the `data` entry for strict 4xx request errors.
    pub fn handleQuery(self: *GraphQLHandler, database: *db.Database, query: []const u8, variables: ?std.json.Value, operation_name: ?[]const u8, strict: bool) ![]u8 {
        return self.handleQueryWithResolve(database, query, variables, operation_name, strict, null);
    }

    /// Like `handleQuery`, but with an optional live-resolution context (opaque pointer
    /// to resolve.universal.LiveContext) threaded into the executor so the record-read
    /// handlers can fall back to a live UR read on an indexed MISS. Pass null (what
    /// `handleQuery` does) for indexed-only behavior — the default everywhere.
    pub fn handleQueryWithResolve(self: *GraphQLHandler, database: *db.Database, query: []const u8, variables: ?std.json.Value, operation_name: ?[]const u8, strict: bool, resolve_ctx: ?*anyopaque) ![]u8 {
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
        var loader_context = try dataloader_mod.LoaderContext.init(request_alloc, database);
        defer loader_context.deinit();

        // Create a per-request executor copy to avoid race conditions when
        // multiple threads handle requests concurrently. The shared executor's
        // resolvers map is read-only and safe to share; per-request state
        // (fragments, variables, loaders) lives on this stack copy.
        var request_executor = self.executor;
        request_executor.allocator = request_alloc;
        request_executor.context.allocator = request_alloc;
        request_executor.context.database = @ptrCast(database);
        request_executor.context.loaders = @ptrCast(loader_context);
        request_executor.context.resolve = resolve_ctx; // null unless live resolution is on

        // Parse the query using the arena allocator
        var document = parser.parseQuery(request_alloc, query) catch |err| {
            // warn, not err: this is client-controlled input (any visitor can send an
            // unparseable query); err-level would let clients spam error alerts.
            std.log.warn("Failed to parse GraphQL query: {}", .{err});
            self.metrics.recordError();
            return try self.buildErrorResponseWithCode("Invalid GraphQL syntax", ErrorCode.SYNTAX_ERROR);
        };
        defer document.deinit(request_alloc);

        // Structural validation on the freshly-parsed document, BEFORE any pass
        // that traverses fragments (introspection routing, complexity analysis,
        // execution). Rejects cyclic and dangling fragment spreads — a cyclic
        // fragment would otherwise recurse until the native stack overflows and
        // crashes the process (both the analyzer and the executor expand spreads
        // with no visited-set).
        query_validator.validateDocument(request_alloc, &document) catch |err| {
            self.metrics.recordError();
            const msg = switch (err) {
                error.CyclicFragment => "Fragment spreads form a cycle",
                error.UnknownFragment => "Query references an undefined fragment",
                else => "Query validation failed",
            };
            return try self.buildErrorResponseWithCode(msg, ErrorCode.VALIDATION_ERROR);
        };

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
                if (std.mem.eql(u8, f.name, "__type")) return try self.handleTypeIntrospectionQuery(f, variables);
            }
        }

        // Strict-mode variable coercion (GraphQL-over-HTTP spec): a request that declares a
        // non-null variable but supplies it null — or omits it with no default — is a request
        // error and MUST surface as 4xx. Legacy `application/json` clients keep the lenient
        // 200 behavior (the audit's application/json variant requires 200), so this is gated
        // on `strict`. Emitting VALIDATION_ERROR makes the server map it to 400.
        if (strict) {
            const coerce_op: ?*const parser.Operation = sel: {
                if (operation_name) |nm| {
                    for (document.operations) |*o| {
                        if (o.name != null and std.mem.eql(u8, o.name.?, nm)) break :sel o;
                    }
                    break :sel null; // unknown named op — let the executor report it
                }
                if (document.operations.len == 1) break :sel &document.operations[0];
                break :sel null; // multiple unnamed ops — let the executor report it
            };
            if (coerce_op) |op| {
                for (op.variables) |vdef| {
                    if (!vdef.required) continue;
                    const provided: ?std.json.Value = if (variables) |vars|
                        (if (vars == .object) vars.object.get(vdef.name) else null)
                    else
                        null;
                    const violated = if (provided) |pv| pv == .null else (vdef.default_value == null);
                    if (violated) {
                        self.metrics.recordError();
                        const msg = try std.fmt.allocPrint(
                            self.allocator,
                            "Variable \"${s}\" of required type \"{s}\" was not provided a non-null value",
                            .{ vdef.name, vdef.type_name },
                        );
                        defer self.allocator.free(msg);
                        return try self.buildErrorResponseWithCode(msg, ErrorCode.VALIDATION_ERROR);
                    }
                }
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
            // warn, not err: execution failures include client-driven rejections
            // (complexity LimitExceeded, bad arguments) — not server faults.
            std.log.warn("Failed to execute GraphQL query: {}", .{err});
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

    fn handleTypeIntrospectionQuery(self: *GraphQLHandler, field: *const parser.Field, variables: ?std.json.Value) ![]u8 {
        // Read the requested type name from the parsed __type(name: ...) field. The literal
        // form `__type(name: "Domain")` resolves via getStringArg; the variable form
        // `__type(name: $name)` (used by the graphql-http conformance suite and by clients
        // that parameterize introspection) is resolved here against the request variables.
        const type_name = blk: {
            if (parser.getStringArg(field, "name", null)) |literal| break :blk literal;
            for (field.arguments) |*arg| {
                if (!std.mem.eql(u8, arg.name, "name")) continue;
                switch (arg.value) {
                    .variable => |var_name| {
                        if (variables) |vars| {
                            if (vars == .object) {
                                if (vars.object.get(var_name)) |jv| {
                                    if (jv == .string) break :blk jv.string;
                                }
                            }
                        }
                    },
                    else => {},
                }
            }
            return try self.buildErrorResponseWithCode("Invalid __type query: missing name argument", ErrorCode.VALIDATION_ERROR);
        };

        // Reuse the introspection parsed once at handler init (no per-request re-parse).
        const parsed = self.introspection_parsed;

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
        var response: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer response.deinit();

        const message_escaped = try json_utils.escapeString(self.allocator, message);
        defer self.allocator.free(message_escaped);

        const writer = &response.writer;

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

        return response.toOwnedSlice();
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
    var handler = try GraphQLHandler.init(allocator, 10, 10000, false);
    defer handler.deinit();

    const result = try handler.handleQuery(&database, query, null, op_name, false);
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
    var handler = try GraphQLHandler.init(allocator, 10, 10000, false);
    defer handler.deinit();

    const result = try handler.handleQuery(&database, "{ __schema { queryType { name } } }", null, null, false);
    defer allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "\"queryType\"") != null);
}

test "handleQuery: real __type(name:) returns the requested type via parsed arg" {
    const allocator = testing.allocator;
    var database = try db.Database.init(allocator, ":memory:");
    defer database.deinit();
    var handler = try GraphQLHandler.init(allocator, 10, 10000, false);
    defer handler.deinit();

    const found = try handler.handleQuery(&database, "{ __type(name:\"Domain\"){ name kind } }", null, null, false);
    defer allocator.free(found);
    try testing.expect(std.mem.indexOf(u8, found, "\"__type\"") != null);
    try testing.expect(std.mem.indexOf(u8, found, "Domain") != null);

    const missing = try handler.handleQuery(&database, "{ __type(name:\"NoSuchType\"){ name } }", null, null, false);
    defer allocator.free(missing);
    try testing.expectEqualStrings("{\"data\":{\"__type\":null}}", missing);
}

test "handleQuery: where with and/or boolean filter validates and executes (#25)" {
    const allocator = testing.allocator;
    var database = try db.Database.init(allocator, ":memory:");
    defer database.deinit();
    var handler = try GraphQLHandler.init(allocator, 10, 10000, false);
    defer handler.deinit();

    // owner=X AND (name_contains a OR name_contains b) — nested DomainFilter via `or`.
    const q = "{ domains(where:{ owner:\"0x1111111111111111111111111111111111111111\", or:[{name_contains:\"a\"},{name_contains:\"b\"}] }){ name } }";
    const result = try handler.handleQuery(&database, q, null, null, false);
    defer allocator.free(result);
    // Parsed + schema-validated + executed → a data response (empty list on an empty DB),
    // NOT a validation/syntax error.
    try testing.expect(std.mem.indexOf(u8, result, "\"data\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"errors\"") == null);
    try testing.expect(std.mem.indexOf(u8, result, "domains") != null);
}

test "handleQuery: eventConnection where and/or validates and executes (#25)" {
    const allocator = testing.allocator;
    var database = try db.Database.init(allocator, ":memory:");
    defer database.deinit();
    var handler = try GraphQLHandler.init(allocator, 10, 10000, false);
    defer handler.deinit();

    const q = "{ eventConnection(first:5, where:{ blockNumber_gt:0, or:[{type:\"Transfer\"},{type:\"NameRegistered\"}] }){ totalCount } }";
    const result = try handler.handleQuery(&database, q, null, null, false);
    defer allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "\"data\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"errors\"") == null);
}

test "handleQuery: registrationConnection where and/or validates and executes (#25)" {
    const allocator = testing.allocator;
    var database = try db.Database.init(allocator, ":memory:");
    defer database.deinit();
    var handler = try GraphQLHandler.init(allocator, 10, 10000, false);
    defer handler.deinit();

    const q = "{ registrationConnection(first:5, where:{ and:[{protocol:\"v2\"},{or:[{registrant:\"0x1111111111111111111111111111111111111111\"}]}] }){ totalCount } }";
    const result = try handler.handleQuery(&database, q, null, null, false);
    defer allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "\"data\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"errors\"") == null);
}

test "handleQuery: __type(name: $name) resolves the type from variables (graphql-http 28B9)" {
    const allocator = testing.allocator;
    var database = try db.Database.init(allocator, ":memory:");
    defer database.deinit();
    var handler = try GraphQLHandler.init(allocator, 10, 10000, false);
    defer handler.deinit();

    const vars = try std.json.parseFromSlice(std.json.Value, allocator, "{\"name\":\"Domain\"}", .{});
    defer vars.deinit();

    const result = try handler.handleQuery(
        &database,
        "query Type($name: String!) { __type(name: $name) { name } }",
        vars.value,
        null,
        false,
    );
    defer allocator.free(result);
    // A real data response for the requested type — NOT a "missing name argument" error.
    try testing.expect(std.mem.indexOf(u8, result, "\"__type\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Domain") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"errors\"") == null);
}

test "handleQuery: required variable given null errors only in strict mode (graphql-http 86EE/7B9B)" {
    const allocator = testing.allocator;
    var database = try db.Database.init(allocator, ":memory:");
    defer database.deinit();
    var handler = try GraphQLHandler.init(allocator, 10, 10000, false);
    defer handler.deinit();

    const vars = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":null}", .{});
    defer vars.deinit();
    const q = "query CoerceFailure($id: ID!){ __typename }";

    // Strict: a non-null variable supplied null is a request error -> VALIDATION_ERROR
    // (the server then maps this to HTTP 400).
    const strict_res = try handler.handleQuery(&database, q, vars.value, null, true);
    defer allocator.free(strict_res);
    try testing.expect(std.mem.indexOf(u8, strict_res, "VALIDATION_ERROR") != null);

    // Legacy: stays lenient — executes and returns data, no error (the 200 contract every
    // existing application/json client relies on).
    const legacy_res = try handler.handleQuery(&database, q, vars.value, null, false);
    defer allocator.free(legacy_res);
    try testing.expect(std.mem.indexOf(u8, legacy_res, "\"errors\"") == null);
    try testing.expect(std.mem.indexOf(u8, legacy_res, "\"data\"") != null);
}

test "handleQuery: resolver namedResources returns seeded associations" {
    const allocator = testing.allocator;
    var database = try db.Database.init(allocator, ":memory:");
    defer database.deinit();
    var handler = try GraphQLHandler.init(allocator, 10, 10000, false);
    defer handler.deinit();

    const Address = @import("../types/address.zig").Address;
    const Hash = @import("../types/hash.zig").Hash;
    const resolver = try Address.fromHex("0x00000000000000000000000000000000000000cc");
    try database.upsertNamedResource(.v2, resolver, "0x00000000000000000000000000000000000000000000000000000000000000a1", "text", "url", -1, "alice.eth", 123, Hash{ .bytes = [_]u8{1} ** 32 }, 0);

    const result = try handler.handleQuery(&database,
        \\{ resolver(id: "0x00000000000000000000000000000000000000cc") { namedResources { protocol resource recordKind recordKey coinType name blockNumber } } }
    , null, null, false);
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "\"recordKind\":\"text\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"recordKey\":\"url\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"name\":\"alice.eth\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"coinType\":\"-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"protocol\":\"v2\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"blockNumber\":123") != null);
    try testing.expect(std.mem.indexOf(u8, result, "00000000000000a1") != null);
}
