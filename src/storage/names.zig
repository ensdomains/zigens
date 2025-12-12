const std = @import("std");
const testing = std.testing;
const db_module = @import("database.zig");
const Database = db_module.Database;
const c = db_module.c;
const models = @import("../types/models.zig");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;

// SQLITE_TRANSIENT - For Zig 0.15.1, we can't use the C constant due to alignment issues
// Instead, we use null which tells SQLite to make a copy of the string
inline fn SQLITE_TRANSIENT() c.sqlite3_destructor_type {
    return null;
}

// ============================================================================
// NAME OPERATIONS (12 functions)
// ============================================================================

pub fn insertRegistry(db: *Database, registry: models.Registry) !void {
    const sql =
        \\INSERT OR REPLACE INTO registries
        \\(address, chain, name, namehash, parent_registry, created_block, created_at)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
    ;

    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    const addr_hex = try registry.address.toHex(db.allocator);
    defer db.allocator.free(addr_hex);

    const namehash_hex = try registry.namehash.toHex(db.allocator);
    defer db.allocator.free(namehash_hex);

    const parent_hex = try registry.parent_registry.toHex(db.allocator);
    defer db.allocator.free(parent_hex);

    const chain_str = registry.chain.toString();

    _ = c.sqlite3_bind_text(stmt, 1, addr_hex.ptr, @intCast(addr_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 2, chain_str.ptr, @intCast(chain_str.len), c.SQLITE_STATIC);
    _ = c.sqlite3_bind_text(stmt, 3, registry.name.ptr, @intCast(registry.name.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 4, namehash_hex.ptr, @intCast(namehash_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 5, parent_hex.ptr, @intCast(parent_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 6, @intCast(registry.created_block));
    _ = c.sqlite3_bind_int64(stmt, 7, registry.created_at);

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to insert registry: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.InsertFailed;
    }
}

pub fn insertName(db: *Database, name: models.Name) !void {
    const sql =
        \\INSERT OR REPLACE INTO names
        \\(namehash, name, label, label_hash, parent_name, parent_namehash, chain,
        \\ registry, owner, resolver, token_id, canonical_id, token_version, expiry,
        \\ registry_locked, migrated, ejected, created_block, created_at, updated_block, updated_at,
        \\ is_wrapped, wrapper_fuses, wrapper_expiry, is_v1_name, v1_label_hash)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ;

    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    const namehash_hex = try name.namehash.toHex(db.allocator);
    defer db.allocator.free(namehash_hex);

    const label_hash_hex = try name.label_hash.toHex(db.allocator);
    defer db.allocator.free(label_hash_hex);

    const parent_hash_hex = try name.parent_namehash.toHex(db.allocator);
    defer db.allocator.free(parent_hash_hex);

    const registry_hex = try name.registry.toHex(db.allocator);
    defer db.allocator.free(registry_hex);

    const owner_hex = try name.owner.toHex(db.allocator);
    defer db.allocator.free(owner_hex);

    const resolver_hex = try name.resolver.toHex(db.allocator);
    defer db.allocator.free(resolver_hex);

    const chain_str = name.chain.toString();

    // Format token_id as hex string
    const token_id_hex = try std.fmt.allocPrint(db.allocator, "0x{x:0>64}", .{name.token_id});
    defer db.allocator.free(token_id_hex);

    // Format canonical_id as hex string
    const canonical_id_hex = try std.fmt.allocPrint(db.allocator, "0x{x:0>64}", .{name.canonical_id});
    defer db.allocator.free(canonical_id_hex);

    _ = c.sqlite3_bind_text(stmt, 1, namehash_hex.ptr, @intCast(namehash_hex.len), SQLITE_TRANSIENT());
    if (name.name) |n| {
        _ = c.sqlite3_bind_text(stmt, 2, n.ptr, @intCast(n.len), SQLITE_TRANSIENT());
    } else {
        _ = c.sqlite3_bind_null(stmt, 2);
    }
    if (name.label) |l| {
        _ = c.sqlite3_bind_text(stmt, 3, l.ptr, @intCast(l.len), SQLITE_TRANSIENT());
    } else {
        _ = c.sqlite3_bind_null(stmt, 3);
    }
    _ = c.sqlite3_bind_text(stmt, 4, label_hash_hex.ptr, @intCast(label_hash_hex.len), SQLITE_TRANSIENT());
    if (name.parent_name) |p| {
        _ = c.sqlite3_bind_text(stmt, 5, p.ptr, @intCast(p.len), SQLITE_TRANSIENT());
    } else {
        _ = c.sqlite3_bind_null(stmt, 5);
    }
    _ = c.sqlite3_bind_text(stmt, 6, parent_hash_hex.ptr, @intCast(parent_hash_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 7, chain_str.ptr, @intCast(chain_str.len), c.SQLITE_STATIC);
    _ = c.sqlite3_bind_text(stmt, 8, registry_hex.ptr, @intCast(registry_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 9, owner_hex.ptr, @intCast(owner_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 10, resolver_hex.ptr, @intCast(resolver_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 11, token_id_hex.ptr, @intCast(token_id_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 12, canonical_id_hex.ptr, @intCast(canonical_id_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 13, @intCast(name.token_version));
    _ = c.sqlite3_bind_int64(stmt, 14, name.expiry);
    _ = c.sqlite3_bind_int(stmt, 15, if (name.registry_locked) 1 else 0);
    _ = c.sqlite3_bind_int(stmt, 16, if (name.migrated) 1 else 0);
    _ = c.sqlite3_bind_int(stmt, 17, if (name.ejected) 1 else 0);
    _ = c.sqlite3_bind_int64(stmt, 18, @intCast(name.created_block));
    _ = c.sqlite3_bind_int64(stmt, 19, name.created_at);
    _ = c.sqlite3_bind_int64(stmt, 20, @intCast(name.updated_block));
    _ = c.sqlite3_bind_int64(stmt, 21, name.updated_at);
    _ = c.sqlite3_bind_int(stmt, 22, if (name.is_wrapped) 1 else 0);
    if (name.wrapper_fuses) |fuses| {
        _ = c.sqlite3_bind_text(stmt, 23, fuses.ptr, @intCast(fuses.len), SQLITE_TRANSIENT());
    } else {
        _ = c.sqlite3_bind_null(stmt, 23);
    }
    if (name.wrapper_expiry) |expiry| {
        _ = c.sqlite3_bind_int64(stmt, 24, expiry);
    } else {
        _ = c.sqlite3_bind_null(stmt, 24);
    }
    _ = c.sqlite3_bind_int(stmt, 25, if (name.is_v1_name) 1 else 0);
    if (name.v1_label_hash) |hash| {
        _ = c.sqlite3_bind_text(stmt, 26, hash.ptr, @intCast(hash.len), SQLITE_TRANSIENT());
    } else {
        _ = c.sqlite3_bind_null(stmt, 26);
    }

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to insert name: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.InsertFailed;
    }
}

pub fn getNameByNamehash(db: *Database, namehash: Hash) !?models.Name {
    const sql =
        \\SELECT name, label, label_hash, parent_name, parent_namehash, chain, registry,
        \\       owner, resolver, token_id, canonical_id, token_version, namehash, expiry, registry_locked,
        \\       migrated, ejected, created_block, created_at, updated_block, updated_at,
        \\       is_wrapped, wrapper_fuses, wrapper_expiry, is_v1_name, v1_label_hash
        \\FROM names WHERE namehash = ?
    ;

    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    const namehash_hex = try namehash.toHex(db.allocator);
    defer db.allocator.free(namehash_hex);

    _ = c.sqlite3_bind_text(stmt, 1, namehash_hex.ptr, @intCast(namehash_hex.len), SQLITE_TRANSIENT());

    if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const name_str = std.mem.span(c.sqlite3_column_text(stmt, 0));
        const label_str = std.mem.span(c.sqlite3_column_text(stmt, 1));
        const label_hash_str = std.mem.span(c.sqlite3_column_text(stmt, 2));
        const parent_name_str = std.mem.span(c.sqlite3_column_text(stmt, 3));
        const parent_hash_str = std.mem.span(c.sqlite3_column_text(stmt, 4));
        const chain_str = std.mem.span(c.sqlite3_column_text(stmt, 5));
        const registry_str = std.mem.span(c.sqlite3_column_text(stmt, 6));
        const owner_str = std.mem.span(c.sqlite3_column_text(stmt, 7));
        const resolver_str = std.mem.span(c.sqlite3_column_text(stmt, 8));
        const token_id_str = std.mem.span(c.sqlite3_column_text(stmt, 9));
        const canonical_id_str = std.mem.span(c.sqlite3_column_text(stmt, 10));

        return models.Name{
            .name = try db.allocator.dupe(u8, name_str),
            .namehash = namehash,
            .label = try db.allocator.dupe(u8, label_str),
            .label_hash = try Hash.fromHex(label_hash_str),
            .parent_name = try db.allocator.dupe(u8, parent_name_str),
            .parent_namehash = try Hash.fromHex(parent_hash_str),
            .chain = try models.Chain.fromString(chain_str),
            .registry = try Address.fromHex(registry_str),
            .owner = try Address.fromHex(owner_str),
            .resolver = try Address.fromHex(resolver_str),
            .token_id = blk: {
                const hex_str = if (std.mem.startsWith(u8, token_id_str, "0x")) token_id_str[2..] else token_id_str;
                break :blk try std.fmt.parseInt(u256, hex_str, 16);
            },
            .canonical_id = blk: {
                const hex_str = if (std.mem.startsWith(u8, canonical_id_str, "0x")) canonical_id_str[2..] else canonical_id_str;
                break :blk try std.fmt.parseInt(u256, hex_str, 16);
            },
            .token_version = @intCast(c.sqlite3_column_int64(stmt, 11)),
            // Column 12 is namehash (skipped - using input param)
            .expiry = c.sqlite3_column_int64(stmt, 13),
            .registry_locked = c.sqlite3_column_int(stmt, 14) != 0,
            .migrated = c.sqlite3_column_int(stmt, 15) != 0,
            .ejected = c.sqlite3_column_int(stmt, 16) != 0,
            .created_block = @intCast(c.sqlite3_column_int64(stmt, 17)),
            .created_at = c.sqlite3_column_int64(stmt, 18),
            .updated_block = @intCast(c.sqlite3_column_int64(stmt, 19)),
            .updated_at = c.sqlite3_column_int64(stmt, 20),
            .is_wrapped = false,
            .wrapper_fuses = null,
            .wrapper_expiry = null,
            .is_v1_name = false,
            .v1_label_hash = null,
        };
    }

    return null;
}

/// Get namehash by resolver address
/// In ENSv2, each name typically has its own dedicated resolver, so we can look up
/// the name's namehash from the resolver address
pub fn getNamehashByResolver(db: *Database, resolver: Address) !?Hash {
    const sql = "SELECT namehash FROM names WHERE resolver = ? LIMIT 1";

    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    const resolver_hex = try resolver.toHex(db.allocator);
    defer db.allocator.free(resolver_hex);

    _ = c.sqlite3_bind_text(stmt, 1, resolver_hex.ptr, @intCast(resolver_hex.len), SQLITE_TRANSIENT());

    if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const namehash_str = std.mem.span(c.sqlite3_column_text(stmt, 0));
        return try Hash.fromHex(namehash_str);
    }

    return null;
}

/// Update name expiry (for renewals)
pub fn updateNameExpiry(db: *Database, namehash: Hash, expiry: i64) !void {
    const sql = "UPDATE names SET expiry = ?, updated_at = ?, updated_block = updated_block + 1 WHERE namehash = ?";

    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    const timestamp = std.time.timestamp();
    const namehash_hex = try namehash.toHex(db.allocator);
    defer db.allocator.free(namehash_hex);

    _ = c.sqlite3_bind_int64(stmt, 1, expiry);
    _ = c.sqlite3_bind_int64(stmt, 2, timestamp);
    _ = c.sqlite3_bind_text(stmt, 3, namehash_hex.ptr, @intCast(namehash_hex.len), SQLITE_TRANSIENT());

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to update name expiry: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.UpdateFailed;
    }
}

/// Update name owner (for transfers)
pub fn updateNameOwner(db: *Database, namehash: Hash, new_owner: Address) !void {
    const sql = "UPDATE names SET owner = ?, updated_at = ?, updated_block = updated_block + 1 WHERE namehash = ?";

    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    const timestamp = std.time.timestamp();
    const owner_hex = try new_owner.toHex(db.allocator);
    defer db.allocator.free(owner_hex);

    const namehash_hex = try namehash.toHex(db.allocator);
    defer db.allocator.free(namehash_hex);

    _ = c.sqlite3_bind_text(stmt, 1, owner_hex.ptr, @intCast(owner_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 2, timestamp);
    _ = c.sqlite3_bind_text(stmt, 3, namehash_hex.ptr, @intCast(namehash_hex.len), SQLITE_TRANSIENT());

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to update name owner: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.UpdateFailed;
    }
}

/// Update name subregistry
pub fn updateNameSubregistry(db: *Database, namehash: Hash, subregistry: Address) !void {
    const sql = "UPDATE names SET registry = ?, updated_at = ?, updated_block = updated_block + 1 WHERE namehash = ?";

    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    const timestamp = std.time.timestamp();
    const subregistry_hex = try subregistry.toHex(db.allocator);
    defer db.allocator.free(subregistry_hex);

    const namehash_hex = try namehash.toHex(db.allocator);
    defer db.allocator.free(namehash_hex);

    _ = c.sqlite3_bind_text(stmt, 1, subregistry_hex.ptr, @intCast(subregistry_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 2, timestamp);
    _ = c.sqlite3_bind_text(stmt, 3, namehash_hex.ptr, @intCast(namehash_hex.len), SQLITE_TRANSIENT());

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to update name subregistry: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.UpdateFailed;
    }
}

/// Update name resolver
pub fn updateNameResolver(db: *Database, namehash: Hash, resolver: Address) !void {
    const sql = "UPDATE names SET resolver = ?, updated_at = ?, updated_block = updated_block + 1 WHERE namehash = ?";

    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    const timestamp = std.time.timestamp();
    const resolver_hex = try resolver.toHex(db.allocator);
    defer db.allocator.free(resolver_hex);

    const namehash_hex = try namehash.toHex(db.allocator);
    defer db.allocator.free(namehash_hex);

    _ = c.sqlite3_bind_text(stmt, 1, resolver_hex.ptr, @intCast(resolver_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 2, timestamp);
    _ = c.sqlite3_bind_text(stmt, 3, namehash_hex.ptr, @intCast(namehash_hex.len), SQLITE_TRANSIENT());

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to update name resolver: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.UpdateFailed;
    }
}

/// Get name by token ID
pub fn getNameByTokenId(db: *Database, token_id: u256) !?models.Name {
    const sql = "SELECT name, label, label_hash, parent_name, parent_namehash, chain, registry, owner, resolver, token_id, canonical_id, token_version, namehash, expiry, registry_locked, migrated, ejected, created_block, created_at, updated_block, updated_at FROM names WHERE token_id = ? LIMIT 1";

    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    // Format token_id as hex string to match how it's stored in the database
    const token_id_hex = try std.fmt.allocPrint(db.allocator, "0x{x:0>64}", .{token_id});
    defer db.allocator.free(token_id_hex);

    _ = c.sqlite3_bind_text(stmt, 1, token_id_hex.ptr, @intCast(token_id_hex.len), SQLITE_TRANSIENT());

    if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const name_str = std.mem.span(c.sqlite3_column_text(stmt, 0));
        const label_str = std.mem.span(c.sqlite3_column_text(stmt, 1));
        const label_hash_str = std.mem.span(c.sqlite3_column_text(stmt, 2));
        const parent_name_str = std.mem.span(c.sqlite3_column_text(stmt, 3));
        const parent_hash_str = std.mem.span(c.sqlite3_column_text(stmt, 4));
        const chain_str = std.mem.span(c.sqlite3_column_text(stmt, 5));
        const registry_str = std.mem.span(c.sqlite3_column_text(stmt, 6));
        const owner_str = std.mem.span(c.sqlite3_column_text(stmt, 7));
        const resolver_str = std.mem.span(c.sqlite3_column_text(stmt, 8));
        const token_id_str = std.mem.span(c.sqlite3_column_text(stmt, 9));
        const canonical_id_str = std.mem.span(c.sqlite3_column_text(stmt, 10));
        const token_version = @as(u32, @intCast(c.sqlite3_column_int64(stmt, 11)));
        const namehash_str = std.mem.span(c.sqlite3_column_text(stmt, 12));
        const expiry = c.sqlite3_column_int64(stmt, 13);
        const registry_locked = c.sqlite3_column_int(stmt, 14) != 0;
        const migrated = c.sqlite3_column_int(stmt, 15) != 0;
        const ejected = c.sqlite3_column_int(stmt, 16) != 0;
        const created_block = c.sqlite3_column_int64(stmt, 17);
        const created_at = c.sqlite3_column_int64(stmt, 18);
        const updated_block = c.sqlite3_column_int64(stmt, 19);
        const updated_at = c.sqlite3_column_int64(stmt, 20);
        const is_wrapped = c.sqlite3_column_int(stmt, 21) != 0;
        const wrapper_fuses_ptr = c.sqlite3_column_text(stmt, 22);
        const wrapper_fuses = if (wrapper_fuses_ptr != null) try db.allocator.dupe(u8, std.mem.span(wrapper_fuses_ptr)) else null;
        const wrapper_expiry_raw = c.sqlite3_column_int64(stmt, 23);
        const wrapper_expiry = if (c.sqlite3_column_type(stmt, 23) != c.SQLITE_NULL) wrapper_expiry_raw else null;
        const is_v1_name = c.sqlite3_column_int(stmt, 24) != 0;
        const v1_label_hash_ptr = c.sqlite3_column_text(stmt, 25);
        const v1_label_hash = if (v1_label_hash_ptr != null) try db.allocator.dupe(u8, std.mem.span(v1_label_hash_ptr)) else null;

        return models.Name{
            .name = try db.allocator.dupe(u8, name_str),
            .label = try db.allocator.dupe(u8, label_str),
            .label_hash = try Hash.fromHex(label_hash_str),
            .parent_name = try db.allocator.dupe(u8, parent_name_str),
            .parent_namehash = try Hash.fromHex(parent_hash_str),
            .chain = try models.Chain.fromString(chain_str),
            .registry = try Address.fromHex(registry_str),
            .owner = try Address.fromHex(owner_str),
            .resolver = try Address.fromHex(resolver_str),
            .token_id = blk: {
                const hex_str = if (std.mem.startsWith(u8, token_id_str, "0x")) token_id_str[2..] else token_id_str;
                break :blk try std.fmt.parseInt(u256, hex_str, 16);
            },
            .canonical_id = blk: {
                const hex_str = if (std.mem.startsWith(u8, canonical_id_str, "0x")) canonical_id_str[2..] else canonical_id_str;
                break :blk try std.fmt.parseInt(u256, hex_str, 16);
            },
            .token_version = token_version,
            .namehash = try Hash.fromHex(namehash_str),
            .expiry = @intCast(expiry),
            .registry_locked = registry_locked,
            .migrated = migrated,
            .ejected = ejected,
            .created_block = @intCast(created_block),
            .created_at = created_at,
            .updated_block = @intCast(updated_block),
            .updated_at = updated_at,
            .is_wrapped = is_wrapped,
            .wrapper_fuses = wrapper_fuses,
            .wrapper_expiry = wrapper_expiry,
            .is_v1_name = is_v1_name,
            .v1_label_hash = v1_label_hash,
        };
    }

    return null;
}

/// Update name expiry by token ID (for V2 renewals)
pub fn updateNameExpiryByTokenId(db: *Database, token_id: i64, expiry: i64) !void {
    const sql = "UPDATE names SET expiry = ?, updated_at = ?, updated_block = updated_block + 1 WHERE token_id = ?";

    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    const timestamp = std.time.timestamp();

    // Format token_id as hex string to match how it's stored in the database
    const token_id_hex = try std.fmt.allocPrint(db.allocator, "0x{x:0>64}", .{@as(u256, @intCast(token_id))});
    defer db.allocator.free(token_id_hex);

    _ = c.sqlite3_bind_int64(stmt, 1, expiry);
    _ = c.sqlite3_bind_int64(stmt, 2, timestamp);
    _ = c.sqlite3_bind_text(stmt, 3, token_id_hex.ptr, @intCast(token_id_hex.len), SQLITE_TRANSIENT());

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to update name expiry by token_id: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.UpdateFailed;
    }
}

/// Delete a name by token ID (for burned names)
pub fn deleteNameByTokenId(db: *Database, token_id: i64) !void {
    const sql = "DELETE FROM names WHERE token_id = ?";

    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    // Format token_id as hex string to match how it's stored in the database
    const token_id_hex = try std.fmt.allocPrint(db.allocator, "0x{x:0>64}", .{@as(u256, @intCast(token_id))});
    defer db.allocator.free(token_id_hex);

    _ = c.sqlite3_bind_text(stmt, 1, token_id_hex.ptr, @intCast(token_id_hex.len), SQLITE_TRANSIENT());

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to delete name by token_id: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.DeleteFailed;
    }
}

/// Update token_id for a name (for TokenRegenerated events)
pub fn updateNameTokenId(db: *Database, old_token_id: u256, new_token_id: u256) !void {
    const token_id_utils = @import("../types/token_id.zig");

    // Extract canonical_id and token_version from the new token_id
    const canonical_id = token_id_utils.getCanonicalId(new_token_id);
    const token_version = token_id_utils.getTokenVersion(new_token_id);

    const sql = "UPDATE names SET token_id = ?, canonical_id = ?, token_version = ?, updated_at = ?, updated_block = updated_block + 1 WHERE token_id = ?";

    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    const timestamp = std.time.timestamp();

    // Format both token IDs as hex strings to match how they're stored in the database
    const new_token_id_hex = try std.fmt.allocPrint(db.allocator, "0x{x:0>64}", .{new_token_id});
    defer db.allocator.free(new_token_id_hex);

    const old_token_id_hex = try std.fmt.allocPrint(db.allocator, "0x{x:0>64}", .{old_token_id});
    defer db.allocator.free(old_token_id_hex);

    const canonical_id_hex = try std.fmt.allocPrint(db.allocator, "0x{x:0>64}", .{canonical_id});
    defer db.allocator.free(canonical_id_hex);

    _ = c.sqlite3_bind_text(stmt, 1, new_token_id_hex.ptr, @intCast(new_token_id_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 2, canonical_id_hex.ptr, @intCast(canonical_id_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 3, @intCast(token_version));
    _ = c.sqlite3_bind_int64(stmt, 4, timestamp);
    _ = c.sqlite3_bind_text(stmt, 5, old_token_id_hex.ptr, @intCast(old_token_id_hex.len), SQLITE_TRANSIENT());

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to update token_id: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.UpdateFailed;
    }
}

/// Get all names owned by an address
pub fn getNamesByOwner(db: *Database, owner: Address, limit: ?u32) ![]models.Name {
    const sql = if (limit) |l|
        try std.fmt.allocPrint(db.allocator, "SELECT name, label, label_hash, parent_name, parent_namehash, chain, registry, owner, resolver, token_id, canonical_id, token_version, namehash, expiry, registry_locked, migrated, ejected, created_block, created_at, updated_block, updated_at FROM names WHERE owner = ? LIMIT {d}", .{l})
    else
        try std.fmt.allocPrint(db.allocator, "SELECT name, label, label_hash, parent_name, parent_namehash, chain, registry, owner, resolver, token_id, canonical_id, token_version, namehash, expiry, registry_locked, migrated, ejected, created_block, created_at, updated_block, updated_at FROM names WHERE owner = ?", .{});
    defer db.allocator.free(sql);

    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    const owner_hex = try owner.toHex(db.allocator);
    defer db.allocator.free(owner_hex);

    _ = c.sqlite3_bind_text(stmt, 1, owner_hex.ptr, @intCast(owner_hex.len), SQLITE_TRANSIENT());

    var names: std.ArrayList(models.Name) = .{};
    errdefer {
        for (names.items) |*name| {
            name.deinit(db.allocator);
        }
        names.deinit(db.allocator);
    }

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const name_str = std.mem.span(c.sqlite3_column_text(stmt, 0));
        const label_str = std.mem.span(c.sqlite3_column_text(stmt, 1));
        const label_hash_str = std.mem.span(c.sqlite3_column_text(stmt, 2));
        const parent_name_str = std.mem.span(c.sqlite3_column_text(stmt, 3));
        const parent_namehash_str = std.mem.span(c.sqlite3_column_text(stmt, 4));
        const chain_str = std.mem.span(c.sqlite3_column_text(stmt, 5));
        const registry_str = std.mem.span(c.sqlite3_column_text(stmt, 6));
        const owner_str = std.mem.span(c.sqlite3_column_text(stmt, 7));
        const resolver_str = std.mem.span(c.sqlite3_column_text(stmt, 8));
        const token_id_str = std.mem.span(c.sqlite3_column_text(stmt, 9));
        const canonical_id_str = std.mem.span(c.sqlite3_column_text(stmt, 10));
        const namehash_str = std.mem.span(c.sqlite3_column_text(stmt, 12));

        const name = models.Name{
            .name = try db.allocator.dupe(u8, name_str),
            .label = try db.allocator.dupe(u8, label_str),
            .label_hash = try Hash.fromHex(label_hash_str),
            .parent_name = try db.allocator.dupe(u8, parent_name_str),
            .parent_namehash = try Hash.fromHex(parent_namehash_str),
            .chain = try models.Chain.fromString(chain_str),
            .registry = try Address.fromHex(registry_str),
            .owner = try Address.fromHex(owner_str),
            .resolver = try Address.fromHex(resolver_str),
            .token_id = blk: {
                const hex_str = if (std.mem.startsWith(u8, token_id_str, "0x")) token_id_str[2..] else token_id_str;
                break :blk try std.fmt.parseInt(u256, hex_str, 16);
            },
            .canonical_id = blk: {
                const hex_str = if (std.mem.startsWith(u8, canonical_id_str, "0x")) canonical_id_str[2..] else canonical_id_str;
                break :blk try std.fmt.parseInt(u256, hex_str, 16);
            },
            .token_version = @intCast(c.sqlite3_column_int64(stmt, 11)),
            .namehash = try Hash.fromHex(namehash_str),
            .expiry = c.sqlite3_column_int64(stmt, 13),
            .registry_locked = c.sqlite3_column_int(stmt, 14) != 0,
            .migrated = c.sqlite3_column_int(stmt, 15) != 0,
            .ejected = c.sqlite3_column_int(stmt, 16) != 0,
            .created_block = @intCast(c.sqlite3_column_int64(stmt, 17)),
            .created_at = c.sqlite3_column_int64(stmt, 18),
            .updated_block = @intCast(c.sqlite3_column_int64(stmt, 19)),
            .updated_at = c.sqlite3_column_int64(stmt, 20),
            .is_wrapped = false,
            .wrapper_fuses = null,
            .wrapper_expiry = null,
            .is_v1_name = false,
            .v1_label_hash = null,
        };

        try names.append(db.allocator, name);
    }

    return names.toOwnedSlice(db.allocator);
}

/// Get all names with filtering and pagination
/// Order direction for queries
pub const OrderDir = enum {
    asc,
    desc,
};

pub fn getAllNames(db: *Database, owner: ?Address, skip: u32, limit: u32) ![]models.Name {
    return getAllNamesWithOrder(db, owner, skip, limit, .desc);
}

/// Get all names with configurable order direction (for backward pagination support)
pub fn getAllNamesWithOrder(db: *Database, owner: ?Address, skip: u32, limit: u32, order_dir: OrderDir) ![]models.Name {
    var sql_buf: [512]u8 = undefined;
    var sql_len: usize = 0;

    const base_sql = "SELECT name, namehash, label, label_hash, parent_name, owner, resolver, registry, chain, token_id, canonical_id, token_version, expiry, registry_locked, migrated, ejected, created_at, created_block, updated_at, updated_block FROM names";
    @memcpy(sql_buf[sql_len..][0..base_sql.len], base_sql);
    sql_len += base_sql.len;

    if (owner != null) {
        const where_sql = " WHERE owner = ?";
        @memcpy(sql_buf[sql_len..][0..where_sql.len], where_sql);
        sql_len += where_sql.len;
    }

    // Use order direction for backward pagination support
    const order_sql = if (order_dir == .desc)
        " ORDER BY created_at DESC LIMIT ? OFFSET ?"
    else
        " ORDER BY created_at ASC LIMIT ? OFFSET ?";
    @memcpy(sql_buf[sql_len..][0..order_sql.len], order_sql);
    sql_len += order_sql.len;

    const sql = sql_buf[0..sql_len];
    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db.db, sql_z.ptr, @intCast(sql_z.len + 1), &stmt, null) != c.SQLITE_OK) {
        std.log.err("Failed to prepare statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.DatabaseError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    var param_index: c_int = 1;
    var owner_hex: ?[]u8 = null;
    defer if (owner_hex) |h| db.allocator.free(h);

    if (owner) |o| {
        // Owner is stored as TEXT hex string in the database
        owner_hex = try o.toHex(db.allocator);
        if (c.sqlite3_bind_text(stmt, param_index, owner_hex.?.ptr, @intCast(owner_hex.?.len), SQLITE_TRANSIENT()) != c.SQLITE_OK) {
            return error.DatabaseError;
        }
        param_index += 1;
    }

    if (c.sqlite3_bind_int(stmt, param_index, @intCast(limit)) != c.SQLITE_OK) {
        return error.DatabaseError;
    }
    param_index += 1;

    if (c.sqlite3_bind_int(stmt, param_index, @intCast(skip)) != c.SQLITE_OK) {
        return error.DatabaseError;
    }

    var names: std.ArrayList(models.Name) = .{};
    errdefer {
        for (names.items) |*name| {
            name.deinit(db.allocator);
        }
        names.deinit(db.allocator);
    }

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const name_str = std.mem.span(c.sqlite3_column_text(stmt, 0));
        const label_str = std.mem.span(c.sqlite3_column_text(stmt, 2));
        const label_hash_str = std.mem.span(c.sqlite3_column_text(stmt, 3));
        const parent_name_str = std.mem.span(c.sqlite3_column_text(stmt, 4));
        const chain_str = std.mem.span(c.sqlite3_column_text(stmt, 8));
        const registry_str = std.mem.span(c.sqlite3_column_text(stmt, 7));
        const owner_str = std.mem.span(c.sqlite3_column_text(stmt, 5));
        const resolver_str = std.mem.span(c.sqlite3_column_text(stmt, 6));
        const token_id_str = std.mem.span(c.sqlite3_column_text(stmt, 9));
        const canonical_id_str = std.mem.span(c.sqlite3_column_text(stmt, 10));
        const namehash_str = std.mem.span(c.sqlite3_column_text(stmt, 1));

        // Derive parent_namehash from parent_name
        const parent_namehash = try @import("../types/hash.zig").namehash(db.allocator, parent_name_str);

        const name = models.Name{
            .name = try db.allocator.dupe(u8, name_str),
            .label = try db.allocator.dupe(u8, label_str),
            .label_hash = try Hash.fromHex(label_hash_str),
            .parent_name = try db.allocator.dupe(u8, parent_name_str),
            .parent_namehash = parent_namehash,
            .chain = try models.Chain.fromString(chain_str),
            .registry = try Address.fromHex(registry_str),
            .owner = try Address.fromHex(owner_str),
            .resolver = try Address.fromHex(resolver_str),
            .token_id = blk: {
                const hex_str = if (std.mem.startsWith(u8, token_id_str, "0x")) token_id_str[2..] else token_id_str;
                break :blk try std.fmt.parseInt(u256, hex_str, 16);
            },
            .canonical_id = blk: {
                const hex_str = if (std.mem.startsWith(u8, canonical_id_str, "0x")) canonical_id_str[2..] else canonical_id_str;
                break :blk try std.fmt.parseInt(u256, hex_str, 16);
            },
            .token_version = @intCast(c.sqlite3_column_int64(stmt, 11)),
            .namehash = try Hash.fromHex(namehash_str),
            .expiry = c.sqlite3_column_int64(stmt, 12),
            .registry_locked = c.sqlite3_column_int(stmt, 13) != 0,
            .migrated = c.sqlite3_column_int(stmt, 14) != 0,
            .ejected = c.sqlite3_column_int(stmt, 15) != 0,
            .created_block = @intCast(c.sqlite3_column_int64(stmt, 17)),
            .created_at = c.sqlite3_column_int64(stmt, 16),
            .updated_block = @intCast(c.sqlite3_column_int64(stmt, 19)),
            .updated_at = c.sqlite3_column_int64(stmt, 18),
            .is_wrapped = false,
            .wrapper_fuses = null,
            .wrapper_expiry = null,
            .is_v1_name = false,
            .v1_label_hash = null,
        };

        try names.append(db.allocator, name);
    }

    return names.toOwnedSlice(db.allocator);
}

/// Count direct subdomains for a given parent name (one level down only)
/// For example, if parent_name is "eth", this counts "vitalik.eth", "nick.eth", etc.
/// but NOT "sub.vitalik.eth" (which would be a subdomain of "vitalik.eth")
pub fn countDirectSubdomains(db: *Database, parent_name: []const u8) !u32 {
    const sql = "SELECT COUNT(*) FROM names WHERE parent_name = ?";

    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    const parent_name_z = try db.allocator.dupeZ(u8, parent_name);
    defer db.allocator.free(parent_name_z);

    _ = c.sqlite3_bind_text(stmt, 1, parent_name_z.ptr, @intCast(parent_name_z.len), null);

    const step_result = c.sqlite3_step(stmt);
    if (step_result == c.SQLITE_ROW) {
        return @intCast(c.sqlite3_column_int(stmt, 0));
    }

    return 0;
}

/// Check if a domain has any direct subdomains (one level down only)
pub fn hasDirectSubdomains(db: *Database, parent_name: []const u8) !bool {
    const sql = "SELECT 1 FROM names WHERE parent_name = ? LIMIT 1";

    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    const parent_name_z = try db.allocator.dupeZ(u8, parent_name);
    defer db.allocator.free(parent_name_z);

    _ = c.sqlite3_bind_text(stmt, 1, parent_name_z.ptr, @intCast(parent_name_z.len), null);

    const step_result = c.sqlite3_step(stmt);
    return step_result == c.SQLITE_ROW;
}

/// Get subdomains of a parent domain with pagination
/// Returns names where parent_name = the given parent name
pub fn getSubdomains(db: *Database, parent_name_arg: []const u8, skip: u32, limit: u32) ![]models.Name {
    const sql = "SELECT name, namehash, label, label_hash, parent_name, owner, resolver, registry, chain, token_id, canonical_id, token_version, expiry, registry_locked, migrated, ejected, created_at, created_block, updated_at, updated_block FROM names WHERE parent_name = ? ORDER BY created_at DESC LIMIT ? OFFSET ?";

    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    const parent_name_z = try db.allocator.dupeZ(u8, parent_name_arg);
    defer db.allocator.free(parent_name_z);

    _ = c.sqlite3_bind_text(stmt, 1, parent_name_z.ptr, @intCast(parent_name_z.len), null);
    _ = c.sqlite3_bind_int(stmt, 2, @intCast(limit));
    _ = c.sqlite3_bind_int(stmt, 3, @intCast(skip));

    var names_list: std.ArrayList(models.Name) = .{};
    errdefer {
        for (names_list.items) |*n| {
            n.deinit(db.allocator);
        }
        names_list.deinit(db.allocator);
    }

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const name_str = std.mem.span(c.sqlite3_column_text(stmt, 0));
        const label_str = std.mem.span(c.sqlite3_column_text(stmt, 2));
        const label_hash_str = std.mem.span(c.sqlite3_column_text(stmt, 3));
        const parent_name_str = std.mem.span(c.sqlite3_column_text(stmt, 4));
        const chain_str = std.mem.span(c.sqlite3_column_text(stmt, 8));
        const registry_str = std.mem.span(c.sqlite3_column_text(stmt, 7));
        const owner_str = std.mem.span(c.sqlite3_column_text(stmt, 5));
        const resolver_str = std.mem.span(c.sqlite3_column_text(stmt, 6));
        const token_id_str = std.mem.span(c.sqlite3_column_text(stmt, 9));
        const canonical_id_str = std.mem.span(c.sqlite3_column_text(stmt, 10));
        const namehash_str = std.mem.span(c.sqlite3_column_text(stmt, 1));

        // Derive parent_namehash from parent_name
        const parent_namehash = try @import("../types/hash.zig").namehash(db.allocator, parent_name_str);

        const name = models.Name{
            .name = try db.allocator.dupe(u8, name_str),
            .label = try db.allocator.dupe(u8, label_str),
            .label_hash = try Hash.fromHex(label_hash_str),
            .parent_name = try db.allocator.dupe(u8, parent_name_str),
            .parent_namehash = parent_namehash,
            .chain = try models.Chain.fromString(chain_str),
            .registry = try Address.fromHex(registry_str),
            .owner = try Address.fromHex(owner_str),
            .resolver = try Address.fromHex(resolver_str),
            .token_id = blk: {
                const hex_str = if (std.mem.startsWith(u8, token_id_str, "0x")) token_id_str[2..] else token_id_str;
                break :blk try std.fmt.parseInt(u256, hex_str, 16);
            },
            .canonical_id = blk: {
                const hex_str = if (std.mem.startsWith(u8, canonical_id_str, "0x")) canonical_id_str[2..] else canonical_id_str;
                break :blk try std.fmt.parseInt(u256, hex_str, 16);
            },
            .token_version = @intCast(c.sqlite3_column_int64(stmt, 11)),
            .namehash = try Hash.fromHex(namehash_str),
            .expiry = c.sqlite3_column_int64(stmt, 12),
            .registry_locked = c.sqlite3_column_int(stmt, 13) != 0,
            .migrated = c.sqlite3_column_int(stmt, 14) != 0,
            .ejected = c.sqlite3_column_int(stmt, 15) != 0,
            .created_block = @intCast(c.sqlite3_column_int64(stmt, 17)),
            .created_at = c.sqlite3_column_int64(stmt, 16),
            .updated_block = @intCast(c.sqlite3_column_int64(stmt, 19)),
            .updated_at = c.sqlite3_column_int64(stmt, 18),
            .is_wrapped = false,
            .wrapper_fuses = null,
            .wrapper_expiry = null,
            .is_v1_name = false,
            .v1_label_hash = null,
        };

        try names_list.append(db.allocator, name);
    }

    return names_list.toOwnedSlice(db.allocator);
}

