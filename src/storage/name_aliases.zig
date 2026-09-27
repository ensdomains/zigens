//! Shared-registry alias storage: the reads and bounded set-writes behind
//! "one Domain per live referring parent".
//!
//! A `PermissionedRegistry` contract can be the subregistry of SEVERAL parent
//! names at the same time — the portal offers "use a pre-existing registry
//! contract", and nothing on-chain forbids it. `getSubregistry(label)` then
//! returns that same contract for every one of those parents, so every label
//! minted in it resolves under every one of them: N parents x M labels = N*M
//! fully-qualified names, all live.
//!
//! `LabelRegistered` is emitted by the CHILD registry and carries no parent, so
//! the indexer can only attribute it through the registry address — which is
//! many-to-one. Attributing each label to a single parent (historically: the
//! most recent linker) stores M of those N*M names and drops the rest, which is
//! what a user sees as "my subname was created under someone else's name".
//!
//! ## The derivation is a fixpoint, not a procedure
//!
//! The alias rows are defined declaratively: given the live edge set
//! `LIVE_PARENT_EDGES` below, `names` must hold exactly one `is_alias = 1` row per
//! (primary label, live referring parent other than that label's own). Everything
//! here either reports the difference between that definition and the stored rows
//! (`aliasPlanBatch`) or removes rows the definition no longer contains
//! (`deleteStaleAliases`).
//!
//! Two consequences, which together are the whole safety argument:
//!
//!   * **Deterministic end state.** The fixpoint is a pure function of
//!     (`names`, `registries`, `registry_entries`) — no wall clock, no block
//!     number, no event ordering, no hash-map iteration order. A `--backfill`
//!     replay that runs the pass to exhaustion lands on the same rows a live run
//!     did, which is what makes the two byte-comparable. The live loop bounds
//!     rows-per-batch for latency, so only the PATH differs, never the
//!     destination; replay runs unbounded and reaches it in one pass.
//!   * **Cost proportional to the delta, not to the data.** Both halves are single
//!     set-operations over indexed predicates, so a steady state costs one
//!     statement returning zero rows. Nothing loads a registry's labels into
//!     memory and nothing iterates parents in Zig, so a registry with 100k labels
//!     and 30 referring parents costs the same per batch as an empty one once its
//!     rows exist.
//!
//! ## Depth and cycles
//!
//! An alias row is never itself treated as a parent (`pp.is_alias = 0` in the edge
//! set). That bounds the derivation to one level with no depth counter and no cycle
//! guard — the registry graph is allowed to contain self-loops and cycles (a live
//! Sepolia example points a registry's own label at itself), and without this
//! restriction each pass would mint one more level of nesting forever.
const std = @import("std");
const db_module = @import("database.zig");
const reorg_undo = @import("reorg_undo.zig");
const Database = db_module.Database;
const Query = db_module.Query;
const models = @import("../types/models.zig");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;
const formatU256HexBuf = @import("names_common.zig").formatU256HexBuf;
const hash_mod = @import("../types/hash.zig");
const ens_name = @import("../utils/ens_name.zig");

/// The live parent edges of every shared subregistry, as a subquery: one row per
/// (child registry contract, parent name that CURRENTLY points at it).
///
/// `registries` is append-only history — UNIQUE(protocol, address, namehash), one
/// row per (subregistry, parent) pair ever seen, inserted OR IGNORE, never pruned
/// — which makes it exactly the right candidate set and exactly the wrong answer
/// on its own. `registry_entries` is the live mirror of the on-chain `Entry`
/// mapping. Joining them through the parent's own `names` row turns "which parents
/// still point here" into names: history supplies the candidates, the mirror
/// supplies liveness. A parent that has since repointed or cleared its pointer
/// keeps its `registries` row but drops out of this join, which is what makes the
/// mechanism immune to the stale-linker class that reading history alone produced.
///
/// Three predicates on the parent row carry weight:
///   * `pp.is_alias = 0` — an alias is never a parent (see the module header).
///   * `pp.is_reachable = 1` — a derived name is only minted under a parent that
///     itself resolves, so the alias row's reachability is settled at insert time
///     and needs no second authority. When a parent stops resolving it leaves this
///     set and its derived rows are deleted.
///   * the parent NAME comes from `pp.name`, not `registries.name`: the latter is
///     frozen at link time and can still hold a `[0x…]` placeholder that was healed
///     afterwards, while the `names` row carries the live spelling.
///
/// And one on the EDGE: an expired parent resolves nothing beneath it on-chain
/// (`getSubregistry` returns zero for an expired entry), so it owes no derived names. Our stored
/// `0`/NULL means NEVER EXPIRES — the opposite of the contract's `0` — see
/// `registry_entries.EDGE_NOT_EXPIRED` for why that convention is the one to keep.
///
/// Bind order: `protocol`, then the evaluation time in chain seconds.
const LIVE_PARENT_EDGES =
    \\SELECT r.address AS edge_registry, pp.name AS edge_parent_name, pp.namehash AS edge_parent_namehash
    \\FROM registries r
    \\JOIN names pp ON pp.protocol = r.protocol AND pp.namehash = r.namehash
    \\              AND pp.is_alias = 0 AND pp.is_reachable = 1
    \\JOIN registry_entries re ON re.protocol = r.protocol AND re.parent_registry = pp.registry
    \\                        AND re.canonical_id = pp.canonical_id AND re.subregistry = r.address
    \\WHERE r.protocol = ?
    \\  AND (pp.expiry IS NULL OR pp.expiry = 0 OR pp.expiry > ?)
