const std = @import("std");
const db = @import("../storage/database.zig");
const models = @import("../types/models.zig");
const Hash = @import("../types/hash.zig").Hash;
const Address = @import("../types/address.zig").Address;
const namehash = @import("../types/hash.zig").namehash;
const parser = @import("graphql_parser.zig");
const complexity = @import("query_complexity.zig");
const metrics_mod = @import("metrics.zig");
const pagination = @import("pagination.zig");
const json_utils = @import("../utils/json.zig");
const ens_normalize = @import("ens_normalize");

/// Maximum query depth to prevent DoS attacks
const MAX_QUERY_DEPTH: u32 = 10;

/// Max uint64 value representing "no expiry" for subnames
const NO_EXPIRY: u64 = std.math.maxInt(u64);

/// Check if expiry value represents a valid expiry date (not 0 or max uint64)
fn hasValidExpiry(expiry: u64) bool {
    return expiry > 0 and expiry < NO_EXPIRY;
}

/// Context for nested field resolution
const NestedContext = struct {
    database: *db.Database,
    depth: u32,
    allocator: std.mem.Allocator,
    loaders: ?*anyopaque, // LoaderContext pointer for batching
};

/// Helper to escape JSON strings using std.json (RFC 8259 compliant)
/// This is now a thin wrapper around json_utils which uses Zig's professional-grade std.json
fn escapeJsonString(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    return json_utils.escapeString(allocator, s);
}

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

        // Register all resolvers
        try executor.registerResolver("domain", resolveDomain);
        try executor.registerResolver("domains", resolveDomains);
        try executor.registerResolver("domainConnection", resolveDomainConnection);
        try executor.registerResolver("account", resolveAccount);
        try executor.registerResolver("registrations", resolveRegistrations);
        try executor.registerResolver("registrationConnection", resolveRegistrationConnection);
        try executor.registerResolver("events", resolveEvents);
        try executor.registerResolver("eventConnection", resolveEventConnection);
        try executor.registerResolver("roles", resolveRoles);
        try executor.registerResolver("resolvers", resolveResolvers);
        try executor.registerResolver("registries", resolveRegistries);
        try executor.registerResolver("metadata", resolveMetadata);
        try executor.registerResolver("approvals", resolveApprovals);

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

        // Create request-scoped DataLoader context for batching and caching
        const dataloader_mod = @import("dataloader.zig");
        var loader_context = try dataloader_mod.LoaderContext.init(self.allocator, self.database);
        defer loader_context.deinit();

        // Inject loaders into execution context for this request
        self.executor.context.loaders = @ptrCast(loader_context);

        // Parse the query using the new parser
        var document = parser.parseQuery(self.allocator, query) catch |err| {
            std.log.err("Failed to parse GraphQL query: {}", .{err});
            self.metrics.recordError();
            return try self.buildErrorResponseWithCode("Invalid GraphQL syntax", ErrorCode.SYNTAX_ERROR);
        };
        defer document.deinit(self.allocator);

        // Analyze query complexity to prevent DoS attacks
        const limits = complexity.ComplexityLimits{
            .max_depth = self.complexity_max_depth,
            .max_cost = self.complexity_max_cost,
        };
        var analyzer = complexity.ComplexityAnalyzer.init(self.allocator, limits);
        const analysis = try analyzer.analyzeDocument(&document);

        if (!analysis.isValid()) {
            const error_msg = try analysis.errorMessage(self.allocator);
            defer self.allocator.free(error_msg);
            std.log.warn("Query complexity violation: {s}", .{error_msg});
            self.metrics.recordRejection(analysis.depth, analysis.cost);
            return try self.buildErrorResponseWithCode(error_msg, ErrorCode.COMPLEXITY_LIMIT_EXCEEDED);
        }

        std.log.debug("Query complexity: depth={d}, cost={d}", .{ analysis.depth, analysis.cost });

        // Execute the parsed query with variables (with DataLoaders available)
        const result = self.executor.executeDocument(&document, variables, operation_name) catch |err| {
            std.log.err("Failed to execute GraphQL query: {}", .{err});
            self.metrics.recordError();
            if (err == error.OperationNotFound) {
                return try self.buildErrorResponseWithCode("Operation not found", ErrorCode.VALIDATION_ERROR);
            } else if (err == error.OperationNameRequired) {
                return try self.buildErrorResponseWithCode("Must provide operation name when query contains multiple operations", ErrorCode.VALIDATION_ERROR);
            } else if (err == error.InvalidContractAddress) {
                return try self.buildErrorResponseWithCode("Invalid contractAddress: must be a valid Ethereum address (40 hex characters with 0x prefix)", ErrorCode.INVALID_ARGUMENT);
            }
            return try self.buildErrorResponseWithCode("Query execution failed", ErrorCode.EXECUTION_ERROR);
        };

        // Record successful query with timing
        const duration_us = timer.elapsedMicroseconds();
        self.metrics.recordQuery(duration_us, analysis.depth, analysis.cost);

        // Log DataLoader cache statistics
        const stats = loader_context.getAllStats();
        const hit_rate = stats.resolver_address.hitRate();
        const avg_batch = stats.resolver_address.avgBatchSize();
        std.log.debug("DataLoader stats - Resolver addresses: {d} cached, {d} hits, {d} misses, hit rate: {d:.2}%, {d} batches, avg batch size: {d:.2}", .{ stats.resolver_address.entries, stats.resolver_address.cache_hits, stats.resolver_address.cache_misses, hit_rate * 100, stats.resolver_address.batch_loads, avg_batch });

        return result;
    }

    fn handleMultiFieldQuery(self: *GraphQLHandler, query: []const u8) ![]u8 {
        // Handle queries with multiple root-level fields by calling each handler
        // and merging the JSON results

        var response: std.ArrayList(u8) = .{};
        defer response.deinit(self.allocator);

        try response.appendSlice(self.allocator, "{\"data\":{");

        var first = true;

        // Check each field and call its handler
        if (std.mem.indexOf(u8, query, "domain(") != null) {
            if (!first) try response.appendSlice(self.allocator, ",");
            const result = try self.handleDomainQuery(query);
            defer self.allocator.free(result);
            // Extract just the data field content
            if (try self.extractDataField(result)) |data| {
                defer self.allocator.free(data);
                try response.appendSlice(self.allocator, data);
                first = false;
            }
        }

        if (std.mem.indexOf(u8, query, "domains(") != null) {
            if (!first) try response.appendSlice(self.allocator, ",");
            const result = try self.handleDomainsQuery(query);
            defer self.allocator.free(result);
            if (try self.extractDataField(result)) |data| {
                defer self.allocator.free(data);
                try response.appendSlice(self.allocator, data);
                first = false;
            }
        }

        if (std.mem.indexOf(u8, query, "account(") != null) {
            if (!first) try response.appendSlice(self.allocator, ",");
            const result = try self.handleAccountQuery(query);
            defer self.allocator.free(result);
            if (try self.extractDataField(result)) |data| {
                defer self.allocator.free(data);
                try response.appendSlice(self.allocator, data);
                first = false;
            }
        }

        if (std.mem.indexOf(u8, query, "registrations(") != null) {
            if (!first) try response.appendSlice(self.allocator, ",");
            const result = try self.handleRegistrationsQuery(query);
            defer self.allocator.free(result);
            if (try self.extractDataField(result)) |data| {
                defer self.allocator.free(data);
                try response.appendSlice(self.allocator, data);
                first = false;
            }
        }

        if (std.mem.indexOf(u8, query, "events(") != null) {
            if (!first) try response.appendSlice(self.allocator, ",");
            const result = try self.handleEventsQuery(query);
            defer self.allocator.free(result);
            if (try self.extractDataField(result)) |data| {
                defer self.allocator.free(data);
                try response.appendSlice(self.allocator, data);
                first = false;
            }
        }

        if (std.mem.indexOf(u8, query, "roles(") != null) {
            if (!first) try response.appendSlice(self.allocator, ",");
            const result = try self.handleRolesQuery(query);
            defer self.allocator.free(result);
            if (try self.extractDataField(result)) |data| {
                defer self.allocator.free(data);
                try response.appendSlice(self.allocator, data);
                first = false;
            }
        }

        if (std.mem.indexOf(u8, query, "resolvers(") != null) {
            if (!first) try response.appendSlice(self.allocator, ",");
            const result = try self.handleResolversQuery(query);
            defer self.allocator.free(result);
            if (try self.extractDataField(result)) |data| {
                defer self.allocator.free(data);
                try response.appendSlice(self.allocator, data);
                first = false;
            }
        }

        if (std.mem.indexOf(u8, query, "registries(") != null) {
            if (!first) try response.appendSlice(self.allocator, ",");
            const result = try self.handleRegistriesQuery(query);
            defer self.allocator.free(result);
            if (try self.extractDataField(result)) |data| {
                defer self.allocator.free(data);
                try response.appendSlice(self.allocator, data);
                first = false;
            }
        }

        if (std.mem.indexOf(u8, query, "metadata(") != null) {
            if (!first) try response.appendSlice(self.allocator, ",");
            const result = try self.handleMetadataQuery(query);
            defer self.allocator.free(result);
            if (try self.extractDataField(result)) |data| {
                defer self.allocator.free(data);
                try response.appendSlice(self.allocator, data);
                first = false;
            }
        }

        if (std.mem.indexOf(u8, query, "approvals(") != null or std.mem.indexOf(u8, query, "approvals {") != null) {
            if (!first) try response.appendSlice(self.allocator, ",");
            const result = try self.handleApprovalsQuery(query);
            defer self.allocator.free(result);
            if (try self.extractDataField(result)) |data| {
                defer self.allocator.free(data);
                try response.appendSlice(self.allocator, data);
                first = false;
            }
        }

        try response.appendSlice(self.allocator, "}}");

        return try self.allocator.dupe(u8, response.items);
    }

    fn extractDataField(self: *GraphQLHandler, json: []const u8) !?[]const u8 {
        // Extract the content inside {"data":{...}}
        // Returns the inner content like "domains":[...] or "events":[...]
        const data_start = std.mem.indexOf(u8, json, "{\"data\":{");
        if (data_start == null) return null;

        const content_start = data_start.? + 9; // Skip {"data":{
        const content_end = std.mem.lastIndexOf(u8, json, "}}");
        if (content_end == null or content_end.? <= content_start) return null;

        return try self.allocator.dupe(u8, json[content_start..content_end.?]);
    }

    fn handleDomainQuery(self: *GraphQLHandler, query: []const u8) ![]u8 {
        // Extract domain name from query
        // Example: domain(id: "alice.eth")
        const name = try self.extractStringParam(query, "id:");

        if (name.len == 0) {
            return try self.buildErrorResponse("Domain name required");
        }

        const nh = try namehash(self.allocator, name);
        const domain = try self.database.getNameByNamehash(nh);

        if (domain) |d| {
            var domain_copy = d;
            defer domain_copy.deinit(self.allocator);
            return try self.buildDomainResponse(domain_copy);
        } else {
            return try self.buildNullResponse("domain");
        }
    }

    fn handleDomainsQuery(self: *GraphQLHandler, query: []const u8) ![]u8 {
        // Parse parameters: first, skip, where
        const first = self.extractIntParam(query, "first:") catch 100;
        const skip = self.extractIntParam(query, "skip:") catch 0;

        // Try to extract owner filter from where clause
        var owner_filter: ?Address = null;
        if (std.mem.indexOf(u8, query, "where:")) |where_start| {
            if (std.mem.indexOf(u8, query[where_start..], "owner:")) |_| {
                const owner_str = try self.extractStringParam(query, "owner:");
                if (owner_str.len > 0) {
                    owner_filter = Address.fromHex(owner_str) catch null;
                }
            }
        }

        // Query actual name records from database
        const names = try self.database.getAllNames(owner_filter, @intCast(skip), @intCast(first));
        defer {
            for (names) |*name| {
                name.deinit(self.allocator);
            }
            self.allocator.free(names);
        }

        return try self.buildArrayResponse("domains", names, query);
    }

    fn handleAccountQuery(self: *GraphQLHandler, query: []const u8) ![]u8 {
        // Extract account address from query
        // Example: account(id: "0x123...")
        const address_str = try self.extractStringParam(query, "id:");

        if (address_str.len == 0) {
            return try self.buildErrorResponse("Account address required");
        }

        const address = Address.fromHex(address_str) catch {
            return try self.buildErrorResponse("Invalid address format");
        };

        return try self.buildAccountResponse(address);
    }

    fn handleRegistrationsQuery(self: *GraphQLHandler, query: []const u8) ![]u8 {
        _ = query;
        // Query recent name registrations
        const events = try self.database.getRecentEvents(null, .name_registered, 50);
        defer {
            for (events) |*event| {
                event.deinit(self.allocator);
            }
            self.allocator.free(events);
        }

        var response: std.ArrayList(u8) = .{};
        defer response.deinit(self.allocator);

        try response.appendSlice(self.allocator, "{\"data\":{\"registrations\":[");
        for (events, 0..) |event, i| {
            if (i > 0) try response.appendSlice(self.allocator, ",");
            if (event.name) |name| {
                const item = try std.fmt.allocPrint(self.allocator, "{{\"name\":\"{s}\",\"block\":{d},\"timestamp\":{d}}}", .{ name, event.block_number, event.timestamp });
                defer self.allocator.free(item);
                try response.appendSlice(self.allocator, item);
            }
        }
        try response.appendSlice(self.allocator, "]}}");

        return try self.allocator.dupe(u8, response.items);
    }

    fn handleEventsQuery(self: *GraphQLHandler, query: []const u8) ![]u8 {
        _ = query;
        // Query recent events
        const events = try self.database.getRecentEvents(null, null, 50);
        defer {
            for (events) |*event| {
                event.deinit(self.allocator);
            }
            self.allocator.free(events);
        }

        var response: std.ArrayList(u8) = .{};
        defer response.deinit(self.allocator);

        try response.appendSlice(self.allocator, "{\"data\":{\"events\":[");
        for (events, 0..) |event, i| {
            if (i > 0) try response.appendSlice(self.allocator, ",");

            const tx_hash = try event.tx_hash.toHex(self.allocator);
            defer self.allocator.free(tx_hash);
            const contract_addr = try event.contract_address.toHex(self.allocator);
            defer self.allocator.free(contract_addr);

            const name_str = if (event.name) |n|
                try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{n})
            else
                try self.allocator.dupe(u8, "null");
            defer self.allocator.free(name_str);

            const namehash_str = if (event.namehash) |nh| blk: {
                const h = try nh.toHex(self.allocator);
                defer self.allocator.free(h);
                break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{h});
            } else try self.allocator.dupe(u8, "null");
            defer self.allocator.free(namehash_str);

            const item = try std.fmt.allocPrint(
                self.allocator,
                "{{\"id\":\"{s}-{d}\",\"type\":\"{s}\",\"blockNumber\":{d},\"transactionHash\":\"{s}\",\"timestamp\":{d},\"name\":{s},\"namehash\":{s},\"contractAddress\":\"{s}\"}}",
                .{ tx_hash, event.log_index, event.event_type.toString(), event.block_number, tx_hash, event.timestamp, name_str, namehash_str, contract_addr },
            );
            defer self.allocator.free(item);
            try response.appendSlice(self.allocator, item);
        }
        try response.appendSlice(self.allocator, "]}}");

        return try self.allocator.dupe(u8, response.items);
    }

    fn handleRolesQuery(self: *GraphQLHandler, query: []const u8) ![]u8 {
        // Extract parameters: roles(resource: "0x...", account: "0x...")
        // Both are optional - can query by either or both
        const resource = try self.extractStringParam(query, "resource:");
        const account_str = try self.extractStringParam(query, "account:");

        const chain = models.Chain.l2; // TODO: Make configurable

        var roles: []models.EACRoleAssignment = undefined;
        defer {
            for (roles) |*role| {
                role.deinit(self.allocator);
            }
            self.allocator.free(roles);
        }

        // Query based on provided parameters
        if (resource.len > 0 and account_str.len == 0) {
            // Query by resource only
            roles = try self.database.getRolesByResource(chain, resource);
        } else if (account_str.len > 0 and resource.len == 0) {
            // Query by account only
            const account = try Address.fromHex(account_str);
            roles = try self.database.getRolesByAccount(chain, account);
        } else if (account_str.len > 0 and resource.len > 0) {
            // Query by both - get by resource and filter by account
            const account = try Address.fromHex(account_str);
            const all_roles = try self.database.getRolesByResource(chain, resource);
            defer {
                for (all_roles) |*r| {
                    r.deinit(self.allocator);
                }
                self.allocator.free(all_roles);
            }

            var filtered: std.ArrayList(models.EACRoleAssignment) = .{};
            defer filtered.deinit(self.allocator);

            for (all_roles) |role| {
                if (role.account.eql(account)) {
                    try filtered.append(self.allocator, .{
                        .id = role.id,
                        .chain = role.chain,
                        .resource = try self.allocator.dupe(u8, role.resource),
                        .account = role.account,
                        .role_bitmap = try self.allocator.dupe(u8, role.role_bitmap),
                        .block_number = role.block_number,
                        .tx_hash = role.tx_hash,
                        .log_index = role.log_index,
                        .timestamp = role.timestamp,
                    });
                }
            }
            roles = try filtered.toOwnedSlice(self.allocator);
        } else {
            // No parameters provided - return empty array
            roles = &[_]models.EACRoleAssignment{};
        }

        // Build JSON response
        var response: std.ArrayList(u8) = .{};
        defer response.deinit(self.allocator);

        try response.appendSlice(self.allocator, "{\"data\":{\"roles\":[");
        for (roles, 0..) |role, i| {
            if (i > 0) try response.appendSlice(self.allocator, ",");

            const account_hex = try role.account.toHex(self.allocator);
            defer self.allocator.free(account_hex);
            const tx_hash_hex = try role.tx_hash.toHex(self.allocator);
            defer self.allocator.free(tx_hash_hex);

            const item = try std.fmt.allocPrint(
                self.allocator,
                "{{\"id\":\"{d}\",\"resource\":\"{s}\",\"account\":\"{s}\",\"roleBitmap\":\"{s}\",\"blockNumber\":{d},\"transactionHash\":\"{s}\",\"timestamp\":{d}}}",
                .{ role.id, role.resource, account_hex, role.role_bitmap, role.block_number, tx_hash_hex, role.timestamp },
            );
            defer self.allocator.free(item);
            try response.appendSlice(self.allocator, item);
        }
        try response.appendSlice(self.allocator, "]}}");

        return try self.allocator.dupe(u8, response.items);
    }

    fn handleResolversQuery(self: *GraphQLHandler, query: []const u8) ![]u8 {
        // Extract account parameter: resolvers(account: "0x...")
        const account_str = try self.extractStringParam(query, "account:");

        if (account_str.len == 0) {
            return try self.buildErrorResponse("Account address required");
        }

        const account = Address.fromHex(account_str) catch {
            return try self.buildErrorResponse("Invalid account address");
        };

        const chain = models.Chain.l2; // TODO: Make configurable

        // Get all resolvers for this account (works for N-level domains)
        const resolvers_list = try self.database.getResolversByOwner(chain, account);
        defer {
            for (resolvers_list) |*resolver| {
                resolver.deinit(self.allocator);
            }
            self.allocator.free(resolvers_list);
        }

        // Build JSON response
        var response: std.ArrayList(u8) = .{};
        defer response.deinit(self.allocator);

        try response.appendSlice(self.allocator, "{\"data\":{\"resolvers\":[");
        for (resolvers_list, 0..) |resolver, i| {
            if (i > 0) try response.appendSlice(self.allocator, ",");

            const address_hex = try resolver.address.toHex(self.allocator);
            defer self.allocator.free(address_hex);
            const namehash_hex = try resolver.namehash.toHex(self.allocator);
            defer self.allocator.free(namehash_hex);

            const item = try std.fmt.allocPrint(
                self.allocator,
                "{{\"address\":\"{s}\",\"name\":\"{s}\",\"namehash\":\"{s}\",\"setBlock\":{d},\"setAt\":{d}}}",
                .{ address_hex, resolver.name, namehash_hex, resolver.set_block, resolver.set_at },
            );
            defer self.allocator.free(item);
            try response.appendSlice(self.allocator, item);
        }
        try response.appendSlice(self.allocator, "]}}");

        return try self.allocator.dupe(u8, response.items);
    }

    fn handleRegistriesQuery(self: *GraphQLHandler, query: []const u8) ![]u8 {
        // Extract owner parameter: registries(owner: "0x...")
        const owner_str = try self.extractStringParam(query, "owner:");

        if (owner_str.len == 0) {
            return try self.buildErrorResponse("Owner address required");
        }

        const owner = Address.fromHex(owner_str) catch {
            return try self.buildErrorResponse("Invalid owner address");
        };

        const chain = models.Chain.l2; // TODO: Make configurable

        // Get all registries owned by this account (works for N-level domains)
        const registries = try self.database.getRegistriesByOwner(chain, owner);
        defer {
            for (registries) |*registry| {
                registry.deinit(self.allocator);
            }
            self.allocator.free(registries);
        }

        // Build JSON response
        var response: std.ArrayList(u8) = .{};
        defer response.deinit(self.allocator);

        try response.appendSlice(self.allocator, "{\"data\":{\"registries\":[");
        for (registries, 0..) |registry, i| {
            if (i > 0) try response.appendSlice(self.allocator, ",");

            const address_hex = try registry.address.toHex(self.allocator);
            defer self.allocator.free(address_hex);
            const namehash_hex = try registry.namehash.toHex(self.allocator);
            defer self.allocator.free(namehash_hex);
            const parent_hex = try registry.parent_registry.toHex(self.allocator);
            defer self.allocator.free(parent_hex);

            const item = try std.fmt.allocPrint(
                self.allocator,
                "{{\"address\":\"{s}\",\"name\":\"{s}\",\"namehash\":\"{s}\",\"parentRegistry\":\"{s}\",\"createdBlock\":{d},\"createdAt\":{d}}}",
                .{ address_hex, registry.name, namehash_hex, parent_hex, registry.created_block, registry.created_at },
            );
            defer self.allocator.free(item);
            try response.appendSlice(self.allocator, item);
        }
        try response.appendSlice(self.allocator, "]}}");

        return try self.allocator.dupe(u8, response.items);
    }

    fn handleMetadataQuery(self: *GraphQLHandler, query: []const u8) ![]u8 {
        // Extract resolver parameter: metadata(resolver: "0x...")
        const resolver_str = try self.extractStringParam(query, "resolver:");

        if (resolver_str.len == 0) {
            return try self.buildErrorResponse("Resolver address required");
        }

        const resolver = Address.fromHex(resolver_str) catch {
            return try self.buildErrorResponse("Invalid resolver address");
        };

        const chain = models.Chain.l2; // TODO: Make configurable

        // Get resolver metadata
        const metadata_opt = try self.database.getResolverMetadata(chain, resolver);
        if (metadata_opt == null) {
            // Return null for not found
            return try self.allocator.dupe(u8, "{\"data\":{\"metadata\":null}}");
        }
        var metadata = metadata_opt.?;
        defer metadata.deinit(self.allocator);

        // Build JSON response
        const resolver_hex = try metadata.resolver.toHex(self.allocator);
        defer self.allocator.free(resolver_hex);
        const tx_hash_hex = try metadata.tx_hash.toHex(self.allocator);
        defer self.allocator.free(tx_hash_hex);

        const response = try std.fmt.allocPrint(
            self.allocator,
            "{{\"data\":{{\"metadata\":{{\"id\":\"{d}\",\"resolver\":\"{s}\",\"graphqlUrl\":\"{s}\",\"blockNumber\":{d},\"transactionHash\":\"{s}\",\"timestamp\":{d}}}}}}}",
            .{ metadata.id, resolver_hex, metadata.graphql_url, metadata.block_number, tx_hash_hex, metadata.timestamp },
        );

        return response;
    }

    fn handleApprovalsQuery(self: *GraphQLHandler, query: []const u8) ![]u8 {
        // Extract optional parameters: approvals(namehash: "0x...", delegate: "0x...")
        const namehash_str = self.extractStringParam(query, "namehash:") catch "";
        const delegate_str = self.extractStringParam(query, "delegate:") catch "";

        const chain = models.Chain.l2; // TODO: Make configurable

        // Determine which query to use based on parameters
        var approvals_list: []models.ResolverApproval = undefined;

        if (namehash_str.len > 0) {
            // Query by namehash
            const name_hash = Hash.fromHex(namehash_str) catch {
                return try self.buildErrorResponse("Invalid namehash");
            };
            approvals_list = try self.database.getApprovalsForName(chain, name_hash, null);
        } else if (delegate_str.len > 0) {
            // Query by delegate
            const delegate = Address.fromHex(delegate_str) catch {
                return try self.buildErrorResponse("Invalid delegate address");
            };
            approvals_list = try self.database.getApprovalsForDelegate(chain, delegate);
        } else {
            // No filters - return empty array or error
            return try self.allocator.dupe(u8, "{\"data\":{\"approvals\":[]}}");
        }

        defer {
            for (approvals_list) |*approval| {
                approval.deinit(self.allocator);
            }
            self.allocator.free(approvals_list);
        }

        // Build JSON response
        var response: std.ArrayList(u8) = .{};
        defer response.deinit(self.allocator);

        try response.appendSlice(self.allocator, "{\"data\":{\"approvals\":[");
        for (approvals_list, 0..) |approval, i| {
            if (i > 0) try response.appendSlice(self.allocator, ",");

            const resolver_hex = try approval.resolver.toHex(self.allocator);
            defer self.allocator.free(resolver_hex);
            const namehash_hex = try approval.namehash.toHex(self.allocator);
            defer self.allocator.free(namehash_hex);
            const delegate_hex = try approval.delegate.toHex(self.allocator);
            defer self.allocator.free(delegate_hex);
            const tx_hash_hex = try approval.tx_hash.toHex(self.allocator);
            defer self.allocator.free(tx_hash_hex);

            const context_str = if (approval.context) |ctx|
                try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{ctx})
            else
                try self.allocator.dupe(u8, "null");
            defer self.allocator.free(context_str);

            const item = try std.fmt.allocPrint(
                self.allocator,
                "{{\"id\":\"{d}\",\"resolver\":\"{s}\",\"namehash\":\"{s}\",\"context\":{s},\"delegate\":\"{s}\",\"approved\":{},\"blockNumber\":{d},\"transactionHash\":\"{s}\",\"logIndex\":{d},\"timestamp\":{d}}}",
                .{ approval.id, resolver_hex, namehash_hex, context_str, delegate_hex, approval.approved, approval.block_number, tx_hash_hex, approval.log_index, approval.timestamp },
            );
            defer self.allocator.free(item);
            try response.appendSlice(self.allocator, item);
        }
        try response.appendSlice(self.allocator, "]}}");

        return try self.allocator.dupe(u8, response.items);
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

    fn buildDomainResponse(self: *GraphQLHandler, domain: models.Name) ![]u8 {
        var response: std.ArrayList(u8) = .{};
        errdefer response.deinit(self.allocator);

        const owner_hex = try domain.owner.toHex(self.allocator);
        defer self.allocator.free(owner_hex);

        const resolver_hex = try domain.resolver.toHex(self.allocator);
        defer self.allocator.free(resolver_hex);

        const registry_hex = try domain.registry.toHex(self.allocator);
        defer self.allocator.free(registry_hex);

        const namehash_hex = try domain.namehash.toHex(self.allocator);
        defer self.allocator.free(namehash_hex);

        const labelhash_hex = try domain.label_hash.toHex(self.allocator);
        defer self.allocator.free(labelhash_hex);

        const name_escaped = try escapeJsonString(self.allocator, domain.name);
        defer self.allocator.free(name_escaped);

        const label_escaped = try escapeJsonString(self.allocator, domain.label);
        defer self.allocator.free(label_escaped);

        const parent_escaped = try escapeJsonString(self.allocator, domain.parent_name);
        defer self.allocator.free(parent_escaped);

        // Fetch resolver data
        const addr = self.database.getResolverAddress(domain.namehash, 60) catch null; // Coin type 60 = ETH
        defer if (addr) |a| self.allocator.free(a);

        const content_hash = self.database.getResolverContentHash(domain.namehash) catch null;
        defer if (content_hash) |ch| self.allocator.free(ch);

        const text_keys = self.database.getResolverTextKeys(domain.namehash) catch &[_][]u8{};
        defer {
            for (text_keys) |key| {
                self.allocator.free(key);
            }
            self.allocator.free(text_keys);
        }

        const writer = response.writer(self.allocator);
        try writer.writeAll("{\"data\":{\"domain\":{");
        try writer.print("\"id\":\"{s}\",", .{name_escaped});
        try writer.print("\"name\":\"{s}\",", .{name_escaped});
        try writer.print("\"labelName\":\"{s}\",", .{label_escaped});
        try writer.print("\"labelhash\":\"{s}\",", .{labelhash_hex});
        try writer.print("\"parent\":{{\"id\":\"{s}\",\"name\":\"{s}\"}},", .{ parent_escaped, parent_escaped });
        try writer.writeAll("\"subdomains\":[],");
        try writer.print("\"resolvedAddress\":{{\"id\":\"{s}\"}},", .{owner_hex});
        try writer.print("\"owner\":{{\"id\":\"{s}\"}},", .{owner_hex});

        // Write resolver with data
        try writer.print("\"resolver\":{{\"id\":\"{s}\",\"address\":\"{s}\"", .{ resolver_hex, resolver_hex });
        if (addr) |a| {
            try writer.print(",\"addr\":\"{s}\"", .{a});
        } else {
            try writer.writeAll(",\"addr\":null");
        }
        if (content_hash) |ch| {
            try writer.print(",\"contentHash\":\"{s}\"", .{ch});
        } else {
            try writer.writeAll(",\"contentHash\":null");
        }
        try writer.writeAll(",\"texts\":[");
        for (text_keys, 0..) |key, idx| {
            if (idx > 0) try writer.writeAll(",");
            try writer.print("\"{s}\"", .{key});
        }
        try writer.writeAll("]},");
        try writer.writeAll("\"ttl\":null,");
        try writer.print("\"isMigrated\":{},", .{domain.migrated});
        try writer.print("\"createdAt\":{d},", .{domain.created_at});
        try writer.print("\"registrant\":{{\"id\":\"{s}\"}},", .{owner_hex});
        try writer.print("\"registrationDate\":{d},", .{domain.created_at});
        if (hasValidExpiry(domain.expiry)) {
            try writer.print("\"expiryDate\":{d},", .{domain.expiry});
        } else {
            try writer.writeAll("\"expiryDate\":null,");
        }

        // Add tokenId, canonicalId, and tokenVersion
        const token_id_hex = try std.fmt.allocPrint(self.allocator, "0x{x:0>64}", .{domain.token_id});
        defer self.allocator.free(token_id_hex);
        try writer.print("\"tokenId\":\"{s}\",", .{token_id_hex});

        const canonical_id_hex = try std.fmt.allocPrint(self.allocator, "0x{x:0>64}", .{domain.canonical_id});
        defer self.allocator.free(canonical_id_hex);
        try writer.print("\"canonicalId\":\"{s}\",", .{canonical_id_hex});

        try writer.print("\"tokenVersion\":{d}", .{domain.token_version});

        try writer.writeAll("}}}");

        return response.toOwnedSlice(self.allocator);
    }

    fn buildAccountResponse(self: *GraphQLHandler, address: Address) ![]u8 {
        var response: std.ArrayList(u8) = .{};
        errdefer response.deinit(self.allocator);

        const address_hex = try address.toHex(self.allocator);
        defer self.allocator.free(address_hex);

        const writer = response.writer(self.allocator);
        try writer.print("{{\"data\":{{\"account\":{{\"id\":\"{s}\",\"domains\":[],\"registrations\":[]}}}}}}", .{address_hex});

        return response.toOwnedSlice(self.allocator);
    }

    /// Extract requested fields from a GraphQL query
    fn extractRequestedFields(self: *GraphQLHandler, query: []const u8, field_name: []const u8) !std.StringHashMap(bool) {
        var fields = std.StringHashMap(bool).init(self.allocator);

        // Find the field name in the query (e.g., "domains")
        const field_pos = std.mem.indexOf(u8, query, field_name) orelse return fields;

        // Find the opening brace of the selection set after the field name
        const search_start = field_pos + field_name.len;
        const start_idx = std.mem.indexOfPos(u8, query, search_start, "{") orelse return fields;

        // Find the matching closing brace
        var depth: i32 = 1;
        var end_idx = start_idx + 1;
        while (end_idx < query.len and depth > 0) {
            if (query[end_idx] == '{') depth += 1;
            if (query[end_idx] == '}') depth -= 1;
            end_idx += 1;
        }

        if (depth != 0) return fields; // Mismatched braces

        const selection = query[start_idx + 1 .. end_idx - 1];

        // Parse field names (simple tokenization)
        var i: usize = 0;
        while (i < selection.len) {
            // Skip whitespace and comments
            while (i < selection.len and (selection[i] == ' ' or selection[i] == '\n' or selection[i] == '\r' or selection[i] == '\t' or selection[i] == ',')) {
                i += 1;
            }
            if (i >= selection.len) break;

            // Skip comments
            if (i < selection.len - 1 and selection[i] == '#') {
                while (i < selection.len and selection[i] != '\n') i += 1;
                continue;
            }

            // Extract field name
            const field_start = i;
            while (i < selection.len and
                   selection[i] != ' ' and selection[i] != '\n' and
                   selection[i] != '\r' and selection[i] != '\t' and
                   selection[i] != '{' and selection[i] != '}' and selection[i] != ',') {
                i += 1;
            }

            if (i > field_start) {
                const extracted_field = selection[field_start..i];
                if (extracted_field.len > 0) {
                    try fields.put(extracted_field, true);
                }

                // Handle nested selections (e.g., owner { id }, resolver { address })
                // Skip whitespace before potential opening brace
                while (i < selection.len and (selection[i] == ' ' or selection[i] == '\n' or selection[i] == '\r' or selection[i] == '\t')) {
                    i += 1;
                }

                if (i < selection.len and selection[i] == '{') {
                    const parent_field = extracted_field;
                    const nested_start = i + 1;

                    // Find matching closing brace for this nested selection
                    var nested_depth: i32 = 1;
                    var nested_end = nested_start;
                    while (nested_end < selection.len and nested_depth > 0) {
                        if (selection[nested_end] == '{') nested_depth += 1;
                        if (selection[nested_end] == '}') nested_depth -= 1;
                        if (nested_depth > 0) nested_end += 1;
                    }

                    // Parse nested fields and add them with dot notation
                    const nested_selection = selection[nested_start..nested_end];
                    var j: usize = 0;
                    while (j < nested_selection.len) {
                        // Skip whitespace
                        while (j < nested_selection.len and (nested_selection[j] == ' ' or nested_selection[j] == '\n' or nested_selection[j] == '\r' or nested_selection[j] == '\t' or nested_selection[j] == ',')) {
                            j += 1;
                        }
                        if (j >= nested_selection.len) break;

                        // Extract nested field name
                        const nested_field_start = j;
                        while (j < nested_selection.len and
                               nested_selection[j] != ' ' and nested_selection[j] != '\n' and
                               nested_selection[j] != '\r' and nested_selection[j] != '\t' and
                               nested_selection[j] != '{' and nested_selection[j] != '}' and nested_selection[j] != ',') {
                            j += 1;
                        }

                        if (j > nested_field_start) {
                            const nested_field = nested_selection[nested_field_start..j];
                            // Add with dot notation: "resolver.address", "owner.id", etc.
                            // Note: We allocate this string and it will be used by the hash map.
                            // It should be freed after the hash map is done being used.
                            const dotted_field = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ parent_field, nested_field });
                            try fields.put(dotted_field, true);
                        }

                        // Skip any further nested selections (we only go one level deep)
                        if (j < nested_selection.len and nested_selection[j] == '{') {
                            var skip_depth: i32 = 1;
                            j += 1;
                            while (j < nested_selection.len and skip_depth > 0) {
                                if (nested_selection[j] == '{') skip_depth += 1;
                                if (nested_selection[j] == '}') skip_depth -= 1;
                                j += 1;
                            }
                        }
                    }

                    i = nested_end + 1; // Skip past the closing brace
                    continue;
                }
            }
        }

        return fields;
    }

    fn buildArrayResponse(self: *GraphQLHandler, field_name: []const u8, items: []const models.Name, query: []const u8) ![]u8 {
        // Extract which fields were requested
        var requested_fields = try self.extractRequestedFields(query, field_name);
        defer {
            // Free allocated dotted field strings (e.g., "resolver.address")
            var it = requested_fields.keyIterator();
            while (it.next()) |key| {
                if (std.mem.indexOf(u8, key.*, ".") != null) {
                    self.allocator.free(key.*);
                }
            }
            requested_fields.deinit();
        }

        // If no fields were extracted, default to basic fields
        if (requested_fields.count() == 0) {
            try requested_fields.put("id", true);
            try requested_fields.put("name", true);
            try requested_fields.put("owner", true);
        }

        var response: std.ArrayList(u8) = .{};
        errdefer response.deinit(self.allocator);

        const writer = response.writer(self.allocator);
        try writer.writeAll("{\"data\":{\"");
        try writer.writeAll(field_name);
        try writer.writeAll("\":[");

        // Batch-load content hashes and text records if needed to eliminate N+1 queries
        const need_content_hash = requested_fields.contains("resolver.contentHash");
        const need_texts = requested_fields.contains("resolver.texts");

        var content_hash_map: ?std.AutoHashMap([32]u8, ?[]const u8) = null;
        defer {
            if (content_hash_map) |*map| {
                var it = map.valueIterator();
                while (it.next()) |val_ptr| {
                    if (val_ptr.*) |val| {
                        self.allocator.free(val);
                    }
                }
                map.deinit();
            }
        }

        var text_records_map: ?std.AutoHashMap([32]u8, @import("dataloader.zig").TextRecords) = null;
        defer {
            if (text_records_map) |*map| {
                var it = map.valueIterator();
                while (it.next()) |val_ptr| {
                    val_ptr.*.deinit();
                }
                map.deinit();
            }
        }

        if ((need_content_hash or need_texts) and self.executor.context.loaders != null) {
            const dataloader_mod = @import("dataloader.zig");
            const loaders_ptr = self.executor.context.loaders.?;
            const loader_ctx: *dataloader_mod.LoaderContext = @ptrCast(@alignCast(loaders_ptr));

            // Collect all namehashes
            var namehashes = try self.allocator.alloc([32]u8, items.len);
            defer self.allocator.free(namehashes);
            for (items, 0..) |item_for_hash, idx| {
                namehashes[idx] = item_for_hash.namehash.bytes;
            }

            // Batch-load content hashes if needed
            if (need_content_hash) {
                const content_hash_loader = try loader_ctx.getContentHashLoader();
                const content_hashes = try content_hash_loader.loadMany(namehashes);
                defer self.allocator.free(content_hashes);

                content_hash_map = std.AutoHashMap([32]u8, ?[]const u8).init(self.allocator);
                for (namehashes, content_hashes) |hash, ch| {
                    try content_hash_map.?.put(hash, ch);
                }
            }

            // Batch-load text records if needed
            if (need_texts) {
                const text_records_loader = try loader_ctx.getTextRecordsLoader();
                const text_records = try text_records_loader.loadMany(namehashes);
                defer self.allocator.free(text_records);

                text_records_map = std.AutoHashMap([32]u8, dataloader_mod.TextRecords).init(self.allocator);
                for (namehashes, text_records) |hash, records| {
                    try text_records_map.?.put(hash, records);
                }
            }
        }

        for (items, 0..) |item, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{");

            var first = true;

            // Dynamically build response based on requested fields
            if (requested_fields.contains("id") or requested_fields.contains("name")) {
                const name_escaped = try escapeJsonString(self.allocator, item.name);
                defer self.allocator.free(name_escaped);

                if (requested_fields.contains("id")) {
                    if (!first) try writer.writeAll(",");
                    try writer.print("\"id\":\"{s}\"", .{name_escaped});
                    first = false;
                }

                if (requested_fields.contains("name")) {
                    if (!first) try writer.writeAll(",");
                    try writer.print("\"name\":\"{s}\"", .{name_escaped});
                    first = false;
                }
            }

            if (requested_fields.contains("labelName")) {
                const label_escaped = try escapeJsonString(self.allocator, item.label);
                defer self.allocator.free(label_escaped);
                if (!first) try writer.writeAll(",");
                try writer.print("\"labelName\":\"{s}\"", .{label_escaped});
                first = false;
            }

            if (requested_fields.contains("labelhash")) {
                const labelhash_hex = try item.label_hash.toHex(self.allocator);
                defer self.allocator.free(labelhash_hex);
                if (!first) try writer.writeAll(",");
                try writer.print("\"labelhash\":\"{s}\"", .{labelhash_hex});
                first = false;
            }

            if (requested_fields.contains("owner")) {
                const owner_hex = try item.owner.toHex(self.allocator);
                defer self.allocator.free(owner_hex);
                if (!first) try writer.writeAll(",");

                try writer.writeAll("\"owner\":{");
                if (requested_fields.contains("owner.id")) {
                    try writer.print("\"id\":\"{s}\"", .{owner_hex});
                }
                try writer.writeAll("}");
                first = false;
            }

            if (requested_fields.contains("resolver")) {
                const resolver_hex = try item.resolver.toHex(self.allocator);
                defer self.allocator.free(resolver_hex);
                if (!first) try writer.writeAll(",");

                // Only fetch data for requested nested fields (need_content_hash and need_texts already declared above)
                const need_addr = requested_fields.contains("resolver.addr");

                const addr = if (need_addr) self.database.getResolverAddress(item.namehash, 60) catch null else null;
                defer if (addr) |a| self.allocator.free(a);

                // Use pre-loaded content hash from map instead of individual database query
                const content_hash = if (need_content_hash and content_hash_map != null)
                    content_hash_map.?.get(item.namehash.bytes) orelse null
                else if (need_content_hash)
                    self.database.getResolverContentHash(item.namehash) catch null
                else
                    null;
                // No defer needed - content_hash points to map data, cleaned up with map

                // Use pre-loaded text records from map instead of individual database query
                var text_keys_list: std.ArrayList([]const u8) = .{};
                defer text_keys_list.deinit(self.allocator);

                if (need_texts and text_records_map != null) {
                    if (text_records_map.?.get(item.namehash.bytes)) |records| {
                        for (records.records) |record| {
                            try text_keys_list.append(self.allocator, record.key);
                        }
                    }
                } else if (need_texts) {
                    const keys_from_db = self.database.getResolverTextKeys(item.namehash) catch &[_][]u8{};
                    defer {
                        for (keys_from_db) |key| {
                            self.allocator.free(key);
                        }
                        self.allocator.free(keys_from_db);
                    }
                    for (keys_from_db) |key| {
                        try text_keys_list.append(self.allocator, key);
                    }
                }
                const text_keys = text_keys_list.items;

                try writer.writeAll("\"resolver\":{");
                var resolver_first = true;

                // Always include id and address if resolver is requested (they're always available)
                if (requested_fields.contains("resolver.id")) {
                    try writer.print("\"id\":\"{s}\"", .{resolver_hex});
                    resolver_first = false;
                }

                if (requested_fields.contains("resolver.address")) {
                    if (!resolver_first) try writer.writeAll(",");
                    try writer.print("\"address\":\"{s}\"", .{resolver_hex});
                    resolver_first = false;
                }

                if (need_addr) {
                    if (!resolver_first) try writer.writeAll(",");
                    if (addr) |a| {
                        try writer.print("\"addr\":\"{s}\"", .{a});
                    } else {
                        try writer.writeAll("\"addr\":null");
                    }
                    resolver_first = false;
                }

                if (need_content_hash) {
                    if (!resolver_first) try writer.writeAll(",");
                    if (content_hash) |ch| {
                        try writer.print("\"contentHash\":\"{s}\"", .{ch});
                    } else {
                        try writer.writeAll("\"contentHash\":null");
                    }
                    resolver_first = false;
                }

                if (need_texts) {
                    if (!resolver_first) try writer.writeAll(",");
                    try writer.writeAll("\"texts\":[");
                    for (text_keys, 0..) |key, idx| {
                        if (idx > 0) try writer.writeAll(",");
                        try writer.print("\"{s}\"", .{key});
                    }
                    try writer.writeAll("]");
                    resolver_first = false;
                }

                try writer.writeAll("}");
                first = false;
            }

            if (requested_fields.contains("expiryDate")) {
                if (!first) try writer.writeAll(",");
                if (hasValidExpiry(item.expiry)) {
                    try writer.print("\"expiryDate\":{d}", .{item.expiry});
                } else {
                    try writer.writeAll("\"expiryDate\":null");
                }
                first = false;
            }

            if (requested_fields.contains("tokenId")) {
                if (!first) try writer.writeAll(",");
                const token_id_hex = try std.fmt.allocPrint(self.allocator, "0x{x:0>64}", .{item.token_id});
                defer self.allocator.free(token_id_hex);
                try writer.print("\"tokenId\":\"{s}\"", .{token_id_hex});
                first = false;
            }

            if (requested_fields.contains("canonicalId")) {
                if (!first) try writer.writeAll(",");
                const canonical_id_hex = try std.fmt.allocPrint(self.allocator, "0x{x:0>64}", .{item.canonical_id});
                defer self.allocator.free(canonical_id_hex);
                try writer.print("\"canonicalId\":\"{s}\"", .{canonical_id_hex});
                first = false;
            }

            if (requested_fields.contains("tokenVersion")) {
                if (!first) try writer.writeAll(",");
                try writer.print("\"tokenVersion\":{d}", .{item.token_version});
                first = false;
            }

            if (requested_fields.contains("isMigrated")) {
                if (!first) try writer.writeAll(",");
                try writer.print("\"isMigrated\":{}", .{item.migrated});
                first = false;
            }

            if (requested_fields.contains("createdAt")) {
                if (!first) try writer.writeAll(",");
                try writer.print("\"createdAt\":{d}", .{item.created_at});
                first = false;
            }

            if (requested_fields.contains("registrationDate")) {
                if (!first) try writer.writeAll(",");
                try writer.print("\"registrationDate\":{d}", .{item.created_at});
                first = false;
            }

            try writer.writeAll("}");
        }

        try writer.writeAll("]}}");

        return response.toOwnedSlice(self.allocator);
    }

    fn buildNullResponse(self: *GraphQLHandler, field_name: []const u8) ![]u8 {
        var response: std.ArrayList(u8) = .{};
        errdefer response.deinit(self.allocator);

        const writer = response.writer(self.allocator);
        try writer.writeAll("{\"data\":{\"");
        try writer.writeAll(field_name);
        try writer.writeAll("\":null}}");

        return response.toOwnedSlice(self.allocator);
    }

    /// GraphQL error location (line and column in the query)
    const ErrorLocation = struct {
        line: u32,
        column: u32,
    };

    /// Standard GraphQL error codes for ENS indexer
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

    /// Build a GraphQL spec-compliant error response
    /// Format: {"errors":[{"message":"...", "locations":[...], "path":[...], "extensions":{...}}], "data":null}
    fn buildErrorResponse(self: *GraphQLHandler, message: []const u8) ![]u8 {
        return self.buildErrorResponseFull(message, null, null, null);
    }

    /// Build a GraphQL error response with error code
    fn buildErrorResponseWithCode(self: *GraphQLHandler, message: []const u8, code: ErrorCode) ![]u8 {
        const extensions = try std.fmt.allocPrint(self.allocator, "{{\"code\":\"{s}\"}}", .{code.toString()});
        defer self.allocator.free(extensions);
        return self.buildErrorResponseFull(message, null, null, extensions);
    }

    /// Build a GraphQL error response with error code and path
    fn buildErrorResponseWithCodeAndPath(self: *GraphQLHandler, message: []const u8, code: ErrorCode, path: []const []const u8) ![]u8 {
        const extensions = try std.fmt.allocPrint(self.allocator, "{{\"code\":\"{s}\"}}", .{code.toString()});
        defer self.allocator.free(extensions);
        return self.buildErrorResponseFull(message, null, path, extensions);
    }

    /// Build a GraphQL error response with optional locations
    fn buildErrorResponseWithLocation(self: *GraphQLHandler, message: []const u8, locations: ?[]const ErrorLocation) ![]u8 {
        return self.buildErrorResponseFull(message, locations, null, null);
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

        const message_escaped = try escapeJsonString(self.allocator, message);
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
                const escaped_segment = try escapeJsonString(self.allocator, segment);
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

    /// Build a multi-error response (for multiple errors in one query)
    fn buildMultiErrorResponse(self: *GraphQLHandler, errors: []const []const u8) ![]u8 {
        var response: std.ArrayList(u8) = .{};
        errdefer response.deinit(self.allocator);

        const writer = response.writer(self.allocator);

        try writer.writeAll("{\"errors\":[");
        for (errors, 0..) |err_msg, i| {
            if (i > 0) try writer.writeAll(",");
            const escaped = try escapeJsonString(self.allocator, err_msg);
            defer self.allocator.free(escaped);
            try writer.print("{{\"message\":\"{s}\"}}", .{escaped});
        }
        try writer.writeAll("],\"data\":null}");

        return response.toOwnedSlice(self.allocator);
    }

    fn extractStringParam(self: *GraphQLHandler, query: []const u8, param_name: []const u8) ![]const u8 {
        _ = self;

        const param_start = std.mem.indexOf(u8, query, param_name) orelse return "";
        const value_start = param_start + param_name.len;

        // Skip whitespace and quotes
        var i = value_start;
        while (i < query.len and (query[i] == ' ' or query[i] == '"')) : (i += 1) {}

        if (i >= query.len) return "";

        // Find end of value
        const start = i;
        while (i < query.len and query[i] != '"' and query[i] != ')' and query[i] != ',') : (i += 1) {}

        return query[start..i];
    }

    fn extractIntParam(self: *GraphQLHandler, query: []const u8, param_name: []const u8) !i64 {
        _ = self;

        const param_start = std.mem.indexOf(u8, query, param_name) orelse return error.ParameterNotFound;
        const value_start = param_start + param_name.len;

        // Skip whitespace
        var i = value_start;
        while (i < query.len and query[i] == ' ') : (i += 1) {}

        if (i >= query.len) return error.InvalidParameter;

        // Find end of number
        const start = i;
        while (i < query.len and query[i] >= '0' and query[i] <= '9') : (i += 1) {}

        const num_str = query[start..i];
        return std.fmt.parseInt(i64, num_str, 10);
    }
};

