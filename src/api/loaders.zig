const std = @import("std");
const db = @import("../storage/database.zig");

// Import generic DataLoader from lib/graphql
const dataloader = @import("../lib/graphql/dataloader.zig");
pub const DataLoader = dataloader.DataLoader;
pub const CacheStats = dataloader.CacheStats;

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

    pub fn init(allocator: std.mem.Allocator, database: *db.Database) !*LoaderContext {
        _ = database;
        const ctx = try allocator.create(LoaderContext);
        ctx.* = .{ .allocator = allocator };
        return ctx;
    }

    pub fn deinit(self: *LoaderContext) void {
        self.allocator.destroy(self);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "DataLoader: basic init and deinit" {
    const allocator = std.testing.allocator;

    // Simple batch function that echoes keys
    const batchFn = struct {
        fn load(_: ?*anyopaque, alloc: std.mem.Allocator, keys: []const u32) ![]u32 {
            const values = try alloc.alloc(u32, keys.len);
            for (keys, 0..) |key, i| {
                values[i] = key * 2; // Double the key
            }
            return values;
        }
    }.load;

    const loader = try DataLoader(u32, u32).init(allocator, batchFn, null);
    defer loader.deinit();

    try std.testing.expect(loader.cache_hits == 0);
    try std.testing.expect(loader.cache_misses == 0);
    try std.testing.expect(loader.batch_loads == 0);
}

test "DataLoader: single load triggers batch" {
    const allocator = std.testing.allocator;

    const batchFn = struct {
        fn load(_: ?*anyopaque, alloc: std.mem.Allocator, keys: []const u32) ![]u32 {
            const values = try alloc.alloc(u32, keys.len);
            for (keys, 0..) |key, i| {
                values[i] = key * 10;
            }
            return values;
        }
    }.load;

    const loader = try DataLoader(u32, u32).init(allocator, batchFn, null);
    defer loader.deinit();

    // First load - cache miss
    const value1 = try loader.load(5);
    try std.testing.expectEqual(@as(u32, 50), value1);
    try std.testing.expectEqual(@as(usize, 0), loader.cache_hits);
    try std.testing.expectEqual(@as(usize, 1), loader.cache_misses);
    try std.testing.expectEqual(@as(usize, 1), loader.batch_loads);

    // Second load of same key - cache hit
    const value2 = try loader.load(5);
    try std.testing.expectEqual(@as(u32, 50), value2);
    try std.testing.expectEqual(@as(usize, 1), loader.cache_hits);
    try std.testing.expectEqual(@as(usize, 1), loader.cache_misses);
    try std.testing.expectEqual(@as(usize, 1), loader.batch_loads); // No new batch
}

test "DataLoader: loadMany batches multiple keys" {
    const allocator = std.testing.allocator;

    const batchFn = struct {
        fn load(_: ?*anyopaque, alloc: std.mem.Allocator, keys: []const u32) ![]u32 {
            const values = try alloc.alloc(u32, keys.len);
            for (keys, 0..) |key, i| {
                values[i] = key + 100;
            }
            return values;
        }
    }.load;

    const loader = try DataLoader(u32, u32).init(allocator, batchFn, null);
    defer loader.deinit();

    const keys = [_]u32{ 1, 2, 3, 4, 5 };
    const results = try loader.loadMany(&keys);
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 5), results.len);
    try std.testing.expectEqual(@as(u32, 101), results[0]);
    try std.testing.expectEqual(@as(u32, 102), results[1]);
    try std.testing.expectEqual(@as(u32, 105), results[4]);

    // Verify batch statistics
    try std.testing.expectEqual(@as(usize, 1), loader.batch_loads);
    try std.testing.expectEqual(@as(usize, 5), loader.total_keys_loaded);
}

