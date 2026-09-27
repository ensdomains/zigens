const std = @import("std");
const zsys = @import("../utils/system.zig");
const db_module = @import("database.zig");
const Database = db_module.Database;
const Query = db_module.Query;
const models = @import("../types/models.zig");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;
const reorg_undo = @import("reorg_undo.zig");
const heal_targets = @import("heal_targets.zig");

// ── Reorg rollback delete-lists ────────────────────────────────────────────────
// Single source of truth for the tables whose post-N rows `rollbackToBlock` deletes.
// The comptime coverage guard below cross-checks them against the reorg trigger
// arrays so a new rollback delete can't silently bypass undo capture.

/// Deleted by `(protocol, block_number > N)` — insert-only logs + derived tables alike.
pub const reorg_rollback_by_block_number = [_][]const u8{
    "events",
    "block_hashes",
    "orphaned_registrations",
    "resolver_addresses",
    "resolver_contenthashes",
    "resolver_texts",
    "resolver_aliases",
    "resolver_pubkeys",
    "resolver_abis",
    "resolver_names",
    "resolver_interfaces",
    "resolver_versions",
    "resolver_dns_records",
    "resolver_dns_zonehashes",
    "resolver_authorisations",
    "reverse_records",
    "approvals",
    "eac_roles",
    "resolver_metadata",
    "resolver_approvals",
    "resolver_named_resources",
    "registrations",
    "name_history",
    "resolver_links",
    "resolver_datas",
    "resolver_kinds",
};

/// Deleted by `(protocol, created_block > N)`.
pub const reorg_rollback_by_created_block = [_][]const u8{ "names", "registries" };

/// Deleted by `(protocol, <col> > N)` for a non-`block_number` block column.
pub const reorg_rollback_by_other_col = [_]struct { name: []const u8, col: []const u8 }{
    .{ .name = "registry_entries", .col = "updated_block" },
    .{ .name = "resolvers", .col = "set_block" },
};

/// Tables deleted on rollback that need NO undo capture: they are insert-only (rows
/// are only inserted then post-N-deleted — no in-place UPDATE / clear-DELETE of a
/// pre-N row to reverse). Everything else deleted on rollback MUST be captured by a
/// reorg trigger (`reorg_undo.PROTECTED_TABLES` ∪ `REORG_ACTIVE_TABLES`).
const reorg_capture_waived = [_][]const u8{
    // events: rows are append-only EXCEPT the denormalized name/namehash columns, which
    // updatePlaceholderEventsByName (names.zig) patches in place once a placeholder name
    // resolves. Deliberately NOT reorg-captured: the canonical `data` JSON is untouched,
    // the patch is idempotent and self-heals on re-sync (the resolving event re-fires),
    // and its `WHERE name=?` (no protocol filter) would make undo capture cross-protocol-
    // ambiguous. Residual (accepted): if the resolving event is itself reorged out, a
    // pre-N event row keeps the resolved value in those two derived columns. See
    // [[events-placeholder-patch-reorg-waiver]].
    "events",
    "block_hashes", // append-only block-hash chain (insert + retention-prune only)
    "name_history", // append-only change log (INSERT only; no in-place mutation)
    "resolvers", // resolver entity table: insert-only (set_block, INSERT OR IGNORE keeps first); attribute records live in the PROTECTED resolver_* tables
};

fn reorgCovered(comptime name: []const u8) bool {
    for (reorg_undo.PROTECTED_TABLES ++ reorg_undo.REORG_ACTIVE_TABLES ++ reorg_capture_waived) |t| {
        if (std.mem.eql(u8, t, name)) return true;
    }
    return false;
}

fn inRollbackDeleteList(comptime name: []const u8) bool {
    for (reorg_rollback_by_block_number ++ reorg_rollback_by_created_block) |t| {
        if (std.mem.eql(u8, t, name)) return true;
    }
    for (reorg_rollback_by_other_col) |t| {
        if (std.mem.eql(u8, t.name, name)) return true;
    }
    return false;
}

comptime {
    @setEvalBranchQuota(100000);
    // Guard 1 — every table whose post-N rows `rollbackToBlock` deletes must be either
    // reorg-captured or explicitly waived as insert-only. Catches "added a rollback
    // delete but forgot the trigger array" (the 2026-06-02 regression class).
    for (reorg_rollback_by_block_number ++ reorg_rollback_by_created_block) |t| {
        if (!reorgCovered(t)) @compileError("reorg coverage gap: '" ++ t ++ "' is deleted on rollback but neither reorg-captured nor waived as insert-only (see sync.zig reorg_capture_waived)");
    }
    for (reorg_rollback_by_other_col) |t| {
        if (!reorgCovered(t.name)) @compileError("reorg coverage gap: '" ++ t.name ++ "' is deleted on rollback but neither reorg-captured nor waived");
    }
    // Guard 2 (symmetric) — every PROTECTED table (whose in-place updates are captured)
    // must ALSO have its post-N inserts deleted by a rollback list; otherwise a reorg
    // reverses updates but leaves genuinely-new rows behind. REORG_ACTIVE tables are
    // exempt: replayUndo's op-'I' handler removes their post-N inserts (no protocol
    // column ⇒ no created-after delete).
    for (reorg_undo.PROTECTED_TABLES) |t| {
        if (!inRollbackDeleteList(t)) @compileError("reorg coverage gap: PROTECTED table '" ++ t ++ "' has its updates captured but its post-N inserts are never deleted on rollback (add it to a sync.zig reorg_rollback_* list)");
    }
}

