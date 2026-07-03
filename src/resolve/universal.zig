//! ENSIP-10 live resolution codec for the ENS Universal Resolver.
//!
//! This is the PURE, network-free layer of the Universal Resolver fallback (Task 06):
//! it builds the calldata for a record read — `resolve(bytes name, bytes data)` wrapping
//! an inner `addr`/`text`/`contenthash` call — and decodes the Universal Resolver's
//! `(bytes result, address resolver)` return into a typed value. The actual eth_call +
//! caching is done by the caller through resolve/client.zig `callCached`; the fallback
//! wiring lives in the API builders and is gated by RESOLVE_LIVE_ENABLED (default OFF),
//! so nothing here runs unless the operator turns live resolution on.
//!
//! Scope: FALLBACK only. Indexed answers always win; this fires on an indexed MISS.

const std = @import("std");
const Hash = @import("../types/hash.zig").Hash;
const Address = @import("../types/address.zig").Address;
const dns = @import("../utils/dns.zig");
const cache = @import("cache.zig");
const Resolver = @import("client.zig").Resolver;
const isFresh = @import("client.zig").isFresh;
const ccip_mod = @import("ccip.zig");
const testing = std.testing;

/// CCIP-Read parameters threaded into live resolution when RESOLVE_CCIP_ENABLED. When
/// present, the UR call is revert-aware so an EIP-3668 OffchainLookup completes offchain.
pub const CcipParams = struct {
    transport: ccip_mod.Transport,
    max_redirects: u32,
};

// 4-byte function selectors = keccak256(signature)[0..4]. Cross-checked at runtime in
// the "selectors match their signatures" test below.
pub const SEL_RESOLVE = [4]u8{ 0x90, 0x61, 0xb9, 0x23 }; // resolve(bytes,bytes)
pub const SEL_ADDR = [4]u8{ 0x3b, 0x3b, 0x57, 0xde }; // addr(bytes32)
pub const SEL_ADDR_COIN = [4]u8{ 0xf1, 0xcb, 0x7e, 0x06 }; // addr(bytes32,uint256)
pub const SEL_TEXT = [4]u8{ 0x59, 0xd1, 0xd4, 0x3c }; // text(bytes32,string)
pub const SEL_CONTENTHASH = [4]u8{ 0xbc, 0x1c, 0x58, 0xd1 }; // contenthash(bytes32)

/// The record being resolved. Selects the inner calldata and how the return decodes.
pub const Record = union(enum) {
    addr, // addr(bytes32) -> address
    addr_coin: u64, // addr(bytes32,uint256) -> bytes
    text: []const u8, // text(bytes32,string) -> string
    contenthash, // contenthash(bytes32) -> bytes

    /// A stable cache selector_key for this record (partitions the resolution_cache
    /// separately from the direct-resolver rows). Caller owns the returned string.
    pub fn cacheKey(self: Record, allocator: std.mem.Allocator) ![]u8 {
        return switch (self) {
            .addr => allocator.dupe(u8, "ur:addr"),
            .addr_coin => |c| std.fmt.allocPrint(allocator, "ur:addr:{d}", .{c}),
            .text => |k| std.fmt.allocPrint(allocator, "ur:text:{s}", .{k}),
            .contenthash => allocator.dupe(u8, "ur:contenthash"),
        };
    }
};

fn beWord(n: u256) [32]u8 {
    var b: [32]u8 = undefined;
    std.mem.writeInt(u256, &b, n, .big);
    return b;
}

// Minimal hand-rolled ABI packing (self-contained, no external ABI dep). Used only for
// the fixed shapes we build here — a 32-byte word and a right-zero-padded dynamic tail.
fn appendWord(list: *std.ArrayList(u8), allocator: std.mem.Allocator, n: u256) !void {
    const w = beWord(n);
    try list.appendSlice(allocator, &w);
}
fn appendPadded(list: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    try list.appendSlice(allocator, bytes);
    const rem = (32 - (bytes.len % 32)) % 32;
    const zeros = [_]u8{0} ** 32;
    try list.appendSlice(allocator, zeros[0..rem]);
}
fn paddedLen(n: usize) usize {
    return n + ((32 - (n % 32)) % 32);
}

fn readWordUsize(w32: []const u8) !usize {
    const v = std.mem.readInt(u256, w32[0..32], .big);
    if (v > std.math.maxInt(usize)) return error.OffsetOverflow;
    return @intCast(v);
}

