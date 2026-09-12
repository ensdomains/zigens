const std = @import("std");
const zsys = @import("../../utils/system.zig");

/// Upper bounds (microseconds) of the graphql_query_duration_seconds histogram
/// buckets; the trailing +Inf bucket is implicit.
pub const DURATION_BUCKET_BOUNDS_US = [_]u64{
    5_000,     10_000,    25_000,    50_000,     100_000,    250_000,    500_000,
    1_000_000, 2_500_000, 5_000_000, 10_000_000, 30_000_000, 60_000_000,
};

/// Prometheus `le` labels (seconds) matching DURATION_BUCKET_BOUNDS_US.
pub const DURATION_BUCKET_LABELS = [_][]const u8{
    "0.005", "0.01", "0.025", "0.05", "0.1", "0.25", "0.5",
    "1",     "2.5",  "5",     "10",   "30",  "60",
};

/// Bucket slots including the +Inf bucket (last index).
pub const DURATION_BUCKET_COUNT = DURATION_BUCKET_BOUNDS_US.len + 1;

/// GraphQL Metrics Tracker
/// Thread-safe metrics collection for GraphQL queries
/// Zero overhead when disabled
pub const Metrics = struct {
    allocator: std.mem.Allocator,
    enabled: bool,
    mutex: zsys.Mutex,

    // Query counters
    total_queries: u64,
    successful_queries: u64,
    failed_queries: u64,
    rejected_queries: u64, // Rejected due to complexity

    // Primary-name forward-verification outcomes (see resolve/primary.zig).
    primary_verified: u64,
    primary_mismatch: u64,
    primary_unverified: u64,

    // Timing stats (in microseconds)
    total_duration_us: u64,
    min_duration_us: u64,
    max_duration_us: u64,

    // Duration histogram over successful AND failed executions. Bucket counts
    // are cumulative (Prometheus `le` semantics); the last slot is +Inf.
    duration_buckets: [DURATION_BUCKET_COUNT]u64,
    duration_sum_us: u64,
    duration_count: u64,

    // Complexity stats
    total_depth: u64,
    max_depth: u32,
    total_cost: u64,
    max_cost: u32,

    // Start time for uptime
    start_time: i64,

    pub fn init(allocator: std.mem.Allocator, enabled: bool) Metrics {
        return .{
            .allocator = allocator,
            .enabled = enabled,
            .mutex = .{},
            .total_queries = 0,
            .successful_queries = 0,
            .failed_queries = 0,
            .rejected_queries = 0,
            .primary_verified = 0,
            .primary_mismatch = 0,
            .primary_unverified = 0,
            .total_duration_us = 0,
            .min_duration_us = std.math.maxInt(u64),
            .max_duration_us = 0,
            .duration_buckets = [_]u64{0} ** DURATION_BUCKET_COUNT,
            .duration_sum_us = 0,
            .duration_count = 0,
            .total_depth = 0,
            .max_depth = 0,
            .total_cost = 0,
            .max_cost = 0,
            .start_time = zsys.timestamp(),
        };
    }

    pub fn deinit(self: *Metrics) void {
        _ = self;
        // Nothing to clean up currently
    }

    /// Record a successful query execution
    pub fn recordQuery(self: *Metrics, duration_us: u64, depth: u32, cost: u32) void {
        if (!self.enabled) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        self.total_queries += 1;
        self.successful_queries += 1;
        self.total_duration_us += duration_us;

        if (duration_us < self.min_duration_us) {
            self.min_duration_us = duration_us;
        }
        if (duration_us > self.max_duration_us) {
            self.max_duration_us = duration_us;
        }

        self.total_depth += depth;
        if (depth > self.max_depth) {
            self.max_depth = depth;
        }

        self.total_cost += cost;
        if (cost > self.max_cost) {
            self.max_cost = cost;
        }

        self.addDurationSample(duration_us);
    }

    /// Record a failed query (error during execution)
    pub fn recordError(self: *Metrics) void {
        if (!self.enabled) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        self.total_queries += 1;
        self.failed_queries += 1;
    }

    /// Record a failed query that ran long enough to time (execution errors),
    /// so the duration histogram covers failures as well as successes.
    pub fn recordErrorWithDuration(self: *Metrics, duration_us: u64) void {
        if (!self.enabled) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        self.total_queries += 1;
        self.failed_queries += 1;
        self.addDurationSample(duration_us);
    }

    /// Add one execution duration to the histogram without touching the
    /// success/failure counters.
    pub fn recordDuration(self: *Metrics, duration_us: u64) void {
        if (!self.enabled) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        self.addDurationSample(duration_us);
    }

    /// Histogram update shared by the record* entry points; the caller holds the mutex.
    fn addDurationSample(self: *Metrics, duration_us: u64) void {
        for (DURATION_BUCKET_BOUNDS_US, 0..) |bound, i| {
            if (duration_us <= bound) self.duration_buckets[i] += 1;
        }
        self.duration_buckets[DURATION_BUCKET_COUNT - 1] += 1;
        self.duration_sum_us += duration_us;
        self.duration_count += 1;
    }

    /// Record a rejected query (complexity limit exceeded)
    pub fn recordRejection(self: *Metrics, depth: u32, cost: u32) void {
        if (!self.enabled) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        self.total_queries += 1;
        self.rejected_queries += 1;

        // Still track the complexity of rejected queries
        if (depth > self.max_depth) {
            self.max_depth = depth;
        }
        if (cost > self.max_cost) {
            self.max_cost = cost;
        }
    }

    /// Outcome of a primary-name forward verification. Mirrors resolve/primary.zig
    /// `Verdict` without importing it, so the metrics module stays dependency-free.
    pub const PrimaryOutcome = enum { verified, mismatch, unverified };

    /// Record a primary-name forward-verification outcome.
    pub fn recordPrimaryVerification(self: *Metrics, outcome: PrimaryOutcome) void {
        if (!self.enabled) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        switch (outcome) {
            .verified => self.primary_verified += 1,
            .mismatch => self.primary_mismatch += 1,
            .unverified => self.primary_unverified += 1,
        }
    }

    /// Get snapshot of current metrics (thread-safe)
    pub fn getSnapshot(self: *Metrics) MetricsSnapshot {
        if (!self.enabled) {
            return MetricsSnapshot{
                .enabled = false,
                .total_queries = 0,
                .successful_queries = 0,
                .failed_queries = 0,
                .rejected_queries = 0,
                .primary_verified = 0,
                .primary_mismatch = 0,
                .primary_unverified = 0,
                .avg_duration_us = 0,
                .min_duration_us = 0,
                .max_duration_us = 0,
                .avg_depth = 0,
                .max_depth = 0,
                .avg_cost = 0,
                .max_cost = 0,
                .duration_buckets = [_]u64{0} ** DURATION_BUCKET_COUNT,
                .duration_sum_us = 0,
                .duration_count = 0,
                .uptime_seconds = 0,
            };
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        const avg_duration = if (self.successful_queries > 0)
            @divTrunc(self.total_duration_us, self.successful_queries)
        else
            0;

        const avg_depth = if (self.successful_queries > 0)
            @as(u32, @intCast(@divTrunc(self.total_depth, self.successful_queries)))
        else
            0;

        const avg_cost = if (self.successful_queries > 0)
            @as(u32, @intCast(@divTrunc(self.total_cost, self.successful_queries)))
        else
            0;

        const now = zsys.timestamp();
        const uptime = @as(u64, @intCast(now - self.start_time));

        return MetricsSnapshot{
            .enabled = true,
            .total_queries = self.total_queries,
            .successful_queries = self.successful_queries,
            .failed_queries = self.failed_queries,
            .rejected_queries = self.rejected_queries,
            .primary_verified = self.primary_verified,
            .primary_mismatch = self.primary_mismatch,
            .primary_unverified = self.primary_unverified,
            .avg_duration_us = avg_duration,
            .min_duration_us = if (self.min_duration_us == std.math.maxInt(u64)) 0 else self.min_duration_us,
            .max_duration_us = self.max_duration_us,
            .avg_depth = avg_depth,
            .max_depth = self.max_depth,
            .avg_cost = avg_cost,
            .max_cost = self.max_cost,
            .duration_buckets = self.duration_buckets,
            .duration_sum_us = self.duration_sum_us,
            .duration_count = self.duration_count,
            .uptime_seconds = uptime,
        };
    }

    /// Format metrics as Prometheus exposition format
    pub fn formatPrometheus(self: *Metrics, allocator: std.mem.Allocator) ![]u8 {
        const snapshot = self.getSnapshot();

        if (!snapshot.enabled) {
            return try allocator.dupe(u8, "# Metrics disabled\n");
        }

        var buffer: std.Io.Writer.Allocating = .init(allocator);
        errdefer buffer.deinit();

        const writer = &buffer.writer;

        try writer.writeAll("# HELP graphql_queries_total Total number of GraphQL queries\n");
        try writer.writeAll("# TYPE graphql_queries_total counter\n");
        try writer.print("graphql_queries_total {d}\n", .{snapshot.total_queries});

        try writer.writeAll("# HELP graphql_queries_successful Number of successful queries\n");
        try writer.writeAll("# TYPE graphql_queries_successful counter\n");
        try writer.print("graphql_queries_successful {d}\n", .{snapshot.successful_queries});

        try writer.writeAll("# HELP graphql_queries_failed Number of failed queries\n");
        try writer.writeAll("# TYPE graphql_queries_failed counter\n");
        try writer.print("graphql_queries_failed {d}\n", .{snapshot.failed_queries});

        try writer.writeAll("# HELP graphql_queries_rejected Number of queries rejected due to complexity\n");
        try writer.writeAll("# TYPE graphql_queries_rejected counter\n");
        try writer.print("graphql_queries_rejected {d}\n", .{snapshot.rejected_queries});

        try writer.writeAll("# HELP primary_verifications_verified Primary-name claims that forward-verified to the same address\n");
        try writer.writeAll("# TYPE primary_verifications_verified counter\n");
        try writer.print("primary_verifications_verified {d}\n", .{snapshot.primary_verified});

        try writer.writeAll("# HELP primary_verifications_mismatch Primary-name claims that forward-resolved to a different address\n");
        try writer.writeAll("# TYPE primary_verifications_mismatch counter\n");
        try writer.print("primary_verifications_mismatch {d}\n", .{snapshot.primary_mismatch});

        try writer.writeAll("# HELP primary_verifications_unverified Primary-name claims with no usable forward evidence\n");
        try writer.writeAll("# TYPE primary_verifications_unverified counter\n");
        try writer.print("primary_verifications_unverified {d}\n", .{snapshot.primary_unverified});

        try writer.writeAll("# HELP graphql_query_duration_microseconds_avg Average query duration\n");
        try writer.writeAll("# TYPE graphql_query_duration_microseconds_avg gauge\n");
        try writer.print("graphql_query_duration_microseconds_avg {d}\n", .{snapshot.avg_duration_us});

        try writer.writeAll("# HELP graphql_query_duration_microseconds_min Minimum query duration\n");
        try writer.writeAll("# TYPE graphql_query_duration_microseconds_min gauge\n");
        try writer.print("graphql_query_duration_microseconds_min {d}\n", .{snapshot.min_duration_us});

        try writer.writeAll("# HELP graphql_query_duration_microseconds_max Maximum query duration\n");
        try writer.writeAll("# TYPE graphql_query_duration_microseconds_max gauge\n");
        try writer.print("graphql_query_duration_microseconds_max {d}\n", .{snapshot.max_duration_us});

        try writer.writeAll("# HELP graphql_query_duration_seconds Query execution duration, successful and failed executions\n");
        try writer.writeAll("# TYPE graphql_query_duration_seconds histogram\n");
        for (DURATION_BUCKET_LABELS, 0..) |label, i| {
            try writer.print("graphql_query_duration_seconds_bucket{{le=\"{s}\"}} {d}\n", .{ label, snapshot.duration_buckets[i] });
        }
        try writer.print("graphql_query_duration_seconds_bucket{{le=\"+Inf\"}} {d}\n", .{snapshot.duration_buckets[DURATION_BUCKET_COUNT - 1]});
        try writer.print("graphql_query_duration_seconds_sum {d:.6}\n", .{snapshot.durationSumSeconds()});
        try writer.print("graphql_query_duration_seconds_count {d}\n", .{snapshot.duration_count});

        try writer.writeAll("# HELP graphql_query_depth_avg Average query depth\n");
        try writer.writeAll("# TYPE graphql_query_depth_avg gauge\n");
        try writer.print("graphql_query_depth_avg {d}\n", .{snapshot.avg_depth});

        try writer.writeAll("# HELP graphql_query_depth_max Maximum query depth seen\n");
        try writer.writeAll("# TYPE graphql_query_depth_max gauge\n");
        try writer.print("graphql_query_depth_max {d}\n", .{snapshot.max_depth});

        try writer.writeAll("# HELP graphql_query_cost_avg Average query cost\n");
        try writer.writeAll("# TYPE graphql_query_cost_avg gauge\n");
        try writer.print("graphql_query_cost_avg {d}\n", .{snapshot.avg_cost});

        try writer.writeAll("# HELP graphql_query_cost_max Maximum query cost seen\n");
        try writer.writeAll("# TYPE graphql_query_cost_max gauge\n");
        try writer.print("graphql_query_cost_max {d}\n", .{snapshot.max_cost});

        try writer.writeAll("# HELP api_uptime_seconds Time since API server started\n");
        try writer.writeAll("# TYPE api_uptime_seconds counter\n");
        try writer.print("api_uptime_seconds {d}\n", .{snapshot.uptime_seconds});

        return buffer.toOwnedSlice();
    }

    /// Format metrics as JSON
    pub fn formatJson(self: *Metrics, allocator: std.mem.Allocator) ![]u8 {
        const snapshot = self.getSnapshot();

        var buffer: std.Io.Writer.Allocating = .init(allocator);
        errdefer buffer.deinit();

        const writer = &buffer.writer;

        try writer.print(
            \\{{"enabled":{s},"total_queries":{d},"successful_queries":{d},"failed_queries":{d},"rejected_queries":{d},"primary_verified":{d},"primary_mismatch":{d},"primary_unverified":{d},"avg_duration_us":{d},"min_duration_us":{d},"max_duration_us":{d},"avg_depth":{d},"max_depth":{d},"avg_cost":{d},"max_cost":{d},"uptime_seconds":{d}
        , .{
            if (snapshot.enabled) "true" else "false",
            snapshot.total_queries,
            snapshot.successful_queries,
            snapshot.failed_queries,
            snapshot.rejected_queries,
            snapshot.primary_verified,
            snapshot.primary_mismatch,
            snapshot.primary_unverified,
            snapshot.avg_duration_us,
            snapshot.min_duration_us,
            snapshot.max_duration_us,
            snapshot.avg_depth,
            snapshot.max_depth,
            snapshot.avg_cost,
            snapshot.max_cost,
            snapshot.uptime_seconds,
        });

        try writer.writeAll(",\"duration_histogram\":{\"buckets\":{");
        for (DURATION_BUCKET_LABELS, 0..) |label, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.print("\"{s}\":{d}", .{ label, snapshot.duration_buckets[i] });
        }
        try writer.print(",\"+Inf\":{d}}}", .{snapshot.duration_buckets[DURATION_BUCKET_COUNT - 1]});
        try writer.print(",\"sum_seconds\":{d:.6},\"count\":{d}}}}}", .{ snapshot.durationSumSeconds(), snapshot.duration_count });

        return buffer.toOwnedSlice();
    }
};

/// Immutable snapshot of metrics at a point in time
pub const MetricsSnapshot = struct {
    enabled: bool,
    total_queries: u64,
    successful_queries: u64,
    failed_queries: u64,
    rejected_queries: u64,
    primary_verified: u64,
    primary_mismatch: u64,
    primary_unverified: u64,
    avg_duration_us: u64,
    min_duration_us: u64,
    max_duration_us: u64,
    avg_depth: u32,
    max_depth: u32,
    avg_cost: u32,
    max_cost: u32,
    duration_buckets: [DURATION_BUCKET_COUNT]u64,
    duration_sum_us: u64,
    duration_count: u64,
    uptime_seconds: u64,

    pub fn durationSumSeconds(self: *const MetricsSnapshot) f64 {
        return @as(f64, @floatFromInt(self.duration_sum_us)) / std.time.us_per_s;
    }
};

/// Timer for measuring query execution time
pub const QueryTimer = struct {
    start_time: i128,

    pub fn start() QueryTimer {
        return .{
            .start_time = zsys.nanoTimestamp(),
        };
    }

    pub fn elapsedMicroseconds(self: *const QueryTimer) u64 {
        const now = zsys.nanoTimestamp();
        const elapsed_ns = now - self.start_time;
        return @intCast(@divTrunc(elapsed_ns, 1000));
    }
};

test "Metrics init and basic recording" {
    const allocator = std.testing.allocator;

    var metrics = Metrics.init(allocator, true);
    defer metrics.deinit();

    try std.testing.expect(metrics.enabled);
    try std.testing.expect(metrics.total_queries == 0);

    metrics.recordQuery(1000, 3, 10);
    try std.testing.expect(metrics.total_queries == 1);
    try std.testing.expect(metrics.successful_queries == 1);

    metrics.recordError();
    try std.testing.expect(metrics.total_queries == 2);
    try std.testing.expect(metrics.failed_queries == 1);

    metrics.recordRejection(5, 100);
    try std.testing.expect(metrics.total_queries == 3);
    try std.testing.expect(metrics.rejected_queries == 1);
}

test "Metrics primary verification counters" {
    const allocator = std.testing.allocator;

    var metrics = Metrics.init(allocator, true);
    defer metrics.deinit();

    metrics.recordPrimaryVerification(.verified);
    metrics.recordPrimaryVerification(.verified);
    metrics.recordPrimaryVerification(.mismatch);
    metrics.recordPrimaryVerification(.unverified);

    const snapshot = metrics.getSnapshot();
    try std.testing.expect(snapshot.primary_verified == 2);
    try std.testing.expect(snapshot.primary_mismatch == 1);
    try std.testing.expect(snapshot.primary_unverified == 1);

    const output = try metrics.formatPrometheus(allocator);
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "primary_verifications_verified 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "primary_verifications_mismatch 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "primary_verifications_unverified 1") != null);
}

