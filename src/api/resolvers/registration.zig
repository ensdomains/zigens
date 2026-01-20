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
const builders = common.builders;
const loaders = common.loaders;
const NestedContext = common.NestedContext;

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

    // For backward pagination (last/before), reverse the query order
    const order_dir: db.EventOrderDir = if (params.direction == .backward) .asc else .desc;

    // Get registration events from database (filters by canonical registries internally)
    const events = try database.getRegistrations(.{
        .limit = @intCast(fetch_limit),
        .order_dir = order_dir,
    });
    defer {
        for (events) |*event| {
            event.deinit(allocator);
        }
        allocator.free(events);
    }

    // Determine actual items to return
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

    // Get total count for aggregation
    const total_count = try database.getTotalRegistrationCount();

    // Build connection
    const connection = try pagination.buildConnectionString(
        RegistrationWithSelections,
        allocator,
        wrapper_items,
        params,
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

    // Extract arguments
    const first = parser.getIntArg(field, "first", 100) orelse 100;
    const skip = parser.getIntArg(field, "skip", 0) orelse 0;

    // Parse filter if provided
    var filter_registrant: ?Address = null;
    var filter_registrant_in: ?[]Address = null;
    var filter_expiry_gt: ?i64 = null;
    var filter_expiry_gte: ?i64 = null;
    var filter_expiry_lt: ?i64 = null;
    var filter_expiry_lte: ?i64 = null;
    var filter_chain: ?models.Chain = null;

    // Look for "where" argument
    for (field.arguments) |arg| {
        if (std.mem.eql(u8, arg.name, "where")) {
            if (arg.value == .object) {
                for (arg.value.object) |filter_arg| {
                    if (std.mem.eql(u8, filter_arg.name, "registrant")) {
                        if (filter_arg.value == .string) {
                            filter_registrant = Address.fromHex(filter_arg.value.string) catch null;
                        }
                    } else if (std.mem.eql(u8, filter_arg.name, "chain")) {
                        if (filter_arg.value == .string) {
                            filter_chain = models.Chain.fromString(filter_arg.value.string) catch null;
                        }
                    } else if (std.mem.eql(u8, filter_arg.name, "expiryDate_gt")) {
                        if (filter_arg.value == .int) {
                            filter_expiry_gt = filter_arg.value.int;
                        }
                    } else if (std.mem.eql(u8, filter_arg.name, "expiryDate_lt")) {
                        if (filter_arg.value == .int) {
                            filter_expiry_lt = filter_arg.value.int;
                        }
                    } else if (std.mem.eql(u8, filter_arg.name, "registrant_in")) {
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
                            filter_registrant_in = try addresses.toOwnedSlice(allocator);
                        }
                    } else if (std.mem.eql(u8, filter_arg.name, "expiryDate_gte")) {
                        if (filter_arg.value == .int) {
                            filter_expiry_gte = filter_arg.value.int;
                        }
                    } else if (std.mem.eql(u8, filter_arg.name, "expiryDate_lte")) {
                        if (filter_arg.value == .int) {
                            filter_expiry_lte = filter_arg.value.int;
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

    // Get registration events from database
    // The database handles contract filtering internally based on its network configuration
    const fetch_limit = if (filter_registrant != null or filter_registrant_in != null or
        filter_expiry_gt != null or filter_expiry_gte != null or
        filter_expiry_lt != null or filter_expiry_lte != null)
        @min(first * 10, 1000)
    else
        first;

    const events = try database.getRegistrations(.{
        .chain = filter_chain,
        .limit = @intCast(fetch_limit),
        .order_dir = .desc,
    });
    defer {
        for (events) |*event| {
            event.deinit(allocator);
        }
        allocator.free(events);
    }

    // Helper struct for sorting
    const FilteredEvent = struct {
        event: *models.Event,
        name: []const u8,
        expiry: i64,
    };

    // First pass: collect filtered events
    var filtered_events: std.ArrayList(FilteredEvent) = .{};
    defer filtered_events.deinit(allocator);

    for (events) |*event| {
        if (event.name == null) continue;

        // Parse event data to check filters
        var matches = true;
        var event_expiry: i64 = 0;
        var owner_str: ?[]const u8 = null;

        if (filter_registrant != null or filter_registrant_in != null or
            filter_expiry_gt != null or filter_expiry_gte != null or
            filter_expiry_lt != null or filter_expiry_lte != null or
            order_by != null) {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, event.data, .{}) catch continue;
            defer parsed.deinit();

            // Get owner for registrant filters
            owner_str = if (parsed.value.object.get("owner")) |owner_val|
                if (owner_val == .string) owner_val.string else null
            else
                null;

            // Check registrant filter
            if (filter_registrant) |reg_addr| {
                if (owner_str) |owner| {
                    const owner_addr = Address.fromHex(owner) catch {
                        matches = false;
                        continue;
                    };
                    if (!owner_addr.eql(reg_addr)) matches = false;
                } else {
                    matches = false;
                }
            }

            // Check registrant_in filter
            if (matches and filter_registrant_in != null) {
                if (owner_str) |owner| {
                    const owner_addr = Address.fromHex(owner) catch {
                        matches = false;
                        continue;
                    };
                    var found = false;
                    for (filter_registrant_in.?) |addr| {
                        if (owner_addr.eql(addr)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) matches = false;
                } else {
                    matches = false;
                }
            }

            // Get expiry for filter checks and sorting
            // Calculate expiry from timestamp + duration
            if (parsed.value.object.get("duration")) |duration_val| {
                if (duration_val == .integer) {
                    event_expiry = event.timestamp + duration_val.integer;
                }
            }
        }

        // Apply expiry filters
        if (matches and filter_expiry_gt != null) {
            if (event_expiry <= filter_expiry_gt.?) matches = false;
        }
        if (matches and filter_expiry_gte != null) {
            if (event_expiry < filter_expiry_gte.?) matches = false;
        }
        if (matches and filter_expiry_lt != null) {
            if (event_expiry >= filter_expiry_lt.?) matches = false;
        }
        if (matches and filter_expiry_lte != null) {
            if (event_expiry > filter_expiry_lte.?) matches = false;
        }

        if (matches) {
            try filtered_events.append(allocator, .{
                .event = event,
                .name = event.name.?,
                .expiry = event_expiry,
            });
        }
    }

    // Sort filtered events if orderBy is specified
    if (order_by) |field_name| {
        const ascending = std.mem.eql(u8, order_direction, "asc");
        const SortContext = struct {
            field: []const u8,
            asc: bool,
        };
        const sort_ctx = SortContext{ .field = field_name, .asc = ascending };

        std.mem.sort(FilteredEvent, filtered_events.items, sort_ctx, struct {
            fn lessThan(sort_ctx_param: SortContext, a: FilteredEvent, b: FilteredEvent) bool {
                if (std.mem.eql(u8, sort_ctx_param.field, "name")) {
                    const cmp = std.mem.order(u8, a.name, b.name);
                    return if (sort_ctx_param.asc) cmp == .lt else cmp == .gt;
                } else if (std.mem.eql(u8, sort_ctx_param.field, "registrationDate")) {
                    return if (sort_ctx_param.asc) a.event.timestamp < b.event.timestamp else a.event.timestamp > b.event.timestamp;
                } else if (std.mem.eql(u8, sort_ctx_param.field, "expiryDate")) {
                    return if (sort_ctx_param.asc) a.expiry < b.expiry else a.expiry > b.expiry;
                } else if (std.mem.eql(u8, sort_ctx_param.field, "id")) {
                    // For registrations, id is the name
                    const cmp = std.mem.order(u8, a.name, b.name);
                    return if (sort_ctx_param.asc) cmp == .lt else cmp == .gt;
                }
                return false;
            }
        }.lessThan);
    }

    // Build JSON from sorted/filtered events, applying skip
    var json: std.ArrayList(u8) = .{};
    defer json.deinit(allocator);

    try json.appendSlice(allocator, "[");
    const start_idx = @min(skip, filtered_events.items.len);
    const end_idx = @min(start_idx + first, filtered_events.items.len);
    for (filtered_events.items[@as(usize, @intCast(start_idx))..@as(usize, @intCast(end_idx))], 0..) |filtered, i| {
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
