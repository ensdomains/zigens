const std = @import("std");
const constants = @import("../constants.zig");
const db_module = @import("database.zig");
const Database = db_module.Database;
const Query = db_module.Query;
const models = @import("../types/models.zig");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

/// Parse a single event row from query results
/// Column order: event_type(0), chain(1), block_number(2), tx_hash(3), log_index(4),
///               contract_address(5), name(6), namehash(7), data(8), timestamp(9)
fn parseEventRow(q: *Query, allocator: std.mem.Allocator) !models.Event {
    const event_type_str = q.getTextSlice(0) orelse models.EventType.transfer.toString();
    const chain_str = q.getTextSlice(1) orelse models.Chain.l2.toString();
    const tx_hash_str = q.getTextSlice(3) orelse return error.MissingTxHash;
    const contract_addr_str = q.getTextSlice(5) orelse return error.MissingContractAddress;
    const data_str = q.getTextSlice(8) orelse "{}";

    const name_val = if (q.getTextSlice(6)) |n| try allocator.dupe(u8, n) else null;
    errdefer if (name_val) |n| allocator.free(n);

    const namehash_val = if (q.getTextSlice(7)) |hash_str| blk: {
        if (hash_str.len == 66 and hash_str[0] == '0' and hash_str[1] == 'x') {
            break :blk Hash.fromHex(hash_str) catch null;
        } else {
            break :blk null;
        }
    } else null;

    const data_copy = try allocator.dupe(u8, data_str);
    errdefer allocator.free(data_copy);

    return models.Event{
        .event_type = models.EventType.fromString(event_type_str) orelse .transfer,
        .chain = try models.Chain.fromString(chain_str),
        .block_number = @intCast(q.getInt64(2)),
        .tx_hash = try Hash.fromHex(tx_hash_str),
        .log_index = @intCast(q.getInt(4)),
        .contract_address = try Address.fromHex(contract_addr_str),
        .name = name_val,
        .namehash = namehash_val,
        .data = data_copy,
        .timestamp = q.getInt64(9),
    };
}

// ============================================================================
// EVENT OPERATIONS
// ============================================================================

pub fn insertEvent(db: *Database, event: models.Event) !void {
    const sql =
        \\INSERT OR IGNORE INTO events
        \\(event_type, chain, block_number, tx_hash, log_index, contract_address,
        \\ name, namehash, data, timestamp)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    // Bind event type and chain as static text
    const event_type_str = event.event_type.toString();
    const chain_str = event.chain.toString();
    try q.bindTextStatic(event_type_str);
    try q.bindTextStatic(chain_str);
    try q.bindInt64(@intCast(event.block_number));
    try q.bindHash(event.tx_hash);
    try q.bindInt(@intCast(event.log_index));
    try q.bindAddress(event.contract_address);
    try q.bindOptionalText(event.name);
    try q.bindOptionalHash(event.namehash);
    try q.bindText(event.data);
    try q.bindInt64(event.timestamp);

    try q.exec();
}

/// Order direction for event queries
pub const OrderDir = enum {
    asc,
    desc,
};

pub fn getRecentEvents(db: *Database, chain: ?models.Chain, event_type: ?models.EventType, limit: u32) ![]models.Event {
    return getRecentEventsWithOrder(db, chain, event_type, limit, .desc);
}

/// Get recent events with configurable order direction (for backward pagination support)
pub fn getRecentEventsWithOrder(db: *Database, chain: ?models.Chain, event_type: ?models.EventType, limit: u32, order_dir: OrderDir) ![]models.Event {
    var sql_buf: [512]u8 = undefined;
    var sql_len: usize = 0;

    const base_sql = "SELECT event_type, chain, block_number, tx_hash, log_index, contract_address, name, namehash, data, timestamp FROM events";
    @memcpy(sql_buf[sql_len..][0..base_sql.len], base_sql);
    sql_len += base_sql.len;

    if (chain != null or event_type != null) {
        const where_sql = " WHERE ";
        @memcpy(sql_buf[sql_len..][0..where_sql.len], where_sql);
        sql_len += where_sql.len;

        if (chain != null) {
            const chain_filter = "chain = ?";
            @memcpy(sql_buf[sql_len..][0..chain_filter.len], chain_filter);
            sql_len += chain_filter.len;

            if (event_type != null) {
                const and_sql = " AND ";
                @memcpy(sql_buf[sql_len..][0..and_sql.len], and_sql);
                sql_len += and_sql.len;
            }
        }

        if (event_type != null) {
            const type_filter = "event_type = ?";
            @memcpy(sql_buf[sql_len..][0..type_filter.len], type_filter);
            sql_len += type_filter.len;
        }
    }

    const order_sql = if (order_dir == .desc)
        " ORDER BY block_number DESC, log_index DESC LIMIT "
    else
        " ORDER BY block_number ASC, log_index ASC LIMIT ";
    @memcpy(sql_buf[sql_len..][0..order_sql.len], order_sql);
    sql_len += order_sql.len;

    const limit_str = try std.fmt.bufPrint(sql_buf[sql_len..], "{d}", .{limit});
    sql_len += limit_str.len;

    var q = try Query.init(db, sql_buf[0..sql_len]);
    defer q.deinit();

    // Bind parameters
    if (chain) |ch| {
        try q.bindTextStatic(ch.toString());
    }
    if (event_type) |et| {
        try q.bindTextStatic(et.toString());
    }

    var events: std.ArrayList(models.Event) = .{};
    errdefer {
        for (events.items) |*event| {
            event.deinit(db.allocator);
        }
        events.deinit(db.allocator);
    }

    while (try q.step()) {
        const event = try parseEventRow(&q, db.allocator);
        try events.append(db.allocator, event);
    }

    return events.toOwnedSlice(db.allocator);
}

