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

/// Default page size of a list nested under an entity (`Domain.subdomains`,
/// `Account.domains`, `Account.registrations`, the nested connections) when
/// `first` is omitted. Deliberately below the root lists' 100: the complexity
/// budget charges a nested list 1 however many rows it returns, so this is
/// the only bound on nested fan-out. schema.graphql declares the same default
/// on each of those fields.
pub const NESTED_DEFAULT_FIRST: i64 = 10;

/// Default skip (offset) when pagination args are omitted.
pub const DEFAULT_SKIP: i64 = 0;

/// Maximum offset for flat `skip`-paginated queries. Bounds the value so the
/// `@intCast` to the u32 `Pagination.skip` cannot panic on a hostile
/// `skip: 9999999999` (which would otherwise crash the process), and keeps
/// deep-offset scans from becoming an amplification vector. Clients needing to
/// page deeper than this should use cursor (connection) pagination.
pub const MAX_SKIP: i64 = 1_000_000;

// ============================================================================
// STALENESS
// ============================================================================

pub const ProtocolSync = @import("../storage/sync.zig").ProtocolSync;

pub const StalenessInputs = struct {
    /// Highest block synced across protocols.
    head: u64,
    /// Chain `safe` position, or null when finality data was never fetched.
    safe: ?u64,
    /// `last_synced_at` of each protocol; null when the protocol has no
    /// sync_state row, i.e. this deployment does not index it.
    synced_at: []const ?i64,
    /// Seconds without a committed batch before the no-finality fallback
    /// trips. 0 disables the fallback.
    stale_after_seconds: u32,
    now: i64,
};

/// The `stale` flag behind /ready, /coverage, `_coverage` and the
/// `ensv2_indexing_stale` gauge. With finality data the safe-head comparison
/// is exact. Without it, and only when the fallback is armed, a deployment is
/// stale when any protocol it indexes has gone longer than the threshold
/// without committing a batch, or when no protocol has ever synced. One live
/// protocol must not mask a dead one.
///
/// The fallback is the only wall-clock read on the read path, so it is opt-in:
/// `stale_after_seconds == 0` keeps the answer a pure function of DB state.
pub fn isStale(in: StalenessInputs) bool {
    if (in.safe) |safe_num| return in.head < safe_num;
    if (in.stale_after_seconds == 0) return false;
    var any_synced = false;
    for (in.synced_at) |maybe_at| {
        const at = maybe_at orelse continue;
        if (at <= 0) continue;
        any_synced = true;
        // A timestamp ahead of this host's clock is clock skew between the
        // indexer and API hosts, not a fresh sync; it reads as age 0.
        const age = @max(in.now -| at, 0);
        if (age > in.stale_after_seconds) return true;
    }
    return !any_synced;
}

/// Seconds a `last_synced_at` may sit ahead of this host's clock before it is
/// reported as skew rather than ordinary drift between hosts.
pub const CLOCK_SKEW_WARN_SECONDS: i64 = 60;

var clock_skew_warned = std.atomic.Value(bool).init(false);

/// isStale over the two protocols' sync_state rows, shared by every surface
/// that reports staleness so they cannot disagree. Warns once per process when
/// a sync timestamp is ahead of the local clock: the fallback compares the
/// indexer host's clock with this one, and skew in that direction hides a stall.
pub fn coverageStale(v1: ?ProtocolSync, v2: ?ProtocolSync, safe: ?u64, stale_after_seconds: u32, now: i64) bool {
    const synced_at = [_]?i64{ if (v1) |s| s.at else null, if (v2) |s| s.at else null };
    if (stale_after_seconds != 0 and safe == null) {
        for (synced_at) |maybe_at| {
            const at = maybe_at orelse continue;
            if (at -| now > CLOCK_SKEW_WARN_SECONDS and !clock_skew_warned.swap(true, .monotonic)) {
                std.log.warn("coverage staleness: last_synced_at {d} is {d}s ahead of this host's clock; the indexer and API clocks disagree, so the no-finality stale check is unreliable", .{ at, at -| now });
            }
        }
    }
    return isStale(.{
        .head = indexedHead(v1, v2),
        .safe = safe,
        .synced_at = &synced_at,
        .stale_after_seconds = stale_after_seconds,
        .now = now,
    });
}

/// Highest block synced across the two protocols; 0 when neither has synced.
pub fn indexedHead(v1: ?ProtocolSync, v2: ?ProtocolSync) u64 {
    const v1_block: u64 = if (v1) |s| s.block else 0;
    const v2_block: u64 = if (v2) |s| s.block else 0;
    return @max(v1_block, v2_block);
}

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
/// - `skip`: negative values return `error.NegativeLimit`; values exceeding
///   `MAX_SKIP` return `error.LimitExceeded` (an unbounded `skip` would overflow
///   the u32 cast and crash the process).
///
/// For Relay-style connection queries, use `lib/graphql/pagination.PaginationParams.parse`
/// instead — this helper is for flat list queries that take `first`/`skip` directly.
pub fn parsePagination(field: *const parser.Field, default_first: i64) !Pagination {
    // Pass null default so we can distinguish "client passed first explicitly" from "use default".
    // Only the explicit case errors on out-of-range — call sites legitimately pass large defaults.
    const first_explicit = parser.getIntArg(field, "first", null);
    const first_raw = first_explicit orelse default_first;
    const skip_raw = parser.getIntArg(field, "skip", DEFAULT_SKIP) orelse DEFAULT_SKIP;
    if (first_raw < 0 or skip_raw < 0) return error.NegativeLimit;
    if (first_explicit) |e| {
        if (e > MAX_FIRST) return error.LimitExceeded;
    }
    if (skip_raw > MAX_SKIP) return error.LimitExceeded;
    const first_clamped = @min(first_raw, MAX_FIRST);
    return .{
        .first = @intCast(first_clamped),
        .skip = @intCast(skip_raw),
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

/// Parse the `orderBy` arg of an `Event_orderBy` field onto a storage sort
/// enum. Falls back to `default` when the arg is missing or unrecognized.
///
/// Comptime type parameter for the same reason as `parseOrderDirection`: it
/// keeps this module free of a storage dependency. Callers pass
/// `db.EventSortField`.
///
/// Keep the accepted names in sync with the `Event_orderBy` enum in
/// `schema.graphql`.
pub fn parseEventOrderBy(field: *const parser.Field, comptime T: type, default: T) T {
    const order_by = parser.getStringArg(field, "orderBy", null) orelse return default;
    if (std.mem.eql(u8, order_by, "blockNumber")) return @as(T, .block_number);
    if (std.mem.eql(u8, order_by, "timestamp")) return @as(T, .timestamp);
    if (std.mem.eql(u8, order_by, "name")) return @as(T, .name);
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
    var list: std.ArrayList([]const u8) = .empty;
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
    var list: std.ArrayList(Address) = .empty;
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

// `parseEventOrderBy` is generic so this module stays free of a storage
// dependency, so exercise it against the real `EventSortField` — a local stub
// would not catch a variant renamed on the storage side.
const EventSortField = @import("../storage/events.zig").EventSortField;
const EventOrderDir = @import("../storage/events.zig").OrderDir;

test "parseEventOrderBy maps every Event_orderBy value" {
    // Keep in sync with the `Event_orderBy` enum in schema.graphql.
    const cases = [_]struct { arg: []const u8, want: EventSortField }{
        .{ .arg = "blockNumber", .want = .block_number },
        .{ .arg = "timestamp", .want = .timestamp },
        .{ .arg = "name", .want = .name },
    };
    for (cases) |c| {
        var args = [_]parser.Argument{
            .{ .name = "orderBy", .value = .{ .string = c.arg } },
        };
        try testing.expectEqual(
            c.want,
            parseEventOrderBy(&makeField(&args), EventSortField, .block_number),
        );
    }
}

test "parseEventOrderBy falls back to default when missing or unrecognized" {
    // Missing arg: Domain.events omits orderBy on most queries, and must then
    // keep whatever the caller already resolved rather than silently resetting.
    var none = [_]parser.Argument{};
    try testing.expectEqual(
        EventSortField.timestamp,
        parseEventOrderBy(&makeField(&none), EventSortField, .timestamp),
    );

    // Unrecognized value: reject rather than guess. `expiry` is a real
    // EventSortField variant but is NOT exposed by Event_orderBy, so it must
    // not be reachable from client input.
    var bogus = [_]parser.Argument{
        .{ .name = "orderBy", .value = .{ .string = "expiry" } },
    };
    try testing.expectEqual(
        EventSortField.timestamp,
        parseEventOrderBy(&makeField(&bogus), EventSortField, .timestamp),
    );

    // Wrong type: an int where a string is expected must not be coerced.
    var wrong_type = [_]parser.Argument{
        .{ .name = "orderBy", .value = .{ .int = 1 } },
    };
    try testing.expectEqual(
        EventSortField.name,
        parseEventOrderBy(&makeField(&wrong_type), EventSortField, .name),
    );
}

test "parseOrderDirection round-trips both directions for events" {
    // Domain.events pairs orderBy with orderDirection; the pair is what makes
    // `{ first: n, orderDirection: asc }` return the OLDEST n rather than the
    // newest n rearranged, so cover the event enum explicitly.
    var asc = [_]parser.Argument{
        .{ .name = "orderDirection", .value = .{ .string = "asc" } },
    };
    try testing.expectEqual(
        EventOrderDir.asc,
        parseOrderDirection(&makeField(&asc), EventOrderDir, .desc),
    );

    var desc = [_]parser.Argument{
        .{ .name = "orderDirection", .value = .{ .string = "desc" } },
    };
    try testing.expectEqual(
        EventOrderDir.desc,
        parseOrderDirection(&makeField(&desc), EventOrderDir, .asc),
    );

    var none = [_]parser.Argument{};
    try testing.expectEqual(
        EventOrderDir.desc,
        parseOrderDirection(&makeField(&none), EventOrderDir, .desc),
    );
}

fn staleAt(safe: ?u64, synced_at: []const ?i64, stale_after_seconds: u32, now: i64) bool {
    return isStale(.{ .head = 100, .safe = safe, .synced_at = synced_at, .stale_after_seconds = stale_after_seconds, .now = now });
}

test "isStale: finality data present decides on its own" {
    // Head past safe: caught up. Head behind safe: stale, regardless of clock.
    try testing.expect(!staleAt(100, &.{ null, null }, 0, 0));
    try testing.expect(staleAt(101, &.{ null, null }, 0, 0));
    // A fresh clock never rescues a head that is behind safe.
    try testing.expect(staleAt(101, &.{ null, 1000 }, 900, 1000));
    // An old sync never overrides a head that is at safe.
    try testing.expect(!staleAt(100, &.{ null, 1 }, 900, 1_000_000));
}

test "isStale: without finality data, a frozen head reads stale" {
    // The regression this guards: no finality data used to mean `false` even
    // when the indexer had not advanced in days.
    const day = 86400;
    try testing.expect(staleAt(null, &.{ null, 1000 }, 900, 1000 + day));
    try testing.expect(!staleAt(null, &.{ null, 1000 }, 900, 1000 + 899));
    // Exactly at the threshold is not yet stale (strict >).
    try testing.expect(!staleAt(null, &.{ null, 1000 }, 900, 1000 + 900));
    try testing.expect(staleAt(null, &.{ null, 1000 }, 900, 1000 + 901));
}

test "isStale: a live protocol does not mask a dead one" {
    // Split binaries: v1 keeps committing while v2 stopped a day ago.
    try testing.expect(staleAt(null, &.{ 100_000, 100_000 - 86400 }, 900, 100_000));
    try testing.expect(staleAt(null, &.{ 100_000 - 86400, 100_000 }, 900, 100_000));
    // A protocol this deployment does not index (no row) is ignored.
    try testing.expect(!staleAt(null, &.{ null, 100_000 }, 900, 100_000));
}

test "isStale: never synced reads stale once the fallback is armed" {
    // An API pointed at a database whose indexer never started.
    try testing.expect(staleAt(null, &.{ null, null }, 900, 100_000));
    try testing.expect(staleAt(null, &.{ 0, 0 }, 900, 100_000));
    // Disabled fallback keeps the old answer.
    try testing.expect(!staleAt(null, &.{ null, null }, 0, 100_000));
}

test "isStale: disabled fallback ignores the clock" {
    try testing.expect(!staleAt(null, &.{ null, 1000 }, 0, 1000 + 86400));
}

test "isStale: a sync timestamp ahead of the clock reads as fresh, not negative" {
    try testing.expect(!staleAt(null, &.{ null, 5000 }, 900, 1000));
    // Hostile DB values cannot overflow the subtraction.
    try testing.expect(!staleAt(null, &.{ null, std.math.maxInt(i64) }, 900, std.math.minInt(i64)));
    try testing.expect(staleAt(null, &.{ null, 1 }, 900, std.math.maxInt(i64)));
}

test "coverageStale: reads both protocol rows and the head they imply" {
    const now: i64 = 1_700_000_000;
    const fresh = ProtocolSync{ .block = 50, .at = now };
    const dead = ProtocolSync{ .block = 40, .at = now - 86400 };
    try testing.expect(!coverageStale(null, fresh, null, 900, now));
    try testing.expect(coverageStale(dead, fresh, null, 900, now));
    try testing.expect(coverageStale(null, null, null, 900, now));
    try testing.expect(!coverageStale(null, null, null, 0, now));
    // Head is max(v1, v2): 50 is behind safe 60, and at safe 50 it is not.
    try testing.expect(coverageStale(dead, fresh, 60, 0, now));
    try testing.expect(!coverageStale(dead, fresh, 50, 900, now));
}

test "indexedHead: highest protocol wins, absent reads as 0" {
    try testing.expectEqual(@as(u64, 0), indexedHead(null, null));
    try testing.expectEqual(@as(u64, 7), indexedHead(.{ .block = 7, .at = 1 }, null));
    try testing.expectEqual(@as(u64, 9), indexedHead(.{ .block = 7, .at = 1 }, .{ .block = 9, .at = 1 }));
}
