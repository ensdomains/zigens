//! Tests for the dispatch-scoped name prefetch (src/storage/name_prefetch.zig):
//! its two lookups must mirror the DB point lookups exactly (authoritative
//! misses and the LIMIT-2 uniqueness guard included), write-through from
//! insertName must make same-dispatch registrations visible, and every other
//! names write must invalidate so a surviving entry always equals the DB.

const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers");
const lib = @import("lib");
const models = lib.models;
const Address = lib.Address;
const Hash = lib.Hash;
const NamePrefetch = lib.storage.name_prefetch.NamePrefetch;
const Lookup = lib.storage.name_prefetch.Lookup;
const Tag = std.meta.Tag(Lookup);

const REG_1 = Address{ .bytes = [_]u8{0xC1} ** 20 };
const REG_2 = Address{ .bytes = [_]u8{0xC2} ** 20 };
const REG_3 = Address{ .bytes = [_]u8{0xC3} ** 20 };
const OWNER = Address{ .bytes = [_]u8{0xA1} ** 20 };

fn nthHash(n: u8) Hash {
    var h = Hash{ .bytes = [_]u8{0} ** 32 };
    h.bytes[31] = n;
    h.bytes[0] = 0x0C;
    return h;
}

fn fixtureName(n: u8, protocol: models.Protocol, registry: Address, cid: u256, name_str: []const u8) models.Name {
    return models.Name{
        .protocol = protocol,
        .name = name_str,
        .namehash = nthHash(n),
        .label = name_str,
        .label_hash = nthHash(n),
        .parent_name = "",
        .parent_namehash = Hash.zero,
        .registry = registry,
        .owner = OWNER,
        .registrant = OWNER,
        .resolver = Address.zero,
        .token_id = cid,
        .canonical_id = cid,
        .token_version = 1,
        .expiry = 0,
        .registry_locked = false,
        .migrated = false,
        .created_block = 100,
        .created_at = 1700000000,
        .registered_at = 1700000000,
        .updated_block = 100,
        .updated_at = 1700000000,
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    };
}

// Canonical ids: low 32 bits are the version counter and get masked, so a
// canonical id must have them zeroed.
const CID_AMBIG: u256 = @as(u256, 7) << 32; // two v2 rows, different registries
const CID_SOLO: u256 = @as(u256, 8) << 32; // one v2 row
const CID_SPLIT: u256 = @as(u256, 9) << 32; // one v1 row + one v2 row
const CID_EMPTY: u256 = @as(u256, 10) << 32; // prefetched, zero rows in DB
const CID_UNPREFETCHED: u256 = @as(u256, 11) << 32; // in DB, NOT prefetched

fn seedFixtures(database: anytype) !void {
    try database.insertName(fixtureName(1, .v2, REG_1, CID_AMBIG, "ambig-r1.eth"));
    try database.insertName(fixtureName(2, .v2, REG_2, CID_AMBIG, "ambig-r2.eth"));
    try database.insertName(fixtureName(3, .v2, REG_1, CID_SOLO, "solo.eth"));
    try database.insertName(fixtureName(4, .v1, REG_1, CID_SPLIT, "split.eth"));
    try database.insertName(fixtureName(5, .v2, REG_2, CID_SPLIT, "split-v2.eth"));
    try database.insertName(fixtureName(6, .v2, REG_1, CID_UNPREFETCHED, "unprefetched.eth"));
}

// Populate with RAW token ids (version bits set) — build must canonicalize.
const PREFETCH_TOKENS = [_]u256{ CID_AMBIG | 3, CID_SOLO | 1, CID_SPLIT, CID_EMPTY | 9 };

fn expectHitName(lookup: Lookup, expected: []const u8, alloc: std.mem.Allocator) !void {
    switch (lookup) {
        .hit => |h| {
            defer if (h.name) |nm| alloc.free(nm);
            try testing.expectEqualStrings(expected, h.name.?);
        },
        else => return error.ExpectedHit,
    }
}

