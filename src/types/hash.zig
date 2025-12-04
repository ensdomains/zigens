const std = @import("std");

/// Ethereum hash (32 bytes) - used for namehash, transaction hashes, etc.
pub const Hash = struct {
    bytes: [32]u8,

    pub const zero = Hash{ .bytes = [_]u8{0} ** 32 };

    pub fn fromHex(hex: []const u8) !Hash {
        var hash = Hash{ .bytes = undefined };

        // Remove 0x prefix if present
        const hex_data = if (std.mem.startsWith(u8, hex, "0x")) hex[2..] else hex;

        if (hex_data.len != 64) {
            return error.InvalidHashLength;
        }

        // SECURITY: Use built-in std.fmt.hexToBytes (industry standard hex decoding)
        _ = try std.fmt.hexToBytes(&hash.bytes, hex_data);

        return hash;
    }

    pub fn toHex(self: Hash, allocator: std.mem.Allocator) ![]u8 {
        // SECURITY: Use built-in std.fmt.bytesToHex (industry standard hex encoding)
        const hex_bytes = std.fmt.bytesToHex(self.bytes, .lower);

        var result = try allocator.alloc(u8, 66);
        result[0] = '0';
        result[1] = 'x';
        @memcpy(result[2..], &hex_bytes);

        return result;
    }

    pub fn eql(self: Hash, other: Hash) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    pub fn isZero(self: Hash) bool {
        return self.eql(zero);
    }
};

/// Compute keccak256 hash
pub fn keccak256(allocator: std.mem.Allocator, data: []const u8) !Hash {
    _ = allocator;
    var hash = Hash{ .bytes = undefined };
    std.crypto.hash.sha3.Keccak256.hash(data, &hash.bytes, .{});
    return hash;
}

/// Compute ENS namehash
pub fn namehash(allocator: std.mem.Allocator, name: []const u8) !Hash {
    if (name.len == 0) {
        return Hash.zero;
    }

    var hash = Hash.zero;

    // Split by '.' and process from right to left
    var it = std.mem.splitBackwardsScalar(u8, name, '.');
    while (it.next()) |label| {
        if (label.len == 0) continue;

        // Hash the label
        const label_hash = try keccak256(allocator, label);

        // Concatenate current hash with label hash and hash again
        var combined: [64]u8 = undefined;
        @memcpy(combined[0..32], &hash.bytes);
        @memcpy(combined[32..64], &label_hash.bytes);

        hash = try keccak256(allocator, &combined);
    }

    return hash;
}

test "Hash fromHex" {
    const hash = try Hash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000001");
    try std.testing.expect(hash.bytes[31] == 1);
}

test "keccak256" {
    const data = "hello";
    const hash = try keccak256(std.testing.allocator, data);
    try std.testing.expect(!hash.isZero());
}

test "namehash root" {
    const hash = try namehash(std.testing.allocator, "");
    try std.testing.expect(hash.isZero());
}

test "namehash eth" {
    const hash = try namehash(std.testing.allocator, "eth");
    try std.testing.expect(!hash.isZero());
}
