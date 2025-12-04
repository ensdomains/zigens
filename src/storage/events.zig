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
// EVENT OPERATIONS (3 functions)
// ============================================================================

pub fn insertEvent(db: *Database, event: models.Event) !void {
    const sql =
        \\INSERT OR IGNORE INTO events
        \\(event_type, chain, block_number, tx_hash, log_index, contract_address,
        \\ name, namehash, data, timestamp)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ;

    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare insert event statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    const event_type_str = event.event_type.toString();
    const chain_str = event.chain.toString();

    const tx_hash_hex = try event.tx_hash.toHex(db.allocator);
    const contract_hex = try event.contract_address.toHex(db.allocator);
    const nh_hex = if (event.namehash) |nh| try nh.toHex(db.allocator) else null;

    // Defer all allocations until AFTER sqlite3_step() completes
    // Even though SQLITE_TRANSIENT() tells SQLite to copy, the copy happens during step()
    defer {
        db.allocator.free(tx_hash_hex);
        db.allocator.free(contract_hex);
        if (nh_hex) |h| db.allocator.free(h);
    }

    _ = c.sqlite3_bind_text(stmt, 1, event_type_str.ptr, @intCast(event_type_str.len), c.SQLITE_STATIC);
    _ = c.sqlite3_bind_text(stmt, 2, chain_str.ptr, @intCast(chain_str.len), c.SQLITE_STATIC);
    _ = c.sqlite3_bind_int64(stmt, 3, @intCast(event.block_number));
    _ = c.sqlite3_bind_text(stmt, 4, tx_hash_hex.ptr, @intCast(tx_hash_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int(stmt, 5, @intCast(event.log_index));
    _ = c.sqlite3_bind_text(stmt, 6, contract_hex.ptr, @intCast(contract_hex.len), SQLITE_TRANSIENT());

    if (event.name) |name| {
        _ = c.sqlite3_bind_text(stmt, 7, name.ptr, @intCast(name.len), SQLITE_TRANSIENT());
    } else {
        _ = c.sqlite3_bind_null(stmt, 7);
    }

    if (nh_hex) |h| {
        _ = c.sqlite3_bind_text(stmt, 8, h.ptr, @intCast(h.len), SQLITE_TRANSIENT());
    } else {
        _ = c.sqlite3_bind_null(stmt, 8);
    }

    _ = c.sqlite3_bind_text(stmt, 9, event.data.ptr, @intCast(event.data.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 10, event.timestamp);

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to insert event: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.InsertFailed;
    }
}

pub fn getRecentEvents(db: *Database, chain: ?models.Chain, event_type: ?models.EventType, limit: u32) ![]models.Event {
    var sql_buf: [512]u8 = undefined;
    var sql_len: usize = 0;

    const base_sql = "SELECT event_type, chain, block_number, tx_hash, log_index, contract_address, name, namehash, data, timestamp FROM events";
    @memcpy(sql_buf[sql_len..][0..base_sql.len], base_sql);
    sql_len += base_sql.len;

    var param_count: u8 = 0;
    if (chain != null or event_type != null) {
        const where_sql = " WHERE ";
        @memcpy(sql_buf[sql_len..][0..where_sql.len], where_sql);
        sql_len += where_sql.len;

        if (chain != null) {
            const chain_filter = "chain = ?";
            @memcpy(sql_buf[sql_len..][0..chain_filter.len], chain_filter);
            sql_len += chain_filter.len;
            param_count += 1;

            if (event_type != null) {
                const and_sql = " AND ";
                @memcpy(sql_buf[sql_len..][0..and_sql.len], and_sql);
                sql_len += and_sql.len;
            }
        }

        if (event_type != null) {
            const type_filter = "event_type = ?";
            @memcpy(sql_buf[sql_len..][0..type_filter.len], type_filter);
            sql_len += type_filter.len;
            param_count += 1;
        }
    }

    const order_sql = " ORDER BY block_number DESC, log_index DESC LIMIT ";
    @memcpy(sql_buf[sql_len..][0..order_sql.len], order_sql);
    sql_len += order_sql.len;

    const limit_str = try std.fmt.bufPrint(sql_buf[sql_len..], "{d}", .{limit});
    sql_len += limit_str.len;

    const sql = sql_buf[0..sql_len];
    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare get events statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    // Bind parameters
    var param_idx: c_int = 1;
    if (chain) |ch| {
        const chain_str = ch.toString();
        _ = c.sqlite3_bind_text(stmt, param_idx, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());
        param_idx += 1;
    }
    if (event_type) |et| {
        const type_str = et.toString();
        _ = c.sqlite3_bind_text(stmt, param_idx, type_str.ptr, @intCast(type_str.len), SQLITE_TRANSIENT());
    }

    var events: std.ArrayList(models.Event) = .{};
    errdefer {
        for (events.items) |*event| {
            event.deinit(db.allocator);
        }
        events.deinit(db.allocator);
    }

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const event_type_str = std.mem.span(c.sqlite3_column_text(stmt, 0));
        const chain_str = std.mem.span(c.sqlite3_column_text(stmt, 1));
        const tx_hash_str = std.mem.span(c.sqlite3_column_text(stmt, 3));
        const contract_addr_str = std.mem.span(c.sqlite3_column_text(stmt, 5));
        const data_str = std.mem.span(c.sqlite3_column_text(stmt, 8));

        const name_col = c.sqlite3_column_text(stmt, 6);
        const name_val = if (name_col != null) try db.allocator.dupe(u8, std.mem.span(name_col)) else null;

        const namehash_col = c.sqlite3_column_text(stmt, 7);
        const namehash_val = if (namehash_col != null) blk: {
            const hash_str = std.mem.span(namehash_col);
            // Check if it's valid hex (should start with 0x and be 66 chars)
            if (hash_str.len == 66 and hash_str[0] == '0' and hash_str[1] == 'x') {
                break :blk Hash.fromHex(hash_str) catch null;
            } else {
                break :blk null;
            }
        } else null;

        const event = models.Event{
            .event_type = std.meta.stringToEnum(models.EventType, event_type_str) orelse .transfer,
            .chain = try models.Chain.fromString(chain_str),
            .block_number = @intCast(c.sqlite3_column_int64(stmt, 2)),
            .tx_hash = try Hash.fromHex(tx_hash_str),
            .log_index = @intCast(c.sqlite3_column_int(stmt, 4)),
            .contract_address = try Address.fromHex(contract_addr_str),
            .name = name_val,
            .namehash = namehash_val,
            .data = try db.allocator.dupe(u8, data_str),
            .timestamp = c.sqlite3_column_int64(stmt, 9),
        };

        try events.append(db.allocator, event);
    }

    return events.toOwnedSlice(db.allocator);
}

/// Insert or update an approval
pub fn insertApproval(db: *Database, chain: models.Chain, token_id: u256, owner: Address, approved: Address, block_number: u64, tx_hash: Hash) !void {
    const sql =
        \\INSERT OR REPLACE INTO approvals
        \\(chain, token_id, owner, approved, block_number, tx_hash, timestamp)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
    ;

    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare insert approval statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    const chain_str = chain.toString();
    const token_id_str = try std.fmt.allocPrint(db.allocator, "{d}", .{token_id});
    defer db.allocator.free(token_id_str);
    const owner_hex = try owner.toHex(db.allocator);
    defer db.allocator.free(owner_hex);
    const approved_hex = try approved.toHex(db.allocator);
    defer db.allocator.free(approved_hex);
    const tx_hash_hex = try tx_hash.toHex(db.allocator);
    defer db.allocator.free(tx_hash_hex);
    const timestamp = std.time.timestamp();

    _ = c.sqlite3_bind_text(stmt, 1, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 2, token_id_str.ptr, @intCast(token_id_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 3, owner_hex.ptr, @intCast(owner_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 4, approved_hex.ptr, @intCast(approved_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 5, @intCast(block_number));
    _ = c.sqlite3_bind_text(stmt, 6, tx_hash_hex.ptr, @intCast(tx_hash_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 7, timestamp);

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to insert approval: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.InsertFailed;
    }
}