test "prefetch lookups mirror the DB point lookups exactly" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    try seedFixtures(database);

    var np = NamePrefetch.init(allocator);
    defer np.deinit();
    try np.populate(database, &PREFETCH_TOKENS);

    // Paired hit — raw token id with version bits must canonicalize.
    try expectHitName(try np.pairedLookup(CID_SOLO | 55, REG_1, allocator), "solo.eth", allocator);
    // Paired: same cid, wrong registry — authoritative miss (row set complete).
    try testing.expectEqual(Tag.miss, std.meta.activeTag(try np.pairedLookup(CID_SOLO, REG_3, allocator)));
    // Paired on the ambiguous cid still resolves per registry.
    try expectHitName(try np.pairedLookup(CID_AMBIG, REG_2, allocator), "ambig-r2.eth", allocator);
    // Prefetched with zero rows: authoritative miss (explicit empty entry).
    try testing.expectEqual(Tag.miss, std.meta.activeTag(try np.pairedLookup(CID_EMPTY, REG_1, allocator)));
    // Never prefetched: unknown — must fall back, never claim a miss.
    try testing.expectEqual(Tag.unknown, std.meta.activeTag(try np.pairedLookup(CID_UNPREFETCHED, REG_1, allocator)));

    // Unique: single v2 row → hit.
    try expectHitName(try np.uniqueLookup(.v2, CID_SOLO | 2, allocator), "solo.eth", allocator);
    // Unique: cross-registry ambiguity → refuse to guess (SQL answers null).
    try testing.expectEqual(Tag.miss, std.meta.activeTag(try np.uniqueLookup(.v2, CID_AMBIG, allocator)));
    // Unique: protocol filter splits the pair — each side unique.
    try expectHitName(try np.uniqueLookup(.v1, CID_SPLIT, allocator), "split.eth", allocator);
    try expectHitName(try np.uniqueLookup(.v2, CID_SPLIT, allocator), "split-v2.eth", allocator);
    // Unique: empty entry → authoritative miss; unprefetched → unknown.
    try testing.expectEqual(Tag.miss, std.meta.activeTag(try np.uniqueLookup(.v2, CID_EMPTY, allocator)));
    try testing.expectEqual(Tag.unknown, std.meta.activeTag(try np.uniqueLookup(.v2, CID_UNPREFETCHED, allocator)));

    // Property check: wherever the map answers, it must agree with the DB.
    const registries = [_]Address{ REG_1, REG_2, REG_3 };
    const cids = [_]u256{ CID_AMBIG, CID_SOLO, CID_SPLIT, CID_EMPTY, CID_UNPREFETCHED };
    for (cids) |cid| {
        for (registries) |reg| {
            switch (try np.pairedLookup(cid, reg, allocator)) {
                .unknown => {},
                .miss => try testing.expectEqual(@as(?models.Name, null), try database.getNameByTokenIdAndRegistry(cid, reg)),
                .hit => |h| {
                    defer if (h.name) |nm| allocator.free(nm);
                    var db_hit = (try database.getNameByTokenIdAndRegistry(cid, reg)) orelse return error.MapClaimedPhantomRow;
                    defer db_hit.deinit(database.allocator);
                    try testing.expectEqualStrings(db_hit.name.?, h.name.?);
                    try testing.expect(db_hit.namehash.eql(h.namehash));
                },
            }
        }
        for ([_]models.Protocol{ .v1, .v2 }) |proto| {
            switch (try np.uniqueLookup(proto, cid, allocator)) {
                .unknown => {},
                .miss => try testing.expectEqual(@as(?models.Name, null), try database.getUniqueNameByCanonicalId(proto, cid)),
                .hit => |h| {
                    defer if (h.name) |nm| allocator.free(nm);
                    var db_hit = (try database.getUniqueNameByCanonicalId(proto, cid)) orelse return error.MapClaimedPhantomRow;
                    defer db_hit.deinit(database.allocator);
                    try testing.expectEqualStrings(db_hit.name.?, h.name.?);
                    try testing.expect(db_hit.namehash.eql(h.namehash));
                },
            }
        }
    }
}

