//! Webhook management HTTP handlers (auth + CRUD API + management UI).
//!
//! Split out of server.zig as `pub fn f(self: *Server, ...)`; server.zig re-exports
//! them as `pub const f = webhook_handlers.f;`. They reach the response senders and
//! each other through `self` (resolved via the Server aliases).

const std = @import("std");
const zsys = @import("../utils/system.zig");
const models = @import("../types/models.zig");
const json_utils = @import("../utils/json.zig");
const url_utils = @import("../utils/url.zig");
const validation = @import("../utils/validation.zig");
const webhook_manager = @import("../webhooks/manager.zig");
const http_util = @import("http_util.zig");
const Server = @import("server.zig").Server;

// Typed accessors over an attacker-supplied std.json.Value. Reading a union field
// directly (e.g. `v.string`, `v.object`) panics — and crashes the process — when
// the client sends a different JSON type; these return null on mismatch so the
// handler can answer 400 instead.
fn jsonObject(v: std.json.Value) ?std.json.ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}
fn jsonStr(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |str| str,
        else => null,
    };
}
fn jsonBool(v: std.json.Value) ?bool {
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}
fn jsonInt(v: std.json.Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        else => null,
    };
}
fn jsonArray(v: std.json.Value) ?std.json.Array {
    return switch (v) {
        .array => |a| a,
        else => null,
    };
}

// Webhook/internal authentication now lives in api/auth.zig (constant-time,
// fail-closed) and is enforced at the routing seam in server.zig via
// `Server.webhookAuthOk`. The former `checkWebhookAuth` here compared credentials
// with short-circuiting std.mem.eql and failed open on missing config; both are
// fixed by the unified AdminAuth.

// ========================================================================
// WEBHOOK MANAGEMENT ENDPOINTS
// ========================================================================

pub fn handleWebhooksAPI(self: *Server, conn: http_util.Conn, method: []const u8, path: []const u8, request: []const u8) !void {
    // Parse path to determine webhook ID if present
    // /api/webhooks OR /api/webhooks/123
    const base_path = "/api/webhooks";
    const webhook_id_start = base_path.len;

    if (std.mem.eql(u8, method, "GET")) {
        if (path.len > webhook_id_start + 1) {
            // GET /api/webhooks/:id - Get single webhook
            var id_end = webhook_id_start + 1;
            while (id_end < path.len and path[id_end] != ' ' and path[id_end] != '?' and path[id_end] != '\r') {
                id_end += 1;
            }
            const id_str = path[webhook_id_start + 1 .. id_end];
            const webhook_id = std.fmt.parseInt(u64, id_str, 10) catch {
                return try self.sendBadRequest(conn, "Invalid webhook ID");
            };

            try self.handleGetWebhook(conn, webhook_id);
        } else {
            // GET /api/webhooks - List all webhooks
            try self.handleListWebhooks(conn);
        }
    } else if (std.mem.eql(u8, method, "POST")) {
        // POST /api/webhooks - Create new webhook
        try self.handleCreateWebhook(conn, request);
    } else if (std.mem.eql(u8, method, "PATCH")) {
        // PATCH /api/webhooks/:id - Update webhook
        if (path.len <= webhook_id_start + 1) {
            return try self.sendBadRequest(conn, "Webhook ID required");
        }

        var id_end = webhook_id_start + 1;
        while (id_end < path.len and path[id_end] != ' ' and path[id_end] != '?' and path[id_end] != '\r') {
            id_end += 1;
        }
        const id_str = path[webhook_id_start + 1 .. id_end];
        const webhook_id = std.fmt.parseInt(u64, id_str, 10) catch {
            return try self.sendBadRequest(conn, "Invalid webhook ID");
        };

        try self.handleUpdateWebhook(conn, webhook_id, request);
    } else if (std.mem.eql(u8, method, "DELETE")) {
        // DELETE /api/webhooks/:id - Delete webhook
        if (path.len <= webhook_id_start + 1) {
            return try self.sendBadRequest(conn, "Webhook ID required");
        }

        var id_end = webhook_id_start + 1;
        while (id_end < path.len and path[id_end] != ' ' and path[id_end] != '?' and path[id_end] != '\r') {
            id_end += 1;
        }
        const id_str = path[webhook_id_start + 1 .. id_end];
        const webhook_id = std.fmt.parseInt(u64, id_str, 10) catch {
            return try self.sendBadRequest(conn, "Invalid webhook ID");
        };

        try self.handleDeleteWebhook(conn, webhook_id);
    } else {
        try self.sendBadRequest(conn, "Method not allowed");
    }
}

