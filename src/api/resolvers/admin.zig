/// Admin-related GraphQL resolvers
/// - resolveRoles: List EAC role assignments
/// - resolveRolesConnection: Cursor-based pagination for role assignments
/// - resolveResolvers: List resolvers
/// - resolveRegistries: List registries
/// - resolveMetadata: List resolver metadata
/// - resolveApprovals: List resolver approvals
const std = @import("std");
const common = @import("common.zig");
const db = common.db;
const models = common.models;
const Address = common.Address;
const Hash = common.Hash;
const parser = common.parser;
const pagination = common.pagination;
const builders = @import("../builders/builders.zig");
const json_utils = common.json_utils;
const domain_resolvers = @import("domain.zig");

/// Parse protocol argument from field (defaults to v2).
/// Surfaces invalid protocol values as `error.InvalidProtocol` rather than silently
/// falling back to v2 — a typo would otherwise mask the user's intended filter.
fn parseProtocolArg(field: *const parser.Field) !models.Protocol {
    const protocol_str = parser.getStringArg(field, "protocol", null) orelse return .v2;
    if (std.mem.eql(u8, protocol_str, models.Protocol.v1.toString())) return .v1;
    if (std.mem.eql(u8, protocol_str, models.Protocol.v2.toString())) return .v2;
    return error.InvalidProtocol;
}

pub fn resolveRoles(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const allocator = ctx.allocator;
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));

    // Get protocol argument (default: l2)
    const protocol = try parseProtocolArg(field);

    // Get optional arguments
    const resource_arg = parser.getStringArg(field, "resource", null);
    const account_arg = parser.getStringArg(field, "account", null);

    // Determine which database method to call based on arguments
    const roles = if (resource_arg) |resource|
        try database.getRolesByResource(protocol, resource)
    else if (account_arg) |account_str| blk: {
        const account_addr = Address.fromHex(account_str) catch return error.InvalidAddress;
        break :blk try database.getRolesByAccount(protocol, account_addr);
    } else try allocator.alloc(models.EACRoleAssignment, 0); // Requires resource or account filter

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
            .context = @ptrCast(@constCast(role)),
        };
        const role_json = try buildJsonWithFields(allocator, field.selections, handler);
        defer allocator.free(role_json);
        try json.appendSlice(allocator, role_json);
    }

    try json.appendSlice(allocator, "]");
    return parser.FieldResult{ .json = try allocator.dupe(u8, json.items) };
}

/// Resolver for roleConnection query (cursor-based pagination)
pub fn resolveRolesConnection(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const allocator = ctx.allocator;
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));

    // Get protocol argument (default: l2)
    const protocol = try parseProtocolArg(field);

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

    // Get optional filter arguments
    const resource_arg = parser.getStringArg(field, "resource", null);
    const account_arg = parser.getStringArg(field, "account", null);

    // Parse account address if provided.
    // Surface invalid input as an error rather than silently dropping the filter —
    // otherwise a typo expands the result set to ALL roles, masquerading as real data.
    var account_addr: ?Address = null;
    if (account_arg) |account_str| {
        account_addr = Address.fromHex(account_str) catch return error.InvalidAddress;
    }

    // Decode cursor if present — fail loud on malformed cursor instead of silently
    // restarting from the first page.
    var cursor_id: ?i64 = null;
    if (params.cursor) |cursor| {
        cursor_id = try pagination.CursorCodec.decodeInt(allocator, cursor);
    }

    // Check which top-level fields are requested (for totalCount-only fast path)
    var wants_edges = false;
    var wants_page_info = false;
    var wants_total_count = false;
    for (field.selections) |*sel| {
        if (std.mem.eql(u8, sel.name, "edges")) wants_edges = true;
        if (std.mem.eql(u8, sel.name, "pageInfo")) wants_page_info = true;
        if (std.mem.eql(u8, sel.name, "totalCount")) wants_total_count = true;
    }

    // Fast path: only totalCount requested — skip row fetching entirely
    if (wants_total_count and !wants_edges and !wants_page_info) {
        const count = try database.getTotalRoleCount(protocol, resource_arg, account_addr);
        const result = try std.fmt.allocPrint(allocator, "{{\"totalCount\":{d}}}", .{count});
        return parser.FieldResult{ .json = result };
    }

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
    const fetch_limit: u32 = @intCast(params.limit + 1);

    const roles = try database.getRolesWithPagination(protocol, .{
        .resource = resource_arg,
        .account = account_addr,
        .limit = fetch_limit,
        .cursor_id = cursor_id,
        .direction = if (params.direction == .backward) .backward else .forward,
    });
    defer {
        for (roles) |*role| {
            @constCast(role).deinit(allocator);
        }
        allocator.free(roles);
    }

    // Determine actual items to return
    const actual_items = @min(roles.len, params.limit);
    const has_more = roles.len > params.limit;

    // For backward pagination, reverse the results to maintain proper edge order
    if (params.direction == .backward and actual_items > 1) {
        std.mem.reverse(models.EACRoleAssignment, @constCast(roles[0..actual_items]));
    }

    const items_slice = roles[0..actual_items];

    // Only compute total count when requested (reuse wants_total_count from earlier scan)
    const total_count: ?usize = if (wants_total_count)
        try database.getTotalRoleCount(protocol, resource_arg, account_addr)
    else
        null;

    // Build JSON
    var json: std.ArrayList(u8) = .{};
    defer json.deinit(allocator);

    try json.appendSlice(allocator, "{\"pageInfo\":{");
    try json.appendSlice(allocator, "\"hasNextPage\":");
    try json.appendSlice(allocator, if (params.direction == .forward and has_more) "true" else "false");
    try json.appendSlice(allocator, ",\"hasPreviousPage\":");
    try json.appendSlice(allocator, if (params.direction == .backward and has_more) "true" else if (params.cursor != null) "true" else "false");

    if (items_slice.len > 0) {
        const start_cursor = try pagination.CursorCodec.encodeInt(allocator, @intCast(items_slice[0].id));
        defer allocator.free(start_cursor);
        try json.appendSlice(allocator, ",\"startCursor\":\"");
        try json.appendSlice(allocator, start_cursor);
        try json.appendSlice(allocator, "\"");

        const end_cursor = try pagination.CursorCodec.encodeInt(allocator, @intCast(items_slice[items_slice.len - 1].id));
        defer allocator.free(end_cursor);
        try json.appendSlice(allocator, ",\"endCursor\":\"");
        try json.appendSlice(allocator, end_cursor);
        try json.appendSlice(allocator, "\"");
    } else {
        try json.appendSlice(allocator, ",\"startCursor\":null");
        try json.appendSlice(allocator, ",\"endCursor\":null");
    }

    try json.appendSlice(allocator, "},\"edges\":[");

    // Build edges
    for (items_slice, 0..) |*role, i| {
        if (i > 0) try json.appendSlice(allocator, ",");

        const cursor = try pagination.CursorCodec.encodeInt(allocator, @intCast(role.id));
        defer allocator.free(cursor);

        try json.appendSlice(allocator, "{\"cursor\":\"");
        try json.appendSlice(allocator, cursor);
        try json.appendSlice(allocator, "\",\"node\":");

        // Build role JSON using the existing field handler
        const handler = FieldHandler{
            .handleFn = handleEACRoleField,
            .context = @ptrCast(@constCast(role)),
        };
        const role_json = try buildJsonWithFields(allocator, node_selections, handler);
        defer allocator.free(role_json);
        try json.appendSlice(allocator, role_json);

        try json.appendSlice(allocator, "}");
    }

    try json.appendSlice(allocator, "]");

    if (total_count) |count| {
        try json.appendSlice(allocator, ",\"totalCount\":");
        const count_str = try std.fmt.allocPrint(allocator, "{d}", .{count});
        defer allocator.free(count_str);
        try json.appendSlice(allocator, count_str);
    }

    try json.appendSlice(allocator, "}");

    return parser.FieldResult{ .json = try allocator.dupe(u8, json.items) };
}

