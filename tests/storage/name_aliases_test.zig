/// Tests for shared-registry aliases: the "one Domain per live referring parent"
/// derivation that fixes subname misattribution across a shared subregistry.
///
/// The shape under test, from the field report: koala.eth deploys a registry and
/// mints labels in it; kangaroo.eth then adopts the SAME registry contract; every
/// label in it now resolves under both names on-chain, but a LabelRegistered event
/// is emitted by the child registry and names no parent, so the handler stores one
/// FQDN per label and the other half is missing entirely.
///
/// These drive the storage layer directly — the live edge set, the plan (what the
/// definition owes), the stale delete, the guards that keep a primary row safe, and
/// the properties the production loop depends on: a total plan order, a steady state
/// that costs nothing, and a cursor that cannot be starved.
const std = @import("std");
const testing = std.testing;
const lib = @import("lib");
const helpers = @import("helpers");
const Database = lib.Database;
const Address = lib.Address;
const Hash = lib.Hash;
const models = lib.models;
const name_aliases = lib.storage.name_aliases;

const ETH_REGISTRY = Address{ .bytes = [_]u8{0xE7} ** 20 };
/// The shared child registry: koala.eth deployed it, kangaroo.eth adopted it.
const SHARED = Address{ .bytes = [_]u8{0x14} ** 20 };
const SHARED_HEX = "0x1414141414141414141414141414141414141414";
const OTHER = Address{ .bytes = [_]u8{0x77} ** 20 };
const OTHER_HEX = "0x7777777777777777777777777777777777777777";
const OWNER = helpers.TEST_OWNER_1;

/// The `registry_entries` key for a label: its labelhash with the token-version bits
/// cleared, exactly what the contract's Entry mapping is keyed on.
fn canonicalOf(label: []const u8) !u256 {
    const label_hash = try lib.labelhash(testing.allocator, label);
    return std.mem.readInt(u256, &label_hash.bytes, .big) & ~@as(u256, 0xffffffff);
}

/// Insert a 2LD living in the eth registry — the shape of a parent name.
fn seedParent(allocator: std.mem.Allocator, database: *Database, name: []const u8) !Hash {
    const dot = std.mem.indexOfScalar(u8, name, '.').?;
    return seedName(allocator, database, name[0..dot], name[dot + 1 ..], ETH_REGISTRY, 1000);
}

/// A label minted in `registry`, attributed to `parent_name` — one primary row.
fn seedName(
    allocator: std.mem.Allocator,
    database: *Database,
    label: []const u8,
    parent_name: []const u8,
    registry: Address,
    created_block: u64,
) !Hash {
    const full = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ label, parent_name });
    defer allocator.free(full);
    const nh = try lib.namehash(allocator, full);
    const parent_nh = try lib.namehash(allocator, parent_name);
    const lh = try lib.labelhash(allocator, label);
    const cid = std.mem.readInt(u256, &lh.bytes, .big) & ~@as(u256, 0xffffffff);
    try database.insertName(.{
        .protocol = .v2,
        .name = full,
        .namehash = nh,
        .label = label,
        .label_hash = lh,
        .parent_name = parent_name,
        .parent_namehash = parent_nh,
        .registry = registry,
        .owner = OWNER,
        .registrant = OWNER,
        .resolver = Address.zero,
        .token_id = cid,
        .canonical_id = cid,
        .token_version = 0,
        .expiry = 0,
        .registry_locked = false,
        .migrated = false,
        .created_block = created_block,
        .created_at = 1_700_000_100,
        .registered_at = 1_700_000_100,
        .updated_block = created_block,
        .updated_at = 1_700_000_100,
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    });
    return nh;
}

/// Record a (registry -> parent) link in the append-only history AND in the live
/// pointer mirror — i.e. what one SubregistryUpdated does.
fn link(
    database: *Database,
    parent_name: []const u8,
    parent_namehash: Hash,
    parent_label: []const u8,
    registry: Address,
    block: u64,
) !void {
    try database.insertRegistry(.{
        .address = registry,
        .protocol = .v2,
        .name = parent_name,
        .namehash = parent_namehash,
        .parent_registry = ETH_REGISTRY,
        .created_block = block,
        .created_at = @intCast(1_700_000_000 + block),
    });
    _ = try database.upsertRegistryEntrySubregistry(
        .v2,
        ETH_REGISTRY,
        try canonicalOf(parent_label),
        registry,
        block,
        @intCast(1_700_000_000 + block),
    );
}

/// Clear a parent's pointer: the entry survives holding the zero address, exactly as
/// `setSubregistry(label, 0)` leaves it on-chain.
fn unlink(database: *Database, parent_label: []const u8, block: u64) !void {
    _ = try database.upsertRegistryEntrySubregistry(
        .v2,
        ETH_REGISTRY,
        try canonicalOf(parent_label),
        Address.zero,
        block,
        @intCast(1_700_000_000 + block),
    );
}

/// The koala/kangaroo fixture: two parents, one shared registry, three labels the
/// handler attributed to koala.eth.
fn seedSharedFixture(allocator: std.mem.Allocator, database: *Database) !struct { koala: Hash, kangaroo: Hash } {
    const koala = try seedParent(allocator, database, "koala.eth");
    const kangaroo = try seedParent(allocator, database, "kangaroo.eth");
    try link(database, "koala.eth", koala, "koala", SHARED, 1100);
    try link(database, "kangaroo.eth", kangaroo, "kangaroo", SHARED, 1200);
    _ = try seedName(allocator, database, "grey", "koala.eth", SHARED, 1110);
    _ = try seedName(allocator, database, "blue", "koala.eth", SHARED, 1120);
    _ = try seedName(allocator, database, "purple", "koala.eth", SHARED, 1300);
    return .{ .koala = koala, .kangaroo = kangaroo };
}

fn countNames(database: *Database, where: []const u8) !i64 {
    const sql = try std.fmt.allocPrint(testing.allocator, "SELECT COUNT(*) FROM names WHERE {s}", .{where});
    defer testing.allocator.free(sql);
    var q = try lib.storage.Query.init(database, sql);
    defer q.deinit();
    if (try q.step()) return q.getInt64(0);
    return -1;
}

