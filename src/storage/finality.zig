//! Finality tiers (Task 09): per-chain `safe` / `finalized` block positions.
//!
//! The indexer periodically fetches the chain's `safe` and `finalized` block tags and
//! persists them here so the API can signal how settled an answer is (the `head` tier is
//! derived from sync_state, not stored). Keyed by chain_id — multi-chain (Task 11) drops
//! in without a schema change. Created via `ensureSchema` (like resolution_cache), so it
//! is not part of the drop-and-reindex base schema and does not affect PG-schema drift.
//!
//! Signalling only: this never blocks indexing (best-effort; a fetch failure leaves the
//! prior/absent position). Per-tier monotonicity (a tier only ever advances) is enforced
//! in `setFinality`; the cross-tier `finalized <= safe` invariant is checked by the writer
//! before it calls in.

const std = @import("std");
const db_module = @import("database.zig");
const Database = db_module.Database;
const Query = db_module.Query;
const Hash = @import("../types/hash.zig").Hash;

pub const Tier = enum {
    safe,
    finalized,
    pub fn toString(self: Tier) []const u8 {
        return @tagName(self);
    }
};

pub const Position = struct {
    number: u64,
    hash: Hash,
    updated_at: i64,
};

pub fn ensureSchema(db: *Database) !void {
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS finality_state (
        \\  chain_id BIGINT NOT NULL,
        \\  tier TEXT NOT NULL,
        \\  number BIGINT NOT NULL,
        \\  hash TEXT NOT NULL,
        \\  updated_at BIGINT NOT NULL,
        \\  PRIMARY KEY (chain_id, tier)
        \\)
    );
}

/// Upsert the `tier` position for `chain_id`. `now` is the fetch time (unix seconds).
/// Monotonic: a tier only advances. A provider that momentarily reports a lower (or a
/// transiently wrong) safe/finalized head must not move the persisted position backward;
/// a genuine downward correction reconverges once a higher head is reported again.
pub fn setFinality(db: *Database, chain_id: u64, tier: Tier, number: u64, hash: Hash, now: i64) !void {
    if (try getFinality(db, chain_id, tier)) |current| {
        if (number < current.number) return;
    }

    const sql = try db.upsertSql(db.allocator, "finality_state", &.{ "chain_id", "tier", "number", "hash", "updated_at" }, .replace);
    defer db.allocator.free(sql);

    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindInt64(@intCast(chain_id));
    try q.bindTextStatic(tier.toString());
    try q.bindInt64(@intCast(number));
    try q.bindHashBuf(hash);
    try q.bindInt64(now);
    try q.exec();
}

/// Read the `tier` position for `chain_id`, or null if not yet fetched.
pub fn getFinality(db: *Database, chain_id: u64, tier: Tier) !?Position {
    const sql = "SELECT number, hash, updated_at FROM finality_state WHERE chain_id = ? AND tier = ?";
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindInt64(@intCast(chain_id));
    try q.bindTextStatic(tier.toString());
    if (try q.step()) {
        const hash = (try q.getHash(1)) orelse Hash.zero; // hash column is NOT NULL
        return Position{
            .number = @intCast(q.getInt64(0)),
            .hash = hash,
            .updated_at = q.getInt64(2),
        };
    }
    return null;
}

test "finality_state round-trips per (chain, tier) and is null when unset" {
    const a = std.testing.allocator;
    var database = try Database.init(a, ":memory:");
    defer database.deinit();

    try std.testing.expect((try getFinality(&database, 1, .safe)) == null);

    const safe_hash = Hash{ .bytes = [_]u8{0xaa} ** 32 };
    const fin_hash = Hash{ .bytes = [_]u8{0xbb} ** 32 };
    try setFinality(&database, 1, .safe, 100, safe_hash, 1700000000);
    try setFinality(&database, 1, .finalized, 90, fin_hash, 1700000000);

    const s = (try getFinality(&database, 1, .safe)).?;
    try std.testing.expectEqual(@as(u64, 100), s.number);
    try std.testing.expectEqual(safe_hash.bytes, s.hash.bytes);
    const f = (try getFinality(&database, 1, .finalized)).?;
    try std.testing.expectEqual(@as(u64, 90), f.number);

    // Upsert overwrites the same (chain, tier).
    try setFinality(&database, 1, .safe, 110, safe_hash, 1700000100);
    try std.testing.expectEqual(@as(u64, 110), (try getFinality(&database, 1, .safe)).?.number);
    // A different chain is independent.
    try std.testing.expect((try getFinality(&database, 2, .safe)) == null);
}

test "setFinality is monotonic: a lower head does not move a tier backward" {
    const a = std.testing.allocator;
    var database = try Database.init(a, ":memory:");
    defer database.deinit();

    const h1 = Hash{ .bytes = [_]u8{0x11} ** 32 };
    const h2 = Hash{ .bytes = [_]u8{0x22} ** 32 };
    try setFinality(&database, 1, .safe, 200, h1, 1700000000);
    // A backward move (e.g. a provider blip) is ignored, hash included.
    try setFinality(&database, 1, .safe, 150, h2, 1700000100);
    const after_backward = (try getFinality(&database, 1, .safe)).?;
    try std.testing.expectEqual(@as(u64, 200), after_backward.number);
    try std.testing.expectEqual(h1.bytes, after_backward.hash.bytes);
    // Forward still advances, including an equal-height re-report (hash refresh).
    try setFinality(&database, 1, .safe, 200, h2, 1700000200);
    try std.testing.expectEqual(h2.bytes, (try getFinality(&database, 1, .safe)).?.hash.bytes);
    try setFinality(&database, 1, .safe, 250, h1, 1700000300);
    try std.testing.expectEqual(@as(u64, 250), (try getFinality(&database, 1, .safe)).?.number);
}
