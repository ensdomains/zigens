/// Field Definition System for GraphQL
///
/// This module provides a table-driven approach to defining GraphQL fields,
/// eliminating repetitive if-else chains in field handlers.
///
/// Usage:
/// ```zig
/// const MyFields = [_]FieldDef{
///     FieldDef.string("id", getMyId),
///     FieldDef.string("type", getMyType),
///     FieldDef.int("count", getMyCount),
///     FieldDef.optionalString("description", getMyDescription),
/// };
///
/// const handled = try handleFieldFromTable(ctx, output_key, field_name, writer, allocator, &MyFields);
/// ```
const std = @import("std");

/// Field value types
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
    /// Custom function for complex fields (nested objects, computed values)
    custom,
};

/// Result of getting a field value
pub const FieldValue = union(enum) {
    string: []const u8,
    optional_string: ?[]const u8,
    int: i64,
    optional_int: ?i64,
    bool_val: bool,
    optional_bool: ?bool,
    /// Custom handlers write directly to the writer and return true if handled
    custom: bool,
    /// Field not found or error
    none: void,
};

/// Getter function type - takes context and returns field value
pub const FieldGetter = *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!FieldValue;

/// Custom writer function type - writes directly to JSON output
pub const CustomWriter = *const fn (ctx: *anyopaque, output_key: []const u8, writer: std.ArrayList(u8).Writer, allocator: std.mem.Allocator) anyerror!bool;

/// Field definition
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

    /// Create a custom field with direct writer access
    pub fn custom(name: []const u8, writer_fn: CustomWriter) FieldDef {
        return .{ .name = name, .field_type = .custom, .getter = null, .custom_writer = writer_fn };
    }
};

/// Escape a string for JSON output (RFC 8259 compliant)
/// Properly escapes ALL control characters (0x00-0x1F, 0x7F), quotes, backslashes
pub fn escapeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(allocator);

    for (input) |char| {
        switch (char) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            '\x08' => try result.appendSlice(allocator, "\\b"), // backspace
            '\x0C' => try result.appendSlice(allocator, "\\f"), // form feed
            // All other control characters (0x00-0x1F except the ones above, plus 0x7F) must be escaped as \uXXXX
            0x00...0x07, 0x0B, 0x0E...0x1F, 0x7F => {
                try result.writer(allocator).print("\\u{x:0>4}", .{char});
            },
            else => try result.append(allocator, char),
        }
    }

    return result.toOwnedSlice(allocator);
}

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
        .custom => |handled| {
            return handled;
        },
        .none => {
            return false;
        },
    }
}
