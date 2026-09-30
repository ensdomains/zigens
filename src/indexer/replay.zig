/// Replay module — rebuilds the `names` table from stored events.
///
/// Used by `--backfill` CLI mode: clears names, replays all events in order,
/// and re-derives name records using the same storage functions as live indexing.
const std = @import("std");
const zsys = @import("../utils/system.zig");
const ens_name = @import("../utils/ens_name.zig");
const constants = @import("../constants.zig");
const db_module = @import("../storage/database.zig");
const Query = db_module.Query;
const Hash = @import("../types/hash.zig").Hash;
const Address = @import("../types/address.zig").Address;
const models = @import("../types/models.zig");
const names_storage = @import("../storage/names.zig");
const v1_names = @import("../utils/v1_names.zig");
const Indexer = @import("indexer.zig").Indexer;
const utils = @import("utils.zig");
const reorg_undo = @import("../storage/reorg_undo.zig");
const alias_sync = @import("v2/alias_sync.zig");

const Keccak256 = std.crypto.hash.sha3.Keccak256;

/// Commit interval: flush transaction every N events
const COMMIT_INTERVAL: u64 = 100_000;

/// The replay SQL query — extracts fields from JSON in SQL to avoid per-row JSON parsing in Zig.
const REPLAY_SQL =
    \\SELECT event_type, protocol, block_number, tx_hash, log_index,
    \\       contract_address, name, namehash, timestamp, data
    \\FROM events WHERE protocol = 'v1'
    \\ORDER BY block_number ASC, log_index ASC
;

// Column indices for the replay query. JSON fields are parsed from the raw `data` column in
// Zig (jsonString/jsonU256/jsonU64) — Postgres-portable, and lossless for the u256 tokenId/id
// that SQLite json_extract would f64-corrupt.
const COL_EVENT_TYPE = 0;
const COL_CHAIN = 1;
const COL_BLOCK_NUMBER = 2;
const COL_TX_HASH = 3;
const COL_LOG_INDEX = 4;
const COL_CONTRACT_ADDRESS = 5;
const COL_NAME = 6;
const COL_NAMEHASH = 7;
const COL_TIMESTAMP = 8;
const COL_DATA = 9;

/// Replay all stored events to rebuild the names table from scratch.
pub fn replayEventsToRebuildNames(self: *Indexer) !void {
    const database = self.database;

    // ── Step 1: Ensure events indexes exist (needed for the replay query ORDER BY) ──
    std.log.info("Ensuring events indexes exist for replay query...", .{});
    try database.exec("CREATE INDEX IF NOT EXISTS idx_events_protocol ON events(protocol)");
    try database.exec("CREATE INDEX IF NOT EXISTS idx_events_block_log ON events(block_number, log_index)");

    // ── Step 2: Count total events (fast with index) ──
    const total_events = blk: {
        var cq = try Query.init(database, "SELECT COUNT(*) FROM events WHERE protocol = 'v1'");
        defer cq.deinit();
        if (try cq.step()) {
            break :blk @as(u64, @intCast(cq.getInt64(0)));
        }
        break :blk @as(u64, 0);
    };
    std.log.info("Replay: {d} events to process", .{total_events});

    // ── Step 3: Drop ONLY names indexes for bulk insert speed (keep events indexes!) ──
    std.log.info("Dropping names indexes for bulk replay...", .{});
    try dropNamesIndexes(database);

    // ── Step 5: Clear names + backfill_status ──
    // DELETE, not DROP+CREATE: the canonical names schema lives only in
    // schema/schema.sql (and its generated Postgres twin). A hand-maintained
    // CREATE TABLE copy here drifts — it has already silently lost columns
    // (the generated `expiry_effective` among them), and insertName binds
    // against the live schema, so a missing column breaks every replay insert
    // or, for a generated column, leaves queries referencing a column the
    // rebuilt table lacks. Clearing rows keeps the real table — every column,
    // its generated columns, indexes, and UNIQUE(protocol, namehash) (which
    // insertName's upsert needs). Bulk-load speed is preserved by the
    // dropNamesIndexes/createNamesIndexes pair below.
    //
    // A full names rebuild also invalidates the reorg undo-log, and the AFTER
    // UPDATE/DELETE triggers on `names` (a protected table) would otherwise
    // self-capture the entire rebuild into reorg_undo at the stale live cursor —
    // DELETE keeps the triggers live (unlike the old DROP). Clear the cursor/active
    // context + undo log first so the triggers no-op and no stale entries survive.
    try database.exec("DELETE FROM reorg_cursor");
    try database.exec("DELETE FROM reorg_active");
    try database.exec("DELETE FROM reorg_undo");

    // Scope the clear to V1: this replay rebuilds only protocol='v1' rows, so a combined
    // database's V2 name records must survive (they are disjoint by the protocol column).
    std.log.info("Clearing V1 names...", .{});
    try database.exec("DELETE FROM names WHERE protocol = 'v1'");
    try database.exec("DELETE FROM backfill_status");

    // ── Step 5: Bulk-load v1_labels into the in-memory cache ──
    std.log.info("Loading v1_labels into cache...", .{});
    {
        var lq = try Query.init(database, "SELECT token_id, label FROM v1_labels");
        defer lq.deinit();
        var label_count: u64 = 0;
        while (try lq.step()) {
            const token_id = lq.getTextSlice(0) orelse continue;
            const label = lq.getTextSlice(1) orelse continue;
            try self.putCachedV1Label(token_id, label);
            label_count += 1;
        }
        std.log.info("Loaded {d} v1_labels into cache", .{label_count});
    }

    // ── Step 6: Replay loop ──
    // We use a single transaction (no intermediate commits) because SQLite invalidates
    // cursors on COMMIT. WAL mode handles the large transaction gracefully.
    std.log.info("Starting event replay...", .{});
    try database.beginTransaction();

    var q = try Query.init(database, REPLAY_SQL);

    var processed: u64 = 0;
    var errors: u64 = 0;
    const start_time = zsys.milliTimestamp();

    while (try q.step()) {
        replayOneEvent(self, &q) catch |err| {
            errors += 1;
            if (errors <= 20) {
                const et = q.getTextSlice(COL_EVENT_TYPE) orelse "?";
                const bn = q.getInt64(COL_BLOCK_NUMBER);
                std.log.warn("Replay error at block {d} event={s}: {}", .{ bn, et, err });
            }
        };

        processed += 1;
        if (processed % COMMIT_INTERVAL == 0) {
            const elapsed_s = @divFloor(zsys.milliTimestamp() - start_time, 1000);
            const rate = if (elapsed_s > 0) @divFloor(processed, @as(u64, @intCast(elapsed_s))) else processed;
            const pct = if (total_events > 0) @divFloor(processed * 100, total_events) else 100;
            std.log.info("Replay progress: {d}/{d} ({d}%) — {d} events/s — {d} errors", .{
                processed, total_events, pct, rate, errors,
            });
        }
    }

    q.deinit();
    try database.commitTransaction();
    const elapsed_s = @divFloor(zsys.milliTimestamp() - start_time, 1000);
    std.log.info("Replay complete: {d} events processed, {d} errors, {d}s elapsed", .{
        processed, errors, elapsed_s,
    });

    // ── Step 7: Recreate names indexes ──
    std.log.info("Recreating names indexes...", .{});
    try createNamesIndexes(database);

    // Ensure reorg undo-log triggers are installed (idempotent / first-run table
    // creation). The bulk rebuild above captured nothing because step 5 cleared the
    // cursor + active context before touching `names` (the triggers stay live now
    // that we DELETE rather than DROP the table).
    try reorg_undo.installTriggers(database);

    // ── Step 8: Post-replay backfill passes ──
    // These are SQLite-tuned V1 enrichment passes (v1_labels joins, json_extract event
    // lookups, cursor-in-cursor writes) — not portable to Postgres, and a V2-only Postgres
    // deployment has no V1 data for them to touch. Skip them on Postgres; the core V1 replay
    // loop above is backend-agnostic.
    if (database.isPostgres()) {
        std.log.info("Skipping V1 post-replay backfill passes on Postgres (no V1 data on a V2 deployment)", .{});
    } else {
        std.log.info("Running post-replay backfill passes...", .{});

        const backfill_mod = @import("v1/backfill.zig");

        // 7a: Pre-migration names (joins temp_pre_migration_names + v1_labels)
        backfill_mod.backfillPreMigrationNames(self) catch |err| {
            std.log.warn("backfillPreMigrationNames failed: {}", .{err});
        };

        // 7b: Unknown labels (requires RPC, may not be available)
        backfill_mod.backfillUnknownLabels(self) catch |err| {
            std.log.warn("backfillUnknownLabels failed (RPC may be unavailable): {}", .{err});
        };

        // 7c: Missing .eth 2LD names
        backfill_mod.backfillMissingEth2LDNames(self) catch |err| {
            std.log.warn("backfillMissingEth2LDNames failed: {}", .{err});
        };

        // 7d: PCC fuse → Domain.expiry mirror. The replay wrapper handlers write
        // only wrapper_* fields, so without this pass wrapped-but-never-renewed
        // .eth 2LDs would end replay with bare expiry — which the wrapped read
        // path serves as-is, 90d short. The live indexer only runs it at
        // initial-sync completion, which an API-only deployment never reaches.
        self.materializePccUncaptured();
    }

    // ── Summary ──
    const name_count = blk: {
        var ncq = try Query.init(database, "SELECT COUNT(*) FROM names");
        defer ncq.deinit();
        if (try ncq.step()) {
            break :blk @as(u64, @intCast(ncq.getInt64(0)));
        }
        break :blk @as(u64, 0);
    };
    std.log.info("Backfill complete: {d} name records in database", .{name_count});

    // Clean up allocator-heavy caches before exiting
    self.clearBlockTimestampCache();
}

// ============================================================================
// DISPATCH
// ============================================================================

/// Dispatch a single replayed event row based on contract_address + event_type + JSON keys.
fn replayOneEvent(self: *Indexer, q: *Query) !void {
    const event_type_str = q.getTextSlice(COL_EVENT_TYPE) orelse return;
    const contract_str = q.getTextSlice(COL_CONTRACT_ADDRESS) orelse return;

    const contract = try Address.fromHex(contract_str);
    const data = q.getTextSlice(COL_DATA) orelse return;

    const cfg = self.config.v1_contracts;

    // ── Registry events ──
    if (contract.eql(cfg.ens_registry)) {
        if (std.mem.eql(u8, event_type_str, "transfer")) {
            // Discriminate NewOwner (parentNode present) vs RegistryTransfer (node present)
            if (jsonRawValue(data, "parentNode") != null) {
                try replayNewOwner(self, q);
            } else if (jsonRawValue(data, "node") != null) {
                try replayRegistryTransfer(self, q);
            }
        } else if (std.mem.eql(u8, event_type_str, "resolver_update")) {
            if (jsonRawValue(data, "resolver") != null) {
                try replayNewResolver(self, q);
            }
        }
        return;
    }

    // ── Base Registrar events ──
    if (contract.eql(cfg.base_registrar)) {
        if (std.mem.eql(u8, event_type_str, "transfer")) {
            try replayERC721Transfer(self, q);
        } else if (std.mem.eql(u8, event_type_str, "name_registered")) {
            try replayBaseRegistrarNameReg(self, q);
        } else if (std.mem.eql(u8, event_type_str, "name_renewed")) {
            try replayBaseRegistrarRenewal(self, q);
        }
        return;
    }

    // ── Name Wrapper events ──
    if (contract.eql(cfg.name_wrapper)) {
        if (std.mem.eql(u8, event_type_str, "transfer")) {
            // NameWrapped has fuses; NameUnwrapped does not
            if (jsonRawValue(data, "fuses") != null) {
                try replayNameWrapped(self, q);
            } else {
                try replayNameUnwrapped(self, q);
            }
        } else if (std.mem.eql(u8, event_type_str, "resolver_update")) {
            if (jsonRawValue(data, "fuses") != null) {
                try replayFusesSet(self, q);
            }
        } else if (std.mem.eql(u8, event_type_str, "name_renewed")) {
            if (jsonRawValue(data, "node") != null) {
                try replayExpiryExtended(self, q);
            }
        }
        return;
    }

    // ── ETH Controller events ──
    if (contract.eql(cfg.eth_registrar_controller)) {
        if (std.mem.eql(u8, event_type_str, "name_registered")) {
            try replayETHControllerNameReg(self, q);
        }
        // NameRenewed from controller is a no-op (expiry updated by BaseRegistrar event)
        return;
    }

    // ── Reverse Registrar — skip (doesn't modify names) ──
    // ── Unknown contracts — skip ──
}

// ============================================================================
// INDIVIDUAL REPLAY HANDLERS
// ============================================================================

/// Replay NewOwner: create subdomain name record.
/// Mirrors handleV1NewOwner logic (addr.reverse → rainbow → [labelhash]).
fn replayNewOwner(self: *Indexer, q: *Query) !void {
    const data = q.getTextSlice(COL_DATA) orelse return;
    const parent_hex = jsonString(data, "parentNode") orelse return;
    const labelhash_hex = jsonString(data, "labelhash") orelse return;
    const owner_hex = jsonString(data, "owner") orelse return;
    const block_number: u64 = @intCast(q.getInt64(COL_BLOCK_NUMBER));
    const timestamp = q.getInt64(COL_TIMESTAMP);

    const parent_node = try Hash.fromHex(parent_hex);
    const labelhash = try Hash.fromHex(labelhash_hex);
    const owner = try Address.fromHex(owner_hex);

    // Compute subdomain namehash: keccak256(parent_node ++ labelhash)
    var subdomain_input: [64]u8 = undefined;
    @memcpy(subdomain_input[0..32], &parent_node.bytes);
    @memcpy(subdomain_input[32..64], &labelhash.bytes);
    var subdomain_bytes: [32]u8 = undefined;
    Keccak256.hash(&subdomain_input, &subdomain_bytes, .{});
    const subdomain_namehash = Hash{ .bytes = subdomain_bytes };

    // Skip pre-migration .eth 2LDs (handled by backfillPreMigrationNames)
    const v1_migration_block = self.config.v1_contracts.v1_migration_block;
    if (v1_migration_block > 0 and block_number < v1_migration_block) return;

    // .eth 2LDs are handled by BaseRegistrar NameRegistered — skip
    if (parent_node.eql(self.root_node)) return;

    // Resolve label: addr.reverse → rainbow → [labelhash]
    var resolved_label: ?[]const u8 = null;
    var label_is_allocated = false;
    defer if (label_is_allocated) {
        if (resolved_label) |l| self.allocator.free(l);
    };

    // Strategy 1: addr.reverse subnames
    if (parent_node.eql(constants.WellKnown.reverse_namehash)) {
        if (owner_hex.len >= 2) {
            const addr_str = if (std.mem.startsWith(u8, owner_hex, "0x")) owner_hex[2..] else owner_hex;
            if (addr_str.len == 40) {
                var lower_addr: [40]u8 = undefined;
                for (addr_str, 0..) |ch, idx| {
                    lower_addr[idx] = if (ch >= 'A' and ch <= 'F') ch + 32 else ch;
                }
                var hash_result: [32]u8 = undefined;
                Keccak256.hash(&lower_addr, &hash_result, .{});
                if (std.mem.eql(u8, &hash_result, &labelhash.bytes)) {
                    resolved_label = try self.allocator.dupe(u8, &lower_addr);
                    label_is_allocated = true;
                }
            }
        }
    }

    // Strategy 2: Rainbow table
    if (resolved_label == null) {
        if (self.resolveLabel(labelhash)) |rainbow_label| {
            resolved_label = rainbow_label;
            label_is_allocated = false; // borrowed from rainbow_cache
        }
    }

    // Build label string
    var label_buf: [66]u8 = undefined;
    const labelhash_no_prefix = if (std.mem.startsWith(u8, labelhash_hex, "0x")) labelhash_hex[2..] else labelhash_hex;
    const label_str = if (resolved_label) |l| l else blk: {
        label_buf[0] = '[';
        const copy_len = @min(labelhash_no_prefix.len, 64);
        @memcpy(label_buf[1 .. 1 + copy_len], labelhash_no_prefix[0..copy_len]);
        label_buf[1 + copy_len] = ']';
        break :blk label_buf[0 .. 2 + copy_len];
    };

    // Look up parent name
    var parent_name_str: ?[]const u8 = null;
    var parent_record_to_free: ?models.Name = null;
    defer if (parent_record_to_free) |*pr| pr.deinit(self.allocator);

    if (parent_node.eql(constants.WellKnown.root_namehash)) {
        parent_name_str = null;
    } else if (try names_storage.getNameByNamehash(self.database, parent_node)) |parent_record| {
        parent_record_to_free = parent_record;
        parent_name_str = parent_record.name;
    }

    const full_name = try ens_name.join(self.allocator, label_str, parent_name_str);
    defer self.allocator.free(full_name);

    // Create or update
    if (try names_storage.getNameByNamehash(self.database, subdomain_namehash)) |existing| {
        var existing_mut = existing;
        existing_mut.deinit(self.allocator);
        try names_storage.updateNameOwner(self.database, .v1, subdomain_namehash, owner);
    } else {
        const registry = self.config.v1_contracts.ens_registry;

        const name_copy = try self.allocator.dupe(u8, full_name);
        const label_copy = try self.allocator.dupe(u8, label_str);
        // Root parent is the empty string, never null. See ens_name.ROOT_PARENT.
        const parent_copy = try self.allocator.dupe(u8, parent_name_str orelse ens_name.ROOT_PARENT);

        var name = models.Name{
            .protocol = .v1,
            .name = name_copy,
            .namehash = subdomain_namehash,
            .label = label_copy,
            .label_hash = labelhash,
            .parent_name = parent_copy,
            .parent_namehash = parent_node,
            .registry = registry,
            .owner = owner,
            .registrant = owner,
            .resolver = Address.zero,
            .token_id = 0,
            // Parity with the live handler (handleV1NewOwner): V1 rows have no
            // version bits, so the namehash is the canonical_id — replaying 0
            // here would make canonical_id lookups ambiguous after a --backfill.
            .canonical_id = std.mem.readInt(u256, &subdomain_namehash.bytes, .big),
            .token_version = 0,
            .expiry = 0,
            .registry_locked = false,
            .migrated = false,
            .created_block = block_number,
            .created_at = timestamp,
            .registered_at = timestamp,
            .updated_block = block_number,
            .updated_at = timestamp,
            .is_wrapped = false,
            .wrapper_fuses = null,
            .wrapper_expiry = null,
            .is_v1_name = true,
            .v1_label_hash = null,
        };
        defer name.deinit(self.allocator);

        self.insertName(name) catch |err| {
            std.log.debug("Failed to create subdomain name {s}: {}", .{ full_name, err });
        };
    }
}

