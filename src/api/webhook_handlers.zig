//! Webhook management HTTP handlers (auth + CRUD API + management UI).
//!
//! Split out of server.zig as `pub fn f(self: *Server, ...)`; server.zig re-exports
//! them as `pub const f = webhook_handlers.f;`. They reach the response senders and
//! each other through `self` (resolved via the Server aliases).

const std = @import("std");
const models = @import("../types/models.zig");
const json_utils = @import("../utils/json.zig");
const url_utils = @import("../utils/url.zig");
const validation = @import("../utils/validation.zig");
const webhook_manager = @import("../webhooks/manager.zig");
const Server = @import("server.zig").Server;

/// Check Basic Auth credentials from request headers
/// Returns true if auth is valid or not required, false if auth failed
pub fn checkWebhookAuth(self: *Server, request: []const u8) bool {
    // If no password is set, allow all requests (auth disabled)
    const required_password = self.webhook_admin_password orelse return true;
    const required_username = self.webhook_admin_username orelse return true;

    // Find Authorization header
    var lines = std.mem.splitSequence(u8, request, "\r\n");
    while (lines.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "authorization:")) {
            const header_value = std.mem.trim(u8, line["authorization:".len..], " ");

            // Check for Basic auth
            if (std.ascii.startsWithIgnoreCase(header_value, "basic ")) {
                const encoded = std.mem.trim(u8, header_value["basic ".len..], " ");

                // Decode base64
                const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return false;
                if (decoded_len > 256) return false;

                var decoded_buf: [256]u8 = undefined;
                std.base64.standard.Decoder.decode(&decoded_buf, encoded) catch return false;
                const decoded = decoded_buf[0..decoded_len];

                // Format is "username:password"
                if (std.mem.indexOf(u8, decoded, ":")) |colon_pos| {
                    const username = decoded[0..colon_pos];
                    const password = decoded[colon_pos + 1 ..];
                    return std.mem.eql(u8, username, required_username) and std.mem.eql(u8, password, required_password);
                }
            }
            return false;
        }
    }
    return false;
}

// ========================================================================
// WEBHOOK MANAGEMENT ENDPOINTS
// ========================================================================

pub fn handleWebhooksAPI(self: *Server, stream: std.net.Stream, method: []const u8, path: []const u8, request: []const u8) !void {
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
                return try self.sendBadRequest(stream, "Invalid webhook ID");
            };

            try self.handleGetWebhook(stream, webhook_id);
        } else {
            // GET /api/webhooks - List all webhooks
            try self.handleListWebhooks(stream);
        }
    } else if (std.mem.eql(u8, method, "POST")) {
        // POST /api/webhooks - Create new webhook
        try self.handleCreateWebhook(stream, request);
    } else if (std.mem.eql(u8, method, "PATCH")) {
        // PATCH /api/webhooks/:id - Update webhook
        if (path.len <= webhook_id_start + 1) {
            return try self.sendBadRequest(stream, "Webhook ID required");
        }

        var id_end = webhook_id_start + 1;
        while (id_end < path.len and path[id_end] != ' ' and path[id_end] != '?' and path[id_end] != '\r') {
            id_end += 1;
        }
        const id_str = path[webhook_id_start + 1 .. id_end];
        const webhook_id = std.fmt.parseInt(u64, id_str, 10) catch {
            return try self.sendBadRequest(stream, "Invalid webhook ID");
        };

        try self.handleUpdateWebhook(stream, webhook_id, request);
    } else if (std.mem.eql(u8, method, "DELETE")) {
        // DELETE /api/webhooks/:id - Delete webhook
        if (path.len <= webhook_id_start + 1) {
            return try self.sendBadRequest(stream, "Webhook ID required");
        }

        var id_end = webhook_id_start + 1;
        while (id_end < path.len and path[id_end] != ' ' and path[id_end] != '?' and path[id_end] != '\r') {
            id_end += 1;
        }
        const id_str = path[webhook_id_start + 1 .. id_end];
        const webhook_id = std.fmt.parseInt(u64, id_str, 10) catch {
            return try self.sendBadRequest(stream, "Invalid webhook ID");
        };

        try self.handleDeleteWebhook(stream, webhook_id);
    } else {
        try self.sendBadRequest(stream, "Method not allowed");
    }
}

