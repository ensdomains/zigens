/// Generic JSON Builder for GraphQL entities
///
/// This module provides a table-driven approach to building JSON responses
/// for GraphQL queries, eliminating repetitive if-else chains in build functions.
///
/// Usage:
/// ```zig
/// const event_json = try buildEntityJson(
///     ctx.allocator,
///     @ptrCast(event),
///     selections,
///     &EventConfig,
///     ctx,
/// );
/// ```
const std = @import("std");
const models = @import("../types/models.zig");
const db = @import("../storage/database.zig");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;

// Import generic GraphQL library
const parser = @import("../lib/graphql/parser.zig");

// Import ENS-specific field definitions
const fields = @import("ens_fields.zig");

/// Maximum query depth to prevent DoS attacks
const MAX_QUERY_DEPTH: u32 = 10;

/// Context for nested field resolution
pub const NestedContext = struct {
    database: *db.Database,
    depth: u32,
    allocator: std.mem.Allocator,
    loaders: ?*anyopaque,
};

/// Nested field handler function type
/// Returns the JSON string for a nested field, or null if not handled
pub const NestedHandler = *const fn (
    ctx: *anyopaque,
    field: *const parser.Field,
    nested_ctx: NestedContext,
) anyerror!?[]u8;

/// Nested field definition
pub const NestedFieldDef = struct {
    name: []const u8,
    handler: NestedHandler,
};

/// Entity JSON builder configuration
pub const EntityConfig = struct {
    /// GraphQL type name (for __typename)
    type_name: []const u8,
    /// Field definitions for scalar fields
    field_defs: []const fields.FieldDef,
    /// Optional nested field handlers
    nested_fields: []const NestedFieldDef,
};

/// Build JSON for an entity based on GraphQL field selections
pub fn buildEntityJson(
    allocator: std.mem.Allocator,
    ctx: *anyopaque,
    selections: []const parser.Field,
    config: *const EntityConfig,
    nested_ctx: NestedContext,
) anyerror![]u8 {
    // Check depth limit
    if (nested_ctx.depth >= MAX_QUERY_DEPTH) {
        return error.MaxDepthExceeded;
    }

    var json: std.ArrayList(u8) = .{};
    errdefer json.deinit(allocator);
    const writer = json.writer(allocator);

    try writer.writeAll("{");
    var first = true;

    for (selections) |*field| {
        // Use alias if provided, otherwise use field name (GraphQL spec compliance)
        const output_key = field.alias orelse field.name;

        // Handle __typename introspection field
        if (std.mem.eql(u8, field.name, "__typename")) {
            if (!first) try writer.writeAll(",");
            try writer.print("\"{s}\":\"{s}\"", .{ output_key, config.type_name });
            first = false;
            continue;
        }

        // Try nested field handlers first
        var handled_nested = false;
        for (config.nested_fields) |nested_def| {
            if (std.mem.eql(u8, nested_def.name, field.name)) {
                if (try nested_def.handler(ctx, field, nested_ctx)) |nested_json| {
                    defer allocator.free(nested_json);
                    if (!first) try writer.writeAll(",");
                    try writer.print("\"{s}\":", .{output_key});
                    try writer.writeAll(nested_json);
                    first = false;
                    handled_nested = true;
                    break;
                }
            }
        }
        if (handled_nested) continue;

        // Try scalar field from field definitions
        var field_buffer: std.ArrayList(u8) = .{};
        defer field_buffer.deinit(allocator);

        const handled = try fields.handleFieldFromTable(
            ctx,
            output_key,
            field.name,
            field_buffer.writer(allocator),
            allocator,
            config.field_defs,
        );

        if (handled) {
            if (!first) try writer.writeAll(",");
            try writer.writeAll(field_buffer.items);
            first = false;
        } else {
            // Unknown field - return null per GraphQL spec
            if (!first) try writer.writeAll(",");
            try writer.print("\"{s}\":null", .{output_key});
            first = false;
        }
    }

    try writer.writeAll("}");
    return try allocator.dupe(u8, json.items);
}

/// Build JSON array for a list of entities
pub fn buildEntityArrayJson(
    comptime T: type,
    allocator: std.mem.Allocator,
    items: []T,
    selections: []const parser.Field,
    config: *const EntityConfig,
    nested_ctx: NestedContext,
) anyerror![]u8 {
    var json: std.ArrayList(u8) = .{};
    errdefer json.deinit(allocator);
    const writer = json.writer(allocator);

    try writer.writeAll("[");

    for (items, 0..) |*item, i| {
        if (i > 0) try writer.writeAll(",");
        const item_json = try buildEntityJson(
            allocator,
            @ptrCast(item),
            selections,
            config,
            nested_ctx,
        );
        defer allocator.free(item_json);
        try writer.writeAll(item_json);
    }

    try writer.writeAll("]");
    return try allocator.dupe(u8, json.items);
}

// ============================================================================
// SIMPLE ENTITY CONFIGURATIONS (no nested fields)
// ============================================================================

/// Registration entity configuration
pub const RegistrationConfig = EntityConfig{
    .type_name = "Registration",
    .field_defs = &fields.RegistrationFields,
    .nested_fields = &[_]NestedFieldDef{},
};

/// EAC Role entity configuration
pub const EACRoleConfig = EntityConfig{
    .type_name = "EACRoleAssignment",
    .field_defs = &fields.EACRoleFields,
    .nested_fields = &[_]NestedFieldDef{},
};

/// Resolver entity configuration
pub const ResolverConfig = EntityConfig{
    .type_name = "Resolver",
    .field_defs = &fields.ResolverFields,
    .nested_fields = &[_]NestedFieldDef{},
};

/// Registry entity configuration
pub const RegistryConfig = EntityConfig{
    .type_name = "Registry",
    .field_defs = &fields.RegistryFields,
    .nested_fields = &[_]NestedFieldDef{},
};

/// ResolverMetadata entity configuration
pub const ResolverMetadataConfig = EntityConfig{
    .type_name = "ResolverMetadata",
    .field_defs = &fields.ResolverMetadataFields,
    .nested_fields = &[_]NestedFieldDef{},
};

/// ResolverApproval entity configuration
pub const ResolverApprovalConfig = EntityConfig{
    .type_name = "ResolverApproval",
    .field_defs = &fields.ResolverApprovalFields,
    .nested_fields = &[_]NestedFieldDef{},
};

// ============================================================================
// TESTS
// ============================================================================

test "EntityConfig structure" {
    // Test that EntityConfig structures are valid
    try std.testing.expectEqualStrings("Registration", RegistrationConfig.type_name);
    try std.testing.expect(RegistrationConfig.field_defs.len > 0);
    try std.testing.expect(RegistrationConfig.nested_fields.len == 0);

    try std.testing.expectEqualStrings("EACRoleAssignment", EACRoleConfig.type_name);
    try std.testing.expectEqualStrings("Resolver", ResolverConfig.type_name);
    try std.testing.expectEqualStrings("Registry", RegistryConfig.type_name);
}
