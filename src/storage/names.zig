/// Names storage module - refactored to use Query abstraction
/// This module handles all name-related database operations
const std = @import("std");
const testing = std.testing;
const db_module = @import("database.zig");
const Database = db_module.Database;
const c = db_module.c;
const Query = db_module.Query;
const models = @import("../types/models.zig");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;

// ============================================================================
// CONSTANTS
// ============================================================================

/// Standard SELECT columns for names table (27 columns)
/// Column order: name(0), label(1), label_hash(2), parent_name(3), parent_namehash(4),
///               chain(5), registry(6), owner(7), registrant(8), resolver(9),
///               token_id(10), canonical_id(11), token_version(12), namehash(13), expiry(14),
///               registry_locked(15), migrated(16), ejected(17), created_block(18), created_at(19),
///               updated_block(20), updated_at(21), is_wrapped(22), wrapper_fuses(23),
///               wrapper_expiry(24), is_v1_name(25), v1_label_hash(26)
const SQL_SELECT_NAMES =
    \\SELECT name, label, label_hash, parent_name, parent_namehash, chain, registry,
    \\       owner, registrant, resolver, token_id, canonical_id, token_version, namehash, expiry,
    \\       registry_locked, migrated, ejected, created_block, created_at, updated_block, updated_at,
    \\       is_wrapped, wrapper_fuses, wrapper_expiry, is_v1_name, v1_label_hash
    \\FROM names
;

/// Shorter SELECT for queries that don't need wrapper fields
const SQL_SELECT_NAMES_SHORT =
    \\SELECT name, label, label_hash, parent_name, parent_namehash, chain, registry,
    \\       owner, registrant, resolver, token_id, canonical_id, token_version, namehash, expiry,
    \\       registry_locked, migrated, ejected, created_block, created_at, updated_block, updated_at
    \\FROM names
;

// ============================================================================
// HELPERS
// ============================================================================

/// Parse a u256 from hex string (handles 0x prefix)
fn parseU256Hex(hex_str: []const u8) !u256 {
    const clean = if (std.mem.startsWith(u8, hex_str, "0x")) hex_str[2..] else hex_str;
    return try std.fmt.parseInt(u256, clean, 16);
}

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
    const chain_str = q.getTextSlice(5) orelse "l2";
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
        .chain = try models.Chain.fromString(chain_str),
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
        .ejected = q.getBool(17),
        .created_block = @intCast(q.getInt64(18)),
        .created_at = q.getInt64(19),
        .updated_block = @intCast(q.getInt64(20)),
        .updated_at = q.getInt64(21),
        .is_wrapped = q.getBool(22),
        .wrapper_fuses = wrapper_fuses,
        .wrapper_expiry = wrapper_expiry,
        .is_v1_name = q.getBool(25),
        .v1_label_hash = v1_label_hash,
    };
}

/// Parse a Name model from short query (22 columns, no wrapper fields)
fn parseNameRowShort(q: *Query, allocator: std.mem.Allocator) !models.Name {
    const name_str = q.getTextSlice(0) orelse "";
    const label_str = q.getTextSlice(1) orelse "";
    const label_hash_str = q.getTextSlice(2) orelse "";
    const parent_name_str = q.getTextSlice(3) orelse "";
    const parent_hash_str = q.getTextSlice(4) orelse "";
    const chain_str = q.getTextSlice(5) orelse "l2";
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

    return models.Name{
        .name = try allocator.dupe(u8, name_str),
        .label = try allocator.dupe(u8, label_str),
        .label_hash = try Hash.fromHex(label_hash_str),
        .parent_name = try allocator.dupe(u8, parent_name_str),
        .parent_namehash = try Hash.fromHex(parent_hash_str),
        .chain = try models.Chain.fromString(chain_str),
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
        .ejected = q.getBool(17),
        .created_block = @intCast(q.getInt64(18)),
        .created_at = q.getInt64(19),
        .updated_block = @intCast(q.getInt64(20)),
        .updated_at = q.getInt64(21),
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    };
}

// ============================================================================
// REGISTRY OPERATIONS
// ============================================================================

