//! Cooperative graceful shutdown shared by the indexer and API binaries.
//!
//! A SIGTERM/SIGINT handler sets a process-wide flag and wakes the API accept
//! loop by shutting down the published listener fd. Zig 0.16's accept retries
//! EINTR, so a signal alone never unblocks it; shutdown(2) on the listening
//! socket makes the blocked accept fail with error.SocketNotListening, which
//! the accept loops treat as the stop signal. A second signal force-exits so a
//! stuck drain never traps the operator.

const std = @import("std");

var requested = std.atomic.Value(bool).init(false);
var wake_fd = std.atomic.Value(i32).init(-1);

pub fn isRequested() bool {
    return requested.load(.acquire);
}

/// Publish the listening socket to unblock on signal; -1 clears it.
pub fn setWakeFd(fd: i32) void {
    wake_fd.store(fd, .release);
}

pub fn clearWakeFd() void {
    wake_fd.store(-1, .release);
}

/// Test seam and programmatic trigger; safe to call from any thread.
pub fn request() void {
    requested.store(true, .release);
}

/// Sleep up to `ns`, waking early (returns true) when shutdown was requested.
/// Chunked because zsys.sleep deliberately resumes after EINTR, so a signal
/// never shortens a plain sleep.
pub fn sleepInterruptible(ns: u64) bool {
    const zsys = @import("system.zig");
    const chunk_ns: u64 = 250 * std.time.ns_per_ms;
    var remaining = ns;
    while (remaining > 0) {
        if (isRequested()) return true;
        const n = @min(remaining, chunk_ns);
        zsys.sleep(n);
        remaining -= n;
    }
    return isRequested();
}

fn onSignal(_: std.c.SIG) callconv(.c) void {
    if (requested.swap(true, .acq_rel)) {
        // Second signal: drain is stuck — force exit without destructors.
        std.c._exit(1);
    }
    // shutdown(2) is a plain syscall on Linux; not on the strict POSIX
    // async-signal-safe list but safe in practice (see docs/beat-plan.md P0.1).
    const fd = wake_fd.load(.acquire);
    if (fd >= 0) _ = std.c.shutdown(fd, std.c.SHUT.RDWR);
}

pub fn install() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.TERM, &act, null);
    std.posix.sigaction(.INT, &act, null);
}

test "flag starts clear; request sets it; sleepInterruptible wakes early" {
    try std.testing.expect(!isRequested());
    const t0 = @import("system.zig").milliTimestamp();
    try std.testing.expect(!sleepInterruptible(30 * std.time.ns_per_ms));
    request();
    defer requested.store(false, .release);
    try std.testing.expect(sleepInterruptible(60 * std.time.ns_per_s));
    const elapsed = @import("system.zig").milliTimestamp() - t0;
    try std.testing.expect(elapsed < 5_000);
}