// ============================================================================
// RESOLVER FUNCTIONS
// ============================================================================
// Note: GraphQL schema is defined in schema.graphql at the project root.
// Introspection is served from introspection.json (generated at build time).
// ============================================================================

/// Resolver for domains query
fn resolveDomains(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));
    const allocator = ctx.allocator;

    // Extract arguments
    const first = parser.getIntArg(field, "first", 100) orelse 100;
    const skip = parser.getIntArg(field, "skip", 0) orelse 0;

    // Parse filter if provided
    var filter_name: ?[]const u8 = null;
    var filter_name_contains: ?[]const u8 = null;
    var filter_name_contains_nocase: ?[]const u8 = null;
    var filter_name_starts_with: ?[]const u8 = null;
    var filter_name_ends_with: ?[]const u8 = null;
    var filter_owner: ?Address = null;
    var filter_owner_in: ?[]Address = null;
    var filter_resolved_address: ?Address = null;
    var filter_has_subdomains: ?bool = null;
    var filter_subdomain_count_gt: ?i64 = null;
    var filter_subdomain_count_lt: ?i64 = null;

    // Look for "where" argument
    for (field.arguments) |arg| {
        if (std.mem.eql(u8, arg.name, "where")) {
            if (arg.value == .object) {
                for (arg.value.object) |filter_arg| {
                    if (std.mem.eql(u8, filter_arg.name, "name")) {
                        if (filter_arg.value == .string) {
                            filter_name = filter_arg.value.string;
                        }
                    } else if (std.mem.eql(u8, filter_arg.name, "name_contains")) {
                        if (filter_arg.value == .string) {
                            filter_name_contains = filter_arg.value.string;
                        }
                    } else if (std.mem.eql(u8, filter_arg.name, "owner")) {
                        if (filter_arg.value == .string) {
                            filter_owner = Address.fromHex(filter_arg.value.string) catch null;
                        }
                    } else if (std.mem.eql(u8, filter_arg.name, "resolvedAddress")) {
                        if (filter_arg.value == .string) {
                            filter_resolved_address = Address.fromHex(filter_arg.value.string) catch null;
                        }
                    } else if (std.mem.eql(u8, filter_arg.name, "name_contains_nocase")) {
                        if (filter_arg.value == .string) {
                            filter_name_contains_nocase = filter_arg.value.string;
                        }
                    } else if (std.mem.eql(u8, filter_arg.name, "name_starts_with")) {
                        if (filter_arg.value == .string) {
                            filter_name_starts_with = filter_arg.value.string;
                        }
                    } else if (std.mem.eql(u8, filter_arg.name, "name_ends_with")) {
                        if (filter_arg.value == .string) {
                            filter_name_ends_with = filter_arg.value.string;
                        }
                    } else if (std.mem.eql(u8, filter_arg.name, "owner_in")) {
                        if (filter_arg.value == .list) {
                            var addresses: std.ArrayList(Address) = .{};
                            defer addresses.deinit(allocator);
                            for (filter_arg.value.list) |item| {
                                if (item == .string) {
                                    if (Address.fromHex(item.string)) |addr| {
                                        try addresses.append(allocator, addr);
                                    } else |_| {}
                                }
                            }
                            filter_owner_in = try addresses.toOwnedSlice(allocator);
                        }
                    } else if (std.mem.eql(u8, filter_arg.name, "hasSubdomains")) {
                        if (filter_arg.value == .boolean) {
                            filter_has_subdomains = filter_arg.value.boolean;
                        }
                    } else if (std.mem.eql(u8, filter_arg.name, "subdomainCount_gt")) {
                        if (filter_arg.value == .int) {
                            filter_subdomain_count_gt = filter_arg.value.int;
                        }
                    } else if (std.mem.eql(u8, filter_arg.name, "subdomainCount_lt")) {
                        if (filter_arg.value == .int) {
                            filter_subdomain_count_lt = filter_arg.value.int;
                        }
                    }
                }
            }
            break;
        }
    }

    // Parse orderBy and orderDirection
    var order_by: ?[]const u8 = null;
    var order_direction: []const u8 = "asc"; // default

    for (field.arguments) |arg| {
        if (std.mem.eql(u8, arg.name, "orderBy")) {
            if (arg.value == .string) {
                order_by = arg.value.string;
            }
        } else if (std.mem.eql(u8, arg.name, "orderDirection")) {
            if (arg.value == .string) {
                order_direction = arg.value.string;
            }
        }
    }

    // Get names from database
    // Optimization 1: if exact name filter is set, use direct lookup by namehash
    // This is O(1) lookup instead of scanning/filtering
    if (filter_name) |exact_name| {
        // Compute namehash for exact lookup
        const nh = try namehash(allocator, exact_name);

        // Direct lookup by namehash
        var found_name = try database.getNameByNamehash(nh);
        if (found_name) |*name| {
            defer name.deinit(allocator);

            // Apply any additional filters (owner, etc.)
            var matches = true;
            if (filter_owner) |owner| {
                if (!name.owner.eql(owner)) matches = false;
            }

            if (matches) {
                // Build JSON result for single domain, wrapped in array
                const name_json = try buildDomainJson(name, field.selections, .{
                    .database = database,
                    .depth = 0,
                    .allocator = allocator,
                    .loaders = ctx.loaders,
                });
                defer allocator.free(name_json);

                // Wrap in array: [{...}]
                var result = try allocator.alloc(u8, name_json.len + 2);
                result[0] = '[';
                @memcpy(result[1..][0..name_json.len], name_json);
                result[name_json.len + 1] = ']';
                return .{ .json = result };
            }
        }

        // No match found - return empty array
        return .{ .json = try allocator.dupe(u8, "[]") };
    }

    // Optimization 2: if owner filter is set and it's the main filter, push it to DB
    // This uses the idx_names_owner index instead of scanning all rows
    const has_other_filters = filter_name_contains != null or
        filter_name_contains_nocase != null or filter_name_starts_with != null or
        filter_name_ends_with != null or filter_owner_in != null or
        filter_resolved_address != null or filter_has_subdomains != null or
        filter_subdomain_count_gt != null or filter_subdomain_count_lt != null;

    const db_owner_filter = if (filter_owner != null and !has_other_filters)
        filter_owner
    else
        null;

    const fetch_limit = if (has_other_filters or (filter_owner != null and has_other_filters))
        @min(first * 10, 1000) // Fetch more if we need additional in-memory filtering
    else
        first;
    const names = try database.getAllNames(db_owner_filter, @intCast(skip), @intCast(fetch_limit));
    defer {
        for (names) |*name| {
            name.deinit(allocator);
        }
        allocator.free(names);
    }

    // Batch-load resolver addresses if needed for filtering (eliminates N+1 query)
    var resolver_addresses: ?std.AutoHashMap([32]u8, ?[]const u8) = null;
    defer {
        if (resolver_addresses) |*addrs| {
            var it = addrs.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.*) |addr| {
                    allocator.free(addr);
                }
            }
            addrs.deinit();
        }
    }

    if (filter_resolved_address != null) {
        // Use DataLoader to batch-load all resolver addresses in one query
        const dataloader_mod = @import("dataloader.zig");
        if (ctx.loaders) |loaders_ptr| {
            const loader_ctx: *dataloader_mod.LoaderContext = @ptrCast(@alignCast(loaders_ptr));
            const loader = try loader_ctx.getResolverAddressLoader();

            // Collect all namehashes
            var namehashes = try allocator.alloc([32]u8, names.len);
            defer allocator.free(namehashes);
            for (names, 0..) |name, i| {
                namehashes[i] = name.namehash.bytes;
            }

            // Batch load all addresses in one query!
            const addresses = try loader.loadMany(namehashes);
            defer allocator.free(addresses);

            // Build lookup map
            resolver_addresses = std.AutoHashMap([32]u8, ?[]const u8).init(allocator);
            for (namehashes, addresses) |hash, addr| {
                try resolver_addresses.?.put(hash, addr);
            }
        }
    }

    // First pass: collect filtered names
    var filtered_names: std.ArrayList(*models.Name) = .{};
    defer filtered_names.deinit(allocator);

    for (names) |*name| {
        // Apply filters
        var matches = true;

        if (filter_name) |fname| {
            if (!std.mem.eql(u8, name.name orelse "[unknown]", fname)) matches = false;
        }

        if (matches and filter_name_contains != null) {
            if (std.mem.indexOf(u8, name.name orelse "[unknown]", filter_name_contains.?) == null) matches = false;
        }

        if (matches and filter_owner != null) {
            if (!name.owner.eql(filter_owner.?)) matches = false;
        }

        if (matches and filter_resolved_address != null) {
            // Use pre-loaded resolver addresses (no database query in loop!)
            if (resolver_addresses) |*addrs| {
                const addr_opt = addrs.get(name.namehash.bytes);
                if (addr_opt) |addr| {
                    if (addr) |addr_str| {
                        const resolved_addr = Address.fromHex(addr_str) catch {
                            matches = false;
                            continue;
                        };
                        if (!resolved_addr.eql(filter_resolved_address.?)) matches = false;
                    } else {
                        matches = false;
                    }
                } else {
                    matches = false;
                }
            } else {
                // Fallback to direct database query if loaders not available
                const addr_opt = try database.getResolverAddress(name.namehash, 60);
                if (addr_opt) |addr| {
                    defer allocator.free(addr);
                    const resolved_addr = Address.fromHex(addr) catch {
                        matches = false;
                        continue;
                    };
                    if (!resolved_addr.eql(filter_resolved_address.?)) matches = false;
                } else {
                    matches = false;
                }
            }
        }

        if (matches and filter_name_contains_nocase != null) {
            // Case-insensitive contains
            const lower_name = try std.ascii.allocLowerString(allocator, name.name orelse "[unknown]");
            defer allocator.free(lower_name);
            const lower_filter = try std.ascii.allocLowerString(allocator, filter_name_contains_nocase.?);
            defer allocator.free(lower_filter);
            if (std.mem.indexOf(u8, lower_name, lower_filter) == null) matches = false;
        }

        if (matches and filter_name_starts_with != null) {
            if (!std.mem.startsWith(u8, name.name orelse "[unknown]", filter_name_starts_with.?)) matches = false;
        }

        if (matches and filter_name_ends_with != null) {
            if (!std.mem.endsWith(u8, name.name orelse "[unknown]", filter_name_ends_with.?)) matches = false;
        }

        if (matches and filter_owner_in != null) {
            var found = false;
            for (filter_owner_in.?) |addr| {
                if (name.owner.eql(addr)) {
                    found = true;
                    break;
                }
            }
            if (!found) matches = false;
        }

        // Filter by hasSubdomains - only counts direct children (one level down)
        if (matches and filter_has_subdomains != null) {
            if (name.name) |domain_name| {
                const has_subs = try database.hasDirectSubdomains(domain_name);
                if (filter_has_subdomains.? != has_subs) matches = false;
            } else {
                // Domain without a name can't have subdomains checked
                if (filter_has_subdomains.?) matches = false;
            }
        }

        // Filter by subdomainCount_gt - only counts direct children (one level down)
        if (matches and filter_subdomain_count_gt != null) {
            if (name.name) |domain_name| {
                const subdomain_count = try database.countDirectSubdomains(domain_name);
                if (subdomain_count <= @as(u32, @intCast(filter_subdomain_count_gt.?))) matches = false;
            } else {
                // Domain without a name has 0 subdomains
                matches = false;
            }
        }

        // Filter by subdomainCount_lt - only counts direct children (one level down)
        if (matches and filter_subdomain_count_lt != null) {
            if (name.name) |domain_name| {
                const subdomain_count = try database.countDirectSubdomains(domain_name);
                if (subdomain_count >= @as(u32, @intCast(filter_subdomain_count_lt.?))) matches = false;
            } else {
                // Domain without a name has 0 subdomains - always passes lt filter unless lt=0
                if (filter_subdomain_count_lt.? <= 0) matches = false;
            }
        }

        if (matches) {
            try filtered_names.append(allocator, name);
        }
    }

    // Sort filtered names if orderBy is specified
    if (order_by) |field_name| {
        const ascending = std.mem.eql(u8, order_direction, "asc");
        const SortContext = struct {
            field: []const u8,
            asc: bool,
        };
        const sort_ctx = SortContext{ .field = field_name, .asc = ascending };

        std.mem.sort(*models.Name, filtered_names.items, sort_ctx, struct {
            fn lessThan(sort_ctx_param: SortContext, a: *models.Name, b: *models.Name) bool {
                if (std.mem.eql(u8, sort_ctx_param.field, "name")) {
                    const cmp = std.mem.order(u8, a.name orelse "[unknown]", b.name orelse "[unknown]");
                    return if (sort_ctx_param.asc) cmp == .lt else cmp == .gt;
                } else if (std.mem.eql(u8, sort_ctx_param.field, "createdAt") or
                    std.mem.eql(u8, sort_ctx_param.field, "registrationDate"))
                {
                    // registrationDate is an alias for createdAt
                    return if (sort_ctx_param.asc) a.created_at < b.created_at else a.created_at > b.created_at;
                } else if (std.mem.eql(u8, sort_ctx_param.field, "expiryDate")) {
                    // Sort by expiry timestamp
                    return if (sort_ctx_param.asc) a.expiry < b.expiry else a.expiry > b.expiry;
                } else if (std.mem.eql(u8, sort_ctx_param.field, "id")) {
                    const cmp = std.mem.order(u8, &a.namehash.bytes, &b.namehash.bytes);
                    return if (sort_ctx_param.asc) cmp == .lt else cmp == .gt;
                }
                // Default: no sorting
                return false;
            }
        }.lessThan);
    }

    // Build JSON from sorted/filtered names
    var json: std.ArrayList(u8) = .{};
    defer json.deinit(allocator);

    try json.appendSlice(allocator, "[");
    const items_to_return = @min(first, filtered_names.items.len);

    // Pre-load resolver data for all domains to enable batching (solves N+1 query problem)
    // Check if resolver fields that need data loading are requested
    if (ctx.loaders != null and items_to_return > 0) {
        const dataloader_mod = @import("dataloader.zig");
        var needs_resolver_addr = false;
        var needs_content_hash = false;
        var needs_text_records = false;
        var needs_resolved_address = false;

        // Check field selections for resolver sub-fields
        for (field.selections) |sel| {
            if (std.mem.eql(u8, sel.name, "resolver")) {
                for (sel.selections) |resolver_sel| {
                    if (std.mem.eql(u8, resolver_sel.name, "addr")) {
                        needs_resolver_addr = true;
                    } else if (std.mem.eql(u8, resolver_sel.name, "contentHash")) {
                        needs_content_hash = true;
                    } else if (std.mem.eql(u8, resolver_sel.name, "texts") or
                        std.mem.eql(u8, resolver_sel.name, "text"))
                    {
                        needs_text_records = true;
                    }
                }
            } else if (std.mem.eql(u8, sel.name, "resolvedAddress")) {
                needs_resolved_address = true;
            }
        }

        // Collect namehashes for items that will be returned
        if (needs_resolver_addr or needs_content_hash or needs_text_records or needs_resolved_address) {
            const loader_ctx: *dataloader_mod.LoaderContext = @ptrCast(@alignCast(ctx.loaders.?));
            const return_items = filtered_names.items[0..@as(usize, @intCast(items_to_return))];

            var namehashes = try allocator.alloc([32]u8, return_items.len);
            defer allocator.free(namehashes);

            for (return_items, 0..) |name, idx| {
                namehashes[idx] = name.namehash.bytes;
            }

            // Pre-load resolver addresses (for addr field and resolvedAddress)
            if (needs_resolver_addr or needs_resolved_address) {
                const loader = try loader_ctx.getResolverAddressLoader();
                const preloaded = try loader.loadMany(namehashes);
                allocator.free(preloaded);
            }

            // Pre-load content hashes
            if (needs_content_hash) {
                const loader = try loader_ctx.getContentHashLoader();
                const preloaded = try loader.loadMany(namehashes);
                allocator.free(preloaded);
            }

            // Pre-load text records
            if (needs_text_records) {
                const loader = try loader_ctx.getTextRecordsLoader();
                const preloaded = try loader.loadMany(namehashes);
                allocator.free(preloaded);
            }
        }
    }

    for (filtered_names.items[0..@as(usize, @intCast(items_to_return))], 0..) |name, i| {
        if (i > 0) try json.appendSlice(allocator, ",");

        const name_json = try buildDomainJson(name, field.selections, .{
            .database = database,
            .depth = 0,
            .allocator = allocator,
            .loaders = ctx.loaders,
        });
        defer allocator.free(name_json);
        try json.appendSlice(allocator, name_json);
    }
    try json.appendSlice(allocator, "]");

    const result_json = try allocator.dupe(u8, json.items);
    return parser.FieldResult{ .json = result_json };
}

