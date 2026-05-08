const std = @import("std");
const models = @import("../../types/models.zig");
// ABI decoding migrated to eth.zig-backed shim. Old `../abi.zig` kept for fallback.
const abi = @import("../abi_eth.zig");
const rpc = @import("../../rpc/client.zig");
const db = @import("../../storage/database.zig");
const Query = db.Query;
const Indexer = @import("../indexer.zig").Indexer;

/// Handle Temporary Registrar HashRegistered event
/// HashRegistered(bytes32 indexed hash, address indexed owner, uint256 value, uint256 registrationDate)
pub fn handleTempHashRegistered(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    _ = protocol;

    // Validate topics
    if (log.topics.len < 3) {
        std.log.warn("Temp HashRegistered event has unexpected topic count: {d}, skipping", .{log.topics.len});
        return;
    }
    if (log.data.len < 64) {
        std.log.warn("Temp HashRegistered event has insufficient data: {d} bytes, skipping", .{log.data.len});
        return;
    }

    // Decode indexed parameters (from topics)
    const label_hash = log.topics[1];
    const owner = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);

    // Non-indexed payload: (uint256 value, uint256 registrationDate)
    const data_values = try abi.decodeValues(
        log.data,
        &.{ .uint256, .uint256 },
        self.allocator,
    );
    defer abi.freeValues(data_values, self.allocator);
    const value = data_values[0].uint256;
    const registration_date = data_values[1].uint256;

    // Convert to hex strings for database
    const label_hash_hex = try label_hash.toHex(self.allocator);
    defer self.allocator.free(label_hash_hex);

    const owner_hex = try owner.toHex(self.allocator);
    defer self.allocator.free(owner_hex);

    const tx_hash_hex = try log.transaction_hash.toHex(self.allocator);
    defer self.allocator.free(tx_hash_hex);

    // Format value as string (wei)
    var value_buf: [100]u8 = undefined;
    const value_str = try std.fmt.bufPrint(&value_buf, "{d}", .{value});

    std.log.debug("Temp HashRegistered: hash={s} owner={s} value={s} registration_date={d}", .{
        label_hash_hex,
        owner_hex,
        value_str,
        registration_date,
    });

    // Insert into temp_auctions table
    var q = try Query.init(self.database,
        \\INSERT OR REPLACE INTO temp_auctions (
        \\  label_hash, status, registration_date, value_eth, winner_address,
        \\  start_block, start_tx, end_block, end_tx
        \\) VALUES (?, 'finalized', ?, ?, ?, ?, ?, ?, ?)
    );
    defer q.deinit();

    try q.bindText(label_hash_hex);
    try q.bindInt64(@intCast(registration_date));
    try q.bindText(value_str);
    try q.bindText(owner_hex);
    try q.bindInt64(@intCast(log.block_number));
    try q.bindText(tx_hash_hex);
    try q.bindInt64(@intCast(log.block_number));
    try q.bindText(tx_hash_hex);
    try q.exec();
}