/// Replay RegistryTransfer: update owner by namehash.
fn replayRegistryTransfer(self: *Indexer, q: *Query) !void {
    const data = q.getTextSlice(COL_DATA) orelse return;
    const node_hex = jsonString(data, "node") orelse return;
    const owner_hex = jsonString(data, "owner") orelse return;

    const node = try Hash.fromHex(node_hex);
    const owner = try Address.fromHex(owner_hex);

    names_storage.updateNameOwner(self.database, .v1, node, owner) catch {};
}

/// Replay NewResolver: update resolver by namehash.
fn replayNewResolver(self: *Indexer, q: *Query) !void {
    const data = q.getTextSlice(COL_DATA) orelse return;
    const node_hex = jsonString(data, "node") orelse return;
    const resolver_hex = jsonString(data, "resolver") orelse return;

    const node = try Hash.fromHex(node_hex);
    const resolver = try Address.fromHex(resolver_hex);

    names_storage.updateNameResolver(self.database, .v1, node, resolver) catch {};
}

/// Replay ERC721Transfer: look up label by tokenId, update owner.
fn replayERC721Transfer(self: *Indexer, q: *Query) !void {
    const data = q.getTextSlice(COL_DATA) orelse return;
    const to_hex = jsonString(data, "to") orelse return;
    const token_id = jsonU256(data, "tokenId") orelse return;

    const to = try Address.fromHex(to_hex);

    // Lossless u256 cache key (json_extract f64-corrupts large tokenIds).
    const token_id_hex = tokenIdKey(self.allocator, token_id) catch return;
    defer self.allocator.free(token_id_hex);

    // Look up label from cache
    if (try self.getCachedV1Label(token_id_hex)) |label| {
        const namehash = v1_names.computeChildNamehash(self.root_node, label);
        names_storage.updateNameOwner(self.database, .v1, namehash, to) catch {};
    }
    // If label not found, skip (same as live indexing)
}

/// Replay BaseRegistrar NameRegistered: create .eth 2LD name.
fn replayBaseRegistrarNameReg(self: *Indexer, q: *Query) !void {
    const data = q.getTextSlice(COL_DATA) orelse return;
    const id = jsonU256(data, "id") orelse return;
    const owner_hex = jsonString(data, "owner") orelse return;
    const block_number: u64 = @intCast(q.getInt64(COL_BLOCK_NUMBER));
    const timestamp = q.getInt64(COL_TIMESTAMP);

    const owner = try Address.fromHex(owner_hex);

    const expires: u64 = jsonU64(data, "expires") orelse 0;

    // Lossless u256 cache key (json_extract f64-corrupts large ids).
    const token_id_hex = tokenIdKey(self.allocator, id) catch return;
    defer self.allocator.free(token_id_hex);

    // Look up label from cache
    const maybe_label = try self.getCachedV1Label(token_id_hex);

    if (maybe_label) |label| {
        const full_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ label, self.root_name });
        const namehash = v1_names.computeChildNamehash(self.root_node, label);
        const label_hash = v1_names.computeLabelHash(label);
        const eth_node = self.root_node;

        var label_hash_buf: [66]u8 = undefined;
        const v1_label_hash_hex = label_hash.toHexBuf(&label_hash_buf);

        const token_id_u256 = id;

        const name_record = models.Name{
            .name = full_name,
            .namehash = namehash,
            .label = label,
            .label_hash = label_hash,
            .parent_name = self.root_name,
            .parent_namehash = eth_node,
            .protocol = .v1,
            .registry = self.config.v1_contracts.ens_registry,
            .owner = owner,
            .registrant = owner,
            .resolver = Address.zero,
            .token_id = token_id_u256,
            .canonical_id = token_id_u256,
            .token_version = 0,
            .expiry = expires,
            .registry_locked = false,
            .migrated = false,
            .created_block = block_number,
            .created_at = timestamp,
            .registered_at = timestamp,
            .updated_block = block_number,
            .updated_at = timestamp,
            .is_wrapped = false,
            .wrapper_fuses = null,
            .wrapper_expiry = null,
            .is_v1_name = true,
            .v1_label_hash = v1_label_hash_hex,
        };

        self.insertName(name_record) catch |err| {
            std.log.debug("Failed to create .eth 2LD name {s}: {}", .{ full_name, err });
            self.allocator.free(full_name);
        };
    }
    // If label not found, skip — backfillMissingEth2LDNames will catch it
}

/// Replay BaseRegistrar NameRenewed: update expiry.
fn replayBaseRegistrarRenewal(self: *Indexer, q: *Query) !void {
    const data = q.getTextSlice(COL_DATA) orelse return;
    const id = jsonU256(data, "id") orelse return;
    const expires: u64 = jsonU64(data, "expires") orelse 0;

    const token_id_hex = tokenIdKey(self.allocator, id) catch return;
    defer self.allocator.free(token_id_hex);

    if (try self.getCachedV1Label(token_id_hex)) |label| {
        const namehash = v1_names.computeChildNamehash(self.root_node, label);
        names_storage.updateV1RenewalExpiry(self.database, namehash, expires) catch {};
    }
}

/// Replay NameWrapped: update wrapper state + owner.
fn replayNameWrapped(self: *Indexer, q: *Query) !void {
    const data = q.getTextSlice(COL_DATA) orelse return;
    const node_hex = jsonString(data, "node") orelse
        q.getTextSlice(COL_NAMEHASH) orelse return;
    const owner_hex = jsonString(data, "owner") orelse return;

    const node = try Hash.fromHex(node_hex);
    const owner = try Address.fromHex(owner_hex);
    const fuses: u32 = @truncate(jsonU256(data, "fuses") orelse return);
    const expiry: u64 = jsonU64(data, "expiry") orelse 0;

    names_storage.updateNameWrapperState(self.database, node, fuses, expiry) catch {};
    names_storage.updateNameOwner(self.database, .v1, node, owner) catch {};
}

/// Replay NameUnwrapped: clear wrapper state + update owner.
fn replayNameUnwrapped(self: *Indexer, q: *Query) !void {
    const data = q.getTextSlice(COL_DATA) orelse return;
    const node_hex = jsonString(data, "node") orelse
        q.getTextSlice(COL_NAMEHASH) orelse return;
    const owner_hex = jsonString(data, "owner") orelse return;

    const node = try Hash.fromHex(node_hex);
    const owner = try Address.fromHex(owner_hex);

    names_storage.updateNameUnwrapperState(self.database, node) catch {};
    names_storage.updateNameOwner(self.database, .v1, node, owner) catch {};
}

/// Replay FusesSet: update wrapper fuses.
fn replayFusesSet(self: *Indexer, q: *Query) !void {
    const data = q.getTextSlice(COL_DATA) orelse return;
    const node_hex = jsonString(data, "node") orelse
        q.getTextSlice(COL_NAMEHASH) orelse return;

    const node = try Hash.fromHex(node_hex);
    const fuses: u32 = @truncate(jsonU256(data, "fuses") orelse return);

    names_storage.updateNameWrapperFuses(self.database, node, fuses) catch {};
}

/// Replay ExpiryExtended: update wrapper expiry.
fn replayExpiryExtended(self: *Indexer, q: *Query) !void {
    const data = q.getTextSlice(COL_DATA) orelse return;
    const node_hex = jsonString(data, "node") orelse return;

    const node = try Hash.fromHex(node_hex);
    const expiry: u64 = jsonU64(data, "expiry") orelse return;

    names_storage.updateNameWrapperExpiry(self.database, node, expiry) catch {};
}

/// Replay ETH Controller NameRegistered: store label in v1_labels + cache.
fn replayETHControllerNameReg(self: *Indexer, q: *Query) !void {
    const data = q.getTextSlice(COL_DATA) orelse return;
    const name_str = jsonString(data, "name") orelse return;

    // Compute label hash from plaintext name (the JSON stores it as "label" key, not "labelhash")
    const label_hash = v1_names.computeLabelHash(name_str);
    var label_hash_buf: [66]u8 = undefined;
    const label_hash_hex = label_hash.toHexBuf(&label_hash_buf);

    const namehash = v1_names.computeChildNamehash(self.root_node, name_str);
    const block_number: u64 = @intCast(q.getInt64(COL_BLOCK_NUMBER));
    const tx_hash_hex = q.getTextSlice(COL_TX_HASH) orelse return;

    v1_names.storeTokenIdLabel(
        self.allocator,
        self.database,
        label_hash_hex,
        name_str,
        namehash,
        block_number,
        tx_hash_hex,
        "replay",
    ) catch {};

    // Also update cache
    self.putCachedV1Label(label_hash_hex, name_str) catch {};
}

// ============================================================================
// HELPERS
// ============================================================================

/// The 0x+64-hex cache key for a tokenId (the getCachedV1Label key format), from a
/// losslessly-parsed u256. json_extract would f64-corrupt a large id and silently miss the cache.
fn tokenIdKey(allocator: std.mem.Allocator, token_id: u256) ![]u8 {
    var bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &bytes, token_id, .big);
    return (Hash{ .bytes = bytes }).toHex(allocator);
}

/// Drop only names-related indexes (keep events indexes for the replay query).
fn dropNamesIndexes(database: *db_module.Database) !void {
    try database.exec("DROP INDEX IF EXISTS idx_names_protocol");
    try database.exec("DROP INDEX IF EXISTS idx_names_name");
    try database.exec("DROP INDEX IF EXISTS idx_names_label");
    try database.exec("DROP INDEX IF EXISTS idx_names_owner");
    try database.exec("DROP INDEX IF EXISTS idx_names_expiry");
    try database.exec("DROP INDEX IF EXISTS idx_names_registry");
    try database.exec("DROP INDEX IF EXISTS idx_names_resolver");
    try database.exec("DROP INDEX IF EXISTS idx_names_created_block");
    try database.exec("DROP INDEX IF EXISTS idx_names_registrant");
    try database.exec("DROP INDEX IF EXISTS idx_names_v1_label_hash");
    try database.exec("DROP INDEX IF EXISTS idx_names_parent_namehash");
    try database.exec("DROP INDEX IF EXISTS idx_names_is_wrapped");
    try database.exec("DROP INDEX IF EXISTS idx_names_is_v1_name");
    try database.exec("DROP INDEX IF EXISTS idx_names_wrapper_expiry");
}

/// Recreate only names-related indexes after bulk replay.
fn createNamesIndexes(database: *db_module.Database) !void {
    const timer = zsys.milliTimestamp();
    try database.exec("CREATE INDEX IF NOT EXISTS idx_names_protocol ON names(protocol)");
    try database.exec("CREATE INDEX IF NOT EXISTS idx_names_name ON names(name)");
    try database.exec("CREATE INDEX IF NOT EXISTS idx_names_label ON names(label)");
    try database.exec("CREATE INDEX IF NOT EXISTS idx_names_owner ON names(owner)");
    try database.exec("CREATE INDEX IF NOT EXISTS idx_names_expiry ON names(expiry)");
    try database.exec("CREATE INDEX IF NOT EXISTS idx_names_registry ON names(protocol, registry)");
    try database.exec("CREATE INDEX IF NOT EXISTS idx_names_resolver ON names(protocol, resolver)");
    try database.exec("CREATE INDEX IF NOT EXISTS idx_names_created_block ON names(protocol, created_block)");
    try database.exec("CREATE INDEX IF NOT EXISTS idx_names_registrant ON names(registrant)");
    try database.exec("CREATE INDEX IF NOT EXISTS idx_names_v1_label_hash ON names(v1_label_hash)");
    try database.exec("CREATE INDEX IF NOT EXISTS idx_names_parent_namehash ON names(parent_namehash)");
    try database.exec("CREATE INDEX IF NOT EXISTS idx_names_is_wrapped ON names(is_wrapped)");
    try database.exec("CREATE INDEX IF NOT EXISTS idx_names_is_v1_name ON names(is_v1_name)");
    try database.exec("CREATE INDEX IF NOT EXISTS idx_names_wrapper_expiry ON names(wrapper_expiry)");
    // Namehash lookup index — non-unique, matching schema/schema.sql (the real
    // key is UNIQUE(protocol, namehash); namehash alone repeats across protocols
    // for V1->V2 migrated names). No-op now that DELETE keeps the live indexes.
    try database.exec("CREATE INDEX IF NOT EXISTS idx_names_namehash ON names(namehash)");
    try database.exec("CREATE INDEX IF NOT EXISTS idx_names_token_id ON names(token_id)");
    try database.exec("CREATE INDEX IF NOT EXISTS idx_names_canonical_id ON names(canonical_id)");
    const elapsed = zsys.milliTimestamp() - timer;
    std.log.info("Names indexes created in {d}ms", .{elapsed});
}

// ============================================================================
// V2 NAMES REPLAY (Phase 3 increment 1)
// ============================================================================
//
// V2 events are replayable offline: the V2 handlers make no live RPC calls (the `rpc`
// import is only for the `rpc.Log` param type), and block timestamps come from the stored
// event row. Unlike the V1 REPLAY_SQL above, numeric fields are parsed from the RAW `data`
// text in Zig — SQLite's json_extract coerces a large integer (u256 tokenId, u64 expiry
// >= 2^53) to an f64 and silently corrupts it, so it must never touch these values.
//
// Increment 1 rebuilds `names` for MAIN-REGISTRY (.eth 2LD) names + all update/delete
// paths. Subregistry-parented names (whose parent must be looked up in the `registries`
// projection) and orphan/migration carry-over are a documented follow-on; this core is NOT
// yet wired into the destructive --backfill flow — the rebuild-equivalence test gates that.

const hash_mod2 = @import("../types/hash.zig");
const token_id_utils = @import("../types/token_id.zig");

const REPLAY_SQL_V2 =
    \\SELECT event_type, block_number, tx_hash, log_index, contract_address,
    \\       name, namehash, timestamp, data
    \\FROM events WHERE protocol = 'v2'
    \\ORDER BY block_number ASC, log_index ASC
