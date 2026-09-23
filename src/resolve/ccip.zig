//! EIP-3668 CCIP-Read codec (Task 07).
//!
//! The PURE, network-free layer of the CCIP-Read offchain-resolution loop: decode an
//! `OffchainLookup(address,string[],bytes,bytes4,bytes)` revert, template the gateway
//! URL(s), assemble the callback calldata, and parse a gateway JSON response. The actual
//! gateway HTTP + callback eth_call loop is a separate layer (built on injectable
//! transports so it stays hermetically testable). This fires only when Task 06 hit an
//! OffchainLookup revert AND RESOLVE_CCIP_ENABLED is set; every failure degrades to the
//! indexed miss, so nothing here is on the default path.
//!
//! Untrusted input: the revert bytes and the gateway response both come from
//! name-controlled sources, so every decode is bounds- and overflow-checked (a hostile
//! near-maxInt offset must error, never panic or slice out of bounds).

const std = @import("std");
const Address = @import("../types/address.zig").Address;

/// `OffchainLookup(address,string[],bytes,bytes4,bytes)` — keccak256(sig)[0..4].
pub const OFFCHAIN_LOOKUP = [4]u8{ 0x55, 0x6f, 0x18, 0x30 };

/// Cap on decoded gateway URLs, to bound allocation from a hostile revert.
pub const MAX_URLS: usize = 32;

/// Cap on gateway fetches actually attempted per lookup. A hostile revert can list up to
/// MAX_URLS gateways and each fetch can stall to its timeout; trying only the first few
/// bounds the per-lookup latency (compounded across redirect hops) while still allowing
/// fallback between gateways.
pub const MAX_GATEWAY_URLS: usize = 4;

fn readWordUsize(w32: []const u8) !usize {
    const v = std.mem.readInt(u256, w32[0..32], .big);
    if (v > std.math.maxInt(usize)) return error.OffsetOverflow;
    return @intCast(v);
}

/// Read a `[len][bytes]` dynamic tail at absolute offset `off` in `buf`, returning a
/// slice BORROWING from `buf`. Subtraction-form bounds — no `off + 32` addition that a
/// near-maxInt offset/length could overflow.
fn readDynBytes(buf: []const u8, off: usize) ![]const u8 {
    if (off > buf.len or buf.len - off < 32) return error.ShortRevert;
    const len = try readWordUsize(buf[off .. off + 32]);
    if (buf.len - off - 32 < len) return error.ShortRevert;
    return buf[off + 32 .. off + 32 + len];
}

/// A decoded EIP-3668 OffchainLookup. `urls` is an owned outer slice; its elements and
/// `call_data` / `extra_data` BORROW from the revert bytes passed to `decode`.
pub const OffchainLookup = struct {
    sender: Address,
    urls: [][]const u8,
    call_data: []const u8,
    callback: [4]u8,
    extra_data: []const u8,

    pub fn deinit(self: OffchainLookup, allocator: std.mem.Allocator) void {
        allocator.free(self.urls);
    }
};

/// Decode revert `data` as an OffchainLookup. Returns error.NotOffchainLookup if the
/// selector doesn't match (the caller then treats it as an ordinary revert → degrade).
pub fn decode(allocator: std.mem.Allocator, data: []const u8) !OffchainLookup {
    if (data.len < 4 + 160) return error.ShortRevert; // selector + 5 head words
    if (!std.mem.eql(u8, data[0..4], &OFFCHAIN_LOOKUP)) return error.NotOffchainLookup;
    const t = data[4..]; // tuple data; offsets are relative to here

    var sender: Address = undefined;
    @memcpy(&sender.bytes, t[12..32]); // address is right-aligned in word 0
    const off_urls = try readWordUsize(t[32..64]);
    const off_calldata = try readWordUsize(t[64..96]);
    var callback: [4]u8 = undefined;
    @memcpy(&callback, t[96..100]); // bytes4 is left-aligned in word 3
    const off_extra = try readWordUsize(t[128..160]);

    const call_data = try readDynBytes(t, off_calldata);
    const extra_data = try readDynBytes(t, off_extra);
    const urls = try decodeStringArray(allocator, t, off_urls);

    return .{ .sender = sender, .urls = urls, .call_data = call_data, .callback = callback, .extra_data = extra_data };
}

