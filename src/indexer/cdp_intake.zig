//! Coinbase CDP SQL API intake: bulk-backfill Base (Basenames) history without an
//! archive node. `base.events` rows carry the RAW topics array plus decoded
//! parameters; this module re-encodes each event's non-indexed data tail from the
//! decoded parameters (per-event spec below), rebuilds an `rpc.Log`, and feeds the
//! SAME dispatch tables and handlers the RPC path uses — so the events log and
//! projections come out exactly as live indexing would produce them.
//!
//! Scope and honest boundaries:
//! - Backfill/catch-up only. The live tip stays on RPC (poll economics + the
//!   hardened reorg machinery); intake blocks are deep-finalized, so reorg
//!   capture is disarmed exactly like bulk sync.
//! - Unknown topic0s from the queried addresses are counted and reported, never
//!   silently dropped.
//! - Resolvers discovered mid-intake have their earlier events healed by the
//!   FIRST live RPC run afterwards (the existing newly-discovered-resolver
//!   backfill); controllers have no such gap (ControllerAdded precedes use).
//!
//! Auth: CDP Secret API key (Ed25519). JWT nbf/exp are anchored to the SERVER's
//! Date header — a machine with a skewed clock (this sandbox runs hours behind)
//! would otherwise mint born-expired tokens and see nothing but 401s.

const std = @import("std");
const zsys = @import("../utils/system.zig");
const models = @import("../types/models.zig");
const Hash = @import("../types/hash.zig").Hash;
const Address = @import("../types/address.zig").Address;
const rpc = @import("../rpc/client.zig");
const abi = @import("abi_eth.zig");
const event_config = @import("event_config.zig");
const indexer_mod = @import("indexer.zig");
const Indexer = indexer_mod.Indexer;
const reorg_undo = @import("../storage/reorg_undo.zig");
const Ed25519 = std.crypto.sign.Ed25519;

pub const CDP_HOST = "api.cdp.coinbase.com";
pub const CDP_PATH = "/platform/v2/data/query/run";
const PAGE_LIMIT: u32 = 5000;
const MAX_RESPONSE_BYTES: usize = 32 * 1024 * 1024;

// ============================================================================
// Per-event data-tail specs
// ============================================================================
// The non-indexed parameters, in declaration order, with their ABI kinds and the
// CDP decoder's parameter names. Indexed parameters arrive raw in `topics` and
// need no spec. Round-trip tests below prove each spec re-encodes into exactly
// what the corresponding handler's abi.decodeValues expects.

pub const DataKind = enum { addr, u256_, u64_, str, bytes };

const DataParam = struct { name: []const u8, kind: DataKind };
const Spec = struct { topic0: Hash, params: []const DataParam };

const ES = abi.EventSignatures;
pub const SPECS = [_]Spec{
    // Registry (node-keyed, ENS V1 shape)
    .{ .topic0 = ES.new_owner_hash, .params = &.{.{ .name = "owner", .kind = .addr }} },
    .{ .topic0 = ES.registry_transfer_hash, .params = &.{.{ .name = "owner", .kind = .addr }} },
    .{ .topic0 = ES.new_resolver_hash, .params = &.{.{ .name = "resolver", .kind = .addr }} },
    .{ .topic0 = ES.new_ttl_hash, .params = &.{.{ .name = "ttl", .kind = .u64_ }} },
    // Registrar
    .{ .topic0 = ES.erc721_transfer_hash, .params = &.{} },
    .{ .topic0 = ES.base_registrar_name_registered_hash, .params = &.{.{ .name = "expires", .kind = .u256_ }} },
    .{ .topic0 = ES.base_registrar_name_renewed_hash, .params = &.{.{ .name = "expires", .kind = .u256_ }} },
    .{ .topic0 = ES.basenames_registrar_name_registered_with_record_hash, .params = &.{
        .{ .name = "expires", .kind = .u256_ },
        .{ .name = "resolver", .kind = .addr },
        .{ .name = "ttl", .kind = .u64_ },
    } },
    .{ .topic0 = ES.controller_added_hash, .params = &.{} },
    .{ .topic0 = ES.controller_removed_hash, .params = &.{} },
    // Basenames controllers
    .{ .topic0 = ES.basenames_controller_name_registered_hash, .params = &.{
        .{ .name = "name", .kind = .str },
        .{ .name = "expires", .kind = .u256_ },
    } },
    .{ .topic0 = ES.basenames_controller_name_renewed_hash, .params = &.{
        .{ .name = "name", .kind = .str },
        .{ .name = "expires", .kind = .u256_ },
    } },
    // Resolver records (L2Resolver surface)
    .{ .topic0 = ES.legacy_addr_changed_hash, .params = &.{.{ .name = "a", .kind = .addr }} },
    .{ .topic0 = ES.address_changed_hash, .params = &.{
        .{ .name = "coinType", .kind = .u256_ },
        .{ .name = "newAddress", .kind = .bytes },
    } },
    .{ .topic0 = ES.content_hash_changed_hash, .params = &.{.{ .name = "hash", .kind = .bytes }} },
    .{ .topic0 = ES.text_changed_hash, .params = &.{
        .{ .name = "key", .kind = .str },
        .{ .name = "value", .kind = .str },
    } },
    .{ .topic0 = ES.name_changed_hash, .params = &.{.{ .name = "name", .kind = .str }} },
    .{ .topic0 = ES.version_changed_hash, .params = &.{.{ .name = "newVersion", .kind = .u64_ }} },
    // Reverse (L2ReverseRegistrar)
    .{ .topic0 = ES.name_for_addr_changed_hash, .params = &.{.{ .name = "name", .kind = .str }} },
};