/// Build the inner resolver calldata for `record` on node `node`. Caller owns the result.
pub fn encodeInner(allocator: std.mem.Allocator, node: Hash, record: Record) ![]u8 {
    switch (record) {
        .addr => {
            const out = try allocator.alloc(u8, 36);
            @memcpy(out[0..4], &SEL_ADDR);
            @memcpy(out[4..36], &node.bytes);
            return out;
        },
        .contenthash => {
            const out = try allocator.alloc(u8, 36);
            @memcpy(out[0..4], &SEL_CONTENTHASH);
            @memcpy(out[4..36], &node.bytes);
            return out;
        },
        .addr_coin => |coin| {
            const out = try allocator.alloc(u8, 68);
            @memcpy(out[0..4], &SEL_ADDR_COIN);
            @memcpy(out[4..36], &node.bytes);
            const cw = beWord(coin);
            @memcpy(out[36..68], &cw);
            return out;
        },
        .text => |key| {
            // text(bytes32 node, string key): sel ++ node(32) ++ offset(0x40) ++
            // len(key) ++ key padded to a 32-byte multiple.
            var out: std.ArrayList(u8) = .{};
            errdefer out.deinit(allocator);
            try out.appendSlice(allocator, &SEL_TEXT);
            try out.appendSlice(allocator, &node.bytes);
            try appendWord(&out, allocator, 0x40);
            try appendWord(&out, allocator, key.len);
            try appendPadded(&out, allocator, key);
            return out.toOwnedSlice(allocator);
        },
    }
}

/// Wrap `inner` calldata in a Universal Resolver `resolve(bytes name, bytes data)` call.
/// `name` must already be ENSIP-15 normalized by the caller; it is DNS-wire encoded here.
/// Caller owns the result.
pub fn encodeResolveCall(allocator: std.mem.Allocator, name: []const u8, inner: []const u8) ![]u8 {
    const dns_name = try dns.encodeDNSName(allocator, name);
    defer allocator.free(dns_name);

    // resolve(bytes name, bytes data): sel ++ head[off_name, off_data] ++
    // name tail[len, padded] ++ data tail[len, padded].
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, &SEL_RESOLVE);
    const off_name: usize = 0x40; // two head words
    const off_data: usize = 0x40 + 32 + paddedLen(dns_name.len);
    try appendWord(&out, allocator, off_name);
    try appendWord(&out, allocator, off_data);
    try appendWord(&out, allocator, dns_name.len);
    try appendPadded(&out, allocator, dns_name);
    try appendWord(&out, allocator, inner.len);
    try appendPadded(&out, allocator, inner);
    return out.toOwnedSlice(allocator);
}

/// The decoded `(bytes result, address resolver)` of a Universal Resolver `resolve`.
/// `result` BORROWS from the input buffer (no allocation).
pub const UrReturn = struct {
    result: []const u8,
    resolver: Address,
};

/// Decode the Universal Resolver `resolve` return tuple `(bytes result, address resolver)`.
pub fn decodeResolveReturn(data: []const u8) !UrReturn {
    if (data.len < 64) return error.ShortReturn;
    const off = try readWordUsize(data[0..32]); // offset to the `result` tail
    var resolver: Address = undefined;
    @memcpy(&resolver.bytes, data[44..64]); // low 20 bytes of the second word
    // Subtraction-form bounds (no `off + 32` addition) so a hostile near-maxInt offset
    // or length can't overflow usize — an overflow would panic (uncatchable by resolve()'s
    // `catch`) or, in ReleaseFast, wrap to a wild OOB slice. off <= data.len below, and
    // data.len is a real in-memory length, so the later `off + 32` cannot overflow.
    if (off > data.len or data.len - off < 32) return error.ShortReturn;
    const len = try readWordUsize(data[off .. off + 32]);
    if (data.len - off - 32 < len) return error.ShortReturn;
    return .{ .result = data[off + 32 .. off + 32 + len], .resolver = resolver };
}

/// Decode an `addr(bytes32)` inner return (a single 32-byte address word) to an Address.
/// Returns null for an empty return or the zero address ("no record").
pub fn decodeAddr(result: []const u8) ?Address {
    if (result.len < 32) return null;
    var addr: Address = undefined;
    @memcpy(&addr.bytes, result[12..32]); // low 20 bytes of the word
    if (addr.isZero()) return null;
    return addr;
}