const PassResult = struct { written: u64, deleted: u64, skipped: u64 };

/// One full derivation pass through the real storage code — the same sequence
/// `indexer/v2/alias_sync.zig` runs, minus the Indexer (whose only extra effect is
/// the insertName chokepoint's is_normalized / is_reachable stamps). Unbounded: runs
/// to the fixpoint, which is what these tests assert about.
fn runPass(allocator: std.mem.Allocator, database: *Database) !PassResult {
    return runPassFor(allocator, database, SHARED);
}

/// One full derivation pass over `registry` through the real storage code — the same
/// sequence `indexer/v2/alias_sync.zig` runs, minus the Indexer (whose only extra effect
/// is the insertName chokepoint's is_normalized / is_reachable stamps). Unbounded: runs
/// to the fixpoint, which is what these tests assert about.
fn runPassFor(allocator: std.mem.Allocator, database: *Database, registry: Address) !PassResult {
    return runPassAt(allocator, database, registry, 1_800_000_000);
}

/// `runPassFor` with an explicit chain time for the parent-expiry test.
fn runPassAt(allocator: std.mem.Allocator, database: *Database, registry: Address, now: i64) !PassResult {
    var out = PassResult{ .written = 0, .deleted = 0, .skipped = 0 };
    out.deleted = try name_aliases.deleteStaleAliasesScoped(database, .v2, registry, null, now);

    var canonical_buf: [66]u8 = undefined;
    var parent_buf: [66]u8 = undefined;
    var canonical_len: usize = 0;
    var cursor: name_aliases.AliasPlanCursor = .{};
    var pages: usize = 0;
    while (pages < 64) : (pages += 1) {
        const keys = try name_aliases.aliasPlanBatch(database, allocator, .v2, registry, null, now, cursor, 500);
        defer name_aliases.freeAliasPlan(allocator, keys);
        if (keys.len == 0) break;
        var advanced = false;
        for (keys) |key| {
            if (try name_aliases.buildAliasRow(database, allocator, .v2, key)) |built| {
                var row = built;
                defer row.deinit(allocator);
                try database.insertName(row);
                out.written += 1;
            } else {
                out.skipped += 1;
            }
            canonical_len = @min(key.canonical_id.len, canonical_buf.len);
            @memcpy(canonical_buf[0..canonical_len], key.canonical_id[0..canonical_len]);
            _ = key.parent_namehash.toHexBuf(&parent_buf);
            advanced = true;
        }
        if (advanced) cursor = .{ .canonical_id = canonical_buf[0..canonical_len], .parent_namehash = &parent_buf };
        if (keys.len < 500) break;
    }
    return out;
}

/// Rows the definition still owes — zero means the fixpoint is reached.
fn planSize(allocator: std.mem.Allocator, database: *Database) !usize {
    const keys = try name_aliases.aliasPlanBatch(database, allocator, .v2, SHARED, null, 1_800_000_000, .{}, 500);
    defer name_aliases.freeAliasPlan(allocator, keys);
    return keys.len;
}

// ============================================================================
// The reported bug
// ============================================================================

test "the missing FQDN of every label appears under every other live parent" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    _ = try seedSharedFixture(allocator, database);

    const pass = try runPass(allocator, database);
    try testing.expectEqual(@as(u64, 3), pass.written);
    try testing.expectEqual(@as(u64, 0), pass.skipped);

    // The reported symptom: `purple` was created from koala's UI and has to exist
    // under kangaroo too.
    try testing.expectEqual(@as(i64, 1), try countNames(database, "name = 'purple.kangaroo.eth' AND is_alias = 1"));
    // 3 labels x 2 parents, all live on-chain.
    try testing.expectEqual(@as(i64, 6), try countNames(database, "registry = lower('" ++ SHARED_HEX ++ "')"));
    try testing.expectEqual(@as(i64, 3), try countNames(database, "parent_name = 'koala.eth'"));
    try testing.expectEqual(@as(i64, 3), try countNames(database, "parent_name = 'kangaroo.eth'"));
    // Exactly one primary per label — the invariant every mutation lookup rests on.
    try testing.expectEqual(@as(i64, 3), try countNames(database, "registry = lower('" ++ SHARED_HEX ++ "') AND is_alias = 0"));
}

test "derived names carry their own parent and a namehash matching their name" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    const parents = try seedSharedFixture(allocator, database);
    _ = try runPass(allocator, database);

    var row = (try database.getNameByNamehash(try lib.namehash(allocator, "purple.kangaroo.eth"))).?;
    defer row.deinit(allocator);
    try testing.expect(row.is_alias);
    try testing.expectEqualStrings("kangaroo.eth", row.parent_name.?);
    try testing.expect(row.parent_namehash.eql(parents.kangaroo));
    try testing.expectEqualStrings("purple", row.label.?);
    // Copied verbatim from the primary: same registry, owner and token identity.
    try testing.expect(row.registry.eql(SHARED));
    try testing.expect(row.owner.eql(OWNER));
    try testing.expectEqual(try canonicalOf("purple"), row.canonical_id);
}

// ============================================================================
// Live truth vs append-only history
// ============================================================================

test "a parent that repointed away is dropped, though history still lists it" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    _ = try seedSharedFixture(allocator, database);

    // koala.eth repoints its own entry elsewhere. Its `registries` row for SHARED
    // survives (history is append-only and never pruned) — exactly the stale linker
    // the old history lookup could elect.
    _ = try database.upsertRegistryEntrySubregistry(.v2, ETH_REGISTRY, try canonicalOf("koala"), OTHER, 1500, 1_700_001_500);

    const live = try name_aliases.getLiveParentNames(database, allocator, .v2, SHARED, 1_800_000_000);
    defer name_aliases.freeLiveParents(allocator, live);
    try testing.expectEqual(@as(usize, 1), live.len);
    try testing.expectEqualStrings("kangaroo.eth", live[0].name);
}

