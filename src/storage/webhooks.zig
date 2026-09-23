const std = @import("std");
const db_module = @import("database.zig");
const Database = db_module.Database;
const Query = db_module.Query;
const models = @import("../types/models.zig");

// ============================================================================
// WEBHOOK OPERATIONS
// ============================================================================

/// Serialize event types as a JSON array string. Caller owns the result.
fn serializeEventTypes(allocator: std.mem.Allocator, event_types: []const models.EventType) ![]u8 {
    var json: std.ArrayList(u8) = .empty;
    errdefer json.deinit(allocator);
    try json.append(allocator, '[');
    for (event_types, 0..) |et, i| {
        if (i > 0) try json.append(allocator, ',');
        try json.append(allocator, '"');
        try json.appendSlice(allocator, et.toString());
        try json.append(allocator, '"');
    }
    try json.append(allocator, ']');
    return json.toOwnedSlice(allocator);
}

/// Parse a JSON array of event-type strings (simple quoted-string scan). Caller owns the result.
fn parseEventTypes(allocator: std.mem.Allocator, json: []const u8) ![]models.EventType {
    var event_types: std.ArrayList(models.EventType) = .empty;
    errdefer event_types.deinit(allocator);
    var i: usize = 0;
    while (i < json.len) : (i += 1) {
        if (json[i] == '"') {
            const start = i + 1;
            i += 1;
            while (i < json.len and json[i] != '"') : (i += 1) {}
            if (models.EventType.fromString(json[start..i])) |et| {
                try event_types.append(allocator, et);
            }
        }
    }
    return event_types.toOwnedSlice(allocator);
}

/// Read a webhook row (cols: id, url, secret, event_types, active, max_retries, created_at).
/// Borrowed column slices are consumed before the next step; result is owned by `allocator`.
fn readWebhookRow(allocator: std.mem.Allocator, q: *Query) !models.Webhook {
    const url = try allocator.dupe(u8, q.getTextSlice(1) orelse "");
    errdefer allocator.free(url);
    const secret = try allocator.dupe(u8, q.getTextSlice(2) orelse "");
    errdefer allocator.free(secret);
    const event_types = try parseEventTypes(allocator, q.getTextSlice(3) orelse "");
    errdefer allocator.free(event_types);
    return models.Webhook{
        .id = @intCast(q.getInt64(0)),
        .url = url,
        .secret = secret,
        .event_types = event_types,
        .active = q.getBool(4),
        .max_retries = @intCast(q.getInt(5)),
        .created_at = q.getInt64(6),
    };
}

/// Insert a webhook. The `webhook.secret` MUST be a non-empty hex-encoded HMAC key
/// (callers should auto-generate via webhooks/manager.zig:generateWebhookSecret).
pub fn insertWebhook(db: *Database, webhook: models.Webhook) !u64 {
    if (webhook.secret.len == 0) return error.WebhookSecretRequired;

    const event_types_json = try serializeEventTypes(db.allocator, webhook.event_types);
    defer db.allocator.free(event_types_json);

    // Postgres has no last_insert_rowid; use INSERT … RETURNING id (read via step()).
    // SQLite keeps its proven exec() + lastInsertId() path unchanged.
    const ret_clause: []const u8 = if (db.isPostgres()) " RETURNING id" else "";
    const sql = try std.fmt.allocPrint(db.allocator,
        \\INSERT INTO webhooks
        \\(url, secret, event_types, active, max_retries, created_at)
        \\VALUES (?, ?, ?, ?, ?, ?){s}
    , .{ret_clause});
    defer db.allocator.free(sql);

    var q = try Query.init(db, sql);
    defer q.deinit();

    try q.bindText(webhook.url);
    try q.bindText(webhook.secret);
    try q.bindText(event_types_json);
    try q.bindInt(if (webhook.active) 1 else 0);
    try q.bindInt(@intCast(webhook.max_retries));
    try q.bindInt64(webhook.created_at);

    if (db.isPostgres()) {
        if (!try q.step()) return error.WebhookInsertFailed;
        return @intCast(q.getInt64(0)); // RETURNING id
    }
    try q.exec();
    return @intCast(db.lastInsertId());
}

