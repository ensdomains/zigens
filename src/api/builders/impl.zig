/// ENS Entity JSON Builders
///
/// This module contains all the JSON builder functions for ENS GraphQL entities:
/// - Domain builder (buildDomainJson)
/// - Account builder (buildAccountJson)
/// - Event builder (buildEventJson)
/// - Registration builder (buildRegistrationJson)
/// - Resolver builder (buildResolverJson)
///
/// These builders handle nested field resolution and use the generic json_builder
/// from lib/graphql for the actual JSON construction.
const std = @import("std");
const db = @import("../../storage/database.zig");
const models = @import("../../types/models.zig");
const Hash = @import("../../types/hash.zig").Hash;
const Address = @import("../../types/address.zig").Address;
const json_utils = @import("../../utils/json.zig");
const ens_normalize = @import("ens_normalize");

// Import generic GraphQL library
const parser = @import("../../lib/graphql/parser.zig");

// Import ENS-specific modules
const fields = @import("../ens_fields.zig");
const json_builder = @import("../json_builder.zig");
const loaders = @import("../loaders.zig");
const resolvers_mod = @import("../../storage/resolvers.zig");

/// Max uint64 value representing "no expiry" for subnames
const NO_EXPIRY: u64 = std.math.maxInt(u64);

/// Check if expiry value represents a valid expiry date (not 0 or max uint64)
pub fn hasValidExpiry(expiry: u64) bool {
    return expiry > 0 and expiry < NO_EXPIRY;
}

/// Context for nested field resolution
pub const NestedContext = struct {
    database: *db.Database,
    depth: u32,
    allocator: std.mem.Allocator,
    loaders: ?*anyopaque,
};

/// Helper to escape JSON strings
fn escapeJsonString(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    return json_utils.escapeString(allocator, s);
}

// ============================================================================
// EVENT BUILDER
// ============================================================================

/// Shared nested field handler: domain (used by Event and Registration)
fn domainNestedHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const event: *const models.Event = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    if (event.namehash) |nh| {
        const domain_opt = try database.getNameByNamehash(nh);
        if (domain_opt) |domain| {
            var domain_mut = domain;
            defer domain_mut.deinit(nested_ctx.allocator);
            return try buildDomainJson(&domain_mut, field.selections, .{
                .database = database,
                .depth = nested_ctx.depth + 1,
                .allocator = nested_ctx.allocator,
                .loaders = nested_ctx.loaders,
            });
        }
    }
    return try nested_ctx.allocator.dupe(u8, "null");
}

/// Event entity configuration
const EventEntityConfig = json_builder.EntityConfig{
    .type_name = "Event",
    .field_defs = &fields.EventFields,
    .nested_fields = &[_]json_builder.NestedFieldDef{
        .{ .name = "domain", .handler = domainNestedHandler },
    },
};

/// Build Event JSON with nested field selection support
pub fn buildEventJson(
    event: *const models.Event,
    selections: []const parser.Field,
    ctx: NestedContext,
) anyerror![]u8 {
    return json_builder.buildEntityJson(
        ctx.allocator,
        @ptrCast(@constCast(event)),
        selections,
        &EventEntityConfig,
        .{
            .database = ctx.database,
            .depth = ctx.depth,
            .allocator = ctx.allocator,
            .loaders = ctx.loaders,
        },
    );
}

// ============================================================================
// REGISTRATION BUILDER
// ============================================================================

/// Registration nested field handler: expiryDate
fn registrationExpiryDateHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    _ = field;
    const event: *const models.Event = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    // Try to parse duration from event.data JSON
    const parsed = std.json.parseFromSlice(std.json.Value, nested_ctx.allocator, event.data, .{}) catch {
        return try getExpiryFromDomain(event, database, nested_ctx.allocator);
    };
    defer parsed.deinit();

    if (parsed.value.object.get("duration")) |duration_val| {
        if (duration_val == .integer) {
            const duration: i64 = duration_val.integer;
            const expiry = event.timestamp + duration;
            return try std.fmt.allocPrint(nested_ctx.allocator, "{d}", .{expiry});
        }
    }

    return try getExpiryFromDomain(event, database, nested_ctx.allocator);
}

fn getExpiryFromDomain(event: *const models.Event, database: *db.Database, allocator: std.mem.Allocator) ![]u8 {
    if (event.namehash) |nh| {
        const domain_opt = database.getNameByNamehash(nh) catch null;
        if (domain_opt) |domain| {
            var domain_mut = domain;
            defer domain_mut.deinit(allocator);
            if (hasValidExpiry(domain_mut.expiry)) {
                return try std.fmt.allocPrint(allocator, "{d}", .{domain_mut.expiry});
            }
        }
    }
    return try allocator.dupe(u8, "null");
}

