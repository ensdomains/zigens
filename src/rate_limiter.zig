const std = @import("std");
const zsys = @import("utils/system.zig");

/// 16-byte canonical IP key. IPv4 addresses are stored as IPv4-mapped IPv6
/// (::ffff:<v4>) so a single map type covers both families uniformly.
pub const IpKey = [16]u8;

pub fn ipKeyFromAddress(addr: std.Io.net.IpAddress) IpKey {
    var key: IpKey = std.mem.zeroes(IpKey);
    switch (addr) {
        .ip4 => |ip4| {
            // IPv4-mapped form: ::ffff:<ipv4>
            key[10] = 0xff;
            key[11] = 0xff;
            @memcpy(key[12..16], &ip4.bytes);
        },
        .ip6 => |ip6| @memcpy(&key, &ip6.bytes),
    }
    return key;
}

/// Per-IP token bucket rate limiter. Used by the public API server so that one
/// abusive client can't drain a single global bucket and lock out everyone else.
pub const PerIpRateLimiter = struct {
    allocator: std.mem.Allocator,
    buckets: std.AutoHashMap(IpKey, IpBucket),
    max_tokens: u32,
    refill_rate: u32, // tokens added per second
    max_entries: u32, // hard cap on map size to bound memory
    mutex: zsys.Mutex,
    last_sweep: i64,

    const IpBucket = struct {
        tokens: u32,
        last_refill: i64,
    };

    pub fn init(allocator: std.mem.Allocator, max_tokens: u32, refill_rate: u32, max_entries: u32) PerIpRateLimiter {
        return .{
            .allocator = allocator,
            .buckets = std.AutoHashMap(IpKey, IpBucket).init(allocator),
            .max_tokens = max_tokens,
            .refill_rate = refill_rate,
            .max_entries = max_entries,
            .mutex = .{},
            .last_sweep = zsys.timestamp(),
        };
    }

    pub fn deinit(self: *PerIpRateLimiter) void {
        self.buckets.deinit();
    }

    /// Try to consume one token for the connection's source IP. Returns true on
    /// success, false when this IP is over-rate.
    /// On allocation failure (OOM during HashMap.put) the limiter fails OPEN
    /// (returns true) — denying every request on internal failure would be a
    /// worse outcome than a brief gap in rate limiting.
    pub fn tryAcquireFor(self: *PerIpRateLimiter, addr: std.Io.net.IpAddress) bool {
        const key = ipKeyFromAddress(addr);
        const now = zsys.timestamp();

        self.mutex.lock();
        defer self.mutex.unlock();

        // Periodic sweep of long-idle entries to keep the map bounded.
        if (now - self.last_sweep > 60) {
            self.sweepStaleLocked(now);
            self.last_sweep = now;
        }

        // Prevent unbounded growth from rotating-IP attacks: once at capacity,
        // refuse to register new IPs (treat them as if their bucket were empty).
        // Existing IPs continue to function normally.
        const existing = self.buckets.getPtr(key);
        if (existing == null and self.buckets.count() >= self.max_entries) {
            return false;
        }

        const gop = self.buckets.getOrPut(key) catch return true; // fail open on OOM
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .tokens = self.max_tokens, .last_refill = now };
        }

        // Refill based on elapsed seconds since this bucket's last refill.
        const elapsed = now - gop.value_ptr.last_refill;
        if (elapsed >= 1) {
            const add: u64 = @as(u64, @intCast(elapsed)) * self.refill_rate;
            const new_tokens: u64 = @as(u64, gop.value_ptr.tokens) + add;
            gop.value_ptr.tokens = @intCast(@min(new_tokens, self.max_tokens));
            gop.value_ptr.last_refill = now;
        }

        if (gop.value_ptr.tokens == 0) return false;
        gop.value_ptr.tokens -= 1;
        return true;
    }

    /// Remove buckets that have been idle longer than the stale threshold.
    /// Called from `tryAcquireFor` while holding the mutex; do not call externally.
    fn sweepStaleLocked(self: *PerIpRateLimiter, now: i64) void {
        const stale_threshold_secs: i64 = 600; // 10 minutes idle
        var to_remove: std.ArrayList(IpKey) = .empty;
        defer to_remove.deinit(self.allocator);

        var it = self.buckets.iterator();
        while (it.next()) |kv| {
            if (now - kv.value_ptr.last_refill > stale_threshold_secs) {
                to_remove.append(self.allocator, kv.key_ptr.*) catch break;
            }
        }
        for (to_remove.items) |k| _ = self.buckets.remove(k);
    }
};