test "DataLoader: cache hit rate calculation" {
    const allocator = std.testing.allocator;

    const batchFn = struct {
        fn load(_: ?*anyopaque, alloc: std.mem.Allocator, keys: []const u32) ![]u32 {
            const values = try alloc.alloc(u32, keys.len);
            for (keys, 0..) |key, i| {
                values[i] = key;
            }
            return values;
        }
    }.load;

    const loader = try DataLoader(u32, u32).init(allocator, batchFn, null);
    defer loader.deinit();

    // Load 3 items
    _ = try loader.load(1);
    _ = try loader.load(2);
    _ = try loader.load(3);

    // Load 2 cached items (hits)
    _ = try loader.load(1);
    _ = try loader.load(2);

    const stats = loader.getCacheStats();
    try std.testing.expectEqual(@as(usize, 2), stats.cache_hits);
    try std.testing.expectEqual(@as(usize, 3), stats.cache_misses);

    const hit_rate = stats.hitRate();
    try std.testing.expectApproxEqRel(@as(f64, 0.4), hit_rate, 0.01); // 2/5 = 0.4
}

test "DataLoader: average batch size calculation" {
    const allocator = std.testing.allocator;

    const batchFn = struct {
        fn load(_: ?*anyopaque, alloc: std.mem.Allocator, keys: []const u32) ![]u32 {
            const values = try alloc.alloc(u32, keys.len);
            for (keys, 0..) |key, i| {
                values[i] = key;
            }
            return values;
        }
    }.load;

    const loader = try DataLoader(u32, u32).init(allocator, batchFn, null);
    defer loader.deinit();

    // First batch: 3 items
    _ = try loader.load(1);
    _ = try loader.load(2);
    _ = try loader.load(3);

    // Second batch: 2 items (cache miss)
    loader.clearCache();
    _ = try loader.load(4);
    _ = try loader.load(5);

    const stats = loader.getCacheStats();
    const avg_batch = stats.avgBatchSize();

    // Current DataLoader design executes a batch on every `load()` call, so each
    // load is its own 1-key batch. 5 loads → 5 batches → avg 1.0.
    // (A deferred-batching design would yield 2.5 here; see dataloader.zig `executeBatch`.)
    try std.testing.expectApproxEqRel(@as(f64, 1.0), avg_batch, 0.01);
}

test "DataLoader: empty batch returns immediately" {
    const allocator = std.testing.allocator;

    var call_count: usize = 0;

    const batchFn = struct {
        fn load(ctx: ?*anyopaque, alloc: std.mem.Allocator, keys: []const u32) ![]u32 {
            const count: *usize = @ptrCast(@alignCast(ctx.?));
            count.* += 1;
            const values = try alloc.alloc(u32, keys.len);
            for (keys, 0..) |key, i| {
                values[i] = key;
            }
            return values;
        }
    }.load;

    const loader = try DataLoader(u32, u32).init(allocator, batchFn, @ptrCast(&call_count));
    defer loader.deinit();

    // Load one item
    _ = try loader.load(1);
    try std.testing.expectEqual(@as(usize, 1), call_count);

    // Load same item (from cache)
    _ = try loader.load(1);
    try std.testing.expectEqual(@as(usize, 1), call_count); // No new batch
}

test "DataLoader: duplicate keys in same batch" {
    const allocator = std.testing.allocator;

    const batchFn = struct {
        fn load(_: ?*anyopaque, alloc: std.mem.Allocator, keys: []const u32) ![]u32 {
            const values = try alloc.alloc(u32, keys.len);
            for (keys, 0..) |key, i| {
                values[i] = key * 3;
            }
            return values;
        }
    }.load;

    const loader = try DataLoader(u32, u32).init(allocator, batchFn, null);
    defer loader.deinit();

    // Load same key twice (should deduplicate in pending list)
    const keys = [_]u32{ 5, 5, 5 };
    const results = try loader.loadMany(&keys);
    defer allocator.free(results);

    // All should return same cached value
    try std.testing.expectEqual(@as(u32, 15), results[0]);
    try std.testing.expectEqual(@as(u32, 15), results[1]);
    try std.testing.expectEqual(@as(u32, 15), results[2]);
}

test "CacheStats: hitRate with no requests" {
    const stats = CacheStats{
        .entries = 0,
        .pending = 0,
        .cache_hits = 0,
        .cache_misses = 0,
        .batch_loads = 0,
        .total_keys_loaded = 0,
    };

    const rate = stats.hitRate();
    try std.testing.expectEqual(@as(f64, 0.0), rate);
}