;

/// A parent name whose live `registry_entries` pointer currently targets the
/// subregistry being enumerated. `name` is allocator-owned.
pub const LiveParent = struct {
    name: []u8,
    namehash: Hash,
};

pub fn freeLiveParents(allocator: std.mem.Allocator, parents: []LiveParent) void {
    for (parents) |p| allocator.free(p.name);
    allocator.free(parents);
}

/// Every parent name whose entry currently points at `subregistry`, oldest link
/// first. Used by the registration handlers to attribute ONE label, so it is a
/// point read per subregistry-emitted event; the bulk derivation never calls it.
pub fn getLiveParentNames(
    db: *Database,
    allocator: std.mem.Allocator,
    protocol: models.Protocol,
    subregistry: Address,
    now: i64,
) ![]LiveParent {
    return getLiveParentNamesAsOf(db, allocator, protocol, subregistry, std.math.maxInt(i64), now);
}

/// `getLiveParentNames` restricted to parents that had already linked this registry
/// at or before `max_created_block`.
///
/// Needed by the registration handlers, not by the derivation. The V2 sync fetches
/// the parent registry's events for the whole block range (phase 1) before the child
/// registries' (phase 2), so when a `LabelRegistered` at block X is handled the live
/// mirror already carries pointer changes from blocks after X. Attributing the label
/// to a parent that only adopted the registry later would make the stored row depend
/// on the batch boundary — the same reason the history query this replaced was
/// block-bounded. `registries.created_block` is the first block at which that
/// (registry, parent) pair was seen, so it is the right bound.
///
/// Ordered by first-link block so the attributed parent is stable as later parents
/// adopt the registry; `namehash` breaks ties within one block.
pub fn getLiveParentNamesAsOf(
    db: *Database,
    allocator: std.mem.Allocator,
    protocol: models.Protocol,
    subregistry: Address,
    max_created_block: i64,
    /// Chain time the expiry test is evaluated at — an expired parent resolves nothing beneath it.
    now: i64,
) ![]LiveParent {
    try db.namesBarrier();
    var q = try Query.initCached(db,
        \\SELECT pp.name, pp.namehash FROM registries r
        \\JOIN names pp ON pp.protocol = r.protocol AND pp.namehash = r.namehash
        \\              AND pp.is_alias = 0 AND pp.is_reachable = 1
        \\JOIN registry_entries re ON re.protocol = r.protocol AND re.parent_registry = pp.registry
        \\                        AND re.canonical_id = pp.canonical_id AND re.subregistry = r.address
        \\WHERE r.protocol = ? AND r.address = ? AND r.created_block <= ?
        \\  AND (pp.expiry IS NULL OR pp.expiry = 0 OR pp.expiry > ?)
        \\ORDER BY r.created_block ASC, r.namehash ASC
    );
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(subregistry);
    try q.bindInt64(max_created_block);
    try q.bindInt64(now);

    var out: std.ArrayList(LiveParent) = .empty;
    errdefer {
        for (out.items) |p| allocator.free(p.name);
        out.deinit(allocator);
    }
    while (try q.step()) {
        const name_span = q.getTextSlice(0) orelse continue;
        const namehash_hex = q.getTextSlice(1) orelse continue;
        const namehash = Hash.fromHex(namehash_hex) catch continue;
        const name_copy = try allocator.dupe(u8, name_span);
        errdefer allocator.free(name_copy);
        try out.append(allocator, .{ .name = name_copy, .namehash = namehash });
    }
    return out.toOwnedSlice(allocator);
}

/// One alias row the definition requires but the table does not hold yet, as the
/// keys needed to build it. Strings are allocator-owned; free with `freeAliasPlan`.
pub const AliasPlanKey = struct {
    registry: Address,
    /// '0x' + 64 hex, exactly as stored.
    canonical_id: []u8,
    parent_name: []u8,
    parent_namehash: Hash,
};

