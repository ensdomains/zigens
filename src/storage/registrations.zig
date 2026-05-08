const std = @import("std");
const constants = @import("../constants.zig");
const db_module = @import("database.zig");
const Database = db_module.Database;
const Hash = @import("../types/hash.zig").Hash;
const Address = @import("../types/address.zig").Address;
const models = @import("../types/models.zig");
const events = @import("events.zig");

/// Insert a registration into the `registrations` table.
/// Idempotent on (protocol, transaction_hash, log_index) via UNIQUE constraint.
///
/// Single canonical writer per (protocol, namehash) — V1 is `handleV1BaseRegistrarNameRegistered`,
/// V2 (fresh + migrated) is `handleLabelRegistered`. Notably, V2's
/// `handleETHNameRegistered` does NOT insert here; that event carries payment
/// metadata and lives in the `events` table only, to keep one row per logical
/// registration in this table.
pub fn insertRegistration(
    db: *Database,
    protocol: models.Protocol,
    namehash: Hash,
    label: []const u8,
    parent_name: []const u8,
    registrant: Address,
    registered_at: i64,
    expiry: ?u64,
    block_number: u64,
    tx_hash: Hash,
    log_index: u32,
    event_type: models.EventType,
) !void {
    const sql =
        \\INSERT OR IGNORE INTO registrations
        \\(protocol, namehash, label, parent_name, registrant, registered_at, expiry, block_number, transaction_hash, log_index, event_type)
        \\VALUES (?, ?, ?, ?, LOWER(?), ?, ?, ?, ?, ?, ?)
    ;

    var q = try db_module.Query.initCached(db, sql);
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());
    try q.bindHash(namehash);
    try q.bindText(label);
    try q.bindText(parent_name);
    try q.bindAddress(registrant);
    try q.bindInt64(registered_at);
    if (expiry) |e| {
        const clamped: i64 = if (e > std.math.maxInt(i64)) 0 else @intCast(e);
        if (e > std.math.maxInt(i64)) {
            std.log.warn("insertRegistration: expiry {d} exceeds i64 max; storing 0 (matches names.zig convention)", .{e});
        }
        try q.bindInt64(clamped);
    } else {
        try q.bindNull();
    }
    try q.bindInt64(@intCast(block_number));
    try q.bindHash(tx_hash);
    try q.bindInt(@intCast(log_index));
    try q.bindTextStatic(event_type.toString());

    try q.exec();
}

// ============================================================================
// REGISTRATION QUERIES
// ============================================================================
// Reads from the dedicated `registrations` table (schema/021).
//
// Previously this module derived registrations from the `events` table via
// `event_type IN ('NameRegistered','LabelRegistered')`. That double-counted
// every fresh V2 .eth registration because it emits two events in the same tx
// (one from IETHRegistrar, one from PermissionedRegistry). The first-class
// table avoids that — handlers write exactly one row per registration.
//
// Filters work on typed columns directly (registrant, expiry) rather than
// `json_extract(data, '$.owner')` over a TEXT blob — simpler SQL, faster
// queries, no surprise NULLs from JSON shape mismatches.
// ============================================================================

pub const RegistrationFilterOptions = struct {
    /// Filter by protocol (v1/v2). Null = all.
    protocol: ?models.Protocol = null,
    /// Filter by registrant address (lowercase 0x-prefixed). Null = all.
    registrant: ?[]const u8 = null,
    /// Filter by registrant IN list. Null = all. Caller-owned slice.
    registrant_in: ?[]const []const u8 = null,
    limit: u32 = constants.Pagination.default_limit,
    skip: u32 = 0,
    order_dir: events.OrderDir = .desc,
    sort_field: events.EventSortField = .block_number,
    expiry_gt: ?i64 = null,
    expiry_gte: ?i64 = null,
    expiry_lt: ?i64 = null,
    expiry_lte: ?i64 = null,
};