/// Event filter options for flexible querying
pub const EventFilterOptions = struct {
    event_type: ?[]const u8 = null,
    event_types: ?[]const []const u8 = null,
    chain: ?models.Chain = null,
    domain: ?[]const u8 = null,
    contract_address: ?[]const u8 = null,
    contract_addresses: ?[]const []const u8 = null,
    namehash: ?[]const u8 = null,
    block_number_gt: ?i64 = null,
    block_number_lt: ?i64 = null,
    timestamp_gt: ?i64 = null,
    timestamp_lt: ?i64 = null,
    data_json_owner: ?[]const u8 = null,
    data_json_owners: ?[]const []const u8 = null,
    // Expiry filters - uses json_extract(data, '$.expiration')
    expiry_gt: ?i64 = null,
    expiry_gte: ?i64 = null,
    expiry_lt: ?i64 = null,
    expiry_lte: ?i64 = null,
    limit: u32 = constants.Pagination.default_limit,
    order_dir: OrderDir = .desc,
};

/// Get events with flexible filtering
pub fn getEventsFiltered(db: *Database, filter: EventFilterOptions) ![]models.Event {
    var sql_buf: [2048]u8 = undefined;
    var sql_len: usize = 0;

    const base_sql = "SELECT event_type, chain, block_number, tx_hash, log_index, contract_address, name, namehash, data, timestamp FROM events";
    @memcpy(sql_buf[sql_len..][0..base_sql.len], base_sql);
    sql_len += base_sql.len;

    var conditions: std.ArrayList([]const u8) = .{};
    defer conditions.deinit(db.allocator);

    // Track allocated IN clause strings for cleanup
    var allocated_clauses: std.ArrayList([]const u8) = .{};
    defer {
        for (allocated_clauses.items) |clause| {
            db.allocator.free(clause);
        }
        allocated_clauses.deinit(db.allocator);
    }

    // Build WHERE conditions
    if (filter.chain != null) {
        try conditions.append(db.allocator, "chain = ?");
    }
    if (filter.event_type != null) {
        try conditions.append(db.allocator, "event_type = ?");
    }
    if (filter.event_types != null and filter.event_types.?.len > 0) {
        var in_clause_buf: [256]u8 = undefined;
        var in_len: usize = 0;
        const prefix = "event_type IN (";
        @memcpy(in_clause_buf[in_len..][0..prefix.len], prefix);
        in_len += prefix.len;
        for (filter.event_types.?, 0..) |_, i| {
            if (i > 0) {
                in_clause_buf[in_len] = ',';
                in_len += 1;
            }
            in_clause_buf[in_len] = '?';
            in_len += 1;
        }
        in_clause_buf[in_len] = ')';
        in_len += 1;
        const clause = try db.allocator.dupe(u8, in_clause_buf[0..in_len]);
        try allocated_clauses.append(db.allocator, clause);
        try conditions.append(db.allocator, clause);
    }
    if (filter.domain != null) {
        try conditions.append(db.allocator, "name = ?");
    }
    if (filter.contract_address != null) {
        try conditions.append(db.allocator, "contract_address = ?");
    }
    if (filter.contract_addresses != null and filter.contract_addresses.?.len > 0) {
        var in_clause_buf: [512]u8 = undefined;
        var in_len: usize = 0;
        const prefix = "contract_address IN (";
        @memcpy(in_clause_buf[in_len..][0..prefix.len], prefix);
        in_len += prefix.len;
        for (filter.contract_addresses.?, 0..) |_, i| {
            if (i > 0) {
                in_clause_buf[in_len] = ',';
                in_len += 1;
            }
            in_clause_buf[in_len] = '?';
            in_len += 1;
        }
        in_clause_buf[in_len] = ')';
        in_len += 1;
        const clause = try db.allocator.dupe(u8, in_clause_buf[0..in_len]);
        try allocated_clauses.append(db.allocator, clause);
        try conditions.append(db.allocator, clause);
    }
    if (filter.namehash != null) {
        try conditions.append(db.allocator, "namehash = ?");
    }
    if (filter.block_number_gt != null) {
        try conditions.append(db.allocator, "block_number > ?");
    }
    if (filter.block_number_lt != null) {
        try conditions.append(db.allocator, "block_number < ?");
    }
    if (filter.timestamp_gt != null) {
        try conditions.append(db.allocator, "timestamp > ?");
    }
    if (filter.timestamp_lt != null) {
        try conditions.append(db.allocator, "timestamp < ?");
    }
    if (filter.data_json_owner != null) {
        try conditions.append(db.allocator, "LOWER(json_extract(data, '$.owner')) = LOWER(?)");
    }
    if (filter.data_json_owners != null and filter.data_json_owners.?.len > 0) {
        var in_clause_buf: [1024]u8 = undefined;
        var in_len: usize = 0;
        const prefix = "LOWER(json_extract(data, '$.owner')) IN (";
        @memcpy(in_clause_buf[in_len..][0..prefix.len], prefix);
        in_len += prefix.len;
        for (filter.data_json_owners.?, 0..) |_, i| {
            if (i > 0) {
                in_clause_buf[in_len] = ',';
                in_len += 1;
            }
            const placeholder = "LOWER(?)";
            @memcpy(in_clause_buf[in_len..][0..placeholder.len], placeholder);
            in_len += placeholder.len;
        }
        in_clause_buf[in_len] = ')';
        in_len += 1;
        const clause = try db.allocator.dupe(u8, in_clause_buf[0..in_len]);
        try allocated_clauses.append(db.allocator, clause);
        try conditions.append(db.allocator, clause);
    }
    if (filter.expiry_gt != null) {
        try conditions.append(db.allocator, "json_extract(data, '$.expiration') > ?");
    }
    if (filter.expiry_gte != null) {
        try conditions.append(db.allocator, "json_extract(data, '$.expiration') >= ?");
    }
    if (filter.expiry_lt != null) {
        try conditions.append(db.allocator, "json_extract(data, '$.expiration') < ?");
    }
    if (filter.expiry_lte != null) {
        try conditions.append(db.allocator, "json_extract(data, '$.expiration') <= ?");
    }

    // Add WHERE clause if there are conditions
    if (conditions.items.len > 0) {
        const where_sql = " WHERE ";
        @memcpy(sql_buf[sql_len..][0..where_sql.len], where_sql);
        sql_len += where_sql.len;

        for (conditions.items, 0..) |cond, i| {
            if (i > 0) {
                const and_sql = " AND ";
                @memcpy(sql_buf[sql_len..][0..and_sql.len], and_sql);
                sql_len += and_sql.len;
            }
            @memcpy(sql_buf[sql_len..][0..cond.len], cond);
            sql_len += cond.len;
        }
    }

    // Add ORDER BY
    const order_sql = if (filter.order_dir == .desc)
        " ORDER BY block_number DESC, log_index DESC LIMIT "
    else
        " ORDER BY block_number ASC, log_index ASC LIMIT ";
    @memcpy(sql_buf[sql_len..][0..order_sql.len], order_sql);
    sql_len += order_sql.len;

    const limit_str = try std.fmt.bufPrint(sql_buf[sql_len..], "{d}", .{filter.limit});
    sql_len += limit_str.len;

    var q = try Query.init(db, sql_buf[0..sql_len]);
    defer q.deinit();

    // Bind parameters in the order they were added to conditions
    if (filter.chain) |ch| {
        try q.bindTextStatic(ch.toString());
    }
    if (filter.event_type) |et| {
        try q.bindText(et);
    }
    if (filter.event_types) |types| {
        for (types) |t| {
            try q.bindText(t);
        }
    }
    if (filter.domain) |d| {
        try q.bindText(d);
    }
    if (filter.contract_address) |ca| {
        try q.bindText(ca);
    }
    if (filter.contract_addresses) |addrs| {
        for (addrs) |addr| {
            try q.bindText(addr);
        }
    }
    if (filter.namehash) |nh| {
        try q.bindText(nh);
    }
    if (filter.block_number_gt) |bn| {
        try q.bindInt64(bn);
    }
    if (filter.block_number_lt) |bn| {
        try q.bindInt64(bn);
    }
    if (filter.timestamp_gt) |ts| {
        try q.bindInt64(ts);
    }
    if (filter.timestamp_lt) |ts| {
        try q.bindInt64(ts);
    }
    if (filter.data_json_owner) |owner| {
        try q.bindText(owner);
    }
    if (filter.data_json_owners) |owners| {
        for (owners) |owner| {
            try q.bindText(owner);
        }
    }
    if (filter.expiry_gt) |exp| {
        try q.bindInt64(exp);
    }
    if (filter.expiry_gte) |exp| {
        try q.bindInt64(exp);
    }
    if (filter.expiry_lt) |exp| {
        try q.bindInt64(exp);
    }
    if (filter.expiry_lte) |exp| {
        try q.bindInt64(exp);
    }

    var events: std.ArrayList(models.Event) = .{};
    errdefer {
        for (events.items) |*event| {
            event.deinit(db.allocator);
        }
        events.deinit(db.allocator);
    }

    while (try q.step()) {
        const event = try parseEventRow(&q, db.allocator);
        try events.append(db.allocator, event);
    }

    return events.toOwnedSlice(db.allocator);
}