test "write-through: same-dispatch registrations become map hits" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    var np = NamePrefetch.init(allocator);
    defer np.deinit();
    // Prefetch BEFORE any row exists — the dominant real workload: the
    // ResolverUpdated for a name registered earlier in the same batch.
    try np.populate(database, &[_]u256{ CID_SOLO | 7, CID_AMBIG });
    database.name_write_listener = np.listener();
    defer database.name_write_listener = null;

    try testing.expectEqual(Tag.miss, std.meta.activeTag(try np.pairedLookup(CID_SOLO, REG_1, allocator)));

    // Registration lands mid-dispatch → the map learns the row.
    try database.insertName(fixtureName(3, .v2, REG_1, CID_SOLO, "solo.eth"));
    try expectHitName(try np.pairedLookup(CID_SOLO | 9, REG_1, allocator), "solo.eth", allocator);
    try expectHitName(try np.uniqueLookup(.v2, CID_SOLO, allocator), "solo.eth", allocator);
    // Other registries stay authoritative misses.
    try testing.expectEqual(Tag.miss, std.meta.activeTag(try np.pairedLookup(CID_SOLO, REG_2, allocator)));

    // Label reveal between registration and ResolverUpdated: precise in-place
    // rewrite, protocol-scoped — the entry stays hot.
    try lib.storage.names.updateNameLabel(database, .v2, nthHash(3), "solo", "solo-revealed.eth", true);
    try expectHitName(try np.pairedLookup(CID_SOLO, REG_1, allocator), "solo-revealed.eth", allocator);

    // Same-key upsert that MOVES the row to a new canonical id (conflict on
    // (protocol, namehash)): the old entry must lose the row, the new
    // (prefetched) entry must gain it.
    var moved = fixtureName(3, .v2, REG_2, CID_AMBIG, "moved.eth");
    moved.token_id = CID_AMBIG;
    moved.canonical_id = CID_AMBIG;
    try database.insertName(moved);
    try testing.expectEqual(Tag.miss, std.meta.activeTag(try np.pairedLookup(CID_SOLO, REG_1, allocator)));
    try expectHitName(try np.pairedLookup(CID_AMBIG, REG_2, allocator), "moved.eth", allocator);

    // Insert under an UNPREFETCHED cid: the map must not invent knowledge.
    try database.insertName(fixtureName(6, .v2, REG_1, CID_UNPREFETCHED, "unprefetched.eth"));
    try testing.expectEqual(Tag.unknown, std.meta.activeTag(try np.pairedLookup(CID_UNPREFETCHED, REG_1, allocator)));
}

test "non-projection writes invalidate conservatively; bulk writes clear" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    try seedFixtures(database);

    var np = NamePrefetch.init(allocator);
    defer np.deinit();
    try np.populate(database, &PREFETCH_TOKENS);
    database.name_write_listener = np.listener();
    defer database.name_write_listener = null;

    // Namehash-keyed update (outside the projection) drops the touched entry.
    try database.updateNameResolver(nthHash(3), REG_3);
    try testing.expectEqual(Tag.unknown, std.meta.activeTag(try np.pairedLookup(CID_SOLO, REG_1, allocator)));
    // Untouched entries keep serving.
    try testing.expectEqual(Tag.miss, std.meta.activeTag(try np.uniqueLookup(.v2, CID_AMBIG, allocator)));

    // Cross-protocol same-namehash rows: nthHash(4) belongs to the v1 SPLIT
    // row; a namehash write must reach every entry that may hold it.
    try database.deleteNameByNamehash(nthHash(4));
    try testing.expectEqual(Tag.unknown, std.meta.activeTag(try np.uniqueLookup(.v1, CID_SPLIT, allocator)));

    // Bulk write (reachability cascade) clears everything.
    var np2 = NamePrefetch.init(allocator);
    defer np2.deinit();
    try np2.populate(database, &PREFETCH_TOKENS);
    database.name_write_listener = np2.listener();
    defer database.name_write_listener = null;
    _ = try lib.storage.registry_entries.setRegistriesReachability(database, .v2, &[_]Address{REG_2}, false, 200, 1700000100);
    try testing.expectEqual(Tag.unknown, std.meta.activeTag(try np2.pairedLookup(CID_AMBIG, REG_2, allocator)));
    try testing.expectEqual(Tag.unknown, std.meta.activeTag(try np2.uniqueLookup(.v2, CID_SPLIT, allocator)));

    // Placeholder-parent patch (names_registry) is keyless too — must clear,
    // but ONLY when it matched rows: it runs once per registration and almost
    // always matches nothing, and an ungated clear would disable the prefetch
    // in exactly the registration-heavy batches it exists for.
    var child = fixtureName(41, .v2, REG_1, @as(u256, 41) << 32, "kid.canonicalId:12345");
    child.parent_name = "canonicalId:12345";
    try database.insertName(child);
    var np3 = NamePrefetch.init(allocator);
    defer np3.deinit();
    try np3.populate(database, &[_]u256{CID_AMBIG});
    database.name_write_listener = np3.listener();
    defer database.name_write_listener = null;
    _ = try lib.storage.names_registry.updateRegistryPlaceholderName(database, "canonicalId:99999", "no-match.eth", nthHash(42));
    try expectHitName(try np3.pairedLookup(CID_AMBIG, REG_1, allocator), "ambig-r1.eth", allocator);
    _ = try lib.storage.names_registry.updateRegistryPlaceholderName(database, "canonicalId:12345", "patched.eth", nthHash(40));
    try testing.expectEqual(Tag.unknown, std.meta.activeTag(try np3.pairedLookup(CID_AMBIG, REG_1, allocator)));
}
