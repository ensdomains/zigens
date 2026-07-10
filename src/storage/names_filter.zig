//! Name filter engine + filtered/ordered/counted list queries.
//!
//! Split out of names.zig: the filter/sort/pagination types (OrderDir, NameSortField,
//! NameFilters), the private SQL builders, and the list/count queries. names.zig
//! re-exports the public symbols so every `names.X` / `db.X` caller is unchanged.

const std = @import("std");
const db_module = @import("database.zig");
const Database = db_module.Database;
const Query = db_module.Query;
const models = @import("../types/models.zig");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;
const names_common = @import("names_common.zig");
const parseU256Hex = names_common.parseU256Hex;

/// Order direction for queries
pub const OrderDir = enum {
    asc,
    desc,
};

/// Sort field for name queries
pub const NameSortField = enum {
    created_at,
    name,
    expiry,
    /// Grace-inclusive expiry (Domain.expiryDate ordering). Backed by the STORED
    /// generated `expiry_effective` column (schema.sql) so it stays index-backed
    /// (idx_names_expiry_effective) and matches the expiry_date_* filters and
    /// ens_fields.effectiveDomainExpiry by construction — one SQL source of truth.
    expiry_effective,
    registered_at,

    pub fn toSql(self: NameSortField) []const u8 {
        return self.toSqlQualified("");
    }

    pub fn toSqlQualified(self: NameSortField, comptime alias: []const u8) []const u8 {
        return switch (self) {
            .created_at => alias ++ "created_at",
            .name => alias ++ "name",
            .expiry => alias ++ "expiry",
            .expiry_effective => alias ++ "expiry_effective",
            .registered_at => alias ++ "registered_at",
        };
    }
};

/// Append SQL WHERE conditions corresponding to a `NameFilters` value into `conditions`.
/// Strings allocated for dynamic IN clauses are tracked in `allocated_strings` so the
/// caller can free them after use. The condition list is kept in lockstep with `bindNameFilters`
/// so binds happen in the same order they're appended here.
fn appendNameFilterConditions(
    db: *Database,
    filters: NameFilters,
    conditions: *std.ArrayList([]const u8),
    allocated_strings: *std.ArrayList([]const u8),
) !void {
    if (!filters.include_unreachable) {
        try conditions.append(db.allocator, "is_reachable = 1");
        // Hide the synthetic root domain (namehash 0x000…000, name="") from
        // default GraphQL queries. The row is materialized by `Database.migrate`
        // so internal graph traversal terminates cleanly at the root, but it's
        // noise for client-facing listings (`createdAt = 0`, blank `name`).
        // Audit/debug callers that pass `includeUnreachable: true` also opt
        // back into seeing it.
        try conditions.append(db.allocator, "namehash != '0x0000000000000000000000000000000000000000000000000000000000000000'");
        // PROTOCOL DEDUP: a node indexed under BOTH protocols (e.g. a migrated name) is
        // ONE domain to clients — serve the v2 row and suppress its v1 twin (v2 wins,
        // the same preference Account.primaryName applies). v1-only names are
        // unaffected. Scoped to this !include_unreachable block so audit callers that
        // opt into the raw view (includeUnreachable: true) still see both rows.
        try conditions.append(db.allocator, "NOT (names.protocol = 'v1' AND EXISTS (SELECT 1 FROM names v2twin WHERE v2twin.namehash = names.namehash AND v2twin.protocol = 'v2'))");
    }
    // ENSIP-15 enforcement (mirrors is_reachable): an explicit `isNormalized` filter
    // wins; otherwise non-normalized names are hidden unless `includeUnnormalized` is set.
    if (filters.is_normalized) |want| {
        try conditions.append(db.allocator, if (want) "is_normalized = 1" else "is_normalized = 0");
    } else if (!filters.include_unnormalized) {
        try conditions.append(db.allocator, "is_normalized = 1");
    }
    // User predicate tree (this node's scalars + recursive and/or). Default
    // visibility above applies to the whole result set and is NOT injected into
    // nested and/or nodes.
    if (try buildNameNodeExpr(db, filters, allocated_strings)) |expr| {
        try conditions.append(db.allocator, expr);
    }
}