pub fn freeAliasPlan(allocator: std.mem.Allocator, keys: []AliasPlanKey) void {
    for (keys) |k| {
        allocator.free(k.canonical_id);
        allocator.free(k.parent_name);
    }
    allocator.free(keys);
}

/// Where a bounded pass through one registry's labels stopped. Persisted in
/// `alias_work`, so a large registry materialises across batches without rescanning
/// what it already covered — and so the converged "anything left?" check is an index
/// seek rather than a full re-scan (measured: 0.04ms against 3.9s over 200k labels).
/// Null means "from the beginning"; the comparison is then omitted from the statement
/// entirely rather than bound to a sentinel.
pub const AliasPlanCursor = struct {
    canonical_id: ?[]const u8 = null,
    parent_namehash: ?[]const u8 = null,

    fn isSet(self: AliasPlanCursor) bool {
        return self.canonical_id != null and self.parent_namehash != null;
    }
};

/// The next `limit` alias rows `registry` owes, after `cursor`, in a total order.
///
/// Scoped to ONE registry on purpose, and this is the crux of the whole design. The
/// global form — every primary joined to every live edge, anti-joined against the
/// aliases that exist — cannot use `LIMIT` to bound its work: the join has to
/// enumerate every candidate pair before the limit applies, which measured **23.8s
/// per call** against 1.6M names (200k labels x 8 parents), every batch, forever. Per
/// registry plus a persisted cursor, the same question is an index range scan over
/// `idx_names_registry_canonical` starting AT the cursor: **9ms** for a 500-row page
/// mid-materialisation and **0.04ms** once that registry is converged. The registry
/// set comes from the `alias_work` change queue, so a steady state does not call this
/// at all — it costs one 0.09ms query against the small `registry_entries` mirror.
///
/// The `ORDER BY` is a total order within the registry — (canonical_id, parent) is the
/// plan row's identity there — so paging can neither repeat nor skip a row, and the
/// sequence is identical on both backends. Only keys are returned: the caller loads
/// each primary through the audited `getNameByTokenIdAndRegistry` point read, one
/// indexed lookup per row CREATED (once in that row's lifetime), never per batch.
pub fn aliasPlanBatch(
    db: *Database,
    allocator: std.mem.Allocator,
    protocol: models.Protocol,
    registry: Address,
    /// When set, plan only this label: the rows a single registration owes, which is
    /// O(live parents) rather than a pass over the registry.
    label: ?[]const u8,
    /// Chain time the edge-expiry test is evaluated at.
    now: i64,
    cursor: AliasPlanCursor,
    limit: usize,
) ![]AliasPlanKey {
    try db.namesBarrier();

    const SQL_HEAD =
        \\SELECT p.canonical_id, le.edge_parent_name, le.edge_parent_namehash
        \\FROM names p
        \\JOIN (
    ;
    const SQL_MID =
        \\) le ON le.edge_registry = p.registry
        \\WHERE p.protocol = ? AND p.registry = ? AND p.is_alias = 0 AND p.is_reachable = 1
        \\  AND le.edge_parent_namehash <> p.parent_namehash
        \\  AND NOT EXISTS (
        \\    SELECT 1 FROM names a
        \\    WHERE a.protocol = p.protocol AND a.registry = p.registry
        \\      AND a.canonical_id = p.canonical_id AND a.parent_namehash = le.edge_parent_namehash
        \\  )
    ;
    // Two bounds, not one. The row-value comparison is the exact one, but Postgres cannot
    // push it through the join into the index scan on `p` — measured 3.2s per page. The
    // scalar `p.canonical_id >= ?` is redundant logically and decisive practically: it makes
    // the scan an index range starting AT the cursor (0.9ms). Same bind value for both.
    const SQL_CURSOR = "  AND p.canonical_id >= ? AND (p.canonical_id, le.edge_parent_namehash) > (?, ?)\n";
    const SQL_ONE_LABEL = "  AND p.canonical_id = ?\n";
    const SQL_TAIL = "ORDER BY p.canonical_id ASC, le.edge_parent_namehash ASC\nLIMIT ?";

    const EDGES_FOR_ONE = LIVE_PARENT_EDGES ++ "\n  AND r.address = ?";
    const BASE = SQL_HEAD ++ EDGES_FOR_ONE ++ "\n" ++ SQL_MID ++ "\n";
    const sql = if (label != null)
        BASE ++ SQL_ONE_LABEL ++ SQL_TAIL
    else if (cursor.isSet())
        BASE ++ SQL_CURSOR ++ SQL_TAIL
    else
        BASE ++ SQL_TAIL;

    var q = try Query.initCached(db, sql);
    defer q.deinit();
    // Bind order follows the assembled text: the edge subquery's (protocol, address)
    // sit inside the JOIN, ahead of the outer WHERE's.
    try q.bindTextStatic(protocol.toString());
    try q.bindInt64(now);
    try q.bindAddress(registry);
    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(registry);
    if (label) |l| {
        try q.bindText(l);
    } else if (cursor.isSet()) {
        try q.bindText(cursor.canonical_id.?);
        try q.bindText(cursor.canonical_id.?);
        try q.bindText(cursor.parent_namehash.?);
    }
    try q.bindInt64(@intCast(limit));

    var out: std.ArrayList(AliasPlanKey) = .empty;
    errdefer {
        for (out.items) |k| {
            allocator.free(k.canonical_id);
            allocator.free(k.parent_name);
        }
        out.deinit(allocator);
    }
    while (try q.step()) {
        const canonical_hex = q.getTextSlice(0) orelse continue;
        const parent_name = q.getTextSlice(1) orelse continue;
        const parent_nh_hex = q.getTextSlice(2) orelse continue;
        const parent_namehash = Hash.fromHex(parent_nh_hex) catch continue;
        const canonical_copy = try allocator.dupe(u8, canonical_hex);
        errdefer allocator.free(canonical_copy);
        const parent_copy = try allocator.dupe(u8, parent_name);
        errdefer allocator.free(parent_copy);
        try out.append(allocator, .{
            .registry = registry,
            .canonical_id = canonical_copy,
            .parent_name = parent_copy,
            .parent_namehash = parent_namehash,
        });
    }
    return out.toOwnedSlice(allocator);
}

