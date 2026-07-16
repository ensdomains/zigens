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
    _ = @import("indexer/replay.zig");
}

const dns = @import("utils/dns.zig");
const token_id = @import("types/token_id.zig");

fn expectDns(a: std.mem.Allocator, wire: []const u8, want: []const u8) !void {
    const got = (try dns.decodeDNSNameToString(a, wire)) orelse return error.TestUnexpectedResult;
    defer a.free(got);
    try std.testing.expectEqualStrings(want, got);
}

// Pins the semantics the V2 resolver handlers rely on after the duplicate
// decoder was folded into utils/dns.zig: identical dotted-name output on valid
// (and tolerated-malformed) input, and null — never a decode error — on
// rejected input, which the call sites turn into warn/skip via `orelse`.
test "decodeDNSNameToString: DNS wire-format → dotted name; failures fold to null" {
    const a = std.testing.allocator;
    try expectDns(a, "\x03eth\x00", "eth");
    try expectDns(a, "\x05alice\x03eth\x00", "alice.eth");
    try expectDns(a, "\x03sub\x05alice\x03eth\x00", "sub.alice.eth");
    // A missing root terminator still decodes (the loop ends at data.len).
    try expectDns(a, "\x03eth", "eth");
    // Bytes after the root terminator are ignored, not an error.
    try expectDns(a, "\x03eth\x00junk", "eth");
    // Rejected inputs fold to null: empty, label running past the buffer,
    // and a bare root terminator (no labels).
    try std.testing.expectEqual(@as(?[]const u8, null), try dns.decodeDNSNameToString(a, ""));
    try std.testing.expectEqual(@as(?[]const u8, null), try dns.decodeDNSNameToString(a, "\x05ab"));
    try std.testing.expectEqual(@as(?[]const u8, null), try dns.decodeDNSNameToString(a, "\x00"));
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

test "Approved event signature matches the deployed PublicResolver topic" {
    // Externally verified topic0 (keccak of the canonical signature); guards
    // the signature string in abi.zig against drift.
    const abi = @import("indexer/abi.zig");
    var expect_bytes: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expect_bytes, "f0ddb3b04746704017f9aa8bd728fcc2c1d11675041205350018915f5e4750a0");
    try std.testing.expectEqualSlices(u8, &expect_bytes, &abi.EventSignatures.approved_hash.bytes);
}

test "Named*Resource signatures match the contracts-v2 PermissionedResolver topics" {
    const abi = @import("indexer/abi.zig");
    const cases = .{
        .{ abi.EventSignatures.named_resource_hash, "737038e72be1d204e2c7336c20bff2169d9dffe11face28c5969af4ecce04f67" },
        .{ abi.EventSignatures.named_text_resource_hash, "ab228e072dd20e63d6891264ea8f6a2459e6852ab494b707970f978ba630859c" },
        .{ abi.EventSignatures.named_data_resource_hash, "db7aa4f21d01358b79d5574f3f3f6805f4f97606c53cb70598063387352206ac" },
        .{ abi.EventSignatures.named_addr_resource_hash, "2fe6caf984256b1a1844b92f52cf88703e829b07ce397a6c7fcf1f779db7a185" },
    };
    inline for (cases) |case| {
        var expect_bytes: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&expect_bytes, case[1]);
        const got: [32]u8 = case[0].bytes;
        try std.testing.expectEqualSlices(u8, &expect_bytes, &got);
    }
}