fn mapResolverEntityOrderBy(order_by: ?[]const u8) db.ResolverEntitySortField {
    if (order_by) |s| {
        if (std.mem.eql(u8, s, "setBlock")) return .set_block;
    }
    return .address;
}

/// Resolver for the new subgraph-style `resolvers(first, skip, where, orderBy)`
/// list query. Reads from the `resolvers` table (one row per (protocol, address,
/// namehash) binding). IDs are emitted as `{protocol}-{address}-{namehash}` via
/// the standard `buildResolverJson` builder, which now takes a protocol arg.
pub fn resolveResolverEntities(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));
    const allocator = ctx.allocator;

    const page = try common.parsePagination(field, 100);
    const first = page.first;
    const skip = page.skip;

    var filter_address: ?[]const u8 = null;
    var filter_address_in: ?[][]const u8 = null;
    var filter_namehash: ?[]const u8 = null;
    var filter_protocol: ?[]const u8 = null;

    if (common.getObjectArg(field, "where")) |where_args| {
        for (where_args) |a| {
            if (std.mem.eql(u8, a.name, "address_in")) {
                if (try common.parseStringListArg(a, allocator)) |v| filter_address_in = v;
                continue;
            }
            // Unknown args caught at parse time by schema_validator.zig.
            _ = common.matchStringArg(a, "address", &filter_address) or
                common.matchStringArg(a, "namehash", &filter_namehash) or
                common.matchStringArg(a, "protocol", &filter_protocol);
        }
    }
    defer if (filter_address_in) |a| allocator.free(a);

    const order_by = parser.getStringArg(field, "orderBy", null);
    const sort_field = mapResolverEntityOrderBy(order_by);
    const order_dir = common.parseOrderDirection(field, db.OrderDir, .asc);

    const filters = db.ResolverEntityFilters{
        .address = filter_address,
        .address_in = filter_address_in,
        .namehash = filter_namehash,
        .protocol = filter_protocol,
    };

    const entities = try database.getFilteredResolverEntities(filters, @intCast(skip), first, order_dir, sort_field);
    defer {
        for (entities) |*e| {
            var m = e.*;
            m.deinit(allocator);
        }
        allocator.free(entities);
    }

    var json: std.ArrayList(u8) = .{};
    defer json.deinit(allocator);
    try json.appendSlice(allocator, "[");
    for (entities, 0..) |row, i| {
        if (i > 0) try json.appendSlice(allocator, ",");
        const resolver_addr = Address.fromHex(row.address) catch continue;
        const namehash_val = Hash.fromHex(row.namehash) catch continue;
        const protocol_val: models.Protocol = if (std.mem.eql(u8, row.protocol, "v2")) .v2 else .v1;
        const entity_json = try builders.buildResolverJson(
            resolver_addr,
            namehash_val,
            protocol_val,
            field.selections,
            .{
                .database = database,
                .depth = 0,
                .allocator = allocator,
                .loaders = ctx.loaders,
            },
        );
        defer allocator.free(entity_json);
        try json.appendSlice(allocator, entity_json);
    }
    try json.appendSlice(allocator, "]");
    return parser.FieldResult{ .json = try allocator.dupe(u8, json.items) };
}

/// Resolver for resolvers query
pub fn resolveResolvers(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const allocator = ctx.allocator;
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));

    // Get protocol argument (default: l2)
    const protocol = try parseProtocolArg(field);

    // Get required account argument
    const account_arg = parser.getStringArg(field, "account", null) orelse {
        const json = try allocator.dupe(u8, "[]");
        return parser.FieldResult{ .json = json };
    };

    const account_addr = Address.fromHex(account_arg) catch return error.InvalidAddress;

    const resolvers = try database.getResolversByOwner(protocol, account_addr);
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
        const resolver_json = try buildResolverJson(resolver.address, field.selections, database, allocator, ctx.loaders);
        defer allocator.free(resolver_json);
        try json.appendSlice(allocator, resolver_json);
    }

    try json.appendSlice(allocator, "]");
    return parser.FieldResult{ .json = try allocator.dupe(u8, json.items) };
}

/// Resolver for registries query
pub fn resolveRegistries(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const allocator = ctx.allocator;
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));

    // Get protocol argument (default: l2)
    const protocol = try parseProtocolArg(field);

    // Get required owner argument
    const owner_arg = parser.getStringArg(field, "owner", null) orelse {
        const json = try allocator.dupe(u8, "[]");
        return parser.FieldResult{ .json = json };
    };

    const owner_addr = Address.fromHex(owner_arg) catch return error.InvalidAddress;

    const registries = try database.getRegistriesByOwner(protocol, owner_addr);
    defer {
        for (registries) |*registry| {
            registry.deinit(allocator);
        }
        allocator.free(registries);
    }

    var json: std.ArrayList(u8) = .{};
    defer json.deinit(allocator);
    try json.appendSlice(allocator, "[");

    for (registries, 0..) |*registry, i| {
        if (i > 0) try json.appendSlice(allocator, ",");
        const registry_json = try buildRegistryInfoJson(allocator, database, registry, field.selections, ctx);
        defer allocator.free(registry_json);
        try json.appendSlice(allocator, registry_json);
    }

    try json.appendSlice(allocator, "]");
    return parser.FieldResult{ .json = try allocator.dupe(u8, json.items) };
}

/// Resolver for the single-registry lookup. Mirrors `domain(id:)` for use as
/// the Registry-view page's entry point.
pub fn resolveRegistry(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const allocator = ctx.allocator;
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));

    const protocol = try parseProtocolArg(field);

    const address_arg = parser.getStringArg(field, "address", null) orelse {
        return parser.FieldResult{ .json = try allocator.dupe(u8, "null") };
    };
    const address = Address.fromHex(address_arg) catch return error.InvalidAddress;

    const registry_opt = try database.getRegistry(protocol, address);
    if (registry_opt == null) {
        return parser.FieldResult{ .json = try allocator.dupe(u8, "null") };
    }
    var registry = registry_opt.?;
    defer registry.deinit(allocator);

    const json = try buildRegistryInfoJson(allocator, database, &registry, field.selections, ctx);
    return parser.FieldResult{ .json = json };
}

/// Resolver for metadata query
pub fn resolveMetadata(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const allocator = ctx.allocator;
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));

    // Get protocol argument (default: l2)
    const protocol = try parseProtocolArg(field);

    // Get required resolver argument
    const resolver_arg = parser.getStringArg(field, "resolver", null) orelse {
        const json = try allocator.dupe(u8, "null");
        return parser.FieldResult{ .json = json };
    };

    const resolver_addr = Address.fromHex(resolver_arg) catch return error.InvalidAddress;

    const metadata_opt = try database.getResolverMetadata(protocol, resolver_addr);
    if (metadata_opt) |metadata| {
        var metadata_mut = metadata;
        defer metadata_mut.deinit(allocator);

        const handler = FieldHandler{
            .handleFn = handleResolverMetadataField,
            .context = @ptrCast(@constCast(&metadata_mut)),
        };
        const json = try buildJsonWithFields(allocator, field.selections, handler);
        return parser.FieldResult{ .json = json };
    } else {
        const json = try allocator.dupe(u8, "null");
        return parser.FieldResult{ .json = json };
    }
}