/// Registration nested field handler: registrant
fn registrationRegistrantHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const event: *const models.Event = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    const parsed = std.json.parseFromSlice(std.json.Value, nested_ctx.allocator, event.data, .{}) catch {
        return try nested_ctx.allocator.dupe(u8, "null");
    };
    defer parsed.deinit();

    const owner_str = if (parsed.value.object.get("owner")) |owner_val|
        if (owner_val == .string) owner_val.string else null
    else
        null;

    if (owner_str) |owner| {
        const owner_addr = Address.fromHex(owner) catch {
            return try nested_ctx.allocator.dupe(u8, "null");
        };

        return try buildAccountJson(owner_addr, field.selections, .{
            .database = database,
            .depth = nested_ctx.depth + 1,
            .allocator = nested_ctx.allocator,
            .loaders = nested_ctx.loaders,
        });
    }

    return try nested_ctx.allocator.dupe(u8, "null");
}

/// Registration entity configuration
const RegistrationEntityConfig = json_builder.EntityConfig{
    .type_name = "Registration",
    .field_defs = &fields.RegistrationFields,
    .nested_fields = &[_]json_builder.NestedFieldDef{
        .{ .name = "domain", .handler = domainNestedHandler },
        .{ .name = "expiryDate", .handler = registrationExpiryDateHandler },
        .{ .name = "registrant", .handler = registrationRegistrantHandler },
    },
};

/// Build Registration JSON with nested field selection support
pub fn buildRegistrationJson(
    event: *const models.Event,
    selections: []const parser.Field,
    ctx: NestedContext,
) anyerror![]u8 {
    return json_builder.buildEntityJson(
        ctx.allocator,
        @ptrCast(@constCast(event)),
        selections,
        &RegistrationEntityConfig,
        .{
            .database = ctx.database,
            .depth = ctx.depth,
            .allocator = ctx.allocator,
            .loaders = ctx.loaders,
        },
    );
}

// ============================================================================
// ACCOUNT BUILDER
// ============================================================================

/// Account nested field handler: domains
fn accountDomainsHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const addr: *const Address = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    const first_arg = parser.getIntArg(field, "first", 10) orelse 10;
    const skip_arg = parser.getIntArg(field, "skip", 0) orelse 0;

    const domains = try database.getAllNames(addr.*, @intCast(skip_arg), @intCast(first_arg));
    defer {
        for (domains) |*domain| {
            domain.deinit(nested_ctx.allocator);
        }
        nested_ctx.allocator.free(domains);
    }

    var json: std.ArrayList(u8) = .{};
    errdefer json.deinit(nested_ctx.allocator);
    const writer = json.writer(nested_ctx.allocator);

    try writer.writeAll("[");
    for (domains, 0..) |*domain, i| {
        if (i > 0) try writer.writeAll(",");
        const domain_json = try buildDomainJson(domain, field.selections, .{
            .database = database,
            .depth = nested_ctx.depth + 1,
            .allocator = nested_ctx.allocator,
            .loaders = nested_ctx.loaders,
        });
        defer nested_ctx.allocator.free(domain_json);
        try writer.writeAll(domain_json);
    }
    try writer.writeAll("]");

    return try nested_ctx.allocator.dupe(u8, json.items);
}

/// Account nested field handler: registrations
fn accountRegistrationsHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const addr: *const Address = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    const first_arg = parser.getIntArg(field, "first", 10) orelse 10;
    const skip_arg = parser.getIntArg(field, "skip", 0) orelse 0;

    const names = try database.getNamesByRegistrant(addr.*, @intCast(skip_arg), @intCast(first_arg));
    defer {
        for (names) |*name| {
            name.deinit(nested_ctx.allocator);
        }
        nested_ctx.allocator.free(names);
    }

    var json: std.ArrayList(u8) = .{};
    errdefer json.deinit(nested_ctx.allocator);
    const writer = json.writer(nested_ctx.allocator);

    try writer.writeAll("[");
    for (names, 0..) |*name, i| {
        if (i > 0) try writer.writeAll(",");
        const domain_json = try buildDomainJson(name, field.selections, .{
            .database = database,
            .depth = nested_ctx.depth + 1,
            .allocator = nested_ctx.allocator,
            .loaders = nested_ctx.loaders,
        });
        defer nested_ctx.allocator.free(domain_json);
        try writer.writeAll(domain_json);
    }
    try writer.writeAll("]");

    return try nested_ctx.allocator.dupe(u8, json.items);
}

/// Account entity configuration
const AccountEntityConfig = json_builder.EntityConfig{
    .type_name = "Account",
    .field_defs = &fields.AccountFields,
    .nested_fields = &[_]json_builder.NestedFieldDef{
        .{ .name = "domains", .handler = accountDomainsHandler },
        .{ .name = "registrations", .handler = accountRegistrationsHandler },
    },
};

