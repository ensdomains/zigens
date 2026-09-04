const std = @import("std");
const zsys = @import("../../utils/system.zig");
const ens_name = @import("../../utils/ens_name.zig");
const models = @import("../../types/models.zig");
// ABI decoding migrated from hand-rolled `../abi.zig` to eth.zig-backed
// `../abi_eth.zig`. The old module is kept for fallback. EventSignatures still
// lives in abi.zig and is imported separately where needed.
const abi = @import("../abi_eth.zig");
const rpc = @import("../../rpc/client.zig");
const db = @import("../../storage/database.zig");
const Query = db.Query;
const Hash = @import("../../types/hash.zig").Hash;
const Address = @import("../../types/address.zig").Address;
const Indexer = @import("../indexer.zig").Indexer;
const utils = @import("../utils.zig");
const registry_entries = @import("../../storage/registry_entries.zig");
const json_utils = @import("../../utils/json.zig");
const unknown_labels_storage = @import("../../storage/unknown_labels.zig");
const label_backfill = @import("../label_backfill.zig");

// `handleSubregistryUpdate` (2-arg `SubregistryUpdate(uint256,address)`) was
// removed in the post-audit cleanup — the fresh-Sepolia contracts only emit
// the 3-arg `SubregistryUpdated(uint256,address,address)` variant, handled
// below by `handleSubregistryUpdated`.
/// Process an orphaned registration now that we know its parent
pub fn processOrphanedRegistration(
    self: *Indexer,
    protocol: models.Protocol,
    orphan: db.Database.OrphanedRegistration,
    parent_name: []const u8,
    parent_namehash: Hash,
    subregistry_addr: Address,
) !void {
    const hash_mod = @import("../../types/hash.zig");
    const token_id_utils = @import("../../types/token_id.zig");

    const full_name = try ens_name.join(self.allocator, orphan.label, parent_name);
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
        .protocol = protocol,
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
        .created_at = try self.getBlockTimestamp(protocol, orphan.block_number, null),
        .registered_at = try self.getBlockTimestamp(protocol, orphan.block_number, null),
        .updated_block = orphan.block_number,
        .updated_at = try self.getBlockTimestamp(protocol, orphan.block_number, null),
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    };

    try self.insertName(name);

    // Store event
    var owner_hex_buf: [42]u8 = undefined;
    const owner_hex = orphan.owner.toHexBuf(&owner_hex_buf);
    var registry_hex_buf: [42]u8 = undefined;
    const registry_hex = subregistry_addr.toHexBuf(&registry_hex_buf);

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
        .protocol = protocol,
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
pub fn processRemainingOrphans(self: *Indexer, protocol: models.Protocol) !void {

    // Query all orphaned registrations that now have a valid parent
    // A valid parent is one where the registry's created_block <= orphan's block_number
    const sql =
        \\SELECT o.subregistry_address, o.token_id, o.label, o.expiry, o.owner,
        \\       o.block_number, o.tx_hash, o.log_index,
        \\       r.name as parent_name, r.namehash as parent_namehash, r.address as registry_addr
        \\FROM orphaned_registrations o
        \\INNER JOIN registries r ON r.protocol = o.protocol AND r.address = o.subregistry_address
        \\WHERE o.protocol = ? AND r.created_block <= o.block_number
        \\ORDER BY o.block_number ASC
    ;

    var oq = try Query.initCached(self.database, sql);
    defer oq.deinit();
    try oq.bindText(protocol.toString());

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
            .protocol = protocol,
            .subregistry_address = subregistry_addr_str,
            .token_id = token_id,
            .label = label,
            .expiry = expiry,
            .owner = owner,
            .block_number = block_number,
            .tx_hash = tx_hash,
            .log_index = log_index,
        };

        self.processOrphanedRegistration(protocol, orphan, parent_name, parent_namehash, subregistry_addr) catch |err| {
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
            try self.database.deleteOrphanedRegistrations(protocol, addr.*);
        }
    }
}

// `handleResolverUpdate` (2-arg `ResolverUpdate(uint256,address)`) was removed
// in the post-audit cleanup — the fresh-Sepolia contracts only emit the 3-arg
// `ResolverUpdated(uint256,address,address)` variant, handled below by
// `handleResolverUpdated`. The Resolver-entity upsert (subgraph parity) lives
// on that handler too, so no functionality is lost.