/// Safely convert u64 expiry to i64 for SQLite storage.
/// Values exceeding i64::max are mapped to 0 (never expires).
fn safeU64ToI64(val: u64) i64 {
    if (val > @as(u64, @intCast(std.math.maxInt(i64)))) return 0;
    return @intCast(val);
}

// ============================================================================
// SYNC/MIGRATION OPERATIONS
// ============================================================================

pub fn getSyncState(db: *Database, protocol: models.Protocol) !?u64 {
    const sql = "SELECT last_synced_block FROM sync_state WHERE protocol = ?";

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());

    if (try q.step()) {
        return @intCast(q.getInt64(0));
    }
    return null;
}

pub const ProtocolSync = struct { block: u64, at: i64 };

/// Like getSyncState but also returns when the head was last advanced —
/// the freshness signal for the coverage surface.
pub fn getSyncStateFull(db: *Database, protocol: models.Protocol) !?ProtocolSync {
    const sql = "SELECT last_synced_block, last_synced_at FROM sync_state WHERE protocol = ?";

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());

    if (try q.step()) {
        return .{ .block = @intCast(q.getInt64(0)), .at = q.getInt64(1) };
    }
    return null;
}

pub fn setSyncState(db: *Database, protocol: models.Protocol, block: u64) !void {
    const sql = try db.upsertSql(db.allocator, "sync_state", &.{ "protocol", "last_synced_block", "last_synced_at" }, .replace);
    defer db.allocator.free(sql);

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());
    try q.bindInt64(@intCast(block));
    try q.bindInt64(zsys.timestamp());

    try q.exec();
}

pub fn storeBlockHash(db: *Database, protocol: models.Protocol, block_number: u64, block_hash: Hash, parent_hash: Hash) !void {
    const sql = try db.upsertSql(db.allocator, "block_hashes", &.{ "protocol", "block_number", "block_hash", "parent_hash", "timestamp" }, .replace);
    defer db.allocator.free(sql);

    var q = try Query.initCached(db, sql);
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());
    try q.bindInt64(@intCast(block_number));
    try q.bindHashBuf(block_hash);
    try q.bindHashBuf(parent_hash);
    try q.bindInt64(zsys.timestamp());

    try q.exec();
}

/// Get stored block hash for reorg detection
pub fn getBlockHash(db: *Database, protocol: models.Protocol, block_number: u64) !?Hash {
    const sql = "SELECT block_hash FROM block_hashes WHERE protocol = ? AND block_number = ?";

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());
    try q.bindInt64(@intCast(block_number));

    if (try q.step()) {
        return try q.getHash(0);
    }
    return null;
}

