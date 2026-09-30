//! Record-model resolver handlers (contracts-v2 `IRecordResolver`).
//!
//! The new `PermissionedResolver` keys values by `recordId`, not node:
//!   - `Linked(recordId, node, name)` binds a name's node to a record
//!     (`recordId = 0` unbinds; node `0x0` is the resolver-wide default),
//!   - `<Kind>Updated(recordId, …)` writes a value on the record,
//!   - `ResolverCreated()` marks the resolver as record-model,
//!   - `ResourceArgument(resource, arg)` names an EAC resource by its setter
//!     argument (replaces the per-name `Named*Resource` events).
//!
//! Record values are stored under the record's synthetic key in the ordinary
//! `resolver_*` tables (see storage/resolver_records.zig); reads resolve a
//! node to its record key exactly like the contract's `_record(node)`.
//! `DataChanged` (legacy node-keyed `data(key)` records) is handled here too.

const std = @import("std");
const models = @import("../../types/models.zig");
const abi = @import("../abi_eth.zig");
const rpc = @import("../../rpc/client.zig");
const Hash = @import("../../types/hash.zig").Hash;
const Address = @import("../../types/address.zig").Address;
const Indexer = @import("../indexer.zig").Indexer;
const utils = @import("../utils.zig");
const unicode = @import("../../utils/unicode.zig");
const json_utils = @import("../../utils/json.zig");
const dns = @import("../../utils/dns.zig");
const record_model = @import("../../storage/resolver_records.zig");
const keccak = @import("../../utils/keccak.zig");

/// keccak256 of the empty byte string — what an `indexed bytes` topic carries
/// when the value is empty. It is the one hashed value whose preimage IS known,
/// and it means the record was cleared.
const KECCAK_EMPTY = Hash{ .bytes = keccak.keccak256("") };

/// What a single log lets us assert about a record's value.
///
/// `indexed` is not part of an event signature hash, so two contracts can emit
/// the same topic0 while disagreeing on which parameters reach `data`. For
/// DataChanged both shapes occur in the wild, and this is exactly what they
/// differ in: whether the value arrives verbatim or only as its keccak256.
const RecordValue = union(enum) {
    /// The value arrived verbatim in the payload. Empty means "cleared".
    plain: []const u8,
    /// The emitter declared `value` as `indexed`, so the log carries only
    /// keccak256(value). No preimage is derivable from the log, so the record's
    /// value cannot be asserted — see storeDataRecord for what is written.
    hashed: Hash,
};

const RecordRef = struct {
    id: u256,
    key: Hash,
};

/// Record id from an indexed `uint256 recordId` topic, carried at full width:
/// PermissionedResolver allocates small sequential ids, SharedResolver uses
/// the name's 256-bit node itself.
fn recordFromTopic(log: rpc.Log) ?RecordRef {
    if (log.topics.len < 2) return null;
    const id: u256 = std.mem.readInt(u256, &log.topics[1].bytes, .big);
    return .{ .id = id, .key = record_model.recordKey(id) };
}

fn bytesToHexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const hex = try allocator.alloc(u8, 2 + bytes.len * 2);
    hex[0] = '0';
    hex[1] = 'x';
    for (bytes, 0..) |byte, i| {
        _ = try std.fmt.bufPrint(hex[2 + i * 2 .. 4 + i * 2], "{x:0>2}", .{byte});
    }
    return hex;
}

fn stripNulls(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, input.len);
    errdefer allocator.free(out);
    var n: usize = 0;
    for (input) |c| {
        if (c != 0) {
            out[n] = c;
            n += 1;
        }
    }
    return allocator.realloc(out, n);
}

/// A key/value string pair cleaned the way `TextChanged` cleans it: NULs
/// stripped, key must validate (else the event is skipped), a value that does
/// not validate clears the key.
const CleanText = struct {
    key: []u8,
    value: []u8,
    value_ok: bool,

    fn deinit(self: CleanText, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
    }
};

fn cleanText(self: *Indexer, log: rpc.Log, event_name: []const u8, key: []const u8, value: []const u8) !?CleanText {
    const clean_key = try stripNulls(self.allocator, key);
    errdefer self.allocator.free(clean_key);
    const clean_value = try stripNulls(self.allocator, value);
    errdefer self.allocator.free(clean_value);
    unicode.validateString(clean_key) catch |err| {
        var tx_buf: [66]u8 = undefined;
        std.log.warn("{s} key rejected ({any}) at block {d} tx {s} log_index {d} — event skipped", .{ event_name, err, log.block_number, log.transaction_hash.toHexBuf(&tx_buf), log.log_index });
        self.allocator.free(clean_key);
        self.allocator.free(clean_value);
        return null;
    };
    const value_ok = blk: {
        unicode.validateString(clean_value) catch |err| {
            var tx_buf: [66]u8 = undefined;
            std.log.warn("{s} value rejected ({any}) at block {d} tx {s} log_index {d} — clearing key", .{ event_name, err, log.block_number, log.transaction_hash.toHexBuf(&tx_buf), log.log_index });
            break :blk false;
        };
        break :blk true;
    };
    return CleanText{ .key = clean_key, .value = clean_value, .value_ok = value_ok };
}

/// ResolverCreated()
pub fn handleResolverCreated(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    const ts = try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp);
    self.database.upsertResolverKind(protocol, resolver, record_model.ResolverKind.record, log.block_number, log.transaction_hash, log.log_index, ts) catch |err| {
        std.log.warn("Failed to store resolver kind: {}", .{err});
    };
    const resolver_hex = try resolver.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);
    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"resolver\":\"{s}\"}}", .{resolver_hex});
    try utils.emitEvent(self, protocol, log, .resolver_created, null, null, event_data);
}

