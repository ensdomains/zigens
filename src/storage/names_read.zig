//! Name read / query operations: single-row + list getters, wrapped-domain and
//! subdomain queries, plus the row-parse helpers and SELECT constants they share.
//! Split out of names.zig; names.zig re-exports the public functions so `names.X` /
//! `db.X` callers are unchanged.

const std = @import("std");
const db_module = @import("database.zig");
const Database = db_module.Database;
const Query = db_module.Query;
const models = @import("../types/models.zig");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;
const names_common = @import("names_common.zig");
const unicode = @import("../utils/unicode.zig");
const parseU256Hex = names_common.parseU256Hex;
const formatU256HexBuf = names_common.formatU256HexBuf;

/// Standard SELECT columns for names table (32 columns)
/// Column order: name(0), label(1), label_hash(2), parent_name(3), parent_namehash(4),
///               protocol(5), registry(6), owner(7), registrant(8), resolver(9),
///               token_id(10), canonical_id(11), token_version(12), namehash(13), expiry(14),
///               registry_locked(15), migrated(16), created_block(17), created_at(18),
///               registered_at(19), updated_block(20), updated_at(21), is_wrapped(22), wrapper_fuses(23),
///               wrapper_expiry(24), is_v1_name(25), v1_label_hash(26),
///               is_reachable(27), unreachable_since(28), ttl(29), is_legacy(30),
///               resolved_address(31)
const SQL_SELECT_NAMES =
    \\SELECT name, label, label_hash, parent_name, parent_namehash, protocol, registry,
    \\       owner, registrant, resolver, token_id, canonical_id, token_version, namehash, expiry,
    \\       registry_locked, migrated, created_block, created_at, registered_at, updated_block, updated_at,
    \\       is_wrapped, wrapper_fuses, wrapper_expiry, is_v1_name, v1_label_hash,
    \\       is_reachable, unreachable_since, ttl, is_legacy, resolved_address, is_normalized, is_alias
    \\FROM names
;

/// Shorter SELECT for the hot paths, wrapper fields last (34 columns).
/// Still includes is_reachable/unreachable_since/ttl so callers can honor
/// reachability filtering and serialize the flag.
const SQL_SELECT_NAMES_SHORT =
    \\SELECT name, label, label_hash, parent_name, parent_namehash, protocol, registry,
    \\       owner, registrant, resolver, token_id, canonical_id, token_version, namehash, expiry,
    \\       registry_locked, migrated, created_block, created_at, registered_at, updated_block, updated_at,
    \\       is_reachable, unreachable_since, ttl, is_legacy, resolved_address, is_normalized, is_wrapped, wrapper_fuses, wrapper_expiry, is_v1_name, v1_label_hash, is_alias
    \\FROM names
;

/// SQL_SELECT_NAMES_SHORT's column list plus a per-parent rank (name ASC, the
/// getSubdomains order) as a trailing column, derived at comptime so the two
/// lists cannot drift: a `SELECT * FROM (…) t` over it still parses with
/// parseNameRowShort (indices 0..33). Backs the batched getSubdomains mirror.
const SQL_SELECT_NAMES_FROM = "\nFROM names";
const SQL_SELECT_NAMES_SHORT_RANKED_BY_PARENT = blk: {
    std.debug.assert(std.mem.endsWith(u8, SQL_SELECT_NAMES_SHORT, SQL_SELECT_NAMES_FROM));
    break :blk SQL_SELECT_NAMES_SHORT[0 .. SQL_SELECT_NAMES_SHORT.len - SQL_SELECT_NAMES_FROM.len] ++
        ",\n       ROW_NUMBER() OVER (PARTITION BY parent_name ORDER BY name, protocol) AS rn" ++
        SQL_SELECT_NAMES_FROM;
};

const ROOT_NAMEHASH_HEX: []const u8 = "0x0000000000000000000000000000000000000000000000000000000000000000";

/// IN-list / VALUES width per statement for the batched page readers.
const BATCH_CHUNK = 200;

/// Arena-owned copy of a caller string in the exact form bindText would send
/// (UTF-8-sanitized), for a static bind: long key lists must bypass the
/// per-statement tracked-copy cap.
fn arenaBindCopy(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const clean = try unicode.sanitizeUtf8(arena, s);
    return if (clean.ptr == s.ptr) try arena.dupe(u8, s) else clean;
}

/// Append `n` comma-separated `?` placeholders wrapped as `(?),(?),…` VALUES rows
/// (`row_values = true`) or a bare `?,?,…` IN-list (`row_values = false`).
fn appendPlaceholders(sql: *std.ArrayList(u8), arena: std.mem.Allocator, n: usize, row_values: bool) !void {
    for (0..n) |i| {
        if (i != 0) try sql.append(arena, ',');
        try sql.appendSlice(arena, if (row_values) "(?)" else "?");
    }
}

/// Format a u256 as hex string with 0x prefix
fn formatU256Hex(allocator: std.mem.Allocator, value: u256) ![]u8 {
    return try std.fmt.allocPrint(allocator, "0x{x:0>64}", .{value});
}

