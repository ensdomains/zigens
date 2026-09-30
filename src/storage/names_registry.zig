//! Registry-row operations for the names storage layer.
//!
//! Split out of names.zig as a cohesive, self-contained cluster: these functions
//! manage `registries` rows (and the placeholder-name patch that spans registries,
//! names, and events). They depend only on the shared storage primitives, not on
//! any names.zig-private helper, so they move verbatim. names.zig re-exports them
//! so every existing `names.<fn>` / `db.<fn>` call site is unchanged.

const std = @import("std");
const db_module = @import("database.zig");
const reorg_undo = @import("reorg_undo.zig");
const Database = db_module.Database;
const Query = db_module.Query;
const models = @import("../types/models.zig");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;

pub fn insertRegistry(db: *Database, registry: models.Registry) !void {
    // Use INSERT OR IGNORE to keep the FIRST SubregistryUpdate (when subregistry was established)
    // not later ones. This ensures created_block reflects when the parent->subregistry mapping
    // was first created, which is needed for correct temporal parent lookups.
    const sql = try db.upsertSql(db.allocator, "registries", &.{ "address", "protocol", "name", "namehash", "parent_registry", "created_block", "created_at" }, .ignore);
    defer db.allocator.free(sql);

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindAddress(registry.address);
    try q.bindTextStatic(registry.protocol.toString());
    try q.bindText(registry.name);
    try q.bindHash(registry.namehash);
    try q.bindAddress(registry.parent_registry);
    try q.bindInt64(@intCast(registry.created_block));
    try q.bindInt64(registry.created_at);
    try q.exec();
}

pub fn setSeededRootRegistryCreation(db: *Database, address: Address, protocol: models.Protocol, created_block: u64, created_at: i64) !void {
    const where = "address = ? AND protocol = ? AND parent_registry = ? AND created_at = 0";
    try reorg_undo.captureWhere(db, "registries", "U", where, .{ address, protocol, Address.zero });
    var q = try Query.init(db, "UPDATE registries SET created_block = ?, created_at = ? WHERE " ++ where);
    defer q.deinit();
    try q.bindInt64(@intCast(created_block));
    try q.bindInt64(created_at);
    try q.bindAddressBuf(address);
    try q.bindTextStatic(protocol.toString());
    try q.bindAddressBuf(Address.zero);
    try q.exec();
}

pub fn setSeededSubregistryCreation(db: *Database, address: Address, protocol: models.Protocol, namehash: Hash, parent: Address, created_block: u64, created_at: i64) !void {
    const where = "address = ? AND protocol = ? AND namehash = ? AND parent_registry = ? AND created_at = 0";
    try reorg_undo.captureWhere(db, "registries", "U", where, .{ address, protocol, namehash, parent });
    var q = try Query.init(db, "UPDATE registries SET created_block = ?, created_at = ? WHERE " ++ where);
    defer q.deinit();
    try q.bindInt64(@intCast(created_block));
    try q.bindInt64(created_at);
    try q.bindAddressBuf(address);
    try q.bindTextStatic(protocol.toString());
    try q.bindHashBuf(namehash);
    try q.bindAddressBuf(parent);
    try q.exec();
}

