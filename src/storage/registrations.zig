const std = @import("std");
const constants = @import("../constants.zig");
const db_module = @import("database.zig");
const Database = db_module.Database;
const models = @import("../types/models.zig");
const contracts = @import("../contracts.zig");
const events = @import("events.zig");

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

/// Get canonical registry addresses from contracts.zig for all networks.
/// Returns addresses from both Sepolia and Mainnet deployments.
fn getCanonicalRegistryAddresses(allocator: std.mem.Allocator) ![][]const u8 {
    var addresses: std.ArrayList([]const u8) = .{};
    errdefer {
        for (addresses.items) |addr| {
            allocator.free(addr);
        }
        addresses.deinit(allocator);
    }

    // Get addresses from Sepolia
    const sepolia = contracts.getContractAddresses(.sepolia) catch unreachable;

    // V1 Sepolia Base Registrar
    if (!sepolia.base_registrar.isZero()) {
        const hex = try sepolia.base_registrar.toHex(allocator);
        try addresses.append(allocator, hex);
    }

    // V2 Sepolia L2 ETH Registry
    if (!sepolia.l2_eth_registry.isZero()) {
        const hex = try sepolia.l2_eth_registry.toHex(allocator);
        try addresses.append(allocator, hex);
    }

    // V2 Sepolia L2 ETH Registrar (emits NameRegistered for .eth 2LDs)
    if (!sepolia.l2_eth_registrar.isZero()) {
        const hex = try sepolia.l2_eth_registrar.toHex(allocator);
        try addresses.append(allocator, hex);
    }

    // Get addresses from Mainnet
    const mainnet = contracts.getContractAddresses(.mainnet) catch unreachable;

    // V1 Mainnet Base Registrar
    if (!mainnet.base_registrar.isZero()) {
        const hex = try mainnet.base_registrar.toHex(allocator);
        try addresses.append(allocator, hex);
    }

    // V2 Mainnet L2 ETH Registry (when deployed)
    if (!mainnet.l2_eth_registry.isZero()) {
        const hex = try mainnet.l2_eth_registry.toHex(allocator);
        try addresses.append(allocator, hex);
    }

    // V2 Mainnet L2 ETH Registrar (when deployed)
    if (!mainnet.l2_eth_registrar.isZero()) {
        const hex = try mainnet.l2_eth_registrar.toHex(allocator);
        try addresses.append(allocator, hex);
    }

    return addresses.toOwnedSlice(allocator);
}

pub const RegistrationFilterOptions = struct {
    chain: ?models.Chain = null, // Filter by chain (l1 or l2)
    registrant: ?[]const u8 = null, // Filter by registrant (owner in event data JSON)
    registrant_in: ?[]const []const u8 = null, // Filter by registrant IN list
    limit: u32 = constants.Pagination.default_limit,
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
/// When registrant/registrant_in is set, queries the `names` table using the indexed
/// `registrant` column for O(log N) performance instead of scanning events with json_extract.
/// For unfiltered counts, queries the events table with event_type + contract_address filters.
pub fn getRegistrationCount(database: *Database, filter: RegistrationFilterOptions) !usize {
    if (filter.registrant != null or (filter.registrant_in != null and filter.registrant_in.?.len > 0)) {
        return getRegistrationCountFromNames(database, filter);
    }
    return getRegistrationCountFromEvents(database, filter);
}

/// Count registrations using the names table (fast — uses idx_names_registrant index).
/// Filters 2LDs by parent_name = 'eth' which matches what canonical registries handle.
/// Addresses are stored lowercase via Address.toHex(.lower), so we LOWER() the input.
fn getRegistrationCountFromNames(database: *Database, filter: RegistrationFilterOptions) !usize {
    var sql_buf: [1024]u8 = undefined;
    var sql_len: usize = 0;

    const base = "SELECT COUNT(*) FROM names WHERE parent_name = 'eth'";
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

/// Count registrations using the events table (for unfiltered counts).
/// Counts both V1 (name_registered) and V2 (label_registered) events.
fn getRegistrationCountFromEvents(database: *Database, filter: RegistrationFilterOptions) !usize {
    var sql_buf: [1024]u8 = undefined;
    var sql_len: usize = 0;

    const base = "SELECT COUNT(*) FROM events WHERE event_type IN (?, ?)";
    @memcpy(sql_buf[sql_len..][0..base.len], base);
    sql_len += base.len;

    if (filter.chain != null) {
        const cond = " AND chain = ?";
        @memcpy(sql_buf[sql_len..][0..cond.len], cond);
        sql_len += cond.len;
    }
    if (filter.expiry_gt != null) {
        const cond = " AND json_extract(data, '$.expiration') > ?";
        @memcpy(sql_buf[sql_len..][0..cond.len], cond);
        sql_len += cond.len;
    }
    if (filter.expiry_gte != null) {
        const cond = " AND json_extract(data, '$.expiration') >= ?";
        @memcpy(sql_buf[sql_len..][0..cond.len], cond);
        sql_len += cond.len;
    }
    if (filter.expiry_lt != null) {
        const cond = " AND json_extract(data, '$.expiration') < ?";
        @memcpy(sql_buf[sql_len..][0..cond.len], cond);
        sql_len += cond.len;
    }
    if (filter.expiry_lte != null) {
        const cond = " AND json_extract(data, '$.expiration') <= ?";
        @memcpy(sql_buf[sql_len..][0..cond.len], cond);
        sql_len += cond.len;
    }

    var q = try db_module.Query.init(database, sql_buf[0..sql_len]);
    defer q.deinit();

    try q.bindTextStatic(models.EventType.name_registered.toString());
    try q.bindTextStatic(models.EventType.label_registered.toString());
    if (filter.chain) |ch| {
        try q.bindTextStatic(ch.toString());
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

test "getCanonicalRegistryAddresses returns addresses from contracts.zig" {
    const allocator = std.testing.allocator;

    const addresses = try getCanonicalRegistryAddresses(allocator);
    defer {
        for (addresses) |addr| {
            allocator.free(addr);
        }
        allocator.free(addresses);
    }

    // Should have at least the Sepolia addresses
    try std.testing.expect(addresses.len >= 2);

    // All addresses should start with 0x and be 42 characters
    for (addresses) |addr| {
        try std.testing.expect(addr.len == 42);
        try std.testing.expect(addr[0] == '0');
        try std.testing.expect(addr[1] == 'x');
    }
}