pub fn insertRegistry(db: *Database, registry: models.Registry) !void {
    var q = try Query.init(db,
        \\INSERT OR REPLACE INTO registries
        \\(address, chain, name, namehash, parent_registry, created_block, created_at)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
    );
    defer q.deinit();

    try q.bindAddress(registry.address);
    try q.bindTextStatic(registry.chain.toString());
    try q.bindText(registry.name);
    try q.bindHash(registry.namehash);
    try q.bindAddress(registry.parent_registry);
    try q.bindInt64(@intCast(registry.created_block));
    try q.bindInt64(registry.created_at);
    try q.exec();
}

/// Update a registry that was created with a canonicalId placeholder name to use the actual name
/// Also updates any names that used this placeholder as their parent_name
pub fn updateRegistryPlaceholderName(db: *Database, placeholder_name: []const u8, actual_name: []const u8, namehash: Hash) !u32 {
    // First update the registry
    var reg_q = try Query.init(db, "UPDATE registries SET name = ?, namehash = ? WHERE name = ?");
    defer reg_q.deinit();

    try reg_q.bindText(actual_name);
    try reg_q.bindHash(namehash);
    try reg_q.bindText(placeholder_name);
    try reg_q.exec();

    const registry_changes = reg_q.changes();

    // Now update any names that used this placeholder as parent_name
    var names_q = try Query.init(db,
        \\UPDATE names
        \\SET parent_name = ?,
        \\    parent_namehash = ?,
        \\    name = label || '.' || ?
        \\WHERE parent_name = ?
    );
    defer names_q.deinit();

    try names_q.bindText(actual_name);
    try names_q.bindHash(namehash);
    try names_q.bindText(actual_name);
    try names_q.bindText(placeholder_name);
    try names_q.exec();

    const names_changes = names_q.changes();

    if (registry_changes > 0 or names_changes > 0) {
        std.log.info("Updated placeholder '{s}' -> '{s}': {d} registries, {d} names", .{
            placeholder_name, actual_name, registry_changes, names_changes,
        });
    }

    return registry_changes + names_changes;
}

pub fn getRegistriesByOwner(db: *Database, chain: models.Chain, owner: Address) ![]models.Registry {
    // Join registries with names on namehash to find registries where the NAME is owned by the specified owner
    // This returns registries for names that the owner controls (not registries that the owner's names use as subregistries)
    var q = try Query.init(db,
        \\SELECT r.address, r.chain, r.name, r.namehash, r.parent_registry, r.created_block, r.created_at
        \\FROM registries r
        \\JOIN names n ON r.namehash = n.namehash AND r.chain = n.chain
        \\WHERE r.chain = ? AND n.owner = ?
    );
    defer q.deinit();

    try q.bindTextStatic(chain.toString());
    try q.bindAddress(owner);

    var registries: std.ArrayList(models.Registry) = .{};
    errdefer {
        for (registries.items) |*reg| {
            db.allocator.free(reg.name);
        }
        registries.deinit(db.allocator);
    }

    while (try q.step()) {
        const address_str = q.getTextSlice(0) orelse continue;
        const chain_str = q.getTextSlice(1) orelse continue;
        const name_str = q.getTextSlice(2) orelse "";
        const namehash_str = q.getTextSlice(3) orelse continue;
        const parent_str = q.getTextSlice(4) orelse continue;

        try registries.append(db.allocator, .{
            .address = try Address.fromHex(address_str),
            .chain = try models.Chain.fromString(chain_str),
            .name = try db.allocator.dupe(u8, name_str),
            .namehash = try Hash.fromHex(namehash_str),
            .parent_registry = try Address.fromHex(parent_str),
            .created_block = @intCast(q.getInt64(5)),
            .created_at = q.getInt64(6),
        });
    }

    return registries.toOwnedSlice(db.allocator);
}

// ============================================================================
// NAME INSERT/UPDATE OPERATIONS
// ============================================================================