fn findSpec(topic0: Hash) ?*const Spec {
    inline for (&SPECS) |*spec| {
        if (topic0.eql(spec.topic0)) return spec;
    }
    return null;
}

// ============================================================================
// ABI data-tail encoder
// ============================================================================

fn jsonStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn parseDecU256(s: []const u8) ?u256 {
    if (s.len == 0) return null;
    return std.fmt.parseInt(u256, s, 10) catch null;
}

/// Numeric parameters may arrive as decimal strings or JSON integers.
fn paramU256(obj: std.json.ObjectMap, key: []const u8) ?u256 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| parseDecU256(s),
        .integer => |i| if (i < 0) null else @intCast(i),
        else => null,
    };
}

/// Encode `spec.params` from the decoded parameter map into standard ABI data
/// bytes: one 32-byte head word per param (value, or tail offset for dynamic
/// kinds), dynamic tails appended in order.
pub fn encodeDataTail(allocator: std.mem.Allocator, spec: *const Spec, obj: std.json.ObjectMap, row: ?std.json.ObjectMap) ![]u8 {
    var head: std.ArrayList(u8) = .empty;
    defer head.deinit(allocator);
    var tail: std.ArrayList(u8) = .empty;
    defer tail.deinit(allocator);
    const head_len: usize = spec.params.len * 32;

    for (spec.params) |p| {
        switch (p.kind) {
            .addr => {
                const hex = jsonStr(obj, p.name) orelse return error.MissingParam;
                const a = Address.fromHex(hex) catch return error.BadParam;
                var word = [_]u8{0} ** 32;
                @memcpy(word[12..32], &a.bytes);
                try head.appendSlice(allocator, &word);
            },
            .u256_, .u64_ => {
                const v = paramU256(obj, p.name) orelse return error.MissingParam;
                var word: [32]u8 = undefined;
                std.mem.writeInt(u256, &word, v, .big);
                try head.appendSlice(allocator, &word);
            },
            .str, .bytes => {
                const payload: []const u8 = if (p.kind == .bytes) blk: {
                    // JSON mangles raw bytes (invalid UTF-8 becomes U+FFFD), so the
                    // fetch SELECT projects hex(parameters['<name>']) AS hexp_<name>
                    // server-side; that column is the only lossless source.
                    var kbuf: [64]u8 = undefined;
                    const hex_key = std.fmt.bufPrint(&kbuf, "hexp_{s}", .{p.name}) catch return error.BadParam;
                    const hexed = if (row) |r| jsonStr(r, hex_key) else null;
                    const body = body_blk: {
                        if (hexed) |h| {
                            if (h.len > 0) break :body_blk h;
                        }
                        const raw = jsonStr(obj, p.name) orelse return error.MissingParam;
                        break :body_blk (if (std.mem.startsWith(u8, raw, "0x")) raw[2..] else raw);
                    };
                    const buf = try allocator.alloc(u8, body.len / 2);
                    errdefer allocator.free(buf);
                    _ = std.fmt.hexToBytes(buf, body) catch return error.BadParam;
                    break :blk buf;
                } else jsonStr(obj, p.name) orelse return error.MissingParam;
                defer if (p.kind == .bytes) allocator.free(@constCast(payload));

                var off_word: [32]u8 = undefined;
                std.mem.writeInt(u256, &off_word, @intCast(head_len + tail.items.len), .big);
                try head.appendSlice(allocator, &off_word);

                var len_word: [32]u8 = undefined;
                std.mem.writeInt(u256, &len_word, @intCast(payload.len), .big);
                try tail.appendSlice(allocator, &len_word);
                try tail.appendSlice(allocator, payload);
                const pad = (32 - (payload.len % 32)) % 32;
                try tail.appendNTimes(allocator, 0, pad);
            },
        }
    }

    const out = try allocator.alloc(u8, head.items.len + tail.items.len);
    @memcpy(out[0..head.items.len], head.items);
    @memcpy(out[head.items.len..], tail.items);
    return out;
}

