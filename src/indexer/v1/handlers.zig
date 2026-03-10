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


/// Handle V1 ENS Registry NewOwner event
/// NewOwner(bytes32 indexed node, bytes32 indexed label, address owner)
/// This event is emitted when a subdomain is created
pub fn handleV1NewOwner(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (parent namehash)
    // topics[2] = indexed label (labelhash)
    if (log.topics.len < 3) return error.InvalidTopicCount;
    if (log.data.len < 32) return error.InsufficientData;

    const parent_node = log.topics[1];
    const labelhash = log.topics[2];

    // Decode owner address from data
    const owner = try abi.ABI.decodeAddress(log.data, 0);

    const parent_hex = try parent_node.toHex(self.allocator);
    defer self.allocator.free(parent_hex);
    const labelhash_hex = try labelhash.toHex(self.allocator);
    defer self.allocator.free(labelhash_hex);
    const owner_hex = try owner.toHex(self.allocator);
    defer self.allocator.free(owner_hex);

    // Compute the subdomain namehash: keccak256(parent_node + labelhash)
    var subdomain_input: [64]u8 = undefined;
    @memcpy(subdomain_input[0..32], &parent_node.bytes);
    @memcpy(subdomain_input[32..64], &labelhash.bytes);

    const Keccak256 = std.crypto.hash.sha3.Keccak256;
    var subdomain_namehash_bytes: [32]u8 = undefined;
    Keccak256.hash(&subdomain_input, &subdomain_namehash_bytes, .{});

    var subdomain_namehash: Hash = undefined;
    @memcpy(&subdomain_namehash.bytes, &subdomain_namehash_bytes);

    const subdomain_hex = try subdomain_namehash.toHex(self.allocator);
    defer self.allocator.free(subdomain_hex);

    std.log.debug("V1 NewOwner: parent={s} labelhash={s} subdomain={s} owner={s}", .{
        parent_hex,
        labelhash_hex,
        subdomain_hex,
        owner_hex,
    });

    // V1 migration block - before this, we're in the temporary registrar period
    const v1_migration_block = self.config.l1_contracts.v1_migration_block;
    const is_pre_migration = v1_migration_block > 0 and log.block_number < v1_migration_block;

    if (is_pre_migration) {
        // Store for later backfill when v1_labels table is populated
        std.log.debug("Storing pre-migration NewOwner for backfill: namehash={s} labelhash={s}", .{ subdomain_hex, labelhash_hex });

        const Query = db.Query;
        const tx_hash_hex = try log.transaction_hash.toHex(self.allocator);
        defer self.allocator.free(tx_hash_hex);

        var q = try Query.init(self.database,
            \\INSERT OR IGNORE INTO temp_pre_migration_names
            \\(chain, namehash, label_hash, parent_node, owner, block_number, tx_hash, log_index, created_at)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        );
        defer q.deinit();

        try q.bindText(@tagName(chain));
        try q.bindText(subdomain_hex);
        try q.bindText(labelhash_hex);
        try q.bindText(parent_hex);
        try q.bindText(owner_hex);
        try q.bindInt64(@intCast(log.block_number));
        try q.bindText(tx_hash_hex);
        try q.bindInt64(@intCast(log.log_index));
        try q.bindInt64(std.time.timestamp());
        try q.exec();

        return; // Don't create name entry yet
    }

    // Post-migration: Check if this is a .eth 2LD registration
    // .eth 2LDs are already handled by BaseRegistrar NameRegistered events
    // Only record true subdomains (non-.eth parent) for backfill
    if (parent_node.eql(constants.WellKnown.eth_namehash)) {
        // This is a .eth 2LD registration (e.g., example.eth)
        // Skip - already handled by BaseRegistrar NameRegistered
        std.log.debug("V1 NewOwner for .eth 2LD (skipping - handled by BaseRegistrar): labelhash={s}", .{labelhash_hex});
        return;
    }

    // This is a true subdomain (e.g., sub.example.eth) - record for backfill
    const tx_hash_hex = try log.transaction_hash.toHex(self.allocator);
    defer self.allocator.free(tx_hash_hex);

    std.log.debug("V1 NewOwner subdomain (label unknown, recording for backfill): namehash={s} labelhash={s} owner={s} tx={s}", .{
        subdomain_hex,
        labelhash_hex,
        owner_hex,
        tx_hash_hex,
    });

    // Record unknown label for later backfill from transaction calldata
    unknown_labels_storage.insertUnknownLabel(
        self.database.db.?,
        null, // name_id - we don't have a name record yet
        log.transaction_hash,
        labelhash,
        subdomain_namehash,
        parent_node,
        owner,
        log.block_number,
    ) catch |err| {
        std.log.err("Failed to insert unknown label: {}", .{err});
        // Continue even if insert fails (might be duplicate)
    };

    // Store event for historical record
    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"parentNode\":\"{s}\",\"labelhash\":\"{s}\",\"subdomain\":\"{s}\",\"owner\":\"{s}\"}}", .{
        parent_hex,
        labelhash_hex,
        subdomain_hex,
        owner_hex,
    });

    try utils.emitEvent(self, chain, log, .transfer, null, subdomain_namehash, event_data);
}