fn decodeStringArray(allocator: std.mem.Allocator, buf: []const u8, off: usize) ![][]const u8 {
    if (off > buf.len or buf.len - off < 32) return error.ShortRevert;
    const count = try readWordUsize(buf[off .. off + 32]);
    if (count > MAX_URLS) return error.TooManyUrls;
    const base = off + 32; // element offsets are relative to here
    // `count <= MAX_URLS` so `count * 32` cannot overflow; guard the offsets region.
    if (buf.len - base < count * 32) return error.ShortRevert;

    const urls = try allocator.alloc([]const u8, count);
    errdefer allocator.free(urls);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const el_off = try readWordUsize(buf[base + i * 32 .. base + i * 32 + 32]);
        if (el_off > buf.len - base) return error.ShortRevert; // overflow-safe: base <= buf.len
        const s_at = base + el_off;
        if (buf.len - s_at < 32) return error.ShortRevert;
        const slen = try readWordUsize(buf[s_at .. s_at + 32]);
        if (buf.len - s_at - 32 < slen) return error.ShortRevert;
        urls[i] = buf[s_at + 32 .. s_at + 32 + slen];
    }
    return urls;
}

// ============================================================================
// URL templating (EIP-3668): {sender}/{data} substitution + GET/POST selection.
// ============================================================================

pub const HttpMethod = enum { get, post };

pub const GatewayRequest = struct {
    method: HttpMethod,
    url: []const u8, // owned (templated)
    body: ?[]const u8 = null, // owned JSON for POST; null for GET

    pub fn deinit(self: GatewayRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        if (self.body) |b| allocator.free(b);
    }
};

/// Build the gateway request for one URL template. Per EIP-3668: if the template
/// contains `{data}` use GET with `{sender}`/`{data}` substituted; otherwise POST the
/// JSON `{ "data": <data>, "sender": <sender> }` to the (still `{sender}`-substituted)
/// URL. `sender_hex` / `data_hex` are 0x-prefixed lowercase hex. Caller owns the result.
pub fn buildGatewayRequest(allocator: std.mem.Allocator, url_template: []const u8, sender_hex: []const u8, data_hex: []const u8) !GatewayRequest {
    const has_data = std.mem.indexOf(u8, url_template, "{data}") != null;
    const url = try substitute(allocator, url_template, sender_hex, data_hex);
    errdefer allocator.free(url);
    if (has_data) return .{ .method = .get, .url = url };
    const body = try std.fmt.allocPrint(allocator, "{{\"data\":\"{s}\",\"sender\":\"{s}\"}}", .{ data_hex, sender_hex });
    return .{ .method = .post, .url = url, .body = body };
}