/// Rollback all derived state to the given block (for reorg handling).
/// Atomic (single transaction) and bounded by the block_hashes retention window.
/// Bit-equivalent to a clean sync stopping at `block_number`:
///   1. Reverses in-place mutations to rows created at/before the block (owner/
///      resolver/expiry/… on names, registrant on registrations, and resolver
///      records removed by clear-events) via the reorg undo-log (see reorg_undo.zig).
///   2. Deletes rows created after the block (created_block/block_number > block).
///   3. Deletes insert-only events + block_hashes after the block.
/// Undo capture requires the indexer to set the per-protocol cursor per event
/// (reorg_undo.setCursor); without a cursor (backfill/replay) nothing is captured.
pub fn rollbackToBlock(db: *Database, protocol: models.Protocol, block_number: u64) !void {
    const protocol_str = protocol.toString();
    const block_i64: i64 = @intCast(block_number);

    // Reorg-depth guardrail: never roll back further than the block_hashes retention
    // window (cleanupOldBlockHashes keeps the last 1000 blocks). Beyond it there are
    // no stored hashes to validate against, so a deeper "rollback" is a blind guess —
    // fail loud rather than silently corrupt state.
    {
        const REORG_RETENTION_BLOCKS: u64 = 1000; // matches cleanupOldBlockHashes keep_blocks
        const head = (try db.getSyncState(protocol)) orelse block_number;
        if (head > block_number and head - block_number > REORG_RETENTION_BLOCKS) {
            std.log.err("Refusing reorg rollback on {s}: depth {d} exceeds retention window {d} (head={d}, target={d})", .{ protocol_str, head - block_number, REORG_RETENTION_BLOCKS, head, block_number });
            return error.ReorgTooDeep;
        }
    }

    // Atomicity: the entire rollback runs in one transaction. A crash or error
    // mid-rollback must leave the DB at its pre-rollback state, never half-rolled.
    // The Tx guard rolls back on any early-error return; commit() below seals it.
    var tx = try db_module.Tx.begin(db, .immediate);
    defer tx.deinit();

    // Reverse in-place mutations FIRST: clear the cursor so the restore writes don't
    // self-capture, then reverse-apply every undo entry with block > N. This must run
    // before the created-after deletes below — a re-inserted (cleared) row created
    // after N is then removed by those deletes; an UPDATE-restored pre-N row survives.
    try reorg_undo.clearCursor(db, protocol);
    try reorg_undo.replayUndo(db, protocol, block_number);

    // Delete rows created after N, keyed by block_number (insert-only logs + derived
    // tables alike). replayUndo above already reversed in-place overwrites of pre-N
    // rows, restoring their as-of-N block_number, so these deletes remove only
    // genuinely-new rows. If a table is missing from the schema, Query.init (preparing
    // the DELETE) fails at the `try` boundary and bubbles up — reorg rollback is not
    // safe to continue on partial failure. The set is the comptime-guarded
    // `reorg_rollback_by_block_number` (see the coverage assert at module scope).
    inline for (reorg_rollback_by_block_number) |table| {
        const sql = "DELETE FROM " ++ table ++ " WHERE protocol = ? AND block_number > ?";
        var q = try Query.init(db, sql);
        defer q.deinit();
        try q.bindTextStatic(protocol_str);
        try q.bindInt64(block_i64);
        try q.exec();
    }

    // Derived-state tables keyed by created_block: delete rows created after the block.
    // Updates to rows created <= block_number will be re-derived when re-syncing.
    inline for (reorg_rollback_by_created_block) |table| {
        const sql = "DELETE FROM " ++ table ++ " WHERE protocol = ? AND created_block > ?";
        var q = try Query.init(db, sql);
        defer q.deinit();
        try q.bindTextStatic(protocol_str);
        try q.bindInt64(block_i64);
        try q.exec();
    }

    // Tables keyed by a non-`block_number` block column: same created-after delete,
    // different column. registry_entries → updated_block; resolvers (insert-only entity
    // table) → set_block.
    inline for (reorg_rollback_by_other_col) |t| {
        const sql = "DELETE FROM " ++ t.name ++ " WHERE protocol = ? AND " ++ t.col ++ " > ?";
        var q = try Query.init(db, sql);
        defer q.deinit();
        try q.bindTextStatic(protocol_str);
        try q.bindInt64(block_i64);
        try q.exec();
    }

    // v1_controllers (V1-only, no protocol column) drives WHICH contracts get indexed
    // (getActiveControllers), so a reorged-out ControllerAdded/Removed must be wound back or
    // subsequent indexing scope is corrupted. It is captured in the undo-log via the
    // reorg_active triggers (add=INSERT op 'I', remove/re-add=UPDATE op 'U') and reversed by
    // replayUndo above — which correctly handles a remove-then-readd straddling N that a
    // column-predicate delete could not. Nothing to do here.

    // accounts is cross-protocol (no protocol column) and rolled back PER protocol and
    // independently — so we must NOT blanket-delete by first_seen_block (that would drop
    // the OTHER, still-synced protocol's accounts). Instead the undo-log handles it: the
    // reorg_active triggers capture each protocol's UPDATE/DELETE (reversed by replayUndo
    // above) AND its INSERT (op 'I'), and replayUndo's 'I' handler clears only this
    // protocol's seen flag and drops the row only when neither protocol still claims it.

    // Resolution cache: drop derived answers pinned to a block newer than the
    // rollback target so the next read re-resolves against the restored chain.
    // Chain-scoped (one process = one chain), not protocol-scoped — a rollback on
    // either protocol may purge cache rows attributable to the other, which is
    // harmless for a disposable overlay (it self-heals on the next lookup).
    {
        var cq = try Query.init(db, "DELETE FROM resolution_cache WHERE chain_id = ? AND block_dep_num > ?");
        defer cq.deinit();
        try cq.bindInt64(@intCast(db.chain_id));
        try cq.bindInt64(block_i64);
        try cq.exec();
    }

    // Re-arm the init-gap heal ledger: heal sweeps write with undo capture
    // deliberately disarmed, so the created-after deletes above may have
    // removed healed rows — a surviving `completed` marker would make that
    // loss permanent. Re-opening every target costs one idempotent full
    // re-sweep that converges projections to the surviving chain; attempts
    // reset too, since prior failures say nothing about this chain.
    try heal_targets.resetHealTargets(db, protocol);

    // Update sync state
    try db.setSyncState(protocol, block_number);

    try tx.commit();

    std.log.warn("Rolled back {s} to block {d} (atomic; in-place updates reversed via undo-log + created-after rows removed)", .{ protocol_str, block_number });
}

/// Cleanup old block hashes (keep last 1000 blocks for reorg detection)
pub fn pruneOldBlockHashes(db: *Database, protocol: models.Protocol, current_block: u64) !void {
    const keep_blocks = 1000;
    if (current_block <= keep_blocks) return;

    const cutoff_block = current_block - keep_blocks;
    const sql = "DELETE FROM block_hashes WHERE protocol = ? AND block_number < ?";

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());
    try q.bindInt64(@intCast(cutoff_block));
    try q.exec();
}

