const std = @import("std");
const db = @import("../storage/database.zig");
const models = @import("../types/models.zig");
const Hash = @import("../types/hash.zig").Hash;
const Address = @import("../types/address.zig").Address;
const namehash = @import("../types/hash.zig").namehash;
const json_utils = @import("../utils/json.zig");
const ens_normalize = @import("ens_normalize");

// Import generic GraphQL library
const parser = @import("../lib/graphql/parser.zig");
const complexity = @import("../lib/graphql/complexity.zig");
const metrics_mod = @import("../lib/graphql/metrics.zig");
const pagination = @import("../lib/graphql/pagination.zig");

// Import ENS-specific field definitions, JSON builder, entity builders, and resolvers
const fields = @import("ens_fields.zig");
const json_builder = @import("json_builder.zig");
const builders = @import("builders/builders.zig");
const resolvers = @import("resolvers/resolvers.zig");

/// Maximum query depth to prevent DoS attacks
const MAX_QUERY_DEPTH: u32 = 10;

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
        try executor.registerResolver("resolvers", resolvers.resolveResolvers);
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

        // Create request-scoped DataLoader context for batching and caching
        const dataloader_mod = @import("loaders.zig");
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

            const data_str = if (event.data) |d|
                try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{d})
            else
                try self.allocator.dupe(u8, "null");
            defer self.allocator.free(data_str);

            const chain_str = event.chain.toString();

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
        if (builders.hasValidExpiry(domain.expiry)) {
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
        var field_map = std.StringHashMap(bool).init(self.allocator);

        // Find the field name in the query (e.g., "domains")
        const field_pos = std.mem.indexOf(u8, query, field_name) orelse return field_map;

        // Find the opening brace of the selection set after the field name
        const search_start = field_pos + field_name.len;
        const start_idx = std.mem.indexOfPos(u8, query, search_start, "{") orelse return field_map;

        // Find the matching closing brace
        var depth: i32 = 1;
        var end_idx = start_idx + 1;
        while (end_idx < query.len and depth > 0) {
            if (query[end_idx] == '{') depth += 1;
            if (query[end_idx] == '}') depth -= 1;
            end_idx += 1;
        }

        if (depth != 0) return field_map; // Mismatched braces

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
                    try field_map.put(extracted_field, true);
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
                            try field_map.put(dotted_field, true);
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

        return field_map;
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
                // Note: Values are owned by the DataLoader cache and will be freed
                // when LoaderContext.deinit() runs. Don't free them here to avoid double-free.
                map.deinit();
            }
        }

        var text_records_map: ?std.AutoHashMap([32]u8, @import("loaders.zig").TextRecords) = null;
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
            const dataloader_mod = @import("loaders.zig");
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
                if (builders.hasValidExpiry(item.expiry)) {
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