/// Handle V1 ENS Registry Transfer event
/// Transfer(bytes32 indexed node, address owner)
pub fn handleV1RegistryTransfer(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    if (log.topics.len < 2) return error.InvalidTopicCount;
    if (log.data.len < 32) return error.InsufficientData;

    const node = log.topics[1];

    // Decode owner address from data
    const owner = try abi.ABI.decodeAddress(log.data, 0);

    const node_hex = try node.toHex(self.allocator);
    defer self.allocator.free(node_hex);
    const owner_hex = try owner.toHex(self.allocator);
    defer self.allocator.free(owner_hex);

    std.log.debug("V1 RegistryTransfer: node={s} owner={s}", .{ node_hex, owner_hex });

    // Store event
    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"node\":\"{s}\",\"owner\":\"{s}\"}}", .{
        node_hex,
        owner_hex,
    });

    try utils.emitEvent(self, chain, log, .transfer, null, node, event_data);
}

/// Handle V1 ENS Registry NewResolver event
/// NewResolver(bytes32 indexed node, address resolver)
pub fn handleV1NewResolver(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    if (log.topics.len < 2) return error.InvalidTopicCount;
    if (log.data.len < 32) return error.InsufficientData;

    const node = log.topics[1];

    // Decode resolver address from data
    const resolver = try abi.ABI.decodeAddress(log.data, 0);

    const node_hex = try node.toHex(self.allocator);
    defer self.allocator.free(node_hex);
    const resolver_hex = try resolver.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);

    std.log.debug("V1 NewResolver: node={s} resolver={s}", .{ node_hex, resolver_hex });

    // Update the name's resolver in the database
    const names_storage = @import("../../storage/names.zig");
    try names_storage.updateNameResolver(self.database, node, resolver);

    // Register resolver for indexing
    try self.database.registerResolver(chain, resolver_hex, log.block_number);

    std.log.debug("Updated name resolver: node={s} -> resolver={s}", .{ node_hex, resolver_hex });

    // Store event
    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"node\":\"{s}\",\"resolver\":\"{s}\"}}", .{
        node_hex,
        resolver_hex,
    });

    try utils.emitEvent(self, chain, log, .resolver_update, null, node, event_data);
}

/// Handle V1 ENS Registry NewTTL event
/// NewTTL(bytes32 indexed node, uint64 ttl)
pub fn handleV1NewTTL(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    if (log.topics.len < 2) return error.InvalidTopicCount;
    if (log.data.len < 32) return error.InsufficientData;

    const node = log.topics[1];

    // Decode TTL from data (uint64, but padded to 32 bytes)
    const ttl_u256 = try abi.ABI.decodeUint256(log.data, 0);
    const ttl: u64 = @intCast(ttl_u256);

    const node_hex = try node.toHex(self.allocator);
    defer self.allocator.free(node_hex);

    std.log.debug("V1 NewTTL: node={s} ttl={d}", .{ node_hex, ttl });

    // Store event
    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"node\":\"{s}\",\"ttl\":{d}}}", .{
        node_hex,
        ttl,
    });

    try utils.emitEvent(self, chain, log, .resolver_update, null, node, event_data);
}

