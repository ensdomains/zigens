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
const jw = @import("../../lib/graphql/json_writer.zig");

// Import ENS-specific modules
const fields = @import("../ens_fields.zig");
const json_builder = @import("../json_builder.zig");
const loaders = @import("../loaders.zig");
const resolvers_mod = @import("../../storage/resolvers.zig");
const api_common = @import("../common.zig");

/// Context for nested field resolution
pub const NestedContext = struct {
    database: *db.Database,
    depth: u32,
    allocator: std.mem.Allocator,
    loaders: ?*anyopaque,
};

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
            if (fields.hasValidExpiry(domain_mut.expiry)) {
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

    const page = api_common.parsePagination(field, 10);

    const domains = try database.getAllNames(addr.*, page.skip, page.first);
    defer {
        for (domains) |*domain| {
            domain.deinit(nested_ctx.allocator);
        }
        nested_ctx.allocator.free(domains);
    }

    var json: std.ArrayList(u8) = .{};
    errdefer json.deinit(nested_ctx.allocator);
    var arr = try jw.arrayOn(json.writer(nested_ctx.allocator));
    for (domains) |*domain| {
        const domain_json = try buildDomainJson(domain, field.selections, .{
            .database = database,
            .depth = nested_ctx.depth + 1,
            .allocator = nested_ctx.allocator,
            .loaders = nested_ctx.loaders,
        });
        defer nested_ctx.allocator.free(domain_json);
        try arr.itemRaw(domain_json);
    }
    try arr.end();

    return try nested_ctx.allocator.dupe(u8, json.items);
}

/// Account nested field handler: registrations
fn accountRegistrationsHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const addr: *const Address = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    const page = api_common.parsePagination(field, 10);

    const names = try database.getNamesByRegistrant(addr.*, page.skip, page.first);
    defer {
        for (names) |*name| {
            name.deinit(nested_ctx.allocator);
        }
        nested_ctx.allocator.free(names);
    }

    var json: std.ArrayList(u8) = .{};
    errdefer json.deinit(nested_ctx.allocator);
    var arr = try jw.arrayOn(json.writer(nested_ctx.allocator));
    for (names) |*name| {
        const domain_json = try buildDomainJson(name, field.selections, .{
            .database = database,
            .depth = nested_ctx.depth + 1,
            .allocator = nested_ctx.allocator,
            .loaders = nested_ctx.loaders,
        });
        defer nested_ctx.allocator.free(domain_json);
        try arr.itemRaw(domain_json);
    }
    try arr.end();

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

    // Only return records set by the CURRENTLY AUTHORITATIVE resolver.
    // A migrated V1 name may have legacy addr records from its old V1 resolver in the
    // resolver_addresses table; those must not shadow the (possibly empty) V2 resolver state.
    addr_opt = try database.getAddressRecord(rctx.resolver, rctx.namehash, coin_type);
    owns_addr = true;
    _ = loaders; // DataLoader path disabled for correctness; per-resolver filter precludes namehash-only batching.
    defer if (owns_addr) if (addr_opt) |a| nested_ctx.allocator.free(a);

    if (addr_opt) |addr| {
        const escaped = try json_utils.escapeString(nested_ctx.allocator, addr);
        defer nested_ctx.allocator.free(escaped);
        return try std.fmt.allocPrint(nested_ctx.allocator, "\"{s}\"", .{escaped});
    }
    return try nested_ctx.allocator.dupe(u8, "null");
}

/// Resolver nested field handler: addresses
fn resolverAddressesHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const rctx: *const fields.ResolverBuildContext = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    const all_addresses = try database.getAddressRecords(rctx.resolver, rctx.namehash);
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
    var arr = try jw.arrayOn(json.writer(nested_ctx.allocator));
    for (all_addresses) |coin_addr| {
        var obj = try arr.beginObject();
        if (want_coin_type) try obj.fieldInt("coinType", coin_addr.coin_type);
        if (want_address) try obj.fieldStr("address", coin_addr.address, nested_ctx.allocator);
        try obj.end();
    }
    try arr.end();

    return try nested_ctx.allocator.dupe(u8, json.items);
}

