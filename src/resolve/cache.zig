//! Resolution cache.
//!
//! A derived, disposable overlay that memoizes query-time on-chain reads (the
//! answers produced by the resolution layer) so repeated lookups don't re-issue
//! an RPC call, and so those answers invalidate correctly when the chain reorgs.
//!
//! Every row is pinned to the block hash its answer was read against
//! (`block_dep_hash`) and the height of that block (`block_dep_num`). Rows are
//! never authoritative state: on a rollback the indexer drops every row whose
//! pinned height is newer than the rollback target (see `storage/sync.zig`
//! `rollbackToBlock`/`deleteDataAfterBlock`), and the next read simply
//! re-resolves against the restored chain. Because it self-heals, the table is
//! deliberately NOT part of the reorg undo-log (it is neither a protected nor a
//! captured table) and its DDL is created idempotently at startup rather than
//! living in the drop-and-reindex base schema.
//!
//! Binary columns follow the storage convention used everywhere else in this
//! codebase: addresses and hashes are stored as `0x`-prefixed lowercase hex
//! TEXT, not as a binary type, so the schema is identical across backends.

const std = @import("std");
const db_module = @import("../storage/database.zig");
const Database = db_module.Database;
const Query = db_module.Query;
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;

/// Outcome of a resolution attempt.
pub const Status = enum {
    /// The call returned a concrete value (`value` is populated).
    success,
    /// The call succeeded but resolved to "no record" (empty / zero result).
    not_found,
    /// The call reverted on-chain.
    reverted,
    /// The RPC endpoint or transport failed (transient; short-lived cache).
    rpc_error,

    pub fn toString(self: Status) []const u8 {
        return switch (self) {
            .success => "success",
            .not_found => "not_found",
            .reverted => "reverted",
            .rpc_error => "rpc_error",
        };
    }

    /// Unknown strings collapse to `rpc_error` (treated as a soft, refreshable miss).
    pub fn fromString(s: []const u8) Status {
        if (std.mem.eql(u8, s, "success")) return .success;
        if (std.mem.eql(u8, s, "not_found")) return .not_found;
        if (std.mem.eql(u8, s, "reverted")) return .reverted;
        return .rpc_error;
    }
};

/// Where a served value came from — stamped so callers can distinguish an
/// indexed answer from one produced by a live read.
pub const Source = enum {
    /// A direct on-chain read (e.g. via the resolver/registry).
    resolved_live,
    /// An answer completed through an offchain (CCIP-Read) lookup.
    resolved_ccip,
    /// A reverse-name value recovered via a live reverse lookup.
    reverse_rpc,

    pub fn toString(self: Source) []const u8 {
        return switch (self) {
            .resolved_live => "resolved_live",
            .resolved_ccip => "resolved_ccip",
            .reverse_rpc => "reverse_rpc",
        };
    }

    pub fn fromString(s: []const u8) Source {
        if (std.mem.eql(u8, s, "resolved_ccip")) return .resolved_ccip;
        if (std.mem.eql(u8, s, "reverse_rpc")) return .reverse_rpc;
        return .resolved_live;
    }
};

/// The identity of a cached answer. Two reads collide only when every field
/// matches — in particular a different `block_dep_hash` is a distinct row, which
/// is what makes reorg invalidation a plain "delete rows above the fork" DELETE.
pub const Key = struct {
    /// Chain the read was issued against (one process serves one chain).
    chain_id: u64,
    /// Contract that was called.
    target: Address,
    /// Logical query name, e.g. "addr:60" or "text:avatar".
    selector_key: []const u8,
    /// keccak256 of the ABI-encoded calldata (see `argHash`).
    arg_hash: Hash,
    /// Height of the block the answer is pinned to.
    block_dep_num: u64,
    /// Hash of the block the answer is pinned to.
    block_dep_hash: Hash,
};

