const std = @import("std");
const zsys = @import("../../utils/system.zig");
const models = @import("../../types/models.zig");
const db = @import("../../storage/database.zig");
const Query = db.Query;
const Hash = @import("../../types/hash.zig").Hash;
const Address = @import("../../types/address.zig").Address;
const names_storage = @import("../../storage/names.zig");
const v1_names = @import("../../utils/v1_names.zig");
const LabelBackfill = @import("../label_backfill.zig").LabelBackfill;
const Indexer = @import("../indexer.zig").Indexer;

/// Backfill pre-migration names with labels from v1_labels table
/// This runs once after initial sync completes and v1_labels is populated
pub fn backfillPreMigrationNames(self: *Indexer) !void {
    // Check if backfill already completed
    {
        var check_q = Query.init(self.database, "SELECT completed FROM backfill_status WHERE task = 'pre_migration_names'") catch |err| {
            std.log.warn("Failed to check backfill status: {}", .{err});
            return;
        };
        defer check_q.deinit();
        if (try check_q.step()) {
            if (check_q.getInt(0) == 1) {
                std.log.info("Pre-migration names backfill already completed, skipping", .{});
                return;
            }
        }
    }

    std.log.info("Starting pre-migration names backfill...", .{});

    // Query to join temp_pre_migration_names with v1_labels to resolve labels.
    // Only .eth-parented rows are reconstructible from a bare label: the Name
    // below is built as `<label>.eth` with its namehash recomputed against the
    // .eth node, so a temp row with any other parent (cross-parent labelhash
    // matches are possible) would be silently mis-attributed to `.eth`.
    const query_sql =
        \\SELECT t.namehash, t.label_hash, t.parent_node, t.owner, t.block_number,
        \\       t.tx_hash, t.log_index, t.created_at, v.label
        \\FROM temp_pre_migration_names t
        \\JOIN v1_labels v ON t.label_hash = v.token_id
        \\WHERE t.parent_node = '0x93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae'
    ;

    var q = try Query.init(self.database, query_sql);
    defer q.deinit();

    var count: usize = 0;
    while (try q.step()) {
        // Extract row data
        const block_number = q.getInt64(4);
        _ = q.getInt64(6); // log_index - not needed for name creation
        const created_at = q.getInt64(7);

        if (q.isNull(0) or q.isNull(1) or q.isNull(2) or
            q.isNull(3) or q.isNull(5) or q.isNull(8))
        {
            std.log.warn("Skipping row with null value in backfill", .{});
            continue;
        }

        const label = q.getTextSlice(8).?;
        const label_hash_str = q.getTextSlice(1).?;
        const owner_str = q.getTextSlice(3).?;

        // Allocate strings that will be owned by the Name struct
        const full_name = try std.fmt.allocPrint(self.allocator, "{s}.eth", .{label});
        errdefer self.allocator.free(full_name);

        const label_copy = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(label_copy);

        const parent_name_copy = try self.allocator.dupe(u8, "eth");
        errdefer self.allocator.free(parent_name_copy);

        // Compute hashes
        const namehash = v1_names.computeEthNamehash(label);
        const label_hash = v1_names.computeLabelHash(label);

        // ETH node hash (parent)
        const parent_namehash = try Hash.fromHex("93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae");

        // Parse addresses
        const owner = try Address.fromHex(owner_str);

        // ENS Registry contract address (where these NewOwner events came from)
        const registry = try Address.fromHex("00000000000C2E074eC69A0dFb2997BA6C7d2e1e");

        // Parse token_id from label_hash hex string to u256
        const token_id = try std.fmt.parseInt(u256, if (std.mem.startsWith(u8, label_hash_str, "0x")) label_hash_str[2..] else label_hash_str, 16);

        // Canonical ID is token_id with lower 32 bits cleared (for V1, just use token_id)
        const canonical_id = token_id;

        // V1 label hash for backfilling
        const v1_label_hash = try self.allocator.dupe(u8, label_hash_str);
        errdefer self.allocator.free(v1_label_hash);

        // Create the name entry
        var name = models.Name{
            .protocol = .v1,
            .name = full_name,
            .namehash = namehash,
            .label = label_copy,
            .label_hash = label_hash,
            .parent_name = parent_name_copy,
            .parent_namehash = parent_namehash,
            .registry = registry,
            .owner = owner,
            .registrant = owner, // Original registrant from backfilled data
            .resolver = Address.zero,
            .token_id = token_id,
            .canonical_id = canonical_id,
            .token_version = 1,
            .expiry = 0,
            .registry_locked = false,
            .migrated = false,
            .created_block = @intCast(block_number),
            .created_at = @intCast(created_at),
            .registered_at = @intCast(created_at),
            .updated_block = @intCast(block_number),
            .updated_at = @intCast(created_at),
            .is_wrapped = false,
            .wrapper_fuses = null,
            .wrapper_expiry = null,
            .is_v1_name = true,
            .v1_label_hash = v1_label_hash,
            // Provenance: every temp_pre_migration_names row came from the
            // legacy 0x314159 registry (the only pre-migration fetch source);
            // the default false mislabeled backfilled rows as new-registry.
            .is_legacy = true,
        };

        // Check if name already exists (from V1 events processed during sync)
        const existing_name = names_storage.getNameByNamehash(self.database, namehash) catch null;

        if (existing_name) |existing| {
            // Free the existing name record (we only needed to check existence)
            var existing_copy = existing;
            existing_copy.deinit(self.allocator);
            // Name exists from V1 events - only update creation date if ours is earlier
            names_storage.updateNameCreationDateIfEarlier(
                self.database,
                namehash,
                @intCast(block_number),
                @intCast(created_at),
            ) catch |err| {
                std.log.warn("Failed to update creation date for {s}: {}", .{ full_name, err });
                name.deinit(self.allocator);
                continue;
            };
            std.log.debug("Updated creation date for existing name: {s}", .{full_name});
        } else {
            // Name doesn't exist - create it
            self.insertName(name) catch |err| {
                std.log.warn("Failed to backfill name {s}: {}", .{ name.name.?, err });
                name.deinit(self.allocator);
                continue;
            };
            std.log.debug("Created new name from backfill: {s}", .{full_name});
        }

        // Record migration history entry
        const tx_hash_str = q.getTextSlice(5).?;
        const namehash_hex = try namehash.toHex(self.allocator);

        history: {
            const hsql = self.database.upsertExprSql(
                self.database.allocator,
                "name_history",
                &.{ "protocol", "namehash", "name", "change_type", "old_value", "new_value", "block_number", "tx_hash", "log_index", "timestamp" },
                &.{ "?", "?", "?", "'migration'", "NULL", "'Migrated from temporary registrar'", "?", "?", "0", "?" },
                .ignore,
            ) catch break :history;
            defer self.database.allocator.free(hsql);
            var hq = Query.init(self.database, hsql) catch break :history;
            defer hq.deinit();
            hq.bindText("v1") catch break :history;
            hq.bindText(namehash_hex) catch break :history;
            hq.bindText(full_name) catch break :history;
            hq.bindInt64(@intCast(block_number)) catch break :history;
            hq.bindText(tx_hash_str) catch break :history;
            hq.bindInt64(created_at) catch break :history;
            hq.exec() catch {
                std.log.warn("Failed to insert migration history for {s}", .{full_name});
            };
        }

        self.allocator.free(namehash_hex);

        // Free allocated memory
        name.deinit(self.allocator);

        count += 1;
        if (count % 100 == 0) {
            std.log.info("Backfilled {d} pre-migration names...", .{count});
        }
    }

    std.log.info("Pre-migration names backfill complete: {d} names created", .{count});

    // Mark backfill as completed
    mark: {
        const msql = self.database.upsertExprSql(
            self.database.allocator,
            "backfill_status",
            &.{ "task", "completed", "completed_at", "records_processed" },
            &.{ "'pre_migration_names'", "1", "?", "?" },
            .replace,
        ) catch break :mark;
        defer self.database.allocator.free(msql);
        var mq = Query.init(self.database, msql) catch break :mark;
        defer mq.deinit();
        mq.bindInt64(zsys.timestamp()) catch break :mark;
        mq.bindInt64(@intCast(count)) catch break :mark;
        mq.exec() catch {};
    }
}