/// Handle V1 Name Wrapper NameWrapped event
/// NameWrapped(bytes32 indexed node, bytes name, address owner, uint32 fuses, uint64 expiry)
pub fn handleV1NameWrapped(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    if (log.topics.len < 2) return error.InvalidTopicCount;
    if (log.data.len < 160) return error.InsufficientData;

    const node = log.topics[1];

    // Decode name (bytes - dynamic length)
    const name_bytes = try abi.ABI.decodeBytes(self.allocator, log.data, 0);
    defer self.allocator.free(name_bytes);

    // Decode owner address (offset 32)
    const owner = try abi.ABI.decodeAddress(log.data, 64);

    // Decode fuses (uint32, offset 96, but padded to 32 bytes)
    const fuses_u256 = try abi.ABI.decodeUint256(log.data, 96);
    const fuses: u32 = @intCast(fuses_u256);

    // Decode expiry (uint64, offset 128, but padded to 32 bytes)
    const expiry_u256 = try abi.ABI.decodeUint256(log.data, 128);
    const expiry: u64 = @intCast(expiry_u256);

    const node_hex = try node.toHex(self.allocator);
    defer self.allocator.free(node_hex);
    const owner_hex = try owner.toHex(self.allocator);
    defer self.allocator.free(owner_hex);

    std.log.debug("V1 NameWrapped: node={s} owner={s} fuses={d} expiry={d}", .{ node_hex, owner_hex, fuses, expiry });

    // Update name wrapper state in database
    const names_storage = @import("../../storage/names.zig");
    try names_storage.updateNameWrapperState(self.database, node, fuses, @intCast(expiry));
    try names_storage.updateNameOwner(self.database, node, owner);

    std.log.debug("Updated name wrapper state: node={s} wrapped=true fuses={d} expiry={d}", .{ node_hex, fuses, expiry });

    // Store event
    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"node\":\"{s}\",\"owner\":\"{s}\",\"fuses\":{d},\"expiry\":{d}}}", .{
        node_hex,
        owner_hex,
        fuses,
        expiry,
    });

    try utils.emitEvent(self, chain, log, .transfer, null, node, event_data);
}

/// Handle V1 Name Wrapper NameUnwrapped event
/// NameUnwrapped(bytes32 indexed node, address owner)
pub fn handleV1NameUnwrapped(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    if (log.topics.len < 2) return error.InvalidTopicCount;
    if (log.data.len < 32) return error.InsufficientData;

    const node = log.topics[1];

    // Decode owner address from data
    const owner = try abi.ABI.decodeAddress(log.data, 0);

    const node_hex = try node.toHex(self.allocator);
    defer self.allocator.free(node_hex);
    const owner_hex = try owner.toHex(self.allocator);
    defer self.allocator.free(owner_hex);

    std.log.debug("V1 NameUnwrapped: node={s} owner={s}", .{ node_hex, owner_hex });

    // Update name wrapper state in database
    const names_storage = @import("../../storage/names.zig");
    try names_storage.updateNameUnwrapperState(self.database, node);
    try names_storage.updateNameOwner(self.database, node, owner);

    std.log.debug("Updated name unwrapper state: node={s} wrapped=false", .{node_hex});

    // Store event
    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"node\":\"{s}\",\"owner\":\"{s}\"}}", .{
        node_hex,
        owner_hex,
    });

    try utils.emitEvent(self, chain, log, .transfer, null, node, event_data);
}

/// Handle V1 Name Wrapper FusesSet event
/// FusesSet(bytes32 indexed node, uint32 fuses)
pub fn handleV1FusesSet(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    if (log.topics.len < 2) return error.InvalidTopicCount;
    if (log.data.len < 32) return error.InsufficientData;

    const node = log.topics[1];

    // Decode fuses from data (uint32, but padded to 32 bytes)
    const fuses_u256 = try abi.ABI.decodeUint256(log.data, 0);
    const fuses: u32 = @intCast(fuses_u256);

    const node_hex = try node.toHex(self.allocator);
    defer self.allocator.free(node_hex);

    std.log.debug("V1 FusesSet: node={s} fuses={d}", .{ node_hex, fuses });

    // Update name wrapper fuses in database
    const names_storage = @import("../../storage/names.zig");
    try names_storage.updateNameWrapperFuses(self.database, node, fuses);

    std.log.debug("Updated name wrapper fuses: node={s} fuses={d}", .{ node_hex, fuses });

    // Store event
    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"node\":\"{s}\",\"fuses\":{d}}}", .{
        node_hex,
        fuses,
    });

    try utils.emitEvent(self, chain, log, .resolver_update, null, node, event_data);
}