/// One filter node's scalar predicates (no default visibility, no and/or).
fn appendNameScalarConditions(
    db: *Database,
    filters: NameFilters,
    conditions: *std.ArrayList([]const u8),
    allocated_strings: *std.ArrayList([]const u8),
) !void {
    if (filters.owner != null) {
        try conditions.append(db.allocator, "owner = ?");
    }
    if (filters.owner_not != null) {
        try conditions.append(db.allocator, "owner != ?");
    }
    if (filters.owner_in) |owners| {
        if (owners.len > 0) {
            const clause = try db_module.query.buildInClause(db.allocator, "owner", "IN", owners.len);
            try allocated_strings.append(db.allocator, clause);
            try conditions.append(db.allocator, clause);
        }
    }
    if (filters.owner_not_in) |owners| {
        if (owners.len > 0) {
            const clause = try db_module.query.buildInClause(db.allocator, "owner", "NOT IN", owners.len);
            try allocated_strings.append(db.allocator, clause);
            try conditions.append(db.allocator, clause);
        }
    }
    if (filters.name != null) try conditions.append(db.allocator, "name = ?");
    if (filters.name_not != null) try conditions.append(db.allocator, "name != ?");
    if (filters.name_in) |names| {
        if (names.len == 0) {
            try conditions.append(db.allocator, "1=0");
        } else {
            const clause = try db_module.query.buildInClause(db.allocator, "name", "IN", names.len);
            try allocated_strings.append(db.allocator, clause);
            try conditions.append(db.allocator, clause);
        }
    }
    if (filters.name_not_in) |names| {
        if (names.len > 0) {
            const clause = try db_module.query.buildInClause(db.allocator, "name", "NOT IN", names.len);
            try allocated_strings.append(db.allocator, clause);
            try conditions.append(db.allocator, clause);
        }
    }
    if (filters.name_contains != null) try conditions.append(db.allocator, "name LIKE '%' || ? || '%'");
    if (filters.name_contains_nocase != null) try conditions.append(db.allocator, "LOWER(name) LIKE '%' || LOWER(?) || '%'");
    if (filters.name_not_contains != null) try conditions.append(db.allocator, "name NOT LIKE '%' || ? || '%'");
    if (filters.name_starts_with != null) try conditions.append(db.allocator, "name LIKE ? || '%'");
    if (filters.name_starts_with_nocase != null) try conditions.append(db.allocator, "LOWER(name) LIKE LOWER(?) || '%'");
    if (filters.name_ends_with != null) try conditions.append(db.allocator, "name LIKE '%' || ?");
    if (filters.name_ends_with_nocase != null) try conditions.append(db.allocator, "LOWER(name) LIKE '%' || LOWER(?)");
    if (filters.label_name != null) try conditions.append(db.allocator, "label = ?");
    if (filters.label_name_not != null) try conditions.append(db.allocator, "label != ?");
    if (filters.label_name_in) |labels| {
        if (labels.len == 0) {
            try conditions.append(db.allocator, "1=0");
        } else {
            const clause = try db_module.query.buildInClause(db.allocator, "label", "IN", labels.len);
            try allocated_strings.append(db.allocator, clause);
            try conditions.append(db.allocator, clause);
        }
    }
    if (filters.label_name_not_in) |labels| {
        if (labels.len > 0) {
            const clause = try db_module.query.buildInClause(db.allocator, "label", "NOT IN", labels.len);
            try allocated_strings.append(db.allocator, clause);
            try conditions.append(db.allocator, clause);
        }
    }
    if (filters.label_name_contains != null) try conditions.append(db.allocator, "label LIKE '%' || ? || '%'");
    if (filters.label_name_contains_nocase != null) try conditions.append(db.allocator, "LOWER(label) LIKE '%' || LOWER(?) || '%'");
    if (filters.label_name_not_contains != null) try conditions.append(db.allocator, "label NOT LIKE '%' || ? || '%'");
    if (filters.label_name_starts_with != null) try conditions.append(db.allocator, "label LIKE ? || '%'");
    if (filters.label_name_starts_with_nocase != null) try conditions.append(db.allocator, "LOWER(label) LIKE LOWER(?) || '%'");
    if (filters.label_name_ends_with != null) try conditions.append(db.allocator, "label LIKE '%' || ?");
    if (filters.label_name_ends_with_nocase != null) try conditions.append(db.allocator, "LOWER(label) LIKE '%' || LOWER(?)");
    if (filters.expiry_gt != null) try conditions.append(db.allocator, "expiry > ?");
    if (filters.expiry_gte != null) try conditions.append(db.allocator, "expiry >= ?");
    if (filters.expiry_lt != null) try conditions.append(db.allocator, "expiry < ?");
    if (filters.expiry_lte != null) try conditions.append(db.allocator, "expiry <= ?");
    // Grace-aware variants backing the subgraph `expiryDate_*` filters. Compared
    // against the STORED generated `expiry_effective` column (schema.sql) — the
    // single source of the grace rule — so these stay sargable on
    // idx_names_expiry_effective instead of full-scanning an inline CASE.
    if (filters.expiry_date_gt != null) try conditions.append(db.allocator, "expiry_effective > ?");
    if (filters.expiry_date_gte != null) try conditions.append(db.allocator, "expiry_effective >= ?");
    if (filters.expiry_date_lt != null) try conditions.append(db.allocator, "expiry_effective < ?");
    if (filters.expiry_date_lte != null) try conditions.append(db.allocator, "expiry_effective <= ?");
    if (filters.resolved_address != null) {
        try conditions.append(db.allocator, "namehash IN (SELECT namehash FROM resolver_addresses WHERE address = ?)");
    }
    if (filters.resolver != null) try conditions.append(db.allocator, "resolver = ?");
    if (filters.registry != null) try conditions.append(db.allocator, "registry = ?");
    if (filters.subregistry_pointer != null) {
        try conditions.append(db.allocator, "EXISTS (SELECT 1 FROM registry_entries re WHERE re.protocol = names.protocol AND re.parent_registry = names.registry AND re.canonical_id = names.canonical_id AND re.subregistry = ?)");
    }
    if (filters.migrated) |m| {
        try conditions.append(db.allocator, if (m) "migrated = 1" else "migrated = 0");
    }
    if (filters.has_subdomains) |has_subs| {
        try conditions.append(db.allocator, if (has_subs)
            "(SELECT COUNT(*) FROM names AS sub WHERE sub.parent_name = names.name AND sub.is_reachable = 1 AND is_normalized = 1 AND sub.namehash != '0x0000000000000000000000000000000000000000000000000000000000000000') > 0"
        else
            "(SELECT COUNT(*) FROM names AS sub WHERE sub.parent_name = names.name AND sub.is_reachable = 1 AND is_normalized = 1 AND sub.namehash != '0x0000000000000000000000000000000000000000000000000000000000000000') = 0");
    }
    if (filters.subdomain_count_gt != null) {
        try conditions.append(db.allocator, "(SELECT COUNT(*) FROM names AS sub WHERE sub.parent_name = names.name AND sub.is_reachable = 1 AND is_normalized = 1 AND sub.namehash != '0x0000000000000000000000000000000000000000000000000000000000000000') > ?");
    }
    if (filters.subdomain_count_lt != null) {
        try conditions.append(db.allocator, "(SELECT COUNT(*) FROM names AS sub WHERE sub.parent_name = names.name AND sub.is_reachable = 1 AND is_normalized = 1 AND sub.namehash != '0x0000000000000000000000000000000000000000000000000000000000000000') < ?");
    }
}