/// Handle Temporary Registrar AuctionStarted event
/// AuctionStarted(bytes32 indexed hash, uint256 registrationDate)
pub fn handleTempAuctionStarted(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    _ = protocol;

    if (log.topics.len < 2) {
        std.log.warn("Temp AuctionStarted event has unexpected topic count: {d}, skipping", .{log.topics.len});
        return;
    }
    if (log.data.len < 32) {
        std.log.warn("Temp AuctionStarted event has insufficient data: {d} bytes, skipping", .{log.data.len});
        return;
    }

    const label_hash = log.topics[1];
    // Non-indexed payload: (uint256 registrationDate)
    const data_values = try abi.decodeValues(log.data, &.{.uint256}, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const registration_date = data_values[0].uint256;

    const label_hash_hex = try label_hash.toHex(self.allocator);
    defer self.allocator.free(label_hash_hex);

    const tx_hash_hex = try log.transaction_hash.toHex(self.allocator);
    defer self.allocator.free(tx_hash_hex);

    std.log.debug("Temp AuctionStarted: hash={s} registration_date={d}", .{
        label_hash_hex,
        registration_date,
    });

    var q = try Query.init(self.database,
        \\INSERT OR REPLACE INTO temp_auctions (
        \\  label_hash, status, registration_date, start_block, start_tx
        \\) VALUES (?, 'open', ?, ?, ?)
    );
    defer q.deinit();

    try q.bindText(label_hash_hex);
    try q.bindInt64(@intCast(registration_date));
    try q.bindInt64(@intCast(log.block_number));
    try q.bindText(tx_hash_hex);
    try q.exec();
}

/// Handle Temporary Registrar NewBid event
/// NewBid(bytes32 indexed hash, address indexed bidder, uint256 deposit)
pub fn handleTempNewBid(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    _ = protocol;

    if (log.topics.len < 3) {
        std.log.warn("Temp NewBid event has unexpected topic count: {d}, skipping", .{log.topics.len});
        return;
    }
    if (log.data.len < 32) {
        std.log.warn("Temp NewBid event has insufficient data: {d} bytes, skipping", .{log.data.len});
        return;
    }

    const label_hash = log.topics[1];
    const bidder = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);
    // Non-indexed payload: (uint256 deposit)
    const data_values = try abi.decodeValues(log.data, &.{.uint256}, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const deposit = data_values[0].uint256;

    const label_hash_hex = try label_hash.toHex(self.allocator);
    defer self.allocator.free(label_hash_hex);

    const bidder_hex = try bidder.toHex(self.allocator);
    defer self.allocator.free(bidder_hex);

    const tx_hash_hex = try log.transaction_hash.toHex(self.allocator);
    defer self.allocator.free(tx_hash_hex);

    var deposit_buf: [100]u8 = undefined;
    const deposit_str = try std.fmt.bufPrint(&deposit_buf, "{d}", .{deposit});

    std.log.debug("Temp NewBid: hash={s} bidder={s} deposit={s}", .{
        label_hash_hex,
        bidder_hex,
        deposit_str,
    });

    // Generate sealed bid hash (simplified - in real contract it's keccak256(labelhash, bidder, value, salt))
    // For indexing purposes, we use a placeholder
    const sealed_bid_hash = try std.fmt.allocPrint(self.allocator, "0x{s}{s}", .{ label_hash_hex[2..18], bidder_hex[2..18] });
    defer self.allocator.free(sealed_bid_hash);

    var q = try Query.init(self.database,
        \\INSERT OR IGNORE INTO temp_bids (
        \\  label_hash, bidder_address, sealed_bid_hash, deposit_eth,
        \\  block_number, tx_hash, log_index
        \\) VALUES (?, ?, ?, ?, ?, ?, ?)
    );
    defer q.deinit();

    try q.bindText(label_hash_hex);
    try q.bindText(bidder_hex);
    try q.bindText(sealed_bid_hash);
    try q.bindText(deposit_str);
    try q.bindInt64(@intCast(log.block_number));
    try q.bindText(tx_hash_hex);
    try q.bindInt64(@intCast(log.log_index));
    try q.exec();
}

/// Handle Temporary Registrar BidRevealed event
/// BidRevealed(bytes32 indexed hash, address indexed owner, uint256 value, uint8 status)
pub fn handleTempBidRevealed(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    _ = protocol;

    if (log.topics.len < 3) {
        std.log.warn("Temp BidRevealed event has unexpected topic count: {d}, skipping", .{log.topics.len});
        return;
    }
    if (log.data.len < 64) {
        std.log.warn("Temp BidRevealed event has insufficient data: {d} bytes, skipping", .{log.data.len});
        return;
    }

    const label_hash = log.topics[1];
    const bidder = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);
    // Non-indexed payload: (uint256 value, uint8 status)
    const data_values = try abi.decodeValues(
        log.data,
        &.{ .uint256, .uint8 },
        self.allocator,
    );
    defer abi.freeValues(data_values, self.allocator);
    const value = data_values[0].uint256;
    const status = data_values[1].uint256;

    const label_hash_hex = try label_hash.toHex(self.allocator);
    defer self.allocator.free(label_hash_hex);

    const bidder_hex = try bidder.toHex(self.allocator);
    defer self.allocator.free(bidder_hex);

    const tx_hash_hex = try log.transaction_hash.toHex(self.allocator);
    defer self.allocator.free(tx_hash_hex);

    var value_buf: [100]u8 = undefined;
    const value_str = try std.fmt.bufPrint(&value_buf, "{d}", .{value});

    std.log.debug("Temp BidRevealed: hash={s} bidder={s} value={s} status={d}", .{
        label_hash_hex,
        bidder_hex,
        value_str,
        status,
    });

    var q = try Query.init(self.database,
        \\INSERT OR IGNORE INTO temp_bid_reveals (
        \\  label_hash, bidder_address, revealed_value_eth, status,
        \\  block_number, tx_hash, log_index
        \\) VALUES (?, ?, ?, ?, ?, ?, ?)
    );
    defer q.deinit();

    try q.bindText(label_hash_hex);
    try q.bindText(bidder_hex);
    try q.bindText(value_str);
    try q.bindInt64(@intCast(status));
    try q.bindInt64(@intCast(log.block_number));
    try q.bindText(tx_hash_hex);
    try q.bindInt64(@intCast(log.log_index));
    try q.exec();
}

