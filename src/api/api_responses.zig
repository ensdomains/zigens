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

pub fn sendJsonResponse(self: *Server, conn: http_util.Conn, status: u16, body: []const u8) !void {
    const status_text = if (status == 200) "OK" else "Error";

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

/// GraphQL is closed until the indexer finishes its initial sync (Server.syncReady).
/// 503 + Retry-After marks it as a temporary condition, so clients and load
/// balancers retry rather than treating the endpoint as broken.
pub fn sendSyncInProgress(_: *Server, conn: http_util.Conn) !void {
    const body = "{\"errors\":[{\"message\":\"Indexer initial sync in progress; GraphQL is unavailable until it completes\",\"extensions\":{\"code\":\"SYNC_IN_PROGRESS\"}}]}";
    const header = "HTTP/1.1 503 Service Unavailable\r\n" ++
        "Connection: close\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Retry-After: 60\r\n" ++
        "Access-Control-Allow-Origin: *\r\n" ++
        "Content-Length: " ++ std.fmt.comptimePrint("{d}", .{body.len}) ++ "\r\n" ++
        "\r\n";

    try conn.writeAll(header ++ body);
}

pub fn sendCorsPreflightResponse(_: *Server, conn: http_util.Conn) !void {
    const response =
        "HTTP/1.1 204 No Content\r\n" ++
        "Connection: close\r\n" ++
        "Access-Control-Allow-Origin: *\r\n" ++
        "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" ++
        "Access-Control-Allow-Headers: Content-Type, Authorization\r\n" ++
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