// ============================================================================
// Timestamp parsing
// ============================================================================

fn daysFromCivil(y_in: i64, m: u32, d: u32) i64 {
    // Howard Hinnant's civil-days algorithm.
    const y: i64 = if (m <= 2) y_in - 1 else y_in;
    const era: i64 = @divFloor(y, 400);
    const yoe: u64 = @intCast(y - era * 400);
    const mp: u64 = (@as(u64, m) + 9) % 12;
    const doy: u64 = (153 * mp + 2) / 5 + d - 1;
    const doe: u64 = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + @as(i64, @intCast(doe)) - 719468;
}

/// "2026-07-17T19:13:57.000Z" (base.events DateTime64) -> unix seconds.
pub fn parseIsoTimestamp(s: []const u8) ?i64 {
    if (s.len < 19) return null;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const mo = std.fmt.parseInt(u32, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(u32, s[8..10], 10) catch return null;
    const h = std.fmt.parseInt(i64, s[11..13], 10) catch return null;
    const mi = std.fmt.parseInt(i64, s[14..16], 10) catch return null;
    const sec = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
    return daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + sec;
}

/// RFC 1123 Date header: "Fri, 17 Jul 2026 19:13:14 GMT" -> unix seconds.
pub fn parseHttpDate(s: []const u8) ?i64 {
    if (s.len < 29) return null;
    const d = std.fmt.parseInt(u32, s[5..7], 10) catch return null;
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    var mo: u32 = 0;
    for (months, 1..) |m, i| {
        if (std.mem.eql(u8, s[8..11], m)) mo = @intCast(i);
    }
    if (mo == 0) return null;
    const y = std.fmt.parseInt(i64, s[12..16], 10) catch return null;
    const h = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
    const mi = std.fmt.parseInt(i64, s[20..22], 10) catch return null;
    const sec = std.fmt.parseInt(i64, s[23..25], 10) catch return null;
    return daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + sec;
}

// ============================================================================
// CDP client (Ed25519 JWT, server-time anchored)
// ============================================================================

pub const CdpClient = struct {
    allocator: std.mem.Allocator,
    http_client: *std.http.Client,
    key_id: []const u8,
    key_pair: Ed25519.KeyPair,
    /// server_time - local_time, learned from the Date header before the first
    /// authenticated call. A skewed local clock otherwise mints expired JWTs.
    time_offset: i64,

    pub fn init(allocator: std.mem.Allocator, http_client: *std.http.Client, key_id: []const u8, secret_b64: []const u8) !CdpClient {
        var secret: [64]u8 = undefined;
        const dec = std.base64.standard.Decoder;
        const n = dec.calcSizeForSlice(secret_b64) catch return error.BadSecret;
        if (n != 64) return error.BadSecret;
        dec.decode(&secret, secret_b64) catch return error.BadSecret;
        const kp = Ed25519.KeyPair.fromSecretKey(Ed25519.SecretKey.fromBytes(secret) catch return error.BadSecret) catch return error.BadSecret;

        var self = CdpClient{
            .allocator = allocator,
            .http_client = http_client,
            .key_id = key_id,
            .key_pair = kp,
            .time_offset = 0,
        };
        self.time_offset = self.fetchTimeOffset() catch |err| blk: {
            std.log.warn("CDP intake: server-time fetch failed ({}); JWTs will use the LOCAL clock — a skewed clock then yields 401s/closed connections", .{err});
            break :blk 0;
        };
        return self;
    }

    fn fetchTimeOffset(self: *CdpClient) !i64 {
        const uri = try std.Uri.parse("https://" ++ CDP_HOST ++ "/");
        var req = try self.http_client.request(.HEAD, uri, .{
            .redirect_behavior = .not_allowed,
            .keep_alive = false,
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
        });
        defer req.deinit();
        try req.sendBodiless();
        var redirect_buf: [1024]u8 = undefined;
        const response = try req.receiveHead(&redirect_buf);
        var it = response.head.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "date")) {
                const server_now = parseHttpDate(h.value) orelse return error.BadDate;
                const offset = server_now - zsys.timestamp();
                std.log.info("CDP intake: local clock offset vs server = {d}s (JWTs anchored to server time)", .{offset});
                return offset;
            }
        }
        return error.NoDateHeader;
    }

    fn b64url(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        const enc = std.base64.url_safe_no_pad.Encoder;
        const out = try allocator.alloc(u8, enc.calcSize(data.len));
        _ = enc.encode(out, data);
        return out;
    }

    fn makeJwt(self: *CdpClient, allocator: std.mem.Allocator) ![]u8 {
        var nonce: [16]u8 = undefined;
        var rng_bytes: [16]u8 = undefined;
        zsys.randomBytes(&rng_bytes);
        for (&nonce, rng_bytes) |*c, r| c.* = '0' + (r % 10);

        const now = zsys.timestamp() + self.time_offset;
        const header = try std.fmt.allocPrint(allocator, "{{\"alg\":\"EdDSA\",\"typ\":\"JWT\",\"kid\":\"{s}\",\"nonce\":\"{s}\"}}", .{ self.key_id, nonce });
        defer allocator.free(header);
        const payload = try std.fmt.allocPrint(allocator, "{{\"sub\":\"{s}\",\"iss\":\"cdp\",\"nbf\":{d},\"exp\":{d},\"uris\":[\"POST {s}{s}\"]}}", .{ self.key_id, now, now + 115, CDP_HOST, CDP_PATH });
        defer allocator.free(payload);

        const h64 = try b64url(allocator, header);
        defer allocator.free(h64);
        const p64 = try b64url(allocator, payload);
        defer allocator.free(p64);
        const msg = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ h64, p64 });
        defer allocator.free(msg);

        const sig = self.key_pair.sign(msg, null) catch return error.SignFailed;
        const sig_bytes = sig.toBytes();
        const s64 = try b64url(allocator, &sig_bytes);
        defer allocator.free(s64);

        return std.fmt.allocPrint(allocator, "{s}.{s}", .{ msg, s64 });
    }

    /// Run one SQL query with bounded transport retries; returns the owned raw
    /// JSON response body.
    pub fn run(self: *CdpClient, allocator: std.mem.Allocator, sql: []const u8) ![]u8 {
        var attempt: u32 = 0;
        while (true) {
            return self.runOnce(allocator, sql) catch |err| switch (err) {
                error.CdpHttpError, error.CdpBodyTooLarge => return err,
                else => {
                    attempt += 1;
                    if (attempt >= 4) return err;
                    std.log.warn("CDP query transport error ({}), retry {d}/3", .{ err, attempt });
                    zsys.sleep(2 * std.time.ns_per_s);
                    continue;
                },
            };
        }
    }

    fn runOnce(self: *CdpClient, allocator: std.mem.Allocator, sql: []const u8) ![]u8 {
        const jwt = try self.makeJwt(allocator);
        defer allocator.free(jwt);
        const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{jwt});
        defer allocator.free(auth);

        const body_json = try std.json.Stringify.valueAlloc(allocator, .{ .sql = sql }, .{});
        defer allocator.free(body_json);

        const uri = try std.Uri.parse("https://" ++ CDP_HOST ++ CDP_PATH);
        const extra_headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Authorization", .value = auth },
        };
        var req = try self.http_client.request(.POST, uri, .{
            .redirect_behavior = .not_allowed,
            .keep_alive = false,
            .extra_headers = &extra_headers,
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
        });
        defer req.deinit();
        req.transfer_encoding = .{ .content_length = body_json.len };
        const body_mut = try allocator.dupe(u8, body_json);
        defer allocator.free(body_mut);
        try req.sendBodyComplete(body_mut);

        var redirect_buf: [1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);
        if (@intFromEnum(response.head.status) != 200) {
            var err_buf: [4096]u8 = undefined;
            const err_rdr = response.reader(&err_buf);
            const err_body = err_rdr.allocRemaining(allocator, .limited(4096)) catch null;
            defer if (err_body) |b| allocator.free(b);
            std.log.err("CDP query HTTP {d}: {s}", .{ @intFromEnum(response.head.status), err_body orelse "" });
            return error.CdpHttpError;
        }
        var transfer_buf: [16 * 1024]u8 = undefined;
        const rdr = response.reader(&transfer_buf);
        return rdr.allocRemaining(allocator, .limited(MAX_RESPONSE_BYTES)) catch return error.CdpBodyTooLarge;
    }
};

