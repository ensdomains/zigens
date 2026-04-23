/// Shared helpers and constants for the ENS GraphQL API layer.
///
/// Neutral module: imports nothing from `api/builders/` or `api/resolvers/`.
/// Both of those may safely import from here without risk of cycles.
const std = @import("std");
const parser = @import("../lib/graphql/parser.zig");
const Address = @import("../types/address.zig").Address;

// ============================================================================
// LIMITS
// ============================================================================

/// Maximum page size for list queries. Caps hostile `first: 999999` requests
/// at a size that keeps server-side allocations bounded.
pub const MAX_FIRST: i64 = 1000;

/// Default skip (offset) when pagination args are omitted.
pub const DEFAULT_SKIP: i64 = 0;

// ============================================================================
// PAGINATION
// ============================================================================

pub const Pagination = struct {
    first: u32,
    skip: u32,
};

/// Parse `first` / `skip` from a GraphQL field. Clamps `first` to `[0, MAX_FIRST]`
/// and `skip` to `[0, ∞)` so malicious or malformed inputs (e.g. `first: -1`)
/// cannot cause `@intCast` panics or unbounded allocations downstream.
///
/// For Relay-style connection queries, use `lib/graphql/pagination.PaginationParams.parse`
/// instead — this helper is for flat list queries that take `first`/`skip` directly.
pub fn parsePagination(field: *const parser.Field, default_first: i64) Pagination {
    const first_raw = parser.getIntArg(field, "first", default_first) orelse default_first;
    const skip_raw = parser.getIntArg(field, "skip", DEFAULT_SKIP) orelse DEFAULT_SKIP;
    const first_clamped = @min(@max(first_raw, 0), MAX_FIRST);
    const skip_clamped = @max(skip_raw, 0);
    return .{
        .first = @intCast(first_clamped),
        .skip = @intCast(skip_clamped),
    };
}

// ============================================================================
// ORDER DIRECTION
// ============================================================================

/// Parse `orderDirection` arg into any enum that has `.asc` and `.desc` variants.
/// Falls back to `default` when the arg is missing or unrecognized.
///
/// Works with both `db.OrderDir` and `db.EventOrderDir` — the comptime type parameter
/// avoids duplicating this logic per enum.
pub fn parseOrderDirection(field: *const parser.Field, comptime T: type, default: T) T {
    const str = parser.getStringArg(field, "orderDirection", null) orelse return default;
    if (std.mem.eql(u8, str, "desc")) return @as(T, .desc);
    if (std.mem.eql(u8, str, "asc")) return @as(T, .asc);
    return default;
}

// ============================================================================
// FILTER (where: { ... }) PARSING
// ============================================================================
//
// The matchXArg helpers fold the common "if name matches and value is right type,
// assign to out" pattern into one line per filter field. Each returns `true` when
// the arg *name* matched (whether or not the value type matched), so callers can
// chain them with `or` to short-circuit further comparisons for the same arg.
// A mismatched value type is silently ignored (same behavior as the inline version).

/// Get the `[]Argument` backing a field's named object-argument, or null if absent/wrong-type.
/// Used to retrieve `where: { ... }` before iterating its contents.
pub fn getObjectArg(field: *const parser.Field, name: []const u8) ?[]parser.Argument {
    for (field.arguments) |*arg| {
        if (std.mem.eql(u8, arg.name, name)) {
            return switch (arg.value) {
                .object => |obj| obj,
                else => null,
            };
        }
    }
    return null;
}

pub fn matchStringArg(arg: parser.Argument, name: []const u8, out: *?[]const u8) bool {
    if (!std.mem.eql(u8, arg.name, name)) return false;
    if (arg.value == .string) out.* = arg.value.string;
    return true;
}

pub fn matchIntArg(arg: parser.Argument, name: []const u8, out: *?i64) bool {
    if (!std.mem.eql(u8, arg.name, name)) return false;
    if (arg.value == .int) out.* = arg.value.int;
    return true;
}

