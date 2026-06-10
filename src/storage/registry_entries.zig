/// Registry-entries storage module: indexer-side mirror of the on-chain
/// PermissionedRegistry.Entry mapping. Keyed by `(protocol, parent_registry,
/// canonical_id)` — the parent registry contract plus the version-stripped
/// token id of the label whose Entry this row represents.
///
/// Only the `subregistry` pointer is mirrored — that's all the cascade
/// invalidation needs. `handleSubregistryUpdated` reads the previous value
/// here, decides if the new value is a repoint, and when it is, walks the
/// descendant tree of the previous subregistry to mark every `names` row
/// sourced through it as unreachable.
const std = @import("std");
const db_module = @import("database.zig");
const reorg_undo = @import("reorg_undo.zig");
const Database = db_module.Database;
const Query = db_module.Query;
const models = @import("../types/models.zig");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;
const token_id_utils = @import("../types/token_id.zig");

fn formatU256HexBuf(buf: *[66]u8, value: u256) []const u8 {
    return std.fmt.bufPrint(buf, "0x{x:0>64}", .{value}) catch unreachable;
}

/// One live (parent_registry, canonical_id) entry currently pointing at a
/// subregistry. Strings are allocator-owned; free via `freeLiveParents`.
pub const LiveParent = struct {
    parent_registry: []u8,
    canonical_id: []u8,
};

pub fn freeLiveParents(allocator: std.mem.Allocator, parents: []LiveParent) void {
    for (parents) |p| {
        allocator.free(p.parent_registry);
        allocator.free(p.canonical_id);
    }
    allocator.free(parents);
}

/// Live parents of `subregistry_hex` in the on-chain Entry mirror: the
/// (parent_registry, canonical_id) rows whose pointer CURRENTLY targets it.
/// The `registries` reverse-lookup the handlers use is append-only history, so
/// it over-counts after benign sequential repoints; this is the live truth
/// that gates the "Multi-parent subregistry" warning (audit #37) — > 1 row
/// here is a TRUE simultaneous multi-parent (a VerifiableFactory
/// one-instance-per-name deployment-convention violation). LIMIT 3: the
/// warning needs "more than one" plus the two conflicting pairs, not the full
/// set. Uses idx_registry_entries_subregistry. Caller frees via
/// `freeLiveParents`.
pub fn getLiveParents(
    db: *Database,
    allocator: std.mem.Allocator,
    protocol: models.Protocol,
    subregistry_hex: []const u8,
) ![]LiveParent {
    var q = try Query.initCached(db,
        \\SELECT parent_registry, canonical_id FROM registry_entries
        \\WHERE protocol = ? AND subregistry = ?
        \\ORDER BY updated_block DESC
        \\LIMIT 3
    );
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindText(subregistry_hex);

    var parents: std.ArrayList(LiveParent) = .{};
    errdefer {
        for (parents.items) |p| {
            allocator.free(p.parent_registry);
            allocator.free(p.canonical_id);
        }
        parents.deinit(allocator);
    }
    while (try q.step()) {
        const parent = try allocator.dupe(u8, q.getTextSlice(0) orelse continue);
        errdefer allocator.free(parent);
        const canonical = try allocator.dupe(u8, q.getTextSlice(1) orelse continue);
        errdefer allocator.free(canonical);
        try parents.append(allocator, .{ .parent_registry = parent, .canonical_id = canonical });
    }
    return parents.toOwnedSlice(allocator);
}

