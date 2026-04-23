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

pub const CoinAddress = struct {
    coin_type: u64,
    address: []u8,

    pub fn deinit(self: *CoinAddress, allocator: std.mem.Allocator) void {
        allocator.free(self.address);
    }
};

/// Latest addr record for a given (resolver, namehash, coin_type).
/// Scoped to the currently authoritative resolver so records set by a legacy
/// resolver on a migrated name don't leak through.
pub fn getAddressRecord(db: *Database, resolver: Address, namehash: Hash, coin_type: u64) !?[]u8 {
    const sql =
        \\SELECT address FROM resolver_addresses
        \\WHERE resolver = ? AND namehash = ? AND coin_type = ?
        \\ORDER BY block_number DESC
        \\LIMIT 1
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindAddress(resolver);
    try q.bindHash(namehash);
    try q.bindInt64(@intCast(coin_type));

    if (try q.step()) {
        return try q.getText(0);
    }
    return null;
}

/// All multi-coin addr records for a given (resolver, namehash).
/// Scoped to the currently authoritative resolver — same reason as getAddressRecord.
pub fn getAddressRecords(db: *Database, resolver: Address, namehash: Hash) ![]CoinAddress {
    const sql =
        \\SELECT coin_type, address FROM resolver_addresses
        \\WHERE resolver = ? AND namehash = ?
        \\ORDER BY coin_type
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindAddress(resolver);
    try q.bindHash(namehash);
    return try readCoinAddresses(db, &q);
}

