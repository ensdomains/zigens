const std = @import("std");
const ens_name = @import("../../utils/ens_name.zig");
const constants = @import("../../constants.zig");
const models = @import("../../types/models.zig");
// ABI decoding migrated to eth.zig-backed shim. Old `../abi.zig` kept for fallback.
const abi = @import("../abi_eth.zig");
const rpc = @import("../../rpc/client.zig");
const db = @import("../../storage/database.zig");
const hash_mod = @import("../../types/hash.zig");
const Hash = hash_mod.Hash;
const Address = @import("../../types/address.zig").Address;
const unknown_labels_storage = @import("../../storage/unknown_labels.zig");
const Indexer = @import("../indexer.zig").Indexer;
const utils = @import("../utils.zig");
const dns = @import("../../utils/dns.zig");
const names_storage = @import("../../storage/names.zig");
const ens_normalize = @import("../../utils/ens_normalize.zig");
const v1_names = @import("../../utils/v1_names.zig");

/// Returns true when the log came from the legacy pre-2020 ENS Registry
/// (0x314159…). The legacy registry continues to emit events post-migration
/// for callers that hold its address; the canonical post-2020 Registry
/// (0x00…2e1e) is the source of truth. Subgraph parity: this maps to
/// `Domain.isMigrated = !is_legacy`. Returns false when `old_ens_registry`
/// is zero in config (testnets / V2-only deployments).
fn isFromLegacyRegistry(self: *const Indexer, log_address: Address) bool {
    const legacy = self.config.v1_contracts.old_ens_registry;
    if (legacy.isZero()) return false;
    return legacy.eql(log_address);
}

/// Handle V1 ENS Registry NewOwner event
/// NewOwner(bytes32 indexed node, bytes32 indexed label, address owner)
/// This event is emitted when a subdomain is created
pub fn handleV1NewOwner(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    if (log.topics.len < 3) return error.InvalidTopicCount;
    if (log.data.len < 32) return error.InsufficientData;

    const parent_node = log.topics[1];
    const labelhash = log.topics[2];
    // Non-indexed payload: (address owner)
    const data_values = try abi.decodeValues(log.data, &.{.address}, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const owner = Address{ .bytes = data_values[0].address };

    // Stack-based hex conversions (no heap allocation)
    var parent_buf: [66]u8 = undefined;
    const parent_hex = parent_node.toHexBuf(&parent_buf);
    var labelhash_buf: [66]u8 = undefined;
    const labelhash_hex = labelhash.toHexBuf(&labelhash_buf);
    var owner_buf: [42]u8 = undefined;
    const owner_hex = owner.toHexBuf(&owner_buf);

    // Record the new owner as an Account on first observation. Skip the
    // zero-address sentinel (burned/cleared, not a real account holder).
    utils.recordAccountObservation(self, protocol, owner, log);

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

        const upsert_sql = try self.database.upsertSql(self.database.allocator, "temp_pre_migration_names", &.{ "protocol", "namehash", "label_hash", "parent_node", "owner", "block_number", "tx_hash", "log_index", "created_at" }, .ignore);
        defer self.database.allocator.free(upsert_sql);

        var q = try Query.initCached(self.database, upsert_sql);
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

        // Sibling parity: Transfer/NewResolver/NewTTL emit events rows in this
        // era; NewOwner silently didn't - the events feed had a hole for the
        // most common pre-migration event (readiness review, 2026-06-06).
        const pre_event_data = try std.fmt.allocPrint(self.allocator, "{{\"parentNode\":\"{s}\",\"labelhash\":\"{s}\",\"subdomain\":\"{s}\",\"owner\":\"{s}\"}}", .{
            parent_hex, labelhash_hex, subdomain_hex, owner_hex,
        });
        try utils.emitEvent(self, protocol, log, .transfer, null, subdomain_namehash, pre_event_data);

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

    const full_name = try ens_name.join(self.allocator, label_str, parent_name_str);
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

        // Subgraph parity: when V1 NewOwner repoints to the zero address, the
        // name is considered burned. If the row is also fully cleared
        // (resolver=0, no expiry) AND has no live subdomains, delete it and
        // walk UP the parent chain GCing empty ancestors. V2 hard-deletes on
        // burn already (LabelUnregistered cascade), so this only fires for V1.
        if (owner.isZero()) {
            const deleted = self.database.recursivelyGcEmptyDomain(subdomain_namehash) catch |err| blk: {
                std.log.warn("recursivelyGcEmptyDomain failed for V1 NewOwner: {}", .{err});
                break :blk 0;
            };
            if (deleted > 0) std.log.debug("V1 GC (NewOwner): deleted {d} empty domain(s) at/above {s}", .{ deleted, subdomain_hex });
        }
    } else {
        // Create new name record
        const name_copy = try self.allocator.dupe(u8, full_name);
        const label_copy = try self.allocator.dupe(u8, label_str);
        // Root parent is the empty string, never null (parent_name is NOT NULL,
        // and the subdomain join `sub.parent_name = parent.name` must match the
        // root row's empty name). See ens_name.ROOT_PARENT.
        const parent_copy = try self.allocator.dupe(u8, parent_name_str orelse ens_name.ROOT_PARENT);

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
            .is_legacy = isFromLegacyRegistry(self, log.address),
        };
        defer name.deinit(self.allocator);

        self.insertName(name) catch |err| {
            std.log.warn("Failed to create subdomain name {s}: {}", .{ full_name, err });
        };
    }

    // Still record unresolved labels for backfill (calldata decoding may find them later)
    if (resolved_label == null) {
        unknown_labels_storage.insertUnknownLabel(
            self.database,
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
    // Non-indexed payload: (address owner)
    const data_values = try abi.decodeValues(log.data, &.{.address}, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const owner = Address{ .bytes = data_values[0].address };

    var node_buf: [66]u8 = undefined;
    const node_hex = node.toHexBuf(&node_buf);
    var owner_buf: [42]u8 = undefined;
    const owner_hex = owner.toHexBuf(&owner_buf);

    utils.recordAccountObservation(self, protocol, owner, log);

    std.log.debug("V1 RegistryTransfer: node={s} owner={s}", .{ node_hex, owner_hex });

    // Persist the owner change. Subgraph reference (Registry.ts:188-191) does
    // an unconditional `set({ ownerId })`. We don't auto-create a Domain row
    // here: per ENS semantics, a Transfer is supposed to follow an earlier
    // NewOwner (which is what creates the row); if no row exists, this
    // ownership update has nothing to attach to and a synthetic orphan row
    // would lack name/label/parent context.
    if (self.write_buffer.active) {
        try self.write_buffer.updateNameOwner(node, owner);
    } else {
        try names_storage.updateNameOwner(self.database, node, owner);
    }

    // Track provenance: this event came from either the legacy pre-2020
    // Registry or the canonical post-2020 Registry. No-op if no row exists.
    names_storage.updateNameIsLegacy(self.database, node, isFromLegacyRegistry(self, log.address)) catch {};

    // Subgraph parity: a Transfer to the zero address is a burn. If the row
    // is also fully cleared (resolver=0, no expiry) AND has no live subdomains,
    // delete it and walk UP the parent chain GCing empty ancestors. V2
    // hard-deletes on burn (LabelUnregistered cascade), so this only fires
    // for V1. Skipped while write_buffer is active — the GC needs to read
    // the row's owner/resolver/parent_namehash which is not yet flushed.
    if (owner.isZero() and !self.write_buffer.active) {
        const deleted = self.database.recursivelyGcEmptyDomain(node) catch |err| blk: {
            std.log.warn("recursivelyGcEmptyDomain failed for V1 RegistryTransfer: {}", .{err});
            break :blk 0;
        };
        if (deleted > 0) std.log.debug("V1 GC (RegistryTransfer): deleted {d} empty domain(s) at/above {s}", .{ deleted, node_hex });
    }

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"node\":\"{s}\",\"owner\":\"{s}\"}}", .{
        node_hex, owner_hex,
    });

    try utils.emitEvent(self, protocol, log, .registry_transfer, null, node, event_data);
}

/// Handle V1 ENS Registry NewResolver event
/// NewResolver(bytes32 indexed node, address resolver)
pub fn handleV1NewResolver(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    if (log.topics.len < 2) return error.InvalidTopicCount;
    if (log.data.len < 32) return error.InsufficientData;

    const node = log.topics[1];
    // Non-indexed payload: (address resolver)
    const data_values = try abi.decodeValues(log.data, &.{.address}, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const resolver = Address{ .bytes = data_values[0].address };

    var node_buf: [66]u8 = undefined;
    const node_hex = node.toHexBuf(&node_buf);
    var resolver_buf: [42]u8 = undefined;
    const resolver_hex = resolver.toHexBuf(&resolver_buf);

    std.log.debug("V1 NewResolver: node={s} resolver={s}", .{ node_hex, resolver_hex });

    // The subgraph upserts a Domain row here (Registry.ts:229-285), but it has
    // a queryable typed Domain model where an orphan row is at least
    // identifiable by namehash. Our Name row requires meaningful name/label/
    // parent context that the NewResolver event does not carry; constructing
    // one with all-null/zero fields would produce a row that is useless to
    // clients and indistinguishable from corruption. We therefore intentionally
    // skip auto-create: if no row exists, the UPDATE silently affects zero
    // rows. The expected order is NewOwner (creates) -> NewResolver; if a
    // NewResolver arrives first, the later NewOwner will create the row
    // without the resolver set. This trades a small completeness gap for
    // schema integrity.
    const existing = names_storage.getNameByNamehash(self.database, node) catch null;
    if (existing) |row| {
        var row_mut = row;
        // Capture the name before deinit so we can record the Resolver entity
        // binding. The upsert is INSERT OR IGNORE so a non-zero resolver only
        // creates a row the first time we observe the (protocol, address,
        // namehash) triple; later NewResolver events with the same triple are
        // no-ops, matching subgraph semantics.
        if (!resolver.isZero()) {
            self.database.upsertResolverEntity(
                protocol,
                resolver_hex,
                node_hex,
                row_mut.name orelse "[unknown]",
                log.block_number,
                self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
            ) catch |err| {
                std.log.debug("upsertResolverEntity failed: {}", .{err});
            };
        }
        row_mut.deinit(self.allocator);
        if (self.write_buffer.active) {
            try self.write_buffer.updateNameResolver(node, resolver);
        } else {
            try names_storage.updateNameResolver(self.database, node, resolver);
        }
        // Track legacy/canonical Registry provenance on the same event.
        names_storage.updateNameIsLegacy(self.database, node, isFromLegacyRegistry(self, log.address)) catch {};

        // Subgraph parity: NewResolver materializes `Domain.resolvedAddressId`
        // by calling the resolver's `addr(node)` at this block. We persist the
        // result to `names.resolved_address` so reads don't have to do the
        // query-time resolver lookup for the common case.
        //
        // V1-only: V2 doesn't materialize this column; V2 readers continue to
        // resolve via `Resolver.addr(coinType:60)` at query time.
        //
        // TODO: enrich with a real eth_call to `addr(bytes32)` (selector
        // 0x3b3b57de). The structural fix lands here (column + writer wired);
        // the RPC enrichment is a follow-up — we conservatively clear the
        // materialized value here so any stale prior resolution is invalidated
        // when the resolver flips. Skipped while write_buffer is active —
        // there's no buffered writer for resolved_address and the per-event
        // path is a no-op for non-existent rows anyway.
        if (resolver.isZero()) {
            // Resolver cleared: clear the materialized address too.
            if (!self.write_buffer.active) {
                names_storage.updateResolvedAddressToNull(self.database, node) catch |err| {
                    std.log.debug("updateResolvedAddressToNull failed: {}", .{err});
                };
            }
        } else {
            // Resolver set/changed: invalidate the materialized address. A
            // subsequent eth_call (once wired) will repopulate; for now this
            // leaves the column NULL and forces the query-time fallback.
            if (!self.write_buffer.active) {
                names_storage.updateResolvedAddressToNull(self.database, node) catch |err| {
                    std.log.debug("updateResolvedAddressToNull failed: {}", .{err});
                };
            }
        }
    } else {
        std.log.debug("V1 NewResolver: no Name row for node={s} — skipping resolver update (auto-create disabled, see comment)", .{node_hex});
    }
    try self.registerResolverOnce(protocol, resolver_hex, log.block_number);

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
    // Non-indexed payload: (uint64 ttl)
    const data_values = try abi.decodeValues(log.data, &.{.uint64}, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const ttl: u64 = @truncate(data_values[0].uint256);

    var node_buf: [66]u8 = undefined;
    const node_hex = node.toHexBuf(&node_buf);

    std.log.debug("V1 NewTTL: node={s} ttl={d}", .{ node_hex, ttl });

    // Persist TTL on the Name row. No-op if the row doesn't exist yet —
    // V1 NewTTL on an unregistered node has nothing to attach to.
    names_storage.updateNameTTL(self.database, node, ttl) catch |err| {
        std.log.debug("V1 NewTTL: updateNameTTL failed for {s}: {}", .{ node_hex, err });
    };
    // Track legacy/canonical Registry provenance on the same event.
    names_storage.updateNameIsLegacy(self.database, node, isFromLegacyRegistry(self, log.address)) catch {};

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

    // Non-indexed payload: (bytes name, address owner, uint32 fuses, uint64 expiry)
    const data_values = try abi.decodeValues(
        log.data,
        &.{ .bytes, .address, .uint32, .uint64 },
        self.allocator,
    );
    defer abi.freeValues(data_values, self.allocator);
    const name_bytes = data_values[0].bytes;
    const owner = Address{ .bytes = data_values[1].address };
    const fuses: u32 = @truncate(data_values[2].uint256);
    const expiry: u64 = @truncate(data_values[3].uint256);

    var node_buf: [66]u8 = undefined;
    const node_hex = node.toHexBuf(&node_buf);
    var owner_buf: [42]u8 = undefined;
    const owner_hex = owner.toHexBuf(&owner_buf);

    utils.recordAccountObservation(self, protocol, owner, log);

    std.log.debug("V1 NameWrapped: node={s} owner={s} fuses={d} expiry={d}", .{ node_hex, owner_hex, fuses, expiry });

    if (self.write_buffer.active) {
        try self.write_buffer.updateNameWrapperState(node, fuses, expiry);
        try self.write_buffer.updateNameOwner(node, owner);
    } else {
        try names_storage.updateNameWrapperState(self.database, node, fuses, expiry);
        try names_storage.updateNameOwner(self.database, node, owner);
    }

    // PCC-aware Domain.expiry mirror per subgraph semantics: when the
    // PARENT_CANNOT_CONTROL fuse is burned, the wrapper expiry IS the canonical
    // Domain expiry — mirror it (max with existing) so queries that read
    // Domain.expiryDate see the right date for name-locked subdomains.
    // Edge case: if the names row doesn't exist yet (wrap on a name we never
    // saw via Registry), the helper's UPDATE affects zero rows — no-op, fine.
    const PARENT_CANNOT_CONTROL: u32 = 0x10000;
    if ((fuses & PARENT_CANNOT_CONTROL) != 0) {
        const expiry_i64: i64 = if (expiry > @as(u64, @intCast(std.math.maxInt(i64)))) 0 else @intCast(expiry);
        self.database.updateDomainExpiryIfGreater(node, expiry_i64) catch |err| {
            std.log.debug("PCC expiry mirror failed (NameWrapped): {}", .{err});
        };
    }

    // Heal labels from DNS-encoded name (e.g., \x03sub\x07vitalik\x03eth\x00 → "sub.vitalik.eth")
    // The NameWrapped event contains the full plaintext name — use it to resolve unknown labels.
    healLabelsFromDNSName(self, name_bytes, node, log.block_number) catch |err| {
        std.log.debug("DNS label heal failed for node={s}: {}", .{ node_hex, err });
    };

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"node\":\"{s}\",\"owner\":\"{s}\",\"fuses\":{d},\"expiry\":{d}}}", .{
        node_hex, owner_hex, fuses, expiry,
    });

    try utils.emitEvent(self, protocol, log, .name_wrapped, null, node, event_data);
}

/// Handle V1 Name Wrapper NameUnwrapped event
/// NameUnwrapped(bytes32 indexed node, address owner)
pub fn handleV1NameUnwrapped(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    if (log.topics.len < 2) return error.InvalidTopicCount;
    if (log.data.len < 32) return error.InsufficientData;

    const node = log.topics[1];

    // Non-indexed payload: (address owner)
    const data_values = try abi.decodeValues(log.data, &.{.address}, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const owner = Address{ .bytes = data_values[0].address };

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

    // Subgraph parity (`NameWrapper.ts:250-259`): on unwrap, reset
    // domain.expiryDate to null UNLESS the parent is the .eth registrar — for
    // PCC-mirrored subnames, the wrapper expiry was the canonical Domain
    // expiry, and now that the wrapper state is gone it must be cleared too.
    // For .eth 2LDs the registration row's expiry remains canonical (don't
    // touch names.expiry there).
    //
    // Only runs in incremental sync (write_buffer inactive): the buffer can't
    // service the parent lookup needed to decide whether to clear. During bulk
    // sync, NameUnwrapped is rare on .eth subnames; a residual stale expiry
    // gets a chance to be corrected by post-sync passes.
    if (!self.write_buffer.active) {
        if (try names_storage.getNameByNamehash(self.database, node)) |row_raw| {
            var row = row_raw;
            defer row.deinit(self.allocator);
            if (!row.parent_namehash.eql(constants.WellKnown.eth_namehash)) {
                names_storage.clearNameExpiry(self.database, node) catch |err| {
                    std.log.debug("clearNameExpiry failed on NameUnwrapped: {}", .{err});
                };
            }
        }
    }

    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"node\":\"{s}\",\"owner\":\"{s}\"}}", .{
        node_hex, owner_hex,
    });

    try utils.emitEvent(self, protocol, log, .name_unwrapped, null, node, event_data);
}

/// Handle V1 Name Wrapper FusesSet event
/// FusesSet(bytes32 indexed node, uint32 fuses)
pub fn handleV1FusesSet(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    if (log.topics.len < 2) return error.InvalidTopicCount;
    if (log.data.len < 32) return error.InsufficientData;

    const node = log.topics[1];

    // Non-indexed payload: (uint32 fuses)
    const data_values = try abi.decodeValues(log.data, &.{.uint32}, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const fuses: u32 = @truncate(data_values[0].uint256);

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

    // PCC-aware Domain.expiry mirror per subgraph semantics: if FusesSet burns
    // PARENT_CANNOT_CONTROL, the existing wrapper_expiry becomes the canonical
    // Domain expiry. We look it up from the names row (the FusesSet event
    // doesn't carry an expiry value of its own).
    const PARENT_CANNOT_CONTROL: u32 = 0x10000;
    if ((fuses & PARENT_CANNOT_CONTROL) != 0) {
        if (try self.database.getNameByNamehash(node)) |existing_raw| {
            var existing = existing_raw;
            defer existing.deinit(self.database.allocator);
            if (existing.wrapper_expiry) |wexp| {
                self.database.updateDomainExpiryIfGreater(node, wexp) catch |err| {
                    std.log.debug("PCC expiry mirror failed (FusesSet): {}", .{err});
                };
            }
        }
    }

    // Store event
    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"node\":\"{s}\",\"fuses\":{d}}}", .{
        node_hex,
        fuses,
    });

    try utils.emitEvent(self, protocol, log, .fuses_set, null, node, event_data);
}

/// Handle V1 Name Wrapper ExpiryExtended event
/// ExpiryExtended(bytes32 indexed node, uint64 expiry)
pub fn handleV1ExpiryExtended(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    // topics[0] = event signature
    // topics[1] = indexed node (namehash)
    if (log.topics.len < 2) return error.InvalidTopicCount;
    if (log.data.len < 32) return error.InsufficientData;

    const node = log.topics[1];

    // Non-indexed payload: (uint64 expiry)
    const data_values = try abi.decodeValues(log.data, &.{.uint64}, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const expiry: u64 = @truncate(data_values[0].uint256);

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

    // PCC-aware Domain.expiry mirror per subgraph semantics: if the existing
    // wrapper_fuses has PARENT_CANNOT_CONTROL burned, mirror this new wrapper
    // expiry into Domain.expiry. wrapper_fuses is stored as a decimal TEXT
    // string; parse failure or null → treat as fuses=0 (no PCC) → skip mirror.
    const PARENT_CANNOT_CONTROL: u32 = 0x10000;
    if (try self.database.getNameByNamehash(node)) |existing_raw| {
        var existing = existing_raw;
        defer existing.deinit(self.database.allocator);
        const existing_fuses: u32 = if (existing.wrapper_fuses) |fuses_str|
            std.fmt.parseInt(u32, fuses_str, 10) catch 0
        else
            0;
        if ((existing_fuses & PARENT_CANNOT_CONTROL) != 0) {
            const expiry_i64: i64 = if (expiry > @as(u64, @intCast(std.math.maxInt(i64)))) 0 else @intCast(expiry);
            self.database.updateDomainExpiryIfGreater(node, expiry_i64) catch |err| {
                std.log.debug("PCC expiry mirror failed (ExpiryExtended): {}", .{err});
            };
        }
    }

    // Store event. NameWrapper ExpiryExtended is a wrapper-fuse expiry change,
    // not a registration renewal — the subgraph emits a distinct
    // WrapperExtended event for this, separate from NameRenewed. We previously
    // emitted `.name_renewed` here, which double-counted renewals against the
    // canonical BaseRegistrar NameRenewed event. Use `.expiry_updated` to
    // surface the wrapper expiry change without conflating it with renewal.
    const event_data = try std.fmt.allocPrint(self.allocator, "{{\"node\":\"{s}\",\"expiry\":{d}}}", .{
        node_hex,
        expiry,
    });

    try utils.emitEvent(self, protocol, log, .expiry_updated, null, node, event_data);
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

    utils.recordAccountObservation(self, protocol, to, log);

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

            // Subgraph parity (`Registrar.ts:287, 313-327`): the Registration's
            // registrant follows the ERC721 token, even on burn (to = zero).
            // Without this, `registrations.registrant` stays pinned to the
            // original registrant after any secondary transfer.
            self.database.updateRegistrationRegistrant(.v1, namehash, to) catch |err| {
                std.log.debug("updateRegistrationRegistrant failed: {}", .{err});
            };

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

    // Non-indexed payload: (uint256 expires)
    const data_values = try abi.decodeValues(log.data, &.{.uint256}, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const expires = data_values[0].uint256;

    var owner_buf: [42]u8 = undefined;
    const owner_hex = owner.toHexBuf(&owner_buf);

    utils.recordAccountObservation(self, protocol, owner, log);

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
            // BaseRegistrar fires from the .eth registrar contract, not the
            // ENS Registry itself — so the row's provenance for the canonical
            // Registry is "new" (post-2020). Legacy pre-migration .eth names
            // are seeded via the V1 Registry NewOwner path on the legacy
            // contract.
            .is_legacy = false,
        };

        if (self.write_buffer.active) {
            try self.write_buffer.insertName(name_record);
        } else {
            try self.insertName(name_record);
        }

        // Canonical V1 registration row. V1 has only this one event type per
        // registration (no LabelRegistered analog), so we always write here.
        const expiry_u64: u64 = @truncate(expires);
        self.database.insertRegistration(
            protocol,
            namehash,
            label,
            "eth",
            owner,
            self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
            if (expiry_u64 == 0) null else expiry_u64,
            log.block_number,
            log.transaction_hash,
            log.log_index,
            .name_registered,
        ) catch |err| {
            std.log.warn("insertRegistration failed for {s}: {}", .{ full_name, err });
        };

        // Store event with name and namehash
        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"id\":\"{s}\",\"name\":\"{s}\",\"owner\":\"{s}\",\"expires\":{d}}}", .{
            token_id_hex,
            full_name,
            owner_hex,
            expires,
        });

        try utils.emitEvent(self, protocol, log, .name_registered, full_name, namehash, event_data);
    } else {
        // Label not found yet (Controller event hasn't been processed yet, or
        // is in a later chunk). The subgraph creates the Registration row
        // anyway and lets the controller event update the human label later.
        // We mirror that: insert with bracket-notation placeholder for `name`
        // and `label`. When the Controller event fires it calls
        // writeControllerRegistration → which now also calls updateNameLabel
        // to overwrite the placeholder with the human-readable preimage.
        std.log.debug("V1 BaseRegistrar NameRegistered: tokenID {s} label not found yet, inserting with placeholder", .{token_id_hex});

        // tokenId IS the labelhash in V1
        const label_hash = blk: {
            var bytes: [32]u8 = undefined;
            std.mem.writeInt(u256, &bytes, token_id, .big);
            break :blk Hash{ .bytes = bytes };
        };

        // Compute namehash from labelhash: keccak256(eth_node || labelhash)
        const eth_node = constants.WellKnown.eth_namehash;
        var namehash_input: [64]u8 = undefined;
        @memcpy(namehash_input[0..32], &eth_node.bytes);
        @memcpy(namehash_input[32..64], &label_hash.bytes);
        const Keccak256 = std.crypto.hash.sha3.Keccak256;
        var namehash_bytes: [32]u8 = undefined;
        Keccak256.hash(&namehash_input, &namehash_bytes, .{});
        const namehash = Hash{ .bytes = namehash_bytes };

        // Bracket-notation placeholder: same convention as handleV1NewOwner (line ~146)
        var label_buf: [66]u8 = undefined; // "[" + 64 hex chars + "]"
        var label_hash_hex_buf: [66]u8 = undefined;
        const label_hash_hex = label_hash.toHexBuf(&label_hash_hex_buf);
        label_buf[0] = '[';
        @memcpy(label_buf[1..65], label_hash_hex[2..66]);
        label_buf[65] = ']';
        const placeholder_label = label_buf[0..66];

        // full_name ownership transfers to emitEvent.
        const full_name = try std.fmt.allocPrint(self.allocator, "{s}.eth", .{placeholder_label});

        // Stack-buf v1_label_hash hex (matches label-known path convention).
        var v1_label_hash_buf: [66]u8 = undefined;
        const v1_label_hash_hex = label_hash.toHexBuf(&v1_label_hash_buf);

        // Strings borrowed (literal "eth", stack-buf placeholder_label / v1_label_hash_hex,
        // full_name owned by emitEvent). insertName + write_buffer.insertName
        // both copy/dupe internally so this is safe.
        const name_record = models.Name{
            .name = full_name,
            .namehash = namehash,
            .label = placeholder_label,
            .label_hash = label_hash,
            .parent_name = "eth",
            .parent_namehash = eth_node,
            .protocol = protocol,
            .registry = self.config.v1_contracts.ens_registry,
            .owner = owner,
            .registrant = owner,
            .resolver = Address.zero,
            .token_id = token_id,
            .canonical_id = token_id,
            .token_version = 0,
            .expiry = @truncate(expires),
            .registry_locked = false,
            .migrated = false,
            .created_block = log.block_number,
            .created_at = self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
            .registered_at = self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
            .updated_block = log.block_number,
            .updated_at = std.time.timestamp(),
            .is_wrapped = false,
            .wrapper_fuses = null,
            .wrapper_expiry = null,
            .is_v1_name = true,
            .v1_label_hash = v1_label_hash_hex,
            .is_legacy = false,
        };

        if (self.write_buffer.active) {
            try self.write_buffer.insertName(name_record);
        } else {
            try self.insertName(name_record);
        }

        // Canonical registrations row (same as the label-known path). Placeholder
        // label gets overwritten by the Controller event via
        // updateRegistrationEconomics (which sets label_name to the preimage).
        const expiry_u64: u64 = @truncate(expires);
        self.database.insertRegistration(
            protocol,
            namehash,
            placeholder_label,
            "eth",
            owner,
            self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp),
            if (expiry_u64 == 0) null else expiry_u64,
            log.block_number,
            log.transaction_hash,
            log.log_index,
            .name_registered,
        ) catch |err| {
            std.log.warn("insertRegistration (placeholder) failed for tokenID {s}: {}", .{ token_id_hex, err });
        };

        const event_data = try std.fmt.allocPrint(self.allocator, "{{\"id\":\"{s}\",\"owner\":\"{s}\",\"expires\":{d}}}", .{
            token_id_hex,
            owner_hex,
            expires,
        });

        try utils.emitEvent(self, protocol, log, .name_registered, full_name, namehash, event_data);
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

    // Non-indexed payload: (uint256 expires)
    const data_values = try abi.decodeValues(log.data, &.{.uint256}, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const expires = data_values[0].uint256;

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

        // Update the name's expiry. Renewal-specific: wrapped rows keep their
        // grace-inclusive stored expiry (direct registrar renews emit no
        // ExpiryExtended, so nothing else would re-add the 90d).
        if (self.write_buffer.active) {
            try self.write_buffer.updateV1RenewalExpiry(namehash, @truncate(expires));
        } else {
            try names_storage.updateV1RenewalExpiry(self.database, namehash, @truncate(expires));
        }

        // Subgraph parity (`Registrar.ts:271`): the Registration row's expiry
        // must also advance on renewal — otherwise `registrations.expiry`
        // remains pinned to the original registration value forever.
        const reg_expiry_i64: i64 = if (expires > @as(u256, @intCast(std.math.maxInt(i64)))) 0 else @intCast(expires);
        self.database.updateRegistrationExpiry(.v1, namehash, reg_expiry_i64) catch |err| {
            std.log.debug("updateRegistrationExpiry failed: {}", .{err});
        };

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

/// Shared storage/emit path for all three V1 ETH Controller `NameRegistered`
/// variants (legacy 5-arg, wrapped 6-arg, unwrapped 7-arg). They differ only
/// in the non-indexed data tail (baseCost/premium split + optional referrer);
/// indexed topology — labelhash @ topic[1], owner @ topic[2] — is identical.
///
/// `name` ownership transfers to `emitEvent`; caller must hold it on the
/// indexer allocator (typically duped out of the schema-decoded borrow).
fn writeControllerRegistration(
    self: *Indexer,
    protocol: models.Protocol,
    log: rpc.Log,
    name: []const u8,
    label_hash: Hash,
    owner: Address,
    base_cost: u256,
    premium: u256,
    expires: u256,
    referrer_opt: ?Hash,
) !void {
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

    // Backfill the human-readable label/name on the names row written earlier
    // by BaseRegistrar.NameRegistered with bracket placeholder. (C6 fix: the
    // BaseRegistrar handler now always inserts the row, using `[labelhash].eth`
    // when the label is unknown; this UPDATE replaces the placeholder once the
    // Controller event delivers the preimage.) When the row was created with
    // the real label already (Controller-before-Registrar ordering on a
    // pre-warmed v1_labels cache), the UPDATE writes the same values — no-op.
    // `name` here is the bare label (e.g. "vitalik"); the full name is
    // "vitalik.eth".
    {
        const full_name = std.fmt.allocPrint(self.allocator, "{s}.eth", .{name}) catch null;
        if (full_name) |fn_str| {
            defer self.allocator.free(fn_str);
            names_storage.updateNameLabel(self.database, protocol, namehash, name, fn_str, ens_normalize.nameIsNormalized(self.allocator, fn_str)) catch |err| {
                std.log.debug("updateNameLabel failed (placeholder will heal via backfillMissingEth2LDNames): {}", .{err});
            };
        }
    }

    // Enrich the registrations row created earlier by BaseRegistrar.NameRegistered
    // with controller-side economics + preimage. BaseRegistrar.NameRegistered
    // fires first in the V1 .eth flow (it's what mints the ERC721) and writes
    // the canonical registrations row with just (tokenId, owner, expires);
    // this Controller event arrives later in the same tx (or shortly after)
    // carrying baseCost / premium / human label / optional referrer.
    self.database.updateRegistrationEconomics(.v1, namehash, name, base_cost, premium, referrer_opt) catch |err| {
        std.log.debug("updateRegistrationEconomics failed: {} (row may not yet exist)", .{err});
    };

    // Build event_data JSON. `cost` is preserved as an alias for `baseCost` so
    // existing clients that read `.cost` from legacy-variant events still work
    // across all three signatures.
    const total = base_cost + premium;
    const event_data = if (referrer_opt) |referrer_hash| blk: {
        var referrer_buf: [66]u8 = undefined;
        const referrer_hex = referrer_hash.toHexBuf(&referrer_buf);
        break :blk try std.fmt.allocPrint(
            self.allocator,
            "{{\"name\":\"{s}\",\"label\":\"{s}\",\"owner\":\"{s}\",\"baseCost\":{d},\"premium\":{d},\"cost\":{d},\"expires\":{d},\"referrer\":\"{s}\"}}",
            .{ name, label_hash_hex, owner_hex, base_cost, premium, total, expires, referrer_hex },
        );
    } else try std.fmt.allocPrint(
        self.allocator,
        "{{\"name\":\"{s}\",\"label\":\"{s}\",\"owner\":\"{s}\",\"baseCost\":{d},\"premium\":{d},\"cost\":{d},\"expires\":{d}}}",
        .{ name, label_hash_hex, owner_hex, base_cost, premium, total, expires },
    );

    try utils.emitEvent(self, protocol, log, .name_registered, name, namehash, event_data);
}

/// Handle V1 ETH Registrar Controller NameRegistered event (5-arg legacy)
/// NameRegistered(string name, bytes32 indexed label, address indexed owner, uint256 cost, uint256 expires)
/// LegacyEthRegistrarController. No baseCost/premium split, no referrer.
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

    // Non-indexed payload: (string name, uint256 cost, uint256 expires).
    // 2 uints (cost, expires) — not 3 like the 6-arg variant.
    const data_values = try abi.decodeValues(
        log.data,
        &.{ .string, .uint256, .uint256 },
        self.allocator,
    );
    defer abi.freeValues(data_values, self.allocator);
    const name_borrow = data_values[0].string;
    const cost = data_values[1].uint256;
    const expires = data_values[2].uint256;
    // emitEvent takes ownership of the name; dupe out of the borrowed slice.
    const name = try self.allocator.dupe(u8, name_borrow);
    errdefer self.allocator.free(name);

    // Legacy variant: map `cost` -> baseCost, premium = 0, no referrer.
    try writeControllerRegistration(self, protocol, log, name, label_hash, owner, cost, 0, expires, null);
}

/// Handle V1 ETH Registrar Controller NameRegistered event (6-arg wrapped)
/// NameRegistered(string name, bytes32 indexed label, address indexed owner, uint256 baseCost, uint256 premium, uint256 expires)
/// WrappedEthRegistrarController (mainnet ~block 16,925,618 onward).
pub fn handleV1ETHControllerNameRegistered6Arg(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    if (log.topics.len < 3) {
        std.log.warn("V1 ETH Controller NameRegistered (6-arg) event has unexpected topic count: {d}, skipping", .{log.topics.len});
        return;
    }

    const label_hash = log.topics[1];
    const owner = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);

    // Non-indexed payload: (string name, uint256 baseCost, uint256 premium, uint256 expires).
    const data_values = try abi.decodeValues(
        log.data,
        &.{ .string, .uint256, .uint256, .uint256 },
        self.allocator,
    );
    defer abi.freeValues(data_values, self.allocator);
    const name_borrow = data_values[0].string;
    const base_cost = data_values[1].uint256;
    const premium = data_values[2].uint256;
    const expires = data_values[3].uint256;
    const name = try self.allocator.dupe(u8, name_borrow);
    errdefer self.allocator.free(name);

    try writeControllerRegistration(self, protocol, log, name, label_hash, owner, base_cost, premium, expires, null);
}

/// Handle V1 ETH Registrar Controller NameRegistered event (7-arg unwrapped)
/// NameRegistered(string label, bytes32 indexed labelhash, address indexed owner, uint256 baseCost, uint256 premium, uint256 expires, bytes32 referrer)
/// UnwrappedEthRegistrarController. `referrer` is NOT indexed — sits at the
/// data tail per the ensnode handler signature.
pub fn handleV1ETHControllerNameRegistered7Arg(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    if (log.topics.len < 3) {
        std.log.warn("V1 ETH Controller NameRegistered (7-arg) event has unexpected topic count: {d}, skipping", .{log.topics.len});
        return;
    }

    const label_hash = log.topics[1];
    const owner = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);

    // Non-indexed payload: (string label, uint256 baseCost, uint256 premium, uint256 expires, bytes32 referrer).
    const data_values = try abi.decodeValues(
        log.data,
        &.{ .string, .uint256, .uint256, .uint256, .bytes32 },
        self.allocator,
    );
    defer abi.freeValues(data_values, self.allocator);
    const name_borrow = data_values[0].string;
    const base_cost = data_values[1].uint256;
    const premium = data_values[2].uint256;
    const expires = data_values[3].uint256;
    const referrer_fb = data_values[4].fixed_bytes;
    const referrer = Hash{ .bytes = referrer_fb.data };
    const name = try self.allocator.dupe(u8, name_borrow);
    errdefer self.allocator.free(name);

    try writeControllerRegistration(self, protocol, log, name, label_hash, owner, base_cost, premium, expires, referrer);
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

    // Non-indexed payload: (string name, uint256 cost, uint256 expires).
    // Schema-driven decode replaces a previous manual offset walk over the
    // string tail.
    const data_values = try abi.decodeValues(
        log.data,
        &.{ .string, .uint256, .uint256 },
        self.allocator,
    );
    defer abi.freeValues(data_values, self.allocator);
    const name_borrow = data_values[0].string;
    const cost = data_values[1].uint256;
    const expires = data_values[2].uint256;
    // emitEvent takes ownership of the name; dupe out of the borrowed slice.
    const name = try self.allocator.dupe(u8, name_borrow);
    errdefer self.allocator.free(name);

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

    // Intentionally do NOT emit a `.name_renewed` event here. The canonical
    // renewal event is the BaseRegistrar NameRenewed (handled in
    // handleV1BaseRegistrarNameRenewed). The ETH Controller fires its own
    // NameRenewed in the same transaction, and the subgraph treats it solely
    // as a label-preimage source (Registry.ts reference). Previously this
    // handler also emitted `.name_renewed`, producing duplicate renewal rows
    // (2x for unwrapped names; 3x when combined with the NameWrapper
    // ExpiryExtended fix). We keep the label-cache + v1_labels backfill above
    // because they're load-bearing for label resolution, but we suppress the
    // duplicate event emit. `name` is duped (no longer transferred to
    // emitEvent), so we free it explicitly here. `cost` is consumed by the
    // debug log above; `protocol` is unused now that we no longer emit.
    _ = protocol;
    self.allocator.free(name);
}

