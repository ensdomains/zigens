const std = @import("std");
const db_module = @import("database.zig");
const Database = db_module.Database;
const Query = db_module.Query;
const models = @import("../types/models.zig");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;

// ============================================================================
// SYNC/MIGRATION OPERATIONS
// ============================================================================

pub fn getSyncState(db: *Database, chain: models.Chain) !?u64 {
    const sql = "SELECT last_synced_block FROM sync_state WHERE chain = ?";

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindTextStatic(chain.toString());

    if (try q.step()) {
        return @intCast(q.getInt64(0));
    }
    return null;
}

pub fn setSyncState(db: *Database, chain: models.Chain, block: u64) !void {
    const sql =
        \\INSERT OR REPLACE INTO sync_state (chain, last_synced_block, last_synced_at)
        \\VALUES (?, ?, ?)
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindTextStatic(chain.toString());
    try q.bindInt64(@intCast(block));
    try q.bindInt64(std.time.timestamp());

    try q.exec();
}

pub fn storeBlockHash(db: *Database, chain: models.Chain, block_number: u64, block_hash: Hash, parent_hash: Hash) !void {
    const sql =
        \\INSERT OR REPLACE INTO block_hashes
        \\(chain, block_number, block_hash, parent_hash, timestamp)
        \\VALUES (?, ?, ?, ?, ?)
    ;

    var q = try Query.initCached(db, sql);
    defer q.deinit();

    try q.bindTextStatic(chain.toString());
    try q.bindInt64(@intCast(block_number));
    try q.bindHashBuf(block_hash);
    try q.bindHashBuf(parent_hash);
    try q.bindInt64(std.time.timestamp());

    try q.exec();
}

/// Get stored block hash for reorg detection
pub fn getBlockHash(db: *Database, chain: models.Chain, block_number: u64) !?Hash {
    const sql = "SELECT block_hash FROM block_hashes WHERE chain = ? AND block_number = ?";

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindTextStatic(chain.toString());
    try q.bindInt64(@intCast(block_number));

    if (try q.step()) {
        return try q.getHash(0);
    }
    return null;
}

/// Delete block hashes and events from a block onwards (for reorg handling)
pub fn rollbackToBlock(db: *Database, chain: models.Chain, block_number: u64) !void {
    const chain_str = chain.toString();

    // Delete events
    {
        const delete_events = "DELETE FROM events WHERE chain = ? AND block_number > ?";
        var q = try Query.init(db, delete_events);
        defer q.deinit();

        try q.bindTextStatic(chain_str);
        try q.bindInt64(@intCast(block_number));
        try q.exec();
    }

    // Delete block hashes
    {
        const delete_blocks = "DELETE FROM block_hashes WHERE chain = ? AND block_number > ?";
        var q = try Query.init(db, delete_blocks);
        defer q.deinit();

        try q.bindTextStatic(chain_str);
        try q.bindInt64(@intCast(block_number));
        try q.exec();
    }

    // Update sync state
    try db.setSyncState(chain, block_number);

    std.log.warn("Rolled back {s} chain to block {d}", .{ chain_str, block_number });
}

/// Cleanup old block hashes (keep last 1000 blocks for reorg detection)
pub fn pruneOldBlockHashes(db: *Database, chain: models.Chain, current_block: u64) !void {
    const keep_blocks = 1000;
    if (current_block <= keep_blocks) return;

    const cutoff_block = current_block - keep_blocks;
    const sql = "DELETE FROM block_hashes WHERE chain = ? AND block_number < ?";

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindTextStatic(chain.toString());
    try q.bindInt64(@intCast(cutoff_block));
    try q.exec();
}

/// Verify database integrity (uses quick_check for performance on large databases)
pub fn checkIntegrity(db: *Database) !bool {
    const sql = "PRAGMA quick_check";

    var q = try Query.init(db, sql);
    defer q.deinit();

    if (try q.step()) {
        if (q.getTextSlice(0)) |result_slice| {
            const is_ok = std.mem.eql(u8, result_slice, "ok");
            if (!is_ok) {
                std.log.err("Database integrity check failed: {s}", .{result_slice});
            }
            return is_ok;
        }
    }
    return false;
}