pub fn handleNameRegistered(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    // V2 Event: NameRegistered(uint256 indexed tokenId, string label, uint64 expiration, address registeredBy)
    if (log.topics.len < 2) return error.InvalidTopicCount;

    // Topics[0] = event signature
    // Topics[1] = indexed tokenId
    const token_id_raw = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
    const token_id: u256 = token_id_raw;

    // Non-indexed payload: (string label, uint64 expiration, address registeredBy)
    const data_values = try abi.decodeValues(
        log.data,
        &.{ .string, .uint64, .address },
        self.allocator,
    );
    defer abi.freeValues(data_values, self.allocator);
    const label_str = data_values[0].string;
    const expiration: u256 = data_values[1].uint256;
    const registered_by = Address{ .bytes = data_values[2].address };

    ens_name.validateLabel(label_str) catch |err| {
        std.log.warn("Invalid name label '{s}' for tokenId={d}: {any}", .{ label_str, token_id, err });
        return;
    };

    std.log.debug("NameRegistered: {s} (tokenId={d}, expiration={d}, registeredBy={any})", .{ label_str, token_id, expiration, registered_by });

    utils.recordAccountObservation(self, protocol, registered_by, log);

    // Determine parent name based on registry address
    // If from main .eth registry, parent is "eth". Otherwise look up subregistry parent.
    const eth_registry = self.getEthRegistry(protocol);
    const is_main_registry = log.address.eql(eth_registry);

    var parent_name: []const u8 = "eth";
    var parent_name_allocated = false;
    var parent_namehash: Hash = self.eth_namehash;

    if (!is_main_registry) {
        // This is a subregistry - look up the parent name from registries table
        // We query for the parent that was active at this event's block number
        // (the most recent SubregistryUpdate before or at this block)
        var registry_hex_buf: [42]u8 = undefined;
        const registry_hex = log.address.toHexBuf(&registry_hex_buf);

        // A subregistry contract can be re-pointed to a different parent via setSubregistry
        // (the "one subregistry per name" invariant is only a VerifiableFactory deployment
        // practice, not a protocol guarantee). Take the most recent assignment and warn if
        // more than one exists — see handleLabelRegistered for the matching logic.
        var rq = try Query.initCached(self.database,
            \\SELECT name, namehash FROM registries
            \\WHERE address = ? AND protocol = ? AND created_block <= ?
            \\ORDER BY created_block DESC
            \\LIMIT 2
        );
        defer rq.deinit();
        try rq.bindText(registry_hex);
        try rq.bindText(protocol.toString());
        try rq.bindInt64(@intCast(log.block_number));

        if (try rq.step()) {
            if (rq.getTextSlice(0)) |name_span| {
                parent_name = try self.allocator.dupe(u8, name_span);
                parent_name_allocated = true;
            }

            if (rq.getTextSlice(1)) |namehash_hex| {
                parent_namehash = try Hash.fromHex(namehash_hex);
            }

            if (try rq.step()) {
                warnIfLiveMultiParent(self, protocol, registry_hex, log.block_number);
            }
        } else {
            // No parent found for this subregistry at this block
            // Store as orphaned registration - will be processed when parent claims subregistry
            std.log.debug("NameRegistered: orphaning {s} - no parent found for subregistry {s} at block {d}", .{
                label_str, registry_hex, log.block_number,
            });
            try self.database.insertOrphanedRegistration(
                protocol,
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

    const full_name = try ens_name.join(self.allocator, label_str, parent_name);
    defer self.allocator.free(full_name);
    const namehash = try @import("../../types/hash.zig").namehash(self.allocator, full_name);

    // Compute label hash
    const label_hash = try @import("../../types/hash.zig").keccak256(self.allocator, label_str);

    // Extract canonical_id and version from token_id
    const token_id_utils = @import("../../types/token_id.zig");
    const canonical_id = token_id_utils.getCanonicalId(token_id);
    const token_version = token_id_utils.getTokenVersion(token_id);

    const name_str_dup = try self.allocator.dupe(u8, full_name);
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
        .protocol = protocol,
        .registry = log.address, // Use the actual registry that emitted the event
        .owner = registered_by,
        .registrant = registered_by, // Original registrant from NameRegistered event
        .resolver = Address.zero,
        .token_id = @intCast(token_id),
        .canonical_id = canonical_id,
        .token_version = token_version,
        .expiry = @truncate(expiration),
        .registry_locked = false,
        // V1→V2 migrations flow through handleLabelRegistered (indexed `sender` is checked
        // against migration controllers there). V2 NameRegistered has no sender topic, so
        // names created via this path are always fresh V2 registrations.
        .migrated = false,
        .created_block = log.block_number,
        .created_at = try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
        .registered_at = try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
        .updated_block = log.block_number,
        .updated_at = zsys.timestamp(),
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    };

    try self.insertName(name);

    // Log-index-ordered dispatch means SubregistryUpdated/ResolverUpdated for a newly-minted
    // name can be processed before LabelRegistered/NameRegistered (the on-protocol tx emits them
    // in that order). Those earlier handlers store placeholder rows keyed by canonicalId/tokenId;
    // now that the real name is known, patch them.
    // Stack buffers — u256 max is 78 decimal digits, prefix is "canonicalId:"/"tokenId:".
    var canonical_buf: [96]u8 = undefined;
    const canonical_placeholder = try std.fmt.bufPrint(&canonical_buf, "canonicalId:{d}", .{canonical_id});
    _ = self.database.updateRegistryPlaceholderName(canonical_placeholder, full_name, namehash) catch |err| {
        std.log.warn("Failed to patch canonicalId placeholder: {}", .{err});
    };
    var tokenid_buf: [96]u8 = undefined;
    const tokenid_placeholder = try std.fmt.bufPrint(&tokenid_buf, "tokenId:{d}", .{token_id});
    _ = self.database.updatePlaceholderEventsByName(tokenid_placeholder, full_name, namehash) catch |err| {
        std.log.warn("Failed to patch tokenId placeholder: {}", .{err});
    };

    // Catch up names.resolver from any ResolverUpdated event that fired before
    // this LabelRegistered (chain emit order is ResolverUpdated → LabelRegistered
    // for fresh registrations; the earlier handler couldn't write because the
    // namehash wasn't linked yet). Must run AFTER updatePlaceholderEventsByName
    // above — that's what gives the prior event row its real namehash so the
    // catch-up's lookup-by-namehash actually finds it.
    self.database.applyLatestResolverFromEvents(protocol, namehash) catch |err| {
        std.log.warn("Failed to backfill resolver for {s}: {}", .{ full_name, err });
    };

    // Store event
    var nh_hex_buf: [66]u8 = undefined;
    const nh_hex = namehash.toHexBuf(&nh_hex_buf);
    var owner_hex_buf: [42]u8 = undefined;
    const owner_hex = registered_by.toHexBuf(&owner_hex_buf);

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

    const event_name = try ens_name.join(self.allocator, label_str, parent_name);

    // event_data and event_name transfer to emitEvent, which is their sole owner
    // (insertEventAndNotify frees both on every path) — no errdefer here, matching
    // every other emit site in this file; an errdefer would double-free on a DB error.
    try utils.emitEvent(self, protocol, log, .name_registered, event_name, namehash, event_data);
}

pub fn handleNameRenewed(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    // V2 Event: NameRenewed(uint256 indexed tokenId, uint64 newExpiration, address renewedBy)
    if (log.topics.len < 2) return error.InvalidTopicCount;

    // Topics[0] = event signature
    // Topics[1] = indexed tokenId
    const token_id_raw = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
    const token_id: u256 = token_id_raw;
    const token_id_utils_renew = @import("../../types/token_id.zig");
    const canonical_id = token_id_utils_renew.getCanonicalId(token_id);

    // Non-indexed payload: (uint64 newExpiration, address renewedBy)
    const data_values = try abi.decodeValues(
        log.data,
        &.{ .uint64, .address },
        self.allocator,
    );
    defer abi.freeValues(data_values, self.allocator);
    const new_expiration: u256 = data_values[0].uint256;
    const renewed_by = Address{ .bytes = data_values[1].address };

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

    try utils.emitEvent(self, protocol, log, .name_renewed, event_name, namehash, event_data);
}

pub fn handleTransfer(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    // Event: TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value)
    if (log.topics.len < 4) return error.InvalidTopicCount;

    const operator = try abi.ABI.decodeAddress(&log.topics[1].bytes, 0);
    const from = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);
    const to = try abi.ABI.decodeAddress(&log.topics[3].bytes, 0);

    // Non-indexed payload: (uint256 id, uint256 value)
    const data_values = try abi.decodeValues(
        log.data,
        &.{ .uint256, .uint256 },
        self.allocator,
    );
    defer abi.freeValues(data_values, self.allocator);
    const id = data_values[0].uint256;
    const value = data_values[1].uint256;

    std.log.debug("Transfer: from={any}, to={any}, id={d}, value={d}", .{ from, to, id, value });

    utils.recordAccountObservation(self, protocol, to, log);

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
        // With log-index ordering (utils.dispatchOrdered) a Transfer always arrives after its
        // LabelRegistered/NameRegistered, so this branch should only fire on reorgs, backfill
        // gaps, or genuinely orphaned transfers (non-ENS ERC1155 tokens slipping through the
        // topic-only filter). The event is still emitted for audit; ownership just can't be
        // applied without a known name.
        std.log.warn("  → Transfer for unknown tokenId={d} in registry {any}; ownership not updated", .{ id, log.address });
    }

    defer if (name_str_opt) |n| self.allocator.free(n);

    // Store event
    var operator_hex_buf: [42]u8 = undefined;
    const operator_hex = operator.toHexBuf(&operator_hex_buf);
    var from_hex_buf: [42]u8 = undefined;
    const from_hex = from.toHexBuf(&from_hex_buf);
    var to_hex_buf: [42]u8 = undefined;
    const to_hex = to.toHexBuf(&to_hex_buf);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"operator\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"id\":{d},\"value\":{d}}}", .{
        operator_hex,
        from_hex,
        to_hex,
        id,
        value,
    });

    const event_name = if (name_str_opt) |n| try self.allocator.dupe(u8, n) else null;

    try utils.emitEvent(self, protocol, log, .transfer, event_name, namehash_opt, event_data);
}

// =============================================================================
// ETH Registrar Extended Event Handlers (L2 specific)
// =============================================================================

pub fn handleETHNameRegistered(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    // IETHRegistrar.NameRegistered(uint256 indexed tokenId, string label, address owner, IRegistry subregistry, address resolver, uint64 duration, IERC20 paymentToken, bytes32 referrer, uint256 base, uint256 premium)
    if (log.topics.len < 2) return error.InvalidTopicCount;

    const token_id_raw = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
    const token_id: u256 = token_id_raw;

    // Non-indexed payload: (string label, address owner, address subregistry,
    // address resolver, uint64 duration, address paymentToken, bytes32 referrer,
    // uint256 base, uint256 premium)
    const data_values = try abi.decodeValues(
        log.data,
        &.{ .string, .address, .address, .address, .uint64, .address, .bytes32, .uint256, .uint256 },
        self.allocator,
    );
    defer abi.freeValues(data_values, self.allocator);
    const label_str = data_values[0].string;
    const owner = Address{ .bytes = data_values[1].address };
    const subregistry = Address{ .bytes = data_values[2].address };
    const resolver = Address{ .bytes = data_values[3].address };
    const duration: u256 = data_values[4].uint256;
    const payment_token = Address{ .bytes = data_values[5].address };
    const referrer = Hash{ .bytes = data_values[6].fixed_bytes.data };
    const base_price = data_values[7].uint256;
    const premium = data_values[8].uint256;

    ens_name.validateLabel(label_str) catch |err| {
        std.log.warn("Invalid name label '{s}' for tokenId={d}: {any}", .{ label_str, token_id, err });
        return;
    };

    std.log.debug("ETHRegistrar.NameRegistered: {s} (tokenId={d}, owner={any}, duration={d}, base={d}, premium={d})", .{ label_str, token_id, owner, duration, base_price, premium });

    utils.recordAccountObservation(self, protocol, owner, log);

    // Compute namehash
    const full_name = try std.fmt.allocPrint(self.allocator, "{s}.eth", .{label_str});
    defer self.allocator.free(full_name);
    const namehash = try @import("../../types/hash.zig").namehash(self.allocator, full_name);
    const label_hash = try @import("../../types/hash.zig").keccak256(self.allocator, label_str);

    // Calculate expiry from registration block timestamp + duration
    const block_timestamp = try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp);
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
        .parent_namehash = self.eth_namehash,
        .protocol = protocol,
        .registry = self.getEthRegistry(protocol),
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
        .created_at = try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
        .registered_at = try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
        .updated_block = log.block_number,
        .updated_at = zsys.timestamp(),
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    };

    try self.insertName(name);

    // If subregistry was deployed at registration, store it in the registries table
    if (!subregistry.isZero()) {
        const registry_entry = models.Registry{
            .address = subregistry,
            .protocol = protocol,
            .name = full_name,
            .namehash = namehash,
            .parent_registry = self.getEthRegistry(protocol),
            .created_block = log.block_number,
            .created_at = try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
        };
        self.database.insertRegistry(registry_entry) catch |err| {
            std.log.warn("Failed to insert subregistry for {s}: {any}", .{ full_name, err });
        };
        std.log.debug("  → Registered subregistry {any} for {s}", .{ subregistry, full_name });
    }

    // Intentionally NOT writing to the `registrations` table here. On V2, every
    // fresh `.eth` registration emits TWO events in the same tx: this
    // `IETHRegistrar.NameRegistered` (carrying payment details) AND the
    // `PermissionedRegistry.LabelRegistered` (the canonical "label exists"
    // signal). Writing both would produce 2 rows per name. The
    // LabelRegistered handler (handleLabelRegistered) is the single canonical
    // writer for the registrations table.
    //
    // Instead, enrich the LabelRegistered-written row with controller-side
    // economics (baseCost, premium, label preimage, referrer) so they're
    // first-class on the Registration entity. Ordering caveat: if this
    // event happens to be processed before LabelRegistered in the chunk,
    // the UPDATE no-ops; updateRegistrationEconomics logs that at debug.
    self.database.updateRegistrationEconomics(
        protocol,
        namehash,
        label_str,
        base_price,
        premium,
        referrer,
    ) catch |err| {
        std.log.debug("updateRegistrationEconomics failed: {} (row may not yet exist)", .{err});
    };

    // Store event with payment details
    var payment_token_hex_buf: [42]u8 = undefined;
    const payment_token_hex = payment_token.toHexBuf(&payment_token_hex_buf);
    var referrer_hex_buf: [66]u8 = undefined;
    const referrer_hex = referrer.toHexBuf(&referrer_hex_buf);

    // Escape label_str for safe JSON inclusion
    const escaped_label = try json_utils.escapeString(self.allocator, label_str);
    defer self.allocator.free(escaped_label);

    var owner_hex_buf: [42]u8 = undefined;
    const owner_hex = owner.toHexBuf(&owner_hex_buf);

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

    try utils.emitEvent(self, protocol, log, .name_registered, event_name, namehash, event_data);
}

