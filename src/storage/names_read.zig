//! Name read / query operations: single-row + list getters, wrapped-domain and
//! subdomain queries, plus the row-parse helpers and SELECT constants they share.
//! Split out of names.zig; names.zig re-exports the public functions so `names.X` /
//! `db.X` callers are unchanged.

const std = @import("std");
const db_module = @import("database.zig");
const Database = db_module.Database;
const Query = db_module.Query;
const models = @import("../types/models.zig");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;
const names_common = @import("names_common.zig");
const parseU256Hex = names_common.parseU256Hex;
const formatU256HexBuf = names_common.formatU256HexBuf;

/// Standard SELECT columns for names table (32 columns)
/// Column order: name(0), label(1), label_hash(2), parent_name(3), parent_namehash(4),
///               protocol(5), registry(6), owner(7), registrant(8), resolver(9),
///               token_id(10), canonical_id(11), token_version(12), namehash(13), expiry(14),
///               registry_locked(15), migrated(16), created_block(17), created_at(18),
///               registered_at(19), updated_block(20), updated_at(21), is_wrapped(22), wrapper_fuses(23),
///               wrapper_expiry(24), is_v1_name(25), v1_label_hash(26),
///               is_reachable(27), unreachable_since(28), ttl(29), is_legacy(30),
///               resolved_address(31)
const SQL_SELECT_NAMES =
    \\SELECT name, label, label_hash, parent_name, parent_namehash, protocol, registry,
    \\       owner, registrant, resolver, token_id, canonical_id, token_version, namehash, expiry,
    \\       registry_locked, migrated, created_block, created_at, registered_at, updated_block, updated_at,
    \\       is_wrapped, wrapper_fuses, wrapper_expiry, is_v1_name, v1_label_hash,
    \\       is_reachable, unreachable_since, ttl, is_legacy, resolved_address, is_normalized
    \\FROM names
;

/// Shorter SELECT for queries that don't need wrapper fields (27 columns).
/// Still includes is_reachable/unreachable_since/ttl so callers can honor
/// reachability filtering and serialize the flag.
const SQL_SELECT_NAMES_SHORT =
    \\SELECT name, label, label_hash, parent_name, parent_namehash, protocol, registry,
    \\       owner, registrant, resolver, token_id, canonical_id, token_version, namehash, expiry,
    \\       registry_locked, migrated, created_block, created_at, registered_at, updated_block, updated_at,
    \\       is_reachable, unreachable_since, ttl, is_legacy, resolved_address, is_normalized, is_wrapped, wrapper_fuses, wrapper_expiry, is_v1_name, v1_label_hash
    \\FROM names
;

/// Format a u256 as hex string with 0x prefix
fn formatU256Hex(allocator: std.mem.Allocator, value: u256) ![]u8 {
    return try std.fmt.allocPrint(allocator, "0x{x:0>64}", .{value});
}