test "getLiveParentNames returns every live parent, oldest link first" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    _ = try seedSharedFixture(allocator, database);

    const live = try name_aliases.getLiveParentNames(database, allocator, .v2, SHARED, 1_800_000_000);
    defer name_aliases.freeLiveParents(allocator, live);
    try testing.expectEqual(@as(usize, 2), live.len);
    try testing.expectEqualStrings("koala.eth", live[0].name);
    try testing.expectEqualStrings("kangaroo.eth", live[1].name);
}

test "getLiveParentNamesAsOf ignores a parent that links after the given block" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    _ = try seedSharedFixture(allocator, database);

    // kangaroo.eth linked at 1200, so a label registered at 1150 must not be
    // attributable to it even though the live mirror — built ahead by the phase-1
    // sweep — already knows about the link. Otherwise the stored row would depend on
    // where the batch boundary happened to fall.
    const at_1150 = try name_aliases.getLiveParentNamesAsOf(database, allocator, .v2, SHARED, 1150, 1_800_000_000);
    defer name_aliases.freeLiveParents(allocator, at_1150);
    try testing.expectEqual(@as(usize, 1), at_1150.len);
    try testing.expectEqualStrings("koala.eth", at_1150[0].name);

    const at_1200 = try name_aliases.getLiveParentNamesAsOf(database, allocator, .v2, SHARED, 1200, 1_800_000_000);
    defer name_aliases.freeLiveParents(allocator, at_1200);
    try testing.expectEqual(@as(usize, 2), at_1200.len);
}

test "the parent name comes from its names row, not the frozen registries row" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    const parents = try seedSharedFixture(allocator, database);

    // `registries.name` is frozen at link time and can hold an unhealed placeholder.
    // The live spelling lives on the parent's own names row.
    try database.exec("UPDATE registries SET name = '[0xdeadbeef].eth' WHERE name = 'kangaroo.eth'");
    const live = try name_aliases.getLiveParentNames(database, allocator, .v2, SHARED, 1_800_000_000);
    defer name_aliases.freeLiveParents(allocator, live);
    var saw = false;
    for (live) |p| {
        if (p.namehash.eql(parents.kangaroo)) {
            try testing.expectEqualStrings("kangaroo.eth", p.name);
            saw = true;
        }
    }
    try testing.expect(saw);
}

test "an expired parent owes no derived names, and a renewal makes it owe them again" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    _ = try seedSharedFixture(allocator, database);

    const T: i64 = 1_700_000_000;
    // Both parents live: the three labels each owe a name under kangaroo.
    {
        const live = try name_aliases.getLiveParentNames(database, allocator, .v2, SHARED, T);
        defer name_aliases.freeLiveParents(allocator, live);
        try testing.expectEqual(@as(usize, 2), live.len);
    }

    // kangaroo.eth expires. On-chain its getSubregistry returns zero, so it resolves nothing in the
    // shared registry — it therefore owes no derived names either, and the ones it already has must
    // go. No pointer event is involved; only time passed.
    try database.exec("UPDATE names SET expiry = 1699999999 WHERE name = 'kangaroo.eth'");
    {
        const live = try name_aliases.getLiveParentNames(database, allocator, .v2, SHARED, T);
        defer name_aliases.freeLiveParents(allocator, live);
        try testing.expectEqual(@as(usize, 1), live.len);
        try testing.expectEqualStrings("koala.eth", live[0].name);
    }
    const expired_pass = try runPassAt(allocator, database, SHARED, T);
    try testing.expectEqual(@as(u64, 0), expired_pass.written);
    try testing.expectEqual(@as(i64, 0), try countNames(database, "is_alias = 1"));

    // Renewed: it owes them again.
    try database.exec("UPDATE names SET expiry = 1800000000 WHERE name = 'kangaroo.eth'");
    const renewed_pass = try runPassAt(allocator, database, SHARED, T);
    try testing.expectEqual(@as(u64, 3), renewed_pass.written);
    try testing.expectEqual(@as(i64, 1), try countNames(database, "name = 'purple.kangaroo.eth' AND is_alias = 1"));

    // And evaluating the SAME state at a time before the expiry gives the live answer — the rule is
    // a function of the evaluation time, never of a wall clock.
    try database.exec("UPDATE names SET expiry = 1699999999 WHERE name = 'kangaroo.eth'");
    const before = try name_aliases.getLiveParentNames(database, allocator, .v2, SHARED, 1699999998);
    defer name_aliases.freeLiveParents(allocator, before);
    try testing.expectEqual(@as(usize, 2), before.len);
}

test "an unreachable parent mints nothing" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    _ = try seedSharedFixture(allocator, database);

    _ = try lib.storage.registry_entries.setRegistriesReachability(
        database,
        .v2,
        &[_]Address{ETH_REGISTRY},
        false,
        1600,
        1_700_001_600,
    );

    // Both parents live in the eth registry, so both just became unreachable: a
    // derived name is never minted under a parent that does not itself resolve.
    const live = try name_aliases.getLiveParentNames(database, allocator, .v2, SHARED, 1_800_000_000);
    defer name_aliases.freeLiveParents(allocator, live);
    try testing.expectEqual(@as(usize, 0), live.len);
    const pass = try runPass(allocator, database);
    try testing.expectEqual(@as(u64, 0), pass.written);
}

// ============================================================================
// Fixpoint: idempotence, steady state, convergence
// ============================================================================

test "the pass is idempotent and reaches a steady state that costs nothing" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    _ = try seedSharedFixture(allocator, database);

    const first = try runPass(allocator, database);
    try testing.expectEqual(@as(u64, 3), first.written);

    // Second pass: the plan is empty, so a steady state is one statement returning
    // zero rows — the property that makes the pass safe to run every batch.
    try testing.expectEqual(@as(usize, 0), try planSize(allocator, database));
    const second = try runPass(allocator, database);
    try testing.expectEqual(@as(u64, 0), second.written);
    try testing.expectEqual(@as(u64, 0), second.deleted);

    // And the rows did not multiply.
    try testing.expectEqual(@as(i64, 3), try countNames(database, "is_alias = 1"));
    try testing.expectEqual(@as(i64, 6), try countNames(database, "registry = lower('" ++ SHARED_HEX ++ "')"));
}