;
const V2_EVENT_TYPE = 0;
const V2_BLOCK_NUMBER = 1;
const V2_TX_HASH = 2;
const V2_LOG_INDEX = 3;

const REPLAY_SQL_ACCOUNTS =
    \\SELECT protocol, event_type, block_number, timestamp, data
    \\FROM events
;
const ACC_PROTOCOL = 0;
const ACC_EVENT_TYPE = 1;
const ACC_BLOCK = 2;
const ACC_TS = 3;
const ACC_DATA = 4;
const V2_CONTRACT = 4;
const V2_NAME = 5;
const V2_NAMEHASH = 6;
const V2_TIMESTAMP = 7;
const V2_DATA = 8;

/// Locate the raw value token that follows `"key":` in COMPACT JSON (no spaces, as emitted
/// by the handlers). Requires the key to be preceded by `{` or `,` so a suffix key like
/// `tokenId` never matches inside `oldTokenId`/`newTokenId`. Returns the slice starting at
/// the value (caller interprets string vs number), or null if absent.
fn jsonRawValue(data: []const u8, key: []const u8) ?[]const u8 {
    var pat_buf: [64]u8 = undefined;
    if (key.len + 3 > pat_buf.len) return null;
    const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\":", .{key}) catch return null;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, data, i, pat)) |pos| {
        if (pos == 0 or data[pos - 1] == '{' or data[pos - 1] == ',') return data[pos + pat.len ..];
        i = pos + 1;
    }
    return null;
}

/// Extract a JSON string value `"key":"<value>"` (value has no escaped quotes in our data).
fn jsonString(data: []const u8, key: []const u8) ?[]const u8 {
    const rest = jsonRawValue(data, key) orelse return null;
    if (rest.len == 0 or rest[0] != '"') return null;
    const end = std.mem.indexOfScalar(u8, rest[1..], '"') orelse return null;
    return rest[1 .. 1 + end];
}

/// Extract a decimal integer value (bare `123` or quoted `"123"`) as u256 — lossless,
/// unlike json_extract. Null if absent/non-numeric.
fn jsonU256(data: []const u8, key: []const u8) ?u256 {
    var rest = jsonRawValue(data, key) orelse return null;
    if (rest.len > 0 and rest[0] == '"') rest = rest[1..];
    var n: usize = 0;
    while (n < rest.len and rest[n] >= '0' and rest[n] <= '9') n += 1;
    if (n == 0) return null;
    return std.fmt.parseInt(u256, rest[0..n], 10) catch null;
}

fn jsonU64(data: []const u8, key: []const u8) ?u64 {
    const v = jsonU256(data, key) orelse return null;
    if (v > std.math.maxInt(u64)) return @truncate(v);
    return @intCast(v);
}

/// Clear `names` for protocol v2 and rebuild it from the stored V2 event log. Does ONLY the
/// clear + replay loop (no V1 preload, no RPC/backfill post-passes), so it is unit-testable
/// and safe to compose after the V1 pass in a combined --backfill. Public for the
/// rebuild-equivalence test.
pub fn replayV2NamesCore(self: *Indexer) !void {
    const database = self.database;

    try database.exec("DELETE FROM reorg_cursor");
    try database.exec("DELETE FROM reorg_active");
    try database.exec("DELETE FROM reorg_undo");
    try database.exec("DELETE FROM names WHERE protocol = 'v2'");

    try database.beginTransaction();
    {
        var q = try Query.init(database, REPLAY_SQL_V2);
        defer q.deinit();
        while (try q.step()) {
            replayV2Event(self, &q) catch |err| {
                const et = q.getTextSlice(V2_EVENT_TYPE) orelse "?";
                std.log.warn("V2 replay error event={s}: {}", .{ et, err });
            };
        }
    }
    try database.commitTransaction();
}

fn v2Namehash(q: *Query) !?Hash {
    const h = q.getTextSlice(V2_NAMEHASH) orelse return null;
    return try Hash.fromHex(h);
}

fn replayV2Event(self: *Indexer, q: *Query) !void {
    const et = models.EventType.fromString(q.getTextSlice(V2_EVENT_TYPE) orelse return) orelse return;
    const data = q.getTextSlice(V2_DATA) orelse return;
    switch (et) {
        .label_registered => try replayV2LabelRegistered(self, q, data),
        .label_reserved => try replayV2LabelReserved(self, q, data),
        .transfer => {
            // Live keys ownership off (id, emitting registry) — handlers_registry's
            // handleTransfer via lookupPairedName — and deliberately does nothing when
            // that pair is unknown, because a tokenId collides across registries.
            // Replaying off the events row's namehash instead is not the same read:
            // that column is a denormalised copy, null on an orphaned transfer and
            // only later healed by the placeholder repair ledger, so a rebuild
            // silently skipped transfers live had applied and applied one live had
            // not. Re-derive it the way live does, exactly as .resolver_updated above
            // does for the same reason. token_regenerated keeps names.token_id in
            // step during replay, so the pair resolves as it did live.
            const contract_addr = Address.fromHex(q.getTextSlice(V2_CONTRACT) orelse return) catch return;
            const to = Address.fromHex(jsonString(data, "to") orelse return) catch return;
            // TransferBatch emits a single row carrying "count" and no "id": its
            // per-token ids never reach the event payload, so no rebuild can
            // reproduce them from here. Absent "id" is that row, and it skips.
            const id = jsonU256(data, "id") orelse return;
            const row = (self.database.getNameByTokenIdAndRegistry(id, contract_addr) catch null) orelse return;
            var row_mut = row;
            defer row_mut.deinit(self.allocator);
            names_storage.updateNameOwner(self.database, .v2, row_mut.namehash, to) catch {};
        },
        .name_renewed => {
            const nh = (try v2Namehash(q)) orelse return;
            const exp = jsonU64(data, "newExpiry") orelse jsonU64(data, "newExpiration") orelse return;
            names_storage.updateNameExpiry(self.database, nh, exp) catch {};
        },
        .expiry_updated => {
            const nh = (try v2Namehash(q)) orelse return;
            const exp = jsonU64(data, "newExpiry") orelse return;
            names_storage.updateNameExpiry(self.database, nh, exp) catch {};
        },
        .resolver_updated => {
            // Live keys the resolver update off (tokenId, emitting registry): only the name stored
            // under the registry that emitted the event is touched. A ResolverUpdated from a
            // different registry (e.g. the eth node whose name lives on the root registry) finds no
            // match and leaves the resolver untouched — so we must NOT update blindly by namehash.
            const token_id = jsonU256(data, "tokenId") orelse return;
            const contract_addr = Address.fromHex(q.getTextSlice(V2_CONTRACT) orelse return) catch return;
            const r = Address.fromHex(jsonString(data, "resolver") orelse return) catch return;
            if (self.database.getNameByTokenIdAndRegistry(token_id, contract_addr) catch null) |n_row| {
                var n = n_row;
                defer n.deinit(self.allocator);
                names_storage.updateNameResolver(self.database, .v2, n.namehash, r) catch {};
            }
        },
        .token_regenerated => {
            const nh = (try v2Namehash(q)) orelse return;
            const nt = jsonU256(data, "newTokenId") orelse return;
            self.database.updateNameTokenIdByNamehash(nh, nt) catch {};
        },
        .name_burned => {
            const nh = (try v2Namehash(q)) orelse return;
            self.database.deleteNameByNamehash(nh) catch {};
        },
        .name_registered => {
            // ONLY the orphan-queue shape. A name created from the orphan queue has no
            // LabelRegistered event of its own — the originating log was consumed into
            // orphaned_registrations — so this synthetic event is the only record of it and
            // without this arm the name vanished on every rebuild.
            //
            // Gated on `backfilled`, and that gate is load-bearing: a registrar NameRegistered
            // fires for the SAME node as the registry's LabelRegistered, carries no `registry`
            // and no `sender`, and replaying it would overwrite the row with the eth registry and
            // drop the migration provenance — whichever of the two happened to have the higher
            // log_index would win.
            if (std.mem.indexOf(u8, data, "\"backfilled\":true") != null) {
                try replayV2LabelRegistered(self, q, data);
            }
        },
        .label_unregistered => {
            // Live marks the label's own row unreachable (handlers_registry's
            // handleLabelUnregistered) on top of clearing the parent's pointer. Without this
            // arm, `--backfill` RESURRECTED every name the live indexer had soft-deleted:
            // the pointer clear is replayed by the registries pass, but the per-name soft
            // delete had no replay at all, so a rebuilt database disagreed with the live one
            // on exactly the names a user had unregistered.
            //
            // Block/timestamp come from the event row, never from the replay's own clock, so
            // the rebuilt row carries the same `unreachable_since` the live run wrote.
            const nh = (try v2Namehash(q)) orelse return;
            const block_number: u64 = @intCast(q.getInt64(V2_BLOCK_NUMBER));
            self.database.markNameUnreachableByNamehash(.v2, nh, block_number, q.getInt64(V2_TIMESTAMP)) catch {};
        },
        else => {}, // registry/resolver-record/EAC events don't rebuild `names` (subregistry parent = follow-on)
    }
}

/// Mirror handleLabelRegistered's Name construction. Covers both the main-registry
/// (.eth) case and subregistry-parented names (e.g. bar.foo.eth). At index time the
/// handler resolved the subregistry's parent from the `registries` table and froze the
/// fully-qualified name into the event's `name`/`namehash` columns, so replay reconstructs
/// the row directly from the event — parent_namehash is recomputed from the resolved
/// parent name rather than re-querying `registries`.
fn replayV2LabelRegistered(self: *Indexer, q: *Query, data: []const u8) !void {
    const nh = (try v2Namehash(q)) orelse return;
    const full_name = q.getTextSlice(V2_NAME) orelse return;
    const dot = std.mem.indexOfScalar(u8, full_name, '.') orelse return;
    const label = full_name[0..dot];
    const parent_name = full_name[dot + 1 ..];
    const parent_namehash = if (std.mem.eql(u8, parent_name, "eth"))
        self.eth_namehash
    else
        try hash_mod2.namehash(self.allocator, parent_name);

    const owner = Address.fromHex(jsonString(data, "owner") orelse return) catch return;
    const token_id = jsonU256(data, "tokenId") orelse return;
    const expiry = jsonU64(data, "expiry") orelse 0;

    const label_hash = try hash_mod2.keccak256(self.allocator, label); // == on-chain labelhash for valid labels
    const timestamp = q.getInt64(V2_TIMESTAMP);
    const block_number: u64 = @intCast(q.getInt64(V2_BLOCK_NUMBER));

    // Migration provenance: matches live (getMigrationKind(sender)); a non-migration sender
    // (or a V2-only DB) degrades to false exactly as live does.
    const sender = if (jsonString(data, "sender")) |s| (Address.fromHex(s) catch Address.zero) else Address.zero;
    const migration_kind = self.getMigrationKind(sender);
    const is_migration = migration_kind != .none;

    const registry = if (jsonString(data, "registry")) |r| (Address.fromHex(r) catch self.getEthRegistry(.v2)) else self.getEthRegistry(.v2);

    // Migration carry-over: for a V1→V2 migration, link the V1 source row via v1_label_hash and,
    // for LOCKED migrations of a wrapped V1 name, preserve its wrapper fuses/expiry. The V1 row
    // survives V2 replay (replayV2NamesCore only clears protocol='v2') and is keyed by the same
    // namehash. Mirrors handleLabelRegistered; degrades to null when the V1 row is absent
    // (V2-only DB), exactly as live does.
    var preserved_v1_label_hash_hex: ?[]u8 = null;
    var preserved_fuses_buf: ?[]u8 = null;
    var preserved_wrapper_expiry: ?i64 = null;
    var preserved_is_wrapped: bool = false;
    defer if (preserved_v1_label_hash_hex) |buf| self.allocator.free(buf);
    defer if (preserved_fuses_buf) |buf| self.allocator.free(buf);
    if (is_migration) {
        if (self.database.getNameByNamehashAndProtocol(nh, .v1) catch null) |v1_row| {
            var v1_mut = v1_row;
            defer v1_mut.deinit(self.allocator);
            preserved_v1_label_hash_hex = try v1_mut.label_hash.toHex(self.allocator);
            if (migration_kind == .locked and v1_mut.is_wrapped) {
                if (v1_mut.wrapper_fuses) |fuses_str| {
                    preserved_fuses_buf = try self.allocator.dupe(u8, fuses_str);
                }
                preserved_wrapper_expiry = v1_mut.wrapper_expiry;
                preserved_is_wrapped = true;
            }
        }
    }

    const name = models.Name{
        .name = full_name,
        .label = label,
        .label_hash = label_hash,
        .parent_name = parent_name,
        .parent_namehash = parent_namehash,
        .protocol = .v2,
        .registry = registry,
        .owner = owner,
        .registrant = owner,
        .resolver = Address.zero,
        .token_id = token_id,
        .canonical_id = token_id_utils.getCanonicalId(token_id),
        .token_version = token_id_utils.getTokenVersion(token_id),
        .namehash = nh,
        .expiry = expiry,
        .registry_locked = false,
        .migrated = is_migration,
        .created_block = block_number,
        .created_at = timestamp,
        .registered_at = timestamp,
        .updated_block = block_number,
        .updated_at = timestamp,
        .is_wrapped = preserved_is_wrapped,
        .wrapper_fuses = preserved_fuses_buf,
        .wrapper_expiry = preserved_wrapper_expiry,
        .is_v1_name = is_migration,
        .v1_label_hash = preserved_v1_label_hash_hex,
    };
    try self.insertName(name);
}

/// Mirror handleLabelReserved: a reserved label creates an owner-zero name row (no migration,
/// never wrapped). Like LabelRegistered, the resolved full name/namehash are frozen into the
/// event's name/namehash columns, so parent resolution is read back rather than re-queried.
fn replayV2LabelReserved(self: *Indexer, q: *Query, data: []const u8) !void {
    const nh = (try v2Namehash(q)) orelse return;
    const full_name = q.getTextSlice(V2_NAME) orelse return;
    const dot = std.mem.indexOfScalar(u8, full_name, '.') orelse return;
    const label = full_name[0..dot];
    const parent_name = full_name[dot + 1 ..];
    const parent_namehash = if (std.mem.eql(u8, parent_name, "eth"))
        self.eth_namehash
    else
        try hash_mod2.namehash(self.allocator, parent_name);

    const token_id = jsonU256(data, "tokenId") orelse return;
    const expiry = jsonU64(data, "expiry") orelse 0;
    const label_hash = try hash_mod2.keccak256(self.allocator, label);
    const timestamp = q.getInt64(V2_TIMESTAMP);
    const block_number: u64 = @intCast(q.getInt64(V2_BLOCK_NUMBER));
    const registry = if (jsonString(data, "registry")) |r| (Address.fromHex(r) catch self.getEthRegistry(.v2)) else self.getEthRegistry(.v2);

    const name = models.Name{
        .name = full_name,
        .label = label,
        .label_hash = label_hash,
        .parent_name = parent_name,
        .parent_namehash = parent_namehash,
        .protocol = .v2,
        .registry = registry,
        .owner = Address.zero,
        .registrant = Address.zero,
        .resolver = Address.zero,
        .token_id = token_id,
        .canonical_id = token_id_utils.getCanonicalId(token_id),
        .token_version = token_id_utils.getTokenVersion(token_id),
        .namehash = nh,
        .expiry = expiry,
        .registry_locked = false,
        .migrated = false,
        .created_block = block_number,
        .created_at = timestamp,
        .registered_at = timestamp,
        .updated_block = block_number,
        .updated_at = timestamp,
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    };
    try self.insertName(name);
}

