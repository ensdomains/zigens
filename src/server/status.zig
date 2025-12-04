const std = @import("std");

pub const IndexerStatus = struct {
    current_block: u64,
    target_block: u64,
    start_block: u64,
    start_time: i64,
    graphql_enabled: bool,
    api_enabled: bool,
    webhooks_enabled: bool,
    indexing_complete: bool,

    pub fn getProgress(self: IndexerStatus) f64 {
        if (self.target_block <= self.start_block) return 100.0;
        const total = self.target_block - self.start_block;
        const done = self.current_block - self.start_block;
        return (@as(f64, @floatFromInt(done)) / @as(f64, @floatFromInt(total))) * 100.0;
    }

    pub fn getETA(self: IndexerStatus) ?i64 {
        if (self.indexing_complete) return null;
        if (self.current_block <= self.start_block) return null;

        const elapsed = std.time.timestamp() - self.start_time;
        if (elapsed <= 0) return null;

        const blocks_done = self.current_block - self.start_block;
        // If we've reached or passed the target, no ETA needed
        if (self.current_block >= self.target_block) return null;
        const blocks_remaining = self.target_block - self.current_block;
        if (blocks_done == 0) return null;

        const rate = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(blocks_done));
        return @intFromFloat(rate * @as(f64, @floatFromInt(blocks_remaining)));
    }
};

pub const StatusServer = struct {
    allocator: std.mem.Allocator,
    status: *IndexerStatus,
    listener: std.net.Server,
    thread: ?std.Thread,
    port: u16,
    running: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, status: *IndexerStatus, port: u16) !*StatusServer {
        const self = try allocator.create(StatusServer);
        const address = try std.net.Address.parseIp("127.0.0.1", port);

        self.* = StatusServer{
            .allocator = allocator,
            .status = status,
            .listener = try address.listen(.{ .reuse_address = true }),
            .thread = null,
            .port = port,
            .running = std.atomic.Value(bool).init(false),
        };
        return self;
    }

    pub fn start(self: *StatusServer) !void {
        self.running.store(true, .seq_cst);
        std.log.info("Status server listening on http://127.0.0.1:{d}/status", .{self.port});
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn stop(self: *StatusServer) void {
        self.running.store(false, .seq_cst);
        if (self.thread) |thread| {
            thread.join();
        }
        self.listener.deinit();
    }

    pub fn deinit(self: *StatusServer) void {
        self.stop();
        self.allocator.destroy(self);
    }

    fn run(self: *StatusServer) !void {
        while (self.running.load(.seq_cst)) {
            const connection = self.listener.accept() catch |err| {
                if (err == error.SocketNotListening) break;
                std.log.err("Failed to accept connection: {}", .{err});
                continue;
            };

            self.handleConnection(connection) catch |err| {
                std.log.err("Failed to handle connection: {}", .{err});
            };
        }
    }

    fn handleConnection(self: *StatusServer, conn: std.net.Server.Connection) !void {
        defer conn.stream.close();

        var buf: [4096]u8 = undefined;
        const bytes_read = try conn.stream.read(&buf);
        if (bytes_read == 0) return;

        const request = buf[0..bytes_read];

        // Parse request line
        var lines = std.mem.splitScalar(u8, request, '\n');
        const first_line = lines.next() orelse return;

        var parts = std.mem.splitScalar(u8, first_line, ' ');
        _ = parts.next(); // Method (GET)
        const path = std.mem.trim(u8, parts.next() orelse "/", &std.ascii.whitespace);

        if (std.mem.eql(u8, path, "/status")) {
            try self.serveStatusPage(conn.stream);
        } else if (std.mem.eql(u8, path, "/status/api")) {
            try self.serveStatusAPI(conn.stream);
        } else {
            try self.serve404(conn.stream);
        }
    }

    fn serveStatusPage(self: *StatusServer, stream: std.net.Stream) !void {
        const html = try generateHTML(self.allocator, self.status);
        defer self.allocator.free(html);

        const response = try std.fmt.allocPrint(self.allocator,
            "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\n\r\n{s}",
            .{ html.len, html },
        );
        defer self.allocator.free(response);

        _ = try stream.writeAll(response);
    }

    fn serveStatusAPI(self: *StatusServer, stream: std.net.Stream) !void {
        const json = try generateJSON(self.allocator, self.status);
        defer self.allocator.free(json);

        const response = try std.fmt.allocPrint(self.allocator,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: {d}\r\n\r\n{s}",
            .{ json.len, json },
        );
        defer self.allocator.free(response);

        _ = try stream.writeAll(response);
    }

    fn serve404(self: *StatusServer, stream: std.net.Stream) !void {
        const body = "404 Not Found\n";
        const response = try std.fmt.allocPrint(self.allocator,
            "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\n\r\n{s}",
            .{ body.len, body },
        );
        defer self.allocator.free(response);

        _ = try stream.writeAll(response);
    }
};