test "the plan order is total, so paging cannot repeat or skip a row" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    _ = try seedSharedFixture(allocator, database);

    const all = try name_aliases.aliasPlanBatch(database, allocator, .v2, SHARED, null, 1_800_000_000, .{}, 500);
    defer name_aliases.freeAliasPlan(allocator, all);
    try testing.expectEqual(@as(usize, 3), all.len);

    // Page size 1 through the whole plan: the sequence must match the single-page read
    // exactly, with no duplicates and no gaps. This is what lets the production loop
    // persist a cursor and resume without rescanning.
    var canonical_buf: [66]u8 = undefined;
    var parent_buf: [66]u8 = undefined;
    var cursor: name_aliases.AliasPlanCursor = .{};
    var seen: usize = 0;
    while (true) {
        const one = try name_aliases.aliasPlanBatch(database, allocator, .v2, SHARED, null, 1_800_000_000, cursor, 1);
        defer name_aliases.freeAliasPlan(allocator, one);
        if (one.len == 0) break;
        try testing.expectEqual(@as(usize, 1), one.len);
        try testing.expect(seen < all.len);
        try testing.expectEqualStrings(all[seen].canonical_id, one[0].canonical_id);
        try testing.expect(one[0].parent_namehash.eql(all[seen].parent_namehash));
        const n = @min(one[0].canonical_id.len, canonical_buf.len);
        @memcpy(canonical_buf[0..n], one[0].canonical_id[0..n]);
        _ = one[0].parent_namehash.toHexBuf(&parent_buf);
        cursor = .{ .canonical_id = canonical_buf[0..n], .parent_namehash = &parent_buf };
        seen += 1;
    }
    try testing.expectEqual(all.len, seen);
}

test "a bounded pass converges over several batches to the same fixpoint" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    _ = try seedSharedFixture(allocator, database);

    // Mimic the live budget: one row per pass. The end state must equal what an
    // unbounded pass produces — the budget changes the path, never the destination.
    var written: usize = 0;
    while (written < 10) {
        const keys = try name_aliases.aliasPlanBatch(database, allocator, .v2, SHARED, null, 1_800_000_000, .{}, 1);
        defer name_aliases.freeAliasPlan(allocator, keys);
        if (keys.len == 0) break;
        var row = (try name_aliases.buildAliasRow(database, allocator, .v2, keys[0])).?;
        defer row.deinit(allocator);
        try database.insertName(row);
        written += 1;
    }
    try testing.expectEqual(@as(usize, 3), written);
    try testing.expectEqual(@as(usize, 0), try planSize(allocator, database));
    try testing.expectEqual(@as(i64, 3), try countNames(database, "is_alias = 1"));
    try testing.expectEqual(@as(i64, 1), try countNames(database, "name = 'purple.kangaroo.eth'"));
}

test "the plan is empty once a registry has a single live parent" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    _ = try seedSharedFixture(allocator, database);
    try unlink(database, "kangaroo", 1500);

    const live = try name_aliases.getLiveParentNames(database, allocator, .v2, SHARED, 1_800_000_000);
    defer name_aliases.freeLiveParents(allocator, live);
    try testing.expectEqual(@as(usize, 1), live.len);
    try testing.expectEqual(@as(usize, 0), try planSize(allocator, database));
}

// ============================================================================
// Cleanup — every route by which a derived name stops being owed
// ============================================================================

test "a parent that repoints away loses its derived names" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    _ = try seedSharedFixture(allocator, database);
    _ = try runPass(allocator, database);
    try testing.expectEqual(@as(i64, 3), try countNames(database, "is_alias = 1"));

    try unlink(database, "kangaroo", 1500);
    const pass = try runPass(allocator, database);
    try testing.expectEqual(@as(u64, 3), pass.deleted);
    try testing.expectEqual(@as(i64, 0), try countNames(database, "is_alias = 1"));
    // koala's primaries are untouched — they own the history.
    try testing.expectEqual(@as(i64, 3), try countNames(database, "parent_name = 'koala.eth'"));
}

test "cleanup still reaches a registry after it drops below two live parents" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    _ = try seedSharedFixture(allocator, database);
    _ = try runPass(allocator, database);

    // The registry is no longer multi-parent, so an implementation that enumerated
    // candidates by "more than one live pointer" would never visit it again and would
    // strand kangaroo's three derived names as permanent ghosts. The set-based delete
    // has no candidate list to fall out of.
    try unlink(database, "kangaroo", 1500);
    try testing.expectEqual(@as(u64, 3), try name_aliases.deleteStaleAliases(database, .v2, 1_800_000_000));
    try testing.expectEqual(@as(i64, 0), try countNames(database, "is_alias = 1"));
}

test "an orphaned registry's derived names go even with no live parent left" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    _ = try seedSharedFixture(allocator, database);
    _ = try runPass(allocator, database);

    // Both parents un-point: the registry is orphaned and its primaries go unreachable
    // by the ordinary registry-level rule. The derived names must not survive as the
    // only visible copies of names that no longer resolve.
    try unlink(database, "koala", 1600);
    try unlink(database, "kangaroo", 1600);
    _ = try lib.storage.registry_entries.setRegistriesReachability(database, .v2, &[_]Address{SHARED}, false, 1600, 1_700_001_600);

    try testing.expectEqual(@as(u64, 3), try name_aliases.deleteStaleAliases(database, .v2, 1_800_000_000));
    try testing.expectEqual(@as(i64, 0), try countNames(database, "is_alias = 1"));
    try testing.expectEqual(@as(i64, 3), try countNames(database, "parent_name = 'koala.eth' AND is_reachable = 0"));
}

