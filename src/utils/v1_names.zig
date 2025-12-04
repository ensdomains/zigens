// ENS V1 Name Utilities
// Handles V1-specific name operations (tokenID conversion, namehash computation, etc.)

const std = @import("std");
const Hash = @import("../types/hash.zig").Hash;
const Keccak256 = std.crypto.hash.sha3.Keccak256;

// SQLITE_TRANSIENT - For Zig 0.15.1, we can't use the C constant due to alignment issues
// Instead, we use null which tells SQLite to make a copy of the string
inline fn SQLITE_TRANSIENT() @import("../storage/database.zig").c.sqlite3_destructor_type {
    return null;
}

/// Runtime keccak256 hash function
inline fn keccak256Runtime(input: []const u8) [32]u8 {
    var hash: [32]u8 = undefined;
    Keccak256.hash(input, &hash, .{});
    return hash;
}

/// Computes the namehash for an ENS V1 .eth name
/// Example: computeEthNamehash("vitalik") returns namehash of "vitalik.eth"
///
/// Namehash algorithm:
/// 1. Start with hash of empty string (all zeros)
/// 2. Hash "eth" label: keccak256(zeros ++ keccak256("eth"))
/// 3. Hash provided label: keccak256(eth_node ++ keccak256(label))
pub fn computeEthNamehash(label: []const u8) Hash {
    // Step 1: Root namehash (zeros)
    const root = Hash.zero;

    // Step 2: Compute "eth" node
    // eth_label_hash = keccak256("eth")
    const eth_label = "eth";
    const eth_label_hash = keccak256Runtime(eth_label);

    // eth_node = keccak256(root ++ eth_label_hash)
    var eth_node_input: [64]u8 = undefined;
    @memcpy(eth_node_input[0..32], &root.bytes);
    @memcpy(eth_node_input[32..64], &eth_label_hash);
    const eth_node_bytes = keccak256Runtime(&eth_node_input);

    // Step 3: Compute the full name node
    // label_hash = keccak256(label)
    const label_hash = keccak256Runtime(label);

    // name_node = keccak256(eth_node ++ label_hash)
    var name_node_input: [64]u8 = undefined;
    @memcpy(name_node_input[0..32], &eth_node_bytes);
    @memcpy(name_node_input[32..64], &label_hash);
    const name_node_bytes = keccak256Runtime(&name_node_input);

    var result: Hash = undefined;
    @memcpy(&result.bytes, &name_node_bytes);

    return result;
}

/// Computes the V1 label hash for a given label
/// In V1, tokenID = uint256(keccak256(label))
/// Returns the hash as a Hash type
pub fn computeLabelHash(label: []const u8) Hash {
    const label_hash_bytes = keccak256Runtime(label);

    var result: Hash = undefined;
    @memcpy(&result.bytes, &label_hash_bytes);

    return result;
}

/// Converts a label to its V1 Base Registrar tokenID
/// tokenID = uint256(keccak256(label))
/// Returns as hex string (caller must free)
pub fn labelToTokenId(allocator: std.mem.Allocator, label: []const u8) ![]const u8 {
    const label_hash = computeLabelHash(label);
    return try label_hash.toHex(allocator);
}

/// Looks up a label from a tokenID using the v1_labels table
/// Returns null if not found
/// Caller owns the returned string and must free it
pub fn tokenIdToLabel(
    allocator: std.mem.Allocator,
    db: anytype,
    token_id: []const u8,
) !?[]const u8 {
    const c = @import("../storage/database.zig").c;

    const query =
        \\SELECT label FROM v1_labels WHERE token_id = ?
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(
        db.db,
        query.ptr,
        @intCast(query.len),
        &stmt,
        null,
    );

    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare tokenIdToLabel query: {d}", .{prepare_result});
        return error.SqliteError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    // Bind token_id
    const token_id_z = try allocator.dupeZ(u8, token_id);
    defer allocator.free(token_id_z);

    _ = c.sqlite3_bind_text(stmt, 1, token_id_z.ptr, @intCast(token_id.len), SQLITE_TRANSIENT());

    // Execute query
    if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const label_ptr = c.sqlite3_column_text(stmt, 0);
        const label_slice = std.mem.span(label_ptr);
        return try allocator.dupe(u8, label_slice);
    }

    return null; // Not found
}

