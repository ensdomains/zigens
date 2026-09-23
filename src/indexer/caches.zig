//! In-memory cache and dedup accessors for the Indexer.
//!
//! Leaf helpers over the Indexer's in-memory caches, allocator, and database —
//! split out of indexer.zig using the file's established pattern: the bodies live
//! here as `pub fn f(self: *Indexer, ...)` and indexer.zig keeps `pub const f =
//! caches.f;` aliases, so both `self.f(...)` method calls and `Indexer.f` qualified
//! access resolve unchanged. Struct fields are reached through `self` (Zig fields
//! are not private across files).

const std = @import("std");
const zsys = @import("../utils/system.zig");
const models = @import("../types/models.zig");
const rpc = @import("../rpc/client.zig");
const Hash = @import("../types/hash.zig").Hash;
const Address = @import("../types/address.zig").Address;
const Indexer = @import("indexer.zig").Indexer;

pub const PairedName = struct {
    namehash: Hash,
    /// Owned by the caller (free with the indexer allocator).
    name: ?[]u8,
};

/// names_read.getNameByTokenIdAndRegistry's (namehash, name) projection —
/// answered from the dispatch-scoped prefetch when it is authoritative, by
/// the DB point lookup otherwise. Every handler that keys on (token id,
/// emitting registry) goes through here so a dispatch costs one IN-list load
/// instead of one round trip per event.
pub fn lookupPairedName(self: *Indexer, token_id: u256, registry: Address) !?PairedName {
    if (self.name_prefetch) |np| {
        switch (try np.pairedLookup(token_id, registry, self.allocator)) {
            .unknown => {},
            .miss => return null,
            .hit => |hit| return .{ .namehash = hit.namehash, .name = hit.name },
        }
    }
    const row = (try self.database.getNameByTokenIdAndRegistry(token_id, registry)) orelse return null;
    var row_mut = row;
    defer row_mut.deinit(self.allocator);
    const name_copy: ?[]u8 = if (row_mut.name) |n| try self.allocator.dupe(u8, n) else null;
    return .{ .namehash = row_mut.namehash, .name = name_copy };
}

/// Database.names_barrier target: land every buffered name before a storage
/// names accessor runs. Armed by the driver for the buffered V2 window only.
pub fn namesBarrierFlush(ctx: *anyopaque) anyerror!void {
    const self: *Indexer = @ptrCast(@alignCast(ctx));
    try self.write_buffer.flushNames(self.database);
}

/// Entity writes (name owner/resolver, registrations, resolver entities,
/// accounts) are buffered under the same invariant as eac_roles: only while
/// the reorg cursor is disarmed. See write_buffer.zig.
pub fn bufferingEntities(self: *Indexer) bool {
    return self.write_buffer.active and !self.reorg_arm;
}

pub fn setNameOwner(self: *Indexer, namehash: Hash, owner: Address) !void {
    if (self.bufferingEntities()) return self.write_buffer.updateNameOwner(namehash, owner);
    try self.database.updateNameOwner(namehash, owner);
}

pub fn setNameResolver(self: *Indexer, namehash: Hash, resolver: Address) !void {
    if (self.bufferingEntities()) return self.write_buffer.updateNameResolver(namehash, resolver);
    try self.database.updateNameResolver(namehash, resolver);
}

/// True when the row (protocol scope of `registry`, `namehash`) already
/// exists for `token_id` — i.e. the registry's LabelRegistered was processed.
pub fn registeredNameExists(self: *Indexer, token_id: u256, registry: Address, namehash: Hash) !bool {
    const hit = (try self.lookupPairedName(token_id, registry)) orelse return false;
    defer if (hit.name) |n| self.allocator.free(n);
    return hit.namehash.eql(namehash);
}