/// Handle V1 Name Wrapper ExpiryExtended event
/// ExpiryExtended(bytes32 indexed node, uint64 expiry)
pub fn handleV1ExpiryExtended(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    if (log.topics.len < 2) return error.InvalidTopicCount;
    if (log.data.len < 32) return error.InsufficientData;

    const node = log.topics[1];

    // Decode expiry from data (uint64, but padded to 32 bytes)
    const expiry_u256 = try abi.ABI.decodeUint256(log.data, 0);
    const expiry: u64 = @intCast(expiry_u256);

    const node_hex = try node.toHex(self.allocator);
    defer self.allocator.free(node_hex);

    std.log.debug("V1 ExpiryExtended: node={s} expiry={d}", .{ node_hex, expiry });

    // Update name wrapper expiry in database
    const names_storage = @import("../../storage/names.zig");
    try names_storage.updateNameWrapperExpiry(self.database, node, @intCast(expiry));

    std.log.debug("Updated name wrapper expiry: node={s} expiry={d}", .{ node_hex, expiry });

    // Store event
    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"node\":\"{s}\",\"expiry\":{d}}}", .{
        node_hex,
        expiry,
    });

    try utils.emitEvent(self, chain, log, .name_renewed, null, node, event_data);
}

/// Handle V1 Base Registrar ERC721 Transfer event
/// Transfer(address indexed from, address indexed to, uint256 indexed tokenId)
pub fn handleV1ERC721Transfer(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    const v1_names = @import("../../utils/v1_names.zig");
    const names_storage = @import("../../storage/names.zig");

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

    const from_hex = try from.toHex(self.allocator);
    defer self.allocator.free(from_hex);
    const to_hex = try to.toHex(self.allocator);
    defer self.allocator.free(to_hex);

    std.log.debug("V1 ERC721 Transfer: from={s} to={s} tokenId={d}", .{ from_hex, to_hex, token_id });

    // Try to update the name's owner if we know the label
    // Convert token_id to hex for lookup
    const token_id_hex = try utils.tokenIdToHex(self.allocator, token_id);
    defer self.allocator.free(token_id_hex);

    // Look up the label from our v1_labels table
    if (try v1_names.tokenIdToLabel(self.allocator, self.database, token_id_hex)) |label| {
        defer self.allocator.free(label);

        // Compute the namehash for this name
        const namehash = v1_names.computeEthNamehash(label);

        // Update the name's owner
        try names_storage.updateNameOwner(self.database, namehash, to);

        const full_name = try std.fmt.allocPrint(self.allocator, "{s}.eth", .{label});
        defer self.allocator.free(full_name);

        std.log.debug("Updated V1 name ownership: {s} -> {s}", .{ full_name, to_hex });
    } else {
        // This is expected - not all transfers correspond to known names
        // (e.g., the name might have been registered before we started indexing)
        std.log.debug("V1 Transfer for unknown tokenId {s}, event stored but name not updated", .{token_id_hex});
    }

    // Store event
    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"from\":\"{s}\",\"to\":\"{s}\",\"tokenId\":\"{d}\"}}", .{
        from_hex,
        to_hex,
        token_id,
    });

    try utils.emitEvent(self, chain, log, .transfer, null, null, event_data);
}

