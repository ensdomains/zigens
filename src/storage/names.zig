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
// HELPERS
// ============================================================================

/// Safely convert u64 expiry to i64 for SQLite storage.
/// Values exceeding i64::max are mapped to 0 (never expires).
fn safeU64ToI64(val: u64) i64 {
    if (val > @as(u64, @intCast(std.math.maxInt(i64)))) return 0;
    return @intCast(val);
}

// ============================================================================
// CONSTANTS
// ============================================================================

/// Standard SELECT columns for names table (29 columns)
/// Column order: name(0), label(1), label_hash(2), parent_name(3), parent_namehash(4),
///               protocol(5), registry(6), owner(7), registrant(8), resolver(9),
///               token_id(10), canonical_id(11), token_version(12), namehash(13), expiry(14),
///               registry_locked(15), migrated(16), created_block(17), created_at(18),
///               registered_at(19), updated_block(20), updated_at(21), is_wrapped(22), wrapper_fuses(23),
///               wrapper_expiry(24), is_v1_name(25), v1_label_hash(26),
///               is_reachable(27), unreachable_since(28)
const SQL_SELECT_NAMES =
    \\SELECT name, label, label_hash, parent_name, parent_namehash, protocol, registry,
    \\       owner, registrant, resolver, token_id, canonical_id, token_version, namehash, expiry,
    \\       registry_locked, migrated, created_block, created_at, registered_at, updated_block, updated_at,
    \\       is_wrapped, wrapper_fuses, wrapper_expiry, is_v1_name, v1_label_hash,
    \\       is_reachable, unreachable_since
    \\FROM names
;

/// Shorter SELECT for queries that don't need wrapper fields (24 columns).
/// Still includes is_reachable/unreachable_since so callers can honor
/// reachability filtering and serialize the flag.
const SQL_SELECT_NAMES_SHORT =
    \\SELECT name, label, label_hash, parent_name, parent_namehash, protocol, registry,
    \\       owner, registrant, resolver, token_id, canonical_id, token_version, namehash, expiry,
    \\       registry_locked, migrated, created_block, created_at, registered_at, updated_block, updated_at,
    \\       is_reachable, unreachable_since
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

/// Stack-buffer variant of `formatU256Hex` — writes "0x" + 64 hex chars (66 bytes)
/// directly into a caller-provided fixed buffer. Avoids the per-call heap alloc on
/// per-event hot paths (`insertName` token_id/canonical_id, token regen lookups).
fn formatU256HexBuf(buf: *[66]u8, value: u256) []const u8 {
    return std.fmt.bufPrint(buf, "0x{x:0>64}", .{value}) catch unreachable;
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
    };
}

/// Parse a Name model from short query (22 columns, no wrapper fields)
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
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
        .is_reachable = q.getBool(22),
        .unreachable_since = q.getOptionalInt64(23),
    };
}

// ============================================================================
// REGISTRY OPERATIONS
// ============================================================================

pub fn insertRegistry(db: *Database, registry: models.Registry) !void {
    // Use INSERT OR IGNORE to keep the FIRST SubregistryUpdate (when subregistry was established)
    // not later ones. This ensures created_block reflects when the parent->subregistry mapping
    // was first created, which is needed for correct temporal parent lookups.
    var q = try Query.init(db,
        \\INSERT OR IGNORE INTO registries
        \\(address, protocol, name, namehash, parent_registry, created_block, created_at)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
    );
    defer q.deinit();

    try q.bindAddress(registry.address);
    try q.bindTextStatic(registry.protocol.toString());
    try q.bindText(registry.name);
    try q.bindHash(registry.namehash);
    try q.bindAddress(registry.parent_registry);
    try q.bindInt64(@intCast(registry.created_block));
    try q.bindInt64(registry.created_at);
    try q.exec();
}

/// Update a registry that was created with a canonicalId placeholder name to use the actual name.
/// Also updates names that used this placeholder as parent_name, and events stored with the
/// placeholder in their name/namehash columns (see updatePlaceholderEventsByName for event payload
/// handling — we only patch the indexed columns, not the raw JSON data blob).
pub fn updateRegistryPlaceholderName(db: *Database, placeholder_name: []const u8, actual_name: []const u8, namehash: Hash) !u32 {
    var reg_q = try Query.init(db, "UPDATE registries SET name = ?, namehash = ? WHERE name = ?");
    defer reg_q.deinit();
    try reg_q.bindText(actual_name);
    try reg_q.bindHash(namehash);
    try reg_q.bindText(placeholder_name);
    try reg_q.exec();
    const registry_changes = reg_q.changes();

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

    const event_changes = try updatePlaceholderEventsByName(db, placeholder_name, actual_name, namehash);

    if (registry_changes > 0 or names_changes > 0 or event_changes > 0) {
        // Debug-level: this fires once per migrated/registered name during a sync,
        // generating thousands of identical info lines on a fresh Sepolia reindex.
        std.log.debug("Updated placeholder '{s}' -> '{s}': {d} registries, {d} names, {d} events", .{
            placeholder_name, actual_name, registry_changes, names_changes, event_changes,
        });
    }

    return registry_changes + names_changes + event_changes;
}

/// Patch events stored with a placeholder name (either "canonicalId:N" from SubregistryUpdated or
/// "tokenId:N" from ResolverUpdated) once the name is known. Updates the top-level name/namehash
/// columns only; the raw JSON data blob is left intact as a historical record of what the handler
/// decoded at event-process time.
pub fn updatePlaceholderEventsByName(db: *Database, placeholder_name: []const u8, actual_name: []const u8, namehash: Hash) !u32 {
    var q = try Query.init(db, "UPDATE events SET name = ?, namehash = ? WHERE name = ?");
    defer q.deinit();
    try q.bindText(actual_name);
    try q.bindHash(namehash);
    try q.bindText(placeholder_name);
    try q.exec();
    return q.changes();
}

