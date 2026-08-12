//! MCP (Model Context Protocol) endpoint — agents discover, connect to, and
//! query ENSv2 through the standard agent protocol, with GraphQL as the
//! primary interface (taught via the `graphql-query` tool's primer, not
//! templated). See docs/mcp-agent-endpoint-design.md for the full design.
//!
//! Transport: Streamable HTTP in stateless JSON mode — every POST /mcp gets
//! one application/json response; no SSE, no sessions. Notifications get 202.
//! The protocol core (`processMcp`) is transport-free and takes an Executor,
//! so tests drive it over a seeded database without sockets.
//!
//! Tool calls that run GraphQL go through the SAME pipeline as /graphql
//! (validation, cost model, complexity limits, batch loaders) via
//! Server.executeQuery — no separate query engine exists here.

const std = @import("std");
const validation = @import("../utils/validation.zig");
const jw = @import("../lib/graphql/json_writer.zig");
const http_util = @import("http_util.zig");
const Server = @import("server.zig").Server;

pub const PROTOCOL_VERSION = "2025-06-18";
pub const SERVER_NAME = "ensv2-indexer";
pub const SERVER_VERSION = "0.1.0";

/// Transport-free query runner: prod wraps Server.executeQuery, tests wrap a
/// GraphQLHandler over a seeded test database. Returns allocator-owned
/// response JSON.
pub const Executor = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, query: []const u8, variables: ?std.json.Value) anyerror![]u8,
};

const GRAPHQL_QUERY_PRIMER =
    "Query the ENSv2 indexer with GraphQL. Read-only. " ++
    "ENTRY POINTS: domains(where, first, skip, orderBy, orderDirection) lists/filters domains; " ++
    "domain(id) fetches one domain by NAMEHASH (0x-prefixed 32-byte hex; to look up by name use domains(where:{name:\"alice.eth\"})); " ++
    "resolveDomain(id) fetches one domain WITH live on-chain resolution; " ++
    "registrations(...) is registration history (orderBy: registrationDate | expiryDate | name); " ++
    "accounts(...) / account(id: \"0x…address\") are owners and their domains; " ++
    "events(...) are raw indexed events; _finality / _coverage report the indexing head, safe/finalized blocks, and staleness. " ++
    "CONVENTIONS: filters go in where:{...} with suffixed operators (name_in:[...], expiryDate_gt: <unix seconds>, registrant:\"0x…\"). " ++
    "Paginate with first/skip (keep first <= 100). protocol is \"v1\" (legacy ENS) or \"v2\"; the same name can exist in both. " ++
    "PITFALLS: (1) resolver { texts } returns record KEYS only — read a value with text(key:\"…\"). " ++
    "(2) Listings hide unnormalized and unreachable names by default; pass includeUnnormalized: true / includeUnreachable: true to see them. " ++
    "(3) List queries return INDEXED data only. " ++
    "(4) Expensive queries are rejected by a complexity limit — select only the fields you need. " ++
    "(5) On a syntax or validation error the response includes line/column locations — fix and retry once. " ++
    "Call get-graphql-schema for exact types and fields; read the examples resource for known-good queries.";

const GET_SCHEMA_DESCRIPTION =
    "Look up the exact GraphQL type definitions behind graphql-query. " ++
    "Without arguments: a compact index of every type name with its description. " ++
    "With {\"type\":\"Domain\"}: that type's full SDL definition (fields, arguments, docs). " ++
    "Pull only the types you need — there is no full-schema dump.";

/// Known-good queries, mirrored from the conformance corpus
/// (tests/conformance/runner.zig) — they are verified against goldens on
/// every test run, so the examples can't rot silently.
const EXAMPLES_MARKDOWN =
    \\# ENSv2 GraphQL examples (verified against the conformance suite)
    \\
    \\Look up one domain by name:
    \\```graphql
    \\{ domains(where:{name:"alice.eth"}){ name owner { id } resolver { address } expiryDate } }
    \\```
    \\
    \\Newest registrations with resolver profile records:
    \\```graphql
    \\{ registrations(first:10, orderBy:registrationDate, orderDirection:desc){ name registrationDate expiryDate domain { resolver { address avatar: text(key:"avatar") } } } }
    \\```
    \\
    \\All domains owned by an address:
    \\```graphql
    \\{ account(id:"0x1111111111111111111111111111111111111111"){ domains { name expiryDate } } }
    \\```
    \\
    \\Historical state of a domain at a block (time travel):
    \\```graphql
    \\query($id:String!){ domain(id:$id, atBlock: 235){ id owner { id } resolver { addr text(key:"avatar") } } }
    \\```
    \\
    \\Which text-record keys a resolver has set (values via text(key:)):
    \\```graphql
    \\{ domains(where:{name:"alice.eth"}){ resolver { texts } } }
    \\```
    \\
    \\Data freshness / staleness check:
    \\```graphql
    \\{ _coverage { chainId stale protocols { protocol indexedHead } } _finality { head { number } isStale } }
    \\```
