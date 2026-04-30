/// Account-related GraphQL resolvers
/// - resolveAccount: Single account lookup by id
const std = @import("std");
const common = @import("common.zig");
const db = common.db;
const models = common.models;
const Address = common.Address;
const parser = common.parser;
const builders = @import("../builders/builders.zig");

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
    });
    return parser.FieldResult{ .json = account_json };
}
