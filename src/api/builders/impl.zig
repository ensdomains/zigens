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
const registry_entries = @import("../../storage/registry_entries.zig");
const admin = @import("../resolvers/admin.zig");
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

// ----------------------------------------------------------------------------
// Typed event-data accessors (audit finding #13).
//
// Mirror the documented JSON keys emitted by each handler in
// `src/indexer/{v1,v2}/handlers*.zig`. We surface them as nullable typed
// sub-objects on `Event`; each accessor returns `null` unless the event's
// type matches. Our GraphQL impl doesn't support unions, so this is the
// nullable-typed-field equivalent.
//
// Numeric fields that may exceed i64 (u256 costs, token ids) are exposed
// as Strings to preserve precision — `extractNumericStringField` borrows
// the raw digit slice from `event.data` regardless of whether the source
// stored it as a JSON number or quoted string.
//
// The selection set of each `as<X>` field is ignored — output is the full
// typed object. (Sub-selecting on these is a normal GraphQL object query;
// we just always serialize every defined field.)
// ----------------------------------------------------------------------------

fn isEventType(event: *const models.Event, type_name: []const u8) bool {
    return std.mem.eql(u8, event.event_type.toString(), type_name);
}

/// Write `"key":"<escaped>"` if `value_opt` is non-null; comma-prefix when needed.
fn writeOptStringField(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    first: *bool,
    key: []const u8,
    value_opt: ?[]const u8,
) !void {
    const value = value_opt orelse return;
    const escaped = try json_utils.escapeString(allocator, value);
    defer allocator.free(escaped);
    if (!first.*) try out.append(allocator, ',');
    try out.writer(allocator).print("\"{s}\":\"{s}\"", .{ key, escaped });
    first.* = false;
}

/// Write `"key":<digits>` if `value_opt` is non-null (digits already a numeric string).
fn writeOptIntField(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    first: *bool,
    key: []const u8,
    value_opt: ?i64,
) !void {
    const value = value_opt orelse return;
    if (!first.*) try out.append(allocator, ',');
    try out.writer(allocator).print("\"{s}\":{d}", .{ key, value });
    first.* = false;
}

fn eventAsTransferHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    _ = field;
    const event: *const models.Event = @ptrCast(@alignCast(ctx));
    const allocator = nested_ctx.allocator;
    if (!isEventType(event, "Transfer")) return try allocator.dupe(u8, "null");
    const data = event.data;

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    var first = true;

    try writeOptStringField(&out, allocator, &first, "from", json_utils.extractStringField(data, "from"));
    try writeOptStringField(&out, allocator, &first, "to", json_utils.extractStringField(data, "to"));
    // `id` field name (V1 NameWrapper, V2 Transfer) — namehash hex string or numeric.
    if (json_utils.extractStringField(data, "id")) |s| {
        try writeOptStringField(&out, allocator, &first, "id", s);
    } else if (json_utils.extractNumericStringField(data, "id")) |s| {
        try writeOptStringField(&out, allocator, &first, "id", s);
    } else if (json_utils.extractNumericStringField(data, "tokenId")) |s| {
        // V1 BaseRegistrar ERC721 Transfer emits `tokenId` (decimal).
        try writeOptStringField(&out, allocator, &first, "id", s);
    }
    if (json_utils.extractNumericStringField(data, "value")) |s| {
        try writeOptStringField(&out, allocator, &first, "value", s);
    }
    try writeOptStringField(&out, allocator, &first, "operator", json_utils.extractStringField(data, "operator"));
    // ERC1155 TransferBatch rows summarise the batch as `count` instead of id/value.
    try writeOptIntField(&out, allocator, &first, "count", json_utils.extractIntField(data, "count"));
    // V1 Registry NewOwner rows are stored as `Transfer` (subgraph feed parity)
    // with a node-shaped payload — surface it instead of an empty object (N3).
    try writeOptStringField(&out, allocator, &first, "parentNode", json_utils.extractStringField(data, "parentNode"));
    try writeOptStringField(&out, allocator, &first, "labelhash", json_utils.extractStringField(data, "labelhash"));
    try writeOptStringField(&out, allocator, &first, "subdomain", json_utils.extractStringField(data, "subdomain"));
    try writeOptStringField(&out, allocator, &first, "owner", json_utils.extractStringField(data, "owner"));

    try out.append(allocator, '}');
    return try out.toOwnedSlice(allocator);
}

fn eventAsNameRegisteredHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    _ = field;
    const event: *const models.Event = @ptrCast(@alignCast(ctx));
    const allocator = nested_ctx.allocator;
    if (!isEventType(event, "NameRegistered")) return try allocator.dupe(u8, "null");
    const data = event.data;

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    var first = true;

    try writeOptStringField(&out, allocator, &first, "name", json_utils.extractStringField(data, "name"));
    try writeOptStringField(&out, allocator, &first, "label", json_utils.extractStringField(data, "label"));
    try writeOptStringField(&out, allocator, &first, "owner", json_utils.extractStringField(data, "owner"));
    try writeOptIntField(&out, allocator, &first, "expires", json_utils.extractIntField(data, "expires"));
    if (json_utils.extractNumericStringField(data, "baseCost")) |s| {
        try writeOptStringField(&out, allocator, &first, "baseCost", s);
    }
    if (json_utils.extractNumericStringField(data, "premium")) |s| {
        try writeOptStringField(&out, allocator, &first, "premium", s);
    }
    if (json_utils.extractNumericStringField(data, "cost")) |s| {
        try writeOptStringField(&out, allocator, &first, "cost", s);
    }
    try writeOptStringField(&out, allocator, &first, "referrer", json_utils.extractStringField(data, "referrer"));

    try out.append(allocator, '}');
    return try out.toOwnedSlice(allocator);
}

