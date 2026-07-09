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
const zsys = @import("../utils/system.zig");
const auth = @import("auth.zig");

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
    io: std.Io,
    pool: *pool_mod.Pool,
    webhook_database: ?*db.Database, // Optional - only initialized if webhooks enabled
    port: u16,
    server: ?std.Io.net.Server,
    graphql_handler: graphql.GraphQLHandler,
    rate_limiter: PerIpRateLimiter,
    /// Unified admin/internal credential check (constant-time, fail-closed).
    admin_auth: auth.AdminAuth,
    /// Dedicated low rate limiter for the RPC-amplifying internal routes.
    internal_rate_limiter: PerIpRateLimiter,
    /// Explicit dev opt-in to serve webhook admin routes without auth.
    allow_unauth_webhooks: bool,
    /// Number of trusted reverse-proxy hops. 0 (default) = rate-limit on the direct TCP
    /// peer. > 0 = trust X-Forwarded-For from this many hops and rate-limit on the real
    /// client IP (see handleConnection / resolveClientAddress).
    trusted_proxy_hops: u32,
    /// On-chain resolution state; null unless primary-name verification is enabled
    /// via `enableResolution`. When null the server behaves exactly as before.
    resolve: ?ResolveState,
    /// In-flight connection count, bounded by `max_concurrent_connections` so a
    /// connection flood cannot spawn an unbounded number of 2MB-stack threads.
    active_conns: std.atomic.Value(u32),
    max_concurrent_connections: u32,
    /// Per-request wall-clock read budget (ms); backstops the per-socket timeout.
    request_timeout_ms: u32,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, pool: *pool_mod.Pool, webhook_db_path: ?[]const u8, port: u16, complexity_max_depth: u32, complexity_max_cost: u32, metrics_enabled: bool, rate_limit_per_second: u32, webhook_admin_username: ?[]const u8, webhook_admin_password: ?[]const u8, trusted_proxy_hops: u32, request_timeout_ms: u32, max_concurrent_connections: u32, internal_admin_token: ?[]const u8, internal_rate_limit_per_second: u32, allow_unauth_webhooks: bool) !Server {
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
            .io = io,
            .pool = pool,
            .webhook_database = webhook_db,
            .port = port,
            .server = null,
            .graphql_handler = try graphql.GraphQLHandler.init(allocator, complexity_max_depth, complexity_max_cost, metrics_enabled),
            .rate_limiter = PerIpRateLimiter.init(allocator, rate_limit * 2, rate_limit, 100_000),
            .admin_auth = auth.AdminAuth.init(webhook_admin_username, webhook_admin_password, internal_admin_token),
            .internal_rate_limiter = PerIpRateLimiter.init(allocator, @max(internal_rate_limit_per_second * 2, 1), internal_rate_limit_per_second, 100_000),
            .allow_unauth_webhooks = allow_unauth_webhooks,
            .trusted_proxy_hops = trusted_proxy_hops,
            .resolve = null,
            .active_conns = std.atomic.Value(u32).init(0),
            .max_concurrent_connections = max_concurrent_connections,
            .request_timeout_ms = request_timeout_ms,
        };
    }

    /// Turn on query-time primary-name verification. Creates the HTTP + RPC clients
    /// the resolution layer needs. Call once at startup, only when the feature flag
    /// is set; skipping it leaves the server byte-for-byte as it was.
    pub fn enableResolution(self: *Server, rpc_url: []const u8, ttl_s: u32, chain_id: u64, registry: Address, universal_resolver: Address, live_enabled: bool, primary_verify_enabled: bool, ccip_enabled: bool, ccip_max_redirects: u32, ccip_timeout_ms: u32) !void {
        std.debug.assert(self.resolve == null); // call-once: a second call would leak the first clients
        const http_client = try self.allocator.create(std.http.Client);
        errdefer self.allocator.destroy(http_client);
        http_client.* = std.http.Client{ .allocator = self.allocator, .io = self.io };
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
        self.internal_rate_limiter.deinit();
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
            s.deinit(self.io);
        }
    }

    pub fn start(self: *Server) !void {
        const address = try std.Io.net.IpAddress.parse("0.0.0.0", self.port);
        self.server = try address.listen(self.io, .{
            .reuse_address = true,
            .kernel_backlog = 128, // Handle burst of connections
        });
        const listener = &self.server.?;

        std.log.info("API server listening on port {d}", .{self.port});

        while (true) {
            const stream = listener.accept(self.io) catch |err| {
                std.log.warn("Failed to accept connection: {}", .{err});
                continue;
            };
            const conn = http_util.Conn{ .io = self.io, .stream = stream };

            // Bound a stalled/trickling peer: reads past request_timeout_ms error out
            // (see http_util.setStreamTimeout). The wall-clock deadline in
            // handleConnection is the backstop for a peer that trickles under it.
            http_util.setStreamTimeout(conn.stream.socket.handle, self.request_timeout_ms);

            // Rate-limit the direct peer BEFORE spawning a thread, so a flooder is
            // refused without ever allocating a 2MB handler stack. Behind a trusted
            // proxy the direct peer is the proxy (shared), so that case is limited on
            // the real client IP inside handleConnection instead.
            if (self.trusted_proxy_hops == 0 and !self.rate_limiter.tryAcquireFor(conn.address())) {
                self.sendRateLimited(conn) catch {};
                conn.close();
                continue;
            }

            // Concurrency cap: refuse with 503 rather than spawn an unbounded number of
            // handler threads under a connection flood. Reserve the slot before spawn;
            // the handler thread releases it on exit (and the spawn-error path below).
            if (self.active_conns.fetchAdd(1, .monotonic) + 1 > self.max_concurrent_connections) {
                _ = self.active_conns.fetchSub(1, .monotonic);
                self.sendServiceUnavailable(conn) catch {};
                conn.close();
                continue;
            }

            const thread = std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, handleConnectionThread, .{ self, conn }) catch |err| {
                std.log.warn("Failed to spawn handler thread: {}", .{err});
                _ = self.active_conns.fetchSub(1, .monotonic);
                conn.close();
                continue;
            };
            thread.detach();
        }
    }

    fn handleConnectionThread(self: *Server, conn: http_util.Conn) void {
        defer _ = self.active_conns.fetchSub(1, .monotonic);
        defer conn.close();
        self.handleConnection(conn) catch |err| {
            std.log.warn("Connection handler error: {}", .{err});
        };
    }

    fn handleConnection(self: *Server, conn: http_util.Conn) !void {
        // The direct-peer rate limit (trusted_proxy_hops == 0) now runs in the accept
        // loop, before this thread is spawned; behind a trusted proxy we still limit on
        // the real client IP from X-Forwarded-For after the bounded header read below.

        // Wall-clock request deadline: the per-socket receive timeout bounds each
        // individual read, but a peer trickling one byte per interval could survive
        // forever, so cap the whole header+body read here too.
        const request_start_ms = zsys.milliTimestamp();

        // Read headers first (up to 4KB for headers)
        var header_buffer: [4096]u8 = undefined;
        var total_header_bytes: usize = 0;

        // Read until we find the end of headers (\r\n\r\n or \n\n)
        while (total_header_bytes < header_buffer.len) {
            if (self.request_timeout_ms != 0 and zsys.milliTimestamp() - request_start_ms > self.request_timeout_ms) return;
            const bytes_read = conn.read(header_buffer[total_header_bytes..]) catch |err| {
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
            const client_addr = resolveClientAddress(conn.address(), header_data, self.trusted_proxy_hops);
            if (!self.rate_limiter.tryAcquireFor(client_addr)) {
                try self.sendRateLimited(conn);
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

        // Determine the body length from the parsed headers, rejecting framing we
        // do not safely support (chunked, Content-Length + Transfer-Encoding,
        // conflicting/malformed Content-Length) rather than guessing — an ambiguous
        // body length is a request-smuggling / desync vector.
        const content_length = http_util.parseBodyFraming(header_data[0..header_end]) catch {
            try self.sendBadRequest(conn, "Unsupported or ambiguous request framing");
            return;
        };

        // SECURITY: Limit max body size to 64KB to prevent DoS
        const max_body_size: usize = 65536;
        if (content_length > max_body_size) {
            try self.sendBadRequest(conn, "Request body too large (max 64KB)");
            return;
        }

        // Calculate how much body we already have in buffer
        const body_start_in_buffer = header_end + body_offset;
        const body_already_read = if (body_start_in_buffer < total_header_bytes)
            total_header_bytes - body_start_in_buffer
        else
            0;

        // Bytes buffered past the declared body are a pipelined/smuggled tail:
        // reject rather than (a) over-reading `request` in the copy below — the
        // original @memcpy of total_header_bytes into a content_length-sized buffer
        // was a heap overflow — or (b) leaving the extra bytes unconsumed.
        if (body_already_read > content_length) {
            try self.sendBadRequest(conn, "Unexpected data after request body");
            return;
        }

        // Allocate full request buffer. body_already_read <= content_length now
        // guarantees total_header_bytes <= total_size, so the copy is in-bounds.
        const total_size = header_end + body_offset + content_length;
        const request = self.allocator.alloc(u8, total_size) catch {
            try self.sendBadRequest(conn, "Out of memory");
            return;
        };
        defer self.allocator.free(request);

        // Copy what we already have (headers + any body prefix in the buffer).
        @memcpy(request[0..total_header_bytes], header_data[0..total_header_bytes]);

        // Read the remainder of the DECLARED body exactly. A short read (EOF before
        // content_length is satisfied) is an incomplete request — reject it instead
        // of parsing the uninitialized allocation tail as if it were body.
        if (body_already_read < content_length) {
            var offset = total_header_bytes;
            while (offset < total_size) {
                if (self.request_timeout_ms != 0 and zsys.milliTimestamp() - request_start_ms > self.request_timeout_ms) return;
                const bytes_read = conn.read(request[offset..]) catch |err| {
                    std.log.warn("Error reading request body: {}", .{err});
                    return;
                };
                if (bytes_read == 0) {
                    try self.sendBadRequest(conn, "Incomplete request body");
                    return;
                }
                offset += bytes_read;
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
            try self.sendCorsPreflightResponse(conn);
            return;
        }

        // Route request
        if (std.mem.startsWith(u8, path, "/graphql")) {
            // Handle GraphQL queries (both GET and POST)
            if (std.mem.eql(u8, method, "POST")) {
                try self.handleGraphQLQuery(conn, request);
            } else if (std.mem.eql(u8, method, "GET")) {
                try self.handleGraphQLGet(conn, path, request);
            } else {
                try self.sendBadRequest(conn, "Only GET and POST supported for GraphQL");
            }
        } else if (std.mem.startsWith(u8, path, "/webhooks") and !std.mem.startsWith(u8, path, "/api/webhooks")) {
            // Webhook management UI - only available if webhooks are enabled
            if (self.webhook_database == null) {
                try self.sendNotFound(conn);
                return;
            }
            if (!try self.webhookAuthOk(conn, request)) return;
            try self.handleWebhookUI(conn);
        } else if (std.mem.startsWith(u8, path, "/api/webhooks")) {
            // Webhook API endpoints - only available if webhooks are enabled
            if (self.webhook_database == null) {
                try self.sendNotFound(conn);
                return;
            }
            if (!try self.webhookAuthOk(conn, request)) return;
            try self.handleWebhooksAPI(conn, method, path, request);
        } else if (std.mem.startsWith(u8, path, "/api/name/")) {
            try self.handleNameQuery(conn, path);
        } else if (std.mem.startsWith(u8, path, "/api/owner/")) {
            try self.handleOwnerQuery(conn, path);
        } else if (std.mem.startsWith(u8, path, "/api/events")) {
            try self.handleEventsQuery(conn);
        } else if (self.resolve != null and self.resolve.?.primary_verify_enabled and std.mem.startsWith(u8, path, "/internal/verify-primary/")) {
            // Internal ops endpoint: ALWAYS requires a configured admin credential
            // (fail-closed — no unauth opt-in), because it triggers an on-chain RPC
            // read per request (amplification vector).
            if (!self.admin_auth.configured() or !self.admin_auth.checkRequest(request)) {
                try self.sendUnauthorized(conn);
                return;
            }
            // Dedicated low rate limit on the real client IP, before any DB/RPC work.
            const internal_client = resolveClientAddress(conn.address(), request, self.trusted_proxy_hops);
            if (!self.internal_rate_limiter.tryAcquireFor(internal_client)) {
                try self.sendRateLimited(conn);
                return;
            }
            try self.handleVerifyPrimary(conn, path);
        } else if (std.mem.startsWith(u8, path, "/api/health")) {
            try self.handleHealthCheck(conn);
        } else if (std.mem.startsWith(u8, path, "/metrics")) {
            try self.handleMetrics(conn);
        } else {
            try self.sendNotFound(conn);
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
    /// Gate a webhook admin route. Returns true to proceed; on failure it has
    /// already sent 401 and the caller must return. Fail-closed: with no credential
    /// configured the route rejects UNLESS the explicit dev opt-in is set.
    fn webhookAuthOk(self: *Server, conn: http_util.Conn, request: []const u8) !bool {
        if (self.admin_auth.configured()) {
            if (self.admin_auth.checkRequest(request)) return true;
        } else if (self.allow_unauth_webhooks) {
            return true;
        }
        try self.sendUnauthorized(conn);
        return false;
    }

    pub const sendJsonResponse = api_responses.sendJsonResponse;
    pub const sendNotFound = api_responses.sendNotFound;
    pub const sendBadRequest = api_responses.sendBadRequest;
    pub const sendGraphQLResponse = api_responses.sendGraphQLResponse;
    pub const sendRequestError = api_responses.sendRequestError;
    pub const sendRateLimited = api_responses.sendRateLimited;
    pub const sendServiceUnavailable = api_responses.sendServiceUnavailable;
    pub const sendCorsPreflightResponse = api_responses.sendCorsPreflightResponse;
    pub const sendUnauthorized = api_responses.sendUnauthorized;

    // Webhook management handlers — implementations in webhook_handlers.zig.
    pub const handleWebhooksAPI = webhook_handlers.handleWebhooksAPI;
    pub const handleListWebhooks = webhook_handlers.handleListWebhooks;
    pub const handleGetWebhook = webhook_handlers.handleGetWebhook;
    pub const handleCreateWebhook = webhook_handlers.handleCreateWebhook;
    pub const handleUpdateWebhook = webhook_handlers.handleUpdateWebhook;
    pub const handleDeleteWebhook = webhook_handlers.handleDeleteWebhook;
    pub const handleWebhookUI = webhook_handlers.handleWebhookUI;
};

test "Server init" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();

    var pool = try pool_mod.Pool.open(allocator, .{ .kind = .sqlite, .sqlite_path = ":memory:" });
    defer pool.deinit();

    var server = try Server.init(allocator, threaded.io(), &pool, null, 8080, 10, 1000, false, 100, null, null, 0, 10000, 512, null, 2, true);
    defer server.deinit();

    try std.testing.expect(server.port == 8080);
    try std.testing.expectEqual(@as(u32, 0), server.active_conns.load(.monotonic));
}