/// Map an EventSortField to a registrations-table column name. The events-table
/// `expiry` sort uses a complex COALESCE over JSON; on the registrations table
/// we just sort on the typed column.
fn sortColumn(sort_field: events.EventSortField) []const u8 {
    return switch (sort_field) {
        .block_number => "block_number",
        .timestamp => "registered_at",
        .name => "label",
        .expiry => "expiry",
    };
}

/// Append WHERE conditions for a registrations-table query. `allocated_clauses`
/// owns dynamically-built IN clauses so the caller can free them.
fn appendFilterConditions(
    db: *Database,
    filter: RegistrationFilterOptions,
    conditions: *std.ArrayList([]const u8),
    allocated_clauses: *std.ArrayList([]const u8),
) !void {
    if (filter.protocol != null) try conditions.append(db.allocator, "protocol = ?");
    if (filter.registrant != null) try conditions.append(db.allocator, "registrant = LOWER(?)");
    if (filter.registrant_in) |list| {
        if (list.len > 0) {
            var in_parts: std.ArrayList(u8) = .{};
            defer in_parts.deinit(db.allocator);
            try in_parts.appendSlice(db.allocator, "registrant IN (");
            for (list, 0..) |_, i| {
                if (i > 0) try in_parts.append(db.allocator, ',');
                try in_parts.append(db.allocator, '?');
            }
            try in_parts.append(db.allocator, ')');
            const clause = try db.allocator.dupe(u8, in_parts.items);
            try allocated_clauses.append(db.allocator, clause);
            try conditions.append(db.allocator, clause);
        }
    }
    if (filter.expiry_gt != null) try conditions.append(db.allocator, "expiry > ?");
    if (filter.expiry_gte != null) try conditions.append(db.allocator, "expiry >= ?");
    if (filter.expiry_lt != null) try conditions.append(db.allocator, "expiry < ?");
    if (filter.expiry_lte != null) try conditions.append(db.allocator, "expiry <= ?");
}

/// Bind values for the conditions appended by `appendFilterConditions`. Order
/// must match exactly.
fn bindFilters(q: *db_module.Query, filter: RegistrationFilterOptions) !void {
    if (filter.protocol) |p| try q.bindTextStatic(p.toString());
    if (filter.registrant) |r| try q.bindText(r);
    if (filter.registrant_in) |list| {
        for (list) |addr| try q.bindText(addr);
    }
    if (filter.expiry_gt) |v| try q.bindInt64(v);
    if (filter.expiry_gte) |v| try q.bindInt64(v);
    if (filter.expiry_lt) |v| try q.bindInt64(v);
    if (filter.expiry_lte) |v| try q.bindInt64(v);
}