// ============================================================================
// Row -> rpc.Log mapping
// ============================================================================

pub const MappedLog = struct {
    log: rpc.Log,
    pub fn deinit(self: *MappedLog, allocator: std.mem.Allocator) void {
        allocator.free(self.log.topics);
        allocator.free(self.log.data);
    }
};

/// Map one base.events row (JSON object) into an rpc.Log the handlers accept.
/// Returns null (with a warn) when a required field is missing or no spec covers
/// the topic0 — callers count those.
pub fn mapRow(allocator: std.mem.Allocator, row: std.json.ObjectMap) !?MappedLog {
    const address = Address.fromHex(jsonStr(row, "address") orelse return null) catch return null;
    const topics_v = row.get("topics") orelse return null;
    const topics_arr = switch (topics_v) {
        .array => |a| a,
        else => return null,
    };
    if (topics_arr.items.len == 0) return null;

    var topics = try allocator.alloc(Hash, topics_arr.items.len);
    errdefer allocator.free(topics);
    for (topics_arr.items, 0..) |t, i| {
        const th = switch (t) {
            .string => |s| Hash.fromHex(s) catch return null,
            else => return null,
        };
        topics[i] = th;
    }

    const spec = findSpec(topics[0]) orelse {
        allocator.free(topics);
        return null;
    };
    const params_val = row.get("parameters") orelse std.json.Value.null;
    const data = blk: {
        if (params_val == .object) {
            break :blk encodeDataTail(allocator, spec, params_val.object, row) catch |err| {
                var t0_buf: [66]u8 = undefined;
                std.log.warn("CDP intake: encode failed for topic {s}: {}", .{ topics[0].toHexBuf(&t0_buf), err });
                allocator.free(topics);
                return null;
            };
        }
        if (spec.params.len != 0) {
            allocator.free(topics);
            return null;
        }
        break :blk try allocator.alloc(u8, 0);
    };
    errdefer allocator.free(data);

    const block_number = paramU256(row, "block_number") orelse return null;
    const log_index: u32 = switch (row.get("log_index") orelse return null) {
        .integer => |i| @intCast(i),
        .string => |s| std.fmt.parseInt(u32, s, 10) catch return null,
        else => return null,
    };
    const tx_hash = Hash.fromHex(jsonStr(row, "transaction_hash") orelse return null) catch return null;
    const block_hash: ?Hash = if (jsonStr(row, "block_hash")) |bh| (Hash.fromHex(bh) catch null) else null;
    const ts: ?u64 = if (jsonStr(row, "block_timestamp")) |t|
        (if (parseIsoTimestamp(t)) |e| @intCast(e) else null)
    else
        null;

    return MappedLog{ .log = .{
        .address = address,
        .topics = topics,
        .data = data,
        .block_number = @intCast(block_number),
        .transaction_hash = tx_hash,
        .transaction_index = 0,
        .log_index = log_index,
        .removed = false,
        .block_timestamp = ts,
        .block_hash = block_hash,
    } };
}