fn substitute(allocator: std.mem.Allocator, template: []const u8, sender_hex: []const u8, data_hex: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < template.len) {
        if (std.mem.startsWith(u8, template[i..], "{sender}")) {
            try out.appendSlice(allocator, sender_hex);
            i += "{sender}".len;
        } else if (std.mem.startsWith(u8, template[i..], "{data}")) {
            try out.appendSlice(allocator, data_hex);
            i += "{data}".len;
        } else {
            try out.append(allocator, template[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

// ============================================================================
// Callback assembly + gateway-response parse.
// ============================================================================

fn appendWord(list: *std.ArrayList(u8), allocator: std.mem.Allocator, n: u256) !void {
    var b: [32]u8 = undefined;
    std.mem.writeInt(u256, &b, n, .big);
    try list.appendSlice(allocator, &b);
}
fn appendPadded(list: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    try list.appendSlice(allocator, bytes);
    const rem = (32 - (bytes.len % 32)) % 32;
    const zeros = [_]u8{0} ** 32;
    try list.appendSlice(allocator, zeros[0..rem]);
}

/// Assemble the CCIP callback calldata: `callback ++ abi.encode(bytes response, bytes
/// extraData)`. Hand-packed two-dynamic-bytes ABI (offsets 0x40/off_data). Caller owns.
pub fn encodeCallback(allocator: std.mem.Allocator, callback: [4]u8, response: []const u8, extra_data: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, &callback);
    const paddedLen = struct {
        fn f(n: usize) usize {
            return n + ((32 - (n % 32)) % 32);
        }
    }.f;
    try appendWord(&out, allocator, 0x40); // offset(response)
    try appendWord(&out, allocator, 0x40 + 32 + paddedLen(response.len)); // offset(extraData)
    try appendWord(&out, allocator, response.len);
    try appendPadded(&out, allocator, response);
    try appendWord(&out, allocator, extra_data.len);
    try appendPadded(&out, allocator, extra_data);
    return out.toOwnedSlice(allocator);
}

/// Parse a gateway response body into raw bytes (owned by `allocator`). The EIP-3668
/// object form `{ "data": "0x..." }` is the primary shape; for interop with
/// non-conformant deployed gateways it also accepts a bare JSON string body (`"0x.."`)
/// and, when the body isn't JSON at all, a raw `0x..` hex body. Returns null on any
/// malformation so the caller degrades. Treats the body as untrusted.
pub fn parseGatewayData(allocator: std.mem.Allocator, body: []const u8) !?[]u8 {
    if (std.json.parseFromSlice(std.json.Value, allocator, body, .{})) |parsed| {
        defer parsed.deinit();
        switch (parsed.value) {
            .object => |obj| {
                const data_val = obj.get("data") orelse return null;
                if (data_val != .string) return null;
                return hexToBytes(allocator, data_val.string);
            },
            .string => |s| return hexToBytes(allocator, s),
            else => return null,
        }
    } else |_| {
        // Not JSON: accept a raw hex body only if it cleanly looks like `0x..`.
        const trimmed = std.mem.trim(u8, body, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "0x") or std.mem.startsWith(u8, trimmed, "0X")) {
            return hexToBytes(allocator, trimmed);
        }
        return null;
    }
}

fn hexToBytes(allocator: std.mem.Allocator, hex: []const u8) !?[]u8 {
    var s = hex;
    if (std.mem.startsWith(u8, s, "0x") or std.mem.startsWith(u8, s, "0X")) s = s[2..];
    if (s.len % 2 != 0) return null;
    const out = try allocator.alloc(u8, s.len / 2);
    errdefer allocator.free(out);
    _ = std.fmt.hexToBytes(out, s) catch {
        allocator.free(out);
        return null;
    };
    return out;
}

// ============================================================================
// EIP-3668 offchain loop. Transport-injected (fake HTTP + RPC in tests, real clients
// in production) so the whole loop stays hermetically testable with no network.
// ============================================================================

fn bytesToHexAlloc(allocator: std.mem.Allocator, b: []const u8) ![]u8 {
    const digits = "0123456789abcdef";
    const out = try allocator.alloc(u8, 2 + b.len * 2);
    out[0] = '0';
    out[1] = 'x';
    for (b, 0..) |byte, i| {
        out[2 + i * 2] = digits[byte >> 4];
        out[2 + i * 2 + 1] = digits[byte & 0x0f];
    }
    return out;
}

/// Outcome of a callback eth_call in the loop — success vs revert must be distinguished
/// so a nested OffchainLookup can be detected.
pub const CallOutcome = union(enum) {
    ok: []u8, // return bytes (owned by the loop allocator)
    reverted: []u8, // revert data (possibly a nested OffchainLookup)
    err, // transport/endpoint failure
};

/// Injected transports: fakes in tests, real std.http.Client + rpc client in production.
/// Callbacks allocate on the passed allocator (the loop's arena), freed all at once.
pub const Transport = struct {
    ctx: *anyopaque,
    /// GET/POST a gateway URL; return the response body, or null on ANY failure
    /// (timeout, non-2xx, oversize, transport error) so the loop degrades.
    httpFetch: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, method: HttpMethod, url: []const u8, body: ?[]const u8) ?[]u8,
    /// eth_call `to` with `data`, distinguishing success from revert.
    ethCall: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, to: Address, data: []const u8) CallOutcome,
};

/// ENSIP-21 batch-gateway sentinel: a lookup listing this URL asks the client to resolve
/// the batched sub-requests itself rather than POST to an HTTP gateway.
pub const BATCH_SENTINEL = "x-batch-gateway:true";

/// Cap on sub-requests decoded from a batch query, to bound work from a hostile revert.
pub const MAX_BATCH_REQUESTS: usize = 64;

/// One decoded batch sub-request `(address sender, string[] urls, bytes data)`. All
/// slices borrow from the batch calldata / the passed allocator.
const BatchRequest = struct { sender: Address, urls: [][]const u8, data: []const u8 };

fn containsBatchSentinel(urls: [][]const u8) bool {
    for (urls) |u| {
        if (std.ascii.eqlIgnoreCase(u, BATCH_SENTINEL)) return true;
    }
    return false;
}

/// Fetch one lookup's gateways in order until one yields usable data (up to the per-lookup
/// fetch cap), returning the response bytes or null. Shared by the single-lookup path and
/// each batch sub-request.
fn fetchGateway(allocator: std.mem.Allocator, transport: Transport, sender: Address, data: []const u8, urls: [][]const u8) !?[]u8 {
    const sender_hex = try sender.toHex(allocator);
    const data_hex = try bytesToHexAlloc(allocator, data);
    var attempts: usize = 0;
    for (urls) |url| {
        if (std.ascii.eqlIgnoreCase(url, BATCH_SENTINEL)) continue; // not an HTTP gateway
        const req = buildGatewayRequest(allocator, url, sender_hex, data_hex) catch continue;
        if (attempts >= MAX_GATEWAY_URLS) break;
        attempts += 1;
        const resp = transport.httpFetch(transport.ctx, allocator, req.method, req.url, req.body) orelse continue;
        const parsed = (parseGatewayData(allocator, resp) catch continue) orelse continue;
        return parsed;
    }
    return null;
}