/// Recursively build one filter node's boolean SQL:
///   (scalar AND scalar AND <and-child> AND (<or-child> OR <or-child>))
/// Returns null when the node has no predicates. Allocated fragments are tracked in
/// `allocated_strings` for the caller to free.
fn buildNameNodeExpr(
    db: *Database,
    filters: NameFilters,
    allocated_strings: *std.ArrayList([]const u8),
) anyerror!?[]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(db.allocator);

    try appendNameScalarConditions(db, filters, &parts, allocated_strings);

    if (filters.and_group) |children| {
        for (children) |child| {
            if (try buildNameNodeExpr(db, child, allocated_strings)) |sub| {
                try parts.append(db.allocator, sub);
            }
        }
    }
    if (filters.or_group) |children| {
        var or_parts: std.ArrayList([]const u8) = .empty;
        defer or_parts.deinit(db.allocator);
        for (children) |child| {
            if (try buildNameNodeExpr(db, child, allocated_strings)) |sub| {
                try or_parts.append(db.allocator, sub);
            }
        }
        if (or_parts.items.len > 0) {
            const joined = try db_module.query.joinWrapped(db.allocator, or_parts.items, " OR ");
            try allocated_strings.append(db.allocator, joined);
            try parts.append(db.allocator, joined);
        }
    }

    if (parts.items.len == 0) return null;
    if (parts.items.len == 1) return parts.items[0];
    const joined = try db_module.query.joinWrapped(db.allocator, parts.items, " AND ");
    try allocated_strings.append(db.allocator, joined);
    return joined;
}

/// Bind values for `NameFilters` in the same order the SQL is built: this node's
/// scalars, then `and` children, then `or` children.
fn bindNameFilters(q: *Query, filters: NameFilters) anyerror!void {
    try bindNameScalars(q, filters);
    if (filters.and_group) |children| {
        for (children) |child| try bindNameFilters(q, child);
    }
    if (filters.or_group) |children| {
        for (children) |child| try bindNameFilters(q, child);
    }
}

/// Bind one node's scalar values in the same order `appendNameScalarConditions` appends.
fn bindNameScalars(q: *Query, filters: NameFilters) !void {
    if (filters.owner) |o| try q.bindAddress(o);
    if (filters.owner_not) |o| try q.bindAddress(o);
    if (filters.owner_in) |owners| {
        for (owners) |o| try q.bindAddress(o);
    }
    if (filters.owner_not_in) |owners| {
        for (owners) |o| try q.bindAddress(o);
    }
    if (filters.name) |n| try q.bindText(n);
    if (filters.name_not) |n| try q.bindText(n);
    if (filters.name_in) |names| {
        for (names) |n| try q.bindText(n);
    }
    if (filters.name_not_in) |names| {
        for (names) |n| try q.bindText(n);
    }
    if (filters.name_contains) |n| try q.bindText(n);
    if (filters.name_contains_nocase) |n| try q.bindText(n);
    if (filters.name_not_contains) |n| try q.bindText(n);
    if (filters.name_starts_with) |n| try q.bindText(n);
    if (filters.name_starts_with_nocase) |n| try q.bindText(n);
    if (filters.name_ends_with) |n| try q.bindText(n);
    if (filters.name_ends_with_nocase) |n| try q.bindText(n);
    if (filters.label_name) |n| try q.bindText(n);
    if (filters.label_name_not) |n| try q.bindText(n);
    if (filters.label_name_in) |labels| {
        for (labels) |n| try q.bindText(n);
    }
    if (filters.label_name_not_in) |labels| {
        for (labels) |n| try q.bindText(n);
    }
    if (filters.label_name_contains) |n| try q.bindText(n);
    if (filters.label_name_contains_nocase) |n| try q.bindText(n);
    if (filters.label_name_not_contains) |n| try q.bindText(n);
    if (filters.label_name_starts_with) |n| try q.bindText(n);
    if (filters.label_name_starts_with_nocase) |n| try q.bindText(n);
    if (filters.label_name_ends_with) |n| try q.bindText(n);
    if (filters.label_name_ends_with_nocase) |n| try q.bindText(n);
    if (filters.expiry_gt) |v| try q.bindInt64(v);
    if (filters.expiry_gte) |v| try q.bindInt64(v);
    if (filters.expiry_lt) |v| try q.bindInt64(v);
    if (filters.expiry_lte) |v| try q.bindInt64(v);
    if (filters.expiry_date_gt) |v| try q.bindInt64(v);
    if (filters.expiry_date_gte) |v| try q.bindInt64(v);
    if (filters.expiry_date_lt) |v| try q.bindInt64(v);
    if (filters.expiry_date_lte) |v| try q.bindInt64(v);
    if (filters.resolved_address) |addr| try q.bindAddress(addr);
    if (filters.resolver) |addr| try q.bindAddress(addr);
    if (filters.registry) |addr| try q.bindAddress(addr);
    if (filters.subregistry_pointer) |addr| try q.bindAddress(addr);
    // migrated, has_subdomains contribute no binds (literal SQL)
    if (filters.subdomain_count_gt) |v| try q.bindInt64(v);
    if (filters.subdomain_count_lt) |v| try q.bindInt64(v);
}

