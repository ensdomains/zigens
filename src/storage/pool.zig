/// Read-only SQLite connection pool for the API server.
///
/// ## Why this exists
///
/// The API runs a thread-per-connection HTTP server (`api/server.zig`). Every
/// request thread previously shared a single `*Database` — one `sqlite3*`
/// handle plus one prepared-statement cache. SQLite's `SQLITE_CONFIG_SERIALIZED`
/// mode only makes *individual* C API calls thread-safe; it does NOT make a
/// multi-call `prepare → bind → step … → finalize` sequence atomic. When two
/// threads drove the same connection concurrently, their steps interleaved and
/// SQLite returned `SQLITE_BUSY` / `SQLITE_LOCKED` / `SQLITE_MISUSE`, which the
/// read path surfaced as `error.StepFailed` / `error.PrepareFailed` → the
/// GraphQL gateway reported a transient `EXECUTION_ERROR`. The shared
/// `stmt_cache` (a `std.StringHashMap`) was a second, independent data race.
///
/// ## The fix
///
/// Hand each request thread its *own* connection for the duration of the
/// request. WAL mode (already enabled) lets independent reader connections run
/// concurrently, so this preserves parallelism — unlike a global mutex, which
/// would serialize every query behind one connection. The only shared mutable
/// state here is the small free-list, guarded by a mutex held only across the
/// O(1) acquire/release, never across query execution.
///
/// Connections are pre-opened and kept warm so their prepared-statement caches
/// stay populated across requests. If all pooled connections are checked out,
/// `acquire` opens a temporary "overflow" connection (up to a hard cap) rather
/// than blocking; overflow connections are closed on release instead of being
/// returned to the pool.
const std = @import("std");
const db_module = @import("database.zig");
const Database = db_module.Database;
const constants = @import("../constants.zig");

pub const DatabasePool = struct {
    allocator: std.mem.Allocator,
    /// Absolute/relative path to the SQLite file, duped and owned by the pool.
    path: []u8,
    /// Chain ID applied to every connection (drives entity-ID formatting).
    chain_id: u64,

    mutex: std.Thread.Mutex = .{},
    /// Idle connections available for checkout (LIFO — keeps recently used,
    /// warm caches hot). Uses the repo's unmanaged-ArrayList idiom: methods
    /// take the allocator explicitly.
    idle: std.ArrayList(*Database) = .{},
    /// Total connections currently open (idle + checked-out + overflow).
    total_open: u32 = 0,
    /// Number of connections currently checked out (leased, not in `idle`).
    /// Used by `deinit` to detect connections still in flight at shutdown.
    checked_out: u32 = 0,
    /// Set by `deinit`. Once true, `release` closes returned connections
    /// directly instead of putting them back on the (torn-down) idle list.
    /// Checked under `mutex`, so a concurrent `release` either appends before
    /// shutdown or closes after it — it never touches a freed idle list.
    shutting_down: bool = false,
    /// Target number of long-lived pooled connections.
    size: u32,
    /// Hard cap on total open connections, including overflow.
    max_open: u32,

    /// A checked-out connection plus the bookkeeping needed to release it.
    /// Returned by `acquire`; pass back to `release`.
    pub const Lease = struct {
        database: *Database,
        /// True when this connection was opened beyond `size` because the pool
        /// was exhausted; closed on release rather than returned to the pool.
        is_overflow: bool,
    };

    /// Initialize the pool and eagerly open `size` connections so the first
    /// requests don't pay open + PRAGMA + cache-warm latency. `size` is clamped
    /// to `[1, max_open]`.
    pub fn init(
        allocator: std.mem.Allocator,
        path: []const u8,
        chain_id: u64,
        size: u32,
        max_open: u32,
    ) !DatabasePool {
        const clamped_max = @max(max_open, 1);
        const clamped_size = std.math.clamp(size, 1, clamped_max);

        const path_owned = try allocator.dupe(u8, path);
        errdefer allocator.free(path_owned);

        var pool = DatabasePool{
            .allocator = allocator,
            .path = path_owned,
            .chain_id = chain_id,
            .size = clamped_size,
            .max_open = clamped_max,
        };

        try pool.idle.ensureTotalCapacity(allocator, clamped_size);
        errdefer {
            for (pool.idle.items) |conn| {
                conn.deinit();
                allocator.destroy(conn);
            }
            pool.idle.deinit(allocator);
        }

        var opened: u32 = 0;
        while (opened < clamped_size) : (opened += 1) {
            const conn = try pool.openConnection();
            pool.idle.appendAssumeCapacity(conn);
            pool.total_open += 1;
        }

        return pool;
    }

    /// Tear down the pool. Closes all idle connections and flips `shutting_down`
    /// so any connection still checked out by an in-flight request thread is
    /// closed by that thread's `release` call rather than being returned to the
    /// freed idle list (which would be a use-after-free).
    ///
    /// NOTE: connections checked out at this moment are owned by their leasing
    /// threads; we cannot free them here without a use-after-free in the thread.
    /// If checked-out connections remain, we log it — a clean shutdown should
    /// drain/join request threads before calling this.
    pub fn deinit(self: *DatabasePool) void {
        self.mutex.lock();
        self.shutting_down = true;
        for (self.idle.items) |conn| {
            conn.deinit();
            self.allocator.destroy(conn);
        }
        self.idle.deinit(self.allocator);
        const leaked = self.checked_out;
        self.mutex.unlock();

        if (leaked > 0) {
            std.log.warn(
                "DatabasePool.deinit: {d} connection(s) still checked out; they will be closed on release",
                .{leaked},
            );
        }

        self.allocator.free(self.path);
    }

    /// Open a fresh read-only connection with the standard PRAGMAs and chain ID.
    /// Caller owns the returned heap-allocated `*Database`.
    fn openConnection(self: *DatabasePool) !*Database {
        const conn = try self.allocator.create(Database);
        errdefer self.allocator.destroy(conn);

        conn.* = try Database.initWithoutSchema(self.allocator, self.path);
        conn.setChainId(self.chain_id);
        return conn;
    }

    /// Borrow a connection for the current thread. The returned `Lease.database`
    /// is exclusively owned by the caller until `release` is called — never
    /// share it across threads. Always pair with `defer pool.release(lease)`.
    pub fn acquire(self: *DatabasePool) !Lease {
        self.mutex.lock();

        // Refuse to hand out connections once shutdown has begun.
        if (self.shutting_down) {
            self.mutex.unlock();
            return error.PoolShuttingDown;
        }

        if (self.idle.pop()) |conn| {
            self.checked_out += 1;
            self.mutex.unlock();
            return .{ .database = conn, .is_overflow = false };
        }

        // Pool exhausted. Open an overflow connection if we're under the hard cap.
        if (self.total_open < self.max_open) {
            self.total_open += 1;
            self.checked_out += 1;
            self.mutex.unlock();

            const conn = self.openConnection() catch |err| {
                // Roll back the reservation on failure.
                self.mutex.lock();
                self.total_open -= 1;
                self.checked_out -= 1;
                self.mutex.unlock();
                return err;
            };
            return .{ .database = conn, .is_overflow = true };
        }

        self.mutex.unlock();
        return error.PoolExhausted;
    }

    /// Return a leased connection. Pooled connections go back on the idle list;
    /// overflow connections (and any connection returned after shutdown began)
    /// are closed.
    pub fn release(self: *DatabasePool, lease: Lease) void {
        if (lease.is_overflow) {
            lease.database.deinit();
            self.allocator.destroy(lease.database);
            self.mutex.lock();
            self.total_open -= 1;
            self.checked_out -= 1;
            self.mutex.unlock();
            return;
        }

        self.mutex.lock();

        // If shutdown started while this connection was checked out, the idle
        // list has already been freed. Close the connection directly instead of
        // appending to (freed) idle memory. The flag check is under the same
        // mutex deinit uses, so this is race-free.
        if (self.shutting_down) {
            self.checked_out -= 1;
            self.mutex.unlock();
            lease.database.deinit();
            self.allocator.destroy(lease.database);
            return;
        }

        // appendAssumeCapacity is safe: capacity was reserved for `size` pooled
        // connections at init and pooled connections are never freed before
        // shutdown, so the idle list never needs to grow past that.
        std.debug.assert(self.idle.items.len < self.idle.capacity);
        self.idle.appendAssumeCapacity(lease.database);
        self.checked_out -= 1;
        self.mutex.unlock();
    }
};

