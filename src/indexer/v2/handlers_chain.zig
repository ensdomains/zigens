const std = @import("std");
const models = @import("../../types/models.zig");
// ABI decoding migrated to eth.zig-backed shim. Old `../abi.zig` kept for fallback.
const abi = @import("../abi_eth.zig");
const rpc = @import("../../rpc/client.zig");
const Indexer = @import("../indexer.zig").Indexer;

/// Handle TokenObserverSet event
/// TokenObserverSet(uint256 indexed tokenId, address observer)
pub fn handleTokenObserverSet(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed tokenId
    if (log.topics.len < 2) return error.InvalidTopicCount;
    if (log.data.len < 32) return error.InsufficientData;

    const token_id = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);

    // Non-indexed payload: (address observer)
    const data_values = try abi.decodeValues(log.data, &.{.address}, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const Address = @import("../../types/address.zig").Address;
    const observer = Address{ .bytes = data_values[0].address };

    std.log.debug("TokenObserverSet: tokenId={d} observer={any}", .{ token_id, observer });

    // Store in database
    try self.database.insertTokenObserver(
        protocol,
        token_id,
        observer,
        log.block_number,
        log.transaction_hash,
        log.log_index,
    );
}
