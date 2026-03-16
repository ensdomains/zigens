const std = @import("std");

/// Ethereum address (20 bytes)
pub const Address = struct {
    bytes: [20]u8,

    pub const zero = Address{ .bytes = [_]u8{0} ** 20 };

    pub fn fromHex(hex: []const u8) !Address {
        var addr = Address{ .bytes = undefined };

        // Remove 0x prefix if present
        const hex_data = if (std.mem.startsWith(u8, hex, "0x")) hex[2..] else hex;

        if (hex_data.len != 40) {
            return error.InvalidAddressLength;
        }

        // SECURITY: Use built-in std.fmt.hexToBytes (industry standard hex decoding)
        _ = try std.fmt.hexToBytes(&addr.bytes, hex_data);

        return addr;
    }

    pub fn toHex(self: Address, allocator: std.mem.Allocator) ![]u8 {
        // SECURITY: Use built-in std.fmt.bytesToHex (industry standard hex encoding)
        const hex_bytes = std.fmt.bytesToHex(self.bytes, .lower);

        var result = try allocator.alloc(u8, 42);
        result[0] = '0';
        result[1] = 'x';
        @memcpy(result[2..], &hex_bytes);

        return result;
    }

    /// Convert to hex string using a caller-provided stack buffer (no allocation)
    pub fn toHexBuf(self: Address, buf: *[42]u8) []const u8 {
        buf[0] = '0';
        buf[1] = 'x';
        const hex_bytes = std.fmt.bytesToHex(self.bytes, .lower);
        @memcpy(buf[2..], &hex_bytes);
        return buf[0..42];
    }

    pub fn eql(self: Address, other: Address) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    pub fn isZero(self: Address) bool {
        return self.eql(zero);
    }
};

test "Address fromHex" {
    const addr = try Address.fromHex("0x0000000000000000000000000000000000000001");
    try std.testing.expect(addr.bytes[19] == 1);
}

test "Address toHex" {
    var addr = Address{ .bytes = [_]u8{0} ** 20 };
    addr.bytes[19] = 1;

    const hex = try addr.toHex(std.testing.allocator);
    defer std.testing.allocator.free(hex);

    try std.testing.expectEqualStrings("0x0000000000000000000000000000000000000001", hex);
}
