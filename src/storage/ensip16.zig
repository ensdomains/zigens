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
// ENSIP-16: RESOLVER METADATA OPERATIONS (3 functions)
// ============================================================================

/// Upsert resolver metadata (GraphQL endpoint for offchain data)
pub fn upsertResolverMetadata(db: *Database, chain: models.Chain, resolver: Address, graphql_url: []const u8, block_number: u64, tx_hash: Hash) !void {
    const sql =
        \\INSERT INTO resolver_metadata
        \\(chain, resolver, graphql_url, block_number, transaction_hash, timestamp)
        \\VALUES (?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(chain, resolver) DO UPDATE SET
        \\  graphql_url = excluded.graphql_url,
        \\  block_number = excluded.block_number,
        \\  transaction_hash = excluded.transaction_hash,
        \\  timestamp = excluded.timestamp
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
    const resolver_hex = try resolver.toHex(db.allocator);
    defer db.allocator.free(resolver_hex);
    const tx_hash_hex = try tx_hash.toHex(db.allocator);
    defer db.allocator.free(tx_hash_hex);

    const now = @as(i64, @intCast(std.time.timestamp()));

    _ = c.sqlite3_bind_text(stmt, 1, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 2, resolver_hex.ptr, @intCast(resolver_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 3, graphql_url.ptr, @intCast(graphql_url.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 4, @intCast(block_number));
    _ = c.sqlite3_bind_text(stmt, 5, tx_hash_hex.ptr, @intCast(tx_hash_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 6, now);

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to upsert resolver metadata: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.InsertFailed;
    }
}

/// Get resolver metadata for a specific resolver
pub fn getResolverMetadata(db: *Database, chain: models.Chain, resolver: Address) !?models.ResolverMetadata {
    const sql =
        \\SELECT id, chain, resolver, graphql_url, block_number, transaction_hash, timestamp
        \\FROM resolver_metadata
        \\WHERE chain = ? AND resolver = ?
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
    const resolver_hex = try resolver.toHex(db.allocator);
    defer db.allocator.free(resolver_hex);

    _ = c.sqlite3_bind_text(stmt, 1, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 2, resolver_hex.ptr, @intCast(resolver_hex.len), SQLITE_TRANSIENT());

    if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const chain_col = std.mem.span(c.sqlite3_column_text(stmt, 1));
        const resolver_col = std.mem.span(c.sqlite3_column_text(stmt, 2));
        const graphql_url_col = std.mem.span(c.sqlite3_column_text(stmt, 3));
        const tx_hash_col = std.mem.span(c.sqlite3_column_text(stmt, 5));

        return models.ResolverMetadata{
            .id = @intCast(c.sqlite3_column_int64(stmt, 0)),
            .chain = try models.Chain.fromString(chain_col),
            .resolver = try Address.fromHex(resolver_col),
            .graphql_url = try db.allocator.dupe(u8, graphql_url_col),
            .block_number = @intCast(c.sqlite3_column_int64(stmt, 4)),
            .tx_hash = try Hash.fromHex(tx_hash_col),
            .timestamp = c.sqlite3_column_int64(stmt, 6),
        };
    }

    return null;
}

/// Get all resolvers with offchain metadata
pub fn getAllResolverMetadata(db: *Database, chain: models.Chain) ![]models.ResolverMetadata {
    const sql =
        \\SELECT id, chain, resolver, graphql_url, block_number, transaction_hash, timestamp
        \\FROM resolver_metadata
        \\WHERE chain = ?
        \\ORDER BY timestamp DESC
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
    _ = c.sqlite3_bind_text(stmt, 1, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());

    var result: std.ArrayList(models.ResolverMetadata) = .{};
    errdefer {
        for (result.items) |*metadata| {
            metadata.deinit(db.allocator);
        }
        result.deinit(db.allocator);
    }

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const chain_col = std.mem.span(c.sqlite3_column_text(stmt, 1));
        const resolver_col = std.mem.span(c.sqlite3_column_text(stmt, 2));
        const graphql_url_col = std.mem.span(c.sqlite3_column_text(stmt, 3));
        const tx_hash_col = std.mem.span(c.sqlite3_column_text(stmt, 5));

        const metadata = models.ResolverMetadata{
            .id = @intCast(c.sqlite3_column_int64(stmt, 0)),
            .chain = try models.Chain.fromString(chain_col),
            .resolver = try Address.fromHex(resolver_col),
            .graphql_url = try db.allocator.dupe(u8, graphql_url_col),
            .block_number = @intCast(c.sqlite3_column_int64(stmt, 4)),
            .tx_hash = try Hash.fromHex(tx_hash_col),
            .timestamp = c.sqlite3_column_int64(stmt, 6),
        };

        try result.append(db.allocator, metadata);
    }

    return result.toOwnedSlice(db.allocator);
}

// ============================================================================
// ENSIP-16: RESOLVER APPROVAL OPERATIONS (4 functions)
// ============================================================================

/// Insert or update resolver approval/delegation
pub fn upsertResolverApproval(db: *Database, chain: models.Chain, resolver: Address, namehash: Hash, context: ?[]const u8, delegate: Address, approved: bool, block_number: u64, tx_hash: Hash, log_index: u32) !void {
    const sql =
        \\INSERT INTO resolver_approvals
        \\(chain, resolver, namehash, context, delegate, approved, block_number, transaction_hash, log_index, timestamp)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(chain, resolver, namehash, context, delegate) DO UPDATE SET
        \\  approved = excluded.approved,
        \\  block_number = excluded.block_number,
        \\  transaction_hash = excluded.transaction_hash,
        \\  log_index = excluded.log_index,
        \\  timestamp = excluded.timestamp
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
    const resolver_hex = try resolver.toHex(db.allocator);
    defer db.allocator.free(resolver_hex);
    const namehash_hex = try namehash.toHex(db.allocator);
    defer db.allocator.free(namehash_hex);
    const delegate_hex = try delegate.toHex(db.allocator);
    defer db.allocator.free(delegate_hex);
    const tx_hash_hex = try tx_hash.toHex(db.allocator);
    defer db.allocator.free(tx_hash_hex);

    const now = @as(i64, @intCast(std.time.timestamp()));

    _ = c.sqlite3_bind_text(stmt, 1, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 2, resolver_hex.ptr, @intCast(resolver_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 3, namehash_hex.ptr, @intCast(namehash_hex.len), SQLITE_TRANSIENT());

    if (context) |ctx| {
        _ = c.sqlite3_bind_text(stmt, 4, ctx.ptr, @intCast(ctx.len), SQLITE_TRANSIENT());
    } else {
        _ = c.sqlite3_bind_null(stmt, 4);
    }

    _ = c.sqlite3_bind_text(stmt, 5, delegate_hex.ptr, @intCast(delegate_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int(stmt, 6, if (approved) 1 else 0);
    _ = c.sqlite3_bind_int64(stmt, 7, @intCast(block_number));
    _ = c.sqlite3_bind_text(stmt, 8, tx_hash_hex.ptr, @intCast(tx_hash_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int(stmt, 9, @intCast(log_index));
    _ = c.sqlite3_bind_int64(stmt, 10, now);

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to upsert resolver approval: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.InsertFailed;
    }
}

/// Check if a delegate is approved for a name (with optional context)
pub fn isApprovedFor(db: *Database, chain: models.Chain, resolver: Address, namehash: Hash, context: ?[]const u8, delegate: Address) !bool {
    const sql =
        \\SELECT approved
        \\FROM resolver_approvals
        \\WHERE chain = ? AND resolver = ? AND namehash = ? AND context IS ? AND delegate = ?
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
    const resolver_hex = try resolver.toHex(db.allocator);
    defer db.allocator.free(resolver_hex);
    const namehash_hex = try namehash.toHex(db.allocator);
    defer db.allocator.free(namehash_hex);
    const delegate_hex = try delegate.toHex(db.allocator);
    defer db.allocator.free(delegate_hex);

    _ = c.sqlite3_bind_text(stmt, 1, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 2, resolver_hex.ptr, @intCast(resolver_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 3, namehash_hex.ptr, @intCast(namehash_hex.len), SQLITE_TRANSIENT());

    if (context) |ctx| {
        _ = c.sqlite3_bind_text(stmt, 4, ctx.ptr, @intCast(ctx.len), SQLITE_TRANSIENT());
    } else {
        _ = c.sqlite3_bind_null(stmt, 4);
    }

    _ = c.sqlite3_bind_text(stmt, 5, delegate_hex.ptr, @intCast(delegate_hex.len), SQLITE_TRANSIENT());

    if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        return c.sqlite3_column_int(stmt, 0) != 0;
    }

    return false; // Not found = not approved
}

/// Get all approvals for a specific name (with optional context filter)
pub fn getApprovalsForName(db: *Database, chain: models.Chain, namehash: Hash, context: ?[]const u8) ![]models.ResolverApproval {
    const sql =
        \\SELECT id, chain, resolver, namehash, context, delegate, approved, block_number, transaction_hash, log_index, timestamp
        \\FROM resolver_approvals
        \\WHERE chain = ? AND namehash = ? AND (context IS ? OR ? IS NULL)
        \\ORDER BY timestamp DESC
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
    const namehash_hex = try namehash.toHex(db.allocator);
    defer db.allocator.free(namehash_hex);

    _ = c.sqlite3_bind_text(stmt, 1, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 2, namehash_hex.ptr, @intCast(namehash_hex.len), SQLITE_TRANSIENT());

    if (context) |ctx| {
        _ = c.sqlite3_bind_text(stmt, 3, ctx.ptr, @intCast(ctx.len), SQLITE_TRANSIENT());
        _ = c.sqlite3_bind_text(stmt, 4, ctx.ptr, @intCast(ctx.len), SQLITE_TRANSIENT());
    } else {
        _ = c.sqlite3_bind_null(stmt, 3);
        _ = c.sqlite3_bind_null(stmt, 4);
    }

    var result: std.ArrayList(models.ResolverApproval) = .{};
    errdefer {
        for (result.items) |*approval| {
            approval.deinit(db.allocator);
        }
        result.deinit(db.allocator);
    }

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const chain_col = std.mem.span(c.sqlite3_column_text(stmt, 1));
        const resolver_col = std.mem.span(c.sqlite3_column_text(stmt, 2));
        const namehash_col = std.mem.span(c.sqlite3_column_text(stmt, 3));
        const context_col_ptr = c.sqlite3_column_text(stmt, 4);
        const delegate_col = std.mem.span(c.sqlite3_column_text(stmt, 5));
        const tx_hash_col = std.mem.span(c.sqlite3_column_text(stmt, 8));

        const context_val: ?[]const u8 = if (context_col_ptr != null)
            try db.allocator.dupe(u8, std.mem.span(context_col_ptr))
        else
            null;

        const approval = models.ResolverApproval{
            .id = @intCast(c.sqlite3_column_int64(stmt, 0)),
            .chain = try models.Chain.fromString(chain_col),
            .resolver = try Address.fromHex(resolver_col),
            .namehash = try Hash.fromHex(namehash_col),
            .context = context_val,
            .delegate = try Address.fromHex(delegate_col),
            .approved = c.sqlite3_column_int(stmt, 6) != 0,
            .block_number = @intCast(c.sqlite3_column_int64(stmt, 7)),
            .tx_hash = try Hash.fromHex(tx_hash_col),
            .log_index = @intCast(c.sqlite3_column_int(stmt, 9)),
            .timestamp = c.sqlite3_column_int64(stmt, 10),
        };

        try result.append(db.allocator, approval);
    }

    return result.toOwnedSlice(db.allocator);
}

/// Get all approvals for a specific delegate
pub fn getApprovalsForDelegate(db: *Database, chain: models.Chain, delegate: Address) ![]models.ResolverApproval {
    const sql =
        \\SELECT id, chain, resolver, namehash, context, delegate, approved, block_number, transaction_hash, log_index, timestamp
        \\FROM resolver_approvals
        \\WHERE chain = ? AND delegate = ? AND approved = 1
        \\ORDER BY timestamp DESC
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
    const delegate_hex = try delegate.toHex(db.allocator);
    defer db.allocator.free(delegate_hex);

    _ = c.sqlite3_bind_text(stmt, 1, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 2, delegate_hex.ptr, @intCast(delegate_hex.len), SQLITE_TRANSIENT());

    var result: std.ArrayList(models.ResolverApproval) = .{};
    errdefer {
        for (result.items) |*approval| {
            approval.deinit(db.allocator);
        }
        result.deinit(db.allocator);
    }

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const chain_col = std.mem.span(c.sqlite3_column_text(stmt, 1));
        const resolver_col = std.mem.span(c.sqlite3_column_text(stmt, 2));
        const namehash_col = std.mem.span(c.sqlite3_column_text(stmt, 3));
        const context_col_ptr = c.sqlite3_column_text(stmt, 4);
        const delegate_col = std.mem.span(c.sqlite3_column_text(stmt, 5));
        const tx_hash_col = std.mem.span(c.sqlite3_column_text(stmt, 8));

        const context_val: ?[]const u8 = if (context_col_ptr != null)
            try db.allocator.dupe(u8, std.mem.span(context_col_ptr))
        else
            null;

        const approval = models.ResolverApproval{
            .id = @intCast(c.sqlite3_column_int64(stmt, 0)),
            .chain = try models.Chain.fromString(chain_col),
            .resolver = try Address.fromHex(resolver_col),
            .namehash = try Hash.fromHex(namehash_col),
            .context = context_val,
            .delegate = try Address.fromHex(delegate_col),
            .approved = c.sqlite3_column_int(stmt, 6) != 0,
            .block_number = @intCast(c.sqlite3_column_int64(stmt, 7)),
            .tx_hash = try Hash.fromHex(tx_hash_col),
            .log_index = @intCast(c.sqlite3_column_int(stmt, 9)),
            .timestamp = c.sqlite3_column_int64(stmt, 10),
        };

        try result.append(db.allocator, approval);
    }

    return result.toOwnedSlice(db.allocator);
}
