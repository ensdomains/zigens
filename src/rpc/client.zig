//! Hand-written JSON-RPC client — CUSTOM FOR CAUSE (audit #51, settled 2026-06-06).
//!
//! Migrating this onto eth.zig's provider (we already use its ABI decoding at
//! 45 sites) was investigated against eth.zig v0.3.0 source and rejected: the
//! indexer depends on four properties its RPC layer lacks —
//!   1. JSON-RPC BATCHING: `HttpTransport.request` (http_transport.zig:47) is
//!      single-call; we batch up to ~11 eth_getLogs per HTTP request
//!      (getLogsBatch/getLogsMultiAddressBatch/getTransactionsByHashBatch).
//!   2. ADDRESS-ARRAY FILTERS: its `LogFilter.address` (json_rpc.zig:181) is a
//!      single string; getLogsMultiAddress needs address arrays + topic0 OR.
//!   3. ERROR TAXONOMY: its provider swallows RPC error code/message; the
//!      adaptive chunking here branches on RpcError vs StreamTooLong vs
//!      transient HttpError (see retry/backoff below).
//!   4. RESPONSE CAP: max_response_bytes (50 MB) is what produces
//!      StreamTooLong for the halve-on-error loops; eth.zig fetches unbounded.
//! Also: eth.zig's Log has no `block_timestamp` (the Alchemy extension we use
//! to avoid block fetches), and any second transport would bypass
//! `drainIdleHttpConnections` — the std.http pool-poisoning workaround (still
//! needed on Zig 0.16, see below) — reintroducing that failure through the
//! second pool.
//!
//! REVISIT when: eth.zig grows batch + filter-arrays + surfaced RPC errors +
//! a response cap (upstream-able), AND std.http.Client evicts dead pooled
//! connections on send-path failure (0.16's std.Io rewrite fixed only the
//! receive path; see drainIdleHttpConnections). Until then this file is
//! deliberate.
const std = @import("std");
const zsys = @import("../utils/system.zig");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;

/// Helper to write JSON values for RPC params
fn writeJsonValue(writer: anytype, value: anytype) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .bool => try writer.print("{}", .{value}),
        .int, .comptime_int => try writer.print("{d}", .{value}),
        .float, .comptime_float => try writer.print("{d}", .{value}),
        .pointer => |ptr_info| {
            if (ptr_info.size == .slice and ptr_info.child == u8) {
                // String
                try writer.print("\"{s}\"", .{value});
            } else {
                @compileError("Unsupported pointer type for JSON");
            }
        },
        .@"struct" => {
            // Check if it's a JSON ObjectMap
            if (T == std.json.ObjectMap) {
                // Serialize as JSON object
                try writer.writeAll("{");
                var it = value.iterator();
                var first = true;
                while (it.next()) |entry| {
                    if (!first) try writer.writeAll(",");
                    first = false;
                    try writer.print("\"{s}\":", .{entry.key_ptr.*});
                    try writeJsonValue(writer, entry.value_ptr.*);
                }
                try writer.writeAll("}");
                return;
            }
            // Otherwise handle as regular struct
            try writer.writeAll("{");
            inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("\"{s}\":", .{field.name});
                try writeJsonValue(writer, @field(value, field.name));
            }
            try writer.writeAll("}");
        },
        .@"union" => {
            // Handle JSON Value union
            if (T == std.json.Value) {
                switch (value) {
                    .null => try writer.writeAll("null"),
                    .bool => |b| try writer.print("{}", .{b}),
                    .integer => |n| try writer.print("{d}", .{n}),
                    .float => |f| try writer.print("{d}", .{f}),
                    .number_string => |s| try writer.writeAll(s),
                    .string => |s| try writer.print("\"{s}\"", .{s}),
                    .array => |arr| {
                        try writer.writeAll("[");
                        for (arr.items, 0..) |item, i| {
                            if (i > 0) try writer.writeAll(",");
                            try writeJsonValue(writer, item);
                        }
                        try writer.writeAll("]");
                    },
                    .object => |obj| {
                        try writer.writeAll("{");
                        var it = obj.iterator();
                        var first = true;
                        while (it.next()) |entry| {
                            if (!first) try writer.writeAll(",");
                            first = false;
                            try writer.print("\"{s}\":", .{entry.key_ptr.*});
                            try writeJsonValue(writer, entry.value_ptr.*);
                        }
                        try writer.writeAll("}");
                    },
                }
                return;
            }
            @compileError("Unsupported union type for JSON: " ++ @typeName(T));
        },
        else => @compileError("Unsupported type for JSON: " ++ @typeName(T)),
    }
}

/// Block reference for a read-only call. Prefer `.hash` for reproducible,
/// reorg-safe reads (the answer is pinned to an exact block); `.number` and
/// `.latest` are best-effort against a head that may move or be reorged.
pub const BlockTag = union(enum) {
    latest,
    number: u64,
    hash: Hash,
};

/// Result of a revert-exposing eth_call (`ethCallAllowRevert`). `.ok` carries the return
/// bytes; `.reverted` carries the revert DATA (e.g. an EIP-3668 OffchainLookup). Both are
/// owned by the client allocator.
pub const CallResult = union(enum) {
    ok: []u8,
    reverted: []u8,

    pub fn deinit(self: CallResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .ok => |d| allocator.free(d),
            .reverted => |d| allocator.free(d),
        }
    }
};

const call_hex_alphabet = "0123456789abcdef";

/// Encode raw calldata as a `0x`-prefixed lowercase hex string. Caller owns it.
fn encodeCallData(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, 2 + bytes.len * 2);
    out[0] = '0';
    out[1] = 'x';
    for (bytes, 0..) |b, i| {
        out[2 + i * 2] = call_hex_alphabet[b >> 4];
        out[2 + i * 2 + 1] = call_hex_alphabet[b & 0x0f];
    }
    return out;
}

/// Free hex->bytes decode (0x-prefix optional). Shared by hexToBytes and parseCallResult.
fn hexToBytesAlloc(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    const hex_data = if (std.mem.startsWith(u8, hex, "0x")) hex[2..] else hex;
    if (hex_data.len % 2 != 0) return error.InvalidHexLength;
    const bytes = try allocator.alloc(u8, hex_data.len / 2);
    _ = try std.fmt.hexToBytes(bytes, hex_data);
    return bytes;
}

/// Parse an eth_call JSON-RPC response value into a CallResult. PURE (no I/O) so it is
/// unit-testable with canned responses (see tests below): `error.data` 0x-hex -> `.reverted`
/// (the revert DATA, e.g. an EIP-3668 OffchainLookup); a result string -> `.ok` (return
/// bytes); a revert WITHOUT data, or a missing/non-string result -> an error the caller
/// degrades on. Bytes owned by `allocator`.
fn parseCallResult(allocator: std.mem.Allocator, value: std.json.Value) !CallResult {
    if (value != .object) return error.RpcNoResult;
    const obj = value.object;
    if (obj.get("error")) |err| {
        if (err == .object) {
            if (err.object.get("data")) |d| {
                if (d == .string and std.mem.startsWith(u8, d.string, "0x"))
                    return .{ .reverted = try hexToBytesAlloc(allocator, d.string) };
            }
        }
        return error.RpcError; // revert without data / other RPC error
    }
    const result = obj.get("result") orelse return error.RpcNoResult;
    switch (result) {
        .string => |str| return .{ .ok = try hexToBytesAlloc(allocator, str) },
        else => return error.RpcNoResult,
    }
}

test "encodeCallData: bytes -> lowercase 0x-hex (eth_call request-encode)" {
    const a = std.testing.allocator;
    const out = try encodeCallData(a, &[_]u8{ 0x00, 0x0a, 0xff, 0x10 });
    defer a.free(out);
    try std.testing.expectEqualStrings("0x000aff10", out);
    const empty = try encodeCallData(a, &[_]u8{});
    defer a.free(empty);
    try std.testing.expectEqualStrings("0x", empty);
}

test "parseCallResult: ok / revert-with-data / revert-without-data / no-result (canned responses)" {
    const a = std.testing.allocator;
    const Case = struct { json: []const u8 };
    // .ok — result hex decodes to return bytes.
    {
        const p = try std.json.parseFromSlice(std.json.Value, a, "{\"result\":\"0xdeadbeef\"}", .{});
        defer p.deinit();
        const r = try parseCallResult(a, p.value);
        defer r.deinit(a);
        try std.testing.expect(r == .ok);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0xde, 0xad, 0xbe, 0xef }, r.ok);
    }
    // .reverted — error.data hex IS the revert DATA (where an OffchainLookup lives).
    {
        const p = try std.json.parseFromSlice(std.json.Value, a, "{\"error\":{\"code\":3,\"data\":\"0x1234\"}}", .{});
        defer p.deinit();
        const r = try parseCallResult(a, p.value);
        defer r.deinit(a);
        try std.testing.expect(r == .reverted);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x12, 0x34 }, r.reverted);
    }
    // Revert WITHOUT data -> error (caller degrades to a miss / rpc_error).
    {
        const p = try std.json.parseFromSlice(std.json.Value, a, "{\"error\":{\"code\":3,\"message\":\"execution reverted\"}}", .{});
        defer p.deinit();
        try std.testing.expectError(error.RpcError, parseCallResult(a, p.value));
    }
    // No result key -> error.
    {
        const p = try std.json.parseFromSlice(std.json.Value, a, "{\"id\":1}", .{});
        defer p.deinit();
        try std.testing.expectError(error.RpcNoResult, parseCallResult(a, p.value));
    }
    _ = Case;
}

pub const Block = struct {
    number: u64,
    hash: Hash,
    parent_hash: Hash,
    timestamp: u64,
};