/// Register a resolver as known, deduplicated in-memory: the first observation per
/// (protocol, address) this run does the DB upsert; later observations are skipped.
/// `known_resolvers` is membership-only (its `last_indexed_block` is never read), so
/// skipping is safe and removes the bulk of per-event resolver upserts during sync.
pub fn registerResolverOnce(self: *Indexer, protocol: models.Protocol, address_hex: []const u8, block_number: u64) !void {
    var key_buf: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ protocol.toString(), address_hex }) catch address_hex;
    if (self.known_resolver_cache.contains(key)) return;
    try self.database.registerResolver(protocol, address_hex, block_number);
    const key_copy = try self.allocator.dupe(u8, key);
    errdefer self.allocator.free(key_copy);
    try self.known_resolver_cache.put(key_copy, {});
}

/// Like registerResolverOnce, but reports whether this was the resolver's FIRST
/// sighting ever (not in the dedup cache AND not in known_resolvers). First
/// sightings queue a historical backfill: factory-deployed resolvers emit their
/// initialize()-time EACRolesChanged role grants blocks before the
/// ResolverUpdated that makes them known — without the backfill those roles
/// never reach resolver.roles (the discovery-path backfill can't recover them;
/// registering here makes its `kr.address IS NULL` filter false first).
pub fn registerResolverOnceIfNew(self: *Indexer, protocol: models.Protocol, address_hex: []const u8, block_number: u64) !bool {
    var key_buf: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ protocol.toString(), address_hex }) catch address_hex;
    if (self.known_resolver_cache.contains(key)) return false;
    const was_new = try self.database.registerResolverIfNew(protocol, address_hex, block_number);
    const key_copy = try self.allocator.dupe(u8, key);
    errdefer self.allocator.free(key_copy);
    try self.known_resolver_cache.put(key_copy, {});
    return was_new;
}

/// Drop the in-memory resolver dedup cache. MUST be called whenever a batch
/// transaction is rolled back: the rollback also reverts any known_resolvers inserts
/// the batch made, so a cached-but-reverted resolver would otherwise be skipped
/// forever and never re-inserted (membership loss). Cheap to rebuild.
pub fn clearKnownResolverCache(self: *Indexer) void {
    var it = self.known_resolver_cache.keyIterator();
    while (it.next()) |k| self.allocator.free(k.*);
    self.known_resolver_cache.clearRetainingCapacity();
}

/// Drop the in-memory account-observation dedup cache. Like clearKnownResolverCache,
/// MUST run on batch rollback so reverted account upserts get re-applied next pass.
pub fn clearAccountObsCache(self: *Indexer) void {
    var it = self.account_obs_cache.keyIterator();
    while (it.next()) |k| self.allocator.free(k.*);
    self.account_obs_cache.clearRetainingCapacity();
}

/// Invalidate the cached active controllers list (call after ControllerAdded/Removed)
pub fn invalidateControllerCache(self: *Indexer) void {
    if (self.v1_active_controllers) |controllers| {
        self.allocator.free(controllers);
        self.v1_active_controllers = null;
    }
}

/// Get active controllers, loading from DB on first access or after invalidation
pub fn getOrLoadActiveControllers(self: *Indexer) ![]const Address {
    if (self.v1_active_controllers) |controllers| {
        return controllers;
    }
    const v1_controllers = @import("../storage/v1_controllers.zig");
    const controllers = try v1_controllers.getActiveControllers(self.allocator, self.database);
    self.v1_active_controllers = controllers;
    return controllers;
}

/// Look up a label from v1_label_cache, falling back to DB on miss. Misses are
/// cached as an empty-string sentinel: unknown-label tokens fire 2-3 events each
/// (mint, transfer, renewals) and would otherwise re-query v1_labels every time.
/// The sentinel is overwritten by putCachedV1Label once the label is learned.
pub fn getCachedV1Label(self: *Indexer, token_id_hex: []const u8) !?[]const u8 {
    // Check cache first
    if (self.v1_label_cache.get(token_id_hex)) |label| {
        return if (label.len == 0) null else label;
    }

    // Cache miss - query DB
    const v1_names = @import("../utils/v1_names.zig");
    const label = try v1_names.tokenIdToLabel(self.allocator, self.database, token_id_hex) orelse {
        const key_copy = try self.allocator.dupe(u8, token_id_hex);
        errdefer self.allocator.free(key_copy);
        const sentinel = try self.allocator.dupe(u8, "");
        errdefer self.allocator.free(sentinel);
        try self.v1_label_cache.put(key_copy, sentinel);
        return null;
    };

    // Store in cache (need to dupe the key since token_id_hex may be temporary)
    const key_copy = try self.allocator.dupe(u8, token_id_hex);
    errdefer self.allocator.free(key_copy);
    try self.v1_label_cache.put(key_copy, label);

    return label;
}