/// Get events by namehash (for Domain.events field)
pub fn getEventsByNamehash(db: *Database, namehash_hex: []const u8, limit: u32) ![]models.Event {
    return getEventsFiltered(db, .{
        .namehash = namehash_hex,
        .limit = limit,
    });
}

/// Get events by domain name
pub fn getEventsByDomain(db: *Database, domain_name: []const u8, limit: u32) ![]models.Event {
    return getEventsFiltered(db, .{
        .domain = domain_name,
        .limit = limit,
    });
}

/// Insert or update an approval
pub fn insertApproval(db: *Database, chain: models.Chain, token_id: u256, owner: Address, approved: Address, block_number: u64, tx_hash: Hash) !void {
    const sql =
        \\INSERT OR REPLACE INTO approvals
        \\(chain, token_id, owner, approved, block_number, tx_hash, timestamp)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
    ;

    var q = try Query.init(db, sql);
    defer q.deinit();

    const token_id_str = try std.fmt.allocPrint(db.allocator, "{d}", .{token_id});
    defer db.allocator.free(token_id_str);

    try q.bindTextStatic(chain.toString());
    try q.bindText(token_id_str);
    try q.bindAddress(owner);
    try q.bindAddress(approved);
    try q.bindInt64(@intCast(block_number));
    try q.bindHash(tx_hash);
    try q.bindInt64(std.time.timestamp());

    try q.exec();
}

