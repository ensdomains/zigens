//! REST/ops + GraphQL request handlers for the API server.
//!
//! The endpoint handlers (verify-primary, name/owner/events/health/metrics REST,
//! and the GraphQL query/GET/playground) split out of server.zig as
//! `pub fn f(self: *Server, ...)`; server.zig re-exports them as
//! `pub const f = api_endpoints.f;`, so the router's `self.f(...)` dispatch is
//! unchanged. Response senders + http helpers are reached via `self` / the aliases below.

const std = @import("std");
const zsys = @import("../utils/system.zig");
const db = @import("../storage/database.zig");
const models = @import("../types/models.zig");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;
const graphql = @import("handler.zig");
const api_common = @import("common.zig");
const parser = @import("../lib/graphql/parser.zig");
const json_utils = @import("../utils/json.zig");
const url_utils = @import("../utils/url.zig");
const validation = @import("../utils/validation.zig");
const resolve_client = @import("../resolve/client.zig");
const universal = @import("../resolve/universal.zig");
const resolve_primary = @import("../resolve/primary.zig");
const ccip_transport = @import("../resolve/ccip_transport.zig");
const http_util = @import("http_util.zig");
const acceptsResponseJson = http_util.acceptsResponseJson;
const graphqlContentType = http_util.graphqlContentType;
const strictStatus = http_util.strictStatus;
const stripNullData = http_util.stripNullData;
const getQueryParam = http_util.getQueryParam;
const urlDecode = http_util.urlDecode;
const queryIsMutation = http_util.queryIsMutation;
const Server = @import("server.zig").Server;

pub fn handleVerifyPrimary(self: *Server, conn: http_util.Conn, path: []const u8) !void {
    const rs = self.resolve orelse {
        return try self.sendJsonResponse(conn, 200, "{\"status\":\"disabled\"}");
    };

    const prefix = "/internal/verify-primary/";
    if (path.len <= prefix.len) {
        return try self.sendBadRequest(conn, "Address required");
    }
    var end = prefix.len;
    while (end < path.len and path[end] != ' ' and path[end] != '?' and path[end] != '\r') {
        end += 1;
    }
    const addr_str = path[prefix.len..end];
    const addr = Address.fromHex(addr_str) catch {
        return try self.sendBadRequest(conn, "Invalid address format");
    };

    const database = try self.pool.acquire();
    defer self.pool.release(database);

    // Prefer a V2 reverse claim over V1, matching accountPrimaryNameHandler.
    const namehash = blk: {
        if (try database.getReverseRecordNamehash(.v2, addr)) |nh| break :blk nh;
        if (try database.getReverseRecordNamehash(.v1, addr)) |nh| break :blk nh;
        break :blk null;
    } orelse return try self.sendJsonResponse(conn, 200, "{\"status\":\"no_claim\"}");

    const name = (try database.getLatestNameByNamehash(namehash)) orelse
        return try self.sendJsonResponse(conn, 200, "{\"status\":\"no_claim\"}");
    defer database.allocator.free(name);

    // Pin the forward reads to the current indexed head (whichever protocol is
    // furthest along on this L1 chain) plus its stored block hash, so a reorg
    // invalidates the cached answer.
    const v1_head = (try database.getSyncState(.v1)) orelse 0;
    const v2_head = (try database.getSyncState(.v2)) orelse 0;
    const use_v1 = v1_head >= v2_head;
    const head = if (use_v1) v1_head else v2_head;
    const head_hash = (if (use_v1) try database.getBlockHash(.v1, head) else try database.getBlockHash(.v2, head)) orelse
        return try self.sendJsonResponse(conn, 200, "{\"status\":\"unverified\",\"reason\":\"no_head_hash\"}");

    var resolver = resolve_client.Resolver.init(rs.rpc_client, database, rs.chain_id, rs.ttl_s);
    // Route through the Universal Resolver (like the GraphQL path) so inherited/wildcard
    // primary names verify; falls back to the direct check when no UR is configured.
    var lc = universal.LiveContext{
        .resolver = &resolver,
        .ur_address = rs.universal_resolver,
        .block_num = head,
        .block_hash = head_hash,
        .now = zsys.timestamp(),
        .registry = rs.registry,
        .primary_verify_enabled = rs.primary_verify_enabled,
    };
    const verdict = try lc.verifyPrimary(self.allocator, addr, name);

    const outcome: @TypeOf(self.graphql_handler.metrics).PrimaryOutcome = switch (verdict) {
        .verified => .verified,
        .mismatch => .mismatch,
        // invalid_name / not_found roll into the "unverified" counter bucket; the finer
        // verdict is surfaced verbatim in the response body below.
        .invalid_name, .not_found, .unverified => .unverified,
    };
    self.graphql_handler.metrics.recordPrimaryVerification(outcome);

    const name_escaped = try json_utils.escapeString(self.allocator, name);
    defer self.allocator.free(name_escaped);
    const body = try std.fmt.allocPrint(self.allocator, "{{\"address\":\"{s}\",\"claimed\":\"{s}\",\"verdict\":\"{s}\"}}", .{ addr_str, name_escaped, @tagName(verdict) });
    defer self.allocator.free(body);
    try self.sendJsonResponse(conn, 200, body);
}