/// Handle V1 ETH Registrar Controller NameRenewed event (5-arg unwrapped)
/// NameRenewed(string label, bytes32 indexed labelhash, uint256 cost, uint256 expires, bytes32 referrer)
/// UnwrappedEthRegistrarController. Mirrors the legacy handler: cache label
/// preimage and backfill v1_labels, but ABSTAIN from emitting `.name_renewed`
/// — BaseRegistrar NameRenewed remains the canonical source per Phase 4A
/// dedup. We deliberately do NOT touch registrations.referrer here: the
/// referrer on a registration is set at mint time and a renewal does not
/// change the original attribution.
pub fn handleV1ETHControllerNameRenewedWithReferrer(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    if (log.topics.len < 2) {
        std.log.warn("V1 ETH Controller NameRenewed (with referrer) event has unexpected topic count: {d}, skipping", .{log.topics.len});
        return;
    }

    const label_hash = log.topics[1];

    // Non-indexed payload: (string label, uint256 cost, uint256 expires, bytes32 referrer).
    const data_values = try abi.decodeValues(
        log.data,
        &.{ .string, .uint256, .uint256, .bytes32 },
        self.allocator,
    );
    defer abi.freeValues(data_values, self.allocator);
    const name_borrow = data_values[0].string;
    const cost = data_values[1].uint256;
    const expires = data_values[2].uint256;
    const name = try self.allocator.dupe(u8, name_borrow);
    errdefer self.allocator.free(name);

    var label_hash_buf: [66]u8 = undefined;
    const label_hash_hex = label_hash.toHexBuf(&label_hash_buf);

    std.log.debug("V1 ETH Controller NameRenewed (with referrer): name={s} label_hash={s} cost={d} expires={d}", .{
        name,
        label_hash_hex,
        cost,
        expires,
    });

    // Store/update the tokenID->label mapping (load-bearing for label resolution).
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

    // Populate the in-memory label cache.
    try self.putCachedV1Label(label_hash_hex, name);

    // Suppress the event emit (BaseRegistrar is canonical). See legacy handler
    // above for the full rationale.
    _ = protocol;
    self.allocator.free(name);
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

    utils.recordAccountObservation(self, protocol, addr, log);

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

    try utils.emitEvent(self, protocol, log, .reverse_claimed, null, node, event_data);
}

