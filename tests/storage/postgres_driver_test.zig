//! Live integration tests for the PostgreSQL backend driver
//! (src/storage/drivers/postgres.zig) against the local Postgres. Exercises the
//! `Backend`/`Statement` SPI end-to-end: execRaw, `?`→`$N` prepared statements with
//! sequential binds, row iteration, the OID-dispatching coercing getters, NULL
//! handling, and begin/commit/rollback. Skips if no Postgres is reachable (test-pg
//! lane; start: `sudo pg_ctlcluster 17 main start`).
const std = @import("std");
const testing = std.testing;
const lib = @import("lib");

const pg_driver = lib.storage.postgres;
const models = lib.types.models;
const Address = lib.types.Address;
const Hash = lib.types.Hash;
const namehash = lib.namehash;
const keccak256 = lib.types.keccak256;

fn openBe() !lib.storage.backend.Backend {
    return pg_driver.open(testing.allocator, .{ .database = "ensv2_test", .password = "postgres" });
}

// Load the transpiled Postgres schema into a freshly-cleaned `public` schema.
fn loadPgSchema(be: lib.storage.backend.Backend, a: std.mem.Allocator) !void {
    try be.vtable.execRaw(be.ptr, "DROP SCHEMA public CASCADE; CREATE SCHEMA public");
    const schema_sql = try std.fs.cwd().readFileAlloc(a, "schema/postgres/schema.sql", 1 << 20);
    defer a.free(schema_sql);
    try be.vtable.execRaw(be.ptr, schema_sql);
}

fn makeName(a: std.mem.Allocator, nh: Hash, owner: Address) !models.Name {
    return .{
        .name = try a.dupe(u8, "alice.eth"),
        .namehash = nh,
        .label = try a.dupe(u8, "alice"),
        .label_hash = try keccak256(a, "alice"),
        .parent_name = try a.dupe(u8, "eth"),
        .parent_namehash = try namehash(a, "eth"),
        .protocol = .v2,
        .registry = try Address.fromHex("0x0000000000000000000000000000000000000001"),
        .owner = owner,
        .registrant = owner,
        .resolver = Address.zero,
        .token_id = 42,
        .canonical_id = 0,
        .token_version = 1,
        .expiry = 2000000000,
        .registry_locked = false,
        .migrated = true,
        .created_block = 100,
        .created_at = 1700000100,
        .registered_at = 1700000100,
        .updated_block = 100,
        .updated_at = 1700000100,
        .is_wrapped = true,
        .wrapper_fuses = try a.dupe(u8, "65536"),
        .wrapper_expiry = 2000000001,
        .is_v1_name = false,
        .v1_label_hash = null,
    };
}

test "postgres driver: execRaw + prepared insert/select round-trip + coercing getters + NULL" {
    var be = openBe() catch return error.SkipZigTest;
    defer be.vtable.close(be.ptr);

    try be.vtable.execRaw(be.ptr, "DROP TABLE IF EXISTS drv_probe");
    try be.vtable.execRaw(be.ptr, "CREATE TABLE drv_probe (id BIGINT, label TEXT, flag SMALLINT)");

    // Prepared INSERT: `?` placeholders are renumbered to `$N`; sequential binds.
    {
        var st = try be.vtable.prepare(be.ptr, "INSERT INTO drv_probe (id, label, flag) VALUES (?, ?, ?)", false);
        defer st.deinit();
        try st.bindInt64(99);
        try st.bindText("alpha");
        try st.bindInt(1);
        try st.exec();
    }
    // Second row with a NULL label.
    {
        var st = try be.vtable.prepare(be.ptr, "INSERT INTO drv_probe (id, label, flag) VALUES (?, ?, ?)", false);
        defer st.deinit();
        try st.bindInt64(100);
        try st.bindNull();
        try st.bindInt(0);
        try st.exec();
    }

    // SELECT with a bound param + typed/coercing reads.
    {
        var st = try be.vtable.prepare(be.ptr, "SELECT id, label, flag FROM drv_probe WHERE id = ?", false);
        defer st.deinit();
        try st.bindInt64(99);
        try testing.expect(try st.step());
        try testing.expectEqual(@as(i64, 99), st.getInt64(0)); // int8 → i64
        try testing.expectEqualStrings("alpha", st.getTextSlice(1).?); // text
        try testing.expectEqual(@as(i32, 1), st.getInt(2)); // int2 coerced to i32
        try testing.expect(!try st.step()); // exhausted
    }
    // NULL read.
    {
        var st = try be.vtable.prepare(be.ptr, "SELECT label FROM drv_probe WHERE id = ?", false);
        defer st.deinit();
        try st.bindInt64(100);
        try testing.expect(try st.step());
        try testing.expect(st.isNull(0));
        try testing.expect(st.getTextSlice(0) == null);
    }

    try be.vtable.execRaw(be.ptr, "DROP TABLE drv_probe");
}

test "postgres driver: begin/commit keeps a row, begin/rollback drops one" {
    var be = openBe() catch return error.SkipZigTest;
    defer be.vtable.close(be.ptr);

    try be.vtable.execRaw(be.ptr, "DROP TABLE IF EXISTS drv_tx");
    try be.vtable.execRaw(be.ptr, "CREATE TABLE drv_tx (n bigint)");

    try be.vtable.begin(be.ptr, .deferred);
    try be.vtable.execRaw(be.ptr, "INSERT INTO drv_tx (n) VALUES (1)");
    try be.vtable.commit(be.ptr);

    try be.vtable.begin(be.ptr, .deferred);
    try be.vtable.execRaw(be.ptr, "INSERT INTO drv_tx (n) VALUES (2)");
    be.vtable.rollback(be.ptr);

    var st = try be.vtable.prepare(be.ptr, "SELECT COUNT(*) FROM drv_tx", false);
    defer st.deinit();
    try testing.expect(try st.step());
    try testing.expectEqual(@as(i64, 1), st.getInt64(0)); // only the committed row survives
    try testing.expect(!try st.step()); // step to done so the result is fully drained

    try be.vtable.execRaw(be.ptr, "DROP TABLE drv_tx");
}

