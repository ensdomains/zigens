const std = @import("std");
const db_module = @import("database.zig");
const reorg_undo = @import("reorg_undo.zig");
const Database = db_module.Database;
const Query = db_module.Query;
const models = @import("../types/models.zig");

// ============================================================================
// ACCOUNTS — first-class Account entity (subgraph parity)
// ============================================================================
// One row per address ever observed in any role. Indexer event handlers call
// `upsertAccount` whenever they see an address; the upsert sets the per-protocol
// flag on the matching column and MIN-merges first_seen_block / first_seen_timestamp
// so the earliest observation wins regardless of arrival order.

pub fn upsertAccount(
    db: *Database,
    protocol: models.Protocol,
    address: []const u8,
    block_number: u64,
    timestamp: i64,
) !void {
    if (address.len == 0) return;
    const existed = try reorg_undo.activeRowExists(db, "accounts", "address = ?", .{address});
    if (existed) try reorg_undo.captureActiveWhere(db, "accounts", "U", "address = ?", .{address});
    // Scalar MAX/MIN over two values: MAX/MIN on SQLite, GREATEST/LEAST on Postgres
    // (all args here are NOT NULL columns, so the NULL-handling difference is moot). The
    // existing value is table-qualified (accounts.col) because Postgres rejects an
    // unqualified column in DO UPDATE as ambiguous with `excluded`; SQLite accepts the
    // qualified form too. Cached by SQL content on both backends.
    const d = db.dialect();
    const sql = try std.fmt.allocPrint(db.allocator,
        \\INSERT INTO accounts (address, seen_v1, seen_v2, first_seen_block, first_seen_timestamp)
        \\VALUES (?, ?, ?, ?, ?)
        \\ON CONFLICT(address) DO UPDATE SET
        \\  seen_v1 = {s}(accounts.seen_v1, excluded.seen_v1),
        \\  seen_v2 = {s}(accounts.seen_v2, excluded.seen_v2),
        \\  first_seen_block = {s}(accounts.first_seen_block, excluded.first_seen_block),
        \\  first_seen_timestamp = {s}(accounts.first_seen_timestamp, excluded.first_seen_timestamp)
    , .{ d.scalar_max, d.scalar_max, d.scalar_min, d.scalar_min });
    defer db.allocator.free(sql);
    var q = try Query.initCached(db, sql);
    defer q.deinit();
    const is_v1: i64 = if (protocol == .v1) 1 else 0;
    const is_v2: i64 = if (protocol == .v2) 1 else 0;
    try q.bindText(address);
    try q.bindInt64(is_v1);
    try q.bindInt64(is_v2);
    try q.bindInt64(@intCast(block_number));
    try q.bindInt64(timestamp);
    try q.exec();
    if (!existed) try reorg_undo.captureActiveWhere(db, "accounts", "I", "address = ?", .{address});
}

pub fn getAccountCount(db: *Database) !u64 {
    var q = try Query.init(db, "SELECT COUNT(*) FROM accounts");
    defer q.deinit();
    if (!(try q.step())) return 0;
    return @intCast(q.getInt64(0));
}

pub const Account = struct {
    address: []const u8,
    seen_v1: bool,
    seen_v2: bool,
    first_seen_block: u64,
    first_seen_timestamp: i64,

    pub fn deinit(self: *Account, allocator: std.mem.Allocator) void {
        allocator.free(self.address);
    }
};

pub fn getAccount(db: *Database, address: []const u8) !?Account {
    const sql =
        \\SELECT address, seen_v1, seen_v2, first_seen_block, first_seen_timestamp
        \\FROM accounts WHERE address = ?
    ;
    var q = try Query.initCached(db, sql);
    defer q.deinit();
    try q.bindText(address);
    if (!(try q.step())) return null;
    return Account{
        .address = try db.allocator.dupe(u8, q.getTextSlice(0) orelse ""),
        .seen_v1 = q.getInt64(1) != 0,
        .seen_v2 = q.getInt64(2) != 0,
        .first_seen_block = @intCast(q.getInt64(3)),
        .first_seen_timestamp = q.getInt64(4),
    };
}

pub const AccountFilters = struct {
    id: ?[]const u8 = null,
    id_in: ?[]const []const u8 = null,
    seen_v1: ?bool = null,
    seen_v2: ?bool = null,
};

pub const AccountSortField = enum {
    address,
    first_seen_block,

    pub fn toSql(self: AccountSortField) []const u8 {
        return switch (self) {
            .address => "address",
            .first_seen_block => "first_seen_block",
        };
    }
};

fn appendAccountConditions(
    db: *Database,
    filters: AccountFilters,
    conditions: *std.ArrayList([]const u8),
    allocated: *std.ArrayList([]const u8),
) !void {
    if (filters.id != null) try conditions.append(db.allocator, "address = ?");
    if (filters.id_in) |ids| {
        if (ids.len == 0) {
            try conditions.append(db.allocator, "1=0");
        } else {
            const clause = try db_module.query.buildInClause(db.allocator, "address", "IN", ids.len);
            try allocated.append(db.allocator, clause);
            try conditions.append(db.allocator, clause);
        }
    }
    if (filters.seen_v1) |b| {
        try conditions.append(db.allocator, if (b) "seen_v1 = 1" else "seen_v1 = 0");
    }
    if (filters.seen_v2) |b| {
        try conditions.append(db.allocator, if (b) "seen_v2 = 1" else "seen_v2 = 0");
    }
}