/// Decode a batch query `query((address,string[],bytes)[])` (selector-prefixed) into its
/// sub-requests. Untrusted input: every offset/length is subtraction-form bounds-checked.
fn decodeBatchQuery(allocator: std.mem.Allocator, call_data: []const u8) ![]BatchRequest {
    if (call_data.len < 4 + 32) return error.ShortRevert;
    const t = call_data[4..]; // after the query() selector
    const arr_off = try readWordUsize(t[0..32]);
    if (arr_off > t.len or t.len - arr_off < 32) return error.ShortRevert;
    const count = try readWordUsize(t[arr_off .. arr_off + 32]);
    if (count > MAX_BATCH_REQUESTS) return error.TooManyRequests;
    const base = arr_off + 32; // element offsets are relative to here
    if (t.len - base < count * 32) return error.ShortRevert; // count<=MAX so count*32 can't overflow

    const reqs = try allocator.alloc(BatchRequest, count);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const el_off = try readWordUsize(t[base + i * 32 .. base + i * 32 + 32]);
        if (el_off > t.len - base) return error.ShortRevert; // base <= t.len
        const tup_at = base + el_off;
        if (t.len - tup_at < 96) return error.ShortRevert; // 3 head words
        const tup = t[tup_at..]; // tuple-relative offsets are relative to here
        var sender: Address = undefined;
        @memcpy(&sender.bytes, tup[12..32]);
        const urls_off = try readWordUsize(tup[32..64]);
        const data_off = try readWordUsize(tup[64..96]);
        reqs[i] = .{
            .sender = sender,
            .urls = try decodeStringArray(allocator, tup, urls_off),
            .data = try readDynBytes(tup, data_off),
        };
    }
    return reqs;
}

/// ABI-encode `(bool[] failures, bytes[] responses)` — the ENSIP-21 batch-gateway result.
/// `results[i] == null` means that sub-request failed (failure=true, empty response).
fn encodeBatchResponse(allocator: std.mem.Allocator, results: []const ?[]const u8) ![]u8 {
    const paddedLen = struct {
        fn f(n: usize) usize {
            return n + ((32 - (n % 32)) % 32);
        }
    }.f;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const count = results.len;

    // Head: offsets to the two dynamic arrays.
    try appendWord(&out, allocator, 0x40);
    const fail_block = 32 + count * 32; // count word + one word per bool
    try appendWord(&out, allocator, 0x40 + fail_block);

    // failures[]
    try appendWord(&out, allocator, count);
    for (results) |r| try appendWord(&out, allocator, if (r == null) 1 else 0);

    // responses[]: count, then per-element offsets (relative to the first offset word),
    // then each element as [len][padded data].
    try appendWord(&out, allocator, count);
    var acc: usize = count * 32;
    for (results) |r| {
        try appendWord(&out, allocator, acc);
        acc += 32 + paddedLen(if (r) |b| b.len else 0);
    }
    for (results) |r| {
        const b = r orelse &[_]u8{};
        try appendWord(&out, allocator, b.len);
        try appendPadded(&out, allocator, b);
    }
    return out.toOwnedSlice(allocator);
}

/// Resolve an ENSIP-21 batch: decode the sub-requests, fetch each, and encode the
/// `(bool[],bytes[])` result. Returns null on a malformed batch (→ caller degrades).
fn resolveBatch(allocator: std.mem.Allocator, transport: Transport, call_data: []const u8) !?[]u8 {
    const reqs = decodeBatchQuery(allocator, call_data) catch return null;
    const results = try allocator.alloc(?[]const u8, reqs.len);
    for (reqs, 0..) |req, i| {
        results[i] = fetchGateway(allocator, transport, req.sender, req.data, req.urls) catch null;
    }
    return try encodeBatchResponse(allocator, results);
}

