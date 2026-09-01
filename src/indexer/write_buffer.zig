/// Write buffer for batching database operations during chunk processing.
/// Instead of writing to SQLite per-event, handlers accumulate operations in memory.
/// At the end of each chunk, all buffered writes are flushed to the database.
///
/// Benefits:
/// - Deduplication: multiple writes to the same name merge into a single INSERT/UPDATE
/// - Better locality: all writes of the same type execute in a tight loop
/// - Eliminates per-event DB round-trip overhead
const std = @import("std");
const zsys = @import("../utils/system.zig");
const models = @import("../types/models.zig");
const Hash = @import("../types/hash.zig").Hash;
const token_id_utils = @import("../types/token_id.zig");
const Address = @import("../types/address.zig").Address;
const Database = @import("../storage/database.zig").Database;
const names_storage = @import("../storage/names.zig");
const events_storage = @import("../storage/events.zig");
const roles_storage = @import("../storage/roles.zig");
const ens_normalize = @import("../utils/ens_normalize.zig");

/// Safely convert u64 expiry to i64 for SQLite storage.
/// Values exceeding i64::max are mapped to 0 (never expires).
fn safeU64ToI64(val: u64) i64 {
    if (val > @as(u64, @intCast(std.math.maxInt(i64)))) return 0;
    return @intCast(val);
}

