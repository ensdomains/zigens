/// Resource-naming discovery storage (PermissionedResolver Named*Resource
/// events): one row per (protocol, resolver, resource) mapping an EAC resource
/// id to the name — and, for record-scoped resources, the text/data key or
/// addr coin type — it guards. `record_key`/`coin_type` use '' / -1 sentinels
/// (not NULL) so the UNIQUE key stays conflict-updatable.
const std = @import("std");
const db_module = @import("database.zig");
const reorg_undo = @import("reorg_undo.zig");
const Database = db_module.Database;
const Query = db_module.Query;
const models = @import("../types/models.zig");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;

pub fn upsertNamedResource(
    db: *Database,
    protocol: models.Protocol,
    resolver: Address,
    resource_hex: []const u8,
    record_kind: []const u8,
    record_key: []const u8,
    coin_type: i64,
    name: []const u8,
    block_number: u64,
    tx_hash: Hash,
    log_index: u32,
) !void {
    try reorg_undo.captureUpsert(db, "resolver_named_resources", .{ protocol, resolver, resource_hex });
    const sql = try db.upsertSql(db.allocator, "resolver_named_resources", &.{
        "protocol", "resolver",     "resource",         "record_kind", "record_key", "coin_type",
        "name",     "block_number", "transaction_hash", "log_index",   "timestamp",
    }, .replace);
    defer db.allocator.free(sql);
    var q = try Query.initCached(db, sql);
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(resolver);
    try q.bindText(resource_hex);
    try q.bindTextStatic(record_kind);
    try q.bindText(record_key);
    try q.bindInt64(coin_type);
    try q.bindText(name);
    try q.bindInt64(@intCast(block_number));
    try q.bindHash(tx_hash);
    try q.bindInt(@intCast(log_index));
    try q.bindInt64(std.time.timestamp());
    try q.exec();
}

pub const NamedResource = struct {
    resource: []u8,
    record_kind: []u8,
    record_key: []u8,
    coin_type: i64,
    name: []u8,
    block_number: u64,

    pub fn deinit(self: *NamedResource, allocator: std.mem.Allocator) void {
        allocator.free(self.resource);
        allocator.free(self.record_kind);
        allocator.free(self.record_key);
        allocator.free(self.name);
    }
};

/// All resource-name associations announced by `resolver`. Caller frees each
/// entry (`deinit`) and the slice.
pub fn getNamedResources(db: *Database, allocator: std.mem.Allocator, protocol: models.Protocol, resolver: Address) ![]NamedResource {
    var q = try Query.initCached(db,
        \\SELECT resource, record_kind, record_key, coin_type, name, block_number
        \\FROM resolver_named_resources
        \\WHERE protocol = ? AND resolver = ?
        \\ORDER BY block_number ASC, resource ASC
    );
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(resolver);

    var out: std.ArrayList(NamedResource) = .{};
    errdefer {
        for (out.items) |*r| r.deinit(allocator);
        out.deinit(allocator);
    }
    while (try q.step()) {
        const resource = try allocator.dupe(u8, q.getTextSlice(0) orelse "");
        errdefer allocator.free(resource);
        const kind = try allocator.dupe(u8, q.getTextSlice(1) orelse "");
        errdefer allocator.free(kind);
        const key = try allocator.dupe(u8, q.getTextSlice(2) orelse "");
        errdefer allocator.free(key);
        const name = try allocator.dupe(u8, q.getTextSlice(4) orelse "");
        errdefer allocator.free(name);
        try out.append(allocator, .{
            .resource = resource,
            .record_kind = kind,
            .record_key = key,
            .coin_type = q.getInt64(3),
            .name = name,
            .block_number = @intCast(q.getInt64(5)),
        });
    }
    return out.toOwnedSlice(allocator);
}
