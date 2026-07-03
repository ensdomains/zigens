//! Reorg-support methods for the Indexer.
//!
//! Cursor bookkeeping for the reorg undo-log (mark/invalidate) and the two one-shot
//! post-sync "uncaptured" recomputes (PCC expiry mirror, V2 reachability), split out
//! of indexer.zig. Aliased back as `pub const f = reorg_support.f;`, so `self.f(...)`
//! and `Indexer.f` call sites are unchanged (the intra-cluster `self.invalidateReorg\
//! Cursor()` resolves through that alias too).

const std = @import("std");
const models = @import("../types/models.zig");
const Address = @import("../types/address.zig").Address;
const reorg_undo = @import("../storage/reorg_undo.zig");
const Indexer = @import("indexer.zig").Indexer;

/// Record the block currently being processed so the reorg undo-log tags captured
/// mutations with the correct block. Called per event from the dispatch loops,
/// BEFORE the handler mutates. De-duped on (protocol, block) so it's one cheap
/// upsert per block, not per event. Capture failure must not abort indexing — a
/// missed cursor only degrades reorg-rollback precision, so errors are logged.
pub fn markEventBlock(self: *Indexer, protocol: models.Protocol, block_number: u64) void {
    if (!self.reorg_arm) return; // bulk sync: finalized blocks can't reorg — skip capture
    const proto_i: i8 = @intCast(@intFromEnum(protocol));
    if (self.reorg_cursor_block == @as(i64, @intCast(block_number)) and self.reorg_cursor_proto == proto_i) return;
    reorg_undo.setCursor(self.database, protocol, block_number) catch |err| {
        std.log.warn("reorg undo-log: failed to set cursor for {s} block {d}: {}", .{ protocol.toString(), block_number, err });
        return;
    };
    self.reorg_cursor_block = @intCast(block_number);
    self.reorg_cursor_proto = proto_i;
}

/// Forget the in-memory cursor mirror so the next markEventBlock re-sets the DB
/// cursor row unconditionally. MUST be called whenever the reorg_cursor row is
/// cleared out-of-band (reorg rollback clears it; a batch-transaction rollback
/// reverts the setCursor write). Otherwise the de-dup short-circuit would keep
/// believing the row is set and silently disable undo capture for that block.
pub fn invalidateReorgCursor(self: *Indexer) void {
    self.reorg_cursor_block = -1;
    self.reorg_cursor_proto = -1;
}

/// Run the one-shot PCC Domain.expiry mirror with reorg-undo capture DISARMED.
/// `materializePccDomainExpiry` is a derived bulk recompute (not block
/// processing), so it must not self-capture: a captured undo row would, on a
/// later reorg, wrongly revert the mirror back to its pre-materialize expiry.
/// We disarm the cursor exactly like backfill/replay (reorg_undo.clearCursor)
/// and re-arm lazily — `invalidateReorgCursor` makes the next markEventBlock
/// re-set the DB cursor. Wrapped names are V1-only (NameWrapper).
/// Pub: replay.zig runs it as its post-rebuild pass (step 7d).
pub fn materializePccUncaptured(self: *Indexer) void {
    reorg_undo.clearCursor(self.database, .v1) catch |err| {
        std.log.warn("reorg undo-log: failed to disarm cursor before PCC materialize: {}", .{err});
    };
    defer self.invalidateReorgCursor();
    const pcc_rows = self.database.materializePccDomainExpiry() catch |err| {
        std.log.warn("materializePccDomainExpiry failed: {}", .{err});
        return;
    };
    std.log.info("PCC Domain.expiry mirror materialized: {d} row(s) updated", .{pcc_rows});
}

/// One-shot, order-independent V2 reachability reconciliation, run at
/// initial-sync completion (cursor disarmed so it doesn't self-capture, like
/// materializePccUncaptured). Recomputes reachability from the final registry
/// tree, healing names left wrongly-reachable by a repoint cascade that ran in
/// an earlier phase/chunk than the child registration. V2-only (V1 has no
/// subregistry tree).
pub fn reconcileReachabilityUncaptured(self: *Indexer) void {
    reorg_undo.clearCursor(self.database, .v2) catch |err| {
        std.log.warn("reorg undo-log: failed to disarm cursor before reachability reconcile: {}", .{err});
    };
    defer self.invalidateReorgCursor();
    const head = self.database.getSyncState(.v2) catch null orelse 0;
    const roots = [_]Address{ self.config.v2_contracts.eth_registry, self.config.v2_contracts.root_registry };
    const fixed = self.database.reconcileV2Reachability(self.allocator, &roots, head, std.time.timestamp()) catch |err| {
        std.log.warn("reconcileV2Reachability failed: {}", .{err});
        return;
    };
    std.log.info("V2 reachability reconciled: {d} name(s) marked unreachable", .{fixed});
}