// ============================================================================
// AGGREGATION OPERATIONS
// ============================================================================

/// Get total count of all events in the database
pub fn getTotalEventCount(db: *Database) !usize {
    return getEventCount(db, .{});
}

/// Get count of events with optional filters.
/// Builds the same WHERE clause as getEventsFiltered but uses SELECT COUNT(*).
pub fn getEventCount(db: *Database, filter: EventFilterOptions) !usize {
    var sql_buf: [2048]u8 = undefined;
    var sql_len: usize = 0;

    const base_sql = "SELECT COUNT(*) FROM events";
    @memcpy(sql_buf[sql_len..][0..base_sql.len], base_sql);
    sql_len += base_sql.len;

    var conditions: std.ArrayList([]const u8) = .{};
    defer conditions.deinit(db.allocator);

    var allocated_clauses: std.ArrayList([]const u8) = .{};
    defer {
        for (allocated_clauses.items) |clause| {
            db.allocator.free(clause);
        }
        allocated_clauses.deinit(db.allocator);
    }

    // Build WHERE conditions (same order as getEventsFiltered)
    if (filter.chain != null) {
        try conditions.append(db.allocator, "chain = ?");
    }
    if (filter.event_type != null) {
        try conditions.append(db.allocator, "event_type = ?");
    }
    if (filter.event_types != null and filter.event_types.?.len > 0) {
        var in_clause_buf: [256]u8 = undefined;
        var in_len: usize = 0;
        const prefix = "event_type IN (";
        @memcpy(in_clause_buf[in_len..][0..prefix.len], prefix);
        in_len += prefix.len;
        for (filter.event_types.?, 0..) |_, i| {
            if (i > 0) {
                in_clause_buf[in_len] = ',';
                in_len += 1;
            }
            in_clause_buf[in_len] = '?';
            in_len += 1;
        }
        in_clause_buf[in_len] = ')';
        in_len += 1;
        const clause = try db.allocator.dupe(u8, in_clause_buf[0..in_len]);
        try allocated_clauses.append(db.allocator, clause);
        try conditions.append(db.allocator, clause);
    }
    if (filter.domain != null) {
        try conditions.append(db.allocator, "name = ?");
    }
    if (filter.contract_address != null) {
        try conditions.append(db.allocator, "contract_address = ?");
    }
    if (filter.contract_addresses != null and filter.contract_addresses.?.len > 0) {
        var in_clause_buf: [512]u8 = undefined;
        var in_len: usize = 0;
        const prefix = "contract_address IN (";
        @memcpy(in_clause_buf[in_len..][0..prefix.len], prefix);
        in_len += prefix.len;
        for (filter.contract_addresses.?, 0..) |_, i| {
            if (i > 0) {
                in_clause_buf[in_len] = ',';
                in_len += 1;
            }
            in_clause_buf[in_len] = '?';
            in_len += 1;
        }
        in_clause_buf[in_len] = ')';
        in_len += 1;
        const clause = try db.allocator.dupe(u8, in_clause_buf[0..in_len]);
        try allocated_clauses.append(db.allocator, clause);
        try conditions.append(db.allocator, clause);
    }
    if (filter.namehash != null) {
        try conditions.append(db.allocator, "namehash = ?");
    }
    if (filter.block_number_gt != null) {
        try conditions.append(db.allocator, "block_number > ?");
    }
    if (filter.block_number_lt != null) {
        try conditions.append(db.allocator, "block_number < ?");
    }
    if (filter.timestamp_gt != null) {
        try conditions.append(db.allocator, "timestamp > ?");
    }
    if (filter.timestamp_lt != null) {
        try conditions.append(db.allocator, "timestamp < ?");
    }
    if (filter.data_json_owner != null) {
        try conditions.append(db.allocator, "LOWER(json_extract(data, '$.owner')) = LOWER(?)");
    }
    if (filter.data_json_owners != null and filter.data_json_owners.?.len > 0) {
        var in_clause_buf: [1024]u8 = undefined;
        var in_len: usize = 0;
        const prefix = "LOWER(json_extract(data, '$.owner')) IN (";
        @memcpy(in_clause_buf[in_len..][0..prefix.len], prefix);
        in_len += prefix.len;
        for (filter.data_json_owners.?, 0..) |_, i| {
            if (i > 0) {
                in_clause_buf[in_len] = ',';
                in_len += 1;
            }
            const placeholder = "LOWER(?)";
            @memcpy(in_clause_buf[in_len..][0..placeholder.len], placeholder);
            in_len += placeholder.len;
        }
        in_clause_buf[in_len] = ')';
        in_len += 1;
        const clause = try db.allocator.dupe(u8, in_clause_buf[0..in_len]);
        try allocated_clauses.append(db.allocator, clause);
        try conditions.append(db.allocator, clause);
    }
    if (filter.expiry_gt != null) {
        try conditions.append(db.allocator, "json_extract(data, '$.expiration') > ?");
    }
    if (filter.expiry_gte != null) {
        try conditions.append(db.allocator, "json_extract(data, '$.expiration') >= ?");
    }
    if (filter.expiry_lt != null) {
        try conditions.append(db.allocator, "json_extract(data, '$.expiration') < ?");
    }
    if (filter.expiry_lte != null) {
        try conditions.append(db.allocator, "json_extract(data, '$.expiration') <= ?");
    }

    if (conditions.items.len > 0) {
        const where_sql = " WHERE ";
        @memcpy(sql_buf[sql_len..][0..where_sql.len], where_sql);
        sql_len += where_sql.len;

        for (conditions.items, 0..) |cond, i| {
            if (i > 0) {
                const and_sql = " AND ";
                @memcpy(sql_buf[sql_len..][0..and_sql.len], and_sql);
                sql_len += and_sql.len;
            }
            @memcpy(sql_buf[sql_len..][0..cond.len], cond);
            sql_len += cond.len;
        }
    }

    var q = try Query.init(db, sql_buf[0..sql_len]);
    defer q.deinit();

    // Bind parameters (same order as getEventsFiltered)
    if (filter.chain) |ch| {
        try q.bindTextStatic(ch.toString());
    }
    if (filter.event_type) |et| {
        try q.bindText(et);
    }
    if (filter.event_types) |types| {
        for (types) |t| {
            try q.bindText(t);
        }
    }
    if (filter.domain) |d| {
        try q.bindText(d);
    }
    if (filter.contract_address) |ca| {
        try q.bindText(ca);
    }
    if (filter.contract_addresses) |addrs| {
        for (addrs) |addr| {
            try q.bindText(addr);
        }
    }
    if (filter.namehash) |nh| {
        try q.bindText(nh);
    }
    if (filter.block_number_gt) |bn| {
        try q.bindInt64(bn);
    }
    if (filter.block_number_lt) |bn| {
        try q.bindInt64(bn);
    }
    if (filter.timestamp_gt) |ts| {
        try q.bindInt64(ts);
    }
    if (filter.timestamp_lt) |ts| {
        try q.bindInt64(ts);
    }
    if (filter.data_json_owner) |owner| {
        try q.bindText(owner);
    }
    if (filter.data_json_owners) |owners| {
        for (owners) |owner| {
            try q.bindText(owner);
        }
    }
    if (filter.expiry_gt) |exp| {
        try q.bindInt64(exp);
    }
    if (filter.expiry_gte) |exp| {
        try q.bindInt64(exp);
    }
    if (filter.expiry_lt) |exp| {
        try q.bindInt64(exp);
    }
    if (filter.expiry_lte) |exp| {
        try q.bindInt64(exp);
    }

    if (try q.step()) {
        return @intCast(q.getInt64(0));
    }
    return 0;
}

