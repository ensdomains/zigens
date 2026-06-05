/// Domain-related GraphQL resolvers
/// - resolveDomain: Single domain lookup by id
/// - resolveDomains: List domains with filters
/// - resolveDomainConnection: Cursor-based pagination for domains
const std = @import("std");
const common = @import("common.zig");
const db = common.db;
const models = common.models;
const Address = common.Address;
const parser = common.parser;
const pagination = common.pagination;
const builders = @import("../builders/builders.zig");
const loaders = common.loaders;
const namehash = common.namehash_fn;
const Hash = common.Hash;
const NestedContext = builders.NestedContext;

/// Resolve a domain id (either a name like "alice.eth" or a 32-byte namehash hex like
/// "0x...64 hex chars") to a namehash. Mirrors the schema doc on `domain(id:)` which
/// promises both forms work.
fn resolveDomainId(allocator: std.mem.Allocator, id: []const u8) !Hash {
    if (id.len == 66 and std.mem.startsWith(u8, id, "0x")) {
        var all_hex = true;
        for (id[2..]) |c| {
            if (!std.ascii.isHex(c)) {
                all_hex = false;
                break;
            }
        }
        if (all_hex) return Hash.fromHex(id);
    }
    return namehash(allocator, id);
}

pub fn mapDomainOrderBy(order_by: ?[]const u8) db.NameSortField {
    const field_name = order_by orelse return .created_at;
    if (std.mem.eql(u8, field_name, "name")) return .name;
    if (std.mem.eql(u8, field_name, "createdAt")) return .created_at;
    if (std.mem.eql(u8, field_name, "expiryDate")) return .expiry;
    if (std.mem.eql(u8, field_name, "registrationDate")) return .registered_at;
    return .created_at;
}

/// Parsed `where:` arguments for the Domain queries.
///
/// `resolveDomains` and `resolveDomainConnection` both accept the same
/// `DomainFilter` input object. Before this helper, each one had its own
/// ~140-line parsing block that drifted between them every time a filter
/// was added (and forced every new filter to be wired in twice). This struct
/// centralises both the slot layout AND the parsing so they stay in sync by
/// construction.
const ParsedDomainFilter = struct {
    name: ?[]const u8 = null,
    name_in: ?[][]const u8 = null,
    name_not: ?[]const u8 = null,
    name_not_in: ?[][]const u8 = null,
    name_contains: ?[]const u8 = null,
    name_contains_nocase: ?[]const u8 = null,
    name_not_contains: ?[]const u8 = null,
    name_starts_with: ?[]const u8 = null,
    name_starts_with_nocase: ?[]const u8 = null,
    name_ends_with: ?[]const u8 = null,
    name_ends_with_nocase: ?[]const u8 = null,
    label_name: ?[]const u8 = null,
    label_name_not: ?[]const u8 = null,
    label_name_in: ?[][]const u8 = null,
    label_name_not_in: ?[][]const u8 = null,
    label_name_contains: ?[]const u8 = null,
    label_name_contains_nocase: ?[]const u8 = null,
    label_name_not_contains: ?[]const u8 = null,
    label_name_starts_with: ?[]const u8 = null,
    label_name_starts_with_nocase: ?[]const u8 = null,
    label_name_ends_with: ?[]const u8 = null,
    label_name_ends_with_nocase: ?[]const u8 = null,
    owner: ?Address = null,
    owner_in: ?[]Address = null,
    owner_not: ?Address = null,
    owner_not_in: ?[]Address = null,
    resolved_address: ?Address = null,
    resolver: ?Address = null,
    has_subdomains: ?bool = null,
    subdomain_count_gt: ?i64 = null,
    subdomain_count_lt: ?i64 = null,
    expiry_gt: ?i64 = null,
    expiry_gte: ?i64 = null,
    expiry_lt: ?i64 = null,
    expiry_lte: ?i64 = null,
    migrated: ?bool = null,
    include_unreachable: ?bool = null,
    is_normalized: ?bool = null,
    include_unnormalized: ?bool = null,
    /// Subgraph-style boolean composition (`where: { and: [...], or: [...] }`).
    /// Each element is a nested DomainFilter, parsed recursively.
    and_filters: ?[]ParsedDomainFilter = null,
    or_filters: ?[]ParsedDomainFilter = null,

    /// Frees the heap-allocated slice fields (`*_in` lists + nested and/or groups).
    /// Scalar fields point into the caller-owned GraphQL arg buffer and need no
    /// cleanup. (Request allocations are arena-backed, so this is belt-and-braces.)
    pub fn deinit(self: *ParsedDomainFilter, allocator: std.mem.Allocator) void {
        if (self.name_in) |s| allocator.free(s);
        if (self.name_not_in) |s| allocator.free(s);
        if (self.label_name_in) |s| allocator.free(s);
        if (self.label_name_not_in) |s| allocator.free(s);
        if (self.owner_in) |s| allocator.free(s);
        if (self.owner_not_in) |s| allocator.free(s);
        if (self.and_filters) |group| {
            for (group) |*c| c.deinit(allocator);
            allocator.free(group);
        }
        if (self.or_filters) |group| {
            for (group) |*c| c.deinit(allocator);
            allocator.free(group);
        }
    }
};

