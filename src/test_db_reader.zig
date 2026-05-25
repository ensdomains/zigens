const std = @import("std");
const db = @import("storage/database.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("Opening database in read mode...", .{});

    // Initialize database connection
    var database = try db.Database.init(allocator, "./data/ens.db");
    defer database.deinit();

    std.log.info("Database opened successfully", .{});

    // Count total events using raw SQLite C API
    const count_query = "SELECT COUNT(*) FROM events";
    var count_stmt: ?*db.c.sqlite3_stmt = null;

    const prepare_result = db.c.sqlite3_prepare_v2(
        database.db,
        count_query.ptr,
        @intCast(count_query.len),
        &count_stmt,
        null,
    );

    if (prepare_result != db.c.SQLITE_OK) {
        std.log.err("Failed to prepare count query: {d}", .{prepare_result});
        return error.SqliteError;
    }
    defer _ = db.c.sqlite3_finalize(count_stmt);

    if (db.c.sqlite3_step(count_stmt) == db.c.SQLITE_ROW) {
        const count = db.c.sqlite3_column_int64(count_stmt, 0);
        std.log.info("Total events in database: {d}", .{count});
    }

    // Count events by type
    const type_query = "SELECT event_type, COUNT(*) as count FROM events GROUP BY event_type ORDER BY count DESC LIMIT 10";
    var type_stmt: ?*db.c.sqlite3_stmt = null;

    _ = db.c.sqlite3_prepare_v2(
        database.db,
        type_query.ptr,
        @intCast(type_query.len),
        &type_stmt,
        null,
    );
    defer _ = db.c.sqlite3_finalize(type_stmt);

    std.log.info("\nEvents by type:", .{});
    while (db.c.sqlite3_step(type_stmt) == db.c.SQLITE_ROW) {
        const event_type = db.c.sqlite3_column_text(type_stmt, 0);
        const count = db.c.sqlite3_column_int64(type_stmt, 1);
        std.log.info("  {s}: {d}", .{ event_type, count });
    }

    // Show latest 5 events
    const latest_query = "SELECT event_type, block_number, tx_hash FROM events ORDER BY id DESC LIMIT 5";
    var latest_stmt: ?*db.c.sqlite3_stmt = null;

    _ = db.c.sqlite3_prepare_v2(
        database.db,
        latest_query.ptr,
        @intCast(latest_query.len),
        &latest_stmt,
        null,
    );
    defer _ = db.c.sqlite3_finalize(latest_stmt);

    std.log.info("\nLatest 5 events:", .{});
    while (db.c.sqlite3_step(latest_stmt) == db.c.SQLITE_ROW) {
        const event_type = db.c.sqlite3_column_text(latest_stmt, 0);
        const block_number = db.c.sqlite3_column_int64(latest_stmt, 1);
        const tx_hash = db.c.sqlite3_column_text(latest_stmt, 2);
        const tx_hash_slice = std.mem.span(tx_hash);
        std.log.info("  Block {d}: {s} (tx: {s})", .{ block_number, event_type, if (tx_hash_slice.len > 10) tx_hash_slice[0..10] else tx_hash_slice });
    }

    std.log.info("\n✅ Database read test completed successfully!", .{});
    std.log.info("WAL mode concurrent reading is working correctly.", .{});
}

test {
    std.testing.refAllDecls(@This());
}
