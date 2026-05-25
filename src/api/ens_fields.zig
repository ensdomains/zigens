/// ENS-Specific Field Definitions for GraphQL
///
/// This module extends the generic field system with ENS-specific types
/// (Address, Hash) and provides field definitions for all ENS entities.
///
/// Uses the table-driven approach from lib/graphql/fields.zig for
/// Event, Registration, Domain, Account, Resolver, etc.
const std = @import("std");
const models = @import("../types/models.zig");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;

// Import generic field utilities
const generic_fields = @import("../lib/graphql/fields.zig");
pub const escapeJsonString = generic_fields.escapeJsonString;

// ============================================================================
// ENS-SPECIFIC FIELD TYPES (extends generic with Address/Hash)
// ============================================================================

/// Field value types (ENS-extended)
pub const FieldType = enum {
    /// Required string field
    string,
    /// Optional string field (can be null)
    optional_string,
    /// Integer field
    int,
    /// Optional integer field
    optional_int,
    /// Boolean field
    bool_field,
    /// Optional boolean field
    optional_bool,
    /// Address field (rendered as hex string)
    address,
    /// Optional address field
    optional_address,
    /// Hash field (rendered as hex string)
    hash,
    /// Optional hash field
    optional_hash,
    /// Custom writer that produces a scalar value (sub-selections invalid).
    custom_scalar,
    /// Custom writer that produces an object/list (sub-selections may be valid; the
    /// writer is responsible for honoring them).
    custom,
};

/// Result of getting a field value (ENS-extended)
pub const FieldValue = union(enum) {
    string: []const u8,
    optional_string: ?[]const u8,
    int: i64,
    optional_int: ?i64,
    bool_val: bool,
    optional_bool: ?bool,
    address: Address,
    optional_address: ?Address,
    hash: Hash,
    optional_hash: ?Hash,
    /// Custom handlers write directly to the writer and return true if handled
    custom: bool,
    /// Field not found or error
    none: void,
};

/// Getter function type - takes context and returns field value
pub const FieldGetter = *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!FieldValue;

/// Custom writer function type - writes directly to JSON output
pub const CustomWriter = *const fn (ctx: *anyopaque, output_key: []const u8, writer: std.ArrayList(u8).Writer, allocator: std.mem.Allocator) anyerror!bool;

/// Field definition (ENS-extended)
pub const FieldDef = struct {
    /// GraphQL field name
    name: []const u8,
    /// Type of the field value
    field_type: FieldType,
    /// Getter function (for non-custom types)
    getter: ?FieldGetter,
    /// Custom writer function (for custom types)
    custom_writer: ?CustomWriter,

    /// Create a required string field
    pub fn string(name: []const u8, getter: FieldGetter) FieldDef {
        return .{ .name = name, .field_type = .string, .getter = getter, .custom_writer = null };
    }

    /// Create an optional string field
    pub fn optionalString(name: []const u8, getter: FieldGetter) FieldDef {
        return .{ .name = name, .field_type = .optional_string, .getter = getter, .custom_writer = null };
    }

    /// Create an integer field
    pub fn int(name: []const u8, getter: FieldGetter) FieldDef {
        return .{ .name = name, .field_type = .int, .getter = getter, .custom_writer = null };
    }

    /// Create an optional integer field
    pub fn optionalInt(name: []const u8, getter: FieldGetter) FieldDef {
        return .{ .name = name, .field_type = .optional_int, .getter = getter, .custom_writer = null };
    }

    /// Create a boolean field
    pub fn boolean(name: []const u8, getter: FieldGetter) FieldDef {
        return .{ .name = name, .field_type = .bool_field, .getter = getter, .custom_writer = null };
    }

    /// Create an optional boolean field
    pub fn optionalBoolean(name: []const u8, getter: FieldGetter) FieldDef {
        return .{ .name = name, .field_type = .optional_bool, .getter = getter, .custom_writer = null };
    }

    /// Create an address field
    pub fn address(name: []const u8, getter: FieldGetter) FieldDef {
        return .{ .name = name, .field_type = .address, .getter = getter, .custom_writer = null };
    }

    /// Create a hash field
    pub fn hashField(name: []const u8, getter: FieldGetter) FieldDef {
        return .{ .name = name, .field_type = .hash, .getter = getter, .custom_writer = null };
    }

    /// Create an optional hash field
    pub fn optionalHash(name: []const u8, getter: FieldGetter) FieldDef {
        return .{ .name = name, .field_type = .optional_hash, .getter = getter, .custom_writer = null };
    }

    /// Create a custom field with direct writer access. Use this for fields whose JSON
    /// shape is an object or list — the writer is expected to honor sub-selections itself.
    pub fn custom(name: []const u8, writer_fn: CustomWriter) FieldDef {
        return .{ .name = name, .field_type = .custom, .getter = null, .custom_writer = writer_fn };
    }

    /// Create a custom field whose value is scalar (e.g. a formatted string or number).
    /// Sub-selections will be rejected at the entity-builder level.
    pub fn customScalar(name: []const u8, writer_fn: CustomWriter) FieldDef {
        return .{ .name = name, .field_type = .custom_scalar, .getter = null, .custom_writer = writer_fn };
    }
};

/// Handle a field from a field definition table
/// Returns true if field was handled, false if not found
pub fn handleFieldFromTable(
    ctx: *anyopaque,
    output_key: []const u8,
    field_name: []const u8,
    writer: std.ArrayList(u8).Writer,
    allocator: std.mem.Allocator,
    field_defs: []const FieldDef,
) !bool {
    // Find the field definition
    for (field_defs) |def| {
        if (std.mem.eql(u8, def.name, field_name)) {
            return try writeFieldValue(ctx, output_key, writer, allocator, def);
        }
    }
    return false;
}