/// Handle V2 L2ReverseRegistrar / StandaloneReverseRegistrar NameForAddrChanged event.
///   NameForAddrChanged(address indexed addr, string name)
///
/// V2 stores the primary name directly on the reverse registrar (no node
/// indirection) — there is no `addr.reverse` ENS subtree like V1 has. The
/// equivalent reverse namehash for an address `a` on chain `c` is computed
/// off-chain as `namehash("<a>.<c-hex>.reverse")` if we ever need one. For now
/// we just record the event so the events feed reflects the state change; the
/// reverse_records table (which is V1-shaped) is updated with a zero node so
/// downstream code can still find the most-recent reverse-claim block.
pub fn handleV2NameForAddrChanged(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    if (log.topics.len < 2) return error.InvalidTopicCount;

    const addr = try abi.ABI.decodeAddress(&log.topics[1].bytes, 0);

    // data = (string name) — single dynamic head pointer at offset 0.
    // `name` ownership is later transferred to `emitEvent`, which frees it via
    // `insertEventAndNotify`. Do NOT add a defer-free here.
    const name = try abi.ABI.decodeString(self.allocator, log.data, 0);

    var addr_buf: [42]u8 = undefined;
    const addr_hex = addr.toHexBuf(&addr_buf);

    std.log.debug("V2 NameForAddrChanged: addr={s} name={s}", .{ addr_hex, name });

    // Persist a "current name" hint keyed by address. We store the name's
    // namehash so the existing schema (address → namehash) keeps working;
    // forward-resolution still needs to be verified via the resolver per ENSIP-3.
    const namehash = if (name.len > 0)
        hash_mod.namehash(self.allocator, name) catch Hash.zero
    else
        Hash.zero;

    const block_timestamp = self.getBlockTimestamp(protocol, log.block_number, log.block_timestamp);
    self.database.upsertReverseRecord(
        protocol,
        addr,
        namehash,
        log.block_number,
        log.transaction_hash,
        log.log_index,
        block_timestamp,
    ) catch |err| {
        std.log.warn("Failed to upsert V2 reverse record for {s}: {}", .{ addr_hex, err });
    };

    // Store event (JSON payload mirrors the on-chain event shape)
    var nh_buf: [66]u8 = undefined;
    const nh_hex = namehash.toHexBuf(&nh_buf);
    const event_data = try std.fmt.allocPrint(
        self.allocator,
        "{{\"address\":\"{s}\",\"name\":\"{s}\",\"namehash\":\"{s}\"}}",
        .{ addr_hex, name, nh_hex },
    );

    try utils.emitEvent(self, protocol, log, .name_changed, name, namehash, event_data);
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
                try names_storage.updateNameLabel(self.database, .v1, wrapped_node, labels[0], name_str, ens_normalize.nameIsNormalized(self.allocator, name_str));
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
                try names_storage.updateNameLabel(self.database, .v1, node_hash, label, level_name, ens_normalize.nameIsNormalized(self.allocator, level_name));
                std.log.info("Healed parent name from NameWrapped DNS: {s} (label={s})", .{ level_name, label });
            }
        }

        // Also delete from unknown_labels if resolved
        deleteUnknownLabelByNamehash(self.database, &current_namehash) catch {};
    }
}

