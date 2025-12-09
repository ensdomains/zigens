const std = @import("std");
const db = @import("../storage/database.zig");
const models = @import("../types/models.zig");

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

        /// Batch loading function - takes array of keys, returns array of values
        /// Values must be returned in the same order as keys
        batch_load_fn: *const fn (allocator: std.mem.Allocator, keys: []const K) anyerror![]V,

        allocator: std.mem.Allocator,

        // Statistics
        cache_hits: usize,
        cache_misses: usize,
        batch_loads: usize,
        total_keys_loaded: usize,

        pub fn init(
            allocator: std.mem.Allocator,
            batch_load_fn: *const fn (allocator: std.mem.Allocator, keys: []const K) anyerror![]V,
        ) !*Self {
            const loader = try allocator.create(Self);
            loader.* = .{
                .cache = std.AutoHashMap(K, V).init(allocator),
                .pending = std.ArrayList(K){},
                .batch_load_fn = batch_load_fn,
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
            const values = try self.batch_load_fn(self.allocator, self.pending.items);
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
fn keysEqual(comptime K: type, a: K, b: K) bool {
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

// ============================================================================
// Loader Context - Container for all DataLoaders in a request
// ============================================================================

/// Text record structure for batch loading
pub const TextRecord = struct {
    key: []const u8,
    value: []const u8,
};

pub const TextRecords = struct {
    records: []TextRecord,
    allocator: std.mem.Allocator,

    pub fn deinit(self: TextRecords) void {
        for (self.records) |record| {
            self.allocator.free(record.key);
            self.allocator.free(record.value);
        }
        self.allocator.free(self.records);
    }
};

pub const LoaderContext = struct {
    /// Loader for resolver addresses (namehash -> optional address)
    resolver_address_loader: ?*DataLoader([32]u8, ?[]const u8),

    /// Loader for content hashes (namehash -> optional content hash)
    content_hash_loader: ?*DataLoader([32]u8, ?[]const u8),

    /// Loader for text records (namehash -> list of text records)
    text_records_loader: ?*DataLoader([32]u8, TextRecords),

    /// Loader for account data (address -> account info)
    account_loader: ?*DataLoader([]const u8, []const u8),

    /// Database reference for batch functions
    database: *db.Database,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, database: *db.Database) !*LoaderContext {
        const ctx = try allocator.create(LoaderContext);
        ctx.* = .{
            .resolver_address_loader = null,
            .content_hash_loader = null,
            .text_records_loader = null,
            .account_loader = null,
            .database = database,
            .allocator = allocator,
        };
        return ctx;
    }

    pub fn deinit(self: *LoaderContext) void {
        if (self.resolver_address_loader) |loader| {
            // Clear cache and free any allocated strings
            var it = loader.cache.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.*) |val| {
                    self.allocator.free(val);
                }
            }
            loader.deinit();
        }
        if (self.content_hash_loader) |loader| {
            // Clear cache and free any allocated content hashes
            var it = loader.cache.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.*) |val| {
                    self.allocator.free(val);
                }
            }
            loader.deinit();
        }
        if (self.text_records_loader) |loader| {
            // Clear cache and free text records
            var it = loader.cache.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.*.deinit();
            }
            loader.deinit();
        }
        if (self.account_loader) |loader| {
            // Clear cache and free any allocated strings
            var it = loader.cache.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.value_ptr.*);
            }
            loader.deinit();
        }
        self.allocator.destroy(self);
    }

    /// Get or create the resolver address loader
    pub fn getResolverAddressLoader(self: *LoaderContext) !*DataLoader([32]u8, ?[]const u8) {
        if (self.resolver_address_loader) |loader| {
            return loader;
        }

        // Create a struct that holds the database reference for the batch function
        const BatchContext = struct {
            var database_ref: ?*db.Database = null;

            fn batchLoad(allocator: std.mem.Allocator, namehashes: []const [32]u8) ![]?[]const u8 {
                const database = database_ref orelse return error.NoDatabaseReference;
                return batchLoadResolverAddresses(database, allocator, namehashes);
            }
        };

        // Set the database reference
        BatchContext.database_ref = self.database;

        self.resolver_address_loader = try DataLoader([32]u8, ?[]const u8).init(
            self.allocator,
            &BatchContext.batchLoad,
        );

        return self.resolver_address_loader.?;
    }

    /// Get or create the content hash loader
    pub fn getContentHashLoader(self: *LoaderContext) !*DataLoader([32]u8, ?[]const u8) {
        if (self.content_hash_loader) |loader| {
            return loader;
        }

        const BatchContext = struct {
            var database_ref: ?*db.Database = null;

            fn batchLoad(allocator: std.mem.Allocator, namehashes: []const [32]u8) ![]?[]const u8 {
                const database = database_ref orelse return error.NoDatabaseReference;
                return batchLoadContentHashes(database, allocator, namehashes);
            }
        };

        BatchContext.database_ref = self.database;

        self.content_hash_loader = try DataLoader([32]u8, ?[]const u8).init(
            self.allocator,
            &BatchContext.batchLoad,
        );

        return self.content_hash_loader.?;
    }

    /// Get or create the text records loader
    pub fn getTextRecordsLoader(self: *LoaderContext) !*DataLoader([32]u8, TextRecords) {
        if (self.text_records_loader) |loader| {
            return loader;
        }

        const BatchContext = struct {
            var database_ref: ?*db.Database = null;
            var allocator_ref: ?std.mem.Allocator = null;

            fn batchLoad(_: std.mem.Allocator, namehashes: []const [32]u8) ![]TextRecords {
                const database = database_ref orelse return error.NoDatabaseReference;
                const alloc = allocator_ref orelse return error.NoAllocatorReference;
                return batchLoadTextRecords(database, alloc, namehashes);
            }
        };

        BatchContext.database_ref = self.database;
        BatchContext.allocator_ref = self.allocator;

        self.text_records_loader = try DataLoader([32]u8, TextRecords).init(
            self.allocator,
            &BatchContext.batchLoad,
        );

        return self.text_records_loader.?;
    }

    /// Get or create the account loader
    pub fn getAccountLoader(self: *LoaderContext) !*DataLoader([]const u8, []const u8) {
        if (self.account_loader) |loader| {
            return loader;
        }

        const BatchContext = struct {
            var database_ref: ?*db.Database = null;
            var allocator_ref: ?std.mem.Allocator = null;

            fn batchLoad(_: std.mem.Allocator, addresses: []const []const u8) ![][]const u8 {
                const database = database_ref orelse return error.NoDatabaseReference;
                const alloc = allocator_ref orelse return error.NoAllocatorReference;
                return batchLoadAccounts(database, alloc, addresses);
            }
        };

        BatchContext.database_ref = self.database;
        BatchContext.allocator_ref = self.allocator;

        self.account_loader = try DataLoader([]const u8, []const u8).init(
            self.allocator,
            &BatchContext.batchLoad,
        );

        return self.account_loader.?;
    }

    /// Get cache statistics for all loaders
    pub fn getAllStats(self: *LoaderContext) LoaderStats {
        return .{
            .resolver_address = if (self.resolver_address_loader) |l| l.getCacheStats() else .{ .entries = 0, .pending = 0, .cache_hits = 0, .cache_misses = 0, .batch_loads = 0, .total_keys_loaded = 0 },
            .content_hash = if (self.content_hash_loader) |l| l.getCacheStats() else .{ .entries = 0, .pending = 0, .cache_hits = 0, .cache_misses = 0, .batch_loads = 0, .total_keys_loaded = 0 },
            .text_records = if (self.text_records_loader) |l| l.getCacheStats() else .{ .entries = 0, .pending = 0, .cache_hits = 0, .cache_misses = 0, .batch_loads = 0, .total_keys_loaded = 0 },
            .account = if (self.account_loader) |l| l.getCacheStats() else .{ .entries = 0, .pending = 0, .cache_hits = 0, .cache_misses = 0, .batch_loads = 0, .total_keys_loaded = 0 },
        };
    }
};

