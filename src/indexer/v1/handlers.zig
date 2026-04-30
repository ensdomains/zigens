const std = @import("std");
const constants = @import("../../constants.zig");
const models = @import("../../types/models.zig");
const abi = @import("../abi.zig");
const rpc = @import("../../rpc/client.zig");
const db = @import("../../storage/database.zig");
const Hash = @import("../../types/hash.zig").Hash;
const Address = @import("../../types/address.zig").Address;
const unknown_labels_storage = @import("../../storage/unknown_labels.zig");
const Indexer = @import("../indexer.zig").Indexer;
const utils = @import("../utils.zig");
const dns = @import("../../utils/dns.zig");
const names_storage = @import("../../storage/names.zig");
const v1_names = @import("../../utils/v1_names.zig");

/// Handle V1 ENS Registry NewOwner event
/// NewOwner(bytes32 indexed node, bytes32 indexed label, address owner)
/// This event is emitted when a subdomain is created
pub fn handleV1NewOwner(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    if (log.topics.len < 3) return error.InvalidTopicCount;
    if (log.data.len < 32) return error.InsufficientData;

    const parent_node = log.topics[1];
    const labelhash = log.topics[2];
    const owner = try abi.ABI.decodeAddress(log.data, 0);

    // Stack-based hex conversions (no heap allocation)
    var parent_buf: [66]u8 = undefined;
    const parent_hex = parent_node.toHexBuf(&parent_buf);
    var labelhash_buf: [66]u8 = undefined;
    const labelhash_hex = labelhash.toHexBuf(&labelhash_buf);
    var owner_buf: [42]u8 = undefined;
    const owner_hex = owner.toHexBuf(&owner_buf);

    // Compute the subdomain namehash: keccak256(parent_node + labelhash)
    var subdomain_input: [64]u8 = undefined;
    @memcpy(subdomain_input[0..32], &parent_node.bytes);
    @memcpy(subdomain_input[32..64], &labelhash.bytes);

    const Keccak256 = std.crypto.hash.sha3.Keccak256;
    var subdomain_namehash_bytes: [32]u8 = undefined;
    Keccak256.hash(&subdomain_input, &subdomain_namehash_bytes, .{});

    var subdomain_namehash: Hash = undefined;
    @memcpy(&subdomain_namehash.bytes, &subdomain_namehash_bytes);

    var subdomain_buf: [66]u8 = undefined;
    const subdomain_hex = subdomain_namehash.toHexBuf(&subdomain_buf);

    std.log.debug("V1 NewOwner: parent={s} labelhash={s} subdomain={s} owner={s}", .{
        parent_hex, labelhash_hex, subdomain_hex, owner_hex,
    });

    // V1 migration block - before this, we're in the temporary registrar period
    const v1_migration_block = self.config.v1_contracts.v1_migration_block;
    const is_pre_migration = v1_migration_block > 0 and log.block_number < v1_migration_block;

    if (is_pre_migration) {
        std.log.debug("Storing pre-migration NewOwner for backfill: namehash={s} labelhash={s}", .{ subdomain_hex, labelhash_hex });

        const Query = db.Query;
        var tx_buf: [66]u8 = undefined;
        const tx_hash_hex = log.transaction_hash.toHexBuf(&tx_buf);

        var q = try Query.initCached(self.database,
            \\INSERT OR IGNORE INTO temp_pre_migration_names
            \\(protocol, namehash, label_hash, parent_node, owner, block_number, tx_hash, log_index, created_at)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        );
        defer q.deinit();

        try q.bindTextStatic(@tagName(protocol));
        try q.bindTextStatic(subdomain_hex);
        try q.bindTextStatic(labelhash_hex);
        try q.bindTextStatic(parent_hex);
        try q.bindTextStatic(owner_hex);
        try q.bindInt64(@intCast(log.block_number));
        try q.bindTextStatic(tx_hash_hex);
        try q.bindInt64(@intCast(log.log_index));
        try q.bindInt64(std.time.timestamp());
        try q.exec();

        return;
    }

    // .eth 2LDs are handled by BaseRegistrar NameRegistered — skip
    if (parent_node.eql(constants.WellKnown.eth_namehash)) {
        std.log.debug("V1 NewOwner for .eth 2LD (skipping - handled by BaseRegistrar): labelhash={s}", .{labelhash_hex});
        return;
    }

    // Resolve the label using multiple strategies:
    // 1. addr.reverse: label = lowercase(owner_address)
    // 2. Rainbow table lookup
    // 3. Fallback to [labelhash] notation
    var resolved_label: ?[]const u8 = null;
    var label_is_allocated = false;
    defer if (label_is_allocated) {
        if (resolved_label) |l| self.allocator.free(l);
    };

    // Strategy 1: addr.reverse subnames — label is the lowercase address without "0x"
    if (parent_node.eql(constants.WellKnown.reverse_namehash)) {
        const addr_str = owner_hex[2..];
        var lower_addr: [40]u8 = undefined;
        for (addr_str, 0..) |ch, idx| {
            lower_addr[idx] = if (ch >= 'A' and ch <= 'F') ch + 32 else ch;
        }

        var hash_result: [32]u8 = undefined;
        Keccak256.hash(&lower_addr, &hash_result, .{});

        if (std.mem.eql(u8, &hash_result, &labelhash.bytes)) {
            resolved_label = try self.allocator.dupe(u8, &lower_addr);
            label_is_allocated = true;
        }
    }

    // Strategy 2: Rainbow table lookup
    if (resolved_label == null) {
        if (self.resolveLabel(labelhash)) |rainbow_label| {
            resolved_label = rainbow_label;
            label_is_allocated = true;
        }
    }

    // Build the label string (resolved or [labelhash] notation)
    // labelhash_hex is "0x..." — strip the "0x" prefix for bracket notation
    var label_buf: [66]u8 = undefined; // "[" + 64 hex + "]"
    const label_str = if (resolved_label) |l| l else blk: {
        label_buf[0] = '[';
        @memcpy(label_buf[1..65], labelhash_hex[2..66]);
        label_buf[65] = ']';
        break :blk label_buf[0..66];
    };

    // Look up parent name to construct full name
    var parent_name_str: ?[]const u8 = null;
    var parent_record_to_free: ?models.Name = null;
    defer if (parent_record_to_free) |*pr| pr.deinit(self.allocator);

    if (parent_node.eql(constants.WellKnown.root_namehash)) {
        // TLD: parent is root, no suffix needed
        parent_name_str = null;
    } else if (try names_storage.getNameByNamehash(self.database, parent_node)) |parent_record| {
        parent_record_to_free = parent_record;
        parent_name_str = parent_record.name;
    }

    // Construct the full name
    const full_name = if (parent_name_str) |pn|
        try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ label_str, pn })
    else
        try self.allocator.dupe(u8, label_str);
    defer self.allocator.free(full_name);

    std.log.debug("V1 NewOwner subdomain: {s} (namehash={s})", .{ full_name, subdomain_hex });

    // Create or update the name record
    const registry = try Address.fromHex("00000000000C2E074eC69A0dFb2997BA6C7d2e1e");
    const now = std.time.timestamp();

    if (try names_storage.getNameByNamehash(self.database, subdomain_namehash)) |existing| {
        // Name already exists — update owner
        var existing_mut = existing;
        existing_mut.deinit(self.allocator);
        try names_storage.updateNameOwner(self.database, subdomain_namehash, owner);
    } else {
        // Create new name record
        const name_copy = try self.allocator.dupe(u8, full_name);
        const label_copy = try self.allocator.dupe(u8, label_str);
        const parent_copy = if (parent_name_str) |pn| try self.allocator.dupe(u8, pn) else null;

        // V1 names have no version bits — use the namehash as canonical_id so each
        // V1 row has a unique identifier. The previous code wrote canonical_id=0
        // for every V1 subdomain, making canonical_id-based lookups ambiguous
        // (any of N V1 names matched).
        const v1_canonical_id = std.mem.readInt(u256, &subdomain_namehash.bytes, .big);

        var name = models.Name{
            .protocol = protocol,
            .name = name_copy,
            .namehash = subdomain_namehash,
            .label = label_copy,
            .label_hash = labelhash,
            .parent_name = parent_copy,
            .parent_namehash = parent_node,
            .registry = registry,
            .owner = owner,
            .registrant = owner,
            .resolver = Address.zero,
            .token_id = 0,
            .canonical_id = v1_canonical_id,
            .token_version = 0,
            .expiry = 0,
            .registry_locked = false,
            .migrated = false,
            .created_block = log.block_number,
            .created_at = now,
            .registered_at = now,
            .updated_block = log.block_number,
            .updated_at = now,
            .is_wrapped = false,
            .wrapper_fuses = null,
            .wrapper_expiry = null,
            .is_v1_name = true,
            .v1_label_hash = null,
        };
        defer name.deinit(self.allocator);

        names_storage.insertName(self.database, name) catch |err| {
            std.log.warn("Failed to create subdomain name {s}: {}", .{ full_name, err });
        };
    }

    // Still record unresolved labels for backfill (calldata decoding may find them later)
    if (resolved_label == null) {
        unknown_labels_storage.insertUnknownLabel(
            self.database.db.?,
            null,
            log.transaction_hash,
            labelhash,
            subdomain_namehash,
            parent_node,
            owner,
            log.block_number,
        ) catch |err| {
            std.log.debug("Failed to insert unknown label: {}", .{err});
        };
    }

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"parentNode\":\"{s}\",\"labelhash\":\"{s}\",\"subdomain\":\"{s}\",\"owner\":\"{s}\"}}", .{
        parent_hex, labelhash_hex, subdomain_hex, owner_hex,
    });

    try utils.emitEvent(self, protocol, log, .transfer, null, subdomain_namehash, event_data);
}

