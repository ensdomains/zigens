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
const parser = @import("parser.zig");
const fields = @import("fields.zig");

/// Maximum query depth to prevent DoS attacks
pub const MAX_QUERY_DEPTH: u32 = 10;

/// Context for nested field resolution
pub const NestedContext = struct {
    database: *anyopaque,
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
    /// Field definitions for scalar fields (generic FieldDef from fields.zig)
    field_defs: []const fields.FieldDef,
    /// Optional nested field handlers
    nested_fields: []const NestedFieldDef,
};

/// Build JSON for an entity based on GraphQL field selections
/// This is the generic version that works with the base FieldDef types.
/// For ENS-specific types (Address, Hash), use the ENS-specific builder.
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

    var json: std.Io.Writer.Allocating = .init(allocator);
    errdefer json.deinit();
    const writer = &json.writer;

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
        var field_buffer: std.Io.Writer.Allocating = .init(allocator);
        defer field_buffer.deinit();

        const handled = try fields.handleFieldFromTable(
            ctx,
            output_key,
            field.name,
            &field_buffer.writer,
            allocator,
            config.field_defs,
        );

        if (handled) {
            if (!first) try writer.writeAll(",");
            try writer.writeAll(field_buffer.written());
            first = false;
        } else {
            // Unknown field - return null per GraphQL spec
            if (!first) try writer.writeAll(",");
            try writer.print("\"{s}\":null", .{output_key});
            first = false;
        }
    }

    try writer.writeAll("}");
    return try json.toOwnedSlice();
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
    var json: std.Io.Writer.Allocating = .init(allocator);
    errdefer json.deinit();
    const writer = &json.writer;

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
    return try json.toOwnedSlice();
}
