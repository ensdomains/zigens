/// EAC (Enhanced Access Control) roleBitmap decoding.
///
/// ENSv2's `EnhancedAccessControl` packs roles into a 256-bit bitmap using a
/// nybble-per-role layout: each role occupies one 4-bit slot, so there are 64
/// slots total. Slots 0-31 (bits 0..127) are *regular* roles; slots 32-63
/// (bits 128..255) are the matching *admin* roles (regular role `<< 128`).
/// A role is considered "held" when any bit in its nybble is set — the contract
/// stores per-assignee counts (0-15) in each nybble, but for the purpose of
/// naming the permission we only care whether the nybble is non-zero.
///
/// The named meaning of each slot is contract-specific. A registry and a
/// resolver both emit `EACRolesChanged`, but slot 6 means `SET_RESOLVER` on a
/// registry and `SET_NAME` on a resolver. We therefore decode against the
/// table that matches the emitting contract (see `ContractKind`).
///
/// Constants mirror, verbatim, the ENSv2 contract role libraries:
///   - resolver: contracts-v2 `PermissionedResolverLib.sol`
///   - registry: contracts-v2 `RegistryRolesLib.sol`
///   - masks:    contracts-v2 `EACBaseRolesLib.sol`
const std = @import("std");
const models = @import("../types/models.zig");

/// Which contract emitted the `EACRolesChanged` event. Re-exported from
/// `models` so callers can use `eac_roles.ContractKind` interchangeably.
pub const ContractKind = models.EACContractKind;

/// `ALL_ROLES` mask from `EACBaseRolesLib` — bit 0 of every nybble set.
/// On live Sepolia, the 22 resolver-EAC rows all carry `roleBitmap = 0x11…11`,
/// which is exactly this value.
pub const ALL_ROLES: u256 = 0x1111111111111111111111111111111111111111111111111111111111111111;

/// `ADMIN_ROLES` mask from `EACBaseRolesLib` — only the upper 128 bits (the 32
/// admin nybbles) set.
pub const ADMIN_ROLES: u256 = 0x1111111111111111111111111111111100000000000000000000000000000000;

/// Number of admin role nybbles / the bit shift separating a regular role from
/// its admin counterpart.
const ADMIN_SHIFT: u9 = 128;

/// A single named role slot: its regular-role name and the nybble index it
/// occupies (0-31). The admin counterpart is derived by suffixing the name with
/// `_ADMIN` and shifting the slot by 32.
const RoleSlot = struct {
    name: []const u8,
    /// Regular-role nybble index, 0-31.
    nybble: u6,
    /// Roles the contract defines ONLY in their admin form (no regular role at
    /// this nybble), e.g. registry `ROLE_CAN_TRANSFER_ADMIN`. The bare name is
    /// never emitted for these — only `<name>_ADMIN` when the admin nybble is set.
    admin_only: bool = false,
};

/// Resolver role slots — from `PermissionedResolverLib.sol`.
/// Nybble index = bit offset / 4 (e.g. `1 << 24` → nybble 6).
const RESOLVER_ROLES = [_]RoleSlot{
    .{ .name = "SET_ADDR", .nybble = 0 }, // 1 << 0
    .{ .name = "SET_TEXT", .nybble = 1 }, // 1 << 4
    .{ .name = "SET_CONTENTHASH", .nybble = 2 }, // 1 << 8
    .{ .name = "SET_PUBKEY", .nybble = 3 }, // 1 << 12
    .{ .name = "SET_ABI", .nybble = 4 }, // 1 << 16
    .{ .name = "SET_INTERFACE", .nybble = 5 }, // 1 << 20
    .{ .name = "SET_NAME", .nybble = 6 }, // 1 << 24
    .{ .name = "SET_ALIAS", .nybble = 7 }, // 1 << 28
    .{ .name = "CLEAR", .nybble = 8 }, // 1 << 32
    .{ .name = "SET_DATA", .nybble = 9 }, // 1 << 36
    .{ .name = "UPGRADE", .nybble = 31 }, // 1 << 124
};

/// Registry role slots — from `RegistryRolesLib.sol`.
/// `CAN_TRANSFER` is defined only as `ROLE_CAN_TRANSFER_ADMIN = (1 << 28) << 128`
/// (admin nybble 7) — there is no regular nybble-7 role — so it is admin-only.
const REGISTRY_ROLES = [_]RoleSlot{
    .{ .name = "REGISTRAR", .nybble = 0 }, // 1 << 0
    .{ .name = "REGISTER_RESERVED", .nybble = 1 }, // 1 << 4
    .{ .name = "SET_PARENT", .nybble = 2 }, // 1 << 8
    .{ .name = "UNREGISTER", .nybble = 3 }, // 1 << 12
    .{ .name = "RENEW", .nybble = 4 }, // 1 << 16
    .{ .name = "SET_SUBREGISTRY", .nybble = 5 }, // 1 << 20
    .{ .name = "SET_RESOLVER", .nybble = 6 }, // 1 << 24
    .{ .name = "CAN_TRANSFER", .nybble = 7, .admin_only = true }, // only (1 << 28) << 128
    .{ .name = "UPGRADE", .nybble = 31 }, // 1 << 124
};

