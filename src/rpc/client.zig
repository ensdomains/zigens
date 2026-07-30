const std = @import("std");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;

/// Helper to write JSON values for RPC params (Zig 0.15 compatible)
fn writeJsonValue(writer: anytype, value: anytype) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .bool => try writer.print("{}", .{value}),
        .int, .comptime_int => try writer.print("{d}", .{value}),
        .float, .comptime_float => try writer.print("{d}", .{value}),
        .pointer => |ptr_info| {
            if (ptr_info.size == .slice and ptr_info.child == u8) {
                // String
                try writer.print("\"{s}\"", .{value});
            } else {
                @compileError("Unsupported pointer type for JSON");
            }
        },
        .@"struct" => {
            // Check if it's a JSON ObjectMap
            if (T == std.json.ObjectMap) {
                // Serialize as JSON object
                try writer.writeAll("{");
                var it = value.iterator();
                var first = true;
                while (it.next()) |entry| {
                    if (!first) try writer.writeAll(",");
                    first = false;
                    try writer.print("\"{s}\":", .{entry.key_ptr.*});
                    try writeJsonValue(writer, entry.value_ptr.*);
                }
                try writer.writeAll("}");
                return;
            }
            // Otherwise handle as regular struct
            try writer.writeAll("{");
            inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("\"{s}\":", .{field.name});
                try writeJsonValue(writer, @field(value, field.name));
            }
            try writer.writeAll("}");
        },
        .@"union" => {
            // Handle JSON Value union
            if (T == std.json.Value) {
                switch (value) {
                    .null => try writer.writeAll("null"),
                    .bool => |b| try writer.print("{}", .{b}),
                    .integer => |n| try writer.print("{d}", .{n}),
                    .float => |f| try writer.print("{d}", .{f}),
                    .number_string => |s| try writer.writeAll(s),
                    .string => |s| try writer.print("\"{s}\"", .{s}),
                    .array => |arr| {
                        try writer.writeAll("[");
                        for (arr.items, 0..) |item, i| {
                            if (i > 0) try writer.writeAll(",");
                            try writeJsonValue(writer, item);
                        }
                        try writer.writeAll("]");
                    },
                    .object => |obj| {
                        try writer.writeAll("{");
                        var it = obj.iterator();
                        var first = true;
                        while (it.next()) |entry| {
                            if (!first) try writer.writeAll(",");
                            first = false;
                            try writer.print("\"{s}\":", .{entry.key_ptr.*});
                            try writeJsonValue(writer, entry.value_ptr.*);
                        }
                        try writer.writeAll("}");
                    },
                }
                return;
            }
            @compileError("Unsupported union type for JSON: " ++ @typeName(T));
        },
        else => @compileError("Unsupported type for JSON: " ++ @typeName(T)),
    }
}

pub const Block = struct {
    number: u64,
    hash: Hash,
    parent_hash: Hash,
    timestamp: u64,
};

pub const Log = struct {
    address: Address,
    topics: []Hash,
    data: []u8,
    block_number: u64,
    transaction_hash: Hash,
    transaction_index: u32,
    log_index: u32,
    removed: bool,
    /// Block timestamp - optional, some RPC providers include it in eth_getLogs response
    block_timestamp: ?u64,
    /// Block hash - included in eth_getLogs responses per Ethereum JSON-RPC spec
    block_hash: ?Hash,

    pub fn deinit(self: *Log, allocator: std.mem.Allocator) void {
        allocator.free(self.topics);
        allocator.free(self.data);
    }
};

pub const Transaction = struct {
    hash: Hash,
    block_number: u64,
    from: Address,
    to: ?Address,
    input: []u8,
    value: []const u8,
    gas: u64,
    gas_price: []const u8,

    pub fn deinit(self: *Transaction, allocator: std.mem.Allocator) void {
        allocator.free(self.input);
    }
};

/// Walk an http.Client's idle-connection pool and destroy every entry.
///
/// Workaround for Zig 0.15.2: std.http.Client.ConnectionPool.resize is broken
/// (Client.zig:167 calls `popped.data.close()` but the popped value is a
/// `*DoublyLinkedList.Node` with no `data` field; the function fails to
/// compile when invoked). We replicate what resize(0) was meant to do — lock
/// the pool mutex, pop every node from `free`, recover the parent Connection
/// via @fieldParentPtr, and call Connection.destroy() (which closes the
/// socket and frees the per-connection allocation).
///
/// Touches stdlib internals (the ConnectionPool struct fields and
/// Connection.pool_node are public, but reaching into them is brittle).
/// Safe-ish: only the indexer thread writes to this pool, and the API
/// server has its own http.Client.
fn drainIdleHttpConnections(http_client: *std.http.Client) void {
    const pool = &http_client.connection_pool;
    pool.mutex.lock();
    defer pool.mutex.unlock();

    while (pool.free.popFirst()) |node| {
        pool.free_len -= 1;
        const conn: *std.http.Client.Connection = @alignCast(@fieldParentPtr("pool_node", node));
        conn.destroy();
    }
}

