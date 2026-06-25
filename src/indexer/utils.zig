const std = @import("std");
const models = @import("../types/models.zig");
const rpc = @import("../rpc/client.zig");
const Hash = @import("../types/hash.zig").Hash;
const Address = @import("../types/address.zig").Address;
const Indexer = @import("indexer.zig").Indexer;

/// Record `addr` in the `accounts` entity table at the block/timestamp of
/// the log that observed it. Skip the zero-address sentinel (burned / cleared,
/// not a real account holder). Failure is logged at debug — never aborts
/// event processing.
///
/// Centralises the 15 identical 5-line blocks that previously sat in every
/// V1+V2 handler that observed an address. Use this from any handler that
/// touches a new owner / registrant / role-grantee / transfer-recipient /
/// operator.
pub fn recordAccountObservation(self: *Indexer, protocol: models.Protocol, addr: Address, log: rpc.Log) void {
    if (addr.isZero()) return;
    var addr_buf: [42]u8 = undefined;
    const addr_hex = addr.toHexBuf(&addr_buf);
    // Dedup per (protocol, address) this run: after first sight the upsert is a no-op
    // (first_seen is a MIN, seen_v1/seen_v2 are MAX, and processing is forward). This
    // also skips the getBlockTimestamp call (which can cost an RPC). See account_obs_cache.
    var key_buf: [48]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ protocol.toString(), addr_hex }) catch addr_hex;
    if (self.account_obs_cache.contains(key)) return;
    self.database.upsertAccount(
        protocol,
        addr_hex,
        log.block_number,
        self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
    ) catch |err| {
        std.log.debug("upsertAccount failed: {}", .{err});
        return; // don't cache on failure — retry on the next observation
    };
    const key_copy = self.allocator.dupe(u8, key) catch return;
    self.account_obs_cache.put(key_copy, {}) catch self.allocator.free(key_copy);
}

/// Construct a models.Event from common log fields and emit it via insertEventAndNotify.
/// Eliminates 6 identical field assignments repeated across handler files.
pub fn emitEvent(
    self: *Indexer,
    protocol: models.Protocol,
    log: rpc.Log,
    event_type: models.EventType,
    name: ?[]const u8,
    namehash: ?Hash,
    data: []const u8,
) !void {
    // Track block hash from log for reorg detection (avoids extra RPC call)
    self.trackBlockHash(log.block_number, log.block_hash);

    const event = models.Event{
        .event_type = event_type,
        .protocol = protocol,
        .block_number = log.block_number,
        .tx_hash = log.transaction_hash,
        .log_index = log.log_index,
        .contract_address = log.address,
        .name = name,
        .namehash = namehash,
        .data = data,
        .timestamp = self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
    };
    try Indexer.insertEventAndNotify(self, event);
}

/// Resolve a zero namehash by looking up the actual namehash from the resolver address.
/// In ENSv2, each name has its own dedicated resolver, so events may emit a zeroed namehash.
/// Returns true if the namehash is valid (non-zero or resolved), false if it should be skipped.
pub fn resolveNamehash(self: *Indexer, namehash: *Hash, resolver: Address, event_name: []const u8) !bool {
    if (!namehash.isZero()) return true;
    if (try self.database.getNamehashByResolver(resolver)) |actual| {
        namehash.* = actual;
        return true;
    }
    std.log.debug("{s}: skipping event with zero namehash and unknown resolver", .{event_name});
    return false;
}

/// Convert a u256 token ID to a 0x-prefixed hex string via Hash.
pub fn tokenIdToHex(allocator: std.mem.Allocator, token_id: u256) ![]u8 {
    var bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &bytes, token_id, .big);
    return try (Hash{ .bytes = bytes }).toHex(allocator);
}

/// Deinitialize a batch of log results from getLogsBatch.
/// Frees each log, each inner slice, and the outer slice.
pub fn deinitBatchResults(allocator: std.mem.Allocator, batch_results: [][]rpc.Log) void {
    for (batch_results) |logs| {
        for (logs) |*log| {
            log.deinit(allocator);
        }
        allocator.free(logs);
    }
    allocator.free(batch_results);
}

/// Handler + log pair for ordered dispatch.
/// The `log` aliases slices owned by the source batch result — keep the original
/// result array alive until dispatch finishes.
pub const DispatchEntry = struct {
    handler: *const fn (*Indexer, models.Protocol, rpc.Log) anyerror!void,
    log: rpc.Log,
};

fn dispatchEntryLessThan(_: void, a: DispatchEntry, b: DispatchEntry) bool {
    if (a.log.block_number != b.log.block_number) return a.log.block_number < b.log.block_number;
    return a.log.log_index < b.log.log_index;
}

/// Sort entries by (block_number, log_index) and dispatch each to its handler.
/// Preserves on-protocol event order across different event types within a batch.
pub fn dispatchOrdered(
    self: *Indexer,
    protocol: models.Protocol,
    entries: []DispatchEntry,
) !void {
    std.mem.sort(DispatchEntry, entries, {}, dispatchEntryLessThan);
    for (entries) |entry| {
        self.markEventBlock(protocol, entry.log.block_number);
        try entry.handler(self, protocol, entry.log);
    }
}