fn slotsFor(kind: ContractKind) []const RoleSlot {
    return switch (kind) {
        .resolver => &RESOLVER_ROLES,
        .registry => &REGISTRY_ROLES,
        .unknown => &.{},
    };
}

/// Returns true if the regular-role nybble at `nybble` (0-31) is non-zero.
fn hasRegularNybble(bitmap: u256, nybble: u6) bool {
    const shift: u9 = @as(u9, nybble) * 4;
    return ((bitmap >> @intCast(shift)) & 0xF) != 0;
}

/// Returns true if the admin nybble matching `nybble` (i.e. nybble+32) is
/// non-zero.
fn hasAdminNybble(bitmap: u256, nybble: u6) bool {
    const shift: u9 = ADMIN_SHIFT + @as(u9, nybble) * 4;
    return ((bitmap >> @intCast(shift)) & 0xF) != 0;
}

/// Parse a `0x`-prefixed (or bare) hex string into a u256 role bitmap.
/// Accepts the fixed-width 64-hex form the indexer stores, as well as short
/// forms like `0x01`. Returns `error.InvalidBitmap` on malformed input.
pub fn parseBitmap(hex: []const u8) !u256 {
    var s = hex;
    if (s.len >= 2 and (std.mem.eql(u8, s[0..2], "0x") or std.mem.eql(u8, s[0..2], "0X"))) {
        s = s[2..];
    }
    if (s.len == 0 or s.len > 64) return error.InvalidBitmap;
    return std.fmt.parseInt(u256, s, 16) catch error.InvalidBitmap;
}

/// Decode a role bitmap into an allocated list of named permission strings.
///
/// Naming convention:
///   - A set regular nybble emits the bare role name (e.g. `"SET_RESOLVER"`).
///   - A set admin nybble emits the role name suffixed with `_ADMIN`
///     (e.g. `"SET_RESOLVER_ADMIN"`).
///
/// For a known contract kind (`.resolver`/`.registry`) only nybbles defined in
/// that contract's role table are named; set-but-undefined nybbles are ignored
/// (the contract's `ALL_ROLES` validation mask `0x11…11` sets every nybble, but
/// only the defined ones carry meaning). New contract roles are surfaced by
/// extending the tables above, keeping names sourced from the contracts.
///
/// For `.unknown` contracts we have no table, so every set nybble is emitted as
/// a generic, lossless `"ROLE_<n>"` / `"ROLE_<n>_ADMIN"` identifier rather than
/// guessing a (possibly wrong) name.
///
/// Caller owns the returned slice and each contained string; free with
/// `freePermissions`.
pub fn decode(allocator: std.mem.Allocator, bitmap: u256, kind: ContractKind) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }

    if (kind == .unknown) {
        // No role table: emit generic identifiers for every set nybble.
        var nybble: u6 = 0;
        while (true) : (nybble += 1) {
            if (hasRegularNybble(bitmap, nybble)) {
                const name = try std.fmt.allocPrint(allocator, "ROLE_{d}", .{nybble});
                errdefer allocator.free(name);
                try list.append(allocator, name);
            }
            if (hasAdminNybble(bitmap, nybble)) {
                const name = try std.fmt.allocPrint(allocator, "ROLE_{d}_ADMIN", .{nybble});
                errdefer allocator.free(name);
                try list.append(allocator, name);
            }
            if (nybble == 31) break; // avoid u6 overflow on increment
        }
        return list.toOwnedSlice(allocator);
    }

    for (slotsFor(kind)) |slot| {
        if (!slot.admin_only and hasRegularNybble(bitmap, slot.nybble)) {
            const name = try allocator.dupe(u8, slot.name);
            errdefer allocator.free(name);
            try list.append(allocator, name);
        }
        if (hasAdminNybble(bitmap, slot.nybble)) {
            const name = try std.fmt.allocPrint(allocator, "{s}_ADMIN", .{slot.name});
            errdefer allocator.free(name);
            try list.append(allocator, name);
        }
    }

    return list.toOwnedSlice(allocator);
}

