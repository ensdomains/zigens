//! Record-model resolver storage (contracts-v2 `IRecordResolver`).
//!
//! The new `PermissionedResolver` keys every value by a `recordId` instead of a
//! node: `Linked(recordId, node, name)` binds a name's node to a record
//! (`recordId = 0` unbinds), many nodes may share one record, and the record
//! bound to `bytes32(0)` is the resolver-wide default for nodes without one.
//!
//! Record-keyed rows are stored in the SAME tables as node-keyed rows, under a
//! synthetic *record key* in the `namehash` column (`recordKey(record_id)`), so
//! writes, reorg capture, replay and every existing query shape are unchanged.
//! Only the key a read looks up differs: `resolveRecordKey` maps a
//! `(resolver, namehash)` pair to the row key exactly the way the contract's
//! `_record(node)` does — own record, else default record, else the node
//! itself (legacy node-keyed resolvers have no links at all).

const std = @import("std");
const db_module = @import("database.zig");
const reorg_undo = @import("reorg_undo.zig");
const Database = db_module.Database;
const Query = db_module.Query;
const models = @import("../types/models.zig");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;

/// Domain-separation tag hashed in front of the record id so a record key can
/// never collide with a real namehash (keccak256 preimage space).
pub const RECORD_KEY_TAG = "ensv2:resolver-record:";

/// Pairs per IN-list statement. Binds are static (arena-scratch hex), so this
/// is sized for statement length, not the tracked-string cap.
const LINK_BATCH_CHUNK: usize = 200;

pub const ResolverKind = struct {
    pub const record = "record";
};

/// The synthetic `namehash`-column key under which record `record_id`'s
/// values are stored: `keccak256(RECORD_KEY_TAG || be256(record_id))`. Ids are
/// carried at full uint256 width: PermissionedResolver allocates small
/// sequential ids, SharedResolver uses the name's node itself.
pub fn recordKey(record_id: u256) Hash {
    var preimage: [RECORD_KEY_TAG.len + 32]u8 = undefined;
    @memcpy(preimage[0..RECORD_KEY_TAG.len], RECORD_KEY_TAG);
    var be: [32]u8 = undefined;
    std.mem.writeInt(u256, &be, record_id, .big);
    @memcpy(preimage[RECORD_KEY_TAG.len..], &be);
    var out: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&preimage, &out, .{});
    return Hash{ .bytes = out };
}

pub const ZERO_RECORD_ID_HEX = "0x0000000000000000000000000000000000000000000000000000000000000000";

/// Storage spelling of a record id: fixed 66-char lowercase hex, so equality
/// and the unlinked (`<> ZERO`) guard hold for any uint256.
pub fn recordIdHex(record_id: u256, buf: *[66]u8) []const u8 {
    return std.fmt.bufPrint(buf, "0x{x:0>64}", .{record_id}) catch unreachable;
}

/// Parse a stored (`0x…` hex) or replayed (decimal string) record id.
pub fn parseRecordId(text: []const u8) ?u256 {
    if (text.len == 0) return null;
    if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X")) {
        return std.fmt.parseInt(u256, text[2..], 16) catch null;
    }
    return std.fmt.parseInt(u256, text, 10) catch null;
}

// ---------------------------------------------------------------------------
// resolver_links — Linked(recordId, node, name)
// ---------------------------------------------------------------------------

pub fn upsertResolverLink(
    db: *Database,
    protocol: models.Protocol,
    resolver: Address,
    namehash: Hash,
    record_id: u256,
    name: []const u8,
    block_number: u64,
    tx_hash: Hash,
    log_index: u32,
    timestamp: i64,
) !void {
    try reorg_undo.captureUpsert(db, "resolver_links", .{ protocol, resolver, namehash });
    const sql = try db.upsertSql(db.allocator, "resolver_links", &.{
        "protocol", "resolver",     "namehash",         "record_id", "record_key",
        "name",     "block_number", "transaction_hash", "log_index", "timestamp",
    }, .replace);
    defer db.allocator.free(sql);
    var q = try Query.initCached(db, sql);
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(resolver);
    try q.bindHash(namehash);
    var id_buf: [66]u8 = undefined;
    try q.bindText(recordIdHex(record_id, &id_buf));
    try q.bindHash(recordKey(record_id));
    try q.bindText(name);
    try q.bindInt64(@intCast(block_number));
    try q.bindHash(tx_hash);
    try q.bindInt(@intCast(log_index));
    try q.bindInt64(timestamp);
    try q.exec();
}