/// Decode a dynamic `bytes`/`string` inner return (`text`, `contenthash`, `addr(coin)`).
/// The value BORROWS from `result`. Returns null for an empty/not-set value.
pub fn decodeDynamicBytes(result: []const u8) !?[]const u8 {
    if (result.len == 0) return null;
    if (result.len < 64) return error.ShortReturn;
    const off = try readWordUsize(result[0..32]);
    // Subtraction-form bounds — see decodeResolveReturn; avoids usize-overflow panic/OOB
    // on a hostile near-maxInt offset or length.
    if (off > result.len or result.len - off < 32) return error.ShortReturn;
    const len = try readWordUsize(result[off .. off + 32]);
    if (len == 0) return null;
    if (result.len - off - 32 < len) return error.ShortReturn;
    return result[off + 32 .. off + 32 + len];
}

/// Live-resolve `record` for `name` (ENSIP-15-normalized) at node `node` through the
/// Universal Resolver at `ur_address`, cache-first and block-hash-pinned. Returns the
/// decoded value as a string in the SAME shape the indexed path serves (address hex,
/// text string, or 0x-bytes), owned by `allocator`; null on no-record / unconfigured /
/// any failure (the caller degrades to the indexed miss). The resolution_cache stamps
/// `source='resolved_live'`; provenance lives there, not in the served value.
pub fn resolve(
    r: *Resolver,
    allocator: std.mem.Allocator,
    ur_address: Address,
    name: []const u8,
    node: Hash,
    record: Record,
    block_num: u64,
    block_hash: Hash,
    now: i64,
    ccip: ?CcipParams,
) !?[]u8 {
    if (ur_address.isZero()) return null; // not configured for this network -> degrade

    const inner = try encodeInner(allocator, node, record);
    defer allocator.free(inner);
    const calldata = try encodeResolveCall(allocator, name, inner);
    defer allocator.free(calldata);
    const selector_key = try record.cacheKey(allocator);
    defer allocator.free(selector_key);

    const cp = ccip orelse {
        // Task 06 path (unchanged): cached live read via callCached. An OffchainLookup
        // revert collapses to rpc_error there -> unresolved (degrade).
        const entry = r.callCached(allocator, ur_address, selector_key, calldata, block_num, block_hash, now) catch return null;
        defer entry.deinit(allocator);
        if (entry.status != .success) return null;
        const raw = entry.value orelse return null;
        return decodeRecordFromReturn(allocator, record, raw) catch return null;
    };

    // CCIP-enabled: same resolution_cache + block-hash pinning, but revert-aware so an
    // EIP-3668 OffchainLookup can be completed offchain and cached as `resolved_ccip`.
    const key = cache.Key{
        .chain_id = r.chain_id,
        .target = ur_address,
        .selector_key = selector_key,
        .arg_hash = cache.argHash(calldata),
        .block_dep_num = block_num,
        .block_dep_hash = block_hash,
    };
    if (try cache.get(allocator, r.db, key)) |cached| {
        defer cached.deinit(allocator);
        if (isFresh(cached.fetched_at, now, r.ttl_s)) {
            if (cached.status != .success) return null;
            return decodeRecordFromReturn(allocator, record, cached.value.?) catch return null;
        }
    }
    const call = r.rpc_client.ethCallAllowRevert(ur_address, calldata, .{ .hash = block_hash }) catch {
        cache.put(r.db, key, .rpc_error, null, .resolved_live, now) catch {};
        return null;
    };
    defer call.deinit(r.rpc_client.allocator);
    switch (call) {
        .ok => |data| {
            cache.put(r.db, key, .success, data, .resolved_live, now) catch {};
            return decodeRecordFromReturn(allocator, record, data) catch return null;
        },
        .reverted => |revert| {
            const ol = ccip_mod.decode(allocator, revert) catch {
                cache.put(r.db, key, .reverted, null, .resolved_live, now) catch {};
                return null; // an ordinary revert, not an OffchainLookup
            };
            defer ol.deinit(allocator);
            const final = (ccip_mod.resolve(allocator, cp.transport, ol, ur_address, cp.max_redirects) catch null) orelse return null;
            defer allocator.free(final);
            cache.put(r.db, key, .success, final, .resolved_ccip, now) catch {};
            return decodeRecordFromReturn(allocator, record, final) catch return null;
        },
    }
}