test "Metrics primary verification is disabled-safe" {
    const allocator = std.testing.allocator;
    var metrics = Metrics.init(allocator, false);
    defer metrics.deinit();
    metrics.recordPrimaryVerification(.verified);
    try std.testing.expect(metrics.primary_verified == 0);
}

test "Metrics disabled has zero overhead" {
    const allocator = std.testing.allocator;

    var metrics = Metrics.init(allocator, false);
    defer metrics.deinit();

    try std.testing.expect(!metrics.enabled);

    // Should not record anything
    metrics.recordQuery(1000, 3, 10);
    try std.testing.expect(metrics.total_queries == 0);

    const snapshot = metrics.getSnapshot();
    try std.testing.expect(!snapshot.enabled);
    try std.testing.expect(snapshot.total_queries == 0);
}

test "Metrics snapshot" {
    const allocator = std.testing.allocator;

    var metrics = Metrics.init(allocator, true);
    defer metrics.deinit();

    metrics.recordQuery(1000, 3, 10);
    metrics.recordQuery(2000, 5, 20);

    const snapshot = metrics.getSnapshot();
    try std.testing.expect(snapshot.enabled);
    try std.testing.expect(snapshot.total_queries == 2);
    try std.testing.expect(snapshot.successful_queries == 2);
    try std.testing.expect(snapshot.avg_duration_us == 1500);
    try std.testing.expect(snapshot.min_duration_us == 1000);
    try std.testing.expect(snapshot.max_duration_us == 2000);
    try std.testing.expect(snapshot.avg_depth == 4);
    try std.testing.expect(snapshot.max_depth == 5);
    try std.testing.expect(snapshot.avg_cost == 15);
    try std.testing.expect(snapshot.max_cost == 20);
}

