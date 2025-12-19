/// Storage tests for webhooks.zig
/// Tests webhook CRUD operations
const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers");
const lib = @import("lib");
const Database = lib.Database;
const webhooks = lib.storage.webhooks;
const models = lib.models;

// ============================================================================
// WEBHOOK INSERT OPERATIONS
// ============================================================================

test "insertWebhook creates webhook with event_types JSON" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const event_types = [_]models.EventType{ .name_registered, .transfer };
    const webhook = models.Webhook{
        .id = 0, // Will be assigned
        .url = "https://example.com/webhook",
        .event_types = &event_types,
        .active = true,
        .max_retries = 3,
        .created_at = 1700000000,
    };

    const id = try webhooks.insertWebhook(database, webhook);
    try testing.expect(id > 0);

    // Verify retrieval
    const retrieved = try webhooks.getWebhook(database, id);
    try testing.expect(retrieved != null);

    var wh = retrieved.?;
    defer wh.deinit(allocator);

    try testing.expectEqualStrings("https://example.com/webhook", wh.url);
    try testing.expect(wh.active);
    try testing.expectEqual(@as(usize, 2), wh.event_types.len);
}

test "insertWebhook with empty event_types" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const empty_types: []const models.EventType = &.{};
    const webhook = models.Webhook{
        .id = 0,
        .url = "https://example.com/empty",
        .event_types = empty_types,
        .active = true,
        .max_retries = 5,
        .created_at = 1700000000,
    };

    const id = try webhooks.insertWebhook(database, webhook);

    const retrieved = try webhooks.getWebhook(database, id);
    try testing.expect(retrieved != null);

    var wh = retrieved.?;
    defer wh.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), wh.event_types.len);
}

// ============================================================================
// WEBHOOK QUERY OPERATIONS
// ============================================================================

test "getWebhook returns webhook by id" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const event_types = [_]models.EventType{.name_registered};
    const webhook = models.Webhook{
        .id = 0,
        .url = "https://example.com/get",
        .event_types = &event_types,
        .active = true,
        .max_retries = 3,
        .created_at = 1700000000,
    };

    const id = try webhooks.insertWebhook(database, webhook);
    const retrieved = try webhooks.getWebhook(database, id);

    try testing.expect(retrieved != null);
    var wh = retrieved.?;
    defer wh.deinit(allocator);

    try testing.expectEqual(id, wh.id);
}

test "getWebhook returns null for unknown id" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const result = try webhooks.getWebhook(database, 99999);
    try testing.expect(result == null);
}

test "getWebhooks returns all webhooks" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const event_types = [_]models.EventType{.name_registered};

    // Insert multiple webhooks
    _ = try webhooks.insertWebhook(database, models.Webhook{
        .id = 0,
        .url = "https://example.com/1",
        .event_types = &event_types,
        .active = true,
        .max_retries = 3,
        .created_at = 1700000000,
    });

    _ = try webhooks.insertWebhook(database, models.Webhook{
        .id = 0,
        .url = "https://example.com/2",
        .event_types = &event_types,
        .active = false,
        .max_retries = 5,
        .created_at = 1700001000,
    });

    const all = try webhooks.getWebhooks(database);
    defer {
        for (all) |*wh| wh.deinit(allocator);
        allocator.free(all);
    }

    try testing.expectEqual(@as(usize, 2), all.len);
}

// ============================================================================
// WEBHOOK UPDATE OPERATIONS
// ============================================================================

test "updateWebhook updates URL" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const event_types = [_]models.EventType{.name_registered};
    const id = try webhooks.insertWebhook(database, models.Webhook{
        .id = 0,
        .url = "https://old.example.com",
        .event_types = &event_types,
        .active = true,
        .max_retries = 3,
        .created_at = 1700000000,
    });

    // Update URL
    try webhooks.updateWebhook(database, id, "https://new.example.com", null, null);

    const retrieved = try webhooks.getWebhook(database, id);
    try testing.expect(retrieved != null);

    var wh = retrieved.?;
    defer wh.deinit(allocator);

    try testing.expectEqualStrings("https://new.example.com", wh.url);
}

test "updateWebhook updates event_types" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const old_types = [_]models.EventType{.name_registered};
    const id = try webhooks.insertWebhook(database, models.Webhook{
        .id = 0,
        .url = "https://example.com/types",
        .event_types = &old_types,
        .active = true,
        .max_retries = 3,
        .created_at = 1700000000,
    });

    // Update event types
    const new_types = [_]models.EventType{ .transfer, .resolver_update };
    try webhooks.updateWebhook(database, id, null, &new_types, null);

    const retrieved = try webhooks.getWebhook(database, id);
    try testing.expect(retrieved != null);

    var wh = retrieved.?;
    defer wh.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), wh.event_types.len);
}

test "updateWebhook updates active status" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const event_types = [_]models.EventType{.name_registered};
    const id = try webhooks.insertWebhook(database, models.Webhook{
        .id = 0,
        .url = "https://example.com/active",
        .event_types = &event_types,
        .active = true,
        .max_retries = 3,
        .created_at = 1700000000,
    });

    // Deactivate
    try webhooks.updateWebhook(database, id, null, null, false);

    const retrieved = try webhooks.getWebhook(database, id);
    try testing.expect(retrieved != null);

    var wh = retrieved.?;
    defer wh.deinit(allocator);

    try testing.expect(!wh.active);
}

// ============================================================================
// WEBHOOK DELETE OPERATIONS
// ============================================================================

test "deleteWebhook removes webhook" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const event_types = [_]models.EventType{.name_registered};
    const id = try webhooks.insertWebhook(database, models.Webhook{
        .id = 0,
        .url = "https://example.com/delete",
        .event_types = &event_types,
        .active = true,
        .max_retries = 3,
        .created_at = 1700000000,
    });

    // Verify exists
    {
        const wh_opt = try webhooks.getWebhook(database, id);
        try testing.expect(wh_opt != null);
        var wh = wh_opt.?;
        wh.deinit(allocator);
    }

    // Delete
    try webhooks.deleteWebhook(database, id);

    // Verify deleted
    try testing.expect((try webhooks.getWebhook(database, id)) == null);
}

test "deleteWebhook with unknown id is no-op" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    // Should not error
    try webhooks.deleteWebhook(database, 99999);
}