/// Build the one alias row `key` asks for, or null when it cannot be built (which
/// is not an error).
///
/// Lives here rather than in the indexer driver so the definition and its guards are
/// in one place and the tests exercise the same code the sync loop does. The caller
/// writes the row through the `insertName` chokepoint, which is what stamps
/// `is_normalized` and `is_reachable`.
///
/// Every field but the name and its parent is copied verbatim from the primary,
/// including `created_block` / `created_at` (the label was minted once) and
/// `updated_block` / `updated_at`. Copying those rather than stamping the current
/// block is what makes the derivation a pure function of database state: a replay
/// running at a different block still produces identical rows.
///
/// The returned row owns its `name`, `label` and `parent_name`; free it with
/// `models.Name.deinit`. `wrapper_fuses` / `v1_label_hash` are nulled rather than
/// shared with the primary — they are V1/wrapper fields, always null on the V2 rows
/// this runs over, and aliasing the primary's allocations would double-free.
pub fn buildAliasRow(
    db: *Database,
    allocator: std.mem.Allocator,
    protocol: models.Protocol,
    key: AliasPlanKey,
) !?models.Name {
    const canonical_id = parseHexU256(key.canonical_id) orelse return null;

    // `is_alias = 0`, deterministic pick — the audited point read.
    const primary_row = (try db.getNameByTokenIdAndRegistry(canonical_id, key.registry)) orelse return null;
    var primary = primary_row;
    defer primary.deinit(allocator);
    if (primary.protocol != protocol or !primary.is_reachable) return null;
    const label = primary.label orelse return null;

    const full_name = try ens_name.join(allocator, label, key.parent_name);
    errdefer allocator.free(full_name);
    const namehash = try hash_mod.namehash(allocator, full_name);

    // NEVER write over a primary row. The names upsert conflicts on
    // (protocol, namehash), so an alias whose node already belongs to an
    // `is_alias = 0` row would flip that row's flag — and `deleteStaleAliases`
    // removes rows by that flag, while a primary owns `events` / `registrations` rows
    // keyed on its namehash that only a full replay could rebuild. The collision is
    // reachable, not hypothetical: a parent that repointed from one registry to
    // another keeps its old child rows, so if the same label exists in both
    // registries the derived name lands on one of them. Declining leaves that row
    // exactly as it is, which is the right answer for it.
    if (namehash.eql(primary.namehash)) {
        allocator.free(full_name);
        return null;
    }
    if (try primaryExistsAt(db, protocol, namehash)) {
        allocator.free(full_name);
        return null;
    }

    const label_copy = try allocator.dupe(u8, label);
    errdefer allocator.free(label_copy);
    const parent_copy = try allocator.dupe(u8, key.parent_name);
    errdefer allocator.free(parent_copy);

    var alias = primary;
    alias.name = full_name;
    alias.namehash = namehash;
    alias.label = label_copy;
    alias.parent_name = parent_copy;
    alias.parent_namehash = key.parent_namehash;
    alias.is_alias = true;
    alias.wrapper_fuses = null;
    alias.v1_label_hash = null;
    return alias;
}

