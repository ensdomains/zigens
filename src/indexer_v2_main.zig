const std = @import("std");
const config = @import("config.zig");
const indexer = @import("indexer/indexer.zig");
const db = @import("storage/database.zig");
const db_open = @import("storage/db_open.zig");

// Configure logging: filter debug logs, use file redirection in production
// Run with: ./ensv2-indexer-v2 > logs/indexer-v2.log 2>&1 &
pub const std_options: std.Options = .{
    .log_level = .info, // Only show info, warn, err (no debug)
};

const CliMode = enum { index, backfill };

fn printHelp() void {
    std.debug.print(
        \\ENSv2 V2 Indexer
        \\
        \\Usage: ensv2-indexer-v2 [OPTIONS]
        \\
        \\Options:
        \\  --from-block <BLOCK>    Start indexing from this block number
        \\  --to-block <BLOCK>      Stop indexing at this block number (default: continuous)
        \\  --backfill              Rebuild V2 projections from stored events (no RPC needed)
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

const memstat = @import("utils/memstat.zig");

/// File-scope so the per-batch memory line can read `total_requested_bytes`.
var gpa = std.heap.DebugAllocator(.{ .thread_safe = true, .enable_memory_limit = true }){};

fn gpaLiveBytes() usize {
    return @intCast(gpa.total_requested_bytes);
}

pub fn main(init: std.process.Init) !void {
    // Configure SQLite for thread safety BEFORE any other operations
    db.configureSqliteThreadSafety();

    // Use thread-safe GPA configuration
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    memstat.live_bytes_fn = &gpaLiveBytes;
    const io = init.io;

    // Load configuration from .env
    var cfg = try config.Config.fromEnv(allocator);
    defer cfg.deinit();

    // Parse command-line arguments (override .env values)
    const cli = try parseArgs(init.minimal.args, &cfg);
    const mode = cli.mode;

    // In backfill mode, disable status server and webhooks to avoid DB lock contention
    if (mode == .backfill) {
        cfg.status_port = null;
        cfg.webhooks_enabled = false;
    }

    std.log.info("ENSv2 Indexer starting...", .{});
    std.log.info("Network: {s}", .{cfg.network.toString()});
    std.log.info("RPC: [CONFIGURED]", .{});
    std.log.info("V2 Deployment block: {d}", .{cfg.v2_contracts.v2_deployment_block});
    std.log.info("Batch size: {d}", .{cfg.batch_size});
    std.log.info("Rate limit: {d} req/s", .{cfg.rate_limit_per_second});

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
        try database.setSyncState(.v2, fb);
    }

    // Check database integrity on startup
    const integrity_ok = try database.checkIntegrity();
    if (!integrity_ok) {
        std.log.err("Database integrity check failed! Database may be corrupted.", .{});
        std.log.err("Please restore from backup or delete database to start fresh.", .{});
        return error.DatabaseCorrupted;
    }
    std.log.info("Database integrity check passed", .{});

    // Initialize indexer with only V2 client
    var idx = try indexer.Indexer.initSingleProtocol(allocator, io, cfg, &database, .v2, cfg.end_block);
    defer idx.deinit();

    if (mode == .backfill) {
        std.log.info("Running in --backfill mode: rebuilding V2 projections from stored events", .{});
        try idx.clearReplayStatus();
        try idx.replayV2NamesCore();
        try idx.replayV2RecordsCore();
        try idx.replayV2EacRolesCore();
        try idx.replayV2RegistrationsCore();
        try idx.replayV2RegistriesCore();
        try idx.replayAccountsCore();
        try idx.writeReplayStatus();
        std.log.info("Backfill complete. Exiting.", .{});
        return;
    }

    std.log.info("V2 Indexer started - indexing blocks...", .{});

    // Run indexer
    try idx.startSingleProtocol(.v2);
}

test {
    std.testing.refAllDecls(@This());
}