/// Add a label to the v1_label_cache (called when storeTokenIdLabel succeeds)
pub fn putCachedV1Label(self: *Indexer, token_id_hex: []const u8, label: []const u8) !void {
    // Already cached with a real label: done. A cached miss-sentinel must be
    // replaced now that the label is known.
    if (self.v1_label_cache.get(token_id_hex)) |existing| {
        if (existing.len != 0) return;
        const kv = self.v1_label_cache.fetchRemove(token_id_hex).?;
        self.allocator.free(kv.key);
        self.allocator.free(kv.value);
    }

    const key_copy = try self.allocator.dupe(u8, token_id_hex);
    errdefer self.allocator.free(key_copy);
    const val_copy = try self.allocator.dupe(u8, label);
    errdefer self.allocator.free(val_copy);
    try self.v1_label_cache.put(key_copy, val_copy);
}

/// Resolve a labelhash to its plaintext label using the rainbow table.
/// Returns a BORROWED string (owned by rainbow_cache) or null. Both hits and
/// misses are memoized; probe count/time accumulate for the chunk timing line.
pub fn resolveLabel(self: *Indexer, labelhash: Hash) ?[]const u8 {
    if (self.rainbow_cache.get(labelhash.bytes)) |cached| {
        return if (cached.len == 0) null else cached;
    }
    var r = self.rainbow orelse return null;
    const t0 = zsys.nanoTimestamp();
    const looked_up = r.lookup(labelhash.bytes) catch null;
    self.rainbow_probe_ns += @intCast(zsys.nanoTimestamp() - t0);
    self.rainbow_probe_count += 1;
    // Bound the memo: distinct labelhashes over a full backfill are finite but
    // large; reset rather than grow without limit.
    if (self.rainbow_cache.count() >= 4_000_000) {
        var it = self.rainbow_cache.valueIterator();
        while (it.next()) |v| self.allocator.free(v.*);
        self.rainbow_cache.clearRetainingCapacity();
    }
    const value: []const u8 = looked_up orelse self.allocator.dupe(u8, "") catch return looked_up;
    self.rainbow_cache.put(labelhash.bytes, value) catch {
        if (looked_up == null) self.allocator.free(value);
        return looked_up;
    };
    return if (value.len == 0) null else value;
}

/// Track block hash from a processed log (for reorg detection without extra RPC calls)
pub fn trackBlockHash(self: *Indexer, log_block_number: u64, log_block_hash: ?Hash) void {
    if (log_block_hash) |bh| {
        if (log_block_number >= self.last_seen_block_number) {
            self.last_seen_block_hash = bh;
            self.last_seen_block_number = log_block_number;
        }
    }
}

/// Reset block hash tracking (call before each outer batch)
pub fn resetBlockHashTracking(self: *Indexer) void {
    self.last_seen_block_hash = null;
    self.last_seen_block_number = 0;
}