test "QueryTimer" {
    var timer = QueryTimer.start();
    zsys.sleep(1 * std.time.ns_per_ms); // Sleep 1ms
    const elapsed = timer.elapsedMicroseconds();

    // Should be at least 1000 microseconds (1ms), allow some tolerance
    try std.testing.expect(elapsed >= 900);
}

test "Prometheus format when disabled" {
    const allocator = std.testing.allocator;

    var metrics = Metrics.init(allocator, false);
    defer metrics.deinit();

    const output = try metrics.formatPrometheus(allocator);
    defer allocator.free(output);

    try std.testing.expectEqualStrings("# Metrics disabled\n", output);
}

test "Prometheus format when enabled" {
    const allocator = std.testing.allocator;

    var metrics = Metrics.init(allocator, true);
    defer metrics.deinit();

    // Record some metrics
    metrics.recordQuery(1500, 3, 15);
    metrics.recordQuery(2500, 4, 20);
    metrics.recordError();

    const output = try metrics.formatPrometheus(allocator);
    defer allocator.free(output);

    // Verify key metrics are present in output
    try std.testing.expect(std.mem.indexOf(u8, output, "graphql_queries_total 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "graphql_queries_successful 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "graphql_queries_failed 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "graphql_query_duration_microseconds_avg 2000") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "graphql_query_duration_microseconds_min 1500") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "graphql_query_duration_microseconds_max 2500") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "graphql_query_depth_max 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "graphql_query_cost_max 20") != null);
}

