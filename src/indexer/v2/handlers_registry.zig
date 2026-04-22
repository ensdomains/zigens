const std = @import("std");
const models = @import("../../types/models.zig");
const abi = @import("../abi.zig");
const rpc = @import("../../rpc/client.zig");
const db = @import("../../storage/database.zig");
const Query = db.Query;
const Hash = @import("../../types/hash.zig").Hash;
const Address = @import("../../types/address.zig").Address;
const unicode = @import("../../utils/unicode.zig");
const Indexer = @import("../indexer.zig").Indexer;
const utils = @import("../utils.zig");
const json_utils = @import("../../utils/json.zig");

pub fn handleSubregistryUpdate(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    // Event: SubregistryUpdate(uint256 indexed id, address subregistry)
    // Note: The 'id' in SubregistryUpdate is the canonical_id (version=0), not the full token_id
    if (log.topics.len < 2) return error.InvalidTopicCount;

    // topics[0] = event signature
    // topics[1] = indexed id (canonical ID - note: this is NOT the full token_id)
    // SubregistryUpdate event uses tokenId in topics[1], which may include version bits
    const token_id = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
    // Extract canonical_id (upper bits without version) for consistent lookups
    const token_id_utils = @import("../../types/token_id.zig");
    const canonical_id = token_id_utils.getCanonicalId(token_id);

    // data = subregistry address
    const subregistry_addr = try abi.ABI.decodeAddress(log.data, 0);

    std.log.debug("SubregistryUpdate: tokenId={d}, canonicalId={d}, subregistry={any}, contract={any}", .{ token_id, canonical_id, subregistry_addr, log.address });

    // Skip if subregistry is zero address (unsetting subregistry)
    if (subregistry_addr.isZero()) {
        std.log.debug("  → Skipping zero address subregistry", .{});
        return;
    }

    // Look up the name by token_id AND registry to avoid cross-registry collisions
    const maybe_name = try self.database.getNameByTokenIdAndRegistry(token_id, log.address);
    const name_str = if (maybe_name) |n| blk: {
        var name_copy = n;
        defer name_copy.deinit(self.allocator);
        break :blk try self.allocator.dupe(u8, name_copy.name orelse "[unknown]");
    } else try std.fmt.allocPrint(self.allocator, "canonicalId:{d}", .{canonical_id});
    defer self.allocator.free(name_str);

    const namehash = if (maybe_name) |n| n.namehash else Hash.zero;

    // Insert the subregistry into the registries table so it will be monitored
    const registry = models.Registry{
        .address = subregistry_addr,
        .chain = chain,
        .name = name_str,
        .namehash = namehash,
        .parent_registry = log.address, // The contract that emitted this event
        .created_block = log.block_number,
        .created_at = self.getBlockTimestamp(chain, log.block_number, log.block_timestamp),
    };

    try self.database.insertRegistry(registry);
    std.log.debug("  → Registered subregistry for monitoring: {any}", .{subregistry_addr});

    // Process any orphaned registrations that were waiting for this parent
    const subreg_hex_for_orphans = try subregistry_addr.toHex(self.allocator);
    defer self.allocator.free(subreg_hex_for_orphans);

    const orphans = try self.database.getOrphanedRegistrations(chain, subreg_hex_for_orphans);
    defer {
        for (orphans) |*orphan| {
            var o = orphan.*;
            o.deinit(self.allocator);
        }
        self.allocator.free(orphans);
    }

    if (orphans.len > 0) {
        std.log.info("  → Processing {d} orphaned registration(s) for subregistry {s}", .{ orphans.len, subreg_hex_for_orphans });

        for (orphans) |orphan| {
            // Create the subdomain with correct parent
            try self.processOrphanedRegistration(chain, orphan, name_str, namehash, subregistry_addr);
        }

        // Delete processed orphans
        try self.database.deleteOrphanedRegistrations(chain, subreg_hex_for_orphans);
    }

    // Note: We intentionally do NOT update names.registry here.
    // names.registry should always point to the registry where the name was registered,
    // not the subregistry set for its subdomains. The subregistry relationship is
    // tracked in the registries table via parent_registry.

    // Store event
    const subreg_hex = try subregistry_addr.toHex(self.allocator);
    defer self.allocator.free(subreg_hex);
    const contract_hex = try log.address.toHex(self.allocator);
    defer self.allocator.free(contract_hex);

    // Escape name_str for safe JSON inclusion
    const escaped_name = try json_utils.escapeString(self.allocator, name_str);
    defer self.allocator.free(escaped_name);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"name\":\"{s}\",\"canonicalId\":{d},\"subregistry\":\"{s}\",\"registry\":\"{s}\"}}", .{
        escaped_name,
        canonical_id,
        subreg_hex,
        contract_hex,
    });

    const event_name = try self.allocator.dupe(u8, name_str);

    try utils.emitEvent(self, chain, log, .subregistry_update, event_name, namehash, event_data);
}

/// Process an orphaned registration now that we know its parent
pub fn processOrphanedRegistration(
    self: *Indexer,
    chain: models.Chain,
    orphan: db.Database.OrphanedRegistration,
    parent_name: []const u8,
    parent_namehash: Hash,
    subregistry_addr: Address,
) !void {
    const hash_mod = @import("../../types/hash.zig");
    const token_id_utils = @import("../../types/token_id.zig");

    // Compute full name: label.parent_name
    const full_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ orphan.label, parent_name });
    defer self.allocator.free(full_name);

    const namehash = try hash_mod.namehash(self.allocator, full_name);
    const label_hash = try hash_mod.keccak256(self.allocator, orphan.label);

    // Extract canonical_id and version from token_id
    const canonical_id = token_id_utils.getCanonicalId(orphan.token_id);
    const token_version = token_id_utils.getTokenVersion(orphan.token_id);

    std.log.info("    Processing orphan: {s} (block {d})", .{ full_name, orphan.block_number });

    // Create the name (insertName copies all text internally, so we free our allocations)
    const name_dup = try self.allocator.dupe(u8, full_name);
    defer self.allocator.free(name_dup);
    const label_dup = try self.allocator.dupe(u8, orphan.label);
    defer self.allocator.free(label_dup);
    const parent_name_dup = try self.allocator.dupe(u8, parent_name);
    defer self.allocator.free(parent_name_dup);

    const name = models.Name{
        .name = name_dup,
        .label = label_dup,
        .label_hash = label_hash,
        .parent_name = parent_name_dup,
        .parent_namehash = parent_namehash,
        .chain = chain,
        .registry = subregistry_addr,
        .owner = orphan.owner,
        .registrant = orphan.owner,
        .resolver = Address.zero,
        .token_id = orphan.token_id,
        .canonical_id = canonical_id,
        .token_version = token_version,
        .namehash = namehash,
        .expiry = orphan.expiry,
        .registry_locked = false,
        .migrated = false,
        .created_block = orphan.block_number,
        .created_at = self.getBlockTimestamp(chain, orphan.block_number, null),
        .registered_at = self.getBlockTimestamp(chain, orphan.block_number, null),
        .updated_block = orphan.block_number,
        .updated_at = self.getBlockTimestamp(chain, orphan.block_number, null),
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    };

    try self.database.insertName(name);

    // Store event
    const owner_hex = try orphan.owner.toHex(self.allocator);
    defer self.allocator.free(owner_hex);
    const registry_hex = try subregistry_addr.toHex(self.allocator);
    defer self.allocator.free(registry_hex);

    const escaped_name = try json_utils.escapeString(self.allocator, full_name);
    defer self.allocator.free(escaped_name);
    const escaped_label = try json_utils.escapeString(self.allocator, orphan.label);
    defer self.allocator.free(escaped_label);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"name\":\"{s}\",\"label\":\"{s}\",\"owner\":\"{s}\",\"expiry\":{d},\"registry\":\"{s}\",\"backfilled\":true}}", .{
        escaped_name,
        escaped_label,
        owner_hex,
        orphan.expiry,
        registry_hex,
    });

    const event_name = try self.allocator.dupe(u8, full_name);

    const event = models.Event{
        .event_type = .name_registered,
        .chain = chain,
        .block_number = orphan.block_number,
        .tx_hash = orphan.tx_hash,
        .log_index = orphan.log_index,
        .contract_address = subregistry_addr,
        .name = event_name,
        .namehash = namehash,
        .data = event_data,
        .timestamp = 0, // We don't have the original timestamp
    };

    try self.insertEventAndNotify(event);
}

