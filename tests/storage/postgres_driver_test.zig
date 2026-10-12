//! Live integration tests for the PostgreSQL backend driver
//! (src/storage/drivers/postgres.zig) against the local Postgres. Exercises the
//! `Backend`/`Statement` SPI end-to-end: execRaw, `?`→`$N` prepared statements with
//! sequential binds, row iteration, the OID-dispatching coercing getters, NULL
//! handling, and begin/commit/rollback. Skips if no Postgres is reachable (test-pg
//! lane; start: `sudo pg_ctlcluster 17 main start`).
const std = @import("std");
const zsys = @import("lib").zsys;
const testing = std.testing;
const lib = @import("lib");

const pg_driver = lib.storage.postgres;
const db_open = lib.storage.db_open;
const config = lib.config;
const contracts = lib.contracts;
const models = lib.types.models;
const Address = lib.types.Address;
const Hash = lib.types.Hash;
const namehash = lib.namehash;
const keccak256 = lib.types.keccak256;

const PG_TEST_URL = "postgres://postgres:postgres@127.0.0.1:5432/ensv2_test";

// A Config wired for Postgres against the local test DB. String fields are static
// literals, so callers must NOT call cfg.deinit() (it would free literals).
fn pgTestConfig() !config.Config {
    const net = contracts.Network.sepolia;
    const addrs = try contracts.getContractAddresses(net);
    return .{
        .allocator = testing.allocator,
        .rpc_url = "http://localhost:8545",
        .database_path = ":memory:",
        .backend_kind = .postgres,
        .database_url = PG_TEST_URL,
        .database_pool_size = 10,
        .network = net,
        .start_block = 0,
        .end_block = null,
        .poll_interval = 12,
        .batch_size = 2000,
        .rate_limit_per_second = 15,
        .rpc_rate_limit_per_second = 15,
        .trusted_proxy_hops = 0,
        .request_timeout_ms = 10000,
        .max_concurrent_connections = 512,
        .api_port = 8080,
        .api_enabled = false,
        .status_port = null,
        .webhooks_enabled = false,
        .webhook_max_retries = 3,
        .webhook_db_path = ":memory:",
        .webhook_admin_username = null,
        .webhook_admin_password = null,
        .webhooks_allow_unauthenticated = false,
        .internal_admin_token = null,
        .internal_rate_limit_per_second = 2,
        .checkpoint_interval = 100,
        .graphql_max_depth = 10,
        .graphql_max_cost = 10000,
        .metrics_enabled = false,
        .rainbow_path = "",
        .v1_contracts = addrs,
        .v2_contracts = addrs,
        .resolve_rpc_url = "http://localhost:8545",
        .resolve_cache_ttl_s = 300,
        .primary_verify_enabled = false,
        .resolve_live_enabled = false,
        .resolve_universal_resolver = Address.zero,
        .resolve_ccip_enabled = false,
        .ccip_gateway_timeout_ms = 5000,
        .ccip_max_redirects = 4,
        .finality_enabled = false,
        .coverage_stale_after_seconds = 0,
    };
}

fn openBe() !lib.storage.backend.Backend {
    return pg_driver.open(testing.allocator, .{ .database = "ensv2_test", .password = "postgres" });
}