/// Resolve a `canonicalId:N` placeholder to the real name, for ONE parent registry.
///
/// `parent_registry` is not optional, and leaving it out was a cross-parent corruption bug of
/// exactly the same shape as the shared-registry misattribution. The placeholder string is
/// derived from the canonical id alone — `canonicalId:{d}` — and a canonical id is
/// `keccak(label)` with the version bits cleared, so the SAME LABEL under two different
/// parents produces the SAME placeholder. Unscoped, resolving `blue` under koala.eth rewrote
/// the `registries` row, the child `names` rows and the `events` rows belonging to `blue`
/// under kangaroo.eth as well — naming them after a parent they have nothing to do with.
///
/// Each of the three patches is scoped by the thing that actually disambiguates it:
///   * `registries` — `parent_registry`, which is the registry the parent label lives in and
///     is exactly what the placeholder row recorded at creation
///     (`processSubregistryPointerChange`);
///   * `names` — the child rows live in the SUBREGISTRY contract, so they are scoped to the
///     addresses the first patch just resolved;
///   * `events` — the placeholder event was emitted BY the parent registry, so
///     `contract_address` is the scope.
///
/// KNOWN RESIDUAL: the child `names` rows get a corrected `name` / `parent_name` /
/// `parent_namehash`, but their own `namehash` is NOT recomputed — it was derived from the
/// placeholder parent and stays stale. Fixing it means a per-row keccak (not expressible in
/// SQL) plus a row-identity change under UNIQUE(protocol, namehash), so it is a separate
/// change; the label-heal path handles the same class for unknown labels.
pub fn updateRegistryPlaceholderName(
    db: *Database,
    parent_registry: Address,
    placeholder_name: []const u8,
    actual_name: []const u8,
    namehash: Hash,
) !u32 {
    try db.namesBarrier();

    // Which subregistry contracts does this placeholder name, under THIS parent registry?
    var subregistries: std.ArrayList([42]u8) = .empty;
    defer subregistries.deinit(db.allocator);
    {
        var q = try Query.initCached(db, "SELECT address FROM registries WHERE name = ? AND parent_registry = ?");
        defer q.deinit();
        try q.bindText(placeholder_name);
        try q.bindAddress(parent_registry);
        while (try q.step()) {
            const hex = q.getTextSlice(0) orelse continue;
            var buf: [42]u8 = undefined;
            const n = @min(hex.len, buf.len);
            @memcpy(buf[0..n], hex[0..n]);
            if (n == buf.len) try subregistries.append(db.allocator, buf);
        }
    }

    try reorg_undo.captureWhere(db, "registries", "U", "name = ? AND parent_registry = ?", .{ placeholder_name, parent_registry });
    var reg_q = try Query.init(db, "UPDATE registries SET name = ?, namehash = ? WHERE name = ? AND parent_registry = ?");
    defer reg_q.deinit();
    try reg_q.bindText(actual_name);
    try reg_q.bindHash(namehash);
    try reg_q.bindText(placeholder_name);
    try reg_q.bindAddress(parent_registry);
    try reg_q.exec();
    const registry_changes = reg_q.changes();

    var names_changes: u32 = 0;
    for (subregistries.items) |*subreg| {
        const sub_hex: []const u8 = subreg[0..];
        try reorg_undo.captureWhere(db, "names", "U", "parent_name = ? AND registry = ?", .{ placeholder_name, sub_hex });
        var names_q = try Query.initCached(db,
            \\UPDATE names
            \\SET parent_name = ?,
            \\    parent_namehash = ?,
            \\    name = label || '.' || ?
            \\WHERE parent_name = ? AND registry = ?
        );
        defer names_q.deinit();
        try names_q.bindText(actual_name);
        try names_q.bindHash(namehash);
        try names_q.bindText(actual_name);
        try names_q.bindText(placeholder_name);
        try names_q.bindText(sub_hex);
        try names_q.exec();
        names_changes += names_q.changes();
    }
    // Multi-row names rewrite keyed by placeholder parent — no per-row key, so conservatively
    // clear the dispatch-scoped name prefetch. Gated: this runs once per registration and
    // almost always matches zero rows; an unconditional clear would disable the prefetch in
    // exactly the registration-heavy batches it exists for.
    if (names_changes > 0) db.noteNamesBulkWrite();

    const event_changes = try updatePlaceholderEventsByName(db, parent_registry, placeholder_name, actual_name, namehash);

    if (registry_changes > 0 or names_changes > 0 or event_changes > 0) {
        // Debug-level: this fires once per migrated/registered name during a sync,
        // generating thousands of identical info lines on a fresh Sepolia reindex.
        std.log.debug("Updated placeholder '{s}' -> '{s}': {d} registries, {d} names, {d} events", .{
            placeholder_name, actual_name, registry_changes, names_changes, event_changes,
        });
    }

    return registry_changes + names_changes + event_changes;
}