/// Process any remaining orphaned registrations that now have valid parents
/// Called after indexSubregistryEvents to handle orphans created during this batch
pub fn processRemainingOrphans(self: *Indexer, chain: models.Chain) !void {

    // Query all orphaned registrations that now have a valid parent
    // A valid parent is one where the registry's created_block <= orphan's block_number
    const sql =
        \\SELECT o.subregistry_address, o.token_id, o.label, o.expiry, o.owner,
        \\       o.block_number, o.tx_hash, o.log_index,
        \\       r.name as parent_name, r.namehash as parent_namehash, r.address as registry_addr
        \\FROM orphaned_registrations o
        \\INNER JOIN registries r ON r.chain = o.chain AND r.address = o.subregistry_address
        \\WHERE o.chain = ? AND r.created_block <= o.block_number
        \\ORDER BY o.block_number ASC
    ;

    var oq = try Query.init(self.database, sql);
    defer oq.deinit();
    try oq.bindText(chain.toString());

    var processed_count: usize = 0;
    var processed_addresses = std.StringHashMap(void).init(self.allocator);
    defer {
        var it = processed_addresses.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        processed_addresses.deinit();
    }

    while (try oq.step()) {
        // Extract data from row
        const expiry: u64 = @bitCast(oq.getInt64(3));
        const block_number: u64 = @intCast(oq.getInt64(5));
        const log_index: u32 = @intCast(oq.getInt(7));

        if (oq.isNull(0) or oq.isNull(1) or oq.isNull(2) or
            oq.isNull(4) or oq.isNull(6) or oq.isNull(8) or
            oq.isNull(9) or oq.isNull(10)) continue;

        const subregistry_addr_str = oq.getTextSlice(0).?;
        const token_id_str = oq.getTextSlice(1).?;
        const label = oq.getTextSlice(2).?;
        const owner_str = oq.getTextSlice(4).?;
        const tx_hash_str = oq.getTextSlice(6).?;
        const parent_name = oq.getTextSlice(8).?;
        const parent_namehash_str = oq.getTextSlice(9).?;
        const registry_addr_str = oq.getTextSlice(10).?;

        // Parse values
        const token_id_clean = if (std.mem.startsWith(u8, token_id_str, "0x")) token_id_str[2..] else token_id_str;
        const token_id = std.fmt.parseInt(u256, token_id_clean, 16) catch continue;
        const owner = Address.fromHex(owner_str) catch continue;
        const tx_hash = Hash.fromHex(tx_hash_str) catch continue;
        const parent_namehash = Hash.fromHex(parent_namehash_str) catch continue;
        const subregistry_addr = Address.fromHex(registry_addr_str) catch continue;

        // Create orphan struct and process
        const orphan = db.Database.OrphanedRegistration{
            .chain = chain,
            .subregistry_address = subregistry_addr_str,
            .token_id = token_id,
            .label = label,
            .expiry = expiry,
            .owner = owner,
            .block_number = block_number,
            .tx_hash = tx_hash,
            .log_index = log_index,
        };

        self.processOrphanedRegistration(chain, orphan, parent_name, parent_namehash, subregistry_addr) catch |err| {
            std.log.warn("Failed to process orphaned registration {s}: {}", .{ label, err });
            continue;
        };

        // Track address for later deletion
        if (!processed_addresses.contains(subregistry_addr_str)) {
            const addr_copy = try self.allocator.dupe(u8, subregistry_addr_str);
            try processed_addresses.put(addr_copy, {});
        }

        processed_count += 1;
    }

    // Delete processed orphans
    if (processed_count > 0) {
        std.log.info("Processed {d} orphaned registration(s)", .{processed_count});

        var it = processed_addresses.keyIterator();
        while (it.next()) |addr| {
            try self.database.deleteOrphanedRegistrations(chain, addr.*);
        }
    }
}

pub fn handleResolverUpdate(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    // Event: ResolverUpdate(uint256 indexed id, address resolver)
    // Note: The 'id' in ResolverUpdate is the current token_id (including version bits),
    // NOT the canonical_id. We must strip version bits to look up the name.
    if (log.topics.len < 2) return error.InvalidTopicCount;

    // topics[0] = event signature
    // topics[1] = indexed id (this is the full token_id, including version bits)
    const token_id = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
    const token_id_utils_local = @import("../../types/token_id.zig");
    const canonical_id = token_id_utils_local.getCanonicalId(token_id);

    // data = resolver address
    const resolver_addr = try abi.ABI.decodeAddress(log.data, 0);

    std.log.debug("ResolverUpdate: tokenId={d}, canonicalId={d}, resolver={any}, contract={any}", .{ token_id, canonical_id, resolver_addr, log.address });

    // Look up the name by token_id AND registry to avoid cross-registry collisions
    // (e.g., "tester.eth" and "tester.calendars.eth" share the same token_id)
    const maybe_name = try self.database.getNameByTokenIdAndRegistry(token_id, log.address);

    // Skip if name doesn't exist yet (might be out of order event processing)
    if (maybe_name == null) {
        std.log.warn("  → Skipping ResolverUpdate for unknown tokenId={d} in registry {any}", .{ token_id, log.address });
        return;
    }

    // Extract and allocate name_str and copy namehash before any cleanup
    const name_str = try self.allocator.dupe(u8, maybe_name.?.name orelse "[unknown]");
    defer self.allocator.free(name_str);
    const namehash = maybe_name.?.namehash;

    // Clean up the name struct
    var name_copy = maybe_name.?;
    name_copy.deinit(self.allocator);

    // Update resolver in database
    try self.database.updateNameResolver(namehash, resolver_addr);

    // Register resolver for record indexing (if not zero address)
    if (!resolver_addr.isZero()) {
        const resolver_hex = try resolver_addr.toHex(self.allocator);
        defer self.allocator.free(resolver_hex);
        try self.database.registerResolver(chain, resolver_hex, log.block_number);
    }

    // Store event
    const resolver_hex = try resolver_addr.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);
    const contract_hex = try log.address.toHex(self.allocator);
    defer self.allocator.free(contract_hex);

    // Escape name_str for safe JSON inclusion
    const escaped_name = try json_utils.escapeString(self.allocator, name_str);
    defer self.allocator.free(escaped_name);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"name\":\"{s}\",\"canonicalId\":{d},\"resolver\":\"{s}\",\"registry\":\"{s}\"}}", .{
        escaped_name,
        canonical_id,
        resolver_hex,
        contract_hex,
    });

    const event_name = try self.allocator.dupe(u8, name_str);

    try utils.emitEvent(self, chain, log, .resolver_update, event_name, namehash, event_data);
}

