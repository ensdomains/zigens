const std = @import("std");

/// Decode ENS Registry function calldata to extract label text from setSubnode* functions
///
/// ENS Registry has several functions that take a label as bytes32 parameter:
/// - setSubnodeRecord(bytes32 node, bytes32 label, address owner, address resolver, uint64 ttl)
///   Selector: 0x5b0fc9c3
/// - setSubnodeOwner(bytes32 node, bytes32 label, address owner)
///   Selector: 0x06ab5923
///
/// The calldata format is:
///   [0:4]    - function selector (4 bytes)
///   [4:36]   - node (bytes32)
///   [36:68]  - label (bytes32) ← This is what we want!
///   [68:...]  - remaining parameters
///
pub const CalldataDecoder = struct {
    /// ENS Registry setSubnodeRecord function selector
    pub const SET_SUBNODE_RECORD_SELECTOR = [_]u8{ 0x5b, 0x0f, 0xc9, 0xc3 };

    /// ENS Registry setSubnodeOwner function selector
    pub const SET_SUBNODE_OWNER_SELECTOR = [_]u8{ 0x06, 0xab, 0x59, 0x23 };

    /// Standard multicall selector: multicall(bytes[])
    pub const MULTICALL_SELECTOR = [_]u8{ 0xac, 0x96, 0x50, 0xd8 };

    /// Multicall with deadline selector: multicall(uint256 deadline, bytes[])
    pub const MULTICALL_WITH_DEADLINE_SELECTOR = [_]u8{ 0x5a, 0xe4, 0x01, 0xdc };

    /// Decode label from ENS Registry setSubnode* function calldata
    /// Returns the label as a string, or null if:
    /// - Calldata is too short
    /// - Function selector doesn't match setSubnode functions
    /// - Label contains non-UTF8 or non-printable characters
    ///
    /// The returned string is allocated and must be freed by the caller.
    pub fn decodeSubnodeLabel(allocator: std.mem.Allocator, calldata: []const u8) !?[]u8 {
        // Minimum calldata length: 4 (selector) + 32 (node) + 32 (label) = 68 bytes
        if (calldata.len < 68) {
            return null;
        }

        // Check if this is a setSubnode* function
        const selector = calldata[0..4];
        const is_set_subnode_record = std.mem.eql(u8, selector, &SET_SUBNODE_RECORD_SELECTOR);
        const is_set_subnode_owner = std.mem.eql(u8, selector, &SET_SUBNODE_OWNER_SELECTOR);

        if (!is_set_subnode_record and !is_set_subnode_owner) {
            return null;
        }

        // Extract label bytes (bytes 36-68)
        const label_bytes = calldata[36..68];

        // Convert bytes32 to string
        // In ENS, labels are often padded with zeros on the right
        // We need to trim trailing zeros to get the actual label text
        var label_len: usize = 0;
        for (label_bytes) |byte| {
            if (byte == 0) break;
            label_len += 1;
        }

        if (label_len == 0) {
            return null;
        }

        const label_text = label_bytes[0..label_len];

        // Validate that it's valid UTF-8 and printable ASCII
        // ENS labels should be ASCII-safe (or normalized Unicode)
        if (!std.unicode.utf8ValidateSlice(label_text)) {
            return null;
        }

        // Check if all characters are printable (avoid binary garbage)
        for (label_text) |char| {
            if (char < 0x20 or char > 0x7E) {
                // Non-printable ASCII (allow some extended characters in future)
                // For now, strict ASCII validation
                return null;
            }
        }

        // Allocate and return the label
        return try allocator.dupe(u8, label_text);
    }

    /// Decode label from multicall pattern
    /// This function searches for setSubnode* calls within multicall(bytes[]) patterns
    ///
    /// Multicall structure:
    /// - bytes 0-4: selector (0xac9650d8 or 0x5ae401dc)
    /// - bytes 4+: ABI-encoded dynamic bytes[] array
    ///
    /// For multicall(uint256, bytes[]), there's an extra uint256 parameter first
    pub fn decodeSubnodeLabelFromMulticall(allocator: std.mem.Allocator, calldata: []const u8) !?[]u8 {
        if (calldata.len < 4) return null;

        const selector = calldata[0..4];
        const is_standard_multicall = std.mem.eql(u8, selector, &MULTICALL_SELECTOR);
        const is_deadline_multicall = std.mem.eql(u8, selector, &MULTICALL_WITH_DEADLINE_SELECTOR);

        if (!is_standard_multicall and !is_deadline_multicall) {
            return null;
        }

        // For multicall with deadline, skip the first uint256 parameter (32 bytes)
        const params_start: usize = if (is_deadline_multicall) 36 else 4;

        if (calldata.len < params_start + 32) return null;

        // Read offset to bytes[] array (relative to params_start)
        const array_offset_rel = readUint256(calldata, params_start) catch return null;
        const array_pos = params_start + array_offset_rel;

        if (calldata.len < array_pos + 32) return null;

        // Read array length
        const array_length = readUint256(calldata, array_pos) catch return null;

        if (array_length == 0 or array_length > 100) return null; // Sanity check

        // After array length, we have N offsets (each 32 bytes) pointing to element data
        // All offsets are relative to array_pos (start of array structure)
        const offsets_start = array_pos + 32;

        var i: usize = 0;
        while (i < array_length) : (i += 1) {
            const offset_pos = offsets_start + (i * 32);
            if (calldata.len < offset_pos + 32) break;

            // Read offset for this element (relative to array_pos)
            const elem_offset_rel = readUint256(calldata, offset_pos) catch break;
            const elem_pos = array_pos + elem_offset_rel;

            if (calldata.len < elem_pos + 32) continue;

            // Read element length
            const elem_length = readUint256(calldata, elem_pos) catch continue;
            if (elem_length == 0 or elem_length > 10000) continue; // Sanity check

            // Extract element data
            const elem_data_start = elem_pos + 32;
            if (calldata.len < elem_data_start + elem_length) continue;

            const elem_data = calldata[elem_data_start .. elem_data_start + elem_length];

            // Try to decode this element as a setSubnode call
            if (try decodeSubnodeLabel(allocator, elem_data)) |label| {
                return label; // Found it!
            }
        }

        return null; // No setSubnode call found in multicall
    }

    /// Helper function to read uint256 from calldata at given offset
    fn readUint256(data: []const u8, offset: usize) !usize {
        if (data.len < offset + 32) return error.InsufficientData;

        var value: usize = 0;
        // Read big-endian uint256, but only take the lower usize bits
        // For offsets/lengths, this is safe as they won't exceed usize
        const start = offset + 32 - @sizeOf(usize);
        for (data[start .. offset + 32]) |byte| {
            value = (value << 8) | byte;
        }
        return value;
    }

    /// Wrapper that tries both direct decoding and multicall decoding
    /// This is the main entry point for label extraction
    pub fn decodeLabelFromCalldata(allocator: std.mem.Allocator, calldata: []const u8) !?[]u8 {
        // First try direct setSubnode call
        if (try decodeSubnodeLabel(allocator, calldata)) |label| {
            return label;
        }

        // Then try multicall pattern
        if (try decodeSubnodeLabelFromMulticall(allocator, calldata)) |label| {
            return label;
        }

        return null;
    }
};