/// Resolver for domainConnection query (cursor-based pagination)
fn resolveDomainConnection(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));
    const allocator = ctx.allocator;

    // Parse pagination arguments
    const first = parser.getIntArg(field, "first", null);
    const after = parser.getStringArg(field, "after", null);
    const last = parser.getIntArg(field, "last", null);
    const before = parser.getStringArg(field, "before", null);

    const params = try pagination.PaginationParams.parse(
        first,
        after,
        last,
        before,
        100, // default limit
        1000, // max limit
    );

    // Extract node selections from query: domainConnection { edges { node { ... } } }
    var node_selections: []const parser.Field = &[_]parser.Field{};
    for (field.selections) |*sel| {
        if (std.mem.eql(u8, sel.name, "edges")) {
            for (sel.selections) |*edge_sel| {
                if (std.mem.eql(u8, edge_sel.name, "node")) {
                    node_selections = edge_sel.selections;
                    break;
                }
            }
            break;
        }
    }

    // For now, use offset-based queries (can be optimized to true cursor-based queries later)
    const skip: u32 = 0;

    // Fetch one extra item to determine hasNextPage/hasPreviousPage
    const fetch_limit = params.limit + 1;

    // For backward pagination (last/before), reverse the query order
    // This ensures we get the "last N items" from the end of the result set
    const order_dir: db.OrderDir = if (params.direction == .backward) .asc else .desc;
    const names = try database.getAllNamesWithOrder(null, skip, @intCast(fetch_limit), order_dir);
    defer {
        for (names) |*name| {
            name.deinit(allocator);
        }
        allocator.free(names);
    }

    // Determine actual items to return (exclude the extra item)
    const actual_items = @min(names.len, params.limit);

    // For backward pagination, reverse the results to maintain proper edge order
    // (Query returned oldest-first, but we want newest-first in the edges)
    if (params.direction == .backward and actual_items > 1) {
        std.mem.reverse(models.Name, names[0..actual_items]);
    }

    const items_slice = names[0..actual_items];

    // Build connection using pagination module
    const NameWithSelections = struct {
        name: *models.Name,
        selections: []const parser.Field,
        ctx: NestedContext,
        hex_id: []const u8,
    };

    // Helper to get hex ID
    const getId = struct {
        fn call(item: NameWithSelections) []const u8 {
            return item.hex_id;
        }
    }.call;

    // Create wrapper items with hex IDs
    var wrapper_items = try allocator.alloc(NameWithSelections, items_slice.len);
    defer {
        for (wrapper_items) |item| {
            allocator.free(item.hex_id);
        }
        allocator.free(wrapper_items);
    }

    for (items_slice, 0..) |*name, i| {
        // Format namehash as hex string using Hash.toHex()
        const hex_id = try name.namehash.toHex(allocator);
        wrapper_items[i] = NameWithSelections{
            .name = name,
            .selections = node_selections,
            .ctx = .{
                .database = database,
                .depth = 0,
                .allocator = allocator,
                .loaders = ctx.loaders,
            },
            .hex_id = hex_id,
        };
    }

    // Build connection
    const connection = try pagination.buildConnectionString(
        NameWithSelections,
        allocator,
        wrapper_items,
        params,
        getId,
        null, // total_count - can be added later
    );
    defer connection.deinit(allocator);

    // Build JSON from connection
    var json: std.ArrayList(u8) = .{};
    defer json.deinit(allocator);

    try json.appendSlice(allocator, "{\"pageInfo\":{");
    try json.appendSlice(allocator, "\"hasNextPage\":");
    try json.appendSlice(allocator, if (connection.page_info.has_next_page) "true" else "false");
    try json.appendSlice(allocator, ",\"hasPreviousPage\":");
    try json.appendSlice(allocator, if (connection.page_info.has_previous_page) "true" else "false");

    if (connection.page_info.start_cursor) |cursor| {
        try json.appendSlice(allocator, ",\"startCursor\":\"");
        try json.appendSlice(allocator, cursor);
        try json.appendSlice(allocator, "\"");
    } else {
        try json.appendSlice(allocator, ",\"startCursor\":null");
    }

    if (connection.page_info.end_cursor) |cursor| {
        try json.appendSlice(allocator, ",\"endCursor\":\"");
        try json.appendSlice(allocator, cursor);
        try json.appendSlice(allocator, "\"");
    } else {
        try json.appendSlice(allocator, ",\"endCursor\":null");
    }

    try json.appendSlice(allocator, "},\"edges\":[");

    // Build edges
    for (connection.edges, 0..) |edge, i| {
        if (i > 0) try json.appendSlice(allocator, ",");

        try json.appendSlice(allocator, "{\"cursor\":\"");
        try json.appendSlice(allocator, edge.cursor);
        try json.appendSlice(allocator, "\",\"node\":");

        // Build domain JSON for the node
        const domain_json = try buildDomainJson(edge.node.name, edge.node.selections, edge.node.ctx);
        defer allocator.free(domain_json);
        try json.appendSlice(allocator, domain_json);

        try json.appendSlice(allocator, "}");
    }

    try json.appendSlice(allocator, "]");

    // Add totalCount if available
    if (connection.total_count) |count| {
        try json.appendSlice(allocator, ",\"totalCount\":");
        const count_str = try std.fmt.allocPrint(allocator, "{d}", .{count});
        defer allocator.free(count_str);
        try json.appendSlice(allocator, count_str);
    }

    try json.appendSlice(allocator, "}");

    const result_json = try allocator.dupe(u8, json.items);
    return parser.FieldResult{ .json = result_json };
}