pub const Log = struct {
    address: Address,
    topics: []Hash,
    data: []u8,
    block_number: u64,
    transaction_hash: Hash,
    transaction_index: u32,
    log_index: u32,
    removed: bool,
    /// Block timestamp - optional, some RPC providers include it in eth_getLogs response
    block_timestamp: ?u64,
    /// Block hash - included in eth_getLogs responses per Ethereum JSON-RPC spec
    block_hash: ?Hash,

    pub fn deinit(self: *Log, allocator: std.mem.Allocator) void {
        allocator.free(self.topics);
        allocator.free(self.data);
    }
};

pub const Transaction = struct {
    hash: Hash,
    block_number: u64,
    from: Address,
    to: ?Address,
    input: []u8,
    value: []const u8,
    gas: u64,
    gas_price: []const u8,

    pub fn deinit(self: *Transaction, allocator: std.mem.Allocator) void {
        allocator.free(self.input);
    }
};

/// Walk an http.Client's idle-connection pool and destroy every entry.
///
/// Workaround carried from Zig 0.15.2 into 0.16:
/// std.http.Client.ConnectionPool.resize is still broken (Client.zig:175 calls
/// `popped.data.close(allocator)` but the popped value is a
/// `*DoublyLinkedList.Node` with no `data` field; the function fails to
/// compile when invoked). We replicate what resize(0) was meant to do — lock
/// the pool mutex (an Io.Mutex in 0.16, so lock/unlock take the client's io
/// handle), pop every node from `free`, recover the parent Connection via
/// @fieldParentPtr, and call Connection.destroy(io) (which closes the socket
/// and frees the per-connection allocation).
///
/// Touches stdlib internals (the ConnectionPool struct fields and
/// Connection.pool_node are public, but reaching into them is brittle).
/// Safe-ish: only the indexer thread writes to this pool, and the API
/// server has its own http.Client.
fn drainIdleHttpConnections(http_client: *std.http.Client) void {
    const io = http_client.io;
    const pool = &http_client.connection_pool;
    pool.mutex.lockUncancelable(io);
    defer pool.mutex.unlock(io);

    while (pool.free.popFirst()) |node| {
        pool.free_len -= 1;
        const conn: *std.http.Client.Connection = @alignCast(@fieldParentPtr("pool_node", node));
        conn.destroy(io);
    }
}

/// Zig 0.16's std.http.Client stamps its certificate-validation timestamp
/// (`client.now`) on the process's FIRST https request and never refreshes it
/// (http/Client.zig: `if (client.now != null) break :tls;`), so a long-lived
/// process validates every TLS handshake against a clock frozen at startup.
/// When the RPC provider rotates to a freshly issued leaf certificate whose
/// not_before postdates that frozen clock, EVERY new handshake fails as
/// TlsInitializationFailed until the process restarts (2026-08-20 production
/// stall: 7-day-old indexer, ~14h outage, instant recovery on restart).
/// Nulling `now` makes the next request rescan the CA bundle and stamp a
/// fresh timestamp. Same ownership caveat as drainIdleHttpConnections: only
/// the thread issuing requests on this http.Client may call it (std's own
/// rescan path has a documented race on `now`).
///
/// Remove once std.http.Client refreshes `now` (or re-validates) itself.
fn refreshTlsValidationClock(http_client: *std.http.Client) void {
    http_client.now = null;
}

/// Exponential backoff for retry `attempt` (1-based: the attempt that just
/// failed): 1s, 2s, 4s, 8s, then flat, so no retry loop ever parks for minutes.
pub fn retryBackoffMs(attempt: u32) u64 {
    const shift: u6 = @intCast(@min(attempt -| 1, 3));
    return @as(u64, 1000) << shift;
}

/// Attempts a single request gets once the provider answers with a rate-limit
/// rejection. Three attempts spend at most retryBackoffMs(1) + retryBackoffMs(2)
/// = 3s sleeping — the same budget executeHttpRequest already allows a transport
/// failure, and two orders of magnitude inside SYNC_FAILURE_EXIT_MINUTES — so a
/// throttled provider slows a request instead of stalling the sync past its own
/// watchdog. Callers that want more patience retry the returned
/// error.RpcRateLimited themselves (see the discovery anchor probe).
const MAX_RATE_LIMIT_ATTEMPTS: u32 = 3;

/// Phrasings providers use for rate-limit / compute-unit rejections, matched
/// case-insensitively anywhere in the JSON-RPC error message.
const RATE_LIMIT_PHRASES = [_][]const u8{
    "compute unit",
    "rate limit",
    "rate-limit",
    "ratelimit",
    "too many request",
    "throttl",
    "capacity",
    "quota",
    "over limit",
    "request limit",
    "rps limit",
};

/// A bare "exceeded" counts as a rate limit only next to one of these: "the
/// requested range exceeds the maximum" is a size complaint the caller answers
/// by shrinking its request, not by waiting.
const RATE_LIMIT_QUOTA_WORDS = [_][]const u8{
    "per second",
    "per minute",
    "per day",
    "daily",
    "monthly",
    "compute",
    "quota",
    "capacity",
    "credit",
    "throughput",
    "allowance",
};

fn containsIgnoreCase(haystack: []const u8, needle_lower: []const u8) bool {
    if (needle_lower.len == 0) return true;
    if (haystack.len < needle_lower.len) return false;
    var i: usize = 0;
    while (i + needle_lower.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle_lower.len and std.ascii.toLower(haystack[i + j]) == needle_lower[j]) : (j += 1) {}
        if (j == needle_lower.len) return true;
    }
    return false;
}

/// "429" as its own token — not the tail of a balance or a hex blob, which is
/// how it otherwise shows up in "insufficient funds ... have 42912..." errors.
fn mentionsHttp429(message: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, message, from, "429")) |at| : (from = at + 1) {
        const left_ok = at == 0 or !std.ascii.isAlphanumeric(message[at - 1]);
        const right = at + 3;
        const right_ok = right >= message.len or !std.ascii.isAlphanumeric(message[right]);
        if (left_ok and right_ok) return true;
    }
    return false;
}

/// True when a JSON-RPC error message describes a transient rate-limit or
/// compute-unit rejection, i.e. the provider will answer the very same request
/// after a backoff. Providers return these with HTTP 200, so the 429/408 status
/// retry in executeHttpRequest never sees them. An execution revert is never a
/// rate limit, whatever digits its revert string carries.
pub fn isRateLimitMessage(message: []const u8) bool {
    if (containsIgnoreCase(message, "revert")) return false;
    for (RATE_LIMIT_PHRASES) |phrase| {
        if (containsIgnoreCase(message, phrase)) return true;
    }
    if (mentionsHttp429(message)) return true;
    if (containsIgnoreCase(message, "exceed")) {
        for (RATE_LIMIT_QUOTA_WORDS) |word| {
            if (containsIgnoreCase(message, word)) return true;
        }
    }
    return false;
}

/// JSON-RPC `error` member → its message, tolerating the non-conformant shapes
/// providers have been seen to return (bare strings, message-less objects).
fn rpcErrorMessage(err_value: std.json.Value) []const u8 {
    if (err_value == .string) return err_value.string;
    if (err_value != .object) return "(malformed error)";
    const message = err_value.object.get("message") orelse return "(no message)";
    return if (message == .string) message.string else "(non-string message)";
}

/// Classify a JSON-RPC `error` member, without logging: rate-limit rejections
/// become error.RpcRateLimited (transient — retry the same request), everything
/// else stays error.RpcError, which the indexer's adaptive chunking answers by
/// shrinking its requests (the wrong answer to a throttle).
fn rpcErrorOf(err_value: std.json.Value) anyerror {
    return if (isRateLimitMessage(rpcErrorMessage(err_value))) error.RpcRateLimited else error.RpcError;
}

/// rpcErrorOf plus the log line: a rate limit is expected and recoverable, so
/// it warns; a genuine provider error keeps error level.
fn classifyRpcError(context: []const u8, err_value: std.json.Value) anyerror {
    const message = rpcErrorMessage(err_value);
    const err = rpcErrorOf(err_value);
    if (err == error.RpcRateLimited) {
        std.log.warn("{s} (rate limited): {s}", .{ context, message });
    } else {
        std.log.err("{s}: {s}", .{ context, message });
    }
    return err;
}

/// Whether a rate-limited `attempt` (1-based) may be retried, sleeping the
/// shared backoff first when it may.
fn awaitRateLimitRetry(context: []const u8, attempt: u32) bool {
    if (attempt >= MAX_RATE_LIMIT_ATTEMPTS) return false;
    const delay_ms = retryBackoffMs(attempt);
    std.log.warn("{s} rate limited, retrying in {d}ms (attempt {d}/{d})", .{ context, delay_ms, attempt + 1, MAX_RATE_LIMIT_ATTEMPTS });
    zsys.sleep(delay_ms * std.time.ns_per_ms);
    return true;
}

test "isRateLimitMessage: provider throttles classify as rate limits" {
    try std.testing.expect(isRateLimitMessage("Your app has exceeded its compute units per second capacity. If you have retries enabled, you can safely ignore this message. Contact support@alchemy.com to upgrade your plan and increase your rate limits."));
    try std.testing.expect(isRateLimitMessage("Too Many Requests"));
    try std.testing.expect(isRateLimitMessage("429 Too Many Requests"));
    try std.testing.expect(isRateLimitMessage("429"));
    try std.testing.expect(isRateLimitMessage("daily request count exceeded, request rate limited"));
    try std.testing.expect(isRateLimitMessage("rate limit exceeded"));
    try std.testing.expect(isRateLimitMessage("request throttled, please slow down"));
    try std.testing.expect(isRateLimitMessage("You've exceeded the RPS limit"));
    try std.testing.expect(isRateLimitMessage("monthly capacity exceeded"));
}

