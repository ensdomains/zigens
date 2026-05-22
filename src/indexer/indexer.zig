const std = @import("std");
const config = @import("../config.zig");
const constants = @import("../constants.zig");
const db = @import("../storage/database.zig");
const rpc = @import("../rpc/client.zig");
const models = @import("../types/models.zig");
const abi = @import("abi.zig");
const Hash = @import("../types/hash.zig").Hash;
const Address = @import("../types/address.zig").Address;
const webhooks = @import("../webhooks/manager.zig");
const RateLimiter = @import("../rate_limiter.zig").RateLimiter;
const NetworkHealth = @import("../utils/network_health.zig").NetworkHealth;
const status_mod = @import("../server/status.zig");
const IndexerStatus = status_mod.IndexerStatus;
const handlers_v2_registry = @import("v2/handlers_registry.zig");
const handlers_v2_resolver = @import("v2/handlers_resolver.zig");
const event_fetchers = @import("event_fetchers.zig");
const v1_indexing = @import("v1/indexing.zig");
const handlers_v1 = @import("v1/handlers.zig");
const handlers_v1_temp = @import("v1/handlers_temp.zig");
const backfill_mod = @import("v1/backfill.zig");
const replay_mod = @import("replay.zig");
pub const utils = @import("utils.zig");
const WriteBuffer = @import("write_buffer.zig").WriteBuffer;
const Rainbow = @import("../rainbow/rainbow.zig").Rainbow;

