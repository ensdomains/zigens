const std = @import("std");
const models = @import("../types/models.zig");
const db = @import("../storage/database.zig");
const json_utils = @import("../utils/json.zig");

// SQLITE_TRANSIENT - For Zig 0.15.1, we can't use the C constant due to alignment issues
// Instead, we use null which tells SQLite to make a copy of the string
inline fn SQLITE_TRANSIENT() db.c.sqlite3_destructor_type {
    return null;
}

pub const WebhookManager = struct {
    allocator: std.mem.Allocator,
    database: *db.Database,  // Separate webhook database connection
    http_client: std.http.Client,
    max_retries: u32,
    worker_threads: std.ArrayList(std.Thread),
    should_stop: std.atomic.Value(bool),
    rate_limit_ms: u64,  // Milliseconds between requests to same endpoint
    db_mutex: std.Thread.Mutex,  // Protects database access from worker threads

    pub fn init(allocator: std.mem.Allocator, webhook_db_path: []const u8, max_retries: u32, rate_limit_ms: u64) !*WebhookManager {
        const manager = try allocator.create(WebhookManager);
        errdefer allocator.destroy(manager);

        // Open separate database connection for webhooks (without auto-loading schema)
        const db_value = try db.Database.initWithoutSchema(allocator, webhook_db_path);

        // Allocate on heap to get a pointer
        const webhook_db = try allocator.create(db.Database);
        errdefer allocator.destroy(webhook_db);
        webhook_db.* = db_value;

        // Load webhook schema from schema/webhooks directory
        try loadWebhookSchema(webhook_db);

        manager.* = .{
            .allocator = allocator,
            .database = webhook_db,
            .http_client = std.http.Client{ .allocator = allocator },
            .max_retries = max_retries,
            .worker_threads = .{},
            .should_stop = std.atomic.Value(bool).init(false),
            .rate_limit_ms = rate_limit_ms,
            .db_mutex = std.Thread.Mutex{},
        };
        return manager;
    }

    pub fn deinit(self: *WebhookManager) void {
        self.http_client.deinit();
        for (self.worker_threads.items) |thread| {
            thread.join();
        }
        self.worker_threads.deinit(self.allocator);
        self.database.deinit();
        self.allocator.destroy(self.database);
        self.allocator.destroy(self);
    }

    fn loadWebhookSchema(database: *db.Database) !void {
        std.log.info("Loading webhook schema...", .{});

        const schema_dir = "schema/webhooks";
        var dir = std.fs.cwd().openDir(schema_dir, .{ .iterate = true }) catch |err| {
            std.log.err("Failed to open webhook schema directory '{s}': {}", .{ schema_dir, err });
            return err;
        };
        defer dir.close();

        var iterator = dir.iterate();
        var schema_files: std.ArrayList([]const u8) = .{};
        defer {
            for (schema_files.items) |file| {
                database.allocator.free(file);
            }
            schema_files.deinit(database.allocator);
        }

        while (try iterator.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".sql")) continue;
            const file_name = try database.allocator.dupe(u8, entry.name);
            try schema_files.append(database.allocator, file_name);
        }

        // Sort schema files by name (001_, 002_, etc.)
        std.mem.sort([]const u8, schema_files.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);

        for (schema_files.items) |file_name| {
            std.log.info("  Applying webhook schema: {s}", .{file_name});

            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const full_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ schema_dir, file_name });

            const sql = try std.fs.cwd().readFileAlloc(database.allocator, full_path, 1024 * 1024);
            defer database.allocator.free(sql);

            database.exec(sql) catch |err| {
                std.log.err("Failed to apply schema {s}: {}", .{ file_name, err });
                return err;
            };
        }

        std.log.info("Webhook schema loading complete ({d} files applied)", .{schema_files.items.len});
    }

    /// Start background worker threads for async webhook delivery
    pub fn startWorkers(self: *WebhookManager, num_workers: u32) !void {
        var i: u32 = 0;
        while (i < num_workers) : (i += 1) {
            const thread = try std.Thread.spawn(.{}, workerLoop, .{self});
            try self.worker_threads.append(self.allocator, thread);
        }
        std.log.info("Started {d} webhook worker thread{s}", .{ num_workers, if (num_workers == 1) "" else "s" });
    }

    /// Stop all worker threads gracefully
    pub fn stopWorkers(self: *WebhookManager) void {
        self.should_stop.store(true, .release);
        std.log.info("Stopping webhook workers...", .{});
    }

    /// Background worker loop - processes webhook queue
    fn workerLoop(self: *WebhookManager) void {
        std.log.debug("Webhook worker started", .{});

        // Wait a bit for initialization to complete
        std.Thread.sleep(1000 * std.time.ns_per_ms);

        while (!self.should_stop.load(.acquire)) {
            // Process pending webhooks
            self.processQueueBatch() catch |err| {
                std.log.err("Worker error processing queue: {}", .{err});
            };

            // Sleep briefly to avoid busy-waiting
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }

        std.log.debug("Webhook worker stopped", .{});
    }

    /// Notify webhooks about an event (async - adds to persistent queue)
    pub fn notify(self: *WebhookManager, event: models.Event) !void {
        // Lock for getting webhooks list
        self.db_mutex.lock();
        const webhooks = self.database.getWebhooks() catch |err| {
            self.db_mutex.unlock();
            return err;
        };
        self.db_mutex.unlock();
        defer {
            for (webhooks) |*wh| {
                wh.deinit(self.allocator);
            }
            self.allocator.free(webhooks);
        }

        if (webhooks.len == 0) {
            std.log.debug("No webhooks configured", .{});
            return;
        }

        // Build webhook payload once
        const payload = try self.buildPayload(event);
        defer self.allocator.free(payload);

        // Enqueue to database for each matching webhook
        for (webhooks) |webhook| {
            if (!webhook.active) continue;

            // Check if subscribed to this event type
            var subscribed = false;
            for (webhook.event_types) |et| {
                if (et == event.event_type) {
                    subscribed = true;
                    break;
                }
            }

            if (!subscribed) continue;

            // Add to persistent queue
            try self.enqueueWebhook(webhook.id, webhook.url, event, payload);
        }
    }

    /// Build JSON payload for event
    fn buildPayload(self: *WebhookManager, event: models.Event) ![]u8 {
        var payload: std.ArrayList(u8) = .{};
        errdefer payload.deinit(self.allocator);

        const tx_hex = try event.tx_hash.toHex(self.allocator);
        defer self.allocator.free(tx_hex);
        const contract_hex = try event.contract_address.toHex(self.allocator);
        defer self.allocator.free(contract_hex);

        // SECURITY: Escape event.data field using RFC 8259 compliant json_utils
        const data_escaped = try json_utils.escapeString(self.allocator, event.data);
        defer self.allocator.free(data_escaped);

        const writer = payload.writer(self.allocator);
        try writer.print("{{\"event_type\":\"{s}\",\"chain\":\"{s}\",\"block_number\":{d},\"tx_hash\":\"{s}\",\"contract_address\":\"{s}\",\"data\":\"{s}\",\"timestamp\":{d}}}",
            .{
                event.event_type.toString(),
                event.chain.toString(),
                event.block_number,
                tx_hex,
                contract_hex,
                data_escaped,
                event.timestamp,
            });

        return payload.toOwnedSlice(self.allocator);
    }

    /// Enqueue webhook delivery to persistent database queue
    fn enqueueWebhook(self: *WebhookManager, webhook_id: u64, webhook_url: []const u8, event: models.Event, payload: []const u8) !void {
        self.db_mutex.lock();
        defer self.db_mutex.unlock();

        const sql =
            \\INSERT INTO webhook_queue
            \\(webhook_id, webhook_url, event_type, chain, block_number, tx_hash, contract_address, payload, timestamp, next_retry_at)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ;

        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        var stmt: ?*db.c.sqlite3_stmt = null;
        _ = db.c.sqlite3_prepare_v2(self.database.db, sql_z.ptr, -1, &stmt, null);
        defer _ = db.c.sqlite3_finalize(stmt);

        const tx_hex = try event.tx_hash.toHex(self.allocator);
        defer self.allocator.free(tx_hex);
        const contract_hex = try event.contract_address.toHex(self.allocator);
        defer self.allocator.free(contract_hex);

        _ = db.c.sqlite3_bind_int64(stmt, 1, @intCast(webhook_id));
        _ = db.c.sqlite3_bind_text(stmt, 2, webhook_url.ptr, @intCast(webhook_url.len), SQLITE_TRANSIENT());
        _ = db.c.sqlite3_bind_text(stmt, 3, event.event_type.toString().ptr, @intCast(event.event_type.toString().len), SQLITE_TRANSIENT());
        _ = db.c.sqlite3_bind_text(stmt, 4, event.chain.toString().ptr, @intCast(event.chain.toString().len), SQLITE_TRANSIENT());
        _ = db.c.sqlite3_bind_int64(stmt, 5, @intCast(event.block_number));
        _ = db.c.sqlite3_bind_text(stmt, 6, tx_hex.ptr, @intCast(tx_hex.len), SQLITE_TRANSIENT());
        _ = db.c.sqlite3_bind_text(stmt, 7, contract_hex.ptr, @intCast(contract_hex.len), SQLITE_TRANSIENT());
        _ = db.c.sqlite3_bind_text(stmt, 8, payload.ptr, @intCast(payload.len), SQLITE_TRANSIENT());
        _ = db.c.sqlite3_bind_int64(stmt, 9, event.timestamp);
        _ = db.c.sqlite3_bind_int64(stmt, 10, std.time.timestamp()); // Can send immediately

        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) {
            std.log.err("Failed to enqueue webhook: {s}", .{db.c.sqlite3_errmsg(self.database.db)});
            return error.EnqueueFailed;
        }

        std.log.debug("Enqueued webhook for {s}: {s}", .{ webhook_url, event.event_type.toString() });
    }

    /// Webhook job for processing
    const WebhookJob = struct {
        queue_id: u64,
        webhook_url: []const u8,
        payload: []const u8,
        retry_count: u32,

        fn deinit(self: *WebhookJob, allocator: std.mem.Allocator) void {
            allocator.free(self.webhook_url);
            allocator.free(self.payload);
        }
    };

    /// Process a batch of pending webhooks from the queue
    fn processQueueBatch(self: *WebhookManager) !void {
        const now = std.time.timestamp();

        // Fetch and copy webhook jobs from database (with mutex protection)
        var jobs: std.ArrayList(WebhookJob) = .{};
        defer {
            for (jobs.items) |*job| {
                job.deinit(self.allocator);
            }
            jobs.deinit(self.allocator);
        }

        // Lock database only for fetching jobs
        {
            self.db_mutex.lock();
            defer self.db_mutex.unlock();

            const sql =
                \\SELECT id, webhook_url, payload, retry_count
                \\FROM webhook_queue
                \\WHERE status IN ('pending', 'processing')
                \\  AND next_retry_at <= ?
                \\ORDER BY webhook_url, created_at
                \\LIMIT 50
            ;

            const sql_z = try self.allocator.dupeZ(u8, sql);
            defer self.allocator.free(sql_z);

            var stmt: ?*db.c.sqlite3_stmt = null;
            _ = db.c.sqlite3_prepare_v2(self.database.db, sql_z.ptr, -1, &stmt, null);
            defer _ = db.c.sqlite3_finalize(stmt);

            _ = db.c.sqlite3_bind_int64(stmt, 1, now);

            while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
                const queue_id: u64 = @intCast(db.c.sqlite3_column_int64(stmt, 0));
                const webhook_url_span = std.mem.span(db.c.sqlite3_column_text(stmt, 1));
                const payload_span = std.mem.span(db.c.sqlite3_column_text(stmt, 2));
                const retry_count: u32 = @intCast(db.c.sqlite3_column_int(stmt, 3));

                // IMPORTANT: Copy strings before releasing mutex/finalizing statement
                const webhook_url = try self.allocator.dupe(u8, webhook_url_span);
                errdefer self.allocator.free(webhook_url);
                const payload = try self.allocator.dupe(u8, payload_span);
                errdefer self.allocator.free(payload);

                try jobs.append(self.allocator, .{
                    .queue_id = queue_id,
                    .webhook_url = webhook_url,
                    .payload = payload,
                    .retry_count = retry_count,
                });
            }
        }

        // Process jobs outside of mutex lock
        var endpoint_last_sent = std.StringHashMap(i64).init(self.allocator);
        defer endpoint_last_sent.deinit();

        for (jobs.items) |job| {
            // Check rate limit for this endpoint
            if (endpoint_last_sent.get(job.webhook_url)) |last_sent_time| {
                const time_since_last = now - last_sent_time;
                const rate_limit_secs: i64 = @intCast(self.rate_limit_ms / 1000);
                if (time_since_last < rate_limit_secs) {
                    std.log.debug("Rate limiting {s}, skipping for now", .{job.webhook_url});
                    continue;
                }
            }

            // Attempt delivery
            std.log.debug("Delivering queued webhook id={d} to {s} (attempt {d})", .{ job.queue_id, job.webhook_url, job.retry_count + 1 });

            const success = self.attemptDelivery(job.queue_id, job.webhook_url, job.payload, job.retry_count) catch |err| blk: {
                std.log.err("Delivery error for webhook id={d}: {}", .{ job.queue_id, err });
                break :blk false;
            };

            // Update last sent time for this endpoint
            try endpoint_last_sent.put(job.webhook_url, now);

            // Update queue item status
            if (success) {
                try self.markDelivered(job.queue_id);
            } else {
                try self.markFailed(job.queue_id, job.retry_count);
            }
        }
    }

    /// Attempt webhook delivery and return success status
    fn attemptDelivery(self: *WebhookManager, queue_id: u64, url: []const u8, payload: []const u8, retry_count: u32) !bool {
        _ = queue_id;
        _ = retry_count;

        return self.sendHttpPost(url, payload) catch false;
    }

    /// Mark webhook as successfully delivered
    fn markDelivered(self: *WebhookManager, queue_id: u64) !void {
        self.db_mutex.lock();
        defer self.db_mutex.unlock();

        const sql = "UPDATE webhook_queue SET status = 'delivered', updated_at = ? WHERE id = ?";
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        var stmt: ?*db.c.sqlite3_stmt = null;
        _ = db.c.sqlite3_prepare_v2(self.database.db, sql_z.ptr, -1, &stmt, null);
        defer _ = db.c.sqlite3_finalize(stmt);

        _ = db.c.sqlite3_bind_int64(stmt, 1, std.time.timestamp());
        _ = db.c.sqlite3_bind_int64(stmt, 2, @intCast(queue_id));

        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) {
            return error.UpdateFailed;
        }

        std.log.debug("Marked webhook id={d} as delivered", .{queue_id});
    }

    /// Mark webhook as failed and schedule retry with exponential backoff
    fn markFailed(self: *WebhookManager, queue_id: u64, retry_count: u32) !void {
        self.db_mutex.lock();
        defer self.db_mutex.unlock();

        const new_retry_count = retry_count + 1;

        // Calculate next retry time with exponential backoff
        const backoff_secs = @min(@as(i64, 60) * (@as(i64, 1) << @intCast(@min(retry_count, 10))), 3600); // Max 1 hour
        const next_retry_at = std.time.timestamp() + backoff_secs;

        // Determine if we should give up
        const status = if (new_retry_count >= self.max_retries) "failed" else "pending";

        const sql =
            \\UPDATE webhook_queue
            \\SET status = ?, retry_count = ?, next_retry_at = ?, updated_at = ?, last_attempt_at = ?
            \\WHERE id = ?
        ;
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        var stmt: ?*db.c.sqlite3_stmt = null;
        _ = db.c.sqlite3_prepare_v2(self.database.db, sql_z.ptr, -1, &stmt, null);
        defer _ = db.c.sqlite3_finalize(stmt);

        _ = db.c.sqlite3_bind_text(stmt, 1, status.ptr, @intCast(status.len), SQLITE_TRANSIENT());
        _ = db.c.sqlite3_bind_int(stmt, 2, @intCast(new_retry_count));
        _ = db.c.sqlite3_bind_int64(stmt, 3, next_retry_at);
        _ = db.c.sqlite3_bind_int64(stmt, 4, std.time.timestamp());
        _ = db.c.sqlite3_bind_int64(stmt, 5, std.time.timestamp());
        _ = db.c.sqlite3_bind_int64(stmt, 6, @intCast(queue_id));

        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) {
            return error.UpdateFailed;
        }

        if (new_retry_count >= self.max_retries) {
            std.log.warn("Webhook id={d} permanently failed after {d} attempts", .{ queue_id, new_retry_count });
        } else {
            std.log.debug("Webhook id={d} retry scheduled for {d}s (attempt {d}/{d})", .{ queue_id, backoff_secs, new_retry_count, self.max_retries });
        }
    }

    fn sendHttpPost(self: *WebhookManager, url: []const u8, payload: []const u8) !bool {
        // Use curl for HTTP POST (same workaround as RPC client for Zig 0.15.1 TLS issues)
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{
                "curl",
                "-s",             // Silent mode
                "-X",
                "POST",
                "-H",
                "Content-Type: application/json",
                "-H",
                "User-Agent: ENSv2-Indexer/0.1.0",
                "-d",
                payload,
                "-w",
                "%{http_code}",   // Write HTTP status code to stdout
                "-o",
                "/dev/null",      // Don't output response body
                url,
            },
            .max_output_bytes = 1024,
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term != .Exited or result.term.Exited != 0) {
            std.log.err("curl process failed: {}", .{result.term});
            return error.HttpError;
        }

        // Parse status code
        const status_code = std.fmt.parseInt(u16, result.stdout, 10) catch {
            std.log.err("Failed to parse HTTP status code: {s}", .{result.stdout});
            return error.InvalidStatusCode;
        };

        // 2xx is success
        if (status_code >= 200 and status_code < 300) {
            return true;
        } else {
            std.log.err("Webhook returned status {d}", .{status_code});
            return false;
        }
    }

    /// Register a new webhook
    pub fn registerWebhook(self: *WebhookManager, url: []const u8, event_types: []const models.EventType) !u64 {
        const webhook = models.Webhook{
            .id = 0, // Auto-generated by database
            .url = url,
            .event_types = event_types,
            .active = true,
            .max_retries = self.max_retries,
            .created_at = std.time.timestamp(),
        };

        const webhook_id = try self.database.insertWebhook(webhook);
        std.log.info("Registered webhook id={d} url={s}", .{ webhook_id, url });
        return webhook_id;
    }

    /// Unregister a webhook
    pub fn unregisterWebhook(self: *WebhookManager, webhook_id: u64) !void {
        try self.database.deleteWebhook(webhook_id);
        std.log.info("Unregistered webhook id={d}", .{webhook_id});
    }

    /// List all webhooks
    pub fn listWebhooks(self: *WebhookManager) ![]models.Webhook {
        return try self.database.getWebhooks();
    }
};

