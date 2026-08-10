//! Name write / mutation operations (insert + all update/clear/gc paths).
//!
//! Split out of names.zig. Depends only on the shared storage primitives + the
//! pure helpers in names_common (aliased below); names.zig re-exports every public
//! function here as `pub const f = names_write.f;`, so `names.f` / `db.f` callers
//! (and the indexer's `names_storage.f` write sites) are unchanged.

const std = @import("std");
const zsys = @import("../utils/system.zig");
const db_module = @import("database.zig");
const Database = db_module.Database;
const Query = db_module.Query;
const models = @import("../types/models.zig");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;
const reorg_undo = @import("reorg_undo.zig");
const names_common = @import("names_common.zig");
const safeU64ToI64 = names_common.safeU64ToI64;
const formatU256HexBuf = names_common.formatU256HexBuf;

// The names upsert, factored so the single-row path and the bulk-flush batch
// path share one SQL definition and one bind sequence — they cannot drift.
// NOTE the tail's deliberate asymmetries: created_block/created_at are NOT
// updated on conflict (first-sighting preservation), and resolved_address
// COALESCEs so a null in the incoming row keeps the existing value.
const NAMES_UPSERT_HEAD =
    \\INSERT INTO names
    \\(namehash, name, label, label_hash, parent_name, parent_namehash, protocol,
    \\ registry, owner, registrant, resolver, token_id, canonical_id, token_version, expiry,
    \\ registry_locked, migrated, created_block, created_at, registered_at, updated_block, updated_at,
    \\ is_wrapped, wrapper_fuses, wrapper_expiry, is_v1_name, v1_label_hash,
    \\ is_reachable, unreachable_since, ttl, is_legacy, resolved_address, is_normalized)
    \\VALUES
;

const NAMES_UPSERT_TUPLE = "(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";

/// 33 bound columns per row.
const NAMES_UPSERT_PARAMS = 33;

const NAMES_UPSERT_TAIL =
    \\ON CONFLICT(protocol, namehash) DO UPDATE SET
    \\ name = excluded.name,
    \\ label = excluded.label,
    \\ label_hash = excluded.label_hash,
    \\ parent_name = excluded.parent_name,
    \\ parent_namehash = excluded.parent_namehash,
    \\ registry = excluded.registry,
    \\ owner = excluded.owner,
    \\ registrant = excluded.registrant,
    \\ resolver = excluded.resolver,
    \\ token_id = excluded.token_id,
    \\ canonical_id = excluded.canonical_id,
    \\ token_version = excluded.token_version,
    \\ expiry = excluded.expiry,
    \\ registry_locked = excluded.registry_locked,
    \\ migrated = excluded.migrated,
    \\ registered_at = excluded.registered_at,
    \\ updated_block = excluded.updated_block,
    \\ updated_at = excluded.updated_at,
    \\ is_wrapped = excluded.is_wrapped,
    \\ wrapper_fuses = excluded.wrapper_fuses,
    \\ wrapper_expiry = excluded.wrapper_expiry,
    \\ is_v1_name = excluded.is_v1_name,
    \\ v1_label_hash = excluded.v1_label_hash,
    \\ is_reachable = excluded.is_reachable,
    \\ unreachable_since = excluded.unreachable_since,
    \\ ttl = excluded.ttl,
    \\ is_legacy = excluded.is_legacy,
    \\ resolved_address = COALESCE(excluded.resolved_address, names.resolved_address),
    \\ is_normalized = excluded.is_normalized
;

pub fn insertName(db: *Database, name: models.Name) !void {
    try reorg_undo.captureUpsert(db, "names", .{ name.protocol, name.namehash });

    // Arena declared before the statement so bound SQLITE_STATIC pointers
    // outlive it (LIFO defers).
    var arena = std.heap.ArenaAllocator.init(db.allocator);
    defer arena.deinit();

    var q = try Query.initCached(db, NAMES_UPSERT_HEAD ++ " " ++ NAMES_UPSERT_TUPLE ++ "\n" ++ NAMES_UPSERT_TAIL);
    defer q.deinit();

    try bindNameValues(&q, name, arena.allocator());
    try q.exec();
}