/// Handle V1 Base Registrar NameRegistered event
/// NameRegistered(uint256 indexed id, address indexed owner, uint256 expires)
pub fn handleV1BaseRegistrarNameRegistered(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    const v1_names = @import("../../utils/v1_names.zig");
    const names_storage = @import("../../storage/names.zig");

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

    const owner_hex = try owner.toHex(self.allocator);
    defer self.allocator.free(owner_hex);

    // Convert tokenID to hex for label lookup (big-endian byte order)
    const token_id_hex = try utils.tokenIdToHex(self.allocator, token_id);
    defer self.allocator.free(token_id_hex);

    // Try to look up the label from v1_labels table
    const maybe_label = try v1_names.tokenIdToLabel(self.allocator, self.database, token_id_hex);

    if (maybe_label) |label| {
        defer self.allocator.free(label);

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

        // Allocate v1_label_hash (needs to be freed after insertName)
        const v1_label_hash_hex = try label_hash.toHex(self.allocator);
        defer self.allocator.free(v1_label_hash_hex);

        // Create name record
        const name_record = models.Name{
            .name = full_name,
            .namehash = namehash,
            .label = label,
            .label_hash = label_hash,
            .parent_name = "eth",
            .parent_namehash = eth_node,
            .chain = chain,
            .registry = self.config.l1_contracts.ens_registry, // ENS Registry, not Base Registrar!
            .owner = owner,
            .registrant = owner, // Original registrant from V1 NameRegistered
            .resolver = Address.zero, // Will be updated when resolver is set
            .token_id = token_id,
            .canonical_id = token_id, // V1 doesn't use versioning
            .token_version = 0,
            .expiry = @intCast(expires),
            .registry_locked = false, // V1 names don't have registry locking
            .migrated = false, // This is a native V1 name
            .ejected = false, // V1 names on L1 are not ejected
            .created_block = log.block_number,
            .created_at = self.getBlockTimestamp(chain, log.block_number, log.block_timestamp),
            .registered_at = self.getBlockTimestamp(chain, log.block_number, log.block_timestamp),
            .updated_block = log.block_number,
            .updated_at = std.time.timestamp(),
            .is_wrapped = false, // Not wrapped initially
            .wrapper_fuses = null,
            .wrapper_expiry = null,
            .is_v1_name = true, // This is a V1 .eth name
            .v1_label_hash = v1_label_hash_hex,
        };

        try names_storage.insertName(self.database, name_record);

        // Store event with name and namehash
        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"id\":\"{s}\",\"name\":\"{s}\",\"owner\":\"{s}\",\"expires\":{d}}}", .{
            token_id_hex,
            full_name,
            owner_hex,
            expires,
        });

        try utils.emitEvent(self, chain, log, .name_registered, full_name, namehash, event_data);
    } else {
        // Label not found yet - might come in a later ETH Controller event
        std.log.warn("V1 BaseRegistrar NameRegistered: tokenID {s} label not found (will store event only)", .{token_id_hex});

        // Store event without name/namehash
        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"id\":\"{s}\",\"owner\":\"{s}\",\"expires\":{d}}}", .{
            token_id_hex,
            owner_hex,
            expires,
        });

        try utils.emitEvent(self, chain, log, .name_registered, null, null, event_data);
    }
}

