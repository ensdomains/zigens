const std = @import("std");
const config = @import("../config.zig");
const constants = @import("../constants.zig");
const models = @import("../types/models.zig");
// ABI decoding migrated to eth.zig-backed shim. EventSignatures is re-exported
// from the shim, so this file's `abi.EventSignatures.*` references still work.
// Old `abi.zig` kept for fallback.
const abi = @import("abi_eth.zig");
const rpc = @import("../rpc/client.zig");
const Hash = @import("../types/hash.zig").Hash;
const Address = @import("../types/address.zig").Address;
const Indexer = @import("indexer.zig").Indexer;
const utils = @import("utils.zig");

pub fn indexSubregistryEvents(self: *Indexer, protocol: models.Protocol, client: *rpc.Client, from_block: u64, to_block: u64) !void {
    // Get the main registry address to exclude it
    const main_registry_addr = self.getEthRegistry(protocol);
    const main_registry_hex = try main_registry_addr.toHex(self.allocator);
    defer self.allocator.free(main_registry_hex);

    // Discover new subregistries and get all known ones (uses cache table for performance)
    var discovery = try self.database.discoverAndGetSubregistries(protocol, main_registry_hex, from_block, to_block);
    defer discovery.deinit(self.allocator);

    // Backfill historical events for newly discovered subregistries.
    // When a subregistry is first registered via SubregistryUpdate, it may have already emitted events
    // (e.g. NameRegistered, EACRolesGranted during initialization) that we missed. Fetch those now.
    if (discovery.newly_discovered.len > 0 and from_block > 0) {
        const backfill_from = self.config.start_block;
        std.log.info("Backfilling {d} newly discovered subregistr{s} from block {d} to {d}", .{
            discovery.newly_discovered.len,
            if (discovery.newly_discovered.len == 1) "y" else "ies",
            backfill_from,
            from_block - 1,
        });
        for (discovery.newly_discovered) |subreg_str| {
            const addr = Address.fromHex(subreg_str) catch continue;
            backfillSubregistryEvents(self, protocol, client, addr, backfill_from, from_block - 1) catch |err| {
                std.log.warn("Failed to backfill subregistry {s}: {}", .{ subreg_str, err });
            };
        }
    }

    const subregistries = discovery.all;

    if (subregistries.len == 0) {
        std.log.debug("No subregistries found for {s}", .{protocol.toString()});
        return;
    }

    std.log.debug("Indexing {d} subregistr{s} for {s} from blocks {d}-{d}", .{
        subregistries.len,
        if (subregistries.len == 1) "y" else "ies",
        protocol.toString(),
        from_block,
        to_block,
    });

    // Build HashSet of known subregistries for O(1) filtering.
    // Pre-size to avoid repeated grow+rehash as we insert; without the hint, a HashMap
    // doubles capacity ~log2(N) times.
    var known_subreg_set = std.AutoHashMap([20]u8, void).init(self.allocator);
    defer known_subreg_set.deinit();
    try known_subreg_set.ensureTotalCapacity(@intCast(subregistries.len));

    for (subregistries) |subreg_str| {
        const addr = Address.fromHex(subreg_str) catch continue;
        try known_subreg_set.put(addr.bytes, {});
    }

    // ========================================================================
    // STEP 1: Topic-only query for ENS-specific events
    // These events have low noise on mainnet - only ENS contracts use them
    // Uses adaptive chunking for large block ranges
    // ========================================================================
    var ens_event_topics: [Indexer.SUBREGISTRY_ENS_EVENTS.len]Hash = undefined;
    inline for (Indexer.SUBREGISTRY_ENS_EVENTS, 0..) |event_cfg, i| {
        ens_event_topics[i] = event_cfg.event_hash;
    }

    const ENS_MAX_CHUNK: u64 = 10000; // ENS events are less common, can use larger chunks
    const ENS_MIN_CHUNK: u64 = 500; // Minimum before giving up

    // Process ENS events, auto-registering unknown subregistries
    var ens_processed: usize = 0;
    var ens_auto_registered: usize = 0;
    var ens_total_fetched: usize = 0;

    var ens_chunk_size: u64 = ENS_MAX_CHUNK;
    var ens_chunk_from = from_block;

    while (ens_chunk_from <= to_block) {
        var retry_chunk_size = ens_chunk_size;

        // Retry loop with adaptive chunk size
        const ens_logs = while (retry_chunk_size >= ENS_MIN_CHUNK) {
            const chunk_to = @min(ens_chunk_from + retry_chunk_size - 1, to_block);

            const logs = client.getLogsMultiAddress(.{
                .from_block = ens_chunk_from,
                .to_block = chunk_to,
                .addresses = &[_]Address{}, // Empty = no address filter (topic-only)
                .topic0_or = &ens_event_topics,
            }) catch |err| {
                // Halve chunk size and retry
                const new_size = retry_chunk_size / 2;
                std.log.info("    ENS chunk {d}-{d} too large ({any}), reducing to {d} blocks", .{ ens_chunk_from, chunk_to, err, new_size });
                retry_chunk_size = new_size;
                std.Thread.sleep(constants.Timing.rpc_batch_delay_ms * std.time.ns_per_ms);
                continue;
            };

            // Success - update current chunk size for next iteration
            ens_chunk_size = retry_chunk_size;
            break logs;
        } else {
            // All retries failed - skip this range and try to continue
            std.log.warn("    ENS events failed at block {d} even with min chunk, skipping ahead", .{ens_chunk_from});
            ens_chunk_from += ENS_MIN_CHUNK;
            ens_chunk_size = ENS_MIN_CHUNK * 2;
            continue;
        };

        defer {
            for (ens_logs) |*log| {
                var mutable_log = log.*;
                mutable_log.deinit(self.allocator);
            }
            self.allocator.free(ens_logs);
        }

        ens_total_fetched += ens_logs.len;

        for (ens_logs) |log| {
            if (log.topics.len == 0) continue;

            // Skip events from the main registry - those are already processed by indexPhase1V2Events.
            // Processing them here would cause duplicate handling and overwrite resolver data.
            if (log.address.eql(main_registry_addr)) {
                continue;
            }

            // Only process events from known subregistries (registered via SubregistryUpdate)
            // Topic-only queries can match non-ENS contracts with similar event signatures
            if (!known_subreg_set.contains(log.address.bytes)) {
                ens_auto_registered += 1;
                continue;
            }

            const event_sig = log.topics[0];

            // Find matching handler
            inline for (Indexer.SUBREGISTRY_ENS_EVENTS) |event_cfg| {
                if (event_sig.eql(event_cfg.event_hash)) {
                    try event_cfg.handler(self, protocol, log);
                    ens_processed += 1;
                    break;
                }
            }
        }

        // Move to next chunk
        ens_chunk_from += ens_chunk_size;

        // Gradually increase chunk size back toward max after success (conservative: +25%)
        if (ens_chunk_size < ENS_MAX_CHUNK) {
            const increase = @max(ens_chunk_size / 4, 500); // At least 500 blocks
            const new_size = @min(ens_chunk_size + increase, ENS_MAX_CHUNK);
            if (new_size > ens_chunk_size) {
                std.log.debug("    ENS: Increasing chunk size: {d} -> {d}", .{ ens_chunk_size, new_size });
                ens_chunk_size = new_size;
            }
        }

        // Rate limit between chunks
        if (ens_chunk_from <= to_block) {
            std.Thread.sleep(constants.Timing.rpc_batch_delay_ms * std.time.ns_per_ms);
        }
    }

    if (ens_total_fetched > 0) {
        std.log.info("    Fetched {d} events, processed {d}, skipped {d} (unknown contracts)", .{
            ens_total_fetched,
            ens_processed,
            ens_auto_registered,
        });
    }

    // ========================================================================
    // STEP 2: Topic-only query for TransferSingle - O(1) per subregistry
    // Filter by: 1) Token ID entropy (ENS uses hash-like IDs)
    //            2) Known subregistries HashSet
    // Uses JSON-RPC batching: batch multiple chunk queries into single HTTP request
    // ========================================================================
    const CHUNK_SIZE: u64 = 2000; // TransferSingle is very common, stay conservative
    const BATCH_SIZE: usize = 10; // Number of chunks per HTTP request
    std.log.debug("  Step 2: Topic-only query for TransferSingle (batched, {d} chunks x {d} blocks per request)", .{ BATCH_SIZE, CHUNK_SIZE });

    const transfer_topics = [_]Hash{Indexer.SUBREGISTRY_TRANSFER_EVENT.event_hash};
    var transfer_processed: usize = 0;
    var transfer_filtered_small_id: usize = 0;
    var transfer_filtered_unknown: usize = 0;
    var transfer_total_fetched: usize = 0;

    // Calculate total chunks needed
    const total_blocks = to_block - from_block + 1;
    const total_chunks = (total_blocks + CHUNK_SIZE - 1) / CHUNK_SIZE;

    var chunks_processed: usize = 0;
    var batch_start_chunk: usize = 0;

    while (batch_start_chunk < total_chunks) {
        // Build batch of chunk requests
        const batch_end_chunk = @min(batch_start_chunk + BATCH_SIZE, total_chunks);
        const batch_count = batch_end_chunk - batch_start_chunk;

        var batch_requests = try self.allocator.alloc(rpc.Client.MultiAddressLogsRequest, batch_count);
        defer self.allocator.free(batch_requests);

        for (0..batch_count) |i| {
            const chunk_idx = batch_start_chunk + i;
            const chunk_from_block = from_block + chunk_idx * CHUNK_SIZE;
            const chunk_to_block = @min(chunk_from_block + CHUNK_SIZE - 1, to_block);

            batch_requests[i] = .{
                .from_block = chunk_from_block,
                .to_block = chunk_to_block,
                .addresses = &[_]Address{}, // Empty = no address filter (topic-only)
                .topic0_or = &transfer_topics,
            };
        }

        // Make batched RPC call
        const batch_results = client.getLogsMultiAddressBatch(batch_requests) catch |err| {
            // If batch fails, fall back to individual requests
            std.log.warn("    Batch request failed ({any}), falling back to individual requests", .{err});

            for (batch_requests) |req| {
                const logs = client.getLogsMultiAddress(req) catch |e| {
                    std.log.warn("    Individual request {d}-{d} also failed: {any}", .{ req.from_block, req.to_block, e });
                    continue;
                };
                defer {
                    for (logs) |*log| {
                        log.deinit(self.allocator);
                    }
                    self.allocator.free(logs);
                }

                // Process logs from this chunk
                transfer_total_fetched += logs.len;
                for (logs) |log| {
                    // Hot-path filter: schema-driven decode would allocate per
                    // log just to read one uint256. Primitive shim path is
                    // still eth.zig-backed (eth.uint256.fromBigEndianBytes).
                    if (log.data.len >= 32) {
                        const token_id = abi.ABI.decodeUint256(log.data, 0) catch continue;
                        if (token_id < (1 << 64)) {
                            transfer_filtered_small_id += 1;
                            continue;
                        }
                    }
                    if (!known_subreg_set.contains(log.address.bytes)) {
                        transfer_filtered_unknown += 1;
                        continue;
                    }
                    Indexer.SUBREGISTRY_TRANSFER_EVENT.handler(self, protocol, log) catch |handler_err| {
                        std.log.warn("    Failed to process transfer: {}", .{handler_err});
                    };
                    transfer_processed += 1;
                }
                chunks_processed += 1;
            }
            batch_start_chunk = batch_end_chunk;
            continue;
        };
        defer utils.deinitBatchResults(self.allocator, batch_results);

        // Process results from batch
        const filter_start = std.time.milliTimestamp();
        var batch_filtered_small: usize = 0;
        var batch_filtered_unknown: usize = 0;
        var batch_processed: usize = 0;
        var batch_fetched: usize = 0;

        for (batch_results) |logs| {
            batch_fetched += logs.len;

            for (logs) |log| {
                // Quick filter 1: Check token ID entropy
                // Hot-path: primitive shim (eth.uint256.fromBigEndianBytes) on
                // purpose — schema-driven would allocate per log.
                if (log.data.len >= 32) {
                    const token_id = abi.ABI.decodeUint256(log.data, 0) catch continue;
                    if (token_id < (1 << 64)) {
                        transfer_filtered_small_id += 1;
                        batch_filtered_small += 1;
                        continue;
                    }
                }

                // Quick filter 2: Check if from known subregistry
                if (!known_subreg_set.contains(log.address.bytes)) {
                    transfer_filtered_unknown += 1;
                    batch_filtered_unknown += 1;
                    continue;
                }

                // Process the transfer event
                Indexer.SUBREGISTRY_TRANSFER_EVENT.handler(self, protocol, log) catch |err| {
                    std.log.warn("    Failed to process transfer: {}", .{err});
                };
                transfer_processed += 1;
                batch_processed += 1;
            }
        }
        const filter_elapsed = std.time.milliTimestamp() - filter_start;

        transfer_total_fetched += batch_fetched;
        chunks_processed += batch_count;

        if (batch_fetched > 1000) {
            std.log.debug("    Batch {d} chunks: {d} logs, filter={d}ms (small={d}, unknown={d}, processed={d})", .{
                batch_count,
                batch_fetched,
                filter_elapsed,
                batch_filtered_small,
                batch_filtered_unknown,
                batch_processed,
            });
        }

        batch_start_chunk = batch_end_chunk;

        // Rate limit between batches
        if (batch_start_chunk < total_chunks) {
            std.Thread.sleep(constants.Timing.rpc_batch_delay_ms * std.time.ns_per_ms);
        }
    }

    // Advance last_indexed_block for all subregistries we just backfilled.
    // first_seen_block here is ignored on conflict (the row already exists
    // from discovery, where it was populated with the actual created_block);
    // we pass to_block as a harmless placeholder to satisfy the signature.
    for (discovery.all) |subreg_hex| {
        try self.database.registerSubregistry(protocol, subreg_hex, to_block, to_block);
    }

    const total_processed = ens_processed + transfer_processed;
    if (total_processed > 0) {
        std.log.info("Subregistry indexing: {d} ENS events + {d} transfers from {d} subregistries", .{
            ens_processed,
            transfer_processed,
            subregistries.len,
        });
    }
}

