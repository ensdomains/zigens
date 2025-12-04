const std = @import("std");
const db_module = @import("database.zig");
const Database = db_module.Database;
const c = db_module.c;
const models = @import("../types/models.zig");

// SQLITE_TRANSIENT - For Zig 0.15.1, we can't use the C constant due to alignment issues
// Instead, we use null which tells SQLite to make a copy of the string
inline fn SQLITE_TRANSIENT() c.sqlite3_destructor_type {
    return null;
}

// ============================================================================
// WEBHOOK OPERATIONS (3 functions)
// ============================================================================

/// Insert a webhook
pub fn insertWebhook(db: *Database, webhook: models.Webhook) !u64 {
    const sql =
        \\INSERT INTO webhooks
        \\(url, event_types, active, max_retries, created_at)
        \\VALUES (?, ?, ?, ?, ?)
    ;

    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    // Serialize event_types as JSON array
    var event_types_json: std.ArrayList(u8) = .{};
    defer event_types_json.deinit(db.allocator);
    try event_types_json.append(db.allocator, '[');
    for (webhook.event_types, 0..) |et, i| {
        if (i > 0) try event_types_json.appendSlice(db.allocator, ",");
        try event_types_json.append(db.allocator, '"');
        try event_types_json.appendSlice(db.allocator, et.toString());
        try event_types_json.append(db.allocator, '"');
    }
    try event_types_json.append(db.allocator, ']');

    const active: c_int = if (webhook.active) 1 else 0;

    _ = c.sqlite3_bind_text(stmt, 1, webhook.url.ptr, @intCast(webhook.url.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 2, event_types_json.items.ptr, @intCast(event_types_json.items.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int(stmt, 3, active);
    _ = c.sqlite3_bind_int(stmt, 4, @intCast(webhook.max_retries));
    _ = c.sqlite3_bind_int64(stmt, 5, webhook.created_at);

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to insert webhook: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.InsertFailed;
    }

    return @intCast(c.sqlite3_last_insert_rowid(db.db));
}

/// Delete a webhook by ID
pub fn deleteWebhook(db: *Database, webhook_id: u64) !void {
    const sql = "DELETE FROM webhooks WHERE id = ?";

    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int64(stmt, 1, @intCast(webhook_id));

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to delete webhook: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.DeleteFailed;
    }
}

/// Get all webhooks
pub fn getWebhooks(db: *Database) ![]models.Webhook {
    const sql = "SELECT id, url, event_types, active, max_retries, created_at FROM webhooks";

    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    var webhooks: std.ArrayList(models.Webhook) = .{};
    errdefer {
        for (webhooks.items) |*wh| {
            wh.deinit(db.allocator);
        }
        webhooks.deinit(db.allocator);
    }

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const url_str = std.mem.span(c.sqlite3_column_text(stmt, 1));
        const event_types_json = std.mem.span(c.sqlite3_column_text(stmt, 2));

        // Parse event_types JSON array (simplified - just split by quotes)
        var event_types: std.ArrayList(models.EventType) = .{};
        errdefer event_types.deinit(db.allocator);

        // Very simple JSON array parsing - look for quoted strings
        var i: usize = 0;
        while (i < event_types_json.len) : (i += 1) {
            if (event_types_json[i] == '"') {
                const start = i + 1;
                i += 1;
                while (i < event_types_json.len and event_types_json[i] != '"') : (i += 1) {}
                const type_str = event_types_json[start..i];
                if (models.EventType.fromString(type_str)) |et| {
                    try event_types.append(db.allocator, et);
                }
            }
        }

        const webhook = models.Webhook{
            .id = @intCast(c.sqlite3_column_int64(stmt, 0)),
            .url = try db.allocator.dupe(u8, url_str),
            .event_types = try event_types.toOwnedSlice(db.allocator),
            .active = c.sqlite3_column_int(stmt, 3) != 0,
            .max_retries = @intCast(c.sqlite3_column_int(stmt, 4)),
            .created_at = c.sqlite3_column_int64(stmt, 5),
        };

        try webhooks.append(db.allocator, webhook);
    }

    return webhooks.toOwnedSlice(db.allocator);
}