/// Count rows that come before the given namehash in the current sort order.
/// Used to convert a cursor (namehash) to an offset for paginated queries.
/// Returns 0 if the namehash isn't found (caller falls through to offset=0).
pub fn countRowsBeforeNamehash(
    db: *Database,
    cursor_namehash: []const u8,
    sort_field: NameSortField,
    order_dir: OrderDir,
    filters: NameFilters,
) !u32 {
    const field_outer = sort_field.toSqlQualified("names.");
    const field_cursor = sort_field.toSqlQualified("c.");
    // "before" means "would appear earlier in the result set" — depends on sort direction:
    //   DESC sort: row A is before row B if A.field > B.field OR (A.field == B.field AND A.namehash > B.namehash)
    //   ASC sort:  row A is before row B if A.field < B.field OR (A.field == B.field AND A.namehash < B.namehash)
    // Tiebreaker by namehash ensures a stable total order across the full result set.
    //
    // The filter conditions must match getFilteredNames'/getFilteredNameCount's WHERE clause —
    // otherwise the offset count is taken over an unfiltered superset and pagination skips too
    // many rows, producing partial results (e.g. isMigrated:true with ~9 pages would lose ~343
    // rows because non-migrated rows count toward the offset).

    var conditions: std.ArrayList([]const u8) = .empty;
    defer conditions.deinit(db.allocator);
    var allocated_strings: std.ArrayList([]const u8) = .empty;
    defer {
        for (allocated_strings.items) |s| db.allocator.free(s);
        allocated_strings.deinit(db.allocator);
    }
    try appendNameFilterConditions(db, filters, &conditions, &allocated_strings);

    var filter_clause: std.ArrayList(u8) = .empty;
    defer filter_clause.deinit(db.allocator);
    if (conditions.items.len > 0) {
        for (conditions.items) |cond| {
            try filter_clause.appendSlice(db.allocator, " AND ");
            try filter_clause.appendSlice(db.allocator, cond);
        }
    }

    const op = if (order_dir == .desc) ">" else "<";
    const sql = try std.fmt.allocPrint(
        db.allocator,
        "SELECT COUNT(*) FROM names WHERE EXISTS (SELECT 1 FROM names c WHERE c.namehash = ? AND ({s} {s} {s} OR ({s} = {s} AND names.namehash {s} c.namehash))){s}",
        .{ field_outer, op, field_cursor, field_outer, field_cursor, op, filter_clause.items },
    );
    defer db.allocator.free(sql);

    var q = try Query.initCached(db, sql);
    defer q.deinit();
    try q.bindText(cursor_namehash);
    try bindNameFilters(&q, filters);
    if (!try q.step()) return 0;
    return @intCast(q.getInt64(0));
}

/// Parse name rows from a query result
fn parseNameRows(q: *Query, allocator: std.mem.Allocator) ![]models.Name {
    var names: std.ArrayList(models.Name) = .empty;
    errdefer {
        for (names.items) |*name| {
            name.deinit(allocator);
        }
        names.deinit(allocator);
    }
    while (try q.step()) {
        try names.append(allocator, try parseOneNameRow(q, allocator));
    }
    return names.toOwnedSlice(allocator);
}

