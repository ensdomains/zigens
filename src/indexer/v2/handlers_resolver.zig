const std = @import("std");
const models = @import("../../types/models.zig");
const abi = @import("../abi.zig");
const rpc = @import("../../rpc/client.zig");
const Hash = @import("../../types/hash.zig").Hash;
const Address = @import("../../types/address.zig").Address;
const Indexer = @import("../indexer.zig").Indexer;
const utils = @import("../utils.zig");
const unicode = @import("../../utils/unicode.zig");
const json_utils = @import("../../utils/json.zig");

/// Handle legacy AddrChanged event (2017 Public Resolver)
/// AddrChanged(bytes32 indexed node, address a)
/// Stores as coinType=60 (ETH) to match modern AddressChanged format
pub fn handleLegacyAddrChanged(self: *Indexer, chain: models.Chain, resolver: Address, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    if (log.topics.len < 2) return error.InvalidTopicCount;
    var namehash = log.topics[1];

    // Decode address from data (20 bytes, left-padded to 32)
    const addr = try abi.ABI.decodeAddress(log.data, 0);

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
        chain,
        log.block_number,
        log.transaction_hash,
        std.time.timestamp(),
    );

    // Store event
    const nh_hex = try namehash.toHex(self.allocator);
    defer self.allocator.free(nh_hex);
    const resolver_hex = try resolver.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"namehash\":\"{s}\",\"resolver\":\"{s}\",\"coinType\":60,\"address\":\"{s}\"}}", .{
        nh_hex,
        resolver_hex,
        addr_hex,
    });

    const domain_name = self.getNameFromNamehash(namehash);
    try utils.emitEvent(self, chain, log, .address_changed, domain_name, namehash, event_data);
}

/// Handle legacy ContentChanged event (2017 Public Resolver)
/// ContentChanged(bytes32 indexed node, bytes32 hash)
/// Stores as hex-encoded content hash to match modern ContentHashChanged format
pub fn handleLegacyContentChanged(self: *Indexer, chain: models.Chain, resolver: Address, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    if (log.topics.len < 2) return error.InvalidTopicCount;
    var namehash = log.topics[1];

    // Decode bytes32 content hash from data
    const content_hash = try abi.ABI.decodeBytes32(log.data, 0);

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
        chain,
        log.block_number,
        log.transaction_hash,
        std.time.timestamp(),
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
    try utils.emitEvent(self, chain, log, .contenthash_changed, domain_name, namehash, event_data);
}

/// Handle AddressChanged event
/// AddressChanged(bytes32 indexed node, uint256 coinType, bytes newAddress)
pub fn handleAddressChanged(self: *Indexer, chain: models.Chain, resolver: Address, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    if (log.topics.len < 2) return error.InvalidTopicCount;
    var namehash = log.topics[1];

    // Decode coin type and address from data
    const coin_type = try abi.ABI.decodeUint256(log.data, 0);
    const address_bytes = try abi.ABI.decodeBytes(self.allocator, log.data, 32);
    defer self.allocator.free(address_bytes);

    // Convert address bytes to hex string
    var address_hex = try self.allocator.alloc(u8, 2 + address_bytes.len * 2);
    defer self.allocator.free(address_hex);
    address_hex[0] = '0';
    address_hex[1] = 'x';
    for (address_bytes, 0..) |byte, i| {
        _ = try std.fmt.bufPrint(address_hex[2 + i * 2 .. 4 + i * 2], "{x:0>2}", .{byte});
    }

    if (!try utils.resolveNamehash(self, &namehash, resolver, "AddressChanged")) return;

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
        @intCast(coin_type),
        address_hex,
        chain,
        log.block_number,
        log.transaction_hash,
        std.time.timestamp(),
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

    try utils.emitEvent(self, chain, log, .address_changed, domain_name, namehash, event_data);
}