/// Build Account JSON with nested field selection support
pub fn buildAccountJson(
    address: Address,
    selections: []const parser.Field,
    ctx: NestedContext,
) anyerror![]u8 {
    if (selections.len == 0) {
        const addr_hex = try address.toHex(ctx.allocator);
        defer ctx.allocator.free(addr_hex);
        return try std.fmt.allocPrint(ctx.allocator, "{{\"id\":\"{s}\"}}", .{addr_hex});
    }

    var addr_copy = address;
    return json_builder.buildEntityJson(
        ctx.allocator,
        @ptrCast(&addr_copy),
        selections,
        &AccountEntityConfig,
        .{
            .database = ctx.database,
            .depth = ctx.depth,
            .allocator = ctx.allocator,
            .loaders = ctx.loaders,
        },
    );
}

// ============================================================================
// RESOLVER BUILDER
// ============================================================================

/// Resolver nested field handler: addr
fn resolverAddrHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const rctx: *const fields.ResolverBuildContext = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    var addr_opt: ?[]const u8 = null;
    var owns_addr = false;

    var coin_type: u64 = 60;
    for (field.arguments) |arg| {
        if (std.mem.eql(u8, arg.name, "coinType")) {
            if (arg.value == .int) {
                coin_type = @intCast(arg.value.int);
            }
        }
    }

    if (coin_type == 60) {
        if (nested_ctx.loaders) |loaders_ptr| {
            const loader_ctx: *loaders.LoaderContext = @ptrCast(@alignCast(loaders_ptr));
            const loader = try loader_ctx.getResolverAddressLoader();
            addr_opt = try loader.load(rctx.namehash.bytes);
        } else {
            addr_opt = try database.getResolverAddress(rctx.namehash, 60);
            owns_addr = true;
        }
    } else {
        addr_opt = try database.getResolverAddress(rctx.namehash, coin_type);
        owns_addr = true;
    }
    defer if (owns_addr) if (addr_opt) |a| nested_ctx.allocator.free(a);

    if (addr_opt) |addr| {
        const escaped = try escapeJsonString(nested_ctx.allocator, addr);
        defer nested_ctx.allocator.free(escaped);
        return try std.fmt.allocPrint(nested_ctx.allocator, "\"{s}\"", .{escaped});
    }
    return try nested_ctx.allocator.dupe(u8, "null");
}

/// Resolver nested field handler: addresses
fn resolverAddressesHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const rctx: *const fields.ResolverBuildContext = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    const all_addresses = try resolvers_mod.getResolverAllAddresses(database, rctx.namehash);
    defer {
        for (all_addresses) |*addr| {
            addr.deinit(nested_ctx.allocator);
        }
        nested_ctx.allocator.free(all_addresses);
    }

    var want_coin_type = false;
    var want_address = false;
    for (field.selections) |subfield| {
        if (std.mem.eql(u8, subfield.name, "coinType")) want_coin_type = true;
        if (std.mem.eql(u8, subfield.name, "address")) want_address = true;
    }
    if (!want_coin_type and !want_address) {
        want_coin_type = true;
        want_address = true;
    }

    var json: std.ArrayList(u8) = .{};
    errdefer json.deinit(nested_ctx.allocator);
    const writer = json.writer(nested_ctx.allocator);

    try writer.writeAll("[");
    for (all_addresses, 0..) |coin_addr, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("{");
        var first_subfield = true;
        if (want_coin_type) {
            try writer.print("\"coinType\":{d}", .{coin_addr.coin_type});
            first_subfield = false;
        }
        if (want_address) {
            const escaped = try escapeJsonString(nested_ctx.allocator, coin_addr.address);
            defer nested_ctx.allocator.free(escaped);
            if (!first_subfield) try writer.writeAll(",");
            try writer.print("\"address\":\"{s}\"", .{escaped});
        }
        try writer.writeAll("}");
    }
    try writer.writeAll("]");

    return try nested_ctx.allocator.dupe(u8, json.items);
}

/// Resolver nested field handler: contentHash
fn resolverContentHashHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    _ = field;
    const rctx: *const fields.ResolverBuildContext = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    var hash_opt: ?[]const u8 = null;
    var owns_hash = false;

    if (nested_ctx.loaders) |loaders_ptr| {
        const loader_ctx: *loaders.LoaderContext = @ptrCast(@alignCast(loaders_ptr));
        const loader = try loader_ctx.getContentHashLoader();
        hash_opt = try loader.load(rctx.namehash.bytes);
    } else {
        hash_opt = try database.getResolverContentHash(rctx.namehash);
        owns_hash = true;
    }
    defer if (owns_hash) if (hash_opt) |h| nested_ctx.allocator.free(h);

    if (hash_opt) |hash| {
        const escaped = try escapeJsonString(nested_ctx.allocator, hash);
        defer nested_ctx.allocator.free(escaped);
        return try std.fmt.allocPrint(nested_ctx.allocator, "\"{s}\"", .{escaped});
    }
    return try nested_ctx.allocator.dupe(u8, "null");
}