/// Write a field value to the JSON output
fn writeFieldValue(
    ctx: *anyopaque,
    output_key: []const u8,
    writer: std.ArrayList(u8).Writer,
    allocator: std.mem.Allocator,
    def: FieldDef,
) !bool {
    // Handle custom fields (both scalar and object kinds dispatch through the writer)
    if (def.field_type == .custom or def.field_type == .custom_scalar) {
        if (def.custom_writer) |custom_fn| {
            return try custom_fn(ctx, output_key, writer, allocator);
        }
        return false;
    }

    // Get the field value
    const getter = def.getter orelse return false;
    const value = try getter(ctx, allocator);

    switch (value) {
        .string => |s| {
            const escaped = try escapeJsonString(allocator, s);
            defer allocator.free(escaped);
            try writer.print("\"{s}\":\"{s}\"", .{ output_key, escaped });
            return true;
        },
        .optional_string => |maybe_s| {
            if (maybe_s) |s| {
                const escaped = try escapeJsonString(allocator, s);
                defer allocator.free(escaped);
                try writer.print("\"{s}\":\"{s}\"", .{ output_key, escaped });
            } else {
                try writer.print("\"{s}\":null", .{output_key});
            }
            return true;
        },
        .int => |i| {
            try writer.print("\"{s}\":{d}", .{ output_key, i });
            return true;
        },
        .optional_int => |maybe_i| {
            if (maybe_i) |i| {
                try writer.print("\"{s}\":{d}", .{ output_key, i });
            } else {
                try writer.print("\"{s}\":null", .{output_key});
            }
            return true;
        },
        .bool_val => |b| {
            try writer.print("\"{s}\":{s}", .{ output_key, if (b) "true" else "false" });
            return true;
        },
        .optional_bool => |maybe_b| {
            if (maybe_b) |b| {
                try writer.print("\"{s}\":{s}", .{ output_key, if (b) "true" else "false" });
            } else {
                try writer.print("\"{s}\":null", .{output_key});
            }
            return true;
        },
        .address => |addr| {
            const hex = try addr.toHex(allocator);
            defer allocator.free(hex);
            try writer.print("\"{s}\":\"{s}\"", .{ output_key, hex });
            return true;
        },
        .optional_address => |maybe_addr| {
            if (maybe_addr) |addr| {
                const hex = try addr.toHex(allocator);
                defer allocator.free(hex);
                try writer.print("\"{s}\":\"{s}\"", .{ output_key, hex });
            } else {
                try writer.print("\"{s}\":null", .{output_key});
            }
            return true;
        },
        .hash => |h| {
            const hex = try h.toHex(allocator);
            defer allocator.free(hex);
            try writer.print("\"{s}\":\"{s}\"", .{ output_key, hex });
            return true;
        },
        .optional_hash => |maybe_h| {
            if (maybe_h) |h| {
                const hex = try h.toHex(allocator);
                defer allocator.free(hex);
                try writer.print("\"{s}\":\"{s}\"", .{ output_key, hex });
            } else {
                try writer.print("\"{s}\":null", .{output_key});
            }
            return true;
        },
        .custom => |handled| {
            return handled;
        },
        .none => {
            return false;
        },
    }
}

// ============================================================================
// EVENT FIELD DEFINITIONS
// ============================================================================

/// Get event from context
fn getEventCtx(ctx: *anyopaque) *const models.Event {
    return @ptrCast(@alignCast(ctx));
}

fn getEventId(ctx: *anyopaque, allocator: std.mem.Allocator) !FieldValue {
    const event = getEventCtx(ctx);
    const tx_hash = try event.tx_hash.toHex(allocator);
    defer allocator.free(tx_hash);
    const id = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ tx_hash, event.log_index });
    defer allocator.free(id);
    return FieldValue{ .string = id };
}

fn getEventType(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const event = getEventCtx(ctx);
    return FieldValue{ .string = event.event_type.toString() };
}

fn getEventBlockNumber(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const event = getEventCtx(ctx);
    return FieldValue{ .int = @intCast(event.block_number) };
}

fn getEventTransactionHash(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const event = getEventCtx(ctx);
    return FieldValue{ .hash = event.tx_hash };
}

fn getEventTimestamp(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const event = getEventCtx(ctx);
    return FieldValue{ .int = event.timestamp };
}

fn getEventName(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const event = getEventCtx(ctx);
    return FieldValue{ .optional_string = event.name };
}

fn getEventNamehash(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const event = getEventCtx(ctx);
    return FieldValue{ .optional_hash = event.namehash };
}

fn getEventContractAddress(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const event = getEventCtx(ctx);
    return FieldValue{ .address = event.contract_address };
}

fn getEventProtocol(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const event = getEventCtx(ctx);
    return FieldValue{ .string = event.protocol.toString() };
}

/// Extract a string field from the event's JSON `data` blob, gated on the
/// event type. Used by the flat subgraph-parity accessors that surface
/// event-type-specific payload fields directly on the `Event` GraphQL type
/// (e.g., `key`/`value` on TextChanged, instead of forcing clients through
/// the `asTextChanged { key }` projection).
fn extractDataField(data: ?[]const u8, expected_type: []const u8, event_type: []const u8, field: []const u8, allocator: std.mem.Allocator) !FieldValue {
    if (!std.mem.eql(u8, event_type, expected_type)) return FieldValue{ .optional_string = null };
    const blob = data orelse return FieldValue{ .optional_string = null };
    // Minimal JSON probe — we only need to find a `"field":"value"` pair. Mirrors
    // the json_utils.extractStringField approach used elsewhere but inlined
    // here to avoid a cross-module import for one call site.
    const needle_buf = try std.fmt.allocPrint(allocator, "\"{s}\":\"", .{field});
    defer allocator.free(needle_buf);
    const start = std.mem.indexOf(u8, blob, needle_buf) orelse return FieldValue{ .optional_string = null };
    const value_start = start + needle_buf.len;
    const value_end_rel = std.mem.indexOfScalar(u8, blob[value_start..], '"') orelse return FieldValue{ .optional_string = null };
    const owned = try allocator.dupe(u8, blob[value_start .. value_start + value_end_rel]);
    return FieldValue{ .optional_string = owned };
}

