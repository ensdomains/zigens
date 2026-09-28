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
const name_aliases = @import("../../storage/name_aliases.zig");
const json_utils = @import("../../utils/json.zig");
const unknown_labels_storage = @import("../../storage/unknown_labels.zig");
const label_backfill = @import("../label_backfill.zig");
const bulk_entities = @import("../../storage/bulk_entities.zig");

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

    // `tokenId` is in here so the row is REPLAYABLE. A name created from the orphan queue has no
    // LabelRegistered event of its own — the originating log was consumed into
    // orphaned_registrations, and this synthetic event is the only record of it — so without the
    // token id a `--backfill` could not reconstruct the row and the name vanished on rebuild.
    // `backfilled` is what lets replay recognise this shape and not confuse it with a registrar
    // NameRegistered (which carries no registry and would write the wrong one).
    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"name\":\"{s}\",\"label\":\"{s}\",\"owner\":\"{s}\",\"expiry\":{d},\"tokenId\":{d},\"registry\":\"{s}\",\"backfilled\":true}}", .{
        escaped_name,
        escaped_label,
        owner_hex,
        orphan.expiry,
        orphan.token_id,
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

    // Every queued orphan, oldest first. Deliberately NOT joined to `registries`:
    // that table holds one row per (subregistry, parent) pair ever seen, so an
    // INNER JOIN fanned one orphan out into a row per HISTORICAL parent — which
    // wrote several primary `names` rows for one label, breaking the
    // one-primary-per-(registry, canonical_id) invariant the indexer's mutation
    // lookups depend on, and doing it for stale linkers as well as live ones.
    // resolveSubregistryParent answers the same question the registration handlers
    // ask, from the live pointer mirror, and v2/alias_sync derives the other
    // fully-qualified names of the label as `is_alias = 1` rows.
    const sql =
        \\SELECT o.subregistry_address, o.token_id, o.label, o.expiry, o.owner,
        \\       o.block_number, o.tx_hash, o.log_index
        \\FROM orphaned_registrations o
        \\WHERE o.protocol = ?
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
            oq.isNull(4) or oq.isNull(6)) continue;

        const subregistry_addr_str = oq.getTextSlice(0).?;
        const token_id_str = oq.getTextSlice(1).?;
        const label = oq.getTextSlice(2).?;
        const owner_str = oq.getTextSlice(4).?;
        const tx_hash_str = oq.getTextSlice(6).?;

        // Parse values
        const token_id_clean = if (std.mem.startsWith(u8, token_id_str, "0x")) token_id_str[2..] else token_id_str;
        const token_id = std.fmt.parseInt(u256, token_id_clean, 16) catch continue;
        const owner = Address.fromHex(owner_str) catch continue;
        const tx_hash = Hash.fromHex(tx_hash_str) catch continue;
        const subregistry_addr = Address.fromHex(subregistry_addr_str) catch continue;

        // Still unlinked at the orphan's block: leave it queued for a later pass,
        // exactly as the previous INNER JOIN's non-match did.
        const resolved = (try resolveSubregistryParent(self, protocol, subregistry_addr, block_number, @import("../../types/token_id.zig").getCanonicalId(token_id))) orelse continue;
        defer self.allocator.free(resolved.name);
        const parent_name = resolved.name;
        const parent_namehash = resolved.namehash;

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
        // Subregistry-emitted: the parent comes from the live subregistry pointer,
        // with the historical lookup as fallback. See resolveSubregistryParent.
        if (try resolveSubregistryParent(self, protocol, log.address, log.block_number, @import("../../types/token_id.zig").getCanonicalId(token_id))) |resolved| {
            parent_name = resolved.name;
            parent_name_allocated = true;
            parent_namehash = resolved.namehash;
        } else {
            var registry_hex_buf: [42]u8 = undefined;
            const registry_hex = log.address.toHexBuf(&registry_hex_buf);
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
    patchPlaceholders(self, log.address, canonical_id, token_id, full_name, namehash);

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
    const maybe_name = try self.lookupPairedName(token_id, log.address);
    defer if (maybe_name) |hit| if (hit.name) |n| self.allocator.free(n);

    var name_str: []const u8 = undefined;
    var namehash: Hash = Hash.zero;

    if (maybe_name) |n| {
        // Update expiry using namehash (scoped to the correct name)
        try self.database.updateNameExpiry(n.namehash, @truncate(new_expiration));
        // A renewal extends the edge's life, so a subtree hidden by this parent's expiry can come
        // back. See reevaluateSubtreeAfterExpiryChange — gated on the label being a parent, so the
        // 9,741 ordinary renewals on the reference dataset cost one indexed point read each.
        reevaluateSubtreeAfterExpiryChange(self, protocol, log, token_id);
        name_str = try self.allocator.dupe(u8, n.name orelse "[unknown]");
        namehash = n.namehash;
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
    var namehash_opt: ?Hash = null;
    var name_str_opt: ?[]const u8 = null;

    if (try self.lookupPairedName(id, log.address)) |hit| {
        defer if (hit.name) |n| self.allocator.free(n);
        name_str_opt = try self.allocator.dupe(u8, hit.name orelse "[unknown]");
        namehash_opt = hit.namehash;

        try self.setNameOwner(namehash_opt.?, to);
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

    // The registry's LabelRegistered (same tx, lower log index) already
    // inserted this row with identical values — the registrar's expiry is the
    // same block.timestamp + duration the registry stored, owner and
    // registrant are the same address. The only column this event adds is the
    // resolver the registrar passed, so an existing row takes just that
    // instead of a second full upsert. A missing row (a registrar event
    // without its registry twin) still gets the full insert.
    if (try self.registeredNameExists(token_id, self.getEthRegistry(protocol), namehash)) {
        try self.setNameResolver(namehash, resolver);
    } else {
        try self.insertName(name);
    }

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
    if (self.bufferingEntities()) {
        self.write_buffer.setEconomics(protocol, namehash, label_str, base_price, premium, referrer) catch |err| {
            std.log.debug("buffering registration economics failed: {}", .{err});
        };
    } else {
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
    }

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
    const maybe_name = try self.lookupPairedName(token_id, eth_registry);
    defer if (maybe_name) |hit| if (hit.name) |n| self.allocator.free(n);

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
    const maybe_name = try self.lookupPairedName(token_id, log.address);
    defer if (maybe_name) |hit| if (hit.name) |n| self.allocator.free(n);
    const name_str = if (maybe_name) |hit|
        try self.allocator.dupe(u8, hit.name orelse "[unknown]")
    else
        try std.fmt.allocPrint(self.allocator, "tokenId:{d}", .{token_id});
    defer self.allocator.free(name_str);

    const namehash = if (maybe_name) |hit| hit.namehash else Hash.zero;

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
        self.write_buffer.discardPendingName(.v2, namehash);
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
    const maybe_name = try self.lookupPairedName(old_token_id, log.address);
    defer if (maybe_name) |hit| if (hit.name) |n| self.allocator.free(n);
    const name_str = if (maybe_name) |hit|
        try self.allocator.dupe(u8, hit.name orelse "[unknown]")
    else
        try std.fmt.allocPrint(self.allocator, "tokenId:{d}", .{old_token_id});
    defer self.allocator.free(name_str);

    const namehash = if (maybe_name) |hit| hit.namehash else Hash.zero;

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

        if (try self.lookupPairedName(token_id, log.address)) |hit| {
            if (hit.name) |n| self.allocator.free(n);
            try self.setNameOwner(hit.namehash, to);
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
    const maybe_name = try self.lookupPairedName(token_id, log.address);
    defer if (maybe_name) |hit| if (hit.name) |n| self.allocator.free(n);
    const name_str = if (maybe_name) |hit|
        try self.allocator.dupe(u8, hit.name orelse "[unknown]")
    else
        try std.fmt.allocPrint(self.allocator, "tokenId:{d}", .{token_id});
    defer self.allocator.free(name_str);

    const namehash = if (maybe_name) |hit| hit.namehash else Hash.zero;

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
            try self.write_buffer.setRole(protocol, resource_hex, account, null, log.block_number, log.transaction_hash, log.log_index, log.address, try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp));
        } else {
            try self.database.deleteEACRole(protocol, resource_hex, account, log.address);
        }
        std.log.debug("  → Deleted EAC role (all roles revoked)", .{});
    } else {
        if (buffer_roles) {
            try self.write_buffer.setRole(protocol, resource_hex, account, new_bitmap_hex, log.block_number, log.transaction_hash, log.log_index, log.address, try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp));
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
                try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
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
        if (try self.lookupPairedName(token_id_utils.resourceCanonicalId(resource_uint), log.address)) |hit| {
            name_str_opt = hit.name;
            namehash_opt = hit.namehash;
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
        // A subregistry contract can back SEVERAL parent names at once — the
        // one-instance-per-name shape is a VerifiableFactory deployment practice, not
        // a protocol guarantee, and the portal offers adopting an existing registry.
        // resolveSubregistryParent picks the parent the chain events attach to from
        // the LIVE pointer mirror; v2/alias_sync derives the other fully-qualified
        // names of the same label.
        if (try resolveSubregistryParent(self, protocol, log.address, log.block_number, @import("../../types/token_id.zig").getCanonicalId(token_id))) |resolved| {
            parent_name = resolved.name;
            parent_name_allocated = true;
            parent_namehash = resolved.namehash;
        } else {
            var registry_hex_buf: [42]u8 = undefined;
            const registry_hex = log.address.toHexBuf(&registry_hex_buf);
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
    patchPlaceholders(self, log.address, canonical_id, token_id, full_name, namehash_val);

    // Best-effort; see handleETHNameRegistered for rationale.
    const registration = bulk_entities.RegistrationRow{
        .protocol = protocol,
        .namehash = namehash_val,
        .label = label_str,
        .parent_name = parent_name,
        .registrant = owner,
        .registered_at = block_timestamp,
        .expiry = if (expiry == 0) null else expiry,
        .block_number = log.block_number,
        .tx_hash = log.transaction_hash,
        .log_index = log.log_index,
        .event_type = .label_registered,
    };
    if (self.bufferingEntities()) {
        self.write_buffer.addRegistration(registration) catch |err| {
            std.log.warn("buffering registration failed for {s}: {}", .{ full_name, err });
        };
    } else {
        self.database.insertRegistration(
            registration.protocol,
            registration.namehash,
            registration.label,
            registration.parent_name,
            registration.registrant,
            registration.registered_at,
            registration.expiry,
            registration.block_number,
            registration.tx_hash,
            registration.log_index,
            registration.event_type,
        ) catch |err| {
            std.log.warn("insertRegistration failed for {s}: {}", .{ full_name, err });
        };
    }

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
        // Same live-pointer-first resolution as handleLabelRegistered.
        //
        // The else branch is not optional here. `parent_name` is initialized to
        // "eth" for the main-registry case, so falling through on an unresolved
        // subregistry would name the reservation `<label>.eth` and give it the 2LD's
        // namehash — and since the names upsert conflicts on (protocol, namehash)
        // and overwrites every identity column, that row would CLOBBER the real
        // `<label>.eth`: owner and registrant to zero, registry to this unknown
        // subregistry, and is_reachable recomputed from it. Skip instead; the
        // reservation is re-derivable from the event, and the two sibling handlers
        // orphan for the same reason.
        if (try resolveSubregistryParent(self, protocol, log.address, log.block_number, @import("../../types/token_id.zig").getCanonicalId(token_id))) |resolved| {
            parent_name = resolved.name;
            parent_name_allocated = true;
            parent_namehash = resolved.namehash;
        } else {
            var registry_hex_buf: [42]u8 = undefined;
            const registry_hex = log.address.toHexBuf(&registry_hex_buf);
            std.log.warn("LabelReserved: no parent for subregistry {s} at block {d} — recording the reservation as an unnamed event instead of naming it {s}.eth", .{
                registry_hex, log.block_number, label_str,
            });
            // The reservation itself is still worth keeping: emit it with no name and
            // no namehash (like handleRegistryCreated) so nothing is silently lost and
            // the event carries every field needed to name it later. Replay skips a
            // null-namehash label_reserved, so live and replay agree.
            const escaped = try json_utils.escapeString(self.allocator, label_str);
            defer self.allocator.free(escaped);
            var sender_hex_buf: [42]u8 = undefined;
            const orphan_data = try std.fmt.allocPrint(self.allocator, "{{\"label\":\"{s}\",\"tokenId\":{d},\"expiry\":{d},\"sender\":\"{s}\",\"registry\":\"{s}\",\"reserved\":true,\"unparented\":true}}", .{
                escaped,
                token_id,
                expiry,
                sender.toHexBuf(&sender_hex_buf),
                registry_hex,
            });
            try utils.emitEvent(self, protocol, log, .label_reserved, null, null, orphan_data);
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
    const token_id_utils_unreg = @import("../../types/token_id.zig");

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

    const maybe_name = try self.lookupPairedName(token_id, log.address);
    defer if (maybe_name) |hit| if (hit.name) |n| self.allocator.free(n);

    var name_str: []const u8 = undefined;
    var namehash_opt: ?Hash = null;

    if (maybe_name) |n| {
        // Soft-delete: set is_reachable = 0 so a future re-register can
        // reactivate this row instead of losing history. Hard-delete would
        // drop createdAt / registrationDate / events linkage.
        try self.database.markNameUnreachableByNamehash(protocol, n.namehash, log.block_number, block_timestamp);
        // This label just stopped resolving, so any derived names hanging off it in a
        // shared registry must go. A label item is enough: the delete half of the pass is
        // scoped to the registry and removes them, and the plan half then finds nothing
        // owed for an unreachable primary.
        name_aliases.enqueueAliasLabelWork(self.database, protocol, log.address, token_id_utils_unreg.getCanonicalId(token_id), log.block_number) catch |err| {
            std.log.warn("alias work enqueue failed for {any}: {} (healed by the next sweep)", .{ log.address, err });
        };
        name_str = try self.allocator.dupe(u8, n.name orelse "[unknown]");
        namehash_opt = n.namehash;
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
/// An expiry change alters whether this label's pointer edge is LIVE, and therefore whether
/// everything beneath it resolves — on-chain `getSubregistry` returns zero for an expired entry.
///
/// Nothing emits an event when an expiry merely PASSES, so the stored reachability bit cannot
/// track that by itself; a renewal or an explicit update is the one moment the chain does tell us,
/// and it is the moment to re-evaluate. A renewal extends (edge revives); an expiry cut shortens
/// (edge may die) — `recomputeSubtreeReachability` evaluates the definition per node, so one call
/// handles both directions.
///
/// Gated on the label actually HAVING a subregistry: that is one indexed point read, and it skips
/// the recompute for the overwhelming majority of names (9,741 renewals on the reference dataset,
/// almost none of them parents). Best-effort — a failure here self-heals on the next sweep or
/// `--backfill`, so it must never abort the event.
fn reevaluateSubtreeAfterExpiryChange(self: *Indexer, protocol: models.Protocol, log: rpc.Log, token_id: u256) void {
    const subregistry = self.database.getRegistryEntrySubregistry(protocol, log.address, token_id) catch |err| {
        std.log.debug("expiry re-evaluation: subregistry lookup failed: {}", .{err});
        return;
    };
    if (subregistry.isZero()) return;

    const block_timestamp = self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp) catch return;
    const roots = [_]Address{ self.config.v2_contracts.eth_registry, self.config.v2_contracts.root_registry };
    const seeds = [_]Address{subregistry};
    if (self.database.recomputeSubtreeReachability(self.allocator, protocol, &seeds, &roots, log.block_number, block_timestamp)) |r| {
        if (r.names_marked_reachable > 0 or r.names_marked_unreachable > 0) {
            std.log.info(
                "expiry change on {any} canonicalId={d}: {d} name(s) marked reachable, {d} unreachable beneath {any}",
                .{ log.address, token_id, r.names_marked_reachable, r.names_marked_unreachable, subregistry },
            );
        }
    } else |err| {
        std.log.warn("expiry re-evaluation recompute failed: {} (healed by the next sweep)", .{err});
    }

    // The alias derivation's live-edge set is expiry-aware too, so the same change can add or
    // remove derived names under this registry.
    name_aliases.enqueueAliasWork(self.database, protocol, subregistry, log.block_number) catch |err| {
        std.log.warn("alias work enqueue failed for {any}: {} (healed by the next sweep)", .{ subregistry, err });
    };
}

pub fn handleExpiryUpdated(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    if (log.topics.len < 4) return error.InvalidTopicCount;

    const token_id_raw = try abi.ABI.decodeUint256(&log.topics[1].bytes, 0);
    const token_id: u256 = token_id_raw;

    const new_expiry_raw = try abi.ABI.decodeUint256(&log.topics[2].bytes, 0);
    const new_expiry: u64 = @truncate(new_expiry_raw);

    const sender = try abi.ABI.decodeAddress(&log.topics[3].bytes, 0);

    std.log.debug("ExpiryUpdated: tokenId={d}, newExpiry={d}, sender={any}", .{ token_id, new_expiry, sender });

    const maybe_name = try self.lookupPairedName(token_id, log.address);
    defer if (maybe_name) |hit| if (hit.name) |n| self.allocator.free(n);

    var name_str: []const u8 = undefined;
    var namehash_opt: ?Hash = null;

    if (maybe_name) |n| {
        try self.database.updateNameExpiry(n.namehash, new_expiry);
        reevaluateSubtreeAfterExpiryChange(self, protocol, log, token_id);
        name_str = try self.allocator.dupe(u8, n.name orelse "[unknown]");
        namehash_opt = n.namehash;
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

pub fn handleRegistryCreated(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    const created_at = try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp);
    try self.database.setSeededRootRegistryCreation(log.address, protocol, log.block_number, created_at);

    var registry_hex_buf: [42]u8 = undefined;
    const registry_hex = log.address.toHexBuf(&registry_hex_buf);
    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"registry\":\"{s}\"}}", .{registry_hex});

    try utils.emitEvent(self, protocol, log, .registry_created, null, null, event_data);
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

    // A pointer change alters which parents refer to the OLD and the NEW subregistry, so
    // both owe a re-derivation of their shared-registry alias rows. Enqueueing here — the
    // one place that knows both addresses — is what keeps the derivation change-driven:
    // with an empty queue the per-batch pass costs one indexed lookup instead of a scan
    // over `names`. A failure is logged, not propagated: the periodic sweep re-enqueues
    // every candidate, so a missed enqueue degrades to "derived late", never "wrong".
    for ([_]Address{ prev_subregistry, new_subregistry }) |affected| {
        if (affected.isZero()) continue;
        name_aliases.enqueueAliasWork(self.database, protocol, affected, log.block_number) catch |err| {
            std.log.warn("alias work enqueue failed for {any}: {} (healed by the next sweep)", .{ affected, err });
        };
    }

    const maybe_name = try self.lookupPairedName(token_id, log.address);
    defer if (maybe_name) |hit| if (hit.name) |n| self.allocator.free(n);
    const name_str = if (maybe_name) |hit|
        try self.allocator.dupe(u8, hit.name orelse "[unknown]")
    else
        try std.fmt.allocPrint(self.allocator, "canonicalId:{d}", .{canonical_id});
    defer self.allocator.free(name_str);
    if (maybe_name == null) self.placeholders.noteCanonicalId(canonical_id) catch {};

    const namehash = if (maybe_name) |hit| hit.namehash else Hash.zero;

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
        try self.database.setSeededSubregistryCreation(new_subregistry, protocol, namehash, log.address, log.block_number, block_timestamp);

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
        if (try self.lookupPairedName(token_id, log.address)) |hit| {
            paired_namehash = hit.namehash;
            paired_name = hit.name;
        }
    }

    var name_str: []const u8 = undefined;
    var namehash_opt: ?Hash = null;

    if (paired_namehash) |paired_hash| {
        try self.setNameResolver(paired_hash, resolver_addr);
        name_str = try self.allocator.dupe(u8, paired_name orelse "[unknown]");
        namehash_opt = paired_hash;
        // Record the Resolver entity binding (subgraph parity). Only when we
        // know which name the resolver is bound to; orphan ResolverUpdated
        // events skip this just like the resolver-on-names update above.
        if (!resolver_addr.isZero()) {
            var namehash_hex_buf: [66]u8 = undefined;
            const namehash_hex = namehash_opt.?.toHexBuf(&namehash_hex_buf);
            const set_at = try self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp);
            if (self.bufferingEntities()) {
                self.write_buffer.addResolverEntity(protocol, resolver_hex, namehash_hex, name_str, log.block_number, set_at) catch |err| {
                    std.log.debug("buffering resolver entity failed: {}", .{err});
                };
            } else {
                self.database.upsertResolverEntity(
                    protocol,
                    resolver_hex,
                    namehash_hex,
                    name_str,
                    log.block_number,
                    set_at,
                ) catch |err| {
                    std.log.debug("upsertResolverEntity failed: {}", .{err});
                };
            }
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
/// One `names` row identity for the parent a child-registry label belongs under.
/// `name` is allocator-owned.
const ResolvedParent = struct {
    name: []u8,
    namehash: Hash,
};

/// Resolve the parent of a label minted in the subregistry `registry`, LIVE
/// POINTER FIRST.
///
/// `LabelRegistered` / `NameRegistered` / `LabelReserved` are emitted by the child
/// registry and name no parent, so the only handle is the registry address — and
/// `registries` maps that address to every parent that has EVER pointed at it
/// (UNIQUE(protocol, address, namehash), added precisely so a shared registry
/// could hold several). Reading that history and taking the most recent row is
/// "last linker wins": it hands the label to whichever name adopted the registry
/// most recently, including a name that has since repointed away and no longer
/// resolves it at all, while the name that actually does resolve it shows nothing.
///
/// `registry_entries` is the live mirror of the on-chain `Entry` mapping, so
/// "which parents resolve this registry right now" is a fact we already keep —
/// it was just never consulted for attribution, only to decide whether to log a
/// warning. Preferring it removes the stale-linker class outright.
///
/// Where several parents are live at once the ambiguity is real and unresolvable
/// from the log: on-chain the label resolves under ALL of them. This picks the
/// oldest link as the row the chain events attach to (stable — a later adopter
/// does not move it) and `v2/alias_sync.zig` derives the remaining
/// fully-qualified names as `is_alias = 1` rows, so none of them is lost.
///
/// Falls back to the historical lookup when the live mirror yields nothing: a
/// parent whose own `names` row has not landed yet (phase ordering), or a
/// registry reached through an entry we never saw. Returns null when neither
/// answers, which is the caller's signal to orphan the registration.
fn resolveSubregistryParent(
    self: *Indexer,
    protocol: models.Protocol,
    registry: Address,
    block_number: u64,
    /// The label being attributed, so a shared registry can enqueue exactly the work this
    /// registration creates. Null from callers that are not registering a label.
    canonical_id_for_work: ?u256,
) !?ResolvedParent {
    // Parent liveness is asked as of THIS label's block, for both halves of the question: which
    // parents had linked by then (created_block) and which had not yet expired by then. An expired
    // parent resolves nothing beneath it on-chain, so it cannot be the parent a label is attributed
    // to either.
    const block_ts = self.getBlockTimestamp(protocol, block_number, null) catch std.math.maxInt(i64);
    const live = try name_aliases.getLiveParentNamesAsOf(
        self.database,
        self.allocator,
        protocol,
        registry,
        @intCast(block_number),
        block_ts,
    );
    defer name_aliases.freeLiveParents(self.allocator, live);
    if (live.len > 0) {
        if (live.len > 1) {
            var registry_hex_buf: [42]u8 = undefined;
            warnIfLiveMultiParent(self, protocol, registry.toHexBuf(&registry_hex_buf), block_number);
            // A label minted into a registry that several parents refer to owes a derived
            // name under each of the others. This is the free hook for it: we already hold
            // the live parent set, so the condition costs nothing and only fires for the
            // rare shared registry. Enqueued per LABEL — a whole-registry item would make
            // one registration cost a pass over every label in the registry.
            if (canonical_id_for_work) |cid| name_aliases.enqueueAliasLabelWork(self.database, protocol, registry, cid, block_number) catch |err| {
                std.log.warn("alias work enqueue failed for {any}: {} (healed by the next sweep)", .{ registry, err });
            };
        }
        return .{
            .name = try self.allocator.dupe(u8, live[0].name),
            .namehash = live[0].namehash,
        };
    }

    var registry_hex_buf: [42]u8 = undefined;
    const registry_hex = registry.toHexBuf(&registry_hex_buf);
    // Tier 2, only when the live mirror answered nothing. Prefer the parent's own `names`
    // row over `registries.name`: the latter is frozen at link time and can still hold an
    // unhealed `[0x…]` placeholder, which would be baked into the child's stored name.
    // Falls back to the frozen string when the parent has no row yet (phase ordering).
    var rq = try Query.initCached(self.database,
        \\SELECT COALESCE(pn.name, r.name) AS name, r.namehash FROM registries r
        \\LEFT JOIN names pn ON pn.protocol = r.protocol AND pn.namehash = r.namehash AND pn.is_alias = 0
        \\WHERE r.address = ? AND r.protocol = ? AND r.created_block <= ?
        \\ORDER BY r.created_block DESC
        \\LIMIT 2
    );
    defer rq.deinit();
    try rq.bindText(registry_hex);
    try rq.bindText(protocol.toString());
    try rq.bindInt64(@intCast(block_number));

    if (!try rq.step()) return null;
    const name_span = rq.getTextSlice(0) orelse return null;
    const name_copy = try self.allocator.dupe(u8, name_span);
    errdefer self.allocator.free(name_copy);
    const namehash = if (rq.getTextSlice(1)) |hex| try Hash.fromHex(hex) else self.eth_namehash;
    if (try rq.step()) warnIfLiveMultiParent(self, protocol, registry_hex, block_number);
    return .{ .name = name_copy, .namehash = namehash };
}

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

/// Patch the placeholder rows a registration for (canonical_id, token_id) may
/// have left behind — SubregistryUpdated / ResolverUpdated processed before
/// the name existed. Only when the placeholder ledger says one was actually
/// written: on the common path this used to be four zero-row statements per
/// registration, one of them a full scan of `names`.
/// `emitting_registry` is the contract whose event is being resolved — the registry the label
/// lives in. Both placeholder strings (`canonicalId:N`, `tokenId:N`) are derived from a hash of
/// the LABEL alone, so they are not unique across registries: the same label under two parents
/// yields the same string. Passing the registry is what stops resolving one from renaming the
/// other's rows. See storage/names_registry.updateRegistryPlaceholderName.
fn patchPlaceholders(self: *Indexer, emitting_registry: Address, canonical_id: u256, token_id: u256, full_name: []const u8, namehash: Hash) void {
    if (self.placeholders.owesCanonicalPatch(canonical_id)) {
        var canonical_buf: [96]u8 = undefined;
        const canonical_placeholder = std.fmt.bufPrint(&canonical_buf, "canonicalId:{d}", .{canonical_id}) catch unreachable;
        if (self.database.updateRegistryPlaceholderName(emitting_registry, canonical_placeholder, full_name, namehash)) |_| {
            self.placeholders.canonicalPatched(canonical_id);
        } else |err| {
            std.log.warn("Failed to patch canonicalId placeholder: {}", .{err});
        }
    }
    if (self.placeholders.owesTokenPatch(token_id)) {
        var tokenid_buf: [96]u8 = undefined;
        const tokenid_placeholder = std.fmt.bufPrint(&tokenid_buf, "tokenId:{d}", .{token_id}) catch unreachable;
        if (self.database.updatePlaceholderEventsByName(emitting_registry, tokenid_placeholder, full_name, namehash)) |_| {
            self.placeholders.tokenPatched(token_id);
        } else |err| {
            std.log.warn("Failed to patch tokenId placeholder: {}", .{err});
        }
    }
}