/// Resolver nested field handler: texts
fn resolverTextsHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    _ = field;
    const rctx: *const fields.ResolverBuildContext = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    var json: std.ArrayList(u8) = .{};
    errdefer json.deinit(nested_ctx.allocator);
    const writer = json.writer(nested_ctx.allocator);

    if (nested_ctx.loaders) |loaders_ptr| {
        const loader_ctx: *loaders.LoaderContext = @ptrCast(@alignCast(loaders_ptr));
        const loader = try loader_ctx.getTextRecordsLoader();
        const text_records = try loader.load(rctx.namehash.bytes);

        try writer.writeAll("[");
        for (text_records.records, 0..) |record, i| {
            if (i > 0) try writer.writeAll(",");
            const escaped = try escapeJsonString(nested_ctx.allocator, record.key);
            defer nested_ctx.allocator.free(escaped);
            try writer.print("\"{s}\"", .{escaped});
        }
        try writer.writeAll("]");
    } else {
        const text_keys = try database.getResolverTextKeys(rctx.namehash);
        defer {
            for (text_keys) |key| nested_ctx.allocator.free(key);
            nested_ctx.allocator.free(text_keys);
        }
        try writer.writeAll("[");
        for (text_keys, 0..) |key, i| {
            if (i > 0) try writer.writeAll(",");
            const escaped = try escapeJsonString(nested_ctx.allocator, key);
            defer nested_ctx.allocator.free(escaped);
            try writer.print("\"{s}\"", .{escaped});
        }
        try writer.writeAll("]");
    }

    return try nested_ctx.allocator.dupe(u8, json.items);
}

/// Resolver nested field handler: text
fn resolverTextHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const rctx: *const fields.ResolverBuildContext = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    var key_arg: ?[]const u8 = null;
    for (field.arguments) |arg| {
        if (std.mem.eql(u8, arg.name, "key") and arg.value == .string) {
            key_arg = arg.value.string;
        }
    }

    if (key_arg) |key| {
        var text_value: ?[]const u8 = null;
        var owns_value = false;

        if (nested_ctx.loaders) |loaders_ptr| {
            const loader_ctx: *loaders.LoaderContext = @ptrCast(@alignCast(loaders_ptr));
            const loader = try loader_ctx.getTextRecordsLoader();
            const text_records = try loader.load(rctx.namehash.bytes);

            for (text_records.records) |record| {
                if (std.mem.eql(u8, record.key, key)) {
                    text_value = record.value;
                    break;
                }
            }
        } else {
            text_value = try database.getResolverText(rctx.namehash, key);
            owns_value = true;
        }
        defer if (owns_value) if (text_value) |val| nested_ctx.allocator.free(val);

        if (text_value) |val| {
            const escaped = try escapeJsonString(nested_ctx.allocator, val);
            defer nested_ctx.allocator.free(escaped);
            return try std.fmt.allocPrint(nested_ctx.allocator, "\"{s}\"", .{escaped});
        }
    }
    return try nested_ctx.allocator.dupe(u8, "null");
}

/// Resolver entity configuration
const ResolverBuildEntityConfig = json_builder.EntityConfig{
    .type_name = "Resolver",
    .field_defs = &fields.ResolverBuildFields,
    .nested_fields = &[_]json_builder.NestedFieldDef{
        .{ .name = "addr", .handler = resolverAddrHandler },
        .{ .name = "addresses", .handler = resolverAddressesHandler },
        .{ .name = "contentHash", .handler = resolverContentHashHandler },
        .{ .name = "texts", .handler = resolverTextsHandler },
        .{ .name = "text", .handler = resolverTextHandler },
    },
};

/// Build Resolver JSON with nested field selection support
pub fn buildResolverJson(
    resolver: Address,
    domain_namehash: Hash,
    selections: []const parser.Field,
    ctx: NestedContext,
) anyerror![]u8 {
    if (selections.len == 0) {
        const addr_hex = try resolver.toHex(ctx.allocator);
        defer ctx.allocator.free(addr_hex);
        return try std.fmt.allocPrint(ctx.allocator, "{{\"address\":\"{s}\"}}", .{addr_hex});
    }

    var rctx = fields.ResolverBuildContext{
        .resolver = resolver,
        .namehash = domain_namehash,
    };

    return json_builder.buildEntityJson(
        ctx.allocator,
        @ptrCast(&rctx),
        selections,
        &ResolverBuildEntityConfig,
        .{
            .database = ctx.database,
            .depth = ctx.depth,
            .allocator = ctx.allocator,
            .loaders = ctx.loaders,
        },
    );
}