pub fn insertName(db: *Database, name: models.Name) !void {
    var q = try Query.init(db,
        \\INSERT OR REPLACE INTO names
        \\(namehash, name, label, label_hash, parent_name, parent_namehash, chain,
        \\ registry, owner, registrant, resolver, token_id, canonical_id, token_version, expiry,
        \\ registry_locked, migrated, ejected, created_block, created_at, updated_block, updated_at,
        \\ is_wrapped, wrapper_fuses, wrapper_expiry, is_v1_name, v1_label_hash)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    );
    defer q.deinit();

    // Format token IDs as hex strings
    const token_id_hex = try formatU256Hex(db.allocator, name.token_id);
    defer db.allocator.free(token_id_hex);
    const canonical_id_hex = try formatU256Hex(db.allocator, name.canonical_id);
    defer db.allocator.free(canonical_id_hex);

    try q.bindHash(name.namehash);
    try q.bindOptionalText(name.name);
    try q.bindOptionalText(name.label);
    try q.bindHash(name.label_hash);
    try q.bindOptionalText(name.parent_name);
    try q.bindHash(name.parent_namehash);
    try q.bindTextStatic(name.chain.toString());
    try q.bindAddress(name.registry);
    try q.bindAddress(name.owner);
    try q.bindAddress(name.registrant);
    try q.bindAddress(name.resolver);
    try q.bindText(token_id_hex);
    try q.bindText(canonical_id_hex);
    try q.bindInt64(@intCast(name.token_version));
    try q.bindInt64(@bitCast(name.expiry));
    try q.bindInt(if (name.registry_locked) 1 else 0);
    try q.bindInt(if (name.migrated) 1 else 0);
    try q.bindInt(if (name.ejected) 1 else 0);
    try q.bindInt64(@intCast(name.created_block));
    try q.bindInt64(name.created_at);
    try q.bindInt64(@intCast(name.updated_block));
    try q.bindInt64(name.updated_at);
    try q.bindInt(if (name.is_wrapped) 1 else 0);
    try q.bindOptionalText(name.wrapper_fuses);
    try q.bindOptionalInt64(name.wrapper_expiry);
    try q.bindInt(if (name.is_v1_name) 1 else 0);
    try q.bindOptionalText(name.v1_label_hash);
    try q.exec();
}

/// Update name expiry (for renewals)
pub fn updateNameExpiry(db: *Database, namehash: Hash, expiry: i64) !void {
    var q = try Query.init(db, "UPDATE names SET expiry = ?, updated_at = ? WHERE namehash = ?");
    defer q.deinit();

    try q.bindInt64(expiry);
    try q.bindInt64(std.time.timestamp());
    try q.bindHash(namehash);
    try q.exec();
}

/// Update name owner (for transfers)
pub fn updateNameOwner(db: *Database, namehash: Hash, new_owner: Address) !void {
    var q = try Query.init(db, "UPDATE names SET owner = ?, updated_at = ? WHERE namehash = ?");
    defer q.deinit();

    try q.bindAddress(new_owner);
    try q.bindInt64(std.time.timestamp());
    try q.bindHash(namehash);
    try q.exec();
}

/// Update name subregistry
pub fn updateNameSubregistry(db: *Database, namehash: Hash, subregistry: Address) !void {
    var q = try Query.init(db, "UPDATE names SET registry = ?, updated_at = ? WHERE namehash = ?");
    defer q.deinit();

    try q.bindAddress(subregistry);
    try q.bindInt64(std.time.timestamp());
    try q.bindHash(namehash);
    try q.exec();
}

/// Update name resolver
pub fn updateNameResolver(db: *Database, namehash: Hash, resolver: Address) !void {
    var q = try Query.init(db, "UPDATE names SET resolver = ?, updated_at = ? WHERE namehash = ?");
    defer q.deinit();

    try q.bindAddress(resolver);
    try q.bindInt64(std.time.timestamp());
    try q.bindHash(namehash);
    try q.exec();
}

/// Update name expiry by token ID (for V2 renewals)
pub fn updateNameExpiryByTokenId(db: *Database, token_id: i64, expiry: i64) !void {
    var q = try Query.init(db, "UPDATE names SET expiry = ?, updated_at = ? WHERE token_id = ?");
    defer q.deinit();

    const token_id_hex = try formatU256Hex(db.allocator, @as(u256, @intCast(token_id)));
    defer db.allocator.free(token_id_hex);

    try q.bindInt64(expiry);
    try q.bindInt64(std.time.timestamp());
    try q.bindText(token_id_hex);
    try q.exec();
}