pub const Indexer = struct {
    allocator: std.mem.Allocator,
    config: config.Config,
    database: *db.Database,
    v1_client: *rpc.Client,
    shared_http_client: *std.http.Client,
    webhook_manager: ?*webhooks.WebhookManager,
    should_stop: std.atomic.Value(bool),
    rate_limiter: RateLimiter,
    blocks_since_checkpoint: u64,
    initial_sync_complete: std.atomic.Value(bool),
    v1_network_health: NetworkHealth,
    end_block: ?u64,
    indexer_status: ?*IndexerStatus,
    status_server: ?*status_mod.StatusServer,
    // Block timestamp cache to avoid repeated RPC calls
    block_timestamp_cache: std.AutoHashMap(u64, i64),
    // Cached active V1 controllers (invalidated on ControllerAdded/Removed)
    v1_active_controllers: ?[]Address = null,
    // Cached V1 token_id → label mappings (populated on miss from DB)
    v1_label_cache: std.StringHashMap([]const u8),
    // Track block hash from processed logs to avoid extra getBlockByNumber RPC calls
    last_seen_block_hash: ?Hash = null,
    last_seen_block_number: u64 = 0,
    // Write buffer for batching DB operations during chunk processing
    write_buffer: WriteBuffer,
    // Rainbow table for resolving labelhashes to labels (optional)
    rainbow: ?Rainbow = null,
    // Cached namehash("eth") — constant value used by every V2 LabelRegistered/
    // NameRegistered/LabelReserved handler. Two keccak rounds saved per event.
    eth_namehash: Hash,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config, database: *db.Database, end_block: ?u64) !Indexer {
        // Create ONE shared HTTP client
        const http_client = try allocator.create(std.http.Client);
        http_client.* = std.http.Client{ .allocator = allocator };
        errdefer {
            http_client.deinit();
            allocator.destroy(http_client);
        }

        const v1_client = try rpc.Client.initWithSharedHttpClient(allocator, cfg.rpc_url, http_client);
        errdefer v1_client.deinit();

        var webhook_manager: ?*webhooks.WebhookManager = null;
        if (cfg.webhooks_enabled) {
            webhook_manager = try webhooks.WebhookManager.init(allocator, cfg.webhook_db_path, cfg.webhook_max_retries, 100); // 100ms rate limit per endpoint (10 req/sec)
            // Workers disabled during indexing to avoid SQLite contention
            // Webhooks are queued and can be processed separately
            // try webhook_manager.?.startWorkers(8);
        }

        // Optionally create status tracking and server if configured
        var indexer_status: ?*IndexerStatus = null;
        var status_server: ?*status_mod.StatusServer = null;

        if (cfg.status_port) |port| {
            // Get current block from database (resume point) or use start_block
            const current_block = try database.getSyncState(.v1) orelse cfg.start_block;

            // Fetch target block from protocol if not specified
            const target_block = if (end_block) |eb| eb else blk: {
                const current = v1_client.getBlockNumber() catch |err| {
                    std.log.warn("Failed to fetch current block number from RPC: {any}. Using start_block as fallback.", .{err});
                    break :blk cfg.start_block;
                };
                std.log.info("Fetched current block from protocol: {d}", .{current});
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

        // Load rainbow table (optional — graceful fallback if not available)
        const rainbow = Rainbow.init(allocator, cfg.rainbow_path) catch |err| blk: {
            std.log.info("Rainbow table not available ({any}), label resolution will use [labelhash] format", .{err});
            break :blk null;
        };

        return Indexer{
            .allocator = allocator,
            .config = cfg,
            .database = database,
            .v1_client = v1_client,
            .shared_http_client = http_client,
            .webhook_manager = webhook_manager,
            .should_stop = std.atomic.Value(bool).init(false),
            .rate_limiter = RateLimiter.init(cfg.rate_limit_per_second, cfg.rate_limit_per_second),
            .blocks_since_checkpoint = 0,
            .initial_sync_complete = std.atomic.Value(bool).init(false),
            .v1_network_health = NetworkHealth.init(allocator, cfg.rpc_url, constants.Timing.network_check_interval_ms),
            .end_block = end_block,
            .indexer_status = indexer_status,
            .status_server = status_server,
            .block_timestamp_cache = std.AutoHashMap(u64, i64).init(allocator),
            .v1_label_cache = std.StringHashMap([]const u8).init(allocator),
            .write_buffer = WriteBuffer.init(allocator),
            .rainbow = rainbow,
            .eth_namehash = try @import("../types/hash.zig").namehash(allocator, "eth"),
        };
    }

    /// Initialize indexer for a single protocol (V1 or V2 only)
    pub fn initSingleProtocol(allocator: std.mem.Allocator, cfg: config.Config, database: *db.Database, protocol: models.Protocol, end_block: ?u64) !Indexer {
        const http_client = try allocator.create(std.http.Client);
        http_client.* = std.http.Client{ .allocator = allocator };
        errdefer {
            http_client.deinit();
            allocator.destroy(http_client);
        }

        const client = try rpc.Client.initWithSharedHttpClient(allocator, cfg.rpc_url, http_client);
        errdefer client.deinit();

        var webhook_manager: ?*webhooks.WebhookManager = null;
        if (cfg.webhooks_enabled) {
            webhook_manager = try webhooks.WebhookManager.init(allocator, cfg.webhook_db_path, cfg.webhook_max_retries, 100); // 100ms rate limit per endpoint (10 req/sec)
            // Workers disabled during indexing to avoid SQLite contention
            // Webhooks are queued and can be processed separately
            // try webhook_manager.?.startWorkers(8);
        }

        // Optionally create status tracking and server if configured
        var indexer_status: ?*IndexerStatus = null;
        var status_server: ?*status_mod.StatusServer = null;

        if (cfg.status_port) |port| {
            // Get current block from database (resume point) or use appropriate deployment block
            const deployment_block = switch (protocol) {
                .v1 => cfg.v1_contracts.v1_deployment_block,
                .v2 => cfg.v2_contracts.v2_deployment_block,
            };
            const current_block = try database.getSyncState(protocol) orelse deployment_block;

            // Fetch target block from protocol if not specified
            const target_block = if (end_block) |eb| eb else blk: {
                const current = client.getBlockNumber() catch |err| {
                    std.log.warn("Failed to fetch current block number from RPC: {any}. Using deployment block as fallback.", .{err});
                    break :blk deployment_block;
                };
                std.log.info("Fetched current block from protocol: {d}", .{current});
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

        // Load rainbow table (optional — graceful fallback if not available)
        const rainbow = Rainbow.init(allocator, cfg.rainbow_path) catch |err| blk: {
            std.log.info("Rainbow table not available ({any}), label resolution will use [labelhash] format", .{err});
            break :blk null;
        };

        return Indexer{
            .allocator = allocator,
            .config = cfg,
            .database = database,
            .v1_client = client,
            .shared_http_client = http_client,
            .webhook_manager = webhook_manager,
            .should_stop = std.atomic.Value(bool).init(false),
            .rate_limiter = RateLimiter.init(cfg.rate_limit_per_second, cfg.rate_limit_per_second),
            .blocks_since_checkpoint = 0,
            .initial_sync_complete = std.atomic.Value(bool).init(false),
            .v1_network_health = NetworkHealth.init(allocator, cfg.rpc_url, constants.Timing.network_check_interval_ms),
            .end_block = end_block,
            .indexer_status = indexer_status,
            .status_server = status_server,
            .block_timestamp_cache = std.AutoHashMap(u64, i64).init(allocator),
            .v1_label_cache = std.StringHashMap([]const u8).init(allocator),
            .write_buffer = WriteBuffer.init(allocator),
            .rainbow = rainbow,
            .eth_namehash = try @import("../types/hash.zig").namehash(allocator, "eth"),
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

        self.v1_client.deinit();
        self.shared_http_client.deinit();
        self.allocator.destroy(self.shared_http_client);
        if (self.webhook_manager) |wm| {
            wm.deinit();
        }
        self.block_timestamp_cache.deinit();
        self.write_buffer.deinit();
        if (self.rainbow) |*r| r.deinit();

        // Free cached controllers
        if (self.v1_active_controllers) |controllers| {
            self.allocator.free(controllers);
        }

        // Free cached v1 labels
        var label_it = self.v1_label_cache.iterator();
        while (label_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.v1_label_cache.deinit();
    }

    /// Invalidate the cached active controllers list (call after ControllerAdded/Removed)
    pub fn invalidateControllerCache(self: *Indexer) void {
        if (self.v1_active_controllers) |controllers| {
            self.allocator.free(controllers);
            self.v1_active_controllers = null;
        }
    }

    /// Get active controllers, loading from DB on first access or after invalidation
    pub fn getOrLoadActiveControllers(self: *Indexer) ![]const Address {
        if (self.v1_active_controllers) |controllers| {
            return controllers;
        }
        const v1_controllers = @import("../storage/v1_controllers.zig");
        const controllers = try v1_controllers.getActiveControllers(self.allocator, self.database);
        self.v1_active_controllers = controllers;
        return controllers;
    }

    /// Look up a label from v1_label_cache, falling back to DB on miss
    pub fn getCachedV1Label(self: *Indexer, token_id_hex: []const u8) !?[]const u8 {
        // Check cache first
        if (self.v1_label_cache.get(token_id_hex)) |label| {
            return label;
        }

        // Cache miss - query DB
        const v1_names = @import("../utils/v1_names.zig");
        const label = try v1_names.tokenIdToLabel(self.allocator, self.database, token_id_hex) orelse return null;

        // Store in cache (need to dupe the key since token_id_hex may be temporary)
        const key_copy = try self.allocator.dupe(u8, token_id_hex);
        errdefer self.allocator.free(key_copy);
        try self.v1_label_cache.put(key_copy, label);

        return label;
    }

    /// Add a label to the v1_label_cache (called when storeTokenIdLabel succeeds)
    pub fn putCachedV1Label(self: *Indexer, token_id_hex: []const u8, label: []const u8) !void {
        // Check if already cached
        if (self.v1_label_cache.contains(token_id_hex)) return;

        const key_copy = try self.allocator.dupe(u8, token_id_hex);
        errdefer self.allocator.free(key_copy);
        const val_copy = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(val_copy);
        try self.v1_label_cache.put(key_copy, val_copy);
    }

    /// Resolve a labelhash to its plaintext label using the rainbow table.
    /// Returns owned string (caller must free) or null if not found.
    pub fn resolveLabel(self: *Indexer, labelhash: Hash) ?[]const u8 {
        var r = self.rainbow orelse return null;
        return r.lookup(labelhash.bytes) catch null;
    }

    /// Replay all stored events to rebuild the names table (--backfill mode).
    pub const replayEventsToRebuildNames = replay_mod.replayEventsToRebuildNames;

    /// Track block hash from a processed log (for reorg detection without extra RPC calls)
    pub fn trackBlockHash(self: *Indexer, log_block_number: u64, log_block_hash: ?Hash) void {
        if (log_block_hash) |bh| {
            if (log_block_number >= self.last_seen_block_number) {
                self.last_seen_block_hash = bh;
                self.last_seen_block_number = log_block_number;
            }
        }
    }

    /// Reset block hash tracking (call before each outer batch)
    pub fn resetBlockHashTracking(self: *Indexer) void {
        self.last_seen_block_hash = null;
        self.last_seen_block_number = 0;
    }

    /// Get block timestamp, using log's timestamp if available, then cache, then RPC fallback
    /// If known_timestamp is provided (from RPC provider's blockTimestamp field), use it directly
    pub fn getBlockTimestamp(self: *Indexer, protocol: models.Protocol, block_number: u64, known_timestamp: ?u64) i64 {
        // If provider included timestamp in log response, use it directly (fastest path)
        if (known_timestamp) |ts| {
            const timestamp: i64 = @intCast(ts);
            // Also cache it for other events in the same block
            self.block_timestamp_cache.put(block_number, timestamp) catch {};
            return timestamp;
        }

        // Check cache
        if (self.block_timestamp_cache.get(block_number)) |ts| {
            return ts;
        }

        // Fetch from RPC (slowest path)
        const client = self.getClient(protocol);
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
    pub fn clearBlockTimestampCache(self: *Indexer) void {
        self.block_timestamp_cache.clearRetainingCapacity();
    }

    /// Look up domain name from namehash (returns null if not found).
    /// Uses the narrow `getNameStringByNamehash` query — fetches only the `name`
    /// column instead of the full 21-column Name row, since the caller only needs
    /// the string. Saves per-event allocation/dupe overhead during reverse resolution.
    pub fn getNameFromNamehash(self: *Indexer, namehash: Hash) ?[]const u8 {
        return self.database.getNameStringByNamehash(namehash, self.allocator) catch null;
    }

    // Helper methods to eliminate protocol-specific conditionals
    pub inline fn getEthRegistry(self: *Indexer, protocol: models.Protocol) Address {
        // Both V1 and V2 indexers use the same V2 ETH registry address (Sepolia aliases
        // L1-side and L2-side to one deployment; mainnet has no V2 yet — zero address).
        _ = protocol;
        return self.config.v2_contracts.eth_registry;
    }

    /// Migration kind: which V1→V2 controller (if any) handled the transfer.
    /// Locked vs unlocked matters: locked migrations preserve wrapper fuses;
    /// unlocked do not. Callers must distinguish to populate `wrapper_fuses` /
    /// `wrapper_expiry` on the new V2 row.
    pub const MigrationKind = enum { none, locked, unlocked };

    pub inline fn getMigrationKind(self: *Indexer, addr: Address) MigrationKind {
        const contracts = self.config.v1_contracts; // same struct backs v1 and v2 config
        if (!contracts.locked_migration_controller.isZero() and addr.eql(contracts.locked_migration_controller)) return .locked;
        if (!contracts.unlocked_migration_controller.isZero() and addr.eql(contracts.unlocked_migration_controller)) return .unlocked;
        return .none;
    }

    /// Boolean wrapper kept for call sites that only need yes/no.
    pub inline fn isMigrationController(self: *Indexer, addr: Address) bool {
        return self.getMigrationKind(addr) != .none;
    }

    pub inline fn getClient(self: *Indexer, protocol: models.Protocol) *rpc.Client {
        _ = protocol;
        return self.v1_client;
    }

    // Event configuration tables for declarative event indexing
    pub const RegistryEventConfig = struct {
        event_hash: Hash,
        handler: *const fn (*Indexer, models.Protocol, rpc.Log) anyerror!void,
        name: []const u8,
    };

    pub const ETH_REGISTRY_EVENTS = [_]RegistryEventConfig{
        .{ .event_hash = abi.EventSignatures.name_registered_hash, .handler = handleNameRegistered, .name = "NameRegistered" },
        .{ .event_hash = abi.EventSignatures.name_renewed_hash, .handler = handleNameRenewed, .name = "NameRenewed" },
        .{ .event_hash = abi.EventSignatures.name_burned_hash, .handler = handleNameBurned, .name = "NameBurned" },
        .{ .event_hash = abi.EventSignatures.token_regenerated_hash, .handler = handleTokenRegenerated, .name = "TokenRegenerated" },
        .{ .event_hash = abi.EventSignatures.eac_roles_changed_hash, .handler = handleEACRolesChanged, .name = "EACRolesChanged" },
        // LabelRegistered on the main ETH Registry happens during V1→V2 migration
        // (migration controllers call ETHRegistry directly, not through a subregistry)
        .{ .event_hash = abi.EventSignatures.label_registered_hash, .handler = handleLabelRegistered, .name = "LabelRegistered" },
    };

    pub const ETH_REGISTRAR_EVENTS = [_]RegistryEventConfig{
        .{ .event_hash = abi.EventSignatures.commitment_made_hash, .handler = handleCommitmentMade, .name = "CommitmentMade" },
        .{ .event_hash = abi.EventSignatures.eth_name_registered_hash, .handler = handleETHNameRegistered, .name = "ETH NameRegistered" },
        .{ .event_hash = abi.EventSignatures.eth_name_renewed_hash, .handler = handleETHNameRenewed, .name = "ETH NameRenewed" },
    };

    // ENS-specific subregistry events from PermissionedRegistry (and UserRegistry/WrapperRegistry)
    pub const SUBREGISTRY_ENS_EVENTS = [_]RegistryEventConfig{
        .{ .event_hash = abi.EventSignatures.label_registered_hash, .handler = handleLabelRegistered, .name = "LabelRegistered" },
        .{ .event_hash = abi.EventSignatures.label_reserved_hash, .handler = handleLabelReserved, .name = "LabelReserved" },
        .{ .event_hash = abi.EventSignatures.label_unregistered_hash, .handler = handleLabelUnregistered, .name = "LabelUnregistered" },
        .{ .event_hash = abi.EventSignatures.expiry_updated_hash, .handler = handleExpiryUpdated, .name = "ExpiryUpdated" },
        .{ .event_hash = abi.EventSignatures.parent_updated_hash, .handler = handleParentUpdated, .name = "ParentUpdated" },
        .{ .event_hash = abi.EventSignatures.subregistry_updated_hash, .handler = handleSubregistryUpdated, .name = "SubregistryUpdated" },
        .{ .event_hash = abi.EventSignatures.resolver_updated_hash, .handler = handleResolverUpdated, .name = "ResolverUpdated" },
        .{ .event_hash = abi.EventSignatures.token_regenerated_hash, .handler = handleTokenRegenerated, .name = "TokenRegenerated" },
        .{ .event_hash = abi.EventSignatures.eac_roles_changed_hash, .handler = handleEACRolesChanged, .name = "EACRolesChanged" },
    };

    // TransferSingle is ERC1155 standard - uses topic-only query with two-stage filtering:
    // 1) Token ID entropy filter: ENS uses hash-like IDs (>2^64), most ERC1155s use small sequential IDs
    // 2) Known subregistry HashSet filter: O(1) lookup
    // This achieves O(1) RPC scalability regardless of subregistry count
    pub const SUBREGISTRY_TRANSFER_EVENT = RegistryEventConfig{
        .event_hash = abi.EventSignatures.transfer_single_hash,
        .handler = handleTransfer,
        .name = "TransferSingle",
    };

    // Resolver events have different handler signature (include resolver address)
    pub const ResolverEventConfig = struct {
        event_hash: Hash,
        handler: *const fn (*Indexer, models.Protocol, Address, rpc.Log) anyerror!void,
        name: []const u8,
    };

    pub const RESOLVER_EVENTS = [_]ResolverEventConfig{
        // Legacy resolver events (2017 Public Resolver: 0x112234455c3a32fd11230c42e7bccd4a84e02010)
        .{ .event_hash = abi.EventSignatures.legacy_addr_changed_hash, .handler = handleLegacyAddrChanged, .name = "AddrChanged (legacy)" },
        .{ .event_hash = abi.EventSignatures.legacy_content_changed_hash, .handler = handleLegacyContentChanged, .name = "ContentChanged (legacy)" },
        // Modern resolver events (EIP-2304+)
        .{ .event_hash = abi.EventSignatures.address_changed_hash, .handler = handleAddressChanged, .name = "AddressChanged" },
        .{ .event_hash = abi.EventSignatures.content_hash_changed_hash, .handler = handleContentHashChanged, .name = "ContenthashChanged" },
        .{ .event_hash = abi.EventSignatures.text_changed_hash, .handler = handleTextChanged, .name = "TextChanged" },
        .{ .event_hash = abi.EventSignatures.abi_changed_hash, .handler = handleABIChanged, .name = "ABIChanged" },
        .{ .event_hash = abi.EventSignatures.pubkey_changed_hash, .handler = handlePubkeyChanged, .name = "PubkeyChanged" },
        .{ .event_hash = abi.EventSignatures.name_changed_hash, .handler = handleNameChanged, .name = "NameChanged" },
        .{ .event_hash = abi.EventSignatures.interface_changed_hash, .handler = handleInterfaceChanged, .name = "InterfaceChanged" },
        .{ .event_hash = abi.EventSignatures.version_changed_hash, .handler = handleVersionChanged, .name = "VersionChanged" },
        .{ .event_hash = abi.EventSignatures.alias_changed_hash, .handler = handleAliasChanged, .name = "AliasChanged" },
        .{ .event_hash = abi.EventSignatures.eac_roles_changed_hash, .handler = handleResolverEACRolesChanged, .name = "EACRolesChanged" },
    };

    // ========================================================================
    // V1 EVENT CONFIGURATIONS (ENS V1 - Mainnet)
    // ========================================================================

    // ENS Registry events (0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e)
    pub const V1_REGISTRY_EVENTS = [_]RegistryEventConfig{
        .{ .event_hash = abi.EventSignatures.new_owner_hash, .handler = handleV1NewOwner, .name = "NewOwner" },
        .{ .event_hash = abi.EventSignatures.registry_transfer_hash, .handler = handleV1RegistryTransfer, .name = "RegistryTransfer" },
        .{ .event_hash = abi.EventSignatures.new_resolver_hash, .handler = handleV1NewResolver, .name = "NewResolver" },
        .{ .event_hash = abi.EventSignatures.new_ttl_hash, .handler = handleV1NewTTL, .name = "NewTTL" },
    };

    // Name Wrapper events (0xD4416b13d2b3a9aBae7AcD5D6C2BbDBE25686401)
    pub const V1_NAME_WRAPPER_EVENTS = [_]RegistryEventConfig{
        .{ .event_hash = abi.EventSignatures.name_wrapped_hash, .handler = handleV1NameWrapped, .name = "NameWrapped" },
        .{ .event_hash = abi.EventSignatures.name_unwrapped_hash, .handler = handleV1NameUnwrapped, .name = "NameUnwrapped" },
        .{ .event_hash = abi.EventSignatures.fuses_set_hash, .handler = handleV1FusesSet, .name = "FusesSet" },
        .{ .event_hash = abi.EventSignatures.expiry_extended_hash, .handler = handleV1ExpiryExtended, .name = "ExpiryExtended" },
    };

    // Base Registrar events (0x57f1887a8BF19b14fC0dF6Fd9B2acc9Af147eA85)
    pub const V1_BASE_REGISTRAR_EVENTS = [_]RegistryEventConfig{
        .{ .event_hash = abi.EventSignatures.erc721_transfer_hash, .handler = handleV1ERC721Transfer, .name = "Transfer" },
        .{ .event_hash = abi.EventSignatures.base_registrar_name_registered_hash, .handler = handleV1BaseRegistrarNameRegistered, .name = "NameRegistered" },
        .{ .event_hash = abi.EventSignatures.base_registrar_name_renewed_hash, .handler = handleV1BaseRegistrarNameRenewed, .name = "NameRenewed" },
        .{ .event_hash = abi.EventSignatures.controller_added_hash, .handler = handleV1ControllerAdded, .name = "ControllerAdded" },
        .{ .event_hash = abi.EventSignatures.controller_removed_hash, .handler = handleV1ControllerRemoved, .name = "ControllerRemoved" },
    };

    // ETH Registrar Controller events
    // Multiple controllers have existed (legacy 5/4-param and current 7/5-param
    // with referrer). Register both signatures — the handler picks the right
    // decoding path based on data length.
    pub const V1_ETH_CONTROLLER_EVENTS = [_]RegistryEventConfig{
        .{ .event_hash = abi.EventSignatures.controller_name_registered_hash, .handler = handleV1ETHControllerNameRegistered, .name = "NameRegistered (legacy)" },
        .{ .event_hash = abi.EventSignatures.controller_name_registered_v2_hash, .handler = handleV1ETHControllerNameRegistered, .name = "NameRegistered" },
        .{ .event_hash = abi.EventSignatures.controller_name_renewed_hash, .handler = handleV1ETHControllerNameRenewed, .name = "NameRenewed (legacy)" },
        .{ .event_hash = abi.EventSignatures.controller_name_renewed_v2_hash, .handler = handleV1ETHControllerNameRenewed, .name = "NameRenewed" },
    };

    // Reverse Registrar events (0xa58E81fe9b61B5c3fE2AFD33CF304c454AbFc7Cb)
    pub const V1_REVERSE_REGISTRAR_EVENTS = [_]RegistryEventConfig{
        .{ .event_hash = abi.EventSignatures.reverse_claimed_hash, .handler = handleV1ReverseClaimed, .name = "ReverseClaimed" },
    };

    // V2 ETH Reverse Registrar events (L2ReverseRegistrar / StandaloneReverseRegistrar).
    // V2 emits `NameForAddrChanged(address indexed addr, string name)` — there is
    // no V1-style `ReverseClaimed(addr, node)` since V2 stores the name directly
    // on the reverse registrar rather than going through a separate resolver.
    pub const V2_REVERSE_REGISTRAR_EVENTS = [_]RegistryEventConfig{
        .{ .event_hash = abi.EventSignatures.name_for_addr_changed_hash, .handler = handleV2NameForAddrChanged, .name = "NameForAddrChanged" },
    };

    // Temporary Registrar events (0x6090A6e47849629b7245Dfa1Ca21D94cd15878Ef)
    // Pre-V1 Migration: May 2017 (block 3327417) - May 2019 (block 9380410)
    pub const TEMP_REGISTRAR_EVENTS = [_]RegistryEventConfig{
        .{ .event_hash = abi.EventSignatures.auction_started_hash, .handler = handleTempAuctionStarted, .name = "AuctionStarted" },
        .{ .event_hash = abi.EventSignatures.new_bid_hash, .handler = handleTempNewBid, .name = "NewBid" },
        .{ .event_hash = abi.EventSignatures.bid_revealed_hash, .handler = handleTempBidRevealed, .name = "BidRevealed" },
        .{ .event_hash = abi.EventSignatures.hash_registered_hash, .handler = handleTempHashRegistered, .name = "HashRegistered" },
        .{ .event_hash = abi.EventSignatures.hash_released_hash, .handler = handleTempHashReleased, .name = "HashReleased" },
        .{ .event_hash = abi.EventSignatures.hash_invalidated_hash, .handler = handleTempHashInvalidated, .name = "HashInvalidated" },
    };

    // V1 indexing orchestration (extracted to v1_indexing.zig)
    pub const indexV1EventsChunked = v1_indexing.indexV1EventsChunked;
    pub const indexAllV1Events = v1_indexing.indexAllV1Events;
    pub const indexTempRegistrarEvents = v1_indexing.indexTempRegistrarEvents;
    pub const indexV1RegistryEvents = v1_indexing.indexV1RegistryEvents;
    pub const indexV1NameWrapperEvents = v1_indexing.indexV1NameWrapperEvents;
    pub const indexV1BaseRegistrarEvents = v1_indexing.indexV1BaseRegistrarEvents;
    pub const indexV1ReverseRegistrarEvents = v1_indexing.indexV1ReverseRegistrarEvents;

    /// Helper function to insert an event and trigger webhooks with proper memory cleanup
    /// This ensures that event.name and event.data are ALWAYS freed after use
    pub fn insertEventAndNotify(self: *Indexer, event: models.Event) !void {
        // When write buffer is active, buffer the event instead of writing to DB.
        // Buffer takes ownership of the strings — do NOT free them here.
        if (self.write_buffer.active) {
            try self.write_buffer.addEvent(event);
            return;
        }

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

        // Drop non-essential indexes for faster bulk inserts during initial sync
        if (!self.initial_sync_complete.load(.acquire)) {
            self.database.dropSyncIndexes() catch |err| {
                std.log.warn("Failed to drop sync indexes (non-fatal): {}", .{err});
            };
        }

        while (!self.should_stop.load(.acquire)) {
            // Index V1 first (SQLite doesn't support concurrent writes from different threads)
            try self.indexProtocol(.v1, self.v1_client);

            // Then index V2
            try self.indexProtocol(.v2, self.v1_client);

            // After first successful sync of both chains, recreate indexes and start webhook workers
            if (!self.initial_sync_complete.load(.acquire)) {
                self.database.createSyncIndexes() catch |err| {
                    std.log.err("Failed to recreate sync indexes: {}", .{err});
                };

                self.initial_sync_complete.store(true, .release);
                if (self.webhook_manager) |wm| {
                    std.log.info("Initial sync complete - starting 8 webhook workers", .{});
                    try wm.startWorkers(8);
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

    /// Start indexing a single protocol (for separate process architecture)
    pub fn startSingleProtocol(self: *Indexer, protocol: models.Protocol) !void {
        std.log.info("Single-protocol indexer starting for {s}...", .{protocol.toString()});

        const client = self.getClient(protocol);
        var network_health = &self.v1_network_health;

        // Drop non-essential indexes for faster bulk inserts during initial sync
        if (!self.initial_sync_complete.load(.acquire)) {
            self.database.dropSyncIndexes() catch |err| {
                std.log.warn("Failed to drop sync indexes (non-fatal): {}", .{err});
            };
        }

        while (!self.should_stop.load(.acquire)) {
            if (self.indexProtocol(protocol, client)) |_| {
                // Success - after first successful sync, recreate indexes and start webhook workers
                if (!self.initial_sync_complete.load(.acquire)) {
                    // Recreate all indexes before marking sync complete
                    self.database.createSyncIndexes() catch |err| {
                        std.log.err("Failed to recreate sync indexes: {}", .{err});
                    };

                    self.initial_sync_complete.store(true, .release);
                    if (self.webhook_manager) |wm| {
                        std.log.info("Initial sync complete - starting webhook workers", .{});
                        try wm.startWorkers(1);
                    }

                    // Backfill pre-migration names after initial sync completes
                    if (protocol == .v1) {
                        std.log.info("Running pre-migration names backfill...", .{});
                        self.backfillPreMigrationNames() catch |err| {
                            std.log.err("Failed to backfill pre-migration names: {}", .{err});
                        };

                        // Backfill unknown subdomain labels from transaction calldata
                        std.log.info("Running unknown labels backfill...", .{});
                        self.backfillUnknownLabels() catch |err| {
                            std.log.err("Failed to backfill unknown labels: {}", .{err});
                        };

                        // Retroactive recovery: create name records for .eth 2LDs
                        // where the label was resolved but no name record was created
                        std.log.info("Running missing .eth 2LD names backfill...", .{});
                        self.backfillMissingEth2LDNames() catch |err| {
                            std.log.err("Failed to backfill missing .eth 2LD names: {}", .{err});
                        };
                    }
                }
            } else |err| {
                // Handle errors gracefully based on type
                switch (err) {
                    error.HttpError, error.NetworkUnreachable, error.ConnectionRefused, error.ConnectionTimedOut, error.ConnectionResetByPeer, error.WriteFailed, error.BrokenPipe, error.EndOfStream, error.UnexpectedReadFailure => {
                        // Network error - wait for connection to be restored
                        std.log.warn("{s} network error detected: {}, waiting for connection...", .{ protocol.toString(), err });
                        network_health.waitForHealthy();
                        std.log.info("{s} network restored, continuing...", .{protocol.toString()});
                        // No sleep - continue immediately after network is back
                        continue;
                    },
                    else => {
                        // Other errors (database, parsing, etc) - log and wait briefly
                        std.log.err("{s} indexing error: {}", .{ protocol.toString(), err });
                        std.Thread.sleep(constants.Timing.error_recovery_delay_ms * std.time.ns_per_ms); // Wait 5s for non-network errors
                    },
                }
            }

            // Sleep for poll interval before next iteration
            std.Thread.sleep(self.config.poll_interval * std.time.ns_per_s);
        }

        std.log.info("{s} indexer stopped.", .{protocol.toString()});
    }

    /// True if the stored hash for `block_number` still matches the protocol, or no hash is stored.
    /// On RPC failure, returns true (skip the reorg check this round) rather than aborting the
    /// whole sync — reorgs are rare, transient network errors are not, and the next iteration
    /// will catch a real reorg.
    fn verifyStoredBlockHash(self: *Indexer, protocol: models.Protocol, client: *rpc.Client, block_number: u64) !bool {
        const stored = try self.database.getBlockHash(protocol, block_number) orelse return true;
        const actual = client.getBlockByNumber(block_number, false) catch |err| {
            std.log.warn("Skipping reorg check for block {d} ({}): assuming hash unchanged this round", .{ block_number, err });
            return true;
        };
        return std.mem.eql(u8, &stored.bytes, &actual.hash.bytes);
    }

    /// Walk back from `from_block` until a block whose stored hash matches the protocol is found,
    /// then roll the database back to that block. Returns the block number rolled back to.
    fn rollbackToLastValidBlock(self: *Indexer, protocol: models.Protocol, client: *rpc.Client, from_block: u64) !u64 {
        var rollback_to = from_block;
        while (rollback_to > self.config.start_block) : (rollback_to -= 1) {
            const stored = try self.database.getBlockHash(protocol, rollback_to);
            if (stored == null) break; // past stored history — treat as safe
            const actual = client.getBlockByNumber(rollback_to, false) catch break;
            if (std.mem.eql(u8, &stored.?.bytes, &actual.hash.bytes)) break;
        }
        std.log.warn("Rolling back {s} to block {d}", .{ protocol.toString(), rollback_to });
        try self.database.rollbackToBlock(protocol, rollback_to);
        return rollback_to;
    }

    fn indexProtocol(self: *Indexer, protocol: models.Protocol, client: *rpc.Client) !void {
        // Use protocol-specific deployment block as fallback for fresh databases
        const deployment_block = switch (protocol) {
            .v1 => self.config.v1_contracts.v1_deployment_block,
            .v2 => self.config.v2_contracts.v2_deployment_block,
        };

        // Get last synced block from database (resumability)
        var last_synced = try self.database.getSyncState(protocol) orelse deployment_block;

        // Entry reorg check: if the last-committed block no longer matches protocol, roll back.
        if (last_synced > deployment_block) {
            if (!try self.verifyStoredBlockHash(protocol, client, last_synced)) {
                std.log.err("REORG DETECTED at block {d} on {s} (entry check)", .{ last_synced, protocol.toString() });
                last_synced = try self.rollbackToLastValidBlock(protocol, client, last_synced - 1);
            }
        }

        // Get current block number
        const current_block = try client.getBlockNumber();
        const target_block = if (self.end_block) |eb| @min(eb, current_block) else current_block;

        // Update status target_block to reflect latest protocol block
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
        std.log.info("Indexing {s} from block {d} to {d} ({d} blocks)", .{ protocol.toString(), last_synced + 1, target_block, total_blocks });

        // Index in batches with adaptive batch sizing
        // Starts at configured size, halves on RPC response size errors, grows back on success
        var current_batch_size = self.config.batch_size;
        const ABSOLUTE_MIN_BATCH: u64 = 100;
        var from_block = last_synced + 1;
        var blocks_indexed: u64 = 0;

        while (from_block <= target_block and !self.should_stop.load(.acquire)) {
            const to_block = @min(from_block + current_batch_size - 1, target_block);
            const batch_blocks = to_block - from_block + 1;

            // Rate limit RPC calls to avoid hitting provider limits
            self.rate_limiter.acquire();

            // Mid-sync reorg guard: once we've committed at least one batch this call, verify
            // the previous batch's end block still matches protocol before starting the next.
            // Protects long catch-up passes that would otherwise only notice reorgs at restart.
            if (from_block > last_synced + 1) {
                if (!try self.verifyStoredBlockHash(protocol, client, from_block - 1)) {
                    std.log.err("REORG DETECTED at block {d} on {s} (mid-sync)", .{ from_block - 1, protocol.toString() });
                    _ = try self.rollbackToLastValidBlock(protocol, client, from_block - 2);
                    return; // outer loop re-enters indexProtocol, refreshing target_block and resuming
                }
            }

            // Reset block hash tracking for this batch
            self.resetBlockHashTracking();

            // Use transaction for batch atomicity
            try self.database.beginTransaction();

            // Try indexing - on RPC response size errors, rollback, halve batch, retry
            self.indexBlockRange(protocol, client, from_block, to_block) catch |err| {
                self.database.rollbackTransaction();

                if ((err == error.RpcError or err == error.StreamTooLong) and current_batch_size > ABSOLUTE_MIN_BATCH) {
                    current_batch_size = @max(ABSOLUTE_MIN_BATCH, current_batch_size / 2);
                    std.log.warn("RPC response too large for blocks {d}-{d}! Reducing batch size to {d} blocks and retrying", .{ from_block, to_block, current_batch_size });
                    continue; // Retry same from_block with smaller batch
                }

                return err;
            };

            // Commit transaction FIRST, then update sync state
            try self.database.commitTransaction();

            // After successful batch, gradually grow batch size back toward configured maximum
            if (current_batch_size < self.config.batch_size) {
                current_batch_size = @min(self.config.batch_size, current_batch_size + current_batch_size / 4);
                std.log.info("Growing batch size to {d} blocks", .{current_batch_size});
            }

            blocks_indexed += batch_blocks;
            const progress = (@as(f64, @floatFromInt(blocks_indexed)) / @as(f64, @floatFromInt(total_blocks))) * 100.0;
            std.log.info("Progress: {d:.1}% ({d}/{d} blocks) - Batch {d}-{d} indexed", .{ progress, blocks_indexed, total_blocks, from_block, to_block });

            // Store block hashes for reorg detection and update sync state ATOMICALLY
            try self.database.beginTransaction();
            errdefer self.database.rollbackTransaction();

            // Use block hash from processed logs if available (avoids extra RPC call)
            // Fall back to getBlockByNumber only when no logs were processed in this range
            if (self.last_seen_block_hash != null and self.last_seen_block_number == to_block) {
                try self.database.storeBlockHash(protocol, to_block, self.last_seen_block_hash.?, Hash.zero);
            } else {
                const block_info = try client.getBlockByNumber(to_block, false);
                try self.database.storeBlockHash(protocol, to_block, block_info.hash, block_info.parent_hash);
            }

            // Update sync state
            try self.database.setSyncState(protocol, to_block);
            try self.database.commitTransaction();

            // Update status if tracking is enabled
            if (self.indexer_status) |status| {
                status.current_block = to_block;
            }

            self.blocks_since_checkpoint += (to_block - from_block + 1);

            // Periodic checkpoint and memory cleanup
            if (self.blocks_since_checkpoint >= self.config.checkpoint_interval) {
                std.log.info("Checkpoint: synced {s} to block {d}", .{ protocol.toString(), to_block });
                self.blocks_since_checkpoint = 0;

                // Prune old block hashes (keep last 1000 blocks)
                try self.database.pruneOldBlockHashes(protocol, to_block);

                // Clear block timestamp cache to prevent memory growth
                self.clearBlockTimestampCache();

                // Force a brief pause to allow memory to be reclaimed
                std.Thread.sleep(constants.Timing.rpc_batch_delay_ms * std.time.ns_per_ms);
            }

            from_block = to_block + 1;
        }

        std.log.info("Synced {s} to block {d}", .{ protocol.toString(), target_block });
    }

    fn indexBlockRange(self: *Indexer, protocol: models.Protocol, client: *rpc.Client, from_block: u64, to_block: u64) !void {
        // IMPORTANT: Process events in dependency order:
        // 1. First create names (NameRegistered, NewSubname)
        // 2. Then modify names (SubregistryUpdate, ResolverUpdate, Transfer)
        // 3. Then process data dependent on names existing (resolver records)

        // Block range constants from contract config (protocol-specific)
        const v1_contracts = self.config.v1_contracts;
        const temp_registrar_start = v1_contracts.temp_registrar_start_block;

        // === V1 EVENTS (ENS V1 - Mainnet V1 only) ===
        // Only index V1 events if the block range overlaps with V1 deployment period
        // Skip if entire range is before temp registrar start OR if V2 is deployed and range is entirely after V2
        // V2 deployment block is the same regardless of which protocol (protocol) we're indexing —
        // this gate asks "are we still in the V1 era?".
        const v2_deployment = self.config.v2_contracts.v2_deployment_block;
        const should_index_v1 = (temp_registrar_start > 0) and (to_block >= temp_registrar_start) and
            (v2_deployment == 0 or from_block < v2_deployment + 10);

        if (should_index_v1) {
            // EFFICIENT: Index all V1 events together per chunk (Registry, Name Wrapper, Base Registrar, Reverse Registrar)
            // This processes each chunk ONCE for all contracts, instead of reprocessing chunks per contract
            try self.indexAllV1Events(protocol, client, from_block, to_block);
        }

        // === V2 EVENTS (ENS V2) ===
        // Only index V2 events if V2 is deployed and the block range includes deployment block or later
        const should_index_v2 = (v2_deployment > 0) and (to_block >= v2_deployment);

        if (should_index_v2) {
            // Phase 1: Fetch EthRegistry + ETHRegistrar + Datastore events in a single batch RPC call
            // (1 HTTP request instead of 3, eliminates ~100ms of inter-batch sleeps)
            try self.indexPhase1V2Events(protocol, client, from_block, to_block);

            // Phase 2: Subregistry events (depends on Phase 1 discovering subregistries)
            try self.indexSubregistryEvents(protocol, client, from_block, to_block);
            try self.processRemainingOrphans(protocol);

            // Phase 3: Transfer events (depends on names existing)
            // Note: V1→V2 migration is detected in handleLabelRegistered via sender address
            try self.indexTransferEvents(protocol, client, from_block, to_block);

            // Phase 4: Resolver events (depends on names + resolvers being set)
            try self.indexResolverEvents(protocol, client, from_block, to_block);

            // Phase 5: V2 reverse registrar events. Independent of names — populates
            // the reverse_records table so primary-name lookups don't have to scan
            // the events feed.
            try self.indexV2ReverseRegistrarEvents(protocol, client, from_block, to_block);
        }
    }

    // V2 event fetchers (extracted to event_fetchers.zig)
    pub const indexPhase1V2Events = event_fetchers.indexPhase1V2Events;
    pub const indexSubregistryEvents = event_fetchers.indexSubregistryEvents;
    pub const indexTransferEvents = event_fetchers.indexTransferEvents;
    pub const indexResolverEvents = event_fetchers.indexResolverEvents;
    pub const indexV2ReverseRegistrarEvents = event_fetchers.indexV2ReverseRegistrarEvents;

    // V2 registry handlers (extracted to handlers_v2_registry.zig)
    pub const processOrphanedRegistration = handlers_v2_registry.processOrphanedRegistration;
    pub const processRemainingOrphans = handlers_v2_registry.processRemainingOrphans;
    pub const handleNameRegistered = handlers_v2_registry.handleNameRegistered;
    pub const handleNameRenewed = handlers_v2_registry.handleNameRenewed;
    pub const handleTransfer = handlers_v2_registry.handleTransfer;
    pub const handleETHNameRegistered = handlers_v2_registry.handleETHNameRegistered;
    pub const handleETHNameRenewed = handlers_v2_registry.handleETHNameRenewed;
    pub const handleCommitmentMade = handlers_v2_registry.handleCommitmentMade;
    pub const handleNameBurned = handlers_v2_registry.handleNameBurned;
    pub const handleTokenRegenerated = handlers_v2_registry.handleTokenRegenerated;
    pub const handleTransferBatch = handlers_v2_registry.handleTransferBatch;
    pub const handleApproval = handlers_v2_registry.handleApproval;
    pub const handleEACRolesChanged = handlers_v2_registry.handleEACRolesChanged;
    pub const handleLabelRegistered = handlers_v2_registry.handleLabelRegistered;
    pub const handleLabelReserved = handlers_v2_registry.handleLabelReserved;
    pub const handleLabelUnregistered = handlers_v2_registry.handleLabelUnregistered;
    pub const handleExpiryUpdated = handlers_v2_registry.handleExpiryUpdated;
    pub const handleParentUpdated = handlers_v2_registry.handleParentUpdated;
    pub const handleSubregistryUpdated = handlers_v2_registry.handleSubregistryUpdated;
    pub const handleResolverUpdated = handlers_v2_registry.handleResolverUpdated;

    // V2 resolver handlers (extracted to handlers_v2_resolver.zig)
    pub const handleLegacyAddrChanged = handlers_v2_resolver.handleLegacyAddrChanged;
    pub const handleLegacyContentChanged = handlers_v2_resolver.handleLegacyContentChanged;
    pub const handleAddressChanged = handlers_v2_resolver.handleAddressChanged;
    pub const handleContentHashChanged = handlers_v2_resolver.handleContentHashChanged;
    pub const handleTextChanged = handlers_v2_resolver.handleTextChanged;
    pub const handleABIChanged = handlers_v2_resolver.handleABIChanged;
    pub const handlePubkeyChanged = handlers_v2_resolver.handlePubkeyChanged;
    pub const handleNameChanged = handlers_v2_resolver.handleNameChanged;
    pub const handleInterfaceChanged = handlers_v2_resolver.handleInterfaceChanged;
    pub const handleVersionChanged = handlers_v2_resolver.handleVersionChanged;
    pub const handleAliasChanged = handlers_v2_resolver.handleAliasChanged;
    pub const decodeDnsWireFormat = handlers_v2_resolver.decodeDnsWireFormat;
    pub const handleResolverEACRolesChanged = handlers_v2_resolver.handleResolverEACRolesChanged;

    // V1 event handlers (extracted to handlers_v1.zig)
    pub const handleV1NewOwner = handlers_v1.handleV1NewOwner;
    pub const handleV1RegistryTransfer = handlers_v1.handleV1RegistryTransfer;
    pub const handleV1NewResolver = handlers_v1.handleV1NewResolver;
    pub const handleV1NewTTL = handlers_v1.handleV1NewTTL;
    pub const handleV1NameWrapped = handlers_v1.handleV1NameWrapped;
    pub const handleV1NameUnwrapped = handlers_v1.handleV1NameUnwrapped;
    pub const handleV1FusesSet = handlers_v1.handleV1FusesSet;
    pub const handleV1ExpiryExtended = handlers_v1.handleV1ExpiryExtended;
    pub const handleV1ERC721Transfer = handlers_v1.handleV1ERC721Transfer;
    pub const handleV1BaseRegistrarNameRegistered = handlers_v1.handleV1BaseRegistrarNameRegistered;
    pub const handleV1BaseRegistrarNameRenewed = handlers_v1.handleV1BaseRegistrarNameRenewed;
    pub const handleV1ControllerAdded = handlers_v1.handleV1ControllerAdded;
    pub const handleV1ControllerRemoved = handlers_v1.handleV1ControllerRemoved;
    pub const handleV1ETHControllerNameRegistered = handlers_v1.handleV1ETHControllerNameRegistered;
    pub const handleV1ETHControllerNameRenewed = handlers_v1.handleV1ETHControllerNameRenewed;
    pub const handleV1ReverseClaimed = handlers_v1.handleV1ReverseClaimed;
    pub const handleV2NameForAddrChanged = handlers_v1.handleV2NameForAddrChanged;

    // Temporary registrar handlers (extracted to handlers_v1_temp.zig)
    pub const handleTempHashRegistered = handlers_v1_temp.handleTempHashRegistered;
    pub const handleTempAuctionStarted = handlers_v1_temp.handleTempAuctionStarted;
    pub const handleTempNewBid = handlers_v1_temp.handleTempNewBid;
    pub const handleTempBidRevealed = handlers_v1_temp.handleTempBidRevealed;
    pub const handleTempHashReleased = handlers_v1_temp.handleTempHashReleased;
    pub const handleTempHashInvalidated = handlers_v1_temp.handleTempHashInvalidated;

    // Backfill functions (extracted to backfill.zig)
    const backfillPreMigrationNames = backfill_mod.backfillPreMigrationNames;
    pub const backfillUnknownLabels = backfill_mod.backfillUnknownLabels;
    pub const backfillMissingEth2LDNames = backfill_mod.backfillMissingEth2LDNames;

    // Shared utility functions (extracted to utils.zig)
    pub const emitEvent = utils.emitEvent;
    pub const resolveNamehash = utils.resolveNamehash;
};