/// Parse a Name model from a Query result row
/// Expects columns in SQL_SELECT_NAMES order (27 columns with wrapper fields)
fn parseNameRow(q: *Query, allocator: std.mem.Allocator) !models.Name {
    const name_str = q.getTextSlice(0) orelse "";
    const label_str = q.getTextSlice(1) orelse "";
    const label_hash_str = q.getTextSlice(2) orelse "";
    const parent_name_str = q.getTextSlice(3) orelse "";
    const parent_hash_str = q.getTextSlice(4) orelse "";
    const protocol_str = q.getTextSlice(5) orelse models.Protocol.v2.toString();
    const registry_str = q.getTextSlice(6) orelse "";
    const owner_str = q.getTextSlice(7) orelse "";
    const registrant_str = q.getTextSlice(8);
    const resolver_str = q.getTextSlice(9) orelse "";
    const token_id_str = q.getTextSlice(10) orelse "0x0";
    const canonical_id_str = q.getTextSlice(11) orelse "0x0";
    const namehash_str = q.getTextSlice(13) orelse "";

    // Parse registrant - use owner as fallback for old records where registrant is null
    const registrant = if (registrant_str != null and registrant_str.?.len > 0)
        try Address.fromHex(registrant_str.?)
    else
        try Address.fromHex(owner_str);

    // Parse wrapper fields (optional)
    const wrapper_fuses = if (q.getTextSlice(23)) |fuses| try allocator.dupe(u8, fuses) else null;
    const wrapper_expiry = q.getOptionalInt64(24);
    const v1_label_hash = if (q.getTextSlice(26)) |hash| try allocator.dupe(u8, hash) else null;

    return models.Name{
        .name = try allocator.dupe(u8, name_str),
        .label = try allocator.dupe(u8, label_str),
        .label_hash = try Hash.fromHex(label_hash_str),
        .parent_name = try allocator.dupe(u8, parent_name_str),
        .parent_namehash = try Hash.fromHex(parent_hash_str),
        .protocol = try models.Protocol.fromString(protocol_str),
        .registry = try Address.fromHex(registry_str),
        .owner = try Address.fromHex(owner_str),
        .registrant = registrant,
        .resolver = try Address.fromHex(resolver_str),
        .token_id = try parseU256Hex(token_id_str),
        .canonical_id = try parseU256Hex(canonical_id_str),
        .token_version = @intCast(q.getInt64(12)),
        .namehash = try Hash.fromHex(namehash_str),
        .expiry = @bitCast(q.getInt64(14)),
        .registry_locked = q.getBool(15),
        .migrated = q.getBool(16),
        .created_block = @intCast(q.getInt64(17)),
        .created_at = q.getInt64(18),
        .registered_at = q.getOptionalInt64(19) orelse q.getInt64(18),
        .updated_block = @intCast(q.getInt64(20)),
        .updated_at = q.getInt64(21),
        .is_wrapped = q.getBool(22),
        .wrapper_fuses = wrapper_fuses,
        .wrapper_expiry = wrapper_expiry,
        .is_v1_name = q.getBool(25),
        .v1_label_hash = v1_label_hash,
        .is_reachable = q.getBool(27),
        .unreachable_since = q.getOptionalInt64(28),
        .ttl = if (q.getOptionalInt64(29)) |t| @intCast(t) else null,
        .is_legacy = q.getBool(30),
        .resolved_address = if (q.getTextSlice(31)) |s|
            Address.fromHex(s) catch null
        else
            null,
        .is_normalized = q.getBool(32),
    };
}

/// Parse a Name model from short query (27 columns, no wrapper fields)
fn parseNameRowShort(q: *Query, allocator: std.mem.Allocator) !models.Name {
    const name_str = q.getTextSlice(0) orelse "";
    const label_str = q.getTextSlice(1) orelse "";
    const label_hash_str = q.getTextSlice(2) orelse "";
    const parent_name_str = q.getTextSlice(3) orelse "";
    const parent_hash_str = q.getTextSlice(4) orelse "";
    const protocol_str = q.getTextSlice(5) orelse models.Protocol.v2.toString();
    const registry_str = q.getTextSlice(6) orelse "";
    const owner_str = q.getTextSlice(7) orelse "";
    const registrant_str = q.getTextSlice(8);
    const resolver_str = q.getTextSlice(9) orelse "";
    const token_id_str = q.getTextSlice(10) orelse "0x0";
    const canonical_id_str = q.getTextSlice(11) orelse "0x0";
    const namehash_str = q.getTextSlice(13) orelse "";

    const registrant = if (registrant_str != null and registrant_str.?.len > 0)
        try Address.fromHex(registrant_str.?)
    else
        try Address.fromHex(owner_str);

    const wrapper_fuses = if (q.getTextSlice(29)) |fuses| try allocator.dupe(u8, fuses) else null;
    const v1_label_hash = if (q.getTextSlice(32)) |hash| try allocator.dupe(u8, hash) else null;

    return models.Name{
        .name = try allocator.dupe(u8, name_str),
        .label = try allocator.dupe(u8, label_str),
        .label_hash = try Hash.fromHex(label_hash_str),
        .parent_name = try allocator.dupe(u8, parent_name_str),
        .parent_namehash = try Hash.fromHex(parent_hash_str),
        .protocol = try models.Protocol.fromString(protocol_str),
        .registry = try Address.fromHex(registry_str),
        .owner = try Address.fromHex(owner_str),
        .registrant = registrant,
        .resolver = try Address.fromHex(resolver_str),
        .token_id = try parseU256Hex(token_id_str),
        .canonical_id = try parseU256Hex(canonical_id_str),
        .token_version = @intCast(q.getInt64(12)),
        .namehash = try Hash.fromHex(namehash_str),
        .expiry = @bitCast(q.getInt64(14)),
        .registry_locked = q.getBool(15),
        .migrated = q.getBool(16),
        .created_block = @intCast(q.getInt64(17)),
        .created_at = q.getInt64(18),
        .registered_at = q.getOptionalInt64(19) orelse q.getInt64(18),
        .updated_block = @intCast(q.getInt64(20)),
        .updated_at = q.getInt64(21),
        .is_wrapped = q.getBool(28),
        .wrapper_fuses = wrapper_fuses,
        .wrapper_expiry = q.getOptionalInt64(30),
        .is_v1_name = q.getBool(31),
        .v1_label_hash = v1_label_hash,
        .is_reachable = q.getBool(22),
        .unreachable_since = q.getOptionalInt64(23),
        .ttl = if (q.getOptionalInt64(24)) |t| @intCast(t) else null,
        .is_legacy = q.getBool(25),
        .resolved_address = if (q.getTextSlice(26)) |s|
            Address.fromHex(s) catch null
        else
            null,
        .is_normalized = q.getBool(27),
    };
}