// ============================================================================
// Tests (hermetic — no network)
// ============================================================================

test "specs re-encode into exactly what the handlers' decoders expect" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"expires":"1815851638","resolver":"0x426fa03fb86e510d0dd9f70335cf102a98b10875","ttl":"0",
        \\ "name":"jesse","owner":"0x03d1dd2eac1e12c273d77e5b783a10587d943a79",
        \\ "coinType":"60","newAddress":"0x03d1dd2eac1e12c273d77e5b783a10587d943a79",
        \\ "key":"avatar","value":"https://a.example/x.png"}
    , .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    // WithRecord: (uint256 expires, address resolver, uint64 ttl)
    {
        const spec = findSpec(ES.basenames_registrar_name_registered_with_record_hash).?;
        const data = try encodeDataTail(allocator, spec, obj, null);
        defer allocator.free(data);
        const vals = try abi.decodeValues(data, &.{ .uint256, .address, .uint64 }, allocator);
        defer abi.freeValues(vals, allocator);
        try testing.expectEqual(@as(u256, 1815851638), vals[0].uint256);
        const r = Address{ .bytes = vals[1].address };
        try testing.expect(r.eql(try Address.fromHex("0x426fa03fb86e510d0dd9f70335cf102a98b10875")));
    }
    // Basenames controller registered: (string name, uint256 expires)
    {
        const spec = findSpec(ES.basenames_controller_name_registered_hash).?;
        const data = try encodeDataTail(allocator, spec, obj, null);
        defer allocator.free(data);
        const vals = try abi.decodeValues(data, &.{ .string, .uint256 }, allocator);
        defer abi.freeValues(vals, allocator);
        try testing.expectEqualStrings("jesse", vals[0].string);
        try testing.expectEqual(@as(u256, 1815851638), vals[1].uint256);
    }
    // AddressChanged: (uint256 coinType, bytes newAddress)
    {
        const spec = findSpec(ES.address_changed_hash).?;
        const data = try encodeDataTail(allocator, spec, obj, null);
        defer allocator.free(data);
        const vals = try abi.decodeValues(data, &.{ .uint256, .bytes }, allocator);
        defer abi.freeValues(vals, allocator);
        try testing.expectEqual(@as(u256, 60), vals[0].uint256);
        try testing.expectEqual(@as(usize, 20), vals[1].bytes.len);
    }
    // TextChanged tail: (string key, string value)
    {
        const spec = findSpec(ES.text_changed_hash).?;
        const data = try encodeDataTail(allocator, spec, obj, null);
        defer allocator.free(data);
        const vals = try abi.decodeValues(data, &.{ .string, .string }, allocator);
        defer abi.freeValues(vals, allocator);
        try testing.expectEqualStrings("avatar", vals[0].string);
        try testing.expectEqualStrings("https://a.example/x.png", vals[1].string);
    }
    // NewOwner: (address owner)
    {
        const spec = findSpec(ES.new_owner_hash).?;
        const data = try encodeDataTail(allocator, spec, obj, null);
        defer allocator.free(data);
        const vals = try abi.decodeValues(data, &.{.address}, allocator);
        defer abi.freeValues(vals, allocator);
        const o = Address{ .bytes = vals[0].address };
        try testing.expect(o.eql(try Address.fromHex("0x03d1dd2eac1e12c273d77e5b783a10587d943a79")));
    }
}

