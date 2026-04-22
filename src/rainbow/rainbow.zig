/// ENS Rainbow Table - Standalone labelhash to label reverse lookup
///
/// This module provides a high-performance, space-efficient rainbow table
/// for resolving ENS labelhashes (keccak256) to their original label text.
///
/// Data source: The Graph Protocol's ENS rainbow dataset (MIT licensed)
/// Storage: Optimized SQLite with binary labelhashes
/// Coverage: 133M+ labels (90%+ of all ENS names)
///
/// Usage:
///   var rainbow = try Rainbow.init(allocator, "./data/ens_rainbow.db");
///   defer rainbow.deinit();
///
///   const label = try rainbow.lookup(labelhash);
///   if (label) |text| {
///       defer allocator.free(text);
///       // Use label text
///   }
const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

/// Rainbow table instance
pub const Rainbow = struct {
    db: *c.sqlite3,
    lookup_stmt: ?*c.sqlite3_stmt,
    allocator: std.mem.Allocator,
    stats: Stats,

    pub const Stats = struct {
        lookups: u64 = 0,
        hits: u64 = 0,
        misses: u64 = 0,
    };

    /// Initialize rainbow table from database file
    /// Database must already exist and contain rainbow_labels table
    pub fn init(allocator: std.mem.Allocator, db_path: []const u8) !Rainbow {
        var db: ?*c.sqlite3 = null;

        const path_z = try allocator.dupeZ(u8, db_path);
        defer allocator.free(path_z);

        // Open read-only for thread safety and performance
        const rc = c.sqlite3_open_v2(
            path_z.ptr,
            &db,
            c.SQLITE_OPEN_READONLY,
            null,
        );

        if (rc != c.SQLITE_OK) {
            std.log.warn("Rainbow table not available at {s}", .{db_path});
            return error.RainbowNotAvailable;
        }

        // Optimize for read performance
        _ = c.sqlite3_exec(db.?, "PRAGMA cache_size = 100000", null, null, null); // 400MB cache
        _ = c.sqlite3_exec(db.?, "PRAGMA mmap_size = 1073741824", null, null, null); // 1GB mmap
        _ = c.sqlite3_exec(db.?, "PRAGMA temp_store = memory", null, null, null);

        // Prepare lookup statement (reused for all queries)
        const query = "SELECT label FROM rainbow_labels WHERE labelhash = ?";
        var stmt: ?*c.sqlite3_stmt = null;

        const prep_rc = c.sqlite3_prepare_v2(
            db.?,
            query.ptr,
            @intCast(query.len),
            &stmt,
            null,
        );

        if (prep_rc != c.SQLITE_OK) {
            _ = c.sqlite3_close(db.?);
            return error.StatementPrepareFailed;
        }

        std.log.info("Rainbow table loaded from {s}", .{db_path});

        return Rainbow{
            .db = db.?,
            .lookup_stmt = stmt,
            .allocator = allocator,
            .stats = Stats{},
        };
    }

    /// Clean up resources
    pub fn deinit(self: *Rainbow) void {
        if (self.lookup_stmt) |stmt| {
            _ = c.sqlite3_finalize(stmt);
        }
        _ = c.sqlite3_close(self.db);

        // Log final stats
        if (self.stats.lookups > 0) {
            const hit_rate = @as(f64, @floatFromInt(self.stats.hits)) / @as(f64, @floatFromInt(self.stats.lookups)) * 100.0;
            std.log.info("Rainbow stats: {} lookups, {} hits ({d:.1}% hit rate)", .{
                self.stats.lookups,
                self.stats.hits,
                hit_rate,
            });
        }
    }

    /// Lookup label by labelhash (32-byte binary)
    /// Returns owned string (caller must free) or null if not found
    pub fn lookup(self: *Rainbow, labelhash: [32]u8) !?[]u8 {
        self.stats.lookups += 1;

        const stmt = self.lookup_stmt orelse return error.StatementNotPrepared;

        // Reset statement for reuse
        _ = c.sqlite3_reset(stmt);
        _ = c.sqlite3_clear_bindings(stmt);

        // Bind labelhash as BLOB (32 bytes)
        const bind_rc = c.sqlite3_bind_blob(
            stmt,
            1,
            &labelhash,
            32,
            null, // SQLITE_TRANSIENT equivalent
        );

        if (bind_rc != c.SQLITE_OK) {
            std.log.err("Rainbow bind failed: {s}", .{c.sqlite3_errmsg(self.db)});
            return error.BindFailed;
        }

        // Execute query
        const step_rc = c.sqlite3_step(stmt);

        if (step_rc == c.SQLITE_ROW) {
            // Label found
            self.stats.hits += 1;

            const label_ptr = c.sqlite3_column_text(stmt, 0);
            const label_len = c.sqlite3_column_bytes(stmt, 0);
            const label = label_ptr[0..@intCast(label_len)];

            std.log.debug("Rainbow HIT: {s}", .{label});
            return try self.allocator.dupe(u8, label);
        } else if (step_rc == c.SQLITE_DONE) {
            // Not found
            self.stats.misses += 1;
            std.log.debug("Rainbow MISS", .{});
            return null;
        } else {
            std.log.err("Rainbow query failed: {s}", .{c.sqlite3_errmsg(self.db)});
            return error.QueryFailed;
        }
    }

    /// Get database statistics
    pub fn getDbStats(self: *const Rainbow) !DbStats {
        const query = "SELECT COUNT(*) FROM rainbow_labels";
        var stmt: ?*c.sqlite3_stmt = null;

        const prep_rc = c.sqlite3_prepare_v2(
            self.db,
            query.ptr,
            @intCast(query.len),
            &stmt,
            null,
        );

        if (prep_rc != c.SQLITE_OK) {
            return error.StatementPrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt.?);

        const step_rc = c.sqlite3_step(stmt.?);

        if (step_rc == c.SQLITE_ROW) {
            const count = c.sqlite3_column_int64(stmt.?, 0);
            return DbStats{
                .total_labels = @intCast(count),
                .lookups = self.stats.lookups,
                .hits = self.stats.hits,
                .misses = self.stats.misses,
            };
        }

        return error.QueryFailed;
    }

    pub const DbStats = struct {
        total_labels: u64,
        lookups: u64,
        hits: u64,
        misses: u64,
    };
};