/// Get a webhook by ID
pub fn getWebhook(db: *Database, webhook_id: u64) !?models.Webhook {
    const sql = "SELECT id, url, event_types, active, max_retries, created_at FROM webhooks WHERE id = ?";

    const sql_z = try db.allocator.dupeZ(u8, sql);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int64(stmt, 1, @intCast(webhook_id));

    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) {
        return null;
    }

    const url_str = std.mem.span(c.sqlite3_column_text(stmt, 1));
    const event_types_json = std.mem.span(c.sqlite3_column_text(stmt, 2));

    // Parse event_types JSON array
    var event_types: std.ArrayList(models.EventType) = .{};
    errdefer event_types.deinit(db.allocator);

    var i: usize = 0;
    while (i < event_types_json.len) : (i += 1) {
        if (event_types_json[i] == '"') {
            const start = i + 1;
            i += 1;
            while (i < event_types_json.len and event_types_json[i] != '"') : (i += 1) {}
            const type_str = event_types_json[start..i];
            if (models.EventType.fromString(type_str)) |et| {
                try event_types.append(db.allocator, et);
            }
        }
    }

    return models.Webhook{
        .id = @intCast(c.sqlite3_column_int64(stmt, 0)),
        .url = try db.allocator.dupe(u8, url_str),
        .event_types = try event_types.toOwnedSlice(db.allocator),
        .active = c.sqlite3_column_int(stmt, 3) != 0,
        .max_retries = @intCast(c.sqlite3_column_int(stmt, 4)),
        .created_at = c.sqlite3_column_int64(stmt, 5),
    };
}

/// Update a webhook
pub fn updateWebhook(db: *Database, webhook_id: u64, url: ?[]const u8, event_types: ?[]const models.EventType, active: ?bool) !void {
    // Get the old URL before updating, if URL is being changed
    var old_url: ?[]const u8 = null;
    if (url != null) {
        const webhook = try getWebhook(db, webhook_id);
        if (webhook) |wh| {
            old_url = try db.allocator.dupe(u8, wh.url);
            // Free the webhook struct but keep old_url
            db.allocator.free(wh.url);
            db.allocator.free(wh.event_types);
        }
    }
    defer if (old_url) |ou| db.allocator.free(ou);

    // Build dynamic SQL based on what fields are provided
    var sql_parts: std.ArrayList(u8) = .{};
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

    if (field_count == 0) {
        return; // Nothing to update
    }

    try sql_parts.appendSlice(db.allocator, " WHERE id = ?");

    const sql_z = try db.allocator.dupeZ(u8, sql_parts.items);
    defer db.allocator.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db.db, sql_z.ptr, -1, &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    // Keep event_types JSON alive for the entire function scope
    var event_types_json: std.ArrayList(u8) = .{};
    defer event_types_json.deinit(db.allocator);

    // Bind parameters in order
    var bind_index: c_int = 1;

    if (url) |u| {
        _ = c.sqlite3_bind_text(stmt, bind_index, u.ptr, @intCast(u.len), SQLITE_TRANSIENT());
        bind_index += 1;
    }

    if (event_types) |et| {
        // Serialize event_types as JSON array
        try event_types_json.append(db.allocator, '[');
        for (et, 0..) |evt, i| {
            if (i > 0) try event_types_json.appendSlice(db.allocator, ",");
            try event_types_json.append(db.allocator, '"');
            try event_types_json.appendSlice(db.allocator, evt.toString());
            try event_types_json.append(db.allocator, '"');
        }
        try event_types_json.append(db.allocator, ']');

        _ = c.sqlite3_bind_text(stmt, bind_index, event_types_json.items.ptr, @intCast(event_types_json.items.len), SQLITE_TRANSIENT());
        bind_index += 1;
    }

    if (active) |a| {
        const active_int: c_int = if (a) 1 else 0;
        _ = c.sqlite3_bind_int(stmt, bind_index, active_int);
        bind_index += 1;
    }

    // Bind webhook ID for WHERE clause
    _ = c.sqlite3_bind_int64(stmt, bind_index, @intCast(webhook_id));

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.log.err("Failed to update webhook: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.UpdateFailed;
    }

    // If URL was changed, update all pending webhooks in the queue
    if (url != null and old_url != null) {
        const queue_sql = "UPDATE webhook_queue SET webhook_url = ? WHERE webhook_id = ? AND status IN ('pending', 'processing')";
        const queue_sql_z = try db.allocator.dupeZ(u8, queue_sql);
        defer db.allocator.free(queue_sql_z);

        var queue_stmt: ?*c.sqlite3_stmt = null;
        const queue_prepare_result = c.sqlite3_prepare_v2(db.db, queue_sql_z.ptr, -1, &queue_stmt, null);
        if (queue_prepare_result != c.SQLITE_OK) {
            std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(db.db)});
            return error.PrepareFailed;
        }
        defer _ = c.sqlite3_finalize(queue_stmt);

        _ = c.sqlite3_bind_text(queue_stmt, 1, url.?.ptr, @intCast(url.?.len), SQLITE_TRANSIENT());
        _ = c.sqlite3_bind_int64(queue_stmt, 2, @intCast(webhook_id));

        if (c.sqlite3_step(queue_stmt) == c.SQLITE_DONE) {
            const updated_count = c.sqlite3_changes(db.db);
            if (updated_count > 0) {
                std.log.info("Updated {d} pending webhook(s) in queue with new URL", .{updated_count});
            }
        } else {
            std.log.warn("Failed to update webhook queue URLs: {s}", .{c.sqlite3_errmsg(db.db)});
        }
    }
}