fn eventAsNameRenewedHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    _ = field;
    const event: *const models.Event = @ptrCast(@alignCast(ctx));
    const allocator = nested_ctx.allocator;
    if (!isEventType(event, "NameRenewed")) return try allocator.dupe(u8, "null");
    const data = event.data;

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    var first = true;

    // BaseRegistrar V1 emits `id` as a number; the typed surface keeps it stringified.
    if (json_utils.extractNumericStringField(data, "id")) |s| {
        try writeOptStringField(&out, allocator, &first, "id", s);
    }
    try writeOptIntField(&out, allocator, &first, "expires", json_utils.extractIntField(data, "expires"));

    try out.append(allocator, '}');
    return try out.toOwnedSlice(allocator);
}

fn eventAsNameWrappedHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    _ = field;
    const event: *const models.Event = @ptrCast(@alignCast(ctx));
    const allocator = nested_ctx.allocator;
    // Note: rows indexed BEFORE the EventType refactor still have `type = "Transfer"`
    // for V1 NameWrapper events; this accessor returns null for those legacy rows.
    // Re-index from the NameWrapper deployment block to surface them.
    if (!isEventType(event, "NameWrapped")) return try allocator.dupe(u8, "null");
    const data = event.data;

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    var first = true;
    try writeOptStringField(&out, allocator, &first, "node", json_utils.extractStringField(data, "node"));
    try writeOptStringField(&out, allocator, &first, "owner", json_utils.extractStringField(data, "owner"));
    try writeOptIntField(&out, allocator, &first, "fuses", json_utils.extractIntField(data, "fuses"));
    try writeOptIntField(&out, allocator, &first, "expiry", json_utils.extractIntField(data, "expiry"));
    try out.append(allocator, '}');
    return try out.toOwnedSlice(allocator);
}

fn eventAsNameUnwrappedHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    _ = field;
    const event: *const models.Event = @ptrCast(@alignCast(ctx));
    const allocator = nested_ctx.allocator;
    if (!isEventType(event, "NameUnwrapped")) return try allocator.dupe(u8, "null");
    const data = event.data;

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    var first = true;
    try writeOptStringField(&out, allocator, &first, "node", json_utils.extractStringField(data, "node"));
    try writeOptStringField(&out, allocator, &first, "owner", json_utils.extractStringField(data, "owner"));
    try out.append(allocator, '}');
    return try out.toOwnedSlice(allocator);
}

fn eventAsFusesSetHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    _ = field;
    const event: *const models.Event = @ptrCast(@alignCast(ctx));
    const allocator = nested_ctx.allocator;
    if (!isEventType(event, "FusesSet")) return try allocator.dupe(u8, "null");
    const data = event.data;

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    var first = true;
    try writeOptStringField(&out, allocator, &first, "node", json_utils.extractStringField(data, "node"));
    try writeOptIntField(&out, allocator, &first, "fuses", json_utils.extractIntField(data, "fuses"));
    try out.append(allocator, '}');
    return try out.toOwnedSlice(allocator);
}

fn eventAsReverseClaimedHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    _ = field;
    const event: *const models.Event = @ptrCast(@alignCast(ctx));
    const allocator = nested_ctx.allocator;
    if (!isEventType(event, "ReverseClaimed")) return try allocator.dupe(u8, "null");
    const data = event.data;

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    var first = true;
    try writeOptStringField(&out, allocator, &first, "address", json_utils.extractStringField(data, "address"));
    try writeOptStringField(&out, allocator, &first, "node", json_utils.extractStringField(data, "node"));
    try out.append(allocator, '}');
    return try out.toOwnedSlice(allocator);
}

fn eventAsRegistryTransferHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    _ = field;
    const event: *const models.Event = @ptrCast(@alignCast(ctx));
    const allocator = nested_ctx.allocator;
    if (!isEventType(event, "RegistryTransfer")) return try allocator.dupe(u8, "null");
    const data = event.data;

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    var first = true;
    try writeOptStringField(&out, allocator, &first, "node", json_utils.extractStringField(data, "node"));
    try writeOptStringField(&out, allocator, &first, "owner", json_utils.extractStringField(data, "owner"));
    try out.append(allocator, '}');
    return try out.toOwnedSlice(allocator);
}

fn eventAsTextChangedHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    _ = field;
    const event: *const models.Event = @ptrCast(@alignCast(ctx));
    const allocator = nested_ctx.allocator;
    if (!isEventType(event, "TextChanged")) return try allocator.dupe(u8, "null");
    const data = event.data;

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    var first = true;
    try writeOptStringField(&out, allocator, &first, "namehash", json_utils.extractStringField(data, "namehash"));
    try writeOptStringField(&out, allocator, &first, "resolver", json_utils.extractStringField(data, "resolver"));
    try writeOptStringField(&out, allocator, &first, "key", json_utils.extractStringField(data, "key"));
    try writeOptStringField(&out, allocator, &first, "value", json_utils.extractStringField(data, "value"));
    try out.append(allocator, '}');
    return try out.toOwnedSlice(allocator);
}

