//! Sync driver and run loop for the Indexer.
//!
//! The chain-sync core: the run-loop entrypoints (start/stop/startSingleProtocol)
//! plus the per-protocol drive, block-range processing, and reorg detection/rollback
//! (indexProtocol/indexBlockRange/verifyStoredBlockHash/rollbackToLastValidBlock).
//! Split out of indexer.zig using the move-body+alias-stub pattern: bodies live here
//! as `pub fn f(self: *Indexer, ...)` (the four formerly-private helpers are widened
//! to pub — nothing outside indexer.zig referenced them), and indexer.zig re-exports
//! each as `pub const f = sync_driver.f;`. Every collaborator these call is reached
//! through `self` and resolves via the Indexer struct's alias/pub decls.

const std = @import("std");
const zsys = @import("../utils/system.zig");
const shutdown = @import("../utils/shutdown.zig");
const config = @import("../config.zig");
const constants = @import("../constants.zig");
const db = @import("../storage/database.zig");
const rpc = @import("../rpc/client.zig");
const models = @import("../types/models.zig");
const Hash = @import("../types/hash.zig").Hash;
const Address = @import("../types/address.zig").Address;
const webhooks = @import("../webhooks/manager.zig");
const NetworkHealth = @import("../utils/network_health.zig").NetworkHealth;
const status_mod = @import("../server/status.zig");
const IndexerStatus = status_mod.IndexerStatus;
const reorg_undo = @import("../storage/reorg_undo.zig");
const ens_normalize = @import("../utils/ens_normalize.zig");
const replay_mod = @import("replay.zig");
const backfill_mod = @import("v1/backfill.zig");
const WriteBuffer = @import("write_buffer.zig").WriteBuffer;
const Rainbow = @import("../rainbow/rainbow.zig").Rainbow;
const Indexer = @import("indexer.zig").Indexer;

/// Near the tip, block lineage is stored per-block (not just at batch boundaries) so a
/// reorg's fork point is located exactly. A batch larger than this is stored at the
/// boundary only, bounding per-batch header RPC during catch-up (those far-from-tip
/// blocks finalize long before the tip reaches them).
const PER_BLOCK_LINEAGE_MAX: u64 = 128;

const BlockLineage = struct { number: u64, hash: Hash, parent_hash: Hash };

/// Classify and absorb a sync-iteration error so the run loop never dies on a
/// transient failure: network errors wait for connectivity to return (the RPC
/// being down for hours must stall indexing, not kill it); anything else gets a
/// bounded pause. The cursor is unchanged, so the next iteration resumes where
/// this one failed.
fn handleSyncError(self: *Indexer, protocol: models.Protocol, err: anyerror) void {
    switch (err) {
        error.HttpError, error.NetworkUnreachable, error.ConnectionRefused, error.ConnectionTimedOut, error.ConnectionResetByPeer, error.WriteFailed, error.BrokenPipe, error.EndOfStream, error.UnexpectedReadFailure => {
            std.log.warn("{s} network error detected: {}, waiting for connection...", .{ protocol.toString(), err });
            self.v1_network_health.waitForHealthy();
            std.log.info("{s} network restored, continuing...", .{protocol.toString()});
            // 1s breather before retry. Bounds log volume during a sustained
            // outage and prevents the tight spin we'd otherwise hit when
            // `waitForHealthy` (which uses a fresh http.Client) reports healthy
            // while the indexer's pooled client is still failing.
            _ = shutdown.sleepInterruptible(std.time.ns_per_s);
        },
        else => {
            std.log.err("{s} indexing error: {}", .{ protocol.toString(), err });
            _ = shutdown.sleepInterruptible(constants.Timing.error_recovery_delay_ms * std.time.ns_per_ms);
        },
    }
}