pub fn handleNameRegistered(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    // V2 Event: NameRegistered(uint256 indexed tokenId, string label, uint64 expiration, address registeredBy)
    if (log.topics.len < 2) return error.InvalidTopicCount;

    // Topics[0] = event signature
    // Topics[1] = indexed tokenId
    const token_id_raw = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
    const token_id: u256 = token_id_raw;

    // Data contains: string label, uint64 expiration, address registeredBy
    // String is at offset 0 (as offset pointer)
    // We need to decode the dynamic data
    const label_str = try abi.ABI.decodeString(self.allocator, log.data, 0);
    defer self.allocator.free(label_str);

    // Validate label is valid UTF-8 and contains no control characters
    unicode.validateName(label_str) catch |err| {
        std.log.warn("Invalid name label '{s}' for tokenId={d}: {any}", .{ label_str, token_id, err });
        return;
    };

    // After the string offset (32 bytes) comes uint64 expiration (padded to 32 bytes)
    // and then address registeredBy (padded to 32 bytes)
    // But since string is dynamic, we need to skip to after the actual string data
    // For simplicity, let's decode from the known structure

    // In ABI encoding: [offset_to_string, expiration, registeredBy, string_length, string_data]
    // offset_to_string is at 0x00, expiration at 0x20, registeredBy at 0x40
    const expiration = try abi.ABI.decodeUint256(log.data, 32); // uint64 but padded to uint256
    const registered_by = try abi.ABI.decodeAddress(log.data, 64);

    std.log.debug("NameRegistered: {s} (tokenId={d}, expiration={d}, registeredBy={any})", .{ label_str, token_id, expiration, registered_by });

    // Determine parent name based on registry address
    // If from main .eth registry, parent is "eth". Otherwise look up subregistry parent.
    const eth_registry = self.getEthRegistry(chain);
    const is_main_registry = log.address.eql(eth_registry);

    var parent_name: []const u8 = "eth";
    var parent_name_allocated = false;
    var parent_namehash: Hash = try @import("../../types/hash.zig").namehash(self.allocator, "eth");

    if (!is_main_registry) {
        // This is a subregistry - look up the parent name from registries table
        // We query for the parent that was active at this event's block number
        // (the most recent SubregistryUpdate before or at this block)
        const registry_hex = try log.address.toHex(self.allocator);
        defer self.allocator.free(registry_hex);

        // With multiple parents possible per address (due to address reuse),
        // find the one that was set most recently BEFORE this event
        var rq = try Query.init(self.database,
            \\SELECT name, namehash FROM registries
            \\WHERE address = ? AND chain = ? AND created_block <= ?
            \\ORDER BY created_block DESC
            \\LIMIT 1
        );
        defer rq.deinit();
        try rq.bindText(registry_hex);
        try rq.bindText(chain.toString());
        try rq.bindInt64(@intCast(log.block_number));

        if (try rq.step()) {
            if (rq.getTextSlice(0)) |name_span| {
                parent_name = try self.allocator.dupe(u8, name_span);
                parent_name_allocated = true;
            }

            if (rq.getTextSlice(1)) |namehash_hex| {
                parent_namehash = try Hash.fromHex(namehash_hex);
            }
        } else {
            // No parent found for this subregistry at this block
            // Store as orphaned registration - will be processed when parent claims subregistry
            std.log.debug("NameRegistered: orphaning {s} - no parent found for subregistry {s} at block {d}", .{
                label_str, registry_hex, log.block_number,
            });
            try self.database.insertOrphanedRegistration(
                chain,
                registry_hex,
                token_id,
                label_str,
                @truncate(expiration),
                registered_by,
                log.block_number,
                log.transaction_hash,
                log.log_index,
            );
            return;
        }
    }
    defer if (parent_name_allocated) self.allocator.free(parent_name);

    // Compute full name: label.parent_name
    const full_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ label_str, parent_name });
    defer self.allocator.free(full_name);
    const namehash = try @import("../../types/hash.zig").namehash(self.allocator, full_name);

    // Compute label hash
    const label_hash = try @import("../../types/hash.zig").keccak256(self.allocator, label_str);

    // Extract canonical_id and version from token_id
    const token_id_utils = @import("../../types/token_id.zig");
    const canonical_id = token_id_utils.getCanonicalId(token_id);
    const token_version = token_id_utils.getTokenVersion(token_id);

    const name_str_dup = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ label_str, parent_name });
    defer self.allocator.free(name_str_dup);

    const label_dup = try self.allocator.dupe(u8, label_str);
    defer self.allocator.free(label_dup);

    const parent_name_dup = try self.allocator.dupe(u8, parent_name);
    defer self.allocator.free(parent_name_dup);

    const name = models.Name{
        .name = name_str_dup,
        .namehash = namehash,
        .label = label_dup,
        .label_hash = label_hash,
        .parent_name = parent_name_dup,
        .parent_namehash = parent_namehash,
        .chain = chain,
        .registry = log.address, // Use the actual registry that emitted the event
        .owner = registered_by,
        .registrant = registered_by, // Original registrant from NameRegistered event
        .resolver = Address.zero,
        .token_id = @intCast(token_id),
        .canonical_id = canonical_id,
        .token_version = token_version,
        .expiry = @truncate(expiration),
        .registry_locked = false,
        .migrated = false,
        .created_block = log.block_number,
        .created_at = self.getBlockTimestamp(chain, log.block_number, log.block_timestamp),
        .registered_at = self.getBlockTimestamp(chain, log.block_number, log.block_timestamp),
        .updated_block = log.block_number,
        .updated_at = std.time.timestamp(),
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    };

    try self.database.insertName(name);

    // After inserting name, check if there are placeholder registries that need updating
    // This happens when SubregistryUpdate was processed before NameRegistered in the same block
    // The SubregistryUpdate creates a registry with name "canonicalId:{d}" as a placeholder
    const placeholder_pattern = try std.fmt.allocPrint(self.allocator, "canonicalId:{d}", .{canonical_id});
    defer self.allocator.free(placeholder_pattern);
    _ = self.database.updateRegistryPlaceholderName(placeholder_pattern, full_name, namehash) catch |err| {
        std.log.warn("Failed to update placeholder registry: {}", .{err});
    };

    // Store event
    const nh_hex = try namehash.toHex(self.allocator);
    defer self.allocator.free(nh_hex);
    const owner_hex = try registered_by.toHex(self.allocator);
    defer self.allocator.free(owner_hex);

    // Escape label_str for safe JSON inclusion
    const escaped_label = try json_utils.escapeString(self.allocator, label_str);
    defer self.allocator.free(escaped_label);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"label\":\"{s}\",\"tokenId\":{d},\"namehash\":\"{s}\",\"owner\":\"{s}\",\"expiration\":{d}}}", .{
        escaped_label,
        token_id,
        nh_hex,
        owner_hex,
        expiration,
    });

    const event_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ label_str, parent_name });

    try utils.emitEvent(self, chain, log, .name_registered, event_name, namehash, event_data);
}

pub fn handleNameRenewed(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    // V2 Event: NameRenewed(uint256 indexed tokenId, uint64 newExpiration, address renewedBy)
    if (log.topics.len < 2) return error.InvalidTopicCount;

    // Topics[0] = event signature
    // Topics[1] = indexed tokenId
    const token_id_raw = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
    const token_id: u256 = token_id_raw;
    const token_id_utils_renew = @import("../../types/token_id.zig");
    const canonical_id = token_id_utils_renew.getCanonicalId(token_id);

    // Data contains: uint64 newExpiration, address renewedBy (both padded to 32 bytes)
    const new_expiration = try abi.ABI.decodeUint256(log.data, 0); // uint64 but padded
    const renewed_by = try abi.ABI.decodeAddress(log.data, 32);

    std.log.debug("NameRenewed: tokenId={d}, canonicalId={d}, newExpiration={d}, renewedBy={any}", .{ token_id, canonical_id, new_expiration, renewed_by });

    // Look up the name by token_id AND registry to avoid cross-registry collisions
    const maybe_name = try self.database.getNameByTokenIdAndRegistry(token_id, log.address);

    var name_str: []const u8 = undefined;
    var namehash: Hash = Hash.zero;

    if (maybe_name) |n| {
        // Update expiry using namehash (scoped to the correct name)
        try self.database.updateNameExpiry(n.namehash, @truncate(new_expiration));
        name_str = try self.allocator.dupe(u8, n.name orelse "[unknown]");
        namehash = n.namehash;
        var name_copy = n;
        name_copy.deinit(self.allocator);
    } else {
        name_str = try std.fmt.allocPrint(self.allocator, "tokenId:{d}", .{token_id});
    }
    defer self.allocator.free(name_str);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"tokenId\":{d},\"newExpiration\":{d}}}", .{
        token_id,
        new_expiration,
    });

    const event_name = try self.allocator.dupe(u8, name_str);

    try utils.emitEvent(self, chain, log, .name_renewed, event_name, namehash, event_data);
}

pub fn handleTransfer(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    // Event: TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value)
    if (log.topics.len < 4) return error.InvalidTopicCount;

    const operator = try abi.ABI.decodeAddress(&log.topics[1].bytes, 0);
    const from = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);
    const to = try abi.ABI.decodeAddress(&log.topics[3].bytes, 0);

    const id = try abi.ABI.decodeUint256(log.data, 0);
    const value = try abi.ABI.decodeUint256(log.data, 32);

    std.log.debug("Transfer: from={any}, to={any}, id={d}, value={d}", .{ from, to, id, value });

    // Update name owner in database
    // Look up the name by token ID AND registry to avoid cross-registry tokenId collisions
    // (e.g., label "1" has the same tokenId in every registry)
    const maybe_name = try self.database.getNameByTokenIdAndRegistry(id, log.address);
    var namehash_opt: ?Hash = null;
    var name_str_opt: ?[]const u8 = null;

    if (maybe_name) |name| {
        name_str_opt = try self.allocator.dupe(u8, name.name orelse "[unknown]");
        namehash_opt = name.namehash;

        // Clean up the name struct
        var name_copy = name;
        name_copy.deinit(self.allocator);

        try self.database.updateNameOwner(namehash_opt.?, to);
    } else {
        std.log.debug("  → Skipping Transfer for unknown tokenId={d} in registry {any}", .{ id, log.address });
    }

    defer if (name_str_opt) |n| self.allocator.free(n);

    // Store event
    const operator_hex = try operator.toHex(self.allocator);
    defer self.allocator.free(operator_hex);
    const from_hex = try from.toHex(self.allocator);
    defer self.allocator.free(from_hex);
    const to_hex = try to.toHex(self.allocator);
    defer self.allocator.free(to_hex);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"operator\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"id\":{d},\"value\":{d}}}", .{
        operator_hex,
        from_hex,
        to_hex,
        id,
        value,
    });

    const event_name = if (name_str_opt) |n| try self.allocator.dupe(u8, n) else null;

    try utils.emitEvent(self, chain, log, .transfer, event_name, namehash_opt, event_data);
}

// =============================================================================
// ETH Registrar Extended Event Handlers (L2 specific)
// =============================================================================