/// Handle ContentHashChanged event
/// ContentHashChanged(bytes32 indexed node, bytes hash)
pub fn handleContentHashChanged(self: *Indexer, chain: models.Chain, resolver: Address, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    if (log.topics.len < 2) return error.InvalidTopicCount;
    var namehash = log.topics[1];

    // Decode content hash from data
    const content_hash_bytes = try abi.ABI.decodeBytes(self.allocator, log.data, 0);
    defer self.allocator.free(content_hash_bytes);

    // Convert to hex string
    var content_hash_hex = try self.allocator.alloc(u8, 2 + content_hash_bytes.len * 2);
    defer self.allocator.free(content_hash_hex);
    content_hash_hex[0] = '0';
    content_hash_hex[1] = 'x';
    for (content_hash_bytes, 0..) |byte, i| {
        _ = try std.fmt.bufPrint(content_hash_hex[2 + i * 2 .. 4 + i * 2], "{x:0>2}", .{byte});
    }

    if (!try utils.resolveNamehash(self, &namehash, resolver, "ContentHashChanged")) return;

    const nh_hex_log = try namehash.toHex(self.allocator);
    defer self.allocator.free(nh_hex_log);
    std.log.debug("ContentHashChanged: namehash={s} contentHash={s}", .{
        nh_hex_log,
        content_hash_hex,
    });

    // Store in database
    try self.database.storeResolverContentHash(
        namehash,
        resolver,
        content_hash_hex,
        chain,
        log.block_number,
        log.transaction_hash,
        std.time.timestamp(),
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

    try utils.emitEvent(self, chain, log, .contenthash_changed, domain_name, namehash, event_data);
}

/// Handle TextChanged event
/// TextChanged(bytes32 indexed node, string indexed indexedKey, string key, string value)
pub fn handleTextChanged(self: *Indexer, chain: models.Chain, resolver: Address, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    // topics[2] = indexed key (hashed, not useful)
    if (log.topics.len < 2) return error.InvalidTopicCount;
    var namehash = log.topics[1];

    // Decode key and value from data
    const key = try abi.ABI.decodeString(self.allocator, log.data, 0);
    defer self.allocator.free(key);

    const value = try abi.ABI.decodeString(self.allocator, log.data, 32);
    defer self.allocator.free(value);

    // Validate key and value are valid UTF-8 and contain no dangerous control characters
    unicode.validateString(key) catch |err| {
        std.log.warn("Invalid UTF-8 in text record key: {any}", .{err});
        return;
    };
    unicode.validateString(value) catch |err| {
        std.log.warn("Invalid UTF-8 in text record value: {any}", .{err});
        return;
    };

    if (!try utils.resolveNamehash(self, &namehash, resolver, "TextChanged")) return;

    const nh_hex_log = try namehash.toHex(self.allocator);
    defer self.allocator.free(nh_hex_log);
    std.log.debug("TextChanged: namehash={s} key={s} value={s}", .{
        nh_hex_log,
        key,
        value,
    });

    // Store in database
    try self.database.storeResolverText(
        namehash,
        resolver,
        key,
        value,
        chain,
        log.block_number,
        log.transaction_hash,
        std.time.timestamp(),
    );

    // Store event and trigger webhooks
    const nh_hex = try namehash.toHex(self.allocator);
    defer self.allocator.free(nh_hex);
    const resolver_hex = try resolver.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);

    // Escape key and value for safe JSON inclusion
    const escaped_key = try json_utils.escapeString(self.allocator, key);
    defer self.allocator.free(escaped_key);
    const escaped_value = try json_utils.escapeString(self.allocator, value);
    defer self.allocator.free(escaped_value);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"namehash\":\"{s}\",\"resolver\":\"{s}\",\"key\":\"{s}\",\"value\":\"{s}\"}}", .{
        nh_hex,
        resolver_hex,
        escaped_key,
        escaped_value,
    });

    // Look up domain name from namehash
    const domain_name = self.getNameFromNamehash(namehash);

    try utils.emitEvent(self, chain, log, .text_changed, domain_name, namehash, event_data);
}

/// Handle ABIChanged event
/// ABIChanged(bytes32 indexed node, uint256 indexed contentType)
pub fn handleABIChanged(self: *Indexer, chain: models.Chain, resolver: Address, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    // topics[2] = indexed contentType
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
        chain,
        log.block_number,
        log.transaction_hash,
        self.getBlockTimestamp(chain, log.block_number, log.block_timestamp),
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

    try utils.emitEvent(self, chain, log, .abi_changed, domain_name, namehash, event_data);
}

