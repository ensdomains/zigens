const std = @import("std");
const db = @import("storage/database.zig");
const Rainbow = @import("rainbow/rainbow.zig").Rainbow;
const Hash = @import("types/hash.zig").Hash;
const v1_names = @import("utils/v1_names.zig");
const unknown_labels_storage = @import("storage/unknown_labels.zig");
const process_allocator = @import("utils/process_allocator.zig");

pub fn main(init: std.process.Init) !void {
    // Bulk pass over millions of rainbow-table labels: the same burst-plus-
    // survivors shape that makes `DebugAllocator` retain unboundedly.
    const allocator = process_allocator.init();
    defer if (process_allocator.deinit()) std.log.warn("allocator reported leaks at shutdown", .{});

    std.log.info("=== Rainbow Table Backfill Tool ===", .{});

    var db_path: []const u8 = "./data/ens.db";
    var rainbow_path: []const u8 = "./data/ens_rainbow.db";
    var batch_size: u32 = 100;
    var dry_run = false;

    var args = init.minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--db")) {
            if (args.next()) |value| db_path = value;
        } else if (std.mem.eql(u8, arg, "--rainbow")) {
            if (args.next()) |value| rainbow_path = value;
        } else if (std.mem.eql(u8, arg, "--batch-size")) {
            if (args.next()) |value| batch_size = std.fmt.parseInt(u32, value, 10) catch 100;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
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
    const total_unknown = try unknown_labels_storage.getUnknownLabelCount(&database);
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
        const unknown_labels = try unknown_labels_storage.getUnknownLabelsForBackfill(allocator, &database, batch_size);
        defer {
            for (unknown_labels) |label| unknown_labels_storage.freeUnknownLabel(allocator, label);
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
                    unknown_labels_storage.deleteUnknownLabel(&database, label.id) catch |err| {
                        std.log.err("Failed to delete unknown label: {}", .{err});
                    };
                }

                total_resolved += 1;
            } else {
                std.log.debug("❌ NOT FOUND: labelhash={s}", .{label.labelhash});

                if (!dry_run) {
                    // Increment backfill attempt
                    unknown_labels_storage.incrementBackfillAttempt(&database, label.id) catch {};
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