/// Resolver for registrationConnection query (cursor-based pagination)
fn resolveRegistrationConnection(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));
    const allocator = ctx.allocator;

    // Parse pagination arguments
    const first = parser.getIntArg(field, "first", null);
    const after = parser.getStringArg(field, "after", null);
    const last = parser.getIntArg(field, "last", null);
    const before = parser.getStringArg(field, "before", null);

    const params = try pagination.PaginationParams.parse(
        first,
        after,
        last,
        before,
        100, // default limit
        1000, // max limit
    );

    // Extract node selections from query
    var node_selections: []const parser.Field = &[_]parser.Field{};
    for (field.selections) |*sel| {
        if (std.mem.eql(u8, sel.name, "edges")) {
            for (sel.selections) |*edge_sel| {
                if (std.mem.eql(u8, edge_sel.name, "node")) {
                    node_selections = edge_sel.selections;
                    break;
                }
            }
            break;
        }
    }

    // Fetch one extra item to determine hasNextPage/hasPreviousPage
    const fetch_limit = params.limit + 1;

    // For backward pagination (last/before), reverse the query order
    const order_dir: db.EventOrderDir = if (params.direction == .backward) .asc else .desc;

    // Get registration events from database (filters by canonical registries internally)
    const events = try database.getRegistrations(.{
        .limit = @intCast(fetch_limit),
        .order_dir = order_dir,
    });
    defer {
        for (events) |*event| {
            event.deinit(allocator);
        }
        allocator.free(events);
    }

    // Determine actual items to return
    const actual_items = @min(events.len, params.limit);

    // For backward pagination, reverse the results to maintain proper edge order
    if (params.direction == .backward and actual_items > 1) {
        std.mem.reverse(models.Event, events[0..actual_items]);
    }

    const items_slice = events[0..actual_items];

    // Wrapper type for registrations
    const RegistrationWithSelections = struct {
        event: *models.Event,
        selections: []const parser.Field,
        ctx: NestedContext,
        id: []const u8,
    };

    // Helper to get ID
    const getId = struct {
        fn call(item: RegistrationWithSelections) []const u8 {
            return item.id;
        }
    }.call;

    // Create wrapper items with IDs
    var wrapper_items = try allocator.alloc(RegistrationWithSelections, items_slice.len);
    defer {
        for (wrapper_items) |item| {
            allocator.free(item.id);
        }
        allocator.free(wrapper_items);
    }

    for (items_slice, 0..) |*event, i| {
        const tx_hash = try event.tx_hash.toHex(allocator);
        defer allocator.free(tx_hash);
        const id = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ tx_hash, event.log_index });
        wrapper_items[i] = RegistrationWithSelections{
            .event = event,
            .selections = node_selections,
            .ctx = .{
                .database = database,
                .depth = 0,
                .allocator = allocator,
                .loaders = ctx.loaders,
            },
            .id = id,
        };
    }

    // Build connection
    const connection = try pagination.buildConnectionString(
        RegistrationWithSelections,
        allocator,
        wrapper_items,
        params,
        getId,
        null,
    );
    defer connection.deinit(allocator);

    // Build JSON from connection
    var json: std.ArrayList(u8) = .{};
    defer json.deinit(allocator);

    try json.appendSlice(allocator, "{\"pageInfo\":{");
    try json.appendSlice(allocator, "\"hasNextPage\":");
    try json.appendSlice(allocator, if (connection.page_info.has_next_page) "true" else "false");
    try json.appendSlice(allocator, ",\"hasPreviousPage\":");
    try json.appendSlice(allocator, if (connection.page_info.has_previous_page) "true" else "false");

    if (connection.page_info.start_cursor) |cursor| {
        try json.appendSlice(allocator, ",\"startCursor\":\"");
        try json.appendSlice(allocator, cursor);
        try json.appendSlice(allocator, "\"");
    } else {
        try json.appendSlice(allocator, ",\"startCursor\":null");
    }

    if (connection.page_info.end_cursor) |cursor| {
        try json.appendSlice(allocator, ",\"endCursor\":\"");
        try json.appendSlice(allocator, cursor);
        try json.appendSlice(allocator, "\"");
    } else {
        try json.appendSlice(allocator, ",\"endCursor\":null");
    }

    try json.appendSlice(allocator, "},\"edges\":[");

    // Build edges
    for (connection.edges, 0..) |edge, i| {
        if (i > 0) try json.appendSlice(allocator, ",");

        try json.appendSlice(allocator, "{\"cursor\":\"");
        try json.appendSlice(allocator, edge.cursor);
        try json.appendSlice(allocator, "\",\"node\":");

        // Build registration JSON for the node
        const registration_json = try buildRegistrationJson(edge.node.event, edge.node.selections, edge.node.ctx);
        defer allocator.free(registration_json);
        try json.appendSlice(allocator, registration_json);

        try json.appendSlice(allocator, "}");
    }

    try json.appendSlice(allocator, "]");

    if (connection.total_count) |count| {
        try json.appendSlice(allocator, ",\"totalCount\":");
        const count_str = try std.fmt.allocPrint(allocator, "{d}", .{count});
        defer allocator.free(count_str);
        try json.appendSlice(allocator, count_str);
    }

    try json.appendSlice(allocator, "}");

    const result_json = try allocator.dupe(u8, json.items);
    return parser.FieldResult{ .json = result_json };
}