pub const Client = struct {
    allocator: std.mem.Allocator,
    rpc_url: []const u8,
    request_id: std.atomic.Value(u64),
    http_client: *std.http.Client,
    owns_http_client: bool,

    pub fn init(allocator: std.mem.Allocator, rpc_url: []const u8) !*Client {
        const http_client = try allocator.create(std.http.Client);
        http_client.* = std.http.Client{ .allocator = allocator };

        const client = try allocator.create(Client);
        client.* = .{
            .allocator = allocator,
            .rpc_url = rpc_url,
            .request_id = std.atomic.Value(u64).init(1),
            .http_client = http_client,
            .owns_http_client = true,
        };
        return client;
    }

    pub fn initWithSharedHttpClient(allocator: std.mem.Allocator, rpc_url: []const u8, http_client: *std.http.Client) !*Client {
        const client = try allocator.create(Client);
        client.* = .{
            .allocator = allocator,
            .rpc_url = rpc_url,
            .request_id = std.atomic.Value(u64).init(1),
            .http_client = http_client,
            .owns_http_client = false,
        };
        return client;
    }

    pub fn deinit(self: *Client) void {
        if (self.owns_http_client) {
            self.http_client.deinit();
            self.allocator.destroy(self.http_client);
        }
        self.allocator.destroy(self);
    }

    fn nextRequestId(self: *Client) u64 {
        return self.request_id.fetchAdd(1, .monotonic);
    }

    /// Execute a JSON-RPC POST using std.http.Client with retry and exponential backoff.
    /// Uses the shared http_client (connection pooling + keep-alive) and gzip/deflate decompression.
    /// Returns the response body on success, error on failure after all retries exhausted.
    ///
    /// Timeout NOTE: Zig 0.15's std.http.Client does not expose per-request connect/read
    /// timeouts. Previously `curl --connect-timeout 30 --max-time 120` protected against
    /// hung RPC endpoints. Until Zig's http client exposes timeouts (or we wrap fetch in a
    /// watchdog thread), a single request that hangs can block this indexer thread indefinitely.
    /// Mitigation today: most real RPC providers return quickly; TCP keep-alive detects dead
    /// connections within ~2 hours by default.
    fn executeHttpRequest(self: *Client, arena_allocator: std.mem.Allocator, request_body: []const u8) ![]const u8 {
        const max_retries: u32 = 3;
        const max_response_bytes: usize = 50 * 1024 * 1024;
        var attempt: u32 = 0;
        var last_error: ?anyerror = null;

        // Identity encoding, NOT gzip/deflate: Zig 0.15.2's flate decompressor
        // panics (`unreachable` in unreachableRebase) mid-stream on large
        // compressed bodies — a hard process kill, not a catchable error, and
        // large getLogs responses (the batch-wide resolver pass, catch-up
        // batches) cross the threshold routinely. The override must go through
        // `.headers.accept_encoding` — an extra_headers entry DUPLICATES the
        // client's default Accept-Encoding header instead of replacing it.
        const extra_headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        };

        while (attempt < max_retries) : (attempt += 1) {
            if (attempt > 0) {
                const delay_ms: u64 = @as(u64, 1000) * (@as(u64, 1) << @intCast(attempt - 1));
                std.log.warn("RPC request failed, retrying in {d}ms (attempt {d}/{d})", .{ delay_ms, attempt + 1, max_retries });
                std.Thread.sleep(delay_ms * std.time.ns_per_ms);
            }

            const start_ms = std.time.milliTimestamp();

            var response_buf: std.Io.Writer.Allocating = .init(arena_allocator);
            defer response_buf.deinit();

            const result = self.http_client.fetch(.{
                .location = .{ .url = self.rpc_url },
                .method = .POST,
                .payload = request_body,
                .extra_headers = &extra_headers,
                .headers = .{ .accept_encoding = .{ .override = "identity" } },
                .response_writer = &response_buf.writer,
                .keep_alive = true,
            }) catch |err| {
                if (err == error.StreamTooLong) {
                    // Response exceeds buffer — not a transient failure; the
                    // caller's adaptive chunking should shrink the request.
                    std.log.debug("Response too large: {}", .{err});
                    return err;
                }
                // Zig 0.15.2's std.http.Client does NOT evict pooled connections
                // when fetch fails — Request.deinit() looks at reader.state to
                // decide closing, and several failure modes leave state in a
                // shape that makes the dead socket get returned to the free
                // pool. Next fetch picks the dead socket and fails the same
                // way. We can't use ConnectionPool.resize either — it's itself
                // broken in 0.15.2 (Client.zig:167 calls `popped.data.close()`
                // but DoublyLinkedList.Node has no `data` field; doesn't
                // compile when invoked).
                //
                // Workaround: on ANY transient fetch error, walk the free pool
                // and destroy every idle connection so the next attempt opens
                // a fresh socket. We've observed `ReadFailed` and `WriteFailed`
                // both arise from stale pooled connections (different TCP
                // states at the time of reuse); draining on either keeps the
                // pool healthy. After heavy initial sync the pool may hold
                // several stale connections; one drain + one retry typically
                // restores forward progress.
                //
                // Remove this whole block once Zig fixes the pool eviction
                // or we move to 0.16 (which rewrites http.Client on std.Io).
                if (err == error.WriteFailed or
                    err == error.ReadFailed or
                    err == error.UnexpectedReadFailure or
                    err == error.EndOfStream or
                    err == error.BrokenPipe or
                    err == error.ConnectionResetByPeer)
                {
                    drainIdleHttpConnections(self.http_client);
                    last_error = err;
                    std.log.warn("http.fetch {} (likely stale pooled connection); evicted free pool, retrying", .{err});
                    continue;
                }
                last_error = err;
                std.log.warn("http.fetch error: {}", .{err});
                continue;
            };

            const status_code = @intFromEnum(result.status);
            if (status_code < 200 or status_code >= 300) {
                // Capture response body for diagnostics (RPC providers typically send a
                // JSON error describing the issue: "block range too large", "too many logs", etc.).
                const body_preview_len = @min(response_buf.written().len, 512);
                const body_preview = response_buf.written()[0..body_preview_len];

                // 4xx = permanent client error (request too big, malformed, etc.) — caller's
                // adaptive chunking can halve the range and retry. EXCEPT 408 (Request Timeout)
                // and 429 (Too Many Requests), which are explicitly transient per HTTP spec:
                // 408 means "server timed out waiting; resend the request", 429 is rate-limit
                // and resolves on backoff. Treating either as permanent aborts indexing on a
                // hiccup that retry would have absorbed (observed at deployment startup with
                // some RPC providers returning 408 under load).
                if (status_code >= 400 and status_code < 500 and status_code != 408 and status_code != 429) {
                    std.log.warn("HTTP {d} from RPC (permanent; not retrying). Body: {s}", .{ status_code, body_preview });
                    return error.RpcError;
                }

                // 5xx, 408, 429, and other transient: retry with backoff
                last_error = error.HttpError;
                std.log.warn("HTTP {d} from RPC (transient; retrying). Body: {s}", .{ status_code, body_preview });
                continue;
            }

            const body = response_buf.written();
            if (body.len == 0) {
                last_error = error.HttpError;
                std.log.warn("http.fetch returned empty response", .{});
                continue;
            }
            if (body.len > max_response_bytes) {
                return error.StreamTooLong;
            }

            const elapsed = std.time.milliTimestamp() - start_ms;
            if (elapsed > 500) {
                std.log.debug("RPC http took {d}ms, response {d} bytes", .{ elapsed, body.len });
            }

            // Copy out of the allocating writer's arena-backed buffer
            return try arena_allocator.dupe(u8, body);
        }

        std.log.err("RPC request failed after {d} retries", .{max_retries});
        return last_error orelse error.HttpError;
    }

    fn makeRpcCall(self: *Client, method: []const u8, params: anytype) !std.json.Parsed(std.json.Value) {
        const request_id = self.nextRequestId();

        // Use arena allocator for request/response buffers
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        // Build JSON-RPC request manually for Zig 0.15
        var request_buf: std.ArrayList(u8) = .{};
        const writer = request_buf.writer(arena_allocator);
        try writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":", .{ request_id, method });

        // Handle params
        const ParamsType = @TypeOf(params);
        const params_type_info = @typeInfo(ParamsType);

        switch (params_type_info) {
            .@"struct" => |struct_info| {
                if (struct_info.fields.len == 0) {
                    // Empty struct = empty array
                    try writer.writeAll("[]");
                } else {
                    // Write params as array
                    try writer.writeAll("[");
                    inline for (struct_info.fields, 0..) |field, i| {
                        if (i > 0) try writer.writeAll(",");
                        const value = @field(params, field.name);
                        try writeJsonValue(writer, value);
                    }
                    try writer.writeAll("]");
                }
            },
            else => try writer.writeAll("[]"),
        }

        try writer.writeAll("}");

        // Execute HTTP request with retry logic
        const response_body = try self.executeHttpRequest(arena_allocator, request_buf.items);

        // Parse JSON response with main allocator (result will outlive this function)
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response_body, .{}) catch |err| {
            // Log the first 500 chars of response to help debug non-JSON responses (rate limiting, HTML errors, etc.)
            const preview_len = @min(response_body.len, 500);
            std.log.err("Failed to parse RPC response as JSON ({s}): {s}", .{ method, response_body[0..preview_len] });
            return err;
        };
        errdefer parsed.deinit();

        const response = parsed.value.object;

        // Check for errors
        if (response.get("error")) |err| {
            const error_obj = err.object;
            const error_message = error_obj.get("message").?.string;
            std.log.err("RPC error: {s}", .{error_message});
            return error.RpcError;
        }

        return parsed;
    }

    /// Make a single RPC call with pre-built JSON params
    fn makeRpcCallWithParams(self: *Client, method: []const u8, params: std.json.Value) !std.json.Parsed(std.json.Value) {
        const request_id = self.nextRequestId();

        // Use arena allocator for request/response buffers
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        // Build JSON-RPC request
        var request_buf: std.ArrayList(u8) = .{};
        const writer = request_buf.writer(arena_allocator);
        try writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":", .{ request_id, method });

        // Write params as JSON
        try writeJsonValue(writer, params);

        try writer.writeAll("}");

        // Execute HTTP request with retry logic
        const response_body = try self.executeHttpRequest(arena_allocator, request_buf.items);

        // Parse JSON response with main allocator (result will outlive this function)
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response_body, .{}) catch |err| {
            const preview_len = @min(response_body.len, 500);
            std.log.err("Failed to parse RPC response as JSON ({s}): {s}", .{ method, response_body[0..preview_len] });
            return err;
        };
        errdefer parsed.deinit();

        const response = parsed.value.object;

        // Check for errors
        if (response.get("error")) |err| {
            const error_obj = err.object;
            const error_message = error_obj.get("message").?.string;
            std.log.err("RPC error: {s}", .{error_message});
            return error.RpcError;
        }

        return parsed;
    }

    /// Batch request descriptor
    pub const BatchRequest = struct {
        method: []const u8,
        params: std.json.Value,
    };

    /// Make multiple RPC calls in a single HTTP request (JSON-RPC batch)
    /// Returns array of responses in the same order as requests
    fn makeBatchRpcCall(self: *Client, requests: []const BatchRequest) !std.json.Parsed(std.json.Value) {
        // Use arena allocator for request/response buffers
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        // Build JSON-RPC batch request array
        var request_buf: std.ArrayList(u8) = .{};
        const writer = request_buf.writer(arena_allocator);
        try writer.writeAll("[");

        for (requests, 0..) |req, i| {
            const request_id = self.nextRequestId();

            if (i > 0) try writer.writeAll(",");
            try writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":", .{ request_id, req.method });
            try writeJsonValue(writer, req.params);
            try writer.writeAll("}");
        }

        try writer.writeAll("]");

        // Execute HTTP request with retry logic
        const response_body = try self.executeHttpRequest(arena_allocator, request_buf.items);

        // Parse JSON response with main allocator (result will outlive this function)
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response_body, .{}) catch |err| {
            // Log the first 500 chars of response to help debug non-JSON responses (rate limiting, HTML errors, etc.)
            const preview_len = @min(response_body.len, 500);
            std.log.err("Failed to parse batch RPC response as JSON: {s}", .{response_body[0..preview_len]});
            return err;
        };
        errdefer parsed.deinit();

        // Batch responses are returned as an array
        if (parsed.value != .array) {
            std.log.err("Expected array response for batch request", .{});
            return error.RpcError;
        }

        // IMPORTANT: JSON-RPC batch responses can be returned in any order!
        // We must sort them by ID to match the original request order.
        const ResponseSort = struct {
            pub fn lessThan(_: void, lhs: std.json.Value, rhs: std.json.Value) bool {
                const lhs_id = lhs.object.get("id").?.integer;
                const rhs_id = rhs.object.get("id").?.integer;
                return lhs_id < rhs_id;
            }
        };
        std.mem.sort(std.json.Value, parsed.value.array.items, {}, ResponseSort.lessThan);

        // Check each response for errors
        for (parsed.value.array.items) |response_value| {
            const response = response_value.object;
            if (response.get("error")) |err| {
                const error_obj = err.object;
                const error_message = error_obj.get("message").?.string;
                std.log.err("RPC batch error: {s}", .{error_message});
                return error.RpcError;
            }
        }

        return parsed;
    }

    pub fn getBlockNumber(self: *Client) !u64 {
        const parsed = try self.makeRpcCall("eth_blockNumber", .{});
        defer parsed.deinit();

        const result = parsed.value.object.get("result").?;
        const hex_str = result.string;
        const block_num = try std.fmt.parseInt(u64, hex_str[2..], 16);
        return block_num;
    }

    pub fn getBlockByNumber(self: *Client, block_number: u64, include_txs: bool) !Block {
        const block_hex = try std.fmt.allocPrint(self.allocator, "0x{x}", .{block_number});
        defer self.allocator.free(block_hex);

        const parsed = try self.makeRpcCall("eth_getBlockByNumber", .{ block_hex, include_txs });
        defer parsed.deinit();

        const result = parsed.value.object.get("result").?;
        if (result == .null) {
            return error.BlockNotFound;
        }

        const block_obj = result.object;

        return Block{
            .number = try std.fmt.parseInt(u64, block_obj.get("number").?.string[2..], 16),
            .hash = try Hash.fromHex(block_obj.get("hash").?.string),
            .parent_hash = try Hash.fromHex(block_obj.get("parentHash").?.string),
            .timestamp = try std.fmt.parseInt(u64, block_obj.get("timestamp").?.string[2..], 16),
        };
    }

    pub fn getLogs(self: *Client, from_block: u64, to_block: u64, address: ?Address, topics: []const ?Hash) ![]Log {
        // Use arena allocator to keep all filter strings alive during the call
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        // Build filter object with arena-allocated strings
        const from_hex = try std.fmt.allocPrint(arena_allocator, "0x{x}", .{from_block});
        const to_hex = try std.fmt.allocPrint(arena_allocator, "0x{x}", .{to_block});

        var filter = std.json.ObjectMap.init(arena_allocator);
        try filter.put("fromBlock", .{ .string = from_hex });
        try filter.put("toBlock", .{ .string = to_hex });

        if (address) |addr| {
            const addr_hex = try addr.toHex(arena_allocator);
            try filter.put("address", .{ .string = addr_hex });
        }

        // Convert topics to JSON array
        if (topics.len > 0) {
            var topics_array = std.json.Array.init(arena_allocator);

            for (topics) |topic_opt| {
                if (topic_opt) |topic| {
                    const topic_hex = try topic.toHex(arena_allocator);
                    try topics_array.append(.{ .string = topic_hex });
                } else {
                    try topics_array.append(.null);
                }
            }

            try filter.put("topics", .{ .array = topics_array });
        }

        const parsed = try self.makeRpcCall("eth_getLogs", .{filter});
        defer parsed.deinit();

        const result = parsed.value.object.get("result").?;
        const logs_array = result.array;
        var logs = try self.allocator.alloc(Log, logs_array.items.len);

        for (logs_array.items, 0..) |log_value, i| {
            const log_obj = log_value.object;

            // Parse topics
            const topics_json = log_obj.get("topics").?.array;
            var log_topics = try self.allocator.alloc(Hash, topics_json.items.len);
            for (topics_json.items, 0..) |topic_val, j| {
                log_topics[j] = try Hash.fromHex(topic_val.string);
            }

            // Parse data
            const data_hex = log_obj.get("data").?.string;
            const data_bytes = try self.hexToBytes(data_hex);

            logs[i] = Log{
                .address = try Address.fromHex(log_obj.get("address").?.string),
                .topics = log_topics,
                .data = data_bytes,
                .block_number = try std.fmt.parseInt(u64, log_obj.get("blockNumber").?.string[2..], 16),
                .transaction_hash = try Hash.fromHex(log_obj.get("transactionHash").?.string),
                .transaction_index = @intCast(try std.fmt.parseInt(u64, log_obj.get("transactionIndex").?.string[2..], 16)),
                .log_index = @intCast(try std.fmt.parseInt(u64, log_obj.get("logIndex").?.string[2..], 16)),
                .removed = if (log_obj.get("removed")) |r| r.bool else false,
                .block_timestamp = if (log_obj.get("blockTimestamp")) |ts| std.fmt.parseInt(u64, ts.string[2..], 16) catch null else null,
                .block_hash = if (log_obj.get("blockHash")) |bh| Hash.fromHex(bh.string) catch null else null,
            };
        }

        return logs;
    }

    /// Descriptor for a single getLogs request in a batch
    pub const BatchGetLogsRequest = struct {
        from_block: u64,
        to_block: u64,
        address: ?Address,
        topics: []const ?Hash,
    };

    /// Batch version of getLogs - fetches multiple log queries in a single HTTP request
    /// Returns array of log arrays in the same order as requests
    /// Caller must free each log array and its contents
    pub fn getLogsBatch(self: *Client, requests: []const BatchGetLogsRequest) ![][]Log {
        // Use arena allocator for building batch request params
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        // Build batch requests
        var batch_requests = try arena_allocator.alloc(BatchRequest, requests.len);

        for (requests, 0..) |req, i| {
            // Build filter object
            const from_hex = try std.fmt.allocPrint(arena_allocator, "0x{x}", .{req.from_block});
            const to_hex = try std.fmt.allocPrint(arena_allocator, "0x{x}", .{req.to_block});

            var filter = std.json.ObjectMap.init(arena_allocator);
            try filter.put("fromBlock", .{ .string = from_hex });
            try filter.put("toBlock", .{ .string = to_hex });

            if (req.address) |addr| {
                const addr_hex = try addr.toHex(arena_allocator);
                try filter.put("address", .{ .string = addr_hex });
            }

            // Convert topics to JSON array
            if (req.topics.len > 0) {
                var topics_array = std.json.Array.init(arena_allocator);

                for (req.topics) |topic_opt| {
                    if (topic_opt) |topic| {
                        const topic_hex = try topic.toHex(arena_allocator);
                        try topics_array.append(.{ .string = topic_hex });
                    } else {
                        try topics_array.append(.null);
                    }
                }

                try filter.put("topics", .{ .array = topics_array });
            }

            // Create batch request with filter as param array
            var params_array = std.json.Array.init(arena_allocator);
            try params_array.append(.{ .object = filter });

            batch_requests[i] = .{
                .method = "eth_getLogs",
                .params = .{ .array = params_array },
            };
        }

        // Make batch RPC call
        const parsed = try self.makeBatchRpcCall(batch_requests);
        defer parsed.deinit();

        const responses = parsed.value.array;

        // Allocate array for results
        var results = try self.allocator.alloc([]Log, requests.len);
        errdefer {
            for (results, 0..) |logs, i| {
                if (i > 0) { // Only free already-processed results
                    for (logs) |*log| {
                        log.deinit(self.allocator);
                    }
                    self.allocator.free(logs);
                }
            }
            self.allocator.free(results);
        }

        // Parse each response
        for (responses.items, 0..) |response_value, i| {
            const response = response_value.object;
            const result = response.get("result").?;
            const logs_array = result.array;

            var logs = try self.allocator.alloc(Log, logs_array.items.len);
            errdefer {
                for (logs, 0..) |*log, j| {
                    if (j > 0) log.deinit(self.allocator);
                }
                self.allocator.free(logs);
            }

            for (logs_array.items, 0..) |log_value, j| {
                const log_obj = log_value.object;

                // Parse topics
                const topics_json = log_obj.get("topics").?.array;
                var log_topics = try self.allocator.alloc(Hash, topics_json.items.len);
                for (topics_json.items, 0..) |topic_val, k| {
                    log_topics[k] = try Hash.fromHex(topic_val.string);
                }

                // Parse data
                const data_hex = log_obj.get("data").?.string;
                const data_bytes = try self.hexToBytes(data_hex);

                logs[j] = Log{
                    .address = try Address.fromHex(log_obj.get("address").?.string),
                    .topics = log_topics,
                    .data = data_bytes,
                    .block_number = try std.fmt.parseInt(u64, log_obj.get("blockNumber").?.string[2..], 16),
                    .transaction_hash = try Hash.fromHex(log_obj.get("transactionHash").?.string),
                    .transaction_index = @intCast(try std.fmt.parseInt(u64, log_obj.get("transactionIndex").?.string[2..], 16)),
                    .log_index = @intCast(try std.fmt.parseInt(u64, log_obj.get("logIndex").?.string[2..], 16)),
                    .removed = if (log_obj.get("removed")) |r| r.bool else false,
                    .block_timestamp = if (log_obj.get("blockTimestamp")) |ts| std.fmt.parseInt(u64, ts.string[2..], 16) catch null else null,
                    .block_hash = if (log_obj.get("blockHash")) |bh| Hash.fromHex(bh.string) catch null else null,
                };
            }

            results[i] = logs;
        }

        return results;
    }

    /// Descriptor for a multi-address getLogs request with OR topic support
    /// This allows querying multiple contracts and multiple event types in a single RPC call
    pub const MultiAddressLogsRequest = struct {
        from_block: u64,
        to_block: u64,
        /// Multiple addresses to query (all contracts in one call)
        addresses: []const Address,
        /// First topic position supports OR matching (array of event signatures)
        /// e.g., [AddressChanged, TextChanged, ContentHashChanged] matches ANY of these
        topic0_or: []const Hash,
    };

    /// Fetch logs from multiple addresses with OR topic matching in a single RPC call
    /// This is much more efficient than querying each address/topic separately
    /// Returns all matching logs - caller must filter by address/topic if needed
    /// Caller must free returned logs and their contents
    pub fn getLogsMultiAddress(self: *Client, request: MultiAddressLogsRequest) ![]Log {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        // Build filter object
        const from_hex = try std.fmt.allocPrint(arena_alloc, "0x{x}", .{request.from_block});
        const to_hex = try std.fmt.allocPrint(arena_alloc, "0x{x}", .{request.to_block});

        var filter = std.json.ObjectMap.init(arena_alloc);
        try filter.put("fromBlock", .{ .string = from_hex });
        try filter.put("toBlock", .{ .string = to_hex });

        // Add addresses array
        if (request.addresses.len > 0) {
            var addr_array = std.json.Array.init(arena_alloc);
            for (request.addresses) |addr| {
                const addr_hex = try addr.toHex(arena_alloc);
                try addr_array.append(.{ .string = addr_hex });
            }
            try filter.put("address", .{ .array = addr_array });
        }

        // Add topics with OR support for topic[0]
        if (request.topic0_or.len > 0) {
            var topics_array = std.json.Array.init(arena_alloc);

            // topic[0] is an array for OR matching
            var topic0_array = std.json.Array.init(arena_alloc);
            for (request.topic0_or) |topic| {
                const topic_hex = try topic.toHex(arena_alloc);
                try topic0_array.append(.{ .string = topic_hex });
            }
            try topics_array.append(.{ .array = topic0_array });

            try filter.put("topics", .{ .array = topics_array });
        }

        // Build params array
        var params_array = std.json.Array.init(arena_alloc);
        try params_array.append(.{ .object = filter });

        // Make RPC call
        const rpc_start = std.time.milliTimestamp();
        const parsed = try self.makeRpcCallWithParams("eth_getLogs", .{ .array = params_array });
        defer parsed.deinit();
        const rpc_elapsed = std.time.milliTimestamp() - rpc_start;

        const result = parsed.value.object.get("result").?;
        const logs_array = result.array;

        // Allocate result logs
        var logs = try self.allocator.alloc(Log, logs_array.items.len);
        errdefer {
            for (logs) |*log| {
                log.deinit(self.allocator);
            }
            self.allocator.free(logs);
        }

        // Parse each log
        const parse_start = std.time.milliTimestamp();
        for (logs_array.items, 0..) |log_value, i| {
            const log_obj = log_value.object;

            // Parse topics
            const topics_json = log_obj.get("topics").?.array;
            var log_topics = try self.allocator.alloc(Hash, topics_json.items.len);
            for (topics_json.items, 0..) |topic_val, k| {
                log_topics[k] = try Hash.fromHex(topic_val.string);
            }

            // Parse data
            const data_hex = log_obj.get("data").?.string;
            const data_bytes = try self.hexToBytes(data_hex);

            logs[i] = Log{
                .address = try Address.fromHex(log_obj.get("address").?.string),
                .topics = log_topics,
                .data = data_bytes,
                .block_number = try std.fmt.parseInt(u64, log_obj.get("blockNumber").?.string[2..], 16),
                .transaction_hash = try Hash.fromHex(log_obj.get("transactionHash").?.string),
                .transaction_index = @intCast(try std.fmt.parseInt(u64, log_obj.get("transactionIndex").?.string[2..], 16)),
                .log_index = @intCast(try std.fmt.parseInt(u64, log_obj.get("logIndex").?.string[2..], 16)),
                .removed = if (log_obj.get("removed")) |r| r.bool else false,
                .block_timestamp = if (log_obj.get("blockTimestamp")) |ts| std.fmt.parseInt(u64, ts.string[2..], 16) catch null else null,
                .block_hash = if (log_obj.get("blockHash")) |bh| Hash.fromHex(bh.string) catch null else null,
            };
        }
        const parse_elapsed = std.time.milliTimestamp() - parse_start;

        if (logs.len > 1000) {
            std.log.debug("getLogsMultiAddress: {d} logs, rpc={d}ms, parse={d}ms", .{ logs.len, rpc_elapsed, parse_elapsed });
        }

        return logs;
    }

    /// Batch version of getLogsMultiAddress - fetches multiple block ranges in a single HTTP request
    /// Returns array of log arrays in the same order as requests
    /// Caller must free each log array and its contents
    pub fn getLogsMultiAddressBatch(self: *Client, requests: []const MultiAddressLogsRequest) ![][]Log {
        if (requests.len == 0) {
            return try self.allocator.alloc([]Log, 0);
        }

        // Use arena allocator for building batch request params
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        // Build batch requests
        var batch_requests = try arena_alloc.alloc(BatchRequest, requests.len);

        for (requests, 0..) |req, i| {
            // Build filter object
            const from_hex = try std.fmt.allocPrint(arena_alloc, "0x{x}", .{req.from_block});
            const to_hex = try std.fmt.allocPrint(arena_alloc, "0x{x}", .{req.to_block});

            var filter = std.json.ObjectMap.init(arena_alloc);
            try filter.put("fromBlock", .{ .string = from_hex });
            try filter.put("toBlock", .{ .string = to_hex });

            // Add addresses array
            if (req.addresses.len > 0) {
                var addr_array = std.json.Array.init(arena_alloc);
                for (req.addresses) |addr| {
                    const addr_hex = try addr.toHex(arena_alloc);
                    try addr_array.append(.{ .string = addr_hex });
                }
                try filter.put("address", .{ .array = addr_array });
            }

            // Add topics with OR support for topic[0]
            if (req.topic0_or.len > 0) {
                var topics_array = std.json.Array.init(arena_alloc);

                // topic[0] is an array for OR matching
                var topic0_array = std.json.Array.init(arena_alloc);
                for (req.topic0_or) |topic| {
                    const topic_hex = try topic.toHex(arena_alloc);
                    try topic0_array.append(.{ .string = topic_hex });
                }
                try topics_array.append(.{ .array = topic0_array });

                try filter.put("topics", .{ .array = topics_array });
            }

            // Create batch request with filter as param array
            var params_array = std.json.Array.init(arena_alloc);
            try params_array.append(.{ .object = filter });

            batch_requests[i] = .{
                .method = "eth_getLogs",
                .params = .{ .array = params_array },
            };
        }

        // Make batch RPC call with timing
        const rpc_start = std.time.milliTimestamp();
        const parsed = try self.makeBatchRpcCall(batch_requests);
        defer parsed.deinit();
        const rpc_elapsed = std.time.milliTimestamp() - rpc_start;

        const responses = parsed.value.array;

        // Allocate array for results
        var results = try self.allocator.alloc([]Log, requests.len);
        errdefer {
            for (results, 0..) |logs, i| {
                if (i > 0) {
                    for (logs) |*log| {
                        log.deinit(self.allocator);
                    }
                    self.allocator.free(logs);
                }
            }
            self.allocator.free(results);
        }

        // Parse each response
        const parse_start = std.time.milliTimestamp();
        var total_logs: usize = 0;
        for (responses.items, 0..) |response_value, i| {
            const response = response_value.object;
            const result = response.get("result").?;
            const logs_array = result.array;

            var logs = try self.allocator.alloc(Log, logs_array.items.len);
            errdefer {
                for (logs, 0..) |*log, j| {
                    if (j > 0) log.deinit(self.allocator);
                }
                self.allocator.free(logs);
            }

            for (logs_array.items, 0..) |log_value, j| {
                const log_obj = log_value.object;

                // Parse topics
                const topics_json = log_obj.get("topics").?.array;
                var log_topics = try self.allocator.alloc(Hash, topics_json.items.len);
                for (topics_json.items, 0..) |topic_val, k| {
                    log_topics[k] = try Hash.fromHex(topic_val.string);
                }

                // Parse data
                const data_hex = log_obj.get("data").?.string;
                const data_bytes = try self.hexToBytes(data_hex);

                logs[j] = Log{
                    .address = try Address.fromHex(log_obj.get("address").?.string),
                    .topics = log_topics,
                    .data = data_bytes,
                    .block_number = try std.fmt.parseInt(u64, log_obj.get("blockNumber").?.string[2..], 16),
                    .transaction_hash = try Hash.fromHex(log_obj.get("transactionHash").?.string),
                    .transaction_index = @intCast(try std.fmt.parseInt(u64, log_obj.get("transactionIndex").?.string[2..], 16)),
                    .log_index = @intCast(try std.fmt.parseInt(u64, log_obj.get("logIndex").?.string[2..], 16)),
                    .removed = if (log_obj.get("removed")) |r| r.bool else false,
                    .block_timestamp = if (log_obj.get("blockTimestamp")) |ts| std.fmt.parseInt(u64, ts.string[2..], 16) catch null else null,
                    .block_hash = if (log_obj.get("blockHash")) |bh| Hash.fromHex(bh.string) catch null else null,
                };
            }

            results[i] = logs;
            total_logs += logs.len;
        }
        const parse_elapsed = std.time.milliTimestamp() - parse_start;

        std.log.debug("getLogsMultiAddressBatch: {d} requests, {d} total logs, rpc={d}ms, parse={d}ms", .{
            requests.len,
            total_logs,
            rpc_elapsed,
            parse_elapsed,
        });

        return results;
    }

    /// Batch version of eth_getTransactionByHash - fetches multiple transactions in a single HTTP request
    /// Returns array of transactions in the same order as requested hashes
    /// Caller must free the returned array and each transaction's contents
    pub fn getTransactionsByHashBatch(self: *Client, tx_hashes: []const Hash) ![]Transaction {
        // Use arena allocator for building batch request params
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        // Build batch requests
        var batch_requests = try arena_allocator.alloc(BatchRequest, tx_hashes.len);

        for (tx_hashes, 0..) |tx_hash, i| {
            const tx_hash_hex = try tx_hash.toHex(arena_allocator);

            // Build params array as JSON value
            var params_array = std.json.Array.init(arena_allocator);
            try params_array.append(.{ .string = tx_hash_hex });

            batch_requests[i] = BatchRequest{
                .method = "eth_getTransactionByHash",
                .params = .{ .array = params_array },
            };
        }

        // Make batch call
        const parsed = try self.makeBatchRpcCall(batch_requests);
        defer parsed.deinit();

        const responses = parsed.value.array.items;

        // Allocate result array
        var transactions = try self.allocator.alloc(Transaction, tx_hashes.len);
        errdefer self.allocator.free(transactions);

        // Parse each response
        for (responses, 0..) |response_value, i| {
            const response = response_value.object;
            const result = response.get("result").?;

            if (result == .null) {
                // Transaction not found - clean up and return error
                for (transactions[0..i]) |*tx| {
                    tx.deinit(self.allocator);
                }
                self.allocator.free(transactions);
                return error.TransactionNotFound;
            }

            const tx_obj = result.object;

            // Parse input data
            const input_hex = tx_obj.get("input").?.string;
            const input_bytes = try self.hexToBytes(input_hex);

            transactions[i] = Transaction{
                .hash = try Hash.fromHex(tx_obj.get("hash").?.string),
                .block_number = try std.fmt.parseInt(u64, tx_obj.get("blockNumber").?.string[2..], 16),
                .from = try Address.fromHex(tx_obj.get("from").?.string),
                .to = if (tx_obj.get("to")) |to_val|
                    if (to_val == .null) null else try Address.fromHex(to_val.string)
                else
                    null,
                .input = input_bytes,
                .value = tx_obj.get("value").?.string,
                .gas = try std.fmt.parseInt(u64, tx_obj.get("gas").?.string[2..], 16),
                .gas_price = tx_obj.get("gasPrice").?.string,
            };
        }

        return transactions;
    }

    pub fn call(self: *Client, to: Address, data: []const u8, block_number: ?u64) ![]u8 {
        const to_hex = try to.toHex(self.allocator);
        defer self.allocator.free(to_hex);

        const data_hex = try self.bytesToHex(data);
        defer self.allocator.free(data_hex);

        const block_param = if (block_number) |bn|
            try std.fmt.allocPrint(self.allocator, "0x{x}", .{bn})
        else
            try self.allocator.dupe(u8, "latest");
        defer self.allocator.free(block_param);

        var call_obj = std.json.ObjectMap.init(self.allocator);
        defer call_obj.deinit();

        try call_obj.put("to", .{ .string = to_hex });
        try call_obj.put("data", .{ .string = data_hex });

        const parsed = try self.makeRpcCall("eth_call", .{ call_obj, block_param });
        defer parsed.deinit();

        const result = parsed.value.object.get("result").?;
        return try self.hexToBytes(result.string);
    }

    fn hexToBytes(self: *Client, hex: []const u8) ![]u8 {
        const hex_data = if (std.mem.startsWith(u8, hex, "0x")) hex[2..] else hex;

        if (hex_data.len % 2 != 0) {
            return error.InvalidHexLength;
        }

        // SECURITY: Use built-in std.fmt.hexToBytes (industry standard hex decoding)
        const bytes = try self.allocator.alloc(u8, hex_data.len / 2);
        _ = try std.fmt.hexToBytes(bytes, hex_data);

        return bytes;
    }

    fn bytesToHex(self: *Client, bytes: []const u8) ![]u8 {
        // SECURITY: Use built-in std.fmt.bytesToHex (industry standard hex encoding)
        var result = try self.allocator.alloc(u8, 2 + bytes.len * 2);
        result[0] = '0';
        result[1] = 'x';

        // bytesToHex returns a fixed-size array, we need to use allocPrint for dynamic sizes
        const hex_slice = result[2..];
        for (bytes, 0..) |byte, i| {
            const hex_byte = std.fmt.bytesToHex(&[_]u8{byte}, .lower);
            hex_slice[i * 2] = hex_byte[0];
            hex_slice[i * 2 + 1] = hex_byte[1];
        }

        return result;
    }
};