test "JSON format output" {
    const allocator = std.testing.allocator;

    var metrics = Metrics.init(allocator, true);
    defer metrics.deinit();

    metrics.recordQuery(1000, 2, 10);

    const output = try metrics.formatJson(allocator);
    defer allocator.free(output);

    // Verify JSON contains expected fields
    try std.testing.expect(std.mem.indexOf(u8, output, "\"enabled\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"total_queries\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"successful_queries\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"avg_duration_us\":1000") != null);
}

test "Metrics rejection tracking" {
    const allocator = std.testing.allocator;

    var metrics = Metrics.init(allocator, true);
    defer metrics.deinit();

    // Record rejected queries with high complexity
    metrics.recordRejection(15, 500);
    metrics.recordRejection(20, 1000);

    const snapshot = metrics.getSnapshot();
    try std.testing.expect(snapshot.total_queries == 2);
    try std.testing.expect(snapshot.rejected_queries == 2);
    try std.testing.expect(snapshot.successful_queries == 0);
    try std.testing.expect(snapshot.max_depth == 20);
    try std.testing.expect(snapshot.max_cost == 1000);
}

test "Metrics mixed query types" {
    const allocator = std.testing.allocator;

    var metrics = Metrics.init(allocator, true);
    defer metrics.deinit();

    // Mix of successful, failed, and rejected queries
    metrics.recordQuery(500, 2, 5);
    metrics.recordError();
    metrics.recordRejection(10, 100);
    metrics.recordQuery(1000, 3, 10);
    metrics.recordError();

    const snapshot = metrics.getSnapshot();
    try std.testing.expect(snapshot.total_queries == 5);
    try std.testing.expect(snapshot.successful_queries == 2);
    try std.testing.expect(snapshot.failed_queries == 2);
    try std.testing.expect(snapshot.rejected_queries == 1);
    try std.testing.expect(snapshot.avg_duration_us == 750); // (500 + 1000) / 2
    try std.testing.expect(snapshot.max_depth == 10);
}

