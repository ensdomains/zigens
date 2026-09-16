const std = @import("std");
const zsys = @import("../utils/system.zig");
const db_module = @import("database.zig");
const reorg_undo = @import("reorg_undo.zig");
const Database = db_module.Database;
const Query = db_module.Query;
const models = @import("../types/models.zig");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;
const names_common = @import("names_common.zig");

// ============================================================================
// EAC ROLE OPERATIONS
// ============================================================================

/// Insert or update EAC role assignment
pub fn upsertEACRole(db: *Database, protocol: models.Protocol, resource: []const u8, account: Address, role_bitmap: []const u8, block_number: u64, tx_hash: Hash, log_index: u32, contract_address: Address) !void {
    try reorg_undo.captureUpsert(db, "eac_roles", .{ protocol, resource, account, contract_address });
    const sql =
        \\INSERT INTO eac_roles
        \\(protocol, resource, account, role_bitmap, block_number, transaction_hash, log_index, timestamp, contract_address)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(protocol, resource, account, contract_address) DO UPDATE SET
        \\  role_bitmap = excluded.role_bitmap,
        \\  block_number = excluded.block_number,
        \\  transaction_hash = excluded.transaction_hash,
        \\  log_index = excluded.log_index,
        \\  timestamp = excluded.timestamp
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());
    try q.bindText(resource);
    try q.bindAddress(account);
    try q.bindText(role_bitmap);
    try q.bindInt64(@intCast(block_number));
    try q.bindHash(tx_hash);
    try q.bindInt(@intCast(log_index));
    try q.bindInt64(@intCast(zsys.timestamp()));
    try q.bindAddress(contract_address);

    try q.exec();
}

pub const RoleUpsertRow = struct {
    protocol: models.Protocol,
    resource: []const u8,
    account: Address,
    role_bitmap: []const u8,
    block_number: u64,
    tx_hash: Hash,
    log_index: u32,
    contract_address: Address,
};