/// Handle PubkeyChanged event
/// PubkeyChanged(bytes32 indexed node, bytes32 x, bytes32 y)
pub fn handlePubkeyChanged(self: *Indexer, chain: models.Chain, resolver: Address, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    var namehash = log.topics[1];

    if (!try utils.resolveNamehash(self, &namehash, resolver, "PubkeyChanged")) return;

    // Data contains x and y coordinates (each 32 bytes)
    if (log.data.len < 64) return error.InsufficientData;

    const x = try abi.ABI.decodeBytes32(log.data, 0);
    const y = try abi.ABI.decodeBytes32(log.data, 32);

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
        chain,
        log.block_number,
        log.transaction_hash,
        self.getBlockTimestamp(chain, log.block_number, log.block_timestamp),
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

    try utils.emitEvent(self, chain, log, .pubkey_changed, domain_name, namehash, event_data);
}

/// Handle NameChanged event (reverse resolution)
/// NameChanged(bytes32 indexed node, string name)
pub fn handleNameChanged(self: *Indexer, chain: models.Chain, resolver: Address, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    var namehash = log.topics[1];

    if (!try utils.resolveNamehash(self, &namehash, resolver, "NameChanged")) return;

    // Decode name from data
    const name = try abi.ABI.decodeString(self.allocator, log.data, 0);
    defer self.allocator.free(name);

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
        chain,
        log.block_number,
        log.transaction_hash,
        self.getBlockTimestamp(chain, log.block_number, log.block_timestamp),
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

    try utils.emitEvent(self, chain, log, .name_changed, domain_name, namehash, event_data);
}

/// Handle InterfaceChanged event
/// InterfaceChanged(bytes32 indexed node, bytes4 indexed interfaceID, address implementer)
pub fn handleInterfaceChanged(self: *Indexer, chain: models.Chain, resolver: Address, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    // topics[2] = indexed interfaceID (bytes4 padded to bytes32)
    var namehash = log.topics[1];

    if (!try utils.resolveNamehash(self, &namehash, resolver, "InterfaceChanged")) return;

    // Interface ID is a bytes4, left-aligned (right-padded) in the 32-byte topic
    const interface_id_bytes = log.topics[2].bytes[0..4];

    // Decode implementer address from data
    const implementer = try abi.ABI.decodeAddress(log.data, 0);

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
        chain,
        log.block_number,
        log.transaction_hash,
        self.getBlockTimestamp(chain, log.block_number, log.block_timestamp),
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

    try utils.emitEvent(self, chain, log, .interface_changed, domain_name, namehash, event_data);
}