/// Explain a live resolution: run the exact resolve path for addr(60) with a
/// step-trace attached and return the ordered steps. Auth-gated like
/// verify-primary (each hit is an on-chain read when the cache is cold).
pub fn handleExplain(self: *Server, conn: http_util.Conn, path: []const u8) !void {
    const rs = self.resolve orelse {
        return try self.sendJsonResponse(conn, 200, "{\"status\":\"disabled\"}");
    };

    const prefix = "/internal/explain/";
    if (path.len <= prefix.len) {
        return try self.sendBadRequest(conn, "Name required");
    }
    var end = prefix.len;
    while (end < path.len and path[end] != ' ' and path[end] != '?' and path[end] != '\r') {
        end += 1;
    }
    const raw_name = path[prefix.len..end];
    const name = (try resolve_primary.normalizedClaimOwned(self.allocator, raw_name)) orelse {
        return try self.sendBadRequest(conn, "Name does not normalize (ENSIP-15)");
    };
    defer self.allocator.free(name);
    const node = try @import("../types/hash.zig").namehash(self.allocator, name);

    const database = try self.pool.acquire();
    defer self.pool.release(database);
    const v1_head = (try database.getSyncState(.v1)) orelse 0;
    const v2_head = (try database.getSyncState(.v2)) orelse 0;
    const use_v1 = v1_head >= v2_head;
    const head = if (use_v1) v1_head else v2_head;
    const head_hash = (if (use_v1) try database.getBlockHash(.v1, head) else try database.getBlockHash(.v2, head)) orelse
        return try self.sendJsonResponse(conn, 200, "{\"status\":\"unavailable\",\"reason\":\"no_head_hash\"}");

    var resolver = resolve_client.Resolver.init(rs.rpc_client, database, rs.chain_id, rs.ttl_s);
    var trace = universal.Trace{ .allocator = self.allocator };
    defer trace.deinit();
    var lc = universal.LiveContext{
        .resolver = &resolver,
        .ur_address = rs.universal_resolver,
        .block_num = head,
        .block_hash = head_hash,
        .now = zsys.timestamp(),
        .registry = rs.registry,
        .primary_verify_enabled = rs.primary_verify_enabled,
        .trace = &trace,
    };
    const result = lc.resolveRecord(self.allocator, name, node, .addr) catch null;
    defer if (result) |r| self.allocator.free(r);

    var out: std.Io.Writer.Allocating = .init(self.allocator);
    defer out.deinit();
    const w = &out.writer;
    const name_escaped = try json_utils.escapeString(self.allocator, name);
    defer self.allocator.free(name_escaped);
    var node_buf: [66]u8 = undefined;
    try w.print("{{\"name\":\"{s}\",\"node\":\"{s}\",\"record\":\"addr\",\"block\":{d},", .{ name_escaped, node.toHexBuf(&node_buf), head });
    if (result) |r| {
        const esc = try json_utils.escapeString(self.allocator, r);
        defer self.allocator.free(esc);
        try w.print("\"result\":\"{s}\",", .{esc});
    } else {
        try w.writeAll("\"result\":null,");
    }
    try w.writeAll("\"steps\":[");
    for (trace.steps.items, 0..) |st, i| {
        if (i > 0) try w.writeAll(",");
        const de = try json_utils.escapeString(self.allocator, st.detail);
        defer self.allocator.free(de);
        try w.print("{{\"step\":\"{s}\",\"detail\":\"{s}\"}}", .{ st.name, de });
    }
    try w.writeAll("]}");
    try self.sendJsonResponse(conn, 200, out.written());
}

pub fn handleNameQuery(self: *Server, conn: http_util.Conn, path: []const u8) !void {
    // Extract name from path: /api/name/{name}
    const name_start = "/api/name/".len;
    if (path.len <= name_start) {
        return try self.sendBadRequest(conn, "Name parameter required");
    }

    var name_end = name_start;
    while (name_end < path.len and path[name_end] != ' ' and path[name_end] != '?' and path[name_end] != '\r') {
        name_end += 1;
    }

    const name = path[name_start..name_end];

    // SECURITY: Validate name length to prevent DoS attacks (industry standard: DNS label limit)
    validation.validateEnsName(name) catch {
        return try self.sendBadRequest(conn, "Invalid name: length must be between 1 and 255 characters");
    };

    std.log.info("Querying name: {s}", .{name});

    // Compute namehash
    const nh = try @import("../types/hash.zig").namehash(self.allocator, name);

    // Query database
    const database = try self.pool.acquire();
    defer self.pool.release(database);
    const name_record = try database.getNameByNamehash(nh);

    if (name_record) |record| {
        var record_copy = record;
        defer record_copy.deinit(database.allocator);

        // Build JSON response
        var response_buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer response_buf.deinit();

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

        const writer = &response_buf.writer;
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
        try self.sendJsonResponse(conn, 200, response_buf.written());
    } else {
        try self.sendNotFound(conn);
    }
}

