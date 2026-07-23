//! Fuzz lane: every parser/decoder that consumes UNTRUSTED bytes must
//! parse-or-reject — never panic, never overflow, never leak. These targets are
//! the surfaces hostile input reaches: GraphQL queries (public API), ABI log
//! data (chain), CCIP revert payloads (name-controlled resolvers), DNS wire
//! names (chain), event-data JSON (chain), and HTTP/ISO timestamps (providers).
//!
//! Under a plain `zig build test-fuzz` each target runs once (smoke). Real
//! fuzzing: `zig build test-fuzz --fuzz` explores continuously — any crash is a
//! real bug by definition. KNOWN LIMITATION: Zig 0.16.0's fuzz instrumentation
//! (-ffuzz) currently fails to compile std itself on this platform (StackTrace
//! type conflict in std.debug); the harness is ready and lights up on a fixed
//! toolchain with no further work here.

const std = @import("std");
const Smith = std.testing.Smith;

const parser = @import("lib/graphql/parser.zig");
const abi = @import("indexer/abi_eth.zig");
const ccip = @import("resolve/ccip.zig");
const dns = @import("utils/dns.zig");
const at_block = @import("storage/at_block.zig");
const cdp = @import("indexer/cdp_intake.zig");

fn fill(smith: *Smith, buf: []u8, comptime site: u32) []u8 {
    return buf[0..smith.sliceWithHash(buf, site)];
}

test "fuzz: GraphQL parseQuery never panics" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *Smith) !void {
            var buf: [4096]u8 = undefined;
            const input = fill(smith, &buf, 0x6710_0001);
            var doc = parser.parseQuery(std.testing.allocator, input) catch return;
            doc.deinit(std.testing.allocator);
        }
    }.one, .{});
}

test "fuzz: ABI decodeValues never panics across schemas" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *Smith) !void {
            var buf: [1024]u8 = undefined;
            const input = fill(smith, &buf, 0x6710_0002);
            const AbiType = @import("eth").abi_types.AbiType;
            const schemas = [_][]const AbiType{
                &.{ .string, .uint256, .uint256 },
                &.{ .string, .address, .uint64 },
                &.{ .uint256, .bytes },
                &.{ .bytes, .uint16, .bytes },
                &.{.bool},
            };
            for (schemas) |schema| {
                const vals = abi.decodeValues(input, schema, std.testing.allocator) catch continue;
                abi.freeValues(vals, std.testing.allocator);
            }
        }
    }.one, .{});
}

test "fuzz: CCIP OffchainLookup decode never panics" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *Smith) !void {
            var buf: [2048]u8 = undefined;
            const input = fill(smith, &buf, 0x6710_0003);
            const ol = ccip.decode(std.testing.allocator, input) catch return;
            ol.deinit(std.testing.allocator);
        }
    }.one, .{});
}

test "fuzz: DNS wire-name decode never panics" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *Smith) !void {
            var buf: [512]u8 = undefined;
            const input = fill(smith, &buf, 0x6710_0004);
            const out = (dns.decodeDNSNameToString(std.testing.allocator, input) catch return) orelse return;
            std.testing.allocator.free(out);
        }
    }.one, .{});
}

test "fuzz: event-data JSON scanners never panic" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *Smith) !void {
            var buf: [512]u8 = undefined;
            const input = fill(smith, &buf, 0x6710_0005);
            _ = at_block.jsonRawValue(input, "owner");
            _ = at_block.jsonString(input, "to");
            _ = at_block.jsonU256(input, "tokenId");
            _ = at_block.jsonU64(input, "expiry");
        }
    }.one, .{});
}

test "fuzz: timestamp parsers never panic" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *Smith) !void {
            var buf: [64]u8 = undefined;
            const input = fill(smith, &buf, 0x6710_0006);
            _ = cdp.parseIsoTimestamp(input);
            _ = cdp.parseHttpDate(input);
        }
    }.one, .{});
}
