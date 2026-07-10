//! Pool conformance: the acquire-per-request session pool the API uses
//! (src/storage/pool.zig). Sessions are exclusively owned between acquire and
//! release on every backend (there is no shared-session fast path — see the
//! pool module doc). SQLite runs against a temp file so multi-session pooling
//! is exercised here too; TEST_BACKEND=postgres (the test-storage-pg lane)
//! runs the same contracts against real PG sessions.

const std = @import("std");
const zsys = @import("lib").zsys;
const testing = std.testing;
const lib = @import("lib");
const pool_mod = lib.storage.pool;
const Pool = pool_mod.Pool;

const PG_URL = "postgresql://postgres:postgres@127.0.0.1:5432/ensv2_test";

fn wantPostgres() bool {
    const v = zsys.getEnvOwned(testing.allocator, "TEST_BACKEND") catch return false;
    defer testing.allocator.free(v);
    return std.ascii.eqlIgnoreCase(v, "postgres");
}

/// Options for a multi-session pool: PG in the pg lane, a temp-file SQLite
/// database otherwise (`:memory:` cannot pool — each handle would be its own
/// empty database). Caller deletes `sqlite_file` afterwards.
fn fileOptions(size: u32, sqlite_file: []const u8) pool_mod.Options {
    if (wantPostgres()) {
        return .{ .kind = .postgres, .database_url = PG_URL, .size = size, .chain_id = 1 };
    }
    return .{ .kind = .sqlite, .sqlite_path = sqlite_file, .size = size, .chain_id = 1 };
}

fn cleanupSqliteFile(path: []const u8) void {
    if (!wantPostgres()) zsys.deleteFile(path) catch {};
}

test "sqlite :memory: pool is pinned to a single session with checkout accounting" {
    if (wantPostgres()) return error.SkipZigTest;

    var pool = try Pool.open(testing.allocator, .{ .kind = .sqlite, .sqlite_path = ":memory:", .size = 4, .chain_id = 1 });
    defer pool.deinit();

    try testing.expectEqual(@as(usize, 1), pool.sessions.len);
    const a = try pool.acquire();
    try testing.expectEqual(@as(u64, 1), a.chain_id);
    pool.release(a);
    const b = try pool.acquire();
    try testing.expectEqual(a, b);
    pool.release(b);
}

test "pool hands out distinct sessions" {
    const file = "/tmp/zigens_pool_distinct.db";
    defer cleanupSqliteFile(file);

    var pool = try Pool.open(testing.allocator, fileOptions(2, file));
    defer pool.deinit();

    try testing.expectEqual(@as(usize, 2), pool.sessions.len);
    const a = try pool.acquire();
    const b = try pool.acquire();
    try testing.expect(a != b);
    pool.release(a);
    pool.release(b);
}

test "acquire blocks at exhaustion until a session is released" {
    const file = "/tmp/zigens_pool_exhaust.db";
    defer cleanupSqliteFile(file);

    var pool = try Pool.open(testing.allocator, fileOptions(1, file));
    defer pool.deinit();

    const held = try pool.acquire();

    const Releaser = struct {
        fn run(p: *Pool, session: *lib.Database) void {
            zsys.sleep(30 * std.time.ns_per_ms);
            p.release(session);
        }
    };
    const t = try std.Thread.spawn(.{}, Releaser.run, .{ &pool, held });

    const reacquired = try pool.acquire();
    try testing.expectEqual(held, reacquired);
    t.join();
    pool.release(reacquired);
}

test "concurrent sessions execute queries without corruption" {
    const file = "/tmp/zigens_pool_concurrent.db";
    defer cleanupSqliteFile(file);

    var tsa: ThreadSafeAllocator = .{ .child_allocator = testing.allocator };
    const allocator = tsa.allocator();

    var pool = try Pool.open(allocator, fileOptions(3, file));
    defer pool.deinit();

    const Worker = struct {
        fn run(p: *Pool, failures: *std.atomic.Value(u32)) void {
            var i: usize = 0;
            while (i < 25) : (i += 1) {
                const session = p.acquire() catch {
                    _ = failures.fetchAdd(1, .monotonic);
                    continue;
                };
                defer p.release(session);
                var q = session.prepare("SELECT 1") catch {
                    _ = failures.fetchAdd(1, .monotonic);
                    continue;
                };
                defer q.deinit();
                const got_row = q.step() catch {
                    _ = failures.fetchAdd(1, .monotonic);
                    continue;
                };
                if (!got_row or q.getInt64(0) != 1) {
                    _ = failures.fetchAdd(1, .monotonic);
                }
            }
        }
    };

    var failures = std.atomic.Value(u32).init(0);
    var threads: [6]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ &pool, &failures });
    }
    for (&threads) |*t| t.join();

    try testing.expectEqual(@as(u32, 0), failures.load(.monotonic));
}

test "deinit waits for checked-out sessions to come home" {
    const file = "/tmp/zigens_pool_deinit.db";
    defer cleanupSqliteFile(file);

    var pool = try Pool.open(testing.allocator, fileOptions(1, file));

    const held = try pool.acquire();
    const Returner = struct {
        fn run(p: *Pool, session: *lib.Database) void {
            zsys.sleep(30 * std.time.ns_per_ms);
            p.release(session);
        }
    };
    const t = try std.Thread.spawn(.{}, Returner.run, .{ &pool, held });
    pool.deinit(); // must block until the releaser returns the session
    t.join();
}

test "shutdown: parked acquirer fails with PoolClosed while deinit drains" {
    const file = "/tmp/zigens_pool_closed.db";
    defer cleanupSqliteFile(file);

    var pool = try Pool.open(testing.allocator, fileOptions(1, file));

    const held = try pool.acquire();

    const Parked = struct {
        fn run(p: *Pool, saw_closed: *std.atomic.Value(bool)) void {
            // Pool is exhausted, so this parks; deinit's closing broadcast
            // must wake it with PoolClosed instead of handing it a session
            // that is about to be destroyed.
            if (p.acquire()) |session| {
                p.release(session);
            } else |err| {
                if (err == error.PoolClosed) saw_closed.store(true, .release);
            }
        }
    };
    const Returner = struct {
        fn run(p: *Pool, session: *lib.Database) void {
            zsys.sleep(60 * std.time.ns_per_ms);
            p.release(session);
        }
    };

    var saw_closed = std.atomic.Value(bool).init(false);
    const parked = try std.Thread.spawn(.{}, Parked.run, .{ &pool, &saw_closed });
    zsys.sleep(20 * std.time.ns_per_ms); // let the acquirer park
    const returner = try std.Thread.spawn(.{}, Returner.run, .{ &pool, held });

    pool.deinit(); // closes the pool, drains the parked acquirer, waits for held

    parked.join();
    returner.join();
    try testing.expect(saw_closed.load(.acquire));
}

/// 0.16 removed std.heap.ThreadSafeAllocator; this is its shape over the zsys
/// pthread mutex, just enough for the concurrency test above.
const ThreadSafeAllocator = struct {
    child_allocator: std.mem.Allocator,
    mutex: zsys.Mutex = .{},

    fn allocator(self: *ThreadSafeAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *ThreadSafeAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.child_allocator.rawAlloc(n, alignment, ra);
    }
    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *ThreadSafeAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.child_allocator.rawResize(buf, alignment, new_len, ra);
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *ThreadSafeAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.child_allocator.rawRemap(memory, alignment, new_len, ra);
    }
    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *ThreadSafeAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.child_allocator.rawFree(buf, alignment, ra);
    }
};
