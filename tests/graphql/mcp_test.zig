//! MCP protocol tests: drive the transport-free core (processMcp) with a
//! real GraphQLHandler over a seeded database — full JSON-RPC framing, tool
//! dispatch, and error mapping, no sockets.

const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers");
const lib = @import("lib");
const mcp = lib.api.mcp;
const GraphQLHandler = lib.api.handler.GraphQLHandler;
const models = lib.models;
const Address = lib.Address;
const Hash = lib.Hash;

const TestExec = struct {
    handler: *GraphQLHandler,
    database: *lib.Database,

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator, query: []const u8, variables: ?std.json.Value, operation_name: ?[]const u8) anyerror![]u8 {
        _ = allocator;
        const self: *TestExec = @ptrCast(@alignCast(ctx));
        return self.handler.handleQuery(self.database, query, variables, operation_name, false);
    }

    fn executor(self: *TestExec) mcp.Executor {
        return .{ .ctx = self, .run = run };
    }
};

fn fixtureName(a: std.mem.Allocator, n: u8, name_str: []const u8, label: []const u8) !models.Name {
    return models.Name{
        .protocol = .v2,
        .name = name_str,
        .namehash = try lib.namehash(a, name_str),
        .label = label,
        .label_hash = try lib.labelhash(a, label),
        .parent_name = "eth",
        .parent_namehash = try lib.namehash(a, "eth"),
        .registry = Address{ .bytes = [_]u8{0xC1} ** 20 },
        .owner = Address{ .bytes = [_]u8{0xA1} ** 20 },
        .registrant = Address{ .bytes = [_]u8{0xA1} ** 20 },
        .resolver = Address.zero,
        .token_id = n,
        .canonical_id = n,
        .token_version = 1,
        .expiry = 0,
        .registry_locked = false,
        .migrated = false,
        .created_block = 100,
        .created_at = 1700000000,
        .registered_at = 1700000000,
        .updated_block = 100,
        .updated_at = 1700000000,
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    };
}

const Fixture = struct {
    database: *lib.Database,
    handler: GraphQLHandler,
    exec: TestExec,

    fn init(allocator: std.mem.Allocator) !*Fixture {
        const self = try allocator.create(Fixture);
        errdefer allocator.destroy(self);
        self.database = try helpers.createTestDatabase(allocator);
        errdefer helpers.destroyTestDatabase(allocator, self.database);
        try self.database.insertName(try fixtureName(allocator, 1, "solo.eth", "solo"));
        self.handler = try GraphQLHandler.init(allocator, 30, 100000, false);
        self.exec = .{ .handler = &self.handler, .database = self.database };
        return self;
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.handler.deinit();
        helpers.destroyTestDatabase(allocator, self.database);
        allocator.destroy(self);
    }
};

fn call(fx: *Fixture, allocator: std.mem.Allocator, body: []const u8) !?[]u8 {
    return mcp.processMcp(allocator, body, fx.exec.executor());
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected to find '{s}' in: {s}\n", .{ needle, haystack });
        return error.MissingSubstring;
    }
}

test "initialize returns pinned protocol version and server info" {
    const allocator = testing.allocator;
    const fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    const resp = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(resp);
    try expectContains(resp, "\"protocolVersion\":\"2025-06-18\"");
    try expectContains(resp, "\"name\":\"ensv2-indexer\"");
    try expectContains(resp, "\"id\":1");
}

test "notifications get no response body" {
    const allocator = testing.allocator;
    const fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    const resp = try call(fx, allocator,
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    );
    try testing.expectEqual(@as(?[]u8, null), resp);
}

test "protocol errors: malformed JSON, non-object, unknown method" {
    const allocator = testing.allocator;
    const fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    const bad = (try call(fx, allocator, "{not json")) orelse return error.ExpectedResponse;
    defer allocator.free(bad);
    try expectContains(bad, "-32700");

    const arr = (try call(fx, allocator, "[1,2]")) orelse return error.ExpectedResponse;
    defer allocator.free(arr);
    try expectContains(arr, "-32600");

    const unknown = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":7,"method":"prompts/list"}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(unknown);
    try expectContains(unknown, "-32601");
    try expectContains(unknown, "\"id\":7");
}