// ============================================================================
// NAME QUERY OPERATIONS
// ============================================================================

pub fn getNameByNamehash(db: *Database, namehash: Hash) !?models.Name {
    var q = try Query.initCached(db, SQL_SELECT_NAMES ++ " WHERE namehash = ?");
    defer q.deinit();

    try q.bindHash(namehash);

    if (try q.step()) {
        return try parseNameRow(&q, db.allocator);
    }
    return null;
}

/// Get just the `name` column for a namehash, allocator-owned, or null if missing.
/// Avoids the cost of fetching + duping a full 21-column Name row when callers only
/// need the human-readable name string (reverse-resolution hot path in the indexer).
pub fn getNameStringByNamehash(db: *Database, namehash: Hash, allocator: std.mem.Allocator) !?[]u8 {
    var q = try Query.initCached(db, "SELECT name FROM names WHERE namehash = ? LIMIT 1");
    defer q.deinit();

    try q.bindHash(namehash);

    if (try q.step()) {
        if (q.getTextSlice(0)) |name| {
            return try allocator.dupe(u8, name);
        }
    }
    return null;
}

/// Get a name by namehash within a specific protocol scope. Used for migration
/// path lookups where we need to find the V1 row by the same namehash a V2
/// LabelRegistered event just produced.
pub fn getNameByNamehashAndProtocol(db: *Database, namehash: Hash, protocol: models.Protocol) !?models.Name {
    var q = try Query.initCached(db, SQL_SELECT_NAMES ++ " WHERE namehash = ? AND protocol = ?");
    defer q.deinit();

    try q.bindHash(namehash);
    try q.bindTextStatic(protocol.toString());

    if (try q.step()) {
        return try parseNameRow(&q, db.allocator);
    }
    return null;
}

/// Get namehash by resolver address
pub fn getNamehashByResolver(db: *Database, resolver: Address) !?Hash {
    var q = try Query.initCached(db, "SELECT namehash FROM names WHERE resolver = ? LIMIT 1");
    defer q.deinit();

    try q.bindAddress(resolver);

    if (try q.step()) {
        const namehash_str = q.getTextSlice(0) orelse return null;
        return try Hash.fromHex(namehash_str);
    }
    return null;
}

/// Get name by token ID and registry address (avoids cross-registry tokenId collisions).
/// Strips to canonical_id (version-independent) for lookup, so this works with any
/// version of the token_id and is resilient to TokenRegenerated events.
pub fn getNameByTokenIdAndRegistry(db: *Database, token_id: u256, registry: Address) !?models.Name {
    var q = try Query.initCached(db, SQL_SELECT_NAMES ++ " WHERE canonical_id = ? AND registry = ? LIMIT 1");
    defer q.deinit();

    const token_id_utils = @import("../types/token_id.zig");
    const canonical_id = token_id_utils.getCanonicalId(token_id);
    var canonical_id_buf: [66]u8 = undefined;
    const canonical_id_hex = formatU256HexBuf(&canonical_id_buf, canonical_id);

    try q.bindText(canonical_id_hex);
    try q.bindAddressBuf(registry);

    if (try q.step()) {
        return try parseNameRow(&q, db.allocator);
    }
    return null;
}