test "Metrics thread safety - concurrent recording" {
    const allocator = std.testing.allocator;

    var metrics = Metrics.init(allocator, true);
    defer metrics.deinit();

    // Create multiple threads that record metrics concurrently
    const thread_count = 4;
    const queries_per_thread = 25;

    var threads: [thread_count]std.Thread = undefined;

    const RecordingContext = struct {
        metrics_ptr: *Metrics,

        fn recordQueries(ctx: @This()) void {
            var i: usize = 0;
            while (i < queries_per_thread) : (i += 1) {
                ctx.metrics_ptr.recordQuery(1000 + i * 100, 2, 10);
            }
        }
    };

    const ctx = RecordingContext{ .metrics_ptr = &metrics };

    // Spawn threads
    var i: usize = 0;
    while (i < thread_count) : (i += 1) {
        threads[i] = try std.Thread.spawn(.{}, RecordingContext.recordQueries, .{ctx});
    }

    // Wait for all threads
    i = 0;
    while (i < thread_count) : (i += 1) {
        threads[i].join();
    }

    const snapshot = metrics.getSnapshot();
    try std.testing.expect(snapshot.total_queries == thread_count * queries_per_thread);
    try std.testing.expect(snapshot.successful_queries == thread_count * queries_per_thread);
}

test "Metrics uptime tracking" {
    const allocator = std.testing.allocator;

    var metrics = Metrics.init(allocator, true);
    defer metrics.deinit();

    zsys.sleep(2 * std.time.ns_per_s); // Sleep 2 seconds

    const snapshot = metrics.getSnapshot();
    // Should be at least 2 seconds, but allow for some variance
    try std.testing.expect(snapshot.uptime_seconds >= 2);
    try std.testing.expect(snapshot.uptime_seconds <= 3);
}