/// Convenience wrapper: parse the stored hex bitmap then decode. On a malformed
/// bitmap returns an empty list rather than erroring, so a single bad row never
/// fails the whole GraphQL response.
pub fn decodeHex(allocator: std.mem.Allocator, hex: []const u8, kind: ContractKind) ![]const []const u8 {
    const bitmap = parseBitmap(hex) catch return try allocator.alloc([]const u8, 0);
    return decode(allocator, bitmap, kind);
}

/// Free a permission list produced by `decode`/`decodeHex`.
pub fn freePermissions(allocator: std.mem.Allocator, perms: []const []const u8) void {
    for (perms) |p| allocator.free(p);
    allocator.free(perms);
}

// ============================================================================
// TESTS
// ============================================================================

const testing = std.testing;

fn expectPerms(expected: []const []const u8, actual: []const []const u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    // Order-independent comparison: every expected name must appear once.
    for (expected) |want| {
        var found = false;
        for (actual) |got| {
            if (std.mem.eql(u8, want, got)) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("missing expected permission: {s}\n", .{want});
            return error.MissingPermission;
        }
    }
}

test "parseBitmap accepts 0x-prefixed, bare, and short forms" {
    try testing.expectEqual(@as(u256, 1), try parseBitmap("0x01"));
    try testing.expectEqual(@as(u256, 1), try parseBitmap("1"));
    try testing.expectEqual(ALL_ROLES, try parseBitmap("0x1111111111111111111111111111111111111111111111111111111111111111"));
    try testing.expectError(error.InvalidBitmap, parseBitmap(""));
    try testing.expectError(error.InvalidBitmap, parseBitmap("0xZZ"));
}

test "decode resolver ALL_ROLES (live Sepolia 0x11..11) yields all resolver perms + admins" {
    const allocator = testing.allocator;
    const perms = try decode(allocator, ALL_ROLES, .resolver);
    defer freePermissions(allocator, perms);

    // 11 named resolver slots → 11 regular + 11 admin = 22 names.
    try testing.expectEqual(@as(usize, 22), perms.len);
    try expectPerms(&.{
        "SET_ADDR",         "SET_TEXT",            "SET_CONTENTHASH", "SET_PUBKEY",
        "SET_ABI",          "SET_INTERFACE",       "SET_NAME",        "SET_ALIAS",
        "CLEAR",            "SET_DATA",            "UPGRADE",         "SET_ADDR_ADMIN",
        "SET_NAME_ADMIN",   "UPGRADE_ADMIN",       "SET_DATA_ADMIN",  "CLEAR_ADMIN",
        "SET_ALIAS_ADMIN",  "SET_ABI_ADMIN",       "SET_TEXT_ADMIN",  "SET_CONTENTHASH_ADMIN",
        "SET_PUBKEY_ADMIN", "SET_INTERFACE_ADMIN",
    }, perms);
}

test "decode registry ALL_ROLES (live 0x11..11) — CAN_TRANSFER is admin-only" {
    const allocator = testing.allocator;
    const perms = try decode(allocator, ALL_ROLES, .registry);
    defer freePermissions(allocator, perms);

    // 8 regular-emitting slots (REGISTRAR..SET_RESOLVER, UPGRADE) → 8 regular
    // names; 9 admin nybbles (those 8 + CAN_TRANSFER) → 9 admin names = 17.
    try testing.expectEqual(@as(usize, 17), perms.len);
    // CAN_TRANSFER exists only as an admin role — the bare name must NOT appear.
    for (perms) |p| try testing.expect(!std.mem.eql(u8, p, "CAN_TRANSFER"));
    try expectPerms(&.{
        "REGISTRAR",       "REGISTER_RESERVED",       "SET_PARENT",         "UNREGISTER",
        "RENEW",           "SET_SUBREGISTRY",         "SET_RESOLVER",       "UPGRADE",
        "REGISTRAR_ADMIN", "REGISTER_RESERVED_ADMIN", "SET_PARENT_ADMIN",   "UNREGISTER_ADMIN",
        "RENEW_ADMIN",     "SET_SUBREGISTRY_ADMIN",   "SET_RESOLVER_ADMIN", "CAN_TRANSFER_ADMIN",
        "UPGRADE_ADMIN",
    }, perms);
}

test "decode registry CAN_TRANSFER: regular nybble 7 emits nothing, admin nybble emits _ADMIN only" {
    const allocator = testing.allocator;
    // Regular nybble 7 set, admin nybble 7 clear → no CAN_TRANSFER (admin-only).
    {
        const perms = try decode(allocator, @as(u256, 1) << (7 * 4), .registry);
        defer freePermissions(allocator, perms);
        try testing.expectEqual(@as(usize, 0), perms.len);
    }
    // Admin nybble 7 set → CAN_TRANSFER_ADMIN only.
    {
        const perms = try decode(allocator, @as(u256, 1) << (7 * 4 + 128), .registry);
        defer freePermissions(allocator, perms);
        try expectPerms(&.{"CAN_TRANSFER_ADMIN"}, perms);
    }
}