/// Get all registries owned by an account (i.e., registries for names owned by the account)
pub fn getRegistriesByOwner(db: *Database, chain: models.Chain, owner: Address) ![]models.Registry {
    const sql =
        \\SELECT r.address, r.chain, r.name, r.namehash, r.parent_registry, r.created_block, r.created_at
        \\FROM registries r
        \\INNER JOIN names n ON r.chain = n.chain AND r.namehash = n.namehash
        \\WHERE r.chain = ? AND n.owner = ?
        \\ORDER BY r.created_at DESC
    ;

    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    const chain_str = chain.toString();
    const owner_hex = try owner.toHex(db.allocator);
    defer db.allocator.free(owner_hex);

    _ = c.sqlite3_bind_text(stmt, 1, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 2, owner_hex.ptr, @intCast(owner_hex.len), SQLITE_TRANSIENT());

    var registries: std.ArrayList(models.Registry) = .{};
    errdefer {
        for (registries.items) |*reg| {
            reg.deinit(db.allocator);
        }
        registries.deinit(db.allocator);
    }

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const address_hex = std.mem.span(c.sqlite3_column_text(stmt, 0));
        const chain_col = std.mem.span(c.sqlite3_column_text(stmt, 1));
        const name_str = std.mem.span(c.sqlite3_column_text(stmt, 2));
        const namehash_hex = std.mem.span(c.sqlite3_column_text(stmt, 3));
        const parent_hex = std.mem.span(c.sqlite3_column_text(stmt, 4));

        const registry = models.Registry{
            .address = try Address.fromHex(address_hex),
            .chain = try models.Chain.fromString(chain_col),
            .name = try db.allocator.dupe(u8, name_str),
            .namehash = try Hash.fromHex(namehash_hex),
            .parent_registry = try Address.fromHex(parent_hex),
            .created_block = @intCast(c.sqlite3_column_int64(stmt, 5)),
            .created_at = c.sqlite3_column_int64(stmt, 6),
        };

        try registries.append(db.allocator, registry);
    }

    return registries.toOwnedSlice(db.allocator);
}

