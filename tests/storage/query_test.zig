/// Tests for the Query executor abstraction (the backend statement seam).
const std = @import("std");
const testing = std.testing;
const lib = @import("lib");
const Query = lib.storage.Query;
const Database = lib.Database;
const Address = lib.Address;
const Hash = lib.Hash;
// Module-level helpers (exec/queryOne/queryText) live in the query module.
const query = lib.storage.database.query;

/// Test helper: Create an in-memory database
fn createTestDb(allocator: std.mem.Allocator) !*Database {
    const database = try allocator.create(Database);
    errdefer allocator.destroy(database);
    database.* = try Database.initWithoutSchema(allocator, ":memory:");
    return database;
}

fn destroyTestDb(allocator: std.mem.Allocator, database: *Database) void {
    database.deinit();
    allocator.destroy(database);
}

// ============================================================================
// BASIC QUERY TESTS
// ============================================================================

test "Query: create table and insert" {
    const allocator = testing.allocator;
    const database = try createTestDb(allocator);
    defer destroyTestDb(allocator, database);

    // Create table
    var create_q = try Query.init(database, "CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT, value INTEGER)");
    defer create_q.deinit();
    try create_q.exec();

    // Insert row
    var insert_q = try Query.init(database, "INSERT INTO test (name, value) VALUES (?, ?)");
    defer insert_q.deinit();
    try insert_q.bindText("hello");
    try insert_q.bindInt64(42);
    try insert_q.exec();

    // Verify
    var select_q = try Query.init(database, "SELECT name, value FROM test WHERE id = 1");
    defer select_q.deinit();
    try testing.expect(try select_q.step());

    const name = try select_q.getText(0);
    defer if (name) |n| allocator.free(n);
    try testing.expectEqualStrings("hello", name.?);
    try testing.expectEqual(@as(i64, 42), select_q.getInt64(1));

    try testing.expect(!try select_q.step()); // No more rows
}

test "Query: multiple rows" {
    const allocator = testing.allocator;
    const database = try createTestDb(allocator);
    defer destroyTestDb(allocator, database);

    // Create and populate table
    var create_q = try Query.init(database, "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)");
    defer create_q.deinit();
    try create_q.exec();

    const names = [_][]const u8{ "apple", "banana", "cherry" };
    for (names) |name| {
        var insert_q = try Query.init(database, "INSERT INTO items (name) VALUES (?)");
        defer insert_q.deinit();
        try insert_q.bindText(name);
        try insert_q.exec();
    }

    // Query all
    var select_q = try Query.init(database, "SELECT name FROM items ORDER BY id");
    defer select_q.deinit();

    var count: usize = 0;
    while (try select_q.step()) {
        const name_slice = select_q.getTextSlice(0);
        try testing.expectEqualStrings(names[count], name_slice.?);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 3), count);
}

test "Query: NULL handling" {
    const allocator = testing.allocator;
    const database = try createTestDb(allocator);
    defer destroyTestDb(allocator, database);

    // Create table
    var create_q = try Query.init(database, "CREATE TABLE nullable (id INTEGER PRIMARY KEY, name TEXT, value INTEGER)");
    defer create_q.deinit();
    try create_q.exec();

    // Insert with NULL values
    var insert_q = try Query.init(database, "INSERT INTO nullable (name, value) VALUES (?, ?)");
    defer insert_q.deinit();
    try insert_q.bindNull();
    try insert_q.bindNull();
    try insert_q.exec();

    // Query and check
    var select_q = try Query.init(database, "SELECT name, value FROM nullable WHERE id = 1");
    defer select_q.deinit();
    try testing.expect(try select_q.step());

    try testing.expect(select_q.isNull(0));
    try testing.expect(select_q.isNull(1));
    try testing.expectEqual(@as(?[]u8, null), try select_q.getText(0));
    try testing.expectEqual(@as(?i64, null), select_q.getOptionalInt64(1));
}