/// Parse the `where:` arg of a domains/domainConnection query into the
/// `ParsedDomainFilter` struct. Unknown args were already rejected by the
/// schema validator at parse time, so the `or`-chain at the bottom discards
/// match-misses silently.
fn parseDomainWhere(field: *const parser.Field, allocator: std.mem.Allocator) !ParsedDomainFilter {
    const where_args = common.getObjectArg(field, "where") orelse return ParsedDomainFilter{};
    return parseWhereArgs(where_args, allocator);
}

/// Parse a DomainFilter argument list — the top-level `where:` object or a nested
/// `and`/`or` element — into a `ParsedDomainFilter`. Recursive for the boolean groups.
fn parseWhereArgs(where_args: []const parser.Argument, allocator: std.mem.Allocator) anyerror!ParsedDomainFilter {
    var out = ParsedDomainFilter{};
    errdefer out.deinit(allocator);

    for (where_args) |a| {
        // Boolean composition: `and` / `or` are lists of nested DomainFilters (subgraph parity).
        if ((std.mem.eql(u8, a.name, "and") or std.mem.eql(u8, a.name, "or")) and a.value == .list) {
            const is_and = std.mem.eql(u8, a.name, "and");
            var group: std.ArrayList(ParsedDomainFilter) = .{};
            errdefer {
                for (group.items) |*c| c.deinit(allocator);
                group.deinit(allocator);
            }
            for (a.value.list) |item| {
                if (item == .object) {
                    try group.append(allocator, try parseWhereArgs(item.object, allocator));
                }
            }
            const slice = try group.toOwnedSlice(allocator);
            if (is_and) {
                out.and_filters = slice;
            } else {
                out.or_filters = slice;
            }
            continue;
        }
        // List-typed args allocate via the shared helpers in common.zig.
        if (std.mem.eql(u8, a.name, "owner_in")) {
            if (try common.parseAddressListArg(a, allocator)) |v| out.owner_in = v;
            continue;
        }
        if (std.mem.eql(u8, a.name, "owner_not_in")) {
            if (try common.parseAddressListArg(a, allocator)) |v| out.owner_not_in = v;
            continue;
        }
        if (std.mem.eql(u8, a.name, "name_in")) {
            if (try common.parseStringListArg(a, allocator)) |v| out.name_in = v;
            continue;
        }
        if (std.mem.eql(u8, a.name, "name_not_in")) {
            if (try common.parseStringListArg(a, allocator)) |v| out.name_not_in = v;
            continue;
        }
        if (std.mem.eql(u8, a.name, "labelName_in")) {
            if (try common.parseStringListArg(a, allocator)) |v| out.label_name_in = v;
            continue;
        }
        if (std.mem.eql(u8, a.name, "labelName_not_in")) {
            if (try common.parseStringListArg(a, allocator)) |v| out.label_name_not_in = v;
            continue;
        }
        // `owner_:` nested AccountFilter — subgraph parity — translates to owner / owner_in.
        if (std.mem.eql(u8, a.name, "owner_") and a.value == .object) {
            for (a.value.object) |nested| {
                if (std.mem.eql(u8, nested.name, "id") and nested.value == .string) {
                    out.owner = Address.fromHex(nested.value.string) catch return error.InvalidAddress;
                } else if (std.mem.eql(u8, nested.name, "id_in")) {
                    if (try common.parseAddressListArg(nested, allocator)) |v| out.owner_in = v;
                }
            }
            continue;
        }

        _ = common.matchStringArg(a, "name", &out.name) or
            common.matchStringArg(a, "name_not", &out.name_not) or
            common.matchStringArg(a, "name_contains", &out.name_contains) or
            common.matchStringArg(a, "name_contains_nocase", &out.name_contains_nocase) or
            common.matchStringArg(a, "name_not_contains", &out.name_not_contains) or
            common.matchStringArg(a, "name_starts_with", &out.name_starts_with) or
            common.matchStringArg(a, "name_starts_with_nocase", &out.name_starts_with_nocase) or
            common.matchStringArg(a, "name_ends_with", &out.name_ends_with) or
            common.matchStringArg(a, "name_ends_with_nocase", &out.name_ends_with_nocase) or
            common.matchStringArg(a, "labelName", &out.label_name) or
            common.matchStringArg(a, "labelName_not", &out.label_name_not) or
            common.matchStringArg(a, "labelName_contains", &out.label_name_contains) or
            common.matchStringArg(a, "labelName_contains_nocase", &out.label_name_contains_nocase) or
            common.matchStringArg(a, "labelName_not_contains", &out.label_name_not_contains) or
            common.matchStringArg(a, "labelName_starts_with", &out.label_name_starts_with) or
            common.matchStringArg(a, "labelName_starts_with_nocase", &out.label_name_starts_with_nocase) or
            common.matchStringArg(a, "labelName_ends_with", &out.label_name_ends_with) or
            common.matchStringArg(a, "labelName_ends_with_nocase", &out.label_name_ends_with_nocase) or
            (try common.matchAddressArg(a, "owner", &out.owner)) or
            (try common.matchAddressArg(a, "owner_not", &out.owner_not)) or
            (try common.matchAddressArg(a, "resolvedAddress", &out.resolved_address)) or
            (try common.matchAddressArg(a, "resolver", &out.resolver)) or
            common.matchBoolArg(a, "hasSubdomains", &out.has_subdomains) or
            common.matchIntArg(a, "subdomainCount_gt", &out.subdomain_count_gt) or
            common.matchIntArg(a, "subdomainCount_lt", &out.subdomain_count_lt) or
            common.matchIntArg(a, "expiry_gt", &out.expiry_gt) or
            common.matchIntArg(a, "expiry_gte", &out.expiry_gte) or
            common.matchIntArg(a, "expiry_lt", &out.expiry_lt) or
            common.matchIntArg(a, "expiry_lte", &out.expiry_lte) or
            // Subgraph-parity aliases — populate the same filter slots as expiry_*.
            common.matchIntArg(a, "expiryDate_gt", &out.expiry_gt) or
            common.matchIntArg(a, "expiryDate_gte", &out.expiry_gte) or
            common.matchIntArg(a, "expiryDate_lt", &out.expiry_lt) or
            common.matchIntArg(a, "expiryDate_lte", &out.expiry_lte) or
            common.matchBoolArg(a, "isMigrated", &out.migrated) or
            common.matchBoolArg(a, "includeUnreachable", &out.include_unreachable) or
            common.matchBoolArg(a, "isNormalized", &out.is_normalized) or
            common.matchBoolArg(a, "includeUnnormalized", &out.include_unnormalized);
    }
    return out;
}

