//! Driver-conformance suite: the executable spec for the storage SPI
//! (`src/storage/backend.zig`). Every behavior pinned here is one the storage
//! layer relies on or publishes as SPI surface; a third-party backend that
//! passes this suite against its own driver satisfies the contract documented
//! in docs/backend-spi.md.
//!
//! Runs against SQLite by default and against PostgreSQL with
//! TEST_BACKEND=postgres (the `test-storage-pg` lane), like the other storage
//! suites — both shipped drivers must pass.

const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers");
const lib = @import("lib");
const Database = lib.Database;
const backend_mod = lib.storage.backend;
const sqlite_driver = lib.storage.sqlite;

fn createScratch(database: *Database) !void {
    const ddl = if (database.isPostgres())
        \\CREATE TABLE conformance_t (
        \\  id BIGSERIAL PRIMARY KEY,
        \\  k TEXT NOT NULL UNIQUE,
        \\  t TEXT,
        \\  n BIGINT,
        \\  doc TEXT
        \\)
    else
        \\CREATE TABLE conformance_t (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  k TEXT NOT NULL UNIQUE,
        \\  t TEXT,
        \\  n INTEGER,
        \\  doc TEXT
        \\)
    ;
    try database.exec(ddl);
}

fn insertRow(database: *Database, k: []const u8, t: ?[]const u8, n: ?i64) !void {
    var q = try database.prepare("INSERT INTO conformance_t (k, t, n) VALUES (?, ?, ?)");
    defer q.deinit();
    try q.bindText(k);
    try q.bindOptionalText(t);
    try q.bindOptionalInt64(n);
    try q.exec();
}

fn countRows(database: *Database, where: []const u8) !i64 {
    const sql = try std.fmt.allocPrint(testing.allocator, "SELECT COUNT(*) FROM conformance_t WHERE {s}", .{where});
    defer testing.allocator.free(sql);
    var q = try database.prepare(sql);
    defer q.deinit();
    try testing.expect(try q.step());
    return q.getInt64(0);
}

test "caps: shipped drivers declare the contract the storage layer relies on" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    const caps = database.caps();
    try testing.expect(caps.server_side_undo);
    try testing.expect(caps.returning);
    try testing.expect(caps.savepoints);
    try testing.expectEqual(database.dialect().placeholder, caps.placeholder);
    try testing.expectEqual(database.isPostgres(), caps.placeholder == .dollar);
}

test "server_side_undo=false: no triggers installed, write-path capture works" {
    const allocator = testing.allocator;
    const reorg_undo = lib.storage.reorg_undo;

    var be = try sqlite_driver.open(allocator, ":memory:");
    be.caps.server_side_undo = false;
    var database = try Database.initWithBackend(allocator, be);
    defer database.deinit();

    {
        var q = try database.prepare("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name LIKE '%_reorg_undo_%'");
        defer q.deinit();
        try testing.expect(try q.step());
        try testing.expectEqual(@as(i64, 0), q.getInt64(0));
    }

    const nh = try helpers.createTestName(allocator, &database, "fallback.eth", helpers.TEST_OWNER_1);
    try reorg_undo.setCursor(&database, .v2, 1234);
    try reorg_undo.captureWhere(&database, "names", "U", "namehash = ?", .{nh});

    var q = try database.prepare("SELECT protocol, block_number, table_name, op, old_row FROM reorg_undo");
    defer q.deinit();
    try testing.expect(try q.step());
    try testing.expectEqualStrings("v2", q.getTextSlice(0).?);
    try testing.expectEqual(@as(i64, 1234), q.getInt64(1));
    try testing.expectEqualStrings("names", q.getTextSlice(2).?);
    try testing.expectEqualStrings("U", q.getTextSlice(3).?);
    try testing.expect(std.mem.indexOf(u8, q.getTextSlice(4).?, "fallback.eth") != null);
    try testing.expect(!(try q.step()));
}

test "bind cursor is sequential and 1-based; bindText copies the value" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    try createScratch(database);

    var buf = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    {
        var q = try database.prepare("INSERT INTO conformance_t (k, t, n) VALUES (?, ?, ?)");
        defer q.deinit();
        try q.bindText("key1");
        try q.bindText(buf[0..]);
        @memset(buf[0..], 'X');
        try q.bindInt64(42);
        try q.exec();
    }

    var q = try database.prepare("SELECT t, n FROM conformance_t WHERE k = ?");
    defer q.deinit();
    try q.bindTextStatic("key1");
    try testing.expect(try q.step());
    try testing.expectEqualStrings("hello", q.getTextSlice(0).?);
    try testing.expectEqual(@as(i64, 42), q.getInt64(1));
}