/// Verify database integrity (uses quick_check for performance on large databases)
/// Cheap connectivity/liveness probe: one trivial query, no page scans.
/// The API uses this at startup instead of checkIntegrity — quick_check reads
/// every btree page, which on a mainnet-scale DB is minutes of full-file I/O
/// against a live writer, and a read-only consumer can't act on the result
/// anyway (corruption surfaces at query time regardless).
pub fn probeLiveness(db: *Database) !bool {
    var q = try Query.init(db, "SELECT 1");
    defer q.deinit();
    return try q.step();
}

pub fn checkIntegrity(db: *Database) !bool {
    if (db.isPostgres()) {
        // Postgres has no PRAGMA quick_check; a successful trivial query is the
        // connectivity/liveness probe (deep page verification is the server's job).
        var q = try Query.init(db, "SELECT 1");
        defer q.deinit();
        return try q.step();
    }

    const sql = "PRAGMA quick_check";

    var q = try Query.init(db, sql);
    defer q.deinit();

    if (try q.step()) {
        if (q.getTextSlice(0)) |result_slice| {
            const is_ok = std.mem.eql(u8, result_slice, "ok");
            if (!is_ok) {
                std.log.err("Database integrity check failed: {s}", .{result_slice});
            }
            return is_ok;
        }
    }
    return false;
}

/// Register or update a known subregistry.
///
/// `first_seen_block` should be the subregistry's actual creation block
/// (from `registries.created_block`) — used only on initial INSERT.
/// `last_indexed_block` is the high-water mark for events we've already
/// indexed from this subregistry. On conflict, we keep the MAX of the
/// existing and new value so callers advancing the checkpoint never go
/// backwards.
/// Advance `last_indexed_block` for MANY subregistries in one statement.
///
/// The per-batch checkpoint advance used to be one `registerSubregistry` call per known
/// subregistry — 229 individual UPSERTs on the reference deployment, every batch, growing
/// linearly with the number of subregistries ever discovered. Round-trip-bound rather than
/// work-bound: against Neon at ~27ms that is **6.2 seconds per batch** doing almost nothing,
/// since the vast majority of those rows are already at the head.
///
/// Semantics are identical to the single-row version: `first_seen_block` is ignored on
/// conflict (discovery already set it from the real `created_block`) and `last_indexed_block`
/// is a MAX/GREATEST merge, so it can never regress and the result does not depend on the
/// order rows appear in the batch.
///
/// Binds are static and fed from an arena: the per-statement TRACKED-copy cap is 32, which a
/// chunk of address binds would blow straight through (the names bulk writer does the same).
pub fn registerSubregistriesBatch(
    db: *Database,
    protocol: models.Protocol,
    addresses: []const []const u8,
    last_indexed_block: u64,
) !void {
    if (addresses.len == 0) return;

    const CHUNK: usize = 150;
    var off: usize = 0;
    while (off < addresses.len) : (off += CHUNK) {
        const chunk = addresses[off..@min(off + CHUNK, addresses.len)];

        // Arena declared before the statement so static binds outlive it (LIFO defers).
        var scratch = std.heap.ArenaAllocator.init(db.allocator);
        defer scratch.deinit();
        const sa = scratch.allocator();

        var sql: std.ArrayList(u8) = .empty;
        try sql.appendSlice(sa,
            \\INSERT INTO known_subregistries (protocol, address, first_seen_block, last_indexed_block)
            \\VALUES
        );
        for (chunk, 0..) |_, i| {
            try sql.appendSlice(sa, if (i == 0) " (?, ?, ?, ?)" else ", (?, ?, ?, ?)");
        }
        try sql.appendSlice(sa, "\nON CONFLICT(protocol, address) DO UPDATE SET\n  last_indexed_block = ");
        try sql.appendSlice(sa, db.dialect().scalar_max);
        try sql.appendSlice(sa, "(known_subregistries.last_indexed_block, excluded.last_indexed_block)");

        var q = try Query.init(db, sql.items);
        defer q.deinit();
        for (chunk) |address| {
            try q.bindTextStatic(protocol.toString());
            try q.bindTextStatic(try sa.dupe(u8, address));
            try q.bindInt64(@intCast(last_indexed_block));
            try q.bindInt64(@intCast(last_indexed_block));
        }
        try q.exec();
    }
}

pub fn registerSubregistry(
    db: *Database,
    protocol: models.Protocol,
    address: []const u8,
    first_seen_block: u64,
    last_indexed_block: u64,
) !void {
    const sql = try std.fmt.allocPrint(db.allocator,
        \\INSERT INTO known_subregistries (protocol, address, first_seen_block, last_indexed_block)
        \\VALUES (?, ?, ?, ?)
        \\ON CONFLICT(protocol, address) DO UPDATE SET
        \\  last_indexed_block = {s}(known_subregistries.last_indexed_block, excluded.last_indexed_block)
    , .{db.dialect().scalar_max}); // MAX (SQLite) / GREATEST (Postgres); table-qualify the existing
    defer db.allocator.free(sql); // value — Postgres rejects an unqualified col in DO UPDATE as ambiguous.

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());
    try q.bindText(address);
    try q.bindInt64(@intCast(first_seen_block));
    try q.bindInt64(@intCast(last_indexed_block));

    try q.exec();
}