/// Resolver nested field handler: contentHash
fn resolverContentHashHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    _ = field;
    const rctx: *const fields.ResolverBuildContext = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    // DataLoader path disabled — it batches by namehash only, which would leak
    // legacy-resolver records for migrated names. Per-resolver filter precludes namehash-only batching.
    const hash_opt = try database.getContentHashRecord(rctx.resolver, rctx.namehash);
    defer if (hash_opt) |h| nested_ctx.allocator.free(h);

    if (hash_opt) |hash| {
        const escaped = try json_utils.escapeString(nested_ctx.allocator, hash);
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

    // DataLoader path disabled — namehash-only batching would leak legacy-resolver records for migrated names.
    const text_keys = try database.getTextRecordKeys(rctx.resolver, rctx.namehash);
    defer {
        for (text_keys) |key| nested_ctx.allocator.free(key);
        nested_ctx.allocator.free(text_keys);
    }

    var json: std.ArrayList(u8) = .{};
    errdefer json.deinit(nested_ctx.allocator);
    var arr = try jw.arrayOn(json.writer(nested_ctx.allocator));
    for (text_keys) |key| try arr.itemStr(key, nested_ctx.allocator);
    try arr.end();

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
        // DataLoader path disabled — namehash-only batching would leak legacy-resolver records for migrated names.
        const text_value = try database.getTextRecord(rctx.resolver, rctx.namehash, key);
        defer if (text_value) |val| nested_ctx.allocator.free(val);

        if (text_value) |val| {
            const escaped = try json_utils.escapeString(nested_ctx.allocator, val);
            defer nested_ctx.allocator.free(escaped);
            return try std.fmt.allocPrint(nested_ctx.allocator, "\"{s}\"", .{escaped});
        }
    }
    return try nested_ctx.allocator.dupe(u8, "null");
}

/// Resolver nested field handler: pubkey
fn resolverPubkeyHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    _ = field;
    const rctx: *const fields.ResolverBuildContext = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    var pubkey_opt = try database.getPubkeyRecord(rctx.resolver, rctx.namehash);
    if (pubkey_opt) |*pubkey| {
        defer pubkey.deinit(nested_ctx.allocator);
        const escaped_x = try json_utils.escapeString(nested_ctx.allocator, pubkey.x);
        defer nested_ctx.allocator.free(escaped_x);
        const escaped_y = try json_utils.escapeString(nested_ctx.allocator, pubkey.y);
        defer nested_ctx.allocator.free(escaped_y);
        return try std.fmt.allocPrint(nested_ctx.allocator, "{{\"x\":\"{s}\",\"y\":\"{s}\"}}", .{ escaped_x, escaped_y });
    }
    return try nested_ctx.allocator.dupe(u8, "null");
}

/// Resolver nested field handler: abis (content types)
fn resolverAbisHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    _ = field;
    const rctx: *const fields.ResolverBuildContext = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    const content_types = try database.getAbiContentTypes(rctx.resolver, rctx.namehash);
    defer nested_ctx.allocator.free(content_types);

    var json_buf: std.ArrayList(u8) = .{};
    errdefer json_buf.deinit(nested_ctx.allocator);
    var arr = try jw.arrayOn(json_buf.writer(nested_ctx.allocator));
    for (content_types) |ct| try arr.itemInt(ct);
    try arr.end();

    return try nested_ctx.allocator.dupe(u8, json_buf.items);
}

/// Resolver nested field handler: reverseName
fn resolverReverseNameHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    _ = field;
    const rctx: *const fields.ResolverBuildContext = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    if (try database.getReverseNameRecord(rctx.resolver, rctx.namehash)) |name_val| {
        defer nested_ctx.allocator.free(name_val);
        const escaped = try json_utils.escapeString(nested_ctx.allocator, name_val);
        defer nested_ctx.allocator.free(escaped);
        return try std.fmt.allocPrint(nested_ctx.allocator, "\"{s}\"", .{escaped});
    }
    return try nested_ctx.allocator.dupe(u8, "null");
}