test "Query: optional binding" {
    const allocator = testing.allocator;
    const database = try createTestDb(allocator);
    defer destroyTestDb(allocator, database);

    // Create table
    var create_q = try Query.init(database, "CREATE TABLE opt (id INTEGER PRIMARY KEY, name TEXT, value INTEGER)");
    defer create_q.deinit();
    try create_q.exec();

    // Insert with optional values
    var insert_q = try Query.init(database, "INSERT INTO opt (name, value) VALUES (?, ?)");
    defer insert_q.deinit();

    const maybe_name: ?[]const u8 = "test";
    const maybe_value: ?i64 = null;
    try insert_q.bindOptionalText(maybe_name);
    try insert_q.bindOptionalInt64(maybe_value);
    try insert_q.exec();

    // Query and check
    var select_q = try Query.init(database, "SELECT name, value FROM opt WHERE id = 1");
    defer select_q.deinit();
    try testing.expect(try select_q.step());

    const name = try select_q.getText(0);
    defer if (name) |n| allocator.free(n);
    try testing.expectEqualStrings("test", name.?);
    try testing.expectEqual(@as(?i64, null), select_q.getOptionalInt64(1));
}

test "Query: reset and reuse" {
    const allocator = testing.allocator;
    const database = try createTestDb(allocator);
    defer destroyTestDb(allocator, database);

    // Create table
    var create_q = try Query.init(database, "CREATE TABLE reuse (id INTEGER PRIMARY KEY, name TEXT)");
    defer create_q.deinit();
    try create_q.exec();

    // Reusable insert query
    var insert_q = try Query.init(database, "INSERT INTO reuse (name) VALUES (?)");
    defer insert_q.deinit();

    try insert_q.bindText("first");
    try insert_q.exec();
    insert_q.reset();

    try insert_q.bindText("second");
    try insert_q.exec();
    insert_q.reset();

    try insert_q.bindText("third");
    try insert_q.exec();

    // Verify count
    var count_q = try Query.init(database, "SELECT COUNT(*) FROM reuse");
    defer count_q.deinit();
    try testing.expect(try count_q.step());
    try testing.expectEqual(@as(i64, 3), count_q.getInt64(0));
}

test "Query: bool extraction" {
    const allocator = testing.allocator;
    const database = try createTestDb(allocator);
    defer destroyTestDb(allocator, database);

    // Create table
    var create_q = try Query.init(database, "CREATE TABLE flags (id INTEGER PRIMARY KEY, enabled INTEGER)");
    defer create_q.deinit();
    try create_q.exec();

    // Insert rows
    var insert_q = try Query.init(database, "INSERT INTO flags (enabled) VALUES (?)");
    defer insert_q.deinit();
    try insert_q.bindInt(1);
    try insert_q.exec();
    insert_q.reset();
    try insert_q.bindInt(0);
    try insert_q.exec();

    // Query and check
    var select_q = try Query.init(database, "SELECT enabled FROM flags ORDER BY id");
    defer select_q.deinit();

    try testing.expect(try select_q.step());
    try testing.expect(select_q.getBool(0));

    try testing.expect(try select_q.step());
    try testing.expect(!select_q.getBool(0));
}

test "Query: changes count" {
    const allocator = testing.allocator;
    const database = try createTestDb(allocator);
    defer destroyTestDb(allocator, database);

    // Create table
    var create_q = try Query.init(database, "CREATE TABLE changes (id INTEGER PRIMARY KEY, name TEXT)");
    defer create_q.deinit();
    try create_q.exec();

    // Insert rows
    var insert_q = try Query.init(database, "INSERT INTO changes (name) VALUES ('a'), ('b'), ('c')");
    defer insert_q.deinit();
    try insert_q.exec();
    try testing.expectEqual(@as(u32, 3), insert_q.changes());

    // Update some rows
    var update_q = try Query.init(database, "UPDATE changes SET name = 'updated' WHERE id < 3");
    defer update_q.deinit();
    try update_q.exec();
    try testing.expectEqual(@as(u32, 2), update_q.changes());
}

// ============================================================================
// ADDRESS AND HASH TESTS
// ============================================================================