pub fn handleETHNameRegistered(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    // IETHRegistrar.NameRegistered(uint256 indexed tokenId, string label, address owner, IRegistry subregistry, address resolver, uint64 duration, IERC20 paymentToken, bytes32 referrer, uint256 base, uint256 premium)
    if (log.topics.len < 2) return error.InvalidTopicCount;

    const token_id_raw = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
    const token_id: u256 = token_id_raw;

    // Data: [offset_to_label, owner, subregistry, resolver, duration, paymentToken, referrer, base, premium, label_length, label_data]
    const label_str = try abi.ABI.decodeString(self.allocator, log.data, 0);
    defer self.allocator.free(label_str);

    // Validate label is valid UTF-8 and contains no control characters
    unicode.validateName(label_str) catch |err| {
        std.log.warn("Invalid name label '{s}' for tokenId={d}: {any}", .{ label_str, token_id, err });
        return;
    };

    const owner = try abi.ABI.decodeAddress(log.data, 32);
    const subregistry = try abi.ABI.decodeAddress(log.data, 64);
    const resolver = try abi.ABI.decodeAddress(log.data, 96);
    const duration = try abi.ABI.decodeUint256(log.data, 128); // uint64 padded
    const payment_token = try abi.ABI.decodeAddress(log.data, 160);
    const referrer = try abi.ABI.decodeBytes32(log.data, 192);
    const base_price = try abi.ABI.decodeUint256(log.data, 224);
    const premium = try abi.ABI.decodeUint256(log.data, 256);

    std.log.debug("ETHRegistrar.NameRegistered: {s} (tokenId={d}, owner={any}, duration={d}, base={d}, premium={d})", .{ label_str, token_id, owner, duration, base_price, premium });

    // Compute namehash
    const full_name = try std.fmt.allocPrint(self.allocator, "{s}.eth", .{label_str});
    defer self.allocator.free(full_name);
    const namehash = try @import("../../types/hash.zig").namehash(self.allocator, full_name);
    const label_hash = try @import("../../types/hash.zig").keccak256(self.allocator, label_str);

    // Calculate expiry from registration block timestamp + duration
    const block_timestamp = self.getBlockTimestamp(chain, log.block_number, log.block_timestamp);
    const expiry: u64 = @as(u64, @intCast(block_timestamp)) + @as(u64, @truncate(duration));

    // Extract canonical_id and version from token_id
    const token_id_utils = @import("../../types/token_id.zig");
    const canonical_id = token_id_utils.getCanonicalId(token_id);
    const token_version = token_id_utils.getTokenVersion(token_id);

    const name_str_dup = try std.fmt.allocPrint(self.allocator, "{s}.eth", .{label_str});
    defer self.allocator.free(name_str_dup);

    const label_dup = try self.allocator.dupe(u8, label_str);
    defer self.allocator.free(label_dup);

    const parent_name_dup = try self.allocator.dupe(u8, "eth");
    defer self.allocator.free(parent_name_dup);

    const name = models.Name{
        .name = name_str_dup,
        .namehash = namehash,
        .label = label_dup,
        .label_hash = label_hash,
        .parent_name = parent_name_dup,
        .parent_namehash = try @import("../../types/hash.zig").namehash(self.allocator, "eth"),
        .chain = chain,
        .registry = self.getEthRegistry(chain),
        .owner = owner,
        .registrant = owner, // Original registrant from ETH Registrar
        .resolver = resolver,
        .token_id = @intCast(token_id),
        .canonical_id = canonical_id,
        .token_version = token_version,
        .expiry = expiry,
        .registry_locked = false,
        .migrated = false,
        .created_block = log.block_number,
        .created_at = self.getBlockTimestamp(chain, log.block_number, log.block_timestamp),
        .registered_at = self.getBlockTimestamp(chain, log.block_number, log.block_timestamp),
        .updated_block = log.block_number,
        .updated_at = std.time.timestamp(),
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    };

    try self.database.insertName(name);

    // If subregistry was deployed at registration, store it in the registries table
    if (!subregistry.isZero()) {
        const registry_entry = models.Registry{
            .address = subregistry,
            .chain = chain,
            .name = full_name,
            .namehash = namehash,
            .parent_registry = self.getEthRegistry(chain),
            .created_block = log.block_number,
            .created_at = self.getBlockTimestamp(chain, log.block_number, log.block_timestamp),
        };
        self.database.insertRegistry(registry_entry) catch |err| {
            std.log.warn("Failed to insert subregistry for {s}: {any}", .{ full_name, err });
        };
        std.log.debug("  → Registered subregistry {any} for {s}", .{ subregistry, full_name });
    }

    // Store event with payment details
    const payment_token_hex = try payment_token.toHex(self.allocator);
    defer self.allocator.free(payment_token_hex);
    const referrer_hex = try referrer.toHex(self.allocator);
    defer self.allocator.free(referrer_hex);

    // Escape label_str for safe JSON inclusion
    const escaped_label = try json_utils.escapeString(self.allocator, label_str);
    defer self.allocator.free(escaped_label);

    const owner_hex = try owner.toHex(self.allocator);
    defer self.allocator.free(owner_hex);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"label\":\"{s}\",\"tokenId\":{d},\"owner\":\"{s}\",\"duration\":{d},\"paymentToken\":\"{s}\",\"referrer\":\"{s}\",\"basePrice\":{d},\"premium\":{d}}}", .{
        escaped_label,
        token_id,
        owner_hex,
        duration,
        payment_token_hex,
        referrer_hex,
        base_price,
        premium,
    });

    const event_name = try std.fmt.allocPrint(self.allocator, "{s}.eth", .{label_str});

    try utils.emitEvent(self, chain, log, .name_registered, event_name, namehash, event_data);
}

pub fn handleETHNameRenewed(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    // IETHRegistrar.NameRenewed(uint256 indexed tokenId, string label, uint64 duration, uint64 newExpiry, IERC20 paymentToken, bytes32 referrer, uint256 base)
    if (log.topics.len < 2) return error.InvalidTopicCount;

    const token_id_raw = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
    const token_id: u256 = token_id_raw;
    const token_id_utils_eth_renew = @import("../../types/token_id.zig");
    const canonical_id = token_id_utils_eth_renew.getCanonicalId(token_id);

    // Data: [offset_to_label, duration, newExpiry, paymentToken, referrer, base, label_length, label_data]
    const label_str = try abi.ABI.decodeString(self.allocator, log.data, 0);
    defer self.allocator.free(label_str);

    // Validate label is valid UTF-8 and contains no control characters
    unicode.validateName(label_str) catch |err| {
        std.log.warn("Invalid name label '{s}' for tokenId={d}: {any}", .{ label_str, token_id, err });
        return;
    };

    const duration = try abi.ABI.decodeUint256(log.data, 32); // uint64 padded
    const new_expiry = try abi.ABI.decodeUint256(log.data, 64); // uint64 padded
    const payment_token = try abi.ABI.decodeAddress(log.data, 96);
    const referrer = try abi.ABI.decodeBytes32(log.data, 128);
    const base_price = try abi.ABI.decodeUint256(log.data, 160);

    std.log.debug("ETHRegistrar.NameRenewed: {s} (tokenId={d}, canonicalId={d}, duration={d}, newExpiry={d}, base={d})", .{ label_str, token_id, canonical_id, duration, new_expiry, base_price });

    // Look up the name by token_id AND the .eth registry (NOT log.address, which is the registrar)
    const eth_registry = self.getEthRegistry(chain);
    const maybe_name = try self.database.getNameByTokenIdAndRegistry(token_id, eth_registry);

    // Update expiry using namehash (scoped to the correct name)
    if (maybe_name) |name| {
        try self.database.updateNameExpiry(name.namehash, @truncate(new_expiry));
    }

    // Store event with payment details
    const payment_token_hex = try payment_token.toHex(self.allocator);
    defer self.allocator.free(payment_token_hex);
    const referrer_hex = try referrer.toHex(self.allocator);
    defer self.allocator.free(referrer_hex);

    // Escape label_str for safe JSON inclusion
    const escaped_label = try json_utils.escapeString(self.allocator, label_str);
    defer self.allocator.free(escaped_label);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"label\":\"{s}\",\"tokenId\":{d},\"duration\":{d},\"newExpiry\":{d},\"paymentToken\":\"{s}\",\"referrer\":\"{s}\",\"basePrice\":{d}}}", .{
        escaped_label,
        token_id,
        duration,
        new_expiry,
        payment_token_hex,
        referrer_hex,
        base_price,
    });

    var name_str: []const u8 = undefined;
    var namehash: Hash = Hash.zero;
    if (maybe_name) |n| {
        name_str = try self.allocator.dupe(u8, n.name orelse "[unknown]");
        namehash = n.namehash;
        var name_copy = n;
        name_copy.deinit(self.allocator);
    } else {
        name_str = try std.fmt.allocPrint(self.allocator, "{s}.eth", .{label_str});
    }
    defer self.allocator.free(name_str);

    const event_name = try self.allocator.dupe(u8, name_str);

    try utils.emitEvent(self, chain, log, .name_renewed, event_name, namehash, event_data);
}

