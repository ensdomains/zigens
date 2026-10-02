//! MCP (Model Context Protocol) endpoint — agents discover, connect to, and
//! query ENSv2 through the standard agent protocol, with GraphQL as the
//! primary interface (taught via the `graphql-query` tool's primer, not
//! templated).
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
const ens_normalize = @import("../utils/ens_normalize.zig");
const jw = @import("../lib/graphql/json_writer.zig");
const http_util = @import("http_util.zig");
const Server = @import("server.zig").Server;

/// Revisions we can actually serve, newest first. Nothing in the implemented
/// method set is specific to the newest one — the content array, isError, ping
/// and resources all exist in 2024-11-05 — so refusing an older client bought
/// nothing and made the endpoint unreachable for the many hosts still defaulting
/// to an earlier revision.
pub const SUPPORTED_PROTOCOL_VERSIONS = [_][]const u8{ "2025-06-18", "2025-03-26", "2024-11-05" };
pub const PROTOCOL_VERSION = SUPPORTED_PROTOCOL_VERSIONS[0];

/// Echo the client's proposed revision when we speak it, else offer our newest
/// and let the client decide (the spec's flow). A missing or malformed `params`
/// is not an error here: the client simply gets our default.
fn negotiateProtocolVersion(params: ?std.json.Value) []const u8 {
    const p = params orelse return PROTOCOL_VERSION;
    if (p != .object) return PROTOCOL_VERSION;
    const v = p.object.get("protocolVersion") orelse return PROTOCOL_VERSION;
    if (v != .string) return PROTOCOL_VERSION;
    for (SUPPORTED_PROTOCOL_VERSIONS) |supported| {
        if (std.mem.eql(u8, supported, v.string)) return supported;
    }
    return PROTOCOL_VERSION;
}
/// What the /mcp route should do with a request. Decided here, without a socket
/// or a Server, because no test lane constructs one — so these three gates were
/// previously exercised by nothing at all, which is also where the body-framing
/// panic lived.
pub const Route = enum {
    /// Disabled: 404, indistinguishable from an unrouted path.
    disabled,
    /// An operator configured an Origin allow-list and this browser request falls
    /// outside it: 403. Unreachable when the list is unset.
    origin_rejected,
    /// Streamable HTTP requires 405 — not 400 — when the endpoint offers no SSE
    /// stream, so a client can tell "stay in JSON mode" from a transport failure.
    /// OPTIONS never reaches here; CORS preflight is answered before routing.
    method_not_allowed,
    /// The client named a revision we do not speak in `MCP-Protocol-Version`.
    /// 2025-06-18: "If the server receives a request with an invalid or
    /// unsupported MCP-Protocol-Version, it MUST respond with 400 Bad Request."
    bad_protocol_version,
    /// POST from an acceptable origin: hand the body to processMcp.
    handle,
};

/// Gate order is deliberate: a disabled endpoint reveals nothing, then origin,
/// then method — so a browser blocked by the allow-list is told its origin is
/// the problem rather than its verb.
pub fn route(enabled: bool, method: []const u8, request: []const u8, allowed_origins: ?[]const u8) Route {
    if (!enabled) return .disabled;
    if (!http_util.originAllowed(request, allowed_origins)) return .origin_rejected;
    if (!std.mem.eql(u8, method, "POST")) return .method_not_allowed;
    // Only checked when the client sends it. Its absence is not an error: the
    // spec says to assume 2025-03-26, which we speak.
    if (http_util.findHeaderValue(request, "mcp-protocol-version")) |v| {
        if (!protocolVersionSupported(v)) return .bad_protocol_version;
    }
    return .handle;
}

/// True when `version` names a revision this server implements.
pub fn protocolVersionSupported(version: []const u8) bool {
    for (SUPPORTED_PROTOCOL_VERSIONS) |supported| {
        if (std.mem.eql(u8, supported, version)) return true;
    }
    return false;
}

pub const SERVER_NAME = "ensv2-indexer";
pub const SERVER_VERSION = "0.1.0";

/// Transport-free query runner: prod wraps Server.executeQuery, tests wrap a
/// GraphQLHandler over a seeded test database. Returns allocator-owned
/// response JSON.
pub const Executor = struct {
    ctx: *anyopaque,
    /// `operation_name` is forwarded because the executor REQUIRES it for a
    /// document carrying more than one operation (error.OperationNameRequired →
    /// "Must provide operation name when query contains multiple operations").
    /// Hardcoding null meant the agent was told to supply an argument the tool
    /// had no slot for — an instruction it could not act on.
    run: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, query: []const u8, variables: ?std.json.Value, operation_name: ?[]const u8) anyerror![]u8,
};

