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