pub fn handleCommitmentMade(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    // CommitmentMade(bytes32 commitment)
    // Note: bytes32 is NOT indexed, so it's in the data field
    if (log.topics.len < 1) return error.InvalidTopicCount;

    const commitment = try abi.ABI.decodeBytes32(log.data, 0);

    std.log.debug("CommitmentMade: commitment={any}", .{commitment});

    // Store event
    const commitment_hex = try commitment.toHex(self.allocator);
    defer self.allocator.free(commitment_hex);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"commitment\":\"{s}\"}}", .{commitment_hex});

    try utils.emitEvent(self, chain, log, .commitment_made, null, null, event_data);
}

pub fn handleNameBurned(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    // NameBurned(uint256 indexed tokenId, address burnedBy)
    if (log.topics.len < 2) return error.InvalidTopicCount;

    const token_id_raw = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
    const token_id: u256 = token_id_raw;
    const token_id_utils_burn = @import("../../types/token_id.zig");
    const canonical_id = token_id_utils_burn.getCanonicalId(token_id);

    // Data contains: address burnedBy
    const burned_by = try abi.ABI.decodeAddress(log.data, 0);

    std.log.debug("NameBurned: tokenId={d}, canonicalId={d}, burnedBy={any}", .{ token_id, canonical_id, burned_by });

    // Look up the name by token_id AND registry to avoid cross-registry collisions
    const maybe_name = try self.database.getNameByTokenIdAndRegistry(token_id, log.address);
    const name_str = if (maybe_name) |n| blk: {
        var name_copy = n;
        defer name_copy.deinit(self.allocator);
        break :blk try self.allocator.dupe(u8, name_copy.name orelse "[unknown]");
    } else try std.fmt.allocPrint(self.allocator, "tokenId:{d}", .{token_id});
    defer self.allocator.free(name_str);

    const namehash = if (maybe_name) |n| n.namehash else Hash.zero;

    // Store event
    const burned_by_hex = try burned_by.toHex(self.allocator);
    defer self.allocator.free(burned_by_hex);

    // Escape name_str for safe JSON inclusion
    const escaped_name = try json_utils.escapeString(self.allocator, name_str);
    defer self.allocator.free(escaped_name);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"tokenId\":{d},\"name\":\"{s}\",\"burnedBy\":\"{s}\"}}", .{
        token_id,
        escaped_name,
        burned_by_hex,
    });

    const event_name = try self.allocator.dupe(u8, name_str);

    try utils.emitEvent(self, chain, log, .name_burned, event_name, namehash, event_data);

    // Delete the burned name using namehash (registry-safe: only deletes the exact name)
    // Cannot use canonical_id because it collides across registries (e.g., tester.eth and tester.calendars.eth)
    if (!namehash.eql(Hash.zero)) {
        try self.database.deleteNameByNamehash(namehash);
        std.log.debug("Deleted burned name from database: {s}", .{name_str});
    } else {
        std.log.warn("Cannot delete burned name - unknown namehash for tokenId={d}", .{token_id});
    }
}

pub fn handleTokenRegenerated(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    // TokenRegenerated(uint256 oldTokenId, uint256 newTokenId)
    // Parameters may be indexed (in topics) or non-indexed (in data)
    var old_token_id: u256 = undefined;
    var new_token_id: u256 = undefined;

    if (log.topics.len >= 3) {
        // Both parameters are indexed (in topics)
        old_token_id = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
        new_token_id = try abi.ABI.decodeUint256(&log.topics[2].bytes, 0);
    } else if (log.data.len >= 64) {
        // Parameters are in data (non-indexed)
        old_token_id = try abi.ABI.decodeUint256(log.data, 0);
        new_token_id = try abi.ABI.decodeUint256(log.data, 32);
    } else {
        std.log.warn("TokenRegenerated event with unexpected format: topics={d}, data_len={d}", .{ log.topics.len, log.data.len });
        return;
    }

    std.log.debug("TokenRegenerated: oldTokenId={d}, newTokenId={d}", .{ old_token_id, new_token_id });

    // Look up the name by old token ID and registry to avoid cross-registry collisions
    const maybe_name = try self.database.getNameByTokenIdAndRegistry(old_token_id, log.address);
    const name_str = if (maybe_name) |n| blk: {
        var name_copy = n;
        defer name_copy.deinit(self.allocator);
        break :blk try self.allocator.dupe(u8, name_copy.name orelse "[unknown]");
    } else try std.fmt.allocPrint(self.allocator, "tokenId:{d}", .{old_token_id});
    defer self.allocator.free(name_str);

    const namehash = if (maybe_name) |n| n.namehash else Hash.zero;

    // Store event
    // Escape name_str for safe JSON inclusion
    const escaped_name = try json_utils.escapeString(self.allocator, name_str);
    defer self.allocator.free(escaped_name);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"oldTokenId\":{d},\"newTokenId\":{d},\"name\":\"{s}\"}}", .{
        old_token_id,
        new_token_id,
        escaped_name,
    });

    const event_name = try self.allocator.dupe(u8, name_str);

    try utils.emitEvent(self, chain, log, .token_regenerated, event_name, namehash, event_data);

    // Update token_id in database from old to new (registry-safe: only updates the exact name)
    // Cannot use old_token_id alone because it collides across registries
    if (!namehash.eql(Hash.zero)) {
        try self.database.updateNameTokenIdByNamehash(namehash, new_token_id);
        std.log.debug("Updated token_id in database: {d} -> {d} for {s}", .{ old_token_id, new_token_id, name_str });

        // Note: eac_roles.resource stores canonical_id (version-stripped), so it remains
        // stable across TokenRegenerated events — no update needed.

        // Update approvals.token_id from old to new (scoped by registry)
        // Approvals are tied to specific token versions, so they must be updated.
        const old_token_id_dec = try std.fmt.allocPrint(self.allocator, "{d}", .{old_token_id});
        defer self.allocator.free(old_token_id_dec);
        const new_token_id_dec = try std.fmt.allocPrint(self.allocator, "{d}", .{new_token_id});
        defer self.allocator.free(new_token_id_dec);

        try self.database.updateApprovalTokenId(old_token_id_dec, new_token_id_dec, log.address);
    } else {
        std.log.warn("Cannot update token_id - unknown namehash for oldTokenId={d}", .{old_token_id});
    }
}

pub fn handleTransferBatch(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    // TransferBatch(address indexed operator, address indexed from, address indexed to, uint256[] ids, uint256[] values)
    if (log.topics.len < 4) return error.InvalidTopicCount;

    const operator = try abi.ABI.decodeAddress(&log.topics[1].bytes, 0);
    const from = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);
    const to = try abi.ABI.decodeAddress(&log.topics[3].bytes, 0);

    // Data contains two arrays: ids (offset 0) and values (offset 32)
    const token_ids = try abi.ABI.decodeUint256Array(self.allocator, log.data, 0);
    defer self.allocator.free(token_ids);

    const values = try abi.ABI.decodeUint256Array(self.allocator, log.data, 32);
    defer self.allocator.free(values);

    std.log.debug("TransferBatch: operator={any}, from={any}, to={any}, count={d}", .{ operator, from, to, token_ids.len });

    // Store event
    const operator_hex = try operator.toHex(self.allocator);
    defer self.allocator.free(operator_hex);
    const from_hex = try from.toHex(self.allocator);
    defer self.allocator.free(from_hex);
    const to_hex = try to.toHex(self.allocator);
    defer self.allocator.free(to_hex);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"operator\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"count\":{d}}}", .{
        operator_hex,
        from_hex,
        to_hex,
        token_ids.len,
    });

    try utils.emitEvent(self, chain, log, .transfer, null, null, event_data);

    // Update ownership for each transferred token
    for (token_ids) |token_id| {
        // Only update if transferring to a non-zero address (not burning)
        if (!to.isZero()) {
            // Try to update the owner - if the name doesn't exist, skip it
            const maybe_name = self.database.getNameByTokenIdAndRegistry(token_id, log.address) catch |err| {
                std.log.warn("Failed to get name for tokenId={d} during batch transfer: {any}", .{ token_id, err });
                continue;
            };

            if (maybe_name) |name| {
                // Store the namehash before cleanup
                const namehash = name.namehash;
                // Free the name record
                var mutable_name = name;
                mutable_name.deinit(self.allocator);

                // Use the actual namehash from the retrieved name, not Hash.zero
                self.database.updateNameOwner(namehash, to) catch |err| {
                    std.log.warn("Failed to update owner for tokenId={d}: {any}", .{ token_id, err });
                };
            }
        }
    }
}