pub fn handleETHNameRenewed(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    // IETHRegistrar.NameRenewed(uint256 indexed tokenId, string label, uint64 duration, uint64 newExpiry, IERC20 paymentToken, bytes32 referrer, uint256 base)
    if (log.topics.len < 2) return error.InvalidTopicCount;

    const token_id_raw = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
    const token_id: u256 = token_id_raw;
    const token_id_utils_eth_renew = @import("../../types/token_id.zig");
    const canonical_id = token_id_utils_eth_renew.getCanonicalId(token_id);

    // Non-indexed payload: (string label, uint64 duration, uint64 newExpiry,
    // address paymentToken, bytes32 referrer, uint256 base)
    const data_values = try abi.decodeValues(
        log.data,
        &.{ .string, .uint64, .uint64, .address, .bytes32, .uint256 },
        self.allocator,
    );
    defer abi.freeValues(data_values, self.allocator);
    const label_str = data_values[0].string;
    const duration: u256 = data_values[1].uint256;
    const new_expiry: u256 = data_values[2].uint256;
    const payment_token = Address{ .bytes = data_values[3].address };
    const referrer = Hash{ .bytes = data_values[4].fixed_bytes.data };
    const base_price = data_values[5].uint256;

    ens_name.validateLabel(label_str) catch |err| {
        std.log.warn("Invalid name label '{s}' for tokenId={d}: {any}", .{ label_str, token_id, err });
        return;
    };

    std.log.debug("ETHRegistrar.NameRenewed: {s} (tokenId={d}, canonicalId={d}, duration={d}, newExpiry={d}, base={d})", .{ label_str, token_id, canonical_id, duration, new_expiry, base_price });

    // Look up the name by token_id AND the .eth registry (NOT log.address, which is the registrar)
    const eth_registry = self.getEthRegistry(protocol);
    const maybe_name = try self.database.getNameByTokenIdAndRegistry(token_id, eth_registry);

    // Update expiry using namehash (scoped to the correct name)
    if (maybe_name) |name| {
        try self.database.updateNameExpiry(name.namehash, @truncate(new_expiry));
    }

    // Store event with payment details
    var payment_token_hex_buf: [42]u8 = undefined;
    const payment_token_hex = payment_token.toHexBuf(&payment_token_hex_buf);
    var referrer_hex_buf: [66]u8 = undefined;
    const referrer_hex = referrer.toHexBuf(&referrer_hex_buf);

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

    try utils.emitEvent(self, protocol, log, .name_renewed, event_name, namehash, event_data);
}

pub fn handleCommitmentMade(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    // CommitmentMade(bytes32 commitment)
    // Note: bytes32 is NOT indexed, so it's in the data field
    if (log.topics.len < 1) return error.InvalidTopicCount;

    // Non-indexed payload: (bytes32 commitment)
    const data_values = try abi.decodeValues(log.data, &.{.bytes32}, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const commitment = Hash{ .bytes = data_values[0].fixed_bytes.data };

    std.log.debug("CommitmentMade: commitment={any}", .{commitment});

    // Store event
    var commitment_hex_buf: [66]u8 = undefined;
    const commitment_hex = commitment.toHexBuf(&commitment_hex_buf);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"commitment\":\"{s}\"}}", .{commitment_hex});

    try utils.emitEvent(self, protocol, log, .commitment_made, null, null, event_data);
}

pub fn handleNameBurned(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    // NameBurned(uint256 indexed tokenId, address burnedBy)
    if (log.topics.len < 2) return error.InvalidTopicCount;

    const token_id_raw = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
    const token_id: u256 = token_id_raw;
    const token_id_utils_burn = @import("../../types/token_id.zig");
    const canonical_id = token_id_utils_burn.getCanonicalId(token_id);

    // Non-indexed payload: (address burnedBy)
    const data_values = try abi.decodeValues(log.data, &.{.address}, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const burned_by = Address{ .bytes = data_values[0].address };

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
    var burned_by_hex_buf: [42]u8 = undefined;
    const burned_by_hex = burned_by.toHexBuf(&burned_by_hex_buf);

    // Escape name_str for safe JSON inclusion
    const escaped_name = try json_utils.escapeString(self.allocator, name_str);
    defer self.allocator.free(escaped_name);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"tokenId\":{d},\"name\":\"{s}\",\"burnedBy\":\"{s}\"}}", .{
        token_id,
        escaped_name,
        burned_by_hex,
    });

    const event_name = try self.allocator.dupe(u8, name_str);

    try utils.emitEvent(self, protocol, log, .name_burned, event_name, namehash, event_data);

    // Delete the burned name using namehash (registry-safe: only deletes the exact name)
    // Cannot use canonical_id because it collides across registries (e.g., tester.eth and tester.calendars.eth)
    if (!namehash.eql(Hash.zero)) {
        try self.database.deleteNameByNamehash(namehash);
        std.log.debug("Deleted burned name from database: {s}", .{name_str});
    } else {
        std.log.warn("Cannot delete burned name - unknown namehash for tokenId={d}", .{token_id});
    }
}

