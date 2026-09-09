const std = @import("std");
const zsys = @import("../utils/system.zig");
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

const entity = @import("resolver_entity.zig");
pub const upsertResolverEntity = entity.upsertResolverEntity;
pub const getResolverEntityCount = entity.getResolverEntityCount;
pub const ResolverEntity = entity.ResolverEntity;
pub const ResolverEntityFilters = entity.ResolverEntityFilters;
pub const ResolverEntitySortField = entity.ResolverEntitySortField;
pub const getFilteredResolverEntities = entity.getFilteredResolverEntities;
pub const backfillResolverEntitiesFromNames = entity.backfillResolverEntitiesFromNames;
pub const getResolversToIndex = entity.getResolversToIndex;
pub const ResolverDiscoveryResult = entity.ResolverDiscoveryResult;
pub const discoverAndGetResolvers = entity.discoverAndGetResolvers;
pub const getResolversByOwner = entity.getResolversByOwner;
pub const getResolverNodeCount = entity.getResolverNodeCount;
pub const getResolverAliasCount = entity.getResolverAliasCount;
pub const getResolverRoleHolderCount = entity.getResolverRoleHolderCount;
pub const getResolverRoles = entity.getResolverRoles;

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
    const sql = try db.upsertSql(db.allocator, "resolver_addresses", &.{ "namehash", "resolver", "coin_type", "address", "protocol", "block_number", "transaction_hash", "timestamp" }, .replace);
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
    try db.namesBarrier();
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
    try q.bindInt64(zsys.timestamp());
    try q.bindTextStatic(protocol.toString());
    try q.bindHashBuf(namehash);
    try q.bindTextStatic(protocol.toString());
    try q.bindHashBuf(namehash);
    try q.exec();
    db.noteNameWriteByNamehash(namehash);
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

    var list: std.ArrayList(u64) = .empty;
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
    var addresses: std.ArrayList(CoinAddress) = .empty;
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

/// One `(resolver, namehash) -> value` row from a batch record read. All fields
/// are 0x-hex text owned by the db allocator; free via `deinit`.
pub const ResolverRecordRow = struct {
    resolver: []u8,
    namehash: []u8,
    value: []u8,

    pub fn deinit(self: *ResolverRecordRow, allocator: std.mem.Allocator) void {
        allocator.free(self.resolver);
        allocator.free(self.namehash);
        allocator.free(self.value);
    }
};

fn freeRecordRows(allocator: std.mem.Allocator, rows: *std.ArrayList(ResolverRecordRow)) void {
    for (rows.items) |*r| r.deinit(allocator);
    rows.deinit(allocator);
}

// Pair binds go through bindTextStatic with arena-scratch hex (no tracked-
// string cap), so the chunk is sized for statement length and planner sanity,
// not MAX_BOUND_STRINGS. 200 pairs = 400 placeholders — under even the
// legacy SQLite 999-parameter limit; a 1000-row page batches in 5 statements.
const RECORD_BATCH_CHUNK: usize = 200;

/// Bind a chunk's (resolver, namehash) pairs as static text. The hex buffers
/// live on `scratch`, which the caller MUST declare BEFORE the Query (LIFO
/// defers) so they outlive statement execution — same pattern as
/// upsertEACRolesBatch/insertEventsBatch.
fn bindPairsStatic(q: *Query, scratch: std.mem.Allocator, pair_resolvers: []const Address, pair_namehashes: []const Hash) !void {
    for (pair_resolvers, pair_namehashes) |r, nh| {
        const r_buf = try scratch.create([42]u8);
        try q.bindTextStatic(r.toHexBuf(r_buf));
        const nh_buf = try scratch.create([66]u8);
        try q.bindTextStatic(nh.toHexBuf(nh_buf));
    }
}