/// Rebuild the V2 resolver-record projections (resolver_addresses / resolver_texts /
/// resolver_contenthashes) from the stored V2 event log. Composable after the names pass in a
/// combined --backfill; records depend only on the resolver + resolved namehash frozen in each
/// event, not on the names projection. Refuses on Postgres like the other replay passes.
pub fn replayV2RecordsCore(self: *Indexer) !void {
    const database = self.database;

    try database.exec("DELETE FROM resolver_addresses WHERE protocol = 'v2'");
    try database.exec("DELETE FROM resolver_texts WHERE protocol = 'v2'");
    try database.exec("DELETE FROM resolver_contenthashes WHERE protocol = 'v2'");
    try database.exec("DELETE FROM resolver_datas WHERE protocol = 'v2'");
    try database.exec("DELETE FROM resolver_links WHERE protocol = 'v2'");
    try database.exec("DELETE FROM resolver_kinds WHERE protocol = 'v2'");

    try database.beginTransaction();
    {
        var q = try Query.init(database, REPLAY_SQL_V2);
        defer q.deinit();
        while (try q.step()) {
            const et = models.EventType.fromString(q.getTextSlice(V2_EVENT_TYPE) orelse continue) orelse continue;
            switch (et) {
                .address_changed, .text_changed, .contenthash_changed, .data_changed, .resolver_created, .linked, .cleared, .address_updated, .text_updated, .data_updated, .contenthash_updated, .abi_updated, .interface_updated, .name_updated => {
                    replayV2RecordEvent(self, &q, et) catch |err| {
                        std.log.warn("V2 record replay error event={s}: {}", .{ q.getTextSlice(V2_EVENT_TYPE) orelse "?", err });
                    };
                },
                .version_changed => {
                    // Live wipes every record of this (resolver, namehash) pair and stores the
                    // new version. Replaying only the value-SETTING events left records that a
                    // version bump had cleared, so a rebuilt database served stale texts and
                    // addresses the chain no longer returns. Scoped by resolver exactly as live
                    // is, so an A->B->A resolver swap cannot wipe the other resolver's rows.
                    replayV2VersionChanged(self, &q) catch |err| {
                        std.log.warn("V2 version_changed replay error: {}", .{err});
                    };
                },
                else => {},
            }
        }
    }
    try database.commitTransaction();
}

fn jsonObjStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// Mirror handleAddressChanged/handleTextChanged/handleContentHashChanged record writes. Uses
/// std.json (not the compact hand-parser) because text values are RFC-8259-escaped in event_data
/// and must be unescaped back to the stored form. The namehash is read from the event column (the
/// handler froze the resolved node there). timestamp uses the block time (the live write-time
/// wall clock is non-deterministic and not part of the projection's meaning).
fn replayV2RecordEvent(self: *Indexer, q: *Query, et: models.EventType) !void {
    // Node-keyed events need the frozen node; record-model events carry their record
    // id in event_data instead (ResolverCreated has neither).
    const nh_opt = try v2Namehash(q);
    const nh = switch (et) {
        .address_changed, .text_changed, .contenthash_changed, .data_changed => nh_opt orelse return,
        else => nh_opt orelse Hash.zero,
    };
    const data = q.getTextSlice(V2_DATA) orelse return;
    const block_number: u64 = @intCast(q.getInt64(V2_BLOCK_NUMBER));
    const timestamp = q.getInt64(V2_TIMESTAMP);
    const tx_hash = if (q.getTextSlice(V2_TX_HASH)) |t| (Hash.fromHex(t) catch Hash.zero) else Hash.zero;

    var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch return;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };

    const resolver = Address.fromHex(jsonObjStr(obj, "resolver") orelse return) catch return;

    switch (et) {
        .address_changed => {
            const coin_type: u64 = switch (obj.get("coinType") orelse return) {
                .integer => |i| @intCast(i),
                else => return,
            };
            const address = jsonObjStr(obj, "address") orelse return;
            self.database.storeResolverAddress(nh, resolver, coin_type, address, .v2, block_number, tx_hash, timestamp) catch {};
        },
        .contenthash_changed => {
            const ch = jsonObjStr(obj, "contentHash") orelse return;
            self.database.storeResolverContentHash(nh, resolver, ch, .v2, block_number, tx_hash, timestamp) catch {};
        },
        .text_changed => {
            const key = jsonObjStr(obj, "key") orelse return;
            const value = jsonObjStr(obj, "value") orelse "";
            if (value.len == 0) {
                self.database.deleteResolverText(.v2, nh, resolver, key) catch {};
            } else {
                self.database.storeResolverText(nh, resolver, key, value, .v2, block_number, tx_hash, timestamp) catch {};
            }
        },
        .data_changed => {
            const key = jsonObjStr(obj, "key") orelse return;
            // A row written from a log whose `value` parameter was indexed carries
            // `valueHash` and no `value`: only keccak256(value) was ever on chain, so
            // live stores no value and deletes any stale one. Replay must reach the
            // same state, and it must not mistake the hash for a value — hence the
            // explicit arm rather than leaning on a missing field defaulting to empty.
            if (obj.get("valueHash") != null) {
                self.database.deleteResolverData(.v2, nh, resolver, key) catch {};
                return;
            }
            const value = jsonObjStr(obj, "value") orelse "";
            if (value.len <= 2) {
                self.database.deleteResolverData(.v2, nh, resolver, key) catch {};
            } else {
                self.database.storeResolverData(nh, resolver, key, value, .v2, block_number, tx_hash, timestamp) catch {};
            }
        },
        .resolver_created => {
            const log_index: u32 = @intCast(q.getInt64(V2_LOG_INDEX));
            self.database.upsertResolverKind(.v2, resolver, "record", block_number, tx_hash, log_index, timestamp) catch {};
        },
        // Record-model events: the record id is frozen in event_data; the row key is
        // re-derived from it (never trusted from the events.namehash column).
        .linked, .cleared, .address_updated, .text_updated, .data_updated, .contenthash_updated, .abi_updated, .interface_updated, .name_updated => {
            const record_model = @import("../storage/resolver_records.zig");
            const record_id: u256 = switch (obj.get("recordId") orelse return) {
                .integer => |i| if (i < 0) return else @intCast(i),
                .string => |s| record_model.parseRecordId(s) orelse return,
                else => return,
            };
            const rk = record_model.recordKey(record_id);
            switch (et) {
                .linked => {
                    const node = Hash.fromHex(jsonObjStr(obj, "node") orelse return) catch return;
                    const name = jsonObjStr(obj, "name") orelse "";
                    const log_index: u32 = @intCast(q.getInt64(V2_LOG_INDEX));
                    self.database.upsertResolverLink(.v2, resolver, node, record_id, name, block_number, tx_hash, log_index, timestamp) catch {};
                    // Mirror the live handler: Linked marks the resolver as record-model
                    // when nothing announced it (SharedResolver emits no ResolverCreated).
                    if (self.database.getResolverKind(resolver) catch null) |existing| {
                        self.database.allocator.free(existing);
                    } else {
                        self.database.upsertResolverKind(.v2, resolver, "record", block_number, tx_hash, log_index, timestamp) catch {};
                    }
                },
                .cleared => {
                    self.database.deleteResolverAddresses(.v2, rk, resolver) catch {};
                    self.database.deleteResolverTexts(.v2, rk, resolver) catch {};
                    self.database.deleteResolverContentHash(.v2, rk, resolver) catch {};
                    self.database.deleteResolverAbis(.v2, rk, resolver) catch {};
                    self.database.deleteResolverNames(.v2, rk, resolver) catch {};
                    self.database.deleteResolverInterfaces(.v2, rk, resolver) catch {};
                    self.database.deleteResolverDatas(.v2, rk, resolver) catch {};
                },
                .address_updated => {
                    const coin_type: u64 = switch (obj.get("coinType") orelse return) {
                        .integer => |i| @intCast(i),
                        else => return,
                    };
                    const address = jsonObjStr(obj, "address") orelse return;
                    if (address.len <= 2) {
                        self.database.deleteResolverAddress(.v2, rk, resolver, coin_type) catch {};
                    } else {
                        self.database.storeResolverAddress(rk, resolver, coin_type, address, .v2, block_number, tx_hash, timestamp) catch {};
                    }
                },
                .text_updated => {
                    const key = jsonObjStr(obj, "key") orelse return;
                    const value = jsonObjStr(obj, "value") orelse "";
                    if (value.len == 0) {
                        self.database.deleteResolverText(.v2, rk, resolver, key) catch {};
                    } else {
                        self.database.storeResolverText(rk, resolver, key, value, .v2, block_number, tx_hash, timestamp) catch {};
                    }
                },
                .data_updated => {
                    const key = jsonObjStr(obj, "key") orelse return;
                    const value = jsonObjStr(obj, "value") orelse "";
                    if (value.len <= 2) {
                        self.database.deleteResolverData(.v2, rk, resolver, key) catch {};
                    } else {
                        self.database.storeResolverData(rk, resolver, key, value, .v2, block_number, tx_hash, timestamp) catch {};
                    }
                },
                .contenthash_updated => {
                    const ch = jsonObjStr(obj, "contentHash") orelse return;
                    if (ch.len <= 2) {
                        self.database.deleteResolverContentHash(.v2, rk, resolver) catch {};
                    } else {
                        self.database.storeResolverContentHash(rk, resolver, ch, .v2, block_number, tx_hash, timestamp) catch {};
                    }
                },
                .abi_updated => {
                    const content_type: u64 = switch (obj.get("contentType") orelse return) {
                        .integer => |i| @intCast(i),
                        else => return,
                    };
                    self.database.storeResolverABI(rk, resolver, content_type, .v2, block_number, tx_hash, timestamp) catch {};
                },
                .interface_updated => {
                    const iface = jsonObjStr(obj, "interfaceID") orelse return;
                    const impl = jsonObjStr(obj, "implementer") orelse return;
                    self.database.storeResolverInterface(rk, resolver, iface, impl, .v2, block_number, tx_hash, timestamp) catch {};
                },
                .name_updated => {
                    const name = jsonObjStr(obj, "name") orelse return;
                    self.database.storeResolverName(rk, resolver, name, .v2, block_number, tx_hash, timestamp) catch {};
                },
                else => {},
            }
        },
        else => {},
    }
}

fn isZeroHex(s: []const u8) bool {
    const body = if (std.mem.startsWith(u8, s, "0x")) s[2..] else s;
    if (body.len == 0) return true;
    for (body) |c| if (c != '0') return false;
    return true;
}

/// Rebuild the V2 eac_roles projection from stored EACRolesChanged events. Fully event-derivable:
/// the resolved resource + role bitmap are frozen (as hex strings) in event_data, and upsert vs
/// delete (newRoleBitmap == 0) is last-writer-wins, so replay applies events in (block, log_index)
/// order. Backend-agnostic (Zig JSON parse + dialect-abstracted writers).
pub fn replayV2EacRolesCore(self: *Indexer) !void {
    const database = self.database;
    try database.exec("DELETE FROM eac_roles WHERE protocol = 'v2'");

    try database.beginTransaction();
    {
        var q = try Query.init(database, REPLAY_SQL_V2);
        defer q.deinit();
        while (try q.step()) {
            const et = models.EventType.fromString(q.getTextSlice(V2_EVENT_TYPE) orelse continue) orelse continue;
            if (et != .eac_roles_changed) continue;
            replayV2EacRolesEvent(self, &q) catch |err| {
                std.log.warn("V2 eac_roles replay error: {}", .{err});
            };
        }
    }
    try database.commitTransaction();
}

fn replayV2EacRolesEvent(self: *Indexer, q: *Query) !void {
    const data = q.getTextSlice(V2_DATA) orelse return;
    const resource = jsonString(data, "resource") orelse return;
    const account = Address.fromHex(jsonString(data, "account") orelse return) catch return;
    const new_bitmap = jsonString(data, "newRoleBitmap") orelse return;
    const contract = Address.fromHex(q.getTextSlice(V2_CONTRACT) orelse return) catch return;
    if (isZeroHex(new_bitmap)) {
        self.database.deleteEACRole(.v2, resource, account, contract) catch |err| std.log.warn("deleteEACRole replay: {}", .{err});
    } else {
        const block_number: u64 = @intCast(q.getInt64(V2_BLOCK_NUMBER));
        const tx_hash = if (q.getTextSlice(V2_TX_HASH)) |t| (Hash.fromHex(t) catch Hash.zero) else Hash.zero;
        const log_index: u32 = @intCast(q.getInt64(V2_LOG_INDEX));
        self.database.upsertEACRole(.v2, resource, account, new_bitmap, block_number, tx_hash, log_index, contract, q.getInt64(V2_TIMESTAMP)) catch |err| std.log.warn("upsertEACRole replay: {}", .{err});
    }
}

/// Rebuild the V2 registrations projection from stored events: LabelRegistered inserts the canonical
/// row (INSERT OR IGNORE on protocol,tx,log), and the IETHRegistrar NameRegistered (carrying
/// basePrice/premium/referrer) patches economics onto it, matched by namehash. Order-sensitive — the
/// economics UPDATE no-ops before its INSERT, so replay preserves (block, log_index) order.
pub fn replayV2RegistrationsCore(self: *Indexer) !void {
    const database = self.database;
    try database.exec("DELETE FROM registrations WHERE protocol = 'v2'");

    try database.beginTransaction();
    {
        var q = try Query.init(database, REPLAY_SQL_V2);
        defer q.deinit();
        while (try q.step()) {
            const et = models.EventType.fromString(q.getTextSlice(V2_EVENT_TYPE) orelse continue) orelse continue;
            switch (et) {
                .label_registered => replayV2RegistrationInsert(self, &q) catch |err| {
                    std.log.warn("V2 registration insert replay error: {}", .{err});
                },
                .name_registered => replayV2RegistrationEconomics(self, &q) catch |err| {
                    std.log.warn("V2 registration economics replay error: {}", .{err});
                },
                else => {},
            }
        }
    }
    try database.commitTransaction();
}

fn replayV2RegistrationInsert(self: *Indexer, q: *Query) !void {
    const nh = (try v2Namehash(q)) orelse return;
    const full_name = q.getTextSlice(V2_NAME) orelse return;
    const dot = std.mem.indexOfScalar(u8, full_name, '.') orelse return;
    const label = full_name[0..dot];
    const parent_name = full_name[dot + 1 ..];
    const data = q.getTextSlice(V2_DATA) orelse return;
    const owner = Address.fromHex(jsonString(data, "owner") orelse return) catch return;
    const expiry = jsonU64(data, "expiry") orelse 0;
    const block_number: u64 = @intCast(q.getInt64(V2_BLOCK_NUMBER));
    const timestamp = q.getInt64(V2_TIMESTAMP);
    const log_index: u32 = @intCast(q.getInt64(V2_LOG_INDEX));
    const tx_hash = if (q.getTextSlice(V2_TX_HASH)) |t| (Hash.fromHex(t) catch Hash.zero) else Hash.zero;
    self.database.insertRegistration(.v2, nh, label, parent_name, owner, timestamp, if (expiry == 0) null else expiry, block_number, tx_hash, log_index, .label_registered) catch |err| std.log.warn("insertRegistration replay: {}", .{err});
}

fn replayV2RegistrationEconomics(self: *Indexer, q: *Query) !void {
    const data = q.getTextSlice(V2_DATA) orelse return;
    // Only the IETHRegistrar variant carries economics; the generic NameRegistered has no basePrice.
    const base_cost = jsonU256(data, "basePrice") orelse return;
    const premium = jsonU256(data, "premium") orelse 0;
    const label = jsonString(data, "label") orelse return;
    const nh = (try v2Namehash(q)) orelse return;
    const referrer: ?Hash = if (jsonString(data, "referrer")) |r| (Hash.fromHex(r) catch null) else null;
    self.database.updateRegistrationEconomics(.v2, nh, label, base_cost, premium, referrer) catch |err| std.log.warn("updateRegistrationEconomics replay: {}", .{err});
}

/// Rebuild the accounts projection (one row per address ever observed in any role, with
/// seen_v1/seen_v2 flags and MIN first_seen). accounts is a shared V1+V2 table, so this replays
/// BOTH protocols' observations (owner/to/account/approved per event type, matching the live
/// handlers) then re-runs the deterministic backfillFromExistingData seed over the rebuilt
/// names/registrations — the exact computation the live indexer performs. MIN/MAX merges make it
/// order-independent, so no ORDER BY is needed. Must run AFTER names + registrations are rebuilt.
pub fn replayAccountsCore(self: *Indexer) !void {
    const database = self.database;
    try database.exec("DELETE FROM accounts");

    try database.beginTransaction();
    {
        var q = try Query.init(database, REPLAY_SQL_ACCOUNTS);
        defer q.deinit();
        while (try q.step()) {
            replayAccountObserve(self, &q) catch |err| {
                std.log.warn("account observation replay error: {}", .{err});
            };
        }
    }
    try database.commitTransaction();

    _ = @import("../storage/accounts.zig").backfillFromExistingData(database) catch |err| {
        std.log.warn("backfillFromExistingData replay error: {}", .{err});
    };
}