pub fn handleApproval(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    // Approval(address indexed owner, address indexed approved, uint256 indexed tokenId)
    if (log.topics.len < 4) return error.InvalidTopicCount;

    const owner = try abi.ABI.decodeAddress(&log.topics[1].bytes, 0);
    const approved = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);
    const token_id_raw = try abi.ABI.decodeUint256(&log.topics[3].bytes, 0);
    const token_id: u256 = token_id_raw;

    std.log.debug("Approval: owner={any}, approved={any}, tokenId={d}", .{ owner, approved, token_id });

    // Look up the name by tokenId and registry to avoid cross-registry collisions
    const maybe_name = try self.database.getNameByTokenIdAndRegistry(token_id, log.address);
    const name_str = if (maybe_name) |n| blk: {
        var name_copy = n;
        defer name_copy.deinit(self.allocator);
        break :blk try self.allocator.dupe(u8, name_copy.name orelse "[unknown]");
    } else try std.fmt.allocPrint(self.allocator, "tokenId:{d}", .{token_id});
    defer self.allocator.free(name_str);

    const namehash = if (maybe_name) |n| n.namehash else Hash.zero;

    // Store event
    const owner_hex = try owner.toHex(self.allocator);
    defer self.allocator.free(owner_hex);
    const approved_hex = try approved.toHex(self.allocator);
    defer self.allocator.free(approved_hex);

    // Escape name_str for safe JSON inclusion
    const escaped_name = try json_utils.escapeString(self.allocator, name_str);
    defer self.allocator.free(escaped_name);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"owner\":\"{s}\",\"approved\":\"{s}\",\"tokenId\":{d},\"name\":\"{s}\"}}", .{
        owner_hex,
        approved_hex,
        token_id,
        escaped_name,
    });

    const event_name = try self.allocator.dupe(u8, name_str);

    try utils.emitEvent(self, chain, log, .approval, event_name, namehash, event_data);

    // Store approval in database (registry-scoped to avoid cross-registry token_id collisions)
    try self.database.insertApproval(chain, token_id, owner, approved, log.block_number, log.transaction_hash, log.address);
    std.log.debug("Stored approval in database for tokenId={d}", .{token_id});
}

// ========================================================================
// Enhanced Access Control (EAC) Event Handler
// ========================================================================

/// Handle EACRolesChanged event from registry contracts
/// EACRolesChanged(uint256 indexed resource, address indexed account, uint256 oldRoleBitmap, uint256 newRoleBitmap)
pub fn handleEACRolesChanged(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    // Event: EACRolesChanged(uint256 indexed resource, address indexed account, uint256 oldRoleBitmap, uint256 newRoleBitmap)
    // topics[0] = event signature
    // topics[1] = resource (tokenId/namehash as uint256) - indexed
    // topics[2] = account - indexed
    // data = oldRoleBitmap (uint256) + newRoleBitmap (uint256)
    if (log.topics.len < 3) return error.InvalidTopicCount;

    // Decode indexed parameters from topics
    const resource_uint = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
    const account = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);

    // Decode non-indexed parameters from data
    const old_role_bitmap = try abi.ABI.decodeUint256(log.data, 0);
    const new_role_bitmap = try abi.ABI.decodeUint256(log.data, 32);

    // Strip to canonical_id (clear lower 32 version bits) so the resource is stable
    // across TokenRegenerated events. Works whether the contract emits token_id or canonical_id.
    const token_id_utils = @import("../../types/token_id.zig");
    const canonical_id = token_id_utils.getCanonicalId(resource_uint);

    // Convert canonical_id to hex string for storage
    var resource_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &resource_bytes, canonical_id, .big);
    const resource_hex_chars = std.fmt.bytesToHex(resource_bytes, .lower);
    const resource_hex = try std.fmt.allocPrint(self.allocator, "0x{s}", .{resource_hex_chars});
    defer self.allocator.free(resource_hex);

    // Convert role bitmaps to hex strings
    var old_bitmap_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &old_bitmap_bytes, old_role_bitmap, .big);
    const old_bitmap_hex_chars = std.fmt.bytesToHex(old_bitmap_bytes, .lower);
    const old_bitmap_hex = try std.fmt.allocPrint(self.allocator, "0x{s}", .{old_bitmap_hex_chars});
    defer self.allocator.free(old_bitmap_hex);

    var new_bitmap_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &new_bitmap_bytes, new_role_bitmap, .big);
    const new_bitmap_hex_chars = std.fmt.bytesToHex(new_bitmap_bytes, .lower);
    const new_bitmap_hex = try std.fmt.allocPrint(self.allocator, "0x{s}", .{new_bitmap_hex_chars});
    defer self.allocator.free(new_bitmap_hex);

    const account_hex = try account.toHex(self.allocator);
    defer self.allocator.free(account_hex);

    std.log.debug("EACRolesChanged: resource={s}, account={s}, oldBitmap={s}, newBitmap={s}", .{
        resource_hex,
        account_hex,
        old_bitmap_hex,
        new_bitmap_hex,
    });

    // Store or delete role in database
    // If newRoleBitmap is 0, all roles were revoked - delete the entry
    // Otherwise, upsert with the new bitmap
    if (new_role_bitmap == 0) {
        try self.database.deleteEACRole(chain, resource_hex, account, log.address);
        std.log.debug("  → Deleted EAC role (all roles revoked)", .{});
    } else {
        try self.database.upsertEACRole(
            chain,
            resource_hex,
            account,
            new_bitmap_hex,
            log.block_number,
            log.transaction_hash,
            log.log_index,
            log.address,
        );
        std.log.debug("  → Stored EAC role assignment", .{});
    }

    // Store event for audit trail
    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"resource\":\"{s}\",\"account\":\"{s}\",\"oldRoleBitmap\":\"{s}\",\"newRoleBitmap\":\"{s}\"}}", .{
        resource_hex,
        account_hex,
        old_bitmap_hex,
        new_bitmap_hex,
    });

    // Look up name by canonical_id AND registry to avoid cross-registry collisions
    const maybe_name = try self.database.getNameByTokenIdAndRegistry(canonical_id, log.address);
    var name_str_opt: ?[]const u8 = null;
    var namehash_opt: ?Hash = null;

    if (maybe_name) |name| {
        name_str_opt = if (name.name) |n| try self.allocator.dupe(u8, n) else null;
        namehash_opt = name.namehash;
        var name_copy = name;
        name_copy.deinit(self.allocator);
    }

    const event_name = if (name_str_opt) |n| try self.allocator.dupe(u8, n) else null;
    defer if (name_str_opt) |n| self.allocator.free(n);

    try utils.emitEvent(self, chain, log, .eac_roles_changed, event_name, namehash_opt, event_data);
}