test "isRateLimitMessage: genuine provider errors are not rate limits" {
    try std.testing.expect(!isRateLimitMessage("execution reverted"));
    try std.testing.expect(!isRateLimitMessage("execution reverted: ERC721: invalid token ID"));
    try std.testing.expect(!isRateLimitMessage("Log response size exceeded. this block range should work: [0x1, 0x2]"));
    try std.testing.expect(!isRateLimitMessage("query returned more than 10000 results"));
    try std.testing.expect(!isRateLimitMessage("requested range exceeds the maximum of 2000 blocks"));
    try std.testing.expect(!isRateLimitMessage("invalid argument 0: hex string without 0x prefix"));
    try std.testing.expect(!isRateLimitMessage("missing trie node"));
    // A balance that merely contains the digits 429 is not an HTTP 429.
    try std.testing.expect(!isRateLimitMessage("insufficient funds for gas * price + value: have 42912345 want 50000000"));
    try std.testing.expect(!isRateLimitMessage("execution reverted: exceeded compute budget"));
    try std.testing.expect(!isRateLimitMessage(""));
}

test "retryBackoffMs: doubles then flattens at 8s" {
    try std.testing.expectEqual(@as(u64, 1000), retryBackoffMs(0));
    try std.testing.expectEqual(@as(u64, 1000), retryBackoffMs(1));
    try std.testing.expectEqual(@as(u64, 2000), retryBackoffMs(2));
    try std.testing.expectEqual(@as(u64, 4000), retryBackoffMs(3));
    try std.testing.expectEqual(@as(u64, 8000), retryBackoffMs(4));
    try std.testing.expectEqual(@as(u64, 8000), retryBackoffMs(9));
}

test "rpcErrorOf: rate limits and genuine errors get distinct error values" {
    const Case = struct { body: []const u8, want: anyerror };
    // Real batch-response shapes, including the Alchemy compute-unit rejection
    // that arrives with HTTP 200 and the non-conformant shapes providers send.
    const cases = [_]Case{
        .{ .body =
        \\{"error":{"code":429,"message":"Your app has exceeded its compute units per second capacity. If you have retries enabled, you can safely ignore this message."}}
        , .want = error.RpcRateLimited },
        .{ .body =
        \\{"error":{"code":-32005,"message":"daily request count exceeded, request rate limited"}}
        , .want = error.RpcRateLimited },
        .{ .body =
        \\{"error":{"code":3,"message":"execution reverted"}}
        , .want = error.RpcError },
        .{ .body =
        \\{"error":{"code":-32602,"message":"Log response size exceeded. this block range should work: [0x1, 0x2]"}}
        , .want = error.RpcError },
        .{ .body =
        \\{"error":-32000}
        , .want = error.RpcError },
        .{ .body =
        \\{"error":{"code":-32000}}
        , .want = error.RpcError },
    };
    for (cases) |case| {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, case.body, .{});
        defer parsed.deinit();
        const err_value = parsed.value.object.get("error").?;
        try std.testing.expectEqual(case.want, rpcErrorOf(err_value));
    }
}