/// Multi-row twin of `upsertEACRole` — same column list and the same explicit
/// `ON CONFLICT ... DO UPDATE SET col = excluded.col` clause (NOT the dialect's
/// `.replace`, which on SQLite becomes INSERT OR REPLACE and would churn `id`).
/// End state per key is identical to issuing `upsertEACRole` once with the
/// winning row. Rows MUST be unique on the conflict key
/// (protocol, resource, account, contract_address): Postgres rejects a
/// same-statement double-hit — the write buffer's keyed map guarantees this.
/// Capture parity: `captureUpsert` is invoked per row exactly like the direct
/// path; it no-ops unless the write-path capture fallback is active.
///
/// Row strings are BORROWED for the duration of the call (bound via
/// bindTextStatic — the copying bindText caps tracked strings at 32 per
/// statement, far below a full chunk). The write-buffer flush owns them until
/// reset(), which outlives this call.
pub fn upsertEACRolesBatch(db: *Database, rows: []const RoleUpsertRow) !void {
    try db.namesBarrier();
    if (rows.len == 0) return;
    // 9 params/row → 810 params, under the pre-3.32 SQLite
    // SQLITE_MAX_VARIABLE_NUMBER floor of 999 (same convention as
    // EVENT_BATCH_ROWS).
    const ROLE_BATCH_ROWS: usize = 90;

    const head =
        \\INSERT INTO eac_roles
        \\(protocol, resource, account, role_bitmap, block_number, transaction_hash, log_index, timestamp, contract_address)
        \\VALUES
    ;
    const tail =
        \\
        \\ON CONFLICT(protocol, resource, account, contract_address) DO UPDATE SET
        \\  role_bitmap = excluded.role_bitmap,
        \\  block_number = excluded.block_number,
        \\  transaction_hash = excluded.transaction_hash,
        \\  log_index = excluded.log_index,
        \\  timestamp = excluded.timestamp
    ;

    var start: usize = 0;
    while (start < rows.len) {
        const n = @min(ROLE_BATCH_ROWS, rows.len - start);
        const chunk = rows[start .. start + n];

        for (chunk) |row| {
            try reorg_undo.captureUpsert(db, "eac_roles", .{ row.protocol, row.resource, row.account, row.contract_address });
        }

        var sql: std.ArrayList(u8) = .empty;
        defer sql.deinit(db.allocator);
        try sql.appendSlice(db.allocator, head);
        for (0..n) |i| {
            try sql.appendSlice(db.allocator, if (i == 0) "(?, ?, ?, ?, ?, ?, ?, ?, ?)" else ", (?, ?, ?, ?, ?, ?, ?, ?, ?)");
        }
        try sql.appendSlice(db.allocator, tail);

        // Declared before the Query so its hex strings outlive exec (LIFO
        // defers) — same pattern as insertEventsBatch.
        var arena = std.heap.ArenaAllocator.init(db.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();

        var q = try Query.initCached(db, sql.items);
        defer q.deinit();
        for (chunk) |row| {
            try q.bindTextStatic(row.protocol.toString());
            try q.bindTextStatic(row.resource);
            const acc_buf = try scratch.create([42]u8);
            try q.bindTextStatic(row.account.toHexBuf(acc_buf));
            try q.bindTextStatic(row.role_bitmap);
            try q.bindInt64(@intCast(row.block_number));
            const tx_buf = try scratch.create([66]u8);
            try q.bindTextStatic(row.tx_hash.toHexBuf(tx_buf));
            try q.bindInt(@intCast(row.log_index));
            try q.bindInt64(@intCast(zsys.timestamp()));
            const contract_buf = try scratch.create([42]u8);
            try q.bindTextStatic(row.contract_address.toHexBuf(contract_buf));
        }
        try q.exec();
        start += n;
    }
}

/// Column list shared by all EAC role SELECTs. Column order is relied upon by
/// `parseEACRoleRow`:
///   id(0), protocol(1), resource(2), account(3), role_bitmap(4),
///   block_number(5), transaction_hash(6), log_index(7), timestamp(8),
///   name(9), is_resolver(10)
///
/// `is_resolver` is derived from whether the emitting `contract_address` is a
/// `known_resolvers` row — the exact set the indexer routes resolver events from
/// (see `event_fetchers.zig`: a log is dispatched to the resolver handlers, incl.
/// `handleResolverEACRolesChanged`, only when its address is a known resolver).
/// So every resolver-EAC row's contract is in `known_resolvers`, and every other
/// EAC emitter is a registry. This classification lets the API decode `role_bitmap`
/// against the correct named-role table. See `models.EACContractKind`.
///
/// NOTE: classification must NOT key on the `resolvers` (name-binding) JOIN — those
/// rows carry `resource = namehash`, but resolver-EAC events store `resource =`
/// keccak256(node, part) or 0 (the contract-global admin roles that make up live
/// data), so that JOIN never matches a real resolver row. The `resolvers`/
/// `resolver_name` JOINs below remain only for resolver-path name resolution (a
/// no-op on current data; future-proofing for label-scoped resolver EAC).
///
/// Registry resources are stored verbatim as `canonical_id | uint32(eacVersionId)`
/// (fixed 66-char lowercase hex), so the name join keys on the canonical prefix:
/// the first 58 chars are the label's 224-bit canonical id, the last 8 the EAC
/// version. See `CURRENT_VERSION_ONLY` for the companion staleness rule.
/// Excludes rows whose resource has been superseded by a higher EAC version on
/// the same contract: the contract bumps `eacVersionId` on unregister and on
/// re-registering an expired label, so grants keyed by an older version are
/// unreachable through the registry from then on. Applied to listings that do
/// NOT name a resource; an explicit `resource` filter returns exactly what was
/// asked for, superseded or not. ROOT (0x0…0) has no version and is exempted
/// outright. Range-scans idx_eac_roles_contract_resource.
const CURRENT_VERSION_ONLY =
    \\ AND (r.resource = '0x0000000000000000000000000000000000000000000000000000000000000000'
    \\   OR NOT EXISTS (SELECT 1 FROM eac_roles n WHERE n.protocol = r.protocol AND n.contract_address = r.contract_address
    \\     AND n.resource > r.resource AND n.resource <= (substr(r.resource, 1, 58) || 'ffffffff')))
;

const EAC_SELECT_COLUMNS =
    \\SELECT r.id, r.protocol, r.resource, r.account, r.role_bitmap, r.block_number, r.transaction_hash, r.log_index, r.timestamp,
    \\       COALESCE(reg_name.name, resolver_name.name) AS name,
    \\       CASE WHEN kr.address IS NOT NULL THEN 1 ELSE 0 END AS is_resolver,
    \\       r.contract_address
    \\FROM eac_roles r
    \\LEFT JOIN names reg_name ON reg_name.canonical_id = (substr(r.resource, 1, 58) || '00000000') AND r.contract_address = reg_name.registry
    \\LEFT JOIN resolvers res ON r.contract_address = res.address AND r.resource = res.namehash AND res.protocol = r.protocol
    \\LEFT JOIN names resolver_name ON res.namehash = resolver_name.namehash AND resolver_name.protocol = r.protocol
    \\LEFT JOIN known_resolvers kr ON kr.address = r.contract_address AND kr.protocol = r.protocol
;

/// Parse EACRoleAssignment from query results.
/// Column order: see `EAC_SELECT_COLUMNS`.
fn parseEACRoleRow(q: *Query, allocator: std.mem.Allocator) !models.EACRoleAssignment {
    const protocol_col = q.getTextSlice(1) orelse return error.MissingProtocol;
    const resource_col = q.getTextSlice(2) orelse return error.MissingResource;
    const account_col = q.getTextSlice(3) orelse return error.MissingAccount;
    const role_bitmap_col = q.getTextSlice(4) orelse return error.MissingRoleBitmap;
    const tx_hash_col = q.getTextSlice(6) orelse return error.MissingTxHash;

    // Get domain name from JOIN (column 9), may be null
    const name: ?[]const u8 = if (q.getTextSlice(9)) |n|
        try allocator.dupe(u8, n)
    else
        null;
    errdefer if (name) |n| allocator.free(n);

    // is_resolver (column 10): a row whose emitting contract is a known resolver
    // is decoded against the resolver role table; otherwise it's a registry.
    const contract_kind: models.EACContractKind = if (q.getInt(10) != 0) .resolver else .registry;

    const contract_col = q.getTextSlice(11) orelse return error.MissingContractAddress;

    // Every fallible conversion runs BEFORE the dupes below: a conversion
    // failure mid-literal would leak the dupes already evaluated (only `name`
    // carries an errdefer).
    const protocol = try models.Protocol.fromString(protocol_col);
    const account = try Address.fromHex(account_col);
    const tx_hash = try Hash.fromHex(tx_hash_col);
    // The DDL declares `contract_address TEXT NOT NULL DEFAULT ''`; every
    // current writer binds a real address, but a legacy '' row must render as
    // Address.zero ("unknown") rather than fail the whole result set.
    // Non-empty garbage still errors loudly — that's corruption, not legacy.
    const contract_address = if (contract_col.len == 0) Address.zero else try Address.fromHex(contract_col);

    const resource = try allocator.dupe(u8, resource_col);
    errdefer allocator.free(resource);

    return models.EACRoleAssignment{
        .id = @intCast(q.getInt64(0)),
        .protocol = protocol,
        .resource = resource,
        .account = account,
        .role_bitmap = try allocator.dupe(u8, role_bitmap_col),
        .block_number = @intCast(q.getInt64(5)),
        .tx_hash = tx_hash,
        .log_index = @intCast(q.getInt(7)),
        .timestamp = q.getInt64(8),
        .name = name,
        .contract_kind = contract_kind,
        .contract_address = contract_address,
    };
}

/// Get all role assignments for a resource.
/// Resolves the human-readable name via two paths:
///   1. Registry EAC (today's primary path): `contract_address` matches a registry row,
///      resource = canonical_id | eacVersionId — joins to `names` by the canonical
///      prefix and the registry (see EAC_SELECT_COLUMNS).
///   2. Resolver EAC: resolver contracts DO emit `EACRolesChanged` (handleResolverEACRolesChanged),
///      but with `resource = 0` (the EAC ROOT_RESOURCE) — contract-global admin roles, not
///      per-namehash. Those correctly resolve to no name (resource 0 matches no namehash), so the
///      resolvers JOIN is a no-op on them by design. The JOIN is future-proofing for a hypothetical
///      per-namehash resolver EAC (`resource = namehash`); none is emitted today (verified on
///      Sepolia 2026-06-02: all resolver EAC rows have resource 0).
pub fn getRolesByResource(db: *Database, protocol: models.Protocol, resource: []const u8) ![]models.EACRoleAssignment {
    return getRolesFiltered(db, protocol, .{ .resource = resource });
}

/// Get all role assignments for an account.
/// Resolves name via registry or resolver paths (see getRolesByResource).
pub fn getRolesByAccount(db: *Database, protocol: models.Protocol, account: Address) ![]models.EACRoleAssignment {
    return getRolesFiltered(db, protocol, .{ .account = account });
}

/// The two hex spellings a resource value can wear: chain events (and thus
/// eac_roles storage, and names.canonical_id) carry 64-char zero-padded hex,
/// while the API serializes Domain.tokenId zero-TRIMMED ("0x{x}"). A name
/// whose hash starts with a zero nibble (~1/16 of names) therefore has two
/// distinct spellings of the same value, and clients legitimately feed the
/// trimmed one back into `roles(resource:)` — so the filter matches both
/// (plus the verbatim input, so exotic strings keep exact-match semantics).
/// Null when the input is not parseable hex.
pub const ResourceForms = struct {
    padded: [66]u8,
    trimmed: [66]u8,
    padded_len: usize,
    trimmed_len: usize,

    pub fn of(resource: []const u8) ?ResourceForms {
        const body = if (std.mem.startsWith(u8, resource, "0x")) resource[2..] else resource;
        if (body.len == 0 or body.len > 64) return null;
        const v = std.fmt.parseInt(u256, body, 16) catch return null;
        var out: ResourceForms = undefined;
        const padded = std.fmt.bufPrint(&out.padded, "0x{x:0>64}", .{v}) catch return null;
        out.padded_len = padded.len;
        const trimmed = std.fmt.bufPrint(&out.trimmed, "0x{x}", .{v}) catch return null;
        out.trimmed_len = trimmed.len;
        return out;
    }
};

pub const RoleFilters = struct {
    resource: ?[]const u8 = null,
    account: ?Address = null,
    /// Scope to one emitting contract. Load-bearing for shared resource
    /// values: ROOT (0x0) exists on every EAC-enabled contract, so an
    /// unscoped ROOT query mixes role holders across contracts.
    contract_address: ?Address = null,
};

/// Get all role assignments matching every provided filter, newest first.
/// The id tiebreak keeps equal-timestamp rows in a deterministic order on
/// both backends.
pub fn getRolesFiltered(db: *Database, protocol: models.Protocol, filters: RoleFilters) ![]models.EACRoleAssignment {
    var sql_buf: [2048]u8 = undefined;
    var sql_len: usize = 0;

    const base = EAC_SELECT_COLUMNS ++
        \\
        \\WHERE r.protocol = ?
    ;
    @memcpy(sql_buf[sql_len .. sql_len + base.len], base);
    sql_len += base.len;

    // Widened to the input's VERBATIM spelling plus both canonical hex forms
    // when it parses (see ResourceForms); unparseable input keeps exact-match.
    const resource_forms: ?ResourceForms = if (filters.resource) |r| ResourceForms.of(r) else null;
    if (filters.resource != null) {
        const clause = if (resource_forms != null) " AND r.resource IN (?, ?, ?)" else " AND r.resource = ?";
        @memcpy(sql_buf[sql_len .. sql_len + clause.len], clause);
        sql_len += clause.len;
    }

    if (filters.account != null) {
        const clause = " AND r.account = ?";
        @memcpy(sql_buf[sql_len .. sql_len + clause.len], clause);
        sql_len += clause.len;
    }

    if (filters.contract_address != null) {
        const clause = " AND r.contract_address = ?";
        @memcpy(sql_buf[sql_len .. sql_len + clause.len], clause);
        sql_len += clause.len;
    }

    if (filters.resource == null) {
        @memcpy(sql_buf[sql_len .. sql_len + CURRENT_VERSION_ONLY.len], CURRENT_VERSION_ONLY);
        sql_len += CURRENT_VERSION_ONLY.len;
    }

    {
        const order = " ORDER BY r.timestamp DESC, r.id DESC";
        @memcpy(sql_buf[sql_len .. sql_len + order.len], order);
        sql_len += order.len;
    }

    var q = try Query.init(db, sql_buf[0..sql_len]);
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());
    if (filters.resource) |resource| {
        try q.bindText(resource);
        if (resource_forms) |*forms| {
            try q.bindText(forms.padded[0..forms.padded_len]);
            try q.bindText(forms.trimmed[0..forms.trimmed_len]);
        }
    }
    if (filters.account) |account| try q.bindAddress(account);
    if (filters.contract_address) |contract| try q.bindAddress(contract);

    var roles: std.ArrayList(models.EACRoleAssignment) = .empty;
    errdefer {
        for (roles.items) |*role| {
            role.deinit(db.allocator);
        }
        roles.deinit(db.allocator);
    }

    while (try q.step()) {
        var role = try parseEACRoleRow(&q, db.allocator);
        // Covers the append-fails gap: a parsed-but-unappended row is invisible
        // to the list errdefer above.
        errdefer role.deinit(db.allocator);
        try roles.append(db.allocator, role);
    }

    return roles.toOwnedSlice(db.allocator);
}