/// Resolver for approvals query
pub fn resolveApprovals(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const allocator = ctx.allocator;
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));

    // Get protocol argument (default: l2)
    const protocol = try parseProtocolArg(field);

    // Get optional arguments
    const namehash_arg = parser.getStringArg(field, "namehash", null);
    const delegate_arg = parser.getStringArg(field, "delegate", null);

    // Determine which database method to call based on arguments
    const approvals = if (namehash_arg) |namehash_str| blk: {
        const namehash_hash = Hash.fromHex(namehash_str) catch return error.InvalidNamehash;
        break :blk try database.getApprovalsForName(protocol, namehash_hash, null);
    } else if (delegate_arg) |delegate_str| blk: {
        const delegate_addr = Address.fromHex(delegate_str) catch return error.InvalidAddress;
        break :blk try database.getApprovalsForDelegate(protocol, delegate_addr);
    } else try allocator.alloc(models.ResolverApproval, 0); // No arguments, return empty

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
            .context = @ptrCast(@constCast(approval)),
        };
        const approval_json = try buildJsonWithFields(allocator, field.selections, handler);
        defer allocator.free(approval_json);
        try json.appendSlice(allocator, approval_json);
    }

    try json.appendSlice(allocator, "]");
    return parser.FieldResult{ .json = try allocator.dupe(u8, json.items) };
}

/// Resolver for resolverDetail query - provides detailed resolver info with statistics
pub fn resolveResolver(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const allocator = ctx.allocator;

    // Get required id argument (resolver contract address)
    const id_arg = parser.getStringArg(field, "id", null) orelse {
        const json = try allocator.dupe(u8, "null");
        return parser.FieldResult{ .json = json };
    };

    const resolver_addr = Address.fromHex(id_arg) catch return error.InvalidAddress;

    const database: *db.Database = @ptrCast(@alignCast(ctx.database));
    const json = try buildResolverJson(resolver_addr, field.selections, database, allocator, ctx.loaders);
    return parser.FieldResult{ .json = json };
}

// ============================================================================
// Supporting Types and Functions for Resolvers
// ============================================================================