pub fn handleTokenRegenerated(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    // TokenRegenerated(uint256 oldTokenId, uint256 newTokenId)
    // Parameters may be indexed (in topics) or non-indexed (in data)
    var old_token_id: u256 = undefined;
    var new_token_id: u256 = undefined;

    if (log.topics.len >= 3) {
        // Both parameters are indexed (in topics)
        old_token_id = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
        new_token_id = try abi.ABI.decodeUint256(&log.topics[2].bytes, 0);
    } else if (log.data.len >= 64) {
        // Non-indexed payload: (uint256 oldTokenId, uint256 newTokenId)
        const data_values = try abi.decodeValues(
            log.data,
            &.{ .uint256, .uint256 },
            self.allocator,
        );
        defer abi.freeValues(data_values, self.allocator);
        old_token_id = data_values[0].uint256;
        new_token_id = data_values[1].uint256;
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

    try utils.emitEvent(self, protocol, log, .token_regenerated, event_name, namehash, event_data);

    // Update token_id in database from old to new (registry-safe: only updates the exact name)
    // Cannot use old_token_id alone because it collides across registries
    if (!namehash.eql(Hash.zero)) {
        try self.database.updateNameTokenIdByNamehash(namehash, new_token_id);
        std.log.debug("Updated token_id in database: {d} -> {d} for {s}", .{ old_token_id, new_token_id, name_str });

        // Note: eac_roles.resource carries the EAC version (bumped on unregister /
        // re-register), not the token version, so TokenRegenerated leaves it
        // untouched — no update needed.

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

pub fn handleTransferBatch(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    // TransferBatch(address indexed operator, address indexed from, address indexed to, uint256[] ids, uint256[] values)
    if (log.topics.len < 4) return error.InvalidTopicCount;

    const operator = try abi.ABI.decodeAddress(&log.topics[1].bytes, 0);
    const from = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);
    const to = try abi.ABI.decodeAddress(&log.topics[3].bytes, 0);

    // Non-indexed payload: (uint256[] ids, uint256[] values)
    // Stays on the primitive shim path: eth.zig's decodeValues takes a flat
    // []AbiType and lacks an in-band way to express the element type of a
    // dynamic_array. The primitive decodeUint256Array still routes through
    // eth.uint256.fromBigEndianBytes, so the math is the same.
    const token_ids = try abi.ABI.decodeUint256Array(self.allocator, log.data, 0);
    defer self.allocator.free(token_ids);

    const values = try abi.ABI.decodeUint256Array(self.allocator, log.data, 32);
    defer self.allocator.free(values);

    std.log.debug("TransferBatch: operator={any}, from={any}, to={any}, count={d}", .{ operator, from, to, token_ids.len });

    utils.recordAccountObservation(self, protocol, to, log);

    // Store event
    var operator_hex_buf: [42]u8 = undefined;
    const operator_hex = operator.toHexBuf(&operator_hex_buf);
    var from_hex_buf: [42]u8 = undefined;
    const from_hex = from.toHexBuf(&from_hex_buf);
    var to_hex_buf: [42]u8 = undefined;
    const to_hex = to.toHexBuf(&to_hex_buf);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"operator\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"count\":{d}}}", .{
        operator_hex,
        from_hex,
        to_hex,
        token_ids.len,
    });

    try utils.emitEvent(self, protocol, log, .transfer, null, null, event_data);

    // Update ownership for each transferred token (match handleTransfer semantics — propagate DB errors)
    for (token_ids) |token_id| {
        if (to.isZero()) continue; // burn: no owner update

        const maybe_name = try self.database.getNameByTokenIdAndRegistry(token_id, log.address);
        if (maybe_name) |name| {
            const namehash = name.namehash;
            var mutable_name = name;
            mutable_name.deinit(self.allocator);
            try self.database.updateNameOwner(namehash, to);
        } else {
            std.log.debug("  → Skipping batch Transfer for unknown tokenId={d} in registry {any}", .{ token_id, log.address });
        }
    }
}

pub fn handleApproval(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    // Approval(address indexed owner, address indexed approved, uint256 indexed tokenId)
    if (log.topics.len < 4) return error.InvalidTopicCount;

    const owner = try abi.ABI.decodeAddress(&log.topics[1].bytes, 0);
    const approved = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);
    const token_id_raw = try abi.ABI.decodeUint256(&log.topics[3].bytes, 0);
    const token_id: u256 = token_id_raw;

    std.log.debug("Approval: owner={any}, approved={any}, tokenId={d}", .{ owner, approved, token_id });

    // Both owner and approved are real account observations — `owner` granted
    // permission; `approved` is a new operator address worth tracking too.
    utils.recordAccountObservation(self, protocol, owner, log);
    utils.recordAccountObservation(self, protocol, approved, log);

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
    var owner_hex_buf: [42]u8 = undefined;
    const owner_hex = owner.toHexBuf(&owner_hex_buf);
    var approved_hex_buf: [42]u8 = undefined;
    const approved_hex = approved.toHexBuf(&approved_hex_buf);

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

    try utils.emitEvent(self, protocol, log, .approval, event_name, namehash, event_data);

    // Store approval in database (registry-scoped to avoid cross-registry token_id collisions)
    try self.database.insertApproval(protocol, token_id, owner, approved, log.block_number, log.transaction_hash, log.address);
    std.log.debug("Stored approval in database for tokenId={d}", .{token_id});
}

// ========================================================================
// Enhanced Access Control (EAC) Event Handler
// ========================================================================

/// Handle EACRolesChanged event from registry contracts.
///
/// Registry resources are `canonical_id | uint32(eacVersionId)`; they are stored
/// verbatim and only the name lookup keys on the canonical id. See
/// `handleEACRolesChangedImpl`.
/// EACRolesChanged(uint256 indexed resource, address indexed account, uint256 oldRoleBitmap, uint256 newRoleBitmap)
pub fn handleEACRolesChanged(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    try handleEACRolesChangedImpl(self, protocol, log, false);
}

/// Handle EACRolesChanged event, branching on the emitting contract kind.
///
/// The indexed `resource` is stored EXACTLY as emitted for both kinds:
///   - Registry (is_resolver = false): `resource` is `canonical_id |
///     uint32(eacVersionId)` (PermissionedRegistry._constructResource). The low
///     32 bits are the EAC version, bumped on unregister and on re-registering an
///     expired label — a re-registered name therefore gets a fresh resource and
///     the previous owner's grants stop matching, which is what makes stale
///     grants drop out on-chain. Keeping the bits preserves that; the canonical
///     id is used only to attribute the event to a name.
///   - Resolver (is_resolver = true): `resource` is either ROOT_RESOURCE (0) or
///     `uint256(keccak256(abi.encode(node, part)))` (see PermissionedResolverLib
///     in contracts-v2), a full-entropy hash with no version bits.
pub fn handleEACRolesChangedImpl(self: *Indexer, protocol: models.Protocol, log: rpc.Log, is_resolver: bool) !void {
    // Event: EACRolesChanged(uint256 indexed resource, address indexed account, uint256 oldRoleBitmap, uint256 newRoleBitmap)
    // topics[0] = event signature
    // topics[1] = resource (tokenId/namehash as uint256) - indexed
    // topics[2] = account - indexed
    // data = oldRoleBitmap (uint256) + newRoleBitmap (uint256)
    if (log.topics.len < 3) return error.InvalidTopicCount;

    // Decode indexed parameters from topics
    const resource_uint = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
    const account = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);

    utils.recordAccountObservation(self, protocol, account, log);

    // Non-indexed payload: (uint256 oldRoleBitmap, uint256 newRoleBitmap)
    const data_values = try abi.decodeValues(
        log.data,
        &.{ .uint256, .uint256 },
        self.allocator,
    );
    defer abi.freeValues(data_values, self.allocator);
    const old_role_bitmap = data_values[0].uint256;
    const new_role_bitmap = data_values[1].uint256;

    const token_id_utils = @import("../../types/token_id.zig");

    // Convert resource to hex string for storage (verbatim, version bits included)
    var resource_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &resource_bytes, resource_uint, .big);
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

    var account_hex_buf: [42]u8 = undefined;
    const account_hex = account.toHexBuf(&account_hex_buf);

    std.log.debug("EACRolesChanged: resource={s}, account={s}, oldBitmap={s}, newBitmap={s}", .{
        resource_hex,
        account_hex,
        old_bitmap_hex,
        new_bitmap_hex,
    });

    // Store or delete role in database
    // If newRoleBitmap is 0, all roles were revoked - delete the entry
    // Otherwise, upsert with the new bitmap.
    // Buffered (deduped, flushed as one multi-row upsert) only while the
    // reorg cursor is DISARMED: eac_roles is a capture-protected table, and a
    // flush-time capture would tag every undo row with the batch's last block
    // instead of each event's — see WriteBuffer.roles. Armed (near-tip)
    // batches keep the direct per-event write with correct capture tagging.
    const buffer_roles = self.write_buffer.active and !self.reorg_arm;
    if (new_role_bitmap == 0) {
        if (buffer_roles) {
            try self.write_buffer.setRole(protocol, resource_hex, account, null, log.block_number, log.transaction_hash, log.log_index, log.address);
        } else {
            try self.database.deleteEACRole(protocol, resource_hex, account, log.address);
        }
        std.log.debug("  → Deleted EAC role (all roles revoked)", .{});
    } else {
        if (buffer_roles) {
            try self.write_buffer.setRole(protocol, resource_hex, account, new_bitmap_hex, log.block_number, log.transaction_hash, log.log_index, log.address);
        } else {
            try self.database.upsertEACRole(
                protocol,
                resource_hex,
                account,
                new_bitmap_hex,
                log.block_number,
                log.transaction_hash,
                log.log_index,
                log.address,
            );
        }
        std.log.debug("  → Stored EAC role assignment", .{});
    }

    // Store event for audit trail
    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"resource\":\"{s}\",\"account\":\"{s}\",\"oldRoleBitmap\":\"{s}\",\"newRoleBitmap\":\"{s}\"}}", .{
        resource_hex,
        account_hex,
        old_bitmap_hex,
        new_bitmap_hex,
    });

    // Look up name by canonical_id AND registry to avoid cross-registry collisions.
    // Only valid for the registry path: registry resources are token ids that map
    // to a name. Resolver resources are keccak256(node, part) and `log.address` is
    // the resolver (not a registry), so a token-id lookup can never match — skip it.
    var name_str_opt: ?[]const u8 = null;
    var namehash_opt: ?Hash = null;

    if (!is_resolver) {
        const maybe_name = try self.database.getNameByTokenIdAndRegistry(token_id_utils.resourceCanonicalId(resource_uint), log.address);
        if (maybe_name) |name| {
            name_str_opt = if (name.name) |n| try self.allocator.dupe(u8, n) else null;
            namehash_opt = name.namehash;
            var name_copy = name;
            name_copy.deinit(self.allocator);
        }
    }

    const event_name = if (name_str_opt) |n| try self.allocator.dupe(u8, n) else null;
    defer if (name_str_opt) |n| self.allocator.free(n);

    try utils.emitEvent(self, protocol, log, .eac_roles_changed, event_name, namehash_opt, event_data);
}