pub fn start(self: *Indexer) !void {
    std.log.info("Indexer starting...", .{});

    self.seedV2Registries() catch |err| {
        std.log.warn("Failed to seed V2 registries (non-fatal): {}", .{err});
    };

    // Drop non-essential indexes for faster bulk inserts during initial sync
    if (!self.initial_sync_complete.load(.acquire)) {
        self.database.dropSyncIndexes() catch |err| {
            std.log.warn("Failed to drop sync indexes (non-fatal): {}", .{err});
        };
    }

    while (!self.should_stop.load(.acquire) and !shutdown.isRequested()) {
        // Index V1 first (SQLite doesn't support concurrent writes from different threads)
        self.indexProtocol(.v1, self.v1_client) catch |err| {
            handleSyncError(self, .v1, err);
            continue;
        };

        // Then index V2
        self.indexProtocol(.v2, self.v1_client) catch |err| {
            handleSyncError(self, .v2, err);
            continue;
        };

        // After first successful sync of both chains, recreate indexes and start webhook workers
        if (!self.initial_sync_complete.load(.acquire)) {
            self.database.createSyncIndexes() catch |err| {
                std.log.err("Failed to recreate sync indexes: {}", .{err});
            };

            self.initial_sync_complete.store(true, .release);

            // PCC fuse → Domain.expiry mirror (V1 NameWrapper). The per-event
            // mirror in handleV1NameWrapped/FusesSet/ExpiryExtended needs to
            // read existing wrapper state, which the write_buffer can't
            // service during bulk sync. Run a one-shot bulk UPDATE now that
            // the buffer is flushed and indexes are restored (cursor disarmed
            // so it doesn't self-capture into the reorg undo-log).
            self.materializePccUncaptured();
            self.reconcileReachabilityUncaptured();

            // One-shot V1 heals, mirroring the single-protocol loop so the
            // combined and split binaries produce the same database. The reorg
            // cursor is disarmed here (materializePccUncaptured cleared it), so
            // these do NOT self-capture into the undo-log; keep any new backfill
            // inside this disarmed block. All three no-op without V1 data.
            std.log.info("Running pre-migration names backfill...", .{});
            self.backfillPreMigrationNames() catch |err| {
                std.log.err("Failed to backfill pre-migration names: {}", .{err});
            };
            std.log.info("Running unknown labels backfill...", .{});
            self.backfillUnknownLabels() catch |err| {
                std.log.err("Failed to backfill unknown labels: {}", .{err});
            };
            std.log.info("Running missing .eth 2LD names backfill...", .{});
            self.backfillMissingEth2LDNames() catch |err| {
                std.log.err("Failed to backfill missing .eth 2LD names: {}", .{err});
            };

            if (self.webhook_manager) |wm| {
                std.log.info("Initial sync complete - starting 8 webhook workers", .{});
                wm.startWorkers(8) catch |err| std.log.err("webhook workers failed to start: {}", .{err});
            }
        }

        // Best-effort finality signalling (Task 09); no-op unless FINALITY_ENABLED.
        fetchFinality(self);

        // A configured end block is a hard stop, not just a per-iteration cap —
        // without this the loop keeps polling toward the live head past the
        // requested range.
        if (self.end_block) |eb| {
            const v1_done = ((self.database.getSyncState(.v1) catch null) orelse 0) >= eb or
                self.v1EraStart() > eb;
            const v2_done = ((self.database.getSyncState(.v2) catch null) orelse 0) >= eb or
                self.config.v2_contracts.v2_deployment_block > eb;
            if (v1_done and v2_done) {
                std.log.info("Reached end block {d} for both protocols; stopping", .{eb});
                break;
            }
        }

        // Sleep for poll interval before next iteration; wakes early on SIGTERM.
        _ = shutdown.sleepInterruptible(self.config.poll_interval * std.time.ns_per_s);
    }

    std.log.info("Indexer stopped.", .{});
}

/// Best-effort finality fetch (Task 09): when FINALITY_ENABLED, read the chain's `safe`
/// and `finalized` block tags and persist them. Never throws — a provider that lacks the
/// tags (getBlockByTag → null) or a persist failure is skipped, so indexing is unaffected.
fn fetchFinality(self: *Indexer) void {
    if (!self.config.finality_enabled) return;
    const chain_id = self.database.chain_id;
    const now = zsys.timestamp();
    const safe = self.v1_client.getBlockByTag("safe");
    const finalized = self.v1_client.getBlockByTag("finalized");
    if (safe) |s| {
        self.database.setFinality(chain_id, .safe, s.number, s.hash, now) catch |err| std.log.debug("finality safe persist: {}", .{err});
    }
    if (finalized) |f| {
        // Chain invariant finalized <= safe; a provider anomaly is logged and skipped.
        if (safe) |s| {
            if (f.number > s.number) {
                std.log.warn("finality anomaly: finalized {d} > safe {d}; ignoring finalized", .{ f.number, s.number });
                return;
            }
        }
        self.database.setFinality(chain_id, .finalized, f.number, f.hash, now) catch |err| std.log.debug("finality finalized persist: {}", .{err});
    }
}

pub fn stop(self: *Indexer) void {
    self.should_stop.store(true, .release);
}