// Load the transpiled Postgres schema into a freshly-cleaned `public` schema.
fn loadPgSchema(be: lib.storage.backend.Backend, a: std.mem.Allocator) !void {
    try be.vtable.execRaw(be.ptr, "DROP SCHEMA public CASCADE; CREATE SCHEMA public");
    const schema_sql = try zsys.readFileAlloc(a, "schema/postgres/schema.sql", 1 << 20);
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

// Regression: a statement whose execute() fails server-side (here a duplicate-PK
// unique violation, which surfaces at Execute, not Parse) must still free its pg.Stmt
// arena on deinit. Runs under testing.allocator, so a leak fails the test. Also asserts
// the pinned connection recovers (a later execRaw succeeds) after the failed execute.
test "postgres driver: failed execute frees the statement and leaves the connection usable" {
    var be = openBe() catch return error.SkipZigTest;
    defer be.vtable.close(be.ptr);

    try be.vtable.execRaw(be.ptr, "DROP TABLE IF EXISTS drv_fail");
    try be.vtable.execRaw(be.ptr, "CREATE TABLE drv_fail (n int PRIMARY KEY)");
    try be.vtable.execRaw(be.ptr, "INSERT INTO drv_fail (n) VALUES (1)");

    {
        var st = try be.vtable.prepare(be.ptr, "INSERT INTO drv_fail (n) VALUES (?)", false);
        defer st.deinit(); // must free the Stmt arena even though execute() errored
        try st.bindInt(1); // duplicate PK
        // Call the raw vtable exec (returns false, records to a buffer) rather than
        // Statement.exec(), whose std.log.err on failure would trip the test runner.
        try testing.expect(!st.vtable.exec(st.ctx));
        // lastError() must surface the real Postgres error (SQLSTATE + message), not a
        // placeholder — this is what the storage-layer logs print in production.
        const errmsg = st.vtable.lastError(st.ctx);
        try testing.expect(std.mem.indexOf(u8, errmsg, "23505") != null);
        try testing.expect(std.mem.indexOf(u8, errmsg, "duplicate key") != null);
    }

    // Connection recovered (peekForError consumed ReadyForQuery): a fresh op works.
    try be.vtable.execRaw(be.ptr, "DROP TABLE drv_fail");
}

// Finding D: exec() captures the CommandComplete affected-row count (changes()), and the
// manual drain leaves the pinned connection clean for the next statement. Covers the
// distinct counts the storage layer depends on — including the 0-rows case that
// registrations.zig gates control flow on (`if changes() == 0`).
test "postgres driver: exec captures affected-row count (changes) and leaves conn clean" {
    var be = openBe() catch return error.SkipZigTest;
    defer be.vtable.close(be.ptr);

    try be.vtable.execRaw(be.ptr, "DROP TABLE IF EXISTS drv_cnt");
    try be.vtable.execRaw(be.ptr, "CREATE TABLE drv_cnt (id INT PRIMARY KEY, v INT)");

    // INSERT 3 rows → "INSERT 0 3".
    {
        var st = try be.vtable.prepare(be.ptr, "INSERT INTO drv_cnt (id, v) VALUES (1,10),(2,10),(3,20)", false);
        defer st.deinit();
        try st.exec();
        try testing.expectEqual(@as(u32, 3), st.changes());
    }
    // UPDATE 2 matching rows.
    {
        var st = try be.vtable.prepare(be.ptr, "UPDATE drv_cnt SET v = 99 WHERE v = ?", false);
        defer st.deinit();
        try st.bindInt(10);
        try st.exec();
        try testing.expectEqual(@as(u32, 2), st.changes());
    }
    // UPDATE matching 0 rows — the control-flow case (registrations.zig `== 0`).
    {
        var st = try be.vtable.prepare(be.ptr, "UPDATE drv_cnt SET v = 1 WHERE v = ?", false);
        defer st.deinit();
        try st.bindInt(12345);
        try st.exec();
        try testing.expectEqual(@as(u32, 0), st.changes());
    }
    // DELETE 1 row.
    {
        var st = try be.vtable.prepare(be.ptr, "DELETE FROM drv_cnt WHERE id = ?", false);
        defer st.deinit();
        try st.bindInt(3);
        try st.exec();
        try testing.expectEqual(@as(u32, 1), st.changes());
    }
    // Connection is clean after the drains: a SELECT reads the expected surviving count.
    {
        var st = try be.vtable.prepare(be.ptr, "SELECT COUNT(*) FROM drv_cnt", false);
        defer st.deinit();
        try testing.expect(try st.step());
        try testing.expectEqual(@as(i64, 2), st.getInt64(0)); // 3 inserted − 1 deleted
        try testing.expect(!try st.step());
    }

    try be.vtable.execRaw(be.ptr, "DROP TABLE drv_cnt");
}

// introspectColumns (used by the dialect-agnostic hasTable + the SQLite reorg
// trigger generator) against live PG. The information_schema columns are domain
// types, so the driver casts column_name/data_type to ::text and the PK position to
// ::bigint to match pg.zig's OID-strict native getters. A missing table yields an
// empty slice — the contract Database.hasTable relies on for its "absent" path.
test "postgres driver: introspectColumns returns columns + PK, empty for missing table" {
    var be = openBe() catch return error.SkipZigTest;
    defer be.vtable.close(be.ptr);
    const a = testing.allocator;

    try be.vtable.execRaw(be.ptr, "DROP TABLE IF EXISTS drv_cols");
    try be.vtable.execRaw(be.ptr, "CREATE TABLE drv_cols (namehash TEXT PRIMARY KEY, label TEXT, expiry BIGINT)");

    const cols = try be.vtable.introspectColumns(be.ptr, a, "drv_cols");
    defer lib.storage.backend.freeColumnInfo(a, cols);
    try testing.expectEqual(@as(usize, 3), cols.len);
    try testing.expectEqualStrings("namehash", cols[0].name);
    try testing.expectEqual(@as(i64, 1), cols[0].pk_pos); // PK column → ordinal 1
    try testing.expectEqualStrings("label", cols[1].name);
    try testing.expectEqual(@as(i64, 0), cols[1].pk_pos); // non-PK → 0

    const none = try be.vtable.introspectColumns(be.ptr, a, "table_that_does_not_exist");
    defer lib.storage.backend.freeColumnInfo(a, none);
    try testing.expectEqual(@as(usize, 0), none.len);

    try be.vtable.execRaw(be.ptr, "DROP TABLE drv_cols");
}

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

    const schema_sql = try zsys.readFileAlloc(a, "schema/postgres/schema.sql", 1 << 20);
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

// Headline test for Database.initWithBackend on Postgres: the SAME bootstrap path
// init() uses for SQLite, driven over the PG backend. Proves end-to-end that
//   (1) loadSchemaFiles picks schema/postgres/ and applies it,
//   (2) migrate() runs cleanly on PG (root insert via the dialect upsert; the SQLite-only
//       in-place ALTER/columnExists steps are skipped, not errored),
//   (3) reorg_undo.ensureSchema creates the BIGSERIAL undo tables and installTriggers
//       installs the generated PL/pgSQL capture functions + per-table triggers,
//   (4) those triggers actually FIRE — the first execution of the generated Postgres
//       trigger DDL against a live database (previously only string-generated/unit-tested).
test "postgres initWithBackend: full bootstrap + reorg triggers capture a names UPDATE" {
    const a = testing.allocator;
    // Clean slate so initWithBackend runs the full schema-load + migrate + reorg install.
    {
        var raw = openBe() catch return error.SkipZigTest;
        defer raw.vtable.close(raw.ptr);
        try raw.vtable.execRaw(raw.ptr, "DROP SCHEMA public CASCADE; CREATE SCHEMA public");
    }

    const be = openBe() catch return error.SkipZigTest;
    var db = try lib.Database.initWithBackend(a, be);
    defer db.deinit();

    // (1)+(2): schema applied and migrate ran — the real 33-column insertName upsert works.
    const nh = try namehash(a, "alice.eth");
    const owner = try Address.fromHex("0x00000000000000000000000000000000000000bb");
    var n = try makeName(a, nh, owner);
    defer n.deinit(a);
    try db.insertName(n);
    {
        var got = (try db.getNameByNamehash(nh)) orelse return error.NameNotFound;
        got.deinit(a);
    }

    // (3)+(4): arm the v2 cursor, then UPDATE the alice row. The generated AFTER UPDATE
    // trigger must snapshot OLD into reorg_undo (gated on reorg_cursor for OLD.protocol).
    try lib.storage.reorg_undo.setCursor(&db, .v2, 200);
    try db.exec("UPDATE names SET owner = '0x00000000000000000000000000000000000000cc' WHERE label = 'alice'");

    {
        var st = try db.backend.vtable.prepare(db.backend.ptr, "SELECT table_name, op, old_row FROM reorg_undo WHERE protocol = ?", false);
        defer st.deinit();
        try st.bindText("v2");
        try testing.expect(try st.step());
        try testing.expectEqualStrings("names", st.getTextSlice(0).?);
        try testing.expectEqualStrings("U", st.getTextSlice(1).?); // LEFT(TG_OP,1) ⇒ 'U'
        // to_jsonb(OLD) snapshot holds the real pre-update row (contains the label).
        try testing.expect(std.mem.indexOf(u8, st.getTextSlice(2).?, "alice") != null);
        try testing.expect(!try st.step()); // exactly one capture row, fully drained
    }

    // The UPDATE itself applied (owner is now cc); the OLD value lives only in reorg_undo.
    var after = (try db.getNameByNamehash(nh)) orelse return error.NameNotFound2;
    defer after.deinit(a);
    const cc = try Address.fromHex("0x00000000000000000000000000000000000000cc");
    try testing.expectEqualSlices(u8, &cc.bytes, &after.owner.bytes);

    std.debug.print("✓ initWithBackend bootstrapped PG + reorg triggers captured a names UPDATE\n", .{});
}

// parseUrl is pure (no connection): borrows slices from the URL into ConnectOpts.
test "postgres parseUrl: full, scheme variants, defaults, and errors" {
    // Full URL: user, password, host, port, db.
    {
        const o = try pg_driver.parseUrl("postgres://alice:s3cret@db.example.com:6543/ens");
        try testing.expectEqualStrings("db.example.com", o.host);
        try testing.expectEqual(@as(u16, 6543), o.port);
        try testing.expectEqualStrings("alice", o.username);
        try testing.expectEqualStrings("s3cret", o.password.?);
        try testing.expectEqualStrings("ens", o.database);
    }
    // postgresql:// scheme; no userinfo → username default, no password; default port.
    {
        const o = try pg_driver.parseUrl("postgresql://localhost/mydb");
        try testing.expectEqualStrings("localhost", o.host);
        try testing.expectEqual(@as(u16, 5432), o.port);
        try testing.expectEqualStrings("postgres", o.username); // ConnectOpts default
        try testing.expect(o.password == null);
        try testing.expectEqualStrings("mydb", o.database);
    }
    // User without password; query string trimmed off the database.
    {
        const o = try pg_driver.parseUrl("postgres://svc@10.0.0.5/appdb?sslmode=disable");
        try testing.expectEqualStrings("svc", o.username);
        try testing.expect(o.password == null);
        try testing.expectEqualStrings("appdb", o.database);
        try testing.expectEqualStrings("10.0.0.5", o.host);
    }
    // Password may contain ':' — userinfo splits on the FIRST ':' (username can't contain one).
    {
        const o = try pg_driver.parseUrl("postgres://u:pa:ss@h/db");
        try testing.expectEqualStrings("u", o.username);
        try testing.expectEqualStrings("pa:ss", o.password.?);
        try testing.expectEqualStrings("h", o.host);
    }
    // Password may contain '@' — authority splits on the LAST '@'.
    {
        const o = try pg_driver.parseUrl("postgres://u:p@ss@h:5432/db");
        try testing.expectEqualStrings("u", o.username);
        try testing.expectEqualStrings("p@ss", o.password.?);
        try testing.expectEqualStrings("h", o.host);
        try testing.expectEqual(@as(u16, 5432), o.port);
    }
    // Empty authority → host falls back to the ConnectOpts default.
    {
        const o = try pg_driver.parseUrl("postgres:///db");
        try testing.expectEqualStrings("127.0.0.1", o.host);
        try testing.expectEqualStrings("db", o.database);
    }
    // Errors.
    try testing.expectError(error.InvalidPostgresUrl, pg_driver.parseUrl("mysql://x/y"));
    try testing.expectError(error.MissingDatabase, pg_driver.parseUrl("postgres://host:5432"));
    try testing.expectError(error.MissingDatabase, pg_driver.parseUrl("postgres://host:5432/"));
    try testing.expectError(error.InvalidPort, pg_driver.parseUrl("postgres://host:notaport/db"));
    try testing.expectError(error.InvalidPort, pg_driver.parseUrl("postgres://host:99999/db")); // > u16 max
}

// selectBackend dispatches on the kind: SQLite opens the path, Postgres parses the URL.
test "postgres selectBackend: sqlite + postgres dispatch, and missing-URL error" {
    // SQLite path → qmark dialect, no PG needed.
    {
        var be = try db_open.selectBackend(testing.allocator, .sqlite, ":memory:", null);
        defer be.vtable.close(be.ptr);
        try testing.expect(be.dialect.placeholder == .qmark);
    }
    // Postgres without a URL is an error (no silent fallback to SQLite).
    try testing.expectError(error.MissingDatabaseUrl, db_open.selectBackend(testing.allocator, .postgres, ":memory:", null));

    // Postgres path → dollar dialect + a live round-trip.
    {
        var be = db_open.selectBackend(testing.allocator, .postgres, ":memory:", PG_TEST_URL) catch return error.SkipZigTest;
        defer be.vtable.close(be.ptr);
        try testing.expect(be.dialect.placeholder == .dollar);
        var st = try be.vtable.prepare(be.ptr, "SELECT 1", false);
        defer st.deinit();
        try testing.expect(try st.step());
        try testing.expectEqual(@as(i64, 1), st.getInt64(0));
    }
}

// End-to-end: a Postgres-configured Config drives openFromConfig through selectBackend +
// the shared initWithBackend bootstrap to a working Database (insertName round-trip).
test "postgres openFromConfig: Config(postgres) → bootstrapped Database" {
    const a = testing.allocator;
    // Clean slate on a throwaway connection so openFromConfig loads the schema fresh.
    {
        var raw = openBe() catch return error.SkipZigTest;
        defer raw.vtable.close(raw.ptr);
        try raw.vtable.execRaw(raw.ptr, "DROP SCHEMA public CASCADE; CREATE SCHEMA public");
    }

    const cfg = pgTestConfig() catch return error.SkipZigTest;
    var db = db_open.openFromConfig(a, cfg) catch return error.SkipZigTest;
    defer db.deinit();
    try testing.expect(db.isPostgres());

    const nh = try namehash(a, "alice.eth");
    const owner = try Address.fromHex("0x00000000000000000000000000000000000000bb");
    var n = try makeName(a, nh, owner);
    defer n.deinit(a);
    try db.insertName(n);
    var got = (try db.getNameByNamehash(nh)) orelse return error.NameNotFound;
    defer got.deinit(a);
    try testing.expectEqualStrings("alice.eth", got.name.?);

    std.debug.print("✓ openFromConfig(Config postgres) bootstrapped a working PG Database\n", .{});
}

// The API's read path: openFromConfigReadonly connects to an already-bootstrapped PG DB
// WITHOUT running schema/migrate (mirrors initWithoutSchema), and the dialect-aware
// checkIntegrity (PG → SELECT 1) works. Writer bootstraps + inserts; a second read-only
// handle reads it back.
test "postgres openFromConfigReadonly: connects without bootstrap, checkIntegrity + read work" {
    const a = testing.allocator;
    const cfg = pgTestConfig() catch return error.SkipZigTest;
    const nh = try namehash(a, "alice.eth");

    // Writer: bootstrap (fresh schema) + insert one name, then close.
    {
        var raw = openBe() catch return error.SkipZigTest;
        defer raw.vtable.close(raw.ptr);
        try raw.vtable.execRaw(raw.ptr, "DROP SCHEMA public CASCADE; CREATE SCHEMA public");
    }
    {
        var w = db_open.openFromConfig(a, cfg) catch return error.SkipZigTest;
        defer w.deinit();
        var n = try makeName(a, nh, try Address.fromHex("0x00000000000000000000000000000000000000bb"));
        defer n.deinit(a);
        try w.insertName(n);
    }

    // Read-only open: no bootstrap, integrity probe + read succeed against the live PG.
    var ro = try db_open.openFromConfigReadonly(a, cfg);
    defer ro.deinit();
    try testing.expect(try ro.checkIntegrity()); // PG path: SELECT 1
    var got = (try ro.getNameByNamehash(nh)) orelse return error.NameNotFound;
    defer got.deinit(a);
    try testing.expectEqualStrings("alice.eth", got.name.?);

    std.debug.print("✓ openFromConfigReadonly read an existing PG row without bootstrapping\n", .{});
}

// Finding A regression: a protected row DELETEd then re-INSERTed under the SAME business
// key within a reorg window. The live row now carries the business key under a FRESH
// surrogate id; replayUndo's restore must conflict on the business UNIQUE (protocol,
// namehash) — not the synthetic id — or Postgres raises a unique_violation that
// `ON CONFLICT (id)` can't catch and ABORTS the rollback (where SQLite's INSERT OR
// REPLACE recovers). Proves the rollback succeeds and restores the pre-reorg row (incl id).
test "postgres reorg: delete-then-reinsert-same-key rolls back without aborting (Finding A)" {
    const a = testing.allocator;
    const reorg = lib.storage.reorg_undo;

    {
        var raw = openBe() catch return error.SkipZigTest;
        defer raw.vtable.close(raw.ptr);
        try raw.vtable.execRaw(raw.ptr, "DROP SCHEMA public CASCADE; CREATE SCHEMA public");
    }
    const cfg = pgTestConfig() catch return error.SkipZigTest;
    var db = db_open.openFromConfig(a, cfg) catch return error.SkipZigTest;
    defer db.deinit();

    const nh = try namehash(a, "alice.eth");
    const owner_x = try Address.fromHex("0x00000000000000000000000000000000000000bb");
    const owner_y = try Address.fromHex("0x00000000000000000000000000000000000000cc");

    // Pre-reorg state (no cursor → not captured): insert alice with owner X; record its id.
    var n = try makeName(a, nh, owner_x);
    defer n.deinit(a);
    try db.insertName(n);
    const id_before = try selectAliceId(&db);

    // Arm capture at block 100, then DELETE alice (captures op D of the owner-X row) and
    // re-INSERT the same (protocol, namehash) with owner Y — a brand-new surrogate id,
    // NOT captured (protected tables don't capture INSERT).
    try reorg.setCursor(&db, .v2, 100);
    try db.exec("DELETE FROM names WHERE label = 'alice'");
    n.owner = owner_y;
    try db.insertName(n);
    const id_reinserted = try selectAliceId(&db);
    try testing.expect(id_reinserted != id_before); // fresh surrogate id

    // Roll back everything after block 99. The restore conflicts on (protocol, namehash):
    // it must NOT abort, and must bring the row back to its pre-reorg state.
    try reorg.clearCursor(&db, .v2);
    try reorg.replayUndo(&db, .v2, 99);

    var got = (try db.getNameByNamehash(nh)) orelse return error.NameNotFound;
    defer got.deinit(a);
    try testing.expectEqualSlices(u8, &owner_x.bytes, &got.owner.bytes); // restored OLD owner
    try testing.expectEqual(id_before, try selectAliceId(&db)); // restored OLD surrogate id

    std.debug.print("✓ reorg delete+reinsert-same-key rolled back cleanly on PG (Finding A fixed)\n", .{});
}

fn selectAliceId(db: *lib.Database) !i64 {
    var st = try db.backend.vtable.prepare(db.backend.ptr, "SELECT id FROM names WHERE label = 'alice'", false);
    defer st.deinit();
    if (!try st.step()) return error.AliceMissing;
    return st.getInt64(0);
}

// ── URL / TLS parsing (pure — no live connection; Neon TLS support) ───────────

test "postgres driver: tlsModeFromSslmode maps libpq sslmode values" {
    const TlsMode = pg_driver.TlsMode;
    try testing.expectEqual(TlsMode.off, pg_driver.tlsModeFromSslmode(null));
    try testing.expectEqual(TlsMode.off, pg_driver.tlsModeFromSslmode("disable"));
    try testing.expectEqual(TlsMode.off, pg_driver.tlsModeFromSslmode("prefer"));
    try testing.expectEqual(TlsMode.require, pg_driver.tlsModeFromSslmode("require"));
    try testing.expectEqual(TlsMode.require, pg_driver.tlsModeFromSslmode("REQUIRE")); // case-insensitive
    try testing.expectEqual(TlsMode.verify_full, pg_driver.tlsModeFromSslmode("verify-ca"));
    try testing.expectEqual(TlsMode.verify_full, pg_driver.tlsModeFromSslmode("verify-full"));
    try testing.expectEqual(TlsMode.require, pg_driver.tlsModeFromSslmode("bogus")); // unknown → fail-safe encrypt
}

test "postgres driver: parseUrl extracts sslmode, host, port (Neon-style + local)" {
    const TlsMode = pg_driver.TlsMode;
    // Neon-style: TLS required, host carries the cert SNI, extra query params ignored.
    const neon = try pg_driver.parseUrl("postgresql://u:p@ep-cool-snow-123.us-east-2.aws.neon.tech/neondb?sslmode=require&channel_binding=require");
    try testing.expectEqualStrings("ep-cool-snow-123.us-east-2.aws.neon.tech", neon.host);
    try testing.expectEqualStrings("neondb", neon.database);
    try testing.expectEqualStrings("u", neon.username);
    try testing.expectEqualStrings("p", neon.password.?);
    try testing.expectEqual(@as(u16, 5432), neon.port);
    try testing.expectEqual(TlsMode.require, neon.tls);

    // verify-full → verify against system CAs.
    const vf = try pg_driver.parseUrl("postgres://u:p@host.example/db?sslmode=verify-full");
    try testing.expectEqual(TlsMode.verify_full, vf.tls);

    // Local non-TLS Postgres: no sslmode → TLS off; explicit port honored.
    const local = try pg_driver.parseUrl("postgres://postgres:postgres@127.0.0.1:5433/ensv2_test");
    try testing.expectEqual(TlsMode.off, local.tls);
    try testing.expectEqual(@as(u16, 5433), local.port);
    try testing.expectEqualStrings("127.0.0.1", local.host);
}

// ── #3 server-side statement lifetime: the driver sends each statement as one
// Parse+Bind+Describe+Execute+Sync group, so pg_prepared_statements must stay EMPTY no
// matter how many statements run, or which `cached` flag the caller passes. ──
// Count the server-side prepared statements THIS session holds. pg_prepared_statements is
// session-scoped, so this sees exactly what the driver left behind on its own connection.
// The driver sends every statement as one Parse+Bind+Describe+Execute+Sync group over the
// UNNAMED statement, so the answer must always be zero: nothing it creates outlives the
// group, which is why it is correct behind a transaction-mode pooler without any pooler
// configuration.
fn countPreparedStmts(be: lib.storage.backend.Backend) !i64 {
    var st = try be.vtable.prepare(be.ptr, "SELECT count(*) FROM pg_prepared_statements", false);
    defer st.deinit();
    try testing.expect(try st.step());
    return st.getInt64(0);
}

test "postgres driver: no server-side statement outlives a query" {
    var be = openBe() catch return error.SkipZigTest;
    defer be.vtable.close(be.ptr);
    try be.vtable.execRaw(be.ptr, "DROP TABLE IF EXISTS cache_probe");
    try be.vtable.execRaw(be.ptr, "CREATE TABLE cache_probe (id BIGINT, v TEXT)");
    try be.vtable.execRaw(be.ptr, "INSERT INTO cache_probe (id, v) VALUES (1, 'a')");
    try be.vtable.execRaw(be.ptr, "INSERT INTO cache_probe (id, v) VALUES (2, 'b')");

    try testing.expectEqual(@as(i64, 0), try countPreparedStmts(be));
    const sel = "SELECT v FROM cache_probe WHERE id = ?";

    // Run the same SQL repeatedly, both prepare flavours. Correct rows every time, and
    // never a server-side statement left behind — with the old named-statement cache this
    // count grew, and behind a pooler those names were what broke.
    for (0..40) |i| {
        const cached = i % 2 == 0;
        {
            var st = try be.vtable.prepare(be.ptr, sel, cached);
            defer st.deinit();
            try st.bindInt64(1);
            try testing.expect(try st.step());
            try testing.expectEqualStrings("a", st.getTextSlice(0).?);
        }
        {
            var st = try be.vtable.prepare(be.ptr, sel, cached);
            defer st.deinit();
            try st.bindInt64(2);
            try testing.expect(try st.step());
            try testing.expectEqualStrings("b", st.getTextSlice(0).?);
        }
    }
    try testing.expectEqual(@as(i64, 0), try countPreparedStmts(be));

    // Connection still healthy for a parameterless statement.
    {
        var st = try be.vtable.prepare(be.ptr, "SELECT 1", false);
        defer st.deinit();
        try testing.expect(try st.step());
        try testing.expectEqual(@as(i64, 1), st.getInt64(0));
    }

    try be.vtable.execRaw(be.ptr, "DROP TABLE cache_probe");
}

test "postgres driver: pinned connection revives after server-side termination" {
    var be = openBe() catch return error.SkipZigTest;
    defer be.vtable.close(be.ptr);

    // Healthy baseline through the prepared path.
    {
        var st = try be.vtable.prepare(be.ptr, "SELECT 1", false);
        defer st.deinit();
        try testing.expect(try st.step());
    }

    // Kill our own server session (what Neon does on idle timeout / restart).
    // The terminate statement itself may succeed or fail depending on how fast
    // the server drops the socket — either way the pinned connection is dead.
    {
        var st = be.vtable.prepare(be.ptr, "SELECT pg_terminate_backend(pg_backend_pid())", false) catch return;
        defer st.deinit();
        // Raw vtable step: the statement is EXPECTED to fail as the server
        // drops the session (SQLSTATE 57P01) — the Statement wrapper would
        // err-log that, which the test runner treats as a failure.
        _ = st.vtable.step(st.ctx);
    }

    // The next prepare observes the dead socket, fails, and — the fix —
    // replaces the pinned connection. Pre-fix, this NEVER recovered: every
    // statement failed on the same corpse forever (the staging
    // SSLWriteFailed loop). A couple of attempts absorb teardown races.
    var recovered = false;
    var attempt: usize = 0;
    while (attempt < 5) : (attempt += 1) {
        var st = be.vtable.prepare(be.ptr, "SELECT 1", false) catch continue;
        defer st.deinit();
        if (st.vtable.step(st.ctx) == .row) {
            recovered = true;
            break;
        }
    }
    try testing.expect(recovered);
}

// NOTE on what is NOT tested here: two statements prepared and left UNEXECUTED on one
// connection at the same time. That cannot work in this driver whatever the statements are
// named, because pg.Stmt borrows connection-level scratch (`conn._buf`, `conn._param_oids`,
// `conn._result_state`), so the second Parse overwrites the first's describe state. The
// production failure this naming change fixes was never that: it was the same collision
// ACROSS clients sharing one backend through a transaction-mode pooler, where those
// per-connection buffers are not shared. That is covered by a measured load run (176 of
// 320 concurrent API requests failed before, 0 after), not by a unit test — a single
// connection cannot reproduce it.

// A statement's whole lifecycle — Parse, Bind, Describe, Execute — rides in one message
// group over the unnamed statement, so running many of them must not accumulate anything
// on the server. This is the property that makes the driver pooler-agnostic; if someone
// reintroduces a named/cached statement, this count stops being zero.
test "postgres driver: many statements leave nothing on the server" {
    var be = openBe() catch return error.SkipZigTest;
    defer be.vtable.close(be.ptr);

    for (0..200) |i| {
        var st = try be.vtable.prepare(be.ptr, "SELECT ?::bigint AS v", false);
        defer st.deinit();
        try st.bindInt64(@intCast(i));
        try testing.expect(try st.step());
        try testing.expectEqual(@as(i64, @intCast(i)), st.getInt64(0));
    }

    try testing.expectEqual(@as(i64, 0), try countPreparedStmts(be));
}

// Two statements open at once on ONE connection, with different parameter counts. This
// could not work before: a statement held pg.Stmt state borrowed from the connection
// (its buffer, parameter OIDs and result state), so preparing the second clobbered the
// first's describe data. Now prepare() touches neither the socket nor any shared state —
// the whole lifecycle travels in one group at step() — so independent statements simply
// do not interact. Guards the property that made the old design fragile.
test "postgres driver: two statements can be open at once" {
    var be = openBe() catch return error.SkipZigTest;
    defer be.vtable.close(be.ptr);

    var a = try be.vtable.prepare(be.ptr, "SELECT ?::bigint AS v", false);
    defer a.deinit();
    var b = try be.vtable.prepare(be.ptr, "SELECT ?::bigint + ?::bigint + ?::bigint AS v", false);
    defer b.deinit();

    // Execute the SECOND one first, then the first: interleaved in both directions.
    try b.bindInt64(1);
    try b.bindInt64(2);
    try b.bindInt64(4);
    try testing.expect(try b.step());
    try testing.expectEqual(@as(i64, 7), b.getInt64(0));

    try a.bindInt64(42);
    try testing.expect(try a.step());
    try testing.expectEqual(@as(i64, 42), a.getInt64(0));

    try testing.expectEqual(@as(i64, 0), try countPreparedStmts(be));
}

// changes() comes from the CommandComplete tag. The affected-row count has to survive a
// RETURNING clause (where the reply also carries a RowDescription and DataRows) and an
// ON CONFLICT DO NOTHING that writes nothing — the storage layer branches on both.
test "postgres driver: changes() is exact for RETURNING and for a no-op upsert" {
    var be = openBe() catch return error.SkipZigTest;
    defer be.vtable.close(be.ptr);

    try be.vtable.execRaw(be.ptr, "DROP TABLE IF EXISTS chg_probe");
    try be.vtable.execRaw(be.ptr, "CREATE TABLE chg_probe (id BIGINT PRIMARY KEY, v TEXT)");

    { // INSERT ... RETURNING: one row written, one row returned
        var st = try be.vtable.prepare(be.ptr, "INSERT INTO chg_probe (id, v) VALUES (?, ?) RETURNING id", false);
        defer st.deinit();
        try st.bindInt64(1);
        try st.bindText("a");
        try st.exec();
        try testing.expectEqual(@as(u32, 1), st.changes());
    }
    { // ON CONFLICT DO NOTHING on an existing key: nothing written
        var st = try be.vtable.prepare(be.ptr, "INSERT INTO chg_probe (id, v) VALUES (?, ?) ON CONFLICT (id) DO NOTHING", false);
        defer st.deinit();
        try st.bindInt64(1);
        try st.bindText("dup");
        try st.exec();
        try testing.expectEqual(@as(u32, 0), st.changes());
    }
    { // UPDATE touching two rows
        try be.vtable.execRaw(be.ptr, "INSERT INTO chg_probe (id, v) VALUES (2, 'b')");
        var st = try be.vtable.prepare(be.ptr, "UPDATE chg_probe SET v = ? WHERE id >= ?", false);
        defer st.deinit();
        try st.bindText("z");
        try st.bindInt64(1);
        try st.exec();
        try testing.expectEqual(@as(u32, 2), st.changes());
    }

    try be.vtable.execRaw(be.ptr, "DROP TABLE chg_probe");
}

// Results come back in TEXT format (a single message group cannot choose per-column
// binary formats), so every type has to decode losslessly from text. bytea is the one
// that does not do so naively: text format renders it as the hex escape `\x…`. The
// generated schema has no bytea column, but a future one must not silently start
// returning escape sequences where it used to return bytes.
test "postgres driver: bytea round-trips as raw bytes, not a hex escape" {
    var be = openBe() catch return error.SkipZigTest;
    defer be.vtable.close(be.ptr);

    try be.vtable.execRaw(be.ptr, "DROP TABLE IF EXISTS bytea_probe");
    try be.vtable.execRaw(be.ptr, "CREATE TABLE bytea_probe (id BIGINT, blob BYTEA)");
    try be.vtable.execRaw(be.ptr, "INSERT INTO bytea_probe VALUES (1, '\\x00486921ff'::bytea)");
    try be.vtable.execRaw(be.ptr, "INSERT INTO bytea_probe VALUES (2, ''::bytea)");

    var st = try be.vtable.prepare(be.ptr, "SELECT blob FROM bytea_probe WHERE id = ?", false);
    defer st.deinit();
    try st.bindInt64(1);
    try testing.expect(try st.step());
    // Raw bytes, including the NUL and the high byte — not the 12-character escape text.
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x48, 0x69, 0x21, 0xff }, st.getTextSlice(0).?);

    var empty = try be.vtable.prepare(be.ptr, "SELECT blob FROM bytea_probe WHERE id = ?", false);
    defer empty.deinit();
    try empty.bindInt64(2);
    try testing.expect(try empty.step());
    try testing.expectEqual(@as(usize, 0), empty.getTextSlice(0).?.len);

    try be.vtable.execRaw(be.ptr, "DROP TABLE bytea_probe");
}