/// Handle V1 ENS Registry Transfer event
/// Transfer(bytes32 indexed node, address owner)
pub fn handleV1RegistryTransfer(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    if (log.topics.len < 2) return error.InvalidTopicCount;
    if (log.data.len < 32) return error.InsufficientData;

    const node = log.topics[1];
    const owner = try abi.ABI.decodeAddress(log.data, 0);

    var node_buf: [66]u8 = undefined;
    const node_hex = node.toHexBuf(&node_buf);
    var owner_buf: [42]u8 = undefined;
    const owner_hex = owner.toHexBuf(&owner_buf);

    std.log.debug("V1 RegistryTransfer: node={s} owner={s}", .{ node_hex, owner_hex });

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"node\":\"{s}\",\"owner\":\"{s}\"}}", .{
        node_hex, owner_hex,
    });

    try utils.emitEvent(self, protocol, log, .transfer, null, node, event_data);
}

/// Handle V1 ENS Registry NewResolver event
/// NewResolver(bytes32 indexed node, address resolver)
pub fn handleV1NewResolver(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    if (log.topics.len < 2) return error.InvalidTopicCount;
    if (log.data.len < 32) return error.InsufficientData;

    const node = log.topics[1];
    const resolver = try abi.ABI.decodeAddress(log.data, 0);

    var node_buf: [66]u8 = undefined;
    const node_hex = node.toHexBuf(&node_buf);
    var resolver_buf: [42]u8 = undefined;
    const resolver_hex = resolver.toHexBuf(&resolver_buf);

    std.log.debug("V1 NewResolver: node={s} resolver={s}", .{ node_hex, resolver_hex });

    if (self.write_buffer.active) {
        try self.write_buffer.updateNameResolver(node, resolver);
    } else {
        try names_storage.updateNameResolver(self.database, node, resolver);
    }
    try self.database.registerResolver(protocol, resolver_hex, log.block_number);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"node\":\"{s}\",\"resolver\":\"{s}\"}}", .{
        node_hex, resolver_hex,
    });

    try utils.emitEvent(self, protocol, log, .resolver_update, null, node, event_data);
}

