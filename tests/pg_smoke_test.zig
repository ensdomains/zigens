//! Phase 4 dependency-integration gate: the pg.zig PostgreSQL driver (zig-0.15
//! branch) compiles and its public API is importable under our Zig 0.15.2
//! toolchain, with TLS off (PlainStream — no openssl/libc). The real backend
//! driver (src/storage/drivers/postgres.zig) lands next; this only proves the
//! `pg` dependency resolves, builds, and exposes the surface the driver needs.
const std = @import("std");
const pg = @import("pg");

test "pg.zig public API is importable" {
    _ = pg.Conn;
    _ = pg.Pool;
    _ = pg.Stmt;
    _ = pg.Result;
    _ = pg.Row;
    _ = pg.QueryRow;
    _ = pg.types;
}

// Live integration: pg.zig connects to the local Postgres (apt-installed, port
// 5432, scram-sha-256) over TCP and round-trips a typed query. Skips gracefully
// if no Postgres is reachable (start: `sudo pg_ctlcluster 17 main start`).
test "pg.zig connects to the live Postgres and round-trips a typed query" {
    const allocator = std.testing.allocator;
    var pool = pg.Pool.init(allocator, .{
        .size = 1,
        .connect = .{ .host = "127.0.0.1", .port = 5432 },
        .auth = .{ .username = "postgres", .password = "postgres", .database = "ensv2_test" },
    }) catch |err| {
        std.debug.print("SKIP pg live test: Pool.init failed ({})\n", .{err});
        return error.SkipZigTest;
    };
    defer pool.deinit();

    var conn = pool.acquire() catch |err| {
        std.debug.print("SKIP pg live test: no Postgres at 127.0.0.1:5432 ({})\n", .{err});
        return error.SkipZigTest;
    };
    defer pool.release(conn);

    var row = (try conn.row("SELECT 42::int4, 'ensv2'::text", .{})) orelse return error.NoRow;
    defer row.deinit() catch {};
    try std.testing.expectEqual(@as(i32, 42), try row.get(i32, 0));
    try std.testing.expectEqualStrings("ensv2", try row.get([]const u8, 1));
}

// De-risk the Backend/StmtVTable adapter: validate pg.zig's LOW-LEVEL prepared-
// statement primitives (conn.prepare → sequential stmt.bind → execute → Result.next
// → Row.get) + lifetimes — exactly what drivers/postgres.zig will adapt onto.
test "pg.zig low-level prepare/bind/execute/iterate round-trip" {
    const allocator = std.testing.allocator;
    var pool = pg.Pool.init(allocator, .{
        .size = 1,
        .connect = .{ .host = "127.0.0.1", .port = 5432 },
        .auth = .{ .username = "postgres", .password = "postgres", .database = "ensv2_test" },
    }) catch return error.SkipZigTest;
    defer pool.deinit();
    var conn = pool.acquire() catch return error.SkipZigTest;
    defer pool.release(conn);

    _ = try conn.exec("CREATE TEMP TABLE pgz_probe (a text, b bigint, c smallint)", .{});

    {
        // execute() transfers the stmt's arena to the Result, so we free the Result,
        // not the stmt (stmt.deinit only on a pre-execute error path).
        var stmt = try conn.prepare("INSERT INTO pgz_probe (a, b, c) VALUES ($1, $2, $3)");
        try stmt.bind(@as([]const u8, "hello"));
        try stmt.bind(@as(i64, 42));
        try stmt.bind(@as(i16, 7));
        var res = try stmt.execute();
        try res.drain(); // no rows to read, but the conn must be drained before reuse
        res.deinit();
    }
    {
        var stmt = try conn.prepare("SELECT a, b, c FROM pgz_probe WHERE b = $1");
        try stmt.bind(@as(i64, 42));
        var res = try stmt.execute();
        defer res.deinit();
        const r = (try res.next()) orelse return error.NoRow;
        try std.testing.expectEqualStrings("hello", try r.get([]const u8, 0));
        try std.testing.expectEqual(@as(i64, 42), try r.get(i64, 1));
        try std.testing.expectEqual(@as(i16, 7), try r.get(i16, 2));
        try std.testing.expect((try res.next()) == null);
    }
}
