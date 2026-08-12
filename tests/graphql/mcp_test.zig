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

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator, query: []const u8, variables: ?std.json.Value) anyerror![]u8 {
        _ = allocator;
        const self: *TestExec = @ptrCast(@alignCast(ctx));
        return self.handler.handleQuery(self.database, query, variables, null, false);
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
    try expectContains(bad, "-32602");
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

    // Quote/backslash in the name must be escaped into the composed query —
    // the lookup just misses; it can never re-shape the document.
    const inj = (try call(fx, allocator,
        \\{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"resolve-name","arguments":{"name":"evil\") { registrations { name } } #.eth"}}}
    )) orelse return error.ExpectedResponse;
    defer allocator.free(inj);
    try expectContains(inj, "\"isError\":false");
    try expectContains(inj, "\\\"domain\\\":null");
    try testing.expect(std.mem.indexOf(u8, inj, "registrations") == null);

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