/// Handle LabelRegistered events from PermissionedRegistry
/// Event: LabelRegistered(uint256 indexed tokenId, bytes32 indexed labelHash, string label, address owner, uint64 expiry, address indexed sender)
pub fn handleLabelRegistered(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    if (log.topics.len < 4) return error.InvalidTopicCount;

    const token_id_raw = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
    const token_id: u256 = token_id_raw;
    const token_id_utils = @import("../../types/token_id.zig");
    const canonical_id = token_id_utils.getCanonicalId(token_id);

    const label_hash = Hash{ .bytes = log.topics[2].bytes };
    const sender = try abi.ABI.decodeAddress(&log.topics[3].bytes, 0);

    const label_str = try abi.ABI.decodeString(self.allocator, log.data, 0);
    defer self.allocator.free(label_str);

    unicode.validateName(label_str) catch |err| {
        std.log.warn("Invalid name label '{s}' for tokenId={d}: {any}", .{ label_str, token_id, err });
        return;
    };

    const owner = try abi.ABI.decodeAddress(log.data, 32);
    const expiry: u64 = @truncate(try abi.ABI.decodeUint256(log.data, 64));

    // Detect if this registration was triggered by a migration controller (V1→V2 migration)
    const is_migration = self.isMigrationController(sender);

    std.log.debug("LabelRegistered: {s} (tokenId={d}, canonicalId={d}, owner={any}, expiry={d}, sender={any}, migrated={any})", .{ label_str, token_id, canonical_id, owner, expiry, sender, is_migration });

    const eth_registry = self.getEthRegistry(chain);
    const is_main_registry = log.address.eql(eth_registry);

    var parent_name: []const u8 = "eth";
    var parent_name_allocated = false;
    var parent_namehash: Hash = try @import("../../types/hash.zig").namehash(self.allocator, "eth");

    if (!is_main_registry) {
        const registry_hex = try log.address.toHex(self.allocator);
        defer self.allocator.free(registry_hex);

        var rq = try Query.init(self.database,
            \\SELECT name, namehash FROM registries
            \\WHERE address = ? AND chain = ? AND created_block <= ?
            \\ORDER BY created_block DESC
            \\LIMIT 1
        );
        defer rq.deinit();
        try rq.bindText(registry_hex);
        try rq.bindText(chain.toString());
        try rq.bindInt64(@intCast(log.block_number));

        if (try rq.step()) {
            if (rq.getTextSlice(0)) |name_span| {
                parent_name = try self.allocator.dupe(u8, name_span);
                parent_name_allocated = true;
            }
            if (rq.getTextSlice(1)) |namehash_hex| {
                parent_namehash = try Hash.fromHex(namehash_hex);
            }
        } else {
            std.log.debug("LabelRegistered: orphaning {s} - no parent found for subregistry {s} at block {d}", .{
                label_str, registry_hex, log.block_number,
            });
            try self.database.insertOrphanedRegistration(
                chain,
                registry_hex,
                token_id,
                label_str,
                expiry,
                owner,
                log.block_number,
                log.transaction_hash,
                log.log_index,
            );
            return;
        }
    }
    defer if (parent_name_allocated) self.allocator.free(parent_name);

    const full_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ label_str, parent_name });
    defer self.allocator.free(full_name);

    const namehash_val = try @import("../../types/hash.zig").namehash(self.allocator, full_name);

    const name_dup = try self.allocator.dupe(u8, full_name);
    defer self.allocator.free(name_dup);
    const label_dup = try self.allocator.dupe(u8, label_str);
    defer self.allocator.free(label_dup);
    const parent_name_dup = try self.allocator.dupe(u8, parent_name);
    defer self.allocator.free(parent_name_dup);

    const name = models.Name{
        .name = name_dup,
        .label = label_dup,
        .label_hash = label_hash,
        .parent_name = parent_name_dup,
        .parent_namehash = parent_namehash,
        .chain = chain,
        .registry = log.address,
        .owner = owner,
        .registrant = owner,
        .resolver = Address.zero,
        .token_id = token_id,
        .canonical_id = canonical_id,
        .token_version = token_id_utils.getTokenVersion(token_id),
        .namehash = namehash_val,
        .expiry = expiry,
        .registry_locked = false,
        .migrated = is_migration,
        .created_block = log.block_number,
        .created_at = self.getBlockTimestamp(chain, log.block_number, log.block_timestamp),
        .registered_at = self.getBlockTimestamp(chain, log.block_number, log.block_timestamp),
        .updated_block = log.block_number,
        .updated_at = self.getBlockTimestamp(chain, log.block_number, log.block_timestamp),
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    };

    try self.database.insertName(name);

    if (is_migration) {
        std.log.info("Migration detected: {s} migrated from V1→V2 (sender={any})", .{ full_name, sender });
    }

    const owner_hex = try owner.toHex(self.allocator);
    defer self.allocator.free(owner_hex);
    const registry_hex = try log.address.toHex(self.allocator);
    defer self.allocator.free(registry_hex);
    const sender_hex = try sender.toHex(self.allocator);
    defer self.allocator.free(sender_hex);

    const escaped_name = try json_utils.escapeString(self.allocator, full_name);
    defer self.allocator.free(escaped_name);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"name\":\"{s}\",\"tokenId\":{d},\"canonicalId\":{d},\"owner\":\"{s}\",\"expiry\":{d},\"sender\":\"{s}\",\"registry\":\"{s}\"}}", .{
        escaped_name,
        token_id,
        canonical_id,
        owner_hex,
        expiry,
        sender_hex,
        registry_hex,
    });

    const event_name = try self.allocator.dupe(u8, full_name);

    try utils.emitEvent(self, chain, log, .label_registered, event_name, namehash_val, event_data);
}

/// Handle LabelReserved events from PermissionedRegistry (when owner == 0)
/// Event: LabelReserved(uint256 indexed tokenId, bytes32 indexed labelHash, string label, uint64 expiry, address indexed sender)
pub fn handleLabelReserved(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    if (log.topics.len < 4) return error.InvalidTopicCount;

    const token_id_raw = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
    const token_id: u256 = token_id_raw;

    const label_hash = Hash{ .bytes = log.topics[2].bytes };
    const sender = try abi.ABI.decodeAddress(&log.topics[3].bytes, 0);

    const label_str = try abi.ABI.decodeString(self.allocator, log.data, 0);
    defer self.allocator.free(label_str);

    unicode.validateName(label_str) catch |err| {
        std.log.warn("Invalid name label '{s}' for tokenId={d}: {any}", .{ label_str, token_id, err });
        return;
    };

    const expiry: u64 = @truncate(try abi.ABI.decodeUint256(log.data, 32));

    std.log.debug("LabelReserved: {s} (tokenId={d}, expiry={d}, sender={any})", .{ label_str, token_id, expiry, sender });

    const eth_registry = self.getEthRegistry(chain);
    const is_main_registry = log.address.eql(eth_registry);

    var parent_name: []const u8 = "eth";
    var parent_name_allocated = false;
    var parent_namehash: Hash = try @import("../../types/hash.zig").namehash(self.allocator, "eth");

    if (!is_main_registry) {
        const registry_hex = try log.address.toHex(self.allocator);
        defer self.allocator.free(registry_hex);

        var rq = try Query.init(self.database,
            \\SELECT name, namehash FROM registries
            \\WHERE address = ? AND chain = ? AND created_block <= ?
            \\ORDER BY created_block DESC
            \\LIMIT 1
        );
        defer rq.deinit();
        try rq.bindText(registry_hex);
        try rq.bindText(chain.toString());
        try rq.bindInt64(@intCast(log.block_number));

        if (try rq.step()) {
            if (rq.getTextSlice(0)) |name_span| {
                parent_name = try self.allocator.dupe(u8, name_span);
                parent_name_allocated = true;
            }
            if (rq.getTextSlice(1)) |namehash_hex| {
                parent_namehash = try Hash.fromHex(namehash_hex);
            }
        }
    }
    defer if (parent_name_allocated) self.allocator.free(parent_name);

    const full_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ label_str, parent_name });
    defer self.allocator.free(full_name);

    const namehash_val = try @import("../../types/hash.zig").namehash(self.allocator, full_name);

    const name_dup = try self.allocator.dupe(u8, full_name);
    defer self.allocator.free(name_dup);
    const label_dup = try self.allocator.dupe(u8, label_str);
    defer self.allocator.free(label_dup);
    const parent_name_dup = try self.allocator.dupe(u8, parent_name);
    defer self.allocator.free(parent_name_dup);

    const token_id_utils = @import("../../types/token_id.zig");
    const canonical_id = token_id_utils.getCanonicalId(token_id);

    const name = models.Name{
        .name = name_dup,
        .label = label_dup,
        .label_hash = label_hash,
        .parent_name = parent_name_dup,
        .parent_namehash = parent_namehash,
        .chain = chain,
        .registry = log.address,
        .owner = Address.zero,
        .registrant = Address.zero,
        .resolver = Address.zero,
        .token_id = token_id,
        .canonical_id = canonical_id,
        .token_version = token_id_utils.getTokenVersion(token_id),
        .namehash = namehash_val,
        .expiry = expiry,
        .registry_locked = false,
        .migrated = false,
        .created_block = log.block_number,
        .created_at = self.getBlockTimestamp(chain, log.block_number, log.block_timestamp),
        .registered_at = self.getBlockTimestamp(chain, log.block_number, log.block_timestamp),
        .updated_block = log.block_number,
        .updated_at = self.getBlockTimestamp(chain, log.block_number, log.block_timestamp),
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    };

    try self.database.insertName(name);

    const sender_hex = try sender.toHex(self.allocator);
    defer self.allocator.free(sender_hex);
    const registry_hex = try log.address.toHex(self.allocator);
    defer self.allocator.free(registry_hex);

    const escaped_name = try json_utils.escapeString(self.allocator, full_name);
    defer self.allocator.free(escaped_name);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"name\":\"{s}\",\"tokenId\":{d},\"expiry\":{d},\"sender\":\"{s}\",\"registry\":\"{s}\",\"reserved\":true}}", .{
        escaped_name,
        token_id,
        expiry,
        sender_hex,
        registry_hex,
    });

    const event_name = try self.allocator.dupe(u8, full_name);

    try utils.emitEvent(self, chain, log, .label_reserved, event_name, namehash_val, event_data);
}