test "WebhookManager init" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try db.Database.init(allocator, ":memory:");
    defer database.deinit();

    const manager = try WebhookManager.init(allocator, &database, 3, 1000);
    defer manager.deinit();

    try std.testing.expect(manager.max_retries == 3);
}

test "WebhookManager register webhook" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try db.Database.init(allocator, ":memory:");
    defer database.deinit();

    const manager = try WebhookManager.init(allocator, &database, 3, 1000);
    defer manager.deinit();

    const event_types = [_]models.EventType{.name_registered};
    const webhook_id = try manager.registerWebhook("https://example.com/webhook", &event_types);

    try std.testing.expect(webhook_id > 0);
}

test "WebhookManager unregister webhook" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try db.Database.init(allocator, ":memory:");
    defer database.deinit();

    const manager = try WebhookManager.init(allocator, &database, 3, 1000);
    defer manager.deinit();

    const event_types = [_]models.EventType{.name_registered};
    const webhook_id = try manager.registerWebhook("https://example.com/webhook", &event_types);

    // Unregister should not error
    try manager.unregisterWebhook(webhook_id);
}

test "WebhookManager list webhooks" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try db.Database.init(allocator, ":memory:");
    defer database.deinit();

    const manager = try WebhookManager.init(allocator, &database, 3, 1000);
    defer manager.deinit();

    const event_types = [_]models.EventType{.name_registered};
    _ = try manager.registerWebhook("https://example.com/webhook1", &event_types);
    _ = try manager.registerWebhook("https://example.com/webhook2", &event_types);

    const webhooks = try manager.listWebhooks();
    defer {
        for (webhooks) |*wh| {
            wh.deinit(allocator);
        }
        allocator.free(webhooks);
    }

    try std.testing.expect(webhooks.len == 2);
}
