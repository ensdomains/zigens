const std = @import("std");
const config = @import("config.zig");
const indexer = @import("indexer/indexer.zig");
const db = @import("storage/database.zig");
const db_open = @import("storage/db_open.zig");

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

const CliArgs = struct { mode: CliMode, from_block: ?u64 };

fn parseArgs(process_args: std.process.Args, cfg: *config.Config) !CliArgs {
    var args = process_args.iterate();

    var mode: CliMode = .index;
    var from_block: ?u64 = null;

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
                from_block = try std.fmt.parseInt(u64, block_str, 10);
                cfg.start_block = from_block.?;
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

    return .{ .mode = mode, .from_block = from_block };
}

const process_allocator = @import("utils/process_allocator.zig");

pub fn main(init: std.process.Init) !void {
    // Configure SQLite for thread safety BEFORE any other operations
    db.configureSqliteThreadSafety();

    // libc malloc, thread-safe and shared with sqlite3. `DebugAllocator`
    // cannot back a sync of any length: it pins a whole 128 KiB bucket per
    // surviving small allocation, so RSS grows linearly per batch with no
    // leak present while `total_requested_bytes` reports single-digit MB.
    // See utils/process_allocator.zig for the measurements. `ALLOCATOR=debug`
    // opts back into it for a bounded leak-hunting run.
    const allocator = process_allocator.init();
    defer if (process_allocator.deinit()) std.log.warn("allocator reported leaks at shutdown", .{});
    const io = init.io;

    // Load configuration from .env
    var cfg = try config.Config.fromEnv(allocator);
    defer cfg.deinit();

    // Parse command-line arguments (override .env values)
    const cli = try parseArgs(init.minimal.args, &cfg);
    const mode = cli.mode;

    std.log.info("ENSv2 V1 Indexer starting...", .{});
    std.log.info("Network: {s}", .{cfg.network.toString()});
    std.log.info("Database: {s}", .{cfg.database_path});

    // Initialize database (backend selected by config: SQLite path or DATABASE_URL).
    var database = try db_open.openFromConfig(allocator, cfg);
    defer database.deinit();
    database.setChainId(cfg.network.chainId());

    switch (cfg.backend_kind) {
        .sqlite => std.log.info("Database initialized: sqlite {s}", .{cfg.database_path}),
        .postgres => std.log.info("Database initialized: postgres (via DATABASE_URL)", .{}),
    }

    // --from-block resets this protocol's cursor, mirroring the combined binary,
    // so all three binaries interpret the flag identically.
    if (cli.from_block) |fb| {
        std.log.info("Resetting sync state to block {d}...", .{fb});
        try database.setSyncState(.v1, fb);
    }

    // In backfill mode, disable status server and webhooks to avoid DB lock contention
    if (mode == .backfill) {
        cfg.status_port = null;
        cfg.webhooks_enabled = false;
    }

    // Initialize indexer with only V1 client
    var idx = try indexer.Indexer.initSingleProtocol(allocator, io, cfg, &database, .v1, cfg.end_block);
    defer idx.deinit();

    switch (mode) {
        .backfill => {
            std.log.info("Running in --backfill mode: rebuilding names from stored events", .{});
            try idx.clearReplayStatus();
            try idx.replayEventsToRebuildNames();
            try idx.writeReplayStatus();
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
            std.log.info("RPC rate limit: {d} req/s (outbound)", .{cfg.rpc_rate_limit_per_second});

            std.log.info("V1 Indexer started - indexing blocks...", .{});
            try idx.startSingleProtocol(.v1);
        },
    }
}

test {
    std.testing.refAllDecls(@This());
}
