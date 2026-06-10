const std = @import("std");
const db_module = @import("database.zig");
const reorg_undo = @import("reorg_undo.zig");
const Database = db_module.Database;
const Query = db_module.Query;
const Hash = @import("../types/hash.zig").Hash;
const Address = @import("../types/address.zig").Address;

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
    db: *Database,
    name_id: ?i64,
    transaction_hash: Hash,
    labelhash: Hash,
    namehash: Hash,
    parent_node: Hash,
    owner: Address,
    block_number: u64,
) !void {
    const existed = try reorg_undo.activeRowExists(db, "unknown_labels", "labelhash = ? AND parent_node = ?", .{ labelhash, parent_node });
    var q = try Query.init(db,
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
    );
    defer q.deinit();

    try q.bindOptionalInt64(name_id);
    try q.bindHash(transaction_hash);
    try q.bindHash(labelhash);
    try q.bindHash(namehash);
    try q.bindHash(parent_node);
    try q.bindAddress(owner);
    try q.bindInt64(@intCast(block_number));
    try q.exec();
    if (!existed) try reorg_undo.captureActiveWhere(db, "unknown_labels", "I", "labelhash = ? AND parent_node = ?", .{ labelhash, parent_node });
}

/// Get all unknown labels that need backfill (limited attempts).
/// Returned strings are owned by `allocator`; free each row with `freeUnknownLabel`.
pub fn getUnknownLabelsForBackfill(
    allocator: std.mem.Allocator,
    db: *Database,
    limit: u32,
) ![]UnknownLabel {
    var q = try Query.init(db,
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
    );
    defer q.deinit();

    try q.bindInt64(@intCast(limit));

    var results: std.ArrayList(UnknownLabel) = .{};
    errdefer {
        for (results.items) |label| freeUnknownLabel(allocator, label);
        results.deinit(allocator);
    }

    while (try q.step()) {
        // Row strings are duped with the caller's `allocator` (freed by
        // freeUnknownLabel), so use the borrowed getTextSlice rather than the
        // Statement-allocator-backed getText.
        const tx_hash = try allocator.dupe(u8, q.getTextSlice(2) orelse "");
        errdefer allocator.free(tx_hash);
        const labelhash = try allocator.dupe(u8, q.getTextSlice(3) orelse "");
        errdefer allocator.free(labelhash);
        const namehash = try allocator.dupe(u8, q.getTextSlice(4) orelse "");
        errdefer allocator.free(namehash);
        const parent_node = try allocator.dupe(u8, q.getTextSlice(5) orelse "");
        errdefer allocator.free(parent_node);
        const owner = try allocator.dupe(u8, q.getTextSlice(6) orelse "");
        errdefer allocator.free(owner);

        try results.append(allocator, UnknownLabel{
            .id = q.getInt64(0),
            .name_id = q.getOptionalInt64(1),
            .transaction_hash = tx_hash,
            .labelhash = labelhash,
            .namehash = namehash,
            .parent_node = parent_node,
            .owner = owner,
            .block_number = q.getInt64(7),
            .created_at = q.getInt64(8),
            .backfill_attempts = q.getInt64(9),
            .last_backfill_attempt = q.getOptionalInt64(10),
        });
    }

    return results.toOwnedSlice(allocator);
}

/// Increment backfill attempt counter for an unknown label
pub fn incrementBackfillAttempt(db: *Database, id: i64) !void {
    // `strftime('%s','now')` is SQLite-only; dialect.nowEpoch is the portable current-epoch
    // expression (strftime on SQLite, EXTRACT(EPOCH FROM now())::bigint on Postgres).
    try reorg_undo.captureActiveWhere(db, "unknown_labels", "U", "id = ?", .{id});
    const sql = try std.fmt.allocPrint(db.allocator,
        \\UPDATE unknown_labels
        \\SET backfill_attempts = backfill_attempts + 1,
        \\    last_backfill_attempt = {s}
        \\WHERE id = ?
    , .{db.dialect().nowEpoch});
    defer db.allocator.free(sql);
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindInt64(id);
    try q.exec();
}

/// Delete an unknown label record after successful backfill
pub fn deleteUnknownLabel(db: *Database, id: i64) !void {
    try reorg_undo.captureActiveWhere(db, "unknown_labels", "D", "id = ?", .{id});
    var q = try Query.init(db, "DELETE FROM unknown_labels WHERE id = ?");
    defer q.deinit();
    try q.bindInt64(id);
    try q.exec();
}

/// Get count of unknown labels still eligible for backfill
pub fn getUnknownLabelCount(db: *Database) !u64 {
    var q = try Query.init(db, "SELECT COUNT(*) FROM unknown_labels WHERE backfill_attempts < 3");
    defer q.deinit();
    if (try q.step()) {
        return @intCast(q.getInt64(0));
    }
    return error.DatabaseError;
}

/// Free an UnknownLabel record's allocated fields
pub fn freeUnknownLabel(allocator: std.mem.Allocator, label: UnknownLabel) void {
    allocator.free(label.transaction_hash);
    allocator.free(label.labelhash);
    allocator.free(label.namehash);
    allocator.free(label.parent_node);
    allocator.free(label.owner);
}
