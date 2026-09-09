const std = @import("std");
const zsys = @import("../utils/system.zig");
const config = @import("../config.zig");
const constants = @import("../constants.zig");
const db = @import("../storage/database.zig");
const name_prefetch_mod = @import("../storage/name_prefetch.zig");
const placeholders_mod = @import("placeholders.zig");
const rpc = @import("../rpc/client.zig");
const models = @import("../types/models.zig");
// EventSignatures consumed via the eth.zig-backed shim (re-exports them).
// Old `abi.zig` kept for fallback.
const abi = @import("abi_eth.zig");
const Hash = @import("../types/hash.zig").Hash;
const Address = @import("../types/address.zig").Address;
const contract_defs = @import("../contracts.zig");
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
const backfill_mod = @import("v1/backfill.zig");
const reorg_undo = @import("../storage/reorg_undo.zig");
const ens_normalize = @import("../utils/ens_normalize.zig");
const replay_mod = @import("replay.zig");
pub const utils = @import("utils.zig");
const WriteBuffer = @import("write_buffer.zig").WriteBuffer;
const Rainbow = @import("../rainbow/rainbow.zig").Rainbow;
const caches = @import("caches.zig");
const event_config = @import("event_config.zig");
const persistence = @import("persistence.zig");
const reorg_support = @import("reorg_support.zig");
const sync_driver = @import("sync_driver.zig");