pub fn getRegistriesByOwner(db: *Database, protocol: models.Protocol, owner: Address) ![]models.Registry {
    // Join registries with names on namehash to find registries where the NAME is owned by the specified owner
    // This returns registries for names that the owner controls (not registries that the owner's names use as subregistries)
    // Only returns the LATEST (most recent) registry per name to avoid duplicates when subregistry is updated
    var q = try Query.init(db,
        \\SELECT r.address, r.protocol, r.name, r.namehash, r.parent_registry, r.created_block, r.created_at
        \\FROM registries r
        \\JOIN names n ON r.namehash = n.namehash AND r.protocol = n.protocol
        \\WHERE r.protocol = ? AND n.owner = ?
        \\AND r.created_block = (
        \\    SELECT MAX(r2.created_block)
        \\    FROM registries r2
        \\    WHERE r2.namehash = r.namehash AND r2.protocol = r.protocol
        \\)
    );
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());
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
        const protocol_str = q.getTextSlice(1) orelse continue;
        const name_str = q.getTextSlice(2) orelse "";
        const namehash_str = q.getTextSlice(3) orelse continue;
        const parent_str = q.getTextSlice(4) orelse continue;

        try registries.append(db.allocator, .{
            .address = try Address.fromHex(address_str),
            .protocol = try models.Protocol.fromString(protocol_str),
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
    var q = try Query.initCached(db,
        \\INSERT INTO names
        \\(namehash, name, label, label_hash, parent_name, parent_namehash, protocol,
        \\ registry, owner, registrant, resolver, token_id, canonical_id, token_version, expiry,
        \\ registry_locked, migrated, created_block, created_at, registered_at, updated_block, updated_at,
        \\ is_wrapped, wrapper_fuses, wrapper_expiry, is_v1_name, v1_label_hash,
        \\ is_reachable, unreachable_since)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(protocol, namehash) DO UPDATE SET
        \\ name = excluded.name,
        \\ label = excluded.label,
        \\ label_hash = excluded.label_hash,
        \\ parent_name = excluded.parent_name,
        \\ parent_namehash = excluded.parent_namehash,
        \\ registry = excluded.registry,
        \\ owner = excluded.owner,
        \\ registrant = excluded.registrant,
        \\ resolver = excluded.resolver,
        \\ token_id = excluded.token_id,
        \\ canonical_id = excluded.canonical_id,
        \\ token_version = excluded.token_version,
        \\ expiry = excluded.expiry,
        \\ registry_locked = excluded.registry_locked,
        \\ migrated = excluded.migrated,
        \\ registered_at = excluded.registered_at,
        \\ updated_block = excluded.updated_block,
        \\ updated_at = excluded.updated_at,
        \\ is_wrapped = excluded.is_wrapped,
        \\ wrapper_fuses = excluded.wrapper_fuses,
        \\ wrapper_expiry = excluded.wrapper_expiry,
        \\ is_v1_name = excluded.is_v1_name,
        \\ v1_label_hash = excluded.v1_label_hash,
        \\ is_reachable = excluded.is_reachable,
        \\ unreachable_since = excluded.unreachable_since
    );
    defer q.deinit();

    // Format token IDs as hex strings into stack buffers — both are exactly 66 chars
    // ("0x" + 64 hex). Avoids two heap allocs per insertName call.
    var token_id_buf: [66]u8 = undefined;
    const token_id_hex = formatU256HexBuf(&token_id_buf, name.token_id);
    var canonical_id_buf: [66]u8 = undefined;
    const canonical_id_hex = formatU256HexBuf(&canonical_id_buf, name.canonical_id);

    try q.bindHash(name.namehash);
    try q.bindOptionalText(name.name);
    try q.bindOptionalText(name.label);
    try q.bindHash(name.label_hash);
    try q.bindOptionalText(name.parent_name);
    try q.bindHash(name.parent_namehash);
    try q.bindTextStatic(name.protocol.toString());
    try q.bindAddress(name.registry);
    try q.bindAddress(name.owner);
    try q.bindAddress(name.registrant);
    try q.bindAddress(name.resolver);
    try q.bindText(token_id_hex);
    try q.bindText(canonical_id_hex);
    try q.bindInt64(@intCast(name.token_version));
    try q.bindInt64(safeU64ToI64(name.expiry));
    try q.bindInt(if (name.registry_locked) 1 else 0);
    try q.bindInt(if (name.migrated) 1 else 0);
    try q.bindInt64(@intCast(name.created_block));
    try q.bindInt64(name.created_at);
    try q.bindInt64(name.registered_at);
    try q.bindInt64(@intCast(name.updated_block));
    try q.bindInt64(name.updated_at);
    try q.bindInt(if (name.is_wrapped) 1 else 0);
    try q.bindOptionalText(name.wrapper_fuses);
    try q.bindOptionalInt64(name.wrapper_expiry);
    try q.bindInt(if (name.is_v1_name) 1 else 0);
    try q.bindOptionalText(name.v1_label_hash);
    try q.bindInt(if (name.is_reachable) 1 else 0);
    try q.bindOptionalInt64(name.unreachable_since);
    try q.exec();
}

/// Update name expiry (for renewals)
pub fn updateNameExpiry(db: *Database, namehash: Hash, expiry: u64) !void {
    var q = try Query.initCached(db, "UPDATE names SET expiry = ?, updated_at = ? WHERE namehash = ?");
    defer q.deinit();

    try q.bindInt64(safeU64ToI64(expiry));
    try q.bindInt64(std.time.timestamp());
    try q.bindHashBuf(namehash);
    try q.exec();
}

/// Update name owner (for transfers)
pub fn updateNameOwner(db: *Database, namehash: Hash, new_owner: Address) !void {
    var q = try Query.initCached(db, "UPDATE names SET owner = ?, updated_at = ? WHERE namehash = ?");
    defer q.deinit();

    try q.bindAddressBuf(new_owner);
    try q.bindInt64(std.time.timestamp());
    try q.bindHashBuf(namehash);
    try q.exec();
}

/// Mark a V1 name as migrated to V2, updating owner to the migration controller.
/// Sets migrated=true so the API can distinguish live V1 names from those that
/// have been transferred to a V1→V2 migration controller (which is functionally
/// "no longer ownable on V1").
pub fn markNameMigrated(db: *Database, namehash: Hash, controller: Address) !void {
    var q = try Query.initCached(db, "UPDATE names SET owner = ?, migrated = 1, updated_at = ? WHERE namehash = ?");
    defer q.deinit();

    try q.bindAddressBuf(controller);
    try q.bindInt64(std.time.timestamp());
    try q.bindHashBuf(namehash);
    try q.exec();
}

/// Update name resolver
pub fn updateNameResolver(db: *Database, namehash: Hash, resolver: Address) !void {
    var q = try Query.initCached(db, "UPDATE names SET resolver = ?, updated_at = ? WHERE namehash = ?");
    defer q.deinit();

    try q.bindAddressBuf(resolver);
    try q.bindInt64(std.time.timestamp());
    try q.bindHashBuf(namehash);
    try q.exec();
}

/// Delete a name by its namehash (registry-safe: only deletes the exact name)
pub fn deleteNameByNamehash(db: *Database, namehash: Hash) !void {
    var q = try Query.initCached(db, "DELETE FROM names WHERE namehash = ?");
    defer q.deinit();

    try q.bindHashBuf(namehash);
    try q.exec();
}

/// Update token_id for a specific name by namehash (registry-safe: only updates the exact name).
/// Only updates token_id and token_version — canonical_id is unchanged across regeneration.
pub fn updateNameTokenIdByNamehash(db: *Database, namehash: Hash, new_token_id: u256) !void {
    const token_id_utils = @import("../types/token_id.zig");
    const token_version = token_id_utils.getTokenVersion(new_token_id);

    var q = try Query.initCached(db, "UPDATE names SET token_id = ?, token_version = ?, updated_at = ? WHERE namehash = ?");
    defer q.deinit();

    var new_token_id_buf: [66]u8 = undefined;
    const new_token_id_hex = formatU256HexBuf(&new_token_id_buf, new_token_id);

    try q.bindText(new_token_id_hex);
    try q.bindInt64(@intCast(token_version));
    try q.bindInt64(std.time.timestamp());
    try q.bindHashBuf(namehash);
    try q.exec();
}

/// Update wrapper state for a name
pub fn updateNameWrapperState(db: *Database, namehash: Hash, fuses: u32, expiry: u64) !void {
    var q = try Query.initCached(db,
        \\UPDATE names SET is_wrapped = 1, wrapper_fuses = ?, wrapper_expiry = ?,
        \\updated_at = ? WHERE namehash = ?
    );
    defer q.deinit();

    // u32 max = 10 decimal digits — stack buffer suffices, no heap alloc per event.
    var fuses_buf: [16]u8 = undefined;
    const fuses_str = try std.fmt.bufPrint(&fuses_buf, "{d}", .{fuses});

    try q.bindText(fuses_str);
    try q.bindInt64(safeU64ToI64(expiry));
    try q.bindInt64(std.time.timestamp());
    try q.bindHash(namehash);
    try q.exec();
}

/// Clear wrapper state for a name (unwrap)
pub fn updateNameUnwrapperState(db: *Database, namehash: Hash) !void {
    var q = try Query.initCached(db,
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
    var q = try Query.initCached(db,
        \\UPDATE names SET wrapper_fuses = ?, updated_at = ? WHERE namehash = ?
    );
    defer q.deinit();

    var fuses_buf: [16]u8 = undefined;
    const fuses_str = try std.fmt.bufPrint(&fuses_buf, "{d}", .{fuses});

    try q.bindText(fuses_str);
    try q.bindInt64(std.time.timestamp());
    try q.bindHash(namehash);
    try q.exec();
}

/// Update wrapper expiry only
pub fn updateNameWrapperExpiry(db: *Database, namehash: Hash, expiry: u64) !void {
    var q = try Query.initCached(db,
        \\UPDATE names SET wrapper_expiry = ?, updated_at = ? WHERE namehash = ?
    );
    defer q.deinit();

    try q.bindInt64(safeU64ToI64(expiry));
    try q.bindInt64(std.time.timestamp());
    try q.bindHash(namehash);
    try q.exec();
}

/// Update label and name fields for a name record (used by label healing)
pub fn updateNameLabel(database: *Database, namehash: Hash, label: []const u8, name: []const u8) !void {
    var q = try Query.initCached(database,
        \\UPDATE names SET label = ?, name = ?
        \\WHERE namehash = ?
    );
    defer q.deinit();

    try q.bindText(label);
    try q.bindText(name);
    try q.bindHash(namehash);
    try q.exec();
}

/// Update creation date if the new block is earlier (for backfill scenarios)
pub fn updateNameCreationDateIfEarlier(db: *Database, namehash: Hash, block_number: u64, created_at: i64) !void {
    var q = try Query.initCached(db,
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
        try std.fmt.allocPrint(db.allocator, SQL_SELECT_NAMES_SHORT ++ " WHERE is_reachable = 1 AND owner = ? LIMIT {d}", .{l})
    else
        try db.allocator.dupe(u8, SQL_SELECT_NAMES_SHORT ++ " WHERE is_reachable = 1 AND owner = ?");
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
    var q = try Query.init(db, SQL_SELECT_NAMES_SHORT ++ " WHERE is_reachable = 1 AND resolver = ? ORDER BY created_at DESC LIMIT ?");
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

/// Get names by registrant address. Unreachable rows are filtered out.
pub fn getNamesByRegistrant(db: *Database, registrant: Address, skip: u32, limit: u32) ![]models.Name {
    var q = try Query.init(db, SQL_SELECT_NAMES_SHORT ++ " WHERE is_reachable = 1 AND registrant = ? ORDER BY created_at DESC LIMIT ? OFFSET ?");
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

/// Sort field for name queries
pub const NameSortField = enum {
    created_at,
    name,
    expiry,
    registered_at,

    pub fn toSql(self: NameSortField) []const u8 {
        return switch (self) {
            .created_at => "created_at",
            .name => "name",
            .expiry => "expiry",
            .registered_at => "registered_at",
        };
    }
};

/// Append SQL WHERE conditions corresponding to a `NameFilters` value into `conditions`.
/// Strings allocated for dynamic IN clauses are tracked in `allocated_strings` so the
/// caller can free them after use. The condition list is kept in lockstep with `bindNameFilters`
/// so binds happen in the same order they're appended here.
fn appendNameFilterConditions(
    db: *Database,
    filters: NameFilters,
    conditions: *std.ArrayList([]const u8),
    allocated_strings: *std.ArrayList([]const u8),
) !void {
    if (!filters.include_unreachable) {
        try conditions.append(db.allocator, "is_reachable = 1");
    }
    if (filters.owner != null) {
        try conditions.append(db.allocator, "owner = ?");
    }
    if (filters.owner_in) |owners| {
        if (owners.len > 0) {
            var in_parts: std.ArrayList(u8) = .{};
            defer in_parts.deinit(db.allocator);
            try in_parts.appendSlice(db.allocator, "owner IN (");
            for (owners, 0..) |_, i| {
                if (i > 0) try in_parts.appendSlice(db.allocator, ", ");
                try in_parts.appendSlice(db.allocator, "?");
            }
            try in_parts.appendSlice(db.allocator, ")");
            const clause = try db.allocator.dupe(u8, in_parts.items);
            try allocated_strings.append(db.allocator, clause);
            try conditions.append(db.allocator, clause);
        }
    }
    if (filters.name != null) try conditions.append(db.allocator, "name = ?");
    if (filters.name_contains != null) try conditions.append(db.allocator, "name LIKE '%' || ? || '%'");
    if (filters.name_contains_nocase != null) try conditions.append(db.allocator, "LOWER(name) LIKE '%' || LOWER(?) || '%'");
    if (filters.name_starts_with != null) try conditions.append(db.allocator, "name LIKE ? || '%'");
    if (filters.name_ends_with != null) try conditions.append(db.allocator, "name LIKE '%' || ?");
    if (filters.expiry_gt != null) try conditions.append(db.allocator, "expiry > ?");
    if (filters.expiry_gte != null) try conditions.append(db.allocator, "expiry >= ?");
    if (filters.expiry_lt != null) try conditions.append(db.allocator, "expiry < ?");
    if (filters.expiry_lte != null) try conditions.append(db.allocator, "expiry <= ?");
    if (filters.resolved_address != null) {
        try conditions.append(db.allocator, "namehash IN (SELECT namehash FROM resolver_addresses WHERE address = ?)");
    }
    if (filters.resolver != null) try conditions.append(db.allocator, "resolver = ?");
    if (filters.migrated) |m| {
        try conditions.append(db.allocator, if (m) "migrated = 1" else "migrated = 0");
    }
    if (filters.has_subdomains) |has_subs| {
        try conditions.append(db.allocator, if (has_subs)
            "(SELECT COUNT(*) FROM names AS sub WHERE sub.parent_name = names.name AND sub.is_reachable = 1) > 0"
        else
            "(SELECT COUNT(*) FROM names AS sub WHERE sub.parent_name = names.name AND sub.is_reachable = 1) = 0");
    }
    if (filters.subdomain_count_gt != null) {
        try conditions.append(db.allocator, "(SELECT COUNT(*) FROM names AS sub WHERE sub.parent_name = names.name AND sub.is_reachable = 1) > ?");
    }
    if (filters.subdomain_count_lt != null) {
        try conditions.append(db.allocator, "(SELECT COUNT(*) FROM names AS sub WHERE sub.parent_name = names.name AND sub.is_reachable = 1) < ?");
    }
}

/// Bind values for `NameFilters` in the same order `appendNameFilterConditions` appends them.
fn bindNameFilters(q: *Query, filters: NameFilters) !void {
    if (filters.owner) |o| try q.bindAddress(o);
    if (filters.owner_in) |owners| {
        for (owners) |o| try q.bindAddress(o);
    }
    if (filters.name) |n| try q.bindText(n);
    if (filters.name_contains) |n| try q.bindText(n);
    if (filters.name_contains_nocase) |n| try q.bindText(n);
    if (filters.name_starts_with) |n| try q.bindText(n);
    if (filters.name_ends_with) |n| try q.bindText(n);
    if (filters.expiry_gt) |v| try q.bindInt64(v);
    if (filters.expiry_gte) |v| try q.bindInt64(v);
    if (filters.expiry_lt) |v| try q.bindInt64(v);
    if (filters.expiry_lte) |v| try q.bindInt64(v);
    if (filters.resolved_address) |addr| try q.bindAddress(addr);
    if (filters.resolver) |addr| try q.bindAddress(addr);
    // migrated, has_subdomains contribute no binds (literal SQL)
    if (filters.subdomain_count_gt) |v| try q.bindInt64(v);
    if (filters.subdomain_count_lt) |v| try q.bindInt64(v);
}

/// Count rows that come before the given namehash in the current sort order.
/// Used to convert a cursor (namehash) to an offset for paginated queries.
/// Returns 0 if the namehash isn't found (caller falls through to offset=0).
pub fn countRowsBeforeNamehash(
    db: *Database,
    cursor_namehash: []const u8,
    sort_field: NameSortField,
    order_dir: OrderDir,
    filters: NameFilters,
) !u32 {
    const field = sort_field.toSql();
    // "before" means "would appear earlier in the result set" — depends on sort direction:
    //   DESC sort: row A is before row B if A.field > B.field OR (A.field == B.field AND A.namehash > B.namehash)
    //   ASC sort:  row A is before row B if A.field < B.field OR (A.field == B.field AND A.namehash < B.namehash)
    // Tiebreaker by namehash ensures a stable total order across the full result set.
    //
    // The filter conditions must match getFilteredNames'/getFilteredNameCount's WHERE clause —
    // otherwise the offset count is taken over an unfiltered superset and pagination skips too
    // many rows, producing partial results (e.g. isMigrated:true with ~9 pages would lose ~343
    // rows because non-migrated rows count toward the offset).

    var conditions: std.ArrayList([]const u8) = .{};
    defer conditions.deinit(db.allocator);
    var allocated_strings: std.ArrayList([]const u8) = .{};
    defer {
        for (allocated_strings.items) |s| db.allocator.free(s);
        allocated_strings.deinit(db.allocator);
    }
    try appendNameFilterConditions(db, filters, &conditions, &allocated_strings);

    var filter_clause: std.ArrayList(u8) = .{};
    defer filter_clause.deinit(db.allocator);
    if (conditions.items.len > 0) {
        for (conditions.items) |cond| {
            try filter_clause.appendSlice(db.allocator, " AND ");
            try filter_clause.appendSlice(db.allocator, cond);
        }
    }

    const op = if (order_dir == .desc) ">" else "<";
    const sql = try std.fmt.allocPrint(
        db.allocator,
        "SELECT COUNT(*) FROM names WHERE EXISTS (SELECT 1 FROM names c WHERE c.namehash = ? AND (names.{s} {s} c.{s} OR (names.{s} = c.{s} AND names.namehash {s} c.namehash))){s}",
        .{ field, op, field, field, field, op, filter_clause.items },
    );
    defer db.allocator.free(sql);

    var q = try Query.initCached(db, sql);
    defer q.deinit();
    try q.bindText(cursor_namehash);
    try bindNameFilters(&q, filters);
    if (!try q.step()) return 0;
    return @intCast(q.getInt64(0));
}

/// Parse name rows from a query result
fn parseNameRows(q: *Query, allocator: std.mem.Allocator) ![]models.Name {
    var names: std.ArrayList(models.Name) = .{};
    errdefer {
        for (names.items) |*name| {
            name.deinit(allocator);
        }
        names.deinit(allocator);
    }

    while (try q.step()) {
        // Column order: name(0), namehash(1), label(2), label_hash(3), parent_name(4), parent_namehash(5),
        //               owner(6), resolver(7), registry(8), protocol(9), token_id(10),
        //               canonical_id(11), token_version(12), expiry(13), registry_locked(14),
        //               migrated(15), created_at(16), registered_at(17),
        //               created_block(18), updated_at(19), updated_block(20),
        //               is_reachable(21), unreachable_since(22)
        const name_str = q.getTextSlice(0) orelse "";
        const namehash_str = q.getTextSlice(1) orelse "";
        const label_str = q.getTextSlice(2) orelse "";
        const label_hash_str = q.getTextSlice(3) orelse "";
        const parent_name_str = q.getTextSlice(4) orelse "";
        const parent_namehash_str = q.getTextSlice(5) orelse "";
        const owner_str = q.getTextSlice(6) orelse "";
        const resolver_str = q.getTextSlice(7) orelse "";
        const registry_str = q.getTextSlice(8) orelse "";
        const protocol_str = q.getTextSlice(9) orelse models.Protocol.v2.toString();
        const token_id_str = q.getTextSlice(10) orelse "0x0";
        const canonical_id_str = q.getTextSlice(11) orelse "0x0";

        try names.append(allocator, .{
            .name = try allocator.dupe(u8, name_str),
            .namehash = try Hash.fromHex(namehash_str),
            .label = try allocator.dupe(u8, label_str),
            .label_hash = try Hash.fromHex(label_hash_str),
            .parent_name = try allocator.dupe(u8, parent_name_str),
            .parent_namehash = try Hash.fromHex(parent_namehash_str),
            .owner = try Address.fromHex(owner_str),
            .registrant = try Address.fromHex(owner_str), // Fallback
            .resolver = try Address.fromHex(resolver_str),
            .registry = try Address.fromHex(registry_str),
            .protocol = try models.Protocol.fromString(protocol_str),
            .token_id = try parseU256Hex(token_id_str),
            .canonical_id = try parseU256Hex(canonical_id_str),
            .token_version = @intCast(q.getInt64(12)),
            .expiry = @bitCast(q.getInt64(13)),
            .registry_locked = q.getBool(14),
            .migrated = q.getBool(15),
            .created_at = q.getInt64(16),
            .registered_at = q.getOptionalInt64(17) orelse q.getInt64(16),
            .created_block = @intCast(q.getInt64(18)),
            .updated_at = q.getInt64(19),
            .updated_block = @intCast(q.getInt64(20)),
            .is_wrapped = false,
            .wrapper_fuses = null,
            .wrapper_expiry = null,
            .is_v1_name = false,
            .v1_label_hash = null,
            .is_reachable = q.getBool(21),
            .unreachable_since = q.getOptionalInt64(22),
        });
    }

    return names.toOwnedSlice(allocator);
}

pub fn getAllNames(db: *Database, owner: ?Address, skip: u32, limit: u32) ![]models.Name {
    return getAllNamesWithOrder(db, owner, skip, limit, .desc, .created_at);
}

/// Filter options for querying names
pub const NameFilters = struct {
    // Owner filters
    owner: ?Address = null,
    owner_in: ?[]const Address = null,
    // Name filters
    name: ?[]const u8 = null,
    name_in: ?[]const []const u8 = null,
    name_contains: ?[]const u8 = null,
    name_contains_nocase: ?[]const u8 = null,
    name_starts_with: ?[]const u8 = null,
    name_ends_with: ?[]const u8 = null,
    // Expiry filters
    expiry_gt: ?i64 = null,
    expiry_gte: ?i64 = null,
    expiry_lt: ?i64 = null,
    expiry_lte: ?i64 = null,
    // Resolved address filter (requires resolver lookup)
    resolved_address: ?Address = null,
    // Resolver contract address filter
    resolver: ?Address = null,
    // Migration filter
    migrated: ?bool = null,
    // Subdomain filters (requires subquery)
    has_subdomains: ?bool = null,
    subdomain_count_gt: ?i64 = null,
    subdomain_count_lt: ?i64 = null,
    /// When false (default), only `is_reachable = 1` rows are returned.
    /// Set to true to include rows orphaned by ancestor subregistry repoints
    /// (for audit/debug). See `registry_entries.zig` for invalidation logic.
    include_unreachable: bool = false,
};

/// Get names with filters pushed down to DB query
pub fn getFilteredNames(db: *Database, filters: NameFilters, skip: u32, limit: u32, order_dir: OrderDir, sort_field: NameSortField) ![]models.Name {
    const order_str = if (order_dir == .desc) "DESC" else "ASC";

    // Build WHERE clause dynamically using ArrayList for conditions
    var conditions: std.ArrayList([]const u8) = .{};
    defer conditions.deinit(db.allocator);

    // Track allocations for cleanup
    var allocated_strings: std.ArrayList([]const u8) = .{};
    defer {
        for (allocated_strings.items) |s| db.allocator.free(s);
        allocated_strings.deinit(db.allocator);
    }

    // Reachability filter: default-on, hides orphans from subregistry repoints.
    // Caller passes `include_unreachable = true` to disable for audit queries.
    if (!filters.include_unreachable) {
        try conditions.append(db.allocator, "is_reachable = 1");
    }

    // Owner filters
    if (filters.owner != null) {
        try conditions.append(db.allocator, "owner = ?");
    }
    if (filters.owner_in) |owners| {
        if (owners.len > 0) {
            // Build IN clause: owner IN (?, ?, ...)
            var in_parts: std.ArrayList(u8) = .{};
            defer in_parts.deinit(db.allocator);
            try in_parts.appendSlice(db.allocator, "owner IN (");
            for (owners, 0..) |_, i| {
                if (i > 0) try in_parts.appendSlice(db.allocator, ", ");
                try in_parts.appendSlice(db.allocator, "?");
            }
            try in_parts.appendSlice(db.allocator, ")");
            const clause = try db.allocator.dupe(u8, in_parts.items);
            try allocated_strings.append(db.allocator, clause);
            try conditions.append(db.allocator, clause);
        }
    }

    // Name filters
    if (filters.name != null) {
        try conditions.append(db.allocator, "name = ?");
    }
    if (filters.name_in) |names| {
        if (names.len == 0) {
            try conditions.append(db.allocator, "1=0");
        } else {
            var in_parts: std.ArrayList(u8) = .{};
            defer in_parts.deinit(db.allocator);
            try in_parts.appendSlice(db.allocator, "name IN (");
            for (names, 0..) |_, i| {
                if (i > 0) try in_parts.appendSlice(db.allocator, ", ");
                try in_parts.appendSlice(db.allocator, "?");
            }
            try in_parts.appendSlice(db.allocator, ")");
            const clause = try db.allocator.dupe(u8, in_parts.items);
            try allocated_strings.append(db.allocator, clause);
            try conditions.append(db.allocator, clause);
        }
    }
    if (filters.name_contains != null) {
        try conditions.append(db.allocator, "name LIKE '%' || ? || '%'");
    }
    if (filters.name_contains_nocase != null) {
        try conditions.append(db.allocator, "LOWER(name) LIKE '%' || LOWER(?) || '%'");
    }
    if (filters.name_starts_with != null) {
        try conditions.append(db.allocator, "name LIKE ? || '%'");
    }
    if (filters.name_ends_with != null) {
        try conditions.append(db.allocator, "name LIKE '%' || ?");
    }

    // Expiry filters
    if (filters.expiry_gt != null) {
        try conditions.append(db.allocator, "expiry > ?");
    }
    if (filters.expiry_gte != null) {
        try conditions.append(db.allocator, "expiry >= ?");
    }
    if (filters.expiry_lt != null) {
        try conditions.append(db.allocator, "expiry < ?");
    }
    if (filters.expiry_lte != null) {
        try conditions.append(db.allocator, "expiry <= ?");
    }

    // Resolved address filter (join with resolver_addresses table)
    if (filters.resolved_address != null) {
        try conditions.append(db.allocator, "namehash IN (SELECT namehash FROM resolver_addresses WHERE address = ?)");
    }

    // Resolver contract address filter
    if (filters.resolver != null) {
        try conditions.append(db.allocator, "resolver = ?");
    }

    // Migration filter
    if (filters.migrated) |m| {
        if (m) {
            try conditions.append(db.allocator, "migrated = 1");
        } else {
            try conditions.append(db.allocator, "migrated = 0");
        }
    }

    // Subdomain count filters (using subquery)
    if (filters.has_subdomains) |has_subs| {
        if (has_subs) {
            try conditions.append(db.allocator, "(SELECT COUNT(*) FROM names AS sub WHERE sub.parent_name = names.name AND sub.is_reachable = 1) > 0");
        } else {
            try conditions.append(db.allocator, "(SELECT COUNT(*) FROM names AS sub WHERE sub.parent_name = names.name AND sub.is_reachable = 1) = 0");
        }
    }
    if (filters.subdomain_count_gt != null) {
        try conditions.append(db.allocator, "(SELECT COUNT(*) FROM names AS sub WHERE sub.parent_name = names.name AND sub.is_reachable = 1) > ?");
    }
    if (filters.subdomain_count_lt != null) {
        try conditions.append(db.allocator, "(SELECT COUNT(*) FROM names AS sub WHERE sub.parent_name = names.name AND sub.is_reachable = 1) < ?");
    }

    // Build WHERE clause
    var where_clause: std.ArrayList(u8) = .{};
    defer where_clause.deinit(db.allocator);

    if (conditions.items.len > 0) {
        try where_clause.appendSlice(db.allocator, "WHERE ");
        for (conditions.items, 0..) |cond, i| {
            if (i > 0) try where_clause.appendSlice(db.allocator, " AND ");
            try where_clause.appendSlice(db.allocator, cond);
        }
        try where_clause.appendSlice(db.allocator, " ");
    }

    // Secondary sort on namehash (same direction) gives a stable total order across tied
    // primary keys — required so cursor pagination matches countRowsBeforeNamehash's
    // stable comparator. Without it, SQLite's tie-breaking is non-deterministic and pages
    // can duplicate or skip items.
    const sql = try std.fmt.allocPrint(db.allocator,
        \\SELECT name, namehash, label, label_hash, parent_name, parent_namehash, owner, resolver, registry, protocol,
        \\       token_id, canonical_id, token_version, expiry, registry_locked, migrated,
        \\       created_at, registered_at, created_block, updated_at, updated_block,
        \\       is_reachable, unreachable_since
        \\FROM names {s}ORDER BY {s} {s}, namehash {s} LIMIT ? OFFSET ?
    , .{ where_clause.items, sort_field.toSql(), order_str, order_str });
    defer db.allocator.free(sql);

    var q = try Query.initCached(db, sql);
    defer q.deinit();

    // Bind parameters in the same order as conditions were added
    if (filters.owner) |o| {
        try q.bindAddress(o);
    }
    if (filters.owner_in) |owners| {
        for (owners) |o| {
            try q.bindAddress(o);
        }
    }
    if (filters.name) |n| {
        try q.bindText(n);
    }
    if (filters.name_in) |names| {
        for (names) |n| {
            try q.bindText(n);
        }
    }
    if (filters.name_contains) |n| {
        try q.bindText(n);
    }
    if (filters.name_contains_nocase) |n| {
        try q.bindText(n);
    }
    if (filters.name_starts_with) |n| {
        try q.bindText(n);
    }
    if (filters.name_ends_with) |n| {
        try q.bindText(n);
    }
    if (filters.expiry_gt) |v| {
        try q.bindInt64(v);
    }
    if (filters.expiry_gte) |v| {
        try q.bindInt64(v);
    }
    if (filters.expiry_lt) |v| {
        try q.bindInt64(v);
    }
    if (filters.expiry_lte) |v| {
        try q.bindInt64(v);
    }
    if (filters.resolved_address) |addr| {
        try q.bindAddress(addr);
    }
    if (filters.resolver) |addr| {
        try q.bindAddress(addr);
    }
    // has_subdomains doesn't need binding (no ?)
    if (filters.subdomain_count_gt) |v| {
        try q.bindInt64(v);
    }
    if (filters.subdomain_count_lt) |v| {
        try q.bindInt64(v);
    }
    try q.bindInt(@intCast(limit));
    try q.bindInt(@intCast(skip));

    return parseNameRows(&q, db.allocator);
}

/// Get all names with configurable order direction
pub fn getAllNamesWithOrder(db: *Database, owner: ?Address, skip: u32, limit: u32, order_dir: OrderDir, sort_field: NameSortField) ![]models.Name {
    const order_str = if (order_dir == .desc) "DESC" else "ASC";
    // Secondary sort on namehash (same direction) — see countRowsBeforeNamehash for why.
    // is_reachable = 1 filter is applied by default; unreachable rows are
    // hidden from the legacy unfiltered listing. Use `getFilteredNames` with
    // `include_unreachable = true` to override.
    const sql = if (owner != null)
        try std.fmt.allocPrint(db.allocator,
            \\SELECT name, namehash, label, label_hash, parent_name, parent_namehash, owner, resolver, registry, protocol,
            \\       token_id, canonical_id, token_version, expiry, registry_locked, migrated,
            \\       created_at, registered_at, created_block, updated_at, updated_block,
            \\       is_reachable, unreachable_since
            \\FROM names WHERE is_reachable = 1 AND owner = ? ORDER BY {s} {s}, namehash {s} LIMIT ? OFFSET ?
        , .{ sort_field.toSql(), order_str, order_str })
    else
        try std.fmt.allocPrint(db.allocator,
            \\SELECT name, namehash, label, label_hash, parent_name, parent_namehash, owner, resolver, registry, protocol,
            \\       token_id, canonical_id, token_version, expiry, registry_locked, migrated,
            \\       created_at, registered_at, created_block, updated_at, updated_block,
            \\       is_reachable, unreachable_since
            \\FROM names WHERE is_reachable = 1 ORDER BY {s} {s}, namehash {s} LIMIT ? OFFSET ?
        , .{ sort_field.toSql(), order_str, order_str });
    defer db.allocator.free(sql);

    var q = try Query.initCached(db, sql);
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
        // Column order: name(0), namehash(1), label(2), label_hash(3), parent_name(4), parent_namehash(5),
        //               owner(6), resolver(7), registry(8), protocol(9), token_id(10),
        //               canonical_id(11), token_version(12), expiry(13), registry_locked(14),
        //               migrated(15), created_at(16), registered_at(17),
        //               created_block(18), updated_at(19), updated_block(20)
        const name_str = q.getTextSlice(0) orelse "";
        const namehash_str = q.getTextSlice(1) orelse "";
        const label_str = q.getTextSlice(2) orelse "";
        const label_hash_str = q.getTextSlice(3) orelse "";
        const parent_name_str = q.getTextSlice(4) orelse "";
        const parent_namehash_str = q.getTextSlice(5) orelse "";
        const owner_str = q.getTextSlice(6) orelse "";
        const resolver_str = q.getTextSlice(7) orelse "";
        const registry_str = q.getTextSlice(8) orelse "";
        const protocol_str = q.getTextSlice(9) orelse models.Protocol.v2.toString();
        const token_id_str = q.getTextSlice(10) orelse "0x0";
        const canonical_id_str = q.getTextSlice(11) orelse "0x0";

        try names.append(db.allocator, .{
            .name = try db.allocator.dupe(u8, name_str),
            .namehash = try Hash.fromHex(namehash_str),
            .label = try db.allocator.dupe(u8, label_str),
            .label_hash = try Hash.fromHex(label_hash_str),
            .parent_name = try db.allocator.dupe(u8, parent_name_str),
            .parent_namehash = try Hash.fromHex(parent_namehash_str),
            .owner = try Address.fromHex(owner_str),
            .registrant = try Address.fromHex(owner_str), // Fallback
            .resolver = try Address.fromHex(resolver_str),
            .registry = try Address.fromHex(registry_str),
            .protocol = try models.Protocol.fromString(protocol_str),
            .token_id = try parseU256Hex(token_id_str),
            .canonical_id = try parseU256Hex(canonical_id_str),
            .token_version = @intCast(q.getInt64(12)),
            .expiry = @bitCast(q.getInt64(13)),
            .registry_locked = q.getBool(14),
            .migrated = q.getBool(15),
            .created_at = q.getInt64(16),
            .registered_at = q.getOptionalInt64(17) orelse q.getInt64(16),
            .created_block = @intCast(q.getInt64(18)),
            .updated_at = q.getInt64(19),
            .updated_block = @intCast(q.getInt64(20)),
            .is_wrapped = false,
            .wrapper_fuses = null,
            .wrapper_expiry = null,
            .is_v1_name = false,
            .v1_label_hash = null,
            .is_reachable = q.getBool(21),
            .unreachable_since = q.getOptionalInt64(22),
        });
    }

    return names.toOwnedSlice(db.allocator);
}

// ============================================================================
// AGGREGATION OPERATIONS
// ============================================================================

/// Get total count of all names in the database
pub fn getTotalNameCount(db: *Database) !usize {
    return getFilteredNameCount(db, .{});
}

/// Get count of names with optional filters.
/// Builds the same WHERE clause as getFilteredNames but uses SELECT COUNT(*).
pub fn getFilteredNameCount(db: *Database, filters: NameFilters) !usize {
    var conditions: std.ArrayList([]const u8) = .{};
    defer conditions.deinit(db.allocator);

    var allocated_strings: std.ArrayList([]const u8) = .{};
    defer {
        for (allocated_strings.items) |s| db.allocator.free(s);
        allocated_strings.deinit(db.allocator);
    }

    // Build WHERE conditions (same order as getFilteredNames)
    if (!filters.include_unreachable) {
        try conditions.append(db.allocator, "is_reachable = 1");
    }
    if (filters.owner != null) {
        try conditions.append(db.allocator, "owner = ?");
    }
    if (filters.owner_in) |owners| {
        if (owners.len > 0) {
            var in_parts: std.ArrayList(u8) = .{};
            defer in_parts.deinit(db.allocator);
            try in_parts.appendSlice(db.allocator, "owner IN (");
            for (owners, 0..) |_, i| {
                if (i > 0) try in_parts.appendSlice(db.allocator, ", ");
                try in_parts.appendSlice(db.allocator, "?");
            }
            try in_parts.appendSlice(db.allocator, ")");
            const clause = try db.allocator.dupe(u8, in_parts.items);
            try allocated_strings.append(db.allocator, clause);
            try conditions.append(db.allocator, clause);
        }
    }
    if (filters.name != null) {
        try conditions.append(db.allocator, "name = ?");
    }
    if (filters.name_in) |names| {
        if (names.len == 0) {
            try conditions.append(db.allocator, "1=0");
        } else {
            var in_parts: std.ArrayList(u8) = .{};
            defer in_parts.deinit(db.allocator);
            try in_parts.appendSlice(db.allocator, "name IN (");
            for (names, 0..) |_, i| {
                if (i > 0) try in_parts.appendSlice(db.allocator, ", ");
                try in_parts.appendSlice(db.allocator, "?");
            }
            try in_parts.appendSlice(db.allocator, ")");
            const clause = try db.allocator.dupe(u8, in_parts.items);
            try allocated_strings.append(db.allocator, clause);
            try conditions.append(db.allocator, clause);
        }
    }
    if (filters.name_contains != null) {
        try conditions.append(db.allocator, "name LIKE '%' || ? || '%'");
    }
    if (filters.name_contains_nocase != null) {
        try conditions.append(db.allocator, "LOWER(name) LIKE '%' || LOWER(?) || '%'");
    }
    if (filters.name_starts_with != null) {
        try conditions.append(db.allocator, "name LIKE ? || '%'");
    }
    if (filters.name_ends_with != null) {
        try conditions.append(db.allocator, "name LIKE '%' || ?");
    }
    if (filters.expiry_gt != null) {
        try conditions.append(db.allocator, "expiry > ?");
    }
    if (filters.expiry_gte != null) {
        try conditions.append(db.allocator, "expiry >= ?");
    }
    if (filters.expiry_lt != null) {
        try conditions.append(db.allocator, "expiry < ?");
    }
    if (filters.expiry_lte != null) {
        try conditions.append(db.allocator, "expiry <= ?");
    }
    if (filters.resolved_address != null) {
        try conditions.append(db.allocator, "namehash IN (SELECT namehash FROM resolver_addresses WHERE address = ?)");
    }
    if (filters.resolver != null) {
        try conditions.append(db.allocator, "resolver = ?");
    }
    if (filters.migrated) |m| {
        if (m) {
            try conditions.append(db.allocator, "migrated = 1");
        } else {
            try conditions.append(db.allocator, "migrated = 0");
        }
    }
    if (filters.has_subdomains) |has_subs| {
        if (has_subs) {
            try conditions.append(db.allocator, "(SELECT COUNT(*) FROM names AS sub WHERE sub.parent_name = names.name AND sub.is_reachable = 1) > 0");
        } else {
            try conditions.append(db.allocator, "(SELECT COUNT(*) FROM names AS sub WHERE sub.parent_name = names.name AND sub.is_reachable = 1) = 0");
        }
    }
    if (filters.subdomain_count_gt != null) {
        try conditions.append(db.allocator, "(SELECT COUNT(*) FROM names AS sub WHERE sub.parent_name = names.name AND sub.is_reachable = 1) > ?");
    }
    if (filters.subdomain_count_lt != null) {
        try conditions.append(db.allocator, "(SELECT COUNT(*) FROM names AS sub WHERE sub.parent_name = names.name AND sub.is_reachable = 1) < ?");
    }

    // Build SQL
    var where_clause: std.ArrayList(u8) = .{};
    defer where_clause.deinit(db.allocator);

    if (conditions.items.len > 0) {
        try where_clause.appendSlice(db.allocator, "WHERE ");
        for (conditions.items, 0..) |cond, i| {
            if (i > 0) try where_clause.appendSlice(db.allocator, " AND ");
            try where_clause.appendSlice(db.allocator, cond);
        }
        try where_clause.appendSlice(db.allocator, " ");
    }

    const sql = try std.fmt.allocPrint(db.allocator, "SELECT COUNT(*) FROM names {s}", .{where_clause.items});
    defer db.allocator.free(sql);

    var q = try Query.initCached(db, sql);
    defer q.deinit();

    // Bind parameters (same order as getFilteredNames)
    if (filters.owner) |o| {
        try q.bindAddress(o);
    }
    if (filters.owner_in) |owners| {
        for (owners) |o| {
            try q.bindAddress(o);
        }
    }
    if (filters.name) |n| {
        try q.bindText(n);
    }
    if (filters.name_in) |names| {
        for (names) |n| {
            try q.bindText(n);
        }
    }
    if (filters.name_contains) |n| {
        try q.bindText(n);
    }
    if (filters.name_contains_nocase) |n| {
        try q.bindText(n);
    }
    if (filters.name_starts_with) |n| {
        try q.bindText(n);
    }
    if (filters.name_ends_with) |n| {
        try q.bindText(n);
    }
    if (filters.expiry_gt) |v| {
        try q.bindInt64(v);
    }
    if (filters.expiry_gte) |v| {
        try q.bindInt64(v);
    }
    if (filters.expiry_lt) |v| {
        try q.bindInt64(v);
    }
    if (filters.expiry_lte) |v| {
        try q.bindInt64(v);
    }
    if (filters.resolved_address) |addr| {
        try q.bindAddress(addr);
    }
    if (filters.resolver) |addr| {
        try q.bindAddress(addr);
    }
    // has_subdomains doesn't need binding (no ?)
    if (filters.subdomain_count_gt) |v| {
        try q.bindInt64(v);
    }
    if (filters.subdomain_count_lt) |v| {
        try q.bindInt64(v);
    }

    if (try q.step()) {
        return @intCast(q.getInt64(0));
    }
    return 0;
}

// ============================================================================
// SUBDOMAIN OPERATIONS
// ============================================================================

/// Count direct subdomains of a name. Unreachable subdomains (orphaned by
/// a subregistry repoint) are excluded to match `getSubdomains` semantics.
pub fn countDirectSubdomains(db: *Database, parent_name: []const u8) !u32 {
    var q = try Query.init(db, "SELECT COUNT(*) FROM names WHERE is_reachable = 1 AND parent_name = ?");
    defer q.deinit();

    try q.bindText(parent_name);

    if (try q.step()) {
        return @intCast(q.getInt64(0));
    }
    return 0;
}

/// Check if a name has any direct subdomains (reachable only).
pub fn hasDirectSubdomains(db: *Database, parent_name: []const u8) !bool {
    var q = try Query.init(db, "SELECT 1 FROM names WHERE is_reachable = 1 AND parent_name = ? LIMIT 1");
    defer q.deinit();

    try q.bindText(parent_name);
    return try q.step();
}

/// Batch count direct subdomains for multiple parent names in a single query
/// Returns a hashmap mapping parent_name -> subdomain count
pub fn batchCountDirectSubdomains(db: *Database, allocator: std.mem.Allocator, parent_names: []const []const u8) !std.StringHashMap(u32) {
    var counts = std.StringHashMap(u32).init(allocator);
    errdefer {
        var it = counts.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        counts.deinit();
    }

    if (parent_names.len == 0) {
        return counts;
    }

    // Build dynamic SQL: SELECT parent_name, COUNT(*) FROM names WHERE parent_name IN (?, ?, ...) GROUP BY parent_name
    var sql_buf: std.ArrayList(u8) = .{};
    defer sql_buf.deinit(allocator);

    try sql_buf.appendSlice(allocator, "SELECT parent_name, COUNT(*) FROM names WHERE is_reachable = 1 AND parent_name IN (");
    for (parent_names, 0..) |_, i| {
        if (i > 0) try sql_buf.appendSlice(allocator, ", ");
        try sql_buf.appendSlice(allocator, "?");
    }
    try sql_buf.appendSlice(allocator, ") GROUP BY parent_name");

    const sql_z = try allocator.dupeZ(u8, sql_buf.items);
    defer allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) {
        return counts; // Return empty map on error
    }
    defer _ = c.sqlite3_finalize(stmt);

    // Bind all parent names
    for (parent_names, 0..) |name, i| {
        _ = c.sqlite3_bind_text(stmt, @intCast(i + 1), name.ptr, @intCast(name.len), null);
    }

    // Execute and collect results
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const parent_text = c.sqlite3_column_text(stmt, 0);
        const parent_len = c.sqlite3_column_bytes(stmt, 0);
        const count = c.sqlite3_column_int(stmt, 1);

        if (parent_text != null and parent_len > 0) {
            const parent_slice = parent_text[0..@intCast(parent_len)];
            const key = try allocator.dupe(u8, parent_slice);
            try counts.put(key, @intCast(count));
        }
    }

    return counts;
}

/// Get direct subdomains of a name with pagination. Unreachable rows
/// (orphans of a subregistry repoint) are filtered out — callers that
/// need them must query `getFilteredNames` with `include_unreachable`.
pub fn getSubdomains(db: *Database, parent_name_arg: []const u8, skip: u32, limit: u32) ![]models.Name {
    var q = try Query.init(db, SQL_SELECT_NAMES_SHORT ++ " WHERE is_reachable = 1 AND parent_name = ? ORDER BY name LIMIT ? OFFSET ?");
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