test "Duration histogram: a 0.3s sample lands in le=0.5 and above only" {
    const allocator = std.testing.allocator;

    var metrics = Metrics.init(allocator, true);
    defer metrics.deinit();

    metrics.recordDuration(300_000);

    const snapshot = metrics.getSnapshot();
    for (DURATION_BUCKET_BOUNDS_US, 0..) |bound, i| {
        const expected: u64 = if (bound >= 500_000) 1 else 0;
        try std.testing.expectEqual(expected, snapshot.duration_buckets[i]);
    }
    try std.testing.expectEqual(@as(u64, 0), snapshot.duration_buckets[5]); // le=0.25
    try std.testing.expectEqual(@as(u64, 1), snapshot.duration_buckets[6]); // le=0.5
    try std.testing.expectEqual(@as(u64, 1), snapshot.duration_buckets[DURATION_BUCKET_COUNT - 1]);
    try std.testing.expectEqual(@as(u64, 1), snapshot.duration_count);
    try std.testing.expectEqual(@as(u64, 300_000), snapshot.duration_sum_us);
}

test "Duration histogram: bounds are inclusive and +Inf catches everything" {
    const allocator = std.testing.allocator;

    var metrics = Metrics.init(allocator, true);
    defer metrics.deinit();

    metrics.recordDuration(5_000); // exactly le=0.005
    metrics.recordDuration(120_000_000); // beyond le=60

    const snapshot = metrics.getSnapshot();
    try std.testing.expectEqual(@as(u64, 1), snapshot.duration_buckets[0]);
    try std.testing.expectEqual(@as(u64, 1), snapshot.duration_buckets[DURATION_BUCKET_COUNT - 2]); // le=60
    try std.testing.expectEqual(@as(u64, 2), snapshot.duration_buckets[DURATION_BUCKET_COUNT - 1]);
    try std.testing.expectEqual(@as(u64, 2), snapshot.duration_count);
}