/// Linked(uint256 indexed recordId, bytes32 indexed node, bytes name)
/// `recordId = 0` unbinds the node; node `0x0` (root name) is the default record.
pub fn handleLinked(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    if (log.topics.len < 3) return error.InvalidTopicCount;
    const rec = recordFromTopic(log) orelse return;
    const node = log.topics[2];

    const data_values = try abi.decodeValues(log.data, &.{.bytes}, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const decoded = try dns.decodeDNSNameToString(self.allocator, data_values[0].bytes);
    defer if (decoded) |d| self.allocator.free(d);
    // The root name (`0x00`) decodes to null: that is the default-record binding.
    const name: []const u8 = decoded orelse "";
    const ts = try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp);

    try self.database.upsertResolverLink(
        protocol,
        resolver,
        node,
        rec.id,
        name,
        log.block_number,
        log.transaction_hash,
        log.log_index,
        ts,
    );

    // Any resolver that emits Linked is an IRecordResolver, whether or not it
    // announced itself with ResolverCreated (SharedResolver does not).
    if (try self.database.getResolverKind(resolver)) |existing| {
        self.database.allocator.free(existing);
    } else {
        self.database.upsertResolverKind(protocol, resolver, record_model.ResolverKind.record, log.block_number, log.transaction_hash, log.log_index, ts) catch |err| {
            std.log.warn("Failed to store resolver kind: {}", .{err});
        };
    }

    const resolver_hex = try resolver.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);
    const node_hex = try node.toHex(self.allocator);
    defer self.allocator.free(node_hex);
    const escaped_name = try json_utils.escapeString(self.allocator, name);
    defer self.allocator.free(escaped_name);
    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"resolver\":\"{s}\",\"recordId\":\"{d}\",\"node\":\"{s}\",\"name\":\"{s}\"}}", .{ resolver_hex, rec.id, node_hex, escaped_name });
    const domain_name = self.getNameFromNamehash(node);
    try utils.emitEvent(self, protocol, log, .linked, domain_name, node, event_data);
}

/// Cleared(uint256 indexed recordId) — declared by IRecordResolver, emitted by
/// SharedResolver.clear(): every value of the record is dropped.
pub fn handleCleared(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    const rec = recordFromTopic(log) orelse return;
    const db = self.database;
    db.deleteResolverAddresses(protocol, rec.key, resolver) catch |err| std.log.warn("Cleared: addresses: {}", .{err});
    db.deleteResolverTexts(protocol, rec.key, resolver) catch |err| std.log.warn("Cleared: texts: {}", .{err});
    db.deleteResolverContentHash(protocol, rec.key, resolver) catch |err| std.log.warn("Cleared: contenthash: {}", .{err});
    db.deleteResolverAbis(protocol, rec.key, resolver) catch |err| std.log.warn("Cleared: abis: {}", .{err});
    db.deleteResolverNames(protocol, rec.key, resolver) catch |err| std.log.warn("Cleared: names: {}", .{err});
    db.deleteResolverInterfaces(protocol, rec.key, resolver) catch |err| std.log.warn("Cleared: interfaces: {}", .{err});
    db.deleteResolverDatas(protocol, rec.key, resolver) catch |err| std.log.warn("Cleared: datas: {}", .{err});

    const resolver_hex = try resolver.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);
    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"resolver\":\"{s}\",\"recordId\":\"{d}\"}}", .{ resolver_hex, rec.id });
    try utils.emitEvent(self, protocol, log, .cleared, null, rec.key, event_data);
}

/// AddressUpdated(uint256 indexed recordId, uint256 coinType, bytes addressBytes)
/// Empty `addressBytes` clears the coin type (`hasAddr` becomes false).
pub fn handleAddressUpdated(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    const rec = recordFromTopic(log) orelse return;
    const data_values = try abi.decodeValues(log.data, &.{ .uint256, .bytes }, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const coin_type = data_values[0].uint256;
    const address_bytes = data_values[1].bytes;
    const coin_type_i64 = std.math.cast(i64, coin_type) orelse return error.ValueOutOfRange;

    const address_hex = try bytesToHexAlloc(self.allocator, address_bytes);
    defer self.allocator.free(address_hex);
    const ts = try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp);
    if (address_bytes.len == 0) {
        self.database.deleteResolverAddress(protocol, rec.key, resolver, @intCast(coin_type_i64)) catch |err| {
            std.log.warn("Failed to clear resolver address: {}", .{err});
        };
    } else {
        try self.database.storeResolverAddress(rec.key, resolver, @intCast(coin_type_i64), address_hex, protocol, log.block_number, log.transaction_hash, ts);
    }

    const resolver_hex = try resolver.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);
    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"resolver\":\"{s}\",\"recordId\":\"{d}\",\"coinType\":{d},\"address\":\"{s}\"}}", .{ resolver_hex, rec.id, coin_type, address_hex });
    try utils.emitEvent(self, protocol, log, .address_updated, null, rec.key, event_data);
}

/// TextUpdated(uint256 indexed recordId, string indexed keyHash, string key, string value)
pub fn handleTextUpdated(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    const rec = recordFromTopic(log) orelse return;
    const data_values = try abi.decodeValues(log.data, &.{ .string, .string }, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const clean = (try cleanText(self, log, "TextUpdated", data_values[0].string, data_values[1].string)) orelse return;
    defer clean.deinit(self.allocator);
    const effective_value: []const u8 = if (clean.value_ok) clean.value else "";

    if (effective_value.len == 0) {
        self.database.deleteResolverText(protocol, rec.key, resolver, clean.key) catch |err| {
            std.log.warn("Failed to delete cleared resolver text: {}", .{err});
        };
    } else {
        try self.database.storeResolverText(rec.key, resolver, clean.key, effective_value, protocol, log.block_number, log.transaction_hash, try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp));
    }

    const resolver_hex = try resolver.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);
    const escaped_key = try json_utils.escapeString(self.allocator, clean.key);
    defer self.allocator.free(escaped_key);
    const escaped_value = try json_utils.escapeString(self.allocator, effective_value);
    defer self.allocator.free(escaped_value);
    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"resolver\":\"{s}\",\"recordId\":\"{d}\",\"key\":\"{s}\",\"value\":\"{s}\"}}", .{ resolver_hex, rec.id, escaped_key, escaped_value });
    try utils.emitEvent(self, protocol, log, .text_updated, null, rec.key, event_data);
}

