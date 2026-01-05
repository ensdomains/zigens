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
const builders = common.builders;
const loaders = common.loaders;
const namehash = common.namehash_fn;
const NestedContext = common.NestedContext;

pub fn resolveDomains(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));
    const allocator = ctx.allocator;

    // Extract arguments
    const first = parser.getIntArg(field, "first", 100) orelse 100;
    const skip = parser.getIntArg(field, "skip", 0) orelse 0;

    // Parse filter if provided
    var filter_name: ?[]const u8 = null;
    var filter_name_contains: ?[]const u8 = null;
    var filter_name_contains_nocase: ?[]const u8 = null;
    var filter_name_starts_with: ?[]const u8 = null;
    var filter_name_ends_with: ?[]const u8 = null;
    var filter_owner: ?Address = null;
    var filter_owner_in: ?[]Address = null;
    var filter_resolved_address: ?Address = null;
    var filter_has_subdomains: ?bool = null;
    var filter_subdomain_count_gt: ?i64 = null;
    var filter_subdomain_count_lt: ?i64 = null;

    // Look for "where" argument
    for (field.arguments) |arg| {
        if (std.mem.eql(u8, arg.name, "where")) {
            if (arg.value == .object) {
                for (arg.value.object) |filter_arg| {
                    if (std.mem.eql(u8, filter_arg.name, "name")) {
                        if (filter_arg.value == .string) {
                            filter_name = filter_arg.value.string;
                        }
                    } else if (std.mem.eql(u8, filter_arg.name, "name_contains")) {
                        if (filter_arg.value == .string) {
                            filter_name_contains = filter_arg.value.string;
                        }
                    } else if (std.mem.eql(u8, filter_arg.name, "owner")) {
                        if (filter_arg.value == .string) {
                            filter_owner = Address.fromHex(filter_arg.value.string) catch null;
                        }
                    } else if (std.mem.eql(u8, filter_arg.name, "resolvedAddress")) {
                        if (filter_arg.value == .string) {
                            filter_resolved_address = Address.fromHex(filter_arg.value.string) catch null;
                        }
                    } else if (std.mem.eql(u8, filter_arg.name, "name_contains_nocase")) {
                        if (filter_arg.value == .string) {
                            filter_name_contains_nocase = filter_arg.value.string;
                        }
                    } else if (std.mem.eql(u8, filter_arg.name, "name_starts_with")) {
                        if (filter_arg.value == .string) {
                            filter_name_starts_with = filter_arg.value.string;
                        }
                    } else if (std.mem.eql(u8, filter_arg.name, "name_ends_with")) {
                        if (filter_arg.value == .string) {
                            filter_name_ends_with = filter_arg.value.string;
                        }
                    } else if (std.mem.eql(u8, filter_arg.name, "owner_in")) {
                        if (filter_arg.value == .list) {
                            var addresses: std.ArrayList(Address) = .{};
                            defer addresses.deinit(allocator);
                            for (filter_arg.value.list) |item| {
                                if (item == .string) {
                                    if (Address.fromHex(item.string)) |addr| {
                                        try addresses.append(allocator, addr);
                                    } else |_| {}
                                }
                            }
                            filter_owner_in = try addresses.toOwnedSlice(allocator);
                        }
                    } else if (std.mem.eql(u8, filter_arg.name, "hasSubdomains")) {
                        if (filter_arg.value == .boolean) {
                            filter_has_subdomains = filter_arg.value.boolean;
                        }
                    } else if (std.mem.eql(u8, filter_arg.name, "subdomainCount_gt")) {
                        if (filter_arg.value == .int) {
                            filter_subdomain_count_gt = filter_arg.value.int;
                        }
                    } else if (std.mem.eql(u8, filter_arg.name, "subdomainCount_lt")) {
                        if (filter_arg.value == .int) {
                            filter_subdomain_count_lt = filter_arg.value.int;
                        }
                    }
                }
            }
            break;
        }
    }

    // Parse orderBy and orderDirection
    var order_by: ?[]const u8 = null;
    var order_direction: []const u8 = "asc"; // default

    for (field.arguments) |arg| {
        if (std.mem.eql(u8, arg.name, "orderBy")) {
            if (arg.value == .string) {
                order_by = arg.value.string;
            }
        } else if (std.mem.eql(u8, arg.name, "orderDirection")) {
            if (arg.value == .string) {
                order_direction = arg.value.string;
            }
        }
    }

    // Get names from database
    // Optimization 1: if exact name filter is set, use direct lookup by namehash
    // This is O(1) lookup instead of scanning/filtering
    if (filter_name) |exact_name| {
        // Compute namehash for exact lookup
        const nh = try namehash(allocator, exact_name);

        // Direct lookup by namehash
        var found_name = try database.getNameByNamehash(nh);
        if (found_name) |*name| {
            defer name.deinit(allocator);

            // Apply any additional filters (owner, etc.)
            var matches = true;
            if (filter_owner) |owner| {
                if (!name.owner.eql(owner)) matches = false;
            }

            if (matches) {
                // Build JSON result for single domain, wrapped in array
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
        }

        // No match found - return empty array
        return .{ .json = try allocator.dupe(u8, "[]") };
    }

    // Optimization 2: if owner filter is set, always push it to DB
    // This uses the idx_names_owner index instead of scanning all rows
    // Other filters (name_contains_nocase, etc.) are applied in-memory after DB fetch
    const has_other_filters = filter_name_contains != null or
        filter_name_contains_nocase != null or filter_name_starts_with != null or
        filter_name_ends_with != null or filter_owner_in != null or
        filter_resolved_address != null or filter_has_subdomains != null or
        filter_subdomain_count_gt != null or filter_subdomain_count_lt != null;

    // Always pass owner filter to DB if present - it uses an index and narrows results
    const db_owner_filter = filter_owner;

    const fetch_limit = if (has_other_filters)
        @min(first * 10, 1000) // Fetch more if we need additional in-memory filtering
    else
        first;
    const names = try database.getAllNames(db_owner_filter, @intCast(skip), @intCast(fetch_limit));
    defer {
        for (names) |*name| {
            name.deinit(allocator);
        }
        allocator.free(names);
    }

    // Batch-load resolver addresses if needed for filtering (eliminates N+1 query)
    var resolver_addresses: ?std.AutoHashMap([32]u8, ?[]const u8) = null;
    defer {
        if (resolver_addresses) |*addrs| {
            var it = addrs.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.*) |addr| {
                    allocator.free(addr);
                }
            }
            addrs.deinit();
        }
    }

    if (filter_resolved_address != null) {
        // Use DataLoader to batch-load all resolver addresses in one query
        const dataloader_mod = loaders;
        if (ctx.loaders) |loaders_ptr| {
            const loader_ctx: *dataloader_mod.LoaderContext = @ptrCast(@alignCast(loaders_ptr));
            const loader = try loader_ctx.getResolverAddressLoader();

            // Collect all namehashes
            var namehashes = try allocator.alloc([32]u8, names.len);
            defer allocator.free(namehashes);
            for (names, 0..) |name, i| {
                namehashes[i] = name.namehash.bytes;
            }

            // Batch load all addresses in one query!
            const addresses = try loader.loadMany(namehashes);
            defer allocator.free(addresses);

            // Build lookup map
            resolver_addresses = std.AutoHashMap([32]u8, ?[]const u8).init(allocator);
            for (namehashes, addresses) |hash, addr| {
                try resolver_addresses.?.put(hash, addr);
            }
        }
    }

    // First pass: collect filtered names
    var filtered_names: std.ArrayList(*models.Name) = .{};
    defer filtered_names.deinit(allocator);

    for (names) |*name| {
        // Apply filters
        var matches = true;

        if (filter_name) |fname| {
            if (!std.mem.eql(u8, name.name orelse "[unknown]", fname)) matches = false;
        }

        if (matches and filter_name_contains != null) {
            if (std.mem.indexOf(u8, name.name orelse "[unknown]", filter_name_contains.?) == null) matches = false;
        }

        if (matches and filter_owner != null) {
            if (!name.owner.eql(filter_owner.?)) matches = false;
        }

        if (matches and filter_resolved_address != null) {
            // Use pre-loaded resolver addresses (no database query in loop!)
            if (resolver_addresses) |*addrs| {
                const addr_opt = addrs.get(name.namehash.bytes);
                if (addr_opt) |addr| {
                    if (addr) |addr_str| {
                        const resolved_addr = Address.fromHex(addr_str) catch {
                            matches = false;
                            continue;
                        };
                        if (!resolved_addr.eql(filter_resolved_address.?)) matches = false;
                    } else {
                        matches = false;
                    }
                } else {
                    matches = false;
                }
            } else {
                // Fallback to direct database query if loaders not available
                const addr_opt = try database.getResolverAddress(name.namehash, 60);
                if (addr_opt) |addr| {
                    defer allocator.free(addr);
                    const resolved_addr = Address.fromHex(addr) catch {
                        matches = false;
                        continue;
                    };
                    if (!resolved_addr.eql(filter_resolved_address.?)) matches = false;
                } else {
                    matches = false;
                }
            }
        }

        if (matches and filter_name_contains_nocase != null) {
            // Case-insensitive contains
            const lower_name = try std.ascii.allocLowerString(allocator, name.name orelse "[unknown]");
            defer allocator.free(lower_name);
            const lower_filter = try std.ascii.allocLowerString(allocator, filter_name_contains_nocase.?);
            defer allocator.free(lower_filter);
            if (std.mem.indexOf(u8, lower_name, lower_filter) == null) matches = false;
        }

        if (matches and filter_name_starts_with != null) {
            if (!std.mem.startsWith(u8, name.name orelse "[unknown]", filter_name_starts_with.?)) matches = false;
        }

        if (matches and filter_name_ends_with != null) {
            if (!std.mem.endsWith(u8, name.name orelse "[unknown]", filter_name_ends_with.?)) matches = false;
        }

        if (matches and filter_owner_in != null) {
            var found = false;
            for (filter_owner_in.?) |addr| {
                if (name.owner.eql(addr)) {
                    found = true;
                    break;
                }
            }
            if (!found) matches = false;
        }

        // Filter by hasSubdomains - only counts direct children (one level down)
        if (matches and filter_has_subdomains != null) {
            if (name.name) |domain_name| {
                const has_subs = try database.hasDirectSubdomains(domain_name);
                if (filter_has_subdomains.? != has_subs) matches = false;
            } else {
                // Domain without a name can't have subdomains checked
                if (filter_has_subdomains.?) matches = false;
            }
        }

        // Filter by subdomainCount_gt - only counts direct children (one level down)
        if (matches and filter_subdomain_count_gt != null) {
            if (name.name) |domain_name| {
                const subdomain_count = try database.countDirectSubdomains(domain_name);
                if (subdomain_count <= @as(u32, @intCast(filter_subdomain_count_gt.?))) matches = false;
            } else {
                // Domain without a name has 0 subdomains
                matches = false;
            }
        }

        // Filter by subdomainCount_lt - only counts direct children (one level down)
        if (matches and filter_subdomain_count_lt != null) {
            if (name.name) |domain_name| {
                const subdomain_count = try database.countDirectSubdomains(domain_name);
                if (subdomain_count >= @as(u32, @intCast(filter_subdomain_count_lt.?))) matches = false;
            } else {
                // Domain without a name has 0 subdomains - always passes lt filter unless lt=0
                if (filter_subdomain_count_lt.? <= 0) matches = false;
            }
        }

        if (matches) {
            try filtered_names.append(allocator, name);
        }
    }

    // Sort filtered names if orderBy is specified
    if (order_by) |field_name| {
        const ascending = std.mem.eql(u8, order_direction, "asc");
        const SortContext = struct {
            field: []const u8,
            asc: bool,
        };
        const sort_ctx = SortContext{ .field = field_name, .asc = ascending };

        std.mem.sort(*models.Name, filtered_names.items, sort_ctx, struct {
            fn lessThan(sort_ctx_param: SortContext, a: *models.Name, b: *models.Name) bool {
                if (std.mem.eql(u8, sort_ctx_param.field, "name")) {
                    const cmp = std.mem.order(u8, a.name orelse "[unknown]", b.name orelse "[unknown]");
                    return if (sort_ctx_param.asc) cmp == .lt else cmp == .gt;
                } else if (std.mem.eql(u8, sort_ctx_param.field, "createdAt") or
                    std.mem.eql(u8, sort_ctx_param.field, "registrationDate"))
                {
                    // registrationDate is an alias for createdAt
                    return if (sort_ctx_param.asc) a.created_at < b.created_at else a.created_at > b.created_at;
                } else if (std.mem.eql(u8, sort_ctx_param.field, "expiryDate")) {
                    // Sort by expiry timestamp
                    return if (sort_ctx_param.asc) a.expiry < b.expiry else a.expiry > b.expiry;
                } else if (std.mem.eql(u8, sort_ctx_param.field, "id")) {
                    const cmp = std.mem.order(u8, &a.namehash.bytes, &b.namehash.bytes);
                    return if (sort_ctx_param.asc) cmp == .lt else cmp == .gt;
                }
                // Default: no sorting
                return false;
            }
        }.lessThan);
    }

    // Build JSON from sorted/filtered names
    var json: std.ArrayList(u8) = .{};
    defer json.deinit(allocator);

    try json.appendSlice(allocator, "[");
    const items_to_return = @min(first, filtered_names.items.len);

    // Pre-load resolver data for all domains to enable batching (solves N+1 query problem)
    // Check if resolver fields that need data loading are requested
    if (ctx.loaders != null and items_to_return > 0) {
        const dataloader_mod = loaders;
        var needs_resolver_addr = false;
        var needs_content_hash = false;
        var needs_text_records = false;
        var needs_resolved_address = false;

        // Check field selections for resolver sub-fields
        for (field.selections) |sel| {
            if (std.mem.eql(u8, sel.name, "resolver")) {
                for (sel.selections) |resolver_sel| {
                    if (std.mem.eql(u8, resolver_sel.name, "addr")) {
                        needs_resolver_addr = true;
                    } else if (std.mem.eql(u8, resolver_sel.name, "contentHash")) {
                        needs_content_hash = true;
                    } else if (std.mem.eql(u8, resolver_sel.name, "texts") or
                        std.mem.eql(u8, resolver_sel.name, "text"))
                    {
                        needs_text_records = true;
                    }
                }
            } else if (std.mem.eql(u8, sel.name, "resolvedAddress")) {
                needs_resolved_address = true;
            }
        }

        // Collect namehashes for items that will be returned
        if (needs_resolver_addr or needs_content_hash or needs_text_records or needs_resolved_address) {
            const loader_ctx: *dataloader_mod.LoaderContext = @ptrCast(@alignCast(ctx.loaders.?));
            const return_items = filtered_names.items[0..@as(usize, @intCast(items_to_return))];

            var namehashes = try allocator.alloc([32]u8, return_items.len);
            defer allocator.free(namehashes);

            for (return_items, 0..) |name, idx| {
                namehashes[idx] = name.namehash.bytes;
            }

            // Pre-load resolver addresses (for addr field and resolvedAddress)
            if (needs_resolver_addr or needs_resolved_address) {
                const loader = try loader_ctx.getResolverAddressLoader();
                const preloaded = try loader.loadMany(namehashes);
                allocator.free(preloaded);
            }

            // Pre-load content hashes
            if (needs_content_hash) {
                const loader = try loader_ctx.getContentHashLoader();
                const preloaded = try loader.loadMany(namehashes);
                allocator.free(preloaded);
            }

            // Pre-load text records
            if (needs_text_records) {
                const loader = try loader_ctx.getTextRecordsLoader();
                const preloaded = try loader.loadMany(namehashes);
                allocator.free(preloaded);
            }
        }
    }

    for (filtered_names.items[0..@as(usize, @intCast(items_to_return))], 0..) |name, i| {
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

    // For now, use offset-based queries (can be optimized to true cursor-based queries later)
    const skip: u32 = 0;

    // Fetch one extra item to determine hasNextPage/hasPreviousPage
    const fetch_limit = params.limit + 1;

    // For backward pagination (last/before), reverse the query order
    // This ensures we get the "last N items" from the end of the result set
    const order_dir: db.OrderDir = if (params.direction == .backward) .asc else .desc;
    const names = try database.getAllNamesWithOrder(null, skip, @intCast(fetch_limit), order_dir);
    defer {
        for (names) |*name| {
            name.deinit(allocator);
        }
        allocator.free(names);
    }

    // Determine actual items to return (exclude the extra item)
    const actual_items = @min(names.len, params.limit);

    // For backward pagination, reverse the results to maintain proper edge order
    // (Query returned oldest-first, but we want newest-first in the edges)
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
        // Format namehash as hex string using Hash.toHex()
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

    // Build connection
    const connection = try pagination.buildConnectionString(
        NameWithSelections,
        allocator,
        wrapper_items,
        params,
        getId,
        null, // total_count - can be added later
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

    // Get name from database
    const nh = try namehash(allocator, id);
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