/// Parse a Name model from a Query result row
/// Expects columns in SQL_SELECT_NAMES order (27 columns with wrapper fields)
fn parseNameRow(q: *Query, allocator: std.mem.Allocator) !models.Name {
    const name_str = q.getTextSlice(0) orelse "";
    const label_str = q.getTextSlice(1) orelse "";
    const label_hash_str = q.getTextSlice(2) orelse "";
    const parent_name_str = q.getTextSlice(3) orelse "";
    const parent_hash_str = q.getTextSlice(4) orelse "";
    const protocol_str = q.getTextSlice(5) orelse models.Protocol.v2.toString();
    const registry_str = q.getTextSlice(6) orelse "";
    const owner_str = q.getTextSlice(7) orelse "";
    const registrant_str = q.getTextSlice(8);
    const resolver_str = q.getTextSlice(9) orelse "";
    const token_id_str = q.getTextSlice(10) orelse "0x0";
    const canonical_id_str = q.getTextSlice(11) orelse "0x0";
    const namehash_str = q.getTextSlice(13) orelse "";

    // Parse registrant - use owner as fallback for old records where registrant is null
    const registrant = if (registrant_str != null and registrant_str.?.len > 0)
        try Address.fromHex(registrant_str.?)
    else
        try Address.fromHex(owner_str);

    // Every fallible non-allocating parse FIRST, then the owned dupes under an
    // errdefer chain — a mid-literal parse failure used to leak the dupes made
    // before it (same hoist shape as the roles parser).
    const label_hash = try Hash.fromHex(label_hash_str);
    const parent_namehash_val = try Hash.fromHex(parent_hash_str);
    const protocol = try models.Protocol.fromString(protocol_str);
    const registry = try Address.fromHex(registry_str);
    const owner = try Address.fromHex(owner_str);
    const resolver = try Address.fromHex(resolver_str);
    const token_id = try parseU256Hex(token_id_str);
    const canonical_id = try parseU256Hex(canonical_id_str);
    const namehash_val = try Hash.fromHex(namehash_str);

    const name_owned = try allocator.dupe(u8, name_str);
    errdefer allocator.free(name_owned);
    const label_owned = try allocator.dupe(u8, label_str);
    errdefer allocator.free(label_owned);
    const parent_name_owned = try allocator.dupe(u8, parent_name_str);
    errdefer allocator.free(parent_name_owned);
    const wrapper_fuses = if (q.getTextSlice(23)) |fuses| try allocator.dupe(u8, fuses) else null;
    errdefer if (wrapper_fuses) |f| allocator.free(f);
    const wrapper_expiry = q.getOptionalInt64(24);
    const v1_label_hash = if (q.getTextSlice(26)) |hash| try allocator.dupe(u8, hash) else null;

    return models.Name{
        .name = name_owned,
        .label = label_owned,
        .label_hash = label_hash,
        .parent_name = parent_name_owned,
        .parent_namehash = parent_namehash_val,
        .protocol = protocol,
        .registry = registry,
        .owner = owner,
        .registrant = registrant,
        .resolver = resolver,
        .token_id = token_id,
        .canonical_id = canonical_id,
        .token_version = @intCast(q.getInt64(12)),
        .namehash = namehash_val,
        .expiry = @bitCast(q.getInt64(14)),
        .registry_locked = q.getBool(15),
        .migrated = q.getBool(16),
        .created_block = @intCast(q.getInt64(17)),
        .created_at = q.getInt64(18),
        .registered_at = q.getOptionalInt64(19) orelse q.getInt64(18),
        .updated_block = @intCast(q.getInt64(20)),
        .updated_at = q.getInt64(21),
        .is_wrapped = q.getBool(22),
        .wrapper_fuses = wrapper_fuses,
        .wrapper_expiry = wrapper_expiry,
        .is_v1_name = q.getBool(25),
        .v1_label_hash = v1_label_hash,
        .is_reachable = q.getBool(27),
        .unreachable_since = q.getOptionalInt64(28),
        .ttl = if (q.getOptionalInt64(29)) |t| @intCast(t) else null,
        .is_legacy = q.getBool(30),
        .resolved_address = if (q.getTextSlice(31)) |s|
            Address.fromHex(s) catch null
        else
            null,
        .is_normalized = q.getBool(32),
        .is_alias = q.getBool(33),
    };
}

/// Parse a Name model from short query (27 columns, no wrapper fields)
fn parseNameRowShort(q: *Query, allocator: std.mem.Allocator) !models.Name {
    const name_str = q.getTextSlice(0) orelse "";
    const label_str = q.getTextSlice(1) orelse "";
    const label_hash_str = q.getTextSlice(2) orelse "";
    const parent_name_str = q.getTextSlice(3) orelse "";
    const parent_hash_str = q.getTextSlice(4) orelse "";
    const protocol_str = q.getTextSlice(5) orelse models.Protocol.v2.toString();
    const registry_str = q.getTextSlice(6) orelse "";
    const owner_str = q.getTextSlice(7) orelse "";
    const registrant_str = q.getTextSlice(8);
    const resolver_str = q.getTextSlice(9) orelse "";
    const token_id_str = q.getTextSlice(10) orelse "0x0";
    const canonical_id_str = q.getTextSlice(11) orelse "0x0";
    const namehash_str = q.getTextSlice(13) orelse "";

    const registrant = if (registrant_str != null and registrant_str.?.len > 0)
        try Address.fromHex(registrant_str.?)
    else
        try Address.fromHex(owner_str);

    // Same hoist-then-errdefer discipline as parseNameRow above.
    const label_hash = try Hash.fromHex(label_hash_str);
    const parent_namehash_val = try Hash.fromHex(parent_hash_str);
    const protocol = try models.Protocol.fromString(protocol_str);
    const registry = try Address.fromHex(registry_str);
    const owner = try Address.fromHex(owner_str);
    const resolver = try Address.fromHex(resolver_str);
    const token_id = try parseU256Hex(token_id_str);
    const canonical_id = try parseU256Hex(canonical_id_str);
    const namehash_val = try Hash.fromHex(namehash_str);

    const name_owned = try allocator.dupe(u8, name_str);
    errdefer allocator.free(name_owned);
    const label_owned = try allocator.dupe(u8, label_str);
    errdefer allocator.free(label_owned);
    const parent_name_owned = try allocator.dupe(u8, parent_name_str);
    errdefer allocator.free(parent_name_owned);
    const wrapper_fuses = if (q.getTextSlice(29)) |fuses| try allocator.dupe(u8, fuses) else null;
    errdefer if (wrapper_fuses) |f| allocator.free(f);
    const v1_label_hash = if (q.getTextSlice(32)) |hash| try allocator.dupe(u8, hash) else null;

    return models.Name{
        .name = name_owned,
        .label = label_owned,
        .label_hash = label_hash,
        .parent_name = parent_name_owned,
        .parent_namehash = parent_namehash_val,
        .protocol = protocol,
        .registry = registry,
        .owner = owner,
        .registrant = registrant,
        .resolver = resolver,
        .token_id = token_id,
        .canonical_id = canonical_id,
        .token_version = @intCast(q.getInt64(12)),
        .namehash = namehash_val,
        .expiry = @bitCast(q.getInt64(14)),
        .registry_locked = q.getBool(15),
        .migrated = q.getBool(16),
        .created_block = @intCast(q.getInt64(17)),
        .created_at = q.getInt64(18),
        .registered_at = q.getOptionalInt64(19) orelse q.getInt64(18),
        .updated_block = @intCast(q.getInt64(20)),
        .updated_at = q.getInt64(21),
        .is_wrapped = q.getBool(28),
        .wrapper_fuses = wrapper_fuses,
        .wrapper_expiry = q.getOptionalInt64(30),
        .is_v1_name = q.getBool(31),
        .v1_label_hash = v1_label_hash,
        .is_reachable = q.getBool(22),
        .unreachable_since = q.getOptionalInt64(23),
        .ttl = if (q.getOptionalInt64(24)) |t| @intCast(t) else null,
        .is_legacy = q.getBool(25),
        .resolved_address = if (q.getTextSlice(26)) |s|
            Address.fromHex(s) catch null
        else
            null,
        .is_normalized = q.getBool(27),
        .is_alias = q.getBool(33),
    };
}