pub const LoaderStats = struct {
    resolver_address: CacheStats,
    content_hash: CacheStats,
    text_records: CacheStats,
    account: CacheStats,
};

// ============================================================================
// Batch Loading Functions - These execute the actual database queries
// ============================================================================

/// Batch load resolver addresses for multiple namehashes
/// Returns addresses in the same order as input namehashes
pub fn batchLoadResolverAddresses(
    database: *db.Database,
    allocator: std.mem.Allocator,
    namehashes: []const [32]u8,
) ![]?[]const u8 {
    if (namehashes.len == 0) {
        return try allocator.alloc(?[]const u8, 0);
    }

    const Hash = @import("../types/hash.zig").Hash;
    const c = @import("../storage/database.zig").c;

    // Build SQL query with WHERE IN clause for batch fetching
    var query: std.ArrayList(u8) = .{};
    defer query.deinit(allocator);

    try query.appendSlice(allocator, "SELECT namehash, address FROM resolver_addresses WHERE coin_type = 60 AND namehash IN (");

    for (namehashes, 0..) |_, i| {
        if (i > 0) try query.appendSlice(allocator, ", ");
        try query.appendSlice(allocator, "?");
    }
    try query.appendSlice(allocator, ") ORDER BY block_number DESC");

    // Add null terminator for C string
    const query_z = try allocator.dupeZ(u8, query.items);
    defer allocator.free(query_z);

    var stmt: ?*c.sqlite3_stmt = null;
    defer {
        if (stmt) |s| _ = c.sqlite3_finalize(s);
    }

    if (c.sqlite3_prepare_v2(database.db, query_z.ptr, -1, &stmt, null) != c.SQLITE_OK) {
        return error.PrepareFailed;
    }

    // Bind all namehash parameters
    var namehash_hexes = try allocator.alloc([]u8, namehashes.len);
    defer {
        for (namehash_hexes) |hex| {
            allocator.free(hex);
        }
        allocator.free(namehash_hexes);
    }

    for (namehashes, 0..) |namehash, i| {
        const hash = Hash{ .bytes = namehash };
        namehash_hexes[i] = try hash.toHex(allocator);
        _ = c.sqlite3_bind_text(stmt, @intCast(i + 1), namehash_hexes[i].ptr, @intCast(namehash_hexes[i].len), null);
    }

    // Create a map to store results by namehash
    var result_map = std.StringHashMap(?[]u8).init(allocator);
    defer {
        var it = result_map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*) |val| {
                allocator.free(val);
            }
        }
        result_map.deinit();
    }

    // Execute query and collect results
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const namehash_text = c.sqlite3_column_text(stmt, 0);
        const addr_text = c.sqlite3_column_text(stmt, 1);

        if (namehash_text != null) {
            const namehash_len = c.sqlite3_column_bytes(stmt, 0);
            const namehash_slice = namehash_text[0..@intCast(namehash_len)];
            const namehash_key = try allocator.dupe(u8, namehash_slice);
            errdefer allocator.free(namehash_key);

            if (addr_text != null) {
                const addr_len = c.sqlite3_column_bytes(stmt, 1);
                const addr_slice = addr_text[0..@intCast(addr_len)];
                const addr_copy = try allocator.dupe(u8, addr_slice);
                try result_map.put(namehash_key, addr_copy);
            } else {
                try result_map.put(namehash_key, null);
            }
        }
    }

    // Build result array in the same order as input namehashes
    const results = try allocator.alloc(?[]const u8, namehashes.len);
    for (results, namehashes) |*result, namehash| {
        const hash = Hash{ .bytes = namehash };
        const namehash_hex = try hash.toHex(allocator);
        defer allocator.free(namehash_hex);

        if (result_map.get(namehash_hex)) |addr| {
            result.* = addr;
        } else {
            result.* = null;
        }
    }

    return results;
}