fn getEventTextKey(ctx: *anyopaque, allocator: std.mem.Allocator) !FieldValue {
    const event = getEventCtx(ctx);
    return try extractDataField(event.data, "TextChanged", event.event_type.toString(), "key", allocator);
}

fn getEventTextValue(ctx: *anyopaque, allocator: std.mem.Allocator) !FieldValue {
    const event = getEventCtx(ctx);
    return try extractDataField(event.data, "TextChanged", event.event_type.toString(), "value", allocator);
}

fn getEventData(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const event = getEventCtx(ctx);
    return FieldValue{ .optional_string = event.data };
}

/// Event field definitions table
pub const EventFields = [_]FieldDef{
    FieldDef.customScalar("id", writeEventId),
    FieldDef.string("type", getEventType),
    FieldDef.int("blockNumber", getEventBlockNumber),
    FieldDef.hashField("transactionHash", getEventTransactionHash),
    FieldDef.int("timestamp", getEventTimestamp),
    FieldDef.optionalString("name", getEventName),
    FieldDef.optionalHash("namehash", getEventNamehash),
    FieldDef.address("contractAddress", getEventContractAddress),
    FieldDef.string("protocol", getEventProtocol),
    FieldDef.optionalString("data", getEventData),
    // Subgraph-parity flat accessors for event-type-specific payload fields.
    // These extract the matching value from the JSON `data` blob when the
    // event type matches; null otherwise. The `as*` typed projection accessors
    // remain available for clients that prefer the discriminated-union shape.
    FieldDef.optionalString("key", getEventTextKey),
    FieldDef.optionalString("value", getEventTextValue),
};

/// Custom writer for event ID (composite field)
fn writeEventId(ctx: *anyopaque, output_key: []const u8, writer: std.ArrayList(u8).Writer, allocator: std.mem.Allocator) !bool {
    const event = getEventCtx(ctx);
    const tx_hash = try event.tx_hash.toHex(allocator);
    defer allocator.free(tx_hash);
    try writer.print("\"{s}\":\"{s}-{d}\"", .{ output_key, tx_hash, event.log_index });
    return true;
}

// ============================================================================
// EAC ROLE FIELD DEFINITIONS
// ============================================================================

fn getEACRoleCtx(ctx: *anyopaque) *const models.EACRoleAssignment {
    return @ptrCast(@alignCast(ctx));
}

fn getEACRoleId(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const role = getEACRoleCtx(ctx);
    return FieldValue{ .int = @intCast(role.id) };
}

fn getEACRoleResource(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const role = getEACRoleCtx(ctx);
    return FieldValue{ .string = role.resource };
}

fn getEACRoleAccount(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const role = getEACRoleCtx(ctx);
    return FieldValue{ .address = role.account };
}

fn getEACRoleBitmap(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const role = getEACRoleCtx(ctx);
    return FieldValue{ .string = role.role_bitmap };
}

fn getEACRoleBlockNumber(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const role = getEACRoleCtx(ctx);
    return FieldValue{ .int = @intCast(role.block_number) };
}

fn getEACRoleTransactionHash(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const role = getEACRoleCtx(ctx);
    return FieldValue{ .hash = role.tx_hash };
}

fn getEACRoleTimestamp(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const role = getEACRoleCtx(ctx);
    return FieldValue{ .int = role.timestamp };
}

fn getEACRoleName(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const role = getEACRoleCtx(ctx);
    return FieldValue{ .optional_string = role.name };
}

/// EAC Role field definitions table
pub const EACRoleFields = [_]FieldDef{
    FieldDef.customScalar("id", writeEACRoleId),
    FieldDef.string("resource", getEACRoleResource),
    FieldDef.customScalar("account", writeEACRoleAccount),
    FieldDef.string("roleBitmap", getEACRoleBitmap),
    FieldDef.int("blockNumber", getEACRoleBlockNumber),
    FieldDef.hashField("transactionHash", getEACRoleTransactionHash),
    FieldDef.int("timestamp", getEACRoleTimestamp),
    FieldDef.optionalString("name", getEACRoleName),
};

/// Custom writer for EAC role ID
fn writeEACRoleId(ctx: *anyopaque, output_key: []const u8, writer: std.ArrayList(u8).Writer, _: std.mem.Allocator) !bool {
    const role = getEACRoleCtx(ctx);
    try writer.print("\"{s}\":\"{d}\"", .{ output_key, role.id });
    return true;
}

/// Custom writer for EAC role account (as hex string)
fn writeEACRoleAccount(ctx: *anyopaque, output_key: []const u8, writer: std.ArrayList(u8).Writer, allocator: std.mem.Allocator) !bool {
    const role = getEACRoleCtx(ctx);
    const hex = try role.account.toHex(allocator);
    defer allocator.free(hex);
    try writer.print("\"{s}\":\"{s}\"", .{ output_key, hex });
    return true;
}

// ============================================================================
// RESOLVER FIELD DEFINITIONS
// ============================================================================

fn getResolverCtx(ctx: *anyopaque) *const models.Resolver {
    return @ptrCast(@alignCast(ctx));
}

fn getResolverAddress(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const resolver = getResolverCtx(ctx);
    return FieldValue{ .address = resolver.address };
}