/// DataUpdated(uint256 indexed recordId, string indexed keyHash, string key, bytes value)
pub fn handleDataUpdated(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    const rec = recordFromTopic(log) orelse return;
    const data_values = try abi.decodeValues(log.data, &.{ .string, .bytes }, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    try storeDataRecord(self, protocol, resolver, log, rec.key, data_values[0].string, .{ .plain = data_values[1].bytes }, "DataUpdated", .data_updated, rec.id);
}

/// DataChanged(bytes32 indexed node, string indexed indexedKey, string key, bytes value)
/// Legacy node-keyed `data(key)` record (PublicResolverV2, older PermissionedResolver).
///
/// `indexed` is NOT part of the signature hash, so this one topic0 is emitted by
/// contracts that disagree on how many of those four parameters reach `data`.
/// Both live shapes are handled, dispatched on the observable topic count:
///
///   3 topics — `node` and `indexedKey` indexed: `data` = (string key, bytes value).
///   4 topics — `value` indexed as well: `data` = (string key) alone, and
///              topics[3] = keccak256(value).
///
/// Every log this signature has produced on Sepolia (79 logs, 26 distinct
/// emitters, blocks 9.5M–11.8M) is the 4-topic shape, and all 79 satisfy
/// keccak256(key) == topics[2]. So a `topics.len != 3` guard rejected every one
/// of them, while decoding a 4-topic payload against the two-parameter schema
/// read the key's length word as the value's tail offset, landed mid-word and
/// took a payload byte as a length — which is how one such log reached an
/// unchecked add in the codec and stalled a sync.
///
/// The 4-topic arm does not assume its layout, it proves it: the key it decodes
/// must hash to topics[2], the indexed copy. A contract that indexed some other
/// parameter fails that check and is skipped rather than written under a wrong
/// key. The 3-topic arm needs no such proof — both key and value are in `data`,
/// so nothing there is inferred from a topic.
pub fn handleDataChanged(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    if (log.topics.len != 3 and log.topics.len != 4) return error.InvalidTopicCount;
    const value_is_indexed = log.topics.len == 4;
    var namehash = log.topics[1];

    const data_values = try abi.decodeValues(
        log.data,
        if (value_is_indexed) &.{.string} else &.{ .string, .bytes },
        self.allocator,
    );
    defer abi.freeValues(data_values, self.allocator);
    const key = data_values[0].string;

    const value: RecordValue = if (value_is_indexed) blk: {
        const key_hash = try hash_mod.keccak256(self.allocator, key);
        if (!key_hash.eql(log.topics[2])) return error.AbiPayloadMismatch;
        break :blk .{ .hashed = log.topics[3] };
    } else .{ .plain = data_values[1].bytes };

    if (!try utils.resolveNamehash(self, protocol, &namehash, resolver, "DataChanged")) return;
    try storeDataRecord(self, protocol, resolver, log, namehash, key, value, "DataChanged", .data_changed, null);
}

fn storeDataRecord(
    self: *Indexer,
    protocol: models.Protocol,
    resolver: Address,
    log: rpc.Log,
    row_key: Hash,
    key: []const u8,
    value: RecordValue,
    event_name: []const u8,
    event_type: models.EventType,
    record_id: ?u256,
) !void {
    const clean_key = try stripNulls(self.allocator, key);
    defer self.allocator.free(clean_key);
    unicode.validateString(clean_key) catch |err| {
        var tx_buf: [66]u8 = undefined;
        std.log.warn("{s} key rejected ({any}) at block {d} tx {s} log_index {d} — event skipped", .{ event_name, err, log.block_number, log.transaction_hash.toHexBuf(&tx_buf), log.log_index });
        return;
    };
    const value_hex = switch (value) {
        .plain => |bytes| try bytesToHexAlloc(self.allocator, bytes),
        .hashed => |h| try h.toHex(self.allocator),
    };
    defer self.allocator.free(value_hex);

    // Three outcomes, and the middle one is why RecordValue exists.
    //
    //  - a verbatim value → the row asserts it;
    //  - cleared, either a verbatim empty value or the indexed keccak256("") →
    //    delete, the record has no value;
    //  - an indexed value that is NOT the empty one → the plaintext is not
    //    derivable from the log. `resolver_datas.value` holds the record's
    //    current plaintext (TEXT NOT NULL, one row per protocol/resolver/
    //    namehash/key), so there is nothing truthful to put in it: "" already
    //    means cleared, and the keccak would read back as a 32-byte value the
    //    record does not have. Keeping a pre-existing row is worse still — the
    //    chain says the value changed, so a stored one is now known to be
    //    stale. The row goes, and the change is kept in event history where the
    //    hash travels under its own name (`valueHash`, never `value`).
    const cleared = switch (value) {
        .plain => |bytes| bytes.len == 0,
        .hashed => |h| h.eql(KECCAK_EMPTY),
    };
    const can_assert_value = value == .plain;
    if (cleared) {
        // House convention for a clear, shared with every other record kind in this
        // file: warn and carry on. The stored value was correct at some block, so a
        // failed delete leaves stale-but-once-true data that a resync heals.
        self.database.deleteResolverData(protocol, row_key, resolver, clean_key) catch |err| {
            std.log.warn("Failed to delete cleared resolver data: {}", .{err});
        };
    } else if (!can_assert_value) {
        var tx_buf: [66]u8 = undefined;
        std.log.warn("{s}: `value` is indexed on this emitter, so only keccak256(value) is on chain — key '{s}' keeps no stored value (block {d} tx {s} log_index {d}); the change is recorded in event history", .{ event_name, clean_key, log.block_number, log.transaction_hash.toHexBuf(&tx_buf), log.log_index });
        // Deliberately NOT best-effort, unlike the clear above. This delete is the
        // only thing between a reader and a value the chain has explicitly
        // superseded, and "no row is the truthful representation" is only true if it
        // actually happened. Swallowing the error would commit the batch and advance
        // the sync cursor past the log, serving a known-wrong value as current until
        // a full resync. Failing here retries it, exactly as a failed store does.
        try self.database.deleteResolverData(protocol, row_key, resolver, clean_key);
    } else {
        try self.database.storeResolverData(row_key, resolver, clean_key, value_hex, protocol, log.block_number, log.transaction_hash, try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp));
    }

    const resolver_hex = try resolver.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);
    const key_hex = try row_key.toHex(self.allocator);
    defer self.allocator.free(key_hex);
    const escaped_key = try json_utils.escapeString(self.allocator, clean_key);
    defer self.allocator.free(escaped_key);
    // A hash is published under `valueHash`, never `value`: every reader of
    // these rows (the API's event value field, replay, at-block reconstruction)
    // treats `value` as the record's plaintext, and a keccak sitting in that
    // field would be served as if it were one.
    const value_field = switch (value) {
        .plain => "value",
        .hashed => "valueHash",
    };
    const event_data = if (record_id) |id|
        try std.fmt.allocPrint(self.allocator, "{{\"resolver\":\"{s}\",\"recordId\":\"{d}\",\"key\":\"{s}\",\"{s}\":\"{s}\"}}", .{ resolver_hex, id, escaped_key, value_field, value_hex })
    else
        try std.fmt.allocPrint(self.allocator, "{{\"namehash\":\"{s}\",\"resolver\":\"{s}\",\"key\":\"{s}\",\"{s}\":\"{s}\"}}", .{ key_hex, resolver_hex, escaped_key, value_field, value_hex });
    const domain_name = if (record_id == null) self.getNameFromNamehash(row_key) else null;
    try utils.emitEvent(self, protocol, log, event_type, domain_name, row_key, event_data);
}