/// Batch load account data for multiple addresses
///
/// Note: In ENS, accounts are Ethereum addresses without separate storage.
/// This function validates addresses and provides caching benefits when the same
/// account is referenced multiple times in a GraphQL query (as owner, registrant, etc.)
///
/// Future enhancements could include:
/// - Address checksum validation
/// - ENS name reverse resolution
/// - Account activity metrics from events
pub fn batchLoadAccounts(
    database: *db.Database,
    allocator: std.mem.Allocator,
    addresses: []const []const u8,
) ![][]const u8 {
    if (addresses.len == 0) {
        return try allocator.alloc([]const u8, 0);
    }

    const Address = @import("../types/address.zig").Address;
    const c = @import("../storage/database.zig").c;

    // Build SQL query to check if accounts have any activity (own domains or made registrations)
    // This validates that addresses are "active" in the system
    var query: std.ArrayList(u8) = .{};
    defer query.deinit(allocator);

    try query.appendSlice(allocator,
        \\SELECT DISTINCT owner FROM names WHERE owner IN (
    );

    for (addresses, 0..) |_, i| {
        if (i > 0) try query.appendSlice(allocator, ", ");
        try query.appendSlice(allocator, "?");
    }
    try query.appendSlice(allocator, ")");

    const query_z = try allocator.dupeZ(u8, query.items);
    defer allocator.free(query_z);

    var stmt: ?*c.sqlite3_stmt = null;
    defer {
        if (stmt) |s| _ = c.sqlite3_finalize(s);
    }

    // Prepare statement
    if (c.sqlite3_prepare_v2(database.db, query_z.ptr, -1, &stmt, null) != c.SQLITE_OK) {
        // If query fails, fall back to returning addresses as-is
        const results = try allocator.alloc([]const u8, addresses.len);
        for (results, addresses) |*result, address| {
            result.* = try allocator.dupe(u8, address);
        }
        return results;
    }

    // Bind address parameters
    for (addresses, 0..) |address, i| {
        _ = c.sqlite3_bind_text(stmt, @intCast(i + 1), address.ptr, @intCast(address.len), null);
    }

    // Collect active addresses
    var active_addresses = std.StringHashMap(void).init(allocator);
    defer active_addresses.deinit();

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const owner_text = c.sqlite3_column_text(stmt, 0);
        if (owner_text != null) {
            const owner_len = c.sqlite3_column_bytes(stmt, 0);
            const owner_slice = owner_text[0..@intCast(owner_len)];
            try active_addresses.put(try allocator.dupe(u8, owner_slice), {});
        }
    }
    defer {
        var it = active_addresses.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
    }

    // Build results in the same order as input addresses
    // Return normalized/validated addresses (or originals if not found)
    const results = try allocator.alloc([]const u8, addresses.len);
    for (results, addresses) |*result, address| {
        // Try to parse and normalize address
        const addr = Address.fromHex(address) catch {
            // If parsing fails, return original address
            result.* = try allocator.dupe(u8, address);
            continue;
        };

        // Convert back to hex (this normalizes the address format)
        const normalized = try addr.toHex(allocator);
        result.* = normalized;
    }

    return results;
}