/// Shared builder for a single resolver's JSON. Used by both resolver(id) and resolvers(account).
fn buildResolverJson(
    resolver_addr: Address,
    selections: []const parser.Field,
    database: *db.Database,
    allocator: std.mem.Allocator,
    loaders: ?*anyopaque,
) ![]u8 {
    var json: std.ArrayList(u8) = .{};
    defer json.deinit(allocator);
    try json.appendSlice(allocator, "{");

    var first = true;
    for (selections) |*sel| {
        const output_key = sel.alias orelse sel.name;

        if (!first) try json.appendSlice(allocator, ",");

        if (std.mem.eql(u8, sel.name, "id") or std.mem.eql(u8, sel.name, "address")) {
            const addr_hex = try resolver_addr.toHex(allocator);
            defer allocator.free(addr_hex);
            try json.appendSlice(allocator, "\"");
            try json.appendSlice(allocator, output_key);
            try json.appendSlice(allocator, "\":\"");
            try json.appendSlice(allocator, addr_hex);
            try json.appendSlice(allocator, "\"");
            first = false;
        } else if (std.mem.eql(u8, sel.name, "nodeCount")) {
            const count = try database.getResolverNodeCount(resolver_addr);
            const count_str = try std.fmt.allocPrint(allocator, "\"{s}\":{d}", .{ output_key, count });
            defer allocator.free(count_str);
            try json.appendSlice(allocator, count_str);
            first = false;
        } else if (std.mem.eql(u8, sel.name, "aliasCount")) {
            const count = try database.getResolverAliasCount(resolver_addr);
            const count_str = try std.fmt.allocPrint(allocator, "\"{s}\":{d}", .{ output_key, count });
            defer allocator.free(count_str);
            try json.appendSlice(allocator, count_str);
            first = false;
        } else if (std.mem.eql(u8, sel.name, "roleHolderCount")) {
            const count = try database.getResolverRoleHolderCount(resolver_addr);
            const count_str = try std.fmt.allocPrint(allocator, "\"{s}\":{d}", .{ output_key, count });
            defer allocator.free(count_str);
            try json.appendSlice(allocator, count_str);
            first = false;
        } else if (std.mem.eql(u8, sel.name, "nodes")) {
            const limit_arg = parser.getIntArg(sel, "first", null) orelse 100;
            const limit: u32 = @intCast(@min(limit_arg, 1000));
            const names = try database.getNamesByResolver(resolver_addr, limit);
            defer {
                for (names) |*name| @constCast(name).deinit(allocator);
                allocator.free(names);
            }

            try json.appendSlice(allocator, "\"");
            try json.appendSlice(allocator, output_key);
            try json.appendSlice(allocator, "\":[");
            for (names, 0..) |*name, i| {
                if (i > 0) try json.appendSlice(allocator, ",");
                const name_mut = @constCast(name);
                const domain_json = try builders.buildDomainJson(name_mut, sel.selections, .{
                    .database = database,
                    .depth = 1,
                    .allocator = allocator,
                    .loaders = loaders,
                });
                defer allocator.free(domain_json);
                try json.appendSlice(allocator, domain_json);
            }
            try json.appendSlice(allocator, "]");
            first = false;
        } else if (std.mem.eql(u8, sel.name, "aliases")) {
            const alias_records = try database.getResolverAliases(resolver_addr);
            defer {
                for (alias_records) |*r| @constCast(r).deinit(allocator);
                allocator.free(alias_records);
            }

            try json.appendSlice(allocator, "\"");
            try json.appendSlice(allocator, output_key);
            try json.appendSlice(allocator, "\":[");
            for (alias_records, 0..) |record, i| {
                if (i > 0) try json.appendSlice(allocator, ",");
                try json.appendSlice(allocator, "{");
                var first_sub = true;
                for (sel.selections) |subfield| {
                    if (std.mem.eql(u8, subfield.name, "fromName")) {
                        if (!first_sub) try json.appendSlice(allocator, ",");
                        const escaped = try json_utils.escapeString(allocator, record.from_name);
                        defer allocator.free(escaped);
                        const val = try std.fmt.allocPrint(allocator, "\"fromName\":\"{s}\"", .{escaped});
                        defer allocator.free(val);
                        try json.appendSlice(allocator, val);
                        first_sub = false;
                    } else if (std.mem.eql(u8, subfield.name, "toName")) {
                        if (!first_sub) try json.appendSlice(allocator, ",");
                        const escaped = try json_utils.escapeString(allocator, record.to_name);
                        defer allocator.free(escaped);
                        const val = try std.fmt.allocPrint(allocator, "\"toName\":\"{s}\"", .{escaped});
                        defer allocator.free(val);
                        try json.appendSlice(allocator, val);
                        first_sub = false;
                    }
                }
                if (first_sub) {
                    const escaped_from = try json_utils.escapeString(allocator, record.from_name);
                    defer allocator.free(escaped_from);
                    const escaped_to = try json_utils.escapeString(allocator, record.to_name);
                    defer allocator.free(escaped_to);
                    const val = try std.fmt.allocPrint(allocator, "\"fromName\":\"{s}\",\"toName\":\"{s}\"", .{ escaped_from, escaped_to });
                    defer allocator.free(val);
                    try json.appendSlice(allocator, val);
                }
                try json.appendSlice(allocator, "}");
            }
            try json.appendSlice(allocator, "]");
            first = false;
        } else if (std.mem.eql(u8, sel.name, "roles")) {
            const role_list = try database.getResolverRoles(resolver_addr);
            defer {
                for (role_list) |*role| @constCast(role).deinit(allocator);
                allocator.free(role_list);
            }

            try json.appendSlice(allocator, "\"");
            try json.appendSlice(allocator, output_key);
            try json.appendSlice(allocator, "\":[");
            for (role_list, 0..) |*role, i| {
                if (i > 0) try json.appendSlice(allocator, ",");
                const handler = FieldHandler{
                    .handleFn = handleEACRoleField,
                    .context = @ptrCast(@constCast(role)),
                };
                const role_json = try buildJsonWithFields(allocator, sel.selections, handler);
                defer allocator.free(role_json);
                try json.appendSlice(allocator, role_json);
            }
            try json.appendSlice(allocator, "]");
            first = false;
        } else if (std.mem.eql(u8, sel.name, "namedResources")) {
            try json.appendSlice(allocator, "\"");
            try json.appendSlice(allocator, output_key);
            try json.appendSlice(allocator, "\":[");
            var emitted: usize = 0;
            inline for (.{ models.Protocol.v2, models.Protocol.v1 }) |proto| {
                const rows = try database.getNamedResources(allocator, proto, resolver_addr);
                defer {
                    for (rows) |*r| r.deinit(allocator);
                    allocator.free(rows);
                }
                for (rows) |*row| {
                    if (emitted > 0) try json.appendSlice(allocator, ",");
                    emitted += 1;
                    var fctx = NamedResourceFieldCtx{ .protocol = proto.toString(), .row = row };
                    const handler = FieldHandler{
                        .handleFn = handleNamedResourceField,
                        .context = @ptrCast(&fctx),
                    };
                    const row_json = try buildJsonWithFields(allocator, sel.selections, handler);
                    defer allocator.free(row_json);
                    try json.appendSlice(allocator, row_json);
                }
            }
            try json.appendSlice(allocator, "]");
            first = false;
        } else if (std.mem.eql(u8, sel.name, "events")) {
            const limit_arg = parser.getIntArg(sel, "first", null) orelse 100;
            const limit: u32 = @intCast(@min(limit_arg, 1000));

            const addr_hex = try resolver_addr.toHex(allocator);
            defer allocator.free(addr_hex);

            const events_list = try database.getEventsFiltered(.{
                .contract_address = addr_hex,
                .limit = limit,
            });
            defer {
                for (events_list) |*evt| @constCast(evt).deinit(allocator);
                allocator.free(events_list);
            }

            try json.appendSlice(allocator, "\"");
            try json.appendSlice(allocator, output_key);
            try json.appendSlice(allocator, "\":[");
            for (events_list, 0..) |*evt, i| {
                if (i > 0) try json.appendSlice(allocator, ",");
                const evt_json = try builders.buildEventJson(evt, sel.selections, .{
                    .database = database,
                    .depth = 1,
                    .allocator = allocator,
                    .loaders = loaders,
                });
                defer allocator.free(evt_json);
                try json.appendSlice(allocator, evt_json);
            }
            try json.appendSlice(allocator, "]");
            first = false;
        }
    }

    try json.appendSlice(allocator, "}");
    return try allocator.dupe(u8, json.items);
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

const NamedResourceFieldCtx = struct {
    protocol: []const u8,
    row: *const db.NamedResource,
};

/// NamedResourceEntry field handler
fn handleNamedResourceField(ctx: *anyopaque, output_key: []const u8, field_name: []const u8, writer: std.ArrayList(u8).Writer, allocator: std.mem.Allocator) !bool {
    const c: *const NamedResourceFieldCtx = @ptrCast(@alignCast(ctx));
    if (std.mem.eql(u8, field_name, "protocol")) {
        try writer.print("\"{s}\":\"{s}\"", .{ output_key, c.protocol });
        return true;
    } else if (std.mem.eql(u8, field_name, "resource")) {
        const escaped = try json_utils.escapeString(allocator, c.row.resource);
        defer allocator.free(escaped);
        try writer.print("\"{s}\":\"{s}\"", .{ output_key, escaped });
        return true;
    } else if (std.mem.eql(u8, field_name, "recordKind")) {
        const escaped = try json_utils.escapeString(allocator, c.row.record_kind);
        defer allocator.free(escaped);
        try writer.print("\"{s}\":\"{s}\"", .{ output_key, escaped });
        return true;
    } else if (std.mem.eql(u8, field_name, "recordKey")) {
        const escaped = try json_utils.escapeString(allocator, c.row.record_key);
        defer allocator.free(escaped);
        try writer.print("\"{s}\":\"{s}\"", .{ output_key, escaped });
        return true;
    } else if (std.mem.eql(u8, field_name, "coinType")) {
        try writer.print("\"{s}\":\"{d}\"", .{ output_key, c.row.coin_type });
        return true;
    } else if (std.mem.eql(u8, field_name, "name")) {
        const escaped = try json_utils.escapeString(allocator, c.row.name);
        defer allocator.free(escaped);
        try writer.print("\"{s}\":\"{s}\"", .{ output_key, escaped });
        return true;
    } else if (std.mem.eql(u8, field_name, "blockNumber")) {
        try writer.print("\"{s}\":{d}", .{ output_key, c.row.block_number });
        return true;
    }
    return false;
}

/// EACRole field handler
fn handleEACRoleField(ctx: *anyopaque, output_key: []const u8, field_name: []const u8, writer: std.ArrayList(u8).Writer, allocator: std.mem.Allocator) !bool {
    const role: *const models.EACRoleAssignment = @ptrCast(@alignCast(ctx));

    if (std.mem.eql(u8, field_name, "id")) {
        try writer.print("\"{s}\":\"{d}\"", .{ output_key, role.id });
        return true;
    } else if (std.mem.eql(u8, field_name, "resource")) {
        const escaped = try json_utils.escapeString(allocator, role.resource);
        defer allocator.free(escaped);
        try writer.print("\"{s}\":\"{s}\"", .{ output_key, escaped });
        return true;
    } else if (std.mem.eql(u8, field_name, "account")) {
        const account_hex = try role.account.toHex(allocator);
        defer allocator.free(account_hex);
        try writer.print("\"{s}\":\"{s}\"", .{ output_key, account_hex });
        return true;
    } else if (std.mem.eql(u8, field_name, "roleBitmap")) {
        const escaped = try json_utils.escapeString(allocator, role.role_bitmap);
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
    } else if (std.mem.eql(u8, field_name, "name")) {
        if (role.name) |name| {
            const escaped = try json_utils.escapeString(allocator, name);
            defer allocator.free(escaped);
            try writer.print("\"{s}\":\"{s}\"", .{ output_key, escaped });
        } else {
            try writer.print("\"{s}\":null", .{output_key});
        }
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
        const escaped = try json_utils.escapeString(allocator, registry.name);
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

// ============================================================================
// RegistryInfo JSON builder — handles scalar AND nested fields (owner, labels,
// labelCount, events, eventCount, roles, roleCount).
//
// We don't go through the generic `FieldHandler`/`buildJsonWithFields` path
// because that handler only sees field NAMES, not the full Field (args + sub-
// selections). Nested fields like `labels(first: 50)` need both, so we walk
// `selections` directly.
// ============================================================================

/// Hex form of the EAC "ALL roles" bitmap and the root resource (resource=0x0).
/// Matches `script/deploy-constants.ts:FLAGS.ALL` in contracts-v2.
const REG_ROOT_RESOURCE_HEX: []const u8 = "0x0000000000000000000000000000000000000000000000000000000000000000";
const REG_ROLE_BITMAP_ALL_HEX: []const u8 = "0x1111111111111111111111111111111111111111111111111111111111111111";

/// Cap on `first` for nested list fields. Mirrors the per-query pagination cap
/// so a single registry lookup can't fan out to an unbounded scan.
const REG_NESTED_DEFAULT_LIMIT: u32 = 100;
const REG_NESTED_MAX_LIMIT: u32 = 1000;

fn nestedLimit(field: *const parser.Field) u32 {
    const requested = parser.getIntArg(field, "first", @intCast(REG_NESTED_DEFAULT_LIMIT)) orelse @as(i64, REG_NESTED_DEFAULT_LIMIT);
    const clamped: i64 = @max(0, @min(@as(i64, REG_NESTED_MAX_LIMIT), requested));
    return @intCast(clamped);
}

fn nestedSkip(field: *const parser.Field) u32 {
    const requested = parser.getIntArg(field, "skip", 0) orelse @as(i64, 0);
    const clamped: i64 = @max(0, requested);
    return @intCast(clamped);
}

/// Build a Registry JSON object handling each requested field. Nested fields
/// run their own DB queries; scalar fields use `handleRegistryField` for
/// formatting (so the scalar logic stays in one place).
fn buildRegistryInfoJson(
    allocator: std.mem.Allocator,
    database: *db.Database,
    registry: *const models.Registry,
    selections: []const parser.Field,
    ctx: parser.ExecutionContext,
) anyerror![]u8 {
    var json: std.ArrayList(u8) = .{};
    defer json.deinit(allocator);
    try json.appendSlice(allocator, "{");

    var first = true;
    for (selections) |*sel| {
        const output_key = sel.alias orelse sel.name;

        var field_buf: std.ArrayList(u8) = .{};
        defer field_buf.deinit(allocator);

        const handled = try writeRegistryField(allocator, database, registry, sel, output_key, field_buf.writer(allocator), ctx);
        if (!handled) continue;

        if (!first) try json.appendSlice(allocator, ",");
        try json.appendSlice(allocator, field_buf.items);
        first = false;
    }

    try json.appendSlice(allocator, "}");
    return try allocator.dupe(u8, json.items);
}

/// Write one Registry field. Returns true if the field is known (so the
/// caller writes the comma), false to skip unknown fields silently.
fn writeRegistryField(
    allocator: std.mem.Allocator,
    database: *db.Database,
    registry: *const models.Registry,
    sel: *const parser.Field,
    output_key: []const u8,
    writer: std.ArrayList(u8).Writer,
    ctx: parser.ExecutionContext,
) anyerror!bool {
    // Scalar fields: delegate to the existing handler.
    if (try handleRegistryField(@ptrCast(@constCast(registry)), output_key, sel.name, writer, allocator)) {
        return true;
    }

    if (std.mem.eql(u8, sel.name, "owner")) {
        try writeRegistryOwner(allocator, database, registry, sel, output_key, writer, ctx);
        return true;
    }
    if (std.mem.eql(u8, sel.name, "labels")) {
        try writeRegistryLabels(allocator, database, registry, sel, output_key, writer, ctx);
        return true;
    }
    if (std.mem.eql(u8, sel.name, "labelConnection")) {
        try writeRegistryLabelConnection(allocator, database, registry, sel, output_key, writer, ctx);
        return true;
    }
    if (std.mem.eql(u8, sel.name, "labelCount")) {
        const count = try database.getFilteredNameCount(.{
            .registry = registry.address,
        });
        try writer.print("\"{s}\":{d}", .{ output_key, count });
        return true;
    }
    if (std.mem.eql(u8, sel.name, "events")) {
        try writeRegistryEvents(allocator, database, registry, sel, output_key, writer, ctx);
        return true;
    }
    if (std.mem.eql(u8, sel.name, "eventConnection")) {
        try writeRegistryEventConnection(allocator, database, registry, sel, output_key, writer, ctx);
        return true;
    }
    if (std.mem.eql(u8, sel.name, "eventCount")) {
        const addr_hex = try registry.address.toHex(allocator);
        defer allocator.free(addr_hex);
        const count = try database.getEventCount(.{
            .protocol = registry.protocol,
            .contract_address = addr_hex,
        });
        try writer.print("\"{s}\":{d}", .{ output_key, count });
        return true;
    }
    if (std.mem.eql(u8, sel.name, "roles")) {
        try writeRegistryRoles(allocator, database, registry, sel, output_key, writer);
        return true;
    }
    if (std.mem.eql(u8, sel.name, "roleConnection")) {
        try writeRegistryRoleConnection(allocator, database, registry, sel, output_key, writer);
        return true;
    }
    if (std.mem.eql(u8, sel.name, "roleCount")) {
        const count = try database.getRoleCountFiltered(.{
            .protocol = registry.protocol,
            .contract_address = registry.address,
        });
        try writer.print("\"{s}\":{d}", .{ output_key, count });
        return true;
    }

    return false;
}

/// `owner` = the account holding the FULL root-role bitmap on this registry.
/// Resolves to null if no such role has been granted.
fn writeRegistryOwner(
    allocator: std.mem.Allocator,
    database: *db.Database,
    registry: *const models.Registry,
    sel: *const parser.Field,
    output_key: []const u8,
    writer: std.ArrayList(u8).Writer,
    ctx: parser.ExecutionContext,
) !void {
    // Query all root-resource roles on this contract, then pick the most
    // recently granted holder of the full bitmap. The contract-address
    // filter narrows by registry; the resource filter (root context) is
    // applied client-side because the helper currently only filters
    // resource as a single string match (which works since root is 0x0…0).
    const opts = db.RolePaginationOptions{
        .resource = REG_ROOT_RESOURCE_HEX,
        .contract_address = registry.address,
        .limit = REG_NESTED_MAX_LIMIT,
    };
    const role_rows = try database.getRolesWithPagination(registry.protocol, opts);
    defer {
        for (role_rows) |*r| {
            var role_mut = r.*;
            role_mut.deinit(allocator);
        }
        allocator.free(role_rows);
    }

    var owner_addr: ?Address = null;
    for (role_rows) |*r| {
        if (std.mem.eql(u8, r.role_bitmap, REG_ROLE_BITMAP_ALL_HEX)) {
            owner_addr = r.account; // rows come back DESC by id; first match is newest
            break;
        }
    }

    if (owner_addr) |addr| {
        try writer.print("\"{s}\":", .{output_key});
        const account_json = try builders.buildAccountJson(addr, sel.selections, .{
            .database = database,
            .depth = 0,
            .allocator = allocator,
            .loaders = ctx.loaders,
        });
        defer allocator.free(account_json);
        try writer.writeAll(account_json);
    } else {
        try writer.print("\"{s}\":null", .{output_key});
    }
}

/// Layer `where: DomainFilter` from `sel` onto `filters`. Shared by both the
/// offset-based labels field and the cursor-based labelConnection so the two
/// expose the same filter surface.
fn applyLabelsWhere(sel: *const parser.Field, filters: *db.NameFilters) !void {
    const where_args = common.getObjectArg(sel, "where") orelse return;
    for (where_args) |a| {
        _ = common.matchStringArg(a, "name", &filters.name) or
            common.matchStringArg(a, "name_contains", &filters.name_contains) or
            common.matchStringArg(a, "name_contains_nocase", &filters.name_contains_nocase) or
            common.matchStringArg(a, "name_starts_with", &filters.name_starts_with) or
            common.matchStringArg(a, "name_ends_with", &filters.name_ends_with) or
            (try common.matchAddressArg(a, "owner", &filters.owner)) or
            common.matchIntArg(a, "expiry_gt", &filters.expiry_gt) or
            common.matchIntArg(a, "expiry_gte", &filters.expiry_gte) or
            common.matchIntArg(a, "expiry_lt", &filters.expiry_lt) or
            common.matchIntArg(a, "expiry_lte", &filters.expiry_lte) or
            common.matchBoolArg(a, "isMigrated", &filters.migrated);
    }
}

/// Layer `where: EventFilter` from `sel` onto `filter`. Shared by the offset
/// and connection variants so they accept the same filter shape.
fn applyEventsWhere(sel: *const parser.Field, filter: *db.EventFilterOptions) void {
    const where_args = common.getObjectArg(sel, "where") orelse return;
    for (where_args) |a| {
        _ = common.matchStringArg(a, "type", &filter.event_type) or
            common.matchStringArg(a, "domain", &filter.domain) or
            common.matchStringArg(a, "namehash", &filter.namehash) or
            common.matchIntArg(a, "blockNumber_gt", &filter.block_number_gt) or
            common.matchIntArg(a, "blockNumber_gte", &filter.block_number_gte) or
            common.matchIntArg(a, "blockNumber_lt", &filter.block_number_lt) or
            common.matchIntArg(a, "blockNumber_lte", &filter.block_number_lte) or
            common.matchIntArg(a, "timestamp_gt", &filter.timestamp_gt) or
            common.matchIntArg(a, "timestamp_gte", &filter.timestamp_gte) or
            common.matchIntArg(a, "timestamp_lt", &filter.timestamp_lt) or
            common.matchIntArg(a, "timestamp_lte", &filter.timestamp_lte);
    }
}

/// `labels` = names whose `registry` column matches this contract address.
/// Reuses `getFilteredNames` so caller-supplied `where` filters compose with
/// the registry pin.
fn writeRegistryLabels(
    allocator: std.mem.Allocator,
    database: *db.Database,
    registry: *const models.Registry,
    sel: *const parser.Field,
    output_key: []const u8,
    writer: std.ArrayList(u8).Writer,
    ctx: parser.ExecutionContext,
) !void {
    var filters = db.NameFilters{ .registry = registry.address };
    try applyLabelsWhere(sel, &filters);

    const limit = nestedLimit(sel);
    const skip = nestedSkip(sel);
    const sort_field = domain_resolvers.mapDomainOrderBy(parser.getStringArg(sel, "orderBy", null));
    const order_dir = common.parseOrderDirection(sel, db.OrderDir, .desc);

    const names = try database.getFilteredNames(filters, skip, limit, order_dir, sort_field);
    defer {
        for (names) |*n| {
            var name_mut = n.*;
            name_mut.deinit(allocator);
        }
        allocator.free(names);
    }

    try writer.print("\"{s}\":[", .{output_key});
    for (names, 0..) |*name, i| {
        if (i > 0) try writer.writeAll(",");
        const dom_json = try builders.buildDomainJson(name, sel.selections, .{
            .database = database,
            .depth = 0,
            .allocator = allocator,
            .loaders = ctx.loaders,
        });
        defer allocator.free(dom_json);
        try writer.writeAll(dom_json);
    }
    try writer.writeAll("]");
}

/// `events` = events emitted by this registry contract (history tab).
fn writeRegistryEvents(
    allocator: std.mem.Allocator,
    database: *db.Database,
    registry: *const models.Registry,
    sel: *const parser.Field,
    output_key: []const u8,
    writer: std.ArrayList(u8).Writer,
    ctx: parser.ExecutionContext,
) !void {
    const addr_hex = try registry.address.toHex(allocator);
    defer allocator.free(addr_hex);

    var filter = db.EventFilterOptions{
        .protocol = registry.protocol,
        .contract_address = addr_hex,
        .limit = nestedLimit(sel),
        .skip = nestedSkip(sel),
    };
    applyEventsWhere(sel, &filter);

    const events = try database.getEventsFiltered(filter);
    defer {
        for (events) |*e| {
            var ev_mut = e.*;
            ev_mut.deinit(allocator);
        }
        allocator.free(events);
    }

    try writer.print("\"{s}\":[", .{output_key});
    for (events, 0..) |*event, i| {
        if (i > 0) try writer.writeAll(",");
        const ev_json = try builders.buildEventJson(event, sel.selections, .{
            .database = database,
            .depth = 0,
            .allocator = allocator,
            .loaders = ctx.loaders,
        });
        defer allocator.free(ev_json);
        try writer.writeAll(ev_json);
    }
    try writer.writeAll("]");
}

/// `roles` = EAC role assignments on this registry contract. Filter by
/// account optionally.
fn writeRegistryRoles(
    allocator: std.mem.Allocator,
    database: *db.Database,
    registry: *const models.Registry,
    sel: *const parser.Field,
    output_key: []const u8,
    writer: std.ArrayList(u8).Writer,
) !void {
    var opts = db.RolePaginationOptions{
        .contract_address = registry.address,
        .limit = nestedLimit(sel),
    };
    if (parser.getStringArg(sel, "account", null)) |acc_str| {
        opts.account = Address.fromHex(acc_str) catch return error.InvalidAddress;
    }

    const roles_list = try database.getRolesWithPagination(registry.protocol, opts);
    defer {
        for (roles_list) |*r| {
            var role_mut = r.*;
            role_mut.deinit(allocator);
        }
        allocator.free(roles_list);
    }

    try writer.print("\"{s}\":[", .{output_key});
    for (roles_list, 0..) |*role, i| {
        if (i > 0) try writer.writeAll(",");
        const handler = FieldHandler{
            .handleFn = handleEACRoleField,
            .context = @ptrCast(@constCast(role)),
        };
        const role_json = try buildJsonWithFields(allocator, sel.selections, handler);
        defer allocator.free(role_json);
        try writer.writeAll(role_json);
    }
    try writer.writeAll("]");
}

// ============================================================================
// Registry connection variants (Relay cursor pagination).
//
// These mirror the top-level *Connection resolvers but pin the registry-side
// filters (registry address / contract_address) so the connection is scoped
// to one Registry contract. Cursor format matches the top-level field for the
// same underlying type, so cursors are interchangeable across contexts.
// ============================================================================

/// Parse first/after/last/before from a nested selection.
fn parseConnectionParams(sel: *const parser.Field) !pagination.PaginationParams {
    const first = parser.getIntArg(sel, "first", null);
    const after = parser.getStringArg(sel, "after", null);
    const last = parser.getIntArg(sel, "last", null);
    const before = parser.getStringArg(sel, "before", null);
    return pagination.PaginationParams.parse(
        first,
        after,
        last,
        before,
        REG_NESTED_DEFAULT_LIMIT,
        REG_NESTED_MAX_LIMIT,
    );
}

/// Inspect a connection selection for which top-level fields the client wants.
const ConnectionWants = struct { edges: bool, page_info: bool, total_count: bool };
fn detectConnectionWants(sel: *const parser.Field) ConnectionWants {
    var w = ConnectionWants{ .edges = false, .page_info = false, .total_count = false };
    for (sel.selections) |*s| {
        if (std.mem.eql(u8, s.name, "edges")) w.edges = true;
        if (std.mem.eql(u8, s.name, "pageInfo")) w.page_info = true;
        if (std.mem.eql(u8, s.name, "totalCount")) w.total_count = true;
    }
    return w;
}

/// Find `edges { node { ... } }` selections; returns an empty slice if not present.
fn findNodeSelections(sel: *const parser.Field) []const parser.Field {
    for (sel.selections) |*s| {
        if (std.mem.eql(u8, s.name, "edges")) {
            for (s.selections) |*e| {
                if (std.mem.eql(u8, e.name, "node")) return e.selections;
            }
            break;
        }
    }
    return &[_]parser.Field{};
}

/// Write the `pageInfo` block of a connection. Cursors are passed pre-encoded
/// so this helper is agnostic to int vs. string cursor flavors.
fn writeConnectionPageInfo(
    writer: std.ArrayList(u8).Writer,
    params: pagination.PaginationParams,
    has_more: bool,
    start_cursor: ?[]const u8,
    end_cursor: ?[]const u8,
) !void {
    try writer.writeAll("\"pageInfo\":{\"hasNextPage\":");
    try writer.writeAll(if (params.direction == .forward and has_more) "true" else "false");
    try writer.writeAll(",\"hasPreviousPage\":");
    try writer.writeAll(if (params.direction == .backward and has_more) "true" else if (params.cursor != null) "true" else "false");

    if (start_cursor) |c| {
        try writer.print(",\"startCursor\":\"{s}\"", .{c});
    } else {
        try writer.writeAll(",\"startCursor\":null");
    }
    if (end_cursor) |c| {
        try writer.print(",\"endCursor\":\"{s}\"", .{c});
    } else {
        try writer.writeAll(",\"endCursor\":null");
    }
    try writer.writeAll("}");
}

fn writeRegistryLabelConnection(
    allocator: std.mem.Allocator,
    database: *db.Database,
    registry: *const models.Registry,
    sel: *const parser.Field,
    output_key: []const u8,
    writer: std.ArrayList(u8).Writer,
    ctx: parser.ExecutionContext,
) !void {
    const params = try parseConnectionParams(sel);
    const wants = detectConnectionWants(sel);

    var filters = db.NameFilters{ .registry = registry.address };
    try applyLabelsWhere(sel, &filters);

    try writer.print("\"{s}\":{{", .{output_key});

    if (wants.total_count and !wants.edges and !wants.page_info) {
        const count = try database.getFilteredNameCount(filters);
        try writer.print("\"totalCount\":{d}}}", .{count});
        return;
    }

    const sort_field = domain_resolvers.mapDomainOrderBy(parser.getStringArg(sel, "orderBy", null));
    const base_dir = common.parseOrderDirection(sel, db.OrderDir, .desc);
    const order_dir: db.OrderDir = if (params.direction == .backward)
        (if (base_dir == .desc) .asc else .desc)
    else
        base_dir;

    var skip: u32 = 0;
    if (params.cursor) |c| {
        const cursor_namehash = try pagination.CursorCodec.decodeString(allocator, c);
        defer allocator.free(cursor_namehash);
        const rows_before = database.countRowsBeforeNamehash(cursor_namehash, sort_field, order_dir, filters) catch 0;
        skip = rows_before +| 1;
    }

    const fetch_limit: u32 = @intCast(params.limit + 1);
    const names = try database.getFilteredNames(filters, skip, fetch_limit, order_dir, sort_field);
    defer {
        for (names) |*n| {
            var nn = n.*;
            nn.deinit(allocator);
        }
        allocator.free(names);
    }

    const has_more = names.len > params.limit;
    const actual = @min(names.len, params.limit);
    if (params.direction == .backward and actual > 1) std.mem.reverse(models.Name, names[0..actual]);
    const items = names[0..actual];

    // Pre-encode cursors per edge (kept for re-use in pageInfo).
    var edge_cursors = try allocator.alloc([]const u8, items.len);
    defer {
        for (edge_cursors) |c| allocator.free(c);
        allocator.free(edge_cursors);
    }
    for (items, 0..) |*name, i| {
        const id_hex = try name.namehash.toHex(allocator);
        defer allocator.free(id_hex);
        edge_cursors[i] = try pagination.CursorCodec.encodeString(allocator, id_hex);
    }

    const start_cursor: ?[]const u8 = if (edge_cursors.len > 0) edge_cursors[0] else null;
    const end_cursor: ?[]const u8 = if (edge_cursors.len > 0) edge_cursors[edge_cursors.len - 1] else null;
    try writeConnectionPageInfo(writer, params, has_more, start_cursor, end_cursor);

    try writer.writeAll(",\"edges\":[");
    const node_selections = findNodeSelections(sel);
    for (items, 0..) |*name, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.print("{{\"cursor\":\"{s}\",\"node\":", .{edge_cursors[i]});
        const dom_json = try builders.buildDomainJson(name, node_selections, .{
            .database = database,
            .depth = 0,
            .allocator = allocator,
            .loaders = ctx.loaders,
        });
        defer allocator.free(dom_json);
        try writer.writeAll(dom_json);
        try writer.writeAll("}");
    }
    try writer.writeAll("]");

    if (wants.total_count) {
        const count = try database.getFilteredNameCount(filters);
        try writer.print(",\"totalCount\":{d}", .{count});
    }
    try writer.writeAll("}");
}

fn writeRegistryEventConnection(
    allocator: std.mem.Allocator,
    database: *db.Database,
    registry: *const models.Registry,
    sel: *const parser.Field,
    output_key: []const u8,
    writer: std.ArrayList(u8).Writer,
    ctx: parser.ExecutionContext,
) !void {
    const params = try parseConnectionParams(sel);
    const wants = detectConnectionWants(sel);

    const addr_hex = try registry.address.toHex(allocator);
    defer allocator.free(addr_hex);

    var filter = db.EventFilterOptions{
        .protocol = registry.protocol,
        .contract_address = addr_hex,
    };
    applyEventsWhere(sel, &filter);

    if (parser.getStringArg(sel, "orderBy", null)) |o| {
        if (std.mem.eql(u8, o, "blockNumber")) filter.sort_field = .block_number;
        if (std.mem.eql(u8, o, "timestamp")) filter.sort_field = .timestamp;
        if (std.mem.eql(u8, o, "name")) filter.sort_field = .name;
    }
    filter.order_dir = common.parseOrderDirection(sel, db.EventOrderDir, filter.order_dir);

    try writer.print("\"{s}\":{{", .{output_key});

    if (wants.total_count and !wants.edges and !wants.page_info) {
        const count = try database.getEventCount(filter);
        try writer.print("\"totalCount\":{d}}}", .{count});
        return;
    }

    const user_dir = filter.order_dir;
    const order_dir: db.EventOrderDir = if (params.direction == .backward)
        (if (user_dir == .desc) .asc else .desc)
    else
        user_dir;

    var skip: u32 = 0;
    if (params.cursor) |c| {
        const decoded = try pagination.CursorCodec.decodeString(allocator, c);
        defer allocator.free(decoded);
        const sep = std.mem.lastIndexOfScalar(u8, decoded, '-') orelse return error.InvalidCursor;
        const tx_hash = decoded[0..sep];
        const log_index = std.fmt.parseInt(u32, decoded[sep + 1 ..], 10) catch return error.InvalidCursor;
        const before = database.countEventsBeforeCursor(tx_hash, log_index, order_dir, filter) catch 0;
        skip = before +| 1;
    }

    var fetch_filter = filter;
    fetch_filter.limit = @intCast(params.limit + 1);
    fetch_filter.skip = skip;
    fetch_filter.order_dir = order_dir;

    const events = try database.getEventsFiltered(fetch_filter);
    defer {
        for (events) |*e| {
            var em = e.*;
            em.deinit(allocator);
        }
        allocator.free(events);
    }

    const has_more = events.len > params.limit;
    const actual = @min(events.len, params.limit);
    if (params.direction == .backward and actual > 1) std.mem.reverse(models.Event, events[0..actual]);
    const items = events[0..actual];

    // Encode cursors once per edge (reused in pageInfo and edge JSON).
    var edge_cursors = try allocator.alloc([]const u8, items.len);
    defer {
        for (edge_cursors) |c| allocator.free(c);
        allocator.free(edge_cursors);
    }
    for (items, 0..) |*e, i| {
        const tx = try e.tx_hash.toHex(allocator);
        defer allocator.free(tx);
        const id = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ tx, e.log_index });
        defer allocator.free(id);
        edge_cursors[i] = try pagination.CursorCodec.encodeString(allocator, id);
    }

    const start_cursor: ?[]const u8 = if (edge_cursors.len > 0) edge_cursors[0] else null;
    const end_cursor: ?[]const u8 = if (edge_cursors.len > 0) edge_cursors[edge_cursors.len - 1] else null;
    try writeConnectionPageInfo(writer, params, has_more, start_cursor, end_cursor);

    try writer.writeAll(",\"edges\":[");
    const node_selections = findNodeSelections(sel);
    for (items, 0..) |*evt, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.print("{{\"cursor\":\"{s}\",\"node\":", .{edge_cursors[i]});
        const ev_json = try builders.buildEventJson(evt, node_selections, .{
            .database = database,
            .depth = 0,
            .allocator = allocator,
            .loaders = ctx.loaders,
        });
        defer allocator.free(ev_json);
        try writer.writeAll(ev_json);
        try writer.writeAll("}");
    }
    try writer.writeAll("]");

    if (wants.total_count) {
        const count = try database.getEventCount(filter);
        try writer.print(",\"totalCount\":{d}", .{count});
    }
    try writer.writeAll("}");
}