/// Batch equivalent of `getAddressRecord` for coin_type 60: the latest address
/// per `(resolver, namehash)` pair (`ORDER BY block_number DESC LIMIT 1`,
/// replicated per pair via ROW_NUMBER). Only pairs that HAVE a record appear in
/// the result. `resolvers[i]` pairs with `namehashes[i]`; both must be the same
/// length. Caller owns the returned slice and each row.
pub fn getAddressRecordsBatch(db: *Database, resolvers: []const Address, namehashes: []const Hash, coin_type: u64) ![]ResolverRecordRow {
    std.debug.assert(resolvers.len == namehashes.len);
    var rows: std.ArrayList(ResolverRecordRow) = .empty;
    errdefer freeRecordRows(db.allocator, &rows);
    if (resolvers.len == 0) return try rows.toOwnedSlice(db.allocator);

    var off: usize = 0;
    while (off < resolvers.len) : (off += RECORD_BATCH_CHUNK) {
        const end = @min(off + RECORD_BATCH_CHUNK, resolvers.len);
        const n = end - off;

        var sql: std.ArrayList(u8) = .empty;
        defer sql.deinit(db.allocator);
        try sql.appendSlice(db.allocator, "SELECT resolver, namehash, address FROM (" ++
            "SELECT resolver, namehash, address, ROW_NUMBER() OVER (PARTITION BY resolver, namehash ORDER BY block_number DESC) AS rn " ++
            "FROM resolver_addresses WHERE coin_type = ? AND (resolver, namehash) IN (");
        for (0..n) |i| {
            if (i > 0) try sql.appendSlice(db.allocator, ", ");
            try sql.appendSlice(db.allocator, "(?, ?)");
        }
        try sql.appendSlice(db.allocator, ")) sub WHERE rn = 1");

        var arena = std.heap.ArenaAllocator.init(db.allocator);
        defer arena.deinit();

        var q = try Query.init(db, sql.items);
        defer q.deinit();
        try q.bindInt64(@intCast(coin_type));
        try bindPairsStatic(&q, arena.allocator(), resolvers[off..end], namehashes[off..end]);
        while (try q.step()) {
            // Loop-scoped errdefers: a later getText/append failure must free
            // the columns already duped this iteration (the outer errdefer
            // only sweeps rows already committed to the list).
            const r_opt = try q.getText(0);
            errdefer if (r_opt) |x| db.allocator.free(x);
            const nh_opt = try q.getText(1);
            errdefer if (nh_opt) |x| db.allocator.free(x);
            const val_opt = try q.getText(2);
            errdefer if (val_opt) |x| db.allocator.free(x);
            if (r_opt == null or nh_opt == null or val_opt == null) {
                if (r_opt) |x| db.allocator.free(x);
                if (nh_opt) |x| db.allocator.free(x);
                if (val_opt) |x| db.allocator.free(x);
                continue;
            }
            try rows.append(db.allocator, .{ .resolver = r_opt.?, .namehash = nh_opt.?, .value = val_opt.? });
        }
    }
    return try rows.toOwnedSlice(db.allocator);
}

/// Batch equivalent of `getContentHashRecord`: the latest contenthash per
/// `(resolver, namehash)` pair. Same contract as `getAddressRecordsBatch`.
pub fn getContentHashesBatch(db: *Database, resolvers: []const Address, namehashes: []const Hash) ![]ResolverRecordRow {
    std.debug.assert(resolvers.len == namehashes.len);
    var rows: std.ArrayList(ResolverRecordRow) = .empty;
    errdefer freeRecordRows(db.allocator, &rows);
    if (resolvers.len == 0) return try rows.toOwnedSlice(db.allocator);

    var off: usize = 0;
    while (off < resolvers.len) : (off += RECORD_BATCH_CHUNK) {
        const end = @min(off + RECORD_BATCH_CHUNK, resolvers.len);
        const n = end - off;

        var sql: std.ArrayList(u8) = .empty;
        defer sql.deinit(db.allocator);
        try sql.appendSlice(db.allocator, "SELECT resolver, namehash, contenthash FROM (" ++
            "SELECT resolver, namehash, contenthash, ROW_NUMBER() OVER (PARTITION BY resolver, namehash ORDER BY block_number DESC) AS rn " ++
            "FROM resolver_contenthashes WHERE (resolver, namehash) IN (");
        for (0..n) |i| {
            if (i > 0) try sql.appendSlice(db.allocator, ", ");
            try sql.appendSlice(db.allocator, "(?, ?)");
        }
        try sql.appendSlice(db.allocator, ")) sub WHERE rn = 1");

        var arena = std.heap.ArenaAllocator.init(db.allocator);
        defer arena.deinit();

        var q = try Query.init(db, sql.items);
        defer q.deinit();
        try bindPairsStatic(&q, arena.allocator(), resolvers[off..end], namehashes[off..end]);
        while (try q.step()) {
            // Loop-scoped errdefers: a later getText/append failure must free
            // the columns already duped this iteration (the outer errdefer
            // only sweeps rows already committed to the list).
            const r_opt = try q.getText(0);
            errdefer if (r_opt) |x| db.allocator.free(x);
            const nh_opt = try q.getText(1);
            errdefer if (nh_opt) |x| db.allocator.free(x);
            const val_opt = try q.getText(2);
            errdefer if (val_opt) |x| db.allocator.free(x);
            if (r_opt == null or nh_opt == null or val_opt == null) {
                if (r_opt) |x| db.allocator.free(x);
                if (nh_opt) |x| db.allocator.free(x);
                if (val_opt) |x| db.allocator.free(x);
                continue;
            }
            try rows.append(db.allocator, .{ .resolver = r_opt.?, .namehash = nh_opt.?, .value = val_opt.? });
        }
    }
    return try rows.toOwnedSlice(db.allocator);
}

