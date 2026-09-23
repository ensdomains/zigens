// ABI decode shim backed by StrobeLabs/eth.zig.
//
// Re-exports `EventSignatures` from `abi.zig` (event-signature strings + their
// comptime keccak hashes — project-specific knowledge eth.zig can't supply).
//
// Static decoders (uint256, address) and a single-tail string decoder remain
// here as primitive helpers used by topic decoding (where the input is a
// 32-byte word, not an ABI-head/tail layout) and a couple of legacy fallback
// paths. The schema-driven `decodeValues`/`freeValues` is the main entry point
// for log.data decoding — every event handler routes through it.

const std = @import("std");
const eth = @import("eth");
const Address = @import("../types/address.zig").Address;
const constants = @import("../constants.zig");
const abi_legacy = @import("abi.zig");

/// Re-export from the legacy module so callers only need to import abi_eth.
/// EventSignatures is project-specific (signatures + comptime keccak hashes)
/// and not something eth.zig provides.
pub const EventSignatures = abi_legacy.EventSignatures;

/// Primitive decode helpers. The remaining surface is what's reachable from
/// callers — the schema-driven path (`decodeValues` below) handles everything
/// else.
pub const ABI = struct {
    pub const MAX_STRING_LENGTH: usize = 1024 * 1024;
    pub const MAX_ARRAY_LENGTH: usize = constants.Validation.max_abi_array_length;

    /// Decode uint256 from a 32-byte big-endian word at `data[offset..offset+32]`.
    pub fn decodeUint256(data: []const u8, offset: usize) !u256 {
        if (offset + 32 > data.len) return error.DataTooShort;
        const word: [32]u8 = data[offset..][0..32].*;
        return eth.uint256.fromBigEndianBytes(word);
    }

    /// Decode an address from a 32-byte slot (low 20 bytes).
    pub fn decodeAddress(data: []const u8, offset: usize) !Address {
        if (offset + 32 > data.len) return error.DataTooShort;
        var addr = Address{ .bytes = undefined };
        @memcpy(&addr.bytes, data[offset + 12 .. offset + 32]);
        return addr;
    }

    /// Decode a dynamic string. The 32-byte word at `data[offset..]` holds the
    /// absolute byte offset (within `data`) of the string's length+payload.
    /// Main decode paths go through `decodeValues`; this helper is kept for
    /// any future ad-hoc trailing-string decoding.
    pub fn decodeString(allocator: std.mem.Allocator, data: []const u8, offset: usize) ![]u8 {
        if (offset + 32 > data.len) return error.DataTooShort;
        const head_word: [32]u8 = data[offset..][0..32].*;
        const head_value = eth.uint256.fromBigEndianBytes(head_word);
        const tail_off: usize = std.math.cast(usize, head_value) orelse return error.InvalidStringOffset;
        if (tail_off + 32 > data.len) return error.InvalidStringOffset;

        const len_word: [32]u8 = data[tail_off..][0..32].*;
        const len_value = eth.uint256.fromBigEndianBytes(len_word);
        const length: usize = std.math.cast(usize, len_value) orelse return error.StringTooLong;
        if (length > ABI.MAX_STRING_LENGTH) return error.StringTooLong;
        const payload_end = tail_off + 32 + length;
        if (payload_end > data.len) return error.InvalidStringLength;

        return allocator.dupe(u8, data[tail_off + 32 .. payload_end]);
    }

    /// Returns array length and the absolute offset (in `data`) of the first
    /// element. Used internally by `decodeUint256Array`.
    fn decodeUint256ArrayInfo(data: []const u8, offset: usize) !struct { length: usize, data_offset: usize } {
        if (offset + 32 > data.len) return error.InsufficientData;
        const head_word: [32]u8 = data[offset..][0..32].*;
        const head_value = eth.uint256.fromBigEndianBytes(head_word);
        const array_offset: usize = std.math.cast(usize, head_value) orelse return error.InvalidArrayOffset;
        if (array_offset + 32 > data.len) return error.InvalidArrayOffset;

        const len_word: [32]u8 = data[array_offset..][0..32].*;
        const len_value = eth.uint256.fromBigEndianBytes(len_word);
        const length: usize = std.math.cast(usize, len_value) orelse return error.ArrayTooLong;
        if (length > ABI.MAX_ARRAY_LENGTH) return error.ArrayTooLong;

        return .{ .length = length, .data_offset = array_offset + 32 };
    }

    /// Decode a uint256[] dynamic array.
    pub fn decodeUint256Array(allocator: std.mem.Allocator, data: []const u8, offset: usize) ![]u256 {
        const info = try decodeUint256ArrayInfo(data, offset);
        const end = info.data_offset + info.length * 32;
        if (end > data.len) return error.ArrayDataTooShort;

        var out = try allocator.alloc(u256, info.length);
        errdefer allocator.free(out);

        var i: usize = 0;
        while (i < info.length) : (i += 1) {
            const word: [32]u8 = data[info.data_offset + i * 32 ..][0..32].*;
            out[i] = eth.uint256.fromBigEndianBytes(word);
        }
        return out;
    }
};