/// Delete a name by token ID (for burned names)
pub fn deleteNameByTokenId(db: *Database, token_id: i64) !void {
    var q = try Query.init(db, "DELETE FROM names WHERE token_id = ?");
    defer q.deinit();

    const token_id_hex = try formatU256Hex(db.allocator, @as(u256, @intCast(token_id)));
    defer db.allocator.free(token_id_hex);

    try q.bindText(token_id_hex);
    try q.exec();
}

/// Update token_id for a name (for TokenRegenerated events)
pub fn updateNameTokenId(db: *Database, old_token_id: u256, new_token_id: u256) !void {
    const token_id_utils = @import("../types/token_id.zig");

    const canonical_id = token_id_utils.getCanonicalId(new_token_id);
    const token_version = token_id_utils.getTokenVersion(new_token_id);

    var q = try Query.init(db, "UPDATE names SET token_id = ?, canonical_id = ?, token_version = ?, updated_at = ? WHERE token_id = ?");
    defer q.deinit();

    const new_token_id_hex = try formatU256Hex(db.allocator, new_token_id);
    defer db.allocator.free(new_token_id_hex);
    const old_token_id_hex = try formatU256Hex(db.allocator, old_token_id);
    defer db.allocator.free(old_token_id_hex);
    const canonical_id_hex = try formatU256Hex(db.allocator, canonical_id);
    defer db.allocator.free(canonical_id_hex);

    try q.bindText(new_token_id_hex);
    try q.bindText(canonical_id_hex);
    try q.bindInt64(@intCast(token_version));
    try q.bindInt64(std.time.timestamp());
    try q.bindText(old_token_id_hex);
    try q.exec();
}

/// Update wrapper state for a name
pub fn updateNameWrapperState(db: *Database, namehash: Hash, fuses: u32, expiry: i64) !void {
    var q = try Query.init(db,
        \\UPDATE names SET is_wrapped = 1, wrapper_fuses = ?, wrapper_expiry = ?,
        \\updated_at = ? WHERE namehash = ?
    );
    defer q.deinit();

    const fuses_str = try std.fmt.allocPrint(db.allocator, "{d}", .{fuses});
    defer db.allocator.free(fuses_str);

    try q.bindText(fuses_str);
    try q.bindInt64(expiry);
    try q.bindInt64(std.time.timestamp());
    try q.bindHash(namehash);
    try q.exec();
}

/// Clear wrapper state for a name (unwrap)
pub fn updateNameUnwrapperState(db: *Database, namehash: Hash) !void {
    var q = try Query.init(db,
        \\UPDATE names SET is_wrapped = 0, wrapper_fuses = NULL, wrapper_expiry = NULL,
        \\updated_at = ? WHERE namehash = ?
    );
    defer q.deinit();

    try q.bindInt64(std.time.timestamp());
    try q.bindHash(namehash);
    try q.exec();
}

/// Update wrapper fuses only
pub fn updateNameWrapperFuses(db: *Database, namehash: Hash, fuses: u32) !void {
    var q = try Query.init(db,
        \\UPDATE names SET wrapper_fuses = ?, updated_at = ? WHERE namehash = ?
    );
    defer q.deinit();

    const fuses_str = try std.fmt.allocPrint(db.allocator, "{d}", .{fuses});
    defer db.allocator.free(fuses_str);

    try q.bindText(fuses_str);
    try q.bindInt64(std.time.timestamp());
    try q.bindHash(namehash);
    try q.exec();
}

/// Update wrapper expiry only
pub fn updateNameWrapperExpiry(db: *Database, namehash: Hash, expiry: i64) !void {
    var q = try Query.init(db,
        \\UPDATE names SET wrapper_expiry = ?, updated_at = ? WHERE namehash = ?
    );
    defer q.deinit();

    try q.bindInt64(expiry);
    try q.bindInt64(std.time.timestamp());
    try q.bindHash(namehash);
    try q.exec();
}

/// Update creation date if the new block is earlier (for backfill scenarios)
pub fn updateNameCreationDateIfEarlier(db: *Database, namehash: Hash, block_number: u64, created_at: i64) !void {
    var q = try Query.init(db,
        \\UPDATE names SET created_block = ?, created_at = ?
        \\WHERE namehash = ? AND created_block > ?
    );
    defer q.deinit();

    try q.bindInt64(@intCast(block_number));
    try q.bindInt64(created_at);
    try q.bindHash(namehash);
    try q.bindInt64(@intCast(block_number));
    try q.exec();
}