test "tools/list advertises both tools with the primer" {
    const allocator = testing.allocator;
    const fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    const resp = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(resp);
    try expectContains(resp, "\"graphql-query\"");
    try expectContains(resp, "\"get-graphql-schema\"");
    try expectContains(resp, "\"resolve-name\"");
    try expectContains(resp, "ENTRY POINTS");
    try expectContains(resp, "inputSchema");
}

test "graphql-query executes against the seeded database" {
    const allocator = testing.allocator;
    const fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    const resp = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"graphql-query","arguments":{"query":"{ domains(where:{name:\"solo.eth\"}){ name } }"}}}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(resp);
    try expectContains(resp, "solo.eth");
    try expectContains(resp, "\"isError\":false");
}

test "graphql-query surfaces syntax errors with locations as tool errors" {
    const allocator = testing.allocator;
    const fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    const resp = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"graphql-query","arguments":{"query":"{ domains( }"}}}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(resp);
    try expectContains(resp, "\"isError\":true");
    try expectContains(resp, "locations");
}

test "graphql-query argument validation" {
    const allocator = testing.allocator;
    const fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    const missing = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"graphql-query","arguments":{}}}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(missing);
    try expectContains(missing, "\"isError\":true");
    try expectContains(missing, "query");

    const unknown_tool = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"resolve-everything","arguments":{}}}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(unknown_tool);
    try expectContains(unknown_tool, "-32602");
}

test "get-graphql-schema: index lists types, type arg returns SDL, unknown type errors" {
    const allocator = testing.allocator;
    const fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    const index = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"get-graphql-schema","arguments":{}}}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(index);
    try expectContains(index, "Domain");
    try expectContains(index, "Registration");
    try expectContains(index, "\"isError\":false");

    const domain = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"get-graphql-schema","arguments":{"type":"Domain"}}}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(domain);
    try expectContains(domain, "type Domain");
    try expectContains(domain, "labelhash");

    const unknown = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"get-graphql-schema","arguments":{"type":"NoSuchType"}}}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(unknown);
    try expectContains(unknown, "\"isError\":true");
    try expectContains(unknown, "unknown type");
}

test "resources: list and read examples + coverage" {
    const allocator = testing.allocator;
    const fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    const list = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":11,"method":"resources/list"}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(list);
    try expectContains(list, "ensv2://examples");
    try expectContains(list, "ensv2://coverage");

    const examples = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":12,"method":"resources/read","params":{"uri":"ensv2://examples"}}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(examples);
    try expectContains(examples, "registrations(first:10");

    const coverage = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":13,"method":"resources/read","params":{"uri":"ensv2://coverage"}}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(coverage);
    try expectContains(coverage, "_coverage");

    const bad = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":14,"method":"resources/read","params":{"uri":"ensv2://nope"}}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(bad);
    // MCP's own "resource not found" code, not the generic invalid-params one:
    // clients branch on -32002 to re-list rather than reporting a server bug.
    try expectContains(bad, "-32002");
}

test "resolve-name resolves a seeded name and composes text aliases" {
    const allocator = testing.allocator;
    const fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    const resp = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"resolve-name","arguments":{"name":"solo.eth","texts":["avatar","com.twitter"]}}}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(resp);
    try expectContains(resp, "solo.eth");
    try expectContains(resp, "\"isError\":false");
}

test "resolve-name rejects injection and bad arguments" {
    const allocator = testing.allocator;
    const fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    // THE injection regression test. An injection-shaped name does not normalise,
    // so it falls through to a verbatim lookup — which means writeGraphqlString,
    // the actual escaping, is what has to hold, and this is what proves it does.
    //
    // Asserting "rejected by normalisation" instead would have been a weaker test
    // wearing stronger words: it would pass even if the escaping were removed
    // entirely, because the input would never reach it.
    const inj = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"resolve-name","arguments":{"name":"evil\") { registrations { name } } #.eth"}}}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(inj);
    // The attacker's selection must appear NOWHERE in the response — not as data,
    // and not echoed back inside a GraphQL parse error, which would mean the
    // composed document contained it.
    try testing.expect(std.mem.indexOf(u8, inj, "registrations") == null);
    // The document we sent stayed well-formed and simply matched no name: the
    // whole injection was consumed as one string literal.
    try expectContains(inj, "\\\"domain\\\":null");
    try testing.expect(std.mem.indexOf(u8, inj, "\\\"errors\\\"") == null);

    // Escaping has to survive the other operator-reachable string too: `texts`
    // keys are interpolated into the same document and never had a test.
    const inj_text = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":25,"method":"tools/call","params":{"name":"resolve-name","arguments":{"name":"solo.eth","texts":["avatar\") { registrations { name } } x(key:\"y"]}}}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(inj_text);
    try testing.expect(std.mem.indexOf(u8, inj_text, "registrations") == null);
    try expectContains(inj_text, "\"isError\":false");

    // Normalisation still does its job on the case it exists for: the indexer
    // stores normalised names, so an unnormalised input used to answer "no such
    // name" for a name that does exist.
    const mixed = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":24,"method":"tools/call","params":{"name":"resolve-name","arguments":{"name":"SOLO.ETH"}}}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(mixed);
    try expectContains(mixed, "\"isError\":false");
    try expectContains(mixed, "solo.eth");

    const missing = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"resolve-name","arguments":{}}}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(missing);
    try expectContains(missing, "\"isError\":true");

    const bad_texts = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":23,"method":"tools/call","params":{"name":"resolve-name","arguments":{"name":"solo.eth","texts":"avatar"}}}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(bad_texts);
    try expectContains(bad_texts, "\"isError\":true");
}