/// Handle V1 ENS Registry NewTTL event
/// NewTTL(bytes32 indexed node, uint64 ttl)
pub fn handleV1NewTTL(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    if (log.topics.len < 2) return error.InvalidTopicCount;
    if (log.data.len < 32) return error.InsufficientData;

    const node = log.topics[1];
    const ttl_u256 = try abi.ABI.decodeUint256(log.data, 0);
    const ttl: u64 = @intCast(ttl_u256);

    var node_buf: [66]u8 = undefined;
    const node_hex = node.toHexBuf(&node_buf);

    std.log.debug("V1 NewTTL: node={s} ttl={d}", .{ node_hex, ttl });

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"node\":\"{s}\",\"ttl\":{d}}}", .{ node_hex, ttl });
    try utils.emitEvent(self, protocol, log, .resolver_update, null, node, event_data);
}

/// Handle V1 Name Wrapper NameWrapped event
/// NameWrapped(bytes32 indexed node, bytes name, address owner, uint32 fuses, uint64 expiry)
pub fn handleV1NameWrapped(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    if (log.topics.len < 2) return error.InvalidTopicCount;
    if (log.data.len < 128) return error.InsufficientData;

    const node = log.topics[1];

    // Decode name (bytes - dynamic length)
    const name_bytes = try abi.ABI.decodeBytes(self.allocator, log.data, 0);
    defer self.allocator.free(name_bytes);

    // Decode owner address (word 1, offset 32)
    const owner = try abi.ABI.decodeAddress(log.data, 32);

    // Decode fuses (uint32, word 2, offset 64)
    const fuses_u256 = try abi.ABI.decodeUint256(log.data, 64);
    const fuses: u32 = @intCast(fuses_u256);

    // Decode expiry (uint64, word 3, offset 96)
    const expiry_u256 = try abi.ABI.decodeUint256(log.data, 96);
    const expiry: u64 = @truncate(expiry_u256);

    var node_buf: [66]u8 = undefined;
    const node_hex = node.toHexBuf(&node_buf);
    var owner_buf: [42]u8 = undefined;
    const owner_hex = owner.toHexBuf(&owner_buf);

    std.log.debug("V1 NameWrapped: node={s} owner={s} fuses={d} expiry={d}", .{ node_hex, owner_hex, fuses, expiry });

    if (self.write_buffer.active) {
        try self.write_buffer.updateNameWrapperState(node, fuses, expiry);
        try self.write_buffer.updateNameOwner(node, owner);
    } else {
        try names_storage.updateNameWrapperState(self.database, node, fuses, expiry);
        try names_storage.updateNameOwner(self.database, node, owner);
    }

    // Heal labels from DNS-encoded name (e.g., \x03sub\x07vitalik\x03eth\x00 → "sub.vitalik.eth")
    // The NameWrapped event contains the full plaintext name — use it to resolve unknown labels.
    healLabelsFromDNSName(self, name_bytes, node, log.block_number) catch |err| {
        std.log.debug("DNS label heal failed for node={s}: {}", .{ node_hex, err });
    };

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"node\":\"{s}\",\"owner\":\"{s}\",\"fuses\":{d},\"expiry\":{d}}}", .{
        node_hex, owner_hex, fuses, expiry,
    });

    try utils.emitEvent(self, protocol, log, .transfer, null, node, event_data);
}

/// Handle V1 Name Wrapper NameUnwrapped event
/// NameUnwrapped(bytes32 indexed node, address owner)
pub fn handleV1NameUnwrapped(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    if (log.topics.len < 2) return error.InvalidTopicCount;
    if (log.data.len < 32) return error.InsufficientData;

    const node = log.topics[1];

    // Decode owner address from data
    const owner = try abi.ABI.decodeAddress(log.data, 0);

    var node_buf: [66]u8 = undefined;
    const node_hex = node.toHexBuf(&node_buf);
    var owner_buf: [42]u8 = undefined;
    const owner_hex = owner.toHexBuf(&owner_buf);

    std.log.debug("V1 NameUnwrapped: node={s} owner={s}", .{ node_hex, owner_hex });

    if (self.write_buffer.active) {
        try self.write_buffer.clearNameWrapperState(node);
        try self.write_buffer.updateNameOwner(node, owner);
    } else {
        try names_storage.updateNameUnwrapperState(self.database, node);
        try names_storage.updateNameOwner(self.database, node, owner);
    }

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"node\":\"{s}\",\"owner\":\"{s}\"}}", .{
        node_hex, owner_hex,
    });

    try utils.emitEvent(self, protocol, log, .transfer, null, node, event_data);
}