pub fn indexTransferEvents(self: *Indexer, protocol: models.Protocol, client: *rpc.Client, from_block: u64, to_block: u64) !void {
    // We need to track transfers from all registries, but for now we'll focus on the .eth registry
    const eth_registry = self.getEthRegistry(protocol);

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
    defer utils.deinitBatchResults(self.allocator, batch_results);

    // Sort + dispatch in canonical protocol order. TransferSingle and TransferBatch on the same
    // tokenId in the same block must apply in emission order to produce correct ownership.
    const total_count = batch_results[0].len + batch_results[1].len + batch_results[2].len;

    var entries: std.ArrayList(utils.DispatchEntry) = .{};
    defer entries.deinit(self.allocator);
    try entries.ensureTotalCapacity(self.allocator, total_count);

    for (batch_results[0]) |log| entries.appendAssumeCapacity(.{ .handler = Indexer.handleTransfer, .log = log });
    for (batch_results[1]) |log| entries.appendAssumeCapacity(.{ .handler = Indexer.handleTransferBatch, .log = log });
    for (batch_results[2]) |log| entries.appendAssumeCapacity(.{ .handler = Indexer.handleApproval, .log = log });

    try utils.dispatchOrdered(self, protocol, entries.items);
}

/// Index V2 ETHReverseRegistrar events. Subscribes to ReverseClaimed on the V2
/// reverse registrar contract and dispatches the same handler as V1 (which is
/// protocol-agnostic — it writes to `reverse_records` with the protocol passed
/// in). Skipped when the contract isn't deployed on this network (zero address).
pub fn indexV2ReverseRegistrarEvents(self: *Indexer, protocol: models.Protocol, client: *rpc.Client, from_block: u64, to_block: u64) !void {
    if (protocol != .v2) return;
    const reverse_addr = self.config.v2_contracts.eth_reverse_registrar;
    if (reverse_addr.isZero()) return; // not deployed (mainnet today)

    // V2 reverses are low-volume — reuse the simple chunked V1 fetcher.
    const v1_indexing = @import("v1/indexing.zig");
    try v1_indexing.indexV1EventsChunked(
        self,
        protocol,
        client,
        from_block,
        to_block,
        reverse_addr,
        &Indexer.V2_REVERSE_REGISTRAR_EVENTS,
        "V2 Reverse Registrar",
    );
}