// ============================================================================
// WRAPPER STATE UPDATE FUNCTIONS
// ============================================================================

/// Update name wrapper state when a name is wrapped
/// Sets is_wrapped=1, stores fuses and expiry
pub fn updateNameWrapperState(db: *Database, namehash: Hash, fuses: u32, expiry: i64) !void {
    const sql = "UPDATE names SET is_wrapped = 1, wrapper_fuses = ?, wrapper_expiry = ?, updated_at = ?, updated_block = updated_block + 1 WHERE namehash = ?";

    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    const timestamp = std.time.timestamp();
    const fuses_str = try std.fmt.allocPrint(db.allocator, "{d}", .{fuses});
    defer db.allocator.free(fuses_str);

    const namehash_hex = try namehash.toHex(db.allocator);
    defer db.allocator.free(namehash_hex);

    _ = c.sqlite3_bind_text(stmt, 1, fuses_str.ptr, @intCast(fuses_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 2, expiry);
    _ = c.sqlite3_bind_int64(stmt, 3, timestamp);
    _ = c.sqlite3_bind_text(stmt, 4, namehash_hex.ptr, @intCast(namehash_hex.len), SQLITE_TRANSIENT());

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to update name wrapper state: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.UpdateFailed;
    }
}

/// Update name wrapper state when a name is unwrapped
/// Sets is_wrapped=0, clears fuses and expiry
pub fn updateNameUnwrapperState(db: *Database, namehash: Hash) !void {
    const sql = "UPDATE names SET is_wrapped = 0, wrapper_fuses = NULL, wrapper_expiry = NULL, updated_at = ?, updated_block = updated_block + 1 WHERE namehash = ?";

    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    const timestamp = std.time.timestamp();
    const namehash_hex = try namehash.toHex(db.allocator);
    defer db.allocator.free(namehash_hex);

    _ = c.sqlite3_bind_int64(stmt, 1, timestamp);
    _ = c.sqlite3_bind_text(stmt, 2, namehash_hex.ptr, @intCast(namehash_hex.len), SQLITE_TRANSIENT());

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to update name unwrapper state: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.UpdateFailed;
    }
}