// ============================================================================
// TESTS
// ============================================================================

test "DatabasePool: acquire/release reuses connections and isolates handles" {
    const allocator = std.testing.allocator;

    var pool = try DatabasePool.init(allocator, ":memory:", 1, 2, 4);
    defer pool.deinit();

    // Two concurrent leases get distinct connections.
    const a = try pool.acquire();
    const b = try pool.acquire();
    try std.testing.expect(a.database != b.database);

    // Releasing and re-acquiring reuses a pooled connection (LIFO).
    pool.release(b);
    const b2 = try pool.acquire();
    try std.testing.expectEqual(b.database, b2.database);

    pool.release(a);
    pool.release(b2);
}

test "DatabasePool: overflow opens beyond size and closes on release" {
    const allocator = std.testing.allocator;

    var pool = try DatabasePool.init(allocator, ":memory:", 1, 1, 3);
    defer pool.deinit();

    const a = try pool.acquire(); // pooled
    const b = try pool.acquire(); // overflow
    const cc = try pool.acquire(); // overflow
    try std.testing.expect(b.is_overflow);
    try std.testing.expect(cc.is_overflow);

    // At the hard cap (3), the next acquire fails.
    try std.testing.expectError(error.PoolExhausted, pool.acquire());

    // Releasing an overflow frees a slot for a new acquire.
    pool.release(cc);
    const d = try pool.acquire();
    pool.release(d);
    pool.release(b);
    pool.release(a);
}

test "DatabasePool: releasing a pooled connection after shutdown closes it (no UAF)" {
    const allocator = std.testing.allocator;

    var pool = try DatabasePool.init(allocator, ":memory:", 1, 2, 4);

    // Check out a pooled connection, then shut the pool down while it's still
    // leased. This mirrors a detached request thread that's mid-flight when the
    // server exits. deinit must not free the lease, and the late release must
    // close it directly rather than touching the freed idle list.
    const lease = try pool.acquire();
    pool.deinit(); // frees idle list + path, flips shutting_down; lease survives

    // If this appended to the freed idle list it'd be a use-after-free; instead
    // it closes the connection. testing.allocator verifies no leak/double-free.
    pool.release(lease);
}

test "DatabasePool: acquire after shutdown is refused" {
    const allocator = std.testing.allocator;

    var pool = try DatabasePool.init(allocator, ":memory:", 1, 1, 2);
    pool.deinit();

    try std.testing.expectError(error.PoolShuttingDown, pool.acquire());
}