/// Resolver nested field handler: interfaces
fn resolverInterfacesHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const rctx: *const fields.ResolverBuildContext = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    const ifaces = try database.getInterfaceRecords(rctx.resolver, rctx.namehash);
    defer {
        for (ifaces) |*iface| iface.deinit(nested_ctx.allocator);
        nested_ctx.allocator.free(ifaces);
    }

    var want_interface_id = false;
    var want_implementer = false;
    for (field.selections) |subfield| {
        if (std.mem.eql(u8, subfield.name, "interfaceId")) want_interface_id = true;
        if (std.mem.eql(u8, subfield.name, "implementer")) want_implementer = true;
    }
    if (!want_interface_id and !want_implementer) {
        want_interface_id = true;
        want_implementer = true;
    }

    var json_buf: std.ArrayList(u8) = .{};
    errdefer json_buf.deinit(nested_ctx.allocator);
    var arr = try jw.arrayOn(json_buf.writer(nested_ctx.allocator));
    for (ifaces) |iface| {
        var obj = try arr.beginObject();
        if (want_interface_id) try obj.fieldStr("interfaceId", iface.interface_id, nested_ctx.allocator);
        if (want_implementer) try obj.fieldStr("implementer", iface.implementer, nested_ctx.allocator);
        try obj.end();
    }
    try arr.end();

    return try nested_ctx.allocator.dupe(u8, json_buf.items);
}

/// Resolver nested field handler: aliases
fn resolverAliasesHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const rctx: *const fields.ResolverBuildContext = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    const alias_records = try database.getResolverAliases(rctx.resolver);
    defer {
        for (alias_records) |*r| r.deinit(nested_ctx.allocator);
        nested_ctx.allocator.free(alias_records);
    }

    var want_from = false;
    var want_to = false;
    for (field.selections) |subfield| {
        if (std.mem.eql(u8, subfield.name, "fromName")) want_from = true;
        if (std.mem.eql(u8, subfield.name, "toName")) want_to = true;
    }
    if (!want_from and !want_to) {
        want_from = true;
        want_to = true;
    }

    var json_buf: std.ArrayList(u8) = .{};
    errdefer json_buf.deinit(nested_ctx.allocator);
    var arr = try jw.arrayOn(json_buf.writer(nested_ctx.allocator));
    for (alias_records) |record| {
        var obj = try arr.beginObject();
        if (want_from) try obj.fieldStr("fromName", record.from_name, nested_ctx.allocator);
        if (want_to) try obj.fieldStr("toName", record.to_name, nested_ctx.allocator);
        try obj.end();
    }
    try arr.end();

    return try nested_ctx.allocator.dupe(u8, json_buf.items);
}