fn eventAsAddressChangedHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    _ = field;
    const event: *const models.Event = @ptrCast(@alignCast(ctx));
    const allocator = nested_ctx.allocator;
    if (!isEventType(event, "AddressChanged")) return try allocator.dupe(u8, "null");
    const data = event.data;

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    var first = true;
    try writeOptStringField(&out, allocator, &first, "namehash", json_utils.extractStringField(data, "namehash"));
    try writeOptStringField(&out, allocator, &first, "resolver", json_utils.extractStringField(data, "resolver"));
    try writeOptIntField(&out, allocator, &first, "coinType", json_utils.extractIntField(data, "coinType"));
    try writeOptStringField(&out, allocator, &first, "address", json_utils.extractStringField(data, "address"));
    try out.append(allocator, '}');
    return try out.toOwnedSlice(allocator);
}

fn eventAsExpiryUpdatedHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    _ = field;
    const event: *const models.Event = @ptrCast(@alignCast(ctx));
    const allocator = nested_ctx.allocator;
    if (!isEventType(event, "ExpiryUpdated")) return try allocator.dupe(u8, "null");
    const data = event.data;

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    var first = true;
    try writeOptStringField(&out, allocator, &first, "node", json_utils.extractStringField(data, "node"));
    if (json_utils.extractNumericStringField(data, "tokenId")) |s| {
        try writeOptStringField(&out, allocator, &first, "tokenId", s);
    }
    // V1 NameWrapper ExpiryExtended uses `expiry`; V2 ExpiryUpdated uses `newExpiry`.
    // Unify into a single `expiry` field on the typed view.
    if (json_utils.extractIntField(data, "expiry")) |v| {
        try writeOptIntField(&out, allocator, &first, "expiry", v);
    } else if (json_utils.extractIntField(data, "newExpiry")) |v| {
        try writeOptIntField(&out, allocator, &first, "expiry", v);
    }
    try out.append(allocator, '}');
    return try out.toOwnedSlice(allocator);
}

fn eventAsResolverUpdatedHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    _ = field;
    const event: *const models.Event = @ptrCast(@alignCast(ctx));
    const allocator = nested_ctx.allocator;
    if (!isEventType(event, "ResolverUpdated")) return try allocator.dupe(u8, "null");
    const data = event.data;

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    var first = true;
    if (json_utils.extractNumericStringField(data, "tokenId")) |s| {
        try writeOptStringField(&out, allocator, &first, "tokenId", s);
    }
    try writeOptStringField(&out, allocator, &first, "resolver", json_utils.extractStringField(data, "resolver"));
    try writeOptStringField(&out, allocator, &first, "sender", json_utils.extractStringField(data, "sender"));
    try out.append(allocator, '}');
    return try out.toOwnedSlice(allocator);
}

fn eventAsLabelRegisteredHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    _ = field;
    const event: *const models.Event = @ptrCast(@alignCast(ctx));
    const allocator = nested_ctx.allocator;
    if (!isEventType(event, "LabelRegistered")) return try allocator.dupe(u8, "null");
    const data = event.data;

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    var first = true;
    try writeOptStringField(&out, allocator, &first, "name", json_utils.extractStringField(data, "name"));
    if (json_utils.extractNumericStringField(data, "tokenId")) |s| {
        try writeOptStringField(&out, allocator, &first, "tokenId", s);
    }
    if (json_utils.extractNumericStringField(data, "canonicalId")) |s| {
        try writeOptStringField(&out, allocator, &first, "canonicalId", s);
    }
    try writeOptStringField(&out, allocator, &first, "owner", json_utils.extractStringField(data, "owner"));
    try writeOptIntField(&out, allocator, &first, "expiry", json_utils.extractIntField(data, "expiry"));
    try writeOptStringField(&out, allocator, &first, "sender", json_utils.extractStringField(data, "sender"));
    try writeOptStringField(&out, allocator, &first, "registry", json_utils.extractStringField(data, "registry"));
    try out.append(allocator, '}');
    return try out.toOwnedSlice(allocator);
}

