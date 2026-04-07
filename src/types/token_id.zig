const std = @import("std");

/// ENS V2 Token ID Utilities
///
/// In ENS V2 (namechain), token IDs have a special structure:
/// - Token ID = Canonical ID | Token Version ID
/// - Canonical ID = keccak256(label) XOR uint32(keccak256(label))
/// - Token Version ID = 32-bit version number (0, 1, 2, ...)
///
/// This design allows:
/// 1. Token regeneration with version tracking
/// 2. Efficient storage lookups using canonical ID
/// 3. Multiple versions of the same name to coexist
/// Extract the canonical ID from a token ID
/// Canonical ID is the token ID with the lower 32 bits cleared
pub fn getCanonicalId(token_id: u256) u256 {
    // Clear lower 32 bits by ANDing with mask
    const mask: u256 = ~@as(u256, 0xFFFFFFFF);
    return token_id & mask;
}

/// Extract the token version from a token ID
/// Version is stored in the lower 32 bits
pub fn getTokenVersion(token_id: u256) u32 {
    return @truncate(token_id & 0xFFFFFFFF);
}

/// Construct a token ID from canonical ID and version
pub fn constructTokenId(canonical_id: u256, version: u32) u256 {
    return canonical_id | @as(u256, version);
}

/// Convert a label hash to canonical ID
/// This matches LibLabel.labelToCanonicalId() from the contracts:
/// return id ^ uint32(id);
pub fn labelHashToCanonicalId(label_hash: u256) u256 {
    const lower_32: u32 = @truncate(label_hash & 0xFFFFFFFF);
    return label_hash ^ @as(u256, lower_32);
}

/// Check if a token ID is a canonical ID (version 0)
pub fn isCanonicalId(token_id: u256) bool {
    return getTokenVersion(token_id) == 0;
}

test "getCanonicalId" {
    // Test with a token ID ending in 00000000 (version 0)
    const token_id_v0: u256 = 0x53f632a801578489983227b234817273b09ffad9c79c50366f6ff4d600000000;
    const canonical = getCanonicalId(token_id_v0);
    try std.testing.expectEqual(token_id_v0, canonical);

    // Test with a token ID with version 1
    const token_id_v1: u256 = 0x53f632a801578489983227b234817273b09ffad9c79c50366f6ff4d600000001;
    const canonical_v1 = getCanonicalId(token_id_v1);
    try std.testing.expectEqual(token_id_v0, canonical_v1); // Should strip version
}

test "getTokenVersion" {
    const token_id_v0: u256 = 0x53f632a801578489983227b234817273b09ffad9c79c50366f6ff4d600000000;
    try std.testing.expectEqual(@as(u32, 0), getTokenVersion(token_id_v0));

    const token_id_v1: u256 = 0x53f632a801578489983227b234817273b09ffad9c79c50366f6ff4d600000001;
    try std.testing.expectEqual(@as(u32, 1), getTokenVersion(token_id_v1));

    const token_id_v42: u256 = 0x53f632a801578489983227b234817273b09ffad9c79c50366f6ff4d60000002a;
    try std.testing.expectEqual(@as(u32, 42), getTokenVersion(token_id_v42));
}

test "constructTokenId" {
    const canonical: u256 = 0x53f632a801578489983227b234817273b09ffad9c79c50366f6ff4d600000000;
    const version: u32 = 1;

    const token_id = constructTokenId(canonical, version);
    try std.testing.expectEqual(@as(u256, 0x53f632a801578489983227b234817273b09ffad9c79c50366f6ff4d600000001), token_id);
}

test "labelHashToCanonicalId" {
    // Test with the real keccak256("first-test")
    const first_test_hash: u256 = 0x53f632a801578489983227b234817273b09ffad9c79c50366f6ff4d6cc6561b0;
    const canonical = labelHashToCanonicalId(first_test_hash);

    // Expected: hash XOR lower 32 bits
    // lower_32 = 0xcc6561b0
    // canonical = 0x53f632a8...cc6561b0 XOR 0xcc6561b0 = 0x53f632a8...00000000
    const expected: u256 = 0x53f632a801578489983227b234817273b09ffad9c79c50366f6ff4d600000000;
    try std.testing.expectEqual(expected, canonical);
}

test "isCanonicalId" {
    const token_id_v0: u256 = 0x53f632a801578489983227b234817273b09ffad9c79c50366f6ff4d600000000;
    try std.testing.expect(isCanonicalId(token_id_v0));

    const token_id_v1: u256 = 0x53f632a801578489983227b234817273b09ffad9c79c50366f6ff4d600000001;
    try std.testing.expect(!isCanonicalId(token_id_v1));
}