fn writeRegistryRoleConnection(
    allocator: std.mem.Allocator,
    database: *db.Database,
    registry: *const models.Registry,
    sel: *const parser.Field,
    output_key: []const u8,
    writer: std.ArrayList(u8).Writer,
) !void {
    const params = try parseConnectionParams(sel);
    const wants = detectConnectionWants(sel);

    var account_addr: ?Address = null;
    if (parser.getStringArg(sel, "account", null)) |acc| {
        account_addr = Address.fromHex(acc) catch return error.InvalidAddress;
    }

    try writer.print("\"{s}\":{{", .{output_key});

    const count_filter = db.RoleCountFilters{
        .protocol = registry.protocol,
        .account = account_addr,
        .contract_address = registry.address,
    };

    if (wants.total_count and !wants.edges and !wants.page_info) {
        const count = try database.getRoleCountFiltered(count_filter);
        try writer.print("\"totalCount\":{d}}}", .{count});
        return;
    }

    var cursor_id: ?i64 = null;
    if (params.cursor) |c| {
        cursor_id = try pagination.CursorCodec.decodeInt(allocator, c);
    }

    const fetch_limit: u32 = @intCast(params.limit + 1);
    const role_rows = try database.getRolesWithPagination(registry.protocol, .{
        .account = account_addr,
        .contract_address = registry.address,
        .limit = fetch_limit,
        .cursor_id = cursor_id,
        .direction = if (params.direction == .backward) .backward else .forward,
    });
    defer {
        for (role_rows) |*r| {
            var rm = r.*;
            rm.deinit(allocator);
        }
        allocator.free(role_rows);
    }

    const has_more = role_rows.len > params.limit;
    const actual = @min(role_rows.len, params.limit);
    if (params.direction == .backward and actual > 1) std.mem.reverse(models.EACRoleAssignment, role_rows[0..actual]);
    const items = role_rows[0..actual];

    // Encode cursors once per edge (int-flavored; reused in pageInfo + edges).
    var edge_cursors = try allocator.alloc([]const u8, items.len);
    defer {
        for (edge_cursors) |c| allocator.free(c);
        allocator.free(edge_cursors);
    }
    for (items, 0..) |*role, i| {
        edge_cursors[i] = try pagination.CursorCodec.encodeInt(allocator, @intCast(role.id));
    }

    const start_cursor: ?[]const u8 = if (edge_cursors.len > 0) edge_cursors[0] else null;
    const end_cursor: ?[]const u8 = if (edge_cursors.len > 0) edge_cursors[edge_cursors.len - 1] else null;
    try writeConnectionPageInfo(writer, params, has_more, start_cursor, end_cursor);

    try writer.writeAll(",\"edges\":[");
    const node_selections = findNodeSelections(sel);
    for (items, 0..) |*role, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.print("{{\"cursor\":\"{s}\",\"node\":", .{edge_cursors[i]});
        const handler = FieldHandler{
            .handleFn = handleEACRoleField,
            .context = @ptrCast(@constCast(role)),
        };
        const role_json = try buildJsonWithFields(allocator, node_selections, handler);
        defer allocator.free(role_json);
        try writer.writeAll(role_json);
        try writer.writeAll("}");
    }
    try writer.writeAll("]");

    if (wants.total_count) {
        const count = try database.getRoleCountFiltered(count_filter);
        try writer.print(",\"totalCount\":{d}", .{count});
    }
    try writer.writeAll("}");
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
        const escaped = try json_utils.escapeString(allocator, metadata.graphql_url);
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
            const escaped = try json_utils.escapeString(allocator, ctx_str);
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

