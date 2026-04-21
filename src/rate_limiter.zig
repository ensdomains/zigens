const std = @import("std");

/// Simple token bucket rate limiter
pub const RateLimiter = struct {
    tokens: std.atomic.Value(u32),
    max_tokens: u32,
    refill_rate: u32, // tokens per second
    last_refill: std.atomic.Value(i64),
    mutex: std.Thread.Mutex,

    pub fn init(max_tokens: u32, refill_rate: u32) RateLimiter {
        return .{
            .tokens = std.atomic.Value(u32).init(max_tokens),
            .max_tokens = max_tokens,
            .refill_rate = refill_rate,
            .last_refill = std.atomic.Value(i64).init(std.time.timestamp()),
            .mutex = std.Thread.Mutex{},
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
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }

    /// Refill tokens based on elapsed time
    fn refill(self: *RateLimiter) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();
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