pub fn indexResolverEvents(self: *Indexer, protocol: models.Protocol, client: *rpc.Client, from_block: u64, to_block: u64) !void {
    const resolvers_mod = @import("../storage/resolvers.zig");

    // Discover new resolvers and get all known resolvers
    var discovery = try resolvers_mod.discoverAndGetResolvers(self.database, protocol, from_block, to_block);
    defer discovery.deinit(self.allocator);

    // Backfill historical events for newly discovered resolvers.
    // When a resolver is first set on a domain, it may have already emitted events
    // (e.g. EACRolesChanged during initialize()) that we missed. Fetch those now.
    if (discovery.newly_discovered.len > 0 and from_block > 0) {
        const backfill_from = self.config.start_block;
        std.log.info("Backfilling {d} newly discovered resolver(s) from block {d} to {d}", .{
            discovery.newly_discovered.len,
            backfill_from,
            from_block - 1,
        });
        for (discovery.newly_discovered) |resolver_str| {
            const addr = Address.fromHex(resolver_str) catch continue;
            backfillResolverEvents(self, protocol, client, addr, backfill_from, from_block - 1) catch |err| {
                std.log.warn("Failed to backfill resolver {s}: {}", .{ resolver_str, err });
            };
        }
    }

    if (discovery.all.len == 0) {
        std.log.debug("No known resolvers for blocks {d}-{d}", .{ from_block, to_block });
        return;
    }

    // Build HashSet of known resolver addresses for O(1) filtering.
    // Pre-size to skip incremental grow+rehash work.
    var known_resolver_set = std.AutoHashMap([20]u8, void).init(self.allocator);
    defer known_resolver_set.deinit();
    try known_resolver_set.ensureTotalCapacity(@intCast(discovery.all.len));

    for (discovery.all) |resolver_str| {
        const addr = Address.fromHex(resolver_str) catch continue;
        try known_resolver_set.put(addr.bytes, {});
    }

    std.log.debug("Indexing resolver events with topic-only query (1 RPC call, {d} known resolvers)", .{discovery.all.len});

    // Build event topic array for OR matching (all resolver event types)
    var event_topics: [Indexer.RESOLVER_EVENTS.len]Hash = undefined;
    inline for (Indexer.RESOLVER_EVENTS, 0..) |event_cfg, i| {
        event_topics[i] = event_cfg.event_hash;
    }

    // Single RPC call: query by topics only, no address filter
    // This returns events from ANY contract with matching signatures
    const logs = try client.getLogsMultiAddress(.{
        .from_block = from_block,
        .to_block = to_block,
        .addresses = &[_]Address{}, // Empty = no address filter
        .topic0_or = &event_topics,
    });
    defer {
        for (logs) |*log| {
            log.deinit(self.allocator);
        }
        self.allocator.free(logs);
    }

    // Process logs, filtering by known resolvers
    var processed_count: usize = 0;
    var skipped_count: usize = 0;

    for (logs) |log| {
        if (log.topics.len == 0) continue;

        // Filter: only process events from known resolvers
        if (!known_resolver_set.contains(log.address.bytes)) {
            skipped_count += 1;
            continue;
        }

        const event_sig = log.topics[0];
        const resolver = log.address;

        // Find matching handler by comparing event signature
        inline for (Indexer.RESOLVER_EVENTS) |event_cfg| {
            if (event_sig.eql(event_cfg.event_hash)) {
                try event_cfg.handler(self, protocol, resolver, log);
                processed_count += 1;
                break;
            }
        }
    }

    if (processed_count > 0) {
        std.log.info("Resolver indexing: {d} events processed, {d} skipped (unknown resolvers)", .{ processed_count, skipped_count });
    }
}