/// True when `namehash` is already held by a NON-alias row — the one hard guarantee
/// the whole derivation rests on. See `buildAliasRow`.
pub fn primaryExistsAt(db: *Database, protocol: models.Protocol, namehash: Hash) !bool {
    try db.namesBarrier();
    var q = try Query.initCached(
        db,
        "SELECT 1 FROM names WHERE protocol = ? AND namehash = ? AND is_alias = 0 LIMIT 1",
    );
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindHash(namehash);
    return try q.step();
}

fn parseHexU256(hex: []const u8) ?u256 {
    const body = if (std.mem.startsWith(u8, hex, "0x")) hex[2..] else hex;
    return std.fmt.parseInt(u256, body, 16) catch null;
}

/// Every alias row the definition no longer contains, in ONE statement for the
/// whole protocol.
///
/// Two clauses, both necessary, neither able to touch an `is_alias = 0` row:
///
///   1. the row's own parent edge is no longer live — the parent repointed, cleared
///      its pointer, or stopped resolving;
///   2. the row has no reachable primary left — the label was soft-deleted by
///      `LabelUnregistered`, orphaned by an ancestor repoint, or hard-deleted by
///      `NameBurned`. This clause is the one that still fires for a registry
///      orphaned ENTIRELY (no live edge at all), where leaving the rows would
///      present them as the only visible copies of names that no longer resolve.
///
/// Deleted, not soft-deleted. An alias row is a derived artifact: it carries no
/// events, no `registrations` row, and nothing a user set — everything in it is
/// recomputed from its primary, and if the edge returns the next pass mints it
/// again. That makes removal both the honest answer (the FQDN stopped resolving)
/// and the one that keeps the derivation a pure function of state: there is no
/// `unreachable_since` / `updated_at` to invent, so a replay lands on exactly the
/// rows a live run did regardless of which block either was at. Primary rows use a
/// soft delete for the opposite reason — they own the history.
///
/// Set-based on purpose. An earlier per-registry form bound one parameter per live
/// parent, so it had to cap the parent count — silently skipping cleanup above the
/// cap, which is a wrong answer rather than a slow one — and to enumerate candidate
/// registries in Zig first. Expressing the live edge set as a subquery removes the
/// cap, the enumeration and the per-registry statements together: one statement per
/// pass at any parent count.
///
/// The predicate is deliberately free of outer-table qualification: the reorg undo
/// capture re-uses it inside `... FROM "names" t WHERE (<predicate>)`, where a
/// `names.`-qualified reference has no FROM entry and the statement fails to
/// prepare. Unqualified `registry` / `parent_namehash` / `canonical_id` resolve to
/// the outer row in both contexts because every subquery aliases its tables. The
/// row-value `NOT IN` form is verified identical on SQLite and Postgres, and its
/// NULL behaviour falls the safe way: a NULL anywhere yields NULL, which deletes
/// nothing.
pub fn deleteStaleAliases(db: *Database, protocol: models.Protocol, now: i64) !u64 {
    return deleteStaleAliasesScoped(db, protocol, null, null, now);
}