/// Resolver for eventConnection query (cursor-based pagination)
fn resolveEventConnection(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));
    const allocator = ctx.allocator;

    // Parse pagination arguments
    const first = parser.getIntArg(field, "first", null);
    const after = parser.getStringArg(field, "after", null);
    const last = parser.getIntArg(field, "last", null);
    const before = parser.getStringArg(field, "before", null);

    const params = try pagination.PaginationParams.parse(
        first,
        after,
        last,
        before,
        100, // default limit
        1000, // max limit
    );

    // Extract node selections from query
    var node_selections: []const parser.Field = &[_]parser.Field{};
    for (field.selections) |*sel| {
        if (std.mem.eql(u8, sel.name, "edges")) {
            for (sel.selections) |*edge_sel| {
                if (std.mem.eql(u8, edge_sel.name, "node")) {
                    node_selections = edge_sel.selections;
                    break;
                }
            }
            break;
        }
    }

    // Fetch one extra item to determine hasNextPage/hasPreviousPage
    const fetch_limit = params.limit + 1;

    // For backward pagination (last/before), reverse the query order
    const order_dir: db.EventOrderDir = if (params.direction == .backward) .asc else .desc;
    const events = try database.getRecentEventsWithOrder(null, null, @intCast(fetch_limit), order_dir);
    defer {
        for (events) |*event| {
            event.deinit(allocator);
        }
        allocator.free(events);
    }

    // Determine actual items to return
    const actual_items = @min(events.len, params.limit);

    // For backward pagination, reverse the results to maintain proper edge order
    if (params.direction == .backward and actual_items > 1) {
        std.mem.reverse(models.Event, events[0..actual_items]);
    }

    const items_slice = events[0..actual_items];

    // Wrapper type for events
    const EventWithSelections = struct {
        event: *models.Event,
        selections: []const parser.Field,
        ctx: NestedContext,
        id: []const u8,
    };

    // Helper to get ID
    const getId = struct {
        fn call(item: EventWithSelections) []const u8 {
            return item.id;
        }
    }.call;

    // Create wrapper items with IDs
    var wrapper_items = try allocator.alloc(EventWithSelections, items_slice.len);
    defer {
        for (wrapper_items) |item| {
            allocator.free(item.id);
        }
        allocator.free(wrapper_items);
    }

    for (items_slice, 0..) |*event, i| {
        const tx_hash = try event.tx_hash.toHex(allocator);
        defer allocator.free(tx_hash);
        const id = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ tx_hash, event.log_index });
        wrapper_items[i] = EventWithSelections{
            .event = event,
            .selections = node_selections,
            .ctx = .{
                .database = database,
                .depth = 0,
                .allocator = allocator,
                .loaders = ctx.loaders,
            },
            .id = id,
        };
    }

    // Build connection
    const connection = try pagination.buildConnectionString(
        EventWithSelections,
        allocator,
        wrapper_items,
        params,
        getId,
        null,
    );
    defer connection.deinit(allocator);

    // Build JSON from connection
    var json: std.ArrayList(u8) = .{};
    defer json.deinit(allocator);

    try json.appendSlice(allocator, "{\"pageInfo\":{");
    try json.appendSlice(allocator, "\"hasNextPage\":");
    try json.appendSlice(allocator, if (connection.page_info.has_next_page) "true" else "false");
    try json.appendSlice(allocator, ",\"hasPreviousPage\":");
    try json.appendSlice(allocator, if (connection.page_info.has_previous_page) "true" else "false");

    if (connection.page_info.start_cursor) |cursor| {
        try json.appendSlice(allocator, ",\"startCursor\":\"");
        try json.appendSlice(allocator, cursor);
        try json.appendSlice(allocator, "\"");
    } else {
        try json.appendSlice(allocator, ",\"startCursor\":null");
    }

    if (connection.page_info.end_cursor) |cursor| {
        try json.appendSlice(allocator, ",\"endCursor\":\"");
        try json.appendSlice(allocator, cursor);
        try json.appendSlice(allocator, "\"");
    } else {
        try json.appendSlice(allocator, ",\"endCursor\":null");
    }

    try json.appendSlice(allocator, "},\"edges\":[");

    // Build edges
    for (connection.edges, 0..) |edge, i| {
        if (i > 0) try json.appendSlice(allocator, ",");

        try json.appendSlice(allocator, "{\"cursor\":\"");
        try json.appendSlice(allocator, edge.cursor);
        try json.appendSlice(allocator, "\",\"node\":");

        // Build event JSON for the node
        const event_json = try buildEventJson(edge.node.event, edge.node.selections, edge.node.ctx);
        defer allocator.free(event_json);
        try json.appendSlice(allocator, event_json);

        try json.appendSlice(allocator, "}");
    }

    try json.appendSlice(allocator, "]");

    if (connection.total_count) |count| {
        try json.appendSlice(allocator, ",\"totalCount\":");
        const count_str = try std.fmt.allocPrint(allocator, "{d}", .{count});
        defer allocator.free(count_str);
        try json.appendSlice(allocator, count_str);
    }

    try json.appendSlice(allocator, "}");

    const result_json = try allocator.dupe(u8, json.items);
    return parser.FieldResult{ .json = result_json };
}

/// Resolver for domain query (single domain)
fn resolveDomain(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));
    const allocator = ctx.allocator;

    // Extract id argument
    const id = parser.getStringArg(field, "id", null) orelse {
        const null_json = try allocator.dupe(u8, "null");
        return parser.FieldResult{ .json = null_json };
    };

    // Get name from database
    const nh = try namehash(allocator, id);
    const name_opt = try database.getNameByNamehash(nh);
    if (name_opt == null) {
        const null_json = try allocator.dupe(u8, "null");
        return parser.FieldResult{ .json = null_json };
    }
    var name = name_opt.?;
    defer name.deinit(allocator);

    // Build JSON object using nested builder
    const name_json = try buildDomainJson(&name, field.selections, .{
        .database = database,
        .depth = 0,
        .allocator = allocator,
        .loaders = ctx.loaders,
    });
    return parser.FieldResult{ .json = name_json };
}

/// Resolver for account query
fn resolveAccount(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));
    const allocator = ctx.allocator;

    // Extract id argument
    const id = parser.getStringArg(field, "id", null) orelse {
        const null_json = try allocator.dupe(u8, "null");
        return parser.FieldResult{ .json = null_json };
    };

    // Parse the address
    const address = Address.fromHex(id) catch {
        const null_json = try allocator.dupe(u8, "null");
        return parser.FieldResult{ .json = null_json };
    };

    // Build account object with all requested fields (domains, registrations, etc.)
    const account_json = try buildAccountJson(address, field.selections, .{
        .database = database,
        .depth = 1,
        .allocator = allocator,
        .loaders = ctx.loaders,
    });
    return parser.FieldResult{ .json = account_json };
}

/// Resolver for registrations query
fn resolveRegistrations(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));
    const allocator = ctx.allocator;

    // Extract arguments
    const first = parser.getIntArg(field, "first", 100) orelse 100;
    const skip = parser.getIntArg(field, "skip", 0) orelse 0;

    // Parse filter if provided
    var filter_registrant: ?Address = null;
    var filter_registrant_in: ?[]Address = null;
    var filter_expiry_gt: ?i64 = null;
    var filter_expiry_gte: ?i64 = null;
    var filter_expiry_lt: ?i64 = null;
    var filter_expiry_lte: ?i64 = null;
    var filter_chain: ?models.Chain = null;

    // Look for "where" argument
    for (field.arguments) |arg| {
        if (std.mem.eql(u8, arg.name, "where")) {
            if (arg.value == .object) {
                for (arg.value.object) |filter_arg| {
                    if (std.mem.eql(u8, filter_arg.name, "registrant")) {
                        if (filter_arg.value == .string) {
                            filter_registrant = Address.fromHex(filter_arg.value.string) catch null;
                        }
                    } else if (std.mem.eql(u8, filter_arg.name, "chain")) {
                        if (filter_arg.value == .string) {
                            filter_chain = models.Chain.fromString(filter_arg.value.string) catch null;
                        }
                    } else if (std.mem.eql(u8, filter_arg.name, "expiryDate_gt")) {
                        if (filter_arg.value == .int) {
                            filter_expiry_gt = filter_arg.value.int;
                        }
                    } else if (std.mem.eql(u8, filter_arg.name, "expiryDate_lt")) {
                        if (filter_arg.value == .int) {
                            filter_expiry_lt = filter_arg.value.int;
                        }
                    } else if (std.mem.eql(u8, filter_arg.name, "registrant_in")) {
                        if (filter_arg.value == .list) {
                            var addresses: std.ArrayList(Address) = .{};
                            defer addresses.deinit(allocator);
                            for (filter_arg.value.list) |item| {
                                if (item == .string) {
                                    if (Address.fromHex(item.string)) |addr| {
                                        try addresses.append(allocator, addr);
                                    } else |_| {}
                                }
                            }
                            filter_registrant_in = try addresses.toOwnedSlice(allocator);
                        }
                    } else if (std.mem.eql(u8, filter_arg.name, "expiryDate_gte")) {
                        if (filter_arg.value == .int) {
                            filter_expiry_gte = filter_arg.value.int;
                        }
                    } else if (std.mem.eql(u8, filter_arg.name, "expiryDate_lte")) {
                        if (filter_arg.value == .int) {
                            filter_expiry_lte = filter_arg.value.int;
                        }
                    }
                }
            }
            break;
        }
    }

    // Parse orderBy and orderDirection
    var order_by: ?[]const u8 = null;
    var order_direction: []const u8 = "asc"; // default

    for (field.arguments) |arg| {
        if (std.mem.eql(u8, arg.name, "orderBy")) {
            if (arg.value == .string) {
                order_by = arg.value.string;
            }
        } else if (std.mem.eql(u8, arg.name, "orderDirection")) {
            if (arg.value == .string) {
                order_direction = arg.value.string;
            }
        }
    }

    // Get registration events from database
    // The database handles contract filtering internally based on its network configuration
    const fetch_limit = if (filter_registrant != null or filter_registrant_in != null or
        filter_expiry_gt != null or filter_expiry_gte != null or
        filter_expiry_lt != null or filter_expiry_lte != null)
        @min(first * 10, 1000)
    else
        first;

    const events = try database.getRegistrations(.{
        .chain = filter_chain,
        .limit = @intCast(fetch_limit),
        .order_dir = .desc,
    });
    defer {
        for (events) |*event| {
            event.deinit(allocator);
        }
        allocator.free(events);
    }

    // Helper struct for sorting
    const FilteredEvent = struct {
        event: *models.Event,
        name: []const u8,
        expiry: i64,
    };

    // First pass: collect filtered events
    var filtered_events: std.ArrayList(FilteredEvent) = .{};
    defer filtered_events.deinit(allocator);

    for (events) |*event| {
        if (event.name == null) continue;

        // Parse event data to check filters
        var matches = true;
        var event_expiry: i64 = 0;
        var owner_str: ?[]const u8 = null;

        if (filter_registrant != null or filter_registrant_in != null or
            filter_expiry_gt != null or filter_expiry_gte != null or
            filter_expiry_lt != null or filter_expiry_lte != null or
            order_by != null) {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, event.data, .{}) catch continue;
            defer parsed.deinit();

            // Get owner for registrant filters
            owner_str = if (parsed.value.object.get("owner")) |owner_val|
                if (owner_val == .string) owner_val.string else null
            else
                null;

            // Check registrant filter
            if (filter_registrant) |reg_addr| {
                if (owner_str) |owner| {
                    const owner_addr = Address.fromHex(owner) catch {
                        matches = false;
                        continue;
                    };
                    if (!owner_addr.eql(reg_addr)) matches = false;
                } else {
                    matches = false;
                }
            }

            // Check registrant_in filter
            if (matches and filter_registrant_in != null) {
                if (owner_str) |owner| {
                    const owner_addr = Address.fromHex(owner) catch {
                        matches = false;
                        continue;
                    };
                    var found = false;
                    for (filter_registrant_in.?) |addr| {
                        if (owner_addr.eql(addr)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) matches = false;
                } else {
                    matches = false;
                }
            }

            // Get expiry for filter checks and sorting
            // Calculate expiry from timestamp + duration
            if (parsed.value.object.get("duration")) |duration_val| {
                if (duration_val == .integer) {
                    event_expiry = event.timestamp + duration_val.integer;
                }
            }
        }

        // Apply expiry filters
        if (matches and filter_expiry_gt != null) {
            if (event_expiry <= filter_expiry_gt.?) matches = false;
        }
        if (matches and filter_expiry_gte != null) {
            if (event_expiry < filter_expiry_gte.?) matches = false;
        }
        if (matches and filter_expiry_lt != null) {
            if (event_expiry >= filter_expiry_lt.?) matches = false;
        }
        if (matches and filter_expiry_lte != null) {
            if (event_expiry > filter_expiry_lte.?) matches = false;
        }

        if (matches) {
            try filtered_events.append(allocator, .{
                .event = event,
                .name = event.name.?,
                .expiry = event_expiry,
            });
        }
    }

    // Sort filtered events if orderBy is specified
    if (order_by) |field_name| {
        const ascending = std.mem.eql(u8, order_direction, "asc");
        const SortContext = struct {
            field: []const u8,
            asc: bool,
        };
        const sort_ctx = SortContext{ .field = field_name, .asc = ascending };

        std.mem.sort(FilteredEvent, filtered_events.items, sort_ctx, struct {
            fn lessThan(sort_ctx_param: SortContext, a: FilteredEvent, b: FilteredEvent) bool {
                if (std.mem.eql(u8, sort_ctx_param.field, "name")) {
                    const cmp = std.mem.order(u8, a.name, b.name);
                    return if (sort_ctx_param.asc) cmp == .lt else cmp == .gt;
                } else if (std.mem.eql(u8, sort_ctx_param.field, "registrationDate")) {
                    return if (sort_ctx_param.asc) a.event.timestamp < b.event.timestamp else a.event.timestamp > b.event.timestamp;
                } else if (std.mem.eql(u8, sort_ctx_param.field, "expiryDate")) {
                    return if (sort_ctx_param.asc) a.expiry < b.expiry else a.expiry > b.expiry;
                } else if (std.mem.eql(u8, sort_ctx_param.field, "id")) {
                    // For registrations, id is the name
                    const cmp = std.mem.order(u8, a.name, b.name);
                    return if (sort_ctx_param.asc) cmp == .lt else cmp == .gt;
                }
                return false;
            }
        }.lessThan);
    }

    // Build JSON from sorted/filtered events, applying skip
    var json: std.ArrayList(u8) = .{};
    defer json.deinit(allocator);

    try json.appendSlice(allocator, "[");
    const start_idx = @min(skip, filtered_events.items.len);
    const end_idx = @min(start_idx + first, filtered_events.items.len);
    for (filtered_events.items[@as(usize, @intCast(start_idx))..@as(usize, @intCast(end_idx))], 0..) |filtered, i| {
        if (i > 0) try json.appendSlice(allocator, ",");

        const reg_json = try buildRegistrationJson(filtered.event, field.selections, .{
            .database = database,
            .depth = 0,
            .allocator = allocator,
            .loaders = ctx.loaders,
        });
        defer allocator.free(reg_json);
        try json.appendSlice(allocator, reg_json);
    }
    try json.appendSlice(allocator, "]");

    const result_json = try allocator.dupe(u8, json.items);
    return parser.FieldResult{ .json = result_json };
}

/// Resolver for events query
fn resolveEvents(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));
    const allocator = ctx.allocator;

    // Extract arguments
    const first = parser.getIntArg(field, "first", 100) orelse 100;

    // Parse EventFilter if provided
    var filter_opts = db.EventFilterOptions{
        .limit = @intCast(first),
    };

    // Temporary storage for event_types strings
    var event_types_list: std.ArrayList([]const u8) = .{};
    defer event_types_list.deinit(allocator);

    // Temporary storage for normalized contract address (to handle checksummed addresses)
    var normalized_contract_address: ?[]u8 = null;
    defer if (normalized_contract_address) |addr| allocator.free(addr);

    // Parse 'where' argument
    for (field.arguments) |arg| {
        if (std.mem.eql(u8, arg.name, "where") and arg.value == .object) {
            for (arg.value.object) |filter_arg| {
                if (std.mem.eql(u8, filter_arg.name, "type")) {
                    if (filter_arg.value == .string) {
                        filter_opts.event_type = filter_arg.value.string;
                    }
                } else if (std.mem.eql(u8, filter_arg.name, "type_in")) {
                    if (filter_arg.value == .list) {
                        for (filter_arg.value.list) |item| {
                            if (item == .string) {
                                try event_types_list.append(allocator, item.string);
                            }
                        }
                        if (event_types_list.items.len > 0) {
                            filter_opts.event_types = event_types_list.items;
                        }
                    }
                } else if (std.mem.eql(u8, filter_arg.name, "domain")) {
                    if (filter_arg.value == .string) {
                        filter_opts.domain = filter_arg.value.string;
                    }
                } else if (std.mem.eql(u8, filter_arg.name, "contractAddress")) {
                    if (filter_arg.value == .string) {
                        // Parse and normalize address using Address.fromHex (validates format, normalizes to lowercase)
                        const addr = Address.fromHex(filter_arg.value.string) catch {
                            // Invalid address format - return error to user
                            return error.InvalidContractAddress;
                        };
                        normalized_contract_address = try addr.toHex(allocator);
                        filter_opts.contract_address = normalized_contract_address;
                    }
                } else if (std.mem.eql(u8, filter_arg.name, "namehash")) {
                    if (filter_arg.value == .string) {
                        filter_opts.namehash = filter_arg.value.string;
                    }
                } else if (std.mem.eql(u8, filter_arg.name, "blockNumber_gt")) {
                    if (filter_arg.value == .int) {
                        filter_opts.block_number_gt = filter_arg.value.int;
                    }
                } else if (std.mem.eql(u8, filter_arg.name, "blockNumber_lt")) {
                    if (filter_arg.value == .int) {
                        filter_opts.block_number_lt = filter_arg.value.int;
                    }
                } else if (std.mem.eql(u8, filter_arg.name, "timestamp_gt")) {
                    if (filter_arg.value == .int) {
                        filter_opts.timestamp_gt = filter_arg.value.int;
                    }
                } else if (std.mem.eql(u8, filter_arg.name, "timestamp_lt")) {
                    if (filter_arg.value == .int) {
                        filter_opts.timestamp_lt = filter_arg.value.int;
                    }
                }
            }
        }
    }

    // Get events from database with filters
    const events = try database.getEventsFiltered(filter_opts);
    defer {
        for (events) |*event| {
            event.deinit(allocator);
        }
        allocator.free(events);
    }

    // Build JSON array
    var json: std.ArrayList(u8) = .{};
    defer json.deinit(allocator);

    try json.appendSlice(allocator, "[");
    for (events, 0..) |*event, i| {
        if (i > 0) try json.appendSlice(allocator, ",");

        // Build event object with nested field support
        const event_json = try buildEventJson(event, field.selections, .{
            .database = database,
            .depth = 0,
            .allocator = allocator,
            .loaders = ctx.loaders,
        });
        defer allocator.free(event_json);
        try json.appendSlice(allocator, event_json);
    }
    try json.appendSlice(allocator, "]");

    const result_json = try allocator.dupe(u8, json.items);
    return parser.FieldResult{ .json = result_json };
}

/// Parse chain argument from GraphQL field, defaulting to L2
fn parseChainArg(field: *const parser.Field) models.Chain {
    const chain_str = parser.getStringArg(field, "chain", null) orelse "l2";
    if (std.mem.eql(u8, chain_str, "l1")) {
        return .l1;
    }
    return .l2; // Default to L2
}