/// Backfill historical events for a specific resolver contract.
/// Called when a resolver is newly discovered — fetches events from its deployment
/// to catch initialization events (e.g. EACRolesChanged) that happened before
/// the resolver was set on any domain.
fn backfillResolverEvents(self: *Indexer, protocol: models.Protocol, client: *rpc.Client, resolver_addr: Address, from_block: u64, to_block: u64) !void {
    if (to_block < from_block) return;

    const resolver_hex = try resolver_addr.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);

    std.log.info("  Backfilling resolver {s} events from block {d} to {d}", .{ resolver_hex, from_block, to_block });

    // Build event topic array
    var event_topics: [Indexer.RESOLVER_EVENTS.len]Hash = undefined;
    inline for (Indexer.RESOLVER_EVENTS, 0..) |event_cfg, i| {
        event_topics[i] = event_cfg.event_hash;
    }

    // Query specifically for this resolver's address
    const logs = try client.getLogsMultiAddress(.{
        .from_block = from_block,
        .to_block = to_block,
        .addresses = &[_]Address{resolver_addr},
        .topic0_or = &event_topics,
    });
    defer {
        for (logs) |*log| {
            log.deinit(self.allocator);
        }
        self.allocator.free(logs);
    }

    if (logs.len == 0) {
        std.log.info("  No historical events found for resolver {s}", .{resolver_hex});
        return;
    }

    var processed: usize = 0;
    for (logs) |log| {
        if (log.topics.len == 0) continue;

        const event_sig = log.topics[0];
        inline for (Indexer.RESOLVER_EVENTS) |event_cfg| {
            if (event_sig.eql(event_cfg.event_hash)) {
                event_cfg.handler(self, protocol, resolver_addr, log) catch |err| {
                    std.log.warn("  Backfill handler error for resolver {s}: {}", .{ resolver_hex, err });
                };
                processed += 1;
                break;
            }
        }
    }

    std.log.info("  Backfilled {d} historical events for resolver {s}", .{ processed, resolver_hex });
}

