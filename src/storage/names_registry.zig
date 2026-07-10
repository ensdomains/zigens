//! Registry-row operations for the names storage layer.
//!
//! Split out of names.zig as a cohesive, self-contained cluster: these functions
//! manage `registries` rows (and the placeholder-name patch that spans registries,
//! names, and events). They depend only on the shared storage primitives, not on
//! any names.zig-private helper, so they move verbatim. names.zig re-exports them
//! so every existing `names.<fn>` / `db.<fn>` call site is unchanged.

const std = @import("std");
const db_module = @import("database.zig");
const reorg_undo = @import("reorg_undo.zig");
const Database = db_module.Database;
const Query = db_module.Query;
const models = @import("../types/models.zig");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;

pub fn insertRegistry(db: *Database, registry: models.Registry) !void {
    // Use INSERT OR IGNORE to keep the FIRST SubregistryUpdate (when subregistry was established)
    // not later ones. This ensures created_block reflects when the parent->subregistry mapping
    // was first created, which is needed for correct temporal parent lookups.
    const sql = try db.upsertSql(db.allocator, "registries", &.{ "address", "protocol", "name", "namehash", "parent_registry", "created_block", "created_at" }, .ignore);
    defer db.allocator.free(sql);

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindAddress(registry.address);
    try q.bindTextStatic(registry.protocol.toString());
    try q.bindText(registry.name);
    try q.bindHash(registry.namehash);
    try q.bindAddress(registry.parent_registry);
    try q.bindInt64(@intCast(registry.created_block));
    try q.bindInt64(registry.created_at);
    try q.exec();
}

/// Update a registry that was created with a canonicalId placeholder name to use the actual name.
/// Also updates names that used this placeholder as parent_name, and events stored with the
/// placeholder in their name/namehash columns (see updatePlaceholderEventsByName for event payload
/// handling — we only patch the indexed columns, not the raw JSON data blob).
pub fn updateRegistryPlaceholderName(db: *Database, placeholder_name: []const u8, actual_name: []const u8, namehash: Hash) !u32 {
    try reorg_undo.captureWhere(db, "registries", "U", "name = ?", .{placeholder_name});
    var reg_q = try Query.init(db, "UPDATE registries SET name = ?, namehash = ? WHERE name = ?");
    defer reg_q.deinit();
    try reg_q.bindText(actual_name);
    try reg_q.bindHash(namehash);
    try reg_q.bindText(placeholder_name);
    try reg_q.exec();
    const registry_changes = reg_q.changes();

    try reorg_undo.captureWhere(db, "names", "U", "parent_name = ?", .{placeholder_name});
    var names_q = try Query.init(db,
        \\UPDATE names
        \\SET parent_name = ?,
        \\    parent_namehash = ?,
        \\    name = label || '.' || ?
        \\WHERE parent_name = ?
    );
    defer names_q.deinit();
    try names_q.bindText(actual_name);
    try names_q.bindHash(namehash);
    try names_q.bindText(actual_name);
    try names_q.bindText(placeholder_name);
    try names_q.exec();
    const names_changes = names_q.changes();

    const event_changes = try updatePlaceholderEventsByName(db, placeholder_name, actual_name, namehash);

    if (registry_changes > 0 or names_changes > 0 or event_changes > 0) {
        // Debug-level: this fires once per migrated/registered name during a sync,
        // generating thousands of identical info lines on a fresh Sepolia reindex.
        std.log.debug("Updated placeholder '{s}' -> '{s}': {d} registries, {d} names, {d} events", .{
            placeholder_name, actual_name, registry_changes, names_changes, event_changes,
        });
    }

    return registry_changes + names_changes + event_changes;
}