fn decodeRecordFromReturn(allocator: std.mem.Allocator, record: Record, raw: []const u8) !?[]u8 {
    const ur = try decodeResolveReturn(raw);
    return decodeRecordValue(allocator, record, ur.result);
}

/// Per-request live-resolution context threaded (as an opaque pointer) through the
/// GraphQL builder context. Present only when RESOLVE_LIVE_ENABLED wired a Resolver +
/// a non-zero Universal Resolver for the request. Carries the head block the API is
/// reading at, so the UR call is block-hash-pinned and reorg-invalidated like any other
/// resolution_cache row.
pub const LiveContext = struct {
    resolver: *Resolver,
    ur_address: Address,
    block_num: u64,
    block_hash: Hash,
    now: i64,
    /// CCIP-Read params; null unless RESOLVE_CCIP_ENABLED wired an offchain transport.
    ccip: ?CcipParams = null,

    /// Live-resolve `record` for `name`/`node`, returning the value string (owned by
    /// `allocator`) or null (no record / any failure → caller degrades to the miss).
    pub fn resolveRecord(self: *LiveContext, allocator: std.mem.Allocator, name: []const u8, node: Hash, record: Record) !?[]u8 {
        return resolve(self.resolver, allocator, self.ur_address, name, node, record, self.block_num, self.block_hash, self.now, self.ccip);
    }
};

fn decodeRecordValue(allocator: std.mem.Allocator, record: Record, result: []const u8) !?[]u8 {
    switch (record) {
        .addr => {
            const a = decodeAddr(result) orelse return null;
            return try a.toHex(allocator);
        },
        .text => {
            const v = (try decodeDynamicBytes(result)) orelse return null;
            return try allocator.dupe(u8, v);
        },
        .addr_coin, .contenthash => {
            const v = (try decodeDynamicBytes(result)) orelse return null;
            return try bytesToHexAlloc(allocator, v);
        },
    }
}

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

// ============================================================================
// Tests (pure, offline). Reference vectors independently hand-computed from the
// ABI/DNS layout — see the golden hex literals below.
// ============================================================================

fn selOf(comptime sig: []const u8) [4]u8 {
    var h: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(sig, &h, .{});
    return h[0..4].*;
}

test "selectors match their signatures" {
    try testing.expectEqual(SEL_RESOLVE, selOf("resolve(bytes,bytes)"));
    try testing.expectEqual(SEL_ADDR, selOf("addr(bytes32)"));
    try testing.expectEqual(SEL_ADDR_COIN, selOf("addr(bytes32,uint256)"));
    try testing.expectEqual(SEL_TEXT, selOf("text(bytes32,string)"));
    try testing.expectEqual(SEL_CONTENTHASH, selOf("contenthash(bytes32)"));
}

fn expectHex(expected_hex: []const u8, actual: []const u8) !void {
    const buf = try testing.allocator.alloc(u8, expected_hex.len / 2);
    defer testing.allocator.free(buf);
    const expected = try std.fmt.hexToBytes(buf, expected_hex);
    try testing.expectEqualSlices(u8, expected, actual);
}

test "encodeInner addr = selector ++ node" {
    const node = Hash{ .bytes = [_]u8{0xab} ** 32 };
    const inner = try encodeInner(testing.allocator, node, .addr);
    defer testing.allocator.free(inner);
    try expectHex("3b3b57de" ++ ("ab" ** 32), inner);
}

test "encodeInner addr_coin = selector ++ node ++ coin" {
    const node = Hash{ .bytes = [_]u8{0xab} ** 32 };
    const inner = try encodeInner(testing.allocator, node, .{ .addr_coin = 60 });
    defer testing.allocator.free(inner);
    // coin 60 = 0x3c, right-aligned in a 32-byte word.
    try expectHex("f1cb7e06" ++ ("ab" ** 32) ++ ("00" ** 31) ++ "3c", inner);
}