/// Backfill historical events for a specific subregistry contract.
/// Called when a subregistry is newly discovered — fetches events from start_block
/// to catch initialization events (e.g. NameRegistered, EACRolesGranted) that happened
/// before the SubregistryUpdate event was processed.
fn backfillSubregistryEvents(self: *Indexer, protocol: models.Protocol, client: *rpc.Client, subreg_addr: Address, from_block: u64, to_block: u64) !void {
    if (to_block < from_block) return;

    const subreg_hex = try subreg_addr.toHex(self.allocator);
    defer self.allocator.free(subreg_hex);

    std.log.info("  Backfilling subregistry {s} events from block {d} to {d}", .{ subreg_hex, from_block, to_block });

    // Build ENS event topic array for OR matching
    var ens_event_topics: [Indexer.SUBREGISTRY_ENS_EVENTS.len]Hash = undefined;
    inline for (Indexer.SUBREGISTRY_ENS_EVENTS, 0..) |event_cfg, i| {
        ens_event_topics[i] = event_cfg.event_hash;
    }

    // Also include TransferSingle
    const all_topics_len = Indexer.SUBREGISTRY_ENS_EVENTS.len + 1;
    var all_topics: [all_topics_len]Hash = undefined;
    inline for (Indexer.SUBREGISTRY_ENS_EVENTS, 0..) |event_cfg, i| {
        all_topics[i] = event_cfg.event_hash;
    }
    all_topics[Indexer.SUBREGISTRY_ENS_EVENTS.len] = Indexer.SUBREGISTRY_TRANSFER_EVENT.event_hash;

    // Query specifically for this subregistry's address (no false positives)
    const logs = try client.getLogsMultiAddress(.{
        .from_block = from_block,
        .to_block = to_block,
        .addresses = &[_]Address{subreg_addr},
        .topic0_or = &all_topics,
    });
    defer {
        for (logs) |*log| {
            log.deinit(self.allocator);
        }
        self.allocator.free(logs);
    }

    if (logs.len == 0) {
        std.log.info("  No historical events found for subregistry {s}", .{subreg_hex});
        return;
    }

    var processed: usize = 0;
    for (logs) |log| {
        if (log.topics.len == 0) continue;

        const event_sig = log.topics[0];

        // Check ENS-specific events first
        inline for (Indexer.SUBREGISTRY_ENS_EVENTS) |event_cfg| {
            if (event_sig.eql(event_cfg.event_hash)) {
                event_cfg.handler(self, protocol, log) catch |err| {
                    std.log.warn("  Backfill handler error for subregistry {s}: {}", .{ subreg_hex, err });
                };
                processed += 1;
                break;
            }
        }

        // Check TransferSingle
        if (event_sig.eql(Indexer.SUBREGISTRY_TRANSFER_EVENT.event_hash)) {
            Indexer.SUBREGISTRY_TRANSFER_EVENT.handler(self, protocol, log) catch |err| {
                std.log.warn("  Backfill transfer error for subregistry {s}: {}", .{ subreg_hex, err });
            };
            processed += 1;
        }
    }

    std.log.info("  Backfilled {d} historical events for subregistry {s}", .{ processed, subreg_hex });
}