/// Map a parsed DomainFilter (one node) to a storage `NameFilters`, recursively
/// translating the `and`/`or` groups. Allocations are request-arena-backed.
fn toNameFilters(p: *const ParsedDomainFilter, allocator: std.mem.Allocator) anyerror!db.NameFilters {
    return db.NameFilters{
        .owner = p.owner,
        .owner_in = p.owner_in,
        .owner_not = p.owner_not,
        .owner_not_in = p.owner_not_in,
        .name = p.name,
        .name_in = p.name_in,
        .name_not = p.name_not,
        .name_not_in = p.name_not_in,
        .name_contains = p.name_contains,
        .name_contains_nocase = p.name_contains_nocase,
        .name_not_contains = p.name_not_contains,
        .name_starts_with = p.name_starts_with,
        .name_starts_with_nocase = p.name_starts_with_nocase,
        .name_ends_with = p.name_ends_with,
        .name_ends_with_nocase = p.name_ends_with_nocase,
        .label_name = p.label_name,
        .label_name_not = p.label_name_not,
        .label_name_in = p.label_name_in,
        .label_name_not_in = p.label_name_not_in,
        .label_name_contains = p.label_name_contains,
        .label_name_contains_nocase = p.label_name_contains_nocase,
        .label_name_not_contains = p.label_name_not_contains,
        .label_name_starts_with = p.label_name_starts_with,
        .label_name_starts_with_nocase = p.label_name_starts_with_nocase,
        .label_name_ends_with = p.label_name_ends_with,
        .label_name_ends_with_nocase = p.label_name_ends_with_nocase,
        .expiry_gt = p.expiry_gt,
        .expiry_gte = p.expiry_gte,
        .expiry_lt = p.expiry_lt,
        .expiry_lte = p.expiry_lte,
        .resolved_address = p.resolved_address,
        .resolver = p.resolver,
        .migrated = p.migrated,
        .has_subdomains = p.has_subdomains,
        .subdomain_count_gt = p.subdomain_count_gt,
        .subdomain_count_lt = p.subdomain_count_lt,
        .include_unreachable = p.include_unreachable orelse false,
        .include_unnormalized = p.include_unnormalized orelse false,
        .is_normalized = p.is_normalized,
        .and_group = try mapFilterGroup(p.and_filters, allocator),
        .or_group = try mapFilterGroup(p.or_filters, allocator),
    };
}

/// Map a parsed `and`/`or` group to a slice of storage `NameFilters` (or null).
fn mapFilterGroup(group: ?[]const ParsedDomainFilter, allocator: std.mem.Allocator) anyerror!?[]const db.NameFilters {
    const children = group orelse return null;
    const arr = try allocator.alloc(db.NameFilters, children.len);
    for (children, 0..) |*c, i| arr[i] = try toNameFilters(c, allocator);
    return arr;
}