// ============================================================================
// NAME QUERY OPERATIONS
// ============================================================================

/// A namehash identifies a node, and `names` is UNIQUE(protocol, namehash) — so a name
/// MIGRATED from V1 to V2 has a row in each protocol and this lookup has two candidates.
///
/// It used to have no `ORDER BY` at all, so which twin a caller got was decided by the
/// storage engine: SQLite returned rowid order, Postgres heap order, and the two could
/// disagree about a migrated name's owner, expiry and resolver. The tiebreak below makes the
/// answer deterministic AND consistent with the list queries, which suppress the V1 row
/// whenever a V2 twin exists (`names_filter`'s twin-suppression predicate) — so the point
/// read and the listing can no longer disagree about the same node.
///
/// Callers that mean one specific protocol should say so: `getNameByNamehashAndProtocol`
/// binds the full unique key. Every V1 indexer handler uses that one.
const TWIN_PREFERENCE = " ORDER BY CASE WHEN protocol = 'v2' THEN 0 ELSE 1 END, protocol ASC LIMIT 1";

pub fn getNameByNamehash(db: *Database, namehash: Hash) !?models.Name {
    try db.namesBarrier();
    var q = try Query.initCached(db, SQL_SELECT_NAMES ++ " WHERE namehash = ?" ++ TWIN_PREFERENCE);
    defer q.deinit();

    try q.bindHash(namehash);

    if (try q.step()) {
        return try parseNameRow(&q, db.allocator);
    }
    return null;
}

/// Get just the `name` column for a namehash, allocator-owned, or null if missing.
/// Avoids the cost of fetching + duping a full 21-column Name row when callers only
/// need the human-readable name string (reverse-resolution hot path in the indexer).
pub fn getNameStringByNamehash(db: *Database, namehash: Hash, allocator: std.mem.Allocator) !?[]u8 {
    try db.namesBarrier();
    // Same twin preference as getNameByNamehash — see TWIN_PREFERENCE.
    var q = try Query.initCached(db, "SELECT name FROM names WHERE namehash = ?" ++ TWIN_PREFERENCE);
    defer q.deinit();

    try q.bindHash(namehash);

    if (try q.step()) {
        if (q.getTextSlice(0)) |name| {
            return try allocator.dupe(u8, name);
        }
    }
    return null;
}

/// Get a name by namehash within a specific protocol scope. Used for migration
/// path lookups where we need to find the V1 row by the same namehash a V2
/// LabelRegistered event just produced.
pub fn getNameByNamehashAndProtocol(db: *Database, namehash: Hash, protocol: models.Protocol) !?models.Name {
    try db.namesBarrier();
    var q = try Query.initCached(db, SQL_SELECT_NAMES ++ " WHERE namehash = ? AND protocol = ?");
    defer q.deinit();

    try q.bindHash(namehash);
    try q.bindTextStatic(protocol.toString());

    if (try q.step()) {
        return try parseNameRow(&q, db.allocator);
    }
    return null;
}

/// Get namehash by resolver address
/// The name a resolver belongs to, or null when that question has no single answer.
///
/// This backs the zero-namehash fallback for resolver events: ENSv2 deploys a dedicated
/// resolver per name, so an event whose node is zero can be attributed to that resolver's one
/// name. The premise fails for a SHARED resolver, and it fails hard — on the reference mirror
/// 1,002 resolvers serve more than one name and the most-used serves **159,143**. With
/// `LIMIT 1` and no ORDER BY this returned an arbitrary one of them, so a record would be
/// attributed to a name picked effectively at random (and differently on SQLite vs Postgres).
///
/// So it refuses to guess: `LIMIT 2` and null when a second row exists, the same
/// count-must-be-1 guard `getUniqueNameByCanonicalId` uses. The caller's existing
/// "unknown resolver" branch then skips the event, which loses one event's attribution instead
/// of writing it to the wrong name. Protocol-scoped for the usual reason — `names` is
/// UNIQUE(protocol, namehash) and nothing stops the two protocols sharing a resolver address.
pub fn getNamehashByResolver(db: *Database, protocol: models.Protocol, resolver: Address) !?Hash {
    try db.namesBarrier();
    var q = try Query.initCached(db, "SELECT namehash FROM names WHERE protocol = ? AND resolver = ? LIMIT 2");
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(resolver);

    if (!try q.step()) return null;
    const namehash_str = q.getTextSlice(0) orelse return null;
    const first = try Hash.fromHex(namehash_str);
    // A second row means the resolver is shared and the question is unanswerable.
    if (try q.step()) return null;
    return first;
}