/// Resolver for roles query
fn resolveRoles(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const allocator = ctx.allocator;
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));

    // Get chain argument (default: l2)
    const chain = parseChainArg(field);

    // Get optional arguments
    const resource_arg = parser.getStringArg(field, "resource", null);
    const account_arg = parser.getStringArg(field, "account", null);

    // Determine which database method to call based on arguments
    const roles = if (resource_arg) |resource|
        try database.getRolesByResource(chain, resource)
    else if (account_arg) |account_str|
        blk: {
            const account_addr = Address.fromHex(account_str) catch {
                // Invalid address, return empty array
                const json = try allocator.dupe(u8, "[]");
                return parser.FieldResult{ .json = json };
            };
            break :blk try database.getRolesByAccount(chain, account_addr);
        }
    else
        try allocator.alloc(models.EACRoleAssignment, 0); // No arguments, return empty

    defer {
        for (roles) |*role| {
            role.deinit(allocator);
        }
        allocator.free(roles);
    }

    // Build JSON array
    var json: std.ArrayList(u8) = .{};
    defer json.deinit(allocator);
    try json.appendSlice(allocator, "[");

    for (roles, 0..) |*role, i| {
        if (i > 0) try json.appendSlice(allocator, ",");
        const handler = FieldHandler{
            .handleFn = handleEACRoleField,
            .context = @constCast(@ptrCast(role)),
        };
        const role_json = try buildJsonWithFields(allocator, field.selections, handler);
        defer allocator.free(role_json);
        try json.appendSlice(allocator, role_json);
    }

    try json.appendSlice(allocator, "]");
    return parser.FieldResult{ .json = try allocator.dupe(u8, json.items) };
}

/// Resolver for resolvers query
fn resolveResolvers(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const allocator = ctx.allocator;
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));

    // Get chain argument (default: l2)
    const chain = parseChainArg(field);

    // Get required account argument
    const account_arg = parser.getStringArg(field, "account", null) orelse {
        const json = try allocator.dupe(u8, "[]");
        return parser.FieldResult{ .json = json };
    };

    const account_addr = Address.fromHex(account_arg) catch {
        // Invalid address, return empty array
        const json = try allocator.dupe(u8, "[]");
        return parser.FieldResult{ .json = json };
    };

    const resolvers = try database.getResolversByOwner(chain, account_addr);
    defer {
        for (resolvers) |*resolver| {
            resolver.deinit(allocator);
        }
        allocator.free(resolvers);
    }

    // Build JSON array
    var json: std.ArrayList(u8) = .{};
    defer json.deinit(allocator);
    try json.appendSlice(allocator, "[");

    for (resolvers, 0..) |*resolver, i| {
        if (i > 0) try json.appendSlice(allocator, ",");
        const handler = FieldHandler{
            .handleFn = handleResolverField,
            .context = @constCast(@ptrCast(resolver)),
        };
        const resolver_json = try buildJsonWithFields(allocator, field.selections, handler);
        defer allocator.free(resolver_json);
        try json.appendSlice(allocator, resolver_json);
    }

    try json.appendSlice(allocator, "]");
    return parser.FieldResult{ .json = try allocator.dupe(u8, json.items) };
}

/// Resolver for registries query
fn resolveRegistries(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const allocator = ctx.allocator;
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));

    // Get chain argument (default: l2)
    const chain = parseChainArg(field);

    // Get required owner argument
    const owner_arg = parser.getStringArg(field, "owner", null) orelse {
        const json = try allocator.dupe(u8, "[]");
        return parser.FieldResult{ .json = json };
    };

    const owner_addr = Address.fromHex(owner_arg) catch {
        // Invalid address, return empty array
        const json = try allocator.dupe(u8, "[]");
        return parser.FieldResult{ .json = json };
    };

    const registries = try database.getRegistriesByOwner(chain, owner_addr);
    defer {
        for (registries) |*registry| {
            registry.deinit(allocator);
        }
        allocator.free(registries);
    }

    // Build JSON array
    var json: std.ArrayList(u8) = .{};
    defer json.deinit(allocator);
    try json.appendSlice(allocator, "[");

    for (registries, 0..) |*registry, i| {
        if (i > 0) try json.appendSlice(allocator, ",");
        const handler = FieldHandler{
            .handleFn = handleRegistryField,
            .context = @constCast(@ptrCast(registry)),
        };
        const registry_json = try buildJsonWithFields(allocator, field.selections, handler);
        defer allocator.free(registry_json);
        try json.appendSlice(allocator, registry_json);
    }

    try json.appendSlice(allocator, "]");
    return parser.FieldResult{ .json = try allocator.dupe(u8, json.items) };
}

/// Resolver for metadata query
fn resolveMetadata(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const allocator = ctx.allocator;
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));

    // Get chain argument (default: l2)
    const chain = parseChainArg(field);

    // Get required resolver argument
    const resolver_arg = parser.getStringArg(field, "resolver", null) orelse {
        const json = try allocator.dupe(u8, "null");
        return parser.FieldResult{ .json = json };
    };

    const resolver_addr = Address.fromHex(resolver_arg) catch {
        // Invalid address, return null
        const json = try allocator.dupe(u8, "null");
        return parser.FieldResult{ .json = json };
    };

    const metadata_opt = try database.getResolverMetadata(chain, resolver_addr);
    if (metadata_opt) |metadata| {
        var metadata_mut = metadata;
        defer metadata_mut.deinit(allocator);

        const handler = FieldHandler{
            .handleFn = handleResolverMetadataField,
            .context = @constCast(@ptrCast(&metadata_mut)),
        };
        const json = try buildJsonWithFields(allocator, field.selections, handler);
        return parser.FieldResult{ .json = json };
    } else {
        const json = try allocator.dupe(u8, "null");
        return parser.FieldResult{ .json = json };
    }
}

/// Resolver for approvals query
fn resolveApprovals(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const allocator = ctx.allocator;
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));

    // Get chain argument (default: l2)
    const chain = parseChainArg(field);

    // Get optional arguments
    const namehash_arg = parser.getStringArg(field, "namehash", null);
    const delegate_arg = parser.getStringArg(field, "delegate", null);

    // Determine which database method to call based on arguments
    const approvals = if (namehash_arg) |namehash_str|
        blk: {
            const namehash_hash = Hash.fromHex(namehash_str) catch {
                // Invalid hash, return empty array
                const json = try allocator.dupe(u8, "[]");
                return parser.FieldResult{ .json = json };
            };
            break :blk try database.getApprovalsForName(chain, namehash_hash, null);
        }
    else if (delegate_arg) |delegate_str|
        blk: {
            const delegate_addr = Address.fromHex(delegate_str) catch {
                // Invalid address, return empty array
                const json = try allocator.dupe(u8, "[]");
                return parser.FieldResult{ .json = json };
            };
            break :blk try database.getApprovalsForDelegate(chain, delegate_addr);
        }
    else
        try allocator.alloc(models.ResolverApproval, 0); // No arguments, return empty

    defer {
        for (approvals) |*approval| {
            approval.deinit(allocator);
        }
        allocator.free(approvals);
    }

    // Build JSON array
    var json: std.ArrayList(u8) = .{};
    defer json.deinit(allocator);
    try json.appendSlice(allocator, "[");

    for (approvals, 0..) |*approval, i| {
        if (i > 0) try json.appendSlice(allocator, ",");
        const handler = FieldHandler{
            .handleFn = handleResolverApprovalField,
            .context = @constCast(@ptrCast(approval)),
        };
        const approval_json = try buildJsonWithFields(allocator, field.selections, handler);
        defer allocator.free(approval_json);
        try json.appendSlice(allocator, approval_json);
    }

    try json.appendSlice(allocator, "]");
    return parser.FieldResult{ .json = try allocator.dupe(u8, json.items) };
}

// ============================================================================
// Nested Object Builders
// ============================================================================

/// Build Account (owner/registrant) JSON with nested field selection support
fn buildAccountJson(
    address: Address,
    selections: []const parser.Field,
    ctx: NestedContext,
) anyerror![]u8 {
    // Check depth limit
    if (ctx.depth >= MAX_QUERY_DEPTH) {
        return error.MaxDepthExceeded;
    }

    // If no selections, return just id
    if (selections.len == 0) {
        const addr_hex = try address.toHex(ctx.allocator);
        defer ctx.allocator.free(addr_hex);
        return try std.fmt.allocPrint(ctx.allocator, "{{\"id\":\"{s}\"}}", .{addr_hex});
    }

    var json: std.ArrayList(u8) = .{};
    defer json.deinit(ctx.allocator);
    const writer = json.writer(ctx.allocator);

    try writer.writeAll("{");
    var first = true;

    for (selections) |*field| {
        if (!first) try writer.writeAll(",");

        // Use alias if provided, otherwise use field name (GraphQL spec compliance)
        const output_key = field.alias orelse field.name;

        if (std.mem.eql(u8, field.name, "id")) {
            const addr_hex = try address.toHex(ctx.allocator);
            defer ctx.allocator.free(addr_hex);
            try writer.print("\"{s}\":\"{s}\"", .{ output_key, addr_hex });
            first = false;
        } else if (std.mem.eql(u8, field.name, "domains")) {
            // Nested query: fetch domains owned by this account
            const first_arg = parser.getIntArg(field, "first", 10) orelse 10;
            const skip_arg = parser.getIntArg(field, "skip", 0) orelse 0;

            const domains = try ctx.database.getAllNames(address, @intCast(skip_arg), @intCast(first_arg));
            defer {
                for (domains) |*domain| {
                    domain.deinit(ctx.allocator);
                }
                ctx.allocator.free(domains);
            }

            try writer.print("\"{s}\":[", .{output_key});
            for (domains, 0..) |*domain, i| {
                if (i > 0) try writer.writeAll(",");
                const domain_json = try buildDomainJson(domain, field.selections, .{
                    .database = ctx.database,
                    .depth = ctx.depth + 1,
                    .allocator = ctx.allocator,
                    .loaders = ctx.loaders,
                });
                defer ctx.allocator.free(domain_json);
                try writer.writeAll(domain_json);
            }
            try writer.writeAll("]");
            first = false;
        } else if (std.mem.eql(u8, field.name, "registrations")) {
            // Nested query: fetch registrations by this account
            // Use database query with JSON filter to find NameRegistered events by owner
            const first_arg = parser.getIntArg(field, "first", 10) orelse 10;

            const account_hex = try address.toHex(ctx.allocator);
            defer ctx.allocator.free(account_hex);

            // Query events filtered by event_type and JSON owner field
            const all_events = try ctx.database.getEventsFiltered(.{
                .event_type = "NameRegistered",
                .data_json_owner = account_hex,
                .limit = @intCast(first_arg),
            });
            defer {
                for (all_events) |*e| {
                    e.deinit(ctx.allocator);
                }
                ctx.allocator.free(all_events);
            }

            try writer.print("\"{s}\":[", .{output_key});
            for (all_events, 0..) |*event, i| {
                if (i > 0) try writer.writeAll(",");

                const reg_json = try buildRegistrationJson(event, field.selections, .{
                    .database = ctx.database,
                    .depth = ctx.depth + 1,
                    .allocator = ctx.allocator,
                    .loaders = ctx.loaders,
                });
                defer ctx.allocator.free(reg_json);
                try writer.writeAll(reg_json);
            }
            try writer.writeAll("]");
            first = false;
        } else if (std.mem.eql(u8, field.name, "__typename")) {
            try writer.print("\"{s}\":\"Account\"", .{output_key});
            first = false;
        } else {
            // Unknown field - return null per GraphQL spec
            try writer.print("\"{s}\":null", .{output_key});
            first = false;
        }
    }

    try writer.writeAll("}");
    return try ctx.allocator.dupe(u8, json.items);
}

/// Build Domain/Name JSON with nested field selection support
fn buildDomainJson(
    domain: *const models.Name,
    selections: []const parser.Field,
    ctx: NestedContext,
) anyerror![]u8 {
    // Check depth limit
    if (ctx.depth >= MAX_QUERY_DEPTH) {
        return error.MaxDepthExceeded;
    }

    // If no selections, return just id
    if (selections.len == 0) {
        const escaped = try escapeJsonString(ctx.allocator, domain.name orelse "[unknown]");
        defer ctx.allocator.free(escaped);
        return try std.fmt.allocPrint(ctx.allocator, "{{\"id\":\"{s}\"}}", .{escaped});
    }

    var json: std.ArrayList(u8) = .{};
    defer json.deinit(ctx.allocator);
    const writer = json.writer(ctx.allocator);

    try writer.writeAll("{");
    var first = true;

    for (selections) |*field| {
        if (!first) try writer.writeAll(",");

        // Use alias if provided, otherwise use field name (GraphQL spec compliance)
        const output_key = field.alias orelse field.name;

        if (std.mem.eql(u8, field.name, "id") or std.mem.eql(u8, field.name, "name")) {
            const escaped = try escapeJsonString(ctx.allocator, domain.name orelse "[unknown]");
            defer ctx.allocator.free(escaped);
            try writer.print("\"{s}\":\"{s}\"", .{ output_key, escaped });
            first = false;
        } else if (std.mem.eql(u8, field.name, "labelName")) {
            const escaped = try escapeJsonString(ctx.allocator, domain.label orelse "[unknown]");
            defer ctx.allocator.free(escaped);
            try writer.print("\"{s}\":\"{s}\"", .{ output_key, escaped });
            first = false;
        } else if (std.mem.eql(u8, field.name, "labelhash")) {
            const hash_hex = try domain.label_hash.toHex(ctx.allocator);
            defer ctx.allocator.free(hash_hex);
            try writer.print("\"{s}\":\"{s}\"", .{ output_key, hash_hex });
            first = false;
        } else if (std.mem.eql(u8, field.name, "expiryDate")) {
            if (hasValidExpiry(domain.expiry)) {
                try writer.print("\"{s}\":{d}", .{ output_key, domain.expiry });
            } else {
                try writer.print("\"{s}\":null", .{output_key});
            }
            first = false;
        } else if (std.mem.eql(u8, field.name, "owner")) {
            // Nested Account object
            try writer.print("\"{s}\":", .{output_key});
            const owner_json = try buildAccountJson(domain.owner, field.selections, .{
                .database = ctx.database,
                .depth = ctx.depth + 1,
                .allocator = ctx.allocator,
                .loaders = ctx.loaders,
            });
            defer ctx.allocator.free(owner_json);
            try writer.writeAll(owner_json);
            first = false;
        } else if (std.mem.eql(u8, field.name, "registrant")) {
            // Nested Account object - the original registrant (from NameRegistered event)
            try writer.print("\"{s}\":", .{output_key});
            const registrant_json = try buildAccountJson(domain.registrant, field.selections, .{
                .database = ctx.database,
                .depth = ctx.depth + 1,
                .allocator = ctx.allocator,
                .loaders = ctx.loaders,
            });
            defer ctx.allocator.free(registrant_json);
            try writer.writeAll(registrant_json);
            first = false;
        } else if (std.mem.eql(u8, field.name, "resolvedAddress")) {
            // Nested Account object - the address this domain resolves to (ETH address, coin type 60)
            // Use DataLoader if available
            const dataloader_mod = @import("dataloader.zig");
            try writer.print("\"{s}\":", .{output_key});

            var resolved_addr_opt: ?[]const u8 = null;
            var owns_addr = false;

            if (ctx.loaders) |loaders_ptr| {
                const loader_ctx: *dataloader_mod.LoaderContext = @ptrCast(@alignCast(loaders_ptr));
                const loader = try loader_ctx.getResolverAddressLoader();
                resolved_addr_opt = try loader.load(domain.namehash.bytes);
                // DataLoader owns the memory, don't free it
            } else {
                // Fallback to direct database query
                resolved_addr_opt = try ctx.database.getResolverAddress(domain.namehash, 60);
                owns_addr = true;
            }
            defer if (owns_addr) if (resolved_addr_opt) |a| ctx.allocator.free(a);

            if (resolved_addr_opt) |addr_str| {
                // Parse the address and build Account JSON
                if (Address.fromHex(addr_str)) |addr| {
                    const account_json = try buildAccountJson(addr, field.selections, .{
                        .database = ctx.database,
                        .depth = ctx.depth + 1,
                        .allocator = ctx.allocator,
                        .loaders = ctx.loaders,
                    });
                    defer ctx.allocator.free(account_json);
                    try writer.writeAll(account_json);
                } else |_| {
                    try writer.writeAll("null");
                }
            } else {
                try writer.writeAll("null");
            }
            first = false;
        } else if (std.mem.eql(u8, field.name, "resolver")) {
            // Nested Resolver object
            try writer.print("\"{s}\":", .{output_key});
            if (!domain.resolver.isZero()) {
                const resolver_json = try buildResolverJson(domain.resolver, domain.namehash, field.selections, .{
                    .database = ctx.database,
                    .depth = ctx.depth + 1,
                    .allocator = ctx.allocator,
                    .loaders = ctx.loaders,
                });
                defer ctx.allocator.free(resolver_json);
                try writer.writeAll(resolver_json);
            } else {
                try writer.writeAll("null");
            }
            first = false;
        } else if (std.mem.eql(u8, field.name, "tokenId")) {
            const token_id_hex = try std.fmt.allocPrint(ctx.allocator, "0x{x}", .{domain.token_id});
            defer ctx.allocator.free(token_id_hex);
            try writer.print("\"{s}\":\"{s}\"", .{ output_key, token_id_hex });
            first = false;
        } else if (std.mem.eql(u8, field.name, "canonicalId")) {
            const canonical_hex = try std.fmt.allocPrint(ctx.allocator, "0x{x}", .{domain.canonical_id});
            defer ctx.allocator.free(canonical_hex);
            try writer.print("\"{s}\":\"{s}\"", .{ output_key, canonical_hex });
            first = false;
        } else if (std.mem.eql(u8, field.name, "tokenVersion")) {
            try writer.print("\"{s}\":{d}", .{ output_key, domain.token_version });
            first = false;
        } else if (std.mem.eql(u8, field.name, "isMigrated")) {
            try writer.print("\"{s}\":{s}", .{ output_key, if (domain.migrated) "true" else "false" });
            first = false;
        } else if (std.mem.eql(u8, field.name, "createdAt")) {
            try writer.print("\"{s}\":{d}", .{ output_key, domain.created_at });
            first = false;
        } else if (std.mem.eql(u8, field.name, "registrationDate")) {
            try writer.print("\"{s}\":{d}", .{ output_key, domain.created_at });
            first = false;
        } else if (std.mem.eql(u8, field.name, "normalizedName")) {
            // Compute ENSIP-15 normalized name on-the-fly
            if (domain.name) |name| {
                if (ens_normalize.normalize(ctx.allocator, name)) |normalized| {
                    defer ctx.allocator.free(normalized);
                    const escaped = try escapeJsonString(ctx.allocator, normalized);
                    defer ctx.allocator.free(escaped);
                    try writer.print("\"{s}\":\"{s}\"", .{ output_key, escaped });
                } else |_| {
                    // Normalization failed - name is not ENSIP-15 compliant
                    try writer.print("\"{s}\":null", .{output_key});
                }
            } else {
                try writer.print("\"{s}\":null", .{output_key});
            }
            first = false;
        } else if (std.mem.eql(u8, field.name, "isNormalized")) {
            // Check if name passes ENSIP-15 normalization
            if (domain.name) |name| {
                if (ens_normalize.normalize(ctx.allocator, name)) |normalized| {
                    defer ctx.allocator.free(normalized);
                    // Name is normalized if it equals its normalized form
                    const is_normalized = std.mem.eql(u8, name, normalized);
                    try writer.print("\"{s}\":{s}", .{ output_key, if (is_normalized) "true" else "false" });
                } else |_| {
                    // Normalization failed - definitely not normalized
                    try writer.print("\"{s}\":false", .{output_key});
                }
            } else {
                // No name - consider not normalized
                try writer.print("\"{s}\":false", .{output_key});
            }
            first = false;
        } else if (std.mem.eql(u8, field.name, "parent")) {
            // Nested parent Domain
            try writer.print("\"{s}\":", .{output_key});
            if (!domain.parent_namehash.isZero()) {
                const parent_opt = try ctx.database.getNameByNamehash(domain.parent_namehash);
                if (parent_opt) |parent| {
                    var parent_mut = parent;
                    defer parent_mut.deinit(ctx.allocator);
                    const parent_json = try buildDomainJson(&parent_mut, field.selections, .{
                        .database = ctx.database,
                        .depth = ctx.depth + 1,
                        .allocator = ctx.allocator,
                        .loaders = ctx.loaders,
                    });
                    defer ctx.allocator.free(parent_json);
                    try writer.writeAll(parent_json);
                } else {
                    try writer.writeAll("null");
                }
            } else {
                try writer.writeAll("null");
            }
            first = false;
        } else if (std.mem.eql(u8, field.name, "subdomains")) {
            // Query subdomains: names where parent_name = this domain's name
            const first_arg = parser.getIntArg(field, "first", 10) orelse 10;
            const skip_arg = parser.getIntArg(field, "skip", 0) orelse 0;

            try writer.print("\"{s}\":[", .{output_key});

            // Use efficient database query for subdomains
            if (domain.name) |parent_name| {
                const subdomains = try ctx.database.getSubdomains(parent_name, @intCast(skip_arg), @intCast(first_arg));
                defer {
                    for (subdomains) |*n| {
                        n.deinit(ctx.allocator);
                    }
                    ctx.allocator.free(subdomains);
                }

                for (subdomains, 0..) |*subdomain, i| {
                    if (i > 0) try writer.writeAll(",");
                    const subdomain_json = try buildDomainJson(subdomain, field.selections, .{
                        .database = ctx.database,
                        .depth = ctx.depth + 1,
                        .allocator = ctx.allocator,
                        .loaders = ctx.loaders,
                    });
                    defer ctx.allocator.free(subdomain_json);
                    try writer.writeAll(subdomain_json);
                }
            }

            try writer.writeAll("]");
            first = false;
        } else if (std.mem.eql(u8, field.name, "events")) {
            // Query events for this domain
            const first_arg = parser.getIntArg(field, "first", 100) orelse 100;

            // Get namehash as hex for querying
            const namehash_hex = try domain.namehash.toHex(ctx.allocator);
            defer ctx.allocator.free(namehash_hex);

            // Query events by namehash
            const domain_events = try ctx.database.getEventsByNamehash(namehash_hex, @intCast(first_arg));
            defer {
                for (domain_events) |*e| {
                    e.deinit(ctx.allocator);
                }
                ctx.allocator.free(domain_events);
            }

            try writer.print("\"{s}\":[", .{output_key});
            for (domain_events, 0..) |*event, i| {
                if (i > 0) try writer.writeAll(",");
                const event_json = try buildEventJson(event, field.selections, .{
                    .database = ctx.database,
                    .depth = ctx.depth + 1,
                    .allocator = ctx.allocator,
                    .loaders = ctx.loaders,
                });
                defer ctx.allocator.free(event_json);
                try writer.writeAll(event_json);
            }
            try writer.writeAll("]");
            first = false;
        } else if (std.mem.eql(u8, field.name, "__typename")) {
            try writer.print("\"{s}\":\"Domain\"", .{output_key});
            first = false;
        } else {
            // Unknown field - return null per GraphQL spec
            try writer.print("\"{s}\":null", .{output_key});
            first = false;
        }
    }

    try writer.writeAll("}");
    return try ctx.allocator.dupe(u8, json.items);
}