/// Handle Temporary Registrar HashReleased event
/// HashReleased(bytes32 indexed hash, uint256 value)
pub fn handleTempHashReleased(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    _ = protocol;

    if (log.topics.len < 2) {
        std.log.warn("Temp HashReleased event has unexpected topic count: {d}, skipping", .{log.topics.len});
        return;
    }
    if (log.data.len < 32) {
        std.log.warn("Temp HashReleased event has insufficient data: {d} bytes, skipping", .{log.data.len});
        return;
    }

    const label_hash = log.topics[1];
    // Non-indexed payload: (uint256 value)
    const data_values = try abi.decodeValues(log.data, &.{.uint256}, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const value = data_values[0].uint256;

    const label_hash_hex = try label_hash.toHex(self.allocator);
    defer self.allocator.free(label_hash_hex);

    const tx_hash_hex = try log.transaction_hash.toHex(self.allocator);
    defer self.allocator.free(tx_hash_hex);

    var value_buf: [100]u8 = undefined;
    const value_str = try std.fmt.bufPrint(&value_buf, "{d}", .{value});

    std.log.debug("Temp HashReleased: hash={s} value={s}", .{
        label_hash_hex,
        value_str,
    });

    var q = try Query.init(self.database,
        \\UPDATE temp_auctions SET
        \\  status = 'released',
        \\  end_block = ?,
        \\  end_tx = ?
        \\WHERE label_hash = ?
    );
    defer q.deinit();

    try q.bindInt64(@intCast(log.block_number));
    try q.bindText(tx_hash_hex);
    try q.bindText(label_hash_hex);
    try q.exec();
}

/// Handle Temporary Registrar HashInvalidated event
/// HashInvalidated(bytes32 indexed hash, string indexed name, uint256 value, uint256 registrationDate)
pub fn handleTempHashInvalidated(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    _ = protocol;

    if (log.topics.len < 3) {
        std.log.warn("Temp HashInvalidated event has unexpected topic count: {d}, skipping", .{log.topics.len});
        return;
    }
    if (log.data.len < 64) {
        std.log.warn("Temp HashInvalidated event has insufficient data: {d} bytes, skipping", .{log.data.len});
        return;
    }

    const label_hash = log.topics[1];
    // Note: `name` is declared indexed (string) so its hash sits in topics[2];
    // the actual string is NOT in the canonical non-indexed payload.
    // Non-indexed payload: (uint256 value, uint256 registrationDate)
    const data_values = try abi.decodeValues(
        log.data,
        &.{ .uint256, .uint256 },
        self.allocator,
    );
    defer abi.freeValues(data_values, self.allocator);
    const value = data_values[0].uint256;
    const registration_date = data_values[1].uint256;

    const label_hash_hex = try label_hash.toHex(self.allocator);
    defer self.allocator.free(label_hash_hex);

    const tx_hash_hex = try log.transaction_hash.toHex(self.allocator);
    defer self.allocator.free(tx_hash_hex);

    var value_buf: [100]u8 = undefined;
    const value_str = try std.fmt.bufPrint(&value_buf, "{d}", .{value});

    std.log.debug("Temp HashInvalidated: hash={s} value={s} registration_date={d}", .{
        label_hash_hex,
        value_str,
        registration_date,
    });

    // Defensive: some non-canonical contract variants emit a trailing string
    // past the canonical (uint256, uint256) payload. Stays on the primitive
    // path because it reads bytes outside the declared schema.
    const name = if (log.data.len > 64) blk: {
        break :blk abi.ABI.decodeString(self.allocator, log.data, 64) catch "unknown";
    } else "unknown";
    defer if (log.data.len > 64) self.allocator.free(name);

    var q = try Query.init(self.database,
        \\INSERT OR IGNORE INTO temp_invalidations (
        \\  label_hash, name, registration_date, invalidation_block, invalidation_tx, log_index
        \\) VALUES (?, ?, ?, ?, ?, ?)
    );
    defer q.deinit();

    try q.bindText(label_hash_hex);
    try q.bindText(name);
    try q.bindInt64(@intCast(registration_date));
    try q.bindInt64(@intCast(log.block_number));
    try q.bindText(tx_hash_hex);
    try q.bindInt64(@intCast(log.log_index));
    try q.exec();
}