/// Get all names owned by an address. Unreachable rows (orphaned by a
/// subregistry repoint or LabelUnregistered) are filtered out.
pub fn getNamesByOwner(db: *Database, owner: Address, limit: ?u32) ![]models.Name {
    const sql = if (limit) |l|
        try std.fmt.allocPrint(db.allocator, SQL_SELECT_NAMES_SHORT ++ " WHERE is_reachable = 1 AND is_normalized = 1 AND owner = ? AND namehash != '0x0000000000000000000000000000000000000000000000000000000000000000' LIMIT {d}", .{l})
    else
        try db.allocator.dupe(u8, SQL_SELECT_NAMES_SHORT ++ " WHERE is_reachable = 1 AND is_normalized = 1 AND owner = ? AND namehash != '0x0000000000000000000000000000000000000000000000000000000000000000'");
    defer db.allocator.free(sql);

    var q = try Query.initCached(db, sql);
    defer q.deinit();

    try q.bindAddress(owner);

    var names: std.ArrayList(models.Name) = .{};
    errdefer {
        for (names.items) |*name| {
            name.deinit(db.allocator);
        }
        names.deinit(db.allocator);
    }

    while (try q.step()) {
        try names.append(db.allocator, try parseNameRowShort(&q, db.allocator));
    }

    return names.toOwnedSlice(db.allocator);
}

/// Get names by resolver address. Unreachable rows are filtered out.
pub fn getNamesByResolver(db: *Database, resolver: Address, limit: u32) ![]models.Name {
    var q = try Query.init(db, SQL_SELECT_NAMES_SHORT ++ " WHERE is_reachable = 1 AND is_normalized = 1 AND resolver = ? AND namehash != '0x0000000000000000000000000000000000000000000000000000000000000000' ORDER BY created_at DESC LIMIT ?");
    defer q.deinit();

    try q.bindAddress(resolver);
    try q.bindInt(@intCast(limit));

    var names: std.ArrayList(models.Name) = .{};
    errdefer {
        for (names.items) |*name| {
            name.deinit(db.allocator);
        }
        names.deinit(db.allocator);
    }

    while (try q.step()) {
        try names.append(db.allocator, try parseNameRowShort(&q, db.allocator));
    }

    return names.toOwnedSlice(db.allocator);
}

/// Get wrapped V1 names (paginated). Optionally filter by owner / exact name /
/// expiry bounds — backs the top-level `wrappedDomains` GraphQL query.
/// Unreachable rows are filtered out to match the rest of the API contract.
pub const WrappedDomainFilters = struct {
    owner: ?Address = null,
    name: ?[]const u8 = null,
    expiry_gt: ?i64 = null,
    expiry_lt: ?i64 = null,
};

pub fn getWrappedDomains(
    db: *Database,
    filters: WrappedDomainFilters,
    skip: u32,
    limit: u32,
) ![]models.Name {
    var sql_buf: std.ArrayList(u8) = .{};
    defer sql_buf.deinit(db.allocator);
    try sql_buf.appendSlice(db.allocator, SQL_SELECT_NAMES);
    try sql_buf.appendSlice(db.allocator, " WHERE is_reachable = 1 AND is_normalized = 1 AND is_wrapped = 1");
    if (filters.owner != null) try sql_buf.appendSlice(db.allocator, " AND owner = ?");
    if (filters.name != null) try sql_buf.appendSlice(db.allocator, " AND name = ?");
    if (filters.expiry_gt != null) try sql_buf.appendSlice(db.allocator, " AND wrapper_expiry > ?");
    if (filters.expiry_lt != null) try sql_buf.appendSlice(db.allocator, " AND wrapper_expiry < ?");
    try sql_buf.appendSlice(db.allocator, " ORDER BY created_at DESC LIMIT ? OFFSET ?");

    var q = try Query.init(db, sql_buf.items);
    defer q.deinit();

    if (filters.owner) |o| try q.bindAddress(o);
    if (filters.name) |n| try q.bindText(n);
    if (filters.expiry_gt) |v| try q.bindInt64(v);
    if (filters.expiry_lt) |v| try q.bindInt64(v);
    try q.bindInt(@intCast(limit));
    try q.bindInt(@intCast(skip));

    var names: std.ArrayList(models.Name) = .{};
    errdefer {
        for (names.items) |*n| n.deinit(db.allocator);
        names.deinit(db.allocator);
    }
    while (try q.step()) {
        try names.append(db.allocator, try parseNameRow(&q, db.allocator));
    }
    return names.toOwnedSlice(db.allocator);
}