pub fn handleListWebhooks(self: *Server, conn: http_util.Conn) !void {
    const webhook_db = self.webhook_database orelse {
        return try self.sendJsonResponse(conn, 503, "{\"error\":\"Webhooks not enabled\"}");
    };
    const webhooks = try webhook_db.getWebhooks();
    defer {
        for (webhooks) |*wh| {
            wh.deinit(self.allocator);
        }
        self.allocator.free(webhooks);
    }

    var response_buf: std.ArrayList(u8) = .empty;
    defer response_buf.deinit(self.allocator);

    try response_buf.appendSlice(self.allocator, "[");
    for (webhooks, 0..) |webhook, i| {
        if (i > 0) try response_buf.appendSlice(self.allocator, ",");

        // Serialize event_types
        var event_types_json: std.ArrayList(u8) = .empty;
        defer event_types_json.deinit(self.allocator);
        try event_types_json.appendSlice(self.allocator, "[");
        for (webhook.event_types, 0..) |et, j| {
            if (j > 0) try event_types_json.appendSlice(self.allocator, ",");
            const et_quoted = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{et.toString()});
            defer self.allocator.free(et_quoted);
            try event_types_json.appendSlice(self.allocator, et_quoted);
        }
        try event_types_json.appendSlice(self.allocator, "]");

        const webhook_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"id\":{d},\"url\":\"{s}\",\"event_types\":{s},\"active\":{},\"max_retries\":{d},\"created_at\":{d}}}",
            .{ webhook.id, webhook.url, event_types_json.items, webhook.active, webhook.max_retries, webhook.created_at },
        );
        defer self.allocator.free(webhook_json);
        try response_buf.appendSlice(self.allocator, webhook_json);
    }
    try response_buf.appendSlice(self.allocator, "]");

    try self.sendJsonResponse(conn, 200, response_buf.items);
}

pub fn handleGetWebhook(self: *Server, conn: http_util.Conn, webhook_id: u64) !void {
    const webhook_db = self.webhook_database orelse {
        return try self.sendJsonResponse(conn, 503, "{\"error\":\"Webhooks not enabled\"}");
    };
    const webhook_opt = try webhook_db.getWebhook(webhook_id);

    if (webhook_opt) |webhook| {
        var wh = webhook;
        defer wh.deinit(self.allocator);

        // Serialize event_types
        var event_types_json: std.ArrayList(u8) = .empty;
        defer event_types_json.deinit(self.allocator);
        try event_types_json.appendSlice(self.allocator, "[");
        for (wh.event_types, 0..) |et, i| {
            if (i > 0) try event_types_json.appendSlice(self.allocator, ",");
            const et_quoted = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{et.toString()});
            defer self.allocator.free(et_quoted);
            try event_types_json.appendSlice(self.allocator, et_quoted);
        }
        try event_types_json.appendSlice(self.allocator, "]");

        const webhook_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"id\":{d},\"url\":\"{s}\",\"event_types\":{s},\"active\":{},\"max_retries\":{d},\"created_at\":{d}}}",
            .{ wh.id, wh.url, event_types_json.items, wh.active, wh.max_retries, wh.created_at },
        );
        defer self.allocator.free(webhook_json);

        try self.sendJsonResponse(conn, 200, webhook_json);
    } else {
        try self.sendNotFound(conn);
    }
}