test "decode resolver single regular role SET_ADDR" {
    const allocator = testing.allocator;
    // ROLE_SET_ADDR = 1 << 0
    const perms = try decode(allocator, 1 << 0, .resolver);
    defer freePermissions(allocator, perms);
    try expectPerms(&.{"SET_ADDR"}, perms);
}

test "decode resolver SET_NAME lives at nybble 6 (1 << 24)" {
    const allocator = testing.allocator;
    const perms = try decode(allocator, 1 << 24, .resolver);
    defer freePermissions(allocator, perms);
    try expectPerms(&.{"SET_NAME"}, perms);
}

test "decode registry SET_RESOLVER lives at nybble 6 (1 << 24) — same bit, different name" {
    const allocator = testing.allocator;
    const perms = try decode(allocator, 1 << 24, .registry);
    defer freePermissions(allocator, perms);
    try expectPerms(&.{"SET_RESOLVER"}, perms);
}

test "decode registry admin role: ROLE_REGISTRAR_ADMIN = (1<<0) << 128" {
    const allocator = testing.allocator;
    const bitmap: u256 = @as(u256, 1) << 128; // nybble 0 in the admin half
    const perms = try decode(allocator, bitmap, .registry);
    defer freePermissions(allocator, perms);
    try expectPerms(&.{"REGISTRAR_ADMIN"}, perms);
}

test "decode registry regular + admin pair" {
    const allocator = testing.allocator;
    // ROLE_SET_RESOLVER | ROLE_SET_RESOLVER_ADMIN
    const bitmap: u256 = (@as(u256, 1) << 24) | (@as(u256, 1) << (24 + 128));
    const perms = try decode(allocator, bitmap, .registry);
    defer freePermissions(allocator, perms);
    try expectPerms(&.{ "SET_RESOLVER", "SET_RESOLVER_ADMIN" }, perms);
}

test "decode counts > 1 in a nybble still names the role once" {
    const allocator = testing.allocator;
    // Nybble 0 with count = 3 (binary 0011) — contract stores assignee counts.
    const perms = try decode(allocator, 0x3, .resolver);
    defer freePermissions(allocator, perms);
    try expectPerms(&.{"SET_ADDR"}, perms);
}

test "decode empty bitmap yields no permissions" {
    const allocator = testing.allocator;
    const perms = try decode(allocator, 0, .resolver);
    defer freePermissions(allocator, perms);
    try testing.expectEqual(@as(usize, 0), perms.len);
}

test "decode unknown contract falls back to generic ROLE_<n> identifiers" {
    const allocator = testing.allocator;
    const perms = try decode(allocator, 1 << 24, .unknown);
    defer freePermissions(allocator, perms);
    try expectPerms(&.{"ROLE_6"}, perms);
}

test "decode resolver ignores set-but-undefined nybbles (only named roles emitted)" {
    const allocator = testing.allocator;
    // SET_ADDR (nybble 0, known) + nybble 15 (undefined on resolver) → only SET_ADDR.
    const bitmap: u256 = (1 << 0) | (@as(u256, 1) << (15 * 4));
    const perms = try decode(allocator, bitmap, .resolver);
    defer freePermissions(allocator, perms);
    try expectPerms(&.{"SET_ADDR"}, perms);
}

test "decode unknown contract ALL_ROLES emits all 64 generic identifiers" {
    const allocator = testing.allocator;
    const perms = try decode(allocator, ALL_ROLES, .unknown);
    defer freePermissions(allocator, perms);
    // 32 regular + 32 admin nybbles set.
    try testing.expectEqual(@as(usize, 64), perms.len);
}

test "decodeHex on malformed bitmap returns empty list, not error" {
    const allocator = testing.allocator;
    const perms = try decodeHex(allocator, "0xnothex", .resolver);
    defer freePermissions(allocator, perms);
    try testing.expectEqual(@as(usize, 0), perms.len);
}

test "decodeHex round-trips the stored fixed-width ALL_ROLES form" {
    const allocator = testing.allocator;
    const perms = try decodeHex(allocator, "0x1111111111111111111111111111111111111111111111111111111111111111", .resolver);
    defer freePermissions(allocator, perms);
    try testing.expectEqual(@as(usize, 22), perms.len);
}
