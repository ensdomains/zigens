const std = @import("std");
const db = @import("../storage/database.zig");
const models = @import("../types/models.zig");
const Hash = @import("../types/hash.zig").Hash;
const Address = @import("../types/address.zig").Address;
const graphql = @import("handler.zig");
const json_utils = @import("../utils/json.zig");
const url_utils = @import("../utils/url.zig");
const validation = @import("../utils/validation.zig");
const RateLimiter = @import("../rate_limiter.zig").RateLimiter;

/// Simple JSON API Server for ENSv2 Indexer
/// Provides REST endpoints and GraphQL for querying indexed data
pub const Server = struct {
    allocator: std.mem.Allocator,
    database: *db.Database,
    webhook_database: ?*db.Database,  // Optional - only initialized if webhooks enabled
    port: u16,
    server: ?std.net.Server,
    graphql_handler: graphql.GraphQLHandler,
    rate_limiter: RateLimiter,

    pub fn init(allocator: std.mem.Allocator, database: *db.Database, webhook_db_path: ?[]const u8, port: u16, complexity_max_depth: u32, complexity_max_cost: u32, metrics_enabled: bool, rate_limit_per_second: u32) !Server {
        // Only open webhook database if path is provided (webhooks enabled)
        var webhook_db: ?*db.Database = null;
        if (webhook_db_path) |path| {
            const webhook_db_value = try db.Database.initWithoutSchema(allocator, path);
            webhook_db = try allocator.create(db.Database);
            webhook_db.?.* = webhook_db_value;
        }

        // Initialize rate limiter with configurable requests per second
        // Default burst capacity is 2x the per-second rate
        const rate_limit = if (rate_limit_per_second > 0) rate_limit_per_second else 100;

        return .{
            .allocator = allocator,
            .database = database,
            .webhook_database = webhook_db,
            .port = port,
            .server = null,
            .graphql_handler = try graphql.GraphQLHandler.init(allocator, database, complexity_max_depth, complexity_max_cost, metrics_enabled),
            .rate_limiter = RateLimiter.init(rate_limit * 2, rate_limit),
        };
    }

    pub fn deinit(self: *Server) void {
        self.graphql_handler.deinit();
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
        });
        self.server = server;

        std.log.info("API server listening on port {d}", .{self.port});

        while (true) {
            const connection = try server.accept();
            defer connection.stream.close();

            try self.handleConnection(connection);
        }
    }

    fn handleConnection(self: *Server, connection: std.net.Server.Connection) !void {
        // Check rate limit before processing request
        if (!self.rate_limiter.tryAcquire()) {
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
            // Webhook management UI
            try self.handleWebhookUI(connection.stream);
        } else if (std.mem.startsWith(u8, path, "/api/webhooks")) {
            // Webhook API endpoints
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
            try writer.print("{{\"name\":\"{s}\",\"namehash\":\"{s}\",\"owner\":\"{s}\",\"resolver\":\"{s}\",\"registry\":\"{s}\",\"chain\":\"{s}\",\"expiry\":{d},\"registry_locked\":{},\"migrated\":{},\"ejected\":{},\"created_at\":{d},\"updated_at\":{d}}}",
                .{
                    name_escaped,
                    namehash_hex,
                    owner_hex,
                    resolver_hex,
                    registry_hex,
                    record_copy.chain.toString(),
                    record_copy.expiry,
                    record_copy.registry_locked,
                    record_copy.migrated,
                    record_copy.ejected,
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

            try writer.print("{{\"name\":\"{s}\",\"expiry\":{d},\"owner\":\"{s}\"}}",
                .{ name_escaped, name.expiry, owner_str });
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

        const query_value = parsed.value.object.get("query") orelse {
            return try self.sendBadRequest(stream, "Query field required");
        };

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
        // Return GraphiQL - Interactive GraphQL IDE with autocomplete enabled
        const html =
            \\<!DOCTYPE html>
            \\<html>
            \\<head>
            \\  <title>ENSv2 GraphQL Playground</title>
            \\  <style>
            \\    body { height: 100%; margin: 0; width: 100%; overflow: hidden; }
            \\    #graphiql { height: 100vh; }
            \\  </style>
            \\  <script crossorigin src="https://unpkg.com/react@17/umd/react.production.min.js"></script>
            \\  <script crossorigin src="https://unpkg.com/react-dom@17/umd/react-dom.production.min.js"></script>
            \\  <link rel="stylesheet" href="https://unpkg.com/graphiql@2.4.7/graphiql.min.css" />
            \\</head>
            \\<body>
            \\  <div id="graphiql">Loading GraphQL Playground...</div>
            \\  <script src="https://unpkg.com/graphiql@2.4.7/graphiql.min.js" crossorigin></script>
            \\  <script>
            \\    // Custom fetcher function for GraphQL queries
            \\    function graphQLFetcher(graphQLParams) {
            \\      return fetch('/graphql', {
            \\        method: 'post',
            \\        headers: { 'Content-Type': 'application/json' },
            \\        body: JSON.stringify(graphQLParams),
            \\      }).then(response => response.json());
            \\    }
            \\
            \\    const defaultQuery = `# Welcome to ENSv2 GraphQL Playground!
            \\#
            \\# 🎯 Autocomplete Tips:
            \\#   - Press Ctrl+Space anywhere to see suggestions
            \\#   - Start typing a field name to get completions
            \\#   - Hover over fields to see type information
            \\#
            \\# Try these example queries:
            \\
            \\# Query a domain
            \\{
            \\  domain(id: "test.eth") {
            \\    name
            \\    owner { id }
            \\    resolver { address }
            \\    expiryDate
            \\    isMigrated
            \\  }
            \\}
            \\
            \\# Query all domains (first 10)
            \\# {
            \\#   domains(first: 10) {
            \\#     name
            \\#     owner { id }
            \\#   }
            \\# }
            \\
            \\# Query an account
            \\# {
            \\#   account(id: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045") {
            \\#     id
            \\#     domains { name }
            \\#   }
            \\# }
            \\`;
            \\
            \\    // Render GraphiQL with autocomplete enabled
            \\    ReactDOM.render(
            \\      React.createElement(GraphiQL, {
            \\        fetcher: graphQLFetcher,
            \\        defaultQuery: defaultQuery,
            \\      }),
            \\      document.getElementById('graphiql')
            \\    );
            \\  </script>
            \\</body>
            \\</html>
        ;

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

            const webhook_json = try std.fmt.allocPrint(self.allocator,
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
        const webhook_opt = try self.database.getWebhook(webhook_id);

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

            const webhook_json = try std.fmt.allocPrint(self.allocator,
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
                if (std.meta.stringToEnum(models.EventType, et_str)) |et| {
                    try event_types.append(self.allocator, et);
                }
            }
        }

        const active = if (obj.get("active")) |a| a.bool else true;
        const max_retries = if (obj.get("max_retries")) |mr| @as(u32, @intCast(mr.integer)) else 3;

        // Create webhook
        const webhook = models.Webhook{
            .id = 0, // Will be set by database
            .url = url.string,
            .event_types = try event_types.toOwnedSlice(self.allocator),
            .active = active,
            .max_retries = max_retries,
            .created_at = std.time.timestamp(),
        };

        const webhook_id = try self.webhook_database.?.insertWebhook(webhook);

        const response = try std.fmt.allocPrint(self.allocator, "{{\"id\":{d},\"message\":\"Webhook created\"}}", .{webhook_id});
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
                if (std.meta.stringToEnum(models.EventType, et_str)) |et| {
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
            \\      font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
            \\      max-width: 1400px;
            \\      margin: 0 auto;
            \\      padding: 20px;
            \\      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            \\      min-height: 100vh;
            \\    }
            \\    h1 {
            \\      color: white;
            \\      text-align: center;
            \\      font-size: 2.5rem;
            \\      margin-bottom: 30px;
            \\      text-shadow: 0 2px 4px rgba(0,0,0,0.2);
            \\    }
            \\    .container {
            \\      background: white;
            \\      padding: 30px;
            \\      border-radius: 12px;
            \\      box-shadow: 0 8px 32px rgba(0,0,0,0.1);
            \\      margin-bottom: 20px;
            \\    }
            \\    .form-grid {
            \\      display: grid;
            \\      grid-template-columns: 1fr 400px;
            \\      gap: 30px;
            \\    }
            \\    @media (max-width: 900px) {
            \\      .form-grid { grid-template-columns: 1fr; }
            \\    }
            \\    .event-categories {
            \\      display: grid;
            \\      grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
            \\      gap: 15px;
            \\      margin-top: 10px;
            \\    }
            \\    .event-category {
            \\      border: 1px solid #e0e0e0;
            \\      border-radius: 8px;
            \\      padding: 15px;
            \\      background: #fafafa;
            \\    }
            \\    .category-title {
            \\      font-weight: 700;
            \\      color: #667eea;
            \\      margin-bottom: 12px;
            \\      font-size: 13px;
            \\      text-transform: uppercase;
            \\      letter-spacing: 0.5px;
            \\      display: flex;
            \\      justify-content: space-between;
            \\      align-items: center;
            \\    }
            \\    .select-all {
            \\      font-size: 11px;
            \\      color: #667eea;
            \\      cursor: pointer;
            \\      text-decoration: underline;
            \\    }
            \\    .checkbox-item {
            \\      display: flex;
            \\      align-items: center;
            \\      margin-bottom: 8px;
            \\      cursor: pointer;
            \\    }
            \\    .checkbox-item input[type="checkbox"] {
            \\      width: 18px;
            \\      height: 18px;
            \\      margin-right: 8px;
            \\      cursor: pointer;
            \\      accent-color: #667eea;
            \\    }
            \\    .checkbox-item label {
            \\      cursor: pointer;
            \\      font-size: 13px;
            \\      color: #333;
            \\      user-select: none;
            \\    }
            \\    .summary-panel {
            \\      position: sticky;
            \\      top: 20px;
            \\      border: 2px solid #667eea;
            \\      border-radius: 8px;
            \\      padding: 20px;
            \\      background: linear-gradient(135deg, #667eea10 0%, #764ba210 100%);
            \\      max-height: 600px;
            \\      overflow-y: auto;
            \\    }
            \\    .summary-title {
            \\      font-weight: 700;
            \\      font-size: 16px;
            \\      color: #667eea;
            \\      margin-bottom: 15px;
            \\      display: flex;
            \\      align-items: center;
            \\      gap: 8px;
            \\    }
            \\    .summary-count {
            \\      background: #667eea;
            \\      color: white;
            \\      padding: 2px 10px;
            \\      border-radius: 12px;
            \\      font-size: 13px;
            \\    }
            \\    .summary-empty {
            \\      color: #999;
            \\      font-style: italic;
            \\      text-align: center;
            \\      padding: 20px;
            \\    }
            \\    .summary-events {
            \\      display: flex;
            \\      flex-wrap: wrap;
            \\      gap: 8px;
            \\    }
            \\    .summary-event-tag {
            \\      background: white;
            \\      border: 1px solid #667eea;
            \\      color: #667eea;
            \\      padding: 6px 12px;
            \\      border-radius: 6px;
            \\      font-size: 12px;
            \\      font-weight: 500;
            \\    }
            \\    .summary-event-tag.all {
            \\      background: #667eea;
            \\      color: white;
            \\      font-weight: 700;
            \\    }
            \\    table {
            \\      width: 100%;
            \\      border-collapse: separate;
            \\      border-spacing: 0;
            \\      margin-top: 20px;
            \\      border-radius: 8px;
            \\      overflow: hidden;
            \\    }
            \\    th, td {
            \\      text-align: left;
            \\      padding: 14px;
            \\      border-bottom: 1px solid #f0f0f0;
            \\    }
            \\    th {
            \\      background: linear-gradient(135deg, #667eea, #764ba2);
            \\      color: white;
            \\      font-weight: 600;
            \\      font-size: 13px;
            \\      text-transform: uppercase;
            \\      letter-spacing: 0.5px;
            \\    }
            \\    tr:hover td {
            \\      background: #f8f9ff;
            \\    }
            \\    button {
            \\      padding: 10px 20px;
            \\      border: none;
            \\      border-radius: 6px;
            \\      cursor: pointer;
            \\      font-size: 14px;
            \\      font-weight: 600;
            \\      margin-right: 8px;
            \\      transition: all 0.2s;
            \\    }
            \\    .btn-primary {
            \\      background: linear-gradient(135deg, #667eea, #764ba2);
            \\      color: white;
            \\    }
            \\    .btn-primary:hover {
            \\      transform: translateY(-1px);
            \\      box-shadow: 0 4px 12px rgba(102, 126, 234, 0.4);
            \\    }
            \\    .btn-danger {
            \\      background: #dc3545;
            \\      color: white;
            \\    }
            \\    .btn-danger:hover {
            \\      background: #c82333;
            \\    }
            \\    .btn-success {
            \\      background: #28a745;
            \\      color: white;
            \\    }
            \\    .btn-success:hover {
            \\      background: #218838;
            \\    }
            \\    .btn-warning {
            \\      background: #ffc107;
            \\      color: #333;
            \\    }
            \\    .btn-warning:hover {
            \\      background: #e0a800;
            \\    }
            \\    .btn-edit {
            \\      background: #17a2b8;
            \\      color: white;
            \\    }
            \\    .btn-edit:hover {
            \\      background: #138496;
            \\    }
            \\    input[type="text"], input[type="url"] {
            \\      padding: 12px;
            \\      border: 2px solid #e0e0e0;
            \\      border-radius: 6px;
            \\      font-size: 14px;
            \\      width: 100%;
            \\      transition: border-color 0.2s;
            \\    }
            \\    input[type="text"]:focus, input[type="url"]:focus {
            \\      outline: none;
            \\      border-color: #667eea;
            \\    }
            \\    .form-group {
            \\      margin-bottom: 20px;
            \\    }
            \\    .form-group label {
            \\      display: block;
            \\      margin-bottom: 8px;
            \\      font-weight: 600;
            \\      color: #333;
            \\      font-size: 14px;
            \\    }
            \\    .status-active {
            \\      color: #28a745;
            \\      font-weight: 600;
            \\    }
            \\    .status-inactive {
            \\      color: #dc3545;
            \\      font-weight: 600;
            \\    }
            \\    .event-tag {
            \\      display: inline-block;
            \\      background: #e9ecef;
            \\      padding: 4px 10px;
            \\      border-radius: 4px;
            \\      margin: 2px;
            \\      font-size: 11px;
            \\    }
            \\    #message {
            \\      padding: 16px;
            \\      border-radius: 8px;
            \\      margin-bottom: 20px;
            \\      display: none;
            \\      font-weight: 500;
            \\    }
            \\    #message.success {
            \\      background: #d4edda;
            \\      color: #155724;
            \\      border: 1px solid #c3e6cb;
            \\      display: block;
            \\    }
            \\    #message.error {
            \\      background: #f8d7da;
            \\      color: #721c24;
            \\      border: 1px solid #f5c6cb;
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
            \\      background: rgba(0,0,0,0.5);
            \\      backdrop-filter: blur(4px);
            \\    }
            \\    .modal-content {
            \\      background: white;
            \\      margin: 50px auto;
            \\      padding: 30px;
            \\      border-radius: 12px;
            \\      max-width: 900px;
            \\      max-height: 85vh;
            \\      overflow-y: auto;
            \\      box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            \\    }
            \\    .modal-header {
            \\      display: flex;
            \\      justify-content: space-between;
            \\      align-items: center;
            \\      margin-bottom: 20px;
            \\      padding-bottom: 15px;
            \\      border-bottom: 2px solid #667eea;
            \\    }
            \\    .modal-header h2 {
            \\      margin: 0;
            \\      color: #667eea;
            \\    }
            \\    .close {
            \\      font-size: 32px;
            \\      font-weight: 300;
            \\      color: #999;
            \\      cursor: pointer;
            \\      line-height: 1;
            \\    }
            \\    .close:hover {
            \\      color: #333;
            \\    }
            \\  </style>
            \\</head>
            \\<body>
            \\  <h1>📡 ENSv2 Webhook Management</h1>
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
            \\                  <span class="select-all" onclick="selectCategory('registry')">Select All</span>
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
            \\                  <span class="select-all" onclick="selectCategory('registration')">Select All</span>
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
            \\                  <span class="select-all" onclick="selectCategory('token')">Select All</span>
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
            \\                  Migration
            \\                  <span class="select-all" onclick="selectCategory('migration')">Select All</span>
            \\                </div>
            \\                <div class="checkbox-item">
            \\                  <input type="checkbox" id="name_migrated" value="name_migrated" class="event-checkbox migration-event">
            \\                  <label for="name_migrated">NameMigrated</label>
            \\                </div>
            \\                <div class="checkbox-item">
            \\                  <input type="checkbox" id="name_ejected_to_l1" value="name_ejected_to_l1" class="event-checkbox migration-event">
            \\                  <label for="name_ejected_to_l1">NameEjectedToL1</label>
            \\                </div>
            \\                <div class="checkbox-item">
            \\                  <input type="checkbox" id="name_returned_to_l2" value="name_returned_to_l2" class="event-checkbox migration-event">
            \\                  <label for="name_returned_to_l2">NameReturnedToL2</label>
            \\                </div>
            \\              </div>
            \\
            \\              <div class="event-category">
            \\                <div class="category-title">
            \\                  Resolver Records
            \\                  <span class="select-all" onclick="selectCategory('resolver')">Select All</span>
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
            \\          <button type="submit" class="btn-success">✓ Create Webhook</button>
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
            \\            <button type="submit" class="btn-primary">💾 Save Changes</button>
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
            \\      migration: ['name_migrated', 'name_ejected_to_l1', 'name_returned_to_l2'],
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
            \\      'name_migrated': 'NameMigrated',
            \\      'name_ejected_to_l1': 'NameEjectedToL1',
            \\      'name_returned_to_l2': 'NameReturnedToL2',
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
            \\        contentEl.innerHTML = 'No events selected. Webhook will receive <span class="summary-event-tag all">ALL EVENTS</span>';
            \\      } else {
            \\        contentEl.className = 'summary-events';
            \\        contentEl.innerHTML = selected.map(v =>
            \\          `<span class="summary-event-tag">${EVENT_DISPLAY_NAMES[v] || v}</span>`
            \\        ).join('');
            \\      }
            \\    }
            \\
            \\    function selectCategory(category) {
            \\      const events = EVENT_CATEGORIES[category];
            \\      events.forEach(event => {
            \\        const cb = document.getElementById(event);
            \\        if (cb) cb.checked = true;
            \\      });
            \\      updateSummary(false);
            \\    }
            \\
            \\    // Set up event listeners for create form checkboxes
            \\    document.addEventListener('DOMContentLoaded', () => {
            \\      document.querySelectorAll('.event-checkbox').forEach(cb => {
            \\        cb.addEventListener('change', () => updateSummary(false));
            \\      });
            \\      updateSummary(false);
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
            \\            <span class="select-all" onclick="selectEditCategory('${category}')">Select All</span>
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
            \\        cb.addEventListener('change', () => updateSummary(true));
            \\      });
            \\
            \\      updateSummary(true);
            \\      document.getElementById('editModal').style.display = 'block';
            \\    }
            \\
            \\    function selectEditCategory(category) {
            \\      const events = EVENT_CATEGORIES[category];
            \\      events.forEach(event => {
            \\        const cb = document.getElementById('edit_' + event);
            \\        if (cb) cb.checked = true;
            \\      });
            \\      updateSummary(true);
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

    var server = try Server.init(allocator, &database, null, 8080, 10, 1000, false, 100);
    defer server.deinit();

    try std.testing.expect(server.port == 8080);
}
