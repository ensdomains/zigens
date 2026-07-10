//! Real CCIP-Read transport (Task 07 Increment 3): the network-backed implementation of
//! `ccip.Transport`, used by production when RESOLVE_CCIP_ENABLED. Gateway fetches go over
//! `std.http.Client`; the EIP-3668 callback goes over the RPC client's revert-exposing
//! `ethCallAllowRevert`. The pure loop in ccip.zig stays transport-injected, so this file
//! is the only place that touches the network — and it treats gateway responses as
//! untrusted.
//!
//! Hardening against a hostile/slow gateway:
//!   - https-only (SSRF): reject any non-https URL.
//!   - no redirects: a 3xx gateway response errors (no arbitrary redirect chains).
//!   - hard response-size cap: the body reader is bounded, so a gateway cannot make us
//!     buffer unbounded data.
//!   - identity-only encoding: compressed responses are rejected at the head — an
//!     untrusted gateway never gets to choose a coding that amplifies bytes (gzip
//!     bombs) or exercises the decompressor at all (see httpFetch).
//!   - SOCKET RECEIVE/SEND TIMEOUT: SO_RCVTIMEO/SO_SNDTIMEO are set on the gateway
//!     connection, so a gateway that completes the handshake then goes silent (the main
//!     slowloris vector) hits `timeout_ms` and errors out instead of stalling the request.
//!     We use the lower-level `Client.request` (not `fetch`) specifically to reach the
//!     connection socket. The TCP connect + TLS handshake phase is still bounded only by
//!     the OS's connect timeout (finite, but longer than `timeout_ms`); a fully bounded
//!     connect needs non-blocking connect, a later refinement.
//!
//! Any failure at any step returns null → the loop degrades to the indexed miss.

const std = @import("std");
const zsys = @import("../utils/system.zig");
const ccip = @import("ccip.zig");
const rpc = @import("../rpc/client.zig");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;

/// Default cap on a single gateway response body.
pub const DEFAULT_MAX_RESPONSE: usize = 256 * 1024;

/// Set a receive + send timeout on a socket so a stalled peer can't block us forever.
/// Best-effort: a setsockopt failure is ignored (the fetch then relies on OS defaults).
fn setStreamTimeout(handle: std.posix.socket_t, timeout_ms: u32) void {
    if (timeout_ms == 0) return;
    const tv = std.posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    const bytes = std.mem.asBytes(&tv);
    std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, bytes) catch {};
    std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, bytes) catch {};
}