// NOTE: introspectColumns (used by the reorg replay path, not core CRUD) is
// implemented but its live test is deferred pending a conn-state/draining
// investigation (the SELECT-then-reuse interaction with the held connection).

// End-to-end: the transpiled Postgres schema (gen_pg_schema.py output) loads into a
// real PostgreSQL, and a PG-dialect ON CONFLICT upsert round-trips on a real ENS table
// through the driver. Proves the schema transpilation is valid PG and the dialect's
// DO UPDATE overwrites (not duplicates) on the actual primary key.
test "postgres: transpiled schema loads + PG-dialect upsert round-trips on sync_state" {
    var be = openBe() catch return error.SkipZigTest;
    defer be.vtable.close(be.ptr);
    const a = testing.allocator;
    const pgd = lib.storage.postgres_dialect.pg_dialect;

    // Clean slate so every CREATE in the schema is actually validated this run.
    try be.vtable.execRaw(be.ptr, "DROP SCHEMA public CASCADE; CREATE SCHEMA public");

    const schema_sql = try std.fs.cwd().readFileAlloc(a, "schema/postgres/schema.sql", 1 << 20);
    defer a.free(schema_sql);
    try be.vtable.execRaw(be.ptr, schema_sql);

    const cols = [_][]const u8{ "protocol", "last_synced_block", "last_synced_at" };
    // Two upserts on the same protocol: the 2nd must overwrite via ON CONFLICT DO UPDATE.
    inline for ([_]i64{ 12345, 99999 }) |block| {
        const sql = try pgd.upsert(a, "sync_state", &cols, &.{}, &.{"protocol"}, .replace);
        defer a.free(sql);
        var st = try be.vtable.prepare(be.ptr, sql, false);
        defer st.deinit();
        try st.bindText("v1");
        try st.bindInt64(block);
        try st.bindInt64(1700000000);
        try st.exec();
    }

    var st = try be.vtable.prepare(be.ptr, "SELECT last_synced_block, (SELECT COUNT(*) FROM sync_state) FROM sync_state WHERE protocol = ?", false);
    defer st.deinit();
    try st.bindText("v1");
    try testing.expect(try st.step());
    try testing.expectEqual(@as(i64, 99999), st.getInt64(0)); // overwritten, not the first value
    try testing.expectEqual(@as(i64, 1), st.getInt64(1)); // exactly one row — no duplicate insert
    try testing.expect(!try st.step());
}

// A/B parity: run the real storage `insertName` (a 33-column ON CONFLICT upsert) +
// `getNameByNamehash` (33-column read via the coercing getters) on a PG-backed
// Database and on SQLite, and assert the round-tripped Name matches across backends.
// This exercises the driver + dialect + coercing getters on the real `names` table.
test "postgres A/B: insertName round-trips on PG identically to SQLite" {
    const a = testing.allocator;
    const nh = try namehash(a, "alice.eth");
    const owner = try Address.fromHex("0x00000000000000000000000000000000000000aa");

    var n = try makeName(a, nh, owner);
    defer n.deinit(a);

    // PG-backed Database (constructed directly over a pre-opened backend + loaded schema).
    const pg_be = openBe() catch return error.SkipZigTest;
    var pgdb = lib.Database{ .allocator = a, .backend = pg_be };
    defer pgdb.deinit(); // closes the backend (releases conn + deinits pool)
    try loadPgSchema(pg_be, a);
    try pgdb.insertName(n);
    var pg_name = (try pgdb.getNameByNamehash(nh)) orelse return error.PgNameNotFound;
    defer pg_name.deinit(a);

    // SQLite baseline.
    var sqdb = try lib.Database.init(a, ":memory:");
    defer sqdb.deinit();
    try sqdb.insertName(n);
    var sq_name = (try sqdb.getNameByNamehash(nh)) orelse return error.SqNameNotFound;
    defer sq_name.deinit(a);

    // The round-tripped Name must be identical across backends (key fields spanning
    // TEXT, BIGINT, SMALLINT/bool, u256-as-text, and a nullable BIGINT).
    try testing.expectEqualStrings(sq_name.name.?, pg_name.name.?);
    try testing.expectEqualStrings(sq_name.label.?, pg_name.label.?);
    try testing.expect(sq_name.protocol == pg_name.protocol);
    try testing.expectEqualSlices(u8, &sq_name.owner.bytes, &pg_name.owner.bytes);
    try testing.expectEqual(sq_name.token_id, pg_name.token_id); // u256 via TEXT hex
    try testing.expectEqual(sq_name.expiry, pg_name.expiry); // u64 -> BIGINT
    try testing.expectEqual(sq_name.created_block, pg_name.created_block);
    try testing.expectEqual(sq_name.is_wrapped, pg_name.is_wrapped); // bool <- SMALLINT
    try testing.expectEqual(sq_name.migrated, pg_name.migrated);
    try testing.expectEqual(sq_name.wrapper_expiry, pg_name.wrapper_expiry); // ?i64
    try testing.expectEqual(sq_name.is_normalized, pg_name.is_normalized);
    std.debug.print("✓ insertName round-trips identically on PG and SQLite\n", .{});
}
