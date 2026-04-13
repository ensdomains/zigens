const std = @import("std");
const models = @import("../../types/models.zig");
const abi = @import("../abi.zig");
const rpc = @import("../../rpc/client.zig");
const Indexer = @import("../indexer.zig").Indexer;

/// Handle TokenObserverSet event
/// TokenObserverSet(uint256 indexed tokenId, address observer)
pub fn handleTokenObserverSet(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed tokenId
    if (log.topics.len < 2) return error.InvalidTopicCount;
    if (log.data.len < 32) return error.InsufficientData;

    const token_id = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);

    // Decode observer address from data
    const observer = try abi.ABI.decodeAddress(log.data, 0);

    std.log.debug("TokenObserverSet: tokenId={d} observer={any}", .{ token_id, observer });

    // Store in database
    try self.database.insertTokenObserver(
        chain,
        token_id,
        observer,
        log.block_number,
        log.transaction_hash,
        log.log_index,
    );
}