/// `deleteStaleAliases` restricted to one registry — what the change queue runs, so the
/// cost is that registry's alias rows rather than every alias row in the database.
/// `null` scopes to everything, which is what the sweep and `--backfill` want.
pub fn deleteStaleAliasesScoped(
    db: *Database,
    protocol: models.Protocol,
    registry: ?Address,
    /// When set, restrict to one label as well. A registration's work item only needs its
    /// own label's rows checked; scanning the registry's whole derived set instead measured
    /// 13.1s on a registry holding 1.4M of them. An edge change has to take the wider scan
    /// — every row in the registry may have gone stale — which is why both scopes exist.
    label: ?[]const u8,
    /// Chain time the edge-expiry test is evaluated at.
    now: i64,
) !u64 {
    try db.namesBarrier();

    // Two clauses, both scoped so the predicate stands on its own binds.
    // The "no reachable primary left" clause is an EXISTS correlated on the row's own
    // registry, not a NOT IN over every primary in the database. The NOT IN form could not
    // use an index for the scoped case — the inner set was every primary row — and did not
    // return within two minutes on 1.6M names. The EXISTS probes
    // idx_names_registry_canonical once per alias row instead.
    //
    // The outer row is aliased `t`, and that is not cosmetic. The reorg undo capture
    // re-uses this predicate verbatim inside `... FROM "names" t WHERE (<predicate>)`, so
    // the outer reference has to be spelled `t.` — it cannot be `names.` (no FROM entry
    // there) and it cannot be unqualified, because `registry` / `canonical_id` inside the
    // correlated EXISTS would then bind to the inner table. The DELETE is therefore written
    // `DELETE FROM names AS t`, which both backends accept, so capture and delete see
    // exactly the same rows. Verified on SQLite and Postgres.
    const BODY =
        "t.is_alias = 1 AND (\n" ++
        "  (t.registry, t.parent_namehash) NOT IN (\n" ++
        "    SELECT le.edge_registry, le.edge_parent_namehash FROM (\n" ++
        LIVE_PARENT_EDGES ++ "\n" ++
        "    ) le\n" ++
        "  )\n" ++
        "  OR NOT EXISTS (\n" ++
        "    SELECT 1 FROM names pr\n" ++
        "    WHERE pr.protocol = ? AND pr.registry = t.registry\n" ++
        "      AND pr.canonical_id = t.canonical_id AND pr.is_alias = 0 AND pr.is_reachable = 1\n" ++
        "  )\n" ++
        ")";
    const WHERE_ALL = "t.protocol = ? AND " ++ BODY;
    const WHERE_ONE = "t.protocol = ? AND t.registry = ? AND " ++ BODY;
    const WHERE_LABEL = "t.protocol = ? AND t.registry = ? AND t.canonical_id = ? AND " ++ BODY;

    const Binder = struct {
        protocol: models.Protocol,
        registry: ?Address,
        label: ?[]const u8,
        now: i64,
        pub fn bind(self: @This(), cq: *Query) !void {
            try cq.bindText(self.protocol.toString());
            if (self.registry) |r| try cq.bindAddressBuf(r);
            if (self.label) |l| try cq.bindText(l);
            // the edge subquery: protocol, then the expiry evaluation time
            try cq.bindText(self.protocol.toString());
            try cq.bindInt64(self.now);
            try cq.bindText(self.protocol.toString());
        }
    };
    const where = if (label != null) WHERE_LABEL else if (registry != null) WHERE_ONE else WHERE_ALL;
    try reorg_undo.captureWhereBinder(db, "names", "D", where, Binder{
        .protocol = protocol,
        .registry = registry,
        .label = label,
        .now = now,
    });

    var q = try Query.initCached(db, if (label != null)
        "DELETE FROM names AS t WHERE " ++ WHERE_LABEL
    else if (registry != null)
        "DELETE FROM names AS t WHERE " ++ WHERE_ONE
    else
        "DELETE FROM names AS t WHERE " ++ WHERE_ALL);
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    if (registry) |r| try q.bindAddress(r);
    if (label) |l| try q.bindText(l);
    try q.bindTextStatic(protocol.toString());
    try q.bindInt64(now);
    try q.bindTextStatic(protocol.toString());
    try q.exec();
    return @intCast(q.changes());
}

// ============================================================================
// Change queue
// ============================================================================
// The derivation is defined as a fixpoint, but recomputing it from scratch costs a
// pass over the data, so a steady state must be driven by CHANGES. This queue is that
// driver: the events that can alter a registry's owed set enqueue it, and the pass
// only looks at queued registries.
//
// It is scheduling state, never a source of truth. Losing it costs latency, not
// correctness — the startup and periodic sweeps re-enqueue every multi-parent registry,
// and `--backfill` ignores the queue and converges by enumeration. That is deliberate:
// a missed enqueue must degrade to "derived late", never to "derived wrong".

/// Mark every label in `registry` as needing derivation — what an EDGE change enqueues,
/// since a parent appearing or leaving changes what every label in the registry owes.
///
/// Rewinds the cursor and clears `done`, so the next pass re-derives from the start. That
/// is a full pass over the registry, which is inherent: every label owes a new name. The
/// row budget chunks it across batches.
///
/// If the registry is already mid-pass, `restart` is set as well: the sweep in flight
/// finishes, then one more runs from the beginning, so a change landing BEHIND the cursor
/// is not missed and a steady stream of changes cannot starve the scan either.
pub fn enqueueAliasWork(db: *Database, protocol: models.Protocol, registry: Address, block_number: u64) !void {
    if (registry.isZero()) return;
    var q = try Query.initCached(db,
        \\INSERT INTO alias_work (protocol, registry, canonical_id, cursor_canonical_id, cursor_parent_namehash, done, restart, enqueued_block)
        \\VALUES (?, ?, '', NULL, NULL, 0, 0, ?)
        \\ON CONFLICT(protocol, registry, canonical_id) DO UPDATE SET
        \\  done = 0, restart = 1, cursor_canonical_id = NULL, cursor_parent_namehash = NULL
    );
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(registry);
    try q.bindInt64(@intCast(block_number));
    try q.exec();
}