/// Event entity configuration
const EventEntityConfig = json_builder.EntityConfig{
    .type_name = "Event",
    .field_defs = &fields.EventFields,
    .nested_fields = &[_]json_builder.NestedFieldDef{
        .{ .name = "domain", .handler = domainNestedHandler },
        .{ .name = "asTransfer", .handler = eventAsTransferHandler },
        .{ .name = "asNameRegistered", .handler = eventAsNameRegisteredHandler },
        .{ .name = "asNameRenewed", .handler = eventAsNameRenewedHandler },
        .{ .name = "asNameWrapped", .handler = eventAsNameWrappedHandler },
        .{ .name = "asNameUnwrapped", .handler = eventAsNameUnwrappedHandler },
        .{ .name = "asFusesSet", .handler = eventAsFusesSetHandler },
        .{ .name = "asReverseClaimed", .handler = eventAsReverseClaimedHandler },
        .{ .name = "asRegistryTransfer", .handler = eventAsRegistryTransferHandler },
        .{ .name = "asTextChanged", .handler = eventAsTextChangedHandler },
        .{ .name = "asAddressChanged", .handler = eventAsAddressChangedHandler },
        .{ .name = "asExpiryUpdated", .handler = eventAsExpiryUpdatedHandler },
        .{ .name = "asResolverUpdated", .handler = eventAsResolverUpdatedHandler },
        .{ .name = "asLabelRegistered", .handler = eventAsLabelRegisteredHandler },
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

/// Registration nested field handler: expiryDate.
///
/// Resolution order MUST match the SQL `ORDER BY expiryDate` expression in
/// `EventSortField.expiry.toSql()` — otherwise the displayed value disagrees
/// with the sort key (rows appear out of order vs the field they're sorted by).
/// Fallback chain (first hit wins):
///   1. data.expiry        (V1 controller events emit absolute expiry)
///   2. data.expiration    (legacy alt naming)
///   3. timestamp + data.duration   (V2 LabelRegistered carries duration only)
///   4. names.expiry        (resolve via the domain row as a last resort)
fn registrationExpiryDateHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    _ = field;
    const event: *const models.Event = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    if (json_utils.extractIntField(event.data, "expiry")) |expiry| {
        return try std.fmt.allocPrint(nested_ctx.allocator, "{d}", .{expiry});
    }
    if (json_utils.extractIntField(event.data, "expiration")) |expiration| {
        return try std.fmt.allocPrint(nested_ctx.allocator, "{d}", .{expiration});
    }
    if (json_utils.extractIntField(event.data, "duration")) |duration| {
        const expiry = event.timestamp + duration;
        return try std.fmt.allocPrint(nested_ctx.allocator, "{d}", .{expiry});
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

    // Targeted extract — flat key lookup, no allocation, no tree build per row.
    const owner_str = json_utils.extractStringField(event.data, "owner") orelse {
        return try nested_ctx.allocator.dupe(u8, "null");
    };

    const owner_addr = Address.fromHex(owner_str) catch {
        return try nested_ctx.allocator.dupe(u8, "null");
    };

    return try buildAccountJson(owner_addr, field.selections, .{
        .database = database,
        .depth = nested_ctx.depth + 1,
        .allocator = nested_ctx.allocator,
        .loaders = nested_ctx.loaders,
    });
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

    const page = try api_common.parsePagination(field, 10);

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
///
/// Returns Registration entities (from the `registrations` table) registered by
/// this account — matching the schema's `[Registration!]!`. Sourced via
/// `getRegistrations` filtered by registrant (NOT the `names` table, which would
/// produce a Domain shape under a Registration-typed field).
fn accountRegistrationsHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const addr: *const Address = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    const page = try api_common.parsePagination(field, 10);

    const registrant_hex = try addr.toHex(nested_ctx.allocator);
    defer nested_ctx.allocator.free(registrant_hex);

    const fetch_limit: u32 = page.first + page.skip;
    const registrations = try database.getRegistrations(.{
        .registrant = registrant_hex,
        .limit = fetch_limit,
    });
    defer {
        for (registrations) |*reg| {
            reg.deinit(nested_ctx.allocator);
        }
        nested_ctx.allocator.free(registrations);
    }

    var json: std.ArrayList(u8) = .{};
    errdefer json.deinit(nested_ctx.allocator);
    var arr = try jw.arrayOn(json.writer(nested_ctx.allocator));
    const start_idx: usize = @min(@as(usize, @intCast(page.skip)), registrations.len);
    const end_idx: usize = @min(start_idx + @as(usize, @intCast(page.first)), registrations.len);
    for (registrations[start_idx..end_idx]) |*reg| {
        const reg_json = try buildRegistrationJson(reg, field.selections, .{
            .database = database,
            .depth = nested_ctx.depth + 1,
            .allocator = nested_ctx.allocator,
            .loaders = nested_ctx.loaders,
        });
        defer nested_ctx.allocator.free(reg_json);
        try arr.itemRaw(reg_json);
    }
    try arr.end();

    return try nested_ctx.allocator.dupe(u8, json.items);
}

/// Account nested field handler: primaryName
///
/// Two-step V1 subgraph reverse-resolution path:
///   1. reverse_records: address → reverse node (proves WHICH node represents the address)
///   2. resolver_names: latest NameChanged(name) for that node, across any resolver
/// Either query returning no row yields `null` — matches the contract semantic
/// where an unclaimed/uncleared reverse has no primary name.
///
/// Protocol resolution: prefer V2 (newer = more authoritative), fall back to V1.
/// V2 reverse ingestion is already wired (indexer.zig:V2_REVERSE_REGISTRAR_EVENTS
/// uses the protocol-agnostic handleV1ReverseClaimed which writes
/// reverse_records with the correct protocol), so V2 rows surface here as soon
/// as the V2 ETHReverseRegistrar contract address is populated in
/// `contracts.zig:eth_reverse_registrar`. Until then V2 lookups return null
/// and we transparently fall through to V1.
fn accountPrimaryNameHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    _ = field;
    const addr: *const Address = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    // Prefer V2 reverse over V1 when both exist for the same address.
    const namehash_opt = blk: {
        if (try database.getReverseRecordNamehash(.v2, addr.*)) |nh| break :blk nh;
        if (try database.getReverseRecordNamehash(.v1, addr.*)) |nh| break :blk nh;
        break :blk null;
    };
    const namehash = namehash_opt orelse return try nested_ctx.allocator.dupe(u8, "null");

    const name_opt = try database.getLatestNameByNamehash(namehash);
    const name = name_opt orelse return try nested_ctx.allocator.dupe(u8, "null");
    defer nested_ctx.allocator.free(name);

    const escaped = try json_utils.escapeString(nested_ctx.allocator, name);
    defer nested_ctx.allocator.free(escaped);
    return try std.fmt.allocPrint(nested_ctx.allocator, "\"{s}\"", .{escaped});
}

/// Account nested field handler: wrappedDomains (V1 NameWrapper records owned by this address).
fn accountWrappedDomainsHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const addr: *const Address = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    const page = try api_common.parsePagination(field, 100);

    // Reuse getAllNames (filters reachable, by owner) then keep only wrapped ones.
    const domains = try database.getAllNames(addr.*, page.skip, page.first);
    defer {
        for (domains) |*d| d.deinit(nested_ctx.allocator);
        nested_ctx.allocator.free(domains);
    }

    var json: std.ArrayList(u8) = .{};
    errdefer json.deinit(nested_ctx.allocator);
    var arr = try jw.arrayOn(json.writer(nested_ctx.allocator));
    for (domains) |*d| {
        if (!d.is_wrapped) continue;
        const wd_ctx = NestedContext{
            .database = database,
            .depth = nested_ctx.depth + 1,
            .allocator = nested_ctx.allocator,
            .loaders = nested_ctx.loaders,
        };
        const wd_json = try buildWrappedDomainJson(d, field.selections, wd_ctx);
        defer nested_ctx.allocator.free(wd_json);
        try arr.itemRaw(wd_json);
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
        .{ .name = "primaryName", .handler = accountPrimaryNameHandler },
        .{ .name = "wrappedDomains", .handler = accountWrappedDomainsHandler },
        // Account-row-backed scalars. Each handler issues an indexed point
        // lookup on the `accounts` table; the per-field lookups are cheap
        // (PK access, ~1 µs) and let single-account queries fetch only the
        // columns they actually select. For list queries that pull all four,
        // a per-row cache would help — left as a follow-up optimization.
        .{ .name = "seenV1", .handler = accountSeenV1Handler },
        .{ .name = "seenV2", .handler = accountSeenV2Handler },
        .{ .name = "firstSeenBlock", .handler = accountFirstSeenBlockHandler },
        .{ .name = "firstSeenTimestamp", .handler = accountFirstSeenTimestampHandler },
    },
};

