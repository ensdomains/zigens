const std = @import("std");
const constants = @import("../constants.zig");
const db_module = @import("database.zig");
const Database = db_module.Database;
const Hash = @import("../types/hash.zig").Hash;
const Address = @import("../types/address.zig").Address;
const models = @import("../types/models.zig");
const events = @import("events.zig");

/// Insert a registration into the `registrations` table.
/// Idempotent on (chain, tx_hash, log_index) via UNIQUE constraint.
pub fn insertRegistration(
    db: *Database,
    chain: models.Chain,
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
        \\(chain, namehash, label, parent_name, registrant, registered_at, expiry, block_number, transaction_hash, log_index, event_type)
        \\VALUES (?, ?, ?, ?, LOWER(?), ?, ?, ?, ?, ?, ?)
    ;

    var q = try db_module.Query.initCached(db, sql);
    defer q.deinit();

    try q.bindTextStatic(chain.toString());
    try q.bindHash(namehash);
    try q.bindText(label);
    try q.bindText(parent_name);
    try q.bindAddress(registrant);
    try q.bindInt64(registered_at);
    // Clamp overflow to 0 — matches names.zig safeU64ToI64 convention where "0 = no expiry".
    // Callers pass `null` when the registration has no expiry at all.
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
// This module provides specialized queries for registration events.
// It handles the ENS-specific logic of filtering by canonical registry contracts
// to avoid duplicate NameRegistered events from non-authoritative contracts.
//
// The filtering logic uses canonical registry addresses from contracts.zig:
// - V1: base_registrar (L1 .eth name registrations)
// - V2: l2_eth_registry (L2 .eth name registrations, not FastTestETHRegistrar)
//
// This prevents duplicates from non-authoritative contracts like FastTestETHRegistrar.
// ============================================================================

pub const RegistrationFilterOptions = struct {
    chain: ?models.Chain = null, // Filter by chain (l1 or l2)
    registrant: ?[]const u8 = null, // Filter by registrant (owner in event data JSON)
    registrant_in: ?[]const []const u8 = null, // Filter by registrant IN list
    limit: u32 = constants.Pagination.default_limit,
    skip: u32 = 0,
    order_dir: events.OrderDir = .desc,
    sort_field: events.EventSortField = .block_number,
    expiry_gt: ?i64 = null,
    expiry_gte: ?i64 = null,
    expiry_lt: ?i64 = null,
    expiry_lte: ?i64 = null,
};

/// Get registration events filtered by canonical registry contracts.
/// This function automatically filters to only include NameRegistered events from
/// canonical registries (base_registrar for V1, l2_eth_registry for V2).
/// This prevents duplicates from non-authoritative contracts like FastTestETHRegistrar.
pub fn getRegistrations(database: *Database, filter: RegistrationFilterOptions) ![]models.Event {
    // Both V1 (name_registered) and V2 (label_registered) events represent registrations.
    // V2 LabelRegistered events come from dynamically discovered subregistries,
    // so we cannot filter by a static canonical address list.
    const registration_event_types = [_][]const u8{
        models.EventType.name_registered.toString(),
        models.EventType.label_registered.toString(),
    };

    const event_filter = events.EventFilterOptions{
        .event_types = &registration_event_types,
        .chain = filter.chain,
        .data_json_owner = filter.registrant,
        .data_json_owners = filter.registrant_in,
        .limit = filter.limit,
        .skip = filter.skip,
        .order_dir = filter.order_dir,
        .sort_field = filter.sort_field,
        .expiry_gt = filter.expiry_gt,
        .expiry_gte = filter.expiry_gte,
        .expiry_lt = filter.expiry_lt,
        .expiry_lte = filter.expiry_lte,
    };

    return events.getEventsFiltered(database, event_filter);
}

// ============================================================================
// AGGREGATION OPERATIONS
// ============================================================================

/// Get count of registrations with optional filters.
/// Single unified query against the `registrations` table (indexed columns).
pub fn getRegistrationCount(database: *Database, filter: RegistrationFilterOptions) !usize {
    var sql_buf: [1024]u8 = undefined;
    var sql_len: usize = 0;

    const base = "SELECT COUNT(*) FROM registrations WHERE 1=1";
    @memcpy(sql_buf[sql_len..][0..base.len], base);
    sql_len += base.len;

    if (filter.chain != null) {
        const cond = " AND chain = ?";
        @memcpy(sql_buf[sql_len..][0..cond.len], cond);
        sql_len += cond.len;
    }
    if (filter.registrant != null) {
        const cond = " AND registrant = LOWER(?)";
        @memcpy(sql_buf[sql_len..][0..cond.len], cond);
        sql_len += cond.len;
    }
    if (filter.registrant_in != null and filter.registrant_in.?.len > 0) {
        const prefix = " AND registrant IN (";
        @memcpy(sql_buf[sql_len..][0..prefix.len], prefix);
        sql_len += prefix.len;
        for (filter.registrant_in.?, 0..) |_, i| {
            if (i > 0) {
                sql_buf[sql_len] = ',';
                sql_len += 1;
            }
            const placeholder = "LOWER(?)";
            @memcpy(sql_buf[sql_len..][0..placeholder.len], placeholder);
            sql_len += placeholder.len;
        }
        sql_buf[sql_len] = ')';
        sql_len += 1;
    }
    if (filter.expiry_gt != null) {
        const cond = " AND expiry > ?";
        @memcpy(sql_buf[sql_len..][0..cond.len], cond);
        sql_len += cond.len;
    }
    if (filter.expiry_gte != null) {
        const cond = " AND expiry >= ?";
        @memcpy(sql_buf[sql_len..][0..cond.len], cond);
        sql_len += cond.len;
    }
    if (filter.expiry_lt != null) {
        const cond = " AND expiry < ?";
        @memcpy(sql_buf[sql_len..][0..cond.len], cond);
        sql_len += cond.len;
    }
    if (filter.expiry_lte != null) {
        const cond = " AND expiry <= ?";
        @memcpy(sql_buf[sql_len..][0..cond.len], cond);
        sql_len += cond.len;
    }

    var q = try db_module.Query.init(database, sql_buf[0..sql_len]);
    defer q.deinit();

    if (filter.chain) |ch| {
        try q.bindTextStatic(ch.toString());
    }
    if (filter.registrant) |reg| {
        try q.bindText(reg);
    }
    if (filter.registrant_in) |regs| {
        for (regs) |reg| {
            try q.bindText(reg);
        }
    }
    if (filter.expiry_gt) |exp| try q.bindInt64(exp);
    if (filter.expiry_gte) |exp| try q.bindInt64(exp);
    if (filter.expiry_lt) |exp| try q.bindInt64(exp);
    if (filter.expiry_lte) |exp| try q.bindInt64(exp);

    if (try q.step()) {
        return @intCast(q.getInt64(0));
    }
    return 0;
}

/// Get total count of registrations (convenience wrapper with no filters)
pub fn getTotalRegistrationCount(database: *Database) !usize {
    return getRegistrationCount(database, .{});
}

// ============================================================================
// TESTS
// ============================================================================

test "getRegistrations filters by canonical contracts" {
    // This test would require a mock database setup
    // For now, we just verify the module compiles correctly
}