test "text binds are stored as valid UTF-8 on every backend: invalid bytes become U+FFFD" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    try createScratch(database);

    // The staging poison (a lone 0xEF lead byte) through both bind paths; on
    // Postgres the raw bytes would fail with 22021 and abort the transaction.
    const poison = "k\xEF\x58\x17";
    {
        var q = try database.prepare("INSERT INTO conformance_t (k, t, n) VALUES (?, ?, ?)");
        defer q.deinit();
        try q.bindText("copied");
        try q.bindText(poison);
        try q.bindInt64(1);
        try q.exec();
    }
    {
        var q = try database.prepare("INSERT INTO conformance_t (k, t, n) VALUES (?, ?, ?)");
        defer q.deinit();
        try q.bindTextStatic("static");
        try q.bindTextStatic(poison);
        try q.bindInt64(2);
        try q.exec();
    }
    var q = try database.prepare("SELECT k, t FROM conformance_t WHERE k IN (?, ?) ORDER BY k");
    defer q.deinit();
    try q.bindTextStatic("copied");
    try q.bindTextStatic("static");
    try testing.expect(try q.step());
    try testing.expectEqualStrings("k\xEF\xBF\xBDX\x17", q.getTextSlice(1).?);
    try testing.expect(try q.step());
    try testing.expectEqualStrings("k\xEF\xBF\xBDX\x17", q.getTextSlice(1).?);
    try testing.expect(!(try q.step()));
}

test "null binds read back as NULL through every accessor" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    try createScratch(database);

    try insertRow(database, "nulls", null, null);
    try insertRow(database, "vals", "txt", 7);

    {
        var q = try database.prepare("SELECT t, n FROM conformance_t WHERE k = 'nulls'");
        defer q.deinit();
        try testing.expect(try q.step());
        try testing.expect(q.isNull(0));
        try testing.expect(q.isNull(1));
        try testing.expectEqual(@as(?[]const u8, null), q.getTextSlice(0));
        try testing.expectEqual(@as(?[]u8, null), try q.getText(0));
        try testing.expectEqual(@as(?i64, null), q.getOptionalInt64(1));
        try testing.expectEqual(@as(?lib.Address, null), try q.getAddress(0));
        try testing.expectEqual(@as(?lib.Hash, null), try q.getHash(0));
    }
    {
        var q = try database.prepare("SELECT t, n FROM conformance_t WHERE k = 'vals'");
        defer q.deinit();
        try testing.expect(try q.step());
        try testing.expect(!q.isNull(0));
        try testing.expectEqual(@as(?i64, 7), q.getOptionalInt64(1));
    }
}

test "step iterates rows in order, then reports done" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    try createScratch(database);

    try insertRow(database, "a", "1", 1);
    try insertRow(database, "b", "2", 2);
    try insertRow(database, "c", "3", 3);

    {
        var q = try database.prepare("SELECT n FROM conformance_t ORDER BY n");
        defer q.deinit();
        var expected: i64 = 1;
        while (try q.step()) : (expected += 1) {
            try testing.expectEqual(expected, q.getInt64(0));
        }
        try testing.expectEqual(@as(i64, 4), expected);
    }
    {
        var q = try database.prepare("SELECT n FROM conformance_t WHERE k = 'missing'");
        defer q.deinit();
        try testing.expect(!(try q.step()));
    }
}

test "changes reports affected rows immediately after exec of DML" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    try createScratch(database);

    {
        var q = try database.prepare("INSERT INTO conformance_t (k, n) VALUES (?, ?)");
        defer q.deinit();
        try q.bindText("c1");
        try q.bindInt64(1);
        try q.exec();
        try testing.expectEqual(@as(u32, 1), q.changes());
    }
    try insertRow(database, "c2", null, 1);
    {
        var q = try database.prepare("UPDATE conformance_t SET n = 9 WHERE n = 1");
        defer q.deinit();
        try q.exec();
        try testing.expectEqual(@as(u32, 2), q.changes());
    }
    {
        var q = try database.prepare("UPDATE conformance_t SET n = 9 WHERE k = 'missing'");
        defer q.deinit();
        try q.exec();
        try testing.expectEqual(@as(u32, 0), q.changes());
    }
    {
        var q = try database.prepare("DELETE FROM conformance_t WHERE n = 9");
        defer q.deinit();
        try q.exec();
        try testing.expectEqual(@as(u32, 2), q.changes());
    }
}