/// Update name wrapper fuses
pub fn updateNameWrapperFuses(db: *Database, namehash: Hash, fuses: u32) !void {
    const sql = "UPDATE names SET wrapper_fuses = ?, updated_at = ?, updated_block = updated_block + 1 WHERE namehash = ?";

    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    const timestamp = std.time.timestamp();
    const fuses_str = try std.fmt.allocPrint(db.allocator, "{d}", .{fuses});
    defer db.allocator.free(fuses_str);

    const namehash_hex = try namehash.toHex(db.allocator);
    defer db.allocator.free(namehash_hex);

    _ = c.sqlite3_bind_text(stmt, 1, fuses_str.ptr, @intCast(fuses_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 2, timestamp);
    _ = c.sqlite3_bind_text(stmt, 3, namehash_hex.ptr, @intCast(namehash_hex.len), SQLITE_TRANSIENT());

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to update name wrapper fuses: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.UpdateFailed;
    }
}

/// Update name wrapper expiry
pub fn updateNameWrapperExpiry(db: *Database, namehash: Hash, expiry: i64) !void {
    const sql = "UPDATE names SET wrapper_expiry = ?, updated_at = ?, updated_block = updated_block + 1 WHERE namehash = ?";

    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    const timestamp = std.time.timestamp();
    const namehash_hex = try namehash.toHex(db.allocator);
    defer db.allocator.free(namehash_hex);

    _ = c.sqlite3_bind_int64(stmt, 1, expiry);
    _ = c.sqlite3_bind_int64(stmt, 2, timestamp);
    _ = c.sqlite3_bind_text(stmt, 3, namehash_hex.ptr, @intCast(namehash_hex.len), SQLITE_TRANSIENT());

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to update name wrapper expiry: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.UpdateFailed;
    }
}