/// Looks up the Account row via the per-request cache in LoaderContext so a
/// list query selecting all four row-backed fields (`seenV1`, `seenV2`,
/// `firstSeenBlock`, `firstSeenTimestamp`) does one DB hit per row instead of
/// four. Falls back to a direct DB call if loaders aren't attached (e.g.,
/// unit-test paths).
fn loadAccountRow(addr: *const Address, nested_ctx: json_builder.NestedContext) !?*const db.Account {
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));
    const addr_hex = try addr.toHex(nested_ctx.allocator);
    defer nested_ctx.allocator.free(addr_hex);
    if (nested_ctx.loaders) |opaque_loaders| {
        const lc: *@import("../loaders.zig").LoaderContext = @ptrCast(@alignCast(opaque_loaders));
        return try lc.getAccountCached(database, addr_hex);
    }
    // Loader-less fallback: caller must not free — but in this path the row
    // is leaked. Only hit by tests; production always attaches loaders.
    const fetched = try database.getAccount(addr_hex);
    if (fetched) |row| {
        const heap_row = try nested_ctx.allocator.create(db.Account);
        heap_row.* = row;
        return heap_row;
    }
    return null;
}

fn accountSeenV1Handler(ctx: *anyopaque, _: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const addr: *const Address = @ptrCast(@alignCast(ctx));
    const row_opt = try loadAccountRow(addr, nested_ctx);
    const v = if (row_opt) |r| r.seen_v1 else false;
    return try nested_ctx.allocator.dupe(u8, if (v) "true" else "false");
}

fn accountSeenV2Handler(ctx: *anyopaque, _: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const addr: *const Address = @ptrCast(@alignCast(ctx));
    const row_opt = try loadAccountRow(addr, nested_ctx);
    const v = if (row_opt) |r| r.seen_v2 else false;
    return try nested_ctx.allocator.dupe(u8, if (v) "true" else "false");
}

fn accountFirstSeenBlockHandler(ctx: *anyopaque, _: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const addr: *const Address = @ptrCast(@alignCast(ctx));
    const row_opt = try loadAccountRow(addr, nested_ctx);
    const v = if (row_opt) |r| r.first_seen_block else 0;
    return try std.fmt.allocPrint(nested_ctx.allocator, "{d}", .{v});
}

