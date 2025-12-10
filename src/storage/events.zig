const std = @import("std");
const db_module = @import("database.zig");
const Database = db_module.Database;
const c = db_module.c;
const models = @import("../types/models.zig");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;

// SQLITE_TRANSIENT - For Zig 0.15.1, we can't use the C constant due to alignment issues
// Instead, we use null which tells SQLite to make a copy of the string
inline fn SQLITE_TRANSIENT() c.sqlite3_destructor_type {
    return null;
}

// ============================================================================
// EVENT OPERATIONS (3 functions)
// ============================================================================

pub fn insertEvent(db: *Database, event: models.Event) !void {
    const sql =
        \\INSERT OR IGNORE INTO events
        \\(event_type, chain, block_number, tx_hash, log_index, contract_address,
        \\ name, namehash, data, timestamp)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ;

    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare insert event statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    const event_type_str = event.event_type.toString();
    const chain_str = event.chain.toString();

    const tx_hash_hex = try event.tx_hash.toHex(db.allocator);
    const contract_hex = try event.contract_address.toHex(db.allocator);
    const nh_hex = if (event.namehash) |nh| try nh.toHex(db.allocator) else null;

    // Defer all allocations until AFTER sqlite3_step() completes
    // Even though SQLITE_TRANSIENT() tells SQLite to copy, the copy happens during step()
    defer {
        db.allocator.free(tx_hash_hex);
        db.allocator.free(contract_hex);
        if (nh_hex) |h| db.allocator.free(h);
    }

    _ = c.sqlite3_bind_text(stmt, 1, event_type_str.ptr, @intCast(event_type_str.len), c.SQLITE_STATIC);
    _ = c.sqlite3_bind_text(stmt, 2, chain_str.ptr, @intCast(chain_str.len), c.SQLITE_STATIC);
    _ = c.sqlite3_bind_int64(stmt, 3, @intCast(event.block_number));
    _ = c.sqlite3_bind_text(stmt, 4, tx_hash_hex.ptr, @intCast(tx_hash_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int(stmt, 5, @intCast(event.log_index));
    _ = c.sqlite3_bind_text(stmt, 6, contract_hex.ptr, @intCast(contract_hex.len), SQLITE_TRANSIENT());

    if (event.name) |name| {
        _ = c.sqlite3_bind_text(stmt, 7, name.ptr, @intCast(name.len), SQLITE_TRANSIENT());
    } else {
        _ = c.sqlite3_bind_null(stmt, 7);
    }

    if (nh_hex) |h| {
        _ = c.sqlite3_bind_text(stmt, 8, h.ptr, @intCast(h.len), SQLITE_TRANSIENT());
    } else {
        _ = c.sqlite3_bind_null(stmt, 8);
    }

    _ = c.sqlite3_bind_text(stmt, 9, event.data.ptr, @intCast(event.data.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 10, event.timestamp);

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to insert event: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.InsertFailed;
    }
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

    var param_count: u8 = 0;
    if (chain != null or event_type != null) {
        const where_sql = " WHERE ";
        @memcpy(sql_buf[sql_len..][0..where_sql.len], where_sql);
        sql_len += where_sql.len;

        if (chain != null) {
            const chain_filter = "chain = ?";
            @memcpy(sql_buf[sql_len..][0..chain_filter.len], chain_filter);
            sql_len += chain_filter.len;
            param_count += 1;

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
            param_count += 1;
        }
    }

    // Use order direction for backward pagination support
    const order_sql = if (order_dir == .desc)
        " ORDER BY block_number DESC, log_index DESC LIMIT "
    else
        " ORDER BY block_number ASC, log_index ASC LIMIT ";
    @memcpy(sql_buf[sql_len..][0..order_sql.len], order_sql);
    sql_len += order_sql.len;

    const limit_str = try std.fmt.bufPrint(sql_buf[sql_len..], "{d}", .{limit});
    sql_len += limit_str.len;

    const sql = sql_buf[0..sql_len];
    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare get events statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    // Bind parameters
    var param_idx: c_int = 1;
    if (chain) |ch| {
        const chain_str = ch.toString();
        _ = c.sqlite3_bind_text(stmt, param_idx, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());
        param_idx += 1;
    }
    if (event_type) |et| {
        const type_str = et.toString();
        _ = c.sqlite3_bind_text(stmt, param_idx, type_str.ptr, @intCast(type_str.len), SQLITE_TRANSIENT());
    }

    var events: std.ArrayList(models.Event) = .{};
    errdefer {
        for (events.items) |*event| {
            event.deinit(db.allocator);
        }
        events.deinit(db.allocator);
    }

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const event_type_str = std.mem.span(c.sqlite3_column_text(stmt, 0));
        const chain_str = std.mem.span(c.sqlite3_column_text(stmt, 1));
        const tx_hash_str = std.mem.span(c.sqlite3_column_text(stmt, 3));
        const contract_addr_str = std.mem.span(c.sqlite3_column_text(stmt, 5));
        const data_str = std.mem.span(c.sqlite3_column_text(stmt, 8));

        const name_col = c.sqlite3_column_text(stmt, 6);
        const name_val = if (name_col != null) try db.allocator.dupe(u8, std.mem.span(name_col)) else null;

        const namehash_col = c.sqlite3_column_text(stmt, 7);
        const namehash_val = if (namehash_col != null) blk: {
            const hash_str = std.mem.span(namehash_col);
            // Check if it's valid hex (should start with 0x and be 66 chars)
            if (hash_str.len == 66 and hash_str[0] == '0' and hash_str[1] == 'x') {
                break :blk Hash.fromHex(hash_str) catch null;
            } else {
                break :blk null;
            }
        } else null;

        const event = models.Event{
            .event_type = models.EventType.fromString(event_type_str) orelse .transfer,
            .chain = try models.Chain.fromString(chain_str),
            .block_number = @intCast(c.sqlite3_column_int64(stmt, 2)),
            .tx_hash = try Hash.fromHex(tx_hash_str),
            .log_index = @intCast(c.sqlite3_column_int(stmt, 4)),
            .contract_address = try Address.fromHex(contract_addr_str),
            .name = name_val,
            .namehash = namehash_val,
            .data = try db.allocator.dupe(u8, data_str),
            .timestamp = c.sqlite3_column_int64(stmt, 9),
        };

        try events.append(db.allocator, event);
    }

    return events.toOwnedSlice(db.allocator);
}

/// Event filter options for flexible querying
pub const EventFilterOptions = struct {
    event_type: ?[]const u8 = null,
    event_types: ?[]const []const u8 = null,
    domain: ?[]const u8 = null,
    contract_address: ?[]const u8 = null,
    namehash: ?[]const u8 = null,
    block_number_gt: ?i64 = null,
    block_number_lt: ?i64 = null,
    timestamp_gt: ?i64 = null,
    timestamp_lt: ?i64 = null,
    limit: u32 = 100,
    order_dir: OrderDir = .desc,
};

/// Get events with flexible filtering
pub fn getEventsFiltered(db: *Database, filter: EventFilterOptions) ![]models.Event {
    var sql_buf: [1024]u8 = undefined;
    var sql_len: usize = 0;

    const base_sql = "SELECT event_type, chain, block_number, tx_hash, log_index, contract_address, name, namehash, data, timestamp FROM events";
    @memcpy(sql_buf[sql_len..][0..base_sql.len], base_sql);
    sql_len += base_sql.len;

    var conditions: std.ArrayList([]const u8) = .{};
    defer conditions.deinit(db.allocator);

    // Build WHERE conditions
    if (filter.event_type != null) {
        try conditions.append(db.allocator, "event_type = ?");
    }
    if (filter.event_types != null and filter.event_types.?.len > 0) {
        // Build IN clause placeholder
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
        try conditions.append(db.allocator, try db.allocator.dupe(u8, in_clause_buf[0..in_len]));
    }
    if (filter.domain != null) {
        try conditions.append(db.allocator, "name = ?");
    }
    if (filter.contract_address != null) {
        try conditions.append(db.allocator, "contract_address = ?");
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

    const sql = sql_buf[0..sql_len];
    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare get events filtered statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    // Bind parameters in the order they were added to conditions
    var param_idx: c_int = 1;
    if (filter.event_type) |et| {
        _ = c.sqlite3_bind_text(stmt, param_idx, et.ptr, @intCast(et.len), SQLITE_TRANSIENT());
        param_idx += 1;
    }
    if (filter.event_types) |types| {
        for (types) |t| {
            _ = c.sqlite3_bind_text(stmt, param_idx, t.ptr, @intCast(t.len), SQLITE_TRANSIENT());
            param_idx += 1;
        }
    }
    if (filter.domain) |d| {
        _ = c.sqlite3_bind_text(stmt, param_idx, d.ptr, @intCast(d.len), SQLITE_TRANSIENT());
        param_idx += 1;
    }
    if (filter.contract_address) |ca| {
        _ = c.sqlite3_bind_text(stmt, param_idx, ca.ptr, @intCast(ca.len), SQLITE_TRANSIENT());
        param_idx += 1;
    }
    if (filter.namehash) |nh| {
        _ = c.sqlite3_bind_text(stmt, param_idx, nh.ptr, @intCast(nh.len), SQLITE_TRANSIENT());
        param_idx += 1;
    }
    if (filter.block_number_gt) |bn| {
        _ = c.sqlite3_bind_int64(stmt, param_idx, bn);
        param_idx += 1;
    }
    if (filter.block_number_lt) |bn| {
        _ = c.sqlite3_bind_int64(stmt, param_idx, bn);
        param_idx += 1;
    }
    if (filter.timestamp_gt) |ts| {
        _ = c.sqlite3_bind_int64(stmt, param_idx, ts);
        param_idx += 1;
    }
    if (filter.timestamp_lt) |ts| {
        _ = c.sqlite3_bind_int64(stmt, param_idx, ts);
        param_idx += 1;
    }

    var events: std.ArrayList(models.Event) = .{};
    errdefer {
        for (events.items) |*event| {
            event.deinit(db.allocator);
        }
        events.deinit(db.allocator);
    }

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const event_type_str = std.mem.span(c.sqlite3_column_text(stmt, 0));
        const chain_str = std.mem.span(c.sqlite3_column_text(stmt, 1));
        const tx_hash_str = std.mem.span(c.sqlite3_column_text(stmt, 3));
        const contract_addr_str = std.mem.span(c.sqlite3_column_text(stmt, 5));
        const data_str = std.mem.span(c.sqlite3_column_text(stmt, 8));

        const name_col = c.sqlite3_column_text(stmt, 6);
        const name_val = if (name_col != null) try db.allocator.dupe(u8, std.mem.span(name_col)) else null;

        const namehash_col = c.sqlite3_column_text(stmt, 7);
        const namehash_val = if (namehash_col != null) blk: {
            const hash_str = std.mem.span(namehash_col);
            if (hash_str.len == 66 and hash_str[0] == '0' and hash_str[1] == 'x') {
                break :blk Hash.fromHex(hash_str) catch null;
            } else {
                break :blk null;
            }
        } else null;

        const event = models.Event{
            .event_type = models.EventType.fromString(event_type_str) orelse .transfer,
            .chain = try models.Chain.fromString(chain_str),
            .block_number = @intCast(c.sqlite3_column_int64(stmt, 2)),
            .tx_hash = try Hash.fromHex(tx_hash_str),
            .log_index = @intCast(c.sqlite3_column_int(stmt, 4)),
            .contract_address = try Address.fromHex(contract_addr_str),
            .name = name_val,
            .namehash = namehash_val,
            .data = try db.allocator.dupe(u8, data_str),
            .timestamp = c.sqlite3_column_int64(stmt, 9),
        };

        try events.append(db.allocator, event);
    }

    // Free allocated IN clause strings
    for (conditions.items) |cond| {
        if (std.mem.startsWith(u8, cond, "event_type IN")) {
            db.allocator.free(cond);
        }
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

    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare insert approval statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    const chain_str = chain.toString();
    const token_id_str = try std.fmt.allocPrint(db.allocator, "{d}", .{token_id});
    defer db.allocator.free(token_id_str);
    const owner_hex = try owner.toHex(db.allocator);
    defer db.allocator.free(owner_hex);
    const approved_hex = try approved.toHex(db.allocator);
    defer db.allocator.free(approved_hex);
    const tx_hash_hex = try tx_hash.toHex(db.allocator);
    defer db.allocator.free(tx_hash_hex);
    const timestamp = std.time.timestamp();

    _ = c.sqlite3_bind_text(stmt, 1, chain_str.ptr, @intCast(chain_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 2, token_id_str.ptr, @intCast(token_id_str.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 3, owner_hex.ptr, @intCast(owner_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 4, approved_hex.ptr, @intCast(approved_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 5, @intCast(block_number));
    _ = c.sqlite3_bind_text(stmt, 6, tx_hash_hex.ptr, @intCast(tx_hash_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 7, timestamp);

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to insert approval: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.InsertFailed;
    }
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
    // Generate unique tx_hash based on counter to avoid UNIQUE constraint violations
    // Events table has UNIQUE(chain, tx_hash, log_index) constraint
    test_event_counter += 1;

    // Create a unique tx_hash by embedding the counter in the hash
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

    // Insert test events
    var event1 = try createTestEvent(allocator, .transfer, "test.eth", "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef", 100, 1000);
    defer event1.deinit(allocator);
    try insertEvent(&database, event1);

    var event2 = try createTestEvent(allocator, .name_registered, "test.eth", "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef", 101, 1001);
    defer event2.deinit(allocator);
    try insertEvent(&database, event2);

    var event3 = try createTestEvent(allocator, .transfer, "other.eth", "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890", 102, 1002);
    defer event3.deinit(allocator);
    try insertEvent(&database, event3);

    // Test filter by event type
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

    // Test block range filter (150 < block < 350)
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

    // Test timestamp range filter (1500 < timestamp < 2500)
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

    // Test combined filter: Transfer events for combo.eth between blocks 50-180
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

    // Test filter with multiple types
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

    // Insert many events
    var i: u64 = 0;
    while (i < 20) : (i += 1) {
        var event = try createTestEvent(allocator, .transfer, "test.eth", null, 100 + i, @intCast(1000 + i));
        defer event.deinit(allocator);
        try insertEvent(&database, event);
    }

    // Test with limit
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

    // Test default ordering (desc)
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

    // Test ascending ordering
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

    // Query for non-existent domain
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

    // Insert one of each event type to verify they can all be stored and queried
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

    // Query all events
    const all_events = try getEventsFiltered(&database, .{
        .limit = 100,
    });
    defer {
        for (all_events) |*e| e.deinit(allocator);
        allocator.free(all_events);
    }

    try std.testing.expectEqual(event_types.len, all_events.len);

    // Verify each type can be filtered
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