/// Aggregated profile: one GET returns the domain's core fields, its effective
/// resolver's records (addr/contenthash/all texts), and the owner's primary
/// name. Indexed data only — on-chain verification stays on the auth-gated
/// /internal/verify-primary endpoint (a live RPC per public hit would be a DoS
/// vector).
pub fn handleProfileQuery(self: *Server, conn: http_util.Conn, path: []const u8) !void {
    const prefix_len: usize = if (std.mem.startsWith(u8, path, "/api/profiles/")) "/api/profiles/".len else "/profiles/".len;
    if (path.len <= prefix_len) {
        return try self.sendBadRequest(conn, "Name parameter required");
    }
    var name_end = prefix_len;
    while (name_end < path.len and path[name_end] != ' ' and path[name_end] != '?' and path[name_end] != '\r') {
        name_end += 1;
    }
    const name = path[prefix_len..name_end];
    validation.validateEnsName(name) catch {
        return try self.sendBadRequest(conn, "Invalid name: length must be between 1 and 255 characters");
    };

    const nh = try @import("../types/hash.zig").namehash(self.allocator, name);
    const database = try self.pool.acquire();
    defer self.pool.release(database);

    const row_opt = try database.getNameByNamehash(nh);
    if (row_opt == null) {
        return try self.sendJsonResponse(conn, 404, "{\"error\":\"name not found\"}");
    }
    var row = row_opt.?;
    defer row.deinit(database.allocator);

    // Same effective-resolver semantics as GraphQL: ENSIP-10 ancestor walk-up
    // when the name has no resolver of its own.
    const impl = @import("builders/impl.zig");
    const resolver = impl.effectiveResolver(database, &row) catch row.resolver;

    var out: std.Io.Writer.Allocating = .init(self.allocator);
    defer out.deinit();
    const w = &out.writer;

    const name_escaped = try json_utils.escapeString(self.allocator, row.name orelse name);
    defer self.allocator.free(name_escaped);
    var nh_buf: [66]u8 = undefined;
    var owner_buf: [42]u8 = undefined;
    try w.print("{{\"name\":\"{s}\",\"namehash\":\"{s}\",\"owner\":\"{s}\",\"protocol\":\"{s}\",\"expiry\":{d}", .{
        name_escaped,
        row.namehash.toHexBuf(&nh_buf),
        row.owner.toHexBuf(&owner_buf),
        row.protocol.toString(),
        row.expiry,
    });

    if (resolver.isZero()) {
        try w.writeAll(",\"resolver\":null,\"address\":null,\"contenthash\":null,\"texts\":{}");
    } else {
        var resolver_buf: [42]u8 = undefined;
        try w.print(",\"resolver\":\"{s}\"", .{resolver.toHexBuf(&resolver_buf)});

        if (database.getAddressRecord(resolver, nh, 60) catch null) |a| {
            defer database.allocator.free(a);
            const esc = try json_utils.escapeString(self.allocator, a);
            defer self.allocator.free(esc);
            try w.print(",\"address\":\"{s}\"", .{esc});
        } else {
            try w.writeAll(",\"address\":null");
        }

        if (database.getContentHashRecord(resolver, nh) catch null) |ch| {
            defer database.allocator.free(ch);
            const esc = try json_utils.escapeString(self.allocator, ch);
            defer self.allocator.free(esc);
            try w.print(",\"contenthash\":\"{s}\"", .{esc});
        } else {
            try w.writeAll(",\"contenthash\":null");
        }

        try w.writeAll(",\"texts\":{");
        const keys = database.getTextRecordKeys(resolver, nh) catch &[_][]const u8{};
        defer {
            for (keys) |k| database.allocator.free(k);
            if (keys.len > 0) database.allocator.free(keys);
        }
        var first = true;
        for (keys) |k| {
            const v = (database.getTextRecord(resolver, nh, k) catch null) orelse continue;
            defer database.allocator.free(v);
            const ek = try json_utils.escapeString(self.allocator, k);
            defer self.allocator.free(ek);
            const ev = try json_utils.escapeString(self.allocator, v);
            defer self.allocator.free(ev);
            if (!first) try w.writeAll(",");
            try w.print("\"{s}\":\"{s}\"", .{ ek, ev });
            first = false;
        }
        try w.writeAll("}");
    }

    // The OWNER's primary (reverse) name, preferring V2 claims like GraphQL.
    const primary_nh = blk: {
        if (database.getReverseRecordNamehash(.v2, row.owner) catch null) |p| break :blk p;
        if (database.getReverseRecordNamehash(.v1, row.owner) catch null) |p| break :blk p;
        break :blk null;
    };
    if (primary_nh) |pnh| {
        if (database.getLatestNameByNamehash(pnh) catch null) |pname| {
            defer database.allocator.free(pname);
            const esc = try json_utils.escapeString(self.allocator, pname);
            defer self.allocator.free(esc);
            try w.print(",\"ownerPrimaryName\":\"{s}\"", .{esc});
        } else {
            try w.writeAll(",\"ownerPrimaryName\":null");
        }
    } else {
        try w.writeAll(",\"ownerPrimaryName\":null");
    }

    try w.writeAll("}");
    try self.sendJsonResponse(conn, 200, out.written());
}

