const std = @import("std");
const zsys = @import("../../utils/system.zig");
const models = @import("../../types/models.zig");
// ABI decoding migrated to eth.zig-backed shim. Old `../abi.zig` kept for
// fallback. This file uses no EventSignatures, so the swap is wholesale.
const abi = @import("../abi_eth.zig");
const rpc = @import("../../rpc/client.zig");
const Hash = @import("../../types/hash.zig").Hash;
const Address = @import("../../types/address.zig").Address;
const Indexer = @import("../indexer.zig").Indexer;
const utils = @import("../utils.zig");
const unicode = @import("../../utils/unicode.zig");
const json_utils = @import("../../utils/json.zig");
const dns = @import("../../utils/dns.zig");

/// Handle legacy AddrChanged event (2017 Public Resolver)
/// AddrChanged(bytes32 indexed node, address a)
/// Stores as coinType=60 (ETH) to match modern AddressChanged format
///
/// Storage idempotent; event emit suppressed to avoid double-counting against
/// the paired `AddressChanged` event that modern resolvers (2018+) also emit
/// for the same write. Legacy 2017 PublicResolver standalone AddrChanged
/// writes lose the event row — accepted trade.
pub fn handleLegacyAddrChanged(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    if (log.topics.len < 2) return error.InvalidTopicCount;
    var namehash = log.topics[1];

    // Non-indexed payload: (address a)
    const data_values = try abi.decodeValues(log.data, &.{.address}, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const addr = Address{ .bytes = data_values[0].address };

    if (!try utils.resolveNamehash(self, &namehash, resolver, "AddrChanged")) return;

    const addr_hex = try addr.toHex(self.allocator);
    defer self.allocator.free(addr_hex);

    const nh_hex_log = try namehash.toHex(self.allocator);
    defer self.allocator.free(nh_hex_log);
    std.log.debug("AddrChanged (legacy): namehash={s} address={s}", .{
        nh_hex_log,
        addr_hex,
    });

    // Store as coinType=60 (ETH)
    try self.database.storeResolverAddress(
        namehash,
        resolver,
        60, // ETH coin type
        addr_hex,
        protocol,
        log.block_number,
        log.transaction_hash,
        try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
    );
}

/// Handle legacy ContentChanged event (2017 Public Resolver)
/// ContentChanged(bytes32 indexed node, bytes32 hash)
/// Stores as hex-encoded content hash to match modern ContentHashChanged format
pub fn handleLegacyContentChanged(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    if (log.topics.len < 2) return error.InvalidTopicCount;
    var namehash = log.topics[1];

    // Non-indexed payload: (bytes32 hash)
    const data_values = try abi.decodeValues(log.data, &.{.bytes32}, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const content_hash = Hash{ .bytes = data_values[0].fixed_bytes.data };

    if (!try utils.resolveNamehash(self, &namehash, resolver, "ContentChanged")) return;

    const content_hex = try content_hash.toHex(self.allocator);
    defer self.allocator.free(content_hex);

    // Prepend 0x for consistent storage format
    const content_hash_hex = try std.fmt.allocPrint(self.allocator, "0x{s}", .{content_hex});
    defer self.allocator.free(content_hash_hex);

    const nh_hex_log = try namehash.toHex(self.allocator);
    defer self.allocator.free(nh_hex_log);
    std.log.debug("ContentChanged (legacy): namehash={s} contentHash={s}", .{
        nh_hex_log,
        content_hash_hex,
    });

    // Store in database
    try self.database.storeResolverContentHash(
        namehash,
        resolver,
        content_hash_hex,
        protocol,
        log.block_number,
        log.transaction_hash,
        try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
    );

    // Store event
    const nh_hex = try namehash.toHex(self.allocator);
    defer self.allocator.free(nh_hex);
    const resolver_hex = try resolver.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"namehash\":\"{s}\",\"resolver\":\"{s}\",\"contentHash\":\"{s}\"}}", .{
        nh_hex,
        resolver_hex,
        content_hash_hex,
    });

    const domain_name = self.getNameFromNamehash(namehash);
    try utils.emitEvent(self, protocol, log, .contenthash_changed, domain_name, namehash, event_data);
}

/// Handle AddressChanged event
/// AddressChanged(bytes32 indexed node, uint256 coinType, bytes newAddress)
pub fn handleAddressChanged(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    if (log.topics.len < 2) return error.InvalidTopicCount;
    var namehash = log.topics[1];

    // Non-indexed payload: (uint256 coinType, bytes newAddress)
    const data_values = try abi.decodeValues(log.data, &.{ .uint256, .bytes }, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const coin_type = data_values[0].uint256;
    const address_bytes = data_values[1].bytes;

    // Convert address bytes to hex string
    var address_hex = try self.allocator.alloc(u8, 2 + address_bytes.len * 2);
    defer self.allocator.free(address_hex);
    address_hex[0] = '0';
    address_hex[1] = 'x';
    for (address_bytes, 0..) |byte, i| {
        _ = try std.fmt.bufPrint(address_hex[2 + i * 2 .. 4 + i * 2], "{x:0>2}", .{byte});
    }

    if (!try utils.resolveNamehash(self, &namehash, resolver, "AddressChanged")) return;

    // ENSIP-11 coin types fit u32 (0x80000000 | chainId); the column is a
    // 64-bit INTEGER. A hostile contract can emit any uint256 — reject it as
    // malformed (skipped with coordinates) instead of @intCast panicking.
    const coin_type_i64 = std.math.cast(i64, coin_type) orelse return error.ValueOutOfRange;

    const nh_hex_log = try namehash.toHex(self.allocator);
    defer self.allocator.free(nh_hex_log);
    std.log.debug("AddressChanged: namehash={s} coinType={d} address={s}", .{
        nh_hex_log,
        coin_type,
        address_hex,
    });

    // Store in database
    try self.database.storeResolverAddress(
        namehash,
        resolver,
        @intCast(coin_type_i64),
        address_hex,
        protocol,
        log.block_number,
        log.transaction_hash,
        try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
    );

    // Store event and trigger webhooks
    const nh_hex = try namehash.toHex(self.allocator);
    defer self.allocator.free(nh_hex);
    const resolver_hex = try resolver.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"namehash\":\"{s}\",\"resolver\":\"{s}\",\"coinType\":{d},\"address\":\"{s}\"}}", .{
        nh_hex,
        resolver_hex,
        coin_type,
        address_hex,
    });

    // Look up domain name from namehash
    const domain_name = self.getNameFromNamehash(namehash);

    try utils.emitEvent(self, protocol, log, .address_changed, domain_name, namehash, event_data);
}

/// Handle ContenthashChanged event (note: lowercase 'h' — canonical ENS event name).
/// ContenthashChanged(bytes32 indexed node, bytes hash)
pub fn handleContentHashChanged(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    if (log.topics.len < 2) return error.InvalidTopicCount;
    var namehash = log.topics[1];

    // Non-indexed payload: (bytes hash)
    const data_values = try abi.decodeValues(log.data, &.{.bytes}, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const content_hash_bytes = data_values[0].bytes;

    // Convert to hex string
    var content_hash_hex = try self.allocator.alloc(u8, 2 + content_hash_bytes.len * 2);
    defer self.allocator.free(content_hash_hex);
    content_hash_hex[0] = '0';
    content_hash_hex[1] = 'x';
    for (content_hash_bytes, 0..) |byte, i| {
        _ = try std.fmt.bufPrint(content_hash_hex[2 + i * 2 .. 4 + i * 2], "{x:0>2}", .{byte});
    }

    if (!try utils.resolveNamehash(self, &namehash, resolver, "ContenthashChanged")) return;

    const nh_hex_log = try namehash.toHex(self.allocator);
    defer self.allocator.free(nh_hex_log);
    std.log.debug("ContenthashChanged: namehash={s} contentHash={s}", .{
        nh_hex_log,
        content_hash_hex,
    });

    // Store in database
    try self.database.storeResolverContentHash(
        namehash,
        resolver,
        content_hash_hex,
        protocol,
        log.block_number,
        log.transaction_hash,
        try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
    );

    // Store event and trigger webhooks
    const nh_hex = try namehash.toHex(self.allocator);
    defer self.allocator.free(nh_hex);
    const resolver_hex = try resolver.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"namehash\":\"{s}\",\"resolver\":\"{s}\",\"contentHash\":\"{s}\"}}", .{
        nh_hex,
        resolver_hex,
        content_hash_hex,
    });

    // Look up domain name from namehash
    const domain_name = self.getNameFromNamehash(namehash);

    try utils.emitEvent(self, protocol, log, .contenthash_changed, domain_name, namehash, event_data);
}

/// Return a newly allocated copy of `input` with all 0x00 bytes removed.
/// Subgraph parity: SQLite TEXT and JSON output don't tolerate NUL bytes well.
/// Caller owns the returned slice.
fn stripNulls(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, input.len);
    for (input) |b| {
        if (b != 0) out.appendAssumeCapacity(b);
    }
    return try out.toOwnedSlice(allocator);
}

