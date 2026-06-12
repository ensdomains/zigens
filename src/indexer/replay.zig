/// Replay module — rebuilds the `names` table from stored events.
///
/// Used by `--backfill` CLI mode: clears names, replays all events in order,
/// and re-derives name records using the same storage functions as live indexing.
const std = @import("std");
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

const Keccak256 = std.crypto.hash.sha3.Keccak256;

/// Commit interval: flush transaction every N events
const COMMIT_INTERVAL: u64 = 100_000;

/// The replay SQL query — extracts fields from JSON in SQL to avoid per-row JSON parsing in Zig.
const REPLAY_SQL =
    \\SELECT event_type, protocol, block_number, tx_hash, log_index,
    \\       contract_address, name, namehash, timestamp,
    \\       json_extract(data, '$.parentNode'),
    \\       json_extract(data, '$.labelhash'),
    \\       json_extract(data, '$.subdomain'),
    \\       json_extract(data, '$.owner'),
    \\       json_extract(data, '$.node'),
    \\       json_extract(data, '$.resolver'),
    \\       json_extract(data, '$.from'),
    \\       json_extract(data, '$.to'),
    \\       json_extract(data, '$.tokenId'),
    \\       json_extract(data, '$.id'),
    \\       json_extract(data, '$.expires'),
    \\       json_extract(data, '$.fuses'),
    \\       json_extract(data, '$.expiry'),
    \\       json_extract(data, '$.name'),
    \\       json_extract(data, '$.address')
    \\FROM events WHERE protocol = 'v1' AND json_valid(data)
    \\ORDER BY block_number ASC, log_index ASC
;