pub fn handleOwnerQuery(self: *Server, conn: http_util.Conn, path: []const u8) !void {
    // Extract owner address from path: /api/owner/{address}
    const owner_start = "/api/owner/".len;
    if (path.len <= owner_start) {
        return try self.sendBadRequest(conn, "Owner address required");
    }

    var owner_end = owner_start;
    while (owner_end < path.len and path[owner_end] != ' ' and path[owner_end] != '?' and path[owner_end] != '\r') {
        owner_end += 1;
    }

    const owner_str = path[owner_start..owner_end];

    std.log.info("Querying owner: {s}", .{owner_str});

    // Parse owner address
    const owner = Address.fromHex(owner_str) catch {
        return try self.sendBadRequest(conn, "Invalid address format");
    };

    // Query database for all names owned by this address
    const database = try self.pool.acquire();
    defer self.pool.release(database);
    const names = try database.getNamesByOwner(owner, 100); // Limit to 100 names
    defer {
        for (names) |*name| {
            name.deinit(database.allocator);
        }
        database.allocator.free(names);
    }

    // Build JSON response
    var response_buf: std.Io.Writer.Allocating = .init(self.allocator);
    defer response_buf.deinit();

    const writer = &response_buf.writer;
    try writer.writeAll("[");

    for (names, 0..) |name, i| {
        if (i > 0) try writer.writeAll(",");

        // SECURITY: Escape name field using RFC 8259 compliant json_utils (industry standard)
        const name_escaped = try json_utils.escapeString(self.allocator, name.name orelse "[unknown]");
        defer self.allocator.free(name_escaped);

        try writer.print("{{\"name\":\"{s}\",\"expiry\":{d},\"owner\":\"{s}\"}}", .{ name_escaped, name.expiry, owner_str });
    }

    try writer.writeAll("]");
    try self.sendJsonResponse(conn, 200, response_buf.written());
}

pub fn handleEventsQuery(self: *Server, conn: http_util.Conn) !void {
    // Query recent events from database (last 50)
    const database = try self.pool.acquire();
    defer self.pool.release(database);
    const events = try database.getRecentEvents(null, null, 50);
    defer {
        for (events) |*event| {
            event.deinit(database.allocator);
        }
        database.allocator.free(events);
    }

    // Build JSON response
    var response_buf: std.ArrayList(u8) = .empty;
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

    try self.sendJsonResponse(conn, 200, response_buf.items);
}

/// Liveness: the process is up and the HTTP server accepts requests. Deliberately does
/// NOT touch the DB — a transient DB blip must not fail liveness and trigger a restart.
/// Use /ready for a DB-backed readiness signal.
pub fn handleHealthCheck(self: *Server, conn: http_util.Conn) !void {
    const response =
        \\{"status":"ok","service":"ensv2-indexer"}
    ;
    try self.sendJsonResponse(conn, 200, response);
}

/// Readiness: can this node actually serve queries? Acquires a pool session and does a
/// trivial read; returns 503 when the DB is unreachable so a load balancer routes traffic
/// away. Staleness is surfaced as a `stale` flag (api/common.coverageStale), not a 503,
/// so a node that is merely a little behind keeps serving instead of flapping out of
/// rotation.
pub fn handleReadiness(self: *Server, conn: http_util.Conn) !void {
    const database = self.pool.acquire() catch
        return self.sendJsonResponse(conn, 503, "{\"status\":\"not_ready\",\"reason\":\"db_unavailable\"}");
    defer self.pool.release(database);

    const v1 = database.getSyncStateFull(.v1) catch
        return self.sendJsonResponse(conn, 503, "{\"status\":\"not_ready\",\"reason\":\"db_unreachable\"}");
    const v2 = database.getSyncStateFull(.v2) catch
        return self.sendJsonResponse(conn, 503, "{\"status\":\"not_ready\",\"reason\":\"db_unreachable\"}");
    const head = api_common.indexedHead(v1, v2);

    const safe = database.getFinality(database.chain_id, .safe) catch null;
    const safe_num: ?u64 = if (safe) |sp| sp.number else null;
    const stale = api_common.coverageStale(v1, v2, safe_num, database.stale_after_seconds, zsys.timestamp());

    const body = try std.fmt.allocPrint(self.allocator, "{{\"status\":\"ready\",\"indexed_head\":{d},\"safe\":{d},\"stale\":{s}}}", .{ head, safe_num orelse 0, if (stale) "true" else "false" });
    defer self.allocator.free(body);
    try self.sendJsonResponse(conn, 200, body);
}