/// Stores a tokenID → label mapping in the v1_labels table
/// This is called when we learn a label (from NameRegistered, NameRenewed, etc.)
pub fn storeTokenIdLabel(
    allocator: std.mem.Allocator,
    db: anytype,
    token_id: []const u8,
    label: []const u8,
    namehash: Hash,
    block_number: u64,
    tx_hash: []const u8,
    source: []const u8,
) !void {
    const c = @import("../storage/database.zig").c;

    const query =
        \\INSERT OR IGNORE INTO v1_labels
        \\(token_id, label, namehash, first_seen_block, first_seen_tx, source)
        \\VALUES (?, ?, ?, ?, ?, ?)
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(
        db.db,
        query.ptr,
        @intCast(query.len),
        &stmt,
        null,
    );

    if (prepare_result != c.SQLITE_OK) {
        std.log.err("Failed to prepare storeTokenIdLabel query: {d}", .{prepare_result});
        return error.SqliteError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    // Bind parameters
    const token_id_z = try allocator.dupeZ(u8, token_id);
    defer allocator.free(token_id_z);

    const label_z = try allocator.dupeZ(u8, label);
    defer allocator.free(label_z);

    const namehash_hex = try namehash.toHex(allocator);
    defer allocator.free(namehash_hex);

    const namehash_z = try allocator.dupeZ(u8, namehash_hex);
    defer allocator.free(namehash_z);

    const tx_hash_z = try allocator.dupeZ(u8, tx_hash);
    defer allocator.free(tx_hash_z);

    const source_z = try allocator.dupeZ(u8, source);
    defer allocator.free(source_z);

    _ = c.sqlite3_bind_text(stmt, 1, token_id_z.ptr, @intCast(token_id.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 2, label_z.ptr, @intCast(label.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 3, namehash_z.ptr, @intCast(namehash_hex.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_int64(stmt, 4, @intCast(block_number));
    _ = c.sqlite3_bind_text(stmt, 5, tx_hash_z.ptr, @intCast(tx_hash.len), SQLITE_TRANSIENT());
    _ = c.sqlite3_bind_text(stmt, 6, source_z.ptr, @intCast(source.len), SQLITE_TRANSIENT());

    // Execute
    const step_result = c.sqlite3_step(stmt);
    if (step_result != c.SQLITE_DONE) {
        std.log.err("Failed to store tokenID label mapping: {d}", .{step_result});
        return error.SqliteError;
    }
}

test "computeEthNamehash - known values" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test 1: "vitalik.eth" - known namehash from ENS
    // namehash("vitalik.eth") = 0xee6c4522aab0003e8d14cd40a6af439055fd2577951148c14b6cea9a53475835
    const vitalik_namehash = computeEthNamehash("vitalik");
    const vitalik_hex = try vitalik_namehash.toHex(allocator);
    defer allocator.free(vitalik_hex);

    try testing.expectEqualStrings("ee6c4522aab0003e8d14cd40a6af439055fd2577951148c14b6cea9a53475835", vitalik_hex);

    // Test 2: "eth" node itself
    const eth_node = computeEthNamehash("");
    const eth_hex = try eth_node.toHex(allocator);
    defer allocator.free(eth_hex);

    // namehash("eth") = 0x93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae
    try testing.expectEqualStrings("93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae", eth_hex);

    // Test 3: "alice.eth"
    const alice_namehash = computeEthNamehash("alice");
    const alice_hex = try alice_namehash.toHex(allocator);
    defer allocator.free(alice_hex);

    // Should be deterministic
    try testing.expect(alice_hex.len == 64);

    // Computing same name twice should give same result
    const alice_namehash2 = computeEthNamehash("alice");
    try testing.expect(std.mem.eql(u8, &alice_namehash.bytes, &alice_namehash2.bytes));
}

test "computeLabelHash - known values" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test with known label hash
    // keccak256("vitalik") = 0xaf2caa1c2ca1d027f1ac823b529d0a67cd144264b2789fa2ea4d63a67c7103cc
    const label_hash = computeLabelHash("vitalik");
    const hash_hex = try label_hash.toHex(allocator);
    defer allocator.free(hash_hex);

    try testing.expectEqualStrings("af2caa1c2ca1d027f1ac823b529d0a67cd144264b2789fa2ea4d63a67c7103cc", hash_hex);

    // Test empty label
    const empty_hash = computeLabelHash("");
    const empty_hex = try empty_hash.toHex(allocator);
    defer allocator.free(empty_hex);

    // keccak256("") = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
    try testing.expectEqualStrings("c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470", empty_hex);
}

test "labelToTokenId" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test that tokenID matches label hash
    const token_id = try labelToTokenId(allocator, "vitalik");
    defer allocator.free(token_id);

    // Should equal the label hash
    try testing.expectEqualStrings("af2caa1c2ca1d027f1ac823b529d0a67cd144264b2789fa2ea4d63a67c7103cc", token_id);
}

test "storeTokenIdLabel and tokenIdToLabel - round trip" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const db = @import("../storage/database.zig");

    // Create in-memory test database
    var database = try db.Database.init(allocator, ":memory:");
    defer database.deinit();

    // Store a label
    const token_id = "af2caa1c2ca1d027f1ac823b529d0a67cd144264b2789fa2ea4d63a67c7103cc";
    const label = "vitalik";
    const namehash = computeEthNamehash(label);

    try storeTokenIdLabel(
        allocator,
        &database,
        token_id,
        label,
        namehash,
        12345678, // block_number
        "0x123abc", // tx_hash
        "test", // source
    );

    // Retrieve the label
    const retrieved = try tokenIdToLabel(allocator, &database, token_id);
    try testing.expect(retrieved != null);
    defer allocator.free(retrieved.?);

    try testing.expectEqualStrings(label, retrieved.?);
}

test "tokenIdToLabel - not found" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const db = @import("../storage/database.zig");

    // Create in-memory test database
    var database = try db.Database.init(allocator, ":memory:");
    defer database.deinit();

    // Try to retrieve non-existent label
    const result = try tokenIdToLabel(allocator, &database, "nonexistent");
    try testing.expect(result == null);
}

test "storeTokenIdLabel - duplicate insert" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const db = @import("../storage/database.zig");

    // Create in-memory test database
    var database = try db.Database.init(allocator, ":memory:");
    defer database.deinit();

    const token_id = "test123";
    const label = "testlabel";
    const namehash = computeEthNamehash(label);

    // Insert once
    try storeTokenIdLabel(
        allocator,
        &database,
        token_id,
        label,
        namehash,
        100,
        "0xaaa",
        "source1",
    );

    // Insert again with different data - should be ignored due to INSERT OR IGNORE
    try storeTokenIdLabel(
        allocator,
        &database,
        token_id,
        "different_label",
        namehash,
        200,
        "0xbbb",
        "source2",
    );

    // Should still have the first label
    const retrieved = try tokenIdToLabel(allocator, &database, token_id);
    try testing.expect(retrieved != null);
    defer allocator.free(retrieved.?);

    try testing.expectEqualStrings(label, retrieved.?);
}