/// Build Resolver JSON with nested field selection support
fn buildResolverJson(
    resolver: Address,
    domain_namehash: Hash,
    selections: []const parser.Field,
    ctx: NestedContext,
) anyerror![]u8 {
    // Check depth limit
    if (ctx.depth >= MAX_QUERY_DEPTH) {
        return error.MaxDepthExceeded;
    }

    // If no selections, return just address
    if (selections.len == 0) {
        const addr_hex = try resolver.toHex(ctx.allocator);
        defer ctx.allocator.free(addr_hex);
        return try std.fmt.allocPrint(ctx.allocator, "{{\"address\":\"{s}\"}}", .{addr_hex});
    }

    var json: std.ArrayList(u8) = .{};
    defer json.deinit(ctx.allocator);
    const writer = json.writer(ctx.allocator);

    try writer.writeAll("{");
    var first = true;

    for (selections) |*field| {
        if (!first) try writer.writeAll(",");

        // Use alias if provided, otherwise use field name (GraphQL spec compliance)
        const output_key = field.alias orelse field.name;

        if (std.mem.eql(u8, field.name, "id") or std.mem.eql(u8, field.name, "address")) {
            const addr_hex = try resolver.toHex(ctx.allocator);
            defer ctx.allocator.free(addr_hex);
            try writer.print("\"{s}\":\"{s}\"", .{ output_key, addr_hex });
            first = false;
        } else if (std.mem.eql(u8, field.name, "addr")) {
            // Fetch address for specified coin type (default: 60 for ETH)
            // Supports: addr or addr(coinType: 60)
            const dataloader_mod = @import("dataloader.zig");
            var addr_opt: ?[]const u8 = null;
            var owns_addr = false;

            // Parse coinType argument (default to 60 for ETH)
            var coin_type: u64 = 60;
            for (field.arguments) |arg| {
                if (std.mem.eql(u8, arg.name, "coinType")) {
                    if (arg.value == .int) {
                        coin_type = @intCast(arg.value.int);
                    }
                }
            }

            // Only use DataLoader for default ETH (coinType 60)
            if (coin_type == 60) {
                if (ctx.loaders) |loaders_ptr| {
                    const loader_ctx: *dataloader_mod.LoaderContext = @ptrCast(@alignCast(loaders_ptr));
                    const loader = try loader_ctx.getResolverAddressLoader();
                    addr_opt = try loader.load(domain_namehash.bytes);
                    // DataLoader owns the memory, don't free it
                } else {
                    addr_opt = try ctx.database.getResolverAddress(domain_namehash, 60);
                    owns_addr = true;
                }
            } else {
                // For non-ETH coin types, query database directly
                addr_opt = try ctx.database.getResolverAddress(domain_namehash, coin_type);
                owns_addr = true;
            }
            defer if (owns_addr) if (addr_opt) |a| ctx.allocator.free(a);

            if (addr_opt) |addr| {
                const escaped = try escapeJsonString(ctx.allocator, addr);
                defer ctx.allocator.free(escaped);
                try writer.print("\"{s}\":\"{s}\"", .{ output_key, escaped });
            } else {
                try writer.print("\"{s}\":null", .{output_key});
            }
            first = false;
        } else if (std.mem.eql(u8, field.name, "addresses")) {
            // Fetch all addresses for all coin types
            // Returns array with requested subfields (coinType and/or address)
            const resolvers_mod = @import("../storage/resolvers.zig");
            const all_addresses = try resolvers_mod.getResolverAllAddresses(ctx.database, domain_namehash);
            defer {
                for (all_addresses) |*addr| {
                    addr.deinit(ctx.allocator);
                }
                ctx.allocator.free(all_addresses);
            }

            // Check which subfields are requested
            var want_coin_type = false;
            var want_address = false;
            for (field.selections) |subfield| {
                if (std.mem.eql(u8, subfield.name, "coinType")) {
                    want_coin_type = true;
                } else if (std.mem.eql(u8, subfield.name, "address")) {
                    want_address = true;
                }
            }
            // Default to both if no selections (shouldn't happen in valid GraphQL)
            if (!want_coin_type and !want_address) {
                want_coin_type = true;
                want_address = true;
            }

            try writer.print("\"{s}\":[", .{output_key});
            for (all_addresses, 0..) |coin_addr, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.writeAll("{");
                var first_subfield = true;
                if (want_coin_type) {
                    try writer.print("\"coinType\":{d}", .{coin_addr.coin_type});
                    first_subfield = false;
                }
                if (want_address) {
                    const escaped = try escapeJsonString(ctx.allocator, coin_addr.address);
                    defer ctx.allocator.free(escaped);
                    if (!first_subfield) try writer.writeAll(",");
                    try writer.print("\"address\":\"{s}\"", .{escaped});
                }
                try writer.writeAll("}");
            }
            try writer.writeAll("]");
            first = false;
        } else if (std.mem.eql(u8, field.name, "contentHash")) {
            // Fetch content hash - use DataLoader if available
            const dataloader_mod = @import("dataloader.zig");
            var hash_opt: ?[]const u8 = null;
            var owns_hash = false;

            if (ctx.loaders) |loaders_ptr| {
                const loader_ctx: *dataloader_mod.LoaderContext = @ptrCast(@alignCast(loaders_ptr));
                const loader = try loader_ctx.getContentHashLoader();
                hash_opt = try loader.load(domain_namehash.bytes);
                // DataLoader owns the memory, don't free it
            } else {
                // Fallback to direct database query
                hash_opt = try ctx.database.getResolverContentHash(domain_namehash);
                owns_hash = true;
            }
            defer if (owns_hash) if (hash_opt) |h| ctx.allocator.free(h);

            if (hash_opt) |hash| {
                const escaped = try escapeJsonString(ctx.allocator, hash);
                defer ctx.allocator.free(escaped);
                try writer.print("\"{s}\":\"{s}\"", .{ output_key, escaped });
            } else {
                try writer.print("\"{s}\":null", .{output_key});
            }
            first = false;
        } else if (std.mem.eql(u8, field.name, "texts")) {
            // Fetch text record keys by namehash - use DataLoader if available
            const dataloader_mod = @import("dataloader.zig");

            if (ctx.loaders) |loaders_ptr| {
                const loader_ctx: *dataloader_mod.LoaderContext = @ptrCast(@alignCast(loaders_ptr));
                const loader = try loader_ctx.getTextRecordsLoader();
                const text_records = try loader.load(domain_namehash.bytes);
                // DataLoader owns the memory, don't free it

                try writer.print("\"{s}\":[", .{output_key});
                for (text_records.records, 0..) |record, i| {
                    if (i > 0) try writer.writeAll(",");
                    const escaped = try escapeJsonString(ctx.allocator, record.key);
                    defer ctx.allocator.free(escaped);
                    try writer.print("\"{s}\"", .{escaped});
                }
                try writer.writeAll("]");
            } else {
                // Fallback to direct database query
                const text_keys = try ctx.database.getResolverTextKeys(domain_namehash);
                defer {
                    for (text_keys) |key| {
                        ctx.allocator.free(key);
                    }
                    ctx.allocator.free(text_keys);
                }
                try writer.print("\"{s}\":[", .{output_key});
                for (text_keys, 0..) |key, i| {
                    if (i > 0) try writer.writeAll(",");
                    const escaped = try escapeJsonString(ctx.allocator, key);
                    defer ctx.allocator.free(escaped);
                    try writer.print("\"{s}\"", .{escaped});
                }
                try writer.writeAll("]");
            }
            first = false;
        } else if (std.mem.eql(u8, field.name, "text")) {
            // Get text record value for specific key - use DataLoader if available
            const dataloader_mod = @import("dataloader.zig");
            var key_arg: ?[]const u8 = null;
            for (field.arguments) |arg| {
                if (std.mem.eql(u8, arg.name, "key")) {
                    if (arg.value == .string) {
                        key_arg = arg.value.string;
                    }
                }
            }

            if (key_arg) |key| {
                var text_value: ?[]const u8 = null;

                if (ctx.loaders) |loaders_ptr| {
                    const loader_ctx: *dataloader_mod.LoaderContext = @ptrCast(@alignCast(loaders_ptr));
                    const loader = try loader_ctx.getTextRecordsLoader();
                    const text_records = try loader.load(domain_namehash.bytes);
                    // DataLoader owns the memory, don't free it

                    // Find the value for the requested key
                    for (text_records.records) |record| {
                        if (std.mem.eql(u8, record.key, key)) {
                            text_value = record.value;
                            break;
                        }
                    }
                } else {
                    // Fallback to direct database query
                    text_value = try ctx.database.getResolverText(domain_namehash, key);
                    // Note: In fallback case we need to free, but DataLoader case doesn't
                    defer if (ctx.loaders == null) if (text_value) |val| ctx.allocator.free(val);
                }

                if (text_value) |val| {
                    const escaped = try escapeJsonString(ctx.allocator, val);
                    defer ctx.allocator.free(escaped);
                    try writer.print("\"{s}\":\"{s}\"", .{ output_key, escaped });
                } else {
                    try writer.print("\"{s}\":null", .{output_key});
                }
            } else {
                try writer.print("\"{s}\":null", .{output_key});
            }
            first = false;
        } else if (std.mem.eql(u8, field.name, "__typename")) {
            try writer.print("\"{s}\":\"Resolver\"", .{output_key});
            first = false;
        } else {
            // Unknown field - return null per GraphQL spec
            try writer.print("\"{s}\":null", .{output_key});
            first = false;
        }
    }

    try writer.writeAll("}");
    return try ctx.allocator.dupe(u8, json.items);
}

/// Build Registration JSON with nested field selection support
fn buildRegistrationJson(
    event: *const models.Event,
    selections: []const parser.Field,
    ctx: NestedContext,
) anyerror![]u8 {
    // Check depth limit
    if (ctx.depth >= MAX_QUERY_DEPTH) {
        return error.MaxDepthExceeded;
    }

    var json: std.ArrayList(u8) = .{};
    defer json.deinit(ctx.allocator);
    const writer = json.writer(ctx.allocator);

    try writer.writeAll("{");
    var first = true;

    for (selections) |*field| {
        if (!first) try writer.writeAll(",");

        // Use alias if provided, otherwise use field name (GraphQL spec compliance)
        const output_key = field.alias orelse field.name;

        if (std.mem.eql(u8, field.name, "name") or std.mem.eql(u8, field.name, "id")) {
            if (event.name) |n| {
                const escaped = try escapeJsonString(ctx.allocator, n);
                defer ctx.allocator.free(escaped);
                try writer.print("\"{s}\":\"{s}\"", .{ output_key, escaped });
                first = false;
            }
        } else if (std.mem.eql(u8, field.name, "domain")) {
            // Nested Domain object
            if (event.namehash) |nh| {
                const domain_opt = try ctx.database.getNameByNamehash(nh);
                if (domain_opt) |domain| {
                    var domain_mut = domain;
                    defer domain_mut.deinit(ctx.allocator);
                    try writer.print("\"{s}\":", .{output_key});
                    const domain_json = try buildDomainJson(&domain_mut, field.selections, .{
                        .database = ctx.database,
                        .depth = ctx.depth + 1,
                        .allocator = ctx.allocator,
                        .loaders = ctx.loaders,
                    });
                    defer ctx.allocator.free(domain_json);
                    try writer.writeAll(domain_json);
                    first = false;
                }
            }
        } else if (std.mem.eql(u8, field.name, "registrationDate")) {
            try writer.print("\"{s}\":{d}", .{ output_key, event.timestamp });
            first = false;
        } else if (std.mem.eql(u8, field.name, "expiryDate")) {
            // Parse duration from event.data JSON and calculate expiry = timestamp + duration
            const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, event.data, .{}) catch {
                // Fallback: try to get expiry from domain record
                if (event.namehash) |nh| {
                    const domain_opt = ctx.database.getNameByNamehash(nh) catch null;
                    if (domain_opt) |domain| {
                        var domain_mut = domain;
                        defer domain_mut.deinit(ctx.allocator);
                        if (hasValidExpiry(domain_mut.expiry)) {
                            try writer.print("\"{s}\":{d}", .{ output_key, domain_mut.expiry });
                            first = false;
                            continue;
                        }
                    }
                }
                try writer.print("\"{s}\":null", .{output_key});
                first = false;
                continue;
            };
            defer parsed.deinit();

            // Try to get duration from event data
            if (parsed.value.object.get("duration")) |duration_val| {
                if (duration_val == .integer) {
                    const duration: i64 = duration_val.integer;
                    const expiry = event.timestamp + duration;
                    try writer.print("\"{s}\":{d}", .{ output_key, expiry });
                    first = false;
                    continue;
                }
            }

            // Fallback: try to get expiry from domain record in database
            if (event.namehash) |nh| {
                const domain_opt = ctx.database.getNameByNamehash(nh) catch null;
                if (domain_opt) |domain| {
                    var domain_mut = domain;
                    defer domain_mut.deinit(ctx.allocator);
                    if (hasValidExpiry(domain_mut.expiry)) {
                        try writer.print("\"{s}\":{d}", .{ output_key, domain_mut.expiry });
                        first = false;
                        continue;
                    }
                }
            }

            // No duration available
            try writer.print("\"{s}\":null", .{output_key});
            first = false;
        } else if (std.mem.eql(u8, field.name, "registrant")) {
            // Parse event.data JSON to extract the owner (registrant) address
            const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, event.data, .{}) catch {
                try writer.print("\"{s}\":null", .{output_key});
                first = false;
                continue;
            };
            defer parsed.deinit();

            const owner_str = if (parsed.value.object.get("owner")) |owner_val|
                if (owner_val == .string) owner_val.string else null
            else
                null;

            if (owner_str) |owner| {
                // Parse the owner address and build nested Account object
                const owner_addr = Address.fromHex(owner) catch {
                    try writer.print("\"{s}\":null", .{output_key});
                    first = false;
                    continue;
                };

                try writer.print("\"{s}\":", .{output_key});
                const registrant_json = try buildAccountJson(owner_addr, field.selections, .{
                    .database = ctx.database,
                    .depth = ctx.depth + 1,
                    .allocator = ctx.allocator,
                    .loaders = ctx.loaders,
                });
                defer ctx.allocator.free(registrant_json);
                try writer.writeAll(registrant_json);
            } else {
                try writer.print("\"{s}\":null", .{output_key});
            }
            first = false;
        } else if (std.mem.eql(u8, field.name, "chain")) {
            try writer.print("\"{s}\":\"{s}\"", .{ output_key, event.chain.toString() });
            first = false;
        } else if (std.mem.eql(u8, field.name, "__typename")) {
            try writer.print("\"{s}\":\"Registration\"", .{output_key});
            first = false;
        } else {
            // Unknown field - return null per GraphQL spec
            try writer.print("\"{s}\":null", .{output_key});
            first = false;
        }
    }

    try writer.writeAll("}");
    return try ctx.allocator.dupe(u8, json.items);
}

