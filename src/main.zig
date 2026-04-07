const std = @import("std");
const config = @import("config.zig");
const indexer = @import("indexer/indexer.zig");
const api = @import("api/server.zig");
const db = @import("storage/database.zig");

// Configure logging: filter debug logs, use file redirection in production
pub const std_options: std.Options = .{
    .log_level = .info, // Only show info, warn, err (no debug)
};

pub fn main() !void {
    // Use thread-safe GPA configuration
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load configuration from .env
    var cfg = try config.Config.fromEnv(allocator);
    defer cfg.deinit();

    std.log.info("ENSv2 Indexer starting...", .{});
    std.log.info("Network: {s}", .{cfg.network.toString()});
    // Don't log RPC URLs as they may contain API keys
    std.log.info("L1 RPC: [CONFIGURED]", .{});
    std.log.info("L2 RPC: [CONFIGURED]", .{});
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

    // Initialize indexer
    var idx = try indexer.Indexer.init(allocator, cfg, &database, null);
    defer idx.deinit();

    // Start indexer in a separate thread
    const indexer_thread = try std.Thread.spawn(.{}, indexer.Indexer.start, .{&idx});

    // Start API server if enabled
    if (cfg.api_enabled) {
        const webhook_path: ?[]const u8 = if (cfg.webhooks_enabled) cfg.webhook_db_path else null;
        var server = try api.Server.init(allocator, &database, webhook_path, cfg.api_port, cfg.graphql_max_depth, cfg.graphql_max_cost, cfg.metrics_enabled, cfg.rate_limit_per_second, cfg.webhook_admin_username, cfg.webhook_admin_password);
        defer server.deinit();

        std.log.info("API server starting on port {d}", .{cfg.api_port});
        try server.start();
    } else {
        std.log.info("API server disabled", .{});
        // Just wait for indexer if no API
        indexer_thread.join();
    }
}

test {
    std.testing.refAllDecls(@This());
}
