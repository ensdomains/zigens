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

    /// Check if the RPC endpoint is actually serving requests.
    ///
    /// Sends a minimal JSON-RPC `eth_blockNumber` call rather than just opening a TCP
    /// socket. A bare TCP connect succeeds whenever DNS resolves and the upstream
    /// gateway/load-balancer accepts the SYN — even when the actual HTTPS/RPC layer
    /// is broken. That false-positive caused the indexer to flap between
    /// "network restored, continuing..." and "network error detected, waiting..."
    /// because the TCP check passed but the next real RPC call still failed
    /// (`error.WriteFailed`).
    fn checkConnection(self: *NetworkHealth) bool {
        // 1) Cheap pre-flight: TCP-resolve the host. Bails fast on hard outages
        //    (no DNS / no route to host) without paying for a full HTTPS handshake.
        const uri = std.Uri.parse(self.rpc_url) catch return false;
        const port: u16 = uri.port orelse if (std.mem.startsWith(u8, self.rpc_url, "https")) 443 else 80;
        const host = uri.host orelse return false;

        const address_list = std.net.getAddressList(self.allocator, host.percent_encoded, port) catch return false;
        defer address_list.deinit();
        if (address_list.addrs.len == 0) return false;

        const stream = std.net.tcpConnectToAddress(address_list.addrs[0]) catch return false;
        stream.close();

        // 2) Real check: post a tiny JSON-RPC request and require a 2xx response with
        //    a non-empty body. This exercises the same path the indexer's `eth_getLogs`
        //    calls take, so a passing check actually predicts the next call will work.
        var client = std.http.Client{ .allocator = self.allocator };
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