/// Run the EIP-3668 loop for an already-decoded `first` OffchainLookup. `expected_sender`
/// is the contract the original call was issued against — EIP-3668 requires the revert's
/// `sender` to equal it. Returns the final resolved bytes (owned by `allocator`), or null
/// on unresolved (sender mismatch, all gateways failed, too many redirects, a
/// non-OffchainLookup revert, or any transport failure) so the caller degrades to the
/// indexed miss. `first`'s borrowed slices must outlive this call.
pub fn resolve(allocator: std.mem.Allocator, transport: Transport, first: OffchainLookup, expected_sender: Address, max_redirects: u32) !?[]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const s = arena.allocator();

    var lookup = first;
    var expected = expected_sender;
    var redirects: u32 = 0;
    while (true) {
        // EIP-3668: the revert's sender must be the contract we called.
        if (!lookup.sender.eql(expected)) return null;

        // ENSIP-21: a `x-batch-gateway:true` sentinel URL means the call_data is a batch
        // of sub-requests to resolve here, returning abi.encode(bool[] failures,
        // bytes[] responses). Otherwise, do a normal single-lookup gateway fetch.
        const gateway_data: []const u8 = if (containsBatchSentinel(lookup.urls))
            (resolveBatch(s, transport, lookup.call_data) catch return null) orelse return null
        else
            (fetchGateway(s, transport, lookup.sender, lookup.call_data, lookup.urls) catch return null) orelse return null;

        // Complete the lookup: callback selector ++ abi(response, extraData), eth_called
        // against the sender.
        const cb = try encodeCallback(s, lookup.callback, gateway_data, lookup.extra_data);
        switch (transport.ethCall(transport.ctx, s, lookup.sender, cb)) {
            .ok => |result| return try allocator.dupe(u8, result),
            .err => return null,
            .reverted => |revert| {
                const nested = decode(s, revert) catch return null; // non-OffchainLookup -> unresolved
                redirects += 1;
                if (redirects > max_redirects) return null;
                expected = lookup.sender; // the nested revert must come from the callee
                lookup = nested;
            },
        }
    }
}

// ============================================================================
// Tests (pure, hermetic).
// ============================================================================

const testing = std.testing;

/// Reference OffchainLookup revert (see the decode test) — reused by the loop tests.
const REF_OFFCHAIN_HEX = "556f1830000000000000000000000000aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa00000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000140deadbeef00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000018000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000002768747470733a2f2f67772e6578616d706c652f7b73656e6465727d2f7b646174617d2e6a736f6e000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002123400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000025678000000000000000000000000000000000000000000000000000000000000";

const FakeCtx = struct {
    gateway_body: ?[]const u8,
    outcome: CallOutcome,
    fetches: usize = 0,
    calls: usize = 0,
};
fn fakeFetch(ctx: *anyopaque, allocator: std.mem.Allocator, method: HttpMethod, url: []const u8, body: ?[]const u8) ?[]u8 {
    _ = method;
    _ = url;
    _ = body;
    const c: *FakeCtx = @ptrCast(@alignCast(ctx));
    c.fetches += 1;
    const g = c.gateway_body orelse return null;
    return allocator.dupe(u8, g) catch null;
}
fn fakeCall(ctx: *anyopaque, allocator: std.mem.Allocator, to: Address, data: []const u8) CallOutcome {
    _ = to;
    _ = data;
    const c: *FakeCtx = @ptrCast(@alignCast(ctx));
    c.calls += 1;
    return switch (c.outcome) {
        .ok => |v| .{ .ok = allocator.dupe(u8, v) catch return .err },
        .reverted => |v| .{ .reverted = allocator.dupe(u8, v) catch return .err },
        .err => .err,
    };
}
const SENDER_AA = Address{ .bytes = [_]u8{0xaa} ** 20 };

fn fromHex(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, hex.len / 2);
    _ = try std.fmt.hexToBytes(out, hex);
    return out;
}

test "OFFCHAIN_LOOKUP selector matches its signature" {
    var h: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash("OffchainLookup(address,string[],bytes,bytes4,bytes)", &h, .{});
    try testing.expectEqual(OFFCHAIN_LOOKUP, h[0..4].*);
}

test "decode an OffchainLookup revert (independent reference payload)" {
    const a = testing.allocator;
    // Reference hand-computed from the ABI layout: sender 0xaa*20, one url template,
    // callData 0x1234, callback 0xdeadbeef, extraData 0x5678.
    const payload = try fromHex(a, REF_OFFCHAIN_HEX);
    defer a.free(payload);

    const ol = try decode(a, payload);
    defer ol.deinit(a);
    try testing.expectEqual([_]u8{0xaa} ** 20, ol.sender.bytes);
    try testing.expectEqual([_]u8{ 0xde, 0xad, 0xbe, 0xef }, ol.callback);
    try testing.expectEqual(@as(usize, 1), ol.urls.len);
    try testing.expectEqualStrings("https://gw.example/{sender}/{data}.json", ol.urls[0]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x12, 0x34 }, ol.call_data);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x56, 0x78 }, ol.extra_data);
}

test "decode rejects a non-OffchainLookup selector and short/hostile data" {
    const a = testing.allocator;
    var bad = [_]u8{0} ** 164;
    bad[0] = 0xde; // wrong selector
    try testing.expectError(error.NotOffchainLookup, decode(a, &bad));
    try testing.expectError(error.ShortRevert, decode(a, &[_]u8{ 0x55, 0x6f, 0x18, 0x30 }));
    // Hostile: correct selector but a near-maxInt urls offset must error, not overflow.
    var hostile = [_]u8{0} ** 164;
    @memcpy(hostile[0..4], &OFFCHAIN_LOOKUP);
    @memset(hostile[4 + 32 + 24 .. 4 + 64], 0xff); // off_urls low bytes = huge
    try testing.expect(std.meta.isError(decode(a, &hostile)));
}