/// The earliest block at which `address` exists as a registry for `protocol` — i.e. the
/// lower bound for any event it could have emitted (a contract emits nothing before it is
/// created). Used to scope subregistry backfill to [created_block, …] instead of the
/// indexer's start_block, which would scan millions of provably-empty pre-creation blocks.
/// Returns 0 if the address isn't a known registry (caller falls back to start_block).
pub fn getSubregistryCreatedBlock(db: *Database, protocol: models.Protocol, address: []const u8) !u64 {
    var q = try Query.initCached(db, "SELECT COALESCE(MIN(created_block), 0) FROM registries WHERE protocol = ? AND address = ?");
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindText(address);
    if (try q.step()) return @intCast(q.getInt64(0));
    return 0;
}

/// Like registerResolver, but reports whether this was the resolver's FIRST
/// sighting. First sightings must trigger a historical event backfill: a
/// factory-deployed resolver emits its initialize()-time events (EACRolesChanged
/// role grants) blocks BEFORE the ResolverUpdated that makes it known, and the
/// resolver pass only fetches known-resolver events within the current batch —
/// without a backfill those init events are lost (the discovery-path backfill
/// cannot fire for resolvers registered here: its `kr.address IS NULL` filter
/// is already false by the time it runs).
pub fn registerResolverIfNew(db: *Database, protocol: models.Protocol, address: []const u8, block_number: u64) !bool {
    const exists = blk: {
        var q = try Query.init(db, "SELECT 1 FROM known_resolvers WHERE protocol = ? AND address = ? LIMIT 1");
        defer q.deinit();
        try q.bindTextStatic(protocol.toString());
        try q.bindText(address);
        break :blk try q.step();
    };
    try registerResolver(db, protocol, address, block_number);
    return !exists;
}

/// Register or update a known resolver
pub fn registerResolver(db: *Database, protocol: models.Protocol, address: []const u8, block_number: u64) !void {
    const sql = try std.fmt.allocPrint(db.allocator,
        \\INSERT INTO known_resolvers (protocol, address, first_seen_block, last_indexed_block)
        \\VALUES (?, ?, ?, ?)
        \\ON CONFLICT(protocol, address) DO UPDATE SET
        \\  last_indexed_block = {s}(known_resolvers.last_indexed_block, excluded.last_indexed_block)
    , .{db.dialect().scalar_max}); // MAX (SQLite) / GREATEST (Postgres); table-qualify the existing
    defer db.allocator.free(sql); // value — Postgres rejects an unqualified col in DO UPDATE as ambiguous.

    var q = try Query.initCached(db, sql);
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());
    try q.bindText(address);
    try q.bindInt64(@intCast(block_number));
    try q.bindInt64(@intCast(block_number));

    try q.exec();
}

/// Whether `address` is a fully-indexed resolver for `protocol` — one whose record
/// events this indexer ingests (registered on first sight via registerResolver). For
/// such a resolver an indexed record MISS is authoritative: the record does not exist
/// in event-visible storage on-chain, so a live re-read can only refetch the same
/// emptiness.
pub fn isKnownResolver(db: *Database, protocol: models.Protocol, address: Address) !bool {
    var q = try Query.initCached(db,
        \\SELECT 1 FROM known_resolvers WHERE protocol = ? AND address = ? LIMIT 1
    );
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(address);
    return try q.step();
}

/// Get subregistries to index for a block range
/// Uses cache table for O(1) lookup, falls back to full scan on first run
/// Result of subregistry discovery, including which ones are newly discovered and need backfill.
pub const SubregistryDiscoveryResult = struct {
    all: [][]u8,
    newly_discovered: [][]u8,

    pub fn deinit(self: *SubregistryDiscoveryResult, allocator: std.mem.Allocator) void {
        for (self.all) |s| allocator.free(s);
        allocator.free(self.all);
        for (self.newly_discovered) |s| allocator.free(s);
        allocator.free(self.newly_discovered);
    }
};

