/// Names storage module - refactored to use Query abstraction
/// This module handles all name-related database operations
const std = @import("std");
const testing = std.testing;
const db_module = @import("database.zig");
const reorg_undo = @import("reorg_undo.zig");
const Database = db_module.Database;
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
    \\       is_reachable, unreachable_since, ttl, is_legacy, resolved_address, is_normalized
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
// REGISTRY OPERATIONS
// ============================================================================

pub fn insertRegistry(db: *Database, registry: models.Registry) !void {
    // Use INSERT OR IGNORE to keep the FIRST SubregistryUpdate (when subregistry was established)
    // not later ones. This ensures created_block reflects when the parent->subregistry mapping
    // was first created, which is needed for correct temporal parent lookups.
    const sql = try db.upsertSql(db.allocator, "registries", &.{ "address", "protocol", "name", "namehash", "parent_registry", "created_block", "created_at" }, .ignore);
    defer db.allocator.free(sql);

    var q = try Query.init(db, sql);
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
    try reorg_undo.captureWhere(db, "registries", "U", "name = ?", .{placeholder_name});
    var reg_q = try Query.init(db, "UPDATE registries SET name = ?, namehash = ? WHERE name = ?");
    defer reg_q.deinit();
    try reg_q.bindText(actual_name);
    try reg_q.bindHash(namehash);
    try reg_q.bindText(placeholder_name);
    try reg_q.exec();
    const registry_changes = reg_q.changes();

    try reorg_undo.captureWhere(db, "names", "U", "parent_name = ?", .{placeholder_name});
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

/// Look up a single registry contract by its address. Returns the most-recently
/// created row when the same contract is referenced from multiple `created_block`
/// entries (which can happen on V2 since `INSERT OR IGNORE` keeps the first
/// SubregistryUpdate per registry but the table is keyed by
/// `UNIQUE(protocol, address, namehash)`).
pub fn getRegistry(db: *Database, protocol: models.Protocol, address: Address) !?models.Registry {
    var q = try Query.init(db,
        \\SELECT r.address, r.protocol, r.name, r.namehash, r.parent_registry, r.created_block, r.created_at
        \\FROM registries r
        \\WHERE r.protocol = ? AND r.address = ?
        \\ORDER BY r.created_block DESC
        \\LIMIT 1
    );
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(address);

    if (!try q.step()) return null;

    const address_str = q.getTextSlice(0) orelse return null;
    const protocol_str = q.getTextSlice(1) orelse return null;
    const name_str = q.getTextSlice(2) orelse "";
    const namehash_str = q.getTextSlice(3) orelse return null;
    const parent_str = q.getTextSlice(4) orelse return null;

    return .{
        .address = try Address.fromHex(address_str),
        .protocol = try models.Protocol.fromString(protocol_str),
        .name = try db.allocator.dupe(u8, name_str),
        .namehash = try Hash.fromHex(namehash_str),
        .parent_registry = try Address.fromHex(parent_str),
        .created_block = @intCast(q.getInt64(5)),
        .created_at = q.getInt64(6),
    };
}

// ============================================================================
// NAME INSERT/UPDATE OPERATIONS
// ============================================================================

pub fn insertName(db: *Database, name: models.Name) !void {
    try reorg_undo.captureUpsert(db, "names", .{ name.protocol, name.namehash });
    var q = try Query.initCached(db,
        \\INSERT INTO names
        \\(namehash, name, label, label_hash, parent_name, parent_namehash, protocol,
        \\ registry, owner, registrant, resolver, token_id, canonical_id, token_version, expiry,
        \\ registry_locked, migrated, created_block, created_at, registered_at, updated_block, updated_at,
        \\ is_wrapped, wrapper_fuses, wrapper_expiry, is_v1_name, v1_label_hash,
        \\ is_reachable, unreachable_since, ttl, is_legacy, resolved_address, is_normalized)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
        \\ unreachable_since = excluded.unreachable_since,
        \\ ttl = excluded.ttl,
        \\ is_legacy = excluded.is_legacy,
        \\ resolved_address = COALESCE(excluded.resolved_address, names.resolved_address),
        \\ is_normalized = excluded.is_normalized
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
    try q.bindOptionalInt64(if (name.ttl) |t| @intCast(t) else null);
    try q.bindInt(if (name.is_legacy) 1 else 0);
    if (name.resolved_address) |addr| {
        var resolved_buf: [42]u8 = undefined;
        const resolved_hex = addr.toHexBuf(&resolved_buf);
        try q.bindText(resolved_hex);
    } else {
        try q.bindNull();
    }
    try q.bindInt(if (name.is_normalized) 1 else 0);
    try q.exec();
}

/// Update the `is_legacy` flag on an existing name row. Called by V1 Registry
/// handlers to track whether the most recent update came from the legacy
/// pre-2020 Registry (0x314159…) or the canonical post-2020 Registry.
/// No-op when no row exists for `namehash`.
pub fn updateNameIsLegacy(db: *Database, namehash: Hash, is_legacy: bool) !void {
    try reorg_undo.captureWhere(db, "names", "U", "namehash = ?", .{namehash});
    var q = try Query.initCached(db, "UPDATE names SET is_legacy = ?, updated_at = ? WHERE namehash = ?");
    defer q.deinit();
    try q.bindInt(if (is_legacy) 1 else 0);
    try q.bindInt64(std.time.timestamp());
    try q.bindHashBuf(namehash);
    try q.exec();
}

/// Update name expiry (for renewals)
pub fn updateNameExpiry(db: *Database, namehash: Hash, expiry: u64) !void {
    try reorg_undo.captureWhere(db, "names", "U", "namehash = ?", .{namehash});
    var q = try Query.initCached(db, "UPDATE names SET expiry = ?, updated_at = ? WHERE namehash = ?");
    defer q.deinit();

    try q.bindInt64(safeU64ToI64(expiry));
    try q.bindInt64(std.time.timestamp());
    try q.bindHashBuf(namehash);
    try q.exec();
}

/// Expiry update for BaseRegistrar NameRenewed (V1 .eth 2LDs only). Wrapped rows
/// store the grace-inclusive wrapper value (registrar expires + 90d); writing the
/// bare registrar value there would silently shrink expiryDate by the grace period
/// on direct registrar renewals, where no ExpiryExtended fires to re-sync it.
/// The `> 0` guard preserves the safeU64ToI64 never-expires sentinel (0) — grace
/// must not turn it into a 1970 expiry. The protocol predicate keeps a
/// same-namehash V2 row from being stomped (names is UNIQUE(protocol, namehash)).
pub fn updateV1RenewalExpiry(db: *Database, namehash: Hash, expires: u64) !void {
    try reorg_undo.captureWhere(db, "names", "U", "namehash = ? AND protocol = 'v1'", .{namehash});
    var q = try Query.initCached(db, "UPDATE names SET expiry = CASE WHEN is_wrapped = 1 AND ? > 0 THEN ? + 7776000 ELSE ? END, updated_at = ? WHERE namehash = ? AND protocol = 'v1'");
    defer q.deinit();

    // Within 90d of i64 max the grace addition would overflow (PG errors,
    // SQLite degrades to REAL); such a value means never-expires in practice.
    const v = safeU64ToI64(expires);
    const base = if (v > std.math.maxInt(i64) - 7776000) 0 else v;
    try q.bindInt64(base);
    try q.bindInt64(base);
    try q.bindInt64(base);
    try q.bindInt64(std.time.timestamp());
    try q.bindHashBuf(namehash);
    try q.exec();
}

/// Update name owner (for transfers)
pub fn updateNameOwner(db: *Database, namehash: Hash, new_owner: Address) !void {
    try reorg_undo.captureWhere(db, "names", "U", "namehash = ?", .{namehash});
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
    try reorg_undo.captureWhere(db, "names", "U", "namehash = ?", .{namehash});
    var q = try Query.initCached(db, "UPDATE names SET owner = ?, migrated = 1, updated_at = ? WHERE namehash = ?");
    defer q.deinit();

    try q.bindAddressBuf(controller);
    try q.bindInt64(std.time.timestamp());
    try q.bindHashBuf(namehash);
    try q.exec();
}

/// Update name resolver
pub fn updateNameResolver(db: *Database, namehash: Hash, resolver: Address) !void {
    try reorg_undo.captureWhere(db, "names", "U", "namehash = ?", .{namehash});
    var q = try Query.initCached(db, "UPDATE names SET resolver = ?, updated_at = ? WHERE namehash = ?");
    defer q.deinit();

    try q.bindAddressBuf(resolver);
    try q.bindInt64(std.time.timestamp());
    try q.bindHashBuf(namehash);
    try q.exec();
}

/// Clear `names.resolved_address` (set to NULL). Called when V1 NewResolver
/// either points at the zero resolver or the `addr(node)` call returns zero
/// — both indicate "no resolution available right now". No-op if the row
/// doesn't exist.
pub fn updateResolvedAddressToNull(db: *Database, namehash: Hash) !void {
    try reorg_undo.captureWhere(db, "names", "U", "namehash = ?", .{namehash});
    var q = try Query.initCached(db, "UPDATE names SET resolved_address = NULL, updated_at = ? WHERE namehash = ?");
    defer q.deinit();

    try q.bindInt64(std.time.timestamp());
    try q.bindHashBuf(namehash);
    try q.exec();
}

/// Update TTL for a name (V1 ENS Registry NewTTL event).
/// No-op if no row exists with this namehash — consistent with NewResolver:
/// V1 NewTTL on a non-existent name has nothing to attach to.
pub fn updateNameTTL(db: *Database, namehash: Hash, ttl: u64) !void {
    try reorg_undo.captureWhere(db, "names", "U", "namehash = ?", .{namehash});
    var q = try Query.initCached(db, "UPDATE names SET ttl = ?, updated_at = ? WHERE namehash = ?");
    defer q.deinit();

    try q.bindInt64(@intCast(ttl));
    try q.bindInt64(std.time.timestamp());
    try q.bindHashBuf(namehash);
    try q.exec();
}

/// Delete a name by its namehash (registry-safe: only deletes the exact name)
pub fn deleteNameByNamehash(db: *Database, namehash: Hash) !void {
    try reorg_undo.captureActiveWhere(db, "unknown_labels", "D", "name_id IN (SELECT id FROM names WHERE namehash = ?)", .{namehash});
    try reorg_undo.captureWhere(db, "names", "D", "namehash = ?", .{namehash});
    var q = try Query.initCached(db, "DELETE FROM names WHERE namehash = ?");
    defer q.deinit();

    try q.bindHashBuf(namehash);
    try q.exec();
}

/// Recursively delete a domain and walk up parent chain GCing empty parents.
/// Mirrors subgraph's `recursivelyRemoveEmptyDomainFromParentSubdomainCount`.
/// A "fully-burned" name (owner=0, resolver=0, no live subdomains, no expiry)
/// is deleted and the parent re-checked. Stops at the root or at the first
/// parent that's not fully burned. Returns the total number of rows deleted.
///
/// V1-only: V2 hard-deletes on burn (LabelUnregistered cascade), so this
/// reconciliation is only meaningful for V1 ENS Registry `NewOwner`/`Transfer`
/// events that set `owner = 0x0`. The walker is iterative (stack-driven) to
/// avoid recursion in Zig and to keep the parent chain check explicit.
pub fn recursivelyGcEmptyDomain(db: *Database, namehash: Hash) !u32 {
    var deleted: u32 = 0;
    var current = namehash;

    // Cap the walk to defend against pathological parent chains (data
    // corruption or self-referential rows); ENS depth in practice is small.
    var safety: u32 = 0;
    const SAFETY_LIMIT: u32 = 256;

    while (safety < SAFETY_LIMIT) : (safety += 1) {
        // Root has parent_namehash=0; stop GC at the root.
        if (current.isZero()) break;

        // Fetch the row's owner/resolver/expiry/parent_namehash. We must read
        // the row before deciding to delete: the GC criteria require checking
        // owner=0 AND resolver=0 AND no children AND no expiry.
        var q = try Query.initCached(db,
            \\SELECT owner, resolver, expiry, parent_namehash FROM names WHERE namehash = ? LIMIT 1
        );
        defer q.deinit();
        try q.bindHashBuf(current);
        if (!try q.step()) break; // Row already gone, nothing to do.

        const owner_str = q.getTextSlice(0) orelse "";
        const resolver_str = q.getTextSlice(1) orelse "";
        const expiry = q.getOptionalInt64(2);
        const parent_str = q.getTextSlice(3) orelse "";

        const ZERO = "0x0000000000000000000000000000000000000000";
        const owner_zero = std.mem.eql(u8, owner_str, ZERO);
        const resolver_zero = std.mem.eql(u8, resolver_str, ZERO) or resolver_str.len == 0;
        const expiry_unset = (expiry == null) or (expiry.? == 0);
        if (!(owner_zero and resolver_zero and expiry_unset)) break;

        // Capture parent before we delete this row.
        const parent_hash = Hash.fromHex(parent_str) catch break;

        // Children check: stop if this row has any descendant pointing at it
        // via parent_namehash. NOT EXISTS is a single-row probe — cheap.
        var child_q = try Query.initCached(db,
            \\SELECT 1 FROM names WHERE parent_namehash = ? LIMIT 1
        );
        defer child_q.deinit();
        try child_q.bindHashBuf(current);
        const has_child = try child_q.step();
        if (has_child) break;

        // All gates passed — delete this row and walk up to parent.
        try deleteNameByNamehash(db, current);
        deleted += 1;
        current = parent_hash;
    }

    return deleted;
}

/// Update token_id for a specific name by namehash (registry-safe: only updates the exact name).
/// Only updates token_id and token_version — canonical_id is unchanged across regeneration.
pub fn updateNameTokenIdByNamehash(db: *Database, namehash: Hash, new_token_id: u256) !void {
    const token_id_utils = @import("../types/token_id.zig");
    const token_version = token_id_utils.getTokenVersion(new_token_id);

    try reorg_undo.captureWhere(db, "names", "U", "namehash = ?", .{namehash});
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
    try reorg_undo.captureWhere(db, "names", "U", "namehash = ?", .{namehash});
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

/// Clear `names.expiry` (set to NULL) for a namehash. Used on NameUnwrapped
/// for subnames whose parent is NOT the .eth registrar: subgraph
/// (`NameWrapper.ts:250-259`) resets domain.expiryDate to null on unwrap
/// unless the parent is the .eth registrar (in which case the registration's
/// expiry remains canonical).
pub fn clearNameExpiry(db: *Database, namehash: Hash) !void {
    try reorg_undo.captureWhere(db, "names", "U", "namehash = ?", .{namehash});
    var q = try Query.initCached(db,
        \\UPDATE names SET expiry = NULL, updated_at = ? WHERE namehash = ?
    );
    defer q.deinit();

    try q.bindInt64(std.time.timestamp());
    try q.bindHashBuf(namehash);
    try q.exec();
}

/// Clear wrapper state for a name (unwrap)
pub fn updateNameUnwrapperState(db: *Database, namehash: Hash) !void {
    try reorg_undo.captureWhere(db, "names", "U", "namehash = ?", .{namehash});
    // Re-base .eth 2LD expiry to the bare registrar value on unwrap: while
    // wrapped, names.expiry may hold the grace-inclusive wrapper value (PCC
    // mirror / updateV1RenewalExpiry). The unwrapped read path re-adds the 90d
    // grace, so leaving the inflated value would over-report expiryDate by
    // 180d. registrations stores the bare expires (subgraph Registration
    // parity); rows without one (temp-registrar era) keep their value.
    var q = try Query.initCached(db,
        \\UPDATE names SET is_wrapped = 0, wrapper_fuses = NULL, wrapper_expiry = NULL,
        \\expiry = CASE WHEN protocol = 'v1' AND parent_name = 'eth'
        \\  THEN COALESCE((SELECT MAX(r.expiry) FROM registrations r WHERE r.protocol = names.protocol AND r.namehash = names.namehash), expiry)
        \\  ELSE expiry END,
        \\updated_at = ? WHERE namehash = ?
    );
    defer q.deinit();

    try q.bindInt64(std.time.timestamp());
    try q.bindHash(namehash);
    try q.exec();
}

/// Update wrapper fuses only
pub fn updateNameWrapperFuses(db: *Database, namehash: Hash, fuses: u32) !void {
    try reorg_undo.captureWhere(db, "names", "U", "namehash = ?", .{namehash});
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
    try reorg_undo.captureWhere(db, "names", "U", "namehash = ?", .{namehash});
    var q = try Query.initCached(db,
        \\UPDATE names SET wrapper_expiry = ?, updated_at = ? WHERE namehash = ?
    );
    defer q.deinit();

    try q.bindInt64(safeU64ToI64(expiry));
    try q.bindInt64(std.time.timestamp());
    try q.bindHash(namehash);
    try q.exec();
}

/// PCC-aware Domain expiry mirror. Subgraph parity: when the wrapped name's
/// PARENT_CANNOT_CONTROL fuse is burned, the wrapper expiry IS the canonical
/// Domain expiry — mirror it (max with existing) so `Domain.expiryDate` returns
/// the wrapper-extended date rather than the registration's base expiry (or null
/// for wrapped subdomains that never had a base registrar expiry).
///
/// SQL `MAX(COALESCE(existing, 0), new)` handles NULL existing rows cleanly —
/// no row in `names` for this namehash → UPDATE affects zero rows (no-op).
/// That edge case is fine: `NameWrapped` on a name we never saw via Registry
/// will simply skip the mirror until the Registry row materializes.
pub fn updateDomainExpiryIfGreater(db: *Database, namehash: Hash, new_expiry: i64) !void {
    try reorg_undo.captureWhere(db, "names", "U", "namehash = ?", .{namehash});
    const sql = try std.fmt.allocPrint(db.allocator,
        \\UPDATE names
        \\SET expiry = {s}(COALESCE(expiry, 0), ?),
        \\    updated_at = ?
        \\WHERE namehash = ?
    , .{db.dialect().scalar_max}); // MAX (SQLite) / GREATEST (Postgres); args non-null via COALESCE
    defer db.allocator.free(sql);
    var q = try Query.initCached(db, sql);
    defer q.deinit();
    try q.bindInt64(new_expiry);
    try q.bindInt64(std.time.timestamp());
    try q.bindHashBuf(namehash);
    try q.exec();
}

/// Bulk-materialize the PCC (PARENT_CANNOT_CONTROL = 0x10000) fuse → Domain.expiry
/// mirror for every wrapped name. Idempotent: only updates rows where the wrapper
/// expiry would actually advance Domain.expiry, and only where the PCC fuse is set.
///
/// Why this exists separately from the per-event mirror in handlers:
/// - During initial bulk sync the write_buffer is active. The per-event mirror in
///   handleV1NameWrapped/FusesSet/ExpiryExtended needs to READ existing rows to
///   determine PCC state, which the write_buffer cannot service. The per-event
///   mirror is therefore skipped while buffered.
/// - After bulk sync flushes, this function runs once to materialize the mirror
///   in one bulk UPDATE. For incremental sync after bulk, the per-event mirror
///   handles updates directly (write_buffer is inactive).
///
/// SQL safety:
/// - `CAST(wrapper_fuses AS INTEGER)` returns 0 for null/non-numeric strings, so
///   the AND check naturally short-circuits. Combined with the explicit IS NOT
///   NULL guards, this avoids touching unrelated rows.
/// - `wrapper_expiry > COALESCE(expiry, 0)` ensures we never lower Domain.expiry.
/// Returns the number of rows updated.
pub fn materializePccDomainExpiry(db: *Database) !u32 {
    const PARENT_CANNOT_CONTROL: i64 = 0x10000;
    try reorg_undo.captureWhere(db, "names", "U", "is_wrapped = 1 AND wrapper_expiry IS NOT NULL AND wrapper_fuses IS NOT NULL AND wrapper_fuses != '' AND (CAST(wrapper_fuses AS INTEGER) & ?) != 0 AND wrapper_expiry > COALESCE(expiry, 0)", .{PARENT_CANNOT_CONTROL});
    var q = try Query.init(db,
        \\UPDATE names
        \\SET expiry = wrapper_expiry,
        \\    updated_at = ?
        \\WHERE is_wrapped = 1
        \\  AND wrapper_expiry IS NOT NULL
        \\  AND wrapper_fuses IS NOT NULL
        \\  AND wrapper_fuses != ''
        \\  AND (CAST(wrapper_fuses AS INTEGER) & ?) != 0
        \\  AND wrapper_expiry > COALESCE(expiry, 0)
    );
    defer q.deinit();
    try q.bindInt64(std.time.timestamp());
    try q.bindInt64(PARENT_CANNOT_CONTROL);
    try q.exec();
    return q.changes();
}

/// Update label and name fields for a name record (used by label healing).
/// `is_normalized` is recomputed by the caller (indexer layer, which has the
/// ENSIP-15 lib) now that the plaintext label/name is known.
pub fn updateNameLabel(database: *Database, namehash: Hash, label: []const u8, name: []const u8, is_normalized: bool) !void {
    try reorg_undo.captureWhere(database, "names", "U", "namehash = ?", .{namehash});
    var q = try Query.initCached(database,
        \\UPDATE names SET label = ?, name = ?, is_normalized = ?
        \\WHERE namehash = ?
    );
    defer q.deinit();

    try q.bindText(label);
    try q.bindText(name);
    try q.bindInt(if (is_normalized) 1 else 0);
    try q.bindHash(namehash);
    try q.exec();
}

/// Update creation date if the new block is earlier (for backfill scenarios)
pub fn updateNameCreationDateIfEarlier(db: *Database, namehash: Hash, block_number: u64, created_at: i64) !void {
    try reorg_undo.captureWhere(db, "names", "U", "namehash = ? AND created_block > ?", .{ namehash, block_number });
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
    /// Grace-inclusive expiry (Domain.expiryDate ordering) — must agree with
    /// the expiry_date_* filter CASE and effectiveDomainExpiry, otherwise sort
    /// order and displayed values diverge by up to 90d in mixed result sets.
    expiry_effective,
    registered_at,

    pub fn toSql(self: NameSortField) []const u8 {
        return self.toSqlQualified("");
    }

    pub fn toSqlQualified(self: NameSortField, comptime alias: []const u8) []const u8 {
        return switch (self) {
            .created_at => alias ++ "created_at",
            .name => alias ++ "name",
            .expiry => alias ++ "expiry",
            .expiry_effective => "CASE WHEN " ++ alias ++ "protocol = 'v1' AND " ++ alias ++ "parent_name = 'eth' AND " ++ alias ++ "is_wrapped = 0 AND " ++ alias ++ "expiry > 0 AND " ++ alias ++ "expiry <= 9223372036846999807 THEN " ++ alias ++ "expiry + 7776000 ELSE " ++ alias ++ "expiry END",
            .registered_at => alias ++ "registered_at",
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
        // Hide the synthetic root domain (namehash 0x000…000, name="") from
        // default GraphQL queries. The row is materialized by `Database.migrate`
        // so internal graph traversal terminates cleanly at the root, but it's
        // noise for client-facing listings (`createdAt = 0`, blank `name`).
        // Audit/debug callers that pass `includeUnreachable: true` also opt
        // back into seeing it.
        try conditions.append(db.allocator, "namehash != '0x0000000000000000000000000000000000000000000000000000000000000000'");
    }
    // ENSIP-15 enforcement (mirrors is_reachable): an explicit `isNormalized` filter
    // wins; otherwise non-normalized names are hidden unless `includeUnnormalized` is set.
    if (filters.is_normalized) |want| {
        try conditions.append(db.allocator, if (want) "is_normalized = 1" else "is_normalized = 0");
    } else if (!filters.include_unnormalized) {
        try conditions.append(db.allocator, "is_normalized = 1");
    }
    // User predicate tree (this node's scalars + recursive and/or). Default
    // visibility above applies to the whole result set and is NOT injected into
    // nested and/or nodes.
    if (try buildNameNodeExpr(db, filters, allocated_strings)) |expr| {
        try conditions.append(db.allocator, expr);
    }
}

/// One filter node's scalar predicates (no default visibility, no and/or).
fn appendNameScalarConditions(
    db: *Database,
    filters: NameFilters,
    conditions: *std.ArrayList([]const u8),
    allocated_strings: *std.ArrayList([]const u8),
) !void {
    if (filters.owner != null) {
        try conditions.append(db.allocator, "owner = ?");
    }
    if (filters.owner_not != null) {
        try conditions.append(db.allocator, "owner != ?");
    }
    if (filters.owner_in) |owners| {
        if (owners.len > 0) {
            const clause = try db_module.query.buildInClause(db.allocator, "owner", "IN", owners.len);
            try allocated_strings.append(db.allocator, clause);
            try conditions.append(db.allocator, clause);
        }
    }
    if (filters.owner_not_in) |owners| {
        if (owners.len > 0) {
            const clause = try db_module.query.buildInClause(db.allocator, "owner", "NOT IN", owners.len);
            try allocated_strings.append(db.allocator, clause);
            try conditions.append(db.allocator, clause);
        }
    }
    if (filters.name != null) try conditions.append(db.allocator, "name = ?");
    if (filters.name_not != null) try conditions.append(db.allocator, "name != ?");
    if (filters.name_in) |names| {
        if (names.len == 0) {
            try conditions.append(db.allocator, "1=0");
        } else {
            const clause = try db_module.query.buildInClause(db.allocator, "name", "IN", names.len);
            try allocated_strings.append(db.allocator, clause);
            try conditions.append(db.allocator, clause);
        }
    }
    if (filters.name_not_in) |names| {
        if (names.len > 0) {
            const clause = try db_module.query.buildInClause(db.allocator, "name", "NOT IN", names.len);
            try allocated_strings.append(db.allocator, clause);
            try conditions.append(db.allocator, clause);
        }
    }
    if (filters.name_contains != null) try conditions.append(db.allocator, "name LIKE '%' || ? || '%'");
    if (filters.name_contains_nocase != null) try conditions.append(db.allocator, "LOWER(name) LIKE '%' || LOWER(?) || '%'");
    if (filters.name_not_contains != null) try conditions.append(db.allocator, "name NOT LIKE '%' || ? || '%'");
    if (filters.name_starts_with != null) try conditions.append(db.allocator, "name LIKE ? || '%'");
    if (filters.name_starts_with_nocase != null) try conditions.append(db.allocator, "LOWER(name) LIKE LOWER(?) || '%'");
    if (filters.name_ends_with != null) try conditions.append(db.allocator, "name LIKE '%' || ?");
    if (filters.name_ends_with_nocase != null) try conditions.append(db.allocator, "LOWER(name) LIKE '%' || LOWER(?)");
    if (filters.label_name != null) try conditions.append(db.allocator, "label = ?");
    if (filters.label_name_not != null) try conditions.append(db.allocator, "label != ?");
    if (filters.label_name_in) |labels| {
        if (labels.len == 0) {
            try conditions.append(db.allocator, "1=0");
        } else {
            const clause = try db_module.query.buildInClause(db.allocator, "label", "IN", labels.len);
            try allocated_strings.append(db.allocator, clause);
            try conditions.append(db.allocator, clause);
        }
    }
    if (filters.label_name_not_in) |labels| {
        if (labels.len > 0) {
            const clause = try db_module.query.buildInClause(db.allocator, "label", "NOT IN", labels.len);
            try allocated_strings.append(db.allocator, clause);
            try conditions.append(db.allocator, clause);
        }
    }
    if (filters.label_name_contains != null) try conditions.append(db.allocator, "label LIKE '%' || ? || '%'");
    if (filters.label_name_contains_nocase != null) try conditions.append(db.allocator, "LOWER(label) LIKE '%' || LOWER(?) || '%'");
    if (filters.label_name_not_contains != null) try conditions.append(db.allocator, "label NOT LIKE '%' || ? || '%'");
    if (filters.label_name_starts_with != null) try conditions.append(db.allocator, "label LIKE ? || '%'");
    if (filters.label_name_starts_with_nocase != null) try conditions.append(db.allocator, "LOWER(label) LIKE LOWER(?) || '%'");
    if (filters.label_name_ends_with != null) try conditions.append(db.allocator, "label LIKE '%' || ?");
    if (filters.label_name_ends_with_nocase != null) try conditions.append(db.allocator, "LOWER(label) LIKE '%' || LOWER(?)");
    if (filters.expiry_gt != null) try conditions.append(db.allocator, "expiry > ?");
    if (filters.expiry_gte != null) try conditions.append(db.allocator, "expiry >= ?");
    if (filters.expiry_lt != null) try conditions.append(db.allocator, "expiry < ?");
    if (filters.expiry_lte != null) try conditions.append(db.allocator, "expiry <= ?");
    // Grace-aware variants backing the subgraph `expiryDate_*` filters: the
    // compared value mirrors effectiveDomainExpiry (ens_fields.zig) — bare
    // stored expiry plus 90d (7776000s) for unwrapped V1 .eth 2LDs only.
    // The maxInt(i64)-7776000 bound keeps one near-max row from overflowing
    // the addition as BIGINT on PG (whole query errors; SQLite degrades to REAL).
    if (filters.expiry_date_gt != null) try conditions.append(db.allocator, "CASE WHEN protocol = 'v1' AND parent_name = 'eth' AND is_wrapped = 0 AND expiry > 0 AND expiry <= 9223372036846999807 THEN expiry + 7776000 ELSE expiry END > ?");
    if (filters.expiry_date_gte != null) try conditions.append(db.allocator, "CASE WHEN protocol = 'v1' AND parent_name = 'eth' AND is_wrapped = 0 AND expiry > 0 AND expiry <= 9223372036846999807 THEN expiry + 7776000 ELSE expiry END >= ?");
    if (filters.expiry_date_lt != null) try conditions.append(db.allocator, "CASE WHEN protocol = 'v1' AND parent_name = 'eth' AND is_wrapped = 0 AND expiry > 0 AND expiry <= 9223372036846999807 THEN expiry + 7776000 ELSE expiry END < ?");
    if (filters.expiry_date_lte != null) try conditions.append(db.allocator, "CASE WHEN protocol = 'v1' AND parent_name = 'eth' AND is_wrapped = 0 AND expiry > 0 AND expiry <= 9223372036846999807 THEN expiry + 7776000 ELSE expiry END <= ?");
    if (filters.resolved_address != null) {
        try conditions.append(db.allocator, "namehash IN (SELECT namehash FROM resolver_addresses WHERE address = ?)");
    }
    if (filters.resolver != null) try conditions.append(db.allocator, "resolver = ?");
    if (filters.registry != null) try conditions.append(db.allocator, "registry = ?");
    if (filters.migrated) |m| {
        try conditions.append(db.allocator, if (m) "migrated = 1" else "migrated = 0");
    }
    if (filters.has_subdomains) |has_subs| {
        try conditions.append(db.allocator, if (has_subs)
            "(SELECT COUNT(*) FROM names AS sub WHERE sub.parent_name = names.name AND sub.is_reachable = 1 AND is_normalized = 1 AND sub.namehash != '0x0000000000000000000000000000000000000000000000000000000000000000') > 0"
        else
            "(SELECT COUNT(*) FROM names AS sub WHERE sub.parent_name = names.name AND sub.is_reachable = 1 AND is_normalized = 1 AND sub.namehash != '0x0000000000000000000000000000000000000000000000000000000000000000') = 0");
    }
    if (filters.subdomain_count_gt != null) {
        try conditions.append(db.allocator, "(SELECT COUNT(*) FROM names AS sub WHERE sub.parent_name = names.name AND sub.is_reachable = 1 AND is_normalized = 1 AND sub.namehash != '0x0000000000000000000000000000000000000000000000000000000000000000') > ?");
    }
    if (filters.subdomain_count_lt != null) {
        try conditions.append(db.allocator, "(SELECT COUNT(*) FROM names AS sub WHERE sub.parent_name = names.name AND sub.is_reachable = 1 AND is_normalized = 1 AND sub.namehash != '0x0000000000000000000000000000000000000000000000000000000000000000') < ?");
    }
}

/// Recursively build one filter node's boolean SQL:
///   (scalar AND scalar AND <and-child> AND (<or-child> OR <or-child>))
/// Returns null when the node has no predicates. Allocated fragments are tracked in
/// `allocated_strings` for the caller to free.
fn buildNameNodeExpr(
    db: *Database,
    filters: NameFilters,
    allocated_strings: *std.ArrayList([]const u8),
) anyerror!?[]const u8 {
    var parts: std.ArrayList([]const u8) = .{};
    defer parts.deinit(db.allocator);

    try appendNameScalarConditions(db, filters, &parts, allocated_strings);

    if (filters.and_group) |children| {
        for (children) |child| {
            if (try buildNameNodeExpr(db, child, allocated_strings)) |sub| {
                try parts.append(db.allocator, sub);
            }
        }
    }
    if (filters.or_group) |children| {
        var or_parts: std.ArrayList([]const u8) = .{};
        defer or_parts.deinit(db.allocator);
        for (children) |child| {
            if (try buildNameNodeExpr(db, child, allocated_strings)) |sub| {
                try or_parts.append(db.allocator, sub);
            }
        }
        if (or_parts.items.len > 0) {
            const joined = try db_module.query.joinWrapped(db.allocator, or_parts.items, " OR ");
            try allocated_strings.append(db.allocator, joined);
            try parts.append(db.allocator, joined);
        }
    }

    if (parts.items.len == 0) return null;
    if (parts.items.len == 1) return parts.items[0];
    const joined = try db_module.query.joinWrapped(db.allocator, parts.items, " AND ");
    try allocated_strings.append(db.allocator, joined);
    return joined;
}

/// Bind values for `NameFilters` in the same order the SQL is built: this node's
/// scalars, then `and` children, then `or` children.
fn bindNameFilters(q: *Query, filters: NameFilters) anyerror!void {
    try bindNameScalars(q, filters);
    if (filters.and_group) |children| {
        for (children) |child| try bindNameFilters(q, child);
    }
    if (filters.or_group) |children| {
        for (children) |child| try bindNameFilters(q, child);
    }
}

/// Bind one node's scalar values in the same order `appendNameScalarConditions` appends.
fn bindNameScalars(q: *Query, filters: NameFilters) !void {
    if (filters.owner) |o| try q.bindAddress(o);
    if (filters.owner_not) |o| try q.bindAddress(o);
    if (filters.owner_in) |owners| {
        for (owners) |o| try q.bindAddress(o);
    }
    if (filters.owner_not_in) |owners| {
        for (owners) |o| try q.bindAddress(o);
    }
    if (filters.name) |n| try q.bindText(n);
    if (filters.name_not) |n| try q.bindText(n);
    if (filters.name_in) |names| {
        for (names) |n| try q.bindText(n);
    }
    if (filters.name_not_in) |names| {
        for (names) |n| try q.bindText(n);
    }
    if (filters.name_contains) |n| try q.bindText(n);
    if (filters.name_contains_nocase) |n| try q.bindText(n);
    if (filters.name_not_contains) |n| try q.bindText(n);
    if (filters.name_starts_with) |n| try q.bindText(n);
    if (filters.name_starts_with_nocase) |n| try q.bindText(n);
    if (filters.name_ends_with) |n| try q.bindText(n);
    if (filters.name_ends_with_nocase) |n| try q.bindText(n);
    if (filters.label_name) |n| try q.bindText(n);
    if (filters.label_name_not) |n| try q.bindText(n);
    if (filters.label_name_in) |labels| {
        for (labels) |n| try q.bindText(n);
    }
    if (filters.label_name_not_in) |labels| {
        for (labels) |n| try q.bindText(n);
    }
    if (filters.label_name_contains) |n| try q.bindText(n);
    if (filters.label_name_contains_nocase) |n| try q.bindText(n);
    if (filters.label_name_not_contains) |n| try q.bindText(n);
    if (filters.label_name_starts_with) |n| try q.bindText(n);
    if (filters.label_name_starts_with_nocase) |n| try q.bindText(n);
    if (filters.label_name_ends_with) |n| try q.bindText(n);
    if (filters.label_name_ends_with_nocase) |n| try q.bindText(n);
    if (filters.expiry_gt) |v| try q.bindInt64(v);
    if (filters.expiry_gte) |v| try q.bindInt64(v);
    if (filters.expiry_lt) |v| try q.bindInt64(v);
    if (filters.expiry_lte) |v| try q.bindInt64(v);
    if (filters.expiry_date_gt) |v| try q.bindInt64(v);
    if (filters.expiry_date_gte) |v| try q.bindInt64(v);
    if (filters.expiry_date_lt) |v| try q.bindInt64(v);
    if (filters.expiry_date_lte) |v| try q.bindInt64(v);
    if (filters.resolved_address) |addr| try q.bindAddress(addr);
    if (filters.resolver) |addr| try q.bindAddress(addr);
    if (filters.registry) |addr| try q.bindAddress(addr);
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
    const field_outer = sort_field.toSqlQualified("names.");
    const field_cursor = sort_field.toSqlQualified("c.");
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
        "SELECT COUNT(*) FROM names WHERE EXISTS (SELECT 1 FROM names c WHERE c.namehash = ? AND ({s} {s} {s} OR ({s} = {s} AND names.namehash {s} c.namehash))){s}",
        .{ field_outer, op, field_cursor, field_outer, field_cursor, op, filter_clause.items },
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
            .ttl = if (q.getOptionalInt64(23)) |t| @intCast(t) else null,
            .is_legacy = q.getBool(24),
            .is_normalized = q.getBool(25),
        });
    }

    return names.toOwnedSlice(allocator);
}

pub fn getAllNames(db: *Database, owner: ?Address, skip: u32, limit: u32) ![]models.Name {
    return getAllNamesWithOrder(db, owner, skip, limit, .desc, .created_at);
}

/// Filter options for querying names
pub const NameFilters = struct {
    // Grace-aware expiry comparisons (subgraph `expiryDate_*`; see the CASE in
    // the condition builder). Distinct from the bare `expiry_*` slots.
    expiry_date_gt: ?i64 = null,
    expiry_date_gte: ?i64 = null,
    expiry_date_lt: ?i64 = null,
    expiry_date_lte: ?i64 = null,
    // Owner filters
    owner: ?Address = null,
    owner_in: ?[]const Address = null,
    owner_not: ?Address = null,
    owner_not_in: ?[]const Address = null,
    // Name filters
    name: ?[]const u8 = null,
    name_in: ?[]const []const u8 = null,
    name_not: ?[]const u8 = null,
    name_not_in: ?[]const []const u8 = null,
    name_contains: ?[]const u8 = null,
    name_contains_nocase: ?[]const u8 = null,
    name_not_contains: ?[]const u8 = null,
    name_starts_with: ?[]const u8 = null,
    name_starts_with_nocase: ?[]const u8 = null,
    name_ends_with: ?[]const u8 = null,
    name_ends_with_nocase: ?[]const u8 = null,
    // Label (leftmost component) filters — map to the `label` column on names.
    label_name: ?[]const u8 = null,
    label_name_not: ?[]const u8 = null,
    label_name_in: ?[]const []const u8 = null,
    label_name_not_in: ?[]const []const u8 = null,
    label_name_contains: ?[]const u8 = null,
    label_name_contains_nocase: ?[]const u8 = null,
    label_name_not_contains: ?[]const u8 = null,
    label_name_starts_with: ?[]const u8 = null,
    label_name_starts_with_nocase: ?[]const u8 = null,
    label_name_ends_with: ?[]const u8 = null,
    label_name_ends_with_nocase: ?[]const u8 = null,
    // Expiry filters
    expiry_gt: ?i64 = null,
    expiry_gte: ?i64 = null,
    expiry_lt: ?i64 = null,
    expiry_lte: ?i64 = null,
    // Resolved address filter (requires resolver lookup)
    resolved_address: ?Address = null,
    // Resolver contract address filter
    resolver: ?Address = null,
    // Registry contract address filter (the contract that owns this name's label)
    registry: ?Address = null,
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
    /// When false (default), only `is_normalized = 1` rows are returned (ENSIP-15
    /// enforcement). Set true to include non-normalized names (e.g. `Nick.eth`).
    include_unnormalized: bool = false,
    /// Exact normalization filter: when set, returns only rows matching it (overrides
    /// the default-hide). Maps to GraphQL `isNormalized: Boolean`.
    is_normalized: ?bool = null,
    /// Subgraph-style boolean composition (GraphQL `and` / `or`). `and_group`: every
    /// sub-filter must match (AND); `or_group`: any sub-filter matches (OR). Both nest
    /// recursively. Default visibility (reachable/normalized/root) is applied once at the
    /// top level only — it is NOT injected into nested nodes.
    and_group: ?[]const NameFilters = null,
    or_group: ?[]const NameFilters = null,
};

/// Get names with filters pushed down to DB query
pub fn getFilteredNames(db: *Database, filters: NameFilters, skip: u32, limit: u32, order_dir: OrderDir, sort_field: NameSortField) ![]models.Name {
    const order_str = if (order_dir == .desc) "DESC" else "ASC";

    // Build WHERE conditions via the shared helper so all callers (getFilteredNames,
    // getFilteredNameCount, countRowsBeforeNamehash) stay in lockstep.
    var conditions: std.ArrayList([]const u8) = .{};
    defer conditions.deinit(db.allocator);
    var allocated_strings: std.ArrayList([]const u8) = .{};
    defer {
        for (allocated_strings.items) |s| db.allocator.free(s);
        allocated_strings.deinit(db.allocator);
    }
    try appendNameFilterConditions(db, filters, &conditions, &allocated_strings);

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
        \\       is_reachable, unreachable_since, ttl, is_legacy, is_normalized
        \\FROM names {s}ORDER BY {s} {s}, namehash {s} LIMIT ? OFFSET ?
    , .{ where_clause.items, sort_field.toSql(), order_str, order_str });
    defer db.allocator.free(sql);

    var q = try Query.initCached(db, sql);
    defer q.deinit();

    // Bind parameters via the shared helper (same order as appendNameFilterConditions).
    try bindNameFilters(&q, filters);
    try q.bindInt(@intCast(limit));
    try q.bindInt(@intCast(skip));

    return parseNameRows(&q, db.allocator);
}

