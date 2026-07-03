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
        }) catch return null;
        defer req.deinit();

        // Bound a silent gateway: reads/writes past timeout_ms now error out. The
        // Connection's own getStream is private, but its stream_reader exposes a pub one.
        if (req.connection) |conn| setStreamTimeout(conn.stream_reader.getStream().handle, self.timeout_ms);

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

        // We advertise gzip/deflate (client default), so we MUST decode them — reading raw
        // would truncate/garble a compressed body. Size the decode window by the response's
        // content-encoding; zstd/compress aren't advertised, so reject rather than carry a
        // huge window buffer.
        var transfer_buffer: [4096]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        var flate_window: [std.compress.flate.max_window_len]u8 = undefined;
        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .gzip, .deflate => &flate_window,
            .zstd, .compress => return null,
        };
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
        // Read the ENTIRE decompressed body — allocRemaining loops until end-of-stream
        // (a single stream() would capture only one segment) — hard-capped, so a chunked
        // or multi-segment gateway can't truncate us or OOM us. Any error → degrade.
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

test "setStreamTimeout makes a silent socket read time out instead of blocking forever" {
    const testing = std.testing;
    // A bound UDP socket with nothing ever sent to it: with a short SO_RCVTIMEO, recv must
    // return promptly with an error rather than hang — proving the timeout mechanism the
    // gateway fetch relies on actually fires.
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    defer std.posix.close(sock);
    try std.posix.bind(sock, &addr.any, addr.getOsSockLen());

    setStreamTimeout(sock, 50); // 50 ms
    var buf: [1]u8 = undefined;
    const start = std.time.milliTimestamp();
    const result = std.posix.recv(sock, &buf, 0);
    const elapsed = std.time.milliTimestamp() - start;

    try testing.expect(std.meta.isError(result)); // timed out (WouldBlock), not data
    try testing.expect(elapsed >= 40 and elapsed < 2000); // fired ~50ms, did not hang
}