// The reader has a 4 KB static buffer and allocates a dynamic one for anything larger,
// reusing it across rows within a statement's flow (the driver opens that flow around the
// message group). Both dimensions need exercising: one value far wider than the static
// buffer, and enough rows that the dynamic buffer is reused rather than grown per row.
test "postgres driver: wide values and many rows materialize exactly" {
    var be = openBe() catch return error.SkipZigTest;
    defer be.vtable.close(be.ptr);

    try be.vtable.execRaw(be.ptr, "DROP TABLE IF EXISTS wide_probe");
    try be.vtable.execRaw(be.ptr, "CREATE TABLE wide_probe (id BIGINT, body TEXT)");
    // One 1 MiB value (256x the static buffer) and one just over the boundary.
    try be.vtable.execRaw(be.ptr, "INSERT INTO wide_probe VALUES (1, repeat('ab', 524288))");
    try be.vtable.execRaw(be.ptr, "INSERT INTO wide_probe VALUES (2, repeat('z', 4097))");

    {
        var st = try be.vtable.prepare(be.ptr, "SELECT body FROM wide_probe WHERE id = ?", false);
        defer st.deinit();
        try st.bindInt64(1);
        try testing.expect(try st.step());
        const body = st.getTextSlice(0).?;
        try testing.expectEqual(@as(usize, 1024 * 1024), body.len);
        try testing.expectEqualStrings("ab", body[0..2]);
        try testing.expectEqualStrings("ab", body[body.len - 2 ..]);
        // No byte may have been dropped or duplicated across buffer boundaries.
        var a_count: usize = 0;
        for (body) |c| {
            if (c == 'a') a_count += 1;
        }
        try testing.expectEqual(@as(usize, 512 * 1024), a_count);
    }
    {
        var st = try be.vtable.prepare(be.ptr, "SELECT body FROM wide_probe WHERE id = ?", false);
        defer st.deinit();
        try st.bindInt64(2);
        try testing.expect(try st.step());
        try testing.expectEqual(@as(usize, 4097), st.getTextSlice(0).?.len);
    }

    // Many rows in ONE statement: every row read through the same reused buffer, each
    // with a value wider than the static buffer so the dynamic path is hit repeatedly.
    try be.vtable.execRaw(be.ptr,
        \\INSERT INTO wide_probe SELECT 100 + g, repeat('q', 5000) FROM generate_series(1, 2000) g
    );
    {
        var st = try be.vtable.prepare(be.ptr, "SELECT id, body FROM wide_probe WHERE id >= ? ORDER BY id", false);
        defer st.deinit();
        try st.bindInt64(100);
        var seen: usize = 0;
        var expect_id: i64 = 101;
        while (try st.step()) : (seen += 1) {
            try testing.expectEqual(expect_id, st.getInt64(0));
            try testing.expectEqual(@as(usize, 5000), st.getTextSlice(1).?.len);
            expect_id += 1;
        }
        try testing.expectEqual(@as(usize, 2000), seen);
    }

    try be.vtable.execRaw(be.ptr, "DROP TABLE wide_probe");
}

