//! Per-dispatch in-memory prefetch of `names` rows.
//!
//! ResolverUpdated dominates V2 bulk sync (~86% of events on real ranges) and
//! its handler issues one or two point lookups per event — the largest class
//! of serial DB round trips after event-insert batching. One ordered dispatch
//! knows every tokenId it is about to process, so the driver loads all
//! matching rows up front (a few IN-list queries) and serves the handler's
//! lookups from memory. Crucially, most ResolverUpdated events follow their
//! name's registration within the SAME batch — the row doesn't exist at
//! prefetch time — so the map also learns rows as they are written
//! (write-through from insertName via the Database.name_write_listener hook).
//!
//! Correctness model — DB-equivalence by construction, for a REDUCED
//! projection (protocol, registry, canonical_id, namehash, name — exactly
//! what handleResolverUpdated consumes):
//! - `populate` loads the COMPLETE row set for each prefetched canonical id
//!   (no protocol/registry filter) and records an explicit EMPTY entry for
//!   ids with zero rows, so presence of an entry always means complete
//!   knowledge and both point-lookup shapes can be answered exactly,
//!   authoritative misses included.
//! - The names-upsert conflict tail sets every projection column to plain
//!   `excluded.*` (only created_* / resolved_address deviate, and neither is
//!   in the projection), so on_upsert can append the post-upsert row from the
//!   argument values alone — that is what makes write-through exact.
//! - `updateNameLabel` rewrites the row's name in place (protocol-scoped);
//!   every OTHER single-row writer conservatively drops the touched entries
//!   (on_namehash), and keyless multi-row writers clear the map (on_bulk).
//!   A surviving entry therefore always equals the DB.
//! - An id with no entry is `.unknown` — the caller falls back to the DB.
//! - The map lives for exactly one `dispatchOrdered` call; reorg rollback,
//!   replay, heals, and the resolver-record pass all run outside its life.
//!
//! The namehash index maps to a LIST of canonical ids: same-namehash rows
//! under different ids (v1/v2 protocol split) must all be reachable.
//!
//! `populate` parses into the embedded arena: never move a populated
//! NamePrefetch.

const std = @import("std");
const db_module = @import("database.zig");
const Database = db_module.Database;
const models = @import("../types/models.zig");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;
const token_id_utils = @import("../types/token_id.zig");
const names_read = @import("names_read.zig");

/// The projection served to lookups. `name` is a copy owned by the caller.
pub const Hit = struct {
    namehash: Hash,
    name: ?[]u8,
};

pub const Lookup = union(enum) {
    /// Not prefetched (or row-order-dependent in a way only SQL can decide) —
    /// fall back to the DB lookup.
    unknown,
    /// Authoritative: the DB lookup would return null.
    miss,
    /// Authoritative: the DB lookup would return exactly this row (projection
    /// fields). Caller frees `hit.name` with the lookup's allocator.
    hit: Hit,
};

const Row = struct {
    protocol: models.Protocol,
    registry: Address,
    namehash: Hash,
    name: ?[]const u8,
};

