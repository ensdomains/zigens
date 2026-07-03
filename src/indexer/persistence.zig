//! Persistence chokepoints for the Indexer.
//!
//! The shared event/name insert paths (and the one-shot V2 registry seed), split
//! out of indexer.zig as `pub fn f(self: *Indexer, ...)`. indexer.zig re-exports
//! them as `pub const f = persistence.f;` so `self.f(...)` and `Indexer.f` uses are
//! unchanged. (seedV2Registries was file-private; the alias widens it to pub, which
//! is inert — nothing outside indexer.zig referenced it.)

const std = @import("std");
const models = @import("../types/models.zig");
const Hash = @import("../types/hash.zig").Hash;
const Address = @import("../types/address.zig").Address;
const ens_normalize = @import("../utils/ens_normalize.zig");
const Indexer = @import("indexer.zig").Indexer;

/// Helper function to insert an event and trigger webhooks with proper memory cleanup
/// This ensures that event.name and event.data are ALWAYS freed after use
pub fn insertEventAndNotify(self: *Indexer, event: models.Event) !void {
    // When write buffer is active, buffer the event instead of writing to DB.
    // Buffer takes ownership of the strings — do NOT free them here.
    if (self.write_buffer.active) {
        try self.write_buffer.addEvent(event);
        return;
    }

    // Insert event into database (database makes a copy via SQLITE_TRANSIENT)
    // We must free our allocations whether insert succeeds or fails
    defer {
        if (event.name) |name| self.allocator.free(name);
        self.allocator.free(event.data);
    }

    // Try to insert the event
    try self.database.insertEvent(event);

    // Trigger webhook if enabled (only after initial sync to avoid notifying about historical events)
    if (self.initial_sync_complete.load(.acquire)) {
        if (self.webhook_manager) |wm| {
            wm.notify(event) catch |err| {
                // Webhook failed but event was inserted successfully
                // Just log the error - event was successfully stored
                std.log.warn("Webhook notification failed: {}", .{err});
                // Don't return error - event was successfully stored
            };
        }
    }
}

/// Seed the canonical V2 root + eth registries into the `registries` table.
/// These are deployed pre-indexing and never produce a SubregistryUpdate that
/// would insert them, so `registry(address:)` lookups for the main eth
/// registry return null on a fresh database without this bootstrap.
/// Uses INSERT OR IGNORE under the hood, so repeated calls are no-ops.
pub fn seedV2Registries(self: *Indexer) !void {
    const eth_addr = self.config.v2_contracts.eth_registry;
    const root_addr = self.config.v2_contracts.root_registry;
    if (eth_addr.isZero()) return; // V2 not deployed on this network

    const deploy_block = self.config.v2_contracts.v2_deployment_block;

    if (!root_addr.isZero()) {
        try self.database.insertRegistry(.{
            .address = root_addr,
            .protocol = .v2,
            .name = "",
            .namehash = Hash.zero,
            .parent_registry = Address.zero,
            .created_block = deploy_block,
            .created_at = 0,
        });
    }

    try self.database.insertRegistry(.{
        .address = eth_addr,
        .protocol = .v2,
        .name = "eth",
        .namehash = self.eth_namehash,
        .parent_registry = if (root_addr.isZero()) Address.zero else root_addr,
        .created_block = deploy_block,
        .created_at = 0,
    });
}

pub fn insertName(self: *Indexer, name: models.Name) !void {
    var n = name;
    n.is_normalized = ens_normalize.nameIsNormalized(self.allocator, n.name);
    // Reachability is derived from the registry tree: a V2 name is reachable
    // iff its source registry chains up to a root through the current
    // subregistry edges. Evaluating it at this insert chokepoint (the one
    // shared with is_normalized) covers the phase-ordering case the repoint
    // cascade can't — a name registered into a subregistry whose parent
    // already repointed away. V1 names have no subregistry tree, so they keep
    // the default (reachable). On a transient lookup error, leave the default
    // rather than block the insert.
    if (n.protocol == .v2) {
        const roots = [_]Address{ self.config.v2_contracts.eth_registry, self.config.v2_contracts.root_registry };
        n.is_reachable = self.database.isRegistryReachable(self.allocator, n.protocol, n.registry, &roots) catch |err| blk: {
            std.log.warn("isRegistryReachable failed for {any}: {} (assuming reachable)", .{ n.registry, err });
            break :blk n.is_reachable;
        };
    }
    try self.database.insertName(n);
}