/// Get name by token ID and registry address (avoids cross-registry tokenId collisions).
/// Strips to canonical_id (version-independent) for lookup, so this works with any
/// version of the token_id and is resilient to TokenRegenerated events.
pub fn getNameByTokenIdAndRegistry(db: *Database, token_id: u256, registry: Address) !?models.Name {
    try db.namesBarrier();
    // `is_alias = 0` is what keeps this single-valued. A registry pointed at by
    // several live parents holds one row per (label, parent) — all sharing this
    // (canonical_id, registry) pair — and the unfiltered `LIMIT 1` would pick an
    // arbitrary one, backend-defined, sending every ownership / expiry / resolver
    // write to a random FQDN of the label. Exactly one row per pair is the
    // attributed primary; the alias rows are derived from it (storage/name_aliases).
    // ORDER BY is belt-and-braces on top of `is_alias = 0`. The invariant says one
    // primary per (canonical_id, registry), but it is maintained across events rather
    // than enforced by a constraint: re-registering a label in a shared registry whose
    // original parent has since un-pointed makes the handler derive a different FQDN,
    // and the upsert writes `is_alias = 0` there while the old primary keeps its flag.
    // A bare LIMIT 1 would then pick backend-defined garbage; oldest-first makes the
    // degraded case pick the same row every time, on both backends, so ownership and
    // expiry writes stay on one FQDN instead of alternating.
    var q = try Query.initCached(db, SQL_SELECT_NAMES ++
        " WHERE canonical_id = ? AND registry = ? AND is_alias = 0 ORDER BY created_block ASC, namehash ASC LIMIT 1");
    defer q.deinit();

    const token_id_utils = @import("../types/token_id.zig");
    const canonical_id = token_id_utils.getCanonicalId(token_id);
    var canonical_id_buf: [66]u8 = undefined;
    const canonical_id_hex = formatU256HexBuf(&canonical_id_buf, canonical_id);

    try q.bindText(canonical_id_hex);
    try q.bindAddressBuf(registry);

    if (try q.step()) {
        return try parseNameRow(&q, db.allocator);
    }
    return null;
}

/// The single name matching this canonical token id under `protocol`, or null
/// when none — or MORE THAN ONE — matches. The uniqueness guard matters: the
/// same label under different parents yields the same token id in different
/// registries (the documented cross-registry collision class), and callers of
/// this registry-less lookup (the write-buffer's placeholder-event repair)
/// must skip rather than guess in that case.
pub fn getUniqueNameByCanonicalId(db: *Database, protocol: models.Protocol, token_id: u256) !?models.Name {
    try db.namesBarrier();
    // Alias rows are excluded before the uniqueness guard runs: they share the
    // canonical id of their primary by construction, so counting them would make
    // this return null for every shared-registry label and degrade event naming to
    // the `tokenId:N` placeholder. The guard still fires for the genuine
    // cross-registry collision it exists for.
    var q = try Query.initCached(db, SQL_SELECT_NAMES ++ " WHERE canonical_id = ? AND protocol = ? AND is_alias = 0 LIMIT 2");
    defer q.deinit();

    const token_id_utils = @import("../types/token_id.zig");
    const canonical_id = token_id_utils.getCanonicalId(token_id);
    var canonical_id_buf: [66]u8 = undefined;
    const canonical_id_hex = formatU256HexBuf(&canonical_id_buf, canonical_id);

    try q.bindText(canonical_id_hex);
    try q.bindTextStatic(protocol.toString());

    if (!try q.step()) return null;
    var first = try parseNameRow(&q, db.allocator);
    // The ambiguity-check step can itself fail (SQLITE_BUSY/IOERR) — without
    // this, `first`'s duped strings leak on that error path, silently and
    // repeatedly under the repair loop's `catch null`.
    errdefer first.deinit(db.allocator);
    if (try q.step()) {
        first.deinit(db.allocator);
        return null;
    }
    return first;
}

/// Every row whose canonical_id is in `canonical_ids` — deliberately no
/// protocol or registry filter, so the caller (the dispatch-scoped name
/// prefetch) holds the COMPLETE row set per id and can mirror both point
/// lookups above exactly, authoritative misses included. Rows and the
/// returned slice are allocated with `allocator`.
///
/// `is_alias = 0` matches the two point lookups: both exclude the derived
/// shared-registry alias rows, and both of this function's callers reduce their
/// result with a count-must-be-1 uniqueness guard, which alias rows (sharing
/// their primary's canonical id by construction) would trip on every
/// shared-registry label.
pub fn getNamesByCanonicalIds(db: *Database, canonical_ids: []const u256, allocator: std.mem.Allocator) ![]models.Name {
    try db.namesBarrier();
    var out: std.ArrayList(models.Name) = .empty;
    errdefer {
        for (out.items) |*n| n.deinit(allocator);
        out.deinit(allocator);
    }

    const CHUNK = 200;
    var start: usize = 0;
    while (start < canonical_ids.len) {
        const chunk = canonical_ids[start..@min(start + CHUNK, canonical_ids.len)];
        start += chunk.len;

        var scratch = std.heap.ArenaAllocator.init(db.allocator);
        defer scratch.deinit();

        var sql: std.ArrayList(u8) = .empty;
        try sql.appendSlice(scratch.allocator(), SQL_SELECT_NAMES ++ " WHERE is_alias = 0 AND canonical_id IN (");
        for (chunk, 0..) |_, i| {
            if (i != 0) try sql.append(scratch.allocator(), ',');
            try sql.append(scratch.allocator(), '?');
        }
        try sql.append(scratch.allocator(), ')');

        var q = try Query.init(db, sql.items);
        defer q.deinit();
        for (chunk) |cid| {
            const buf = try scratch.allocator().create([66]u8);
            try q.bindTextStatic(formatU256HexBuf(buf, cid));
        }
        while (try q.step()) {
            var row = try parseNameRow(&q, allocator);
            errdefer row.deinit(allocator);
            try out.append(allocator, row);
        }
    }

    return try out.toOwnedSlice(allocator);
}