/// Batch equivalent of `getTextRecord` for a single `key`: the latest value per
/// `(resolver, namehash)` pair for that key. Same contract as
/// `getAddressRecordsBatch`. Rows carry (resolver, namehash, value); the key is
/// fixed per call, so the caller supplies it when keying the result.
pub fn getTextRecordsBatch(db: *Database, resolvers: []const Address, namehashes: []const Hash, key: []const u8) ![]ResolverRecordRow {
    std.debug.assert(resolvers.len == namehashes.len);
    var rows: std.ArrayList(ResolverRecordRow) = .empty;
    errdefer freeRecordRows(db.allocator, &rows);
    if (resolvers.len == 0) return try rows.toOwnedSlice(db.allocator);

    var off: usize = 0;
    while (off < resolvers.len) : (off += RECORD_BATCH_CHUNK) {
        const end = @min(off + RECORD_BATCH_CHUNK, resolvers.len);
        const n = end - off;

        var sql: std.ArrayList(u8) = .empty;
        defer sql.deinit(db.allocator);
        try sql.appendSlice(db.allocator, "SELECT resolver, namehash, value FROM (" ++
            "SELECT resolver, namehash, value, ROW_NUMBER() OVER (PARTITION BY resolver, namehash ORDER BY block_number DESC) AS rn " ++
            "FROM resolver_texts WHERE key = ? AND (resolver, namehash) IN (");
        for (0..n) |i| {
            if (i > 0) try sql.appendSlice(db.allocator, ", ");
            try sql.appendSlice(db.allocator, "(?, ?)");
        }
        try sql.appendSlice(db.allocator, ")) sub WHERE rn = 1");

        var arena = std.heap.ArenaAllocator.init(db.allocator);
        defer arena.deinit();

        var q = try Query.init(db, sql.items);
        defer q.deinit();
        try q.bindText(key);
        try bindPairsStatic(&q, arena.allocator(), resolvers[off..end], namehashes[off..end]);
        while (try q.step()) {
            // Loop-scoped errdefers: a later getText/append failure must free
            // the columns already duped this iteration (the outer errdefer
            // only sweeps rows already committed to the list).
            const r_opt = try q.getText(0);
            errdefer if (r_opt) |x| db.allocator.free(x);
            const nh_opt = try q.getText(1);
            errdefer if (nh_opt) |x| db.allocator.free(x);
            const val_opt = try q.getText(2);
            errdefer if (val_opt) |x| db.allocator.free(x);
            if (r_opt == null or nh_opt == null or val_opt == null) {
                if (r_opt) |x| db.allocator.free(x);
                if (nh_opt) |x| db.allocator.free(x);
                if (val_opt) |x| db.allocator.free(x);
                continue;
            }
            try rows.append(db.allocator, .{ .resolver = r_opt.?, .namehash = nh_opt.?, .value = val_opt.? });
        }
    }
    return try rows.toOwnedSlice(db.allocator);
}

/// All text record keys set by (resolver, namehash).
/// One row per (resolver, namehash, key) triple across all requested pairs —
/// the batched mirror of getTextRecordKeys. Global ORDER BY key means each
/// pair's keys arrive in the SAME ascending order the point query produces,
/// so grouping by pair in scan order reproduces its output exactly.
pub const PairTextKeyRow = struct { resolver: []u8, namehash: []u8, key: []u8 };