/// Count events for a specific domain (by namehash)
pub fn countEventsByNamehash(db: *Database, namehash: Hash) !usize {
    var q = try Query.init(db, "SELECT COUNT(*) FROM events WHERE namehash = ?");
    defer q.deinit();

    try q.bindHash(namehash);

    if (try q.step()) {
        return @intCast(q.getInt64(0));
    }
    return 0;
}

/// Count events for a specific domain (by name)
pub fn countEventsByDomain(db: *Database, domain_name: []const u8) !usize {
    var q = try Query.init(db, "SELECT COUNT(*) FROM events WHERE name = ?");
    defer q.deinit();

    try q.bindText(domain_name);

    if (try q.step()) {
        return @intCast(q.getInt64(0));
    }
    return 0;
}

// ============================================================================
// TESTS
// ============================================================================

// Global counter for unique test event IDs
var test_event_counter: u32 = 0;

fn createTestEvent(
    allocator: std.mem.Allocator,
    event_type: models.EventType,
    name: ?[]const u8,
    namehash_str: ?[]const u8,
    block_number: u64,
    timestamp: i64,
) !models.Event {
    test_event_counter += 1;

    var tx_hash_bytes: [32]u8 = undefined;
    @memset(&tx_hash_bytes, 0);
    std.mem.writeInt(u32, tx_hash_bytes[0..4], test_event_counter, .big);

    return models.Event{
        .event_type = event_type,
        .chain = .l2,
        .block_number = block_number,
        .tx_hash = Hash{ .bytes = tx_hash_bytes },
        .log_index = 0,
        .contract_address = Address.zero,
        .name = if (name) |n| try allocator.dupe(u8, n) else null,
        .namehash = if (namehash_str) |nh| Hash.fromHex(nh) catch null else null,
        .data = try allocator.dupe(u8, "{}"),
        .timestamp = timestamp,
    };
}