/// Options for paginated role queries
pub const RolePaginationOptions = struct {
    resource: ?[]const u8 = null,
    account: ?Address = null,
    /// Filter by the contract that emitted the role event (e.g., to scope
    /// a query to a single registry's roles regardless of resource).
    contract_address: ?Address = null,
    limit: u32 = 100,
    cursor_id: ?i64 = null, // For cursor-based pagination (ID to start after)
    direction: enum { forward, backward } = .forward,
};

/// Get roles with pagination support
pub fn getRolesWithPagination(db: *Database, protocol: models.Protocol, options: RolePaginationOptions) ![]models.EACRoleAssignment {
    // Build SQL dynamically based on filters
    var sql_buf: [2048]u8 = undefined;
    var sql_len: usize = 0;

    const base = EAC_SELECT_COLUMNS ++
        \\
        \\WHERE r.protocol = ?
    ;
    @memcpy(sql_buf[sql_len .. sql_len + base.len], base);
    sql_len += base.len;

    if (options.resource != null) {
        const clause = " AND r.resource = ?";
        @memcpy(sql_buf[sql_len .. sql_len + clause.len], clause);
        sql_len += clause.len;
    }

    if (options.account != null) {
        const clause = " AND r.account = ?";
        @memcpy(sql_buf[sql_len .. sql_len + clause.len], clause);
        sql_len += clause.len;
    }

    if (options.contract_address != null) {
        const clause = " AND r.contract_address = ?";
        @memcpy(sql_buf[sql_len .. sql_len + clause.len], clause);
        sql_len += clause.len;
    }

    if (options.resource == null) {
        @memcpy(sql_buf[sql_len .. sql_len + CURRENT_VERSION_ONLY.len], CURRENT_VERSION_ONLY);
        sql_len += CURRENT_VERSION_ONLY.len;
    }

    if (options.cursor_id != null) {
        if (options.direction == .forward) {
            const clause = " AND r.id < ?";
            @memcpy(sql_buf[sql_len .. sql_len + clause.len], clause);
            sql_len += clause.len;
        } else {
            const clause = " AND r.id > ?";
            @memcpy(sql_buf[sql_len .. sql_len + clause.len], clause);
            sql_len += clause.len;
        }
    }

    {
        const order = if (options.direction == .forward)
            " ORDER BY r.id DESC LIMIT ?"
        else
            " ORDER BY r.id ASC LIMIT ?";
        @memcpy(sql_buf[sql_len .. sql_len + order.len], order);
        sql_len += order.len;
    }

    var q = try Query.init(db, sql_buf[0..sql_len]);
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());

    if (options.resource) |resource| {
        try q.bindText(resource);
    }

    if (options.account) |account| {
        try q.bindAddress(account);
    }

    if (options.contract_address) |contract| {
        try q.bindAddress(contract);
    }

    if (options.cursor_id) |cursor_id| {
        try q.bindInt64(cursor_id);
    }

    try q.bindInt(@intCast(options.limit));

    var roles: std.ArrayList(models.EACRoleAssignment) = .empty;
    errdefer {
        for (roles.items) |*role| {
            role.deinit(db.allocator);
        }
        roles.deinit(db.allocator);
    }

    while (try q.step()) {
        var role = try parseEACRoleRow(&q, db.allocator);
        // Covers the append-fails gap: a parsed-but-unappended row is invisible
        // to the list errdefer above.
        errdefer role.deinit(db.allocator);
        try roles.append(db.allocator, role);
    }

    return roles.toOwnedSlice(db.allocator);
}