pub fn getTextRecordKeysForPairs(db: *Database, resolvers_list: []const Address, namehashes: []const Hash) ![]PairTextKeyRow {
    std.debug.assert(resolvers_list.len == namehashes.len);
    var rows: std.ArrayList(PairTextKeyRow) = .empty;
    errdefer {
        for (rows.items) |row| {
            db.allocator.free(row.resolver);
            db.allocator.free(row.namehash);
            db.allocator.free(row.key);
        }
        rows.deinit(db.allocator);
    }
    if (resolvers_list.len == 0) return try rows.toOwnedSlice(db.allocator);

    var off: usize = 0;
    while (off < resolvers_list.len) : (off += RECORD_BATCH_CHUNK) {
        const end = @min(off + RECORD_BATCH_CHUNK, resolvers_list.len);
        const n = end - off;

        var sql: std.ArrayList(u8) = .empty;
        defer sql.deinit(db.allocator);
        try sql.appendSlice(db.allocator, "SELECT DISTINCT resolver, namehash, key FROM resolver_texts WHERE (resolver, namehash) IN (");
        for (0..n) |i| {
            if (i > 0) try sql.appendSlice(db.allocator, ", ");
            try sql.appendSlice(db.allocator, "(?, ?)");
        }
        try sql.appendSlice(db.allocator, ") ORDER BY key");

        var arena = std.heap.ArenaAllocator.init(db.allocator);
        defer arena.deinit();

        var q = try Query.init(db, sql.items);
        defer q.deinit();
        try bindPairsStatic(&q, arena.allocator(), resolvers_list[off..end], namehashes[off..end]);
        while (try q.step()) {
            // Loop-scoped errdefers — see getTextRecordsBatch for rationale.
            const r_opt = try q.getText(0);
            errdefer if (r_opt) |x| db.allocator.free(x);
            const nh_opt = try q.getText(1);
            errdefer if (nh_opt) |x| db.allocator.free(x);
            const key_opt = try q.getText(2);
            errdefer if (key_opt) |x| db.allocator.free(x);
            if (r_opt == null or nh_opt == null or key_opt == null) {
                if (r_opt) |x| db.allocator.free(x);
                if (nh_opt) |x| db.allocator.free(x);
                if (key_opt) |x| db.allocator.free(x);
                continue;
            }
            try rows.append(db.allocator, .{ .resolver = r_opt.?, .namehash = nh_opt.?, .key = key_opt.? });
        }
    }
    return try rows.toOwnedSlice(db.allocator);
}

/// Distinct coin types per (resolver, namehash) across all requested pairs —
/// the batched mirror of getCoinTypes. Global ORDER BY coin_type means each
/// pair's list arrives in the SAME ascending order the point query produces,
/// so grouping by pair in scan order reproduces its output exactly.
pub const PairCoinTypeRow = struct { resolver: []u8, namehash: []u8, coin_type: u64 };

pub fn getCoinTypesForPairs(db: *Database, resolvers_list: []const Address, namehashes: []const Hash) ![]PairCoinTypeRow {
    std.debug.assert(resolvers_list.len == namehashes.len);
    var rows: std.ArrayList(PairCoinTypeRow) = .empty;
    errdefer {
        for (rows.items) |row| {
            db.allocator.free(row.resolver);
            db.allocator.free(row.namehash);
        }
        rows.deinit(db.allocator);
    }
    if (resolvers_list.len == 0) return try rows.toOwnedSlice(db.allocator);

    var off: usize = 0;
    while (off < resolvers_list.len) : (off += RECORD_BATCH_CHUNK) {
        const end = @min(off + RECORD_BATCH_CHUNK, resolvers_list.len);
        const n = end - off;

        var sql: std.ArrayList(u8) = .empty;
        defer sql.deinit(db.allocator);
        try sql.appendSlice(db.allocator, "SELECT DISTINCT resolver, namehash, coin_type FROM resolver_addresses WHERE (resolver, namehash) IN (");
        for (0..n) |i| {
            if (i > 0) try sql.appendSlice(db.allocator, ", ");
            try sql.appendSlice(db.allocator, "(?, ?)");
        }
        try sql.appendSlice(db.allocator, ") ORDER BY coin_type");

        var arena = std.heap.ArenaAllocator.init(db.allocator);
        defer arena.deinit();

        var q = try Query.init(db, sql.items);
        defer q.deinit();
        try bindPairsStatic(&q, arena.allocator(), resolvers_list[off..end], namehashes[off..end]);
        while (try q.step()) {
            // Loop-scoped errdefers — see getTextRecordsBatch for rationale.
            const r_opt = try q.getText(0);
            errdefer if (r_opt) |x| db.allocator.free(x);
            const nh_opt = try q.getText(1);
            errdefer if (nh_opt) |x| db.allocator.free(x);
            if (r_opt == null or nh_opt == null) {
                if (r_opt) |x| db.allocator.free(x);
                if (nh_opt) |x| db.allocator.free(x);
                continue;
            }
            try rows.append(db.allocator, .{ .resolver = r_opt.?, .namehash = nh_opt.?, .coin_type = @intCast(q.getInt64(2)) });
        }
    }
    return try rows.toOwnedSlice(db.allocator);
}

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

    var keys: std.ArrayList([]u8) = .empty;
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

