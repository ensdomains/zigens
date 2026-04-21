const std = @import("std");
const c = @cimport({
    @cInclude("sqlite3.h");
});
const types = @import("../types.zig");
const Hash = types.Hash;

pub const LabelSource = enum {
    controller,
    calldata,
    wrapper,
    manual,

    pub fn toString(self: LabelSource) []const u8 {
        return switch (self) {
            .controller => "controller",
            .calldata => "calldata",
            .wrapper => "wrapper",
            .manual => "manual",
        };
    }
};

/// Store a label in the rainbow table
/// Silently ignores duplicates (INSERT OR IGNORE)
pub fn storeLabel(
    db: *c.sqlite3,
    labelhash: Hash,
    label: []const u8,
    source: LabelSource,
    block_number: u64,
    tx_hash: Hash,
) !void {
    const labelhash_hex = try labelhash.toHex(std.heap.c_allocator);
    defer std.heap.c_allocator.free(labelhash_hex);

    const tx_hash_hex = try tx_hash.toHex(std.heap.c_allocator);
    defer std.heap.c_allocator.free(tx_hash_hex);

    const query =
        \\INSERT OR IGNORE INTO rainbow_labels
        \\  (labelhash, label, source, first_seen_block, first_seen_tx)
        \\VALUES (?, ?, ?, ?, ?)
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    var rc = c.sqlite3_prepare_v2(db, query.ptr, @intCast(query.len), &stmt, null);

    if (rc != c.SQLITE_OK) {
        std.log.err("Failed to prepare rainbow insert statement: {d}", .{rc});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt.?);

    // Bind parameters
    _ = c.sqlite3_bind_text(stmt.?, 1, labelhash_hex.ptr, @intCast(labelhash_hex.len), c.SQLITE_TRANSIENT);
    _ = c.sqlite3_bind_text(stmt.?, 2, label.ptr, @intCast(label.len), c.SQLITE_TRANSIENT);
    _ = c.sqlite3_bind_text(stmt.?, 3, source.toString().ptr, @intCast(source.toString().len), c.SQLITE_TRANSIENT);
    _ = c.sqlite3_bind_int64(stmt.?, 4, @intCast(block_number));
    _ = c.sqlite3_bind_text(stmt.?, 5, tx_hash_hex.ptr, @intCast(tx_hash_hex.len), c.SQLITE_TRANSIENT);

    rc = c.sqlite3_step(stmt.?);

    if (rc != c.SQLITE_DONE) {
        std.log.err("Failed to insert rainbow label: {d}", .{rc});
        return error.InsertFailed;
    }
}

/// Lookup a label by labelhash
/// Returns owned slice (caller must free) or null if not found
pub fn lookupLabel(
    allocator: std.mem.Allocator,
    db: *c.sqlite3,
    labelhash: Hash,
) !?[]u8 {
    const labelhash_hex = try labelhash.toHex(allocator);
    defer allocator.free(labelhash_hex);

    const query = "SELECT label FROM rainbow_labels WHERE labelhash = ?";

    var stmt: ?*c.sqlite3_stmt = null;
    var rc = c.sqlite3_prepare_v2(db, query.ptr, @intCast(query.len), &stmt, null);

    if (rc != c.SQLITE_OK) {
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt.?);

    _ = c.sqlite3_bind_text(stmt.?, 1, labelhash_hex.ptr, @intCast(labelhash_hex.len), c.SQLITE_TRANSIENT);

    rc = c.sqlite3_step(stmt.?);

    if (rc == c.SQLITE_ROW) {
        const label_ptr = c.sqlite3_column_text(stmt.?, 0);
        const label_len = c.sqlite3_column_bytes(stmt.?, 0);
        const label = label_ptr[0..@intCast(label_len)];
        return try allocator.dupe(u8, label);
    } else if (rc == c.SQLITE_DONE) {
        return null;
    } else {
        return error.QueryFailed;
    }
}

/// Compute labelhash from label (keccak256)
pub fn computeLabelhash(label: []const u8) Hash {
    const std_crypto = std.crypto;
    var hash_bytes: [32]u8 = undefined;
    std_crypto.hash.sha3.Keccak256.hash(label, &hash_bytes, .{});

    var hash: Hash = undefined;
    @memcpy(&hash.bytes, &hash_bytes);
    return hash;
}