fn observeAccount(self: *Indexer, protocol: models.Protocol, hex: []const u8, block: u64, ts: i64) void {
    const addr = Address.fromHex(hex) catch return;
    if (addr.isZero()) return;
    var buf: [42]u8 = undefined;
    self.database.upsertAccount(protocol, addr.toHexBuf(&buf), block, ts) catch {};
}

fn replayAccountObserve(self: *Indexer, q: *Query) !void {
    const protocol = models.Protocol.fromString(q.getTextSlice(ACC_PROTOCOL) orelse return) catch return;
    const et = models.EventType.fromString(q.getTextSlice(ACC_EVENT_TYPE) orelse return) orelse return;
    const block: u64 = @intCast(q.getInt64(ACC_BLOCK));
    const ts = q.getInt64(ACC_TS);
    const data = q.getTextSlice(ACC_DATA) orelse return;
    switch (protocol) {
        .v2 => switch (et) {
            .name_registered => if (jsonString(data, "owner")) |o| observeAccount(self, .v2, o, block, ts),
            .transfer => if (jsonString(data, "to")) |o| observeAccount(self, .v2, o, block, ts),
            .eac_roles_changed => if (jsonString(data, "account")) |o| observeAccount(self, .v2, o, block, ts),
            .approval => {
                if (jsonString(data, "owner")) |o| observeAccount(self, .v2, o, block, ts);
                if (jsonString(data, "approved")) |o| observeAccount(self, .v2, o, block, ts);
            },
            else => {},
        },
        // V1: NewOwner (transfer + parentNode) observes owner; ERC721/wrapper transfer observes to.
        .v1 => switch (et) {
            .transfer => {
                if (jsonRawValue(data, "parentNode") != null) {
                    if (jsonString(data, "owner")) |o| observeAccount(self, .v1, o, block, ts);
                } else if (jsonString(data, "to")) |o| observeAccount(self, .v1, o, block, ts);
            },
            .registry_transfer, .name_wrapped, .name_registered => if (jsonString(data, "owner")) |o| observeAccount(self, .v1, o, block, ts),
            else => {},
        },
    }
}

/// Rebuild the V2 registries + registry_entries projections from stored events. registry_entries
/// is fully event-derived (SubregistryUpdated + LabelUnregistered); registries keeps its root+eth
/// bootstrap rows (seeded at init, not events) which are re-seeded, plus subregistry rows from the
/// pointer changes. Faithfully mirrors processSubregistryPointerChange: upsert the pointer, run the
/// reachability cascade (invalidate the old subtree / re-link the new one — the re-link also fixes
/// subregistry names that the names pass marked unreachable while registry_entries was still empty),
/// then register the subregistry. Must run AFTER the names pass. Backend-agnostic.
pub fn replayV2RegistriesCore(self: *Indexer) !void {
    const database = self.database;
    try database.exec("DELETE FROM registry_entries WHERE protocol = 'v2'");
    try database.exec("DELETE FROM registries WHERE protocol = 'v2'");
    try self.seedV2Registries();

    try database.beginTransaction();
    {
        var q = try Query.init(database, REPLAY_SQL_V2);
        defer q.deinit();
        while (try q.step()) {
            const et = models.EventType.fromString(q.getTextSlice(V2_EVENT_TYPE) orelse continue) orelse continue;
            switch (et) {
                .subregistry_updated => replayV2SubregistryPointer(self, &q, false) catch |err| {
                    std.log.warn("V2 subregistry_updated replay error: {}", .{err});
                },
                .label_unregistered => replayV2SubregistryPointer(self, &q, true) catch |err| {
                    std.log.warn("V2 label_unregistered replay error: {}", .{err});
                },
                .registry_created => replayV2RegistryCreated(self, &q) catch |err| {
                    std.log.warn("V2 registry_created replay error: {}", .{err});
                },
                else => {},
            }
        }
    }
    try database.commitTransaction();
}

/// Rebuild the shared-registry alias rows. Must run AFTER replayV2NamesCore (which
/// wipes every V2 `names` row, aliases included, and rebuilds the primaries from the
/// FQDN frozen into each event) and AFTER replayV2RegistriesCore (which rebuilds both
/// `registries` and the `registry_entries` mirror the derivation reads).
///
/// This is why the derivation is state-derived rather than event-driven: a
/// `LabelRegistered` event carries exactly one FQDN, so the names replay can only
/// ever reconstruct one row per label, and the mirror it would need to find the other
/// parents does not exist yet at that point in the replay order. Recomputing from the
/// finished tables instead lands on the same rows a live run did, and needs no
/// timestamp of its own — a stale alias is deleted, never stamped.
pub fn replayV2AliasesCore(self: *Indexer) !void {
    // Unbounded: a replay must reach the fixpoint in one pass so the rebuilt
    // database is byte-comparable against a live one.
    // Evaluate parent expiry as of the replayed head, so the rebuilt rows match what a live run
    // holding the same head would have.
    const head_ts = blk: {
        var q = Query.init(self.database, "SELECT MAX(timestamp) FROM events WHERE protocol = 'v2'") catch break :blk 0;
        defer q.deinit();
        break :blk if (q.step() catch false) q.getInt64(0) else 0;
    };
    const stats = try alias_sync.runToFixpoint(self, .v2, head_ts);
    if (stats.aliases_written > 0 or stats.aliases_deleted > 0) {
        std.log.info("V2 alias replay: +{d} derived, -{d} stale, {d} collision(s) skipped", .{ stats.aliases_written, stats.aliases_deleted, stats.skipped_collisions });
    }
    // The fixpoint must actually be reached, or the rebuilt database is not the one a
    // live run would have produced and a byte-comparison against it is meaningless.
    if (stats.work_remaining) {
        std.log.warn("V2 alias replay did not converge in one pass — page guard hit; re-run --backfill", .{});
    }
}

/// Mirror `handleVersionChanged`: clear every record of this (resolver, namehash) pair and
/// store the new version. The resolver is the event's emitting contract, so the scope is
/// identical to live's.
///
/// Aliases are deliberately NOT cleared — they live in `_storage().aliases`, not
/// `_record(node)`, so a version bump does not touch them on-chain either. Keeping that
/// asymmetry is the point: a replay that cleared them would diverge the other way.
fn replayV2VersionChanged(self: *Indexer, q: *Query) !void {
    const nh = (try v2Namehash(q)) orelse return;
    const resolver = Address.fromHex(q.getTextSlice(V2_CONTRACT) orelse return) catch return;
    const data = q.getTextSlice(V2_DATA) orelse "";

    self.database.deleteResolverAddresses(.v2, nh, resolver) catch {};
    self.database.deleteResolverContentHash(.v2, nh, resolver) catch {};
    self.database.deleteResolverTexts(.v2, nh, resolver) catch {};
    self.database.deleteResolverPubkeys(.v2, nh, resolver) catch {};
    self.database.deleteResolverAbis(.v2, nh, resolver) catch {};
    self.database.deleteResolverNames(.v2, nh, resolver) catch {};
    self.database.deleteResolverInterfaces(.v2, nh, resolver) catch {};

    const new_version = jsonU64(data, "newVersion") orelse jsonU64(data, "version") orelse 0;
    const block_number: u64 = @intCast(q.getInt64(V2_BLOCK_NUMBER));
    const tx = Hash.fromHex(q.getTextSlice(V2_TX_HASH) orelse "") catch Hash.zero;
    self.database.storeResolverVersion(nh, resolver, new_version, .v2, block_number, tx, q.getInt64(V2_TIMESTAMP)) catch {};
}

fn replayV2RegistryCreated(self: *Indexer, q: *Query) !void {
    const registry = Address.fromHex(q.getTextSlice(V2_CONTRACT) orelse return) catch return;
    const block_number: u64 = @intCast(q.getInt64(V2_BLOCK_NUMBER));
    try self.database.setSeededRootRegistryCreation(registry, .v2, block_number, q.getInt64(V2_TIMESTAMP));
}

fn replayV2SubregistryPointer(self: *Indexer, q: *Query, clear: bool) !void {
    const data = q.getTextSlice(V2_DATA) orelse return;
    // For SubregistryUpdated the emitting parent registry is data.registry; LabelUnregistered
    // clears the pointer, so the parent is the emitting contract and the new subregistry is zero.
    const registry = Address.fromHex(if (clear)
        (q.getTextSlice(V2_CONTRACT) orelse return)
    else
        (jsonString(data, "registry") orelse return)) catch return;
    // getCanonicalId (inside upsertSubregistry) is idempotent, so the version-stripped canonicalId
    // frozen in the event maps to the same canonical_id the live handler derived from the token id.
    const canonical_id = jsonU256(data, "canonicalId") orelse jsonU256(data, "tokenId") orelse return;
    const new_subregistry = if (clear)
        Address.zero
    else
        (Address.fromHex(jsonString(data, "subregistry") orelse return) catch return);
    const block_number: u64 = @intCast(q.getInt64(V2_BLOCK_NUMBER));
    const ts = q.getInt64(V2_TIMESTAMP);

    const prev = try self.database.upsertRegistryEntrySubregistry(.v2, registry, canonical_id, new_subregistry, block_number, ts);

    // Edge change: per-registry reachability recompute over both affected
    // subtrees — identical to the live handler (no blanket cascades; the
    // graph permits multi-parent edges). Also flips subregistry names the
    // names pass left is_reachable=0 while registry_entries was empty.
    if (!prev.eql(new_subregistry)) {
        const roots = [_]Address{ self.config.v2_contracts.eth_registry, self.config.v2_contracts.root_registry };
        const seeds = [_]Address{ prev, new_subregistry };
        _ = try self.database.recomputeSubtreeReachability(self.allocator, .v2, &seeds, &roots, block_number, ts);
    }

    // Register the subregistry (INSERT OR IGNORE keeps the bootstrap eth row). Resolve its name
    // from the rebuilt names, exactly like processSubregistryPointerChange.
    if (!new_subregistry.isZero()) {
        var name_str: []const u8 = "";
        var namehash = Hash.zero;
        var name_owned = false;
        if (try self.database.getNameByTokenIdAndRegistry(canonical_id, registry)) |n_row| {
            var n = n_row;
            defer n.deinit(self.allocator);
            if (n.name) |nm| {
                name_str = try self.allocator.dupe(u8, nm);
                name_owned = true;
            }
            namehash = n.namehash;
        }
        defer if (name_owned) self.allocator.free(name_str);
        self.database.insertRegistry(.{
            .address = new_subregistry,
            .protocol = .v2,
            .name = name_str,
            .namehash = namehash,
            .parent_registry = registry,
            .created_block = block_number,
            .created_at = ts,
        }) catch |err| std.log.warn("insertRegistry replay: {}", .{err});
        self.database.setSeededSubregistryCreation(new_subregistry, .v2, namehash, registry, block_number, ts) catch |err| std.log.warn("setSeededSubregistryCreation replay: {}", .{err});
    }
}

test "jsonU256/jsonU64/jsonString parse compact JSON losslessly (json_extract would corrupt)" {
    const t = std.testing;
    // A real u256 tokenId that overflows f64/i64 — json_extract returns a float here.
    const big = "115792089237316195423570985008687907853269984665640564039457584007913129639935";
    const data = "{\"name\":\"foo.eth\",\"tokenId\":" ++ big ++ ",\"oldTokenId\":42,\"owner\":\"0xabc\",\"expiry\":18446744073709551615,\"registry\":\"0x00\"}";
    try t.expectEqual(@as(?u256, try std.fmt.parseInt(u256, big, 10)), jsonU256(data, "tokenId"));
    // Suffix-key guard: "tokenId" must not match inside "oldTokenId".
    try t.expectEqual(@as(?u256, 42), jsonU256(data, "oldTokenId"));
    try t.expectEqual(@as(?u64, std.math.maxInt(u64)), jsonU64(data, "expiry"));
    try t.expectEqualStrings("foo.eth", jsonString(data, "name").?);
    try t.expectEqualStrings("0xabc", jsonString(data, "owner").?);
    try t.expect(jsonU256(data, "missing") == null);
    // Quoted numeric also parses.
    try t.expectEqual(@as(?u256, 7), jsonU256("{\"tokenId\":\"7\"}", "tokenId"));
}

