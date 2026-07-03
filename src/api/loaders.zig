const std = @import("std");
const db = @import("../storage/database.zig");

// ============================================================================
// Per-request loader context
// ============================================================================
//
// All previous ENS-specific loaders (resolver_address, content_hash, text_records)
// were removed because they had a namehash-only batching key that leaked
// legacy-resolver records for migrated names. See:
//   - src/api/builders/impl.zig — handlers bypass the loader layer and query
//     with (resolver, namehash) for correctness.
//   - schema/022_resolver_composite_unique.sql — enforces the invariant at the DB.
//
// The struct is kept as a zero-field stub so existing plumbing in handler.zig and
// the executor's `loaders: ?*anyopaque` field remains valid. Future batching would
// add fields here, keyed appropriately to avoid the legacy bug.
pub const LoaderContext = struct {
    allocator: std.mem.Allocator,
    /// Per-request memoization for Account rows. The four `seenV1` / `seenV2` /
    /// `firstSeenBlock` / `firstSeenTimestamp` field handlers each fetch the
    /// same row; in list queries that pull all four, the per-row count drops
    /// from 4 → 1 with this cache. Keyed by 0x-prefixed lowercase address;
    /// the entry value is the loaded row (or null sentinel for "looked up,
    /// no such account"). Cache keys live on `allocator` (the request arena);
    /// the row values' inner slices are owned by `db_allocator` — db.getAccount
    /// dupes `.address` on the persistent db allocator, not the arena — so
    /// deinit must free both explicitly.
    account_cache: std.StringHashMap(?db.Account),
    db_allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, database: *db.Database) !*LoaderContext {
        const ctx = try allocator.create(LoaderContext);
        ctx.* = .{
            .allocator = allocator,
            .account_cache = std.StringHashMap(?db.Account).init(allocator),
            .db_allocator = database.allocator,
        };
        return ctx;
    }

    /// Returns the cached row for `address`, fetching from the DB on first miss.
    /// The returned pointer is owned by the LoaderContext (arena-scoped); callers
    /// must not free it.
    pub fn getAccountCached(self: *LoaderContext, database: *db.Database, address: []const u8) !?*const db.Account {
        if (self.account_cache.getPtr(address)) |existing| {
            if (existing.*) |*row| return row;
            return null;
        }
        const fetched = try database.getAccount(address);
        // Dupe the key onto the arena so the cache key outlives the caller's `address`.
        const key_owned = try self.allocator.dupe(u8, address);
        try self.account_cache.put(key_owned, fetched);
        if (self.account_cache.getPtr(key_owned)) |slot| {
            if (slot.*) |*row| return row;
        }
        return null;
    }

    pub fn deinit(self: *LoaderContext) void {
        var it = self.account_cache.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*) |acct| {
                var row = acct;
                row.deinit(self.db_allocator); // frees .address (db-allocator-owned)
            }
            self.allocator.free(entry.key_ptr.*); // arena key (no-op on arena; correct on GPA)
        }
        self.account_cache.deinit();
        self.allocator.destroy(self);
    }
};

// ============================================================================
// Tests
// ============================================================================

// ============================================================================
// Tests for Content Hash and Text Records Loaders
// ============================================================================

test "LoaderContext: init and deinit" {
    const allocator = std.testing.allocator;

    var test_db = try db.Database.init(allocator, ":memory:");
    defer test_db.deinit();

    const ctx = try LoaderContext.init(allocator, &test_db);
    defer ctx.deinit();
}

// ============================================================================
// Complex Scenario Tests for N+1 Query Problem and Memory Management
// ============================================================================