/// Handle V1 Base Registrar NameRenewed event
/// NameRenewed(uint256 indexed id, uint256 expires)
pub fn handleV1BaseRegistrarNameRenewed(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    const v1_names = @import("../../utils/v1_names.zig");
    const names_storage = @import("../../storage/names.zig");

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

    // Look up the label from our v1_labels table
    if (try v1_names.tokenIdToLabel(self.allocator, self.database, token_id_hex)) |label| {
        defer self.allocator.free(label);

        // Compute the namehash for this name
        const namehash = v1_names.computeEthNamehash(label);

        // Update the name's expiry
        try names_storage.updateNameExpiry(self.database, namehash, @intCast(expires));

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

    try utils.emitEvent(self, chain, log, .name_renewed, null, null, event_data);
}

/// Handle V1 Base Registrar ControllerAdded event
/// ControllerAdded(address indexed controller)
pub fn handleV1ControllerAdded(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    _ = chain; // Controller events are operational only, not stored as user-facing events
    const v1_controllers = @import("../../storage/v1_controllers.zig");

    // topics[0] = event signature
    // topics[1] = indexed controller address
    if (log.topics.len < 2) {
        std.log.warn("V1 ControllerAdded event has unexpected topic count: {d}, skipping", .{log.topics.len});
        return;
    }

    const controller = try abi.ABI.decodeAddress(&log.topics[1].bytes, 0);
    const controller_hex = try controller.toHex(self.allocator);
    defer self.allocator.free(controller_hex);

    const tx_hash_hex = try log.transaction_hash.toHex(self.allocator);
    defer self.allocator.free(tx_hash_hex);

    std.log.debug("V1 ControllerAdded: controller={s} at block {d}", .{ controller_hex, log.block_number });

    // Store in v1_controllers table (this is purely for operational tracking of which contracts to index)
    try v1_controllers.addController(self.database, controller, log.block_number, tx_hash_hex);
}

/// Handle V1 Base Registrar ControllerRemoved event
/// ControllerRemoved(address indexed controller)
pub fn handleV1ControllerRemoved(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    _ = chain; // Controller events are operational only, not stored as user-facing events
    const v1_controllers = @import("../../storage/v1_controllers.zig");

    // topics[0] = event signature
    // topics[1] = indexed controller address
    if (log.topics.len < 2) {
        std.log.warn("V1 ControllerRemoved event has unexpected topic count: {d}, skipping", .{log.topics.len});
        return;
    }

    const controller = try abi.ABI.decodeAddress(&log.topics[1].bytes, 0);
    const controller_hex = try controller.toHex(self.allocator);
    defer self.allocator.free(controller_hex);

    const tx_hash_hex = try log.transaction_hash.toHex(self.allocator);
    defer self.allocator.free(tx_hash_hex);

    std.log.debug("V1 ControllerRemoved: controller={s} at block {d}", .{ controller_hex, log.block_number });

    // Update in v1_controllers table (this is purely for operational tracking of which contracts to index)
    try v1_controllers.removeController(self.database, controller, log.block_number, tx_hash_hex);
}

/// Handle V1 ETH Registrar Controller NameRegistered event
/// NameRegistered(string name, bytes32 indexed label, address indexed owner, uint256 baseCost, uint256 premium, uint256 expires)
pub fn handleV1ETHControllerNameRegistered(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    const v1_names = @import("../../utils/v1_names.zig");

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

    const owner_hex = try owner.toHex(self.allocator);
    defer self.allocator.free(owner_hex);

    const label_hash_hex = try label_hash.toHex(self.allocator);
    defer self.allocator.free(label_hash_hex);

    std.log.debug("V1 ETH Controller NameRegistered: name={s} label_hash={s} owner={s} expires={d}", .{
        name,
        label_hash_hex,
        owner_hex,
        expires,
    });

    // Store the tokenID->label mapping in the v1_labels table
    const namehash = v1_names.computeEthNamehash(name);
    const tx_hash_hex = try log.transaction_hash.toHex(self.allocator);
    defer self.allocator.free(tx_hash_hex);

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

    // Store event
    const event_data = try std.fmt.allocPrint(
        self.allocator,
        "{{\"name\":\"{s}\",\"label\":\"{s}\",\"owner\":\"{s}\",\"cost\":{d},\"expires\":{d}}}",
        .{ name, label_hash_hex, owner_hex, cost, expires },
    );

    try utils.emitEvent(self, chain, log, .name_registered, name, namehash, event_data);
}

/// Handle V1 ETH Registrar Controller NameRenewed event
/// NameRenewed(string name, bytes32 indexed label, uint256 cost, uint256 expires)
pub fn handleV1ETHControllerNameRenewed(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    const v1_names = @import("../../utils/v1_names.zig");

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

    const label_hash_hex = try label_hash.toHex(self.allocator);
    defer self.allocator.free(label_hash_hex);

    std.log.debug("V1 ETH Controller NameRenewed: name={s} label_hash={s} cost={d} expires={d}", .{
        name,
        label_hash_hex,
        cost,
        expires,
    });

    // Store/update the tokenID->label mapping
    const namehash = v1_names.computeEthNamehash(name);
    const tx_hash_hex = try log.transaction_hash.toHex(self.allocator);
    defer self.allocator.free(tx_hash_hex);

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

    // Store event
    const event_data = try std.fmt.allocPrint(
        self.allocator,
        "{{\"name\":\"{s}\",\"label\":\"{s}\",\"cost\":{d},\"expires\":{d}}}",
        .{ name, label_hash_hex, cost, expires },
    );

    try utils.emitEvent(self, chain, log, .name_renewed, name, namehash, event_data);
}

/// Handle V1 Reverse Registrar ReverseClaimed event
/// ReverseClaimed(address indexed addr, bytes32 indexed node)
pub fn handleV1ReverseClaimed(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed addr
    // topics[2] = indexed node
    if (log.topics.len < 3) return error.InvalidTopicCount;

    const addr = try abi.ABI.decodeAddress(&log.topics[1].bytes, 0);
    const node = log.topics[2];

    const addr_hex = try addr.toHex(self.allocator);
    defer self.allocator.free(addr_hex);
    const node_hex = try node.toHex(self.allocator);
    defer self.allocator.free(node_hex);

    std.log.debug("V1 ReverseClaimed: addr={s} node={s}", .{ addr_hex, node_hex });

    // Store event
    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"address\":\"{s}\",\"node\":\"{s}\"}}", .{
        addr_hex,
        node_hex,
    });

    try utils.emitEvent(self, chain, log, .transfer, null, node, event_data);
}