test "EventFilterOptions - filter by event type" {
    const allocator = std.testing.allocator;

    var database = try Database.init(allocator, ":memory:");
    defer database.deinit();

    var event1 = try createTestEvent(allocator, .transfer, "test.eth", "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef", 100, 1000);
    defer event1.deinit(allocator);
    try insertEvent(&database, event1);

    var event2 = try createTestEvent(allocator, .name_registered, "test.eth", "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef", 101, 1001);
    defer event2.deinit(allocator);
    try insertEvent(&database, event2);

    var event3 = try createTestEvent(allocator, .transfer, "other.eth", "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890", 102, 1002);
    defer event3.deinit(allocator);
    try insertEvent(&database, event3);

    const transfer_events = try getEventsFiltered(&database, .{
        .event_type = "Transfer",
        .limit = 100,
    });
    defer {
        for (transfer_events) |*e| e.deinit(allocator);
        allocator.free(transfer_events);
    }

    try std.testing.expectEqual(@as(usize, 2), transfer_events.len);
    for (transfer_events) |e| {
        try std.testing.expectEqual(models.EventType.transfer, e.event_type);
    }
}

test "EventFilterOptions - filter by domain name" {
    const allocator = std.testing.allocator;

    var database = try Database.init(allocator, ":memory:");
    defer database.deinit();

    var event1 = try createTestEvent(allocator, .transfer, "vitalik.eth", "0x1111111111111111111111111111111111111111111111111111111111111111", 100, 1000);
    defer event1.deinit(allocator);
    try insertEvent(&database, event1);

    var event2 = try createTestEvent(allocator, .name_renewed, "vitalik.eth", "0x1111111111111111111111111111111111111111111111111111111111111111", 101, 1001);
    defer event2.deinit(allocator);
    try insertEvent(&database, event2);

    var event3 = try createTestEvent(allocator, .transfer, "nick.eth", "0x2222222222222222222222222222222222222222222222222222222222222222", 102, 1002);
    defer event3.deinit(allocator);
    try insertEvent(&database, event3);

    const vitalik_events = try getEventsFiltered(&database, .{
        .domain = "vitalik.eth",
        .limit = 100,
    });
    defer {
        for (vitalik_events) |*e| e.deinit(allocator);
        allocator.free(vitalik_events);
    }

    try std.testing.expectEqual(@as(usize, 2), vitalik_events.len);
    for (vitalik_events) |e| {
        try std.testing.expect(e.name != null);
        try std.testing.expectEqualStrings("vitalik.eth", e.name.?);
    }
}

test "EventFilterOptions - filter by namehash" {
    const allocator = std.testing.allocator;

    var database = try Database.init(allocator, ":memory:");
    defer database.deinit();

    const namehash1 = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const namehash2 = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    var event1 = try createTestEvent(allocator, .text_changed, "test1.eth", namehash1, 100, 1000);
    defer event1.deinit(allocator);
    try insertEvent(&database, event1);

    var event2 = try createTestEvent(allocator, .address_changed, "test1.eth", namehash1, 101, 1001);
    defer event2.deinit(allocator);
    try insertEvent(&database, event2);

    var event3 = try createTestEvent(allocator, .text_changed, "test2.eth", namehash2, 102, 1002);
    defer event3.deinit(allocator);
    try insertEvent(&database, event3);

    const events_by_hash = try getEventsFiltered(&database, .{
        .namehash = namehash1,
        .limit = 100,
    });
    defer {
        for (events_by_hash) |*e| e.deinit(allocator);
        allocator.free(events_by_hash);
    }

    try std.testing.expectEqual(@as(usize, 2), events_by_hash.len);
}

test "EventFilterOptions - filter by block number range" {
    const allocator = std.testing.allocator;

    var database = try Database.init(allocator, ":memory:");
    defer database.deinit();

    var event1 = try createTestEvent(allocator, .transfer, "a.eth", null, 100, 1000);
    defer event1.deinit(allocator);
    try insertEvent(&database, event1);

    var event2 = try createTestEvent(allocator, .transfer, "b.eth", null, 200, 2000);
    defer event2.deinit(allocator);
    try insertEvent(&database, event2);

    var event3 = try createTestEvent(allocator, .transfer, "c.eth", null, 300, 3000);
    defer event3.deinit(allocator);
    try insertEvent(&database, event3);

    var event4 = try createTestEvent(allocator, .transfer, "d.eth", null, 400, 4000);
    defer event4.deinit(allocator);
    try insertEvent(&database, event4);

    const range_events = try getEventsFiltered(&database, .{
        .block_number_gt = 150,
        .block_number_lt = 350,
        .limit = 100,
    });
    defer {
        for (range_events) |*e| e.deinit(allocator);
        allocator.free(range_events);
    }

    try std.testing.expectEqual(@as(usize, 2), range_events.len);
    for (range_events) |e| {
        try std.testing.expect(e.block_number > 150);
        try std.testing.expect(e.block_number < 350);
    }
}