fn generateHTML(allocator: std.mem.Allocator, status: *IndexerStatus) ![]const u8 {
    const progress = status.getProgress();
    const eta = status.getETA();

    var eta_str = try allocator.alloc(u8, 50);
    defer allocator.free(eta_str);

    if (status.indexing_complete) {
        eta_str = try std.fmt.allocPrint(allocator, "Complete", .{});
    } else if (eta) |seconds| {
        const hours = @divTrunc(seconds, 3600);
        const mins = @divTrunc(@rem(seconds, 3600), 60);
        const secs = @rem(seconds, 60);
        if (hours > 0) {
            eta_str = try std.fmt.allocPrint(allocator, "{d}h {d}m {d}s", .{ hours, mins, secs });
        } else if (mins > 0) {
            eta_str = try std.fmt.allocPrint(allocator, "{d}m {d}s", .{ mins, secs });
        } else {
            eta_str = try std.fmt.allocPrint(allocator, "{d}s", .{secs});
        }
    } else {
        eta_str = try std.fmt.allocPrint(allocator, "Calculating...", .{});
    }

    const html = try std.fmt.allocPrint(allocator,
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\  <meta charset="utf-8">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1">
        \\  <title>ENSv2 Indexer Status</title>
        \\  <style>
        \\    * {{ margin: 0; padding: 0; box-sizing: border-box; }}
        \\    body {{ font-family: system-ui, -apple-system, sans-serif; background: #0a0a0a; color: #e0e0e0; padding: 40px 20px; }}
        \\    .container {{ max-width: 800px; margin: 0 auto; }}
        \\    h1 {{ font-size: 24px; font-weight: 600; margin-bottom: 32px; color: #fff; }}
        \\    .section {{ background: #1a1a1a; border: 1px solid #2a2a2a; border-radius: 8px; padding: 24px; margin-bottom: 20px; }}
        \\    .section-title {{ font-size: 14px; font-weight: 600; color: #a0a0a0; margin-bottom: 16px; text-transform: uppercase; letter-spacing: 0.5px; }}
        \\    .status-grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 16px; }}
        \\    .status-item {{ display: flex; align-items: center; gap: 12px; }}
        \\    .status-dot {{ width: 10px; height: 10px; border-radius: 50%; }}
        \\    .status-dot.active {{ background: #10b981; box-shadow: 0 0 8px #10b981; }}
        \\    .status-dot.inactive {{ background: #6b7280; }}
        \\    .status-label {{ font-size: 14px; color: #e0e0e0; }}
        \\    .progress-container {{ margin-top: 20px; }}
        \\    .progress-bar {{ height: 8px; background: #2a2a2a; border-radius: 4px; overflow: hidden; }}
        \\    .progress-fill {{ height: 100%; background: linear-gradient(90deg, #3b82f6, #8b5cf6); transition: width 0.3s ease; }}
        \\    .progress-info {{ display: flex; justify-content: space-between; margin-top: 12px; font-size: 14px; }}
        \\    .progress-label {{ color: #a0a0a0; }}
        \\    .progress-value {{ color: #fff; font-weight: 500; }}
        \\    .blocks-info {{ display: grid; grid-template-columns: repeat(3, 1fr); gap: 16px; margin-top: 16px; }}
        \\    .block-stat {{ text-align: center; }}
        \\    .block-label {{ font-size: 12px; color: #6b7280; margin-bottom: 4px; }}
        \\    .block-value {{ font-size: 18px; font-weight: 600; color: #fff; }}
        \\    .eta-badge {{ display: inline-block; background: #1e3a8a; color: #93c5fd; padding: 4px 12px; border-radius: 12px; font-size: 12px; font-weight: 500; }}
        \\  </style>
        \\  <script>
        \\    setInterval(async () => {{
        \\      const res = await fetch('/status/api');
        \\      const data = await res.json();
        \\      document.getElementById('progress').style.width = data.progress.toFixed(1) + '%';
        \\      document.getElementById('progress-text').textContent = data.progress.toFixed(1);
        \\      document.getElementById('current-block').textContent = data.current_block.toLocaleString();
        \\      document.getElementById('eta').textContent = data.eta;
        \\    }}, 1000);
        \\  </script>
        \\</head>
        \\<body>
        \\  <div class="container">
        \\    <h1>ENSv2 Indexer Status</h1>
        \\
        \\    <div class="section">
        \\      <div class="section-title">Services</div>
        \\      <div class="status-grid">
        \\        <div class="status-item">
        \\          <div class="status-dot {s}"></div>
        \\          <div class="status-label">GraphQL API</div>
        \\        </div>
        \\        <div class="status-item">
        \\          <div class="status-dot {s}"></div>
        \\          <div class="status-label">REST API</div>
        \\        </div>
        \\        <div class="status-item">
        \\          <div class="status-dot {s}"></div>
        \\          <div class="status-label">Webhooks</div>
        \\        </div>
        \\      </div>
        \\    </div>
        \\
        \\    <div class="section">
        \\      <div class="section-title">Indexing Progress</div>
        \\      <div class="progress-container">
        \\        <div class="progress-bar">
        \\          <div class="progress-fill" id="progress" style="width: {d:.1}%"></div>
        \\        </div>
        \\        <div class="progress-info">
        \\          <div class="progress-label">Progress</div>
        \\          <div class="progress-value"><span id="progress-text">{d:.1}</span>%</div>
        \\        </div>
        \\        <div class="blocks-info">
        \\          <div class="block-stat">
        \\            <div class="block-label">Start</div>
        \\            <div class="block-value">{d}</div>
        \\          </div>
        \\          <div class="block-stat">
        \\            <div class="block-label">Current</div>
        \\            <div class="block-value" id="current-block">{d}</div>
        \\          </div>
        \\          <div class="block-stat">
        \\            <div class="block-label">Target</div>
        \\            <div class="block-value">{d}</div>
        \\          </div>
        \\        </div>
        \\        <div class="progress-info" style="margin-top: 16px;">
        \\          <div class="progress-label">ETA</div>
        \\          <div class="eta-badge" id="eta">{s}</div>
        \\        </div>
        \\      </div>
        \\    </div>
        \\  </div>
        \\</body>
        \\</html>
    , .{
        if (status.graphql_enabled) "active" else "inactive",
        if (status.api_enabled) "active" else "inactive",
        if (status.webhooks_enabled) "active" else "inactive",
        progress,
        progress,
        status.start_block,
        status.current_block,
        status.target_block,
        eta_str,
    });

    return html;
}

fn generateJSON(allocator: std.mem.Allocator, status: *IndexerStatus) ![]const u8 {
    const progress = status.getProgress();
    const eta = status.getETA();

    var eta_str = try allocator.alloc(u8, 50);
    defer allocator.free(eta_str);

    if (status.indexing_complete) {
        eta_str = try std.fmt.allocPrint(allocator, "Complete", .{});
    } else if (eta) |seconds| {
        const hours = @divTrunc(seconds, 3600);
        const mins = @divTrunc(@rem(seconds, 3600), 60);
        const secs = @rem(seconds, 60);
        if (hours > 0) {
            eta_str = try std.fmt.allocPrint(allocator, "{d}h {d}m {d}s", .{ hours, mins, secs });
        } else if (mins > 0) {
            eta_str = try std.fmt.allocPrint(allocator, "{d}m {d}s", .{ mins, secs });
        } else {
            eta_str = try std.fmt.allocPrint(allocator, "{d}s", .{secs});
        }
    } else {
        eta_str = try std.fmt.allocPrint(allocator, "Calculating...", .{});
    }

    const json = try std.fmt.allocPrint(allocator,
        \\{{"current_block":{d},"target_block":{d},"start_block":{d},"progress":{d:.2},"eta":"{s}","graphql_enabled":{s},"api_enabled":{s},"webhooks_enabled":{s},"indexing_complete":{s}}}
    , .{
        status.current_block,
        status.target_block,
        status.start_block,
        progress,
        eta_str,
        if (status.graphql_enabled) "true" else "false",
        if (status.api_enabled) "true" else "false",
        if (status.webhooks_enabled) "true" else "false",
        if (status.indexing_complete) "true" else "false",
    });

    return json;
}