fn readCoinAddresses(db: *Database, q: *Query) ![]CoinAddress {

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

/// Latest contenthash record for (resolver, namehash).
/// Scoped to the given resolver so a migrated name doesn't surface its legacy V1 value.
pub fn getContentHashRecord(db: *Database, resolver: Address, namehash: Hash) !?[]u8 {
    const sql =
        \\SELECT contenthash FROM resolver_contenthashes
        \\WHERE resolver = ? AND namehash = ?
        \\ORDER BY block_number DESC
        \\LIMIT 1
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindAddress(resolver);
    try q.bindHash(namehash);

    if (try q.step()) {
        return try q.getText(0);
    }
    return null;
}

/// All text record keys set by (resolver, namehash).
pub fn getTextRecordKeys(db: *Database, resolver: Address, namehash: Hash) ![][]u8 {
    const sql =
        \\SELECT DISTINCT key FROM resolver_texts
        \\WHERE resolver = ? AND namehash = ?
        \\ORDER BY key
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindAddress(resolver);
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

/// Latest text record value for (resolver, namehash, key).
pub fn getTextRecord(db: *Database, resolver: Address, namehash: Hash, key: []const u8) !?[]u8 {
    const sql =
        \\SELECT value FROM resolver_texts
        \\WHERE resolver = ? AND namehash = ? AND key = ?
        \\ORDER BY block_number DESC
        \\LIMIT 1
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindAddress(resolver);
    try q.bindHash(namehash);
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

/// Result from resolver discovery: all known resolvers + any newly discovered ones
pub const ResolverDiscoveryResult = struct {
    all: [][]u8,
    newly_discovered: [][]u8,

    pub fn deinit(self: *ResolverDiscoveryResult, allocator: std.mem.Allocator) void {
        for (self.all) |r| allocator.free(r);
        allocator.free(self.all);
        for (self.newly_discovered) |r| allocator.free(r);
        allocator.free(self.newly_discovered);
    }
};

/// Get resolvers to index, also returning which ones were newly discovered in this block range.
/// Newly discovered resolvers need their historical events backfilled.
pub fn discoverAndGetResolvers(db: *Database, chain: models.Chain, from_block: u64, to_block: u64) !ResolverDiscoveryResult {
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

    var new_resolvers: std.ArrayList([]u8) = .{};
    errdefer {
        for (new_resolvers.items) |r| db.allocator.free(r);
        new_resolvers.deinit(db.allocator);
    }

    {
        var q = try Query.init(db, discover_sql);
        defer q.deinit();

        try q.bindTextStatic(chain_str);
        try q.bindInt64(@intCast(from_block));
        try q.bindInt64(@intCast(to_block));

        while (try q.step()) {
            if (q.getTextSlice(0)) |addr_slice| {
                try db.registerResolver(chain, addr_slice, from_block);
                const copy = try db.allocator.dupe(u8, addr_slice);
                try new_resolvers.append(db.allocator, copy);
            }
        }
    }

    // Get ALL known resolvers from cache
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
        for (resolvers.items) |r| db.allocator.free(r);
        resolvers.deinit(db.allocator);
    }

    while (try q2.step()) {
        if (try q2.getText(0)) |addr| {
            try resolvers.append(db.allocator, addr);
        }
    }

    return .{
        .all = try resolvers.toOwnedSlice(db.allocator),
        .newly_discovered = try new_resolvers.toOwnedSlice(db.allocator),
    };
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

// ============================================================================
// DELETE OPERATIONS (for VersionChanged record clearing)
// ============================================================================

pub fn deleteResolverAddresses(db: *Database, namehash: Hash) !void {
    const sql = "DELETE FROM resolver_addresses WHERE namehash = ?";
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindHash(namehash);
    try q.exec();
}

pub fn deleteResolverContentHash(db: *Database, namehash: Hash) !void {
    const sql = "DELETE FROM resolver_contenthashes WHERE namehash = ?";
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindHash(namehash);
    try q.exec();
}

pub fn deleteResolverTexts(db: *Database, namehash: Hash) !void {
    const sql = "DELETE FROM resolver_texts WHERE namehash = ?";
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindHash(namehash);
    try q.exec();
}

pub fn deleteResolverAlias(db: *Database, resolver: Address, from_name: []const u8) !void {
    const sql = "DELETE FROM resolver_aliases WHERE resolver = ? AND from_name = ?";
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindAddress(resolver);
    try q.bindText(from_name);
    try q.exec();
}

pub fn deleteResolverPubkeys(db: *Database, namehash: Hash) !void {
    const sql = "DELETE FROM resolver_pubkeys WHERE namehash = ?";
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindHash(namehash);
    try q.exec();
}

pub fn deleteResolverAbis(db: *Database, namehash: Hash) !void {
    const sql = "DELETE FROM resolver_abis WHERE namehash = ?";
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindHash(namehash);
    try q.exec();
}

pub fn deleteResolverNames(db: *Database, namehash: Hash) !void {
    const sql = "DELETE FROM resolver_names WHERE namehash = ?";
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindHash(namehash);
    try q.exec();
}

pub fn deleteResolverInterfaces(db: *Database, namehash: Hash) !void {
    const sql = "DELETE FROM resolver_interfaces WHERE namehash = ?";
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindHash(namehash);
    try q.exec();
}

// ============================================================================
// STORE OPERATIONS (for new record types)
// ============================================================================

pub fn storeResolverAlias(
    db: *Database,
    resolver: Address,
    from_name: []const u8,
    to_name: []const u8,
    chain: models.Chain,
    block_number: u64,
    tx_hash: Hash,
    timestamp: i64,
) !void {
    const sql =
        \\INSERT OR REPLACE INTO resolver_aliases
        \\  (resolver, from_name, to_name, chain, block_number, transaction_hash, timestamp)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindAddress(resolver);
    try q.bindText(from_name);
    try q.bindText(to_name);
    try q.bindTextStatic(chain.toString());
    try q.bindInt64(@intCast(block_number));
    try q.bindHash(tx_hash);
    try q.bindInt64(timestamp);

    try q.exec();
}

pub const AliasRecord = struct {
    from_name: []u8,
    to_name: []u8,

    pub fn deinit(self: *AliasRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.from_name);
        allocator.free(self.to_name);
    }
};

pub fn getResolverAliases(db: *Database, resolver: Address) ![]AliasRecord {
    const sql =
        \\SELECT from_name, to_name FROM resolver_aliases
        \\WHERE resolver = ?
        \\ORDER BY from_name
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindAddress(resolver);

    var records: std.ArrayList(AliasRecord) = .{};
    errdefer {
        for (records.items) |*r| r.deinit(db.allocator);
        records.deinit(db.allocator);
    }

    while (try q.step()) {
        const from = try q.getText(0) orelse continue;
        const to = q.getText(1) catch {
            db.allocator.free(from);
            continue;
        } orelse {
            db.allocator.free(from);
            continue;
        };
        try records.append(db.allocator, AliasRecord{
            .from_name = from,
            .to_name = to,
        });
    }

    return records.toOwnedSlice(db.allocator);
}

pub const PubkeyRecord = struct {
    x: []u8,
    y: []u8,

    pub fn deinit(self: *PubkeyRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.x);
        allocator.free(self.y);
    }
};

/// Pubkey record (x, y) for (resolver, namehash).
pub fn getPubkeyRecord(db: *Database, resolver: Address, namehash_val: Hash) !?PubkeyRecord {
    const sql =
        \\SELECT x, y FROM resolver_pubkeys
        \\WHERE resolver = ? AND namehash = ?
        \\LIMIT 1
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindAddress(resolver);
    try q.bindHash(namehash_val);

    if (try q.step()) {
        const x = try q.getText(0) orelse return null;
        const y = q.getText(1) catch {
            db.allocator.free(x);
            return null;
        } orelse {
            db.allocator.free(x);
            return null;
        };
        return PubkeyRecord{ .x = x, .y = y };
    }
    return null;
}

/// ABI content-type ids present for (resolver, namehash).
pub fn getAbiContentTypes(db: *Database, resolver: Address, namehash_val: Hash) ![]u64 {
    const sql =
        \\SELECT content_type FROM resolver_abis
        \\WHERE resolver = ? AND namehash = ?
        \\ORDER BY content_type
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindAddress(resolver);
    try q.bindHash(namehash_val);

    var types: std.ArrayList(u64) = .{};
    errdefer types.deinit(db.allocator);

    while (try q.step()) {
        try types.append(db.allocator, @intCast(q.getInt64(0)));
    }

    return types.toOwnedSlice(db.allocator);
}

/// Reverse-name record (name() on the resolver) for (resolver, namehash).
pub fn getReverseNameRecord(db: *Database, resolver: Address, namehash_val: Hash) !?[]u8 {
    const sql =
        \\SELECT name FROM resolver_names
        \\WHERE resolver = ? AND namehash = ?
        \\LIMIT 1
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindAddress(resolver);
    try q.bindHash(namehash_val);

    if (try q.step()) {
        return try q.getText(0);
    }
    return null;
}

pub const InterfaceRecord = struct {
    interface_id: []u8,
    implementer: []u8,

    pub fn deinit(self: *InterfaceRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.interface_id);
        allocator.free(self.implementer);
    }
};