// A statement that fails PART WAY THROUGH its result: Postgres streams DataRows as it
// computes them, so rows arrive and THEN an ErrorResponse. The rest of the reply (the
// ErrorResponse and the ReadyForQuery that follows it) must be consumed before the
// connection is handed back, or the next statement reads this one's tail as its own
// result — silently wrong rows, which is the failure mode this driver exists to prevent.
// The same path covers a local failure while materializing (allocation) and a statement
// timeout firing mid-result.
test "postgres driver: a mid-result error leaves the connection usable" {
    var be = openBe() catch return error.SkipZigTest;
    defer be.vtable.close(be.ptr);

    // Rows 1..9 compute fine; row 10 divides by zero.
    {
        var st = try be.vtable.prepare(be.ptr, "SELECT 100 / (10 - i) AS v FROM generate_series(?::bigint, ?::bigint) i", false);
        defer st.deinit();
        try st.bindInt64(1);
        try st.bindInt64(20);
        try testing.expectEqual(lib.storage.backend.StepOutcome.failed, st.vtable.step(st.ctx));
    }

    // The very next statement must be correct — not the tail of the failed one.
    {
        var st = try be.vtable.prepare(be.ptr, "SELECT ?::bigint AS a, ?::text AS b", false);
        defer st.deinit();
        try st.bindInt64(4242);
        try st.bindText("after-error");
        try testing.expect(try st.step());
        try testing.expectEqual(@as(i64, 4242), st.getInt64(0));
        try testing.expectEqualStrings("after-error", st.getTextSlice(1).?);
        try testing.expect(!try st.step()); // exactly one row, nothing left over
    }

    // And a multi-row read still lines up row-for-row.
    {
        var st = try be.vtable.prepare(be.ptr, "SELECT i FROM generate_series(?::bigint, ?::bigint) i ORDER BY i", false);
        defer st.deinit();
        try st.bindInt64(1);
        try st.bindInt64(50);
        var expect: i64 = 1;
        while (try st.step()) : (expect += 1) try testing.expectEqual(expect, st.getInt64(0));
        try testing.expectEqual(@as(i64, 51), expect);
    }

    try testing.expectEqual(@as(i64, 0), try countPreparedStmts(be));
}

// Parameters are buffered client-side and sent with Bind, so the old 32-bound on copied
// binds is gone. The protocol's own limit is an int16 count; the storage layer chunks IN
// lists well below that, but a few hundred parameters must work and bind in order.
test "postgres driver: hundreds of parameters bind in order" {
    const allocator = testing.allocator;
    var be = openBe() catch return error.SkipZigTest;
    defer be.vtable.close(be.ptr);

    const n = 400;
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);
    try sql.appendSlice(allocator, "SELECT count(*)::bigint, min(x)::bigint, max(x)::bigint FROM (VALUES ");
    for (0..n) |i| {
        if (i > 0) try sql.appendSlice(allocator, ",");
        try sql.appendSlice(allocator, "(?::bigint)");
    }
    try sql.appendSlice(allocator, ") AS v(x)");

    var st = try be.vtable.prepare(be.ptr, sql.items, false);
    defer st.deinit();
    for (0..n) |i| try st.bindInt64(@intCast(i * 3));
    try testing.expect(try st.step());
    try testing.expectEqual(@as(i64, n), st.getInt64(0));
    try testing.expectEqual(@as(i64, 0), st.getInt64(1));
    try testing.expectEqual(@as(i64, (n - 1) * 3), st.getInt64(2));
}