test "insert id: lastInsertId on qmark backends, RETURNING on dollar backends" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    try createScratch(database);

    // The production idiom (storage/webhooks.zig): PG callers append RETURNING
    // and read the id from the row; SQLite callers use exec + lastInsertId().
    var id: i64 = 0;
    if (database.isPostgres()) {
        const ret = try database.dialect().returning(allocator, "id");
        defer allocator.free(ret);
        const sql = try std.fmt.allocPrint(allocator, "INSERT INTO conformance_t (k) VALUES (?){s}", .{ret});
        defer allocator.free(sql);
        var q = try database.prepare(sql);
        defer q.deinit();
        try q.bindText("idrow");
        try testing.expect(try q.step());
        id = q.getInt64(0);
    } else {
        var q = try database.prepare("INSERT INTO conformance_t (k) VALUES (?)");
        defer q.deinit();
        try q.bindText("idrow");
        try q.exec();
        id = database.lastInsertId();
    }
    try testing.expect(id > 0);

    var q = try database.prepare("SELECT k FROM conformance_t WHERE id = ?");
    defer q.deinit();
    try q.bindInt64(id);
    try testing.expect(try q.step());
    try testing.expectEqualStrings("idrow", q.getTextSlice(0).?);
}

test "getText returns owned memory; getTextSlice is borrowed until the next step" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    try createScratch(database);

    try insertRow(database, "o1", "first", 1);
    try insertRow(database, "o2", "second", 2);

    var q = try database.prepare("SELECT t FROM conformance_t ORDER BY n");
    defer q.deinit();
    try testing.expect(try q.step());
    const owned = (try q.getText(0)).?;
    defer testing.allocator.free(owned);
    const borrowed = q.getTextSlice(0).?;
    try testing.expectEqualStrings("first", borrowed);
    try testing.expect(try q.step());
    try testing.expectEqualStrings("second", q.getTextSlice(0).?);
    try testing.expectEqualStrings("first", owned);
}

test "integer extremes and bool coercion round-trip" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    try createScratch(database);

    try insertRow(database, "max", null, std.math.maxInt(i64));
    try insertRow(database, "min", null, std.math.minInt(i64));
    try insertRow(database, "zero", null, 0);
    try insertRow(database, "one", null, 1);

    {
        var q = try database.prepare("SELECT n FROM conformance_t WHERE k = 'max'");
        defer q.deinit();
        try testing.expect(try q.step());
        try testing.expectEqual(@as(i64, std.math.maxInt(i64)), q.getInt64(0));
    }
    {
        var q = try database.prepare("SELECT n FROM conformance_t WHERE k = 'min'");
        defer q.deinit();
        try testing.expect(try q.step());
        try testing.expectEqual(@as(i64, std.math.minInt(i64)), q.getInt64(0));
    }
    {
        var q = try database.prepare("SELECT n FROM conformance_t WHERE k = 'zero'");
        defer q.deinit();
        try testing.expect(try q.step());
        try testing.expect(!q.getBool(0));
        try testing.expectEqual(@as(i32, 0), q.getInt(0));
    }
    {
        var q = try database.prepare("SELECT n FROM conformance_t WHERE k = 'one'");
        defer q.deinit();
        try testing.expect(try q.step());
        try testing.expect(q.getBool(0));
        try testing.expectEqual(@as(i32, 1), q.getInt(0));
    }
}

test "address and hash binders round-trip as lowercase hex text" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    try createScratch(database);

    const addr = helpers.TEST_OWNER_1;
    const hash = helpers.randomHash();
    {
        var q = try database.prepare("INSERT INTO conformance_t (k, t, doc) VALUES (?, ?, ?)");
        defer q.deinit();
        try q.bindText("ah");
        try q.bindAddress(addr);
        try q.bindHash(hash);
        try q.exec();
    }
    var q = try database.prepare("SELECT t, doc FROM conformance_t WHERE k = 'ah'");
    defer q.deinit();
    try testing.expect(try q.step());
    const got_addr = (try q.getAddress(0)).?;
    const got_hash = (try q.getHash(1)).?;
    try testing.expectEqualSlices(u8, &addr.bytes, &got_addr.bytes);
    try testing.expectEqualSlices(u8, &hash.bytes, &got_hash.bytes);
}

