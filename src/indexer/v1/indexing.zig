const std = @import("std");
const zsys = @import("../../utils/system.zig");
const config = @import("../../config.zig");
const constants = @import("../../constants.zig");
const models = @import("../../types/models.zig");
const rpc = @import("../../rpc/client.zig");
const Hash = @import("../../types/hash.zig").Hash;
const Address = @import("../../types/address.zig").Address;
const Indexer = @import("../indexer.zig").Indexer;
const utils = @import("../utils.zig");

/// Generic chunked batch event indexing for V1 events with adaptive chunk sizing
/// Dynamically adjusts chunk size based on event density to optimize RPC calls
pub fn indexV1EventsChunked(
    self: *Indexer,
    protocol: models.Protocol,
    client: *rpc.Client,
    from_block: u64,
    to_block: u64,
    contract_address: Address,
    event_configs: []const Indexer.RegistryEventConfig,
    contract_name: []const u8,
) !void {
    // Predictive adaptive chunk sizing
    const MIN_CHUNK_SIZE: u64 = constants.RpcBatching.min_chunk_size;
    const MAX_CHUNK_SIZE: u64 = self.config.batch_size; // Use configured batch size as maximum
    const TARGET_EVENTS_PER_CHUNK: usize = 25000; // Target ~25000 events per chunk

    // Start with smarter initial estimates based on block range
    const v1_mig_block = self.config.v1_contracts.v1_migration_block;
    var current_chunk_size: u64 = if (v1_mig_block > 0 and from_block < v1_mig_block) 10000 else 100;
    var events_per_block: f64 = if (v1_mig_block > 0 and from_block < v1_mig_block) 0.1 else 5.0;
    var chunk_start = from_block;
    // RPC overflow ceiling — learned from actual overflow failures
    var max_rpc_chunk_size: u64 = MAX_CHUNK_SIZE;

    while (chunk_start <= to_block) {
        // PREDICTIVE: Calculate optimal chunk size BEFORE making request
        // Based on learned event density from previous chunks
        const predicted_chunk_size = blk: {
            if (events_per_block < 0.1) {
                // Very sparse: use maximum chunk size
                break :blk max_rpc_chunk_size;
            }
            // Calculate chunk size to hit target event count, capped by RPC ceiling
            const calculated = @as(u64, @intFromFloat(@ceil(@as(f64, @floatFromInt(TARGET_EVENTS_PER_CHUNK)) / events_per_block)));
            break :blk @min(max_rpc_chunk_size, @max(MIN_CHUNK_SIZE, calculated));
        };
        current_chunk_size = predicted_chunk_size;

        // RETRY LOOP: Handle sudden density spikes that predictor couldn't foresee
        var retry_chunk_size = current_chunk_size;
        const ABSOLUTE_MIN_CHUNK: u64 = 10; // Last resort minimum

        retry_loop: while (true) {
            const chunk_end = @min(chunk_start + retry_chunk_size - 1, to_block);
            const blocks_in_chunk = chunk_end - chunk_start + 1;

            // Log the protocol the caller passed (v1 / v2) instead of a hardcoded "V1";
            // V2 callers (e.g. the V2 reverse-registrar fetcher) reuse this chunked helper
            // and previously produced confusing "Indexing V1 V2 Reverse Registrar …" lines.
            std.log.info("Indexing {s} {s} events from blocks {d}-{d} (chunk_size={d}, predicted_density={d:.2} events/block)", .{
                protocol.toString(),
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
                // Handle both RPC provider buffer overflow (error.RpcError) and http buffer overflow (error.StreamTooLong)
                if ((err == error.RpcError or err == error.StreamTooLong) and retry_chunk_size > ABSOLUTE_MIN_CHUNK) {
                    // Learn the halved size, not the failed one: a ceiling set to the
                    // failing size lets the predictor re-attempt it while the +10%
                    // regrowth climbs back over a provider's hard range cap within a
                    // few chunks — one wasted error round-trip per cycle, forever.
                    retry_chunk_size = @max(ABSOLUTE_MIN_CHUNK, retry_chunk_size / 2);
                    max_rpc_chunk_size = retry_chunk_size;
                    std.log.warn("  Buffer overflow! Retrying with {d} blocks (rpc ceiling now {d})", .{ retry_chunk_size, max_rpc_chunk_size });
                    continue :retry_loop;
                }
                return err; // Other errors or hit minimum chunk size
            };
            defer utils.deinitBatchResults(self.allocator, batch_results);
            self.warmBlockTimestampCache(protocol, batch_results);

            // Process each event type and count total events
            var total_events: usize = 0;
            for (event_configs, 0..) |event_cfg, i| {
                const logs = batch_results[i];
                total_events += logs.len;

                if (logs.len > 0) {
                    std.log.info("  Found {d} {s} {s} event{s}", .{
                        logs.len,
                        protocol.toString(),
                        event_cfg.name,
                        if (logs.len == 1) "" else "s",
                    });
                }

                for (logs) |log| {
                    self.markEventBlock(protocol, log.block_number);
                    try event_cfg.handler(self, protocol, log);
                }
            }

            // LEARNING: Update event density estimate using exponential moving average
            // This smooths out spikes while adapting to trends
            const actual_events_per_block = @as(f64, @floatFromInt(total_events)) / @as(f64, @floatFromInt(blocks_in_chunk));
            const LEARNING_RATE = 0.3; // 30% weight to new data, 70% to history
            const old_density = events_per_block;
            events_per_block = events_per_block * (1.0 - LEARNING_RATE) + actual_events_per_block * LEARNING_RATE;

            // Calculate next chunk size with exponential scaling based on density
            const ideal_chunk_size = @as(f64, @floatFromInt(TARGET_EVENTS_PER_CHUNK)) / @max(0.001, events_per_block);
            const size_ratio = ideal_chunk_size / @as(f64, @floatFromInt(retry_chunk_size));
            const scale_factor = std.math.pow(f64, size_ratio, 0.5); // Square root for smooth exponential scaling
            const density_chunk = @min(MAX_CHUNK_SIZE, @max(MIN_CHUNK_SIZE, @as(u64, @intFromFloat(@as(f64, @floatFromInt(retry_chunk_size)) * scale_factor))));
            // Cap at RPC overflow ceiling (learned from past failures), then slowly grow ceiling back
            const next_chunk_size = @min(density_chunk, max_rpc_chunk_size);
            if (max_rpc_chunk_size < MAX_CHUNK_SIZE) {
                max_rpc_chunk_size = @min(MAX_CHUNK_SIZE, max_rpc_chunk_size + max_rpc_chunk_size / 10);
            }

            if (total_events > TARGET_EVENTS_PER_CHUNK * 2) {
                std.log.info("  High density: {d} events ({d:.2}->{d:.2} events/block), next chunk: {d} blocks", .{
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

            // Apply learned chunk size for next iteration
            current_chunk_size = next_chunk_size;

            chunk_start = chunk_end + 1;
            // Rate limit: wait between batches to avoid hitting RPC provider limits
            if (chunk_start <= to_block) {
                self.rate_limiter.acquire();
            }
            break :retry_loop; // Success - move to next chunk
        }
    }
}

/// EFFICIENT V1 indexing: Process ALL V1 contracts together per chunk
/// Uses topic0 OR matching to combine event types per contract, reducing ~18 RPC sub-requests to ~5
/// Processing order: ETH Controller → Base Registrar → ENS Registry → Name Wrapper → Reverse Registrar
/// (ETH Controller must be first because it provides label text that Base Registrar handlers need)
pub fn indexAllV1Events(self: *Indexer, protocol: models.Protocol, client: *rpc.Client, from_block: u64, to_block: u64) !void {
    if (protocol != .v1) return; // V1 events only exist on mainnet L1

    // Index Old ENS Registry pre-migration events FIRST (only for blocks before
    // the V1 Permanent Registrar migration). The Temporary Registrar (auction)
    // contract has been intentionally removed — it was 2017-2019 only and its
    // tables were not used by any client.
    try indexPreMigrationRegistryEvents(self, protocol, client, from_block, to_block);

    // Predictive adaptive chunk sizing
    const MIN_CHUNK_SIZE: u64 = constants.RpcBatching.min_chunk_size;
    const MAX_CHUNK_SIZE: u64 = self.config.batch_size; // Use configured batch size as maximum
    const TARGET_EVENTS_PER_CHUNK: usize = 25000; // Target ~25000 events per chunk

    // Start with smarter initial estimates based on block range
    // Pre-migration era has ~0.01 events/block, post-migration is denser
    const v1_migration_block = self.config.v1_contracts.v1_migration_block;
    var current_chunk_size: u64 = if (v1_migration_block > 0 and from_block < v1_migration_block) 10000 else 100;
    var events_per_block: f64 = if (self.v1_events_per_block > 0)
        self.v1_events_per_block
    else if (v1_migration_block > 0 and from_block < v1_migration_block) 0.1 else 5.0;
    var chunk_start = from_block;
    // RPC overflow ceiling — learned from actual overflow failures.
    // Prevents the density predictor from overshooting into sizes that will overflow.
    var max_rpc_chunk_size: u64 = if (self.v1_rpc_chunk_ceiling > 0)
        @min(self.v1_rpc_chunk_ceiling, MAX_CHUNK_SIZE)
    else
        MAX_CHUNK_SIZE;
    // Persist what this batch learned so the next batch starts warm.
    defer {
        self.v1_events_per_block = events_per_block;
        self.v1_rpc_chunk_ceiling = max_rpc_chunk_size;
    }

    // Name Wrapper deployment block (from contract config)
    const NAME_WRAPPER_DEPLOYMENT_BLOCK = self.config.v1_contracts.name_wrapper_deployment_block;

    // Pre-build topic arrays for each contract group (constant across chunks)
    const eth_controller_topics = comptime blk: {
        var topics: [Indexer.V1_ETH_CONTROLLER_EVENTS.len]Hash = undefined;
        for (Indexer.V1_ETH_CONTROLLER_EVENTS, 0..) |cfg, i| {
            topics[i] = cfg.event_hash;
        }
        break :blk topics;
    };
    const base_registrar_topics = comptime blk: {
        var topics: [Indexer.V1_BASE_REGISTRAR_EVENTS.len]Hash = undefined;
        for (Indexer.V1_BASE_REGISTRAR_EVENTS, 0..) |cfg, i| {
            topics[i] = cfg.event_hash;
        }
        break :blk topics;
    };
    const registry_topics = comptime blk: {
        var topics: [Indexer.V1_REGISTRY_EVENTS.len]Hash = undefined;
        for (Indexer.V1_REGISTRY_EVENTS, 0..) |cfg, i| {
            topics[i] = cfg.event_hash;
        }
        break :blk topics;
    };
    const name_wrapper_topics = comptime blk: {
        var topics: [Indexer.V1_NAME_WRAPPER_EVENTS.len]Hash = undefined;
        for (Indexer.V1_NAME_WRAPPER_EVENTS, 0..) |cfg, i| {
            topics[i] = cfg.event_hash;
        }
        break :blk topics;
    };
    const reverse_registrar_topics = comptime blk: {
        var topics: [Indexer.V1_REVERSE_REGISTRAR_EVENTS.len]Hash = undefined;
        for (Indexer.V1_REVERSE_REGISTRAR_EVENTS, 0..) |cfg, i| {
            topics[i] = cfg.event_hash;
        }
        break :blk topics;
    };

    while (chunk_start <= to_block) {
        // Flag to indicate if we need to reprocess this chunk due to new controllers
        var needs_controller_reprocess = false;

        // PREDICTIVE: Calculate optimal chunk size BEFORE making request, capped by RPC ceiling
        const predicted_chunk_size = blk: {
            if (events_per_block < 0.1) {
                break :blk max_rpc_chunk_size;
            }
            const calculated = @as(u64, @intFromFloat(@ceil(@as(f64, @floatFromInt(TARGET_EVENTS_PER_CHUNK)) / events_per_block)));
            break :blk @min(max_rpc_chunk_size, @max(MIN_CHUNK_SIZE, calculated));
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

            // Build combined requests using topic0 OR matching (5 requests instead of ~18)
            // Each request covers one contract group with ALL event types combined
            const active_controllers = try self.getOrLoadActiveControllers();

            // Batch request index mapping:
            // [0] = ETH Controllers (all addresses, topic0 OR NameRegistered|NameRenewed)
            // [1] = Base Registrar (topic0 OR Transfer|NameRegistered|NameRenewed|ControllerAdded|ControllerRemoved)
            // [2] = ENS Registry (topic0 OR NewOwner|Transfer|NewResolver|NewTTL)
            // [3] = Name Wrapper (topic0 OR NameWrapped|NameUnwrapped|FusesSet|ExpiryExtended) - conditional
            // [4] = Reverse Registrar (topic0 ReverseClaimed)
            const include_name_wrapper = chunk_end >= NAME_WRAPPER_DEPLOYMENT_BLOCK;
            const num_requests: usize = if (include_name_wrapper) 5 else 4;

            // Build controller addresses for ETH Controller request
            var controller_addrs: []const Address = undefined;
            var controller_addrs_heap: ?[]Address = null;
            defer if (controller_addrs_heap) |h| self.allocator.free(h);

            if (active_controllers.len == 0) {
                // Fallback to config
                const fallback = try self.allocator.alloc(Address, 1);
                fallback[0] = self.config.v1_contracts.eth_registrar_controller;
                controller_addrs_heap = fallback;
                controller_addrs = fallback;
                std.log.warn("No active V1 controllers found in database - using config fallback", .{});
            } else {
                controller_addrs = active_controllers;
            }

            var requests = try self.allocator.alloc(rpc.Client.MultiAddressLogsRequest, num_requests);
            defer self.allocator.free(requests);

            // [0] ETH Controllers - all controller addresses, topic0 OR
            requests[0] = .{
                .from_block = chunk_start,
                .to_block = chunk_end,
                .addresses = controller_addrs,
                .topic0_or = &eth_controller_topics,
            };

            // [1] Base Registrar
            const base_registrar_addr = [_]Address{self.config.v1_contracts.base_registrar};
            requests[1] = .{
                .from_block = chunk_start,
                .to_block = chunk_end,
                .addresses = &base_registrar_addr,
                .topic0_or = &base_registrar_topics,
            };

            // [2] ENS Registry
            const ens_registry_addr = [_]Address{self.config.v1_contracts.ens_registry};
            requests[2] = .{
                .from_block = chunk_start,
                .to_block = chunk_end,
                .addresses = &ens_registry_addr,
                .topic0_or = &registry_topics,
            };

            // [3] Name Wrapper (conditional) or [3] Reverse Registrar
            const reverse_registrar_addr = [_]Address{self.config.v1_contracts.reverse_registrar};
            if (include_name_wrapper) {
                const name_wrapper_addr = [_]Address{self.config.v1_contracts.name_wrapper};
                requests[3] = .{
                    .from_block = @max(chunk_start, NAME_WRAPPER_DEPLOYMENT_BLOCK),
                    .to_block = chunk_end,
                    .addresses = &name_wrapper_addr,
                    .topic0_or = &name_wrapper_topics,
                };
                requests[4] = .{
                    .from_block = chunk_start,
                    .to_block = chunk_end,
                    .addresses = &reverse_registrar_addr,
                    .topic0_or = &reverse_registrar_topics,
                };
            } else {
                requests[3] = .{
                    .from_block = chunk_start,
                    .to_block = chunk_end,
                    .addresses = &reverse_registrar_addr,
                    .topic0_or = &reverse_registrar_topics,
                };
            }

            // Execute combined batch RPC call - retry with smaller chunks if buffer overflow
            const fetch_timer = zsys.milliTimestamp();
            const batch_results = client.getLogsMultiAddressBatch(requests) catch |err| {
                if ((err == error.RpcError or err == error.StreamTooLong) and retry_chunk_size > ABSOLUTE_MIN_CHUNK) {
                    // Learn the halved size, not the failed one: a ceiling set to the
                    // failing size lets the predictor re-attempt it while the +10%
                    // regrowth climbs back over a provider's hard range cap (Alchemy:
                    // 10k blocks) within 2-3 chunks — a wasted error round-trip and a
                    // half-sized chunk per cycle, forever.
                    retry_chunk_size = @max(ABSOLUTE_MIN_CHUNK, retry_chunk_size / 2);
                    max_rpc_chunk_size = retry_chunk_size;
                    std.log.warn("  Buffer overflow! Retrying with {d} blocks (rpc ceiling now {d})", .{ retry_chunk_size, max_rpc_chunk_size });
                    continue :retry_loop;
                }
                return err;
            };
            defer utils.deinitBatchResults(self.allocator, batch_results);
            self.warmBlockTimestampCache(protocol, batch_results);
            const fetch_elapsed = zsys.milliTimestamp() - fetch_timer;

            // Track controller count before processing to detect new controllers
            const controller_count_before = active_controllers.len;
            var total_events: usize = 0;

            // Activate the write buffer for batched DB writes — EXCEPT within the reorg
            // retention window of the tip. The buffer dedups updates across the whole
            // chunk, collapsing a name's per-block history into one final value flushed
            // at the chunk's last block. That would prevent the reorg undo-log from
            // restoring exact state-as-of-N if a reorg later lands inside this chunk.
            // Near the tip we therefore write direct per-event so each mutation is
            // captured at its own block; the RPC batch is unaffected (still one call).
            const REORG_WINDOW: u64 = 1000; // matches sync.zig REORG_RETENTION_BLOCKS / pruneOldBlockHashes
            // reorg_arm distinguishes the real chain tip from a mere batch end: the
            // driver arms it only when the batch lands within the reorg window of the
            // chain head. Gating on to_block alone made the last REORG_WINDOW blocks
            // of EVERY bulk batch run unbuffered (direct per-event SQL, ~3x slower).
            const near_tip = self.reorg_arm and to_block >= REORG_WINDOW and chunk_end > to_block - REORG_WINDOW;
            self.write_buffer.active = !near_tip;
            errdefer {
                self.write_buffer.active = false;
                self.write_buffer.reset();
            }

            // Process results in required order, dispatching by topic[0]
            const chunk_timer = zsys.milliTimestamp();

            // 1. ETH Controller events (MUST be first - provides labels for Base Registrar)
            const eth_logs = batch_results[0];
            total_events += eth_logs.len;
            for (eth_logs) |log| {
                if (log.topics.len == 0) continue;
                self.markEventBlock(protocol, log.block_number);
                inline for (Indexer.V1_ETH_CONTROLLER_EVENTS) |cfg| {
                    if (log.topics[0].eql(cfg.event_hash)) {
                        try cfg.handler(self, protocol, log);
                        break;
                    }
                }
            }
            const eth_elapsed = zsys.milliTimestamp() - chunk_timer;

            // 2. Base Registrar events
            const base_timer = zsys.milliTimestamp();
            const base_logs = batch_results[1];
            total_events += base_logs.len;
            for (base_logs) |log| {
                if (log.topics.len == 0) continue;
                self.markEventBlock(protocol, log.block_number);
                inline for (Indexer.V1_BASE_REGISTRAR_EVENTS) |cfg| {
                    if (log.topics[0].eql(cfg.event_hash)) {
                        try cfg.handler(self, protocol, log);
                        break;
                    }
                }
            }
            const base_elapsed = zsys.milliTimestamp() - base_timer;

            // 3. ENS Registry events
            const registry_timer = zsys.milliTimestamp();
            const registry_logs = batch_results[2];
            total_events += registry_logs.len;
            var reg_type_ns = [_]i128{0} ** Indexer.V1_REGISTRY_EVENTS.len;
            var reg_type_count = [_]usize{0} ** Indexer.V1_REGISTRY_EVENTS.len;
            self.newowner_phase_ns = [_]i128{0} ** 5;
            for (registry_logs) |log| {
                if (log.topics.len == 0) continue;
                self.markEventBlock(protocol, log.block_number);
                inline for (Indexer.V1_REGISTRY_EVENTS, 0..) |cfg, type_i| {
                    if (log.topics[0].eql(cfg.event_hash)) {
                        const h0 = zsys.nanoTimestamp();
                        try cfg.handler(self, protocol, log);
                        reg_type_ns[type_i] += zsys.nanoTimestamp() - h0;
                        reg_type_count[type_i] += 1;
                        break;
                    }
                }
            }
            const registry_elapsed = zsys.milliTimestamp() - registry_timer;
            // Spike forensics: when the registry group ran hot, name the handler.
            if (registry_elapsed > 5000) {
                inline for (Indexer.V1_REGISTRY_EVENTS, 0..) |cfg, type_i| {
                    if (reg_type_count[type_i] > 0) {
                        std.log.info("    reg breakdown: {s} {d} events in {d}ms", .{
                            cfg.name,
                            reg_type_count[type_i],
                            @as(i64, @intCast(@divTrunc(reg_type_ns[type_i], std.time.ns_per_ms))),
                        });
                    }
                }
                const ph = self.newowner_phase_ns;
                std.log.info("    NewOwner phases: resolve={d}ms parent={d}ms rw={d}ms unknown={d}ms emit={d}ms", .{
                    @as(i64, @intCast(@divTrunc(ph[0], std.time.ns_per_ms))),
                    @as(i64, @intCast(@divTrunc(ph[1], std.time.ns_per_ms))),
                    @as(i64, @intCast(@divTrunc(ph[2], std.time.ns_per_ms))),
                    @as(i64, @intCast(@divTrunc(ph[3], std.time.ns_per_ms))),
                    @as(i64, @intCast(@divTrunc(ph[4], std.time.ns_per_ms))),
                });
            }

            // 4. Name Wrapper events (if included)
            var wrapper_count: usize = 0;
            var wrapper_elapsed: i64 = 0;
            if (include_name_wrapper) {
                const wrapper_timer = zsys.milliTimestamp();
                const wrapper_logs = batch_results[3];
                wrapper_count = wrapper_logs.len;
                total_events += wrapper_logs.len;
                for (wrapper_logs) |log| {
                    if (log.topics.len == 0) continue;
                    self.markEventBlock(protocol, log.block_number);
                    inline for (Indexer.V1_NAME_WRAPPER_EVENTS) |cfg| {
                        if (log.topics[0].eql(cfg.event_hash)) {
                            try cfg.handler(self, protocol, log);
                            break;
                        }
                    }
                }
                wrapper_elapsed = zsys.milliTimestamp() - wrapper_timer;
            }

            // 5. Reverse Registrar events
            const reverse_idx: usize = if (include_name_wrapper) 4 else 3;
            const reverse_logs = batch_results[reverse_idx];
            total_events += reverse_logs.len;
            for (reverse_logs) |log| {
                if (log.topics.len == 0) continue;
                self.markEventBlock(protocol, log.block_number);
                inline for (Indexer.V1_REVERSE_REGISTRAR_EVENTS) |cfg| {
                    if (log.topics[0].eql(cfg.event_hash)) {
                        try cfg.handler(self, protocol, log);
                        break;
                    }
                }
            }

            const total_process_elapsed = zsys.milliTimestamp() - chunk_timer;

            // Flush write buffer to database (batched writes)
            self.write_buffer.active = false;
            try self.write_buffer.flush(self.database);

            const total_with_flush = zsys.milliTimestamp() - chunk_timer;
            const rb_ms = self.rainbow_probe_ns / std.time.ns_per_ms;
            const rb_count = self.rainbow_probe_count;
            self.rainbow_probe_ns = 0;
            self.rainbow_probe_count = 0;
            std.log.info("  Processed {d} events in {d}ms, fetched in {d}ms, flushed in {d}ms (eth={d}/{d}ms base={d}/{d}ms reg={d}/{d}ms wrap={d}/{d}ms rev={d} rb={d}/{d}ms)", .{
                total_events,
                total_process_elapsed,
                fetch_elapsed,
                total_with_flush - total_process_elapsed,
                eth_logs.len,
                eth_elapsed,
                base_logs.len,
                base_elapsed,
                registry_logs.len,
                registry_elapsed,
                wrapper_count,
                wrapper_elapsed,
                reverse_logs.len,
                rb_count,
                rb_ms,
            });

            // Check if new controllers were added during processing
            var has_new_controller = false;
            if (self.v1_active_controllers == null) {
                const controllers_after = try self.getOrLoadActiveControllers();
                if (controllers_after.len > controller_count_before) {
                    has_new_controller = true;
                    std.log.warn("  New controller discovered! Reprocessing chunk {d}-{d}", .{ chunk_start, chunk_end });
                }
            }

            if (has_new_controller) {
                needs_controller_reprocess = true;
                break :retry_loop;
            }

            // LEARNING: Update event density estimate using exponential moving average
            const actual_events_per_block = @as(f64, @floatFromInt(total_events)) / @as(f64, @floatFromInt(blocks_in_chunk));
            const LEARNING_RATE = 0.3;
            const old_density = events_per_block;
            events_per_block = events_per_block * (1.0 - LEARNING_RATE) + actual_events_per_block * LEARNING_RATE;

            const ideal_chunk_size = @as(f64, @floatFromInt(TARGET_EVENTS_PER_CHUNK)) / @max(0.001, events_per_block);
            const size_ratio = ideal_chunk_size / @as(f64, @floatFromInt(retry_chunk_size));
            const scale_factor = std.math.pow(f64, size_ratio, 0.5);
            const density_chunk = @min(MAX_CHUNK_SIZE, @max(MIN_CHUNK_SIZE, @as(u64, @intFromFloat(@as(f64, @floatFromInt(retry_chunk_size)) * scale_factor))));
            // Cap at RPC overflow ceiling (learned from past failures), then slowly grow ceiling back
            const next_chunk_size = @min(density_chunk, max_rpc_chunk_size);
            if (max_rpc_chunk_size < MAX_CHUNK_SIZE) {
                // Gradually relax ceiling by 10% per successful chunk (density may change in later blocks)
                max_rpc_chunk_size = @min(MAX_CHUNK_SIZE, max_rpc_chunk_size + max_rpc_chunk_size / 10);
            }

            if (total_events > TARGET_EVENTS_PER_CHUNK * 2) {
                std.log.info("  High density: {d} events ({d:.2}->{d:.2} events/block), next chunk: {d} blocks", .{
                    total_events, old_density, events_per_block, next_chunk_size,
                });
            } else if (total_events < TARGET_EVENTS_PER_CHUNK / 2) {
                std.log.info("  Low density: {d} events ({d:.2}->{d:.2} events/block), next chunk: {d} blocks", .{
                    total_events, old_density, events_per_block, next_chunk_size,
                });
            }

            // Apply learned chunk size for next iteration
            current_chunk_size = next_chunk_size;

            if (!needs_controller_reprocess) {
                // Bulk sync: seal this chunk's work (data + cursor stay atomic) and
                // drain the WAL while its pages are still hot, so the wal-index
                // never grows past one chunk. Near the tip the batch remains a
                // single transaction for reorg-undo consistency.
                if (!self.reorg_arm) {
                    try self.database.commitTransaction();
                    self.database.checkpointWalPassive();
                    try self.database.beginTransaction();
                }
                chunk_start = chunk_end + 1;
                if (chunk_start <= to_block) {
                    self.rate_limiter.acquire();
                }
            }
            break :retry_loop;
        }
    }
}

/// Index pre-migration events: Old ENS Registry only, in a single batched pass.
/// Old ENS Registry (0x314159...): NewOwner, Transfer, NewResolver, NewTTL
/// Active from May 2017 (block 3327417) to May 2019 (block ~9380410).
///
/// Note: the 2017-2019 Temporary Registrar (auction) contract used to be indexed
/// here as well. It has been removed (audit finding #8): the auction handlers had
/// data-corruption bugs and no client consumed the auction tables. The schema
/// tables (`temp_auctions`, `temp_bids`, `temp_bid_reveals`, `temp_invalidations`)
/// remain in `schema/008_temporary_registrar.sql` so existing DBs don't error on
/// startup, but they are no longer populated.
pub fn indexPreMigrationRegistryEvents(self: *Indexer, protocol: models.Protocol, client: *rpc.Client, from_block: u64, to_block: u64) !void {
    if (protocol != .v1) return; // Old ENS Registry only exists on mainnet L1

    // V1 Permanent Registrar migration block (from contract config)
    const v1_migration_block = self.config.v1_contracts.v1_migration_block;
    if (v1_migration_block == 0) return; // Testnets don't have a pre-migration era
    if (from_block >= v1_migration_block) return; // No pre-migration events after migration

    // Adjust to_block to not exceed migration block
    const adjusted_to_block = if (to_block >= v1_migration_block) v1_migration_block - 1 else to_block;

    // Use old ENS registry for pre-migration period (new registry didn't exist yet)
    const old_registry = self.config.v1_contracts.old_ens_registry;

    // Single contract, batched per event topic
    const total_event_configs = Indexer.V1_REGISTRY_EVENTS.len;

    const ContractEventPair = struct {
        address: Address,
        config: Indexer.RegistryEventConfig,
    };

    var pairs: [total_event_configs]ContractEventPair = undefined;
    var idx: usize = 0;

    for (Indexer.V1_REGISTRY_EVENTS) |event_cfg| {
        pairs[idx] = .{
            .address = old_registry,
            .config = event_cfg,
        };
        idx += 1;
    }

    // Adaptive chunked indexing (single pass over the block range)
    const MIN_CHUNK_SIZE: u64 = constants.RpcBatching.min_chunk_size;
    const MAX_CHUNK_SIZE: u64 = self.config.batch_size;
    const TARGET_EVENTS_PER_CHUNK: usize = 25000;

    // Pre-migration era is sparse (~0.01 events/block), start with large chunks
    var current_chunk_size: u64 = 10000;
    var events_per_block: f64 = 0.1;
    var chunk_start = from_block;

    while (chunk_start <= adjusted_to_block) {
        const predicted_chunk_size = blk: {
            if (events_per_block < 0.1) {
                break :blk MAX_CHUNK_SIZE;
            }
            const calculated = @as(u64, @intFromFloat(@ceil(@as(f64, @floatFromInt(TARGET_EVENTS_PER_CHUNK)) / events_per_block)));
            break :blk @min(MAX_CHUNK_SIZE, @max(MIN_CHUNK_SIZE, calculated));
        };
        current_chunk_size = predicted_chunk_size;

        var retry_chunk_size = current_chunk_size;
        const ABSOLUTE_MIN_CHUNK: u64 = 10;

        retry_loop: while (true) {
            const chunk_end = @min(chunk_start + retry_chunk_size - 1, adjusted_to_block);
            const blocks_in_chunk = chunk_end - chunk_start + 1;

            std.log.info("Indexing pre-migration events from blocks {d}-{d} (chunk_size={d}, predicted_density={d:.2} events/block)", .{
                chunk_start,
                chunk_end,
                retry_chunk_size,
                events_per_block,
            });

            // Build batch requests for all event types across both contracts
            var batch_requests = try self.allocator.alloc(rpc.Client.BatchGetLogsRequest, total_event_configs);
            defer self.allocator.free(batch_requests);

            var topics_arrays = try self.allocator.alloc([]const ?Hash, total_event_configs);
            defer {
                for (topics_arrays) |topics| {
                    self.allocator.free(topics);
                }
                self.allocator.free(topics_arrays);
            }

            for (&pairs, 0..) |*pair, i| {
                var topics = try self.allocator.alloc(?Hash, 1);
                topics[0] = pair.config.event_hash;
                topics_arrays[i] = topics;

                batch_requests[i] = .{
                    .from_block = chunk_start,
                    .to_block = chunk_end,
                    .address = pair.address,
                    .topics = topics,
                };
            }

            const batch_results = client.getLogsBatch(batch_requests) catch |err| {
                if ((err == error.RpcError or err == error.StreamTooLong) and retry_chunk_size > ABSOLUTE_MIN_CHUNK) {
                    retry_chunk_size = @max(ABSOLUTE_MIN_CHUNK, retry_chunk_size / 2);
                    std.log.warn("  🔄 Buffer overflow! Retrying with smaller chunk: {d} blocks", .{retry_chunk_size});
                    continue :retry_loop;
                }
                return err;
            };
            defer utils.deinitBatchResults(self.allocator, batch_results);
            self.warmBlockTimestampCache(protocol, batch_results);

            var total_events: usize = 0;
            for (&pairs, 0..) |*pair, i| {
                const logs = batch_results[i];
                total_events += logs.len;

                if (logs.len > 0) {
                    const contract_name = "Old ENS Registry";
                    std.log.info("  Found {d} {s} {s} event{s}", .{
                        logs.len,
                        contract_name,
                        pair.config.name,
                        if (logs.len == 1) "" else "s",
                    });
                }

                for (logs) |log| {
                    self.markEventBlock(protocol, log.block_number);
                    try pair.config.handler(self, protocol, log);
                }
            }

            // Update density estimate
            const actual_events_per_block = @as(f64, @floatFromInt(total_events)) / @as(f64, @floatFromInt(blocks_in_chunk));
            const LEARNING_RATE = 0.3;
            const old_density = events_per_block;
            events_per_block = events_per_block * (1.0 - LEARNING_RATE) + actual_events_per_block * LEARNING_RATE;

            const ideal_chunk_size = @as(f64, @floatFromInt(TARGET_EVENTS_PER_CHUNK)) / @max(0.001, events_per_block);
            const size_ratio = ideal_chunk_size / @as(f64, @floatFromInt(retry_chunk_size));
            const scale_factor = std.math.pow(f64, size_ratio, 0.5);
            const next_chunk_size = @min(MAX_CHUNK_SIZE, @max(MIN_CHUNK_SIZE, @as(u64, @intFromFloat(@as(f64, @floatFromInt(retry_chunk_size)) * scale_factor))));

            if (total_events > TARGET_EVENTS_PER_CHUNK * 2) {
                std.log.info("  ⚠️  High density: {d} events ({d:.2}→{d:.2} events/block), next chunk: {d} blocks", .{
                    total_events, old_density, events_per_block, next_chunk_size,
                });
            } else if (total_events < TARGET_EVENTS_PER_CHUNK / 2) {
                std.log.info("  ✅ Low density: {d} events ({d:.2}→{d:.2} events/block), next chunk: {d} blocks", .{
                    total_events, old_density, events_per_block, next_chunk_size,
                });
            }

            // Apply learned chunk size for next iteration
            current_chunk_size = next_chunk_size;

            chunk_start = chunk_end + 1;
            if (chunk_start <= adjusted_to_block) {
                zsys.sleep(constants.Timing.rpc_batch_delay_ms * std.time.ns_per_ms);
            }
            break :retry_loop;
        }
    }
}