;

const COVERAGE_QUERY =
    "{ _coverage { chainId stale protocols { protocol indexedHead } } _finality { head { number } safe { number } finalized { number } isStale } }";

// ---------------------------------------------------------------------------
// HTTP entry (prod)
// ---------------------------------------------------------------------------

pub fn handleMcp(self: *Server, conn: http_util.Conn, request: []const u8) !void {
    const body_start = std.mem.indexOf(u8, request, "\r\n\r\n") orelse std.mem.indexOf(u8, request, "\n\n") orelse {
        return try self.sendJsonResponse(conn, 400, "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"missing request body\"}}");
    };
    const body = request[body_start + 4 ..];

    var prod = ProdExecutor{ .server = self };
    const response = processMcp(self.allocator, body, .{ .ctx = &prod, .run = ProdExecutor.run }) catch |err| {
        std.log.warn("mcp: internal error: {}", .{err});
        return try self.sendJsonResponse(conn, 500, "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"internal error\"}}");
    };
    if (response) |resp| {
        defer self.allocator.free(resp);
        try self.sendJsonResponse(conn, 200, resp);
    } else {
        // Notification: accepted, no body (Streamable HTTP contract).
        try self.sendJsonResponse(conn, 202, "");
    }
}

const ProdExecutor = struct {
    server: *Server,
    fn run(ctx: *anyopaque, allocator: std.mem.Allocator, query: []const u8, variables: ?std.json.Value) anyerror![]u8 {
        _ = allocator;
        const self: *ProdExecutor = @ptrCast(@alignCast(ctx));
        return self.server.executeQuery(query, variables, null, false);
    }
};

// ---------------------------------------------------------------------------
// Protocol core (transport-free, testable)
// ---------------------------------------------------------------------------

/// Process one JSON-RPC message body. Returns the allocator-owned response
/// body, or null for notifications (no id → HTTP 202, no body).
pub fn processMcp(allocator: std.mem.Allocator, body: []const u8, executor: Executor) !?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return try rpcError(allocator, .null, -32700, "parse error: body is not valid JSON");
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return try rpcError(allocator, .null, -32600, "invalid request: expected a JSON-RPC object");
    }
    const obj = parsed.value.object;

    const method_val = obj.get("method") orelse
        return try rpcError(allocator, .null, -32600, "invalid request: missing method");
    if (method_val != .string)
        return try rpcError(allocator, .null, -32600, "invalid request: method must be a string");
    const method = method_val.string;

    const id: std.json.Value = obj.get("id") orelse .null;
    const is_notification = obj.get("id") == null;
    if (is_notification) {
        // notifications/initialized etc.: accept and ignore.
        return null;
    }
    const params: ?std.json.Value = obj.get("params");

    if (std.mem.eql(u8, method, "initialize")) {
        return try handleInitialize(allocator, id);
    } else if (std.mem.eql(u8, method, "ping")) {
        return try rpcResultRaw(allocator, id, "{}");
    } else if (std.mem.eql(u8, method, "tools/list")) {
        return try handleToolsList(allocator, id);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        return try handleToolsCall(allocator, id, params, executor);
    } else if (std.mem.eql(u8, method, "resources/list")) {
        return try handleResourcesList(allocator, id);
    } else if (std.mem.eql(u8, method, "resources/read")) {
        return try handleResourcesRead(allocator, id, params, executor);
    }
    return try rpcError(allocator, id, -32601, "method not found");
}

fn handleInitialize(allocator: std.mem.Allocator, id: std.json.Value) ![]u8 {
    // Stateless server: whatever version the client proposes, answer with the
    // one we speak — the client disconnects if it can't accept it (spec flow).
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var o = try beginResponse(&out.writer, allocator, id);
    var result = try o.beginObject("result");
    try result.fieldStr("protocolVersion", PROTOCOL_VERSION, allocator);
    var caps = try result.beginObject("capabilities");
    try caps.fieldRaw("tools", "{}");
    try caps.fieldRaw("resources", "{}");
    try caps.end();
    var info = try result.beginObject("serverInfo");
    try info.fieldStr("name", SERVER_NAME, allocator);
    try info.fieldStr("version", SERVER_VERSION, allocator);
    try info.end();
    try result.fieldStr("instructions", "ENSv2 (Ethereum Name Service) indexer. Use graphql-query to read domains, registrations, resolvers, accounts, and events; get-graphql-schema for exact types; the examples resource for known-good queries.", allocator);
    try result.end();
    try o.end();
    return try out.toOwnedSlice();
}