/// Coverage declaration: chain id, per-protocol indexed head + last-sync time, and a
/// staleness flag (api/common.coverageStale, the same flag /ready reports). The
/// GraphQL `_coverage` field serves the same data with field selection.
pub fn handleCoverage(self: *Server, conn: http_util.Conn) !void {
    const database = self.pool.acquire() catch
        return self.sendJsonResponse(conn, 503, "{\"status\":\"unavailable\",\"reason\":\"db_unavailable\"}");
    defer self.pool.release(database);

    const v1 = database.getSyncStateFull(.v1) catch null;
    const v2 = database.getSyncStateFull(.v2) catch null;
    const safe = database.getFinality(database.chain_id, .safe) catch null;
    const stale = api_common.coverageStale(v1, v2, if (safe) |sp| sp.number else null, database.stale_after_seconds, zsys.timestamp());

    const body = try std.fmt.allocPrint(
        self.allocator,
        "{{\"chainId\":{d},\"stale\":{s},\"protocols\":[{{\"protocol\":\"v1\",\"indexedHead\":{d},\"lastSyncedAt\":{?d}}},{{\"protocol\":\"v2\",\"indexedHead\":{d},\"lastSyncedAt\":{?d}}}]}}",
        .{ database.chain_id, if (stale) "true" else "false", if (v1) |s| s.block else 0, if (v1) |s| s.at else null, if (v2) |s| s.block else 0, if (v2) |s| s.at else null },
    );
    defer self.allocator.free(body);
    try self.sendJsonResponse(conn, 200, body);
}

pub fn handleMetrics(self: *Server, conn: http_util.Conn) !void {
    // Get metrics from GraphQL handler and format as Prometheus
    const metrics_text = try self.graphql_handler.metrics.formatPrometheus(self.allocator);
    defer self.allocator.free(metrics_text);

    // Finality gauges (Task 09): read head/safe/finalized from a pool session. Best-effort
    // — empty on any error so /metrics never fails on the finality read.
    var fin: std.Io.Writer.Allocating = .init(self.allocator);
    defer fin.deinit();
    appendFinalityMetrics(self, &fin) catch {};

    var response: std.Io.Writer.Allocating = .init(self.allocator);
    defer response.deinit();

    const writer = &response.writer;
    try writer.print(
        "HTTP/1.1 200 OK\r\n" ++
            "Connection: close\r\n" ++
            "Content-Type: text/plain; version=0.0.4\r\n" ++
            "Content-Length: {d}\r\n" ++
            "\r\n" ++
            "{s}{s}",
        .{ metrics_text.len + fin.written().len, metrics_text, fin.written() },
    );

    try conn.writeAll(response.written());
}

/// Append Prometheus finality gauges (Task 09): indexed head, safe/finalized positions,
/// safe lag, and both stale flags. Reads a pool session; 0/stale when finality is unpopulated.
fn appendFinalityMetrics(self: *Server, out: *std.Io.Writer.Allocating) !void {
    const database = try self.pool.acquire();
    defer self.pool.release(database);
    const v1 = try database.getSyncStateFull(.v1);
    const v2 = try database.getSyncStateFull(.v2);
    const safe: ?u64 = if (try database.getFinality(database.chain_id, .safe)) |s| s.number else null;
    const finalized = try database.getFinality(database.chain_id, .finalized);
    const coverage_stale = api_common.coverageStale(v1, v2, safe, database.stale_after_seconds, zsys.timestamp());
    try writeFinalityGauges(&out.writer, api_common.indexedHead(v1, v2), safe, if (finalized) |f| f.number else null, coverage_stale);
}

/// Pure Prometheus-gauge formatter for the finality metrics (Task 09). Split out of the
/// DB-coupled fetch so the gauge SET and the lag math are unit-testable. `safe`/`finalized`
/// are the block numbers of the chain's safe/finalized heads (null = not yet observed).
///
/// Two stale gauges, deliberately different: `ensv2_indexing_stale` is the conservative
/// `_finality.isStale` (1 whenever there is no safe head to trust);
/// `ensv2_coverage_stale` is the `stale` flag /ready, /coverage and `_coverage` report,
/// including the COVERAGE_STALE_AFTER_SECONDS fallback.
fn writeFinalityGauges(w: *std.Io.Writer, head: u64, safe: ?u64, finalized: ?u64, coverage_stale: bool) !void {
    try w.print("# TYPE ensv2_indexed_head gauge\nensv2_indexed_head {d}\n", .{head});
    try w.print("# TYPE ensv2_finality_safe gauge\nensv2_finality_safe {d}\n", .{safe orelse 0});
    try w.print("# TYPE ensv2_finality_finalized gauge\nensv2_finality_finalized {d}\n", .{finalized orelse 0});
    const safe_lag: u64 = if (safe) |s| (if (head > s) head - s else 0) else 0;
    try w.print("# TYPE ensv2_finality_safe_lag gauge\nensv2_finality_safe_lag {d}\n", .{safe_lag});
    // Doc step 4: finalized lag (indexed head minus the finalized head).
    const finalized_lag: u64 = if (finalized) |f| (if (head > f) head - f else 0) else 0;
    try w.print("# TYPE ensv2_finality_finalized_lag gauge\nensv2_finality_finalized_lag {d}\n", .{finalized_lag});
    const stale: u8 = if (safe) |s| (if (head < s) @as(u8, 1) else 0) else 1;
    try w.print("# TYPE ensv2_indexing_stale gauge\nensv2_indexing_stale {d}\n", .{stale});
    try w.print("# TYPE ensv2_coverage_stale gauge\nensv2_coverage_stale {d}\n", .{@intFromBool(coverage_stale)});
}