pub const Indexer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: config.Config,
    database: *db.Database,
    // Whether this process indexes V1. Only V1 produces `unknown_labels` rows, so the
    // V2 LabelStore heal is a no-op (pure RPC overhead) in the V2-only binary — gate it.
    indexes_v1: bool,
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
    // Adaptive fetch state persisted across driver batches: learned V1 event
    // density and the RPC overflow ceiling. 0 = not yet learned (era defaults
    // apply). Without these the fetcher re-learns from scratch every batch.
    v1_events_per_block: f64 = 0,
    v1_rpc_chunk_ceiling: u64 = 0,
    // Largest eth_getLogs block span the provider has accepted for a discovery
    // sweep (0 = unlimited, nothing learned yet). Lowered by the first rejection
    // and kept for the rest of the run so every later sweep starts right-sized.
    backfill_chunk_ceiling: u64 = 0,
    // Memoized rainbow-table lookups (hit AND miss — the empty-string sentinel).
    // A cold probe into the multi-GB rainbow DB is disk-latency-priced; the same
    // labelhash recurs on every event touching that node, so memoization collapses
    // repeat probes to a hash lookup. Values are cache-owned (callers borrow).
    rainbow_cache: std.AutoHashMap([32]u8, []const u8),
    // Per-chunk rainbow probe instrumentation (printed in the chunk timing line).
    rainbow_probe_count: u64 = 0,
    newowner_phase_ns: [5]i128 = [_]i128{0} ** 5,
    /// Resolvers first sighted this batch (via ResolverUpdated registration).
    /// Drained by indexResolverEvents, which backfills each one's pre-attachment
    /// history (initialize()-time EACRolesChanged role grants fire blocks before
    /// the resolver becomes known). Cleared alongside clearKnownResolverCache on
    /// batch rollback (the registrations were reverted with the transaction).
    pending_resolver_backfills: std.ArrayList(Address) = .empty,
    /// Whether this process actually dropped the bulk-sync indexes. The
    /// completion path only pays the index rebuild + ANALYZE when a drop
    /// happened — a caught-up restart (gap below SYNC_INDEX_MIN_GAP_BLOCKS)
    /// keeps its indexes and skips the whole cycle.
    sync_indexes_dropped: bool = false,
    rainbow_probe_ns: u64 = 0,
    // Cached V1 token_id → label mappings (populated on miss from DB)
    v1_label_cache: std.StringHashMap([]const u8),
    // In-memory dedup of registered resolvers (membership-only — known_resolvers'
    // last_indexed_block is never read), so the same resolver isn't re-upserted on
    // every ResolverUpdated/NewResolver. See registerResolverOnce.
    known_resolver_cache: std.StringHashMap(void),
    // In-memory dedup of account observations per (protocol,address) this run: accounts'
    // first_seen is a MIN and seen_v1/seen_v2 are MAX, and the indexer processes forward,
    // so re-upserting an already-seen address is a no-op. Cleared on batch rollback.
    account_obs_cache: std.StringHashMap(void),
    // Per-batch namehash→name read cache: resolver events cluster many lookups on the
    // same few names; dedups getNameFromNamehash within a batch (cleared per batch to
    // pick up placeholder→real name patches). Values are owned.
    name_by_namehash_cache: std.AutoHashMap(Hash, []const u8),
    // Track block hash from processed logs to avoid extra getBlockByNumber RPC calls
    last_seen_block_hash: ?Hash = null,
    // Dispatch-scoped names prefetch (see storage/name_prefetch.zig). Set by
    // utils.dispatchOrdered for the duration of one ordered dispatch; null
    // otherwise. Consulted only by handleResolverUpdated.
    name_prefetch: ?*name_prefetch_mod.NamePrefetch = null,
    last_seen_block_number: u64 = 0,
    // Reorg undo-log cursor de-dup: last (protocol, block) the cursor was written for,
    // so `markEventBlock` only writes on a change (avoids a per-event upsert). -1 = unset.
    reorg_cursor_block: i64 = -1,
    reorg_cursor_proto: i8 = -1,
    // Reorg undo capture is armed only near the chain tip (within REORG_ARM_WINDOW of the
    // head). Bulk-sync blocks are finalized and cannot reorg, so leaving the cursor unarmed
    // there makes the AFTER UPDATE/DELETE triggers skip capture — eliminating the reorg_undo
    // writes + trigger work for the millions of old blocks in a backfill.
    reorg_arm: bool = true,
    // Write buffer for batching DB operations during chunk processing
    write_buffer: WriteBuffer,
    /// Which canonical/token ids have placeholder rows on disk — gates the
    /// per-registration placeholder patches (see placeholders.zig).
    placeholders: placeholders_mod.PlaceholderLedger,
    // Rainbow table for resolving labelhashes to labels (optional)
    rainbow: ?Rainbow = null,
    // Cached namehash("eth") — constant value used by every V2 LabelRegistered/
    // NameRegistered/LabelReserved handler. Two keccak rounds saved per event.
    eth_namehash: Hash,

    // Registrar root for the V1-shaped path: "eth" on ENS networks, "base.eth"
    // on Base (Basenames). 2LDs from the base-registrar/controller surface are
    // `<label>.<root_name>` with parent node `root_node`.
    root_name: []const u8,
    root_node: Hash,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, cfg: config.Config, database: *db.Database, end_block: ?u64) !Indexer {
        // Create ONE shared HTTP client
        const http_client = try allocator.create(std.http.Client);
        http_client.* = std.http.Client{ .allocator = allocator, .io = io };
        errdefer {
            http_client.deinit();
            allocator.destroy(http_client);
        }

        const v1_client = try rpc.Client.initWithSharedHttpClient(allocator, cfg.rpc_url, http_client);
        errdefer v1_client.deinit();
        v1_client.max_batch_requests = cfg.rpc_max_batch_requests;

        var webhook_manager: ?*webhooks.WebhookManager = null;
        if (cfg.webhooks_enabled) {
            webhook_manager = try webhooks.WebhookManager.init(allocator, io, cfg.webhook_db_path, cfg.webhook_max_retries, 100); // 100ms rate limit per endpoint (10 req/sec)
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
                .start_time = zsys.timestamp(),
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
            .io = io,
            .config = cfg,
            .database = database,
            .indexes_v1 = true, // combined indexer indexes both protocols
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
            .rainbow_cache = std.AutoHashMap([32]u8, []const u8).init(allocator),
            .known_resolver_cache = std.StringHashMap(void).init(allocator),
            .account_obs_cache = std.StringHashMap(void).init(allocator),
            .name_by_namehash_cache = std.AutoHashMap(Hash, []const u8).init(allocator),
            .write_buffer = WriteBuffer.init(allocator),
            .placeholders = placeholders_mod.PlaceholderLedger.init(allocator),
            .rainbow = rainbow,
            .eth_namehash = try @import("../types/hash.zig").namehash(allocator, "eth"),
            .root_name = cfg.network.rootName(),
            .root_node = try @import("../types/hash.zig").namehash(allocator, cfg.network.rootName()),
        };
    }

    /// Initialize indexer for a single protocol (V1 or V2 only)
    pub fn initSingleProtocol(allocator: std.mem.Allocator, io: std.Io, cfg: config.Config, database: *db.Database, protocol: models.Protocol, end_block: ?u64) !Indexer {
        const http_client = try allocator.create(std.http.Client);
        http_client.* = std.http.Client{ .allocator = allocator, .io = io };
        errdefer {
            http_client.deinit();
            allocator.destroy(http_client);
        }

        const client = try rpc.Client.initWithSharedHttpClient(allocator, cfg.rpc_url, http_client);
        errdefer client.deinit();
        client.max_batch_requests = cfg.rpc_max_batch_requests;

        var webhook_manager: ?*webhooks.WebhookManager = null;
        if (cfg.webhooks_enabled) {
            webhook_manager = try webhooks.WebhookManager.init(allocator, io, cfg.webhook_db_path, cfg.webhook_max_retries, 100); // 100ms rate limit per endpoint (10 req/sec)
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
                .start_time = zsys.timestamp(),
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
            .io = io,
            .config = cfg,
            .database = database,
            .indexes_v1 = (protocol == .v1),
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
            .rainbow_cache = std.AutoHashMap([32]u8, []const u8).init(allocator),
            .known_resolver_cache = std.StringHashMap(void).init(allocator),
            .account_obs_cache = std.StringHashMap(void).init(allocator),
            .name_by_namehash_cache = std.AutoHashMap(Hash, []const u8).init(allocator),
            .write_buffer = WriteBuffer.init(allocator),
            .placeholders = placeholders_mod.PlaceholderLedger.init(allocator),
            .rainbow = rainbow,
            .eth_namehash = try @import("../types/hash.zig").namehash(allocator, "eth"),
            .root_name = cfg.network.rootName(),
            .root_node = try @import("../types/hash.zig").namehash(allocator, cfg.network.rootName()),
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
        self.placeholders.deinit();
        self.pending_resolver_backfills.deinit(self.allocator);
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

        var rb_it = self.rainbow_cache.valueIterator();
        while (rb_it.next()) |v| self.allocator.free(v.*);
        self.rainbow_cache.deinit();

        // Free cached resolver-dedup keys
        var rk_it = self.known_resolver_cache.keyIterator();
        while (rk_it.next()) |k| self.allocator.free(k.*);
        self.known_resolver_cache.deinit();

        // Free cached account-dedup keys
        var ak_it = self.account_obs_cache.keyIterator();
        while (ak_it.next()) |k| self.allocator.free(k.*);
        self.account_obs_cache.deinit();

        // Free cached namehash→name values
        var nv_it = self.name_by_namehash_cache.valueIterator();
        while (nv_it.next()) |v| self.allocator.free(v.*);
        self.name_by_namehash_cache.deinit();
    }

    // In-memory cache / dedup accessors — implementations in caches.zig.
    pub const registerResolverOnce = caches.registerResolverOnce;
    pub const registerResolverOnceIfNew = caches.registerResolverOnceIfNew;
    pub const lookupPairedName = caches.lookupPairedName;
    pub const namesBarrierFlush = caches.namesBarrierFlush;
    pub const bufferingEntities = caches.bufferingEntities;
    pub const setNameOwner = caches.setNameOwner;
    pub const setNameResolver = caches.setNameResolver;
    pub const registeredNameExists = caches.registeredNameExists;
    pub const clearKnownResolverCache = caches.clearKnownResolverCache;
    pub const clearAccountObsCache = caches.clearAccountObsCache;
    pub const invalidateControllerCache = caches.invalidateControllerCache;
    pub const getOrLoadActiveControllers = caches.getOrLoadActiveControllers;
    pub const getCachedV1Label = caches.getCachedV1Label;
    pub const putCachedV1Label = caches.putCachedV1Label;
    pub const resolveLabel = caches.resolveLabel;
    /// Replay all stored events to rebuild the names table (--backfill mode).
    pub const replayEventsToRebuildNames = replay_mod.replayEventsToRebuildNames;
    pub const clearReplayStatus = replay_mod.clearReplayStatus;
    pub const writeReplayStatus = replay_mod.writeReplayStatus;
    /// Rebuild the V2 names projection from stored V2 events. In a combined --backfill this
    /// MUST run AFTER replayEventsToRebuildNames so V1→V2 migration lookups find their V1 rows.
    pub const replayV2NamesCore = replay_mod.replayV2NamesCore;
    /// Rebuild the V2 resolver-record projections (addresses/texts/contenthashes) from events.
    pub const replayV2RecordsCore = replay_mod.replayV2RecordsCore;
    /// Rebuild the V2 eac_roles projection from stored EACRolesChanged events.
    pub const replayV2EacRolesCore = replay_mod.replayV2EacRolesCore;
    /// Rebuild the V2 registrations projection from stored LabelRegistered/NameRegistered events.
    pub const replayV2RegistrationsCore = replay_mod.replayV2RegistrationsCore;
    /// Rebuild the accounts projection (V1+V2 observations + backfill seed) from events.
    pub const replayAccountsCore = replay_mod.replayAccountsCore;
    /// Rebuild the V2 registries + registry_entries projections (bootstrap + pointer changes).
    pub const replayV2RegistriesCore = replay_mod.replayV2RegistriesCore;
    pub const trackBlockHash = caches.trackBlockHash;
    pub const resetBlockHashTracking = caches.resetBlockHashTracking;
    pub const getBlockTimestamp = caches.getBlockTimestamp;
    pub const warmBlockTimestampCache = caches.warmBlockTimestampCache;
    pub const clearBlockTimestampCache = caches.clearBlockTimestampCache;
    pub const getNameFromNamehash = caches.getNameFromNamehash;

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
        const c = self.config.v1_contracts; // same struct backs v1 and v2 config
        // isActiveContract skips a DISABLED (zero-address) contract — the manifest
        // `status = .disabled` path (Task 08 criterion 5). Kept as the shared guard.
        if (contract_defs.isActiveContract(addr, c.locked_migration_controller)) return .locked;
        if (contract_defs.isActiveContract(addr, c.unlocked_migration_controller)) return .unlocked;
        return .none;
    }

    pub inline fn getClient(self: *Indexer, protocol: models.Protocol) *rpc.Client {
        _ = protocol;
        return self.v1_client;
    }

    // Event-dispatch config tables/structs — implementations in event_config.zig.
    pub const RegistryEventConfig = event_config.RegistryEventConfig;
    pub const ETH_REGISTRY_EVENTS = event_config.ETH_REGISTRY_EVENTS;
    pub const ETH_REGISTRAR_EVENTS = event_config.ETH_REGISTRAR_EVENTS;
    pub const SUBREGISTRY_ENS_EVENTS = event_config.SUBREGISTRY_ENS_EVENTS;
    pub const SUBREGISTRY_TRANSFER_EVENT = event_config.SUBREGISTRY_TRANSFER_EVENT;
    pub const ResolverEventConfig = event_config.ResolverEventConfig;
    pub const RESOLVER_EVENTS = event_config.RESOLVER_EVENTS;
    pub const V1_REGISTRY_EVENTS = event_config.V1_REGISTRY_EVENTS;
    pub const V1_NAME_WRAPPER_EVENTS = event_config.V1_NAME_WRAPPER_EVENTS;
    pub const V1_BASE_REGISTRAR_EVENTS = event_config.V1_BASE_REGISTRAR_EVENTS;
    pub const V1_ETH_CONTROLLER_EVENTS = event_config.V1_ETH_CONTROLLER_EVENTS;
    pub const V1_REVERSE_REGISTRAR_EVENTS = event_config.V1_REVERSE_REGISTRAR_EVENTS;
    pub const V2_REVERSE_REGISTRAR_EVENTS = event_config.V2_REVERSE_REGISTRAR_EVENTS;
    pub const V2_ETH_RENEWER_EVENTS = event_config.V2_ETH_RENEWER_EVENTS;
    pub const V2_LABEL_STORE_EVENTS = event_config.V2_LABEL_STORE_EVENTS;

    // V1 indexing orchestration (extracted to v1_indexing.zig)
    pub const indexV1EventsChunked = v1_indexing.indexV1EventsChunked;
    pub const indexAllV1Events = v1_indexing.indexAllV1Events;
    pub const v1EraStart = sync_driver.v1EraStart;
    pub const indexPreMigrationRegistryEvents = v1_indexing.indexPreMigrationRegistryEvents;

    // Persistence chokepoints — implementations in persistence.zig.
    pub const insertEventAndNotify = persistence.insertEventAndNotify;
    pub const seedV2Registries = persistence.seedV2Registries;

    // Sync driver + run loop — implementations in sync_driver.zig.
    pub const start = sync_driver.start;
    pub const stop = sync_driver.stop;
    pub const startSingleProtocol = sync_driver.startSingleProtocol;
    pub const indexProtocol = sync_driver.indexProtocol;
    pub const indexBlockRange = sync_driver.indexBlockRange;
    pub const verifyStoredBlockHash = sync_driver.verifyStoredBlockHash;
    pub const rollbackToLastValidBlock = sync_driver.rollbackToLastValidBlock;
    // Persistence + reorg-support chokepoints (bodies in persistence.zig / reorg_support.zig).
    pub const insertName = persistence.insertName;
    pub const markEventBlock = reorg_support.markEventBlock;
    pub const invalidateReorgCursor = reorg_support.invalidateReorgCursor;
    pub const materializePccUncaptured = reorg_support.materializePccUncaptured;
    pub const reconcileReachabilityUncaptured = reorg_support.reconcileReachabilityUncaptured;
    // V2 event fetchers (extracted to event_fetchers.zig)
    pub const indexPhase1V2Events = event_fetchers.indexPhase1V2Events;
    pub const indexSubregistryEvents = event_fetchers.indexSubregistryEvents;
    pub const indexTransferEvents = event_fetchers.indexTransferEvents;
    pub const indexResolverEvents = event_fetchers.indexResolverEvents;
    pub const seedInitGapHealTargets = event_fetchers.seedInitGapHealTargets;
    pub const hasDueInitGapHeals = event_fetchers.hasDueInitGapHeals;
    pub const drainInitGapHeals = event_fetchers.drainInitGapHeals;
    pub const indexV2ReverseRegistrarEvents = event_fetchers.indexV2ReverseRegistrarEvents;
    pub const indexV2RenewerEvents = event_fetchers.indexV2RenewerEvents;
    pub const indexLabelStoreEvents = event_fetchers.indexLabelStoreEvents;

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
    pub const handleEACRolesChangedImpl = handlers_v2_registry.handleEACRolesChangedImpl;
    pub const handleLabelRegistered = handlers_v2_registry.handleLabelRegistered;
    pub const handleLabelStoreLabel = handlers_v2_registry.handleLabelStoreLabel;
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
    pub const handleLegacyTextChanged = handlers_v2_resolver.handleLegacyTextChanged;
    pub const handleAuthorisationChanged = handlers_v2_resolver.handleAuthorisationChanged;
    pub const handleApproved = handlers_v2_resolver.handleApproved;
    pub const handleNamedResource = handlers_v2_resolver.handleNamedResource;
    pub const handleNamedTextResource = handlers_v2_resolver.handleNamedTextResource;
    pub const handleNamedDataResource = handlers_v2_resolver.handleNamedDataResource;
    pub const handleNamedAddrResource = handlers_v2_resolver.handleNamedAddrResource;
    pub const handleDnsRecordChanged = handlers_v2_resolver.handleDnsRecordChanged;
    pub const handleDnsRecordDeleted = handlers_v2_resolver.handleDnsRecordDeleted;
    pub const handleDnsZonehashChanged = handlers_v2_resolver.handleDnsZonehashChanged;
    pub const handleABIChanged = handlers_v2_resolver.handleABIChanged;
    pub const handlePubkeyChanged = handlers_v2_resolver.handlePubkeyChanged;
    pub const handleNameChanged = handlers_v2_resolver.handleNameChanged;
    pub const handleInterfaceChanged = handlers_v2_resolver.handleInterfaceChanged;
    pub const handleVersionChanged = handlers_v2_resolver.handleVersionChanged;
    pub const handleAliasChanged = handlers_v2_resolver.handleAliasChanged;
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
    pub const handleV1NameWrapperTransferSingle = handlers_v1.handleV1NameWrapperTransferSingle;
    pub const handleV1NameWrapperTransferBatch = handlers_v1.handleV1NameWrapperTransferBatch;
    pub const handleV1ERC721Transfer = handlers_v1.handleV1ERC721Transfer;
    pub const handleV1BaseRegistrarNameRegistered = handlers_v1.handleV1BaseRegistrarNameRegistered;
    pub const handleV1BaseRegistrarNameRenewed = handlers_v1.handleV1BaseRegistrarNameRenewed;
    pub const handleV1ControllerAdded = handlers_v1.handleV1ControllerAdded;
    pub const handleV1ControllerRemoved = handlers_v1.handleV1ControllerRemoved;
    pub const handleV1ETHControllerNameRegistered = handlers_v1.handleV1ETHControllerNameRegistered;
    pub const handleV1ETHControllerNameRegistered6Arg = handlers_v1.handleV1ETHControllerNameRegistered6Arg;
    pub const handleV1ETHControllerNameRegistered7Arg = handlers_v1.handleV1ETHControllerNameRegistered7Arg;
    pub const handleV1ETHControllerNameRenewed = handlers_v1.handleV1ETHControllerNameRenewed;
    pub const handleV1ETHControllerNameRenewedWithReferrer = handlers_v1.handleV1ETHControllerNameRenewedWithReferrer;
    pub const handleBasenamesControllerNameRegistered = handlers_v1.handleBasenamesControllerNameRegistered;
    pub const handleBasenamesControllerNameRenewed = handlers_v1.handleBasenamesControllerNameRenewed;
    pub const handleBasenamesRegistrarNameRegisteredWithRecord = handlers_v1.handleBasenamesRegistrarNameRegisteredWithRecord;
    pub const handleV1ReverseClaimed = handlers_v1.handleV1ReverseClaimed;
    pub const handleV2NameForAddrChanged = handlers_v1.handleV2NameForAddrChanged;

    // Backfill functions (extracted to backfill.zig)
    // pub so sync_driver.zig (startSingleProtocol) can reach it via self/Indexer.
    pub const backfillPreMigrationNames = backfill_mod.backfillPreMigrationNames;
    pub const backfillUnknownLabels = backfill_mod.backfillUnknownLabels;
    pub const backfillMissingEth2LDNames = backfill_mod.backfillMissingEth2LDNames;

    // Shared utility functions (extracted to utils.zig)
    pub const emitEvent = utils.emitEvent;
    pub const resolveNamehash = utils.resolveNamehash;
};