test "buildGatewayRequest selects GET for {data} templates and POST otherwise" {
    const a = testing.allocator;
    const get = try buildGatewayRequest(a, "https://gw/{sender}/{data}.json", "0xabcd", "0x1234");
    defer get.deinit(a);
    try testing.expectEqual(HttpMethod.get, get.method);
    try testing.expectEqualStrings("https://gw/0xabcd/0x1234.json", get.url);
    try testing.expect(get.body == null);

    const post = try buildGatewayRequest(a, "https://gw/{sender}", "0xabcd", "0x1234");
    defer post.deinit(a);
    try testing.expectEqual(HttpMethod.post, post.method);
    try testing.expectEqualStrings("https://gw/0xabcd", post.url);
    try testing.expectEqualStrings("{\"data\":\"0x1234\",\"sender\":\"0xabcd\"}", post.body.?);
}

test "encodeCallback = selector ++ abi(bytes response, bytes extraData)" {
    const a = testing.allocator;
    const cd = try encodeCallback(a, .{ 0xde, 0xad, 0xbe, 0xef }, &[_]u8{ 0x11, 0x22 }, &[_]u8{0x33});
    defer a.free(cd);
    // selector, off 0x40, off_data 0x80, len(2), 1122.., len(1), 33..
    const ref = "deadbeef" ++
        "0000000000000000000000000000000000000000000000000000000000000040" ++
        "0000000000000000000000000000000000000000000000000000000000000080" ++
        "0000000000000000000000000000000000000000000000000000000000000002" ++
        "1122000000000000000000000000000000000000000000000000000000000000" ++
        "0000000000000000000000000000000000000000000000000000000000000001" ++
        "3300000000000000000000000000000000000000000000000000000000000000";
    const want = try fromHex(a, ref);
    defer a.free(want);
    try testing.expectEqualSlices(u8, want, cd);
}

test "parseGatewayData extracts hex bytes and degrades on garbage" {
    const a = testing.allocator;
    const ok = (try parseGatewayData(a, "{\"data\":\"0xabcd\"}")).?;
    defer a.free(ok);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xab, 0xcd }, ok);
    try testing.expect((try parseGatewayData(a, "not json")) == null);
    try testing.expect((try parseGatewayData(a, "{\"nope\":1}")) == null);
    try testing.expect((try parseGatewayData(a, "{\"data\":\"0xzz\"}")) == null);

    // Lenient shapes: bare JSON string body and raw hex body.
    const bare = (try parseGatewayData(a, "\"0xabcd\"")).?;
    defer a.free(bare);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xab, 0xcd }, bare);
    const raw = (try parseGatewayData(a, "  0xABCD\n")).?;
    defer a.free(raw);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xab, 0xcd }, raw);
    // A non-hex, non-JSON body still degrades to null.
    try testing.expect((try parseGatewayData(a, "garbage body")) == null);
}

test "ccip loop: happy path resolves via one gateway + callback" {
    const a = testing.allocator;
    const payload = try fromHex(a, REF_OFFCHAIN_HEX);
    defer a.free(payload);
    const first = try decode(a, payload);
    defer first.deinit(a);

    var final = [_]u8{ 0xca, 0xfe };
    var ctx = FakeCtx{ .gateway_body = "{\"data\":\"0x00\"}", .outcome = .{ .ok = &final } };
    const t = Transport{ .ctx = &ctx, .httpFetch = fakeFetch, .ethCall = fakeCall };
    const out = try resolve(a, t, first, SENDER_AA, 4);
    defer if (out) |o| a.free(o);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xca, 0xfe }, out.?);
    try testing.expectEqual(@as(usize, 1), ctx.fetches);
    try testing.expectEqual(@as(usize, 1), ctx.calls);
}

test "ccip loop: sender mismatch is rejected before any fetch" {
    const a = testing.allocator;
    const payload = try fromHex(a, REF_OFFCHAIN_HEX);
    defer a.free(payload);
    const first = try decode(a, payload);
    defer first.deinit(a);
    var final = [_]u8{0xca};
    var ctx = FakeCtx{ .gateway_body = "{\"data\":\"0x00\"}", .outcome = .{ .ok = &final } };
    const t = Transport{ .ctx = &ctx, .httpFetch = fakeFetch, .ethCall = fakeCall };
    const out = try resolve(a, t, first, Address{ .bytes = [_]u8{0xbb} ** 20 }, 4);
    try testing.expect(out == null);
    try testing.expectEqual(@as(usize, 0), ctx.fetches);
    try testing.expectEqual(@as(usize, 0), ctx.calls);
}