/// ContenthashUpdated(uint256 indexed recordId, bytes hash)
pub fn handleContenthashUpdated(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    const rec = recordFromTopic(log) orelse return;
    const data_values = try abi.decodeValues(log.data, &.{.bytes}, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const hash_bytes = data_values[0].bytes;
    const hash_hex = try bytesToHexAlloc(self.allocator, hash_bytes);
    defer self.allocator.free(hash_hex);

    if (hash_bytes.len == 0) {
        self.database.deleteResolverContentHash(protocol, rec.key, resolver) catch |err| {
            std.log.warn("Failed to clear resolver contenthash: {}", .{err});
        };
    } else {
        try self.database.storeResolverContentHash(rec.key, resolver, hash_hex, protocol, log.block_number, log.transaction_hash, try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp));
    }

    const resolver_hex = try resolver.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);
    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"resolver\":\"{s}\",\"recordId\":\"{d}\",\"contentHash\":\"{s}\"}}", .{ resolver_hex, rec.id, hash_hex });
    try utils.emitEvent(self, protocol, log, .contenthash_updated, null, rec.key, event_data);
}

/// ABIUpdated(uint256 indexed recordId, uint256 indexed contentType) — no payload.
pub fn handleABIUpdated(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    if (log.topics.len < 3) return error.InvalidTopicCount;
    const rec = recordFromTopic(log) orelse return;
    const content_type = try abi.ABI.decodeUint256(&log.topics[2].bytes, 0);
    self.database.storeResolverABI(rec.key, resolver, @truncate(content_type), protocol, log.block_number, log.transaction_hash, try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp)) catch |err| {
        std.log.warn("Failed to store resolver ABI: {}", .{err});
    };
    const resolver_hex = try resolver.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);
    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"resolver\":\"{s}\",\"recordId\":\"{d}\",\"contentType\":{d}}}", .{ resolver_hex, rec.id, content_type });
    try utils.emitEvent(self, protocol, log, .abi_updated, null, rec.key, event_data);
}

/// InterfaceUpdated(uint256 indexed recordId, bytes4 indexed interfaceId, address implementer)
pub fn handleInterfaceUpdated(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    if (log.topics.len < 3) return error.InvalidTopicCount;
    const rec = recordFromTopic(log) orelse return;
    const interface_id_hex = try bytesToHexAlloc(self.allocator, log.topics[2].bytes[0..4]);
    defer self.allocator.free(interface_id_hex);
    const data_values = try abi.decodeValues(log.data, &.{.address}, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const implementer = Address{ .bytes = data_values[0].address };
    const implementer_hex = try implementer.toHex(self.allocator);
    defer self.allocator.free(implementer_hex);

    self.database.storeResolverInterface(rec.key, resolver, interface_id_hex, implementer_hex, protocol, log.block_number, log.transaction_hash, try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp)) catch |err| {
        std.log.warn("Failed to store resolver interface: {}", .{err});
    };

    const resolver_hex = try resolver.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);
    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"resolver\":\"{s}\",\"recordId\":\"{d}\",\"interfaceID\":\"{s}\",\"implementer\":\"{s}\"}}", .{ resolver_hex, rec.id, interface_id_hex, implementer_hex });
    try utils.emitEvent(self, protocol, log, .interface_updated, null, rec.key, event_data);
}

/// NameUpdated(uint256 indexed recordId, string primaryName) — the record's
/// `name()` (reverse) value.
pub fn handleNameUpdated(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    const rec = recordFromTopic(log) orelse return;
    const data_values = try abi.decodeValues(log.data, &.{.string}, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const name = data_values[0].string;
    unicode.validateString(name) catch |err| {
        std.log.warn("Invalid UTF-8 in reverse name: {any}", .{err});
        return;
    };
    self.database.storeResolverName(rec.key, resolver, name, protocol, log.block_number, log.transaction_hash, try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp)) catch |err| {
        std.log.warn("Failed to store resolver name: {}", .{err});
    };

    const resolver_hex = try resolver.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);
    const escaped_name = try json_utils.escapeString(self.allocator, name);
    defer self.allocator.free(escaped_name);
    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"resolver\":\"{s}\",\"recordId\":\"{d}\",\"name\":\"{s}\"}}", .{ resolver_hex, rec.id, escaped_name });
    try utils.emitEvent(self, protocol, log, .name_updated, null, rec.key, event_data);
}

/// Whether `arg` is a printable UTF-8 setter argument (a text/data key).
fn isPrintableUtf8(arg: []const u8) bool {
    if (arg.len == 0) return false;
    unicode.validateString(arg) catch return false;
    for (arg) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

/// ResourceArgument(uint256 indexed resource, bytes arg)
/// Emitted on the first `grantSetterRoles` for a resource: `resource =
/// keccak256(arg)` where `arg` is the setter's argument — a text/data key
/// (string), a coinType/contentType (uint256), or an interfaceId (bytes4).
/// Stored as record_kind "argument": `record_key` carries the argument as
/// text when it is printable UTF-8 (else 0x-hex), `coin_type` its integer
/// value when it is a 32-byte word. Which setter it guards follows from the
/// role bits granted on the resource (`EACRolesChanged`), not the event.
pub fn handleResourceArgument(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    if (log.topics.len < 2) return error.InvalidTopicCount;
    var resource_buf: [66]u8 = undefined;
    const resource_hex = log.topics[1].toHexBuf(&resource_buf);
    const data_values = try abi.decodeValues(log.data, &.{.bytes}, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const arg = data_values[0].bytes;

    const arg_hex = try bytesToHexAlloc(self.allocator, arg);
    defer self.allocator.free(arg_hex);
    const record_key: []const u8 = if (isPrintableUtf8(arg)) arg else arg_hex;
    const coin_type: i64 = if (arg.len == 32) (std.math.cast(i64, std.mem.readInt(u256, arg[0..32], .big)) orelse -1) else -1;

    self.database.upsertNamedResource(protocol, resolver, resource_hex, "argument", record_key, coin_type, "", log.block_number, log.transaction_hash, log.log_index) catch |err| {
        std.log.warn("Failed to store resource argument: {}", .{err});
    };

    const resolver_hex = try resolver.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);
    const escaped_key = try json_utils.escapeString(self.allocator, record_key);
    defer self.allocator.free(escaped_key);
    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"resolver\":\"{s}\",\"resource\":\"{s}\",\"arg\":\"{s}\",\"argument\":\"{s}\"}}", .{ resolver_hex, resource_hex, arg_hex, escaped_key });
    try utils.emitEvent(self, protocol, log, .resource_argument, null, null, event_data);
}