pub fn resolveDomains(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));
    const allocator = ctx.allocator;

    const page = try common.parsePagination(field, 100);
    const first = page.first;
    const skip = page.skip;

    // Parse `where` filter via the shared helper.
    var parsed = try parseDomainWhere(field, allocator);
    defer parsed.deinit(allocator);
    const filter_name = parsed.name;
    const filter_name_in = parsed.name_in;
    const filter_name_not = parsed.name_not;
    const filter_name_not_in = parsed.name_not_in;
    const filter_name_contains = parsed.name_contains;
    const filter_name_contains_nocase = parsed.name_contains_nocase;
    const filter_name_not_contains = parsed.name_not_contains;
    const filter_name_starts_with = parsed.name_starts_with;
    const filter_name_starts_with_nocase = parsed.name_starts_with_nocase;
    const filter_name_ends_with = parsed.name_ends_with;
    const filter_name_ends_with_nocase = parsed.name_ends_with_nocase;
    const filter_label_name = parsed.label_name;
    const filter_label_name_not = parsed.label_name_not;
    const filter_label_name_in = parsed.label_name_in;
    const filter_label_name_not_in = parsed.label_name_not_in;
    const filter_label_name_contains = parsed.label_name_contains;
    const filter_label_name_contains_nocase = parsed.label_name_contains_nocase;
    const filter_label_name_not_contains = parsed.label_name_not_contains;
    const filter_label_name_starts_with = parsed.label_name_starts_with;
    const filter_label_name_starts_with_nocase = parsed.label_name_starts_with_nocase;
    const filter_label_name_ends_with = parsed.label_name_ends_with;
    const filter_label_name_ends_with_nocase = parsed.label_name_ends_with_nocase;
    const filter_owner = parsed.owner;
    const filter_owner_in = parsed.owner_in;
    const filter_owner_not = parsed.owner_not;
    const filter_owner_not_in = parsed.owner_not_in;
    const filter_resolved_address = parsed.resolved_address;
    const filter_resolver = parsed.resolver;
    const filter_has_subdomains = parsed.has_subdomains;
    const filter_subdomain_count_gt = parsed.subdomain_count_gt;
    const filter_subdomain_count_lt = parsed.subdomain_count_lt;
    const filter_expiry_gt = parsed.expiry_gt;
    const filter_expiry_gte = parsed.expiry_gte;
    const filter_expiry_lt = parsed.expiry_lt;
    const filter_expiry_lte = parsed.expiry_lte;
    const filter_migrated = parsed.migrated;

    const include_unreachable = parsed.include_unreachable orelse false;
    const include_unnormalized = parsed.include_unnormalized orelse false;

    const order_by = parser.getStringArg(field, "orderBy", null);
    const order_dir_parsed = common.parseOrderDirection(field, db.OrderDir, .desc);

    // Get names from database
    // Optimization: if ONLY name filter is set (no other filters), use direct namehash lookup (O(1))
    // If additional filters are present, fall through to getFilteredNames so all filters apply correctly
    const no_label_filters = filter_label_name == null and filter_label_name_not == null and
        filter_label_name_in == null and filter_label_name_not_in == null and
        filter_label_name_contains == null and filter_label_name_contains_nocase == null and
        filter_label_name_not_contains == null and
        filter_label_name_starts_with == null and filter_label_name_starts_with_nocase == null and
        filter_label_name_ends_with == null and filter_label_name_ends_with_nocase == null;

    const only_name_filter = filter_name != null and
        filter_name_not == null and filter_name_not_in == null and
        filter_owner == null and filter_owner_in == null and
        filter_owner_not == null and filter_owner_not_in == null and
        filter_name_contains == null and filter_name_contains_nocase == null and
        filter_name_not_contains == null and
        filter_name_starts_with == null and filter_name_starts_with_nocase == null and
        filter_name_ends_with == null and filter_name_ends_with_nocase == null and
        no_label_filters and
        filter_resolved_address == null and filter_resolver == null and
        filter_has_subdomains == null and
        filter_subdomain_count_gt == null and filter_subdomain_count_lt == null and
        filter_expiry_gt == null and filter_expiry_gte == null and
        filter_expiry_lt == null and filter_expiry_lte == null and
        filter_migrated == null and
        parsed.and_filters == null and parsed.or_filters == null;

    if (only_name_filter) {
        const exact_name = filter_name.?;
        const nh = try namehash(allocator, exact_name);

        var found_name = try database.getNameByNamehash(nh);
        if (found_name) |*name| {
            // Apply reachability filter: by default, hide unreachable rows
            // even on direct namehash lookup. Audit clients pass
            // `includeUnreachable: true` to override.
            if (!include_unreachable and !name.is_reachable) {
                defer name.deinit(allocator);
                return .{ .json = try allocator.dupe(u8, "[]") };
            }
            // Normalization filter — mirror getFilteredNames so this fast-path matches
            // the listing contract (domainConnection / domains both default-hide
            // non-normalized names). An explicit isNormalized wins; otherwise hide
            // non-normalized unless includeUnnormalized. (Singular domain(id:) does NOT
            // apply this — exact id/namehash lookups still return non-normalized names.)
            const norm_ok = if (parsed.is_normalized) |want|
                (name.is_normalized == want)
            else
                (include_unnormalized or name.is_normalized);
            if (!norm_ok) {
                defer name.deinit(allocator);
                return .{ .json = try allocator.dupe(u8, "[]") };
            }
            defer name.deinit(allocator);

            const name_json = try builders.buildDomainJson(name, field.selections, .{
                .database = database,
                .depth = 0,
                .allocator = allocator,
                .loaders = ctx.loaders,
            });
            defer allocator.free(name_json);

            // Wrap in array: [{...}]
            var result = try allocator.alloc(u8, name_json.len + 2);
            result[0] = '[';
            @memcpy(result[1..][0..name_json.len], name_json);
            result[name_json.len + 1] = ']';
            return .{ .json = result };
        }

        // No match found - return empty array
        return .{ .json = try allocator.dupe(u8, "[]") };
    }

    // Check if any filters are set
    const has_filters = filter_name != null or filter_name_in != null or
        filter_name_not != null or filter_name_not_in != null or
        filter_name_contains != null or filter_name_contains_nocase != null or
        filter_name_not_contains != null or
        filter_name_starts_with != null or filter_name_starts_with_nocase != null or
        filter_name_ends_with != null or filter_name_ends_with_nocase != null or
        !no_label_filters or
        filter_owner != null or filter_owner_in != null or
        filter_owner_not != null or filter_owner_not_in != null or
        filter_resolved_address != null or filter_resolver != null or filter_has_subdomains != null or
        filter_subdomain_count_gt != null or filter_subdomain_count_lt != null or
        filter_expiry_gt != null or filter_expiry_gte != null or
        filter_expiry_lt != null or filter_expiry_lte != null or
        filter_migrated != null or include_unreachable or
        include_unnormalized or parsed.is_normalized != null or
        parsed.and_filters != null or parsed.or_filters != null;

    // All filters pushed to DB - no need to over-fetch
    const fetch_limit: u32 = first;

    // Map GraphQL orderBy to SQL sort field
    const sort_field = mapDomainOrderBy(order_by);
    const order_dir = order_dir_parsed;

    // Use filtered query with all filters pushed to DB
    const names = if (has_filters)
        try database.getFilteredNames(.{
            .owner = filter_owner,
            .owner_in = filter_owner_in,
            .owner_not = filter_owner_not,
            .owner_not_in = filter_owner_not_in,
            .name = filter_name,
            .name_in = filter_name_in,
            .name_not = filter_name_not,
            .name_not_in = filter_name_not_in,
            .name_contains = filter_name_contains,
            .name_contains_nocase = filter_name_contains_nocase,
            .name_not_contains = filter_name_not_contains,
            .name_starts_with = filter_name_starts_with,
            .name_starts_with_nocase = filter_name_starts_with_nocase,
            .name_ends_with = filter_name_ends_with,
            .name_ends_with_nocase = filter_name_ends_with_nocase,
            .label_name = filter_label_name,
            .label_name_not = filter_label_name_not,
            .label_name_in = filter_label_name_in,
            .label_name_not_in = filter_label_name_not_in,
            .label_name_contains = filter_label_name_contains,
            .label_name_contains_nocase = filter_label_name_contains_nocase,
            .label_name_not_contains = filter_label_name_not_contains,
            .label_name_starts_with = filter_label_name_starts_with,
            .label_name_starts_with_nocase = filter_label_name_starts_with_nocase,
            .label_name_ends_with = filter_label_name_ends_with,
            .label_name_ends_with_nocase = filter_label_name_ends_with_nocase,
            .expiry_gt = filter_expiry_gt,
            .expiry_gte = filter_expiry_gte,
            .expiry_lt = filter_expiry_lt,
            .expiry_lte = filter_expiry_lte,
            .resolved_address = filter_resolved_address,
            .resolver = filter_resolver,
            .migrated = filter_migrated,
            .has_subdomains = filter_has_subdomains,
            .subdomain_count_gt = filter_subdomain_count_gt,
            .subdomain_count_lt = filter_subdomain_count_lt,
            .include_unreachable = include_unreachable,
            .include_unnormalized = include_unnormalized,
            .is_normalized = parsed.is_normalized,
            .and_group = try mapFilterGroup(parsed.and_filters, allocator),
            .or_group = try mapFilterGroup(parsed.or_filters, allocator),
        }, @intCast(skip), fetch_limit, order_dir, sort_field)
    else
        try database.getAllNamesWithOrder(null, @intCast(skip), fetch_limit, order_dir, sort_field);
    defer {
        for (names) |*name| {
            name.deinit(allocator);
        }
        allocator.free(names);
    }

    // Build JSON from DB-sorted names
    var json: std.ArrayList(u8) = .{};
    defer json.deinit(allocator);

    try json.appendSlice(allocator, "[");
    const items_to_return = @min(first, names.len);

    for (names[0..@as(usize, @intCast(items_to_return))], 0..) |*name, i| {
        if (i > 0) try json.appendSlice(allocator, ",");

        const name_json = try builders.buildDomainJson(name, field.selections, .{
            .database = database,
            .depth = 0,
            .allocator = allocator,
            .loaders = ctx.loaders,
        });
        defer allocator.free(name_json);
        try json.appendSlice(allocator, name_json);
    }
    try json.appendSlice(allocator, "]");

    const result_json = try allocator.dupe(u8, json.items);
    return parser.FieldResult{ .json = result_json };
}