/// Build one models.Name from the CURRENT row of `q` (columns 0..30 of the standard
/// SELECT list). Does not call step(); the caller controls row iteration.
fn parseOneNameRow(q: *Query, allocator: std.mem.Allocator) !models.Name {
    {
        // Column order: name(0), namehash(1), label(2), label_hash(3), parent_name(4), parent_namehash(5),
        //               owner(6), resolver(7), registry(8), protocol(9), token_id(10),
        //               canonical_id(11), token_version(12), expiry(13), registry_locked(14),
        //               migrated(15), created_at(16), registered_at(17),
        //               created_block(18), updated_at(19), updated_block(20),
        //               is_reachable(21), unreachable_since(22)
        const name_str = q.getTextSlice(0) orelse "";
        const namehash_str = q.getTextSlice(1) orelse "";
        const label_str = q.getTextSlice(2) orelse "";
        const label_hash_str = q.getTextSlice(3) orelse "";
        const parent_name_str = q.getTextSlice(4) orelse "";
        const parent_namehash_str = q.getTextSlice(5) orelse "";
        const owner_str = q.getTextSlice(6) orelse "";
        const resolver_str = q.getTextSlice(7) orelse "";
        const registry_str = q.getTextSlice(8) orelse "";
        const protocol_str = q.getTextSlice(9) orelse models.Protocol.v2.toString();
        const token_id_str = q.getTextSlice(10) orelse "0x0";
        const canonical_id_str = q.getTextSlice(11) orelse "0x0";
        const wrapper_fuses = if (q.getTextSlice(27)) |fuses| try allocator.dupe(u8, fuses) else null;
        const v1_label_hash = if (q.getTextSlice(30)) |hash| try allocator.dupe(u8, hash) else null;

        return .{
            .name = try allocator.dupe(u8, name_str),
            .namehash = try Hash.fromHex(namehash_str),
            .label = try allocator.dupe(u8, label_str),
            .label_hash = try Hash.fromHex(label_hash_str),
            .parent_name = try allocator.dupe(u8, parent_name_str),
            .parent_namehash = try Hash.fromHex(parent_namehash_str),
            .owner = try Address.fromHex(owner_str),
            .registrant = try Address.fromHex(owner_str), // Fallback
            .resolver = try Address.fromHex(resolver_str),
            .registry = try Address.fromHex(registry_str),
            .protocol = try models.Protocol.fromString(protocol_str),
            .token_id = try parseU256Hex(token_id_str),
            .canonical_id = try parseU256Hex(canonical_id_str),
            .token_version = @intCast(q.getInt64(12)),
            .expiry = @bitCast(q.getInt64(13)),
            .registry_locked = q.getBool(14),
            .migrated = q.getBool(15),
            .created_at = q.getInt64(16),
            .registered_at = q.getOptionalInt64(17) orelse q.getInt64(16),
            .created_block = @intCast(q.getInt64(18)),
            .updated_at = q.getInt64(19),
            .updated_block = @intCast(q.getInt64(20)),
            .is_wrapped = q.getBool(26),
            .wrapper_fuses = wrapper_fuses,
            .wrapper_expiry = q.getOptionalInt64(28),
            .is_v1_name = q.getBool(29),
            .v1_label_hash = v1_label_hash,
            .is_reachable = q.getBool(21),
            .unreachable_since = q.getOptionalInt64(22),
            .ttl = if (q.getOptionalInt64(23)) |t| @intCast(t) else null,
            .is_legacy = q.getBool(24),
            .is_normalized = q.getBool(25),
        };
    }
}

pub fn getAllNames(db: *Database, owner: ?Address, skip: u32, limit: u32) ![]models.Name {
    return getAllNamesWithOrder(db, owner, skip, limit, .desc, .created_at);
}