/// Handle TextChanged event
/// TextChanged(bytes32 indexed node, string indexed indexedKey, string key, string value)
pub fn handleTextChanged(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    // topics[2] = indexed key (hashed, not useful)
    if (log.topics.len < 2) return error.InvalidTopicCount;
    var namehash = log.topics[1];

    // Non-indexed payload: (string key, string value)
    const data_values = try abi.decodeValues(log.data, &.{ .string, .string }, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const key = data_values[0].string;
    const value = data_values[1].string;

    if (!try utils.resolveNamehash(self, &namehash, resolver, "TextChanged")) return;

    // Subgraph parity: strip embedded NULs BEFORE validating — clients that
    // pass fixed-width padded strings emit keys like "com.twitter\x00", which
    // the subgraph stores stripped; validating the raw bytes first rejected
    // the whole event. Then validate the cleaned strings: a bad KEY is
    // unaddressable, so the event is skipped (with coordinates); a bad VALUE
    // clears the key like an empty value would — dropping the event outright
    // left the previous value serving stale while on-chain state changed.
    const clean_key = try stripNulls(self.allocator, key);
    defer self.allocator.free(clean_key);
    const clean_value = try stripNulls(self.allocator, value);
    defer self.allocator.free(clean_value);

    unicode.validateString(clean_key) catch |err| {
        var tx_buf: [66]u8 = undefined;
        std.log.warn("TextChanged key rejected ({any}) at block {d} tx {s} log_index {d} — event skipped", .{ err, log.block_number, log.transaction_hash.toHexBuf(&tx_buf), log.log_index });
        return;
    };
    const value_ok = blk: {
        unicode.validateString(clean_value) catch |err| {
            var tx_buf: [66]u8 = undefined;
            std.log.warn("TextChanged value rejected ({any}) at block {d} tx {s} log_index {d} — clearing key", .{ err, log.block_number, log.transaction_hash.toHexBuf(&tx_buf), log.log_index });
            break :blk false;
        };
        break :blk true;
    };
    const effective_value: []const u8 = if (value_ok) clean_value else "";

    const nh_hex_log = try namehash.toHex(self.allocator);
    defer self.allocator.free(nh_hex_log);
    std.log.debug("TextChanged: namehash={s} key={s} value={s}", .{
        nh_hex_log,
        clean_key,
        effective_value,
    });

    if (effective_value.len == 0) {
        // Empty or unusable value → treat as a clear. Skip INSERT, still emit
        // the event row so audit history is preserved.
        self.database.deleteResolverText(protocol, namehash, resolver, clean_key) catch |err| {
            std.log.warn("Failed to delete cleared resolver text: {}", .{err});
        };
    } else {
        try self.database.storeResolverText(
            namehash,
            resolver,
            clean_key,
            effective_value,
            protocol,
            log.block_number,
            log.transaction_hash,
            try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
        );
    }

    // Store event and trigger webhooks
    const nh_hex = try namehash.toHex(self.allocator);
    defer self.allocator.free(nh_hex);
    const resolver_hex = try resolver.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);

    // Escape key and value for safe JSON inclusion
    const escaped_key = try json_utils.escapeString(self.allocator, clean_key);
    defer self.allocator.free(escaped_key);
    const escaped_value = try json_utils.escapeString(self.allocator, effective_value);
    defer self.allocator.free(escaped_value);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"namehash\":\"{s}\",\"resolver\":\"{s}\",\"key\":\"{s}\",\"value\":\"{s}\"}}", .{
        nh_hex,
        resolver_hex,
        escaped_key,
        escaped_value,
    });

    // Look up domain name from namehash
    const domain_name = self.getNameFromNamehash(namehash);

    try utils.emitEvent(self, protocol, log, .text_changed, domain_name, namehash, event_data);
}