/// Delete unknown_labels entry by namehash (after healing from DNS name). Best-effort.
fn deleteUnknownLabelByNamehash(database: *db.Database, namehash_bytes: *const [32]u8) !void {
    const namehash = Hash{ .bytes = namehash_bytes.* };
    const reorg_undo = @import("../../storage/reorg_undo.zig");
    // Best-effort like the rest of this fn — but if capture fails, SKIP the
    // delete: an uncaptured delete breaks rollback ≡ clean-sync in the
    // write-path lane (triggers are atomic with the statement; mirror that).
    reorg_undo.captureActiveWhere(database, "unknown_labels", "D", "namehash = ?", .{namehash}) catch return;
    var q = db.Query.init(database, "DELETE FROM unknown_labels WHERE namehash = ?") catch return;
    defer q.deinit();
    q.bindHash(namehash) catch return;
    q.exec() catch return;
}

/// Apply a NameWrapper ERC1155 ownership change for a single token id.
/// `id` is the namehash of the wrapped name (V1 NameWrapper packs namehash → uint256).
/// If the name is known, update its owner; otherwise log debug and continue.
fn applyNameWrapperOwnerChange(self: *Indexer, id: u256, to: Address) !void {
    // Convert id → 32-byte big-endian namehash.
    var buf: [32]u8 = undefined;
    std.mem.writeInt(u256, &buf, id, .big);
    const namehash = Hash{ .bytes = buf };

    const maybe_name = names_storage.getNameByNamehash(self.database, namehash) catch null;
    if (maybe_name) |name| {
        var name_copy = name;
        defer name_copy.deinit(self.allocator);

        if (self.write_buffer.active) {
            try self.write_buffer.updateNameOwner(namehash, to);
        } else {
            try names_storage.updateNameOwner(self.database, namehash, to);
        }

        var nh_buf: [66]u8 = undefined;
        const nh_hex = namehash.toHexBuf(&nh_buf);
        var to_buf: [42]u8 = undefined;
        const to_hex = to.toHexBuf(&to_buf);
        std.log.debug("V1 NameWrapper transfer: namehash={s} → owner={s}", .{ nh_hex, to_hex });
    } else {
        // Either the NameWrapped event for this id hasn't been processed yet
        // (will be caught by ordering / resync) or it's a non-ENS ERC1155
        // token slipping through the topic-only filter.
        var nh_buf: [66]u8 = undefined;
        const nh_hex = (Hash{ .bytes = buf }).toHexBuf(&nh_buf);
        std.log.debug("V1 NameWrapper transfer for unknown namehash={s}, event stored but owner not updated", .{nh_hex});
    }
}