// The claim in mcp.zig's EXAMPLES_MARKDOWN doc comment, made real. Every fenced
// graphql block in the advertised examples is executed against the fixture
// database; a schema change that invalidates one breaks this test instead of
// silently handing an agent a query that no longer works.
test "every advertised example executes without a GraphQL error" {
    const allocator = testing.allocator;
    const fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    const md = mcp.EXAMPLES_MARKDOWN;
    var checked: usize = 0;
    var rest: []const u8 = md;
    while (std.mem.indexOf(u8, rest, "```graphql")) |open_at| {
        const after = rest[open_at + "```graphql".len ..];
        const nl = std.mem.indexOfScalar(u8, after, '\n') orelse break;
        const body = after[nl + 1 ..];
        const close_at = std.mem.indexOf(u8, body, "```") orelse break;
        const query = std.mem.trim(u8, body[0..close_at], " \n\r");
        rest = body[close_at + 3 ..];
        if (query.len == 0) continue;

        // Several examples are parameterised (`query($id:String!)`), so supply a
        // variables object covering the names they use. Extra variables are
        // harmless; a missing one is the "undefined variable" error we are
        // checking the examples do NOT have for schema reasons.
        var vars_parsed = try std.json.parseFromSlice(std.json.Value, allocator,
            \\{"id":"solo.eth"}
        , .{});
        defer vars_parsed.deinit();

        const res = try fx.handler.handleQuery(fx.database, query, vars_parsed.value, null, false);
        defer allocator.free(res);
        checked += 1;
        // A GraphQL error means the example no longer matches the schema.
        if (std.mem.indexOf(u8, res, "\"errors\"") != null) {
            std.debug.print("\nexample #{d} failed:\n  {s}\n  -> {s}\n", .{ checked, query, res });
            return error.ExampleQueryRejected;
        }
    }
    // Guard the extractor itself: if the fence format ever changes, this test
    // must fail loudly rather than quietly verify nothing.
    try testing.expect(checked >= 5);
}

test "initialize negotiates the protocol version instead of always answering its own" {
    const allocator = testing.allocator;
    const fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    // An older revision the server can speak is echoed, so the client stays.
    const old = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(old);
    try expectContains(old, "\"protocolVersion\":\"2024-11-05\"");

    // An unknown revision gets our newest, and the client decides.
    const future = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(future);
    try expectContains(future, "\"protocolVersion\":\"" ++ mcp.PROTOCOL_VERSION ++ "\"");

    // No params at all is still a valid initialize.
    const bare = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":3,"method":"initialize"}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(bare);
    try expectContains(bare, "\"protocolVersion\":\"" ++ mcp.PROTOCOL_VERSION ++ "\"");
}

