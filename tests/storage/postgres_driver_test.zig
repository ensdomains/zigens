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
        .network = net,
        .start_block = 0,
        .end_block = null,
        .poll_interval = 12,
        .batch_size = 2000,
        .max_blocks_per_request = 2000,
        .rate_limit_per_second = 15,
        .trusted_proxy_hops = 0,
        .api_port = 8080,
        .api_enabled = false,
        .status_port = null,
        .webhooks_enabled = false,
        .webhook_max_retries = 3,
        .webhook_db_path = ":memory:",
        .webhook_admin_username = null,
        .webhook_admin_password = null,
        .max_memory_mb = 512,
        .checkpoint_interval = 100,
        .graphql_max_depth = 10,
        .graphql_max_cost = 10000,
        .metrics_enabled = false,
        .rainbow_path = "",
        .v1_contracts = addrs,
        .v2_contracts = addrs,
    };
}

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
    }

    // Connection recovered (peekForError consumed ReadyForQuery): a fresh op works.
    try be.vtable.execRaw(be.ptr, "DROP TABLE drv_fail");
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
