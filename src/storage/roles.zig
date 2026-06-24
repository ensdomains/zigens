const std = @import("std");
const db_module = @import("database.zig");
const reorg_undo = @import("reorg_undo.zig");
const Database = db_module.Database;
const Query = db_module.Query;
const models = @import("../types/models.zig");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;

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
    try q.bindInt64(@intCast(std.time.timestamp()));
    try q.bindAddress(contract_address);

    try q.exec();
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
/// canonical_id (0 for the contract-global admin roles that make up live data), so
/// that JOIN never matches a real resolver row. The `resolvers`/`resolver_name`
/// JOINs below remain only for resolver-path name resolution (a no-op on current
/// data; future-proofing for label-scoped resolver EAC).
const EAC_SELECT_COLUMNS =
    \\SELECT r.id, r.protocol, r.resource, r.account, r.role_bitmap, r.block_number, r.transaction_hash, r.log_index, r.timestamp,
    \\       COALESCE(reg_name.name, resolver_name.name) AS name,
    \\       CASE WHEN kr.address IS NOT NULL THEN 1 ELSE 0 END AS is_resolver
    \\FROM eac_roles r
    \\LEFT JOIN names reg_name ON r.resource = reg_name.canonical_id AND r.contract_address = reg_name.registry
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

    return models.EACRoleAssignment{
        .id = @intCast(q.getInt64(0)),
        .protocol = try models.Protocol.fromString(protocol_col),
        .resource = try allocator.dupe(u8, resource_col),
        .account = try Address.fromHex(account_col),
        .role_bitmap = try allocator.dupe(u8, role_bitmap_col),
        .block_number = @intCast(q.getInt64(5)),
        .tx_hash = try Hash.fromHex(tx_hash_col),
        .log_index = @intCast(q.getInt(7)),
        .timestamp = q.getInt64(8),
        .name = name,
        .contract_kind = contract_kind,
    };
}

/// Get all role assignments for a resource.
/// Resolves the human-readable name via two paths:
///   1. Registry EAC (today's primary path): `contract_address` matches a registry row,
///      resource = token's canonical_id — joins to `names` by (canonical_id, registry).
///   2. Resolver EAC: resolver contracts DO emit `EACRolesChanged` (handleResolverEACRolesChanged),
///      but with `resource = 0` (the EAC ROOT_RESOURCE) — contract-global admin roles, not
///      per-namehash. Those correctly resolve to no name (resource 0 matches no namehash), so the
///      resolvers JOIN is a no-op on them by design. The JOIN is future-proofing for a hypothetical
///      per-namehash resolver EAC (`resource = namehash`); none is emitted today (verified on
///      Sepolia 2026-06-02: all resolver EAC rows have resource 0).
pub fn getRolesByResource(db: *Database, protocol: models.Protocol, resource: []const u8) ![]models.EACRoleAssignment {
    const sql = EAC_SELECT_COLUMNS ++
        \\
        \\WHERE r.protocol = ? AND r.resource = ?
        \\ORDER BY r.timestamp DESC
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());
    try q.bindText(resource);

    var roles: std.ArrayList(models.EACRoleAssignment) = .{};
    errdefer {
        for (roles.items) |*role| {
            role.deinit(db.allocator);
        }
        roles.deinit(db.allocator);
    }

    while (try q.step()) {
        const role = try parseEACRoleRow(&q, db.allocator);
        try roles.append(db.allocator, role);
    }

    return roles.toOwnedSlice(db.allocator);
}

/// Get all role assignments for an account.
/// Resolves name via registry or resolver paths (see getRolesByResource).
pub fn getRolesByAccount(db: *Database, protocol: models.Protocol, account: Address) ![]models.EACRoleAssignment {
    const sql = EAC_SELECT_COLUMNS ++
        \\
        \\WHERE r.protocol = ? AND r.account = ?
        \\ORDER BY r.timestamp DESC
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(account);

    var roles: std.ArrayList(models.EACRoleAssignment) = .{};
    errdefer {
        for (roles.items) |*role| {
            role.deinit(db.allocator);
        }
        roles.deinit(db.allocator);
    }

    while (try q.step()) {
        const role = try parseEACRoleRow(&q, db.allocator);
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

    var roles: std.ArrayList(models.EACRoleAssignment) = .{};
    errdefer {
        for (roles.items) |*role| {
            role.deinit(db.allocator);
        }
        roles.deinit(db.allocator);
    }

    while (try q.step()) {
        const role = try parseEACRoleRow(&q, db.allocator);
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
    var sql_buf: [512]u8 = undefined;
    var sql_len: usize = 0;

    const base = "SELECT COUNT(*) FROM eac_roles WHERE protocol = ?";
    @memcpy(sql_buf[sql_len .. sql_len + base.len], base);
    sql_len += base.len;

    if (filters.resource != null) {
        const clause = " AND resource = ?";
        @memcpy(sql_buf[sql_len .. sql_len + clause.len], clause);
        sql_len += clause.len;
    }
    if (filters.account != null) {
        const clause = " AND account = ?";
        @memcpy(sql_buf[sql_len .. sql_len + clause.len], clause);
        sql_len += clause.len;
    }
    if (filters.contract_address != null) {
        const clause = " AND contract_address = ?";
        @memcpy(sql_buf[sql_len .. sql_len + clause.len], clause);
        sql_len += clause.len;
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
/// A role's `resource` is the token's `canonical_id` and its `contract_address`
/// is the registry that owns the label, so the join key is
/// `(canonical_id, registry)` — version-independent, matching the same shape
/// used by `getRolesByResource`. Empty role bitmaps are excluded (mirroring the
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
    const sql =
        \\SELECT COUNT(DISTINCT account)
        \\FROM eac_roles
        \\WHERE protocol = ? AND resource = ? AND contract_address = ?
        \\  AND role_bitmap != ?
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());
    try q.bindText(canonical_id_hex);
    try q.bindAddress(registry);
    try q.bindTextStatic(ZERO_ROLE_BITMAP);

    if (try q.step()) return @intCast(q.getInt64(0));
    return 0;
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
