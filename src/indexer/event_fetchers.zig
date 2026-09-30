const std = @import("std");
const zsys = @import("../utils/system.zig");
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
const discovery_backfill = @import("discovery_backfill.zig");

pub fn indexSubregistryEvents(self: *Indexer, protocol: models.Protocol, client: *rpc.Client, from_block: u64, to_block: u64) !void {
    // Get the main registry address to exclude it
    const main_registry_addr = self.getEthRegistry(protocol);
    const main_registry_hex = try main_registry_addr.toHex(self.allocator);
    defer self.allocator.free(main_registry_hex);

    // Discover new subregistries and get all known ones (uses cache table for performance)
    var discovery = try self.database.discoverAndGetSubregistries(protocol, main_registry_hex, from_block, to_block);
    defer discovery.deinit(self.allocator);

    // Newly discovered subregistries owe a sweep from their deployment block:
    // a UserRegistry is deployed and initialize()d — granting roles — BEFORE
    // the parent is repointed at it, so `registries.created_block` (the first
    // SubregistryUpdated) sits above its own earliest events. Anchors and
    // sweeps are batched across the whole set (discovery_backfill.zig).
    if (discovery.newly_discovered.len > 0 and from_block > 0) {
        std.log.info("Backfilling {d} newly discovered subregistr{s} (up to block {d})", .{
            discovery.newly_discovered.len,
            if (discovery.newly_discovered.len == 1) "y" else "ies",
            from_block - 1,
        });
        backfillAddressStrings(self, protocol, client, .subregistry, discovery.newly_discovered, from_block - 1);
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

    // Process ENS events, skipping contracts that are not known subregistries.
    // NOTE: nothing is auto-registered here — an unknown address is DROPPED. The
    // counter was previously named `ens_auto_registered`, which made that silent
    // loss read like a recovery and hid a whole class of missing events.
    var ens_processed: usize = 0;
    var ens_skipped_unknown: usize = 0;
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
                self.rate_limiter.acquire();
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
                ens_skipped_unknown += 1;
                continue;
            }

            const event_sig = log.topics[0];

            // Find matching handler
            self.markEventBlock(protocol, log.block_number);
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
            self.rate_limiter.acquire();
        }
    }

    if (ens_total_fetched > 0) {
        std.log.info("    Fetched {d} events, processed {d}, skipped {d} (unknown contracts)", .{
            ens_total_fetched,
            ens_processed,
            ens_skipped_unknown,
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
                    self.markEventBlock(protocol, log.block_number);
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
        const filter_start = zsys.milliTimestamp();
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
                self.markEventBlock(protocol, log.block_number);
                Indexer.SUBREGISTRY_TRANSFER_EVENT.handler(self, protocol, log) catch |err| {
                    std.log.warn("    Failed to process transfer: {}", .{err});
                };
                transfer_processed += 1;
                batch_processed += 1;
            }
        }
        const filter_elapsed = zsys.milliTimestamp() - filter_start;

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
            self.rate_limiter.acquire();
        }
    }

    // Advance last_indexed_block for all subregistries we just backfilled.
    // first_seen_block here is ignored on conflict (the row already exists
    // from discovery, where it was populated with the actual created_block);
    // we pass to_block as a harmless placeholder to satisfy the signature.
    // One statement per 150, not one per subregistry: this ran 229 UPSERTs every batch on the
    // reference deployment (~6.2s/batch against Neon) to advance checkpoints that were mostly
    // already at the head.
    try self.database.registerSubregistriesBatch(protocol, discovery.all, to_block);

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

    var entries: std.ArrayList(utils.DispatchEntry) = .empty;
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