pub const ResolverLink = struct {
    /// 0 = explicitly unlinked (falls back to the default record on-chain).
    record_id: u256,
    record_key: Hash,
    name: []u8,
    block_number: u64,

    pub fn deinit(self: *ResolverLink, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

/// The link row for (resolver, namehash), if any Linked event bound it.
pub fn getResolverLink(db: *Database, resolver: Address, namehash: Hash) !?ResolverLink {
    var q = try Query.initCached(db,
        \\SELECT record_id, record_key, name, block_number FROM resolver_links
        \\WHERE resolver = ? AND namehash = ?
        \\LIMIT 1
    );
    defer q.deinit();
    try q.bindAddress(resolver);
    try q.bindHash(namehash);
    if (!try q.step()) return null;
    const key = Hash.fromHex(q.getTextSlice(1) orelse return null) catch return null;
    const name = try db.allocator.dupe(u8, q.getTextSlice(2) orelse "");
    return ResolverLink{
        .record_id = parseRecordId(q.getTextSlice(0) orelse "") orelse 0,
        .record_key = key,
        .name = name,
        .block_number = @intCast(q.getInt64(3)),
    };
}

/// The row key a record read for (resolver, namehash) must use — the
/// contract's `_record(node)`: the node's own record, else the resolver's
/// default record (node 0x0), else the node itself (legacy resolver).
pub fn resolveRecordKey(db: *Database, resolver: Address, namehash: Hash) !Hash {
    var q = try Query.initCached(db,
        \\SELECT namehash, record_id, record_key FROM resolver_links
        \\WHERE resolver = ? AND namehash IN (?, ?)
    );
    defer q.deinit();
    try q.bindAddress(resolver);
    try q.bindHash(namehash);
    try q.bindHash(Hash.zero);
    var own: ?Hash = null;
    var default: ?Hash = null;
    var zero_buf: [66]u8 = undefined;
    const zero_hex = Hash.zero.toHexBuf(&zero_buf);
    while (try q.step()) {
        if ((parseRecordId(q.getTextSlice(1) orelse "") orelse 0) == 0) continue;
        const row_nh = q.getTextSlice(0) orelse continue;
        const key = Hash.fromHex(q.getTextSlice(2) orelse continue) catch continue;
        if (std.mem.eql(u8, row_nh, zero_hex)) {
            default = key;
        } else {
            own = key;
        }
    }
    if (namehash.isZero()) return default orelse namehash;
    return own orelse default orelse namehash;
}

/// The effective record id for (resolver, namehash) — own, else default — or
/// null when the name resolves through no record (legacy or unlinked).
pub fn getEffectiveRecordId(db: *Database, resolver: Address, namehash: Hash) !?u256 {
    var q = try Query.initCached(db,
        \\SELECT namehash, record_id FROM resolver_links
        \\WHERE resolver = ? AND namehash IN (?, ?)
    );
    defer q.deinit();
    try q.bindAddress(resolver);
    try q.bindHash(namehash);
    try q.bindHash(Hash.zero);
    var own: ?u256 = null;
    var default: ?u256 = null;
    var zero_buf: [66]u8 = undefined;
    const zero_hex = Hash.zero.toHexBuf(&zero_buf);
    while (try q.step()) {
        const id = parseRecordId(q.getTextSlice(1) orelse "") orelse 0;
        if (id == 0) continue;
        const row_nh = q.getTextSlice(0) orelse continue;
        if (std.mem.eql(u8, row_nh, zero_hex)) {
            default = id;
        } else {
            own = id;
        }
    }
    if (namehash.isZero()) return default;
    return own orelse default;
}

/// Batched `resolveRecordKey`: fills `out[i]` for each `(resolvers[i],
/// namehashes[i])` pair with at most two IN-list statements per chunk (own
/// links + default links). Returns whether ANY pair was translated, so callers
/// can skip the row remap on pure-legacy pages.
pub fn resolveRecordKeys(db: *Database, resolvers: []const Address, namehashes: []const Hash, out: []Hash) !bool {
    std.debug.assert(resolvers.len == namehashes.len and out.len == namehashes.len);
    @memcpy(out, namehashes);
    if (resolvers.len == 0) return false;

    // Default record per resolver, keyed by resolver hex.
    var defaults = std.StringHashMap(Hash).init(db.allocator);
    defer {
        var it = defaults.keyIterator();
        while (it.next()) |k| db.allocator.free(k.*);
        defaults.deinit();
    }
    // Own record per pair, keyed by "<resolver_hex>|<namehash_hex>".
    var own = std.StringHashMap(Hash).init(db.allocator);
    defer {
        var it = own.keyIterator();
        while (it.next()) |k| db.allocator.free(k.*);
        own.deinit();
    }

    var zero_buf: [66]u8 = undefined;
    const zero_hex = Hash.zero.toHexBuf(&zero_buf);

    var off: usize = 0;
    while (off < resolvers.len) : (off += LINK_BATCH_CHUNK) {
        const end = @min(off + LINK_BATCH_CHUNK, resolvers.len);
        const n = end - off;

        var sql: std.ArrayList(u8) = .empty;
        defer sql.deinit(db.allocator);
        try sql.appendSlice(db.allocator, "SELECT resolver, namehash, record_id, record_key FROM resolver_links WHERE record_id <> '" ++ ZERO_RECORD_ID_HEX ++ "' AND ((resolver, namehash) IN (");
        for (0..n) |i| {
            if (i > 0) try sql.appendSlice(db.allocator, ", ");
            try sql.appendSlice(db.allocator, "(?, ?)");
        }
        try sql.appendSlice(db.allocator, ") OR (namehash = ? AND resolver IN (");
        for (0..n) |i| {
            if (i > 0) try sql.appendSlice(db.allocator, ", ");
            try sql.appendSlice(db.allocator, "?");
        }
        try sql.appendSlice(db.allocator, ")))");

        // Declared before the Query so the hex scratch outlives exec (LIFO defers).
        var arena = std.heap.ArenaAllocator.init(db.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();

        var q = try Query.init(db, sql.items);
        defer q.deinit();
        for (resolvers[off..end], namehashes[off..end]) |r, nh| {
            const r_buf = try scratch.create([42]u8);
            try q.bindTextStatic(r.toHexBuf(r_buf));
            const nh_buf = try scratch.create([66]u8);
            try q.bindTextStatic(nh.toHexBuf(nh_buf));
        }
        try q.bindTextStatic(zero_hex);
        for (resolvers[off..end]) |r| {
            const r_buf = try scratch.create([42]u8);
            try q.bindTextStatic(r.toHexBuf(r_buf));
        }
        while (try q.step()) {
            const r_hex = q.getTextSlice(0) orelse continue;
            const nh_hex = q.getTextSlice(1) orelse continue;
            const key = Hash.fromHex(q.getTextSlice(3) orelse continue) catch continue;
            if (std.mem.eql(u8, nh_hex, zero_hex)) {
                const gop = try defaults.getOrPut(r_hex);
                if (!gop.found_existing) {
                    gop.key_ptr.* = db.allocator.dupe(u8, r_hex) catch |err| {
                        _ = defaults.remove(r_hex);
                        return err;
                    };
                }
                gop.value_ptr.* = key;
            } else {
                var kbuf: [42 + 1 + 66]u8 = undefined;
                const composite = try std.fmt.bufPrint(&kbuf, "{s}|{s}", .{ r_hex, nh_hex });
                const gop = try own.getOrPut(composite);
                if (!gop.found_existing) {
                    gop.key_ptr.* = db.allocator.dupe(u8, composite) catch |err| {
                        _ = own.remove(composite);
                        return err;
                    };
                }
                gop.value_ptr.* = key;
            }
        }
    }

    var translated = false;
    for (resolvers, namehashes, 0..) |r, nh, i| {
        var r_buf: [42]u8 = undefined;
        const r_hex = r.toHexBuf(&r_buf);
        var nh_buf: [66]u8 = undefined;
        const nh_hex = nh.toHexBuf(&nh_buf);
        var kbuf: [42 + 1 + 66]u8 = undefined;
        const composite = try std.fmt.bufPrint(&kbuf, "{s}|{s}", .{ r_hex, nh_hex });
        const key: ?Hash = if (!nh.isZero()) (own.get(composite) orelse defaults.get(r_hex)) else defaults.get(r_hex);
        if (key) |k| {
            out[i] = k;
            translated = true;
        }
    }
    return translated;
}

pub const LinkedName = struct {
    name: []u8,
    namehash: Hash,
    record_id: u256,
    block_number: u64,

    pub fn deinit(self: *LinkedName, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

/// Every name currently bound to `record_id` on `resolver` (the sharing view;
/// the default-record binding to node 0x0 is included with its empty name).
/// The namehashes linked to `record_id` on `resolver` whose own `names` row still
/// points at that same resolver — exactly the set a write to that record belongs to.
///
/// ONE query, rather than `getLinkedNames` followed by a resolver lookup per link.
/// The eligibility test *is* `names.resolver = resolver_links.resolver`, so the join
/// expresses it directly and both sides stay index probes
/// (`idx_resolver_links_record`, and `names` UNIQUE(protocol, namehash)). A record
/// write is the hottest event class on a record-model deployment, so the per-link
/// round-trip it replaces was multiplying the cost of every one of them.
///
/// A NULL or zero `names.resolver` simply fails the join, which is the same answer
/// the per-link check gave. `bytes32(0)` is skipped: that is the resolver-wide
/// default record's node, which belongs to no single name.
pub fn getLinkedNamesUsingResolver(
    db: *Database,
    allocator: std.mem.Allocator,
    protocol: models.Protocol,
    resolver: Address,
    record_id: u256,
) ![]Hash {
    try db.namesBarrier();
    var q = try Query.initCached(db,
        \\SELECT l.namehash FROM resolver_links l
        \\JOIN names n ON n.protocol = ? AND n.namehash = l.namehash AND n.resolver = l.resolver
        \\WHERE l.resolver = ? AND l.record_id = ?
        \\ORDER BY l.block_number ASC, l.log_index ASC
    );
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(resolver);
    var id_buf: [66]u8 = undefined;
    try q.bindText(recordIdHex(record_id, &id_buf));

    var out: std.ArrayList(Hash) = .empty;
    errdefer out.deinit(allocator);
    while (try q.step()) {
        const nh = Hash.fromHex(q.getTextSlice(0) orelse continue) catch continue;
        if (nh.isZero()) continue;
        try out.append(allocator, nh);
    }
    return out.toOwnedSlice(allocator);
}

pub fn getLinkedNames(db: *Database, allocator: std.mem.Allocator, resolver: Address, record_id: u256) ![]LinkedName {
    var q = try Query.initCached(db,
        \\SELECT name, namehash, record_id, block_number FROM resolver_links
        \\WHERE resolver = ? AND record_id = ?
        \\ORDER BY block_number ASC, log_index ASC
    );
    defer q.deinit();
    try q.bindAddress(resolver);
    var id_buf: [66]u8 = undefined;
    try q.bindText(recordIdHex(record_id, &id_buf));
    var out: std.ArrayList(LinkedName) = .empty;
    errdefer {
        for (out.items) |*l| l.deinit(allocator);
        out.deinit(allocator);
    }
    while (try q.step()) {
        const nh = Hash.fromHex(q.getTextSlice(1) orelse continue) catch continue;
        const name = try allocator.dupe(u8, q.getTextSlice(0) orelse "");
        errdefer allocator.free(name);
        try out.append(allocator, .{
            .name = name,
            .namehash = nh,
            .record_id = parseRecordId(q.getTextSlice(2) orelse "") orelse 0,
            .block_number = @intCast(q.getInt64(3)),
        });
    }
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// resolver_datas — DataUpdated / DataChanged (ENSIP-24 `data(key)`)
// ---------------------------------------------------------------------------

pub fn storeResolverData(
    db: *Database,
    namehash: Hash,
    resolver: Address,
    key: []const u8,
    value_hex: []const u8,
    protocol: models.Protocol,
    block_number: u64,
    tx_hash: Hash,
    timestamp: i64,
) !void {
    try reorg_undo.captureUpsert(db, "resolver_datas", .{ protocol, resolver, namehash, key });
    const sql = try db.upsertSql(db.allocator, "resolver_datas", &.{ "namehash", "resolver", "key", "value", "protocol", "block_number", "transaction_hash", "timestamp" }, .replace);
    defer db.allocator.free(sql);
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindHash(namehash);
    try q.bindAddress(resolver);
    try q.bindText(key);
    try q.bindText(value_hex);
    try q.bindTextStatic(protocol.toString());
    try q.bindInt64(@intCast(block_number));
    try q.bindHash(tx_hash);
    try q.bindInt64(timestamp);
    try q.exec();
}

pub fn deleteResolverData(db: *Database, protocol: models.Protocol, namehash: Hash, resolver: Address, key: []const u8) !void {
    try reorg_undo.captureWhere(db, "resolver_datas", "D", "protocol = ? AND resolver = ? AND namehash = ? AND key = ?", .{ protocol, resolver, namehash, key });
    var q = try Query.init(db, "DELETE FROM resolver_datas WHERE protocol = ? AND resolver = ? AND namehash = ? AND key = ?");
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(resolver);
    try q.bindHash(namehash);
    try q.bindText(key);
    try q.exec();
}

/// Remove every data record stored under `namehash` (a record key on
/// `Cleared`, or a node on legacy clears).
pub fn deleteResolverDatas(db: *Database, protocol: models.Protocol, namehash: Hash, resolver: Address) !void {
    try reorg_undo.captureWhere(db, "resolver_datas", "D", "protocol = ? AND resolver = ? AND namehash = ?", .{ protocol, resolver, namehash });
    var q = try Query.init(db, "DELETE FROM resolver_datas WHERE protocol = ? AND resolver = ? AND namehash = ?");
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(resolver);
    try q.bindHash(namehash);
    try q.exec();
}

/// Remove one coin type's address row: `AddressUpdated` with empty bytes is
/// how a record resolver clears an address (`hasAddr` then reports false).
pub fn deleteResolverAddress(db: *Database, protocol: models.Protocol, namehash: Hash, resolver: Address, coin_type: u64) !void {
    try reorg_undo.captureWhere(db, "resolver_addresses", "D", "protocol = ? AND resolver = ? AND namehash = ? AND coin_type = ?", .{ protocol, resolver, namehash, @as(i64, @intCast(coin_type)) });
    var q = try Query.init(db, "DELETE FROM resolver_addresses WHERE protocol = ? AND resolver = ? AND namehash = ? AND coin_type = ?");
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(resolver);
    try q.bindHash(namehash);
    try q.bindInt64(@intCast(coin_type));
    try q.exec();
}

/// Latest data record value (0x-hex) for (resolver, namehash, key), through
/// the record indirection.
pub fn getDataRecord(db: *Database, resolver: Address, namehash: Hash, key: []const u8) !?[]u8 {
    const row_key = try resolveRecordKey(db, resolver, namehash);
    var q = try Query.init(db,
        \\SELECT value FROM resolver_datas
        \\WHERE resolver = ? AND namehash = ? AND key = ?
        \\ORDER BY block_number DESC
        \\LIMIT 1
    );
    defer q.deinit();
    try q.bindAddress(resolver);
    try q.bindHash(row_key);
    try q.bindText(key);
    if (try q.step()) return try q.getText(0);
    return null;
}

/// All data record keys set for (resolver, namehash), through the record
/// indirection. Caller frees each key and the slice.
pub fn getDataKeys(db: *Database, resolver: Address, namehash: Hash) ![][]u8 {
    const row_key = try resolveRecordKey(db, resolver, namehash);
    var q = try Query.init(db,
        \\SELECT DISTINCT key FROM resolver_datas
        \\WHERE resolver = ? AND namehash = ?
        \\ORDER BY key
    );
    defer q.deinit();
    try q.bindAddress(resolver);
    try q.bindHash(row_key);
    var keys: std.ArrayList([]u8) = .empty;
    errdefer {
        for (keys.items) |k| db.allocator.free(k);
        keys.deinit(db.allocator);
    }
    while (try q.step()) {
        if (try q.getText(0)) |k| {
            errdefer db.allocator.free(k);
            try keys.append(db.allocator, k);
        }
    }
    return keys.toOwnedSlice(db.allocator);
}

// ---------------------------------------------------------------------------
// resolver_kinds — ResolverCreated() marks a record-model resolver
// ---------------------------------------------------------------------------

pub fn upsertResolverKind(
    db: *Database,
    protocol: models.Protocol,
    resolver: Address,
    kind: []const u8,
    block_number: u64,
    tx_hash: Hash,
    log_index: u32,
    timestamp: i64,
) !void {
    try reorg_undo.captureUpsert(db, "resolver_kinds", .{ protocol, resolver });
    const sql = try db.upsertSql(db.allocator, "resolver_kinds", &.{ "protocol", "resolver", "kind", "block_number", "transaction_hash", "log_index", "timestamp" }, .replace);
    defer db.allocator.free(sql);
    var q = try Query.initCached(db, sql);
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(resolver);
    try q.bindText(kind);
    try q.bindInt64(@intCast(block_number));
    try q.bindHash(tx_hash);
    try q.bindInt(@intCast(log_index));
    try q.bindInt64(timestamp);
    try q.exec();
}

/// The announced kind of `resolver` ("record" after ResolverCreated), or null
/// for legacy node-keyed resolvers. Caller frees.
pub fn getResolverKind(db: *Database, resolver: Address) !?[]u8 {
    var q = try Query.initCached(db, "SELECT kind FROM resolver_kinds WHERE resolver = ? LIMIT 1");
    defer q.deinit();
    try q.bindAddress(resolver);
    if (try q.step()) return try q.getText(0);
    return null;
}

/// OR of every role bitmap granted on `resource` at `contract` (an EAC
/// resolver): which setter roles a `ResourceArgument` resource guards follows
/// from these bits (PermissionedResolverLib: ADDRESS 1<<0, TEXT 1<<4, ABI
/// 1<<12, INTERFACE 1<<16, DATA 1<<24; admin variants << 128).
pub fn getResourceRoleUnion(db: *Database, protocol: models.Protocol, contract: Address, resource_hex: []const u8) !u256 {
    var q = try Query.initCached(db, "SELECT role_bitmap FROM eac_roles WHERE protocol = ? AND contract_address = ? AND resource = ?");
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(contract);
    try q.bindText(resource_hex);
    var acc: u256 = 0;
    while (try q.step()) {
        const raw = q.getTextSlice(0) orelse continue;
        const body = if (std.mem.startsWith(u8, raw, "0x")) raw[2..] else raw;
        if (body.len == 0) continue;
        const bits = std.fmt.parseInt(u256, body, 16) catch continue;
        acc |= bits;
    }
    return acc;
}

test "recordKey is deterministic, id-sensitive and never the zero hash" {
    const k1 = recordKey(1);
    const k1b = recordKey(1);
    const k2 = recordKey(2);
    try std.testing.expect(k1.eql(k1b));
    try std.testing.expect(!k1.eql(k2));
    try std.testing.expect(!k1.isZero());
    try std.testing.expect(!recordKey(0).isZero());
}
