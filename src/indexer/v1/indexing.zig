const std = @import("std");
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
    chain: models.Chain,
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

    var current_chunk_size: u64 = 100; // Start conservative
    var events_per_block: f64 = 5.0; // Initial estimate: 5 events/block average
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
            defer utils.deinitBatchResults(self.allocator, batch_results);

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
pub fn indexAllV1Events(self: *Indexer, chain: models.Chain, client: *rpc.Client, from_block: u64, to_block: u64) !void {
    if (chain != .l1) return; // V1 events only exist on mainnet L1

    // Index Temporary Registrar events FIRST (for pre-migration blocks only)
    // This function internally checks block ranges and only indexes before block 9380410
    try indexTempRegistrarEvents(self, chain, client, from_block, to_block);

    // Predictive adaptive chunk sizing
    const MIN_CHUNK_SIZE: u64 = constants.RpcBatching.min_chunk_size;
    const MAX_CHUNK_SIZE: u64 = self.config.batch_size; // Use configured batch size as maximum
    const TARGET_EVENTS_PER_CHUNK: usize = 25000; // Target ~25000 events per chunk

    var current_chunk_size: u64 = 100; // Start conservative
    var events_per_block: f64 = 5.0; // Initial estimate: 5 events/block average
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
                event_config: Indexer.RegistryEventConfig,
                contract_addr: Address,
            };
            var request_info_list: std.ArrayList(ContractEventInfo) = .{};
            defer request_info_list.deinit(self.allocator);

            // 1. ETH Registrar Controller events - MUST BE FIRST!
            // ETH Controller events contain the label text which Base Registrar needs
            // Query active controllers dynamically from database
            const v1_controllers = @import("../../storage/v1_controllers.zig");
            const active_controllers = try v1_controllers.getActiveControllers(self.allocator, self.database);
            defer self.allocator.free(active_controllers);

            if (active_controllers.len == 0) {
                std.log.warn("No active V1 controllers found in database - using config fallback", .{});
                // Fallback to config if no controllers in DB (e.g., fresh database)
                for (Indexer.V1_ETH_CONTROLLER_EVENTS) |event_cfg| {
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

                    for (Indexer.V1_ETH_CONTROLLER_EVENTS) |event_cfg| {
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
            for (Indexer.V1_BASE_REGISTRAR_EVENTS) |event_cfg| {
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
            for (Indexer.V1_REGISTRY_EVENTS) |event_cfg| {
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
                for (Indexer.V1_NAME_WRAPPER_EVENTS) |event_cfg| {
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
            for (Indexer.V1_REVERSE_REGISTRAR_EVENTS) |event_cfg| {
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
            defer utils.deinitBatchResults(self.allocator, batch_results);

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

/// Index Temporary Registrar events (Pre-V1 Migration, only on L1/mainnet)
/// AuctionStarted, NewBid, BidRevealed, HashRegistered, HashReleased, HashInvalidated
/// Active from May 2017 (block 3327417) to May 2019 (block 9380410)
pub fn indexTempRegistrarEvents(self: *Indexer, chain: models.Chain, client: *rpc.Client, from_block: u64, to_block: u64) !void {
    if (chain != .l1) return; // Temporary Registrar only exists on mainnet L1

    // V1 Permanent Registrar migration block (from contract config)
    const v1_migration_block = self.config.l1_contracts.v1_migration_block;
    if (v1_migration_block == 0) return; // Testnets don't have temp registrar
    if (from_block >= v1_migration_block) return; // No temp registrar events after migration

    // Adjust to_block to not exceed migration block
    const adjusted_to_block = if (to_block >= v1_migration_block) v1_migration_block - 1 else to_block;

    try indexV1EventsChunked(
        self,
        chain,
        client,
        from_block,
        adjusted_to_block,
        self.config.l1_contracts.temporary_registrar,
        &Indexer.TEMP_REGISTRAR_EVENTS,
        "Temporary Registrar",
    );

    // Index ENS Registry events to create name relationships
    // NewOwner, NewResolver, Transfer events from the ENS Registry contract
    // This captures the actual domain ownership and metadata during the temp registrar period
    try indexV1EventsChunked(
        self,
        chain,
        client,
        from_block,
        adjusted_to_block,
        self.config.l1_contracts.ens_registry,
        &Indexer.V1_REGISTRY_EVENTS,
        "ENS Registry (Pre-Migration)",
    );
}

/// Index V1 ENS Registry events (only on L1/mainnet)
/// NewOwner, Transfer, NewResolver, NewTTL
pub fn indexV1RegistryEvents(self: *Indexer, chain: models.Chain, client: *rpc.Client, from_block: u64, to_block: u64) !void {
    if (chain != .l1) return; // V1 events only exist on mainnet L1
    try indexV1EventsChunked(
        self,
        chain,
        client,
        from_block,
        to_block,
        self.config.l1_contracts.ens_registry,
        &Indexer.V1_REGISTRY_EVENTS,
        "ENS Registry",
    );
}

/// Index V1 Name Wrapper events (only on L1/mainnet, from block 15628465)
/// NameWrapped, NameUnwrapped, FusesSet, ExpiryExtended
pub fn indexV1NameWrapperEvents(self: *Indexer, chain: models.Chain, client: *rpc.Client, from_block: u64, to_block: u64) !void {
    if (chain != .l1) return; // V1 events only exist on mainnet L1

    // Name Wrapper deployment block (from contract config)
    const name_wrapper_deployment = self.config.l1_contracts.name_wrapper_deployment_block;
    if (name_wrapper_deployment == 0) return; // Testnets may not have Name Wrapper at same block
    if (to_block < name_wrapper_deployment) return;

    const adjusted_from_block = if (from_block < name_wrapper_deployment) name_wrapper_deployment else from_block;

    try indexV1EventsChunked(
        self,
        chain,
        client,
        adjusted_from_block,
        to_block,
        self.config.l1_contracts.name_wrapper,
        &Indexer.V1_NAME_WRAPPER_EVENTS,
        "Name Wrapper",
    );
}

/// Index V1 Base Registrar events (only on L1/mainnet)
/// ERC721 Transfer, NameRegistered, NameRenewed
pub fn indexV1BaseRegistrarEvents(self: *Indexer, chain: models.Chain, client: *rpc.Client, from_block: u64, to_block: u64) !void {
    if (chain != .l1) return; // V1 events only exist on mainnet L1
    try indexV1EventsChunked(
        self,
        chain,
        client,
        from_block,
        to_block,
        self.config.l1_contracts.base_registrar,
        &Indexer.V1_BASE_REGISTRAR_EVENTS,
        "Base Registrar",
    );
}

/// Index V1 Reverse Registrar events (only on L1/mainnet)
/// ReverseClaimed
pub fn indexV1ReverseRegistrarEvents(self: *Indexer, chain: models.Chain, client: *rpc.Client, from_block: u64, to_block: u64) !void {
    if (chain != .l1) return; // V1 events only exist on mainnet L1
    try indexV1EventsChunked(
        self,
        chain,
        client,
        from_block,
        to_block,
        self.config.l1_contracts.reverse_registrar,
        &Indexer.V1_REVERSE_REGISTRAR_EVENTS,
        "Reverse Registrar",
    );
}