// ============================================================================
// DOMAIN BUILDER
// ============================================================================

/// Domain nested field handler: owner
fn domainOwnerHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const domain: *const models.Name = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));
    return try buildAccountJson(domain.owner, field.selections, .{
        .database = database,
        .depth = nested_ctx.depth + 1,
        .allocator = nested_ctx.allocator,
        .loaders = nested_ctx.loaders,
    });
}

/// Domain nested field handler: registrant
fn domainRegistrantHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const domain: *const models.Name = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));
    return try buildAccountJson(domain.registrant, field.selections, .{
        .database = database,
        .depth = nested_ctx.depth + 1,
        .allocator = nested_ctx.allocator,
        .loaders = nested_ctx.loaders,
    });
}

/// Domain nested field handler: resolvedAddress
fn domainResolvedAddressHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const domain: *const models.Name = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    var resolved_addr_opt: ?[]const u8 = null;
    var owns_addr = false;

    if (nested_ctx.loaders) |loaders_ptr| {
        const loader_ctx: *loaders.LoaderContext = @ptrCast(@alignCast(loaders_ptr));
        const loader = try loader_ctx.getResolverAddressLoader();
        resolved_addr_opt = try loader.load(domain.namehash.bytes);
    } else {
        resolved_addr_opt = try database.getResolverAddress(domain.namehash, 60);
        owns_addr = true;
    }
    defer if (owns_addr) if (resolved_addr_opt) |a| nested_ctx.allocator.free(a);

    if (resolved_addr_opt) |addr_str| {
        if (Address.fromHex(addr_str)) |addr| {
            return try buildAccountJson(addr, field.selections, .{
                .database = database,
                .depth = nested_ctx.depth + 1,
                .allocator = nested_ctx.allocator,
                .loaders = nested_ctx.loaders,
            });
        } else |_| {
            return try nested_ctx.allocator.dupe(u8, "null");
        }
    }
    return try nested_ctx.allocator.dupe(u8, "null");
}

/// Domain nested field handler: resolver
fn domainResolverHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const domain: *const models.Name = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));
    if (!domain.resolver.isZero()) {
        return try buildResolverJson(domain.resolver, domain.namehash, field.selections, .{
            .database = database,
            .depth = nested_ctx.depth + 1,
            .allocator = nested_ctx.allocator,
            .loaders = nested_ctx.loaders,
        });
    }
    return try nested_ctx.allocator.dupe(u8, "null");
}

/// Domain nested field handler: parent
fn domainParentHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const domain: *const models.Name = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));
    if (!domain.parent_namehash.isZero()) {
        const parent_opt = try database.getNameByNamehash(domain.parent_namehash);
        if (parent_opt) |parent| {
            var parent_mut = parent;
            defer parent_mut.deinit(nested_ctx.allocator);
            return try buildDomainJson(&parent_mut, field.selections, .{
                .database = database,
                .depth = nested_ctx.depth + 1,
                .allocator = nested_ctx.allocator,
                .loaders = nested_ctx.loaders,
            });
        }
    }
    return try nested_ctx.allocator.dupe(u8, "null");
}

/// Domain nested field handler: subdomains
fn domainSubdomainsHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const domain: *const models.Name = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    const first_arg = parser.getIntArg(field, "first", 10) orelse 10;
    const skip_arg = parser.getIntArg(field, "skip", 0) orelse 0;

    var json: std.ArrayList(u8) = .{};
    errdefer json.deinit(nested_ctx.allocator);
    const writer = json.writer(nested_ctx.allocator);

    try writer.writeAll("[");

    if (domain.name) |parent_name| {
        const subdomains = try database.getSubdomains(parent_name, @intCast(skip_arg), @intCast(first_arg));
        defer {
            for (subdomains) |*n| n.deinit(nested_ctx.allocator);
            nested_ctx.allocator.free(subdomains);
        }

        for (subdomains, 0..) |*subdomain, i| {
            if (i > 0) try writer.writeAll(",");
            const subdomain_json = try buildDomainJson(subdomain, field.selections, .{
                .database = database,
                .depth = nested_ctx.depth + 1,
                .allocator = nested_ctx.allocator,
                .loaders = nested_ctx.loaders,
            });
            defer nested_ctx.allocator.free(subdomain_json);
            try writer.writeAll(subdomain_json);
        }
    }

    try writer.writeAll("]");
    return try nested_ctx.allocator.dupe(u8, json.items);
}