test "ccip loop: gateway failure degrades to unresolved" {
    const a = testing.allocator;
    const payload = try fromHex(a, REF_OFFCHAIN_HEX);
    defer a.free(payload);
    const first = try decode(a, payload);
    defer first.deinit(a);
    var final = [_]u8{0xca};
    var ctx = FakeCtx{ .gateway_body = null, .outcome = .{ .ok = &final } };
    const t = Transport{ .ctx = &ctx, .httpFetch = fakeFetch, .ethCall = fakeCall };
    const out = try resolve(a, t, first, SENDER_AA, 4);
    try testing.expect(out == null);
    try testing.expectEqual(@as(usize, 1), ctx.fetches);
    try testing.expectEqual(@as(usize, 0), ctx.calls);
}

test "ccip loop: nested OffchainLookup honored up to the redirect cap" {
    const a = testing.allocator;
    const payload = try fromHex(a, REF_OFFCHAIN_HEX);
    defer a.free(payload);
    const first = try decode(a, payload);
    defer first.deinit(a);
    // Callback always reverts with the same OffchainLookup (sender 0xaa == expected).
    var ctx = FakeCtx{ .gateway_body = "{\"data\":\"0x00\"}", .outcome = .{ .reverted = payload } };
    const t = Transport{ .ctx = &ctx, .httpFetch = fakeFetch, .ethCall = fakeCall };
    const out = try resolve(a, t, first, SENDER_AA, 2);
    try testing.expect(out == null);
    // initial + 2 nested redirects = 3 callback calls, then redirects > cap -> stop.
    try testing.expectEqual(@as(usize, 3), ctx.calls);
}

test "ccip loop: a non-OffchainLookup revert is unresolved" {
    const a = testing.allocator;
    const payload = try fromHex(a, REF_OFFCHAIN_HEX);
    defer a.free(payload);
    const first = try decode(a, payload);
    defer first.deinit(a);
    var junk = [_]u8{0xff} ** 8; // wrong selector / too short
    var ctx = FakeCtx{ .gateway_body = "{\"data\":\"0x00\"}", .outcome = .{ .reverted = &junk } };
    const t = Transport{ .ctx = &ctx, .httpFetch = fakeFetch, .ethCall = fakeCall };
    const out = try resolve(a, t, first, SENDER_AA, 4);
    try testing.expect(out == null);
    try testing.expectEqual(@as(usize, 1), ctx.calls);
}

test "ccip loop: a callback transport error is unresolved" {
    const a = testing.allocator;
    const payload = try fromHex(a, REF_OFFCHAIN_HEX);
    defer a.free(payload);
    const first = try decode(a, payload);
    defer first.deinit(a);
    var ctx = FakeCtx{ .gateway_body = "{\"data\":\"0x00\"}", .outcome = .err };
    const t = Transport{ .ctx = &ctx, .httpFetch = fakeFetch, .ethCall = fakeCall };
    const out = try resolve(a, t, first, SENDER_AA, 4);
    try testing.expect(out == null);
    try testing.expectEqual(@as(usize, 1), ctx.calls);
}

// --- ENSIP-21 batch gateway ---

fn tPaddedLen(n: usize) usize {
    return n + ((32 - (n % 32)) % 32);
}

/// Test-only inverse of decodeBatchQuery: encode `query((address,string[],bytes)[])`.
fn tEncodeBatchQuery(al: std.mem.Allocator, reqs: []const BatchRequest) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(al);
    try out.appendSlice(al, &[_]u8{ 0xa7, 0x80, 0xba, 0xb6 }); // arbitrary selector (decode skips it)
    try appendWord(&out, al, 0x20); // offset to the array

    // Build each tuple into its own buffer so we can lay out array element offsets.
    var tuples: std.ArrayList([]u8) = .empty;
    defer {
        for (tuples.items) |b| al.free(b);
        tuples.deinit(al);
    }
    for (reqs) |req| {
        var tb: std.ArrayList(u8) = .empty;
        errdefer tb.deinit(al);
        // Head: address, offset(urls)=0x60, offset(data) = 0x60 + urls_block_len.
        var word0 = [_]u8{0} ** 32;
        @memcpy(word0[12..32], &req.sender.bytes);
        try tb.appendSlice(al, &word0);
        // urls block (string[])
        var ub: std.ArrayList(u8) = .empty;
        defer ub.deinit(al);
        try appendWord(&ub, al, req.urls.len);
        var acc: usize = req.urls.len * 32;
        for (req.urls) |u| {
            try appendWord(&ub, al, acc);
            acc += 32 + tPaddedLen(u.len);
        }
        for (req.urls) |u| {
            try appendWord(&ub, al, u.len);
            try appendPadded(&ub, al, u);
        }
        try appendWord(&tb, al, 0x60);
        try appendWord(&tb, al, 0x60 + ub.items.len);
        try tb.appendSlice(al, ub.items);
        // data block (bytes)
        try appendWord(&tb, al, req.data.len);
        try appendPadded(&tb, al, req.data);
        try tuples.append(al, try tb.toOwnedSlice(al));
    }
    // Array: count, element offsets (relative to after the count word), then tuples.
    try appendWord(&out, al, reqs.len);
    var off: usize = reqs.len * 32;
    for (tuples.items) |tb| {
        try appendWord(&out, al, off);
        off += tb.len;
    }
    for (tuples.items) |tb| try out.appendSlice(al, tb);
    return out.toOwnedSlice(al);
}