pub fn discoverAndGetSubregistries(db: *Database, protocol: models.Protocol, main_registry: []const u8, from_block: u64, to_block: u64) !SubregistryDiscoveryResult {
    _ = to_block;
    // `from_block` is the current batch's lower bound and is intentionally
    // unused here: each newly-discovered subregistry's checkpoint is keyed
    // off its own `registries.created_block`, not the batch boundary. See
    // the comment on the discovery SQL below for why.
    _ = from_block;
    const protocol_str = protocol.toString();

    // Discover any subregistry recorded in the registries table that is not
    // yet in known_subregistries. We intentionally do not filter by
    // created_block: subregistries registered in a previous batch via a
    // nested SubregistryUpdated (4LD and deeper, where Phase 2 events from
    // a freshly-discovered 3LD subregistry register a further subregistry
    // *after* Phase 2 discovery already ran) would otherwise never be
    // picked up — their created_block would fall outside both the batch
    // that inserted them (discovery ran too early) and all subsequent
    // batches (window doesn't cover prior blocks). The LEFT JOIN keeps the
    // common case O(0) once steady state is reached.
    const discover_sql =
        \\SELECT r.address, MIN(r.created_block) AS created_block
        \\FROM registries r
        \\LEFT JOIN known_subregistries ks ON ks.protocol = r.protocol AND ks.address = r.address
        \\WHERE r.protocol = ?
        \\  AND r.address != '0x0000000000000000000000000000000000000000'
        \\  AND r.address != ?
        \\  AND ks.address IS NULL
        \\GROUP BY r.address
    ;

    var new_subregistries: std.ArrayList([]u8) = .empty;
    errdefer {
        for (new_subregistries.items) |s| db.allocator.free(s);
        new_subregistries.deinit(db.allocator);
    }

    {
        var q = try Query.init(db, discover_sql);
        defer q.deinit();

        try q.bindTextStatic(protocol_str);
        try q.bindText(main_registry);

        // Register newly discovered subregistries and track them.
        // `first_seen_block` is the subregistry's actual creation block
        // (from registries.created_block), which may predate the current
        // batch by many blocks — PR #66 dropped the created_block window
        // filter so late discoveries are now possible. `last_indexed_block`
        // is set to the creation block as well: we have NOT yet indexed
        // any events emitted by this subregistry, but events can only
        // exist from created_block onward, so this is the correct lower
        // bound. The follow-up `backfillSubregistryEvents` call will
        // advance the checkpoint after the bulk backfill completes.
        while (try q.step()) {
            if (q.getTextSlice(0)) |addr_slice| {
                const created_block: u64 = @intCast(q.getInt64(1));
                try db.registerSubregistry(protocol, addr_slice, created_block, created_block);
                const copy = try db.allocator.dupe(u8, addr_slice);
                try new_subregistries.append(db.allocator, copy);
            }
        }
    }

    // Now get ALL known subregistries from cache (very fast)
    const get_sql =
        \\SELECT address FROM known_subregistries
        \\WHERE protocol = ?
        \\ORDER BY address
    ;

    var q2 = try Query.init(db, get_sql);
    defer q2.deinit();

    try q2.bindTextStatic(protocol_str);

    var subregistries: std.ArrayList([]u8) = .empty;
    errdefer {
        for (subregistries.items) |subreg| {
            db.allocator.free(subreg);
        }
        subregistries.deinit(db.allocator);
    }

    while (try q2.step()) {
        if (try q2.getText(0)) |addr| {
            try subregistries.append(db.allocator, addr);
        }
    }

    return .{
        .all = try subregistries.toOwnedSlice(db.allocator),
        .newly_discovered = try new_subregistries.toOwnedSlice(db.allocator),
    };
}

/// Delete all data after a specific block (for clean re-indexing)
pub fn deleteDataAfterBlock(db: *Database, block_number: u64) !void {
    std.log.info("Deleting data after block {d}...", .{block_number});

    // Tables to clean, with the block column that dates each row. Kept in sync with
    // rollbackToBlock's coverage so --clean is clean-at-N equivalent for ALL protocols
    // (no protocol filter here — the replayUndo above ran for both v1 and v2).
    const tables = [_]struct { name: []const u8, block_col: []const u8 }{
        .{ .name = "names", .block_col = "created_block" },
        .{ .name = "registries", .block_col = "created_block" },
        .{ .name = "events", .block_col = "block_number" },
        .{ .name = "block_hashes", .block_col = "block_number" },
        .{ .name = "orphaned_registrations", .block_col = "block_number" },
        .{ .name = "approvals", .block_col = "block_number" },
        .{ .name = "eac_roles", .block_col = "block_number" },
        .{ .name = "registrations", .block_col = "block_number" },
        .{ .name = "registry_entries", .block_col = "updated_block" },
        .{ .name = "reverse_records", .block_col = "block_number" },
        .{ .name = "resolvers", .block_col = "set_block" },
        .{ .name = "name_history", .block_col = "block_number" },
        .{ .name = "accounts", .block_col = "first_seen_block" },
        .{ .name = "resolver_addresses", .block_col = "block_number" },
        .{ .name = "resolver_contenthashes", .block_col = "block_number" },
        .{ .name = "resolver_texts", .block_col = "block_number" },
        .{ .name = "resolver_aliases", .block_col = "block_number" },
        .{ .name = "resolver_pubkeys", .block_col = "block_number" },
        .{ .name = "resolver_abis", .block_col = "block_number" },
        .{ .name = "resolver_names", .block_col = "block_number" },
        .{ .name = "resolver_interfaces", .block_col = "block_number" },
        .{ .name = "resolver_versions", .block_col = "block_number" },
        .{ .name = "resolver_metadata", .block_col = "block_number" },
        .{ .name = "resolver_approvals", .block_col = "block_number" },
        .{ .name = "resolver_dns_records", .block_col = "block_number" },
        .{ .name = "resolver_dns_zonehashes", .block_col = "block_number" },
        .{ .name = "resolver_authorisations", .block_col = "block_number" },
    };

    // Begin transaction for atomic cleanup. The Tx guard rolls back on any
    // early-error return; commit() below seals it.
    var tx = try db_module.Tx.begin(db, .deferred);
    defer tx.deinit();

    // Reverse in-place mutations after the block for BOTH protocols (this path is
    // protocol-agnostic), so --clean is clean-at-N equivalent and no stale undo
    // entries survive. Clear cursors first so the restore writes don't self-capture.
    inline for ([_]models.Protocol{ .v1, .v2 }) |proto| {
        try reorg_undo.clearCursor(db, proto);
        try reorg_undo.replayUndo(db, proto, block_number);
    }

    for (tables) |table| {
        const sql = try std.fmt.allocPrint(
            db.allocator,
            "DELETE FROM {s} WHERE {s} > ?",
            .{ table.name, table.block_col },
        );
        defer db.allocator.free(sql);

        var q = try Query.init(db, sql);
        defer q.deinit();

        try q.bindInt64(@intCast(block_number));
        try q.exec();

        const deleted = q.changes();
        if (deleted > 0) {
            std.log.info("  Deleted {d} rows from {s}", .{ deleted, table.name });
        }
    }

    // v1_controllers is wound back by the replayUndo calls above (reorg_active undo-log,
    // both protocols) — no explicit column-predicate cleanup needed.

    // Resolution cache: drop derived answers pinned above the target block (chain-
    // scoped; protocol-agnostic like this whole path). Self-heals on the next read.
    {
        var cq = try Query.init(db, "DELETE FROM resolution_cache WHERE chain_id = ? AND block_dep_num > ?");
        defer cq.deinit();
        try cq.bindInt64(@intCast(db.chain_id));
        try cq.bindInt64(@intCast(block_number));
        try cq.exec();
    }

    // Commit transaction
    try tx.commit();
    std.log.info("Data cleanup complete", .{});
}