test "EventFilterOptions - filter by timestamp range" {
    const allocator = std.testing.allocator;

    var database = try Database.init(allocator, ":memory:");
    defer database.deinit();

    var event1 = try createTestEvent(allocator, .transfer, "a.eth", null, 100, 1000);
    defer event1.deinit(allocator);
    try insertEvent(&database, event1);

    var event2 = try createTestEvent(allocator, .transfer, "b.eth", null, 101, 2000);
    defer event2.deinit(allocator);
    try insertEvent(&database, event2);

    var event3 = try createTestEvent(allocator, .transfer, "c.eth", null, 102, 3000);
    defer event3.deinit(allocator);
    try insertEvent(&database, event3);

    const range_events = try getEventsFiltered(&database, .{
        .timestamp_gt = 1500,
        .timestamp_lt = 2500,
        .limit = 100,
    });
    defer {
        for (range_events) |*e| e.deinit(allocator);
        allocator.free(range_events);
    }

    try std.testing.expectEqual(@as(usize, 1), range_events.len);
    try std.testing.expectEqual(@as(i64, 2000), range_events[0].timestamp);
}

test "EventFilterOptions - combined filters" {
    const allocator = std.testing.allocator;

    var database = try Database.init(allocator, ":memory:");
    defer database.deinit();

    const namehash = "0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";

    var event1 = try createTestEvent(allocator, .transfer, "combo.eth", namehash, 100, 1000);
    defer event1.deinit(allocator);
    try insertEvent(&database, event1);

    var event2 = try createTestEvent(allocator, .transfer, "combo.eth", namehash, 200, 2000);
    defer event2.deinit(allocator);
    try insertEvent(&database, event2);

    var event3 = try createTestEvent(allocator, .name_registered, "combo.eth", namehash, 150, 1500);
    defer event3.deinit(allocator);
    try insertEvent(&database, event3);

    var event4 = try createTestEvent(allocator, .transfer, "other.eth", null, 175, 1750);
    defer event4.deinit(allocator);
    try insertEvent(&database, event4);

    const combo_events = try getEventsFiltered(&database, .{
        .event_type = "Transfer",
        .domain = "combo.eth",
        .block_number_gt = 50,
        .block_number_lt = 180,
        .limit = 100,
    });
    defer {
        for (combo_events) |*e| e.deinit(allocator);
        allocator.free(combo_events);
    }

    try std.testing.expectEqual(@as(usize, 1), combo_events.len);
    try std.testing.expectEqual(models.EventType.transfer, combo_events[0].event_type);
    try std.testing.expectEqual(@as(u64, 100), combo_events[0].block_number);
}

test "EventFilterOptions - multiple event types (type_in)" {
    const allocator = std.testing.allocator;

    var database = try Database.init(allocator, ":memory:");
    defer database.deinit();

    var event1 = try createTestEvent(allocator, .transfer, "a.eth", null, 100, 1000);
    defer event1.deinit(allocator);
    try insertEvent(&database, event1);

    var event2 = try createTestEvent(allocator, .name_registered, "b.eth", null, 101, 1001);
    defer event2.deinit(allocator);
    try insertEvent(&database, event2);

    var event3 = try createTestEvent(allocator, .name_renewed, "c.eth", null, 102, 1002);
    defer event3.deinit(allocator);
    try insertEvent(&database, event3);

    var event4 = try createTestEvent(allocator, .text_changed, "d.eth", null, 103, 1003);
    defer event4.deinit(allocator);
    try insertEvent(&database, event4);

    const types = [_][]const u8{ "Transfer", "NameRegistered" };
    const multi_type_events = try getEventsFiltered(&database, .{
        .event_types = &types,
        .limit = 100,
    });
    defer {
        for (multi_type_events) |*e| e.deinit(allocator);
        allocator.free(multi_type_events);
    }

    try std.testing.expectEqual(@as(usize, 2), multi_type_events.len);
    for (multi_type_events) |e| {
        try std.testing.expect(e.event_type == .transfer or e.event_type == .name_registered);
    }
}

test "getEventsByNamehash - convenience function" {
    const allocator = std.testing.allocator;

    var database = try Database.init(allocator, ":memory:");
    defer database.deinit();

    const target_namehash = "0xdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";

    var event1 = try createTestEvent(allocator, .transfer, "target.eth", target_namehash, 100, 1000);
    defer event1.deinit(allocator);
    try insertEvent(&database, event1);

    var event2 = try createTestEvent(allocator, .text_changed, "target.eth", target_namehash, 101, 1001);
    defer event2.deinit(allocator);
    try insertEvent(&database, event2);

    var event3 = try createTestEvent(allocator, .transfer, "other.eth", "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", 102, 1002);
    defer event3.deinit(allocator);
    try insertEvent(&database, event3);

    const events = try getEventsByNamehash(&database, target_namehash, 100);
    defer {
        for (events) |*e| e.deinit(allocator);
        allocator.free(events);
    }

    try std.testing.expectEqual(@as(usize, 2), events.len);
}

test "getEventsByDomain - convenience function" {
    const allocator = std.testing.allocator;

    var database = try Database.init(allocator, ":memory:");
    defer database.deinit();

    var event1 = try createTestEvent(allocator, .transfer, "mydomain.eth", null, 100, 1000);
    defer event1.deinit(allocator);
    try insertEvent(&database, event1);

    var event2 = try createTestEvent(allocator, .name_renewed, "mydomain.eth", null, 101, 1001);
    defer event2.deinit(allocator);
    try insertEvent(&database, event2);

    var event3 = try createTestEvent(allocator, .transfer, "otherdomain.eth", null, 102, 1002);
    defer event3.deinit(allocator);
    try insertEvent(&database, event3);

    const events = try getEventsByDomain(&database, "mydomain.eth", 100);
    defer {
        for (events) |*e| e.deinit(allocator);
        allocator.free(events);
    }

    try std.testing.expectEqual(@as(usize, 2), events.len);
    for (events) |e| {
        try std.testing.expect(e.name != null);
        try std.testing.expectEqualStrings("mydomain.eth", e.name.?);
    }
}