/// Get total count of roles with optional filters
pub fn getTotalRoleCount(db: *Database, protocol: models.Protocol, resource: ?[]const u8, account: ?Address) !usize {
    return getRoleCountFiltered(db, .{
        .protocol = protocol,
        .resource = resource,
        .account = account,
    });
}

pub const RoleCountFilters = struct {
    protocol: models.Protocol,
    resource: ?[]const u8 = null,
    account: ?Address = null,
    contract_address: ?Address = null,
};

/// Count roles matching all provided filters. Used by Registry.roleCount.
pub fn getRoleCountFiltered(db: *Database, filters: RoleCountFilters) !usize {
    var sql_buf: [768]u8 = undefined;
    var sql_len: usize = 0;

    const base = "SELECT COUNT(*) FROM eac_roles r WHERE r.protocol = ?";
    @memcpy(sql_buf[sql_len .. sql_len + base.len], base);
    sql_len += base.len;

    if (filters.resource != null) {
        const clause = " AND r.resource = ?";
        @memcpy(sql_buf[sql_len .. sql_len + clause.len], clause);
        sql_len += clause.len;
    }
    if (filters.account != null) {
        const clause = " AND r.account = ?";
        @memcpy(sql_buf[sql_len .. sql_len + clause.len], clause);
        sql_len += clause.len;
    }
    if (filters.contract_address != null) {
        const clause = " AND r.contract_address = ?";
        @memcpy(sql_buf[sql_len .. sql_len + clause.len], clause);
        sql_len += clause.len;
    }
    // Same staleness rule as the listings this count paginates.
    if (filters.resource == null) {
        @memcpy(sql_buf[sql_len .. sql_len + CURRENT_VERSION_ONLY.len], CURRENT_VERSION_ONLY);
        sql_len += CURRENT_VERSION_ONLY.len;
    }

    var q = try Query.init(db, sql_buf[0..sql_len]);
    defer q.deinit();

    try q.bindTextStatic(filters.protocol.toString());
    if (filters.resource) |res| try q.bindText(res);
    if (filters.account) |acc| try q.bindAddress(acc);
    if (filters.contract_address) |addr| try q.bindAddress(addr);

    if (try q.step()) return @intCast(q.getInt64(0));
    return 0;
}