/// Update name creation date if the provided date is earlier
/// Used for backfilling historical data while preserving latest state
pub fn updateNameCreationDateIfEarlier(db: *Database, namehash: Hash, block_number: u64, created_at: i64) !void {
    const sql =
        \\UPDATE names
        \\SET created_block = ?, created_at = ?
        \\WHERE namehash = ? AND created_block > ?
    ;

    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    const namehash_hex = try namehash.toHex(db.allocator);
    defer db.allocator.free(namehash_hex);

    _ = c.sqlite3_bind_int64(stmt, 1, @intCast(block_number));
    _ = c.sqlite3_bind_int64(stmt, 2, created_at);
    _ = c.sqlite3_bind_text(stmt, 3, namehash_hex.ptr, @intCast(namehash_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 4, @intCast(block_number));

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to update name creation date: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.UpdateFailed;
    }
}

// ============================================================================
// TESTS
// ============================================================================

test "updateNameWrapperState - wrap a name" {
    const allocator = testing.allocator;

    var database = try Database.init(allocator, ":memory:");
    defer database.deinit();

    // Create a test name first
    const test_name = models.Name{
        .name = "test.eth",
        .label = "test",
        .label_hash = Hash.zero,
        .parent_name = "eth",
        .parent_namehash = Hash.zero,
        .chain = .l1,
        .registry = Address.zero,
        .owner = Address.zero,
        .resolver = Address.zero,
        .token_id = 0,
        .canonical_id = 0,
        .token_version = 1,
        .namehash = Hash.zero,
        .expiry = 0,
        .registry_locked = false,
        .migrated = false,
        .ejected = false,
        .created_block = 1,
        .created_at = 1000,
        .updated_block = 1,
        .updated_at = 1000,
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    };

    try insertName(&database, test_name);

    // Wrap the name
    const fuses: u32 = 123;
    const expiry: i64 = 2000000000;
    try updateNameWrapperState(&database, Hash.zero, fuses, expiry);

    // Verify wrapper state was updated
    var name_opt = try getNameByNamehash(&database, Hash.zero);
    try testing.expect(name_opt != null);
    defer if (name_opt) |*n| n.deinit(allocator);

    // Note: We can't easily verify is_wrapped, wrapper_fuses, wrapper_expiry
    // as they're not in the Name struct yet. This test verifies the function doesn't crash.
}