/// Filter options for querying names
pub const NameFilters = struct {
    // Grace-aware expiry comparisons (subgraph `expiryDate_*`; see the CASE in
    // the condition builder). Distinct from the bare `expiry_*` slots.
    expiry_date_gt: ?i64 = null,
    expiry_date_gte: ?i64 = null,
    expiry_date_lt: ?i64 = null,
    expiry_date_lte: ?i64 = null,
    // Owner filters
    owner: ?Address = null,
    owner_in: ?[]const Address = null,
    owner_not: ?Address = null,
    owner_not_in: ?[]const Address = null,
    // Name filters
    name: ?[]const u8 = null,
    name_in: ?[]const []const u8 = null,
    name_not: ?[]const u8 = null,
    name_not_in: ?[]const []const u8 = null,
    name_contains: ?[]const u8 = null,
    name_contains_nocase: ?[]const u8 = null,
    name_not_contains: ?[]const u8 = null,
    name_starts_with: ?[]const u8 = null,
    name_starts_with_nocase: ?[]const u8 = null,
    name_ends_with: ?[]const u8 = null,
    name_ends_with_nocase: ?[]const u8 = null,
    // Label (leftmost component) filters — map to the `label` column on names.
    label_name: ?[]const u8 = null,
    label_name_not: ?[]const u8 = null,
    label_name_in: ?[]const []const u8 = null,
    label_name_not_in: ?[]const []const u8 = null,
    label_name_contains: ?[]const u8 = null,
    label_name_contains_nocase: ?[]const u8 = null,
    label_name_not_contains: ?[]const u8 = null,
    label_name_starts_with: ?[]const u8 = null,
    label_name_starts_with_nocase: ?[]const u8 = null,
    label_name_ends_with: ?[]const u8 = null,
    label_name_ends_with_nocase: ?[]const u8 = null,
    // Expiry filters
    expiry_gt: ?i64 = null,
    expiry_gte: ?i64 = null,
    expiry_lt: ?i64 = null,
    expiry_lte: ?i64 = null,
    // Resolved address filter (requires resolver lookup)
    resolved_address: ?Address = null,
    // Resolver contract address filter
    resolver: ?Address = null,
    // Registry contract address filter (the contract that owns this name's label)
    registry: ?Address = null,
    /// Inverse subregistry-pointer filter: match names whose CURRENT subregistry pointer
    /// (the `registry_entries.subregistry` value for this name) equals this address. Powers
    /// `RegistryInfo.referencedBy` — the names that use a registry as their subname registry.
    /// Implemented as a correlated EXISTS join over `registry_entries`; there is no
    /// subregistry column on `names`.
    subregistry_pointer: ?Address = null,
    // Migration filter
    migrated: ?bool = null,
    // Subdomain filters (requires subquery)
    has_subdomains: ?bool = null,
    subdomain_count_gt: ?i64 = null,
    subdomain_count_lt: ?i64 = null,
    /// When false (default), only `is_reachable = 1` rows are returned.
    /// Set to true to include rows orphaned by ancestor subregistry repoints
    /// (for audit/debug). See `registry_entries.zig` for invalidation logic.
    include_unreachable: bool = false,
    /// When false (default), only `is_normalized = 1` rows are returned (ENSIP-15
    /// enforcement). Set true to include non-normalized names (e.g. `Nick.eth`).
    include_unnormalized: bool = false,
    /// Exact normalization filter: when set, returns only rows matching it (overrides
    /// the default-hide). Maps to GraphQL `isNormalized: Boolean`.
    is_normalized: ?bool = null,
    /// Subgraph-style boolean composition (GraphQL `and` / `or`). `and_group`: every
    /// sub-filter must match (AND); `or_group`: any sub-filter matches (OR). Both nest
    /// recursively. Default visibility (reachable/normalized/root) is applied once at the
    /// top level only — it is NOT injected into nested nodes.
    and_group: ?[]const NameFilters = null,
    or_group: ?[]const NameFilters = null,
};

/// Get names with filters pushed down to DB query
pub fn getFilteredNames(db: *Database, filters: NameFilters, skip: u32, limit: u32, order_dir: OrderDir, sort_field: NameSortField) ![]models.Name {
    const order_str = if (order_dir == .desc) "DESC" else "ASC";

    // Build WHERE conditions via the shared helper so all callers (getFilteredNames,
    // getFilteredNameCount, countRowsBeforeNamehash) stay in lockstep.
    var conditions: std.ArrayList([]const u8) = .empty;
    defer conditions.deinit(db.allocator);
    var allocated_strings: std.ArrayList([]const u8) = .empty;
    defer {
        for (allocated_strings.items) |s| db.allocator.free(s);
        allocated_strings.deinit(db.allocator);
    }
    try appendNameFilterConditions(db, filters, &conditions, &allocated_strings);

    // Build WHERE clause
    var where_clause: std.ArrayList(u8) = .empty;
    defer where_clause.deinit(db.allocator);

    if (conditions.items.len > 0) {
        try where_clause.appendSlice(db.allocator, "WHERE ");
        for (conditions.items, 0..) |cond, i| {
            if (i > 0) try where_clause.appendSlice(db.allocator, " AND ");
            try where_clause.appendSlice(db.allocator, cond);
        }
        try where_clause.appendSlice(db.allocator, " ");
    }

    // Secondary sort on namehash (same direction) gives a stable total order across tied
    // primary keys — required so cursor pagination matches countRowsBeforeNamehash's
    // stable comparator. Without it, SQLite's tie-breaking is non-deterministic and pages
    // can duplicate or skip items.
    const sql = try std.fmt.allocPrint(db.allocator,
        \\SELECT name, namehash, label, label_hash, parent_name, parent_namehash, owner, resolver, registry, protocol,
        \\       token_id, canonical_id, token_version, expiry, registry_locked, migrated,
        \\       created_at, registered_at, created_block, updated_at, updated_block,
        \\       is_reachable, unreachable_since, ttl, is_legacy, is_normalized, is_wrapped, wrapper_fuses, wrapper_expiry, is_v1_name, v1_label_hash
        \\FROM names {s}ORDER BY {s} {s}, namehash {s} LIMIT ? OFFSET ?
    , .{ where_clause.items, sort_field.toSql(), order_str, order_str });
    defer db.allocator.free(sql);

    var q = try Query.initCached(db, sql);
    defer q.deinit();

    // Bind parameters via the shared helper (same order as appendNameFilterConditions).
    try bindNameFilters(&q, filters);
    try q.bindInt(@intCast(limit));
    try q.bindInt(@intCast(skip));

    return parseNameRows(&q, db.allocator);
}

/// A keyset (seek) pagination anchor: the sort-field value + namehash of the last
/// row the client saw, both as text (the namehash is 0x-hex, the value is the
/// column's text form). Compared against the row's (sort_field, namehash) tuple.
pub const KeysetAnchor = struct {
    sort_value: []const u8,
    namehash: []const u8,
};