/// Handle VersionChanged event (OwnedResolver)
/// VersionChanged(bytes32 indexed node, uint64 newVersion)
/// Clears all resolver records for the given namehash
pub fn handleVersionChanged(self: *Indexer, chain: models.Chain, resolver: Address, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    // data = newVersion (uint64, padded to 32 bytes)
    var namehash = log.topics[1];

    if (!try utils.resolveNamehash(self, &namehash, resolver, "VersionChanged")) return;

    // Decode newVersion from data (uint64 encoded as uint256)
    var new_version: u64 = 0;
    if (log.data.len >= 32) {
        const version_u256 = abi.ABI.decodeUint256(log.data, 0) catch 0;
        new_version = @truncate(version_u256);
    }

    const nh_hex_log = try namehash.toHex(self.allocator);
    defer self.allocator.free(nh_hex_log);
    std.log.debug("VersionChanged: namehash={s} newVersion={d}", .{
        nh_hex_log,
        new_version,
    });

    // Clear all resolver records for this namehash
    self.database.deleteResolverAddresses(namehash) catch |err| {
        std.log.warn("Failed to delete resolver addresses: {}", .{err});
    };
    self.database.deleteResolverContentHash(namehash) catch |err| {
        std.log.warn("Failed to delete resolver contenthash: {}", .{err});
    };
    self.database.deleteResolverTexts(namehash) catch |err| {
        std.log.warn("Failed to delete resolver texts: {}", .{err});
    };
    // Note: aliases are NOT versioned — they live in _storage().aliases, not _record(node).
    // So VersionChanged does NOT clear aliases.
    self.database.deleteResolverPubkeys(namehash) catch |err| {
        std.log.warn("Failed to delete resolver pubkeys: {}", .{err});
    };
    self.database.deleteResolverAbis(namehash) catch |err| {
        std.log.warn("Failed to delete resolver ABIs: {}", .{err});
    };
    self.database.deleteResolverNames(namehash) catch |err| {
        std.log.warn("Failed to delete resolver names: {}", .{err});
    };
    self.database.deleteResolverInterfaces(namehash) catch |err| {
        std.log.warn("Failed to delete resolver interfaces: {}", .{err});
    };

    // Store the new version
    self.database.storeResolverVersion(
        namehash,
        resolver,
        new_version,
        chain,
        log.block_number,
        log.transaction_hash,
        self.getBlockTimestamp(chain, log.block_number, log.block_timestamp),
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

    try utils.emitEvent(self, chain, log, .version_changed, domain_name, namehash, event_data);
}

/// Handle AliasChanged event (OwnedResolver)
/// AliasChanged(bytes indexed indexedFromName, bytes indexed indexedToName, bytes fromName, bytes toName)
pub fn handleAliasChanged(self: *Indexer, chain: models.Chain, resolver: Address, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = keccak256(fromName) — indexed bytes are hashed, not directly useful
    // topics[2] = keccak256(toName) — indexed bytes are hashed, not directly useful
    // data = ABI-encoded (bytes fromName, bytes toName)

    // Decode fromName (first dynamic bytes in data)
    const from_dns_bytes = abi.ABI.decodeBytes(self.allocator, log.data, 0) catch |err| {
        std.log.warn("AliasChanged: failed to decode fromName bytes: {}", .{err});
        return;
    };
    defer self.allocator.free(from_dns_bytes);

    // Decode toName (second dynamic bytes in data)
    const to_dns_bytes = abi.ABI.decodeBytes(self.allocator, log.data, 32) catch |err| {
        std.log.warn("AliasChanged: failed to decode toName bytes: {}", .{err});
        return;
    };
    defer self.allocator.free(to_dns_bytes);

    // Decode DNS wire format to human-readable names
    const from_name = decodeDnsWireFormat(self.allocator, from_dns_bytes) catch |err| {
        std.log.warn("AliasChanged: failed to decode fromName DNS wire format: {}", .{err});
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
        const to_name = decodeDnsWireFormat(self.allocator, to_dns_bytes) catch |err| {
            std.log.warn("AliasChanged: failed to decode toName DNS wire format: {}", .{err});
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
            chain,
            log.block_number,
            log.transaction_hash,
            self.getBlockTimestamp(chain, log.block_number, log.block_timestamp),
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
    const to_name_for_event = decodeDnsWireFormat(self.allocator, to_dns_bytes) catch
        try self.allocator.dupe(u8, "");
    defer self.allocator.free(to_name_for_event);

    const escaped_to = try json_utils.escapeString(self.allocator, to_name_for_event);
    defer self.allocator.free(escaped_to);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"resolver\":\"{s}\",\"fromName\":\"{s}\",\"toName\":\"{s}\"}}", .{
        resolver_hex,
        escaped_from,
        escaped_to,
    });

    try utils.emitEvent(self, chain, log, .alias_changed, null, null, event_data);
}

/// Wrapper for EACRolesChanged from resolver contracts
/// Adapts ResolverEventConfig signature to call the existing RegistryEventConfig handler
pub fn handleResolverEACRolesChanged(self: *Indexer, chain: models.Chain, _resolver: Address, log: rpc.Log) !void {
    _ = _resolver;
    try Indexer.handleEACRolesChanged(self, chain, log);
}

/// Decode DNS wire format to human-readable domain name
/// e.g., \x03eth\x00 → "eth", \x05alice\x03eth\x00 → "alice.eth"
pub fn decodeDnsWireFormat(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    if (data.len == 0) return error.EmptyDnsData;

    var parts: std.ArrayList([]const u8) = .{};
    defer parts.deinit(allocator);

    var pos: usize = 0;
    while (pos < data.len) {
        const label_len = data[pos];
        if (label_len == 0) break; // Root label terminator

        pos += 1;
        if (pos + label_len > data.len) return error.InvalidDnsWireFormat;

        try parts.append(allocator, data[pos .. pos + label_len]);
        pos += label_len;
    }

    if (parts.items.len == 0) return error.EmptyDnsName;

    // Calculate total length: sum of labels + dots between them
    var total_len: usize = 0;
    for (parts.items) |part| {
        total_len += part.len;
    }
    total_len += parts.items.len - 1; // dots

    var result = try allocator.alloc(u8, total_len);
    var offset: usize = 0;
    for (parts.items, 0..) |part, i| {
        @memcpy(result[offset .. offset + part.len], part);
        offset += part.len;
        if (i < parts.items.len - 1) {
            result[offset] = '.';
            offset += 1;
        }
    }

    return result;
}