// ============================================================================
// SUBGRAPH-PARITY ADDITIONS
// ============================================================================

/// Top-level `wrappedDomains(first, skip, where)` resolver. Filter shape mirrors
/// the subgraph WrappedDomain entity. Returns an empty array when no wrapped
/// rows match — never null.
pub fn resolveWrappedDomains(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const allocator = ctx.allocator;
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));

    const page = try common.parsePagination(field, 100);

    var filter_owner: ?Address = null;
    var filter_name: ?[]const u8 = null;
    var filter_expiry_gt: ?i64 = null;
    var filter_expiry_lt: ?i64 = null;

    if (common.getObjectArg(field, "where")) |where_args| {
        for (where_args) |a| {
            _ = common.matchStringArg(a, "name", &filter_name) or
                (try common.matchAddressArg(a, "owner", &filter_owner)) or
                common.matchIntArg(a, "expiryDate_gt", &filter_expiry_gt) or
                common.matchIntArg(a, "expiryDate_lt", &filter_expiry_lt);
        }
    }

    const filters = db.Database.WrappedDomainFilters{
        .owner = filter_owner,
        .name = filter_name,
        .expiry_gt = filter_expiry_gt,
        .expiry_lt = filter_expiry_lt,
    };

    const rows = try database.getWrappedDomains(filters, @intCast(page.skip), page.first);
    defer {
        for (rows) |*r| @constCast(r).deinit(allocator);
        allocator.free(rows);
    }

    var json: std.ArrayList(u8) = .{};
    defer json.deinit(allocator);
    try json.appendSlice(allocator, "[");
    for (rows, 0..) |*r, i| {
        if (i > 0) try json.appendSlice(allocator, ",");
        const wd_json = try builders.buildWrappedDomainJson(r, field.selections, .{
            .database = database,
            .depth = 0,
            .allocator = allocator,
            .loaders = ctx.loaders,
        });
        defer allocator.free(wd_json);
        try json.appendSlice(allocator, wd_json);
    }
    try json.appendSlice(allocator, "]");
    return parser.FieldResult{ .json = try allocator.dupe(u8, json.items) };
}