/// Check if a subregistry is already known
pub fn isSubregistryKnown(db: *Database, chain: models.Chain, address: []const u8) !bool {
    const sql = "SELECT 1 FROM known_subregistries WHERE chain = ? AND address = ? LIMIT 1";

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindTextStatic(chain.toString());
    try q.bindText(address);

    return try q.step();
}

/// Register or update a known subregistry
pub fn registerSubregistry(db: *Database, chain: models.Chain, address: []const u8, block_number: u64) !void {
    const sql =
        \\INSERT INTO known_subregistries (chain, address, first_seen_block, last_indexed_block)
        \\VALUES (?, ?, ?, ?)
        \\ON CONFLICT(chain, address) DO UPDATE SET
        \\  last_indexed_block = MAX(last_indexed_block, excluded.last_indexed_block)
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindTextStatic(chain.toString());
    try q.bindText(address);
    try q.bindInt64(@intCast(block_number));
    try q.bindInt64(@intCast(block_number));

    try q.exec();
}

/// Register or update a known resolver
pub fn registerResolver(db: *Database, chain: models.Chain, address: []const u8, block_number: u64) !void {
    const sql =
        \\INSERT INTO known_resolvers (chain, address, first_seen_block, last_indexed_block)
        \\VALUES (?, ?, ?, ?)
        \\ON CONFLICT(chain, address) DO UPDATE SET
        \\  last_indexed_block = MAX(last_indexed_block, excluded.last_indexed_block)
    ;

    var q = try Query.initCached(db, sql);
    defer q.deinit();

    try q.bindTextStatic(chain.toString());
    try q.bindText(address);
    try q.bindInt64(@intCast(block_number));
    try q.bindInt64(@intCast(block_number));

    try q.exec();
}

/// Get subregistries to index for a block range
/// Uses cache table for O(1) lookup, falls back to full scan on first run
pub fn getSubregistriesToIndex(db: *Database, chain: models.Chain, main_registry: []const u8, from_block: u64, to_block: u64) ![][]u8 {
    const chain_str = chain.toString();

    // First, discover any NEW subregistries from registries table (only those registered in this block range)
    const discover_sql =
        \\SELECT DISTINCT r.address
        \\FROM registries r
        \\LEFT JOIN known_subregistries ks ON ks.chain = r.chain AND ks.address = r.address
        \\WHERE r.chain = ?
        \\  AND r.address != '0x0000000000000000000000000000000000000000'
        \\  AND r.address != ?
        \\  AND r.created_block >= ?
        \\  AND r.created_block <= ?
        \\  AND ks.address IS NULL
    ;

    {
        var q = try Query.init(db, discover_sql);
        defer q.deinit();

        try q.bindTextStatic(chain_str);
        try q.bindText(main_registry);
        try q.bindInt64(@intCast(from_block));
        try q.bindInt64(@intCast(to_block));

        // Register newly discovered subregistries
        while (try q.step()) {
            if (q.getTextSlice(0)) |addr_slice| {
                try db.registerSubregistry(chain, addr_slice, from_block);
            }
        }
    }

    // Now get ALL known subregistries from cache (very fast)
    const get_sql =
        \\SELECT address FROM known_subregistries
        \\WHERE chain = ?
        \\ORDER BY address
    ;

    var q2 = try Query.init(db, get_sql);
    defer q2.deinit();

    try q2.bindTextStatic(chain_str);

    var subregistries: std.ArrayList([]u8) = .{};
    errdefer {
        for (subregistries.items) |subreg| {
            db.allocator.free(subreg);
        }
        subregistries.deinit(db.allocator);
    }

    while (try q2.step()) {
        if (try q2.getText(0)) |addr| {
            try subregistries.append(db.allocator, addr);
        }
    }

    return subregistries.toOwnedSlice(db.allocator);
}

/// Insert a migration event
pub fn insertMigration(db: *Database, chain: models.Chain, token_id: u256, direction: models.MigrationDirection, dns_encoded_name: []const u8, block_number: u64, tx_hash: Hash, log_index: u32) !void {
    const sql =
        \\INSERT OR IGNORE INTO migrations
        \\(chain, token_id, direction, dns_encoded_name, block_number, transaction_hash, log_index, timestamp)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    const token_id_str = try std.fmt.allocPrint(db.allocator, "{d}", .{token_id});
    defer db.allocator.free(token_id_str);

    try q.bindTextStatic(chain.toString());
    try q.bindText(token_id_str);
    try q.bindTextStatic(direction.toString());
    try q.bindText(dns_encoded_name);
    try q.bindInt64(@intCast(block_number));
    try q.bindHash(tx_hash);
    try q.bindInt(@intCast(log_index));
    try q.bindInt64(std.time.timestamp());

    try q.exec();
}

