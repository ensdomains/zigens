const std = @import("std");
const db_module = @import("database.zig");
const Database = db_module.Database;
const Query = db_module.Query;
const Address = @import("../types/address.zig").Address;

/// Add a controller to the v1_controllers table
pub fn addController(
    database: *Database,
    controller_address: Address,
    block_number: u64,
    tx_hash: []const u8,
) !void {
    const sql =
        \\INSERT INTO v1_controllers (controller_address, added_block_number, is_active, added_tx_hash)
        \\VALUES (?, ?, 1, ?)
        \\ON CONFLICT(controller_address) DO UPDATE SET
        \\  is_active = 1,
        \\  removed_block_number = NULL,
        \\  removed_tx_hash = NULL
    ;

    var q = try Query.initCached(database, sql);
    defer q.deinit();

    try q.bindAddressBuf(controller_address);
    try q.bindInt64(@intCast(block_number));
    try q.bindText(tx_hash);

    try q.exec();
}

/// Remove a controller from the v1_controllers table (mark as inactive)
pub fn removeController(
    database: *Database,
    controller_address: Address,
    block_number: u64,
    tx_hash: []const u8,
) !void {
    const sql =
        \\UPDATE v1_controllers
        \\SET is_active = 0,
        \\    removed_block_number = ?,
        \\    removed_tx_hash = ?
        \\WHERE controller_address = ?
    ;

    var q = try Query.initCached(database, sql);
    defer q.deinit();

    try q.bindInt64(@intCast(block_number));
    try q.bindText(tx_hash);
    try q.bindAddressBuf(controller_address);

    try q.exec();
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

    var q = try Query.initCached(database, sql);
    defer q.deinit();

    var controllers: std.ArrayList(Address) = .{};
    errdefer controllers.deinit(allocator);

    while (try q.step()) {
        const addr_hex = q.getTextSlice(0) orelse continue;
        const addr = try Address.fromHex(addr_hex);
        try controllers.append(allocator, addr);
    }

    return controllers.toOwnedSlice(allocator);
}