/// Domain nested field handler: events
fn domainEventsHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const domain: *const models.Name = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    const first_arg = parser.getIntArg(field, "first", 100) orelse 100;

    const namehash_hex = try domain.namehash.toHex(nested_ctx.allocator);
    defer nested_ctx.allocator.free(namehash_hex);

    var filter_opts = db.EventFilterOptions{
        .namehash = namehash_hex,
        .limit = @intCast(first_arg),
    };

    var event_types_list: std.ArrayList([]const u8) = .{};
    defer event_types_list.deinit(nested_ctx.allocator);

    var normalized_contract_address: ?[]u8 = null;
    defer if (normalized_contract_address) |addr| nested_ctx.allocator.free(addr);

    for (field.arguments) |arg| {
        if (std.mem.eql(u8, arg.name, "where") and arg.value == .object) {
            for (arg.value.object) |filter_arg| {
                if (std.mem.eql(u8, filter_arg.name, "type") and filter_arg.value == .string) {
                    filter_opts.event_type = filter_arg.value.string;
                } else if (std.mem.eql(u8, filter_arg.name, "type_in") and filter_arg.value == .list) {
                    for (filter_arg.value.list) |item| {
                        if (item == .string) try event_types_list.append(nested_ctx.allocator, item.string);
                    }
                    if (event_types_list.items.len > 0) filter_opts.event_types = event_types_list.items;
                } else if (std.mem.eql(u8, filter_arg.name, "contractAddress") and filter_arg.value == .string) {
                    const addr = Address.fromHex(filter_arg.value.string) catch continue;
                    normalized_contract_address = try addr.toHex(nested_ctx.allocator);
                    filter_opts.contract_address = normalized_contract_address;
                } else if (std.mem.eql(u8, filter_arg.name, "blockNumber_gt") and filter_arg.value == .int) {
                    filter_opts.block_number_gt = filter_arg.value.int;
                } else if (std.mem.eql(u8, filter_arg.name, "blockNumber_lt") and filter_arg.value == .int) {
                    filter_opts.block_number_lt = filter_arg.value.int;
                } else if (std.mem.eql(u8, filter_arg.name, "timestamp_gt") and filter_arg.value == .int) {
                    filter_opts.timestamp_gt = filter_arg.value.int;
                } else if (std.mem.eql(u8, filter_arg.name, "timestamp_lt") and filter_arg.value == .int) {
                    filter_opts.timestamp_lt = filter_arg.value.int;
                }
            }
        }
    }

    const domain_events = try database.getEventsFiltered(filter_opts);
    defer {
        for (domain_events) |*e| e.deinit(nested_ctx.allocator);
        nested_ctx.allocator.free(domain_events);
    }

    var json: std.ArrayList(u8) = .{};
    errdefer json.deinit(nested_ctx.allocator);
    const writer = json.writer(nested_ctx.allocator);

    try writer.writeAll("[");
    for (domain_events, 0..) |*event, i| {
        if (i > 0) try writer.writeAll(",");
        const event_json = try buildEventJson(event, field.selections, .{
            .database = database,
            .depth = nested_ctx.depth + 1,
            .allocator = nested_ctx.allocator,
            .loaders = nested_ctx.loaders,
        });
        defer nested_ctx.allocator.free(event_json);
        try writer.writeAll(event_json);
    }
    try writer.writeAll("]");

    return try nested_ctx.allocator.dupe(u8, json.items);
}

/// Domain nested field handler: domain (recursive)
fn domainDomainHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const domain: *const models.Name = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));
    return try buildDomainJson(domain, field.selections, .{
        .database = database,
        .depth = nested_ctx.depth + 1,
        .allocator = nested_ctx.allocator,
        .loaders = nested_ctx.loaders,
    });
}

/// Domain nested field handler: expiryDate
fn domainExpiryDateHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    _ = field;
    const domain: *const models.Name = @ptrCast(@alignCast(ctx));
    if (fields.hasValidExpiry(domain.expiry)) {
        return try std.fmt.allocPrint(nested_ctx.allocator, "{d}", .{domain.expiry});
    }
    return try nested_ctx.allocator.dupe(u8, "null");
}

/// Domain nested field handler: normalizedName
fn domainNormalizedNameHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    _ = field;
    const domain: *const models.Name = @ptrCast(@alignCast(ctx));
    if (domain.name) |name| {
        if (ens_normalize.normalize(nested_ctx.allocator, name)) |normalized| {
            defer nested_ctx.allocator.free(normalized);
            const escaped = try escapeJsonString(nested_ctx.allocator, normalized);
            defer nested_ctx.allocator.free(escaped);
            return try std.fmt.allocPrint(nested_ctx.allocator, "\"{s}\"", .{escaped});
        } else |_| {
            return try nested_ctx.allocator.dupe(u8, "null");
        }
    }
    return try nested_ctx.allocator.dupe(u8, "null");
}

