//! In-memory ledger of the placeholder names the V2 handlers may have written
//! ahead of a registration: `canonicalId:N` (registries rows, their children's
//! parent_name, and event names from a SubregistryUpdated that beat the
//! name) and `tokenId:N` (event names from a ResolverUpdated / NameBurned /
//! TokenRegenerated that could not resolve the name).
//!
//! LabelRegistered / NameRegistered patch those rows once the real name is
//! known. Unconditionally that cost four zero-row statements per registration
//! (one of them an unindexed scan of `names`) on a workload where placeholders
//! are the rare exception. With this ledger a registration patches only when a
//! placeholder for its id was actually written — the ledger is seeded from the
//! database at sync start (and re-seeded after a reorg rollback, whose undo
//! rows can resurrect placeholders) and fed by every site that writes one, so
//! it is always a superset of the placeholders on disk. A superset only ever
//! costs an extra no-op patch; while unseeded every registration patches, the
//! pre-ledger behaviour.

const std = @import("std");
const db_module = @import("../storage/database.zig");
const Database = db_module.Database;
const Query = db_module.Query;

pub const CANONICAL_PREFIX = "canonicalId:";
pub const TOKEN_PREFIX = "tokenId:";

pub const PlaceholderLedger = struct {
    canonical_ids: std.AutoHashMap(u256, void),
    token_ids: std.AutoHashMap(u256, void),
    seeded: bool = false,

    pub fn init(allocator: std.mem.Allocator) PlaceholderLedger {
        return .{
            .canonical_ids = std.AutoHashMap(u256, void).init(allocator),
            .token_ids = std.AutoHashMap(u256, void).init(allocator),
        };
    }

    pub fn deinit(self: *PlaceholderLedger) void {
        self.canonical_ids.deinit();
        self.token_ids.deinit();
    }

    /// Load every placeholder currently on disk. Any failure leaves the
    /// ledger unseeded, i.e. every registration patches as before.
    /// Seed once per process. The ledger is in-memory and grows on its own during a run
    /// (`noteName` / `noteCanonicalId`), so re-deriving it from disk mid-run is pure waste —
    /// and worse than waste, because it CLEARS what the run has learned and rebuilds it with
    /// four unindexed prefix scans. Those measured **970ms combined on the reference mirror**
    /// (170k names / 1.1M events) to recover 22 rows, and they were running once per
    /// `indexProtocol` call — i.e. once per poll cycle per protocol, forever, growing with the
    /// event table.
    ///
    /// A forced re-seed IS required after a reorg rollback, whose undo rows can resurrect
    /// placeholders the ledger already forgot; that call site uses `seed` directly.
    pub fn seedOnce(self: *PlaceholderLedger, db: *Database) void {
        if (self.seeded) return;
        self.seed(db);
    }

    pub fn seed(self: *PlaceholderLedger, db: *Database) void {
        self.canonical_ids.clearRetainingCapacity();
        self.token_ids.clearRetainingCapacity();
        self.seeded = false;
        const sources = [_][]const u8{
            "SELECT DISTINCT name FROM registries WHERE name LIKE 'canonicalId:%'",
            "SELECT DISTINCT parent_name FROM names WHERE parent_name LIKE 'canonicalId:%'",
            "SELECT DISTINCT name FROM events WHERE name LIKE 'canonicalId:%'",
            "SELECT DISTINCT name FROM events WHERE name LIKE 'tokenId:%'",
        };
        for (sources) |sql| {
            self.seedFrom(db, sql) catch |err| {
                std.log.warn("placeholder ledger: seed query failed ({}); every registration will patch placeholders this run", .{err});
                self.canonical_ids.clearRetainingCapacity();
                self.token_ids.clearRetainingCapacity();
                return;
            };
        }
        self.seeded = true;
        std.log.info("Placeholder ledger seeded: {d} canonical id(s), {d} token id(s)", .{ self.canonical_ids.count(), self.token_ids.count() });
    }

    fn seedFrom(self: *PlaceholderLedger, db: *Database, sql: []const u8) !void {
        var q = try Query.init(db, sql);
        defer q.deinit();
        while (try q.step()) {
            const name = q.getTextSlice(0) orelse continue;
            try self.noteName(name);
        }
    }

    /// Record a name string that was (or is about to be) written as a
    /// placeholder. Non-placeholder names are ignored.
    pub fn noteName(self: *PlaceholderLedger, name: []const u8) !void {
        if (parseId(name, CANONICAL_PREFIX)) |cid| {
            try self.canonical_ids.put(cid, {});
        } else if (parseId(name, TOKEN_PREFIX)) |tok| {
            try self.token_ids.put(tok, {});
        }
    }

    pub fn noteCanonicalId(self: *PlaceholderLedger, cid: u256) !void {
        try self.canonical_ids.put(cid, {});
    }

    /// True when a registration for `cid` must run the canonicalId patch.
    pub fn owesCanonicalPatch(self: *const PlaceholderLedger, cid: u256) bool {
        return !self.seeded or self.canonical_ids.contains(cid);
    }

    pub fn owesTokenPatch(self: *const PlaceholderLedger, token_id: u256) bool {
        return !self.seeded or self.token_ids.contains(token_id);
    }

    /// The patch ran: nothing is owed for the id until a placeholder is
    /// written again.
    pub fn canonicalPatched(self: *PlaceholderLedger, cid: u256) void {
        _ = self.canonical_ids.remove(cid);
    }

    pub fn tokenPatched(self: *PlaceholderLedger, token_id: u256) void {
        _ = self.token_ids.remove(token_id);
    }
};

pub fn parseId(name: []const u8, prefix: []const u8) ?u256 {
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    return std.fmt.parseInt(u256, name[prefix.len..], 10) catch null;
}

const testing = std.testing;

test "unseeded ledger owes every patch; seeded ledger owes only noted ids" {
    var ledger = PlaceholderLedger.init(testing.allocator);
    defer ledger.deinit();
    try testing.expect(ledger.owesCanonicalPatch(7));
    try testing.expect(ledger.owesTokenPatch(7));

    ledger.seeded = true;
    try testing.expect(!ledger.owesCanonicalPatch(7));
    try testing.expect(!ledger.owesTokenPatch(7));

    try ledger.noteName("canonicalId:7");
    try ledger.noteName("tokenId:340282366920938463463374607431768211456");
    try ledger.noteName("vitalik.eth");
    try testing.expect(ledger.owesCanonicalPatch(7));
    try testing.expect(!ledger.owesTokenPatch(7));
    try testing.expect(ledger.owesTokenPatch(340282366920938463463374607431768211456));

    ledger.canonicalPatched(7);
    try testing.expect(!ledger.owesCanonicalPatch(7));
}

test "parseId rejects malformed placeholder strings" {
    try testing.expectEqual(@as(?u256, 42), parseId("tokenId:42", TOKEN_PREFIX));
    try testing.expectEqual(@as(?u256, null), parseId("tokenId:", TOKEN_PREFIX));
    try testing.expectEqual(@as(?u256, null), parseId("tokenId:abc", TOKEN_PREFIX));
    try testing.expectEqual(@as(?u256, null), parseId("canonicalId:1", TOKEN_PREFIX));
}
