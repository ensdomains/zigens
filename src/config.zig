const std = @import("std");
const env_mod = @import("env.zig");
const contracts = @import("contracts.zig");

pub const Config = struct {
    allocator: std.mem.Allocator,
    l1_rpc_url: []const u8,
    l2_rpc_url: []const u8,
    database_path: []const u8,
    network_l1: contracts.Network,
    network_l2: contracts.Network,
    start_block: u64,
    end_block: ?u64, // null means index continuously
    poll_interval: u64,
    batch_size: u64,
    max_blocks_per_request: u64,
    rate_limit_per_second: u32,
    api_port: u16,
    api_enabled: bool,
    status_port: ?u16,
    webhooks_enabled: bool,
    webhook_max_retries: u32,
    max_memory_mb: u64,
    checkpoint_interval: u64,
    graphql_max_depth: u32,
    graphql_max_cost: u32,
    metrics_enabled: bool,
    l1_contracts: contracts.ContractAddresses,
    l2_contracts: contracts.ContractAddresses,

    // Deprecated: kept for backwards compatibility with single-network mode
    network: contracts.Network,
    contracts: contracts.ContractAddresses,

    pub fn fromEnv(allocator: std.mem.Allocator) !Config {
        var env_map = try env_mod.loadEnv(allocator, ".env");
        defer env_mod.deinitEnv(&env_map);

        // Support dual-network configuration: NETWORK_L1 and NETWORK_L2
        // Falls back to single NETWORK for backwards compatibility
        const network_l1 = contracts.Network.fromString(
            env_mod.getEnv(&env_map, "NETWORK_L1", env_mod.getEnv(&env_map, "NETWORK", "sepolia"))
        ) catch .sepolia;

        const network_l2 = contracts.Network.fromString(
            env_mod.getEnv(&env_map, "NETWORK_L2", env_mod.getEnv(&env_map, "NETWORK", "sepolia"))
        ) catch .sepolia;

        const l1_contract_addrs = try contracts.getContractAddresses(network_l1);
        const l2_contract_addrs = try contracts.getContractAddresses(network_l2);

        // Use L1 contract deployment blocks as default start if START_BLOCK not specified
        const default_start = l1_contract_addrs.v1_deployment_block;

        // Backwards compatibility: use L1 network as primary
        const network = network_l1;
        const contract_addrs = l1_contract_addrs;

        return Config{
            .allocator = allocator,
            .l1_rpc_url = try allocator.dupe(u8, env_mod.getEnv(&env_map, "L1_RPC_URL", "http://localhost:8545")),
            .l2_rpc_url = try allocator.dupe(u8, env_mod.getEnv(&env_map, "L2_RPC_URL", "http://localhost:8546")),
            .database_path = try allocator.dupe(u8, env_mod.getEnv(&env_map, "DATABASE_PATH", "./data/ens.db")),
            .network_l1 = network_l1,
            .network_l2 = network_l2,
            .l1_contracts = l1_contract_addrs,
            .l2_contracts = l2_contract_addrs,
            .network = network,
            .contracts = contract_addrs,
            .start_block = env_mod.getEnvInt(&env_map, u64, "START_BLOCK", default_start),
            .end_block = blk: {
                const end_str = env_mod.getEnv(&env_map, "END_BLOCK", "");
                if (end_str.len == 0) {
                    break :blk null;
                } else {
                    break :blk env_mod.getEnvInt(&env_map, u64, "END_BLOCK", 0);
                }
            },
            .poll_interval = env_mod.getEnvInt(&env_map, u64, "POLL_INTERVAL", 12),
            .batch_size = env_mod.getEnvInt(&env_map, u64, "BATCH_SIZE", 1000),
            .max_blocks_per_request = env_mod.getEnvInt(&env_map, u64, "MAX_BLOCKS_PER_REQUEST", 1000),
            .rate_limit_per_second = env_mod.getEnvInt(&env_map, u32, "RATE_LIMIT_PER_SECOND", 10),
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
            .max_memory_mb = env_mod.getEnvInt(&env_map, u64, "MAX_MEMORY_MB", 512),
            .checkpoint_interval = env_mod.getEnvInt(&env_map, u64, "CHECKPOINT_INTERVAL", 100),
            .graphql_max_depth = env_mod.getEnvInt(&env_map, u32, "GRAPHQL_MAX_DEPTH", 10),
            .graphql_max_cost = env_mod.getEnvInt(&env_map, u32, "GRAPHQL_MAX_COST", 1000),
            .metrics_enabled = env_mod.getEnvBool(&env_map, "METRICS_ENABLED", false),
        };
    }

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.l1_rpc_url);
        self.allocator.free(self.l2_rpc_url);
        self.allocator.free(self.database_path);
    }
};

