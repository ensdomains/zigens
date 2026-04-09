# Temporary Registrar Implementation Guide

## ✅ Completed (This Session)

1. **Contract Configuration** (`src/contracts.zig`)
   - Added `temporary_registrar` address: `0x6090A6e47849629b7245Dfa1Ca21D94cd15878Ef`
   - Updated deployment block documentation
   - Clarified V1 migration at block 9380410

2. **Event Signature Hashes** (`src/indexer/abi.zig:112-141`)
   - All 6 temporary registrar event hashes added and compiling

3. **Database Schema** (`schema/008_temporary_registrar.sql`)
   - Complete tables: auctions, bids, bid_reveals, invalidations

4. **Environment** (`.env`)
   - START_BLOCK=3327417 (ENS genesis)

## 🔨 Remaining Work

### Phase 1: Add Event Registration (5 minutes)

**File**: `src/indexer/indexer.zig`
**Location**: After line 304 (after `V1_REVERSE_REGISTRAR_EVENTS`)

```zig
// Temporary Registrar events (0x6090A6e47849629b7245Dfa1Ca21D94cd15878Ef)
const TEMP_REGISTRAR_EVENTS = [_]RegistryEventConfig{
    .{ .event_hash = abi.EventSignatures.auction_started_hash, .handler = handleTempAuctionStarted, .name = "AuctionStarted" },
    .{ .event_hash = abi.EventSignatures.new_bid_hash, .handler = handleTempNewBid, .name = "NewBid" },
    .{ .event_hash = abi.EventSignatures.bid_revealed_hash, .handler = handleTempBidRevealed, .name = "BidRevealed" },
    .{ .event_hash = abi.EventSignatures.hash_registered_hash, .handler = handleTempHashRegistered, .name = "HashRegistered" },
    .{ .event_hash = abi.EventSignatures.hash_released_hash, .handler = handleTempHashReleased, .name = "HashReleased" },
    .{ .event_hash = abi.EventSignatures.hash_invalidated_hash, .handler = handleTempHashInvalidated, .name = "HashInvalidated" },
};
```

### Phase 2: Implement Event Handlers (2-3 hours)

**File**: `src/indexer/indexer.zig`
**Location**: After line 3950 (after `handleV1ReverseClaimed` function)

#### Handler 1: HashRegistered (Most Important)

```zig
/// HashRegistered(bytes32 indexed hash, address indexed owner, uint256 value, uint256 registrationDate)
fn handleTempHashRegistered(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
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
    const label_hash = Hash{ .bytes = log.topics[1].bytes };
    const owner = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);

    // Decode non-indexed parameters (from data)
    const value = try abi.ABI.decodeUint256(log.data, 0);
    const registration_date = try abi.ABI.decodeUint256(log.data, 32);

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

    std.log.info("Temp HashRegistered: hash={s} owner={s} value={s} registration_date={d}", .{
        label_hash_hex,
        owner_hex,
        value_str,
        registration_date,
    });

    // Insert into temp_auctions table
    const sql =
        \\INSERT OR REPLACE INTO temp_auctions (
        \\  label_hash, status, registration_date, value_eth, winner_address,
        \\  start_block, start_tx, end_block, end_tx
        \\) VALUES (?, 'finalized', ?, ?, ?, ?, ?, ?, ?)
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    var rc = c.sqlite3_prepare_v2(self.database, sql.ptr, @intCast(sql.len), &stmt, null);
    if (rc != c.SQLITE_OK) {
        std.log.err("Failed to prepare temp_auctions insert: {s}", .{c.sqlite3_errmsg(self.database)});
        return error.DatabaseError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_text(stmt, 1, label_hash_hex.ptr, @intCast(label_hash_hex.len), c.SQLITE_TRANSIENT);
    _ = c.sqlite3_bind_int64(stmt, 2, @intCast(registration_date));
    _ = c.sqlite3_bind_text(stmt, 3, value_str.ptr, @intCast(value_str.len), c.SQLITE_TRANSIENT);
    _ = c.sqlite3_bind_text(stmt, 4, owner_hex.ptr, @intCast(owner_hex.len), c.SQLITE_TRANSIENT);
    _ = c.sqlite3_bind_int64(stmt, 5, @intCast(log.block_number));
    _ = c.sqlite3_bind_text(stmt, 6, tx_hash_hex.ptr, @intCast(tx_hash_hex.len), c.SQLITE_TRANSIENT);
    _ = c.sqlite3_bind_int64(stmt, 7, @intCast(log.block_number));
    _ = c.sqlite3_bind_text(stmt, 8, tx_hash_hex.ptr, @intCast(tx_hash_hex.len), c.SQLITE_TRANSIENT);

    rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_DONE) {
        std.log.err("Failed to insert temp_auctions: {s}", .{c.sqlite3_errmsg(self.database)});
        return error.DatabaseError;
    }
}
```