/// Dump the stable (non-volatile) columns of `names` for equivalence comparison.
fn dumpNamesForTest(database: *db_module.Database, allocator: std.mem.Allocator) ![]u8 {
    var q = try Query.init(database,
        \\SELECT namehash, COALESCE(name,''), COALESCE(label,''), owner, resolver,
        \\       token_id, canonical_id, token_version, expiry, migrated, is_v1_name, protocol,
        \\       COALESCE(parent_name,''), COALESCE(parent_namehash,''), registry,
        \\       is_wrapped, COALESCE(wrapper_fuses,'NULL'), COALESCE(CAST(wrapper_expiry AS TEXT),'NULL'),
        \\       COALESCE(v1_label_hash,'NULL')
        \\FROM names ORDER BY namehash, protocol
    );
    defer q.deinit();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    while (try q.step()) {
        var i: usize = 0;
        while (i < 19) : (i += 1) {
            try out.appendSlice(allocator, q.getTextSlice(i) orelse "NULL");
            try out.append(allocator, '|');
        }
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

test "replay(events) rebuilds V2 names (main-registry + subregistry + reserved + migration carry-over) identically to live" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var cfg = @import("../config.zig").Config.fromEnv(allocator) catch return; // needs a loadable config
    cfg.status_port = null; // skip Indexer.init's status server (its getBlockNumber() RPC would hang offline)
    cfg.webhooks_enabled = false; // no webhook manager/DB in a unit test
    const mig_ctrl = "0x681802eff57b83edce99d688c023ab1284495176"; // locked migration controller
    cfg.v1_contracts.locked_migration_controller = try Address.fromHex(mig_ctrl);
    defer cfg.deinit();
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const foo_nh = try hash_mod2.namehash(allocator, "foo.eth");
    const owner1 = "0x1111111111111111111111111111111111111111";
    const owner2 = "0x2222222222222222222222222222222222222222";
    const reg = "0x3333333333333333333333333333333333333333";
    const big_token = "115792089237316195423570985008687907853269984665640564039457584007913129639935";

    const sub_reg = "0x4444444444444444444444444444444444444444"; // subregistry contract for foo.eth

    // The emitting contract is part of the fixture, not a placeholder: replay keys
    // ownership and resolver updates off (tokenId, emitting registry), so an event
    // attributed to the zero address is not a shape live can produce.
    const ev = struct {
        fn go(db: *db_module.Database, et: models.EventType, name: []const u8, nh: ?Hash, data: []const u8, blk: u64, li: u32, contract: Address) !void {
            try @import("../storage/events.zig").insertEvent(db, .{
                .event_type = et,
                .protocol = .v2,
                .block_number = blk,
                .tx_hash = Hash.zero,
                .log_index = li,
                .contract_address = contract,
                .name = name,
                .namehash = nh,
                .data = data,
                .timestamp = 1000,
            });
        }
    }.go;

    // Build the two DBs: `live` gets events + direct names writes; `replayed` gets events only.
    const build = struct {
        fn go(a: std.mem.Allocator, io_: std.Io, c: @TypeOf(cfg), fnh: Hash, bt: []const u8, o1: []const u8, o2: []const u8, r: []const u8, mc: []const u8, apply_names: bool) !*db_module.Database {
            const database = try a.create(db_module.Database);
            database.* = try db_module.Database.init(a, ":memory:");
            var idx = try Indexer.init(a, io_, c, database, null);
            defer idx.deinit();

            const reg_data = try std.fmt.allocPrint(a, "{{\"name\":\"foo.eth\",\"tokenId\":{s},\"owner\":\"{s}\",\"expiry\":1000000,\"sender\":\"{s}\",\"registry\":\"{s}\"}}", .{ bt, o1, o1, r });
            defer a.free(reg_data);
            const reg_addr = try Address.fromHex(r);
            try ev(database, .label_registered, "foo.eth", fnh, reg_data, 100, 0, reg_addr);
            // Live's Transfer payload always carries the token id, and ownership is
            // keyed off (id, emitting registry) — the events row's namehash is a
            // denormalised copy that may still be a placeholder.
            const xfer_data = try std.fmt.allocPrint(a, "{{\"to\":\"{s}\",\"id\":{s},\"value\":1}}", .{ o2, bt });
            defer a.free(xfer_data);
            try ev(database, .transfer, "foo.eth", fnh, xfer_data, 101, 1, reg_addr);
            try ev(database, .name_renewed, "foo.eth", fnh, "{\"newExpiry\":2000000}", 102, 2, reg_addr);

            // Subregistry-parented child: bar.foo.eth registered on foo.eth's subregistry
            // contract. At index time the handler resolved the parent via `registries` and froze
            // "bar.foo.eth" into the event name; replay reconstructs it without touching registries.
            const bar_nh = try hash_mod2.namehash(a, "bar.foo.eth");
            const child_data = try std.fmt.allocPrint(a, "{{\"name\":\"bar.foo.eth\",\"tokenId\":42,\"canonicalId\":42,\"owner\":\"{s}\",\"expiry\":1500000,\"sender\":\"{s}\",\"registry\":\"{s}\"}}", .{ o1, o1, sub_reg });
            defer a.free(child_data);
            try ev(database, .label_registered, "bar.foo.eth", bar_nh, child_data, 103, 3, try Address.fromHex(sub_reg));

            // V1→V2 LOCKED migration. A pre-existing wrapped V1 row for mig.eth is seeded into BOTH
            // DBs (pre-migration state, not a replayed event). When the locked migration controller
            // registers mig.eth on V2, the carry-over links v1_label_hash and preserves the V1
            // wrapper fuses/expiry. Replay must reconstruct this from the V1 row it looks up.
            const mig_nh = try hash_mod2.namehash(a, "mig.eth");
            const mig_lh = try hash_mod2.keccak256(a, "mig");
            try idx.insertName(.{
                .name = "mig.eth",
                .label = "mig",
                .label_hash = mig_lh,
                .parent_name = "eth",
                .parent_namehash = idx.eth_namehash,
                .protocol = .v1,
                .registry = try Address.fromHex(r),
                .owner = try Address.fromHex(o1),
                .registrant = try Address.fromHex(o1),
                .resolver = Address.zero,
                .token_id = 0,
                .canonical_id = 0,
                .token_version = 0,
                .namehash = mig_nh,
                .expiry = 3000000,
                .registry_locked = false,
                .migrated = false,
                .created_block = 50,
                .created_at = 1000,
                .registered_at = 1000,
                .updated_block = 50,
                .updated_at = 1000,
                .is_wrapped = true,
                .wrapper_fuses = "65536",
                .wrapper_expiry = 3000000,
                .is_v1_name = true,
                .v1_label_hash = null,
            });
            const mig_data = try std.fmt.allocPrint(a, "{{\"name\":\"mig.eth\",\"tokenId\":77,\"canonicalId\":77,\"owner\":\"{s}\",\"expiry\":2500000,\"sender\":\"{s}\",\"registry\":\"{s}\"}}", .{ o1, mc, r });
            defer a.free(mig_data);
            try ev(database, .label_registered, "mig.eth", mig_nh, mig_data, 104, 4, reg_addr);

            // Reserved label: owner-zero name row created by a LabelReserved event (the bulk of
            // real names). Replay must reconstruct it via replayV2LabelReserved.
            const resv_nh = try hash_mod2.namehash(a, "resv.eth");
            const resv_data = try std.fmt.allocPrint(a, "{{\"name\":\"resv.eth\",\"tokenId\":88,\"expiry\":1800000,\"sender\":\"{s}\",\"registry\":\"{s}\",\"reserved\":true}}", .{ o1, r });
            defer a.free(resv_data);
            try ev(database, .label_reserved, "resv.eth", resv_nh, resv_data, 105, 5, reg_addr);

            if (apply_names) {
                // Mirror what the live handlers produce (the ground-truth expected state).
                const token_id = try std.fmt.parseInt(u256, bt, 10);
                const lh = try hash_mod2.keccak256(a, "foo");
                try idx.insertName(.{
                    .name = "foo.eth",
                    .label = "foo",
                    .label_hash = lh,
                    .parent_name = "eth",
                    .parent_namehash = idx.eth_namehash,
                    .protocol = .v2,
                    .registry = try Address.fromHex(r),
                    .owner = try Address.fromHex(o1),
                    .registrant = try Address.fromHex(o1),
                    .resolver = Address.zero,
                    .token_id = token_id,
                    .canonical_id = token_id_utils.getCanonicalId(token_id),
                    .token_version = token_id_utils.getTokenVersion(token_id),
                    .namehash = fnh,
                    .expiry = 1000000,
                    .registry_locked = false,
                    .migrated = false,
                    .created_block = 100,
                    .created_at = 1000,
                    .registered_at = 1000,
                    .updated_block = 100,
                    .updated_at = 1000,
                    .is_wrapped = false,
                    .wrapper_fuses = null,
                    .wrapper_expiry = null,
                    .is_v1_name = false,
                    .v1_label_hash = null,
                });
                try @import("../storage/names.zig").updateNameOwner(database, .v2, fnh, try Address.fromHex(o2));
                try @import("../storage/names.zig").updateNameExpiry(database, fnh, 2000000);

                const bar_lh = try hash_mod2.keccak256(a, "bar");
                try idx.insertName(.{
                    .name = "bar.foo.eth",
                    .label = "bar",
                    .label_hash = bar_lh,
                    .parent_name = "foo.eth",
                    .parent_namehash = fnh,
                    .protocol = .v2,
                    .registry = try Address.fromHex(sub_reg),
                    .owner = try Address.fromHex(o1),
                    .registrant = try Address.fromHex(o1),
                    .resolver = Address.zero,
                    .token_id = 42,
                    .canonical_id = token_id_utils.getCanonicalId(42),
                    .token_version = token_id_utils.getTokenVersion(42),
                    .namehash = bar_nh,
                    .expiry = 1500000,
                    .registry_locked = false,
                    .migrated = false,
                    .created_block = 103,
                    .created_at = 1000,
                    .registered_at = 1000,
                    .updated_block = 103,
                    .updated_at = 1000,
                    .is_wrapped = false,
                    .wrapper_fuses = null,
                    .wrapper_expiry = null,
                    .is_v1_name = false,
                    .v1_label_hash = null,
                });

                // Migrated V2 mig.eth: LOCKED migration of the wrapped V1 row above. v1_label_hash
                // is derived from the V1 row's label_hash; wrapper fuses/expiry + is_wrapped carried.
                const mig_v1_hash_hex = try mig_lh.toHex(a);
                defer a.free(mig_v1_hash_hex);
                try idx.insertName(.{
                    .name = "mig.eth",
                    .label = "mig",
                    .label_hash = mig_lh,
                    .parent_name = "eth",
                    .parent_namehash = idx.eth_namehash,
                    .protocol = .v2,
                    .registry = try Address.fromHex(r),
                    .owner = try Address.fromHex(o1),
                    .registrant = try Address.fromHex(o1),
                    .resolver = Address.zero,
                    .token_id = 77,
                    .canonical_id = token_id_utils.getCanonicalId(77),
                    .token_version = token_id_utils.getTokenVersion(77),
                    .namehash = mig_nh,
                    .expiry = 2500000,
                    .registry_locked = false,
                    .migrated = true,
                    .created_block = 104,
                    .created_at = 1000,
                    .registered_at = 1000,
                    .updated_block = 104,
                    .updated_at = 1000,
                    .is_wrapped = true,
                    .wrapper_fuses = "65536",
                    .wrapper_expiry = 3000000,
                    .is_v1_name = true,
                    .v1_label_hash = mig_v1_hash_hex,
                });

                const resv_lh = try hash_mod2.keccak256(a, "resv");
                try idx.insertName(.{
                    .name = "resv.eth",
                    .label = "resv",
                    .label_hash = resv_lh,
                    .parent_name = "eth",
                    .parent_namehash = idx.eth_namehash,
                    .protocol = .v2,
                    .registry = try Address.fromHex(r),
                    .owner = Address.zero,
                    .registrant = Address.zero,
                    .resolver = Address.zero,
                    .token_id = 88,
                    .canonical_id = token_id_utils.getCanonicalId(88),
                    .token_version = token_id_utils.getTokenVersion(88),
                    .namehash = resv_nh,
                    .expiry = 1800000,
                    .registry_locked = false,
                    .migrated = false,
                    .created_block = 105,
                    .created_at = 1000,
                    .registered_at = 1000,
                    .updated_block = 105,
                    .updated_at = 1000,
                    .is_wrapped = false,
                    .wrapper_fuses = null,
                    .wrapper_expiry = null,
                    .is_v1_name = false,
                    .v1_label_hash = null,
                });
            } else {
                try replayV2NamesCore(&idx);
            }
            return database;
        }
    }.go;

    const live = try build(allocator, io, cfg, foo_nh, big_token, owner1, owner2, reg, mig_ctrl, true);
    defer {
        live.deinit();
        allocator.destroy(live);
    }
    const replayed = try build(allocator, io, cfg, foo_nh, big_token, owner1, owner2, reg, mig_ctrl, false);
    defer {
        replayed.deinit();
        allocator.destroy(replayed);
    }

    const live_dump = try dumpNamesForTest(live, allocator);
    defer allocator.free(live_dump);
    const replayed_dump = try dumpNamesForTest(replayed, allocator);
    defer allocator.free(replayed_dump);

    try std.testing.expect(live_dump.len > 0); // sanity: not vacuously empty
    try std.testing.expectEqualStrings(live_dump, replayed_dump);
}

test "replayV2RecordsCore rebuilds resolver records (address/text/contenthash) with correct unescaping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var cfg = @import("../config.zig").Config.fromEnv(allocator) catch return;
    cfg.status_port = null;
    cfg.webhooks_enabled = false;
    defer cfg.deinit();
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();

    const database = try allocator.create(db_module.Database);
    database.* = try db_module.Database.init(allocator, ":memory:");
    defer {
        database.deinit();
        allocator.destroy(database);
    }
    var idx = try Indexer.init(allocator, threaded.io(), cfg, database, null);
    defer idx.deinit();

    const node = try hash_mod2.namehash(allocator, "rec.eth");
    const resolver = "0x5555555555555555555555555555555555555555";

    const ev = struct {
        fn go(db: *db_module.Database, et: models.EventType, nh: Hash, data: []const u8, li: u32) !void {
            try @import("../storage/events.zig").insertEvent(db, .{
                .event_type = et,
                .protocol = .v2,
                .block_number = 200,
                .tx_hash = Hash.zero,
                .log_index = li,
                .contract_address = Address.zero,
                .name = "rec.eth",
                .namehash = nh,
                .data = data,
                .timestamp = 1000,
            });
        }
    }.go;

    const nh_hex = try node.toHex(allocator);
    const addr_data = try std.fmt.allocPrint(allocator, "{{\"namehash\":\"{s}\",\"resolver\":\"{s}\",\"coinType\":60,\"address\":\"0x00000000000000000000000000000000000000ab\"}}", .{ nh_hex, resolver });
    // A text value containing an embedded quote — escaped in event_data, must round-trip back.
    const text_data = try std.fmt.allocPrint(allocator, "{{\"namehash\":\"{s}\",\"resolver\":\"{s}\",\"key\":\"note\",\"value\":\"he said \\\"hi\\\"\"}}", .{ nh_hex, resolver });
    const ch_data = try std.fmt.allocPrint(allocator, "{{\"namehash\":\"{s}\",\"resolver\":\"{s}\",\"contentHash\":\"0xe30101701220ab\"}}", .{ nh_hex, resolver });
    try ev(database, .address_changed, node, addr_data, 0);
    try ev(database, .text_changed, node, text_data, 1);
    try ev(database, .contenthash_changed, node, ch_data, 2);

    try replayV2RecordsCore(&idx);

    const one = struct {
        fn str(db: *db_module.Database, a: std.mem.Allocator, sql: []const u8) !?[]u8 {
            var qq = try Query.init(db, sql);
            defer qq.deinit();
            if (try qq.step()) {
                if (qq.getTextSlice(0)) |s| return try a.dupe(u8, s);
            }
            return null;
        }
    }.str;

    const addr = try one(database, allocator, "SELECT address FROM resolver_addresses WHERE coin_type = 60");
    try std.testing.expectEqualStrings("0x00000000000000000000000000000000000000ab", addr.?);
    const val = try one(database, allocator, "SELECT value FROM resolver_texts WHERE key = 'note'");
    try std.testing.expectEqualStrings("he said \"hi\"", val.?); // unescaped back to the original
    const ch = try one(database, allocator, "SELECT contenthash FROM resolver_contenthashes");
    try std.testing.expectEqualStrings("0xe30101701220ab", ch.?);
}

test "replay reconstructs an orphan-queue name, and ignores a registrar NameRegistered" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var cfg = @import("../config.zig").Config.fromEnv(allocator) catch return;
    cfg.status_port = null;
    cfg.webhooks_enabled = false;
    defer cfg.deinit();
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();

    const database = try allocator.create(db_module.Database);
    database.* = try db_module.Database.init(allocator, ":memory:");
    defer {
        database.deinit();
        allocator.destroy(database);
    }
    var idx = try Indexer.init(allocator, threaded.io(), cfg, database, null);
    defer idx.deinit();

    const sub_reg = "0x4444444444444444444444444444444444444444";
    const owner = "0x1111111111111111111111111111111111111111";
    const orphan_nh = try hash_mod2.namehash(allocator, "late.foo.eth");
    const plain_nh = try hash_mod2.namehash(allocator, "plain.eth");

    const ev = struct {
        fn go(db: *db_module.Database, et: models.EventType, name: []const u8, nh: Hash, data: []const u8, li: u32) !void {
            try @import("../storage/events.zig").insertEvent(db, .{
                .event_type = et,
                .protocol = .v2,
                .block_number = 300 + li,
                .tx_hash = Hash.zero,
                .log_index = li,
                .contract_address = Address.zero,
                .name = name,
                .namehash = nh,
                .data = data,
                .timestamp = 1000,
            });
        }
    }.go;

    // The orphan-queue shape: `backfilled`, and it carries the registry + token id, because it is
    // the ONLY record of a registration whose originating log went into orphaned_registrations.
    const orphan_data = try std.fmt.allocPrint(allocator, "{{\"name\":\"late.foo.eth\",\"label\":\"late\",\"owner\":\"{s}\",\"expiry\":1500000,\"tokenId\":77,\"registry\":\"{s}\",\"backfilled\":true}}", .{ owner, sub_reg });
    try ev(database, .name_registered, "late.foo.eth", orphan_nh, orphan_data, 0);

    // A registrar NameRegistered: same shape of event type, but NO registry and NO backfilled
    // marker. Replaying it would write the eth registry over whatever LabelRegistered produced,
    // so it must be ignored here.
    const registrar_data = try std.fmt.allocPrint(allocator, "{{\"label\":\"plain\",\"tokenId\":88,\"namehash\":\"0x00\",\"owner\":\"{s}\",\"expiration\":1600000}}", .{owner});
    try ev(database, .name_registered, "plain.eth", plain_nh, registrar_data, 1);

    try replayV2NamesCore(&idx);

    // The orphan name is reconstructed, with its real registry — not the eth registry.
    var row = (try database.getNameByNamehash(orphan_nh)).?;
    defer row.deinit(allocator);
    try std.testing.expectEqualStrings("late.foo.eth", row.name.?);
    try std.testing.expectEqualStrings("foo.eth", row.parent_name.?);
    var reg_buf: [42]u8 = undefined;
    try std.testing.expectEqualStrings(sub_reg, row.registry.toHexBuf(&reg_buf));

    // The registrar event produced nothing: LabelRegistered owns that node.
    try std.testing.expect((try database.getNameByNamehash(plain_nh)) == null);
}

