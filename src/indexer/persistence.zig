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
const json_utils = @import("../utils/json.zig");
const Indexer = @import("indexer.zig").Indexer;

/// The events table carries expression indexes over json_extract(data, ...), so
/// SQLite (and the PG jsonb cast) evaluates the payload on every INSERT — one
/// invalid payload aborts the whole chunk. Producers interpolate on-chain strings
/// (labels, text-record values) into JSON, so hostile bytes must never reach the
/// table unvalidated: invalid payloads are re-wrapped as valid JSON that preserves
/// the original bytes, with coordinates logged so the producer can be fixed.
pub fn quarantineMalformedData(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const escaped = try json_utils.escapeString(allocator, data);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator, "{{\"malformed\":true,\"raw\":\"{s}\"}}", .{escaped});
}

fn ensureValidEventData(self: *Indexer, event: models.Event) !models.Event {
    if (try std.json.validate(self.allocator, event.data)) return event;
    const quarantined = try quarantineMalformedData(self.allocator, event.data);
    var tx_buf: [66]u8 = undefined;
    std.log.warn("event {s} at block {d} tx {s} log_index {d}: malformed JSON payload quarantined", .{
        @tagName(event.event_type), event.block_number, event.tx_hash.toHexBuf(&tx_buf), event.log_index,
    });
    self.allocator.free(event.data);
    var fixed = event;
    fixed.data = quarantined;
    return fixed;
}

/// Helper function to insert an event and trigger webhooks with proper memory cleanup
/// This ensures that event.name and event.data are ALWAYS freed after use
pub fn insertEventAndNotify(self: *Indexer, raw_event: models.Event) !void {
    const event = try ensureValidEventData(self, raw_event);

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
    const inserted = try self.database.insertEventIfNew(event);

    // Trigger webhook only after initial sync (historical events must not
    // notify) AND only when the row actually landed: the insert is
    // conflict-ignoring, so init-gap heal sweeps and backfill retries revisit
    // already-stored events, and those must never re-notify subscribers.
    if (inserted and self.initial_sync_complete.load(.acquire)) {
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
    if (n.protocol == .v2 and self.bufferingEntities()) {
        // Buffered like every other V2 entity write: the row lands in one
        // multi-row upsert at flush (chain order), or earlier if any storage
        // names accessor runs first (Database.names_barrier). A buffered
        // insert supersedes pending field updates exactly as the upsert did.
        // The prefetch learns the row now, as the direct insert's listener
        // notify would have told it.
        try self.write_buffer.insertName(n);
        self.database.noteNameUpsert(n.protocol, n.registry, n.canonical_id, n.namehash, n.name);
        return;
    }
    // A direct upsert supersedes any owner/resolver update still buffered
    // for this row (burn + re-register within one batch).
    self.write_buffer.discardPendingName(n.namehash);
    try self.database.insertName(n);
}

test "quarantineMalformedData produces valid JSON preserving raw bytes" {
    const allocator = std.testing.allocator;
    const poison = "{\"name\":\"a\"b.eth\",\"owner\":\"0xabc\"}";
    try std.testing.expect(!try std.json.validate(allocator, poison));

    const fixed = try quarantineMalformedData(allocator, poison);
    defer allocator.free(fixed);
    try std.testing.expect(try std.json.validate(allocator, fixed));

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, fixed, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("malformed").?.bool);
    try std.testing.expectEqualStrings(poison, parsed.value.object.get("raw").?.string);
}
