const std = @import("std");
const config = @import("config.zig");
const indexer = @import("indexer/indexer.zig");
const db = @import("storage/database.zig");

// Configure logging: filter debug logs, use file redirection in production
// Run with: ./ensv2-indexer-v2 > logs/indexer-v2.log 2>&1 &
pub const std_options: std.Options = .{
    .log_level = .info, // Only show info, warn, err (no debug)
};

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

    std.log.info("ENSv2 Indexer starting...", .{});
    std.log.info("Network: {s}", .{cfg.network.toString()});
    std.log.info("RPC: [CONFIGURED]", .{});
    std.log.info("V2 Deployment block: {d}", .{cfg.v2_contracts.v2_deployment_block});
    std.log.info("Batch size: {d}", .{cfg.batch_size});
    std.log.info("Rate limit: {d} req/s", .{cfg.rate_limit_per_second});

    // Initialize database
    var database = try db.Database.init(allocator, cfg.database_path);
    defer database.deinit();
    database.setChainId(cfg.network.chainId());

    std.log.info("Database initialized at: {s}", .{cfg.database_path});

    // Check database integrity on startup
    const integrity_ok = try database.checkIntegrity();
    if (!integrity_ok) {
        std.log.err("Database integrity check failed! Database may be corrupted.", .{});
        std.log.err("Please restore from backup or delete database to start fresh.", .{});
        return error.DatabaseCorrupted;
    }
    std.log.info("Database integrity check passed", .{});

    // Initialize indexer with only V2 client
    var idx = try indexer.Indexer.initSingleProtocol(allocator, cfg, &database, .v2, null);
    defer idx.deinit();

    std.log.info("V2 Indexer started - indexing blocks...", .{});

    // Run indexer
    try idx.startSingleProtocol(.v2);
}

test {
    std.testing.refAllDecls(@This());
}