/// Handle V1 Name Wrapper FusesSet event
/// FusesSet(bytes32 indexed node, uint32 fuses)
pub fn handleV1FusesSet(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    if (log.topics.len < 2) return error.InvalidTopicCount;
    if (log.data.len < 32) return error.InsufficientData;

    const node = log.topics[1];

    // Decode fuses from data (uint32, but padded to 32 bytes)
    const fuses_u256 = try abi.ABI.decodeUint256(log.data, 0);
    const fuses: u32 = @intCast(fuses_u256);

    var node_buf: [66]u8 = undefined;
    const node_hex = node.toHexBuf(&node_buf);

    std.log.debug("V1 FusesSet: node={s} fuses={d}", .{ node_hex, fuses });

    // Update name wrapper fuses
    if (self.write_buffer.active) {
        try self.write_buffer.updateNameWrapperFuses(node, fuses);
    } else {
        try names_storage.updateNameWrapperFuses(self.database, node, fuses);
    }

    std.log.debug("Updated name wrapper fuses: node={s} fuses={d}", .{ node_hex, fuses });

    // Store event
    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"node\":\"{s}\",\"fuses\":{d}}}", .{
        node_hex,
        fuses,
    });

    try utils.emitEvent(self, protocol, log, .resolver_update, null, node, event_data);
}

/// Handle V1 Name Wrapper ExpiryExtended event
/// ExpiryExtended(bytes32 indexed node, uint64 expiry)
pub fn handleV1ExpiryExtended(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    if (log.topics.len < 2) return error.InvalidTopicCount;
    if (log.data.len < 32) return error.InsufficientData;

    const node = log.topics[1];

    // Decode expiry from data (uint64, but padded to 32 bytes)
    const expiry_u256 = try abi.ABI.decodeUint256(log.data, 0);
    const expiry: u64 = @truncate(expiry_u256);

    var node_buf: [66]u8 = undefined;
    const node_hex = node.toHexBuf(&node_buf);

    std.log.debug("V1 ExpiryExtended: node={s} expiry={d}", .{ node_hex, expiry });

    // Update name wrapper expiry
    if (self.write_buffer.active) {
        try self.write_buffer.updateNameWrapperExpiry(node, expiry);
    } else {
        try names_storage.updateNameWrapperExpiry(self.database, node, expiry);
    }

    std.log.debug("Updated name wrapper expiry: node={s} expiry={d}", .{ node_hex, expiry });

    // Store event
    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"node\":\"{s}\",\"expiry\":{d}}}", .{
        node_hex,
        expiry,
    });

    try utils.emitEvent(self, protocol, log, .name_renewed, null, node, event_data);
}

/// Handle V1 Base Registrar ERC721 Transfer event
/// Transfer(address indexed from, address indexed to, uint256 indexed tokenId)
pub fn handleV1ERC721Transfer(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {

    // names_storage imported at top level

    // topics[0] = event signature
    // topics[1] = indexed from
    // topics[2] = indexed to
    // topics[3] = indexed tokenId
    if (log.topics.len < 4) {
        std.log.warn("V1 ERC721 Transfer event has unexpected topic count: {d}, skipping", .{log.topics.len});
        return;
    }

    const from = try abi.ABI.decodeAddress(&log.topics[1].bytes, 0);
    const to = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);
    const token_id = try abi.ABI.decodeUint256(&log.topics[3].bytes, 0);

    var from_buf: [42]u8 = undefined;
    const from_hex = from.toHexBuf(&from_buf);
    var to_buf: [42]u8 = undefined;
    const to_hex = to.toHexBuf(&to_buf);

    std.log.debug("V1 ERC721 Transfer: from={s} to={s} tokenId={d}", .{ from_hex, to_hex, token_id });

    // Try to update the name's owner if we know the label
    // Convert token_id to hex for lookup
    const token_id_hex = try utils.tokenIdToHex(self.allocator, token_id);
    defer self.allocator.free(token_id_hex);

    // Detect V1 → V2 migration: a transfer to one of the V2 migration controllers
    // signals the V1 token is being migrated. We need to mark the V1 row migrated
    // (so the API can distinguish live V1 names from migrated ones) and emit a
    // distinct NameMigrated event so consumers don't conflate it with an ordinary
    // ownership transfer.
    const migration_kind = self.getMigrationKind(to);

    // Look up the label from cache (falls back to DB on miss)
    if (try self.getCachedV1Label(token_id_hex)) |label| {
        // Compute the namehash for this name
        const namehash = v1_names.computeEthNamehash(label);

        if (migration_kind != .none) {
            // V1→V2 migration: mark the V1 row as migrated and update owner to the
            // controller. Don't lose the prior owner — it's emitted in the event.
            if (self.write_buffer.active) {
                try self.write_buffer.markNameMigrated(namehash, to);
            } else {
                try names_storage.markNameMigrated(self.database, namehash, to);
            }
            // Debug-level: a Sepolia sync produces thousands of these.
            std.log.debug("V1 → V2 migration detected: {s}.eth → {s} controller (to={s})", .{
                label,
                if (migration_kind == .locked) "LOCKED" else "UNLOCKED",
                to_hex,
            });
        } else {
            // Update the name's owner (normal transfer)
            if (self.write_buffer.active) {
                try self.write_buffer.updateNameOwner(namehash, to);
            } else {
                try names_storage.updateNameOwner(self.database, namehash, to);
            }
            std.log.debug("Updated V1 name ownership: {s}.eth -> {s}", .{ label, to_hex });
        }
    } else {
        // This is expected - not all transfers correspond to known names
        // (e.g., the name might have been registered before we started indexing)
        std.log.debug("V1 Transfer for unknown tokenId {s}, event stored but name not updated", .{token_id_hex});
    }

    // Store event — use NameMigrated for migration transfers, plain Transfer otherwise.
    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"from\":\"{s}\",\"to\":\"{s}\",\"tokenId\":\"{d}\"{s}}}", .{
        from_hex,
        to_hex,
        token_id,
        switch (migration_kind) {
            .locked => ",\"migrationKind\":\"locked\"",
            .unlocked => ",\"migrationKind\":\"unlocked\"",
            .none => "",
        },
    });

    const ev_type: models.EventType = if (migration_kind != .none) .name_migrated else .transfer;
    try utils.emitEvent(self, protocol, log, ev_type, null, null, event_data);
}

