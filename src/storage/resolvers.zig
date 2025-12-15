const std = @import("std");
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
// RESOLVER OPERATIONS (8 functions)
// ============================================================================

pub fn storeResolverAddress(
    db: *Database,
    namehash: Hash,
    resolver: Address,
    coin_type: u64,
    address: []const u8,
    chain: models.Chain,
    block_number: u64,
    tx_hash: Hash,
    timestamp: i64,
) !void {
    const sql =
        \\INSERT OR REPLACE INTO resolver_addresses
        \\  (namehash, resolver, coin_type, address, chain, block_number, transaction_hash, timestamp, context)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)
    ;

    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    defer {
        if (stmt) |s| _ = c.sqlite3_finalize(s);
    }

    if (c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) {
        std.log.err("Failed to prepare resolver address SQL: {s}", .{c.sqlite3_errmsg(db.db)});
        std.log.err("SQL was: {s}", .{sql});
        return error.PrepareFailed;
    }

    const namehash_str = try namehash.toHex(db.allocator);
    defer db.allocator.free(namehash_str);

    const resolver_str = try resolver.toHex(db.allocator);
    defer db.allocator.free(resolver_str);

    const chain_str = chain.toString();

    const tx_hash_str = try tx_hash.toHex(db.allocator);
    defer db.allocator.free(tx_hash_str);

    _ = c.sqlite3_bind_text(stmt, 1, namehash_str.ptr, @intCast(namehash_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 2, resolver_str.ptr, @intCast(resolver_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 3, @intCast(coin_type));
    _ = c.sqlite3_bind_text(stmt, 4, address.ptr, @intCast(address.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 5, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 6, @intCast(block_number));
    _ = c.sqlite3_bind_text(stmt, 7, tx_hash_str.ptr, @intCast(tx_hash_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 8, timestamp);

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        return error.StoreFailed;
    }
}

/// Store resolver content hash (from ContentHashChanged event)
pub fn storeResolverContentHash(
    db: *Database,
    namehash: Hash,
    resolver: Address,
    content_hash: []const u8,
    chain: models.Chain,
    block_number: u64,
    tx_hash: Hash,
    timestamp: i64,
) !void {
    const sql =
        \\INSERT OR REPLACE INTO resolver_contenthashes
        \\  (namehash, resolver, contenthash, chain, block_number, transaction_hash, timestamp)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    defer {
        if (stmt) |s| _ = c.sqlite3_finalize(s);
    }

    if (c.sqlite3_prepare_v2(db.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
        return error.PrepareFailed;
    }

    const namehash_str = try namehash.toHex(db.allocator);
    defer db.allocator.free(namehash_str);

    const resolver_str = try resolver.toHex(db.allocator);
    defer db.allocator.free(resolver_str);

    const chain_str = chain.toString();

    const tx_hash_str = try tx_hash.toHex(db.allocator);
    defer db.allocator.free(tx_hash_str);

    _ = c.sqlite3_bind_text(stmt, 1, namehash_str.ptr, @intCast(namehash_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 2, resolver_str.ptr, @intCast(resolver_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 3, content_hash.ptr, @intCast(content_hash.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 4, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 5, @intCast(block_number));
    _ = c.sqlite3_bind_text(stmt, 6, tx_hash_str.ptr, @intCast(tx_hash_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 7, timestamp);

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        return error.StoreFailed;
    }
}

/// Store resolver text record (from TextChanged event)
pub fn storeResolverText(
    db: *Database,
    namehash: Hash,
    resolver: Address,
    key: []const u8,
    value: []const u8,
    chain: models.Chain,
    block_number: u64,
    tx_hash: Hash,
    timestamp: i64,
) !void {
    const sql =
        \\INSERT OR REPLACE INTO resolver_texts
        \\  (namehash, resolver, key, value, chain, block_number, transaction_hash, timestamp)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    defer {
        if (stmt) |s| _ = c.sqlite3_finalize(s);
    }

    if (c.sqlite3_prepare_v2(db.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
        return error.PrepareFailed;
    }

    const namehash_str = try namehash.toHex(db.allocator);
    defer db.allocator.free(namehash_str);

    const resolver_str = try resolver.toHex(db.allocator);
    defer db.allocator.free(resolver_str);

    const chain_str = chain.toString();

    const tx_hash_str = try tx_hash.toHex(db.allocator);
    defer db.allocator.free(tx_hash_str);

    _ = c.sqlite3_bind_text(stmt, 1, namehash_str.ptr, @intCast(namehash_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 2, resolver_str.ptr, @intCast(resolver_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 3, key.ptr, @intCast(key.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 4, value.ptr, @intCast(value.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 5, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 6, @intCast(block_number));
    _ = c.sqlite3_bind_text(stmt, 7, tx_hash_str.ptr, @intCast(tx_hash_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 8, timestamp);

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        return error.StoreFailed;
    }
}

/// Get the latest address record for a namehash (coin type 60 = ETH)
pub fn getResolverAddress(db: *Database, namehash: Hash, coin_type: u64) !?[]u8 {
    const sql =
        \\SELECT address FROM resolver_addresses
        \\WHERE namehash = ? AND coin_type = ?
        \\ORDER BY block_number DESC
        \\LIMIT 1
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    defer {
        if (stmt) |s| _ = c.sqlite3_finalize(s);
    }

    if (c.sqlite3_prepare_v2(db.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
        return error.PrepareFailed;
    }

    const namehash_str = try namehash.toHex(db.allocator);
    defer db.allocator.free(namehash_str);

    _ = c.sqlite3_bind_text(stmt, 1, namehash_str.ptr, @intCast(namehash_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 2, @intCast(coin_type));

    if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const addr_text = c.sqlite3_column_text(stmt, 0);
        if (addr_text != null) {
            const addr_len = c.sqlite3_column_bytes(stmt, 0);
            const addr_slice = addr_text[0..@intCast(addr_len)];
            return try db.allocator.dupe(u8, addr_slice);
        }
    }

    return null;
}

/// Get all addresses for a namehash (all coin types)
/// Returns array of (coin_type, address) pairs
pub const CoinAddress = struct {
    coin_type: u64,
    address: []u8,

    pub fn deinit(self: *CoinAddress, allocator: std.mem.Allocator) void {
        allocator.free(self.address);
    }
};

pub fn getResolverAllAddresses(db: *Database, namehash: Hash) ![]CoinAddress {
    const sql =
        \\SELECT coin_type, address FROM resolver_addresses
        \\WHERE namehash = ?
        \\ORDER BY coin_type
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    defer {
        if (stmt) |s| _ = c.sqlite3_finalize(s);
    }

    if (c.sqlite3_prepare_v2(db.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
        return error.PrepareFailed;
    }

    const namehash_str = try namehash.toHex(db.allocator);
    defer db.allocator.free(namehash_str);

    _ = c.sqlite3_bind_text(stmt, 1, namehash_str.ptr, @intCast(namehash_str.len), SQLITE_TRANSIENT());

    var addresses: std.ArrayList(CoinAddress) = .{};
    errdefer {
        for (addresses.items) |*addr| {
            addr.deinit(db.allocator);
        }
        addresses.deinit(db.allocator);
    }

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const coin_type: u64 = @intCast(c.sqlite3_column_int64(stmt, 0));
        const addr_text = c.sqlite3_column_text(stmt, 1);
        if (addr_text != null) {
            const addr_len = c.sqlite3_column_bytes(stmt, 1);
            const addr_slice = addr_text[0..@intCast(addr_len)];
            const coin_addr = CoinAddress{
                .coin_type = coin_type,
                .address = try db.allocator.dupe(u8, addr_slice),
            };
            try addresses.append(db.allocator, coin_addr);
        }
    }

    return addresses.toOwnedSlice(db.allocator);
}

/// Get the latest content hash for a namehash
pub fn getResolverContentHash(db: *Database, namehash: Hash) !?[]u8 {
    const sql =
        \\SELECT contenthash FROM resolver_contenthashes
        \\WHERE namehash = ?
        \\ORDER BY block_number DESC
        \\LIMIT 1
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    defer {
        if (stmt) |s| _ = c.sqlite3_finalize(s);
    }

    if (c.sqlite3_prepare_v2(db.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
        return error.PrepareFailed;
    }

    const namehash_str = try namehash.toHex(db.allocator);
    defer db.allocator.free(namehash_str);

    _ = c.sqlite3_bind_text(stmt, 1, namehash_str.ptr, @intCast(namehash_str.len), SQLITE_TRANSIENT());

    if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const hash_text = c.sqlite3_column_text(stmt, 0);
        if (hash_text != null) {
            const hash_len = c.sqlite3_column_bytes(stmt, 0);
            const hash_slice = hash_text[0..@intCast(hash_len)];
            return try db.allocator.dupe(u8, hash_slice);
        }
    }

    return null;
}

/// Get all text records for a namehash (returns list of keys)
pub fn getResolverTextKeys(db: *Database, namehash: Hash) ![][]u8 {
    const sql =
        \\SELECT DISTINCT key FROM resolver_texts
        \\WHERE namehash = ?
        \\ORDER BY key
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    defer {
        if (stmt) |s| _ = c.sqlite3_finalize(s);
    }

    if (c.sqlite3_prepare_v2(db.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
        return error.PrepareFailed;
    }

    const namehash_str = try namehash.toHex(db.allocator);
    defer db.allocator.free(namehash_str);

    _ = c.sqlite3_bind_text(stmt, 1, namehash_str.ptr, @intCast(namehash_str.len), SQLITE_TRANSIENT());

    var keys: std.ArrayList([]u8) = .{};
    errdefer {
        for (keys.items) |key| {
            db.allocator.free(key);
        }
        keys.deinit(db.allocator);
    }

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const key_text = c.sqlite3_column_text(stmt, 0);
        if (key_text != null) {
            const key_len = c.sqlite3_column_bytes(stmt, 0);
            const key_slice = key_text[0..@intCast(key_len)];
            const key_copy = try db.allocator.dupe(u8, key_slice);
            try keys.append(db.allocator, key_copy);
        }
    }

    return keys.toOwnedSlice(db.allocator);
}

/// Get a specific text record value for a namehash and key
pub fn getResolverText(db: *Database, namehash: Hash, key: []const u8) !?[]u8 {
    const sql =
        \\SELECT value FROM resolver_texts
        \\WHERE namehash = ? AND key = ?
        \\ORDER BY block_number DESC
        \\LIMIT 1
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    defer {
        if (stmt) |s| _ = c.sqlite3_finalize(s);
    }

    if (c.sqlite3_prepare_v2(db.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
        return error.PrepareFailed;
    }

    const namehash_str = try namehash.toHex(db.allocator);
    defer db.allocator.free(namehash_str);

    _ = c.sqlite3_bind_text(stmt, 1, namehash_str.ptr, @intCast(namehash_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 2, key.ptr, @intCast(key.len), SQLITE_TRANSIENT());

    if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const value_text = c.sqlite3_column_text(stmt, 0);
        if (value_text != null) {
            const value_len = c.sqlite3_column_bytes(stmt, 0);
            const value_slice = value_text[0..@intCast(value_len)];
            return try db.allocator.dupe(u8, value_slice);
        }
    }

    return null;
}

/// Get all text record keys for a resolver address (for V2 names)
/// NOTE: V2 names have different namehashes than V1 resolver events, so we
/// must look up by resolver address to find text records for V2 names.
pub fn getResolverTextKeysByResolver(db: *Database, resolver: Address) ![][]u8 {
    const sql =
        \\SELECT DISTINCT key FROM resolver_texts
        \\WHERE resolver = ?
        \\ORDER BY key
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    defer {
        if (stmt) |s| _ = c.sqlite3_finalize(s);
    }

    if (c.sqlite3_prepare_v2(db.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
        return error.PrepareFailed;
    }

    const resolver_str = try resolver.toHex(db.allocator);
    defer db.allocator.free(resolver_str);

    _ = c.sqlite3_bind_text(stmt, 1, resolver_str.ptr, @intCast(resolver_str.len), SQLITE_TRANSIENT());

    var keys: std.ArrayList([]u8) = .{};
    errdefer {
        for (keys.items) |key| {
            db.allocator.free(key);
        }
        keys.deinit(db.allocator);
    }

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const key_text = c.sqlite3_column_text(stmt, 0);
        if (key_text != null) {
            const key_len = c.sqlite3_column_bytes(stmt, 0);
            const key_slice = key_text[0..@intCast(key_len)];
            const key_copy = try db.allocator.dupe(u8, key_slice);
            try keys.append(db.allocator, key_copy);
        }
    }

    return keys.toOwnedSlice(db.allocator);
}

/// Get a specific text record value by resolver address and key (for V2 names)
pub fn getResolverTextByResolver(db: *Database, resolver: Address, key: []const u8) !?[]u8 {
    const sql =
        \\SELECT value FROM resolver_texts
        \\WHERE resolver = ? AND key = ?
        \\ORDER BY block_number DESC
        \\LIMIT 1
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    defer {
        if (stmt) |s| _ = c.sqlite3_finalize(s);
    }

    if (c.sqlite3_prepare_v2(db.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
        return error.PrepareFailed;
    }

    const resolver_str = try resolver.toHex(db.allocator);
    defer db.allocator.free(resolver_str);

    _ = c.sqlite3_bind_text(stmt, 1, resolver_str.ptr, @intCast(resolver_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 2, key.ptr, @intCast(key.len), SQLITE_TRANSIENT());

    if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const value_text = c.sqlite3_column_text(stmt, 0);
        if (value_text != null) {
            const value_len = c.sqlite3_column_bytes(stmt, 0);
            const value_slice = value_text[0..@intCast(value_len)];
            return try db.allocator.dupe(u8, value_slice);
        }
    }

    return null;
}

/// Get resolvers to index for a block range
/// Uses cache table for O(1) lookup, falls back to full scan on first run
pub fn getResolversToIndex(db: *Database, chain: models.Chain, from_block: u64, to_block: u64) ![][]u8 {
    // First, discover any NEW resolvers from names table (only those set in this block range)
    const discover_sql =
        \\SELECT DISTINCT n.resolver
        \\FROM names n
        \\LEFT JOIN known_resolvers kr ON kr.chain = n.chain AND kr.address = n.resolver
        \\WHERE n.chain = ?
        \\  AND n.resolver != '0x0000000000000000000000000000000000000000'
        \\  AND n.created_block >= ?
        \\  AND n.created_block <= ?
        \\  AND kr.address IS NULL
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    defer {
        if (stmt) |s| _ = c.sqlite3_finalize(s);
    }

    if (c.sqlite3_prepare_v2(db.db, discover_sql, -1, &stmt, null) != c.SQLITE_OK) {
        return error.PrepareFailed;
    }

    const chain_str = chain.toString();
    _ = c.sqlite3_bind_text(stmt, 1, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 2, @intCast(from_block));
    _ = c.sqlite3_bind_int64(stmt, 3, @intCast(to_block));

    // Register newly discovered resolvers
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const addr_text = c.sqlite3_column_text(stmt, 0);
        if (addr_text != null) {
            const addr_len = c.sqlite3_column_bytes(stmt, 0);
            const addr_slice = addr_text[0..@intCast(addr_len)];
            try db.registerResolver(chain, addr_slice, from_block);
        }
    }
    _ = c.sqlite3_finalize(stmt);

    // Now get ALL known resolvers from cache (very fast)
    const get_sql =
        \\SELECT address FROM known_resolvers
        \\WHERE chain = ?
        \\ORDER BY address
    ;

    if (c.sqlite3_prepare_v2(db.db, get_sql, -1, &stmt, null) != c.SQLITE_OK) {
        return error.PrepareFailed;
    }

    _ = c.sqlite3_bind_text(stmt, 1, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());

    var resolvers: std.ArrayList([]u8) = .{};
    errdefer {
        for (resolvers.items) |resolver| {
            db.allocator.free(resolver);
        }
        resolvers.deinit(db.allocator);
    }

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const addr_text = c.sqlite3_column_text(stmt, 0);
        if (addr_text != null) {
            const addr_len = c.sqlite3_column_bytes(stmt, 0);
            const addr_slice = addr_text[0..@intCast(addr_len)];
            const addr_copy = try db.allocator.dupe(u8, addr_slice);
            try resolvers.append(db.allocator, addr_copy);
        }
    }

    return resolvers.toOwnedSlice(db.allocator);
}

/// Get all distinct resolver addresses set on domains owned by an account
pub fn getResolversByOwner(db: *Database, chain: models.Chain, owner: Address) ![]models.Resolver {
    const sql =
        \\SELECT DISTINCT n.resolver, n.name, n.namehash, n.created_block, n.created_at
        \\FROM names n
        \\WHERE n.chain = ? AND n.owner = ? AND n.resolver != '0x0000000000000000000000000000000000000000'
        \\ORDER BY n.created_at DESC
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

    var result: std.ArrayList(models.Resolver) = .{};
    errdefer {
        for (result.items) |*r| {
            r.deinit(db.allocator);
        }
        result.deinit(db.allocator);
    }

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const resolver_hex = std.mem.span(c.sqlite3_column_text(stmt, 0));
        const name_str = std.mem.span(c.sqlite3_column_text(stmt, 1));
        const namehash_hex = std.mem.span(c.sqlite3_column_text(stmt, 2));

        const resolver = models.Resolver{
            .chain = chain,
            .address = try Address.fromHex(resolver_hex),
            .name = try db.allocator.dupe(u8, name_str),
            .namehash = try Hash.fromHex(namehash_hex),
            .set_block = @intCast(c.sqlite3_column_int64(stmt, 3)),
            .set_at = c.sqlite3_column_int64(stmt, 4),
        };

        try result.append(db.allocator, resolver);
    }

    return result.toOwnedSlice(db.allocator);
}
