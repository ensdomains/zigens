/// Write buffer for batching database operations during chunk processing.
/// Instead of writing to SQLite per-event, handlers accumulate operations in memory.
/// At the end of each chunk, all buffered writes are flushed to the database.
///
/// Benefits:
/// - Deduplication: multiple writes to the same name merge into a single INSERT/UPDATE
/// - Better locality: all writes of the same type execute in a tight loop
/// - Eliminates per-event DB round-trip overhead
const std = @import("std");
const models = @import("../types/models.zig");
const Hash = @import("../types/hash.zig").Hash;
const Address = @import("../types/address.zig").Address;
const Database = @import("../storage/database.zig").Database;
const names_storage = @import("../storage/names.zig");
const events_storage = @import("../storage/events.zig");

pub const WriteBuffer = struct {
    allocator: std.mem.Allocator,

    /// Buffered name operations, keyed by namehash (32 bytes).
    /// For new names: stores full record with all subsequent updates applied in-place.
    /// For existing DB names: stores only the pending field updates.
    names: std.AutoHashMap([32]u8, BufferedName),

    /// Buffered events (append-only, no deduplication needed).
    events: std.ArrayList(models.Event),

    /// Whether the buffer is currently active (handlers should use buffer vs direct DB).
    active: bool,

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
        wrapper_expiry_update: ?i64 = null,

        const WrapperState = struct {
            fuses: u32,
            expiry: i64,
        };
    };

    pub fn init(allocator: std.mem.Allocator) WriteBuffer {
        return .{
            .allocator = allocator,
            .names = std.AutoHashMap([32]u8, BufferedName).init(allocator),
            .events = .{},
            .active = false,
        };
    }

    pub fn deinit(self: *WriteBuffer) void {
        self.freeAll();
        self.names.deinit();
        self.events.deinit(self.allocator);
    }

    pub fn reset(self: *WriteBuffer) void {
        self.freeAll();
        self.names.clearRetainingCapacity();
        self.events.clearRetainingCapacity();
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

    /// Buffer an expiry update.
    pub fn updateNameExpiry(self: *WriteBuffer, namehash: Hash, expiry: u64) !void {
        const key = namehash.bytes;
        const gop = try self.names.getOrPut(key);

        if (gop.found_existing) {
            if (gop.value_ptr.is_new) {
                gop.value_ptr.record.?.expiry = expiry;
            } else {
                gop.value_ptr.expiry = expiry;
            }
        } else {
            gop.value_ptr.* = .{ .is_new = false, .expiry = expiry };
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
    pub fn updateNameWrapperState(self: *WriteBuffer, namehash: Hash, fuses: u32, expiry: i64) !void {
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
                gop.value_ptr.record.?.wrapper_expiry = expiry;
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
    pub fn updateNameWrapperExpiry(self: *WriteBuffer, namehash: Hash, expiry: i64) !void {
        const key = namehash.bytes;
        const gop = try self.names.getOrPut(key);

        if (gop.found_existing) {
            if (gop.value_ptr.is_new) {
                gop.value_ptr.record.?.wrapper_expiry = expiry;
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
    // READ OPERATIONS (check buffer, return null if not found)
    // ========================================================================

    /// Look up a buffered name by namehash. Returns the record if it was INSERT'd
    /// in this chunk. For update-only entries, returns null (caller should query DB).
    pub fn getNameByNamehash(self: *WriteBuffer, namehash: Hash) ?*models.Name {
        if (self.names.getPtr(namehash.bytes)) |bn| {
            if (bn.is_new) {
                return &bn.record.?;
            }
        }
        return null;
    }

    // ========================================================================
    // FLUSH — Write all buffered data to database
    // ========================================================================

    pub fn flush(self: *WriteBuffer, db: *Database) !void {
        const timer = std.time.milliTimestamp();
        var names_inserted: usize = 0;
        var names_updated: usize = 0;

        // 1. Flush names (events may reference names)
        var it = self.names.iterator();
        while (it.next()) |entry| {
            const bn = entry.value_ptr;

            if (bn.is_new) {
                // Single INSERT with all updates already applied to the record
                try names_storage.insertName(db, bn.record.?);
                names_inserted += 1;
            } else {
                // Apply individual updates to existing DB record
                const namehash = Hash{ .bytes = entry.key_ptr.* };

                // Unwrap must come before other wrapper updates
                if (bn.unwrap) {
                    try names_storage.updateNameUnwrapperState(db, namehash);
                }

                // Full wrapper state (from NameWrapped)
                if (bn.wrapper_state) |ws| {
                    try names_storage.updateNameWrapperState(db, namehash, ws.fuses, ws.expiry);
                }

                if (bn.owner) |owner| {
                    try names_storage.updateNameOwner(db, namehash, owner);
                }
                if (bn.expiry) |expiry| {
                    try names_storage.updateNameExpiry(db, namehash, @bitCast(expiry));
                }
                if (bn.resolver) |resolver| {
                    try names_storage.updateNameResolver(db, namehash, resolver);
                }
                if (bn.fuses_update) |fuses| {
                    try names_storage.updateNameWrapperFuses(db, namehash, fuses);
                }
                if (bn.wrapper_expiry_update) |exp| {
                    try names_storage.updateNameWrapperExpiry(db, namehash, exp);
                }
                names_updated += 1;
            }
        }

        // 2. Flush events
        for (self.events.items) |event| {
            try events_storage.insertEvent(db, event);
        }

        const elapsed = std.time.milliTimestamp() - timer;
        if (self.events.items.len > 0 or names_inserted > 0 or names_updated > 0) {
            std.log.info("  Buffer flush: {d} events, {d} name inserts, {d} name updates in {d}ms", .{
                self.events.items.len,
                names_inserted,
                names_updated,
                elapsed,
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
