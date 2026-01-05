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

    return addresses.toOwnedSlice(allocator);
}

pub const RegistrationFilterOptions = struct {
    chain: ?models.Chain = null, // Filter by chain (l1 or l2)
    limit: u32 = constants.Pagination.default_limit,
    order_dir: events.OrderDir = .desc,
};

/// Get registration events filtered by canonical registry contracts.
/// This function automatically filters to only include NameRegistered events from
/// canonical registries (base_registrar for V1, l2_eth_registry for V2).
/// This prevents duplicates from non-authoritative contracts like FastTestETHRegistrar.
pub fn getRegistrations(database: *Database, filter: RegistrationFilterOptions) ![]models.Event {
    const allocator = database.allocator;

    // Get canonical registry addresses from contracts.zig
    const canonical_addresses = try getCanonicalRegistryAddresses(allocator);
    defer {
        for (canonical_addresses) |addr| {
            allocator.free(addr);
        }
        allocator.free(canonical_addresses);
    }

    // Build event filter options
    const event_filter = events.EventFilterOptions{
        .event_type = models.EventType.name_registered.toString(),
        .chain = filter.chain,
        .contract_addresses = if (canonical_addresses.len > 0) canonical_addresses else null,
        .limit = filter.limit,
        .order_dir = filter.order_dir,
    };

    return events.getEventsFiltered(database, event_filter);
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