// ============================================================================
// ORPHANED REGISTRATIONS
// ============================================================================

/// Orphaned registration data - NameRegistered events skipped due to no parent
pub const OrphanedRegistration = struct {
    protocol: models.Protocol,
    subregistry_address: []const u8,
    token_id: u256,
    label: []const u8,
    expiry: u64,
    owner: Address,
    block_number: u64,
    tx_hash: Hash,
    log_index: u32,

    pub fn deinit(self: *OrphanedRegistration, allocator: std.mem.Allocator) void {
        allocator.free(self.subregistry_address);
        allocator.free(self.label);
    }
};

/// Store an orphaned NameRegistered event for later processing
pub fn insertOrphanedRegistration(
    db: *Database,
    protocol: models.Protocol,
    subregistry_address: []const u8,
    token_id: u256,
    label: []const u8,
    expiry: u64,
    owner: Address,
    block_number: u64,
    tx_hash: Hash,
    log_index: u32,
) !void {
    const sql = try db.upsertSql(db.allocator, "orphaned_registrations", &.{ "protocol", "subregistry_address", "token_id", "label", "expiry", "owner", "block_number", "tx_hash", "log_index", "created_at" }, .ignore);
    defer db.allocator.free(sql);

    var q = try Query.init(db, sql);
    defer q.deinit();

    const token_id_str = try std.fmt.allocPrint(db.allocator, "0x{x:0>64}", .{token_id});
    defer db.allocator.free(token_id_str);

    try q.bindTextStatic(protocol.toString());
    try q.bindText(subregistry_address);
    try q.bindText(token_id_str);
    try q.bindText(label);
    try q.bindInt64(safeU64ToI64(expiry));
    try q.bindAddress(owner);
    try q.bindInt64(@intCast(block_number));
    try q.bindHash(tx_hash);
    try q.bindInt(@intCast(log_index));
    try q.bindInt64(zsys.timestamp());

    try q.exec();
}

/// Get orphaned registrations for a subregistry address
pub fn getOrphanedRegistrations(db: *Database, protocol: models.Protocol, subregistry_address: []const u8) ![]OrphanedRegistration {
    const sql =
        \\SELECT protocol, subregistry_address, token_id, label, expiry, owner, block_number, tx_hash, log_index
        \\FROM orphaned_registrations
        \\WHERE protocol = ? AND subregistry_address = ?
        \\ORDER BY block_number ASC
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());
    try q.bindText(subregistry_address);

    var results: std.ArrayList(OrphanedRegistration) = .empty;
    errdefer {
        for (results.items) |*item| {
            item.deinit(db.allocator);
        }
        results.deinit(db.allocator);
    }

    while (try q.step()) {
        const protocol_str = q.getTextSlice(0) orelse continue;
        const addr_str = q.getTextSlice(1) orelse continue;
        const token_id_str = q.getTextSlice(2) orelse continue;
        const label_str = q.getTextSlice(3) orelse continue;
        const owner_str = q.getTextSlice(5) orelse continue;
        const tx_hash_str = q.getTextSlice(7) orelse continue;

        // Parse token_id from hex
        const token_id_clean = if (std.mem.startsWith(u8, token_id_str, "0x")) token_id_str[2..] else token_id_str;
        const token_id = std.fmt.parseInt(u256, token_id_clean, 16) catch continue;

        try results.append(db.allocator, .{
            .protocol = models.Protocol.fromString(protocol_str) catch continue,
            .subregistry_address = try db.allocator.dupe(u8, addr_str),
            .token_id = token_id,
            .label = try db.allocator.dupe(u8, label_str),
            .expiry = @bitCast(q.getInt64(4)),
            .owner = Address.fromHex(owner_str) catch continue,
            .block_number = @intCast(q.getInt64(6)),
            .tx_hash = Hash.fromHex(tx_hash_str) catch continue,
            .log_index = @intCast(q.getInt(8)),
        });
    }

    return results.toOwnedSlice(db.allocator);
}