/// Resolver nested field handler: version
fn resolverVersionHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    _ = field;
    const rctx: *const fields.ResolverBuildContext = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    if (try database.getNodeRecordVersion(rctx.resolver, rctx.namehash)) |version| {
        return try std.fmt.allocPrint(nested_ctx.allocator, "{d}", .{version});
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
        .{ .name = "pubkey", .handler = resolverPubkeyHandler },
        .{ .name = "abis", .handler = resolverAbisHandler },
        .{ .name = "reverseName", .handler = resolverReverseNameHandler },
        .{ .name = "interfaces", .handler = resolverInterfacesHandler },
        .{ .name = "aliases", .handler = resolverAliasesHandler },
        .{ .name = "version", .handler = resolverVersionHandler },
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
/// Returns the ETH address set by the domain's CURRENT resolver. For migrated V1 names,
/// legacy V1 resolver records must not shadow the V2 resolver's state — we filter by
/// the currently authoritative resolver to match on-chain semantics.
fn domainResolvedAddressHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const domain: *const models.Name = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    // If the domain has no resolver set, there can be no resolved address.
    if (domain.resolver.isZero()) {
        return try nested_ctx.allocator.dupe(u8, "null");
    }

    const resolved_addr_opt = try database.getAddressRecord(domain.resolver, domain.namehash, 60);
    defer if (resolved_addr_opt) |a| nested_ctx.allocator.free(a);

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

    const page = api_common.parsePagination(field, 10);

    var json: std.ArrayList(u8) = .{};
    errdefer json.deinit(nested_ctx.allocator);
    var arr = try jw.arrayOn(json.writer(nested_ctx.allocator));

    if (domain.name) |parent_name| {
        const subdomains = try database.getSubdomains(parent_name, page.skip, page.first);
        defer {
            for (subdomains) |*n| n.deinit(nested_ctx.allocator);
            nested_ctx.allocator.free(subdomains);
        }

        for (subdomains) |*subdomain| {
            const subdomain_json = try buildDomainJson(subdomain, field.selections, .{
                .database = database,
                .depth = nested_ctx.depth + 1,
                .allocator = nested_ctx.allocator,
                .loaders = nested_ctx.loaders,
            });
            defer nested_ctx.allocator.free(subdomain_json);
            try arr.itemRaw(subdomain_json);
        }
    }

    try arr.end();
    return try nested_ctx.allocator.dupe(u8, json.items);
}

/// Domain nested field handler: events
fn domainEventsHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const domain: *const models.Name = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    const first_arg = api_common.parsePagination(field, 100).first;

    const namehash_hex = try domain.namehash.toHex(nested_ctx.allocator);
    defer nested_ctx.allocator.free(namehash_hex);

    var filter_opts = db.EventFilterOptions{
        .namehash = namehash_hex,
        .limit = first_arg,
    };

    var event_types_list: std.ArrayList([]const u8) = .{};
    defer event_types_list.deinit(nested_ctx.allocator);

    var normalized_contract_address: ?[]u8 = null;
    defer if (normalized_contract_address) |addr| nested_ctx.allocator.free(addr);

    if (api_common.getObjectArg(field, "where")) |where_args| {
        for (where_args) |a| {
            if (std.mem.eql(u8, a.name, "type_in") and a.value == .list) {
                for (a.value.list) |item| {
                    if (item == .string) try event_types_list.append(nested_ctx.allocator, item.string);
                }
                if (event_types_list.items.len > 0) filter_opts.event_types = event_types_list.items;
                continue;
            }
            if (std.mem.eql(u8, a.name, "contractAddress") and a.value == .string) {
                const addr = Address.fromHex(a.value.string) catch continue;
                normalized_contract_address = try addr.toHex(nested_ctx.allocator);
                filter_opts.contract_address = normalized_contract_address;
                continue;
            }

            _ = api_common.matchStringArg(a, "type", &filter_opts.event_type) or
                api_common.matchIntArg(a, "blockNumber_gt", &filter_opts.block_number_gt) or
                api_common.matchIntArg(a, "blockNumber_lt", &filter_opts.block_number_lt) or
                api_common.matchIntArg(a, "timestamp_gt", &filter_opts.timestamp_gt) or
                api_common.matchIntArg(a, "timestamp_lt", &filter_opts.timestamp_lt);
        }
    }

    const domain_events = try database.getEventsFiltered(filter_opts);
    defer {
        for (domain_events) |*e| e.deinit(nested_ctx.allocator);
        nested_ctx.allocator.free(domain_events);
    }

    var json: std.ArrayList(u8) = .{};
    errdefer json.deinit(nested_ctx.allocator);
    var arr = try jw.arrayOn(json.writer(nested_ctx.allocator));
    for (domain_events) |*event| {
        const event_json = try buildEventJson(event, field.selections, .{
            .database = database,
            .depth = nested_ctx.depth + 1,
            .allocator = nested_ctx.allocator,
            .loaders = nested_ctx.loaders,
        });
        defer nested_ctx.allocator.free(event_json);
        try arr.itemRaw(event_json);
    }
    try arr.end();

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
            const escaped = try json_utils.escapeString(nested_ctx.allocator, normalized);
            defer nested_ctx.allocator.free(escaped);
            return try std.fmt.allocPrint(nested_ctx.allocator, "\"{s}\"", .{escaped});
        } else |_| {
            return try nested_ctx.allocator.dupe(u8, "null");
        }
    }
    return try nested_ctx.allocator.dupe(u8, "null");
}