/// Get statistics about the rainbow table
pub fn getStats(db: *c.sqlite3) !RainbowStats {
    const query =
        \\SELECT
        \\  COUNT(*) as total,
        \\  SUM(CASE WHEN source = 'controller' THEN 1 ELSE 0 END) as controller,
        \\  SUM(CASE WHEN source = 'calldata' THEN 1 ELSE 0 END) as calldata,
        \\  SUM(CASE WHEN source = 'wrapper' THEN 1 ELSE 0 END) as wrapper,
        \\  SUM(CASE WHEN source = 'manual' THEN 1 ELSE 0 END) as manual
        \\FROM rainbow_labels
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    var rc = c.sqlite3_prepare_v2(db, query.ptr, @intCast(query.len), &stmt, null);

    if (rc != c.SQLITE_OK) {
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt.?);

    rc = c.sqlite3_step(stmt.?);

    if (rc == c.SQLITE_ROW) {
        return RainbowStats{
            .total = @intCast(c.sqlite3_column_int64(stmt.?, 0)),
            .controller = @intCast(c.sqlite3_column_int64(stmt.?, 1)),
            .calldata = @intCast(c.sqlite3_column_int64(stmt.?, 2)),
            .wrapper = @intCast(c.sqlite3_column_int64(stmt.?, 3)),
            .manual = @intCast(c.sqlite3_column_int64(stmt.?, 4)),
        };
    }

    return error.QueryFailed;
}

pub const RainbowStats = struct {
    total: u64,
    controller: u64,
    calldata: u64,
    wrapper: u64,
    manual: u64,
};

// Tests
test "compute labelhash" {
    const label = "app";
    const hash = computeLabelhash(label);

    // Verify it's not all zeros
    var is_zero = true;
    for (hash.bytes) |byte| {
        if (byte != 0) {
            is_zero = false;
            break;
        }
    }

    try std.testing.expect(!is_zero);
}

test "rainbow table store and lookup" {
    const allocator = std.testing.allocator;

    // Create in-memory database for testing
    var db: ?*c.sqlite3 = null;
    var rc = c.sqlite3_open(":memory:", &db);
    try std.testing.expectEqual(c.SQLITE_OK, rc);
    defer _ = c.sqlite3_close(db.?);

    // Create schema
    const schema =
        \\CREATE TABLE rainbow_labels (
        \\    labelhash TEXT PRIMARY KEY,
        \\    label TEXT NOT NULL,
        \\    source TEXT NOT NULL,
        \\    first_seen_block INTEGER NOT NULL,
        \\    first_seen_tx TEXT NOT NULL
        \\)
    ;

    rc = c.sqlite3_exec(db.?, schema.ptr, null, null, null);
    try std.testing.expectEqual(c.SQLITE_OK, rc);

    // Create test data
    const label = "test";
    const labelhash = computeLabelhash(label);
    const tx_hash = Hash{ .bytes = [_]u8{1} ** 32 };

    // Store label
    try storeLabel(db.?, labelhash, label, .calldata, 12345, tx_hash);

    // Lookup label
    const result = try lookupLabel(allocator, db.?, labelhash);
    try std.testing.expect(result != null);

    if (result) |found_label| {
        defer allocator.free(found_label);
        try std.testing.expectEqualStrings(label, found_label);
    }

    // Lookup non-existent label
    const fake_hash = Hash{ .bytes = [_]u8{9} ** 32 };
    const not_found = try lookupLabel(allocator, db.?, fake_hash);
    try std.testing.expect(not_found == null);
}

test "rainbow stats" {
    // Create in-memory database for testing
    var db: ?*c.sqlite3 = null;
    var rc = c.sqlite3_open(":memory:", &db);
    try std.testing.expectEqual(c.SQLITE_OK, rc);
    defer _ = c.sqlite3_close(db.?);

    // Create schema
    const schema =
        \\CREATE TABLE rainbow_labels (
        \\    labelhash TEXT PRIMARY KEY,
        \\    label TEXT NOT NULL,
        \\    source TEXT NOT NULL,
        \\    first_seen_block INTEGER NOT NULL,
        \\    first_seen_tx TEXT NOT NULL
        \\)
    ;

    rc = c.sqlite3_exec(db.?, schema.ptr, null, null, null);
    try std.testing.expectEqual(c.SQLITE_OK, rc);

    // Add some test labels
    const tx_hash = Hash{ .bytes = [_]u8{1} ** 32 };

    try storeLabel(db.?, computeLabelhash("label1"), "label1", .controller, 100, tx_hash);
    try storeLabel(db.?, computeLabelhash("label2"), "label2", .controller, 200, tx_hash);
    try storeLabel(db.?, computeLabelhash("label3"), "label3", .calldata, 300, tx_hash);

    // Get stats
    const stats = try getStats(db.?);
    try std.testing.expectEqual(@as(u64, 3), stats.total);
    try std.testing.expectEqual(@as(u64, 2), stats.controller);
    try std.testing.expectEqual(@as(u64, 1), stats.calldata);
    try std.testing.expectEqual(@as(u64, 0), stats.wrapper);
}