/// Handle LabelRegistered events from PermissionedRegistry
/// Event: LabelRegistered(uint256 indexed tokenId, bytes32 indexed labelHash, string label, address owner, uint64 expiry, address indexed sender)
pub fn handleLabelRegistered(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    if (log.topics.len < 4) return error.InvalidTopicCount;

    const token_id_raw = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
    const token_id: u256 = token_id_raw;
    const token_id_utils = @import("../../types/token_id.zig");
    const canonical_id = token_id_utils.getCanonicalId(token_id);

    const label_hash = Hash{ .bytes = log.topics[2].bytes };
    const sender = try abi.ABI.decodeAddress(&log.topics[3].bytes, 0);

    // Non-indexed payload: (string label, address owner, uint64 expiry).
    // Decoded as a single schema-driven call through eth.zig's tested codec.
    const data_values = try abi.decodeValues(
        log.data,
        &.{ .string, .address, .uint64 },
        self.allocator,
    );
    defer abi.freeValues(data_values, self.allocator);

    const label_str = data_values[0].string;
    const owner = Address{ .bytes = data_values[1].address };
    const expiry: u64 = @truncate(data_values[2].uint256);

    ens_name.validateLabel(label_str) catch |err| {
        std.log.warn("Invalid name label '{s}' for tokenId={d}: {any}", .{ label_str, token_id, err });
        return;
    };

    // Detect if this registration was triggered by a migration controller (V1→V2 migration)
    // and which kind. Locked migrations preserve V1 wrapper fuses; unlocked do not.
    const migration_kind = self.getMigrationKind(sender);
    const is_migration = migration_kind != .none;

    std.log.debug("LabelRegistered: {s} (tokenId={d}, canonicalId={d}, owner={any}, expiry={d}, sender={any}, migration_kind={any})", .{ label_str, token_id, canonical_id, owner, expiry, sender, migration_kind });

    const eth_registry = self.getEthRegistry(protocol);
    const is_main_registry = log.address.eql(eth_registry);

    var parent_name: []const u8 = "eth";
    var parent_name_allocated = false;
    var parent_namehash: Hash = self.eth_namehash;

    if (!is_main_registry) {
        var registry_hex_buf: [42]u8 = undefined;
        const registry_hex = log.address.toHexBuf(&registry_hex_buf);

        // V2 invariant: each subregistry contract is deployed for a single parent position
        // (VerifiableFactory deploys a fresh instance per name). If this invariant breaks
        // in a future deployment, we'd need path-based parent resolution. The query below
        // takes the most-recently-set parent, which is correct under the current invariant.
        var rq = try Query.initCached(self.database,
            \\SELECT name, namehash FROM registries
            \\WHERE address = ? AND protocol = ? AND created_block <= ?
            \\ORDER BY created_block DESC
            \\LIMIT 2
        );
        defer rq.deinit();
        try rq.bindText(registry_hex);
        try rq.bindText(protocol.toString());
        try rq.bindInt64(@intCast(log.block_number));

        if (try rq.step()) {
            if (rq.getTextSlice(0)) |name_span| {
                parent_name = try self.allocator.dupe(u8, name_span);
                parent_name_allocated = true;
            }
            if (rq.getTextSlice(1)) |namehash_hex| {
                parent_namehash = try Hash.fromHex(namehash_hex);
            }
            // Warn if the V2 per-name-subregistry invariant is broken
            if (try rq.step()) {
                warnIfLiveMultiParent(self, protocol, registry_hex, log.block_number);
            }
        } else {
            std.log.debug("LabelRegistered: orphaning {s} - no parent found for subregistry {s} at block {d}", .{
                label_str, registry_hex, log.block_number,
            });
            try self.database.insertOrphanedRegistration(
                protocol,
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

    const full_name = try ens_name.join(self.allocator, label_str, parent_name);
    defer self.allocator.free(full_name);

    const namehash_val = try @import("../../types/hash.zig").namehash(self.allocator, full_name);

    const name_dup = try self.allocator.dupe(u8, full_name);
    defer self.allocator.free(name_dup);
    const label_dup = try self.allocator.dupe(u8, label_str);
    defer self.allocator.free(label_dup);
    const parent_name_dup = try self.allocator.dupe(u8, parent_name);
    defer self.allocator.free(parent_name_dup);

    const block_timestamp = try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp);

    // For migrations, look up the corresponding V1 row by namehash so we can
    // (a) link via v1_label_hash, (b) carry over wrapper fuses for LOCKED
    // migrations, (c) attest is_v1_name=true. The V1 namehash matches V2's
    // namehash for a migrated name (same label, same parent), so we look up
    // by the same namehash but in the V1 protocol scope.
    var preserved_v1_label_hash_hex: ?[]u8 = null;
    var preserved_fuses_buf: ?[]u8 = null;
    var preserved_wrapper_expiry: ?i64 = null;
    var preserved_is_wrapped: bool = false;
    defer if (preserved_v1_label_hash_hex) |buf| self.allocator.free(buf);
    defer if (preserved_fuses_buf) |buf| self.allocator.free(buf);
    if (is_migration) {
        if (self.database.getNameByNamehashAndProtocol(namehash_val, .v1) catch null) |v1_row| {
            var v1_mut = v1_row;
            defer v1_mut.deinit(self.allocator);
            preserved_v1_label_hash_hex = try v1_mut.label_hash.toHex(self.allocator);
            // Locked migrations preserve fuses + wrapper_expiry; unlocked do not.
            if (migration_kind == .locked and v1_mut.is_wrapped) {
                if (v1_mut.wrapper_fuses) |fuses_str| {
                    preserved_fuses_buf = try self.allocator.dupe(u8, fuses_str);
                }
                preserved_wrapper_expiry = v1_mut.wrapper_expiry;
                preserved_is_wrapped = true;
            }
        } else {
            // V1 row not found. Expected when running V2-only (no V1 indexer on this DB);
            // a real ordering bug would surface differently. Debug-level so a sync of N
            // thousand migrations doesn't spam the operator log.
            std.log.debug("Migration LabelRegistered for {s}: no V1 row found by namehash; v1_label_hash will be null", .{full_name});
        }
    }

    const name = models.Name{
        .name = name_dup,
        .label = label_dup,
        .label_hash = label_hash,
        .parent_name = parent_name_dup,
        .parent_namehash = parent_namehash,
        .protocol = protocol,
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
        .created_at = block_timestamp,
        .registered_at = block_timestamp,
        .updated_block = log.block_number,
        .updated_at = block_timestamp,
        .is_wrapped = preserved_is_wrapped,
        .wrapper_fuses = preserved_fuses_buf,
        .wrapper_expiry = preserved_wrapper_expiry,
        .is_v1_name = is_migration, // V1-origin only when migrated; pure V2 mints stay false
        .v1_label_hash = preserved_v1_label_hash_hex,
    };

    try self.insertName(name);

    if (is_migration) {
        // Per-name migration log moved to debug — a Sepolia sync produces thousands of
        // these and they drown out useful info. Aggregate counts (migrations
        // detected, locked vs unlocked) are surfaced at the end of each batch via
        // the existing progress log.
        std.log.debug("Migration detected ({s}): {s} migrated from V1→V2", .{
            if (migration_kind == .locked) "LOCKED" else "UNLOCKED",
            full_name,
        });
    }

    // Log-index-ordered dispatch means SubregistryUpdated/ResolverUpdated for a newly-minted
    // name can fire before LabelRegistered in the same tx. Those handlers stored placeholder
    // rows keyed by canonicalId/tokenId; patch them now that the name is resolved.
    const canonical_placeholder = try std.fmt.allocPrint(self.allocator, "canonicalId:{d}", .{canonical_id});
    defer self.allocator.free(canonical_placeholder);
    _ = self.database.updateRegistryPlaceholderName(canonical_placeholder, full_name, namehash_val) catch |err| {
        std.log.warn("Failed to patch canonicalId placeholder: {}", .{err});
    };
    const tokenid_placeholder = try std.fmt.allocPrint(self.allocator, "tokenId:{d}", .{token_id});
    defer self.allocator.free(tokenid_placeholder);
    _ = self.database.updatePlaceholderEventsByName(tokenid_placeholder, full_name, namehash_val) catch |err| {
        std.log.warn("Failed to patch tokenId placeholder: {}", .{err});
    };

    // Best-effort; see handleETHNameRegistered for rationale.
    self.database.insertRegistration(
        protocol,
        namehash_val,
        label_str,
        parent_name,
        owner,
        block_timestamp,
        if (expiry == 0) null else expiry,
        log.block_number,
        log.transaction_hash,
        log.log_index,
        .label_registered,
    ) catch |err| {
        std.log.warn("insertRegistration failed for {s}: {}", .{ full_name, err });
    };

    var owner_hex_buf: [42]u8 = undefined;
    const owner_hex = owner.toHexBuf(&owner_hex_buf);
    var registry_hex_buf: [42]u8 = undefined;
    const registry_hex = log.address.toHexBuf(&registry_hex_buf);
    var sender_hex_buf: [42]u8 = undefined;
    const sender_hex = sender.toHexBuf(&sender_hex_buf);

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

    try utils.emitEvent(self, protocol, log, .label_registered, event_name, namehash_val, event_data);
}

/// Handle LabelReserved events from PermissionedRegistry (when owner == 0)
/// Event: LabelReserved(uint256 indexed tokenId, bytes32 indexed labelHash, string label, uint64 expiry, address indexed sender)
pub fn handleLabelReserved(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    if (log.topics.len < 4) return error.InvalidTopicCount;

    const token_id_raw = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
    const token_id: u256 = token_id_raw;

    const label_hash = Hash{ .bytes = log.topics[2].bytes };
    const sender = try abi.ABI.decodeAddress(&log.topics[3].bytes, 0);

    // Non-indexed payload: (string label, uint64 expiry)
    const data_values = try abi.decodeValues(
        log.data,
        &.{ .string, .uint64 },
        self.allocator,
    );
    defer abi.freeValues(data_values, self.allocator);
    const label_str = data_values[0].string;
    const expiry: u64 = @truncate(data_values[1].uint256);

    ens_name.validateLabel(label_str) catch |err| {
        std.log.warn("Invalid name label '{s}' for tokenId={d}: {any}", .{ label_str, token_id, err });
        return;
    };

    std.log.debug("LabelReserved: {s} (tokenId={d}, expiry={d}, sender={any})", .{ label_str, token_id, expiry, sender });

    const eth_registry = self.getEthRegistry(protocol);
    const is_main_registry = log.address.eql(eth_registry);

    var parent_name: []const u8 = "eth";
    var parent_name_allocated = false;
    var parent_namehash: Hash = self.eth_namehash;

    if (!is_main_registry) {
        var registry_hex_buf: [42]u8 = undefined;
        const registry_hex = log.address.toHexBuf(&registry_hex_buf);

        // V2 invariant: each subregistry contract is deployed for a single parent position.
        // Same LIMIT 2 + warning pattern as handleLabelRegistered.
        var rq = try Query.initCached(self.database,
            \\SELECT name, namehash FROM registries
            \\WHERE address = ? AND protocol = ? AND created_block <= ?
            \\ORDER BY created_block DESC
            \\LIMIT 2
        );
        defer rq.deinit();
        try rq.bindText(registry_hex);
        try rq.bindText(protocol.toString());
        try rq.bindInt64(@intCast(log.block_number));

        if (try rq.step()) {
            if (rq.getTextSlice(0)) |name_span| {
                parent_name = try self.allocator.dupe(u8, name_span);
                parent_name_allocated = true;
            }
            if (rq.getTextSlice(1)) |namehash_hex| {
                parent_namehash = try Hash.fromHex(namehash_hex);
            }
            if (try rq.step()) {
                warnIfLiveMultiParent(self, protocol, registry_hex, log.block_number);
            }
        }
    }
    defer if (parent_name_allocated) self.allocator.free(parent_name);

    const full_name = try ens_name.join(self.allocator, label_str, parent_name);
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
        .protocol = protocol,
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
        .created_at = try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
        .registered_at = try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
        .updated_block = log.block_number,
        .updated_at = try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    };

    try self.insertName(name);

    var sender_hex_buf: [42]u8 = undefined;
    const sender_hex = sender.toHexBuf(&sender_hex_buf);
    var registry_hex_buf: [42]u8 = undefined;
    const registry_hex = log.address.toHexBuf(&registry_hex_buf);

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

    try utils.emitEvent(self, protocol, log, .label_reserved, event_name, namehash_val, event_data);
}

/// Handle LabelUnregistered events from PermissionedRegistry
/// Event: LabelUnregistered(uint256 indexed tokenId, address indexed sender)
///
/// On-chain, this sets `entry.expiry = block.timestamp` which makes
/// `getSubregistry(label)` return zero — the same canonical effect as
/// `setSubregistry(label, 0)`. So we must cascade-invalidate descendants
/// of the entry's current subregistry, then soft-delete the label itself
/// (rather than hard-delete) so future re-registration can reactivate it.
pub fn handleLabelUnregistered(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    if (log.topics.len < 3) return error.InvalidTopicCount;

    const token_id_raw = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
    const token_id: u256 = token_id_raw;

    const sender = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);

    std.log.debug("LabelUnregistered: tokenId={d}, sender={any}", .{ token_id, sender });

    const block_timestamp = try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp);

    // Cascade-invalidate descendants of the entry's current subregistry —
    // multi-parent-guarded, and with the mirror cleared FIRST so the guard's
    // root-walk sees post-change edges (on-chain the expiry guard makes
    // getSubregistry return zero; our mirror reflects that before deciding
    // whether the old subtree is genuinely orphaned).
    const prev_subregistry = try self.database.getRegistryEntrySubregistry(
        protocol,
        log.address,
        token_id,
    );
    if (!prev_subregistry.isZero()) {
        _ = try self.database.upsertRegistryEntrySubregistry(
            protocol,
            log.address,
            token_id,
            Address.zero,
            log.block_number,
            block_timestamp,
        );
        const roots = [_]Address{ self.config.v2_contracts.eth_registry, self.config.v2_contracts.root_registry };
        const seeds = [_]Address{prev_subregistry};
        const recompute = try self.database.recomputeSubtreeReachability(
            self.allocator,
            protocol,
            &seeds,
            &roots,
            log.block_number,
            block_timestamp,
        );
        if (recompute.names_marked_unreachable > 0 or recompute.names_marked_reachable > 0) {
            std.log.info(
                "LabelUnregistered: cleared {any} from {any}; {d} name(s) marked unreachable, {d} reachable across {d} checked subregistries",
                .{ log.address, prev_subregistry, recompute.names_marked_unreachable, recompute.names_marked_reachable, recompute.registries_checked },
            );
        }
    }

    const maybe_name = try self.database.getNameByTokenIdAndRegistry(token_id, log.address);

    var name_str: []const u8 = undefined;
    var namehash_opt: ?Hash = null;

    if (maybe_name) |n| {
        // Soft-delete: set is_reachable = 0 so a future re-register can
        // reactivate this row instead of losing history. Hard-delete would
        // drop createdAt / registrationDate / events linkage.
        try self.database.markNameUnreachableByNamehash(protocol, n.namehash, log.block_number, block_timestamp);
        name_str = try self.allocator.dupe(u8, n.name orelse "[unknown]");
        namehash_opt = n.namehash;
        var name_copy = n;
        name_copy.deinit(self.allocator);
    } else {
        name_str = try std.fmt.allocPrint(self.allocator, "tokenId:{d}", .{token_id});
    }
    defer self.allocator.free(name_str);

    var sender_hex_buf: [42]u8 = undefined;
    const sender_hex = sender.toHexBuf(&sender_hex_buf);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"tokenId\":{d},\"sender\":\"{s}\"}}", .{
        token_id,
        sender_hex,
    });

    const event_name = try self.allocator.dupe(u8, name_str);

    try utils.emitEvent(self, protocol, log, .label_unregistered, event_name, namehash_opt, event_data);
}