// ============================================================================
// TESTS — drive the handlers with synthetic logs against an in-memory DB.
// ============================================================================

const testing = std.testing;
const db_module = @import("../../storage/database.zig");
const hash_mod = @import("../../types/hash.zig");

const AbiPart = union(enum) {
    word: u256,
    dyn: []const u8,
};

/// Minimal ABI encoder for test payloads: static words inline, dynamic
/// bytes/strings via head offsets + length-prefixed, 32-byte-padded tails.
/// ApprovalUpdated(uint256 indexed recordId, address indexed owner, address indexed operator, bool approved)
/// SharedResolver's per-record operator approval. Its record id IS the name's
/// node (`uint256(node)`), so the approval is stored against that node in
/// resolver_approvals, beside the PublicResolver `Approved` rows.
pub fn handleApprovalUpdated(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    if (log.topics.len < 4) return error.InvalidTopicCount;
    const rec = recordFromTopic(log) orelse return;
    const node = log.topics[1];
    var owner = Address{ .bytes = undefined };
    @memcpy(&owner.bytes, log.topics[2].bytes[12..32]);
    var operator = Address{ .bytes = undefined };
    @memcpy(&operator.bytes, log.topics[3].bytes[12..32]);
    const approved = log.data.len >= 32 and log.data[31] != 0;

    self.database.upsertResolverApproval(protocol, resolver, node, "", operator, approved, log.block_number, log.transaction_hash, log.log_index) catch |err| {
        std.log.warn("Failed to store resolver approval: {}", .{err});
    };

    const resolver_hex = try resolver.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);
    const owner_hex = try owner.toHex(self.allocator);
    defer self.allocator.free(owner_hex);
    const operator_hex = try operator.toHex(self.allocator);
    defer self.allocator.free(operator_hex);
    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"resolver\":\"{s}\",\"recordId\":\"{d}\",\"owner\":\"{s}\",\"operator\":\"{s}\",\"approved\":{s}}}", .{ resolver_hex, rec.id, owner_hex, operator_hex, if (approved) "true" else "false" });
    const domain_name = self.getNameFromNamehash(node);
    try utils.emitEvent(self, protocol, log, .approval_updated, domain_name, node, event_data);
}

fn abiEncode(allocator: std.mem.Allocator, parts: []const AbiPart) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const head_len = parts.len * 32;
    var tail: std.ArrayList(u8) = .empty;
    defer tail.deinit(allocator);
    for (parts) |part| {
        var word: [32]u8 = [_]u8{0} ** 32;
        switch (part) {
            .word => |w| std.mem.writeInt(u256, &word, w, .big),
            .dyn => |d| {
                std.mem.writeInt(u256, &word, @intCast(head_len + tail.items.len), .big);
                var len_word: [32]u8 = [_]u8{0} ** 32;
                std.mem.writeInt(u256, &len_word, @intCast(d.len), .big);
                try tail.appendSlice(allocator, &len_word);
                try tail.appendSlice(allocator, d);
                const pad = (32 - (d.len % 32)) % 32;
                try tail.appendNTimes(allocator, 0, pad);
            },
        }
        try out.appendSlice(allocator, &word);
    }
    try out.appendSlice(allocator, tail.items);
    return out.toOwnedSlice(allocator);
}

fn wordHash(v: u256) Hash {
    var h = Hash{ .bytes = [_]u8{0} ** 32 };
    std.mem.writeInt(u256, &h.bytes, v, .big);
    return h;
}

const TestRig = struct {
    arena: std.heap.ArenaAllocator,
    threaded: std.Io.Threaded,
    database: *db_module.Database,
    idx: Indexer,
    cfg: @import("../../config.zig").Config,
    log_index: u32 = 0,

    fn init() !?*TestRig {
        const rig = try testing.allocator.create(TestRig);
        errdefer testing.allocator.destroy(rig);
        rig.arena = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer rig.arena.deinit();
        const aa = rig.arena.allocator();
        rig.cfg = @import("../../config.zig").Config.fromEnv(aa) catch {
            rig.arena.deinit();
            testing.allocator.destroy(rig);
            return null;
        };
        rig.cfg.status_port = null;
        rig.cfg.webhooks_enabled = false;
        rig.threaded = std.Io.Threaded.init(aa, .{});
        errdefer rig.threaded.deinit();
        rig.database = try aa.create(db_module.Database);
        rig.database.* = try db_module.Database.init(aa, ":memory:");
        errdefer rig.database.deinit();
        rig.idx = try Indexer.init(aa, rig.threaded.io(), rig.cfg, rig.database, null);
        rig.log_index = 0;
        return rig;
    }

    fn deinit(self: *TestRig) void {
        self.idx.deinit();
        self.database.deinit();
        self.threaded.deinit();
        self.cfg.deinit();
        self.arena.deinit();
        testing.allocator.destroy(self);
    }

    fn alloc(self: *TestRig) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn log(self: *TestRig, resolver: Address, topics: []const Hash, data: []u8) !rpc.Log {
        self.log_index += 1;
        return rpc.Log{
            .address = resolver,
            .topics = try self.alloc().dupe(Hash, topics),
            .data = data,
            .block_number = 500,
            .transaction_hash = Hash{ .bytes = [_]u8{0xAB} ** 32 },
            .transaction_index = 0,
            .log_index = self.log_index,
            .removed = false,
            .block_timestamp = 1_700_000_000,
            .block_hash = null,
        };
    }
};