fn handleToolsList(allocator: std.mem.Allocator, id: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var o = try beginResponse(&out.writer, allocator, id);
    var result = try o.beginObject("result");
    var tools = try result.beginArray("tools");

    {
        var t = try tools.beginObject();
        try t.fieldStr("name", "graphql-query", allocator);
        try t.fieldStr("description", GRAPHQL_QUERY_PRIMER, allocator);
        try t.fieldRaw("inputSchema",
            \\{"type":"object","properties":{"query":{"type":"string","description":"The GraphQL query document"},"variables":{"type":"object","description":"Optional GraphQL variables"}},"required":["query"]}
        );
        try t.end();
    }
    {
        var t = try tools.beginObject();
        try t.fieldStr("name", "get-graphql-schema", allocator);
        try t.fieldStr("description", GET_SCHEMA_DESCRIPTION, allocator);
        try t.fieldRaw("inputSchema",
            \\{"type":"object","properties":{"type":{"type":"string","description":"A type name from the index, e.g. Domain"}}}
        );
        try t.end();
    }

    try tools.end();
    try result.end();
    try o.end();
    return try out.toOwnedSlice();
}

fn handleToolsCall(allocator: std.mem.Allocator, id: std.json.Value, params: ?std.json.Value, executor: Executor) ![]u8 {
    const p = params orelse return try rpcError(allocator, id, -32602, "invalid params: missing");
    if (p != .object) return try rpcError(allocator, id, -32602, "invalid params: expected object");
    const name_val = p.object.get("name") orelse return try rpcError(allocator, id, -32602, "invalid params: missing tool name");
    if (name_val != .string) return try rpcError(allocator, id, -32602, "invalid params: tool name must be a string");
    const tool = name_val.string;
    const args: ?std.json.Value = p.object.get("arguments");

    if (std.mem.eql(u8, tool, "graphql-query")) {
        return try callGraphqlQuery(allocator, id, args, executor);
    } else if (std.mem.eql(u8, tool, "get-graphql-schema")) {
        return try callGetSchema(allocator, id, args);
    }
    return try rpcError(allocator, id, -32602, "unknown tool");
}

fn callGraphqlQuery(allocator: std.mem.Allocator, id: std.json.Value, args: ?std.json.Value, executor: Executor) ![]u8 {
    const a = args orelse return try toolError(allocator, id, "missing arguments: {\"query\":\"...\"} required");
    if (a != .object) return try toolError(allocator, id, "arguments must be an object");
    const q_val = a.object.get("query") orelse return try toolError(allocator, id, "missing required argument: query");
    if (q_val != .string) return try toolError(allocator, id, "query must be a string");
    const query = q_val.string;
    validation.validateGraphQLQuery(query) catch {
        return try toolError(allocator, id, "invalid query: length must be between 1 and 10000 characters");
    };
    const variables: ?std.json.Value = if (a.object.get("variables")) |v| blk: {
        if (v == .object) break :blk v;
        if (v == .null) break :blk null;
        return try toolError(allocator, id, "variables must be an object");
    } else null;

    const result_json = executor.run(executor.ctx, allocator, query, variables) catch {
        return try toolError(allocator, id, "query execution failed");
    };
    defer allocator.free(result_json);

    // Tool-level isError only for pure error responses (no data at all) —
    // partial results (data + errors) are successes the agent should read.
    const is_error = graphqlResponseIsPureError(allocator, result_json);
    return try toolTextResult(allocator, id, result_json, is_error);
}

fn graphqlResponseIsPureError(allocator: std.mem.Allocator, response: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const has_errors = parsed.value.object.get("errors") != null;
    const data = parsed.value.object.get("data") orelse return has_errors;
    return has_errors and data == .null;
}

// ---------------------------------------------------------------------------
// get-graphql-schema: SDL sectioner over the embedded schema
// ---------------------------------------------------------------------------

const schema_sdl = @embedFile("schema.graphql");

const TOP_LEVEL_KINDS = [_][]const u8{ "type ", "enum ", "input ", "interface ", "union ", "scalar " };