pub const WriteBuffer = struct {
    allocator: std.mem.Allocator,

    /// Buffered name operations, keyed by namehash (32 bytes).
    /// For new names: stores full record with all subsequent updates applied in-place.
    /// For existing DB names: stores only the pending field updates.
    names: std.AutoHashMap([32]u8, BufferedName),

    /// Buffered events (append-only, no deduplication needed).
    events: std.ArrayList(models.Event),

    /// Buffered EAC role assignments, keyed by the table's conflict key
    /// (protocol, resource, account, contract) — last write wins, mirroring the
    /// direct path's upsert semantics: the batch is a single transaction, so
    /// only the final per-key state is ever observable, and the winning
    /// event's metadata (block/tx/log_index) is preserved. A null bitmap is a
    /// buffered delete (all roles revoked).
    ///
    /// INVARIANT (enforced at the handler routing site): roles are only
    /// buffered while the reorg cursor is DISARMED. eac_roles is a
    /// capture-protected table; a flush-time capture would tag every undo row
    /// with the batch's LAST block and break mid-batch fork restoration.
    roles: std.StringHashMap(BufferedRole),

    /// Whether the buffer is currently active (handlers should use buffer vs direct DB).
    active: bool,

    pub const BufferedRole = struct {
        protocol: models.Protocol,
        /// Owned. Also embedded in the map key, but kept here so the flush
        /// doesn't re-parse keys.
        resource: []const u8,
        account: Address,
        contract_address: Address,
        /// Owned. Null = delete (newRoleBitmap == 0).
        role_bitmap: ?[]const u8,
        block_number: u64,
        tx_hash: Hash,
        log_index: u32,
    };

    pub const BufferedName = struct {
        /// True if this name was INSERT'd in this chunk (vs UPDATE to existing DB record).
        is_new: bool,
        /// Full name record (for new inserts). All string fields are owned by the buffer.
        record: ?models.Name = null,
        /// Pending field updates (applied at flush time for existing DB names).
        owner: ?Address = null,
        expiry: ?u64 = null,
        resolver: ?Address = null,
        /// Wrapper state: set via NameWrapped
        wrapper_state: ?WrapperState = null,
        /// Unwrap flag: set via NameUnwrapped (clears wrapper fields)
        unwrap: bool = false,
        /// Individual wrapper field updates
        fuses_update: ?u32 = null,
        wrapper_expiry_update: ?u64 = null,
        /// Set when a V1 token is transferred to a migration controller. Carries
        /// the new owner (the controller address) so the flush can apply both
        /// `owner=controller` and `migrated=true` in a single statement.
        migrated_to: ?Address = null,

        const WrapperState = struct {
            fuses: u32,
            expiry: u64,
        };
    };

    pub fn init(allocator: std.mem.Allocator) WriteBuffer {
        return .{
            .allocator = allocator,
            .names = std.AutoHashMap([32]u8, BufferedName).init(allocator),
            .events = .empty,
            .roles = std.StringHashMap(BufferedRole).init(allocator),
            .active = false,
        };
    }

    pub fn deinit(self: *WriteBuffer) void {
        self.freeAll();
        self.names.deinit();
        self.events.deinit(self.allocator);
        self.roles.deinit();
    }

    pub fn reset(self: *WriteBuffer) void {
        self.freeAll();
        self.names.clearRetainingCapacity();
        self.events.clearRetainingCapacity();
        self.roles.clearRetainingCapacity();
    }

    fn freeAll(self: *WriteBuffer) void {
        // Free all owned name record strings
        var it = self.names.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.record) |*rec| {
                freeNameStrings(self.allocator, rec);
            }
        }
        // Free all event strings
        for (self.events.items) |*event| {
            if (event.name) |n| self.allocator.free(n);
            self.allocator.free(event.data);
        }
        // Free role keys and owned role strings
        var rit = self.roles.iterator();
        while (rit.next()) |entry| {
            self.allocator.free(entry.value_ptr.resource);
            if (entry.value_ptr.role_bitmap) |b| self.allocator.free(b);
            self.allocator.free(entry.key_ptr.*);
        }
    }

    // ========================================================================
    // NAME OPERATIONS
    // ========================================================================

    /// Buffer a new name INSERT. Dupes all string fields so the caller can free theirs.
    pub fn insertName(self: *WriteBuffer, name: models.Name) !void {
        const key = name.namehash.bytes;
        const gop = try self.names.getOrPut(key);

        if (gop.found_existing) {
            // Name already buffered (shouldn't happen for INSERTs, but handle gracefully).
            // Replace with the new record (UPSERT semantics).
            if (gop.value_ptr.record) |*old_rec| {
                freeNameStrings(self.allocator, old_rec);
            }
            gop.value_ptr.* = .{
                .is_new = true,
                .record = try dupeName(self.allocator, name),
            };
        } else {
            gop.value_ptr.* = .{
                .is_new = true,
                .record = try dupeName(self.allocator, name),
            };
        }
        // Compute the ENSIP-15 flag here (the buffered insert chokepoint) so flushed
        // V1 names persist it just like the direct-insert path (Indexer.insertName).
        gop.value_ptr.record.?.is_normalized = ens_normalize.nameIsNormalized(self.allocator, name.name);
    }

    /// Mutable view of a name INSERT'd this chunk but not yet flushed. Update
    /// handlers use it so same-chunk creation+update sequences behave exactly
    /// like the direct path: field updates land on the pending record in-place
    /// instead of no-op'ing against a DB row that doesn't exist yet. The
    /// pointer is invalidated by the next names-map mutation — use immediately.
    pub fn pendingNewName(self: *WriteBuffer, namehash: Hash) ?*models.Name {
        const entry = self.names.getPtr(namehash.bytes) orelse return null;
        if (!entry.is_new) return null;
        return &entry.record.?;
    }

    /// Buffer an owner update. If the name was INSERT'd this chunk, updates in-place.
    pub fn updateNameOwner(self: *WriteBuffer, namehash: Hash, owner: Address) !void {
        const key = namehash.bytes;
        const gop = try self.names.getOrPut(key);

        if (gop.found_existing) {
            if (gop.value_ptr.is_new) {
                // Update the buffered record in-place
                gop.value_ptr.record.?.owner = owner;
            } else {
                gop.value_ptr.owner = owner;
            }
        } else {
            // Name exists in DB, record pending update
            gop.value_ptr.* = .{ .is_new = false, .owner = owner };
        }
    }

    /// Buffer a V1→V2 migration: sets `owner=controller` and `migrated=true`.
    /// If the name was INSERT'd this chunk (rare for migrations), updates the
    /// buffered record in-place; otherwise records pending update.
    pub fn markNameMigrated(self: *WriteBuffer, namehash: Hash, controller: Address) !void {
        const key = namehash.bytes;
        const gop = try self.names.getOrPut(key);

        if (gop.found_existing) {
            if (gop.value_ptr.is_new) {
                gop.value_ptr.record.?.owner = controller;
                gop.value_ptr.record.?.migrated = true;
            } else {
                gop.value_ptr.migrated_to = controller;
            }
        } else {
            gop.value_ptr.* = .{ .is_new = false, .migrated_to = controller };
        }
    }

    /// Buffer a BaseRegistrar renewal expiry update. Rows already in the DB
    /// flush through names_storage.updateV1RenewalExpiry (grace-aware CASE for
    /// wrapped rows); records buffered this chunk store the bare value.
    pub fn updateV1RenewalExpiry(self: *WriteBuffer, namehash: Hash, expires: u64) !void {
        const key = namehash.bytes;
        const gop = try self.names.getOrPut(key);

        if (gop.found_existing) {
            if (gop.value_ptr.is_new) {
                // Bare registrar value, even when the buffered record is
                // wrapped: grace for wrapped rows comes from the post-sync PCC
                // materialize pass (the buffer is only active during bulk
                // sync). Pre-applying it here double-counted after an unwrap
                // later in the same chunk — the in-memory unwrap can't re-base.
                gop.value_ptr.record.?.expiry = expires;
            } else {
                gop.value_ptr.expiry = expires;
            }
        } else {
            gop.value_ptr.* = .{ .is_new = false, .expiry = expires };
        }
    }

    /// Buffer a resolver update.
    pub fn updateNameResolver(self: *WriteBuffer, namehash: Hash, resolver: Address) !void {
        const key = namehash.bytes;
        const gop = try self.names.getOrPut(key);

        if (gop.found_existing) {
            if (gop.value_ptr.is_new) {
                gop.value_ptr.record.?.resolver = resolver;
            } else {
                gop.value_ptr.resolver = resolver;
            }
        } else {
            gop.value_ptr.* = .{ .is_new = false, .resolver = resolver };
        }
    }

    /// Buffer a wrapper state update (NameWrapped event).
    pub fn updateNameWrapperState(self: *WriteBuffer, namehash: Hash, fuses: u32, expiry: u64) !void {
        const key = namehash.bytes;
        const gop = try self.names.getOrPut(key);

        if (gop.found_existing) {
            if (gop.value_ptr.is_new) {
                gop.value_ptr.record.?.is_wrapped = true;
                // Store fuses as string (matching DB format)
                if (gop.value_ptr.record.?.wrapper_fuses) |old| {
                    self.allocator.free(old);
                }
                gop.value_ptr.record.?.wrapper_fuses = std.fmt.allocPrint(self.allocator, "{d}", .{fuses}) catch null;
                gop.value_ptr.record.?.wrapper_expiry = safeU64ToI64(expiry);
            } else {
                gop.value_ptr.wrapper_state = .{ .fuses = fuses, .expiry = expiry };
                gop.value_ptr.unwrap = false; // Cancel any pending unwrap
            }
        } else {
            gop.value_ptr.* = .{
                .is_new = false,
                .wrapper_state = .{ .fuses = fuses, .expiry = expiry },
            };
        }
    }

    /// Buffer a name unwrap (NameUnwrapped event).
    pub fn clearNameWrapperState(self: *WriteBuffer, namehash: Hash) !void {
        const key = namehash.bytes;
        const gop = try self.names.getOrPut(key);

        if (gop.found_existing) {
            if (gop.value_ptr.is_new) {
                gop.value_ptr.record.?.is_wrapped = false;
                if (gop.value_ptr.record.?.wrapper_fuses) |old| {
                    self.allocator.free(old);
                }
                gop.value_ptr.record.?.wrapper_fuses = null;
                gop.value_ptr.record.?.wrapper_expiry = null;
            } else {
                gop.value_ptr.unwrap = true;
                gop.value_ptr.wrapper_state = null; // Cancel any pending wrap
                gop.value_ptr.fuses_update = null;
                gop.value_ptr.wrapper_expiry_update = null;
            }
        } else {
            gop.value_ptr.* = .{ .is_new = false, .unwrap = true };
        }
    }

    /// Buffer a fuses-only update (FusesSet event).
    pub fn updateNameWrapperFuses(self: *WriteBuffer, namehash: Hash, fuses: u32) !void {
        const key = namehash.bytes;
        const gop = try self.names.getOrPut(key);

        if (gop.found_existing) {
            if (gop.value_ptr.is_new) {
                if (gop.value_ptr.record.?.wrapper_fuses) |old| {
                    self.allocator.free(old);
                }
                gop.value_ptr.record.?.wrapper_fuses = std.fmt.allocPrint(self.allocator, "{d}", .{fuses}) catch null;
            } else {
                gop.value_ptr.fuses_update = fuses;
            }
        } else {
            gop.value_ptr.* = .{ .is_new = false, .fuses_update = fuses };
        }
    }

    /// Buffer a wrapper expiry-only update (ExpiryExtended event).
    pub fn updateNameWrapperExpiry(self: *WriteBuffer, namehash: Hash, expiry: u64) !void {
        const key = namehash.bytes;
        const gop = try self.names.getOrPut(key);

        if (gop.found_existing) {
            if (gop.value_ptr.is_new) {
                gop.value_ptr.record.?.wrapper_expiry = safeU64ToI64(expiry);
            } else {
                gop.value_ptr.wrapper_expiry_update = expiry;
            }
        } else {
            gop.value_ptr.* = .{ .is_new = false, .wrapper_expiry_update = expiry };
        }
    }

    // ========================================================================
    // EVENT OPERATIONS
    // ========================================================================

    /// Buffer an event. Takes ownership of event.name and event.data strings.
    /// Caller must NOT free these strings after calling addEvent.
    pub fn addEvent(self: *WriteBuffer, event: models.Event) !void {
        try self.events.append(self.allocator, event);
    }

    // ========================================================================
    // EAC ROLE OPERATIONS
    // ========================================================================

    /// Buffer an EACRolesChanged outcome: `role_bitmap` = the new bitmap hex,
    /// or null when all roles were revoked (a delete). Later writes to the
    /// same (protocol, resource, account, contract) key replace earlier ones
    /// — identical end state to the direct upsert/delete sequence within the
    /// batch transaction. Dupes `resource`/`role_bitmap` so the caller keeps
    /// ownership of its slices.
    pub fn setRole(
        self: *WriteBuffer,
        protocol: models.Protocol,
        resource: []const u8,
        account: Address,
        role_bitmap: ?[]const u8,
        block_number: u64,
        tx_hash: Hash,
        log_index: u32,
        contract_address: Address,
    ) !void {
        var account_buf: [42]u8 = undefined;
        var contract_buf: [42]u8 = undefined;
        const key = try std.fmt.allocPrint(self.allocator, "{s}|{s}|{s}|{s}", .{
            protocol.toString(),
            resource,
            account.toHexBuf(&account_buf),
            contract_address.toHexBuf(&contract_buf),
        });
        errdefer self.allocator.free(key);

        const resource_dup = try self.allocator.dupe(u8, resource);
        errdefer self.allocator.free(resource_dup);
        const bitmap_dup: ?[]const u8 = if (role_bitmap) |b| try self.allocator.dupe(u8, b) else null;
        errdefer if (bitmap_dup) |b| self.allocator.free(b);

        const gop = try self.roles.getOrPut(key);
        if (gop.found_existing) {
            self.allocator.free(key);
            self.allocator.free(gop.value_ptr.resource);
            if (gop.value_ptr.role_bitmap) |b| self.allocator.free(b);
        }
        gop.value_ptr.* = .{
            .protocol = protocol,
            .resource = resource_dup,
            .account = account,
            .contract_address = contract_address,
            .role_bitmap = bitmap_dup,
            .block_number = block_number,
            .tx_hash = tx_hash,
            .log_index = log_index,
        };
    }

    // ========================================================================
    // FLUSH — Write all buffered data to database
    // ========================================================================

    pub fn flush(self: *WriteBuffer, db: *Database) !void {
        const timer = zsys.milliTimestamp();
        var names_inserted: usize = 0;
        var names_updated: usize = 0;
        var names_ms: i64 = 0;
        // Per-statement-type forensics: [insert, unwrap, wrapper_state, migrate/owner,
        // expiry, resolver, fuses, wrapper_expiry]. Printed when the names phase runs hot.
        var op_ns: [8]i128 = @splat(0);
        var op_count: [8]usize = @splat(0);
        const wal_before = db.walFileSize() orelse 0;

        // 1. Flush names (events may reference names). New names are collected
        // and written in one multi-row upsert pass below — on a remote
        // Postgres the per-row round trips dominated the flush.
        var new_names: std.ArrayList(models.Name) = .empty;
        defer new_names.deinit(self.allocator);

        var it = self.names.iterator();
        while (it.next()) |entry| {
            const bn = entry.value_ptr;

            if (bn.is_new) {
                // Record has all updates already applied; strings stay owned by
                // the buffer until reset(), which outlives the batch insert.
                try new_names.append(self.allocator, bn.record.?);
            } else {
                // Apply individual updates to existing DB record
                const namehash = Hash{ .bytes = entry.key_ptr.* };

                // Unwrap must come before other wrapper updates
                if (bn.unwrap) {
                    const t0 = zsys.nanoTimestamp();
                    try names_storage.updateNameUnwrapperState(db, namehash);
                    op_ns[1] += zsys.nanoTimestamp() - t0;
                    op_count[1] += 1;
                }

                // Full wrapper state (from NameWrapped)
                if (bn.wrapper_state) |ws| {
                    const t0 = zsys.nanoTimestamp();
                    try names_storage.updateNameWrapperState(db, namehash, ws.fuses, ws.expiry);
                    op_ns[2] += zsys.nanoTimestamp() - t0;
                    op_count[2] += 1;
                }

                // Migration takes precedence over plain owner update — it sets
                // both `owner` and `migrated=true` in one statement.
                if (bn.migrated_to) |controller| {
                    const t0 = zsys.nanoTimestamp();
                    try names_storage.markNameMigrated(db, namehash, controller);
                    op_ns[3] += zsys.nanoTimestamp() - t0;
                    op_count[3] += 1;
                } else if (bn.owner) |owner| {
                    const t0 = zsys.nanoTimestamp();
                    try names_storage.updateNameOwner(db, namehash, owner);
                    op_ns[3] += zsys.nanoTimestamp() - t0;
                    op_count[3] += 1;
                }
                if (bn.expiry) |expiry| {
                    const t0 = zsys.nanoTimestamp();
                    try names_storage.updateV1RenewalExpiry(db, namehash, expiry);
                    op_ns[4] += zsys.nanoTimestamp() - t0;
                    op_count[4] += 1;
                }
                if (bn.resolver) |resolver| {
                    const t0 = zsys.nanoTimestamp();
                    try names_storage.updateNameResolver(db, namehash, resolver);
                    op_ns[5] += zsys.nanoTimestamp() - t0;
                    op_count[5] += 1;
                }
                if (bn.fuses_update) |fuses| {
                    const t0 = zsys.nanoTimestamp();
                    try names_storage.updateNameWrapperFuses(db, namehash, fuses);
                    op_ns[6] += zsys.nanoTimestamp() - t0;
                    op_count[6] += 1;
                }
                if (bn.wrapper_expiry_update) |exp| {
                    const t0 = zsys.nanoTimestamp();
                    try names_storage.updateNameWrapperExpiry(db, namehash, exp);
                    op_ns[7] += zsys.nanoTimestamp() - t0;
                    op_count[7] += 1;
                }
                names_updated += 1;
            }
        }
        if (new_names.items.len > 0) {
            const t0 = zsys.nanoTimestamp();
            try names_storage.insertNamesBatch(db, new_names.items);
            op_ns[0] += zsys.nanoTimestamp() - t0;
            op_count[0] += new_names.items.len;
            names_inserted = new_names.items.len;
        }
        names_ms = zsys.milliTimestamp() - timer;

        // 1b. Flush EAC roles — one deduped multi-row upsert (the map already
        // guarantees unique conflict keys, which Postgres requires within a
        // single INSERT ... ON CONFLICT statement) plus the rare buffered
        // deletes. See the `roles` field invariant: this only runs with the
        // reorg cursor disarmed, so no undo capture fires here — matching what
        // the direct path would have captured (nothing).
        var role_upserts: usize = 0;
        var role_deletes: usize = 0;
        if (self.roles.count() > 0) {
            var upserts: std.ArrayList(roles_storage.RoleUpsertRow) = .empty;
            defer upserts.deinit(self.allocator);
            try upserts.ensureTotalCapacity(self.allocator, self.roles.count());
            var role_it = self.roles.iterator();
            while (role_it.next()) |entry| {
                const r = entry.value_ptr;
                if (r.role_bitmap) |bitmap| {
                    upserts.appendAssumeCapacity(.{
                        .protocol = r.protocol,
                        .resource = r.resource,
                        .account = r.account,
                        .role_bitmap = bitmap,
                        .block_number = r.block_number,
                        .tx_hash = r.tx_hash,
                        .log_index = r.log_index,
                        .contract_address = r.contract_address,
                    });
                } else {
                    try roles_storage.deleteEACRole(db, r.protocol, r.resource, r.account, r.contract_address);
                    role_deletes += 1;
                }
            }
            if (upserts.items.len > 0) {
                // Chain order, not hash-map order: new rows get their serial
                // ids in (block, log_index) sequence, matching what the direct
                // per-event path would have assigned (the API tiebreaks equal
                // timestamps on id).
                std.mem.sort(roles_storage.RoleUpsertRow, upserts.items, {}, struct {
                    fn lessThan(_: void, a: roles_storage.RoleUpsertRow, b: roles_storage.RoleUpsertRow) bool {
                        if (a.block_number != b.block_number) return a.block_number < b.block_number;
                        return a.log_index < b.log_index;
                    }
                }.lessThan);
                try roles_storage.upsertEACRolesBatch(db, upserts.items);
                role_upserts = upserts.items.len;
            }
        }

        // 2. Repair placeholder-named buffered events before they land: the
        // mid-batch placeholder→real patch (updatePlaceholderEventsByName)
        // only reaches rows already in the table, so buffered events would
        // keep the "tokenId:…" denorm name and null namehash. The names table
        // is fully current at this point (names flushed above; V2 names write
        // direct), so one token-id lookup per placeholder event restores
        // byte-identical output vs the direct per-event path. A miss (or a
        // still-placeholder name) is left as-is — identical to direct mode
        // when no patch ever fired.
        // Registry-LESS resolution on purpose: the emitting contract of the
        // event is not necessarily the registry that owns the token (the
        // direct-mode patch matches by placeholder string, no registry).
        // Ambiguous tokens are absent from the map, so they conservatively
        // keep their placeholder. Batched: one IN-list sweep per protocol
        // instead of one point lookup per placeholder event (~7k per storm
        // batch) — exact, because nothing here writes the names table.
        var tokens_v1: std.ArrayList(u256) = .empty;
        defer tokens_v1.deinit(self.allocator);
        var tokens_v2: std.ArrayList(u256) = .empty;
        defer tokens_v2.deinit(self.allocator);
        for (self.events.items) |*event| {
            const placeholder = event.name orelse continue;
            if (!std.mem.startsWith(u8, placeholder, "tokenId:")) continue;
            const token = std.fmt.parseInt(u256, placeholder["tokenId:".len..], 10) catch continue;
            switch (event.protocol) {
                .v1 => try tokens_v1.append(self.allocator, token),
                .v2 => try tokens_v2.append(self.allocator, token),
            }
        }
        if (tokens_v1.items.len > 0 or tokens_v2.items.len > 0) {
            var res_v1 = try names_storage.resolveUniqueNamesByCanonicalIds(db, .v1, tokens_v1.items, self.allocator);
            defer names_storage.freeCanonicalNameResolutions(&res_v1, self.allocator);
            var res_v2 = try names_storage.resolveUniqueNamesByCanonicalIds(db, .v2, tokens_v2.items, self.allocator);
            defer names_storage.freeCanonicalNameResolutions(&res_v2, self.allocator);
            for (self.events.items) |*event| {
                const placeholder = event.name orelse continue;
                if (!std.mem.startsWith(u8, placeholder, "tokenId:")) continue;
                const token = std.fmt.parseInt(u256, placeholder["tokenId:".len..], 10) catch continue;
                const resolutions = switch (event.protocol) {
                    .v1 => &res_v1,
                    .v2 => &res_v2,
                };
                const found = resolutions.get(token_id_utils.getCanonicalId(token)) orelse continue;
                const real_name = found.name orelse continue;
                if (std.mem.startsWith(u8, real_name, "tokenId:")) continue;
                const dup = try self.allocator.dupe(u8, real_name);
                self.allocator.free(placeholder);
                event.name = dup;
                event.namehash = found.namehash;
            }
        }

        // 3. Flush events — one multi-row conflict-ignoring INSERT per chunk.
        const events_timer = zsys.milliTimestamp();
        try events_storage.insertEventsBatch(db, self.events.items);
        const events_ms = zsys.milliTimestamp() - events_timer;
        const wal_after = db.walFileSize() orelse wal_before;

        const elapsed = zsys.milliTimestamp() - timer;
        if (self.events.items.len > 0 or names_inserted > 0 or names_updated > 0 or role_upserts > 0 or role_deletes > 0) {
            if (names_ms > 5000) {
                const op_labels = [8][]const u8{ "ins", "unwrap", "wrapstate", "owner", "expiry", "resolver", "fuses", "wrapexp" };
                for (op_labels, 0..) |label, i| {
                    if (op_count[i] > 0) {
                        std.log.info("    names breakdown: {s} {d} stmts in {d}ms", .{ label, op_count[i], @as(i64, @intCast(@divTrunc(op_ns[i], std.time.ns_per_ms))) });
                    }
                }
            }
            std.log.info("  Buffer flush: {d} events, {d} name inserts, {d} name updates, {d} role upserts, {d} role deletes in {d}ms (names={d}ms events={d}ms wal+={d}MB)", .{
                self.events.items.len,
                names_inserted,
                names_updated,
                role_upserts,
                role_deletes,
                elapsed,
                names_ms,
                events_ms,
                (wal_after -| wal_before) / (1024 * 1024),
            });
        }

        // Reset for next chunk (frees all owned strings)
        self.reset();
    }

    // ========================================================================
    // HELPERS
    // ========================================================================

    /// Dupe all string fields of a Name so the buffer owns them.
    fn dupeName(allocator: std.mem.Allocator, name: models.Name) !models.Name {
        var result = name;

        result.name = if (name.name) |n| try allocator.dupe(u8, n) else null;
        errdefer if (result.name) |n| allocator.free(n);

        result.label = if (name.label) |l| try allocator.dupe(u8, l) else null;
        errdefer if (result.label) |l| allocator.free(l);

        result.parent_name = if (name.parent_name) |p| try allocator.dupe(u8, p) else null;
        errdefer if (result.parent_name) |p| allocator.free(p);

        result.wrapper_fuses = if (name.wrapper_fuses) |f| try allocator.dupe(u8, f) else null;
        errdefer if (result.wrapper_fuses) |f| allocator.free(f);

        result.v1_label_hash = if (name.v1_label_hash) |v| try allocator.dupe(u8, v) else null;

        return result;
    }

    /// Free all owned string fields of a Name record.
    fn freeNameStrings(allocator: std.mem.Allocator, name: *models.Name) void {
        if (name.name) |n| allocator.free(n);
        if (name.label) |l| allocator.free(l);
        if (name.parent_name) |p| allocator.free(p);
        if (name.wrapper_fuses) |f| allocator.free(f);
        if (name.v1_label_hash) |v| allocator.free(v);
        name.name = null;
        name.label = null;
        name.parent_name = null;
        name.wrapper_fuses = null;
        name.v1_label_hash = null;
    }
};