/// Handle V1 NameWrapper ERC1155 TransferSingle event.
/// TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value)
/// In NameWrapper, `id` is the namehash of the wrapped name encoded as uint256.
pub fn handleV1NameWrapperTransferSingle(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    if (log.topics.len < 4) {
        std.log.warn("V1 NameWrapper TransferSingle has unexpected topic count: {d}, skipping", .{log.topics.len});
        return;
    }

    const operator = try abi.ABI.decodeAddress(&log.topics[1].bytes, 0);
    const from = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);
    const to = try abi.ABI.decodeAddress(&log.topics[3].bytes, 0);

    // Non-indexed payload: (uint256 id, uint256 value)
    const data_values = try abi.decodeValues(log.data, &.{ .uint256, .uint256 }, self.allocator);
    defer abi.freeValues(data_values, self.allocator);
    const id = data_values[0].uint256;
    const value = data_values[1].uint256;

    // Defensive: self-transfers don't change ownership.
    if (from.eql(to)) return;

    // Burn (to == 0): the canonical unwrap event (NameUnwrapped) handles owner
    // semantics separately. Since WrappedDomain is collapsed onto the Name row,
    // we simply update the owner field here and skip if it's a burn.
    if (!to.isZero()) {
        try applyNameWrapperOwnerChange(self, id, to);
        utils.recordAccountObservation(self, protocol, to, log);
    }

    // Emit event
    var operator_buf: [42]u8 = undefined;
    const operator_hex = operator.toHexBuf(&operator_buf);
    var from_buf: [42]u8 = undefined;
    const from_hex = from.toHexBuf(&from_buf);
    var to_buf: [42]u8 = undefined;
    const to_hex = to.toHexBuf(&to_buf);

    var nh_buf: [32]u8 = undefined;
    std.mem.writeInt(u256, &nh_buf, id, .big);
    const namehash = Hash{ .bytes = nh_buf };
    var nh_hex_buf: [66]u8 = undefined;
    const nh_hex = namehash.toHexBuf(&nh_hex_buf);

    const event_data = try std.fmt.allocPrint(
        self.allocator,
        "{{\"operator\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"id\":\"{s}\",\"value\":{d}}}",
        .{ operator_hex, from_hex, to_hex, nh_hex, value },
    );

    try utils.emitEvent(self, protocol, log, .transfer, null, namehash, event_data);
}

