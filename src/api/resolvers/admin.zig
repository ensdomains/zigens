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
const builders = common.builders;
const escapeJsonString = common.escapeJsonString;

/// Parse chain argument from field (defaults to l2)
fn parseChainArg(field: *const parser.Field) models.Chain {
    const chain_str = parser.getStringArg(field, "chain", null) orelse models.Chain.l2.toString();
    if (std.mem.eql(u8, chain_str, models.Chain.l1.toString())) {
        return .l1;
    }
    return .l2; // Default to L2
}

pub fn resolveRoles(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
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

/// Resolver for roleConnection query (cursor-based pagination)
pub fn resolveRolesConnection(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const allocator = ctx.allocator;
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));

    // Get chain argument (default: l2)
    const chain = parseChainArg(field);

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

    // Parse account address if provided
    var account_addr: ?Address = null;
    if (account_arg) |account_str| {
        account_addr = Address.fromHex(account_str) catch null;
    }

    // Decode cursor if present
    var cursor_id: ?i64 = null;
    if (params.cursor) |cursor| {
        cursor_id = pagination.CursorCodec.decodeInt(allocator, cursor) catch null;
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

    const roles = try database.getRolesWithPagination(chain, .{
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

    // Only compute total count when requested in the GraphQL selection
    var wants_total_count = false;
    for (field.selections) |*sel| {
        if (std.mem.eql(u8, sel.name, "totalCount")) {
            wants_total_count = true;
            break;
        }
    }
    const total_count: ?usize = if (wants_total_count)
        try database.getTotalRoleCount(chain, resource_arg, account_addr)
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
            .context = @constCast(@ptrCast(role)),
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

/// Resolver for resolvers query
pub fn resolveResolvers(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
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
pub fn resolveRegistries(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
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
pub fn resolveMetadata(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
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
pub fn resolveApprovals(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
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

/// Resolver for resolverDetail query - provides detailed resolver info with statistics
pub fn resolveResolver(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const allocator = ctx.allocator;
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));

    // Get required id argument (resolver contract address)
    const id_arg = parser.getStringArg(field, "id", null) orelse {
        const json = try allocator.dupe(u8, "null");
        return parser.FieldResult{ .json = json };
    };

    const resolver_addr = Address.fromHex(id_arg) catch {
        const json = try allocator.dupe(u8, "null");
        return parser.FieldResult{ .json = json };
    };

    // Build JSON based on requested fields
    var json: std.ArrayList(u8) = .{};
    defer json.deinit(allocator);
    try json.appendSlice(allocator, "{");

    var first = true;
    for (field.selections) |*sel| {
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
                    .loaders = ctx.loaders,
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
                        const escaped = try escapeJsonString(allocator, record.from_name);
                        defer allocator.free(escaped);
                        const val = try std.fmt.allocPrint(allocator, "\"fromName\":\"{s}\"", .{escaped});
                        defer allocator.free(val);
                        try json.appendSlice(allocator, val);
                        first_sub = false;
                    } else if (std.mem.eql(u8, subfield.name, "toName")) {
                        if (!first_sub) try json.appendSlice(allocator, ",");
                        const escaped = try escapeJsonString(allocator, record.to_name);
                        defer allocator.free(escaped);
                        const val = try std.fmt.allocPrint(allocator, "\"toName\":\"{s}\"", .{escaped});
                        defer allocator.free(val);
                        try json.appendSlice(allocator, val);
                        first_sub = false;
                    }
                }
                // Default to all fields if none selected
                if (first_sub) {
                    const escaped_from = try escapeJsonString(allocator, record.from_name);
                    defer allocator.free(escaped_from);
                    const escaped_to = try escapeJsonString(allocator, record.to_name);
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
                    .context = @constCast(@ptrCast(role)),
                };
                const role_json = try buildJsonWithFields(allocator, sel.selections, handler);
                defer allocator.free(role_json);
                try json.appendSlice(allocator, role_json);
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
                    .loaders = ctx.loaders,
                });
                defer allocator.free(evt_json);
                try json.appendSlice(allocator, evt_json);
            }
            try json.appendSlice(allocator, "]");
            first = false;
        }
    }

    try json.appendSlice(allocator, "}");
    return parser.FieldResult{ .json = try allocator.dupe(u8, json.items) };
}

// ============================================================================
// Supporting Types and Functions for Resolvers
// ============================================================================

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

/// EACRole field handler
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
    } else if (std.mem.eql(u8, field_name, "name")) {
        if (role.name) |name| {
            const escaped = try escapeJsonString(allocator, name);
            defer allocator.free(escaped);
            try writer.print("\"{s}\":\"{s}\"", .{ output_key, escaped });
        } else {
            try writer.print("\"{s}\":null", .{output_key});
        }
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