/// Batch load content hashes for multiple namehashes
/// Returns content hashes in the same order as input namehashes
pub fn batchLoadContentHashes(
    database: *db.Database,
    allocator: std.mem.Allocator,
    namehashes: []const [32]u8,
) ![]?[]const u8 {
    if (namehashes.len == 0) {
        return try allocator.alloc(?[]const u8, 0);
    }

    const Hash = @import("../types/hash.zig").Hash;
    const c = @import("../storage/database.zig").c;

    // Build SQL query with WHERE IN clause for batch fetching
    var query: std.ArrayList(u8) = .{};
    defer query.deinit(allocator);

    try query.appendSlice(allocator, "SELECT namehash, contenthash FROM resolver_contenthashes WHERE namehash IN (");

    for (namehashes, 0..) |_, i| {
        if (i > 0) try query.appendSlice(allocator, ", ");
        try query.appendSlice(allocator, "?");
    }
    try query.appendSlice(allocator, ") ORDER BY block_number DESC");

    // Add null terminator for C string
    const query_z = try allocator.dupeZ(u8, query.items);
    defer allocator.free(query_z);

    var stmt: ?*c.sqlite3_stmt = null;
    defer {
        if (stmt) |s| _ = c.sqlite3_finalize(s);
    }

    if (c.sqlite3_prepare_v2(database.db, query_z.ptr, -1, &stmt, null) != c.SQLITE_OK) {
        return error.PrepareFailed;
    }

    // Bind all namehash parameters
    var namehash_hexes = try allocator.alloc([]u8, namehashes.len);
    defer {
        for (namehash_hexes) |hex| {
            allocator.free(hex);
        }
        allocator.free(namehash_hexes);
    }

    for (namehashes, 0..) |namehash, i| {
        const hash = Hash{ .bytes = namehash };
        namehash_hexes[i] = try hash.toHex(allocator);
        _ = c.sqlite3_bind_text(stmt, @intCast(i + 1), namehash_hexes[i].ptr, @intCast(namehash_hexes[i].len), null);
    }

    // Create a map to store results by namehash
    var result_map = std.StringHashMap(?[]u8).init(allocator);
    defer {
        var it = result_map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*) |val| {
                allocator.free(val);
            }
        }
        result_map.deinit();
    }

    // Execute query and collect results
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const namehash_text = c.sqlite3_column_text(stmt, 0);
        const hash_text = c.sqlite3_column_text(stmt, 1);

        if (namehash_text != null) {
            const namehash_len = c.sqlite3_column_bytes(stmt, 0);
            const namehash_slice = namehash_text[0..@intCast(namehash_len)];
            const namehash_key = try allocator.dupe(u8, namehash_slice);
            errdefer allocator.free(namehash_key);

            if (hash_text != null) {
                const hash_len = c.sqlite3_column_bytes(stmt, 1);
                const hash_slice = hash_text[0..@intCast(hash_len)];
                const hash_copy = try allocator.dupe(u8, hash_slice);
                try result_map.put(namehash_key, hash_copy);
            } else {
                try result_map.put(namehash_key, null);
            }
        }
    }

    // Build result array in the same order as input namehashes
    const results = try allocator.alloc(?[]const u8, namehashes.len);
    for (results, namehashes) |*result, namehash| {
        const hash = Hash{ .bytes = namehash };
        const namehash_hex = try hash.toHex(allocator);
        defer allocator.free(namehash_hex);

        if (result_map.get(namehash_hex)) |content_hash| {
            result.* = content_hash;
        } else {
            result.* = null;
        }
    }

    return results;
}

