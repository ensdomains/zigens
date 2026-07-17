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
    /// Optional live-resolution context (cast to resolve.universal.LiveContext by the
    /// record-read handlers). Default null; propagated from the parent context at every
    /// nested-context construction, so a missed propagation just disables the fallback
    /// on that branch (fail-safe = pre-existing indexed-only behavior).
    resolve: ?*anyopaque = null,
    /// Optional at-block reconstruction state (cast to storage.at_block.AtBlockState).
    /// Set ONLY on the single at-block entity's serve path (resolveDomain -> its own
    /// resolver/record fields); deliberately NOT propagated into nested domain entities
    /// (parent/subdomains), which serve current state — a missed site fails safe to
    /// current-state reads, never to mixed history.
    at_block: ?*const anyopaque = null,
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

    var json: std.Io.Writer.Allocating = .init(allocator);
    errdefer json.deinit();
    const writer = &json.writer;

    try writer.writeAll("{");
    var first = true;

    // GraphQL §5.3.2: fields with the same response name (alias or name) are merged.
    // Per-row dedup of output_key. A small stack-backed slice of seen keys is faster
    // than initializing+deiniting a StringHashMap for every entity row in a list query
    // — typical selection size is well under MAX_SEEN_KEYS, and string equality on a
    // short list dominates HashMap setup cost at this scale.
    const MAX_SEEN_KEYS = 64;
    var seen_keys_buf: [MAX_SEEN_KEYS][]const u8 = undefined;
    var seen_keys_len: usize = 0;

    for (selections) |*field| {
        // Use alias if provided, otherwise use field name (GraphQL spec compliance)
        const output_key = field.alias orelse field.name;

        // Dedup via linear scan. selections.len is bounded by GraphQL complexity
        // limits; a HashMap would amortize better at thousands of fields, which we
        // never see (cap is ~50 cost on a single field's children).
        var already_seen = false;
        var k: usize = 0;
        while (k < seen_keys_len) : (k += 1) {
            if (std.mem.eql(u8, seen_keys_buf[k], output_key)) {
                already_seen = true;
                break;
            }
        }
        if (already_seen) continue;
        if (seen_keys_len < MAX_SEEN_KEYS) {
            seen_keys_buf[seen_keys_len] = output_key;
            seen_keys_len += 1;
        }

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

        // GraphQL §5.3.3: a sub-selection (`field { foo }`) is only valid for object/list types.
        // If the field maps to a scalar FieldDef, sub-selections are an error per spec — silent
        // tolerance hides client mistakes (e.g. `texts { key value }` against a `[String!]` field
        // or `name { foo }` on a String field).
        if (field.selections.len > 0) {
            for (config.field_defs) |def| {
                if (std.mem.eql(u8, def.name, field.name) and def.field_type != .custom) {
                    // FieldDef.custom = object/list writer (sub-selections honored by writer).
                    // All other types (including custom_scalar) are scalars and must reject sub-selections.
                    return error.SubSelectionOnScalar;
                }
            }
        }

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
    // toOwnedSlice transfers the backing buffer directly to the caller — saves the
    // dupe-then-free round trip vs `allocator.dupe(u8, json.written())`.
    return try json.toOwnedSlice();
}