test "writeFinalityGauges: emits the full finality gauge set with correct lag" {
    const a = std.testing.allocator;
    {
        var buf: std.Io.Writer.Allocating = .init(a);
        defer buf.deinit();
        try writeFinalityGauges(&buf.writer, 200, 190, 180, false); // head=200, safe=190, finalized=180
        const o = buf.written();
        try std.testing.expect(std.mem.indexOf(u8, o, "ensv2_indexed_head 200\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, o, "ensv2_finality_safe 190\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, o, "ensv2_finality_finalized 180\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, o, "ensv2_finality_safe_lag 10\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, o, "ensv2_finality_finalized_lag 20\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, o, "ensv2_indexing_stale 0\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, o, "ensv2_coverage_stale 0\n") != null);
    }
    {
        // No finality observed yet -> zeros, and stale=1 (we have no safe head to trust).
        var buf: std.Io.Writer.Allocating = .init(a);
        defer buf.deinit();
        try writeFinalityGauges(&buf.writer, 200, null, null, false);
        const o = buf.written();
        try std.testing.expect(std.mem.indexOf(u8, o, "ensv2_finality_safe 0\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, o, "ensv2_finality_safe_lag 0\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, o, "ensv2_indexing_stale 1\n") != null);
        // The coverage flag is whatever /coverage computed, not the conservative one.
        try std.testing.expect(std.mem.indexOf(u8, o, "ensv2_coverage_stale 0\n") != null);
    }
    {
        var buf: std.Io.Writer.Allocating = .init(a);
        defer buf.deinit();
        try writeFinalityGauges(&buf.writer, 200, null, null, true);
        try std.testing.expect(std.mem.indexOf(u8, buf.written(), "ensv2_coverage_stale 1\n") != null);
    }
}

/// Run one GraphQL query through the full pipeline (pool session, live
/// ENSIP-10 context when enabled, cost model, batch loaders). Shared by the
/// HTTP POST/GET endpoints and the MCP `graphql-query` tool, so every
/// transport gets byte-identical behavior. Block-scopes the session so it
/// returns to the pool before response serialization / socket writes.
pub fn executeQuery(self: *Server, query: []const u8, variables_value: ?std.json.Value, operation_name: ?[]const u8, strict: bool) ![]u8 {
    return blk: {
        const database = try self.pool.acquire();
        defer self.pool.release(database);
        // Live ENSIP-10 record fallback (Task 06): when RESOLVE_LIVE_ENABLED wired a
        // Universal Resolver, thread a per-request LiveContext pinned to the head block
        // the API is reading at (so cached live answers reorg-invalidate). When off, the
        // plain indexed-only handleQuery below runs — byte-identical to before.
        if (self.resolve) |rs| {
            if (rs.live_enabled and !rs.universal_resolver.isZero()) {
                const v1_head = (try database.getSyncState(.v1)) orelse 0;
                const v2_head = (try database.getSyncState(.v2)) orelse 0;
                const use_v1 = v1_head >= v2_head;
                const head = if (use_v1) v1_head else v2_head;
                const head_hash_opt = if (use_v1) try database.getBlockHash(.v1, head) else try database.getBlockHash(.v2, head);
                if (head_hash_opt) |head_hash| {
                    var resolver = resolve_client.Resolver.init(rs.rpc_client, database, rs.chain_id, rs.ttl_s);
                    var live_ctx = universal.LiveContext{
                        .resolver = &resolver,
                        .ur_address = rs.universal_resolver,
                        .block_num = head,
                        .block_hash = head_hash,
                        .now = zsys.timestamp(),
                        .registry = rs.registry,
                        .primary_verify_enabled = rs.primary_verify_enabled,
                    };
                    // CCIP-Read (Task 07): when enabled, attach a real gateway+callback
                    // transport (pinned to the same head) so OffchainLookup reverts complete
                    // offchain. Stack-scoped; lives for the synchronous handleQuery call.
                    var ccip_rt: ccip_transport.RealTransport = undefined;
                    if (rs.ccip_enabled) {
                        ccip_rt = .{
                            .http_client = rs.http_client,
                            .rpc_client = rs.rpc_client,
                            .block_hash = head_hash,
                            .timeout_ms = rs.ccip_timeout_ms,
                        };
                        live_ctx.ccip = .{ .transport = ccip_rt.transport(), .max_redirects = rs.ccip_max_redirects };
                    }
                    break :blk try self.graphql_handler.handleQueryWithResolve(database, query, variables_value, operation_name, strict, @ptrCast(&live_ctx));
                }
            }
        }
        break :blk try self.graphql_handler.handleQuery(database, query, variables_value, operation_name, strict);
    };
}