pub fn handleCreateWebhook(self: *Server, conn: http_util.Conn, request: []const u8) !void {
    if (self.webhook_database == null) {
        return try self.sendJsonResponse(conn, 503, "{\"error\":\"Webhooks not enabled\"}");
    }

    // Extract JSON body
    const body_start = std.mem.indexOf(u8, request, "\r\n\r\n") orelse std.mem.indexOf(u8, request, "\n\n") orelse {
        return try self.sendBadRequest(conn, "Invalid request format");
    };
    const body = request[body_start + 4 ..];

    // Parse JSON body
    const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch {
        return try self.sendBadRequest(conn, "Invalid JSON body");
    };
    defer parsed.deinit();

    const obj = jsonObject(parsed.value) orelse {
        return try self.sendBadRequest(conn, "Request body must be a JSON object");
    };

    // Extract fields
    const url_value = obj.get("url") orelse {
        return try self.sendBadRequest(conn, "url field required");
    };
    const url_str = jsonStr(url_value) orelse {
        return try self.sendBadRequest(conn, "url must be a string");
    };

    // SECURITY: Validate webhook URL (SSRF protection, protocol validation, etc.)
    url_utils.validateWebhookUrl(url_str) catch |err| {
        const err_msg = switch (err) {
            error.UrlEmpty => "URL cannot be empty",
            error.UrlTooLong => "URL exceeds maximum length",
            error.InvalidUrlProtocol => "Only HTTP and HTTPS protocols are allowed",
            error.InvalidUrlFormat => "Invalid URL format",
            error.PrivateIpNotAllowed => "Private IPs and localhost are not allowed",
            error.NullByteInUrl => "URL contains invalid null byte",
            error.ControlCharacterInUrl => "URL contains invalid control characters",
        };
        return try self.sendBadRequest(conn, err_msg);
    };

    // Parse event_types array
    var event_types: std.ArrayList(models.EventType) = .empty;
    defer event_types.deinit(self.allocator);

    if (obj.get("event_types")) |et_value| {
        const et_array = jsonArray(et_value) orelse {
            return try self.sendBadRequest(conn, "event_types must be an array");
        };
        for (et_array.items) |et_item| {
            const et_str = jsonStr(et_item) orelse continue;
            // Accept the spec name ("NameRegistered") from the API surface. stringToEnum
            // would match only the internal variant name ("name_registered") — wrong direction.
            if (models.EventType.fromString(et_str)) |et| {
                try event_types.append(self.allocator, et);
            }
        }
    }

    const active = if (obj.get("active")) |a|
        (jsonBool(a) orelse return try self.sendBadRequest(conn, "active must be a boolean"))
    else
        true;
    const max_retries: u32 = if (obj.get("max_retries")) |mr| blk: {
        const n = jsonInt(mr) orelse return try self.sendBadRequest(conn, "max_retries must be an integer");
        if (n < 0 or n > 1000) return try self.sendBadRequest(conn, "max_retries must be between 0 and 1000");
        break :blk @intCast(n);
    } else 3;

    // Use a caller-supplied secret when provided so several senders can share a
    // receiver's single WEBHOOK_SECRET; otherwise mint a fresh one. Either way the
    // value is hex (computeWebhookSignature hex-decodes it), so a provided secret
    // must be non-empty even-length hex to match the receiver's hex secret.
    const secret = if (obj.get("secret")) |s| blk: {
        const provided = switch (s) {
            .string => |str| str,
            else => return try self.sendBadRequest(conn, "secret must be a string"),
        };
        if (provided.len == 0 or provided.len > 256 or provided.len % 2 != 0) {
            return try self.sendBadRequest(conn, "secret must be non-empty even-length hex (max 256 chars)");
        }
        for (provided) |c| {
            const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
            if (!is_hex) return try self.sendBadRequest(conn, "secret must be hex (0-9, a-f)");
        }
        break :blk try self.allocator.dupe(u8, provided);
    } else try webhook_manager.generateWebhookSecret(self.allocator);
    defer self.allocator.free(secret);

    // Create webhook
    const webhook = models.Webhook{
        .id = 0, // Will be set by database
        .url = url_str,
        .secret = secret,
        .event_types = try event_types.toOwnedSlice(self.allocator),
        .active = active,
        .max_retries = max_retries,
        .created_at = zsys.timestamp(),
    };

    const webhook_id = try self.webhook_database.?.insertWebhook(webhook);

    const response = try std.fmt.allocPrint(
        self.allocator,
        "{{\"id\":{d},\"secret\":\"{s}\",\"message\":\"Webhook created. Store the secret — it is NOT retrievable later. Verify deliveries by computing HMAC-SHA256(secret, \\\"<X-Webhook-Timestamp>.<body>\\\") and comparing to X-Webhook-Signature.\"}}",
        .{ webhook_id, secret },
    );
    defer self.allocator.free(response);

    try self.sendJsonResponse(conn, 201, response);
}

