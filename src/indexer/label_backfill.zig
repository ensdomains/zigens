const std = @import("std");
const rpc = @import("../rpc/client.zig");
const db_module = @import("../storage/database.zig");
const c = db_module.c;
const unknown_labels_storage = @import("../storage/unknown_labels.zig");
const v1_names = @import("../utils/v1_names.zig");
const CalldataDecoder = @import("../utils/calldata_decoder.zig").CalldataDecoder;
const Hash = @import("../types/hash.zig").Hash;
const Rainbow = @import("../rainbow/rainbow.zig").Rainbow;

// SQLITE_TRANSIENT constant
inline fn SQLITE_TRANSIENT() c.sqlite3_destructor_type {
    return null;
}

/// Backfill unknown subdomain labels by fetching transaction calldata
/// and extracting label text from setSubnode* function calls
pub const LabelBackfill = struct {
    allocator: std.mem.Allocator,
    rpc_client: *rpc.Client,
    database: *db_module.Database,
    rainbow: ?Rainbow, // Optional rainbow table for fast lookups

    const BATCH_SIZE = 100; // Fetch 100 transactions at a time
    const RAINBOW_DB_PATH = "./data/ens_rainbow.db";

    pub fn init(allocator: std.mem.Allocator, rpc_client: *rpc.Client, database: *db_module.Database) LabelBackfill {
        // Try to load rainbow table (optional - gracefully handle if not available)
        const rainbow = Rainbow.init(allocator, RAINBOW_DB_PATH) catch |err| {
            std.log.info("Rainbow table not available ({any}), using calldata decoding only", .{err});
            return LabelBackfill{
                .allocator = allocator,
                .rpc_client = rpc_client,
                .database = database,
                .rainbow = null,
            };
        };

        // Rainbow table loaded successfully - log stats
        const stats = rainbow.getDbStats() catch {
            return LabelBackfill{
                .allocator = allocator,
                .rpc_client = rpc_client,
                .database = database,
                .rainbow = rainbow,
            };
        };

        std.log.info("✅ Rainbow table loaded: {d} labels available", .{stats.total_labels});

        return LabelBackfill{
            .allocator = allocator,
            .rpc_client = rpc_client,
            .database = database,
            .rainbow = rainbow,
        };
    }

    pub fn deinit(self: *LabelBackfill) void {
        if (self.rainbow) |*rainbow| {
            rainbow.deinit();
        }
    }

    /// Run backfill process for all unknown labels
    /// Returns the number of labels successfully resolved
    pub fn backfillAll(self: *LabelBackfill) !u64 {
        var total_resolved: u64 = 0;

        while (true) {
            // Get batch of unknown labels
            const unknown_labels = try unknown_labels_storage.getUnknownLabelsForBackfill(
                self.allocator,
                self.database.db.?,
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

            std.log.info("Backfilling batch of {d} unknown labels...", .{unknown_labels.len});

            // Process this batch
            const resolved = try self.backfillBatch(unknown_labels);
            total_resolved += resolved;

            std.log.info("Resolved {d}/{d} labels in this batch (total: {d})", .{ resolved, unknown_labels.len, total_resolved });
        }

        return total_resolved;
    }

    /// Process a batch of unknown labels
    fn backfillBatch(self: *LabelBackfill, unknown_labels: []unknown_labels_storage.UnknownLabel) !u64 {
        var resolved_count: u64 = 0;

        // STEP 1: Try rainbow table first (if available)
        if (self.rainbow) |*rainbow| {
            std.log.info("🔍 Attempting rainbow lookups for {} labels...", .{unknown_labels.len});
            for (unknown_labels) |label| {
                const labelhash_binary = try Hash.fromHex(label.labelhash);
                std.log.info("  Looking up labelhash: {s}", .{label.labelhash});

                if (try rainbow.lookup(labelhash_binary.bytes)) |label_text| {
                    defer self.allocator.free(label_text);

                    std.log.info("✅ Resolved via rainbow: {s} (labelhash={s})", .{ label_text, label.labelhash });

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

                    // Delete from unknown_labels (successfully resolved)
                    try unknown_labels_storage.deleteUnknownLabel(self.database.db.?, label.id);

                    resolved_count += 1;
                }
            }
        }

        // STEP 2: For remaining unknown labels, try calldata decoding
        // Collect labels still needing resolution
        var remaining_labels: std.ArrayList(unknown_labels_storage.UnknownLabel) = .{};
        defer remaining_labels.deinit(self.allocator);

        for (unknown_labels) |label| {
            // Check if this label was already resolved
            const exists_query = "SELECT COUNT(*) FROM unknown_labels WHERE id = ?";
            var stmt: ?*c.sqlite3_stmt = null;
            const rc = c.sqlite3_prepare_v2(self.database.db.?, exists_query.ptr, @intCast(exists_query.len), &stmt, null);
            if (rc == c.SQLITE_OK) {
                _ = c.sqlite3_bind_int64(stmt.?, 1, label.id);
                if (c.sqlite3_step(stmt.?) == c.SQLITE_ROW) {
                    const count = c.sqlite3_column_int64(stmt.?, 0);
                    if (count > 0) {
                        try remaining_labels.append(self.allocator, label);
                    }
                }
                _ = c.sqlite3_finalize(stmt);
            }
        }

        if (remaining_labels.items.len == 0) {
            // All labels resolved via rainbow
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
                unknown_labels_storage.incrementBackfillAttempt(self.database.db.?, label.id) catch {};
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
                try unknown_labels_storage.incrementBackfillAttempt(self.database.db.?, label.id);
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

                // TODO: Create the name record now that we have the label
                // This requires reconstructing the full name from parent + label
                // For now, we just store the label mapping

                // Delete from unknown_labels (successfully resolved)
                try unknown_labels_storage.deleteUnknownLabel(self.database.db.?, label.id);

                resolved_count += 1;
            } else {
                // Calldata doesn't contain a valid label (not a setSubnode call?)
                std.log.warn("No label found in calldata for tx {s} (labelhash={s})", .{
                    label.transaction_hash,
                    label.labelhash,
                });
                try unknown_labels_storage.incrementBackfillAttempt(self.database.db.?, label.id);
            }
        }

        return resolved_count;
    }

    /// Get statistics about unknown labels
    pub fn getStats(self: *LabelBackfill) !BackfillStats {
        const total = try unknown_labels_storage.getUnknownLabelCount(self.database.db.?);

        // Get count by attempt ranges
        const query =
            \\SELECT
            \\  COUNT(CASE WHEN backfill_attempts = 0 THEN 1 END) as pending,
            \\  COUNT(CASE WHEN backfill_attempts > 0 AND backfill_attempts < 3 THEN 1 END) as retrying,
            \\  COUNT(CASE WHEN backfill_attempts >= 3 THEN 1 END) as failed
            \\FROM unknown_labels
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.database.db.?, query.ptr, @intCast(query.len), &stmt, null);
        if (rc != c.SQLITE_OK) {
            return error.DatabaseError;
        }
        defer _ = c.sqlite3_finalize(stmt);

        const step_rc = c.sqlite3_step(stmt);
        if (step_rc != c.SQLITE_ROW) {
            return error.DatabaseError;
        }

        return BackfillStats{
            .total = total,
            .pending = @intCast(c.sqlite3_column_int64(stmt, 0)),
            .retrying = @intCast(c.sqlite3_column_int64(stmt, 1)),
            .failed = @intCast(c.sqlite3_column_int64(stmt, 2)),
        };
    }
};

pub const BackfillStats = struct {
    total: u64,
    pending: u64,
    retrying: u64,
    failed: u64,
};