/// Interface records (interfaceImplementer entries) for (resolver, namehash).
pub fn getInterfaceRecords(db: *Database, resolver: Address, namehash_val: Hash) ![]InterfaceRecord {
    const sql =
        \\SELECT interface_id, implementer FROM resolver_interfaces
        \\WHERE resolver = ? AND namehash = ?
        \\ORDER BY interface_id
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindAddress(resolver);
    try q.bindHash(namehash_val);

    var records: std.ArrayList(InterfaceRecord) = .{};
    errdefer {
        for (records.items) |*r| r.deinit(db.allocator);
        records.deinit(db.allocator);
    }

    while (try q.step()) {
        const iface_id = try q.getText(0) orelse continue;
        const implementer = q.getText(1) catch {
            db.allocator.free(iface_id);
            continue;
        } orelse {
            db.allocator.free(iface_id);
            continue;
        };
        try records.append(db.allocator, InterfaceRecord{
            .interface_id = iface_id,
            .implementer = implementer,
        });
    }

    return records.toOwnedSlice(db.allocator);
}

/// Per-node record version (PublicResolver's `recordVersions[node]`) for (resolver, namehash).
/// This is a node-scoped counter used to invalidate all records at once — not a
/// "resolver version." Returns null if no VersionChanged has been emitted.
pub fn getNodeRecordVersion(db: *Database, resolver: Address, namehash_val: Hash) !?u64 {
    const sql =
        \\SELECT version FROM resolver_versions
        \\WHERE resolver = ? AND namehash = ?
        \\LIMIT 1
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindAddress(resolver);
    try q.bindHash(namehash_val);

    if (try q.step()) {
        return @intCast(q.getInt64(0));
    }
    return null;
}