// ============================================================================
// NAME QUERY OPERATIONS
// ============================================================================

pub fn getNameByNamehash(db: *Database, namehash: Hash) !?models.Name {
    var q = try Query.init(db, SQL_SELECT_NAMES ++ " WHERE namehash = ?");
    defer q.deinit();

    try q.bindHash(namehash);

    if (try q.step()) {
        return try parseNameRow(&q, db.allocator);
    }
    return null;
}

/// Get namehash by resolver address
pub fn getNamehashByResolver(db: *Database, resolver: Address) !?Hash {
    var q = try Query.init(db, "SELECT namehash FROM names WHERE resolver = ? LIMIT 1");
    defer q.deinit();

    try q.bindAddress(resolver);

    if (try q.step()) {
        const namehash_str = q.getTextSlice(0) orelse return null;
        return try Hash.fromHex(namehash_str);
    }
    return null;
}

/// Get name by token ID
pub fn getNameByTokenId(db: *Database, token_id: u256) !?models.Name {
    var q = try Query.init(db, SQL_SELECT_NAMES ++ " WHERE token_id = ? LIMIT 1");
    defer q.deinit();

    const token_id_hex = try formatU256Hex(db.allocator, token_id);
    defer db.allocator.free(token_id_hex);

    try q.bindText(token_id_hex);

    if (try q.step()) {
        return try parseNameRow(&q, db.allocator);
    }
    return null;
}

/// Get name by canonical ID
pub fn getNameByCanonicalId(db: *Database, canonical_id: u256) !?models.Name {
    var q = try Query.init(db, SQL_SELECT_NAMES ++ " WHERE canonical_id = ? LIMIT 1");
    defer q.deinit();

    const canonical_id_hex = try formatU256Hex(db.allocator, canonical_id);
    defer db.allocator.free(canonical_id_hex);

    try q.bindText(canonical_id_hex);

    if (try q.step()) {
        return try parseNameRow(&q, db.allocator);
    }
    return null;
}

