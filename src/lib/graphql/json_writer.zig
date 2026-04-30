/// Tiny stream-based JSON object/array builders.
///
/// The GraphQL response-building in `src/api/builders/impl.zig` repeatedly does:
///   - open `{` / `[`, track first-field vs subsequent (for commas), escape strings,
///     print `"name":"value"`, close `}` / `]`.
///
/// These helpers fold that pattern into a typed, stateful writer so handlers don't
/// have to manually track `first_subfield` booleans or worry about missed commas /
/// double-escapes.
///
/// Generic over the writer's concrete type (ArrayList.Writer, Io.Writer, ...) via
/// `anytype`. The `on(writer)` constructor returns the correctly-parameterized
/// builder without the caller having to spell out the type.
///
/// Escaping delegates to `fields.escapeJsonString` so this module stays ENS-agnostic.
const std = @import("std");
const fields = @import("fields.zig");

/// Begin a JSON object on `writer`. Caller must `end()` to close it.
pub fn objectOn(writer: anytype) !Object(@TypeOf(writer)) {
    return Object(@TypeOf(writer)).begin(writer);
}

/// Begin a JSON array on `writer`. Caller must `end()` to close it.
pub fn arrayOn(writer: anytype) !Array(@TypeOf(writer)) {
    return Array(@TypeOf(writer)).begin(writer);
}

pub fn Object(comptime W: type) type {
    return struct {
        writer: W,
        first: bool,

        const Self = @This();

        pub fn begin(writer: W) !Self {
            try writer.writeAll("{");
            return .{ .writer = writer, .first = true };
        }

        pub fn end(self: *Self) !void {
            try self.writer.writeAll("}");
        }

        fn sep(self: *Self) !void {
            if (!self.first) try self.writer.writeAll(",");
            self.first = false;
        }

        pub fn fieldStr(self: *Self, name: []const u8, value: []const u8, allocator: std.mem.Allocator) !void {
            try self.sep();
            const escaped = try fields.escapeJsonString(allocator, value);
            defer allocator.free(escaped);
            try self.writer.print("\"{s}\":\"{s}\"", .{ name, escaped });
        }

        pub fn fieldOptStr(self: *Self, name: []const u8, value: ?[]const u8, allocator: std.mem.Allocator) !void {
            if (value) |v| {
                try self.fieldStr(name, v, allocator);
            } else {
                try self.fieldNull(name);
            }
        }

        pub fn fieldInt(self: *Self, name: []const u8, value: anytype) !void {
            try self.sep();
            try self.writer.print("\"{s}\":{d}", .{ name, value });
        }

        pub fn fieldBool(self: *Self, name: []const u8, value: bool) !void {
            try self.sep();
            try self.writer.print("\"{s}\":{s}", .{ name, if (value) "true" else "false" });
        }

        pub fn fieldNull(self: *Self, name: []const u8) !void {
            try self.sep();
            try self.writer.print("\"{s}\":null", .{name});
        }

        /// Insert a raw, pre-escaped JSON fragment as the value for `name`.
        /// Useful when the value is a nested object/array already serialized by another handler.
        pub fn fieldRaw(self: *Self, name: []const u8, raw_json: []const u8) !void {
            try self.sep();
            try self.writer.print("\"{s}\":{s}", .{ name, raw_json });
        }

        /// Open a nested object under `name`. Caller must `end()` the returned Object.
        pub fn beginObject(self: *Self, name: []const u8) !Object(W) {
            try self.sep();
            try self.writer.print("\"{s}\":", .{name});
            return Object(W).begin(self.writer);
        }

        /// Open a nested array under `name`. Caller must `end()` the returned Array.
        pub fn beginArray(self: *Self, name: []const u8) !Array(W) {
            try self.sep();
            try self.writer.print("\"{s}\":", .{name});
            return Array(W).begin(self.writer);
        }
    };
}