pub const Client = struct {
    allocator: std.mem.Allocator,
    rpc_url: []const u8,
    request_id: std.atomic.Value(u64),
    /// Borrowed: the caller owns the http.Client (every consumer shares one).
    http_client: *std.http.Client,
    /// Provider batch-size ceiling for JSON-RPC batch calls; some providers cap
    /// the number of requests per batch. 0 = unlimited. When set, oversized
    /// batches are split into sequential sub-batches and the responses merged.
    max_batch_requests: usize = 0,
    /// Wall-clock of the last request through this client. A pooled
    /// keep-alive socket that sat idle longer than IDLE_EVICT_MS (a long
    /// database-only dispatch between fetches) is assumed closed by the
    /// provider and evicted BEFORE the next request, instead of failing it
    /// and — with every retry landing on the same stale pool — rolling the
    /// whole batch back.
    last_request_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    pub fn initWithSharedHttpClient(allocator: std.mem.Allocator, rpc_url: []const u8, http_client: *std.http.Client) !*Client {
        const client = try allocator.create(Client);
        client.* = .{
            .allocator = allocator,
            .rpc_url = rpc_url,
            .request_id = std.atomic.Value(u64).init(1),
            .http_client = http_client,
        };
        return client;
    }

    pub fn deinit(self: *Client) void {
        self.allocator.destroy(self);
    }

    fn nextRequestId(self: *Client) u64 {
        return self.request_id.fetchAdd(1, .monotonic);
    }

    /// Execute a JSON-RPC POST using std.http.Client with retry and exponential backoff.
    /// Uses the shared http_client (connection pooling + keep-alive). gzip/deflate responses
    /// are accepted with BOUNDED decompression — see performRequest.
    /// Returns the response body on success, error on failure after all retries exhausted.
    ///
    /// Timeout NOTE: Zig 0.16's std.http.Client still does not expose per-request
    /// connect/read timeouts. Previously `curl --connect-timeout 30 --max-time 120`
    /// protected against hung RPC endpoints. Until Zig's http client exposes timeouts (or
    /// we wrap fetch in a watchdog thread), a single request that hangs can block this
    /// indexer thread indefinitely.
    /// Mitigation today: most real RPC providers return quickly; TCP keep-alive detects dead
    /// connections within ~2 hours by default.
    const HttpOutcome = struct {
        status: u16,
        body: []u8,
    };

    /// One request/response cycle. Uses the lower-level request() (not fetch) so the body
    /// is read through readerDecompressing + allocRemaining(.limited(cap)): gzip/deflate
    /// are accepted (std's default accept-encoding header advertises them; the default
    /// accept-array already rejects zstd/compress at receiveHead), but the DECOMPRESSED
    /// output is capped — a compression bomb from a hostile or compromised endpoint
    /// surfaces as error.StreamTooLong instead of unbounded allocation. fetch() cannot do
    /// this: its decompressing stream has no output limit, and a cap enforced via the
    /// response writer would surface as WriteFailed, which the retry loop must treat as a
    /// transient connection error. (The 0.15.2 flate panic that briefly forced
    /// identity-only encoding here is fixed in 0.16 — match writes are limit-guarded.)
    fn performRequest(self: *Client, arena_allocator: std.mem.Allocator, request_body: []const u8, max_response_bytes: usize) !HttpOutcome {
        const uri = try std.Uri.parse(self.rpc_url);
        var req = try self.http_client.request(.POST, uri, .{
            .redirect_behavior = .unhandled, // same as fetch() for payload requests; 3xx surfaces as a status
            .keep_alive = true,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = request_body.len };
        var body_writer = try req.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(request_body);
        try body_writer.end();
        try req.connection.?.flush();

        var response = try req.receiveHead(&.{});

        // Reject oversize wire bodies up front; the decompression limit below is what
        // actually bounds a small-wire/huge-output bomb.
        if (response.head.content_length) |cl| {
            if (cl > max_response_bytes) return error.StreamTooLong;
        }

        var transfer_buffer: [4096]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        var flate_window: [std.compress.flate.max_window_len]u8 = undefined;
        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .gzip, .deflate => &flate_window,
            // Not advertised and not in the accept-array — receiveHead rejects these
            // before we get here; kept as a defensive arm.
            .zstd, .compress => return error.HttpContentEncodingUnsupported,
        };
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
        const body = try reader.allocRemaining(arena_allocator, .limited(max_response_bytes));
        return .{ .status = @intFromEnum(response.head.status), .body = body };
    }

    const IDLE_EVICT_MS: i64 = 30_000;

    fn executeHttpRequest(self: *Client, arena_allocator: std.mem.Allocator, request_body: []const u8) ![]const u8 {
        const started_ms = zsys.milliTimestamp();
        const last_ms = self.last_request_ms.swap(started_ms, .monotonic);
        if (last_ms != 0 and started_ms - last_ms > IDLE_EVICT_MS) drainIdleHttpConnections(self.http_client);
        const max_retries: u32 = 3;
        const max_response_bytes: usize = 50 * 1024 * 1024;
        var attempt: u32 = 0;
        var last_error: ?anyerror = null;

        while (attempt < max_retries) : (attempt += 1) {
            if (attempt > 0) {
                const delay_ms = retryBackoffMs(attempt);
                std.log.warn("RPC request failed, retrying in {d}ms (attempt {d}/{d})", .{ delay_ms, attempt + 1, max_retries });
                zsys.sleep(delay_ms * std.time.ns_per_ms);
            }

            const start_ms = zsys.milliTimestamp();

            const outcome = self.performRequest(arena_allocator, request_body, max_response_bytes) catch |err| {
                if (err == error.StreamTooLong) {
                    // Wire content-length or DECOMPRESSED output exceeded the cap — not a
                    // transient failure; the caller's adaptive chunking should shrink the
                    // request.
                    std.log.debug("Response too large: {}", .{err});
                    return err;
                }
                if (err == error.OutOfMemory) return err;
                // Zig 0.16's std.http.Client evicts a connection whose
                // receiveHead fails (it sets connection.closing before
                // returning the error), but a SEND-path failure — WriteFailed
                // from sendBody*/flush on a stale socket — leaves reader.state
                // == .ready, so Request.deinit() returns the dead socket to
                // the free pool. Next fetch picks the dead socket and fails
                // the same way. We can't use ConnectionPool.resize either —
                // it's still broken in 0.16 (Client.zig:175 calls
                // `popped.data.close()` but DoublyLinkedList.Node has no
                // `data` field; doesn't compile when invoked).
                //
                // Workaround: on ANY transient request error, walk the free pool
                // and destroy every idle connection so the next attempt opens
                // a fresh socket. We've observed `ReadFailed` and `WriteFailed`
                // both arise from stale pooled connections (different TCP
                // states at the time of reuse); draining on either keeps the
                // pool healthy. `HttpConnectionClosing` is the same disease's
                // clearest symptom — a 0-byte read of the response head, i.e.
                // the server closed the idle keep-alive socket before we
                // reused it (observed on the poll pass right after a full
                // sync, when the whole pool has been sitting idle). 0.16
                // already destroys THAT one connection, but after heavy
                // initial sync the pool may hold several stale connections;
                // one drain + one retry restores forward progress instead of
                // burning a retry per stale socket.
                //
                // Remove this whole block once std.http.Client also evicts on
                // send failure and ConnectionPool.resize compiles.
                if (err == error.WriteFailed or
                    err == error.ReadFailed or
                    err == error.UnexpectedReadFailure or
                    err == error.EndOfStream or
                    err == error.BrokenPipe or
                    err == error.ConnectionResetByPeer or
                    err == error.HttpConnectionClosing)
                {
                    drainIdleHttpConnections(self.http_client);
                    last_error = err;
                    std.log.warn("http request {} (likely stale pooled connection); evicted free pool, retrying", .{err});
                    continue;
                }
                // TlsInitializationFailed on a fresh connection is the frozen
                // validation-clock disease (see refreshTlsValidationClock) far
                // more often than a genuinely bad peer; CertificateBundleLoadFailure
                // is the same rescan path failing outright. Both heal by forcing
                // a rescan + fresh timestamp, so the retry lands on a clean slate.
                if (err == error.TlsInitializationFailed or
                    err == error.CertificateBundleLoadFailure)
                {
                    refreshTlsValidationClock(self.http_client);
                    drainIdleHttpConnections(self.http_client);
                    last_error = err;
                    std.log.warn("http request {}; reset frozen TLS validation clock + CA bundle, retrying", .{err});
                    continue;
                }
                last_error = err;
                std.log.warn("http request error: {}", .{err});
                continue;
            };

            const status_code = outcome.status;
            if (status_code < 200 or status_code >= 300) {
                // Capture response body for diagnostics (RPC providers typically send a
                // JSON error describing the issue: "block range too large", "too many logs", etc.).
                const body_preview_len = @min(outcome.body.len, 512);
                const body_preview = outcome.body[0..body_preview_len];

                // 4xx = permanent client error (request too big, malformed, etc.) — caller's
                // adaptive chunking can halve the range and retry. EXCEPT 408 (Request Timeout)
                // and 429 (Too Many Requests), which are explicitly transient per HTTP spec:
                // 408 means "server timed out waiting; resend the request", 429 is rate-limit
                // and resolves on backoff. Treating either as permanent aborts indexing on a
                // hiccup that retry would have absorbed (observed at deployment startup with
                // some RPC providers returning 408 under load).
                if (status_code >= 400 and status_code < 500 and status_code != 408 and status_code != 429) {
                    std.log.warn("HTTP {d} from RPC (permanent; not retrying). Body: {s}", .{ status_code, body_preview });
                    return error.RpcError;
                }

                // 5xx, 408, 429, and other transient: retry with backoff
                last_error = error.HttpError;
                std.log.warn("HTTP {d} from RPC (transient; retrying). Body: {s}", .{ status_code, body_preview });
                continue;
            }

            const body = outcome.body;
            if (body.len == 0) {
                last_error = error.HttpError;
                std.log.warn("http request returned empty response", .{});
                continue;
            }

            const elapsed = zsys.milliTimestamp() - start_ms;
            if (elapsed > 500) {
                std.log.debug("RPC http took {d}ms, response {d} bytes", .{ elapsed, body.len });
            }

            // Decompressed into the caller's arena by performRequest; bounded there.
            return body;
        }

        std.log.err("RPC request failed after {d} retries", .{max_retries});
        return last_error orelse error.HttpError;
    }

    /// Single JSON-RPC call, retrying provider rate-limit rejections (which
    /// arrive as a JSON-RPC error over HTTP 200, invisible to the status-code
    /// retry in executeHttpRequest) with the same exponential backoff.
    fn makeRpcCall(self: *Client, method: []const u8, params: anytype) !std.json.Parsed(std.json.Value) {
        var attempt: u32 = 1;
        while (true) : (attempt += 1) {
            return self.makeRpcCallOnce(method, params) catch |err| {
                if (err != error.RpcRateLimited) return err;
                if (!awaitRateLimitRetry("RPC request", attempt)) return err;
                continue;
            };
        }
    }

    fn makeRpcCallOnce(self: *Client, method: []const u8, params: anytype) !std.json.Parsed(std.json.Value) {
        const request_id = self.nextRequestId();

        // Use arena allocator for request/response buffers
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        // Build JSON-RPC request manually for Zig 0.15
        var request_buf: std.Io.Writer.Allocating = .init(arena_allocator);
        const writer = &request_buf.writer;
        try writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":", .{ request_id, method });

        // Handle params
        const ParamsType = @TypeOf(params);
        const params_type_info = @typeInfo(ParamsType);

        switch (params_type_info) {
            .@"struct" => |struct_info| {
                if (struct_info.fields.len == 0) {
                    // Empty struct = empty array
                    try writer.writeAll("[]");
                } else {
                    // Write params as array
                    try writer.writeAll("[");
                    inline for (struct_info.fields, 0..) |field, i| {
                        if (i > 0) try writer.writeAll(",");
                        const value = @field(params, field.name);
                        try writeJsonValue(writer, value);
                    }
                    try writer.writeAll("]");
                }
            },
            else => try writer.writeAll("[]"),
        }

        try writer.writeAll("}");

        // Execute HTTP request with retry logic
        const response_body = try self.executeHttpRequest(arena_allocator, request_buf.written());

        // Parse JSON response with main allocator (result will outlive this function)
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response_body, .{}) catch |err| {
            // Log the first 500 chars of response to help debug non-JSON responses (rate limiting, HTML errors, etc.)
            const preview_len = @min(response_body.len, 500);
            std.log.err("Failed to parse RPC response as JSON ({s}): {s}", .{ method, response_body[0..preview_len] });
            return err;
        };
        errdefer parsed.deinit();

        // A non-conformant provider can return valid JSON that is not the expected shape;
        // treat that as a catchable error, never an (uncatchable) panic — some callers run
        // in the indexer poll loop and rely on `catch` to degrade.
        if (parsed.value != .object) {
            std.log.err("RPC response for {s} was not a JSON object", .{method});
            return error.InvalidRpcResponse;
        }
        const response = parsed.value.object;

        // Check for errors
        if (response.get("error")) |err| return classifyRpcError("RPC error", err);

        return parsed;
    }

    /// Make a single RPC call with pre-built JSON params
    /// Execute a JSON-RPC call and return the parsed response WITHOUT collapsing the
    /// `error` member — callers that need the error object (e.g. eth_call revert data for
    /// EIP-3668) inspect it themselves. Transport/parse failures still error.
    fn makeRpcCallRaw(self: *Client, method: []const u8, params: std.json.Value) !std.json.Parsed(std.json.Value) {
        const request_id = self.nextRequestId();

        // Use arena allocator for request/response buffers
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        // Build JSON-RPC request
        var request_buf: std.Io.Writer.Allocating = .init(arena_allocator);
        const writer = &request_buf.writer;
        try writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":", .{ request_id, method });

        // Write params as JSON
        try writeJsonValue(writer, params);

        try writer.writeAll("}");

        // Execute HTTP request with retry logic
        const response_body = try self.executeHttpRequest(arena_allocator, request_buf.written());

        // Parse JSON response with main allocator (result will outlive this function)
        return std.json.parseFromSlice(std.json.Value, self.allocator, response_body, .{}) catch |err| {
            const preview_len = @min(response_body.len, 500);
            std.log.err("Failed to parse RPC response as JSON ({s}): {s}", .{ method, response_body[0..preview_len] });
            return err;
        };
    }

    fn makeRpcCallWithParams(self: *Client, method: []const u8, params: std.json.Value) !std.json.Parsed(std.json.Value) {
        var attempt: u32 = 1;
        while (true) : (attempt += 1) {
            return self.makeRpcCallWithParamsOnce(method, params) catch |err| {
                if (err != error.RpcRateLimited) return err;
                if (!awaitRateLimitRetry("RPC request", attempt)) return err;
                continue;
            };
        }
    }

    fn makeRpcCallWithParamsOnce(self: *Client, method: []const u8, params: std.json.Value) !std.json.Parsed(std.json.Value) {
        const parsed = try self.makeRpcCallRaw(method, params);
        errdefer parsed.deinit();
        // Check for errors
        if (parsed.value.object.get("error")) |err| return classifyRpcError("RPC error", err);
        return parsed;
    }

    /// Batch request descriptor
    pub const BatchRequest = struct {
        method: []const u8,
        params: std.json.Value,
    };

    fn writeBatchRequestJson(self: *Client, writer: *std.Io.Writer, requests: []const BatchRequest) !void {
        try writer.writeAll("[");
        for (requests, 0..) |req, i| {
            const request_id = self.nextRequestId();
            if (i > 0) try writer.writeAll(",");
            try writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":", .{ request_id, req.method });
            try writeJsonValue(writer, req.params);
            try writer.writeAll("}");
        }
        try writer.writeAll("]");
    }

    /// Make multiple RPC calls in a single HTTP request (JSON-RPC batch).
    /// Rate-limit rejections come back as a JSON-RPC error with HTTP 200, so the
    /// status-code retry never sees them; retry the whole batch with the shared
    /// backoff before handing error.RpcRateLimited to the caller.
    fn makeBatchRpcCall(self: *Client, requests: []const BatchRequest) !std.json.Parsed(std.json.Value) {
        var attempt: u32 = 1;
        while (true) : (attempt += 1) {
            return self.makeBatchRpcCallOnce(requests) catch |err| {
                if (err != error.RpcRateLimited) return err;
                if (!awaitRateLimitRetry("RPC batch", attempt)) return err;
                continue;
            };
        }
    }

    /// Returns array of responses in the same order as requests. When the
    /// provider caps batch sizes (max_batch_requests > 0), oversized batches
    /// are transparently split into sequential sub-batches and the response
    /// arrays merged before parsing — ids are globally unique, so the id-sort
    /// below restores request order across sub-batches.
    fn makeBatchRpcCallOnce(self: *Client, requests: []const BatchRequest) !std.json.Parsed(std.json.Value) {
        // Use arena allocator for request/response buffers
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        const max = self.max_batch_requests;
        const response_body = if (max == 0 or requests.len <= max) blk: {
            var request_buf: std.Io.Writer.Allocating = .init(arena_allocator);
            try self.writeBatchRequestJson(&request_buf.writer, requests);
            break :blk try self.executeHttpRequest(arena_allocator, request_buf.written());
        } else blk: {
            var merged: std.Io.Writer.Allocating = .init(arena_allocator);
            try merged.writer.writeAll("[");
            var wrote_any = false;
            var i: usize = 0;
            while (i < requests.len) : (i += max) {
                const chunk = requests[i..@min(i + max, requests.len)];
                var request_buf: std.Io.Writer.Allocating = .init(arena_allocator);
                try self.writeBatchRequestJson(&request_buf.writer, chunk);
                const chunk_body = try self.executeHttpRequest(arena_allocator, request_buf.written());
                const trimmed = std.mem.trim(u8, chunk_body, " \t\r\n");
                if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') {
                    const preview_len = @min(trimmed.len, 200);
                    std.log.err("Expected array response for batch sub-request: {s}", .{trimmed[0..preview_len]});
                    return error.RpcError;
                }
                const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n");
                if (inner.len > 0) {
                    if (wrote_any) try merged.writer.writeAll(",");
                    try merged.writer.writeAll(inner);
                    wrote_any = true;
                }
            }
            try merged.writer.writeAll("]");
            break :blk merged.written();
        };

        // Parse JSON response with main allocator (result will outlive this function)
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response_body, .{}) catch |err| {
            // Log the first 500 chars of response to help debug non-JSON responses (rate limiting, HTML errors, etc.)
            const preview_len = @min(response_body.len, 500);
            std.log.err("Failed to parse batch RPC response as JSON: {s}", .{response_body[0..preview_len]});
            return err;
        };
        errdefer parsed.deinit();

        // Batch responses are returned as an array
        if (parsed.value != .array) {
            std.log.err("Expected array response for batch request", .{});
            return error.RpcError;
        }

        // IMPORTANT: JSON-RPC batch responses can be returned in any order!
        // We must sort them by ID to match the original request order.
        const ResponseSort = struct {
            pub fn lessThan(_: void, lhs: std.json.Value, rhs: std.json.Value) bool {
                const lhs_id = lhs.object.get("id").?.integer;
                const rhs_id = rhs.object.get("id").?.integer;
                return lhs_id < rhs_id;
            }
        };
        std.mem.sort(std.json.Value, parsed.value.array.items, {}, ResponseSort.lessThan);

        // Check each response for errors
        for (parsed.value.array.items) |response_value| {
            const response = response_value.object;
            if (response.get("error")) |err| return classifyRpcError("RPC batch error", err);
        }

        return parsed;
    }

    pub fn getBlockNumber(self: *Client) !u64 {
        const parsed = try self.makeRpcCall("eth_blockNumber", .{});
        defer parsed.deinit();

        const result = parsed.value.object.get("result").?;
        const hex_str = result.string;
        const block_num = try std.fmt.parseInt(u64, hex_str[2..], 16);
        return block_num;
    }

    /// True when `address` has contract code at `block_number` (eth_getCode
    /// returns more than "0x"). Historical blocks need an archive-capable
    /// provider; a non-archive provider errors, which callers must treat as
    /// "unknown" and fall back conservatively.
    pub fn hasCodeAt(self: *Client, address: Address, block_number: u64) !bool {
        var addr_buf: [42]u8 = undefined;
        const addr_hex = address.toHexBuf(&addr_buf);
        var block_buf: [20]u8 = undefined;
        const block_hex = try std.fmt.bufPrint(&block_buf, "0x{x}", .{block_number});
        const parsed = try self.makeRpcCall("eth_getCode", .{ addr_hex, block_hex });
        defer parsed.deinit();
        const result = parsed.value.object.get("result") orelse return error.RpcError;
        if (result != .string) return error.RpcError;
        return result.string.len > 2;
    }

    pub const CodeProbe = struct { address: Address, block: u64 };

    /// eth_getCode for many (address, block) pairs in one JSON-RPC batch, in
    /// request order. Entry i is null when the provider's answer for probe i
    /// was missing or malformed, so a hostile or partial reply degrades that
    /// probe alone instead of the whole batch.
    pub fn getCodeBatch(self: *Client, probes: []const CodeProbe) ![]?bool {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var batch_requests = try a.alloc(BatchRequest, probes.len);
        for (probes, 0..) |probe, i| {
            var params = std.json.Array.init(a);
            try params.append(.{ .string = try probe.address.toHex(a) });
            try params.append(.{ .string = try std.fmt.allocPrint(a, "0x{x}", .{probe.block}) });
            batch_requests[i] = .{ .method = "eth_getCode", .params = .{ .array = params } };
        }

        const parsed = try self.makeBatchRpcCall(batch_requests);
        defer parsed.deinit();
        if (parsed.value != .array) return error.RpcError;
        const items = parsed.value.array.items;
        if (items.len != probes.len) return error.RpcError;

        const out = try self.allocator.alloc(?bool, probes.len);
        for (items, 0..) |item, i| out[i] = parseCodeEntry(item);
        return out;
    }

    fn parseCodeEntry(value: std.json.Value) ?bool {
        if (value != .object) return null;
        const result = value.object.get("result") orelse return null;
        if (result != .string) return null;
        const code = result.string;
        if (!std.mem.startsWith(u8, code, "0x")) return null;
        return code.len > 2;
    }

    test "parseCodeEntry degrades on malformed provider responses, never panics" {
        const a = std.testing.allocator;
        const Case = struct { json: []const u8, want: ?bool };
        const cases = [_]Case{
            .{ .json = "{\"result\":\"0x6080604052\"}", .want = true },
            .{ .json = "{\"result\":\"0x\"}", .want = false },
            .{ .json = "{\"result\":null}", .want = null },
            .{ .json = "{\"error\":{\"code\":-32000}}", .want = null },
            .{ .json = "{\"result\":42}", .want = null },
            .{ .json = "{\"result\":\"6080\"}", .want = null },
            .{ .json = "[]", .want = null },
        };
        for (cases) |c| {
            const parsed = try std.json.parseFromSlice(std.json.Value, a, c.json, .{});
            defer parsed.deinit();
            try std.testing.expectEqual(c.want, parseCodeEntry(parsed.value));
        }
    }

    /// Execute a read-only contract call (`eth_call`) against `to` with `data`,
    /// evaluated at `block`. Returns the raw ABI return bytes, owned by this
    /// client's allocator (an empty return is a zero-length slice). An on-chain
    /// revert or transport failure surfaces as an error — resolution callers are
    /// expected to catch it and fall back to their indexed answer.
    pub fn ethCall(self: *Client, to: Address, data: []const u8, block: BlockTag) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        // params: [ { to, data }, <block reference> ]
        var call_obj: std.json.ObjectMap = .empty;
        try call_obj.put(a, "to", .{ .string = try to.toHex(a) });
        try call_obj.put(a, "data", .{ .string = try encodeCallData(a, data) });

        var params_arr = std.json.Array.init(a);
        try params_arr.append(.{ .object = call_obj });
        switch (block) {
            .latest => try params_arr.append(.{ .string = "latest" }),
            .number => |n| try params_arr.append(.{ .string = try std.fmt.allocPrint(a, "0x{x}", .{n}) }),
            .hash => |h| {
                // EIP-1898 block-hash reference so the read is pinned to an exact block.
                // requireCanonical rejects a read against a block that has been reorged
                // out, so a result cached during the reorg window can't be a wrong-branch
                // answer; a provider that errors on the field degrades to the indexed value.
                var blk_obj: std.json.ObjectMap = .empty;
                try blk_obj.put(a, "blockHash", .{ .string = try h.toHex(a) });
                try blk_obj.put(a, "requireCanonical", .{ .bool = true });
                try params_arr.append(.{ .object = blk_obj });
            },
        }

        const parsed = try self.makeRpcCallWithParams("eth_call", .{ .array = params_arr });
        defer parsed.deinit();

        const result = parsed.value.object.get("result") orelse return error.RpcNoResult;
        switch (result) {
            .string => |s| return try self.hexToBytes(s),
            else => return error.RpcNoResult,
        }
    }

    /// EIP-3668/CCIP: the revert-exposing sibling of `ethCall`. Returns `.ok` with the
    /// return bytes, or `.reverted` with the revert DATA (needed to decode an
    /// OffchainLookup). A transport failure, missing result, or a revert WITHOUT data
    /// surfaces as an error so the caller degrades. Result owned by `self.allocator`.
    pub fn ethCallAllowRevert(self: *Client, to: Address, data: []const u8, block: BlockTag) !CallResult {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var call_obj: std.json.ObjectMap = .empty;
        try call_obj.put(a, "to", .{ .string = try to.toHex(a) });
        try call_obj.put(a, "data", .{ .string = try encodeCallData(a, data) });
        var params_arr = std.json.Array.init(a);
        try params_arr.append(.{ .object = call_obj });
        switch (block) {
            .latest => try params_arr.append(.{ .string = "latest" }),
            .number => |n| try params_arr.append(.{ .string = try std.fmt.allocPrint(a, "0x{x}", .{n}) }),
            .hash => |h| {
                // EIP-1898 pinned read; requireCanonical rejects a reorged-out block so a
                // revert/answer can't be decoded from a wrong-branch state.
                var blk_obj: std.json.ObjectMap = .empty;
                try blk_obj.put(a, "blockHash", .{ .string = try h.toHex(a) });
                try blk_obj.put(a, "requireCanonical", .{ .bool = true });
                try params_arr.append(.{ .object = blk_obj });
            },
        }

        const parsed = try self.makeRpcCallRaw("eth_call", .{ .array = params_arr });
        defer parsed.deinit();
        return parseCallResult(self.allocator, parsed.value);
    }

    pub fn getBlockByNumber(self: *Client, block_number: u64, include_txs: bool) !Block {
        const block_hex = try std.fmt.allocPrint(self.allocator, "0x{x}", .{block_number});
        defer self.allocator.free(block_hex);

        const parsed = try self.makeRpcCall("eth_getBlockByNumber", .{ block_hex, include_txs });
        defer parsed.deinit();

        const result = parsed.value.object.get("result").?;
        if (result == .null) {
            return error.BlockNotFound;
        }

        const block_obj = result.object;

        return Block{
            .number = try std.fmt.parseInt(u64, block_obj.get("number").?.string[2..], 16),
            .hash = try Hash.fromHex(block_obj.get("hash").?.string),
            .parent_hash = try Hash.fromHex(block_obj.get("parentHash").?.string),
            .timestamp = try std.fmt.parseInt(u64, block_obj.get("timestamp").?.string[2..], 16),
        };
    }

    /// A full block header (number, hash, parent, timestamp).
    pub const BlockHeader = struct { number: u64, hash: Hash, parent_hash: Hash, timestamp: u64 };

    fn parseHeaderEntry(item: std.json.Value) ?BlockHeader {
        if (item != .object) return null;
        const result = item.object.get("result") orelse return null;
        if (result != .object) return null;
        const obj = result.object;
        const num_v = obj.get("number") orelse return null;
        const hash_v = obj.get("hash") orelse return null;
        const parent_v = obj.get("parentHash") orelse return null;
        const ts_v = obj.get("timestamp") orelse return null;
        if (num_v != .string or hash_v != .string or parent_v != .string or ts_v != .string) return null;
        const num_s = if (std.mem.startsWith(u8, num_v.string, "0x")) num_v.string[2..] else num_v.string;
        const ts_s = if (std.mem.startsWith(u8, ts_v.string, "0x")) ts_v.string[2..] else ts_v.string;
        return BlockHeader{
            .number = std.fmt.parseInt(u64, num_s, 16) catch return null,
            .hash = Hash.fromHex(hash_v.string) catch return null,
            .parent_hash = Hash.fromHex(parent_v.string) catch return null,
            .timestamp = std.fmt.parseInt(u64, ts_s, 16) catch return null,
        };
    }

    /// Fetch many block headers in one JSON-RPC batch (auto-split per
    /// max_batch_requests). Result is aligned with `numbers`; an entry the
    /// provider returned malformed or null decodes as null instead of failing
    /// the whole call. Caller owns the returned slice.
    pub fn getBlockHeadersBatch(self: *Client, numbers: []const u64) ![]?BlockHeader {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        var batch_requests = try arena_allocator.alloc(BatchRequest, numbers.len);
        for (numbers, 0..) |n, i| {
            const hexnum = try std.fmt.allocPrint(arena_allocator, "0x{x}", .{n});
            var params = std.json.Array.init(arena_allocator);
            try params.append(.{ .string = hexnum });
            try params.append(.{ .bool = false });
            batch_requests[i] = .{ .method = "eth_getBlockByNumber", .params = .{ .array = params } };
        }

        const parsed = try self.makeBatchRpcCall(batch_requests);
        defer parsed.deinit();
        const items = parsed.value.array.items;
        if (items.len != numbers.len) return error.RpcError;

        const out = try self.allocator.alloc(?BlockHeader, numbers.len);
        errdefer self.allocator.free(out);
        for (items, 0..) |item, i| out[i] = parseHeaderEntry(item);
        return out;
    }

    /// A block position by tier (number + hash). Used for finality (Task 09).
    pub const TaggedBlock = struct { number: u64, hash: Hash };

    /// Fetch a block by tag ('safe' / 'finalized' / 'latest'). Returns null when the
    /// provider doesn't support the tag or returns a null block (pre-Merge nodes, some
    /// L2s) — the caller degrades. Only number + hash are decoded; never throws for a
    /// finality fetch, so a bad provider can't break indexing.
    /// Decode a TaggedBlock from a parsed eth_getBlockByNumber response. Every access is
    /// checked so a hostile/non-conformant provider response degrades to null and never
    /// panics — the caller runs this in the indexer poll loop and relies on that.
    fn parseTaggedBlock(value: std.json.Value) ?TaggedBlock {
        if (value != .object) return null;
        const result = value.object.get("result") orelse return null;
        if (result != .object) return null; // "result": null → tag unsupported
        const block_obj = result.object;
        const num_v = block_obj.get("number") orelse return null;
        const hash_v = block_obj.get("hash") orelse return null;
        if (num_v != .string or hash_v != .string) return null;
        const num_s = num_v.string;
        // Require a 0x-prefixed hex quantity with at least one digit; guards the [2..]
        // slice (an empty/short string would panic) and rejects a non-hex misparse.
        if (num_s.len < 3 or !std.mem.startsWith(u8, num_s, "0x")) return null;
        return TaggedBlock{
            .number = std.fmt.parseInt(u64, num_s[2..], 16) catch return null,
            .hash = Hash.fromHex(hash_v.string) catch return null,
        };
    }

    pub fn getBlockByTag(self: *Client, tag: []const u8) ?TaggedBlock {
        const parsed = self.makeRpcCall("eth_getBlockByNumber", .{ tag, false }) catch return null;
        defer parsed.deinit();
        return parseTaggedBlock(parsed.value);
    }

    test "parseTaggedBlock degrades on malformed provider responses, never panics" {
        const a = std.testing.allocator;
        const valid_hash = "0x" ++ ("aa" ** 32); // 66-char valid hash
        const Case = struct { json: []const u8, ok: bool, num: u64 };
        const cases = [_]Case{
            .{ .json = "{\"result\":{\"number\":\"0x64\",\"hash\":\"" ++ valid_hash ++ "\"}}", .ok = true, .num = 100 },
            .{ .json = "{\"result\":null}", .ok = false, .num = 0 }, // tag unsupported
            // Empty number string — before the length/prefix guard this slice-panicked (the reviewed bug).
            .{ .json = "{\"result\":{\"number\":\"\",\"hash\":\"" ++ valid_hash ++ "\"}}", .ok = false, .num = 0 },
            .{ .json = "{\"result\":{\"number\":\"0x\",\"hash\":\"" ++ valid_hash ++ "\"}}", .ok = false, .num = 0 }, // 0x, no digits
            .{ .json = "{\"result\":{\"number\":\"0x64\"}}", .ok = false, .num = 0 }, // missing hash
            .{ .json = "{\"result\":{\"number\":100,\"hash\":\"0x00\"}}", .ok = false, .num = 0 }, // non-string number
            .{ .json = "{\"result\":{\"number\":\"0x64\",\"hash\":\"0xbeef\"}}", .ok = false, .num = 0 }, // bad hash len
            .{ .json = "[]", .ok = false, .num = 0 }, // non-object top-level
        };
        for (cases) |c| {
            const parsed = try std.json.parseFromSlice(std.json.Value, a, c.json, .{});
            defer parsed.deinit();
            const got = parseTaggedBlock(parsed.value);
            if (c.ok) {
                try std.testing.expect(got != null);
                try std.testing.expectEqual(c.num, got.?.number);
            } else {
                try std.testing.expect(got == null);
            }
        }
    }

    /// Descriptor for a single getLogs request in a batch
    pub const BatchGetLogsRequest = struct {
        from_block: u64,
        to_block: u64,
        address: ?Address,
        topics: []const ?Hash,
    };

    /// Batch version of getLogs - fetches multiple log queries in a single HTTP request
    /// Returns array of log arrays in the same order as requests
    /// Caller must free each log array and its contents
    pub fn getLogsBatch(self: *Client, requests: []const BatchGetLogsRequest) ![][]Log {
        // Use arena allocator for building batch request params
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        // Build batch requests
        var batch_requests = try arena_allocator.alloc(BatchRequest, requests.len);

        for (requests, 0..) |req, i| {
            // Build filter object
            const from_hex = try std.fmt.allocPrint(arena_allocator, "0x{x}", .{req.from_block});
            const to_hex = try std.fmt.allocPrint(arena_allocator, "0x{x}", .{req.to_block});

            var filter: std.json.ObjectMap = .empty;
            try filter.put(arena_allocator, "fromBlock", .{ .string = from_hex });
            try filter.put(arena_allocator, "toBlock", .{ .string = to_hex });

            if (req.address) |addr| {
                const addr_hex = try addr.toHex(arena_allocator);
                try filter.put(arena_allocator, "address", .{ .string = addr_hex });
            }

            // Convert topics to JSON array
            if (req.topics.len > 0) {
                var topics_array = std.json.Array.init(arena_allocator);

                for (req.topics) |topic_opt| {
                    if (topic_opt) |topic| {
                        const topic_hex = try topic.toHex(arena_allocator);
                        try topics_array.append(.{ .string = topic_hex });
                    } else {
                        try topics_array.append(.null);
                    }
                }

                try filter.put(arena_allocator, "topics", .{ .array = topics_array });
            }

            // Create batch request with filter as param array
            var params_array = std.json.Array.init(arena_allocator);
            try params_array.append(.{ .object = filter });

            batch_requests[i] = .{
                .method = "eth_getLogs",
                .params = .{ .array = params_array },
            };
        }

        // Make batch RPC call
        const parsed = try self.makeBatchRpcCall(batch_requests);
        defer parsed.deinit();

        const responses = parsed.value.array;

        // Allocate array for results
        var results = try self.allocator.alloc([]Log, requests.len);
        errdefer {
            for (results, 0..) |logs, i| {
                if (i > 0) { // Only free already-processed results
                    for (logs) |*log| {
                        log.deinit(self.allocator);
                    }
                    self.allocator.free(logs);
                }
            }
            self.allocator.free(results);
        }

        // Parse each response
        for (responses.items, 0..) |response_value, i| {
            const response = response_value.object;
            const result = response.get("result").?;
            const logs_array = result.array;

            var logs = try self.allocator.alloc(Log, logs_array.items.len);
            errdefer {
                for (logs, 0..) |*log, j| {
                    if (j > 0) log.deinit(self.allocator);
                }
                self.allocator.free(logs);
            }

            for (logs_array.items, 0..) |log_value, j| {
                const log_obj = log_value.object;

                // Parse topics
                const topics_json = log_obj.get("topics").?.array;
                var log_topics = try self.allocator.alloc(Hash, topics_json.items.len);
                for (topics_json.items, 0..) |topic_val, k| {
                    log_topics[k] = try Hash.fromHex(topic_val.string);
                }

                // Parse data
                const data_hex = log_obj.get("data").?.string;
                const data_bytes = try self.hexToBytes(data_hex);

                logs[j] = Log{
                    .address = try Address.fromHex(log_obj.get("address").?.string),
                    .topics = log_topics,
                    .data = data_bytes,
                    .block_number = try std.fmt.parseInt(u64, log_obj.get("blockNumber").?.string[2..], 16),
                    .transaction_hash = try Hash.fromHex(log_obj.get("transactionHash").?.string),
                    .transaction_index = @intCast(try std.fmt.parseInt(u64, log_obj.get("transactionIndex").?.string[2..], 16)),
                    .log_index = @intCast(try std.fmt.parseInt(u64, log_obj.get("logIndex").?.string[2..], 16)),
                    .removed = if (log_obj.get("removed")) |r| r.bool else false,
                    .block_timestamp = if (log_obj.get("blockTimestamp")) |ts| std.fmt.parseInt(u64, ts.string[2..], 16) catch null else null,
                    .block_hash = if (log_obj.get("blockHash")) |bh| Hash.fromHex(bh.string) catch null else null,
                };
            }

            results[i] = logs;
        }

        return results;
    }

    /// Descriptor for a multi-address getLogs request with OR topic support
    /// This allows querying multiple contracts and multiple event types in a single RPC call
    pub const MultiAddressLogsRequest = struct {
        from_block: u64,
        to_block: u64,
        /// Multiple addresses to query (all contracts in one call)
        addresses: []const Address,
        /// First topic position supports OR matching (array of event signatures)
        /// e.g., [AddressChanged, TextChanged, ContentHashChanged] matches ANY of these
        topic0_or: []const Hash,
    };

    /// Fetch logs from multiple addresses with OR topic matching in a single RPC call
    /// This is much more efficient than querying each address/topic separately
    /// Returns all matching logs - caller must filter by address/topic if needed
    /// Caller must free returned logs and their contents
    pub fn getLogsMultiAddress(self: *Client, request: MultiAddressLogsRequest) ![]Log {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        // Build filter object
        const from_hex = try std.fmt.allocPrint(arena_alloc, "0x{x}", .{request.from_block});
        const to_hex = try std.fmt.allocPrint(arena_alloc, "0x{x}", .{request.to_block});

        var filter: std.json.ObjectMap = .empty;
        try filter.put(arena_alloc, "fromBlock", .{ .string = from_hex });
        try filter.put(arena_alloc, "toBlock", .{ .string = to_hex });

        // Add addresses array
        if (request.addresses.len > 0) {
            var addr_array = std.json.Array.init(arena_alloc);
            for (request.addresses) |addr| {
                const addr_hex = try addr.toHex(arena_alloc);
                try addr_array.append(.{ .string = addr_hex });
            }
            try filter.put(arena_alloc, "address", .{ .array = addr_array });
        }

        // Add topics with OR support for topic[0]
        if (request.topic0_or.len > 0) {
            var topics_array = std.json.Array.init(arena_alloc);

            // topic[0] is an array for OR matching
            var topic0_array = std.json.Array.init(arena_alloc);
            for (request.topic0_or) |topic| {
                const topic_hex = try topic.toHex(arena_alloc);
                try topic0_array.append(.{ .string = topic_hex });
            }
            try topics_array.append(.{ .array = topic0_array });

            try filter.put(arena_alloc, "topics", .{ .array = topics_array });
        }

        // Build params array
        var params_array = std.json.Array.init(arena_alloc);
        try params_array.append(.{ .object = filter });

        // Make RPC call
        const rpc_start = zsys.milliTimestamp();
        const parsed = try self.makeRpcCallWithParams("eth_getLogs", .{ .array = params_array });
        defer parsed.deinit();
        const rpc_elapsed = zsys.milliTimestamp() - rpc_start;

        const result = parsed.value.object.get("result").?;
        const logs_array = result.array;

        // Allocate result logs
        var logs = try self.allocator.alloc(Log, logs_array.items.len);
        errdefer {
            for (logs) |*log| {
                log.deinit(self.allocator);
            }
            self.allocator.free(logs);
        }

        // Parse each log
        const parse_start = zsys.milliTimestamp();
        for (logs_array.items, 0..) |log_value, i| {
            const log_obj = log_value.object;

            // Parse topics
            const topics_json = log_obj.get("topics").?.array;
            var log_topics = try self.allocator.alloc(Hash, topics_json.items.len);
            for (topics_json.items, 0..) |topic_val, k| {
                log_topics[k] = try Hash.fromHex(topic_val.string);
            }

            // Parse data
            const data_hex = log_obj.get("data").?.string;
            const data_bytes = try self.hexToBytes(data_hex);

            logs[i] = Log{
                .address = try Address.fromHex(log_obj.get("address").?.string),
                .topics = log_topics,
                .data = data_bytes,
                .block_number = try std.fmt.parseInt(u64, log_obj.get("blockNumber").?.string[2..], 16),
                .transaction_hash = try Hash.fromHex(log_obj.get("transactionHash").?.string),
                .transaction_index = @intCast(try std.fmt.parseInt(u64, log_obj.get("transactionIndex").?.string[2..], 16)),
                .log_index = @intCast(try std.fmt.parseInt(u64, log_obj.get("logIndex").?.string[2..], 16)),
                .removed = if (log_obj.get("removed")) |r| r.bool else false,
                .block_timestamp = if (log_obj.get("blockTimestamp")) |ts| std.fmt.parseInt(u64, ts.string[2..], 16) catch null else null,
                .block_hash = if (log_obj.get("blockHash")) |bh| Hash.fromHex(bh.string) catch null else null,
            };
        }
        const parse_elapsed = zsys.milliTimestamp() - parse_start;

        if (logs.len > 1000) {
            std.log.debug("getLogsMultiAddress: {d} logs, rpc={d}ms, parse={d}ms", .{ logs.len, rpc_elapsed, parse_elapsed });
        }

        return logs;
    }

    /// Batch version of getLogsMultiAddress - fetches multiple block ranges in a single HTTP request
    /// Returns array of log arrays in the same order as requests
    /// Caller must free each log array and its contents
    pub fn getLogsMultiAddressBatch(self: *Client, requests: []const MultiAddressLogsRequest) ![][]Log {
        if (requests.len == 0) {
            return try self.allocator.alloc([]Log, 0);
        }

        // Use arena allocator for building batch request params
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        // Build batch requests
        var batch_requests = try arena_alloc.alloc(BatchRequest, requests.len);

        for (requests, 0..) |req, i| {
            // Build filter object
            const from_hex = try std.fmt.allocPrint(arena_alloc, "0x{x}", .{req.from_block});
            const to_hex = try std.fmt.allocPrint(arena_alloc, "0x{x}", .{req.to_block});

            var filter: std.json.ObjectMap = .empty;
            try filter.put(arena_alloc, "fromBlock", .{ .string = from_hex });
            try filter.put(arena_alloc, "toBlock", .{ .string = to_hex });

            // Add addresses array
            if (req.addresses.len > 0) {
                var addr_array = std.json.Array.init(arena_alloc);
                for (req.addresses) |addr| {
                    const addr_hex = try addr.toHex(arena_alloc);
                    try addr_array.append(.{ .string = addr_hex });
                }
                try filter.put(arena_alloc, "address", .{ .array = addr_array });
            }

            // Add topics with OR support for topic[0]
            if (req.topic0_or.len > 0) {
                var topics_array = std.json.Array.init(arena_alloc);

                // topic[0] is an array for OR matching
                var topic0_array = std.json.Array.init(arena_alloc);
                for (req.topic0_or) |topic| {
                    const topic_hex = try topic.toHex(arena_alloc);
                    try topic0_array.append(.{ .string = topic_hex });
                }
                try topics_array.append(.{ .array = topic0_array });

                try filter.put(arena_alloc, "topics", .{ .array = topics_array });
            }

            // Create batch request with filter as param array
            var params_array = std.json.Array.init(arena_alloc);
            try params_array.append(.{ .object = filter });

            batch_requests[i] = .{
                .method = "eth_getLogs",
                .params = .{ .array = params_array },
            };
        }

        // Make batch RPC call with timing
        const rpc_start = zsys.milliTimestamp();
        const parsed = try self.makeBatchRpcCall(batch_requests);
        defer parsed.deinit();
        const rpc_elapsed = zsys.milliTimestamp() - rpc_start;

        const responses = parsed.value.array;

        // Allocate array for results
        var results = try self.allocator.alloc([]Log, requests.len);
        errdefer {
            for (results, 0..) |logs, i| {
                if (i > 0) {
                    for (logs) |*log| {
                        log.deinit(self.allocator);
                    }
                    self.allocator.free(logs);
                }
            }
            self.allocator.free(results);
        }

        // Parse each response
        const parse_start = zsys.milliTimestamp();
        var total_logs: usize = 0;
        for (responses.items, 0..) |response_value, i| {
            const response = response_value.object;
            const result = response.get("result").?;
            const logs_array = result.array;

            var logs = try self.allocator.alloc(Log, logs_array.items.len);
            errdefer {
                for (logs, 0..) |*log, j| {
                    if (j > 0) log.deinit(self.allocator);
                }
                self.allocator.free(logs);
            }

            for (logs_array.items, 0..) |log_value, j| {
                const log_obj = log_value.object;

                // Parse topics
                const topics_json = log_obj.get("topics").?.array;
                var log_topics = try self.allocator.alloc(Hash, topics_json.items.len);
                for (topics_json.items, 0..) |topic_val, k| {
                    log_topics[k] = try Hash.fromHex(topic_val.string);
                }

                // Parse data
                const data_hex = log_obj.get("data").?.string;
                const data_bytes = try self.hexToBytes(data_hex);

                logs[j] = Log{
                    .address = try Address.fromHex(log_obj.get("address").?.string),
                    .topics = log_topics,
                    .data = data_bytes,
                    .block_number = try std.fmt.parseInt(u64, log_obj.get("blockNumber").?.string[2..], 16),
                    .transaction_hash = try Hash.fromHex(log_obj.get("transactionHash").?.string),
                    .transaction_index = @intCast(try std.fmt.parseInt(u64, log_obj.get("transactionIndex").?.string[2..], 16)),
                    .log_index = @intCast(try std.fmt.parseInt(u64, log_obj.get("logIndex").?.string[2..], 16)),
                    .removed = if (log_obj.get("removed")) |r| r.bool else false,
                    .block_timestamp = if (log_obj.get("blockTimestamp")) |ts| std.fmt.parseInt(u64, ts.string[2..], 16) catch null else null,
                    .block_hash = if (log_obj.get("blockHash")) |bh| Hash.fromHex(bh.string) catch null else null,
                };
            }

            results[i] = logs;
            total_logs += logs.len;
        }
        const parse_elapsed = zsys.milliTimestamp() - parse_start;

        std.log.debug("getLogsMultiAddressBatch: {d} requests, {d} total logs, rpc={d}ms, parse={d}ms", .{
            requests.len,
            total_logs,
            rpc_elapsed,
            parse_elapsed,
        });

        return results;
    }

    /// Batch version of eth_getTransactionByHash - fetches multiple transactions in a single HTTP request
    /// Returns array of transactions in the same order as requested hashes
    /// Caller must free the returned array and each transaction's contents
    pub fn getTransactionsByHashBatch(self: *Client, tx_hashes: []const Hash) ![]Transaction {
        // Use arena allocator for building batch request params
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        // Build batch requests
        var batch_requests = try arena_allocator.alloc(BatchRequest, tx_hashes.len);

        for (tx_hashes, 0..) |tx_hash, i| {
            const tx_hash_hex = try tx_hash.toHex(arena_allocator);

            // Build params array as JSON value
            var params_array = std.json.Array.init(arena_allocator);
            try params_array.append(.{ .string = tx_hash_hex });

            batch_requests[i] = BatchRequest{
                .method = "eth_getTransactionByHash",
                .params = .{ .array = params_array },
            };
        }

        // Make batch call
        const parsed = try self.makeBatchRpcCall(batch_requests);
        defer parsed.deinit();

        const responses = parsed.value.array.items;

        // Allocate result array
        var transactions = try self.allocator.alloc(Transaction, tx_hashes.len);
        errdefer self.allocator.free(transactions);

        // Parse each response
        for (responses, 0..) |response_value, i| {
            const response = response_value.object;
            const result = response.get("result").?;

            if (result == .null) {
                // Transaction not found - clean up and return error
                for (transactions[0..i]) |*tx| {
                    tx.deinit(self.allocator);
                }
                self.allocator.free(transactions);
                return error.TransactionNotFound;
            }

            const tx_obj = result.object;

            // Parse input data
            const input_hex = tx_obj.get("input").?.string;
            const input_bytes = try self.hexToBytes(input_hex);

            transactions[i] = Transaction{
                .hash = try Hash.fromHex(tx_obj.get("hash").?.string),
                .block_number = try std.fmt.parseInt(u64, tx_obj.get("blockNumber").?.string[2..], 16),
                .from = try Address.fromHex(tx_obj.get("from").?.string),
                .to = if (tx_obj.get("to")) |to_val|
                    if (to_val == .null) null else try Address.fromHex(to_val.string)
                else
                    null,
                .input = input_bytes,
                .value = tx_obj.get("value").?.string,
                .gas = try std.fmt.parseInt(u64, tx_obj.get("gas").?.string[2..], 16),
                .gas_price = tx_obj.get("gasPrice").?.string,
            };
        }

        return transactions;
    }

    fn hexToBytes(self: *Client, hex: []const u8) ![]u8 {
        return hexToBytesAlloc(self.allocator, hex);
    }
};