/// Get all names owned by an address
pub fn getNamesByOwner(db: *Database, owner: Address, limit: ?u32) ![]models.Name {
    const sql = if (limit) |l|
        try std.fmt.allocPrint(db.allocator, SQL_SELECT_NAMES_SHORT ++ " WHERE owner = ? LIMIT {d}", .{l})
    else
        try db.allocator.dupe(u8, SQL_SELECT_NAMES_SHORT ++ " WHERE owner = ?");
    defer db.allocator.free(sql);

    var q = try Query.init(db, sql);
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

/// Get names by registrant address
pub fn getNamesByRegistrant(db: *Database, registrant: Address, skip: u32, limit: u32) ![]models.Name {
    var q = try Query.init(db, SQL_SELECT_NAMES_SHORT ++ " WHERE registrant = ? ORDER BY created_at DESC LIMIT ? OFFSET ?");
    defer q.deinit();

    try q.bindAddress(registrant);
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

/// Order direction for queries
pub const OrderDir = enum {
    asc,
    desc,
};

pub fn getAllNames(db: *Database, owner: ?Address, skip: u32, limit: u32) ![]models.Name {
    return getAllNamesWithOrder(db, owner, skip, limit, .desc);
}

/// Get all names with configurable order direction
pub fn getAllNamesWithOrder(db: *Database, owner: ?Address, skip: u32, limit: u32, order_dir: OrderDir) ![]models.Name {
    const order_str = if (order_dir == .desc) "DESC" else "ASC";
    const sql = if (owner != null)
        try std.fmt.allocPrint(db.allocator,
            \\SELECT name, namehash, label, label_hash, parent_name, owner, resolver, registry, chain,
            \\       token_id, canonical_id, token_version, expiry, registry_locked, migrated, ejected,
            \\       created_at, created_block, updated_at, updated_block
            \\FROM names WHERE owner = ? ORDER BY created_at {s} LIMIT ? OFFSET ?
        , .{order_str})
    else
        try std.fmt.allocPrint(db.allocator,
            \\SELECT name, namehash, label, label_hash, parent_name, owner, resolver, registry, chain,
            \\       token_id, canonical_id, token_version, expiry, registry_locked, migrated, ejected,
            \\       created_at, created_block, updated_at, updated_block
            \\FROM names ORDER BY created_at {s} LIMIT ? OFFSET ?
        , .{order_str});
    defer db.allocator.free(sql);

    var q = try Query.init(db, sql);
    defer q.deinit();

    if (owner) |o| {
        try q.bindAddress(o);
    }
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
        // Column order: name(0), namehash(1), label(2), label_hash(3), parent_name(4),
        //               owner(5), resolver(6), registry(7), chain(8), token_id(9),
        //               canonical_id(10), token_version(11), expiry(12), registry_locked(13),
        //               migrated(14), ejected(15), created_at(16), created_block(17),
        //               updated_at(18), updated_block(19)
        const name_str = q.getTextSlice(0) orelse "";
        const namehash_str = q.getTextSlice(1) orelse "";
        const label_str = q.getTextSlice(2) orelse "";
        const label_hash_str = q.getTextSlice(3) orelse "";
        const parent_name_str = q.getTextSlice(4) orelse "";
        const owner_str = q.getTextSlice(5) orelse "";
        const resolver_str = q.getTextSlice(6) orelse "";
        const registry_str = q.getTextSlice(7) orelse "";
        const chain_str = q.getTextSlice(8) orelse "l2";
        const token_id_str = q.getTextSlice(9) orelse "0x0";
        const canonical_id_str = q.getTextSlice(10) orelse "0x0";

        // Derive parent_namehash from parent_name
        const parent_namehash = try @import("../types/hash.zig").namehash(db.allocator, parent_name_str);

        try names.append(db.allocator, .{
            .name = try db.allocator.dupe(u8, name_str),
            .namehash = try Hash.fromHex(namehash_str),
            .label = try db.allocator.dupe(u8, label_str),
            .label_hash = try Hash.fromHex(label_hash_str),
            .parent_name = try db.allocator.dupe(u8, parent_name_str),
            .parent_namehash = parent_namehash,
            .owner = try Address.fromHex(owner_str),
            .registrant = try Address.fromHex(owner_str), // Fallback
            .resolver = try Address.fromHex(resolver_str),
            .registry = try Address.fromHex(registry_str),
            .chain = try models.Chain.fromString(chain_str),
            .token_id = try parseU256Hex(token_id_str),
            .canonical_id = try parseU256Hex(canonical_id_str),
            .token_version = @intCast(q.getInt64(11)),
            .expiry = @bitCast(q.getInt64(12)),
            .registry_locked = q.getBool(13),
            .migrated = q.getBool(14),
            .ejected = q.getBool(15),
            .created_at = q.getInt64(16),
            .created_block = @intCast(q.getInt64(17)),
            .updated_at = q.getInt64(18),
            .updated_block = @intCast(q.getInt64(19)),
            .is_wrapped = false,
            .wrapper_fuses = null,
            .wrapper_expiry = null,
            .is_v1_name = false,
            .v1_label_hash = null,
        });
    }

    return names.toOwnedSlice(db.allocator);
}

// ============================================================================
// SUBDOMAIN OPERATIONS
// ============================================================================

/// Count direct subdomains of a name
pub fn countDirectSubdomains(db: *Database, parent_name: []const u8) !u32 {
    var q = try Query.init(db, "SELECT COUNT(*) FROM names WHERE parent_name = ?");
    defer q.deinit();

    try q.bindText(parent_name);

    if (try q.step()) {
        return @intCast(q.getInt64(0));
    }
    return 0;
}

/// Check if a name has any direct subdomains
pub fn hasDirectSubdomains(db: *Database, parent_name: []const u8) !bool {
    var q = try Query.init(db, "SELECT 1 FROM names WHERE parent_name = ? LIMIT 1");
    defer q.deinit();

    try q.bindText(parent_name);
    return try q.step();
}

/// Get direct subdomains of a name with pagination
pub fn getSubdomains(db: *Database, parent_name_arg: []const u8, skip: u32, limit: u32) ![]models.Name {
    var q = try Query.init(db, SQL_SELECT_NAMES_SHORT ++ " WHERE parent_name = ? ORDER BY name LIMIT ? OFFSET ?");
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