fn getResolverName(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const resolver = getResolverCtx(ctx);
    return FieldValue{ .string = resolver.name };
}

fn getResolverNamehash(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const resolver = getResolverCtx(ctx);
    return FieldValue{ .hash = resolver.namehash };
}

fn getResolverSetBlock(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const resolver = getResolverCtx(ctx);
    return FieldValue{ .int = @intCast(resolver.set_block) };
}

fn getResolverSetAt(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const resolver = getResolverCtx(ctx);
    return FieldValue{ .int = resolver.set_at };
}

/// Resolver field definitions table
pub const ResolverFields = [_]FieldDef{
    FieldDef.address("address", getResolverAddress),
    FieldDef.string("name", getResolverName),
    FieldDef.hashField("namehash", getResolverNamehash),
    FieldDef.int("setBlock", getResolverSetBlock),
    FieldDef.int("setAt", getResolverSetAt),
};

// ============================================================================
// REGISTRY FIELD DEFINITIONS
// ============================================================================

fn getRegistryCtx(ctx: *anyopaque) *const models.Registry {
    return @ptrCast(@alignCast(ctx));
}

fn getRegistryAddress(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const registry = getRegistryCtx(ctx);
    return FieldValue{ .address = registry.address };
}

fn getRegistryName(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const registry = getRegistryCtx(ctx);
    return FieldValue{ .string = registry.name };
}

fn getRegistryNamehash(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const registry = getRegistryCtx(ctx);
    return FieldValue{ .hash = registry.namehash };
}

fn getRegistryParentRegistry(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const registry = getRegistryCtx(ctx);
    return FieldValue{ .address = registry.parent_registry };
}

fn getRegistryCreatedBlock(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const registry = getRegistryCtx(ctx);
    return FieldValue{ .int = @intCast(registry.created_block) };
}

fn getRegistryCreatedAt(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const registry = getRegistryCtx(ctx);
    return FieldValue{ .int = registry.created_at };
}

/// Registry field definitions table
pub const RegistryFields = [_]FieldDef{
    FieldDef.address("address", getRegistryAddress),
    FieldDef.string("name", getRegistryName),
    FieldDef.hashField("namehash", getRegistryNamehash),
    FieldDef.address("parentRegistry", getRegistryParentRegistry),
    FieldDef.int("createdBlock", getRegistryCreatedBlock),
    FieldDef.int("createdAt", getRegistryCreatedAt),
};

// ============================================================================
// REGISTRATION FIELD DEFINITIONS (uses Event model)
// ============================================================================

/// Registration uses Event as underlying model
fn getRegistrationName(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const event = getEventCtx(ctx);
    return FieldValue{ .optional_string = event.name };
}

fn getRegistrationBlock(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const event = getEventCtx(ctx);
    return FieldValue{ .int = @intCast(event.block_number) };
}

fn getRegistrationTimestamp(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const event = getEventCtx(ctx);
    return FieldValue{ .int = event.timestamp };
}

fn getRegistrationProtocol(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const event = getEventCtx(ctx);
    return FieldValue{ .string = event.protocol.toString() };
}

/// Registration economic field getters. All four columns are optional —
/// they're NULL until the matching ETH Controller event arrives and the
/// indexer enriches the row via updateRegistrationEconomics. The fields
/// are decimal-string u256 (cost, baseCost, premium) or 0x-prefixed hex
/// (referrer); see schema.graphql comments and models.Event for rationale.
fn getRegistrationBaseCost(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const event = getEventCtx(ctx);
    return FieldValue{ .optional_string = event.base_cost };
}

fn getRegistrationPremium(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const event = getEventCtx(ctx);
    return FieldValue{ .optional_string = event.premium };
}

fn getRegistrationLabelName(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const event = getEventCtx(ctx);
    return FieldValue{ .optional_string = event.label_name };
}

fn getRegistrationReferrer(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const event = getEventCtx(ctx);
    return FieldValue{ .optional_string = event.referrer };
}

/// `cost = base_cost + premium`. Computed lazily because we don't store
/// a redundant column. Custom writer so the temporary allocation has a
/// clean lifetime (returning an allocated string via FieldValue.optional_string
/// would leak — the dispatcher in lib/graphql/fields.zig doesn't free getter
/// return values, and we can't safely escape/free in-line).
fn writeRegistrationCost(ctx: *anyopaque, output_key: []const u8, writer: std.ArrayList(u8).Writer, allocator: std.mem.Allocator) !bool {
    const event = getEventCtx(ctx);
    const base = event.base_cost orelse {
        try writer.print("\"{s}\":null", .{output_key});
        return true;
    };
    const premium = event.premium orelse "0";

    // Parse u256 decimal strings, sum, render back. base+premium can't
    // overflow u256 for any realistic registration; wrapping add is safe.
    const base_u = std.fmt.parseInt(u256, base, 10) catch {
        try writer.print("\"{s}\":null", .{output_key});
        return true;
    };
    const premium_u = std.fmt.parseInt(u256, premium, 10) catch {
        try writer.print("\"{s}\":null", .{output_key});
        return true;
    };
    const total = base_u +% premium_u;

    const total_str = try std.fmt.allocPrint(allocator, "{d}", .{total});
    defer allocator.free(total_str);
    try writer.print("\"{s}\":\"{s}\"", .{ output_key, total_str });
    return true;
}

