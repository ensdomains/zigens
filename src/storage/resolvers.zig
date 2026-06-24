const std = @import("std");
const db_module = @import("database.zig");
const reorg_undo = @import("reorg_undo.zig");
const Database = db_module.Database;
const Query = db_module.Query;
const models = @import("../types/models.zig");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;

// ============================================================================
// RESOLVER OPERATIONS
// ============================================================================

// ----------------------------------------------------------------------------
// Resolver entity table (subgraph parity)
// ----------------------------------------------------------------------------
// One row per (protocol, namehash, resolver_address) binding ever observed on
// a NewResolver-style event. The same name can produce multiple Resolver rows
// over time if its resolver contract changes — each row records when that
// specific binding was first set.
//
// The subgraph encodes IDs as `{chainId}-{address}-{node}`. Our (protocol,
// address, namehash) triple is the same shape; the encoding lives in the
// query layer, not the storage layer.

pub fn upsertResolverEntity(
    db: *Database,
    protocol: models.Protocol,
    resolver_address: []const u8,
    namehash: []const u8,
    name: []const u8,
    block_number: u64,
    timestamp: i64,
) !void {
    if (resolver_address.len == 0 or namehash.len == 0) return;
    const sql = try db.upsertSql(db.allocator, "resolvers", &.{ "protocol", "address", "name", "namehash", "set_block", "set_at" }, .ignore);
    defer db.allocator.free(sql);
    var q = try Query.initCached(db, sql);
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindText(resolver_address);
    try q.bindText(name);
    try q.bindText(namehash);
    try q.bindInt64(@intCast(block_number));
    try q.bindInt64(timestamp);
    try q.exec();
}

pub fn getResolverEntityCount(db: *Database) !u64 {
    var q = try Query.init(db, "SELECT COUNT(*) FROM resolvers");
    defer q.deinit();
    if (!(try q.step())) return 0;
    return @intCast(q.getInt64(0));
}

pub const ResolverEntity = struct {
    protocol: []const u8,
    address: []const u8,
    name: []const u8,
    namehash: []const u8,
    set_block: u64,
    set_at: i64,

    pub fn deinit(self: *ResolverEntity, allocator: std.mem.Allocator) void {
        allocator.free(self.protocol);
        allocator.free(self.address);
        allocator.free(self.name);
        allocator.free(self.namehash);
    }
};

pub const ResolverEntityFilters = struct {
    /// Exact match on the resolver contract address (lowercase 0x-hex).
    address: ?[]const u8 = null,
    address_in: ?[]const []const u8 = null,
    /// Exact match on the bound namehash.
    namehash: ?[]const u8 = null,
    /// Restrict to one protocol; null = both.
    protocol: ?[]const u8 = null,
};

pub const ResolverEntitySortField = enum {
    set_block,
    address,

    pub fn toSql(self: ResolverEntitySortField) []const u8 {
        return switch (self) {
            .set_block => "set_block",
            .address => "address",
        };
    }
};