/// Best-effort pre-resolution of every unique event block the provider didn't
/// annotate with blockTimestamp: one batched header call per 200 blocks instead
/// of a lazy per-block RPC inside dispatch. Failures degrade silently to the
/// lazy path in getBlockTimestamp; single-threaded, so WASM-portable as-is.
pub fn warmBlockTimestampCache(self: *Indexer, protocol: models.Protocol, logs_groups: []const []rpc.Log) void {
    var missing: std.ArrayList(u64) = .empty;
    defer missing.deinit(self.allocator);
    var seen = std.AutoHashMap(u64, void).init(self.allocator);
    defer seen.deinit();
    for (logs_groups) |logs| {
        for (logs) |log| {
            if (log.block_timestamp != null) continue;
            if (self.block_timestamp_cache.contains(log.block_number)) continue;
            const gop = seen.getOrPut(log.block_number) catch return;
            if (gop.found_existing) continue;
            missing.append(self.allocator, log.block_number) catch return;
        }
    }
    if (missing.items.len == 0) return;
    const client = self.getClient(protocol);
    var warmed: usize = 0;
    var start: usize = 0;
    while (start < missing.items.len) {
        const end = @min(start + 200, missing.items.len);
        const headers = client.getBlockHeadersBatch(missing.items[start..end]) catch return;
        defer self.allocator.free(headers);
        for (headers) |maybe_header| {
            const header = maybe_header orelse continue;
            const ts = std.math.cast(i64, header.timestamp) orelse continue;
            self.block_timestamp_cache.put(header.number, ts) catch {};
            warmed += 1;
        }
        start = end;
    }
    if (warmed > 0) std.log.info("Warmed {d} block timestamps in {d} batched call(s)", .{ warmed, (missing.items.len + 199) / 200 });
}

/// Get block timestamp: log-provided value if available, then cache, then RPC.
/// Errors instead of fabricating a time — a wall-clock substitute would poison
/// historical rows permanently; failing lets the batch retry.
pub fn getBlockTimestamp(self: *Indexer, protocol: models.Protocol, block_number: u64, known_timestamp: ?u64) !i64 {
    // If provider included timestamp in log response, use it directly (fastest path)
    if (known_timestamp) |ts| {
        const timestamp = std.math.cast(i64, ts) orelse return error.InvalidBlockTimestamp;
        // Also cache it for other events in the same block
        self.block_timestamp_cache.put(block_number, timestamp) catch {};
        return timestamp;
    }

    // Check cache
    if (self.block_timestamp_cache.get(block_number)) |ts| {
        return ts;
    }

    // Fetch from RPC (slowest path)
    const client = self.getClient(protocol);
    const block = client.getBlockByNumber(block_number, false) catch |err| {
        std.log.warn("Failed to fetch block {d} timestamp: {}", .{ block_number, err });
        return err;
    };

    const timestamp = std.math.cast(i64, block.timestamp) orelse return error.InvalidBlockTimestamp;

    // Cache the result
    self.block_timestamp_cache.put(block_number, timestamp) catch {
        // If cache fails, just return the timestamp without caching
    };

    return timestamp;
}

/// Clear block timestamp cache (call after processing a batch to free memory)
pub fn clearBlockTimestampCache(self: *Indexer) void {
    self.block_timestamp_cache.clearRetainingCapacity();
}

/// Look up domain name from namehash (returns null if not found).
/// Uses the narrow `getNameStringByNamehash` query — fetches only the `name`
/// column instead of the full 21-column Name row, since the caller only needs
/// the string. Saves per-event allocation/dupe overhead during reverse resolution.
pub fn getNameFromNamehash(self: *Indexer, namehash: Hash) ?[]const u8 {
    // Per-batch read cache: resolver events cluster many lookups on the same name.
    // Cache HITS only (non-null) and return an owned dupe (caller frees) so the cache
    // keeps its own copy. The cache is cleared each batch (indexBlockRange) so a
    // placeholder→real name patch is picked up on the next batch.
    if (self.name_by_namehash_cache.get(namehash)) |cached| {
        return self.allocator.dupe(u8, cached) catch null;
    }
    // Names INSERT'd this chunk live in the write buffer, not the DB — without
    // this, same-chunk lookups (e.g. events.name) silently resolve to null.
    // Not cached: the pending record is mutable until flush.
    if (self.write_buffer.active) {
        if (self.write_buffer.pendingNewName(namehash)) |pr| {
            if (pr.name) |n| return self.allocator.dupe(u8, n) catch null;
        }
    }
    const name = (self.database.getNameStringByNamehash(namehash, self.allocator) catch null) orelse return null;
    const copy = self.allocator.dupe(u8, name) catch return name;
    self.name_by_namehash_cache.put(namehash, copy) catch {
        self.allocator.free(copy);
        return name;
    };
    return name;
}