/// Registration field definitions table
/// Note: expiryDate, registrant, and domain are handled as nested fields
/// because they require database access and JSON parsing
pub const RegistrationFields = [_]FieldDef{
    FieldDef.optionalString("id", getRegistrationName),
    FieldDef.optionalString("name", getRegistrationName),
    FieldDef.int("block", getRegistrationBlock),
    FieldDef.int("blockNumber", getRegistrationBlock),
    FieldDef.int("timestamp", getRegistrationTimestamp),
    FieldDef.int("registrationDate", getRegistrationTimestamp),
    FieldDef.string("protocol", getRegistrationProtocol),
    FieldDef.customScalar("cost", writeRegistrationCost),
    FieldDef.optionalString("baseCost", getRegistrationBaseCost),
    FieldDef.optionalString("premium", getRegistrationPremium),
    FieldDef.optionalString("labelName", getRegistrationLabelName),
    FieldDef.optionalString("referrer", getRegistrationReferrer),
};

// ============================================================================
// RESOLVER METADATA FIELD DEFINITIONS
// ============================================================================

fn getResolverMetadataCtx(ctx: *anyopaque) *const models.ResolverMetadata {
    return @ptrCast(@alignCast(ctx));
}

fn getResolverMetadataId(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const metadata = getResolverMetadataCtx(ctx);
    return FieldValue{ .int = @intCast(metadata.id) };
}

fn getResolverMetadataResolver(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const metadata = getResolverMetadataCtx(ctx);
    return FieldValue{ .address = metadata.resolver };
}

fn getResolverMetadataGraphqlUrl(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const metadata = getResolverMetadataCtx(ctx);
    return FieldValue{ .string = metadata.graphql_url };
}

fn getResolverMetadataBlockNumber(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const metadata = getResolverMetadataCtx(ctx);
    return FieldValue{ .int = @intCast(metadata.block_number) };
}

fn getResolverMetadataTransactionHash(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const metadata = getResolverMetadataCtx(ctx);
    return FieldValue{ .hash = metadata.tx_hash };
}

fn getResolverMetadataTimestamp(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const metadata = getResolverMetadataCtx(ctx);
    return FieldValue{ .int = metadata.timestamp };
}

/// Custom writer for resolver metadata ID (as string)
fn writeResolverMetadataId(ctx: *anyopaque, output_key: []const u8, writer: std.ArrayList(u8).Writer, _: std.mem.Allocator) !bool {
    const metadata = getResolverMetadataCtx(ctx);
    try writer.print("\"{s}\":\"{d}\"", .{ output_key, metadata.id });
    return true;
}

/// Resolver metadata field definitions table
pub const ResolverMetadataFields = [_]FieldDef{
    FieldDef.customScalar("id", writeResolverMetadataId),
    FieldDef.address("resolver", getResolverMetadataResolver),
    FieldDef.string("graphqlUrl", getResolverMetadataGraphqlUrl),
    FieldDef.int("blockNumber", getResolverMetadataBlockNumber),
    FieldDef.hashField("transactionHash", getResolverMetadataTransactionHash),
    FieldDef.int("timestamp", getResolverMetadataTimestamp),
};

// ============================================================================
// RESOLVER APPROVAL FIELD DEFINITIONS
// ============================================================================

fn getResolverApprovalCtx(ctx: *anyopaque) *const models.ResolverApproval {
    return @ptrCast(@alignCast(ctx));
}

fn getResolverApprovalId(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const approval = getResolverApprovalCtx(ctx);
    return FieldValue{ .int = @intCast(approval.id) };
}

fn getResolverApprovalResolver(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const approval = getResolverApprovalCtx(ctx);
    return FieldValue{ .address = approval.resolver };
}

fn getResolverApprovalNamehash(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const approval = getResolverApprovalCtx(ctx);
    return FieldValue{ .hash = approval.namehash };
}

fn getResolverApprovalContext(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const approval = getResolverApprovalCtx(ctx);
    return FieldValue{ .optional_string = approval.context };
}

fn getResolverApprovalDelegate(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const approval = getResolverApprovalCtx(ctx);
    return FieldValue{ .address = approval.delegate };
}

fn getResolverApprovalApproved(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const approval = getResolverApprovalCtx(ctx);
    return FieldValue{ .bool_val = approval.approved };
}

fn getResolverApprovalBlockNumber(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const approval = getResolverApprovalCtx(ctx);
    return FieldValue{ .int = @intCast(approval.block_number) };
}

fn getResolverApprovalTransactionHash(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const approval = getResolverApprovalCtx(ctx);
    return FieldValue{ .hash = approval.tx_hash };
}

fn getResolverApprovalLogIndex(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const approval = getResolverApprovalCtx(ctx);
    return FieldValue{ .int = @intCast(approval.log_index) };
}

fn getResolverApprovalTimestamp(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const approval = getResolverApprovalCtx(ctx);
    return FieldValue{ .int = approval.timestamp };
}

/// Custom writer for resolver approval ID (as string)
fn writeResolverApprovalId(ctx: *anyopaque, output_key: []const u8, writer: std.ArrayList(u8).Writer, _: std.mem.Allocator) !bool {
    const approval = getResolverApprovalCtx(ctx);
    try writer.print("\"{s}\":\"{d}\"", .{ output_key, approval.id });
    return true;
}

/// Resolver approval field definitions table
pub const ResolverApprovalFields = [_]FieldDef{
    FieldDef.customScalar("id", writeResolverApprovalId),
    FieldDef.address("resolver", getResolverApprovalResolver),
    FieldDef.hashField("namehash", getResolverApprovalNamehash),
    FieldDef.optionalString("context", getResolverApprovalContext),
    FieldDef.address("delegate", getResolverApprovalDelegate),
    FieldDef.boolean("approved", getResolverApprovalApproved),
    FieldDef.int("blockNumber", getResolverApprovalBlockNumber),
    FieldDef.hashField("transactionHash", getResolverApprovalTransactionHash),
    FieldDef.int("logIndex", getResolverApprovalLogIndex),
    FieldDef.int("timestamp", getResolverApprovalTimestamp),
};