test "timestamp parsers: ISO event time and RFC1123 Date header" {
    const testing = std.testing;
    // 2026-07-17T19:13:57Z (cross-checked externally)
    try testing.expectEqual(@as(i64, 1784315637), parseIsoTimestamp("2026-07-17T19:13:57.000Z").?);
    try testing.expectEqual(@as(i64, 1784315594), parseHttpDate("Fri, 17 Jul 2026 19:13:14 GMT").?);
    // Epoch sanity: 1970-01-01
    try testing.expectEqual(@as(i64, 0), parseIsoTimestamp("1970-01-01T00:00:00.000Z").?);
    try testing.expect(parseIsoTimestamp("garbage") == null);
    try testing.expect(parseHttpDate("garbage-garbage-garbage-garbage") == null);
}

test "mapRow reconstructs an rpc.Log from a real WithRecord row" {
    const testing = std.testing;
    const allocator = testing.allocator;
    // Verbatim row captured from base.events on 2026-07-17 (block 48763145).
    const row_json =
        \\{"address":"0x03c4738ee98ae44591e1a4a4f3cab6641d95dd9a",
        \\ "block_hash":"0xc7e92a4fddce50cf4d19048ab7249cbe450cfb3ef36c3c9475c8d5daf6df90a9",
        \\ "block_number":"48763145","block_timestamp":"2026-07-17T19:13:57.000Z",
        \\ "event_name":"NameRegisteredWithRecord","log_index":255,
        \\ "parameters":{"expires":"1815851638",
        \\   "id":"60092119045912026813912492955088590263475162984377270772321167981595280632606",
        \\   "owner":"0x03d1dd2eac1e12c273d77e5b783a10587d943a79",
        \\   "resolver":"0x426fa03fb86e510d0dd9f70335cf102a98b10875","ttl":"0"},
        \\ "topics":["0xfd724d251af149ea2929b9061ddab2bb31e2d87778cc0acfa1d68add62e222e8",
        \\   "0x84daef1fbab867b965e7e148bc29b05722c36ab6262c5988a11a7792a8656b1e",
        \\   "0x00000000000000000000000003d1dd2eac1e12c273d77e5b783a10587d943a79"],
        \\ "transaction_hash":"0x2d580f6837cf61e88d53a9dfc69bc59ce576d9c5dd1a229a38ec0f1bbbe53816"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, row_json, .{});
    defer parsed.deinit();

    var mapped = (try mapRow(allocator, parsed.value.object)) orelse return error.MapFailed;
    defer mapped.deinit(allocator);
    const log = mapped.log;

    try testing.expectEqual(@as(u64, 48763145), log.block_number);
    try testing.expectEqual(@as(u32, 255), log.log_index);
    try testing.expectEqual(@as(usize, 3), log.topics.len);
    try testing.expect(log.topics[0].eql(ES.basenames_registrar_name_registered_with_record_hash));
    try testing.expectEqual(@as(u64, 1784315637), log.block_timestamp.?);
    // The re-encoded tail decodes with the WithRecord handler's exact type list.
    const vals = try abi.decodeValues(log.data, &.{ .uint256, .address, .uint64 }, allocator);
    defer abi.freeValues(vals, allocator);
    try testing.expectEqual(@as(u256, 1815851638), vals[0].uint256);
}

// ============================================================================
// Backfill driver
// ============================================================================

fn collectAddresses(idx: *Indexer, allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) !void {
    const cfg = idx.config.v1_contracts;
    const fixed = [_]Address{ cfg.ens_registry, cfg.base_registrar, cfg.eth_registrar_controller, cfg.public_resolver, cfg.eth_reverse_registrar };
    for (fixed) |a| {
        if (a.isZero()) continue;
        try list.append(allocator, try a.toHex(allocator));
    }
    // Discovered controllers + known resolvers grow the set between pages.
    appendAddrsFromSql(idx, allocator, list, "SELECT DISTINCT controller_address FROM v1_controllers WHERE is_active = 1") catch {};
    appendAddrsFromSql(idx, allocator, list, "SELECT DISTINCT address FROM known_resolvers WHERE protocol = 'v1'") catch {};
}

fn countDiscovered(idx: *Indexer) u64 {
    const db_mod = @import("../storage/database.zig");
    var total: u64 = 0;
    for ([_][]const u8{ "SELECT COUNT(*) FROM v1_controllers", "SELECT COUNT(*) FROM known_resolvers WHERE protocol = 'v1'" }) |sql| {
        var q = db_mod.Query.init(idx.database, sql) catch continue;
        defer q.deinit();
        if (q.step() catch false) total += @intCast(q.getInt64(0));
    }
    return total;
}