/// VersionChanged record clears. The predicate MUST include protocol: every
/// record table's only sync-surviving index is its UNIQUE(protocol, resolver,
/// namehash, ...) constraint, and without the protocol equality the leftmost
/// prefix can't be used — each delete degraded to a full table scan during
/// bulk sync (measured 26s per VersionChanged event across the 7 tables).
/// Protocol scoping is also the correct semantics: the tables are
/// protocol-partitioned, and an unscoped delete could cross protocols.
pub fn deleteResolverAddresses(db: *Database, protocol: models.Protocol, namehash: Hash, resolver: Address) !void {
    try reorg_undo.captureWhere(db, "resolver_addresses", "D", "protocol = ? AND resolver = ? AND namehash = ?", .{ protocol, resolver, namehash });
    const sql = "DELETE FROM resolver_addresses WHERE protocol = ? AND resolver = ? AND namehash = ?";
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(resolver);
    try q.bindHash(namehash);
    try q.exec();
}

pub fn deleteResolverContentHash(db: *Database, protocol: models.Protocol, namehash: Hash, resolver: Address) !void {
    try reorg_undo.captureWhere(db, "resolver_contenthashes", "D", "protocol = ? AND resolver = ? AND namehash = ?", .{ protocol, resolver, namehash });
    const sql = "DELETE FROM resolver_contenthashes WHERE protocol = ? AND resolver = ? AND namehash = ?";
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(resolver);
    try q.bindHash(namehash);
    try q.exec();
}

pub fn deleteResolverTexts(db: *Database, protocol: models.Protocol, namehash: Hash, resolver: Address) !void {
    try reorg_undo.captureWhere(db, "resolver_texts", "D", "protocol = ? AND resolver = ? AND namehash = ?", .{ protocol, resolver, namehash });
    const sql = "DELETE FROM resolver_texts WHERE protocol = ? AND resolver = ? AND namehash = ?";
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(resolver);
    try q.bindHash(namehash);
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

pub fn deleteResolverPubkeys(db: *Database, protocol: models.Protocol, namehash: Hash, resolver: Address) !void {
    try reorg_undo.captureWhere(db, "resolver_pubkeys", "D", "protocol = ? AND resolver = ? AND namehash = ?", .{ protocol, resolver, namehash });
    const sql = "DELETE FROM resolver_pubkeys WHERE protocol = ? AND resolver = ? AND namehash = ?";
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(resolver);
    try q.bindHash(namehash);
    try q.exec();
}

pub fn deleteResolverAbis(db: *Database, protocol: models.Protocol, namehash: Hash, resolver: Address) !void {
    try reorg_undo.captureWhere(db, "resolver_abis", "D", "protocol = ? AND resolver = ? AND namehash = ?", .{ protocol, resolver, namehash });
    const sql = "DELETE FROM resolver_abis WHERE protocol = ? AND resolver = ? AND namehash = ?";
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(resolver);
    try q.bindHash(namehash);
    try q.exec();
}

pub fn deleteResolverNames(db: *Database, protocol: models.Protocol, namehash: Hash, resolver: Address) !void {
    try reorg_undo.captureWhere(db, "resolver_names", "D", "protocol = ? AND resolver = ? AND namehash = ?", .{ protocol, resolver, namehash });
    const sql = "DELETE FROM resolver_names WHERE protocol = ? AND resolver = ? AND namehash = ?";
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(resolver);
    try q.bindHash(namehash);
    try q.exec();
}

pub fn deleteResolverInterfaces(db: *Database, protocol: models.Protocol, namehash: Hash, resolver: Address) !void {
    try reorg_undo.captureWhere(db, "resolver_interfaces", "D", "protocol = ? AND resolver = ? AND namehash = ?", .{ protocol, resolver, namehash });
    const sql = "DELETE FROM resolver_interfaces WHERE protocol = ? AND resolver = ? AND namehash = ?";
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(resolver);
    try q.bindHash(namehash);
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

    var records: std.ArrayList(AliasRecord) = .empty;
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

    var types: std.ArrayList(u64) = .empty;
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

    var records: std.ArrayList(InterfaceRecord) = .empty;
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