/// Handle ExpiryUpdated events from PermissionedRegistry (replaces NameRenewed)
/// Event: ExpiryUpdated(uint256 indexed tokenId, uint64 indexed newExpiry, address indexed sender)
pub fn handleExpiryUpdated(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
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
        // Defensive: with log-index ordering this should not happen for in-batch events.
        // Reachable on reorg replay or orphaned subregistries not yet linked.
        std.log.warn("ExpiryUpdated for unknown tokenId={d} in registry {any}; expiry not updated (event still recorded)", .{ token_id, log.address });
        name_str = try std.fmt.allocPrint(self.allocator, "tokenId:{d}", .{token_id});
    }
    defer self.allocator.free(name_str);

    var sender_hex_buf: [42]u8 = undefined;
    const sender_hex = sender.toHexBuf(&sender_hex_buf);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"tokenId\":{d},\"newExpiry\":{d},\"sender\":\"{s}\"}}", .{
        token_id,
        new_expiry,
        sender_hex,
    });

    const event_name = try self.allocator.dupe(u8, name_str);

    try utils.emitEvent(self, protocol, log, .expiry_updated, event_name, namehash_opt, event_data);
}

/// Handle ParentUpdated events from PermissionedRegistry
/// Event: ParentUpdated(IRegistry indexed parent, string label, address indexed sender)
pub fn handleParentUpdated(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    if (log.topics.len < 3) return error.InvalidTopicCount;

    const parent_addr = try abi.ABI.decodeAddress(&log.topics[1].bytes, 0);
    const sender = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);

    // Non-indexed payload: (string label)
    const data_values = try abi.decodeValues(log.data, &.{.string}, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const label_str = data_values[0].string;

    std.log.debug("ParentUpdated: parent={any}, label={s}, sender={any}", .{ parent_addr, label_str, sender });

    var parent_hex_buf: [42]u8 = undefined;
    const parent_hex = parent_addr.toHexBuf(&parent_hex_buf);
    var sender_hex_buf: [42]u8 = undefined;
    const sender_hex = sender.toHexBuf(&sender_hex_buf);

    const escaped_label = try json_utils.escapeString(self.allocator, label_str);
    defer self.allocator.free(escaped_label);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"parent\":\"{s}\",\"label\":\"{s}\",\"sender\":\"{s}\"}}", .{
        parent_hex,
        escaped_label,
        sender_hex,
    });

    const event_name = try self.allocator.dupe(u8, label_str);

    try utils.emitEvent(self, protocol, log, .parent_updated, event_name, null, event_data);
}

