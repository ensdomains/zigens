const std = @import("std");
const zsys = @import("../utils/system.zig");
const constants = @import("../constants.zig");
const db_module = @import("database.zig");
const reorg_undo = @import("reorg_undo.zig");
const Database = db_module.Database;
const Query = db_module.Query;
const models = @import("../types/models.zig");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

/// Parse a single event row from query results
/// Column order: event_type(0), protocol(1), block_number(2), tx_hash(3), log_index(4),
///               contract_address(5), name(6), namehash(7), data(8), timestamp(9)
fn parseEventRow(q: *Query, allocator: std.mem.Allocator) !models.Event {
    const event_type_str = q.getTextSlice(0) orelse models.EventType.transfer.toString();
    const protocol_str = q.getTextSlice(1) orelse models.Protocol.v2.toString();
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
        .protocol = try models.Protocol.fromString(protocol_str),
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
    const sql = try db.upsertSql(db.allocator, "events", &.{ "event_type", "protocol", "block_number", "tx_hash", "log_index", "contract_address", "name", "namehash", "data", "timestamp" }, .ignore);
    defer db.allocator.free(sql);

    var q = try Query.initCached(db, sql);
    defer q.deinit();

    // Bind event type and protocol as static text
    const event_type_str = event.event_type.toString();
    const protocol_str = event.protocol.toString();
    try q.bindTextStatic(event_type_str);
    try q.bindTextStatic(protocol_str);
    try q.bindInt64(@intCast(event.block_number));
    try q.bindHashBuf(event.tx_hash);
    try q.bindInt(@intCast(event.log_index));
    try q.bindAddressBuf(event.contract_address);
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

/// Sort field for event queries
pub const EventSortField = enum {
    block_number,
    timestamp,
    name,
    /// Sort by the JSON-encoded expiry. Uses the same COALESCE expression as
    /// the expiry_* filters so ordering and filtering are consistent. Lets
    /// SQLite handle the sort instead of the resolver pulling 10k rows and
    /// sorting in memory.
    expiry,

    /// Non-JSON sort columns (valid verbatim on both backends). `.expiry` extracts JSON
    /// data fields, so it is dialect-dependent and built via `expirySortExpr` instead.
    pub fn toSql(self: EventSortField) []const u8 {
        return switch (self) {
            .block_number => "block_number",
            .timestamp => "timestamp",
            .name => "name",
            .expiry => "", // built dialect-aware by expirySortExpr; never used directly
        };
    }
};

/// `CAST(<json data.$.field> AS INTEGER)` — portable numeric JSON access. SQLite:
/// `CAST(json_extract(data,'$.field') AS INTEGER)` (unchanged); Postgres:
/// `CAST((data::jsonb ->> 'field') AS INTEGER)`. The explicit CAST (cast_type=null on
/// jsonExtract) keeps the SQLite form identical and is valid on both. Caller owns result.
fn jsonDataInt(db: *Database, field: []const u8) ![]u8 {
    const je = try db.dialect().jsonExtract(db.allocator, "data", field, null);
    defer db.allocator.free(je);
    return std.fmt.allocPrint(db.allocator, "CAST({s} AS INTEGER)", .{je});
}

/// `LOWER(<json data.$.field>)` — portable case-folded text access. Caller owns result.
fn jsonDataLower(db: *Database, field: []const u8) ![]u8 {
    const je = try db.dialect().jsonExtract(db.allocator, "data", field, null);
    defer db.allocator.free(je);
    return std.fmt.allocPrint(db.allocator, "LOWER({s})", .{je});
}

/// Dialect-aware expiry ordering/filtering expression: the registration expiry from
/// `data.$.expiry`/`$.expiration`, else `timestamp + data.$.duration`. `with_expiration`
/// includes the `$.expiration` fallback (the sort does; the filter doesn't). Caller owns.
fn expirySortExpr(db: *Database, with_expiration: bool) ![]u8 {
    const expiry = try jsonDataInt(db, "expiry");
    defer db.allocator.free(expiry);
    const duration = try jsonDataInt(db, "duration");
    defer db.allocator.free(duration);
    if (with_expiration) {
        const expiration = try jsonDataInt(db, "expiration");
        defer db.allocator.free(expiration);
        return std.fmt.allocPrint(db.allocator, "COALESCE({s}, {s}, timestamp + {s})", .{ expiry, expiration, duration });
    }
    return std.fmt.allocPrint(db.allocator, "COALESCE({s}, timestamp + {s})", .{ expiry, duration });
}

/// The ORDER BY column expression for a sort field, shared by getEventsFiltered and
/// countEventsBeforeCursor so the fetch order and the cursor-position count agree exactly.
/// `.name` is COALESCE'd so NULL names order deterministically; `.expiry` is the JSON expr.
/// Caller owns the returned string.
fn sortColExpr(db: *Database, sort_field: EventSortField) ![]u8 {
    return switch (sort_field) {
        .block_number => db.allocator.dupe(u8, "block_number"),
        .timestamp => db.allocator.dupe(u8, "timestamp"),
        .name => db.allocator.dupe(u8, "COALESCE(name, '')"),
        .expiry => expirySortExpr(db, true),
    };
}

pub fn getRecentEvents(db: *Database, protocol: ?models.Protocol, event_type: ?models.EventType, limit: u32) ![]models.Event {
    return getRecentEventsWithOrder(db, protocol, event_type, limit, .desc);
}

/// Get recent events with configurable order direction (for backward pagination support)
pub fn getRecentEventsWithOrder(db: *Database, protocol: ?models.Protocol, event_type: ?models.EventType, limit: u32, order_dir: OrderDir) ![]models.Event {
    var sql_buf: [512]u8 = undefined;
    var sql_len: usize = 0;

    const base_sql = "SELECT event_type, protocol, block_number, tx_hash, log_index, contract_address, name, namehash, data, timestamp FROM events";
    @memcpy(sql_buf[sql_len..][0..base_sql.len], base_sql);
    sql_len += base_sql.len;

    if (protocol != null or event_type != null) {
        const where_sql = " WHERE ";
        @memcpy(sql_buf[sql_len..][0..where_sql.len], where_sql);
        sql_len += where_sql.len;

        if (protocol != null) {
            const protocol_filter = "protocol = ?";
            @memcpy(sql_buf[sql_len..][0..protocol_filter.len], protocol_filter);
            sql_len += protocol_filter.len;

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

    var q = try Query.initCached(db, sql_buf[0..sql_len]);
    defer q.deinit();

    // Bind parameters
    if (protocol) |ch| {
        try q.bindTextStatic(ch.toString());
    }
    if (event_type) |et| {
        try q.bindTextStatic(et.toString());
    }

    var events: std.ArrayList(models.Event) = .empty;
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
    event_type_not: ?[]const u8 = null,
    event_types_not: ?[]const []const u8 = null,
    protocol: ?models.Protocol = null,
    domain: ?[]const u8 = null,
    contract_address: ?[]const u8 = null,
    contract_addresses: ?[]const []const u8 = null,
    namehash: ?[]const u8 = null,
    block_number_gt: ?i64 = null,
    block_number_gte: ?i64 = null,
    block_number_lt: ?i64 = null,
    block_number_lte: ?i64 = null,
    timestamp_gt: ?i64 = null,
    timestamp_gte: ?i64 = null,
    timestamp_lt: ?i64 = null,
    timestamp_lte: ?i64 = null,
    data_json_owner: ?[]const u8 = null,
    data_json_owners: ?[]const []const u8 = null,
    // Expiry filters - uses json_extract(data, '$.expiration')
    expiry_gt: ?i64 = null,
    expiry_gte: ?i64 = null,
    expiry_lt: ?i64 = null,
    expiry_lte: ?i64 = null,
    /// Subgraph-style boolean composition (GraphQL `and` / `or`), nesting recursively.
    and_group: ?[]const EventFilterOptions = null,
    or_group: ?[]const EventFilterOptions = null,
    limit: u32 = constants.Pagination.default_limit,
    skip: u32 = 0,
    order_dir: OrderDir = .desc,
    sort_field: EventSortField = .block_number,
};

/// Append the WHERE conditions (no leading AND/WHERE) corresponding to `filter` into
/// `conditions`. Dynamic IN-clause strings are tracked in `allocated_clauses` so the
/// caller can free them after use. Kept in lockstep with `bindEventFilters`.
fn appendEventFilterConditions(
    db: *Database,
    filter: EventFilterOptions,
    conditions: *std.ArrayList([]const u8),
    allocated_clauses: *std.ArrayList([]const u8),
) !void {
    // Events have no default-visibility filters — the whole WHERE is the user's
    // predicate tree (this node's scalars + recursive and/or).
    if (try buildEventNodeExpr(db, filter, allocated_clauses)) |expr| {
        try conditions.append(db.allocator, expr);
    }
}

/// One event-filter node's scalar predicates (no and/or).
fn appendEventScalarConditions(
    db: *Database,
    filter: EventFilterOptions,
    conditions: *std.ArrayList([]const u8),
    allocated_clauses: *std.ArrayList([]const u8),
) !void {
    if (filter.protocol != null) try conditions.append(db.allocator, "protocol = ?");
    if (filter.event_type != null) try conditions.append(db.allocator, "event_type = ?");
    if (filter.event_type_not != null) try conditions.append(db.allocator, "event_type != ?");
    if (filter.event_types != null and filter.event_types.?.len > 0) {
        var in_parts: std.ArrayList(u8) = .empty;
        defer in_parts.deinit(db.allocator);
        try in_parts.appendSlice(db.allocator, "event_type IN (");
        for (filter.event_types.?, 0..) |_, i| {
            if (i > 0) try in_parts.append(db.allocator, ',');
            try in_parts.append(db.allocator, '?');
        }
        try in_parts.append(db.allocator, ')');
        const clause = try db.allocator.dupe(u8, in_parts.items);
        try allocated_clauses.append(db.allocator, clause);
        try conditions.append(db.allocator, clause);
    }
    if (filter.event_types_not != null and filter.event_types_not.?.len > 0) {
        var in_parts: std.ArrayList(u8) = .empty;
        defer in_parts.deinit(db.allocator);
        try in_parts.appendSlice(db.allocator, "event_type NOT IN (");
        for (filter.event_types_not.?, 0..) |_, i| {
            if (i > 0) try in_parts.append(db.allocator, ',');
            try in_parts.append(db.allocator, '?');
        }
        try in_parts.append(db.allocator, ')');
        const clause = try db.allocator.dupe(u8, in_parts.items);
        try allocated_clauses.append(db.allocator, clause);
        try conditions.append(db.allocator, clause);
    }
    if (filter.domain != null) try conditions.append(db.allocator, "name = ?");
    if (filter.contract_address != null) try conditions.append(db.allocator, "contract_address = ?");
    if (filter.contract_addresses != null and filter.contract_addresses.?.len > 0) {
        var in_parts: std.ArrayList(u8) = .empty;
        defer in_parts.deinit(db.allocator);
        try in_parts.appendSlice(db.allocator, "contract_address IN (");
        for (filter.contract_addresses.?, 0..) |_, i| {
            if (i > 0) try in_parts.append(db.allocator, ',');
            try in_parts.append(db.allocator, '?');
        }
        try in_parts.append(db.allocator, ')');
        const clause = try db.allocator.dupe(u8, in_parts.items);
        try allocated_clauses.append(db.allocator, clause);
        try conditions.append(db.allocator, clause);
    }
    if (filter.namehash != null) try conditions.append(db.allocator, "namehash = ?");
    if (filter.block_number_gt != null) try conditions.append(db.allocator, "block_number > ?");
    if (filter.block_number_gte != null) try conditions.append(db.allocator, "block_number >= ?");
    if (filter.block_number_lt != null) try conditions.append(db.allocator, "block_number < ?");
    if (filter.block_number_lte != null) try conditions.append(db.allocator, "block_number <= ?");
    if (filter.timestamp_gt != null) try conditions.append(db.allocator, "timestamp > ?");
    if (filter.timestamp_gte != null) try conditions.append(db.allocator, "timestamp >= ?");
    if (filter.timestamp_lt != null) try conditions.append(db.allocator, "timestamp < ?");
    if (filter.timestamp_lte != null) try conditions.append(db.allocator, "timestamp <= ?");
    if (filter.data_json_owner != null) {
        const owner_lower = try jsonDataLower(db, "owner");
        defer db.allocator.free(owner_lower);
        const clause = try std.fmt.allocPrint(db.allocator, "{s} = LOWER(?)", .{owner_lower});
        try allocated_clauses.append(db.allocator, clause);
        try conditions.append(db.allocator, clause);
    }
    if (filter.data_json_owners != null and filter.data_json_owners.?.len > 0) {
        const owner_lower = try jsonDataLower(db, "owner");
        defer db.allocator.free(owner_lower);
        var in_parts: std.ArrayList(u8) = .empty;
        defer in_parts.deinit(db.allocator);
        try in_parts.print(db.allocator, "{s} IN (", .{owner_lower});
        for (filter.data_json_owners.?, 0..) |_, i| {
            if (i > 0) try in_parts.append(db.allocator, ',');
            try in_parts.appendSlice(db.allocator, "LOWER(?)");
        }
        try in_parts.append(db.allocator, ')');
        const clause = try db.allocator.dupe(u8, in_parts.items);
        try allocated_clauses.append(db.allocator, clause);
        try conditions.append(db.allocator, clause);
    }
    // Registration-style expiry filter (V2: data.$.expiry; V1: timestamp + data.$.duration).
    if (filter.expiry_gt != null or filter.expiry_gte != null or filter.expiry_lt != null or filter.expiry_lte != null) {
        const expiry_expr = try expirySortExpr(db, false); // filter omits the $.expiration fallback
        defer db.allocator.free(expiry_expr);
        if (filter.expiry_gt != null) try appendExpiryCond(db, conditions, allocated_clauses, expiry_expr, ">");
        if (filter.expiry_gte != null) try appendExpiryCond(db, conditions, allocated_clauses, expiry_expr, ">=");
        if (filter.expiry_lt != null) try appendExpiryCond(db, conditions, allocated_clauses, expiry_expr, "<");
        if (filter.expiry_lte != null) try appendExpiryCond(db, conditions, allocated_clauses, expiry_expr, "<=");
    }
}

fn appendExpiryCond(
    db: *Database,
    conditions: *std.ArrayList([]const u8),
    allocated_clauses: *std.ArrayList([]const u8),
    expiry_expr: []const u8,
    op: []const u8,
) !void {
    const clause = try std.fmt.allocPrint(db.allocator, "{s} {s} ?", .{ expiry_expr, op });
    try allocated_clauses.append(db.allocator, clause);
    try conditions.append(db.allocator, clause);
}

/// Recursively build one event-filter node's boolean SQL (scalars + and/or).
fn buildEventNodeExpr(
    db: *Database,
    filter: EventFilterOptions,
    allocated_clauses: *std.ArrayList([]const u8),
) anyerror!?[]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(db.allocator);
    try appendEventScalarConditions(db, filter, &parts, allocated_clauses);
    if (filter.and_group) |children| {
        for (children) |child| {
            if (try buildEventNodeExpr(db, child, allocated_clauses)) |sub| try parts.append(db.allocator, sub);
        }
    }
    if (filter.or_group) |children| {
        var or_parts: std.ArrayList([]const u8) = .empty;
        defer or_parts.deinit(db.allocator);
        for (children) |child| {
            if (try buildEventNodeExpr(db, child, allocated_clauses)) |sub| try or_parts.append(db.allocator, sub);
        }
        if (or_parts.items.len > 0) {
            const joined = try db_module.query.joinWrapped(db.allocator, or_parts.items, " OR ");
            try allocated_clauses.append(db.allocator, joined);
            try parts.append(db.allocator, joined);
        }
    }
    if (parts.items.len == 0) return null;
    if (parts.items.len == 1) return parts.items[0];
    const joined = try db_module.query.joinWrapped(db.allocator, parts.items, " AND ");
    try allocated_clauses.append(db.allocator, joined);
    return joined;
}

/// Bind values for `filter` in the same order the SQL is built: scalars, then and, then or.
fn bindEventFilters(q: *Query, filter: EventFilterOptions) anyerror!void {
    try bindEventScalars(q, filter);
    if (filter.and_group) |children| {
        for (children) |child| try bindEventFilters(q, child);
    }
    if (filter.or_group) |children| {
        for (children) |child| try bindEventFilters(q, child);
    }
}

/// Bind one node's scalars in the same order `appendEventScalarConditions` appends them.
fn bindEventScalars(q: *Query, filter: EventFilterOptions) !void {
    if (filter.protocol) |c| try q.bindTextStatic(c.toString());
    if (filter.event_type) |t| try q.bindText(t);
    if (filter.event_type_not) |t| try q.bindText(t);
    if (filter.event_types) |types| {
        for (types) |t| try q.bindText(t);
    }
    if (filter.event_types_not) |types| {
        for (types) |t| try q.bindText(t);
    }
    if (filter.domain) |d| try q.bindText(d);
    if (filter.contract_address) |a| try q.bindText(a);
    if (filter.contract_addresses) |addrs| {
        for (addrs) |a| try q.bindText(a);
    }
    if (filter.namehash) |nh| try q.bindText(nh);
    if (filter.block_number_gt) |v| try q.bindInt64(v);
    if (filter.block_number_gte) |v| try q.bindInt64(v);
    if (filter.block_number_lt) |v| try q.bindInt64(v);
    if (filter.block_number_lte) |v| try q.bindInt64(v);
    if (filter.timestamp_gt) |v| try q.bindInt64(v);
    if (filter.timestamp_gte) |v| try q.bindInt64(v);
    if (filter.timestamp_lt) |v| try q.bindInt64(v);
    if (filter.timestamp_lte) |v| try q.bindInt64(v);
    if (filter.data_json_owner) |o| try q.bindText(o);
    if (filter.data_json_owners) |owners| {
        for (owners) |o| try q.bindText(o);
    }
    if (filter.expiry_gt) |v| try q.bindInt64(v);
    if (filter.expiry_gte) |v| try q.bindInt64(v);
    if (filter.expiry_lt) |v| try q.bindInt64(v);
    if (filter.expiry_lte) |v| try q.bindInt64(v);
}

/// Count events that sort BEFORE the event identified by (tx_hash, log_index)
/// in the events table's canonical (block_number, log_index) order. Used to
/// convert a cursor to a skip offset for paginated queries on registrations/events.
///
/// `filter` must match the filter applied to the row-fetch query — without it the offset
/// is computed over the unfiltered superset and pagination skips too many rows.
///
/// Returns 0 if the cursor's event can't be found (caller should fall through to offset=0).
pub fn countEventsBeforeCursor(
    db: *Database,
    tx_hash: []const u8,
    log_index: u32,
    order_dir: OrderDir,
    filter: EventFilterOptions,
) !u32 {
    // Count in the SAME total order the row query uses: (sort_col, block_number, log_index).
    // A cursor identifies a unique row; count rows strictly before it in that order, so
    // OFFSET = count + 1 lands exactly on the next page with no dropped/duplicated rows.
    const sort_expr = try sortColExpr(db, filter.sort_field);
    defer db.allocator.free(sort_expr);
    const is_text_sort = filter.sort_field == .name;

    // Resolve the cursor row's full sort tuple (sort_value, block_number, log_index).
    const lookup_sql = try std.fmt.allocPrint(db.allocator, "SELECT {s}, block_number, log_index FROM events WHERE tx_hash = ? AND log_index = ? LIMIT 1", .{sort_expr});
    defer db.allocator.free(lookup_sql);
    var lookup = try Query.init(db, lookup_sql);
    defer lookup.deinit();
    try lookup.bindText(tx_hash);
    try lookup.bindInt(@intCast(log_index));
    if (!try lookup.step()) return 0;
    const cursor_sort_int: i64 = if (is_text_sort) 0 else lookup.getInt64(0);
    const cursor_sort_text: []const u8 = try db.allocator.dupe(u8, if (is_text_sort) (lookup.getTextSlice(0) orelse "") else "");
    defer db.allocator.free(cursor_sort_text);
    const cursor_block = lookup.getInt64(1);
    const cursor_log = lookup.getInt64(2);

    // "before" in the display order: DESC → higher tuple, ASC → lower tuple. Filters must
    // match the row query or the offset is taken over the wrong (super)set.
    const op: []const u8 = if (order_dir == .desc) ">" else "<";
    var sql_buf: std.ArrayList(u8) = .empty;
    defer sql_buf.deinit(db.allocator);
    const pred = try std.fmt.allocPrint(db.allocator, "SELECT COUNT(*) FROM events WHERE ({s} {s} ? OR ({s} = ? AND (block_number {s} ? OR (block_number = ? AND log_index {s} ?))))", .{ sort_expr, op, sort_expr, op, op });
    defer db.allocator.free(pred);
    try sql_buf.appendSlice(db.allocator, pred);

    var conditions: std.ArrayList([]const u8) = .empty;
    defer conditions.deinit(db.allocator);
    var allocated_clauses: std.ArrayList([]const u8) = .empty;
    defer {
        for (allocated_clauses.items) |s| db.allocator.free(s);
        allocated_clauses.deinit(db.allocator);
    }
    try appendEventFilterConditions(db, filter, &conditions, &allocated_clauses);
    for (conditions.items) |cond| {
        try sql_buf.appendSlice(db.allocator, " AND ");
        try sql_buf.appendSlice(db.allocator, cond);
    }

    var q = try Query.initCached(db, sql_buf.items);
    defer q.deinit();
    if (is_text_sort) {
        try q.bindText(cursor_sort_text);
        try q.bindText(cursor_sort_text);
    } else {
        try q.bindInt64(cursor_sort_int);
        try q.bindInt64(cursor_sort_int);
    }
    try q.bindInt64(cursor_block);
    try q.bindInt64(cursor_block);
    try q.bindInt64(cursor_log);
    try bindEventFilters(&q, filter);
    if (!try q.step()) return 0;
    return @intCast(q.getInt64(0));
}

/// Get events with flexible filtering
pub fn getEventsFiltered(db: *Database, filter: EventFilterOptions) ![]models.Event {
    var sql_buf: [2048]u8 = undefined;
    var sql_len: usize = 0;

    const base_sql = "SELECT event_type, protocol, block_number, tx_hash, log_index, contract_address, name, namehash, data, timestamp FROM events";
    @memcpy(sql_buf[sql_len..][0..base_sql.len], base_sql);
    sql_len += base_sql.len;

    var conditions: std.ArrayList([]const u8) = .empty;
    defer conditions.deinit(db.allocator);

    // Track allocated IN clause strings for cleanup
    var allocated_clauses: std.ArrayList([]const u8) = .empty;
    defer {
        for (allocated_clauses.items) |clause| {
            db.allocator.free(clause);
        }
        allocated_clauses.deinit(db.allocator);
    }

    try appendEventFilterConditions(db, filter, &conditions, &allocated_clauses);

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
    const order_by_prefix = " ORDER BY ";
    @memcpy(sql_buf[sql_len..][0..order_by_prefix.len], order_by_prefix);
    sql_len += order_by_prefix.len;

    // Shared sort-column expression (see sortColExpr) so the fetch order matches the
    // cursor-position count exactly.
    const sort_col = try sortColExpr(db, filter.sort_field);
    defer db.allocator.free(sort_col);
    @memcpy(sql_buf[sql_len..][0..sort_col.len], sort_col);
    sql_len += sort_col.len;

    const dir_str = if (filter.order_dir == .desc) " DESC" else " ASC";
    @memcpy(sql_buf[sql_len..][0..dir_str.len], dir_str);
    sql_len += dir_str.len;

    // Total order: (block_number, log_index) is unique, so appending it as a final
    // tiebreaker makes pagination deterministic for every sort field (no two rows tie).
    const tiebreak = if (filter.sort_field == .block_number)
        (if (filter.order_dir == .desc) ", log_index DESC" else ", log_index ASC")
    else
        (if (filter.order_dir == .desc) ", block_number DESC, log_index DESC" else ", block_number ASC, log_index ASC");
    @memcpy(sql_buf[sql_len..][0..tiebreak.len], tiebreak);
    sql_len += tiebreak.len;

    const limit_prefix = " LIMIT ";
    @memcpy(sql_buf[sql_len..][0..limit_prefix.len], limit_prefix);
    sql_len += limit_prefix.len;

    const limit_str = try std.fmt.bufPrint(sql_buf[sql_len..], "{d}", .{filter.limit});
    sql_len += limit_str.len;

    if (filter.skip > 0) {
        const offset_prefix = " OFFSET ";
        @memcpy(sql_buf[sql_len..][0..offset_prefix.len], offset_prefix);
        sql_len += offset_prefix.len;
        const offset_str = try std.fmt.bufPrint(sql_buf[sql_len..], "{d}", .{filter.skip});
        sql_len += offset_str.len;
    }

    var q = try Query.initCached(db, sql_buf[0..sql_len]);
    defer q.deinit();

    try bindEventFilters(&q, filter);

    var events: std.ArrayList(models.Event) = .empty;
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
/// Update token_id for all approvals when a token is regenerated.
/// Scoped by registry to avoid cross-registry collisions.
pub fn updateApprovalTokenId(db: *Database, old_token_id: []const u8, new_token_id: []const u8, registry: Address) !void {
    try reorg_undo.captureWhere(db, "approvals", "U", "token_id = ? AND registry = ?", .{ old_token_id, registry });
    const sql = "UPDATE approvals SET token_id = ? WHERE token_id = ? AND registry = ?";

    var q = try Query.initCached(db, sql);
    defer q.deinit();

    try q.bindText(new_token_id);
    try q.bindText(old_token_id);
    try q.bindAddress(registry);

    try q.exec();
}

pub fn insertApproval(db: *Database, protocol: models.Protocol, token_id: u256, owner: Address, approved: Address, block_number: u64, tx_hash: Hash, registry: Address) !void {
    const sql = try db.upsertSql(db.allocator, "approvals", &.{ "protocol", "token_id", "owner", "approved", "block_number", "tx_hash", "timestamp", "registry" }, .replace);
    defer db.allocator.free(sql);

    var q = try Query.initCached(db, sql);
    defer q.deinit();

    const token_id_str = try std.fmt.allocPrint(db.allocator, "{d}", .{token_id});
    defer db.allocator.free(token_id_str);
    try reorg_undo.captureUpsert(db, "approvals", .{ protocol, token_id_str, registry });

    try q.bindTextStatic(protocol.toString());
    try q.bindText(token_id_str);
    try q.bindAddress(owner);
    try q.bindAddress(approved);
    try q.bindInt64(@intCast(block_number));
    try q.bindHash(tx_hash);
    try q.bindInt64(zsys.timestamp());
    try q.bindAddress(registry);

    try q.exec();
}

// ============================================================================
// AGGREGATION OPERATIONS
// ============================================================================

/// Get count of events with optional filters.
/// Builds the same WHERE clause as getEventsFiltered but uses SELECT COUNT(*).
pub fn getEventCount(db: *Database, filter: EventFilterOptions) !usize {
    var sql_buf: [2048]u8 = undefined;
    var sql_len: usize = 0;

    const base_sql = "SELECT COUNT(*) FROM events";
    @memcpy(sql_buf[sql_len..][0..base_sql.len], base_sql);
    sql_len += base_sql.len;

    var conditions: std.ArrayList([]const u8) = .empty;
    defer conditions.deinit(db.allocator);

    var allocated_clauses: std.ArrayList([]const u8) = .empty;
    defer {
        for (allocated_clauses.items) |clause| {
            db.allocator.free(clause);
        }
        allocated_clauses.deinit(db.allocator);
    }

    try appendEventFilterConditions(db, filter, &conditions, &allocated_clauses);

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

    var q = try Query.initCached(db, sql_buf[0..sql_len]);
    defer q.deinit();

    try bindEventFilters(&q, filter);

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
        .protocol = .v2,
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

test "connection pagination reproduces the full ordered result with no drops/dupes (all sort fields)" {
    const allocator = std.testing.allocator;
    var database = try Database.init(allocator, ":memory:");
    defer database.deinit();

    // Insert events with deliberate TIES on every sort field: same block (diff log_index),
    // same timestamp across blocks, repeated + NULL names — so a non-total order would drop
    // or duplicate rows across pages.
    const Row = struct { blk: u64, log: u32, ts: i64, name: ?[]const u8 };
    const rows = [_]Row{
        .{ .blk = 100, .log = 0, .ts = 1000, .name = "b.eth" },
        .{ .blk = 100, .log = 1, .ts = 1000, .name = "a.eth" },
        .{ .blk = 100, .log = 2, .ts = 1000, .name = null },
        .{ .blk = 101, .log = 0, .ts = 1000, .name = "a.eth" },
        .{ .blk = 101, .log = 1, .ts = 1001, .name = "c.eth" },
        .{ .blk = 102, .log = 0, .ts = 1001, .name = null },
        .{ .blk = 102, .log = 1, .ts = 1002, .name = "b.eth" },
        .{ .blk = 103, .log = 0, .ts = 1002, .name = "a.eth" },
    };
    for (rows, 0..) |r, i| {
        var tx = [_]u8{0} ** 32;
        std.mem.writeInt(u32, tx[0..4], @intCast(i + 1), .big);
        var ev = models.Event{
            .event_type = .transfer,
            .protocol = .v2,
            .block_number = r.blk,
            .tx_hash = Hash{ .bytes = tx },
            .log_index = r.log,
            .contract_address = Address.zero,
            .name = if (r.name) |n| try allocator.dupe(u8, n) else null,
            .namehash = null,
            .data = try allocator.dupe(u8, "{}"),
            .timestamp = r.ts,
        };
        defer ev.deinit(allocator);
        try insertEvent(&database, ev);
    }

    const sorts = [_]EventSortField{ .block_number, .timestamp, .name };
    const dirs = [_]OrderDir{ .desc, .asc };
    for (sorts) |sf| {
        for (dirs) |dir| {
            // Ground truth: the full ordered result.
            const full = try getEventsFiltered(&database, .{ .sort_field = sf, .order_dir = dir, .limit = 1000 });
            defer {
                for (full) |*e| e.deinit(database.allocator);
                database.allocator.free(full);
            }

            // Paginate in pages of 3, walking the cursor exactly like the connection resolver.
            var collected: std.ArrayList(struct { blk: u64, log: u32 }) = .empty;
            defer collected.deinit(allocator);
            var skip: u32 = 0;
            while (true) {
                const page = try getEventsFiltered(&database, .{ .sort_field = sf, .order_dir = dir, .limit = 3, .skip = skip });
                defer {
                    for (page) |*e| e.deinit(database.allocator);
                    database.allocator.free(page);
                }
                if (page.len == 0) break;
                for (page) |e| try collected.append(allocator, .{ .blk = e.block_number, .log = e.log_index });
                const last = page[page.len - 1];
                const tx_hex = try last.tx_hash.toHex(allocator);
                defer allocator.free(tx_hex);
                const before = try countEventsBeforeCursor(&database, tx_hex, last.log_index, dir, .{ .sort_field = sf, .order_dir = dir });
                skip = before + 1;
                if (page.len < 3) break;
            }

            // Paginated sequence must equal the full sequence exactly (order + membership).
            try std.testing.expectEqual(full.len, collected.items.len);
            for (full, collected.items) |f, c| {
                try std.testing.expectEqual(f.block_number, c.blk);
                try std.testing.expectEqual(f.log_index, c.log);
            }
        }
    }
}