fn appendAddrsFromSql(idx: *Indexer, allocator: std.mem.Allocator, list: *std.ArrayList([]u8), sql: []const u8) !void {
    const db_mod = @import("../storage/database.zig");
    var q = try db_mod.Query.init(idx.database, sql);
    defer q.deinit();
    while (try q.step()) {
        const a = q.getTextSlice(0) orelse continue;
        var dup = false;
        for (list.items) |existing| {
            if (std.ascii.eqlIgnoreCase(existing, a)) {
                dup = true;
                break;
            }
        }
        if (!dup) try list.append(allocator, try std.ascii.allocLowerString(allocator, a));
    }
}

/// Honor the standard https_proxy/HTTPS_PROXY env (production proxies and the
/// sandbox's egress firewall alike). Best-effort: a malformed value is ignored.
fn setupProxyFromEnv(client: *std.http.Client, allocator: std.mem.Allocator) void {
    const purl = zsys.getenv("https_proxy") orelse zsys.getenv("HTTPS_PROXY") orelse return;
    if (purl.len == 0) return;
    const uri = std.Uri.parse(purl) catch return;
    const host = uri.getHostAlloc(allocator) catch return;
    const proxy = allocator.create(std.http.Client.Proxy) catch return;
    proxy.* = .{
        .protocol = .plain,
        .host = host,
        .authorization = null,
        .port = uri.port orelse 80,
        .supports_connect = true,
    };
    client.https_proxy = proxy;
}

fn dispatchLog(idx: *Indexer, log: rpc.Log) !bool {
    const cfg = idx.config.v1_contracts;
    const t0 = log.topics[0];
    if (log.address.eql(cfg.ens_registry)) {
        inline for (event_config.V1_REGISTRY_EVENTS) |ec| {
            if (t0.eql(ec.event_hash)) {
                try ec.handler(idx, .v1, log);
                return true;
            }
        }
    } else if (log.address.eql(cfg.base_registrar)) {
        inline for (event_config.V1_BASE_REGISTRAR_EVENTS) |ec| {
            if (t0.eql(ec.event_hash)) {
                try ec.handler(idx, .v1, log);
                return true;
            }
        }
    } else if (log.address.eql(cfg.eth_reverse_registrar)) {
        inline for (event_config.V2_REVERSE_REGISTRAR_EVENTS) |ec| {
            if (t0.eql(ec.event_hash)) {
                // Same protocol tag the live V2-pass scan uses for this surface.
                try ec.handler(idx, .v2, log);
                return true;
            }
        }
    } else {
        // Controllers (discovered set) share topic-disjoint tables with resolvers,
        // so try the controller table first, then the resolver table.
        inline for (event_config.V1_ETH_CONTROLLER_EVENTS) |ec| {
            if (t0.eql(ec.event_hash)) {
                try ec.handler(idx, .v1, log);
                return true;
            }
        }
        inline for (event_config.RESOLVER_EVENTS) |ec| {
            if (t0.eql(ec.event_hash)) {
                try ec.handler(idx, .v1, log.address, log);
                return true;
            }
        }
    }
    return false;
}