/// Combined Phase 1 fetch: EthRegistry + ETHRegistrar + Datastore events in a single batch RPC call.
/// This eliminates 2 HTTP round trips and ~100ms of inter-batch sleeps compared to 3 separate calls.
/// Processing order is preserved: EthRegistry → ETHRegistrar → Datastore (same as sequential).
pub fn indexPhase1V2Events(self: *Indexer, protocol: models.Protocol, client: *rpc.Client, from_block: u64, to_block: u64) !void {
    const eth_registry = self.getEthRegistry(protocol);

    // Pre-compute all topic arrays on the stack (pointers must remain valid until batch call returns)
    var reg_topics: [Indexer.ETH_REGISTRY_EVENTS.len][1]?Hash = undefined;
    inline for (Indexer.ETH_REGISTRY_EVENTS, 0..) |event_cfg, i| {
        reg_topics[i] = .{event_cfg.event_hash};
    }

    var registrar_topics: [Indexer.ETH_REGISTRAR_EVENTS.len][1]?Hash = undefined;
    inline for (Indexer.ETH_REGISTRAR_EVENTS, 0..) |event_cfg, i| {
        registrar_topics[i] = .{event_cfg.event_hash};
    }

    const ds_topics = [2][1]?Hash{
        .{abi.EventSignatures.subregistry_updated_hash},
        .{abi.EventSignatures.resolver_updated_hash},
    };

    const N_REG = Indexer.ETH_REGISTRY_EVENTS.len;
    const N_REGISTRAR = Indexer.ETH_REGISTRAR_EVENTS.len;
    const N_DS: usize = 2;

    if (protocol == .v2) {
        const eth_registrar = self.config.v2_contracts.eth_registrar_v2;
        const TOTAL = N_REG + N_REGISTRAR + N_DS;

        var batch: [TOTAL]rpc.Client.BatchGetLogsRequest = undefined;

        // EthRegistry events (indices 0..N_REG)
        inline for (Indexer.ETH_REGISTRY_EVENTS, 0..) |_, i| {
            batch[i] = .{
                .from_block = from_block,
                .to_block = to_block,
                .address = eth_registry,
                .topics = &reg_topics[i],
            };
        }

        // ETHRegistrar events (indices N_REG..N_REG+N_REGISTRAR)
        inline for (Indexer.ETH_REGISTRAR_EVENTS, 0..) |_, i| {
            batch[N_REG + i] = .{
                .from_block = from_block,
                .to_block = to_block,
                .address = eth_registrar,
                .topics = &registrar_topics[i],
            };
        }

        // Datastore events (indices N_REG+N_REGISTRAR..TOTAL)
        batch[N_REG + N_REGISTRAR + 0] = .{ .from_block = from_block, .to_block = to_block, .address = eth_registry, .topics = &ds_topics[0] };
        batch[N_REG + N_REGISTRAR + 1] = .{ .from_block = from_block, .to_block = to_block, .address = eth_registry, .topics = &ds_topics[1] };

        // Single HTTP call for all 11 requests
        const results = try client.getLogsBatch(&batch);
        defer utils.deinitBatchResults(self.allocator, results);

        // Per-topic "Found N events" logging (preserve existing operator visibility)
        var total_registry: usize = 0;
        inline for (Indexer.ETH_REGISTRY_EVENTS, 0..) |event_cfg, i| {
            const n = results[i].len;
            if (n > 0) {
                std.log.info("    Found {d} {s} event{s}", .{ n, event_cfg.name, if (n == 1) "" else "s" });
            }
            total_registry += n;
        }
        if (total_registry == 0) {
            std.log.debug("    No ETH Registry events in blocks {d}-{d}", .{ from_block, to_block });
        }

        var total_registrar: usize = 0;
        inline for (Indexer.ETH_REGISTRAR_EVENTS, 0..) |event_cfg, i| {
            const n = results[N_REG + i].len;
            if (n > 0) {
                std.log.info("    Found {d} {s} event{s}", .{ n, event_cfg.name, if (n == 1) "" else "s" });
            }
            total_registrar += n;
        }
        if (total_registrar == 0) {
            std.log.debug("    No ETH Registrar events in blocks {d}-{d}", .{ from_block, to_block });
        }

        // Collect all phase-1 events into a single list, sort by (block, log_index),
        // and dispatch in canonical protocol order. Same-block events from different types
        // (e.g. NameRegistered then NameBurned on the same name) must apply in emission
        // order to produce correct final state.
        var total_count: usize = total_registry + total_registrar;
        for (results[N_REG + N_REGISTRAR ..]) |logs| total_count += logs.len;

        var entries: std.ArrayList(utils.DispatchEntry) = .{};
        defer entries.deinit(self.allocator);
        try entries.ensureTotalCapacity(self.allocator, total_count);

        inline for (Indexer.ETH_REGISTRY_EVENTS, 0..) |event_cfg, i| {
            for (results[i]) |log| entries.appendAssumeCapacity(.{ .handler = event_cfg.handler, .log = log });
        }
        inline for (Indexer.ETH_REGISTRAR_EVENTS, 0..) |event_cfg, i| {
            for (results[N_REG + i]) |log| entries.appendAssumeCapacity(.{ .handler = event_cfg.handler, .log = log });
        }
        for (results[N_REG + N_REGISTRAR + 0]) |log| entries.appendAssumeCapacity(.{ .handler = Indexer.handleSubregistryUpdated, .log = log });
        for (results[N_REG + N_REGISTRAR + 1]) |log| entries.appendAssumeCapacity(.{ .handler = Indexer.handleResolverUpdated, .log = log });

        try utils.dispatchOrdered(self, protocol, entries.items);
    } else {
        // L1: No ETH Registrar
        const TOTAL = N_REG + N_DS;

        var batch: [TOTAL]rpc.Client.BatchGetLogsRequest = undefined;

        inline for (Indexer.ETH_REGISTRY_EVENTS, 0..) |_, i| {
            batch[i] = .{
                .from_block = from_block,
                .to_block = to_block,
                .address = eth_registry,
                .topics = &reg_topics[i],
            };
        }

        batch[N_REG + 0] = .{ .from_block = from_block, .to_block = to_block, .address = eth_registry, .topics = &ds_topics[0] };
        batch[N_REG + 1] = .{ .from_block = from_block, .to_block = to_block, .address = eth_registry, .topics = &ds_topics[1] };

        const results = try client.getLogsBatch(&batch);
        defer utils.deinitBatchResults(self.allocator, results);

        // Per-topic visibility logging
        var total_registry: usize = 0;
        inline for (Indexer.ETH_REGISTRY_EVENTS, 0..) |event_cfg, i| {
            const n = results[i].len;
            if (n > 0) {
                std.log.info("    Found {d} {s} event{s}", .{ n, event_cfg.name, if (n == 1) "" else "s" });
            }
            total_registry += n;
        }

        // Sort + dispatch in canonical protocol order (see V2 branch for rationale).
        var total_count: usize = total_registry;
        for (results[N_REG..]) |logs| total_count += logs.len;

        var entries: std.ArrayList(utils.DispatchEntry) = .{};
        defer entries.deinit(self.allocator);
        try entries.ensureTotalCapacity(self.allocator, total_count);

        inline for (Indexer.ETH_REGISTRY_EVENTS, 0..) |event_cfg, i| {
            for (results[i]) |log| entries.appendAssumeCapacity(.{ .handler = event_cfg.handler, .log = log });
        }
        for (results[N_REG + 0]) |log| entries.appendAssumeCapacity(.{ .handler = Indexer.handleSubregistryUpdated, .log = log });
        for (results[N_REG + 1]) |log| entries.appendAssumeCapacity(.{ .handler = Indexer.handleResolverUpdated, .log = log });

        try utils.dispatchOrdered(self, protocol, entries.items);
    }
}