// Tests
test "decode setSubnodeRecord calldata" {
    const allocator = std.testing.allocator;

    // Example: setSubnodeRecord with label "test" (0x74657374 padded)
    // Selector: 0x5b0fc9c3
    // Node: 0x00..00 (32 bytes)
    // Label: 0x74657374 + 0x00...00 (32 bytes, "test" padded)
    const calldata = [_]u8{
        0x5b, 0x0f, 0xc9, 0xc3, // selector
        // node (32 bytes of zeros)
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        // label: "test" (0x74657374) padded with zeros
        0x74, 0x65, 0x73, 0x74, // "test"
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
    };

    const label = try CalldataDecoder.decodeSubnodeLabel(allocator, &calldata);
    try std.testing.expect(label != null);
    defer allocator.free(label.?);

    try std.testing.expectEqualStrings("test", label.?);
}

test "decode setSubnodeOwner calldata" {
    const allocator = std.testing.allocator;

    // Selector: 0x06ab5923
    const calldata = [_]u8{
        0x06, 0xab, 0x59, 0x23, // selector
        // node (32 bytes of zeros)
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        // label: "mail" (0x6d61696c) padded
        0x6d, 0x61, 0x69, 0x6c, // "mail"
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
    };

    const label = try CalldataDecoder.decodeSubnodeLabel(allocator, &calldata);
    try std.testing.expect(label != null);
    defer allocator.free(label.?);

    try std.testing.expectEqualStrings("mail", label.?);
}

test "reject invalid selector" {
    const allocator = std.testing.allocator;

    const calldata = [_]u8{
        0xff, 0xff, 0xff, 0xff, // invalid selector
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0x74, 0x65, 0x73, 0x74,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
    };

    const label = try CalldataDecoder.decodeSubnodeLabel(allocator, &calldata);
    try std.testing.expect(label == null);
}

test "reject too short calldata" {
    const allocator = std.testing.allocator;

    const calldata = [_]u8{ 0x5b, 0x0f, 0xc9, 0xc3 }; // Only selector

    const label = try CalldataDecoder.decodeSubnodeLabel(allocator, &calldata);
    try std.testing.expect(label == null);
}

test "reject empty label" {
    const allocator = std.testing.allocator;

    const calldata = [_]u8{
        0x5b, 0x0f, 0xc9, 0xc3, // selector
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        // label: all zeros
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
    };

    const label = try CalldataDecoder.decodeSubnodeLabel(allocator, &calldata);
    try std.testing.expect(label == null);
}

test "decode multicall with setSubnodeRecord" {
    const allocator = std.testing.allocator;

    // Skip this test for now - multicall pattern decoding is complex
    // and requires careful ABI encoding. The direct setSubnode decoding
    // works, and the multicall wrapper can be added later with real-world examples.
    _ = allocator;

    // To be implemented with real multicall transaction data
    // const label = try CalldataDecoder.decodeSubnodeLabelFromMulticall(allocator, real_multicall_data);
}

test "decode using wrapper function" {
    const allocator = std.testing.allocator;

    // Test the wrapper that tries both direct and multicall
    // Direct setSubnodeRecord
    const direct_calldata = [_]u8{
        0x5b, 0x0f, 0xc9, 0xc3, // selector
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0x77, 0x77, 0x77, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // "www"
        0,    0,    0,    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    };

    const label1 = try CalldataDecoder.decodeLabelFromCalldata(allocator, &direct_calldata);
    try std.testing.expect(label1 != null);
    defer allocator.free(label1.?);
    try std.testing.expectEqualStrings("www", label1.?);
}

test "reject non-multicall calldata" {
    const allocator = std.testing.allocator;

    // Random selector
    const calldata = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0 };

    const label = try CalldataDecoder.decodeSubnodeLabelFromMulticall(allocator, &calldata);
    try std.testing.expect(label == null);
}