test "replayV2RecordsCore applies VersionChanged, so a rebuild does not serve records the chain cleared" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var cfg = @import("../config.zig").Config.fromEnv(allocator) catch return;
    cfg.status_port = null;
    cfg.webhooks_enabled = false;
    defer cfg.deinit();
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();

    const database = try allocator.create(db_module.Database);
    database.* = try db_module.Database.init(allocator, ":memory:");
    defer {
        database.deinit();
        allocator.destroy(database);
    }
    var idx = try Indexer.init(allocator, threaded.io(), cfg, database, null);
    defer idx.deinit();

    const node = try hash_mod2.namehash(allocator, "ver.eth");
    const resolver_a = try Address.fromHex("0x5555555555555555555555555555555555555555");
    const resolver_b = try Address.fromHex("0x6666666666666666666666666666666666666666");
    const nh_hex = try node.toHex(allocator);

    const ev = struct {
        fn go(db: *db_module.Database, et: models.EventType, nh: Hash, contract: Address, data: []const u8, li: u32) !void {
            try @import("../storage/events.zig").insertEvent(db, .{
                .event_type = et,
                .protocol = .v2,
                .block_number = 200 + li,
                .tx_hash = Hash.zero,
                .log_index = li,
                .contract_address = contract,
                .name = "ver.eth",
                .namehash = nh,
                .data = data,
                .timestamp = 1000,
            });
        }
    }.go;

    // Two resolvers hold a text for the same node; then resolver A bumps its version, which
    // on-chain clears A's records for that node and leaves B's alone.
    const a_text = try std.fmt.allocPrint(allocator, "{{\"namehash\":\"{s}\",\"resolver\":\"0x5555555555555555555555555555555555555555\",\"key\":\"note\",\"value\":\"from-a\"}}", .{nh_hex});
    const b_text = try std.fmt.allocPrint(allocator, "{{\"namehash\":\"{s}\",\"resolver\":\"0x6666666666666666666666666666666666666666\",\"key\":\"note\",\"value\":\"from-b\"}}", .{nh_hex});
    const bump = try std.fmt.allocPrint(allocator, "{{\"namehash\":\"{s}\",\"newVersion\":7}}", .{nh_hex});
    try ev(database, .text_changed, node, resolver_a, a_text, 0);
    try ev(database, .text_changed, node, resolver_b, b_text, 1);
    try ev(database, .version_changed, node, resolver_a, bump, 2);

    try replayV2RecordsCore(&idx);

    // Without the version_changed arm the replay kept "from-a" — a value the chain no longer
    // returns — so a rebuilt database served a stale text. A's row must be gone.
    var qa = try Query.init(database, "SELECT COUNT(*) FROM resolver_texts WHERE resolver = '0x5555555555555555555555555555555555555555'");
    defer qa.deinit();
    try std.testing.expect(try qa.step());
    try std.testing.expectEqual(@as(i64, 0), qa.getInt64(0));

    // B's record is untouched: the clear is scoped to the emitting resolver, exactly as live.
    var qb = try Query.init(database, "SELECT value FROM resolver_texts WHERE resolver = '0x6666666666666666666666666666666666666666'");
    defer qb.deinit();
    try std.testing.expect(try qb.step());
    try std.testing.expectEqualStrings("from-b", qb.getTextSlice(0).?);
}

test "replayV2EacRolesCore + replayV2RegistrationsCore rebuild roles and registrations from events" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var cfg = @import("../config.zig").Config.fromEnv(allocator) catch return;
    cfg.status_port = null;
    cfg.webhooks_enabled = false;
    defer cfg.deinit();
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();

    const database = try allocator.create(db_module.Database);
    database.* = try db_module.Database.init(allocator, ":memory:");
    defer {
        database.deinit();
        allocator.destroy(database);
    }
    var idx = try Indexer.init(allocator, threaded.io(), cfg, database, null);
    defer idx.deinit();

    const nh = try hash_mod2.namehash(allocator, "eco.eth");
    const nh_hex = try nh.toHex(allocator);
    const owner = "0x1111111111111111111111111111111111111111";
    const reg = "0x2222222222222222222222222222222222222222";

    const ev = struct {
        fn go(db: *db_module.Database, et: models.EventType, name: []const u8, h: ?Hash, data: []const u8, blk: u64, li: u32) !void {
            try @import("../storage/events.zig").insertEvent(db, .{
                .event_type = et,
                .protocol = .v2,
                .block_number = blk,
                .tx_hash = Hash.zero,
                .log_index = li,
                .contract_address = try Address.fromHex(reg),
                .name = name,
                .namehash = h,
                .data = data,
                .timestamp = 1000,
            });
        }
    }.go;

    // LabelRegistered (canonical registration row) then IETHRegistrar NameRegistered (economics).
    const lr = try std.fmt.allocPrint(allocator, "{{\"name\":\"eco.eth\",\"tokenId\":5,\"owner\":\"{s}\",\"expiry\":1500000,\"sender\":\"{s}\",\"registry\":\"{s}\"}}", .{ owner, owner, reg });
    try ev(database, .label_registered, "eco.eth", nh, lr, 100, 0);
    const nr = "{\"label\":\"eco\",\"tokenId\":5,\"owner\":\"0x1111111111111111111111111111111111111111\",\"duration\":31536000,\"paymentToken\":\"0x0\",\"referrer\":\"0x00000000000000000000000000000000000000000000000000000000000000aa\",\"basePrice\":123456,\"premium\":789}";
    try ev(database, .name_registered, "eco.eth", nh, nr, 100, 1);
    // EACRolesChanged (grant) then a revoke of a different account (newRoleBitmap == 0 → delete/no-op).
    const eac = try std.fmt.allocPrint(allocator, "{{\"resource\":\"{s}\",\"account\":\"{s}\",\"oldRoleBitmap\":\"0x0000000000000000000000000000000000000000000000000000000000000000\",\"newRoleBitmap\":\"0x0000000000000000000000000000000000000000000000000000000000000007\"}}", .{ nh_hex, owner });
    try ev(database, .eac_roles_changed, "eco.eth", nh, eac, 101, 2);

    try replayV2RegistrationsCore(&idx);
    try replayV2EacRolesCore(&idx);

    const one = struct {
        fn str(db: *db_module.Database, a: std.mem.Allocator, sql: []const u8) !?[]u8 {
            var qq = try Query.init(db, sql);
            defer qq.deinit();
            if (try qq.step()) {
                if (qq.getTextSlice(0)) |v| return try a.dupe(u8, v);
            }
            return null;
        }
    }.str;

    // registrations: row inserted by LabelRegistered, economics patched by NameRegistered.
    const label = try one(database, allocator, "SELECT label FROM registrations WHERE protocol='v2'");
    try std.testing.expectEqualStrings("eco", label.?);
    const base_cost = try one(database, allocator, "SELECT base_cost FROM registrations WHERE protocol='v2'");
    try std.testing.expectEqualStrings("123456", base_cost.?); // economics UPDATE landed after the INSERT
    const premium = try one(database, allocator, "SELECT premium FROM registrations WHERE protocol='v2'");
    try std.testing.expectEqualStrings("789", premium.?);

    // eac_roles: one granted role for `owner` on the resource.
    const rb = try one(database, allocator, "SELECT role_bitmap FROM eac_roles WHERE protocol='v2'");
    try std.testing.expectEqualStrings("0x0000000000000000000000000000000000000000000000000000000000000007", rb.?);
    const n = try one(database, allocator, "SELECT count(*) FROM eac_roles WHERE protocol='v2'");
    try std.testing.expectEqualStrings("1", n.?);
}

test "replayAccountsCore rebuilds accounts (V2 observations MIN-merged + backfill seed)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var cfg = @import("../config.zig").Config.fromEnv(allocator) catch return;
    cfg.status_port = null;
    cfg.webhooks_enabled = false;
    defer cfg.deinit();
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const database = try allocator.create(db_module.Database);
    database.* = try db_module.Database.init(allocator, ":memory:");
    defer {
        database.deinit();
        allocator.destroy(database);
    }
    var idx = try Indexer.init(allocator, threaded.io(), cfg, database, null);
    defer idx.deinit();

    const AA = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const BB = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const DD = "0xdddddddddddddddddddddddddddddddddddddddd";

    const ev = struct {
        fn go(db: *db_module.Database, et: models.EventType, data: []const u8, blk: u64, li: u32) !void {
            try @import("../storage/events.zig").insertEvent(db, .{
                .event_type = et,
                .protocol = .v2,
                .block_number = blk,
                .tx_hash = Hash.zero,
                .log_index = li,
                .contract_address = Address.zero,
                .name = null,
                .namehash = null,
                .data = data,
                .timestamp = 1000,
            });
        }
    }.go;

    // A observed via name_registered @100 AND eac_roles_changed @30  → MIN first_seen_block = 30.
    try ev(database, .name_registered, "{\"owner\":\"" ++ AA ++ "\",\"label\":\"acct\",\"tokenId\":1}", 100, 0);
    try ev(database, .eac_roles_changed, "{\"resource\":\"0x00\",\"account\":\"" ++ AA ++ "\",\"oldRoleBitmap\":\"0x00\",\"newRoleBitmap\":\"0x07\"}", 30, 1);
    // B observed via transfer @50.
    try ev(database, .transfer, "{\"to\":\"" ++ BB ++ "\"}", 50, 2);

    // D: owner of a seeded v2 name (backfill source, NOT event-observed) + sync head 200.
    const nh = try hash_mod2.namehash(allocator, "acct.eth");
    const lh = try hash_mod2.keccak256(allocator, "acct");
    try idx.insertName(.{
        .name = "acct.eth",
        .label = "acct",
        .label_hash = lh,
        .parent_name = "eth",
        .parent_namehash = idx.eth_namehash,
        .protocol = .v2,
        .registry = idx.getEthRegistry(.v2),
        .owner = try Address.fromHex(DD),
        .registrant = try Address.fromHex(DD),
        .resolver = Address.zero,
        .token_id = 9,
        .canonical_id = 9,
        .token_version = 0,
        .namehash = nh,
        .expiry = 0,
        .registry_locked = false,
        .migrated = false,
        .created_block = 77,
        .created_at = 4242,
        .registered_at = 4242,
        .updated_block = 77,
        .updated_at = 4242,
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    });
    try database.exec("INSERT INTO sync_state (protocol, last_synced_block, last_synced_at) VALUES ('v2', 200, 0)");

    try replayAccountsCore(&idx);

    const one = struct {
        fn str(db: *db_module.Database, a: std.mem.Allocator, sql: []const u8) !?[]u8 {
            var qq = try Query.init(db, sql);
            defer qq.deinit();
            if (try qq.step()) {
                if (qq.getTextSlice(0)) |v| return try a.dupe(u8, v);
            }
            return null;
        }
    }.str;

    try std.testing.expectEqualStrings("3", (try one(database, allocator, "SELECT count(*) FROM accounts")).?);
    // A: MIN(100, 30) = 30 (proves the MIN merge, not just last-write).
    try std.testing.expectEqualStrings("30", (try one(database, allocator, "SELECT first_seen_block FROM accounts WHERE address = '" ++ AA ++ "'")).?);
    try std.testing.expectEqualStrings("50", (try one(database, allocator, "SELECT first_seen_block FROM accounts WHERE address = '" ++ BB ++ "'")).?);
    // D: only from backfillFromExistingData → seed_block = MIN(sync head) = 200.
    try std.testing.expectEqualStrings("200", (try one(database, allocator, "SELECT first_seen_block FROM accounts WHERE address = '" ++ DD ++ "'")).?);
    try std.testing.expectEqualStrings("1", (try one(database, allocator, "SELECT seen_v2 FROM accounts WHERE address = '" ++ DD ++ "'")).?);
}

test "replayV2RegistriesCore rebuilds registries + registry_entries (bootstrap + SubregistryUpdated)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var cfg = @import("../config.zig").Config.fromEnv(allocator) catch return;
    cfg.status_port = null;
    cfg.webhooks_enabled = false;
    defer cfg.deinit();
    if (idxEthRegistryIsZero(cfg)) return; // needs a configured eth registry to bootstrap
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const database = try allocator.create(db_module.Database);
    database.* = try db_module.Database.init(allocator, ":memory:");
    defer {
        database.deinit();
        allocator.destroy(database);
    }
    var idx = try Indexer.init(allocator, threaded.io(), cfg, database, null);
    defer idx.deinit();

    const parent_reg = idx.getEthRegistry(.v2);
    if (parent_reg.isZero()) return;
    var pbuf: [42]u8 = undefined;
    const parent_hex = parent_reg.toHexBuf(&pbuf);
    const canonical: u256 = 0x100000000; // already version-stripped (lower 32 bits 0)

    // Seed the parent name so the pointer change can resolve the subregistry's name.
    const nh = try hash_mod2.namehash(allocator, "par.eth");
    const lh = try hash_mod2.keccak256(allocator, "par");
    try idx.insertName(.{
        .name = "par.eth",
        .label = "par",
        .label_hash = lh,
        .parent_name = "eth",
        .parent_namehash = idx.eth_namehash,
        .protocol = .v2,
        .registry = parent_reg,
        .owner = try Address.fromHex("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        .registrant = try Address.fromHex("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        .resolver = Address.zero,
        .token_id = canonical,
        .canonical_id = canonical,
        .token_version = 0,
        .namehash = nh,
        .expiry = 0,
        .registry_locked = false,
        .migrated = false,
        .created_block = 100,
        .created_at = 1000,
        .registered_at = 1000,
        .updated_block = 100,
        .updated_at = 1000,
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    });

    const data = try std.fmt.allocPrint(allocator, "{{\"name\":\"par.eth\",\"canonicalId\":{d},\"subregistry\":\"0x9999999999999999999999999999999999999999\",\"registry\":\"{s}\"}}", .{ canonical, parent_hex });
    try @import("../storage/events.zig").insertEvent(database, .{
        .event_type = .subregistry_updated,
        .protocol = .v2,
        .block_number = 101,
        .tx_hash = Hash.zero,
        .log_index = 0,
        .contract_address = parent_reg,
        .name = "par.eth",
        .namehash = nh,
        .data = data,
        .timestamp = 2000,
    });

    try replayV2RegistriesCore(&idx);

    const one = struct {
        fn str(db: *db_module.Database, a: std.mem.Allocator, sql: []const u8) !?[]u8 {
            var qq = try Query.init(db, sql);
            defer qq.deinit();
            if (try qq.step()) {
                if (qq.getTextSlice(0)) |v| return try a.dupe(u8, v);
            }
            return null;
        }
    }.str;

    // registry_entries: exactly one, pointing parent_reg/canonical → SUB.
    try std.testing.expectEqualStrings("1", (try one(database, allocator, "SELECT count(*) FROM registry_entries WHERE protocol='v2'")).?);
    try std.testing.expectEqualStrings("0x9999999999999999999999999999999999999999", (try one(database, allocator, "SELECT subregistry FROM registry_entries WHERE protocol='v2'")).?);
    // registries: bootstrap root+eth preserved, and the SUB row got the resolved parent name.
    try std.testing.expectEqualStrings("par.eth", (try one(database, allocator, "SELECT name FROM registries WHERE address = '0x9999999999999999999999999999999999999999'")).?);
}

fn idxEthRegistryIsZero(cfg: @import("../config.zig").Config) bool {
    return cfg.v2_contracts.eth_registry.isZero();
}

const at_block = @import("../storage/at_block.zig");