/// Per-request real transport. Build one on the stack per GraphQL request that may resolve
/// offchain, and pass `.transport()` into universal.CcipParams. Its lifetime must span the
/// synchronous resolution call.
pub const RealTransport = struct {
    http_client: *std.http.Client,
    rpc_client: *rpc.Client,
    /// Pin the callback eth_call to the same head block the API is reading at.
    block_hash: Hash,
    timeout_ms: u32,
    max_response_bytes: usize = DEFAULT_MAX_RESPONSE,

    pub fn transport(self: *RealTransport) ccip.Transport {
        return .{ .ctx = self, .httpFetch = httpFetch, .ethCall = ethCall };
    }

    fn httpFetch(ctx: *anyopaque, allocator: std.mem.Allocator, method: ccip.HttpMethod, url: []const u8, body: ?[]const u8) ?[]u8 {
        const self: *RealTransport = @ptrCast(@alignCast(ctx));
        // SSRF hardening: only fetch https gateways (reject http/file/gopher/etc.).
        if (!std.mem.startsWith(u8, url, "https://")) return null;

        const uri = std.Uri.parse(url) catch return null;
        const m: std.http.Method = if (method == .get) .GET else .POST;
        const extra_headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        };
        var req = self.http_client.request(m, uri, .{
            .redirect_behavior = .not_allowed, // no arbitrary redirect chains (EIP-3668 safety)
            .keep_alive = false, // dedicated connection; our timeout socket isn't pooled
            .extra_headers = &extra_headers,
            // Negotiate identity so the flate decompressor stays out of the path. 0.15.2's
            // could panic (unreachableRebase) on a match straddling the per-call stream
            // limit; 0.16 fixed that, so for an UNTRUSTED gateway identity now guards
            // against decompression-bomb amplification (std's decompressing reader has no
            // output cap) rather than a panic. Must be this `headers` override (sendHead's
            // emitOverridableHeader replaces the default line): an "Accept-Encoding" entry
            // in `extra_headers` is emitted IN ADDITION to std's default
            // "accept-encoding: gzip, deflate" line, and the gateway could still pick gzip.
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
        }) catch return null;
        defer req.deinit();
        // Belt-and-braces for a non-compliant gateway that compresses anyway: accept only
        // identity bodies, so receiveHead rejects any compressed response outright
        // (HttpContentEncodingUnsupported → null) instead of handing us compressed bytes.
        req.accept_encoding = comptime blk: {
            var enc: @TypeOf(req.accept_encoding) = @splat(false);
            enc[@intFromEnum(std.http.ContentEncoding.identity)] = true;
            break :blk enc;
        };

        // Bound a silent gateway: reads/writes past timeout_ms now error out. The
        // Connection's own getStream is private, but its stream_reader (an
        // Io.net.Stream.Reader) exposes the Stream and its Socket as public fields; for
        // TLS connections stream_reader is still the raw TCP stream under the TLS client.
        if (req.connection) |conn| setStreamTimeout(conn.stream_reader.stream.socket.handle, self.timeout_ms);

        if (body) |payload| {
            req.transfer_encoding = .{ .content_length = payload.len };
            var w = req.sendBodyUnflushed(&.{}) catch return null;
            w.writer.writeAll(payload) catch return null;
            w.end() catch return null;
            req.connection.?.flush() catch return null;
        } else {
            req.sendBodiless() catch return null;
        }

        var redirect_buf: [1]u8 = undefined; // redirects disallowed → unused
        var response = req.receiveHead(&redirect_buf) catch return null;
        const code = @intFromEnum(response.head.status);
        if (code < 200 or code >= 300) return null;
        if (response.head.content_length) |cl| {
            if (cl > self.max_response_bytes) return null; // reject oversize up front
        }

        // Identity is negotiated AND enforced above, so read the body RAW — no decompressing
        // reader, flate's panic-prone path is never reachable. allocRemaining loops until
        // end-of-stream (a single stream() would capture only one segment), hard-capped so a
        // chunked or multi-segment gateway can't truncate us or OOM us. Any error → degrade.
        var transfer_buffer: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        return reader.allocRemaining(allocator, std.Io.Limit.limited(self.max_response_bytes)) catch null;
    }

    fn ethCall(ctx: *anyopaque, allocator: std.mem.Allocator, to: Address, data: []const u8) ccip.CallOutcome {
        const self: *RealTransport = @ptrCast(@alignCast(ctx));
        const cr = self.rpc_client.ethCallAllowRevert(to, data, .{ .hash = self.block_hash }) catch return .err;
        defer cr.deinit(self.rpc_client.allocator);
        return switch (cr) {
            .ok => |d| .{ .ok = allocator.dupe(u8, d) catch return .err },
            .reverted => |d| .{ .reverted = allocator.dupe(u8, d) catch return .err },
        };
    }
};

/// Test-only local HTTP peer: accept one connection, capture the request head into `out`,
/// then write `response` verbatim and close. Lets the tests below pin the exact std.http
/// wire behavior the identity negotiation depends on.
fn captureHeadAndRespond(io: std.Io, srv: *std.Io.net.Server, out: *std.ArrayList(u8), alloc: std.mem.Allocator, response: []const u8) void {
    const conn = srv.accept(io) catch return;
    defer conn.close(io);
    var buf: [4096]u8 = undefined;
    while (std.mem.indexOf(u8, out.items, "\r\n\r\n") == null) {
        const n = std.posix.read(conn.socket.handle, &buf) catch return;
        if (n == 0) break;
        out.appendSlice(alloc, buf[0..n]) catch return;
    }
    var write_buf: [256]u8 = undefined;
    var writer = conn.writer(io, &write_buf);
    writer.interface.writeAll(response) catch return;
    writer.interface.flush() catch return;
}

