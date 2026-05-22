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

/// Parse `first` / `skip` from a GraphQL field. Bounds:
/// - `first`: explicitly-passed values exceeding MAX_FIRST return `error.LimitExceeded`
///   so callers don't get deceptively-truncated pages. The default (when omitted)
///   never errors. Negative values return `error.NegativeLimit`.
/// - `skip`: clamped to `[0, ∞)` (negative values silently snap to 0).
///
/// For Relay-style connection queries, use `lib/graphql/pagination.PaginationParams.parse`
/// instead — this helper is for flat list queries that take `first`/`skip` directly.
pub fn parsePagination(field: *const parser.Field, default_first: i64) !Pagination {
    // Pass null default so we can distinguish "client passed first explicitly" from "use default".
    // Only the explicit case errors on out-of-range — call sites legitimately pass large defaults.
    const first_explicit = parser.getIntArg(field, "first", null);
    const first_raw = first_explicit orelse default_first;
    const skip_raw = parser.getIntArg(field, "skip", DEFAULT_SKIP) orelse DEFAULT_SKIP;
    if (first_raw < 0) return error.NegativeLimit;
    if (first_explicit) |e| {
        if (e > MAX_FIRST) return error.LimitExceeded;
    }
    const first_clamped = @min(first_raw, MAX_FIRST);
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
// protocol them with `or` to short-circuit further comparisons for the same arg.
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

/// Match a filter arg and parse its string value as an Address.
/// Returns true if the arg name matched (regardless of whether the value parsed).
/// Returns `error.InvalidAddress` if the name matched and the value is a string but
/// fails hex parsing — silent fallthrough (returning all rows when the filter was
/// intended) is dangerous, so we surface it as an error.
pub fn matchAddressArg(arg: parser.Argument, name: []const u8, out: *?Address) !bool {
    if (!std.mem.eql(u8, arg.name, name)) return false;
    if (arg.value == .string) {
        out.* = Address.fromHex(arg.value.string) catch return error.InvalidAddress;
    }
    return true;
}

/// Collect a `[String!]` list-typed `where:` arg into a heap-owned slice of
/// borrowed `[]const u8` slices. The slices point into the GraphQL arg
/// buffer (caller-owned); only the outer container is freshly allocated.
/// Use this for filters like `name_in: [String!]`, `labelName_not_in: [String!]`,
/// `id_in: [String!]` etc. — replaces a ~9-line inline ArrayList dance at
/// each call site.
///
/// Caps the list at `constants.Pagination.max_limit` to keep filter SQL
/// bounded (large IN clauses degenerate into thousands of namehash lookups).
/// Returns `error.TooManyNames` when over the cap. Returns `null` if the
/// arg's value is not a list (caller can treat as "filter not applied").
pub fn parseStringListArg(arg: parser.Argument, allocator: std.mem.Allocator) !?[][]const u8 {
    const constants_mod = @import("../constants.zig");
    if (arg.value != .list) return null;
    if (arg.value.list.len > constants_mod.Pagination.max_limit) return error.TooManyNames;
    var list: std.ArrayList([]const u8) = .{};
    defer list.deinit(allocator);
    for (arg.value.list) |item| {
        if (item == .string) try list.append(allocator, item.string);
    }
    return try list.toOwnedSlice(allocator);
}

/// Collect a `[String!]` list-typed `where:` arg into a heap-owned slice of
/// parsed `Address`. Sister to `parseStringListArg` — for filters like
/// `owner_in: [String!]`. Surfaces `error.InvalidAddress` on any item that
/// fails hex parsing (matches `matchAddressArg`'s fail-loud semantics).
pub fn parseAddressListArg(arg: parser.Argument, allocator: std.mem.Allocator) !?[]Address {
    if (arg.value != .list) return null;
    var list: std.ArrayList(Address) = .{};
    defer list.deinit(allocator);
    for (arg.value.list) |item| {
        if (item == .string) {
            const addr = Address.fromHex(item.string) catch return error.InvalidAddress;
            try list.append(allocator, addr);
        }
    }
    return try list.toOwnedSlice(allocator);
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

test "parsePagination errors on negative first" {
    var args = [_]parser.Argument{
        .{ .name = "first", .value = .{ .int = -5 } },
    };
    try testing.expectError(error.NegativeLimit, parsePagination(&makeField(&args), 100));
}

test "parsePagination errors when explicit first exceeds MAX_FIRST" {
    var args = [_]parser.Argument{
        .{ .name = "first", .value = .{ .int = 999999 } },
    };
    try testing.expectError(error.LimitExceeded, parsePagination(&makeField(&args), 100));
}

test "parsePagination accepts default_first beyond MAX_FIRST without erroring" {
    // Default is set by the call site, not the client — silently capped is fine.
    var args = [_]parser.Argument{};
    const p = try parsePagination(&makeField(&args), MAX_FIRST + 50);
    try testing.expectEqual(@as(u32, @intCast(MAX_FIRST)), p.first);
}

test "parsePagination accepts valid first within range" {
    var args = [_]parser.Argument{
        .{ .name = "first", .value = .{ .int = 50 } },
    };
    const p = try parsePagination(&makeField(&args), 100);
    try testing.expectEqual(@as(u32, 50), p.first);
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

test "matchAddressArg parses valid hex" {
    var addr: ?Address = null;
    try testing.expect(try matchAddressArg(
        .{ .name = "owner", .value = .{ .string = "0x1234567890abcdef1234567890abcdef12345678" } },
        "owner",
        &addr,
    ));
    try testing.expect(addr != null);
}

test "matchAddressArg errors on invalid hex value" {
    var addr: ?Address = null;
    try testing.expectError(error.InvalidAddress, matchAddressArg(
        .{ .name = "owner", .value = .{ .string = "not-hex" } },
        "owner",
        &addr,
    ));
}

test "matchAddressArg returns false when name does not match" {
    var addr: ?Address = null;
    try testing.expect(!(try matchAddressArg(
        .{ .name = "other", .value = .{ .string = "0x1234567890abcdef1234567890abcdef12345678" } },
        "owner",
        &addr,
    )));
    try testing.expect(addr == null);
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
