const std = @import("std");

// The indexer's inline tests (abi_eth) and the pure helpers it relies on (DNS wire
// decode, token-id/canonical-id math, calldata decoding, V1 name helpers) are NOT
// reached by the lib.zig-rooted `test` step — so they never ran in CI. Pull them in
// here so `zig build test-indexer` executes them, plus the new coverage below.
// Rooted under src/ so the relative imports stay inside the module path (Zig 0.15
// forbids @import escaping the module root, which a tests/ location would do).
comptime {
    _ = @import("indexer/abi_eth.zig");
    _ = @import("utils/dns.zig");
    _ = @import("utils/calldata_decoder.zig");
    _ = @import("utils/v1_names.zig");
    _ = @import("types/token_id.zig");
}

const handlers_resolver = @import("indexer/v2/handlers_resolver.zig");
const token_id = @import("types/token_id.zig");

fn expectDns(a: std.mem.Allocator, wire: []const u8, want: []const u8) !void {
    const got = try handlers_resolver.decodeDnsWireFormat(a, wire);
    defer a.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "decodeDnsWireFormat: DNS wire-format → dotted name" {
    const a = std.testing.allocator;
    try expectDns(a, "\x03eth\x00", "eth");
    try expectDns(a, "\x05alice\x03eth\x00", "alice.eth");
    try expectDns(a, "\x03sub\x05alice\x03eth\x00", "sub.alice.eth");
    // A missing root terminator still decodes (the loop ends at data.len).
    try expectDns(a, "\x03eth", "eth");
    // Empty input and a label length running past the buffer are rejected.
    try std.testing.expectError(error.EmptyDnsData, handlers_resolver.decodeDnsWireFormat(a, ""));
    try std.testing.expectError(error.InvalidDnsWireFormat, handlers_resolver.decodeDnsWireFormat(a, "\x05ab"));
}

test "getCanonicalId: clears the low 32 version bits (EAC/token-id stability)" {
    // A versioned token id and its canonical id differ only in the low 32 bits.
    const high: u256 = 0xABCDEF; // the canonical (high) bits
    const versioned = (high << 32) | 0x12345678; // a version in the low 32 bits
    try std.testing.expectEqual(high << 32, token_id.getCanonicalId(versioned));
    // Already-canonical (low 32 bits zero) is unchanged; zero stays zero (resolver EAC).
    try std.testing.expectEqual(high << 32, token_id.getCanonicalId(high << 32));
    try std.testing.expectEqual(@as(u256, 0), token_id.getCanonicalId(0));
}