// ============================================================================
// NAME/DOMAIN FIELD DEFINITIONS
// ============================================================================

fn getNameCtx(ctx: *anyopaque) *const models.Name {
    return @ptrCast(@alignCast(ctx));
}

fn getNameName(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const name = getNameCtx(ctx);
    return FieldValue{ .string = name.name };
}

fn getNameLabel(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const name = getNameCtx(ctx);
    return FieldValue{ .string = name.label };
}

fn getNameLabelhash(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const name = getNameCtx(ctx);
    return FieldValue{ .hash = name.label_hash };
}

/// Custom writer for name ID/name field
fn writeNameId(ctx: *anyopaque, output_key: []const u8, writer: std.ArrayList(u8).Writer, allocator: std.mem.Allocator) !bool {
    const name = getNameCtx(ctx);
    const escaped = try escapeJsonString(allocator, name.name orelse "[unknown]");
    defer allocator.free(escaped);
    try writer.print("\"{s}\":\"{s}\"", .{ output_key, escaped });
    return true;
}

/// Custom writer for owner field (nested object)
fn writeNameOwner(ctx: *anyopaque, output_key: []const u8, writer: std.ArrayList(u8).Writer, allocator: std.mem.Allocator) !bool {
    const name = getNameCtx(ctx);
    const owner_hex = try name.owner.toHex(allocator);
    defer allocator.free(owner_hex);
    try writer.print("\"{s}\":{{\"id\":\"{s}\"}}", .{ output_key, owner_hex });
    return true;
}

/// Custom writer for resolver field (nested object or null)
fn writeNameResolver(ctx: *anyopaque, output_key: []const u8, writer: std.ArrayList(u8).Writer, allocator: std.mem.Allocator) !bool {
    const name = getNameCtx(ctx);
    if (!name.resolver.isZero()) {
        const resolver_hex = try name.resolver.toHex(allocator);
        defer allocator.free(resolver_hex);
        try writer.print("\"{s}\":{{\"address\":\"{s}\"}}", .{ output_key, resolver_hex });
    } else {
        try writer.print("\"{s}\":null", .{output_key});
    }
    return true;
}

/// Custom writer for expiryDate field. For V1 .eth 2LDs, includes the 90-day
/// grace period (subgraph parity). Null when no expiry is set.
fn writeNameExpiryDate(ctx: *anyopaque, output_key: []const u8, writer: std.ArrayList(u8).Writer, _: std.mem.Allocator) !bool {
    const name = getNameCtx(ctx);
    if (hasValidExpiry(name.expiry)) {
        try writer.print("\"{s}\":{d}", .{ output_key, effectiveDomainExpiry(name) });
    } else {
        try writer.print("\"{s}\":null", .{output_key});
    }
    return true;
}

/// Check if expiry is valid. We store 0 for "no expiry" (subnames without duration).
pub fn hasValidExpiry(expiry: anytype) bool {
    return expiry > 0;
}

/// V1 BaseRegistrar grace-period: subgraph defines `Domain.expiryDate =
/// BaseRegistrar.expires + 90d` while `Registration.expiryDate = expires`.
/// We store bare `expires` on the row (matches on-chain truth) and add the
/// grace at read time only for V1 .eth 2LDs. Other names (V2, V1 subnames,
/// non-`.eth` TLDs) return the stored value unchanged.
pub const V1_GRACE_PERIOD_SECONDS: i64 = 90 * 24 * 60 * 60;
pub fn effectiveDomainExpiry(name: anytype) i64 {
    const base: i64 = @intCast(name.expiry);
    if (name.protocol != .v1) return base;
    if (name.expiry == 0) return base;
    const parent = name.parent_name orelse return base;
    if (!std.mem.eql(u8, parent, "eth")) return base;
    return base + V1_GRACE_PERIOD_SECONDS;
}

/// Name/Domain field definitions table (for simple queries)
pub const NameFields = [_]FieldDef{
    FieldDef.custom("id", writeNameId),
    FieldDef.custom("name", writeNameId),
    FieldDef.custom("owner", writeNameOwner),
    FieldDef.custom("resolver", writeNameResolver),
    FieldDef.custom("labelName", writeNameLabelName),
    FieldDef.custom("labelhash", writeNameLabelhash),
    FieldDef.custom("expiryDate", writeNameExpiryDate),
};

// ============================================================================
// DOMAIN BUILD FIELD DEFINITIONS (for json_builder)
// ============================================================================

