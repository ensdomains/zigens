const std = @import("std");
const models = @import("../../types/models.zig");
const abi = @import("../abi.zig");
const rpc = @import("../../rpc/client.zig");
const Indexer = @import("../indexer.zig").Indexer;

/// Handle NameEjectedToL1 event
/// NameEjectedToL1(bytes dnsEncodedName, uint256 tokenId)
pub fn handleNameEjectedToL1(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    // topics[0] = event signature
    // No indexed parameters, all in data
    if (log.data.len < 64) return error.InsufficientData;

    // Decode dns_encoded_name (dynamic bytes)
    const dns_encoded_name = try abi.ABI.decodeBytes(self.allocator, log.data, 0);
    defer self.allocator.free(dns_encoded_name);

    // Decode token_id
    const token_id = try abi.ABI.decodeUint256(log.data, 32);

    std.log.debug("NameEjectedToL1: tokenId={d} dnsName={any}", .{ token_id, dns_encoded_name });

    // Store in database
    try self.database.insertMigration(
        chain,
        token_id,
        .to_l1,
        dns_encoded_name,
        log.block_number,
        log.transaction_hash,
        log.log_index,
    );
}

/// Handle NameEjectedToL2 event
/// NameEjectedToL2(bytes dnsEncodedName, uint256 tokenId)
pub fn handleNameEjectedToL2(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    // topics[0] = event signature
    // No indexed parameters, all in data
    if (log.data.len < 64) return error.InsufficientData;

    // Decode dns_encoded_name (dynamic bytes)
    const dns_encoded_name = try abi.ABI.decodeBytes(self.allocator, log.data, 0);
    defer self.allocator.free(dns_encoded_name);

    // Decode token_id
    const token_id = try abi.ABI.decodeUint256(log.data, 32);

    std.log.debug("NameEjectedToL2: tokenId={d} dnsName={any}", .{ token_id, dns_encoded_name });

    // Store in database
    try self.database.insertMigration(
        chain,
        token_id,
        .to_l2,
        dns_encoded_name,
        log.block_number,
        log.transaction_hash,
        log.log_index,
    );
}

/// Handle RenewalSynchronized event
/// RenewalSynchronized(uint256 tokenId, uint64 newExpiry)
pub fn handleRenewalSynchronized(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    // topics[0] = event signature
    // No indexed parameters, all in data
    if (log.data.len < 64) return error.InsufficientData;

    // Decode token_id
    const token_id = try abi.ABI.decodeUint256(log.data, 0);

    // Decode new_expiry (uint64, but padded to 32 bytes)
    const new_expiry_u256 = try abi.ABI.decodeUint256(log.data, 32);
    const new_expiry: u64 = @intCast(new_expiry_u256);

    std.log.debug("RenewalSynchronized: tokenId={d} newExpiry={d}", .{ token_id, new_expiry });

    // Store in database
    try self.database.insertRenewalSync(
        chain,
        token_id,
        new_expiry,
        log.block_number,
        log.transaction_hash,
        log.log_index,
    );
}

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
