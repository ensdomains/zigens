const std = @import("std");
const db = @import("../storage/database.zig");
const pool_mod = @import("../storage/pool.zig");
const models = @import("../types/models.zig");
const Hash = @import("../types/hash.zig").Hash;
const Address = @import("../types/address.zig").Address;
const graphql = @import("handler.zig");
const parser = @import("../lib/graphql/parser.zig");
const json_utils = @import("../utils/json.zig");
const url_utils = @import("../utils/url.zig");
const validation = @import("../utils/validation.zig");
const PerIpRateLimiter = @import("../rate_limiter.zig").PerIpRateLimiter;
const webhook_manager = @import("../webhooks/manager.zig");
const rpc = @import("../rpc/client.zig");
const resolve_client = @import("../resolve/client.zig");
const resolve_primary = @import("../resolve/primary.zig");

/// On-chain resolution state, created only when primary-name verification is enabled.
/// Owns the HTTP client the RPC client borrows; both are freed in `Server.deinit`.
pub const ResolveState = struct {
    http_client: *std.http.Client,
    rpc_client: *rpc.Client,
    chain_id: u64,
    ttl_s: u32,
    /// Registry the forward `resolver(node)` read is issued against (L1 ENS registry).
    registry: Address,
    /// Universal Resolver for live ENSIP-10 record fallback (Task 06). Zero when not
    /// configured for this network → live fallback stays off even if the flag is set.
    universal_resolver: Address,
    /// Whether live UR record fallback is enabled (RESOLVE_LIVE_ENABLED).
    live_enabled: bool,
    /// Whether primary-name forward verification (Task 05) is enabled. Distinct from
    /// live_enabled: both share the RPC client but gate independent features, so the
    /// /internal/verify-primary endpoint is exposed only when THIS flag is set.
    primary_verify_enabled: bool,
    /// CCIP-Read (EIP-3668) offchain completion during live resolution (Task 07).
    /// Requires live_enabled; enabling it adds outbound HTTP to name-controlled gateways.
    ccip_enabled: bool,
    ccip_max_redirects: u32,
    ccip_timeout_ms: u32,
};

const http_util = @import("http_util.zig");
const api_responses = @import("api_responses.zig");
const webhook_handlers = @import("webhook_handlers.zig");
const api_endpoints = @import("api_endpoints.zig");
const resolveClientAddress = http_util.resolveClientAddress;
const acceptsResponseJson = http_util.acceptsResponseJson;
const graphqlContentType = http_util.graphqlContentType;
const strictStatus = http_util.strictStatus;
const stripNullData = http_util.stripNullData;
const getQueryParam = http_util.getQueryParam;
const urlDecode = http_util.urlDecode;
const queryIsMutation = http_util.queryIsMutation;