/// ETHRenewerV1: a standalone renewer that emits the same eth-registrar
/// `NameRenewed(...)` as `eth_registrar_v2`. Renewals can originate from either
/// contract, so this fetch covers the second source. Skipped when not deployed.
pub fn indexV2RenewerEvents(self: *Indexer, protocol: models.Protocol, client: *rpc.Client, from_block: u64, to_block: u64) !void {
    if (protocol != .v2) return;
    const renewer_addr = self.config.v2_contracts.eth_renewer_v1;
    if (renewer_addr.isZero()) return;

    const v1_indexing = @import("v1/indexing.zig");
    try v1_indexing.indexV1EventsChunked(
        self,
        protocol,
        client,
        from_block,
        to_block,
        renewer_addr,
        &Indexer.V2_ETH_RENEWER_EVENTS,
        "V2 ETH Renewer",
    );
}

/// LabelStore: an on-chain labelhash->preimage dictionary. Its `Label` events heal
/// unknown labels. Skipped when not deployed.
pub fn indexLabelStoreEvents(self: *Indexer, protocol: models.Protocol, client: *rpc.Client, from_block: u64, to_block: u64) !void {
    if (protocol != .v2) return;
    // Only V1 produces unknown_labels, so LabelStore heals nothing in a V2-only process.
    // Gate it to processes that also index V1 (combined binary) to avoid wasted RPC.
    if (!self.indexes_v1) return;
    const label_store_addr = self.config.v2_contracts.eth_label_store;
    if (label_store_addr.isZero()) return;

    const v1_indexing = @import("v1/indexing.zig");
    try v1_indexing.indexV1EventsChunked(
        self,
        protocol,
        client,
        from_block,
        to_block,
        label_store_addr,
        &Indexer.V2_LABEL_STORE_EVENTS,
        "V2 LabelStore",
    );
}

fn processResolverChunk(
    self: *Indexer,
    protocol: models.Protocol,
    logs: []rpc.Log,
    known_resolver_set: *const std.AutoHashMap([20]u8, void),
    processed_count: *usize,
    skipped_count: *usize,
    type_ns: *[Indexer.RESOLVER_EVENTS.len]i128,
    type_count: *[Indexer.RESOLVER_EVENTS.len]usize,
) !void {
    for (logs) |log| {
        if (log.topics.len == 0) continue;

        // Filter: only process events from known resolvers
        if (!known_resolver_set.contains(log.address.bytes)) {
            skipped_count.* += 1;
            continue;
        }

        const event_sig = log.topics[0];
        const resolver = log.address;

        // Find matching handler by comparing event signature
        self.markEventBlock(protocol, log.block_number);
        inline for (Indexer.RESOLVER_EVENTS, 0..) |event_cfg, i| {
            if (event_sig.eql(event_cfg.event_hash)) {
                const handler_t = zsys.nanoTimestamp();
                event_cfg.handler(self, protocol, resolver, log) catch |err| {
                    if (!utils.isMalformedEventError(err)) return err;
                    utils.skipMalformedEvent(log, err);
                };
                type_ns[i] += zsys.nanoTimestamp() - handler_t;
                type_count[i] += 1;
                processed_count.* += 1;
                break;
            }
        }
    }
}

