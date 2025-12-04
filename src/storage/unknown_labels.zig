const std = @import("std");
const db_module = @import("database.zig");
const Database = db_module.Database;
const c = db_module.c;
const Hash = @import("../types/hash.zig").Hash;
const Address = @import("../types/address.zig").Address;

// SQLITE_TRANSIENT - For Zig 0.15.1, we can't use the C constant due to alignment issues
// Instead, we use null which tells SQLite to make a copy of the string
inline fn SQLITE_TRANSIENT() c.sqlite3_destructor_type {
    return null;
}

/// Record for tracking unknown subdomain labels that need backfill
pub const UnknownLabel = struct {
    id: i64,
    name_id: ?i64,
    transaction_hash: []const u8,
    labelhash: []const u8,
    namehash: []const u8,
    parent_node: []const u8,
    owner: []const u8,
    block_number: i64,
    created_at: i64,
    backfill_attempts: i64,
    last_backfill_attempt: ?i64,
};

/// Insert a new unknown label record
pub fn insertUnknownLabel(
    db: *c.sqlite3,
    name_id: ?i64,
    transaction_hash: Hash,
    labelhash: Hash,
    namehash: Hash,
    parent_node: Hash,
    owner: Address,
    block_number: u64,
) !void {
    const allocator = std.heap.c_allocator;

    const tx_hash_hex = try transaction_hash.toHex(allocator);
    defer allocator.free(tx_hash_hex);

    const labelhash_hex = try labelhash.toHex(allocator);
    defer allocator.free(labelhash_hex);

    const namehash_hex = try namehash.toHex(allocator);
    defer allocator.free(namehash_hex);

    const parent_node_hex = try parent_node.toHex(allocator);
    defer allocator.free(parent_node_hex);

    const owner_hex = try owner.toHex(allocator);
    defer allocator.free(owner_hex);

    const query =
        \\INSERT INTO unknown_labels (
        \\  name_id,
        \\  transaction_hash,
        \\  labelhash,
        \\  namehash,
        \\  parent_node,
        \\  owner,
        \\  block_number
        \\) VALUES (?, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(labelhash, parent_node) DO NOTHING
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    var rc = c.sqlite3_prepare_v2(db, query.ptr, @intCast(query.len), &stmt, null);
    if (rc != c.SQLITE_OK) {
        std.log.err("Failed to prepare unknown_labels insert: {s}", .{c.sqlite3_errmsg(db)});
        return error.DatabaseError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    if (name_id) |nid| {
        _ = c.sqlite3_bind_int64(stmt, 1, nid);
    } else {
        _ = c.sqlite3_bind_null(stmt, 1);
    }

    _ = c.sqlite3_bind_text(stmt, 2, tx_hash_hex.ptr, @intCast(tx_hash_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 3, labelhash_hex.ptr, @intCast(labelhash_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 4, namehash_hex.ptr, @intCast(namehash_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 5, parent_node_hex.ptr, @intCast(parent_node_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 6, owner_hex.ptr, @intCast(owner_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 7, @intCast(block_number));

    rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_DONE and rc != c.SQLITE_OK) {
        std.log.err("Failed to insert unknown_labels: {s}", .{c.sqlite3_errmsg(db)});
        return error.DatabaseError;
    }
}

/// Get all unknown labels that need backfill (limited attempts)
pub fn getUnknownLabelsForBackfill(
    allocator: std.mem.Allocator,
    db: *c.sqlite3,
    limit: u32,
) ![]UnknownLabel {
    const query =
        \\SELECT
        \\  id,
        \\  name_id,
        \\  transaction_hash,
        \\  labelhash,
        \\  namehash,
        \\  parent_node,
        \\  owner,
        \\  block_number,
        \\  created_at,
        \\  backfill_attempts,
        \\  last_backfill_attempt
        \\FROM unknown_labels
        \\WHERE backfill_attempts < 3
        \\ORDER BY created_at ASC
        \\LIMIT ?
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(db, query.ptr, @intCast(query.len), &stmt, null);
    if (rc != c.SQLITE_OK) {
        return error.DatabaseError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int64(stmt, 1, @intCast(limit));

    var results: std.ArrayList(UnknownLabel) = .{};
    errdefer {
        for (results.items) |label| {
            freeUnknownLabel(allocator, label);
        }
        results.deinit(allocator);
    }

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const id = c.sqlite3_column_int64(stmt, 0);

        const name_id: ?i64 = if (c.sqlite3_column_type(stmt, 1) == c.SQLITE_NULL)
            null
        else
            c.sqlite3_column_int64(stmt, 1);

        const tx_hash_text = c.sqlite3_column_text(stmt, 2);
        const tx_hash = try allocator.dupe(u8, std.mem.span(tx_hash_text));

        const labelhash_text = c.sqlite3_column_text(stmt, 3);
        const labelhash = try allocator.dupe(u8, std.mem.span(labelhash_text));

        const namehash_text = c.sqlite3_column_text(stmt, 4);
        const namehash = try allocator.dupe(u8, std.mem.span(namehash_text));

        const parent_text = c.sqlite3_column_text(stmt, 5);
        const parent_node = try allocator.dupe(u8, std.mem.span(parent_text));

        const owner_text = c.sqlite3_column_text(stmt, 6);
        const owner = try allocator.dupe(u8, std.mem.span(owner_text));

        const block_number = c.sqlite3_column_int64(stmt, 7);
        const created_at = c.sqlite3_column_int64(stmt, 8);
        const backfill_attempts = c.sqlite3_column_int64(stmt, 9);

        const last_backfill_attempt: ?i64 = if (c.sqlite3_column_type(stmt, 10) == c.SQLITE_NULL)
            null
        else
            c.sqlite3_column_int64(stmt, 10);

        try results.append(allocator, UnknownLabel{
            .id = id,
            .name_id = name_id,
            .transaction_hash = tx_hash,
            .labelhash = labelhash,
            .namehash = namehash,
            .parent_node = parent_node,
            .owner = owner,
            .block_number = block_number,
            .created_at = created_at,
            .backfill_attempts = backfill_attempts,
            .last_backfill_attempt = last_backfill_attempt,
        });
    }

    return results.toOwnedSlice(allocator);
}

/// Increment backfill attempt counter for an unknown label
pub fn incrementBackfillAttempt(db: *c.sqlite3, id: i64) !void {
    const query =
        \\UPDATE unknown_labels
        \\SET backfill_attempts = backfill_attempts + 1,
        \\    last_backfill_attempt = strftime('%s', 'now')
        \\WHERE id = ?
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    const rc_prep = c.sqlite3_prepare_v2(db, query.ptr, @intCast(query.len), &stmt, null);
    if (rc_prep != c.SQLITE_OK) {
        return error.DatabaseError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int64(stmt, 1, id);
    const rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_DONE) {
        return error.DatabaseError;
    }
}

/// Delete an unknown label record after successful backfill
pub fn deleteUnknownLabel(db: *c.sqlite3, id: i64) !void {
    const query = "DELETE FROM unknown_labels WHERE id = ?";

    var stmt: ?*c.sqlite3_stmt = null;
    const rc_prep = c.sqlite3_prepare_v2(db, query.ptr, @intCast(query.len), &stmt, null);
    if (rc_prep != c.SQLITE_OK) {
        return error.DatabaseError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int64(stmt, 1, id);
    const rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_DONE) {
        return error.DatabaseError;
    }
}

/// Get count of unknown labels
pub fn getUnknownLabelCount(db: *c.sqlite3) !u64 {
    const query = "SELECT COUNT(*) FROM unknown_labels WHERE backfill_attempts < 3";

    var stmt: ?*c.sqlite3_stmt = null;
    const rc_prep = c.sqlite3_prepare_v2(db, query.ptr, @intCast(query.len), &stmt, null);
    if (rc_prep != c.SQLITE_OK) {
        return error.DatabaseError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    const rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_ROW) {
        return error.DatabaseError;
    }

    return @intCast(c.sqlite3_column_int64(stmt, 0));
}

/// Free an UnknownLabel record's allocated fields
pub fn freeUnknownLabel(allocator: std.mem.Allocator, label: UnknownLabel) void {
    allocator.free(label.transaction_hash);
    allocator.free(label.labelhash);
    allocator.free(label.namehash);
    allocator.free(label.parent_node);
    allocator.free(label.owner);
}