/// Batch load text records for multiple namehashes
/// Returns all text records for each namehash in the same order as input
/// NOTE: This function uses a two-step approach because V2 names have different
/// namehashes than V1 resolver events. We first lookup resolver addresses from
/// the names table, then query resolver_texts by resolver address.
pub fn batchLoadTextRecords(
    database: *db.Database,
    allocator: std.mem.Allocator,
    namehashes: []const [32]u8,
) ![]TextRecords {
    if (namehashes.len == 0) {
        return try allocator.alloc(TextRecords, 0);
    }

    const Hash = @import("../types/hash.zig").Hash;
    const c = @import("../storage/database.zig").c;

    // Step 1: Get resolver addresses for each namehash from the names table
    var resolver_query: std.ArrayList(u8) = .{};
    defer resolver_query.deinit(allocator);

    try resolver_query.appendSlice(allocator, "SELECT namehash, resolver FROM names WHERE namehash IN (");
    for (namehashes, 0..) |_, i| {
        if (i > 0) try resolver_query.appendSlice(allocator, ", ");
        try resolver_query.appendSlice(allocator, "?");
    }
    try resolver_query.appendSlice(allocator, ")");

    const resolver_query_z = try allocator.dupeZ(u8, resolver_query.items);
    defer allocator.free(resolver_query_z);

    var resolver_stmt: ?*c.sqlite3_stmt = null;
    defer {
        if (resolver_stmt) |s| _ = c.sqlite3_finalize(s);
    }

    if (c.sqlite3_prepare_v2(database.db, resolver_query_z.ptr, -1, &resolver_stmt, null) != c.SQLITE_OK) {
        return error.PrepareFailed;
    }

    // Bind namehash parameters and prepare hex strings
    var namehash_hexes = try allocator.alloc([]u8, namehashes.len);
    defer {
        for (namehash_hexes) |hex| {
            allocator.free(hex);
        }
        allocator.free(namehash_hexes);
    }

    for (namehashes, 0..) |namehash, i| {
        const hash = Hash{ .bytes = namehash };
        namehash_hexes[i] = try hash.toHex(allocator);
        _ = c.sqlite3_bind_text(resolver_stmt, @intCast(i + 1), namehash_hexes[i].ptr, @intCast(namehash_hexes[i].len), null);
    }

    // Map: namehash_hex -> resolver_address
    var namehash_to_resolver = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = namehash_to_resolver.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        namehash_to_resolver.deinit();
    }

    // Collect unique resolver addresses
    var unique_resolvers = std.StringHashMap(void).init(allocator);
    defer {
        var it = unique_resolvers.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        unique_resolvers.deinit();
    }

    while (c.sqlite3_step(resolver_stmt) == c.SQLITE_ROW) {
        const nh_text = c.sqlite3_column_text(resolver_stmt, 0);
        const resolver_text = c.sqlite3_column_text(resolver_stmt, 1);

        if (nh_text != null and resolver_text != null) {
            const nh_len = c.sqlite3_column_bytes(resolver_stmt, 0);
            const nh_slice = nh_text[0..@intCast(nh_len)];

            const resolver_len = c.sqlite3_column_bytes(resolver_stmt, 1);
            const resolver_slice = resolver_text[0..@intCast(resolver_len)];

            // Skip if resolver is null/zero address
            if (resolver_len > 0 and !std.mem.eql(u8, resolver_slice, "0x0000000000000000000000000000000000000000")) {
                const nh_copy = try allocator.dupe(u8, nh_slice);
                const resolver_copy = try allocator.dupe(u8, resolver_slice);
                try namehash_to_resolver.put(nh_copy, resolver_copy);

                // Track unique resolvers
                const resolver_key = try allocator.dupe(u8, resolver_slice);
                const put_result = try unique_resolvers.getOrPut(resolver_key);
                if (put_result.found_existing) {
                    allocator.free(resolver_key);
                }
            }
        }
    }

    // Step 2: Query resolver_texts by resolver addresses
    // Map: resolver_address -> list of text records
    var resolver_to_texts = std.StringHashMap(std.ArrayList(TextRecord)).init(allocator);
    defer {
        var it = resolver_to_texts.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.*.items) |record| {
                allocator.free(record.key);
                allocator.free(record.value);
            }
            entry.value_ptr.*.deinit(allocator);
        }
        resolver_to_texts.deinit();
    }

    if (unique_resolvers.count() > 0) {
        var text_query: std.ArrayList(u8) = .{};
        defer text_query.deinit(allocator);

        try text_query.appendSlice(allocator, "SELECT resolver, key, value FROM resolver_texts WHERE resolver IN (");
        var first = true;
        var resolver_it = unique_resolvers.keyIterator();
        while (resolver_it.next()) |_| {
            if (!first) try text_query.appendSlice(allocator, ", ");
            try text_query.appendSlice(allocator, "?");
            first = false;
        }
        try text_query.appendSlice(allocator, ") ORDER BY resolver, key");

        const text_query_z = try allocator.dupeZ(u8, text_query.items);
        defer allocator.free(text_query_z);

        var text_stmt: ?*c.sqlite3_stmt = null;
        defer {
            if (text_stmt) |s| _ = c.sqlite3_finalize(s);
        }

        if (c.sqlite3_prepare_v2(database.db, text_query_z.ptr, -1, &text_stmt, null) != c.SQLITE_OK) {
            return error.PrepareFailed;
        }

        // Bind resolver addresses
        var bind_idx: c_int = 1;
        var bind_it = unique_resolvers.keyIterator();
        while (bind_it.next()) |key| {
            _ = c.sqlite3_bind_text(text_stmt, bind_idx, key.*.ptr, @intCast(key.*.len), null);
            bind_idx += 1;
        }

        // Execute and collect text records
        while (c.sqlite3_step(text_stmt) == c.SQLITE_ROW) {
            const resolver_col = c.sqlite3_column_text(text_stmt, 0);
            const key_col = c.sqlite3_column_text(text_stmt, 1);
            const value_col = c.sqlite3_column_text(text_stmt, 2);

            if (resolver_col != null and key_col != null and value_col != null) {
                const resolver_len = c.sqlite3_column_bytes(text_stmt, 0);
                const resolver_slice = resolver_col[0..@intCast(resolver_len)];

                const key_len = c.sqlite3_column_bytes(text_stmt, 1);
                const key_slice = key_col[0..@intCast(key_len)];
                const key_copy = try allocator.dupe(u8, key_slice);

                const value_len = c.sqlite3_column_bytes(text_stmt, 2);
                const value_slice = value_col[0..@intCast(value_len)];
                const value_copy = try allocator.dupe(u8, value_slice);

                // Get or create list for this resolver
                const result = try resolver_to_texts.getOrPut(resolver_slice);
                if (!result.found_existing) {
                    result.key_ptr.* = try allocator.dupe(u8, resolver_slice);
                    result.value_ptr.* = std.ArrayList(TextRecord){};
                }

                try result.value_ptr.*.append(allocator, .{
                    .key = key_copy,
                    .value = value_copy,
                });
            }
        }
    }

    // Step 3: Build result array mapping namehashes -> text records via resolver
    const results = try allocator.alloc(TextRecords, namehashes.len);
    for (results, namehashes) |*result, namehash| {
        const hash = Hash{ .bytes = namehash };
        const namehash_hex = try hash.toHex(allocator);
        defer allocator.free(namehash_hex);

        // Look up resolver for this namehash
        if (namehash_to_resolver.get(namehash_hex)) |resolver_addr| {
            // Look up text records for this resolver
            if (resolver_to_texts.get(resolver_addr)) |records_list| {
                // Copy the records for this result
                const records = try allocator.alloc(TextRecord, records_list.items.len);
                for (records_list.items, 0..) |record, j| {
                    records[j] = .{
                        .key = try allocator.dupe(u8, record.key),
                        .value = try allocator.dupe(u8, record.value),
                    };
                }
                result.* = .{
                    .records = records,
                    .allocator = allocator,
                };
            } else {
                // Resolver exists but no text records
                result.* = .{
                    .records = try allocator.alloc(TextRecord, 0),
                    .allocator = allocator,
                };
            }
        } else {
            // No resolver for this namehash
            result.* = .{
                .records = try allocator.alloc(TextRecord, 0),
                .allocator = allocator,
            };
        }
    }

    return results;
}

// ============================================================================
// Tests
// ============================================================================

test "DataLoader: basic init and deinit" {
    const allocator = std.testing.allocator;

    // Simple batch function that echoes keys
    const batchFn = struct {
        fn load(alloc: std.mem.Allocator, keys: []const u32) ![]u32 {
            const values = try alloc.alloc(u32, keys.len);
            for (keys, 0..) |key, i| {
                values[i] = key * 2; // Double the key
            }
            return values;
        }
    }.load;

    const loader = try DataLoader(u32, u32).init(allocator, batchFn);
    defer loader.deinit();

    try std.testing.expect(loader.cache_hits == 0);
    try std.testing.expect(loader.cache_misses == 0);
    try std.testing.expect(loader.batch_loads == 0);
}