/// Handle SubregistryUpdated events from PermissionedRegistry (NEW signature)
/// Event: SubregistryUpdated(uint256 indexed tokenId, IRegistry indexed subregistry, address indexed sender)
/// Note: Different from SubregistryUpdate - uses indexed IRegistry instead of non-indexed address
pub fn handleSubregistryUpdated(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    if (log.topics.len < 4) return error.InvalidTopicCount;

    const token_id_raw = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
    const token_id: u256 = token_id_raw;
    const token_id_utils = @import("../../types/token_id.zig");
    const canonical_id = token_id_utils.getCanonicalId(token_id);

    const subregistry_addr = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);
    const sender = try abi.ABI.decodeAddress(&log.topics[3].bytes, 0);

    std.log.debug("SubregistryUpdated: tokenId={d}, canonicalId={d}, subregistry={any}, sender={any}", .{ token_id, canonical_id, subregistry_addr, sender });

    try processSubregistryPointerChange(
        self,
        protocol,
        log,
        token_id,
        subregistry_addr,
        sender,
        .subregistry_updated,
    );
}

/// Shared implementation for SubregistryUpdate / SubregistryUpdated.
///
/// The canonical resolution path on-chain reads
/// `parent.getSubregistry(label)` top-down from the root. When the parent
/// repoints (or unsets) its subregistry pointer for a label, every Domain
/// under the previous subregistry's subtree becomes unreachable from the
/// canonical resolver — even though those Domain rows still exist in the
/// previous subregistry contract's storage.
///
/// This function:
/// 1. Reads the previous subregistry pointer from the `registry_entries`
///    mirror (Address.zero if no prior entry — the initial-pointer case,
///    which fires from `_register` in the same tx as `LabelRegistered`).
/// 2. Upserts the new pointer into the mirror.
/// 3. If `prev != 0 && prev != new`: BFS the descendant tree under `prev`
///    via `registry_entries.subregistry` edges, then bulk-mark every
///    `names` row whose source `registry` is in that set as unreachable.
/// 4. If `new != 0`: BFS the new subtree and reactivate any descendants
///    that were previously soft-deleted (re-link case).
/// 5. Registers the new subregistry for monitoring and processes any
///    orphaned registrations waiting for this parent linkage.
fn processSubregistryPointerChange(
    self: *Indexer,
    protocol: models.Protocol,
    log: rpc.Log,
    token_id: u256,
    new_subregistry: Address,
    sender_opt: ?Address,
    event_type: models.EventType,
) !void {
    const token_id_utils = @import("../../types/token_id.zig");
    const canonical_id = token_id_utils.getCanonicalId(token_id);

    const block_timestamp = try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp);

    const prev_subregistry = try self.database.upsertRegistryEntrySubregistry(
        protocol,
        log.address,
        token_id,
        new_subregistry,
        log.block_number,
        block_timestamp,
    );

    // Edge change: recompute reachability PER REGISTRY over both affected
    // subtrees (the region under the previous pointer and under the new one).
    // The mirror was updated above, so the per-node root-walks see post-change
    // edges. No blanket cascades in either direction: the graph permits
    // multi-parent edges (a user pointing their own entry at a shared
    // registry — even the root — must never orphan it on repoint-away, and a
    // re-link through an orphaned parent must never resurrect a subtree).
    // The initial-pointer case (prev=0 from `_register`) still recomputes the
    // new subtree — a no-op against already-correct rows.
    if (!prev_subregistry.eql(new_subregistry)) {
        const roots = [_]Address{ self.config.v2_contracts.eth_registry, self.config.v2_contracts.root_registry };
        const seeds = [_]Address{ prev_subregistry, new_subregistry };
        const recompute = try self.database.recomputeSubtreeReachability(
            self.allocator,
            protocol,
            &seeds,
            &roots,
            log.block_number,
            block_timestamp,
        );
        if (recompute.names_marked_reachable > 0 or recompute.names_marked_unreachable > 0) {
            std.log.info(
                "SubregistryUpdated: repoint of {any} canonicalId={d} from {any} → {any}: {d} name(s) marked reachable, {d} unreachable across {d} checked subregistries",
                .{ log.address, canonical_id, prev_subregistry, new_subregistry, recompute.names_marked_reachable, recompute.names_marked_unreachable, recompute.registries_checked },
            );
        }
    }

    const maybe_name = try self.database.getNameByTokenIdAndRegistry(token_id, log.address);
    const name_str = if (maybe_name) |n| blk: {
        var name_copy = n;
        defer name_copy.deinit(self.allocator);
        break :blk try self.allocator.dupe(u8, name_copy.name orelse "[unknown]");
    } else try std.fmt.allocPrint(self.allocator, "canonicalId:{d}", .{canonical_id});
    defer self.allocator.free(name_str);

    const namehash = if (maybe_name) |n| n.namehash else Hash.zero;

    if (!new_subregistry.isZero()) {
        const registry = models.Registry{
            .address = new_subregistry,
            .protocol = protocol,
            .name = name_str,
            .namehash = namehash,
            .parent_registry = log.address,
            .created_block = log.block_number,
            .created_at = block_timestamp,
        };
        try self.database.insertRegistry(registry);

        // Process orphaned registrations waiting on this parent linkage.
        var subreg_hex_for_orphans_buf: [42]u8 = undefined;
        const subreg_hex_for_orphans = new_subregistry.toHexBuf(&subreg_hex_for_orphans_buf);
        const orphans = try self.database.getOrphanedRegistrations(protocol, subreg_hex_for_orphans);
        defer {
            for (orphans) |*orphan| {
                var o = orphan.*;
                o.deinit(self.allocator);
            }
            self.allocator.free(orphans);
        }
        if (orphans.len > 0) {
            for (orphans) |orphan| {
                try self.processOrphanedRegistration(protocol, orphan, name_str, namehash, new_subregistry);
            }
            try self.database.deleteOrphanedRegistrations(protocol, subreg_hex_for_orphans);
        }
    }

    var subreg_hex_buf: [42]u8 = undefined;
    const subreg_hex = new_subregistry.toHexBuf(&subreg_hex_buf);
    var contract_hex_buf: [42]u8 = undefined;
    const contract_hex = log.address.toHexBuf(&contract_hex_buf);

    const escaped_name = try json_utils.escapeString(self.allocator, name_str);
    defer self.allocator.free(escaped_name);

    const event_data = if (sender_opt) |sender| blk: {
        var sender_hex_buf: [42]u8 = undefined;
        const sender_hex = sender.toHexBuf(&sender_hex_buf);
        break :blk try std.fmt.allocPrint(self.allocator, "{{\"name\":\"{s}\",\"canonicalId\":{d},\"subregistry\":\"{s}\",\"registry\":\"{s}\",\"sender\":\"{s}\"}}", .{
            escaped_name,
            canonical_id,
            subreg_hex,
            contract_hex,
            sender_hex,
        });
    } else try std.fmt.allocPrint(self.allocator, "{{\"name\":\"{s}\",\"canonicalId\":{d},\"subregistry\":\"{s}\",\"registry\":\"{s}\"}}", .{
        escaped_name,
        canonical_id,
        subreg_hex,
        contract_hex,
    });

    const event_name = try self.allocator.dupe(u8, name_str);

    try utils.emitEvent(self, protocol, log, event_type, event_name, namehash, event_data);
}

