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

fn openBe() !lib.storage.backend.Backend {
    return pg_driver.open(testing.allocator, .{ .database = "ensv2_test", .password = "postgres" });
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