fn accountFirstSeenTimestampHandler(ctx: *anyopaque, _: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const addr: *const Address = @ptrCast(@alignCast(ctx));
    const row_opt = try loadAccountRow(addr, nested_ctx);
    const v = if (row_opt) |r| r.first_seen_timestamp else 0;
    return try std.fmt.allocPrint(nested_ctx.allocator, "{d}", .{v});
}

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
    var want_coin_type_big = false;
    var want_address = false;
    for (field.selections) |subfield| {
        if (std.mem.eql(u8, subfield.name, "coinType")) want_coin_type = true;
        if (std.mem.eql(u8, subfield.name, "coinTypeBig")) want_coin_type_big = true;
        if (std.mem.eql(u8, subfield.name, "address")) want_address = true;
    }
    if (!want_coin_type and !want_coin_type_big and !want_address) {
        want_coin_type = true;
        want_coin_type_big = true;
        want_address = true;
    }

    var json: std.ArrayList(u8) = .{};
    errdefer json.deinit(nested_ctx.allocator);
    var arr = try jw.arrayOn(json.writer(nested_ctx.allocator));
    for (all_addresses) |coin_addr| {
        var obj = try arr.beginObject();
        // `coinType: Int!` lossy-clamps to i64::max for ENSIP-11 L2 entries beyond i64
        // (in practice u64 fits, but Int32 doesn't — that's exactly why `coinTypeBig`
        // exists). Clients querying L2 coin types should select `coinTypeBig`.
        if (want_coin_type) try obj.fieldInt("coinType", coin_addr.coin_type);
        if (want_coin_type_big) {
            const ct_str = try std.fmt.allocPrint(nested_ctx.allocator, "{d}", .{coin_addr.coin_type});
            defer nested_ctx.allocator.free(ct_str);
            try obj.fieldStr("coinTypeBig", ct_str, nested_ctx.allocator);
        }
        if (want_address) try obj.fieldStr("address", coin_addr.address, nested_ctx.allocator);
        try obj.end();
    }
    try arr.end();

    return try nested_ctx.allocator.dupe(u8, json.items);
}

/// Resolver nested field handler: coinTypes — parallel projection of the
/// coin types currently set on this resolver/name, as decimal strings. ENSIP-11
/// safe (L2 coin types `0x80000000 | chainId` exceed Int32).
fn resolverCoinTypesHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    // Schema declares `coinTypes: [String!]` — scalar list, no sub-selection.
    if (field.selections.len > 0) return error.SubSelectionOnScalar;
    const rctx: *const fields.ResolverBuildContext = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    const coin_types = try database.getCoinTypes(rctx.resolver, rctx.namehash);
    defer nested_ctx.allocator.free(coin_types);

    var json: std.ArrayList(u8) = .{};
    errdefer json.deinit(nested_ctx.allocator);
    var arr = try jw.arrayOn(json.writer(nested_ctx.allocator));
    for (coin_types) |ct| {
        const ct_str = try std.fmt.allocPrint(nested_ctx.allocator, "{d}", .{ct});
        defer nested_ctx.allocator.free(ct_str);
        try arr.itemStr(ct_str, nested_ctx.allocator);
    }
    try arr.end();
    return try nested_ctx.allocator.dupe(u8, json.items);
}