test "an error echoes the request id, and a malformed notification is never answered" {
    const allocator = testing.allocator;
    const fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    // Missing method, but the id is determinable: JSON-RPC requires it echoed.
    // Answering "id":null makes a client that keys pending requests by id drop
    // the response and wait out its timeout.
    const no_method = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":7}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(no_method);
    try expectContains(no_method, "\"id\":7");
    try expectContains(no_method, "-32600");

    // A string id round-trips too.
    const str_id = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":"abc","method":"nope/nope"}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(str_id);
    try expectContains(str_id, "\"id\":\"abc\"");
    try expectContains(str_id, "-32601");

    // No id = notification: no response, even malformed. Previously a bad
    // notification got a full error body.
    try testing.expectEqual(@as(?[]u8, null), try call(fx, allocator, "{\"jsonrpc\":\"2.0\"}"));
    try testing.expectEqual(@as(?[]u8, null), try call(fx, allocator, "{\"jsonrpc\":\"2.0\",\"method\":123}"));
    try testing.expectEqual(@as(?[]u8, null), try call(fx, allocator,
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    ));

    // A wrong jsonrpc version is rejected, with the id echoed.
    const bad_ver = (try call(fx, allocator,
        \\{"jsonrpc":"1.0","id":9,"method":"ping"}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(bad_ver);
    try expectContains(bad_ver, "\"id\":9");
    try expectContains(bad_ver, "-32600");
}

test "get-graphql-schema rejects malformed arguments instead of returning the whole index" {
    const allocator = testing.allocator;
    const fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    // A string where an object belongs used to fall through and return the
    // 61-type index with isError:false — a plausible wrong answer.
    const not_obj = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"get-graphql-schema","arguments":"Domain"}}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(not_obj);
    try expectContains(not_obj, "\"isError\":true");

    // A one-character typo likewise.
    const typo = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":32,"method":"tools/call","params":{"name":"get-graphql-schema","arguments":{"typ":"Domain"}}}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(typo);
    try expectContains(typo, "\"isError\":true");

    // The index with no arguments at all is still a success.
    const index = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":33,"method":"tools/call","params":{"name":"get-graphql-schema"}}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(index);
    try expectContains(index, "\"isError\":false");
    try expectContains(index, "Domain");
}

test "graphql-query forwards operationName so a multi-operation document is answerable" {
    const allocator = testing.allocator;
    const fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    // Two operations and no name: the executor demands one. Before this was
    // plumbed, the agent was told to supply an argument the tool had no slot for.
    const unnamed = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":41,"method":"tools/call","params":{"name":"graphql-query","arguments":{"query":"query A { domains(first:1){ name } } query B { domains(first:1){ id } }"}}}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(unnamed);
    try expectContains(unnamed, "\"isError\":true");

    // Naming one makes it answerable.
    const named = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"graphql-query","arguments":{"query":"query A { domains(first:1){ name } } query B { domains(first:1){ id } }","operationName":"A"}}}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(named);
    try expectContains(named, "\"isError\":false");

    // And it is type-checked.
    const bad = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":43,"method":"tools/call","params":{"name":"graphql-query","arguments":{"query":"{ domains(first:1){ name } }","operationName":7}}}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(bad);
    try expectContains(bad, "\"isError\":true");
}

test "a JSON-RPC batch answers every request in one array, in order" {
    const allocator = testing.allocator;
    const fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    // 2025-03-26 requires a server to accept "an array batching one or more
    // requests and/or notifications", and 2025-06-18 tells a server that gets no
    // MCP-Protocol-Version header to assume 2025-03-26. Since initialize echoes
    // whichever revision the client proposed, a rejected array would have been a
    // promise we did not keep.
    // Deliberately NOT `initialize`: the lifecycle spec says the initialize
    // request MUST NOT be part of a batch, so batching it here would have pinned
    // a shape no conformant client may send.
    const body =
        \\[{"jsonrpc":"2.0","id":1,"method":"tools/list"},
        \\ {"jsonrpc":"2.0","id":"two","method":"resources/list"},
        \\ {"jsonrpc":"2.0","id":3,"method":"no/such/method"}]
    ;
    const resp = (try call(fx, allocator, body)).?;
    defer allocator.free(resp);

    try testing.expect(resp[0] == '[');
    try testing.expect(resp[resp.len - 1] == ']');
    // One response per request, ids preserved including a string id.
    try expectContains(resp, "\"id\":1");
    try expectContains(resp, "\"id\":\"two\"");
    try expectContains(resp, "\"id\":3");
    try expectContains(resp, "graphql-query");
    try expectContains(resp, "ensv2://examples");
    try expectContains(resp, "-32601");
    // The whole thing must be ONE well-formed array of exactly three response
    // objects — not three objects concatenated, and not a nested shape that
    // happens to contain the right substrings.
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .array);
    try testing.expectEqual(@as(usize, 3), parsed.value.array.items.len);
    for (parsed.value.array.items) |el| {
        try testing.expect(el == .object);
        try testing.expectEqualStrings("2.0", el.object.get("jsonrpc").?.string);
        try testing.expect(el.object.get("id") != null);
    }
}