/// Resolver for domainConnection query (cursor-based pagination)
pub fn resolveDomainConnection(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));
    const allocator = ctx.allocator;

    // Parse pagination arguments
    const first = parser.getIntArg(field, "first", null);
    const after = parser.getStringArg(field, "after", null);
    const last = parser.getIntArg(field, "last", null);
    const before = parser.getStringArg(field, "before", null);

    const params = try pagination.PaginationParams.parse(
        first,
        after,
        last,
        before,
        100, // default limit
        1000, // max limit
    );

    // Parse `where` filter via the shared helper.
    var parsed = try parseDomainWhere(field, allocator);
    defer parsed.deinit(allocator);
    const filter_owner = parsed.owner;
    const filter_owner_in = parsed.owner_in;
    const filter_owner_not = parsed.owner_not;
    const filter_owner_not_in = parsed.owner_not_in;
    const filter_name = parsed.name;
    const filter_name_in = parsed.name_in;
    const filter_name_not = parsed.name_not;
    const filter_name_not_in = parsed.name_not_in;
    const filter_name_contains = parsed.name_contains;
    const filter_name_contains_nocase = parsed.name_contains_nocase;
    const filter_name_not_contains = parsed.name_not_contains;
    const filter_name_starts_with = parsed.name_starts_with;
    const filter_name_starts_with_nocase = parsed.name_starts_with_nocase;
    const filter_name_ends_with = parsed.name_ends_with;
    const filter_name_ends_with_nocase = parsed.name_ends_with_nocase;
    const filter_label_name = parsed.label_name;
    const filter_label_name_not = parsed.label_name_not;
    const filter_label_name_in = parsed.label_name_in;
    const filter_label_name_not_in = parsed.label_name_not_in;
    const filter_label_name_contains = parsed.label_name_contains;
    const filter_label_name_contains_nocase = parsed.label_name_contains_nocase;
    const filter_label_name_not_contains = parsed.label_name_not_contains;
    const filter_label_name_starts_with = parsed.label_name_starts_with;
    const filter_label_name_starts_with_nocase = parsed.label_name_starts_with_nocase;
    const filter_label_name_ends_with = parsed.label_name_ends_with;
    const filter_label_name_ends_with_nocase = parsed.label_name_ends_with_nocase;
    const filter_resolved_address = parsed.resolved_address;
    const filter_resolver = parsed.resolver;
    const filter_has_subdomains = parsed.has_subdomains;
    const filter_subdomain_count_gt = parsed.subdomain_count_gt;
    const filter_subdomain_count_lt = parsed.subdomain_count_lt;
    const filter_expiry_gt = parsed.expiry_gt;
    const filter_expiry_gte = parsed.expiry_gte;
    const filter_expiry_lt = parsed.expiry_lt;
    const filter_expiry_lte = parsed.expiry_lte;
    const filter_migrated = parsed.migrated;

    const include_unreachable = parsed.include_unreachable orelse false;
    const include_unnormalized = parsed.include_unnormalized orelse false;

    const name_filters = db.NameFilters{
        .owner = filter_owner,
        .owner_in = filter_owner_in,
        .owner_not = filter_owner_not,
        .owner_not_in = filter_owner_not_in,
        .name = filter_name,
        .name_in = filter_name_in,
        .name_not = filter_name_not,
        .name_not_in = filter_name_not_in,
        .name_contains = filter_name_contains,
        .name_contains_nocase = filter_name_contains_nocase,
        .name_not_contains = filter_name_not_contains,
        .name_starts_with = filter_name_starts_with,
        .name_starts_with_nocase = filter_name_starts_with_nocase,
        .name_ends_with = filter_name_ends_with,
        .name_ends_with_nocase = filter_name_ends_with_nocase,
        .label_name = filter_label_name,
        .label_name_not = filter_label_name_not,
        .label_name_in = filter_label_name_in,
        .label_name_not_in = filter_label_name_not_in,
        .label_name_contains = filter_label_name_contains,
        .label_name_contains_nocase = filter_label_name_contains_nocase,
        .label_name_not_contains = filter_label_name_not_contains,
        .label_name_starts_with = filter_label_name_starts_with,
        .label_name_starts_with_nocase = filter_label_name_starts_with_nocase,
        .label_name_ends_with = filter_label_name_ends_with,
        .label_name_ends_with_nocase = filter_label_name_ends_with_nocase,
        .expiry_gt = filter_expiry_gt,
        .expiry_gte = filter_expiry_gte,
        .expiry_lt = filter_expiry_lt,
        .expiry_lte = filter_expiry_lte,
        .resolved_address = filter_resolved_address,
        .resolver = filter_resolver,
        .migrated = filter_migrated,
        .has_subdomains = filter_has_subdomains,
        .subdomain_count_gt = filter_subdomain_count_gt,
        .subdomain_count_lt = filter_subdomain_count_lt,
        .include_unreachable = include_unreachable,
        .include_unnormalized = include_unnormalized,
        .is_normalized = parsed.is_normalized,
        .and_group = try mapFilterGroup(parsed.and_filters, allocator),
        .or_group = try mapFilterGroup(parsed.or_filters, allocator),
    };

    const has_filters = filter_name != null or filter_name_in != null or
        filter_name_not != null or filter_name_not_in != null or
        filter_name_contains != null or filter_name_contains_nocase != null or
        filter_name_not_contains != null or
        filter_name_starts_with != null or filter_name_starts_with_nocase != null or
        filter_name_ends_with != null or filter_name_ends_with_nocase != null or
        filter_label_name != null or filter_label_name_not != null or
        filter_label_name_in != null or filter_label_name_not_in != null or
        filter_label_name_contains != null or filter_label_name_contains_nocase != null or
        filter_label_name_not_contains != null or
        filter_label_name_starts_with != null or filter_label_name_starts_with_nocase != null or
        filter_label_name_ends_with != null or filter_label_name_ends_with_nocase != null or
        filter_owner != null or filter_owner_in != null or
        filter_owner_not != null or filter_owner_not_in != null or
        filter_resolved_address != null or filter_resolver != null or filter_has_subdomains != null or
        filter_subdomain_count_gt != null or filter_subdomain_count_lt != null or
        filter_expiry_gt != null or filter_expiry_gte != null or
        filter_expiry_lt != null or filter_expiry_lte != null or
        filter_migrated != null or include_unreachable or
        include_unnormalized or parsed.is_normalized != null or
        parsed.and_filters != null or parsed.or_filters != null;

    // Check which top-level fields are requested
    var wants_edges = false;
    var wants_page_info = false;
    var wants_total_count = false;
    for (field.selections) |*sel| {
        if (std.mem.eql(u8, sel.name, "edges")) wants_edges = true;
        if (std.mem.eql(u8, sel.name, "pageInfo")) wants_page_info = true;
        if (std.mem.eql(u8, sel.name, "totalCount")) wants_total_count = true;
    }

    // Fast path: only totalCount requested — skip row fetching entirely
    if (wants_total_count and !wants_edges and !wants_page_info) {
        const count = try database.getFilteredNameCount(name_filters);
        const result = try std.fmt.allocPrint(allocator, "{{\"totalCount\":{d}}}", .{count});
        return parser.FieldResult{ .json = result };
    }

    // Extract node selections from query: domainConnection { edges { node { ... } } }
    var node_selections: []const parser.Field = &[_]parser.Field{};
    for (field.selections) |*sel| {
        if (std.mem.eql(u8, sel.name, "edges")) {
            for (sel.selections) |*edge_sel| {
                if (std.mem.eql(u8, edge_sel.name, "node")) {
                    node_selections = edge_sel.selections;
                    break;
                }
            }
            break;
        }
    }

    const order_by = parser.getStringArg(field, "orderBy", null);
    const sort_field = mapDomainOrderBy(order_by);

    // Default order: desc (newest first) when no orderDirection specified
    const base_dir = common.parseOrderDirection(field, db.OrderDir, .desc);

    // Fetch one extra item to determine hasNextPage/hasPreviousPage
    const fetch_limit = params.limit + 1;

    // Combine pagination direction with user-requested order
    const order_dir: db.OrderDir = if (params.direction == .backward)
        (if (base_dir == .desc) .asc else .desc)
    else
        base_dir;

    // Convert the cursor (encoded namehash) into a SKIP offset for the SQL query.
    // The cursor points to the last item the client already saw; we skip everything up
    // to and including it. This uses countRowsBeforeNamehash which does a (sort_field, namehash)
    // stable comparison to get the count of rows that sort BEFORE the cursor row, then +1 to
    // skip the cursor row itself.
    //
    // The same filters must be passed in — otherwise the offset is taken over the unfiltered
    // superset and pagination skips too many rows (e.g. with isMigrated:true ~343 rows would
    // be lost across pages because non-migrated rows still counted toward the offset).
    var skip: u32 = 0;
    if (params.cursor) |c| {
        const cursor_namehash = try pagination.CursorCodec.decodeString(allocator, c);
        defer allocator.free(cursor_namehash);
        const rows_before = database.countRowsBeforeNamehash(cursor_namehash, sort_field, order_dir, name_filters) catch 0;
        skip = rows_before +| 1; // +1 to skip past the cursor row itself
    }

    const names = if (has_filters)
        try database.getFilteredNames(name_filters, skip, @intCast(fetch_limit), order_dir, sort_field)
    else
        try database.getAllNamesWithOrder(null, skip, @intCast(fetch_limit), order_dir, sort_field);
    defer {
        for (names) |*name| {
            name.deinit(allocator);
        }
        allocator.free(names);
    }

    // We fetched `params.limit + 1` to detect a trailing page; if we actually got
    // more than `limit`, there's more data in the pagination direction.
    const has_more = names.len > params.limit;
    const actual_items = @min(names.len, params.limit);

    // For backward pagination, reverse the results to maintain proper edge order
    if (params.direction == .backward and actual_items > 1) {
        std.mem.reverse(models.Name, names[0..actual_items]);
    }

    const items_slice = names[0..actual_items];

    // Build connection using pagination module
    const NameWithSelections = struct {
        name: *models.Name,
        selections: []const parser.Field,
        ctx: NestedContext,
        hex_id: []const u8,
    };

    // Helper to get hex ID
    const getId = struct {
        fn call(item: NameWithSelections) []const u8 {
            return item.hex_id;
        }
    }.call;

    // Create wrapper items with hex IDs
    var wrapper_items = try allocator.alloc(NameWithSelections, items_slice.len);
    defer {
        for (wrapper_items) |item| {
            allocator.free(item.hex_id);
        }
        allocator.free(wrapper_items);
    }

    for (items_slice, 0..) |*name, i| {
        const hex_id = try name.namehash.toHex(allocator);
        wrapper_items[i] = NameWithSelections{
            .name = name,
            .selections = node_selections,
            .ctx = .{
                .database = database,
                .depth = 0,
                .allocator = allocator,
                .loaders = ctx.loaders,
            },
            .hex_id = hex_id,
        };
    }

    // Compute total count if requested (wants_total_count determined above)
    const total_count: ?usize = if (wants_total_count)
        try database.getFilteredNameCount(name_filters)
    else
        null;

    // Build connection
    const connection = try pagination.buildConnectionString(
        NameWithSelections,
        allocator,
        wrapper_items,
        params,
        has_more,
        getId,
        total_count,
    );
    defer connection.deinit(allocator);

    // Build JSON from connection
    var json: std.ArrayList(u8) = .{};
    defer json.deinit(allocator);

    try json.appendSlice(allocator, "{\"pageInfo\":{");
    try json.appendSlice(allocator, "\"hasNextPage\":");
    try json.appendSlice(allocator, if (connection.page_info.has_next_page) "true" else "false");
    try json.appendSlice(allocator, ",\"hasPreviousPage\":");
    try json.appendSlice(allocator, if (connection.page_info.has_previous_page) "true" else "false");

    if (connection.page_info.start_cursor) |cursor| {
        try json.appendSlice(allocator, ",\"startCursor\":\"");
        try json.appendSlice(allocator, cursor);
        try json.appendSlice(allocator, "\"");
    } else {
        try json.appendSlice(allocator, ",\"startCursor\":null");
    }

    if (connection.page_info.end_cursor) |cursor| {
        try json.appendSlice(allocator, ",\"endCursor\":\"");
        try json.appendSlice(allocator, cursor);
        try json.appendSlice(allocator, "\"");
    } else {
        try json.appendSlice(allocator, ",\"endCursor\":null");
    }

    try json.appendSlice(allocator, "},\"edges\":[");

    // Build edges
    for (connection.edges, 0..) |edge, i| {
        if (i > 0) try json.appendSlice(allocator, ",");

        try json.appendSlice(allocator, "{\"cursor\":\"");
        try json.appendSlice(allocator, edge.cursor);
        try json.appendSlice(allocator, "\",\"node\":");

        // Build domain JSON for the node
        const domain_json = try builders.buildDomainJson(edge.node.name, edge.node.selections, edge.node.ctx);
        defer allocator.free(domain_json);
        try json.appendSlice(allocator, domain_json);

        try json.appendSlice(allocator, "}");
    }

    try json.appendSlice(allocator, "]");

    // Add totalCount if available
    if (connection.total_count) |count| {
        try json.appendSlice(allocator, ",\"totalCount\":");
        const count_str = try std.fmt.allocPrint(allocator, "{d}", .{count});
        defer allocator.free(count_str);
        try json.appendSlice(allocator, count_str);
    }

    try json.appendSlice(allocator, "}");

    const result_json = try allocator.dupe(u8, json.items);
    return parser.FieldResult{ .json = result_json };
}