/// Convert hex string to 32-byte array
fn hexToBytes(hex: []const u8) ![32]u8 {
    var result: [32]u8 = undefined;

    // Remove 0x prefix if present
    const hex_data = if (std.mem.startsWith(u8, hex, "0x")) hex[2..] else hex;

    if (hex_data.len != 64) {
        return error.InvalidHexLength;
    }

    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const byte_hex = hex_data[i * 2 .. i * 2 + 2];
        result[i] = try std.fmt.parseInt(u8, byte_hex, 16);
    }

    return result;
}

/// Compute labelhash from label text (keccak256)
pub fn computeLabelhash(label: []const u8) [32]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(label, &hash, .{});
    return hash;
}

// Tests
test "hex to bytes conversion" {
    const hex = "0x0000000000000000000000000000000000000000000000000000000000000001";
    const bytes = try hexToBytes(hex);

    try std.testing.expectEqual(@as(u8, 0), bytes[0]);
    try std.testing.expectEqual(@as(u8, 1), bytes[31]);
}

test "compute labelhash" {
    const label = "test";
    const hash = computeLabelhash(label);

    // Verify it's not all zeros
    var is_zero = true;
    for (hash) |byte| {
        if (byte != 0) {
            is_zero = false;
            break;
        }
    }

    try std.testing.expect(!is_zero);
}

test "rainbow table operations" {
    _ = std.testing.allocator;

    // Create in-memory database for testing
    var db: ?*c.sqlite3 = null;
    var rc = c.sqlite3_open(":memory:", &db);
    try std.testing.expectEqual(c.SQLITE_OK, rc);
    defer _ = c.sqlite3_close(db.?);

    // Create schema
    const schema =
        \\CREATE TABLE rainbow_labels (
        \\    labelhash BLOB PRIMARY KEY,
        \\    label TEXT NOT NULL
        \\) WITHOUT ROWID
    ;

    rc = c.sqlite3_exec(db.?, schema.ptr, null, null, null);
    try std.testing.expectEqual(c.SQLITE_OK, rc);

    // Insert test data
    const test_label = "vitalik";
    const test_hash = computeLabelhash(test_label);

    const insert = "INSERT INTO rainbow_labels (labelhash, label) VALUES (?, ?)";
    var stmt: ?*c.sqlite3_stmt = null;

    rc = c.sqlite3_prepare_v2(db.?, insert.ptr, @intCast(insert.len), &stmt, null);
    try std.testing.expectEqual(c.SQLITE_OK, rc);

    _ = c.sqlite3_bind_blob(stmt.?, 1, &test_hash, 32, null);
    _ = c.sqlite3_bind_text(stmt.?, 2, test_label.ptr, @intCast(test_label.len), null);

    rc = c.sqlite3_step(stmt.?);
    try std.testing.expectEqual(c.SQLITE_DONE, rc);
    _ = c.sqlite3_finalize(stmt.?);

    // Note: Can't easily test Rainbow.init() with in-memory DB
    // since it requires a file path. Would need integration test.
}