/// A materialized cache entry. `value` is caller-owned when non-null; free it
/// with `deinit` (or the same allocator passed to `get`).
pub const Entry = struct {
    status: Status,
    /// Raw result bytes; non-null only for `.success`.
    value: ?[]const u8,
    source: Source,
    /// Unix seconds when the answer was fetched (drives TTL freshness).
    fetched_at: i64,

    pub fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        if (self.value) |v| allocator.free(v);
    }
};

const hex_alphabet = "0123456789abcdef";

/// Encode raw bytes as `0x`-prefixed lowercase hex. Caller owns the result.
fn bytesToHexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, 2 + bytes.len * 2);
    out[0] = '0';
    out[1] = 'x';
    for (bytes, 0..) |b, i| {
        out[2 + i * 2] = hex_alphabet[b >> 4];
        out[2 + i * 2 + 1] = hex_alphabet[b & 0x0f];
    }
    return out;
}

/// Decode `0x`-prefixed (or bare) hex into raw bytes. Caller owns the result.
fn hexToBytesAlloc(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    const h = if (std.mem.startsWith(u8, hex, "0x")) hex[2..] else hex;
    if (h.len % 2 != 0) return error.InvalidHexLength;
    const out = try allocator.alloc(u8, h.len / 2);
    errdefer allocator.free(out);
    _ = try std.fmt.hexToBytes(out, h);
    return out;
}

/// keccak256 of the calldata — the `arg_hash` component of a cache key. Runtime
/// input, so it uses the streaming primitive directly (the comptime helper in
/// `utils/keccak.zig` cannot take a runtime slice).
pub fn argHash(calldata: []const u8) Hash {
    var out: Hash = .{ .bytes = undefined };
    std.crypto.hash.sha3.Keccak256.hash(calldata, &out.bytes, .{});
    return out;
}

/// Create the cache table if it does not exist. Idempotent; called at DB init on
/// every backend so already-synced deployments gain the table without a reindex.
/// `BIGINT`/`TEXT` are valid on both SQLite (via type affinity) and Postgres, so
/// one DDL string serves both — timestamps need the 64-bit width (a 32-bit
/// `INTEGER` unix time overflows in 2038).
pub fn ensureSchema(db: *Database) !void {
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS resolution_cache (
        \\  chain_id BIGINT NOT NULL,
        \\  target TEXT NOT NULL,
        \\  selector_key TEXT NOT NULL,
        \\  arg_hash TEXT NOT NULL,
        \\  block_dep_num BIGINT NOT NULL,
        \\  block_dep_hash TEXT NOT NULL,
        \\  status TEXT NOT NULL,
        \\  value TEXT,
        \\  source TEXT NOT NULL,
        \\  fetched_at BIGINT NOT NULL,
        \\  PRIMARY KEY (chain_id, target, selector_key, arg_hash, block_dep_hash)
        \\)
    );
    try db.exec("CREATE INDEX IF NOT EXISTS idx_resolution_cache_block ON resolution_cache(chain_id, block_dep_num)");
}

const upsert_cols = [_][]const u8{
    "chain_id",       "target", "selector_key", "arg_hash", "block_dep_num",
    "block_dep_hash", "status", "value",        "source",   "fetched_at",
};