/// Retroactive recovery for .eth 2LD names that were missed during initial indexing.
/// When BaseRegistrar NameRegistered fires before the ETH Controller event (cross-chunk race),
/// the handler stores the event but skips name creation because the label isn't in v1_labels yet.
/// Once the label is later resolved (by ETH Controller NameRegistered/NameRenewed), this function
/// finds v1_labels entries without corresponding name records and creates them.
pub fn backfillMissingEth2LDNames(self: *Indexer) !void {
    // Idempotent: rerun on every sync-complete to catch chunk-boundary races at the indexing head.
    std.log.info("Starting missing .eth 2LD names backfill...", .{});

    // Find v1_labels entries that don't have a corresponding name record
    const query_sql =
        \\SELECT l.token_id, l.label, l.namehash, l.first_seen_block, l.first_seen_tx, l.source
        \\FROM v1_labels l
        \\LEFT JOIN names n ON l.namehash = n.namehash
        \\WHERE n.namehash IS NULL
    ;

    var q = try Query.init(self.database, query_sql);
    defer q.deinit();

    var total_found: usize = 0;
    var created_count: usize = 0;
    const tx = @import("../../storage/transactions.zig");

    // Use transaction for bulk insert speed (individual auto-commits are very slow)
    try tx.beginTransaction(self.database);

    while (try q.step()) {
        const token_id_str = q.getTextSlice(0) orelse continue;
        const label = q.getTextSlice(1) orelse continue;
        const namehash_hex = q.getTextSlice(2) orelse continue;
        const first_seen_block = q.getInt64(3);

        total_found += 1;

        // Verify this is an .eth 2LD by checking the namehash matches computeEthNamehash(label)
        const computed_namehash = v1_names.computeChildNamehash(self.root_node, label);
        const stored_namehash = Hash.fromHex(namehash_hex) catch continue;

        if (!std.mem.eql(u8, &computed_namehash.bytes, &stored_namehash.bytes)) {
            // Not an .eth 2LD (subdomain with different parent) - skip
            continue;
        }

        // This is an .eth 2LD - try to find owner and expiry from events table
        var owner = Address.zero;
        var expiry: u64 = 0;
        var reg_timestamp: i64 = zsys.timestamp();
        var reg_block: i64 = first_seen_block;

        // Look up registration event for this name (ETH Controller events have namehash set)
        event_lookup: {
            var eq = Query.init(self.database,
                \\SELECT json_extract(data, '$.owner'), json_extract(data, '$.expires'),
                \\       timestamp, block_number
                \\FROM events
                \\WHERE namehash = ? AND event_type = 'name_registered' AND protocol = 'v1'
                \\ORDER BY block_number ASC
                \\LIMIT 1
            ) catch {
                std.log.debug("Failed to query events for owner/expiry, using defaults", .{});
                break :event_lookup;
            };
            defer eq.deinit();
            eq.bindText(namehash_hex) catch break :event_lookup;

            if (eq.step() catch null) |_| {
                if (eq.getTextSlice(0)) |owner_hex| {
                    owner = Address.fromHex(owner_hex) catch Address.zero;
                }
                if (eq.getOptionalInt64(1)) |exp| {
                    expiry = @bitCast(exp);
                }
                reg_timestamp = eq.getInt64(2);
                reg_block = eq.getInt64(3);
            }
        }

        // Parse token_id from hex string to u256
        const clean_token_id = if (std.mem.startsWith(u8, token_id_str, "0x")) token_id_str[2..] else token_id_str;
        const token_id = std.fmt.parseInt(u256, clean_token_id, 16) catch continue;

        // Compute derived values
        const label_hash = v1_names.computeLabelHash(label);
        const parent_namehash = self.root_node;
        const registry = self.config.v1_contracts.ens_registry;

        // Allocate owned strings for the Name struct
        const full_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ label, self.root_name });
        const label_copy = try self.allocator.dupe(u8, label);
        const parent_name_copy = try self.allocator.dupe(u8, self.root_name);
        const v1_label_hash = try self.allocator.dupe(u8, token_id_str);

        var name = models.Name{
            .protocol = .v1,
            .name = full_name,
            .namehash = stored_namehash,
            .label = label_copy,
            .label_hash = label_hash,
            .parent_name = parent_name_copy,
            .parent_namehash = parent_namehash,
            .registry = registry,
            .owner = owner,
            .registrant = owner,
            .resolver = Address.zero,
            .token_id = token_id,
            .canonical_id = token_id, // V1 doesn't use versioning
            // Match the LIVE registrar path and the replay arm, which both write
            // token_version = 0 for registrar 2LDs — a heal-created row must be
            // byte-identical to the row live indexing would have produced. (The
            // pre-migration backfill above keeps 1 for its temp-registrar rows.)
            .token_version = 0,
            .expiry = expiry,
            .registry_locked = false,
            .migrated = false,
            .created_block = @intCast(reg_block),
            .created_at = reg_timestamp,
            .registered_at = reg_timestamp,
            .updated_block = @intCast(reg_block),
            .updated_at = zsys.timestamp(),
            .is_wrapped = false,
            .wrapper_fuses = null,
            .wrapper_expiry = null,
            .is_v1_name = true,
            .v1_label_hash = v1_label_hash,
        };
        defer name.deinit(self.allocator);

        self.insertName(name) catch |err| {
            std.log.warn("Failed to create missing .eth 2LD name {s}: {}", .{ full_name, err });
            continue;
        };

        std.log.debug("Created missing .eth 2LD name: {s}", .{full_name});
        created_count += 1;

        if (created_count % 50_000 == 0) {
            // Periodic commit to bound WAL size (cursor stays valid within same connection)
            tx.commitTransaction(self.database) catch |err| {
                std.log.err("Failed to commit batch: {}", .{err});
            };
            try tx.beginTransaction(self.database);
            std.log.info("Created {d} missing .eth 2LD names...", .{created_count});
        } else if (created_count % 1000 == 0) {
            std.log.info("Created {d} missing .eth 2LD names...", .{created_count});
        }
    }

    // Commit final batch
    tx.commitTransaction(self.database) catch |err| {
        std.log.err("Failed to commit final batch: {}", .{err});
    };

    std.log.info("Missing .eth 2LD backfill complete: found {d} labels without names, created {d} records", .{ total_found, created_count });
}

