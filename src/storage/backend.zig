//! Pluggable database-backend SPI.
//!
//! Phase 0 introduces the *statement* seam: every storage module talks to a
//! backend-agnostic `Statement` whose primitive operations dispatch through a
//! `StmtVTable`. The SQLite implementation lives in `drivers/sqlite.zig`. This
//! is the seam a second backend (PostgreSQL) and third-party backends plug
//! into; the broader `Backend`/`Pool`/`Dialect` surface is layered on in later
//! phases (see docs/postgresql-migration-plan.md).
//!
//! `Statement` is a drop-in for the old `Query`: same sequential 1-based bind
//! cursor, same index-based column reads, same `SQLITE_STATIC` + tracked-copy
//! bind lifetime — so the storage modules change only their import.

const std = @import("std");
const Database = @import("database.zig").Database;
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;

/// Max number of bound strings tracked per statement (preserves the old
/// `Query` bound-string lifetime model: copies bound `SQLITE_STATIC` and freed
/// on reset/deinit).
const MAX_BOUND_STRINGS = 32;

/// Outcome of stepping a statement, mapped from the backend's native result.
pub const StepOutcome = enum { row, done, failed };

/// Placeholder style a backend accepts. Phase 0 is SQLite-only (`?`); the
/// Postgres driver renumbers to `$N`. Carried here for the Phase-4 SPI.
pub const Placeholder = enum { qmark, dollar };

/// Backend feature flags, consulted by callers without RTTI. Each driver
/// declares its capabilities statically and carries them on its `Backend`.
///
/// `server_side_undo` is load-bearing for reorg correctness. `true` means the
/// backend provides in-engine capture (triggers) for the reorg undo-log,
/// installed by `Database.initWithBackend`'s bootstrap — declare it ONLY if
/// trigger capture really exists, or reorg rollback is silently broken.
/// `false` activates the application write-path fallback: no triggers are
/// installed and the storage mutators capture pre-images themselves
/// (reorg_undo.captureWhere/captureUpsert/captureActive*). The fallback covers
/// exactly the instrumented mutators in src/storage/ (+ the v1 handler heal) —
/// raw SQL on protected tables outside them is NOT captured. Conformance gate:
/// `zig build test-integration-fallback` (the full reorg suite with SQLite
/// forced to `false`). Both shipped drivers declare `true`.
pub const Capabilities = struct {
    placeholder: Placeholder = .qmark,
    /// Supports the `RETURNING` clause (used unconditionally by the webhook
    /// queue's race-free claim UPDATE).
    returning: bool = true,
    /// Supports `SAVEPOINT`/`RELEASE`/`ROLLBACK TO` inside a transaction.
    savepoints: bool = true,
    /// In-engine (trigger-based) reorg undo capture. See struct doc.
    server_side_undo: bool = true,
    /// The driver manages its connection through an internal pool (reconnect
    /// support); the `Backend` still exposes a single pinned session.
    pooled: bool = false,
};

/// Transaction mode. `immediate` takes a write lock up front (SQLite `BEGIN IMMEDIATE`);
/// `deferred` is a plain `BEGIN`. `read_snapshot` is a read-only transaction giving a
/// STABLE snapshot across statements — SQLite plain `BEGIN` (WAL snapshots on first read),
/// Postgres `REPEATABLE READ, READ ONLY` — so several reads in one request observe one
/// consistent state. On Postgres `deferred`/`immediate` both map to a plain `BEGIN` (it
/// locks lazily and isolation handles serialization).
pub const TxMode = enum { deferred, immediate, read_snapshot };

/// Upsert conflict behaviour: `.replace` overwrites the conflicting row,
/// `.ignore` keeps it. (SQLite `INSERT OR REPLACE`/`OR IGNORE`; Postgres
/// `ON CONFLICT … DO UPDATE`/`DO NOTHING`.)
pub const ConflictAction = enum { replace, ignore };