/// Bind one name's 33 upsert values in NAMES_UPSERT_HEAD column order. Shared
/// by the single-row and batch paths. All text binds are static: the caller's
/// `name` strings must stay alive through exec (they do at every call site —
/// live handlers exec before returning, the flush batch execs while the write
/// buffer still owns them), and derived hex goes into `scratch`, which the
/// caller keeps alive past exec. Static binds keep the batch path clear of
/// the statement's MAX_BOUND_STRINGS tracked-copy cap.
fn bindNameValues(q: *Query, name: models.Name, scratch: std.mem.Allocator) !void {
    const namehash_buf = try scratch.create([66]u8);
    try q.bindTextStatic(name.namehash.toHexBuf(namehash_buf));
    if (name.name) |v| try q.bindTextStatic(v) else try q.bindNull();
    if (name.label) |v| try q.bindTextStatic(v) else try q.bindNull();
    const label_hash_buf = try scratch.create([66]u8);
    try q.bindTextStatic(name.label_hash.toHexBuf(label_hash_buf));
    // parent_name is NOT NULL: a root child is the empty string, never SQL NULL.
    // Coerce here so the schema invariant holds for every caller (a null would
    // otherwise abort the insert on the NOT NULL constraint). See ens_name.ROOT_PARENT.
    try q.bindTextStatic(name.parent_name orelse "");
    const parent_hash_buf = try scratch.create([66]u8);
    try q.bindTextStatic(name.parent_namehash.toHexBuf(parent_hash_buf));
    try q.bindTextStatic(name.protocol.toString());
    const registry_buf = try scratch.create([42]u8);
    try q.bindTextStatic(name.registry.toHexBuf(registry_buf));
    const owner_buf = try scratch.create([42]u8);
    try q.bindTextStatic(name.owner.toHexBuf(owner_buf));
    const registrant_buf = try scratch.create([42]u8);
    try q.bindTextStatic(name.registrant.toHexBuf(registrant_buf));
    const resolver_buf = try scratch.create([42]u8);
    try q.bindTextStatic(name.resolver.toHexBuf(resolver_buf));
    const token_id_buf = try scratch.create([66]u8);
    try q.bindTextStatic(formatU256HexBuf(token_id_buf, name.token_id));
    const canonical_id_buf = try scratch.create([66]u8);
    try q.bindTextStatic(formatU256HexBuf(canonical_id_buf, name.canonical_id));
    try q.bindInt64(@intCast(name.token_version));
    try q.bindInt64(safeU64ToI64(name.expiry));
    try q.bindInt(if (name.registry_locked) 1 else 0);
    try q.bindInt(if (name.migrated) 1 else 0);
    try q.bindInt64(@intCast(name.created_block));
    try q.bindInt64(name.created_at);
    try q.bindInt64(name.registered_at);
    try q.bindInt64(@intCast(name.updated_block));
    try q.bindInt64(name.updated_at);
    try q.bindInt(if (name.is_wrapped) 1 else 0);
    if (name.wrapper_fuses) |v| try q.bindTextStatic(v) else try q.bindNull();
    try q.bindOptionalInt64(name.wrapper_expiry);
    try q.bindInt(if (name.is_v1_name) 1 else 0);
    if (name.v1_label_hash) |v| try q.bindTextStatic(v) else try q.bindNull();
    try q.bindInt(if (name.is_reachable) 1 else 0);
    try q.bindOptionalInt64(name.unreachable_since);
    try q.bindOptionalInt64(if (name.ttl) |t| safeU64ToI64(t) else null);
    try q.bindInt(if (name.is_legacy) 1 else 0);
    if (name.resolved_address) |addr| {
        const resolved_buf = try scratch.create([42]u8);
        try q.bindTextStatic(addr.toHexBuf(resolved_buf));
    } else {
        try q.bindNull();
    }
    try q.bindInt(if (name.is_normalized) 1 else 0);
}

/// Rows per multi-row names upsert: 33 params each → 990 params, under even
/// the pre-3.32 SQLite SQLITE_MAX_VARIABLE_NUMBER floor of 999.
const NAMES_BATCH_ROWS = 30;

