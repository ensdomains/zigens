const std = @import("std");
const zsys = @import("../utils/system.zig");
const db_module = @import("database.zig");
const reorg_undo = @import("reorg_undo.zig");
const Database = db_module.Database;
const Query = db_module.Query;
const models = @import("../types/models.zig");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;

// Resolver ENTITY storage (subgraph-parity Resolver rows, discovery,
// per-resolver counts and roles). Extracted from resolvers.zig; the
// record-value operations remain there. resolvers.zig re-exports every
// public symbol below so `resolvers.X` / `database.X` callers are unchanged.

// ----------------------------------------------------------------------------
// Resolver entity table (subgraph parity)
// ----------------------------------------------------------------------------
// One row per (protocol, namehash, resolver_address) binding ever observed on
// a NewResolver-style event. The same name can produce multiple Resolver rows
// over time if its resolver contract changes — each row records when that
// specific binding was first set.
//
// The subgraph encodes IDs as `{chainId}-{address}-{node}`. Our (protocol,
// address, namehash) triple is the same shape; the encoding lives in the
// query layer, not the storage layer.

pub fn upsertResolverEntity(
    db: *Database,
    protocol: models.Protocol,
    resolver_address: []const u8,
    namehash: []const u8,
    name: []const u8,
    block_number: u64,
    timestamp: i64,
) !void {
    if (resolver_address.len == 0 or namehash.len == 0) return;
    const sql = try db.upsertSql(db.allocator, "resolvers", &.{ "protocol", "address", "name", "namehash", "set_block", "set_at" }, .ignore);
    defer db.allocator.free(sql);
    var q = try Query.initCached(db, sql);
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindText(resolver_address);
    try q.bindText(name);
    try q.bindText(namehash);
    try q.bindInt64(@intCast(block_number));
    try q.bindInt64(timestamp);
    try q.exec();
}

pub fn getResolverEntityCount(db: *Database) !u64 {
    var q = try Query.init(db, "SELECT COUNT(*) FROM resolvers");
    defer q.deinit();
    if (!(try q.step())) return 0;
    return @intCast(q.getInt64(0));
}

pub const ResolverEntity = struct {
    protocol: []const u8,
    address: []const u8,
    name: []const u8,
    namehash: []const u8,
    set_block: u64,
    set_at: i64,

    pub fn deinit(self: *ResolverEntity, allocator: std.mem.Allocator) void {
        allocator.free(self.protocol);
        allocator.free(self.address);
        allocator.free(self.name);
        allocator.free(self.namehash);
    }
};

pub const ResolverEntityFilters = struct {
    /// Exact match on the resolver contract address (lowercase 0x-hex).
    address: ?[]const u8 = null,
    address_in: ?[]const []const u8 = null,
    /// Exact match on the bound namehash.
    namehash: ?[]const u8 = null,
    /// Restrict to one protocol; null = both.
    protocol: ?[]const u8 = null,
};

pub const ResolverEntitySortField = enum {
    set_block,
    address,

    pub fn toSql(self: ResolverEntitySortField) []const u8 {
        return switch (self) {
            .set_block => "set_block",
            .address => "address",
        };
    }
};

