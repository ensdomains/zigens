const std = @import("std");
const db_module = @import("database.zig");
const Database = db_module.Database;
const c = db_module.c;
const Address = @import("../types/address.zig").Address;

// SQLITE_TRANSIENT - For Zig 0.15.1, we can't use the C constant due to alignment issues
// Instead, we use null which tells SQLite to make a copy of the string
inline fn SQLITE_TRANSIENT() c.sqlite3_destructor_type {
    return null;
}

/// Add a controller to the v1_controllers table
pub fn addController(
    database: *Database,
    controller_address: Address,
    block_number: u64,
    tx_hash: []const u8,
) !void {
    const controller_hex = try controller_address.toHex(database.allocator);
    defer database.allocator.free(controller_hex);

    const sql =
        \\INSERT INTO v1_controllers (controller_address, added_block_number, is_active, added_tx_hash)
        \\VALUES (?, ?, 1, ?)
        \\ON CONFLICT(controller_address) DO UPDATE SET
        \\  is_active = 1,
        \\  removed_block_number = NULL,
        \\  removed_tx_hash = NULL
    ;

    const sql_z = try database.allocator.dupeZ(u8, sql);
    defer database.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(database.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(database.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_text(stmt, 1, controller_hex.ptr, @intCast(controller_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 2, @intCast(block_number));
    _ = c.sqlite3_bind_text(stmt, 3, tx_hash.ptr, @intCast(tx_hash.len), SQLITE_TRANSIENT());

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to add controller: {s}", .{c.sqlite3_errmsg(database.db)});
        return error.InsertFailed;
    }
}

/// Remove a controller from the v1_controllers table (mark as inactive)
pub fn removeController(
    database: *Database,
    controller_address: Address,
    block_number: u64,
    tx_hash: []const u8,
) !void {
    const controller_hex = try controller_address.toHex(database.allocator);
    defer database.allocator.free(controller_hex);

    const sql =
        \\UPDATE v1_controllers
        \\SET is_active = 0,
        \\    removed_block_number = ?,
        \\    removed_tx_hash = ?
        \\WHERE controller_address = ?
    ;

    const sql_z = try database.allocator.dupeZ(u8, sql);
    defer database.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(database.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(database.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int64(stmt, 1, @intCast(block_number));
    _ = c.sqlite3_bind_text(stmt, 2, tx_hash.ptr, @intCast(tx_hash.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 3, controller_hex.ptr, @intCast(controller_hex.len), SQLITE_TRANSIENT());

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to remove controller: {s}", .{c.sqlite3_errmsg(database.db)});
        return error.UpdateFailed;
    }
}

/// Get all active controller addresses
pub fn getActiveControllers(
    allocator: std.mem.Allocator,
    database: *Database,
) ![]Address {
    const sql =
        \\SELECT controller_address FROM v1_controllers
        \\WHERE is_active = 1
        \\ORDER BY added_block_number ASC
    ;

    const sql_z = try database.allocator.dupeZ(u8, sql);
    defer database.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(database.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(database.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    var controllers: std.ArrayList(Address) = .{};
    errdefer controllers.deinit(allocator);

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const addr_hex = std.mem.span(c.sqlite3_column_text(stmt, 0));
        const addr = try Address.fromHex(addr_hex);
        try controllers.append(allocator, addr);
    }

    return controllers.toOwnedSlice(allocator);
}