test "introspectColumns reports names, declared types, and pk positions" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    try createScratch(database);

    const cols = try database.introspectColumns(allocator, "conformance_t");
    defer backend_mod.freeColumnInfo(allocator, cols);
    try testing.expectEqual(@as(usize, 5), cols.len);

    var saw_id = false;
    var saw_k = false;
    for (cols) |col| {
        try testing.expect(col.sql_type.len > 0);
        if (std.mem.eql(u8, col.name, "id")) {
            saw_id = true;
            try testing.expectEqual(@as(i64, 1), col.pk_pos);
        } else {
            try testing.expectEqual(@as(i64, 0), col.pk_pos);
            if (std.mem.eql(u8, col.name, "k")) saw_k = true;
        }
    }
    try testing.expect(saw_id);
    try testing.expect(saw_k);

    const missing = try database.introspectColumns(allocator, "no_such_table");
    defer backend_mod.freeColumnInfo(allocator, missing);
    try testing.expectEqual(@as(usize, 0), missing.len);
}

test "Tx commit persists; uncommitted Tx rolls back on deinit" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    try createScratch(database);

    {
        var tx = try backend_mod.Tx.begin(database, .immediate);
        defer tx.deinit();
        try insertRow(database, "committed", null, 1);
        try tx.commit();
    }
    {
        var tx = try backend_mod.Tx.begin(database, .deferred);
        defer tx.deinit();
        try insertRow(database, "abandoned", null, 2);
    }
    try testing.expectEqual(@as(i64, 1), try countRows(database, "k = 'committed'"));
    try testing.expectEqual(@as(i64, 0), try countRows(database, "k = 'abandoned'"));
}

test "savepoints nest inside a transaction" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    try createScratch(database);

    var tx = try backend_mod.Tx.begin(database, .immediate);
    defer tx.deinit();
    try insertRow(database, "outer", null, 1);
    try database.exec("SAVEPOINT conformance_sp");
    try insertRow(database, "inner", null, 2);
    try database.exec("ROLLBACK TO conformance_sp");
    try database.exec("RELEASE conformance_sp");
    try tx.commit();

    try testing.expectEqual(@as(i64, 1), try countRows(database, "k = 'outer'"));
    try testing.expectEqual(@as(i64, 0), try countRows(database, "k = 'inner'"));
}

test "exec applies multi-statement batches" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    try createScratch(database);

    try database.exec(
        \\INSERT INTO conformance_t (k, n) VALUES ('m1', 1);
        \\INSERT INTO conformance_t (k, n) VALUES ('m2', 2);
    );
    try testing.expectEqual(@as(i64, 2), try countRows(database, "k IN ('m1', 'm2')"));
}

test "dialect upsert: .replace overwrites, .ignore keeps the existing row" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    try createScratch(database);

    const cols = [_][]const u8{ "k", "t" };
    const conflict = [_][]const u8{"k"};
    const replace_sql = try database.dialect().upsert(allocator, "conformance_t", &cols, &.{}, &conflict, .replace);
    defer allocator.free(replace_sql);
    const ignore_sql = try database.dialect().upsert(allocator, "conformance_t", &cols, &.{}, &conflict, .ignore);
    defer allocator.free(ignore_sql);

    inline for (.{ "v1", "v2" }) |val| {
        var q = try database.prepare(replace_sql);
        defer q.deinit();
        try q.bindText("up");
        try q.bindText(val);
        try q.exec();
    }
    {
        var q = try database.prepare(ignore_sql);
        defer q.deinit();
        try q.bindText("up");
        try q.bindText("v3");
        try q.exec();
    }

    try testing.expectEqual(@as(i64, 1), try countRows(database, "k = 'up'"));
    var q = try database.prepare("SELECT t FROM conformance_t WHERE k = 'up'");
    defer q.deinit();
    try testing.expect(try q.step());
    try testing.expectEqualStrings("v2", q.getTextSlice(0).?);
}

test "dialect insertSelect routes INSERT ... SELECT with a conflict action" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    try createScratch(database);

    try insertRow(database, "src", "copied", 5);

    const cols = [_][]const u8{ "k", "t" };
    const conflict = [_][]const u8{"k"};
    const sql = try database.dialect().insertSelect(
        allocator,
        "conformance_t",
        &cols,
        "SELECT 'dst', t FROM conformance_t WHERE k = 'src'",
        &conflict,
        .ignore,
    );
    defer allocator.free(sql);

    try database.exec(sql);
    try database.exec(sql);

    try testing.expectEqual(@as(i64, 1), try countRows(database, "k = 'dst'"));
    var q = try database.prepare("SELECT t FROM conformance_t WHERE k = 'dst'");
    defer q.deinit();
    try testing.expect(try q.step());
    try testing.expectEqualStrings("copied", q.getTextSlice(0).?);
}