pub fn getFilteredResolverEntities(
    db: *Database,
    filters: ResolverEntityFilters,
    skip: u32,
    limit: u32,
    order_dir: db_module.OrderDir,
    sort_field: ResolverEntitySortField,
) ![]ResolverEntity {
    var conditions: std.ArrayList([]const u8) = .empty;
    defer conditions.deinit(db.allocator);
    var allocated: std.ArrayList([]const u8) = .empty;
    defer {
        for (allocated.items) |s| db.allocator.free(s);
        allocated.deinit(db.allocator);
    }

    if (filters.address != null) try conditions.append(db.allocator, "address = ?");
    if (filters.namehash != null) try conditions.append(db.allocator, "namehash = ?");
    if (filters.protocol != null) try conditions.append(db.allocator, "protocol = ?");
    if (filters.address_in) |addrs| {
        if (addrs.len == 0) {
            try conditions.append(db.allocator, "1=0");
        } else {
            const clause = try db_module.query.buildInClause(db.allocator, "address", "IN", addrs.len);
            try allocated.append(db.allocator, clause);
            try conditions.append(db.allocator, clause);
        }
    }

    var sql_buf: std.ArrayList(u8) = .empty;
    defer sql_buf.deinit(db.allocator);
    try sql_buf.appendSlice(db.allocator, "SELECT protocol, address, name, namehash, set_block, set_at FROM resolvers");
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
    try sql_buf.appendSlice(db.allocator, ", namehash ASC LIMIT ? OFFSET ?");

    var q = try Query.init(db, sql_buf.items);
    defer q.deinit();
    if (filters.address) |a| try q.bindText(a);
    if (filters.namehash) |n| try q.bindText(n);
    if (filters.protocol) |p| try q.bindText(p);
    if (filters.address_in) |addrs| {
        for (addrs) |a| try q.bindText(a);
    }
    try q.bindInt64(@intCast(limit));
    try q.bindInt64(@intCast(skip));

    var results: std.ArrayList(ResolverEntity) = .empty;
    defer results.deinit(db.allocator);
    while (try q.step()) {
        try results.append(db.allocator, .{
            .protocol = try db.allocator.dupe(u8, q.getTextSlice(0) orelse ""),
            .address = try db.allocator.dupe(u8, q.getTextSlice(1) orelse ""),
            .name = try db.allocator.dupe(u8, q.getTextSlice(2) orelse ""),
            .namehash = try db.allocator.dupe(u8, q.getTextSlice(3) orelse ""),
            .set_block = @intCast(q.getInt64(4)),
            .set_at = q.getInt64(5),
        });
    }
    return try results.toOwnedSlice(db.allocator);
}

// Backfill `resolvers` rows from existing `names.resolver` bindings. Idempotent
// (INSERT OR IGNORE preserves any previously inserted rows). Used once after
// the writer is added to event handlers, so historical data isn't lost.
pub fn backfillResolverEntitiesFromNames(db: *Database) !u64 {
    try db.namesBarrier();
    const seed_block_sql = "SELECT COALESCE(MIN(last_synced_block), 0) FROM sync_state";
    var seed_q = try Query.init(db, seed_block_sql);
    defer seed_q.deinit();
    const seed_block: i64 = if (try seed_q.step()) seed_q.getInt64(0) else 0;

    const select_body =
        \\SELECT n.protocol, n.resolver, n.name, n.namehash, ?, COALESCE(n.created_at, 0)
        \\FROM names n
        \\WHERE n.resolver IS NOT NULL
        \\  AND n.resolver != ''
        \\  AND n.resolver != '0x0000000000000000000000000000000000000000'
    ;
    const sql = try db.insertSelectSql(db.allocator, "resolvers", &.{ "protocol", "address", "name", "namehash", "set_block", "set_at" }, select_body, .ignore);
    defer db.allocator.free(sql);
    var q = try Query.init(db, sql);
    defer q.deinit();
    try q.bindInt64(seed_block);
    try q.exec();
    return try getResolverEntityCount(db);
}

/// Uses cache table for O(1) lookup, falls back to full scan on first run
pub fn getResolversToIndex(db: *Database, protocol: models.Protocol, from_block: u64, to_block: u64) ![][]u8 {
    try db.namesBarrier();
    // First, discover any NEW resolvers from names table (only those set in this block range)
    const discover_sql =
        \\SELECT DISTINCT n.resolver
        \\FROM names n
        \\LEFT JOIN known_resolvers kr ON kr.protocol = n.protocol AND kr.address = n.resolver
        \\WHERE n.protocol = ?
        \\  AND n.resolver != '0x0000000000000000000000000000000000000000'
        \\  AND n.created_block >= ?
        \\  AND n.created_block <= ?
        \\  AND kr.address IS NULL
    ;

    const protocol_str = protocol.toString();

    {
        var q = try Query.init(db, discover_sql);
        defer q.deinit();

        try q.bindTextStatic(protocol_str);
        try q.bindInt64(@intCast(from_block));
        try q.bindInt64(@intCast(to_block));

        // Register newly discovered resolvers
        while (try q.step()) {
            if (q.getTextSlice(0)) |addr_slice| {
                try db.registerResolver(protocol, addr_slice, from_block);
            }
        }
    }

    // Now get ALL known resolvers from cache (very fast)
    const get_sql =
        \\SELECT address FROM known_resolvers
        \\WHERE protocol = ?
        \\ORDER BY address
    ;

    var q2 = try Query.init(db, get_sql);
    defer q2.deinit();

    try q2.bindTextStatic(protocol_str);

    var resolvers: std.ArrayList([]u8) = .empty;
    errdefer {
        for (resolvers.items) |resolver| {
            db.allocator.free(resolver);
        }
        resolvers.deinit(db.allocator);
    }

    while (try q2.step()) {
        if (try q2.getText(0)) |addr| {
            try resolvers.append(db.allocator, addr);
        }
    }

    return resolvers.toOwnedSlice(db.allocator);
}

