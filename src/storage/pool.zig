//! Connection pool of read-only `Database` sessions — the acquire-per-request
//! seam the API process uses (see docs/postgresql-migration-plan.md,
//! "Connection routing & pooling").
//!
//! A `*Database` is a session bound to exactly ONE backend connection (with its
//! own statement cache), owned by exactly one thread between `acquire` and
//! `release` — that handoff is the only synchronization. There is deliberately
//! NO shared-session fast path: a session's prepared-statement cache and live
//! statement handles are not thread-safe on any backend (SQLite's SERIALIZED
//! mode only serializes individual C calls, not Zig-side cache mutation or
//! interleaved reset/bind/step on a shared cached statement), so concurrent
//! request threads must never hold the same session.
//!
//! Per backend:
//!  - SQLite: `size` independent read connections to the same database file.
//!    `:memory:` is forced to a single session (independent :memory: handles
//!    would each open a separate empty database).
//!  - PostgreSQL: `size` independent sessions; a single pinned pg connection
//!    is not concurrent-safe, so pooling is mandatory here.
//!
//! Sessions are opened WITHOUT the schema bootstrap (the pool's consumers are
//! read-only; running migrate would take a startup write lock against a live
//! indexer) — the cross-backend analogue of `openFromConfigReadonly`.
const std = @import("std");
const zsys = @import("../utils/system.zig");
const config = @import("../config.zig");
const db_open = @import("db_open.zig");
const Database = @import("database.zig").Database;

pub const Options = struct {
    kind: config.BackendKind,
    /// SQLite database path (used when kind == .sqlite).
    sqlite_path: []const u8 = "",
    /// Postgres URL (required when kind == .postgres).
    database_url: ?[]const u8 = null,
    /// Number of sessions. SQLite `:memory:` is always 1 (see module doc).
    size: u32 = 10,
    /// EIP-155 chain id, set on every session (entity-ID formatting).
    chain_id: u64 = 0,
    /// COVERAGE_STALE_AFTER_SECONDS, set on every session. 0 leaves the
    /// no-finality stale fallback off.
    stale_after_seconds: u32 = 0,
};

pub const Pool = struct {
    allocator: std.mem.Allocator,
    sessions: []*Database,
    /// Stack of currently-free sessions; `free[0..free_count]` are available.
    free: []*Database,
    free_count: usize,
    /// Set by deinit: parked/new acquirers fail with error.PoolClosed instead
    /// of racing the teardown.
    closing: bool = false,
    mutex: zsys.Mutex = .{},
    cond: zsys.Condition = .{},

    pub fn open(allocator: std.mem.Allocator, opts: Options) !Pool {
        // `:memory:` (and SQLite's empty-path private temp DB) is per-connection
        // state — independent handles would each see a separate empty database,
        // so those are pinned to a single session.
        const single_sqlite = opts.kind == .sqlite and
            (opts.sqlite_path.len == 0 or std.mem.eql(u8, opts.sqlite_path, ":memory:"));
        const n: usize = if (single_sqlite) 1 else @max(1, opts.size);

        const sessions = try allocator.alloc(*Database, n);
        var opened: usize = 0;
        errdefer {
            for (sessions[0..opened]) |s| {
                s.deinit();
                allocator.destroy(s);
            }
            allocator.free(sessions);
        }
        while (opened < n) {
            const s = try allocator.create(Database);
            errdefer allocator.destroy(s);
            s.* = .{
                .allocator = allocator,
                .backend = try db_open.selectBackend(allocator, opts.kind, opts.sqlite_path, opts.database_url),
            };
            s.setChainId(opts.chain_id);
            s.setStaleAfterSeconds(opts.stale_after_seconds);
            sessions[opened] = s;
            opened += 1;
        }

        const free = try allocator.alloc(*Database, n);
        @memcpy(free, sessions);

        return .{
            .allocator = allocator,
            .sessions = sessions,
            .free = free,
            .free_count = n,
        };
    }

    /// Check out a session for exclusive use; blocks until one is free. Fails
    /// with error.PoolClosed once deinit has begun. The caller must `release`
    /// the session when the request completes and must not use it afterwards.
    pub fn acquire(self: *Pool) !*Database {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (true) {
            if (self.closing) return error.PoolClosed;
            if (self.free_count > 0) break;
            self.cond.wait(&self.mutex);
        }
        self.free_count -= 1;
        return self.free[self.free_count];
    }

    pub fn release(self: *Pool, session: *Database) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        // Unconditional (std.debug.assert compiles out in ReleaseFast and this
        // would be an out-of-bounds heap write).
        if (self.free_count >= self.free.len) @panic("pool: double release");
        self.free[self.free_count] = session;
        self.free_count += 1;
        // broadcast, not signal: a parked acquirer woken during shutdown exits
        // with PoolClosed without consuming the session, and a lone signal it
        // swallowed would leave deinit waiting forever.
        self.cond.broadcast();
    }

    /// Close every session. Marks the pool closing (parked/new acquirers fail
    /// with error.PoolClosed), then blocks until all checked-out sessions are
    /// released — so an in-flight request can never be left holding freed
    /// memory; a leaked (never-released) session hangs deinit rather than
    /// corrupting it.
    pub fn deinit(self: *Pool) void {
        self.mutex.lock();
        self.closing = true;
        self.cond.broadcast();
        while (self.free_count < self.sessions.len) self.cond.wait(&self.mutex);
        self.mutex.unlock();
        for (self.sessions) |s| {
            s.deinit();
            self.allocator.destroy(s);
        }
        self.allocator.free(self.sessions);
        self.allocator.free(self.free);
    }
};