/// Handle legacy TextChanged event (V1 LegacyPublicResolver, 2017)
/// TextChanged(bytes32 indexed node, string indexed indexedKey, string value)
///
/// Differs from the modern 4-arg variant: the non-indexed payload is just
/// `(string value)` — there is no separate plaintext `key`, only the
/// keccak-hashed key in topic[1]/topic[2]. Without the plaintext key we
/// store using the hashed key hex as a placeholder so the event row is
/// recoverable; V2 resolvers always emit the 4-arg variant so this path is
/// V1-only.
pub fn handleLegacyTextChanged(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    // topics[2] = indexed hashed key (keccak256 of the plaintext key)
    if (log.topics.len < 2) return error.InvalidTopicCount;
    var namehash = log.topics[1];

    // Non-indexed payload for the 3-arg variant: (string value) only.
    const data_values = try abi.decodeValues(log.data, &.{.string}, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const value = data_values[0].string;

    if (!try utils.resolveNamehash(self, &namehash, resolver, "TextChanged (legacy)")) return;

    // Use the hashed indexed key as the storage key (prefixed to mark it as
    // hashed-only — we don't have the plaintext from this event variant).
    const key_storage: []u8 = blk: {
        if (log.topics.len >= 3) {
            const hashed_hex = try log.topics[2].toHex(self.allocator);
            defer self.allocator.free(hashed_hex);
            break :blk try std.fmt.allocPrint(self.allocator, "hashed:0x{s}", .{hashed_hex});
        } else {
            break :blk try self.allocator.dupe(u8, "hashed:unknown");
        }
    };
    defer self.allocator.free(key_storage);

    // Same order as the modern handler: strip NULs first, then validate; an
    // unusable value clears the (hashed) key rather than dropping the event.
    const clean_value = try stripNulls(self.allocator, value);
    defer self.allocator.free(clean_value);
    const value_ok = blk: {
        unicode.validateString(clean_value) catch |err| {
            var tx_buf: [66]u8 = undefined;
            std.log.warn("TextChanged (legacy) value rejected ({any}) at block {d} tx {s} log_index {d} — clearing key", .{ err, log.block_number, log.transaction_hash.toHexBuf(&tx_buf), log.log_index });
            break :blk false;
        };
        break :blk true;
    };
    const effective_value: []const u8 = if (value_ok) clean_value else "";

    if (effective_value.len == 0) {
        self.database.deleteResolverText(protocol, namehash, resolver, key_storage) catch |err| {
            std.log.warn("Failed to delete legacy resolver text: {}", .{err});
        };
    } else {
        try self.database.storeResolverText(
            namehash,
            resolver,
            key_storage,
            effective_value,
            protocol,
            log.block_number,
            log.transaction_hash,
            try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
        );
    }

    const nh_hex = try namehash.toHex(self.allocator);
    defer self.allocator.free(nh_hex);
    const resolver_hex = try resolver.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);

    const escaped_key = try json_utils.escapeString(self.allocator, key_storage);
    defer self.allocator.free(escaped_key);
    const escaped_value = try json_utils.escapeString(self.allocator, effective_value);
    defer self.allocator.free(escaped_value);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"namehash\":\"{s}\",\"resolver\":\"{s}\",\"key\":\"{s}\",\"value\":\"{s}\"}}", .{
        nh_hex,
        resolver_hex,
        escaped_key,
        escaped_value,
    });

    const domain_name = self.getNameFromNamehash(namehash);
    try utils.emitEvent(self, protocol, log, .text_changed, domain_name, namehash, event_data);
}