/// Domain nested field handler: isNormalized
fn domainIsNormalizedHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    _ = field;
    const domain: *const models.Name = @ptrCast(@alignCast(ctx));
    if (domain.name) |name| {
        if (ens_normalize.normalize(nested_ctx.allocator, name)) |normalized| {
            defer nested_ctx.allocator.free(normalized);
            return try nested_ctx.allocator.dupe(u8, if (std.mem.eql(u8, name, normalized)) "true" else "false");
        } else |_| {
            return try nested_ctx.allocator.dupe(u8, "false");
        }
    }
    return try nested_ctx.allocator.dupe(u8, "false");
}

/// Domain nested field handler: subdomainsCount (aggregation)
fn domainSubdomainsCountHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    _ = field;
    const domain: *const models.Name = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    if (domain.name) |parent_name| {
        const count = try database.countDirectSubdomains(parent_name);
        return try std.fmt.allocPrint(nested_ctx.allocator, "{d}", .{count});
    }
    return try nested_ctx.allocator.dupe(u8, "0");
}

/// Domain nested field handler: eventsCount (aggregation)
fn domainEventsCountHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    _ = field;
    const domain: *const models.Name = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    const count = try database.countEventsByNamehash(domain.namehash);
    return try std.fmt.allocPrint(nested_ctx.allocator, "{d}", .{count});
}

/// Domain nested field handler: subdomainConnection (Relay-style connection)
fn domainSubdomainConnectionHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const domain: *const models.Name = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));
    const allocator = nested_ctx.allocator;

    const first_arg = parser.getIntArg(field, "first", 10) orelse 10;
    const limit: u32 = @intCast(@min(first_arg, 100));

    var json: std.ArrayList(u8) = .{};
    errdefer json.deinit(allocator);

    if (domain.name) |parent_name| {
        // Check if totalCount is requested
        var wants_total_count = false;
        for (field.selections) |*sel| {
            if (std.mem.eql(u8, sel.name, "totalCount")) {
                wants_total_count = true;
                break;
            }
        }

        // Fetch one extra to determine hasNextPage
        const subdomains = try database.getSubdomains(parent_name, 0, limit + 1);
        defer {
            for (subdomains) |*n| n.deinit(allocator);
            allocator.free(subdomains);
        }

        const has_next = subdomains.len > limit;
        const actual_count = @min(subdomains.len, limit);

        // Extract node selections
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

        // Build connection JSON
        try json.appendSlice(allocator, "{");
        var first_field = true;

        if (wants_total_count) {
            const total_count = try database.countDirectSubdomains(parent_name);
            const count_str = try std.fmt.allocPrint(allocator, "{d}", .{total_count});
            defer allocator.free(count_str);
            try json.appendSlice(allocator, "\"totalCount\":");
            try json.appendSlice(allocator, count_str);
            first_field = false;
        }

        if (!first_field) try json.appendSlice(allocator, ",");
        try json.appendSlice(allocator, "\"pageInfo\":{\"hasNextPage\":");
        try json.appendSlice(allocator, if (has_next) "true" else "false");
        try json.appendSlice(allocator, ",\"hasPreviousPage\":false}");

        try json.appendSlice(allocator, ",\"edges\":[");
        for (subdomains[0..actual_count], 0..) |*subdomain, i| {
            if (i > 0) try json.appendSlice(allocator, ",");

            // Build cursor from namehash
            const cursor_hex = try subdomain.namehash.toHex(allocator);
            defer allocator.free(cursor_hex);

            try json.appendSlice(allocator, "{\"cursor\":\"");
            try json.appendSlice(allocator, cursor_hex);
            try json.appendSlice(allocator, "\",\"node\":");

            const subdomain_json = try buildDomainJson(subdomain, node_selections, .{
                .database = database,
                .depth = nested_ctx.depth + 1,
                .allocator = allocator,
                .loaders = nested_ctx.loaders,
            });
            defer allocator.free(subdomain_json);
            try json.appendSlice(allocator, subdomain_json);
            try json.appendSlice(allocator, "}");
        }
        try json.appendSlice(allocator, "]}");
    } else {
        try json.appendSlice(allocator, "{\"pageInfo\":{\"hasNextPage\":false,\"hasPreviousPage\":false},\"edges\":[]}");
    }

    return try allocator.dupe(u8, json.items);
}