/// The `is_alias = 0` rows of one registry contract: the labels that registry has
/// minted, one row each. Backs the shared-registry alias derivation
/// (storage/name_aliases.zig), which copies each of these into one row per extra
/// live referring parent, so the alias rows themselves must stay out — including
/// them would make the derivation copy its own output. Ordered by namehash so a
/// pass emits its rows in the same sequence on every run and under replay. Rows
/// and the returned slice are allocated with `allocator`.
pub fn getNamesInRegistry(
    db: *Database,
    allocator: std.mem.Allocator,
    protocol: models.Protocol,
    registry: Address,
) ![]models.Name {
    try db.namesBarrier();
    var out: std.ArrayList(models.Name) = .empty;
    errdefer {
        for (out.items) |*n| n.deinit(allocator);
        out.deinit(allocator);
    }

    var q = try Query.initCached(db, SQL_SELECT_NAMES ++
        " WHERE protocol = ? AND registry = ? AND is_alias = 0 ORDER BY namehash ASC");
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(registry);

    while (try q.step()) {
        var row = try parseNameRow(&q, allocator);
        errdefer row.deinit(allocator);
        try out.append(allocator, row);
    }
    return out.toOwnedSlice(allocator);
}

/// Every row whose namehash is in `namehashes` — no protocol filter, no
/// LIMIT, exactly the row universe getNameByNamehash steps over. The API-page
/// domain loader groups these per namehash and only serves namehashes with a
/// SINGLE row (multi-row namehashes fall back to the point query, whose
/// unordered first-row pick only SQL can reproduce). Rows and the returned
/// slice are allocated with `allocator`.
pub fn getNamesByNamehashes(db: *Database, namehashes: []const Hash, allocator: std.mem.Allocator) ![]models.Name {
    try db.namesBarrier();
    var out: std.ArrayList(models.Name) = .empty;
    errdefer {
        for (out.items) |*n| n.deinit(allocator);
        out.deinit(allocator);
    }

    const CHUNK = 200;
    var start: usize = 0;
    while (start < namehashes.len) {
        const chunk = namehashes[start..@min(start + CHUNK, namehashes.len)];
        start += chunk.len;

        var scratch = std.heap.ArenaAllocator.init(db.allocator);
        defer scratch.deinit();

        var sql: std.ArrayList(u8) = .empty;
        try sql.appendSlice(scratch.allocator(), SQL_SELECT_NAMES ++ " WHERE namehash IN (");
        for (chunk, 0..) |_, i| {
            if (i != 0) try sql.append(scratch.allocator(), ',');
            try sql.append(scratch.allocator(), '?');
        }
        try sql.append(scratch.allocator(), ')');

        var q = try Query.init(db, sql.items);
        defer q.deinit();
        for (chunk) |nh| {
            const buf = try scratch.allocator().create([66]u8);
            try q.bindTextStatic(nh.toHexBuf(buf));
        }
        while (try q.step()) {
            var row = try parseNameRow(&q, allocator);
            errdefer row.deinit(allocator);
            try out.append(allocator, row);
        }
    }

    return try out.toOwnedSlice(allocator);
}

pub const CanonicalNameResolution = struct {
    name: ?[]const u8,
    namehash: Hash,
};

/// Batched mirror of getUniqueNameByCanonicalId over many token ids: one
/// IN-list sweep instead of one point query each (the placeholder-repair
/// passes issue thousands of these per bulk-sync batch). The returned map is
/// keyed by CANONICAL id and holds an entry only for ids that resolve
/// uniquely under `protocol` — zero rows and the cross-registry ambiguity are
/// both absent, exactly like the point lookup's null. Valid only when no
/// names write happens between here and the lookups it replaces (the repair
/// passes write events only). Names are duped with `allocator`; release via
/// freeCanonicalNameResolutions.
pub fn resolveUniqueNamesByCanonicalIds(db: *Database, protocol: models.Protocol, token_ids: []const u256, allocator: std.mem.Allocator) !std.AutoHashMap(u256, CanonicalNameResolution) {
    try db.namesBarrier();
    var out = std.AutoHashMap(u256, CanonicalNameResolution).init(allocator);
    errdefer freeCanonicalNameResolutions(&out, allocator);

    var seen = std.AutoHashMap(u256, void).init(allocator);
    defer seen.deinit();
    var cids: std.ArrayList(u256) = .empty;
    defer cids.deinit(allocator);
    const token_id_utils = @import("../types/token_id.zig");
    for (token_ids) |tok| {
        const cid = token_id_utils.getCanonicalId(tok);
        const gop = try seen.getOrPut(cid);
        if (!gop.found_existing) try cids.append(allocator, cid);
    }
    if (cids.items.len == 0) return out;

    var arena = std.heap.ArenaAllocator.init(db.allocator);
    defer arena.deinit();
    const rows = try getNamesByCanonicalIds(db, cids.items, arena.allocator());

    const Tally = struct { count: usize, row_index: usize };
    var tally = std.AutoHashMap(u256, Tally).init(allocator);
    defer tally.deinit();
    for (rows, 0..) |row, i| {
        if (row.protocol != protocol) continue;
        const gop = try tally.getOrPut(row.canonical_id);
        if (gop.found_existing) {
            gop.value_ptr.count += 1;
        } else {
            gop.value_ptr.* = .{ .count = 1, .row_index = i };
        }
    }

    var it = tally.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.count != 1) continue;
        const row = rows[kv.value_ptr.row_index];
        try out.put(kv.key_ptr.*, .{
            .name = if (row.name) |nm| try allocator.dupe(u8, nm) else null,
            .namehash = row.namehash,
        });
    }
    return out;
}

pub fn freeCanonicalNameResolutions(map: *std.AutoHashMap(u256, CanonicalNameResolution), allocator: std.mem.Allocator) void {
    var it = map.valueIterator();
    while (it.next()) |v| {
        if (v.name) |nm| allocator.free(nm);
    }
    map.deinit();
}