/// Handle AuthorisationChanged event (V1 PublicResolver `Authorisable` mixin)
/// AuthorisationChanged(bytes32 indexed node, address indexed owner, address indexed target, bool isAuthorised)
///
/// V2 PermissionedResolver does NOT emit this — pure V1 additive subscription.
pub fn handleAuthorisationChanged(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node
    // topics[2] = indexed owner
    // topics[3] = indexed target
    // data       = (bool isAuthorised)
    if (log.topics.len < 4) return error.InvalidTopicCount;
    var namehash = log.topics[1];

    // Owner and target are 20-byte addresses right-aligned in the 32-byte topic.
    var owner = Address{ .bytes = undefined };
    @memcpy(&owner.bytes, log.topics[2].bytes[12..32]);
    var target = Address{ .bytes = undefined };
    @memcpy(&target.bytes, log.topics[3].bytes[12..32]);

    // bool occupies the low byte of a 32-byte word.
    var is_authorised: bool = false;
    if (log.data.len >= 32) {
        const data_values = abi.decodeValues(log.data, &.{.bool}, self.allocator) catch null;
        if (data_values) |dv| {
            defer abi.freeValues(dv, self.allocator);
            is_authorised = dv[0].boolean;
        } else {
            is_authorised = log.data[31] != 0;
        }
    }

    if (!try utils.resolveNamehash(self, &namehash, resolver, "AuthorisationChanged")) return;

    self.database.storeResolverAuthorisation(
        protocol,
        namehash,
        resolver,
        owner,
        target,
        is_authorised,
        log.block_number,
        log.transaction_hash,
        log.log_index,
        try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
    ) catch |err| {
        std.log.warn("Failed to store resolver authorisation: {}", .{err});
    };

    const nh_hex = try namehash.toHex(self.allocator);
    defer self.allocator.free(nh_hex);
    const resolver_hex = try resolver.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);
    const owner_hex = try owner.toHex(self.allocator);
    defer self.allocator.free(owner_hex);
    const target_hex = try target.toHex(self.allocator);
    defer self.allocator.free(target_hex);

    const event_data = try std.fmt.allocPrint(
        self.allocator,
        "{{\"namehash\":\"{s}\",\"resolver\":\"{s}\",\"owner\":\"{s}\",\"target\":\"{s}\",\"isAuthorised\":{s}}}",
        .{
            nh_hex,
            resolver_hex,
            owner_hex,
            target_hex,
            if (is_authorised) "true" else "false",
        },
    );

    const domain_name = self.getNameFromNamehash(namehash);
    try utils.emitEvent(self, protocol, log, .resolver_update, domain_name, namehash, event_data);
}

/// Approved(address owner, bytes32 indexed node, address indexed delegate, bool indexed approved)
/// Per-name delegate approval (PublicResolver 2023+) — the modern successor to
/// AuthorisationChanged. `owner` rides in data; node/delegate/approved are
/// indexed. Stored with context = "" (NOT NULL): SQL NULLs never conflict, so a
/// NULL context would insert a fresh row per event — duplicates on re-index and
/// no in-place revoke. Empty string keeps the UNIQUE key live; the nullable
/// column itself is reserved for future context-scoped approval variants.
pub fn handleApproved(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    if (log.topics.len < 4) return error.InvalidTopicCount;
    var namehash = log.topics[1];

    var delegate = Address{ .bytes = undefined };
    @memcpy(&delegate.bytes, log.topics[2].bytes[12..32]);
    const approved = log.topics[3].bytes[31] != 0;

    // owner is the single non-indexed word.
    var owner = Address.zero;
    if (log.data.len >= 32) {
        @memcpy(&owner.bytes, log.data[12..32]);
    }

    if (!try utils.resolveNamehash(self, &namehash, resolver, "Approved")) return;

    self.database.upsertResolverApproval(
        protocol,
        resolver,
        namehash,
        "",
        delegate,
        approved,
        log.block_number,
        log.transaction_hash,
        log.log_index,
    ) catch |err| {
        std.log.warn("Failed to store resolver approval: {}", .{err});
    };

    const nh_hex = try namehash.toHex(self.allocator);
    defer self.allocator.free(nh_hex);
    const resolver_hex = try resolver.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);
    const owner_hex = try owner.toHex(self.allocator);
    defer self.allocator.free(owner_hex);
    const delegate_hex = try delegate.toHex(self.allocator);
    defer self.allocator.free(delegate_hex);

    const event_data = try std.fmt.allocPrint(
        self.allocator,
        "{{\"namehash\":\"{s}\",\"resolver\":\"{s}\",\"owner\":\"{s}\",\"delegate\":\"{s}\",\"approved\":{s}}}",
        .{
            nh_hex,
            resolver_hex,
            owner_hex,
            delegate_hex,
            if (approved) "true" else "false",
        },
    );

    const domain_name = self.getNameFromNamehash(namehash);
    try utils.emitEvent(self, protocol, log, .resolver_update, domain_name, namehash, event_data);
}

/// Shared body for the four PermissionedResolver Named*Resource events —
/// resource-naming discovery for the EAC permission model, emitted on the
/// FIRST role grant for a resource. topics[1] is the resource id (stored as
/// its 32-byte hex); the name rides in data DNS-encoded (decode failures fold
/// to null → warn + skip, matching the other DNS consumers).
fn handleNamedResourceKind(
    self: *Indexer,
    protocol: models.Protocol,
    resolver: Address,
    log: rpc.Log,
    record_kind: []const u8,
    record_key: []const u8,
    coin_type: i64,
    name_bytes: []const u8,
) !void {
    if (log.topics.len < 2) return error.InvalidTopicCount;
    var resource_buf: [66]u8 = undefined;
    const resource_hex = log.topics[1].toHexBuf(&resource_buf);

    const name = (try dns.decodeDNSNameToString(self.allocator, name_bytes)) orelse {
        std.log.warn("NamedResource({s}): failed to decode DNS-encoded name for resource {s}", .{ record_kind, resource_hex });
        return;
    };
    defer self.allocator.free(name);

    self.database.upsertNamedResource(
        protocol,
        resolver,
        resource_hex,
        record_kind,
        record_key,
        coin_type,
        name,
        log.block_number,
        log.transaction_hash,
        log.log_index,
    ) catch |err| {
        std.log.warn("Failed to store named resource: {}", .{err});
    };
}