fn bindAccountFilters(q: *Query, filters: AccountFilters) !void {
    if (filters.id) |id| try q.bindText(id);
    if (filters.id_in) |ids| {
        for (ids) |id| try q.bindText(id);
    }
}

pub fn getFilteredAccounts(
    db: *Database,
    filters: AccountFilters,
    skip: u32,
    limit: u32,
    order_dir: db_module.OrderDir,
    sort_field: AccountSortField,
) ![]Account {
    var conditions: std.ArrayList([]const u8) = .{};
    defer conditions.deinit(db.allocator);
    var allocated: std.ArrayList([]const u8) = .{};
    defer {
        for (allocated.items) |s| db.allocator.free(s);
        allocated.deinit(db.allocator);
    }
    try appendAccountConditions(db, filters, &conditions, &allocated);

    var sql_buf: std.ArrayList(u8) = .{};
    defer sql_buf.deinit(db.allocator);
    try sql_buf.appendSlice(db.allocator, "SELECT address, seen_v1, seen_v2, first_seen_block, first_seen_timestamp FROM accounts");
    if (conditions.items.len > 0) {
        try sql_buf.appendSlice(db.allocator, " WHERE ");
        for (conditions.items, 0..) |c, i| {
            if (i > 0) try sql_buf.appendSlice(db.allocator, " AND ");
            try sql_buf.appendSlice(db.allocator, c);
        }
    }
    try sql_buf.appendSlice(db.allocator, " ORDER BY ");
    try sql_buf.appendSlice(db.allocator, sort_field.toSql());
    try sql_buf.appendSlice(db.allocator, if (order_dir == .desc) " DESC" else " ASC");
    try sql_buf.appendSlice(db.allocator, ", address ASC LIMIT ? OFFSET ?");

    var q = try Query.init(db, sql_buf.items);
    defer q.deinit();
    try bindAccountFilters(&q, filters);
    try q.bindInt64(@intCast(limit));
    try q.bindInt64(@intCast(skip));

    var results: std.ArrayList(Account) = .{};
    defer results.deinit(db.allocator);
    while (try q.step()) {
        try results.append(db.allocator, .{
            .address = try db.allocator.dupe(u8, q.getTextSlice(0) orelse ""),
            .seen_v1 = q.getInt64(1) != 0,
            .seen_v2 = q.getInt64(2) != 0,
            .first_seen_block = @intCast(q.getInt64(3)),
            .first_seen_timestamp = q.getInt64(4),
        });
    }
    return try results.toOwnedSlice(db.allocator);
}

// ============================================================================
// BACKFILL
// ============================================================================
// One-time fill from existing relational columns. Idempotent — the upsert path
// MAX-merges the protocol flags, so re-running converges to "address has seen
// V1 if any V1 row references it; same for V2; both can be 1." Uses the
// per-protocol earliest sync_state block as the conservative first-seen anchor
// since we don't carry a per-name observation block on `names`.

pub fn backfillFromExistingData(db: *Database) !u64 {
    const seed_block_sql = "SELECT COALESCE(MIN(last_synced_block), 0) FROM sync_state";
    var seed_q = try Query.init(db, seed_block_sql);
    defer seed_q.deinit();
    const seed_block: i64 = if (try seed_q.step()) seed_q.getInt64(0) else 0;

    // Walks names.owner, names.registrant, and registrations.registrant. Each
    // source carries `protocol`, so the seen_v1/seen_v2 flags get set correctly
    // by the same `upsertAccount` codepath the indexer will use at runtime.
    const SeedQuery = struct {
        sql: []const u8,
    };
    const seeds = [_]SeedQuery{
        .{ .sql = "SELECT DISTINCT owner, protocol, COALESCE(created_at, 0) FROM names WHERE owner IS NOT NULL AND owner != '' AND owner != '0x0000000000000000000000000000000000000000'" },
        .{ .sql = "SELECT DISTINCT registrant, protocol, COALESCE(created_at, 0) FROM names WHERE registrant IS NOT NULL AND registrant != '' AND registrant != '0x0000000000000000000000000000000000000000'" },
        .{ .sql = "SELECT DISTINCT registrant, protocol, COALESCE(registered_at, 0) FROM registrations WHERE registrant IS NOT NULL AND registrant != '' AND registrant != '0x0000000000000000000000000000000000000000'" },
    };
    for (seeds) |seed| {
        var q = try Query.init(db, seed.sql);
        defer q.deinit();
        while (try q.step()) {
            const address = q.getTextSlice(0) orelse continue;
            const protocol_str = q.getTextSlice(1) orelse continue;
            const ts = q.getInt64(2);
            const protocol = if (std.mem.eql(u8, protocol_str, "v2")) models.Protocol.v2 else models.Protocol.v1;
            try upsertAccount(db, protocol, address, @intCast(seed_block), ts);
        }
    }
    return try getAccountCount(db);
}