/// Delete a webhook by ID
pub fn deleteWebhook(db: *Database, webhook_id: u64) !void {
    var q = try Query.init(db, "DELETE FROM webhooks WHERE id = ?");
    defer q.deinit();
    try q.bindInt64(@intCast(webhook_id));
    try q.exec();
}

/// Get all webhooks
pub fn getWebhooks(db: *Database) ![]models.Webhook {
    var q = try Query.init(db, "SELECT id, url, secret, event_types, active, max_retries, created_at FROM webhooks");
    defer q.deinit();

    var webhooks: std.ArrayList(models.Webhook) = .empty;
    errdefer {
        for (webhooks.items) |*wh| wh.deinit(db.allocator);
        webhooks.deinit(db.allocator);
    }

    while (try q.step()) {
        var webhook = try readWebhookRow(db.allocator, &q);
        errdefer webhook.deinit(db.allocator);
        try webhooks.append(db.allocator, webhook);
    }

    return webhooks.toOwnedSlice(db.allocator);
}

/// Get a webhook by ID
pub fn getWebhook(db: *Database, webhook_id: u64) !?models.Webhook {
    var q = try Query.init(db, "SELECT id, url, secret, event_types, active, max_retries, created_at FROM webhooks WHERE id = ?");
    defer q.deinit();

    try q.bindInt64(@intCast(webhook_id));

    if (try q.step()) {
        return try readWebhookRow(db.allocator, &q);
    }
    return null;
}

/// Update a webhook
pub fn updateWebhook(db: *Database, webhook_id: u64, url: ?[]const u8, event_types: ?[]const models.EventType, active: ?bool) !void {
    // Get the old URL before updating, if URL is being changed
    var old_url: ?[]const u8 = null;
    if (url != null) {
        if (try getWebhook(db, webhook_id)) |wh| {
            var w = wh;
            old_url = try db.allocator.dupe(u8, w.url);
            w.deinit(db.allocator);
        }
    }
    defer if (old_url) |ou| db.allocator.free(ou);

    // Build dynamic SQL based on what fields are provided.
    var sql_parts: std.ArrayList(u8) = .empty;
    defer sql_parts.deinit(db.allocator);
    try sql_parts.appendSlice(db.allocator, "UPDATE webhooks SET ");

    var field_count: u8 = 0;
    if (url != null) {
        try sql_parts.appendSlice(db.allocator, "url = ?");
        field_count += 1;
    }
    if (event_types != null) {
        if (field_count > 0) try sql_parts.appendSlice(db.allocator, ", ");
        try sql_parts.appendSlice(db.allocator, "event_types = ?");
        field_count += 1;
    }
    if (active != null) {
        if (field_count > 0) try sql_parts.appendSlice(db.allocator, ", ");
        try sql_parts.appendSlice(db.allocator, "active = ?");
        field_count += 1;
    }
    if (field_count == 0) return; // Nothing to update
    try sql_parts.appendSlice(db.allocator, " WHERE id = ?");

    // Keep the event_types JSON alive until exec.
    var event_types_json: ?[]u8 = null;
    defer if (event_types_json) |j| db.allocator.free(j);

    var q = try Query.init(db, sql_parts.items);
    defer q.deinit();

    // Bind in the same conditional order the SQL was built.
    if (url) |u| try q.bindText(u);
    if (event_types) |et| {
        event_types_json = try serializeEventTypes(db.allocator, et);
        try q.bindText(event_types_json.?);
    }
    if (active) |a| try q.bindInt(if (a) 1 else 0);
    try q.bindInt64(@intCast(webhook_id));
    try q.exec();

    // If URL was changed, update all pending webhooks in the queue.
    if (url) |u| {
        if (old_url != null) {
            var qq = try Query.init(db, "UPDATE webhook_queue SET webhook_url = ? WHERE webhook_id = ? AND status IN ('pending', 'processing')");
            defer qq.deinit();
            try qq.bindText(u);
            try qq.bindInt64(@intCast(webhook_id));
            // Best-effort: a queue-update failure is logged, not propagated (matches prior behaviour).
            if (qq.exec()) |_| {
                const updated_count = qq.changes();
                if (updated_count > 0) {
                    std.log.info("Updated {d} pending webhook(s) in queue with new URL", .{updated_count});
                }
            } else |_| {
                std.log.warn("Failed to update webhook queue URLs", .{});
            }
        }
    }
}