/// Build a synthetic models.Event from a registrations row. The resolver/
/// builder layer expects models.Event values; we adapt rather than duplicate
/// the entire builder stack. The constructed `data` JSON carries the keys the
/// builders look up (`name`, `owner`, `expiry`).
fn rowToEvent(allocator: std.mem.Allocator, q: *db_module.Query) !models.Event {
    // Column order matches the SELECT in `getRegistrations` and `cursorBlockOf`.
    //  0: protocol, 1: namehash, 2: label, 3: parent_name, 4: registrant,
    //  5: registered_at, 6: expiry, 7: block_number, 8: transaction_hash,
    //  9: log_index, 10: event_type
    const protocol_str = q.getTextSlice(0) orelse return error.RegistrationRowMissingProtocol;
    const namehash_str = q.getTextSlice(1) orelse return error.RegistrationRowMissingNamehash;
    const label = q.getTextSlice(2) orelse "";
    const parent = q.getTextSlice(3) orelse "";
    const registrant = q.getTextSlice(4) orelse "0x0000000000000000000000000000000000000000";
    const registered_at = q.getInt64(5);
    const expiry_raw: ?i64 = if (q.isNull(6)) null else q.getInt64(6);
    const block_number: u64 = @intCast(q.getInt64(7));
    const tx_hash_str = q.getTextSlice(8) orelse return error.RegistrationRowMissingTxHash;
    const log_index: u32 = @intCast(q.getInt(9));
    const event_type_str = q.getTextSlice(10) orelse return error.RegistrationRowMissingEventType;

    const protocol = models.Protocol.fromString(protocol_str) catch return error.RegistrationRowInvalidProtocol;
    const event_type = models.EventType.fromString(event_type_str) orelse return error.RegistrationRowInvalidEventType;
    const namehash = try Hash.fromHex(namehash_str);
    const tx_hash = try Hash.fromHex(tx_hash_str);

    // event.name = "label.parent_name" (or just "label" when parent is empty).
    const name = if (parent.len == 0)
        try allocator.dupe(u8, label)
    else
        try std.fmt.allocPrint(allocator, "{s}.{s}", .{ label, parent });
    errdefer allocator.free(name);

    // event.data: builders read `owner` and `expiry`. Keep `name` for any
    // caller that inspects it.
    const data = if (expiry_raw) |e|
        try std.fmt.allocPrint(allocator, "{{\"name\":\"{s}\",\"owner\":\"{s}\",\"expiry\":{d}}}", .{ name, registrant, e })
    else
        try std.fmt.allocPrint(allocator, "{{\"name\":\"{s}\",\"owner\":\"{s}\"}}", .{ name, registrant });
    errdefer allocator.free(data);

    return models.Event{
        .event_type = event_type,
        .protocol = protocol,
        .block_number = block_number,
        .tx_hash = tx_hash,
        .log_index = log_index,
        .contract_address = Address.zero, // Not stored in registrations; resolvers don't query it.
        .name = name,
        .namehash = namehash,
        .data = data,
        .timestamp = registered_at,
    };
}

/// Get registrations matching the filter, ordered by `sort_field`/`order_dir`.
/// Returns synthetic Event values for resolver/builder compat. Caller owns the
/// slice and each Event (deinit each).
pub fn getRegistrations(database: *Database, filter: RegistrationFilterOptions) ![]models.Event {
    const base_sql =
        "SELECT protocol, namehash, label, parent_name, registrant, registered_at, " ++
        "expiry, block_number, transaction_hash, log_index, event_type FROM registrations";

    var sql_buf: std.ArrayList(u8) = .{};
    defer sql_buf.deinit(database.allocator);
    try sql_buf.appendSlice(database.allocator, base_sql);

    var conditions: std.ArrayList([]const u8) = .{};
    defer conditions.deinit(database.allocator);
    var allocated_clauses: std.ArrayList([]const u8) = .{};
    defer {
        for (allocated_clauses.items) |s| database.allocator.free(s);
        allocated_clauses.deinit(database.allocator);
    }
    try appendFilterConditions(database, filter, &conditions, &allocated_clauses);

    if (conditions.items.len > 0) {
        try sql_buf.appendSlice(database.allocator, " WHERE ");
        for (conditions.items, 0..) |cond, i| {
            if (i > 0) try sql_buf.appendSlice(database.allocator, " AND ");
            try sql_buf.appendSlice(database.allocator, cond);
        }
    }

    try sql_buf.appendSlice(database.allocator, " ORDER BY ");
    try sql_buf.appendSlice(database.allocator, sortColumn(filter.sort_field));
    try sql_buf.appendSlice(database.allocator, if (filter.order_dir == .desc) " DESC" else " ASC");
    try sql_buf.appendSlice(database.allocator, ", id ");
    try sql_buf.appendSlice(database.allocator, if (filter.order_dir == .desc) "DESC" else "ASC");
    try sql_buf.appendSlice(database.allocator, " LIMIT ? OFFSET ?");

    var q = try db_module.Query.init(database, sql_buf.items);
    defer q.deinit();

    try bindFilters(&q, filter);
    try q.bindInt(@intCast(filter.limit));
    try q.bindInt(@intCast(filter.skip));

    var results: std.ArrayList(models.Event) = .{};
    errdefer {
        for (results.items) |*ev| ev.deinit(database.allocator);
        results.deinit(database.allocator);
    }

    while (try q.step()) {
        const ev = try rowToEvent(database.allocator, &q);
        try results.append(database.allocator, ev);
    }

    return results.toOwnedSlice(database.allocator);
}

