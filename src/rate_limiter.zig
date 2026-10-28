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
/// Provider throttle responses observed anywhere in this process, ever.
///
/// A free-running counter rather than a callback, for one specific reason: the
/// RPC client absorbs a throttle inside its OWN retry loop when the retry
/// succeeds, so those never reach a caller that could report them — and in the
/// 2026-09-30 incident all fifteen were of exactly that kind ("attempt 2/3",
/// never 3/3). Sampling a counter catches them without threading a limiter
/// reference through the client.
var provider_throttles: std.atomic.Value(u64) = .init(0);

/// Called from the RPC error classifier on every provider throttle, retried or
/// not. Cheap enough to sit on that path unconditionally.
pub fn noteProviderThrottle() void {
    _ = provider_throttles.fetchAdd(1, .monotonic);
}

pub fn providerThrottleCount() u64 {
    return provider_throttles.load(.monotonic);
}

/// How long the rate stays reduced before stepping back up, the floor it will
/// not go below (so a throttling provider cannot stall the indexer), and the
/// minimum gap between two decreases.
///
/// The cooldown is the important one. Halving on *every* distinct throttle meant
/// a burst — which is the normal shape of a 429, and was exactly the shape of the
/// incident this exists for: fifteen in eighty seconds — walked 15 → 7 → 3 → 1 in
/// under a second and then crawled back one token at a time. That is a
/// self-inflicted stall an order of magnitude worse than the problem. AIMD
/// decreases once per feedback window, not once per message.
const BACKPRESSURE_RECOVERY_SECS: i64 = 10;
const BACKPRESSURE_DECREASE_COOLDOWN_SECS: i64 = 5;
const BACKPRESSURE_MIN_RATE: u32 = 1;

pub const RateLimiter = struct {
    tokens: std.atomic.Value(u32),
    max_tokens: u32,
    refill_rate: u32, // tokens per second — the configured ceiling
    /// The rate actually in force. Halved on each provider throttle and stepped
    /// back up after a quiet period (AIMD). Before this existed the provider
    /// could reject us fifteen times in eighty seconds and we would answer at
    /// the same speed every time; the configured rate was the only input and the
    /// provider's own feedback was discarded.
    effective_rate: u32,
    last_refill: std.atomic.Value(i64),
    /// Throttle count at the last adjustment, so a NEW throttle is distinguished
    /// from the same one seen again.
    seen_throttles: u64,
    last_adjust: i64,
    /// Seconds of quiet before the rate steps back up, and the minimum gap
    /// between two decreases. Fields rather than constants purely so a test can
    /// exercise both paths without a fake clock — production uses the defaults.
    recovery_secs: i64 = BACKPRESSURE_RECOVERY_SECS,
    decrease_cooldown_secs: i64 = BACKPRESSURE_DECREASE_COOLDOWN_SECS,
    /// Operator kill switch (RPC_BACKPRESSURE_ENABLED). A brand-new control loop
    /// that can only be turned off by a redeploy is not something to put in
    /// production; with this false the limiter behaves exactly as it did before
    /// backpressure existed.
    backpressure_enabled: bool = true,
    mutex: zsys.Mutex,

    pub fn init(max_tokens: u32, refill_rate: u32) RateLimiter {
        return .{
            .tokens = std.atomic.Value(u32).init(max_tokens),
            .max_tokens = max_tokens,
            .refill_rate = refill_rate,
            .effective_rate = refill_rate,
            .last_refill = std.atomic.Value(i64).init(zsys.timestamp()),
            .seen_throttles = provider_throttles.load(.monotonic),
            .last_adjust = zsys.timestamp(),
            .mutex = zsys.Mutex{},
        };
    }

    /// Current rate in force, for logging and tests.
    pub fn effectiveRate(self: *RateLimiter) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.effective_rate;
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

    /// Additive-increase step, proportional to the configured rate. A flat +1
    /// took fourteen quiet windows to climb back from the floor at the default
    /// rate of 15 — minutes of near-stalled indexing after the provider had
    /// already recovered.
    /// Caller holds the mutex.
    fn recoveryStepLocked(self: *const RateLimiter) u32 {
        return @max(1, self.refill_rate / 4);
    }

    /// Refill tokens based on elapsed time
    fn refill(self: *RateLimiter) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = zsys.timestamp();

        // Multiplicative decrease on the provider's feedback, additive recovery.
        // Done here rather than on the throttle path itself so it needs no lock
        // of its own and cannot be missed by a caller that forgets to report.
        const seen = provider_throttles.load(.monotonic);
        if (!self.backpressure_enabled) {
            // Keep tracking so turning it off mid-run cannot leave a stale
            // counter that fires a spurious decrease if it is turned back on.
            self.seen_throttles = seen;
            self.effective_rate = self.refill_rate;
        } else if (seen != self.seen_throttles) {
            // One decrease per window. Inside the cooldown the signal is NOT
            // consumed, so the next window still halves — a burst is bounded,
            // not discarded.
            if (now - self.last_adjust >= self.decrease_cooldown_secs) {
                self.seen_throttles = seen;
                const before = self.effective_rate;
                self.effective_rate = @max(BACKPRESSURE_MIN_RATE, self.effective_rate / 2);
                self.last_adjust = now;
                // Drop the standing burst too: tokens already granted at the old rate
                // would otherwise let the next few calls ignore the decrease.
                const current = self.tokens.load(.acquire);
                if (current > self.effective_rate) self.tokens.store(self.effective_rate, .release);
                // An indexer that quietly slows itself down is the hardest kind
                // of incident to diagnose, so say so every time it happens.
                if (before != self.effective_rate) {
                    std.log.warn("rpc backpressure: provider throttling, rate {d} -> {d}/s (configured {d}/s; recovers +{d} every {d}s)", .{
                        before,
                        self.effective_rate,
                        self.refill_rate,
                        self.recoveryStepLocked(),
                        self.recovery_secs,
                    });
                }
            }
        } else if (self.effective_rate < self.refill_rate and now - self.last_adjust >= self.recovery_secs) {
            self.effective_rate = @min(self.refill_rate, self.effective_rate + self.recoveryStepLocked());
            self.last_adjust = now;
            if (self.effective_rate == self.refill_rate) {
                std.log.info("rpc backpressure: provider quiet, rate restored to the configured {d}/s", .{self.refill_rate});
            }
        }

        const last = self.last_refill.load(.acquire);
        const elapsed = now - last;

        if (elapsed >= 1) {
            const tokens_to_add = @as(u32, @intCast(elapsed)) * self.effective_rate;
            const current = self.tokens.load(.acquire);
            // Cap at the effective rate, not the configured burst: a once-per-
            // second burst of `max_tokens` is the worst possible shape for a
            // provider that meters per second.
            const new_tokens = @min(current + tokens_to_add, @min(self.max_tokens, self.effective_rate));

            self.tokens.store(new_tokens, .release);
            self.last_refill.store(now, .release);
        }
    }
};

