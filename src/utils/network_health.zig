const std = @import("std");

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

    /// Wait until network is healthy, logging status periodically
    /// This never returns an error - it waits indefinitely until connection is restored
    pub fn waitForHealthy(self: *NetworkHealth) void {
        var consecutive_failures: u32 = 0;
        var logged_waiting = false;

        while (true) {
            if (self.checkConnection()) {
                if (logged_waiting) {
                    std.log.info("✓ Network connection restored, resuming operations", .{});
                }
                self.last_check = std.time.timestamp();
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
                std.Thread.sleep(wait_ns);
            }
        }
    }

    /// Quick check if connection is available (non-blocking)
    fn checkConnection(self: *NetworkHealth) bool {
        // Try a simple TCP connection to the RPC host
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        // Parse URL to get host and port
        const uri = std.Uri.parse(self.rpc_url) catch return false;
        const port: u16 = uri.port orelse if (std.mem.startsWith(u8, self.rpc_url, "https")) 443 else 80;

        // Try to resolve and connect
        const host = uri.host orelse return false;
        const address_list = std.net.getAddressList(self.allocator, host.percent_encoded, port) catch return false;
        defer address_list.deinit();

        if (address_list.addrs.len == 0) return false;

        // Try to connect to first address with short timeout
        const stream = std.net.tcpConnectToAddress(address_list.addrs[0]) catch return false;
        stream.close();

        return true;
    }
};