test "reconstructV2AtBlock matches truncated live replay at every lifecycle checkpoint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var cfg = @import("../config.zig").Config.fromEnv(allocator) catch return;
    cfg.status_port = null;
    cfg.webhooks_enabled = false;
    defer cfg.deinit();
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const nh = try hash_mod2.namehash(allocator, "tt.eth");
    const reg = try Address.fromHex("0x3333333333333333333333333333333333333333");
    const wrong_reg = try Address.fromHex("0x5555555555555555555555555555555555555555");
    const rsv = try Address.fromHex("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");

    // Full lifecycle. Every event gets a distinct log_index — the events UNIQUE is
    // (protocol, tx_hash, log_index) and duplicates are silently dropped.
    const Ev = struct { et: models.EventType, blk: u64, li: u32, contract: Address, data: []const u8 };
    const events = [_]Ev{
        .{ .et = .label_registered, .blk = 100, .li = 0, .contract = reg, .data = "{\"name\":\"tt.eth\",\"tokenId\":500,\"owner\":\"0x1111111111111111111111111111111111111111\",\"expiry\":1000000,\"registry\":\"0x3333333333333333333333333333333333333333\"}" },
        // Foreign-registry ResolverUpdated: same tokenId, different emitting registry -> must be a no-op.
        .{ .et = .resolver_updated, .blk = 102, .li = 1, .contract = wrong_reg, .data = "{\"tokenId\":500,\"resolver\":\"0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}" },
        .{ .et = .resolver_updated, .blk = 104, .li = 2, .contract = reg, .data = "{\"tokenId\":500,\"resolver\":\"0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}" },
        .{ .et = .address_changed, .blk = 106, .li = 3, .contract = rsv, .data = "{\"resolver\":\"0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"coinType\":60,\"address\":\"0x9999999999999999999999999999999999999999\"}" },
        .{ .et = .text_changed, .blk = 108, .li = 4, .contract = rsv, .data = "{\"resolver\":\"0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"key\":\"url\",\"value\":\"https://a\"}" },
        .{ .et = .text_changed, .blk = 110, .li = 5, .contract = rsv, .data = "{\"resolver\":\"0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"key\":\"url\",\"value\":\"\"}" },
        // Transfer carries its tokenId and is emitted BY the registry; ownership is
        // keyed on that pair, so a same-node transfer from a foreign registry is a
        // no-op exactly like the ResolverUpdated above.
        .{ .et = .transfer, .blk = 111, .li = 11, .contract = wrong_reg, .data = "{\"to\":\"0x4444444444444444444444444444444444444444\",\"id\":500,\"value\":1}" },
        .{ .et = .transfer, .blk = 112, .li = 6, .contract = reg, .data = "{\"to\":\"0x2222222222222222222222222222222222222222\",\"id\":500,\"value\":1}" },
        .{ .et = .name_renewed, .blk = 114, .li = 7, .contract = reg, .data = "{\"newExpiry\":2000000}" },
        .{ .et = .token_regenerated, .blk = 116, .li = 8, .contract = reg, .data = "{\"oldTokenId\":500,\"newTokenId\":501}" },
        .{ .et = .name_burned, .blk = 120, .li = 9, .contract = reg, .data = "{\"tokenId\":501}" },
        .{ .et = .label_registered, .blk = 124, .li = 10, .contract = reg, .data = "{\"name\":\"tt.eth\",\"tokenId\":600,\"owner\":\"0x2222222222222222222222222222222222222222\",\"expiry\":3000000,\"registry\":\"0x3333333333333333333333333333333333333333\"}" },
    };

    const seed = struct {
        fn go(db: *db_module.Database, evs: []const Ev, up_to: u64, name_nh: Hash) !void {
            for (evs) |e| {
                if (e.blk > up_to) continue;
                try @import("../storage/events.zig").insertEvent(db, .{
                    .event_type = e.et,
                    .protocol = .v2,
                    .block_number = e.blk,
                    .tx_hash = Hash.zero,
                    .log_index = e.li,
                    .contract_address = e.contract,
                    .name = "tt.eth",
                    .namehash = name_nh,
                    .data = e.data,
                    .timestamp = 1000,
                });
            }
        }
    }.go;

    // Full DB: all events + a live-replayed names table (the provenance-overlay source).
    var full_db = try db_module.Database.init(allocator, ":memory:");
    defer full_db.deinit();
    {
        var idx = try Indexer.init(allocator, io, cfg, &full_db, null);
        defer idx.deinit();
        try seed(&full_db, &events, 10_000, nh);
        try idx.replayV2NamesCore();
        try idx.replayV2RecordsCore();
    }

    // At each checkpoint: ground truth = fresh DB with events <= N replayed live.
    const checkpoints = [_]u64{ 100, 103, 105, 109, 111, 118, 121, 125 };
    for (checkpoints) |n| {
        var tdb = try db_module.Database.init(allocator, ":memory:");
        defer tdb.deinit();
        {
            var idx = try Indexer.init(allocator, io, cfg, &tdb, null);
            defer idx.deinit();
            try seed(&tdb, &events, n, nh);
            try idx.replayV2NamesCore();
            try idx.replayV2RecordsCore();
        }

        var st = try at_block.reconstructV2AtBlock(&full_db, allocator, nh, n);
        defer st.deinit();

        const expected = tdb.getNameByNamehashAndProtocol(nh, .v2) catch null;
        if (expected) |exp_row| {
            var exp = exp_row;
            defer exp.deinit(tdb.allocator);
            const got = st.name orelse return error.AtBlockMissingName;
            try std.testing.expectEqualStrings(exp.name.?, got.name.?);
            try std.testing.expectEqualStrings(exp.label.?, got.label.?);
            try std.testing.expectEqualStrings(exp.parent_name.?, got.parent_name.?);
            try std.testing.expect(exp.owner.eql(got.owner));
            try std.testing.expect(exp.registrant.eql(got.registrant));
            try std.testing.expect(exp.resolver.eql(got.resolver));
            try std.testing.expect(exp.registry.eql(got.registry));
            try std.testing.expectEqual(exp.token_id, got.token_id);
            try std.testing.expectEqual(exp.token_version, got.token_version);
            try std.testing.expectEqual(exp.expiry, got.expiry);
            try std.testing.expectEqual(exp.created_block, got.created_block);
            try std.testing.expectEqual(exp.migrated, got.migrated);
            try std.testing.expectEqual(exp.is_wrapped, got.is_wrapped);

            // Records: at-block lookups must agree with the truncated DB's tables.
            const exp_addr = tdb.getAddressRecord(rsv, nh, 60) catch null;
            const got_addr = st.lookupAddr(rsv, 60);
            if (exp_addr) |ea| {
                defer tdb.allocator.free(ea);
                try std.testing.expectEqualStrings(ea, got_addr orelse return error.AtBlockMissingAddr);
            } else {
                try std.testing.expect(got_addr == null);
            }
            const exp_text = tdb.getTextRecord(rsv, nh, "url") catch null;
            const got_text = st.lookupText(rsv, "url");
            if (exp_text) |et_| {
                defer tdb.allocator.free(et_);
                try std.testing.expectEqualStrings(et_, got_text orelse return error.AtBlockMissingText);
            } else {
                try std.testing.expect(got_text == null);
            }
        } else {
            try std.testing.expect(st.name == null); // burned / not yet registered
        }
    }
}

pub const REPLAY_VERSION: i64 = 1;

/// Clear the completion marker before a rebuild starts, so a crash mid-replay
/// can never masquerade as a finished backfill.
pub fn clearReplayStatus(self: *Indexer) !void {
    try self.database.exec("DELETE FROM replay_status");
}

/// Record a completed rebuild: the replay-logic version, the highest event
/// block covered, and the resulting names count. Refuses to mark complete if
/// creation-shaped events exist but the rebuild produced zero names.
pub fn writeReplayStatus(self: *Indexer) !void {
    const database = self.database;
    var names_count: i64 = 0;
    {
        var q = try Query.init(database, "SELECT COUNT(*) FROM names");
        defer q.deinit();
        if (try q.step()) names_count = q.getInt64(0);
    }
    var creation_events: i64 = 0;
    {
        var q = try Query.init(database, "SELECT COUNT(*) FROM events WHERE event_type IN ('NameRegistered', 'NewOwner', 'NewSubname')");
        defer q.deinit();
        if (try q.step()) creation_events = q.getInt64(0);
    }
    if (creation_events > 0 and names_count == 0) {
        std.log.err("backfill produced 0 names from {d} creation events - refusing to mark complete", .{creation_events});
        return error.BackfillIncomplete;
    }
    var completed_block: i64 = 0;
    {
        var q = try Query.init(database, "SELECT COALESCE(MAX(block_number), 0) FROM events");
        defer q.deinit();
        if (try q.step()) completed_block = q.getInt64(0);
    }
    try database.exec("DELETE FROM replay_status");
    var q = try Query.init(database, "INSERT INTO replay_status (id, replay_version, completed_block, names_count, completed_at) VALUES (1, ?, ?, ?, ?)");
    defer q.deinit();
    try q.bindInt64(REPLAY_VERSION);
    try q.bindInt64(completed_block);
    try q.bindInt64(names_count);
    try q.bindInt64(zsys.timestamp());
    try q.exec();
    std.log.info("Replay status recorded: version {d}, completed through block {d}, {d} names", .{ REPLAY_VERSION, completed_block, names_count });
}

test "replayV2RecordsCore rebuilds record-model resolvers (links, values, default, cleared) from events" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var cfg = @import("../config.zig").Config.fromEnv(allocator) catch return;
    cfg.status_port = null;
    cfg.webhooks_enabled = false;
    defer cfg.deinit();
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();

    const database = try allocator.create(db_module.Database);
    database.* = try db_module.Database.init(allocator, ":memory:");
    defer {
        database.deinit();
        allocator.destroy(database);
    }
    var idx = try Indexer.init(allocator, threaded.io(), cfg, database, null);
    defer idx.deinit();

    const carol = try hash_mod2.namehash(allocator, "carol.eth");
    const erin = try hash_mod2.namehash(allocator, "erin.eth");
    const dave = try hash_mod2.namehash(allocator, "dave.eth");
    const resolver_hex = "0xdddddddddddddddddddddddddddddddddddddddd";
    const resolver = try Address.fromHex(resolver_hex);
    const record_model = @import("../storage/resolver_records.zig");

    const ev = struct {
        fn go(db: *db_module.Database, et: models.EventType, nh: ?Hash, data: []const u8, li: u32) !void {
            try @import("../storage/events.zig").insertEvent(db, .{
                .event_type = et,
                .protocol = .v2,
                .block_number = 300,
                .tx_hash = Hash.zero,
                .log_index = li,
                .contract_address = Address.zero,
                .name = null,
                .namehash = nh,
                .data = data,
                .timestamp = 1000,
            });
        }
    }.go;

    const carol_hex = try carol.toHex(allocator);
    const erin_hex = try erin.toHex(allocator);
    const zero_hex = try Hash.zero.toHex(allocator);
    // The exact event_data shapes the record handlers emit.
    try ev(database, .resolver_created, null, try std.fmt.allocPrint(allocator, "{{\"resolver\":\"{s}\"}}", .{resolver_hex}), 0);
    try ev(database, .linked, carol, try std.fmt.allocPrint(allocator, "{{\"resolver\":\"{s}\",\"recordId\":1,\"node\":\"{s}\",\"name\":\"carol.eth\"}}", .{ resolver_hex, carol_hex }), 1);
    try ev(database, .text_updated, record_model.recordKey(1), try std.fmt.allocPrint(allocator, "{{\"resolver\":\"{s}\",\"recordId\":1,\"key\":\"avatar\",\"value\":\"he said \\\"hi\\\"\"}}", .{resolver_hex}), 2);
    try ev(database, .address_updated, record_model.recordKey(1), try std.fmt.allocPrint(allocator, "{{\"resolver\":\"{s}\",\"recordId\":1,\"coinType\":60,\"address\":\"0x00000000000000000000000000000000000000ab\"}}", .{resolver_hex}), 3);
    try ev(database, .contenthash_updated, record_model.recordKey(1), try std.fmt.allocPrint(allocator, "{{\"resolver\":\"{s}\",\"recordId\":1,\"contentHash\":\"0xe30101701220ab\"}}", .{resolver_hex}), 4);
    try ev(database, .data_updated, record_model.recordKey(1), try std.fmt.allocPrint(allocator, "{{\"resolver\":\"{s}\",\"recordId\":1,\"key\":\"blob\",\"value\":\"0xdead\"}}", .{resolver_hex}), 5);
    try ev(database, .name_updated, record_model.recordKey(1), try std.fmt.allocPrint(allocator, "{{\"resolver\":\"{s}\",\"recordId\":1,\"name\":\"carol.eth\"}}", .{resolver_hex}), 6);
    try ev(database, .abi_updated, record_model.recordKey(1), try std.fmt.allocPrint(allocator, "{{\"resolver\":\"{s}\",\"recordId\":1,\"contentType\":1}}", .{resolver_hex}), 7);
    try ev(database, .interface_updated, record_model.recordKey(1), try std.fmt.allocPrint(allocator, "{{\"resolver\":\"{s}\",\"recordId\":1,\"interfaceID\":\"0x01ffc9a7\",\"implementer\":\"0x2222222222222222222222222222222222222222\"}}", .{resolver_hex}), 8);
    // erin shares record 1; the default record 2 gets a url; record 3 is cleared after a write.
    try ev(database, .linked, erin, try std.fmt.allocPrint(allocator, "{{\"resolver\":\"{s}\",\"recordId\":1,\"node\":\"{s}\",\"name\":\"erin.eth\"}}", .{ resolver_hex, erin_hex }), 9);
    try ev(database, .linked, Hash.zero, try std.fmt.allocPrint(allocator, "{{\"resolver\":\"{s}\",\"recordId\":2,\"node\":\"{s}\",\"name\":\"\"}}", .{ resolver_hex, zero_hex }), 10);
    try ev(database, .text_updated, record_model.recordKey(2), try std.fmt.allocPrint(allocator, "{{\"resolver\":\"{s}\",\"recordId\":2,\"key\":\"url\",\"value\":\"https://default\"}}", .{resolver_hex}), 11);
    try ev(database, .text_updated, record_model.recordKey(3), try std.fmt.allocPrint(allocator, "{{\"resolver\":\"{s}\",\"recordId\":3,\"key\":\"gone\",\"value\":\"x\"}}", .{resolver_hex}), 12);
    try ev(database, .cleared, record_model.recordKey(3), try std.fmt.allocPrint(allocator, "{{\"resolver\":\"{s}\",\"recordId\":3}}", .{resolver_hex}), 13);
    // A clearing write (empty value) must delete, not store.
    try ev(database, .text_updated, record_model.recordKey(2), try std.fmt.allocPrint(allocator, "{{\"resolver\":\"{s}\",\"recordId\":2,\"key\":\"tmp\",\"value\":\"v\"}}", .{resolver_hex}), 14);
    try ev(database, .text_updated, record_model.recordKey(2), try std.fmt.allocPrint(allocator, "{{\"resolver\":\"{s}\",\"recordId\":2,\"key\":\"tmp\",\"value\":\"\"}}", .{resolver_hex}), 15);

    try replayV2RecordsCore(&idx);

    const kind = (try database.getResolverKind(resolver)).?;
    defer database.allocator.free(kind);
    try std.testing.expectEqualStrings("record", kind);
    // Shared record, unescaped value, through the link indirection.
    const carol_avatar = (try database.getTextRecord(resolver, carol, "avatar")).?;
    defer database.allocator.free(carol_avatar);
    try std.testing.expectEqualStrings("he said \"hi\"", carol_avatar);
    const erin_avatar = (try database.getTextRecord(resolver, erin, "avatar")).?;
    defer database.allocator.free(erin_avatar);
    try std.testing.expectEqualStrings("he said \"hi\"", erin_avatar);
    const addr = (try database.getAddressRecord(resolver, erin, 60)).?;
    defer database.allocator.free(addr);
    try std.testing.expectEqualStrings("0x00000000000000000000000000000000000000ab", addr);
    const ch = (try database.getContentHashRecord(resolver, carol)).?;
    defer database.allocator.free(ch);
    try std.testing.expectEqualStrings("0xe30101701220ab", ch);
    const blob = (try database.getDataRecord(resolver, carol, "blob")).?;
    defer database.allocator.free(blob);
    try std.testing.expectEqualStrings("0xdead", blob);
    const primary = (try database.getLatestNameByNamehash(carol)).?;
    defer database.allocator.free(primary);
    try std.testing.expectEqualStrings("carol.eth", primary);
    const abis = try database.getAbiContentTypes(resolver, carol);
    defer database.allocator.free(abis);
    try std.testing.expectEqual(@as(usize, 1), abis.len);
    const ifaces = try database.getInterfaceRecords(resolver, carol);
    defer {
        for (ifaces) |*i| i.deinit(database.allocator);
        database.allocator.free(ifaces);
    }
    try std.testing.expectEqual(@as(usize, 1), ifaces.len);
    // Default record serves unlinked names; cleared record 3 has nothing; tmp was deleted.
    const dave_url = (try database.getTextRecord(resolver, dave, "url")).?;
    defer database.allocator.free(dave_url);
    try std.testing.expectEqualStrings("https://default", dave_url);
    try std.testing.expectEqual(@as(?[]u8, null), try database.getTextRecord(resolver, dave, "tmp"));
    var q = try Query.init(database, "SELECT COUNT(*) FROM resolver_texts WHERE key = 'gone'");
    defer q.deinit();
    try std.testing.expect(try q.step());
    try std.testing.expectEqual(@as(i64, 0), q.getInt64(0));
    try std.testing.expectEqual(@as(?u256, 1), try database.getEffectiveRecordId(resolver, erin));
    try std.testing.expectEqual(@as(?u256, 2), try database.getEffectiveRecordId(resolver, dave));
}
