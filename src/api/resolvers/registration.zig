/// Registration-related GraphQL resolvers
/// - resolveRegistrations: List registrations with filters
/// - resolveRegistrationConnection: Cursor-based pagination for registrations
const std = @import("std");
const common = @import("common.zig");
const db = common.db;
const models = common.models;
const Address = common.Address;
const parser = common.parser;
const pagination = common.pagination;
const builders = @import("../builders/builders.zig");
const loaders = common.loaders;
const NestedContext = builders.NestedContext;

fn mapRegistrationOrderBy(order_by: ?[]const u8) db.EventSortField {
    const field_name = order_by orelse return .block_number;
    if (std.mem.eql(u8, field_name, "registrationDate")) return .timestamp;
    if (std.mem.eql(u8, field_name, "name")) return .name;
    // expiryDate lives in JSON, can't sort in SQL — keep default
    if (std.mem.eql(u8, field_name, "expiryDate")) return .block_number;
    return .block_number;
}

/// Resolver for registrationConnection query (cursor-based pagination)
pub fn resolveRegistrationConnection(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
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
    var filter_registrant: ?[]const u8 = null;
    var filter_registrant_in: ?[][]const u8 = null;
    var filter_expiry_gt: ?i64 = null;
    var filter_expiry_gte: ?i64 = null;
    var filter_expiry_lt: ?i64 = null;
    var filter_expiry_lte: ?i64 = null;
    var filter_chain: ?models.Chain = null;

    if (common.getObjectArg(field, "where")) |where_args| {
        for (where_args) |a| {
            // chain: string → enum (special-cased)
            if (std.mem.eql(u8, a.name, "chain") and a.value == .string) {
                filter_chain = models.Chain.fromString(a.value.string) catch null;
                continue;
            }
            // registrant_in: list-of-string — allocates
            if (std.mem.eql(u8, a.name, "registrant_in") and a.value == .list) {
                var addresses: std.ArrayList([]const u8) = .{};
                defer addresses.deinit(allocator);
                for (a.value.list) |item| {
                    if (item == .string) {
                        try addresses.append(allocator, item.string);
                    }
                }
                filter_registrant_in = try addresses.toOwnedSlice(allocator);
                continue;
            }

            _ = common.matchStringArg(a, "registrant", &filter_registrant) or
                common.matchIntArg(a, "expiryDate_gt", &filter_expiry_gt) or
                common.matchIntArg(a, "expiryDate_gte", &filter_expiry_gte) or
                common.matchIntArg(a, "expiryDate_lt", &filter_expiry_lt) or
                common.matchIntArg(a, "expiryDate_lte", &filter_expiry_lte);
        }
    }
    defer if (filter_registrant_in) |regs| allocator.free(regs);

    // Build registration filter
    const reg_filter = db.RegistrationFilterOptions{
        .chain = filter_chain,
        .registrant = filter_registrant,
        .registrant_in = filter_registrant_in,
        .expiry_gt = filter_expiry_gt,
        .expiry_gte = filter_expiry_gte,
        .expiry_lt = filter_expiry_lt,
        .expiry_lte = filter_expiry_lte,
    };

    // Check which top-level fields are requested (for totalCount-only fast path)
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
        const count = try database.getRegistrationCount(reg_filter);
        const result = try std.fmt.allocPrint(allocator, "{{\"totalCount\":{d}}}", .{count});
        return parser.FieldResult{ .json = result };
    }

    // Extract node selections from query
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
    const sort_field = mapRegistrationOrderBy(order_by);

    // Default order: desc (newest first) when no orderDirection specified
    const base_dir = common.parseOrderDirection(field, db.EventOrderDir, .desc);

    // Fetch one extra item to determine hasNextPage/hasPreviousPage
    const fetch_limit = params.limit + 1;

    // Combine pagination direction with user-requested order
    const order_dir: db.EventOrderDir = if (params.direction == .backward)
        (if (base_dir == .desc) .asc else .desc)
    else
        base_dir;

    // Convert the cursor (tx_hash-log_index) into a SKIP offset, matching the pattern
    // used for domainConnection. Cursor refers to the last item already seen.
    var skip: u32 = 0;
    if (params.cursor) |c| {
        const decoded_opt = pagination.CursorCodec.decodeString(allocator, c) catch null;
        if (decoded_opt) |decoded| {
            defer allocator.free(decoded);
            // Cursor format is "<tx_hash_hex>-<log_index>"
            if (std.mem.lastIndexOfScalar(u8, decoded, '-')) |sep| {
                const tx_hash = decoded[0..sep];
                const log_index = std.fmt.parseInt(u32, decoded[sep + 1 ..], 10) catch 0;
                // Registrations only include NameRegistered + LabelRegistered events — count
                // must apply the same filter or the skip offset will be wildly off.
                const reg_types = [_][]const u8{
                    models.EventType.name_registered.toString(),
                    models.EventType.label_registered.toString(),
                };
                const events_before = database.countEventsBeforeCursor(tx_hash, log_index, order_dir, &reg_types) catch 0;
                skip = events_before +| 1; // +1 to skip past the cursor row itself
            }
        }
    }

    // Get registration events from database with filters applied at DB level
    var fetch_filter = reg_filter;
    fetch_filter.limit = @intCast(fetch_limit);
    fetch_filter.skip = skip;
    fetch_filter.order_dir = order_dir;
    fetch_filter.sort_field = sort_field;

    const events = try database.getRegistrations(fetch_filter);
    defer {
        for (events) |*event| {
            event.deinit(allocator);
        }
        allocator.free(events);
    }

    // We fetched `params.limit + 1` to detect a trailing page; if we actually got
    // more than `limit`, there's more data in the pagination direction.
    const has_more = events.len > params.limit;
    const actual_items = @min(events.len, params.limit);

    // For backward pagination, reverse the results to maintain proper edge order
    if (params.direction == .backward and actual_items > 1) {
        std.mem.reverse(models.Event, events[0..actual_items]);
    }

    const items_slice = events[0..actual_items];

    // Wrapper type for registrations
    const RegistrationWithSelections = struct {
        event: *models.Event,
        selections: []const parser.Field,
        ctx: NestedContext,
        id: []const u8,
    };

    // Helper to get ID
    const getId = struct {
        fn call(item: RegistrationWithSelections) []const u8 {
            return item.id;
        }
    }.call;

    // Create wrapper items with IDs
    var wrapper_items = try allocator.alloc(RegistrationWithSelections, items_slice.len);
    defer {
        for (wrapper_items) |item| {
            allocator.free(item.id);
        }
        allocator.free(wrapper_items);
    }

    for (items_slice, 0..) |*event, i| {
        const tx_hash = try event.tx_hash.toHex(allocator);
        defer allocator.free(tx_hash);
        const id = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ tx_hash, event.log_index });
        wrapper_items[i] = RegistrationWithSelections{
            .event = event,
            .selections = node_selections,
            .ctx = .{
                .database = database,
                .depth = 0,
                .allocator = allocator,
                .loaders = ctx.loaders,
            },
            .id = id,
        };
    }

    // Only compute total count when requested (reuse wants_total_count from earlier scan)
    const total_count: ?usize = if (wants_total_count)
        try database.getRegistrationCount(reg_filter)
    else
        null;

    // Build connection
    const connection = try pagination.buildConnectionString(
        RegistrationWithSelections,
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

        // Build registration JSON for the node
        const registration_json = try builders.buildRegistrationJson(edge.node.event, edge.node.selections, edge.node.ctx);
        defer allocator.free(registration_json);
        try json.appendSlice(allocator, registration_json);

        try json.appendSlice(allocator, "}");
    }

    try json.appendSlice(allocator, "]");

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

