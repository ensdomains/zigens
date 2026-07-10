const std = @import("std");
const zsys = @import("../../utils/system.zig");

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
    }

    /// Record a failed query (error during execution)
    pub fn recordError(self: *Metrics) void {
        if (!self.enabled) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        self.total_queries += 1;
        self.failed_queries += 1;
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

        return std.fmt.allocPrint(allocator,
            \\{{"enabled":{s},"total_queries":{d},"successful_queries":{d},"failed_queries":{d},"rejected_queries":{d},"primary_verified":{d},"primary_mismatch":{d},"primary_unverified":{d},"avg_duration_us":{d},"min_duration_us":{d},"max_duration_us":{d},"avg_depth":{d},"max_depth":{d},"avg_cost":{d},"max_cost":{d},"uptime_seconds":{d}}}
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
    uptime_seconds: u64,
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