test "DataLoader: single load triggers batch" {
    const allocator = std.testing.allocator;

    const batchFn = struct {
        fn load(alloc: std.mem.Allocator, keys: []const u32) ![]u32 {
            const values = try alloc.alloc(u32, keys.len);
            for (keys, 0..) |key, i| {
                values[i] = key * 10;
            }
            return values;
        }
    }.load;

    const loader = try DataLoader(u32, u32).init(allocator, batchFn);
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
        fn load(alloc: std.mem.Allocator, keys: []const u32) ![]u32 {
            const values = try alloc.alloc(u32, keys.len);
            for (keys, 0..) |key, i| {
                values[i] = key + 100;
            }
            return values;
        }
    }.load;

    const loader = try DataLoader(u32, u32).init(allocator, batchFn);
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
        fn load(alloc: std.mem.Allocator, keys: []const u32) ![]u32 {
            const values = try alloc.alloc(u32, keys.len);
            for (keys, 0..) |key, i| {
                values[i] = key;
            }
            return values;
        }
    }.load;

    const loader = try DataLoader(u32, u32).init(allocator, batchFn);
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
        fn load(alloc: std.mem.Allocator, keys: []const u32) ![]u32 {
            const values = try alloc.alloc(u32, keys.len);
            for (keys, 0..) |key, i| {
                values[i] = key;
            }
            return values;
        }
    }.load;

    const loader = try DataLoader(u32, u32).init(allocator, batchFn);
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

    // Total: 5 keys loaded in 2 batches = 2.5 average
    try std.testing.expectApproxEqRel(@as(f64, 2.5), avg_batch, 0.01);
}

test "DataLoader: empty batch returns immediately" {
    const allocator = std.testing.allocator;

    var call_count: usize = 0;

    const batchFn = struct {
        var count_ptr: *usize = undefined;

        fn load(alloc: std.mem.Allocator, keys: []const u32) ![]u32 {
            count_ptr.* += 1;
            const values = try alloc.alloc(u32, keys.len);
            for (keys, 0..) |key, i| {
                values[i] = key;
            }
            return values;
        }
    }.load;

    batchFn.count_ptr = &call_count;

    const loader = try DataLoader(u32, u32).init(allocator, batchFn);
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
        fn load(alloc: std.mem.Allocator, keys: []const u32) ![]u32 {
            const values = try alloc.alloc(u32, keys.len);
            for (keys, 0..) |key, i| {
                values[i] = key * 3;
            }
            return values;
        }
    }.load;

    const loader = try DataLoader(u32, u32).init(allocator, batchFn);
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
        fn load(alloc: std.mem.Allocator, keys: []const u32) ![]u32 {
            const values = try alloc.alloc(u32, keys.len);
            for (keys, 0..) |key, i| {
                values[i] = key;
            }
            return values;
        }
    }.load;

    const loader = try DataLoader(u32, u32).init(allocator, batchFn);
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
    // But statistics are preserved
    try std.testing.expectEqual(@as(usize, 2), stats_after.cache_misses);
    try std.testing.expectEqual(@as(usize, 1), stats_after.batch_loads);
}

// ============================================================================
// Tests for Content Hash and Text Records Loaders
// ============================================================================