pub fn handleListWebhooks(self: *Server, stream: std.net.Stream) !void {
    const webhook_db = self.webhook_database orelse {
        return try self.sendJsonResponse(stream, 503, "{\"error\":\"Webhooks not enabled\"}");
    };
    const webhooks = try webhook_db.getWebhooks();
    defer {
        for (webhooks) |*wh| {
            wh.deinit(self.allocator);
        }
        self.allocator.free(webhooks);
    }

    var response_buf: std.ArrayList(u8) = .{};
    defer response_buf.deinit(self.allocator);

    try response_buf.appendSlice(self.allocator, "[");
    for (webhooks, 0..) |webhook, i| {
        if (i > 0) try response_buf.appendSlice(self.allocator, ",");

        // Serialize event_types
        var event_types_json: std.ArrayList(u8) = .{};
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

    try self.sendJsonResponse(stream, 200, response_buf.items);
}

pub fn handleGetWebhook(self: *Server, stream: std.net.Stream, webhook_id: u64) !void {
    const webhook_db = self.webhook_database orelse {
        return try self.sendJsonResponse(stream, 503, "{\"error\":\"Webhooks not enabled\"}");
    };
    const webhook_opt = try webhook_db.getWebhook(webhook_id);

    if (webhook_opt) |webhook| {
        var wh = webhook;
        defer wh.deinit(self.allocator);

        // Serialize event_types
        var event_types_json: std.ArrayList(u8) = .{};
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

        try self.sendJsonResponse(stream, 200, webhook_json);
    } else {
        try self.sendNotFound(stream);
    }
}

pub fn handleCreateWebhook(self: *Server, stream: std.net.Stream, request: []const u8) !void {
    if (self.webhook_database == null) {
        return try self.sendJsonResponse(stream, 503, "{\"error\":\"Webhooks not enabled\"}");
    }

    // Extract JSON body
    const body_start = std.mem.indexOf(u8, request, "\r\n\r\n") orelse std.mem.indexOf(u8, request, "\n\n") orelse {
        return try self.sendBadRequest(stream, "Invalid request format");
    };
    const body = request[body_start + 4 ..];

    // Parse JSON body
    const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch {
        return try self.sendBadRequest(stream, "Invalid JSON body");
    };
    defer parsed.deinit();

    const obj = parsed.value.object;

    // Extract fields
    const url = obj.get("url") orelse {
        return try self.sendBadRequest(stream, "url field required");
    };

    // SECURITY: Validate webhook URL (SSRF protection, protocol validation, etc.)
    url_utils.validateWebhookUrl(url.string) catch |err| {
        const err_msg = switch (err) {
            error.UrlEmpty => "URL cannot be empty",
            error.UrlTooLong => "URL exceeds maximum length",
            error.InvalidUrlProtocol => "Only HTTP and HTTPS protocols are allowed",
            error.InvalidUrlFormat => "Invalid URL format",
            error.PrivateIpNotAllowed => "Private IPs and localhost are not allowed",
            error.NullByteInUrl => "URL contains invalid null byte",
            error.ControlCharacterInUrl => "URL contains invalid control characters",
        };
        return try self.sendBadRequest(stream, err_msg);
    };

    // Parse event_types array
    var event_types: std.ArrayList(models.EventType) = .{};
    defer event_types.deinit(self.allocator);

    if (obj.get("event_types")) |et_value| {
        const et_array = et_value.array;
        for (et_array.items) |et_item| {
            const et_str = et_item.string;
            // Accept the spec name ("NameRegistered") from the API surface. stringToEnum
            // would match only the internal variant name ("name_registered") — wrong direction.
            if (models.EventType.fromString(et_str)) |et| {
                try event_types.append(self.allocator, et);
            }
        }
    }

    const active = if (obj.get("active")) |a| a.bool else true;
    const max_retries = if (obj.get("max_retries")) |mr| @as(u32, @intCast(mr.integer)) else 3;

    // Use a caller-supplied secret when provided so several senders can share a
    // receiver's single WEBHOOK_SECRET; otherwise mint a fresh one. Either way the
    // value is hex (computeWebhookSignature hex-decodes it), so a provided secret
    // must be non-empty even-length hex to match the receiver's hex secret.
    const secret = if (obj.get("secret")) |s| blk: {
        const provided = switch (s) {
            .string => |str| str,
            else => return try self.sendBadRequest(stream, "secret must be a string"),
        };
        if (provided.len == 0 or provided.len > 256 or provided.len % 2 != 0) {
            return try self.sendBadRequest(stream, "secret must be non-empty even-length hex (max 256 chars)");
        }
        for (provided) |c| {
            const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
            if (!is_hex) return try self.sendBadRequest(stream, "secret must be hex (0-9, a-f)");
        }
        break :blk try self.allocator.dupe(u8, provided);
    } else try webhook_manager.generateWebhookSecret(self.allocator);
    defer self.allocator.free(secret);

    // Create webhook
    const webhook = models.Webhook{
        .id = 0, // Will be set by database
        .url = url.string,
        .secret = secret,
        .event_types = try event_types.toOwnedSlice(self.allocator),
        .active = active,
        .max_retries = max_retries,
        .created_at = std.time.timestamp(),
    };

    const webhook_id = try self.webhook_database.?.insertWebhook(webhook);

    const response = try std.fmt.allocPrint(
        self.allocator,
        "{{\"id\":{d},\"secret\":\"{s}\",\"message\":\"Webhook created. Store the secret — it is NOT retrievable later. Verify deliveries by computing HMAC-SHA256(secret, \\\"<X-Webhook-Timestamp>.<body>\\\") and comparing to X-Webhook-Signature.\"}}",
        .{ webhook_id, secret },
    );
    defer self.allocator.free(response);

    try self.sendJsonResponse(stream, 201, response);
}

pub fn handleUpdateWebhook(self: *Server, stream: std.net.Stream, webhook_id: u64, request: []const u8) !void {
    if (self.webhook_database == null) {
        return try self.sendJsonResponse(stream, 503, "{\"error\":\"Webhooks not enabled\"}");
    }

    // Extract JSON body
    const body_start = std.mem.indexOf(u8, request, "\r\n\r\n") orelse std.mem.indexOf(u8, request, "\n\n") orelse {
        return try self.sendBadRequest(stream, "Invalid request format");
    };
    const body = request[body_start + 4 ..];

    // Parse JSON body
    const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch {
        return try self.sendBadRequest(stream, "Invalid JSON body");
    };
    defer parsed.deinit();

    const obj = parsed.value.object;

    // Extract fields (all optional for PATCH)
    const url: ?[]const u8 = if (obj.get("url")) |u| u.string else null;

    // Parse event_types array if present
    var event_types: ?[]const models.EventType = null;
    var event_types_list: std.ArrayList(models.EventType) = .{};
    defer {
        if (event_types == null) {
            event_types_list.deinit(self.allocator);
        }
    }

    if (obj.get("event_types")) |et_value| {
        const et_array = et_value.array;
        for (et_array.items) |et_item| {
            const et_str = et_item.string;
            if (models.EventType.fromString(et_str)) |et| {
                try event_types_list.append(self.allocator, et);
            }
        }
        event_types = try event_types_list.toOwnedSlice(self.allocator);
    }

    const active: ?bool = if (obj.get("active")) |a| a.bool else null;

    // Update webhook
    try self.webhook_database.?.updateWebhook(webhook_id, url, event_types, active);

    // Cleanup event_types if allocated
    if (event_types) |et| {
        self.allocator.free(et);
    }

    const response = try std.fmt.allocPrint(self.allocator, "{{\"id\":{d},\"message\":\"Webhook updated\"}}", .{webhook_id});
    defer self.allocator.free(response);

    try self.sendJsonResponse(stream, 200, response);
}

pub fn handleDeleteWebhook(self: *Server, stream: std.net.Stream, webhook_id: u64) !void {
    if (self.webhook_database == null) {
        return try self.sendJsonResponse(stream, 503, "{\"error\":\"Webhooks not enabled\"}");
    }
    try self.webhook_database.?.deleteWebhook(webhook_id);

    const response = try std.fmt.allocPrint(self.allocator, "{{\"id\":{d},\"message\":\"Webhook deleted\"}}", .{webhook_id});
    defer self.allocator.free(response);

    try self.sendJsonResponse(stream, 200, response);
}

pub fn handleWebhookUI(self: *Server, stream: std.net.Stream) !void {
    const html = @embedFile("webhook_ui.html");

    var response: std.ArrayList(u8) = .{};
    defer response.deinit(self.allocator);

    const writer = response.writer(self.allocator);
    try writer.print(
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/html; charset=utf-8\r\n" ++
            "Cache-Control: no-store\r\n" ++
            "Content-Length: {d}\r\n" ++
            "\r\n" ++
            "{s}",
        .{ html.len, html },
    );

    _ = try stream.write(response.items);
}
