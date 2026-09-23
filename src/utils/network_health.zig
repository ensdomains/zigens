const std = @import("std");
const zsys = @import("../utils/system.zig");
const shutdown = @import("shutdown.zig");

/// Network health checker - waits for network connectivity before continuing
pub const NetworkHealth = struct {
    allocator: std.mem.Allocator,
    rpc_url: []const u8,
    last_check: i64,
    check_interval_ms: u64,

    pub fn init(allocator: std.mem.Allocator, rpc_url: []const u8, check_interval_ms: u64) NetworkHealth {
        return .{
            .allocator = allocator,
            .rpc_url = rpc_url,
            .last_check = 0,
            .check_interval_ms = check_interval_ms,
        };
    }

    /// Wait until network is healthy, logging status periodically.
    /// Waits indefinitely for connectivity, but returns early on graceful
    /// shutdown — callers re-check their stop condition immediately after.
    pub fn waitForHealthy(self: *NetworkHealth) void {
        var consecutive_failures: u32 = 0;
        var logged_waiting = false;

        while (!shutdown.isRequested()) {
            if (self.checkConnection()) {
                if (logged_waiting) {
                    std.log.info("✓ Network connection restored, resuming operations", .{});
                }
                self.last_check = zsys.timestamp();
                return;
            } else {
                consecutive_failures += 1;

                if (!logged_waiting) {
                    std.log.warn("⚠ No network connection detected - waiting for connectivity...", .{});
                    logged_waiting = true;
                } else if (consecutive_failures % 10 == 0) {
                    // Log every 10 attempts (every ~30 seconds) to show we're still waiting
                    std.log.info("Still waiting for network connection... ({d} checks)", .{consecutive_failures});
                }

                // Wait before next check (exponential backoff up to 10 seconds)
                const wait_ms = @min(self.check_interval_ms * @as(u64, @intCast(@min(consecutive_failures, 10))), 10000);
                const wait_ns = wait_ms * @as(u64, std.time.ns_per_ms);
                if (shutdown.sleepInterruptible(wait_ns)) return;
            }
        }
    }

    /// Check if the RPC endpoint is actually serving requests.
    ///
    /// Sends a minimal JSON-RPC `eth_blockNumber` call rather than just opening a TCP
    /// socket. A bare TCP connect succeeds whenever DNS resolves and the upstream
    /// gateway/load-balancer accepts the SYN — even when the actual HTTPS/RPC layer
    /// is broken. That false-positive caused the indexer to flap between
    /// "network restored, continuing..." and "network error detected, waiting..."
    /// because the TCP check passed but the next real RPC call still failed
    /// (`error.WriteFailed`). (The 0.15-era DNS/TCP preflight is gone with std.net;
    /// the fetch below is the one real check.)
    fn checkConnection(self: *NetworkHealth) bool {
        // Per-call event loop: checkConnection is a cold path (only runs while the
        // network is already down), so a throwaway Threaded per check is fine and
        // keeps io out of the public API.
        var threaded = std.Io.Threaded.init(self.allocator, .{});
        defer threaded.deinit();

        var client = std.http.Client{ .allocator = self.allocator, .io = threaded.io() };
        defer client.deinit();

        const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\",\"params\":[]}";

        var response_buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer response_buf.deinit();

        const result = client.fetch(.{
            .location = .{ .url = self.rpc_url },
            .method = .POST,
            .payload = body,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "Content-Type", .value = "application/json" },
            },
            // Identity-only, like rpc/client.zig: keep the health probe off the flate
            // decompressor path entirely (see executeHttpRequest there).
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
            .response_writer = &response_buf.writer,
            .keep_alive = false,
        }) catch return false;

        const status: u16 = @intFromEnum(result.status);
        if (status < 200 or status >= 300) return false;
        if (response_buf.written().len == 0) return false;

        // No JSON parse — `"result":` substring is enough to distinguish a real RPC reply
        // from a captive-portal "200 OK <html>" or a load-balancer error stub.
        return std.mem.indexOf(u8, response_buf.written(), "\"result\":") != null;
    }
};