pub fn storeResolverPubkey(
    db: *Database,
    namehash: Hash,
    resolver: Address,
    x: []const u8,
    y: []const u8,
    chain: models.Chain,
    block_number: u64,
    tx_hash: Hash,
    timestamp: i64,
) !void {
    const sql =
        \\INSERT OR REPLACE INTO resolver_pubkeys
        \\  (namehash, resolver, x, y, chain, block_number, transaction_hash, timestamp)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindHash(namehash);
    try q.bindAddress(resolver);
    try q.bindText(x);
    try q.bindText(y);
    try q.bindTextStatic(chain.toString());
    try q.bindInt64(@intCast(block_number));
    try q.bindHash(tx_hash);
    try q.bindInt64(timestamp);

    try q.exec();
}

pub fn storeResolverABI(
    db: *Database,
    namehash: Hash,
    resolver: Address,
    content_type: u64,
    chain: models.Chain,
    block_number: u64,
    tx_hash: Hash,
    timestamp: i64,
) !void {
    const sql =
        \\INSERT OR REPLACE INTO resolver_abis
        \\  (namehash, resolver, content_type, chain, block_number, transaction_hash, timestamp)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindHash(namehash);
    try q.bindAddress(resolver);
    try q.bindInt64(@intCast(content_type));
    try q.bindTextStatic(chain.toString());
    try q.bindInt64(@intCast(block_number));
    try q.bindHash(tx_hash);
    try q.bindInt64(timestamp);

    try q.exec();
}

pub fn storeResolverName(
    db: *Database,
    namehash: Hash,
    resolver: Address,
    name: []const u8,
    chain: models.Chain,
    block_number: u64,
    tx_hash: Hash,
    timestamp: i64,
) !void {
    const sql =
        \\INSERT OR REPLACE INTO resolver_names
        \\  (namehash, resolver, name, chain, block_number, transaction_hash, timestamp)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindHash(namehash);
    try q.bindAddress(resolver);
    try q.bindText(name);
    try q.bindTextStatic(chain.toString());
    try q.bindInt64(@intCast(block_number));
    try q.bindHash(tx_hash);
    try q.bindInt64(timestamp);

    try q.exec();
}

pub fn storeResolverInterface(
    db: *Database,
    namehash: Hash,
    resolver: Address,
    interface_id: []const u8,
    implementer: []const u8,
    chain: models.Chain,
    block_number: u64,
    tx_hash: Hash,
    timestamp: i64,
) !void {
    const sql =
        \\INSERT OR REPLACE INTO resolver_interfaces
        \\  (namehash, resolver, interface_id, implementer, chain, block_number, transaction_hash, timestamp)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindHash(namehash);
    try q.bindAddress(resolver);
    try q.bindText(interface_id);
    try q.bindText(implementer);
    try q.bindTextStatic(chain.toString());
    try q.bindInt64(@intCast(block_number));
    try q.bindHash(tx_hash);
    try q.bindInt64(timestamp);

    try q.exec();
}