/// Get all names with configurable order direction
pub fn getAllNamesWithOrder(db: *Database, owner: ?Address, skip: u32, limit: u32, order_dir: OrderDir, sort_field: NameSortField) ![]models.Name {
    const order_str = if (order_dir == .desc) "DESC" else "ASC";
    // Secondary sort on namehash (same direction) — see countRowsBeforeNamehash for why.
    // is_reachable = 1 filter is applied by default; unreachable rows are
    // hidden from the legacy unfiltered listing. Synthetic root domain
    // (namehash 0x000…0) is also excluded — see `appendNameFilterConditions`.
    // Use `getFilteredNames` with `include_unreachable = true` to override.
    const sql = if (owner != null)
        try std.fmt.allocPrint(db.allocator,
            \\SELECT name, namehash, label, label_hash, parent_name, parent_namehash, owner, resolver, registry, protocol,
            \\       token_id, canonical_id, token_version, expiry, registry_locked, migrated,
            \\       created_at, registered_at, created_block, updated_at, updated_block,
            \\       is_reachable, unreachable_since, ttl, is_legacy, is_normalized
            \\FROM names WHERE is_reachable = 1 AND is_normalized = 1 AND owner = ? AND namehash != '0x0000000000000000000000000000000000000000000000000000000000000000' ORDER BY {s} {s}, namehash {s} LIMIT ? OFFSET ?
        , .{ sort_field.toSql(), order_str, order_str })
    else
        try std.fmt.allocPrint(db.allocator,
            \\SELECT name, namehash, label, label_hash, parent_name, parent_namehash, owner, resolver, registry, protocol,
            \\       token_id, canonical_id, token_version, expiry, registry_locked, migrated,
            \\       created_at, registered_at, created_block, updated_at, updated_block,
            \\       is_reachable, unreachable_since, ttl, is_legacy, is_normalized
            \\FROM names WHERE is_reachable = 1 AND is_normalized = 1 AND namehash != '0x0000000000000000000000000000000000000000000000000000000000000000' ORDER BY {s} {s}, namehash {s} LIMIT ? OFFSET ?
        , .{ sort_field.toSql(), order_str, order_str });
    defer db.allocator.free(sql);

    var q = try Query.initCached(db, sql);
    defer q.deinit();

    if (owner) |o| {
        try q.bindAddress(o);
    }
    try q.bindInt(@intCast(limit));
    try q.bindInt(@intCast(skip));

    return parseNameRows(&q, db.allocator);
}

// ============================================================================
// AGGREGATION OPERATIONS
// ============================================================================

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
    try appendNameFilterConditions(db, filters, &conditions, &allocated_strings);

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

    try bindNameFilters(&q, filters);

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