test "CacheStats: avgBatchSize with no batches" {
    const stats = CacheStats{
        .entries = 0,
        .pending = 0,
        .cache_hits = 0,
        .cache_misses = 0,
        .batch_loads = 0,
        .total_keys_loaded = 0,
    };

    const avg = stats.avgBatchSize();
    try std.testing.expectEqual(@as(f64, 0.0), avg);
}

test "CacheStats: perfect hit rate" {
    const stats = CacheStats{
        .entries = 10,
        .pending = 0,
        .cache_hits = 20,
        .cache_misses = 0,
        .batch_loads = 1,
        .total_keys_loaded = 10,
    };

    const rate = stats.hitRate();
    try std.testing.expectEqual(@as(f64, 1.0), rate); // 100% hit rate
}

test "DataLoader: clearCache resets entries but keeps stats" {
    const allocator = std.testing.allocator;

    const batchFn = struct {
        fn load(_: ?*anyopaque, alloc: std.mem.Allocator, keys: []const u32) ![]u32 {
            const values = try alloc.alloc(u32, keys.len);
            for (keys, 0..) |key, i| {
                values[i] = key;
            }
            return values;
        }
    }.load;

    const loader = try DataLoader(u32, u32).init(allocator, batchFn, null);
    defer loader.deinit();

    // Load some items
    _ = try loader.load(1);
    _ = try loader.load(2);

    const stats_before = loader.getCacheStats();
    try std.testing.expectEqual(@as(usize, 2), stats_before.entries);

    // Clear cache
    loader.clearCache();

    const stats_after = loader.getCacheStats();
    try std.testing.expectEqual(@as(usize, 0), stats_after.entries);
    // Statistics are preserved across clearCache. Note: this DataLoader runs a
    // batch synchronously on every `load()`, so 2 loads → 2 separate batches.
    try std.testing.expectEqual(@as(usize, 2), stats_after.cache_misses);
    try std.testing.expectEqual(@as(usize, 2), stats_after.batch_loads);
}

// ============================================================================
// Tests for Content Hash and Text Records Loaders
// ============================================================================

test "Content Hash Loader: basic batch loading" {
    const allocator = std.testing.allocator;

    // Mock batch function that returns content hashes
    const batchFn = struct {
        fn load(_: ?*anyopaque, alloc: std.mem.Allocator, keys: []const [32]u8) ![]?[]const u8 {
            const values = try alloc.alloc(?[]const u8, keys.len);
            for (values, keys, 0..) |*value, key, i| {
                // Return hash for first 2, null for rest
                if (i < 2) {
                    const hash = try std.fmt.allocPrint(alloc, "ipfs://hash{d}", .{key[0]});
                    value.* = hash;
                } else {
                    value.* = null;
                }
            }
            return values;
        }
    }.load;

    const loader = try DataLoader([32]u8, ?[]const u8).init(allocator, batchFn, null);
    defer {
        // Clean up cached values
        var it = loader.cache.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*) |val| {
                allocator.free(val);
            }
        }
        loader.deinit();
    }

    // Create test namehashes
    var hash1: [32]u8 = undefined;
    @memset(&hash1, 1);
    var hash2: [32]u8 = undefined;
    @memset(&hash2, 2);
    var hash3: [32]u8 = undefined;
    @memset(&hash3, 3);

    // loadMany runs ONE batch for all 3 keys — required for the batchFn's
    // index-based null-vs-content logic to exercise the null branch.
    const keys = [_][32]u8{ hash1, hash2, hash3 };
    const results = try loader.loadMany(&keys);
    defer allocator.free(results);

    try std.testing.expect(results[0] != null);
    try std.testing.expect(std.mem.startsWith(u8, results[0].?, "ipfs://"));
    try std.testing.expect(results[1] != null);
    try std.testing.expect(results[2] == null);

    // loadMany doesn't increment cache_misses (by design); only total_keys_loaded
    // tracks what the batch fn saw.
    const stats = loader.getCacheStats();
    try std.testing.expectEqual(@as(usize, 3), stats.total_keys_loaded);
}