/// Top-level `_meta` resolver. Reports the highest-synced block across V1/V2
/// `sync_state` rows. `hasIndexingErrors` is currently a literal `false` — we
/// don't track per-tick errors centrally; if/when we do, surface that here.
/// `deployment` is null until we wire in a version/git-sha env var.
pub fn resolveMeta(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const allocator = ctx.allocator;
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));

    const v1_block = (try database.getSyncState(.v1)) orelse 0;
    const v2_block = (try database.getSyncState(.v2)) orelse 0;
    const head: u64 = if (v1_block > v2_block) v1_block else v2_block;

    var json: std.ArrayList(u8) = .{};
    defer json.deinit(allocator);
    const w = json.writer(allocator);

    try w.writeAll("{");
    var first_meta = true;
    for (field.selections) |*sel| {
        const key = sel.alias orelse sel.name;
        if (!first_meta) try w.writeAll(",");
        if (std.mem.eql(u8, sel.name, "block")) {
            try w.print("\"{s}\":{{", .{key});
            var first_b = true;
            // If no sub-selection, default to number-only.
            const block_sels = sel.selections;
            if (block_sels.len == 0) {
                try w.print("\"number\":{d}", .{head});
            } else {
                for (block_sels) |*bs| {
                    const bk = bs.alias orelse bs.name;
                    if (!first_b) try w.writeAll(",");
                    if (std.mem.eql(u8, bs.name, "number")) {
                        try w.print("\"{s}\":{d}", .{ bk, head });
                    } else if (std.mem.eql(u8, bs.name, "hash")) {
                        // We don't surface a synthetic head-hash across the two
                        // protocols (they have different chains); keep null.
                        try w.print("\"{s}\":null", .{bk});
                    } else if (std.mem.eql(u8, bs.name, "timestamp")) {
                        try w.print("\"{s}\":null", .{bk});
                    } else {
                        try w.print("\"{s}\":null", .{bk});
                    }
                    first_b = false;
                }
            }
            try w.writeAll("}");
        } else if (std.mem.eql(u8, sel.name, "hasIndexingErrors")) {
            try w.print("\"{s}\":false", .{key});
        } else if (std.mem.eql(u8, sel.name, "deployment")) {
            try w.print("\"{s}\":null", .{key});
        } else {
            try w.print("\"{s}\":null", .{key});
        }
        first_meta = false;
    }
    try w.writeAll("}");

    return parser.FieldResult{ .json = try allocator.dupe(u8, json.items) };
}