test "encodeResolveCall matches the hand-computed ABI reference" {
    const node = Hash{ .bytes = [_]u8{0xab} ** 32 };
    const inner = try encodeInner(testing.allocator, node, .addr);
    defer testing.allocator.free(inner);
    const calldata = try encodeResolveCall(testing.allocator, "alice.eth", inner);
    defer testing.allocator.free(calldata);
    // Reference: 9061b923 selector, offsets 0x40/0x80, name len 11 (DNS "alice.eth"),
    // data len 0x24 (36) = addr(node). Independently hand-computed from the ABI layout.
    const ref =
        "9061b923" ++
        "0000000000000000000000000000000000000000000000000000000000000040" ++
        "0000000000000000000000000000000000000000000000000000000000000080" ++
        "000000000000000000000000000000000000000000000000000000000000000b" ++
        "05616c69636503657468000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000024" ++
        "3b3b57deabababababababababababababababababababababababababababababababab" ++
        "00000000000000000000000000000000000000000000000000000000";
    try expectHex(ref, calldata);
}

test "decodeResolveReturn + decodeAddr extract value and resolver" {
    // (bytes result, address resolver): off=0x40, resolver=0x11*20, result=32-byte
    // word with address 0x22*20 in the low 20 bytes.
    var blob: [128]u8 = [_]u8{0} ** 128;
    blob[31] = 0x40; // offset word
    @memset(blob[44..64], 0x11); // resolver
    blob[95] = 32; // result length word (32)
    @memset(blob[108..128], 0x22); // result address word low 20 bytes
    const ur = try decodeResolveReturn(&blob);
    try testing.expectEqualSlices(u8, blob[96..128], ur.result);
    try testing.expectEqual([_]u8{0x11} ** 20, ur.resolver.bytes);
    const addr = decodeAddr(ur.result).?;
    try testing.expectEqual([_]u8{0x22} ** 20, addr.bytes);
}

test "decoders reject a hostile near-maxInt offset without overflow or panic" {
    // Offset word = maxInt(usize) on a 64-bit target (low 8 bytes 0xff). The
    // subtraction-form bounds must return an error, never overflow `off + 32`.
    var blob: [64]u8 = [_]u8{0} ** 64;
    @memset(blob[24..32], 0xff);
    try testing.expectError(error.ShortReturn, decodeResolveReturn(&blob));
    try testing.expectError(error.ShortReturn, decodeDynamicBytes(&blob));
}

test "decodeAddr treats the zero address as no record" {
    try testing.expect(decodeAddr(&([_]u8{0} ** 32)) == null);
    try testing.expect(decodeAddr(&[_]u8{}) == null);
}

test "decodeDynamicBytes reads a string/bytes value" {
    // ABI dynamic bytes: [offset=0x20][len=5]["hello" padded to 32].
    var result: [96]u8 = [_]u8{0} ** 96;
    result[31] = 0x20;
    result[63] = 5;
    @memcpy(result[64..69], "hello");
    const val = (try decodeDynamicBytes(&result)).?;
    try testing.expectEqualStrings("hello", val);
    // Empty return / zero length -> null.
    try testing.expect((try decodeDynamicBytes(&[_]u8{})) == null);
    var empty: [64]u8 = [_]u8{0} ** 64;
    empty[31] = 0x20; // offset, len word = 0
    try testing.expect((try decodeDynamicBytes(&empty)) == null);
}