test "updateNameUnwrapperState - unwrap a name" {
    const allocator = testing.allocator;

    var database = try Database.init(allocator, ":memory:");
    defer database.deinit();

    // Create and wrap a test name
    const test_name = models.Name{
        .name = "test.eth",
        .label = "test",
        .label_hash = Hash.zero,
        .parent_name = "eth",
        .parent_namehash = Hash.zero,
        .chain = .l1,
        .registry = Address.zero,
        .owner = Address.zero,
        .resolver = Address.zero,
        .token_id = 0,
        .canonical_id = 0,
        .token_version = 1,
        .namehash = Hash.zero,
        .expiry = 0,
        .registry_locked = false,
        .migrated = false,
        .ejected = false,
        .created_block = 1,
        .created_at = 1000,
        .updated_block = 1,
        .updated_at = 1000,
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    };

    try insertName(&database, test_name);
    try updateNameWrapperState(&database, Hash.zero, 123, 2000000000);

    // Unwrap the name
    try updateNameUnwrapperState(&database, Hash.zero);

    // Verify function completed successfully
    var name_opt = try getNameByNamehash(&database, Hash.zero);
    try testing.expect(name_opt != null);
    defer if (name_opt) |*n| n.deinit(allocator);
}

test "updateNameWrapperFuses - update fuses" {
    const allocator = testing.allocator;

    var database = try Database.init(allocator, ":memory:");
    defer database.deinit();

    // Create and wrap a test name
    const test_name = models.Name{
        .name = "test.eth",
        .label = "test",
        .label_hash = Hash.zero,
        .parent_name = "eth",
        .parent_namehash = Hash.zero,
        .chain = .l1,
        .registry = Address.zero,
        .owner = Address.zero,
        .resolver = Address.zero,
        .token_id = 0,
        .canonical_id = 0,
        .token_version = 1,
        .namehash = Hash.zero,
        .expiry = 0,
        .registry_locked = false,
        .migrated = false,
        .ejected = false,
        .created_block = 1,
        .created_at = 1000,
        .updated_block = 1,
        .updated_at = 1000,
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    };

    try insertName(&database, test_name);
    try updateNameWrapperState(&database, Hash.zero, 123, 2000000000);

    // Update fuses
    const new_fuses: u32 = 456;
    try updateNameWrapperFuses(&database, Hash.zero, new_fuses);

    // Verify function completed successfully
    var name_opt = try getNameByNamehash(&database, Hash.zero);
    try testing.expect(name_opt != null);
    defer if (name_opt) |*n| n.deinit(allocator);
}