/// NamedResource(uint256 indexed resource, bytes name)
pub fn handleNamedResource(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    const data_values = try abi.decodeValues(log.data, &.{.bytes}, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    try handleNamedResourceKind(self, protocol, resolver, log, "name", "", -1, data_values[0].bytes);
}

/// NamedTextResource(uint256 indexed resource, bytes name, bytes32 indexed keyHash, string key)
pub fn handleNamedTextResource(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    const data_values = try abi.decodeValues(log.data, &.{ .bytes, .string }, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    try handleNamedResourceKind(self, protocol, resolver, log, "text", data_values[1].string, -1, data_values[0].bytes);
}

/// NamedDataResource(uint256 indexed resource, bytes name, bytes32 indexed keyHash, string key)
pub fn handleNamedDataResource(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    const data_values = try abi.decodeValues(log.data, &.{ .bytes, .string }, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    try handleNamedResourceKind(self, protocol, resolver, log, "data", data_values[1].string, -1, data_values[0].bytes);
}

/// NamedAddrResource(uint256 indexed resource, bytes name, uint256 indexed coinType)
pub fn handleNamedAddrResource(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    if (log.topics.len < 3) return error.InvalidTopicCount;
    // ENSIP-11 coin types fit i64 in practice; anything larger stores the -1
    // sentinel rather than truncating silently.
    const raw: u256 = std.mem.readInt(u256, &log.topics[2].bytes, .big);
    const coin_type: i64 = std.math.cast(i64, raw) orelse -1;
    const data_values = try abi.decodeValues(log.data, &.{.bytes}, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    try handleNamedResourceKind(self, protocol, resolver, log, "addr", "", coin_type, data_values[0].bytes);
}

/// Convert a byte slice to a `0x`-prefixed lowercase hex string. Caller owns
/// the returned slice. Used for ENSIP-17 DNS record payloads.
fn bytesToHexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, 2 + bytes.len * 2);
    out[0] = '0';
    out[1] = 'x';
    for (bytes, 0..) |byte, i| {
        _ = try std.fmt.bufPrint(out[2 + i * 2 .. 4 + i * 2], "{x:0>2}", .{byte});
    }
    return out;
}

/// Handle DNSRecordChanged event (ENSIP-17)
/// DNSRecordChanged(bytes32 indexed node, bytes name, uint16 resource, bytes record)
pub fn handleDnsRecordChanged(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    if (log.topics.len < 2) return error.InvalidTopicCount;
    var namehash = log.topics[1];

    const data_values = try abi.decodeValues(log.data, &.{ .bytes, .uint16, .bytes }, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const dns_name_bytes = data_values[0].bytes;
    const resource: u16 = @truncate(data_values[1].uint256);
    const record_bytes = data_values[2].bytes;

    if (!try utils.resolveNamehash(self, &namehash, resolver, "DNSRecordChanged")) return;

    const dns_name_hex = try bytesToHexAlloc(self.allocator, dns_name_bytes);
    defer self.allocator.free(dns_name_hex);
    const record_hex = try bytesToHexAlloc(self.allocator, record_bytes);
    defer self.allocator.free(record_hex);

    self.database.storeResolverDnsRecord(
        protocol,
        namehash,
        resolver,
        dns_name_hex,
        resource,
        record_hex,
        log.block_number,
        log.transaction_hash,
        log.log_index,
        try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
    ) catch |err| {
        std.log.warn("Failed to store resolver DNS record: {}", .{err});
    };

    const nh_hex = try namehash.toHex(self.allocator);
    defer self.allocator.free(nh_hex);
    const resolver_hex = try resolver.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);

    const event_data = try std.fmt.allocPrint(
        self.allocator,
        "{{\"namehash\":\"{s}\",\"resolver\":\"{s}\",\"dnsName\":\"{s}\",\"resource\":{d},\"record\":\"{s}\"}}",
        .{ nh_hex, resolver_hex, dns_name_hex, resource, record_hex },
    );

    const domain_name = self.getNameFromNamehash(namehash);
    try utils.emitEvent(self, protocol, log, .resolver_update, domain_name, namehash, event_data);
}

/// Handle DNSRecordDeleted event (ENSIP-17)
/// DNSRecordDeleted(bytes32 indexed node, bytes name, uint16 resource)
pub fn handleDnsRecordDeleted(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    if (log.topics.len < 2) return error.InvalidTopicCount;
    var namehash = log.topics[1];

    const data_values = try abi.decodeValues(log.data, &.{ .bytes, .uint16 }, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const dns_name_bytes = data_values[0].bytes;
    const resource: u16 = @truncate(data_values[1].uint256);

    if (!try utils.resolveNamehash(self, &namehash, resolver, "DNSRecordDeleted")) return;

    const dns_name_hex = try bytesToHexAlloc(self.allocator, dns_name_bytes);
    defer self.allocator.free(dns_name_hex);

    self.database.deleteResolverDnsRecord(protocol, namehash, resolver, dns_name_hex, resource) catch |err| {
        std.log.warn("Failed to delete resolver DNS record: {}", .{err});
    };

    const nh_hex = try namehash.toHex(self.allocator);
    defer self.allocator.free(nh_hex);
    const resolver_hex = try resolver.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);

    const event_data = try std.fmt.allocPrint(
        self.allocator,
        "{{\"namehash\":\"{s}\",\"resolver\":\"{s}\",\"dnsName\":\"{s}\",\"resource\":{d}}}",
        .{ nh_hex, resolver_hex, dns_name_hex, resource },
    );

    const domain_name = self.getNameFromNamehash(namehash);
    try utils.emitEvent(self, protocol, log, .resolver_update, domain_name, namehash, event_data);
}

/// Handle DNSZonehashChanged event (ENSIP-17)
/// DNSZonehashChanged(bytes32 indexed node, bytes lastzonehash, bytes zonehash)
pub fn handleDnsZonehashChanged(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    if (log.topics.len < 2) return error.InvalidTopicCount;
    var namehash = log.topics[1];

    const data_values = try abi.decodeValues(log.data, &.{ .bytes, .bytes }, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const last_zonehash_bytes = data_values[0].bytes;
    const zonehash_bytes = data_values[1].bytes;

    if (!try utils.resolveNamehash(self, &namehash, resolver, "DNSZonehashChanged")) return;

    const last_hex = try bytesToHexAlloc(self.allocator, last_zonehash_bytes);
    defer self.allocator.free(last_hex);
    const zone_hex = try bytesToHexAlloc(self.allocator, zonehash_bytes);
    defer self.allocator.free(zone_hex);

    self.database.storeResolverDnsZonehash(
        protocol,
        namehash,
        resolver,
        zone_hex,
        last_hex,
        log.block_number,
        log.transaction_hash,
        log.log_index,
        try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
    ) catch |err| {
        std.log.warn("Failed to store resolver DNS zonehash: {}", .{err});
    };

    const nh_hex = try namehash.toHex(self.allocator);
    defer self.allocator.free(nh_hex);
    const resolver_hex = try resolver.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);

    const event_data = try std.fmt.allocPrint(
        self.allocator,
        "{{\"namehash\":\"{s}\",\"resolver\":\"{s}\",\"lastZonehash\":\"{s}\",\"zonehash\":\"{s}\"}}",
        .{ nh_hex, resolver_hex, last_hex, zone_hex },
    );

    const domain_name = self.getNameFromNamehash(namehash);
    try utils.emitEvent(self, protocol, log, .resolver_update, domain_name, namehash, event_data);
}

/// Handle ABIChanged event
/// ABIChanged(bytes32 indexed node, uint256 indexed contentType)
pub fn handleABIChanged(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    // topics[2] = indexed contentType
    if (log.topics.len < 3) return error.InvalidTopicCount;
    var namehash = log.topics[1];
    const content_type = try abi.ABI.decodeUint256(&log.topics[2].bytes, 0);

    if (!try utils.resolveNamehash(self, &namehash, resolver, "ABIChanged")) return;

    const nh_hex_log = try namehash.toHex(self.allocator);
    defer self.allocator.free(nh_hex_log);
    std.log.debug("ABIChanged: namehash={s} contentType={d}", .{
        nh_hex_log,
        content_type,
    });

    // Store event and trigger webhooks
    const nh_hex = try namehash.toHex(self.allocator);
    defer self.allocator.free(nh_hex);
    const resolver_hex = try resolver.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);

    // Store ABI record in database
    self.database.storeResolverABI(
        namehash,
        resolver,
        @truncate(content_type),
        protocol,
        log.block_number,
        log.transaction_hash,
        try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
    ) catch |err| {
        std.log.warn("Failed to store resolver ABI: {}", .{err});
    };

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"namehash\":\"{s}\",\"resolver\":\"{s}\",\"contentType\":{d}}}", .{
        nh_hex,
        resolver_hex,
        content_type,
    });

    // Look up domain name from namehash
    const domain_name = self.getNameFromNamehash(namehash);

    try utils.emitEvent(self, protocol, log, .abi_changed, domain_name, namehash, event_data);
}