test "a label that no longer resolves loses its derived names and gains none" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    _ = try seedSharedFixture(allocator, database);
    _ = try runPass(allocator, database);

    // LabelUnregistered soft-deletes one primary. The registry stays reachable through
    // both parents, so registry-level reachability does not change — only THIS label's
    // derived names must go.
    const blue_nh = try lib.namehash(allocator, "blue.koala.eth");
    try lib.storage.registry_entries.markNameUnreachableByNamehash(database, .v2, blue_nh, 1700, 1_700_001_700);

    const pass = try runPass(allocator, database);
    try testing.expectEqual(@as(u64, 1), pass.deleted);
    try testing.expectEqual(@as(u64, 0), pass.written);
    try testing.expectEqual(@as(i64, 0), try countNames(database, "name = 'blue.kangaroo.eth'"));
    try testing.expectEqual(@as(i64, 2), try countNames(database, "is_alias = 1"));
    // The soft-deleted primary itself is untouched.
    try testing.expectEqual(@as(i64, 1), try countNames(database, "name = 'blue.koala.eth' AND is_reachable = 0"));
    // And it is not re-minted on the next pass.
    try testing.expectEqual(@as(usize, 0), try planSize(allocator, database));
}

test "deleting a primary takes its derived names with it" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    _ = try seedSharedFixture(allocator, database);
    _ = try runPass(allocator, database);

    // NameBurned hard-deletes the row; its derived names would otherwise be the only
    // remaining copies of a name that no longer exists.
    try database.deleteNameByNamehash(try lib.namehash(allocator, "grey.koala.eth"));
    const pass = try runPass(allocator, database);
    try testing.expectEqual(@as(u64, 1), pass.deleted);
    try testing.expectEqual(@as(i64, 0), try countNames(database, "name LIKE 'grey.%'"));
    try testing.expectEqual(@as(i64, 2), try countNames(database, "is_alias = 1"));
}

test "a repoint from one shared registry to another moves the derived names" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    _ = try seedSharedFixture(allocator, database);
    _ = try runPass(allocator, database);
    try testing.expectEqual(@as(i64, 1), try countNames(database, "name = 'purple.kangaroo.eth'"));

    // kangaroo moves to a second shared registry that koala also refers to, holding one
    // label of its own. One pass must both drop the old FQDNs and mint the new one.
    const koala_nh = try lib.namehash(allocator, "koala.eth");
    try link(database, "koala.eth", koala_nh, "koala", OTHER, 1700);
    _ = try seedName(allocator, database, "amber", "koala.eth", OTHER, 1710);
    const kangaroo_nh = try lib.namehash(allocator, "kangaroo.eth");
    try link(database, "kangaroo.eth", kangaroo_nh, "kangaroo", OTHER, 1720);
    _ = try database.upsertRegistryEntrySubregistry(.v2, ETH_REGISTRY, try canonicalOf("kangaroo"), OTHER, 1720, 1_700_001_720);

    // Two work items now: SHARED loses three derived names, OTHER gains one. The queue
    // is keyed by registry precisely so each is bounded by its own label set.
    const shared_pass = try runPassFor(allocator, database, SHARED);
    const other_pass = try runPassFor(allocator, database, OTHER);
    try testing.expectEqual(@as(u64, 3), shared_pass.deleted);
    try testing.expectEqual(@as(u64, 0), shared_pass.written);
    try testing.expectEqual(@as(u64, 1), other_pass.written);
    try testing.expectEqual(@as(i64, 0), try countNames(database, "name = 'purple.kangaroo.eth'"));
    try testing.expectEqual(@as(i64, 1), try countNames(database, "name = 'amber.kangaroo.eth' AND is_alias = 1"));
    try testing.expectEqual(@as(usize, 0), try planSize(allocator, database));
}

test "deleteStaleAliases never touches a primary row" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    _ = try seedSharedFixture(allocator, database);
    _ = try runPass(allocator, database);
    const before = try countNames(database, "is_alias = 0");

    // Tear the world down in every direction at once: no live edges at all.
    try unlink(database, "koala", 1800);
    try unlink(database, "kangaroo", 1800);
    _ = try name_aliases.deleteStaleAliases(database, .v2, 1_800_000_000);
    _ = try name_aliases.deleteStaleAliases(database, .v2, 1_800_000_000);

    try testing.expectEqual(@as(i64, 0), try countNames(database, "is_alias = 1"));
    try testing.expectEqual(before, try countNames(database, "is_alias = 0"));
}

// ============================================================================
// Guards: a primary row must never become deletable
// ============================================================================

test "a derived name colliding with an existing primary is declined, not written" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    _ = try seedSharedFixture(allocator, database);

    // The shared registry also holds `zed`, attributed to kangaroo — so the definition
    // owes `zed.koala.eth`.
    _ = try seedName(allocator, database, "zed", "kangaroo.eth", SHARED, 1250);

    // But `zed.koala.eth` ALREADY exists as a primary sourced from a different registry:
    // koala.eth used to point at OTHER and minted `zed` there. That row owns the
    // namehash, and with it any events/registrations referencing that node. (Note the
    // two rows are distinct nodes — `zed.kangaroo.eth` and `zed.koala.eth` — which is
    // why seeding both is possible at all.)
    _ = try seedName(allocator, database, "zed", "koala.eth", OTHER, 1050);
    try testing.expectEqual(@as(i64, 1), try countNames(database, "name = 'zed.koala.eth' AND is_alias = 0 AND registry = lower('" ++ OTHER_HEX ++ "')"));

    const pass = try runPass(allocator, database);
    // grey, blue and purple gain their kangaroo names; zed's koala name is declined
    // because that node already belongs to a primary.
    try testing.expectEqual(@as(u64, 3), pass.written);
    try testing.expectEqual(@as(u64, 1), pass.skipped);

    // The pre-existing primary is untouched — still is_alias = 0, still sourced from
    // OTHER, so no delete pass can ever remove it.
    try testing.expectEqual(@as(i64, 1), try countNames(database, "name = 'zed.koala.eth' AND is_alias = 0 AND registry = lower('" ++ OTHER_HEX ++ "')"));
    _ = try name_aliases.deleteStaleAliases(database, .v2, 1_800_000_000);
    try testing.expectEqual(@as(i64, 1), try countNames(database, "name = 'zed.koala.eth'"));
}

