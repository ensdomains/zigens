const std = @import("std");
const db = @import("storage/database.zig");
const Rainbow = @import("rainbow/rainbow.zig").Rainbow;
const Hash = @import("types/hash.zig").Hash;
const v1_names = @import("utils/v1_names.zig");

const c = db.c;

const UnknownLabel = struct {
    id: i64,
    labelhash: []const u8,
    namehash: []const u8,
    parent_node: []const u8,
    owner: []const u8,
    transaction_hash: []const u8,
    block_number: i64,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== Rainbow Table Backfill Tool ===", .{});

    // Parse args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var db_path: []const u8 = "./data/ens.db";
    var rainbow_path: []const u8 = "./data/ens_rainbow.db";
    var batch_size: u32 = 100;
    var dry_run = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--db")) {
            i += 1;
            if (i < args.len) db_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--rainbow")) {
            i += 1;
            if (i < args.len) rainbow_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--batch-size")) {
            i += 1;
            if (i < args.len) batch_size = std.fmt.parseInt(u32, args[i], 10) catch 100;
        } else if (std.mem.eql(u8, args[i], "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, args[i], "--help")) {
            printUsage();
            return;
        }
    }

    std.log.info("Database: {s}", .{db_path});
    std.log.info("Rainbow DB: {s}", .{rainbow_path});
    std.log.info("Batch size: {d}", .{batch_size});
    std.log.info("Dry run: {}", .{dry_run});

    // Open main database
    std.log.info("Opening ENS database...", .{});
    var database = try db.Database.init(allocator, db_path);
    defer database.deinit();

    // Count unknown labels
    const total_unknown = try countUnknownLabels(database.db.?);
    std.log.info("Total unknown labels: {d}", .{total_unknown});

    if (total_unknown == 0) {
        std.log.info("No unknown labels to backfill!", .{});
        return;
    }

    // Load rainbow table
    std.log.info("Loading rainbow table...", .{});
    var rainbow = Rainbow.init(allocator, rainbow_path) catch |err| {
        std.log.err("Failed to load rainbow table: {}", .{err});
        return err;
    };
    defer rainbow.deinit();

    const stats = try rainbow.getDbStats();
    std.log.info("✅ Rainbow table loaded: {d} labels available", .{stats.total_labels});

    // Process unknown labels in batches
    var total_resolved: u64 = 0;
    var total_processed: u64 = 0;

    while (true) {
        const unknown_labels = try getUnknownLabelsBatch(allocator, database.db.?, batch_size);
        defer {
            for (unknown_labels) |label| {
                allocator.free(label.labelhash);
                allocator.free(label.namehash);
                allocator.free(label.parent_node);
                allocator.free(label.owner);
                allocator.free(label.transaction_hash);
            }
            allocator.free(unknown_labels);
        }

        if (unknown_labels.len == 0) {
            break;
        }

        std.log.info("\n--- Processing batch of {d} labels ---", .{unknown_labels.len});

        for (unknown_labels) |label| {
            total_processed += 1;

            // Convert labelhash to binary
            const labelhash_binary = Hash.fromHex(label.labelhash) catch |err| {
                std.log.err("Invalid labelhash format: {s} ({})", .{ label.labelhash, err });
                continue;
            };

            // Try rainbow lookup
            if (try rainbow.lookup(labelhash_binary.bytes)) |label_text| {
                defer allocator.free(label_text);

                std.log.info("✅ RESOLVED: labelhash={s} -> label=\"{s}\"", .{ label.labelhash, label_text });

                if (!dry_run) {
                    // Store the resolved label
                    const namehash = Hash.fromHex(label.namehash) catch continue;

                    v1_names.storeTokenIdLabel(
                        allocator,
                        &database,
                        label.labelhash,
                        label_text,
                        namehash,
                        @intCast(label.block_number),
                        label.transaction_hash,
                        "rainbow_backfill_tool",
                    ) catch |err| {
                        std.log.err("Failed to store label: {}", .{err});
                        continue;
                    };

                    // Delete from unknown_labels
                    deleteUnknownLabel(database.db.?, label.id) catch |err| {
                        std.log.err("Failed to delete unknown label: {}", .{err});
                    };
                }

                total_resolved += 1;
            } else {
                std.log.debug("❌ NOT FOUND: labelhash={s}", .{label.labelhash});

                if (!dry_run) {
                    // Increment backfill attempt
                    incrementBackfillAttempt(database.db.?, label.id) catch {};
                }
            }
        }

        std.log.info("Progress: {d}/{d} resolved, {d} processed", .{ total_resolved, total_unknown, total_processed });
    }

    std.log.info("\n=== Backfill Complete ===", .{});
    std.log.info("Total processed: {d}", .{total_processed});
    std.log.info("Total resolved: {d}", .{total_resolved});
    std.log.info("Resolution rate: {d:.1}%", .{@as(f64, @floatFromInt(total_resolved)) / @as(f64, @floatFromInt(total_processed)) * 100.0});

    // Show rainbow stats
    std.log.info("Rainbow lookups: {d}, hits: {d}, hit rate: {d:.1}%", .{
        rainbow.stats.lookups,
        rainbow.stats.hits,
        if (rainbow.stats.lookups > 0) @as(f64, @floatFromInt(rainbow.stats.hits)) / @as(f64, @floatFromInt(rainbow.stats.lookups)) * 100.0 else 0.0,
    });
}