/// Insert or overwrite a cached answer. `value` is required for `.success` and
/// ignored otherwise; `now` is the fetch timestamp (unix seconds).
pub fn put(
    db: *Database,
    key: Key,
    status: Status,
    value: ?[]const u8,
    source: Source,
    now: i64,
) !void {
    const sql = try db.upsertSql(db.allocator, "resolution_cache", &upsert_cols, .replace);
    defer db.allocator.free(sql);

    const value_hex: ?[]u8 = if (value) |v| try bytesToHexAlloc(db.allocator, v) else null;
    defer if (value_hex) |vh| db.allocator.free(vh);

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindInt64(@intCast(key.chain_id));
    try q.bindAddress(key.target);
    try q.bindText(key.selector_key);
    try q.bindHash(key.arg_hash);
    try q.bindInt64(@intCast(key.block_dep_num));
    try q.bindHash(key.block_dep_hash);
    try q.bindTextStatic(status.toString());
    try q.bindOptionalText(value_hex);
    try q.bindTextStatic(source.toString());
    try q.bindInt64(now);
    try q.exec();

    // Bound growth: once this query's answer is recorded at the current head, drop any
    // superseded rows for the same query pinned to an OLDER block. Reads always pin to
    // the current head, so an older-head row can never be a hit; and the reorg DELETEs
    // only cover block_dep_num > N, so without this the table would accrue one dead row
    // per advancing head forever. This keeps at most one row per (target, selector, args).
    var prune = try Query.init(db, "DELETE FROM resolution_cache WHERE chain_id = ? AND target = ? AND selector_key = ? AND arg_hash = ? AND block_dep_num < ?");
    defer prune.deinit();
    try prune.bindInt64(@intCast(key.chain_id));
    try prune.bindAddress(key.target);
    try prune.bindText(key.selector_key);
    try prune.bindHash(key.arg_hash);
    try prune.bindInt64(@intCast(key.block_dep_num));
    try prune.exec();
}