test "resolve() serves a cached UR addr answer without touching RPC" {
    const a = testing.allocator;
    const db_mod = @import("../storage/database.zig");
    const rpc = @import("../rpc/client.zig");

    var database = try db_mod.Database.init(a, ":memory:");
    defer database.deinit();

    const ur_addr = Address{ .bytes = [_]u8{0xcc} ** 20 };
    const node = Hash{ .bytes = [_]u8{0xab} ** 32 };
    const name = "wildcard.eth";
    const now: i64 = 1_700_000_000;
    const block_num: u64 = 100;
    const block_hash = Hash{ .bytes = [_]u8{0xbb} ** 32 };
    const rec: Record = .addr;

    // Canned UR return (bytes result, address resolver): result = addr word 0x22*20.
    var blob: [128]u8 = [_]u8{0} ** 128;
    blob[31] = 0x40; // offset to result tail
    @memset(blob[44..64], 0x11); // selected resolver
    blob[95] = 32; // result length
    @memset(blob[108..128], 0x22); // address in low 20 bytes of the result word

    // Pre-seed the resolution_cache at the exact key resolve() will compute.
    const inner = try encodeInner(a, node, rec);
    defer a.free(inner);
    const calldata = try encodeResolveCall(a, name, inner);
    defer a.free(calldata);
    const selector_key = try rec.cacheKey(a);
    defer a.free(selector_key);
    const key = cache.Key{
        .chain_id = 1,
        .target = ur_addr,
        .selector_key = selector_key,
        .arg_hash = cache.argHash(calldata),
        .block_dep_num = block_num,
        .block_dep_hash = block_hash,
    };
    try cache.put(&database, key, .success, &blob, .resolved_live, now);

    // A deliberately-undefined RPC client: callCached must serve from cache and never
    // dereference it. If the fallback wrongly hit the network, this would crash.
    var resolver = Resolver.init(@as(*rpc.Client, undefined), &database, 1, 300);

    const val = try resolve(&resolver, a, ur_addr, name, node, rec, block_num, block_hash, now, null);
    defer if (val) |v| a.free(v);
    try testing.expectEqualStrings("0x2222222222222222222222222222222222222222", val.?);

    // Unconfigured (zero UR address) degrades to null with no lookup.
    const none = try resolve(&resolver, a, Address.zero, name, node, rec, block_num, block_hash, now, null);
    try testing.expect(none == null);
}

test "encodeDNSName vectors" {
    const a = testing.allocator;
    const alice = try dns.encodeDNSName(a, "alice.eth");
    defer a.free(alice);
    try expectHex("05616c6963650365746800", alice);
    const eth_name = try dns.encodeDNSName(a, "eth");
    defer a.free(eth_name);
    try expectHex("0365746800", eth_name);
    const root = try dns.encodeDNSName(a, "");
    defer a.free(root);
    try expectHex("00", root);
    try testing.expectError(error.InvalidLabel, dns.encodeDNSName(a, "a..b"));
}

// A transport whose callbacks must never fire (used to prove a cache hit short-circuits
// before any network touch); calling either would crash the test.
fn neverFetch(_: *anyopaque, _: std.mem.Allocator, _: ccip_mod.HttpMethod, _: []const u8, _: ?[]const u8) ?[]u8 {
    unreachable;
}
fn neverCall(_: *anyopaque, _: std.mem.Allocator, _: Address, _: []const u8) ccip_mod.CallOutcome {
    unreachable;
}

test "resolve(): CCIP-enabled path serves a resolved_ccip cache hit without any transport" {
    const a = testing.allocator;
    const db_mod = @import("../storage/database.zig");
    const rpc = @import("../rpc/client.zig");

    var database = try db_mod.Database.init(a, ":memory:");
    defer database.deinit();

    const ur_addr = Address{ .bytes = [_]u8{0xcc} ** 20 };
    const node = Hash{ .bytes = [_]u8{0xab} ** 32 };
    const name = "offchain.eth";
    const now: i64 = 1_700_000_000;
    const block_num: u64 = 100;
    const block_hash = Hash{ .bytes = [_]u8{0xbb} ** 32 };
    const rec: Record = .addr;

    // Canned (bytes result, address) with the resolved addr 0x33*20, stamped resolved_ccip.
    var blob: [128]u8 = [_]u8{0} ** 128;
    blob[31] = 0x40;
    blob[95] = 32;
    @memset(blob[108..128], 0x33);

    const inner = try encodeInner(a, node, rec);
    defer a.free(inner);
    const calldata = try encodeResolveCall(a, name, inner);
    defer a.free(calldata);
    const selkey = try rec.cacheKey(a);
    defer a.free(selkey);
    try cache.put(&database, .{
        .chain_id = 1,
        .target = ur_addr,
        .selector_key = selkey,
        .arg_hash = cache.argHash(calldata),
        .block_dep_num = block_num,
        .block_dep_hash = block_hash,
    }, .success, &blob, .resolved_ccip, now);

    var resolver = Resolver.init(@as(*rpc.Client, undefined), &database, 1, 300);
    const cp = CcipParams{
        .transport = .{ .ctx = undefined, .httpFetch = neverFetch, .ethCall = neverCall },
        .max_redirects = 4,
    };
    const val = try resolve(&resolver, a, ur_addr, name, node, rec, block_num, block_hash, now, cp);
    defer if (val) |v| a.free(v);
    try testing.expectEqualStrings("0x3333333333333333333333333333333333333333", val.?);
}
