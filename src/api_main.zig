const std = @import("std");
const config = @import("config.zig");
const api = @import("api/server.zig");
const db = @import("storage/database.zig");
const pool_mod = @import("storage/pool.zig");
const ens_normalize = @import("ens_normalize");

pub fn main() !void {
    // Configure SQLite for thread safety BEFORE any other operations
    db.configureSqliteThreadSafety();

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
    switch (cfg.backend_kind) {
        .sqlite => std.log.info("Database: sqlite {s}", .{cfg.database_path}),
        .postgres => std.log.info("Database: postgres (via DATABASE_URL)", .{}),
    }
    std.log.info("Port: {d}", .{cfg.api_port});
    std.log.info("GraphQL Max Depth: {d}", .{cfg.graphql_max_depth});
    std.log.info("GraphQL Max Cost: {d}", .{cfg.graphql_max_cost});

    // Read-only session pool (skip schema loading — the indexer owns writes):
    // DATABASE_POOL_SIZE independent sessions acquired per request. Sessions are
    // never shared across threads — SQLite gets N read connections to the file
    // (:memory: pins to 1), and a single pinned pg connection is not
    // concurrent-safe under the API's thread-per-request model.
    var db_pool = try pool_mod.Pool.open(allocator, .{
        .kind = cfg.backend_kind,
        .sqlite_path = cfg.database_path,
        .database_url = cfg.database_url,
        .size = cfg.database_pool_size,
        .chain_id = cfg.network.chainId(),
    });
    defer db_pool.deinit();

    // Check database integrity
    {
        const session = try db_pool.acquire();
        defer db_pool.release(session);
        const integrity_ok = try session.checkIntegrity();
        if (!integrity_ok) {
            std.log.err("Database integrity check failed!", .{});
            return error.DatabaseCorrupted;
        }
    }

    std.log.info("Database connected ({d} session{s})", .{ db_pool.sessions.len, if (db_pool.sessions.len == 1) "" else "s" });

    // Eagerly initialize ENS normalizer to avoid cold-start latency on first query
    std.log.info("Initializing ENS name normalizer...", .{});
    _ = ens_normalize.shared();
    std.log.info("ENS normalizer initialized", .{});

    // Start API server with complexity limits and metrics from config
    // Only pass webhook_db_path if webhooks are enabled
    const webhook_path: ?[]const u8 = if (cfg.webhooks_enabled) cfg.webhook_db_path else null;
    var server = try api.Server.init(allocator, &db_pool, webhook_path, cfg.api_port, cfg.graphql_max_depth, cfg.graphql_max_cost, cfg.metrics_enabled, cfg.rate_limit_per_second, cfg.webhook_admin_username, cfg.webhook_admin_password, cfg.trusted_proxy_hops);
    defer server.deinit();

    // Opt-in on-chain resolution (default off). Covers primary-name verification (05)
    // and/or live Universal Resolver record fallback (06); either flag creates the shared
    // RPC client. Leaving both unset creates no RPC client and changes no served value.
    if (cfg.primary_verify_enabled or cfg.resolve_live_enabled) {
        try server.enableResolution(cfg.resolve_rpc_url, cfg.resolve_cache_ttl_s, cfg.network.chainId(), cfg.v1_contracts.ens_registry, cfg.resolve_universal_resolver, cfg.resolve_live_enabled, cfg.primary_verify_enabled, cfg.resolve_ccip_enabled, cfg.ccip_max_redirects, cfg.ccip_gateway_timeout_ms);
        std.log.info("On-chain resolution enabled (primary_verify={}, live={}, rpc={s})", .{ cfg.primary_verify_enabled, cfg.resolve_live_enabled, cfg.resolve_rpc_url });
    }

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
