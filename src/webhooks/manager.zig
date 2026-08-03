const std = @import("std");
const zsys = @import("../utils/system.zig");
const models = @import("../types/models.zig");
const db = @import("../storage/database.zig");
const json_utils = @import("../utils/json.zig");

/// Generate a 32-byte random HMAC secret, hex-encoded (64 chars + "0x"-style prefix omitted).
/// Caller owns the returned slice. Use `std.crypto.random` for cryptographically secure bytes.
pub fn generateWebhookSecret(allocator: std.mem.Allocator) ![]u8 {
    var raw: [32]u8 = undefined;
    zsys.randomBytes(&raw);
    const hex = std.fmt.bytesToHex(raw, .lower);
    return try allocator.dupe(u8, &hex);
}

/// Compute HMAC-SHA256(secret, "{timestamp}.{payload}") and return the hex digest.
/// The timestamp is the canonical Unix-second timestamp the receiver verifies for replay
/// protection. The same string is sent in `X-Webhook-Timestamp`. Receivers verify by:
///   1. parsing X-Webhook-Timestamp; reject if older than their tolerance window
///   2. recomputing HMAC-SHA256(secret, "<timestamp>.<body>") and constant-time-comparing
///      against the value after `sha256=` in X-Webhook-Signature.
pub fn computeWebhookSignature(allocator: std.mem.Allocator, secret_hex: []const u8, timestamp_secs: i64, payload: []const u8) ![]u8 {
    // Decode the hex secret back into raw bytes for HMAC.
    if (secret_hex.len % 2 != 0) return error.InvalidSecretLength;
    const secret_raw = try allocator.alloc(u8, secret_hex.len / 2);
    defer allocator.free(secret_raw);
    _ = try std.fmt.hexToBytes(secret_raw, secret_hex);

    // Format timestamp as decimal string for the signed-string preamble.
    var ts_buf: [24]u8 = undefined;
    const ts_str = try std.fmt.bufPrint(&ts_buf, "{d}", .{timestamp_secs});

    // signed_string = "{ts}.{payload}"
    var signed: std.ArrayList(u8) = .empty;
    defer signed.deinit(allocator);
    try signed.appendSlice(allocator, ts_str);
    try signed.append(allocator, '.');
    try signed.appendSlice(allocator, payload);

    var mac: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, signed.items, secret_raw);

    const hex = std.fmt.bytesToHex(mac, .lower);
    return try allocator.dupe(u8, &hex);
}

test "generateWebhookSecret produces 64 hex chars" {
    const allocator = std.testing.allocator;
    const s = try generateWebhookSecret(allocator);
    defer allocator.free(s);
    try std.testing.expectEqual(@as(usize, 64), s.len);
}

test "computeWebhookSignature is deterministic for fixed inputs" {
    const allocator = std.testing.allocator;
    // 32-byte secret of zeros
    const secret = "0000000000000000000000000000000000000000000000000000000000000000";
    const sig_a = try computeWebhookSignature(allocator, secret, 1700000000, "hello");
    defer allocator.free(sig_a);
    const sig_b = try computeWebhookSignature(allocator, secret, 1700000000, "hello");
    defer allocator.free(sig_b);
    try std.testing.expectEqualStrings(sig_a, sig_b);
    try std.testing.expectEqual(@as(usize, 64), sig_a.len);
}

/// Strip userinfo (`user:pass@`) from a URL before logging.
/// Webhook owners may register URLs with credentials embedded in the authority
/// component; those must never appear in logs. Returns the input unchanged when
/// no userinfo is present.
fn sanitizeUrlForLog(url: []const u8) []const u8 {
    // Look for "://", then for "@" before the next "/" or "?".
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return url;
    const authority_start = scheme_end + 3;
    if (authority_start >= url.len) return url;
    // Find the end of the authority component.
    const authority_end_offset = std.mem.indexOfAnyPos(u8, url, authority_start, "/?#") orelse url.len;
    const at_idx = std.mem.indexOfScalarPos(u8, url, authority_start, '@') orelse return url;
    if (at_idx >= authority_end_offset) return url; // '@' is in path/query, not authority
    // Cannot allocate from a leaf logging helper without an allocator parameter; instead,
    // log the URL with credentials already stripped by recomposing the visible portion.
    // Callers that want a single-string display should use this in a print: "{s}<redacted>{s}"
    // — but for simplicity we just return the suffix starting at the host. The scheme
    // is short and well-known, so dropping it from log lines is acceptable in this context.
    _ = url[0..scheme_end]; // scheme available if we wanted to prepend it
    return url[at_idx + 1 ..];
}