/// Handle LabelUnregistered events from PermissionedRegistry
/// Event: LabelUnregistered(uint256 indexed tokenId, address indexed sender)
pub fn handleLabelUnregistered(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    if (log.topics.len < 3) return error.InvalidTopicCount;

    const token_id_raw = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
    const token_id: u256 = token_id_raw;

    const sender = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);

    std.log.debug("LabelUnregistered: tokenId={d}, sender={any}", .{ token_id, sender });

    const maybe_name = try self.database.getNameByTokenIdAndRegistry(token_id, log.address);

    var name_str: []const u8 = undefined;
    var namehash_opt: ?Hash = null;

    if (maybe_name) |n| {
        try self.database.deleteNameByNamehash(n.namehash);
        name_str = try self.allocator.dupe(u8, n.name orelse "[unknown]");
        namehash_opt = n.namehash;
        var name_copy = n;
        name_copy.deinit(self.allocator);
    } else {
        name_str = try std.fmt.allocPrint(self.allocator, "tokenId:{d}", .{token_id});
    }
    defer self.allocator.free(name_str);

    const sender_hex = try sender.toHex(self.allocator);
    defer self.allocator.free(sender_hex);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"tokenId\":{d},\"sender\":\"{s}\"}}", .{
        token_id,
        sender_hex,
    });

    const event_name = try self.allocator.dupe(u8, name_str);

    try utils.emitEvent(self, chain, log, .label_unregistered, event_name, namehash_opt, event_data);
}

/// Handle ExpiryUpdated events from PermissionedRegistry (replaces NameRenewed)
/// Event: ExpiryUpdated(uint256 indexed tokenId, uint64 indexed newExpiry, address indexed sender)
pub fn handleExpiryUpdated(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    if (log.topics.len < 4) return error.InvalidTopicCount;

    const token_id_raw = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
    const token_id: u256 = token_id_raw;

    const new_expiry_raw = try abi.ABI.decodeUint256(&log.topics[2].bytes, 0);
    const new_expiry: u64 = @truncate(new_expiry_raw);

    const sender = try abi.ABI.decodeAddress(&log.topics[3].bytes, 0);

    std.log.debug("ExpiryUpdated: tokenId={d}, newExpiry={d}, sender={any}", .{ token_id, new_expiry, sender });

    const maybe_name = try self.database.getNameByTokenIdAndRegistry(token_id, log.address);

    var name_str: []const u8 = undefined;
    var namehash_opt: ?Hash = null;

    if (maybe_name) |n| {
        try self.database.updateNameExpiry(n.namehash, new_expiry);
        name_str = try self.allocator.dupe(u8, n.name orelse "[unknown]");
        namehash_opt = n.namehash;
        var name_copy = n;
        name_copy.deinit(self.allocator);
    } else {
        name_str = try std.fmt.allocPrint(self.allocator, "tokenId:{d}", .{token_id});
    }
    defer self.allocator.free(name_str);

    const sender_hex = try sender.toHex(self.allocator);
    defer self.allocator.free(sender_hex);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"tokenId\":{d},\"newExpiry\":{d},\"sender\":\"{s}\"}}", .{
        token_id,
        new_expiry,
        sender_hex,
    });

    const event_name = try self.allocator.dupe(u8, name_str);

    try utils.emitEvent(self, chain, log, .expiry_updated, event_name, namehash_opt, event_data);
}

/// Handle ParentUpdated events from PermissionedRegistry
/// Event: ParentUpdated(IRegistry indexed parent, string label, address indexed sender)
pub fn handleParentUpdated(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    if (log.topics.len < 3) return error.InvalidTopicCount;

    const parent_addr = try abi.ABI.decodeAddress(&log.topics[1].bytes, 0);
    const sender = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);

    const label_str = try abi.ABI.decodeString(self.allocator, log.data, 0);
    defer self.allocator.free(label_str);

    std.log.debug("ParentUpdated: parent={any}, label={s}, sender={any}", .{ parent_addr, label_str, sender });

    const parent_hex = try parent_addr.toHex(self.allocator);
    defer self.allocator.free(parent_hex);
    const sender_hex = try sender.toHex(self.allocator);
    defer self.allocator.free(sender_hex);

    const escaped_label = try json_utils.escapeString(self.allocator, label_str);
    defer self.allocator.free(escaped_label);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"parent\":\"{s}\",\"label\":\"{s}\",\"sender\":\"{s}\"}}", .{
        parent_hex,
        escaped_label,
        sender_hex,
    });

    const event_name = try self.allocator.dupe(u8, label_str);

    try utils.emitEvent(self, chain, log, .parent_updated, event_name, null, event_data);
}

/// Handle SubregistryUpdated events from PermissionedRegistry (NEW signature)
/// Event: SubregistryUpdated(uint256 indexed tokenId, IRegistry indexed subregistry, address indexed sender)
/// Note: Different from SubregistryUpdate - uses indexed IRegistry instead of non-indexed address
pub fn handleSubregistryUpdated(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    if (log.topics.len < 4) return error.InvalidTopicCount;

    const token_id_raw = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
    const token_id: u256 = token_id_raw;
    const token_id_utils = @import("../../types/token_id.zig");
    const canonical_id = token_id_utils.getCanonicalId(token_id);

    const subregistry_addr = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);
    const sender = try abi.ABI.decodeAddress(&log.topics[3].bytes, 0);

    std.log.debug("SubregistryUpdated: tokenId={d}, canonicalId={d}, subregistry={any}, sender={any}", .{ token_id, canonical_id, subregistry_addr, sender });

    if (subregistry_addr.isZero()) {
        std.log.debug("  → Skipping zero address subregistry", .{});
        return;
    }

    const maybe_name = try self.database.getNameByTokenIdAndRegistry(token_id, log.address);
    const name_str = if (maybe_name) |n| blk: {
        var name_copy = n;
        defer name_copy.deinit(self.allocator);
        break :blk try self.allocator.dupe(u8, name_copy.name orelse "[unknown]");
    } else try std.fmt.allocPrint(self.allocator, "canonicalId:{d}", .{canonical_id});
    defer self.allocator.free(name_str);

    const namehash = if (maybe_name) |n| n.namehash else Hash.zero;

    const registry = models.Registry{
        .address = subregistry_addr,
        .chain = chain,
        .name = name_str,
        .namehash = namehash,
        .parent_registry = log.address,
        .created_block = log.block_number,
        .created_at = self.getBlockTimestamp(chain, log.block_number, log.block_timestamp),
    };

    try self.database.insertRegistry(registry);

    const subreg_hex = try subregistry_addr.toHex(self.allocator);
    defer self.allocator.free(subreg_hex);
    const contract_hex = try log.address.toHex(self.allocator);
    defer self.allocator.free(contract_hex);
    const sender_hex = try sender.toHex(self.allocator);
    defer self.allocator.free(sender_hex);

    const escaped_name = try json_utils.escapeString(self.allocator, name_str);
    defer self.allocator.free(escaped_name);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"name\":\"{s}\",\"canonicalId\":{d},\"subregistry\":\"{s}\",\"registry\":\"{s}\",\"sender\":\"{s}\"}}", .{
        escaped_name,
        canonical_id,
        subreg_hex,
        contract_hex,
        sender_hex,
    });

    const event_name = try self.allocator.dupe(u8, name_str);

    try utils.emitEvent(self, chain, log, .subregistry_updated, event_name, namehash, event_data);
}

/// Handle ResolverUpdated events from PermissionedRegistry (NEW signature)
/// Event: ResolverUpdated(uint256 indexed tokenId, address indexed resolver, address indexed sender)
/// Note: Different from ResolverUpdate - uses indexed address
pub fn handleResolverUpdated(self: *Indexer, chain: models.Chain, log: rpc.Log) !void {
    if (log.topics.len < 4) return error.InvalidTopicCount;

    const token_id_raw = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
    const token_id: u256 = token_id_raw;

    const resolver_addr = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);
    const sender = try abi.ABI.decodeAddress(&log.topics[3].bytes, 0);

    std.log.debug("ResolverUpdated: tokenId={d}, resolver={any}, sender={any}", .{ token_id, resolver_addr, sender });

    // Register the resolver for record indexing
    const resolver_hex = try resolver_addr.toHex(self.allocator);
    defer self.allocator.free(resolver_hex);
    try self.database.registerResolver(chain, resolver_hex, log.block_number);

    const maybe_name = try self.database.getNameByTokenIdAndRegistry(token_id, log.address);

    var name_str: []const u8 = undefined;
    var namehash_opt: ?Hash = null;

    if (maybe_name) |n| {
        try self.database.updateNameResolver(n.namehash, resolver_addr);
        name_str = try self.allocator.dupe(u8, n.name orelse "[unknown]");
        namehash_opt = n.namehash;
        var name_copy = n;
        name_copy.deinit(self.allocator);
    } else {
        name_str = try std.fmt.allocPrint(self.allocator, "tokenId:{d}", .{token_id});
    }
    defer self.allocator.free(name_str);

    const sender_hex = try sender.toHex(self.allocator);
    defer self.allocator.free(sender_hex);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"tokenId\":{d},\"resolver\":\"{s}\",\"sender\":\"{s}\"}}", .{
        token_id,
        resolver_hex,
        sender_hex,
    });

    const event_name = try self.allocator.dupe(u8, name_str);

    try utils.emitEvent(self, chain, log, .resolver_updated, event_name, namehash_opt, event_data);
}