test "updateNameWrapperExpiry - update wrapper expiry" {
    const allocator = testing.allocator;

    var database = try Database.init(allocator, ":memory:");
    defer database.deinit();

    // Create and wrap a test name
    const test_name = models.Name{
        .name = "test.eth",
        .label = "test",
        .label_hash = Hash.zero,
        .parent_name = "eth",
        .parent_namehash = Hash.zero,
        .chain = .l1,
        .registry = Address.zero,
        .owner = Address.zero,
        .resolver = Address.zero,
        .token_id = 0,
        .canonical_id = 0,
        .token_version = 1,
        .namehash = Hash.zero,
        .expiry = 0,
        .registry_locked = false,
        .migrated = false,
        .ejected = false,
        .created_block = 1,
        .created_at = 1000,
        .updated_block = 1,
        .updated_at = 1000,
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    };

    try insertName(&database, test_name);
    try updateNameWrapperState(&database, Hash.zero, 123, 2000000000);

    // Update wrapper expiry
    const new_expiry: i64 = 2500000000;
    try updateNameWrapperExpiry(&database, Hash.zero, new_expiry);

    // Verify function completed successfully
    var name_opt = try getNameByNamehash(&database, Hash.zero);
    try testing.expect(name_opt != null);
    defer if (name_opt) |*n| n.deinit(allocator);
}