// ----------------------------------------------------------------------------
// Schema-driven decode (the main entry point). Pass an event's non-indexed
// param schema as a slice literal of eth.zig's AbiType tags and get back typed
// AbiValues in one call.
// ----------------------------------------------------------------------------

/// Decode the entire `data` against a list of types using eth.zig's tested
/// codec. Caller owns the returned slice and must call `freeValues`.
pub fn decodeValues(data: []const u8, types: []const eth.abi_types.AbiType, allocator: std.mem.Allocator) ![]eth.abi_encode.AbiValue {
    return eth.abi_decode.decodeValues(data, types, allocator);
}

/// Free a slice returned by `decodeValues`.
pub fn freeValues(values: []eth.abi_encode.AbiValue, allocator: std.mem.Allocator) void {
    eth.abi_decode.freeValues(values, allocator);
}

// ----------------------------------------------------------------------------
// Tests — mirror abi.zig's tests so we know we match bit-for-bit.
// ----------------------------------------------------------------------------

test "decodeUint256 matches abi.zig" {
    const data = [_]u8{0} ** 31 ++ [_]u8{42};
    const value = try ABI.decodeUint256(&data, 0);
    try std.testing.expectEqual(@as(u256, 42), value);
}

test "decodeAddress matches abi.zig" {
    var data = [_]u8{0} ** 32;
    data[31] = 1;
    const addr = try ABI.decodeAddress(&data, 0);
    try std.testing.expectEqual(@as(u8, 1), addr.bytes[19]);
}

test "decodeString roundtrip" {
    // Layout: [head=0x20][len=5]["hello"+padding]
    var data: [96]u8 = [_]u8{0} ** 96;
    data[31] = 0x20; // head: tail at offset 32
    data[63] = 5; // length
    @memcpy(data[64..69], "hello");

    const allocator = std.testing.allocator;
    const result = try ABI.decodeString(allocator, &data, 0);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "schema-driven decode matches primitive decode for LabelRegistered payload" {
    // Realistic LabelRegistered non-indexed payload: (string label, address owner, uint64 expiry)
    //   label  = "alice"
    //   owner  = 0x1111...1111
    //   expiry = 1700000000

    // Head: 3 × 32 bytes = 96 bytes; string tail starts at offset 0x60.
    var data: [160]u8 = [_]u8{0} ** 160;

    // Slot 0: string offset = 0x60
    data[31] = 0x60;

    // Slot 1: address (20 bytes right-aligned in 32-byte slot)
    var i: usize = 12;
    while (i < 32) : (i += 1) data[32 + i] = 0x11;

    // Slot 2: uint64 1700000000 = 0x6553F100 — big-endian, right-aligned in
    // the 32-byte slot (low 8 bytes hold the value; for this u32-sized number
    // the lower 4 bytes carry the actual digits).
    data[64 + 28] = 0x65;
    data[64 + 29] = 0x53;
    data[64 + 30] = 0xF1;
    data[64 + 31] = 0x00;

    // Tail @ 96: length=5
    data[96 + 31] = 5;
    @memcpy(data[128..133], "alice");

    const allocator = std.testing.allocator;

    // Primitive path (the shim's hand-rolled decoders).
    const label_a = try ABI.decodeString(allocator, &data, 0);
    defer allocator.free(label_a);
    const owner_a = try ABI.decodeAddress(&data, 32);
    const expiry_a: u64 = @truncate(try ABI.decodeUint256(&data, 64));

    // Schema-driven path (eth.zig's typed codec).
    const values = try decodeValues(&data, &.{ .string, .address, .uint64 }, allocator);
    defer freeValues(values, allocator);

    try std.testing.expectEqualStrings(label_a, values[0].string);
    try std.testing.expectEqualSlices(u8, &owner_a.bytes, &values[1].address);
    try std.testing.expectEqual(@as(u256, expiry_a), values[2].uint256);

    // And both must report the expected concrete values.
    try std.testing.expectEqualStrings("alice", label_a);
    try std.testing.expectEqual(@as(u8, 0x11), owner_a.bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x11), owner_a.bytes[19]);
    try std.testing.expectEqual(@as(u64, 1700000000), expiry_a);
}