/// Get the canonical Domain row for a resolver (first by namehash ASC).
/// Used by the `Resolver.domain` back-reference (subgraph parity). Returns
/// null when no name currently points at this resolver. Unreachable rows
/// are filtered out to match the rest of the API contract.
pub fn getDomainByResolver(db: *Database, resolver: Address) !?models.Name {
    var q = try Query.initCached(
        db,
        SQL_SELECT_NAMES ++ " WHERE is_reachable = 1 AND is_normalized = 1 AND resolver = ? AND namehash != '0x0000000000000000000000000000000000000000000000000000000000000000' ORDER BY namehash ASC LIMIT 1",
    );
    defer q.deinit();

    try q.bindAddress(resolver);

    if (try q.step()) {
        return try parseNameRow(&q, db.allocator);
    }
    return null;
}

// ============================================================================
// SUBDOMAIN OPERATIONS
// ============================================================================

/// Count direct subdomains of a name. Unreachable subdomains (orphaned by
/// a subregistry repoint) are excluded to match `getSubdomains` semantics.
/// Subgraph parity: a name is considered fully burned (eligible for GC) when
/// both `owner` and `resolver` are the zero address. Subgraph deletes such
/// rows recursively when their subdomainCount is also 0; we approximate at
/// query time by filtering them out of subdomain queries. The full recursive
/// `subdomainCount == 0` check is omitted because it would require a sub-
/// query per row — the practical effect of filtering on owner+resolver alone
/// is close enough (a name with no owner/resolver but live children is rare
/// and clients can still reach it via direct namehash lookup).
const ZERO_ADDR_HEX: []const u8 = "0x0000000000000000000000000000000000000000";
const SUBDOMAIN_GC_FILTER: []const u8 = " AND NOT (owner = '" ++ ZERO_ADDR_HEX ++ "' AND resolver = '" ++ ZERO_ADDR_HEX ++ "')";

pub fn countDirectSubdomains(db: *Database, parent_name: []const u8) !u32 {
    var q = try Query.init(db, "SELECT COUNT(*) FROM names WHERE is_reachable = 1 AND is_normalized = 1 AND parent_name = ?" ++ SUBDOMAIN_GC_FILTER);
    defer q.deinit();

    try q.bindText(parent_name);

    if (try q.step()) {
        return @intCast(q.getInt64(0));
    }
    return 0;
}

/// Check if a name has any direct subdomains (reachable + non-burned).
pub fn hasDirectSubdomains(db: *Database, parent_name: []const u8) !bool {
    var q = try Query.init(db, "SELECT 1 FROM names WHERE is_reachable = 1 AND is_normalized = 1 AND parent_name = ?" ++ SUBDOMAIN_GC_FILTER ++ " LIMIT 1");
    defer q.deinit();

    try q.bindText(parent_name);
    return try q.step();
}

/// Get direct subdomains of a name with pagination. Unreachable rows
/// (orphans of a subregistry repoint) AND fully-burned rows (owner=0 AND
/// resolver=0, mirroring subgraph's GC deletion criteria) are filtered out
/// — callers that need them must query `getFilteredNames` with
/// `include_unreachable` (which still applies the GC filter; resurrection
/// requires direct namehash lookup).
pub fn getSubdomains(db: *Database, parent_name_arg: []const u8, skip: u32, limit: u32) ![]models.Name {
    var q = try Query.init(db, SQL_SELECT_NAMES_SHORT ++ " WHERE is_reachable = 1 AND is_normalized = 1 AND parent_name = ?" ++ SUBDOMAIN_GC_FILTER ++ " ORDER BY name LIMIT ? OFFSET ?");
    defer q.deinit();

    try q.bindText(parent_name_arg);
    try q.bindInt(@intCast(limit));
    try q.bindInt(@intCast(skip));

    var names: std.ArrayList(models.Name) = .{};
    errdefer {
        for (names.items) |*name| {
            name.deinit(db.allocator);
        }
        names.deinit(db.allocator);
    }

    while (try q.step()) {
        try names.append(db.allocator, try parseNameRowShort(&q, db.allocator));
    }

    return names.toOwnedSlice(db.allocator);
}