/// Per-backend SQL-fragment builders for the handful of constructs that differ
/// between SQLite and PostgreSQL. Storage code keeps writing `?` placeholders
/// (the Postgres driver renumbers them to `$N` at prepare time); only the
/// *semantic* divergences below go through these builders. Each builder returns
/// an allocator-owned slice the caller frees. The SQLite `Dialect` emits exactly
/// today's SQL, so routing a call site through it is behaviour-neutral.
///
/// (`introspectColumns` — PRAGMA table_info vs information_schema.columns — is
/// added when the reorg undo-log is routed through the dialect; it needs the
/// connection, unlike these pure builders.)
pub const Dialect = struct {
    placeholder: Placeholder,
    /// SQL expression yielding the current Unix epoch in seconds.
    nowEpoch: []const u8,
    /// Two-argument scalar max/min function NAME. SQLite's `MAX`/`MIN` are scalar for 2+
    /// args; Postgres needs `GREATEST`/`LEAST` (its `MAX`/`MIN` are aggregate-only). Call
    /// syntax `FN(a, b)` is identical, so this is just the name. NULL-handling differs
    /// (SQLite `MAX` → NULL if any arg NULL; `GREATEST` ignores NULLs) — only safe where
    /// every argument is non-null, which holds at all current call sites.
    scalar_max: []const u8,
    scalar_min: []const u8,
    /// `INSERT OR REPLACE/IGNORE INTO t (cols) VALUES (v, …)` (SQLite) /
    /// `INSERT INTO t (cols) VALUES (v, …) ON CONFLICT(conflict) DO UPDATE/NOTHING` (PG).
    /// `value_exprs` gives the SQL value expression per column (a `?` placeholder,
    /// a literal like `'migration'`/`NULL`/`0`, or a wrapper like `LOWER(?)`); pass
    /// an empty slice for the common all-`?` case (one placeholder per column).
    upsert: *const fn (allocator: std.mem.Allocator, table: []const u8, cols: []const []const u8, value_exprs: []const []const u8, conflict_cols: []const []const u8, action: ConflictAction) anyerror![]u8,
    /// Multi-row form of `upsert`, all-`?` placeholders: `VALUES (…), (…) …`
    /// × `rows`. Bind row-major in column order. Callers must ensure no two
    /// rows share a conflict key within one statement — Postgres rejects
    /// "affect row a second time", unlike the silent per-row semantics of
    /// sequential single-row upserts.
    upsertMulti: *const fn (allocator: std.mem.Allocator, table: []const u8, cols: []const []const u8, rows: usize, conflict_cols: []const []const u8, action: ConflictAction) anyerror![]u8,
    /// `INSERT OR REPLACE/IGNORE INTO t (cols) <select_body>` (SQLite) /
    /// `INSERT INTO t (cols) <select_body> ON CONFLICT(conflict) DO UPDATE/NOTHING` (PG).
    /// `select_body` is the caller's `SELECT … FROM … [WHERE …]` (driver renumbers `?`).
    insertSelect: *const fn (allocator: std.mem.Allocator, table: []const u8, cols: []const []const u8, select_body: []const u8, conflict_cols: []const []const u8, action: ConflictAction) anyerror![]u8,
    /// ` RETURNING <col>` clause.
    returning: *const fn (allocator: std.mem.Allocator, col: []const u8) anyerror![]u8,
    /// `json_object('c', alias."c", …)` (SQLite) / `jsonb_build_object(…)`/`to_jsonb` (PG).
    jsonObject: *const fn (allocator: std.mem.Allocator, cols: []const []const u8, alias: []const u8) anyerror![]u8,
    /// Extract a JSON object field by name: `json_extract(src, '$.col')` (SQLite) /
    /// `(src::jsonb ->> 'col')` (PG). `cast_type` (when non-null) requests a typed
    /// result — SQLite is dynamically typed and ignores it; Postgres (Phase 4)
    /// appends `::<cast_type>` because `->>` always yields `text`.
    jsonExtract: *const fn (allocator: std.mem.Allocator, src: []const u8, col: []const u8, cast_type: ?[]const u8) anyerror![]u8,
};

/// A column as seen by `introspectColumns`: its name, declared SQL type (may be
/// empty for SQLite's untyped columns), and 1-based position in the primary key
/// (0 = not part of the PK). Caller owns `name`/`sql_type`; free via
/// `freeColumnInfo`.
pub const ColumnInfo = struct {
    name: []const u8,
    sql_type: []const u8,
    pk_pos: i64,
    /// True for DB-computed columns (GENERATED ALWAYS AS ... STORED). They cannot
    /// be written, so the reorg undo-log must exclude them from capture/restore —
    /// they recompute from the base columns automatically. SQLite's PRAGMA
    /// table_info never lists generated columns (so this stays false there); the
    /// Postgres information_schema query sets it from `is_generated`.
    is_generated: bool = false,
};

/// Free a `[]ColumnInfo` returned by `introspectColumns`.
pub fn freeColumnInfo(allocator: std.mem.Allocator, cols: []ColumnInfo) void {
    for (cols) |col| {
        allocator.free(col.name);
        allocator.free(col.sql_type);
    }
    allocator.free(cols);
}