/// Patch events stored with a placeholder name (either "canonicalId:N" from SubregistryUpdated or
/// "tokenId:N" from ResolverUpdated) once the name is known. Updates the top-level name/namehash
/// columns only; the raw JSON data blob is left intact as a historical record of what the handler
/// decoded at event-process time.
pub fn updatePlaceholderEventsByName(db: *Database, emitting_contract: Address, placeholder_name: []const u8, actual_name: []const u8, namehash: Hash) !u32 {
    // Scoped by the emitting contract for the same reason the registry patch is scoped by
    // parent_registry: a `canonicalId:N` / `tokenId:N` placeholder is not unique across
    // registries, so an unscoped rewrite renamed other registries' events.
    try reorg_undo.captureWhere(db, "events", "U", "name = ? AND contract_address = ?", .{ placeholder_name, emitting_contract });
    var q = try Query.initCached(db, "UPDATE events SET name = ?, namehash = ? WHERE name = ? AND contract_address = ?");
    defer q.deinit();
    try q.bindText(actual_name);
    try q.bindHash(namehash);
    try q.bindText(placeholder_name);
    try q.bindAddress(emitting_contract);
    try q.exec();
    return q.changes();
}

pub fn getRegistriesByOwner(db: *Database, protocol: models.Protocol, owner: Address) ![]models.Registry {
    try db.namesBarrier();
    // Join registries with names on namehash to find registries where the NAME is owned by the specified owner
    // This returns registries for names that the owner controls (not registries that the owner's names use as subregistries)
    // Only returns the LATEST (most recent) registry per name to avoid duplicates when subregistry is updated
    var q = try Query.init(db,
        \\SELECT r.address, r.protocol, r.name, r.namehash, r.parent_registry, r.created_block, r.created_at
        \\FROM registries r
        \\JOIN names n ON r.namehash = n.namehash AND r.protocol = n.protocol
        \\WHERE r.protocol = ? AND n.owner = ?
        \\AND r.created_block = (
        \\    SELECT MAX(r2.created_block)
        \\    FROM registries r2
        \\    WHERE r2.namehash = r.namehash AND r2.protocol = r.protocol
        \\)
    );
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(owner);

    var registries: std.ArrayList(models.Registry) = .empty;
    errdefer {
        for (registries.items) |*reg| {
            db.allocator.free(reg.name);
        }
        registries.deinit(db.allocator);
    }

    while (try q.step()) {
        const address_str = q.getTextSlice(0) orelse continue;
        const protocol_str = q.getTextSlice(1) orelse continue;
        const name_str = q.getTextSlice(2) orelse "";
        const namehash_str = q.getTextSlice(3) orelse continue;
        const parent_str = q.getTextSlice(4) orelse continue;

        try registries.append(db.allocator, .{
            .address = try Address.fromHex(address_str),
            .protocol = try models.Protocol.fromString(protocol_str),
            .name = try db.allocator.dupe(u8, name_str),
            .namehash = try Hash.fromHex(namehash_str),
            .parent_registry = try Address.fromHex(parent_str),
            .created_block = @intCast(q.getInt64(5)),
            .created_at = q.getInt64(6),
        });
    }

    return registries.toOwnedSlice(db.allocator);
}