test "Query: Address binding and extraction" {
    const allocator = testing.allocator;
    const database = try createTestDb(allocator);
    defer destroyTestDb(allocator, database);

    // Create table
    var create_q = try Query.init(database, "CREATE TABLE addrs (id INTEGER PRIMARY KEY, addr TEXT)");
    defer create_q.deinit();
    try create_q.exec();

    // Insert address
    const addr = Address.fromHex("0x1234567890abcdef1234567890abcdef12345678") catch unreachable;
    var insert_q = try Query.init(database, "INSERT INTO addrs (addr) VALUES (?)");
    defer insert_q.deinit();
    try insert_q.bindAddress(addr);
    try insert_q.exec();

    // Query and verify
    var select_q = try Query.init(database, "SELECT addr FROM addrs WHERE id = 1");
    defer select_q.deinit();
    try testing.expect(try select_q.step());

    const retrieved = try select_q.getAddress(0);
    try testing.expect(retrieved != null);
    try testing.expect(retrieved.?.eql(addr));
}

test "Query: Hash binding" {
    const allocator = testing.allocator;
    const database = try createTestDb(allocator);
    defer destroyTestDb(allocator, database);

    // Create table
    var create_q = try Query.init(database, "CREATE TABLE hashes (id INTEGER PRIMARY KEY, hash TEXT)");
    defer create_q.deinit();
    try create_q.exec();

    // Insert hash
    const hash = Hash.fromHex("0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef") catch unreachable;
    var insert_q = try Query.init(database, "INSERT INTO hashes (hash) VALUES (?)");
    defer insert_q.deinit();
    try insert_q.bindHash(hash);
    try insert_q.exec();

    // Query and verify
    var select_q = try Query.init(database, "SELECT hash FROM hashes WHERE id = 1");
    defer select_q.deinit();
    try testing.expect(try select_q.step());

    const retrieved = try select_q.getHash(0);
    try testing.expect(retrieved != null);
    try testing.expect(retrieved.?.eql(hash));
}

// ============================================================================
// CONVENIENCE FUNCTION TESTS
// ============================================================================

test "query.exec convenience function" {
    const allocator = testing.allocator;
    const database = try createTestDb(allocator);
    defer destroyTestDb(allocator, database);

    try query.exec(database, "CREATE TABLE simple (id INTEGER)");

    // Verify table exists
    var select_q = try Query.init(database, "SELECT name FROM sqlite_master WHERE type='table' AND name='simple'");
    defer select_q.deinit();
    try testing.expect(try select_q.step());
}

test "query.queryOne convenience function" {
    const allocator = testing.allocator;
    const database = try createTestDb(allocator);
    defer destroyTestDb(allocator, database);

    try query.exec(database, "CREATE TABLE nums (val INTEGER)");
    try query.exec(database, "INSERT INTO nums VALUES (42)");

    const result = try query.queryOne(i64, database, "SELECT val FROM nums", struct {
        fn bind(_: *Query) !void {}
    }.bind);
    try testing.expectEqual(@as(?i64, 42), result);
}

test "query.queryText convenience function" {
    const allocator = testing.allocator;
    const database = try createTestDb(allocator);
    defer destroyTestDb(allocator, database);

    try query.exec(database, "CREATE TABLE texts (val TEXT)");
    try query.exec(database, "INSERT INTO texts VALUES ('hello world')");

    const result = try query.queryText(database, "SELECT val FROM texts", struct {
        fn bind(_: *Query) !void {}
    }.bind);
    defer if (result) |r| allocator.free(r);
    try testing.expectEqualStrings("hello world", result.?);
}

// ============================================================================
// DIALECT BUILDER TESTS (SQLite emits today's exact SQL)
// ============================================================================