test "PerIpRateLimiter rejects after burst, isolates by IP" {
    const allocator = std.testing.allocator;
    var lim = PerIpRateLimiter.init(allocator, 3, 1, 1000);
    defer lim.deinit();

    const a4: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 1, 2, 3, 4 }, .port = 0 } };
    const b4: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 5, 6, 7, 8 }, .port = 0 } };

    // Drain A's bucket
    try std.testing.expect(lim.tryAcquireFor(a4));
    try std.testing.expect(lim.tryAcquireFor(a4));
    try std.testing.expect(lim.tryAcquireFor(a4));
    try std.testing.expect(!lim.tryAcquireFor(a4)); // empty

    // B is unaffected — proves per-IP isolation
    try std.testing.expect(lim.tryAcquireFor(b4));
}

test "PerIpRateLimiter caps map at max_entries" {
    const allocator = std.testing.allocator;
    var lim = PerIpRateLimiter.init(allocator, 100, 1, 2);
    defer lim.deinit();

    const a: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 1, 0, 0, 1 }, .port = 0 } };
    const b: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 1, 0, 0, 2 }, .port = 0 } };
    const c: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 1, 0, 0, 3 }, .port = 0 } };

    try std.testing.expect(lim.tryAcquireFor(a));
    try std.testing.expect(lim.tryAcquireFor(b));
    // Third distinct IP refused because map is at capacity
    try std.testing.expect(!lim.tryAcquireFor(c));
}

/// Simple token bucket rate limiter
pub const RateLimiter = struct {
    tokens: std.atomic.Value(u32),
    max_tokens: u32,
    refill_rate: u32, // tokens per second
    last_refill: std.atomic.Value(i64),
    mutex: zsys.Mutex,

    pub fn init(max_tokens: u32, refill_rate: u32) RateLimiter {
        return .{
            .tokens = std.atomic.Value(u32).init(max_tokens),
            .max_tokens = max_tokens,
            .refill_rate = refill_rate,
            .last_refill = std.atomic.Value(i64).init(zsys.timestamp()),
            .mutex = zsys.Mutex{},
        };
    }

    /// Try to acquire a token, returns true if successful
    pub fn tryAcquire(self: *RateLimiter) bool {
        self.refill();

        // Use compare-and-swap loop to atomically decrement only if > 0.
        // A simple load-then-fetchSub has a TOCTOU race: two threads can both
        // read current=1, both subtract, wrapping u32 to max and disabling
        // the rate limiter.
        while (true) {
            const current = self.tokens.load(.acquire);
            if (current == 0) return false;
            if (self.tokens.cmpxchgWeak(current, current - 1, .release, .monotonic) == null) {
                return true;
            }
            // CAS failed (another thread changed tokens), retry
        }
    }

    /// Acquire a token, blocking if necessary
    pub fn acquire(self: *RateLimiter) void {
        while (true) {
            if (self.tryAcquire()) {
                return;
            }
            // Sleep for a small amount if no tokens available
            zsys.sleep(100 * std.time.ns_per_ms);
        }
    }

    /// Refill tokens based on elapsed time
    fn refill(self: *RateLimiter) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = zsys.timestamp();
        const last = self.last_refill.load(.acquire);
        const elapsed = now - last;

        if (elapsed >= 1) {
            const tokens_to_add = @as(u32, @intCast(elapsed)) * self.refill_rate;
            const current = self.tokens.load(.acquire);
            const new_tokens = @min(current + tokens_to_add, self.max_tokens);

            self.tokens.store(new_tokens, .release);
            self.last_refill.store(now, .release);
        }
    }
};
