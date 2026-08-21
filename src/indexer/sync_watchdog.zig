//! Fail-fast watchdog for the sync run loops.
//!
//! If every sync cycle fails continuously for the configured window while the
//! network looks healthy, the process state is assumed unrecoverable in place
//! and the process exits so the supervisor's restart policy revives it in
//! seconds instead of stalling until a human notices. Motivating incident
//! (2026-08-20): std.http.Client stamps its certificate-validation timestamp
//! on the process's first https request and never refreshes it, so when the
//! RPC provider rotated its leaf certificate every new handshake failed as
//! TlsInitializationFailed for ~14 hours — a restart was the cure. The rpc
//! client now heals that specific disease in place; this watchdog is the
//! backstop for the next process-local failure mode that restart would fix.
//!
//! An abrupt exit is safe by design: the sync cursor and reorg undo-log
//! already survive kill/crash, and the next start resumes from stored state.
//! Genuine network outages must NOT trip it — the run loop parks those in
//! NetworkHealth.waitForHealthy without recording a failure.

const std = @import("std");

pub const SyncFailureWatchdog = struct {
    /// 0 disables the watchdog entirely.
    exit_after_ms: u64,
    first_failure_ms: ?i64 = null,

    pub fn init(exit_after_minutes: u64) SyncFailureWatchdog {
        return .{ .exit_after_ms = exit_after_minutes * std.time.ms_per_min };
    }

    pub fn recordSuccess(self: *SyncFailureWatchdog) void {
        self.first_failure_ms = null;
    }

    /// Timing core, kept pure (caller supplies the clock and performs the
    /// exit) so it is unit-testable: arms the window on the first failure and
    /// returns true once failures have been continuous for the whole window.
    pub fn failureWindowElapsed(self: *SyncFailureWatchdog, now_ms: i64) bool {
        if (self.exit_after_ms == 0) return false;
        const first = self.first_failure_ms orelse {
            self.first_failure_ms = now_ms;
            return false;
        };
        if (now_ms < first) return false;
        return @as(u64, @intCast(now_ms - first)) >= self.exit_after_ms;
    }
};

test "watchdog arms on first failure and elapses only after a continuous window" {
    var w: SyncFailureWatchdog = .init(15);
    try std.testing.expect(!w.failureWindowElapsed(1_000));
    try std.testing.expect(!w.failureWindowElapsed(1_000 + 14 * std.time.ms_per_min));
    try std.testing.expect(w.failureWindowElapsed(1_000 + 15 * std.time.ms_per_min));
}

test "watchdog success resets the window" {
    var w: SyncFailureWatchdog = .init(15);
    try std.testing.expect(!w.failureWindowElapsed(0));
    w.recordSuccess();
    try std.testing.expect(!w.failureWindowElapsed(16 * std.time.ms_per_min));
    try std.testing.expect(!w.failureWindowElapsed(30 * std.time.ms_per_min));
    try std.testing.expect(w.failureWindowElapsed(31 * std.time.ms_per_min));
}

test "watchdog with 0 minutes is disabled" {
    var w: SyncFailureWatchdog = .init(0);
    try std.testing.expect(!w.failureWindowElapsed(0));
    try std.testing.expect(!w.failureWindowElapsed(100 * std.time.ms_per_hour));
}

test "watchdog tolerates a clock stepping backwards" {
    var w: SyncFailureWatchdog = .init(15);
    try std.testing.expect(!w.failureWindowElapsed(20 * std.time.ms_per_min));
    try std.testing.expect(!w.failureWindowElapsed(1 * std.time.ms_per_min));
    try std.testing.expect(w.failureWindowElapsed(35 * std.time.ms_per_min));
}