test "EventFilterOptions - limit parameter" {
    const allocator = std.testing.allocator;

    var database = try Database.init(allocator, ":memory:");
    defer database.deinit();

    var i: u64 = 0;
    while (i < 20) : (i += 1) {
        var event = try createTestEvent(allocator, .transfer, "test.eth", null, 100 + i, @intCast(1000 + i));
        defer event.deinit(allocator);
        try insertEvent(&database, event);
    }

    const limited_events = try getEventsFiltered(&database, .{
        .limit = 5,
    });
    defer {
        for (limited_events) |*e| e.deinit(allocator);
        allocator.free(limited_events);
    }

    try std.testing.expectEqual(@as(usize, 5), limited_events.len);
}

test "EventFilterOptions - ordering (desc by default)" {
    const allocator = std.testing.allocator;

    var database = try Database.init(allocator, ":memory:");
    defer database.deinit();

    var event1 = try createTestEvent(allocator, .transfer, "a.eth", null, 100, 1000);
    defer event1.deinit(allocator);
    try insertEvent(&database, event1);

    var event2 = try createTestEvent(allocator, .transfer, "b.eth", null, 200, 2000);
    defer event2.deinit(allocator);
    try insertEvent(&database, event2);

    var event3 = try createTestEvent(allocator, .transfer, "c.eth", null, 300, 3000);
    defer event3.deinit(allocator);
    try insertEvent(&database, event3);

    const desc_events = try getEventsFiltered(&database, .{
        .limit = 100,
        .order_dir = .desc,
    });
    defer {
        for (desc_events) |*e| e.deinit(allocator);
        allocator.free(desc_events);
    }

    try std.testing.expectEqual(@as(usize, 3), desc_events.len);
    try std.testing.expectEqual(@as(u64, 300), desc_events[0].block_number);
    try std.testing.expectEqual(@as(u64, 200), desc_events[1].block_number);
    try std.testing.expectEqual(@as(u64, 100), desc_events[2].block_number);

    const asc_events = try getEventsFiltered(&database, .{
        .limit = 100,
        .order_dir = .asc,
    });
    defer {
        for (asc_events) |*e| e.deinit(allocator);
        allocator.free(asc_events);
    }

    try std.testing.expectEqual(@as(usize, 3), asc_events.len);
    try std.testing.expectEqual(@as(u64, 100), asc_events[0].block_number);
    try std.testing.expectEqual(@as(u64, 200), asc_events[1].block_number);
    try std.testing.expectEqual(@as(u64, 300), asc_events[2].block_number);
}

test "EventFilterOptions - empty result" {
    const allocator = std.testing.allocator;

    var database = try Database.init(allocator, ":memory:");
    defer database.deinit();

    var event = try createTestEvent(allocator, .transfer, "exists.eth", null, 100, 1000);
    defer event.deinit(allocator);
    try insertEvent(&database, event);

    const no_events = try getEventsFiltered(&database, .{
        .domain = "nonexistent.eth",
        .limit = 100,
    });
    defer allocator.free(no_events);

    try std.testing.expectEqual(@as(usize, 0), no_events.len);
}

test "EventFilterOptions - all V2 event types" {
    const allocator = std.testing.allocator;

    var database = try Database.init(allocator, ":memory:");
    defer database.deinit();

    const event_types = [_]models.EventType{
        .new_subname,
        .subregistry_update,
        .resolver_update,
        .transfer,
        .name_registered,
        .name_renewed,
        .name_burned,
        .commitment_made,
        .token_regenerated,
        .approval,
        .name_migrated,
        .name_ejected_to_l1,
        .name_returned_to_l2,
        .metadata_changed,
        .resolver_approved,
        .text_changed,
        .address_changed,
        .contenthash_changed,
        .abi_changed,
        .pubkey_changed,
        .name_changed,
        .interface_changed,
    };

    for (event_types, 0..) |et, i| {
        var event = try createTestEvent(allocator, et, "test.eth", null, 100 + i, @intCast(1000 + i));
        defer event.deinit(allocator);
        try insertEvent(&database, event);
    }

    const all_events = try getEventsFiltered(&database, .{
        .limit = 100,
    });
    defer {
        for (all_events) |*e| e.deinit(allocator);
        allocator.free(all_events);
    }

    try std.testing.expectEqual(event_types.len, all_events.len);

    for (event_types) |et| {
        const type_events = try getEventsFiltered(&database, .{
            .event_type = et.toString(),
            .limit = 10,
        });
        defer {
            for (type_events) |*e| e.deinit(allocator);
            allocator.free(type_events);
        }

        try std.testing.expectEqual(@as(usize, 1), type_events.len);
        try std.testing.expectEqual(et, type_events[0].event_type);
    }
}