/// Count distinct accounts holding any label-scoped role on a single label,
/// keyed by the label's canonical (version-stripped) token id.
///
/// A role's `resource` is `canonical_id | eacVersionId` and its
/// `contract_address` is the registry that owns the label, so the lookup takes
/// the canonical prefix range on `(registry, resource)` and keeps only the
/// highest EAC version present — the generation the contract currently
/// resolves; grants from a previous registration of the same label are not
/// holders any more. Empty role bitmaps are excluded (mirroring the
/// portal's `if (roleBitmap === 0n) continue`), since grant-then-revoke or
/// backfill can leave a row with an all-zero bitmap. A label's `canonical_id` is
/// non-zero, so the registry-wide root role (resource = 0x0…0) is naturally
/// excluded by the resource match. This replaces the client-side
/// fetch-all-roles + group-by-resource counting previously done in the portal.
///
/// `role_bitmap` is always stored as the fixed-width `0x` + 64-hex form (see
/// `handlers_registry` EACRolesChanged), so the only zero representation is the
/// all-zeros literal compared below.
const ZERO_ROLE_BITMAP = "0x0000000000000000000000000000000000000000000000000000000000000000";

pub fn getLabelRoleHolderCount(
    db: *Database,
    protocol: models.Protocol,
    canonical_id_hex: []const u8,
    registry: Address,
) !usize {
    const forms = ResourceForms.of(canonical_id_hex) orelse return 0;
    var hi: [66]u8 = undefined;
    @memcpy(hi[0..58], forms.padded[0..58]);
    @memcpy(hi[58..66], "ffffffff");

    const sql =
        \\SELECT COUNT(DISTINCT account)
        \\FROM eac_roles
        \\WHERE protocol = ? AND contract_address = ? AND resource >= ? AND resource <= ?
        \\  AND role_bitmap != ?
        \\  AND resource = (SELECT MAX(resource) FROM eac_roles
        \\                  WHERE protocol = ? AND contract_address = ? AND resource >= ? AND resource <= ?)
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(registry);
    try q.bindText(forms.padded[0..forms.padded_len]);
    try q.bindText(&hi);
    try q.bindTextStatic(ZERO_ROLE_BITMAP);
    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(registry);
    try q.bindText(forms.padded[0..forms.padded_len]);
    try q.bindText(&hi);

    if (try q.step()) return @intCast(q.getInt64(0));
    return 0;
}