// Column indices for the replay query
const COL_EVENT_TYPE = 0;
const COL_CHAIN = 1;
const COL_BLOCK_NUMBER = 2;
const COL_TX_HASH = 3;
const COL_LOG_INDEX = 4;
const COL_CONTRACT_ADDRESS = 5;
const COL_NAME = 6;
const COL_NAMEHASH = 7;
const COL_TIMESTAMP = 8;
const COL_PARENT_NODE = 9;
const COL_LABELHASH = 10;
const COL_SUBDOMAIN = 11;
const COL_OWNER = 12;
const COL_NODE = 13;
const COL_RESOLVER = 14;
const COL_FROM = 15;
const COL_TO = 16;
const COL_TOKEN_ID = 17;
const COL_ID = 18;
const COL_EXPIRES = 19;
const COL_FUSES = 20;
const COL_EXPIRY = 21;
const COL_JSON_NAME = 22;
const COL_ADDRESS = 23;

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
    // insertName's upsert needs) — and the reorg triggers (no cursor is armed
    // during replay, so the bulk DELETE captures nothing). Bulk-load speed is
    // preserved by the dropNamesIndexes/createNamesIndexes pair below.
    std.log.info("Clearing names table...", .{});
    try database.exec("DELETE FROM names");
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
    try database.exec("BEGIN TRANSACTION");

    var q = try Query.init(database, REPLAY_SQL);
    defer q.deinit();

    var processed: u64 = 0;
    var errors: u64 = 0;
    const start_time = std.time.milliTimestamp();

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
            const elapsed_s = @divFloor(std.time.milliTimestamp() - start_time, 1000);
            const rate = if (elapsed_s > 0) @divFloor(processed, @as(u64, @intCast(elapsed_s))) else processed;
            const pct = if (total_events > 0) @divFloor(processed * 100, total_events) else 100;
            std.log.info("Replay progress: {d}/{d} ({d}%) — {d} events/s — {d} errors", .{
                processed, total_events, pct, rate, errors,
            });
        }
    }

    try database.exec("COMMIT");
    const elapsed_s = @divFloor(std.time.milliTimestamp() - start_time, 1000);
    std.log.info("Replay complete: {d} events processed, {d} errors, {d}s elapsed", .{
        processed, errors, elapsed_s,
    });

    // ── Step 7: Recreate names indexes ──
    std.log.info("Recreating names indexes...", .{});
    try createNamesIndexes(database);

    // Reinstall reorg undo-log triggers: DROP TABLE names (step 5) also dropped its
    // triggers. Idempotent for the other protected tables. Replay itself sets no
    // cursor, so the bulk rebuild above captured nothing.
    try reorg_undo.installTriggers(database);

    // ── Step 8: Post-replay backfill passes ──
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

    const cfg = self.config.v1_contracts;

    // ── Registry events ──
    if (contract.eql(cfg.ens_registry)) {
        if (std.mem.eql(u8, event_type_str, "transfer")) {
            // Discriminate NewOwner (parentNode present) vs RegistryTransfer (node present)
            if (q.getTextSlice(COL_PARENT_NODE) != null) {
                try replayNewOwner(self, q);
            } else if (q.getTextSlice(COL_NODE) != null) {
                try replayRegistryTransfer(self, q);
            }
        } else if (std.mem.eql(u8, event_type_str, "resolver_update")) {
            if (q.getTextSlice(COL_RESOLVER) != null) {
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
            if (q.getTextSlice(COL_FUSES) != null) {
                try replayNameWrapped(self, q);
            } else {
                try replayNameUnwrapped(self, q);
            }
        } else if (std.mem.eql(u8, event_type_str, "resolver_update")) {
            if (q.getTextSlice(COL_FUSES) != null) {
                try replayFusesSet(self, q);
            }
        } else if (std.mem.eql(u8, event_type_str, "name_renewed")) {
            if (q.getTextSlice(COL_NODE) != null) {
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
    const parent_hex = q.getTextSlice(COL_PARENT_NODE) orelse return;
    const labelhash_hex = q.getTextSlice(COL_LABELHASH) orelse return;
    const owner_hex = q.getTextSlice(COL_OWNER) orelse return;
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
    if (parent_node.eql(constants.WellKnown.eth_namehash)) return;

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
            label_is_allocated = true;
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
        try names_storage.updateNameOwner(self.database, subdomain_namehash, owner);
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
    const node_hex = q.getTextSlice(COL_NODE) orelse return;
    const owner_hex = q.getTextSlice(COL_OWNER) orelse return;

    const node = try Hash.fromHex(node_hex);
    const owner = try Address.fromHex(owner_hex);

    names_storage.updateNameOwner(self.database, node, owner) catch {};
}

/// Replay NewResolver: update resolver by namehash.
fn replayNewResolver(self: *Indexer, q: *Query) !void {
    const node_hex = q.getTextSlice(COL_NODE) orelse return;
    const resolver_hex = q.getTextSlice(COL_RESOLVER) orelse return;

    const node = try Hash.fromHex(node_hex);
    const resolver = try Address.fromHex(resolver_hex);

    names_storage.updateNameResolver(self.database, node, resolver) catch {};
}

/// Replay ERC721Transfer: look up label by tokenId, update owner.
fn replayERC721Transfer(self: *Indexer, q: *Query) !void {
    const to_hex = q.getTextSlice(COL_TO) orelse return;
    const token_id_str = q.getTextSlice(COL_TOKEN_ID) orelse return;

    const to = try Address.fromHex(to_hex);

    // Normalize tokenId to hex format for cache lookup
    const token_id_hex = normalizeTokenId(self.allocator, token_id_str) catch return;
    defer self.allocator.free(token_id_hex);

    // Look up label from cache
    if (try self.getCachedV1Label(token_id_hex)) |label| {
        const namehash = v1_names.computeEthNamehash(label);
        names_storage.updateNameOwner(self.database, namehash, to) catch {};
    }
    // If label not found, skip (same as live indexing)
}

/// Replay BaseRegistrar NameRegistered: create .eth 2LD name.
fn replayBaseRegistrarNameReg(self: *Indexer, q: *Query) !void {
    const id_str = q.getTextSlice(COL_ID) orelse return;
    const owner_hex = q.getTextSlice(COL_OWNER) orelse return;
    const block_number: u64 = @intCast(q.getInt64(COL_BLOCK_NUMBER));
    const timestamp = q.getInt64(COL_TIMESTAMP);

    const owner = try Address.fromHex(owner_hex);

    // Parse expires
    const expires_str = q.getTextSlice(COL_EXPIRES);
    const expires: u64 = if (expires_str) |es|
        std.fmt.parseInt(u64, es, 10) catch 0
    else
        0;

    // Convert id to token_id hex format for cache lookup
    // The id in the event JSON may be a decimal string or hex
    const token_id_hex = normalizeTokenId(self.allocator, id_str) catch return;
    defer self.allocator.free(token_id_hex);

    // Look up label from cache
    const maybe_label = try self.getCachedV1Label(token_id_hex);

    if (maybe_label) |label| {
        const full_name = try std.fmt.allocPrint(self.allocator, "{s}.eth", .{label});
        const namehash = v1_names.computeEthNamehash(label);
        const label_hash = v1_names.computeLabelHash(label);
        const eth_node = try Hash.fromHex("93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae");

        var label_hash_buf: [66]u8 = undefined;
        const v1_label_hash_hex = label_hash.toHexBuf(&label_hash_buf);

        // Parse token_id to u256
        const clean_hex = if (std.mem.startsWith(u8, token_id_hex, "0x")) token_id_hex[2..] else token_id_hex;
        const token_id_u256 = std.fmt.parseInt(u256, clean_hex, 16) catch 0;

        const name_record = models.Name{
            .name = full_name,
            .namehash = namehash,
            .label = label,
            .label_hash = label_hash,
            .parent_name = "eth",
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
    const id_str = q.getTextSlice(COL_ID) orelse return;

    const expires_str = q.getTextSlice(COL_EXPIRES);
    const expires: u64 = if (expires_str) |es|
        std.fmt.parseInt(u64, es, 10) catch 0
    else
        0;

    const token_id_hex = normalizeTokenId(self.allocator, id_str) catch return;
    defer self.allocator.free(token_id_hex);

    if (try self.getCachedV1Label(token_id_hex)) |label| {
        const namehash = v1_names.computeEthNamehash(label);
        names_storage.updateV1RenewalExpiry(self.database, namehash, expires) catch {};
    }
}

/// Replay NameWrapped: update wrapper state + owner.
fn replayNameWrapped(self: *Indexer, q: *Query) !void {
    const node_hex = q.getTextSlice(COL_NODE) orelse
        q.getTextSlice(COL_NAMEHASH) orelse return;
    const owner_hex = q.getTextSlice(COL_OWNER) orelse return;
    const fuses_str = q.getTextSlice(COL_FUSES) orelse return;
    const expiry_str = q.getTextSlice(COL_EXPIRY);

    const node = try Hash.fromHex(node_hex);
    const owner = try Address.fromHex(owner_hex);
    const fuses: u32 = std.fmt.parseInt(u32, fuses_str, 10) catch 0;
    const expiry: u64 = if (expiry_str) |es|
        std.fmt.parseInt(u64, es, 10) catch 0
    else
        0;

    names_storage.updateNameWrapperState(self.database, node, fuses, expiry) catch {};
    names_storage.updateNameOwner(self.database, node, owner) catch {};
}

/// Replay NameUnwrapped: clear wrapper state + update owner.
fn replayNameUnwrapped(self: *Indexer, q: *Query) !void {
    const node_hex = q.getTextSlice(COL_NODE) orelse
        q.getTextSlice(COL_NAMEHASH) orelse return;
    const owner_hex = q.getTextSlice(COL_OWNER) orelse return;

    const node = try Hash.fromHex(node_hex);
    const owner = try Address.fromHex(owner_hex);

    names_storage.updateNameUnwrapperState(self.database, node) catch {};
    names_storage.updateNameOwner(self.database, node, owner) catch {};
}

/// Replay FusesSet: update wrapper fuses.
fn replayFusesSet(self: *Indexer, q: *Query) !void {
    const node_hex = q.getTextSlice(COL_NODE) orelse
        q.getTextSlice(COL_NAMEHASH) orelse return;
    const fuses_str = q.getTextSlice(COL_FUSES) orelse return;

    const node = try Hash.fromHex(node_hex);
    const fuses: u32 = std.fmt.parseInt(u32, fuses_str, 10) catch 0;

    names_storage.updateNameWrapperFuses(self.database, node, fuses) catch {};
}

/// Replay ExpiryExtended: update wrapper expiry.
fn replayExpiryExtended(self: *Indexer, q: *Query) !void {
    const node_hex = q.getTextSlice(COL_NODE) orelse return;
    const expiry_str = q.getTextSlice(COL_EXPIRY) orelse return;

    const node = try Hash.fromHex(node_hex);
    const expiry: u64 = std.fmt.parseInt(u64, expiry_str, 10) catch 0;

    names_storage.updateNameWrapperExpiry(self.database, node, expiry) catch {};
}

/// Replay ETH Controller NameRegistered: store label in v1_labels + cache.
fn replayETHControllerNameReg(self: *Indexer, q: *Query) !void {
    const name_str = q.getTextSlice(COL_JSON_NAME) orelse return;

    // Compute label hash from plaintext name (the JSON stores it as "label" key, not "labelhash")
    const label_hash = v1_names.computeLabelHash(name_str);
    var label_hash_buf: [66]u8 = undefined;
    const label_hash_hex = label_hash.toHexBuf(&label_hash_buf);

    const namehash = v1_names.computeEthNamehash(name_str);
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

/// Normalize a token ID string to the 0x-prefixed hex format used by getCachedV1Label.
/// Handles both decimal strings (e.g. "12345") and hex strings (e.g. "0xabcd...").
fn normalizeTokenId(allocator: std.mem.Allocator, id_str: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, id_str, "0x")) {
        return try allocator.dupe(u8, id_str);
    }
    // Try parsing as decimal, convert to 0x-prefixed hex
    const value = std.fmt.parseInt(u256, id_str, 10) catch {
        // Not decimal, try as raw hex
        return try std.fmt.allocPrint(allocator, "0x{s}", .{id_str});
    };
    var bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &bytes, value, .big);
    return try (Hash{ .bytes = bytes }).toHex(allocator);
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
    const timer = std.time.milliTimestamp();
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
    const elapsed = std.time.milliTimestamp() - timer;
    std.log.info("Names indexes created in {d}ms", .{elapsed});
}
