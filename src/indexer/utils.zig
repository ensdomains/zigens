const std = @import("std");
const models = @import("../types/models.zig");
const rpc = @import("../rpc/client.zig");
const Hash = @import("../types/hash.zig").Hash;
const Address = @import("../types/address.zig").Address;
const Indexer = @import("indexer.zig").Indexer;

/// Construct a models.Event from common log fields and emit it via insertEventAndNotify.
/// Eliminates 6 identical field assignments repeated across handler files.
pub fn emitEvent(
    self: *Indexer,
    chain: models.Chain,
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
        .chain = chain,
        .block_number = log.block_number,
        .tx_hash = log.transaction_hash,
        .log_index = log.log_index,
        .contract_address = log.address,
        .name = name,
        .namehash = namehash,
        .data = data,
        .timestamp = self.getBlockTimestamp(chain, log.block_number, log.block_timestamp),
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