/// Handle PubkeyChanged event
/// PubkeyChanged(bytes32 indexed node, bytes32 x, bytes32 y)
pub fn handlePubkeyChanged(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    var namehash = log.topics[1];

    if (!try utils.resolveNamehash(self, &namehash, resolver, "PubkeyChanged")) return;

    // Non-indexed payload: (bytes32 x, bytes32 y)
    const data_values = try abi.decodeValues(log.data, &.{ .bytes32, .bytes32 }, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const x = Hash{ .bytes = data_values[0].fixed_bytes.data };
    const y = Hash{ .bytes = data_values[1].fixed_bytes.data };

    const nh_hex_log = try namehash.toHex(self.allocator);
    defer self.allocator.free(nh_hex_log);
    const x_hex_log = try x.toHex(self.allocator);
    defer self.allocator.free(x_hex_log);
    const y_hex_log = try y.toHex(self.allocator);
    defer self.allocator.free(y_hex_log);
    std.log.debug("PubkeyChanged: namehash={s} x={s} y={s}", .{
        nh_hex_log,
        x_hex_log,
        y_hex_log,
    });

    // Store event and trigger webhooks
    const nh_hex = try namehash.toHex(self.allocator);
    defer self.allocator.free(nh_hex);
    const resolver_hex = try resolver.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);
    const x_hex = try x.toHex(self.allocator);
    defer self.allocator.free(x_hex);
    const y_hex = try y.toHex(self.allocator);
    defer self.allocator.free(y_hex);

    // Store pubkey record in database
    self.database.storeResolverPubkey(
        namehash,
        resolver,
        x_hex,
        y_hex,
        protocol,
        log.block_number,
        log.transaction_hash,
        try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
    ) catch |err| {
        std.log.warn("Failed to store resolver pubkey: {}", .{err});
    };

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"namehash\":\"{s}\",\"resolver\":\"{s}\",\"x\":\"{s}\",\"y\":\"{s}\"}}", .{
        nh_hex,
        resolver_hex,
        x_hex,
        y_hex,
    });

    // Look up domain name from namehash
    const domain_name = self.getNameFromNamehash(namehash);

    try utils.emitEvent(self, protocol, log, .pubkey_changed, domain_name, namehash, event_data);
}

