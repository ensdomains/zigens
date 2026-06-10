const std = @import("std");
const db_module = @import("database.zig");
const reorg_undo = @import("reorg_undo.zig");
const Database = db_module.Database;
const Query = db_module.Query;
const models = @import("../types/models.zig");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;

// ============================================================================
// ENSIP-16: RESOLVER METADATA OPERATIONS (3 functions)
// ============================================================================

/// Upsert resolver metadata (GraphQL endpoint for offchain data).
///
/// NO WRITER EXISTS YET — and that is a verified fact, not an oversight
/// (2026-06-06): neither the deployed Sepolia V2 resolvers (full topic sweep
/// over every known resolver since deployment) nor the contracts-v2 resolver
/// sources define any on-chain metadata/graphql-url event; ENSIP-16 specifies
/// an offchain discovery convention. This write path + the read surface
/// (GraphQL `metadata` query) are kept for the day an on-chain signal ships.
/// Its sibling `upsertResolverApproval` IS wired (the PublicResolver
/// `Approved` event via handleApproved).
pub fn upsertResolverMetadata(db: *Database, protocol: models.Protocol, resolver: Address, graphql_url: []const u8, block_number: u64, tx_hash: Hash) !void {
    try reorg_undo.captureUpsert(db, "resolver_metadata", .{ protocol, resolver });
    var q = try Query.init(db,
        \\INSERT INTO resolver_metadata
        \\(protocol, resolver, graphql_url, block_number, transaction_hash, timestamp)
        \\VALUES (?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(protocol, resolver) DO UPDATE SET
        \\  graphql_url = excluded.graphql_url,
        \\  block_number = excluded.block_number,
        \\  transaction_hash = excluded.transaction_hash,
        \\  timestamp = excluded.timestamp
    );
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(resolver);
    try q.bindText(graphql_url);
    try q.bindInt64(@intCast(block_number));
    try q.bindHash(tx_hash);
    try q.bindInt64(std.time.timestamp());
    try q.exec();
}

/// Get resolver metadata for a specific resolver
pub fn getResolverMetadata(db: *Database, protocol: models.Protocol, resolver: Address) !?models.ResolverMetadata {
    var q = try Query.init(db,
        \\SELECT id, protocol, resolver, graphql_url, block_number, transaction_hash, timestamp
        \\FROM resolver_metadata
        \\WHERE protocol = ? AND resolver = ?
    );
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(resolver);

    if (try q.step()) {
        const graphql_url = try db.allocator.dupe(u8, q.getTextSlice(3) orelse "");
        errdefer db.allocator.free(graphql_url);
        return models.ResolverMetadata{
            .id = @intCast(q.getInt64(0)),
            .protocol = try models.Protocol.fromString(q.getTextSlice(1) orelse ""),
            .resolver = try Address.fromHex(q.getTextSlice(2) orelse ""),
            .graphql_url = graphql_url,
            .block_number = @intCast(q.getInt64(4)),
            .tx_hash = try Hash.fromHex(q.getTextSlice(5) orelse ""),
            .timestamp = q.getInt64(6),
        };
    }

    return null;
}

/// Get all resolvers with offchain metadata
pub fn getAllResolverMetadata(db: *Database, protocol: models.Protocol) ![]models.ResolverMetadata {
    var q = try Query.init(db,
        \\SELECT id, protocol, resolver, graphql_url, block_number, transaction_hash, timestamp
        \\FROM resolver_metadata
        \\WHERE protocol = ?
        \\ORDER BY timestamp DESC
    );
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());

    var result: std.ArrayList(models.ResolverMetadata) = .{};
    errdefer {
        for (result.items) |*metadata| metadata.deinit(db.allocator);
        result.deinit(db.allocator);
    }

    while (try q.step()) {
        const graphql_url = try db.allocator.dupe(u8, q.getTextSlice(3) orelse "");
        errdefer db.allocator.free(graphql_url);
        try result.append(db.allocator, models.ResolverMetadata{
            .id = @intCast(q.getInt64(0)),
            .protocol = try models.Protocol.fromString(q.getTextSlice(1) orelse ""),
            .resolver = try Address.fromHex(q.getTextSlice(2) orelse ""),
            .graphql_url = graphql_url,
            .block_number = @intCast(q.getInt64(4)),
            .tx_hash = try Hash.fromHex(q.getTextSlice(5) orelse ""),
            .timestamp = q.getInt64(6),
        });
    }

    return result.toOwnedSlice(db.allocator);
}

// ============================================================================
// ENSIP-16: RESOLVER APPROVAL OPERATIONS (4 functions)
// ============================================================================