pub fn getFilteredResolverEntities(
    db: *Database,
    filters: ResolverEntityFilters,
    skip: u32,
    limit: u32,
    order_dir: db_module.OrderDir,
    sort_field: ResolverEntitySortField,
) ![]ResolverEntity {
    var conditions: std.ArrayList([]const u8) = .{};
    defer conditions.deinit(db.allocator);
    var allocated: std.ArrayList([]const u8) = .{};
    defer {
        for (allocated.items) |s| db.allocator.free(s);
        allocated.deinit(db.allocator);
    }

    if (filters.address != null) try conditions.append(db.allocator, "address = ?");
    if (filters.namehash != null) try conditions.append(db.allocator, "namehash = ?");
    if (filters.protocol != null) try conditions.append(db.allocator, "protocol = ?");
    if (filters.address_in) |addrs| {
        if (addrs.len == 0) {
            try conditions.append(db.allocator, "1=0");
        } else {
            const clause = try db_module.query.buildInClause(db.allocator, "address", "IN", addrs.len);
            try allocated.append(db.allocator, clause);
            try conditions.append(db.allocator, clause);
        }
    }

    var sql_buf: std.ArrayList(u8) = .{};
    defer sql_buf.deinit(db.allocator);
    try sql_buf.appendSlice(db.allocator, "SELECT protocol, address, name, namehash, set_block, set_at FROM resolvers");
    if (conditions.items.len > 0) {
        try sql_buf.appendSlice(db.allocator, " WHERE ");
        for (conditions.items, 0..) |c, i| {
            if (i > 0) try sql_buf.appendSlice(db.allocator, " AND ");
            try sql_buf.appendSlice(db.allocator, c);
        }
    }
    try sql_buf.appendSlice(db.allocator, " ORDER BY ");
    try sql_buf.appendSlice(db.allocator, sort_field.toSql());
    try sql_buf.appendSlice(db.allocator, if (order_dir == .desc) " DESC" else " ASC");
    try sql_buf.appendSlice(db.allocator, ", namehash ASC LIMIT ? OFFSET ?");

    var q = try Query.init(db, sql_buf.items);
    defer q.deinit();
    if (filters.address) |a| try q.bindText(a);
    if (filters.namehash) |n| try q.bindText(n);
    if (filters.protocol) |p| try q.bindText(p);
    if (filters.address_in) |addrs| {
        for (addrs) |a| try q.bindText(a);
    }
    try q.bindInt64(@intCast(limit));
    try q.bindInt64(@intCast(skip));

    var results: std.ArrayList(ResolverEntity) = .{};
    defer results.deinit(db.allocator);
    while (try q.step()) {
        try results.append(db.allocator, .{
            .protocol = try db.allocator.dupe(u8, q.getTextSlice(0) orelse ""),
            .address = try db.allocator.dupe(u8, q.getTextSlice(1) orelse ""),
            .name = try db.allocator.dupe(u8, q.getTextSlice(2) orelse ""),
            .namehash = try db.allocator.dupe(u8, q.getTextSlice(3) orelse ""),
            .set_block = @intCast(q.getInt64(4)),
            .set_at = q.getInt64(5),
        });
    }
    return try results.toOwnedSlice(db.allocator);
}

// Backfill `resolvers` rows from existing `names.resolver` bindings. Idempotent
// (INSERT OR IGNORE preserves any previously inserted rows). Used once after
// the writer is added to event handlers, so historical data isn't lost.
pub fn backfillResolverEntitiesFromNames(db: *Database) !u64 {
    const seed_block_sql = "SELECT COALESCE(MIN(last_synced_block), 0) FROM sync_state";
    var seed_q = try Query.init(db, seed_block_sql);
    defer seed_q.deinit();
    const seed_block: i64 = if (try seed_q.step()) seed_q.getInt64(0) else 0;

    const select_body =
        \\SELECT n.protocol, n.resolver, n.name, n.namehash, ?, COALESCE(n.created_at, 0)
        \\FROM names n
        \\WHERE n.resolver IS NOT NULL
        \\  AND n.resolver != ''
        \\  AND n.resolver != '0x0000000000000000000000000000000000000000'
    ;
    const sql = try db.insertSelectSql(db.allocator, "resolvers", &.{ "protocol", "address", "name", "namehash", "set_block", "set_at" }, select_body, .ignore);
    defer db.allocator.free(sql);
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindInt64(seed_block);
    try q.exec();
    return try getResolverEntityCount(db);
}