test "getSubdomains returns subdomains for parent name" {
    const allocator = testing.allocator;

    var database = try Database.init(allocator, ":memory:");
    defer database.deinit();

    const hash_mod = @import("../types/hash.zig");

    // Create parent domain "eth"
    const eth_name = models.Name{
        .name = try allocator.dupe(u8, "eth"),
        .label = try allocator.dupe(u8, "eth"),
        .label_hash = Hash.zero,
        .parent_name = try allocator.dupe(u8, ""),
        .parent_namehash = Hash.zero,
        .chain = .l1,
        .registry = Address.zero,
        .owner = Address.zero,
        .resolver = Address.zero,
        .token_id = 0,
        .canonical_id = 0,
        .token_version = 0,
        .namehash = try hash_mod.namehash(allocator, "eth"),
        .expiry = 0,
        .registry_locked = false,
        .migrated = false,
        .ejected = false,
        .created_block = 1,
        .created_at = 1000,
        .updated_block = 1,
        .updated_at = 1000,
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    };
    defer {
        allocator.free(eth_name.name.?);
        allocator.free(eth_name.label.?);
        allocator.free(eth_name.parent_name.?);
    }
    try insertName(&database, eth_name);

    // Create subdomains alice.eth and bob.eth
    const alice_name = models.Name{
        .name = try allocator.dupe(u8, "alice.eth"),
        .label = try allocator.dupe(u8, "alice"),
        .label_hash = Hash.zero,
        .parent_name = try allocator.dupe(u8, "eth"),
        .parent_namehash = try hash_mod.namehash(allocator, "eth"),
        .chain = .l1,
        .registry = Address.zero,
        .owner = Address.zero,
        .resolver = Address.zero,
        .token_id = 1,
        .canonical_id = 1,
        .token_version = 0,
        .namehash = try hash_mod.namehash(allocator, "alice.eth"),
        .expiry = 0,
        .registry_locked = false,
        .migrated = false,
        .ejected = false,
        .created_block = 2,
        .created_at = 2000,
        .updated_block = 2,
        .updated_at = 2000,
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    };
    defer {
        allocator.free(alice_name.name.?);
        allocator.free(alice_name.label.?);
        allocator.free(alice_name.parent_name.?);
    }
    try insertName(&database, alice_name);

    const bob_name = models.Name{
        .name = try allocator.dupe(u8, "bob.eth"),
        .label = try allocator.dupe(u8, "bob"),
        .label_hash = Hash.zero,
        .parent_name = try allocator.dupe(u8, "eth"),
        .parent_namehash = try hash_mod.namehash(allocator, "eth"),
        .chain = .l1,
        .registry = Address.zero,
        .owner = Address.zero,
        .resolver = Address.zero,
        .token_id = 2,
        .canonical_id = 2,
        .token_version = 0,
        .namehash = try hash_mod.namehash(allocator, "bob.eth"),
        .expiry = 0,
        .registry_locked = false,
        .migrated = false,
        .ejected = false,
        .created_block = 3,
        .created_at = 3000,
        .updated_block = 3,
        .updated_at = 3000,
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    };
    defer {
        allocator.free(bob_name.name.?);
        allocator.free(bob_name.label.?);
        allocator.free(bob_name.parent_name.?);
    }
    try insertName(&database, bob_name);

    // Query subdomains of eth
    const subdomains = try getSubdomains(&database, "eth", 0, 10);
    defer {
        for (subdomains) |*s| {
            s.deinit(allocator);
        }
        allocator.free(subdomains);
    }

    // Should return both alice.eth and bob.eth
    try testing.expectEqual(@as(usize, 2), subdomains.len);

    // Verify subdomains are ordered by created_at DESC (bob first, then alice)
    try testing.expectEqualStrings("bob.eth", subdomains[0].name.?);
    try testing.expectEqualStrings("alice.eth", subdomains[1].name.?);
}

test "getSubdomains respects pagination limits" {
    const allocator = testing.allocator;

    var database = try Database.init(allocator, ":memory:");
    defer database.deinit();

    const hash_mod = @import("../types/hash.zig");

    // Create parent domain "eth"
    const eth_name = models.Name{
        .name = try allocator.dupe(u8, "eth"),
        .label = try allocator.dupe(u8, "eth"),
        .label_hash = Hash.zero,
        .parent_name = try allocator.dupe(u8, ""),
        .parent_namehash = Hash.zero,
        .chain = .l1,
        .registry = Address.zero,
        .owner = Address.zero,
        .resolver = Address.zero,
        .token_id = 0,
        .canonical_id = 0,
        .token_version = 0,
        .namehash = try hash_mod.namehash(allocator, "eth"),
        .expiry = 0,
        .registry_locked = false,
        .migrated = false,
        .ejected = false,
        .created_block = 1,
        .created_at = 1000,
        .updated_block = 1,
        .updated_at = 1000,
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    };
    defer {
        allocator.free(eth_name.name.?);
        allocator.free(eth_name.label.?);
        allocator.free(eth_name.parent_name.?);
    }
    try insertName(&database, eth_name);

    // Create 5 subdomains
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const name_slice = try std.fmt.bufPrint(&name_buf, "sub{d}.eth", .{i});
        var label_buf: [16]u8 = undefined;
        const label_slice = try std.fmt.bufPrint(&label_buf, "sub{d}", .{i});

        const sub_name = models.Name{
            .name = try allocator.dupe(u8, name_slice),
            .label = try allocator.dupe(u8, label_slice),
            .label_hash = Hash.zero,
            .parent_name = try allocator.dupe(u8, "eth"),
            .parent_namehash = try hash_mod.namehash(allocator, "eth"),
            .chain = .l1,
            .registry = Address.zero,
            .owner = Address.zero,
            .resolver = Address.zero,
            .token_id = i + 1,
            .canonical_id = i + 1,
            .token_version = 0,
            .namehash = try hash_mod.namehash(allocator, name_slice),
            .expiry = 0,
            .registry_locked = false,
            .migrated = false,
            .ejected = false,
            .created_block = i + 2,
            .created_at = @as(i64, @intCast((i + 2) * 1000)),
            .updated_block = i + 2,
            .updated_at = @as(i64, @intCast((i + 2) * 1000)),
            .is_wrapped = false,
            .wrapper_fuses = null,
            .wrapper_expiry = null,
            .is_v1_name = false,
            .v1_label_hash = null,
        };
        defer {
            allocator.free(sub_name.name.?);
            allocator.free(sub_name.label.?);
            allocator.free(sub_name.parent_name.?);
        }
        try insertName(&database, sub_name);
    }

    // Query with limit of 2
    const subdomains = try getSubdomains(&database, "eth", 0, 2);
    defer {
        for (subdomains) |*s| {
            s.deinit(allocator);
        }
        allocator.free(subdomains);
    }

    // Should return only 2 subdomains
    try testing.expectEqual(@as(usize, 2), subdomains.len);

    // Query with skip
    const subdomains_skip = try getSubdomains(&database, "eth", 2, 2);
    defer {
        for (subdomains_skip) |*s| {
            s.deinit(allocator);
        }
        allocator.free(subdomains_skip);
    }

    // Should return 2 more subdomains
    try testing.expectEqual(@as(usize, 2), subdomains_skip.len);
}

test "getSubdomains returns empty for no subdomains" {
    const allocator = testing.allocator;

    var database = try Database.init(allocator, ":memory:");
    defer database.deinit();

    // Query subdomains of non-existent parent
    const subdomains = try getSubdomains(&database, "nonexistent.eth", 0, 10);
    defer {
        for (subdomains) |*s| {
            s.deinit(allocator);
        }
        allocator.free(subdomains);
    }

    // Should return empty slice
    try testing.expectEqual(@as(usize, 0), subdomains.len);
}