pub const NamePrefetch = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    /// Key present == complete row-set knowledge for that canonical id
    /// (possibly zero rows). Lists and row strings are arena-owned.
    by_cid: std.AutoHashMap(u256, std.ArrayList(Row)),
    /// namehash → canonical ids that may hold rows with it. Append-only and
    /// possibly stale (dropped ids linger) — consumers tolerate both.
    by_namehash: std.AutoHashMap(Hash, std.ArrayList(u256)),
    served: u64 = 0,
    fell_through: u64 = 0,
    paired_served: u64 = 0,
    paired_unknown: u64 = 0,
    unique_served: u64 = 0,
    unique_unknown: u64 = 0,

    pub fn init(gpa: std.mem.Allocator) NamePrefetch {
        return .{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .by_cid = std.AutoHashMap(u256, std.ArrayList(Row)).init(gpa),
            .by_namehash = std.AutoHashMap(Hash, std.ArrayList(u256)).init(gpa),
        };
    }

    pub fn deinit(self: *NamePrefetch) void {
        self.by_cid.deinit();
        self.by_namehash.deinit();
        self.arena.deinit();
    }

    pub fn populate(self: *NamePrefetch, db: *Database, token_ids: []const u256) !void {
        var cids: std.ArrayList(u256) = .empty;
        defer cids.deinit(self.gpa);
        for (token_ids) |tok| {
            const cid = token_id_utils.getCanonicalId(tok);
            const gop = try self.by_cid.getOrPut(cid);
            if (gop.found_existing) continue;
            gop.value_ptr.* = .empty;
            try cids.append(self.gpa, cid);
        }
        if (cids.items.len == 0) return;

        // Rows (and every string they carry) are arena-parsed; the projection
        // aliases the arena strings and everything is freed at deinit.
        const rows = try names_read.getNamesByCanonicalIds(db, cids.items, self.arena.allocator());
        for (rows) |row| {
            const entry = self.by_cid.getPtr(row.canonical_id) orelse continue;
            try self.indexNamehash(row.namehash, row.canonical_id);
            try entry.append(self.arena.allocator(), .{
                .protocol = row.protocol,
                .registry = row.registry,
                .namehash = row.namehash,
                .name = row.name,
            });
        }
    }

    /// Mirror of names_read.getNameByTokenIdAndRegistry
    /// (`WHERE canonical_id = ? AND registry = ? LIMIT 1` — no protocol filter).
    pub fn pairedLookup(self: *NamePrefetch, token_id: u256, registry: Address, out_alloc: std.mem.Allocator) !Lookup {
        const cid = token_id_utils.getCanonicalId(token_id);
        const list = self.by_cid.get(cid) orelse {
            self.fell_through += 1;
            self.paired_unknown += 1;
            return .unknown;
        };
        var match: ?*const Row = null;
        var count: usize = 0;
        for (list.items) |*row| {
            if (row.registry.eql(registry)) {
                count += 1;
                if (match == null) match = row;
            }
        }
        if (count > 1) {
            // More than one row for one (canonical_id, registry): LIMIT 1 row
            // order would pick arbitrarily — defer to the DB rather than guess.
            self.fell_through += 1;
            self.paired_unknown += 1;
            return .unknown;
        }
        self.served += 1;
        self.paired_served += 1;
        if (match) |m| return .{ .hit = try dupeHit(m, out_alloc) };
        return .miss;
    }

    /// Mirror of names_read.getUniqueNameByCanonicalId (protocol-filtered,
    /// LIMIT-2 uniqueness guard: zero rows and the cross-registry ambiguity
    /// both answer null).
    pub fn uniqueLookup(self: *NamePrefetch, protocol: models.Protocol, token_id: u256, out_alloc: std.mem.Allocator) !Lookup {
        const cid = token_id_utils.getCanonicalId(token_id);
        const list = self.by_cid.get(cid) orelse {
            self.fell_through += 1;
            self.unique_unknown += 1;
            return .unknown;
        };
        var match: ?*const Row = null;
        var count: usize = 0;
        for (list.items) |*row| {
            if (row.protocol == protocol) {
                count += 1;
                if (match == null) match = row;
            }
        }
        self.served += 1;
        self.unique_served += 1;
        if (count == 1) return .{ .hit = try dupeHit(match.?, out_alloc) };
        return .miss;
    }

    pub fn listener(self: *NamePrefetch) db_module.NameWriteListener {
        return .{
            .ctx = self,
            .on_upsert = onUpsert,
            .on_name_text = onNameText,
            .on_namehash = onNamehash,
            .on_bulk = onBulk,
        };
    }

    pub fn logStats(self: *const NamePrefetch) void {
        if (self.served + self.fell_through == 0) return;
        std.log.info("  Name prefetch: {d} lookups served in-memory, {d} fell through to DB (paired {d}/{d}, unique {d}/{d}, entries {d})", .{ self.served, self.fell_through, self.paired_served, self.paired_unknown, self.unique_served, self.unique_unknown, self.by_cid.count() });
    }

    fn indexNamehash(self: *NamePrefetch, namehash: Hash, cid: u256) !void {
        const gop = try self.by_namehash.getOrPut(namehash);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        for (gop.value_ptr.items) |existing| {
            if (existing == cid) return;
        }
        try gop.value_ptr.append(self.arena.allocator(), cid);
    }

    /// insertName/insertNamesBatch: the conflict target is (protocol,
    /// namehash), so exactly that row was rewritten — remove it wherever it
    /// was listed, then append the post-upsert projection to the id's entry
    /// (entry presence == complete knowledge, which the append preserves).
    /// Callbacks are infallible: any allocation failure degrades by dropping
    /// the entry, never by serving stale state.
    fn onUpsert(ctx: *anyopaque, protocol: models.Protocol, registry: Address, canonical_id: u256, namehash: Hash, name: ?[]const u8) void {
        const self: *NamePrefetch = @ptrCast(@alignCast(ctx));
        if (self.by_namehash.getPtr(namehash)) |cid_list| {
            for (cid_list.items) |cid| {
                const rows = self.by_cid.getPtr(cid) orelse continue;
                var i: usize = 0;
                while (i < rows.items.len) {
                    if (rows.items[i].protocol == protocol and rows.items[i].namehash.eql(namehash)) {
                        _ = rows.swapRemove(i);
                        continue;
                    }
                    i += 1;
                }
            }
        }
        if (self.by_cid.getPtr(canonical_id)) |entry| {
            self.indexNamehash(namehash, canonical_id) catch {
                _ = self.by_cid.remove(canonical_id);
                return;
            };
            const name_copy: ?[]const u8 = if (name) |nm|
                self.arena.allocator().dupe(u8, nm) catch {
                    _ = self.by_cid.remove(canonical_id);
                    return;
                }
            else
                null;
            entry.append(self.arena.allocator(), .{
                .protocol = protocol,
                .registry = registry,
                .namehash = namehash,
                .name = name_copy,
            }) catch {
                _ = self.by_cid.remove(canonical_id);
                return;
            };
        }
    }

    /// updateNameLabel: protocol-scoped rewrite of the name text only — the
    /// one frequent mid-batch write between a registration and its
    /// ResolverUpdated (label reveals), kept precise so entries stay hot.
    fn onNameText(ctx: *anyopaque, protocol: models.Protocol, namehash: Hash, name: []const u8) void {
        const self: *NamePrefetch = @ptrCast(@alignCast(ctx));
        const cid_list = self.by_namehash.getPtr(namehash) orelse return;
        for (cid_list.items) |cid| {
            const rows = self.by_cid.getPtr(cid) orelse continue;
            for (rows.items) |*row| {
                if (row.protocol == protocol and row.namehash.eql(namehash)) {
                    row.name = self.arena.allocator().dupe(u8, name) catch {
                        _ = self.by_cid.remove(cid);
                        break;
                    };
                }
            }
        }
    }

    /// Every other single-row writer (deletes, token-id changes, column
    /// updates outside the projection): conservatively drop every entry that
    /// may hold the row. Cheap, and provably never serves stale state.
    fn onNamehash(ctx: *anyopaque, namehash: Hash) void {
        const self: *NamePrefetch = @ptrCast(@alignCast(ctx));
        const cid_list = self.by_namehash.getPtr(namehash) orelse return;
        for (cid_list.items) |cid| {
            _ = self.by_cid.remove(cid);
        }
    }

    fn onBulk(ctx: *anyopaque) void {
        const self: *NamePrefetch = @ptrCast(@alignCast(ctx));
        self.by_cid.clearRetainingCapacity();
        self.by_namehash.clearRetainingCapacity();
    }
};

fn dupeHit(row: *const Row, alloc: std.mem.Allocator) !Hit {
    return .{
        .namehash = row.namehash,
        .name = if (row.name) |nm| try alloc.dupe(u8, nm) else null,
    };
}