test "batch query round-trips through decode" {
    const a = testing.allocator;
    var urls0 = [_][]const u8{"https://gw.one/{data}"};
    var urls1 = [_][]const u8{ "https://a/{data}", "https://b/{data}" };
    const reqs = [_]BatchRequest{
        .{ .sender = SENDER_AA, .urls = &urls0, .data = &[_]u8{ 0x12, 0x34 } },
        .{ .sender = Address{ .bytes = [_]u8{0xbb} ** 20 }, .urls = &urls1, .data = &[_]u8{ 0xde, 0xad, 0xbe, 0xef } },
    };
    const enc = try tEncodeBatchQuery(a, &reqs);
    defer a.free(enc);

    const got = try decodeBatchQuery(a, enc);
    defer {
        for (got) |g| a.free(g.urls);
        a.free(got);
    }
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualSlices(u8, &SENDER_AA.bytes, &got[0].sender.bytes);
    try testing.expectEqualStrings("https://gw.one/{data}", got[0].urls[0]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x12, 0x34 }, got[0].data);
    try testing.expectEqual(@as(usize, 2), got[1].urls.len);
    try testing.expectEqualStrings("https://b/{data}", got[1].urls[1]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xde, 0xad, 0xbe, 0xef }, got[1].data);
}

test "encodeBatchResponse lays out (bool[] failures, bytes[] responses)" {
    const a = testing.allocator;
    const results = [_]?[]const u8{ &[_]u8{ 0xaa, 0xbb }, null };
    const enc = try encodeBatchResponse(a, &results);
    defer a.free(enc);
    // head: offset(failures)=0x40, offset(responses)=0x40 + (32 + 2*32)=0xa0
    try testing.expectEqual(@as(u256, 0x40), std.mem.readInt(u256, enc[0..32], .big));
    try testing.expectEqual(@as(u256, 0xa0), std.mem.readInt(u256, enc[32..64], .big));
    // failures[]: count=2, [0]=0 (ok), [1]=1 (failed)
    try testing.expectEqual(@as(u256, 2), std.mem.readInt(u256, enc[64..96], .big));
    try testing.expectEqual(@as(u256, 0), std.mem.readInt(u256, enc[96..128], .big));
    try testing.expectEqual(@as(u256, 1), std.mem.readInt(u256, enc[128..160], .big));
}

test "ccip loop: batch sentinel resolves sub-requests and completes the callback" {
    const a = testing.allocator;
    var sub_urls = [_][]const u8{"https://sub.gateway/{data}"};
    const reqs = [_]BatchRequest{.{ .sender = SENDER_AA, .urls = &sub_urls, .data = &[_]u8{ 0x12, 0x34 } }};
    const call_data = try tEncodeBatchQuery(a, &reqs);
    defer a.free(call_data);

    var urls = [_][]const u8{BATCH_SENTINEL};
    const final = try fromHex(a, "cafe");
    defer a.free(final);
    const first = OffchainLookup{
        .sender = SENDER_AA,
        .urls = &urls,
        .call_data = call_data,
        .callback = [_]u8{ 0x11, 0x22, 0x33, 0x44 },
        .extra_data = &[_]u8{},
    };
    // The sub-request gateway returns 0xdeadbeef; the callback returns the final bytes.
    var ctx = FakeCtx{ .gateway_body = "{\"data\":\"0xdeadbeef\"}", .outcome = .{ .ok = final } };
    const t = Transport{ .ctx = &ctx, .httpFetch = fakeFetch, .ethCall = fakeCall };
    const out = (try resolve(a, t, first, SENDER_AA, 4)) orelse return error.ExpectedResolved;
    defer a.free(out);
    try testing.expectEqualSlices(u8, final, out);
    try testing.expectEqual(@as(usize, 1), ctx.fetches); // one sub-request fetched
    try testing.expectEqual(@as(usize, 1), ctx.calls); // one callback
}