/// Patch events stored with a placeholder name (either "canonicalId:N" from SubregistryUpdated or
/// "tokenId:N" from ResolverUpdated) once the name is known. Updates the top-level name/namehash
/// columns only; the raw JSON data blob is left intact as a historical record of what the handler
/// decoded at event-process time.
pub fn updatePlaceholderEventsByName(db: *Database, placeholder_name: []const u8, actual_name: []const u8, namehash: Hash) !u32 {
    var q = try Query.init(db, "UPDATE events SET name = ?, namehash = ? WHERE name = ?");
    defer q.deinit();
    try q.bindText(actual_name);
    try q.bindHash(namehash);
    try q.bindText(placeholder_name);
    try q.exec();
    return q.changes();
}

pub fn getRegistriesByOwner(db: *Database, protocol: models.Protocol, owner: Address) ![]models.Registry {
    // Join registries with names on namehash to find registries where the NAME is owned by the specified owner
    // This returns registries for names that the owner controls (not registries that the owner's names use as subregistries)
    // Only returns the LATEST (most recent) registry per name to avoid duplicates when subregistry is updated
    var q = try Query.init(db,
        \\SELECT r.address, r.protocol, r.name, r.namehash, r.parent_registry, r.created_block, r.created_at
        \\FROM registries r
        \\JOIN names n ON r.namehash = n.namehash AND r.protocol = n.protocol
        \\WHERE r.protocol = ? AND n.owner = ?
        \\AND r.created_block = (
        \\    SELECT MAX(r2.created_block)
        \\    FROM registries r2
        \\    WHERE r2.namehash = r.namehash AND r2.protocol = r.protocol
        \\)
    );
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(owner);

    var registries: std.ArrayList(models.Registry) = .empty;
    errdefer {
        for (registries.items) |*reg| {
            db.allocator.free(reg.name);
        }
        registries.deinit(db.allocator);
    }

    while (try q.step()) {
        const address_str = q.getTextSlice(0) orelse continue;
        const protocol_str = q.getTextSlice(1) orelse continue;
        const name_str = q.getTextSlice(2) orelse "";
        const namehash_str = q.getTextSlice(3) orelse continue;
        const parent_str = q.getTextSlice(4) orelse continue;

        try registries.append(db.allocator, .{
            .address = try Address.fromHex(address_str),
            .protocol = try models.Protocol.fromString(protocol_str),
            .name = try db.allocator.dupe(u8, name_str),
            .namehash = try Hash.fromHex(namehash_str),
            .parent_registry = try Address.fromHex(parent_str),
            .created_block = @intCast(q.getInt64(5)),
            .created_at = q.getInt64(6),
        });
    }

    return registries.toOwnedSlice(db.allocator);
}

/// Look up a single registry contract by its address. Returns the most-recently
/// created row when the same contract is referenced from multiple `created_block`
/// entries (which can happen on V2 since `INSERT OR IGNORE` keeps the first
/// SubregistryUpdate per registry but the table is keyed by
/// `UNIQUE(protocol, address, namehash)`).
pub fn getRegistry(db: *Database, protocol: models.Protocol, address: Address) !?models.Registry {
    var q = try Query.init(db,
        \\SELECT r.address, r.protocol, r.name, r.namehash, r.parent_registry, r.created_block, r.created_at
        \\FROM registries r
        \\WHERE r.protocol = ? AND r.address = ?
        \\ORDER BY r.created_block DESC
        \\LIMIT 1
    );
    defer q.deinit();

    try q.bindTextStatic(protocol.toString());
    try q.bindAddress(address);

    if (!try q.step()) return null;

    const address_str = q.getTextSlice(0) orelse return null;
    const protocol_str = q.getTextSlice(1) orelse return null;
    const name_str = q.getTextSlice(2) orelse "";
    const namehash_str = q.getTextSlice(3) orelse return null;
    const parent_str = q.getTextSlice(4) orelse return null;

    return .{
        .address = try Address.fromHex(address_str),
        .protocol = try models.Protocol.fromString(protocol_str),
        .name = try db.allocator.dupe(u8, name_str),
        .namehash = try Hash.fromHex(namehash_str),
        .parent_registry = try Address.fromHex(parent_str),
        .created_block = @intCast(q.getInt64(5)),
        .created_at = q.getInt64(6),
    };
}