fn lineStartsBlock(line: []const u8) ?[]const u8 {
    for (TOP_LEVEL_KINDS) |kind| {
        if (std.mem.startsWith(u8, line, kind)) {
            var rest = line[kind.len..];
            const name_end = std.mem.indexOfAny(u8, rest, " {(\r") orelse rest.len;
            rest = rest[0..name_end];
            if (rest.len > 0) return rest;
        }
    }
    return null;
}

const SchemaBlock = struct {
    name: []const u8,
    /// Slice of schema_sdl: the block including its preceding docstring.
    text: []const u8,
    /// First docstring line, for the index view ("" when undocumented).
    doc: []const u8,
};

/// Split the SDL into top-level blocks. A docstring (\"\"\") directly above a
/// block belongs to it. Comptime-fixed capacity: the schema has well under
/// 256 top-level types, and growth fails the build-time test, not runtime.
fn sectionSchema(blocks: *[256]SchemaBlock) usize {
    var count: usize = 0;
    var block_start: usize = 0;
    var doc_start: ?usize = null;
    var doc_line: []const u8 = "";
    var pending_doc: []const u8 = "";
    var in_doc = false;
    var current: ?[]const u8 = null;

    var offset: usize = 0;
    var it = std.mem.splitScalar(u8, schema_sdl, '\n');
    while (it.next()) |line_raw| {
        const line_off = offset;
        offset += line_raw.len + 1;
        const line = std.mem.trimEnd(u8, line_raw, "\r");

        if (std.mem.startsWith(u8, line, "\"\"\"")) {
            if (!in_doc) {
                doc_start = line_off;
                doc_line = std.mem.trim(u8, line, "\" \t");
                in_doc = !(line.len > 3 and std.mem.endsWith(u8, line, "\"\"\""));
            } else {
                in_doc = false;
            }
            continue;
        }
        if (in_doc) {
            if (doc_line.len == 0) doc_line = std.mem.trim(u8, line, " \t");
            continue;
        }

        if (lineStartsBlock(line)) |name| {
            const this_start = doc_start orelse line_off;
            if (current) |prev_name| {
                if (count < blocks.len) {
                    blocks[count] = .{ .name = prev_name, .text = schema_sdl[block_start..this_start], .doc = pending_doc };
                    count += 1;
                }
            }
            block_start = this_start;
            pending_doc = doc_line;
            current = name;
            doc_start = null;
            doc_line = "";
        }
    }
    if (current) |prev_name| {
        if (count < blocks.len) {
            blocks[count] = .{ .name = prev_name, .text = schema_sdl[block_start..], .doc = pending_doc };
            count += 1;
        }
    }
    return count;
}

fn callGetSchema(allocator: std.mem.Allocator, id: std.json.Value, args: ?std.json.Value) ![]u8 {
    var wanted: ?[]const u8 = null;
    if (args) |a| {
        if (a == .object) {
            if (a.object.get("type")) |tv| {
                if (tv != .string) return try toolError(allocator, id, "type must be a string");
                wanted = tv.string;
            }
        }
    }

    var blocks: [256]SchemaBlock = undefined;
    const n = sectionSchema(&blocks);

    var text: std.Io.Writer.Allocating = .init(allocator);
    defer text.deinit();

    if (wanted) |want| {
        for (blocks[0..n]) |b| {
            if (std.mem.eql(u8, b.name, want)) {
                try text.writer.writeAll(std.mem.trim(u8, b.text, "\n"));
                try text.writer.writeAll("\n");
                const owned = try text.toOwnedSlice();
                defer allocator.free(owned);
                return try toolTextResult(allocator, id, owned, false);
            }
        }
        return try toolError(allocator, id, "unknown type — call get-graphql-schema with no arguments for the index");
    }

    for (blocks[0..n]) |b| {
        try text.writer.writeAll(b.name);
        if (b.doc.len > 0) {
            try text.writer.writeAll(" — ");
            try text.writer.writeAll(b.doc);
        }
        try text.writer.writeAll("\n");
    }
    const owned = try text.toOwnedSlice();
    defer allocator.free(owned);
    return try toolTextResult(allocator, id, owned, false);
}

// ---------------------------------------------------------------------------
// Resources
// ---------------------------------------------------------------------------