/// Handle NameChanged event (reverse resolution)
/// NameChanged(bytes32 indexed node, string name)
pub fn handleNameChanged(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    var namehash = log.topics[1];

    if (!try utils.resolveNamehash(self, &namehash, resolver, "NameChanged")) return;

    // Non-indexed payload: (string name)
    const data_values = try abi.decodeValues(log.data, &.{.string}, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const name = data_values[0].string;

    // Validate name is valid UTF-8
    unicode.validateString(name) catch |err| {
        std.log.warn("Invalid UTF-8 in reverse name: {any}", .{err});
        return;
    };

    const nh_hex_log = try namehash.toHex(self.allocator);
    defer self.allocator.free(nh_hex_log);
    std.log.debug("NameChanged: namehash={s} name={s}", .{
        nh_hex_log,
        name,
    });

    // Store event and trigger webhooks
    const nh_hex = try namehash.toHex(self.allocator);
    defer self.allocator.free(nh_hex);
    const resolver_hex = try resolver.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);

    // Escape name for safe JSON inclusion
    const escaped_name = try json_utils.escapeString(self.allocator, name);
    defer self.allocator.free(escaped_name);

    // Store name record in database (reverse resolution)
    self.database.storeResolverName(
        namehash,
        resolver,
        name,
        protocol,
        log.block_number,
        log.transaction_hash,
        try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
    ) catch |err| {
        std.log.warn("Failed to store resolver name: {}", .{err});
    };

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"namehash\":\"{s}\",\"resolver\":\"{s}\",\"name\":\"{s}\"}}", .{
        nh_hex,
        resolver_hex,
        escaped_name,
    });

    // Look up domain name from namehash
    const domain_name = self.getNameFromNamehash(namehash);

    try utils.emitEvent(self, protocol, log, .name_changed, domain_name, namehash, event_data);
}

/// Handle InterfaceChanged event
/// InterfaceChanged(bytes32 indexed node, bytes4 indexed interfaceID, address implementer)
pub fn handleInterfaceChanged(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    // topics[2] = indexed interfaceID (bytes4 padded to bytes32)
    if (log.topics.len < 3) return error.InvalidTopicCount;
    var namehash = log.topics[1];

    if (!try utils.resolveNamehash(self, &namehash, resolver, "InterfaceChanged")) return;

    // Interface ID is a bytes4, left-aligned (right-padded) in the 32-byte topic
    const interface_id_bytes = log.topics[2].bytes[0..4];

    // Non-indexed payload: (address implementer)
    const data_values = try abi.decodeValues(log.data, &.{.address}, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const implementer = Address{ .bytes = data_values[0].address };

    // Convert interface ID to hex string
    var interface_id_hex = try self.allocator.alloc(u8, 10); // "0x" + 8 hex chars
    defer self.allocator.free(interface_id_hex);
    interface_id_hex[0] = '0';
    interface_id_hex[1] = 'x';
    for (interface_id_bytes, 0..) |byte, i| {
        _ = try std.fmt.bufPrint(interface_id_hex[2 + i * 2 .. 4 + i * 2], "{x:0>2}", .{byte});
    }

    const nh_hex_log = try namehash.toHex(self.allocator);
    defer self.allocator.free(nh_hex_log);
    std.log.debug("InterfaceChanged: namehash={s} interfaceID={s} implementer={any}", .{
        nh_hex_log,
        interface_id_hex,
        implementer,
    });

    // Store event and trigger webhooks
    const nh_hex = try namehash.toHex(self.allocator);
    defer self.allocator.free(nh_hex);
    const resolver_hex = try resolver.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);
    const implementer_hex = try implementer.toHex(self.allocator);
    defer self.allocator.free(implementer_hex);

    // Store interface record in database
    self.database.storeResolverInterface(
        namehash,
        resolver,
        interface_id_hex,
        implementer_hex,
        protocol,
        log.block_number,
        log.transaction_hash,
        try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
    ) catch |err| {
        std.log.warn("Failed to store resolver interface: {}", .{err});
    };

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"namehash\":\"{s}\",\"resolver\":\"{s}\",\"interfaceID\":\"{s}\",\"implementer\":\"{s}\"}}", .{
        nh_hex,
        resolver_hex,
        interface_id_hex,
        implementer_hex,
    });

    // Look up domain name from namehash
    const domain_name = self.getNameFromNamehash(namehash);

    try utils.emitEvent(self, protocol, log, .interface_changed, domain_name, namehash, event_data);
}