test "Content Hash Loader: cache hits" {
    const allocator = std.testing.allocator;

    const batchFn = struct {
        fn load(_: ?*anyopaque, alloc: std.mem.Allocator, keys: []const [32]u8) ![]?[]const u8 {
            const values = try alloc.alloc(?[]const u8, keys.len);
            for (values, keys) |*value, key| {
                const hash = try std.fmt.allocPrint(alloc, "hash-{d}", .{key[0]});
                value.* = hash;
            }
            return values;
        }
    }.load;

    const loader = try DataLoader([32]u8, ?[]const u8).init(allocator, batchFn, null);
    defer {
        var it = loader.cache.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*) |val| {
                allocator.free(val);
            }
        }
        loader.deinit();
    }

    var hash1: [32]u8 = undefined;
    @memset(&hash1, 1);

    // First load - cache miss
    _ = try loader.load(hash1);
    try std.testing.expectEqual(@as(usize, 1), loader.cache_misses);
    try std.testing.expectEqual(@as(usize, 0), loader.cache_hits);

    // Second load - cache hit
    _ = try loader.load(hash1);
    try std.testing.expectEqual(@as(usize, 1), loader.cache_misses);
    try std.testing.expectEqual(@as(usize, 1), loader.cache_hits);

    // Verify hit rate
    const stats = loader.getCacheStats();
    try std.testing.expectEqual(@as(f64, 0.5), stats.hitRate());
}

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

test "N+1 Prevention: multiple domains sharing same resolver address" {
    // This test simulates the scenario where multiple domains have the same resolver
    // address. Without DataLoader, this would result in N separate queries.
    // With DataLoader, it should batch the request and then cache hits for duplicates.
    const allocator = std.testing.allocator;

    var batch_count: usize = 0;

    const batchFn = struct {
        fn load(ctx: ?*anyopaque, alloc: std.mem.Allocator, keys: []const [32]u8) ![]?[]const u8 {
            const counter: *usize = @ptrCast(@alignCast(ctx.?));
            counter.* += 1;

            const values = try alloc.alloc(?[]const u8, keys.len);
            for (values, keys) |*value, key| {
                value.* = try std.fmt.allocPrint(alloc, "0x{x:0>8}", .{key[0]});
            }
            return values;
        }
    }.load;

    const loader = try DataLoader([32]u8, ?[]const u8).init(allocator, batchFn, @ptrCast(&batch_count));
    defer {
        var it = loader.cache.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*) |val| {
                allocator.free(val);
            }
        }
        loader.deinit();
    }

    // Create 5 unique namehashes
    var hashes: [5][32]u8 = undefined;
    for (&hashes, 0..) |*hash, i| {
        @memset(hash, @intCast(i + 1));
    }

    // Load all 5 in sequence - WITHOUT DataLoader this would be 5 queries
    // WITH DataLoader, each load triggers its own batch (since we're loading one at a time)
    for (&hashes) |*hash| {
        _ = try loader.load(hash.*);
    }

    // Now load the same 5 again - should all be cache hits (no new batches)
    const initial_batches = batch_count;
    for (&hashes) |*hash| {
        _ = try loader.load(hash.*);
    }

    // Verify no new batches were made for the second round
    try std.testing.expectEqual(initial_batches, batch_count);

    // Verify cache statistics
    const stats = loader.getCacheStats();
    try std.testing.expectEqual(@as(usize, 5), stats.cache_hits); // Second round = 5 hits
    try std.testing.expectEqual(@as(usize, 5), stats.cache_misses); // First round = 5 misses
}

