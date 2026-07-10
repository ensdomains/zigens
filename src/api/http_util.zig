//! HTTP and GraphQL-over-HTTP protocol helpers for the API server.
//!
//! Pure free functions over strings/allocators — no `Server` state — split out of
//! server.zig so the request-handling core stays focused. server.zig keeps
//! file-scope aliases (`const resolveClientAddress = http_util.resolveClientAddress;`
//! …) so its existing unqualified call sites are unchanged. Also home of `Conn`,
//! the blocking socket wrapper the handler clusters take instead of a raw stream.

const std = @import("std");
const parser = @import("../lib/graphql/parser.zig");

/// Blocking connection wrapper over a 0.16 `std.Io.net.Stream`. Reads and writes go
/// straight to the socket fd via libc: the 0.16 Stream Reader/Writer interfaces are
/// buffered and io-threaded, while the handlers were written against 0.15's plain
/// blocking read/write semantics — the fd-level calls preserve those exactly.
pub const Conn = struct {
    io: std.Io,
    stream: std.Io.net.Stream,

    pub const ReadError = error{ReadFailed};
    pub const WriteError = error{WriteFailed};

    fn lastErrno() std.c.E {
        return @enumFromInt(std.c._errno().*);
    }

    pub fn address(self: Conn) std.Io.net.IpAddress {
        return self.stream.socket.address;
    }

    /// Returns 0 at end of stream, like the old std.net.Stream.read.
    pub fn read(self: Conn, buffer: []u8) ReadError!usize {
        while (true) {
            const rc = std.c.read(self.stream.socket.handle, buffer.ptr, buffer.len);
            if (rc >= 0) return @intCast(rc);
            if (lastErrno() != .INTR) return error.ReadFailed;
        }
    }

    pub fn write(self: Conn, bytes: []const u8) WriteError!usize {
        while (true) {
            const rc = std.c.write(self.stream.socket.handle, bytes.ptr, bytes.len);
            if (rc >= 0) return @intCast(rc);
            if (lastErrno() != .INTR) return error.WriteFailed;
        }
    }

    pub fn writeAll(self: Conn, bytes: []const u8) WriteError!void {
        var index: usize = 0;
        while (index < bytes.len) {
            index += try self.write(bytes[index..]);
        }
    }

    pub fn close(self: Conn) void {
        self.stream.close(self.io);
    }
};

/// Find a header value (case-insensitive name) in a raw HTTP header block. Returns the
/// trimmed value or null. Handles CRLF and LF line endings.
fn findHeaderValue(header_data: []const u8, name_lower: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, header_data, '\n');
    while (lines.next()) |line0| {
        const line = std.mem.trimEnd(u8, line0, "\r");
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], name_lower)) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }
    return null;
}

/// Set a receive + send timeout on an accepted socket so a stalled or trickling peer
/// cannot pin a handler thread forever (slow-loris). Best-effort: a setsockopt failure
/// is ignored, so the caller's wall-clock request deadline remains the real backstop.
pub fn setStreamTimeout(handle: std.posix.socket_t, timeout_ms: u32) void {
    if (timeout_ms == 0) return;
    const tv = std.posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    const bytes = std.mem.asBytes(&tv);
    std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, bytes) catch {};
    std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, bytes) catch {};
}

pub const FramingError = error{
    ChunkedUnsupported,
    ContentLengthAndTransferEncoding,
    ConflictingContentLength,
    MalformedContentLength,
};

