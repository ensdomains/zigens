//! Cache-first on-chain resolver.
//!
//! Wraps the JSON-RPC client with the resolution cache so a record read is
//! answered from a fresh cached row when possible and issued as a single
//! block-hash-pinned `eth_call` otherwise. Pinning to the block hash is what
//! lets a reorg invalidate the answer (the cache row is dropped when its block
//! is rolled back).
//!
//! This is the seam every resolution feature builds on: a primary-name forward
//! check, a live record-read fallback, and (later) offchain completion all call
//! `callCached` rather than opening their own RPC path. Callers treat any
//! non-`.success` result as "no live answer" and fall back to the indexed value
//! — a resolution failure must never surface as a hard error to the reader.

const std = @import("std");
const rpc = @import("../rpc/client.zig");
const cache = @import("cache.zig");
const db_module = @import("../storage/database.zig");
const Database = db_module.Database;
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;

pub const Resolver = struct {
    rpc_client: *rpc.Client,
    db: *Database,
    /// Chain the reads are issued against (also the cache partition key).
    chain_id: u64,
    /// Soft freshness window, in seconds, for cached answers.
    ttl_s: u32,

    pub fn init(rpc_client: *rpc.Client, db: *Database, chain_id: u64, ttl_s: u32) Resolver {
        return .{ .rpc_client = rpc_client, .db = db, .chain_id = chain_id, .ttl_s = ttl_s };
    }

    /// Read `calldata` from `to`, pinned to `(block_num, block_hash)`.
    ///
    /// Returns a cached entry when a fresh one exists; otherwise issues one
    /// `eth_call`, records the outcome, and returns it. A transport/revert
    /// failure is recorded as `.rpc_error` (never thrown) so the caller can
    /// degrade to its indexed answer. The returned entry's `value` is owned by
    /// `allocator` (free via `Entry.deinit`).
    pub fn callCached(
        self: *Resolver,
        allocator: std.mem.Allocator,
        to: Address,
        selector_key: []const u8,
        calldata: []const u8,
        block_num: u64,
        block_hash: Hash,
        now: i64,
    ) !cache.Entry {
        const key = cache.Key{
            .chain_id = self.chain_id,
            .target = to,
            .selector_key = selector_key,
            .arg_hash = cache.argHash(calldata),
            .block_dep_num = block_num,
            .block_dep_hash = block_hash,
        };

        if (try cache.get(allocator, self.db, key)) |cached| {
            if (isFresh(cached.fetched_at, now, self.ttl_s)) return cached;
            cached.deinit(allocator); // stale: fall through and re-read
        }

        const raw = self.rpc_client.ethCall(to, calldata, .{ .hash = block_hash }) catch {
            try cache.put(self.db, key, .rpc_error, null, .resolved_live, now);
            return cache.Entry{ .status = .rpc_error, .value = null, .source = .resolved_live, .fetched_at = now };
        };
        defer self.rpc_client.allocator.free(raw);

        // An empty return is "no record"; a non-empty return is a concrete value.
        // Record-type-specific emptiness (e.g. the zero address) is interpreted by
        // the caller, not here, so this layer stays record-agnostic.
        const status: cache.Status = if (raw.len == 0) .not_found else .success;
        const stored_value: ?[]const u8 = if (status == .success) raw else null;
        try cache.put(self.db, key, status, stored_value, .resolved_live, now);

        const owned: ?[]const u8 = if (stored_value) |v| try allocator.dupe(u8, v) else null;
        return cache.Entry{ .status = status, .value = owned, .source = .resolved_live, .fetched_at = now };
    }
};

/// Whether a cached answer fetched at `fetched_at` is still within its TTL as of
/// `now` (unix seconds). A `now` before `fetched_at` (clock skew / non-monotonic
/// wall clock) is treated as fresh rather than instantly stale.
pub fn isFresh(fetched_at: i64, now: i64, ttl_s: u32) bool {
    if (now < fetched_at) return true;
    return (now - fetched_at) <= @as(i64, ttl_s);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "isFresh honors the ttl window" {
    try testing.expect(isFresh(1000, 1000, 300)); // same instant
    try testing.expect(isFresh(1000, 1300, 300)); // exactly at the edge
    try testing.expect(!isFresh(1000, 1301, 300)); // just past
    try testing.expect(isFresh(1000, 900, 300)); // clock skew → fresh
}