fn handleResourcesList(allocator: std.mem.Allocator, id: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var o = try beginResponse(&out.writer, allocator, id);
    var result = try o.beginObject("result");
    var resources = try result.beginArray("resources");
    {
        var r = try resources.beginObject();
        try r.fieldStr("uri", "ensv2://examples", allocator);
        try r.fieldStr("name", "examples", allocator);
        try r.fieldStr("description", "Known-good GraphQL queries with intents, verified by the conformance suite", allocator);
        try r.fieldStr("mimeType", "text/markdown", allocator);
        try r.end();
    }
    {
        var r = try resources.beginObject();
        try r.fieldStr("uri", "ensv2://coverage", allocator);
        try r.fieldStr("name", "coverage", allocator);
        try r.fieldStr("description", "Live indexing coverage and finality snapshot (data freshness)", allocator);
        try r.fieldStr("mimeType", "application/json", allocator);
        try r.end();
    }
    try resources.end();
    try result.end();
    try o.end();
    return try out.toOwnedSlice();
}

fn handleResourcesRead(allocator: std.mem.Allocator, id: std.json.Value, params: ?std.json.Value, executor: Executor) ![]u8 {
    const p = params orelse return try rpcError(allocator, id, -32602, "invalid params: missing uri");
    if (p != .object) return try rpcError(allocator, id, -32602, "invalid params: expected object");
    const uri_val = p.object.get("uri") orelse return try rpcError(allocator, id, -32602, "invalid params: missing uri");
    if (uri_val != .string) return try rpcError(allocator, id, -32602, "invalid params: uri must be a string");
    const uri = uri_val.string;

    if (std.mem.eql(u8, uri, "ensv2://examples")) {
        return try resourceTextResult(allocator, id, uri, "text/markdown", EXAMPLES_MARKDOWN);
    } else if (std.mem.eql(u8, uri, "ensv2://coverage")) {
        const result_json = executor.run(executor.ctx, allocator, COVERAGE_QUERY, null) catch {
            return try rpcError(allocator, id, -32603, "coverage query failed");
        };
        defer allocator.free(result_json);
        return try resourceTextResult(allocator, id, uri, "application/json", result_json);
    }
    return try rpcError(allocator, id, -32602, "unknown resource uri");
}

// ---------------------------------------------------------------------------
// JSON-RPC plumbing
// ---------------------------------------------------------------------------

fn writeId(o: anytype, id: std.json.Value, allocator: std.mem.Allocator) !void {
    switch (id) {
        .integer => |n| try o.fieldInt("id", n),
        .string => |s| try o.fieldStr("id", s, allocator),
        else => try o.fieldNull("id"),
    }
}

fn beginResponse(writer: anytype, allocator: std.mem.Allocator, id: std.json.Value) !jw.Object(@TypeOf(writer)) {
    var o = try jw.objectOn(writer);
    try o.fieldStr("jsonrpc", "2.0", allocator);
    try writeId(&o, id, allocator);
    return o;
}

fn rpcResultRaw(allocator: std.mem.Allocator, id: std.json.Value, raw: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var o = try beginResponse(&out.writer, allocator, id);
    try o.fieldRaw("result", raw);
    try o.end();
    return try out.toOwnedSlice();
}

fn rpcError(allocator: std.mem.Allocator, id: std.json.Value, code: i32, message: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var o = try beginResponse(&out.writer, allocator, id);
    var e = try o.beginObject("error");
    try e.fieldInt("code", code);
    try e.fieldStr("message", message, allocator);
    try e.end();
    try o.end();
    return try out.toOwnedSlice();
}

/// Tool result envelope: {content:[{type:"text",text:...}], isError}.
fn toolTextResult(allocator: std.mem.Allocator, id: std.json.Value, text: []const u8, is_error: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var o = try beginResponse(&out.writer, allocator, id);
    var result = try o.beginObject("result");
    var content = try result.beginArray("content");
    var item = try content.beginObject();
    try item.fieldStr("type", "text", allocator);
    try item.fieldStr("text", text, allocator);
    try item.end();
    try content.end();
    try result.fieldBool("isError", is_error);
    try result.end();
    try o.end();
    return try out.toOwnedSlice();
}

/// Tool-level failure (bad arguments, execution failure): still a successful
/// JSON-RPC response, with isError=true — per MCP the agent sees the message.
fn toolError(allocator: std.mem.Allocator, id: std.json.Value, message: []const u8) ![]u8 {
    return try toolTextResult(allocator, id, message, true);
}

fn resourceTextResult(allocator: std.mem.Allocator, id: std.json.Value, uri: []const u8, mime: []const u8, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var o = try beginResponse(&out.writer, allocator, id);
    var result = try o.beginObject("result");
    var contents = try result.beginArray("contents");
    var item = try contents.beginObject();
    try item.fieldStr("uri", uri, allocator);
    try item.fieldStr("mimeType", mime, allocator);
    try item.fieldStr("text", text, allocator);
    try item.end();
    try contents.end();
    try result.end();
    try o.end();
    return try out.toOwnedSlice();
}