test "an unbuildable plan row does not starve the rows behind it" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    _ = try seedSharedFixture(allocator, database);

    // Make the FIRST plan row unbuildable by parking a primary on its namehash. With a
    // cursor that only advanced on success, this row would head every page forever and
    // nothing behind it would ever be written.
    const all = try name_aliases.aliasPlanBatch(database, allocator, .v2, SHARED, null, 1_800_000_000, .{}, 500);
    defer name_aliases.freeAliasPlan(allocator, all);
    try testing.expectEqual(@as(usize, 3), all.len);
    var blocker = (try name_aliases.buildAliasRow(database, allocator, .v2, all[0])).?;
    defer blocker.deinit(allocator);
    blocker.is_alias = false;
    blocker.registry = OTHER;
    try database.insertName(blocker);

    const pass = try runPass(allocator, database);
    try testing.expectEqual(@as(u64, 1), pass.skipped);
    try testing.expectEqual(@as(u64, 2), pass.written);
    try testing.expectEqual(@as(i64, 2), try countNames(database, "is_alias = 1"));
}

test "an alias is never used as a parent, so the derivation cannot recurse" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    _ = try seedSharedFixture(allocator, database);
    _ = try runPass(allocator, database);

    // Point one derived name's own entry at the shared registry — the self-loop shape
    // the live registry graph actually contains. Without the `is_alias = 0` guard on
    // the parent join, every pass would add another level of nesting forever.
    const grey_kangaroo = try lib.namehash(allocator, "grey.kangaroo.eth");
    try database.insertRegistry(.{
        .address = SHARED,
        .protocol = .v2,
        .name = "grey.kangaroo.eth",
        .namehash = grey_kangaroo,
        .parent_registry = SHARED,
        .created_block = 1600,
        .created_at = 1_700_001_600,
    });
    _ = try database.upsertRegistryEntrySubregistry(.v2, SHARED, try canonicalOf("grey"), SHARED, 1600, 1_700_001_600);

    const live = try name_aliases.getLiveParentNames(database, allocator, .v2, SHARED, 1_800_000_000);
    defer name_aliases.freeLiveParents(allocator, live);
    for (live) |p| try testing.expect(!std.mem.eql(u8, p.name, "grey.kangaroo.eth"));

    // Still at the fixpoint, and no nested name was minted.
    try testing.expectEqual(@as(usize, 0), try planSize(allocator, database));
    _ = try runPass(allocator, database);
    try testing.expectEqual(@as(i64, 0), try countNames(database, "name LIKE '%.grey.kangaroo.eth'"));
    try testing.expectEqual(@as(i64, 3), try countNames(database, "is_alias = 1"));
}

test "a real registration overwrites a derived name at the same node" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    _ = try seedSharedFixture(allocator, database);
    _ = try runPass(allocator, database);
    try testing.expectEqual(@as(i64, 1), try countNames(database, "name = 'purple.kangaroo.eth' AND is_alias = 1"));

    // A handler writes a genuine name at a node currently held by a derived row: the
    // real registration must win, and the row must stop being deletable as an alias.
    _ = try seedName(allocator, database, "purple", "kangaroo.eth", OTHER, 1900);
    try testing.expectEqual(@as(i64, 1), try countNames(database, "name = 'purple.kangaroo.eth' AND is_alias = 0"));
    _ = try name_aliases.deleteStaleAliases(database, .v2, 1_800_000_000);
    try testing.expectEqual(@as(i64, 1), try countNames(database, "name = 'purple.kangaroo.eth'"));
}

// ============================================================================
// Scaling and reorg-capture properties the production loop depends on
// ============================================================================

test "many live parents need no per-parent binds and hit no cap" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    // 40 parents on one shared registry — past any plausible per-statement bind cap.
    // The earlier per-registry form bound one parameter per parent and had to skip
    // cleanup above 24, which is a wrong answer rather than a slow one.
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        const label = try std.fmt.bufPrint(&buf, "p{d}", .{i});
        const name = try std.fmt.allocPrint(allocator, "{s}.eth", .{label});
        defer allocator.free(name);
        const nh = try seedParent(allocator, database, name);
        try link(database, name, nh, label, SHARED, 1000 + i);
    }
    _ = try seedName(allocator, database, "only", "p0.eth", SHARED, 1200);

    const live = try name_aliases.getLiveParentNames(database, allocator, .v2, SHARED, 1_800_000_000);
    defer name_aliases.freeLiveParents(allocator, live);
    try testing.expectEqual(@as(usize, 40), live.len);

    const pass = try runPass(allocator, database);
    try testing.expectEqual(@as(u64, 39), pass.written);
    try testing.expectEqual(@as(usize, 0), try planSize(allocator, database));

    // And cleanup scales the same way: drop every parent but one.
    i = 1;
    while (i < 40) : (i += 1) {
        const label = try std.fmt.bufPrint(&buf, "p{d}", .{i});
        try unlink(database, label, 2000 + i);
    }
    try testing.expectEqual(@as(u64, 39), try name_aliases.deleteStaleAliases(database, .v2, 1_800_000_000));
    try testing.expectEqual(@as(i64, 0), try countNames(database, "is_alias = 1"));
}

test "the stale delete prepares and captures under an armed reorg cursor" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    _ = try seedSharedFixture(allocator, database);
    _ = try runPass(allocator, database);

    // With the cursor armed, the delete's predicate first runs inside the undo
    // capture's `... FROM "names" t WHERE (<predicate>)` wrapper — where a
    // `names.`-qualified reference has no FROM entry and the statement fails to
    // prepare. Without the cursor the capture is skipped entirely and a broken
    // predicate would never run, so this test is what catches that class.
    try lib.storage.reorg_undo.setCursor(database, .v2, 1800);

    try unlink(database, "kangaroo", 1800);
    try testing.expectEqual(@as(u64, 3), try name_aliases.deleteStaleAliases(database, .v2, 1_800_000_000));
    try testing.expectEqual(@as(i64, 0), try countNames(database, "is_alias = 1"));

    // The primary-missing clause too: re-mint, then drop a primary.
    _ = try database.upsertRegistryEntrySubregistry(.v2, ETH_REGISTRY, try canonicalOf("kangaroo"), SHARED, 1810, 1_700_001_810);
    _ = try runPass(allocator, database);
    try database.deleteNameByNamehash(try lib.namehash(allocator, "purple.koala.eth"));
    try testing.expectEqual(@as(u64, 1), try name_aliases.deleteStaleAliases(database, .v2, 1_800_000_000));
    try testing.expectEqual(@as(i64, 0), try countNames(database, "name LIKE 'purple.%'"));
}