/// Result from resolver discovery: all known resolvers + any newly discovered ones
pub const ResolverDiscoveryResult = struct {
    all: [][]u8,
    newly_discovered: [][]u8,

    pub fn deinit(self: *ResolverDiscoveryResult, allocator: std.mem.Allocator) void {
        for (self.all) |r| allocator.free(r);
        allocator.free(self.all);
        for (self.newly_discovered) |r| allocator.free(r);
        allocator.free(self.newly_discovered);
    }
};

/// Get resolvers to index, also returning which ones were newly discovered in this block range.
/// Newly discovered resolvers need their historical events backfilled.
pub fn discoverAndGetResolvers(db: *Database, protocol: models.Protocol, from_block: u64, to_block: u64) !ResolverDiscoveryResult {
    try db.namesBarrier();
    const discover_sql =
        \\SELECT DISTINCT n.resolver
        \\FROM names n
        \\LEFT JOIN known_resolvers kr ON kr.protocol = n.protocol AND kr.address = n.resolver
        \\WHERE n.protocol = ?
        \\  AND n.resolver != '0x0000000000000000000000000000000000000000'
        \\  AND n.created_block >= ?
        \\  AND n.created_block <= ?
        \\  AND kr.address IS NULL
    ;

    const protocol_str = protocol.toString();

    var new_resolvers: std.ArrayList([]u8) = .empty;
    errdefer {
        for (new_resolvers.items) |r| db.allocator.free(r);
        new_resolvers.deinit(db.allocator);
    }

    {
        var q = try Query.init(db, discover_sql);
        defer q.deinit();

        try q.bindTextStatic(protocol_str);
        try q.bindInt64(@intCast(from_block));
        try q.bindInt64(@intCast(to_block));

        while (try q.step()) {
            if (q.getTextSlice(0)) |addr_slice| {
                try db.registerResolver(protocol, addr_slice, from_block);
                const copy = try db.allocator.dupe(u8, addr_slice);
                try new_resolvers.append(db.allocator, copy);
            }
        }
    }

    // Get ALL known resolvers from cache
    const get_sql =
        \\SELECT address FROM known_resolvers
        \\WHERE protocol = ?
        \\ORDER BY address
    ;

    var q2 = try Query.init(db, get_sql);
    defer q2.deinit();

    try q2.bindTextStatic(protocol_str);

    var resolvers: std.ArrayList([]u8) = .empty;
    errdefer {
        for (resolvers.items) |r| db.allocator.free(r);
        resolvers.deinit(db.allocator);
    }

    while (try q2.step()) {
        if (try q2.getText(0)) |addr| {
            try resolvers.append(db.allocator, addr);
        }
    }

    return .{
        .all = try resolvers.toOwnedSlice(db.allocator),
        .newly_discovered = try new_resolvers.toOwnedSlice(db.allocator),
    };
}

/// Get all distinct resolver addresses set on domains owned by an account
pub fn getResolversByOwner(db: *Database, protocol: models.Protocol, owner: Address) ![]models.Resolver {
    try db.namesBarrier();
    const sql =
        \\SELECT DISTINCT n.resolver, n.name, n.namehash, n.created_block, n.created_at
        \\FROM names n
        \\WHERE n.protocol = ? AND n.owner = ? AND n.resolver != '0x0000000000000000000000000000000000000000'
        \\ORDER BY n.created_at DESC
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(owner);

    var result: std.ArrayList(models.Resolver) = .empty;
    errdefer {
        for (result.items) |*r| {
            r.deinit(db.allocator);
        }
        result.deinit(db.allocator);
    }

    while (try q.step()) {
        const resolver_addr = try q.getAddress(0) orelse continue;
        const name_str = q.getTextSlice(1) orelse continue;
        const namehash_val = try q.getHash(2) orelse continue;

        const resolver = models.Resolver{
            .protocol = protocol,
            .address = resolver_addr,
            .name = try db.allocator.dupe(u8, name_str),
            .namehash = namehash_val,
            .set_block = @intCast(q.getInt64(3)),
            .set_at = q.getInt64(4),
        };

        try result.append(db.allocator, resolver);
    }

    return result.toOwnedSlice(db.allocator);
}