/// Handle V1 NameWrapper ERC1155 TransferBatch event.
/// TransferBatch(address indexed operator, address indexed from, address indexed to, uint256[] ids, uint256[] values)
/// In NameWrapper, each `id` is the namehash of a wrapped name encoded as uint256.
pub fn handleV1NameWrapperTransferBatch(self: *Indexer, protocol: models.Protocol, log: rpc.Log) !void {
    if (log.topics.len < 4) {
        std.log.warn("V1 NameWrapper TransferBatch has unexpected topic count: {d}, skipping", .{log.topics.len});
        return;
    }

    const operator = try abi.ABI.decodeAddress(&log.topics[1].bytes, 0);
    const from = try abi.ABI.decodeAddress(&log.topics[2].bytes, 0);
    const to = try abi.ABI.decodeAddress(&log.topics[3].bytes, 0);

    // Non-indexed payload: (uint256[] ids, uint256[] values).
    // eth.zig's decodeValues takes a flat []AbiType and has no in-band way to
    // express the element type of a dynamic array, so use the primitive
    // decodeUint256Array shim (same approach as V2 handleTransferBatch).
    const ids = try abi.ABI.decodeUint256Array(self.allocator, log.data, 0);
    defer self.allocator.free(ids);

    const values = try abi.ABI.decodeUint256Array(self.allocator, log.data, 32);
    defer self.allocator.free(values);

    // Defensive: empty batch is well-formed but uninteresting.
    if (ids.len == 0) {
        std.log.debug("V1 NameWrapper TransferBatch with empty ids array, skipping", .{});
        return;
    }

    const self_transfer = from.eql(to);

    if (!self_transfer and !to.isZero()) {
        for (ids) |id| {
            applyNameWrapperOwnerChange(self, id, to) catch |err| {
                std.log.warn("V1 NameWrapper TransferBatch: failed to update owner for id: {any}", .{err});
            };
        }
        utils.recordAccountObservation(self, protocol, to, log);
    }

    // Emit event
    var operator_buf: [42]u8 = undefined;
    const operator_hex = operator.toHexBuf(&operator_buf);
    var from_buf: [42]u8 = undefined;
    const from_hex = from.toHexBuf(&from_buf);
    var to_buf: [42]u8 = undefined;
    const to_hex = to.toHexBuf(&to_buf);

    const event_data = try std.fmt.allocPrint(
        self.allocator,
        "{{\"operator\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"count\":{d}}}",
        .{ operator_hex, from_hex, to_hex, ids.len },
    );

    try utils.emitEvent(self, protocol, log, .transfer, null, null, event_data);
}