test "decodeString rejects overlong" {
    var data: [64]u8 = [_]u8{0} ** 64;
    data[31] = 0x20;
    // length = MAX+1 (won't fit in u64, but the cap check fires first via cast)
    data[56] = 0x80;

    const result = ABI.decodeString(std.testing.allocator, &data, 0);
    try std.testing.expectError(error.StringTooLong, result);
}

test "decodeUint256Array handles two-array TransferBatch payload" {
    // ERC-1155 TransferBatch non-indexed payload: (uint256[] ids, uint256[] values).
    // The tuple head occupies the first 2 words (bytes 0..64) and stores offsets
    // (relative to the start of the payload) to each dynamic array's tail.
    //
    // Layout used here (packed):
    //   bytes   0..32  head[0] = 0x40   → ids tail starts at byte 64
    //   bytes  32..64  head[1] = 0xA0   → values tail starts at byte 160
    //   bytes  64..96  ids.length = 2
    //   bytes  96..128 ids[0] = 0xAA…AA
    //   bytes 128..160 ids[1] = 0xBB…BB
    //   bytes 160..192 values.length = 2
    //   bytes 192..224 values[0] = 1
    //   bytes 224..256 values[1] = 2
    //
    // Both `(data, 0)` and `(data, 32)` are head-slot offsets — decodeUint256Array
    // dereferences each through the head pointer to reach the correct tail. If it
    // were instead a raw byte offset, the second call would read garbage.

    var data: [256]u8 = [_]u8{0} ** 256;
    // Head[0] = 0x40 (ids tail at byte 64)
    data[31] = 0x40;
    // Head[1] = 0xA0 (values tail at byte 160; packed right after ids tail end)
    data[63] = 0xA0;
    // ids tail: length = 2
    data[64 + 31] = 0x02;
    // ids[0] = 0xAA…AA (byte 0xAA repeated for clarity)
    for (data[96..128]) |*b| b.* = 0xAA;
    // ids[1] = 0xBB…BB
    for (data[128..160]) |*b| b.* = 0xBB;
    // values tail: length = 2
    data[160 + 31] = 0x02;
    // values[0] = 1
    data[192 + 31] = 0x01;
    // values[1] = 2
    data[224 + 31] = 0x02;

    const ids = try ABI.decodeUint256Array(std.testing.allocator, &data, 0);
    defer std.testing.allocator.free(ids);
    const values = try ABI.decodeUint256Array(std.testing.allocator, &data, 32);
    defer std.testing.allocator.free(values);

    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expectEqual(@as(u256, 0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA), ids[0]);
    try std.testing.expectEqual(@as(u256, 0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB), ids[1]);
    try std.testing.expectEqual(@as(usize, 2), values.len);
    try std.testing.expectEqual(@as(u256, 1), values[0]);
    try std.testing.expectEqual(@as(u256, 2), values[1]);
}

test "decodeValues keeps the raw bytes of a non-UTF-8 string: the contracts hash labels as bytes" {
    const allocator = std.testing.allocator;
    var data: [96]u8 = [_]u8{0} ** 96;
    data[31] = 0x20;
    data[63] = 4;
    @memcpy(data[64..68], "k\xEF\x58\x17");
    const values = try decodeValues(&data, &.{.string}, allocator);
    defer freeValues(values, allocator);
    try std.testing.expectEqualSlices(u8, "k\xEF\x58\x17", values[0].string);
    const hash_mod = @import("../types/hash.zig");
    const from_decoded = try hash_mod.keccak256(allocator, values[0].string);
    const from_chain_bytes = try hash_mod.keccak256(allocator, "k\xEF\x58\x17");
    try std.testing.expect(from_decoded.eql(from_chain_bytes));
}