pub fn indexResolverEvents(self: *Indexer, protocol: models.Protocol, client: *rpc.Client, from_block: u64, to_block: u64) !void {
    const resolvers_mod = @import("../storage/resolvers.zig");
    const pass_timer = zsys.milliTimestamp();

    // Resolvers first sighted this batch (queued by handleResolverUpdated's
    // registerResolverOnceIfNew) and resolvers surfaced by discovery both owe
    // a sweep of their pre-attachment history: initialize()-time
    // EACRolesChanged grants fire blocks before the resolver becomes known,
    // so the pass below can never see them. Events within [from_block,
    // to_block] are the pass's job, hence the window ends at from_block - 1.
    // Anchors and sweeps are batched across the whole set.
    var owed: std.ArrayList(Address) = .empty;
    defer owed.deinit(self.allocator);
    if (from_block > self.config.start_block) {
        try owed.appendSlice(self.allocator, self.pending_resolver_backfills.items);
    }
    self.pending_resolver_backfills.clearRetainingCapacity();

    // Discover new resolvers and get all known resolvers
    var discovery = try resolvers_mod.discoverAndGetResolvers(self.database, protocol, from_block, to_block);
    defer discovery.deinit(self.allocator);
    const discover_ms = zsys.milliTimestamp() - pass_timer;

    if (from_block > 0) {
        for (discovery.newly_discovered) |resolver_str| {
            const addr = Address.fromHex(resolver_str) catch continue;
            try owed.append(self.allocator, addr);
        }
    }
    if (owed.items.len > 0) {
        std.log.info("Backfilling {d} resolver(s) first sighted this batch (up to block {d})", .{ owed.items.len, from_block - 1 });
        _ = discovery_backfill.backfillDiscovered(self, protocol, client, .resolver, owed.items, from_block - 1, null, null);
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

    // Topic-only query, no address filter: returns events from ANY contract with
    // matching signatures; known-resolver filtering happens client-side below.
    // Chunked with overflow halving — one unchunked call over a large outer batch
    // exceeds provider response caps and, being the LAST phase, used to abort the
    // whole already-processed batch.
    var processed_count: usize = 0;
    var skipped_count: usize = 0;
    var fetch_ms: i64 = 0;
    var process_ms: i64 = 0;
    var fetch_count: usize = 0;
    var type_ns: [Indexer.RESOLVER_EVENTS.len]i128 = @splat(0);
    var type_count: [Indexer.RESOLVER_EVENTS.len]usize = @splat(0);
    var chunk_lo = from_block;
    var resolver_chunk: u64 = @max(1, @min(self.config.batch_size, 5000));
    while (chunk_lo <= to_block) {
        const chunk_hi = @min(to_block, chunk_lo + resolver_chunk - 1);
        const fetch_t = zsys.milliTimestamp();
        const logs = client.getLogsMultiAddress(.{
            .from_block = chunk_lo,
            .to_block = chunk_hi,
            .addresses = &[_]Address{}, // Empty = no address filter
            .topic0_or = &event_topics,
        }) catch |err| {
            fetch_ms += zsys.milliTimestamp() - fetch_t;
            // OutOfMemory belongs here with the size errors: a chunk that will
            // not fit in memory is a chunk that is too large, and halving is
            // the same recovery. Without it an allocation failure propagated
            // out of the last phase and abandoned the whole already-processed
            // batch, which is how a memory problem became a permanent sync
            // stall rather than a slower pass. Bounded — the floor of 10 ends
            // the retreat and returns the error.
            if ((err == error.RpcError or err == error.RpcRateLimited or err == error.StreamTooLong or err == error.OutOfMemory) and resolver_chunk > 10) {
                resolver_chunk = @max(10, resolver_chunk / 2);
                std.log.warn("  Resolver-events chunk too large, retrying {d}-{d} at {d} blocks", .{ chunk_lo, chunk_hi, resolver_chunk });
                continue;
            }
            return err;
        };
        fetch_ms += zsys.milliTimestamp() - fetch_t;
        fetch_count += 1;
        defer {
            for (logs) |*log| {
                log.deinit(self.allocator);
            }
            self.allocator.free(logs);
        }

        self.warmBlockTimestampCache(protocol, &.{logs});

        const process_t = zsys.milliTimestamp();
        try processResolverChunk(self, protocol, logs, &known_resolver_set, &processed_count, &skipped_count, &type_ns, &type_count);
        process_ms += zsys.milliTimestamp() - process_t;
        chunk_lo = chunk_hi + 1;
        if (chunk_lo <= to_block) self.rate_limiter.acquire();
    }
    if (processed_count > 0) {
        if (process_ms > 5000) {
            inline for (Indexer.RESOLVER_EVENTS, 0..) |event_cfg, i| {
                if (type_count[i] > 0) {
                    std.log.info("    resolver breakdown: {s} {d} events in {d}ms", .{ event_cfg.name, type_count[i], @as(i64, @intCast(@divTrunc(type_ns[i], std.time.ns_per_ms))) });
                }
            }
        }
        std.log.info("Resolver indexing: {d} events processed, {d} skipped (unknown resolvers) in {d}ms (discover={d}ms fetch={d}ms/{d} calls process={d}ms)", .{ processed_count, skipped_count, zsys.milliTimestamp() - pass_timer, discover_ms, fetch_ms, fetch_count, process_ms });
    }
}

// ============================================================================
// INIT-GAP HEALS (durable per-target ledger)
// ============================================================================
// Resolver and subregistry contracts emit their initialization events
// (EACRolesChanged role grants during factory initialize()) BEFORE the
// on-chain pointer that makes them known to the indexer, so the normal batch
// scan can never see those events. Discovery-time backfills close the gap for
// new sightings; the ledger (`init_gap_heal_targets`, storage/heal_targets.zig)
// makes every owed sweep durable, so a failed backfill is retried with attempt
// caps and spacing instead of being dropped with a warning. The previous
// task-level `backfill_status` markers were written `completed` even when every
// per-target sweep had failed, converting one RPC outage into a permanent
// silent data gap; the ledger deliberately ignores them (their word is not
// trustworthy), at the cost of one idempotent re-sweep per pre-ledger target.

const RESOLVER_HEAL_TASK = discovery_backfill.RESOLVER_HEAL_TASK;
const SUBREGISTRY_HEAL_TASK = discovery_backfill.SUBREGISTRY_HEAL_TASK;
/// After this many spaced failures a target parks at err level: a persistent
/// per-target problem needs an operator, not an infinite retry loop.
const HEAL_MAX_ATTEMPTS = discovery_backfill.HEAL_MAX_ATTEMPTS;
/// Minimum seconds between attempts on one target, so a multi-hour RPC outage
/// cannot burn the whole attempt budget in a few poll cycles.
const HEAL_RETRY_SPACING_SECS: i64 = 600;
/// Per-poll-cycle heal budget. The drain runs inside the sync loop, so whatever
/// it spends is time the indexer is NOT following the chain head: an unbounded
/// pass once blocked head-following for 54 minutes after a single 1-block reorg
/// re-armed the whole ledger. Two bounds, because the pass has two cost drivers:
/// anchor bisection scales with the number of targets, sweeping with blocks and
/// events. Neither bound risks correctness — an unswept target simply stays owed
/// in the ledger, which is already how a failed sweep is resumed.
const HEAL_TARGETS_PER_CYCLE: usize = 200;
const HEAL_BUDGET_MS: i64 = 20_000;

/// Seed the ledger with every already-known resolver and subregistry. Runs at
/// initial-sync completion; enqueue is INSERT OR IGNORE, so completed targets
/// stay completed and re-seeding on every restart is free.
pub fn seedInitGapHealTargets(self: *Indexer, protocol: models.Protocol) !void {
    if (protocol != .v2) return;
    const db_mod = @import("../storage/database.zig");
    inline for (.{
        .{ RESOLVER_HEAL_TASK, "SELECT address FROM known_resolvers WHERE protocol = ?" },
        .{ SUBREGISTRY_HEAL_TASK, "SELECT address FROM known_subregistries WHERE protocol = ?" },
    }) |entry| {
        var q = try db_mod.Query.init(self.database, entry[1]);
        defer q.deinit();
        try q.bindTextStatic(protocol.toString());
        while (try q.step()) {
            const addr_slice = q.getTextSlice(0) orelse continue;
            self.database.enqueueHealTarget(entry[0], protocol, addr_slice) catch |err| {
                std.log.warn("init-gap heal: failed to enqueue {s} target {s}: {}", .{ entry[0], addr_slice, err });
            };
        }
    }
}

pub fn hasDueInitGapHeals(self: *Indexer, protocol: models.Protocol) bool {
    if (protocol != .v2) return false;
    const retry_before = zsys.timestamp() - HEAL_RETRY_SPACING_SECS;
    return self.database.hasPendingHealTargets(protocol, HEAL_MAX_ATTEMPTS, retry_before) catch false;
}

pub fn drainInitGapHeals(self: *Indexer, protocol: models.Protocol, client: *rpc.Client) void {
    if (protocol != .v2) return;
    const retry_before = zsys.timestamp() - HEAL_RETRY_SPACING_SECS;
    // One deadline shared by both tasks, so a cycle's total heal cost is bounded
    // rather than doubled. Whatever the resolver pass leaves is what the
    // subregistry pass gets; on the next cycle the order is the same but the
    // completed targets are gone, so both drain over successive cycles.
    const deadline = zsys.milliTimestamp() + HEAL_BUDGET_MS;
    drainHealTask(self, .resolver, protocol, client, retry_before, deadline);
    drainHealTask(self, .subregistry, protocol, client, retry_before, deadline);
}

fn drainHealTask(self: *Indexer, kind: discovery_backfill.Kind, protocol: models.Protocol, client: *rpc.Client, retry_before: i64, deadline_ms: i64) void {
    const task = switch (kind) {
        .resolver => RESOLVER_HEAL_TASK,
        .subregistry => SUBREGISTRY_HEAL_TASK,
    };
    var targets = self.database.pendingHealTargets(self.allocator, task, protocol, HEAL_MAX_ATTEMPTS, retry_before, HEAL_TARGETS_PER_CYCLE) catch |err| {
        std.log.warn("init-gap heal: failed to list {s} targets: {}", .{ task, err });
        return;
    };
    defer targets.deinit(self.allocator);
    if (targets.items.len == 0) return;

    // Split the rows into the two parallel slices backfillDiscovered wants. The
    // ceiling is each contract's first-seen block: the sweep owes only the
    // events emitted before the indexer knew the contract existed. Sweeping to
    // the head instead re-scanned ~9x more blocks and re-dispatched tens of
    // thousands of already-stored events on every pass.
    var addrs: std.ArrayList(Address) = .empty;
    defer addrs.deinit(self.allocator);
    var ceils: std.ArrayList(u64) = .empty;
    defer ceils.deinit(self.allocator);
    for (targets.items) |t| {
        addrs.append(self.allocator, t.addr) catch break;
        // first_seen_block is the first block the ordinary path covered, so the
        // gap ends one block earlier. 0 means unknown and stays 0, which
        // backfillDiscovered reads as "fall back to the head".
        ceils.append(self.allocator, if (t.first_seen_block > 0) t.first_seen_block - 1 else 0) catch break;
    }
    if (addrs.items.len != targets.items.len or ceils.items.len != targets.items.len) {
        std.log.warn("init-gap heal: out of memory listing {s} targets; leaving all {d} owed", .{ task, targets.items.len });
        return;
    }

    const to_block = (self.database.getSyncState(protocol) catch null) orelse 0;
    std.log.info("init-gap heal: {d} pending {s} target(s), sweeping up to block {d}", .{ targets.items.len, task, to_block });
    const outcome = discovery_backfill.backfillDiscovered(self, protocol, client, kind, addrs.items, to_block, ceils.items, deadline_ms);
    std.log.info("init-gap heal: {s} pass complete, {d}/{d} swept", .{ task, outcome.swept + outcome.no_history, targets.items.len });
}

fn backfillAddressStrings(self: *Indexer, protocol: models.Protocol, client: *rpc.Client, kind: discovery_backfill.Kind, hexes: []const []const u8, to_block: u64) void {
    var addrs: std.ArrayList(Address) = .empty;
    defer addrs.deinit(self.allocator);
    for (hexes) |hex| {
        const addr = Address.fromHex(hex) catch continue;
        addrs.append(self.allocator, addr) catch continue;
    }
    _ = discovery_backfill.backfillDiscovered(self, protocol, client, kind, addrs.items, to_block, null, null);
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

        // Single HTTP call for all requests
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

        var entries: std.ArrayList(utils.DispatchEntry) = .empty;
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

        var entries: std.ArrayList(utils.DispatchEntry) = .empty;
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