/// Domain nested field handler: isNormalized (computed at query time)
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

    const limit: u32 = @min(api_common.parsePagination(field, 10).first, 100);

    var json: std.ArrayList(u8) = .{};
    errdefer json.deinit(allocator);

    if (domain.name) |parent_name| {
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

        var root = try jw.objectOn(json.writer(allocator));
        if (wants_total_count) {
            const total_count = try database.countDirectSubdomains(parent_name);
            try root.fieldInt("totalCount", total_count);
        }
        {
            var pi = try root.beginObject("pageInfo");
            try pi.fieldBool("hasNextPage", has_next);
            try pi.fieldBool("hasPreviousPage", false);
            try pi.end();
        }
        {
            var edges = try root.beginArray("edges");
            for (subdomains[0..actual_count]) |*subdomain| {
                var edge = try edges.beginObject();
                const cursor_hex = try subdomain.namehash.toHex(allocator);
                defer allocator.free(cursor_hex);
                try edge.fieldStr("cursor", cursor_hex, allocator);
                const subdomain_json = try buildDomainJson(subdomain, node_selections, .{
                    .database = database,
                    .depth = nested_ctx.depth + 1,
                    .allocator = allocator,
                    .loaders = nested_ctx.loaders,
                });
                defer allocator.free(subdomain_json);
                try edge.fieldRaw("node", subdomain_json);
                try edge.end();
            }
            try edges.end();
        }
        try root.end();
    } else {
        var root = try jw.objectOn(json.writer(allocator));
        {
            var pi = try root.beginObject("pageInfo");
            try pi.fieldBool("hasNextPage", false);
            try pi.fieldBool("hasPreviousPage", false);
            try pi.end();
        }
        var edges = try root.beginArray("edges");
        try edges.end();
        try root.end();
    }

    return try allocator.dupe(u8, json.items);
}

/// Domain nested field handler: eventsConnection (Relay-style connection)
fn domainEventsConnectionHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const domain: *const models.Name = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));
    const allocator = nested_ctx.allocator;

    const limit: u32 = @min(api_common.parsePagination(field, 10).first, 100);

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

    var root = try jw.objectOn(json.writer(allocator));
    if (wants_total_count) {
        const total_count = try database.countEventsByNamehash(domain.namehash);
        try root.fieldInt("totalCount", total_count);
    }
    {
        var pi = try root.beginObject("pageInfo");
        try pi.fieldBool("hasNextPage", has_next);
        try pi.fieldBool("hasPreviousPage", false);
        try pi.end();
    }
    {
        var edges = try root.beginArray("edges");
        for (events[0..actual_count]) |*event| {
            var edge = try edges.beginObject();
            const tx_hash_hex = try event.tx_hash.toHex(allocator);
            defer allocator.free(tx_hash_hex);
            const cursor = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ tx_hash_hex, event.log_index });
            defer allocator.free(cursor);
            try edge.fieldStr("cursor", cursor, allocator);
            const event_json = try buildEventJson(event, node_selections, .{
                .database = database,
                .depth = nested_ctx.depth + 1,
                .allocator = allocator,
                .loaders = nested_ctx.loaders,
            });
            defer allocator.free(event_json);
            try edge.fieldRaw("node", event_json);
            try edge.end();
        }
        try edges.end();
    }
    try root.end();

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
        const escaped = try json_utils.escapeString(ctx.allocator, domain.name orelse "[unknown]");
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
