const std = @import("std");
const env_mod = @import("env.zig");
const contracts = @import("contracts.zig");
const manifest = @import("manifest.zig");
const Address = @import("types/address.zig").Address;

/// Which storage backend to open. Defaults to SQLite so existing deployments are
/// unaffected; selected via DATABASE_BACKEND or inferred from a postgres:// DATABASE_URL.
pub const BackendKind = enum { sqlite, postgres };

pub const Config = struct {
    allocator: std.mem.Allocator,
    rpc_url: []const u8,
    database_path: []const u8,
    /// Active storage backend. SQLite uses `database_path`; Postgres uses `database_url`.
    backend_kind: BackendKind,
    /// Postgres connection URL (`postgres://user:pass@host:port/db`); null on SQLite.
    database_url: ?[]const u8,
    /// Reader-session count for the API's connection pool. Ignored on SQLite
    /// (the pool is degenerate — one shared serialized connection).
    database_pool_size: u32,
    network: contracts.Network,
    start_block: u64,
    end_block: ?u64, // null means index continuously
    poll_interval: u64,
    batch_size: u64,
    /// Fail-fast watchdog: exit(1) after this many minutes of continuous
    /// sync-cycle failure while the network probe reports healthy, so the
    /// container restart policy revives the process (restart is the proven
    /// cure for process-local rot like a frozen TLS validation clock).
    /// 0 disables. (SYNC_FAILURE_EXIT_MINUTES)
    sync_failure_exit_minutes: u64 = 15,
    /// SQLite page-cache size (MB) during bulk sync. Plumbed to the Database so
    /// .env values work (schema.zig can't see the .env map, only process env).
    sync_cache_mb: u64 = 512,
    /// Opt-in deep integrity check (PRAGMA quick_check) at API startup. Off by
    /// default: quick_check reads every btree page — minutes of full-file I/O
    /// on a mainnet-scale DB — and the read-only API can't act on the result.
    api_integrity_check: bool = false,
    /// Buffer V2 events during bulk sync and flush them as multi-row inserts
    /// (V2_EVENT_BUFFER, default on). Ops escape hatch: 0 restores per-event
    /// direct writes.
    v2_event_buffer: bool = true,
    /// Prefetch names rows per ordered dispatch so the ResolverUpdated storm
    /// is served from memory instead of per-event point lookups
    /// (NAME_PREFETCH, default on). Ops escape hatch: 0 restores per-event
    /// DB lookups.
    name_prefetch: bool = true,
    rate_limit_per_second: u32,
    /// Provider ceiling on JSON-RPC batch sizes (requests per HTTP batch);
    /// 0 = unlimited. Set when a provider rejects large batches.
    rpc_max_batch_requests: u32 = 0,
    /// Trusted reverse-proxy hops for rate limiting. 0 (default) = key on the direct TCP
    /// peer. > 0 = trust X-Forwarded-For from this many hops (e.g. 1 for a single LB) and
    /// key on the real client IP. Only enable behind a proxy you control that sets XFF.
    trusted_proxy_hops: u32,
    /// Wall-clock budget (ms) for reading a full request (headers + body). A peer that
    /// trickles bytes slower than this is dropped, backstopping the per-socket receive
    /// timeout against a slow-loris. 0 disables the deadline.
    request_timeout_ms: u32,
    /// Hard cap on concurrent API connections; accepts past it get 503. Bounds worst-case
    /// handler-thread memory (each live connection is one 2MB-stack thread).
    max_concurrent_connections: u32,
    api_port: u16,
    api_enabled: bool,
    status_port: ?u16,
    webhooks_enabled: bool,
    webhook_max_retries: u32,
    webhook_db_path: []const u8,
    webhook_admin_username: ?[]const u8,
    webhook_admin_password: ?[]const u8,
    /// Bearer token for internal/ops endpoints (e.g. /internal/verify-primary).
    /// Null = those routes are only reachable with the webhook Basic credential.
    internal_admin_token: ?[]const u8,
    /// Dedicated (low) per-IP rate limit for the RPC-amplifying internal routes.
    internal_rate_limit_per_second: u32,
    /// Explicit dev opt-in to serve webhook admin routes WITHOUT authentication.
    /// Default false = fail-closed (unconfigured credentials -> routes reject).
    webhooks_allow_unauthenticated: bool,
    checkpoint_interval: u64,
    graphql_max_depth: u32,
    graphql_max_cost: u32,
    metrics_enabled: bool,
    rainbow_path: []const u8,
    v1_contracts: contracts.ContractAddresses,
    v2_contracts: contracts.ContractAddresses,
    /// Query-time resolution RPC endpoint. Defaults to `rpc_url` when unset, so
    /// the resolution layer works with no extra config; point it at a dedicated
    /// endpoint to isolate read traffic from indexing traffic.
    resolve_rpc_url: []const u8,
    /// Soft freshness window (seconds) for cached resolution answers.
    resolve_cache_ttl_s: u32,
    /// Gate for forward-verifying reverse/primary-name claims with an on-chain
    /// read. Off by default; served values are unchanged until enabled.
    primary_verify_enabled: bool,
    /// Gate for issuing live ENSIP-10 Universal Resolver reads on an indexed MISS
    /// (Task 06). Off by default; served values are unchanged until enabled AND a
    /// non-zero `resolve_universal_resolver` is configured.
    resolve_live_enabled: bool,
    /// Universal Resolver address used for live resolution. Defaults to the
    /// network's contract entry (Address.zero until wired per network);
    /// RESOLVE_UNIVERSAL_RESOLVER overrides it at deploy time.
    resolve_universal_resolver: Address,
    /// Gate for completing EIP-3668 CCIP-Read offchain lookups during live resolution
    /// (Task 07). Requires resolve_live_enabled; off by default. Enabling it means the
    /// API makes outbound HTTP to name-controlled gateway URLs (SSRF surface).
    resolve_ccip_enabled: bool,
    /// Per-gateway HTTP timeout (ms) for a CCIP-Read fetch.
    ccip_gateway_timeout_ms: u32,
    /// Max EIP-3668 OffchainLookup redirect hops before giving up (unresolved).
    ccip_max_redirects: u32,
    /// Gate for fetching + persisting per-chain safe/finalized block positions in the
    /// indexer poll loop (Task 09). Off by default. The additive `_finality` API field is
    /// always present but returns nulls until this is on and positions are fetched.
    finality_enabled: bool,

    pub fn fromEnv(allocator: std.mem.Allocator) !Config {
        var env_map = try env_mod.loadEnv(allocator, ".env");
        defer env_mod.deinitEnv(&env_map);

        const network = contracts.Network.fromString(env_mod.getEnv(&env_map, "NETWORK", "sepolia")) catch .sepolia;
        // Contract wiring source: a MANIFEST_PATH .zon manifest wins (config-as-data,
        // Task 08); otherwise the hardcoded code switch (unchanged, the default).
        const manifest_path = env_mod.getEnv(&env_map, "MANIFEST_PATH", "");

        const v1_contract_addrs = if (manifest_path.len > 0)
            try manifest.loadManifest(allocator, manifest_path, network)
        else
            contracts.getContractAddresses(network) catch |err| {
                if (err == error.ManifestRequired) {
                    std.log.err("NETWORK={s} has no built-in contract defaults — set MANIFEST_PATH (see manifests/README.txt)", .{network.toString()});
                }
                return err;
            };
        // Same network → the V1 and V2 sets are the same struct (the code path also
        // returned identical copies); ContractAddresses is a by-value copy.
        const v2_contract_addrs = v1_contract_addrs;

        // DATABASE_URL (Postgres) is owned; backend_kind is the explicit DATABASE_BACKEND
        // if set, else inferred from a postgres:// URL scheme, else SQLite.
        const database_url: ?[]const u8 = blk: {
            const u = env_mod.getEnv(&env_map, "DATABASE_URL", "");
            if (u.len == 0) break :blk null;
            break :blk try allocator.dupe(u8, u);
        };
        errdefer if (database_url) |u| allocator.free(u);
        const backend_kind: BackendKind = blk: {
            const be = env_mod.getEnv(&env_map, "DATABASE_BACKEND", "");
            if (be.len > 0) {
                if (std.ascii.eqlIgnoreCase(be, "postgres") or std.ascii.eqlIgnoreCase(be, "postgresql")) break :blk .postgres;
                if (std.ascii.eqlIgnoreCase(be, "sqlite")) break :blk .sqlite;
                std.log.warn("Unknown DATABASE_BACKEND '{s}'; inferring from DATABASE_URL or defaulting to sqlite", .{be});
            }
            if (database_url) |u| {
                if (std.mem.startsWith(u8, u, "postgres://") or std.mem.startsWith(u8, u, "postgresql://")) break :blk .postgres;
            }
            break :blk .sqlite;
        };

        return Config{
            .allocator = allocator,
            .rpc_url = try allocator.dupe(u8, env_mod.getEnv(&env_map, "RPC_URL", "http://localhost:8545")),
            .database_path = try allocator.dupe(u8, env_mod.getEnv(&env_map, "DATABASE_PATH", "./data/ens.db")),
            .backend_kind = backend_kind,
            .database_url = database_url,
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
            .sync_failure_exit_minutes = env_mod.getEnvInt(&env_map, u64, "SYNC_FAILURE_EXIT_MINUTES", 15),
            .sync_cache_mb = env_mod.getEnvInt(&env_map, u64, "SYNC_CACHE_MB", 512),
            .api_integrity_check = env_mod.getEnvBool(&env_map, "API_INTEGRITY_CHECK", false),
            .v2_event_buffer = env_mod.getEnvBool(&env_map, "V2_EVENT_BUFFER", true),
            .name_prefetch = env_mod.getEnvBool(&env_map, "NAME_PREFETCH", true),
            .rate_limit_per_second = env_mod.getEnvInt(&env_map, u32, "RATE_LIMIT_PER_SECOND", 15),
            .rpc_max_batch_requests = env_mod.getEnvInt(&env_map, u32, "RPC_MAX_BATCH_REQUESTS", 0),
            .trusted_proxy_hops = env_mod.getEnvInt(&env_map, u32, "TRUSTED_PROXY_HOPS", 0),
            .request_timeout_ms = env_mod.getEnvInt(&env_map, u32, "REQUEST_TIMEOUT_MS", 10000),
            .max_concurrent_connections = env_mod.getEnvInt(&env_map, u32, "MAX_CONCURRENT_CONNECTIONS", 512),
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
            .database_pool_size = env_mod.getEnvInt(&env_map, u32, "DATABASE_POOL_SIZE", 10),
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
            .internal_admin_token = blk: {
                const tok = env_mod.getEnv(&env_map, "INTERNAL_ADMIN_TOKEN", "");
                if (tok.len == 0) break :blk null else break :blk try allocator.dupe(u8, tok);
            },
            .internal_rate_limit_per_second = env_mod.getEnvInt(&env_map, u32, "INTERNAL_RATE_LIMIT_PER_SECOND", 2),
            .webhooks_allow_unauthenticated = env_mod.getEnvBool(&env_map, "WEBHOOKS_ALLOW_UNAUTHENTICATED", false),
            .checkpoint_interval = env_mod.getEnvInt(&env_map, u64, "CHECKPOINT_INTERVAL", 100),
            .graphql_max_depth = env_mod.getEnvInt(&env_map, u32, "GRAPHQL_MAX_DEPTH", 10),
            .graphql_max_cost = env_mod.getEnvInt(&env_map, u32, "GRAPHQL_MAX_COST", 10000),
            .metrics_enabled = env_mod.getEnvBool(&env_map, "METRICS_ENABLED", false),
            .rainbow_path = try allocator.dupe(u8, env_mod.getEnv(&env_map, "RAINBOW_PATH", "./data/ens_rainbow.db")),
            // Falls back to RPC_URL (dupe'd independently so `deinit` can free it
            // unconditionally without aliasing `rpc_url`).
            .resolve_rpc_url = try allocator.dupe(u8, env_mod.getEnv(&env_map, "RESOLVE_RPC_URL", env_mod.getEnv(&env_map, "RPC_URL", "http://localhost:8545"))),
            .resolve_cache_ttl_s = env_mod.getEnvInt(&env_map, u32, "RESOLVE_CACHE_TTL_S", 300),
            .primary_verify_enabled = env_mod.getEnvBool(&env_map, "PRIMARY_VERIFY_ENABLED", false),
            .resolve_live_enabled = env_mod.getEnvBool(&env_map, "RESOLVE_LIVE_ENABLED", false),
            .resolve_universal_resolver = blk: {
                const s = env_mod.getEnv(&env_map, "RESOLVE_UNIVERSAL_RESOLVER", "");
                break :blk if (s.len > 0)
                    (Address.fromHex(s) catch v1_contract_addrs.universal_resolver)
                else
                    v1_contract_addrs.universal_resolver;
            },
            // CCIP-Read requires live resolution; asking for CCIP without live is a hard
            // startup error (see validateResolution), not a silently-inert flag.
            .resolve_ccip_enabled = env_mod.getEnvBool(&env_map, "RESOLVE_CCIP_ENABLED", false),
            .ccip_gateway_timeout_ms = env_mod.getEnvInt(&env_map, u32, "CCIP_GATEWAY_TIMEOUT_MS", 5000),
            .ccip_max_redirects = env_mod.getEnvInt(&env_map, u32, "CCIP_MAX_REDIRECTS", 4),
            .finality_enabled = env_mod.getEnvBool(&env_map, "FINALITY_ENABLED", false),
        };
    }

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.rpc_url);
        self.allocator.free(self.database_path);
        if (self.database_url) |url| self.allocator.free(url);
        self.allocator.free(self.webhook_db_path);
        self.allocator.free(self.rainbow_path);
        self.allocator.free(self.resolve_rpc_url);
        if (self.webhook_admin_username) |user| {
            self.allocator.free(user);
        }
        if (self.webhook_admin_password) |pwd| {
            self.allocator.free(pwd);
        }
        if (self.internal_admin_token) |tok| {
            self.allocator.free(tok);
        }
    }

    /// Reject an ambiguous partial webhook-admin credential (exactly one of
    /// username/password set). Fail-closed: refuse to boot in a state where auth
    /// was intended but silently half-disabled.
    pub fn validateAuth(self: *const Config) !void {
        const has_user = self.webhook_admin_username != null;
        const has_pass = self.webhook_admin_password != null;
        if (has_user != has_pass) return error.PartialWebhookAdminConfig;
    }

    /// CCIP-Read (Task 07) is only ever reached via the live-resolution revert path, so
    /// RESOLVE_CCIP_ENABLED without RESOLVE_LIVE_ENABLED is a misconfiguration. Fail fast at
    /// startup rather than run with a silently-inert flag the operator believes is active.
    pub fn validateResolution(self: *const Config) !void {
        if (self.resolve_ccip_enabled and !self.resolve_live_enabled) return error.CcipRequiresLive;
    }
};

test "validateResolution: CCIP without live is a hard error; both-off / both-on / live-only are OK" {
    var c: Config = undefined;
    c.resolve_ccip_enabled = true;
    c.resolve_live_enabled = false;
    try std.testing.expectError(error.CcipRequiresLive, c.validateResolution());
    c.resolve_live_enabled = true; // CCIP + live
    try c.validateResolution();
    c.resolve_ccip_enabled = false; // live only
    try c.validateResolution();
    c.resolve_live_enabled = false; // both off (default)
    try c.validateResolution();
}