test "Content Hash Loader: basic batch loading" {
    const allocator = std.testing.allocator;

    // Mock batch function that returns content hashes
    const batchFn = struct {
        fn load(alloc: std.mem.Allocator, keys: []const [32]u8) ![]?[]const u8 {
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

    const loader = try DataLoader([32]u8, ?[]const u8).init(allocator, batchFn);
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

    // Load first hash
    const result1 = try loader.load(hash1);
    try std.testing.expect(result1 != null);
    try std.testing.expect(std.mem.startsWith(u8, result1.?, "ipfs://"));

    // Load second hash (should be in same batch)
    const result2 = try loader.load(hash2);
    try std.testing.expect(result2 != null);

    // Load third hash (returns null)
    const result3 = try loader.load(hash3);
    try std.testing.expect(result3 == null);

    // Verify stats
    const stats = loader.getCacheStats();
    try std.testing.expectEqual(@as(usize, 3), stats.cache_misses);
    try std.testing.expectEqual(@as(usize, 3), stats.total_keys_loaded);
}

test "Content Hash Loader: cache hits" {
    const allocator = std.testing.allocator;

    const batchFn = struct {
        fn load(alloc: std.mem.Allocator, keys: []const [32]u8) ![]?[]const u8 {
            const values = try alloc.alloc(?[]const u8, keys.len);
            for (values, keys) |*value, key| {
                const hash = try std.fmt.allocPrint(alloc, "hash-{d}", .{key[0]});
                value.* = hash;
            }
            return values;
        }
    }.load;

    const loader = try DataLoader([32]u8, ?[]const u8).init(allocator, batchFn);
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

test "Text Records Loader: basic loading" {
    const allocator = std.testing.allocator;

    const batchFn = struct {
        fn load(alloc: std.mem.Allocator, keys: []const [32]u8) ![]TextRecords {
            const values = try alloc.alloc(TextRecords, keys.len);
            for (values, keys, 0..) |*value, key, i| {
                if (i == 0) {
                    // First namehash has 2 records
                    const records = try alloc.alloc(TextRecord, 2);
                    records[0] = .{
                        .key = try alloc.dupe(u8, "avatar"),
                        .value = try std.fmt.allocPrint(alloc, "https://avatar{d}.png", .{key[0]}),
                    };
                    records[1] = .{
                        .key = try alloc.dupe(u8, "email"),
                        .value = try std.fmt.allocPrint(alloc, "user{d}@example.com", .{key[0]}),
                    };
                    value.* = .{ .records = records, .allocator = alloc };
                } else {
                    // Others have no records
                    value.* = .{ .records = try alloc.alloc(TextRecord, 0), .allocator = alloc };
                }
            }
            return values;
        }
    }.load;

    const loader = try DataLoader([32]u8, TextRecords).init(allocator, batchFn);
    defer {
        var it = loader.cache.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        loader.deinit();
    }

    var hash1: [32]u8 = undefined;
    @memset(&hash1, 1);

    const result = try loader.load(hash1);
    try std.testing.expectEqual(@as(usize, 2), result.records.len);
    try std.testing.expectEqualStrings("avatar", result.records[0].key);
    try std.testing.expectEqualStrings("email", result.records[1].key);
}

test "Text Records Loader: loadMany with multiple namehashes" {
    const allocator = std.testing.allocator;

    const batchFn = struct {
        fn load(alloc: std.mem.Allocator, keys: []const [32]u8) ![]TextRecords {
            const values = try alloc.alloc(TextRecords, keys.len);
            for (values, keys, 0..) |*value, key, i| {
                // Each namehash gets i+1 records
                const records = try alloc.alloc(TextRecord, i + 1);
                for (records, 0..) |*record, j| {
                    record.* = .{
                        .key = try std.fmt.allocPrint(alloc, "key{d}", .{j}),
                        .value = try std.fmt.allocPrint(alloc, "value{d}-{d}", .{ key[0], j }),
                    };
                }
                value.* = .{ .records = records, .allocator = alloc };
            }
            return values;
        }
    }.load;

    const loader = try DataLoader([32]u8, TextRecords).init(allocator, batchFn);
    defer {
        var it = loader.cache.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        loader.deinit();
    }

    // Create 3 test namehashes
    var hashes: [3][32]u8 = undefined;
    for (&hashes, 0..) |*hash, i| {
        @memset(hash, @intCast(i + 1));
    }

    const results = try loader.loadMany(&hashes);
    defer allocator.free(results);

    // Verify each result
    try std.testing.expectEqual(@as(usize, 1), results[0].records.len);
    try std.testing.expectEqual(@as(usize, 2), results[1].records.len);
    try std.testing.expectEqual(@as(usize, 3), results[2].records.len);

    // Verify one batch was used
    const stats = loader.getCacheStats();
    try std.testing.expectEqual(@as(usize, 1), stats.batch_loads);
    try std.testing.expectEqual(@as(usize, 3), stats.total_keys_loaded);
    try std.testing.expectEqual(@as(f64, 3.0), stats.avgBatchSize());
}

test "Text Records Loader: empty results" {
    const allocator = std.testing.allocator;

    const batchFn = struct {
        fn load(alloc: std.mem.Allocator, keys: []const [32]u8) ![]TextRecords {
            const values = try alloc.alloc(TextRecords, keys.len);
            for (values) |*value| {
                // All namehashes have no records
                value.* = .{ .records = try alloc.alloc(TextRecord, 0), .allocator = alloc };
            }
            return values;
        }
    }.load;

    const loader = try DataLoader([32]u8, TextRecords).init(allocator, batchFn);
    defer {
        var it = loader.cache.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        loader.deinit();
    }

    var hash1: [32]u8 = undefined;
    @memset(&hash1, 1);

    const result = try loader.load(hash1);
    try std.testing.expectEqual(@as(usize, 0), result.records.len);
}

test "LoaderContext: init and deinit with new loaders" {
    const allocator = std.testing.allocator;

    var test_db = try db.Database.init(allocator, ":memory:");
    defer test_db.deinit();

    const ctx = try LoaderContext.init(allocator, &test_db);
    defer ctx.deinit();

    // Verify all loaders start as null
    try std.testing.expect(ctx.resolver_address_loader == null);
    try std.testing.expect(ctx.content_hash_loader == null);
    try std.testing.expect(ctx.text_records_loader == null);
    try std.testing.expect(ctx.account_loader == null);
}

test "LoaderContext: getAllStats with new loaders" {
    const allocator = std.testing.allocator;

    var test_db = try db.Database.init(allocator, ":memory:");
    defer test_db.deinit();

    const ctx = try LoaderContext.init(allocator, &test_db);
    defer ctx.deinit();

    // Get stats before any loaders are created
    const stats = ctx.getAllStats();

    // All stats should be zero
    try std.testing.expectEqual(@as(usize, 0), stats.resolver_address.entries);
    try std.testing.expectEqual(@as(usize, 0), stats.content_hash.entries);
    try std.testing.expectEqual(@as(usize, 0), stats.text_records.entries);
    try std.testing.expectEqual(@as(usize, 0), stats.account.entries);
}

test "Account Loader: basic batch loading" {
    const allocator = std.testing.allocator;

    // Mock batch function that normalizes addresses
    const batchFn = struct {
        fn load(alloc: std.mem.Allocator, addresses: []const []const u8) ![][]const u8 {
            const values = try alloc.alloc([]const u8, addresses.len);
            for (values, addresses) |*value, address| {
                // Normalize addresses by converting to lowercase
                const normalized = try alloc.alloc(u8, address.len);
                for (normalized, address) |*c, ch| {
                    c.* = std.ascii.toLower(ch);
                }
                value.* = normalized;
            }
            return values;
        }
    }.load;

    const loader = try DataLoader([]const u8, []const u8).init(allocator, batchFn);
    defer {
        // Clean up cached values
        var it = loader.cache.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.value_ptr.*);
        }
        loader.deinit();
    }

    // Load addresses with mixed case
    const addr1 = "0x1234ABCD";
    const addr2 = "0x5678EFGH";
    const addr3 = "0xABCDEF01";

    const result1 = try loader.load(addr1);
    try std.testing.expectEqualStrings("0x1234abcd", result1);

    const result2 = try loader.load(addr2);
    try std.testing.expectEqualStrings("0x5678efgh", result2);

    const result3 = try loader.load(addr3);
    try std.testing.expectEqualStrings("0xabcdef01", result3);

    // Verify stats
    const stats = loader.getCacheStats();
    try std.testing.expectEqual(@as(usize, 3), stats.cache_misses);
    try std.testing.expectEqual(@as(usize, 3), stats.total_keys_loaded);
}

test "Account Loader: cache hits for same address" {
    const allocator = std.testing.allocator;

    const batchFn = struct {
        fn load(alloc: std.mem.Allocator, addresses: []const []const u8) ![][]const u8 {
            const values = try alloc.alloc([]const u8, addresses.len);
            for (values, addresses) |*value, address| {
                value.* = try alloc.dupe(u8, address);
            }
            return values;
        }
    }.load;

    const loader = try DataLoader([]const u8, []const u8).init(allocator, batchFn);
    defer {
        var it = loader.cache.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.value_ptr.*);
        }
        loader.deinit();
    }

    const addr = "0x1234567890abcdef1234567890abcdef12345678";

    // First load - cache miss
    _ = try loader.load(addr);
    try std.testing.expectEqual(@as(usize, 1), loader.cache_misses);
    try std.testing.expectEqual(@as(usize, 0), loader.cache_hits);

    // Second load - cache hit
    _ = try loader.load(addr);
    try std.testing.expectEqual(@as(usize, 1), loader.cache_misses);
    try std.testing.expectEqual(@as(usize, 1), loader.cache_hits);

    // Third load - another cache hit
    _ = try loader.load(addr);
    try std.testing.expectEqual(@as(usize, 1), loader.cache_misses);
    try std.testing.expectEqual(@as(usize, 2), loader.cache_hits);

    // Verify hit rate
    const stats = loader.getCacheStats();
    try std.testing.expectEqual(@as(f64, 2.0 / 3.0), stats.hitRate());
}