pub fn storeResolverVersion(
    db: *Database,
    namehash: Hash,
    resolver: Address,
    version: u64,
    chain: models.Chain,
    block_number: u64,
    tx_hash: Hash,
    timestamp: i64,
) !void {
    const sql =
        \\INSERT OR REPLACE INTO resolver_versions
        \\  (namehash, resolver, version, chain, block_number, transaction_hash, timestamp)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindHash(namehash);
    try q.bindAddress(resolver);
    try q.bindInt64(@intCast(version));
    try q.bindTextStatic(chain.toString());
    try q.bindInt64(@intCast(block_number));
    try q.bindHash(tx_hash);
    try q.bindInt64(timestamp);

    try q.exec();
}

// ============================================================================
// RESOLVER STATISTICS QUERIES (for top-level resolverDetail query)
// ============================================================================

/// Count the number of domains (nodes) that use a specific resolver address
pub fn getResolverNodeCount(db: *Database, resolver: Address) !usize {
    const sql = "SELECT COUNT(*) FROM names WHERE resolver = ?";

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindAddress(resolver);

    if (try q.step()) {
        return @intCast(q.getInt64(0));
    }
    return 0;
}

/// Count the number of aliases defined on a resolver
pub fn getResolverAliasCount(db: *Database, resolver: Address) !usize {
    const sql = "SELECT COUNT(*) FROM resolver_aliases WHERE resolver = ?";

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindAddress(resolver);

    if (try q.step()) {
        return @intCast(q.getInt64(0));
    }
    return 0;
}

/// Count the number of distinct role holders for a resolver contract
pub fn getResolverRoleHolderCount(db: *Database, resolver: Address) !usize {
    const sql = "SELECT COUNT(DISTINCT account) FROM eac_roles WHERE contract_address = ?";

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindAddress(resolver);

    if (try q.step()) {
        return @intCast(q.getInt64(0));
    }
    return 0;
}

/// Get all EAC role assignments for a resolver contract address
pub fn getResolverRoles(db: *Database, resolver: Address) ![]models.EACRoleAssignment {
    const sql =
        \\SELECT r.id, r.chain, r.resource, r.account, r.role_bitmap, r.block_number, r.transaction_hash, r.log_index, r.timestamp, n.name
        \\FROM eac_roles r
        \\LEFT JOIN names n ON r.resource = n.canonical_id AND r.contract_address = n.registry
        \\WHERE r.contract_address = ?
        \\ORDER BY r.timestamp DESC
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindAddress(resolver);

    var roles: std.ArrayList(models.EACRoleAssignment) = .{};
    errdefer {
        for (roles.items) |*role| {
            role.deinit(db.allocator);
        }
        roles.deinit(db.allocator);
    }

    while (try q.step()) {
        const chain_col = q.getTextSlice(1) orelse continue;
        const resource_col = q.getTextSlice(2) orelse continue;
        const account_col = q.getTextSlice(3) orelse continue;
        const role_bitmap_col = q.getTextSlice(4) orelse continue;
        const tx_hash_col = q.getTextSlice(6) orelse continue;

        const name_val: ?[]const u8 = if (q.getTextSlice(9)) |n|
            try db.allocator.dupe(u8, n)
        else
            null;
        errdefer if (name_val) |n| db.allocator.free(n);

        const role = models.EACRoleAssignment{
            .id = @intCast(q.getInt64(0)),
            .chain = try models.Chain.fromString(chain_col),
            .resource = try db.allocator.dupe(u8, resource_col),
            .account = try Address.fromHex(account_col),
            .role_bitmap = try db.allocator.dupe(u8, role_bitmap_col),
            .block_number = @intCast(q.getInt64(5)),
            .tx_hash = try Hash.fromHex(tx_hash_col),
            .log_index = @intCast(q.getInt(7)),
            .timestamp = q.getInt64(8),
            .name = name_val,
        };
        try roles.append(db.allocator, role);
    }

    return roles.toOwnedSlice(db.allocator);
}
