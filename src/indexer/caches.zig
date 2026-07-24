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
const Hash = @import("../types/hash.zig").Hash;
const Address = @import("../types/address.zig").Address;
const Indexer = @import("indexer.zig").Indexer;

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

/// Look up a label from v1_label_cache, falling back to DB on miss
pub fn getCachedV1Label(self: *Indexer, token_id_hex: []const u8) !?[]const u8 {
    // Check cache first
    if (self.v1_label_cache.get(token_id_hex)) |label| {
        return label;
    }

    // Cache miss - query DB
    const v1_names = @import("../utils/v1_names.zig");
    const label = try v1_names.tokenIdToLabel(self.allocator, self.database, token_id_hex) orelse return null;

    // Store in cache (need to dupe the key since token_id_hex may be temporary)
    const key_copy = try self.allocator.dupe(u8, token_id_hex);
    errdefer self.allocator.free(key_copy);
    try self.v1_label_cache.put(key_copy, label);

    return label;
}

/// Add a label to the v1_label_cache (called when storeTokenIdLabel succeeds)
pub fn putCachedV1Label(self: *Indexer, token_id_hex: []const u8, label: []const u8) !void {
    // Check if already cached
    if (self.v1_label_cache.contains(token_id_hex)) return;

    const key_copy = try self.allocator.dupe(u8, token_id_hex);
    errdefer self.allocator.free(key_copy);
    const val_copy = try self.allocator.dupe(u8, label);
    errdefer self.allocator.free(val_copy);
    try self.v1_label_cache.put(key_copy, val_copy);
}

/// Resolve a labelhash to its plaintext label using the rainbow table.
/// Returns owned string (caller must free) or null if not found.
pub fn resolveLabel(self: *Indexer, labelhash: Hash) ?[]const u8 {
    var r = self.rainbow orelse return null;
    return r.lookup(labelhash.bytes) catch null;
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
    const name = (self.database.getNameStringByNamehash(namehash, self.allocator) catch null) orelse return null;
    const copy = self.allocator.dupe(u8, name) catch return name;
    self.name_by_namehash_cache.put(namehash, copy) catch {
        self.allocator.free(copy);
        return name;
    };
    return name;
}