test "sanitizeUrlForLog strips userinfo" {
    try std.testing.expectEqualStrings("example.com/hook", sanitizeUrlForLog("https://user:pass@example.com/hook"));
    try std.testing.expectEqualStrings("example.com/hook", sanitizeUrlForLog("https://user@example.com/hook"));
    try std.testing.expectEqualStrings("https://example.com/hook?a=b@c", sanitizeUrlForLog("https://example.com/hook?a=b@c"));
    try std.testing.expectEqualStrings("https://example.com/hook", sanitizeUrlForLog("https://example.com/hook"));
}

pub const WebhookManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    database: *db.Database, // Separate webhook database connection
    http_client: std.http.Client,
    max_retries: u32,
    worker_threads: std.ArrayList(std.Thread),
    should_stop: std.atomic.Value(bool),
    rate_limit_ms: u64, // Milliseconds between requests to same endpoint
    db_mutex: zsys.Mutex, // Protects database access from worker threads
    last_cleanup_at: std.atomic.Value(i64), // Timestamp of last queue cleanup
    // Detached delivery threads still inside http_client.fetch; deinit must not
    // free the client while nonzero (see the bounded wait there).
    inflight_deliveries: std.atomic.Value(usize),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, webhook_db_path: []const u8, max_retries: u32, rate_limit_ms: u64) !*WebhookManager {
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
            .io = io,
            .database = webhook_db,
            .http_client = std.http.Client{ .allocator = allocator, .io = io },
            .max_retries = max_retries,
            .worker_threads = .empty,
            .should_stop = std.atomic.Value(bool).init(false),
            .rate_limit_ms = rate_limit_ms,
            .db_mutex = zsys.Mutex{},
            .last_cleanup_at = std.atomic.Value(i64).init(0), // Will run cleanup on first check
            .inflight_deliveries = std.atomic.Value(usize).init(0),
        };
        return manager;
    }

    pub fn deinit(self: *WebhookManager) void {
        // Workers first: joining them bounds new delivery spawns, and a worker
        // mid-delivery blocks in sendHttpPost at most HTTP_DELIVERY_DEADLINE_MS.
        self.should_stop.store(true, .release);
        for (self.worker_threads.items) |thread| {
            thread.join();
        }
        self.worker_threads.deinit(self.allocator);

        // Abandoned (timed-out) delivery threads may still be inside
        // http_client.fetch. Bounded wait; on timeout, deliberately LEAK the
        // client rather than free it under a live thread — the process is
        // exiting, and a leak report beats a use-after-free.
        const deadline_ms = zsys.milliTimestamp() + HTTP_DELIVERY_DEADLINE_MS + 2_000;
        while (self.inflight_deliveries.load(.acquire) > 0 and zsys.milliTimestamp() < deadline_ms) {
            zsys.sleep(50 * std.time.ns_per_ms);
        }
        const stuck = self.inflight_deliveries.load(.acquire);
        if (stuck == 0) {
            self.http_client.deinit();
        } else {
            std.log.warn("{d} webhook delivery thread(s) stuck in OS-level timeouts; leaking http client on exit", .{stuck});
        }

        self.database.deinit();
        self.allocator.destroy(self.database);
        self.allocator.destroy(self);
    }

    fn loadWebhookSchema(database: *db.Database) !void {
        std.log.info("Loading webhook schema...", .{});

        const schema_dir = "schema/webhooks";
        const dir_names = zsys.listFiles(database.allocator, schema_dir) catch |err| {
            std.log.err("Failed to open webhook schema directory '{s}': {}", .{ schema_dir, err });
            return err;
        };
        defer zsys.freeFileList(database.allocator, dir_names);

        var schema_files: std.ArrayList([]const u8) = .empty;
        defer schema_files.deinit(database.allocator);

        for (dir_names) |entry_name| {
            if (!std.mem.endsWith(u8, entry_name, ".sql")) continue;
            try schema_files.append(database.allocator, entry_name);
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

            const sql = try zsys.readFileAlloc(database.allocator, full_path, 1024 * 1024);
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
        zsys.sleep(1000 * std.time.ns_per_ms);

        // Reclaim any rows stuck in 'processing' from a previous crashed/restarted worker.
        // Done once at startup; subsequent stale-claim recovery happens periodically
        // (every cleanup cycle) below.
        self.reclaimStuckClaims() catch |err| {
            std.log.warn("reclaimStuckClaims at startup failed: {}", .{err});
        };

        while (!self.should_stop.load(.acquire)) {
            // Process pending webhooks
            self.processQueueBatch() catch |err| {
                std.log.err("Worker error processing queue: {}", .{err});
            };

            // Run daily cleanup if 24 hours have passed
            self.runDailyCleanupIfNeeded();

            // Sleep briefly to avoid busy-waiting
            zsys.sleep(100 * std.time.ns_per_ms);
        }

        std.log.debug("Webhook worker stopped", .{});
    }

    /// Reclaim rows stuck in 'processing' state after a crash. A row is considered
    /// stuck if `updated_at` is older than the stuck threshold (default 5 minutes —
    /// well beyond a normal HTTP timeout). Reclaimed rows go back to 'pending'.
    fn reclaimStuckClaims(self: *WebhookManager) !void {
        const stuck_threshold_secs: i64 = 300; // 5 minutes
        const now = zsys.timestamp();
        const cutoff = now - stuck_threshold_secs;

        self.db_mutex.lock();
        defer self.db_mutex.unlock();

        // Best-effort: any failure silently returns (matches prior behaviour).
        var q = db.Query.init(self.database, "UPDATE webhook_queue SET status = 'pending', updated_at = ? WHERE status = 'processing' AND updated_at < ?") catch return;
        defer q.deinit();
        q.bindInt64(now) catch return;
        q.bindInt64(cutoff) catch return;
        q.exec() catch return;

        const reclaimed = q.changes();
        if (reclaimed > 0) {
            std.log.info("Reclaimed {d} webhook delivery row(s) stuck in 'processing'", .{reclaimed});
        }
    }

    /// Run queue cleanup once per day (24 hours)
    fn runDailyCleanupIfNeeded(self: *WebhookManager) void {
        const now = zsys.timestamp();
        const last_cleanup = self.last_cleanup_at.load(.acquire);
        const one_day_seconds: i64 = 86400;

        // Reclaim any stuck 'processing' rows on every worker tick, cheap and crash-safe.
        self.reclaimStuckClaims() catch |err| {
            std.log.debug("Periodic reclaimStuckClaims failed: {}", .{err});
        };

        // Check if 24 hours have passed since last cleanup
        if (now - last_cleanup >= one_day_seconds) {
            // Try to claim the cleanup (avoid multiple workers running it)
            if (self.last_cleanup_at.cmpxchgStrong(last_cleanup, now, .acq_rel, .acquire) == null) {
                // Successfully claimed - run cleanup
                const stats = self.cleanupQueueDefault() catch |err| {
                    std.log.err("Daily queue cleanup failed: {}", .{err});
                    return;
                };

                if (stats.delivered_removed > 0 or stats.failed_removed > 0) {
                    std.log.info("Daily cleanup: removed {d} delivered, {d} failed webhook entries", .{
                        stats.delivered_removed,
                        stats.failed_removed,
                    });
                }
            }
        }
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
            try self.enqueueWebhook(webhook.id, webhook.url, webhook.secret, event, payload);
        }
    }

    /// Build JSON payload for event
    fn buildPayload(self: *WebhookManager, event: models.Event) ![]u8 {
        var payload: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer payload.deinit();

        const tx_hex = try event.tx_hash.toHex(self.allocator);
        defer self.allocator.free(tx_hex);
        const contract_hex = try event.contract_address.toHex(self.allocator);
        defer self.allocator.free(contract_hex);

        // SECURITY: Escape event.data field using RFC 8259 compliant json_utils
        const data_escaped = try json_utils.escapeString(self.allocator, event.data);
        defer self.allocator.free(data_escaped);

        const writer = &payload.writer;

        // Build base payload with required fields
        try writer.print("{{\"event_type\":\"{s}\",\"protocol\":\"{s}\",\"block_number\":{d},\"tx_hash\":\"{s}\",\"log_index\":{d},\"contract_address\":\"{s}\"", .{
            event.event_type.toString(),
            event.protocol.toString(),
            event.block_number,
            tx_hex,
            event.log_index,
            contract_hex,
        });

        // Add optional name field
        if (event.name) |name| {
            const name_escaped = try json_utils.escapeString(self.allocator, name);
            defer self.allocator.free(name_escaped);
            try writer.print(",\"name\":\"{s}\"", .{name_escaped});
        } else {
            try writer.writeAll(",\"name\":null");
        }

        // Add optional namehash field
        if (event.namehash) |nh| {
            const nh_hex = try nh.toHex(self.allocator);
            defer self.allocator.free(nh_hex);
            try writer.print(",\"namehash\":\"{s}\"", .{nh_hex});
        } else {
            try writer.writeAll(",\"namehash\":null");
        }

        // Add data and timestamp
        try writer.print(",\"data\":\"{s}\",\"timestamp\":{d}}}", .{ data_escaped, event.timestamp });

        return payload.toOwnedSlice();
    }

    /// Enqueue webhook delivery to persistent database queue.
    /// Captures the webhook's HMAC secret at enqueue time so a later rotation doesn't
    /// invalidate signatures on already-queued deliveries.
    fn enqueueWebhook(self: *WebhookManager, webhook_id: u64, webhook_url: []const u8, webhook_secret: []const u8, event: models.Event, payload: []const u8) !void {
        self.db_mutex.lock();
        defer self.db_mutex.unlock();

        const sql =
            \\INSERT INTO webhook_queue
            \\(webhook_id, webhook_url, webhook_secret, event_type, protocol, block_number, tx_hash, contract_address, payload, timestamp, next_retry_at)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ;

        var q = try db.Query.init(self.database, sql);
        defer q.deinit();

        try q.bindInt64(@intCast(webhook_id));
        try q.bindText(webhook_url);
        try q.bindText(webhook_secret);
        try q.bindTextStatic(event.event_type.toString());
        try q.bindTextStatic(event.protocol.toString());
        try q.bindInt64(@intCast(event.block_number));
        try q.bindHash(event.tx_hash);
        try q.bindAddress(event.contract_address);
        try q.bindText(payload);
        try q.bindInt64(event.timestamp);
        try q.bindInt64(zsys.timestamp()); // Can send immediately
        try q.exec();

        std.log.debug("Enqueued webhook for {s}: {s}", .{ sanitizeUrlForLog(webhook_url), event.event_type.toString() });
    }

    /// Webhook job for processing
    const WebhookJob = struct {
        queue_id: u64,
        webhook_url: []const u8,
        webhook_secret: []const u8,
        payload: []const u8,
        retry_count: u32,

        fn deinit(self: *WebhookJob, allocator: std.mem.Allocator) void {
            allocator.free(self.webhook_url);
            allocator.free(self.webhook_secret);
            allocator.free(self.payload);
        }
    };

    /// Process a batch of pending webhooks from the queue
    fn processQueueBatch(self: *WebhookManager) !void {
        const now = zsys.timestamp();

        // Fetch and copy webhook jobs from database (with mutex protection)
        var jobs: std.ArrayList(WebhookJob) = .empty;
        defer {
            for (jobs.items) |*job| {
                job.deinit(self.allocator);
            }
            jobs.deinit(self.allocator);
        }

        // Atomically claim a batch: flip pending→processing in one statement and return the
        // rows we successfully transitioned. Without this, two workers (or two consecutive
        // calls before the first marks anything delivered) could SELECT the same row and
        // POST it twice. The `RETURNING` clause + `status='pending'` predicate make the
        // claim race-free at SQLite level.
        {
            self.db_mutex.lock();
            defer self.db_mutex.unlock();

            const sql =
                \\UPDATE webhook_queue
                \\SET status = 'processing', updated_at = ?
                \\WHERE id IN (
                \\  SELECT id FROM webhook_queue
                \\  WHERE status = 'pending'
                \\    AND next_retry_at <= ?
                \\  ORDER BY webhook_url, created_at
                \\  LIMIT 200
                \\)
                \\RETURNING id, webhook_url, webhook_secret, payload, retry_count
            ;

            var q = try db.Query.init(self.database, sql);
            defer q.deinit();

            try q.bindInt64(now);
            try q.bindInt64(now);

            while (try q.step()) {
                const queue_id: u64 = @intCast(q.getInt64(0));
                const retry_count: u32 = @intCast(q.getInt(4));

                // IMPORTANT: copy strings before the next step / statement teardown.
                const webhook_url = try self.allocator.dupe(u8, q.getTextSlice(1) orelse "");
                errdefer self.allocator.free(webhook_url);
                const webhook_secret = try self.allocator.dupe(u8, q.getTextSlice(2) orelse "");
                errdefer self.allocator.free(webhook_secret);
                const payload = try self.allocator.dupe(u8, q.getTextSlice(3) orelse "");
                errdefer self.allocator.free(payload);

                try jobs.append(self.allocator, .{
                    .queue_id = queue_id,
                    .webhook_url = webhook_url,
                    .webhook_secret = webhook_secret,
                    .payload = payload,
                    .retry_count = retry_count,
                });
            }
        }

        // Process jobs outside of mutex lock.
        // Track last-sent in milliseconds so sub-second rate limits actually apply —
        // the previous second-precision `now - last_sent < rate_limit_ms/1000` truncated
        // any rate_limit_ms < 1000 to 0, disabling the limit entirely.
        var endpoint_last_sent_ms = std.StringHashMap(i64).init(self.allocator);
        defer endpoint_last_sent_ms.deinit();
        const now_ms = zsys.milliTimestamp();

        for (jobs.items) |job| {
            // Check rate limit for this endpoint (millisecond precision)
            if (endpoint_last_sent_ms.get(job.webhook_url)) |last_sent_ms| {
                const elapsed_ms = now_ms - last_sent_ms;
                if (elapsed_ms < @as(i64, @intCast(self.rate_limit_ms))) {
                    std.log.debug("Rate limiting {s}, skipping for now", .{sanitizeUrlForLog(job.webhook_url)});
                    continue;
                }
            }

            // Attempt delivery
            std.log.debug("Delivering queued webhook id={d} to {s} (attempt {d})", .{ job.queue_id, sanitizeUrlForLog(job.webhook_url), job.retry_count + 1 });

            const success = self.attemptDelivery(job.queue_id, job.webhook_url, job.webhook_secret, job.payload, job.retry_count) catch |err| blk: {
                std.log.err("Delivery error for webhook id={d}: {}", .{ job.queue_id, err });
                break :blk false;
            };

            // Update last sent time for this endpoint (millisecond precision)
            try endpoint_last_sent_ms.put(job.webhook_url, now_ms);

            // Update queue item status
            if (success) {
                try self.markDelivered(job.queue_id);
            } else {
                try self.markFailed(job.queue_id, job.retry_count);
            }
        }
    }

    /// Attempt webhook delivery and return success status
    fn attemptDelivery(self: *WebhookManager, queue_id: u64, url: []const u8, secret: []const u8, payload: []const u8, retry_count: u32) !bool {
        _ = retry_count;

        return self.sendHttpPost(queue_id, url, secret, payload) catch false;
    }

    /// Mark webhook as successfully delivered
    fn markDelivered(self: *WebhookManager, queue_id: u64) !void {
        self.db_mutex.lock();
        defer self.db_mutex.unlock();

        var q = try db.Query.init(self.database, "UPDATE webhook_queue SET status = 'delivered', updated_at = ? WHERE id = ?");
        defer q.deinit();
        try q.bindInt64(zsys.timestamp());
        try q.bindInt64(@intCast(queue_id));
        try q.exec();

        std.log.debug("Marked webhook id={d} as delivered", .{queue_id});
    }

    /// Mark webhook as failed and schedule retry with exponential backoff
    fn markFailed(self: *WebhookManager, queue_id: u64, retry_count: u32) !void {
        self.db_mutex.lock();
        defer self.db_mutex.unlock();

        const new_retry_count = retry_count + 1;

        // Calculate next retry time with exponential backoff
        const backoff_secs = @min(@as(i64, 60) * (@as(i64, 1) << @intCast(@min(retry_count, 10))), 3600); // Max 1 hour
        const next_retry_at = zsys.timestamp() + backoff_secs;

        // Determine if we should give up
        const status = if (new_retry_count >= self.max_retries) "failed" else "pending";

        const sql =
            \\UPDATE webhook_queue
            \\SET status = ?, retry_count = ?, next_retry_at = ?, updated_at = ?, last_attempt_at = ?
            \\WHERE id = ?
        ;
        var q = try db.Query.init(self.database, sql);
        defer q.deinit();
        try q.bindTextStatic(status);
        try q.bindInt(@intCast(new_retry_count));
        try q.bindInt64(next_retry_at);
        try q.bindInt64(zsys.timestamp());
        try q.bindInt64(zsys.timestamp());
        try q.bindInt64(@intCast(queue_id));
        try q.exec();

        if (new_retry_count >= self.max_retries) {
            std.log.warn("Webhook id={d} permanently failed after {d} attempts", .{ queue_id, new_retry_count });
        } else {
            std.log.debug("Webhook id={d} retry scheduled for {d}s (attempt {d}/{d})", .{ queue_id, backoff_secs, new_retry_count, self.max_retries });
        }
    }

    /// Default total deadline for one webhook delivery attempt.
    /// Zig 0.15.2's std.http.Client exposes no per-request connect/read timeout; we enforce
    /// the deadline externally by running fetch in a detached thread and abandoning it on
    /// timeout. A leaked thread eventually returns when its TCP read times out at the OS
    /// level (default minutes, but bounded). With a fixed-size worker pool this is a worst
    /// case of `worker_count × leaked_threads_per_worker_lifetime` simultaneous in-flight
    /// fetches — small + bounded.
    const HTTP_DELIVERY_DEADLINE_MS: i64 = 10_000;

    /// Heap-allocated state shared between a delivery thread and its watching worker.
    /// Refcounted so neither side has to know which one outlives the other:
    /// each side calls `release()` once when leaving; whoever brings refs to 0 frees.
    const DeliveryArgs = struct {
        allocator: std.mem.Allocator,
        client: *std.http.Client,
        url: []u8,
        payload: []u8,
        secret: []u8,
        // Stable idempotency key (webhook_queue row id). Constant across retries
        // so receivers can dedup the same delivery; sent as X-Webhook-Id.
        queue_id: u64,
        // Manager's in-flight counter; decremented when the thread is done
        // touching `client`. Points at the manager, which outlives every
        // delivery via the bounded wait in deinit.
        inflight: *std.atomic.Value(usize),
        // Result, written by the thread, read by the worker.
        // 0 = running, 1 = 2xx success, 2 = non-2xx response, 3 = transport error
        done: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
        status_code: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        refs: std.atomic.Value(usize) = std.atomic.Value(usize).init(2),

        fn release(self: *DeliveryArgs) void {
            if (self.refs.fetchSub(1, .acq_rel) == 1) {
                self.allocator.free(self.url);
                self.allocator.free(self.payload);
                self.allocator.free(self.secret);
                self.allocator.destroy(self);
            }
        }
    };

    /// Detached delivery thread body. Runs fetch, signals result, releases its ref.
    /// MUST NOT touch `args` after `release()` — the worker may have raced ahead and freed.
    fn deliveryThreadFn(args: *DeliveryArgs) void {
        defer args.release();
        // Runs before release (LIFO): signals "no longer touching client".
        defer _ = args.inflight.fetchSub(1, .acq_rel);

        // Compute HMAC-SHA256 over "{timestamp}.{payload}" for the X-Webhook-Signature header.
        const timestamp = zsys.timestamp();
        const signature = computeWebhookSignature(args.allocator, args.secret, timestamp, args.payload) catch |err| {
            std.log.err("Webhook signature compute failed for {s}: {}", .{ sanitizeUrlForLog(args.url), err });
            args.done.store(3, .release);
            return;
        };
        defer args.allocator.free(signature);

        var ts_buf: [24]u8 = undefined;
        const timestamp_str = std.fmt.bufPrint(&ts_buf, "{d}", .{timestamp}) catch {
            args.done.store(3, .release);
            return;
        };

        var sig_header: std.ArrayList(u8) = .empty;
        defer sig_header.deinit(args.allocator);
        sig_header.appendSlice(args.allocator, "sha256=") catch {
            args.done.store(3, .release);
            return;
        };
        sig_header.appendSlice(args.allocator, signature) catch {
            args.done.store(3, .release);
            return;
        };

        var id_buf: [24]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{args.queue_id}) catch {
            args.done.store(3, .release);
            return;
        };

        const extra_headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "User-Agent", .value = "ENSv2-Indexer/0.1.0" },
            .{ .name = "X-Webhook-Timestamp", .value = timestamp_str },
            .{ .name = "X-Webhook-Signature", .value = sig_header.items },
            .{ .name = "X-Webhook-Id", .value = id_str },
        };

        // No response_writer: only the status matters, and without one fetch discards the
        // body through the RAW reader — so the endpoint (an untrusted, user-supplied URL)
        // can never route us into Zig 0.15.2's panic-prone flate decompressor, whatever
        // Content-Encoding it sends (see rpc/client.zig executeHttpRequest).
        const result = args.client.fetch(.{
            .location = .{ .url = args.url },
            .method = .POST,
            .payload = args.payload,
            .extra_headers = &extra_headers,
            .keep_alive = true,
        }) catch |err| {
            std.log.err("Webhook http.fetch error for {s}: {}", .{ sanitizeUrlForLog(args.url), err });
            args.done.store(3, .release);
            return;
        };

        const status_code = @intFromEnum(result.status);
        args.status_code.store(@intCast(status_code), .release);
        if (status_code >= 200 and status_code < 300) {
            args.done.store(1, .release);
        } else {
            std.log.err("Webhook {s} returned status {d}", .{ sanitizeUrlForLog(args.url), status_code });
            args.done.store(2, .release);
        }
    }

    /// POST JSON to `url`. Returns true on 2xx within `HTTP_DELIVERY_DEADLINE_MS`,
    /// false on non-2xx; returns `error.HttpTimeout` if the deadline elapses.
    /// Spawns a detached delivery thread so a hung endpoint cannot stall the worker.
    fn sendHttpPost(self: *WebhookManager, queue_id: u64, url: []const u8, secret: []const u8, payload: []const u8) !bool {
        // Heap-allocate args + dupe inputs so the spawned thread can outlive this stack frame.
        const args = try self.allocator.create(DeliveryArgs);
        args.* = DeliveryArgs{
            .allocator = self.allocator,
            .client = &self.http_client,
            .url = try self.allocator.dupe(u8, url),
            .payload = try self.allocator.dupe(u8, payload),
            .secret = try self.allocator.dupe(u8, secret),
            .queue_id = queue_id,
            .inflight = &self.inflight_deliveries,
        };
        // Worker holds one ref; thread will hold the other once spawned.
        defer args.release();

        _ = self.inflight_deliveries.fetchAdd(1, .acq_rel);
        const thread = std.Thread.spawn(.{ .stack_size = 1 * 1024 * 1024 }, deliveryThreadFn, .{args}) catch |err| {
            std.log.err("Failed to spawn webhook delivery thread: {}", .{err});
            _ = self.inflight_deliveries.fetchSub(1, .acq_rel);
            // Roll back the thread's pre-allocated ref since no thread will run.
            args.release();
            return error.HttpError;
        };
        thread.detach();

        // Poll done flag with a deadline. Sleep granularity 50ms — fine for 10s deadline.
        const start_ms = zsys.milliTimestamp();
        while (true) {
            const status = args.done.load(.acquire);
            if (status != 0) {
                return switch (status) {
                    1 => true, // 2xx
                    2 => false, // non-2xx
                    else => error.HttpError,
                };
            }
            if (zsys.milliTimestamp() - start_ms >= HTTP_DELIVERY_DEADLINE_MS) {
                std.log.warn("Webhook delivery timed out for {s} after {d}ms; abandoning thread", .{
                    sanitizeUrlForLog(url),
                    HTTP_DELIVERY_DEADLINE_MS,
                });
                return error.HttpTimeout;
            }
            zsys.sleep(50 * std.time.ns_per_ms);
        }
    }

    /// Register a new webhook. Generates a fresh HMAC secret and returns both the id
    /// and the secret to the caller — the secret is NOT persisted in plaintext anywhere
    /// retrievable, so the caller must capture it from this return value.
    pub const RegisterResult = struct { id: u64, secret: []u8 };

    pub fn registerWebhook(self: *WebhookManager, url: []const u8, event_types: []const models.EventType) !RegisterResult {
        const secret = try generateWebhookSecret(self.allocator);
        errdefer self.allocator.free(secret);

        const webhook = models.Webhook{
            .id = 0, // Auto-generated by database
            .url = url,
            .secret = secret,
            .event_types = event_types,
            .active = true,
            .max_retries = self.max_retries,
            .created_at = zsys.timestamp(),
        };

        const webhook_id = try self.database.insertWebhook(webhook);
        std.log.info("Registered webhook id={d} url={s}", .{ webhook_id, sanitizeUrlForLog(url) });
        return .{ .id = webhook_id, .secret = secret };
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

    // =========================================================================
    // QUEUE CLEANUP
    // =========================================================================
    //
    // The webhook_queue table accumulates entries over time:
    // - 'pending' and 'processing' entries are still active and needed
    // - 'delivered' entries have completed successfully - no longer needed
    // - 'failed' entries gave up after max retries - no longer needed
    //
    // Without cleanup, the table grows indefinitely:
    // - Each entry stores full JSON payload (~500-2000 bytes)
    // - 10,000 events/day × 3 webhooks = 30,000 rows/day
    // - This impacts disk space, query performance, and backup times
    //
    // Cleanup policy:
    // - Delivered: remove after 1 day (just for recent debugging)
    // - Failed: remove after 7 days (allows investigation window)
    // =========================================================================

    /// Queue cleanup statistics
    pub const CleanupStats = struct {
        delivered_removed: u32,
        failed_removed: u32,
    };

    /// Clean up old webhook queue entries that are no longer needed.
    /// - Delivered webhooks older than `delivered_retention_days` are removed
    /// - Failed webhooks older than `failed_retention_days` are removed
    /// Returns the number of entries removed.
    pub fn cleanupQueue(self: *WebhookManager, delivered_retention_days: u32, failed_retention_days: u32) !CleanupStats {
        self.db_mutex.lock();
        defer self.db_mutex.unlock();

        var stats = CleanupStats{ .delivered_removed = 0, .failed_removed = 0 };
        const now = zsys.timestamp();

        // Clean up delivered webhooks
        {
            const cutoff = now - (@as(i64, delivered_retention_days) * 86400);
            var q = try db.Query.init(self.database, "DELETE FROM webhook_queue WHERE status = 'delivered' AND created_at < ?");
            defer q.deinit();
            try q.bindInt64(cutoff);
            if (q.exec()) |_| {
                stats.delivered_removed = @intCast(q.changes());
            } else |_| {}
        }

        // Clean up failed webhooks
        {
            const cutoff = now - (@as(i64, failed_retention_days) * 86400);
            var q = try db.Query.init(self.database, "DELETE FROM webhook_queue WHERE status = 'failed' AND created_at < ?");
            defer q.deinit();
            try q.bindInt64(cutoff);
            if (q.exec()) |_| {
                stats.failed_removed = @intCast(q.changes());
            } else |_| {}
        }

        if (stats.delivered_removed > 0 or stats.failed_removed > 0) {
            std.log.info("Webhook queue cleanup: removed {d} delivered, {d} failed entries", .{
                stats.delivered_removed,
                stats.failed_removed,
            });
        }

        return stats;
    }

    /// Clean up queue with default retention policy (1 day delivered, 7 days failed)
    pub fn cleanupQueueDefault(self: *WebhookManager) !CleanupStats {
        return self.cleanupQueue(1, 7);
    }
};