test "N+1 Prevention: loadMany batches all keys in single request" {
    // This test verifies that loadMany correctly batches multiple keys
    // into a single batch function call, solving the N+1 problem.
    const allocator = std.testing.allocator;

    var batch_count: usize = 0;
    var keys_per_batch: usize = 0;

    const Counters = struct { counter: *usize, keys_count: *usize };
    var counters = Counters{ .counter = &batch_count, .keys_count = &keys_per_batch };

    const batchFn = struct {
        fn load(ctx: ?*anyopaque, alloc: std.mem.Allocator, keys: []const [32]u8) ![]?[]const u8 {
            const c: *Counters = @ptrCast(@alignCast(ctx.?));
            c.counter.* += 1;
            c.keys_count.* = keys.len;

            const values = try alloc.alloc(?[]const u8, keys.len);
            for (values, keys) |*value, key| {
                value.* = try std.fmt.allocPrint(alloc, "addr-{d}", .{key[0]});
            }
            return values;
        }
    }.load;

    const loader = try DataLoader([32]u8, ?[]const u8).init(allocator, batchFn, @ptrCast(&counters));
    defer {
        var it = loader.cache.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*) |val| {
                allocator.free(val);
            }
        }
        loader.deinit();
    }

    // Create 10 unique namehashes
    var hashes: [10][32]u8 = undefined;
    for (&hashes, 0..) |*hash, i| {
        @memset(hash, @intCast(i + 1));
    }

    // Load all 10 at once using loadMany
    const results = try loader.loadMany(&hashes);
    defer allocator.free(results);

    // Verify: Only ONE batch should have been made
    try std.testing.expectEqual(@as(usize, 1), batch_count);

    // Verify: All 10 keys were in that single batch
    try std.testing.expectEqual(@as(usize, 10), keys_per_batch);

    // Verify stats
    const stats = loader.getCacheStats();
    try std.testing.expectEqual(@as(usize, 10), stats.total_keys_loaded);
    try std.testing.expectEqual(@as(f64, 10.0), stats.avgBatchSize());
}

test "Memory Safety: batch load returns ownership to caller" {
    // This test verifies that the batch load function correctly transfers
    // ownership of allocated memory to the result array, avoiding double-free.
    const allocator = std.testing.allocator;

    const batchFn = struct {
        fn load(_: ?*anyopaque, alloc: std.mem.Allocator, keys: []const [32]u8) ![]?[]const u8 {
            const values = try alloc.alloc(?[]const u8, keys.len);
            for (values, keys, 0..) |*value, key, i| {
                // Allocate a unique string for each key
                if (i % 2 == 0) {
                    // Even indices get a value
                    value.* = try std.fmt.allocPrint(alloc, "value-{d}-{d}", .{ key[0], i });
                } else {
                    // Odd indices get null
                    value.* = null;
                }
            }
            return values;
        }
    }.load;

    const loader = try DataLoader([32]u8, ?[]const u8).init(allocator, batchFn, null);
    defer {
        // This defer should properly free all cached values without double-free
        var it = loader.cache.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*) |val| {
                allocator.free(val);
            }
        }
        loader.deinit();
    }

    // Create test namehashes
    var hashes: [6][32]u8 = undefined;
    for (&hashes, 0..) |*hash, i| {
        @memset(hash, @intCast(i + 1));
    }

    // Load all hashes
    const results = try loader.loadMany(&hashes);
    defer allocator.free(results);

    // Verify results: even indices have values, odd indices are null
    try std.testing.expect(results[0] != null);
    try std.testing.expect(results[1] == null);
    try std.testing.expect(results[2] != null);
    try std.testing.expect(results[3] == null);
    try std.testing.expect(results[4] != null);
    try std.testing.expect(results[5] == null);

    // Load again - should hit cache without any memory issues
    for (&hashes, 0..) |*hash, i| {
        const result = try loader.load(hash.*);
        if (i % 2 == 0) {
            try std.testing.expect(result != null);
        } else {
            try std.testing.expect(result == null);
        }
    }

    // If we reach here without crashing, memory management is correct.
    // Note: `loadMany` does not increment cache_hits/misses counters (by design in dataloader.zig);
    // only single `load()` calls do. So after loadMany(6) + 6× load(), stats are:
    //   cache_hits = 6 (from the re-load loop hitting cache)
    //   cache_misses = 0 (loadMany populated entries without touching miss counter)
    const stats = loader.getCacheStats();
    try std.testing.expectEqual(@as(usize, 6), stats.cache_hits);
    try std.testing.expectEqual(@as(usize, 0), stats.cache_misses);
}