pub fn Array(comptime W: type) type {
    return struct {
        writer: W,
        first: bool,

        const Self = @This();

        pub fn begin(writer: W) !Self {
            try writer.writeAll("[");
            return .{ .writer = writer, .first = true };
        }

        pub fn end(self: *Self) !void {
            try self.writer.writeAll("]");
        }

        fn sep(self: *Self) !void {
            if (!self.first) try self.writer.writeAll(",");
            self.first = false;
        }

        pub fn itemStr(self: *Self, value: []const u8, allocator: std.mem.Allocator) !void {
            try self.sep();
            const escaped = try fields.escapeJsonString(allocator, value);
            defer allocator.free(escaped);
            try self.writer.print("\"{s}\"", .{escaped});
        }

        pub fn itemInt(self: *Self, value: anytype) !void {
            try self.sep();
            try self.writer.print("{d}", .{value});
        }

        pub fn itemRaw(self: *Self, raw_json: []const u8) !void {
            try self.sep();
            try self.writer.writeAll(raw_json);
        }

        pub fn beginObject(self: *Self) !Object(W) {
            try self.sep();
            return Object(W).begin(self.writer);
        }

        pub fn beginArray(self: *Self) !Array(W) {
            try self.sep();
            return Array(W).begin(self.writer);
        }
    };
}

// ============================================================================
// TESTS
// ============================================================================

const testing = std.testing;

test "Object: empty object" {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(testing.allocator);
    var obj = try objectOn(buf.writer(testing.allocator));
    try obj.end();
    try testing.expectEqualStrings("{}", buf.items);
}

test "Object: single string field" {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(testing.allocator);
    var obj = try objectOn(buf.writer(testing.allocator));
    try obj.fieldStr("name", "alice.eth", testing.allocator);
    try obj.end();
    try testing.expectEqualStrings("{\"name\":\"alice.eth\"}", buf.items);
}

test "Object: multiple fields, comma handling" {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(testing.allocator);
    var obj = try objectOn(buf.writer(testing.allocator));
    try obj.fieldStr("name", "alice.eth", testing.allocator);
    try obj.fieldInt("count", 3);
    try obj.fieldBool("isMigrated", true);
    try obj.fieldNull("resolver");
    try obj.end();
    try testing.expectEqualStrings(
        "{\"name\":\"alice.eth\",\"count\":3,\"isMigrated\":true,\"resolver\":null}",
        buf.items,
    );
}

test "Object: string escaping" {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(testing.allocator);
    var obj = try objectOn(buf.writer(testing.allocator));
    try obj.fieldStr("q", "a\"b\\c\nd", testing.allocator);
    try obj.end();
    try testing.expectEqualStrings("{\"q\":\"a\\\"b\\\\c\\nd\"}", buf.items);
}

test "Array: empty" {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(testing.allocator);
    var arr = try arrayOn(buf.writer(testing.allocator));
    try arr.end();
    try testing.expectEqualStrings("[]", buf.items);
}

test "Array: mixed items" {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(testing.allocator);
    var arr = try arrayOn(buf.writer(testing.allocator));
    try arr.itemStr("a", testing.allocator);
    try arr.itemInt(42);
    try arr.itemRaw("null");
    try arr.end();
    try testing.expectEqualStrings("[\"a\",42,null]", buf.items);
}

test "Array of objects (nested): resolver.addresses shape" {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(testing.allocator);
    var arr = try arrayOn(buf.writer(testing.allocator));
    {
        var o = try arr.beginObject();
        try o.fieldInt("coinType", 60);
        try o.fieldStr("address", "0xdead", testing.allocator);
        try o.end();
    }
    {
        var o = try arr.beginObject();
        try o.fieldInt("coinType", 0);
        try o.fieldStr("address", "bc1qbtc", testing.allocator);
        try o.end();
    }
    try arr.end();
    try testing.expectEqualStrings(
        "[{\"coinType\":60,\"address\":\"0xdead\"},{\"coinType\":0,\"address\":\"bc1qbtc\"}]",
        buf.items,
    );
}

test "Object with nested object field" {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(testing.allocator);
    var obj = try objectOn(buf.writer(testing.allocator));
    try obj.fieldStr("id", "x", testing.allocator);
    {
        var inner = try obj.beginObject("meta");
        try inner.fieldBool("ok", true);
        try inner.end();
    }
    try obj.end();
    try testing.expectEqualStrings("{\"id\":\"x\",\"meta\":{\"ok\":true}}", buf.items);
}