const TEST_RESOLVER = Address{ .bytes = [_]u8{0xDD} ** 20 };
const TEST_LEGACY = Address{ .bytes = [_]u8{0xEE} ** 20 };

fn dnsName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return dns.encodeDNSName(allocator, name);
}

test "record handlers: create, link, update values, share, default, unlink, clear" {
    const rig = (try TestRig.init()) orelse return;
    defer rig.deinit();
    const a = rig.alloc();
    const idx = &rig.idx;
    const db = rig.database;
    const carol = try hash_mod.namehash(a, "carol.eth");
    const erin = try hash_mod.namehash(a, "erin.eth");
    const dave = try hash_mod.namehash(a, "dave.eth");

    // ResolverCreated()
    try handleResolverCreated(idx, .v2, TEST_RESOLVER, try rig.log(TEST_RESOLVER, &.{wordHash(0)}, try a.dupe(u8, "")));
    const kind = (try db.getResolverKind(TEST_RESOLVER)).?;
    defer db.allocator.free(kind);
    try testing.expectEqualStrings("record", kind);

    // setText(carol.eth, "avatar", …) => Linked(1, carol, name) + TextUpdated(1, …)
    try handleLinked(idx, .v2, TEST_RESOLVER, try rig.log(TEST_RESOLVER, &.{ wordHash(0), wordHash(1), carol }, try abiEncode(a, &.{.{ .dyn = try dnsName(a, "carol.eth") }})));
    try handleTextUpdated(idx, .v2, TEST_RESOLVER, try rig.log(TEST_RESOLVER, &.{ wordHash(0), wordHash(1), wordHash(0) }, try abiEncode(a, &.{ .{ .dyn = "avatar" }, .{ .dyn = "https://r1/a.png" } })));
    try handleAddressUpdated(idx, .v2, TEST_RESOLVER, try rig.log(TEST_RESOLVER, &.{ wordHash(0), wordHash(1) }, try abiEncode(a, &.{ .{ .word = 60 }, .{ .dyn = &[_]u8{0x11} ** 20 } })));
    try handleContenthashUpdated(idx, .v2, TEST_RESOLVER, try rig.log(TEST_RESOLVER, &.{ wordHash(0), wordHash(1) }, try abiEncode(a, &.{.{ .dyn = &[_]u8{ 0xe3, 0x01 } }})));
    try handleDataUpdated(idx, .v2, TEST_RESOLVER, try rig.log(TEST_RESOLVER, &.{ wordHash(0), wordHash(1), wordHash(0) }, try abiEncode(a, &.{ .{ .dyn = "blob" }, .{ .dyn = &[_]u8{ 0xde, 0xad } } })));
    try handleNameUpdated(idx, .v2, TEST_RESOLVER, try rig.log(TEST_RESOLVER, &.{ wordHash(0), wordHash(1) }, try abiEncode(a, &.{.{ .dyn = "carol.eth" }})));
    try handleABIUpdated(idx, .v2, TEST_RESOLVER, try rig.log(TEST_RESOLVER, &.{ wordHash(0), wordHash(1), wordHash(1) }, try a.dupe(u8, "")));
    var iface = Hash{ .bytes = [_]u8{0} ** 32 };
    iface.bytes[0] = 0x01;
    iface.bytes[1] = 0xff;
    iface.bytes[2] = 0xc9;
    iface.bytes[3] = 0xa7;
    try handleInterfaceUpdated(idx, .v2, TEST_RESOLVER, try rig.log(TEST_RESOLVER, &.{ wordHash(0), wordHash(1), iface }, try abiEncode(a, &.{.{ .word = 0x2222222222222222222222222222222222222222 }})));

    var link = (try db.getResolverLink(TEST_RESOLVER, carol)).?;
    defer link.deinit(db.allocator);
    try testing.expectEqual(@as(u256, 1), link.record_id);
    try testing.expectEqualStrings("carol.eth", link.name);

    const avatar = (try db.getTextRecord(TEST_RESOLVER, carol, "avatar")).?;
    defer db.allocator.free(avatar);
    try testing.expectEqualStrings("https://r1/a.png", avatar);
    const addr = (try db.getAddressRecord(TEST_RESOLVER, carol, 60)).?;
    defer db.allocator.free(addr);
    try testing.expectEqualStrings("0x1111111111111111111111111111111111111111", addr);
    const ch = (try db.getContentHashRecord(TEST_RESOLVER, carol)).?;
    defer db.allocator.free(ch);
    try testing.expectEqualStrings("0xe301", ch);
    const blob = (try db.getDataRecord(TEST_RESOLVER, carol, "blob")).?;
    defer db.allocator.free(blob);
    try testing.expectEqualStrings("0xdead", blob);
    const primary = (try db.getLatestNameByNamehash(carol)).?;
    defer db.allocator.free(primary);
    try testing.expectEqualStrings("carol.eth", primary);
    const abis = try db.getAbiContentTypes(TEST_RESOLVER, carol);
    defer db.allocator.free(abis);
    try testing.expectEqual(@as(usize, 1), abis.len);
    const ifaces = try db.getInterfaceRecords(TEST_RESOLVER, carol);
    defer {
        for (ifaces) |*i| i.deinit(db.allocator);
        db.allocator.free(ifaces);
    }
    try testing.expectEqual(@as(usize, 1), ifaces.len);
    try testing.expectEqualStrings("0x01ffc9a7", ifaces[0].interface_id);

    // linkToRecord(erin.eth, 1): erin shares carol's record.
    try handleLinked(idx, .v2, TEST_RESOLVER, try rig.log(TEST_RESOLVER, &.{ wordHash(0), wordHash(1), erin }, try abiEncode(a, &.{.{ .dyn = try dnsName(a, "erin.eth") }})));
    const erin_avatar = (try db.getTextRecord(TEST_RESOLVER, erin, "avatar")).?;
    defer db.allocator.free(erin_avatar);
    try testing.expectEqualStrings("https://r1/a.png", erin_avatar);
    const linked = try db.getLinkedNames(a, TEST_RESOLVER, 1);
    try testing.expectEqual(@as(usize, 2), linked.len);

    // Default record: setText(<root>, …) => Linked(2, 0x0, "\x00") + TextUpdated(2).
    try handleLinked(idx, .v2, TEST_RESOLVER, try rig.log(TEST_RESOLVER, &.{ wordHash(0), wordHash(2), Hash.zero }, try abiEncode(a, &.{.{ .dyn = "\x00" }})));
    try handleTextUpdated(idx, .v2, TEST_RESOLVER, try rig.log(TEST_RESOLVER, &.{ wordHash(0), wordHash(2), wordHash(0) }, try abiEncode(a, &.{ .{ .dyn = "avatar" }, .{ .dyn = "https://default/a.png" } })));
    const dave_avatar = (try db.getTextRecord(TEST_RESOLVER, dave, "avatar")).?;
    defer db.allocator.free(dave_avatar);
    try testing.expectEqualStrings("https://default/a.png", dave_avatar);

    // linkToRecord(erin.eth, 0): erin falls back to the default record.
    try handleLinked(idx, .v2, TEST_RESOLVER, try rig.log(TEST_RESOLVER, &.{ wordHash(0), wordHash(0), erin }, try abiEncode(a, &.{.{ .dyn = try dnsName(a, "erin.eth") }})));
    const erin_default = (try db.getTextRecord(TEST_RESOLVER, erin, "avatar")).?;
    defer db.allocator.free(erin_default);
    try testing.expectEqualStrings("https://default/a.png", erin_default);

    // Clearing writes: empty text value / empty address / empty contenthash.
    try handleTextUpdated(idx, .v2, TEST_RESOLVER, try rig.log(TEST_RESOLVER, &.{ wordHash(0), wordHash(1), wordHash(0) }, try abiEncode(a, &.{ .{ .dyn = "avatar" }, .{ .dyn = "" } })));
    try testing.expectEqual(@as(?[]u8, null), try db.getTextRecord(TEST_RESOLVER, carol, "avatar"));
    try handleAddressUpdated(idx, .v2, TEST_RESOLVER, try rig.log(TEST_RESOLVER, &.{ wordHash(0), wordHash(1) }, try abiEncode(a, &.{ .{ .word = 60 }, .{ .dyn = "" } })));
    try testing.expectEqual(@as(?[]u8, null), try db.getAddressRecord(TEST_RESOLVER, carol, 60));
    try handleContenthashUpdated(idx, .v2, TEST_RESOLVER, try rig.log(TEST_RESOLVER, &.{ wordHash(0), wordHash(1) }, try abiEncode(a, &.{.{ .dyn = "" }})));
    try testing.expectEqual(@as(?[]u8, null), try db.getContentHashRecord(TEST_RESOLVER, carol));

    // Cleared(2) drops the default record's values.
    try handleCleared(idx, .v2, TEST_RESOLVER, try rig.log(TEST_RESOLVER, &.{ wordHash(0), wordHash(2) }, try a.dupe(u8, "")));
    try testing.expectEqual(@as(?[]u8, null), try db.getTextRecord(TEST_RESOLVER, dave, "avatar"));

    // A 256-bit record id (SharedResolver keys records by the node itself) is
    // carried at full width, never truncated or skipped.
    const huge_id: u256 = @as(u256, 1) << 200;
    const huge = wordHash(huge_id);
    try handleTextUpdated(idx, .v2, TEST_RESOLVER, try rig.log(TEST_RESOLVER, &.{ wordHash(0), huge, wordHash(0) }, try abiEncode(a, &.{ .{ .dyn = "k" }, .{ .dyn = "v" } })));
    // Read the row directly: name-resolution reads translate through links, and
    // no name is linked to this record (a bare setter write on a fresh id).
    var huge_q = try db_module.Query.init(db, "SELECT value FROM resolver_texts WHERE resolver = ? AND namehash = ? AND key = 'k'");
    defer huge_q.deinit();
    try huge_q.bindAddress(TEST_RESOLVER);
    try huge_q.bindHash(record_model.recordKey(huge_id));
    try testing.expect(try huge_q.step());
    try testing.expectEqualStrings("v", huge_q.getTextSlice(0).?);

    // SharedResolver approvals: the record id is the node, so the approval
    // lands on the name in resolver_approvals.
    try handleApprovalUpdated(idx, .v2, TEST_RESOLVER, try rig.log(TEST_RESOLVER, &.{ wordHash(0), carol, wordHash(0x1111111111111111111111111111111111111111), wordHash(0x2222222222222222222222222222222222222222) }, try abiEncode(a, &.{.{ .word = 1 }})));
    var approvals_q = try db_module.Query.init(db, "SELECT COUNT(*) FROM resolver_approvals WHERE approved = 1 AND delegate = '0x2222222222222222222222222222222222222222'");
    defer approvals_q.deinit();
    try testing.expect(try approvals_q.step());
    try testing.expectEqual(@as(i64, 1), approvals_q.getInt64(0));

    // Every handler emitted its event row.
    var q = try db_module.Query.init(db, "SELECT COUNT(*) FROM events WHERE event_type IN ('ResolverCreated','Linked','TextUpdated','AddressUpdated','ContenthashUpdated','DataUpdated','NameUpdated','ABIUpdated','InterfaceUpdated','Cleared','ApprovalUpdated')");
    defer q.deinit();
    try testing.expect(try q.step());
    try testing.expectEqual(@as(i64, 19), q.getInt64(0));
}

