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

pub fn sendJsonResponse(self: *Server, stream: std.net.Stream, status: u16, body: []const u8) !void {
    const status_text = if (status == 200) "OK" else "Error";

    var response: std.ArrayList(u8) = .{};
    defer response.deinit(self.allocator);

    const writer = response.writer(self.allocator);
    try writer.print(
        "HTTP/1.1 {d} {s}\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "\r\n" ++
            "{s}",
        .{ status, status_text, body.len, body },
    );

    _ = try stream.write(response.items);
}

pub fn sendNotFound(self: *Server, stream: std.net.Stream) !void {
    const response =
        \\{"error":"Not found"}
    ;
    try self.sendJsonResponse(stream, 404, response);
}

pub fn sendBadRequest(self: *Server, stream: std.net.Stream, message: []const u8) !void {
    const response = try std.fmt.allocPrint(self.allocator, "{{\"error\":\"{s}\"}}", .{message});
    defer self.allocator.free(response);

    try self.sendJsonResponse(stream, 400, response);
}

/// Write a GraphQL response with a content-negotiated Content-Type. Same wire format
/// as `sendJsonResponse` but the media type and status are caller-chosen (see the
/// content-negotiation logic in `handleGraphQLQuery`).
pub fn sendGraphQLResponse(self: *Server, stream: std.net.Stream, status: u16, body: []const u8, content_type: []const u8) !void {
    const status_text = switch (status) {
        200 => "OK",
        400 => "Bad Request",
        else => "Error",
    };

    var response: std.ArrayList(u8) = .{};
    defer response.deinit(self.allocator);

    const writer = response.writer(self.allocator);
    try writer.print(
        "HTTP/1.1 {d} {s}\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "\r\n" ++
            "{s}",
        .{ status, status_text, content_type, body.len, body },
    );

    _ = try stream.write(response.items);
}

/// Request-level error (malformed body / params). Legacy clients keep the existing
/// `{"error":...}` + application/json + 400 response (unchanged). Strict clients get
/// the GraphQL `{"errors":[...]}` envelope + application/graphql-response+json + 400.
/// `message` is a static, JSON-safe string (no escaping needed).
pub fn sendRequestError(self: *Server, stream: std.net.Stream, message: []const u8, strict: bool) !void {
    if (!strict) return self.sendBadRequest(stream, message);
    const body = try std.fmt.allocPrint(self.allocator, "{{\"errors\":[{{\"message\":\"{s}\"}}]}}", .{message});
    defer self.allocator.free(body);
    try self.sendGraphQLResponse(stream, 400, body, graphqlContentType(true));
}

pub fn sendRateLimited(self: *Server, stream: std.net.Stream) !void {
    const response =
        \\{"error":"Too many requests. Please try again later."}
    ;
    try self.sendJsonResponse(stream, 429, response);
}

pub fn sendCorsPreflightResponse(_: *Server, stream: std.net.Stream) !void {
    const response =
        "HTTP/1.1 204 No Content\r\n" ++
        "Access-Control-Allow-Origin: *\r\n" ++
        "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" ++
        "Access-Control-Allow-Headers: Content-Type, Authorization\r\n" ++
        "Access-Control-Max-Age: 86400\r\n" ++
        "\r\n";

    _ = try stream.write(response);
}

pub fn sendUnauthorized(_: *Server, stream: std.net.Stream) !void {
    const body = "{\"error\":\"Authentication required\"}";
    const header = "HTTP/1.1 401 Unauthorized\r\n" ++
        "Content-Type: application/json\r\n" ++
        "WWW-Authenticate: Basic realm=\"Webhook Admin\"\r\n" ++
        "Access-Control-Allow-Origin: *\r\n" ++
        "Content-Length: " ++ std.fmt.comptimePrint("{d}", .{body.len}) ++ "\r\n" ++
        "\r\n";

    _ = try stream.write(header);
    _ = try stream.write(body);
}