fn printUsage() void {
    std.debug.print(
        \\Rainbow Table Backfill Tool
        \\
        \\Usage: rainbow-backfill [options]
        \\
        \\Options:
        \\  --db <path>         Path to ENS database (default: ./data/ens.db)
        \\  --rainbow <path>    Path to rainbow table (default: ./data/ens_rainbow.db)
        \\  --batch-size <n>    Number of labels per batch (default: 100)
        \\  --dry-run           Don't modify database, just show what would be resolved
        \\  --help              Show this help
        \\
    , .{});
}

fn countUnknownLabels(db_conn: *c.sqlite3) !u64 {
    const query = "SELECT COUNT(*) FROM unknown_labels WHERE backfill_attempts < 3";
    var stmt: ?*c.sqlite3_stmt = null;

    if (c.sqlite3_prepare_v2(db_conn, query.ptr, @intCast(query.len), &stmt, null) != c.SQLITE_OK) {
        return error.SqliteError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        return @intCast(c.sqlite3_column_int64(stmt, 0));
    }
    return 0;
}

fn getUnknownLabelsBatch(allocator: std.mem.Allocator, db_conn: *c.sqlite3, limit: u32) ![]UnknownLabel {
    const query =
        \\SELECT id, labelhash, namehash, parent_node, owner, transaction_hash, block_number
        \\FROM unknown_labels
        \\WHERE backfill_attempts < 3
        \\ORDER BY created_at ASC
        \\LIMIT ?
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db_conn, query.ptr, @intCast(query.len), &stmt, null) != c.SQLITE_OK) {
        return error.SqliteError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int(stmt, 1, @intCast(limit));

    var results: std.ArrayList(UnknownLabel) = .{};
    errdefer {
        for (results.items) |item| {
            allocator.free(item.labelhash);
            allocator.free(item.namehash);
            allocator.free(item.parent_node);
            allocator.free(item.owner);
            allocator.free(item.transaction_hash);
        }
        results.deinit(allocator);
    }

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const label = UnknownLabel{
            .id = c.sqlite3_column_int64(stmt, 0),
            .labelhash = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1))),
            .namehash = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 2))),
            .parent_node = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 3))),
            .owner = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 4))),
            .transaction_hash = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 5))),
            .block_number = c.sqlite3_column_int64(stmt, 6),
        };
        try results.append(allocator, label);
    }

    return try results.toOwnedSlice(allocator);
}

fn deleteUnknownLabel(db_conn: *c.sqlite3, id: i64) !void {
    const query = "DELETE FROM unknown_labels WHERE id = ?";
    var stmt: ?*c.sqlite3_stmt = null;

    if (c.sqlite3_prepare_v2(db_conn, query.ptr, @intCast(query.len), &stmt, null) != c.SQLITE_OK) {
        return error.SqliteError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int64(stmt, 1, id);

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        return error.SqliteError;
    }
}

fn incrementBackfillAttempt(db_conn: *c.sqlite3, id: i64) !void {
    const query = "UPDATE unknown_labels SET backfill_attempts = backfill_attempts + 1, last_backfill_attempt = strftime('%s', 'now') WHERE id = ?";
    var stmt: ?*c.sqlite3_stmt = null;

    if (c.sqlite3_prepare_v2(db_conn, query.ptr, @intCast(query.len), &stmt, null) != c.SQLITE_OK) {
        return error.SqliteError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int64(stmt, 1, id);
    _ = c.sqlite3_step(stmt);
}
