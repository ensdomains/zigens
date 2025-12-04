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
// SYNC/MIGRATION OPERATIONS (14 functions)
// ============================================================================

pub fn getSyncState(db: *Database, chain: models.Chain) !?u64 {
    const sql = "SELECT last_synced_block FROM sync_state WHERE chain = ?";

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
    _ = c.sqlite3_bind_text(stmt, 1, chain_str.ptr, @intCast(chain_str.len), c.SQLITE_STATIC);

    if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        return @intCast(c.sqlite3_column_int64(stmt, 0));
    }

    return null;
}

pub fn setSyncState(db: *Database, chain: models.Chain, block: u64) !void {
    const sql =
        \\INSERT OR REPLACE INTO sync_state (chain, last_synced_block, last_synced_at)
        \\VALUES (?, ?, ?)
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
    const now = std.time.timestamp();

    _ = c.sqlite3_bind_text(stmt, 1, chain_str.ptr, @intCast(chain_str.len), c.SQLITE_STATIC);
    _ = c.sqlite3_bind_int64(stmt, 2, @intCast(block));
    _ = c.sqlite3_bind_int64(stmt, 3, now);

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to set sync state: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.UpdateFailed;
    }
}

pub fn storeBlockHash(db: *Database, chain: models.Chain, block_number: u64, block_hash: Hash, parent_hash: Hash) !void {
    const sql =
        \\INSERT OR REPLACE INTO block_hashes
        \\(chain, block_number, block_hash, parent_hash, timestamp)
        \\VALUES (?, ?, ?, ?, ?)
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    defer {
        if (stmt) |s| _ = c.sqlite3_finalize(s);
    }

    if (c.sqlite3_prepare_v2(db.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
        std.log.err("Failed to prepare statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }

    const chain_str = chain.toString();
    // Format hashes manually
    var block_hash_hex: [66]u8 = undefined;
    block_hash_hex[0] = '0';
    block_hash_hex[1] = 'x';
    for (block_hash.bytes, 0..) |byte, i| {
        _ = std.fmt.bufPrint(block_hash_hex[2 + i * 2 ..][0..2], "{x:0>2}", .{byte}) catch unreachable;
    }

    var parent_hash_hex: [66]u8 = undefined;
    parent_hash_hex[0] = '0';
    parent_hash_hex[1] = 'x';
    for (parent_hash.bytes, 0..) |byte, i| {
        _ = std.fmt.bufPrint(parent_hash_hex[2 + i * 2 ..][0..2], "{x:0>2}", .{byte}) catch unreachable;
    }

    _ = c.sqlite3_bind_text(stmt, 1, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 2, @intCast(block_number));
    _ = c.sqlite3_bind_text(stmt, 3, block_hash_hex[0..66].ptr, 66, SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 4, parent_hash_hex[0..66].ptr, 66, SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 5, std.time.timestamp());

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to store block hash: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.InsertFailed;
    }
}

/// Get stored block hash for reorg detection
pub fn getBlockHash(db: *Database, chain: models.Chain, block_number: u64) !?Hash {
    const sql = "SELECT block_hash FROM block_hashes WHERE chain = ? AND block_number = ?";

    var stmt: ?*c.sqlite3_stmt = null;
    defer {
        if (stmt) |s| _ = c.sqlite3_finalize(s);
    }

    if (c.sqlite3_prepare_v2(db.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
        return error.PrepareFailed;
    }

    const chain_str = chain.toString();
    _ = c.sqlite3_bind_text(stmt, 1, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 2, @intCast(block_number));

    if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const hash_text = c.sqlite3_column_text(stmt, 0);
        const hash_len = c.sqlite3_column_bytes(stmt, 0);
        if (hash_text != null and hash_len > 0) {
            const hash_slice = hash_text[0..@intCast(hash_len)];
            return try Hash.fromHex(hash_slice);
        }
    }

    return null;
}

/// Delete block hashes and events from a block onwards (for reorg handling)
pub fn rollbackToBlock(db: *Database, chain: models.Chain, block_number: u64) !void {
    const chain_str = chain.toString();

    // Delete events
    const delete_events = "DELETE FROM events WHERE chain = ? AND block_number > ?";
    var stmt: ?*c.sqlite3_stmt = null;
    defer {
        if (stmt) |s| _ = c.sqlite3_finalize(s);
    }

    if (c.sqlite3_prepare_v2(db.db, delete_events, -1, &stmt, null) != c.SQLITE_OK) {
        return error.PrepareFailed;
    }

    _ = c.sqlite3_bind_text(stmt, 1, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 2, @intCast(block_number));

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to delete events during rollback: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.RollbackFailed;
    }

    _ = c.sqlite3_finalize(stmt);
    stmt = null;

    // Delete block hashes
    const delete_blocks = "DELETE FROM block_hashes WHERE chain = ? AND block_number > ?";
    if (c.sqlite3_prepare_v2(db.db, delete_blocks, -1, &stmt, null) != c.SQLITE_OK) {
        return error.PrepareFailed;
    }

    _ = c.sqlite3_bind_text(stmt, 1, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 2, @intCast(block_number));

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to delete block hashes during rollback: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.RollbackFailed;
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

    var stmt: ?*c.sqlite3_stmt = null;
    defer {
        if (stmt) |s| _ = c.sqlite3_finalize(s);
    }

    if (c.sqlite3_prepare_v2(db.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
        return error.PrepareFailed;
    }

    const chain_str = chain.toString();
    _ = c.sqlite3_bind_text(stmt, 1, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 2, @intCast(cutoff_block));

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to prune old block hashes: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PruneFailed;
    }
}

/// Verify database integrity
pub fn checkIntegrity(db: *Database) !bool {
    const sql = "PRAGMA integrity_check";
    var stmt: ?*c.sqlite3_stmt = null;
    defer {
        if (stmt) |s| _ = c.sqlite3_finalize(s);
    }

    if (c.sqlite3_prepare_v2(db.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
        return error.PrepareFailed;
    }

    if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const result = c.sqlite3_column_text(stmt, 0);
        if (result != null) {
            const result_len = c.sqlite3_column_bytes(stmt, 0);
            const result_slice = result[0..@intCast(result_len)];
            const is_ok = std.mem.eql(u8, result_slice, "ok");
            if (!is_ok) {
                std.log.err("Database integrity check failed: {s}", .{result_slice});
            }
            return is_ok;
        }
    }

    return false;
}

/// Register or update a known subregistry
pub fn registerSubregistry(db: *Database, chain: models.Chain, address: []const u8, block_number: u64) !void {
    const sql =
        \\INSERT INTO known_subregistries (chain, address, first_seen_block, last_indexed_block)
        \\VALUES (?, ?, ?, ?)
        \\ON CONFLICT(chain, address) DO UPDATE SET
        \\  last_indexed_block = MAX(last_indexed_block, excluded.last_indexed_block)
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    defer {
        if (stmt) |s| _ = c.sqlite3_finalize(s);
    }

    if (c.sqlite3_prepare_v2(db.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
        return error.PrepareFailed;
    }

    const chain_str = chain.toString();
    _ = c.sqlite3_bind_text(stmt, 1, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 2, address.ptr, @intCast(address.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 3, @intCast(block_number));
    _ = c.sqlite3_bind_int64(stmt, 4, @intCast(block_number));

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        return error.ExecuteFailed;
    }
}

/// Register or update a known resolver
pub fn registerResolver(db: *Database, chain: models.Chain, address: []const u8, block_number: u64) !void {
    const sql =
        \\INSERT INTO known_resolvers (chain, address, first_seen_block, last_indexed_block)
        \\VALUES (?, ?, ?, ?)
        \\ON CONFLICT(chain, address) DO UPDATE SET
        \\  last_indexed_block = MAX(last_indexed_block, excluded.last_indexed_block)
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    defer {
        if (stmt) |s| _ = c.sqlite3_finalize(s);
    }

    if (c.sqlite3_prepare_v2(db.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
        return error.PrepareFailed;
    }

    const chain_str = chain.toString();
    _ = c.sqlite3_bind_text(stmt, 1, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 2, address.ptr, @intCast(address.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 3, @intCast(block_number));
    _ = c.sqlite3_bind_int64(stmt, 4, @intCast(block_number));

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        return error.ExecuteFailed;
    }
}

/// Get subregistries to index for a block range
/// Uses cache table for O(1) lookup, falls back to full scan on first run
pub fn getSubregistriesToIndex(db: *Database, chain: models.Chain, main_registry: []const u8, from_block: u64, to_block: u64) ![][]u8 {
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

    var stmt: ?*c.sqlite3_stmt = null;
    defer {
        if (stmt) |s| _ = c.sqlite3_finalize(s);
    }

    if (c.sqlite3_prepare_v2(db.db, discover_sql, -1, &stmt, null) != c.SQLITE_OK) {
        return error.PrepareFailed;
    }

    const chain_str = chain.toString();
    _ = c.sqlite3_bind_text(stmt, 1, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 2, main_registry.ptr, @intCast(main_registry.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 3, @intCast(from_block));
    _ = c.sqlite3_bind_int64(stmt, 4, @intCast(to_block));

    // Register newly discovered subregistries
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const addr_text = c.sqlite3_column_text(stmt, 0);
        if (addr_text != null) {
            const addr_len = c.sqlite3_column_bytes(stmt, 0);
            const addr_slice = addr_text[0..@intCast(addr_len)];
            try db.registerSubregistry(chain, addr_slice, from_block);
        }
    }
    _ = c.sqlite3_finalize(stmt);

    // Now get ALL known subregistries from cache (very fast)
    const get_sql =
        \\SELECT address FROM known_subregistries
        \\WHERE chain = ?
        \\ORDER BY address
    ;

    if (c.sqlite3_prepare_v2(db.db, get_sql, -1, &stmt, null) != c.SQLITE_OK) {
        return error.PrepareFailed;
    }

    _ = c.sqlite3_bind_text(stmt, 1, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());

    var subregistries: std.ArrayList([]u8) = .{};
    errdefer {
        for (subregistries.items) |subreg| {
            db.allocator.free(subreg);
        }
        subregistries.deinit(db.allocator);
    }

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const addr_text = c.sqlite3_column_text(stmt, 0);
        if (addr_text != null) {
            const addr_len = c.sqlite3_column_bytes(stmt, 0);
            const addr_slice = addr_text[0..@intCast(addr_len)];
            const addr_copy = try db.allocator.dupe(u8, addr_slice);
            try subregistries.append(db.allocator, addr_copy);
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
    const token_id_str = try std.fmt.allocPrint(db.allocator, "{d}", .{token_id});
    defer db.allocator.free(token_id_str);
    const direction_str = direction.toString();
    const tx_hash_hex = try tx_hash.toHex(db.allocator);
    defer db.allocator.free(tx_hash_hex);
    const timestamp = std.time.timestamp();

    _ = c.sqlite3_bind_text(stmt, 1, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 2, token_id_str.ptr, @intCast(token_id_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 3, direction_str.ptr, @intCast(direction_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 4, dns_encoded_name.ptr, @intCast(dns_encoded_name.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 5, @intCast(block_number));
    _ = c.sqlite3_bind_text(stmt, 6, tx_hash_hex.ptr, @intCast(tx_hash_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int(stmt, 7, @intCast(log_index));
    _ = c.sqlite3_bind_int64(stmt, 8, timestamp);

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to insert migration: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.InsertFailed;
    }
}

/// Insert a renewal sync event
pub fn insertRenewalSync(db: *Database, chain: models.Chain, token_id: u256, new_expiry: u64, block_number: u64, tx_hash: Hash, log_index: u32) !void {
    const sql =
        \\INSERT OR IGNORE INTO renewal_syncs
        \\(chain, token_id, new_expiry, block_number, transaction_hash, log_index, timestamp)
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

    const chain_str = chain.toString();
    const token_id_str = try std.fmt.allocPrint(db.allocator, "{d}", .{token_id});
    defer db.allocator.free(token_id_str);
    const tx_hash_hex = try tx_hash.toHex(db.allocator);
    defer db.allocator.free(tx_hash_hex);
    const timestamp = std.time.timestamp();

    _ = c.sqlite3_bind_text(stmt, 1, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 2, token_id_str.ptr, @intCast(token_id_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 3, @intCast(new_expiry));
    _ = c.sqlite3_bind_int64(stmt, 4, @intCast(block_number));
    _ = c.sqlite3_bind_text(stmt, 5, tx_hash_hex.ptr, @intCast(tx_hash_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int(stmt, 6, @intCast(log_index));
    _ = c.sqlite3_bind_int64(stmt, 7, timestamp);

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to insert renewal sync: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.InsertFailed;
    }
}

/// Insert a token observer event
pub fn insertTokenObserver(db: *Database, chain: models.Chain, token_id: u256, observer: Address, block_number: u64, tx_hash: Hash, log_index: u32) !void {
    const sql =
        \\INSERT OR IGNORE INTO token_observers
        \\(chain, token_id, observer, block_number, transaction_hash, log_index, timestamp)
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

    const chain_str = chain.toString();
    const token_id_str = try std.fmt.allocPrint(db.allocator, "{d}", .{token_id});
    defer db.allocator.free(token_id_str);
    const observer_hex = try observer.toHex(db.allocator);
    defer db.allocator.free(observer_hex);
    const tx_hash_hex = try tx_hash.toHex(db.allocator);
    defer db.allocator.free(tx_hash_hex);
    const timestamp = std.time.timestamp();

    _ = c.sqlite3_bind_text(stmt, 1, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 2, token_id_str.ptr, @intCast(token_id_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 3, observer_hex.ptr, @intCast(observer_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 4, @intCast(block_number));
    _ = c.sqlite3_bind_text(stmt, 5, tx_hash_hex.ptr, @intCast(tx_hash_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int(stmt, 6, @intCast(log_index));
    _ = c.sqlite3_bind_int64(stmt, 7, timestamp);

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to insert token observer: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.InsertFailed;
    }
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

        const sql_z = try db.allocator.dupeZ(u8, sql);
        defer db.allocator.free(sql_z);

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            std.log.err("Failed to prepare delete for {s}: {s}", .{ table.name, c.sqlite3_errmsg(db.db) });
            return error.PrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_int64(stmt, 1, @intCast(block_number));

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            std.log.err("Failed to delete from {s}: {s}", .{ table.name, c.sqlite3_errmsg(db.db) });
            return error.DeleteFailed;
        }

        const deleted = c.sqlite3_changes(db.db);
        if (deleted > 0) {
            std.log.info("  Deleted {d} rows from {s}", .{ deleted, table.name });
        }
    }

    // Commit transaction
    try db.exec("COMMIT");
    std.log.info("Data cleanup complete", .{});
}