// ============================================================================
// DELETE OPERATIONS (for VersionChanged record clearing)
// ============================================================================

/// Count the number of domains (nodes) that use a specific resolver address
pub fn getResolverNodeCount(db: *Database, resolver: Address) !usize {
    try db.namesBarrier();
    const sql = "SELECT COUNT(*) FROM names WHERE resolver = ?";

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindAddress(resolver);

    if (try q.step()) {
        return @intCast(q.getInt64(0));
    }
    return 0;
}

/// Count the number of aliases defined on a resolver
pub fn getResolverAliasCount(db: *Database, resolver: Address) !usize {
    const sql = "SELECT COUNT(*) FROM resolver_aliases WHERE resolver = ?";

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindAddress(resolver);

    if (try q.step()) {
        return @intCast(q.getInt64(0));
    }
    return 0;
}

/// Count the number of distinct role holders for a resolver contract
pub fn getResolverRoleHolderCount(db: *Database, resolver: Address) !usize {
    const sql = "SELECT COUNT(DISTINCT account) FROM eac_roles WHERE contract_address = ?";

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindAddress(resolver);

    if (try q.step()) {
        return @intCast(q.getInt64(0));
    }
    return 0;
}

/// Get all EAC role assignments for a resolver contract address
pub fn getResolverRoles(db: *Database, resolver: Address) ![]models.EACRoleAssignment {
    try db.namesBarrier();
    const sql =
        \\SELECT r.id, r.protocol, r.resource, r.account, r.role_bitmap, r.block_number, r.transaction_hash, r.log_index, r.timestamp, n.name
        \\FROM eac_roles r
        \\LEFT JOIN names n ON n.canonical_id = (substr(r.resource, 1, 58) || '00000000') AND r.contract_address = n.registry
        \\WHERE r.contract_address = ?
        \\ORDER BY r.timestamp DESC
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindAddress(resolver);

    var roles: std.ArrayList(models.EACRoleAssignment) = .empty;
    errdefer {
        for (roles.items) |*role| {
            role.deinit(db.allocator);
        }
        roles.deinit(db.allocator);
    }

    while (try q.step()) {
        const protocol_col = q.getTextSlice(1) orelse continue;
        const resource_col = q.getTextSlice(2) orelse continue;
        const account_col = q.getTextSlice(3) orelse continue;
        const role_bitmap_col = q.getTextSlice(4) orelse continue;
        const tx_hash_col = q.getTextSlice(6) orelse continue;

        const name_val: ?[]const u8 = if (q.getTextSlice(9)) |n|
            try db.allocator.dupe(u8, n)
        else
            null;
        errdefer if (name_val) |n| db.allocator.free(n);

        const role = models.EACRoleAssignment{
            .id = @intCast(q.getInt64(0)),
            .protocol = try models.Protocol.fromString(protocol_col),
            .resource = try db.allocator.dupe(u8, resource_col),
            .account = try Address.fromHex(account_col),
            .role_bitmap = try db.allocator.dupe(u8, role_bitmap_col),
            .block_number = @intCast(q.getInt64(5)),
            .tx_hash = try Hash.fromHex(tx_hash_col),
            .log_index = @intCast(q.getInt(7)),
            .timestamp = q.getInt64(8),
            .name = name_val,
            // This query is scoped to a single resolver contract, so every row
            // is a resolver-EAC assignment — decode against the resolver table.
            .contract_kind = .resolver,
            .contract_address = resolver,
        };
        try roles.append(db.allocator, role);
    }

    return roles.toOwnedSlice(db.allocator);
}
