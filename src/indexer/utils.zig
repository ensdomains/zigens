const std = @import("std");
const models = @import("../types/models.zig");
const rpc = @import("../rpc/client.zig");
const Hash = @import("../types/hash.zig").Hash;
const Address = @import("../types/address.zig").Address;
const Indexer = @import("indexer.zig").Indexer;
const name_prefetch_mod = @import("../storage/name_prefetch.zig");

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
    const ts = self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp) catch |err| {
        std.log.debug("observeAccount timestamp fetch failed: {}", .{err});
        return; // best-effort — retried on the next observation of this address
    };
    if (self.bufferingEntities()) {
        self.write_buffer.observeAccount(protocol, addr_hex, log.block_number, ts) catch |err| {
            std.log.debug("buffering account observation failed: {}", .{err});
            return;
        };
    } else {
        self.database.upsertAccount(protocol, addr_hex, log.block_number, ts) catch |err| {
            std.log.debug("upsertAccount failed: {}", .{err});
            return; // don't cache on failure — retry on the next observation
        };
    }
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
        .timestamp = try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
    };
    if (name) |n| self.placeholders.noteName(n) catch {};
    try Indexer.insertEventAndNotify(self, event);
}

/// Resolve a zero namehash by looking up the actual namehash from the resolver address.
/// In ENSv2, each name has its own dedicated resolver, so events may emit a zeroed namehash.
/// Returns true if the namehash is valid (non-zero or resolved), false if it should be skipped.
pub fn resolveNamehash(self: *Indexer, protocol: models.Protocol, namehash: *Hash, resolver: Address, event_name: []const u8) !bool {
    if (!namehash.isZero()) return true;
    // Null covers two cases and both must skip: the resolver is unknown, or it is SHARED by
    // several names so the attribution is unanswerable. Skipping loses one event's record;
    // guessing wrote it to a name chosen arbitrarily out of as many as 159k.
    if (try self.database.getNamehashByResolver(protocol, resolver)) |actual| {
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

/// Malformed-payload errors from decoding a hostile or legacy event shape (old
/// contract variants share topic names with different ABIs). One undecodable
/// event must be skipped with its coordinates logged, never allowed to abort
/// the batch — a deterministic poison log would pin the sync cursor forever.
/// Database and I/O errors still propagate: skipping those would drop valid data.
pub fn isMalformedEventError(err: anyerror) bool {
    return switch (err) {
        error.DataTooShort, error.ArrayDataTooShort, error.InvalidTopicCount => true,
        // Decoded fine but a numeric field exceeds what the schema can hold
        // (e.g. a hostile uint256 coinType) — same skip-with-coordinates
        // treatment as an undecodable payload.
        error.ValueOutOfRange => true,
        else => false,
    };
}

pub fn skipMalformedEvent(log: rpc.Log, err: anyerror) void {
    var tx_buf: [66]u8 = undefined;
    std.log.warn("skipping undecodable event at block {d} tx {s} log_index {d}: {}", .{ log.block_number, log.transaction_hash.toHexBuf(&tx_buf), log.log_index, err });
}

/// Sort entries by (block_number, log_index) and dispatch each to its handler.
/// Preserves on-protocol event order across different event types within a batch.
pub fn dispatchOrdered(
    self: *Indexer,
    protocol: models.Protocol,
    entries: []DispatchEntry,
) !void {
    std.mem.sort(DispatchEntry, entries, {}, dispatchEntryLessThan);

    // Dispatch-scoped names prefetch: one IN-list load replaces the
    // ResolverUpdated storm's per-event point lookups (~86% of V2 bulk-sync
    // events on real ranges). The write listener keeps it exact — see
    // storage/name_prefetch.zig for the correctness model. Guarded against
    // nesting: an inner dispatch must never displace an outer map.
    var prefetch: ?name_prefetch_mod.NamePrefetch = null;
    defer if (prefetch) |*p| p.deinit();
    if (self.config.name_prefetch and self.name_prefetch == null) {
        buildNamePrefetch(self, entries, &prefetch);
    }
    if (prefetch != null) {
        self.name_prefetch = &prefetch.?;
        self.database.name_write_listener = prefetch.?.listener();
    }
    defer if (prefetch) |*p| {
        self.name_prefetch = null;
        self.database.name_write_listener = null;
        p.logStats();
    };

    for (entries) |entry| {
        self.markEventBlock(protocol, entry.log.block_number);
        entry.handler(self, protocol, entry.log) catch |err| {
            if (!isMalformedEventError(err)) return err;
            skipMalformedEvent(entry.log, err);
        };
    }
}

/// Collect the token id of every entry — topics[1] for the registry and
/// registrar events, the data-encoded id for TransferSingle — and load their
/// names rows, so every handler's (token id, registry) lookup and every
/// same-dispatch write-through has an entry to land in. Non-token topics
/// only add empty entries. Best-effort: any failure (or an undecodable
/// topic) just leaves the map unbuilt/incomplete and lookups fall back to
/// the DB — the prefetch is never allowed to abort dispatch.
fn buildNamePrefetch(self: *Indexer, entries: []const DispatchEntry, out: *?name_prefetch_mod.NamePrefetch) void {
    var tokens: std.ArrayList(u256) = .empty;
    defer tokens.deinit(self.allocator);
    for (entries) |entry| {
        if (entry.handler == @as(@TypeOf(entry.handler), Indexer.handleTransfer)) {
            if (entry.log.data.len < 32) continue;
            tokens.append(self.allocator, std.mem.readInt(u256, entry.log.data[0..32], .big)) catch return;
            continue;
        }
        if (entry.log.topics.len < 2) continue;
        const tok = std.mem.readInt(u256, &entry.log.topics[1].bytes, .big);
        tokens.append(self.allocator, tok) catch return;
    }
    if (tokens.items.len == 0) return;

    // Construct in place before populate: rows live in the embedded arena and
    // a populated NamePrefetch must never move.
    out.* = name_prefetch_mod.NamePrefetch.init(self.allocator);
    out.*.?.populate(self.database, tokens.items) catch |err| {
        std.log.warn("name prefetch failed (falling back to per-event lookups): {}", .{err});
        out.*.?.deinit();
        out.* = null;
    };
}