test "record handlers: ResourceArgument and legacy DataChanged" {
    const rig = (try TestRig.init()) orelse return;
    defer rig.deinit();
    const a = rig.alloc();
    const idx = &rig.idx;
    const db = rig.database;

    // grantSetterRoles(setText(name, "avatar", …)) => ResourceArgument(keccak("avatar"), "avatar")
    var resource: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash("avatar", &resource, .{});
    try handleResourceArgument(idx, .v2, TEST_RESOLVER, try rig.log(TEST_RESOLVER, &.{ wordHash(0), Hash{ .bytes = resource } }, try abiEncode(a, &.{.{ .dyn = "avatar" }})));
    // setAddress(name, 60, …) => arg = abi.encodePacked(uint256(60))
    var coin_word: [32]u8 = [_]u8{0} ** 32;
    coin_word[31] = 60;
    var coin_resource: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&coin_word, &coin_resource, .{});
    try handleResourceArgument(idx, .v2, TEST_RESOLVER, try rig.log(TEST_RESOLVER, &.{ wordHash(0), Hash{ .bytes = coin_resource } }, try abiEncode(a, &.{.{ .dyn = &coin_word }})));

    const rows = try db.getNamedResources(a, .v2, TEST_RESOLVER);
    try testing.expectEqual(@as(usize, 2), rows.len);
    var saw_text = false;
    var saw_coin = false;
    for (rows) |row| {
        try testing.expectEqualStrings("argument", row.record_kind);
        if (std.mem.eql(u8, row.record_key, "avatar")) saw_text = true;
        if (row.coin_type == 60) saw_coin = true;
    }
    try testing.expect(saw_text and saw_coin);

    // Legacy DataChanged on a node-keyed resolver.
    const node = try hash_mod.namehash(a, "legacy.eth");
    try handleDataChanged(idx, .v2, TEST_LEGACY, try rig.log(TEST_LEGACY, &.{ wordHash(0), node, wordHash(0) }, try abiEncode(a, &.{ .{ .dyn = "blob" }, .{ .dyn = &[_]u8{0x01} } })));
    const v = (try db.getDataRecord(TEST_LEGACY, node, "blob")).?;
    defer db.allocator.free(v);
    try testing.expectEqualStrings("0x01", v);

    // The production shape that stalled a sync: the SAME DataChanged signature
    // hash from a contract that marks `value` indexed too, so ONE value sits in
    // `data` instead of two and topics[3] carries keccak256(value). `indexed` is
    // not part of topic0, so it lands in this handler regardless, and decoding it
    // as two parameters read the key's length word as the value's tail offset.
    // This is the ONLY shape this signature has produced on Sepolia (79 logs,
    // 26 emitters), so it must be indexed, not rejected.
    const pkey = "knowledge.proposal.acme-dev.eth";
    const pkey_hash = try hash_mod.keccak256(a, pkey);
    var value_hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&[_]u8{ 0x07, 0x07 }, &value_hash, .{});
    try handleDataChanged(idx, .v2, TEST_LEGACY, try rig.log(
        TEST_LEGACY,
        &.{ wordHash(0), node, pkey_hash, Hash{ .bytes = value_hash } },
        try abiEncode(a, &.{.{ .dyn = pkey }}),
    ));
    // No value is stored: only keccak256(value) was ever on chain, and
    // resolver_datas.value is the record's plaintext. Writing the hash there
    // would be served as the value; writing "" would read back as "cleared".
    try testing.expectEqual(@as(?[]u8, null), try db.getDataRecord(TEST_LEGACY, node, pkey));
    // The change is not lost, though — it is in event history, with the hash
    // under its own field name so no reader mistakes it for a value.
    {
        const nh_hex = try node.toHex(a);
        const events = try db.getEventsByNamehash(nh_hex, 100);
        defer {
            for (events) |*e| e.deinit(db.allocator);
            db.allocator.free(events);
        }
        var saw = false;
        for (events) |e| {
            if (e.event_type != .data_changed) continue;
            if (std.mem.indexOf(u8, e.data, pkey) == null) continue;
            saw = true;
            try testing.expect(std.mem.indexOf(u8, e.data, "\"valueHash\":") != null);
            try testing.expect(std.mem.indexOf(u8, e.data, "\"value\":") == null);
        }
        try testing.expect(saw);
    }

    // A value change we cannot read must not leave a previous value standing:
    // the chain says the record changed, so a stored plaintext is now known to be
    // stale. "blob" was written verbatim above; re-emitting it with an indexed
    // value drops the row rather than keeping the old 0x01.
    var blob_key_hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash("blob", &blob_key_hash, .{});
    try handleDataChanged(idx, .v2, TEST_LEGACY, try rig.log(
        TEST_LEGACY,
        &.{ wordHash(0), node, Hash{ .bytes = blob_key_hash }, Hash{ .bytes = value_hash } },
        try abiEncode(a, &.{.{ .dyn = "blob" }}),
    ));
    try testing.expectEqual(@as(?[]u8, null), try db.getDataRecord(TEST_LEGACY, node, "blob"));

    // keccak256("") is the one hashed value whose preimage IS known: it means
    // cleared, and takes the ordinary delete path.
    try handleDataChanged(idx, .v2, TEST_LEGACY, try rig.log(
        TEST_LEGACY,
        &.{ wordHash(0), node, Hash{ .bytes = blob_key_hash }, KECCAK_EMPTY },
        try abiEncode(a, &.{.{ .dyn = "blob" }}),
    ));
    try testing.expectEqual(@as(?[]u8, null), try db.getDataRecord(TEST_LEGACY, node, "blob"));

    // The 4-topic arm PROVES its layout instead of assuming it: the decoded key
    // must hash to topics[2], the indexed copy. A contract that indexed some
    // other parameter fails here and is skipped, never written under a wrong key.
    try testing.expectError(error.AbiPayloadMismatch, handleDataChanged(idx, .v2, TEST_LEGACY, try rig.log(
        TEST_LEGACY,
        &.{ wordHash(0), node, wordHash(0xdeadbeef), Hash{ .bytes = value_hash } },
        try abiEncode(a, &.{.{ .dyn = pkey }}),
    )));
    // Neither shape is 2 or 5 topics; those stay rejected outright.
    try testing.expectError(error.InvalidTopicCount, handleDataChanged(idx, .v2, TEST_LEGACY, try rig.log(
        TEST_LEGACY,
        &.{ wordHash(0), node },
        try abiEncode(a, &.{.{ .dyn = pkey }}),
    )));
    try testing.expectError(error.InvalidTopicCount, handleDataChanged(idx, .v2, TEST_LEGACY, try rig.log(
        TEST_LEGACY,
        &.{ wordHash(0), node, pkey_hash, Hash{ .bytes = value_hash }, wordHash(1) },
        try abiEncode(a, &.{.{ .dyn = pkey }}),
    )));
    // ...and every rejection must be on the skip list, or dispatch aborts the
    // whole batch instead of dropping the single event.
    try testing.expect(utils.isMalformedEventError(error.InvalidTopicCount));
    try testing.expect(utils.isMalformedEventError(error.AbiPayloadMismatch));

    // "blob" was stored then dropped, and the indexed-value key never stored a
    // value, so no data row survives on this node.
    const keys = try db.getDataKeys(TEST_LEGACY, node);
    defer {
        for (keys) |k| db.allocator.free(k);
        db.allocator.free(keys);
    }
    try testing.expectEqual(@as(usize, 0), keys.len);
}