/// Start indexing a single protocol (for separate process architecture)
pub fn startSingleProtocol(self: *Indexer, protocol: models.Protocol) !void {
    std.log.info("Single-protocol indexer starting for {s}...", .{protocol.toString()});

    if (protocol == .v2) {
        self.seedV2Registries() catch |err| {
            std.log.warn("Failed to seed V2 registries (non-fatal): {}", .{err});
        };
    }

    const client = self.getClient(protocol);

    // Drop non-essential indexes for faster bulk inserts during initial sync
    if (!self.initial_sync_complete.load(.acquire)) {
        self.database.dropSyncIndexes() catch |err| {
            std.log.warn("Failed to drop sync indexes (non-fatal): {}", .{err});
        };
    }

    while (!self.should_stop.load(.acquire) and !shutdown.isRequested()) {
        if (self.indexProtocol(protocol, client)) |_| {
            // Success - after first successful sync, recreate indexes and start webhook workers
            if (!self.initial_sync_complete.load(.acquire)) {
                // Recreate all indexes before marking sync complete
                self.database.createSyncIndexes() catch |err| {
                    std.log.err("Failed to recreate sync indexes: {}", .{err});
                };

                self.initial_sync_complete.store(true, .release);

                // PCC fuse → Domain.expiry mirror (V1 NameWrapper, runs only
                // on V1 protocol since V2 doesn't have NameWrapper). The
                // per-event mirror in handleV1NameWrapped/FusesSet/
                // ExpiryExtended needs to read existing wrapper state, which
                // the write_buffer can't service during bulk sync. Run a
                // one-shot bulk UPDATE now that the buffer is flushed.
                if (protocol == .v1) {
                    self.materializePccUncaptured();
                }
                if (protocol == .v2) {
                    self.reconcileReachabilityUncaptured();
                }

                if (self.webhook_manager) |wm| {
                    std.log.info("Initial sync complete - starting webhook workers", .{});
                    wm.startWorkers(1) catch |err| std.log.err("webhook workers failed to start: {}", .{err});
                }

                // Backfill pre-migration names after initial sync completes.
                // INVARIANT: the reorg cursor is disarmed here — materializePccUncaptured
                // above cleared it and nothing re-arms it until the next indexProtocol —
                // so these one-shot backfills (which UPDATE/DELETE protected & reorg_active
                // tables, incl. unknown_labels) do NOT self-capture into the undo-log, per the
                // backfill-doesn't-capture rule. Keep any new backfill inside this disarmed block.
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
            handleSyncError(self, protocol, err);
            continue;
        }

        // Best-effort finality signalling (Task 09); no-op unless FINALITY_ENABLED.
        // Wired here too so the single-protocol binaries (ensv2-indexer-v1/-v2) persist
        // finality just like the combined indexer's `start` loop.
        fetchFinality(self);

        // A configured end block is a hard stop, matching the combined loop. A
        // protocol whose deployment lies beyond the end block can never reach
        // it — stop instead of polling forever.
        if (self.end_block) |eb| {
            const deployed_at = switch (protocol) {
                .v1 => self.v1EraStart(),
                .v2 => self.config.v2_contracts.v2_deployment_block,
            };
            if (((self.database.getSyncState(protocol) catch null) orelse 0) >= eb or deployed_at > eb) {
                std.log.info("Reached end block {d} for {s}; stopping", .{ eb, protocol.toString() });
                break;
            }
        }

        // Sleep for poll interval before next iteration; wakes early on SIGTERM.
        _ = shutdown.sleepInterruptible(self.config.poll_interval * std.time.ns_per_s);
    }

    std.log.info("{s} indexer stopped.", .{protocol.toString()});
}

/// True if the stored hash for `block_number` still matches the protocol, or no hash is stored.
/// On RPC failure, returns true (skip the reorg check this round) rather than aborting the
/// whole sync — reorgs are rare, transient network errors are not, and the next iteration
/// will catch a real reorg.
pub fn verifyStoredBlockHash(self: *Indexer, protocol: models.Protocol, client: *rpc.Client, block_number: u64) !bool {
    const stored = try self.database.getBlockHash(protocol, block_number) orelse return true;
    const actual = client.getBlockByNumber(block_number, false) catch |err| {
        std.log.warn("Skipping reorg check for block {d} ({}): assuming hash unchanged this round", .{ block_number, err });
        return true;
    };
    return std.mem.eql(u8, &stored.bytes, &actual.hash.bytes);
}

/// Walk back from `from_block` to the most recent stored checkpoint whose hash still
/// matches the canonical chain, then roll the database back to it. Returns the block
/// number rolled back to, or `error.ReorgTooDeep` when no matching checkpoint exists
/// within the retained window.
///
/// Two properties keep this fail-closed: (1) a height with no stored hash is skipped
/// rather than treated as a safe stopping point (hashes are dense near the tip, sparse
/// during catch-up), so stopping early would leave orphaned-branch state below it; (2) an RPC
/// error while confirming a checkpoint is propagated, so the round aborts and retries
/// rather than committing a rollback to an unverified height.
pub fn rollbackToLastValidBlock(self: *Indexer, protocol: models.Protocol, client: *rpc.Client, from_block: u64) !u64 {
    // Bound the walk to the hash-retention window; beyond it there are no stored hashes to
    // validate against, so a deeper rollback would be a blind guess (rollbackToBlock guards
    // the same depth). Matches cleanupOldBlockHashes / REORG_ARM_WINDOW.
    const RETENTION_BLOCKS: u64 = 1000;
    const floor = @max(self.config.start_block, from_block -| RETENTION_BLOCKS);

    var rollback_to = from_block;
    var matched = false;
    while (rollback_to > floor) : (rollback_to -= 1) {
        const stored = try self.database.getBlockHash(protocol, rollback_to);
        if (stored == null) continue; // not a stored checkpoint — keep descending
        const actual = try client.getBlockByNumber(rollback_to, false); // propagate RPC errors
        if (std.mem.eql(u8, &stored.?.bytes, &actual.hash.bytes)) {
            matched = true;
            break;
        }
    }
    if (!matched) {
        std.log.err("Reorg on {s} from block {d} has no matching checkpoint within {d}-block retention; refusing blind rollback", .{ protocol.toString(), from_block, RETENTION_BLOCKS });
        return error.ReorgTooDeep;
    }

    std.log.warn("Rolling back {s} to block {d}", .{ protocol.toString(), rollback_to });
    try self.database.rollbackToBlock(protocol, rollback_to);
    // rollbackToBlock cleared the reorg_cursor row; drop the in-memory mirror so the
    // next event re-arms it (otherwise capture stays silently disabled for that block).
    self.invalidateReorgCursor();
    return rollback_to;
}

/// First block of the V1 era on this network: the temporary-registrar start
/// where pre-permanent-registrar history exists (mainnet), else the V1
/// deployment block. Everything reasoning about "where does V1 begin" must use
/// this, not v1_deployment_block, or the 2017-2019 era is silently skipped.
pub fn v1EraStart(self: *Indexer) u64 {
    const temp = self.config.v1_contracts.temp_registrar_start_block;
    return if (temp > 0) temp else self.config.v1_contracts.v1_deployment_block;
}

pub fn indexProtocol(self: *Indexer, protocol: models.Protocol, client: *rpc.Client) !void {
    // Fresh databases start at the protocol's era start (for V1 that includes
    // the pre-permanent-registrar history on networks that have it).
    const deployment_block = switch (protocol) {
        .v1 => self.v1EraStart(),
        .v2 => self.config.v2_contracts.v2_deployment_block,
    };

    // A protocol that is not deployed on this network has nothing to index.
    // Without this guard the combined binary walks the entire chain for the
    // inert protocol, paying reorg-check and lineage RPCs per empty batch.
    if (deployment_block == 0) return;

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

    // Defensively clear the undo-capture cursor before processing. The in-loop
    // stale-cursor guard only fires when the in-memory mirror knows a cursor was
    // set (reorg_cursor_block != -1) — after a process restart the mirror is
    // always -1, so a cursor row left armed by a crashed near-tip run would
    // silently turn every protected-table write into a full-row undo capture
    // for the rest of the bulk sync. Armed batches re-set the cursor per block.
    reorg_undo.clearCursor(self.database, protocol) catch |err|
        std.log.warn("reorg undo-log: failed to clear cursor at sync start: {}", .{err});
    self.invalidateReorgCursor();

    // Index in batches with adaptive batch sizing
    // Starts at configured size, halves on RPC response size errors, grows back on success
    var current_batch_size = self.config.batch_size;
    const ABSOLUTE_MIN_BATCH: u64 = 100;
    // Arm reorg undo capture only within this many blocks of the head. Must exceed the
    // deepest realistic reorg (Ethereum finality is ~64-128 blocks); 1000 is a wide
    // safety margin while still skipping capture for the millions of bulk-sync blocks.
    const REORG_ARM_WINDOW: u64 = 1000;
    var from_block = last_synced + 1;
    var blocks_indexed: u64 = 0;

    while (from_block <= target_block and !self.should_stop.load(.acquire) and !shutdown.isRequested()) {
        const to_block = @min(from_block + current_batch_size - 1, target_block);
        const batch_blocks = to_block - from_block + 1;

        // Arm reorg capture only near the tip; far-from-head batches are finalized and
        // can't reorg, so skip capturing their undo (the dominant DB write during bulk
        // sync). On the bulk-sync side, clear any stale cursor an earlier near-tip run
        // may have left armed so the triggers don't capture against it.
        self.reorg_arm = target_block - to_block < REORG_ARM_WINDOW;
        if (!self.reorg_arm and self.reorg_cursor_block != -1) {
            reorg_undo.clearCursor(self.database, protocol) catch |err|
                std.log.warn("reorg undo-log: failed to clear stale cursor: {}", .{err});
            self.invalidateReorgCursor();
        }

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
            // The reverted transaction included this batch's setCursor writes; drop the
            // in-memory mirror so the smaller-batch retry re-arms the cursor per block.
            self.invalidateReorgCursor();
            // The rolled-back batch reverted its known_resolvers + accounts inserts;
            // drop those dedup caches so the entries get re-inserted on retry.
            self.clearKnownResolverCache();
            self.clearAccountObsCache();

            if ((err == error.RpcError or err == error.StreamTooLong) and current_batch_size > ABSOLUTE_MIN_BATCH) {
                current_batch_size = @max(ABSOLUTE_MIN_BATCH, current_batch_size / 2);
                // The retry restarts at the batch head, often in a different density
                // regime than the tail this state was learned from — a stale estimate
                // predicts oversized chunks and cascades through overflow retries.
                self.v1_events_per_block = 0;
                self.v1_rpc_chunk_ceiling = 0;
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

        // --- Block-hash lineage (reorg detection) ---
        // Near the tip, store per-block (hash, parent_hash) so a reorg's fork point is
        // located exactly and the parent chain is reliable; far from the tip a single
        // boundary hash suffices. Bounded: only a small armed batch is stored per-block.
        const store_per_block = self.reorg_arm and (to_block - from_block + 1) <= PER_BLOCK_LINEAGE_MAX;

        // Gather headers OUTSIDE the write transaction so RPC never holds the DB lock.
        var lineage: std.ArrayList(BlockLineage) = .empty;
        defer lineage.deinit(self.allocator);
        if (store_per_block) {
            // For to_block, prefer the hash observed while indexing its logs: it is
            // consistent with the committed events, so a reorg landing after indexing
            // can't mask itself from the next poll's reorg check (which examines exactly
            // this height). Intermediate blocks are fetched for their real headers in
            // ONE batched call instead of up to 128 sequential round-trips.
            const reuse_boundary = self.last_seen_block_hash != null and self.last_seen_block_number == to_block;
            var numbers: std.ArrayList(u64) = .empty;
            defer numbers.deinit(self.allocator);
            var b = from_block;
            while (b <= to_block) : (b += 1) {
                if (b == to_block and reuse_boundary) continue;
                try numbers.append(self.allocator, b);
            }
            if (numbers.items.len > 0) {
                self.rate_limiter.acquire();
                const headers = try client.getBlockHeadersBatch(numbers.items);
                defer self.allocator.free(headers);
                for (headers, numbers.items) |maybe_header, number| {
                    const info = maybe_header orelse return error.BlockNotFound;
                    try lineage.append(self.allocator, .{ .number = number, .hash = info.hash, .parent_hash = info.parent_hash });
                }
            }
            if (reuse_boundary) {
                try lineage.append(self.allocator, .{ .number = to_block, .hash = self.last_seen_block_hash.?, .parent_hash = Hash.zero });
            }
        }

        // Store block hashes for reorg detection and update sync state ATOMICALLY.
        try self.database.beginTransaction();
        errdefer self.database.rollbackTransaction();

        if (store_per_block) {
            for (lineage.items) |bl| try self.database.storeBlockHash(protocol, bl.number, bl.hash, bl.parent_hash);
        } else if (self.last_seen_block_hash != null and self.last_seen_block_number == to_block) {
            // Bulk sync: reuse the log hash to avoid an extra RPC (parent_hash unused off-tip).
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

            // Prune undo-log entries below the reorg retention window (same 1000-block
            // horizon as block_hashes — rollbacks deeper than that are refused).
            const undo_keep_from: u64 = if (to_block > 1000) to_block - 1000 else 0;
            reorg_undo.pruneBelow(self.database, protocol, undo_keep_from) catch |err| {
                std.log.warn("reorg undo-log prune failed (non-fatal): {}", .{err});
            };

            // Clear block timestamp cache to prevent memory growth
            self.clearBlockTimestampCache();

            // Flatten the WAL once per outer batch: chunk-processing reads slow
            // down as WAL depth grows, so trade random mid-chunk stalls for one
            // bounded checkpoint here.
            self.database.checkpointWal();

            // Force a brief pause to allow memory to be reclaimed
            self.rate_limiter.acquire();
        }

        from_block = to_block + 1;
    }

    std.log.info("Synced {s} to block {d}", .{ protocol.toString(), target_block });
}

pub fn indexBlockRange(self: *Indexer, protocol: models.Protocol, client: *rpc.Client, from_block: u64, to_block: u64) !void {
    // Per-batch namehash→name read cache: clear each batch to pick up name patches.
    {
        var nv_it = self.name_by_namehash_cache.valueIterator();
        while (nv_it.next()) |v| self.allocator.free(v.*);
        self.name_by_namehash_cache.clearRetainingCapacity();
    }

    // IMPORTANT: Process events in dependency order:
    // 1. First create names (NameRegistered, NewSubname)
    // 2. Then modify names (SubregistryUpdate, ResolverUpdate, Transfer)
    // 3. Then process data dependent on names existing (resolver records)

    // Block range constants from contract config (protocol-specific)
    const v1_contracts = self.config.v1_contracts;

    // === V1 EVENTS ===
    // The V1 era starts at the earliest configured V1 marker for this network:
    // the temporary-registrar start where pre-permanent-registrar history exists
    // (mainnet), else the V1 deployment block. It ends at the explicit per-network
    // v1_end_block (0 = no sunset) — never at a code constant, so V1 activity
    // after a V2 launch keeps indexing until a real cutover is configured.
    const v2_deployment = self.config.v2_contracts.v2_deployment_block;
    const v1_start = self.v1EraStart();
    const v1_end = v1_contracts.v1_end_block;
    const should_index_v1 = (v1_start > 0) and (to_block >= v1_start) and
        (v1_end == 0 or from_block <= v1_end);

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

        // Phase 1b: Renewals from the standalone ETHRenewerV1 (same NameRenewed as the
        // registrar, second source). No-op when the renewer isn't deployed.
        try self.indexV2RenewerEvents(protocol, client, from_block, to_block);

        // Phase 2: Subregistry events (depends on Phase 1 discovering subregistries)
        try self.indexSubregistryEvents(protocol, client, from_block, to_block);
        try self.processRemainingOrphans(protocol);

        // Phase 3: Transfer events (depends on names existing)
        // Note: V1→V2 migration is detected in handleLabelRegistered via sender address
        try self.indexTransferEvents(protocol, client, from_block, to_block);

        // Phase 5: V2 reverse registrar events. Independent of names — populates
        // the reverse_records table so primary-name lookups don't have to scan
        // the events feed.
        try self.indexV2ReverseRegistrarEvents(protocol, client, from_block, to_block);

        // Phase 6: LabelStore label-dictionary events. Runs after subregistry events
        // so any unknown_labels created in this range are present to heal. No-op when
        // LabelStore isn't deployed.
        try self.indexLabelStoreEvents(protocol, client, from_block, to_block);
    }

    // === RESOLVER RECORD EVENTS (V1 and V2) ===
    // Depends on names + resolvers being set, so it runs after both protocol
    // phases. Deliberately OUTSIDE the V2 gate: on mainnet (v2_deployment = 0)
    // the V2 branch never runs, and keeping resolver indexing inside it meant
    // mainnet indexed ZERO resolver records (text/addr/contenthash/...) — the
    // 2026-06-06 readiness-review disqualifier. Discovery comes from V1
    // NewResolver / V2 ResolverUpdated registering known_resolvers, so this
    // single pass serves both protocols. The V1 leg additionally requires
    // protocol == .v1: on mainnet the combined indexer's .v2 pass also sees
    // should_index_v1 = true, and without the protocol check it would crawl
    // V1-era ranges under protocol = 'v2' — correct today only because V2
    // resolver discovery finds nothing there, and one stray v2
    // known_resolvers row would flip it to indexing V1 logs as 'v2'.
    if ((should_index_v1 and protocol == .v1) or should_index_v2) {
        try self.indexResolverEvents(protocol, client, from_block, to_block);
    }
}