/// Result of a keyset fetch: the page rows plus each row's sort-field value (text),
/// parallel to `names`, so the caller can build the next cursor. Caller owns both.
pub const KeysetResult = struct {
    names: []models.Name,
    sort_values: [][]u8,

    pub fn deinit(self: *KeysetResult, allocator: std.mem.Allocator) void {
        for (self.names) |*n| n.deinit(allocator);
        allocator.free(self.names);
        for (self.sort_values) |v| allocator.free(v);
        allocator.free(self.sort_values);
    }
};

fn bindKeysetValue(q: *Query, sort_field: NameSortField, value: []const u8) !void {
    switch (sort_field) {
        .name => try q.bindText(value),
        // created_at / expiry / expiry_effective / registered_at are integer columns;
        // bind as int so the comparison is numeric (and valid on Postgres, which won't
        // coerce a text bind against an integer column).
        else => try q.bindInt64(std.fmt.parseInt(i64, value, 10) catch 0),
    }
}

/// Keyset (seek) equivalent of `getFilteredNames`: instead of OFFSET, it takes the
/// last row's `(sort_value, namehash)` anchor and emits rows strictly after it in the
/// stable `ORDER BY {sort_field} {dir}, namehash {dir}` order. This is an index range
/// scan (O(limit)) per page vs OFFSET's O(n + skip), and drops the per-page
/// full-table `countRowsBeforeNamehash` scan entirely.
///
/// The keyset predicate is the standard tuple comparison
///   ({field} {op} ?sv) OR ({field} = ?sv AND namehash {op} ?nh)
/// with `op` matching the effective order direction. The `{field} = ?sv AND namehash
/// {op} ?nh` term is what makes TIED sort values (e.g. many rows sharing a
/// `created_at`) page correctly instead of dropping/duplicating at the boundary.
///
/// `anchor == null` returns the first page. Each row's sort value is returned in
/// parallel (read from an extra `{field} AS _sortval` column) so the caller can build
/// per-edge cursors without materializing the sort field on models.Name.
pub fn getFilteredNamesKeyset(db: *Database, filters: NameFilters, anchor: ?KeysetAnchor, limit: u32, order_dir: OrderDir, sort_field: NameSortField) !KeysetResult {
    const order_str = if (order_dir == .desc) "DESC" else "ASC";
    const op = if (order_dir == .desc) "<" else ">";

    var conditions: std.ArrayList([]const u8) = .empty;
    defer conditions.deinit(db.allocator);
    var allocated_strings: std.ArrayList([]const u8) = .empty;
    defer {
        for (allocated_strings.items) |str| db.allocator.free(str);
        allocated_strings.deinit(db.allocator);
    }
    try appendNameFilterConditions(db, filters, &conditions, &allocated_strings);

    if (anchor != null) {
        const pred = try std.fmt.allocPrint(db.allocator, "({s} {s} ? OR ({s} = ? AND namehash {s} ?))", .{ sort_field.toSql(), op, sort_field.toSql(), op });
        try allocated_strings.append(db.allocator, pred);
        try conditions.append(db.allocator, pred);
    }

    var where_clause: std.ArrayList(u8) = .empty;
    defer where_clause.deinit(db.allocator);
    if (conditions.items.len > 0) {
        try where_clause.appendSlice(db.allocator, "WHERE ");
        for (conditions.items, 0..) |cond, i| {
            if (i > 0) try where_clause.appendSlice(db.allocator, " AND ");
            try where_clause.appendSlice(db.allocator, cond);
        }
        try where_clause.appendSlice(db.allocator, " ");
    }

    // Extra trailing column `{s} AS _sortval` (index 31) so we can read each row's
    // sort value without adding it to models.Name.
    const sql = try std.fmt.allocPrint(db.allocator, "SELECT name, namehash, label, label_hash, parent_name, parent_namehash, owner, resolver, registry, protocol, token_id, canonical_id, token_version, expiry, registry_locked, migrated, created_at, registered_at, created_block, updated_at, updated_block, is_reachable, unreachable_since, ttl, is_legacy, is_normalized, is_wrapped, wrapper_fuses, wrapper_expiry, is_v1_name, v1_label_hash, CAST({s} AS TEXT) AS _sortval FROM names {s}ORDER BY {s} {s}, namehash {s} LIMIT ?", .{ sort_field.toSql(), where_clause.items, sort_field.toSql(), order_str, order_str });
    defer db.allocator.free(sql);

    var q = try Query.init(db, sql);
    defer q.deinit();

    try bindNameFilters(&q, filters);
    if (anchor) |a| {
        try bindKeysetValue(&q, sort_field, a.sort_value);
        try bindKeysetValue(&q, sort_field, a.sort_value);
        try q.bindText(a.namehash);
    }
    try q.bindInt(@intCast(limit));

    var names: std.ArrayList(models.Name) = .empty;
    errdefer {
        for (names.items) |*n| n.deinit(db.allocator);
        names.deinit(db.allocator);
    }
    var sort_values: std.ArrayList([]u8) = .empty;
    errdefer {
        for (sort_values.items) |v| db.allocator.free(v);
        sort_values.deinit(db.allocator);
    }
    while (try q.step()) {
        const row = try parseOneNameRow(&q, db.allocator);
        errdefer {
            var m = row;
            m.deinit(db.allocator);
        }
        const sv = try db.allocator.dupe(u8, q.getTextSlice(31) orelse "");
        errdefer db.allocator.free(sv);
        try names.append(db.allocator, row);
        try sort_values.append(db.allocator, sv);
    }

    return .{
        .names = try names.toOwnedSlice(db.allocator),
        .sort_values = try sort_values.toOwnedSlice(db.allocator),
    };
}