/// Resolver for eventConnection query (cursor-based pagination)
pub fn resolveRegistrations(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));
    const allocator = ctx.allocator;

    const page = common.parsePagination(field, 100);
    const first = page.first;
    const skip = page.skip;

    // Parse filter if provided
    var filter_registrant: ?[]const u8 = null;
    var filter_registrant_in: ?[][]const u8 = null;
    var filter_expiry_gt: ?i64 = null;
    var filter_expiry_gte: ?i64 = null;
    var filter_expiry_lt: ?i64 = null;
    var filter_expiry_lte: ?i64 = null;
    var filter_chain: ?models.Chain = null;

    if (common.getObjectArg(field, "where")) |where_args| {
        for (where_args) |a| {
            if (std.mem.eql(u8, a.name, "chain") and a.value == .string) {
                filter_chain = models.Chain.fromString(a.value.string) catch null;
                continue;
            }
            if (std.mem.eql(u8, a.name, "registrant_in") and a.value == .list) {
                var addresses: std.ArrayList([]const u8) = .{};
                defer addresses.deinit(allocator);
                for (a.value.list) |item| {
                    if (item == .string) {
                        try addresses.append(allocator, item.string);
                    }
                }
                filter_registrant_in = try addresses.toOwnedSlice(allocator);
                continue;
            }

            _ = common.matchStringArg(a, "registrant", &filter_registrant) or
                common.matchIntArg(a, "expiryDate_gt", &filter_expiry_gt) or
                common.matchIntArg(a, "expiryDate_gte", &filter_expiry_gte) or
                common.matchIntArg(a, "expiryDate_lt", &filter_expiry_lt) or
                common.matchIntArg(a, "expiryDate_lte", &filter_expiry_lte);
        }
    }
    defer if (filter_registrant_in) |regs| allocator.free(regs);

    const order_by = parser.getStringArg(field, "orderBy", null);
    const sort_field = mapRegistrationOrderBy(order_by);
    const order_dir = common.parseOrderDirection(field, db.EventOrderDir, .asc);

    // For expiryDate sort, we need in-memory fallback since expiry is in JSON
    const is_expiry_sort = if (order_by) |ob| std.mem.eql(u8, ob, "expiryDate") else false;

    // All filters are pushed to the DB level
    // For expiryDate sort, fetch all matching events for in-memory sort
    // For other sorts, fetch enough items to cover skip + first for offset pagination
    const fetch_limit: u32 = if (is_expiry_sort) 10000 else @intCast(first + skip);

    const events_result = try database.getRegistrations(.{
        .chain = filter_chain,
        .registrant = filter_registrant,
        .registrant_in = filter_registrant_in,
        .limit = fetch_limit,
        .order_dir = order_dir,
        .sort_field = sort_field,
        .expiry_gt = filter_expiry_gt,
        .expiry_gte = filter_expiry_gte,
        .expiry_lt = filter_expiry_lt,
        .expiry_lte = filter_expiry_lte,
    });
    defer {
        for (events_result) |*event| {
            event.deinit(allocator);
        }
        allocator.free(events_result);
    }

    // For expiryDate sort, apply in-memory sort since expiry is stored in JSON
    if (is_expiry_sort) {
        const FilteredEvent = struct {
            event: *models.Event,
            expiry: i64,
        };

        var filtered_events: std.ArrayList(FilteredEvent) = .{};
        defer filtered_events.deinit(allocator);

        for (events_result) |*event| {
            if (event.name == null) continue;

            var event_expiry: i64 = 0;
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, event.data, .{}) catch continue;
            defer parsed.deinit();

            if (parsed.value.object.get("expiration")) |expiration_val| {
                if (expiration_val == .integer) {
                    event_expiry = expiration_val.integer;
                }
            }

            try filtered_events.append(allocator, .{
                .event = event,
                .expiry = event_expiry,
            });
        }

        const ascending = order_dir == .asc;
        std.mem.sort(FilteredEvent, filtered_events.items, ascending, struct {
            fn lessThan(asc: bool, a: FilteredEvent, b: FilteredEvent) bool {
                return if (asc) a.expiry < b.expiry else a.expiry > b.expiry;
            }
        }.lessThan);

        // Build JSON from sorted events, applying skip
        var json: std.ArrayList(u8) = .{};
        defer json.deinit(allocator);

        try json.appendSlice(allocator, "[");
        const start_idx: usize = @min(@as(usize, @intCast(skip)), filtered_events.items.len);
        const end_idx: usize = @min(start_idx + @as(usize, @intCast(first)), filtered_events.items.len);
        for (filtered_events.items[start_idx..end_idx], 0..) |filtered, i| {
            if (i > 0) try json.appendSlice(allocator, ",");

            const reg_json = try builders.buildRegistrationJson(filtered.event, field.selections, .{
                .database = database,
                .depth = 0,
                .allocator = allocator,
                .loaders = ctx.loaders,
            });
            defer allocator.free(reg_json);
            try json.appendSlice(allocator, reg_json);
        }
        try json.appendSlice(allocator, "]");

        const result_json = try allocator.dupe(u8, json.items);
        return parser.FieldResult{ .json = result_json };
    }

    // For non-expiryDate sorts, data is already sorted by SQL
    // Build JSON, applying skip
    var json: std.ArrayList(u8) = .{};
    defer json.deinit(allocator);

    try json.appendSlice(allocator, "[");
    const start_idx: usize = @min(@as(usize, @intCast(skip)), events_result.len);
    const end_idx: usize = @min(start_idx + @as(usize, @intCast(first)), events_result.len);
    for (events_result[start_idx..end_idx], 0..) |*event, i| {
        if (i > 0) try json.appendSlice(allocator, ",");

        const reg_json = try builders.buildRegistrationJson(event, field.selections, .{
            .database = database,
            .depth = 0,
            .allocator = allocator,
            .loaders = ctx.loaders,
        });
        defer allocator.free(reg_json);
        try json.appendSlice(allocator, reg_json);
    }
    try json.appendSlice(allocator, "]");

    const result_json = try allocator.dupe(u8, json.items);
    return parser.FieldResult{ .json = result_json };
}