/// Test-only local HTTP peer: accept one connection, discard the request head, respond
/// with `head` + `body` verbatim, close. Lets the tests below exercise performRequest's
/// bounded-decompression contract against real wire bytes.
fn serveOnce(io: std.Io, srv: *std.Io.net.Server, head: []const u8, body: []const u8) void {
    const conn = srv.accept(io) catch return;
    defer conn.close(io);
    var buf: [4096]u8 = undefined;
    var seen: usize = 0;
    var head_buf: [8192]u8 = undefined;
    while (std.mem.indexOf(u8, head_buf[0..seen], "\r\n\r\n") == null) {
        const n = std.posix.read(conn.socket.handle, &buf) catch return;
        if (n == 0) break;
        const take = @min(n, head_buf.len - seen);
        @memcpy(head_buf[seen..][0..take], buf[0..take]);
        seen += take;
    }
    var write_buf: [512]u8 = undefined;
    var writer = conn.writer(io, &write_buf);
    writer.interface.writeAll(head) catch return;
    writer.interface.writeAll(body) catch return;
    writer.interface.flush() catch return;
}

// gzip("{\"result\":\"ok\"}"), level 9, mtime 0 — 35 bytes on the wire.
const GZ_SMALL = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xab\x56\x2a\x4a\x2d\x2e\xcd\x29\x51\xb2\x52\xca\xcf\x56\xaa\x05\x00\xcc\x7e\xc6\x44\x0f\x00\x00\x00";
// gzip(8192 zero bytes) — 43 bytes on the wire, 8192 decompressed: a miniature bomb.
const GZ_BOMB = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xed\xc1\x01\x0d\x00\x00\x00\xc2\xa0\xf7\x4f\x6d\x0e\x37\xa0\x00\x00\x00\x00\x00\x00\x00\x80\x77\x03\x94\x99\xf4\xd8\x00\x20\x00\x00";

