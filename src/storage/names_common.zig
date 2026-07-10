//! Shared pure helpers for the names storage cluster (hex / int conversions).
//!
//! Split out so sibling name modules reuse one copy; names.zig aliases them back
//! (`const parseU256Hex = names_common.parseU256Hex;`) so its call sites are unchanged.

const std = @import("std");

/// Safely convert u64 expiry to i64 for SQLite storage.
/// Values exceeding i64::max are mapped to 0 (never expires).
pub fn safeU64ToI64(val: u64) i64 {
    if (val > @as(u64, @intCast(std.math.maxInt(i64)))) return 0;
    return @intCast(val);
}

/// Parse a u256 from hex string (handles 0x prefix).
pub fn parseU256Hex(hex_str: []const u8) !u256 {
    const clean = if (std.mem.startsWith(u8, hex_str, "0x")) hex_str[2..] else hex_str;
    return try std.fmt.parseInt(u256, clean, 16);
}

/// Stack-buffer u256->hex: writes "0x" + 64 hex chars (66 bytes) into a caller buffer.
pub fn formatU256HexBuf(buf: *[66]u8, value: u256) []const u8 {
    return std.fmt.bufPrint(buf, "0x{x:0>64}", .{value}) catch unreachable;
}