pub fn handleGraphQLQuery(self: *Server, conn: http_util.Conn, request: []const u8) !void {
    // GraphQL-over-HTTP content negotiation. Default (application/json, */*, or no
    // Accept header) keeps the legacy contract every ensjs / subgraph client relies
    // on: 200 + application/json with errors in the body. A client that explicitly
    // Accepts `application/graphql-response+json` opts into spec status codes (4xx for
    // request / parse / validation failures). The opt-in header is the only thing that
    // changes behaviour, so existing clients are unaffected.
    const strict = acceptsResponseJson(request);
    const ct = graphqlContentType(strict);

    // Extract GraphQL query from POST body
    // Find the body after double newline
    const body = http_util.requestBody(request) orelse {
        return try self.sendRequestError(conn, "Invalid request format", strict);
    };

    // Parse JSON body to extract query and variables
    const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch {
        return try self.sendRequestError(conn, "Invalid JSON body", strict);
    };
    defer parsed.deinit();

    // Body must be a JSON object. Null, arrays, primitives, etc. would panic on .object access.
    if (parsed.value != .object) {
        return try self.sendRequestError(conn, "Request body must be a JSON object", strict);
    }

    const query_value = parsed.value.object.get("query") orelse {
        return try self.sendRequestError(conn, "Query field required", strict);
    };

    // Query must be a string. Integer/null/etc. would panic on .string access.
    if (query_value != .string) {
        return try self.sendRequestError(conn, "`query` field must be a string", strict);
    }
    const query = query_value.string;

    // SECURITY: Validate GraphQL query length to prevent DoS attacks
    validation.validateGraphQLQuery(query) catch {
        return try self.sendRequestError(conn, "Invalid GraphQL query: length must be between 1 and 10000 characters", strict);
    };

    // Extract variables if present (optional)
    const variables_value = parsed.value.object.get("variables");

    // Extract operationName if present (optional, used when query has multiple operations)
    const operation_name: ?[]const u8 = if (parsed.value.object.get("operationName")) |op_val|
        if (op_val == .string) op_val.string else null
    else
        null;

    // Strict mode validates parameter types per the GraphQL-over-HTTP spec (400 on a
    // wrong-typed variables/operationName/extensions). Legacy mode stays lenient —
    // unchanged for existing clients, which never send malformed parameters anyway.
    if (strict) {
        if (variables_value) |v| {
            if (v != .object and v != .null) return try self.sendRequestError(conn, "`variables` must be an object", strict);
        }
        if (parsed.value.object.get("operationName")) |ov| {
            if (ov != .string and ov != .null) return try self.sendRequestError(conn, "`operationName` must be a string", strict);
        }
        if (parsed.value.object.get("extensions")) |ev| {
            if (ev != .object and ev != .null) return try self.sendRequestError(conn, "`extensions` must be an object", strict);
        }
    }

    std.log.info("GraphQL query: {s}", .{query});
    if (variables_value) |v| {
        std.log.info("Variables provided: {any}", .{v});
    }
    if (operation_name) |name| {
        std.log.info("Operation name: {s}", .{name});
    }

    // Handle the query with variables and operation name
    const result = try self.executeQuery(query, variables_value, operation_name, strict);
    defer self.allocator.free(result);

    // Legacy mode: always 200 (errors travel in the body) — unchanged. Strict mode:
    // map the response to a spec status code (4xx for request/parse/validation errors)
    // and drop the `data:null` entry the spec forbids on request errors.
    const status: u16 = if (strict) strictStatus(result) else 200;
    if (strict and status == 400) {
        const stripped = try stripNullData(self.allocator, result);
        defer self.allocator.free(stripped);
        try self.sendGraphQLResponse(conn, status, stripped, ct);
    } else {
        try self.sendGraphQLResponse(conn, status, result, ct);
    }
}