/// One `(canonical_id, registry) -> distinct holder count` row from
/// `getLabelRoleHolderCountsForLabels`. `canonical_id` is the caller's input
/// spelling echoed back verbatim (the batch key); `registry` is the stored
/// 0x-hex address. Both strings are owned by the allocator the read was given;
/// free via `freeLabelRoleHolderCountRows`.
pub const LabelRoleHolderCountRow = struct {
    canonical_id: []u8,
    registry: []u8,
    count: u64,
};

pub fn freeLabelRoleHolderCountRows(allocator: std.mem.Allocator, rows: []LabelRoleHolderCountRow) void {
    for (rows) |r| {
        allocator.free(r.canonical_id);
        allocator.free(r.registry);
    }
    allocator.free(rows);
}

/// Pairs per statement of the batch holder count. Each pair is four
/// arena-static binds (no tracked-copy cap), so the chunk is sized for
/// statement length: 200 pairs = 800 placeholders plus three fixed ones, under
/// the legacy SQLite 999-parameter floor.
const LABEL_HOLDER_BATCH_CHUNK: usize = 200;

/// Batched mirror of `getLabelRoleHolderCount` over many `(canonical_id_hex,
/// registry)` pairs: `canonical_id_hexes[i]` pairs with `registries[i]` (both
/// the same length). Per pair it takes the point read's exact range
/// (`lo` = padded canonical spelling, `hi` = its 58-char prefix + 'ffffffff'),
/// keeps only rows at the MAX resource inside that range for (protocol,
/// registry), and counts DISTINCT accounts whose bitmap is not all-zero —
/// one statement per chunk of LABEL_HOLDER_BATCH_CHUNK pairs, via a VALUES
/// CTE joined to eac_roles twice (range max, then holders at the max).
/// Ordered by (canonical_id, registry). Pairs that yield zero are absent (no
/// row in range, or every row at the max resource has a zero bitmap) — the
/// point read answers 0 for them, as it does for a canonical id that does not
/// parse (`ResourceForms.of` null), which is skipped here. Duplicate pairs are
/// collapsed before chunking; two spellings of one canonical id are distinct
/// keys that each echo their own input. Rows and the returned slice are
/// allocated with `allocator`; free via `freeLabelRoleHolderCountRows`.
pub fn getLabelRoleHolderCountsForLabels(
    db: *Database,
    protocol: models.Protocol,
    canonical_id_hexes: []const []const u8,
    registries: []const Address,
    allocator: std.mem.Allocator,
) ![]LabelRoleHolderCountRow {
    std.debug.assert(canonical_id_hexes.len == registries.len);
    var rows: std.ArrayList(LabelRoleHolderCountRow) = .empty;
    errdefer {
        for (rows.items) |r| {
            allocator.free(r.canonical_id);
            allocator.free(r.registry);
        }
        rows.deinit(allocator);
    }
    if (canonical_id_hexes.len == 0) return try rows.toOwnedSlice(allocator);

    const Pair = struct { canonical_id_hex: []const u8, registry: Address, forms: ResourceForms };
    // Dedupe keys (input spelling + registry hex) live here for the whole call.
    var key_arena = std.heap.ArenaAllocator.init(db.allocator);
    defer key_arena.deinit();
    var seen = std.StringHashMap(void).init(db.allocator);
    defer seen.deinit();
    var unique: std.ArrayList(Pair) = .empty;
    defer unique.deinit(db.allocator);
    for (canonical_id_hexes, registries) |canonical_id_hex, registry| {
        const forms = ResourceForms.of(canonical_id_hex) orelse continue;
        var registry_buf: [42]u8 = undefined;
        const key = try std.mem.concat(key_arena.allocator(), u8, &.{ canonical_id_hex, "|", registry.toHexBuf(&registry_buf) });
        const gop = try seen.getOrPut(key);
        if (gop.found_existing) continue;
        try unique.append(db.allocator, .{ .canonical_id_hex = canonical_id_hex, .registry = registry, .forms = forms });
    }

    var off: usize = 0;
    while (off < unique.items.len) : (off += LABEL_HOLDER_BATCH_CHUNK) {
        const end = @min(off + LABEL_HOLDER_BATCH_CHUNK, unique.items.len);
        const chunk = unique.items[off..end];

        // Declared before the Query so the bound strings outlive step (LIFO defers).
        var scratch = std.heap.ArenaAllocator.init(db.allocator);
        defer scratch.deinit();
        const scratch_alloc = scratch.allocator();

        var sql: std.ArrayList(u8) = .empty;
        try sql.appendSlice(scratch_alloc, "WITH v(cid, lo, hi, registry) AS (VALUES ");
        for (chunk, 0..) |_, i| {
            if (i != 0) try sql.appendSlice(scratch_alloc, ", ");
            try sql.appendSlice(scratch_alloc, "(?, ?, ?, ?)");
        }
        try sql.appendSlice(scratch_alloc, "), " ++
            "m AS (SELECT v.cid, v.registry, MAX(e.resource) AS maxres FROM v JOIN eac_roles e " ++
            "ON e.protocol = ? AND e.contract_address = v.registry AND e.resource >= v.lo AND e.resource <= v.hi " ++
            "GROUP BY v.cid, v.registry) " ++
            "SELECT m.cid, m.registry, COUNT(DISTINCT e.account) FROM m JOIN eac_roles e " ++
            "ON e.protocol = ? AND e.contract_address = m.registry AND e.resource = m.maxres AND e.role_bitmap != ? " ++
            "GROUP BY m.cid, m.registry ORDER BY m.cid, m.registry");

        var q = try Query.init(db, sql.items);
        defer q.deinit();
        for (chunk) |pair| {
            try q.bindTextStatic(pair.canonical_id_hex);
            const lo = try scratch_alloc.dupe(u8, pair.forms.padded[0..pair.forms.padded_len]);
            try q.bindTextStatic(lo);
            const hi = try scratch_alloc.create([66]u8);
            @memcpy(hi[0..58], pair.forms.padded[0..58]);
            @memcpy(hi[58..66], "ffffffff");
            try q.bindTextStatic(hi);
            const registry_buf = try scratch_alloc.create([42]u8);
            try q.bindTextStatic(pair.registry.toHexBuf(registry_buf));
        }
        try q.bindTextStatic(protocol.toString());
        try q.bindTextStatic(protocol.toString());
        try q.bindTextStatic(ZERO_ROLE_BITMAP);

        while (try q.step()) {
            const cid_str = q.getTextSlice(0) orelse continue;
            const registry_str = q.getTextSlice(1) orelse continue;
            const canonical_id = try allocator.dupe(u8, cid_str);
            errdefer allocator.free(canonical_id);
            const registry = try allocator.dupe(u8, registry_str);
            errdefer allocator.free(registry);
            try rows.append(allocator, .{ .canonical_id = canonical_id, .registry = registry, .count = @intCast(q.getInt64(2)) });
        }
    }
    return try rows.toOwnedSlice(allocator);
}

/// Delete role assignment (when all roles revoked)
pub fn deleteEACRole(db: *Database, protocol: models.Protocol, resource: []const u8, account: Address, contract_address: Address) !void {
    try reorg_undo.captureWhere(db, "eac_roles", "D", "protocol = ? AND resource = ? AND account = ? AND contract_address = ?", .{ protocol, resource, account, contract_address });
    const sql = "DELETE FROM eac_roles WHERE protocol = ? AND resource = ? AND account = ? AND contract_address = ?";

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());
    try q.bindText(resource);
    try q.bindAddress(account);
    try q.bindAddress(contract_address);

    try q.exec();
}