#### Handler 2-6: Similar Pattern

For the remaining handlers (`handleTempAuctionStarted`, `handleTempNewBid`, `handleTempBidRevealed`, `handleTempHashReleased`, `handleTempHashInvalidated`):

1. Follow the same structure as `handleTempHashRegistered`
2. Decode the appropriate event parameters based on the event signature
3. Insert into the corresponding table:
   - AuctionStarted → `temp_auctions` (status='open')
   - NewBid → `temp_bids`
   - BidRevealed → `temp_bid_reveals`
   - HashReleased → `temp_auctions` (status='released')
   - HashInvalidated → `temp_invalidations`

### Phase 3: Add Routing Logic (30 minutes)

**File**: `src/indexer/indexer.zig`
**Location**: In the `indexV1Events` function (around line 2800-2900)

Find where V1 events are indexed and add conditional logic:

```zig
// Before indexing V1 events, check if we should index temp registrar instead
const V1_MIGRATION_BLOCK = 9380410;

if (from_block < V1_MIGRATION_BLOCK) {
    // Index temporary registrar events for pre-migration blocks
    try self.indexV1EventsChunked(
        chain,
        client,
        from_block,
        @min(to_block, V1_MIGRATION_BLOCK - 1),
        self.config.l1_contracts.temporary_registrar,
        &TEMP_REGISTRAR_EVENTS,
        "Temporary Registrar",
    );
}

// If blocks extend beyond migration, index V1 events
if (to_block >= V1_MIGRATION_BLOCK) {
    const v1_start = @max(from_block, V1_MIGRATION_BLOCK);
    // ... existing V1 indexing logic ...
}
```

### Phase 4: Testing (1 hour)

1. **Build and Run**:
   ```bash
   zig build
   rm -f ./data/*.db*
   ./zig-out/bin/ensv2-indexer-v1 --from-block 3327417 --to-block 3327500
   ```

2. **Verify Schema Loaded**:
   ```bash
   sqlite3 ./data/ens.db "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'temp_%';"
   ```

   Expected output:
   ```
   temp_auctions
   temp_bids
   temp_bid_reveals
   temp_invalidations
   ```

3. **Check for Events**:
   ```bash
   sqlite3 ./data/ens.db "SELECT COUNT(*) FROM temp_auctions;"
   ```

4. **Test V1 Migration Boundary**:
   ```bash
   ./zig-out/bin/ensv2-indexer-v1 --from-block 9380400 --to-block 9380420
   ```
   Should index temp registrar events before 9380410, then switch to V1 events after.

## 📝 Implementation Checklist

- [ ] Add `TEMP_REGISTRAR_EVENTS` array after line 304
- [ ] Implement `handleTempHashRegistered` after line 3950
- [ ] Implement `handleTempAuctionStarted`
- [ ] Implement `handleTempNewBid`
- [ ] Implement `handleTempBidRevealed`
- [ ] Implement `handleTempHashReleased`
- [ ] Implement `handleTempHashInvalidated`
- [ ] Add routing logic in `indexV1Events` function
- [ ] Test schema loads correctly
- [ ] Test pre-migration event indexing (blocks < 9380410)
- [ ] Test migration boundary (blocks around 9380410)
- [ ] Test full indexing from genesis (3327417) to present

## 🔍 Debugging Tips

- Check logs for "Temp [EventName]:" messages
- Query database directly: `sqlite3 ./data/ens.db`
- Use `--to-block` to limit test ranges
- Check schema application: Look for "Applying schema: 008_temporary_registrar.sql" in logs

## 📚 Reference Event Signatures

```solidity
event AuctionStarted(bytes32 indexed hash, uint256 registrationDate);
event NewBid(bytes32 indexed hash, address indexed bidder, uint256 deposit);
event BidRevealed(bytes32 indexed hash, address indexed owner, uint256 value, uint8 status);
event HashRegistered(bytes32 indexed hash, address indexed owner, uint256 value, uint256 registrationDate);
event HashReleased(bytes32 indexed hash, uint256 value);
event HashInvalidated(bytes32 indexed hash, string indexed name, uint256 value, uint256 registrationDate);
```

## ⏱️ Estimated Time

- Phase 1 (Registration): 5 minutes
- Phase 2 (Handlers): 2-3 hours
- Phase 3 (Routing): 30 minutes
- Phase 4 (Testing): 1 hour

**Total: ~4 hours**
