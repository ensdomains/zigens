const std = @import("std");
const config = @import("../config.zig");
const constants = @import("../constants.zig");
const db = @import("../storage/database.zig");
const c = db.c;
const rpc = @import("../rpc/client.zig");
const models = @import("../types/models.zig");
const abi = @import("abi.zig");
const Hash = @import("../types/hash.zig").Hash;
const Address = @import("../types/address.zig").Address;
const webhooks = @import("../webhooks/manager.zig");
const RateLimiter = @import("../rate_limiter.zig").RateLimiter;
const json_utils = @import("../utils/json.zig");
const unicode = @import("../utils/unicode.zig");
const NetworkHealth = @import("../utils/network_health.zig").NetworkHealth;
const status_mod = @import("../server/status.zig");
const IndexerStatus = status_mod.IndexerStatus;
const unknown_labels_storage = @import("../storage/unknown_labels.zig");
const LabelBackfill = @import("label_backfill.zig").LabelBackfill;

pub const Indexer = struct {
    allocator: std.mem.Allocator,
    config: config.Config,
    database: *db.Database,
    l1_client: *rpc.Client,
    l2_client: *rpc.Client,
    shared_http_client: *std.http.Client,
    webhook_manager: ?*webhooks.WebhookManager,
    should_stop: std.atomic.Value(bool),
    rate_limiter: RateLimiter,
    blocks_since_checkpoint: u64,
    initial_sync_complete: std.atomic.Value(bool),
    l1_network_health: NetworkHealth,
    l2_network_health: NetworkHealth,
    end_block: ?u64,
    indexer_status: ?*IndexerStatus,
    status_server: ?*status_mod.StatusServer,
    // Block timestamp cache to avoid repeated RPC calls
    block_timestamp_cache: std.AutoHashMap(u64, i64),

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config, database: *db.Database, end_block: ?u64) !Indexer {
        // Create ONE shared HTTP client for both L1 and L2
        const http_client = try allocator.create(std.http.Client);
        http_client.* = std.http.Client{ .allocator = allocator };
        errdefer {
            http_client.deinit();
            allocator.destroy(http_client);
        }

        const l1_client = try rpc.Client.initWithSharedHttpClient(allocator, cfg.l1_rpc_url, http_client);
        errdefer l1_client.deinit();

        const l2_client = try rpc.Client.initWithSharedHttpClient(allocator, cfg.l2_rpc_url, http_client);
        errdefer l2_client.deinit();

        var webhook_manager: ?*webhooks.WebhookManager = null;
        if (cfg.webhooks_enabled) {
            webhook_manager = try webhooks.WebhookManager.init(allocator, cfg.webhook_db_path, cfg.webhook_max_retries, 1000); // 1000ms rate limit per endpoint
            // Workers disabled during indexing to avoid SQLite contention
            // Webhooks are queued and can be processed separately
            // try webhook_manager.?.startWorkers(1);
        }

        // Optionally create status tracking and server if configured
        var indexer_status: ?*IndexerStatus = null;
        var status_server: ?*status_mod.StatusServer = null;

        if (cfg.status_port) |port| {
            // Get current block from database (resume point) or use start_block
            const current_block = try database.getSyncState(.l1) orelse cfg.start_block;

            // Fetch target block from chain if not specified
            const target_block = if (end_block) |eb| eb else blk: {
                const current = l1_client.getBlockNumber() catch |err| {
                    std.log.warn("Failed to fetch current block number from RPC: {any}. Using start_block as fallback.", .{err});
                    break :blk cfg.start_block;
                };
                std.log.info("Fetched current block from chain: {d}", .{current});
                break :blk current;
            };

            // Create status tracking
            const status = try allocator.create(IndexerStatus);
            status.* = IndexerStatus{
                .current_block = current_block,
                .target_block = target_block,
                .start_block = cfg.start_block,
                .start_time = std.time.timestamp(),
                .graphql_enabled = cfg.api_enabled,
                .api_enabled = cfg.api_enabled,
                .webhooks_enabled = cfg.webhooks_enabled,
                .indexing_complete = false,
            };
            indexer_status = status;

            // Create and start status server
            const server = try status_mod.StatusServer.init(allocator, status, port);
            try server.start();
            status_server = server;

            std.log.info("Status server enabled on port {d}", .{port});
        }

        return Indexer{
            .allocator = allocator,
            .config = cfg,
            .database = database,
            .l1_client = l1_client,
            .l2_client = l2_client,
            .shared_http_client = http_client,
            .webhook_manager = webhook_manager,
            .should_stop = std.atomic.Value(bool).init(false),
            .rate_limiter = RateLimiter.init(cfg.rate_limit_per_second, cfg.rate_limit_per_second),
            .blocks_since_checkpoint = 0,
            .initial_sync_complete = std.atomic.Value(bool).init(false),
            .l1_network_health = NetworkHealth.init(allocator, cfg.l1_rpc_url, 3000), // Check every 3s
            .l2_network_health = NetworkHealth.init(allocator, cfg.l2_rpc_url, 3000),
            .end_block = end_block,
            .indexer_status = indexer_status,
            .status_server = status_server,
            .block_timestamp_cache = std.AutoHashMap(u64, i64).init(allocator),
        };
    }

    /// Initialize indexer for a single chain (L1 or L2 only)
    pub fn initSingleChain(allocator: std.mem.Allocator, cfg: config.Config, database: *db.Database, chain: models.Chain, end_block: ?u64) !Indexer {
        const http_client = try allocator.create(std.http.Client);
        http_client.* = std.http.Client{ .allocator = allocator };
        errdefer {
            http_client.deinit();
            allocator.destroy(http_client);
        }

        const rpc_url = if (chain == .l1) cfg.l1_rpc_url else cfg.l2_rpc_url;
        const client = try rpc.Client.initWithSharedHttpClient(allocator, rpc_url, http_client);
        errdefer client.deinit();

        var webhook_manager: ?*webhooks.WebhookManager = null;
        if (cfg.webhooks_enabled) {
            webhook_manager = try webhooks.WebhookManager.init(allocator, cfg.webhook_db_path, cfg.webhook_max_retries, 1000); // 1000ms rate limit per endpoint
            // Workers disabled during indexing to avoid SQLite contention
            // Webhooks are queued and can be processed separately
            // try webhook_manager.?.startWorkers(1);
        }

        // Optionally create status tracking and server if configured
        var indexer_status: ?*IndexerStatus = null;
        var status_server: ?*status_mod.StatusServer = null;

        if (cfg.status_port) |port| {
            // Get current block from database (resume point) or use appropriate deployment block
            const deployment_block = if (chain == .l1) cfg.l1_contracts.l1_deployment_block else cfg.l2_contracts.l2_deployment_block;
            const current_block = try database.getSyncState(chain) orelse deployment_block;

            // Fetch target block from chain if not specified
            const target_block = if (end_block) |eb| eb else blk: {
                const current = client.getBlockNumber() catch |err| {
                    std.log.warn("Failed to fetch current block number from RPC: {any}. Using deployment block as fallback.", .{err});
                    break :blk deployment_block;
                };
                std.log.info("Fetched current block from chain: {d}", .{current});
                break :blk current;
            };

            // Create status tracking
            const status = try allocator.create(IndexerStatus);
            status.* = IndexerStatus{
                .current_block = current_block,
                .target_block = target_block,
                .start_block = deployment_block,
                .start_time = std.time.timestamp(),
                .graphql_enabled = cfg.api_enabled,
                .api_enabled = cfg.api_enabled,
                .webhooks_enabled = cfg.webhooks_enabled,
                .indexing_complete = false,
            };
            indexer_status = status;

            // Create and start status server
            const server = try status_mod.StatusServer.init(allocator, status, port);
            try server.start();
            status_server = server;

            std.log.info("Status server enabled on port {d}", .{port});
        }

        return Indexer{
            .allocator = allocator,
            .config = cfg,
            .database = database,
            .l1_client = client,
            .l2_client = client, // Same client - only one will be used
            .shared_http_client = http_client,
            .webhook_manager = webhook_manager,
            .should_stop = std.atomic.Value(bool).init(false),
            .rate_limiter = RateLimiter.init(cfg.rate_limit_per_second, cfg.rate_limit_per_second),
            .blocks_since_checkpoint = 0,
            .initial_sync_complete = std.atomic.Value(bool).init(false),
            .l1_network_health = NetworkHealth.init(allocator, rpc_url, 3000),
            .l2_network_health = NetworkHealth.init(allocator, rpc_url, 3000), // Same for single chain
            .end_block = end_block,
            .indexer_status = indexer_status,
            .status_server = status_server,
            .block_timestamp_cache = std.AutoHashMap(u64, i64).init(allocator),
        };
    }

    pub fn deinit(self: *Indexer) void {
        // Stop webhook workers before cleanup
        if (self.webhook_manager) |wm| {
            wm.stopWorkers();
        }

        // Stop and cleanup status server if running
        if (self.status_server) |server| {
            server.deinit();
        }
        // Free status tracking if allocated
        if (self.indexer_status) |status| {
            self.allocator.destroy(status);
        }

        // Only deinit l1_client - in single-chain mode, both pointers are the same
        self.l1_client.deinit();
        // Only deinit l2_client if it's a different pointer
        if (self.l1_client != self.l2_client) {
            self.l2_client.deinit();
        }
        self.shared_http_client.deinit();
        self.allocator.destroy(self.shared_http_client);
        if (self.webhook_manager) |wm| {
            wm.deinit();
        }
        self.block_timestamp_cache.deinit();
    }

    /// Get block timestamp, using cache to avoid repeated RPC calls
    fn getBlockTimestamp(self: *Indexer, chain: models.Chain, block_number: u64) i64 {
        // Check cache first
        if (self.block_timestamp_cache.get(block_number)) |ts| {
            return ts;
        }

        // Fetch from RPC
        const client = self.getClient(chain);
        const block = client.getBlockByNumber(block_number, false) catch |err| {
            std.log.warn("Failed to fetch block {d} timestamp: {}, using current time", .{ block_number, err });
            return std.time.timestamp();
        };

        const timestamp: i64 = @intCast(block.timestamp);

        // Cache the result
        self.block_timestamp_cache.put(block_number, timestamp) catch {
            // If cache fails, just return the timestamp without caching
        };

        return timestamp;
    }

    /// Clear block timestamp cache (call after processing a batch to free memory)
    fn clearBlockTimestampCache(self: *Indexer) void {
        self.block_timestamp_cache.clearRetainingCapacity();
    }

    // Helper methods to eliminate chain-specific conditionals
    inline fn getEthRegistry(self: *Indexer, chain: models.Chain) Address {
        return if (chain == .l1) self.config.l1_contracts.eth_registry else self.config.l2_contracts.l2_eth_registry;
    }

    inline fn getDatastore(self: *Indexer, chain: models.Chain) Address {
        return if (chain == .l1) self.config.l1_contracts.registry_datastore else self.config.l2_contracts.l2_registry_datastore;
    }

    inline fn getBridgeController(self: *Indexer, chain: models.Chain) Address {
        return if (chain == .l1) self.config.l1_contracts.l1_bridge_controller else self.config.l2_contracts.l2_bridge_controller;
    }

    inline fn getClient(self: *Indexer, chain: models.Chain) *rpc.Client {
        return if (chain == .l1) self.l1_client else self.l2_client;
    }

    // Generic event indexing abstraction
    const EventIndexConfig = struct {
        event_hash: Hash,
        contract: Address,
        handler: *const fn (*Indexer, models.Chain, rpc.Log) anyerror!void,
        name: []const u8,
    };

    fn indexEvent(
        self: *Indexer,
        chain: models.Chain,
        client: *rpc.Client,
        from_block: u64,
        to_block: u64,
        event_config: EventIndexConfig,
    ) !void {
        const topics = [_]?Hash{event_config.event_hash};
        const logs = try client.getLogs(from_block, to_block, event_config.contract, &topics);
        defer {
            for (logs) |*log| {
                log.deinit(self.allocator);
            }
            self.allocator.free(logs);
        }

        std.log.info("    Found {d} {s} event{s}", .{
            logs.len,
            event_config.name,
            if (logs.len == 1) "" else "s",
        });

        for (logs) |log| {
            try event_config.handler(self, chain, log);
        }
    }

    // Specialized indexEvent for resolver events (includes resolver address parameter)
    fn indexResolverEvent(
        self: *Indexer,
        chain: models.Chain,
        client: *rpc.Client,
        resolver: Address,
        from_block: u64,
        to_block: u64,
        event_hash: Hash,
        handler: *const fn (*Indexer, models.Chain, Address, rpc.Log) anyerror!void,
        name: []const u8,
    ) !void {
        const topics = [_]?Hash{event_hash};
        const logs = try client.getLogs(from_block, to_block, resolver, &topics);
        defer {
            for (logs) |*log| {
                log.deinit(self.allocator);
            }
            self.allocator.free(logs);
        }

        std.log.info("  Found {d} {s} event{s}", .{
            logs.len,
            name,
            if (logs.len == 1) "" else "s",
        });

        for (logs) |log| {
            try handler(self, chain, resolver, log);
        }
    }

    // Event configuration tables for declarative event indexing
    const RegistryEventConfig = struct {
        event_hash: Hash,
        handler: *const fn (*Indexer, models.Chain, rpc.Log) anyerror!void,
        name: []const u8,
    };

    const ETH_REGISTRY_EVENTS = [_]RegistryEventConfig{
        .{ .event_hash = abi.EventSignatures.name_registered_hash, .handler = handleNameRegistered, .name = "NameRegistered" },
        .{ .event_hash = abi.EventSignatures.name_renewed_hash, .handler = handleNameRenewed, .name = "NameRenewed" },
        .{ .event_hash = abi.EventSignatures.name_burned_hash, .handler = handleNameBurned, .name = "NameBurned" },
        .{ .event_hash = abi.EventSignatures.token_regenerated_hash, .handler = handleTokenRegenerated, .name = "TokenRegenerated" },
        // NEW: TokenRegenerated V2 with 3 params (oldTokenId, newTokenId, flags) - current Sepolia deployment
        .{ .event_hash = abi.EventSignatures.token_regenerated_v2_hash, .handler = handleTokenRegenerated, .name = "TokenRegeneratedV2" },
        .{ .event_hash = abi.EventSignatures.eac_roles_changed_hash, .handler = handleEACRolesChanged, .name = "EACRolesChanged" },
    };

    const ETH_REGISTRAR_EVENTS = [_]RegistryEventConfig{
        .{ .event_hash = abi.EventSignatures.commitment_made_hash, .handler = handleCommitmentMade, .name = "CommitmentMade" },
        .{ .event_hash = abi.EventSignatures.eth_name_registered_hash, .handler = handleETHNameRegistered, .name = "ETH NameRegistered" },
        .{ .event_hash = abi.EventSignatures.eth_name_renewed_hash, .handler = handleETHNameRenewed, .name = "ETH NameRenewed" },
    };

    const SUBREGISTRY_EVENTS = [_]RegistryEventConfig{
        .{ .event_hash = abi.EventSignatures.name_registered_hash, .handler = handleNameRegistered, .name = "NameRegistered" },
        .{ .event_hash = abi.EventSignatures.new_subname_hash, .handler = handleNewSubname, .name = "NewSubname" },
        .{ .event_hash = abi.EventSignatures.name_renewed_hash, .handler = handleNameRenewed, .name = "NameRenewed" },
        .{ .event_hash = abi.EventSignatures.name_burned_hash, .handler = handleNameBurned, .name = "NameBurned" },
        .{ .event_hash = abi.EventSignatures.token_regenerated_hash, .handler = handleTokenRegenerated, .name = "TokenRegenerated" },
        .{ .event_hash = abi.EventSignatures.resolver_update_hash, .handler = handleResolverUpdate, .name = "ResolverUpdate" },
        .{ .event_hash = abi.EventSignatures.transfer_single_hash, .handler = handleTransfer, .name = "TransferSingle" },
        .{ .event_hash = abi.EventSignatures.eac_roles_changed_hash, .handler = handleEACRolesChanged, .name = "EACRolesChanged" },
    };

    // Resolver events have different handler signature (include resolver address)
    const ResolverEventConfig = struct {
        event_hash: Hash,
        handler: *const fn (*Indexer, models.Chain, Address, rpc.Log) anyerror!void,
        name: []const u8,
    };

    const RESOLVER_EVENTS = [_]ResolverEventConfig{
        .{ .event_hash = abi.EventSignatures.address_changed_hash, .handler = handleAddressChanged, .name = "AddressChanged" },
        .{ .event_hash = abi.EventSignatures.content_hash_changed_hash, .handler = handleContentHashChanged, .name = "ContentHashChanged" },
        .{ .event_hash = abi.EventSignatures.text_changed_hash, .handler = handleTextChanged, .name = "TextChanged" },
        .{ .event_hash = abi.EventSignatures.abi_changed_hash, .handler = handleABIChanged, .name = "ABIChanged" },
        .{ .event_hash = abi.EventSignatures.pubkey_changed_hash, .handler = handlePubkeyChanged, .name = "PubkeyChanged" },
        .{ .event_hash = abi.EventSignatures.name_changed_hash, .handler = handleNameChanged, .name = "NameChanged" },
        .{ .event_hash = abi.EventSignatures.interface_changed_hash, .handler = handleInterfaceChanged, .name = "InterfaceChanged" },
    };

    // ========================================================================
    // V1 EVENT CONFIGURATIONS (ENS V1 - Mainnet)
    // ========================================================================

    // ENS Registry events (0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e)
    const V1_REGISTRY_EVENTS = [_]RegistryEventConfig{
        .{ .event_hash = abi.EventSignatures.new_owner_hash, .handler = handleV1NewOwner, .name = "NewOwner" },
        .{ .event_hash = abi.EventSignatures.registry_transfer_hash, .handler = handleV1RegistryTransfer, .name = "RegistryTransfer" },
        .{ .event_hash = abi.EventSignatures.new_resolver_hash, .handler = handleV1NewResolver, .name = "NewResolver" },
        .{ .event_hash = abi.EventSignatures.new_ttl_hash, .handler = handleV1NewTTL, .name = "NewTTL" },
    };

    // Name Wrapper events (0xD4416b13d2b3a9aBae7AcD5D6C2BbDBE25686401)
    const V1_NAME_WRAPPER_EVENTS = [_]RegistryEventConfig{
        .{ .event_hash = abi.EventSignatures.name_wrapped_hash, .handler = handleV1NameWrapped, .name = "NameWrapped" },
        .{ .event_hash = abi.EventSignatures.name_unwrapped_hash, .handler = handleV1NameUnwrapped, .name = "NameUnwrapped" },
        .{ .event_hash = abi.EventSignatures.fuses_set_hash, .handler = handleV1FusesSet, .name = "FusesSet" },
        .{ .event_hash = abi.EventSignatures.expiry_extended_hash, .handler = handleV1ExpiryExtended, .name = "ExpiryExtended" },
    };

    // Base Registrar events (0x57f1887a8BF19b14fC0dF6Fd9B2acc9Af147eA85)
    const V1_BASE_REGISTRAR_EVENTS = [_]RegistryEventConfig{
        .{ .event_hash = abi.EventSignatures.erc721_transfer_hash, .handler = handleV1ERC721Transfer, .name = "Transfer" },
        .{ .event_hash = abi.EventSignatures.base_registrar_name_registered_hash, .handler = handleV1BaseRegistrarNameRegistered, .name = "NameRegistered" },
        .{ .event_hash = abi.EventSignatures.base_registrar_name_renewed_hash, .handler = handleV1BaseRegistrarNameRenewed, .name = "NameRenewed" },
        .{ .event_hash = abi.EventSignatures.controller_added_hash, .handler = handleV1ControllerAdded, .name = "ControllerAdded" },
        .{ .event_hash = abi.EventSignatures.controller_removed_hash, .handler = handleV1ControllerRemoved, .name = "ControllerRemoved" },
    };

    // ETH Registrar Controller events (0x59E16fcCd424Cc24e280Be16E11Bcd56fb0CE547)
    // These events provide the label text, which is critical for V1 name resolution
    const V1_ETH_CONTROLLER_EVENTS = [_]RegistryEventConfig{
        .{ .event_hash = abi.EventSignatures.controller_name_registered_hash, .handler = handleV1ETHControllerNameRegistered, .name = "NameRegistered" },
        .{ .event_hash = abi.EventSignatures.controller_name_renewed_hash, .handler = handleV1ETHControllerNameRenewed, .name = "NameRenewed" },
    };

    // Reverse Registrar events (0xa58E81fe9b61B5c3fE2AFD33CF304c454AbFc7Cb)
    const V1_REVERSE_REGISTRAR_EVENTS = [_]RegistryEventConfig{
        .{ .event_hash = abi.EventSignatures.reverse_claimed_hash, .handler = handleV1ReverseClaimed, .name = "ReverseClaimed" },
    };

    // Temporary Registrar events (0x6090A6e47849629b7245Dfa1Ca21D94cd15878Ef)
    // Pre-V1 Migration: May 2017 (block 3327417) - May 2019 (block 9380410)
    const TEMP_REGISTRAR_EVENTS = [_]RegistryEventConfig{
        .{ .event_hash = abi.EventSignatures.auction_started_hash, .handler = handleTempAuctionStarted, .name = "AuctionStarted" },
        .{ .event_hash = abi.EventSignatures.new_bid_hash, .handler = handleTempNewBid, .name = "NewBid" },
        .{ .event_hash = abi.EventSignatures.bid_revealed_hash, .handler = handleTempBidRevealed, .name = "BidRevealed" },
        .{ .event_hash = abi.EventSignatures.hash_registered_hash, .handler = handleTempHashRegistered, .name = "HashRegistered" },
        .{ .event_hash = abi.EventSignatures.hash_released_hash, .handler = handleTempHashReleased, .name = "HashReleased" },
        .{ .event_hash = abi.EventSignatures.hash_invalidated_hash, .handler = handleTempHashInvalidated, .name = "HashInvalidated" },
    };

    /// Generic chunked batch event indexing for V1 events with adaptive chunk sizing
    /// Dynamically adjusts chunk size based on event density to optimize RPC calls
    fn indexV1EventsChunked(
        self: *Indexer,
        chain: models.Chain,
        client: *rpc.Client,
        from_block: u64,
        to_block: u64,
        contract_address: Address,
        event_configs: []const RegistryEventConfig,
        contract_name: []const u8,
    ) !void {
        // Predictive adaptive chunk sizing
        const MIN_CHUNK_SIZE: u64 = constants.RpcBatching.min_chunk_size;
        const MAX_CHUNK_SIZE: u64 = self.config.batch_size; // Use configured batch size as maximum
        const TARGET_EVENTS_PER_CHUNK: usize = 25000; // Target ~25000 events per chunk

        var current_chunk_size: u64 = 100; // Start conservative
        var events_per_block: f64 = 5.0;   // Initial estimate: 5 events/block average
        var chunk_start = from_block;

        while (chunk_start <= to_block) {
            // PREDICTIVE: Calculate optimal chunk size BEFORE making request
            // Based on learned event density from previous chunks
            const predicted_chunk_size = blk: {
                if (events_per_block < 0.1) {
                    // Very sparse: use maximum chunk size
                    break :blk MAX_CHUNK_SIZE;
                }
                // Calculate chunk size to hit target event count
                const calculated = @as(u64, @intFromFloat(@ceil(@as(f64, @floatFromInt(TARGET_EVENTS_PER_CHUNK)) / events_per_block)));
                // Clamp to min/max bounds
                break :blk @min(MAX_CHUNK_SIZE, @max(MIN_CHUNK_SIZE, calculated));
            };
            current_chunk_size = predicted_chunk_size;

            // RETRY LOOP: Handle sudden density spikes that predictor couldn't foresee
            var retry_chunk_size = current_chunk_size;
            const ABSOLUTE_MIN_CHUNK: u64 = 10; // Last resort minimum

            retry_loop: while (true) {
                const chunk_end = @min(chunk_start + retry_chunk_size - 1, to_block);
                const blocks_in_chunk = chunk_end - chunk_start + 1;

                std.log.info("Indexing V1 {s} events from blocks {d}-{d} (chunk_size={d}, predicted_density={d:.2} events/block)", .{
                    contract_name,
                    chunk_start,
                    chunk_end,
                    retry_chunk_size,
                    events_per_block,
                });

                // Batch all events in a single RPC call
                var batch_requests = try self.allocator.alloc(rpc.Client.BatchGetLogsRequest, event_configs.len);
                defer self.allocator.free(batch_requests);

                // Allocate topics arrays (need to persist until RPC call completes)
                var topics_arrays = try self.allocator.alloc([]const ?Hash, event_configs.len);
                defer {
                    for (topics_arrays) |topics| {
                        self.allocator.free(topics);
                    }
                    self.allocator.free(topics_arrays);
                }

                for (event_configs, 0..) |event_cfg, i| {
                    var topics = try self.allocator.alloc(?Hash, 1);
                    topics[0] = event_cfg.event_hash;
                    topics_arrays[i] = topics;

                    // DEBUG: Print event hash being searched
                    const event_hash_hex = try event_cfg.event_hash.toHex(self.allocator);
                    defer self.allocator.free(event_hash_hex);
                    std.log.debug("  Searching for {s}: {s}", .{ event_cfg.name, event_hash_hex });

                    batch_requests[i] = .{
                        .from_block = chunk_start,
                        .to_block = chunk_end,
                        .address = contract_address,
                        .topics = topics,
                    };
                }

                // Try the RPC call - retry with smaller chunks if buffer overflow
                const batch_results = client.getLogsBatch(batch_requests) catch |err| {
                    // Handle both RPC provider buffer overflow (error.RpcError) and curl buffer overflow (error.StdoutStreamTooLong)
                    if ((err == error.RpcError or err == error.StdoutStreamTooLong) and retry_chunk_size > ABSOLUTE_MIN_CHUNK) {
                        // Buffer overflow - halve chunk size and retry
                        retry_chunk_size = @max(ABSOLUTE_MIN_CHUNK, retry_chunk_size / 2);
                        std.log.warn("  🔄 Buffer overflow! Retrying with smaller chunk: {d} blocks", .{retry_chunk_size});
                        continue :retry_loop;
                    }
                    return err; // Other errors or hit minimum chunk size
                };
                defer {
                    for (batch_results) |logs| {
                        for (logs) |*log| {
                            log.deinit(self.allocator);
                        }
                        self.allocator.free(logs);
                    }
                    self.allocator.free(batch_results);
                }

                // Process each event type and count total events
                var total_events: usize = 0;
                for (event_configs, 0..) |event_cfg, i| {
                    const logs = batch_results[i];
                    total_events += logs.len;

                    if (logs.len > 0) {
                        std.log.info("  Found {d} V1 {s} event{s}", .{
                            logs.len,
                            event_cfg.name,
                            if (logs.len == 1) "" else "s",
                        });
                    }

                    for (logs) |log| {
                        try event_cfg.handler(self, chain, log);
                    }
                }

                // LEARNING: Update event density estimate using exponential moving average
                // This smooths out spikes while adapting to trends
                const actual_events_per_block = @as(f64, @floatFromInt(total_events)) / @as(f64, @floatFromInt(blocks_in_chunk));
                const LEARNING_RATE = 0.3; // 30% weight to new data, 70% to history
                const old_density = events_per_block;
                events_per_block = events_per_block * (1.0 - LEARNING_RATE) + actual_events_per_block * LEARNING_RATE;

                // Calculate next chunk size with exponential scaling based on density
                // Target: 500 events per chunk. If density is 5 events/block, we want 100 blocks.
                // Calculate ideal chunk size, then apply exponential scaling to current size
                const ideal_chunk_size = @as(f64, @floatFromInt(TARGET_EVENTS_PER_CHUNK)) / @max(0.001, events_per_block);
                const size_ratio = ideal_chunk_size / @as(f64, @floatFromInt(retry_chunk_size));
                const scale_factor = std.math.pow(f64, size_ratio, 0.5); // Square root for smooth exponential scaling
                const next_chunk_size = @min(MAX_CHUNK_SIZE, @max(MIN_CHUNK_SIZE, @as(u64, @intFromFloat(@as(f64, @floatFromInt(retry_chunk_size)) * scale_factor))));

                if (total_events > TARGET_EVENTS_PER_CHUNK * 2) {
                    std.log.info("  ⚠️  High density: {d} events ({d:.2}→{d:.2} events/block), next chunk: {d} blocks", .{
                        total_events,
                        old_density,
                        events_per_block,
                        next_chunk_size,
                    });
                } else if (total_events < TARGET_EVENTS_PER_CHUNK / 2) {
                    std.log.info("  ✅ Low density: {d} events ({d:.2}→{d:.2} events/block), next chunk: {d} blocks", .{
                        total_events,
                        old_density,
                        events_per_block,
                        next_chunk_size,
                    });
                }

                chunk_start = chunk_end + 1;
                // Rate limit: wait between batches to avoid hitting RPC provider limits
                if (chunk_start <= to_block) {
                    std.Thread.sleep(constants.Timing.rpc_retry_delay_ms * std.time.ns_per_ms); // 200ms delay between batches
                }
                break :retry_loop; // Success - move to next chunk
            }
        }
    }

    /// EFFICIENT V1 indexing: Process ALL V1 contracts together per chunk
    /// This avoids reprocessing the same block range multiple times
    fn indexAllV1Events(self: *Indexer, chain: models.Chain, client: *rpc.Client, from_block: u64, to_block: u64) !void {
        if (chain != .l1) return; // V1 events only exist on mainnet L1

        // Index Temporary Registrar events FIRST (for pre-migration blocks only)
        // This function internally checks block ranges and only indexes before block 9380410
        try self.indexTempRegistrarEvents(chain, client, from_block, to_block);

        // Predictive adaptive chunk sizing
        const MIN_CHUNK_SIZE: u64 = constants.RpcBatching.min_chunk_size;
        const MAX_CHUNK_SIZE: u64 = self.config.batch_size; // Use configured batch size as maximum
        const TARGET_EVENTS_PER_CHUNK: usize = 25000; // Target ~25000 events per chunk

        var current_chunk_size: u64 = 100; // Start conservative
        var events_per_block: f64 = 5.0;   // Initial estimate: 5 events/block average
        var chunk_start = from_block;

        // Name Wrapper deployment block (from contract config)
        const NAME_WRAPPER_DEPLOYMENT_BLOCK = self.config.l1_contracts.name_wrapper_deployment_block;

        while (chunk_start <= to_block) {
            // Flag to indicate if we need to reprocess this chunk due to new controllers
            var needs_controller_reprocess = false;

            // PREDICTIVE: Calculate optimal chunk size BEFORE making request
            const predicted_chunk_size = blk: {
                if (events_per_block < 0.1) {
                    break :blk MAX_CHUNK_SIZE;
                }
                const calculated = @as(u64, @intFromFloat(@ceil(@as(f64, @floatFromInt(TARGET_EVENTS_PER_CHUNK)) / events_per_block)));
                break :blk @min(MAX_CHUNK_SIZE, @max(MIN_CHUNK_SIZE, calculated));
            };
            current_chunk_size = predicted_chunk_size;

            // RETRY LOOP: Handle sudden density spikes that predictor couldn't foresee
            var retry_chunk_size = current_chunk_size;
            const ABSOLUTE_MIN_CHUNK: u64 = 10; // Last resort minimum

            retry_loop: while (true) {
                const chunk_end = @min(chunk_start + retry_chunk_size - 1, to_block);
                const blocks_in_chunk = chunk_end - chunk_start + 1;

                std.log.info("Indexing V1 events from blocks {d}-{d} (chunk_size={d}, predicted_density={d:.2} events/block)", .{
                    chunk_start,
                    chunk_end,
                    retry_chunk_size,
                    events_per_block,
                });

            // Build batch requests for ALL V1 contracts in this chunk
            var batch_list: std.ArrayList(rpc.Client.BatchGetLogsRequest) = .{};
            defer batch_list.deinit(self.allocator);

            var topics_list: std.ArrayList([]const ?Hash) = .{};
            defer {
                for (topics_list.items) |topics| {
                    self.allocator.free(topics);
                }
                topics_list.deinit(self.allocator);
            }

            // Track which contract/event each batch request corresponds to
            const ContractEventInfo = struct {
                contract_name: []const u8,
                event_config: RegistryEventConfig,
                contract_addr: Address,
            };
            var request_info_list: std.ArrayList(ContractEventInfo) = .{};
            defer request_info_list.deinit(self.allocator);

            // 1. ETH Registrar Controller events - MUST BE FIRST!
            // ETH Controller events contain the label text which Base Registrar needs
            // Query active controllers dynamically from database
            const v1_controllers = @import("../storage/v1_controllers.zig");
            const active_controllers = try v1_controllers.getActiveControllers(self.allocator, self.database);
            defer self.allocator.free(active_controllers);

            if (active_controllers.len == 0) {
                std.log.warn("No active V1 controllers found in database - using config fallback", .{});
                // Fallback to config if no controllers in DB (e.g., fresh database)
                for (V1_ETH_CONTROLLER_EVENTS) |event_cfg| {
                    var topics = try self.allocator.alloc(?Hash, 1);
                    topics[0] = event_cfg.event_hash;
                    try topics_list.append(self.allocator, topics);

                    try batch_list.append(self.allocator, .{
                        .from_block = chunk_start,
                        .to_block = chunk_end,
                        .address = self.config.l1_contracts.eth_registrar_controller,
                        .topics = topics,
                    });
                    try request_info_list.append(self.allocator, .{
                        .contract_name = "ETH Registrar Controller",
                        .event_config = event_cfg,
                        .contract_addr = self.config.l1_contracts.eth_registrar_controller,
                    });
                }
            } else {
                // Index events from ALL active controllers
                for (active_controllers) |controller_addr| {
                    const controller_hex = try controller_addr.toHex(self.allocator);
                    defer self.allocator.free(controller_hex);
                    std.log.debug("Indexing controller: {s}", .{controller_hex});

                    for (V1_ETH_CONTROLLER_EVENTS) |event_cfg| {
                        var topics = try self.allocator.alloc(?Hash, 1);
                        topics[0] = event_cfg.event_hash;
                        try topics_list.append(self.allocator, topics);

                        try batch_list.append(self.allocator, .{
                            .from_block = chunk_start,
                            .to_block = chunk_end,
                            .address = controller_addr,
                            .topics = topics,
                        });
                        try request_info_list.append(self.allocator, .{
                            .contract_name = "ETH Registrar Controller",
                            .event_config = event_cfg,
                            .contract_addr = controller_addr,
                        });
                    }
                }
            }

            // 2. Base Registrar events
            // These can now look up labels from v1_labels table populated above
            for (V1_BASE_REGISTRAR_EVENTS) |event_cfg| {
                var topics = try self.allocator.alloc(?Hash, 1);
                topics[0] = event_cfg.event_hash;
                try topics_list.append(self.allocator, topics);

                try batch_list.append(self.allocator, .{
                    .from_block = chunk_start,
                    .to_block = chunk_end,
                    .address = self.config.l1_contracts.base_registrar,
                    .topics = topics,
                });
                try request_info_list.append(self.allocator, .{
                    .contract_name = "Base Registrar",
                    .event_config = event_cfg,
                    .contract_addr = self.config.l1_contracts.base_registrar,
                });
            }

            // 3. ENS Registry events
            for (V1_REGISTRY_EVENTS) |event_cfg| {
                var topics = try self.allocator.alloc(?Hash, 1);
                topics[0] = event_cfg.event_hash;
                try topics_list.append(self.allocator, topics);

                try batch_list.append(self.allocator, .{
                    .from_block = chunk_start,
                    .to_block = chunk_end,
                    .address = self.config.l1_contracts.ens_registry,
                    .topics = topics,
                });
                try request_info_list.append(self.allocator, .{
                    .contract_name = "ENS Registry",
                    .event_config = event_cfg,
                    .contract_addr = self.config.l1_contracts.ens_registry,
                });
            }

            // 4. Name Wrapper events (only if we're past deployment block)
            if (chunk_end >= NAME_WRAPPER_DEPLOYMENT_BLOCK) {
                for (V1_NAME_WRAPPER_EVENTS) |event_cfg| {
                    var topics = try self.allocator.alloc(?Hash, 1);
                    topics[0] = event_cfg.event_hash;
                    try topics_list.append(self.allocator, topics);

                    try batch_list.append(self.allocator, .{
                        .from_block = @max(chunk_start, NAME_WRAPPER_DEPLOYMENT_BLOCK),
                        .to_block = chunk_end,
                        .address = self.config.l1_contracts.name_wrapper,
                        .topics = topics,
                    });
                    try request_info_list.append(self.allocator, .{
                        .contract_name = "Name Wrapper",
                        .event_config = event_cfg,
                        .contract_addr = self.config.l1_contracts.name_wrapper,
                    });
                }
            }

            // 5. Reverse Registrar events
            for (V1_REVERSE_REGISTRAR_EVENTS) |event_cfg| {
                var topics = try self.allocator.alloc(?Hash, 1);
                topics[0] = event_cfg.event_hash;
                try topics_list.append(self.allocator, topics);

                try batch_list.append(self.allocator, .{
                    .from_block = chunk_start,
                    .to_block = chunk_end,
                    .address = self.config.l1_contracts.reverse_registrar,
                    .topics = topics,
                });
                try request_info_list.append(self.allocator, .{
                    .contract_name = "Reverse Registrar",
                    .event_config = event_cfg,
                    .contract_addr = self.config.l1_contracts.reverse_registrar,
                });
            }

            // Execute batch RPC call for ALL contracts at once - retry with smaller chunks if buffer overflow
            const batch_results = client.getLogsBatch(batch_list.items) catch |err| {
                // Handle both RPC provider buffer overflow (error.RpcError) and curl buffer overflow (error.StdoutStreamTooLong)
                if ((err == error.RpcError or err == error.StdoutStreamTooLong) and retry_chunk_size > ABSOLUTE_MIN_CHUNK) {
                    // Buffer overflow - halve chunk size and retry
                    retry_chunk_size = @max(ABSOLUTE_MIN_CHUNK, retry_chunk_size / 2);
                    std.log.warn("  🔄 Buffer overflow! Retrying with smaller chunk: {d} blocks", .{retry_chunk_size});
                    continue :retry_loop;
                }
                return err; // Other errors or hit minimum chunk size
            };
            defer {
                for (batch_results) |logs| {
                    for (logs) |*log| {
                        log.deinit(self.allocator);
                    }
                    self.allocator.free(logs);
                }
                self.allocator.free(batch_results);
            }

            // Process results
            // Process events and count total
            // Track if any ControllerAdded events were found (need to reprocess chunk)
            const controllers_before = try v1_controllers.getActiveControllers(self.allocator, self.database);
            defer self.allocator.free(controllers_before);
            const controller_count_before = controllers_before.len;

            var total_events: usize = 0;
            for (batch_results, 0..) |logs, i| {
                const info = request_info_list.items[i];
                total_events += logs.len;

                if (logs.len > 0) {
                    std.log.info("  Found {d} V1 {s} {s} event{s}", .{
                        logs.len,
                        info.contract_name,
                        info.event_config.name,
                        if (logs.len == 1) "" else "s",
                    });
                }

                for (logs) |log| {
                    try info.event_config.handler(self, chain, log);
                }
            }

            // Check if new controllers were added during processing
            const controllers_after = try v1_controllers.getActiveControllers(self.allocator, self.database);
            defer self.allocator.free(controllers_after);

            // Detect NEW controllers by comparing address lists
            var has_new_controller = false;
            if (controllers_after.len > controller_count_before) {
                // More controllers now - check which ones are new
                outer: for (controllers_after) |new_addr| {
                    for (controllers_before) |old_addr| {
                        if (std.mem.eql(u8, &new_addr.bytes, &old_addr.bytes)) {
                            continue :outer; // This controller already existed
                        }
                    }
                    // Found a controller that wasn't in the before list
                    has_new_controller = true;
                    const new_controller_hex = try new_addr.toHex(self.allocator);
                    defer self.allocator.free(new_controller_hex);
                    std.log.warn("  🔄 New controller discovered: {s}! Reprocessing chunk {d}-{d}", .{ new_controller_hex, chunk_start, chunk_end });
                    break;
                }
            }

            if (has_new_controller) {
                // Set flag to reprocess this chunk with new controllers
                // This will cause the outer while loop to restart without advancing chunk_start
                needs_controller_reprocess = true;
                break :retry_loop;
            }

            // LEARNING: Update event density estimate using exponential moving average
            // This smooths out spikes while adapting to trends
            const actual_events_per_block = @as(f64, @floatFromInt(total_events)) / @as(f64, @floatFromInt(blocks_in_chunk));
            const LEARNING_RATE = 0.3; // 30% weight to new data, 70% to history
            const old_density = events_per_block;
            events_per_block = events_per_block * (1.0 - LEARNING_RATE) + actual_events_per_block * LEARNING_RATE;

            // Calculate next chunk size with exponential scaling based on density
            // Target: 500 events per chunk. If density is 5 events/block, we want 100 blocks.
            // Calculate ideal chunk size, then apply exponential scaling to current size
            const ideal_chunk_size = @as(f64, @floatFromInt(TARGET_EVENTS_PER_CHUNK)) / @max(0.001, events_per_block);
            const size_ratio = ideal_chunk_size / @as(f64, @floatFromInt(retry_chunk_size));
            const scale_factor = std.math.pow(f64, size_ratio, 0.5); // Square root for smooth exponential scaling
            const next_chunk_size = @min(MAX_CHUNK_SIZE, @max(MIN_CHUNK_SIZE, @as(u64, @intFromFloat(@as(f64, @floatFromInt(retry_chunk_size)) * scale_factor))));

            if (total_events > TARGET_EVENTS_PER_CHUNK * 2) {
                std.log.info("  ⚠️  High density: {d} events ({d:.2}→{d:.2} events/block), next chunk: {d} blocks", .{
                    total_events,
                    old_density,
                    events_per_block,
                    next_chunk_size,
                });
            } else if (total_events < TARGET_EVENTS_PER_CHUNK / 2) {
                std.log.info("  ✅ Low density: {d} events ({d:.2}→{d:.2} events/block), next chunk: {d} blocks", .{
                    total_events,
                    old_density,
                    events_per_block,
                    next_chunk_size,
                });
            }

            // Only advance to next chunk if we're not reprocessing for new controllers
            if (!needs_controller_reprocess) {
                chunk_start = chunk_end + 1;
                // Rate limit: wait between batches to avoid hitting RPC provider limits
                if (chunk_start <= to_block) {
                    std.Thread.sleep(constants.Timing.rpc_retry_delay_ms * std.time.ns_per_ms); // 200ms delay between batches
                }
            }
            break :retry_loop; // Success - move to next chunk (or reprocess current chunk)
            }
        }
    }

    /// Helper function to insert an event and trigger webhooks with proper memory cleanup
    /// This ensures that event.name and event.data are ALWAYS freed after use
    fn insertEventAndNotify(self: *Indexer, event: models.Event) !void {
        // Insert event into database (database makes a copy via SQLITE_TRANSIENT)
        // We must free our allocations whether insert succeeds or fails
        defer {
            if (event.name) |name| self.allocator.free(name);
            self.allocator.free(event.data);
        }

        // Try to insert the event
        try self.database.insertEvent(event);

        // Trigger webhook if enabled (only after initial sync to avoid notifying about historical events)
        if (self.initial_sync_complete.load(.acquire)) {
            if (self.webhook_manager) |wm| {
                wm.notify(event) catch |err| {
                    // Webhook failed but event was inserted successfully
                    // Just log the error - event was successfully stored
                    std.log.warn("Webhook notification failed: {}", .{err});
                    // Don't return error - event was successfully stored
                };
            }
        }
    }

    pub fn start(self: *Indexer) !void {
        std.log.info("Indexer starting...", .{});

        while (!self.should_stop.load(.acquire)) {
            // Index L1 first (SQLite doesn't support concurrent writes from different threads)
            try self.indexChain(.l1, self.l1_client);

            // Then index L2
            try self.indexChain(.l2, self.l2_client);

            // After first successful sync of both chains, start webhook workers
            if (!self.initial_sync_complete.load(.acquire)) {
                self.initial_sync_complete.store(true, .release);
                if (self.webhook_manager) |wm| {
                    std.log.info("Initial sync complete - starting webhook workers", .{});
                    try wm.startWorkers(1);
                }
            }

            // Sleep for poll interval before next iteration
            std.Thread.sleep(self.config.poll_interval * std.time.ns_per_s);
        }

        std.log.info("Indexer stopped.", .{});
    }

    pub fn stop(self: *Indexer) void {
        self.should_stop.store(true, .release);
    }

    /// Start indexing a single chain (for separate process architecture)
    pub fn startSingleChain(self: *Indexer, chain: models.Chain) !void {
        std.log.info("Single-chain indexer starting for {s}...", .{chain.toString()});

        const client = self.getClient(chain);
        var network_health = if (chain == .l1) &self.l1_network_health else &self.l2_network_health;

        while (!self.should_stop.load(.acquire)) {
            if (self.indexChain(chain, client)) |_| {
                // Success - after first successful sync, start webhook workers
                if (!self.initial_sync_complete.load(.acquire)) {
                    self.initial_sync_complete.store(true, .release);
                    if (self.webhook_manager) |wm| {
                        std.log.info("Initial sync complete - starting webhook workers", .{});
                        try wm.startWorkers(1);
                    }

                    // Backfill pre-migration names after initial sync completes
                    if (chain == .l1) {
                        std.log.info("Running pre-migration names backfill...", .{});
                        self.backfillPreMigrationNames() catch |err| {
                            std.log.err("Failed to backfill pre-migration names: {}", .{err});
                        };

                        // Backfill unknown subdomain labels from transaction calldata
                        std.log.info("Running unknown labels backfill...", .{});
                        self.backfillUnknownLabels() catch |err| {
                            std.log.err("Failed to backfill unknown labels: {}", .{err});
                        };
                    }
                }
            } else |err| {
                // Handle errors gracefully based on type
                switch (err) {
                    error.HttpError, error.NetworkUnreachable, error.ConnectionRefused, error.ConnectionTimedOut, error.ConnectionResetByPeer => {
                        // Network error - wait for connection to be restored
                        std.log.warn("{s} network error detected: {}, waiting for connection...", .{ chain.toString(), err });
                        network_health.waitForHealthy();
                        std.log.info("{s} network restored, continuing...", .{chain.toString()});
                        // No sleep - continue immediately after network is back
                        continue;
                    },
                    else => {
                        // Other errors (database, parsing, etc) - log and wait briefly
                        std.log.err("{s} indexing error: {}", .{ chain.toString(), err });
                        std.Thread.sleep(constants.Timing.error_recovery_delay_ms * std.time.ns_per_ms); // Wait 5s for non-network errors
                    },
                }
            }

            // Sleep for poll interval before next iteration
            std.Thread.sleep(self.config.poll_interval * std.time.ns_per_s);
        }

        std.log.info("{s} indexer stopped.", .{chain.toString()});
    }

    fn indexChain(self: *Indexer, chain: models.Chain, client: *rpc.Client) !void {
        // Use chain-specific deployment block as fallback for fresh databases
        const deployment_block = switch (chain) {
            .l1 => self.config.l1_contracts.l1_deployment_block,
            .l2 => self.config.l2_contracts.l2_deployment_block,
        };

        // Get last synced block from database (resumability)
        var last_synced = try self.database.getSyncState(chain) orelse deployment_block;

        // REORG DETECTION: Check if we need to roll back
        if (last_synced > deployment_block) {
            const stored_hash = try self.database.getBlockHash(chain, last_synced);

            if (stored_hash) |expected_hash| {
                // Fetch current block hash from RPC
                const actual_block = client.getBlockByNumber(last_synced, false) catch |err| {
                    std.log.warn("Failed to fetch block {d} for reorg check: {}", .{ last_synced, err });
                    return err;
                };

                // Compare hashes - if mismatch, we have a reorg!
                if (!std.mem.eql(u8, &expected_hash.bytes, &actual_block.hash.bytes)) {
                    std.log.err("REORG DETECTED at block {d} on {s}!", .{ last_synced, chain.toString() });
                    std.log.err("Block hash mismatch detected - rolling back", .{});

                    // Find the last valid block by going backwards
                    var rollback_to = last_synced - 1;
                    while (rollback_to > self.config.start_block) : (rollback_to -= 1) {
                        const check_hash = try self.database.getBlockHash(chain, rollback_to);
                        if (check_hash == null) {
                            // No stored hash, assume this is safe
                            break;
                        }

                        const check_block = client.getBlockByNumber(rollback_to, false) catch break;

                        if (std.mem.eql(u8, &check_hash.?.bytes, &check_block.hash.bytes)) {
                            // Found matching block
                            break;
                        }
                    }

                    std.log.warn("Rolling back {s} to block {d}", .{ chain.toString(), rollback_to });
                    try self.database.rollbackToBlock(chain, rollback_to);
                    last_synced = rollback_to;
                }
            }
        }

        // Get current block number
        const current_block = try client.getBlockNumber();
        const target_block = if (self.end_block) |eb| @min(eb, current_block) else current_block;

        // Update status target_block to reflect latest chain block
        if (self.indexer_status) |status| {
            status.target_block = target_block;
        }

        if (last_synced >= target_block) {
            // Mark as complete when caught up
            if (self.indexer_status) |status| {
                status.indexing_complete = true;
            }
            return; // Nothing new to index
        }

        // Mark as in-progress when there are blocks to index
        if (self.indexer_status) |status| {
            status.indexing_complete = false;
        }

        const total_blocks = target_block - last_synced;
        std.log.info("Indexing {s} from block {d} to {d} ({d} blocks)", .{ chain.toString(), last_synced + 1, target_block, total_blocks });

        // Index in batches with memory management
        const batch_size = self.config.batch_size;
        var from_block = last_synced + 1;
        var blocks_indexed: u64 = 0;

        while (from_block <= target_block and !self.should_stop.load(.acquire)) {
            const to_block = @min(from_block + batch_size - 1, target_block);
            const batch_blocks = to_block - from_block + 1;

            // Rate limit RPC calls to avoid hitting provider limits
            self.rate_limiter.acquire();

            // Use transaction for batch atomicity
            try self.database.beginTransaction();
            errdefer self.database.rollbackTransaction();

            try self.indexBlockRange(chain, client, from_block, to_block);

            // Commit transaction FIRST, then update sync state
            try self.database.commitTransaction();

            blocks_indexed += batch_blocks;
            const progress = (@as(f64, @floatFromInt(blocks_indexed)) / @as(f64, @floatFromInt(total_blocks))) * 100.0;
            std.log.info("Progress: {d:.1}% ({d}/{d} blocks) - Batch {d}-{d} indexed", .{ progress, blocks_indexed, total_blocks, from_block, to_block });

            // Store block hashes for reorg detection and update sync state ATOMICALLY
            try self.database.beginTransaction();
            errdefer self.database.rollbackTransaction();

            // Only store block hashes at checkpoint intervals to reduce RPC calls
            // We only need the last block hash for reorg detection
            const block_info = try client.getBlockByNumber(to_block, false);
            try self.database.storeBlockHash(chain, to_block, block_info.hash, block_info.parent_hash);

            // Update sync state
            try self.database.setSyncState(chain, to_block);
            try self.database.commitTransaction();

            // Update status if tracking is enabled
            if (self.indexer_status) |status| {
                status.current_block = to_block;
            }

            self.blocks_since_checkpoint += (to_block - from_block + 1);

            // Periodic checkpoint and memory cleanup
            if (self.blocks_since_checkpoint >= self.config.checkpoint_interval) {
                std.log.info("Checkpoint: synced {s} to block {d}", .{ chain.toString(), to_block });
                self.blocks_since_checkpoint = 0;

                // Prune old block hashes (keep last 1000 blocks)
                try self.database.pruneOldBlockHashes(chain, to_block);

                // Clear block timestamp cache to prevent memory growth
                self.clearBlockTimestampCache();

                // Force a brief pause to allow memory to be reclaimed
                std.Thread.sleep(constants.Timing.rpc_batch_delay_ms * std.time.ns_per_ms);
            }

            from_block = to_block + 1;
        }

        std.log.info("Synced {s} to block {d}", .{ chain.toString(), target_block });
    }

    fn indexBlockRange(self: *Indexer, chain: models.Chain, client: *rpc.Client, from_block: u64, to_block: u64) !void {
        // IMPORTANT: Process events in dependency order:
        // 1. First create names (NameRegistered, NewSubname)
        // 2. Then modify names (SubregistryUpdate, ResolverUpdate, Transfer)
        // 3. Then process data dependent on names existing (resolver records)

        // Block range constants from contract config (chain-specific)
        const l1_contracts = self.config.l1_contracts;
        const temp_registrar_start = l1_contracts.temp_registrar_start_block;

        // === V1 EVENTS (ENS V1 - Mainnet L1 only) ===
        // Only index V1 events if the block range overlaps with V1 deployment period
        // Skip if entire range is before temp registrar start OR if V2 is deployed and range is entirely after V2
        const v2_deployment = if (chain == .l1) l1_contracts.l1_deployment_block else self.config.l2_contracts.l2_deployment_block;
        const should_index_v1 = (temp_registrar_start > 0) and (to_block >= temp_registrar_start) and
                               (v2_deployment == 0 or from_block < v2_deployment + 10);

        if (should_index_v1) {
            // EFFICIENT: Index all V1 events together per chunk (Registry, Name Wrapper, Base Registrar, Reverse Registrar)
            // This processes each chunk ONCE for all contracts, instead of reprocessing chunks per contract
            try self.indexAllV1Events(chain, client, from_block, to_block);
        }

        // === V2 EVENTS (ENS V2 - L1 and L2) ===
        // Only index V2 events if V2 is deployed and the block range includes deployment block or later
        const should_index_v2 = (v2_deployment > 0) and (to_block >= v2_deployment);

        if (should_index_v2) {
            // Index ETH Registry events (batched RPC requests)
            try self.indexEthRegistryEvents(chain, client, from_block, to_block);
            std.Thread.sleep(constants.Timing.rpc_batch_delay_ms * std.time.ns_per_ms); // Rate limit between RPC batches

            // Index ETH Registrar events (batched RPC requests)
            try self.indexETHRegistrarEvents(chain, client, from_block, to_block);
            std.Thread.sleep(constants.Timing.rpc_batch_delay_ms * std.time.ns_per_ms); // Rate limit between RPC batches

            // Get events from RegistryDatastore (SubregistryUpdate, ResolverUpdate)
            // Process BEFORE subregistries so new registries are discovered first
            try self.indexDatastoreEvents(chain, client, from_block, to_block);
            std.Thread.sleep(constants.Timing.rpc_batch_delay_ms * std.time.ns_per_ms); // Rate limit between RPC batches

            // Get events from all subregistries (for subdomain indexing - NewSubname)
            // Process AFTER SubregistryUpdate so we know which registries to query
            try self.indexSubregistryEvents(chain, client, from_block, to_block);
            std.Thread.sleep(constants.Timing.rpc_batch_delay_ms * std.time.ns_per_ms); // Rate limit between RPC batches

            // Get Transfer events (ERC1155)
            try self.indexTransferEvents(chain, client, from_block, to_block);
            std.Thread.sleep(constants.Timing.rpc_batch_delay_ms * std.time.ns_per_ms); // Rate limit between RPC batches

            // Get resolver data events (AddressChanged, ContentHashChanged, TextChanged)
            // Process AFTER names and resolvers are set
            try self.indexResolverEvents(chain, client, from_block, to_block);
            std.Thread.sleep(constants.Timing.rpc_batch_delay_ms * std.time.ns_per_ms); // Rate limit between RPC batches

            // Get migration events
            if (chain == .l1) {
                try self.indexMigrationEvents(client, from_block, to_block);
                std.Thread.sleep(constants.Timing.rpc_batch_delay_ms * std.time.ns_per_ms); // Rate limit between RPC batches
            }

            // Get ejection events
            try self.indexEjectionEvents(chain, client, from_block, to_block);
        }
    }

    fn indexDatastoreEvents(self: *Indexer, chain: models.Chain, client: *rpc.Client, from_block: u64, to_block: u64) !void {
        // SubregistryUpdate/Updated and ResolverUpdate/Updated events are emitted from the Registry contract
        const registry_addr = self.getEthRegistry(chain);

        // Fetch all event types in a single batch - need to handle both old and new event signatures
        // OLD: SubregistryUpdate, ResolverUpdate (pre-deployment)
        // NEW: SubregistryUpdated, ResolverUpdated (current deployment on Sepolia)

        // Topics for each event type
        const topics_subreg_old = [_]?Hash{abi.EventSignatures.subregistry_update_hash};
        const topics_subreg_new = [_]?Hash{abi.EventSignatures.subregistry_updated_hash};
        const topics_resolver_old = [_]?Hash{abi.EventSignatures.resolver_update_hash};
        const topics_resolver_new = [_]?Hash{abi.EventSignatures.resolver_updated_hash};

        // Build batch request for all datastore events (4 calls → 1 batch)
        const batch_requests = [_]rpc.Client.BatchGetLogsRequest{
            .{ .from_block = from_block, .to_block = to_block, .address = registry_addr, .topics = &topics_subreg_old },
            .{ .from_block = from_block, .to_block = to_block, .address = registry_addr, .topics = &topics_subreg_new },
            .{ .from_block = from_block, .to_block = to_block, .address = registry_addr, .topics = &topics_resolver_old },
            .{ .from_block = from_block, .to_block = to_block, .address = registry_addr, .topics = &topics_resolver_new },
        };

        // Fetch all event logs in a single batch request
        const batch_results = try client.getLogsBatch(&batch_requests);
        defer {
            for (batch_results) |logs| {
                for (logs) |*log| {
                    log.deinit(self.allocator);
                }
                self.allocator.free(logs);
            }
            self.allocator.free(batch_results);
        }

        // Process SubregistryUpdate events (OLD signature)
        for (batch_results[0]) |log| {
            try self.handleSubregistryUpdate(chain, log);
        }

        // Process SubregistryUpdated events (NEW signature)
        for (batch_results[1]) |log| {
            try self.handleSubregistryUpdate(chain, log);
        }

        // Process ResolverUpdate events (OLD signature)
        for (batch_results[2]) |log| {
            try self.handleResolverUpdate(chain, log);
        }

        // Process ResolverUpdated events (NEW signature)
        for (batch_results[3]) |log| {
            try self.handleResolverUpdate(chain, log);
        }
    }

    fn indexEthRegistryEvents(self: *Indexer, chain: models.Chain, client: *rpc.Client, from_block: u64, to_block: u64) !void {
        const eth_registry = self.getEthRegistry(chain);

        // Build batch request for all ETH registry events
        var batch_requests: [ETH_REGISTRY_EVENTS.len]rpc.Client.BatchGetLogsRequest = undefined;
        inline for (ETH_REGISTRY_EVENTS, 0..) |event_cfg, i| {
            const topics = [_]?Hash{event_cfg.event_hash};
            batch_requests[i] = .{
                .from_block = from_block,
                .to_block = to_block,
                .address = eth_registry,
                .topics = &topics,
            };
        }

        // Fetch all event logs in a single batch request
        const batch_results = try client.getLogsBatch(&batch_requests);
        defer {
            for (batch_results) |logs| {
                for (logs) |*log| {
                    log.deinit(self.allocator);
                }
                self.allocator.free(logs);
            }
            self.allocator.free(batch_results);
        }

        // Process each event type's logs
        inline for (ETH_REGISTRY_EVENTS, 0..) |event_cfg, i| {
            const logs = batch_results[i];
            std.log.info("    Found {d} {s} event{s}", .{
                logs.len,
                event_cfg.name,
                if (logs.len == 1) "" else "s",
            });

            for (logs) |log| {
                try event_cfg.handler(self, chain, log);
            }
        }
    }

    fn indexETHRegistrarEvents(self: *Indexer, chain: models.Chain, client: *rpc.Client, from_block: u64, to_block: u64) !void {
        // Only index L2 ETH Registrar events (L1 doesn't have the registrar)
        if (chain != .l2) return;

        const eth_registrar = self.config.l2_contracts.l2_eth_registrar;

        // Build batch request for all ETH registrar events
        var batch_requests: [ETH_REGISTRAR_EVENTS.len]rpc.Client.BatchGetLogsRequest = undefined;
        inline for (ETH_REGISTRAR_EVENTS, 0..) |event_cfg, i| {
            const topics = [_]?Hash{event_cfg.event_hash};
            batch_requests[i] = .{
                .from_block = from_block,
                .to_block = to_block,
                .address = eth_registrar,
                .topics = &topics,
            };
        }

        // Fetch all event logs in a single batch request
        const batch_results = try client.getLogsBatch(&batch_requests);
        defer {
            for (batch_results) |logs| {
                for (logs) |*log| {
                    log.deinit(self.allocator);
                }
                self.allocator.free(logs);
            }
            self.allocator.free(batch_results);
        }

        // Process each event type's logs
        inline for (ETH_REGISTRAR_EVENTS, 0..) |event_cfg, i| {
            const logs = batch_results[i];
            std.log.info("    Found {d} {s} event{s}", .{
                logs.len,
                event_cfg.name,
                if (logs.len == 1) "" else "s",
            });

            for (logs) |log| {
                try event_cfg.handler(self, chain, log);
            }
        }
    }

    fn indexSubregistryEvents(self: *Indexer, chain: models.Chain, client: *rpc.Client, from_block: u64, to_block: u64) !void {
        // Get the main registry address to exclude it
        const main_registry_addr = self.getEthRegistry(chain);
        const main_registry_hex = try main_registry_addr.toHex(self.allocator);
        defer self.allocator.free(main_registry_hex);

        // Get subregistries to index (uses cache table for performance)
        const subregistries = try self.database.getSubregistriesToIndex(chain, main_registry_hex, from_block, to_block);
        defer {
            for (subregistries) |subreg| {
                self.allocator.free(subreg);
            }
            self.allocator.free(subregistries);
        }

        if (subregistries.len == 0) {
            std.log.debug("No subregistries found for {s}", .{chain.toString()});
            return;
        }

        std.log.info("Indexing {d} subregistr{s} for {s} from blocks {d}-{d}", .{
            subregistries.len,
            if (subregistries.len == 1) "y" else "ies",
            chain.toString(),
            from_block,
            to_block,
        });

        // RPC provider address limit per eth_getLogs call (conservative estimate)
        const SUBREGISTRIES_PER_CALL = constants.RpcBatching.addresses_per_call;

        // Build event topic array for OR matching (all 8 subregistry event types)
        var event_topics: [SUBREGISTRY_EVENTS.len]Hash = undefined;
        inline for (SUBREGISTRY_EVENTS, 0..) |event_cfg, i| {
            event_topics[i] = event_cfg.event_hash;
        }

        // Process subregistries in chunks based on address limit
        var chunk_start: usize = 0;
        var chunk_num: usize = 1;
        const total_chunks = (subregistries.len + SUBREGISTRIES_PER_CALL - 1) / SUBREGISTRIES_PER_CALL;

        while (chunk_start < subregistries.len) {
            const chunk_end = @min(chunk_start + SUBREGISTRIES_PER_CALL, subregistries.len);
            const chunk_size = chunk_end - chunk_start;

            std.log.info("Processing subregistry batch {d}/{d} ({d} subregistries, 1 RPC call)...", .{
                chunk_num,
                total_chunks,
                chunk_size,
            });

            // Convert subregistry hex strings to Address objects for this chunk
            var subreg_addrs = try self.allocator.alloc(Address, chunk_size);
            defer self.allocator.free(subreg_addrs);

            for (subregistries[chunk_start..chunk_end], 0..) |subreg_hex, i| {
                subreg_addrs[i] = try Address.fromHex(subreg_hex);
            }

            // Single RPC call for all subregistries in this chunk and all event types
            const logs = try client.getLogsMultiAddress(.{
                .from_block = from_block,
                .to_block = to_block,
                .addresses = subreg_addrs,
                .topic0_or = &event_topics,
            });
            defer {
                for (logs) |*log| {
                    log.deinit(self.allocator);
                }
                self.allocator.free(logs);
            }

            std.log.info("  Fetched {d} total events from {d} subregistries", .{ logs.len, chunk_size });

            // Process logs by matching topic[0] to event handler
            for (logs) |log| {
                if (log.topics.len == 0) continue;

                const event_sig = log.topics[0];

                // Find matching handler by comparing event signature
                inline for (SUBREGISTRY_EVENTS) |event_cfg| {
                    if (event_sig.eql(event_cfg.event_hash)) {
                        try event_cfg.handler(self, chain, log);
                        break;
                    }
                }
            }

            // Update last_indexed_block for all subregistries in this chunk
            for (subregistries[chunk_start..chunk_end]) |subreg_hex| {
                try self.database.registerSubregistry(chain, subreg_hex, to_block);
            }

            std.log.info("Batch {d} complete: processed {d} subregistries", .{ chunk_num, chunk_size });

            chunk_start = chunk_end;
            chunk_num += 1;

            // Rate limit: wait between batches to avoid hitting RPC provider limits
            if (chunk_start < subregistries.len) {
                std.Thread.sleep(300 * std.time.ns_per_ms); // 300ms delay between batches
            }
        }

        std.log.info("Subregistry indexing complete: {d} subregistries processed", .{subregistries.len});
    }

    fn indexTransferEvents(self: *Indexer, chain: models.Chain, client: *rpc.Client, from_block: u64, to_block: u64) !void {
        // We need to track transfers from all registries, but for now we'll focus on the .eth registry
        const eth_registry = self.getEthRegistry(chain);

        // Topics for each event type
        const topics_transfer_single = [_]?Hash{abi.EventSignatures.transfer_single_hash};
        const topics_transfer_batch = [_]?Hash{abi.EventSignatures.transfer_batch_hash};
        const topics_approval = [_]?Hash{abi.EventSignatures.approval_hash};

        // Build batch request for all transfer events (3 calls → 1 batch)
        const batch_requests = [_]rpc.Client.BatchGetLogsRequest{
            .{ .from_block = from_block, .to_block = to_block, .address = eth_registry, .topics = &topics_transfer_single },
            .{ .from_block = from_block, .to_block = to_block, .address = eth_registry, .topics = &topics_transfer_batch },
            .{ .from_block = from_block, .to_block = to_block, .address = eth_registry, .topics = &topics_approval },
        };

        // Fetch all event logs in a single batch request
        const batch_results = try client.getLogsBatch(&batch_requests);
        defer {
            for (batch_results) |logs| {
                for (logs) |*log| {
                    log.deinit(self.allocator);
                }
                self.allocator.free(logs);
            }
            self.allocator.free(batch_results);
        }

        // Process TransferSingle events
        for (batch_results[0]) |log| {
            try self.handleTransfer(chain, log);
        }

        // Process TransferBatch events
        for (batch_results[1]) |log| {
            try self.handleTransferBatch(chain, log);
        }

        // Process Approval events
        for (batch_results[2]) |log| {
            try self.handleApproval(chain, log);
        }
    }

    fn indexMigrationEvents(_: *Indexer, _: *rpc.Client, _: u64, _: u64) !void {
        // Migration events from L1 migration contract
        // This would track ENSv1 -> ENSv2 migrations
        // TODO: Implement when migration event signatures are defined
    }

    fn indexEjectionEvents(self: *Indexer, chain: models.Chain, client: *rpc.Client, from_block: u64, to_block: u64) !void {
        // Get the appropriate bridge controller contract address
        const bridge_addr = self.getBridgeController(chain);
        const registry_addr = self.getEthRegistry(chain);

        // Skip bridge events if bridge contract is not configured (zero address)
        if (!bridge_addr.isZero()) {
            // Topics for bridge events
            const topics_ejected_l1 = [_]?Hash{abi.EventSignatures.name_ejected_to_l1_hash};
            const topics_ejected_l2 = [_]?Hash{abi.EventSignatures.name_ejected_to_l2_hash};
            const topics_renewal_sync = [_]?Hash{abi.EventSignatures.renewal_synchronized_hash};

            // Build batch request for bridge events (2-3 calls → 1 batch depending on chain)
            if (chain == .l1) {
                // L1: Include RenewalSynchronized
                const batch_requests = [_]rpc.Client.BatchGetLogsRequest{
                    .{ .from_block = from_block, .to_block = to_block, .address = bridge_addr, .topics = &topics_ejected_l1 },
                    .{ .from_block = from_block, .to_block = to_block, .address = bridge_addr, .topics = &topics_ejected_l2 },
                    .{ .from_block = from_block, .to_block = to_block, .address = bridge_addr, .topics = &topics_renewal_sync },
                };

                const batch_results = try client.getLogsBatch(&batch_requests);
                defer {
                    for (batch_results) |logs| {
                        for (logs) |*log| {
                            log.deinit(self.allocator);
                        }
                        self.allocator.free(logs);
                    }
                    self.allocator.free(batch_results);
                }

                // Process NameEjectedToL1 events
                std.log.info("Found {d} NameEjectedToL1 event{s} from {s}", .{
                    batch_results[0].len,
                    if (batch_results[0].len == 1) "" else "s",
                    chain.toString(),
                });
                for (batch_results[0]) |log| {
                    try self.handleNameEjectedToL1(chain, log);
                }

                // Process NameEjectedToL2 events
                std.log.info("Found {d} NameEjectedToL2 event{s} from {s}", .{
                    batch_results[1].len,
                    if (batch_results[1].len == 1) "" else "s",
                    chain.toString(),
                });
                for (batch_results[1]) |log| {
                    try self.handleNameEjectedToL2(chain, log);
                }

                // Process RenewalSynchronized events
                std.log.info("Found {d} RenewalSynchronized event{s}", .{
                    batch_results[2].len,
                    if (batch_results[2].len == 1) "" else "s",
                });
                for (batch_results[2]) |log| {
                    try self.handleRenewalSynchronized(chain, log);
                }
            } else {
                // L2: No RenewalSynchronized
                const batch_requests = [_]rpc.Client.BatchGetLogsRequest{
                    .{ .from_block = from_block, .to_block = to_block, .address = bridge_addr, .topics = &topics_ejected_l1 },
                    .{ .from_block = from_block, .to_block = to_block, .address = bridge_addr, .topics = &topics_ejected_l2 },
                };

                const batch_results = try client.getLogsBatch(&batch_requests);
                defer {
                    for (batch_results) |logs| {
                        for (logs) |*log| {
                            log.deinit(self.allocator);
                        }
                        self.allocator.free(logs);
                    }
                    self.allocator.free(batch_results);
                }

                // Process NameEjectedToL1 events
                std.log.info("Found {d} NameEjectedToL1 event{s} from {s}", .{
                    batch_results[0].len,
                    if (batch_results[0].len == 1) "" else "s",
                    chain.toString(),
                });
                for (batch_results[0]) |log| {
                    try self.handleNameEjectedToL1(chain, log);
                }

                // Process NameEjectedToL2 events
                std.log.info("Found {d} NameEjectedToL2 event{s} from {s}", .{
                    batch_results[1].len,
                    if (batch_results[1].len == 1) "" else "s",
                    chain.toString(),
                });
                for (batch_results[1]) |log| {
                    try self.handleNameEjectedToL2(chain, log);
                }
            }
        }

        // TokenObserverSet events (from registry contract - separate batch)
        {
            const topics = [_]?Hash{abi.EventSignatures.token_observer_set_hash};
            const logs = try client.getLogs(from_block, to_block, registry_addr, &topics);
            defer {
                for (logs) |*log| {
                    log.deinit(self.allocator);
                }
                self.allocator.free(logs);
            }

            std.log.info("Found {d} TokenObserverSet event{s} from {s}", .{
                logs.len,
                if (logs.len == 1) "" else "s",
                chain.toString(),
            });

            for (logs) |log| {
                try self.handleTokenObserverSet(chain, log);
            }
        }
    }

    fn handleSubregistryUpdate(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        // Event: SubregistryUpdate(uint256 indexed id, address subregistry)
        // Note: The 'id' in SubregistryUpdate is the canonical_id (version=0), not the full token_id
        if (log.topics.len < 2) return error.InvalidTopicCount;

        // topics[0] = event signature
        // topics[1] = indexed id (canonical ID - note: this is NOT the full token_id)
        // SubregistryUpdate event uses tokenId in topics[1], which may include version bits
        const token_id = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
        // Extract canonical_id (upper bits without version) for consistent lookups
        const token_id_utils = @import("../types/token_id.zig");
        const canonical_id = token_id_utils.getCanonicalId(token_id);

        // data = subregistry address
        const subregistry_addr = try abi.ABI.decodeAddress(log.data, 0);

        std.log.debug("SubregistryUpdate: tokenId={d}, canonicalId={d}, subregistry={any}, contract={any}", .{ token_id, canonical_id, subregistry_addr, log.address });

        // Skip if subregistry is zero address (unsetting subregistry)
        if (subregistry_addr.isZero()) {
            std.log.info("  → Skipping zero address subregistry", .{});
            return;
        }

        // Look up the name by canonical ID (token_id with version bits cleared)
        const maybe_name = try self.database.getNameByCanonicalId(canonical_id);
        const name_str = if (maybe_name) |n| blk: {
            var name_copy = n;
            defer name_copy.deinit(self.allocator);
            break :blk try self.allocator.dupe(u8, name_copy.name orelse "[unknown]");
        } else try std.fmt.allocPrint(self.allocator, "canonicalId:{d}", .{canonical_id});
        defer self.allocator.free(name_str);

        const namehash = if (maybe_name) |n| n.namehash else Hash.zero;

        // Insert the subregistry into the registries table so it will be monitored
        const registry = models.Registry{
            .address = subregistry_addr,
            .chain = chain,
            .name = name_str,
            .namehash = namehash,
            .parent_registry = log.address, // The contract that emitted this event
            .created_block = log.block_number,
            .created_at = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.database.insertRegistry(registry);
        std.log.debug("  → Registered subregistry for monitoring: {any}", .{subregistry_addr});

        // Update the parent name's registry field if we found the name
        if (maybe_name != null and !namehash.isZero()) {
            try self.database.updateNameSubregistry(namehash, subregistry_addr);
            std.log.debug("  → Updated name registry field", .{});
        }

        // Store event
        const subreg_hex = try subregistry_addr.toHex(self.allocator);
        defer self.allocator.free(subreg_hex);
        const contract_hex = try log.address.toHex(self.allocator);
        defer self.allocator.free(contract_hex);

        // Escape name_str for safe JSON inclusion
        const escaped_name = try json_utils.escapeString(self.allocator, name_str);
        defer self.allocator.free(escaped_name);

        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"name\":\"{s}\",\"canonicalId\":{d},\"subregistry\":\"{s}\",\"registry\":\"{s}\"}}", .{
            escaped_name,
            canonical_id,
            subreg_hex,
            contract_hex,
        });

        const event_name = try self.allocator.dupe(u8, name_str);

        const event = models.Event{
            .event_type = .subregistry_update,
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = event_name,
            .namehash = namehash,
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);
    }

    fn handleResolverUpdate(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        // Event: ResolverUpdate(uint256 indexed id, address resolver)
        // Note: The 'id' in ResolverUpdate is the canonical_id (version=0), not the full token_id
        if (log.topics.len < 2) return error.InvalidTopicCount;

        // topics[0] = event signature
        // topics[1] = indexed id (canonical ID - note: this is NOT the full token_id)
        const canonical_id = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);

        // data = resolver address
        const resolver_addr = try abi.ABI.decodeAddress(log.data, 0);

        std.log.debug("ResolverUpdate: canonicalId={d}, resolver={any}, contract={any}", .{ canonical_id, resolver_addr, log.address });

        // Look up the name by canonical ID (not token_id, since events use canonical_id)
        const maybe_name = try self.database.getNameByCanonicalId(canonical_id);

        // Skip if name doesn't exist yet (might be out of order event processing)
        if (maybe_name == null) {
            std.log.warn("  → Skipping ResolverUpdate for unknown canonicalId={d}", .{canonical_id});
            return;
        }

        // Extract and allocate name_str and copy namehash before any cleanup
        const name_str = try self.allocator.dupe(u8, maybe_name.?.name orelse "[unknown]");
        defer self.allocator.free(name_str);
        const namehash = maybe_name.?.namehash;

        // Clean up the name struct
        var name_copy = maybe_name.?;
        name_copy.deinit(self.allocator);

        // Update resolver in database
        try self.database.updateNameResolver(namehash, resolver_addr);

        // Register resolver for record indexing (if not zero address)
        if (!resolver_addr.isZero()) {
            const resolver_hex = try resolver_addr.toHex(self.allocator);
            defer self.allocator.free(resolver_hex);
            try self.database.registerResolver(chain, resolver_hex, log.block_number);
        }

        // Store event
        const resolver_hex = try resolver_addr.toHex(self.allocator);
        defer self.allocator.free(resolver_hex);
        const contract_hex = try log.address.toHex(self.allocator);
        defer self.allocator.free(contract_hex);

        // Escape name_str for safe JSON inclusion
        const escaped_name = try json_utils.escapeString(self.allocator, name_str);
        defer self.allocator.free(escaped_name);

        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"name\":\"{s}\",\"canonicalId\":{d},\"resolver\":\"{s}\",\"registry\":\"{s}\"}}", .{
            escaped_name,
            canonical_id,
            resolver_hex,
            contract_hex,
        });

        const event_name = try self.allocator.dupe(u8, name_str);

        const event = models.Event{
            .event_type = .resolver_update,
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = event_name,
            .namehash = namehash,
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);
    }

    fn handleNameRegistered(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        // V2 Event: NameRegistered(uint256 indexed tokenId, string label, uint64 expiration, address registeredBy)
        if (log.topics.len < 2) return error.InvalidTopicCount;

        // Topics[0] = event signature
        // Topics[1] = indexed tokenId
        const token_id_raw = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
        const token_id: u256 = token_id_raw;

        // Data contains: string label, uint64 expiration, address registeredBy
        // String is at offset 0 (as offset pointer)
        // We need to decode the dynamic data
        const label_str = try abi.ABI.decodeString(self.allocator, log.data, 0);
        defer self.allocator.free(label_str);

        // Validate label is valid UTF-8 and contains no control characters
        unicode.validateName(label_str) catch |err| {
            std.log.warn("Invalid name label for tokenId={d}: {any}", .{ token_id, err });
            return;
        };

        // After the string offset (32 bytes) comes uint64 expiration (padded to 32 bytes)
        // and then address registeredBy (padded to 32 bytes)
        // But since string is dynamic, we need to skip to after the actual string data
        // For simplicity, let's decode from the known structure

        // In ABI encoding: [offset_to_string, expiration, registeredBy, string_length, string_data]
        // offset_to_string is at 0x00, expiration at 0x20, registeredBy at 0x40
        const expiration = try abi.ABI.decodeUint256(log.data, 32);  // uint64 but padded to uint256
        const registered_by = try abi.ABI.decodeAddress(log.data, 64);

        std.log.debug("NameRegistered: {s} (tokenId={d}, expiration={d}, registeredBy={any})", .{
            label_str, token_id, expiration, registered_by
        });

        // Determine parent name based on registry address
        // If from main .eth registry, parent is "eth". Otherwise look up subregistry parent.
        const eth_registry = self.getEthRegistry(chain);
        const is_main_registry = log.address.eql(eth_registry);

        var parent_name: []const u8 = "eth";
        var parent_name_allocated = false;
        var parent_namehash: Hash = try @import("../types/hash.zig").namehash(self.allocator, "eth");

        if (!is_main_registry) {
            // This is a subregistry - look up the parent name from registries table
            const registry_hex = try log.address.toHex(self.allocator);
            defer self.allocator.free(registry_hex);

            const registry_query = "SELECT name, namehash FROM registries WHERE address = ? AND chain = ?";
            const registry_query_z = try self.allocator.dupeZ(u8, registry_query);
            defer self.allocator.free(registry_query_z);

            var reg_stmt: ?*c.sqlite3_stmt = null;
            _ = c.sqlite3_prepare_v2(self.database.db, registry_query_z.ptr, -1, &reg_stmt, null);
            defer _ = c.sqlite3_finalize(reg_stmt);

            const chain_str = chain.toString();
            _ = c.sqlite3_bind_text(reg_stmt, 1, registry_hex.ptr, @intCast(registry_hex.len), SQLITE_TRANSIENT());
            _ = c.sqlite3_bind_text(reg_stmt, 2, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());

            if (c.sqlite3_step(reg_stmt) == c.SQLITE_ROW) {
                const name_ptr = c.sqlite3_column_text(reg_stmt, 0);
                if (name_ptr != null) {
                    const name_span = std.mem.span(name_ptr);
                    parent_name = try self.allocator.dupe(u8, name_span);
                    parent_name_allocated = true;
                }

                const namehash_ptr = c.sqlite3_column_text(reg_stmt, 1);
                if (namehash_ptr != null) {
                    const namehash_hex = std.mem.span(namehash_ptr);
                    parent_namehash = try Hash.fromHex(namehash_hex);
                }
            }
        }
        defer if (parent_name_allocated) self.allocator.free(parent_name);

        // Compute full name: label.parent_name
        const full_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ label_str, parent_name });
        defer self.allocator.free(full_name);
        const namehash = try @import("../types/hash.zig").namehash(self.allocator, full_name);

        // Compute label hash
        const label_hash = try @import("../types/hash.zig").keccak256(self.allocator, label_str);

        // Extract canonical_id and version from token_id
        const token_id_utils = @import("../types/token_id.zig");
        const canonical_id = token_id_utils.getCanonicalId(token_id);
        const token_version = token_id_utils.getTokenVersion(token_id);

        const name_str_dup = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ label_str, parent_name });
        errdefer self.allocator.free(name_str_dup);

        const label_dup = try self.allocator.dupe(u8, label_str);
        errdefer self.allocator.free(label_dup);

        const parent_name_dup = try self.allocator.dupe(u8, parent_name);
        errdefer self.allocator.free(parent_name_dup);

        const name = models.Name{
            .name = name_str_dup,
            .namehash = namehash,
            .label = label_dup,
            .label_hash = label_hash,
            .parent_name = parent_name_dup,
            .parent_namehash = parent_namehash,
            .chain = chain,
            .registry = log.address, // Use the actual registry that emitted the event
            .owner = registered_by,
            .registrant = registered_by, // Original registrant from NameRegistered event
            .resolver = Address.zero,
            .token_id = @intCast(token_id),
            .canonical_id = canonical_id,
            .token_version = token_version,
            .expiry = @truncate(expiration),
            .registry_locked = false,
            .migrated = false,
            .ejected = false,
            .created_block = log.block_number,
            .created_at = self.getBlockTimestamp(chain, log.block_number),
            .updated_block = log.block_number,
            .updated_at = std.time.timestamp(),
            .is_wrapped = false,
            .wrapper_fuses = null,
            .wrapper_expiry = null,
            .is_v1_name = false,
            .v1_label_hash = null,
        };

        self.database.insertName(name) catch |err| {
            if (name.name) |n| self.allocator.free(n);
            if (name.label) |l| self.allocator.free(l);
            if (name.parent_name) |p| self.allocator.free(p);
            return err;
        };

        // After inserting name, check if there are placeholder registries that need updating
        // This happens when SubregistryUpdate was processed before NameRegistered in the same block
        // The SubregistryUpdate creates a registry with name "canonicalId:{d}" as a placeholder
        const placeholder_pattern = try std.fmt.allocPrint(self.allocator, "canonicalId:{d}", .{canonical_id});
        defer self.allocator.free(placeholder_pattern);
        _ = self.database.updateRegistryPlaceholderName(placeholder_pattern, full_name, namehash) catch |err| {
            std.log.warn("Failed to update placeholder registry: {}", .{err});
        };

        // Store event
        const nh_hex = try namehash.toHex(self.allocator);
        defer self.allocator.free(nh_hex);
        const owner_hex = try registered_by.toHex(self.allocator);
        defer self.allocator.free(owner_hex);

        // Escape label_str for safe JSON inclusion
        const escaped_label = try json_utils.escapeString(self.allocator, label_str);
        defer self.allocator.free(escaped_label);

        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"label\":\"{s}\",\"tokenId\":{d},\"namehash\":\"{s}\",\"owner\":\"{s}\",\"expiration\":{d}}}", .{
            escaped_label,
            token_id,
            nh_hex,
            owner_hex,
            expiration,
        });

        const event_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ label_str, parent_name });

        const event = models.Event{
            .event_type = .name_registered,
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = event_name,
            .namehash = namehash,
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);
    }

    // SQLITE_TRANSIENT - For Zig 0.15.1, we can't use the C constant due to alignment issues
    // Instead, we use null which tells SQLite to make a copy of the string
    inline fn SQLITE_TRANSIENT() c.sqlite3_destructor_type {
        return null;
    }

    fn handleNewSubname(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        // NewSubname event: NewSubname(uint256 indexed tokenId, string label)
        // This event is emitted by UserRegistry contracts instead of NameRegistered
        if (log.topics.len < 2) return error.InvalidTopicCount;

        // Topics[0] = event signature
        // Topics[1] = indexed tokenId
        const token_id_raw = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
        const token_id: u256 = token_id_raw;

        // Data contains: string label
        const label_str = try abi.ABI.decodeString(self.allocator, log.data, 0);
        defer self.allocator.free(label_str);

        // Validate label is valid UTF-8 and contains no control characters
        unicode.validateName(label_str) catch |err| {
            std.log.warn("Invalid subname label for tokenId={d}: {any}", .{ token_id, err });
            return;
        };

        std.log.debug("NewSubname: {s} (tokenId={d}, registry={any})", .{
            label_str,
            token_id,
            log.address,
        });

        // Get the parent name from the registry that emitted this event
        // The registry is stored in the registries table
        const registry_hex = try log.address.toHex(self.allocator);
        defer self.allocator.free(registry_hex);

        // Query the registries table to find the parent name
        const registry_query = "SELECT name, namehash FROM registries WHERE address = ? AND chain = ?";
        const registry_query_z = try self.allocator.dupeZ(u8, registry_query);
        defer self.allocator.free(registry_query_z);

        var stmt: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(self.database.db, registry_query_z.ptr, -1, &stmt, null);
        defer _ = c.sqlite3_finalize(stmt);

        const chain_str = chain.toString();
        _ = c.sqlite3_bind_text(stmt, 1, registry_hex.ptr, @intCast(registry_hex.len), SQLITE_TRANSIENT());
        _ = c.sqlite3_bind_text(stmt, 2, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());

        var parent_name: ?[]const u8 = null;
        var parent_namehash: Hash = Hash.zero;

        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const name_ptr = c.sqlite3_column_text(stmt, 0);
            if (name_ptr != null) {
                const name_span = std.mem.span(name_ptr);
                parent_name = try self.allocator.dupe(u8, name_span);
            }

            const namehash_ptr = c.sqlite3_column_text(stmt, 1);
            if (namehash_ptr != null) {
                const namehash_hex = std.mem.span(namehash_ptr);
                parent_namehash = try Hash.fromHex(namehash_hex);
            }
        }

        if (parent_name == null) {
            std.log.warn("  → Could not find parent name for registry {s}, skipping subname", .{registry_hex});
            return;
        }
        defer self.allocator.free(parent_name.?);

        // Construct full subname: label.parent_name
        const full_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ label_str, parent_name.? });
        defer self.allocator.free(full_name);

        // Compute namehash for the full subname
        const namehash = try @import("../types/hash.zig").namehash(self.allocator, full_name);

        // Compute label hash
        const label_hash = try @import("../types/hash.zig").keccak256(self.allocator, label_str);

        // Extract canonical_id and version from token_id
        const token_id_utils = @import("../types/token_id.zig");
        const canonical_id = token_id_utils.getCanonicalId(token_id);
        const token_version = token_id_utils.getTokenVersion(token_id);

        // NewSubname doesn't include owner or expiration, so we need to get them from TransferSingle event
        // or query the datastore. For now, we'll use zero values and they'll be updated by Transfer events
        const name_str = try self.allocator.dupe(u8, full_name);
        errdefer self.allocator.free(name_str);

        const label_dup = try self.allocator.dupe(u8, label_str);
        errdefer self.allocator.free(label_dup);

        const parent_name_dup = try self.allocator.dupe(u8, parent_name.?);
        errdefer self.allocator.free(parent_name_dup);

        const name = models.Name{
            .name = name_str,
            .namehash = namehash,
            .label = label_dup,
            .label_hash = label_hash,
            .parent_name = parent_name_dup,
            .parent_namehash = parent_namehash,
            .chain = chain,
            .registry = log.address,
            .owner = Address.zero, // Will be updated by Transfer event
            .registrant = Address.zero, // Subnames don't have a registrant in the same sense
            .resolver = Address.zero,
            .token_id = @intCast(token_id),
            .canonical_id = canonical_id,
            .token_version = token_version,
            .expiry = 0, // Subnames may not have expiration
            .registry_locked = false,
            .migrated = false,
            .ejected = false,
            .created_block = log.block_number,
            .created_at = self.getBlockTimestamp(chain, log.block_number),
            .updated_block = log.block_number,
            .updated_at = std.time.timestamp(),
            .is_wrapped = false,
            .wrapper_fuses = null,
            .wrapper_expiry = null,
            .is_v1_name = false,
            .v1_label_hash = null,
        };

        self.database.insertName(name) catch |err| {
            // Clean up name allocations on error
            if (name.name) |n| self.allocator.free(n);
            if (name.label) |l| self.allocator.free(l);
            if (name.parent_name) |p| self.allocator.free(p);
            return err;
        };

        // Store event
        const nh_hex = try namehash.toHex(self.allocator);
        defer self.allocator.free(nh_hex);

        // Escape label_str for safe JSON inclusion
        const escaped_label = try json_utils.escapeString(self.allocator, label_str);
        defer self.allocator.free(escaped_label);

        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"label\":\"{s}\",\"tokenId\":{d},\"namehash\":\"{s}\",\"parent\":\"{s}\"}}", .{
            escaped_label,
            token_id,
            nh_hex,
            parent_name.?,
        });

        const event_name = try self.allocator.dupe(u8, full_name);

        const event = models.Event{
            .event_type = .new_subname,
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = event_name,
            .namehash = namehash,
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);
    }

    fn handleNameRenewed(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        // V2 Event: NameRenewed(uint256 indexed tokenId, uint64 newExpiration, address renewedBy)
        if (log.topics.len < 2) return error.InvalidTopicCount;

        // Topics[0] = event signature
        // Topics[1] = indexed tokenId
        const token_id_raw = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
        const token_id: u256 = token_id_raw;

        // Data contains: uint64 newExpiration, address renewedBy (both padded to 32 bytes)
        const new_expiration = try abi.ABI.decodeUint256(log.data, 0);  // uint64 but padded
        const renewed_by = try abi.ABI.decodeAddress(log.data, 32);

        std.log.debug("NameRenewed: tokenId={d}, newExpiration={d}, renewedBy={any}", .{
            token_id, new_expiration, renewed_by
        });

        // Look up the name by token_id to get the namehash
        // For now, we'll update by token_id
        try self.database.updateNameExpiryByTokenId(@intCast(token_id), @intCast(new_expiration));

        // Store event - we need to look up the name/namehash for the event
        // For simplicity, we'll just store the token_id
        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"tokenId\":{d},\"newExpiration\":{d}}}", .{
            token_id,
            new_expiration,
        });

        // Try to get the name from database
        const maybe_name = try self.database.getNameByTokenId(token_id);
        const name_str = if (maybe_name) |n| blk: {
            var name_copy = n;
            defer name_copy.deinit(self.allocator);
            break :blk try self.allocator.dupe(u8, name_copy.name orelse "[unknown]");
        } else try std.fmt.allocPrint(self.allocator, "tokenId:{d}", .{token_id});
        defer self.allocator.free(name_str);

        const namehash = if (maybe_name) |n| n.namehash else Hash.zero;

        const event_name = try self.allocator.dupe(u8, name_str);

        const event = models.Event{
            .event_type = .name_renewed,
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = event_name,
            .namehash = namehash,
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);
    }

    fn handleTransfer(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        // Event: TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value)
        if (log.topics.len < 4) return error.InvalidTopicCount;

        const operator = try abi.ABI.decodeAddress(&log.topics[1].bytes, 0);
        const from = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);
        const to = try abi.ABI.decodeAddress(&log.topics[3].bytes, 0);

        const id = try abi.ABI.decodeUint256(log.data, 0);
        const value = try abi.ABI.decodeUint256(log.data, 32);

        std.log.debug("Transfer: from={any}, to={any}, id={d}, value={d}", .{ from, to, id, value });

        // Update name owner in database
        // Look up the name by token ID to get the namehash
        const maybe_name = try self.database.getNameByTokenId(id);
        var namehash_opt: ?Hash = null;
        var name_str_opt: ?[]const u8 = null;

        if (maybe_name) |name| {
            name_str_opt = try self.allocator.dupe(u8, name.name orelse "[unknown]");
            namehash_opt = name.namehash;

            // Clean up the name struct
            var name_copy = name;
            name_copy.deinit(self.allocator);

            // Update owner
            try self.database.updateNameOwner(namehash_opt.?, to);
        } else {
            std.log.debug("  → Skipping Transfer for unknown tokenId={d}", .{id});
        }

        defer if (name_str_opt) |n| self.allocator.free(n);

        // Store event
        const operator_hex = try operator.toHex(self.allocator);
        defer self.allocator.free(operator_hex);
        const from_hex = try from.toHex(self.allocator);
        defer self.allocator.free(from_hex);
        const to_hex = try to.toHex(self.allocator);
        defer self.allocator.free(to_hex);

        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"operator\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"id\":{d},\"value\":{d}}}", .{
            operator_hex,
            from_hex,
            to_hex,
            id,
            value,
        });

        const event_name = if (name_str_opt) |n| try self.allocator.dupe(u8, n) else null;

        const event = models.Event{
            .event_type = .transfer,
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = event_name,
            .namehash = namehash_opt,
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);
    }

    // =============================================================================
    // ETH Registrar Extended Event Handlers (L2 specific)
    // =============================================================================

    fn handleETHNameRegistered(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        // IETHRegistrar.NameRegistered(uint256 indexed tokenId, string label, address owner, IRegistry subregistry, address resolver, uint64 duration, IERC20 paymentToken, bytes32 referrer, uint256 base, uint256 premium)
        if (log.topics.len < 2) return error.InvalidTopicCount;

        const token_id_raw = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
        const token_id: u256 = token_id_raw;

        // Data: [offset_to_label, owner, subregistry, resolver, duration, paymentToken, referrer, base, premium, label_length, label_data]
        const label_str = try abi.ABI.decodeString(self.allocator, log.data, 0);
        defer self.allocator.free(label_str);

        // Validate label is valid UTF-8 and contains no control characters
        unicode.validateName(label_str) catch |err| {
            std.log.warn("Invalid name label for tokenId={d}: {any}", .{ token_id, err });
            return;
        };

        const owner = try abi.ABI.decodeAddress(log.data, 32);
        const subregistry = try abi.ABI.decodeAddress(log.data, 64);
        const resolver = try abi.ABI.decodeAddress(log.data, 96);
        const duration = try abi.ABI.decodeUint256(log.data, 128);  // uint64 padded
        const payment_token = try abi.ABI.decodeAddress(log.data, 160);
        const referrer = try abi.ABI.decodeBytes32(log.data, 192);
        const base_price = try abi.ABI.decodeUint256(log.data, 224);
        const premium = try abi.ABI.decodeUint256(log.data, 256);

        std.log.debug("ETHRegistrar.NameRegistered: {s} (tokenId={d}, owner={any}, duration={d}, base={d}, premium={d})", .{
            label_str, token_id, owner, duration, base_price, premium
        });

        // Compute namehash
        const full_name = try std.fmt.allocPrint(self.allocator, "{s}.eth", .{label_str});
        defer self.allocator.free(full_name);
        const namehash = try @import("../types/hash.zig").namehash(self.allocator, full_name);
        const label_hash = try @import("../types/hash.zig").keccak256(self.allocator, label_str);

        // Calculate expiry from registration block timestamp + duration
        const block_timestamp = self.getBlockTimestamp(chain, log.block_number);
        const expiry: u64 = @intCast(block_timestamp + @as(i64, @intCast(duration)));

        // Extract canonical_id and version from token_id
        const token_id_utils = @import("../types/token_id.zig");
        const canonical_id = token_id_utils.getCanonicalId(token_id);
        const token_version = token_id_utils.getTokenVersion(token_id);

        const name_str_dup = try std.fmt.allocPrint(self.allocator, "{s}.eth", .{label_str});
        errdefer self.allocator.free(name_str_dup);

        const label_dup = try self.allocator.dupe(u8, label_str);
        errdefer self.allocator.free(label_dup);

        const parent_name_dup = try self.allocator.dupe(u8, "eth");
        errdefer self.allocator.free(parent_name_dup);

        const name = models.Name{
            .name = name_str_dup,
            .namehash = namehash,
            .label = label_dup,
            .label_hash = label_hash,
            .parent_name = parent_name_dup,
            .parent_namehash = try @import("../types/hash.zig").namehash(self.allocator, "eth"),
            .chain = chain,
            .registry = self.getEthRegistry(chain),
            .owner = owner,
            .registrant = owner, // Original registrant from ETH Registrar
            .resolver = resolver,
            .token_id = @intCast(token_id),
            .canonical_id = canonical_id,
            .token_version = token_version,
            .expiry = expiry,
            .registry_locked = false,
            .migrated = false,
            .ejected = false,
            .created_block = log.block_number,
            .created_at = self.getBlockTimestamp(chain, log.block_number),
            .updated_block = log.block_number,
            .updated_at = std.time.timestamp(),
            .is_wrapped = false,
            .wrapper_fuses = null,
            .wrapper_expiry = null,
            .is_v1_name = false,
            .v1_label_hash = null,
        };

        self.database.insertName(name) catch |err| {
            if (name.name) |n| self.allocator.free(n);
            if (name.label) |l| self.allocator.free(l);
            if (name.parent_name) |p| self.allocator.free(p);
            return err;
        };

        // If subregistry was deployed at registration, store it in the registries table
        if (!subregistry.isZero()) {
            const registry_entry = models.Registry{
                .address = subregistry,
                .chain = chain,
                .name = full_name,
                .namehash = namehash,
                .parent_registry = self.getEthRegistry(chain),
                .created_block = log.block_number,
                .created_at = self.getBlockTimestamp(chain, log.block_number),
            };
            self.database.insertRegistry(registry_entry) catch |err| {
                std.log.warn("Failed to insert subregistry for {s}: {any}", .{ full_name, err });
            };
            std.log.info("  → Registered subregistry {any} for {s}", .{ subregistry, full_name });
        }

        // Store event with payment details
        const payment_token_hex = try payment_token.toHex(self.allocator);
        defer self.allocator.free(payment_token_hex);
        const referrer_hex = try referrer.toHex(self.allocator);
        defer self.allocator.free(referrer_hex);

        // Escape label_str for safe JSON inclusion
        const escaped_label = try json_utils.escapeString(self.allocator, label_str);
        defer self.allocator.free(escaped_label);

        const owner_hex = try owner.toHex(self.allocator);
        defer self.allocator.free(owner_hex);

        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"label\":\"{s}\",\"tokenId\":{d},\"owner\":\"{s}\",\"duration\":{d},\"paymentToken\":\"{s}\",\"referrer\":\"{s}\",\"basePrice\":{d},\"premium\":{d}}}", .{
            escaped_label,
            token_id,
            owner_hex,
            duration,
            payment_token_hex,
            referrer_hex,
            base_price,
            premium,
        });

        const event_name = try std.fmt.allocPrint(self.allocator, "{s}.eth", .{label_str});

        const event = models.Event{
            .event_type = .name_registered,
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = event_name,
            .namehash = namehash,
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);
    }

    fn handleETHNameRenewed(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        // IETHRegistrar.NameRenewed(uint256 indexed tokenId, string label, uint64 duration, uint64 newExpiry, IERC20 paymentToken, bytes32 referrer, uint256 base)
        if (log.topics.len < 2) return error.InvalidTopicCount;

        const token_id_raw = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
        const token_id: u256 = token_id_raw;

        // Data: [offset_to_label, duration, newExpiry, paymentToken, referrer, base, label_length, label_data]
        const label_str = try abi.ABI.decodeString(self.allocator, log.data, 0);
        defer self.allocator.free(label_str);

        // Validate label is valid UTF-8 and contains no control characters
        unicode.validateName(label_str) catch |err| {
            std.log.warn("Invalid name label for tokenId={d}: {any}", .{ token_id, err });
            return;
        };

        const duration = try abi.ABI.decodeUint256(log.data, 32);  // uint64 padded
        const new_expiry = try abi.ABI.decodeUint256(log.data, 64);  // uint64 padded
        const payment_token = try abi.ABI.decodeAddress(log.data, 96);
        const referrer = try abi.ABI.decodeBytes32(log.data, 128);
        const base_price = try abi.ABI.decodeUint256(log.data, 160);

        std.log.debug("ETHRegistrar.NameRenewed: {s} (tokenId={d}, duration={d}, newExpiry={d}, base={d})", .{
            label_str, token_id, duration, new_expiry, base_price
        });

        // Update name expiry
        try self.database.updateNameExpiryByTokenId(@intCast(token_id), @intCast(new_expiry));

        // Store event with payment details
        const payment_token_hex = try payment_token.toHex(self.allocator);
        defer self.allocator.free(payment_token_hex);
        const referrer_hex = try referrer.toHex(self.allocator);
        defer self.allocator.free(referrer_hex);

        // Escape label_str for safe JSON inclusion
        const escaped_label = try json_utils.escapeString(self.allocator, label_str);
        defer self.allocator.free(escaped_label);

        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"label\":\"{s}\",\"tokenId\":{d},\"duration\":{d},\"newExpiry\":{d},\"paymentToken\":\"{s}\",\"referrer\":\"{s}\",\"basePrice\":{d}}}", .{
            escaped_label,
            token_id,
            duration,
            new_expiry,
            payment_token_hex,
            referrer_hex,
            base_price,
        });

        const maybe_name = try self.database.getNameByTokenId(token_id);
        const name_str = if (maybe_name) |n| blk: {
            var name_copy = n;
            defer name_copy.deinit(self.allocator);
            break :blk try self.allocator.dupe(u8, name_copy.name orelse "[unknown]");
        } else try std.fmt.allocPrint(self.allocator, "{s}.eth", .{label_str});
        defer self.allocator.free(name_str);

        const namehash = if (maybe_name) |n| n.namehash else Hash.zero;

        const event_name = try self.allocator.dupe(u8, name_str);

        const event = models.Event{
            .event_type = .name_renewed,
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = event_name,
            .namehash = namehash,
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);
    }

    fn handleCommitmentMade(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        // CommitmentMade(bytes32 commitment)
        // Note: bytes32 is NOT indexed, so it's in the data field
        if (log.topics.len < 1) return error.InvalidTopicCount;

        const commitment = try abi.ABI.decodeBytes32(log.data, 0);

        std.log.debug("CommitmentMade: commitment={any}", .{commitment});

        // Store event
        const commitment_hex = try commitment.toHex(self.allocator);
        defer self.allocator.free(commitment_hex);

        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"commitment\":\"{s}\"}}", .{commitment_hex});

        const event = models.Event{
            .event_type = .commitment_made,
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = null,
            .namehash = null,
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);
    }

    fn handleNameBurned(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        // NameBurned(uint256 indexed tokenId, address burnedBy)
        if (log.topics.len < 2) return error.InvalidTopicCount;

        const token_id_raw = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
        const token_id: u256 = token_id_raw;

        // Data contains: address burnedBy
        const burned_by = try abi.ABI.decodeAddress(log.data, 0);

        std.log.debug("NameBurned: tokenId={d}, burnedBy={any}", .{ token_id, burned_by });

        // Look up the name before deleting/marking as burned
        const maybe_name = try self.database.getNameByTokenId(token_id);
        const name_str = if (maybe_name) |n| blk: {
            var name_copy = n;
            defer name_copy.deinit(self.allocator);
            break :blk try self.allocator.dupe(u8, name_copy.name orelse "[unknown]");
        } else try std.fmt.allocPrint(self.allocator, "tokenId:{d}", .{token_id});
        defer self.allocator.free(name_str);

        const namehash = if (maybe_name) |n| n.namehash else Hash.zero;

        // Store event
        const burned_by_hex = try burned_by.toHex(self.allocator);
        defer self.allocator.free(burned_by_hex);

        // Escape name_str for safe JSON inclusion
        const escaped_name = try json_utils.escapeString(self.allocator, name_str);
        defer self.allocator.free(escaped_name);

        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"tokenId\":{d},\"name\":\"{s}\",\"burnedBy\":\"{s}\"}}", .{
            token_id,
            escaped_name,
            burned_by_hex,
        });

        const event_name = try self.allocator.dupe(u8, name_str);

        const event = models.Event{
            .event_type = .name_burned,
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = event_name,
            .namehash = namehash,
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);

        // Delete the burned name from the database
        try self.database.deleteNameByTokenId(@intCast(token_id));
        std.log.debug("Deleted burned name from database: {s}", .{name_str});
    }

    fn handleTokenRegenerated(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        // TokenRegenerated(uint256 oldTokenId, uint256 newTokenId)
        // Parameters may be indexed (in topics) or non-indexed (in data)
        var old_token_id: u256 = undefined;
        var new_token_id: u256 = undefined;

        if (log.topics.len >= 3) {
            // Both parameters are indexed (in topics)
            old_token_id = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
            new_token_id = try abi.ABI.decodeUint256(&log.topics[2].bytes, 0);
        } else if (log.data.len >= 64) {
            // Parameters are in data (non-indexed)
            old_token_id = try abi.ABI.decodeUint256(log.data, 0);
            new_token_id = try abi.ABI.decodeUint256(log.data, 32);
        } else {
            std.log.warn("TokenRegenerated event with unexpected format: topics={d}, data_len={d}", .{ log.topics.len, log.data.len });
            return;
        }

        std.log.debug("TokenRegenerated: oldTokenId={d}, newTokenId={d}", .{ old_token_id, new_token_id });

        // Look up the name by old token ID
        const maybe_name = try self.database.getNameByTokenId(old_token_id);
        const name_str = if (maybe_name) |n| blk: {
            var name_copy = n;
            defer name_copy.deinit(self.allocator);
            break :blk try self.allocator.dupe(u8, name_copy.name orelse "[unknown]");
        } else try std.fmt.allocPrint(self.allocator, "tokenId:{d}", .{old_token_id});
        defer self.allocator.free(name_str);

        const namehash = if (maybe_name) |n| n.namehash else Hash.zero;

        // Store event
        // Escape name_str for safe JSON inclusion
        const escaped_name = try json_utils.escapeString(self.allocator, name_str);
        defer self.allocator.free(escaped_name);

        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"oldTokenId\":{d},\"newTokenId\":{d},\"name\":\"{s}\"}}", .{
            old_token_id,
            new_token_id,
            escaped_name,
        });

        const event_name = try self.allocator.dupe(u8, name_str);

        const event = models.Event{
            .event_type = .token_regenerated,
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = event_name,
            .namehash = namehash,
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);

        // Update token_id in database from old to new
        try self.database.updateNameTokenId(old_token_id, new_token_id);
        std.log.debug("Updated token_id in database: {d} -> {d} for {s}", .{ old_token_id, new_token_id, name_str });
    }

    fn handleTransferBatch(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        // TransferBatch(address indexed operator, address indexed from, address indexed to, uint256[] ids, uint256[] values)
        if (log.topics.len < 4) return error.InvalidTopicCount;

        const operator = try abi.ABI.decodeAddress(&log.topics[1].bytes, 0);
        const from = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);
        const to = try abi.ABI.decodeAddress(&log.topics[3].bytes, 0);

        // Data contains two arrays: ids (offset 0) and values (offset 32)
        const token_ids = try abi.ABI.decodeUint256Array(self.allocator, log.data, 0);
        defer self.allocator.free(token_ids);

        const values = try abi.ABI.decodeUint256Array(self.allocator, log.data, 32);
        defer self.allocator.free(values);

        std.log.debug("TransferBatch: operator={any}, from={any}, to={any}, count={d}", .{ operator, from, to, token_ids.len });

        // Store event
        const operator_hex = try operator.toHex(self.allocator);
        defer self.allocator.free(operator_hex);
        const from_hex = try from.toHex(self.allocator);
        defer self.allocator.free(from_hex);
        const to_hex = try to.toHex(self.allocator);
        defer self.allocator.free(to_hex);

        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"operator\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"count\":{d}}}", .{
            operator_hex,
            from_hex,
            to_hex,
            token_ids.len,
        });

        const event = models.Event{
            .event_type = .transfer,
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = null,
            .namehash = null,
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);

        // Update ownership for each transferred token
        for (token_ids) |token_id| {
            // Only update if transferring to a non-zero address (not burning)
            if (!to.isZero()) {
                // Try to update the owner - if the name doesn't exist, skip it
                const maybe_name = self.database.getNameByTokenId(token_id) catch |err| {
                    std.log.warn("Failed to get name for tokenId={d} during batch transfer: {any}", .{ token_id, err });
                    continue;
                };

                if (maybe_name) |name| {
                    // Store the namehash before cleanup
                    const namehash = name.namehash;
                    // Free the name record
                    var mutable_name = name;
                    mutable_name.deinit(self.allocator);

                    // Use the actual namehash from the retrieved name, not Hash.zero
                    self.database.updateNameOwner(namehash, to) catch |err| {
                        std.log.warn("Failed to update owner for tokenId={d}: {any}", .{ token_id, err });
                    };
                }
            }
        }
    }

    fn handleApproval(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        // Approval(address indexed owner, address indexed approved, uint256 indexed tokenId)
        if (log.topics.len < 4) return error.InvalidTopicCount;

        const owner = try abi.ABI.decodeAddress(&log.topics[1].bytes, 0);
        const approved = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);
        const token_id_raw = try abi.ABI.decodeUint256(&log.topics[3].bytes, 0);
        const token_id: u256 = token_id_raw;

        std.log.debug("Approval: owner={any}, approved={any}, tokenId={d}", .{ owner, approved, token_id });

        // Look up the name
        const maybe_name = try self.database.getNameByTokenId(token_id);
        const name_str = if (maybe_name) |n| blk: {
            var name_copy = n;
            defer name_copy.deinit(self.allocator);
            break :blk try self.allocator.dupe(u8, name_copy.name orelse "[unknown]");
        } else try std.fmt.allocPrint(self.allocator, "tokenId:{d}", .{token_id});
        defer self.allocator.free(name_str);

        const namehash = if (maybe_name) |n| n.namehash else Hash.zero;

        // Store event
        const owner_hex = try owner.toHex(self.allocator);
        defer self.allocator.free(owner_hex);
        const approved_hex = try approved.toHex(self.allocator);
        defer self.allocator.free(approved_hex);

        // Escape name_str for safe JSON inclusion
        const escaped_name = try json_utils.escapeString(self.allocator, name_str);
        defer self.allocator.free(escaped_name);

        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"owner\":\"{s}\",\"approved\":\"{s}\",\"tokenId\":{d},\"name\":\"{s}\"}}", .{
            owner_hex,
            approved_hex,
            token_id,
            escaped_name,
        });

        const event_name = try self.allocator.dupe(u8, name_str);

        const event = models.Event{
            .event_type = .approval,
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = event_name,
            .namehash = namehash,
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);

        // Store approval in database
        try self.database.insertApproval(chain, token_id, owner, approved, log.block_number, log.transaction_hash);
        std.log.debug("Stored approval in database for tokenId={d}", .{token_id});
    }

    // ========================================================================
    // Enhanced Access Control (EAC) Event Handler
    // ========================================================================

    /// Handle EACRolesChanged event from registry contracts
    /// EACRolesChanged(uint256 indexed resource, address indexed account, uint256 oldRoleBitmap, uint256 newRoleBitmap)
    fn handleEACRolesChanged(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        // Event: EACRolesChanged(uint256 indexed resource, address indexed account, uint256 oldRoleBitmap, uint256 newRoleBitmap)
        // topics[0] = event signature
        // topics[1] = resource (tokenId/namehash as uint256) - indexed
        // topics[2] = account - indexed
        // data = oldRoleBitmap (uint256) + newRoleBitmap (uint256)
        if (log.topics.len < 3) return error.InvalidTopicCount;

        // Decode indexed parameters from topics
        const resource_uint = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
        const account = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);

        // Decode non-indexed parameters from data
        const old_role_bitmap = try abi.ABI.decodeUint256(log.data, 0);
        const new_role_bitmap = try abi.ABI.decodeUint256(log.data, 32);

        // Convert resource uint256 to hex string (this is the namehash/tokenId)
        var resource_bytes: [32]u8 = undefined;
        std.mem.writeInt(u256, &resource_bytes, resource_uint, .big);
        const resource_hex_chars = std.fmt.bytesToHex(resource_bytes, .lower);
        const resource_hex = try std.fmt.allocPrint(self.allocator, "0x{s}", .{resource_hex_chars});
        defer self.allocator.free(resource_hex);

        // Convert role bitmaps to hex strings
        var old_bitmap_bytes: [32]u8 = undefined;
        std.mem.writeInt(u256, &old_bitmap_bytes, old_role_bitmap, .big);
        const old_bitmap_hex_chars = std.fmt.bytesToHex(old_bitmap_bytes, .lower);
        const old_bitmap_hex = try std.fmt.allocPrint(self.allocator, "0x{s}", .{old_bitmap_hex_chars});
        defer self.allocator.free(old_bitmap_hex);

        var new_bitmap_bytes: [32]u8 = undefined;
        std.mem.writeInt(u256, &new_bitmap_bytes, new_role_bitmap, .big);
        const new_bitmap_hex_chars = std.fmt.bytesToHex(new_bitmap_bytes, .lower);
        const new_bitmap_hex = try std.fmt.allocPrint(self.allocator, "0x{s}", .{new_bitmap_hex_chars});
        defer self.allocator.free(new_bitmap_hex);

        const account_hex = try account.toHex(self.allocator);
        defer self.allocator.free(account_hex);

        std.log.debug("EACRolesChanged: resource={s}, account={s}, oldBitmap={s}, newBitmap={s}", .{
            resource_hex,
            account_hex,
            old_bitmap_hex,
            new_bitmap_hex,
        });

        // Store or delete role in database
        // If newRoleBitmap is 0, all roles were revoked - delete the entry
        // Otherwise, upsert with the new bitmap
        if (new_role_bitmap == 0) {
            try self.database.deleteEACRole(chain, resource_hex, account);
            std.log.debug("  → Deleted EAC role (all roles revoked)", .{});
        } else {
            try self.database.upsertEACRole(
                chain,
                resource_hex,
                account,
                new_bitmap_hex,
                log.block_number,
                log.transaction_hash,
                log.log_index,
            );
            std.log.debug("  → Stored EAC role assignment", .{});
        }

        // Store event for audit trail
        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"resource\":\"{s}\",\"account\":\"{s}\",\"oldRoleBitmap\":\"{s}\",\"newRoleBitmap\":\"{s}\"}}", .{
            resource_hex,
            account_hex,
            old_bitmap_hex,
            new_bitmap_hex,
        });

        // Try to look up name for this resource (tokenId)
        const maybe_name = try self.database.getNameByTokenId(resource_uint);
        var name_str_opt: ?[]const u8 = null;
        var namehash_opt: ?Hash = null;

        if (maybe_name) |name| {
            name_str_opt = if (name.name) |n| try self.allocator.dupe(u8, n) else null;
            namehash_opt = name.namehash;
            var name_copy = name;
            name_copy.deinit(self.allocator);
        }

        defer if (name_str_opt) |n| self.allocator.free(n);

        const event = models.Event{
            .event_type = .eac_roles_changed,
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = if (name_str_opt) |n| try self.allocator.dupe(u8, n) else null,
            .namehash = namehash_opt,
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);
    }

    // ========================================================================
    // V1 EVENT INDEXING FUNCTIONS (ENS V1 - Mainnet)
    // ========================================================================

    /// Index Temporary Registrar events (Pre-V1 Migration, only on L1/mainnet)
    /// AuctionStarted, NewBid, BidRevealed, HashRegistered, HashReleased, HashInvalidated
    /// Active from May 2017 (block 3327417) to May 2019 (block 9380410)
    fn indexTempRegistrarEvents(self: *Indexer, chain: models.Chain, client: *rpc.Client, from_block: u64, to_block: u64) !void {
        if (chain != .l1) return; // Temporary Registrar only exists on mainnet L1

        // V1 Permanent Registrar migration block (from contract config)
        const v1_migration_block = self.config.l1_contracts.v1_migration_block;
        if (v1_migration_block == 0) return; // Testnets don't have temp registrar
        if (from_block >= v1_migration_block) return; // No temp registrar events after migration

        // Adjust to_block to not exceed migration block
        const adjusted_to_block = if (to_block >= v1_migration_block) v1_migration_block - 1 else to_block;

        try self.indexV1EventsChunked(
            chain,
            client,
            from_block,
            adjusted_to_block,
            self.config.l1_contracts.temporary_registrar,
            &TEMP_REGISTRAR_EVENTS,
            "Temporary Registrar",
        );

        // Index ENS Registry events to create name relationships
        // NewOwner, NewResolver, Transfer events from the ENS Registry contract
        // This captures the actual domain ownership and metadata during the temp registrar period
        try self.indexV1EventsChunked(
            chain,
            client,
            from_block,
            adjusted_to_block,
            self.config.l1_contracts.ens_registry,
            &V1_REGISTRY_EVENTS,
            "ENS Registry (Pre-Migration)",
        );
    }

    /// Index V1 ENS Registry events (only on L1/mainnet)
    /// NewOwner, Transfer, NewResolver, NewTTL
    fn indexV1RegistryEvents(self: *Indexer, chain: models.Chain, client: *rpc.Client, from_block: u64, to_block: u64) !void {
        if (chain != .l1) return; // V1 events only exist on mainnet L1
        try self.indexV1EventsChunked(
            chain,
            client,
            from_block,
            to_block,
            self.config.l1_contracts.ens_registry,
            &V1_REGISTRY_EVENTS,
            "ENS Registry",
        );
    }

    /// Index V1 Name Wrapper events (only on L1/mainnet, from block 15628465)
    /// NameWrapped, NameUnwrapped, FusesSet, ExpiryExtended
    fn indexV1NameWrapperEvents(self: *Indexer, chain: models.Chain, client: *rpc.Client, from_block: u64, to_block: u64) !void {
        if (chain != .l1) return; // V1 events only exist on mainnet L1

        // Name Wrapper deployment block (from contract config)
        const name_wrapper_deployment = self.config.l1_contracts.name_wrapper_deployment_block;
        if (name_wrapper_deployment == 0) return; // Testnets may not have Name Wrapper at same block
        if (to_block < name_wrapper_deployment) return;

        const adjusted_from_block = if (from_block < name_wrapper_deployment) name_wrapper_deployment else from_block;

        try self.indexV1EventsChunked(
            chain,
            client,
            adjusted_from_block,
            to_block,
            self.config.l1_contracts.name_wrapper,
            &V1_NAME_WRAPPER_EVENTS,
            "Name Wrapper",
        );
    }

    /// Index V1 Base Registrar events (only on L1/mainnet)
    /// ERC721 Transfer, NameRegistered, NameRenewed
    fn indexV1BaseRegistrarEvents(self: *Indexer, chain: models.Chain, client: *rpc.Client, from_block: u64, to_block: u64) !void {
        if (chain != .l1) return; // V1 events only exist on mainnet L1
        try self.indexV1EventsChunked(
            chain,
            client,
            from_block,
            to_block,
            self.config.l1_contracts.base_registrar,
            &V1_BASE_REGISTRAR_EVENTS,
            "Base Registrar",
        );
    }

    /// Index V1 Reverse Registrar events (only on L1/mainnet)
    /// ReverseClaimed
    fn indexV1ReverseRegistrarEvents(self: *Indexer, chain: models.Chain, client: *rpc.Client, from_block: u64, to_block: u64) !void {
        if (chain != .l1) return; // V1 events only exist on mainnet L1
        try self.indexV1EventsChunked(
            chain,
            client,
            from_block,
            to_block,
            self.config.l1_contracts.reverse_registrar,
            &V1_REVERSE_REGISTRAR_EVENTS,
            "Reverse Registrar",
        );
    }

    /// Index resolver data events (AddressChanged, ContentHashChanged, TextChanged)
    /// Queries all known resolver contracts for events in the block range
    /// Uses multi-address queries to fetch all events in minimal RPC calls
    fn indexResolverEvents(self: *Indexer, chain: models.Chain, client: *rpc.Client, from_block: u64, to_block: u64) !void {
        // Get resolvers to index (uses cache table for performance)
        const resolvers = try self.database.getResolversToIndex(chain, from_block, to_block);
        defer {
            for (resolvers) |resolver| {
                self.allocator.free(resolver);
            }
            self.allocator.free(resolvers);
        }

        if (resolvers.len == 0) {
            std.log.info("No resolvers to index for blocks {d}-{d}", .{ from_block, to_block });
            return;
        }

        std.log.info("Indexing resolver events for {d} unique resolvers from blocks {d}-{d}", .{ resolvers.len, from_block, to_block });

        // RPC provider address limit per eth_getLogs call (conservative estimate)
        const RESOLVERS_PER_CALL = constants.RpcBatching.addresses_per_call;

        // Build event topic array for OR matching (all 7 resolver event types)
        var event_topics: [RESOLVER_EVENTS.len]Hash = undefined;
        inline for (RESOLVER_EVENTS, 0..) |event_cfg, i| {
            event_topics[i] = event_cfg.event_hash;
        }

        // Process resolvers in chunks based on address limit
        var chunk_start: usize = 0;
        var chunk_num: usize = 1;
        const total_chunks = (resolvers.len + RESOLVERS_PER_CALL - 1) / RESOLVERS_PER_CALL;

        while (chunk_start < resolvers.len) {
            const chunk_end = @min(chunk_start + RESOLVERS_PER_CALL, resolvers.len);
            const chunk_size = chunk_end - chunk_start;

            std.log.info("Processing resolver batch {d}/{d} ({d} resolvers, 1 RPC call)...", .{
                chunk_num,
                total_chunks,
                chunk_size,
            });

            // Convert resolver hex strings to Address objects for this chunk
            var resolver_addrs = try self.allocator.alloc(Address, chunk_size);
            defer self.allocator.free(resolver_addrs);

            for (resolvers[chunk_start..chunk_end], 0..) |resolver_str, i| {
                resolver_addrs[i] = try Address.fromHex(resolver_str);
            }

            // Single RPC call for all resolvers in this chunk and all event types
            const logs = try client.getLogsMultiAddress(.{
                .from_block = from_block,
                .to_block = to_block,
                .addresses = resolver_addrs,
                .topic0_or = &event_topics,
            });
            defer {
                for (logs) |*log| {
                    log.deinit(self.allocator);
                }
                self.allocator.free(logs);
            }

            std.log.info("  Fetched {d} total events from {d} resolvers", .{ logs.len, chunk_size });

            // Process logs by matching topic[0] to event handler
            for (logs) |log| {
                if (log.topics.len == 0) continue;

                const event_sig = log.topics[0];
                const resolver = log.address;

                // Find matching handler by comparing event signature
                inline for (RESOLVER_EVENTS) |event_cfg| {
                    if (event_sig.eql(event_cfg.event_hash)) {
                        try event_cfg.handler(self, chain, resolver, log);
                        break;
                    }
                }
            }

            // Update last_indexed_block for all resolvers in this chunk
            for (resolvers[chunk_start..chunk_end]) |resolver_str| {
                try self.database.registerResolver(chain, resolver_str, to_block);
            }

            std.log.info("Batch {d} complete: processed {d} resolvers", .{ chunk_num, chunk_size });

            chunk_start = chunk_end;
            chunk_num += 1;

            // Rate limit: wait between batches to avoid hitting RPC provider limits
            if (chunk_start < resolvers.len) {
                std.Thread.sleep(300 * std.time.ns_per_ms); // 300ms delay between batches
            }
        }

        std.log.info("Resolver indexing complete: {d} resolvers processed", .{resolvers.len});
    }

    /// Handle AddressChanged event
    /// AddressChanged(bytes32 indexed node, uint256 coinType, bytes newAddress)
    fn handleAddressChanged(self: *Indexer, chain: models.Chain, resolver: Address, log: rpc.Log) !void {
        // topics[0] = event signature
        // topics[1] = indexed node (namehash)
        if (log.topics.len < 2) return error.InvalidTopicCount;
        var namehash = log.topics[1];

        // Decode coin type and address from data
        const coin_type = try abi.ABI.decodeUint256(log.data, 0);
        const address_bytes = try abi.ABI.decodeBytes(self.allocator, log.data, 32);
        defer self.allocator.free(address_bytes);

        // Convert address bytes to hex string
        var address_hex = try self.allocator.alloc(u8, 2 + address_bytes.len * 2);
        defer self.allocator.free(address_hex);
        address_hex[0] = '0';
        address_hex[1] = 'x';
        for (address_bytes, 0..) |byte, i| {
            _ = try std.fmt.bufPrint(address_hex[2 + i * 2 .. 4 + i * 2], "{x:0>2}", .{byte});
        }

        // In ENSv2, each name has its own dedicated resolver. If the namehash is zero,
        // look up the actual namehash from the resolver address.
        if (namehash.isZero()) {
            if (try self.database.getNamehashByResolver(resolver)) |actual_namehash| {
                namehash = actual_namehash;
            } else {
                std.log.debug("AddressChanged: skipping event with zero namehash and unknown resolver", .{});
                return;
            }
        }

        const nh_hex_log = try namehash.toHex(self.allocator);
        defer self.allocator.free(nh_hex_log);
        std.log.debug("AddressChanged: namehash={s} coinType={d} address={s}", .{
            nh_hex_log,
            coin_type,
            address_hex,
        });

        // Store in database
        try self.database.storeResolverAddress(
            namehash,
            resolver,
            @intCast(coin_type),
            address_hex,
            chain,
            log.block_number,
            log.transaction_hash,
            std.time.timestamp(),
        );

        // Store event and trigger webhooks
        const nh_hex = try namehash.toHex(self.allocator);
        defer self.allocator.free(nh_hex);
        const resolver_hex = try resolver.toHex(self.allocator);
        defer self.allocator.free(resolver_hex);

        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"namehash\":\"{s}\",\"resolver\":\"{s}\",\"coinType\":{d},\"address\":\"{s}\"}}", .{
            nh_hex,
            resolver_hex,
            coin_type,
            address_hex,
        });

        const event = models.Event{
            .event_type = .address_changed,
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = null,
            .namehash = namehash,
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);
    }

    /// Handle ContentHashChanged event
    /// ContentHashChanged(bytes32 indexed node, bytes hash)
    fn handleContentHashChanged(self: *Indexer, chain: models.Chain, resolver: Address, log: rpc.Log) !void {
        // topics[0] = event signature
        // topics[1] = indexed node (namehash)
        if (log.topics.len < 2) return error.InvalidTopicCount;
        var namehash = log.topics[1];

        // Decode content hash from data
        const content_hash_bytes = try abi.ABI.decodeBytes(self.allocator, log.data, 0);
        defer self.allocator.free(content_hash_bytes);

        // Convert to hex string
        var content_hash_hex = try self.allocator.alloc(u8, 2 + content_hash_bytes.len * 2);
        defer self.allocator.free(content_hash_hex);
        content_hash_hex[0] = '0';
        content_hash_hex[1] = 'x';
        for (content_hash_bytes, 0..) |byte, i| {
            _ = try std.fmt.bufPrint(content_hash_hex[2 + i * 2 .. 4 + i * 2], "{x:0>2}", .{byte});
        }

        // In ENSv2, each name has its own dedicated resolver. If the namehash is zero,
        // look up the actual namehash from the resolver address.
        if (namehash.isZero()) {
            if (try self.database.getNamehashByResolver(resolver)) |actual_namehash| {
                namehash = actual_namehash;
            } else {
                std.log.debug("ContentHashChanged: skipping event with zero namehash and unknown resolver", .{});
                return;
            }
        }

        const nh_hex_log = try namehash.toHex(self.allocator);
        defer self.allocator.free(nh_hex_log);
        std.log.debug("ContentHashChanged: namehash={s} contentHash={s}", .{
            nh_hex_log,
            content_hash_hex,
        });

        // Store in database
        try self.database.storeResolverContentHash(
            namehash,
            resolver,
            content_hash_hex,
            chain,
            log.block_number,
            log.transaction_hash,
            std.time.timestamp(),
        );

        // Store event and trigger webhooks
        const nh_hex = try namehash.toHex(self.allocator);
        defer self.allocator.free(nh_hex);
        const resolver_hex = try resolver.toHex(self.allocator);
        defer self.allocator.free(resolver_hex);

        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"namehash\":\"{s}\",\"resolver\":\"{s}\",\"contentHash\":\"{s}\"}}", .{
            nh_hex,
            resolver_hex,
            content_hash_hex,
        });

        const event = models.Event{
            .event_type = .contenthash_changed,
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = null,
            .namehash = namehash,
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);
    }

    /// Handle TextChanged event
    /// TextChanged(bytes32 indexed node, string indexed indexedKey, string key, string value)
    fn handleTextChanged(self: *Indexer, chain: models.Chain, resolver: Address, log: rpc.Log) !void {
        // topics[0] = event signature
        // topics[1] = indexed node (namehash)
        // topics[2] = indexed key (hashed, not useful)
        if (log.topics.len < 2) return error.InvalidTopicCount;
        var namehash = log.topics[1];

        // Decode key and value from data
        const key = try abi.ABI.decodeString(self.allocator, log.data, 0);
        defer self.allocator.free(key);

        const value = try abi.ABI.decodeString(self.allocator, log.data, 32);
        defer self.allocator.free(value);

        // Validate key and value are valid UTF-8 and contain no dangerous control characters
        unicode.validateString(key) catch |err| {
            std.log.warn("Invalid UTF-8 in text record key: {any}", .{err});
            return;
        };
        unicode.validateString(value) catch |err| {
            std.log.warn("Invalid UTF-8 in text record value: {any}", .{err});
            return;
        };

        // In ENSv2, each name has its own dedicated resolver (User Resolver pattern).
        // The TextChanged event may emit with a zeroed namehash because the resolver
        // itself is dedicated to one name. In this case, we look up the name's namehash
        // from the resolver address.
        if (namehash.isZero()) {
            if (try self.database.getNamehashByResolver(resolver)) |actual_namehash| {
                namehash = actual_namehash;
                std.log.debug("TextChanged: resolved zero namehash to {s} via resolver lookup", .{
                    (try actual_namehash.toHex(self.allocator)),
                });
            } else {
                // Resolver not associated with any indexed name - skip this event
                std.log.debug("TextChanged: skipping event with zero namehash and unknown resolver", .{});
                return;
            }
        }

        const nh_hex_log = try namehash.toHex(self.allocator);
        defer self.allocator.free(nh_hex_log);
        std.log.debug("TextChanged: namehash={s} key={s} value={s}", .{
            nh_hex_log,
            key,
            value,
        });

        // Store in database
        try self.database.storeResolverText(
            namehash,
            resolver,
            key,
            value,
            chain,
            log.block_number,
            log.transaction_hash,
            std.time.timestamp(),
        );

        // Store event and trigger webhooks
        const nh_hex = try namehash.toHex(self.allocator);
        defer self.allocator.free(nh_hex);
        const resolver_hex = try resolver.toHex(self.allocator);
        defer self.allocator.free(resolver_hex);

        // Escape key and value for safe JSON inclusion
        const escaped_key = try json_utils.escapeString(self.allocator, key);
        defer self.allocator.free(escaped_key);
        const escaped_value = try json_utils.escapeString(self.allocator, value);
        defer self.allocator.free(escaped_value);

        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"namehash\":\"{s}\",\"resolver\":\"{s}\",\"key\":\"{s}\",\"value\":\"{s}\"}}", .{
            nh_hex,
            resolver_hex,
            escaped_key,
            escaped_value,
        });

        const event = models.Event{
            .event_type = .text_changed,
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = null,
            .namehash = namehash,
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);
    }

    /// Handle ABIChanged event
    /// ABIChanged(bytes32 indexed node, uint256 indexed contentType)
    fn handleABIChanged(self: *Indexer, chain: models.Chain, resolver: Address, log: rpc.Log) !void {
        // topics[0] = event signature
        // topics[1] = indexed node (namehash)
        // topics[2] = indexed contentType
        const namehash = log.topics[1];
        const content_type = try abi.ABI.decodeUint256(&log.topics[2].bytes, 0);

        const nh_hex_log = try namehash.toHex(self.allocator);
        defer self.allocator.free(nh_hex_log);
        std.log.debug("ABIChanged: namehash={s} contentType={d}", .{
            nh_hex_log,
            content_type,
        });

        // Store event and trigger webhooks
        const nh_hex = try namehash.toHex(self.allocator);
        defer self.allocator.free(nh_hex);
        const resolver_hex = try resolver.toHex(self.allocator);
        defer self.allocator.free(resolver_hex);

        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"namehash\":\"{s}\",\"resolver\":\"{s}\",\"contentType\":{d}}}", .{
            nh_hex,
            resolver_hex,
            content_type,
        });

        const event = models.Event{
            .event_type = .abi_changed,
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = null,
            .namehash = namehash,
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);
    }

    /// Handle PubkeyChanged event
    /// PubkeyChanged(bytes32 indexed node, bytes32 x, bytes32 y)
    fn handlePubkeyChanged(self: *Indexer, chain: models.Chain, resolver: Address, log: rpc.Log) !void {
        // topics[0] = event signature
        // topics[1] = indexed node (namehash)
        const namehash = log.topics[1];

        // Data contains x and y coordinates (each 32 bytes)
        if (log.data.len < 64) return error.InsufficientData;

        const x = try abi.ABI.decodeBytes32(log.data, 0);
        const y = try abi.ABI.decodeBytes32(log.data, 32);

        const nh_hex_log = try namehash.toHex(self.allocator);
        defer self.allocator.free(nh_hex_log);
        const x_hex_log = try x.toHex(self.allocator);
        defer self.allocator.free(x_hex_log);
        const y_hex_log = try y.toHex(self.allocator);
        defer self.allocator.free(y_hex_log);
        std.log.debug("PubkeyChanged: namehash={s} x={s} y={s}", .{
            nh_hex_log,
            x_hex_log,
            y_hex_log,
        });

        // Store event and trigger webhooks
        const nh_hex = try namehash.toHex(self.allocator);
        defer self.allocator.free(nh_hex);
        const resolver_hex = try resolver.toHex(self.allocator);
        defer self.allocator.free(resolver_hex);
        const x_hex = try x.toHex(self.allocator);
        defer self.allocator.free(x_hex);
        const y_hex = try y.toHex(self.allocator);
        defer self.allocator.free(y_hex);

        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"namehash\":\"{s}\",\"resolver\":\"{s}\",\"x\":\"{s}\",\"y\":\"{s}\"}}", .{
            nh_hex,
            resolver_hex,
            x_hex,
            y_hex,
        });

        const event = models.Event{
            .event_type = .pubkey_changed,
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = null,
            .namehash = namehash,
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);
    }

    /// Handle NameChanged event (reverse resolution)
    /// NameChanged(bytes32 indexed node, string name)
    fn handleNameChanged(self: *Indexer, chain: models.Chain, resolver: Address, log: rpc.Log) !void {
        // topics[0] = event signature
        // topics[1] = indexed node (namehash)
        const namehash = log.topics[1];

        // Decode name from data
        const name = try abi.ABI.decodeString(self.allocator, log.data, 0);
        defer self.allocator.free(name);

        // Validate name is valid UTF-8
        unicode.validateString(name) catch |err| {
            std.log.warn("Invalid UTF-8 in reverse name: {any}", .{err});
            return;
        };

        const nh_hex_log = try namehash.toHex(self.allocator);
        defer self.allocator.free(nh_hex_log);
        std.log.debug("NameChanged: namehash={s} name={s}", .{
            nh_hex_log,
            name,
        });

        // Store event and trigger webhooks
        const nh_hex = try namehash.toHex(self.allocator);
        defer self.allocator.free(nh_hex);
        const resolver_hex = try resolver.toHex(self.allocator);
        defer self.allocator.free(resolver_hex);

        // Escape name for safe JSON inclusion
        const escaped_name = try json_utils.escapeString(self.allocator, name);
        defer self.allocator.free(escaped_name);

        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"namehash\":\"{s}\",\"resolver\":\"{s}\",\"name\":\"{s}\"}}", .{
            nh_hex,
            resolver_hex,
            escaped_name,
        });

        const event = models.Event{
            .event_type = .name_changed,
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = null,
            .namehash = namehash,
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);
    }

    /// Handle InterfaceChanged event
    /// InterfaceChanged(bytes32 indexed node, bytes4 indexed interfaceID, address implementer)
    fn handleInterfaceChanged(self: *Indexer, chain: models.Chain, resolver: Address, log: rpc.Log) !void {
        // topics[0] = event signature
        // topics[1] = indexed node (namehash)
        // topics[2] = indexed interfaceID (bytes4 padded to bytes32)
        const namehash = log.topics[1];

        // Interface ID is a bytes4, stored in the last 4 bytes of the topic
        const interface_id_bytes = log.topics[2].bytes[28..32];

        // Decode implementer address from data
        const implementer = try abi.ABI.decodeAddress(log.data, 0);

        // Convert interface ID to hex string
        var interface_id_hex = try self.allocator.alloc(u8, 10); // "0x" + 8 hex chars
        defer self.allocator.free(interface_id_hex);
        interface_id_hex[0] = '0';
        interface_id_hex[1] = 'x';
        for (interface_id_bytes, 0..) |byte, i| {
            _ = try std.fmt.bufPrint(interface_id_hex[2 + i * 2 .. 4 + i * 2], "{x:0>2}", .{byte});
        }

        const nh_hex_log = try namehash.toHex(self.allocator);
        defer self.allocator.free(nh_hex_log);
        std.log.debug("InterfaceChanged: namehash={s} interfaceID={s} implementer={any}", .{
            nh_hex_log,
            interface_id_hex,
            implementer,
        });

        // Store event and trigger webhooks
        const nh_hex = try namehash.toHex(self.allocator);
        defer self.allocator.free(nh_hex);
        const resolver_hex = try resolver.toHex(self.allocator);
        defer self.allocator.free(resolver_hex);
        const implementer_hex = try implementer.toHex(self.allocator);
        defer self.allocator.free(implementer_hex);

        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"namehash\":\"{s}\",\"resolver\":\"{s}\",\"interfaceID\":\"{s}\",\"implementer\":\"{s}\"}}", .{
            nh_hex,
            resolver_hex,
            interface_id_hex,
            implementer_hex,
        });

        const event = models.Event{
            .event_type = .interface_changed,
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = null,
            .namehash = namehash,
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);
    }

    /// Handle NameEjectedToL1 event
    /// NameEjectedToL1(bytes dnsEncodedName, uint256 tokenId)
    fn handleNameEjectedToL1(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        // topics[0] = event signature
        // No indexed parameters, all in data
        if (log.data.len < 64) return error.InsufficientData;

        // Decode dns_encoded_name (dynamic bytes)
        const dns_encoded_name = try abi.ABI.decodeBytes(self.allocator, log.data, 0);
        defer self.allocator.free(dns_encoded_name);

        // Decode token_id
        const token_id = try abi.ABI.decodeUint256(log.data, 32);

        std.log.debug("NameEjectedToL1: tokenId={d} dnsName={any}", .{ token_id, dns_encoded_name });

        // Store in database
        try self.database.insertMigration(
            chain,
            token_id,
            .to_l1,
            dns_encoded_name,
            log.block_number,
            log.transaction_hash,
            log.log_index,
        );
    }

    /// Handle NameEjectedToL2 event
    /// NameEjectedToL2(bytes dnsEncodedName, uint256 tokenId)
    fn handleNameEjectedToL2(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        // topics[0] = event signature
        // No indexed parameters, all in data
        if (log.data.len < 64) return error.InsufficientData;

        // Decode dns_encoded_name (dynamic bytes)
        const dns_encoded_name = try abi.ABI.decodeBytes(self.allocator, log.data, 0);
        defer self.allocator.free(dns_encoded_name);

        // Decode token_id
        const token_id = try abi.ABI.decodeUint256(log.data, 32);

        std.log.debug("NameEjectedToL2: tokenId={d} dnsName={any}", .{ token_id, dns_encoded_name });

        // Store in database
        try self.database.insertMigration(
            chain,
            token_id,
            .to_l2,
            dns_encoded_name,
            log.block_number,
            log.transaction_hash,
            log.log_index,
        );
    }

    /// Handle RenewalSynchronized event
    /// RenewalSynchronized(uint256 tokenId, uint64 newExpiry)
    fn handleRenewalSynchronized(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        // topics[0] = event signature
        // No indexed parameters, all in data
        if (log.data.len < 64) return error.InsufficientData;

        // Decode token_id
        const token_id = try abi.ABI.decodeUint256(log.data, 0);

        // Decode new_expiry (uint64, but padded to 32 bytes)
        const new_expiry_u256 = try abi.ABI.decodeUint256(log.data, 32);
        const new_expiry: u64 = @intCast(new_expiry_u256);

        std.log.debug("RenewalSynchronized: tokenId={d} newExpiry={d}", .{ token_id, new_expiry });

        // Store in database
        try self.database.insertRenewalSync(
            chain,
            token_id,
            new_expiry,
            log.block_number,
            log.transaction_hash,
            log.log_index,
        );
    }

    /// Handle TokenObserverSet event
    /// TokenObserverSet(uint256 indexed tokenId, address observer)
    fn handleTokenObserverSet(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        // topics[0] = event signature
        // topics[1] = indexed tokenId
        if (log.topics.len < 2) return error.InvalidTopicCount;
        if (log.data.len < 32) return error.InsufficientData;

        const token_id = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);

        // Decode observer address from data
        const observer = try abi.ABI.decodeAddress(log.data, 0);

        std.log.debug("TokenObserverSet: tokenId={d} observer={any}", .{ token_id, observer });

        // Store in database
        try self.database.insertTokenObserver(
            chain,
            token_id,
            observer,
            log.block_number,
            log.transaction_hash,
            log.log_index,
        );
    }

    // ========================================================================
    // V1 EVENT HANDLERS (ENS V1 - Mainnet)
    // ========================================================================

    /// Handle V1 ENS Registry NewOwner event
    /// NewOwner(bytes32 indexed node, bytes32 indexed label, address owner)
    /// This event is emitted when a subdomain is created
    fn handleV1NewOwner(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        // topics[0] = event signature
        // topics[1] = indexed node (parent namehash)
        // topics[2] = indexed label (labelhash)
        if (log.topics.len < 3) return error.InvalidTopicCount;
        if (log.data.len < 32) return error.InsufficientData;

        const parent_node = log.topics[1];
        const labelhash = log.topics[2];

        // Decode owner address from data
        const owner = try abi.ABI.decodeAddress(log.data, 0);

        const parent_hex = try parent_node.toHex(self.allocator);
        defer self.allocator.free(parent_hex);
        const labelhash_hex = try labelhash.toHex(self.allocator);
        defer self.allocator.free(labelhash_hex);
        const owner_hex = try owner.toHex(self.allocator);
        defer self.allocator.free(owner_hex);

        // Compute the subdomain namehash: keccak256(parent_node + labelhash)
        var subdomain_input: [64]u8 = undefined;
        @memcpy(subdomain_input[0..32], &parent_node.bytes);
        @memcpy(subdomain_input[32..64], &labelhash.bytes);

        const Keccak256 = std.crypto.hash.sha3.Keccak256;
        var subdomain_namehash_bytes: [32]u8 = undefined;
        Keccak256.hash(&subdomain_input, &subdomain_namehash_bytes, .{});

        var subdomain_namehash: Hash = undefined;
        @memcpy(&subdomain_namehash.bytes, &subdomain_namehash_bytes);

        const subdomain_hex = try subdomain_namehash.toHex(self.allocator);
        defer self.allocator.free(subdomain_hex);

        std.log.debug("V1 NewOwner: parent={s} labelhash={s} subdomain={s} owner={s}", .{
            parent_hex,
            labelhash_hex,
            subdomain_hex,
            owner_hex,
        });

        // V1 migration block - before this, we're in the temporary registrar period
        const v1_migration_block = self.config.l1_contracts.v1_migration_block;
        const is_pre_migration = v1_migration_block > 0 and log.block_number < v1_migration_block;

        if (is_pre_migration) {
            // Store for later backfill when v1_labels table is populated
            std.log.debug("Storing pre-migration NewOwner for backfill: namehash={s} labelhash={s}", .{ subdomain_hex, labelhash_hex });

            const insert_sql =
                \\INSERT OR IGNORE INTO temp_pre_migration_names
                \\(chain, namehash, label_hash, parent_node, owner, block_number, tx_hash, log_index, created_at)
                \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ;

            var stmt: ?*c.sqlite3_stmt = null;
            var rc = c.sqlite3_prepare_v2(self.database.db, insert_sql.ptr, @intCast(insert_sql.len), &stmt, null);
            if (rc != c.SQLITE_OK) {
                std.log.err("Failed to prepare temp_pre_migration_names insert: {s}", .{c.sqlite3_errmsg(self.database.db)});
                return error.DatabaseError;
            }
            defer _ = c.sqlite3_finalize(stmt);

            const chain_str = @tagName(chain);
            const tx_hash_hex = try log.transaction_hash.toHex(self.allocator);
            defer self.allocator.free(tx_hash_hex);

            _ = c.sqlite3_bind_text(stmt, 1, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());
            _ = c.sqlite3_bind_text(stmt, 2, subdomain_hex.ptr, @intCast(subdomain_hex.len), SQLITE_TRANSIENT());
            _ = c.sqlite3_bind_text(stmt, 3, labelhash_hex.ptr, @intCast(labelhash_hex.len), SQLITE_TRANSIENT());
            _ = c.sqlite3_bind_text(stmt, 4, parent_hex.ptr, @intCast(parent_hex.len), SQLITE_TRANSIENT());
            _ = c.sqlite3_bind_text(stmt, 5, owner_hex.ptr, @intCast(owner_hex.len), SQLITE_TRANSIENT());
            _ = c.sqlite3_bind_int64(stmt, 6, @intCast(log.block_number));
            _ = c.sqlite3_bind_text(stmt, 7, tx_hash_hex.ptr, @intCast(tx_hash_hex.len), SQLITE_TRANSIENT());
            _ = c.sqlite3_bind_int64(stmt, 8, @intCast(log.log_index));
            _ = c.sqlite3_bind_int64(stmt, 9, std.time.timestamp());

            rc = c.sqlite3_step(stmt);
            if (rc != c.SQLITE_DONE) {
                std.log.err("Failed to insert temp_pre_migration_names: {s}", .{c.sqlite3_errmsg(self.database.db)});
                return error.DatabaseError;
            }
            return; // Don't create name entry yet
        }

        // Post-migration: Check if this is a .eth 2LD registration
        // .eth 2LDs are already handled by BaseRegistrar NameRegistered events
        // Only record true subdomains (non-.eth parent) for backfill
        if (parent_node.eql(constants.WellKnown.eth_namehash)) {
            // This is a .eth 2LD registration (e.g., example.eth)
            // Skip - already handled by BaseRegistrar NameRegistered
            std.log.debug("V1 NewOwner for .eth 2LD (skipping - handled by BaseRegistrar): labelhash={s}", .{labelhash_hex});
            return;
        }

        // This is a true subdomain (e.g., sub.example.eth) - record for backfill
        const tx_hash_hex = try log.transaction_hash.toHex(self.allocator);
        defer self.allocator.free(tx_hash_hex);

        std.log.debug("V1 NewOwner subdomain (label unknown, recording for backfill): namehash={s} labelhash={s} owner={s} tx={s}", .{
            subdomain_hex,
            labelhash_hex,
            owner_hex,
            tx_hash_hex,
        });

        // Record unknown label for later backfill from transaction calldata
        unknown_labels_storage.insertUnknownLabel(
            self.database.db.?,
            null, // name_id - we don't have a name record yet
            log.transaction_hash,
            labelhash,
            subdomain_namehash,
            parent_node,
            owner,
            log.block_number,
        ) catch |err| {
            std.log.err("Failed to insert unknown label: {}", .{err});
            // Continue even if insert fails (might be duplicate)
        };

        // Store event for historical record
        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"parentNode\":\"{s}\",\"labelhash\":\"{s}\",\"subdomain\":\"{s}\",\"owner\":\"{s}\"}}", .{
            parent_hex,
            labelhash_hex,
            subdomain_hex,
            owner_hex,
        });

        const event = models.Event{
            .event_type = .transfer, // Using transfer as closest match
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = null,
            .namehash = subdomain_namehash, // Use subdomain namehash
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);
    }

    /// Handle V1 ENS Registry Transfer event
    /// Transfer(bytes32 indexed node, address owner)
    fn handleV1RegistryTransfer(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        // topics[0] = event signature
        // topics[1] = indexed node (namehash)
        if (log.topics.len < 2) return error.InvalidTopicCount;
        if (log.data.len < 32) return error.InsufficientData;

        const node = log.topics[1];

        // Decode owner address from data
        const owner = try abi.ABI.decodeAddress(log.data, 0);

        const node_hex = try node.toHex(self.allocator);
        defer self.allocator.free(node_hex);
        const owner_hex = try owner.toHex(self.allocator);
        defer self.allocator.free(owner_hex);

        std.log.debug("V1 RegistryTransfer: node={s} owner={s}", .{ node_hex, owner_hex });

        // Store event
        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"node\":\"{s}\",\"owner\":\"{s}\"}}", .{
            node_hex,
            owner_hex,
        });

        const event = models.Event{
            .event_type = .transfer,
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = null,
            .namehash = node,
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);
    }

    /// Handle V1 ENS Registry NewResolver event
    /// NewResolver(bytes32 indexed node, address resolver)
    fn handleV1NewResolver(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        // topics[0] = event signature
        // topics[1] = indexed node (namehash)
        if (log.topics.len < 2) return error.InvalidTopicCount;
        if (log.data.len < 32) return error.InsufficientData;

        const node = log.topics[1];

        // Decode resolver address from data
        const resolver = try abi.ABI.decodeAddress(log.data, 0);

        const node_hex = try node.toHex(self.allocator);
        defer self.allocator.free(node_hex);
        const resolver_hex = try resolver.toHex(self.allocator);
        defer self.allocator.free(resolver_hex);

        std.log.debug("V1 NewResolver: node={s} resolver={s}", .{ node_hex, resolver_hex });

        // Update the name's resolver in the database
        const names_storage = @import("../storage/names.zig");
        try names_storage.updateNameResolver(self.database, node, resolver);

        // Register resolver for indexing
        try self.database.registerResolver(chain, resolver_hex, log.block_number);

        std.log.debug("Updated name resolver: node={s} -> resolver={s}", .{ node_hex, resolver_hex });

        // Store event
        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"node\":\"{s}\",\"resolver\":\"{s}\"}}", .{
            node_hex,
            resolver_hex,
        });

        const event = models.Event{
            .event_type = .resolver_update,
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = null,
            .namehash = node,
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);
    }

    /// Handle V1 ENS Registry NewTTL event
    /// NewTTL(bytes32 indexed node, uint64 ttl)
    fn handleV1NewTTL(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        // topics[0] = event signature
        // topics[1] = indexed node (namehash)
        if (log.topics.len < 2) return error.InvalidTopicCount;
        if (log.data.len < 32) return error.InsufficientData;

        const node = log.topics[1];

        // Decode TTL from data (uint64, but padded to 32 bytes)
        const ttl_u256 = try abi.ABI.decodeUint256(log.data, 0);
        const ttl: u64 = @intCast(ttl_u256);

        const node_hex = try node.toHex(self.allocator);
        defer self.allocator.free(node_hex);

        std.log.debug("V1 NewTTL: node={s} ttl={d}", .{ node_hex, ttl });

        // Store event
        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"node\":\"{s}\",\"ttl\":{d}}}", .{
            node_hex,
            ttl,
        });

        const event = models.Event{
            .event_type = .resolver_update, // Using resolver_update as closest match
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = null,
            .namehash = node,
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);
    }

    /// Handle V1 Name Wrapper NameWrapped event
    /// NameWrapped(bytes32 indexed node, bytes name, address owner, uint32 fuses, uint64 expiry)
    fn handleV1NameWrapped(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        // topics[0] = event signature
        // topics[1] = indexed node (namehash)
        if (log.topics.len < 2) return error.InvalidTopicCount;
        if (log.data.len < 160) return error.InsufficientData;

        const node = log.topics[1];

        // Decode name (bytes - dynamic length)
        const name_bytes = try abi.ABI.decodeBytes(self.allocator, log.data, 0);
        defer self.allocator.free(name_bytes);

        // Decode owner address (offset 32)
        const owner = try abi.ABI.decodeAddress(log.data, 64);

        // Decode fuses (uint32, offset 96, but padded to 32 bytes)
        const fuses_u256 = try abi.ABI.decodeUint256(log.data, 96);
        const fuses: u32 = @intCast(fuses_u256);

        // Decode expiry (uint64, offset 128, but padded to 32 bytes)
        const expiry_u256 = try abi.ABI.decodeUint256(log.data, 128);
        const expiry: u64 = @intCast(expiry_u256);

        const node_hex = try node.toHex(self.allocator);
        defer self.allocator.free(node_hex);
        const owner_hex = try owner.toHex(self.allocator);
        defer self.allocator.free(owner_hex);

        std.log.debug("V1 NameWrapped: node={s} owner={s} fuses={d} expiry={d}", .{ node_hex, owner_hex, fuses, expiry });

        // Update name wrapper state in database
        const names_storage = @import("../storage/names.zig");
        try names_storage.updateNameWrapperState(self.database, node, fuses, @intCast(expiry));
        try names_storage.updateNameOwner(self.database, node, owner);

        std.log.debug("Updated name wrapper state: node={s} wrapped=true fuses={d} expiry={d}", .{ node_hex, fuses, expiry });

        // Store event
        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"node\":\"{s}\",\"owner\":\"{s}\",\"fuses\":{d},\"expiry\":{d}}}", .{
            node_hex,
            owner_hex,
            fuses,
            expiry,
        });

        const event = models.Event{
            .event_type = .transfer,
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = null,
            .namehash = node,
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);
    }

    /// Handle V1 Name Wrapper NameUnwrapped event
    /// NameUnwrapped(bytes32 indexed node, address owner)
    fn handleV1NameUnwrapped(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        // topics[0] = event signature
        // topics[1] = indexed node (namehash)
        if (log.topics.len < 2) return error.InvalidTopicCount;
        if (log.data.len < 32) return error.InsufficientData;

        const node = log.topics[1];

        // Decode owner address from data
        const owner = try abi.ABI.decodeAddress(log.data, 0);

        const node_hex = try node.toHex(self.allocator);
        defer self.allocator.free(node_hex);
        const owner_hex = try owner.toHex(self.allocator);
        defer self.allocator.free(owner_hex);

        std.log.debug("V1 NameUnwrapped: node={s} owner={s}", .{ node_hex, owner_hex });

        // Update name wrapper state in database
        const names_storage = @import("../storage/names.zig");
        try names_storage.updateNameUnwrapperState(self.database, node);
        try names_storage.updateNameOwner(self.database, node, owner);

        std.log.debug("Updated name unwrapper state: node={s} wrapped=false", .{node_hex});

        // Store event
        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"node\":\"{s}\",\"owner\":\"{s}\"}}", .{
            node_hex,
            owner_hex,
        });

        const event = models.Event{
            .event_type = .transfer,
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = null,
            .namehash = node,
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);
    }

    /// Handle V1 Name Wrapper FusesSet event
    /// FusesSet(bytes32 indexed node, uint32 fuses)
    fn handleV1FusesSet(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        // topics[0] = event signature
        // topics[1] = indexed node (namehash)
        if (log.topics.len < 2) return error.InvalidTopicCount;
        if (log.data.len < 32) return error.InsufficientData;

        const node = log.topics[1];

        // Decode fuses from data (uint32, but padded to 32 bytes)
        const fuses_u256 = try abi.ABI.decodeUint256(log.data, 0);
        const fuses: u32 = @intCast(fuses_u256);

        const node_hex = try node.toHex(self.allocator);
        defer self.allocator.free(node_hex);

        std.log.debug("V1 FusesSet: node={s} fuses={d}", .{ node_hex, fuses });

        // Update name wrapper fuses in database
        const names_storage = @import("../storage/names.zig");
        try names_storage.updateNameWrapperFuses(self.database, node, fuses);

        std.log.debug("Updated name wrapper fuses: node={s} fuses={d}", .{ node_hex, fuses });

        // Store event
        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"node\":\"{s}\",\"fuses\":{d}}}", .{
            node_hex,
            fuses,
        });

        const event = models.Event{
            .event_type = .resolver_update, // Using resolver_update as closest match
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = null,
            .namehash = node,
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);
    }

    /// Handle V1 Name Wrapper ExpiryExtended event
    /// ExpiryExtended(bytes32 indexed node, uint64 expiry)
    fn handleV1ExpiryExtended(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        // topics[0] = event signature
        // topics[1] = indexed node (namehash)
        if (log.topics.len < 2) return error.InvalidTopicCount;
        if (log.data.len < 32) return error.InsufficientData;

        const node = log.topics[1];

        // Decode expiry from data (uint64, but padded to 32 bytes)
        const expiry_u256 = try abi.ABI.decodeUint256(log.data, 0);
        const expiry: u64 = @intCast(expiry_u256);

        const node_hex = try node.toHex(self.allocator);
        defer self.allocator.free(node_hex);

        std.log.debug("V1 ExpiryExtended: node={s} expiry={d}", .{ node_hex, expiry });

        // Update name wrapper expiry in database
        const names_storage = @import("../storage/names.zig");
        try names_storage.updateNameWrapperExpiry(self.database, node, @intCast(expiry));

        std.log.debug("Updated name wrapper expiry: node={s} expiry={d}", .{ node_hex, expiry });

        // Store event
        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"node\":\"{s}\",\"expiry\":{d}}}", .{
            node_hex,
            expiry,
        });

        const event = models.Event{
            .event_type = .name_renewed,
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = null,
            .namehash = node,
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);
    }

    /// Handle V1 Base Registrar ERC721 Transfer event
    /// Transfer(address indexed from, address indexed to, uint256 indexed tokenId)
    fn handleV1ERC721Transfer(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        const v1_names = @import("../utils/v1_names.zig");
        const names_storage = @import("../storage/names.zig");

        // topics[0] = event signature
        // topics[1] = indexed from
        // topics[2] = indexed to
        // topics[3] = indexed tokenId
        if (log.topics.len < 4) {
            std.log.warn("V1 ERC721 Transfer event has unexpected topic count: {d}, skipping", .{log.topics.len});
            return;
        }

        const from = try abi.ABI.decodeAddress(&log.topics[1].bytes, 0);
        const to = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);
        const token_id = try abi.ABI.decodeUint256(&log.topics[3].bytes, 0);

        const from_hex = try from.toHex(self.allocator);
        defer self.allocator.free(from_hex);
        const to_hex = try to.toHex(self.allocator);
        defer self.allocator.free(to_hex);

        std.log.debug("V1 ERC721 Transfer: from={s} to={s} tokenId={d}", .{ from_hex, to_hex, token_id });

        // Try to update the name's owner if we know the label
        // Convert token_id to hex for lookup
        var token_id_bytes: [32]u8 = undefined;
        std.mem.writeInt(u256, &token_id_bytes, token_id, .big);
        const token_id_hash = Hash{ .bytes = token_id_bytes };
        const token_id_hex = try token_id_hash.toHex(self.allocator);
        defer self.allocator.free(token_id_hex);

        // Look up the label from our v1_labels table
        if (try v1_names.tokenIdToLabel(self.allocator, self.database, token_id_hex)) |label| {
            defer self.allocator.free(label);

            // Compute the namehash for this name
            const namehash = v1_names.computeEthNamehash(label);

            // Update the name's owner
            try names_storage.updateNameOwner(self.database, namehash, to);

            const full_name = try std.fmt.allocPrint(self.allocator, "{s}.eth", .{label});
            defer self.allocator.free(full_name);

            std.log.debug("Updated V1 name ownership: {s} -> {s}", .{ full_name, to_hex });
        } else {
            // This is expected - not all transfers correspond to known names
            // (e.g., the name might have been registered before we started indexing)
            std.log.debug("V1 Transfer for unknown tokenId {s}, event stored but name not updated", .{token_id_hex});
        }

        // Store event
        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"from\":\"{s}\",\"to\":\"{s}\",\"tokenId\":\"{d}\"}}", .{
            from_hex,
            to_hex,
            token_id,
        });

        const event = models.Event{
            .event_type = .transfer,
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = null,
            .namehash = null,
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);
    }

    /// Handle V1 Base Registrar NameRegistered event
    /// NameRegistered(uint256 indexed id, address indexed owner, uint256 expires)
    fn handleV1BaseRegistrarNameRegistered(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        const v1_names = @import("../utils/v1_names.zig");
        const names_storage = @import("../storage/names.zig");

        // topics[0] = event signature
        // topics[1] = indexed id (tokenId)
        // topics[2] = indexed owner
        if (log.topics.len < 3) {
            std.log.warn("V1 BaseRegistrar NameRegistered event has unexpected topic count: {d}, skipping", .{log.topics.len});
            return;
        }
        if (log.data.len < 32) {
            std.log.warn("V1 BaseRegistrar NameRegistered event has insufficient data: {d} bytes, skipping", .{log.data.len});
            return;
        }

        const token_id = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
        const owner = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);

        // Decode expires from data
        const expires = try abi.ABI.decodeUint256(log.data, 0);

        const owner_hex = try owner.toHex(self.allocator);
        defer self.allocator.free(owner_hex);

        // Convert tokenID to hex for label lookup (big-endian byte order)
        var token_id_bytes: [32]u8 = undefined;
        std.mem.writeInt(u256, &token_id_bytes, token_id, .big);
        const token_id_hash = Hash{ .bytes = token_id_bytes };
        const token_id_hex = try token_id_hash.toHex(self.allocator);
        defer self.allocator.free(token_id_hex);

        // Try to look up the label from v1_labels table
        const maybe_label = try v1_names.tokenIdToLabel(self.allocator, self.database, token_id_hex);

        if (maybe_label) |label| {
            defer self.allocator.free(label);

            // We have the label! Create a complete name record
            const full_name = try std.fmt.allocPrint(self.allocator, "{s}.eth", .{label});
            // Note: full_name is freed by insertEventAndNotify, not here

            const namehash = v1_names.computeEthNamehash(label);
            const label_hash = token_id_hash; // tokenID IS the label hash in V1

            // Compute parent namehash ("eth")
            const eth_node = v1_names.computeEthNamehash("");

            std.log.debug("V1 BaseRegistrar NameRegistered: {s} (id={s}) owner={s} expires={d}", .{
                full_name,
                token_id_hex,
                owner_hex,
                expires,
            });

            // Allocate v1_label_hash (needs to be freed after insertName)
            const v1_label_hash_hex = try label_hash.toHex(self.allocator);
            defer self.allocator.free(v1_label_hash_hex);

            // Create name record
            const name_record = models.Name{
                .name = full_name,
                .namehash = namehash,
                .label = label,
                .label_hash = label_hash,
                .parent_name = "eth",
                .parent_namehash = eth_node,
                .chain = chain,
                .registry = self.config.l1_contracts.ens_registry, // ENS Registry, not Base Registrar!
                .owner = owner,
                .registrant = owner, // Original registrant from V1 NameRegistered
                .resolver = Address.zero, // Will be updated when resolver is set
                .token_id = token_id,
                .canonical_id = token_id, // V1 doesn't use versioning
                .token_version = 0,
                .expiry = @intCast(expires),
                .registry_locked = false, // V1 names don't have registry locking
                .migrated = false, // This is a native V1 name
                .ejected = false, // V1 names on L1 are not ejected
                .created_block = log.block_number,
                .created_at = self.getBlockTimestamp(chain, log.block_number),
                .updated_block = log.block_number,
                .updated_at = std.time.timestamp(),
                .is_wrapped = false, // Not wrapped initially
                .wrapper_fuses = null,
                .wrapper_expiry = null,
                .is_v1_name = true, // This is a V1 .eth name
                .v1_label_hash = v1_label_hash_hex,
            };

            try names_storage.insertName(self.database, name_record);

            // Store event with name and namehash
            const event_data = try std.fmt.allocPrint(self.allocator, "{{\"id\":\"{s}\",\"name\":\"{s}\",\"owner\":\"{s}\",\"expires\":{d}}}", .{
                token_id_hex,
                full_name,
                owner_hex,
                expires,
            });

            const event = models.Event{
                .event_type = .name_registered,
                .chain = chain,
                .block_number = log.block_number,
                .tx_hash = log.transaction_hash,
                .log_index = log.log_index,
                .contract_address = log.address,
                .name = full_name,
                .namehash = namehash,
                .data = event_data,
                .timestamp = self.getBlockTimestamp(chain, log.block_number),
            };

            try self.insertEventAndNotify(event);
        } else {
            // Label not found yet - might come in a later ETH Controller event
            std.log.warn("V1 BaseRegistrar NameRegistered: tokenID {s} label not found (will store event only)", .{token_id_hex});

            // Store event without name/namehash
            const event_data = try std.fmt.allocPrint(self.allocator, "{{\"id\":\"{s}\",\"owner\":\"{s}\",\"expires\":{d}}}", .{
                token_id_hex,
                owner_hex,
                expires,
            });

            const event = models.Event{
                .event_type = .name_registered,
                .chain = chain,
                .block_number = log.block_number,
                .tx_hash = log.transaction_hash,
                .log_index = log.log_index,
                .contract_address = log.address,
                .name = null,
                .namehash = null,
                .data = event_data,
                .timestamp = self.getBlockTimestamp(chain, log.block_number),
            };

            try self.insertEventAndNotify(event);
        }
    }

    /// Handle V1 Base Registrar NameRenewed event
    /// NameRenewed(uint256 indexed id, uint256 expires)
    fn handleV1BaseRegistrarNameRenewed(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        const v1_names = @import("../utils/v1_names.zig");
        const names_storage = @import("../storage/names.zig");

        // topics[0] = event signature
        // topics[1] = indexed id (tokenId)
        if (log.topics.len < 2) return error.InvalidTopicCount;
        if (log.data.len < 32) return error.InsufficientData;

        const token_id = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);

        // Decode expires from data
        const expires = try abi.ABI.decodeUint256(log.data, 0);

        std.log.debug("V1 BaseRegistrar NameRenewed: id={d} expires={d}", .{ token_id, expires });

        // Try to update the name's expiry if we know the label
        // Convert token_id to hex for lookup
        var token_id_bytes: [32]u8 = undefined;
        std.mem.writeInt(u256, &token_id_bytes, token_id, .big);
        const token_id_hash = Hash{ .bytes = token_id_bytes };
        const token_id_hex = try token_id_hash.toHex(self.allocator);
        defer self.allocator.free(token_id_hex);

        // Look up the label from our v1_labels table
        if (try v1_names.tokenIdToLabel(self.allocator, self.database, token_id_hex)) |label| {
            defer self.allocator.free(label);

            // Compute the namehash for this name
            const namehash = v1_names.computeEthNamehash(label);

            // Update the name's expiry
            try names_storage.updateNameExpiry(self.database, namehash, @intCast(expires));

            const full_name = try std.fmt.allocPrint(self.allocator, "{s}.eth", .{label});
            defer self.allocator.free(full_name);

            std.log.debug("Updated V1 name expiry: {s} -> {d}", .{ full_name, expires });
        } else {
            // This is expected - not all renewals correspond to known names
            std.log.debug("V1 NameRenewed for unknown tokenId {s}, event stored but name not updated", .{token_id_hex});
        }

        // Store event
        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"id\":\"{d}\",\"expires\":{d}}}", .{
            token_id,
            expires,
        });

        const event = models.Event{
            .event_type = .name_renewed,
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = null,
            .namehash = null,
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);
    }

    /// Handle V1 Base Registrar ControllerAdded event
    /// ControllerAdded(address indexed controller)
    fn handleV1ControllerAdded(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        _ = chain; // Controller events are operational only, not stored as user-facing events
        const v1_controllers = @import("../storage/v1_controllers.zig");

        // topics[0] = event signature
        // topics[1] = indexed controller address
        if (log.topics.len < 2) {
            std.log.warn("V1 ControllerAdded event has unexpected topic count: {d}, skipping", .{log.topics.len});
            return;
        }

        const controller = try abi.ABI.decodeAddress(&log.topics[1].bytes, 0);
        const controller_hex = try controller.toHex(self.allocator);
        defer self.allocator.free(controller_hex);

        const tx_hash_hex = try log.transaction_hash.toHex(self.allocator);
        defer self.allocator.free(tx_hash_hex);

        std.log.debug("V1 ControllerAdded: controller={s} at block {d}", .{ controller_hex, log.block_number });

        // Store in v1_controllers table (this is purely for operational tracking of which contracts to index)
        try v1_controllers.addController(self.database, controller, log.block_number, tx_hash_hex);
    }

    /// Handle V1 Base Registrar ControllerRemoved event
    /// ControllerRemoved(address indexed controller)
    fn handleV1ControllerRemoved(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        _ = chain; // Controller events are operational only, not stored as user-facing events
        const v1_controllers = @import("../storage/v1_controllers.zig");

        // topics[0] = event signature
        // topics[1] = indexed controller address
        if (log.topics.len < 2) {
            std.log.warn("V1 ControllerRemoved event has unexpected topic count: {d}, skipping", .{log.topics.len});
            return;
        }

        const controller = try abi.ABI.decodeAddress(&log.topics[1].bytes, 0);
        const controller_hex = try controller.toHex(self.allocator);
        defer self.allocator.free(controller_hex);

        const tx_hash_hex = try log.transaction_hash.toHex(self.allocator);
        defer self.allocator.free(tx_hash_hex);

        std.log.debug("V1 ControllerRemoved: controller={s} at block {d}", .{ controller_hex, log.block_number });

        // Update in v1_controllers table (this is purely for operational tracking of which contracts to index)
        try v1_controllers.removeController(self.database, controller, log.block_number, tx_hash_hex);
    }

    /// Handle V1 ETH Registrar Controller NameRegistered event
    /// NameRegistered(string name, bytes32 indexed label, address indexed owner, uint256 baseCost, uint256 premium, uint256 expires)
    fn handleV1ETHControllerNameRegistered(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        const v1_names = @import("../utils/v1_names.zig");

        // topics[0] = event signature
        // topics[1] = indexed label (bytes32)
        // topics[2] = indexed owner (address)
        if (log.topics.len < 3) {
            std.log.warn("V1 ETH Controller NameRegistered event has unexpected topic count: {d}, skipping", .{log.topics.len});
            return;
        }

        const label_hash = log.topics[1];
        const owner = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);

        // Decode data: name (string), cost (uint256), expires (uint256)
        // Note: V1 Controller has only 2 non-indexed parameters (cost, expires), NOT 3
        // Note: name ownership is transferred to the Event struct, so don't free it here
        // name is a dynamic type, so it starts with an offset pointer
        const name = try abi.ABI.decodeString(self.allocator, log.data, 0);

        // cost, expires are after the string data
        // Skip to second word for cost (after string offset pointer and string data)
        var offset: usize = 32; // Skip string offset
        const str_len_offset = try abi.ABI.decodeUint256(log.data, 0);
        offset = @intCast(str_len_offset + 32 + ((name.len + 31) / 32) * 32); // String length + padded string data

        const cost = if (offset < log.data.len) try abi.ABI.decodeUint256(log.data, offset) else 0;
        offset += 32;
        const expires = if (offset < log.data.len) try abi.ABI.decodeUint256(log.data, offset) else 0;

        const owner_hex = try owner.toHex(self.allocator);
        defer self.allocator.free(owner_hex);

        const label_hash_hex = try label_hash.toHex(self.allocator);
        defer self.allocator.free(label_hash_hex);

        std.log.debug("V1 ETH Controller NameRegistered: name={s} label_hash={s} owner={s} expires={d}", .{
            name,
            label_hash_hex,
            owner_hex,
            expires,
        });

        // Store the tokenID→label mapping in the v1_labels table
        const namehash = v1_names.computeEthNamehash(name);
        const tx_hash_hex = try log.transaction_hash.toHex(self.allocator);
        defer self.allocator.free(tx_hash_hex);

        try v1_names.storeTokenIdLabel(
            self.allocator,
            self.database,
            label_hash_hex,
            name,
            namehash,
            log.block_number,
            tx_hash_hex,
            models.EventType.name_registered.toString(),
        );

        // Store event
        const event_data = try std.fmt.allocPrint(
            self.allocator,
            "{{\"name\":\"{s}\",\"label\":\"{s}\",\"owner\":\"{s}\",\"cost\":{d},\"expires\":{d}}}",
            .{ name, label_hash_hex, owner_hex, cost, expires },
        );

        const event = models.Event{
            .event_type = .name_registered,
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = name,
            .namehash = namehash,
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);
    }

    /// Handle V1 ETH Registrar Controller NameRenewed event
    /// NameRenewed(string name, bytes32 indexed label, uint256 cost, uint256 expires)
    fn handleV1ETHControllerNameRenewed(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        const v1_names = @import("../utils/v1_names.zig");

        // topics[0] = event signature
        // topics[1] = indexed label (bytes32)
        if (log.topics.len < 2) {
            std.log.warn("V1 ETH Controller NameRenewed event has unexpected topic count: {d}, skipping", .{log.topics.len});
            return;
        }

        const label_hash = log.topics[1];

        // Decode data: name (string), cost (uint256), expires (uint256)
        // Note: name ownership is transferred to the Event struct, so don't free it here
        const name = try abi.ABI.decodeString(self.allocator, log.data, 0);

        // cost and expires are after the string data
        var offset: usize = 32; // Skip string offset
        const str_len_offset = try abi.ABI.decodeUint256(log.data, 0);
        offset = @intCast(str_len_offset + 32 + ((name.len + 31) / 32) * 32);

        const cost = if (offset < log.data.len) try abi.ABI.decodeUint256(log.data, offset) else 0;
        offset += 32;
        const expires = if (offset < log.data.len) try abi.ABI.decodeUint256(log.data, offset) else 0;

        const label_hash_hex = try label_hash.toHex(self.allocator);
        defer self.allocator.free(label_hash_hex);

        std.log.debug("V1 ETH Controller NameRenewed: name={s} label_hash={s} cost={d} expires={d}", .{
            name,
            label_hash_hex,
            cost,
            expires,
        });

        // Store/update the tokenID→label mapping
        const namehash = v1_names.computeEthNamehash(name);
        const tx_hash_hex = try log.transaction_hash.toHex(self.allocator);
        defer self.allocator.free(tx_hash_hex);

        try v1_names.storeTokenIdLabel(
            self.allocator,
            self.database,
            label_hash_hex,
            name,
            namehash,
            log.block_number,
            tx_hash_hex,
            models.EventType.name_renewed.toString(),
        );

        // Store event
        const event_data = try std.fmt.allocPrint(
            self.allocator,
            "{{\"name\":\"{s}\",\"label\":\"{s}\",\"cost\":{d},\"expires\":{d}}}",
            .{ name, label_hash_hex, cost, expires },
        );

        const event = models.Event{
            .event_type = .name_renewed,
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = name,
            .namehash = namehash,
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);
    }

    /// Handle V1 Reverse Registrar ReverseClaimed event
    /// ReverseClaimed(address indexed addr, bytes32 indexed node)
    fn handleV1ReverseClaimed(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        // topics[0] = event signature
        // topics[1] = indexed addr
        // topics[2] = indexed node
        if (log.topics.len < 3) return error.InvalidTopicCount;

        const addr = try abi.ABI.decodeAddress(&log.topics[1].bytes, 0);
        const node = log.topics[2];

        const addr_hex = try addr.toHex(self.allocator);
        defer self.allocator.free(addr_hex);
        const node_hex = try node.toHex(self.allocator);
        defer self.allocator.free(node_hex);

        std.log.debug("V1 ReverseClaimed: addr={s} node={s}", .{ addr_hex, node_hex });

        // Store event
        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"address\":\"{s}\",\"node\":\"{s}\"}}", .{
            addr_hex,
            node_hex,
        });

        const event = models.Event{
            .event_type = .transfer, // Using transfer as closest match
            .chain = chain,
            .block_number = log.block_number,
            .tx_hash = log.transaction_hash,
            .log_index = log.log_index,
            .contract_address = log.address,
            .name = null,
            .namehash = node,
            .data = event_data,
            .timestamp = self.getBlockTimestamp(chain, log.block_number),
        };

        try self.insertEventAndNotify(event);
    }

    // ========================================================================
    // Temporary Registrar Event Handlers (Pre-V1 Migration)
    // May 2017 (block 3327417) - May 2019 (block 9380410)
    // ========================================================================

    /// Handle Temporary Registrar HashRegistered event
    /// HashRegistered(bytes32 indexed hash, address indexed owner, uint256 value, uint256 registrationDate)
    fn handleTempHashRegistered(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        _ = chain;

        // Validate topics
        if (log.topics.len < 3) {
            std.log.warn("Temp HashRegistered event has unexpected topic count: {d}, skipping", .{log.topics.len});
            return;
        }
        if (log.data.len < 64) {
            std.log.warn("Temp HashRegistered event has insufficient data: {d} bytes, skipping", .{log.data.len});
            return;
        }

        // Decode indexed parameters (from topics)
        const label_hash = log.topics[1];
        const owner = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);

        // Decode non-indexed parameters (from data)
        const value = try abi.ABI.decodeUint256(log.data, 0);
        const registration_date = try abi.ABI.decodeUint256(log.data, 32);

        // Convert to hex strings for database
        const label_hash_hex = try label_hash.toHex(self.allocator);
        defer self.allocator.free(label_hash_hex);

        const owner_hex = try owner.toHex(self.allocator);
        defer self.allocator.free(owner_hex);

        const tx_hash_hex = try log.transaction_hash.toHex(self.allocator);
        defer self.allocator.free(tx_hash_hex);

        // Format value as string (wei)
        var value_buf: [100]u8 = undefined;
        const value_str = try std.fmt.bufPrint(&value_buf, "{d}", .{value});

        std.log.debug("Temp HashRegistered: hash={s} owner={s} value={s} registration_date={d}", .{
            label_hash_hex,
            owner_hex,
            value_str,
            registration_date,
        });

        // Insert into temp_auctions table
        const sql =
            \\INSERT OR REPLACE INTO temp_auctions (
            \\  label_hash, status, registration_date, value_eth, winner_address,
            \\  start_block, start_tx, end_block, end_tx
            \\) VALUES (?, 'finalized', ?, ?, ?, ?, ?, ?, ?)
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.database.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) {
            std.log.err("Failed to prepare temp_auctions insert: {s}", .{c.sqlite3_errmsg(self.database.db)});
            return error.DatabaseError;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, label_hash_hex.ptr, @intCast(label_hash_hex.len), SQLITE_TRANSIENT());
        _ = c.sqlite3_bind_int64(stmt, 2, @intCast(registration_date));
        _ = c.sqlite3_bind_text(stmt, 3, value_str.ptr, @intCast(value_str.len), SQLITE_TRANSIENT());
        _ = c.sqlite3_bind_text(stmt, 4, owner_hex.ptr, @intCast(owner_hex.len), SQLITE_TRANSIENT());
        _ = c.sqlite3_bind_int64(stmt, 5, @intCast(log.block_number));
        _ = c.sqlite3_bind_text(stmt, 6, tx_hash_hex.ptr, @intCast(tx_hash_hex.len), SQLITE_TRANSIENT());
        _ = c.sqlite3_bind_int64(stmt, 7, @intCast(log.block_number));
        _ = c.sqlite3_bind_text(stmt, 8, tx_hash_hex.ptr, @intCast(tx_hash_hex.len), SQLITE_TRANSIENT());

        rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_DONE) {
            std.log.err("Failed to insert temp_auctions: {s}", .{c.sqlite3_errmsg(self.database.db)});
            return error.DatabaseError;
        }
    }

    /// Handle Temporary Registrar AuctionStarted event
    /// AuctionStarted(bytes32 indexed hash, uint256 registrationDate)
    fn handleTempAuctionStarted(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        _ = chain;

        if (log.topics.len < 2) {
            std.log.warn("Temp AuctionStarted event has unexpected topic count: {d}, skipping", .{log.topics.len});
            return;
        }
        if (log.data.len < 32) {
            std.log.warn("Temp AuctionStarted event has insufficient data: {d} bytes, skipping", .{log.data.len});
            return;
        }

        const label_hash = log.topics[1];
        const registration_date = try abi.ABI.decodeUint256(log.data, 0);

        const label_hash_hex = try label_hash.toHex(self.allocator);
        defer self.allocator.free(label_hash_hex);

        const tx_hash_hex = try log.transaction_hash.toHex(self.allocator);
        defer self.allocator.free(tx_hash_hex);

        std.log.debug("Temp AuctionStarted: hash={s} registration_date={d}", .{
            label_hash_hex,
            registration_date,
        });

        const sql =
            \\INSERT OR REPLACE INTO temp_auctions (
            \\  label_hash, status, registration_date, start_block, start_tx
            \\) VALUES (?, 'open', ?, ?, ?)
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.database.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) {
            std.log.err("Failed to prepare temp_auctions insert: {s}", .{c.sqlite3_errmsg(self.database.db)});
            return error.DatabaseError;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, label_hash_hex.ptr, @intCast(label_hash_hex.len), SQLITE_TRANSIENT());
        _ = c.sqlite3_bind_int64(stmt, 2, @intCast(registration_date));
        _ = c.sqlite3_bind_int64(stmt, 3, @intCast(log.block_number));
        _ = c.sqlite3_bind_text(stmt, 4, tx_hash_hex.ptr, @intCast(tx_hash_hex.len), SQLITE_TRANSIENT());

        rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_DONE) {
            std.log.err("Failed to insert temp_auctions: {s}", .{c.sqlite3_errmsg(self.database.db)});
            return error.DatabaseError;
        }
    }

    /// Handle Temporary Registrar NewBid event
    /// NewBid(bytes32 indexed hash, address indexed bidder, uint256 deposit)
    fn handleTempNewBid(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        _ = chain;

        if (log.topics.len < 3) {
            std.log.warn("Temp NewBid event has unexpected topic count: {d}, skipping", .{log.topics.len});
            return;
        }
        if (log.data.len < 32) {
            std.log.warn("Temp NewBid event has insufficient data: {d} bytes, skipping", .{log.data.len});
            return;
        }

        const label_hash = log.topics[1];
        const bidder = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);
        const deposit = try abi.ABI.decodeUint256(log.data, 0);

        const label_hash_hex = try label_hash.toHex(self.allocator);
        defer self.allocator.free(label_hash_hex);

        const bidder_hex = try bidder.toHex(self.allocator);
        defer self.allocator.free(bidder_hex);

        const tx_hash_hex = try log.transaction_hash.toHex(self.allocator);
        defer self.allocator.free(tx_hash_hex);

        var deposit_buf: [100]u8 = undefined;
        const deposit_str = try std.fmt.bufPrint(&deposit_buf, "{d}", .{deposit});

        std.log.debug("Temp NewBid: hash={s} bidder={s} deposit={s}", .{
            label_hash_hex,
            bidder_hex,
            deposit_str,
        });

        // Generate sealed bid hash (simplified - in real contract it's keccak256(labelhash, bidder, value, salt))
        // For indexing purposes, we use a placeholder
        const sealed_bid_hash = try std.fmt.allocPrint(self.allocator, "0x{s}{s}", .{ label_hash_hex[2..18], bidder_hex[2..18] });
        defer self.allocator.free(sealed_bid_hash);

        const sql =
            \\INSERT OR IGNORE INTO temp_bids (
            \\  label_hash, bidder_address, sealed_bid_hash, deposit_eth,
            \\  block_number, tx_hash, log_index
            \\) VALUES (?, ?, ?, ?, ?, ?, ?)
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.database.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) {
            std.log.err("Failed to prepare temp_bids insert: {s}", .{c.sqlite3_errmsg(self.database.db)});
            return error.DatabaseError;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, label_hash_hex.ptr, @intCast(label_hash_hex.len), SQLITE_TRANSIENT());
        _ = c.sqlite3_bind_text(stmt, 2, bidder_hex.ptr, @intCast(bidder_hex.len), SQLITE_TRANSIENT());
        _ = c.sqlite3_bind_text(stmt, 3, sealed_bid_hash.ptr, @intCast(sealed_bid_hash.len), SQLITE_TRANSIENT());
        _ = c.sqlite3_bind_text(stmt, 4, deposit_str.ptr, @intCast(deposit_str.len), SQLITE_TRANSIENT());
        _ = c.sqlite3_bind_int64(stmt, 5, @intCast(log.block_number));
        _ = c.sqlite3_bind_text(stmt, 6, tx_hash_hex.ptr, @intCast(tx_hash_hex.len), SQLITE_TRANSIENT());
        _ = c.sqlite3_bind_int64(stmt, 7, @intCast(log.log_index));

        rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_DONE) {
            std.log.err("Failed to insert temp_bids: {s}", .{c.sqlite3_errmsg(self.database.db)});
            return error.DatabaseError;
        }
    }

    /// Handle Temporary Registrar BidRevealed event
    /// BidRevealed(bytes32 indexed hash, address indexed owner, uint256 value, uint8 status)
    fn handleTempBidRevealed(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        _ = chain;

        if (log.topics.len < 3) {
            std.log.warn("Temp BidRevealed event has unexpected topic count: {d}, skipping", .{log.topics.len});
            return;
        }
        if (log.data.len < 64) {
            std.log.warn("Temp BidRevealed event has insufficient data: {d} bytes, skipping", .{log.data.len});
            return;
        }

        const label_hash = log.topics[1];
        const bidder = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);
        const value = try abi.ABI.decodeUint256(log.data, 0);
        const status = try abi.ABI.decodeUint256(log.data, 32);

        const label_hash_hex = try label_hash.toHex(self.allocator);
        defer self.allocator.free(label_hash_hex);

        const bidder_hex = try bidder.toHex(self.allocator);
        defer self.allocator.free(bidder_hex);

        const tx_hash_hex = try log.transaction_hash.toHex(self.allocator);
        defer self.allocator.free(tx_hash_hex);

        var value_buf: [100]u8 = undefined;
        const value_str = try std.fmt.bufPrint(&value_buf, "{d}", .{value});

        std.log.debug("Temp BidRevealed: hash={s} bidder={s} value={s} status={d}", .{
            label_hash_hex,
            bidder_hex,
            value_str,
            status,
        });

        const sql =
            \\INSERT OR IGNORE INTO temp_bid_reveals (
            \\  label_hash, bidder_address, revealed_value_eth, status,
            \\  block_number, tx_hash, log_index
            \\) VALUES (?, ?, ?, ?, ?, ?, ?)
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.database.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) {
            std.log.err("Failed to prepare temp_bid_reveals insert: {s}", .{c.sqlite3_errmsg(self.database.db)});
            return error.DatabaseError;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, label_hash_hex.ptr, @intCast(label_hash_hex.len), SQLITE_TRANSIENT());
        _ = c.sqlite3_bind_text(stmt, 2, bidder_hex.ptr, @intCast(bidder_hex.len), SQLITE_TRANSIENT());
        _ = c.sqlite3_bind_text(stmt, 3, value_str.ptr, @intCast(value_str.len), SQLITE_TRANSIENT());
        _ = c.sqlite3_bind_int64(stmt, 4, @intCast(status));
        _ = c.sqlite3_bind_int64(stmt, 5, @intCast(log.block_number));
        _ = c.sqlite3_bind_text(stmt, 6, tx_hash_hex.ptr, @intCast(tx_hash_hex.len), SQLITE_TRANSIENT());
        _ = c.sqlite3_bind_int64(stmt, 7, @intCast(log.log_index));

        rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_DONE) {
            std.log.err("Failed to insert temp_bid_reveals: {s}", .{c.sqlite3_errmsg(self.database.db)});
            return error.DatabaseError;
        }
    }

    /// Handle Temporary Registrar HashReleased event
    /// HashReleased(bytes32 indexed hash, uint256 value)
    fn handleTempHashReleased(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        _ = chain;

        if (log.topics.len < 2) {
            std.log.warn("Temp HashReleased event has unexpected topic count: {d}, skipping", .{log.topics.len});
            return;
        }
        if (log.data.len < 32) {
            std.log.warn("Temp HashReleased event has insufficient data: {d} bytes, skipping", .{log.data.len});
            return;
        }

        const label_hash = log.topics[1];
        const value = try abi.ABI.decodeUint256(log.data, 0);

        const label_hash_hex = try label_hash.toHex(self.allocator);
        defer self.allocator.free(label_hash_hex);

        const tx_hash_hex = try log.transaction_hash.toHex(self.allocator);
        defer self.allocator.free(tx_hash_hex);

        var value_buf: [100]u8 = undefined;
        const value_str = try std.fmt.bufPrint(&value_buf, "{d}", .{value});

        std.log.debug("Temp HashReleased: hash={s} value={s}", .{
            label_hash_hex,
            value_str,
        });

        const sql =
            \\UPDATE temp_auctions SET
            \\  status = 'released',
            \\  end_block = ?,
            \\  end_tx = ?
            \\WHERE label_hash = ?
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.database.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) {
            std.log.err("Failed to prepare temp_auctions update: {s}", .{c.sqlite3_errmsg(self.database.db)});
            return error.DatabaseError;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_int64(stmt, 1, @intCast(log.block_number));
        _ = c.sqlite3_bind_text(stmt, 2, tx_hash_hex.ptr, @intCast(tx_hash_hex.len), SQLITE_TRANSIENT());
        _ = c.sqlite3_bind_text(stmt, 3, label_hash_hex.ptr, @intCast(label_hash_hex.len), SQLITE_TRANSIENT());

        rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_DONE) {
            std.log.err("Failed to update temp_auctions: {s}", .{c.sqlite3_errmsg(self.database.db)});
            return error.DatabaseError;
        }
    }

    /// Handle Temporary Registrar HashInvalidated event
    /// HashInvalidated(bytes32 indexed hash, string indexed name, uint256 value, uint256 registrationDate)
    fn handleTempHashInvalidated(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
        _ = chain;

        if (log.topics.len < 3) {
            std.log.warn("Temp HashInvalidated event has unexpected topic count: {d}, skipping", .{log.topics.len});
            return;
        }
        if (log.data.len < 64) {
            std.log.warn("Temp HashInvalidated event has insufficient data: {d} bytes, skipping", .{log.data.len});
            return;
        }

        const label_hash = log.topics[1];
        // Note: name is indexed but as a string, so it's hashed in topics[2]
        // We need to decode the actual name from data
        const value = try abi.ABI.decodeUint256(log.data, 0);
        const registration_date = try abi.ABI.decodeUint256(log.data, 32);

        const label_hash_hex = try label_hash.toHex(self.allocator);
        defer self.allocator.free(label_hash_hex);

        const tx_hash_hex = try log.transaction_hash.toHex(self.allocator);
        defer self.allocator.free(tx_hash_hex);

        var value_buf: [100]u8 = undefined;
        const value_str = try std.fmt.bufPrint(&value_buf, "{d}", .{value});

        std.log.debug("Temp HashInvalidated: hash={s} value={s} registration_date={d}", .{
            label_hash_hex,
            value_str,
            registration_date,
        });

        // Try to decode name from data (it's after the two uint256 values)
        const name = if (log.data.len > 64) blk: {
            break :blk abi.ABI.decodeString(self.allocator, log.data, 64) catch "unknown";
        } else "unknown";
        defer if (log.data.len > 64) self.allocator.free(name);

        const sql =
            \\INSERT OR IGNORE INTO temp_invalidations (
            \\  label_hash, name, registration_date, invalidation_block, invalidation_tx, log_index
            \\) VALUES (?, ?, ?, ?, ?, ?)
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.database.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) {
            std.log.err("Failed to prepare temp_invalidations insert: {s}", .{c.sqlite3_errmsg(self.database.db)});
            return error.DatabaseError;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, label_hash_hex.ptr, @intCast(label_hash_hex.len), SQLITE_TRANSIENT());
        _ = c.sqlite3_bind_text(stmt, 2, name.ptr, @intCast(name.len), SQLITE_TRANSIENT());
        _ = c.sqlite3_bind_int64(stmt, 3, @intCast(registration_date));
        _ = c.sqlite3_bind_int64(stmt, 4, @intCast(log.block_number));
        _ = c.sqlite3_bind_text(stmt, 5, tx_hash_hex.ptr, @intCast(tx_hash_hex.len), SQLITE_TRANSIENT());
        _ = c.sqlite3_bind_int64(stmt, 6, @intCast(log.log_index));

        rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_DONE) {
            std.log.err("Failed to insert temp_invalidations: {s}", .{c.sqlite3_errmsg(self.database.db)});
            return error.DatabaseError;
        }
    }

    /// Backfill pre-migration names with labels from v1_labels table
    /// This runs once after initial sync completes and v1_labels is populated
    fn backfillPreMigrationNames(self: *Indexer) !void {
        const v1_names = @import("../utils/v1_names.zig");
        const names_storage = @import("../storage/names.zig");

        // Check if backfill already completed
        const check_sql = "SELECT completed FROM backfill_status WHERE task = 'pre_migration_names'";
        var check_stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.database.db, check_sql.ptr, @intCast(check_sql.len), &check_stmt, null);
        if (rc == c.SQLITE_OK) {
            defer _ = c.sqlite3_finalize(check_stmt);
            if (c.sqlite3_step(check_stmt) == c.SQLITE_ROW) {
                const completed = c.sqlite3_column_int(check_stmt, 0);
                if (completed == 1) {
                    std.log.info("Pre-migration names backfill already completed, skipping", .{});
                    return;
                }
            }
        }

        std.log.info("Starting pre-migration names backfill...", .{});

        // Query to join temp_pre_migration_names with v1_labels to resolve labels
        const query_sql =
            \\SELECT t.namehash, t.label_hash, t.parent_node, t.owner, t.block_number,
            \\       t.tx_hash, t.log_index, t.created_at, v.label
            \\FROM temp_pre_migration_names t
            \\JOIN v1_labels v ON t.label_hash = v.token_id
        ;

        var query_stmt: ?*c.sqlite3_stmt = null;
        rc = c.sqlite3_prepare_v2(self.database.db, query_sql.ptr, @intCast(query_sql.len), &query_stmt, null);
        if (rc != c.SQLITE_OK) {
            std.log.err("Failed to prepare backfill query: {s}", .{c.sqlite3_errmsg(self.database.db)});
            return error.DatabaseError;
        }
        defer _ = c.sqlite3_finalize(query_stmt);

        var count: usize = 0;
        while (c.sqlite3_step(query_stmt) == c.SQLITE_ROW) {
            // Extract row data
            const namehash_ptr = c.sqlite3_column_text(query_stmt, 0);
            const label_hash_ptr = c.sqlite3_column_text(query_stmt, 1);
            const parent_node_ptr = c.sqlite3_column_text(query_stmt, 2);
            const owner_ptr = c.sqlite3_column_text(query_stmt, 3);
            const block_number = c.sqlite3_column_int64(query_stmt, 4);
            const tx_hash_ptr = c.sqlite3_column_text(query_stmt, 5);
            _ = c.sqlite3_column_int64(query_stmt, 6); // log_index - not needed for name creation
            const created_at = c.sqlite3_column_int64(query_stmt, 7);
            const label_ptr = c.sqlite3_column_text(query_stmt, 8);

            if (namehash_ptr == null or label_hash_ptr == null or parent_node_ptr == null or
                owner_ptr == null or tx_hash_ptr == null or label_ptr == null) {
                std.log.warn("Skipping row with null value in backfill", .{});
                continue;
            }

            const label = std.mem.span(label_ptr);
            const label_hash_str = std.mem.span(label_hash_ptr);
            const owner_str = std.mem.span(owner_ptr);

            // Allocate strings that will be owned by the Name struct
            const full_name = try std.fmt.allocPrint(self.allocator, "{s}.eth", .{label});
            errdefer self.allocator.free(full_name);

            const label_copy = try self.allocator.dupe(u8, label);
            errdefer self.allocator.free(label_copy);

            const parent_name_copy = try self.allocator.dupe(u8, "eth");
            errdefer self.allocator.free(parent_name_copy);

            // Compute hashes
            const namehash = v1_names.computeEthNamehash(label);
            const label_hash = v1_names.computeLabelHash(label);

            // ETH node hash (parent)
            const parent_namehash = try Hash.fromHex("93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae");

            // Parse addresses
            const owner = try Address.fromHex(owner_str);

            // ENS Registry contract address (where these NewOwner events came from)
            const registry = try Address.fromHex("00000000000C2E074eC69A0dFb2997BA6C7d2e1e");

            // Parse token_id from label_hash hex string to u256
            const token_id = try std.fmt.parseInt(u256, if (std.mem.startsWith(u8, label_hash_str, "0x")) label_hash_str[2..] else label_hash_str, 16);

            // Canonical ID is token_id with lower 32 bits cleared (for V1, just use token_id)
            const canonical_id = token_id;

            // V1 label hash for backfilling
            const v1_label_hash = try self.allocator.dupe(u8, label_hash_str);
            errdefer self.allocator.free(v1_label_hash);

            // Create the name entry
            var name = models.Name{
                .chain = .l1,
                .name = full_name,
                .namehash = namehash,
                .label = label_copy,
                .label_hash = label_hash,
                .parent_name = parent_name_copy,
                .parent_namehash = parent_namehash,
                .registry = registry,
                .owner = owner,
                .registrant = owner, // Original registrant from backfilled data
                .resolver = Address.zero,
                .token_id = token_id,
                .canonical_id = canonical_id,
                .token_version = 1,
                .expiry = 0,
                .registry_locked = false,
                .migrated = false,
                .ejected = false,
                .created_block = @intCast(block_number),
                .created_at = @intCast(created_at),
                .updated_block = @intCast(block_number),
                .updated_at = @intCast(created_at),
                .is_wrapped = false,
                .wrapper_fuses = null,
                .wrapper_expiry = null,
                .is_v1_name = true,
                .v1_label_hash = v1_label_hash,
            };

            // Check if name already exists (from V1 events processed during sync)
            const existing_name = names_storage.getNameByNamehash(self.database, namehash) catch null;

            if (existing_name) |_| {
                // Name exists from V1 events - only update creation date if ours is earlier
                names_storage.updateNameCreationDateIfEarlier(
                    self.database,
                    namehash,
                    @intCast(block_number),
                    @intCast(created_at),
                ) catch |err| {
                    std.log.warn("Failed to update creation date for {s}: {}", .{ full_name, err });
                    name.deinit(self.allocator);
                    continue;
                };
                std.log.debug("Updated creation date for existing name: {s}", .{full_name});
            } else {
                // Name doesn't exist - create it
                names_storage.insertName(self.database, name) catch |err| {
                    std.log.warn("Failed to backfill name {s}: {}", .{ name.name.?, err });
                    name.deinit(self.allocator);
                    continue;
                };
                std.log.debug("Created new name from backfill: {s}", .{full_name});
            }

            // Record migration history entry
            const tx_hash_str = std.mem.span(tx_hash_ptr);
            const namehash_hex = try namehash.toHex(self.allocator);
            errdefer self.allocator.free(namehash_hex);

            const history_sql =
                \\INSERT OR IGNORE INTO name_history
                \\(chain, namehash, name, change_type, old_value, new_value, block_number, tx_hash, log_index, timestamp)
                \\VALUES (?, ?, ?, 'migration', NULL, 'Migrated from temporary registrar', ?, ?, 0, ?)
            ;

            var history_stmt: ?*c.sqlite3_stmt = null;
            rc = c.sqlite3_prepare_v2(self.database.db, history_sql.ptr, @intCast(history_sql.len), &history_stmt, null);
            if (rc == c.SQLITE_OK) {
                defer _ = c.sqlite3_finalize(history_stmt);

                const chain_str = "l1";
                _ = c.sqlite3_bind_text(history_stmt, 1, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());
                _ = c.sqlite3_bind_text(history_stmt, 2, namehash_hex.ptr, @intCast(namehash_hex.len), SQLITE_TRANSIENT());
                _ = c.sqlite3_bind_text(history_stmt, 3, full_name.ptr, @intCast(full_name.len), SQLITE_TRANSIENT());
                _ = c.sqlite3_bind_int64(history_stmt, 4, @intCast(block_number));
                _ = c.sqlite3_bind_text(history_stmt, 5, tx_hash_str.ptr, @intCast(tx_hash_str.len), SQLITE_TRANSIENT());
                _ = c.sqlite3_bind_int64(history_stmt, 6, created_at);

                if (c.sqlite3_step(history_stmt) != c.SQLITE_DONE) {
                    std.log.warn("Failed to insert migration history for {s}", .{full_name});
                }
            }

            // Free namehash_hex immediately after use (not deferred to function end)
            self.allocator.free(namehash_hex);

            // Free allocated memory
            name.deinit(self.allocator);

            count += 1;
            if (count % 100 == 0) {
                std.log.info("Backfilled {d} pre-migration names...", .{count});
            }
        }

        std.log.info("Pre-migration names backfill complete: {d} names created", .{count});

        // Mark backfill as completed
        const mark_sql =
            \\INSERT OR REPLACE INTO backfill_status (task, completed, completed_at, records_processed)
            \\VALUES ('pre_migration_names', 1, ?, ?)
        ;
        var mark_stmt: ?*c.sqlite3_stmt = null;
        rc = c.sqlite3_prepare_v2(self.database.db, mark_sql.ptr, @intCast(mark_sql.len), &mark_stmt, null);
        if (rc == c.SQLITE_OK) {
            defer _ = c.sqlite3_finalize(mark_stmt);
            _ = c.sqlite3_bind_int64(mark_stmt, 1, std.time.timestamp());
            _ = c.sqlite3_bind_int64(mark_stmt, 2, @intCast(count));
            _ = c.sqlite3_step(mark_stmt);
        }
    }

    /// Backfill unknown subdomain labels from transaction calldata
    /// This runs after initial sync completes to resolve labels that weren't in events
    pub fn backfillUnknownLabels(self: *Indexer) !void {
        // Get statistics first
        var label_backfill = LabelBackfill.init(self.allocator, self.l1_client, self.database);
        const stats = try label_backfill.getStats();

        if (stats.total == 0) {
            std.log.info("No unknown labels to backfill", .{});
            return;
        }

        std.log.info("Starting unknown labels backfill...", .{});
        std.log.info("  Total unknown labels: {d}", .{stats.total});
        std.log.info("  Pending (0 attempts): {d}", .{stats.pending});
        std.log.info("  Retrying (1-2 attempts): {d}", .{stats.retrying});
        std.log.info("  Failed (3+ attempts): {d}", .{stats.failed});

        const resolved = try label_backfill.backfillAll();

        std.log.info("Unknown labels backfill complete: {d} labels resolved", .{resolved});

        // Get final stats
        const final_stats = try label_backfill.getStats();
        if (final_stats.total > 0) {
            std.log.warn("  Remaining unknown labels: {d}", .{final_stats.total});
            std.log.warn("  Failed after 3 attempts: {d}", .{final_stats.failed});
        }
    }
};