/// Mark ONE label as needing derivation — what a registration, burn or unregistration
/// enqueues.
///
/// This is the difference between a bounded indexer and an unbounded one. A registration
/// in a shared registry owes one row per other live parent, so scoping the work item to
/// the label makes it an indexed point operation (0.9ms) instead of a pass over the
/// registry (12.2s at 200k labels — both measured). Conflicts do nothing: an item already
/// queued for this label already covers it.
pub fn enqueueAliasLabelWork(
    db: *Database,
    protocol: models.Protocol,
    registry: Address,
    canonical_id: u256,
    block_number: u64,
) !void {
    if (registry.isZero()) return;
    var buf: [66]u8 = undefined;
    const canonical_hex = formatU256HexBuf(&buf, canonical_id);
    var q = try Query.initCached(db,
        \\INSERT INTO alias_work (protocol, registry, canonical_id, done, restart, enqueued_block)
        \\VALUES (?, ?, ?, 0, 0, ?)
        \\ON CONFLICT(protocol, registry, canonical_id) DO UPDATE SET done = 0
    );
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(registry);
    try q.bindText(canonical_hex);
    try q.bindInt64(@intCast(block_number));
    try q.exec();
}

/// One pending work item. `label` is null for a whole-registry item.
pub const AliasWorkItem = struct {
    registry: Address,
    label: ?[]u8,
    cursor: AliasPlanCursor,
    restart: bool,
    canonical_buf: ?[]u8,
    parent_buf: ?[]u8,

    pub fn deinit(self: *AliasWorkItem, allocator: std.mem.Allocator) void {
        if (self.label) |b| allocator.free(b);
        if (self.canonical_buf) |b| allocator.free(b);
        if (self.parent_buf) |b| allocator.free(b);
    }
};

/// The next `limit` pending items, lowest (registry, label) first so a pass processes them
/// in the same order on every run and on both backends. `done = 1` rows are invisible here
/// — they are converged whole-registry rows kept only so the sweep can re-assert them
/// without rewinding.
pub fn takeAliasWork(
    db: *Database,
    allocator: std.mem.Allocator,
    protocol: models.Protocol,
    limit: usize,
) ![]AliasWorkItem {
    var q = try Query.initCached(db,
        \\SELECT registry, canonical_id, cursor_canonical_id, cursor_parent_namehash, restart
        \\FROM alias_work WHERE protocol = ? AND done = 0
        \\ORDER BY registry ASC, canonical_id ASC LIMIT ?
    );
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindInt64(@intCast(limit));

    var out: std.ArrayList(AliasWorkItem) = .empty;
    errdefer {
        for (out.items) |*it| it.deinit(allocator);
        out.deinit(allocator);
    }
    while (try q.step()) {
        const registry_hex = q.getTextSlice(0) orelse continue;
        const registry = Address.fromHex(registry_hex) catch continue;
        var item = AliasWorkItem{
            .registry = registry,
            .label = null,
            .cursor = .{},
            .restart = q.getBool(4),
            .canonical_buf = null,
            .parent_buf = null,
        };
        errdefer item.deinit(allocator);
        if (q.getTextSlice(1)) |lbl| {
            if (lbl.len > 0) item.label = try allocator.dupe(u8, lbl);
        }
        if (q.getTextSlice(2)) |c| {
            if (q.getTextSlice(3)) |pnh| {
                item.canonical_buf = try allocator.dupe(u8, c);
                item.parent_buf = try allocator.dupe(u8, pnh);
                item.cursor = .{ .canonical_id = item.canonical_buf, .parent_namehash = item.parent_buf };
            }
        }
        try out.append(allocator, item);
    }
    return out.toOwnedSlice(allocator);
}

pub fn freeAliasWork(allocator: std.mem.Allocator, items: []AliasWorkItem) void {
    for (items) |*it| it.deinit(allocator);
    allocator.free(items);
}

/// Persist where a bounded pass stopped, so the next batch resumes instead of rescanning.
pub fn saveAliasWorkCursorHex(
    db: *Database,
    protocol: models.Protocol,
    registry: Address,
    canonical_id: []const u8,
    parent_namehash_hex: []const u8,
) !void {
    var q = try Query.initCached(db,
        \\UPDATE alias_work SET cursor_canonical_id = ?, cursor_parent_namehash = ?
        \\WHERE protocol = ? AND registry = ? AND canonical_id = ''
    );
    defer q.deinit();
    try q.bindText(canonical_id);
    try q.bindText(parent_namehash_hex);
    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(registry);
    try q.exec();
}