/// Handle ResolverUpdated events from PermissionedRegistry (NEW signature)
/// Event: ResolverUpdated(uint256 indexed tokenId, address indexed resolver, address indexed sender)
/// Note: Different from ResolverUpdate - uses indexed address
pub fn handleResolverUpdated(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    if (log.topics.len < 4) return error.InvalidTopicCount;

    const token_id_raw = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
    const token_id: u256 = token_id_raw;

    const resolver_addr = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);
    const sender = try abi.ABI.decodeAddress(&log.topics[3].bytes, 0);

    std.log.debug("ResolverUpdated: tokenId={d}, resolver={any}, sender={any}", .{ token_id, resolver_addr, sender });

    // Register the resolver for record indexing. A FIRST sighting is queued
    // for a historical backfill (drained by indexResolverEvents): factory-
    // deployed resolvers emit their initialize()-time EACRolesChanged role
    // grants blocks BEFORE this ResolverUpdated, when the resolver pass still
    // skipped them as unknown — without the backfill those roles never reach
    // resolver.roles. The discovery-path backfill can't recover them:
    // registering here makes its `kr.address IS NULL` filter false first.
    var resolver_hex_buf: [42]u8 = undefined;
    const resolver_hex = resolver_addr.toHexBuf(&resolver_hex_buf);
    const newly_known = try self.registerResolverOnceIfNew(protocol, resolver_hex, log.block_number);
    if (newly_known and !resolver_addr.isZero()) {
        try self.pending_resolver_backfills.append(self.allocator, resolver_addr);
    }

    // Paired identity — (namehash, display name) — via the dispatch-scoped
    // prefetch when it answers (authoritative, see storage/name_prefetch.zig),
    // via the DB point lookup on fall-through.
    var paired_namehash: ?Hash = null;
    var paired_name: ?[]const u8 = null;
    defer if (paired_name) |nm| self.allocator.free(nm);
    resolved: {
        if (self.name_prefetch) |np| {
            switch (try np.pairedLookup(token_id, log.address, self.allocator)) {
                .unknown => {},
                .miss => break :resolved,
                .hit => |hit| {
                    paired_namehash = hit.namehash;
                    paired_name = hit.name;
                    break :resolved;
                },
            }
        }
        if (try self.database.getNameByTokenIdAndRegistry(token_id, log.address)) |n| {
            var n_copy = n;
            defer n_copy.deinit(self.allocator);
            paired_namehash = n_copy.namehash;
            if (n_copy.name) |nm| paired_name = try self.allocator.dupe(u8, nm);
        }
    }

    var name_str: []const u8 = undefined;
    var namehash_opt: ?Hash = null;

    if (paired_namehash) |paired_hash| {
        try self.database.updateNameResolver(paired_hash, resolver_addr);
        name_str = try self.allocator.dupe(u8, paired_name orelse "[unknown]");
        namehash_opt = paired_hash;
        // Record the Resolver entity binding (subgraph parity). Only when we
        // know which name the resolver is bound to; orphan ResolverUpdated
        // events skip this just like the resolver-on-names update above.
        if (!resolver_addr.isZero()) {
            var namehash_hex_buf: [66]u8 = undefined;
            const namehash_hex = namehash_opt.?.toHexBuf(&namehash_hex_buf);
            self.database.upsertResolverEntity(
                protocol,
                resolver_hex,
                namehash_hex,
                name_str,
                log.block_number,
                try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
            ) catch |err| {
                std.log.debug("upsertResolverEntity failed: {}", .{err});
            };
        }
    } else fallback: {
        // Event-enrichment fallback ONLY — the mutations above stay strictly
        // behind the paired (token, emitting contract) lookup. The emitter is
        // not always the owning registry (TLD ResolverUpdated arrives from
        // the datastore while the name's row records the root registry), and
        // that miss used to leave a PERMANENT "tokenId:…" placeholder with a
        // null namehash — rows invisible to name-scoped history queries.
        // Ambiguity-guarded: a cross-registry canonical collision returns
        // null and keeps the placeholder rather than guessing. Mirrors the
        // write-buffer flush repair (A/B-verified 180/180 on real data), so
        // direct and buffered mode now agree.
        var fb_namehash: ?Hash = null;
        var fb_name: ?[]const u8 = null;
        defer if (fb_name) |nm| self.allocator.free(nm);
        fb_resolved: {
            if (self.name_prefetch) |np| {
                switch (try np.uniqueLookup(protocol, token_id, self.allocator)) {
                    .unknown => {},
                    .miss => break :fb_resolved,
                    .hit => |hit| {
                        fb_namehash = hit.namehash;
                        fb_name = hit.name;
                        break :fb_resolved;
                    },
                }
            }
            if (try self.database.getUniqueNameByCanonicalId(protocol, token_id)) |fb| {
                var fb_copy = fb;
                defer fb_copy.deinit(self.allocator);
                fb_namehash = fb_copy.namehash;
                if (fb_copy.name) |nm| fb_name = try self.allocator.dupe(u8, nm);
            }
        }
        if (fb_name) |real| {
            if (!std.mem.startsWith(u8, real, "tokenId:")) {
                name_str = try self.allocator.dupe(u8, real);
                namehash_opt = fb_namehash;
                break :fallback;
            }
        }
        name_str = try std.fmt.allocPrint(self.allocator, "tokenId:{d}", .{token_id});
    }
    defer self.allocator.free(name_str);

    var sender_hex_buf: [42]u8 = undefined;
    const sender_hex = sender.toHexBuf(&sender_hex_buf);

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"tokenId\":{d},\"resolver\":\"{s}\",\"sender\":\"{s}\"}}", .{
        token_id,
        resolver_hex,
        sender_hex,
    });

    const event_name = try self.allocator.dupe(u8, name_str);

    try utils.emitEvent(self, protocol, log, .resolver_updated, event_name, namehash_opt, event_data);
}

/// Audit #37: the parent reverse-lookup above reads `registries`, which is
/// append-only HISTORY — a benign sequential repoint (old parent already
/// cascade-invalidated before the new one registered) leaves >1 historical row
/// and used to fire a false-positive warning. Gate on the `registry_entries`
/// live mirror instead: only a registry with more than one entry CURRENTLY
/// pointing at it is a true simultaneous multi-parent (a VerifiableFactory
/// one-instance-per-name deployment-convention violation). Best-effort: a
/// probe failure must not break event processing.
fn warnIfLiveMultiParent(self: *Indexer, protocol: models.Protocol, registry_hex: []const u8, block_number: u64) void {
    const parents = registry_entries.getLiveParents(self.database, self.allocator, protocol, registry_hex) catch |err| {
        std.log.debug("multi-parent live-mirror probe failed for {s}: {}", .{ registry_hex, err });
        return;
    };
    defer registry_entries.freeLiveParents(self.allocator, parents);
    if (parents.len <= 1) return; // benign repoint: history has >1 parent, live mirror does not
    std.log.warn("Multi-parent subregistry detected: address={s} has {d} live parents at block {d} (parent={s} canonical_id={s} vs parent={s} canonical_id={s}); one-instance-per-name deployment convention violated", .{
        registry_hex,
        parents.len,
        block_number,
        parents[0].parent_registry,
        parents[0].canonical_id,
        parents[1].parent_registry,
        parents[1].canonical_id,
    });
}

/// Handle LabelStore `Label(bytes32 indexed labelHash, string label)` — the on-chain
/// labelhash->preimage dictionary. Heals any unknown labels carrying this labelhash by
/// materializing their name records (reusing the rainbow heal path), then clears them.
pub fn handleLabelStoreLabel(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    _ = protocol;
    if (log.topics.len < 2) return error.InvalidTopicCount;
    const labelhash = Hash{ .bytes = log.topics[1].bytes };

    // Non-indexed payload: (string label).
    const data_values = try abi.decodeValues(log.data, &.{.string}, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const label = data_values[0].string;

    ens_name.validateLabel(label) catch {
        std.log.warn("LabelStore: ignoring invalid label for labelhash {any}", .{labelhash});
        return;
    };

    const rows = try unknown_labels_storage.getUnknownLabelsByLabelhash(self.allocator, self.database, labelhash);
    defer {
        for (rows) |r| unknown_labels_storage.freeUnknownLabel(self.allocator, r);
        self.allocator.free(rows);
    }
    if (rows.len == 0) return;

    var healed: usize = 0;
    for (rows) |row| {
        label_backfill.healSubdomainLabel(self.allocator, self.database, label, row) catch |err| {
            std.log.warn("LabelStore heal failed for labelhash={s}: {}", .{ row.labelhash, err });
            continue;
        };
        unknown_labels_storage.deleteUnknownLabel(self.database, row.id) catch {};
        healed += 1;
    }
    if (healed > 0) std.log.debug("LabelStore: healed {d} label(s) as '{s}'", .{ healed, label });
}
