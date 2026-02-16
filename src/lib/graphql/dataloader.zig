const std = @import("std");

/// Generic DataLoader for batching and caching data requests
/// K: Key type (must be hashable)
/// V: Value type
pub fn DataLoader(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        /// Cache mapping keys to loaded values
        cache: std.AutoHashMap(K, V),

        /// Pending keys waiting to be batched
        pending: std.ArrayList(K),

        /// Batch loading function - takes a context, allocator, and array of keys, returns array of values
        /// Values must be returned in the same order as keys
        batch_load_fn: *const fn (context: ?*anyopaque, allocator: std.mem.Allocator, keys: []const K) anyerror![]V,

        /// Opaque context pointer passed to the batch load function (e.g. database reference)
        context: ?*anyopaque,

        allocator: std.mem.Allocator,

        // Statistics
        cache_hits: usize,
        cache_misses: usize,
        batch_loads: usize,
        total_keys_loaded: usize,

        pub fn init(
            allocator: std.mem.Allocator,
            batch_load_fn: *const fn (context: ?*anyopaque, allocator: std.mem.Allocator, keys: []const K) anyerror![]V,
            context: ?*anyopaque,
        ) !*Self {
            const loader = try allocator.create(Self);
            loader.* = .{
                .cache = std.AutoHashMap(K, V).init(allocator),
                .pending = std.ArrayList(K){},
                .batch_load_fn = batch_load_fn,
                .context = context,
                .allocator = allocator,
                .cache_hits = 0,
                .cache_misses = 0,
                .batch_loads = 0,
                .total_keys_loaded = 0,
            };
            return loader;
        }

        pub fn deinit(self: *Self) void {
            self.cache.deinit();
            self.pending.deinit(self.allocator);
            self.allocator.destroy(self);
        }

        /// Load a single value by key
        /// If the key is in cache, returns immediately
        /// Otherwise, adds to pending batch and executes batch load
        pub fn load(self: *Self, key: K) !V {
            // Check cache first
            if (self.cache.get(key)) |cached| {
                self.cache_hits += 1;
                return cached;
            }

            // Cache miss
            self.cache_misses += 1;

            // Check if already pending to avoid duplicates
            var already_pending = false;
            for (self.pending.items) |pending_key| {
                if (keysEqual(K, key, pending_key)) {
                    already_pending = true;
                    break;
                }
            }

            if (!already_pending) {
                try self.pending.append(self.allocator, key);
            }

            // Execute batch load immediately
            // (In a more sophisticated implementation, this could be deferred)
            try self.executeBatch();

            // Return from cache
            return self.cache.get(key) orelse error.LoadFailed;
        }

        /// Load multiple values by keys (more efficient than multiple load() calls)
        pub fn loadMany(self: *Self, keys: []const K) ![]V {
            // Add all keys to pending (checking cache first)
            for (keys) |key| {
                if (self.cache.contains(key)) continue;

                var already_pending = false;
                for (self.pending.items) |pending_key| {
                    if (keysEqual(K, key, pending_key)) {
                        already_pending = true;
                        break;
                    }
                }

                if (!already_pending) {
                    try self.pending.append(self.allocator, key);
                }
            }

            // Execute batch
            try self.executeBatch();

            // Collect results from cache
            const results = try self.allocator.alloc(V, keys.len);
            for (keys, 0..) |key, i| {
                results[i] = self.cache.get(key) orelse return error.LoadFailed;
            }

            return results;
        }

        /// Execute the batch load for all pending keys
        fn executeBatch(self: *Self) !void {
            if (self.pending.items.len == 0) return;

            // Track batch load statistics
            const batch_size = self.pending.items.len;
            self.batch_loads += 1;
            self.total_keys_loaded += batch_size;

            // Call user-provided batch function
            const values = try self.batch_load_fn(self.context, self.allocator, self.pending.items);
            defer self.allocator.free(values);

            // Ensure batch function returned correct number of values
            if (values.len != self.pending.items.len) {
                return error.BatchLoadMismatch;
            }

            // Populate cache
            for (self.pending.items, values) |key, value| {
                try self.cache.put(key, value);
            }

            // Clear pending
            self.pending.clearRetainingCapacity();
        }

        /// Clear the cache (useful for testing or manual cache invalidation)
        pub fn clearCache(self: *Self) void {
            self.cache.clearRetainingCapacity();
        }

        /// Get cache statistics
        pub fn getCacheStats(self: *Self) CacheStats {
            return .{
                .entries = self.cache.count(),
                .pending = self.pending.items.len,
                .cache_hits = self.cache_hits,
                .cache_misses = self.cache_misses,
                .batch_loads = self.batch_loads,
                .total_keys_loaded = self.total_keys_loaded,
            };
        }
    };
}

pub const CacheStats = struct {
    entries: usize,
    pending: usize,
    cache_hits: usize,
    cache_misses: usize,
    batch_loads: usize,
    total_keys_loaded: usize,

    pub fn hitRate(self: CacheStats) f64 {
        const total = self.cache_hits + self.cache_misses;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.cache_hits)) / @as(f64, @floatFromInt(total));
    }

    pub fn avgBatchSize(self: CacheStats) f64 {
        if (self.batch_loads == 0) return 0.0;
        return @as(f64, @floatFromInt(self.total_keys_loaded)) / @as(f64, @floatFromInt(self.batch_loads));
    }
};

/// Helper to compare keys (handles different types)
pub fn keysEqual(comptime K: type, a: K, b: K) bool {
    const type_info = @typeInfo(K);
    return switch (type_info) {
        .int, .float, .bool, .@"enum" => a == b,
        .pointer => |ptr_info| {
            if (ptr_info.size == .slice) {
                // For slices (like []const u8), compare contents
                if (ptr_info.child == u8) {
                    return std.mem.eql(u8, a, b);
                }
            }
            // For other pointers, compare addresses
            return a == b;
        },
        .array => |arr_info| {
            // For arrays, compare element by element
            if (arr_info.child == u8) {
                return std.mem.eql(u8, &a, &b);
            }
            return std.mem.eql(arr_info.child, &a, &b);
        },
        .@"struct" => {
            // For structs, assume they implement eql or use == operator
            return a == b;
        },
        else => a == b,
    };
}

/// Optional value wrapper for nullable results
pub fn Optional(comptime V: type) type {
    return struct {
        value: ?V,
    };
}