/// An item finished. A label item leaves the queue outright. A whole-registry item is kept
/// with `done = 1` — that is what lets the periodic sweep re-assert it without rewinding a
/// converged registry — unless it was re-enqueued midway, in which case it rewinds for one
/// more sweep. Returns true when the item is now considered converged.
pub fn completeAliasWork(
    db: *Database,
    protocol: models.Protocol,
    registry: Address,
    label: ?[]const u8,
    had_restart: bool,
) !bool {
    if (label) |l| {
        var q = try Query.initCached(db, "DELETE FROM alias_work WHERE protocol = ? AND registry = ? AND canonical_id = ?");
        defer q.deinit();
        try q.bindTextStatic(protocol.toString());
        try q.bindAddress(registry);
        try q.bindText(l);
        try q.exec();
        return true;
    }
    if (had_restart) {
        var q = try Query.initCached(db,
            \\UPDATE alias_work SET restart = 0, done = 0, cursor_canonical_id = NULL, cursor_parent_namehash = NULL
            \\WHERE protocol = ? AND registry = ? AND canonical_id = ''
        );
        defer q.deinit();
        try q.bindTextStatic(protocol.toString());
        try q.bindAddress(registry);
        try q.exec();
        return false;
    }
    var q = try Query.initCached(db,
        \\UPDATE alias_work SET done = 1, restart = 0 WHERE protocol = ? AND registry = ? AND canonical_id = ''
    );
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(registry);
    try q.exec();
    return true;
}

/// Assert a whole-registry item for every registry the definition could owe rows for,
/// WITHOUT disturbing one that has already converged.
///
/// The self-heal: a missed enqueue is repaired here rather than leaving a name permanently
/// underived, which is what turns "we forgot a hook" from a correctness bug into a bounded
/// delay. `DO NOTHING` is the load-bearing part — re-deriving a converged 200k-label
/// registry from the start costs a full pass, while leaving its `done = 1` row alone costs
/// nothing. Reads only the small `registry_entries` mirror (0.17ms measured).
pub fn sweepAliasCandidates(db: *Database, protocol: models.Protocol, block_number: u64) !usize {
    var q = try Query.initCached(db,
        \\SELECT subregistry FROM registry_entries
        \\WHERE protocol = ? AND subregistry != '0x0000000000000000000000000000000000000000'
        \\GROUP BY subregistry HAVING COUNT(*) > 1 ORDER BY subregistry
    );
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    var addrs: std.ArrayList(Address) = .empty;
    defer addrs.deinit(db.allocator);
    while (try q.step()) {
        const hex = q.getTextSlice(0) orelse continue;
        try addrs.append(db.allocator, Address.fromHex(hex) catch continue);
    }
    for (addrs.items) |a| {
        var ins = try Query.initCached(db,
            \\INSERT INTO alias_work (protocol, registry, canonical_id, done, restart, enqueued_block)
            \\VALUES (?, ?, '', 0, 0, ?)
            \\ON CONFLICT(protocol, registry, canonical_id) DO NOTHING
        );
        defer ins.deinit();
        try ins.bindTextStatic(protocol.toString());
        try ins.bindAddress(a);
        try ins.bindInt64(@intCast(block_number));
        try ins.exec();
    }
    return addrs.items.len;
}

/// Force a full re-derivation of every candidate: `--backfill` only, where the queue was
/// never built and the point is to converge from scratch. Also covers the registries that
/// still HOLD derived rows, so a registry that has dropped below two live parents still
/// gets its rows cleaned up.
pub fn enqueueAllAliasCandidates(db: *Database, protocol: models.Protocol, block_number: u64) !usize {
    try db.namesBarrier();
    var count: usize = 0;
    var addrs: std.ArrayList(Address) = .empty;
    defer addrs.deinit(db.allocator);
    {
        var q = try Query.initCached(db,
            \\SELECT subregistry FROM registry_entries
            \\WHERE protocol = ? AND subregistry != '0x0000000000000000000000000000000000000000'
            \\GROUP BY subregistry HAVING COUNT(*) > 1 ORDER BY subregistry
        );
        defer q.deinit();
        try q.bindTextStatic(protocol.toString());
        while (try q.step()) {
            const hex = q.getTextSlice(0) orelse continue;
            try addrs.append(db.allocator, Address.fromHex(hex) catch continue);
        }
    }
    {
        var q = try Query.initCached(db,
            \\SELECT DISTINCT registry FROM names WHERE protocol = ? AND is_alias = 1 ORDER BY registry
        );
        defer q.deinit();
        try q.bindTextStatic(protocol.toString());
        while (try q.step()) {
            const hex = q.getTextSlice(0) orelse continue;
            try addrs.append(db.allocator, Address.fromHex(hex) catch continue);
        }
    }
    for (addrs.items) |a| {
        try enqueueAliasWork(db, protocol, a, block_number);
        count += 1;
    }
    return count;
}