test "a batch of only notifications is answered with no body, like a single one" {
    const allocator = testing.allocator;
    const fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    const body =
        \\[{"jsonrpc":"2.0","method":"notifications/initialized"},
        \\ {"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}]
    ;
    // null → HTTP 202 with no body. Answering a notification at all is a
    // protocol violation, and that holds element-by-element inside a batch.
    try testing.expectEqual(@as(?[]u8, null), try call(fx, allocator, body));
}

test "a batch mixing a notification and a request answers only the request" {
    const allocator = testing.allocator;
    const fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    const body =
        \\[{"jsonrpc":"2.0","method":"notifications/initialized"},
        \\ {"jsonrpc":"2.0","id":9,"method":"ping"},
        \\ {"jsonrpc":"2.0","method":"notifications/initialized"}]
    ;
    const resp = (try call(fx, allocator, body)).?;
    defer allocator.free(resp);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, resp, "\"jsonrpc\":\"2.0\""));
    try expectContains(resp, "\"id\":9");
    // No stray separator from the two elements that contributed nothing.
    try testing.expect(std.mem.indexOf(u8, resp, "[,") == null);
    try testing.expect(std.mem.indexOf(u8, resp, ",]") == null);
}

test "batch edges: empty array, an oversized batch, and a non-object element" {
    const allocator = testing.allocator;
    const fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    // JSON-RPC 2.0: an empty batch is itself an invalid request.
    {
        const resp = (try call(fx, allocator, "[]")).?;
        defer allocator.free(resp);
        try expectContains(resp, "-32600");
        try expectContains(resp, "empty batch");
    }

    // The cap exists because the 64KB body limit would otherwise buy a thousand
    // GraphQL executions for the one token the per-IP limiter charges.
    {
        var b: std.ArrayList(u8) = .empty;
        defer b.deinit(allocator);
        try b.append(allocator, '[');
        for (0..mcp.MAX_BATCH_ELEMENTS + 1) |i| {
            if (i > 0) try b.append(allocator, ',');
            var buf: [64]u8 = undefined;
            try b.appendSlice(allocator, try std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"ping\"}}", .{i}));
        }
        try b.append(allocator, ']');
        const resp = (try call(fx, allocator, b.items)).?;
        defer allocator.free(resp);
        try expectContains(resp, "-32600");
        try expectContains(resp, "exceeds");
    }

    // Exactly at the cap still runs.
    {
        var b: std.ArrayList(u8) = .empty;
        defer b.deinit(allocator);
        try b.append(allocator, '[');
        for (0..mcp.MAX_BATCH_ELEMENTS) |i| {
            if (i > 0) try b.append(allocator, ',');
            var buf: [64]u8 = undefined;
            try b.appendSlice(allocator, try std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"ping\"}}", .{i}));
        }
        try b.append(allocator, ']');
        const resp = (try call(fx, allocator, b.items)).?;
        defer allocator.free(resp);
        try testing.expectEqual(@as(usize, mcp.MAX_BATCH_ELEMENTS), std.mem.count(u8, resp, "\"jsonrpc\":\"2.0\""));
    }

    // A non-object element has no id, so it cannot be treated as a notification
    // and dropped — it gets an error response and the rest of the batch still runs.
    {
        const resp = (try call(fx, allocator, "[42,{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"ping\"}]")).?;
        defer allocator.free(resp);
        try testing.expectEqual(@as(usize, 2), std.mem.count(u8, resp, "\"jsonrpc\":\"2.0\""));
        try expectContains(resp, "not a JSON-RPC object");
        try expectContains(resp, "\"id\":5");
    }

    // A bare scalar body is still neither an object nor a batch.
    {
        const resp = (try call(fx, allocator, "42")).?;
        defer allocator.free(resp);
        try expectContains(resp, "-32600");
    }
}

test "a batched graphql-query runs against the database like a single call" {
    const allocator = testing.allocator;
    const fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    const body =
        \\[{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"graphql-query","arguments":{"query":"{ domain(id:\"solo.eth\") { name } }"}}},
        \\ {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"resolve-name","arguments":{"name":"SOLO.ETH"}}}]
    ;
    const resp = (try call(fx, allocator, body)).?;
    defer allocator.free(resp);
    // Both tools really executed inside the batch — not a stubbed envelope.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, resp, "solo.eth"));
    try expectContains(resp, "\"isError\":false");
}