/// Delete orphaned registrations after they've been processed
pub fn deleteOrphanedRegistrations(db: *Database, protocol: models.Protocol, subregistry_address: []const u8) !void {
    try reorg_undo.captureWhere(db, "orphaned_registrations", "D", "protocol = ? AND subregistry_address = ?", .{ protocol, subregistry_address });
    const sql = "DELETE FROM orphaned_registrations WHERE protocol = ? AND subregistry_address = ?";

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());
    try q.bindText(subregistry_address);

    try q.exec();
}

test "registerSubregistriesBatch matches the per-row writer: MAX merge, first_seen preserved, chunk boundary" {
    const testing = std.testing;
    var db = try Database.init(testing.allocator, ":memory:");
    defer db.deinit();

    // Enough addresses to cross the 150-row chunk boundary, so the multi-statement path is the
    // one under test rather than a single convenient statement.
    const total: usize = 160;
    var store: [total][42]u8 = undefined;
    var addrs: [total][]const u8 = undefined;
    for (0..total) |i| {
        var a = Address{ .bytes = [_]u8{0} ** 20 };
        a.bytes[19] = @intCast(i % 256);
        a.bytes[18] = @intCast(i / 256);
        addrs[i] = a.toHexBuf(&store[i]);
    }

    // Discovery seeds first_seen_block with the real created_block, one row at a time.
    for (addrs, 0..) |hex, i| {
        try registerSubregistry(&db, .v2, hex, 1000 + i, 1000 + i);
    }

    // The per-batch advance. first_seen_block must be UNTOUCHED (ignored on conflict) and
    // last_indexed_block must move to the new head.
    try registerSubregistriesBatch(&db, .v2, &addrs, 5000);
    {
        var q = try Query.init(&db, "SELECT count(*), min(first_seen_block), max(first_seen_block), min(last_indexed_block), max(last_indexed_block) FROM known_subregistries WHERE protocol = 'v2'");
        defer q.deinit();
        try testing.expect(try q.step());
        try testing.expectEqual(@as(i64, @intCast(total)), q.getInt64(0));
        try testing.expectEqual(@as(i64, 1000), q.getInt64(1));
        try testing.expectEqual(@as(i64, 1000 + @as(i64, @intCast(total)) - 1), q.getInt64(2));
        try testing.expectEqual(@as(i64, 5000), q.getInt64(3));
        try testing.expectEqual(@as(i64, 5000), q.getInt64(4));
    }

    // A LOWER head must not regress the checkpoint — the merge is MAX/GREATEST, so replaying an
    // older batch is harmless and the result does not depend on batch order.
    try registerSubregistriesBatch(&db, .v2, &addrs, 4000);
    {
        var q = try Query.init(&db, "SELECT min(last_indexed_block) FROM known_subregistries WHERE protocol = 'v2'");
        defer q.deinit();
        try testing.expect(try q.step());
        try testing.expectEqual(@as(i64, 5000), q.getInt64(0));
    }

    // And it is protocol-scoped: v1 rows are untouched by a v2 advance.
    try registerSubregistry(&db, .v1, addrs[0], 10, 10);
    try registerSubregistriesBatch(&db, .v2, &addrs, 6000);
    {
        var q = try Query.init(&db, "SELECT last_indexed_block FROM known_subregistries WHERE protocol = 'v1'");
        defer q.deinit();
        try testing.expect(try q.step());
        try testing.expectEqual(@as(i64, 10), q.getInt64(0));
    }
}

test "isKnownResolver is protocol-scoped and requires registration" {
    const testing = std.testing;
    var db = try Database.init(testing.allocator, ":memory:");
    defer db.deinit();

    const r = Address{ .bytes = [_]u8{0x77} ** 20 };
    try testing.expect(!(try isKnownResolver(&db, .v2, r)));

    const hex = try r.toHex(testing.allocator);
    defer testing.allocator.free(hex);
    try registerResolver(&db, .v2, hex, 100);

    try testing.expect(try isKnownResolver(&db, .v2, r));
    try testing.expect(!(try isKnownResolver(&db, .v1, r)));
}
