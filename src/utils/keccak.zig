const std = @import("std");
const Keccak256 = std.crypto.hash.sha3.Keccak256;

/// Compute keccak256 hash at compile time
pub fn keccak256(comptime input: []const u8) [32]u8 {
    @setEvalBranchQuota(10000); // Keccak-256 needs more compile-time evaluation budget
    var hash: [32]u8 = undefined;
    Keccak256.hash(input, &hash, .{});
    return hash;
}

/// Compute event signature hash at compile time
/// Example: eventSignature("Transfer(address,address,uint256)")
pub fn eventSignature(comptime sig: []const u8) [32]u8 {
    return keccak256(sig);
}

test "keccak256 basic" {
    const result = keccak256("hello");
    // Known keccak256("hello") = 0x1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8
    const expected = [_]u8{
        0x1c, 0x8a, 0xff, 0x95, 0x06, 0x85, 0xc2, 0xed,
        0x4b, 0xc3, 0x17, 0x4f, 0x34, 0x72, 0x28, 0x7b,
        0x56, 0xd9, 0x51, 0x7b, 0x9c, 0x94, 0x81, 0x27,
        0x31, 0x9a, 0x09, 0xa7, 0xa3, 0x6d, 0xea, 0xc8,
    };
    try std.testing.expectEqualSlices(u8, &expected, &result);
}

test "event signature Transfer" {
    const sig = eventSignature("Transfer(address,address,uint256)");
    // Known keccak256 of Transfer event
    const expected = [_]u8{
        0xdd, 0xf2, 0x52, 0xad, 0x1b, 0xe2, 0xc8, 0x9b,
        0x69, 0xc2, 0xb0, 0x68, 0xfc, 0x37, 0x8d, 0xaa,
        0x95, 0x2b, 0xa7, 0xf1, 0x63, 0xc4, 0xa1, 0x16,
        0x28, 0xf5, 0x5a, 0x4d, 0xf5, 0x23, 0xb3, 0xef,
    };
    try std.testing.expectEqualSlices(u8, &expected, &sig);
}