const GRAPHQL_QUERY_PRIMER =
    "Query the ENSv2 indexer with GraphQL. Read-only. " ++
    "ENTRY POINTS: domains(where, first, skip, orderBy, orderDirection) lists/filters domains; " ++
    "domain(id) fetches one domain by name or namehash (domain(id:\"alice.eth\") works; single-domain lookups include live on-chain resolution when the deployment enables it); " ++
    "registrations(...) is registration history (orderBy: registrationDate | expiryDate | name); " ++
    "accounts(...) / account(id: \"0x…address\") are owners and their domains; " ++
    "events(...) are raw indexed events; _finality / _coverage report the indexing head, safe/finalized blocks, and staleness. " ++
    "CONVENTIONS: filters go in where:{...} with suffixed operators (name_in:[...], name_contains:\"…\", expiryDate_gt: <unix seconds>, owner:\"0x…\"). " ++
    "`registrant` is a RegistrationFilter field, NOT a DomainFilter one — filter domains by owner. " ++
    "Paginate with first/skip (keep first <= 100). NESTED list fields are paginated too and some default to as few as 10 — always pass first explicitly and compare against the matching count field (e.g. subdomainCount) before assuming a list is complete. " ++
    "protocol is \"v1\" (legacy ENS) or \"v2\"; the same name can exist in both. " ++
    "PITFALLS: (1) resolver { texts } returns record KEYS only — read a value with text(key:\"…\"). " ++
    "(2) Listings hide unnormalized and unreachable names by default; pass them INSIDE the filter — where:{includeUnnormalized:true, includeUnreachable:true} — because an unknown TOP-LEVEL argument is a hard validation error. " ++
    "(3) List queries return INDEXED data only. " ++
    "(4) Expensive queries are rejected by a complexity limit — select only the fields you need. " ++
    "(5) On a syntax or validation error the response includes line/column locations — fix and retry once. " ++
    "Call get-graphql-schema for exact types and fields; read the examples resource for known-good queries.";

const GET_SCHEMA_DESCRIPTION =
    "Look up the exact GraphQL type definitions behind graphql-query. " ++
    "Without arguments: a compact index of every type name with its description. " ++
    "With {\"type\":\"Domain\"}: that type's full SDL definition (fields, arguments, docs). " ++
    "Pull only the types you need — there is no full-schema dump.";

/// Known-good queries. Every one is executed against the fixture database by
/// mcp_test.zig, so a schema change that invalidates an example breaks the test
/// instead of silently handing an agent a query that no longer works. The test
/// asserts EXECUTABILITY, not output — these are not golden-compared.
const RESOLVE_NAME_DESCRIPTION =
    "Resolve one ENS name: current address, resolver, and requested text records, " ++
    "via the single-name resolution path (ENSIP-10 inheritance; live on-chain fallback " ++
    "when the deployment enables it). Prefer this over hand-written queries for " ++
    "\"what does X resolve to\". Requested text records come back as fields t0..tN " ++
    "in the order given. Returns the standard GraphQL response for the composed lookup.";