/// Bulk-flush insert path: multi-row upserts instead of one round trip per
/// name — same SQL head/tail as `insertName`, so semantics are identical row
/// for row (incl. created_* preservation and the resolved_address COALESCE).
/// Duplicates by (protocol, namehash) within the slice are deduped keep-LAST
/// (equal to sequential last-write-wins; Postgres rejects intra-statement
/// conflict-key repeats). Per-row reorg capture mirrors `insertName`.
pub fn insertNamesBatch(db: *Database, names_slice: []const models.Name) !void {
    if (names_slice.len == 0) return;

    const DedupKey = struct { protocol: models.Protocol, namehash: [32]u8 };
    var seen = std.AutoHashMap(DedupKey, void).init(db.allocator);
    defer seen.deinit();
    try seen.ensureTotalCapacity(@intCast(names_slice.len));

    // Reverse scan keep-first == forward keep-last. Order among distinct keys
    // is irrelevant: independent rows, one statement.
    var deduped: std.ArrayList(*const models.Name) = .empty;
    defer deduped.deinit(db.allocator);
    try deduped.ensureTotalCapacity(db.allocator, names_slice.len);
    var i: usize = names_slice.len;
    while (i > 0) {
        i -= 1;
        const name = &names_slice[i];
        const gop = seen.getOrPutAssumeCapacity(.{ .protocol = name.protocol, .namehash = name.namehash.bytes });
        if (gop.found_existing) continue;
        deduped.appendAssumeCapacity(name);
    }

    var start: usize = 0;
    while (start < deduped.items.len) {
        const rows = @min(NAMES_BATCH_ROWS, deduped.items.len - start);
        const chunk = deduped.items[start .. start + rows];

        for (chunk) |name| {
            try reorg_undo.captureUpsert(db, "names", .{ name.protocol, name.namehash });
        }

        var sql: std.ArrayList(u8) = .empty;
        defer sql.deinit(db.allocator);
        try sql.appendSlice(db.allocator, NAMES_UPSERT_HEAD);
        for (0..rows) |r| {
            try sql.appendSlice(db.allocator, if (r == 0) " " else ", ");
            try sql.appendSlice(db.allocator, NAMES_UPSERT_TUPLE);
        }
        try sql.append(db.allocator, '\n');
        try sql.appendSlice(db.allocator, NAMES_UPSERT_TAIL);

        // Declared before the Query so hex strings outlive exec (LIFO defers).
        var arena = std.heap.ArenaAllocator.init(db.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();

        var q = try Query.initCached(db, sql.items);
        defer q.deinit();
        for (chunk) |name| {
            try bindNameValues(&q, name.*, scratch);
        }
        try q.exec();
        start += rows;
    }
}

/// Update the `is_legacy` flag on an existing name row. Called by V1 Registry
/// handlers to track whether the most recent update came from the legacy
/// pre-2020 Registry (0x314159…) or the canonical post-2020 Registry.
/// No-op when no row exists for `namehash`.
pub fn updateNameIsLegacy(db: *Database, namehash: Hash, is_legacy: bool) !void {
    try reorg_undo.captureWhere(db, "names", "U", "namehash = ?", .{namehash});
    var q = try Query.initCached(db, "UPDATE names SET is_legacy = ?, updated_at = ? WHERE namehash = ?");
    defer q.deinit();
    try q.bindInt(if (is_legacy) 1 else 0);
    try q.bindInt64(zsys.timestamp());
    try q.bindHashBuf(namehash);
    try q.exec();
}

/// Update name expiry (for renewals)
pub fn updateNameExpiry(db: *Database, namehash: Hash, expiry: u64) !void {
    try reorg_undo.captureWhere(db, "names", "U", "namehash = ?", .{namehash});
    var q = try Query.initCached(db, "UPDATE names SET expiry = ?, updated_at = ? WHERE namehash = ?");
    defer q.deinit();

    try q.bindInt64(safeU64ToI64(expiry));
    try q.bindInt64(zsys.timestamp());
    try q.bindHashBuf(namehash);
    try q.exec();
}

/// Expiry update for BaseRegistrar NameRenewed (V1 .eth 2LDs only). Wrapped rows
/// store the grace-inclusive wrapper value (registrar expires + 90d); writing the
/// bare registrar value there would silently shrink expiryDate by the grace period
/// on direct registrar renewals, where no ExpiryExtended fires to re-sync it.
/// The `> 0` guard preserves the safeU64ToI64 never-expires sentinel (0) — grace
/// must not turn it into a 1970 expiry. The protocol predicate keeps a
/// same-namehash V2 row from being stomped (names is UNIQUE(protocol, namehash)).
pub fn updateV1RenewalExpiry(db: *Database, namehash: Hash, expires: u64) !void {
    try reorg_undo.captureWhere(db, "names", "U", "namehash = ? AND protocol = 'v1'", .{namehash});
    var q = try Query.initCached(db, "UPDATE names SET expiry = CASE WHEN is_wrapped = 1 AND ? > 0 THEN ? + 7776000 ELSE ? END, updated_at = ? WHERE namehash = ? AND protocol = 'v1'");
    defer q.deinit();

    // Within 90d of i64 max the grace addition would overflow (PG errors,
    // SQLite degrades to REAL); such a value means never-expires in practice.
    const v = safeU64ToI64(expires);
    const base = if (v > std.math.maxInt(i64) - 7776000) 0 else v;
    try q.bindInt64(base);
    try q.bindInt64(base);
    try q.bindInt64(base);
    try q.bindInt64(zsys.timestamp());
    try q.bindHashBuf(namehash);
    try q.exec();
}

/// Update name owner (for transfers)
pub fn updateNameOwner(db: *Database, namehash: Hash, new_owner: Address) !void {
    try reorg_undo.captureWhere(db, "names", "U", "namehash = ?", .{namehash});
    var q = try Query.initCached(db, "UPDATE names SET owner = ?, updated_at = ? WHERE namehash = ?");
    defer q.deinit();

    try q.bindAddressBuf(new_owner);
    try q.bindInt64(zsys.timestamp());
    try q.bindHashBuf(namehash);
    try q.exec();
}

/// Mark a V1 name as migrated to V2, updating owner to the migration controller.
/// Sets migrated=true so the API can distinguish live V1 names from those that
/// have been transferred to a V1→V2 migration controller (which is functionally
/// "no longer ownable on V1").
pub fn markNameMigrated(db: *Database, namehash: Hash, controller: Address) !void {
    try reorg_undo.captureWhere(db, "names", "U", "namehash = ?", .{namehash});
    var q = try Query.initCached(db, "UPDATE names SET owner = ?, migrated = 1, updated_at = ? WHERE namehash = ?");
    defer q.deinit();

    try q.bindAddressBuf(controller);
    try q.bindInt64(zsys.timestamp());
    try q.bindHashBuf(namehash);
    try q.exec();
}

/// Update name resolver
pub fn updateNameResolver(db: *Database, namehash: Hash, resolver: Address) !void {
    try reorg_undo.captureWhere(db, "names", "U", "namehash = ?", .{namehash});
    var q = try Query.initCached(db, "UPDATE names SET resolver = ?, updated_at = ? WHERE namehash = ?");
    defer q.deinit();

    try q.bindAddressBuf(resolver);
    try q.bindInt64(zsys.timestamp());
    try q.bindHashBuf(namehash);
    try q.exec();
}

/// Clear `names.resolved_address` (set to NULL). Called when V1 NewResolver
/// either points at the zero resolver or the `addr(node)` call returns zero
/// — both indicate "no resolution available right now". No-op if the row
/// doesn't exist.
pub fn updateResolvedAddressToNull(db: *Database, namehash: Hash) !void {
    try reorg_undo.captureWhere(db, "names", "U", "namehash = ?", .{namehash});
    var q = try Query.initCached(db, "UPDATE names SET resolved_address = NULL, updated_at = ? WHERE namehash = ?");
    defer q.deinit();

    try q.bindInt64(zsys.timestamp());
    try q.bindHashBuf(namehash);
    try q.exec();
}

/// Update TTL for a name (V1 ENS Registry NewTTL event).
/// No-op if no row exists with this namehash — consistent with NewResolver:
/// V1 NewTTL on a non-existent name has nothing to attach to. TTL is an
/// arbitrary caller-set u64 on-chain; values beyond i64 collapse to the 0
/// sentinel like expiry does.
pub fn updateNameTTL(db: *Database, namehash: Hash, ttl: u64) !void {
    try reorg_undo.captureWhere(db, "names", "U", "namehash = ?", .{namehash});
    var q = try Query.initCached(db, "UPDATE names SET ttl = ?, updated_at = ? WHERE namehash = ?");
    defer q.deinit();

    try q.bindInt64(safeU64ToI64(ttl));
    try q.bindInt64(zsys.timestamp());
    try q.bindHashBuf(namehash);
    try q.exec();
}

/// Delete a name by its namehash (registry-safe: only deletes the exact name)
pub fn deleteNameByNamehash(db: *Database, namehash: Hash) !void {
    try reorg_undo.captureActiveWhere(db, "unknown_labels", "D", "name_id IN (SELECT id FROM names WHERE namehash = ?)", .{namehash});
    try reorg_undo.captureWhere(db, "names", "D", "namehash = ?", .{namehash});
    var q = try Query.initCached(db, "DELETE FROM names WHERE namehash = ?");
    defer q.deinit();

    try q.bindHashBuf(namehash);
    try q.exec();
}

/// Recursively delete a domain and walk up parent chain GCing empty parents.
/// Mirrors subgraph's `recursivelyRemoveEmptyDomainFromParentSubdomainCount`.
/// A "fully-burned" name (owner=0, resolver=0, no live subdomains, no expiry)
/// is deleted and the parent re-checked. Stops at the root or at the first
/// parent that's not fully burned. Returns the total number of rows deleted.
///
/// V1-only: V2 hard-deletes on burn (LabelUnregistered cascade), so this
/// reconciliation is only meaningful for V1 ENS Registry `NewOwner`/`Transfer`
/// events that set `owner = 0x0`. The walker is iterative (stack-driven) to
/// avoid recursion in Zig and to keep the parent chain check explicit.
pub fn recursivelyGcEmptyDomain(db: *Database, namehash: Hash) !u32 {
    var deleted: u32 = 0;
    var current = namehash;

    // Cap the walk to defend against pathological parent chains (data
    // corruption or self-referential rows); ENS depth in practice is small.
    var safety: u32 = 0;
    const SAFETY_LIMIT: u32 = 256;

    while (safety < SAFETY_LIMIT) : (safety += 1) {
        // Root has parent_namehash=0; stop GC at the root.
        if (current.isZero()) break;

        // Fetch the row's owner/resolver/expiry/parent_namehash. We must read
        // the row before deciding to delete: the GC criteria require checking
        // owner=0 AND resolver=0 AND no children AND no expiry.
        var q = try Query.initCached(db,
            \\SELECT owner, resolver, expiry, parent_namehash FROM names WHERE namehash = ? LIMIT 1
        );
        defer q.deinit();
        try q.bindHashBuf(current);
        if (!try q.step()) break; // Row already gone, nothing to do.

        const owner_str = q.getTextSlice(0) orelse "";
        const resolver_str = q.getTextSlice(1) orelse "";
        const expiry = q.getOptionalInt64(2);
        const parent_str = q.getTextSlice(3) orelse "";

        const ZERO = "0x0000000000000000000000000000000000000000";
        const owner_zero = std.mem.eql(u8, owner_str, ZERO);
        const resolver_zero = std.mem.eql(u8, resolver_str, ZERO) or resolver_str.len == 0;
        const expiry_unset = (expiry == null) or (expiry.? == 0);
        if (!(owner_zero and resolver_zero and expiry_unset)) break;

        // Capture parent before we delete this row.
        const parent_hash = Hash.fromHex(parent_str) catch break;

        // Children check: stop if this row has any descendant pointing at it
        // via parent_namehash. NOT EXISTS is a single-row probe — cheap.
        var child_q = try Query.initCached(db,
            \\SELECT 1 FROM names WHERE parent_namehash = ? LIMIT 1
        );
        defer child_q.deinit();
        try child_q.bindHashBuf(current);
        const has_child = try child_q.step();
        if (has_child) break;

        // All gates passed — delete this row and walk up to parent.
        try deleteNameByNamehash(db, current);
        deleted += 1;
        current = parent_hash;
    }

    return deleted;
}

/// Update token_id for a specific name by namehash (registry-safe: only updates the exact name).
/// Only updates token_id and token_version — canonical_id is unchanged across regeneration.
pub fn updateNameTokenIdByNamehash(db: *Database, namehash: Hash, new_token_id: u256) !void {
    const token_id_utils = @import("../types/token_id.zig");
    const token_version = token_id_utils.getTokenVersion(new_token_id);

    try reorg_undo.captureWhere(db, "names", "U", "namehash = ?", .{namehash});
    var q = try Query.initCached(db, "UPDATE names SET token_id = ?, token_version = ?, updated_at = ? WHERE namehash = ?");
    defer q.deinit();

    var new_token_id_buf: [66]u8 = undefined;
    const new_token_id_hex = formatU256HexBuf(&new_token_id_buf, new_token_id);

    try q.bindText(new_token_id_hex);
    try q.bindInt64(@intCast(token_version));
    try q.bindInt64(zsys.timestamp());
    try q.bindHashBuf(namehash);
    try q.exec();
}

/// Update wrapper state for a name
pub fn updateNameWrapperState(db: *Database, namehash: Hash, fuses: u32, expiry: u64) !void {
    try reorg_undo.captureWhere(db, "names", "U", "namehash = ?", .{namehash});
    var q = try Query.initCached(db,
        \\UPDATE names SET is_wrapped = 1, wrapper_fuses = ?, wrapper_expiry = ?,
        \\updated_at = ? WHERE namehash = ?
    );
    defer q.deinit();

    // u32 max = 10 decimal digits — stack buffer suffices, no heap alloc per event.
    var fuses_buf: [16]u8 = undefined;
    const fuses_str = try std.fmt.bufPrint(&fuses_buf, "{d}", .{fuses});

    try q.bindText(fuses_str);
    try q.bindInt64(safeU64ToI64(expiry));
    try q.bindInt64(zsys.timestamp());
    try q.bindHash(namehash);
    try q.exec();
}

/// Clear `names.expiry` (set to NULL) for a namehash. Used on NameUnwrapped
/// for subnames whose parent is NOT the .eth registrar: subgraph
/// (`NameWrapper.ts:250-259`) resets domain.expiryDate to null on unwrap
/// unless the parent is the .eth registrar (in which case the registration's
/// expiry remains canonical).
pub fn clearNameExpiry(db: *Database, namehash: Hash) !void {
    try reorg_undo.captureWhere(db, "names", "U", "namehash = ?", .{namehash});
    var q = try Query.initCached(db,
        \\UPDATE names SET expiry = NULL, updated_at = ? WHERE namehash = ?
    );
    defer q.deinit();

    try q.bindInt64(zsys.timestamp());
    try q.bindHashBuf(namehash);
    try q.exec();
}

/// Clear wrapper state for a name (unwrap)
pub fn updateNameUnwrapperState(db: *Database, namehash: Hash) !void {
    try reorg_undo.captureWhere(db, "names", "U", "namehash = ?", .{namehash});
    // Re-base .eth 2LD expiry to the bare registrar value on unwrap: while
    // wrapped, names.expiry may hold the grace-inclusive wrapper value (PCC
    // mirror / updateV1RenewalExpiry). The unwrapped read path re-adds the 90d
    // grace, so leaving the inflated value would over-report expiryDate by
    // 180d. registrations stores the bare expires (subgraph Registration
    // parity); rows without one (temp-registrar era) keep their value.
    //
    // MAX(r.expiry + 0), not MAX(r.expiry): a bare MAX over an indexed column
    // triggers SQLite's min/max shortcut, which here picks the (protocol,
    // expiry) index and walks it from the top testing namehash row by row —
    // measured ~10s per unwrap on a 3.4M-row mainnet table. The expression
    // form disables the shortcut so the planner takes the (protocol, namehash)
    // equality index (plan-verified; same semantics, MAX ignores NULLs either
    // way, and Postgres plans both forms identically).
    var q = try Query.initCached(db,
        \\UPDATE names SET is_wrapped = 0, wrapper_fuses = NULL, wrapper_expiry = NULL,
        \\expiry = CASE WHEN protocol = 'v1' AND parent_name = 'eth'
        \\  THEN COALESCE((SELECT MAX(r.expiry + 0) FROM registrations r WHERE r.protocol = names.protocol AND r.namehash = names.namehash), expiry)
        \\  ELSE expiry END,
        \\updated_at = ? WHERE namehash = ?
    );
    defer q.deinit();

    try q.bindInt64(zsys.timestamp());
    try q.bindHash(namehash);
    try q.exec();
}

/// Update wrapper fuses only
pub fn updateNameWrapperFuses(db: *Database, namehash: Hash, fuses: u32) !void {
    try reorg_undo.captureWhere(db, "names", "U", "namehash = ?", .{namehash});
    var q = try Query.initCached(db,
        \\UPDATE names SET wrapper_fuses = ?, updated_at = ? WHERE namehash = ?
    );
    defer q.deinit();

    var fuses_buf: [16]u8 = undefined;
    const fuses_str = try std.fmt.bufPrint(&fuses_buf, "{d}", .{fuses});

    try q.bindText(fuses_str);
    try q.bindInt64(zsys.timestamp());
    try q.bindHash(namehash);
    try q.exec();
}

/// Update wrapper expiry only
pub fn updateNameWrapperExpiry(db: *Database, namehash: Hash, expiry: u64) !void {
    try reorg_undo.captureWhere(db, "names", "U", "namehash = ?", .{namehash});
    var q = try Query.initCached(db,
        \\UPDATE names SET wrapper_expiry = ?, updated_at = ? WHERE namehash = ?
    );
    defer q.deinit();

    try q.bindInt64(safeU64ToI64(expiry));
    try q.bindInt64(zsys.timestamp());
    try q.bindHash(namehash);
    try q.exec();
}

/// PCC-aware Domain expiry mirror. Subgraph parity: when the wrapped name's
/// PARENT_CANNOT_CONTROL fuse is burned, the wrapper expiry IS the canonical
/// Domain expiry — mirror it (max with existing) so `Domain.expiryDate` returns
/// the wrapper-extended date rather than the registration's base expiry (or null
/// for wrapped subdomains that never had a base registrar expiry).
///
/// SQL `MAX(COALESCE(existing, 0), new)` handles NULL existing rows cleanly —
/// no row in `names` for this namehash → UPDATE affects zero rows (no-op).
/// That edge case is fine: `NameWrapped` on a name we never saw via Registry
/// will simply skip the mirror until the Registry row materializes.
pub fn updateDomainExpiryIfGreater(db: *Database, namehash: Hash, new_expiry: i64) !void {
    try reorg_undo.captureWhere(db, "names", "U", "namehash = ?", .{namehash});
    const sql = try std.fmt.allocPrint(db.allocator,
        \\UPDATE names
        \\SET expiry = {s}(COALESCE(expiry, 0), ?),
        \\    updated_at = ?
        \\WHERE namehash = ?
    , .{db.dialect().scalar_max}); // MAX (SQLite) / GREATEST (Postgres); args non-null via COALESCE
    defer db.allocator.free(sql);
    var q = try Query.initCached(db, sql);
    defer q.deinit();
    try q.bindInt64(new_expiry);
    try q.bindInt64(zsys.timestamp());
    try q.bindHashBuf(namehash);
    try q.exec();
}

/// Bulk-materialize the PCC (PARENT_CANNOT_CONTROL = 0x10000) fuse → Domain.expiry
/// mirror for every wrapped name. Idempotent: only updates rows where the wrapper
/// expiry would actually advance Domain.expiry, and only where the PCC fuse is set.
///
/// Why this exists separately from the per-event mirror in handlers:
/// - During initial bulk sync the write_buffer is active. The per-event mirror in
///   handleV1NameWrapped/FusesSet/ExpiryExtended needs to READ existing rows to
///   determine PCC state, which the write_buffer cannot service. The per-event
///   mirror is therefore skipped while buffered.
/// - After bulk sync flushes, this function runs once to materialize the mirror
///   in one bulk UPDATE. For incremental sync after bulk, the per-event mirror
///   handles updates directly (write_buffer is inactive).
///
/// SQL safety:
/// - `CAST(wrapper_fuses AS INTEGER)` returns 0 for null/non-numeric strings, so
///   the AND check naturally short-circuits. Combined with the explicit IS NOT
///   NULL guards, this avoids touching unrelated rows.
/// - `wrapper_expiry > COALESCE(expiry, 0)` ensures we never lower Domain.expiry.
/// Returns the number of rows updated.
pub fn materializePccDomainExpiry(db: *Database) !u32 {
    const PARENT_CANNOT_CONTROL: i64 = 0x10000;
    try reorg_undo.captureWhere(db, "names", "U", "is_wrapped = 1 AND wrapper_expiry IS NOT NULL AND wrapper_fuses IS NOT NULL AND wrapper_fuses != '' AND (CAST(wrapper_fuses AS INTEGER) & ?) != 0 AND wrapper_expiry > COALESCE(expiry, 0)", .{PARENT_CANNOT_CONTROL});
    var q = try Query.init(db,
        \\UPDATE names
        \\SET expiry = wrapper_expiry,
        \\    updated_at = ?
        \\WHERE is_wrapped = 1
        \\  AND wrapper_expiry IS NOT NULL
        \\  AND wrapper_fuses IS NOT NULL
        \\  AND wrapper_fuses != ''
        \\  AND (CAST(wrapper_fuses AS INTEGER) & ?) != 0
        \\  AND wrapper_expiry > COALESCE(expiry, 0)
    );
    defer q.deinit();
    try q.bindInt64(zsys.timestamp());
    try q.bindInt64(PARENT_CANNOT_CONTROL);
    try q.exec();
    return q.changes();
}

/// Update label and name fields for a name record (used by label healing).
/// Scoped by protocol: names is UNIQUE(protocol, namehash), so a V1 heal must
/// not overwrite a same-namehashed V2 row (e.g. a V1->V2 migrated name).
/// `is_normalized` is recomputed by the caller (indexer layer, which has the
/// ENSIP-15 lib) now that the plaintext label/name is known.
pub fn updateNameLabel(database: *Database, protocol: models.Protocol, namehash: Hash, label: []const u8, name: []const u8, is_normalized: bool) !void {
    try reorg_undo.captureWhere(database, "names", "U", "namehash = ? AND protocol = ?", .{ namehash, protocol });
    var q = try Query.initCached(database,
        \\UPDATE names SET label = ?, name = ?, is_normalized = ?
        \\WHERE namehash = ? AND protocol = ?
    );
    defer q.deinit();

    try q.bindText(label);
    try q.bindText(name);
    try q.bindInt(if (is_normalized) 1 else 0);
    try q.bindHash(namehash);
    try q.bindTextStatic(protocol.toString());
    try q.exec();
}

/// Update creation date if the new block is earlier (for backfill scenarios)
pub fn updateNameCreationDateIfEarlier(db: *Database, namehash: Hash, block_number: u64, created_at: i64) !void {
    try reorg_undo.captureWhere(db, "names", "U", "namehash = ? AND created_block > ?", .{ namehash, block_number });
    var q = try Query.initCached(db,
        \\UPDATE names SET created_block = ?, created_at = ?
        \\WHERE namehash = ? AND created_block > ?
    );
    defer q.deinit();

    try q.bindInt64(@intCast(block_number));
    try q.bindInt64(created_at);
    try q.bindHash(namehash);
    try q.bindInt64(@intCast(block_number));
    try q.exec();
}