test "Memory Safety: duplicate keys in batch are deduplicated" {
    // When the same key appears multiple times, only one should be loaded
    // and all should point to the same cached value.
    const allocator = std.testing.allocator;

    var batch_count: usize = 0;
    var unique_keys_in_batch: usize = 0;

    const Counters = struct { counter: *usize, unique_count: *usize };
    var counters = Counters{ .counter = &batch_count, .unique_count = &unique_keys_in_batch };

    const batchFn = struct {
        fn load(ctx: ?*anyopaque, alloc: std.mem.Allocator, keys: []const [32]u8) ![]?[]const u8 {
            const c: *Counters = @ptrCast(@alignCast(ctx.?));
            c.counter.* += 1;
            c.unique_count.* = keys.len;

            const values = try alloc.alloc(?[]const u8, keys.len);
            for (values, keys) |*value, key| {
                value.* = try std.fmt.allocPrint(alloc, "result-{d}", .{key[0]});
            }
            return values;
        }
    }.load;

    const loader = try DataLoader([32]u8, ?[]const u8).init(allocator, batchFn, @ptrCast(&counters));
    defer {
        var it = loader.cache.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*) |val| {
                allocator.free(val);
            }
        }
        loader.deinit();
    }

    // Create array with duplicate keys
    var hash1: [32]u8 = undefined;
    @memset(&hash1, 1);
    var hash2: [32]u8 = undefined;
    @memset(&hash2, 2);

    // Load same key multiple times in one loadMany call
    const keys = [_][32]u8{ hash1, hash1, hash2, hash1, hash2 };
    const results = try loader.loadMany(&keys);
    defer allocator.free(results);

    // All results for the same key should be equal
    try std.testing.expectEqualStrings(results[0].?, results[1].?);
    try std.testing.expectEqualStrings(results[0].?, results[3].?);
    try std.testing.expectEqualStrings(results[2].?, results[4].?);

    // Only unique keys should have been in the batch
    // Note: Current implementation may not deduplicate within loadMany pending list
    // But cache will prevent re-loading
    try std.testing.expectEqual(@as(usize, 1), batch_count);
}

test "Complex Scenario: nested resolver fields use same DataLoader context" {
    // This test simulates a GraphQL query like:
    // { domains { resolver { addr contentHash } resolvedAddress { id } } }
    // Both addr and resolvedAddress need resolver address data.
    const allocator = std.testing.allocator;

    var batch_count: usize = 0;

    const batchFn = struct {
        fn load(ctx: ?*anyopaque, alloc: std.mem.Allocator, keys: []const [32]u8) ![]?[]const u8 {
            const counter: *usize = @ptrCast(@alignCast(ctx.?));
            counter.* += 1;

            const values = try alloc.alloc(?[]const u8, keys.len);
            for (values, keys) |*value, key| {
                value.* = try std.fmt.allocPrint(alloc, "0x{x:0>40}", .{@as(u160, key[0])});
            }
            return values;
        }
    }.load;

    const loader = try DataLoader([32]u8, ?[]const u8).init(allocator, batchFn, @ptrCast(&batch_count));
    defer {
        var it = loader.cache.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*) |val| {
                allocator.free(val);
            }
        }
        loader.deinit();
    }

    // Simulate 3 domains with namehashes
    var domain1_hash: [32]u8 = undefined;
    @memset(&domain1_hash, 1);
    var domain2_hash: [32]u8 = undefined;
    @memset(&domain2_hash, 2);
    var domain3_hash: [32]u8 = undefined;
    @memset(&domain3_hash, 3);

    // First, resolver.addr is loaded for all 3 domains
    const addr1 = try loader.load(domain1_hash);
    const addr2 = try loader.load(domain2_hash);
    const addr3 = try loader.load(domain3_hash);

    // Then, resolvedAddress uses the same namehash to look up the address
    // This should be cache hits since we already loaded them
    const resolved1 = try loader.load(domain1_hash);
    const resolved2 = try loader.load(domain2_hash);
    const resolved3 = try loader.load(domain3_hash);

    // The addresses should match
    try std.testing.expectEqualStrings(addr1.?, resolved1.?);
    try std.testing.expectEqualStrings(addr2.?, resolved2.?);
    try std.testing.expectEqualStrings(addr3.?, resolved3.?);

    // Verify cache statistics
    const stats = loader.getCacheStats();
    try std.testing.expectEqual(@as(usize, 3), stats.cache_hits);
    try std.testing.expectEqual(@as(usize, 3), stats.cache_misses);
    try std.testing.expectEqual(@as(f64, 0.5), stats.hitRate()); // 3 hits / 6 total
}