test "Duration histogram: successes and failures both count, sum adds up" {
    const allocator = std.testing.allocator;

    var metrics = Metrics.init(allocator, true);
    defer metrics.deinit();

    metrics.recordQuery(1_500, 3, 15);
    metrics.recordErrorWithDuration(2_500_000);
    metrics.recordError(); // no timing: counters only

    const snapshot = metrics.getSnapshot();
    try std.testing.expectEqual(@as(u64, 3), snapshot.total_queries);
    try std.testing.expectEqual(@as(u64, 1), snapshot.successful_queries);
    try std.testing.expectEqual(@as(u64, 2), snapshot.failed_queries);
    try std.testing.expectEqual(@as(u64, 2), snapshot.duration_count);
    try std.testing.expectEqual(@as(u64, 2_501_500), snapshot.duration_sum_us);
    try std.testing.expectEqual(@as(u64, 1), snapshot.duration_buckets[0]); // le=0.005: the 1.5ms success
    try std.testing.expectEqual(@as(u64, 1), snapshot.duration_buckets[7]); // le=1
    try std.testing.expectEqual(@as(u64, 2), snapshot.duration_buckets[8]); // le=2.5: both
    // The all-time gauges stay success-only, exactly as before.
    try std.testing.expectEqual(@as(u64, 1_500), snapshot.max_duration_us);
    try std.testing.expectEqual(@as(u64, 1_500), snapshot.avg_duration_us);
}