/// Handle VersionChanged event (OwnedResolver)
/// VersionChanged(bytes32 indexed node, uint64 newVersion)
/// Clears all resolver records for the given namehash
pub fn handleVersionChanged(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    // data = newVersion (uint64, padded to 32 bytes)
    var namehash = log.topics[1];

    if (!try utils.resolveNamehash(self, &namehash, resolver, "VersionChanged")) return;

    // Non-indexed payload: (uint64 newVersion)
    var new_version: u64 = 0;
    if (log.data.len >= 32) {
        if (abi.decodeValues(log.data, &.{.uint64}, self.allocator)) |values| {
            defer abi.freeValues(values, self.allocator);
            new_version = @truncate(values[0].uint256);
        } else |_| {}
    }

    const nh_hex_log = try namehash.toHex(self.allocator);
    defer self.allocator.free(nh_hex_log);
    std.log.debug("VersionChanged: namehash={s} newVersion={d}", .{
        nh_hex_log,
        new_version,
    });

    // Clear all resolver records for this (resolver, namehash) pair only.
    // Scoping by resolver prevents wiping records owned by a different resolver
    // for the same name (e.g. resolver-A → resolver-B → resolver-A swap path).
    self.database.deleteResolverAddresses(protocol, namehash, resolver) catch |err| {
        std.log.warn("Failed to delete resolver addresses: {}", .{err});
    };
    self.database.deleteResolverContentHash(protocol, namehash, resolver) catch |err| {
        std.log.warn("Failed to delete resolver contenthash: {}", .{err});
    };
    self.database.deleteResolverTexts(protocol, namehash, resolver) catch |err| {
        std.log.warn("Failed to delete resolver texts: {}", .{err});
    };
    // Note: aliases are NOT versioned — they live in _storage().aliases, not _record(node).
    // So VersionChanged does NOT clear aliases.
    self.database.deleteResolverPubkeys(protocol, namehash, resolver) catch |err| {
        std.log.warn("Failed to delete resolver pubkeys: {}", .{err});
    };
    self.database.deleteResolverAbis(protocol, namehash, resolver) catch |err| {
        std.log.warn("Failed to delete resolver ABIs: {}", .{err});
    };
    self.database.deleteResolverNames(protocol, namehash, resolver) catch |err| {
        std.log.warn("Failed to delete resolver names: {}", .{err});
    };
    self.database.deleteResolverInterfaces(protocol, namehash, resolver) catch |err| {
        std.log.warn("Failed to delete resolver interfaces: {}", .{err});
    };

    // Store the new version
    self.database.storeResolverVersion(
        namehash,
        resolver,
        new_version,
        protocol,
        log.block_number,
        log.transaction_hash,
        try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
    ) catch |err| {
        std.log.warn("Failed to store resolver version: {}", .{err});
    };

    // Store event and trigger webhooks
    const nh_hex = try namehash.toHex(self.allocator);
    defer self.allocator.free(nh_hex);
    const resolver_hex = try resolver.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"namehash\":\"{s}\",\"resolver\":\"{s}\",\"newVersion\":{d}}}", .{
        nh_hex,
        resolver_hex,
        new_version,
    });

    const domain_name = self.getNameFromNamehash(namehash);

    try utils.emitEvent(self, protocol, log, .version_changed, domain_name, namehash, event_data);
}

/// Handle AliasChanged event (OwnedResolver)
/// AliasChanged(bytes indexed indexedFromName, bytes indexed indexedToName, bytes fromName, bytes toName)
pub fn handleAliasChanged(self: *Indexer, protocol: models.Protocol, resolver: Address, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = keccak256(fromName) — indexed bytes are hashed, not directly useful
    // topics[2] = keccak256(toName) — indexed bytes are hashed, not directly useful
    // data = ABI-encoded (bytes fromName, bytes toName)

    // Non-indexed payload: (bytes fromName, bytes toName)
    const data_values = abi.decodeValues(log.data, &.{ .bytes, .bytes }, self.allocator) catch |err| {
        std.log.warn("AliasChanged: failed to decode payload: {}", .{err});
        return;
    };
    defer abi.freeValues(data_values, self.allocator);
    const from_dns_bytes = data_values[0].bytes;
    const to_dns_bytes = data_values[1].bytes;

    // Decode DNS wire format to human-readable names
    const from_name = (try dns.decodeDNSNameToString(self.allocator, from_dns_bytes)) orelse {
        std.log.warn("AliasChanged: failed to decode fromName DNS wire format", .{});
        return;
    };
    defer self.allocator.free(from_name);

    const resolver_hex_log = try resolver.toHex(self.allocator);
    defer self.allocator.free(resolver_hex_log);

    // If toName is empty, the alias was removed
    if (to_dns_bytes.len == 0 or (to_dns_bytes.len == 1 and to_dns_bytes[0] == 0)) {
        std.log.debug("AliasChanged: resolver={s} removed alias for {s}", .{
            resolver_hex_log,
            from_name,
        });

        self.database.deleteResolverAlias(resolver, from_name) catch |err| {
            std.log.warn("Failed to delete resolver alias: {}", .{err});
        };
    } else {
        const to_name = (try dns.decodeDNSNameToString(self.allocator, to_dns_bytes)) orelse {
            std.log.warn("AliasChanged: failed to decode toName DNS wire format", .{});
            return;
        };
        defer self.allocator.free(to_name);

        std.log.debug("AliasChanged: resolver={s} alias {s} -> {s}", .{
            resolver_hex_log,
            from_name,
            to_name,
        });

        // Store in database
        self.database.storeResolverAlias(
            resolver,
            from_name,
            to_name,
            protocol,
            log.block_number,
            log.transaction_hash,
            try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
        ) catch |err| {
            std.log.warn("Failed to store resolver alias: {}", .{err});
        };
    }

    // Store event and trigger webhooks
    const resolver_hex = try resolver.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);

    const escaped_from = try json_utils.escapeString(self.allocator, from_name);
    defer self.allocator.free(escaped_from);

    // For event data, include raw toName even if empty
    const to_name_for_event = (try dns.decodeDNSNameToString(self.allocator, to_dns_bytes)) orelse
        try self.allocator.dupe(u8, "");
    defer self.allocator.free(to_name_for_event);

    const escaped_to = try json_utils.escapeString(self.allocator, to_name_for_event);
    defer self.allocator.free(escaped_to);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"resolver\":\"{s}\",\"fromName\":\"{s}\",\"toName\":\"{s}\"}}", .{
        resolver_hex,
        escaped_from,
        escaped_to,
    });

    try utils.emitEvent(self, protocol, log, .alias_changed, null, null, event_data);
}

/// Wrapper for EACRolesChanged from resolver contracts.
/// Adapts ResolverEventConfig signature to the shared handler, flagging it as a
/// resolver event so the indexed `resource` (keccak256(node, part), or ROOT 0) is
/// stored verbatim rather than canonicalized like a registry token id (WEB-511).
pub fn handleResolverEACRolesChanged(self: *Indexer, protocol: models.Protocol, _resolver: Address, log: rpc.Log) !void {
    _ = _resolver;
    try Indexer.handleEACRolesChangedImpl(self, protocol, log, true);
}
