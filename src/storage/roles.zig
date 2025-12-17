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
// EAC ROLE OPERATIONS (4 functions)
// ============================================================================

/// Insert or update EAC role assignment
pub fn upsertEACRole(db: *Database, chain: models.Chain, resource: []const u8, account: Address, role_bitmap: []const u8, block_number: u64, tx_hash: Hash, log_index: u32) !void {
    const sql =
        \\INSERT INTO eac_roles
        \\(chain, resource, account, role_bitmap, block_number, transaction_hash, log_index, timestamp)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(chain, resource, account) DO UPDATE SET
        \\  role_bitmap = excluded.role_bitmap,
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
    const account_hex = try account.toHex(db.allocator);
    defer db.allocator.free(account_hex);
    const tx_hash_hex = try tx_hash.toHex(db.allocator);
    defer db.allocator.free(tx_hash_hex);

    const now = @as(i64, @intCast(std.time.timestamp()));

    _ = c.sqlite3_bind_text(stmt, 1, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 2, resource.ptr, @intCast(resource.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 3, account_hex.ptr, @intCast(account_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 4, role_bitmap.ptr, @intCast(role_bitmap.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 5, @intCast(block_number));
    _ = c.sqlite3_bind_text(stmt, 6, tx_hash_hex.ptr, @intCast(tx_hash_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int(stmt, 7, @intCast(log_index));
    _ = c.sqlite3_bind_int64(stmt, 8, now);

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to upsert EAC role: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.InsertFailed;
    }
}

/// Get all role assignments for a resource
pub fn getRolesByResource(db: *Database, chain: models.Chain, resource: []const u8) ![]models.EACRoleAssignment {
    const sql =
        \\SELECT r.id, r.chain, r.resource, r.account, r.role_bitmap, r.block_number, r.transaction_hash, r.log_index, r.timestamp, n.name
        \\FROM eac_roles r
        \\LEFT JOIN names n ON r.resource = n.canonical_id
        \\WHERE r.chain = ? AND r.resource = ?
        \\ORDER BY r.timestamp DESC
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
    _ = c.sqlite3_bind_text(stmt, 2, resource.ptr, @intCast(resource.len), SQLITE_TRANSIENT());

    var roles: std.ArrayList(models.EACRoleAssignment) = .{};
    errdefer {
        for (roles.items) |*role| {
            role.deinit(db.allocator);
        }
        roles.deinit(db.allocator);
    }

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const chain_col = std.mem.span(c.sqlite3_column_text(stmt, 1));
        const resource_col = std.mem.span(c.sqlite3_column_text(stmt, 2));
        const account_col = std.mem.span(c.sqlite3_column_text(stmt, 3));
        const role_bitmap_col = std.mem.span(c.sqlite3_column_text(stmt, 4));
        const tx_hash_col = std.mem.span(c.sqlite3_column_text(stmt, 6));

        // Get domain name from JOIN (column 9), may be null
        const name_ptr = c.sqlite3_column_text(stmt, 9);
        const name: ?[]const u8 = if (name_ptr != null)
            try db.allocator.dupe(u8, std.mem.span(name_ptr))
        else
            null;

        const role = models.EACRoleAssignment{
            .id = @intCast(c.sqlite3_column_int64(stmt, 0)),
            .chain = try models.Chain.fromString(chain_col),
            .resource = try db.allocator.dupe(u8, resource_col),
            .account = try Address.fromHex(account_col),
            .role_bitmap = try db.allocator.dupe(u8, role_bitmap_col),
            .block_number = @intCast(c.sqlite3_column_int64(stmt, 5)),
            .tx_hash = try Hash.fromHex(tx_hash_col),
            .log_index = @intCast(c.sqlite3_column_int(stmt, 7)),
            .timestamp = c.sqlite3_column_int64(stmt, 8),
            .name = name,
        };

        try roles.append(db.allocator, role);
    }

    return roles.toOwnedSlice(db.allocator);
}

/// Get all role assignments for an account
pub fn getRolesByAccount(db: *Database, chain: models.Chain, account: Address) ![]models.EACRoleAssignment {
    const sql =
        \\SELECT r.id, r.chain, r.resource, r.account, r.role_bitmap, r.block_number, r.transaction_hash, r.log_index, r.timestamp, n.name
        \\FROM eac_roles r
        \\LEFT JOIN names n ON r.resource = n.canonical_id
        \\WHERE r.chain = ? AND r.account = ?
        \\ORDER BY r.timestamp DESC
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
    const account_hex = try account.toHex(db.allocator);
    defer db.allocator.free(account_hex);

    _ = c.sqlite3_bind_text(stmt, 1, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 2, account_hex.ptr, @intCast(account_hex.len), SQLITE_TRANSIENT());

    var roles: std.ArrayList(models.EACRoleAssignment) = .{};
    errdefer {
        for (roles.items) |*role| {
            role.deinit(db.allocator);
        }
        roles.deinit(db.allocator);
    }

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const chain_col = std.mem.span(c.sqlite3_column_text(stmt, 1));
        const resource_col = std.mem.span(c.sqlite3_column_text(stmt, 2));
        const account_col = std.mem.span(c.sqlite3_column_text(stmt, 3));
        const role_bitmap_col = std.mem.span(c.sqlite3_column_text(stmt, 4));
        const tx_hash_col = std.mem.span(c.sqlite3_column_text(stmt, 6));

        // Get domain name from JOIN (column 9), may be null
        const name_ptr = c.sqlite3_column_text(stmt, 9);
        const name: ?[]const u8 = if (name_ptr != null)
            try db.allocator.dupe(u8, std.mem.span(name_ptr))
        else
            null;

        const role = models.EACRoleAssignment{
            .id = @intCast(c.sqlite3_column_int64(stmt, 0)),
            .chain = try models.Chain.fromString(chain_col),
            .resource = try db.allocator.dupe(u8, resource_col),
            .account = try Address.fromHex(account_col),
            .role_bitmap = try db.allocator.dupe(u8, role_bitmap_col),
            .block_number = @intCast(c.sqlite3_column_int64(stmt, 5)),
            .tx_hash = try Hash.fromHex(tx_hash_col),
            .log_index = @intCast(c.sqlite3_column_int(stmt, 7)),
            .timestamp = c.sqlite3_column_int64(stmt, 8),
            .name = name,
        };

        try roles.append(db.allocator, role);
    }

    return roles.toOwnedSlice(db.allocator);
}

/// Delete role assignment (when all roles revoked)
pub fn deleteEACRole(db: *Database, chain: models.Chain, resource: []const u8, account: Address) !void {
    const sql = "DELETE FROM eac_roles WHERE chain = ? AND resource = ? AND account = ?";

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
    const account_hex = try account.toHex(db.allocator);
    defer db.allocator.free(account_hex);

    _ = c.sqlite3_bind_text(stmt, 1, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 2, resource.ptr, @intCast(resource.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 3, account_hex.ptr, @intCast(account_hex.len), SQLITE_TRANSIENT());

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to delete EAC role: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.DeleteFailed;
    }
}