pub fn handleUpdateWebhook(self: *Server, conn: http_util.Conn, webhook_id: u64, request: []const u8) !void {
    if (self.webhook_database == null) {
        return try self.sendJsonResponse(conn, 503, "{\"error\":\"Webhooks not enabled\"}");
    }

    // Extract JSON body
    const body_start = std.mem.indexOf(u8, request, "\r\n\r\n") orelse std.mem.indexOf(u8, request, "\n\n") orelse {
        return try self.sendBadRequest(conn, "Invalid request format");
    };
    const body = request[body_start + 4 ..];

    // Parse JSON body
    const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch {
        return try self.sendBadRequest(conn, "Invalid JSON body");
    };
    defer parsed.deinit();

    const obj = jsonObject(parsed.value) orelse {
        return try self.sendBadRequest(conn, "Request body must be a JSON object");
    };

    // Extract fields (all optional for PATCH)
    const url: ?[]const u8 = if (obj.get("url")) |u|
        (jsonStr(u) orelse return try self.sendBadRequest(conn, "url must be a string"))
    else
        null;

    // Parse event_types array if present
    var event_types: ?[]const models.EventType = null;
    var event_types_list: std.ArrayList(models.EventType) = .empty;
    defer {
        if (event_types == null) {
            event_types_list.deinit(self.allocator);
        }
    }

    if (obj.get("event_types")) |et_value| {
        const et_array = jsonArray(et_value) orelse {
            return try self.sendBadRequest(conn, "event_types must be an array");
        };
        for (et_array.items) |et_item| {
            const et_str = jsonStr(et_item) orelse continue;
            if (models.EventType.fromString(et_str)) |et| {
                try event_types_list.append(self.allocator, et);
            }
        }
        event_types = try event_types_list.toOwnedSlice(self.allocator);
    }

    const active: ?bool = if (obj.get("active")) |a|
        (jsonBool(a) orelse return try self.sendBadRequest(conn, "active must be a boolean"))
    else
        null;

    // Update webhook
    try self.webhook_database.?.updateWebhook(webhook_id, url, event_types, active);

    // Cleanup event_types if allocated
    if (event_types) |et| {
        self.allocator.free(et);
    }

    const response = try std.fmt.allocPrint(self.allocator, "{{\"id\":{d},\"message\":\"Webhook updated\"}}", .{webhook_id});
    defer self.allocator.free(response);

    try self.sendJsonResponse(conn, 200, response);
}

pub fn handleDeleteWebhook(self: *Server, conn: http_util.Conn, webhook_id: u64) !void {
    if (self.webhook_database == null) {
        return try self.sendJsonResponse(conn, 503, "{\"error\":\"Webhooks not enabled\"}");
    }
    try self.webhook_database.?.deleteWebhook(webhook_id);

    const response = try std.fmt.allocPrint(self.allocator, "{{\"id\":{d},\"message\":\"Webhook deleted\"}}", .{webhook_id});
    defer self.allocator.free(response);

    try self.sendJsonResponse(conn, 200, response);
}

pub fn handleWebhookUI(self: *Server, conn: http_util.Conn) !void {
    const html = @embedFile("webhook_ui.html");

    var response: std.Io.Writer.Allocating = .init(self.allocator);
    defer response.deinit();

    const writer = &response.writer;
    try writer.print(
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/html; charset=utf-8\r\n" ++
            "Cache-Control: no-store\r\n" ++
            "Content-Length: {d}\r\n" ++
            "\r\n" ++
            "{s}",
        .{ html.len, html },
    );

    try conn.writeAll(response.written());
}