/// Get domain token ID (as hex string)
fn getDomainTokenId(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!FieldValue {
    const name = getNameCtx(ctx);
    const hex = try std.fmt.allocPrint(allocator, "0x{x}", .{name.token_id});
    return FieldValue{ .string = hex };
}

/// Get domain canonical ID (as hex string)
fn getDomainCanonicalId(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!FieldValue {
    const name = getNameCtx(ctx);
    const hex = try std.fmt.allocPrint(allocator, "0x{x}", .{name.canonical_id});
    return FieldValue{ .string = hex };
}

/// Get domain token version
fn getDomainTokenVersion(ctx: *anyopaque, _: std.mem.Allocator) anyerror!FieldValue {
    const name = getNameCtx(ctx);
    return FieldValue{ .int = name.token_version };
}

/// Get domain isMigrated
fn getDomainIsMigrated(ctx: *anyopaque, _: std.mem.Allocator) anyerror!FieldValue {
    const name = getNameCtx(ctx);
    return FieldValue{ .bool_val = name.migrated };
}

/// Get domain namehash (hex)
fn getDomainNamehash(ctx: *anyopaque, _: std.mem.Allocator) anyerror!FieldValue {
    const name = getNameCtx(ctx);
    return FieldValue{ .hash = name.namehash };
}

/// Get domain createdAt
fn getDomainCreatedAt(ctx: *anyopaque, _: std.mem.Allocator) anyerror!FieldValue {
    const name = getNameCtx(ctx);
    return FieldValue{ .int = name.created_at };
}

/// Get domain registrationDate (current registration timestamp, updates on re-registration)
fn getDomainRegistrationDate(ctx: *anyopaque, _: std.mem.Allocator) anyerror!FieldValue {
    const name = getNameCtx(ctx);
    return FieldValue{ .int = name.registered_at };
}

/// Get domain expiry. For V1 .eth 2LDs, includes the 90-day grace period
/// (subgraph parity: `Domain.expiryDate = expires + 90d`). The bare on-chain
/// `expires` is still available via the parallel `Registration.expiryDate`.
fn getDomainExpiry(ctx: *anyopaque, _: std.mem.Allocator) anyerror!FieldValue {
    const name = getNameCtx(ctx);
    if (hasValidExpiry(name.expiry)) {
        return FieldValue{ .int = effectiveDomainExpiry(name) };
    }
    return FieldValue{ .none = {} };
}

/// Get domain isReachable
fn getDomainIsReachable(ctx: *anyopaque, _: std.mem.Allocator) anyerror!FieldValue {
    const name = getNameCtx(ctx);
    return FieldValue{ .bool_val = name.is_reachable };
}

/// Get domain unreachableSince (null when reachable)
fn getDomainUnreachableSince(ctx: *anyopaque, _: std.mem.Allocator) anyerror!FieldValue {
    const name = getNameCtx(ctx);
    if (name.unreachable_since) |ts| return FieldValue{ .int = ts };
    return FieldValue{ .none = {} };
}

/// Get domain protocol ("v1" or "v2")
fn getDomainProtocol(ctx: *anyopaque, _: std.mem.Allocator) anyerror!FieldValue {
    const name = getNameCtx(ctx);
    return FieldValue{ .string = name.protocol.toString() };
}

/// Get domain isWrapped (V1 NameWrapper state)
fn getDomainIsWrapped(ctx: *anyopaque, _: std.mem.Allocator) anyerror!FieldValue {
    const name = getNameCtx(ctx);
    return FieldValue{ .bool_val = name.is_wrapped };
}

/// Get domain fuses (V1 NameWrapper fuse bitmap, stored as decimal string).
/// Parse on read; return .none on null or parse error.
fn getDomainFuses(ctx: *anyopaque, _: std.mem.Allocator) anyerror!FieldValue {
    const name = getNameCtx(ctx);
    if (name.wrapper_fuses) |fuses_str| {
        const parsed = std.fmt.parseInt(u64, fuses_str, 10) catch return FieldValue{ .none = {} };
        return FieldValue{ .int = @intCast(parsed) };
    }
    return FieldValue{ .none = {} };
}

/// Get domain wrapperExpiry (V1 NameWrapper expiry timestamp)
fn getDomainWrapperExpiry(ctx: *anyopaque, _: std.mem.Allocator) anyerror!FieldValue {
    const name = getNameCtx(ctx);
    if (name.wrapper_expiry) |ts| return FieldValue{ .int = ts };
    return FieldValue{ .none = {} };
}

/// Get domain TTL (V1 ENS Registry `NewTTL`). Null when unset.
fn getDomainTTL(ctx: *anyopaque, _: std.mem.Allocator) anyerror!FieldValue {
    const name = getNameCtx(ctx);
    if (name.ttl) |t| return FieldValue{ .int = @intCast(t) };
    return FieldValue{ .none = {} };
}

/// Get domain isLegacy (V1 ENS Registry provenance flag).
fn getDomainIsLegacy(ctx: *anyopaque, _: std.mem.Allocator) anyerror!FieldValue {
    const name = getNameCtx(ctx);
    return FieldValue{ .bool_val = name.is_legacy };
}

/// Get domain gracePeriodEnd: subgraph semantics — `Domain.expiryDate =
/// BaseRegistrar.expires + 90d` for V1 .eth 2LDs, while `Registration.expiryDate
/// = expires` (no grace). Explicit-name alias for the same value that
/// `Domain.expiryDate` now returns. Kept for client-side discoverability —
/// some clients prefer naming the field that explicitly indicates the
/// grace-period semantic. Returns null for non-V1 / non-.eth-2LD names.
fn getDomainGracePeriodEnd(ctx: *anyopaque, _: std.mem.Allocator) anyerror!FieldValue {
    const name = getNameCtx(ctx);
    if (name.protocol != .v1) return FieldValue{ .none = {} };
    if (!hasValidExpiry(name.expiry)) return FieldValue{ .none = {} };
    const parent = name.parent_name orelse return FieldValue{ .none = {} };
    if (!std.mem.eql(u8, parent, "eth")) return FieldValue{ .none = {} };
    return FieldValue{ .int = effectiveDomainExpiry(name) };
}

/// Domain build field definitions - scalar fields only
/// Nested fields (owner, registrant, resolver, etc.) are handled via NestedFieldDef
pub const DomainBuildFields = [_]FieldDef{
    FieldDef.customScalar("id", writeNameId),
    FieldDef.customScalar("name", writeNameId),
    FieldDef.hashField("namehash", getDomainNamehash),
    FieldDef.customScalar("labelName", writeNameLabelName),
    FieldDef.customScalar("labelhash", writeNameLabelhash),
    FieldDef.string("tokenId", getDomainTokenId),
    FieldDef.string("canonicalId", getDomainCanonicalId),
    FieldDef.int("tokenVersion", getDomainTokenVersion),
    FieldDef.boolean("isMigrated", getDomainIsMigrated),
    FieldDef.string("protocol", getDomainProtocol),
    FieldDef.boolean("isReachable", getDomainIsReachable),
    FieldDef.int("unreachableSince", getDomainUnreachableSince),
    FieldDef.boolean("isWrapped", getDomainIsWrapped),
    FieldDef.int("fuses", getDomainFuses),
    FieldDef.int("wrapperExpiry", getDomainWrapperExpiry),
    FieldDef.int("ttl", getDomainTTL),
    FieldDef.boolean("isLegacy", getDomainIsLegacy),
    FieldDef.int("gracePeriodEnd", getDomainGracePeriodEnd),
    FieldDef.int("createdAt", getDomainCreatedAt),
    FieldDef.int("registrationDate", getDomainRegistrationDate),
};

/// Custom writer for labelName
fn writeNameLabelName(ctx: *anyopaque, output_key: []const u8, writer: std.ArrayList(u8).Writer, allocator: std.mem.Allocator) !bool {
    const name = getNameCtx(ctx);
    const escaped = try escapeJsonString(allocator, name.label orelse "[unknown]");
    defer allocator.free(escaped);
    try writer.print("\"{s}\":\"{s}\"", .{ output_key, escaped });
    return true;
}

/// Custom writer for labelhash
fn writeNameLabelhash(ctx: *anyopaque, output_key: []const u8, writer: std.ArrayList(u8).Writer, allocator: std.mem.Allocator) !bool {
    const name = getNameCtx(ctx);
    const hash_hex = try name.label_hash.toHex(allocator);
    defer allocator.free(hash_hex);
    try writer.print("\"{s}\":\"{s}\"", .{ output_key, hash_hex });
    return true;
}

// ============================================================================
// ACCOUNT FIELD DEFINITIONS
// ============================================================================

/// Helper to get Address pointer from context
fn getAddressCtx(ctx: *anyopaque) *const Address {
    return @ptrCast(@alignCast(ctx));
}

/// Get account id (address as hex)
fn getAccountId(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!FieldValue {
    const addr = getAddressCtx(ctx);
    const hex = try addr.toHex(allocator);
    return FieldValue{ .string = hex };
}

/// Account field definitions - only scalar field is "id"
/// Nested fields (domains, registrations) are handled via NestedFieldDef
pub const AccountFields = [_]FieldDef{
    FieldDef.string("id", getAccountId),
};

// ============================================================================
// RESOLVER BUILD CONTEXT FIELD DEFINITIONS
// ============================================================================

/// Context for building Resolver JSON
/// Holds the (chainId, protocol, address, namehash) quadruple — superset of
/// the entity table's UNIQUE key so the entity ID can be rendered as
/// `{chainId}-{protocol}-{address}-{namehash}`. ChainId leads so the ID
/// stays globally unique once this indexer extends to multi-chain plugins
/// (basenames, lineanames, 3DNS). The `v1`/`v2` protocol segment stays
/// because V1 and V2 share a single chain's namehash space — collisions are
/// inevitable otherwise once names are migrated keeping the same resolver.
pub const ResolverBuildContext = struct {
    resolver: Address,
    namehash: Hash,
    protocol: models.Protocol,
    chain_id: u64,
};

/// Helper to get ResolverBuildContext from opaque pointer
fn getResolverBuildCtx(ctx: *anyopaque) *const ResolverBuildContext {
    return @ptrCast(@alignCast(ctx));
}

/// Get resolver entity id `{chainId}-{protocol}-{address}-{namehash}`.
/// Phase 4b changed this from address-only to a triple for subgraph parity.
/// A follow-up extends it to a quadruple with the leading chain ID, making
/// the ID safe to merge across chains the day this indexer adds multi-chain
/// plugin support without a schema migration. Reading `domain.resolver.id`
/// returns the entity ID, NOT the raw contract address — clients that need
/// the bare address should select `domain.resolver.address` instead.
fn getResolverBuildId(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!FieldValue {
    const rctx = getResolverBuildCtx(ctx);
    const addr_hex = try rctx.resolver.toHex(allocator);
    defer allocator.free(addr_hex);
    const namehash_hex = try rctx.namehash.toHex(allocator);
    defer allocator.free(namehash_hex);
    const id = try std.fmt.allocPrint(allocator, "{d}-{s}-{s}-{s}", .{
        rctx.chain_id,
        rctx.protocol.toString(),
        addr_hex,
        namehash_hex,
    });
    return FieldValue{ .string = id };
}

/// Address-only view of the resolver contract.
fn getResolverBuildAddress(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!FieldValue {
    const rctx = getResolverBuildCtx(ctx);
    const hex = try rctx.resolver.toHex(allocator);
    return FieldValue{ .string = hex };
}

/// Resolver build field definitions - scalar fields only
/// Nested fields (addr, addresses, contentHash, texts, text) are handled via NestedFieldDef
pub const ResolverBuildFields = [_]FieldDef{
    FieldDef.string("id", getResolverBuildId),
    FieldDef.string("address", getResolverBuildAddress),
};

// ============================================================================
// TESTS
// ============================================================================

test "FieldDef creation" {
    // Test that field definitions are created correctly
    const def1 = FieldDef.string("name", getEventType);
    try std.testing.expectEqualStrings("name", def1.name);
    try std.testing.expectEqual(FieldType.string, def1.field_type);

    const def2 = FieldDef.int("count", getEventBlockNumber);
    try std.testing.expectEqual(FieldType.int, def2.field_type);

    const def3 = FieldDef.optionalString("description", getEventName);
    try std.testing.expectEqual(FieldType.optional_string, def3.field_type);

    const def4 = FieldDef.address("addr", getEventContractAddress);
    try std.testing.expectEqual(FieldType.address, def4.field_type);

    const def5 = FieldDef.hashField("hash", getEventTransactionHash);
    try std.testing.expectEqual(FieldType.hash, def5.field_type);
}