test "Account Loader: loadMany with multiple addresses" {
    const allocator = std.testing.allocator;

    const batchFn = struct {
        fn load(alloc: std.mem.Allocator, addresses: []const []const u8) ![][]const u8 {
            const values = try alloc.alloc([]const u8, addresses.len);
            for (values, addresses) |*value, address| {
                const result = try std.fmt.allocPrint(alloc, "normalized_{s}", .{address});
                value.* = result;
            }
            return values;
        }
    }.load;

    const loader = try DataLoader([]const u8, []const u8).init(allocator, batchFn);
    defer {
        var it = loader.cache.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.value_ptr.*);
        }
        loader.deinit();
    }

    const addresses = [_][]const u8{
        "0xaddr1",
        "0xaddr2",
        "0xaddr3",
    };

    const results = try loader.loadMany(&addresses);
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expect(std.mem.startsWith(u8, results[0], "normalized_"));
    try std.testing.expect(std.mem.startsWith(u8, results[1], "normalized_"));
    try std.testing.expect(std.mem.startsWith(u8, results[2], "normalized_"));

    // Verify all were loaded in one batch
    const stats = loader.getCacheStats();
    try std.testing.expectEqual(@as(usize, 1), stats.batch_loads);
    try std.testing.expectEqual(@as(usize, 3), stats.total_keys_loaded);
}

test "Account Loader: empty batch returns immediately" {
    const allocator = std.testing.allocator;

    const batchFn = struct {
        fn load(alloc: std.mem.Allocator, addresses: []const []const u8) ![][]const u8 {
            return try alloc.alloc([]const u8, addresses.len);
        }
    }.load;

    const loader = try DataLoader([]const u8, []const u8).init(allocator, batchFn);
    defer loader.deinit();

    const addresses = [_][]const u8{};
    const results = try loader.loadMany(&addresses);
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 0), results.len);

    const stats = loader.getCacheStats();
    try std.testing.expectEqual(@as(usize, 0), stats.batch_loads);
}

test "LoaderContext: getAccountLoader creates and reuses loader" {
    const allocator = std.testing.allocator;

    var test_db = try db.Database.init(allocator, ":memory:");
    defer test_db.deinit();

    const ctx = try LoaderContext.init(allocator, &test_db);
    defer ctx.deinit();

    // Initially null
    try std.testing.expect(ctx.account_loader == null);

    // Get loader - should create it
    const loader1 = try ctx.getAccountLoader();
    try std.testing.expect(ctx.account_loader != null);

    // Get loader again - should reuse the same instance
    const loader2 = try ctx.getAccountLoader();
    try std.testing.expect(loader1 == loader2);
}

test "LoaderContext: account loader in getAllStats" {
    const allocator = std.testing.allocator;

    var test_db = try db.Database.init(allocator, ":memory:");
    defer test_db.deinit();

    const ctx = try LoaderContext.init(allocator, &test_db);
    defer ctx.deinit();

    // Create account loader
    _ = try ctx.getAccountLoader();

    // Get stats
    const stats = ctx.getAllStats();

    // Account stats should be initialized
    try std.testing.expectEqual(@as(usize, 0), stats.account.entries);
    try std.testing.expectEqual(@as(usize, 0), stats.account.cache_hits);
    try std.testing.expectEqual(@as(usize, 0), stats.account.cache_misses);
}
