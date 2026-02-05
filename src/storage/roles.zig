const std = @import("std");
const db_module = @import("database.zig");
const Database = db_module.Database;
const Query = db_module.Query;
const models = @import("../types/models.zig");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;

// ============================================================================
// EAC ROLE OPERATIONS
// ============================================================================

/// Insert or update EAC role assignment
pub fn upsertEACRole(db: *Database, chain: models.Chain, resource: []const u8, account: Address, role_bitmap: []const u8, block_number: u64, tx_hash: Hash, log_index: u32) !void {
    const sql =
        \\INSERT INTO eac_roles
        \\(chain, resource, account, role_bitmap, block_number, transaction_hash, log_index, timestamp)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(chain, resource, account) DO UPDATE SET
        \\  role_bitmap = excluded.role_bitmap,
        \\  block_number = excluded.block_number,
        \\  transaction_hash = excluded.transaction_hash,
        \\  log_index = excluded.log_index,
        \\  timestamp = excluded.timestamp
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindTextStatic(chain.toString());
    try q.bindText(resource);
    try q.bindAddress(account);
    try q.bindText(role_bitmap);
    try q.bindInt64(@intCast(block_number));
    try q.bindHash(tx_hash);
    try q.bindInt(@intCast(log_index));
    try q.bindInt64(@intCast(std.time.timestamp()));

    try q.exec();
}

/// Parse EACRoleAssignment from query results
/// Column order: id(0), chain(1), resource(2), account(3), role_bitmap(4),
///               block_number(5), transaction_hash(6), log_index(7), timestamp(8), name(9)
fn parseEACRoleRow(q: *Query, allocator: std.mem.Allocator) !models.EACRoleAssignment {
    const chain_col = q.getTextSlice(1) orelse return error.MissingChain;
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

    return models.EACRoleAssignment{
        .id = @intCast(q.getInt64(0)),
        .chain = try models.Chain.fromString(chain_col),
        .resource = try allocator.dupe(u8, resource_col),
        .account = try Address.fromHex(account_col),
        .role_bitmap = try allocator.dupe(u8, role_bitmap_col),
        .block_number = @intCast(q.getInt64(5)),
        .tx_hash = try Hash.fromHex(tx_hash_col),
        .log_index = @intCast(q.getInt(7)),
        .timestamp = q.getInt64(8),
        .name = name,
    };
}

/// Get all role assignments for a resource
pub fn getRolesByResource(db: *Database, chain: models.Chain, resource: []const u8) ![]models.EACRoleAssignment {
    const sql =
        \\SELECT r.id, r.chain, r.resource, r.account, r.role_bitmap, r.block_number, r.transaction_hash, r.log_index, r.timestamp, n.name
        \\FROM eac_roles r
        \\LEFT JOIN names n ON r.resource = n.canonical_id
        \\WHERE r.chain = ? AND r.resource = ?
        \\ORDER BY r.timestamp DESC
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindTextStatic(chain.toString());
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

/// Get all role assignments for an account
pub fn getRolesByAccount(db: *Database, chain: models.Chain, account: Address) ![]models.EACRoleAssignment {
    const sql =
        \\SELECT r.id, r.chain, r.resource, r.account, r.role_bitmap, r.block_number, r.transaction_hash, r.log_index, r.timestamp, n.name
        \\FROM eac_roles r
        \\LEFT JOIN names n ON r.resource = n.canonical_id
        \\WHERE r.chain = ? AND r.account = ?
        \\ORDER BY r.timestamp DESC
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindTextStatic(chain.toString());
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
    limit: u32 = 100,
    cursor_id: ?i64 = null, // For cursor-based pagination (ID to start after)
    direction: enum { forward, backward } = .forward,
};

/// Get roles with pagination support
pub fn getRolesWithPagination(db: *Database, chain: models.Chain, options: RolePaginationOptions) ![]models.EACRoleAssignment {
    // Build SQL dynamically based on filters
    var sql_buf: [1024]u8 = undefined;
    var sql_len: usize = 0;

    const base =
        \\SELECT r.id, r.chain, r.resource, r.account, r.role_bitmap, r.block_number, r.transaction_hash, r.log_index, r.timestamp, n.name
        \\FROM eac_roles r
        \\LEFT JOIN names n ON r.resource = n.canonical_id
        \\WHERE r.chain = ?
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

    try q.bindTextStatic(chain.toString());

    if (options.resource) |resource| {
        try q.bindText(resource);
    }

    if (options.account) |account| {
        try q.bindAddress(account);
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
pub fn getTotalRoleCount(db: *Database, chain: models.Chain, resource: ?[]const u8, account: ?Address) !usize {
    var sql_buf: [512]u8 = undefined;
    var sql_len: usize = 0;

    const base = "SELECT COUNT(*) FROM eac_roles WHERE chain = ?";
    @memcpy(sql_buf[sql_len .. sql_len + base.len], base);
    sql_len += base.len;

    if (resource != null) {
        const clause = " AND resource = ?";
        @memcpy(sql_buf[sql_len .. sql_len + clause.len], clause);
        sql_len += clause.len;
    }

    if (account != null) {
        const clause = " AND account = ?";
        @memcpy(sql_buf[sql_len .. sql_len + clause.len], clause);
        sql_len += clause.len;
    }

    var q = try Query.init(db, sql_buf[0..sql_len]);
    defer q.deinit();

    try q.bindTextStatic(chain.toString());

    if (resource) |res| {
        try q.bindText(res);
    }

    if (account) |acc| {
        try q.bindAddress(acc);
    }

    if (try q.step()) {
        return @intCast(q.getInt64(0));
    }
    return 0;
}

/// Delete role assignment (when all roles revoked)
pub fn deleteEACRole(db: *Database, chain: models.Chain, resource: []const u8, account: Address) !void {
    const sql = "DELETE FROM eac_roles WHERE chain = ? AND resource = ? AND account = ?";

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindTextStatic(chain.toString());
    try q.bindText(resource);
    try q.bindAddress(account);

    try q.exec();
}
