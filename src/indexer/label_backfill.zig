const std = @import("std");
const ens_name = @import("../utils/ens_name.zig");
const rpc = @import("../rpc/client.zig");
const db_module = @import("../storage/database.zig");
const unknown_labels_storage = @import("../storage/unknown_labels.zig");
const v1_names = @import("../utils/v1_names.zig");
const CalldataDecoder = @import("../utils/calldata_decoder.zig").CalldataDecoder;
const Hash = @import("../types/hash.zig").Hash;
const Address = @import("../types/address.zig").Address;
const models = @import("../types/models.zig");
const names_storage = @import("../storage/names.zig");
const ens_normalize = @import("../utils/ens_normalize.zig");
const Rainbow = @import("../rainbow/rainbow.zig").Rainbow;
const constants = @import("../constants.zig");
const Keccak256 = std.crypto.hash.sha3.Keccak256;

/// Backfill unknown subdomain labels by fetching transaction calldata
/// and extracting label text from setSubnode* function calls
pub const LabelBackfill = struct {
    allocator: std.mem.Allocator,
    rpc_client: *rpc.Client,
    database: *db_module.Database,
    rainbow: ?*Rainbow, // Borrowed from Indexer (not owned)

    const BATCH_SIZE = 100; // Fetch 100 transactions at a time

    /// Maximum number of batches to process per invocation. Bounds RPC usage so a
    /// fresh sync with millions of unknown labels doesn't hammer the RPC for hours
    /// in a single run. Backfill is resumable: remaining work is picked up by
    /// subsequent sync cycles. 200 * BATCH_SIZE = up to 20,000 labels per call.
    const MAX_ITERATIONS: u32 = 200;

    /// Inter-batch sleep (milliseconds) — reuses the existing RPC batch delay so
    /// we don't slam upstream providers. TODO: consider a dedicated
    /// `label_backfill_delay_ms` constant if backfill needs separate tuning.
    const INTER_BATCH_DELAY_MS: u64 = constants.Timing.rpc_batch_delay_ms;

    pub fn init(allocator: std.mem.Allocator, rpc_client: *rpc.Client, database: *db_module.Database, rainbow: ?*Rainbow) LabelBackfill {
        return LabelBackfill{
            .allocator = allocator,
            .rpc_client = rpc_client,
            .database = database,
            .rainbow = rainbow,
        };
    }

    /// Run backfill process for all unknown labels.
    /// Bounded to MAX_ITERATIONS batches per invocation to keep RPC load sane;
    /// remaining work is picked up by subsequent sync cycles. Sleeps
    /// INTER_BATCH_DELAY_MS between batches. The underlying SQL query already
    /// filters `WHERE backfill_attempts < 3`, so dead labels don't burn budget.
    /// Returns the number of labels successfully resolved in this invocation.
    pub fn backfillAll(self: *LabelBackfill) !u64 {
        var total_resolved: u64 = 0;
        var iteration: u32 = 0;

        while (iteration < MAX_ITERATIONS) : (iteration += 1) {
            // Get batch of unknown labels (query already excludes attempts >= 3)
            const unknown_labels = try unknown_labels_storage.getUnknownLabelsForBackfill(
                self.allocator,
                self.database,
                BATCH_SIZE,
            );
            defer {
                for (unknown_labels) |label| {
                    unknown_labels_storage.freeUnknownLabel(self.allocator, label);
                }
                self.allocator.free(unknown_labels);
            }

            if (unknown_labels.len == 0) {
                break; // No more labels to process
            }

            std.log.info("Backfilling batch {d}/{d} ({d} labels)...", .{ iteration + 1, MAX_ITERATIONS, unknown_labels.len });

            // Process this batch
            const resolved = try self.backfillBatch(unknown_labels);
            total_resolved += resolved;

            std.log.info("Resolved {d}/{d} labels in this batch (total: {d})", .{ resolved, unknown_labels.len, total_resolved });

            // Inter-batch sleep to be kind to the RPC provider. Skip on the
            // last iteration (loop is about to exit anyway).
            if (iteration + 1 < MAX_ITERATIONS) {
                std.Thread.sleep(INTER_BATCH_DELAY_MS * std.time.ns_per_ms);
            }
        }

        if (iteration >= MAX_ITERATIONS) {
            const remaining = unknown_labels_storage.getUnknownLabelCount(self.database) catch 0;
            std.log.info(
                "Reached MAX_ITERATIONS ({d}) for unknown-label backfill; {d} labels still pending (attempts<3). Will resume on next sync cycle.",
                .{ MAX_ITERATIONS, remaining },
            );
        }

        return total_resolved;
    }

    /// Process a batch of unknown labels
    fn backfillBatch(self: *LabelBackfill, unknown_labels: []unknown_labels_storage.UnknownLabel) !u64 {
        var resolved_count: u64 = 0;

        // addr.reverse namehash for fast comparison
        var addr_reverse_hex_buf: [66]u8 = undefined;
        const addr_reverse_hex = constants.WellKnown.reverse_namehash.toHexBuf(&addr_reverse_hex_buf);

        // STEP 0: Resolve addr.reverse labels (no RPC needed)
        // For addr.reverse subnames, the label is the lowercase address without 0x prefix.
        // We try the owner address from the event and verify keccak256(label) == labelhash.
        for (unknown_labels) |label| {
            if (!std.mem.eql(u8, label.parent_node, addr_reverse_hex)) continue;

            if (self.tryResolveAddrReverse(label)) |addr_label| {
                defer self.allocator.free(addr_label);

                const namehash = try Hash.fromHex(label.namehash);
                try v1_names.storeTokenIdLabel(
                    self.allocator,
                    self.database,
                    label.labelhash,
                    addr_label,
                    namehash,
                    @intCast(label.block_number),
                    label.transaction_hash,
                    "addr_reverse",
                );

                self.createSubdomainNameRecord(addr_label, label) catch |err| {
                    std.log.warn("Failed to create addr.reverse name for labelhash={s}: {}", .{ label.labelhash, err });
                };

                try unknown_labels_storage.deleteUnknownLabel(self.database, label.id);
                resolved_count += 1;
            } else {
                // Owner address didn't match — mark as failed (no point retrying via RPC)
                unknown_labels_storage.incrementBackfillAttempt(self.database, label.id) catch {};
                unknown_labels_storage.incrementBackfillAttempt(self.database, label.id) catch {};
                unknown_labels_storage.incrementBackfillAttempt(self.database, label.id) catch {};
            }
        }

        // STEP 1: Try rainbow table (if available)
        if (self.rainbow) |rainbow| {
            for (unknown_labels) |label| {
                // Skip already-resolved labels
                if (std.mem.eql(u8, label.parent_node, addr_reverse_hex)) continue;

                const labelhash_binary = try Hash.fromHex(label.labelhash);

                if (try rainbow.lookup(labelhash_binary.bytes)) |label_text| {
                    defer self.allocator.free(label_text);

                    std.log.debug("Resolved via rainbow: {s} (labelhash={s})", .{ label_text, label.labelhash });

                    // Store the label in v1_labels table
                    const namehash = try Hash.fromHex(label.namehash);
                    try v1_names.storeTokenIdLabel(
                        self.allocator,
                        self.database,
                        label.labelhash,
                        label_text,
                        namehash,
                        @intCast(label.block_number),
                        label.transaction_hash,
                        "rainbow_table",
                    );

                    // Create subdomain name record now that we have the label
                    self.createSubdomainNameRecord(label_text, label) catch |err| {
                        std.log.warn("Failed to create subdomain name for labelhash={s}: {}", .{ label.labelhash, err });
                    };

                    // Delete from unknown_labels (successfully resolved)
                    try unknown_labels_storage.deleteUnknownLabel(self.database, label.id);

                    resolved_count += 1;
                }
            }
        }

        // STEP 2: For remaining unknown labels, try calldata decoding
        // Collect labels still needing resolution (skip addr.reverse — already handled)
        var remaining_labels: std.ArrayList(unknown_labels_storage.UnknownLabel) = .{};
        defer remaining_labels.deinit(self.allocator);

        for (unknown_labels) |label| {
            // Skip addr.reverse entries (already resolved or marked failed in step 0)
            if (std.mem.eql(u8, label.parent_node, addr_reverse_hex)) continue;

            // Check if this label was already resolved by rainbow (best-effort).
            var q = db_module.Query.init(self.database, "SELECT COUNT(*) FROM unknown_labels WHERE id = ?") catch continue;
            defer q.deinit();
            q.bindInt64(label.id) catch continue;
            if (q.step() catch false) {
                if (q.getInt64(0) > 0) {
                    try remaining_labels.append(self.allocator, label);
                }
            }
        }

        if (remaining_labels.items.len == 0) {
            return resolved_count;
        }

        std.log.debug("{d} labels remaining after rainbow lookup, fetching transactions...", .{remaining_labels.items.len});

        // Collect transaction hashes to fetch
        var tx_hashes = try self.allocator.alloc(Hash, remaining_labels.items.len);
        defer self.allocator.free(tx_hashes);

        for (remaining_labels.items, 0..) |label, i| {
            tx_hashes[i] = try Hash.fromHex(label.transaction_hash);
        }

        // Batch fetch transactions
        const transactions = self.rpc_client.getTransactionsByHashBatch(tx_hashes) catch |err| {
            std.log.err("Failed to fetch transactions batch: {}", .{err});
            // Increment attempt counters for remaining labels
            for (remaining_labels.items) |label| {
                unknown_labels_storage.incrementBackfillAttempt(self.database, label.id) catch {};
            }
            return resolved_count;
        };
        defer {
            for (transactions) |*tx| {
                tx.deinit(self.allocator);
            }
            self.allocator.free(transactions);
        }

        // Process each transaction
        for (remaining_labels.items, 0..) |label, i| {
            const tx = transactions[i];

            // Try to decode label from transaction calldata
            // This tries both direct setSubnode calls and multicall patterns
            const maybe_label_text = CalldataDecoder.decodeLabelFromCalldata(self.allocator, tx.input) catch |err| {
                std.log.warn("Failed to decode calldata for tx {s}: {}", .{ label.transaction_hash, err });
                try unknown_labels_storage.incrementBackfillAttempt(self.database, label.id);
                continue;
            };

            if (maybe_label_text) |label_text| {
                defer self.allocator.free(label_text);

                std.log.info("Resolved label: {s} (from tx {s})", .{ label_text, label.transaction_hash });

                // Store the label in v1_labels table
                const namehash = try Hash.fromHex(label.namehash);
                try v1_names.storeTokenIdLabel(
                    self.allocator,
                    self.database,
                    label.labelhash, // token_id as hex string
                    label_text,
                    namehash,
                    @intCast(label.block_number),
                    label.transaction_hash,
                    "transaction_calldata",
                );

                // Create subdomain name record now that we have the label
                self.createSubdomainNameRecord(label_text, label) catch |err| {
                    std.log.warn("Failed to create subdomain name for labelhash={s}: {}", .{ label.labelhash, err });
                };

                // Delete from unknown_labels (successfully resolved)
                try unknown_labels_storage.deleteUnknownLabel(self.database, label.id);

                resolved_count += 1;
            } else {
                // Calldata doesn't contain a valid label (not a setSubnode call?)
                std.log.warn("No label found in calldata for tx {s} (labelhash={s})", .{
                    label.transaction_hash,
                    label.labelhash,
                });
                try unknown_labels_storage.incrementBackfillAttempt(self.database, label.id);
            }
        }

        return resolved_count;
    }

    /// Try to resolve an addr.reverse label from the owner address.
    /// For addr.reverse subnames, the label is the lowercase hex address without "0x".
    /// Returns the label string (caller-owned) if keccak256(label) matches the labelhash.
    fn tryResolveAddrReverse(self: *LabelBackfill, label: unknown_labels_storage.UnknownLabel) ?[]const u8 {
        // Owner is stored as "0x..." hex string — the reverse label is the address without "0x", lowercased
        const owner_hex = label.owner;
        if (owner_hex.len < 3) return null;

        // Strip "0x" prefix
        const addr_str = if (std.mem.startsWith(u8, owner_hex, "0x")) owner_hex[2..] else owner_hex;
        if (addr_str.len != 40) return null;

        // Lowercase the address
        var lower_addr: [40]u8 = undefined;
        for (addr_str, 0..) |ch, i| {
            lower_addr[i] = if (ch >= 'A' and ch <= 'F') ch + 32 else ch;
        }

        // Compute keccak256 of the lowercase address string
        var hash_result: [32]u8 = undefined;
        Keccak256.hash(&lower_addr, &hash_result, .{});

        // Compare with the stored labelhash
        const labelhash_binary = Hash.fromHex(label.labelhash) catch return null;
        if (!std.mem.eql(u8, &hash_result, &labelhash_binary.bytes)) return null;

        // Match! Return the lowercase address as the label
        return self.allocator.dupe(u8, &lower_addr) catch null;
    }

    /// Heal a name record after resolving its label via backfill.
    /// The name record was already created during indexing with a [labelhash] label.
    /// Now that we know the plaintext label, update the name and label fields.
    fn createSubdomainNameRecord(
        self: *LabelBackfill,
        label_text: []const u8,
        unknown_label: unknown_labels_storage.UnknownLabel,
    ) !void {
        const namehash = try Hash.fromHex(unknown_label.namehash);

        // Check if name exists — it should, since handleV1NewOwner now creates records inline
        if (try names_storage.getNameByNamehash(self.database, namehash)) |existing| {
            var existing_mut = existing;
            defer existing_mut.deinit(self.allocator);

            // Only heal if the label is still in [labelhash] notation
            const needs_heal = existing.label != null and existing.label.?[0] == '[';
            if (!needs_heal) return; // Already has a real label

            // Look up parent name to reconstruct full name
            const parent_namehash = try Hash.fromHex(unknown_label.parent_node);
            var parent_name_str: ?[]const u8 = null;
            var parent_record_to_free: ?models.Name = null;
            defer if (parent_record_to_free) |*pr| pr.deinit(self.allocator);

            if (parent_namehash.eql(constants.WellKnown.root_namehash)) {
                // Genuine root child (a TLD): bare label, no suffix.
                parent_name_str = ens_name.ROOT_PARENT;
            } else if (try names_storage.getNameByNamehash(self.database, parent_namehash)) |parent_record| {
                parent_record_to_free = parent_record;
                parent_name_str = parent_record.name;
            } else {
                // Parent absent and not root: joining against an empty parent
                // would mint a root-level name ('foo') inconsistent with this
                // row's namehash (= namehash('foo.<parent>')). Leave the
                // [labelhash] placeholder for a later heal once the parent is
                // indexed, rather than write a wrong name.
                std.log.debug("Skipping label heal for '{s}': parent {s} not yet indexed", .{ label_text, unknown_label.parent_node });
                return;
            }

            const full_name = try ens_name.join(self.allocator, label_text, parent_name_str);
            defer self.allocator.free(full_name);

            // Now that the plaintext name is known, recompute the ENSIP-15 flag.
            const is_norm = ens_normalize.nameIsNormalized(self.allocator, full_name);
            try names_storage.updateNameLabel(self.database, .v1, namehash, label_text, full_name, is_norm);
            std.log.debug("Healed subdomain label: {s}", .{full_name});
        }
        // If name doesn't exist (shouldn't happen with new indexing), skip silently
    }

    /// Get statistics about unknown labels
    pub fn getStats(self: *LabelBackfill) !BackfillStats {
        const total = try unknown_labels_storage.getUnknownLabelCount(self.database);

        // Get count by attempt ranges
        const query =
            \\SELECT
            \\  COUNT(CASE WHEN backfill_attempts = 0 THEN 1 END) as pending,
            \\  COUNT(CASE WHEN backfill_attempts > 0 AND backfill_attempts < 3 THEN 1 END) as retrying,
            \\  COUNT(CASE WHEN backfill_attempts >= 3 THEN 1 END) as failed
            \\FROM unknown_labels
        ;

        var q = db_module.Query.init(self.database, query) catch return error.DatabaseError;
        defer q.deinit();
        if (!(q.step() catch return error.DatabaseError)) return error.DatabaseError;

        return BackfillStats{
            .total = total,
            .pending = @intCast(q.getInt64(0)),
            .retrying = @intCast(q.getInt64(1)),
            .failed = @intCast(q.getInt64(2)),
        };
    }
};

pub const BackfillStats = struct {
    total: u64,
    pending: u64,
    retrying: u64,
    failed: u64,
};