pub fn resolveDomain(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));
    const allocator = ctx.allocator;

    // Extract id argument
    const id = parser.getStringArg(field, "id", null) orelse {
        const null_json = try allocator.dupe(u8, "null");
        return parser.FieldResult{ .json = null_json };
    };

    // Get name from database — id may be either a name or a namehash hex string
    const nh = try resolveDomainId(allocator, id);
    const name_opt = try database.getNameByNamehash(nh);
    if (name_opt == null) {
        const null_json = try allocator.dupe(u8, "null");
        return parser.FieldResult{ .json = null_json };
    }
    var name = name_opt.?;
    defer name.deinit(allocator);

    // Hide unreachable domains from default lookup. There's currently no
    // `includeUnreachable` arg on the singular `domain(id:)` query; clients
    // that need orphan visibility should use `domains(where:{includeUnreachable:true})`.
    if (!name.is_reachable) {
        const null_json = try allocator.dupe(u8, "null");
        return parser.FieldResult{ .json = null_json };
    }

    // Build JSON object using nested builder
    const name_json = try builders.buildDomainJson(&name, field.selections, .{
        .database = database,
        .depth = 0,
        .allocator = allocator,
        .loaders = ctx.loaders,
    });
    return parser.FieldResult{ .json = name_json };
}