pub const EXAMPLES_MARKDOWN =
    \\# ENSv2 GraphQL examples (every one is executed by the test suite)
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
    \\Domains owned by an address (nested lists are paginated — ask for what you need):
    \\```graphql
    \\{ account(id:"0x1111111111111111111111111111111111111111"){ domains(first:100){ name expiryDate } } }
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
    const body = http_util.requestBody(request) orelse {
        return try self.sendJsonResponse(conn, 400, "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"missing request body\"}}");
    };

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
    fn run(ctx: *anyopaque, allocator: std.mem.Allocator, query: []const u8, variables: ?std.json.Value, operation_name: ?[]const u8) anyerror![]u8 {
        // The server allocator owns the result; callers free with the same one
        // they pass here, so the two must be the same allocator. An ERROR rather
        // than std.debug.assert: assertions are live in ReleaseSafe, which is what
        // the Dockerfile ships, so a mismatch would abort the whole API process
        // instead of failing the one request that caused it.
        const self: *ProdExecutor = @ptrCast(@alignCast(ctx));
        if (allocator.ptr != self.server.allocator.ptr) return error.McpAllocatorMismatch;
        return self.server.executeQuery(query, variables, operation_name, false);
    }
};

// ---------------------------------------------------------------------------
// Protocol core (transport-free, testable)
// ---------------------------------------------------------------------------

/// Largest batch we will execute.
///
/// This is a rate-limit question, not a parsing one. The per-IP limiter charges
/// ONE token per HTTP request, so a batch of N multiplies the work that token
/// buys by N — on an unauthenticated endpoint, with every element free to carry a
/// 10,000-character query. The 64KB body cap alone would allow hundreds. Real
/// clients batch a handful and the spec only requires accepting "one or more", so
/// a small cap costs nothing real and bounds the amplification at 8x.
pub const MAX_BATCH_ELEMENTS = 8;

/// Process one JSON-RPC message body. Returns the allocator-owned response
/// body, or null when there is nothing to answer (notifications only → HTTP
/// 202, no body).
///
/// A top-level ARRAY is a JSON-RPC batch. 2025-03-26 requires a server to take
/// one — "an array batching one or more requests and/or notifications" — and
/// 2025-06-18, which removed batching, still says a server receiving no
/// `MCP-Protocol-Version` header SHOULD assume 2025-03-26. Since `initialize`
/// answers with whichever of the three revisions the client proposed, rejecting
/// arrays would have advertised support we did not have.
pub fn processMcp(allocator: std.mem.Allocator, body: []const u8, executor: Executor) !?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return try rpcError(allocator, .null, -32700, "parse error: body is not valid JSON");
    };
    defer parsed.deinit();
    return switch (parsed.value) {
        .object => |obj| try processOne(allocator, obj, executor),
        .array => |arr| try processBatch(allocator, arr.items, executor),
        else => try rpcError(allocator, .null, -32600, "invalid request: expected a JSON-RPC object or batch array"),
    };
}

/// Run a batch and concatenate the responses that are owed. Notifications
/// contribute nothing, so a batch of only notifications answers like a single
/// one: null, which the caller turns into 202 with no body.
fn processBatch(allocator: std.mem.Allocator, items: []const std.json.Value, executor: Executor) !?[]u8 {
    if (items.len == 0)
        return try rpcError(allocator, .null, -32600, "invalid request: empty batch");
    if (items.len > MAX_BATCH_ELEMENTS)
        return try rpcError(allocator, .null, -32600, std.fmt.comptimePrint("invalid request: batch exceeds {d} elements", .{MAX_BATCH_ELEMENTS}));

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeByte('[');
    var answered: usize = 0;
    for (items) |item| {
        // A non-object element carries no id, so it cannot be a notification:
        // it gets an error response rather than being dropped silently.
        const one: ?[]u8 = switch (item) {
            .object => |o| try processOne(allocator, o, executor),
            else => try rpcError(allocator, .null, -32600, "invalid request: batch element is not a JSON-RPC object"),
        };
        if (one) |resp| {
            defer allocator.free(resp);
            if (answered > 0) try out.writer.writeByte(',');
            try out.writer.writeAll(resp);
            answered += 1;
        }
    }
    if (answered == 0) {
        out.deinit();
        return null;
    }
    try out.writer.writeByte(']');
    return try out.toOwnedSlice();
}

/// One already-parsed JSON-RPC message object.
fn processOne(allocator: std.mem.Allocator, obj: std.json.ObjectMap, executor: Executor) !?[]u8 {

    // The id is read BEFORE anything can fail, for two reasons. JSON-RPC requires
    // it echoed on every error where it is determinable — answering with
    // `"id":null` makes a client that keys pending requests by id drop the
    // response and wait out its timeout instead of failing fast. And a request
    // with no id is a NOTIFICATION, which the server must not answer at all,
    // even when it is malformed: validating `method` first meant a bad
    // notification got a full error response and a 200 body where the contract
    // says 202 and nothing.
    const id: std.json.Value = obj.get("id") orelse .null;
    if (obj.get("id") == null) {
        // notifications/initialized etc.: accept and ignore.
        return null;
    }

    if (obj.get("jsonrpc")) |v| {
        if (v != .string or !std.mem.eql(u8, v.string, "2.0")) {
            return try rpcError(allocator, id, -32600, "invalid request: jsonrpc must be \"2.0\"");
        }
    }

    const method_val = obj.get("method") orelse
        return try rpcError(allocator, id, -32600, "invalid request: missing method");
    if (method_val != .string)
        return try rpcError(allocator, id, -32600, "invalid request: method must be a string");
    const method = method_val.string;

    const params: ?std.json.Value = obj.get("params");

    if (std.mem.eql(u8, method, "initialize")) {
        return try handleInitialize(allocator, id, params);
    } else if (std.mem.eql(u8, method, "ping")) {
        return try rpcResultRaw(allocator, id, "{}");
    } else if (std.mem.eql(u8, method, "tools/list")) {
        return try handleToolsList(allocator, id);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        return try handleToolsCall(allocator, id, params, executor);
    } else if (std.mem.eql(u8, method, "resources/list")) {
        return try handleResourcesList(allocator, id);
    } else if (std.mem.eql(u8, method, "resources/templates/list")) {
        // Declaring the `resources` capability invites this call. We expose fixed
        // URIs rather than templates, so the answer is an empty list — a client
        // that got -32601 here recorded a protocol error against a server that
        // was working correctly.
        return try rpcResultRaw(allocator, id, "{\"resourceTemplates\":[]}");
    } else if (std.mem.eql(u8, method, "resources/read")) {
        return try handleResourcesRead(allocator, id, params, executor);
    }
    return try rpcError(allocator, id, -32601, "method not found");
}

fn handleInitialize(allocator: std.mem.Allocator, id: std.json.Value, params: ?std.json.Value) ![]u8 {
    const version = negotiateProtocolVersion(params);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var o = try beginResponse(&out.writer, allocator, id);
    var result = try o.beginObject("result");
    try result.fieldStr("protocolVersion", version, allocator);
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
            \\{"type":"object","properties":{"query":{"type":"string","description":"The GraphQL query document"},"variables":{"type":"object","description":"Optional GraphQL variables"},"operationName":{"type":"string","description":"Required when the document contains more than one operation"}},"required":["query"]}
        );
        try t.end();
    }
    {
        var t = try tools.beginObject();
        try t.fieldStr("name", "get-graphql-schema", allocator);
        try t.fieldStr("description", GET_SCHEMA_DESCRIPTION, allocator);
        try t.fieldRaw("inputSchema",
            \\{"type":"object","additionalProperties":false,"properties":{"type":{"type":"string","description":"A type name from the index, e.g. Domain"}}}
        );
        try t.end();
    }

    {
        var t = try tools.beginObject();
        try t.fieldStr("name", "resolve-name", allocator);
        try t.fieldStr("description", RESOLVE_NAME_DESCRIPTION, allocator);
        try t.fieldRaw("inputSchema",
            \\{"type":"object","properties":{"name":{"type":"string","description":"ENS name, e.g. alice.eth"},"texts":{"type":"array","items":{"type":"string"},"description":"Text-record keys to include, e.g. [\"avatar\",\"com.twitter\"]"}},"required":["name"]}
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
    } else if (std.mem.eql(u8, tool, "resolve-name")) {
        return try callResolveName(allocator, id, args, executor);
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
    // The schema declares no Mutation type today, so nothing is reachable through
    // this — which is exactly why the guard belongs here rather than later.
    // NOTHING in the execution pipeline inspects the operation type, so the day a
    // Mutation type is added it would be writable through this unauthenticated
    // endpoint with no further change. Refuse by operation, not by what the schema
    // currently happens to contain.
    if (http_util.queryIsMutation(allocator, query)) {
        return try toolError(allocator, id, "this endpoint is read-only; only query operations are accepted");
    }
    const variables: ?std.json.Value = if (a.object.get("variables")) |v| blk: {
        if (v == .object) break :blk v;
        if (v == .null) break :blk null;
        return try toolError(allocator, id, "variables must be an object");
    } else null;

    const operation_name: ?[]const u8 = if (a.object.get("operationName")) |ov| blk: {
        if (ov == .null) break :blk null;
        if (ov != .string) return try toolError(allocator, id, "operationName must be a string");
        break :blk ov.string;
    } else null;
    const result_json = executor.run(executor.ctx, allocator, query, variables, operation_name) catch {
        return try toolError(allocator, id, "query execution failed");
    };
    defer allocator.free(result_json);

    // Tool-level isError only for pure error responses (no data at all) —
    // partial results (data + errors) are successes the agent should read.
    const is_error = graphqlResponseIsPureError(allocator, result_json);
    return try toolTextResult(allocator, id, result_json, is_error);
}

/// The one convenience tool: composes the curated single-name lookup over
/// domain(id:) — the field that carries live ENSIP-10 resolution when the
/// deployment enables it — so agents get authoritative answers without
/// knowing the resolution model. Everything still runs through the shared
/// GraphQL pipeline; this tool only knows WHICH query to write.
fn callResolveName(allocator: std.mem.Allocator, id: std.json.Value, args: ?std.json.Value, executor: Executor) ![]u8 {
    const a = args orelse return try toolError(allocator, id, "missing arguments: {\"name\":\"alice.eth\"} required");
    if (a != .object) return try toolError(allocator, id, "arguments must be an object");
    const name_val = a.object.get("name") orelse return try toolError(allocator, id, "missing required argument: name");
    if (name_val != .string) return try toolError(allocator, id, "name must be a string");
    const raw_name = name_val.string;
    if (raw_name.len == 0 or raw_name.len > 255) return try toolError(allocator, id, "name must be 1-255 characters");

    // ENSIP-15 normalise before looking anything up. The indexer stores and
    // hashes normalised names, so querying the raw input made "Alice.ETH" — and
    // anything with unicode confusables or a mixed-case label — answer "does not
    // exist" for a name that does exist. A caller passing an already-normalised
    // name is unaffected: normalisation is idempotent.
    // Labels are stored and hashed as the RAW bytes the chain emitted, so the
    // index legitimately holds names that are NOT ENSIP-15 normalisable. Hard
    // erroring on those made a name the indexer actually has unreachable through
    // this tool, so an unnormalisable input falls back to a verbatim lookup — the
    // normalisation still fixes "Alice.ETH", it just no longer refuses what it
    // cannot normalise.
    var norm = ens_normalize.normalizeName(allocator, raw_name);
    defer norm.deinit(allocator);
    const name = if (norm.is_valid and norm.normalized != null) norm.normalized.? else raw_name;

    var q: std.Io.Writer.Allocating = .init(allocator);
    defer q.deinit();
    try q.writer.writeAll("{ domain(id:\"");
    writeGraphqlString(&q.writer, name) catch {
        return try toolError(allocator, id, "name contains control characters");
    };
    try q.writer.writeAll("\"){ name protocol expiryDate resolvedAddress resolver { address addr");

    if (a.object.get("texts")) |tv| {
        if (tv != .array) return try toolError(allocator, id, "texts must be an array of record keys");
        if (tv.array.items.len > 16) return try toolError(allocator, id, "texts: at most 16 keys per call");
        for (tv.array.items, 0..) |item, i| {
            if (item != .string) return try toolError(allocator, id, "texts entries must be strings");
            const key = item.string;
            if (key.len == 0 or key.len > 80) return try toolError(allocator, id, "texts keys must be 1-80 characters");
            try q.writer.print(" t{d}: text(key:\"", .{i});
            writeGraphqlString(&q.writer, key) catch {
                return try toolError(allocator, id, "text key contains control characters");
            };
            try q.writer.writeAll("\")");
        }
    }
    try q.writer.writeAll(" } } }");

    const composed = try q.toOwnedSlice();
    defer allocator.free(composed);
    const result_json = executor.run(executor.ctx, allocator, composed, null, null) catch {
        return try toolError(allocator, id, "resolution query failed");
    };
    defer allocator.free(result_json);
    const is_error = graphqlResponseIsPureError(allocator, result_json);
    return try toolTextResult(allocator, id, result_json, is_error);
}

/// GraphQL string-literal escaping for agent-supplied values embedded in a
/// composed query: backslash and quote are escaped, control characters are
/// rejected outright — the composed document can never be re-shaped by input.
fn writeGraphqlString(w: anytype, s: []const u8) !void {
    for (s) |c| {
        if (c < 0x20) return error.ControlCharacter;
        if (c == '\\' or c == '"') try w.writeByte('\\');
        try w.writeByte(c);
    }
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
/// block belongs to it. Comptime-fixed capacity: the schema has well under 256
/// top-level types. Growth past that silently truncates the index, so the cap is
/// asserted by a test ("the schema fits the section buffer") rather than by the
/// build-time guard an earlier comment here claimed but never had.
pub fn sectionSchema(blocks: *[256]SchemaBlock) usize {
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
    // Every malformed shape used to fall through to `wanted == null` and return
    // the whole type index with isError:false — so `{"arguments":"Domain"}` or a
    // one-character typo like `{"typ":"Domain"}` handed an agent a type list and
    // told it the call succeeded. graphql-query and resolve-name both reject a
    // non-object `arguments` explicitly; this now matches them, and an unknown
    // key is named rather than ignored.
    var wanted: ?[]const u8 = null;
    if (args) |a| {
        if (a != .object) return try toolError(allocator, id, "arguments must be an object");
        var it = a.object.iterator();
        while (it.next()) |entry| {
            if (!std.mem.eql(u8, entry.key_ptr.*, "type")) {
                return try toolError(allocator, id, "unknown argument — get-graphql-schema takes only `type`");
            }
        }
        if (a.object.get("type")) |tv| {
            if (tv != .string) return try toolError(allocator, id, "type must be a string");
            wanted = tv.string;
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
        try r.fieldStr("description", "Known-good GraphQL queries with intents, each executed by the test suite", allocator);
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
        const result_json = executor.run(executor.ctx, allocator, COVERAGE_QUERY, null, null) catch {
            return try rpcError(allocator, id, -32603, "coverage query failed");
        };
        defer allocator.free(result_json);
        return try resourceTextResult(allocator, id, uri, "application/json", result_json);
    }
    // -32002 is MCP's "resource not found", distinct from a malformed params
    // object; clients branch on it to re-list rather than treating it as a bug.
    return try rpcError(allocator, id, -32002, "resource not found");
}

// ---------------------------------------------------------------------------
// JSON-RPC plumbing
// ---------------------------------------------------------------------------

fn writeId(o: anytype, id: std.json.Value, allocator: std.mem.Allocator) !void {
    switch (id) {
        .integer => |n| try o.fieldInt("id", n),
        .string => |str| try o.fieldStr("id", str, allocator),
        // JSON-RPC allows ANY number as an id. Flattening a float or an
        // out-of-i64 value to null leaves the client unable to match the response
        // to its request — the same failure the id-echoing fix exists to prevent.
        // Both of these came from the JSON parser, so both are valid JSON numbers.
        .float => |f| {
            var buf: [64]u8 = undefined;
            if (std.fmt.bufPrint(&buf, "{d}", .{f})) |txt| {
                try o.fieldRaw("id", txt);
            } else |_| {
                try o.fieldNull("id");
            }
        },
        .number_string => |ns| try o.fieldRaw("id", ns),
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

test "the schema fits the section buffer" {
    // sectionSchema writes into a fixed [256]SchemaBlock. Past that it would
    // silently truncate the type index, so the headroom is asserted here rather
    // than left to a build-time guard that never existed.
    var blocks: [256]SchemaBlock = undefined;
    const n = sectionSchema(&blocks);
    try std.testing.expect(n > 0);
    try std.testing.expect(n < blocks.len);
}

test "negotiateProtocolVersion echoes a supported revision and falls back otherwise" {
    const parse = struct {
        fn p(a: std.mem.Allocator, body: []const u8) !std.json.Parsed(std.json.Value) {
            return std.json.parseFromSlice(std.json.Value, a, body, .{});
        }
    }.p;
    const a = std.testing.allocator;

    // Every advertised revision is echoed back, not overridden.
    for (SUPPORTED_PROTOCOL_VERSIONS) |want| {
        const body = try std.fmt.allocPrint(a, "{{\"protocolVersion\":\"{s}\"}}", .{want});
        defer a.free(body);
        var parsed = try parse(a, body);
        defer parsed.deinit();
        try std.testing.expectEqualStrings(want, negotiateProtocolVersion(parsed.value));
    }

    // An unknown revision gets our newest, so the client can decide.
    var unknown = try parse(a, "{\"protocolVersion\":\"1999-01-01\"}");
    defer unknown.deinit();
    try std.testing.expectEqualStrings(PROTOCOL_VERSION, negotiateProtocolVersion(unknown.value));

    // Missing, non-object and non-string params are not errors — they default.
    try std.testing.expectEqualStrings(PROTOCOL_VERSION, negotiateProtocolVersion(null));
    var not_obj = try parse(a, "\"nope\"");
    defer not_obj.deinit();
    try std.testing.expectEqualStrings(PROTOCOL_VERSION, negotiateProtocolVersion(not_obj.value));
    var not_str = try parse(a, "{\"protocolVersion\":7}");
    defer not_str.deinit();
    try std.testing.expectEqualStrings(PROTOCOL_VERSION, negotiateProtocolVersion(not_str.value));
}

test "route: the three gates, in order, without a socket" {
    const post = "POST /mcp HTTP/1.1\r\nHost: x\r\n\r\n{}";
    const get = "GET /mcp HTTP/1.1\r\nHost: x\r\n\r\n";
    const post_evil = "POST /mcp HTTP/1.1\r\nOrigin: https://evil.test\r\n\r\n{}";

    // Disabled wins over everything and reveals nothing.
    try std.testing.expectEqual(Route.disabled, route(false, "POST", post, null));
    try std.testing.expectEqual(Route.disabled, route(false, "GET", get, "https://app.test"));

    // Enabled, no allow-list: POST handled, anything else 405 (not 400 — a
    // conformant client reads 405 as "no SSE stream here").
    try std.testing.expectEqual(Route.handle, route(true, "POST", post, null));
    try std.testing.expectEqual(Route.method_not_allowed, route(true, "GET", get, null));
    try std.testing.expectEqual(Route.method_not_allowed, route(true, "DELETE", get, null));

    // With a list, origin is checked BEFORE method, so a blocked browser learns
    // the origin is the problem rather than the verb.
    try std.testing.expectEqual(Route.origin_rejected, route(true, "POST", post_evil, "https://app.test"));
    try std.testing.expectEqual(Route.origin_rejected, route(true, "GET", "GET /mcp HTTP/1.1\r\nOrigin: https://evil.test\r\n\r\n", "https://app.test"));

    // A client that sends no Origin is unaffected by the list — that is every
    // CLI and agent caller, i.e. the normal case.
    try std.testing.expectEqual(Route.handle, route(true, "POST", post, "https://app.test"));
}

test "route: an unsupported MCP-Protocol-Version header is a 400, a supported one is not" {
    const with = struct {
        fn hdr(comptime v: []const u8) []const u8 {
            return "POST /mcp HTTP/1.1\r\nHost: x\r\nMCP-Protocol-Version: " ++ v ++ "\r\n\r\n{}";
        }
    };

    // Every revision we answer in `initialize` must also be accepted here, or a
    // client that follows the spec ("send the version you negotiated") would be
    // 400'd by the very server that chose it.
    inline for (SUPPORTED_PROTOCOL_VERSIONS) |v| {
        try std.testing.expectEqual(Route.handle, route(true, "POST", with.hdr(v), null));
    }

    // Unsupported or malformed: 400, which the spec words as a MUST.
    try std.testing.expectEqual(Route.bad_protocol_version, route(true, "POST", with.hdr("2099-01-01"), null));
    try std.testing.expectEqual(Route.bad_protocol_version, route(true, "POST", with.hdr("garbage"), null));
    try std.testing.expectEqual(Route.bad_protocol_version, route(true, "POST", with.hdr(""), null));

    // Header absent: NOT an error. The spec says assume 2025-03-26, which we
    // speak, so the request is handled exactly as before this gate existed.
    try std.testing.expectEqual(Route.handle, route(true, "POST", "POST /mcp HTTP/1.1\r\nHost: x\r\n\r\n{}", null));

    // The header is case-insensitive and its value is trimmed, as any header is.
    try std.testing.expectEqual(Route.handle, route(true, "POST", "POST /mcp HTTP/1.1\r\nmcp-protocol-version:  2025-06-18 \r\n\r\n{}", null));

    // Gate order: a disabled endpoint and a bad origin still win over it, so the
    // header can never be used to probe a disabled or walled-off endpoint.
    try std.testing.expectEqual(Route.disabled, route(false, "POST", with.hdr("2099-01-01"), null));
    try std.testing.expectEqual(
        Route.origin_rejected,
        route(true, "POST", "POST /mcp HTTP/1.1\r\nOrigin: https://evil.test\r\nMCP-Protocol-Version: 2099-01-01\r\n\r\n{}", "https://app.test"),
    );
}

test "protocolVersionSupported agrees with the advertised list" {
    inline for (SUPPORTED_PROTOCOL_VERSIONS) |v| try std.testing.expect(protocolVersionSupported(v));
    try std.testing.expect(!protocolVersionSupported("2099-01-01"));
    try std.testing.expect(!protocolVersionSupported(""));
    try std.testing.expect(!protocolVersionSupported("2025-06-18 "));
}
