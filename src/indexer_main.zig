const std = @import("std");
const config = @import("config.zig");
const indexer = @import("indexer/indexer.zig");
const db = @import("storage/database.zig");
const models = @import("types/models.zig");

// Configure logging: filter debug logs, use file redirection in production
// Run with: ./ensv2-indexer > logs/indexer.log 2>&1 &
pub const std_options: std.Options = .{
    .log_level = .info, // Only show info, warn, err (no debug)
};

const CliArgs = struct {
    from_block: ?u64 = null,
    to_block: ?u64 = null,
    clean: bool = false,
    help: bool = false,
};

fn parseArgs(allocator: std.mem.Allocator) !CliArgs {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program name
    _ = args.skip();

    var result = CliArgs{};

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            result.help = true;
        } else if (std.mem.eql(u8, arg, "--from-block")) {
            if (args.next()) |block_str| {
                result.from_block = try std.fmt.parseInt(u64, block_str, 10);
            } else {
                std.log.err("--from-block requires a block number", .{});
                return error.InvalidArgs;
            }
        } else if (std.mem.eql(u8, arg, "--to-block")) {
            if (args.next()) |block_str| {
                result.to_block = try std.fmt.parseInt(u64, block_str, 10);
            } else {
                std.log.err("--to-block requires a block number", .{});
                return error.InvalidArgs;
            }
        } else if (std.mem.eql(u8, arg, "--clean")) {
            result.clean = true;
        } else {
            std.log.warn("Unknown argument: {s}", .{arg});
        }
    }

    return result;
}

fn printHelp() void {
    std.log.info(
        \\
        \\ENSv2 Indexer
        \\
        \\Usage: ensv2-indexer [OPTIONS]
        \\
        \\Options:
        \\  --from-block <N>    Re-index from block N (resets sync state)
        \\  --to-block <N>      Stop indexing at block N (default: current block)
        \\  --clean             Delete all data after --from-block before re-indexing
        \\  --help, -h          Show this help message
        \\
        \\Examples:
        \\  ensv2-indexer                          # Start indexing from last synced block
        \\  ensv2-indexer --from-block 1000000     # Re-index from block 1000000 (keeps existing data)
        \\  ensv2-indexer --from-block 1000000 --to-block 1001000  # Index blocks 1000000 to 1001000
        \\  ensv2-indexer --from-block 1000000 --clean  # Delete data after block 1000000 and re-index
        \\
        \\Notes:
        \\  - Re-indexing without --clean is idempotent (safe to run multiple times)
        \\  - Uses INSERT OR IGNORE to handle duplicates automatically
        \\  - --clean mode deletes ALL data after the specified block before re-indexing
        \\  - --to-block limits indexing to a specific block range (useful for testing)
        \\
    , .{});
}

pub fn main() !void {
    // Configure SQLite for thread safety BEFORE any other operations
    const sqlite_result = db.c.sqlite3_config(db.c.SQLITE_CONFIG_SERIALIZED);
    if (sqlite_result == db.c.SQLITE_OK) {
        std.log.info("SQLite configured for serialized (thread-safe) mode", .{});
    } else {
        std.log.warn("Failed to configure SQLite thread safety: {d}", .{sqlite_result});
    }

    // Use thread-safe GPA configuration
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try parseArgs(allocator);

    if (args.help) {
        printHelp();
        return;
    }

    // Load configuration from .env
    var cfg = try config.Config.fromEnv(allocator);
    defer cfg.deinit();

    std.log.info("ENSv2 Indexer starting...", .{});
    std.log.info("V1 Network: {s}", .{cfg.network_v1.toString()});
    std.log.info("V2 Network: {s}", .{cfg.network_v2.toString()});
    std.log.info("V1 RPC: [CONFIGURED]", .{});
    std.log.info("V2 RPC: [CONFIGURED]", .{});
    std.log.info("Start block: {d}", .{cfg.start_block});
    std.log.info("Batch size: {d}", .{cfg.batch_size});
    std.log.info("Rate limit: {d} req/s", .{cfg.rate_limit_per_second});

    // Initialize database
    var database = try db.Database.init(allocator, cfg.database_path);
    defer database.deinit();

    std.log.info("Database initialized at: {s}", .{cfg.database_path});

    // Check database integrity on startup
    const integrity_ok = try database.checkIntegrity();
    if (!integrity_ok) {
        std.log.err("Database integrity check failed! Database may be corrupted.", .{});
        std.log.err("Please restore from backup or delete database to start fresh.", .{});
        return error.DatabaseCorrupted;
    }
    std.log.info("Database integrity check passed", .{});

    // Handle re-indexing if --from-block is specified
    if (args.from_block) |from_block| {
        std.log.info("Re-indexing requested from block {d}", .{from_block});

        if (args.clean) {
            std.log.warn("--clean mode: Deleting all data after block {d}...", .{from_block});
            try database.deleteDataAfterBlock(from_block);
            std.log.info("Data cleanup complete", .{});
        } else {
            std.log.info("Idempotent re-index: Keeping existing data, will skip duplicates", .{});
        }

        // Reset sync state for both chains
        std.log.info("Resetting sync state to block {d}...", .{from_block});
        try database.setSyncState(.v1, from_block);
        try database.setSyncState(.v2, from_block);
        std.log.info("Sync state reset complete. Indexer will resume from block {d}", .{from_block});
    }

    // Initialize and start indexer
    var idx = try indexer.Indexer.init(allocator, cfg, &database, args.to_block);
    defer idx.deinit();

    std.log.info("Indexer started - indexing blocks...", .{});

    // Run indexer in main thread (no spawning needed)
    try idx.start();
}

test {
    std.testing.refAllDecls(@This());
}