pub fn matchBoolArg(arg: parser.Argument, name: []const u8, out: *?bool) bool {
    if (!std.mem.eql(u8, arg.name, name)) return false;
    if (arg.value == .boolean) out.* = arg.value.boolean;
    return true;
}

/// Match a filter arg and parse its string value as an Address. Invalid hex leaves `out` unchanged.
pub fn matchAddressArg(arg: parser.Argument, name: []const u8, out: *?Address) bool {
    if (!std.mem.eql(u8, arg.name, name)) return false;
    if (arg.value == .string) {
        if (Address.fromHex(arg.value.string)) |addr| {
            out.* = addr;
        } else |_| {}
    }
    return true;
}

// ============================================================================
// TESTS
// ============================================================================

const testing = std.testing;

fn makeField(args: []parser.Argument) parser.Field {
    return .{
        .name = "",
        .alias = null,
        .arguments = args,
        .selections = &[_]parser.Field{},
        .fragment_spread = null,
        .directives = &[_]parser.Directive{},
    };
}

test "parsePagination clamps negative first to 0 and huge first to MAX_FIRST" {
    var args = [_]parser.Argument{
        .{ .name = "first", .value = .{ .int = -5 } },
    };
    const p1 = parsePagination(&makeField(&args), 100);
    try testing.expectEqual(@as(u32, 0), p1.first);

    var args2 = [_]parser.Argument{
        .{ .name = "first", .value = .{ .int = 999999 } },
    };
    const p2 = parsePagination(&makeField(&args2), 100);
    try testing.expectEqual(@as(u32, @intCast(MAX_FIRST)), p2.first);
}

test "matchStringArg assigns on name+type match, returns true on name match only" {
    var out: ?[]const u8 = null;

    // name match + string value → assigns, returns true
    try testing.expect(matchStringArg(.{ .name = "foo", .value = .{ .string = "bar" } }, "foo", &out));
    try testing.expectEqualStrings("bar", out.?);

    // name mismatch → no assignment, returns false
    out = null;
    try testing.expect(!matchStringArg(.{ .name = "baz", .value = .{ .string = "x" } }, "foo", &out));
    try testing.expect(out == null);

    // name match + wrong value type → no assignment, still returns true (caller should stop)
    out = null;
    try testing.expect(matchStringArg(.{ .name = "foo", .value = .{ .int = 42 } }, "foo", &out));
    try testing.expect(out == null);
}

test "matchIntArg and matchBoolArg" {
    var i: ?i64 = null;
    try testing.expect(matchIntArg(.{ .name = "n", .value = .{ .int = 7 } }, "n", &i));
    try testing.expectEqual(@as(i64, 7), i.?);

    var b: ?bool = null;
    try testing.expect(matchBoolArg(.{ .name = "ok", .value = .{ .boolean = true } }, "ok", &b));
    try testing.expect(b.?);
}

test "matchAddressArg parses valid hex and ignores invalid" {
    var addr: ?Address = null;
    try testing.expect(matchAddressArg(
        .{ .name = "owner", .value = .{ .string = "0x1234567890abcdef1234567890abcdef12345678" } },
        "owner",
        &addr,
    ));
    try testing.expect(addr != null);

    // Invalid hex: arg name matches, returns true, but out stays null
    var addr2: ?Address = null;
    try testing.expect(matchAddressArg(
        .{ .name = "owner", .value = .{ .string = "not-hex" } },
        "owner",
        &addr2,
    ));
    try testing.expect(addr2 == null);
}

test "getObjectArg returns inner object or null" {
    var inner = [_]parser.Argument{
        .{ .name = "name", .value = .{ .string = "alice.eth" } },
    };
    var outer = [_]parser.Argument{
        .{ .name = "where", .value = .{ .object = &inner } },
    };
    const field = makeField(&outer);
    const obj = getObjectArg(&field, "where");
    try testing.expect(obj != null);
    try testing.expectEqual(@as(usize, 1), obj.?.len);
    try testing.expectEqualStrings("name", obj.?[0].name);

    try testing.expect(getObjectArg(&field, "missing") == null);
}