/// Look up a single registry contract by its address. Returns the most-recently
/// created row when the same contract is referenced from multiple `created_block`
/// entries (which can happen on V2 since `INSERT OR IGNORE` keeps the first
/// SubregistryUpdate per registry but the table is keyed by
/// `UNIQUE(protocol, address, namehash)`).
/// The registry entity at `address`: which name owns this contract.
///
/// `registries` is append-only history, UNIQUE(protocol, address, namehash) — one row per
/// (contract, parent name) pair ever seen — so this is a one-to-MANY question, and
/// `ORDER BY created_block DESC LIMIT 1` answered it with the most recent linker. That is the
/// same defect as the subname misattribution the indexer side just had, on the read side:
/// for a contract shared by several parents it named whichever adopted it last, INCLUDING a
/// parent that has since repointed away and no longer resolves it at all. It is why
/// `Domain.subregistry` and `registry(address:)` reported the wrong owning name.
///
/// Now: prefer a parent whose pointer is still LIVE (the `registry_entries` mirror, joined
/// through the parent's own `names` row), oldest link first so the answer is stable as later
/// parents adopt the contract. History remains the fallback, for a contract whose parent row
/// has not landed yet. `referencedBy` already exposes the full set and is unchanged — this
/// only fixes which single parent the singular field names.
///
/// Ordering is a TOTAL order (`is_live`, then created_block, then namehash), so the answer
/// cannot differ between SQLite and Postgres.
pub fn getRegistry(db: *Database, protocol: models.Protocol, address: Address) !?models.Registry {
    try db.namesBarrier();
    var q = try Query.init(db,
        \\SELECT r.address, r.protocol, r.name, r.namehash, r.parent_registry, r.created_block, r.created_at
        \\FROM registries r
        \\LEFT JOIN names pp ON pp.protocol = r.protocol AND pp.namehash = r.namehash
        \\                  AND pp.is_alias = 0 AND pp.is_reachable = 1
        \\WHERE r.protocol = ? AND r.address = ?
        \\ORDER BY CASE WHEN EXISTS (
        \\           SELECT 1 FROM registry_entries re
        \\           WHERE re.protocol = r.protocol AND re.parent_registry = pp.registry
        \\             AND re.canonical_id = pp.canonical_id AND re.subregistry = r.address
        \\         ) THEN 0 ELSE 1 END ASC,
        \\         r.created_block ASC, r.namehash ASC
        \\LIMIT 1
    );
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(address);

    if (!try q.step()) return null;
    return try parseRegistryRow(&q, db.allocator);
}

/// Column list shared by `getRegistry` and `getRegistriesByAddresses`; the
/// order is what `parseRegistryRow` reads.
const REGISTRY_SELECT_COLS = "r.address, r.protocol, r.name, r.namehash, r.parent_registry, r.created_block, r.created_at";

/// Parse one `registries` row (REGISTRY_SELECT_COLS order). Null when a
/// required column is NULL. Every fallible conversion runs before the `name`
/// dupe so a conversion failure cannot leak it.
fn parseRegistryRow(q: *Query, allocator: std.mem.Allocator) !?models.Registry {
    const address_str = q.getTextSlice(0) orelse return null;
    const protocol_str = q.getTextSlice(1) orelse return null;
    const name_str = q.getTextSlice(2) orelse "";
    const namehash_str = q.getTextSlice(3) orelse return null;
    const parent_str = q.getTextSlice(4) orelse return null;

    const address = try Address.fromHex(address_str);
    const protocol = try models.Protocol.fromString(protocol_str);
    const namehash = try Hash.fromHex(namehash_str);
    const parent_registry = try Address.fromHex(parent_str);

    return .{
        .address = address,
        .protocol = protocol,
        .name = try allocator.dupe(u8, name_str),
        .namehash = namehash,
        .parent_registry = parent_registry,
        .created_block = @intCast(q.getInt64(5)),
        .created_at = q.getInt64(6),
    };
}

/// Addresses per IN-list statement of the batch read. The address binds are
/// arena-static (no tracked-copy cap), so the chunk is sized for statement
/// length, under the legacy SQLite 999-parameter floor.
const REGISTRY_BATCH_CHUNK: usize = 200;