test "performRequest decompresses a gzip RPC response (bounded reader, happy path)" {
    const testing = std.testing;
    const io = testing.io;
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);

    var head_buf: [128]u8 = undefined;
    const head = try std.fmt.bufPrint(&head_buf, "HTTP/1.1 200 OK\r\ncontent-encoding: gzip\r\ncontent-length: {d}\r\n\r\n", .{GZ_SMALL.len});
    const thread = try std.Thread.spawn(.{}, serveOnce, .{ io, &server, head, GZ_SMALL });

    var http_client: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    defer http_client.deinit();
    var url_buf: [48]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{server.socket.address.getPort()});
    const client = try Client.initWithSharedHttpClient(testing.allocator, url, &http_client);
    defer client.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const outcome = try client.performRequest(arena.allocator(), "{}", 50 * 1024 * 1024);
    thread.join();
    try testing.expectEqual(@as(u16, 200), outcome.status);
    try testing.expectEqualStrings("{\"result\":\"ok\"}", outcome.body);
}

test "performRequest bounds DECOMPRESSED output: small-wire gzip bomb -> StreamTooLong" {
    const testing = std.testing;
    const io = testing.io;
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);

    // 43 bytes on the wire (passes the content-length pre-check against a 1 KiB cap),
    // 8 KiB decompressed — only the allocRemaining limit can catch it.
    var head_buf: [128]u8 = undefined;
    const head = try std.fmt.bufPrint(&head_buf, "HTTP/1.1 200 OK\r\ncontent-encoding: gzip\r\ncontent-length: {d}\r\n\r\n", .{GZ_BOMB.len});
    const thread = try std.Thread.spawn(.{}, serveOnce, .{ io, &server, head, GZ_BOMB });

    var http_client: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    defer http_client.deinit();
    var url_buf: [48]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{server.socket.address.getPort()});
    const client = try Client.initWithSharedHttpClient(testing.allocator, url, &http_client);
    defer client.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = client.performRequest(arena.allocator(), "{}", 1024);
    thread.join();
    try testing.expectError(error.StreamTooLong, result);
}