/// Simple JSON API Server for ENSv2 Indexer
/// Provides REST endpoints and GraphQL for querying indexed data
pub const Server = struct {
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    webhook_database: ?*db.Database, // Optional - only initialized if webhooks enabled
    port: u16,
    server: ?std.net.Server,
    graphql_handler: graphql.GraphQLHandler,
    rate_limiter: PerIpRateLimiter,
    webhook_admin_username: ?[]const u8, // Optional - if set with password, requires Basic Auth
    webhook_admin_password: ?[]const u8, // Optional - if set, requires Basic Auth for webhook endpoints
    /// Number of trusted reverse-proxy hops. 0 (default) = rate-limit on the direct TCP
    /// peer. > 0 = trust X-Forwarded-For from this many hops and rate-limit on the real
    /// client IP (see handleConnection / resolveClientAddress).
    trusted_proxy_hops: u32,
    /// On-chain resolution state; null unless primary-name verification is enabled
    /// via `enableResolution`. When null the server behaves exactly as before.
    resolve: ?ResolveState,

    pub fn init(allocator: std.mem.Allocator, pool: *pool_mod.Pool, webhook_db_path: ?[]const u8, port: u16, complexity_max_depth: u32, complexity_max_cost: u32, metrics_enabled: bool, rate_limit_per_second: u32, webhook_admin_username: ?[]const u8, webhook_admin_password: ?[]const u8, trusted_proxy_hops: u32) !Server {
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
            .pool = pool,
            .webhook_database = webhook_db,
            .port = port,
            .server = null,
            .graphql_handler = try graphql.GraphQLHandler.init(allocator, complexity_max_depth, complexity_max_cost, metrics_enabled),
            .rate_limiter = PerIpRateLimiter.init(allocator, rate_limit * 2, rate_limit, 100_000),
            .webhook_admin_username = webhook_admin_username,
            .webhook_admin_password = webhook_admin_password,
            .trusted_proxy_hops = trusted_proxy_hops,
            .resolve = null,
        };
    }

    /// Turn on query-time primary-name verification. Creates the HTTP + RPC clients
    /// the resolution layer needs. Call once at startup, only when the feature flag
    /// is set; skipping it leaves the server byte-for-byte as it was.
    pub fn enableResolution(self: *Server, rpc_url: []const u8, ttl_s: u32, chain_id: u64, registry: Address, universal_resolver: Address, live_enabled: bool, primary_verify_enabled: bool, ccip_enabled: bool, ccip_max_redirects: u32, ccip_timeout_ms: u32) !void {
        std.debug.assert(self.resolve == null); // call-once: a second call would leak the first clients
        const http_client = try self.allocator.create(std.http.Client);
        errdefer self.allocator.destroy(http_client);
        http_client.* = std.http.Client{ .allocator = self.allocator };
        errdefer http_client.deinit();

        const rpc_client = try rpc.Client.initWithSharedHttpClient(self.allocator, rpc_url, http_client);

        self.resolve = .{
            .http_client = http_client,
            .rpc_client = rpc_client,
            .chain_id = chain_id,
            .ttl_s = ttl_s,
            .registry = registry,
            .universal_resolver = universal_resolver,
            .live_enabled = live_enabled,
            .primary_verify_enabled = primary_verify_enabled,
            .ccip_enabled = ccip_enabled,
            .ccip_max_redirects = ccip_max_redirects,
            .ccip_timeout_ms = ccip_timeout_ms,
        };
    }

    pub fn deinit(self: *Server) void {
        self.graphql_handler.deinit();
        self.rate_limiter.deinit();
        if (self.webhook_database) |webhook_db| {
            webhook_db.deinit();
            self.allocator.destroy(webhook_db);
        }
        if (self.resolve) |rs| {
            rs.rpc_client.deinit(); // destroys the Client (borrows http_client, so free it after)
            rs.http_client.deinit();
            self.allocator.destroy(rs.http_client);
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
        // Rate limit on the direct TCP peer when NOT behind a proxy (the common case) —
        // before any header read, so a flooding peer is refused immediately. Behind a
        // trusted proxy (trusted_proxy_hops > 0) the direct peer is the proxy and is shared
        // by all clients, so we instead limit on the real client IP from X-Forwarded-For
        // after reading headers (still bounded — headers are capped at 4KB below).
        if (self.trusted_proxy_hops == 0) {
            if (!self.rate_limiter.tryAcquireFor(connection.address)) {
                try self.sendRateLimited(connection.stream);
                return;
            }
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

        // Behind a trusted proxy: rate-limit on the real client IP from X-Forwarded-For
        // (spoof-resistant — see resolveClientAddress). Done after the bounded header read,
        // still before any request body is processed.
        if (self.trusted_proxy_hops > 0) {
            const client_addr = resolveClientAddress(connection.address, header_data, self.trusted_proxy_hops);
            if (!self.rate_limiter.tryAcquireFor(client_addr)) {
                try self.sendRateLimited(connection.stream);
                return;
            }
        }

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
                try self.handleGraphQLGet(connection.stream, path, request);
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
        } else if (self.resolve != null and self.resolve.?.primary_verify_enabled and std.mem.startsWith(u8, path, "/internal/verify-primary/")) {
            // Only routed when primary-name verification is enabled; otherwise this
            // path falls through to 404, keeping flag-off behavior identical to before.
            try self.handleVerifyPrimary(connection.stream, path);
        } else if (std.mem.startsWith(u8, path, "/api/health")) {
            try self.handleHealthCheck(connection.stream);
        } else if (std.mem.startsWith(u8, path, "/metrics")) {
            try self.handleMetrics(connection.stream);
        } else {
            try self.sendNotFound(connection.stream);
        }
    }

    /// Internal, ops-facing endpoint: forward-verify an address's primary-name claim
    /// on-chain (ENSIP-3). Active only when primary-name verification is enabled;
    /// returns a small JSON verdict and increments the verification metrics. This is
    /// NOT part of the public GraphQL/subgraph contract.
    // REST/ops + GraphQL request handlers — implementations in api_endpoints.zig.
    pub const handleVerifyPrimary = api_endpoints.handleVerifyPrimary;
    pub const handleNameQuery = api_endpoints.handleNameQuery;
    pub const handleOwnerQuery = api_endpoints.handleOwnerQuery;
    pub const handleEventsQuery = api_endpoints.handleEventsQuery;
    pub const handleHealthCheck = api_endpoints.handleHealthCheck;
    pub const handleMetrics = api_endpoints.handleMetrics;
    pub const handleGraphQLQuery = api_endpoints.handleGraphQLQuery;
    pub const handleGraphQLGet = api_endpoints.handleGraphQLGet;
    pub const handleGraphQLPlayground = api_endpoints.handleGraphQLPlayground;

    // Response writers — implementations in api_responses.zig.
    pub const sendJsonResponse = api_responses.sendJsonResponse;
    pub const sendNotFound = api_responses.sendNotFound;
    pub const sendBadRequest = api_responses.sendBadRequest;
    pub const sendGraphQLResponse = api_responses.sendGraphQLResponse;
    pub const sendRequestError = api_responses.sendRequestError;
    pub const sendRateLimited = api_responses.sendRateLimited;
    pub const sendCorsPreflightResponse = api_responses.sendCorsPreflightResponse;
    pub const sendUnauthorized = api_responses.sendUnauthorized;

    // Webhook management handlers — implementations in webhook_handlers.zig.
    pub const checkWebhookAuth = webhook_handlers.checkWebhookAuth;
    pub const handleWebhooksAPI = webhook_handlers.handleWebhooksAPI;
    pub const handleListWebhooks = webhook_handlers.handleListWebhooks;
    pub const handleGetWebhook = webhook_handlers.handleGetWebhook;
    pub const handleCreateWebhook = webhook_handlers.handleCreateWebhook;
    pub const handleUpdateWebhook = webhook_handlers.handleUpdateWebhook;
    pub const handleDeleteWebhook = webhook_handlers.handleDeleteWebhook;
    pub const handleWebhookUI = webhook_handlers.handleWebhookUI;
};

test "Server init" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pool = try pool_mod.Pool.open(allocator, .{ .kind = .sqlite, .sqlite_path = ":memory:" });
    defer pool.deinit();

    var server = try Server.init(allocator, &pool, null, 8080, 10, 1000, false, 100, null, null, 0);
    defer server.deinit();

    try std.testing.expect(server.port == 8080);
}