/// Backfill unknown subdomain labels from transaction calldata
/// This runs after initial sync completes to resolve labels that weren't in events
pub fn backfillUnknownLabels(self: *Indexer) !void {
    // Get statistics first
    var label_backfill = LabelBackfill.init(self.allocator, self.v1_client, self.database, if (self.rainbow != null) &self.rainbow.? else null);
    const stats = try label_backfill.getStats();

    if (stats.total == 0) {
        std.log.info("No unknown labels to backfill", .{});
        return;
    }

    std.log.info("Starting unknown labels backfill...", .{});
    std.log.info("  Total unknown labels: {d}", .{stats.total});
    std.log.info("  Pending (0 attempts): {d}", .{stats.pending});
    std.log.info("  Retrying (1-2 attempts): {d}", .{stats.retrying});
    std.log.info("  Failed (3+ attempts): {d}", .{stats.failed});

    const resolved = try label_backfill.backfillAll();

    std.log.info("Unknown labels backfill complete: {d} labels resolved", .{resolved});

    // Get final stats
    const final_stats = try label_backfill.getStats();
    if (final_stats.total > 0) {
        std.log.warn("  Remaining unknown labels: {d}", .{final_stats.total});
        std.log.warn("  Failed after 3 attempts: {d}", .{final_stats.failed});
    }
}