/// Get all names owned by an address. Unreachable rows (orphaned by a
/// subregistry repoint or LabelUnregistered) are filtered out.
pub fn getNamesByOwner(db: *Database, owner: Address, limit: ?u32) ![]models.Name {
    try db.namesBarrier();
    const sql = if (limit) |l|
        try std.fmt.allocPrint(db.allocator, SQL_SELECT_NAMES_SHORT ++ " WHERE is_reachable = 1 AND is_normalized = 1 AND owner = ? AND namehash != '0x0000000000000000000000000000000000000000000000000000000000000000' LIMIT {d}", .{l})
    else
        try db.allocator.dupe(u8, SQL_SELECT_NAMES_SHORT ++ " WHERE is_reachable = 1 AND is_normalized = 1 AND owner = ? AND namehash != '0x0000000000000000000000000000000000000000000000000000000000000000'");
    defer db.allocator.free(sql);

    var q = try Query.initCached(db, sql);
    defer q.deinit();

    try q.bindAddress(owner);

    var names: std.ArrayList(models.Name) = .empty;
    errdefer {
        for (names.items) |*name| {
            name.deinit(db.allocator);
        }
        names.deinit(db.allocator);
    }

    while (try q.step()) {
        try names.append(db.allocator, try parseNameRowShort(&q, db.allocator));
    }

    return names.toOwnedSlice(db.allocator);
}

/// Get names by resolver address. Unreachable rows are filtered out.
pub fn getNamesByResolver(db: *Database, resolver: Address, limit: u32) ![]models.Name {
    try db.namesBarrier();
    var q = try Query.init(db, SQL_SELECT_NAMES_SHORT ++ " WHERE is_reachable = 1 AND is_normalized = 1 AND resolver = ? AND namehash != '0x0000000000000000000000000000000000000000000000000000000000000000' ORDER BY created_at DESC LIMIT ?");
    defer q.deinit();

    try q.bindAddress(resolver);
    try q.bindInt(@intCast(limit));

    var names: std.ArrayList(models.Name) = .empty;
    errdefer {
        for (names.items) |*name| {
            name.deinit(db.allocator);
        }
        names.deinit(db.allocator);
    }

    while (try q.step()) {
        try names.append(db.allocator, try parseNameRowShort(&q, db.allocator));
    }

    return names.toOwnedSlice(db.allocator);
}

/// Get wrapped V1 names (paginated). Optionally filter by owner / exact name /
/// expiry bounds — backs the top-level `wrappedDomains` GraphQL query.
/// Unreachable rows are filtered out to match the rest of the API contract.
pub const WrappedDomainFilters = struct {
    owner: ?Address = null,
    name: ?[]const u8 = null,
    expiry_gt: ?i64 = null,
    expiry_lt: ?i64 = null,
};

pub fn getWrappedDomains(
    db: *Database,
    filters: WrappedDomainFilters,
    skip: u32,
    limit: u32,
) ![]models.Name {
    try db.namesBarrier();
    var sql_buf: std.ArrayList(u8) = .empty;
    defer sql_buf.deinit(db.allocator);
    try sql_buf.appendSlice(db.allocator, SQL_SELECT_NAMES);
    try sql_buf.appendSlice(db.allocator, " WHERE is_reachable = 1 AND is_normalized = 1 AND is_wrapped = 1");
    if (filters.owner != null) try sql_buf.appendSlice(db.allocator, " AND owner = ?");
    if (filters.name != null) try sql_buf.appendSlice(db.allocator, " AND name = ?");
    if (filters.expiry_gt != null) try sql_buf.appendSlice(db.allocator, " AND wrapper_expiry > ?");
    if (filters.expiry_lt != null) try sql_buf.appendSlice(db.allocator, " AND wrapper_expiry < ?");
    try sql_buf.appendSlice(db.allocator, " ORDER BY created_at DESC LIMIT ? OFFSET ?");

    var q = try Query.init(db, sql_buf.items);
    defer q.deinit();

    if (filters.owner) |o| try q.bindAddress(o);
    if (filters.name) |n| try q.bindText(n);
    if (filters.expiry_gt) |v| try q.bindInt64(v);
    if (filters.expiry_lt) |v| try q.bindInt64(v);
    try q.bindInt(@intCast(limit));
    try q.bindInt(@intCast(skip));

    var names: std.ArrayList(models.Name) = .empty;
    errdefer {
        for (names.items) |*n| n.deinit(db.allocator);
        names.deinit(db.allocator);
    }
    while (try q.step()) {
        try names.append(db.allocator, try parseNameRow(&q, db.allocator));
    }
    return names.toOwnedSlice(db.allocator);
}

/// Get the canonical Domain row for a resolver (first by namehash ASC).
/// Used by the `Resolver.domain` back-reference (subgraph parity). Returns
/// null when no name currently points at this resolver. Unreachable rows
/// are filtered out to match the rest of the API contract.
pub fn getDomainByResolver(db: *Database, resolver: Address) !?models.Name {
    try db.namesBarrier();
    var q = try Query.initCached(
        db,
        SQL_SELECT_NAMES ++ " WHERE is_reachable = 1 AND is_normalized = 1 AND resolver = ? AND namehash != '0x0000000000000000000000000000000000000000000000000000000000000000' ORDER BY namehash ASC LIMIT 1",
    );
    defer q.deinit();

    try q.bindAddress(resolver);

    if (try q.step()) {
        return try parseNameRow(&q, db.allocator);
    }
    return null;
}

