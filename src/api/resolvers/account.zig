/// Account-related GraphQL resolvers
/// - resolveAccount: Single account lookup by id
/// - resolveAccounts: Paginated/filtered list of Account entities (subgraph parity)
const std = @import("std");
const common = @import("common.zig");
const db = common.db;
const models = common.models;
const Address = common.Address;
const parser = common.parser;
const builders = @import("../builders/builders.zig");
const domain_resolvers = @import("domain.zig");

/// Resolver for account query
pub fn resolveAccount(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));
    const allocator = ctx.allocator;

    // Extract id argument
    const id = parser.getStringArg(field, "id", null) orelse {
        const null_json = try allocator.dupe(u8, "null");
        return parser.FieldResult{ .json = null_json };
    };

    // Parse the address — surface invalid input as an error so typos are visible
    // (rather than masquerading as "no such account").
    const address = Address.fromHex(id) catch return error.InvalidAddress;

    // Build account object with all requested fields (domains, registrations, etc.)
    const account_json = try builders.buildAccountJson(address, field.selections, .{
        .database = database,
        .depth = 1,
        .allocator = allocator,
        .loaders = ctx.loaders,
        .resolve = ctx.resolve,
    });
    return parser.FieldResult{ .json = account_json };
}

fn mapAccountOrderBy(order_by: ?[]const u8) db.AccountSortField {
    if (order_by) |s| {
        if (std.mem.eql(u8, s, "firstSeenBlock")) return .first_seen_block;
    }
    return .address;
}

/// Resolver for the `accounts(first, skip, where, orderBy)` list query.
/// Subgraph parity: paginated list of Account entities synthesized from the
/// `accounts` table (populated by indexer event handlers and one-shot backfill).
pub fn resolveAccounts(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));
    const allocator = ctx.allocator;

    const page = try common.parsePagination(field, 100);
    const first = page.first;
    const skip = page.skip;

    var filter_id: ?[]const u8 = null;
    var filter_id_in: ?[][]const u8 = null;
    var filter_seen_v1: ?bool = null;
    var filter_seen_v2: ?bool = null;

    if (common.getObjectArg(field, "where")) |where_args| {
        for (where_args) |a| {
            if (std.mem.eql(u8, a.name, "id_in")) {
                if (try common.parseStringListArg(a, allocator)) |v| filter_id_in = v;
                continue;
            }
            // Unknown args caught at parse time by schema_validator.zig.
            _ = common.matchStringArg(a, "id", &filter_id) or
                common.matchBoolArg(a, "seenV1", &filter_seen_v1) or
                common.matchBoolArg(a, "seenV2", &filter_seen_v2);
        }
    }
    defer if (filter_id_in) |ids| allocator.free(ids);

    const order_by = parser.getStringArg(field, "orderBy", null);
    const sort_field = mapAccountOrderBy(order_by);
    const order_dir = common.parseOrderDirection(field, db.OrderDir, .asc);

    const filters = db.AccountFilters{
        .id = filter_id,
        .id_in = filter_id_in,
        .seen_v1 = filter_seen_v1,
        .seen_v2 = filter_seen_v2,
    };

    const accounts = try database.getFilteredAccounts(filters, @intCast(skip), first, order_dir, sort_field);
    defer {
        for (accounts) |*a| {
            var m = a.*;
            m.deinit(database.allocator);
        }
        database.allocator.free(accounts);
    }

    // Page-batch the nested `domains` pages + their resolver records/texts:
    // one windowed query for the whole accounts page instead of one point
    // query per account (the N+1 behind multi-second accounts lists).
    domain_resolvers.prefetchDomainsForAccountsPage(database, allocator, ctx.loaders, accounts, field.selections);

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(allocator);
    try json.appendSlice(allocator, "[");
    for (accounts, 0..) |row, i| {
        if (i > 0) try json.appendSlice(allocator, ",");
        const addr = Address.fromHex(row.address) catch continue;
        const acct_json = try builders.buildAccountJson(addr, field.selections, .{
            .database = database,
            .depth = 0,
            .allocator = allocator,
            .loaders = ctx.loaders,
            .resolve = null, // list context: live resolution is single-name only, never per-row
        });
        defer allocator.free(acct_json);
        try json.appendSlice(allocator, acct_json);
    }
    try json.appendSlice(allocator, "]");
    return parser.FieldResult{ .json = try allocator.dupe(u8, json.items) };
}