/// Insert or update resolver approval/delegation
pub fn upsertResolverApproval(db: *Database, protocol: models.Protocol, resolver: Address, namehash: Hash, context: ?[]const u8, delegate: Address, approved: bool, block_number: u64, tx_hash: Hash, log_index: u32) !void {
    try reorg_undo.captureUpsert(db, "resolver_approvals", .{ protocol, resolver, namehash, context, delegate });
    var q = try Query.init(db,
        \\INSERT INTO resolver_approvals
        \\(protocol, resolver, namehash, context, delegate, approved, block_number, transaction_hash, log_index, timestamp)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(protocol, resolver, namehash, context, delegate) DO UPDATE SET
        \\  approved = excluded.approved,
        \\  block_number = excluded.block_number,
        \\  transaction_hash = excluded.transaction_hash,
        \\  log_index = excluded.log_index,
        \\  timestamp = excluded.timestamp
    );
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(resolver);
    try q.bindHash(namehash);
    try q.bindOptionalText(context);
    try q.bindAddress(delegate);
    try q.bindInt(if (approved) 1 else 0);
    try q.bindInt64(@intCast(block_number));
    try q.bindHash(tx_hash);
    try q.bindInt(@intCast(log_index));
    try q.bindInt64(std.time.timestamp());
    try q.exec();
}

/// Check if a delegate is approved for a name (with optional context)
pub fn isApprovedFor(db: *Database, protocol: models.Protocol, resolver: Address, namehash: Hash, context: ?[]const u8, delegate: Address) !bool {
    var q = try Query.init(db,
        \\SELECT approved
        \\FROM resolver_approvals
        \\WHERE protocol = ? AND resolver = ? AND namehash = ?
        \\  AND ((CAST(? AS TEXT) IS NULL AND context IS NULL) OR context = ?) AND delegate = ?
    );
    defer q.deinit();

    // `context IS ?` is SQLite-only (PG allows only the literal IS NULL), so
    // portable NULL-or-equal needs the context bound twice.
    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(resolver);
    try q.bindHash(namehash);
    try q.bindOptionalText(context);
    try q.bindOptionalText(context);
    try q.bindAddress(delegate);

    if (try q.step()) {
        return q.getBool(0);
    }

    return false; // Not found = not approved
}

/// Get all approvals for a specific name (with optional context filter)
pub fn getApprovalsForName(db: *Database, protocol: models.Protocol, namehash: Hash, context: ?[]const u8) ![]models.ResolverApproval {
    var q = try Query.init(db,
        \\SELECT id, protocol, resolver, namehash, context, delegate, approved, block_number, transaction_hash, log_index, timestamp
        \\FROM resolver_approvals
        \\WHERE protocol = ? AND namehash = ? AND (CAST(? AS TEXT) IS NULL OR context = ?)
        \\ORDER BY timestamp DESC
    );
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());
    try q.bindHash(namehash);
    try q.bindOptionalText(context);
    try q.bindOptionalText(context);

    return collectApprovals(db, &q);
}

/// Get all approvals for a specific delegate
pub fn getApprovalsForDelegate(db: *Database, protocol: models.Protocol, delegate: Address) ![]models.ResolverApproval {
    var q = try Query.init(db,
        \\SELECT id, protocol, resolver, namehash, context, delegate, approved, block_number, transaction_hash, log_index, timestamp
        \\FROM resolver_approvals
        \\WHERE protocol = ? AND delegate = ? AND approved = 1
        \\ORDER BY timestamp DESC
    );
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(delegate);

    return collectApprovals(db, &q);
}

/// Read every remaining row of an approvals query into an owned slice (shared by
/// getApprovalsForName/getApprovalsForDelegate — identical 11-column projection).
fn collectApprovals(db: *Database, q: *Query) ![]models.ResolverApproval {
    var result: std.ArrayList(models.ResolverApproval) = .{};
    errdefer {
        for (result.items) |*approval| approval.deinit(db.allocator);
        result.deinit(db.allocator);
    }

    while (try q.step()) {
        const context: ?[]const u8 = if (q.getTextSlice(4)) |ctx| try db.allocator.dupe(u8, ctx) else null;
        errdefer if (context) |ctx| db.allocator.free(ctx);
        try result.append(db.allocator, models.ResolverApproval{
            .id = @intCast(q.getInt64(0)),
            .protocol = try models.Protocol.fromString(q.getTextSlice(1) orelse ""),
            .resolver = try Address.fromHex(q.getTextSlice(2) orelse ""),
            .namehash = try Hash.fromHex(q.getTextSlice(3) orelse ""),
            .context = context,
            .delegate = try Address.fromHex(q.getTextSlice(5) orelse ""),
            .approved = q.getBool(6),
            .block_number = @intCast(q.getInt64(7)),
            .tx_hash = try Hash.fromHex(q.getTextSlice(8) orelse ""),
            .log_index = @intCast(q.getInt(9)),
            .timestamp = q.getInt64(10),
        });
    }

    return result.toOwnedSlice(db.allocator);
}