/// Handle V1 Base Registrar NameRegistered event
/// NameRegistered(uint256 indexed id, address indexed owner, uint256 expires)
pub fn handleV1BaseRegistrarNameRegistered(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {

    // names_storage imported at top level

    // topics[0] = event signature
    // topics[1] = indexed id (tokenId)
    // topics[2] = indexed owner
    if (log.topics.len < 3) {
        std.log.warn("V1 BaseRegistrar NameRegistered event has unexpected topic count: {d}, skipping", .{log.topics.len});
        return;
    }
    if (log.data.len < 32) {
        std.log.warn("V1 BaseRegistrar NameRegistered event has insufficient data: {d} bytes, skipping", .{log.data.len});
        return;
    }

    const token_id = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
    const owner = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);

    // Decode expires from data
    const expires = try abi.ABI.decodeUint256(log.data, 0);

    var owner_buf: [42]u8 = undefined;
    const owner_hex = owner.toHexBuf(&owner_buf);

    // Convert tokenID to hex for label lookup (big-endian byte order)
    const token_id_hex = try utils.tokenIdToHex(self.allocator, token_id);
    defer self.allocator.free(token_id_hex);

    // Try to look up the label from cache (falls back to DB on miss)
    const maybe_label = try self.getCachedV1Label(token_id_hex);

    if (maybe_label) |label| {
        // label is owned by the cache, do not free

        // We have the label! Create a complete name record
        const full_name = try std.fmt.allocPrint(self.allocator, "{s}.eth", .{label});
        // Note: full_name is freed by insertEventAndNotify, not here

        const namehash = v1_names.computeEthNamehash(label);
        const label_hash = blk: { // tokenID IS the label hash in V1
            var bytes: [32]u8 = undefined;
            std.mem.writeInt(u256, &bytes, token_id, .big);
            break :blk Hash{ .bytes = bytes };
        };

        // Compute parent namehash ("eth")
        const eth_node = v1_names.computeEthNamehash("");

        std.log.debug("V1 BaseRegistrar NameRegistered: {s} (id={s}) owner={s} expires={d}", .{
            full_name,
            token_id_hex,
            owner_hex,
            expires,
        });

        // Stack-based v1_label_hash hex
        var label_hash_buf: [66]u8 = undefined;
        const v1_label_hash_hex = label_hash.toHexBuf(&label_hash_buf);

        // Create name record
        const name_record = models.Name{
            .name = full_name,
            .namehash = namehash,
            .label = label,
            .label_hash = label_hash,
            .parent_name = "eth",
            .parent_namehash = eth_node,
            .protocol = protocol,
            .registry = self.config.v1_contracts.ens_registry, // ENS Registry, not Base Registrar!
            .owner = owner,
            .registrant = owner, // Original registrant from V1 NameRegistered
            .resolver = Address.zero, // Will be updated when resolver is set
            .token_id = token_id,
            .canonical_id = token_id, // V1 doesn't use versioning
            .token_version = 0,
            .expiry = @truncate(expires),
            .registry_locked = false, // V1 names don't have registry locking
            .migrated = false, // This is a native V1 name
            .created_block = log.block_number,
            .created_at = self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
            .registered_at = self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
            .updated_block = log.block_number,
            .updated_at = std.time.timestamp(),
            .is_wrapped = false, // Not wrapped initially
            .wrapper_fuses = null,
            .wrapper_expiry = null,
            .is_v1_name = true, // This is a V1 .eth name
            .v1_label_hash = v1_label_hash_hex,
        };

        if (self.write_buffer.active) {
            try self.write_buffer.insertName(name_record);
        } else {
            try names_storage.insertName(self.database, name_record);
        }

        // Store event with name and namehash
        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"id\":\"{s}\",\"name\":\"{s}\",\"owner\":\"{s}\",\"expires\":{d}}}", .{
            token_id_hex,
            full_name,
            owner_hex,
            expires,
        });

        try utils.emitEvent(self, protocol, log, .name_registered, full_name, namehash, event_data);
    } else {
        // Label not found yet - might come in a later ETH Controller event
        std.log.warn("V1 BaseRegistrar NameRegistered: tokenID {s} label not found (will store event only)", .{token_id_hex});

        // Store event without name/namehash
        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"id\":\"{s}\",\"owner\":\"{s}\",\"expires\":{d}}}", .{
            token_id_hex,
            owner_hex,
            expires,
        });

        try utils.emitEvent(self, protocol, log, .name_registered, null, null, event_data);
    }
}