test "identity accept_encoding override emits exactly one accept-encoding header" {
    const testing = std.testing;
    // Regression pin for the fix's core mechanism: `headers.accept_encoding = .override`
    // must REPLACE std.http.Client's default "accept-encoding: gzip, deflate" line. (An
    // "Accept-Encoding" entry in `extra_headers` is emitted in ADDITION to the default —
    // duplicate headers a server may merge and still pick gzip from, re-arming the flate
    // decompressor hazard this transport and rpc/client.zig avoid.)
    const io = testing.io;
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    const thread = try std.Thread.spawn(.{}, captureHeadAndRespond, .{
        io, &server, &captured, testing.allocator, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok",
    });

    var client = std.http.Client{ .allocator = testing.allocator, .io = io };
    defer client.deinit();
    var url_buf: [48]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{server.socket.address.getPort()});
    const extra = [_]std.http.Header{.{ .name = "Content-Type", .value = "application/json" }};
    var body: std.Io.Writer.Allocating = .init(testing.allocator);
    defer body.deinit();
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = "{}",
        .extra_headers = &extra,
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
        .response_writer = &body.writer,
        .keep_alive = false,
    });
    thread.join();

    try testing.expectEqual(std.http.Status.ok, result.status);
    const head = try std.ascii.allocLowerString(testing.allocator, captured.items);
    defer testing.allocator.free(head);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, head, "accept-encoding:"));
    try testing.expect(std.mem.indexOf(u8, head, "accept-encoding: identity\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, head, "gzip") == null);
    try testing.expect(std.mem.indexOf(u8, head, "deflate") == null);
}

test "identity-only accept_encoding rejects a compressed response at receiveHead" {
    const testing = std.testing;
    // Belt-and-braces pin: with the accept_encoding array narrowed to identity (as
    // httpFetch does), a gateway that compresses anyway is refused at receiveHead with a
    // catchable error — the decompressor (and raw compressed bytes) are never reachable.
    const io = testing.io;
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    const thread = try std.Thread.spawn(.{}, captureHeadAndRespond, .{
        io,                                                                           &server, &captured, testing.allocator,
        "HTTP/1.1 200 OK\r\ncontent-encoding: gzip\r\ncontent-length: 4\r\n\r\nXXXX",
    });

    var client = std.http.Client{ .allocator = testing.allocator, .io = io };
    defer client.deinit();
    var url_buf: [48]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{server.socket.address.getPort()});
    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{
        .redirect_behavior = .not_allowed,
        .keep_alive = false,
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
    });
    defer req.deinit();
    req.accept_encoding = comptime blk: {
        var enc: @TypeOf(req.accept_encoding) = @splat(false);
        enc[@intFromEnum(std.http.ContentEncoding.identity)] = true;
        break :blk enc;
    };
    try req.sendBodiless();
    var redirect_buf: [1]u8 = undefined;
    try testing.expectError(error.HttpContentEncodingUnsupported, req.receiveHead(&redirect_buf));
    thread.join();
}

test "setStreamTimeout makes a silent socket read time out instead of blocking forever" {
    const testing = std.testing;
    // A bound UDP socket with nothing ever sent to it: with a short SO_RCVTIMEO, a blocking
    // read must return promptly with an error rather than hang — proving the timeout
    // mechanism the gateway fetch relies on actually fires. (0.16 dropped posix
    // socket/bind/recv; the socket comes from Io.net and the blocking read — read(2) waits
    // for a datagram on a UDP socket just like recv — from the surviving std.posix.read.)
    const io = testing.io;
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const sock = try addr.bind(io, .{ .mode = .dgram });
    defer sock.close(io);

    setStreamTimeout(sock.handle, 50); // 50 ms
    var buf: [1]u8 = undefined;
    const start = zsys.milliTimestamp();
    const result = std.posix.read(sock.handle, &buf);
    const elapsed = zsys.milliTimestamp() - start;

    try testing.expect(std.meta.isError(result)); // timed out (WouldBlock), not data
    try testing.expect(elapsed >= 40 and elapsed < 2000); // fired ~50ms, did not hang
}