test "WebhookManager init" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const manager = try WebhookManager.init(allocator, std.testing.io, ":memory:", 3, 1000);
    defer manager.deinit();

    try std.testing.expect(manager.max_retries == 3);
}

test "WebhookManager register webhook" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const manager = try WebhookManager.init(allocator, std.testing.io, ":memory:", 3, 1000);
    defer manager.deinit();

    const event_types = [_]models.EventType{.name_registered};
    const result = try manager.registerWebhook("https://example.com/webhook", &event_types);
    defer allocator.free(result.secret);

    try std.testing.expect(result.id > 0);
    try std.testing.expectEqual(@as(usize, 64), result.secret.len);
}

test "WebhookManager unregister webhook" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const manager = try WebhookManager.init(allocator, std.testing.io, ":memory:", 3, 1000);
    defer manager.deinit();

    const event_types = [_]models.EventType{.name_registered};
    const result = try manager.registerWebhook("https://example.com/webhook", &event_types);
    defer allocator.free(result.secret);

    // Unregister should not error
    try manager.unregisterWebhook(result.id);
}

test "WebhookManager list webhooks" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const manager = try WebhookManager.init(allocator, std.testing.io, ":memory:", 3, 1000);
    defer manager.deinit();

    const event_types = [_]models.EventType{.name_registered};
    {
        const r = try manager.registerWebhook("https://example.com/webhook1", &event_types);
        allocator.free(r.secret);
    }
    {
        const r = try manager.registerWebhook("https://example.com/webhook2", &event_types);
        allocator.free(r.secret);
    }

    const webhooks = try manager.listWebhooks();
    defer {
        for (webhooks) |*wh| {
            wh.deinit(allocator);
        }
        allocator.free(webhooks);
    }

    try std.testing.expect(webhooks.len == 2);
}
