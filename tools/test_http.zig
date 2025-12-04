const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const rpc_url = "https://eth-sepolia.g.alchemy.com/v2/YOUR_ALCHEMY_API_KEY";
    const payload = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\",\"params\":[]}";

    std.log.info("Testing HTTP client with URL: [CONFIGURED]", .{});
    std.log.info("Payload: {s}", .{payload});

    const uri = try std.Uri.parse(rpc_url);
    std.log.info("Parsed URI successfully", .{});

    var http_client = std.http.Client{ .allocator = allocator };
    defer http_client.deinit();

    std.log.info("HTTP client created, making request...", .{});

    var response_buf: std.ArrayList(u8) = .{};
    var response_writer = response_buf.writer(allocator);

    const result = http_client.fetch(.{
        .location = .{ .uri = uri },
        .method = .POST,
        .payload = payload,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
        .response_writer = @ptrCast(&response_writer),
    }) catch |err| {
        std.log.err("Fetch failed: {}", .{err});
        return err;
    };

    std.log.info("Response status: {}", .{result.status});
    std.log.info("Response body: {s}", .{response_buf.items});
    allocator.free(response_buf.items);
}