test "dialect returning appends a clause that yields the inserted column" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    try createScratch(database);

    const ret = try database.dialect().returning(allocator, "id");
    defer allocator.free(ret);
    const sql = try std.fmt.allocPrint(allocator, "INSERT INTO conformance_t (k) VALUES (?){s}", .{ret});
    defer allocator.free(sql);

    var q = try database.prepare(sql);
    defer q.deinit();
    try q.bindText("ret");
    try testing.expect(try q.step());
    try testing.expect(q.getInt64(0) > 0);
}

test "dialect json builders round-trip through real SQL" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    try createScratch(database);

    {
        var q = try database.prepare("INSERT INTO conformance_t (k, n, doc) VALUES (?, ?, ?)");
        defer q.deinit();
        try q.bindText("json");
        try q.bindInt64(11);
        try q.bindText(
            \\{"a": 7, "s": "x"}
        );
        try q.exec();
    }

    {
        const obj = try database.dialect().jsonObject(allocator, &.{ "k", "n" }, "c");
        defer allocator.free(obj);
        const sql = try std.fmt.allocPrint(allocator, "SELECT {s} FROM conformance_t c WHERE c.\"k\" = 'json'", .{obj});
        defer allocator.free(sql);
        var q = try database.prepare(sql);
        defer q.deinit();
        try testing.expect(try q.step());
        const json_text = q.getTextSlice(0).?;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings("json", parsed.value.object.get("k").?.string);
        try testing.expectEqual(@as(i64, 11), parsed.value.object.get("n").?.integer);
    }
    {
        const extract_int = try database.dialect().jsonExtract(allocator, "doc", "a", "BIGINT");
        defer allocator.free(extract_int);
        const extract_text = try database.dialect().jsonExtract(allocator, "doc", "s", null);
        defer allocator.free(extract_text);
        const sql = try std.fmt.allocPrint(allocator, "SELECT {s}, {s} FROM conformance_t WHERE k = 'json'", .{ extract_int, extract_text });
        defer allocator.free(sql);
        var q = try database.prepare(sql);
        defer q.deinit();
        try testing.expect(try q.step());
        try testing.expectEqual(@as(i64, 7), q.getInt64(0));
        try testing.expectEqualStrings("x", q.getTextSlice(1).?);
    }
    {
        const sql = try std.fmt.allocPrint(allocator, "SELECT {s}", .{database.dialect().nowEpoch});
        defer allocator.free(sql);
        var q = try database.prepare(sql);
        defer q.deinit();
        try testing.expect(try q.step());
        const epoch = q.getInt64(0);
        try testing.expect(epoch > 1_700_000_000 and epoch < 4_000_000_000);
    }
    {
        const d = database.dialect();
        const sql = try std.fmt.allocPrint(allocator, "SELECT {s}(2, 7), {s}(2, 7)", .{ d.scalar_max, d.scalar_min });
        defer allocator.free(sql);
        var q = try database.prepare(sql);
        defer q.deinit();
        try testing.expect(try q.step());
        try testing.expectEqual(@as(i64, 7), q.getInt64(0));
        try testing.expectEqual(@as(i64, 2), q.getInt64(1));
    }
}

test "placeholders inside string literals are preserved" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    try createScratch(database);

    try insertRow(database, "lit", "?", 1);

    var q = try database.prepare("SELECT t FROM conformance_t WHERE k = ? AND t = '?'");
    defer q.deinit();
    try q.bindText("lit");
    try testing.expect(try q.step());
    try testing.expectEqualStrings("?", q.getTextSlice(0).?);
}

test "prepare of invalid SQL fails with an error, not a crash" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);

    if (database.prepare("SELECT FROM WHERE !!")) |stmt| {
        var q = stmt;
        q.deinit();
        return error.TestUnexpectedResult;
    } else |_| {}

    // The connection must remain usable after a failed prepare.
    var q = try database.prepare("SELECT 1");
    defer q.deinit();
    try testing.expect(try q.step());
    try testing.expectEqual(@as(i64, 1), q.getInt64(0));
}
