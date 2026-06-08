const std = @import("std");
const config = @import("config.zig");
const indexer = @import("indexer/indexer.zig");
const db = @import("storage/database.zig");

// Configure logging: filter debug logs, use file redirection in production
// Run with: ./ensv2-indexer-v1 > logs/indexer.log 2>&1 &
pub const std_options: std.Options = .{
    .log_level = .info, // Only show info, warn, err (no debug)
};

const CliMode = enum { index, backfill };

fn printHelp() void {
    std.debug.print(
        \\ENSv2 V1 Indexer
        \\
        \\Usage: ensv2-indexer-v1 [OPTIONS]
        \\
        \\Options:
        \\  --from-block <BLOCK>    Start indexing from this block number
        \\  --to-block <BLOCK>      Stop indexing at this block number (default: continuous)
        \\  --backfill              Rebuild names table from stored events (no RPC needed)
        \\  --help                  Show this help message
        \\
        \\Configuration is loaded from .env file. Command-line flags override .env values.
        \\
    , .{});
}

fn parseArgs(allocator: std.mem.Allocator, cfg: *config.Config) !CliMode {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    var mode: CliMode = .index;

    // Skip program name
    _ = args.skip();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--backfill")) {
            mode = .backfill;
        } else if (std.mem.eql(u8, arg, "--from-block")) {
            if (args.next()) |block_str| {
                cfg.start_block = try std.fmt.parseInt(u64, block_str, 10);
            } else {
                std.log.err("--from-block requires a block number", .{});
                return error.InvalidArgument;
            }
        } else if (std.mem.eql(u8, arg, "--to-block")) {
            if (args.next()) |block_str| {
                cfg.end_block = try std.fmt.parseInt(u64, block_str, 10);
            } else {
                std.log.err("--to-block requires a block number", .{});
                return error.InvalidArgument;
            }
        } else {
            std.log.warn("Unknown argument: {s}", .{arg});
        }
    }

    return mode;
}

pub fn main() !void {
    // Configure SQLite for thread safety BEFORE any other operations
    db.configureSqliteThreadSafety();

    // Use thread-safe GPA configuration
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load configuration from .env
    var cfg = try config.Config.fromEnv(allocator);
    defer cfg.deinit();

    // Parse command-line arguments (override .env values)
    const mode = try parseArgs(allocator, &cfg);

    std.log.info("ENSv2 V1 Indexer starting...", .{});
    std.log.info("Network: {s}", .{cfg.network.toString()});
    std.log.info("Database: {s}", .{cfg.database_path});

    // Initialize database
    var database = try db.Database.init(allocator, cfg.database_path);
    defer database.deinit();
    database.setChainId(cfg.network.chainId());

    std.log.info("Database initialized at: {s}", .{cfg.database_path});

    // In backfill mode, disable status server and webhooks to avoid DB lock contention
    if (mode == .backfill) {
        cfg.status_port = null;
        cfg.webhooks_enabled = false;
    }

    // Initialize indexer with only V1 client
    var idx = try indexer.Indexer.initSingleProtocol(allocator, cfg, &database, .v1, cfg.end_block);
    defer idx.deinit();

    switch (mode) {
        .backfill => {
            std.log.info("Running in --backfill mode: rebuilding names from stored events", .{});
            try idx.replayEventsToRebuildNames();
            std.log.info("Backfill complete. Exiting.", .{});
        },
        .index => {
            std.log.info("V1 RPC: [CONFIGURED]", .{});
            std.log.info("Start block: {d}", .{cfg.start_block});
            if (cfg.end_block) |end| {
                std.log.info("End block: {d}", .{end});
            } else {
                std.log.info("End block: continuous (will index indefinitely)", .{});
            }
            std.log.info("Batch size: {d}", .{cfg.batch_size});
            std.log.info("Rate limit: {d} req/s", .{cfg.rate_limit_per_second});

            std.log.info("V1 Indexer started - indexing blocks...", .{});
            try idx.startSingleProtocol(.v1);
        },
    }
}

test {
    std.testing.refAllDecls(@This());
}