/// Build Event JSON with nested field selection support
fn buildEventJson(
    event: *const models.Event,
    selections: []const parser.Field,
    ctx: NestedContext,
) anyerror![]u8 {
    // Check depth limit
    if (ctx.depth >= MAX_QUERY_DEPTH) {
        return error.MaxDepthExceeded;
    }

    var json: std.ArrayList(u8) = .{};
    defer json.deinit(ctx.allocator);
    const writer = json.writer(ctx.allocator);

    try writer.writeAll("{");
    var first = true;

    for (selections) |*field| {
        if (!first) try writer.writeAll(",");

        // Use alias if provided, otherwise use field name (GraphQL spec compliance)
        const output_key = field.alias orelse field.name;

        if (std.mem.eql(u8, field.name, "id")) {
            const tx_hash = try event.tx_hash.toHex(ctx.allocator);
            defer ctx.allocator.free(tx_hash);
            try writer.print("\"{s}\":\"{s}-{d}\"", .{ output_key, tx_hash, event.log_index });
            first = false;
        } else if (std.mem.eql(u8, field.name, "type")) {
            try writer.print("\"{s}\":\"{s}\"", .{ output_key, event.event_type.toString() });
            first = false;
        } else if (std.mem.eql(u8, field.name, "blockNumber")) {
            try writer.print("\"{s}\":{d}", .{ output_key, event.block_number });
            first = false;
        } else if (std.mem.eql(u8, field.name, "transactionHash")) {
            const tx_hash = try event.tx_hash.toHex(ctx.allocator);
            defer ctx.allocator.free(tx_hash);
            try writer.print("\"{s}\":\"{s}\"", .{ output_key, tx_hash });
            first = false;
        } else if (std.mem.eql(u8, field.name, "timestamp")) {
            try writer.print("\"{s}\":{d}", .{ output_key, event.timestamp });
            first = false;
        } else if (std.mem.eql(u8, field.name, "contractAddress")) {
            const addr_hex = try event.contract_address.toHex(ctx.allocator);
            defer ctx.allocator.free(addr_hex);
            try writer.print("\"{s}\":\"{s}\"", .{ output_key, addr_hex });
            first = false;
        } else if (std.mem.eql(u8, field.name, "name")) {
            if (event.name) |n| {
                const escaped = try escapeJsonString(ctx.allocator, n);
                defer ctx.allocator.free(escaped);
                try writer.print("\"{s}\":\"{s}\"", .{ output_key, escaped });
            } else {
                try writer.print("\"{s}\":null", .{output_key});
            }
            first = false;
        } else if (std.mem.eql(u8, field.name, "namehash")) {
            if (event.namehash) |nh| {
                const hash_hex = try nh.toHex(ctx.allocator);
                defer ctx.allocator.free(hash_hex);
                try writer.print("\"{s}\":\"{s}\"", .{ output_key, hash_hex });
            } else {
                try writer.print("\"{s}\":null", .{output_key});
            }
            first = false;
        } else if (std.mem.eql(u8, field.name, "domain")) {
            // Nested Domain object
            if (event.namehash) |nh| {
                const domain_opt = try ctx.database.getNameByNamehash(nh);
                if (domain_opt) |domain| {
                    var domain_mut = domain;
                    defer domain_mut.deinit(ctx.allocator);
                    try writer.print("\"{s}\":", .{output_key});
                    const domain_json = try buildDomainJson(&domain_mut, field.selections, .{
                        .database = ctx.database,
                        .depth = ctx.depth + 1,
                        .allocator = ctx.allocator,
                        .loaders = ctx.loaders,
                    });
                    defer ctx.allocator.free(domain_json);
                    try writer.writeAll(domain_json);
                    first = false;
                } else {
                    try writer.print("\"{s}\":null", .{output_key});
                    first = false;
                }
            } else {
                try writer.print("\"{s}\":null", .{output_key});
                first = false;
            }
        } else if (std.mem.eql(u8, field.name, "chain")) {
            try writer.print("\"{s}\":\"{s}\"", .{ output_key, event.chain.toString() });
            first = false;
        } else if (std.mem.eql(u8, field.name, "__typename")) {
            // Handle GraphQL introspection field
            try writer.print("\"{s}\":\"Event\"", .{output_key});
            first = false;
        } else {
            // Unknown field - return null per GraphQL spec
            try writer.print("\"{s}\":null", .{output_key});
            first = false;
        }
    }

    try writer.writeAll("}");
    return try ctx.allocator.dupe(u8, json.items);
}

/// Generic field handler callback type
const FieldHandler = struct {
    /// Called for each requested field, should append JSON value to writer
    /// Returns true if field was handled, false if field is unknown
    /// output_key: the alias if provided, otherwise field_name (use this for JSON keys)
    /// field_name: the actual field name (use this for field matching logic)
    handleFn: *const fn (ctx: *anyopaque, output_key: []const u8, field_name: []const u8, writer: std.ArrayList(u8).Writer, allocator: std.mem.Allocator) anyerror!bool,
    context: *anyopaque,
};

/// Generic helper to build JSON object based on field selections
fn buildJsonWithFields(
    allocator: std.mem.Allocator,
    selections: []const parser.Field,
    handler: FieldHandler,
) ![]u8 {
    var json: std.ArrayList(u8) = .{};
    defer json.deinit(allocator);

    try json.appendSlice(allocator, "{");

    var first = true;
    for (selections) |*field| {
        // Use alias if provided, otherwise use field name (GraphQL spec compliance)
        const output_key = field.alias orelse field.name;

        // Create a temporary buffer for this field
        var field_json: std.ArrayList(u8) = .{};
        defer field_json.deinit(allocator);

        // Try to handle the field in the temporary buffer
        const handled = try handler.handleFn(handler.context, output_key, field.name, field_json.writer(allocator), allocator);
        if (handled) {
            if (!first) {
                try json.appendSlice(allocator, ",");
            }
            try json.appendSlice(allocator, field_json.items);
            first = false;
        }
    }

    try json.appendSlice(allocator, "}");
    return try allocator.dupe(u8, json.items);
}

/// Name field handler
fn handleNameField(ctx: *anyopaque, output_key: []const u8, field_name: []const u8, writer: std.ArrayList(u8).Writer, allocator: std.mem.Allocator) !bool {
    const name: *const models.Name = @ptrCast(@alignCast(ctx));

    if (std.mem.eql(u8, field_name, "id") or std.mem.eql(u8, field_name, "name")) {
        const escaped = try escapeJsonString(allocator, name.name);
        defer allocator.free(escaped);
        try writer.print("\"{s}\":\"{s}\"", .{ output_key, escaped });
        return true;
    } else if (std.mem.eql(u8, field_name, "owner")) {
        const owner_hex = try name.owner.toHex(allocator);
        defer allocator.free(owner_hex);
        try writer.print("\"{s}\":{{\"id\":\"{s}\"}}", .{ output_key, owner_hex });
        return true;
    } else if (std.mem.eql(u8, field_name, "resolver")) {
        const resolver_hex = try name.resolver.toHex(allocator);
        defer allocator.free(resolver_hex);
        if (!name.resolver.isZero()) {
            try writer.print("\"{s}\":{{\"address\":\"{s}\"}}", .{ output_key, resolver_hex });
        } else {
            try writer.print("\"{s}\":null", .{output_key});
        }
        return true;
    } else if (std.mem.eql(u8, field_name, "labelName")) {
        const escaped = try escapeJsonString(allocator, name.label);
        defer allocator.free(escaped);
        try writer.print("\"{s}\":\"{s}\"", .{ output_key, escaped });
        return true;
    } else if (std.mem.eql(u8, field_name, "labelhash")) {
        const hash_hex = try name.label_hash.toHex(allocator);
        defer allocator.free(hash_hex);
        try writer.print("\"{s}\":\"{s}\"", .{ output_key, hash_hex });
        return true;
    } else if (std.mem.eql(u8, field_name, "expiryDate")) {
        if (hasValidExpiry(name.expiry)) {
            try writer.print("\"{s}\":{d}", .{ output_key, name.expiry });
        } else {
            try writer.print("\"{s}\":null", .{output_key});
        }
        return true;
    }
    return false;
}

/// Event field handler
fn handleEventField(ctx: *anyopaque, output_key: []const u8, field_name: []const u8, writer: std.ArrayList(u8).Writer, allocator: std.mem.Allocator) !bool {
    const event: *const models.Event = @ptrCast(@alignCast(ctx));

    if (std.mem.eql(u8, field_name, "id")) {
        const tx_hash = try event.tx_hash.toHex(allocator);
        defer allocator.free(tx_hash);
        try writer.print("\"{s}\":\"{s}-{d}\"", .{ output_key, tx_hash, event.log_index });
        return true;
    } else if (std.mem.eql(u8, field_name, "type")) {
        try writer.print("\"{s}\":\"{s}\"", .{ output_key, event.event_type.toString() });
        return true;
    } else if (std.mem.eql(u8, field_name, "blockNumber")) {
        try writer.print("\"{s}\":{d}", .{ output_key, event.block_number });
        return true;
    } else if (std.mem.eql(u8, field_name, "transactionHash")) {
        const tx_hash = try event.tx_hash.toHex(allocator);
        defer allocator.free(tx_hash);
        try writer.print("\"{s}\":\"{s}\"", .{ output_key, tx_hash });
        return true;
    } else if (std.mem.eql(u8, field_name, "timestamp")) {
        try writer.print("\"{s}\":{d}", .{ output_key, event.timestamp });
        return true;
    } else if (std.mem.eql(u8, field_name, "name")) {
        if (event.name) |n| {
            const escaped = try escapeJsonString(allocator, n);
            defer allocator.free(escaped);
            try writer.print("\"{s}\":\"{s}\"", .{ output_key, escaped });
        } else {
            try writer.print("\"{s}\":null", .{output_key});
        }
        return true;
    } else if (std.mem.eql(u8, field_name, "namehash")) {
        if (event.namehash) |nh| {
            const hash_hex = try nh.toHex(allocator);
            defer allocator.free(hash_hex);
            try writer.print("\"{s}\":\"{s}\"", .{ output_key, hash_hex });
        } else {
            try writer.print("\"{s}\":null", .{output_key});
        }
        return true;
    } else if (std.mem.eql(u8, field_name, "contractAddress")) {
        const addr_hex = try event.contract_address.toHex(allocator);
        defer allocator.free(addr_hex);
        try writer.print("\"{s}\":\"{s}\"", .{ output_key, addr_hex });
        return true;
    }
    return false;
}

/// Registration field handler
fn handleRegistrationField(ctx: *anyopaque, output_key: []const u8, field_name: []const u8, writer: std.ArrayList(u8).Writer, allocator: std.mem.Allocator) !bool {
    const event: *const models.Event = @ptrCast(@alignCast(ctx));

    if (std.mem.eql(u8, field_name, "name") or std.mem.eql(u8, field_name, "id")) {
        if (event.name) |n| {
            const escaped = try escapeJsonString(allocator, n);
            defer allocator.free(escaped);
            try writer.print("\"{s}\":\"{s}\"", .{ output_key, escaped });
        } else {
            try writer.print("\"{s}\":null", .{output_key});
        }
        return true;
    } else if (std.mem.eql(u8, field_name, "block") or std.mem.eql(u8, field_name, "blockNumber")) {
        try writer.print("\"{s}\":{d}", .{ output_key, event.block_number });
        return true;
    } else if (std.mem.eql(u8, field_name, "timestamp")) {
        try writer.print("\"{s}\":{d}", .{ output_key, event.timestamp });
        return true;
    }
    return false;
}

/// EAC Role Assignment field handler
fn handleEACRoleField(ctx: *anyopaque, output_key: []const u8, field_name: []const u8, writer: std.ArrayList(u8).Writer, allocator: std.mem.Allocator) !bool {
    const role: *const models.EACRoleAssignment = @ptrCast(@alignCast(ctx));

    if (std.mem.eql(u8, field_name, "id")) {
        try writer.print("\"{s}\":\"{d}\"", .{ output_key, role.id });
        return true;
    } else if (std.mem.eql(u8, field_name, "resource")) {
        const escaped = try escapeJsonString(allocator, role.resource);
        defer allocator.free(escaped);
        try writer.print("\"{s}\":\"{s}\"", .{ output_key, escaped });
        return true;
    } else if (std.mem.eql(u8, field_name, "account")) {
        const account_hex = try role.account.toHex(allocator);
        defer allocator.free(account_hex);
        try writer.print("\"{s}\":\"{s}\"", .{ output_key, account_hex });
        return true;
    } else if (std.mem.eql(u8, field_name, "roleBitmap")) {
        const escaped = try escapeJsonString(allocator, role.role_bitmap);
        defer allocator.free(escaped);
        try writer.print("\"{s}\":\"{s}\"", .{ output_key, escaped });
        return true;
    } else if (std.mem.eql(u8, field_name, "blockNumber")) {
        try writer.print("\"{s}\":{d}", .{ output_key, role.block_number });
        return true;
    } else if (std.mem.eql(u8, field_name, "transactionHash")) {
        const tx_hex = try role.tx_hash.toHex(allocator);
        defer allocator.free(tx_hex);
        try writer.print("\"{s}\":\"{s}\"", .{ output_key, tx_hex });
        return true;
    } else if (std.mem.eql(u8, field_name, "timestamp")) {
        try writer.print("\"{s}\":{d}", .{ output_key, role.timestamp });
        return true;
    }
    return false;
}

/// Resolver field handler
fn handleResolverField(ctx: *anyopaque, output_key: []const u8, field_name: []const u8, writer: std.ArrayList(u8).Writer, allocator: std.mem.Allocator) !bool {
    const resolver: *const models.Resolver = @ptrCast(@alignCast(ctx));

    if (std.mem.eql(u8, field_name, "address")) {
        const addr_hex = try resolver.address.toHex(allocator);
        defer allocator.free(addr_hex);
        try writer.print("\"{s}\":\"{s}\"", .{ output_key, addr_hex });
        return true;
    } else if (std.mem.eql(u8, field_name, "name")) {
        const escaped = try escapeJsonString(allocator, resolver.name);
        defer allocator.free(escaped);
        try writer.print("\"{s}\":\"{s}\"", .{ output_key, escaped });
        return true;
    } else if (std.mem.eql(u8, field_name, "namehash")) {
        const hash_hex = try resolver.namehash.toHex(allocator);
        defer allocator.free(hash_hex);
        try writer.print("\"{s}\":\"{s}\"", .{ output_key, hash_hex });
        return true;
    } else if (std.mem.eql(u8, field_name, "setBlock")) {
        try writer.print("\"{s}\":{d}", .{ output_key, resolver.set_block });
        return true;
    } else if (std.mem.eql(u8, field_name, "setAt")) {
        try writer.print("\"{s}\":{d}", .{ output_key, resolver.set_at });
        return true;
    }
    return false;
}

/// Registry field handler
fn handleRegistryField(ctx: *anyopaque, output_key: []const u8, field_name: []const u8, writer: std.ArrayList(u8).Writer, allocator: std.mem.Allocator) !bool {
    const registry: *const models.Registry = @ptrCast(@alignCast(ctx));

    if (std.mem.eql(u8, field_name, "address")) {
        const addr_hex = try registry.address.toHex(allocator);
        defer allocator.free(addr_hex);
        try writer.print("\"{s}\":\"{s}\"", .{ output_key, addr_hex });
        return true;
    } else if (std.mem.eql(u8, field_name, "name")) {
        const escaped = try escapeJsonString(allocator, registry.name);
        defer allocator.free(escaped);
        try writer.print("\"{s}\":\"{s}\"", .{ output_key, escaped });
        return true;
    } else if (std.mem.eql(u8, field_name, "namehash")) {
        const hash_hex = try registry.namehash.toHex(allocator);
        defer allocator.free(hash_hex);
        try writer.print("\"{s}\":\"{s}\"", .{ output_key, hash_hex });
        return true;
    } else if (std.mem.eql(u8, field_name, "parentRegistry")) {
        const parent_hex = try registry.parent_registry.toHex(allocator);
        defer allocator.free(parent_hex);
        try writer.print("\"{s}\":\"{s}\"", .{ output_key, parent_hex });
        return true;
    } else if (std.mem.eql(u8, field_name, "createdBlock")) {
        try writer.print("\"{s}\":{d}", .{ output_key, registry.created_block });
        return true;
    } else if (std.mem.eql(u8, field_name, "createdAt")) {
        try writer.print("\"{s}\":{d}", .{ output_key, registry.created_at });
        return true;
    }
    return false;
}

/// Resolver Metadata field handler
fn handleResolverMetadataField(ctx: *anyopaque, output_key: []const u8, field_name: []const u8, writer: std.ArrayList(u8).Writer, allocator: std.mem.Allocator) !bool {
    const metadata: *const models.ResolverMetadata = @ptrCast(@alignCast(ctx));

    if (std.mem.eql(u8, field_name, "id")) {
        try writer.print("\"{s}\":\"{d}\"", .{ output_key, metadata.id });
        return true;
    } else if (std.mem.eql(u8, field_name, "resolver")) {
        const resolver_hex = try metadata.resolver.toHex(allocator);
        defer allocator.free(resolver_hex);
        try writer.print("\"{s}\":\"{s}\"", .{ output_key, resolver_hex });
        return true;
    } else if (std.mem.eql(u8, field_name, "graphqlUrl")) {
        const escaped = try escapeJsonString(allocator, metadata.graphql_url);
        defer allocator.free(escaped);
        try writer.print("\"{s}\":\"{s}\"", .{ output_key, escaped });
        return true;
    } else if (std.mem.eql(u8, field_name, "blockNumber")) {
        try writer.print("\"{s}\":{d}", .{ output_key, metadata.block_number });
        return true;
    } else if (std.mem.eql(u8, field_name, "transactionHash")) {
        const tx_hex = try metadata.tx_hash.toHex(allocator);
        defer allocator.free(tx_hex);
        try writer.print("\"{s}\":\"{s}\"", .{ output_key, tx_hex });
        return true;
    } else if (std.mem.eql(u8, field_name, "timestamp")) {
        try writer.print("\"{s}\":{d}", .{ output_key, metadata.timestamp });
        return true;
    }
    return false;
}

/// Resolver Approval field handler
fn handleResolverApprovalField(ctx: *anyopaque, output_key: []const u8, field_name: []const u8, writer: std.ArrayList(u8).Writer, allocator: std.mem.Allocator) !bool {
    const approval: *const models.ResolverApproval = @ptrCast(@alignCast(ctx));

    if (std.mem.eql(u8, field_name, "id")) {
        try writer.print("\"{s}\":\"{d}\"", .{ output_key, approval.id });
        return true;
    } else if (std.mem.eql(u8, field_name, "resolver")) {
        const resolver_hex = try approval.resolver.toHex(allocator);
        defer allocator.free(resolver_hex);
        try writer.print("\"{s}\":\"{s}\"", .{ output_key, resolver_hex });
        return true;
    } else if (std.mem.eql(u8, field_name, "namehash")) {
        const hash_hex = try approval.namehash.toHex(allocator);
        defer allocator.free(hash_hex);
        try writer.print("\"{s}\":\"{s}\"", .{ output_key, hash_hex });
        return true;
    } else if (std.mem.eql(u8, field_name, "context")) {
        if (approval.context) |ctx_str| {
            const escaped = try escapeJsonString(allocator, ctx_str);
            defer allocator.free(escaped);
            try writer.print("\"{s}\":\"{s}\"", .{ output_key, escaped });
        } else {
            try writer.print("\"{s}\":null", .{output_key});
        }
        return true;
    } else if (std.mem.eql(u8, field_name, "delegate")) {
        const delegate_hex = try approval.delegate.toHex(allocator);
        defer allocator.free(delegate_hex);
        try writer.print("\"{s}\":\"{s}\"", .{ output_key, delegate_hex });
        return true;
    } else if (std.mem.eql(u8, field_name, "approved")) {
        try writer.print("\"{s}\":{s}", .{ output_key, if (approval.approved) "true" else "false" });
        return true;
    } else if (std.mem.eql(u8, field_name, "blockNumber")) {
        try writer.print("\"{s}\":{d}", .{ output_key, approval.block_number });
        return true;
    } else if (std.mem.eql(u8, field_name, "transactionHash")) {
        const tx_hex = try approval.tx_hash.toHex(allocator);
        defer allocator.free(tx_hex);
        try writer.print("\"{s}\":\"{s}\"", .{ output_key, tx_hex });
        return true;
    } else if (std.mem.eql(u8, field_name, "logIndex")) {
        try writer.print("\"{s}\":{d}", .{ output_key, approval.log_index });
        return true;
    } else if (std.mem.eql(u8, field_name, "timestamp")) {
        try writer.print("\"{s}\":{d}", .{ output_key, approval.timestamp });
        return true;
    }
    return false;
}

// Note: GraphQL integration tests have been moved to:
// - src/api/graphql_test.zig (parser tests)
// - src/api/graphql_features_test.zig (feature tests)
// These test files use the proper parser-based executor via handleQuery()