/// Connection-level operations a backend provides — the seam for opening,
/// closing, raw exec, and prepare. `db` is the owning session; Phase 0 keeps
/// the SQLite connection state (`db`/`stmt_cache`) on `Database` as transitional
/// fields, so the driver fns read it from there. The runtime backend *selection*
/// and per-connection ctx land with the second backend (Phase 4).
pub const VTable = struct {
    close: *const fn (ctx: *anyopaque) void,
    execRaw: *const fn (ctx: *anyopaque, sql: []const u8) anyerror!void,
    prepare: *const fn (ctx: *anyopaque, sql: []const u8, cached: bool) anyerror!Statement,
    begin: *const fn (ctx: *anyopaque, mode: TxMode) anyerror!void,
    commit: *const fn (ctx: *anyopaque) anyerror!void,
    /// Rollback is best-effort and logs (not returns) on failure — a failed
    /// rollback is logged CRITICAL, matching the old `rollbackTransaction`.
    rollback: *const fn (ctx: *anyopaque) void,
    /// ROWID of the most recent successful INSERT on this connection.
    lastInsertId: *const fn (ctx: *anyopaque) i64,
    /// Column metadata for `table` (name, declared type, PK position) — the
    /// connection-bound counterpart to the conn-less `Dialect` builders, since it
    /// must query the live schema. SQLite: `PRAGMA table_info`; Postgres (Phase 4):
    /// `information_schema`. Caller owns the result (`freeColumnInfo`).
    introspectColumns: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, table: []const u8) anyerror![]ColumnInfo,
};

/// The backend handle held by `Database`: an opaque pointer to the driver's
/// connection state (`ptr`) + its vtable. The raw connection handle lives inside
/// `ptr` (for SQLite, a `drivers/sqlite.zig` `SqliteConn`), never on `Database`.
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    /// SQL-dialect builders for this backend (static per backend).
    dialect: *const Dialect,
    /// Feature flags for this backend (static per backend).
    caps: Capabilities,
};

/// RAII transaction guard. `begin` opens the transaction; `commit` finalizes it;
/// `deinit` rolls back if `commit` was not called — so the idiom is:
/// `var tx = try Tx.begin(db, .immediate); defer tx.deinit(); … ; try tx.commit();`
/// (equivalent to the old `errdefer db.exec("ROLLBACK")` pattern).
pub const Tx = struct {
    db: *Database,
    committed: bool = false,

    pub fn begin(db: *Database, mode: TxMode) !Tx {
        try db.backend.vtable.begin(db.backend.ptr, mode);
        return .{ .db = db };
    }

    pub fn commit(self: *Tx) !void {
        try self.db.backend.vtable.commit(self.db.backend.ptr);
        self.committed = true;
    }

    pub fn deinit(self: *Tx) void {
        if (!self.committed) self.db.backend.vtable.rollback(self.db.backend.ptr);
    }
};

/// The primitive statement operations a backend must provide. The SQLite impl
/// is `drivers/sqlite.zig`. `ctx` is the backend's opaque per-statement handle
/// (for SQLite, the `sqlite3_stmt`). Text binds are `SQLITE_STATIC`-style: the
/// pointer must remain valid until `step`/`exec`; `Statement` owns that via its
/// tracked-copy buffer.
pub const StmtVTable = struct {
    bindText: *const fn (ctx: *anyopaque, idx: c_int, ptr: [*]const u8, len: usize) bool,
    bindInt64: *const fn (ctx: *anyopaque, idx: c_int, value: i64) bool,
    bindInt: *const fn (ctx: *anyopaque, idx: c_int, value: i32) bool,
    bindNull: *const fn (ctx: *anyopaque, idx: c_int) bool,
    exec: *const fn (ctx: *anyopaque) bool,
    step: *const fn (ctx: *anyopaque) StepOutcome,
    changes: *const fn (ctx: *anyopaque) u32,
    columnIsNull: *const fn (ctx: *anyopaque, col: c_int) bool,
    columnText: *const fn (ctx: *anyopaque, col: c_int) ?[]const u8,
    columnInt64: *const fn (ctx: *anyopaque, col: c_int) i64,
    columnInt: *const fn (ctx: *anyopaque, col: c_int) i32,
    lastError: *const fn (ctx: *anyopaque) [:0]const u8,
    reset: *const fn (ctx: *anyopaque) void,
    finalize: *const fn (ctx: *anyopaque) void,
};

