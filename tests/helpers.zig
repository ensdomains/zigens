/// Test helpers for ENS Indexer tests
/// Provides common utilities for creating test databases and fixtures
const std = @import("std");
const testing = std.testing;
const lib = @import("lib");
const Database = lib.Database;
const Address = lib.Address;
const Hash = lib.Hash;
const models = lib.models;

/// Create an in-memory test database with schema loaded
pub fn createTestDatabase(allocator: std.mem.Allocator) !*Database {
    const database = try allocator.create(Database);
    errdefer allocator.destroy(database);

    database.* = try Database.init(allocator, ":memory:");

    // Create webhooks table (loaded from separate schema directory in production)
    try createWebhooksSchema(database);

    return database;
}

/// Create webhooks schema for tests
fn createWebhooksSchema(database: *Database) !void {
    const webhooks_sql =
        \\CREATE TABLE IF NOT EXISTS webhooks (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  url TEXT NOT NULL,
        \\  event_types TEXT NOT NULL,
        \\  active INTEGER NOT NULL DEFAULT 1,
        \\  max_retries INTEGER NOT NULL DEFAULT 3,
        \\  created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
        \\);
        \\CREATE INDEX IF NOT EXISTS idx_webhooks_active ON webhooks(active);
        \\CREATE TABLE IF NOT EXISTS webhook_queue (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    webhook_id INTEGER NOT NULL,
        \\    webhook_url TEXT NOT NULL,
        \\    event_type TEXT NOT NULL,
        \\    chain TEXT NOT NULL,
        \\    block_number INTEGER NOT NULL,
        \\    tx_hash TEXT NOT NULL,
        \\    contract_address TEXT NOT NULL,
        \\    payload TEXT NOT NULL,
        \\    timestamp INTEGER NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'pending',
        \\    retry_count INTEGER NOT NULL DEFAULT 0,
        \\    last_attempt_at INTEGER,
        \\    next_retry_at INTEGER,
        \\    error_message TEXT,
        \\    created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
        \\    updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
        \\    FOREIGN KEY (webhook_id) REFERENCES webhooks(id) ON DELETE CASCADE
        \\);
    ;
    try database.exec(webhooks_sql);
}

/// Destroy test database and free resources
pub fn destroyTestDatabase(allocator: std.mem.Allocator, database: *Database) void {
    database.deinit();
    allocator.destroy(database);
}

/// Create a test registry in the database
pub fn createTestRegistry(
    database: *Database,
    chain: models.Chain,
    address_val: Address,
    name: []const u8,
    namehash_val: Hash,
) !void {
    try database.insertRegistry(models.Registry{
        .chain = chain,
        .address = address_val,
        .name = name,
        .namehash = namehash_val,
        .parent_registry = Address.zero,
        .created_block = 1000,
        .created_at = 1700000000,
    });
}

/// Create a test name in the database
pub fn createTestName(
    allocator: std.mem.Allocator,
    database: *Database,
    name: []const u8,
    owner: Address,
) !Hash {
    const nh = try lib.namehash(allocator, name);

    // Parse name parts
    var parts = std.mem.splitScalar(u8, name, '.');
    const label = parts.first();
    var parent_parts: std.ArrayList(u8) = .{};
    defer parent_parts.deinit(allocator);

    var first = true;
    while (parts.next()) |part| {
        if (!first) {
            try parent_parts.append(allocator, '.');
        }
        try parent_parts.appendSlice(allocator, part);
        first = false;
    }
    const parent_name = if (parent_parts.items.len > 0) parent_parts.items else "";
    const parent_nh = try lib.namehash(allocator, parent_name);
    const label_hash = try lib.labelhash(allocator, label);

    try database.insertName(models.Name{
        .chain = .l2,
        .name = name,
        .namehash = nh,
        .label = label,
        .label_hash = label_hash,
        .parent_name = parent_name,
        .parent_namehash = parent_nh,
        .registry = Address.zero,
        .owner = owner,
        .registrant = owner,
        .resolver = Address.zero,
        .token_id = 0,
        .canonical_id = 0,
        .token_version = 1,
        .expiry = 0,
        .registry_locked = false,
        .migrated = false,
        .ejected = false,
        .created_block = 1000,
        .created_at = 1700000000,
        .updated_block = 1000,
        .updated_at = 1700000000,
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    });

    return nh;
}

/// Create a test event in the database
pub fn createTestEvent(
    database: *Database,
    event_type: []const u8,
    name: ?[]const u8,
    namehash_val: ?Hash,
) !void {
    const timestamp = std.time.timestamp();
    var tx_hash: [32]u8 = undefined;
    std.crypto.random.bytes(&tx_hash);

    try database.insertEvent(models.Event{
        .chain = .l2,
        .event_type = event_type,
        .block_number = 1000,
        .tx_hash = Hash{ .bytes = tx_hash },
        .log_index = 0,
        .contract_address = Address.zero,
        .name = name,
        .namehash = namehash_val,
        .data = "{}",
        .timestamp = timestamp,
    });
}

/// Generate a random test address
pub fn randomAddress() Address {
    var bytes: [20]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    return Address{ .bytes = bytes };
}

/// Generate a random test hash
pub fn randomHash() Hash {
    var bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    return Hash{ .bytes = bytes };
}

/// Well-known test addresses
pub const TEST_OWNER_1 = Address{ .bytes = [_]u8{ 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11 } };
pub const TEST_OWNER_2 = Address{ .bytes = [_]u8{ 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22 } };
pub const TEST_REGISTRY = Address{ .bytes = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD } };
pub const TEST_RESOLVER = Address{ .bytes = [_]u8{ 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC } };
