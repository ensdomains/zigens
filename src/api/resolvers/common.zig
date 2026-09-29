/// Common imports for ENS GraphQL resolvers
const std = @import("std");
pub const db = @import("../../storage/database.zig");
pub const models = @import("../../types/models.zig");
pub const Hash = @import("../../types/hash.zig").Hash;
pub const Address = @import("../../types/address.zig").Address;
pub const namehash_fn = @import("../../types/hash.zig").namehash;
pub const json_utils = @import("../../utils/json.zig");

// Import generic GraphQL library
pub const parser = @import("../../lib/graphql/parser.zig");
pub const pagination = @import("../../lib/graphql/pagination.zig");

// Import ENS-specific modules.
// Note: `builders` is NOT re-exported here — that would create a cycle with
// builders/builders.zig. Files needing the builder layer (or `builders.NestedContext`)
// should import `../builders/builders.zig` directly.
pub const loaders = @import("../loaders.zig");

// Re-export shared helpers/constants from the neutral api/common.zig so resolver
// files can access them via the same `common.*` namespace.
const api_common = @import("../common.zig");
pub const parsePagination = api_common.parsePagination;
pub const parseOrderDirection = api_common.parseOrderDirection;
pub const parseEventOrderBy = api_common.parseEventOrderBy;
pub const getObjectArg = api_common.getObjectArg;
pub const matchStringArg = api_common.matchStringArg;
pub const matchIntArg = api_common.matchIntArg;
pub const matchBoolArg = api_common.matchBoolArg;
pub const matchAddressArg = api_common.matchAddressArg;
pub const parseStringListArg = api_common.parseStringListArg;
pub const parseAddressListArg = api_common.parseAddressListArg;
pub const NESTED_DEFAULT_FIRST = api_common.NESTED_DEFAULT_FIRST;

/// Normalize a client-supplied EAC resource to the fixed 66-char lowercase hex
/// the indexer stores (zero-trimmed `0x1`, padded and upper-case spellings all
/// map to the same key). Strict hex only — no `_` separators or signs. The value
/// itself is untouched: version bits stay exactly as spelled. Null when the
/// input is not hex, so callers can keep exact-match semantics for it.
pub fn normalizeResourceHex(allocator: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    const body = if (std.mem.startsWith(u8, raw, "0x") or std.mem.startsWith(u8, raw, "0X")) raw[2..] else raw;
    if (body.len == 0 or body.len > 64) return null;
    for (body) |ch| {
        if (!std.ascii.isHex(ch)) return null;
    }
    const v = std.fmt.parseInt(u256, body, 16) catch return null;
    return try std.fmt.allocPrint(allocator, "0x{x:0>64}", .{v});
}

test "normalizeResourceHex pads, lower-cases and rejects non-hex" {
    const a = std.testing.allocator;
    const padded = (try normalizeResourceHex(a, "0x1")).?;
    defer a.free(padded);
    try std.testing.expectEqualStrings("0x0000000000000000000000000000000000000000000000000000000000000001", padded);
    const upper = (try normalizeResourceHex(a, "0XAB00000001")).?;
    defer a.free(upper);
    try std.testing.expectEqualStrings("0x000000000000000000000000000000000000000000000000000000ab00000001", upper);
    try std.testing.expect((try normalizeResourceHex(a, "0x1_0")) == null);
    try std.testing.expect((try normalizeResourceHex(a, "+1")) == null);
    try std.testing.expect((try normalizeResourceHex(a, "not-hex!")) == null);
    try std.testing.expect((try normalizeResourceHex(a, "")) == null);
}