/// Upsert the subregistry pointer for a parent label's entry. Returns the
/// *previous* pointer (Address.zero if no row existed) so the handler can
/// decide whether to cascade-invalidate descendants.
pub fn upsertSubregistry(
    db: *Database,
    protocol: models.Protocol,
    parent_registry: Address,
    token_id: u256,
    new_subregistry: Address,
    block_number: u64,
    block_timestamp: i64,
) !Address {
    const canonical_id = token_id_utils.getCanonicalId(token_id);
    var canonical_buf: [66]u8 = undefined;
    const canonical_hex = formatU256HexBuf(&canonical_buf, canonical_id);

    const previous = try getSubregistry(db, protocol, parent_registry, token_id);

    try reorg_undo.captureUpsert(db, "registry_entries", .{ protocol, parent_registry, canonical_hex });
    var q = try Query.initCached(db,
        \\INSERT INTO registry_entries
        \\  (protocol, parent_registry, canonical_id, subregistry, updated_block, updated_at)
        \\VALUES (?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(protocol, parent_registry, canonical_id) DO UPDATE SET
        \\  subregistry = excluded.subregistry,
        \\  updated_block = excluded.updated_block,
        \\  updated_at = excluded.updated_at
    );
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(parent_registry);
    try q.bindText(canonical_hex);
    try q.bindAddress(new_subregistry);
    try q.bindInt64(@intCast(block_number));
    try q.bindInt64(block_timestamp);
    try q.exec();

    return previous;
}

/// Get the current subregistry pointer for a `(parent_registry, token_id)`
/// pair. Returns `Address.zero` when no entry exists — caller treats this
/// as "initial pointer, not a repoint".
pub fn getSubregistry(
    db: *Database,
    protocol: models.Protocol,
    parent_registry: Address,
    token_id: u256,
) !Address {
    const canonical_id = token_id_utils.getCanonicalId(token_id);
    var canonical_buf: [66]u8 = undefined;
    const canonical_hex = formatU256HexBuf(&canonical_buf, canonical_id);

    var q = try Query.initCached(db,
        \\SELECT subregistry FROM registry_entries
        \\WHERE protocol = ? AND parent_registry = ? AND canonical_id = ?
        \\LIMIT 1
    );
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(parent_registry);
    try q.bindText(canonical_hex);

    if (try q.step()) {
        const addr_str = q.getTextSlice(0) orelse return Address.zero;
        return try Address.fromHex(addr_str);
    }
    return Address.zero;
}

/// BFS the descendant tree under `root` to produce the complete set of
/// subregistry contract addresses transitively reachable from `root` via
/// `registry_entries.subregistry` edges, including `root` itself.
///
/// `db` is the first parameter so this can be called with method syntax
/// (`database.collectSubregistrySubtree(allocator, protocol, root)`).
///
/// Caller owns the returned slice and frees with `allocator.free(slice)`.
///
/// Concretely: if registry A's entry for label `fresh` points at B, and B's
/// entry for label `foo` points at C, then `collectSubtreeRooted(A)` returns
/// `[A, B, C]`. This is the set of `names.registry` values that were sourced
/// through A's subtree.
pub fn collectSubtreeRooted(
    db: *Database,
    allocator: std.mem.Allocator,
    protocol: models.Protocol,
    root: Address,
) ![]Address {
    var seen: std.AutoHashMap(Address, void) = .init(allocator);
    defer seen.deinit();
    var result: std.ArrayList(Address) = .{};
    errdefer result.deinit(allocator);
    var frontier: std.ArrayList(Address) = .{};
    defer frontier.deinit(allocator);

    if (root.isZero()) return try result.toOwnedSlice(allocator);

    try seen.put(root, {});
    try result.append(allocator, root);
    try frontier.append(allocator, root);

    while (frontier.items.len > 0) {
        const current = frontier.swapRemove(frontier.items.len - 1);

        var q = try Query.initCached(db,
            \\SELECT DISTINCT subregistry FROM registry_entries
            \\WHERE protocol = ? AND parent_registry = ?
            \\  AND subregistry != '0x0000000000000000000000000000000000000000'
        );
        defer q.deinit();
        try q.bindTextStatic(protocol.toString());
        try q.bindAddress(current);

        while (try q.step()) {
            const child_str = q.getTextSlice(0) orelse continue;
            const child = Address.fromHex(child_str) catch continue;
            if (child.isZero() or seen.contains(child)) continue;
            try seen.put(child, {});
            try result.append(allocator, child);
            try frontier.append(allocator, child);
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Bulk-flip `names.is_reachable` for every name whose source `registry` is
/// in `registries`. When `reachable = false`, also stamps `unreachable_since`;
/// when `reachable = true`, clears it. `registries` is typically a subtree
/// returned by `collectSubtreeRooted` and is kept reasonably sized.
pub fn setRegistriesReachability(
    db: *Database,
    protocol: models.Protocol,
    registries: []const Address,
    reachable: bool,
    block_number: u64,
    block_timestamp: i64,
) !u64 {
    if (registries.len == 0) return 0;

    // Chunked: each registry address is a tracked text bind, and Statement caps
    // tracked binds at 32 (error.TooManyBoundParams beyond that) — large
    // collectSubtreeRooted subtrees must therefore split the IN-list. The
    // write-path undo capture mirrors each chunk's exact predicate.
    const CHUNK: usize = 24;
    var total: u64 = 0;
    var off: usize = 0;
    while (off < registries.len) : (off += CHUNK) {
        const chunk = registries[off..@min(off + CHUNK, registries.len)];

        var where_buf: std.ArrayList(u8) = .{};
        defer where_buf.deinit(db.allocator);
        try where_buf.appendSlice(db.allocator, if (reachable)
            "protocol = ? AND is_reachable = 0 AND registry IN ("
        else
            "protocol = ? AND is_reachable = 1 AND registry IN (");
        for (chunk, 0..) |_, i| {
            if (i > 0) try where_buf.appendSlice(db.allocator, ", ");
            try where_buf.append(db.allocator, '?');
        }
        try where_buf.append(db.allocator, ')');

        const Binder = struct {
            protocol: models.Protocol,
            registries: []const Address,
            pub fn bind(self: @This(), cq: *Query) !void {
                try cq.bindText(self.protocol.toString());
                for (self.registries) |r| try cq.bindAddressBuf(r);
            }
        };
        try reorg_undo.captureWhereBinder(db, "names", "U", where_buf.items, Binder{ .protocol = protocol, .registries = chunk });

        var sql_buf: std.ArrayList(u8) = .{};
        defer sql_buf.deinit(db.allocator);
        try sql_buf.appendSlice(db.allocator, if (reachable)
            "UPDATE names SET is_reachable = 1, unreachable_since = NULL, updated_block = ?, updated_at = ? WHERE "
        else
            "UPDATE names SET is_reachable = 0, unreachable_since = ?, updated_block = ?, updated_at = ? WHERE ");
        try sql_buf.appendSlice(db.allocator, where_buf.items);

        var q = try Query.init(db, sql_buf.items);
        defer q.deinit();
        if (!reachable) try q.bindInt64(block_timestamp);
        try q.bindInt64(@intCast(block_number));
        try q.bindInt64(block_timestamp);
        try q.bindTextStatic(protocol.toString());
        for (chunk) |r| try q.bindAddress(r);
        try q.exec();
        total += @intCast(q.changes());
    }
    return total;
}

/// Soft-delete a single name by namehash (sets is_reachable = 0). Used by
/// LabelUnregistered so re-registration can reactivate via the UPSERT
/// instead of losing history.
pub fn markNameUnreachableByNamehash(
    db: *Database,
    protocol: models.Protocol,
    namehash: Hash,
    block_number: u64,
    block_timestamp: i64,
) !void {
    try reorg_undo.captureWhere(db, "names", "U", "protocol = ? AND namehash = ?", .{ protocol, namehash });
    var q = try Query.initCached(db,
        \\UPDATE names SET is_reachable = 0, unreachable_since = ?, updated_block = ?, updated_at = ?
        \\WHERE protocol = ? AND namehash = ?
    );
    defer q.deinit();
    try q.bindInt64(block_timestamp);
    try q.bindInt64(@intCast(block_number));
    try q.bindInt64(block_timestamp);
    try q.bindTextStatic(protocol.toString());
    try q.bindHash(namehash);
    try q.exec();
}