/// Domain nested field handler: eventsConnection (Relay-style connection)
fn domainEventsConnectionHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const domain: *const models.Name = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));
    const allocator = nested_ctx.allocator;

    const first_arg = parser.getIntArg(field, "first", 10) orelse 10;
    const limit: u32 = @intCast(@min(first_arg, 100));

    // Check if totalCount is requested
    var wants_total_count = false;
    for (field.selections) |*sel| {
        if (std.mem.eql(u8, sel.name, "totalCount")) {
            wants_total_count = true;
            break;
        }
    }

    // Fetch events
    const namehash_hex = try domain.namehash.toHex(allocator);
    defer allocator.free(namehash_hex);

    const filter_opts = db.EventFilterOptions{
        .namehash = namehash_hex,
        .limit = limit + 1,
    };

    const events = try database.getEventsFiltered(filter_opts);
    defer {
        for (events) |*e| e.deinit(allocator);
        allocator.free(events);
    }

    const has_next = events.len > limit;
    const actual_count = @min(events.len, limit);

    // Extract node selections
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

    var json: std.ArrayList(u8) = .{};
    errdefer json.deinit(allocator);

    // Build connection JSON
    try json.appendSlice(allocator, "{");
    var first_field = true;

    if (wants_total_count) {
        const total_count = try database.countEventsByNamehash(domain.namehash);
        const count_str = try std.fmt.allocPrint(allocator, "{d}", .{total_count});
        defer allocator.free(count_str);
        try json.appendSlice(allocator, "\"totalCount\":");
        try json.appendSlice(allocator, count_str);
        first_field = false;
    }

    if (!first_field) try json.appendSlice(allocator, ",");
    try json.appendSlice(allocator, "\"pageInfo\":{\"hasNextPage\":");
    try json.appendSlice(allocator, if (has_next) "true" else "false");
    try json.appendSlice(allocator, ",\"hasPreviousPage\":false}");

    try json.appendSlice(allocator, ",\"edges\":[");
    for (events[0..actual_count], 0..) |*event, i| {
        if (i > 0) try json.appendSlice(allocator, ",");

        // Build cursor from tx_hash-log_index
        const tx_hash_hex = try event.tx_hash.toHex(allocator);
        defer allocator.free(tx_hash_hex);
        const cursor = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ tx_hash_hex, event.log_index });
        defer allocator.free(cursor);

        try json.appendSlice(allocator, "{\"cursor\":\"");
        try json.appendSlice(allocator, cursor);
        try json.appendSlice(allocator, "\",\"node\":");

        const event_json = try buildEventJson(event, node_selections, .{
            .database = database,
            .depth = nested_ctx.depth + 1,
            .allocator = allocator,
            .loaders = nested_ctx.loaders,
        });
        defer allocator.free(event_json);
        try json.appendSlice(allocator, event_json);
        try json.appendSlice(allocator, "}");
    }
    try json.appendSlice(allocator, "]}");

    return try allocator.dupe(u8, json.items);
}

/// Domain entity configuration
const DomainBuildEntityConfig = json_builder.EntityConfig{
    .type_name = "Domain",
    .field_defs = &fields.DomainBuildFields,
    .nested_fields = &[_]json_builder.NestedFieldDef{
        .{ .name = "owner", .handler = domainOwnerHandler },
        .{ .name = "registrant", .handler = domainRegistrantHandler },
        .{ .name = "resolvedAddress", .handler = domainResolvedAddressHandler },
        .{ .name = "resolver", .handler = domainResolverHandler },
        .{ .name = "parent", .handler = domainParentHandler },
        .{ .name = "subdomains", .handler = domainSubdomainsHandler },
        .{ .name = "subdomainsCount", .handler = domainSubdomainsCountHandler },
        .{ .name = "subdomainConnection", .handler = domainSubdomainConnectionHandler },
        .{ .name = "events", .handler = domainEventsHandler },
        .{ .name = "eventsCount", .handler = domainEventsCountHandler },
        .{ .name = "eventsConnection", .handler = domainEventsConnectionHandler },
        .{ .name = "domain", .handler = domainDomainHandler },
        .{ .name = "expiryDate", .handler = domainExpiryDateHandler },
        .{ .name = "normalizedName", .handler = domainNormalizedNameHandler },
        .{ .name = "isNormalized", .handler = domainIsNormalizedHandler },
    },
};

/// Build Domain JSON with nested field selection support
pub fn buildDomainJson(
    domain: *const models.Name,
    selections: []const parser.Field,
    ctx: NestedContext,
) anyerror![]u8 {
    if (selections.len == 0) {
        const escaped = try escapeJsonString(ctx.allocator, domain.name orelse "[unknown]");
        defer ctx.allocator.free(escaped);
        return try std.fmt.allocPrint(ctx.allocator, "{{\"id\":\"{s}\"}}", .{escaped});
    }

    return json_builder.buildEntityJson(
        ctx.allocator,
        @ptrCast(@constCast(domain)),
        selections,
        &DomainBuildEntityConfig,
        .{
            .database = ctx.database,
            .depth = ctx.depth,
            .allocator = ctx.allocator,
            .loaders = ctx.loaders,
        },
    );
}
