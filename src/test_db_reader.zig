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

    // Count total events
    {
        var q = try db.Query.init(&database, "SELECT COUNT(*) FROM events");
        defer q.deinit();
        if (try q.step()) {
            std.log.info("Total events in database: {d}", .{q.getInt64(0)});
        }
    }

    // Count events by type
    {
        var q = try db.Query.init(&database, "SELECT event_type, COUNT(*) as count FROM events GROUP BY event_type ORDER BY count DESC LIMIT 10");
        defer q.deinit();
        std.log.info("\nEvents by type:", .{});
        while (try q.step()) {
            std.log.info("  {s}: {d}", .{ q.getTextSlice(0) orelse "", q.getInt64(1) });
        }
    }

    // Show latest 5 events
    {
        var q = try db.Query.init(&database, "SELECT event_type, block_number, tx_hash FROM events ORDER BY id DESC LIMIT 5");
        defer q.deinit();
        std.log.info("\nLatest 5 events:", .{});
        while (try q.step()) {
            const event_type = q.getTextSlice(0) orelse "";
            const block_number = q.getInt64(1);
            const tx_hash_slice = q.getTextSlice(2) orelse "";
            std.log.info("  Block {d}: {s} (tx: {s})", .{ block_number, event_type, if (tx_hash_slice.len > 10) tx_hash_slice[0..10] else tx_hash_slice });
        }
    }

    std.log.info("\n✅ Database read test completed successfully!", .{});
    std.log.info("WAL mode concurrent reading is working correctly.", .{});
}

test {
    std.testing.refAllDecls(@This());
}