/// Insert a renewal sync event
pub fn insertRenewalSync(db: *Database, chain: models.Chain, token_id: u256, new_expiry: u64, block_number: u64, tx_hash: Hash, log_index: u32) !void {
    const sql =
        \\INSERT OR IGNORE INTO renewal_syncs
        \\(chain, token_id, new_expiry, block_number, transaction_hash, log_index, timestamp)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    const token_id_str = try std.fmt.allocPrint(db.allocator, "{d}", .{token_id});
    defer db.allocator.free(token_id_str);

    try q.bindTextStatic(chain.toString());
    try q.bindText(token_id_str);
    try q.bindInt64(@bitCast(new_expiry));
    try q.bindInt64(@intCast(block_number));
    try q.bindHash(tx_hash);
    try q.bindInt(@intCast(log_index));
    try q.bindInt64(std.time.timestamp());

    try q.exec();
}

/// Insert a token observer event
pub fn insertTokenObserver(db: *Database, chain: models.Chain, token_id: u256, observer: Address, block_number: u64, tx_hash: Hash, log_index: u32) !void {
    const sql =
        \\INSERT OR IGNORE INTO token_observers
        \\(chain, token_id, observer, block_number, transaction_hash, log_index, timestamp)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    const token_id_str = try std.fmt.allocPrint(db.allocator, "{d}", .{token_id});
    defer db.allocator.free(token_id_str);

    try q.bindTextStatic(chain.toString());
    try q.bindText(token_id_str);
    try q.bindAddress(observer);
    try q.bindInt64(@intCast(block_number));
    try q.bindHash(tx_hash);
    try q.bindInt(@intCast(log_index));
    try q.bindInt64(std.time.timestamp());

    try q.exec();
}

/// Delete all data after a specific block (for clean re-indexing)
pub fn deleteDataAfterBlock(db: *Database, block_number: u64) !void {
    std.log.info("Deleting data after block {d}...", .{block_number});

    // List of tables to clean, with their block_number column name
    const tables = [_]struct { name: []const u8, block_col: []const u8 }{
        .{ .name = "names", .block_col = "created_block" },
        .{ .name = "events", .block_col = "block_number" },
        .{ .name = "approvals", .block_col = "block_number" },
        .{ .name = "resolver_addresses", .block_col = "block_number" },
        .{ .name = "resolver_contenthashes", .block_col = "block_number" },
        .{ .name = "resolver_texts", .block_col = "block_number" },
        .{ .name = "migrations", .block_col = "block_number" },
        .{ .name = "renewal_syncs", .block_col = "block_number" },
        .{ .name = "token_observers", .block_col = "block_number" },
        .{ .name = "resolver_aliases", .block_col = "block_number" },
        .{ .name = "resolver_pubkeys", .block_col = "block_number" },
        .{ .name = "resolver_abis", .block_col = "block_number" },
        .{ .name = "resolver_names", .block_col = "block_number" },
        .{ .name = "resolver_interfaces", .block_col = "block_number" },
        .{ .name = "resolver_versions", .block_col = "block_number" },
    };

    // Begin transaction for atomic cleanup
    try db.exec("BEGIN TRANSACTION");
    errdefer {
        db.exec("ROLLBACK") catch |err| {
            std.log.err("CRITICAL: Failed to rollback transaction during cleanup error: {}", .{err});
        };
    }

    for (tables) |table| {
        const sql = try std.fmt.allocPrint(
            db.allocator,
            "DELETE FROM {s} WHERE {s} > ?",
            .{ table.name, table.block_col },
        );
        defer db.allocator.free(sql);

        var q = try Query.init(db, sql);
        defer q.deinit();

        try q.bindInt64(@intCast(block_number));
        try q.exec();

        const deleted = q.changes();
        if (deleted > 0) {
            std.log.info("  Deleted {d} rows from {s}", .{ deleted, table.name });
        }
    }

    // Commit transaction
    try db.exec("COMMIT");
    std.log.info("Data cleanup complete", .{});
}

