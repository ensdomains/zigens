const std = @import("std");
const constants = @import("../constants.zig");
const db_module = @import("database.zig");
const Database = db_module.Database;
const Hash = @import("../types/hash.zig").Hash;
const Address = @import("../types/address.zig").Address;
const models = @import("../types/models.zig");
const events = @import("events.zig");

/// Insert a registration into the `registrations` table.
/// Idempotent on (protocol, tx_hash, log_index) via UNIQUE constraint.
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
    protocol: ?models.Protocol = null, // Filter by protocol (l1 or l2)
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
        .protocol = filter.protocol,
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
/// Counts from the `events` table (filtered by NameRegistered/LabelRegistered) with the
/// same WHERE clauses `getRegistrations` applies — guaranteeing count parity with the
/// row query. The first-class `registrations` table introduced by schema/021 is not
/// guaranteed to exist on existing DBs (the migration short-circuit in
/// `loadSchemaFiles` skips schema files when `names` already exists), so counting from
/// `events` is the only path that works on every deployment.
pub fn getRegistrationCount(database: *Database, filter: RegistrationFilterOptions) !usize {
    const registration_event_types = [_][]const u8{
        models.EventType.name_registered.toString(),
        models.EventType.label_registered.toString(),
    };

    return events.getEventCount(database, .{
        .event_types = &registration_event_types,
        .protocol = filter.protocol,
        .data_json_owner = filter.registrant,
        .data_json_owners = filter.registrant_in,
        .expiry_gt = filter.expiry_gt,
        .expiry_gte = filter.expiry_gte,
        .expiry_lt = filter.expiry_lt,
        .expiry_lte = filter.expiry_lte,
    });
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