/// Determine the request body length from the header block (the bytes BEFORE the
/// blank-line terminator). Rejects framing this server does not safely support
/// rather than guessing a length, because an ambiguous body length is a
/// request-smuggling / desync vector:
///   - Transfer-Encoding present alongside Content-Length  -> CL.TE desync.
///   - Transfer-Encoding present alone (e.g. chunked)       -> not decoded here.
///   - Two Content-Length values that disagree             -> ambiguous framing.
///   - A non-numeric Content-Length                        -> malformed.
/// A request carrying neither header has a zero-length body.
pub fn parseBodyFraming(header_block: []const u8) FramingError!usize {
    var content_length: ?usize = null;
    var has_transfer_encoding = false;

    var lines = std.mem.splitScalar(u8, header_block, '\n');
    _ = lines.next(); // skip the request line (has no header colon semantics)
    while (lines.next()) |line0| {
        const line = std.mem.trimEnd(u8, line0, "\r");
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = line[0..colon];
        const val = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(key, "content-length")) {
            const n = std.fmt.parseInt(usize, val, 10) catch return error.MalformedContentLength;
            if (content_length) |prev| {
                if (prev != n) return error.ConflictingContentLength;
            } else {
                content_length = n;
            }
        } else if (std.ascii.eqlIgnoreCase(key, "transfer-encoding")) {
            has_transfer_encoding = true;
        }
    }

    if (has_transfer_encoding) {
        if (content_length != null) return error.ContentLengthAndTransferEncoding;
        return error.ChunkedUnsupported;
    }
    return content_length orelse 0;
}

/// Resolve the client IP to rate-limit on, given the direct TCP peer and request headers,
/// trusting `hops` reverse-proxy hops. The observed-address chain is
/// `[XFF entries…, direct_peer]`; the real client is the entry `hops` from the right (the
/// address the outermost trusted proxy saw). Spoof-resistant: a client can prepend fake
/// XFF entries on the LEFT, but trusted proxies append the true peer on the RIGHT, so
/// counting from the right skips exactly the trusted hops. The direct peer is the hop-th
/// proxy (not in XFF), so we skip `hops - 1` XFF entries. Falls back to the direct peer if
/// XFF is absent, too short, or unparseable.
pub fn resolveClientAddress(direct_peer: std.Io.net.IpAddress, header_data: []const u8, hops: u32) std.Io.net.IpAddress {
    const xff = findHeaderValue(header_data, "x-forwarded-for") orelse return direct_peer;
    var skip: u32 = if (hops > 0) hops - 1 else 0;
    var it = std.mem.splitBackwardsScalar(u8, xff, ',');
    while (it.next()) |raw| {
        const ip_str = std.mem.trim(u8, raw, " \t");
        if (ip_str.len == 0) continue;
        if (skip > 0) {
            skip -= 1;
            continue;
        }
        return std.Io.net.IpAddress.parse(ip_str, 0) catch direct_peer;
    }
    return direct_peer;
}

/// GraphQL-over-HTTP content negotiation. Returns true only when the client explicitly
/// Accepts `application/graphql-response+json` (the strict spec media type). Everything
/// else — `application/json`, `*/*`, `text/html`, or no Accept header — keeps the legacy
/// "always 200 + application/json, errors in body" contract that ensjs / subgraph clients
/// rely on. No change is gated on anything but this opt-in header.
pub fn acceptsResponseJson(request: []const u8) bool {
    const accept = findHeaderValue(request, "accept") orelse return false;
    return std.mem.indexOf(u8, accept, "application/graphql-response+json") != null;
}

pub fn graphqlContentType(strict: bool) []const u8 {
    return if (strict) "application/graphql-response+json" else "application/json";
}

/// In strict mode, map a GraphQL response body to a GraphQL-over-HTTP status code:
/// request / parse / validation failures -> 400; success and field-execution errors ->
/// 200. Keyed off the stable `extensions.code` the handler emits. Only consulted in
/// strict mode — the legacy path is always 200, so this never affects existing clients.
pub fn strictStatus(body: []const u8) u16 {
    const codes = [_][]const u8{
        "\"code\":\"SYNTAX_ERROR\"",
        "\"code\":\"VALIDATION_ERROR\"",
        "\"code\":\"COMPLEXITY_LIMIT_EXCEEDED\"",
        "\"code\":\"INVALID_ARGUMENT\"",
    };
    for (codes) |c| {
        if (std.mem.indexOf(u8, body, c) != null) return 400;
    }
    return 200;
}