/// Bulk-backfill from the CDP SQL API: [from, to] inclusive, keyset-paged in
/// (block_number, log_index) order, feeding the standard dispatch tables. Sets
/// sync_state for both protocols at the end so the RPC follow-up resumes there.
pub fn runCdpBackfill(idx: *Indexer, from_opt: ?u64, to_opt: ?u64) !void {
    const allocator = idx.allocator;
    const key_id = zsys.getenv("BASE_CDP_CLIENT_KEY") orelse return error.MissingCdpKeyId;
    const secret = zsys.getenv("BASE_CDP_SECRET_KEY") orelse return error.MissingCdpSecret;

    // Own HTTP client: honoring https_proxy here must never redirect the RPC
    // path (deployments often relay RPC separately from general egress).
    var http_client = std.http.Client{ .allocator = allocator, .io = idx.io };
    defer http_client.deinit();
    setupProxyFromEnv(&http_client, allocator);
    var client = try CdpClient.init(allocator, &http_client, key_id, secret);

    // Deep-finalized history: disarm reorg capture exactly like bulk sync.
    reorg_undo.clearCursor(idx.database, .v1) catch {};
    reorg_undo.clearCursor(idx.database, .v2) catch {};
    idx.invalidateReorgCursor();
    idx.reorg_arm = false;

    const from = from_opt orelse ((idx.database.getSyncState(.v1) catch null) orelse idx.config.start_block);
    const to = to_opt orelse blk: {
        const body = try client.run(allocator, "SELECT MAX(block_number) AS head FROM base.blocks");
        defer allocator.free(body);
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.CdpBadResponse;
        defer parsed.deinit();
        const rows = switch (parsed.value.object.get("result") orelse return error.CdpBadResponse) {
            .array => |a| a,
            else => return error.CdpBadResponse,
        };
        if (rows.items.len == 0) return error.CdpBadResponse;
        const head = paramU256(rows.items[0].object, "head") orelse return error.CdpBadResponse;
        break :blk @as(u64, @intCast(head));
    };
    std.log.info("CDP intake: backfilling blocks {d}..{d}", .{ from, to });

    var last_bn: u64 = if (from == 0) 0 else from - 1;
    var last_li: i64 = std.math.maxInt(i32); // strictly-after sentinel for the first page
    var processed: u64 = 0;
    var skipped_unspecced: u64 = 0;
    var pages: u64 = 0;

    var discovered_before: u64 = 0;
    while (true) {
        const page_start_bn = last_bn;
        const page_start_li = last_li;
        var addrs: std.ArrayList([]u8) = .empty;
        defer {
            for (addrs.items) |a| allocator.free(a);
            addrs.deinit(allocator);
        }
        try collectAddresses(idx, allocator, &addrs);
        var in_list: std.ArrayList(u8) = .empty;
        defer in_list.deinit(allocator);
        for (addrs.items, 0..) |a, i| {
            if (i > 0) try in_list.append(allocator, ',');
            try in_list.print(allocator, "'{s}'", .{a});
        }

        const sql = try std.fmt.allocPrint(allocator,
            \\SELECT address, block_number, log_index, topics, parameters,
            \\       transaction_hash, block_hash, block_timestamp,
            \\       hex(CAST(parameters['newAddress'] AS String)) AS hexp_newAddress,
            \\       hex(CAST(parameters['hash'] AS String)) AS hexp_hash
            \\FROM base.events
            \\WHERE address IN ({s})
            \\  AND block_number <= {d}
            \\  AND (block_number > {d} OR (block_number = {d} AND log_index > {d}))
            \\ORDER BY block_number, log_index
            \\LIMIT {d}
        , .{ in_list.items, to, last_bn, last_bn, last_li, PAGE_LIMIT });
        defer allocator.free(sql);

        const body = try client.run(allocator, sql);
        defer allocator.free(body);
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.CdpBadResponse;
        defer parsed.deinit();
        const result_v = parsed.value.object.get("result") orelse std.json.Value.null;
        const rows = switch (result_v) {
            .array => |a| a,
            else => break, // null result = empty page
        };
        if (rows.items.len == 0) break;
        pages += 1;

        try idx.database.beginTransaction();
        errdefer idx.database.rollbackTransaction();
        for (rows.items) |row_v| {
            const row = switch (row_v) {
                .object => |o| o,
                else => continue,
            };
            const bn = paramU256(row, "block_number") orelse continue;
            last_bn = @intCast(bn);
            last_li = switch (row.get("log_index") orelse std.json.Value.null) {
                .integer => |i| i,
                .string => |s| std.fmt.parseInt(i64, s, 10) catch last_li,
                else => last_li,
            };
            var mapped = (try mapRow(allocator, row)) orelse {
                skipped_unspecced += 1;
                continue;
            };
            defer mapped.deinit(allocator);
            if (dispatchLog(idx, mapped.log) catch |err| blk: {
                std.log.warn("CDP intake: handler error at block {d} log {d}: {}", .{ mapped.log.block_number, mapped.log.log_index, err });
                break :blk false;
            }) {
                processed += 1;
            } else {
                skipped_unspecced += 1;
            }
        }
        try idx.database.commitTransaction();

        // Contract discovery (ControllerAdded / NewResolver) grows the address set
        // MID-page; events those contracts emitted within this same page were not
        // in the query's address list. Rewind and reprocess the window with the
        // grown set — every write on this path is an idempotent upsert. Growth is
        // monotonic and bounded, so this terminates.
        const discovered_now = countDiscovered(idx);
        if (discovered_now > discovered_before) {
            std.log.info("CDP intake: {d} newly discovered contract(s); reprocessing window from block {d}", .{ discovered_now - discovered_before, page_start_bn });
            discovered_before = discovered_now;
            last_bn = page_start_bn;
            last_li = page_start_li;
            continue;
        }
        discovered_before = discovered_now;

        if (pages % 20 == 0) {
            std.log.info("CDP intake: block {d}/{d}, {d} events processed, {d} skipped (no spec/table)", .{ last_bn, to, processed, skipped_unspecced });
        }
        if (rows.items.len < PAGE_LIMIT) break;
    }

    try idx.database.setSyncState(.v1, to);
    try idx.database.setSyncState(.v2, to);
    std.log.info("CDP intake complete: {d} events processed, {d} skipped, {d} pages, sync head set to {d}", .{ processed, skipped_unspecced, pages, to });
}