test "a single-parent deployment does no work at all" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    // The ordinary case: every registry has exactly one referring parent. Both halves
    // of the pass must be no-ops, which is what makes running it every batch free.
    const solo = try seedParent(allocator, database, "solo.eth");
    try link(database, "solo.eth", solo, "solo", OTHER, 1100);
    _ = try seedName(allocator, database, "a", "solo.eth", OTHER, 1110);
    _ = try seedName(allocator, database, "b", "solo.eth", OTHER, 1120);

    try testing.expectEqual(@as(usize, 0), try planSize(allocator, database));
    const pass = try runPass(allocator, database);
    try testing.expectEqual(@as(u64, 0), pass.written);
    try testing.expectEqual(@as(u64, 0), pass.deleted);
    try testing.expectEqual(@as(i64, 0), try countNames(database, "is_alias = 1"));
}

// ============================================================================
// The change queue: scheduling only, never a source of truth
// ============================================================================

/// A fingerprint of every derived row, so two differently-scheduled runs can be compared
/// for exact equality rather than by counting.
fn aliasFingerprint(allocator: std.mem.Allocator, database: *Database) ![]u8 {
    var q = try lib.storage.Query.init(database,
        \\SELECT name, namehash, parent_name, parent_namehash, registry, canonical_id, owner,
        \\       created_block, created_at, updated_block, updated_at, is_reachable, is_normalized
        \\FROM names WHERE protocol = 'v2' AND is_alias = 1 ORDER BY namehash
    );
    defer q.deinit();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    while (try q.step()) {
        var col: usize = 0;
        while (col < 13) : (col += 1) {
            if (q.getTextSlice(col)) |t| {
                try out.appendSlice(allocator, t);
            } else {
                try out.appendSlice(allocator, "~");
            }
            try out.append(allocator, '|');
        }
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

test "the queue records work and clears only when a registry has converged" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    _ = try seedSharedFixture(allocator, database);

    // Nothing queued yet — a steady state must not look at `names` at all.
    {
        const empty = try name_aliases.takeAliasWork(database, allocator, .v2, 16);
        defer name_aliases.freeAliasWork(allocator, empty);
        try testing.expectEqual(@as(usize, 0), empty.len);
    }

    // The sweep enqueues every candidate: the one multi-parent registry.
    const enqueued = try name_aliases.enqueueAllAliasCandidates(database, .v2, 1400);
    try testing.expect(enqueued >= 1);
    const work = try name_aliases.takeAliasWork(database, allocator, .v2, 16);
    defer name_aliases.freeAliasWork(allocator, work);
    try testing.expectEqual(@as(usize, 1), work.len);
    try testing.expect(work[0].registry.eql(SHARED));
    try testing.expect(work[0].cursor.canonical_id == null);
    try testing.expect(!work[0].restart);

    // Converged: the registry leaves the queue.
    _ = try runPass(allocator, database);
    try testing.expect(try name_aliases.completeAliasWork(database, .v2, SHARED, null, false));
    const after = try name_aliases.takeAliasWork(database, allocator, .v2, 16);
    defer name_aliases.freeAliasWork(allocator, after);
    try testing.expectEqual(@as(usize, 0), after.len);
}

test "an edge re-enqueue rewinds, so a change behind the cursor cannot be missed" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    _ = try seedSharedFixture(allocator, database);

    try name_aliases.enqueueAliasWork(database, .v2, SHARED, 1400);
    try name_aliases.saveAliasWorkCursorHex(database, .v2, SHARED, "0xabc", "0xdef");

    // A new parent edge means EVERY label owes a row under it, including labels that sort
    // behind the cursor. So an edge enqueue rewinds — the pass must not resume mid-way and
    // declare itself finished — and sets `restart`, so a sweep already in flight is made to
    // run once more rather than being cut short.
    try name_aliases.enqueueAliasWork(database, .v2, SHARED, 1500);
    const work = try name_aliases.takeAliasWork(database, allocator, .v2, 16);
    defer name_aliases.freeAliasWork(allocator, work);
    try testing.expectEqual(@as(usize, 1), work.len);
    try testing.expect(work[0].restart);
    try testing.expect(work[0].cursor.canonical_id == null);
    try testing.expect(work[0].label == null);

    // Completing a restart-flagged sweep rewinds rather than converging, so exactly one
    // more sweep runs. That is what stops a steady stream of changes from starving it.
    try testing.expect(!try name_aliases.completeAliasWork(database, .v2, SHARED, null, true));
    const again = try name_aliases.takeAliasWork(database, allocator, .v2, 16);
    defer name_aliases.freeAliasWork(allocator, again);
    try testing.expectEqual(@as(usize, 1), again.len);
    try testing.expect(!again[0].restart);
    try testing.expect(try name_aliases.completeAliasWork(database, .v2, SHARED, null, false));
}

