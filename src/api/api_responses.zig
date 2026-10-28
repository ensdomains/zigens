//! HTTP response writers for the API server.
//!
//! The wire-format senders (JSON, GraphQL, errors, CORS, auth) shared across every
//! handler cluster. Split out of server.zig as `pub fn f(self: *Server, ...)`;
//! server.zig re-exports them as `pub const f = api_responses.f;`, so `self.f(...)`
//! call sites are unchanged.

const std = @import("std");
const http_util = @import("http_util.zig");
const graphqlContentType = http_util.graphqlContentType;
const Server = @import("server.zig").Server;

/// The reason phrase for a status we actually emit. It used to be
/// `if (status == 200) "OK" else "Error"`, which put the literal line
/// `HTTP/1.1 202 Error` on the wire for an accepted MCP notification and
/// `405 Error` for a method-not-allowed — well-formed enough for most clients to
/// parse, but it reads as a failure in every log and proxy trace.
fn reasonPhrase(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        else => "Error",
    };
}

pub fn sendJsonResponse(self: *Server, conn: http_util.Conn, status: u16, body: []const u8) !void {
    const status_text = reasonPhrase(status);

    var response: std.Io.Writer.Allocating = .init(self.allocator);
    defer response.deinit();

    const writer = &response.writer;
    try writer.print(
        "HTTP/1.1 {d} {s}\r\n" ++
            "Connection: close\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "\r\n" ++
            "{s}",
        .{ status, status_text, body.len, body },
    );

    try conn.writeAll(response.written());
}

pub fn sendNotFound(self: *Server, conn: http_util.Conn) !void {
    const response =
        \\{"error":"Not found"}
    ;
    try self.sendJsonResponse(conn, 404, response);
}

pub fn sendBadRequest(self: *Server, conn: http_util.Conn, message: []const u8) !void {
    const response = try std.fmt.allocPrint(self.allocator, "{{\"error\":\"{s}\"}}", .{message});
    defer self.allocator.free(response);

    try self.sendJsonResponse(conn, 400, response);
}

/// Write a GraphQL response with a content-negotiated Content-Type. Same wire format
/// as `sendJsonResponse` but the media type and status are caller-chosen (see the
/// content-negotiation logic in `handleGraphQLQuery`).
pub fn sendGraphQLResponse(self: *Server, conn: http_util.Conn, status: u16, body: []const u8, content_type: []const u8) !void {
    const status_text = switch (status) {
        200 => "OK",
        400 => "Bad Request",
        else => "Error",
    };

    var response: std.Io.Writer.Allocating = .init(self.allocator);
    defer response.deinit();

    const writer = &response.writer;
    try writer.print(
        "HTTP/1.1 {d} {s}\r\n" ++
            "Connection: close\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "\r\n" ++
            "{s}",
        .{ status, status_text, content_type, body.len, body },
    );

    try conn.writeAll(response.written());
}

/// Request-level error (malformed body / params). Legacy clients keep the existing
/// `{"error":...}` + application/json + 400 response (unchanged). Strict clients get
/// the GraphQL `{"errors":[...]}` envelope + application/graphql-response+json + 400.
/// `message` is a static, JSON-safe string (no escaping needed).
pub fn sendRequestError(self: *Server, conn: http_util.Conn, message: []const u8, strict: bool) !void {
    if (!strict) return self.sendBadRequest(conn, message);
    const body = try std.fmt.allocPrint(self.allocator, "{{\"errors\":[{{\"message\":\"{s}\"}}]}}", .{message});
    defer self.allocator.free(body);
    try self.sendGraphQLResponse(conn, 400, body, graphqlContentType(true));
}

pub fn sendRateLimited(self: *Server, conn: http_util.Conn) !void {
    const response =
        \\{"error":"Too many requests. Please try again later."}
    ;
    try self.sendJsonResponse(conn, 429, response);
}

pub fn sendServiceUnavailable(self: *Server, conn: http_util.Conn) !void {
    const response =
        \\{"error":"Server at capacity. Please retry shortly."}
    ;
    try self.sendJsonResponse(conn, 503, response);
}

/// 403 with a caller-supplied body, for a request that is well formed but whose
/// origin is not on the allow-list.
pub fn sendForbidden(self: *Server, conn: http_util.Conn, body: []const u8) !void {
    try self.sendJsonResponse(conn, 403, body);
}

/// 405 with an `Allow` header. Streamable HTTP is explicit that a server which
/// offers no SSE stream at its endpoint MUST answer GET with 405 — clients read
/// that as the positive signal "no stream here, stay in JSON mode", whereas a
/// 400 reads as a transport failure and can abort an otherwise fine session.
pub fn sendMethodNotAllowed(self: *Server, conn: http_util.Conn, allow: []const u8, body: []const u8) !void {
    var response: std.Io.Writer.Allocating = .init(self.allocator);
    defer response.deinit();
    const writer = &response.writer;
    try writer.print(
        "HTTP/1.1 405 Method Not Allowed\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Allow: {s}\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "Connection: close\r\n" ++
            "\r\n{s}",
        .{ body.len, allow, body },
    );
    try conn.writeAll(response.written());
}

pub fn sendCorsPreflightResponse(_: *Server, conn: http_util.Conn) !void {
    const response =
        "HTTP/1.1 204 No Content\r\n" ++
        "Connection: close\r\n" ++
        "Access-Control-Allow-Origin: *\r\n" ++
        "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" ++
        // MCP Streamable HTTP requires MCP-Protocol-Version on every request after
        // initialize, and browser clients send Mcp-Session-Id. Both are
        // non-simple headers, so omitting them made the browser block the POST
        // before it ever reached us — silently ruling out the one client class
        // that needs CORS at all.
        "Access-Control-Allow-Headers: Content-Type, Authorization, MCP-Protocol-Version, Mcp-Session-Id\r\n" ++
        "Access-Control-Expose-Headers: Mcp-Session-Id\r\n" ++
        "Access-Control-Max-Age: 86400\r\n" ++
        "\r\n";

    try conn.writeAll(response);
}

pub fn sendUnauthorized(_: *Server, conn: http_util.Conn) !void {
    const body = "{\"error\":\"Authentication required\"}";
    const header = "HTTP/1.1 401 Unauthorized\r\n" ++
        "Connection: close\r\n" ++
        "Content-Type: application/json\r\n" ++
        "WWW-Authenticate: Basic realm=\"Webhook Admin\"\r\n" ++
        "Access-Control-Allow-Origin: *\r\n" ++
        "Content-Length: " ++ std.fmt.comptimePrint("{d}", .{body.len}) ++ "\r\n" ++
        "\r\n";

    try conn.writeAll(header);
    try conn.writeAll(body);
}

test "reasonPhrase covers every status this server actually sends" {
    // The helper exists because `if (status == 200) "OK" else "Error"` put
    // "HTTP/1.1 202 Error" on the wire. Shipping it with 201 still missing left
    // "HTTP/1.1 201 Created" — the webhook-creation response — reading "201 Error".
    const sent = [_]u16{ 200, 201, 202, 204, 400, 401, 403, 404, 405, 429, 500, 503 };
    for (sent) |status| {
        const phrase = reasonPhrase(status);
        if (std.mem.eql(u8, phrase, "Error")) {
            std.debug.print("status {d} falls through to the generic phrase\n", .{status});
            return error.MissingReasonPhrase;
        }
    }
    // Anything genuinely unmapped still degrades rather than failing.
    try std.testing.expectEqualStrings("Error", reasonPhrase(599));
}
