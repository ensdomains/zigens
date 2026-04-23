/// Event-related GraphQL resolvers
/// - resolveEvents: List events with filters
/// - resolveEventConnection: Cursor-based pagination for events
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

pub fn resolveEventConnection(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
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
    var filter_opts = db.EventFilterOptions{};

    var event_types_list: std.ArrayList([]const u8) = .{};
    defer event_types_list.deinit(allocator);

    var normalized_contract_address: ?[]u8 = null;
    defer if (normalized_contract_address) |addr| allocator.free(addr);

    if (common.getObjectArg(field, "where")) |where_args| {
        for (where_args) |a| {
            if (std.mem.eql(u8, a.name, "type_in") and a.value == .list) {
                for (a.value.list) |item| {
                    if (item == .string) try event_types_list.append(allocator, item.string);
                }
                if (event_types_list.items.len > 0) filter_opts.event_types = event_types_list.items;
                continue;
            }
            if (std.mem.eql(u8, a.name, "contractAddress") and a.value == .string) {
                // Normalize inline — needs allocation owned by the caller.
                const addr = Address.fromHex(a.value.string) catch continue;
                normalized_contract_address = try addr.toHex(allocator);
                filter_opts.contract_address = normalized_contract_address;
                continue;
            }

            _ = common.matchStringArg(a, "type", &filter_opts.event_type) or
                common.matchStringArg(a, "domain", &filter_opts.domain) or
                common.matchStringArg(a, "namehash", &filter_opts.namehash) or
                common.matchIntArg(a, "blockNumber_gt", &filter_opts.block_number_gt) or
                common.matchIntArg(a, "blockNumber_lt", &filter_opts.block_number_lt) or
                common.matchIntArg(a, "timestamp_gt", &filter_opts.timestamp_gt) or
                common.matchIntArg(a, "timestamp_lt", &filter_opts.timestamp_lt);
        }
    }

    if (parser.getStringArg(field, "orderBy", null)) |order_by| {
        if (std.mem.eql(u8, order_by, "blockNumber")) filter_opts.sort_field = .block_number;
        if (std.mem.eql(u8, order_by, "timestamp")) filter_opts.sort_field = .timestamp;
        if (std.mem.eql(u8, order_by, "name")) filter_opts.sort_field = .name;
    }
    filter_opts.order_dir = common.parseOrderDirection(field, db.EventOrderDir, filter_opts.order_dir);

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
        const count = try database.getEventCount(filter_opts);
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

    // Fetch one extra item to determine hasNextPage/hasPreviousPage
    const fetch_limit = params.limit + 1;

    // For backward pagination (last/before), flip the query order
    const user_dir = filter_opts.order_dir;
    const order_dir: db.EventOrderDir = if (params.direction == .backward)
        (if (user_dir == .desc) .asc else .desc)
    else
        user_dir;

    // Convert cursor → skip offset (same pattern as registrationConnection).
    // Cursor format is "<tx_hash_hex>-<log_index>".
    var skip: u32 = 0;
    if (params.cursor) |c| {
        const decoded_opt = pagination.CursorCodec.decodeString(allocator, c) catch null;
        if (decoded_opt) |decoded| {
            defer allocator.free(decoded);
            if (std.mem.lastIndexOfScalar(u8, decoded, '-')) |sep| {
                const tx_hash = decoded[0..sep];
                const log_index = std.fmt.parseInt(u32, decoded[sep + 1 ..], 10) catch 0;
                // eventConnection doesn't pre-filter by event_type — pass null so all events count.
                // TODO: if filter_opts.event_type / event_types is set, include here for accurate offset.
                const events_before = database.countEventsBeforeCursor(tx_hash, log_index, order_dir, null) catch 0;
                skip = events_before +| 1;
            }
        }
    }

    // Apply filters and fetch
    var fetch_filter = filter_opts;
    fetch_filter.limit = @intCast(fetch_limit);
    fetch_filter.skip = skip;
    fetch_filter.order_dir = order_dir;

    const events = try database.getEventsFiltered(fetch_filter);
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

    // Wrapper type for events
    const EventWithSelections = struct {
        event: *models.Event,
        selections: []const parser.Field,
        ctx: NestedContext,
        id: []const u8,
    };

    // Helper to get ID
    const getId = struct {
        fn call(item: EventWithSelections) []const u8 {
            return item.id;
        }
    }.call;

    // Create wrapper items with IDs
    var wrapper_items = try allocator.alloc(EventWithSelections, items_slice.len);
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
        wrapper_items[i] = EventWithSelections{
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
        try database.getEventCount(filter_opts)
    else
        null;

    // Build connection
    const connection = try pagination.buildConnectionString(
        EventWithSelections,
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

        // Build event JSON for the node
        const event_json = try builders.buildEventJson(edge.node.event, edge.node.selections, edge.node.ctx);
        defer allocator.free(event_json);
        try json.appendSlice(allocator, event_json);

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

/// Resolver for domain query (single domain)
pub fn resolveEvents(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));
    const allocator = ctx.allocator;

    const first = common.parsePagination(field, 100).first;

    // Parse EventFilter if provided
    var filter_opts = db.EventFilterOptions{
        .limit = first,
    };

    // Temporary storage for event_types strings
    var event_types_list: std.ArrayList([]const u8) = .{};
    defer event_types_list.deinit(allocator);

    // Temporary storage for normalized contract address (to handle checksummed addresses)
    var normalized_contract_address: ?[]u8 = null;
    defer if (normalized_contract_address) |addr| allocator.free(addr);

    // Parse arguments
    if (common.getObjectArg(field, "where")) |where_args| {
        for (where_args) |a| {
            if (std.mem.eql(u8, a.name, "type_in") and a.value == .list) {
                for (a.value.list) |item| {
                    if (item == .string) try event_types_list.append(allocator, item.string);
                }
                if (event_types_list.items.len > 0) filter_opts.event_types = event_types_list.items;
                continue;
            }
            if (std.mem.eql(u8, a.name, "contractAddress") and a.value == .string) {
                // NOTE: unlike the Connection variant, this query surfaces invalid addresses as errors.
                const addr = Address.fromHex(a.value.string) catch return error.InvalidContractAddress;
                normalized_contract_address = try addr.toHex(allocator);
                filter_opts.contract_address = normalized_contract_address;
                continue;
            }

            _ = common.matchStringArg(a, "type", &filter_opts.event_type) or
                common.matchStringArg(a, "domain", &filter_opts.domain) or
                common.matchStringArg(a, "namehash", &filter_opts.namehash) or
                common.matchIntArg(a, "blockNumber_gt", &filter_opts.block_number_gt) or
                common.matchIntArg(a, "blockNumber_lt", &filter_opts.block_number_lt) or
                common.matchIntArg(a, "timestamp_gt", &filter_opts.timestamp_gt) or
                common.matchIntArg(a, "timestamp_lt", &filter_opts.timestamp_lt);
        }
    }

    if (parser.getStringArg(field, "orderBy", null)) |order_by| {
        if (std.mem.eql(u8, order_by, "blockNumber")) filter_opts.sort_field = .block_number;
        if (std.mem.eql(u8, order_by, "timestamp")) filter_opts.sort_field = .timestamp;
        if (std.mem.eql(u8, order_by, "name")) filter_opts.sort_field = .name;
    }
    filter_opts.order_dir = common.parseOrderDirection(field, db.EventOrderDir, filter_opts.order_dir);

    // Get events from database with filters
    const events = try database.getEventsFiltered(filter_opts);
    defer {
        for (events) |*event| {
            event.deinit(allocator);
        }
        allocator.free(events);
    }

    // Build JSON array
    var json: std.ArrayList(u8) = .{};
    defer json.deinit(allocator);

    try json.appendSlice(allocator, "[");
    for (events, 0..) |*event, i| {
        if (i > 0) try json.appendSlice(allocator, ",");

        // Build event object with nested field support
        const event_json = try builders.buildEventJson(event, field.selections, .{
            .database = database,
            .depth = 0,
            .allocator = allocator,
            .loaders = ctx.loaders,
        });
        defer allocator.free(event_json);
        try json.appendSlice(allocator, event_json);
    }
    try json.appendSlice(allocator, "]");

    const result_json = try allocator.dupe(u8, json.items);
    return parser.FieldResult{ .json = result_json };
}