/// Look up a cached answer by QUERY IDENTITY (chain, target, selector, args) — NOT by
/// the pinned block. Matching on the caller's current head would invalidate every entry
/// each time the indexer advances, re-issuing the whole fan-out per query (observed as
/// one live call per record per head-move). The pinned block still matters: the reorg
/// rollback DELETEs rows with block_dep_num above the fork (sync.zig), so an
/// orphaned-chain answer can never be served; freshness is bounded by the caller's TTL.
/// Returns null on a miss. On a hit the caller owns `entry.value` (free via
/// `Entry.deinit`).
pub fn get(allocator: std.mem.Allocator, db: *Database, key: Key) !?Entry {
    var q = try Query.init(db,
        \\SELECT status, value, source, fetched_at
        \\FROM resolution_cache
        \\WHERE chain_id = ? AND target = ? AND selector_key = ? AND arg_hash = ?
        \\ORDER BY block_dep_num DESC, fetched_at DESC
        \\LIMIT 1
    );
    defer q.deinit();

    try q.bindInt64(@intCast(key.chain_id));
    try q.bindAddress(key.target);
    try q.bindText(key.selector_key);
    try q.bindHash(key.arg_hash);

    if (!try q.step()) return null;

    const status_str = q.getTextSlice(0) orelse return null;
    const status = Status.fromString(status_str);

    const value: ?[]const u8 = blk: {
        const vh = q.getTextSlice(1) orelse break :blk null;
        break :blk try hexToBytesAlloc(allocator, vh);
    };

    const source = Source.fromString(q.getTextSlice(2) orelse "resolved_live");
    const fetched_at = q.getInt64(3);

    return Entry{ .status = status, .value = value, .source = source, .fetched_at = fetched_at };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testKey(chain_id: u64, selector: []const u8, block_num: u64, block_hash: Hash) Key {
    return .{
        .chain_id = chain_id,
        .target = Address.zero,
        .selector_key = selector,
        .arg_hash = argHash("deadbeef"),
        .block_dep_num = block_num,
        .block_dep_hash = block_hash,
    };
}

test "argHash is deterministic and input-sensitive" {
    try testing.expect(argHash("abc").eql(argHash("abc")));
    try testing.expect(!argHash("abc").eql(argHash("abd")));
}

test "hex round-trip preserves bytes" {
    const a = testing.allocator;
    const bytes = [_]u8{ 0x00, 0x12, 0xab, 0xff };
    const hex = try bytesToHexAlloc(a, &bytes);
    defer a.free(hex);
    try testing.expectEqualStrings("0x0012abff", hex);
    const back = try hexToBytesAlloc(a, hex);
    defer a.free(back);
    try testing.expectEqualSlices(u8, &bytes, back);
}

test "cache put/get round-trip and miss" {
    const a = testing.allocator;
    var db = try db_module.Database.init(a, ":memory:");
    defer db.deinit();

    const h = Hash{ .bytes = [_]u8{0x11} ** 32 };
    const key = testKey(db.chain_id, "addr:60", 100, h);
    const payload = [_]u8{ 0xde, 0xad, 0xbe, 0xef };

    try put(&db, key, .success, &payload, .resolved_live, 1700000000);

    const got = (try get(a, &db, key)) orelse return error.ExpectedHit;
    defer got.deinit(a);
    try testing.expectEqual(Status.success, got.status);
    try testing.expectEqual(Source.resolved_live, got.source);
    try testing.expectEqual(@as(i64, 1700000000), got.fetched_at);
    try testing.expectEqualSlices(u8, &payload, got.value.?);

    // A different query (selector) is a distinct identity → miss.
    const other = testKey(db.chain_id, "text:url", 100, h);
    try testing.expect((try get(a, &db, other)) == null);

    // Same query pinned at a LATER head is still a hit: lookup is by query identity,
    // so an advancing indexer head does not invalidate fresh answers (freshness is the
    // caller's TTL; reorged rows are removed by the rollback DELETE, tested below).
    const advanced = testKey(db.chain_id, "addr:60", 107, Hash{ .bytes = [_]u8{0x22} ** 32 });
    const still = (try get(a, &db, advanced)) orelse return error.ExpectedHitAcrossHeads;
    defer still.deinit(a);
    try testing.expectEqualSlices(u8, &payload, still.value.?);
}

test "reorg rollback drops cache rows pinned above the fork" {
    const a = testing.allocator;
    var db = try db_module.Database.init(a, ":memory:");
    defer db.deinit();

    // Distinct queries (different selectors) so the same-query prune in put() doesn't
    // cross them — this test isolates the reorg DELETE, not the prune.
    const kept = testKey(db.chain_id, "sel_a", 99, Hash{ .bytes = [_]u8{0xaa} ** 32 });
    const dropped = testKey(db.chain_id, "sel_b", 105, Hash{ .bytes = [_]u8{0xbb} ** 32 });

    try put(&db, kept, .success, &[_]u8{0x01}, .resolved_live, 1700000000);
    try put(&db, dropped, .success, &[_]u8{0x02}, .resolved_live, 1700000000);

    // Roll the chain back to block 100: the row pinned at 105 is now invalid.
    try db.rollbackToBlock(.v2, 100);

    const still = (try get(a, &db, kept)) orelse return error.ExpectedKeptRow;
    still.deinit(a);
    try testing.expect((try get(a, &db, dropped)) == null);
}

test "put prunes superseded rows for the same query at older heads" {
    const a = testing.allocator;
    var db = try db_module.Database.init(a, ":memory:");
    defer db.deinit();

    // Same query (same selector + args), resolved at two advancing heads.
    const old_head = testKey(db.chain_id, "addr:60", 100, Hash{ .bytes = [_]u8{0xaa} ** 32 });
    const new_head = testKey(db.chain_id, "addr:60", 105, Hash{ .bytes = [_]u8{0xbb} ** 32 });

    try put(&db, old_head, .success, &[_]u8{0x01}, .resolved_live, 1700000000);
    try put(&db, new_head, .success, &[_]u8{0x02}, .resolved_live, 1700000001);

    // The superseded older-head row is pruned; only the current-head row survives.
    // Lookup is by query identity, so BOTH key variants hit the same surviving row —
    // proven by the value: the old head's payload (0x01) is gone, replaced by 0x02.
    const via_old = (try get(a, &db, old_head)) orelse return error.ExpectedCurrentRow;
    defer via_old.deinit(a);
    try testing.expectEqualSlices(u8, &[_]u8{0x02}, via_old.value.?);
    const cur = (try get(a, &db, new_head)) orelse return error.ExpectedCurrentRow;
    defer cur.deinit(a);
    try testing.expectEqualSlices(u8, &[_]u8{0x02}, cur.value.?);
}