/// Backend-agnostic prepared statement. Drop-in replacement for the old
/// `Query`. Obtain one via `init`/`initCached` (which forward to
/// `Database.prepare`/`prepareCached`, dispatching to the active driver).
pub const Statement = struct {
    ctx: *anyopaque,
    vtable: *const StmtVTable,
    allocator: std.mem.Allocator,
    param_idx: c_int = 1,
    /// Cached statements are reset (not finalized) on deinit; the cache owns them.
    is_cached: bool = false,
    /// Value-copied SQL prefix so execution failures can name their query.
    sql_prefix: [160]u8 = undefined,
    sql_prefix_len: u8 = 0,
    /// Tracked bound-string copies, freed on reset/deinit (SQLITE_STATIC model).
    bound_strings: [MAX_BOUND_STRINGS]?[]u8 = [_]?[]u8{null} ** MAX_BOUND_STRINGS,
    bound_string_count: usize = 0,

    pub fn init(database: *Database, sql: []const u8) !Statement {
        var stmt = try database.prepare(sql);
        stmt.rememberSql(sql);
        return stmt;
    }

    pub fn initCached(database: *Database, sql: []const u8) !Statement {
        var stmt = try database.prepareCached(sql);
        stmt.rememberSql(sql);
        return stmt;
    }

    /// Keep a value-copied prefix of the SQL so execution failures can name the
    /// query. Copied (not borrowed): some call sites free their SQL string
    /// before the statement is executed.
    pub fn rememberSql(self: *Statement, sql: []const u8) void {
        const n = @min(sql.len, self.sql_prefix.len);
        @memcpy(self.sql_prefix[0..n], sql[0..n]);
        self.sql_prefix_len = @intCast(n);
    }

    fn sqlPrefix(self: *const Statement) []const u8 {
        return self.sql_prefix[0..self.sql_prefix_len];
    }

    pub fn deinit(self: *Statement) void {
        self.freeBoundStrings();
        if (self.is_cached) {
            self.vtable.reset(self.ctx);
        } else {
            self.vtable.finalize(self.ctx);
        }
    }

    pub fn reset(self: *Statement) void {
        self.freeBoundStrings();
        self.vtable.reset(self.ctx);
        self.param_idx = 1;
    }

    fn freeBoundStrings(self: *Statement) void {
        for (self.bound_strings[0..self.bound_string_count]) |maybe_str| {
            if (maybe_str) |str| self.allocator.free(str);
        }
        self.bound_string_count = 0;
        self.bound_strings = [_]?[]u8{null} ** MAX_BOUND_STRINGS;
    }

    fn trackBoundString(self: *Statement, str: []u8) !void {
        // Fail loudly: the old behavior freed the copy and bound the dangling
        // pointer (use-after-free at step/exec). Callers with legitimately
        // large parameter lists must chunk (see setRegistriesReachability).
        if (self.bound_string_count >= MAX_BOUND_STRINGS) {
            self.allocator.free(str);
            return error.TooManyBoundParams;
        }
        self.bound_strings[self.bound_string_count] = str;
        self.bound_string_count += 1;
    }

    // ── Parameter binding ──────────────────────────────────────────────────

    pub fn bindText(self: *Statement, value: []const u8) !void {
        const copy = try self.allocator.dupe(u8, value);
        try self.trackBoundString(copy);
        try self.bindTrackedText(copy);
    }

    /// Bind text with caller-guaranteed static lifetime (no copy).
    pub fn bindTextStatic(self: *Statement, value: []const u8) !void {
        if (!self.vtable.bindText(self.ctx, self.param_idx, value.ptr, value.len)) {
            std.log.err("Failed to bind static text parameter: {s}", .{self.vtable.lastError(self.ctx)});
            return error.BindFailed;
        }
        self.param_idx += 1;
    }

    fn bindTrackedText(self: *Statement, value: []u8) !void {
        if (!self.vtable.bindText(self.ctx, self.param_idx, value.ptr, value.len)) {
            std.log.err("Failed to bind tracked text parameter: {s}", .{self.vtable.lastError(self.ctx)});
            return error.BindFailed;
        }
        self.param_idx += 1;
    }

    pub fn bindInt64(self: *Statement, value: i64) !void {
        if (!self.vtable.bindInt64(self.ctx, self.param_idx, value)) {
            std.log.err("Failed to bind int64 parameter: {s}", .{self.vtable.lastError(self.ctx)});
            return error.BindFailed;
        }
        self.param_idx += 1;
    }

    pub fn bindInt(self: *Statement, value: i32) !void {
        if (!self.vtable.bindInt(self.ctx, self.param_idx, value)) {
            std.log.err("Failed to bind int parameter: {s}", .{self.vtable.lastError(self.ctx)});
            return error.BindFailed;
        }
        self.param_idx += 1;
    }

    pub fn bindNull(self: *Statement) !void {
        if (!self.vtable.bindNull(self.ctx, self.param_idx)) {
            std.log.err("Failed to bind null parameter: {s}", .{self.vtable.lastError(self.ctx)});
            return error.BindFailed;
        }
        self.param_idx += 1;
    }

    pub fn bindAddress(self: *Statement, addr: Address) !void {
        const hex = try addr.toHex(self.allocator);
        try self.trackBoundString(hex);
        try self.bindTrackedText(hex);
    }

    pub fn bindHash(self: *Statement, hash: Hash) !void {
        const hex = try hash.toHex(self.allocator);
        try self.trackBoundString(hex);
        try self.bindTrackedText(hex);
    }

    pub fn bindAddressBuf(self: *Statement, addr: Address) !void {
        var buf: [42]u8 = undefined;
        _ = addr.toHexBuf(&buf);
        const copy = try self.allocator.dupe(u8, &buf);
        try self.trackBoundString(copy);
        try self.bindTrackedText(copy);
    }

    pub fn bindHashBuf(self: *Statement, hash: Hash) !void {
        var buf: [66]u8 = undefined;
        _ = hash.toHexBuf(&buf);
        const copy = try self.allocator.dupe(u8, &buf);
        try self.trackBoundString(copy);
        try self.bindTrackedText(copy);
    }

    pub fn bindOptionalText(self: *Statement, value: ?[]const u8) !void {
        if (value) |v| try self.bindText(v) else try self.bindNull();
    }

    pub fn bindOptionalInt64(self: *Statement, value: ?i64) !void {
        if (value) |v| try self.bindInt64(v) else try self.bindNull();
    }

    pub fn bindOptionalHash(self: *Statement, hash: ?Hash) !void {
        if (hash) |h| try self.bindHash(h) else try self.bindNull();
    }

    // ── Execution ──────────────────────────────────────────────────────────

    pub fn exec(self: *Statement) !void {
        if (!self.vtable.exec(self.ctx)) {
            std.log.err("Failed to execute query: {s} [sql: {s}]", .{ self.vtable.lastError(self.ctx), self.sqlPrefix() });
            return error.ExecFailed;
        }
    }

    pub fn step(self: *Statement) !bool {
        return switch (self.vtable.step(self.ctx)) {
            .row => true,
            .done => false,
            .failed => {
                std.log.err("Failed to step query: {s}", .{self.vtable.lastError(self.ctx)});
                return error.StepFailed;
            },
        };
    }

    pub fn changes(self: *Statement) u32 {
        return self.vtable.changes(self.ctx);
    }

    // ── Result extraction ────────────────────────────────────────────────────

    /// Caller owns the returned memory; null if the column is NULL.
    pub fn getText(self: *Statement, col: usize) !?[]u8 {
        const slice = self.vtable.columnText(self.ctx, @intCast(col)) orelse return null;
        return try self.allocator.dupe(u8, slice);
    }

    /// Borrowed slice valid only until the next step()/reset()/deinit().
    pub fn getTextSlice(self: *Statement, col: usize) ?[]const u8 {
        return self.vtable.columnText(self.ctx, @intCast(col));
    }

    pub fn getInt64(self: *Statement, col: usize) i64 {
        return self.vtable.columnInt64(self.ctx, @intCast(col));
    }

    pub fn getInt(self: *Statement, col: usize) i32 {
        return self.vtable.columnInt(self.ctx, @intCast(col));
    }

    pub fn getBool(self: *Statement, col: usize) bool {
        return self.vtable.columnInt(self.ctx, @intCast(col)) != 0;
    }

    pub fn getOptionalInt64(self: *Statement, col: usize) ?i64 {
        if (self.vtable.columnIsNull(self.ctx, @intCast(col))) return null;
        return self.vtable.columnInt64(self.ctx, @intCast(col));
    }

    pub fn isNull(self: *Statement, col: usize) bool {
        return self.vtable.columnIsNull(self.ctx, @intCast(col));
    }

    pub fn getAddress(self: *Statement, col: usize) !?Address {
        const text = self.getTextSlice(col) orelse return null;
        return Address.fromHex(text) catch null;
    }

    pub fn getHash(self: *Statement, col: usize) !?Hash {
        const text = self.getTextSlice(col) orelse return null;
        return Hash.fromHex(text) catch null;
    }
};