/// Resolver nested field handler: domain — canonical Domain back-reference.
/// SQL: `SELECT … FROM names WHERE resolver = ? ORDER BY namehash ASC LIMIT 1`.
/// Returns null when no name currently points at this resolver. The
/// NestedContext `depth` guard prevents `resolver.domain.resolver.domain…`
/// recursion blowing the stack.
fn resolverDomainHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const rctx: *const fields.ResolverBuildContext = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    const name_opt = try database.getDomainByResolver(rctx.resolver);
    if (name_opt) |name| {
        var name_mut = name;
        defer name_mut.deinit(nested_ctx.allocator);
        return try buildDomainJson(&name_mut, field.selections, .{
            .database = database,
            .depth = nested_ctx.depth + 1,
            .allocator = nested_ctx.allocator,
            .loaders = nested_ctx.loaders,
        });
    }
    return try nested_ctx.allocator.dupe(u8, "null");
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
    // Schema declares `texts: [String!]` — list of scalar keys. Sub-selections are not valid;
    // surface the error rather than silently dropping them (clients sometimes try `texts { key value }`).
    if (field.selections.len > 0) return error.SubSelectionOnScalar;
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
    // Schema declares `abis: [Int!]` — list of scalar content types. Sub-selections invalid.
    if (field.selections.len > 0) return error.SubSelectionOnScalar;
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
        .{ .name = "coinTypes", .handler = resolverCoinTypesHandler },
        .{ .name = "domain", .handler = resolverDomainHandler },
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
    protocol: models.Protocol,
    selections: []const parser.Field,
    ctx: NestedContext,
) anyerror![]u8 {
    if (selections.len == 0) {
        const addr_hex = try resolver.toHex(ctx.allocator);
        defer ctx.allocator.free(addr_hex);
        return try std.fmt.allocPrint(ctx.allocator, "{{\"address\":\"{s}\"}}", .{addr_hex});
    }

    const database: *db.Database = @ptrCast(@alignCast(ctx.database));
    var rctx = fields.ResolverBuildContext{
        .resolver = resolver,
        .namehash = domain_namehash,
        .protocol = protocol,
        .chain_id = database.chain_id,
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
/// the currently authoritative resolver to match on-protocol semantics.
fn domainResolvedAddressHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const domain: *const models.Name = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    // Materialized-column fastpath (V1 NewResolver writer; subgraph parity).
    // V1 rows where `addr(node)` was materialized at write time are served
    // straight from `names.resolved_address` — no resolver_addresses join.
    // V2 rows leave the column NULL and fall through to the query-time path
    // below; the API contract is unchanged.
    if (domain.resolved_address) |addr| {
        if (!addr.isZero()) {
            return try buildAccountJson(addr, field.selections, .{
                .database = database,
                .depth = nested_ctx.depth + 1,
                .allocator = nested_ctx.allocator,
                .loaders = nested_ctx.loaders,
            });
        }
    }

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
        return try buildResolverJson(domain.resolver, domain.namehash, domain.protocol, field.selections, .{
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

/// Domain nested field handler: subregistry (the registry managing this domain's subnames).
/// The pointer lives in `registry_entries` keyed by (parent_registry, canonical_id); a name's
/// parent registry is its `registry` column. Resolves to the matching RegistryInfo, or null
/// when no subregistry is set / the registry entity isn't indexed.
fn domainSubregistryHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const domain: *const models.Name = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    const sub = try registry_entries.getSubregistry(database, domain.protocol, domain.registry, domain.token_id);
    if (sub.isZero()) return try nested_ctx.allocator.dupe(u8, "null");

    const reg_opt = try database.getRegistry(domain.protocol, sub);
    if (reg_opt) |reg_val| {
        var reg = reg_val;
        defer reg.deinit(nested_ctx.allocator);
        return try admin.buildRegistryInfoJson(nested_ctx.allocator, database, &reg, field.selections, .{
            .allocator = nested_ctx.allocator,
            .database = nested_ctx.database,
            .loaders = nested_ctx.loaders,
        });
    }
    return try nested_ctx.allocator.dupe(u8, "null");
}

/// Domain nested field handler: subdomains
fn domainSubdomainsHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const domain: *const models.Name = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    const page = try api_common.parsePagination(field, 10);

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

    const first_arg = (try api_common.parsePagination(field, 100)).first;

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
                // Surface invalid input as an error — silent drop hides typos.
                const addr = Address.fromHex(a.value.string) catch return error.InvalidContractAddress;
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

/// Build a WrappedDomain JSON object from a wrapped Name row.
///
/// Honors the requested sub-selections. Note: WrappedDomain.owner is the V1
/// NameWrapper wrapped-token owner (= the same `name.owner` we surface on
/// Domain.owner per the documented divergence). We intentionally do NOT
/// recurse `owner -> wrappedDomains -> ...`; clients selecting that nested
/// path would hit the existing `depth` guard in NestedContext, but more
/// importantly the WrappedDomain shape itself terminates at the Account.id
/// fast path unless explicitly selected.
pub fn buildWrappedDomainJson(
    domain: *const models.Name,
    selections: []const parser.Field,
    nested_ctx: NestedContext,
) anyerror![]u8 {
    const allocator = nested_ctx.allocator;
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    var first = true;

    // Default projection if no sub-selection: id only (matches Domain/Account fast paths).
    if (selections.len == 0) {
        const nh_hex = try domain.namehash.toHex(allocator);
        defer allocator.free(nh_hex);
        try out.writer(allocator).print("\"id\":\"{s}\"", .{nh_hex});
        try out.append(allocator, '}');
        return try out.toOwnedSlice(allocator);
    }

    for (selections) |*sel| {
        const key = sel.alias orelse sel.name;
        if (!first) try out.append(allocator, ',');

        if (std.mem.eql(u8, sel.name, "id")) {
            const nh_hex = try domain.namehash.toHex(allocator);
            defer allocator.free(nh_hex);
            try out.writer(allocator).print("\"{s}\":\"{s}\"", .{ key, nh_hex });
        } else if (std.mem.eql(u8, sel.name, "domain")) {
            const dj = try buildDomainJson(@constCast(domain), sel.selections, .{
                .database = database,
                .depth = nested_ctx.depth + 1,
                .allocator = allocator,
                .loaders = nested_ctx.loaders,
            });
            defer allocator.free(dj);
            try out.writer(allocator).print("\"{s}\":", .{key});
            try out.appendSlice(allocator, dj);
        } else if (std.mem.eql(u8, sel.name, "expiryDate")) {
            if (domain.wrapper_expiry) |ts| {
                try out.writer(allocator).print("\"{s}\":{d}", .{ key, ts });
            } else {
                try out.writer(allocator).print("\"{s}\":null", .{key});
            }
        } else if (std.mem.eql(u8, sel.name, "fuses")) {
            if (domain.wrapper_fuses) |fs| {
                if (std.fmt.parseInt(u64, fs, 10)) |parsed| {
                    try out.writer(allocator).print("\"{s}\":{d}", .{ key, parsed });
                } else |_| {
                    try out.writer(allocator).print("\"{s}\":null", .{key});
                }
            } else {
                try out.writer(allocator).print("\"{s}\":null", .{key});
            }
        } else if (std.mem.eql(u8, sel.name, "owner")) {
            const aj = try buildAccountJson(domain.owner, sel.selections, .{
                .database = database,
                .depth = nested_ctx.depth + 1,
                .allocator = allocator,
                .loaders = nested_ctx.loaders,
            });
            defer allocator.free(aj);
            try out.writer(allocator).print("\"{s}\":", .{key});
            try out.appendSlice(allocator, aj);
        } else if (std.mem.eql(u8, sel.name, "name")) {
            if (domain.name) |n| {
                const escaped = try json_utils.escapeString(allocator, n);
                defer allocator.free(escaped);
                try out.writer(allocator).print("\"{s}\":\"{s}\"", .{ key, escaped });
            } else {
                try out.writer(allocator).print("\"{s}\":null", .{key});
            }
        } else {
            // Unknown field — emit null for forward-compat.
            try out.writer(allocator).print("\"{s}\":null", .{key});
        }
        first = false;
    }

    try out.append(allocator, '}');
    return try out.toOwnedSlice(allocator);
}

/// Domain nested field handler: wrappedDomain (V1 NameWrapper record).
/// Returns null when the domain is not wrapped (or is a V2 domain).
fn domainWrappedDomainHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const domain: *const models.Name = @ptrCast(@alignCast(ctx));
    if (!domain.is_wrapped) return try nested_ctx.allocator.dupe(u8, "null");
    const inner = NestedContext{
        .database = nested_ctx.database,
        .depth = nested_ctx.depth + 1,
        .allocator = nested_ctx.allocator,
        .loaders = nested_ctx.loaders,
    };
    return try buildWrappedDomainJson(domain, field.selections, inner);
}

/// Domain nested field handler: wrappedOwner (V1 NameWrapper EOA owner).
/// Returns null when the domain is not wrapped. The wrapped-token owner is
/// the same value stored on `name.owner` for wrapped names (per the
/// documented Domain.owner divergence: we expose the EOA owner, not the
/// NameWrapper contract address).
fn domainWrappedOwnerHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const domain: *const models.Name = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));
    if (!domain.is_wrapped) return try nested_ctx.allocator.dupe(u8, "null");
    return try buildAccountJson(domain.owner, field.selections, .{
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
        // Subgraph parity: grace-inclusive for unwrapped V1 .eth 2LDs (the
        // schema docstring promises this; bare expires lives on Registration).
        return try std.fmt.allocPrint(nested_ctx.allocator, "{d}", .{fields.effectiveDomainExpiry(domain.*)});
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

/// Domain nested field handler: isNormalized. Reads the stored column (computed once
/// at ingest via ENSIP-15), not recomputed per query.
fn domainIsNormalizedHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    _ = field;
    const domain: *const models.Name = @ptrCast(@alignCast(ctx));
    return try nested_ctx.allocator.dupe(u8, if (domain.is_normalized) "true" else "false");
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

/// Domain nested field handler: roleHolderCount (aggregation)
///
/// Distinct accounts holding any label-scoped role on this label, joined by the
/// label's canonical (version-stripped) token id and its registry. Folds the
/// portal's previous client-side roleConnection fetch + group-by-resource into a
/// single indexed COUNT(DISTINCT). Roles on the registry-wide root resource and
/// empty bitmaps are excluded (see getLabelRoleHolderCount).
fn domainRoleHolderCountHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    _ = field;
    const domain: *const models.Name = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));

    var canonical_id_buf: [66]u8 = undefined;
    const canonical_id_hex = std.fmt.bufPrint(&canonical_id_buf, "0x{x:0>64}", .{domain.canonical_id}) catch unreachable;

    const count = try database.getLabelRoleHolderCount(domain.protocol, canonical_id_hex, domain.registry);
    return try std.fmt.allocPrint(nested_ctx.allocator, "{d}", .{count});
}

