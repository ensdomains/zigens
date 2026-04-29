const std = @import("std");
const db = @import("../storage/database.zig");
const models = @import("../types/models.zig");
const Hash = @import("../types/hash.zig").Hash;
const Address = @import("../types/address.zig").Address;
const graphql = @import("handler.zig");
const json_utils = @import("../utils/json.zig");
const url_utils = @import("../utils/url.zig");
const validation = @import("../utils/validation.zig");
const PerIpRateLimiter = @import("../rate_limiter.zig").PerIpRateLimiter;
const webhook_manager = @import("../webhooks/manager.zig");

/// Simple JSON API Server for ENSv2 Indexer
/// Provides REST endpoints and GraphQL for querying indexed data
pub const Server = struct {
    allocator: std.mem.Allocator,
    database: *db.Database,
    webhook_database: ?*db.Database, // Optional - only initialized if webhooks enabled
    port: u16,
    server: ?std.net.Server,
    graphql_handler: graphql.GraphQLHandler,
    rate_limiter: PerIpRateLimiter,
    webhook_admin_username: ?[]const u8, // Optional - if set with password, requires Basic Auth
    webhook_admin_password: ?[]const u8, // Optional - if set, requires Basic Auth for webhook endpoints

    pub fn init(allocator: std.mem.Allocator, database: *db.Database, webhook_db_path: ?[]const u8, port: u16, complexity_max_depth: u32, complexity_max_cost: u32, metrics_enabled: bool, rate_limit_per_second: u32, webhook_admin_username: ?[]const u8, webhook_admin_password: ?[]const u8) !Server {
        // Only open webhook database if path is provided (webhooks enabled)
        var webhook_db: ?*db.Database = null;
        if (webhook_db_path) |path| {
            const webhook_db_value = try db.Database.initWithoutSchema(allocator, path);
            webhook_db = try allocator.create(db.Database);
            webhook_db.?.* = webhook_db_value;
        }

        // Per-IP rate limiter with configurable requests/sec.
        // Burst capacity = 2x the per-second rate; the map is bounded at 100k IPs
        // (rotating-IP attacks beyond that get refused new buckets, see PerIpRateLimiter).
        const rate_limit = if (rate_limit_per_second > 0) rate_limit_per_second else 100;

        return .{
            .allocator = allocator,
            .database = database,
            .webhook_database = webhook_db,
            .port = port,
            .server = null,
            .graphql_handler = try graphql.GraphQLHandler.init(allocator, database, complexity_max_depth, complexity_max_cost, metrics_enabled),
            .rate_limiter = PerIpRateLimiter.init(allocator, rate_limit * 2, rate_limit, 100_000),
            .webhook_admin_username = webhook_admin_username,
            .webhook_admin_password = webhook_admin_password,
        };
    }

    pub fn deinit(self: *Server) void {
        self.graphql_handler.deinit();
        self.rate_limiter.deinit();
        if (self.webhook_database) |webhook_db| {
            webhook_db.deinit();
            self.allocator.destroy(webhook_db);
        }
        if (self.server) |*s| {
            s.deinit();
        }
    }

    pub fn start(self: *Server) !void {
        const address = try std.net.Address.parseIp("0.0.0.0", self.port);
        var server = try address.listen(.{
            .reuse_address = true,
            .kernel_backlog = 128, // Handle burst of connections
        });
        self.server = server;

        std.log.info("API server listening on port {d}", .{self.port});

        while (true) {
            const connection = server.accept() catch |err| {
                std.log.warn("Failed to accept connection: {}", .{err});
                continue;
            };

            // Spawn a thread to handle each connection concurrently
            const thread = std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, handleConnectionThread, .{ self, connection }) catch |err| {
                std.log.warn("Failed to spawn handler thread: {}", .{err});
                connection.stream.close();
                continue;
            };
            thread.detach();
        }
    }

    fn handleConnectionThread(self: *Server, connection: std.net.Server.Connection) void {
        defer connection.stream.close();
        self.handleConnection(connection) catch |err| {
            std.log.warn("Connection handler error: {}", .{err});
        };
    }

    fn handleConnection(self: *Server, connection: std.net.Server.Connection) !void {
        // Check per-IP rate limit before processing request.
        // Note: connection.address is the direct peer; if running behind a trusted
        // reverse proxy, use X-Forwarded-For (not yet wired — every visible client
        // would share the proxy's IP otherwise).
        if (!self.rate_limiter.tryAcquireFor(connection.address)) {
            try self.sendRateLimited(connection.stream);
            return;
        }

        // Read headers first (up to 4KB for headers)
        var header_buffer: [4096]u8 = undefined;
        var total_header_bytes: usize = 0;

        // Read until we find the end of headers (\r\n\r\n or \n\n)
        while (total_header_bytes < header_buffer.len) {
            const bytes_read = connection.stream.read(header_buffer[total_header_bytes..]) catch |err| {
                std.log.warn("Error reading request: {}", .{err});
                return;
            };
            if (bytes_read == 0) return;
            total_header_bytes += bytes_read;

            // Check if we have complete headers
            if (std.mem.indexOf(u8, header_buffer[0..total_header_bytes], "\r\n\r\n") != null or
                std.mem.indexOf(u8, header_buffer[0..total_header_bytes], "\n\n") != null)
            {
                break;
            }
        }

        if (total_header_bytes == 0) return;

        const header_data = header_buffer[0..total_header_bytes];

        // Find end of headers
        const header_end_crlf = std.mem.indexOf(u8, header_data, "\r\n\r\n");
        const header_end_lf = std.mem.indexOf(u8, header_data, "\n\n");
        const header_end = if (header_end_crlf) |pos| pos else if (header_end_lf) |pos| pos else {
            return; // No complete headers found
        };
        const body_offset: usize = if (header_end_crlf != null) 4 else 2;

        // Parse Content-Length from headers
        var content_length: usize = 0;
        var header_lines = std.mem.splitSequence(u8, header_data[0..header_end], "\r\n");
        while (header_lines.next()) |line| {
            if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
                const value = std.mem.trim(u8, line["content-length:".len..], " \t");
                content_length = std.fmt.parseInt(usize, value, 10) catch 0;
                break;
            }
        }
        // Also try \n separator
        if (content_length == 0) {
            var header_lines_lf = std.mem.splitScalar(u8, header_data[0..header_end], '\n');
            while (header_lines_lf.next()) |line| {
                const trimmed = std.mem.trimRight(u8, line, "\r");
                if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
                    const value = std.mem.trim(u8, trimmed["content-length:".len..], " \t");
                    content_length = std.fmt.parseInt(usize, value, 10) catch 0;
                    break;
                }
            }
        }

        // SECURITY: Limit max body size to 64KB to prevent DoS
        const max_body_size: usize = 65536;
        if (content_length > max_body_size) {
            try self.sendBadRequest(connection.stream, "Request body too large (max 64KB)");
            return;
        }

        // Calculate how much body we already have in buffer
        const body_start_in_buffer = header_end + body_offset;
        const body_already_read = if (body_start_in_buffer < total_header_bytes)
            total_header_bytes - body_start_in_buffer
        else
            0;

        // Allocate full request buffer
        const total_size = header_end + body_offset + content_length;
        const request = self.allocator.alloc(u8, total_size) catch {
            try self.sendBadRequest(connection.stream, "Out of memory");
            return;
        };
        defer self.allocator.free(request);

        // Copy what we have
        @memcpy(request[0..total_header_bytes], header_data[0..total_header_bytes]);

        // Read remaining body if needed
        if (body_already_read < content_length) {
            var remaining = content_length - body_already_read;
            var offset = total_header_bytes;
            while (remaining > 0) {
                const bytes_read = connection.stream.read(request[offset..]) catch |err| {
                    std.log.warn("Error reading request body: {}", .{err});
                    return;
                };
                if (bytes_read == 0) break;
                offset += bytes_read;
                remaining -= @min(remaining, bytes_read);
            }
        }

        // Parse HTTP request line
        var lines = std.mem.splitScalar(u8, request, '\n');
        const request_line = lines.next() orelse return;

        var parts = std.mem.splitScalar(u8, request_line, ' ');
        const method = parts.next() orelse return;
        const path = parts.next() orelse return;

        std.log.debug("API request: {s} {s}", .{ method, path });

        // Handle CORS preflight requests for all endpoints
        if (std.mem.eql(u8, method, "OPTIONS")) {
            try self.sendCorsPreflightResponse(connection.stream);
            return;
        }

        // Route request
        if (std.mem.startsWith(u8, path, "/graphql")) {
            // Handle GraphQL queries (both GET and POST)
            if (std.mem.eql(u8, method, "POST")) {
                try self.handleGraphQLQuery(connection.stream, request);
            } else if (std.mem.eql(u8, method, "GET")) {
                try self.handleGraphQLPlayground(connection.stream);
            } else {
                try self.sendBadRequest(connection.stream, "Only GET and POST supported for GraphQL");
            }
        } else if (std.mem.startsWith(u8, path, "/webhooks") and !std.mem.startsWith(u8, path, "/api/webhooks")) {
            // Webhook management UI - only available if webhooks are enabled
            if (self.webhook_database == null) {
                try self.sendNotFound(connection.stream);
                return;
            }
            // Requires auth if password is set
            if (!self.checkWebhookAuth(request)) {
                try self.sendUnauthorized(connection.stream);
                return;
            }
            try self.handleWebhookUI(connection.stream);
        } else if (std.mem.startsWith(u8, path, "/api/webhooks")) {
            // Webhook API endpoints - only available if webhooks are enabled
            if (self.webhook_database == null) {
                try self.sendNotFound(connection.stream);
                return;
            }
            // Requires auth if password is set
            if (!self.checkWebhookAuth(request)) {
                try self.sendUnauthorized(connection.stream);
                return;
            }
            try self.handleWebhooksAPI(connection.stream, method, path, request);
        } else if (std.mem.startsWith(u8, path, "/api/name/")) {
            try self.handleNameQuery(connection.stream, path);
        } else if (std.mem.startsWith(u8, path, "/api/owner/")) {
            try self.handleOwnerQuery(connection.stream, path);
        } else if (std.mem.startsWith(u8, path, "/api/events")) {
            try self.handleEventsQuery(connection.stream);
        } else if (std.mem.startsWith(u8, path, "/api/health")) {
            try self.handleHealthCheck(connection.stream);
        } else if (std.mem.startsWith(u8, path, "/metrics")) {
            try self.handleMetrics(connection.stream);
        } else {
            try self.sendNotFound(connection.stream);
        }
    }

    fn handleNameQuery(self: *Server, stream: std.net.Stream, path: []const u8) !void {
        // Extract name from path: /api/name/{name}
        const name_start = "/api/name/".len;
        if (path.len <= name_start) {
            return try self.sendBadRequest(stream, "Name parameter required");
        }

        var name_end = name_start;
        while (name_end < path.len and path[name_end] != ' ' and path[name_end] != '?' and path[name_end] != '\r') {
            name_end += 1;
        }

        const name = path[name_start..name_end];

        // SECURITY: Validate name length to prevent DoS attacks (industry standard: DNS label limit)
        validation.validateEnsName(name) catch {
            return try self.sendBadRequest(stream, "Invalid name: length must be between 1 and 255 characters");
        };

        std.log.info("Querying name: {s}", .{name});

        // Compute namehash
        const nh = try @import("../types/hash.zig").namehash(self.allocator, name);

        // Query database
        const name_record = try self.database.getNameByNamehash(nh);

        if (name_record) |record| {
            var record_copy = record;
            defer record_copy.deinit(self.allocator);

            // Build JSON response
            var response_buf: std.ArrayList(u8) = .{};
            defer response_buf.deinit(self.allocator);

            const owner_hex = try record_copy.owner.toHex(self.allocator);
            defer self.allocator.free(owner_hex);

            const resolver_hex = try record_copy.resolver.toHex(self.allocator);
            defer self.allocator.free(resolver_hex);

            const registry_hex = try record_copy.registry.toHex(self.allocator);
            defer self.allocator.free(registry_hex);

            const namehash_hex = try record_copy.namehash.toHex(self.allocator);
            defer self.allocator.free(namehash_hex);

            // SECURITY: Escape name field using RFC 8259 compliant json_utils (industry standard)
            const name_escaped = try json_utils.escapeString(self.allocator, record_copy.name orelse "[unknown]");
            defer self.allocator.free(name_escaped);

            const writer = response_buf.writer(self.allocator);
            try writer.print("{{\"name\":\"{s}\",\"namehash\":\"{s}\",\"owner\":\"{s}\",\"resolver\":\"{s}\",\"registry\":\"{s}\",\"protocol\":\"{s}\",\"expiry\":{d},\"registry_locked\":{},\"migrated\":{},\"created_at\":{d},\"updated_at\":{d}}}", .{
                name_escaped,
                namehash_hex,
                owner_hex,
                resolver_hex,
                registry_hex,
                record_copy.protocol.toString(),
                record_copy.expiry,
                record_copy.registry_locked,
                record_copy.migrated,
                record_copy.created_at,
                record_copy.updated_at,
            });
            try self.sendJsonResponse(stream, 200, response_buf.items);
        } else {
            try self.sendNotFound(stream);
        }
    }

    fn handleOwnerQuery(self: *Server, stream: std.net.Stream, path: []const u8) !void {
        // Extract owner address from path: /api/owner/{address}
        const owner_start = "/api/owner/".len;
        if (path.len <= owner_start) {
            return try self.sendBadRequest(stream, "Owner address required");
        }

        var owner_end = owner_start;
        while (owner_end < path.len and path[owner_end] != ' ' and path[owner_end] != '?' and path[owner_end] != '\r') {
            owner_end += 1;
        }

        const owner_str = path[owner_start..owner_end];

        std.log.info("Querying owner: {s}", .{owner_str});

        // Parse owner address
        const owner = Address.fromHex(owner_str) catch {
            return try self.sendBadRequest(stream, "Invalid address format");
        };

        // Query database for all names owned by this address
        const names = try self.database.getNamesByOwner(owner, 100); // Limit to 100 names
        defer {
            for (names) |*name| {
                name.deinit(self.allocator);
            }
            self.allocator.free(names);
        }

        // Build JSON response
        var response_buf: std.ArrayList(u8) = .{};
        defer response_buf.deinit(self.allocator);

        const writer = response_buf.writer(self.allocator);
        try writer.writeAll("[");

        for (names, 0..) |name, i| {
            if (i > 0) try writer.writeAll(",");

            // SECURITY: Escape name field using RFC 8259 compliant json_utils (industry standard)
            const name_escaped = try json_utils.escapeString(self.allocator, name.name orelse "[unknown]");
            defer self.allocator.free(name_escaped);

            try writer.print("{{\"name\":\"{s}\",\"expiry\":{d},\"owner\":\"{s}\"}}", .{ name_escaped, name.expiry, owner_str });
        }

        try writer.writeAll("]");
        try self.sendJsonResponse(stream, 200, response_buf.items);
    }

    fn handleEventsQuery(self: *Server, stream: std.net.Stream) !void {
        // Query recent events from database (last 50)
        const events = try self.database.getRecentEvents(null, null, 50);
        defer {
            for (events) |*event| {
                event.deinit(self.allocator);
            }
            self.allocator.free(events);
        }

        // Build JSON response
        var response_buf: std.ArrayList(u8) = .{};
        defer response_buf.deinit(self.allocator);

        try response_buf.appendSlice(self.allocator, "[");
        for (events, 0..) |event, i| {
            if (i > 0) try response_buf.appendSlice(self.allocator, ",");

            const event_json = try std.fmt.allocPrint(self.allocator, "{{\"type\":\"{s}\",\"block\":{d},\"timestamp\":{d}}}", .{
                event.event_type.toString(),
                event.block_number,
                event.timestamp,
            });
            defer self.allocator.free(event_json);

            try response_buf.appendSlice(self.allocator, event_json);
        }
        try response_buf.appendSlice(self.allocator, "]");

        try self.sendJsonResponse(stream, 200, response_buf.items);
    }

    fn handleHealthCheck(self: *Server, stream: std.net.Stream) !void {
        const response =
            \\{"status":"ok","service":"ensv2-indexer"}
        ;
        try self.sendJsonResponse(stream, 200, response);
    }

    fn handleMetrics(self: *Server, stream: std.net.Stream) !void {
        // Get metrics from GraphQL handler and format as Prometheus
        const metrics_text = try self.graphql_handler.metrics.formatPrometheus(self.allocator);
        defer self.allocator.free(metrics_text);

        var response: std.ArrayList(u8) = .{};
        defer response.deinit(self.allocator);

        const writer = response.writer(self.allocator);
        try writer.print(
            "HTTP/1.1 200 OK\r\n" ++
                "Content-Type: text/plain; version=0.0.4\r\n" ++
                "Content-Length: {d}\r\n" ++
                "\r\n" ++
                "{s}",
            .{ metrics_text.len, metrics_text },
        );

        _ = try stream.write(response.items);
    }

    fn handleGraphQLQuery(self: *Server, stream: std.net.Stream, request: []const u8) !void {
        // Extract GraphQL query from POST body
        // Find the body after double newline
        const body_start = std.mem.indexOf(u8, request, "\r\n\r\n") orelse std.mem.indexOf(u8, request, "\n\n") orelse {
            return try self.sendBadRequest(stream, "Invalid request format");
        };

        const body = request[body_start + 4 ..];

        // Parse JSON body to extract query and variables
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch {
            return try self.sendBadRequest(stream, "Invalid JSON body");
        };
        defer parsed.deinit();

        // Body must be a JSON object. Null, arrays, primitives, etc. would panic on .object access.
        if (parsed.value != .object) {
            return try self.sendBadRequest(stream, "Request body must be a JSON object");
        }

        const query_value = parsed.value.object.get("query") orelse {
            return try self.sendBadRequest(stream, "Query field required");
        };

        // Query must be a string. Integer/null/etc. would panic on .string access.
        if (query_value != .string) {
            return try self.sendBadRequest(stream, "`query` field must be a string");
        }
        const query = query_value.string;

        // SECURITY: Validate GraphQL query length to prevent DoS attacks
        validation.validateGraphQLQuery(query) catch {
            return try self.sendBadRequest(stream, "Invalid GraphQL query: length must be between 1 and 10000 characters");
        };

        // Extract variables if present (optional)
        const variables_value = parsed.value.object.get("variables");

        // Extract operationName if present (optional, used when query has multiple operations)
        const operation_name: ?[]const u8 = if (parsed.value.object.get("operationName")) |op_val|
            if (op_val == .string) op_val.string else null
        else
            null;

        std.log.info("GraphQL query: {s}", .{query});
        if (variables_value) |v| {
            std.log.info("Variables provided: {any}", .{v});
        }
        if (operation_name) |name| {
            std.log.info("Operation name: {s}", .{name});
        }

        // Handle the query with variables and operation name
        const result = try self.graphql_handler.handleQuery(query, variables_value, operation_name);
        defer self.allocator.free(result);

        try self.sendJsonResponse(stream, 200, result);
    }

    fn handleGraphQLPlayground(self: *Server, stream: std.net.Stream) !void {
        const html = @embedFile("graphiql.html");

        var response: std.ArrayList(u8) = .{};
        defer response.deinit(self.allocator);

        const writer = response.writer(self.allocator);
        try writer.print(
            "HTTP/1.1 200 OK\r\n" ++
                "Content-Type: text/html\r\n" ++
                "Content-Length: {d}\r\n" ++
                "Access-Control-Allow-Origin: *\r\n" ++
                "\r\n" ++
                "{s}",
            .{ html.len, html },
        );

        _ = try stream.write(response.items);
    }

    fn sendJsonResponse(self: *Server, stream: std.net.Stream, status: u16, body: []const u8) !void {
        const status_text = if (status == 200) "OK" else "Error";

        var response: std.ArrayList(u8) = .{};
        defer response.deinit(self.allocator);

        const writer = response.writer(self.allocator);
        try writer.print(
            "HTTP/1.1 {d} {s}\r\n" ++
                "Content-Type: application/json\r\n" ++
                "Content-Length: {d}\r\n" ++
                "Access-Control-Allow-Origin: *\r\n" ++
                "\r\n" ++
                "{s}",
            .{ status, status_text, body.len, body },
        );

        _ = try stream.write(response.items);
    }

    fn sendNotFound(self: *Server, stream: std.net.Stream) !void {
        const response =
            \\{"error":"Not found"}
        ;
        try self.sendJsonResponse(stream, 404, response);
    }

    fn sendBadRequest(self: *Server, stream: std.net.Stream, message: []const u8) !void {
        const response = try std.fmt.allocPrint(self.allocator, "{{\"error\":\"{s}\"}}", .{message});
        defer self.allocator.free(response);

        try self.sendJsonResponse(stream, 400, response);
    }

    fn sendRateLimited(self: *Server, stream: std.net.Stream) !void {
        const response =
            \\{"error":"Too many requests. Please try again later."}
        ;
        try self.sendJsonResponse(stream, 429, response);
    }

    fn sendCorsPreflightResponse(_: *Server, stream: std.net.Stream) !void {
        const response =
            "HTTP/1.1 204 No Content\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" ++
            "Access-Control-Allow-Headers: Content-Type, Authorization\r\n" ++
            "Access-Control-Max-Age: 86400\r\n" ++
            "\r\n";

        _ = try stream.write(response);
    }

    fn sendUnauthorized(_: *Server, stream: std.net.Stream) !void {
        const body = "{\"error\":\"Authentication required\"}";
        const header = "HTTP/1.1 401 Unauthorized\r\n" ++
            "Content-Type: application/json\r\n" ++
            "WWW-Authenticate: Basic realm=\"Webhook Admin\"\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "Content-Length: " ++ std.fmt.comptimePrint("{d}", .{body.len}) ++ "\r\n" ++
            "\r\n";

        _ = try stream.write(header);
        _ = try stream.write(body);
    }

    /// Check Basic Auth credentials from request headers
    /// Returns true if auth is valid or not required, false if auth failed
    fn checkWebhookAuth(self: *Server, request: []const u8) bool {
        // If no password is set, allow all requests (auth disabled)
        const required_password = self.webhook_admin_password orelse return true;
        const required_username = self.webhook_admin_username orelse return true;

        // Find Authorization header
        var lines = std.mem.splitSequence(u8, request, "\r\n");
        while (lines.next()) |line| {
            if (std.ascii.startsWithIgnoreCase(line, "authorization:")) {
                const header_value = std.mem.trim(u8, line["authorization:".len..], " ");

                // Check for Basic auth
                if (std.ascii.startsWithIgnoreCase(header_value, "basic ")) {
                    const encoded = std.mem.trim(u8, header_value["basic ".len..], " ");

                    // Decode base64
                    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return false;
                    if (decoded_len > 256) return false;

                    var decoded_buf: [256]u8 = undefined;
                    std.base64.standard.Decoder.decode(&decoded_buf, encoded) catch return false;
                    const decoded = decoded_buf[0..decoded_len];

                    // Format is "username:password"
                    if (std.mem.indexOf(u8, decoded, ":")) |colon_pos| {
                        const username = decoded[0..colon_pos];
                        const password = decoded[colon_pos + 1 ..];
                        return std.mem.eql(u8, username, required_username) and std.mem.eql(u8, password, required_password);
                    }
                }
                return false;
            }
        }
        return false;
    }

    // ========================================================================
    // WEBHOOK MANAGEMENT ENDPOINTS
    // ========================================================================

    fn handleWebhooksAPI(self: *Server, stream: std.net.Stream, method: []const u8, path: []const u8, request: []const u8) !void {
        // Parse path to determine webhook ID if present
        // /api/webhooks OR /api/webhooks/123
        const base_path = "/api/webhooks";
        const webhook_id_start = base_path.len;

        if (std.mem.eql(u8, method, "GET")) {
            if (path.len > webhook_id_start + 1) {
                // GET /api/webhooks/:id - Get single webhook
                var id_end = webhook_id_start + 1;
                while (id_end < path.len and path[id_end] != ' ' and path[id_end] != '?' and path[id_end] != '\r') {
                    id_end += 1;
                }
                const id_str = path[webhook_id_start + 1 .. id_end];
                const webhook_id = std.fmt.parseInt(u64, id_str, 10) catch {
                    return try self.sendBadRequest(stream, "Invalid webhook ID");
                };

                try self.handleGetWebhook(stream, webhook_id);
            } else {
                // GET /api/webhooks - List all webhooks
                try self.handleListWebhooks(stream);
            }
        } else if (std.mem.eql(u8, method, "POST")) {
            // POST /api/webhooks - Create new webhook
            try self.handleCreateWebhook(stream, request);
        } else if (std.mem.eql(u8, method, "PATCH")) {
            // PATCH /api/webhooks/:id - Update webhook
            if (path.len <= webhook_id_start + 1) {
                return try self.sendBadRequest(stream, "Webhook ID required");
            }

            var id_end = webhook_id_start + 1;
            while (id_end < path.len and path[id_end] != ' ' and path[id_end] != '?' and path[id_end] != '\r') {
                id_end += 1;
            }
            const id_str = path[webhook_id_start + 1 .. id_end];
            const webhook_id = std.fmt.parseInt(u64, id_str, 10) catch {
                return try self.sendBadRequest(stream, "Invalid webhook ID");
            };

            try self.handleUpdateWebhook(stream, webhook_id, request);
        } else if (std.mem.eql(u8, method, "DELETE")) {
            // DELETE /api/webhooks/:id - Delete webhook
            if (path.len <= webhook_id_start + 1) {
                return try self.sendBadRequest(stream, "Webhook ID required");
            }

            var id_end = webhook_id_start + 1;
            while (id_end < path.len and path[id_end] != ' ' and path[id_end] != '?' and path[id_end] != '\r') {
                id_end += 1;
            }
            const id_str = path[webhook_id_start + 1 .. id_end];
            const webhook_id = std.fmt.parseInt(u64, id_str, 10) catch {
                return try self.sendBadRequest(stream, "Invalid webhook ID");
            };

            try self.handleDeleteWebhook(stream, webhook_id);
        } else {
            try self.sendBadRequest(stream, "Method not allowed");
        }
    }

    fn handleListWebhooks(self: *Server, stream: std.net.Stream) !void {
        const webhook_db = self.webhook_database orelse {
            return try self.sendJsonResponse(stream, 503, "{\"error\":\"Webhooks not enabled\"}");
        };
        const webhooks = try webhook_db.getWebhooks();
        defer {
            for (webhooks) |*wh| {
                wh.deinit(self.allocator);
            }
            self.allocator.free(webhooks);
        }

        var response_buf: std.ArrayList(u8) = .{};
        defer response_buf.deinit(self.allocator);

        try response_buf.appendSlice(self.allocator, "[");
        for (webhooks, 0..) |webhook, i| {
            if (i > 0) try response_buf.appendSlice(self.allocator, ",");

            // Serialize event_types
            var event_types_json: std.ArrayList(u8) = .{};
            defer event_types_json.deinit(self.allocator);
            try event_types_json.appendSlice(self.allocator, "[");
            for (webhook.event_types, 0..) |et, j| {
                if (j > 0) try event_types_json.appendSlice(self.allocator, ",");
                const et_quoted = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{et.toString()});
                defer self.allocator.free(et_quoted);
                try event_types_json.appendSlice(self.allocator, et_quoted);
            }
            try event_types_json.appendSlice(self.allocator, "]");

            const webhook_json = try std.fmt.allocPrint(
                self.allocator,
                "{{\"id\":{d},\"url\":\"{s}\",\"event_types\":{s},\"active\":{},\"max_retries\":{d},\"created_at\":{d}}}",
                .{ webhook.id, webhook.url, event_types_json.items, webhook.active, webhook.max_retries, webhook.created_at },
            );
            defer self.allocator.free(webhook_json);
            try response_buf.appendSlice(self.allocator, webhook_json);
        }
        try response_buf.appendSlice(self.allocator, "]");

        try self.sendJsonResponse(stream, 200, response_buf.items);
    }

    fn handleGetWebhook(self: *Server, stream: std.net.Stream, webhook_id: u64) !void {
        const webhook_db = self.webhook_database orelse {
            return try self.sendJsonResponse(stream, 503, "{\"error\":\"Webhooks not enabled\"}");
        };
        const webhook_opt = try webhook_db.getWebhook(webhook_id);

        if (webhook_opt) |webhook| {
            var wh = webhook;
            defer wh.deinit(self.allocator);

            // Serialize event_types
            var event_types_json: std.ArrayList(u8) = .{};
            defer event_types_json.deinit(self.allocator);
            try event_types_json.appendSlice(self.allocator, "[");
            for (wh.event_types, 0..) |et, i| {
                if (i > 0) try event_types_json.appendSlice(self.allocator, ",");
                const et_quoted = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{et.toString()});
                defer self.allocator.free(et_quoted);
                try event_types_json.appendSlice(self.allocator, et_quoted);
            }
            try event_types_json.appendSlice(self.allocator, "]");

            const webhook_json = try std.fmt.allocPrint(
                self.allocator,
                "{{\"id\":{d},\"url\":\"{s}\",\"event_types\":{s},\"active\":{},\"max_retries\":{d},\"created_at\":{d}}}",
                .{ wh.id, wh.url, event_types_json.items, wh.active, wh.max_retries, wh.created_at },
            );
            defer self.allocator.free(webhook_json);

            try self.sendJsonResponse(stream, 200, webhook_json);
        } else {
            try self.sendNotFound(stream);
        }
    }

    fn handleCreateWebhook(self: *Server, stream: std.net.Stream, request: []const u8) !void {
        if (self.webhook_database == null) {
            return try self.sendJsonResponse(stream, 503, "{\"error\":\"Webhooks not enabled\"}");
        }

        // Extract JSON body
        const body_start = std.mem.indexOf(u8, request, "\r\n\r\n") orelse std.mem.indexOf(u8, request, "\n\n") orelse {
            return try self.sendBadRequest(stream, "Invalid request format");
        };
        const body = request[body_start + 4 ..];

        // Parse JSON body
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch {
            return try self.sendBadRequest(stream, "Invalid JSON body");
        };
        defer parsed.deinit();

        const obj = parsed.value.object;

        // Extract fields
        const url = obj.get("url") orelse {
            return try self.sendBadRequest(stream, "url field required");
        };

        // SECURITY: Validate webhook URL (SSRF protection, protocol validation, etc.)
        url_utils.validateWebhookUrl(url.string) catch |err| {
            const err_msg = switch (err) {
                error.UrlEmpty => "URL cannot be empty",
                error.UrlTooLong => "URL exceeds maximum length",
                error.InvalidUrlProtocol => "Only HTTP and HTTPS protocols are allowed",
                error.InvalidUrlFormat => "Invalid URL format",
                error.PrivateIpNotAllowed => "Private IPs and localhost are not allowed",
                error.NullByteInUrl => "URL contains invalid null byte",
                error.ControlCharacterInUrl => "URL contains invalid control characters",
            };
            return try self.sendBadRequest(stream, err_msg);
        };

        // Parse event_types array
        var event_types: std.ArrayList(models.EventType) = .{};
        defer event_types.deinit(self.allocator);

        if (obj.get("event_types")) |et_value| {
            const et_array = et_value.array;
            for (et_array.items) |et_item| {
                const et_str = et_item.string;
                // Accept the spec name ("NameRegistered") from the API surface. stringToEnum
                // would match only the internal variant name ("name_registered") — wrong direction.
                if (models.EventType.fromString(et_str)) |et| {
                    try event_types.append(self.allocator, et);
                }
            }
        }

        const active = if (obj.get("active")) |a| a.bool else true;
        const max_retries = if (obj.get("max_retries")) |mr| @as(u32, @intCast(mr.integer)) else 3;

        // Generate a fresh HMAC secret for this webhook. This is the ONLY time the
        // secret is returned to the caller — it's not retrievable later.
        const secret = try webhook_manager.generateWebhookSecret(self.allocator);
        defer self.allocator.free(secret);

        // Create webhook
        const webhook = models.Webhook{
            .id = 0, // Will be set by database
            .url = url.string,
            .secret = secret,
            .event_types = try event_types.toOwnedSlice(self.allocator),
            .active = active,
            .max_retries = max_retries,
            .created_at = std.time.timestamp(),
        };

        const webhook_id = try self.webhook_database.?.insertWebhook(webhook);

        const response = try std.fmt.allocPrint(
            self.allocator,
            "{{\"id\":{d},\"secret\":\"{s}\",\"message\":\"Webhook created. Store the secret — it is NOT retrievable later. Verify deliveries by computing HMAC-SHA256(secret, \\\"<X-Webhook-Timestamp>.<body>\\\") and comparing to X-Webhook-Signature.\"}}",
            .{ webhook_id, secret },
        );
        defer self.allocator.free(response);

        try self.sendJsonResponse(stream, 201, response);
    }

    fn handleUpdateWebhook(self: *Server, stream: std.net.Stream, webhook_id: u64, request: []const u8) !void {
        if (self.webhook_database == null) {
            return try self.sendJsonResponse(stream, 503, "{\"error\":\"Webhooks not enabled\"}");
        }

        // Extract JSON body
        const body_start = std.mem.indexOf(u8, request, "\r\n\r\n") orelse std.mem.indexOf(u8, request, "\n\n") orelse {
            return try self.sendBadRequest(stream, "Invalid request format");
        };
        const body = request[body_start + 4 ..];

        // Parse JSON body
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch {
            return try self.sendBadRequest(stream, "Invalid JSON body");
        };
        defer parsed.deinit();

        const obj = parsed.value.object;

        // Extract fields (all optional for PATCH)
        const url: ?[]const u8 = if (obj.get("url")) |u| u.string else null;

        // Parse event_types array if present
        var event_types: ?[]const models.EventType = null;
        var event_types_list: std.ArrayList(models.EventType) = .{};
        defer {
            if (event_types == null) {
                event_types_list.deinit(self.allocator);
            }
        }

        if (obj.get("event_types")) |et_value| {
            const et_array = et_value.array;
            for (et_array.items) |et_item| {
                const et_str = et_item.string;
                if (models.EventType.fromString(et_str)) |et| {
                    try event_types_list.append(self.allocator, et);
                }
            }
            event_types = try event_types_list.toOwnedSlice(self.allocator);
        }

        const active: ?bool = if (obj.get("active")) |a| a.bool else null;

        // Update webhook
        try self.webhook_database.?.updateWebhook(webhook_id, url, event_types, active);

        // Cleanup event_types if allocated
        if (event_types) |et| {
            self.allocator.free(et);
        }

        const response = try std.fmt.allocPrint(self.allocator, "{{\"id\":{d},\"message\":\"Webhook updated\"}}", .{webhook_id});
        defer self.allocator.free(response);

        try self.sendJsonResponse(stream, 200, response);
    }

    fn handleDeleteWebhook(self: *Server, stream: std.net.Stream, webhook_id: u64) !void {
        if (self.webhook_database == null) {
            return try self.sendJsonResponse(stream, 503, "{\"error\":\"Webhooks not enabled\"}");
        }
        try self.webhook_database.?.deleteWebhook(webhook_id);

        const response = try std.fmt.allocPrint(self.allocator, "{{\"id\":{d},\"message\":\"Webhook deleted\"}}", .{webhook_id});
        defer self.allocator.free(response);

        try self.sendJsonResponse(stream, 200, response);
    }

    fn handleWebhookUI(self: *Server, stream: std.net.Stream) !void {
        const html =
            \\<!DOCTYPE html>
            \\<html>
            \\<head>
            \\  <title>ENSv2 Webhook Management</title>
            \\  <meta name="viewport" content="width=device-width, initial-scale=1">
            \\  <style>
            \\    * { box-sizing: border-box; }
            \\    body {
            \\      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            \\      max-width: 1400px;
            \\      margin: 0 auto;
            \\      padding: 40px 20px;
            \\      background: #f8f9fa;
            \\      min-height: 100vh;
            \\      color: #1a1a1a;
            \\    }
            \\    h1 {
            \\      color: #1a1a1a;
            \\      text-align: left;
            \\      font-size: 1.75rem;
            \\      font-weight: 600;
            \\      margin-bottom: 32px;
            \\      letter-spacing: -0.5px;
            \\    }
            \\    h2 {
            \\      font-size: 1rem;
            \\      font-weight: 600;
            \\      color: #1a1a1a;
            \\      margin-bottom: 20px;
            \\      text-transform: uppercase;
            \\      letter-spacing: 0.5px;
            \\    }
            \\    .container {
            \\      background: #fff;
            \\      padding: 28px;
            \\      border-radius: 8px;
            \\      border: 1px solid #e5e5e5;
            \\      margin-bottom: 24px;
            \\    }
            \\    .form-grid {
            \\      display: grid;
            \\      grid-template-columns: 1fr 340px;
            \\      gap: 32px;
            \\    }
            \\    @media (max-width: 900px) {
            \\      .form-grid { grid-template-columns: 1fr; }
            \\    }
            \\    .event-categories {
            \\      display: grid;
            \\      grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
            \\      gap: 16px;
            \\      margin-top: 12px;
            \\    }
            \\    .event-category {
            \\      border: 1px solid #e5e5e5;
            \\      border-radius: 6px;
            \\      padding: 16px;
            \\      background: #fafafa;
            \\    }
            \\    .category-title {
            \\      font-weight: 600;
            \\      color: #666;
            \\      margin-bottom: 12px;
            \\      font-size: 11px;
            \\      text-transform: uppercase;
            \\      letter-spacing: 0.8px;
            \\      display: flex;
            \\      justify-content: space-between;
            \\      align-items: center;
            \\    }
            \\    .select-all {
            \\      font-size: 10px;
            \\      color: #888;
            \\      cursor: pointer;
            \\      text-decoration: none;
            \\      font-weight: 500;
            \\    }
            \\    .select-all:hover {
            \\      color: #1a1a1a;
            \\    }
            \\    .checkbox-item {
            \\      display: flex;
            \\      align-items: center;
            \\      margin-bottom: 8px;
            \\      cursor: pointer;
            \\    }
            \\    .checkbox-item input[type="checkbox"] {
            \\      width: 16px;
            \\      height: 16px;
            \\      margin-right: 10px;
            \\      cursor: pointer;
            \\      accent-color: #1a1a1a;
            \\    }
            \\    .checkbox-item label {
            \\      cursor: pointer;
            \\      font-size: 13px;
            \\      color: #444;
            \\      user-select: none;
            \\    }
            \\    .summary-panel {
            \\      position: sticky;
            \\      top: 20px;
            \\      border: 1px solid #e5e5e5;
            \\      border-radius: 6px;
            \\      padding: 20px;
            \\      background: #fafafa;
            \\      max-height: 600px;
            \\      overflow-y: auto;
            \\    }
            \\    .summary-title {
            \\      font-weight: 600;
            \\      font-size: 11px;
            \\      color: #666;
            \\      margin-bottom: 16px;
            \\      display: flex;
            \\      align-items: center;
            \\      gap: 10px;
            \\      text-transform: uppercase;
            \\      letter-spacing: 0.8px;
            \\    }
            \\    .summary-count {
            \\      background: #1a1a1a;
            \\      color: #fff;
            \\      padding: 2px 8px;
            \\      border-radius: 10px;
            \\      font-size: 11px;
            \\    }
            \\    .summary-empty {
            \\      color: #888;
            \\      font-size: 13px;
            \\      text-align: center;
            \\      padding: 20px 0;
            \\    }
            \\    .summary-events {
            \\      display: flex;
            \\      flex-wrap: wrap;
            \\      gap: 6px;
            \\    }
            \\    .summary-event-tag {
            \\      background: #fff;
            \\      border: 1px solid #ddd;
            \\      color: #444;
            \\      padding: 5px 10px;
            \\      border-radius: 4px;
            \\      font-size: 11px;
            \\      font-weight: 500;
            \\    }
            \\    .summary-event-tag.all {
            \\      background: #1a1a1a;
            \\      border-color: #1a1a1a;
            \\      color: #fff;
            \\      font-weight: 600;
            \\    }
            \\    table {
            \\      width: 100%;
            \\      border-collapse: collapse;
            \\      margin-top: 16px;
            \\      font-size: 13px;
            \\    }
            \\    th, td {
            \\      text-align: left;
            \\      padding: 12px 16px;
            \\      border-bottom: 1px solid #eee;
            \\    }
            \\    th {
            \\      background: #fafafa;
            \\      color: #666;
            \\      font-weight: 600;
            \\      font-size: 11px;
            \\      text-transform: uppercase;
            \\      letter-spacing: 0.5px;
            \\      border-bottom: 1px solid #e5e5e5;
            \\    }
            \\    tr:hover td {
            \\      background: #fafafa;
            \\    }
            \\    button {
            \\      padding: 8px 16px;
            \\      border: 1px solid #ddd;
            \\      border-radius: 4px;
            \\      cursor: pointer;
            \\      font-size: 13px;
            \\      font-weight: 500;
            \\      margin-right: 6px;
            \\      transition: all 0.15s ease;
            \\      background: #fff;
            \\      color: #444;
            \\    }
            \\    button:hover {
            \\      border-color: #999;
            \\      background: #fafafa;
            \\    }
            \\    .btn-primary {
            \\      background: #1a1a1a;
            \\      border-color: #1a1a1a;
            \\      color: #fff;
            \\    }
            \\    .btn-primary:hover {
            \\      background: #333;
            \\      border-color: #333;
            \\    }
            \\    .btn-danger {
            \\      background: #fff;
            \\      border-color: #ccc;
            \\      color: #666;
            \\    }
            \\    .btn-danger:hover {
            \\      background: #f5f5f5;
            \\      border-color: #999;
            \\      color: #333;
            \\    }
            \\    .btn-success {
            \\      background: #1a1a1a;
            \\      border-color: #1a1a1a;
            \\      color: #fff;
            \\    }
            \\    .btn-success:hover {
            \\      background: #333;
            \\      border-color: #333;
            \\    }
            \\    .btn-warning {
            \\      background: #fff;
            \\      border-color: #ccc;
            \\      color: #666;
            \\    }
            \\    .btn-warning:hover {
            \\      background: #f5f5f5;
            \\      border-color: #999;
            \\    }
            \\    .btn-edit {
            \\      background: #fff;
            \\      border-color: #ccc;
            \\      color: #666;
            \\    }
            \\    .btn-edit:hover {
            \\      background: #f5f5f5;
            \\      border-color: #999;
            \\    }
            \\    input[type="text"], input[type="url"] {
            \\      padding: 10px 12px;
            \\      border: 1px solid #ddd;
            \\      border-radius: 4px;
            \\      font-size: 14px;
            \\      width: 100%;
            \\      transition: border-color 0.15s ease;
            \\      background: #fff;
            \\    }
            \\    input[type="text"]:focus, input[type="url"]:focus {
            \\      outline: none;
            \\      border-color: #999;
            \\    }
            \\    .form-group {
            \\      margin-bottom: 20px;
            \\    }
            \\    .form-group label {
            \\      display: block;
            \\      margin-bottom: 8px;
            \\      font-weight: 500;
            \\      color: #444;
            \\      font-size: 13px;
            \\    }
            \\    .status-active {
            \\      color: #1a1a1a;
            \\      font-weight: 600;
            \\    }
            \\    .status-active::before {
            \\      content: "";
            \\      display: inline-block;
            \\      width: 6px;
            \\      height: 6px;
            \\      background: #1a1a1a;
            \\      border-radius: 50%;
            \\      margin-right: 6px;
            \\    }
            \\    .status-inactive {
            \\      color: #888;
            \\      font-weight: 500;
            \\    }
            \\    .status-inactive::before {
            \\      content: "";
            \\      display: inline-block;
            \\      width: 6px;
            \\      height: 6px;
            \\      background: #ccc;
            \\      border-radius: 50%;
            \\      margin-right: 6px;
            \\    }
            \\    .event-tag {
            \\      display: inline-block;
            \\      background: #f0f0f0;
            \\      padding: 3px 8px;
            \\      border-radius: 3px;
            \\      margin: 2px;
            \\      font-size: 11px;
            \\      color: #555;
            \\    }
            \\    #message {
            \\      padding: 14px 16px;
            \\      border-radius: 4px;
            \\      margin-bottom: 20px;
            \\      display: none;
            \\      font-weight: 500;
            \\      font-size: 13px;
            \\    }
            \\    #message.success {
            \\      background: #f8f9fa;
            \\      color: #1a1a1a;
            \\      border: 1px solid #ddd;
            \\      display: block;
            \\    }
            \\    #message.error {
            \\      background: #fafafa;
            \\      color: #666;
            \\      border: 1px solid #ddd;
            \\      display: block;
            \\    }
            \\    .modal {
            \\      display: none;
            \\      position: fixed;
            \\      z-index: 1000;
            \\      left: 0;
            \\      top: 0;
            \\      width: 100%;
            \\      height: 100%;
            \\      background: rgba(0,0,0,0.4);
            \\      backdrop-filter: blur(2px);
            \\    }
            \\    .modal-content {
            \\      background: #fff;
            \\      margin: 60px auto;
            \\      padding: 28px;
            \\      border-radius: 8px;
            \\      max-width: 900px;
            \\      max-height: 85vh;
            \\      overflow-y: auto;
            \\      box-shadow: 0 4px 24px rgba(0,0,0,0.15);
            \\    }
            \\    .modal-header {
            \\      display: flex;
            \\      justify-content: space-between;
            \\      align-items: center;
            \\      margin-bottom: 24px;
            \\      padding-bottom: 16px;
            \\      border-bottom: 1px solid #e5e5e5;
            \\    }
            \\    .modal-header h2 {
            \\      margin: 0;
            \\      color: #1a1a1a;
            \\      font-size: 1.1rem;
            \\    }
            \\    .close {
            \\      font-size: 24px;
            \\      font-weight: 300;
            \\      color: #999;
            \\      cursor: pointer;
            \\      line-height: 1;
            \\    }
            \\    .close:hover {
            \\      color: #1a1a1a;
            \\    }
            \\  </style>
            \\</head>
            \\<body>
            \\  <h1>Webhook Management</h1>
            \\
            \\  <div id="message"></div>
            \\
            \\  <div class="container">
            \\    <h2>Create New Webhook</h2>
            \\    <form id="createForm">
            \\      <div class="form-grid">
            \\        <div>
            \\          <div class="form-group">
            \\            <label>Webhook URL:</label>
            \\            <input type="url" id="url" placeholder="https://your-server.com/webhook" required>
            \\          </div>
            \\
            \\          <div class="form-group">
            \\            <label>Select Event Types (leave unchecked for ALL events):</label>
            \\            <div class="event-categories">
            \\              <div class="event-category">
            \\                <div class="category-title">
            \\                  Registry
            \\                  <span class="select-all" data-category="registry" onclick="toggleCategory('registry')">Select All</span>
            \\                </div>
            \\                <div class="checkbox-item">
            \\                  <input type="checkbox" id="new_subname" value="new_subname" class="event-checkbox registry-event">
            \\                  <label for="new_subname">NewSubname</label>
            \\                </div>
            \\                <div class="checkbox-item">
            \\                  <input type="checkbox" id="subregistry_update" value="subregistry_update" class="event-checkbox registry-event">
            \\                  <label for="subregistry_update">SubregistryUpdate</label>
            \\                </div>
            \\                <div class="checkbox-item">
            \\                  <input type="checkbox" id="resolver_update" value="resolver_update" class="event-checkbox registry-event">
            \\                  <label for="resolver_update">ResolverUpdate</label>
            \\                </div>
            \\                <div class="checkbox-item">
            \\                  <input type="checkbox" id="transfer" value="transfer" class="event-checkbox registry-event">
            \\                  <label for="transfer">Transfer</label>
            \\                </div>
            \\              </div>
            \\
            \\              <div class="event-category">
            \\                <div class="category-title">
            \\                  Registration
            \\                  <span class="select-all" data-category="registration" onclick="toggleCategory('registration')">Select All</span>
            \\                </div>
            \\                <div class="checkbox-item">
            \\                  <input type="checkbox" id="name_registered" value="name_registered" class="event-checkbox registration-event">
            \\                  <label for="name_registered">NameRegistered</label>
            \\                </div>
            \\                <div class="checkbox-item">
            \\                  <input type="checkbox" id="name_renewed" value="name_renewed" class="event-checkbox registration-event">
            \\                  <label for="name_renewed">NameRenewed</label>
            \\                </div>
            \\                <div class="checkbox-item">
            \\                  <input type="checkbox" id="name_burned" value="name_burned" class="event-checkbox registration-event">
            \\                  <label for="name_burned">NameBurned</label>
            \\                </div>
            \\                <div class="checkbox-item">
            \\                  <input type="checkbox" id="commitment_made" value="commitment_made" class="event-checkbox registration-event">
            \\                  <label for="commitment_made">CommitmentMade</label>
            \\                </div>
            \\              </div>
            \\
            \\              <div class="event-category">
            \\                <div class="category-title">
            \\                  Token & Other
            \\                  <span class="select-all" data-category="token" onclick="toggleCategory('token')">Select All</span>
            \\                </div>
            \\                <div class="checkbox-item">
            \\                  <input type="checkbox" id="token_regenerated" value="token_regenerated" class="event-checkbox token-event">
            \\                  <label for="token_regenerated">TokenRegenerated</label>
            \\                </div>
            \\                <div class="checkbox-item">
            \\                  <input type="checkbox" id="approval" value="approval" class="event-checkbox token-event">
            \\                  <label for="approval">Approval</label>
            \\                </div>
            \\                <div class="checkbox-item">
            \\                  <input type="checkbox" id="metadata_changed" value="metadata_changed" class="event-checkbox token-event">
            \\                  <label for="metadata_changed">MetadataChanged</label>
            \\                </div>
            \\                <div class="checkbox-item">
            \\                  <input type="checkbox" id="resolver_approved" value="resolver_approved" class="event-checkbox token-event">
            \\                  <label for="resolver_approved">ResolverApproved</label>
            \\                </div>
            \\              </div>
            \\
            \\              <div class="event-category">
            \\                <div class="category-title">
            \\              <div class="event-category">
            \\                <div class="category-title">
            \\                  Resolver Records
            \\                  <span class="select-all" data-category="resolver" onclick="toggleCategory('resolver')">Select All</span>
            \\                </div>
            \\                <div class="checkbox-item">
            \\                  <input type="checkbox" id="text_changed" value="text_changed" class="event-checkbox resolver-event">
            \\                  <label for="text_changed">TextChanged</label>
            \\                </div>
            \\                <div class="checkbox-item">
            \\                  <input type="checkbox" id="address_changed" value="address_changed" class="event-checkbox resolver-event">
            \\                  <label for="address_changed">AddressChanged</label>
            \\                </div>
            \\                <div class="checkbox-item">
            \\                  <input type="checkbox" id="contenthash_changed" value="contenthash_changed" class="event-checkbox resolver-event">
            \\                  <label for="contenthash_changed">ContenthashChanged</label>
            \\                </div>
            \\                <div class="checkbox-item">
            \\                  <input type="checkbox" id="abi_changed" value="abi_changed" class="event-checkbox resolver-event">
            \\                  <label for="abi_changed">ABIChanged</label>
            \\                </div>
            \\                <div class="checkbox-item">
            \\                  <input type="checkbox" id="pubkey_changed" value="pubkey_changed" class="event-checkbox resolver-event">
            \\                  <label for="pubkey_changed">PubkeyChanged</label>
            \\                </div>
            \\                <div class="checkbox-item">
            \\                  <input type="checkbox" id="name_changed" value="name_changed" class="event-checkbox resolver-event">
            \\                  <label for="name_changed">NameChanged</label>
            \\                </div>
            \\                <div class="checkbox-item">
            \\                  <input type="checkbox" id="interface_changed" value="interface_changed" class="event-checkbox resolver-event">
            \\                  <label for="interface_changed">InterfaceChanged</label>
            \\                </div>
            \\              </div>
            \\            </div>
            \\          </div>
            \\          <button type="submit" class="btn-success">Create Webhook</button>
            \\        </div>
            \\
            \\        <div class="summary-panel">
            \\          <div class="summary-title">
            \\            Subscription Summary
            \\            <span class="summary-count" id="summaryCount">0</span>
            \\          </div>
            \\          <div id="summaryContent" class="summary-empty">
            \\            No events selected. Webhook will receive ALL events.
            \\          </div>
            \\        </div>
            \\      </div>
            \\    </form>
            \\  </div>
            \\
            \\  <div class="container">
            \\    <h2>Existing Webhooks</h2>
            \\    <table id="webhooksTable">
            \\      <thead>
            \\        <tr>
            \\          <th>ID</th>
            \\          <th>URL</th>
            \\          <th>Event Types</th>
            \\          <th>Status</th>
            \\          <th>Max Retries</th>
            \\          <th>Actions</th>
            \\        </tr>
            \\      </thead>
            \\      <tbody id="webhooksList">
            \\        <tr><td colspan="6" style="text-align: center;">Loading webhooks...</td></tr>
            \\      </tbody>
            \\    </table>
            \\  </div>
            \\
            \\  <div id="editModal" class="modal">
            \\    <div class="modal-content">
            \\      <div class="modal-header">
            \\        <h2>Edit Webhook</h2>
            \\        <span class="close" onclick="closeEditModal()">&times;</span>
            \\      </div>
            \\      <form id="editForm">
            \\        <input type="hidden" id="editWebhookId">
            \\        <div class="form-grid">
            \\          <div>
            \\            <div class="form-group">
            \\              <label>Webhook URL:</label>
            \\              <input type="url" id="editUrl" required>
            \\            </div>
            \\            <div class="form-group">
            \\              <label>Select Event Types:</label>
            \\              <div class="event-categories" id="editEventCategories"></div>
            \\            </div>
            \\            <button type="submit" class="btn-primary">Save Changes</button>
            \\            <button type="button" class="btn-danger" onclick="closeEditModal()">Cancel</button>
            \\          </div>
            \\          <div class="summary-panel">
            \\            <div class="summary-title">
            \\              Subscription Summary
            \\              <span class="summary-count" id="editSummaryCount">0</span>
            \\            </div>
            \\            <div id="editSummaryContent" class="summary-empty">
            \\              No events selected. Webhook will receive ALL events.
            \\            </div>
            \\          </div>
            \\        </div>
            \\      </form>
            \\    </div>
            \\  </div>
            \\
            \\  <script>
            \\    const API_BASE = '/api/webhooks';
            \\
            \\    // Event type definitions grouped by category
            \\    const EVENT_CATEGORIES = {
            \\      registry: ['new_subname', 'subregistry_update', 'resolver_update', 'transfer'],
            \\      registration: ['name_registered', 'name_renewed', 'name_burned', 'commitment_made'],
            \\      token: ['token_regenerated', 'approval', 'metadata_changed', 'resolver_approved'],
            \\      resolver: ['text_changed', 'address_changed', 'contenthash_changed', 'abi_changed', 'pubkey_changed', 'name_changed', 'interface_changed']
            \\    };
            \\
            \\    const EVENT_DISPLAY_NAMES = {
            \\      'new_subname': 'NewSubname',
            \\      'subregistry_update': 'SubregistryUpdate',
            \\      'resolver_update': 'ResolverUpdate',
            \\      'transfer': 'Transfer',
            \\      'name_registered': 'NameRegistered',
            \\      'name_renewed': 'NameRenewed',
            \\      'name_burned': 'NameBurned',
            \\      'commitment_made': 'CommitmentMade',
            \\      'token_regenerated': 'TokenRegenerated',
            \\      'approval': 'Approval',
            \\      'metadata_changed': 'MetadataChanged',
            \\      'resolver_approved': 'ResolverApproved',
            \\      'text_changed': 'TextChanged',
            \\      'address_changed': 'AddressChanged',
            \\      'contenthash_changed': 'ContenthashChanged',
            \\      'abi_changed': 'ABIChanged',
            \\      'pubkey_changed': 'PubkeyChanged',
            \\      'name_changed': 'NameChanged',
            \\      'interface_changed': 'InterfaceChanged'
            \\    };
            \\
            \\    function showMessage(text, isError = false) {
            \\      const msg = document.getElementById('message');
            \\      msg.textContent = text;
            \\      msg.className = isError ? 'error' : 'success';
            \\      setTimeout(() => msg.className = '', 5000);
            \\    }
            \\
            \\    function updateSummary(isEdit = false) {
            \\      const checkboxes = document.querySelectorAll(isEdit ? '#editEventCategories .event-checkbox' : '.event-checkbox');
            \\      const selected = Array.from(checkboxes).filter(cb => cb.checked).map(cb => cb.value);
            \\
            \\      const count = selected.length;
            \\      const countEl = document.getElementById(isEdit ? 'editSummaryCount' : 'summaryCount');
            \\      const contentEl = document.getElementById(isEdit ? 'editSummaryContent' : 'summaryContent');
            \\
            \\      countEl.textContent = count;
            \\
            \\      if (count === 0) {
            \\        contentEl.className = 'summary-empty';
            \\        contentEl.innerHTML = '<div style="margin-bottom: 12px;">No events selected.</div><div>Webhook will receive <span class="summary-event-tag all">ALL EVENTS</span></div>';
            \\      } else {
            \\        contentEl.className = 'summary-events';
            \\        contentEl.innerHTML = selected.map(v =>
            \\          `<span class="summary-event-tag">${EVENT_DISPLAY_NAMES[v] || v}</span>`
            \\        ).join('');
            \\      }
            \\    }
            \\
            \\    function toggleCategory(category, container = document) {
            \\      const events = EVENT_CATEGORIES[category];
            \\      const checkboxes = events.map(e => container.querySelector(`#${e}`) || container.querySelector(`[value="${e}"]`)).filter(Boolean);
            \\      const allChecked = checkboxes.every(cb => cb.checked);
            \\      checkboxes.forEach(cb => cb.checked = !allChecked);
            \\      updateCategoryToggleText(category, container);
            \\      updateSummary(container !== document);
            \\    }
            \\
            \\    function updateCategoryToggleText(category, container = document) {
            \\      const events = EVENT_CATEGORIES[category];
            \\      const checkboxes = events.map(e => container.querySelector(`#${e}`) || container.querySelector(`[value="${e}"]`)).filter(Boolean);
            \\      const allChecked = checkboxes.every(cb => cb.checked);
            \\      const toggleEl = container.querySelector(`[data-category="${category}"]`);
            \\      if (toggleEl) {
            \\        toggleEl.textContent = allChecked ? 'Deselect All' : 'Select All';
            \\      }
            \\    }
            \\
            \\    function updateAllCategoryToggles(container = document) {
            \\      Object.keys(EVENT_CATEGORIES).forEach(cat => updateCategoryToggleText(cat, container));
            \\    }
            \\
            \\    // Legacy function name for backwards compatibility
            \\    function selectCategory(category) {
            \\      toggleCategory(category, document);
            \\    }
            \\
            \\    // Set up event listeners for create form checkboxes
            \\    document.addEventListener('DOMContentLoaded', () => {
            \\      document.querySelectorAll('.event-checkbox').forEach(cb => {
            \\        cb.addEventListener('change', () => {
            \\          updateSummary(false);
            \\          updateAllCategoryToggles(document);
            \\        });
            \\      });
            \\      updateSummary(false);
            \\      updateAllCategoryToggles(document);
            \\    });
            \\
            \\    async function loadWebhooks() {
            \\      try {
            \\        const response = await fetch(API_BASE);
            \\        const webhooks = await response.json();
            \\
            \\        const tbody = document.getElementById('webhooksList');
            \\        if (webhooks.length === 0) {
            \\          tbody.innerHTML = '<tr><td colspan="6" style="text-align: center;">No webhooks configured</td></tr>';
            \\          return;
            \\        }
            \\
            \\        tbody.innerHTML = webhooks.map(wh => `
            \\          <tr>
            \\            <td>${wh.id}</td>
            \\            <td style="word-break: break-all;">${wh.url}</td>
            \\            <td class="event-types">
            \\              ${wh.event_types.length === 0
            \\                ? '<span class="event-tag">ALL EVENTS</span>'
            \\                : wh.event_types.map(et => `<span class="event-tag">${EVENT_DISPLAY_NAMES[et] || et}</span>`).join('')
            \\              }
            \\            </td>
            \\            <td class="${wh.active ? 'status-active' : 'status-inactive'}">
            \\              ${wh.active ? '✓ Active' : '✗ Inactive'}
            \\            </td>
            \\            <td>${wh.max_retries}</td>
            \\            <td>
            \\              <button class="btn-edit" onclick='editWebhook(${JSON.stringify(wh)})'>✏ Edit</button>
            \\              <button class="btn-warning" onclick="toggleWebhook(${wh.id}, ${!wh.active})">
            \\                ${wh.active ? 'Disable' : 'Enable'}
            \\              </button>
            \\              <button class="btn-danger" onclick="deleteWebhook(${wh.id})">Delete</button>
            \\            </td>
            \\          </tr>
            \\        `).join('');
            \\      } catch (err) {
            \\        showMessage('Failed to load webhooks: ' + err.message, true);
            \\      }
            \\    }
            \\
            \\    function editWebhook(webhook) {
            \\      document.getElementById('editWebhookId').value = webhook.id;
            \\      document.getElementById('editUrl').value = webhook.url;
            \\
            \\      // Build checkbox categories for edit form
            \\      const container = document.getElementById('editEventCategories');
            \\      container.innerHTML = Object.entries(EVENT_CATEGORIES).map(([category, events]) => `
            \\        <div class="event-category">
            \\          <div class="category-title">
            \\            ${category.charAt(0).toUpperCase() + category.slice(1)}
            \\            <span class="select-all" data-category="${category}" onclick="toggleEditCategory('${category}')">Select All</span>
            \\          </div>
            \\          ${events.map(event => `
            \\            <div class="checkbox-item">
            \\              <input type="checkbox" id="edit_${event}" value="${event}" class="event-checkbox" ${webhook.event_types.includes(event) ? 'checked' : ''}>
            \\              <label for="edit_${event}">${EVENT_DISPLAY_NAMES[event]}</label>
            \\            </div>
            \\          `).join('')}
            \\        </div>
            \\      `).join('');
            \\
            \\      // Add event listeners
            \\      container.querySelectorAll('.event-checkbox').forEach(cb => {
            \\        cb.addEventListener('change', () => {
            \\          updateSummary(true);
            \\          updateAllEditCategoryToggles();
            \\        });
            \\      });
            \\
            \\      updateSummary(true);
            \\      updateAllEditCategoryToggles();
            \\      document.getElementById('editModal').style.display = 'block';
            \\    }
            \\
            \\    function toggleEditCategory(category) {
            \\      const container = document.getElementById('editEventCategories');
            \\      const events = EVENT_CATEGORIES[category];
            \\      const checkboxes = events.map(e => document.getElementById('edit_' + e)).filter(Boolean);
            \\      const allChecked = checkboxes.every(cb => cb.checked);
            \\      checkboxes.forEach(cb => cb.checked = !allChecked);
            \\      updateEditCategoryToggleText(category);
            \\      updateSummary(true);
            \\    }
            \\
            \\    function updateEditCategoryToggleText(category) {
            \\      const events = EVENT_CATEGORIES[category];
            \\      const checkboxes = events.map(e => document.getElementById('edit_' + e)).filter(Boolean);
            \\      const allChecked = checkboxes.every(cb => cb.checked);
            \\      const container = document.getElementById('editEventCategories');
            \\      const toggleEl = container.querySelector(`[data-category="${category}"]`);
            \\      if (toggleEl) {
            \\        toggleEl.textContent = allChecked ? 'Deselect All' : 'Select All';
            \\      }
            \\    }
            \\
            \\    function updateAllEditCategoryToggles() {
            \\      Object.keys(EVENT_CATEGORIES).forEach(cat => updateEditCategoryToggleText(cat));
            \\    }
            \\
            \\    function closeEditModal() {
            \\      document.getElementById('editModal').style.display = 'none';
            \\    }
            \\
            \\    document.getElementById('createForm').addEventListener('submit', async (e) => {
            \\      e.preventDefault();
            \\
            \\      const url = document.getElementById('url').value;
            \\      const eventTypes = Array.from(document.querySelectorAll('.event-checkbox:checked')).map(cb => cb.value);
            \\
            \\      try {
            \\        const response = await fetch(API_BASE, {
            \\          method: 'POST',
            \\          headers: { 'Content-Type': 'application/json' },
            \\          body: JSON.stringify({
            \\            url: url,
            \\            event_types: eventTypes,
            \\            active: true,
            \\            max_retries: 3
            \\          })
            \\        });
            \\
            \\        if (response.ok) {
            \\          showMessage('Webhook created successfully!');
            \\          document.getElementById('createForm').reset();
            \\          document.querySelectorAll('.event-checkbox').forEach(cb => cb.checked = false);
            \\          updateSummary(false);
            \\          loadWebhooks();
            \\        } else {
            \\          const error = await response.json();
            \\          showMessage('Failed to create webhook: ' + error.error, true);
            \\        }
            \\      } catch (err) {
            \\        showMessage('Failed to create webhook: ' + err.message, true);
            \\      }
            \\    });
            \\
            \\    document.getElementById('editForm').addEventListener('submit', async (e) => {
            \\      e.preventDefault();
            \\
            \\      const id = document.getElementById('editWebhookId').value;
            \\      const url = document.getElementById('editUrl').value;
            \\      const eventTypes = Array.from(document.querySelectorAll('#editEventCategories .event-checkbox:checked')).map(cb => cb.value);
            \\
            \\      try {
            \\        const response = await fetch(`${API_BASE}/${id}`, {
            \\          method: 'PATCH',
            \\          headers: { 'Content-Type': 'application/json' },
            \\          body: JSON.stringify({
            \\            url: url,
            \\            event_types: eventTypes
            \\          })
            \\        });
            \\
            \\        if (response.ok) {
            \\          showMessage('Webhook updated successfully!');
            \\          closeEditModal();
            \\          loadWebhooks();
            \\        } else {
            \\          const error = await response.json();
            \\          showMessage('Failed to update webhook: ' + error.error, true);
            \\        }
            \\      } catch (err) {
            \\        showMessage('Failed to update webhook: ' + err.message, true);
            \\      }
            \\    });
            \\
            \\    async function toggleWebhook(id, active) {
            \\      try {
            \\        const response = await fetch(`${API_BASE}/${id}`, {
            \\          method: 'PATCH',
            \\          headers: { 'Content-Type': 'application/json' },
            \\          body: JSON.stringify({ active: active })
            \\        });
            \\
            \\        if (response.ok) {
            \\          showMessage(`Webhook ${active ? 'enabled' : 'disabled'} successfully!`);
            \\          loadWebhooks();
            \\        } else {
            \\          const error = await response.json();
            \\          showMessage('Failed to update webhook: ' + error.error, true);
            \\        }
            \\      } catch (err) {
            \\        showMessage('Failed to update webhook: ' + err.message, true);
            \\      }
            \\    }
            \\
            \\    async function deleteWebhook(id) {
            \\      if (!confirm('Are you sure you want to delete this webhook?')) {
            \\        return;
            \\      }
            \\
            \\      try {
            \\        const response = await fetch(`${API_BASE}/${id}`, {
            \\          method: 'DELETE'
            \\        });
            \\
            \\        if (response.ok) {
            \\          showMessage('Webhook deleted successfully!');
            \\          loadWebhooks();
            \\        } else {
            \\          const error = await response.json();
            \\          showMessage('Failed to delete webhook: ' + error.error, true);
            \\        }
            \\      } catch (err) {
            \\        showMessage('Failed to delete webhook: ' + err.message, true);
            \\      }
            \\    }
            \\
            \\    window.onclick = function(event) {
            \\      const modal = document.getElementById('editModal');
            \\      if (event.target === modal) {
            \\        closeEditModal();
            \\      }
            \\    }
            \\
            \\    // Load webhooks on page load
            \\    loadWebhooks();
            \\  </script>
            \\</body>
            \\</html>
        ;

        var response: std.ArrayList(u8) = .{};
        defer response.deinit(self.allocator);

        const writer = response.writer(self.allocator);
        try writer.print(
            "HTTP/1.1 200 OK\r\n" ++
                "Content-Type: text/html; charset=utf-8\r\n" ++
                "Content-Length: {d}\r\n" ++
                "\r\n" ++
                "{s}",
            .{ html.len, html },
        );

        _ = try stream.write(response.items);
    }
};

test "Server init" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try db.Database.init(allocator, ":memory:");
    defer database.deinit();

    var server = try Server.init(allocator, &database, null, 8080, 10, 1000, false, 100, null, null);
    defer server.deinit();

    try std.testing.expect(server.port == 8080);
}