/// GraphQL-over-HTTP: a response to a request error (parse / validation, served as 4xx)
/// MUST NOT carry a top-level `data` entry. The handler's error envelope always ends with
/// the fixed suffix `,"data":null}`; for strict 4xx responses we drop it, yielding
/// `{"errors":[...]}`. Returns a freshly-allocated body when stripped, otherwise a dupe of
/// the input (caller always frees). Only ever called in strict mode, so the legacy
/// application/json contract keeps `data:null` byte-for-byte.
pub fn stripNullData(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    const suffix = ",\"data\":null}";
    if (std.mem.endsWith(u8, body, suffix)) {
        const head = body[0 .. body.len - suffix.len];
        var out = try allocator.alloc(u8, head.len + 1);
        @memcpy(out[0..head.len], head);
        out[head.len] = '}';
        return out;
    }
    return try allocator.dupe(u8, body);
}

/// Find a raw (still percent-encoded) query-string parameter value by key.
pub fn getQueryParam(qs: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, qs, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

/// Decode an application/x-www-form-urlencoded component (`%XX` escapes, `+` for space).
/// Malformed escapes are passed through verbatim.
pub fn urlDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (c == '+') {
            try out.append(allocator, ' ');
        } else if (c == '%' and i + 2 < input.len) {
            const hi = std.fmt.charToDigit(input[i + 1], 16) catch {
                try out.append(allocator, c);
                continue;
            };
            const lo = std.fmt.charToDigit(input[i + 2], 16) catch {
                try out.append(allocator, c);
                continue;
            };
            try out.append(allocator, hi * 16 + lo);
            i += 2;
        } else {
            try out.append(allocator, c);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// True if any operation in the query is a mutation. Used to reject mutations over GET per
/// the GraphQL-over-HTTP spec (GET is for safe/idempotent queries only). A parse error
/// returns false so the normal handler reports the syntax error instead.
pub fn queryIsMutation(allocator: std.mem.Allocator, query: []const u8) bool {
    var doc = parser.parseQuery(allocator, query) catch return false;
    defer doc.deinit(allocator);
    for (doc.operations) |op| {
        if (op.type == .mutation) return true;
    }
    return false;
}

test "resolveClientAddress: X-Forwarded-For trusted-proxy resolution (spoof-resistant)" {
    const peer = try std.Io.net.IpAddress.parse("10.0.0.1", 0); // the proxy = direct peer
    const eq = struct {
        fn f(a: std.Io.net.IpAddress, ip: []const u8) bool {
            const b = std.Io.net.IpAddress.parse(ip, 0) catch return false;
            return a.eql(&b);
        }
    }.f;
    // Single trusted proxy: client is the rightmost XFF entry.
    try std.testing.expect(eq(resolveClientAddress(peer, "X-Forwarded-For: 1.2.3.4\r\nHost: x\r\n\r\n", 1), "1.2.3.4"));
    // Client prepends a fake entry; the trusted proxy appends the real peer on the RIGHT.
    try std.testing.expect(eq(resolveClientAddress(peer, "X-Forwarded-For: 9.9.9.9, 1.2.3.4\r\n\r\n", 1), "1.2.3.4"));
    // Two trusted hops: skip one proxy from the right, client is the next entry.
    try std.testing.expect(eq(resolveClientAddress(peer, "X-Forwarded-For: 1.2.3.4, 172.16.0.9\r\n\r\n", 2), "1.2.3.4"));
    // Header name is case-insensitive.
    try std.testing.expect(eq(resolveClientAddress(peer, "x-forwarded-for: 1.2.3.4\r\n\r\n", 1), "1.2.3.4"));
    // IPv6 client.
    try std.testing.expect(eq(resolveClientAddress(peer, "X-Forwarded-For: ::1\r\n\r\n", 1), "::1"));
    // No XFF / too many hops / unparseable → fall back to the direct peer (fail-closed to proxy).
    try std.testing.expect(eq(resolveClientAddress(peer, "Host: x\r\n\r\n", 1), "10.0.0.1"));
    try std.testing.expect(eq(resolveClientAddress(peer, "X-Forwarded-For: 1.2.3.4\r\n\r\n", 5), "10.0.0.1"));
    try std.testing.expect(eq(resolveClientAddress(peer, "X-Forwarded-For: not-an-ip\r\n\r\n", 1), "10.0.0.1"));
}

test "content negotiation: only application/graphql-response+json is strict" {
    // Legacy/default media types must NOT trigger strict mode (preserves client compat).
    try std.testing.expect(!acceptsResponseJson("Accept: application/json\r\n\r\n"));
    try std.testing.expect(!acceptsResponseJson("Accept: */*\r\n\r\n"));
    try std.testing.expect(!acceptsResponseJson("Accept: text/html\r\n\r\n"));
    try std.testing.expect(!acceptsResponseJson("Host: x\r\n\r\n")); // no Accept header
    // Only the strict spec media type opts in.
    try std.testing.expect(acceptsResponseJson("Accept: application/graphql-response+json\r\n\r\n"));
    try std.testing.expect(acceptsResponseJson("accept: application/graphql-response+json, application/json\r\n\r\n"));

    try std.testing.expectEqualStrings("application/json", graphqlContentType(false));
    try std.testing.expectEqualStrings("application/graphql-response+json", graphqlContentType(true));
}

test "strictStatus: 400 for request/parse/validation codes, 200 otherwise" {
    try std.testing.expectEqual(@as(u16, 200), strictStatus("{\"data\":{\"x\":1}}"));
    try std.testing.expectEqual(@as(u16, 400), strictStatus("{\"errors\":[{\"extensions\":{\"code\":\"SYNTAX_ERROR\"}}],\"data\":null}"));
    try std.testing.expectEqual(@as(u16, 400), strictStatus("{\"errors\":[{\"extensions\":{\"code\":\"VALIDATION_ERROR\"}}],\"data\":null}"));
    try std.testing.expectEqual(@as(u16, 400), strictStatus("{\"errors\":[{\"extensions\":{\"code\":\"COMPLEXITY_LIMIT_EXCEEDED\"}}],\"data\":null}"));
    try std.testing.expectEqual(@as(u16, 400), strictStatus("{\"errors\":[{\"extensions\":{\"code\":\"INVALID_ARGUMENT\"}}],\"data\":null}"));
    // A field/execution error (no request-level code) stays 200 under the spec.
    try std.testing.expectEqual(@as(u16, 200), strictStatus("{\"errors\":[{\"extensions\":{\"code\":\"INTERNAL_ERROR\"}}],\"data\":null}"));
}

test "parseBodyFraming: content-length parsed; absent = 0" {
    try std.testing.expectEqual(@as(usize, 5), try parseBodyFraming("POST / HTTP/1.1\r\nContent-Length: 5\r\nHost: x"));
    try std.testing.expectEqual(@as(usize, 0), try parseBodyFraming("GET / HTTP/1.1\r\nHost: x"));
    // bare-LF line endings
    try std.testing.expectEqual(@as(usize, 7), try parseBodyFraming("POST / HTTP/1.1\nContent-Length: 7"));
}

test "parseBodyFraming: rejects chunked and CL+TE (smuggling vectors)" {
    try std.testing.expectError(error.ChunkedUnsupported, parseBodyFraming("POST / HTTP/1.1\r\nTransfer-Encoding: chunked"));
    try std.testing.expectError(error.ContentLengthAndTransferEncoding, parseBodyFraming("POST / HTTP/1.1\r\nContent-Length: 5\r\nTransfer-Encoding: chunked"));
}

test "parseBodyFraming: rejects conflicting/malformed content-length; identical dup ok" {
    try std.testing.expectError(error.ConflictingContentLength, parseBodyFraming("POST / HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 6"));
    try std.testing.expectError(error.MalformedContentLength, parseBodyFraming("POST / HTTP/1.1\r\nContent-Length: abc"));
    try std.testing.expectEqual(@as(usize, 5), try parseBodyFraming("POST / HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 5"));
}