/// Batched mirror of getDomainByResolver over many resolvers: for each resolver
/// address, the single row the point query would return (reachable, normalized,
/// non-root, first by namehash ASC). The resolver list is a VALUES CTE and each
/// resolver's pick is a scalar subquery over the same WHERE — on the
/// (resolver, namehash) index that stops at its first entry — whose result
/// keys the outer row-value IN probe. Resolvers with no such row contribute
/// nothing. Chunks of 200 with arena-static address binds (no tracked-copy
/// cap). Rows and the returned slice are allocated with `allocator`.
pub fn getDomainsByResolvers(db: *Database, resolvers: []const Address, allocator: std.mem.Allocator) ![]models.Name {
    try db.namesBarrier();
    var out: std.ArrayList(models.Name) = .empty;
    errdefer {
        for (out.items) |*n| n.deinit(allocator);
        out.deinit(allocator);
    }

    // Duplicates yield one row: dedupe before chunking so a resolver repeated
    // across chunk boundaries is not picked (and returned) once per chunk.
    var seen = std.AutoHashMap([20]u8, void).init(db.allocator);
    defer seen.deinit();
    var unique: std.ArrayList(Address) = .empty;
    defer unique.deinit(db.allocator);
    for (resolvers) |r| {
        const gop = try seen.getOrPut(r.bytes);
        if (!gop.found_existing) try unique.append(db.allocator, r);
    }

    var start: usize = 0;
    while (start < unique.items.len) {
        const chunk = unique.items[start..@min(start + BATCH_CHUNK, unique.items.len)];
        start += chunk.len;

        var scratch = std.heap.ArenaAllocator.init(db.allocator);
        defer scratch.deinit();

        var sql: std.ArrayList(u8) = .empty;
        try sql.appendSlice(scratch.allocator(), "WITH v(addr) AS (VALUES ");
        try appendPlaceholders(&sql, scratch.allocator(), chunk.len, true);
        try sql.appendSlice(scratch.allocator(), ") " ++ SQL_SELECT_NAMES ++ " n WHERE n.is_reachable = 1 AND n.is_normalized = 1 AND (n.resolver, n.namehash) IN (SELECT v.addr, (SELECT m.namehash FROM names m WHERE m.resolver = v.addr AND m.is_reachable = 1 AND m.is_normalized = 1 AND m.namehash != '" ++ ROOT_NAMEHASH_HEX ++ "' ORDER BY m.namehash ASC LIMIT 1) FROM v)");

        var q = try Query.init(db, sql.items);
        defer q.deinit();
        for (chunk) |resolver| {
            const buf = try scratch.allocator().create([42]u8);
            try q.bindTextStatic(resolver.toHexBuf(buf));
        }
        while (try q.step()) {
            var row = try parseNameRow(&q, allocator);
            errdefer row.deinit(allocator);
            try out.append(allocator, row);
        }
    }

    return try out.toOwnedSlice(allocator);
}

// ============================================================================
// SUBDOMAIN OPERATIONS
// ============================================================================

/// Count direct subdomains of a name. Unreachable subdomains (orphaned by
/// a subregistry repoint) are excluded to match `getSubdomains` semantics.
/// Subgraph parity: a name is considered fully burned (eligible for GC) when
/// both `owner` and `resolver` are the zero address. Subgraph deletes such
/// rows recursively when their subdomainCount is also 0; we approximate at
/// query time by filtering them out of subdomain queries. The full recursive
/// `subdomainCount == 0` check is omitted because it would require a sub-
/// query per row — the practical effect of filtering on owner+resolver alone
/// is close enough (a name with no owner/resolver but live children is rare
/// and clients can still reach it via direct namehash lookup).
const ZERO_ADDR_HEX: []const u8 = "0x0000000000000000000000000000000000000000";
const SUBDOMAIN_GC_FILTER: []const u8 = " AND NOT (owner = '" ++ ZERO_ADDR_HEX ++ "' AND resolver = '" ++ ZERO_ADDR_HEX ++ "')";

pub fn countDirectSubdomains(db: *Database, parent_name: []const u8) !u32 {
    try db.namesBarrier();
    var q = try Query.initCached(db, "SELECT COUNT(*) FROM names WHERE is_reachable = 1 AND is_normalized = 1 AND parent_name = ?" ++ SUBDOMAIN_GC_FILTER);
    defer q.deinit();

    try q.bindText(parent_name);

    if (try q.step()) {
        return @intCast(q.getInt64(0));
    }
    return 0;
}

pub const ParentCountRow = struct { parent_name: []u8, count: u32 };

pub fn freeParentCountRows(allocator: std.mem.Allocator, rows: []ParentCountRow) void {
    for (rows) |row| allocator.free(row.parent_name);
    allocator.free(rows);
}

/// Batched mirror of countDirectSubdomains over many parents: one GROUP BY
/// statement per chunk of 200 (deduped) parent names, same WHERE as the point
/// query, rows ordered by parent_name. Parents with no counted child are
/// absent (the caller reads absent as 0). Names are bound statically from an
/// arena copy so long lists escape the tracked-copy cap. Rows (and each
/// parent_name) are allocated with `allocator`; release via freeParentCountRows.
pub fn countDirectSubdomainsForParents(db: *Database, parent_names: []const []const u8, allocator: std.mem.Allocator) ![]ParentCountRow {
    try db.namesBarrier();
    var out: std.ArrayList(ParentCountRow) = .empty;
    errdefer {
        for (out.items) |row| allocator.free(row.parent_name);
        out.deinit(allocator);
    }

    var unique: std.ArrayList([]const u8) = .empty;
    defer unique.deinit(db.allocator);
    try dedupeStrings(db.allocator, parent_names, &unique);

    var start: usize = 0;
    while (start < unique.items.len) {
        const chunk = unique.items[start..@min(start + BATCH_CHUNK, unique.items.len)];
        start += chunk.len;

        var scratch = std.heap.ArenaAllocator.init(db.allocator);
        defer scratch.deinit();

        var sql: std.ArrayList(u8) = .empty;
        try sql.appendSlice(scratch.allocator(), "SELECT parent_name, COUNT(*) FROM names WHERE is_reachable = 1 AND is_normalized = 1 AND parent_name IN (");
        try appendPlaceholders(&sql, scratch.allocator(), chunk.len, false);
        try sql.appendSlice(scratch.allocator(), ")" ++ SUBDOMAIN_GC_FILTER ++ " GROUP BY parent_name ORDER BY parent_name");

        var q = try Query.init(db, sql.items);
        defer q.deinit();
        for (chunk) |parent| try q.bindTextStatic(try arenaBindCopy(scratch.allocator(), parent));
        while (try q.step()) {
            const parent_name = try allocator.dupe(u8, q.getTextSlice(0) orelse "");
            errdefer allocator.free(parent_name);
            try out.append(allocator, .{ .parent_name = parent_name, .count = @intCast(q.getInt64(1)) });
        }
    }

    return try out.toOwnedSlice(allocator);
}