/// Handle V1 Base Registrar NameRenewed event
/// NameRenewed(uint256 indexed id, uint256 expires)
pub fn handleV1BaseRegistrarNameRenewed(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {

    // names_storage imported at top level

    // topics[0] = event signature
    // topics[1] = indexed id (tokenId)
    if (log.topics.len < 2) return error.InvalidTopicCount;
    if (log.data.len < 32) return error.InsufficientData;

    const token_id = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);

    // Decode expires from data
    const expires = try abi.ABI.decodeUint256(log.data, 0);

    std.log.debug("V1 BaseRegistrar NameRenewed: id={d} expires={d}", .{ token_id, expires });

    // Try to update the name's expiry if we know the label
    // Convert token_id to hex for lookup
    const token_id_hex = try utils.tokenIdToHex(self.allocator, token_id);
    defer self.allocator.free(token_id_hex);

    // Look up the label from cache (falls back to DB on miss)
    if (try self.getCachedV1Label(token_id_hex)) |label| {
        // label is owned by the cache, do not free

        // Compute the namehash for this name
        const namehash = v1_names.computeEthNamehash(label);

        // Update the name's expiry
        if (self.write_buffer.active) {
            try self.write_buffer.updateNameExpiry(namehash, @truncate(expires));
        } else {
            try names_storage.updateNameExpiry(self.database, namehash, @truncate(expires));
        }

        const full_name = try std.fmt.allocPrint(self.allocator, "{s}.eth", .{label});
        defer self.allocator.free(full_name);

        std.log.debug("Updated V1 name expiry: {s} -> {d}", .{ full_name, expires });
    } else {
        // This is expected - not all renewals correspond to known names
        std.log.debug("V1 NameRenewed for unknown tokenId {s}, event stored but name not updated", .{token_id_hex});
    }

    // Store event
    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"id\":\"{d}\",\"expires\":{d}}}", .{
        token_id,
        expires,
    });

    try utils.emitEvent(self, protocol, log, .name_renewed, null, null, event_data);
}

/// Handle V1 Base Registrar ControllerAdded event
/// ControllerAdded(address indexed controller)
pub fn handleV1ControllerAdded(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    _ = protocol; // Controller events are operational only, not stored as user-facing events
    const v1_controllers = @import("../../storage/v1_controllers.zig");

    // topics[0] = event signature
    // topics[1] = indexed controller address
    if (log.topics.len < 2) {
        std.log.warn("V1 ControllerAdded event has unexpected topic count: {d}, skipping", .{log.topics.len});
        return;
    }

    const controller = try abi.ABI.decodeAddress(&log.topics[1].bytes, 0);
    var controller_buf: [42]u8 = undefined;
    const controller_hex = controller.toHexBuf(&controller_buf);

    var tx_buf: [66]u8 = undefined;
    const tx_hash_hex = log.transaction_hash.toHexBuf(&tx_buf);

    std.log.debug("V1 ControllerAdded: controller={s} at block {d}", .{ controller_hex, log.block_number });

    // Store in v1_controllers table (this is purely for operational tracking of which contracts to index)
    try v1_controllers.addController(self.database, controller, log.block_number, tx_hash_hex);

    // Invalidate cached controllers so next access reloads from DB
    self.invalidateControllerCache();
}

/// Handle V1 Base Registrar ControllerRemoved event
/// ControllerRemoved(address indexed controller)
pub fn handleV1ControllerRemoved(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    _ = protocol; // Controller events are operational only, not stored as user-facing events
    const v1_controllers = @import("../../storage/v1_controllers.zig");

    // topics[0] = event signature
    // topics[1] = indexed controller address
    if (log.topics.len < 2) {
        std.log.warn("V1 ControllerRemoved event has unexpected topic count: {d}, skipping", .{log.topics.len});
        return;
    }

    const controller = try abi.ABI.decodeAddress(&log.topics[1].bytes, 0);
    var controller_buf: [42]u8 = undefined;
    const controller_hex = controller.toHexBuf(&controller_buf);

    var tx_buf: [66]u8 = undefined;
    const tx_hash_hex = log.transaction_hash.toHexBuf(&tx_buf);

    std.log.debug("V1 ControllerRemoved: controller={s} at block {d}", .{ controller_hex, log.block_number });

    // Update in v1_controllers table (this is purely for operational tracking of which contracts to index)
    try v1_controllers.removeController(self.database, controller, log.block_number, tx_hash_hex);

    // Invalidate cached controllers so next access reloads from DB
    self.invalidateControllerCache();
}

