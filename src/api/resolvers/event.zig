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

/// Parse an EventFilter argument list — the top-level `where:` object or a nested
/// `and`/`or` element — into the WHERE-predicate fields of an `EventFilterOptions`.
/// Recursive for the boolean groups. Allocations use the request arena (`ctx.allocator`),
/// so list/address allocations need no explicit free. Query options (limit/order/sort)
/// are set by the caller, not here.
fn parseEventWhereArgs(where_args: []const parser.Argument, allocator: std.mem.Allocator) anyerror!db.EventFilterOptions {
    var opts = db.EventFilterOptions{};
    for (where_args) |a| {
        if ((std.mem.eql(u8, a.name, "and") or std.mem.eql(u8, a.name, "or")) and a.value == .list) {
            const is_and = std.mem.eql(u8, a.name, "and");
            var group: std.ArrayList(db.EventFilterOptions) = .empty;
            errdefer group.deinit(allocator);
            for (a.value.list) |item| {
                if (item == .object) try group.append(allocator, try parseEventWhereArgs(item.object, allocator));
            }
            const slice = try group.toOwnedSlice(allocator);
            if (is_and) {
                opts.and_group = slice;
            } else {
                opts.or_group = slice;
            }
            continue;
        }
        if (std.mem.eql(u8, a.name, "type_in") and a.value == .list) {
            var list: std.ArrayList([]const u8) = .empty;
            errdefer list.deinit(allocator);
            for (a.value.list) |item| {
                if (item == .string) try list.append(allocator, item.string);
            }
            if (list.items.len > 0) opts.event_types = try list.toOwnedSlice(allocator);
            continue;
        }
        if (std.mem.eql(u8, a.name, "type_not_in") and a.value == .list) {
            var list: std.ArrayList([]const u8) = .empty;
            errdefer list.deinit(allocator);
            for (a.value.list) |item| {
                if (item == .string) try list.append(allocator, item.string);
            }
            if (list.items.len > 0) opts.event_types_not = try list.toOwnedSlice(allocator);
            continue;
        }
        if (std.mem.eql(u8, a.name, "contractAddress") and a.value == .string) {
            const addr = Address.fromHex(a.value.string) catch return error.InvalidContractAddress;
            opts.contract_address = try addr.toHex(allocator);
            continue;
        }
        if (std.mem.eql(u8, a.name, "involved") and a.value == .string) {
            const addr = Address.fromHex(a.value.string) catch return error.InvalidInvolvedAddress;
            opts.involved = try addr.toHex(allocator);
            continue;
        }
        if (std.mem.eql(u8, a.name, "protocol") and a.value == .string) {
            opts.protocol = models.Protocol.fromString(a.value.string) catch return error.InvalidProtocol;
            continue;
        }
        _ = common.matchStringArg(a, "type", &opts.event_type) or
            common.matchStringArg(a, "type_not", &opts.event_type_not) or
            common.matchStringArg(a, "domain", &opts.domain) or
            common.matchStringArg(a, "namehash", &opts.namehash) or
            common.matchIntArg(a, "blockNumber_gt", &opts.block_number_gt) or
            common.matchIntArg(a, "blockNumber_gte", &opts.block_number_gte) or
            common.matchIntArg(a, "blockNumber_lt", &opts.block_number_lt) or
            common.matchIntArg(a, "blockNumber_lte", &opts.block_number_lte) or
            common.matchIntArg(a, "timestamp_gt", &opts.timestamp_gt) or
            common.matchIntArg(a, "timestamp_gte", &opts.timestamp_gte) or
            common.matchIntArg(a, "timestamp_lt", &opts.timestamp_lt) or
            common.matchIntArg(a, "timestamp_lte", &opts.timestamp_lte);
    }
    return opts;
}

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

    // Parse where filters (incl. recursive and/or boolean tree).
    var filter_opts = if (common.getObjectArg(field, "where")) |where_args|
        try parseEventWhereArgs(where_args, allocator)
    else
        db.EventFilterOptions{};

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

    // Convert cursor → skip offset. Cursor format: "<tx_hash_hex>-<log_index>". The count
    // must apply the SAME filters as the row query (type, namehash, contractAddress, block
    // range, …) — otherwise offset is taken over the unfiltered superset and pages drop rows.
    var skip: u32 = 0;
    if (params.cursor) |c| {
        const decoded = try pagination.CursorCodec.decodeString(allocator, c);
        defer allocator.free(decoded);
        const sep = std.mem.lastIndexOfScalar(u8, decoded, '-') orelse return error.InvalidCursor;
        const tx_hash = decoded[0..sep];
        const log_index = std.fmt.parseInt(u32, decoded[sep + 1 ..], 10) catch return error.InvalidCursor;
        const events_before = database.countEventsBeforeCursor(tx_hash, log_index, order_dir, filter_opts) catch 0;
        skip = events_before +| 1;
    }

    // Apply filters and fetch
    var fetch_filter = filter_opts;
    fetch_filter.limit = @intCast(fetch_limit);
    fetch_filter.skip = skip;
    fetch_filter.order_dir = order_dir;

    const events = try database.getEventsFiltered(fetch_filter);
    defer {
        for (events) |*event| {
            event.deinit(database.allocator);
        }
        database.allocator.free(events);
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
                .resolve = null, // list context: live resolution is single-name only, never per-row
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
    var json: std.ArrayList(u8) = .empty;
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

/// Subgraph-parity top-level per-type event queries.
///
/// Each generated resolver below filters the flat `events` table by a fixed
/// `event_type` and returns `[Event!]!` (typed projection via `as*` accessors).
/// This avoids duplicating storage — these are just typed projections of the
/// existing events list. The injected `event_type` overrides any client-set
/// `where.type` so callers can't accidentally cross-query.
fn perTypeEventResolver(comptime event_type_str: []const u8) parser.ResolverFn {
    const inner = struct {
        fn resolve(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
            return resolveEventsWithForcedType(ctx, field, event_type_str);
        }
    };
    return inner.resolve;
}

/// Same as `perTypeEventResolver` but unions multiple event types. Used for
/// `nameRegistereds` where subgraph convention surfaces both V1 BaseRegistrar
/// `NameRegistered` events AND V2 PermissionedRegistry `LabelRegistered` events
/// as a single "name registration" stream — they're semantically the same
/// "a name was registered" signal, just emitted by different contracts.
fn perTypeEventResolverMulti(comptime event_types_arr: []const []const u8) parser.ResolverFn {
    const inner = struct {
        fn resolve(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
            return resolveEventsWithForcedTypes(ctx, field, event_types_arr);
        }
    };
    return inner.resolve;
}

pub const resolveTransfers = perTypeEventResolver("Transfer");
pub const resolveNameRegistereds = perTypeEventResolverMulti(&[_][]const u8{ "NameRegistered", "LabelRegistered" });
pub const resolveNameReneweds = perTypeEventResolver("NameRenewed");
pub const resolveTextChangeds = perTypeEventResolver("TextChanged");
pub const resolveAddressChangeds = perTypeEventResolver("AddressChanged");
pub const resolveNameWrappeds = perTypeEventResolver("NameWrapped");
pub const resolveNameUnwrappeds = perTypeEventResolver("NameUnwrapped");
pub const resolveFusesSets = perTypeEventResolver("FusesSet");
pub const resolveExpiryUpdateds = perTypeEventResolver("ExpiryUpdated");
pub const resolveResolverUpdateds = perTypeEventResolver("ResolverUpdated");
pub const resolveLabelRegistereds = perTypeEventResolver("LabelRegistered");
pub const resolveReverseClaimeds = perTypeEventResolver("ReverseClaimed");
pub const resolveRegistryTransfers = perTypeEventResolver("RegistryTransfer");

/// Resolver for domain query (single domain)
pub fn resolveEvents(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    return resolveEventsWithForcedType(ctx, field, null);
}

/// Sister entry-point for resolvers that need to union multiple event types
/// (currently only `nameRegistereds`). Delegates to the same body as the
/// single-type variant.
fn resolveEventsWithForcedTypes(ctx: parser.ExecutionContext, field: *const parser.Field, forced_event_types: []const []const u8) !parser.FieldResult {
    return resolveEventsWithForced(ctx, field, null, forced_event_types);
}

fn resolveEventsWithForcedType(ctx: parser.ExecutionContext, field: *const parser.Field, forced_event_type: ?[]const u8) !parser.FieldResult {
    return resolveEventsWithForced(ctx, field, forced_event_type, null);
}

fn resolveEventsWithForced(ctx: parser.ExecutionContext, field: *const parser.Field, forced_event_type: ?[]const u8, forced_event_types: ?[]const []const u8) !parser.FieldResult {
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));
    const allocator = ctx.allocator;

    const first = (try common.parsePagination(field, 100)).first;

    // Parse EventFilter (incl. recursive and/or boolean tree).
    var filter_opts = if (common.getObjectArg(field, "where")) |where_args|
        try parseEventWhereArgs(where_args, allocator)
    else
        db.EventFilterOptions{};
    filter_opts.limit = first;

    // Subgraph-parity per-type top-level queries (transfers, textChangeds, …)
    // inject a fixed event_type that overrides any client-set `where.type`.
    if (forced_event_type) |t| {
        filter_opts.event_type = t;
        filter_opts.event_types = null;
        filter_opts.event_type_not = null;
        filter_opts.event_types_not = null;
    }
    if (forced_event_types) |ts| {
        filter_opts.event_type = null;
        filter_opts.event_types = ts;
        filter_opts.event_type_not = null;
        filter_opts.event_types_not = null;
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
            event.deinit(database.allocator);
        }
        database.allocator.free(events);
    }

    // Build JSON array
    var json: std.ArrayList(u8) = .empty;
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
            .resolve = null, // list context: live resolution is single-name only, never per-row
        });
        defer allocator.free(event_json);
        try json.appendSlice(allocator, event_json);
    }
    try json.appendSlice(allocator, "]");

    const result_json = try allocator.dupe(u8, json.items);
    return parser.FieldResult{ .json = result_json };
}