test "Dialect: upsert replace/ignore" {
    const allocator = testing.allocator;
    const database = try createTestDb(allocator);
    defer destroyTestDb(allocator, database);
    const d = database.dialect();

    const replace_sql = try d.upsert(allocator, "names", &.{ "namehash", "owner" }, &.{}, &.{"namehash"}, .replace);
    defer allocator.free(replace_sql);
    try testing.expectEqualStrings("INSERT OR REPLACE INTO \"names\" (\"namehash\", \"owner\") VALUES (?, ?)", replace_sql);

    const ignore_sql = try d.upsert(allocator, "events", &.{"id"}, &.{}, &.{}, .ignore);
    defer allocator.free(ignore_sql);
    try testing.expectEqualStrings("INSERT OR IGNORE INTO \"events\" (\"id\") VALUES (?)", ignore_sql);

    // value_exprs: literals and wrappers stay inline (binds unchanged at call sites).
    const expr_sql = try d.upsert(allocator, "name_history", &.{ "protocol", "change_type", "old_value", "log_index" }, &.{ "?", "'migration'", "NULL", "0" }, &.{}, .ignore);
    defer allocator.free(expr_sql);
    try testing.expectEqualStrings("INSERT OR IGNORE INTO \"name_history\" (\"protocol\", \"change_type\", \"old_value\", \"log_index\") VALUES (?, 'migration', NULL, 0)", expr_sql);

    // insertSelect: verb + cols wrap the caller's SELECT body verbatim.
    const sel_sql = try d.insertSelect(allocator, "resolvers", &.{ "protocol", "address" }, "SELECT n.protocol, n.resolver FROM names n WHERE n.resolver != ''", &.{}, .ignore);
    defer allocator.free(sel_sql);
    try testing.expectEqualStrings("INSERT OR IGNORE INTO \"resolvers\" (\"protocol\", \"address\") SELECT n.protocol, n.resolver FROM names n WHERE n.resolver != ''", sel_sql);
}

test "Database.upsertSql: resolves the schema conflict key + builds SQLite SQL" {
    const allocator = testing.allocator;
    const database = try createTestDb(allocator);
    defer destroyTestDb(allocator, database);

    // The conflict key (UNIQUE(protocol, resolver, namehash, key)) is resolved
    // centrally; SQLite ignores it, so the emitted statement is the literal verb.
    const sql = try database.upsertSql(allocator, "resolver_texts", &.{ "namehash", "resolver", "key", "value" }, .replace);
    defer allocator.free(sql);
    try testing.expectEqualStrings(
        "INSERT OR REPLACE INTO \"resolver_texts\" (\"namehash\", \"resolver\", \"key\", \"value\") VALUES (?, ?, ?, ?)",
        sql,
    );

    const ignore_sql = try database.upsertSql(allocator, "events", &.{ "tx_hash", "log_index" }, .ignore);
    defer allocator.free(ignore_sql);
    try testing.expectEqualStrings(
        "INSERT OR IGNORE INTO \"events\" (\"tx_hash\", \"log_index\") VALUES (?, ?)",
        ignore_sql,
    );

    try testing.expectError(error.UnknownUpsertTable, database.upsertSql(allocator, "not_a_table", &.{"x"}, .replace));
}

test "Dialect: returning / nowEpoch / jsonObject / jsonExtract" {
    const allocator = testing.allocator;
    const database = try createTestDb(allocator);
    defer destroyTestDb(allocator, database);
    const d = database.dialect();

    try testing.expectEqual(@as(@TypeOf(d.placeholder), .qmark), d.placeholder);
    try testing.expectEqualStrings("strftime('%s', 'now')", d.nowEpoch);

    const ret = try d.returning(allocator, "id");
    defer allocator.free(ret);
    try testing.expectEqualStrings(" RETURNING id", ret);

    const obj = try d.jsonObject(allocator, &.{ "protocol", "namehash" }, "OLD");
    defer allocator.free(obj);
    try testing.expectEqualStrings("json_object('protocol', OLD.\"protocol\", 'namehash', OLD.\"namehash\")", obj);

    const ext = try d.jsonExtract(allocator, "?1", "owner");
    defer allocator.free(ext);
    try testing.expectEqualStrings("json_extract(?1, '$.owner')", ext);
}
