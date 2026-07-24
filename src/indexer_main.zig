const std = @import("std");
const config = @import("config.zig");
const indexer = @import("indexer/indexer.zig");
const db = @import("storage/database.zig");
const db_open = @import("storage/db_open.zig");
const models = @import("types/models.zig");
const shutdown = @import("utils/shutdown.zig");

// Configure logging: filter debug logs, use file redirection in production
// Run with: ./ensv2-indexer > logs/indexer.log 2>&1 &
pub const std_options: std.Options = .{
    .log_level = .info, // Only show info, warn, err (no debug)
};

const CliArgs = struct {
    from_block: ?u64 = null,
    to_block: ?u64 = null,
    clean: bool = false,
    backfill: bool = false,
    cdp_backfill: bool = false,
    help: bool = false,
};

fn parseArgs(process_args: std.process.Args) !CliArgs {
    var args = process_args.iterate();

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
        } else if (std.mem.eql(u8, arg, "--backfill")) {
            result.backfill = true;
        } else if (std.mem.eql(u8, arg, "--cdp-backfill")) {
            result.cdp_backfill = true;
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
        \\  --backfill          Rebuild the names table from stored events (V1 then V2), no RPC, then exit
        \\  --cdp-backfill      Bulk-ingest Base history from the CDP SQL API (BASE_CDP_CLIENT_KEY/BASE_CDP_SECRET_KEY), then exit
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

pub fn main(init: std.process.Init) !void {
    // Configure SQLite for thread safety BEFORE any other operations
    db.configureSqliteThreadSafety();

    // Use thread-safe GPA configuration
    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = init.io;

    // Parse command line arguments
    const args = try parseArgs(init.minimal.args);

    if (args.help) {
        printHelp();
        return;
    }

    // Load configuration from .env
    var cfg = try config.Config.fromEnv(allocator);
    defer cfg.deinit();

    std.log.info("ENSv2 Indexer starting...", .{});
    std.log.info("Network: {s}", .{cfg.network.toString()});
    std.log.info("RPC: [CONFIGURED]", .{});
    std.log.info("Start block: {d}", .{cfg.start_block});
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

    // Check database integrity on startup
    const integrity_ok = try database.checkIntegrity();
    if (!integrity_ok) {
        std.log.err("Database integrity check failed! Database may be corrupted.", .{});
        std.log.err("Please restore from backup or delete database to start fresh.", .{});
        return error.DatabaseCorrupted;
    }
    std.log.info("Database integrity check passed", .{});

    // --backfill: offline rebuild of the names projection from stored events. Disable the status
    // server and webhooks (no RPC, no lock contention); live-index setup below is skipped.
    if (args.backfill) {
        cfg.status_port = null;
        cfg.webhooks_enabled = false;
    }

    // Handle re-indexing if --from-block is specified (not applicable in --backfill mode)
    if (!args.backfill) {
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
    }

    // Initialize and start indexer
    var idx = try indexer.Indexer.init(allocator, io, cfg, &database, args.to_block);
    defer idx.deinit();

    // --backfill: rebuild names from stored events (V1 first so V1→V2 migration lookups find
    // their source rows, then V2), then exit without entering the live index loop.
    if (args.backfill) {
        std.log.info("Running in --backfill mode: rebuilding names + records + roles + registrations from stored events (V1 then V2)", .{});
        try idx.clearReplayStatus();
        try idx.replayEventsToRebuildNames();
        try idx.replayV2NamesCore();
        try idx.replayV2RecordsCore();
        try idx.replayV2EacRolesCore();
        try idx.replayV2RegistrationsCore();
        try idx.replayV2RegistriesCore(); // after names (pointer cascade fixes subregistry reachability)
        try idx.replayAccountsCore(); // after names + registrations (backfill seed reads them)
        try idx.writeReplayStatus();
        std.log.info("Backfill complete. Exiting.", .{});
        return;
    }

    if (args.cdp_backfill) {
        std.log.info("Running in --cdp-backfill mode: ingesting history from the CDP SQL API", .{});
        try @import("indexer/cdp_intake.zig").runCdpBackfill(&idx, args.from_block, args.to_block);
        std.log.info("CDP backfill complete. Exiting.", .{});
        return;
    }

    std.log.info("Indexer started - indexing blocks...", .{});

    // Run indexer in main thread (no spawning needed). SIGTERM/SIGINT flips the
    // shutdown flag; the sync loops exit at the next batch boundary and the
    // deferred idx.deinit/database.deinit chain runs in order.
    shutdown.install();
    try idx.start();
    std.log.info("Shutdown complete.", .{});
}

test {
    std.testing.refAllDecls(@This());
    // refAllDecls is shallow — explicitly pull in the EAC roleBitmap decoder's
    // inline tests so `zig build test` exercises the role-table/decode logic.
    _ = @import("api/eac_roles.zig");
}