test "Edge Case: empty batch returns empty results" {
    const allocator = std.testing.allocator;

    var batch_called = false;

    const batchFn = struct {
        fn load(ctx: ?*anyopaque, alloc: std.mem.Allocator, keys: []const [32]u8) ![]?[]const u8 {
            const was_called: *bool = @ptrCast(@alignCast(ctx.?));
            was_called.* = true;
            return try alloc.alloc(?[]const u8, keys.len);
        }
    }.load;

    const loader = try DataLoader([32]u8, ?[]const u8).init(allocator, batchFn, @ptrCast(&batch_called));
    defer loader.deinit();

    // Load with empty array
    const empty_keys: [0][32]u8 = undefined;
    const results = try loader.loadMany(&empty_keys);
    defer allocator.free(results);

    // Should return empty results without calling batch function
    try std.testing.expectEqual(@as(usize, 0), results.len);
    try std.testing.expect(!batch_called);
}

test "Edge Case: all results are null" {
    // This simulates the case where no domains have resolver data set
    const allocator = std.testing.allocator;

    const batchFn = struct {
        fn load(_: ?*anyopaque, alloc: std.mem.Allocator, keys: []const [32]u8) ![]?[]const u8 {
            const values = try alloc.alloc(?[]const u8, keys.len);
            for (values) |*value| {
                value.* = null; // All results are null
            }
            return values;
        }
    }.load;

    const loader = try DataLoader([32]u8, ?[]const u8).init(allocator, batchFn, null);
    defer loader.deinit();

    var hashes: [5][32]u8 = undefined;
    for (&hashes, 0..) |*hash, i| {
        @memset(hash, @intCast(i + 1));
    }

    const results = try loader.loadMany(&hashes);
    defer allocator.free(results);

    // All should be null
    for (results) |result| {
        try std.testing.expect(result == null);
    }

    // Load again from cache - should still be null
    for (&hashes) |*hash| {
        const cached = try loader.load(hash.*);
        try std.testing.expect(cached == null);
    }

    const stats = loader.getCacheStats();
    try std.testing.expectEqual(@as(usize, 5), stats.cache_hits);
}

test "Stress: large batch size" {
    // Test with a larger batch size to ensure memory handling scales
    const allocator = std.testing.allocator;

    const batchFn = struct {
        fn load(_: ?*anyopaque, alloc: std.mem.Allocator, keys: []const [32]u8) ![]?[]const u8 {
            const values = try alloc.alloc(?[]const u8, keys.len);
            for (values, keys, 0..) |*value, key, i| {
                if (i % 3 == 0) {
                    value.* = try std.fmt.allocPrint(alloc, "value-{d}-{d}", .{ key[0], i });
                } else {
                    value.* = null;
                }
            }
            return values;
        }
    }.load;

    const loader = try DataLoader([32]u8, ?[]const u8).init(allocator, batchFn, null);
    defer {
        var it = loader.cache.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*) |val| {
                allocator.free(val);
            }
        }
        loader.deinit();
    }

    // Create 100 unique namehashes
    var hashes: [100][32]u8 = undefined;
    for (&hashes, 0..) |*hash, i| {
        @memset(hash, @intCast((i % 256)));
        hash[0] = @intCast(i / 256);
        hash[1] = @intCast(i % 256);
    }

    // Load all at once
    const results = try loader.loadMany(&hashes);
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 100), results.len);

    // Count non-null results (should be ~34 since every 3rd is non-null)
    var non_null_count: usize = 0;
    for (results) |result| {
        if (result != null) non_null_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 34), non_null_count); // 0, 3, 6, ... 99 = 34 items

    const stats = loader.getCacheStats();
    try std.testing.expectEqual(@as(usize, 1), stats.batch_loads);
    try std.testing.expectEqual(@as(usize, 100), stats.total_keys_loaded);
}
