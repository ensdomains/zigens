const std = @import("std");
const db_module = @import("database.zig");
const Database = db_module.Database;
const Query = db_module.Query;
const models = @import("../types/models.zig");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;

// ============================================================================
// RESOLVER OPERATIONS
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

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindHash(namehash);
    try q.bindAddress(resolver);
    try q.bindInt64(@intCast(coin_type));
    try q.bindText(address);
    try q.bindTextStatic(chain.toString());
    try q.bindInt64(@intCast(block_number));
    try q.bindHash(tx_hash);
    try q.bindInt64(timestamp);

    try q.exec();
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

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindHash(namehash);
    try q.bindAddress(resolver);
    try q.bindText(content_hash);
    try q.bindTextStatic(chain.toString());
    try q.bindInt64(@intCast(block_number));
    try q.bindHash(tx_hash);
    try q.bindInt64(timestamp);

    try q.exec();
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

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindHash(namehash);
    try q.bindAddress(resolver);
    try q.bindText(key);
    try q.bindText(value);
    try q.bindTextStatic(chain.toString());
    try q.bindInt64(@intCast(block_number));
    try q.bindHash(tx_hash);
    try q.bindInt64(timestamp);

    try q.exec();
}

/// Get the latest address record for a namehash (coin type 60 = ETH)
pub fn getResolverAddress(db: *Database, namehash: Hash, coin_type: u64) !?[]u8 {
    const sql =
        \\SELECT address FROM resolver_addresses
        \\WHERE namehash = ? AND coin_type = ?
        \\ORDER BY block_number DESC
        \\LIMIT 1
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindHash(namehash);
    try q.bindInt64(@intCast(coin_type));

    if (try q.step()) {
        return try q.getText(0);
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

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindHash(namehash);

    var addresses: std.ArrayList(CoinAddress) = .{};
    errdefer {
        for (addresses.items) |*addr| {
            addr.deinit(db.allocator);
        }
        addresses.deinit(db.allocator);
    }

    while (try q.step()) {
        const coin_type: u64 = @intCast(q.getInt64(0));
        if (try q.getText(1)) |addr| {
            const coin_addr = CoinAddress{
                .coin_type = coin_type,
                .address = addr,
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

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindHash(namehash);

    if (try q.step()) {
        return try q.getText(0);
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

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindHash(namehash);

    var keys: std.ArrayList([]u8) = .{};
    errdefer {
        for (keys.items) |key| {
            db.allocator.free(key);
        }
        keys.deinit(db.allocator);
    }

    while (try q.step()) {
        if (try q.getText(0)) |key| {
            try keys.append(db.allocator, key);
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

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindHash(namehash);
    try q.bindText(key);

    if (try q.step()) {
        return try q.getText(0);
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

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindAddress(resolver);

    var keys: std.ArrayList([]u8) = .{};
    errdefer {
        for (keys.items) |key| {
            db.allocator.free(key);
        }
        keys.deinit(db.allocator);
    }

    while (try q.step()) {
        if (try q.getText(0)) |key| {
            try keys.append(db.allocator, key);
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

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindAddress(resolver);
    try q.bindText(key);

    if (try q.step()) {
        return try q.getText(0);
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

    const chain_str = chain.toString();

    {
        var q = try Query.init(db, discover_sql);
        defer q.deinit();

        try q.bindTextStatic(chain_str);
        try q.bindInt64(@intCast(from_block));
        try q.bindInt64(@intCast(to_block));

        // Register newly discovered resolvers
        while (try q.step()) {
            if (q.getTextSlice(0)) |addr_slice| {
                try db.registerResolver(chain, addr_slice, from_block);
            }
        }
    }

    // Now get ALL known resolvers from cache (very fast)
    const get_sql =
        \\SELECT address FROM known_resolvers
        \\WHERE chain = ?
        \\ORDER BY address
    ;

    var q2 = try Query.init(db, get_sql);
    defer q2.deinit();

    try q2.bindTextStatic(chain_str);

    var resolvers: std.ArrayList([]u8) = .{};
    errdefer {
        for (resolvers.items) |resolver| {
            db.allocator.free(resolver);
        }
        resolvers.deinit(db.allocator);
    }

    while (try q2.step()) {
        if (try q2.getText(0)) |addr| {
            try resolvers.append(db.allocator, addr);
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

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindTextStatic(chain.toString());
    try q.bindAddress(owner);

    var result: std.ArrayList(models.Resolver) = .{};
    errdefer {
        for (result.items) |*r| {
            r.deinit(db.allocator);
        }
        result.deinit(db.allocator);
    }

    while (try q.step()) {
        const resolver_addr = try q.getAddress(0) orelse continue;
        const name_str = q.getTextSlice(1) orelse continue;
        const namehash_val = try q.getHash(2) orelse continue;

        const resolver = models.Resolver{
            .chain = chain,
            .address = resolver_addr,
            .name = try db.allocator.dupe(u8, name_str),
            .namehash = namehash_val,
            .set_block = @intCast(q.getInt64(3)),
            .set_at = q.getInt64(4),
        };

        try result.append(db.allocator, resolver);
    }

    return result.toOwnedSlice(db.allocator);
}