/// Batched mirror of `getRegistry` over many addresses: EVERY `registries` row
/// of each address (the point read's `ORDER BY created_block DESC LIMIT 1` is
/// not replicated — a contract can hold several rows), parsed by the same
/// column list and conversions, ordered by address, then created_block DESC,
/// then namehash. The caller takes the first row per address as the point
/// read's answer; when an address's top two rows share `created_block` the
/// point read's pick is backend-defined, so fall back to `getRegistry` for that
/// address. Addresses with no row are absent (the point read answers null).
/// Duplicate addresses are collapsed before chunking; one statement per chunk
/// of REGISTRY_BATCH_CHUNK addresses. Rows (`name`) and the returned slice are
/// allocated with `allocator`; release each row via `Registry.deinit`.
pub fn getRegistriesByAddresses(db: *Database, protocol: models.Protocol, addresses: []const Address, allocator: std.mem.Allocator) ![]models.Registry {
    var rows: std.ArrayList(models.Registry) = .empty;
    errdefer {
        for (rows.items) |*r| r.deinit(allocator);
        rows.deinit(allocator);
    }
    if (addresses.len == 0) return try rows.toOwnedSlice(allocator);

    var seen = std.AutoHashMap([20]u8, void).init(db.allocator);
    defer seen.deinit();
    var unique: std.ArrayList(Address) = .empty;
    defer unique.deinit(db.allocator);
    for (addresses) |address| {
        const gop = try seen.getOrPut(address.bytes);
        if (!gop.found_existing) try unique.append(db.allocator, address);
    }

    var off: usize = 0;
    while (off < unique.items.len) : (off += REGISTRY_BATCH_CHUNK) {
        const end = @min(off + REGISTRY_BATCH_CHUNK, unique.items.len);
        const chunk = unique.items[off..end];

        // Declared before the Query so the hex binds outlive step (LIFO defers).
        var scratch = std.heap.ArenaAllocator.init(db.allocator);
        defer scratch.deinit();
        const scratch_alloc = scratch.allocator();

        // Same live-pointer-first total order as the point read `getRegistry`, because the
        // loader's contract is "first row per address == what getRegistry returns". Change
        // one and the batched API answer silently diverges from the point-query answer for
        // exactly the shared registries this ordering exists to get right — there is a test
        // pinning the two together.
        var sql: std.ArrayList(u8) = .empty;
        try sql.appendSlice(scratch_alloc, "SELECT " ++ REGISTRY_SELECT_COLS ++
            " FROM registries r" ++
            " LEFT JOIN names pp ON pp.protocol = r.protocol AND pp.namehash = r.namehash" ++
            "                   AND pp.is_alias = 0 AND pp.is_reachable = 1" ++
            " WHERE r.protocol = ? AND r.address IN (");
        for (chunk, 0..) |_, i| {
            if (i != 0) try sql.appendSlice(scratch_alloc, ", ");
            try sql.append(scratch_alloc, '?');
        }
        try sql.appendSlice(scratch_alloc, ") ORDER BY r.address, CASE WHEN EXISTS (" ++
            "SELECT 1 FROM registry_entries re WHERE re.protocol = r.protocol" ++
            " AND re.parent_registry = pp.registry AND re.canonical_id = pp.canonical_id" ++
            " AND re.subregistry = r.address) THEN 0 ELSE 1 END ASC," ++
            " r.created_block ASC, r.namehash ASC");

        var q = try Query.init(db, sql.items);
        defer q.deinit();
        try q.bindTextStatic(protocol.toString());
        for (chunk) |address| {
            const buf = try scratch_alloc.create([42]u8);
            try q.bindTextStatic(address.toHexBuf(buf));
        }
        while (try q.step()) {
            var row = (try parseRegistryRow(&q, allocator)) orelse continue;
            errdefer row.deinit(allocator);
            try rows.append(allocator, row);
        }
    }
    return try rows.toOwnedSlice(allocator);
}