/// Get all names with configurable order direction
pub fn getAllNamesWithOrder(db: *Database, owner: ?Address, skip: u32, limit: u32, order_dir: OrderDir, sort_field: NameSortField) ![]models.Name {
    const order_str = if (order_dir == .desc) "DESC" else "ASC";
    // Secondary sort on namehash (same direction) — see countRowsBeforeNamehash for why.
    // is_reachable = 1 filter is applied by default; unreachable rows are
    // hidden from the legacy unfiltered listing. Synthetic root domain
    // (namehash 0x000…0) is also excluded — see `appendNameFilterConditions`.
    // Use `getFilteredNames` with `include_unreachable = true` to override.
    const sql = if (owner != null)
        try std.fmt.allocPrint(db.allocator,
            \\SELECT name, namehash, label, label_hash, parent_name, parent_namehash, owner, resolver, registry, protocol,
            \\       token_id, canonical_id, token_version, expiry, registry_locked, migrated,
            \\       created_at, registered_at, created_block, updated_at, updated_block,
            \\       is_reachable, unreachable_since, ttl, is_legacy, is_normalized, is_wrapped, wrapper_fuses, wrapper_expiry, is_v1_name, v1_label_hash
            \\FROM names WHERE is_reachable = 1 AND is_normalized = 1 AND owner = ? AND namehash != '0x0000000000000000000000000000000000000000000000000000000000000000' AND NOT (names.protocol = 'v1' AND EXISTS (SELECT 1 FROM names v2twin WHERE v2twin.namehash = names.namehash AND v2twin.protocol = 'v2')) ORDER BY {s} {s}, namehash {s} LIMIT ? OFFSET ?
        , .{ sort_field.toSql(), order_str, order_str })
    else
        try std.fmt.allocPrint(db.allocator,
            \\SELECT name, namehash, label, label_hash, parent_name, parent_namehash, owner, resolver, registry, protocol,
            \\       token_id, canonical_id, token_version, expiry, registry_locked, migrated,
            \\       created_at, registered_at, created_block, updated_at, updated_block,
            \\       is_reachable, unreachable_since, ttl, is_legacy, is_normalized, is_wrapped, wrapper_fuses, wrapper_expiry, is_v1_name, v1_label_hash
            \\FROM names WHERE is_reachable = 1 AND is_normalized = 1 AND namehash != '0x0000000000000000000000000000000000000000000000000000000000000000' AND NOT (names.protocol = 'v1' AND EXISTS (SELECT 1 FROM names v2twin WHERE v2twin.namehash = names.namehash AND v2twin.protocol = 'v2')) ORDER BY {s} {s}, namehash {s} LIMIT ? OFFSET ?
        , .{ sort_field.toSql(), order_str, order_str });
    defer db.allocator.free(sql);

    var q = try Query.initCached(db, sql);
    defer q.deinit();

    if (owner) |o| {
        try q.bindAddress(o);
    }
    try q.bindInt(@intCast(limit));
    try q.bindInt(@intCast(skip));

    return parseNameRows(&q, db.allocator);
}

// ============================================================================
// AGGREGATION OPERATIONS
// ============================================================================

/// Get count of names with optional filters.
/// Builds the same WHERE clause as getFilteredNames but uses SELECT COUNT(*).
pub fn getFilteredNameCount(db: *Database, filters: NameFilters) !usize {
    var conditions: std.ArrayList([]const u8) = .empty;
    defer conditions.deinit(db.allocator);

    var allocated_strings: std.ArrayList([]const u8) = .empty;
    defer {
        for (allocated_strings.items) |s| db.allocator.free(s);
        allocated_strings.deinit(db.allocator);
    }
    try appendNameFilterConditions(db, filters, &conditions, &allocated_strings);

    // Build SQL
    var where_clause: std.ArrayList(u8) = .empty;
    defer where_clause.deinit(db.allocator);

    if (conditions.items.len > 0) {
        try where_clause.appendSlice(db.allocator, "WHERE ");
        for (conditions.items, 0..) |cond, i| {
            if (i > 0) try where_clause.appendSlice(db.allocator, " AND ");
            try where_clause.appendSlice(db.allocator, cond);
        }
        try where_clause.appendSlice(db.allocator, " ");
    }

    const sql = try std.fmt.allocPrint(db.allocator, "SELECT COUNT(*) FROM names {s}", .{where_clause.items});
    defer db.allocator.free(sql);

    var q = try Query.initCached(db, sql);
    defer q.deinit();

    try bindNameFilters(&q, filters);

    if (try q.step()) {
        return @intCast(q.getInt64(0));
    }
    return 0;
}