// ============================================================================
// ORPHANED REGISTRATIONS
// ============================================================================

/// Orphaned registration data - NameRegistered events skipped due to no parent
pub const OrphanedRegistration = struct {
    chain: models.Chain,
    subregistry_address: []const u8,
    token_id: u256,
    label: []const u8,
    expiry: u64,
    owner: Address,
    block_number: u64,
    tx_hash: Hash,
    log_index: u32,

    pub fn deinit(self: *OrphanedRegistration, allocator: std.mem.Allocator) void {
        allocator.free(self.subregistry_address);
        allocator.free(self.label);
    }
};

/// Store an orphaned NameRegistered event for later processing
pub fn insertOrphanedRegistration(
    db: *Database,
    chain: models.Chain,
    subregistry_address: []const u8,
    token_id: u256,
    label: []const u8,
    expiry: u64,
    owner: Address,
    block_number: u64,
    tx_hash: Hash,
    log_index: u32,
) !void {
    const sql =
        \\INSERT OR IGNORE INTO orphaned_registrations
        \\(chain, subregistry_address, token_id, label, expiry, owner, block_number, tx_hash, log_index, created_at)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    const token_id_str = try std.fmt.allocPrint(db.allocator, "0x{x:0>64}", .{token_id});
    defer db.allocator.free(token_id_str);

    try q.bindTextStatic(chain.toString());
    try q.bindText(subregistry_address);
    try q.bindText(token_id_str);
    try q.bindText(label);
    try q.bindInt64(@bitCast(expiry));
    try q.bindAddress(owner);
    try q.bindInt64(@intCast(block_number));
    try q.bindHash(tx_hash);
    try q.bindInt(@intCast(log_index));
    try q.bindInt64(std.time.timestamp());

    try q.exec();
}

/// Get orphaned registrations for a subregistry address
pub fn getOrphanedRegistrations(db: *Database, chain: models.Chain, subregistry_address: []const u8) ![]OrphanedRegistration {
    const sql =
        \\SELECT chain, subregistry_address, token_id, label, expiry, owner, block_number, tx_hash, log_index
        \\FROM orphaned_registrations
        \\WHERE chain = ? AND subregistry_address = ?
        \\ORDER BY block_number ASC
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindTextStatic(chain.toString());
    try q.bindText(subregistry_address);

    var results: std.ArrayList(OrphanedRegistration) = .{};
    errdefer {
        for (results.items) |*item| {
            item.deinit(db.allocator);
        }
        results.deinit(db.allocator);
    }

    while (try q.step()) {
        const chain_str = q.getTextSlice(0) orelse continue;
        const addr_str = q.getTextSlice(1) orelse continue;
        const token_id_str = q.getTextSlice(2) orelse continue;
        const label_str = q.getTextSlice(3) orelse continue;
        const owner_str = q.getTextSlice(5) orelse continue;
        const tx_hash_str = q.getTextSlice(7) orelse continue;

        // Parse token_id from hex
        const token_id_clean = if (std.mem.startsWith(u8, token_id_str, "0x")) token_id_str[2..] else token_id_str;
        const token_id = std.fmt.parseInt(u256, token_id_clean, 16) catch continue;

        try results.append(db.allocator, .{
            .chain = models.Chain.fromString(chain_str) catch continue,
            .subregistry_address = try db.allocator.dupe(u8, addr_str),
            .token_id = token_id,
            .label = try db.allocator.dupe(u8, label_str),
            .expiry = @bitCast(q.getInt64(4)),
            .owner = Address.fromHex(owner_str) catch continue,
            .block_number = @intCast(q.getInt64(6)),
            .tx_hash = Hash.fromHex(tx_hash_str) catch continue,
            .log_index = @intCast(q.getInt(8)),
        });
    }

    return results.toOwnedSlice(db.allocator);
}

/// Delete orphaned registrations after they've been processed
pub fn deleteOrphanedRegistrations(db: *Database, chain: models.Chain, subregistry_address: []const u8) !void {
    const sql = "DELETE FROM orphaned_registrations WHERE chain = ? AND subregistry_address = ?";

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindTextStatic(chain.toString());
    try q.bindText(subregistry_address);

    try q.exec();
}
