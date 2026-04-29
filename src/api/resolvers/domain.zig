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

fn mapDomainOrderBy(order_by: ?[]const u8) db.NameSortField {
    const field_name = order_by orelse return .created_at;
    if (std.mem.eql(u8, field_name, "name")) return .name;
    if (std.mem.eql(u8, field_name, "createdAt")) return .created_at;
    if (std.mem.eql(u8, field_name, "expiryDate")) return .expiry;
    if (std.mem.eql(u8, field_name, "registrationDate")) return .registered_at;
    return .created_at;
}

pub fn resolveDomains(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));
    const allocator = ctx.allocator;

    const page = try common.parsePagination(field, 100);
    const first = page.first;
    const skip = page.skip;

    // Parse `where` filter
    var filter_name: ?[]const u8 = null;
    var filter_name_contains: ?[]const u8 = null;
    var filter_name_contains_nocase: ?[]const u8 = null;
    var filter_name_starts_with: ?[]const u8 = null;
    var filter_name_ends_with: ?[]const u8 = null;
    var filter_owner: ?Address = null;
    var filter_owner_in: ?[]Address = null;
    var filter_resolved_address: ?Address = null;
    var filter_resolver: ?Address = null;
    var filter_has_subdomains: ?bool = null;
    var filter_subdomain_count_gt: ?i64 = null;
    var filter_subdomain_count_lt: ?i64 = null;
    var filter_expiry_gt: ?i64 = null;
    var filter_expiry_gte: ?i64 = null;
    var filter_expiry_lt: ?i64 = null;
    var filter_expiry_lte: ?i64 = null;
    var filter_migrated: ?bool = null;

    if (common.getObjectArg(field, "where")) |where_args| {
        for (where_args) |a| {
            // owner_in: list-of-Address — handled inline because it allocates.
            if (std.mem.eql(u8, a.name, "owner_in") and a.value == .list) {
                var addresses: std.ArrayList(Address) = .{};
                defer addresses.deinit(allocator);
                for (a.value.list) |item| {
                    if (item == .string) {
                        const addr = Address.fromHex(item.string) catch return error.InvalidAddress;
                        try addresses.append(allocator, addr);
                    }
                }
                filter_owner_in = try addresses.toOwnedSlice(allocator);
                continue;
            }

            _ = common.matchStringArg(a, "name", &filter_name) or
                common.matchStringArg(a, "name_contains", &filter_name_contains) or
                common.matchStringArg(a, "name_contains_nocase", &filter_name_contains_nocase) or
                common.matchStringArg(a, "name_starts_with", &filter_name_starts_with) or
                common.matchStringArg(a, "name_ends_with", &filter_name_ends_with) or
                (try common.matchAddressArg(a, "owner", &filter_owner)) or
                (try common.matchAddressArg(a, "resolvedAddress", &filter_resolved_address)) or
                (try common.matchAddressArg(a, "resolver", &filter_resolver)) or
                common.matchBoolArg(a, "hasSubdomains", &filter_has_subdomains) or
                common.matchIntArg(a, "subdomainCount_gt", &filter_subdomain_count_gt) or
                common.matchIntArg(a, "subdomainCount_lt", &filter_subdomain_count_lt) or
                common.matchIntArg(a, "expiry_gt", &filter_expiry_gt) or
                common.matchIntArg(a, "expiry_gte", &filter_expiry_gte) or
                common.matchIntArg(a, "expiry_lt", &filter_expiry_lt) or
                common.matchIntArg(a, "expiry_lte", &filter_expiry_lte) or
                common.matchBoolArg(a, "isMigrated", &filter_migrated);
        }
    }

    const order_by = parser.getStringArg(field, "orderBy", null);
    const order_dir_parsed = common.parseOrderDirection(field, db.OrderDir, .desc);

    // Get names from database
    // Optimization: if ONLY name filter is set (no other filters), use direct namehash lookup (O(1))
    // If additional filters are present, fall through to getFilteredNames so all filters apply correctly
    const only_name_filter = filter_name != null and
        filter_owner == null and filter_owner_in == null and
        filter_name_contains == null and filter_name_contains_nocase == null and
        filter_name_starts_with == null and filter_name_ends_with == null and
        filter_resolved_address == null and filter_resolver == null and
        filter_has_subdomains == null and
        filter_subdomain_count_gt == null and filter_subdomain_count_lt == null and
        filter_expiry_gt == null and filter_expiry_gte == null and
        filter_expiry_lt == null and filter_expiry_lte == null and
        filter_migrated == null;

    if (only_name_filter) {
        const exact_name = filter_name.?;
        const nh = try namehash(allocator, exact_name);

        var found_name = try database.getNameByNamehash(nh);
        if (found_name) |*name| {
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
    const has_filters = filter_name != null or filter_name_contains != null or
        filter_name_contains_nocase != null or filter_name_starts_with != null or
        filter_name_ends_with != null or filter_owner != null or filter_owner_in != null or
        filter_resolved_address != null or filter_resolver != null or filter_has_subdomains != null or
        filter_subdomain_count_gt != null or filter_subdomain_count_lt != null or
        filter_expiry_gt != null or filter_expiry_gte != null or
        filter_expiry_lt != null or filter_expiry_lte != null or
        filter_migrated != null;

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
            .name = filter_name,
            .name_contains = filter_name_contains,
            .name_contains_nocase = filter_name_contains_nocase,
            .name_starts_with = filter_name_starts_with,
            .name_ends_with = filter_name_ends_with,
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

    // Parse where filters
    var filter_owner: ?Address = null;
    var filter_owner_in: ?[]Address = null;
    var filter_name: ?[]const u8 = null;
    var filter_name_contains: ?[]const u8 = null;
    var filter_name_contains_nocase: ?[]const u8 = null;
    var filter_name_starts_with: ?[]const u8 = null;
    var filter_name_ends_with: ?[]const u8 = null;
    var filter_resolved_address: ?Address = null;
    var filter_resolver: ?Address = null;
    var filter_has_subdomains: ?bool = null;
    var filter_subdomain_count_gt: ?i64 = null;
    var filter_subdomain_count_lt: ?i64 = null;
    var filter_expiry_gt: ?i64 = null;
    var filter_expiry_gte: ?i64 = null;
    var filter_expiry_lt: ?i64 = null;
    var filter_expiry_lte: ?i64 = null;
    var filter_migrated: ?bool = null;

    if (common.getObjectArg(field, "where")) |where_args| {
        for (where_args) |a| {
            if (std.mem.eql(u8, a.name, "owner_in") and a.value == .list) {
                var addresses: std.ArrayList(Address) = .{};
                defer addresses.deinit(allocator);
                for (a.value.list) |item| {
                    if (item == .string) {
                        const addr = Address.fromHex(item.string) catch return error.InvalidAddress;
                        try addresses.append(allocator, addr);
                    }
                }
                filter_owner_in = try addresses.toOwnedSlice(allocator);
                continue;
            }

            _ = common.matchStringArg(a, "name", &filter_name) or
                common.matchStringArg(a, "name_contains", &filter_name_contains) or
                common.matchStringArg(a, "name_contains_nocase", &filter_name_contains_nocase) or
                common.matchStringArg(a, "name_starts_with", &filter_name_starts_with) or
                common.matchStringArg(a, "name_ends_with", &filter_name_ends_with) or
                (try common.matchAddressArg(a, "owner", &filter_owner)) or
                (try common.matchAddressArg(a, "resolvedAddress", &filter_resolved_address)) or
                (try common.matchAddressArg(a, "resolver", &filter_resolver)) or
                common.matchBoolArg(a, "hasSubdomains", &filter_has_subdomains) or
                common.matchIntArg(a, "subdomainCount_gt", &filter_subdomain_count_gt) or
                common.matchIntArg(a, "subdomainCount_lt", &filter_subdomain_count_lt) or
                common.matchIntArg(a, "expiry_gt", &filter_expiry_gt) or
                common.matchIntArg(a, "expiry_gte", &filter_expiry_gte) or
                common.matchIntArg(a, "expiry_lt", &filter_expiry_lt) or
                common.matchIntArg(a, "expiry_lte", &filter_expiry_lte) or
                common.matchBoolArg(a, "isMigrated", &filter_migrated);
        }
    }
    defer if (filter_owner_in) |owners| allocator.free(owners);

    const name_filters = db.NameFilters{
        .owner = filter_owner,
        .owner_in = filter_owner_in,
        .name = filter_name,
        .name_contains = filter_name_contains,
        .name_contains_nocase = filter_name_contains_nocase,
        .name_starts_with = filter_name_starts_with,
        .name_ends_with = filter_name_ends_with,
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
    };

    const has_filters = filter_name != null or filter_name_contains != null or
        filter_name_contains_nocase != null or filter_name_starts_with != null or
        filter_name_ends_with != null or filter_owner != null or filter_owner_in != null or
        filter_resolved_address != null or filter_resolver != null or filter_has_subdomains != null or
        filter_subdomain_count_gt != null or filter_subdomain_count_lt != null or
        filter_expiry_gt != null or filter_expiry_gte != null or
        filter_expiry_lt != null or filter_expiry_lte != null or
        filter_migrated != null;

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

    // Build JSON object using nested builder
    const name_json = try builders.buildDomainJson(&name, field.selections, .{
        .database = database,
        .depth = 0,
        .allocator = allocator,
        .loaders = ctx.loaders,
    });
    return parser.FieldResult{ .json = name_json };
}