/// Handle V1 ETH Registrar Controller NameRegistered event
/// NameRegistered(string name, bytes32 indexed label, address indexed owner, uint256 baseCost, uint256 premium, uint256 expires)
pub fn handleV1ETHControllerNameRegistered(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {

    // topics[0] = event signature
    // topics[1] = indexed label (bytes32)
    // topics[2] = indexed owner (address)
    if (log.topics.len < 3) {
        std.log.warn("V1 ETH Controller NameRegistered event has unexpected topic count: {d}, skipping", .{log.topics.len});
        return;
    }

    const label_hash = log.topics[1];
    const owner = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);

    // Decode data: name (string), cost (uint256), expires (uint256)
    // Note: V1 Controller has only 2 non-indexed parameters (cost, expires), NOT 3
    // Note: name ownership is transferred to the Event struct, so don't free it here
    // name is a dynamic type, so it starts with an offset pointer
    const name = try abi.ABI.decodeString(self.allocator, log.data, 0);

    // cost, expires are after the string data
    // Skip to second word for cost (after string offset pointer and string data)
    var offset: usize = 32; // Skip string offset
    const str_len_offset = try abi.ABI.decodeUint256(log.data, 0);
    offset = @intCast(str_len_offset + 32 + ((name.len + 31) / 32) * 32); // String length + padded string data

    const cost = if (offset < log.data.len) try abi.ABI.decodeUint256(log.data, offset) else 0;
    offset += 32;
    const expires = if (offset < log.data.len) try abi.ABI.decodeUint256(log.data, offset) else 0;

    var owner_buf: [42]u8 = undefined;
    const owner_hex = owner.toHexBuf(&owner_buf);

    var label_hash_buf: [66]u8 = undefined;
    const label_hash_hex = label_hash.toHexBuf(&label_hash_buf);

    std.log.debug("V1 ETH Controller NameRegistered: name={s} label_hash={s} owner={s} expires={d}", .{
        name,
        label_hash_hex,
        owner_hex,
        expires,
    });

    // Store the tokenID->label mapping in the v1_labels table
    const namehash = v1_names.computeEthNamehash(name);
    var tx_buf: [66]u8 = undefined;
    const tx_hash_hex = log.transaction_hash.toHexBuf(&tx_buf);

    try v1_names.storeTokenIdLabel(
        self.allocator,
        self.database,
        label_hash_hex,
        name,
        namehash,
        log.block_number,
        tx_hash_hex,
        models.EventType.name_registered.toString(),
    );

    // Populate the in-memory label cache
    try self.putCachedV1Label(label_hash_hex, name);

    // Store event
    const event_data = try std.fmt.allocPrint(
        self.allocator,
        "{{\"name\":\"{s}\",\"label\":\"{s}\",\"owner\":\"{s}\",\"cost\":{d},\"expires\":{d}}}",
        .{ name, label_hash_hex, owner_hex, cost, expires },
    );

    try utils.emitEvent(self, protocol, log, .name_registered, name, namehash, event_data);
}

/// Handle V1 ETH Registrar Controller NameRenewed event
/// NameRenewed(string name, bytes32 indexed label, uint256 cost, uint256 expires)
pub fn handleV1ETHControllerNameRenewed(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {

    // topics[0] = event signature
    // topics[1] = indexed label (bytes32)
    if (log.topics.len < 2) {
        std.log.warn("V1 ETH Controller NameRenewed event has unexpected topic count: {d}, skipping", .{log.topics.len});
        return;
    }

    const label_hash = log.topics[1];

    // Decode data: name (string), cost (uint256), expires (uint256)
    // Note: name ownership is transferred to the Event struct, so don't free it here
    const name = try abi.ABI.decodeString(self.allocator, log.data, 0);

    // cost and expires are after the string data
    var offset: usize = 32; // Skip string offset
    const str_len_offset = try abi.ABI.decodeUint256(log.data, 0);
    offset = @intCast(str_len_offset + 32 + ((name.len + 31) / 32) * 32);

    const cost = if (offset < log.data.len) try abi.ABI.decodeUint256(log.data, offset) else 0;
    offset += 32;
    const expires = if (offset < log.data.len) try abi.ABI.decodeUint256(log.data, offset) else 0;

    var label_hash_buf: [66]u8 = undefined;
    const label_hash_hex = label_hash.toHexBuf(&label_hash_buf);

    std.log.debug("V1 ETH Controller NameRenewed: name={s} label_hash={s} cost={d} expires={d}", .{
        name,
        label_hash_hex,
        cost,
        expires,
    });

    // Store/update the tokenID->label mapping
    const namehash = v1_names.computeEthNamehash(name);
    var tx_buf: [66]u8 = undefined;
    const tx_hash_hex = log.transaction_hash.toHexBuf(&tx_buf);

    try v1_names.storeTokenIdLabel(
        self.allocator,
        self.database,
        label_hash_hex,
        name,
        namehash,
        log.block_number,
        tx_hash_hex,
        models.EventType.name_renewed.toString(),
    );

    // Populate the in-memory label cache
    try self.putCachedV1Label(label_hash_hex, name);

    // Store event
    const event_data = try std.fmt.allocPrint(
        self.allocator,
        "{{\"name\":\"{s}\",\"label\":\"{s}\",\"cost\":{d},\"expires\":{d}}}",
        .{ name, label_hash_hex, cost, expires },
    );

    try utils.emitEvent(self, protocol, log, .name_renewed, name, namehash, event_data);
}

/// Handle V1 Reverse Registrar ReverseClaimed event
/// ReverseClaimed(address indexed addr, bytes32 indexed node)
pub fn handleV1ReverseClaimed(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed addr
    // topics[2] = indexed node
    if (log.topics.len < 3) return error.InvalidTopicCount;

    const addr = try abi.ABI.decodeAddress(&log.topics[1].bytes, 0);
    const node = log.topics[2];

    var addr_buf: [42]u8 = undefined;
    const addr_hex = addr.toHexBuf(&addr_buf);
    var node_buf: [66]u8 = undefined;
    const node_hex = node.toHexBuf(&node_buf);

    std.log.debug("V1 ReverseClaimed: addr={s} node={s}", .{ addr_hex, node_hex });

    // Persist the address → reverse-node binding so primary-name lookups can be
    // answered by a point query rather than scanning the events feed. Note: this
    // does NOT prove forward resolution; consumers must round-trip via the
    // resolver's addr() to verify primary-name claims (per ENSIP-3).
    const block_timestamp = self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp);
    self.database.upsertReverseRecord(
        protocol,
        addr,
        node,
        log.block_number,
        log.transaction_hash,
        log.log_index,
        block_timestamp,
    ) catch |err| {
        std.log.warn("Failed to upsert V1 reverse record for {s}: {}", .{ addr_hex, err });
    };

    // Store event
    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"address\":\"{s}\",\"node\":\"{s}\"}}", .{
        addr_hex,
        node_hex,
    });

    try utils.emitEvent(self, protocol, log, .transfer, null, node, event_data);
}