test "the sweep re-asserts candidates without rewinding a converged registry" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    _ = try seedSharedFixture(allocator, database);

    // Converge, then sweep. The sweep must leave the converged row alone: re-deriving a
    // large registry from the start costs a full pass, which is exactly the cost the
    // persisted cursor exists to avoid. So the queue stays empty of pending work.
    _ = try name_aliases.sweepAliasCandidates(database, .v2, 1400);
    _ = try runPass(allocator, database);
    _ = try name_aliases.completeAliasWork(database, .v2, SHARED, null, false);

    _ = try name_aliases.sweepAliasCandidates(database, .v2, 1500);
    const pending = try name_aliases.takeAliasWork(database, allocator, .v2, 16);
    defer name_aliases.freeAliasWork(allocator, pending);
    try testing.expectEqual(@as(usize, 0), pending.len);

    // But a real change still reopens it.
    try name_aliases.enqueueAliasWork(database, .v2, SHARED, 1600);
    const reopened = try name_aliases.takeAliasWork(database, allocator, .v2, 16);
    defer name_aliases.freeAliasWork(allocator, reopened);
    try testing.expectEqual(@as(usize, 1), reopened.len);
}

test "a label item derives only that label's rows" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    _ = try seedSharedFixture(allocator, database);

    // What a single registration in a shared registry enqueues. Scoping the item to the
    // label is what makes it an indexed point operation instead of a pass over every label
    // in the registry — the difference measured at 0.9ms vs 12.2s on 200k labels.
    const purple_cid = try canonicalOf("purple");
    try name_aliases.enqueueAliasLabelWork(database, .v2, SHARED, purple_cid, 1400);
    const work = try name_aliases.takeAliasWork(database, allocator, .v2, 16);
    defer name_aliases.freeAliasWork(allocator, work);
    try testing.expectEqual(@as(usize, 1), work.len);
    try testing.expect(work[0].label != null);

    // Planning that item returns only purple's owed row, not grey's or blue's.
    const keys = try name_aliases.aliasPlanBatch(database, allocator, .v2, SHARED, work[0].label, 1_800_000_000, .{}, 500);
    defer name_aliases.freeAliasPlan(allocator, keys);
    try testing.expectEqual(@as(usize, 1), keys.len);
    var row = (try name_aliases.buildAliasRow(database, allocator, .v2, keys[0])).?;
    defer row.deinit(allocator);
    try testing.expectEqualStrings("purple.kangaroo.eth", row.name.?);
    try database.insertName(row);

    // The item leaves the queue; the whole-registry row was never touched.
    try testing.expect(try name_aliases.completeAliasWork(database, .v2, SHARED, work[0].label, false));
    const after = try name_aliases.takeAliasWork(database, allocator, .v2, 16);
    defer name_aliases.freeAliasWork(allocator, after);
    try testing.expectEqual(@as(usize, 0), after.len);
    try testing.expectEqual(@as(i64, 1), try countNames(database, "is_alias = 1"));
}

test "queue-driven and full-sweep runs reach byte-identical derived state" {
    const allocator = testing.allocator;

    // Two databases, same history, two different SCHEDULES: one converges in a single
    // unbounded pass (what --backfill does), the other in one-row steps interleaved with
    // re-enqueues (what a live indexer does across batches). The derived rows must be
    // identical, field for field — that equality is the whole determinism claim, and it is
    // what makes a replayed database comparable against a live one.
    const full = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, full);
    _ = try seedSharedFixture(allocator, full);
    _ = try runPass(allocator, full);
    const fp_full = try aliasFingerprint(allocator, full);
    defer allocator.free(fp_full);

    const incremental = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, incremental);
    _ = try seedSharedFixture(allocator, incremental);
    var canonical_buf: [66]u8 = undefined;
    var parent_buf: [66]u8 = undefined;
    var cursor: name_aliases.AliasPlanCursor = .{};
    var guard: usize = 0;
    while (guard < 20) : (guard += 1) {
        _ = try name_aliases.deleteStaleAliasesScoped(incremental, .v2, SHARED, null, 1_800_000_000);
        const keys = try name_aliases.aliasPlanBatch(incremental, allocator, .v2, SHARED, null, 1_800_000_000, cursor, 1);
        defer name_aliases.freeAliasPlan(allocator, keys);
        if (keys.len == 0) break;
        var row = (try name_aliases.buildAliasRow(incremental, allocator, .v2, keys[0])).?;
        defer row.deinit(allocator);
        try incremental.insertName(row);
        const n = @min(keys[0].canonical_id.len, canonical_buf.len);
        @memcpy(canonical_buf[0..n], keys[0].canonical_id[0..n]);
        _ = keys[0].parent_namehash.toHexBuf(&parent_buf);
        cursor = .{ .canonical_id = canonical_buf[0..n], .parent_namehash = &parent_buf };
    }
    const fp_inc = try aliasFingerprint(allocator, incremental);
    defer allocator.free(fp_inc);

    try testing.expect(fp_full.len > 0);
    try testing.expectEqualStrings(fp_full, fp_inc);

    // And re-running the unbounded pass changes nothing — the fixpoint is stable.
    _ = try runPass(allocator, full);
    const fp_again = try aliasFingerprint(allocator, full);
    defer allocator.free(fp_again);
    try testing.expectEqualStrings(fp_full, fp_again);
}

test "derived rows carry no wall-clock time, so two runs at different times agree" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    _ = try seedSharedFixture(allocator, database);
    _ = try runPass(allocator, database);

    // Every timestamp/block on a derived row is copied from its primary. Nothing is
    // stamped "now", which is what lets a replay at a different block produce the same
    // rows a live run did.
    var q = try lib.storage.Query.init(database,
        \\SELECT a.created_block, a.created_at, a.updated_block, a.updated_at,
        \\       p.created_block, p.created_at, p.updated_block, p.updated_at
        \\FROM names a JOIN names p ON p.protocol = a.protocol AND p.registry = a.registry
        \\   AND p.canonical_id = a.canonical_id AND p.is_alias = 0
        \\WHERE a.protocol = 'v2' AND a.is_alias = 1
    );
    defer q.deinit();
    var rows: usize = 0;
    while (try q.step()) {
        rows += 1;
        try testing.expectEqual(q.getInt64(4), q.getInt64(0));
        try testing.expectEqual(q.getInt64(5), q.getInt64(1));
        try testing.expectEqual(q.getInt64(6), q.getInt64(2));
        try testing.expectEqual(q.getInt64(7), q.getInt64(3));
    }
    try testing.expectEqual(@as(usize, 3), rows);
}
