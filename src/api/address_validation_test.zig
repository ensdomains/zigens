const std = @import("std");
const testing = std.testing;
const Address = @import("address").Address;

// Tests for contract address validation in GraphQL events filter
// These tests verify the behavior of Address.fromHex() which is used to validate
// and normalize contract addresses in the events query filter.

// ============================================================================
// VALID ADDRESS TESTS
// ============================================================================

test "valid checksummed address with 0x prefix" {
    // EIP-55 checksummed addresses should be accepted
    const addr = try Address.fromHex("0xF332544e6234f1CA149907D0d4658afD5feB6831");
    const hex = try addr.toHex(testing.allocator);
    defer testing.allocator.free(hex);

    // Output should be lowercase
    try testing.expectEqualStrings("0xf332544e6234f1ca149907d0d4658afd5feb6831", hex);
}

test "valid lowercase address with 0x prefix" {
    const addr = try Address.fromHex("0xf332544e6234f1ca149907d0d4658afd5feb6831");
    const hex = try addr.toHex(testing.allocator);
    defer testing.allocator.free(hex);

    try testing.expectEqualStrings("0xf332544e6234f1ca149907d0d4658afd5feb6831", hex);
}

test "valid uppercase address with 0x prefix" {
    const addr = try Address.fromHex("0xF332544E6234F1CA149907D0D4658AFD5FEB6831");
    const hex = try addr.toHex(testing.allocator);
    defer testing.allocator.free(hex);

    // Output should be normalized to lowercase
    try testing.expectEqualStrings("0xf332544e6234f1ca149907d0d4658afd5feb6831", hex);
}

test "valid address without 0x prefix" {
    // Address without 0x prefix should also work
    const addr = try Address.fromHex("f332544e6234f1ca149907d0d4658afd5feb6831");
    const hex = try addr.toHex(testing.allocator);
    defer testing.allocator.free(hex);

    try testing.expectEqualStrings("0xf332544e6234f1ca149907d0d4658afd5feb6831", hex);
}

test "valid zero address" {
    const addr = try Address.fromHex("0x0000000000000000000000000000000000000000");
    try testing.expect(addr.isZero());
}

test "valid address - all zeros except last byte" {
    const addr = try Address.fromHex("0x0000000000000000000000000000000000000001");
    try testing.expect(!addr.isZero());
    try testing.expectEqual(@as(u8, 1), addr.bytes[19]);
}

test "valid address - common ENS registry address" {
    // ENS Registry on mainnet
    const addr = try Address.fromHex("0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e");
    const hex = try addr.toHex(testing.allocator);
    defer testing.allocator.free(hex);

    try testing.expectEqualStrings("0x00000000000c2e074ec69a0dfb2997ba6c7d2e1e", hex);
}

// ============================================================================
// INVALID ADDRESS TESTS - These should return errors
// ============================================================================

test "invalid address - too short" {
    const result = Address.fromHex("0x1234");
    try testing.expectError(error.InvalidAddressLength, result);
}

test "invalid address - too long" {
    const result = Address.fromHex("0xf332544e6234f1ca149907d0d4658afd5feb6831EXTRA");
    try testing.expectError(error.InvalidAddressLength, result);
}

test "invalid address - empty string" {
    const result = Address.fromHex("");
    try testing.expectError(error.InvalidAddressLength, result);
}

test "invalid address - only 0x prefix" {
    const result = Address.fromHex("0x");
    try testing.expectError(error.InvalidAddressLength, result);
}

test "invalid address - invalid hex characters" {
    // Contains 'G' which is not a valid hex character
    const result = Address.fromHex("0xGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG");
    try testing.expectError(error.InvalidCharacter, result);
}

test "invalid address - contains spaces" {
    const result = Address.fromHex("0xf332 544e 6234 f1ca 1499 07d0 d465 8afd 5feb 6831");
    try testing.expectError(error.InvalidAddressLength, result);
}

test "invalid address - random text" {
    const result = Address.fromHex("invalid");
    try testing.expectError(error.InvalidAddressLength, result);
}

test "invalid address - ENS name instead of address" {
    const result = Address.fromHex("vitalik.eth");
    try testing.expectError(error.InvalidAddressLength, result);
}

test "invalid address - partial address" {
    const result = Address.fromHex("0xf332544e6234f1ca");
    try testing.expectError(error.InvalidAddressLength, result);
}

test "invalid address - 39 hex chars (1 short)" {
    const result = Address.fromHex("0xf332544e6234f1ca149907d0d4658afd5feb683");
    try testing.expectError(error.InvalidAddressLength, result);
}

test "invalid address - 41 hex chars (1 extra)" {
    const result = Address.fromHex("0xf332544e6234f1ca149907d0d4658afd5feb68311");
    try testing.expectError(error.InvalidAddressLength, result);
}

test "invalid address - mixed valid and invalid chars" {
    // Contains 'z' which is not valid hex
    const result = Address.fromHex("0xf332544e6234f1ca149907d0d4658afd5feb683z");
    try testing.expectError(error.InvalidCharacter, result);
}

test "invalid address - special characters" {
    const result = Address.fromHex("0x!@#$%^&*()!@#$%^&*()!@#$%^&*()!@#$%^&*()");
    try testing.expectError(error.InvalidCharacter, result);
}