test "Duration histogram: Prometheus exposition lines" {
    const allocator = std.testing.allocator;

    var metrics = Metrics.init(allocator, true);
    defer metrics.deinit();

    metrics.recordQuery(300_000, 2, 10);
    metrics.recordErrorWithDuration(1_000_000);

    const output = try metrics.formatPrometheus(allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "# TYPE graphql_query_duration_seconds histogram\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "graphql_query_duration_seconds_bucket{le=\"0.005\"} 0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "graphql_query_duration_seconds_bucket{le=\"0.25\"} 0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "graphql_query_duration_seconds_bucket{le=\"0.5\"} 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "graphql_query_duration_seconds_bucket{le=\"1\"} 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "graphql_query_duration_seconds_bucket{le=\"60\"} 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "graphql_query_duration_seconds_bucket{le=\"+Inf\"} 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "graphql_query_duration_seconds_sum 1.300000\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "graphql_query_duration_seconds_count 2\n") != null);
    // Pre-existing gauges are untouched by the histogram.
    try std.testing.expect(std.mem.indexOf(u8, output, "graphql_query_duration_microseconds_max 300000\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "graphql_queries_failed 1\n") != null);
}

test "Duration histogram: JSON carries buckets, sum and count" {
    const allocator = std.testing.allocator;

    var metrics = Metrics.init(allocator, true);
    defer metrics.deinit();

    metrics.recordQuery(300_000, 2, 10);

    const output = try metrics.formatJson(allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "\"max_duration_us\":300000") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"duration_histogram\":{\"buckets\":{\"0.005\":0,") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"0.25\":0,\"0.5\":1,") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"+Inf\":1},\"sum_seconds\":0.300000,\"count\":1}}") != null);
    try std.testing.expect(std.mem.endsWith(u8, output, "}}"));

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, output, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("duration_histogram").?.object.get("buckets").? == .object);
}

test "Duration histogram is disabled-safe" {
    const allocator = std.testing.allocator;

    var metrics = Metrics.init(allocator, false);
    defer metrics.deinit();

    metrics.recordDuration(300_000);
    metrics.recordErrorWithDuration(300_000);
    try std.testing.expectEqual(@as(u64, 0), metrics.duration_count);
    try std.testing.expectEqual(@as(u64, 0), metrics.failed_queries);
}