/// Count registrations matching the filter. Matches `getRegistrations`'s
/// WHERE clause exactly so paginated cursor offsets are consistent.
pub fn getRegistrationCount(database: *Database, filter: RegistrationFilterOptions) !usize {
    var sql_buf: std.ArrayList(u8) = .{};
    defer sql_buf.deinit(database.allocator);
    try sql_buf.appendSlice(database.allocator, "SELECT COUNT(*) FROM registrations");

    var conditions: std.ArrayList([]const u8) = .{};
    defer conditions.deinit(database.allocator);
    var allocated_clauses: std.ArrayList([]const u8) = .{};
    defer {
        for (allocated_clauses.items) |s| database.allocator.free(s);
        allocated_clauses.deinit(database.allocator);
    }
    try appendFilterConditions(database, filter, &conditions, &allocated_clauses);

    if (conditions.items.len > 0) {
        try sql_buf.appendSlice(database.allocator, " WHERE ");
        for (conditions.items, 0..) |cond, i| {
            if (i > 0) try sql_buf.appendSlice(database.allocator, " AND ");
            try sql_buf.appendSlice(database.allocator, cond);
        }
    }

    var q = try db_module.Query.initCached(database, sql_buf.items);
    defer q.deinit();
    try bindFilters(&q, filter);
    if (!try q.step()) return 0;
    return @intCast(q.getInt64(0));
}

/// Count registrations strictly "before" the cursor (transaction_hash, log_index)
/// in the given order direction, applying the same filters as `getRegistrations`.
/// Used by the connection-pagination resolver to convert a cursor to a SKIP offset.
pub fn countRegistrationsBeforeCursor(
    database: *Database,
    tx_hash_hex: []const u8,
    log_index: u32,
    order_dir: events.OrderDir,
    filter: RegistrationFilterOptions,
) !u32 {
    // Resolve the cursor row's block_number first.
    var lookup = try db_module.Query.init(
        database,
        "SELECT block_number FROM registrations WHERE transaction_hash = ? AND log_index = ? LIMIT 1",
    );
    defer lookup.deinit();
    try lookup.bindText(tx_hash_hex);
    try lookup.bindInt(@intCast(log_index));
    if (!try lookup.step()) return 0;
    const cursor_block = lookup.getInt64(0);

    var sql_buf: std.ArrayList(u8) = .{};
    defer sql_buf.deinit(database.allocator);

    const base = if (order_dir == .desc)
        "SELECT COUNT(*) FROM registrations WHERE (block_number > ? OR (block_number = ? AND log_index > ?))"
    else
        "SELECT COUNT(*) FROM registrations WHERE (block_number < ? OR (block_number = ? AND log_index < ?))";
    try sql_buf.appendSlice(database.allocator, base);

    var conditions: std.ArrayList([]const u8) = .{};
    defer conditions.deinit(database.allocator);
    var allocated_clauses: std.ArrayList([]const u8) = .{};
    defer {
        for (allocated_clauses.items) |s| database.allocator.free(s);
        allocated_clauses.deinit(database.allocator);
    }
    try appendFilterConditions(database, filter, &conditions, &allocated_clauses);
    for (conditions.items) |cond| {
        try sql_buf.appendSlice(database.allocator, " AND ");
        try sql_buf.appendSlice(database.allocator, cond);
    }

    var q = try db_module.Query.initCached(database, sql_buf.items);
    defer q.deinit();
    try q.bindInt64(cursor_block);
    try q.bindInt64(cursor_block);
    try q.bindInt(@intCast(log_index));
    try bindFilters(&q, filter);
    if (!try q.step()) return 0;
    return @intCast(q.getInt64(0));
}

// ============================================================================
// TESTS
// ============================================================================

test "getRegistrations reads from registrations table" {
    // Smoke: module compiles. Real coverage lives in tests/storage tests with
    // a populated DB fixture (out of scope here).
}