test "invalid address - unicode characters" {
    const result = Address.fromHex("0x🌟🌟🌟🌟🌟🌟🌟🌟🌟🌟🌟🌟🌟🌟🌟🌟🌟🌟🌟🌟");
    // Unicode chars don't map to 40 hex chars properly
    try testing.expectError(error.InvalidAddressLength, result);
}

// ============================================================================
// CASE INSENSITIVITY TESTS
// ============================================================================

test "case insensitive - mixed case address normalizes to lowercase" {
    const checksummed = try Address.fromHex("0xF332544e6234f1CA149907D0d4658afD5feB6831");
    const lowercase = try Address.fromHex("0xf332544e6234f1ca149907d0d4658afd5feb6831");
    const uppercase = try Address.fromHex("0xF332544E6234F1CA149907D0D4658AFD5FEB6831");

    // All should produce the same bytes
    try testing.expect(checksummed.eql(lowercase));
    try testing.expect(checksummed.eql(uppercase));
    try testing.expect(lowercase.eql(uppercase));
}

test "case insensitive - output is always lowercase" {
    const addr = try Address.fromHex("0xABCDEF0123456789ABCDEF0123456789ABCDEF01");
    const hex = try addr.toHex(testing.allocator);
    defer testing.allocator.free(hex);

    try testing.expectEqualStrings("0xabcdef0123456789abcdef0123456789abcdef01", hex);
}

// ============================================================================
// EDGE CASES
// ============================================================================

test "edge case - address with all same digits" {
    const addr = try Address.fromHex("0x1111111111111111111111111111111111111111");
    const hex = try addr.toHex(testing.allocator);
    defer testing.allocator.free(hex);

    try testing.expectEqualStrings("0x1111111111111111111111111111111111111111", hex);
}

test "edge case - address with max value" {
    const addr = try Address.fromHex("0xffffffffffffffffffffffffffffffffffffffff");
    for (addr.bytes) |byte| {
        try testing.expectEqual(@as(u8, 0xff), byte);
    }
}

test "edge case - address with alternating bytes" {
    const addr = try Address.fromHex("0xaabbccddeeaabbccddeeaabbccddeeaabbccddee");
    const hex = try addr.toHex(testing.allocator);
    defer testing.allocator.free(hex);

    try testing.expectEqualStrings("0xaabbccddeeaabbccddeeaabbccddeeaabbccddee", hex);
}

// ============================================================================
// ROUND-TRIP TESTS
// ============================================================================

test "round trip - fromHex -> toHex preserves value" {
    const original = "0xf332544e6234f1ca149907d0d4658afd5feb6831";
    const addr = try Address.fromHex(original);
    const hex = try addr.toHex(testing.allocator);
    defer testing.allocator.free(hex);

    try testing.expectEqualStrings(original, hex);
}

test "round trip - checksummed input normalizes to lowercase output" {
    const checksummed_input = "0xF332544e6234f1CA149907D0d4658afD5feB6831";
    const expected_output = "0xf332544e6234f1ca149907d0d4658afd5feb6831";

    const addr = try Address.fromHex(checksummed_input);
    const hex = try addr.toHex(testing.allocator);
    defer testing.allocator.free(hex);

    try testing.expectEqualStrings(expected_output, hex);
}

// ============================================================================
// COMPARISON TESTS
// ============================================================================

test "equality - same address different case are equal" {
    const addr1 = try Address.fromHex("0xf332544e6234f1ca149907d0d4658afd5feb6831");
    const addr2 = try Address.fromHex("0xF332544E6234F1CA149907D0D4658AFD5FEB6831");

    try testing.expect(addr1.eql(addr2));
}

test "equality - different addresses are not equal" {
    const addr1 = try Address.fromHex("0xf332544e6234f1ca149907d0d4658afd5feb6831");
    const addr2 = try Address.fromHex("0x0000000000000000000000000000000000000001");

    try testing.expect(!addr1.eql(addr2));
}

test "equality - zero address comparison" {
    const addr1 = try Address.fromHex("0x0000000000000000000000000000000000000000");
    const addr2 = Address.zero;

    try testing.expect(addr1.eql(addr2));
    try testing.expect(addr1.isZero());
}

// ============================================================================
// GRAPHQL FILTER USE CASE TESTS
// These simulate how addresses are validated in resolveEvents
// ============================================================================

test "graphql filter - valid address passes validation" {
    const filter_value = "0xF332544e6234f1CA149907D0d4658afD5feB6831";

    // Simulate the validation logic in resolveEvents
    const addr = Address.fromHex(filter_value) catch {
        try testing.expect(false); // Should not reach here
        return;
    };

    const normalized = try addr.toHex(testing.allocator);
    defer testing.allocator.free(normalized);

    // Normalized address should work for database queries (lowercase)
    try testing.expectEqualStrings("0xf332544e6234f1ca149907d0d4658afd5feb6831", normalized);
}

test "graphql filter - invalid address is rejected" {
    const filter_value = "invalid";

    // Simulate the validation logic in resolveEvents
    const result = Address.fromHex(filter_value);

    // Should return an error
    try testing.expect(result == error.InvalidAddressLength);
}

test "graphql filter - short address is rejected" {
    const filter_value = "0x1234";

    const result = Address.fromHex(filter_value);
    try testing.expect(result == error.InvalidAddressLength);
}

test "graphql filter - ens name is rejected" {
    const filter_value = "hello.eth";

    const result = Address.fromHex(filter_value);
    try testing.expect(result == error.InvalidAddressLength);
}