pub fn storeResolverAddress(
    db: *Database,
    namehash: Hash,
    resolver: Address,
    coin_type: u64,
    address: []const u8,
    protocol: models.Protocol,
    block_number: u64,
    tx_hash: Hash,
    timestamp: i64,
) !void {
    try reorg_undo.captureUpsert(db, "resolver_addresses", .{ protocol, resolver, namehash, coin_type });
    const sql = try db.upsertExprSql(
        db.allocator,
        "resolver_addresses",
        &.{ "namehash", "resolver", "coin_type", "address", "protocol", "block_number", "transaction_hash", "timestamp", "context" },
        &.{ "?", "?", "?", "?", "?", "?", "?", "?", "NULL" },
        .replace,
    );
    defer db.allocator.free(sql);

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindHash(namehash);
    try q.bindAddress(resolver);
    try q.bindInt64(@intCast(coin_type));
    try q.bindText(address);
    try q.bindTextStatic(protocol.toString());
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
    protocol: models.Protocol,
    block_number: u64,
    tx_hash: Hash,
    timestamp: i64,
) !void {
    try reorg_undo.captureUpsert(db, "resolver_contenthashes", .{ protocol, resolver, namehash });
    const sql = try db.upsertSql(db.allocator, "resolver_contenthashes", &.{ "namehash", "resolver", "contenthash", "protocol", "block_number", "transaction_hash", "timestamp" }, .replace);
    defer db.allocator.free(sql);

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindHash(namehash);
    try q.bindAddress(resolver);
    try q.bindText(content_hash);
    try q.bindTextStatic(protocol.toString());
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
    protocol: models.Protocol,
    block_number: u64,
    tx_hash: Hash,
    timestamp: i64,
) !void {
    try reorg_undo.captureUpsert(db, "resolver_texts", .{ protocol, resolver, namehash, key });
    const sql = try db.upsertSql(db.allocator, "resolver_texts", &.{ "namehash", "resolver", "key", "value", "protocol", "block_number", "transaction_hash", "timestamp" }, .replace);
    defer db.allocator.free(sql);

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindHash(namehash);
    try q.bindAddress(resolver);
    try q.bindText(key);
    try q.bindText(value);
    try q.bindTextStatic(protocol.toString());
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

/// Backfill `names.resolver` from a prior `ResolverUpdated` event for the same
/// (protocol, namehash). Called from `handleLabelRegistered` to catch up state
/// that the `ResolverUpdated` handler couldn't write because the name wasn't
/// yet linked to its tokenId.
///
/// Why this is needed: on V2 a fresh registration emits events in the order
/// `ResolverUpdated → LabelRegistered`. The first handler can't update
/// `names.resolver` (no row to update yet) and only registers the resolver
/// contract for record indexing. By the time `LabelRegistered` runs, the row
/// exists but the resolver wire-up is lost.
///
/// Safety properties:
///   - **Protocol-scoped**: V1 and V2 share the namehash space (UNIQUE
///     constraint is `(protocol, namehash)`). Without protocol filtering a V2
///     event could clobber a V1 row's resolver, or vice versa.
///   - **Idempotent on retry**: `WHERE … resolver IS NULL OR resolver = 0x0…0`
///     prevents overwriting an already-set value. Safe if `LabelRegistered`
///     ever runs twice for the same name.
///   - **No NULL writes**: `EXISTS` plus `json_extract … IS NOT NULL` ensure
///     the SET subquery only fires when there's at least one event with a
///     well-formed `resolver` field. Without this, malformed event data could
///     blank out a row.
///   - **Latest wins**: ordered by `(block_number, log_index) DESC` so multiple
///     prior updates collapse to the most recent.
///
/// Relies on `updatePlaceholderEventsByName` having patched the event rows'
/// `namehash` column before this is called (which `handleLabelRegistered`
/// does in the line just above the call site).
pub fn applyLatestResolverFromEvents(db: *Database, protocol: models.Protocol, namehash: Hash) !void {
    try reorg_undo.captureWhere(db, "names", "U", "protocol = ? AND namehash = ? AND (resolver IS NULL OR resolver = '0x0000000000000000000000000000000000000000') AND EXISTS (SELECT 1 FROM events WHERE event_type = 'ResolverUpdated' AND protocol = ? AND namehash = ? AND json_extract(data, '$.resolver') IS NOT NULL)", .{ protocol, namehash, protocol, namehash });
    var q = try Query.initCached(db,
        \\UPDATE names
        \\SET resolver = (
        \\    SELECT json_extract(data, '$.resolver')
        \\    FROM events
        \\    WHERE event_type = 'ResolverUpdated'
        \\      AND protocol = ?
        \\      AND namehash = ?
        \\      AND json_extract(data, '$.resolver') IS NOT NULL
        \\    ORDER BY block_number DESC, log_index DESC
        \\    LIMIT 1
        \\),
        \\    updated_at = ?
        \\WHERE protocol = ?
        \\  AND namehash = ?
        \\  AND (resolver IS NULL OR resolver = '0x0000000000000000000000000000000000000000')
        \\  AND EXISTS (
        \\    SELECT 1 FROM events
        \\    WHERE event_type = 'ResolverUpdated'
        \\      AND protocol = ?
        \\      AND namehash = ?
        \\      AND json_extract(data, '$.resolver') IS NOT NULL
        \\  )
    );
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindHashBuf(namehash);
    try q.bindInt64(std.time.timestamp());
    try q.bindTextStatic(protocol.toString());
    try q.bindHashBuf(namehash);
    try q.bindTextStatic(protocol.toString());
    try q.bindHashBuf(namehash);
    try q.exec();
}

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

/// Distinct coin types currently set for (resolver, namehash). Returned as
/// u64 to safely cover ENSIP-11 L2 chain IDs (`0x80000000 | chainId`). Caller
/// frees the returned slice.
pub fn getCoinTypes(db: *Database, resolver: Address, namehash: Hash) ![]u64 {
    const sql =
        \\SELECT DISTINCT coin_type FROM resolver_addresses
        \\WHERE resolver = ? AND namehash = ?
        \\ORDER BY coin_type
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindAddress(resolver);
    try q.bindHash(namehash);

    var list: std.ArrayList(u64) = .{};
    errdefer list.deinit(db.allocator);
    while (try q.step()) {
        try list.append(db.allocator, @intCast(q.getInt64(0)));
    }
    return list.toOwnedSlice(db.allocator);
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
pub fn getResolversToIndex(db: *Database, protocol: models.Protocol, from_block: u64, to_block: u64) ![][]u8 {
    // First, discover any NEW resolvers from names table (only those set in this block range)
    const discover_sql =
        \\SELECT DISTINCT n.resolver
        \\FROM names n
        \\LEFT JOIN known_resolvers kr ON kr.protocol = n.protocol AND kr.address = n.resolver
        \\WHERE n.protocol = ?
        \\  AND n.resolver != '0x0000000000000000000000000000000000000000'
        \\  AND n.created_block >= ?
        \\  AND n.created_block <= ?
        \\  AND kr.address IS NULL
    ;

    const protocol_str = protocol.toString();

    {
        var q = try Query.init(db, discover_sql);
        defer q.deinit();

        try q.bindTextStatic(protocol_str);
        try q.bindInt64(@intCast(from_block));
        try q.bindInt64(@intCast(to_block));

        // Register newly discovered resolvers
        while (try q.step()) {
            if (q.getTextSlice(0)) |addr_slice| {
                try db.registerResolver(protocol, addr_slice, from_block);
            }
        }
    }

    // Now get ALL known resolvers from cache (very fast)
    const get_sql =
        \\SELECT address FROM known_resolvers
        \\WHERE protocol = ?
        \\ORDER BY address
    ;

    var q2 = try Query.init(db, get_sql);
    defer q2.deinit();

    try q2.bindTextStatic(protocol_str);

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
pub fn discoverAndGetResolvers(db: *Database, protocol: models.Protocol, from_block: u64, to_block: u64) !ResolverDiscoveryResult {
    const discover_sql =
        \\SELECT DISTINCT n.resolver
        \\FROM names n
        \\LEFT JOIN known_resolvers kr ON kr.protocol = n.protocol AND kr.address = n.resolver
        \\WHERE n.protocol = ?
        \\  AND n.resolver != '0x0000000000000000000000000000000000000000'
        \\  AND n.created_block >= ?
        \\  AND n.created_block <= ?
        \\  AND kr.address IS NULL
    ;

    const protocol_str = protocol.toString();

    var new_resolvers: std.ArrayList([]u8) = .{};
    errdefer {
        for (new_resolvers.items) |r| db.allocator.free(r);
        new_resolvers.deinit(db.allocator);
    }

    {
        var q = try Query.init(db, discover_sql);
        defer q.deinit();

        try q.bindTextStatic(protocol_str);
        try q.bindInt64(@intCast(from_block));
        try q.bindInt64(@intCast(to_block));

        while (try q.step()) {
            if (q.getTextSlice(0)) |addr_slice| {
                try db.registerResolver(protocol, addr_slice, from_block);
                const copy = try db.allocator.dupe(u8, addr_slice);
                try new_resolvers.append(db.allocator, copy);
            }
        }
    }

    // Get ALL known resolvers from cache
    const get_sql =
        \\SELECT address FROM known_resolvers
        \\WHERE protocol = ?
        \\ORDER BY address
    ;

    var q2 = try Query.init(db, get_sql);
    defer q2.deinit();

    try q2.bindTextStatic(protocol_str);

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
pub fn getResolversByOwner(db: *Database, protocol: models.Protocol, owner: Address) ![]models.Resolver {
    const sql =
        \\SELECT DISTINCT n.resolver, n.name, n.namehash, n.created_block, n.created_at
        \\FROM names n
        \\WHERE n.protocol = ? AND n.owner = ? AND n.resolver != '0x0000000000000000000000000000000000000000'
        \\ORDER BY n.created_at DESC
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());
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
            .protocol = protocol,
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

pub fn deleteResolverAddresses(db: *Database, namehash: Hash, resolver: Address) !void {
    try reorg_undo.captureWhere(db, "resolver_addresses", "D", "namehash = ? AND resolver = ?", .{ namehash, resolver });
    const sql = "DELETE FROM resolver_addresses WHERE namehash = ? AND resolver = ?";
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindHash(namehash);
    try q.bindAddress(resolver);
    try q.exec();
}

pub fn deleteResolverContentHash(db: *Database, namehash: Hash, resolver: Address) !void {
    try reorg_undo.captureWhere(db, "resolver_contenthashes", "D", "namehash = ? AND resolver = ?", .{ namehash, resolver });
    const sql = "DELETE FROM resolver_contenthashes WHERE namehash = ? AND resolver = ?";
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindHash(namehash);
    try q.bindAddress(resolver);
    try q.exec();
}

pub fn deleteResolverTexts(db: *Database, namehash: Hash, resolver: Address) !void {
    try reorg_undo.captureWhere(db, "resolver_texts", "D", "namehash = ? AND resolver = ?", .{ namehash, resolver });
    const sql = "DELETE FROM resolver_texts WHERE namehash = ? AND resolver = ?";
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindHash(namehash);
    try q.bindAddress(resolver);
    try q.exec();
}

pub fn deleteResolverAlias(db: *Database, resolver: Address, from_name: []const u8) !void {
    try reorg_undo.captureWhere(db, "resolver_aliases", "D", "resolver = ? AND from_name = ?", .{ resolver, from_name });
    const sql = "DELETE FROM resolver_aliases WHERE resolver = ? AND from_name = ?";
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindAddress(resolver);
    try q.bindText(from_name);
    try q.exec();
}

pub fn deleteResolverPubkeys(db: *Database, namehash: Hash, resolver: Address) !void {
    try reorg_undo.captureWhere(db, "resolver_pubkeys", "D", "namehash = ? AND resolver = ?", .{ namehash, resolver });
    const sql = "DELETE FROM resolver_pubkeys WHERE namehash = ? AND resolver = ?";
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindHash(namehash);
    try q.bindAddress(resolver);
    try q.exec();
}

pub fn deleteResolverAbis(db: *Database, namehash: Hash, resolver: Address) !void {
    try reorg_undo.captureWhere(db, "resolver_abis", "D", "namehash = ? AND resolver = ?", .{ namehash, resolver });
    const sql = "DELETE FROM resolver_abis WHERE namehash = ? AND resolver = ?";
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindHash(namehash);
    try q.bindAddress(resolver);
    try q.exec();
}

pub fn deleteResolverNames(db: *Database, namehash: Hash, resolver: Address) !void {
    try reorg_undo.captureWhere(db, "resolver_names", "D", "namehash = ? AND resolver = ?", .{ namehash, resolver });
    const sql = "DELETE FROM resolver_names WHERE namehash = ? AND resolver = ?";
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindHash(namehash);
    try q.bindAddress(resolver);
    try q.exec();
}

pub fn deleteResolverInterfaces(db: *Database, namehash: Hash, resolver: Address) !void {
    try reorg_undo.captureWhere(db, "resolver_interfaces", "D", "namehash = ? AND resolver = ?", .{ namehash, resolver });
    const sql = "DELETE FROM resolver_interfaces WHERE namehash = ? AND resolver = ?";
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindHash(namehash);
    try q.bindAddress(resolver);
    try q.exec();
}

// ============================================================================
// STORE OPERATIONS (for new record types)
// ============================================================================

/// Delete a single resolver text record (key-scoped).
/// Used when `TextChanged` carries an empty value (treated as a clear).
pub fn deleteResolverText(
    db: *Database,
    protocol: models.Protocol,
    namehash: Hash,
    resolver: Address,
    key: []const u8,
) !void {
    try reorg_undo.captureWhere(db, "resolver_texts", "D", "protocol = ? AND namehash = ? AND resolver = ? AND key = ?", .{ protocol, namehash, resolver, key });
    const sql =
        \\DELETE FROM resolver_texts
        \\WHERE protocol = ? AND namehash = ? AND resolver = ? AND key = ?
    ;
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindHash(namehash);
    try q.bindAddress(resolver);
    try q.bindText(key);
    try q.exec();
}

/// Store an `AuthorisationChanged(node, owner, target, isAuthorised)` row
/// from the V1 PublicResolver `Authorisable` mixin (legacy).
pub fn storeResolverAuthorisation(
    db: *Database,
    protocol: models.Protocol,
    namehash: Hash,
    resolver: Address,
    owner: Address,
    target: Address,
    is_authorised: bool,
    block_number: u64,
    tx_hash: Hash,
    log_index: u32,
    timestamp: i64,
) !void {
    try reorg_undo.captureUpsert(db, "resolver_authorisations", .{ protocol, resolver, namehash, owner, target });
    const sql = try db.upsertSql(db.allocator, "resolver_authorisations", &.{ "protocol", "namehash", "resolver", "owner", "target", "is_authorised", "block_number", "transaction_hash", "log_index", "timestamp" }, .replace);
    defer db.allocator.free(sql);
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindHash(namehash);
    try q.bindAddress(resolver);
    try q.bindAddress(owner);
    try q.bindAddress(target);
    try q.bindInt64(if (is_authorised) 1 else 0);
    try q.bindInt64(@intCast(block_number));
    try q.bindHash(tx_hash);
    try q.bindInt64(@intCast(log_index));
    try q.bindInt64(timestamp);
    try q.exec();
}

/// Store an ENSIP-17 `DNSRecordChanged(node, name, resource, record)` row.
/// `dns_name` and `record` are hex-encoded `0x…` strings.
pub fn storeResolverDnsRecord(
    db: *Database,
    protocol: models.Protocol,
    namehash: Hash,
    resolver: Address,
    dns_name: []const u8,
    resource: u16,
    record: []const u8,
    block_number: u64,
    tx_hash: Hash,
    log_index: u32,
    timestamp: i64,
) !void {
    try reorg_undo.captureUpsert(db, "resolver_dns_records", .{ protocol, resolver, namehash, dns_name, resource });
    const sql = try db.upsertSql(db.allocator, "resolver_dns_records", &.{ "protocol", "namehash", "resolver", "dns_name", "resource", "record", "block_number", "transaction_hash", "log_index", "timestamp" }, .replace);
    defer db.allocator.free(sql);
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindHash(namehash);
    try q.bindAddress(resolver);
    try q.bindText(dns_name);
    try q.bindInt64(@intCast(resource));
    try q.bindText(record);
    try q.bindInt64(@intCast(block_number));
    try q.bindHash(tx_hash);
    try q.bindInt64(@intCast(log_index));
    try q.bindInt64(timestamp);
    try q.exec();
}

/// Delete an ENSIP-17 DNS record (matches `DNSRecordDeleted`).
pub fn deleteResolverDnsRecord(
    db: *Database,
    protocol: models.Protocol,
    namehash: Hash,
    resolver: Address,
    dns_name: []const u8,
    resource: u16,
) !void {
    try reorg_undo.captureWhere(db, "resolver_dns_records", "D", "protocol = ? AND namehash = ? AND resolver = ? AND dns_name = ? AND resource = ?", .{ protocol, namehash, resolver, dns_name, resource });
    const sql =
        \\DELETE FROM resolver_dns_records
        \\WHERE protocol = ? AND namehash = ? AND resolver = ?
        \\  AND dns_name = ? AND resource = ?
    ;
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindHash(namehash);
    try q.bindAddress(resolver);
    try q.bindText(dns_name);
    try q.bindInt64(@intCast(resource));
    try q.exec();
}

/// Store an ENSIP-17 `DNSZonehashChanged(node, lastzonehash, zonehash)` row.
pub fn storeResolverDnsZonehash(
    db: *Database,
    protocol: models.Protocol,
    namehash: Hash,
    resolver: Address,
    zonehash: []const u8,
    last_zonehash: []const u8,
    block_number: u64,
    tx_hash: Hash,
    log_index: u32,
    timestamp: i64,
) !void {
    try reorg_undo.captureUpsert(db, "resolver_dns_zonehashes", .{ protocol, resolver, namehash });
    const sql = try db.upsertSql(db.allocator, "resolver_dns_zonehashes", &.{ "protocol", "namehash", "resolver", "zonehash", "last_zonehash", "block_number", "transaction_hash", "log_index", "timestamp" }, .replace);
    defer db.allocator.free(sql);
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindHash(namehash);
    try q.bindAddress(resolver);
    try q.bindText(zonehash);
    try q.bindText(last_zonehash);
    try q.bindInt64(@intCast(block_number));
    try q.bindHash(tx_hash);
    try q.bindInt64(@intCast(log_index));
    try q.bindInt64(timestamp);
    try q.exec();
}

pub fn storeResolverAlias(
    db: *Database,
    resolver: Address,
    from_name: []const u8,
    to_name: []const u8,
    protocol: models.Protocol,
    block_number: u64,
    tx_hash: Hash,
    timestamp: i64,
) !void {
    try reorg_undo.captureUpsert(db, "resolver_aliases", .{ resolver, from_name });
    const sql = try db.upsertSql(db.allocator, "resolver_aliases", &.{ "resolver", "from_name", "to_name", "protocol", "block_number", "transaction_hash", "timestamp" }, .replace);
    defer db.allocator.free(sql);

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindAddress(resolver);
    try q.bindText(from_name);
    try q.bindText(to_name);
    try q.bindTextStatic(protocol.toString());
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

/// Latest reverse-name record for a namehash, regardless of which resolver wrote it.
/// Used by the primary-name (reverse-resolution) path: a reverse claim binds an address
/// to a node; the most recent `NameChanged` against that node — across resolvers —
/// is the displayed primary name. Resolver_names has no log_index column, so we
/// tiebreak with the autoincrement `id` (monotone in insertion order).
pub fn getLatestNameByNamehash(db: *Database, namehash_val: Hash) !?[]u8 {
    const sql =
        \\SELECT name FROM resolver_names
        \\WHERE namehash = ?
        \\ORDER BY block_number DESC, id DESC
        \\LIMIT 1
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindHash(namehash_val);

    if (try q.step()) {
        return try q.getText(0);
    }
    return null;
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
    protocol: models.Protocol,
    block_number: u64,
    tx_hash: Hash,
    timestamp: i64,
) !void {
    try reorg_undo.captureUpsert(db, "resolver_pubkeys", .{ protocol, resolver, namehash });
    const sql = try db.upsertSql(db.allocator, "resolver_pubkeys", &.{ "namehash", "resolver", "x", "y", "protocol", "block_number", "transaction_hash", "timestamp" }, .replace);
    defer db.allocator.free(sql);

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindHash(namehash);
    try q.bindAddress(resolver);
    try q.bindText(x);
    try q.bindText(y);
    try q.bindTextStatic(protocol.toString());
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
    protocol: models.Protocol,
    block_number: u64,
    tx_hash: Hash,
    timestamp: i64,
) !void {
    try reorg_undo.captureUpsert(db, "resolver_abis", .{ protocol, resolver, namehash, content_type });
    const sql = try db.upsertSql(db.allocator, "resolver_abis", &.{ "namehash", "resolver", "content_type", "protocol", "block_number", "transaction_hash", "timestamp" }, .replace);
    defer db.allocator.free(sql);

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindHash(namehash);
    try q.bindAddress(resolver);
    try q.bindInt64(@intCast(content_type));
    try q.bindTextStatic(protocol.toString());
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
    protocol: models.Protocol,
    block_number: u64,
    tx_hash: Hash,
    timestamp: i64,
) !void {
    try reorg_undo.captureUpsert(db, "resolver_names", .{ protocol, resolver, namehash });
    const sql = try db.upsertSql(db.allocator, "resolver_names", &.{ "namehash", "resolver", "name", "protocol", "block_number", "transaction_hash", "timestamp" }, .replace);
    defer db.allocator.free(sql);

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindHash(namehash);
    try q.bindAddress(resolver);
    try q.bindText(name);
    try q.bindTextStatic(protocol.toString());
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
    protocol: models.Protocol,
    block_number: u64,
    tx_hash: Hash,
    timestamp: i64,
) !void {
    try reorg_undo.captureUpsert(db, "resolver_interfaces", .{ protocol, resolver, namehash, interface_id });
    const sql = try db.upsertSql(db.allocator, "resolver_interfaces", &.{ "namehash", "resolver", "interface_id", "implementer", "protocol", "block_number", "transaction_hash", "timestamp" }, .replace);
    defer db.allocator.free(sql);

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindHash(namehash);
    try q.bindAddress(resolver);
    try q.bindText(interface_id);
    try q.bindText(implementer);
    try q.bindTextStatic(protocol.toString());
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
    protocol: models.Protocol,
    block_number: u64,
    tx_hash: Hash,
    timestamp: i64,
) !void {
    try reorg_undo.captureUpsert(db, "resolver_versions", .{ resolver, namehash });
    const sql = try db.upsertSql(db.allocator, "resolver_versions", &.{ "namehash", "resolver", "version", "protocol", "block_number", "transaction_hash", "timestamp" }, .replace);
    defer db.allocator.free(sql);

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindHash(namehash);
    try q.bindAddress(resolver);
    try q.bindInt64(@intCast(version));
    try q.bindTextStatic(protocol.toString());
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
        \\SELECT r.id, r.protocol, r.resource, r.account, r.role_bitmap, r.block_number, r.transaction_hash, r.log_index, r.timestamp, n.name
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
        const protocol_col = q.getTextSlice(1) orelse continue;
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
            .protocol = try models.Protocol.fromString(protocol_col),
            .resource = try db.allocator.dupe(u8, resource_col),
            .account = try Address.fromHex(account_col),
            .role_bitmap = try db.allocator.dupe(u8, role_bitmap_col),
            .block_number = @intCast(q.getInt64(5)),
            .tx_hash = try Hash.fromHex(tx_hash_col),
            .log_index = @intCast(q.getInt(7)),
            .timestamp = q.getInt64(8),
            .name = name_val,
            // This query is scoped to a single resolver contract, so every row
            // is a resolver-EAC assignment — decode against the resolver table.
            .contract_kind = .resolver,
        };
        try roles.append(db.allocator, role);
    }

    return roles.toOwnedSlice(db.allocator);
}

// ============================================================================
// REVERSE RECORDS (V1 ReverseClaimed + V2 ETHReverseRegistrar)
// ============================================================================

/// Upsert the (protocol, address) → namehash reverse-claim binding. Each address
/// can have at most one current reverse claim per protocol; later claims replace
/// earlier ones (latest-write-wins, mirroring the contract's behavior).
pub fn upsertReverseRecord(
    db: *Database,
    protocol: models.Protocol,
    address: Address,
    namehash: Hash,
    block_number: u64,
    tx_hash: Hash,
    log_index: u32,
    timestamp: i64,
) !void {
    try reorg_undo.captureWhere(db, "reverse_records", "U", "protocol = ? AND address = LOWER(?)", .{ protocol, address });
    var q = try Query.initCached(db,
        \\INSERT INTO reverse_records
        \\  (protocol, address, namehash, block_number, transaction_hash, log_index, timestamp)
        \\VALUES (?, LOWER(?), ?, ?, ?, ?, ?)
        \\ON CONFLICT(protocol, address) DO UPDATE SET
        \\  namehash = excluded.namehash,
        \\  block_number = excluded.block_number,
        \\  transaction_hash = excluded.transaction_hash,
        \\  log_index = excluded.log_index,
        \\  timestamp = excluded.timestamp
    );
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(address);
    try q.bindHash(namehash);
    try q.bindInt64(@intCast(block_number));
    try q.bindHash(tx_hash);
    try q.bindInt(@intCast(log_index));
    try q.bindInt64(timestamp);
    try q.exec();
}

/// Look up the current reverse-claim namehash for an address on a given protocol.
/// Returns null if the address has not claimed a reverse on this protocol.
pub fn getReverseRecordNamehash(db: *Database, protocol: models.Protocol, address: Address) !?Hash {
    var q = try Query.init(db,
        \\SELECT namehash FROM reverse_records
        \\WHERE protocol = ? AND address = LOWER(?)
        \\LIMIT 1
    );
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(address);

    if (try q.step()) {
        if (q.getTextSlice(0)) |hex| return try Hash.fromHex(hex);
    }
    return null;
}
