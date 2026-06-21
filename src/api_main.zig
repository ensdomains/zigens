const std = @import("std");
const config = @import("config.zig");
const api = @import("api/server.zig");
const db = @import("storage/database.zig");
const constants = @import("constants.zig");
const ens_normalize = @import("ens_normalize");

pub fn main() !void {
    // Configure SQLite for thread safety BEFORE any other operations
    const sqlite_result = db.c.sqlite3_config(db.c.SQLITE_CONFIG_SERIALIZED);
    if (sqlite_result == db.c.SQLITE_OK) {
        std.log.info("SQLite configured for serialized (thread-safe) mode", .{});
    } else {
        std.log.warn("Failed to configure SQLite thread safety: {d}", .{sqlite_result});
    }

    // Use thread-safe allocator for concurrent request handling
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load configuration from .env
    var cfg = try config.Config.fromEnv(allocator);
    defer cfg.deinit();

    // Parse command line arguments (override env vars)
    var args = std.process.args();
    _ = args.skip(); // Skip program name
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            if (args.next()) |port_str| {
                cfg.api_port = std.fmt.parseInt(u16, port_str, 10) catch {
                    std.log.err("Invalid port: {s}", .{port_str});
                    return error.InvalidPort;
                };
            }
        } else if (std.mem.startsWith(u8, arg, "--port=")) {
            const port_str = arg[7..];
            cfg.api_port = std.fmt.parseInt(u16, port_str, 10) catch {
                std.log.err("Invalid port: {s}", .{port_str});
                return error.InvalidPort;
            };
        }
    }

    std.log.info("ENSv2 API Server starting...", .{});
    std.log.info("Database: {s}", .{cfg.database_path});
    std.log.info("Port: {d}", .{cfg.api_port});
    std.log.info("GraphQL Max Depth: {d}", .{cfg.graphql_max_depth});
    std.log.info("GraphQL Max Cost: {d}", .{cfg.graphql_max_cost});

    // Bootstrap connection: used only for the startup integrity check. The
    // request path uses the connection pool below, not this handle.
    var bootstrap_db = try db.Database.initWithoutSchema(allocator, cfg.database_path);
    bootstrap_db.setChainId(cfg.network.chainId());

    // Check database integrity
    const integrity_ok = try bootstrap_db.checkIntegrity();
    bootstrap_db.deinit();
    if (!integrity_ok) {
        std.log.err("Database integrity check failed!", .{});
        return error.DatabaseCorrupted;
    }

    // Connection pool: each request thread borrows its own read-only connection,
    // so no two threads ever share a sqlite3 handle (which previously caused
    // transient EXECUTION_ERROR under concurrent load). WAL mode lets these
    // connections read in parallel.
    var pool = try db.DatabasePool.init(
        allocator,
        cfg.database_path,
        cfg.network.chainId(),
        cfg.db_pool_size,
        constants.SQLite.db_pool_max,
    );
    defer pool.deinit();

    std.log.info("Database connected (pool size: {d})", .{cfg.db_pool_size});

    // Eagerly initialize ENS normalizer to avoid cold-start latency on first query
    std.log.info("Initializing ENS name normalizer...", .{});
    _ = ens_normalize.shared();
    std.log.info("ENS normalizer initialized", .{});

    // Start API server with complexity limits and metrics from config
    // Only pass webhook_db_path if webhooks are enabled
    const webhook_path: ?[]const u8 = if (cfg.webhooks_enabled) cfg.webhook_db_path else null;
    var server = try api.Server.init(allocator, &pool, webhook_path, cfg.api_port, cfg.graphql_max_depth, cfg.graphql_max_cost, cfg.metrics_enabled, cfg.rate_limit_per_second, cfg.webhook_admin_username, cfg.webhook_admin_password);
    defer server.deinit();

    if (cfg.webhook_admin_username != null and cfg.webhook_admin_password != null) {
        std.log.info("Webhook auth enabled (username: {s})", .{cfg.webhook_admin_username.?});
    } else {
        std.log.info("Webhook auth disabled (set WEBHOOK_ADMIN_USERNAME and WEBHOOK_ADMIN_PASSWORD to enable)", .{});
    }

    std.log.info("Ready to serve requests", .{});

    try server.start();
}

test {
    std.testing.refAllDecls(@This());
}