test "backpressure: a provider throttle halves the rate, with a floor of 1" {
    var lim = RateLimiter.init(25, 25);
    lim.decrease_cooldown_secs = 0; // isolate the decrease shape from the cooldown
    try std.testing.expectEqual(@as(u32, 25), lim.effectiveRate());

    // Each distinct throttle halves the rate on the next refill. Before this,
    // the provider could reject us repeatedly and the rate never moved.
    const steps = [_]u32{ 12, 6, 3, 1, 1, 1 };
    for (steps) |want| {
        noteProviderThrottle();
        _ = lim.tryAcquire();
        try std.testing.expectEqual(want, lim.effectiveRate());
    }
    // Never zero: a throttling provider must not be able to stall the indexer.
    try std.testing.expect(lim.effectiveRate() >= 1);
}

test "backpressure: the rate recovers additively once the provider goes quiet" {
    var lim = RateLimiter.init(25, 25);
    lim.recovery_secs = 0; // no fake clock available; exercise the path directly
    lim.decrease_cooldown_secs = 0;

    noteProviderThrottle();
    _ = lim.tryAcquire();
    const reduced = lim.effectiveRate();
    try std.testing.expect(reduced < 25);

    // Additive increase, one step per quiet interval — not a jump straight back.
    // The step is proportional to the configured rate: a flat +1 needed fourteen
    // windows to leave the floor at the default rate, which is a stall of its own.
    const step: u32 = 25 / 4;
    try std.testing.expect(step > 1);
    _ = lim.tryAcquire();
    try std.testing.expectEqual(reduced + step, lim.effectiveRate());

    // And it stops at the configured ceiling rather than climbing past it.
    var i: usize = 0;
    while (i < 100) : (i += 1) _ = lim.tryAcquire();
    try std.testing.expectEqual(@as(u32, 25), lim.effectiveRate());
}

test "backpressure: a burst of throttles costs ONE halving, not one per message" {
    var lim = RateLimiter.init(16, 16);
    lim.decrease_cooldown_secs = 3600;
    lim.last_adjust = 0; // as if the process had been up a while

    // The incident shape: fifteen throttles inside eighty seconds. Halving on
    // each one walked the rate to the floor in under a second; one decrease per
    // window is what AIMD actually prescribes.
    for (0..15) |_| {
        noteProviderThrottle();
        _ = lim.tryAcquire();
    }
    try std.testing.expectEqual(@as(u32, 8), lim.effectiveRate());

    // The burst is BOUNDED, not discarded: once the window passes, the throttles
    // that arrived during it still produce the next decrease.
    lim.last_adjust = 0;
    noteProviderThrottle();
    _ = lim.tryAcquire();
    try std.testing.expectEqual(@as(u32, 4), lim.effectiveRate());
}

test "backpressure: the kill switch restores pre-backpressure behaviour exactly" {
    var lim = RateLimiter.init(20, 20);
    lim.backpressure_enabled = false;
    lim.decrease_cooldown_secs = 0;

    for (0..10) |_| {
        noteProviderThrottle();
        _ = lim.tryAcquire();
    }
    // A control loop with no off switch is not something to ship; with it off the
    // configured rate is the only input, as it was before.
    try std.testing.expectEqual(@as(u32, 20), lim.effectiveRate());
    try std.testing.expect(lim.tokens.load(.acquire) <= 20);
}

test "backpressure: a reduction also drops the standing burst" {
    var lim = RateLimiter.init(25, 25);
    lim.decrease_cooldown_secs = 0;
    // Full bucket at the configured rate.
    try std.testing.expectEqual(@as(u32, 25), lim.tokens.load(.acquire));

    noteProviderThrottle();
    _ = lim.tryAcquire();
    // Tokens already granted at the old rate would otherwise let the next
    // dozen calls ignore the decrease entirely.
    try std.testing.expect(lim.tokens.load(.acquire) <= lim.effectiveRate());
}