/// First occurrence of each distinct string in `input`, in input order (the
/// slices are borrowed, not copied).
fn dedupeStrings(allocator: std.mem.Allocator, input: []const []const u8, unique: *std.ArrayList([]const u8)) !void {
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    for (input) |s| {
        const gop = try seen.getOrPut(s);
        if (!gop.found_existing) try unique.append(allocator, s);
    }
}

/// Check if a name has any direct subdomains (reachable + non-burned).
pub fn hasDirectSubdomains(db: *Database, parent_name: []const u8) !bool {
    try db.namesBarrier();
    var q = try Query.initCached(db, "SELECT 1 FROM names WHERE is_reachable = 1 AND is_normalized = 1 AND parent_name = ?" ++ SUBDOMAIN_GC_FILTER ++ " LIMIT 1");
    defer q.deinit();

    try q.bindText(parent_name);
    return try q.step();
}

/// Get direct subdomains of a name with pagination. Unreachable rows
/// (orphans of a subregistry repoint) AND fully-burned rows (owner=0 AND
/// resolver=0, mirroring subgraph's GC deletion criteria) are filtered out
/// — callers that need them must query `getFilteredNames` with
/// `include_unreachable` (which still applies the GC filter; resurrection
/// requires direct namehash lookup).
pub fn getSubdomains(db: *Database, parent_name_arg: []const u8, skip: u32, limit: u32) ![]models.Name {
    try db.namesBarrier();
    var q = try Query.initCached(db, SQL_SELECT_NAMES_SHORT ++ " WHERE is_reachable = 1 AND is_normalized = 1 AND parent_name = ?" ++ SUBDOMAIN_GC_FILTER ++ " ORDER BY name, protocol LIMIT ? OFFSET ?");
    defer q.deinit();

    try q.bindText(parent_name_arg);
    try q.bindInt(@intCast(limit));
    try q.bindInt(@intCast(skip));

    var names: std.ArrayList(models.Name) = .empty;
    errdefer {
        for (names.items) |*name| {
            name.deinit(db.allocator);
        }
        names.deinit(db.allocator);
    }

    while (try q.step()) {
        try names.append(db.allocator, try parseNameRowShort(&q, db.allocator));
    }

    return names.toOwnedSlice(db.allocator);
}

/// Batched mirror of getSubdomains over many parents: per parent, the window
/// `skip < rank <= skip + first` of its direct subdomains ranked by name (the
/// point query's ORDER BY name LIMIT first OFFSET skip), same WHERE and GC
/// filter, one statement per chunk of 200 (deduped) parent names. Rows arrive
/// ordered by parent_name then rank, so each parent's page is one contiguous
/// run in page order; parents with no subdomains contribute nothing. Names
/// are bound statically from an arena copy. Rows and the returned slice are
/// allocated with `allocator`.
pub fn getSubdomainsForParentsPage(db: *Database, parent_names: []const []const u8, skip: u32, first: u32, allocator: std.mem.Allocator) ![]models.Name {
    try db.namesBarrier();
    var out: std.ArrayList(models.Name) = .empty;
    errdefer {
        for (out.items) |*n| n.deinit(allocator);
        out.deinit(allocator);
    }

    var unique: std.ArrayList([]const u8) = .empty;
    defer unique.deinit(db.allocator);
    try dedupeStrings(db.allocator, parent_names, &unique);

    const rank_lo: i64 = skip;
    const rank_hi: i64 = @as(i64, skip) + first;

    var start: usize = 0;
    while (start < unique.items.len) {
        const chunk = unique.items[start..@min(start + BATCH_CHUNK, unique.items.len)];
        start += chunk.len;

        var scratch = std.heap.ArenaAllocator.init(db.allocator);
        defer scratch.deinit();

        var sql: std.ArrayList(u8) = .empty;
        var q: Query = undefined;
        if (db.isPostgres()) {
            // One LATERAL page per parent: Postgres plans each exactly like
            // the point query (name index, LIMIT pushdown), so a parent with
            // millions of children costs what getSubdomains costs, not a
            // sort of every child. Rows arrive grouped per parent in page
            // order, like the windowed form below.
            try sql.appendSlice(scratch.allocator(), "WITH v(p) AS (VALUES ");
            for (chunk, 0..) |_, i| {
                if (i != 0) try sql.append(scratch.allocator(), ',');
                try sql.appendSlice(scratch.allocator(), "(?)");
            }
            try sql.appendSlice(scratch.allocator(), ") SELECT n.* FROM v CROSS JOIN LATERAL (" ++ SQL_SELECT_NAMES_SHORT ++ " WHERE is_reachable = 1 AND is_normalized = 1 AND parent_name = v.p" ++ SUBDOMAIN_GC_FILTER ++ " ORDER BY name, protocol LIMIT ? OFFSET ?) n");
            q = try Query.init(db, sql.items);
            errdefer q.deinit();
            for (chunk) |parent| try q.bindTextStatic(try arenaBindCopy(scratch.allocator(), parent));
            try q.bindInt64(@intCast(first));
            try q.bindInt64(@intCast(skip));
        } else {
            try sql.appendSlice(scratch.allocator(), "SELECT * FROM (" ++ SQL_SELECT_NAMES_SHORT_RANKED_BY_PARENT ++ " WHERE is_reachable = 1 AND is_normalized = 1 AND parent_name IN (");
            try appendPlaceholders(&sql, scratch.allocator(), chunk.len, false);
            try sql.appendSlice(scratch.allocator(), ")" ++ SUBDOMAIN_GC_FILTER ++ ") t WHERE rn > ? AND rn <= ? ORDER BY parent_name, rn");
            q = try Query.init(db, sql.items);
            errdefer q.deinit();
            for (chunk) |parent| try q.bindTextStatic(try arenaBindCopy(scratch.allocator(), parent));
            try q.bindInt64(rank_lo);
            try q.bindInt64(rank_hi);
        }
        defer q.deinit();
        while (try q.step()) {
            var row = try parseNameRowShort(&q, allocator);
            errdefer row.deinit(allocator);
            try out.append(allocator, row);
        }
    }

    return try out.toOwnedSlice(allocator);
}
