const std = @import("std");
const env_mod = @import("env.zig");
const contracts = @import("contracts.zig");

pub const Config = struct {
    allocator: std.mem.Allocator,
    rpc_url: []const u8,
    database_path: []const u8,
    network: contracts.Network,
    start_block: u64,
    end_block: ?u64, // null means index continuously
    poll_interval: u64,
    batch_size: u64,
    max_blocks_per_request: u64,
    rate_limit_per_second: u32,
    /// Trusted reverse-proxy hops for rate limiting. 0 (default) = key on the direct TCP
    /// peer. > 0 = trust X-Forwarded-For from this many hops (e.g. 1 for a single LB) and
    /// key on the real client IP. Only enable behind a proxy you control that sets XFF.
    trusted_proxy_hops: u32,
    api_port: u16,
    api_enabled: bool,
    status_port: ?u16,
    webhooks_enabled: bool,
    webhook_max_retries: u32,
    webhook_db_path: []const u8,
    webhook_admin_username: ?[]const u8,
    webhook_admin_password: ?[]const u8,
    max_memory_mb: u64,
    checkpoint_interval: u64,
    graphql_max_depth: u32,
    graphql_max_cost: u32,
    metrics_enabled: bool,
    rainbow_path: []const u8,
    v1_contracts: contracts.ContractAddresses,
    v2_contracts: contracts.ContractAddresses,

    pub fn fromEnv(allocator: std.mem.Allocator) !Config {
        var env_map = try env_mod.loadEnv(allocator, ".env");
        defer env_mod.deinitEnv(&env_map);

        const network = contracts.Network.fromString(env_mod.getEnv(&env_map, "NETWORK", "sepolia")) catch .sepolia;

        const v1_contract_addrs = try contracts.getContractAddresses(network);
        const v2_contract_addrs = try contracts.getContractAddresses(network);

        return Config{
            .allocator = allocator,
            .rpc_url = try allocator.dupe(u8, env_mod.getEnv(&env_map, "RPC_URL", "http://localhost:8545")),
            .database_path = try allocator.dupe(u8, env_mod.getEnv(&env_map, "DATABASE_PATH", "./data/ens.db")),
            .network = network,
            .v1_contracts = v1_contract_addrs,
            .v2_contracts = v2_contract_addrs,
            .start_block = env_mod.getEnvInt(&env_map, u64, "START_BLOCK", v1_contract_addrs.v1_deployment_block),
            .end_block = blk: {
                const end_str = env_mod.getEnv(&env_map, "END_BLOCK", "");
                if (end_str.len == 0) {
                    break :blk null;
                } else {
                    break :blk env_mod.getEnvInt(&env_map, u64, "END_BLOCK", 0);
                }
            },
            .poll_interval = env_mod.getEnvInt(&env_map, u64, "POLL_INTERVAL", 12),
            .batch_size = env_mod.getEnvInt(&env_map, u64, "BATCH_SIZE", 2000),
            .max_blocks_per_request = env_mod.getEnvInt(&env_map, u64, "MAX_BLOCKS_PER_REQUEST", 2000),
            .rate_limit_per_second = env_mod.getEnvInt(&env_map, u32, "RATE_LIMIT_PER_SECOND", 15),
            .trusted_proxy_hops = env_mod.getEnvInt(&env_map, u32, "TRUSTED_PROXY_HOPS", 0),
            .api_port = env_mod.getEnvInt(&env_map, u16, "API_PORT", 8080),
            .api_enabled = env_mod.getEnvBool(&env_map, "API_ENABLED", true),
            .status_port = blk: {
                const status_str = env_mod.getEnv(&env_map, "STATUS_PORT", "");
                if (status_str.len == 0) {
                    break :blk null;
                } else {
                    break :blk env_mod.getEnvInt(&env_map, u16, "STATUS_PORT", 0);
                }
            },
            .webhooks_enabled = env_mod.getEnvBool(&env_map, "WEBHOOKS_ENABLED", false),
            .webhook_max_retries = env_mod.getEnvInt(&env_map, u32, "WEBHOOK_MAX_RETRIES", 3),
            .webhook_db_path = try allocator.dupe(u8, env_mod.getEnv(&env_map, "WEBHOOK_DB_PATH", "./data/webhooks.db")),
            .webhook_admin_username = blk: {
                const user = env_mod.getEnv(&env_map, "WEBHOOK_ADMIN_USERNAME", "");
                if (user.len == 0) {
                    break :blk null;
                } else {
                    break :blk try allocator.dupe(u8, user);
                }
            },
            .webhook_admin_password = blk: {
                const pwd = env_mod.getEnv(&env_map, "WEBHOOK_ADMIN_PASSWORD", "");
                if (pwd.len == 0) {
                    break :blk null;
                } else {
                    break :blk try allocator.dupe(u8, pwd);
                }
            },
            .max_memory_mb = env_mod.getEnvInt(&env_map, u64, "MAX_MEMORY_MB", 512),
            .checkpoint_interval = env_mod.getEnvInt(&env_map, u64, "CHECKPOINT_INTERVAL", 100),
            .graphql_max_depth = env_mod.getEnvInt(&env_map, u32, "GRAPHQL_MAX_DEPTH", 10),
            .graphql_max_cost = env_mod.getEnvInt(&env_map, u32, "GRAPHQL_MAX_COST", 10000),
            .metrics_enabled = env_mod.getEnvBool(&env_map, "METRICS_ENABLED", false),
            .rainbow_path = try allocator.dupe(u8, env_mod.getEnv(&env_map, "RAINBOW_PATH", "./data/ens_rainbow.db")),
        };
    }

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.rpc_url);
        self.allocator.free(self.database_path);
        self.allocator.free(self.webhook_db_path);
        self.allocator.free(self.rainbow_path);
        if (self.webhook_admin_username) |user| {
            self.allocator.free(user);
        }
        if (self.webhook_admin_password) |pwd| {
            self.allocator.free(pwd);
        }
    }
};
