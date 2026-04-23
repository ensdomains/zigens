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
    /// Custom function for complex fields (nested objects, computed values)
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

    /// Create a custom field with direct writer access
    pub fn custom(name: []const u8, writer_fn: CustomWriter) FieldDef {
        return .{ .name = name, .field_type = .custom, .getter = null, .custom_writer = writer_fn };
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
    // Handle custom fields
    if (def.field_type == .custom) {
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

fn getEventChain(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const event = getEventCtx(ctx);
    return FieldValue{ .string = event.chain.toString() };
}

fn getEventData(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const event = getEventCtx(ctx);
    return FieldValue{ .optional_string = event.data };
}

/// Event field definitions table
pub const EventFields = [_]FieldDef{
    FieldDef.custom("id", writeEventId),
    FieldDef.string("type", getEventType),
    FieldDef.int("blockNumber", getEventBlockNumber),
    FieldDef.hashField("transactionHash", getEventTransactionHash),
    FieldDef.int("timestamp", getEventTimestamp),
    FieldDef.optionalString("name", getEventName),
    FieldDef.optionalHash("namehash", getEventNamehash),
    FieldDef.address("contractAddress", getEventContractAddress),
    FieldDef.string("chain", getEventChain),
    FieldDef.optionalString("data", getEventData),
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
    FieldDef.custom("id", writeEACRoleId),
    FieldDef.string("resource", getEACRoleResource),
    FieldDef.custom("account", writeEACRoleAccount),
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

fn getRegistrationChain(ctx: *anyopaque, _: std.mem.Allocator) !FieldValue {
    const event = getEventCtx(ctx);
    return FieldValue{ .string = event.chain.toString() };
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
    FieldDef.string("chain", getRegistrationChain),
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
    FieldDef.custom("id", writeResolverMetadataId),
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
    FieldDef.custom("id", writeResolverApprovalId),
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

/// Custom writer for expiryDate field (null if not valid)
fn writeNameExpiryDate(ctx: *anyopaque, output_key: []const u8, writer: std.ArrayList(u8).Writer, _: std.mem.Allocator) !bool {
    const name = getNameCtx(ctx);
    if (hasValidExpiry(name.expiry)) {
        try writer.print("\"{s}\":{d}", .{ output_key, name.expiry });
    } else {
        try writer.print("\"{s}\":null", .{output_key});
    }
    return true;
}

/// Check if expiry is valid. We store 0 for "no expiry" (subnames without duration).
pub fn hasValidExpiry(expiry: anytype) bool {
    return expiry > 0;
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

/// Get domain expiry (may be null)
fn getDomainExpiry(ctx: *anyopaque, _: std.mem.Allocator) anyerror!FieldValue {
    const name = getNameCtx(ctx);
    if (hasValidExpiry(name.expiry)) {
        return FieldValue{ .int = name.expiry };
    }
    return FieldValue{ .none = {} };
}

/// Domain build field definitions - scalar fields only
/// Nested fields (owner, registrant, resolver, etc.) are handled via NestedFieldDef
pub const DomainBuildFields = [_]FieldDef{
    FieldDef.custom("id", writeNameId),
    FieldDef.custom("name", writeNameId),
    FieldDef.custom("labelName", writeNameLabelName),
    FieldDef.custom("labelhash", writeNameLabelhash),
    FieldDef.string("tokenId", getDomainTokenId),
    FieldDef.string("canonicalId", getDomainCanonicalId),
    FieldDef.int("tokenVersion", getDomainTokenVersion),
    FieldDef.boolean("isMigrated", getDomainIsMigrated),
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
/// Holds both resolver address and domain namehash needed for nested queries
pub const ResolverBuildContext = struct {
    resolver: Address,
    namehash: Hash,
};

/// Helper to get ResolverBuildContext from opaque pointer
fn getResolverBuildCtx(ctx: *anyopaque) *const ResolverBuildContext {
    return @ptrCast(@alignCast(ctx));
}

/// Get resolver id (address as hex)
fn getResolverBuildId(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!FieldValue {
    const rctx = getResolverBuildCtx(ctx);
    const hex = try rctx.resolver.toHex(allocator);
    return FieldValue{ .string = hex };
}

/// Resolver build field definitions - scalar fields only
/// Nested fields (addr, addresses, contentHash, texts, text) are handled via NestedFieldDef
pub const ResolverBuildFields = [_]FieldDef{
    FieldDef.string("id", getResolverBuildId),
    FieldDef.string("address", getResolverBuildId),
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