/// GraphQL-over-HTTP GET support. Bare `GET /graphql` serves the interactive playground
/// (unchanged). `GET /graphql?query=...&variables=...&operationName=...` executes the
/// query, reusing the same content negotiation, handler, and status mapping as POST.
/// Mutations are rejected with 4xx (this is a read-only indexer; GET must stay safe).
pub fn handleGraphQLGet(self: *Server, conn: http_util.Conn, path: []const u8, request: []const u8) !void {
    const qmark = std.mem.indexOfScalar(u8, path, '?');
    const query_enc: ?[]const u8 = if (qmark) |q| getQueryParam(path[q + 1 ..], "query") else null;

    // No `?query=` → serve the playground, exactly as before.
    if (query_enc == null) return try self.handleGraphQLPlayground(conn);

    const strict = acceptsResponseJson(request);
    const ct = graphqlContentType(strict);
    const qs = path[qmark.? + 1 ..];

    const query = try urlDecode(self.allocator, query_enc.?);
    defer self.allocator.free(query);

    validation.validateGraphQLQuery(query) catch {
        return try self.sendRequestError(conn, "Invalid GraphQL query: length must be between 1 and 10000 characters", strict);
    };

    // GET MUST NOT execute mutations (GraphQL-over-HTTP). We have none anyway.
    if (queryIsMutation(self.allocator, query)) {
        return try self.sendRequestError(conn, "GET supports query operations only; use POST for mutations", strict);
    }

    // Optional URL-encoded JSON `variables`.
    var variables_owned: ?std.json.Parsed(std.json.Value) = null;
    defer if (variables_owned) |p| p.deinit();
    var variables_value: ?std.json.Value = null;
    if (getQueryParam(qs, "variables")) |vars_enc| {
        const vars_json = try urlDecode(self.allocator, vars_enc);
        defer self.allocator.free(vars_json);
        const p = std.json.parseFromSlice(std.json.Value, self.allocator, vars_json, .{}) catch {
            return try self.sendRequestError(conn, "`variables` must be a JSON object", strict);
        };
        if (p.value != .object and p.value != .null) {
            p.deinit();
            return try self.sendRequestError(conn, "`variables` must be a JSON object", strict);
        }
        variables_owned = p;
        variables_value = p.value;
    }

    // Optional `operationName`.
    var op_name_owned: ?[]u8 = null;
    defer if (op_name_owned) |o| self.allocator.free(o);
    var operation_name: ?[]const u8 = null;
    if (getQueryParam(qs, "operationName")) |op_enc| {
        op_name_owned = try urlDecode(self.allocator, op_enc);
        operation_name = op_name_owned;
    }

    // Block-scope the session so it returns to the pool before response
    // serialization and the (possibly slow) socket write to the client.
    const result = blk: {
        const database = try self.pool.acquire();
        defer self.pool.release(database);
        // Live ENSIP-10 record fallback (Task 06): when RESOLVE_LIVE_ENABLED wired a
        // Universal Resolver, thread a per-request LiveContext pinned to the head block
        // the API is reading at (so cached live answers reorg-invalidate). When off, the
        // plain indexed-only handleQuery below runs — byte-identical to before.
        if (self.resolve) |rs| {
            if (rs.live_enabled and !rs.universal_resolver.isZero()) {
                const v1_head = (try database.getSyncState(.v1)) orelse 0;
                const v2_head = (try database.getSyncState(.v2)) orelse 0;
                const use_v1 = v1_head >= v2_head;
                const head = if (use_v1) v1_head else v2_head;
                const head_hash_opt = if (use_v1) try database.getBlockHash(.v1, head) else try database.getBlockHash(.v2, head);
                if (head_hash_opt) |head_hash| {
                    var resolver = resolve_client.Resolver.init(rs.rpc_client, database, rs.chain_id, rs.ttl_s);
                    var live_ctx = universal.LiveContext{
                        .resolver = &resolver,
                        .ur_address = rs.universal_resolver,
                        .block_num = head,
                        .block_hash = head_hash,
                        .now = zsys.timestamp(),
                        .registry = rs.registry,
                        .primary_verify_enabled = rs.primary_verify_enabled,
                    };
                    // CCIP-Read (Task 07): when enabled, attach a real gateway+callback
                    // transport (pinned to the same head) so OffchainLookup reverts complete
                    // offchain. Stack-scoped; lives for the synchronous handleQuery call.
                    var ccip_rt: ccip_transport.RealTransport = undefined;
                    if (rs.ccip_enabled) {
                        ccip_rt = .{
                            .http_client = rs.http_client,
                            .rpc_client = rs.rpc_client,
                            .block_hash = head_hash,
                            .timeout_ms = rs.ccip_timeout_ms,
                        };
                        live_ctx.ccip = .{ .transport = ccip_rt.transport(), .max_redirects = rs.ccip_max_redirects };
                    }
                    break :blk try self.graphql_handler.handleQueryWithResolve(database, query, variables_value, operation_name, strict, @ptrCast(&live_ctx));
                }
            }
        }
        break :blk try self.graphql_handler.handleQuery(database, query, variables_value, operation_name, strict);
    };
    defer self.allocator.free(result);

    const status: u16 = if (strict) strictStatus(result) else 200;
    if (strict and status == 400) {
        const stripped = try stripNullData(self.allocator, result);
        defer self.allocator.free(stripped);
        try self.sendGraphQLResponse(conn, status, stripped, ct);
    } else {
        try self.sendGraphQLResponse(conn, status, result, ct);
    }
}

pub fn handleGraphQLPlayground(self: *Server, conn: http_util.Conn) !void {
    // Playground asset extracted to graphiql.html (commit 5308c2d) so the
    // page can be edited without recompiling. The staging branch's inline
    // version included an example with `name_in` — that example is preserved
    // as a section in the .html file so the merge keeps both branches' intent.
    const html = @embedFile("graphiql.html");

    var response: std.Io.Writer.Allocating = .init(self.allocator);
    defer response.deinit();

    const writer = &response.writer;
    try writer.print(
        "HTTP/1.1 200 OK\r\n" ++
            "Connection: close\r\n" ++
            "Content-Type: text/html\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "\r\n" ++
            "{s}",
        .{ html.len, html },
    );

    try conn.writeAll(response.written());
}