/// Domain nested field handler: subdomainConnection (Relay-style connection)
fn domainSubdomainConnectionHandler(ctx: *anyopaque, field: *const parser.Field, nested_ctx: json_builder.NestedContext) anyerror!?[]u8 {
    const domain: *const models.Name = @ptrCast(@alignCast(ctx));
    const database: *db.Database = @ptrCast(@alignCast(nested_ctx.database));
    const allocator = nested_ctx.allocator;

    const limit: u32 = @min((try api_common.parsePagination(field, 10)).first, 100);

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

    const limit: u32 = @min((try api_common.parsePagination(field, 10)).first, 100);

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
        .{ .name = "subregistry", .handler = domainSubregistryHandler },
        .{ .name = "parent", .handler = domainParentHandler },
        .{ .name = "subdomains", .handler = domainSubdomainsHandler },
        .{ .name = "subdomainsCount", .handler = domainSubdomainsCountHandler },
        // Subgraph-parity alias for subdomainsCount; same resolver.
        .{ .name = "subdomainCount", .handler = domainSubdomainsCountHandler },
        .{ .name = "subdomainConnection", .handler = domainSubdomainConnectionHandler },
        .{ .name = "events", .handler = domainEventsHandler },
        .{ .name = "eventsCount", .handler = domainEventsCountHandler },
        .{ .name = "roleHolderCount", .handler = domainRoleHolderCountHandler },
        .{ .name = "eventsConnection", .handler = domainEventsConnectionHandler },
        .{ .name = "domain", .handler = domainDomainHandler },
        .{ .name = "expiryDate", .handler = domainExpiryDateHandler },
        .{ .name = "normalizedName", .handler = domainNormalizedNameHandler },
        .{ .name = "isNormalized", .handler = domainIsNormalizedHandler },
        .{ .name = "wrappedDomain", .handler = domainWrappedDomainHandler },
        .{ .name = "wrappedOwner", .handler = domainWrappedOwnerHandler },
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