test "graphql-query refuses a mutation operation even though the schema has none" {
    const allocator = testing.allocator;
    const fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    // Nothing in the execution pipeline inspects the operation type, and the GET
    // route is the only other place that checks. So a `mutation` document reaches
    // the Query root and executes. It is harmless only for as long as the schema
    // declares no Mutation type — this pins the refusal to the operation itself,
    // so adding one later cannot quietly make the unauthenticated endpoint
    // writable.
    const cases = [_][]const u8{
        \\{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"graphql-query","arguments":{"query":"mutation { domain(id:\"solo.eth\") { name } }"}}}
        ,
        \\{"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"graphql-query","arguments":{"query":"mutation Named { domain(id:\"solo.eth\") { name } }"}}}
        ,
        // Leading whitespace and comments must not walk past the check.
        \\{"jsonrpc":"2.0","id":32,"method":"tools/call","params":{"name":"graphql-query","arguments":{"query":"\n\n  mutation { domain(id:\"solo.eth\") { name } }"}}}
        ,
    };
    for (cases) |body| {
        const resp = (try call(fx, allocator, body)) orelse return error.ExpectedResponse;
        defer allocator.free(resp);
        try expectContains(resp, "\"isError\":true");
        try expectContains(resp, "read-only");
        // And it did not execute: no name came back.
        try testing.expect(std.mem.indexOf(u8, resp, "solo.eth") == null);
    }

    // A plain query is untouched by the guard.
    const ok = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":33,"method":"tools/call","params":{"name":"graphql-query","arguments":{"query":"{ domain(id:\"solo.eth\") { name } }"}}}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(ok);
    try expectContains(ok, "solo.eth");
    try expectContains(ok, "\"isError\":false");
}

test "resolve-name falls back to a verbatim lookup when a name will not normalise" {
    const allocator = testing.allocator;
    const fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    // Labels are stored and hashed as the RAW bytes the chain emitted, so the
    // index holds names ENSIP-15 cannot normalise. Refusing those made a name the
    // indexer actually has unreachable through this tool.
    const underscore = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":40,"method":"tools/call","params":{"name":"resolve-name","arguments":{"name":"UNDER_SCORE.eth"}}}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(underscore);
    // The lookup RAN (a GraphQL answer came back) rather than being refused.
    try expectContains(underscore, "\"isError\":false");
    try expectContains(underscore, "\\\"domain\\\"");

    // The normalising path proper (SOLO.ETH -> solo.eth) is pinned by
    // "resolve-name rejects injection and bad arguments"; this test is only about
    // what happens when normalisation CANNOT produce a name.
}

test "resources/templates/list answers an empty list rather than method-not-found" {
    const allocator = testing.allocator;
    const fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    const resp = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":50,"method":"resources/templates/list"}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(resp);
    // Declaring the `resources` capability invites this call; -32601 made a
    // working server look broken in client logs.
    try expectContains(resp, "resourceTemplates");
    try testing.expect(std.mem.indexOf(u8, resp, "-32601") == null);
}

test "every JSON-RPC id shape comes back intact, including numbers that are not i64" {
    const allocator = testing.allocator;
    const fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    const cases = [_]struct { body: []const u8, want: []const u8 }{
        .{ .body =
        \\{"jsonrpc":"2.0","id":7,"method":"ping"}
        , .want = "\"id\":7" },
        .{ .body =
        \\{"jsonrpc":"2.0","id":"abc-123","method":"ping"}
        , .want = "\"id\":\"abc-123\"" },
        .{ .body =
        \\{"jsonrpc":"2.0","id":null,"method":"ping"}
        , .want = "\"id\":null" },
        // A float id is legal JSON-RPC. Flattening it to null left the client
        // unable to match the response to its request.
        .{ .body =
        \\{"jsonrpc":"2.0","id":1.5,"method":"ping"}
        , .want = "\"id\":1.5" },
        // Wider than i64: the parser hands this back as a number_string, and it
        // is still a valid JSON number, so it must be echoed verbatim.
        .{ .body =
        \\{"jsonrpc":"2.0","id":99999999999999999999,"method":"ping"}
        , .want = "\"id\":99999999999999999999" },
    };
    for (cases) |c| {
        const resp = (try call(fx, allocator, c.body)) orelse return error.ExpectedResponse;
        defer allocator.free(resp);
        try expectContains(resp, c.want);
    }
}