// ============================================================================
// LABEL HEALING HELPERS
// ============================================================================

/// Extract labels from DNS-encoded name (from NameWrapped event) and heal names
/// that have unknown labels (stored as "[labelhash]").
///
/// DNS wire format: [len][label_bytes][len][label_bytes]...[0x00]
/// Example: \x03sub\x07vitalik\x03eth\x00 → labels: ["sub", "vitalik", "eth"]
///
/// We walk the label protocol and for each label, check if the corresponding name
/// record has an unresolved "[labelhash]" label. If so, heal it with the plaintext.
fn healLabelsFromDNSName(self: *Indexer, name_bytes: []const u8, wrapped_node: Hash, block_number: u64) !void {
    _ = block_number;

    const labels = dns.decodeDNSName(self.allocator, name_bytes) catch return;
    defer {
        for (labels) |l| self.allocator.free(l);
        self.allocator.free(labels);
    }

    if (labels.len == 0) return;

    // Build the full name string and update the wrapped node's name record
    const full_name = dns.decodeDNSNameToString(self.allocator, name_bytes) catch null;
    defer if (full_name) |n| self.allocator.free(n);

    if (full_name) |name_str| {
        // Try to heal the wrapped name itself — update label and name fields if missing
        if (try names_storage.getNameByNamehash(self.database, wrapped_node)) |existing| {
            var existing_mut = existing;
            defer existing_mut.deinit(self.allocator);

            const needs_label_heal = existing.label == null or
                (existing.label != null and existing.label.?[0] == '[');
            const needs_name_heal = existing.name == null or
                (existing.name != null and std.mem.indexOf(u8, existing.name.?, "[") != null);

            if (needs_label_heal or needs_name_heal) {
                try names_storage.updateNameLabel(self.database, wrapped_node, labels[0], name_str);
                std.log.info("Healed name from NameWrapped DNS: {s}", .{name_str});
            }
        }
    }

    // Walk the label protocol and heal parent names too
    // For "sub.vitalik.eth", we check: sub.vitalik.eth, vitalik.eth, eth
    // Rebuild namehashes from root (eth → vitalik.eth → sub.vitalik.eth)
    if (labels.len < 2) return;

    const Keccak256 = std.crypto.hash.sha3.Keccak256;

    // Start from root namehash (0x00...00)
    var current_namehash: [32]u8 = [_]u8{0} ** 32;

    // Walk labels from last to first (root to leaf)
    var i: usize = labels.len;
    while (i > 0) {
        i -= 1;
        const label = labels[i];

        // Compute keccak256(label)
        var label_hash: [32]u8 = undefined;
        Keccak256.hash(label, &label_hash, .{});

        // Compute namehash = keccak256(parent_namehash + label_hash)
        var input: [64]u8 = undefined;
        @memcpy(input[0..32], &current_namehash);
        @memcpy(input[32..64], &label_hash);
        Keccak256.hash(&input, &current_namehash, .{});

        // Build the name string for this level
        var name_parts: std.ArrayList([]const u8) = .{};
        defer name_parts.deinit(self.allocator);
        var j: usize = i;
        while (j < labels.len) : (j += 1) {
            try name_parts.append(self.allocator, labels[j]);
        }

        // Join with dots
        var total_len: usize = 0;
        for (name_parts.items, 0..) |p, pi| {
            total_len += p.len;
            if (pi < name_parts.items.len - 1) total_len += 1;
        }
        const level_name = try self.allocator.alloc(u8, total_len);
        defer self.allocator.free(level_name);
        var pos: usize = 0;
        for (name_parts.items, 0..) |p, pi| {
            @memcpy(level_name[pos .. pos + p.len], p);
            pos += p.len;
            if (pi < name_parts.items.len - 1) {
                level_name[pos] = '.';
                pos += 1;
            }
        }

        const node_hash = Hash{ .bytes = current_namehash };

        // Check if this name has an unresolved label
        if (try names_storage.getNameByNamehash(self.database, node_hash)) |existing| {
            var existing_mut = existing;
            defer existing_mut.deinit(self.allocator);

            const needs_heal = existing.label == null or
                (existing.label != null and existing.label.?[0] == '[');

            if (needs_heal) {
                try names_storage.updateNameLabel(self.database, node_hash, label, level_name);
                std.log.info("Healed parent name from NameWrapped DNS: {s} (label={s})", .{ level_name, label });
            }
        }

        // Also delete from unknown_labels if resolved
        deleteUnknownLabelByNamehash(self.database.db.?, &current_namehash) catch {};
    }
}

/// Delete unknown_labels entry by namehash (after healing from DNS name)
fn deleteUnknownLabelByNamehash(sqlite_db: *db.c.sqlite3, namehash_bytes: *const [32]u8) !void {
    const namehash = Hash{ .bytes = namehash_bytes.* };
    var buf: [66]u8 = undefined;
    const namehash_hex = namehash.toHexBuf(&buf);

    const query = "DELETE FROM unknown_labels WHERE namehash = ?";
    var stmt: ?*db.c.sqlite3_stmt = null;
    const rc = db.c.sqlite3_prepare_v2(sqlite_db, query.ptr, @intCast(query.len), &stmt, null);
    if (rc != db.c.SQLITE_OK) return;
    defer _ = db.c.sqlite3_finalize(stmt);

    _ = db.c.sqlite3_bind_text(stmt, 1, namehash_hex.ptr, @intCast(namehash_hex.len), null);
    _ = db.c.sqlite3_step(stmt);
}
