# Database Backend Abstraction & PostgreSQL Support

This document describes how to **decouple the indexer from any single database** by introducing
a thin, pluggable *backend* layer, and how PostgreSQL is delivered as the second shipped backend
on top of that layer.

The original version of this plan scoped only "add PostgreSQL alongside SQLite." This revision
reframes the work around the real goal: a **modular storage layer** that can be attached to any
database. We ship and support exactly two backends — **SQLite** and **PostgreSQL** — but the seam
is open: a third party can add another backend (including a NoSQL store) by implementing one
interface, in their own code, without forking the indexer. No indexer capability is lost in the
process: the reorg undo-log, transactions/savepoints, the batched write buffer, schema migrations,
prepared-statement caching, and `RETURNING`/last-insert-id all keep working on every backend.

## Executive Summary

- **Goal:** abstract the DB layer behind a backend interface so SQLite and PostgreSQL are
  first-class, runtime-swappable backends — and third parties can plug in others without touching
  shipped code.
- **Dispatch mechanism:** a **runtime vtable** (`*anyopaque` + `*const VTable`) — the only one of
  the three candidate mechanisms (vtable / comptime-generic / tagged-union) that satisfies
  out-of-tree extensibility. Per-statement type-safety stays comptime *inside* each backend.
- **No ORM.** There is no production-grade Zig ORM as of mid-2026, and an ORM is a structural
  mismatch for reorg-critical SQL we must control byte-for-byte. We hand-roll a narrow interface
  and keep the SQL in our hands.
- **Drivers:** PostgreSQL via [pg.zig](https://github.com/karlseguin/pg.zig) (pure-Zig wire
  protocol, `zig-0.15` branch); SQLite keeps today's raw C bindings, now wrapped behind the
  interface.
- **The hard part:** the reorg undo-log is the single biggest portability risk. A code-grounded
  audit of all 60 protected-table capture sites settled the design: **server-side AFTER triggers are
  canonical for both shipped backends** (SQLite as-is; *generated* PL/pgSQL triggers for Postgres,
  from the same `PROTECTED_TABLES` arrays). Write-path `captureBefore` is the **portable fallback**
  for trigger-less/NoSQL backends only (`server_side_undo = false`). Triggers win because bulk/dynamic
  multi-row mutations are captured per-row in-engine for free — a single-key write-path helper would
  need bespoke predicate-duplicating re-SELECTs at the riskiest sites.
- **Estimated effort:** ~8–9 weeks total across 6 phases; the SQLite-only seam (Phase 0–3) is
  shippable on its own and de-risks everything before the first non-SQLite line of code.
- **Risk:** Low-to-moderate. The seam is introduced with zero behaviour change first; PostgreSQL
  and the portable undo path land behind capability flags and parity tests.

---

## Goals & Non-Goals

**Goals**

1. The indexer, API, and write buffer depend on a storage *interface*, never on a concrete DB.
2. SQLite and PostgreSQL ship in-tree and are selected at startup from config/env.
3. A third party can add a backend (SQL or NoSQL) by implementing one interface in their own
   package — no edits to shipped files, no recompilation of the core against a new type.
4. Zero loss of capability: reorg undo-log correctness, transactions + savepoints, batched writes,
   schema migrations, prepared-statement caching, `RETURNING`/last-insert-id.
5. Minimal churn from today's `Query` abstraction; idiomatic Zig; no measurable perf regression.

**Non-Goals**

- We do **not** ship NoSQL backends — only the SPI that makes them possible.
- We do **not** adopt an ORM or a query-DSL.
- We do **not** resurrect the per-file migration ladder; re-index-from-scratch stays the documented
  upgrade path (see [Schema & Migrations](#schema--migrations-per-backend)).
- The rainbow-table lookup DB (`src/rainbow/rainbow.zig`) stays a direct, SQLite-only embedded
  asset and is explicitly **out of scope** for the abstraction (see [Rainbow DB](#rainbow-table-db-out-of-scope)).

---

## Current Architecture (ground truth)

| Component | Details |
|-----------|---------|
| Database entry point | `src/storage/database.zig` (~1000 lines) — owns `db: ?*c.sqlite3` + a prepared-statement cache, applies the schema, installs reorg triggers |
| Query abstraction | `src/storage/query.zig` (~514 lines) — wraps SQLite prepared statements; **this is the seam** |
| Storage modules | ~18 modules under `src/storage/` |
| Schema | **One consolidated `schema/schema.sql`** (864 lines, 38 tables) + `schema/webhooks/*.sql` (2 files); `schema/migrations/` is **empty** |
| Reorg undo-log | `src/storage/reorg_undo.zig` — SQLite **triggers** + `PRAGMA recursive_triggers=ON` |

> The previous plan claimed "13 migration files" and a 32-table schema — both stale. The real
> schema is a single consolidated file applied at init, with an intentionally empty migration
> ladder and an idempotent `migrate()` ALTER hook.

### The `Query` abstraction (the seam)

`Query` is the natural seam, but today it is *deeply* SQLite-bound and must become an interface:

```zig
pub const Query = struct {
    db: ?*c.sqlite3,            // <- SQLite handle
    stmt: ?*c.sqlite3_stmt,     // <- SQLite prepared statement
    param_idx: c_int,           // sequential 1-based bind cursor
    bound_strings: [32]?[]u8,   // tracked copies freed on reset/deinit
    is_cached: bool,            // cached stmts are reset, never finalized
    // ...
};
```

What leaks SQLite specifics today:

- It holds `*c.sqlite3` / `*c.sqlite3_stmt` and **re-exports the C namespace** as
  `pub const c = db_module.c;`, which several modules import.
- Placeholders are SQLite positional `?`; binds advance an **implicit sequential index**; columns
  are read **by index**; errors are `SQLITE_OK/ROW/DONE`.
- The statement cache (`Database.stmt_cache: StringHashMap(*c.sqlite3_stmt)`) is keyed by raw SQL.

The *shape* of the API, however, is already backend-neutral: `init/initCached`, `bindText/bindInt64/
bindNull/bindAddress/bindHash/bindOptional*`, `exec/step/changes`, `getText/getTextSlice/getInt64/
getOptionalInt64/isNull/getAddress/getHash`. Preserving these signatures keeps churn tiny.

### Storage modules — Query adoption

| Group | Modules | DB access |
|-------|---------|-----------|
| Already on `Query` (import-swap only) | `names.zig`, `events.zig`, `resolvers.zig`, `sync.zig`, `registrations.zig`, `roles.zig`, `accounts.zig`, `registry_entries.zig`, `v1_controllers.zig` | Yes |
| Raw C API (must be ported) | `ensip16.zig` (~109 calls), `webhooks.zig` (~65), `unknown_labels.zig` (~48), `transactions.zig` (raw `BEGIN/COMMIT/ROLLBACK`) | No |
| Trigger-driven | `reorg_undo.zig` | Special — see below |

Only **four storage modules** do real raw C — but they are *not* the whole raw-C surface: three
**non-storage** files also call the re-exported `db.c` directly (see Coupling points below). All of
these gate any non-SQLite backend; their call counts are known and bounded. `webhooks.zig:65` is the
**only** `last_insert_rowid` site; `src/webhooks/manager.zig` holds the **only** `RETURNING` clause.

### Coupling points beyond the storage layer

- `src/storage/transactions.zig` issues raw `c.sqlite3_exec("BEGIN TRANSACTION"/"COMMIT"/"ROLLBACK")`.
- `src/rainbow/rainbow.zig` has its **own independent `@cImport("sqlite3.h")`** and a separate
  read-only connection (huge `cache_size`/`mmap_size`, a single `lookup_stmt`). This is a static
  label dictionary, not indexer state — it stays out of scope.
- `pub const c` re-exported from `query.zig` is consumed for **real raw-C calls well beyond the
  storage modules**: `src/webhooks/manager.zig` (~63 calls, including the only `RETURNING` clause),
  `src/indexer/label_backfill.zig` (~14), and `src/indexer/v1/handlers.zig` (~5) all do raw
  prepare/bind/step against `database.db`. Removing `pub const c` requires porting these too.
- The GraphQL/API resolvers and the write buffer go through storage-module functions + `Query`,
  **not** raw SQL — so that part of the seam is clean; the raw-C exceptions above are the work items.

### SQL-dialect feature inventory (measured)

| Feature | Occurrences | SQLite form | PostgreSQL form |
|---------|-------------|-------------|-----------------|
| `AUTOINCREMENT` | 32 | `INTEGER PRIMARY KEY AUTOINCREMENT` | `BIGSERIAL PRIMARY KEY` (DDL only) |
| `PRAGMA` | 27 | `PRAGMA …` | session `SET` / pool config (driver-internal) |
| `INSERT OR REPLACE` | 25 | verbatim | `INSERT … ON CONFLICT(keys) DO UPDATE` |
| `INSERT OR IGNORE` | 21 | verbatim | `INSERT … ON CONFLICT DO NOTHING` |
| `ON CONFLICT` | 11 | verbatim | verbatim (different conflict syntax) |
| `strftime('%s','now')` | 10 | verbatim | `EXTRACT(EPOCH FROM now())::bigint` |
| `RETURNING` | 1 (`webhooks/manager.zig`) | supported | supported |
| `last_insert_rowid` | 1 | `sqlite3_last_insert_rowid` | `RETURNING id` |

---

## The Reorg Undo-Log: the defining constraint

`src/storage/reorg_undo.zig` makes `rollbackToBlock(N)` bit-equivalent to a clean sync at block `N`.
It is the most SQLite-specific subsystem in the codebase, and **how it ports decides the whole
architecture**.

How it works today:

- **AFTER UPDATE / DELETE / INSERT triggers** on ~21 `PROTECTED_TABLES` (+ `accounts`,
  `v1_controllers`) copy the OLD/NEW row — serialized with `json_object(...)` over every column —
  into a `reorg_undo` table, tagged with the block from a `reorg_cursor`.
- Triggers are generated from the live schema via **`PRAGMA table_info`**, so new columns are
  captured automatically.
- Many derived tables are rewritten with `INSERT OR REPLACE`, whose *implicit* row delete only
  fires the AFTER DELETE capture trigger because **`PRAGMA recursive_triggers = ON`**
  (`database.zig`). This is load-bearing.
- `rollbackToBlock(N)` reverse-applies captured rows newest-first via `INSERT OR REPLACE` +
  `json_extract(?1,'$.col')`, then prunes the replayed entries.

Why this does not port mechanically:

| Mechanism | SQLite | PostgreSQL | NoSQL |
|-----------|--------|------------|-------|
| Triggers | yes | yes (PL/pgSQL, different syntax) | **none** |
| `recursive_triggers` semantics | implicit-delete fires AFTER DELETE | `ON CONFLICT DO UPDATE` fires **UPDATE, not DELETE** | n/a |
| Row→JSON | `json_object(...)` | `to_jsonb(OLD)` / `row_to_json` | serializer |
| Schema introspection | `PRAGMA table_info` | `information_schema.columns` | n/a |
| JSON extract | `json_extract(?1,'$.c')` | `(?1::jsonb->>'c')` | n/a |

Triggers don't exist for a KV/document store, so they can't be the *universal* substrate — but they
*are* the best mechanism for both shipped SQL backends. A code-grounded audit (see the
[capture-site inventory appendix](#appendix-reorg-capture-site-inventory)) inventoried **every**
protected-table mutation site to settle this: **~60 sites require capture**, exercising 35 `UPDATE`,
13 `INSERT OR REPLACE`, 12 `DELETE`, and 2 active-table `INSERT` operations (upsert sites span an
insert and an on-conflict-update branch, so per-op tallies overlap slightly), and several are *bulk/dynamic*
single-statement, multi-row mutations — `setRegistriesReachability` builds an `IN(...)` over a
subtree; `materializePccDomainExpiry` is predicate-less over *every* wrapped name;
`recursivelyGcEmptyDomain` cascades a DELETE down a parent chain. A per-row AFTER trigger captures
every affected row of those automatically, in-engine, with no extra round-trips. A single-key
write-path helper cannot — for the bulk sites it would have to re-SELECT the affected set by
*re-deriving each statement's WHERE predicate*, bespoke capture logic at exactly the riskiest sites
(the silent-divergence class the 2026-06-02 audit had to chase).

**Decision (settled by the audit):** **server-side AFTER triggers are canonical for both shipped
backends.** SQLite keeps today's audited triggers; **PostgreSQL gets *generated* PL/pgSQL triggers**
installed from the same `PROTECTED_TABLES`/`REORG_ACTIVE_TABLES` arrays (`to_jsonb(OLD)` +
`information_schema.columns` — the SQLite trigger set transposed). The SQLite implicit-DELETE vs
Postgres `ON CONFLICT DO UPDATE` difference is just a per-backend *trigger-set* detail (both restore
the same OLD row), not a reason to abandon triggers. **Write-path `captureBefore` is demoted to the
portable *fallback*** for trigger-less backends (NoSQL/KV), selected by `server_side_undo = false`.
This keeps two audited, schema-driven, multi-row-correct server-side paths for the backends real
users run, and reserves the hand-instrumented path for backends that have no alternative. See
[Reorg undo-log strategy](#reorg-undo-log-strategy).

---

## Library Research & Decisions

Surveyed mid-2026 (web-verified, high confidence). Full source list at the end.

| Library | Kind | Pure Zig? | Zig 0.15.x | Maint. | Stars | Verdict |
|---------|------|-----------|------------|--------|-------|---------|
| **karlseguin/pg.zig** | Postgres driver (native wire) | Yes (no libpq) | `zig-0.15` branch | Active (commits Jun 2026) | 559 | **Adopt** |
| karlseguin/zqlite.zig | SQLite wrapper over C API | thin wrapper | `zig-0.15` branch | Active | 174 | Optional |
| vrischmann/zig-sqlite | SQLite C bindings + comptime check | C-binding | `zig-0.15.1` branch | Maintainer on hiatus | 599 | Don't migrate |
| HARMONICOM/dig | Query builder (Drizzle-style) | Yes (PG + MySQL) | 0.15.2+ | New (v0.1.2, Nov 2025) | 10 | Avoid (no SQLite) |
| Tony-ArtZ/zorm | ORM (.zorm + codegen) | Yes (PG + SQLite) | unspecified | WIP | 36 | Avoid |
| tinyzimmer/sqlc-gen-zig | SQL-first codegen (targets pg.zig + zqlite) | codegen | driver-pinned | Stalled (2025) | 27 | Avoid dep, borrow philosophy |
| ziglibs/nektro/aeronavery ORMs | Legacy ORM experiments | Zig | No (pre-0.11) | Abandoned | low | Ignore |

### Decision 1 — No ORM, hand-roll the interface

There is no production-grade Zig ORM. Beyond immaturity, ORMs are the wrong tool here: Zig has no
runtime reflection (forcing heavy comptime metaprogramming that
[matklad himself warns against](https://matklad.github.io/2025/03/19/comptime-zig-orm.html)); the
indexer needs precise, auditable control over reorg-critical SQL and exact trigger firing order,
which an ORM hides or reorders; and an ORM would dictate the backend set and its own DSL, fighting
the third-party goal. We borrow only the *SQL-first philosophy* of `sqlc-gen-zig` (keep the SQL in
our hands), not its toolchain.

### Decision 2 — PostgreSQL driver: pg.zig

The clear winner: most mature and most active Postgres library in Zig, **pure-Zig wire protocol**
(no libpq C dependency → simpler cross-platform builds), with a real connection **Pool** (sustained
concurrent writes, reconnection) and **LISTEN/NOTIFY** (useful for reorg/notification signaling).
Pin the **`zig-0.15`** branch — the version-specific branch karlseguin maintains (`zig-0.15`,
`zig-0.14`, …; `master` targets 0.16). It tracks Zig 0.15.x (project min 0.15.2); follow its move to
0.16 when the project upgrades.

**API mapping verified against `zig-0.15` source** (`src/stmt.zig`, `src/conn.zig`, `src/result.zig`).
The design's `Statement` maps onto pg.zig's `Stmt` *cleanly*, because pg.zig binds **sequentially**,
not only via comptime tuples:

| Our `Statement` | pg.zig `zig-0.15` | Note |
|-----------------|-------------------|------|
| `prepare(sql)` | `conn.prepare(sql)` → `stmt.prepareForBind(n)` | driver counts `n` while rewriting `?`→`$n`; this is the **dynamic-arity** path the tuple-based `conn.query(sql, .{…})` can't do — essential for `buildInClause`/filters |
| `bindText/bindInt64/bindNull` | `stmt.bind(value: anytype)` | sequential, internal `param_index`; driver calls it with `[]const u8`/`i64`/`?T` so `anytype` monomorphizes to a few types |
| `exec` / `step` | `stmt.execute() !*Result` → `result.next()` | |
| `getTextSlice` / `getText` | `row.get([]const u8, i)` (borrowed until next `next()`/`deinit`) / `.{.dupe=true}` | lifetime matches our borrowed-vs-owned contract exactly |
| `prepareCached(sql)` | `conn.prepareOpts(sql, .{.cache_name=…})` + `conn.deallocate(name)` | pg.zig's cache is **named & per-connection**, not auto-by-SQL — the driver derives a stable `cache_name` (e.g. a hash of the SQL) |
| `Tx.begin/commit/rollback` | `conn.begin/commit/rollback` | savepoints have no dedicated API → plain `conn.exec("SAVEPOINT …")` |
| `RETURNING` | normal `query` returning rows; read col 0 | `caps.returning = true` |
| backend `Pool` | `pg.Pool.init(allocator, .{.size,.connect,.auth})` | **no `io` parameter** on `zig-0.15` (that's a 0.16-only addition) — design assumed correctly |

Two pg-driver lifetime nuances to handle: (a) after `stmt.execute()`, **do not** call `stmt.deinit()` —
deinit the returned `*Result` instead, so the PG `Statement` wrapper tracks pre- vs post-execute state
in `finalize`; (b) prepared statements + the named cache are **per-connection**, so a `Statement`/`Tx`
must pin the acquired `*Conn` for its lifetime (`pool.acquire()` … `pool.release(conn)`; `queryOpts`
also offers `.release_conn`). Both are already reflected in the [Memory & ownership model](#memory--ownership-model).

### Decision 3 — SQLite driver: keep the raw C bindings

The existing bindings already give full, auditable control over the reorg-critical SQL, triggers,
and `INSERT OR REPLACE`/undo-log semantics — exactly what must *not* be handed to a wrapper.
`zqlite.zig` is only a convenience layer over the same C API; `zig-sqlite`'s comptime bind-checking
is appealing but it pins 0.15.1, has no stable releases, and its maintainer is on hiatus — fragile
for a correctness-critical path. If we want zig-sqlite-style safety, we add comptime bind-checking
*inside our own* `Statement` (we control it).

### Decision 4 — Dispatch mechanism: runtime vtable

| Mechanism | Third-party pluggable? | Cost | Verdict |
|-----------|------------------------|------|---------|
| **Runtime vtable** (`*anyopaque` + `*const VTable`) | **Yes** — implement the vtable out-of-tree, hand us a `Backend` | one indirect call/query (noise vs socket/C-ABI I/O) | **Chosen** |
| Comptime-generic over backend | No — monomorphizes the whole indexer per backend; third parties must fork + recompile core; `-Dbackend=both` duplicates ~4400 LOC of storage | zero-cost dispatch, but compile/binary blowup | Rejected (good ideas grafted) |
| Tagged union `union(enum){sqlite,postgres}` | No — closed enum; every new backend edits the enum and every switch | cheap | Rejected |

The vtable is the only mechanism that satisfies *"third parties add backends without us shipping
them."* Dispatch cost is irrelevant: every DB op already crosses the SQLite C ABI or a Postgres
socket, so one indirect call is nanosecond-scale noise. We **graft** the comptime-generic design's
genuinely good ideas: comptime-typed bind/column paths *inside* each backend, a `verifyVTable`
compile-time conformance check, a `gen_pg_schema.py` schema transpiler, and a `-Dbackend=<…>` build
option for lean single-backend production binaries.

---

## Target Architecture

A new `src/storage/backend.zig` defines the SPI; two shipped drivers live under
`src/storage/drivers/`. `Database` keeps its public type (every caller still passes `*Database`) but
internally holds a `Backend` instead of `?*c.sqlite3`.

```
src/storage/
├── backend.zig          NEW — Backend, VTable, Statement, StmtVTable,
│                              Capabilities, Dialect, Tx, Savepoint, Config,
│                              selectBackend(), verifyVTable()   ← the third-party SPI
├── drivers/
│   ├── sqlite.zig       NEW — wraps today's raw C bindings behind the vtable
│   └── postgres.zig     NEW — pg.zig-based driver
├── database.zig         holds `backend: Backend`; open()/fromBackend(); forwards to vtable
├── query.zig            `pub const Query = Statement;` + shared helpers (transitional alias)
└── … storage modules    import-swap; route divergent SQL through Dialect
```

### Core interfaces (Zig sketches)

**Backend handle + capabilities** — the erased handle the whole storage layer is written against:

```zig
pub const Placeholder = enum { qmark, dollar };

pub const Capabilities = struct {
    placeholder: Placeholder,
    returning: bool,        // can append RETURNING instead of last-insert-id
    savepoints: bool,       // SAVEPOINT / RELEASE / ROLLBACK TO supported
    server_side_undo: bool, // backend captures undo itself (SQLite triggers); else write-path
    pooled: bool,           // connection pool (Postgres) vs single conn (SQLite)
};

pub const TxMode = enum { deferred, immediate };

pub const VTable = struct {
    close:        *const fn (ctx: *anyopaque) void,
    prepare:      *const fn (ctx: *anyopaque, sql: []const u8, cached: bool) anyerror!Statement,
    execRaw:      *const fn (ctx: *anyopaque, sql: []const u8) anyerror!void,
    applySchema:  *const fn (ctx: *anyopaque, a: std.mem.Allocator) anyerror!void,
    begin:        *const fn (ctx: *anyopaque, m: TxMode) anyerror!void,
    commit:       *const fn (ctx: *anyopaque) anyerror!void,
    rollback:     *const fn (ctx: *anyopaque) anyerror!void,
    savepoint:    *const fn (ctx: *anyopaque, name: []const u8) anyerror!void,
    release:      *const fn (ctx: *anyopaque, name: []const u8) anyerror!void,
    rollbackTo:   *const fn (ctx: *anyopaque, name: []const u8) anyerror!void,
    lastInsertId: *const fn (ctx: *anyopaque) i64,
    changes:      *const fn (ctx: *anyopaque) u32,
    capabilities: *const fn (ctx: *anyopaque) Capabilities,
    dialect:      *const fn (ctx: *anyopaque) *const Dialect,
};

pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub inline fn prepare(self: Backend, sql: []const u8, cached: bool) !Statement {
        return self.vtable.prepare(self.ptr, sql, cached);
    }
    pub inline fn caps(self: Backend) Capabilities { return self.vtable.capabilities(self.ptr); }
    pub inline fn dialect(self: Backend) *const Dialect { return self.vtable.dialect(self.ptr); }
    // … thin inline forwarders for begin/commit/rollback/savepoint/lastInsertId/…
};

/// Comptime contract check a driver calls on its own VTable literal to fail early.
pub fn verifyVTable(comptime _: VTable) void {}
```

**Statement** — a drop-in for today's `Query`: same sequential 1-based bind cursor, same
index-based column reads, same call shape (`bindText`/`bindInt64`/`bindAddress`/`getTextSlice`/…).
The `Address`/`Hash` hex binders are **shared default methods** (backend-independent); only the raw
bind/column primitives dispatch through `StmtVTable`. The one deliberate simplification vs today:
binds **copy into the driver** (see [Memory & ownership model](#memory--ownership-model)), so the
`bound_strings[32]` tracking, the `MAX_BOUND_STRINGS` cap, and the "string must outlive `step`"
hazard all **disappear**. The nine already-on-`Query` modules change only their import line.

```zig
pub const StmtVTable = struct {
    bindText:  *const fn (ctx: *anyopaque, idx: u16, v: []const u8) anyerror!void, // driver COPIES v; v need only live for the call
    bindInt64: *const fn (ctx: *anyopaque, idx: u16, v: i64) anyerror!void,
    bindNull:  *const fn (ctx: *anyopaque, idx: u16) anyerror!void,
    exec:      *const fn (ctx: *anyopaque) anyerror!void,
    step:      *const fn (ctx: *anyopaque) anyerror!bool,
    colText:   *const fn (ctx: *anyopaque, col: u16) ?[]const u8, // borrowed until next step
    colInt64:  *const fn (ctx: *anyopaque, col: u16) i64,
    colIsNull: *const fn (ctx: *anyopaque, col: u16) bool,
    changes:   *const fn (ctx: *anyopaque) u32,
    reset:     *const fn (ctx: *anyopaque) void,
    finalize:  *const fn (ctx: *anyopaque) void,
};

pub const Statement = struct {
    ctx: *anyopaque,              // SQLite: the sqlite3_stmt itself (zero per-query alloc). Postgres: a heap wrapper.
    vtable: *const StmtVTable,
    allocator: std.mem.Allocator, // ONLY for the allocating getText(); binds are not tracked here
    param_idx: u16 = 1,
    is_cached: bool = false,

    // Binds copy nothing here: the driver's bindText copies (SQLite SQLITE_TRANSIENT / pg param
    // buffer), so `v` need only live for the call — no tracking array, no 32-slot cap.
    pub fn bindText(self: *Statement, v: []const u8) !void {
        try self.vtable.bindText(self.ctx, self.param_idx, v); self.param_idx += 1;
    }
    pub fn bindInt64(self: *Statement, v: i64) !void {
        try self.vtable.bindInt64(self.ctx, self.param_idx, v); self.param_idx += 1;
    }
    pub fn bindAddress(self: *Statement, a: Address) !void {
        var b: [42]u8 = undefined; try self.bindText(a.toHexBuf(&b)); // stack buffer OK — driver copies
    }
    pub fn step(self: *Statement) !bool { return self.vtable.step(self.ctx); }
    pub fn getTextSlice(self: *Statement, col: usize) ?[]const u8 { // borrowed: valid until next step/reset/deinit
        return self.vtable.colText(self.ctx, @intCast(col));
    }
    pub fn getText(self: *Statement, col: usize) !?[]u8 {            // allocates; caller owns the result
        const s = self.vtable.colText(self.ctx, @intCast(col)) orelse return null;
        return try self.allocator.dupe(u8, s);
    }
    pub fn deinit(self: *Statement) void {
        if (self.is_cached) self.vtable.reset(self.ctx)  // cache owns the stmt — reset, never finalize
        else self.vtable.finalize(self.ctx);             // finalize stmt + free any per-call wrapper
    }
    // bindHash/bindOptional*/getInt64/getOptionalInt64/isNull/changes — as today
};
```

**Database** — keeps the public surface; `Query.init(db,sql)` becomes `db.prepare(sql)`:

```zig
pub const Database = struct {
    allocator: std.mem.Allocator,
    backend: Backend,
    chain_id: u64 = 0,

    pub fn open(a: std.mem.Allocator, cfg: Config) !Database {
        return fromBackend(a, try selectBackend(a, cfg));
    }
    pub fn fromBackend(a: std.mem.Allocator, backend: Backend) !Database {
        const self = Database{ .allocator = a, .backend = backend };
        try backend.vtable.applySchema(backend.ptr, a); // DDL + reorg tables (+ triggers if server_side_undo)
        return self;
    }
    pub fn prepare(self: *Database, sql: []const u8) !Statement { return self.backend.prepare(sql, false); }
    pub fn prepareCached(self: *Database, sql: []const u8) !Statement { return self.backend.prepare(sql, true); }
    pub fn exec(self: *Database, sql: []const u8) !void { return self.backend.vtable.execRaw(self.backend.ptr, sql); }
    pub fn dialect(self: *Database) *const Dialect { return self.backend.dialect(); }
    pub fn caps(self: *Database) Capabilities { return self.backend.caps(); }
    pub fn lastInsertId(self: *Database) i64 { return self.backend.vtable.lastInsertId(self.backend.ptr); }
};

pub const Query = Statement; // compat alias — removed once modules migrate
```

**Tx / Savepoint** — RAII guards replacing `transactions.zig`'s raw calls and `sync.zig`'s
`BEGIN IMMEDIATE`. Savepoints map identically on SQLite and Postgres; a backend with
`caps.savepoints == false` degrades nesting to the outer transaction (correct, coarser):

```zig
pub const Tx = struct {
    db: *Database, done: bool = false,
    pub fn begin(db: *Database, m: TxMode) !Tx { try db.backend.vtable.begin(db.backend.ptr, m); return .{ .db = db }; }
    pub fn commit(self: *Tx) !void { try self.db.backend.vtable.commit(self.db.backend.ptr); self.done = true; }
    pub fn deinit(self: *Tx) void { if (!self.done) self.db.backend.vtable.rollback(self.db.backend.ptr) catch {}; }
};
```

### Backend selection

Resolved **once** at startup over the two shipped drivers; third parties bypass it entirely:

```zig
pub fn selectBackend(a: std.mem.Allocator, cfg: Config) !Backend {
    return switch (cfg.backend_kind) {            // from DATABASE_BACKEND / --backend, default .sqlite
        .sqlite => @import("drivers/sqlite.zig").open(a, cfg),
        .postgres => @import("drivers/postgres.zig").open(a, cfg),
    };
}
// Third party:  const be = try MyBackend.open(a, cfg);  var db = try Database.fromBackend(a, be);
```

### Memory & ownership model

Because the vtable erases types, leaks and use-after-free are the failure mode — so the ownership
rules are pinned down here as a **Phase-0 prerequisite**. The result is *simpler* than today's
`Query`, not more complex.

- **`Statement` is a value; SQLite adds no per-query heap.** It holds only `ctx`, `vtable`,
  `allocator`, `param_idx`, `is_cached`. For SQLite, `ctx` **is** the `sqlite3_stmt*` — zero
  allocation per query, preserving today's value-type cost; the driver recovers the connection it
  needs for `changes()`/error text via `sqlite3_db_handle(stmt)`. Backends whose statement object
  can't recover its connection (Postgres/pg.zig) allocate a small wrapper in `prepare()` and free it
  in `finalize()` — negligible next to a network round-trip.
- **Binds copy into the driver — no caller-side tracking.** `StmtVTable.bindText`'s contract is *"the
  slice need only be valid for the duration of the call."* The SQLite driver binds with
  `SQLITE_TRANSIENT` (SQLite copies internally — already used in `webhooks.zig`); Postgres serializes
  into its param buffer. This **deletes** today's `bound_strings[32]` array, the `MAX_BOUND_STRINGS`
  cap, the immediate-free fallback, and the "string must outlive `step`" hazard. `bindAddress`/
  `bindHash` format hex into a **stack** buffer and pass it through. Copy count is unchanged (one
  copy either way).
- **SQL text is transient.** `prepare()` allocates a NUL-terminated SQL copy only to call
  `sqlite3_prepare_v2`, then frees it immediately — `prepare_v2` keeps its own copy (for
  `sqlite3_sql()`/error messages), so the statement never needs the caller's text. SQL is never
  stored on `Statement`.
- **Column results.** `getTextSlice`/`colText` return a **borrowed** slice valid only until the next
  `step()`/`reset()`/`deinit()` (today's contract). The allocating `getText(col)` dups via
  `Statement.allocator` and the **caller owns** it — the only reason `Statement` carries an allocator.
- **Statement cache — owned by the driver.** The SQLite driver owns the `SQL → sqlite3_stmt` cache
  (moved verbatim from `Database`), its key strings, and its statements. A cached `Statement`
  **borrows** the `sqlite3_stmt`; its `deinit` calls `vtable.reset` (`sqlite3_reset` +
  `sqlite3_clear_bindings`) and **must not finalize** — the cache keeps it alive. The driver's
  `close()` finalizes **every** cached statement and frees its key **before** `sqlite3_close` (today's
  exact order, `database.zig:335-346`; `sqlite3_close` fails with statements still open). `prepare()`
  uses `errdefer` to finalize the statement and free the key if the cache insert fails. The cache is
  bounded in practice by the ~63 distinct `prepareCached` SQL literals — dynamic `allocPrint` SQL uses
  the non-cached `prepare`, so it never bloats the cache.
- **Invariants the abstraction must preserve (pre-existing, now explicit):** *(1) Same-SQL
  re-entrancy* — two live `prepareCached` statements for the **same** SQL share one underlying
  `sqlite3_stmt` and would corrupt each other; a cached statement must be `deinit`-ed before
  re-preparing the same SQL on the same connection. *(2) No eviction* — the cache never evicts, so a
  borrowed statement is never finalized out from under a live `Statement`; a future bounded cache
  must skip in-use statements. *(3) Borrowed-slice invalidation* — column slices die at the next
  `step`/`reset`/`deinit`.
- **Transactions.** `Tx`/`Savepoint` are RAII guards: `deinit` rolls back if `commit`/`release`
  wasn't called. They borrow `*Database`; they own no statements.
- **Postgres-specific (Phase 4).** pg.zig prepared statements and the cache are **per-connection**, so
  a `Statement`/`Tx` must **pin** its connection for its whole lifetime and never share a prepared
  statement across connections. How connections are provisioned (indexer writer vs API reader pool) is
  the [Connection routing & pooling](#connection-routing--pooling) model below.

### Connection routing & pooling

The process/threading topology (verified from source) decides this:

- **Separate binaries / processes:** `ensv2-indexer*` and `ensv2-api` never share a connection.
- **Indexer process:** a single-threaded write loop (`indexProtocol` runs on the main thread); the
  status server thread (`src/server/status.zig`) touches **no** DB. So the indexer needs **one writer
  connection**, period.
- **API process:** **thread-per-connection** — `server.accept()` then `std.Thread.spawn` per request
  (`api/server.zig:225`), all threads sharing **one** read-only `*Database` plus a *separate*
  `webhook_database`, made safe today only by `sqlite3_config(SERIALIZED)` (an internal mutex).

A single shared connection works for SQLite (serialized mutex) but **cannot** work for Postgres —
pg.zig connections aren't concurrent-safe and prepared statements are per-connection. So the
abstraction adds a thin **connection provider** above `Database`:

```zig
pub const AccessMode = enum { writer, reader };
pub const Pool = struct {                       // owned by each process; opened from Config
    pub fn open(a: std.mem.Allocator, cfg: Config) !Pool { ... }
    pub fn acquire(self: *Pool, mode: AccessMode) !*Database { ... }  // a session bound to ONE conn
    pub fn release(self: *Pool, db: *Database) void { ... }
    pub fn deinit(self: *Pool) void { ... }
};
```

A `*Database` is a **session** = exactly one connection (with its own prepared-stmt cache), used by
**one thread at a time**; `acquire`/`release` is the only thread-safe handoff. Usage:

- **Indexer:** `acquire(.writer)` **once**, pin it for the whole run (`defer release`); the batch loop's
  `Tx` + `prepare` all run on that one conn. Single writer ⇒ no contention.
- **API:** each `handleConnectionThread` does `const db = try pool.acquire(.reader); defer pool.release(db);`
  and runs the request's resolvers on `db`; webhook-admin writes `acquire(.writer)`. (Requires the
  small refactor: `Server`/`GraphQLHandler` hold a `*Pool` and take a per-request `*Database` instead
  of a shared one — `api/server.zig`, `api/handler.zig`.)

Per backend:

- **SQLite — degenerate pool, zero behaviour change:** every `acquire` returns the *one* shared
  serialized connection; `release` is a no-op. Identical to today. (Optional later optimization: a
  small pool of separate read connections to the same WAL file for true read concurrency — each gets
  its own stmt cache, removing the serialized-mutex bottleneck.)
- **PostgreSQL — real pools:** the indexer opens a **writer pool of 1** (the single writer); the API
  opens a **reader pool of N** (`DATABASE_POOL_SIZE`, default ~10). Each pooled conn carries its own
  pg.zig named statement cache, so hot GraphQL queries are prepared once per conn and reused across
  requests landing on it. The per-request-conn model also **avoids the shared-statement-cache race**
  that the single-SQLite-conn path leans on `SERIALIZED` to prevent.

Invariants: (1) a `Database`/`Tx`/`Statement` is single-thread-at-a-time; (2) the reorg cursor is set
**only** by the indexer's writer conn, so API reads/webhook-writes never trigger reorg capture; (3)
on Postgres the indexer (writer process) and API (reader + occasional webhook-writer process) run
**concurrently** against one DB via MVCC — unlike SQLite's single-writer file. The **webhook DB** is a
separate SQLite *file* today; on Postgres the webhook tables live in the same database (acquire a conn
and write them — concurrent webhook writes are fine under MVCC).

`Pool`/`AccessMode` are defined in `backend.zig` (Phase 0, SQLite degenerate); the API adopts
acquire-per-request alongside; the real Postgres writer/reader pools land in Phase 4. `Database.open(cfg)`
stays as a convenience (opens a size-1 pool + `acquire`) for tools and tests.

> **Shipped reality (2026-06-06, post-Phase-5 follow-on):** the pool lives in
> `src/storage/pool.zig` (not backend.zig — it needs config + both drivers), and TWO sketch
> details were dropped for cause. (1) **No `AccessMode`** — the API process performs zero
> writes to the main database (webhook admin writes go to the manager's separate webhook DB),
> so a plain reader pool is the honest surface. (2) **No degenerate shared-SQLite session** —
> review showed the "SERIALIZED makes one shared conn safe" assumption was wrong at the Zig
> layer (the per-connection statement *cache* is an unsynchronized hash map, and two threads
> hitting the same cached `sqlite3_stmt` interleave reset/bind/step — a pre-existing race the
> old single-shared-`*Database` API had). Every backend now uses exclusive checkout: SQLite
> gets `DATABASE_POOL_SIZE` read connections to the file (`:memory:`/empty-path pins to 1),
> PG gets `DATABASE_POOL_SIZE` sessions. Shutdown is closed-state + broadcast (parked
> acquirers fail `PoolClosed`; `deinit` blocks until all sessions return; double-release is
> an unconditional panic). The indexer keeps its single pinned writer (no pool needed).

### Read-path typing — coercing column getters

SQLite is dynamically typed; pg.zig's `row.get(T, i)` is **strict** (wrong `T` → runtime error). A
code-grounded audit of **every** read site settled the risk: **~290 read sites, 0 type mismatches**,
no `SELECT *`, and every dynamic query interpolates only the `WHERE`/`ORDER`/`LIMIT` suffix — the
projection (column list/order) is always static, so no ordinal fragility. The storage code already
reads each column with a getter matching its schema type (`token_id`/hashes/addresses as TEXT;
blocks/timestamps/expiry as INTEGER; the 10 boolish INTEGERs via `getBool`).

So the fix lives in **one place** — the Postgres driver implements `StmtVTable.colText`/`colInt64`/
`colIsNull` as **coercing** (mimicking `sqlite3_column_text`/`_int64` via pg.zig's raw column
bytes + OID, *not* the strict `row.get`):

- `colInt64(i) → i64`: widen `int2/int4/int8`, parse `numeric` (aggregates) and `text-of-int`; NULL
  → 0 (matches `sqlite3_column_int64`; nullable sites already guard via `colIsNull`). Unparseable
  text→int is a **driver assertion (panic in debug)**, never a silent 0.
- `colText(i) → ?[]const u8`: text/varchar borrowed as-is; other types formatted to their text repr;
  NULL → null. Makes `getTextSlice`/`getText`/`getAddress`/`getHash` (parse hex *from* text) work
  uniformly, including u256-as-TEXT (`token_id`, `canonical_id`, `wrapper_fuses`, `base_cost`,
  `premium`, `role_bitmap`).
- `colIsNull(i)` true iff SQL NULL; `getBool` stays `colInt64(i) != 0`.

Result: the nine `Query` modules and the legacy `sqlite3_column_*` readers need **zero read-site
edits**. Coercion fixes column *type*, not *order*, so it relies on the [transpiler type-class
rules](#schema--migrations-per-backend) (B1–B3) and a no-`SELECT *` lint. Three things coercion
**cannot** cover, handled elsewhere: (1) the lone real `BOOLEAN` (`v1_controllers.is_active`) and its
integer-literal *writes* → transpiler rule B2; (2) ordinal fragility from a future `SELECT *` → lint;
(3) `reorg_undo.zig`'s `PRAGMA table_info` introspection (reads col 1=name, col 5=pk) → already
routed through `dialect.introspectColumns`.

---

## Dialect strategy

Dialect lives in the **driver + a small shared builder**, never in business logic. We explicitly
reject the old plan's blanket `sql.replace("INSERT OR REPLACE", …)` translator: it is **unsound**,
because it cannot rewrite `INSERT OR REPLACE` → `ON CONFLICT` without knowing the conflict-key
column list. Instead:

| Difference | Where handled | How |
|------------|---------------|-----|
| `?` vs `$N` placeholders | **Postgres driver `prepare()`** | Storage modules keep writing `?`. A one-pass, **literal-aware lexer** renumbers the k-th `?` → `$k`, skipping `?` inside string/identifier/dollar-quoted literals and comments. Memoized per unique SQL, so it is off the hot loop. |
| `INSERT OR REPLACE/IGNORE` ↔ `ON CONFLICT` | **`dialect.upsert(...)` builder** | Callers stop writing the raw verb at divergent sites and call `dialect.upsert(table, cols, conflict_cols, .replace\|.ignore)`. Conflict keys come from the known schema PKs. |
| `AUTOINCREMENT` | **per-backend schema file** (DDL only) | `INTEGER PRIMARY KEY AUTOINCREMENT` → `BIGSERIAL PRIMARY KEY` |
| `last_insert_rowid` / `RETURNING` | **code branch on `caps.returning`** | SQLite: `exec` then `db.lastInsertId()`. Postgres: append `dialect.returning("id")`, read column 0. |
| `strftime('%s','now')` | mostly **schema DEFAULTs**; few runtime via `dialect.nowEpoch` | `EXTRACT(EPOCH FROM now())::bigint` |
| `PRAGMA` | **driver-internal** (`open`/`applySchema`) | SQLite issues the 7-PRAGMA block; Postgres translates intent to `SET` (`synchronous_commit`, `statement_timeout`) and no-ops the rest |
| `PRAGMA table_info` (reorg introspection) | **`dialect.introspectColumns`** | SQLite `PRAGMA table_info` vs Postgres `information_schema.columns` |
| row→JSON / JSON extract (reorg) | **`dialect.jsonObject` / `dialect.jsonExtract`** | `json_object(...)`/`json_extract` vs `jsonb_build_object`/`->>'…'` |

```zig
pub const ConflictAction = enum { replace, ignore };
pub const Dialect = struct {
    placeholder: Placeholder,
    upsert:    *const fn (a: std.mem.Allocator, table: []const u8, cols: []const []const u8,
                          conflict: []const []const u8, action: ConflictAction) anyerror![]u8,
    returning: *const fn (a: std.mem.Allocator, col: []const u8) anyerror![]const u8,
    nowEpoch:  []const u8,
    jsonObject:  *const fn (a: std.mem.Allocator, cols: []const []const u8, alias: []const u8) anyerror![]u8,
    jsonExtract: *const fn (a: std.mem.Allocator, src: []const u8, path: []const u8) anyerror![]u8,
    introspectColumns: *const fn (db: *anyopaque, a: std.mem.Allocator, table: []const u8) anyerror![][]u8,
};
```

Because the SQLite `Dialect` emits today's *exact* SQL, routing the divergent sites through it is a
**no-behaviour-change** refactor on SQLite.

---

## Schema & Migrations (per backend)

Today: one canonical `schema/schema.sql` + `schema/webhooks/*.sql`, applied by `loadSchemaFiles()`
(iterate dir, sort, exec each), with an empty `schema/migrations/` and an idempotent `migrate()`
ALTER hook. This maps directly onto the vtable's `applySchema(ctx, a)` — each driver owns its DDL
dialect.

```
schema/
├── sqlite/        schema.sql (moved verbatim) + webhooks/*.sql   ← canonical source of truth
└── postgres/      schema.sql + webhooks/*.sql                    ← GENERATED at build time
```

- **`tools/gen_pg_schema.py`** (sibling to `generate_introspection.py`, run on `zig build`)
  mechanically transpiles the deltas: `… AUTOINCREMENT` → `BIGSERIAL`, `strftime` DEFAULTs →
  `EXTRACT(EPOCH…)`, drop `WITHOUT ROWID`. Single source of truth → no drift. Build fails if it hits
  an unrecognized DDL token. The **type-class rules** that make the [coercing read getters](#read-path-typing--coercing-column-getters)
  sufficient (derived from the 337-column audit):
  - **B1 — every SQLite `INTEGER` → PG `BIGINT`; never emit `BOOLEAN`.** All 10 boolish-INTEGER
    columns (`accounts.seen_v1/seen_v2`, `names.{migrated,is_wrapped,is_v1_name,is_reachable,is_legacy,is_normalized,registry_locked}`,
    `resolver_authorisations.is_authorised`, `resolver_approvals.approved`) stay integer and are read
    by `getBool`/`getInt64`. `BIGINT` so 64-bit block/timestamp/expiry never truncate.
  - **B2 — the one real `BOOLEAN`, `v1_controllers.is_active` (`schema.sql:618`), → `SMALLINT DEFAULT 1`**
    (and `DEFAULT TRUE`→`DEFAULT 1`, `FALSE`→`0`). This keeps its existing integer-literal writes
    (`is_active = 1/0`, `WHERE is_active = 1`, the `schema.sql:629` seed) and `getBool` reads valid with
    **no Zig change**. Build asserts **no `BOOLEAN` token survives** in generated PG DDL.
  - **B3 — u256/money/hash/addr columns stay `TEXT`** (`token_id`, `canonical_id`, `wrapper_fuses`,
    `base_cost`, `premium`, `role_bitmap`, all `*_hash`/`namehash`/`owner`/`resolver`/`address`/…). B1
    must not touch declared-`TEXT` columns; a future "tighten TEXT→NUMERIC" is forbidden without
    revisiting the read contract.
  - **B4 — `json_extract(col,'$.k')` in DDL → `(col::jsonb ->> 'k')`.** Exactly one site: the
    expression index `idx_events_owner_extracted ON events (LOWER(json_extract(data,'$.owner')))`
    (`schema.sql:519`; `events.data` is `TEXT` JSON). PG form: `… (LOWER((data::jsonb ->> 'owner')))` —
    all-immutable, so the expression index is valid. (Same `json_extract`→`->>` rule the replay path
    uses, applied to DDL too.)
  - A **per-column type-class parity assertion** (integer-vs-text across all 337 columns) fails the
    build on any B1–B4 regression — independent of the read path, so coercion can't paper over drift.
- SQLite's `applySchema` keeps today's logic byte-for-byte (skip when `names` exists; idempotent
  `migrate()` ALTERs). Postgres's runs its DDL in one transaction.
- The reorg meta-tables (`reorg_undo`, `reorg_cursor`, `reorg_active`) are created by `applySchema`
  on both backends. A NoSQL backend's `applySchema` may no-op or create collections/indexes.
- The empty migration ladder stays retired; the documented upgrade path remains
  re-index-from-scratch. A **schema-parity test** asserts the generated Postgres DDL covers the
  same 38 tables.

**Construct audit (complete).** A line-by-line pass over `schema.sql` confirms it is vanilla and the
transpiler's job is bounded: 38 tables, 104 indexes, **1** `CHECK` (`source IN (…)` — portable
verbatim), **1** FK (below), and **zero** views, triggers (they live in code), `WITHOUT ROWID`,
generated columns, FTS/virtual tables, `COLLATE`, `BLOB`/`REAL`/`NUMERIC` types, or constraint-level
`ON CONFLICT`; no column names collide with PG reserved words. The only constructs needing transpile
are the already-covered `AUTOINCREMENT`→`BIGSERIAL` (27), `strftime` defaults (5), `INTEGER`→`BIGINT`
(B1), the `BOOLEAN`/`DEFAULT TRUE` (B2), and the one `json_extract` expression index (B4).

> **Finding to verify (pre-existing, backend-independent reorg gap).** The single FK is
> `unknown_labels.name_id → names(id) ON DELETE CASCADE` (`schema.sql:721`), and **`unknown_labels` is
> not in `PROTECTED_TABLES`** — it has no capture trigger. So deleting a `names` row during a
> reorg-eligible op (`deleteNameByNamehash`/GC, cursor armed) cascade-deletes its `unknown_labels`
> children **without capturing them**, and `rollbackToBlock(N)` restores the `names` row but **not**
> those children → rollback ≠ clean-sync-at-N for `unknown_labels`. This exists on SQLite today
> (independent of the port). Assess whether it matters (`unknown_labels` is a label-backfill work
> queue — possibly self-healing on re-processing) and, if so, either add `unknown_labels` to
> `PROTECTED_TABLES` (+ a `name_id` index) or capture the cascade. Whatever the resolution, both
> backends inherit it via the shared `PROTECTED_TABLES` array.

---

## Reorg undo-log strategy

**Server-side AFTER triggers are canonical for both shipped backends; write-path capture is the
portable fallback for trigger-less backends.** The `capabilities.server_side_undo` flag selects
which: `true` (default for SQLite *and* PostgreSQL) → the backend's own triggers capture; `false`
(NoSQL/KV and any trigger-less third party) → the application captures on the write path.

### Primary — server-side AFTER triggers (`server_side_undo = true`)

- **SQLite (unchanged):** today's `reorg_undo.installTriggers` generates AFTER UPDATE/DELETE triggers
  on `PROTECTED_TABLES` (gated by `reorg_cursor` on `OLD.protocol`) and AFTER INSERT/UPDATE/DELETE on
  `accounts`/`v1_controllers` (gated by `reorg_active`), snapshotting via `json_object(...)` over
  `PRAGMA table_info`. `recursive_triggers=ON` makes `INSERT OR REPLACE`'s implicit delete fire the
  AFTER DELETE capture. **Bit-for-bit the audited path that ships today.**
- **PostgreSQL (new, generated):** a `postgres`-driver `installPgTriggers` mirrors it from the *same*
  `PROTECTED_TABLES`/`REORG_ACTIVE_TABLES` arrays using **two generic PL/pgSQL functions** + plain
  `CREATE TRIGGER … FOR EACH ROW`. The snapshot is `to_jsonb(OLD)` — generic over every column, so
  **no per-column codegen and no introspection at capture time** (even more schema-driven than the
  SQLite path). Same op sets as SQLite. The concrete, doc-verified design is below.

Both installers share the single source of truth (`PROTECTED_TABLES`/`REORG_ACTIVE_TABLES`), so a new
table or column updates both with no hand-editing. `replayUndo`/`rollbackToBlock` are already written
against `Query` + `INSERT OR REPLACE` + `json_extract` and port for free once routed through
`dialect.upsert`/`dialect.jsonExtract`; the whole rollback runs in one `Tx`.

### Postgres trigger design (settled)

Verified against the PostgreSQL docs (`CREATE TRIGGER`, §37.1, PL/pgSQL trigger functions) and
adversarially reviewed against the 60-site capture inventory — **approved, restore-equivalent across
all 8 stress scenarios**, no runtime changes from the SQLite path. Three doc facts shape it:
**(1)** `WHEN` clauses **cannot contain subqueries**, so the cursor gate moves into the function body;
**(2)** `INSERT … ON CONFLICT DO UPDATE` fires **AFTER UPDATE** (with `OLD` = the pre-existing row) on
the conflict path and AFTER INSERT only on the no-conflict path — they partition cleanly, never
double-capturing; **(3)** `FOR EACH ROW` fires once **per affected row**, so bulk multi-row statements
are each captured.

**Two generic trigger functions** (one `CREATE OR REPLACE` each, reused by every trigger). This is
the exact form `reorg_undo.pgTriggerInstallSql` emits (kept in lockstep with the code — the
golden-string test in `tests/integration.zig` pins it). The op letter is `LEFT(TG_OP, 1)` (⇒ I/U/D),
derived from the firing event so it can never disagree with the trigger's event. `OLD.protocol` is a
direct field read (matching the SQLite trigger's `OLD.protocol`; both backends require — and the
coverage guard enforces — that every protected table has a `protocol` column):

```sql
-- protected tables (all have a `protocol` column); op = LEFT(TG_OP, 1) over {UPDATE,DELETE}
CREATE OR REPLACE FUNCTION reorg_capture_protocol() RETURNS trigger AS $$
DECLARE
  cur_block bigint;
BEGIN
  SELECT block_number INTO cur_block FROM reorg_cursor WHERE protocol = OLD.protocol;  -- gate in BODY (fact 1)
  IF cur_block IS NOT NULL THEN                          -- no cursor armed ⇒ backfill/replay ⇒ no self-capture
    INSERT INTO reorg_undo (protocol, block_number, table_name, op, old_row)
    VALUES (OLD.protocol, cur_block, TG_TABLE_NAME, LEFT(TG_OP, 1), to_jsonb(OLD)::text);
  END IF;
  RETURN NULL;                                           -- AFTER trigger return is ignored
END;
$$ LANGUAGE plpgsql;

-- active tables (accounts, v1_controllers, unknown_labels — no `protocol` col); tagged from reorg_active
CREATE OR REPLACE FUNCTION reorg_capture_active() RETURNS trigger AS $$
DECLARE
  act_protocol text;
  act_block bigint;
BEGIN
  SELECT protocol, block_number INTO act_protocol, act_block FROM reorg_active WHERE id = 1;
  IF FOUND THEN
    INSERT INTO reorg_undo (protocol, block_number, table_name, op, old_row)
    VALUES (act_protocol, act_block, TG_TABLE_NAME, LEFT(TG_OP, 1),
            to_jsonb(CASE WHEN TG_OP = 'INSERT' THEN NEW ELSE OLD END)::text);
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;
```

**Trigger generation** (`installPgTriggers`, from the same arrays; PG has no `CREATE TRIGGER IF NOT
EXISTS`, so each is `DROP TRIGGER IF EXISTS … ; CREATE TRIGGER …`, names matching SQLite's
`"<t>_reorg_undo_<i|u|d>"`):
- **Protected tables → `AFTER UPDATE` + `AFTER DELETE`** (op {U,D}; **no AFTER INSERT** — brand-new
  rows are reversed by `sync.zig`'s `created_block/block_number > N` delete, exactly as on SQLite).
- **Active tables → `AFTER INSERT` + `AFTER UPDATE` + `AFTER DELETE`** (op {I,U,D}; the op-`I`
  captures `NEW` so `replayUndo` can precisely retire an after-N first insert).

**Op-mapping & the (narrow) op-letter divergence.** UPDATE→`U`, DELETE→`D`, active-INSERT→`I` are
identical on both backends. The only divergence is the **12 literal `INSERT OR REPLACE` sites
(`resolver_* store*` in `resolvers.zig`, + `insertApproval`)**: on SQLite `recursive_triggers` makes
the implicit delete fire AFTER DELETE → op `D`; on Postgres `dialect.upsert` makes them `ON CONFLICT
DO UPDATE` → AFTER UPDATE → op `U`. **This is harmless** — the captured `OLD` snapshot is the same
pre-overwrite row, and `replayUndo` restores `U` and `D` **identically** (only op `I` branches).
> Note: the *already*-`ON CONFLICT DO UPDATE` sites — `names.insertName`, `eac_roles`,
> `registry_entries`, `reverse_records`, `accounts`, `v1_controllers`, `resolver_metadata/approvals`
> — fire op `U` on SQLite *too*, so they have **zero** divergence. The divergent set is the 12
> literal-IOR sites, not all upserts.

**Snapshot round-trip.** `to_jsonb(OLD)::text` → the existing TEXT `old_row` column (schema matches
SQLite). On replay, `dialect.jsonExtract` emits `($1::jsonb ->> 'col')` — but **`->>` always yields
text**, so numeric columns need an explicit cast `(… ->> 'col')::bigint` (SQLite's `json_extract` was
loosely typed). `dialect.jsonExtract` therefore takes the column's type from `dialect.introspectColumns`
(`information_schema.columns`) — introspection is needed only on the *replay* side, not at capture.
NULLs round-trip as genuine SQL NULL on both.

**#3 — the SQLite `INSERT OR REPLACE` guardrail.** `dialect.upsert(table, cols, conflict, .replace)`
is the single chokepoint. On SQLite it **must** emit literal `INSERT OR REPLACE` for the 12 literal-IOR
sites — *both* because only the implicit delete fires the AFTER DELETE capture under
`recursive_triggers`, *and* because `INSERT OR REPLACE` has full-row-replace semantics (unspecified
columns revert to defaults, `ON DELETE CASCADE` fires) that those rewrites rely on; `ON CONFLICT DO
UPDATE` only sets listed columns. On Postgres the same call emits `ON CONFLICT(conflict) DO UPDATE SET
c=EXCLUDED.c`. **Guardrail test:** assert SQLite `.replace` output **starts with `INSERT OR REPLACE`
and contains no `ON CONFLICT`** (`.ignore` → `INSERT OR IGNORE`); Postgres `.replace` contains `ON
CONFLICT … DO UPDATE SET`. This pins the divergence at the dialect boundary so a refactor can't
silently flip SQLite to `ON CONFLICT` and break implicit-delete capture.

**Replay self-capture is prevented by ordering**, on both backends identically: `rollbackToBlock`
runs `clearCursor` (empties `reorg_cursor` *and* `reorg_active`) **before** `replayUndo`, in the same
`Tx` — so the restore writes (which on PG are `ON CONFLICT DO UPDATE` and *would* re-fire
`reorg_capture_protocol`) hit the body gate, find no cursor row, and early-return. Add a **defensive
assertion** that `replayUndo` is a no-op/aborts if `reorg_cursor`/`reorg_active` are non-empty for the
protocol being replayed, so a future refactor can't reintroduce self-capture.

### Fallback — write-path capture (`server_side_undo = false`)

For trigger-less backends, a `captureBefore(db, table, key)` helper fires from inside the storage
mutators, **before** the mutation and **only while the cursor is set**, reading the affected row(s)
as JSON via `dialect.jsonObject` and inserting into `reorg_undo` with the op marker — reproducing
what the triggers capture, including op-`I` for first inserts on active tables. This is the *only*
option for a KV/document store, and it fits naturally there: such stores mutate **by key**, so the
single-row `captureBefore` shape matches and the bulk-statement re-SELECT awkwardness (which
disqualifies write-path for SQL backends) never arises.

To keep the fallback honest and unrotted, every protected-table mutator routes through a single
`mutateProtected(db, comptime table_tag, key, mutateFn)` chokepoint — a pure pass-through when
`server_side_undo` is true (shipped backends pay nothing), the `captureBefore` site when false.

### Guarding coverage (three layers)

A new protected table or mutation site must not silently lose capture (the 2026-06-02 failure class):

1. **Single source of truth:** `PROTECTED_TABLES`/`REORG_ACTIVE_TABLES` drive both trigger installers;
   a `comptime` assertion requires every table in `sync.zig`'s created-after delete-lists (minus an
   explicit `INSERT_ONLY_TABLES` set) to appear in `PROTECTED ∪ REORG_ACTIVE` — catching the realistic
   "added the delete but forgot the trigger array" drift.
2. **Chokepoint + comptime map:** a `comptime` check requires every protected table to declare a
   capture strategy in a `coverage_map`; the `mutateProtected` wrapper is the only sanctioned way to
   issue an in-place `UPDATE`/`DELETE`/`INSERT OR REPLACE` on a protected table.
3. **CI lint seeded with the golden inventory:** a grep-lint (Zig can't reflect on raw SQL strings)
   fails CI when an in-place mutation of a protected table appears outside `mutateProtected`. The
   [60-site inventory](#appendix-reorg-capture-site-inventory) is its golden fixture — a 61st site
   fails until wrapped or waived.

Triggers build the snapshot over introspected columns, so a **new column** is auto-captured on all
three paths; `captureBefore` uses the same `dialect.jsonObject(introspectColumns(table))` and a parity
test asserts column-set equality.

### A/B parity (proves the fallback is trustworthy)

Parity's purpose is to certify the *fallback* for third parties — **not** to flip SQLite off
triggers. **Two harness rules are hard requirements** (per the adversarial review), because a naive
test passes/fails wrongly without them: **(H1)** never compare raw `old_row` *strings* across
backends — `json_object` (SQLite) and `to_jsonb` (Postgres) differ in key order and number
formatting; **decode each `old_row` to a normalized key→canonical-value map** (sort keys, render
integers canonically) and assert *that* plus **post-rollback table-state equality** (the real ground
truth). **(H2)** assert the `clearCursor`-before-`replayUndo` ordering (the only thing preventing PG's
`ON CONFLICT DO UPDATE` restores from self-capturing mid-rollback). Three lanes: (1) same-backend
SQLite A/B — triggers vs forced write-path produce restore-equivalent `reorg_undo` (the literal-IOR
op-letter legitimately differs — `D` vs the fallback marker — so assert snapshot + post-rollback
equivalence, **not** raw op equality) and identical post-rollback state vs a clean sync stopping at N;
(2) cross-backend SQLite vs Postgres triggers — identical post-rollback state on every protected
table under H1; (3) adversarial site coverage — seed an event stream exercising every hard site with
a cursor armed (`setRegistriesReachability` bulk IN-list, `recursivelyGcEmptyDomain` cascade, **both**
`resolver_texts` delete paths, `updateNameCreationDate` lowering `created_block`, `v1_controllers`
remove-then-readd straddling N, **and `accounts` *both* an op-`I` brand-new and an op-`U`
existing-account-first-seen-by-other-protocol-after-N** — these hit different replay branches). A
dedicated CI lane forces `server_side_undo=false` on SQLite and runs the existing reorg suite
(`d663945`) every PR so the fallback never bit-rots.

> **Pre-existing bug to fix (mechanism-agnostic).** `materializePccDomainExpiry` (`names.zig:769`,
> called from `indexer.zig:683/744`) runs at the end of the first bulk sync with the reorg cursor
> **still armed**, so its predicate-less bulk UPDATE over every wrapped name self-captures one
> `reorg_undo` row per name — unbounded over-capture (correctness-neutral; rollback still restores
> the OLD expiry). It over-captures under triggers *and* would under write-path. Fix independently of
> the backend work: wrap it in `clearCursor()`/`invalidateReorgCursor()` or run it before the cursor
> is armed; add a test asserting `reorg_undo` is empty after a clean first bulk sync.

---

## Transactions, write buffer, and the rainbow DB

**Transactions/savepoints** are trivially portable: `transactions.zig`'s raw `BEGIN/COMMIT/ROLLBACK`
and `sync.zig`'s `BEGIN IMMEDIATE` become `Tx`/`Savepoint` guards. `TxMode.immediate` maps to SQLite
`BEGIN IMMEDIATE` and to a plain Postgres `BEGIN` (Postgres locks lazily; isolation handles
serialization). Savepoints map identically on both shipped backends.

**Write buffer stays backend-agnostic with zero changes in spirit.** `src/indexer/write_buffer.zig`
already contains no SQL and no sqlite symbols — it accumulates `BufferedName` (deduped by 32-byte
namehash) and `Event` structs in memory and only touches the DB in `flush()` by calling
storage-module functions. Since those now go through `Statement`/`Backend`, the buffer flushes onto
any backend unchanged. The only additions: (1) the per-chunk transaction the indexer already wraps
`flush` in becomes a `Tx` guard (atomic batch on every backend); (2) `captureBefore` fires from
*inside* the storage functions during flush, so undo capture and the batched write are naturally
co-transactional. Postgres throughput comes from prepared-statement reuse across the flush loop and,
optionally, multi-row `VALUES`/`COPY` for the append-only events path — never visible to the buffer.

**Rainbow-table DB — out of scope.** `src/rainbow/rainbow.zig` stays a direct, independent SQLite
`@cImport`. It is a separate **read-only** connection to a static label-dictionary DB with
load-bearing SQLite tuning (`cache_size`, `mmap_size`), never written by the indexer and never
reorg-rolled-back. Forcing it through the vtable would add indirection for zero benefit and risk
regressing its tuned path. It stays SQLite-linked regardless of the main backend — even with
Postgres as the indexer store, the rainbow dictionary remains a local SQLite asset.

---

## Third-party backend extension recipe

> **Phase 5:** the canonical, code-accurate recipe now lives in **`docs/backend-spi.md`**
> (published SPI doc), with `tests/storage/backend_conformance_test.zig` as the executable
> spec. The sketch below predates it; known deltas vs. the shipped code: there is **no
> `verifyVTable`** (a comptime `VTable{...}` literal already fails to compile on a missing
> slot — every field is a non-optional fn pointer), **no `Savepoint` type** (savepoints are
> plain SQL through `execRaw` inside a `Tx`, declared via `caps.savepoints`), and **no
> `Config` in backend.zig** (drivers take their own opts struct; `db_open.selectBackend`
> maps env config onto the shipped drivers only). `server_side_undo=false` is currently
> **rejected** at `Database.initWithBackend` — see the scope decision in the Phase-5 status.

A third party adds a backend (SQL or NoSQL) **without modifying this repo**:

1. Add zigens as a `build.zig.zon` dependency; import `src/storage/backend.zig` to get `Backend`,
   `VTable`, `Statement`, `StmtVTable`, `Capabilities`, `Placeholder`, `Dialect`, `Config`, `Tx`,
   `Savepoint`.
2. Define a concrete struct holding your connection/pool/client (e.g. `RocksBackend`,
   `ScyllaBackend`).
3. Write one fn per `VTable` slot (~14) and one per `StmtVTable` slot (~11); each recovers self via
   `const self: *MyBackend = @ptrCast(@alignCast(ctx));`. Map the abstraction: `prepare` returns a
   `Statement` wrapping your cursor; `begin/commit/rollback` map to your txn API (or emulate with a
   write batch + undo if you have none); `applySchema` creates collections/indexes (or no-ops if
   schemaless).
4. Set `Capabilities` — `placeholder` (`.qmark` if you accept `?`), `returning`, `savepoints`,
   `pooled`, and `server_side_undo`. For a NoSQL/KV store set **`server_side_undo = false`** so the
   application write-path records undo entries for you — full reorg-rollback correctness **without
   triggers**. A SQL backend that *does* have triggers may instead set `server_side_undo = true` and
   supply its own trigger installer (the Postgres model); write-path is the floor, not the only option.
5. Provide a `Dialect` instance: supply `upsert`, `returning`, `nowEpoch`, `jsonObject`,
   `jsonExtract`, `introspectColumns` for your query language (a NoSQL backend can route these
   through a thin serializer shim).
6. Build `const vtable = VTable{…}` at comptime (call `verifyVTable(vtable)` to fail early on a
   missing slot) and export `pub fn open(a, cfg) !Backend { return .{ .ptr = self, .vtable = &vtable }; }`.
7. In your app's `main`, call `MyBackend.open(...)` then `Database.fromBackend(alloc, backend)` and
   hand the `*Database` to the indexer/API exactly as the shipped binaries do — **no edits to
   `selectBackend` or any shipped file.**

That is the entire contract: ~25 small fns + a `Dialect`. No registry, no codegen, no dynamic
loading. Run the published **driver-conformance test** (which both shipped drivers pass) as your
executable spec. The hardest slot for a NoSQL backend is transactional atomicity for the batched
flush + reorg rollback; the interface surfaces this honestly via `caps.savepoints`/`begin` and
`server_side_undo` so the implementer knows exactly what consistency they must provide.

---

## File-by-file change map

| Path | Change |
|------|--------|
| `src/storage/backend.zig` | **NEW.** The SPI: `Backend`, `VTable`, `Statement`, `StmtVTable`, `Capabilities`, `Placeholder`, `TxMode`, `ConflictAction`, `Dialect`, `Tx`, `Savepoint`, `Config`, `selectBackend()`, `verifyVTable()`. |
| `src/storage/drivers/sqlite.zig` | **NEW.** Wraps the existing `?*c.sqlite3` + stmt cache + 7-PRAGMA block + `loadSchemaFiles`/`migrate` verbatim behind the vtable. Owns the `@cImport(sqlite3.h)` (moved from `database.zig`). `server_side_undo=true` (keeps today's triggers — canonical, not a temporary default). |
| `src/storage/drivers/postgres.zig` | **NEW.** pg.zig Conn/Stmt/Row, pool, `?`→`$N` lexer, `ON CONFLICT`/`RETURNING`, `SET` session config, `information_schema` introspection, `applySchema`, a generated PL/pgSQL `installPgTriggers`, and **coercing column getters** (`colInt64`/`colText`/`colIsNull` mimic `sqlite3_column_*` so read sites need no edits). `server_side_undo=true` (native triggers). |
| `src/storage/query.zig` | `pub const Query = Statement;`; move the shared bind/get helpers + Address/Hash binders onto `Statement`. **Delete** the `bound_strings`/`MAX_BOUND_STRINGS` tracking (binds now copy in the driver — see [Memory & ownership model](#memory--ownership-model)). **Remove `pub const c`.** Keep `buildInClause`/`joinWrapped`/`queryOne`/`queryText` as thin wrappers. |
| `src/storage/database.zig` | **Major.** Remove the top-level `@cImport`; hold `backend: Backend` (not `?*c.sqlite3` + cache; cache moves into the SQLite driver). `init` → `open(cfg)` via `selectBackend`; add `fromBackend`. Forward exec/prepare/lastInsertId/dialect/caps to the backend. |
| `src/storage/transactions.zig` | Replace raw `sqlite3_exec` BEGIN/COMMIT/ROLLBACK with `Tx`/`Savepoint`. Remove `const c`. |
| `src/storage/reorg_undo.zig` | Keep `installTriggers` as SQLite's **primary** path; **add a generated `installPgTriggers`** for Postgres — the **two generic PL/pgSQL functions** `reorg_capture_protocol`/`reorg_capture_active` (cursor gate in the body; `to_jsonb(OLD)::text` snapshot) + `DROP/CREATE TRIGGER … FOR EACH ROW` from the same arrays (protected {U,D}; active {I,U,D}). Route `getRestoreSql`/`replayUndo` through `dialect.upsert`/`jsonExtract` (PG emits `($1::jsonb ->> 'col')::<type>` — needs the type from `introspectColumns`). Add a **`replayUndo` defensive assert** (cursor/active empty before replay). Add the comptime coverage-map + CI lint (60-site golden inventory). Add `captureBefore` + `mutateProtected` as the **fallback** (`!server_side_undo`). Fix `materializePccDomainExpiry` over-capture. |
| `src/storage/names.zig` | Import swap only (43 `Query` sites unchanged); route `INSERT OR REPLACE/IGNORE` through `dialect.upsert`; drop the vestigial `const c`. |
| `events.zig`, `resolvers.zig`, `sync.zig`, `registrations.zig`, `roles.zig`, `accounts.zig`, `registry_entries.zig`, `v1_controllers.zig` | Import swap + route `INSERT OR REPLACE/IGNORE`/`strftime` sites through Dialect. `sync.zig` `BEGIN IMMEDIATE` → `Tx(.immediate)`. No structural change. |
| `ensip16.zig`, `webhooks.zig`, `unknown_labels.zig` | **Port off raw C** (109/65/48 calls) onto `Statement`/`Backend`. `webhooks.zig:65` `last_insert_rowid` → `db.lastInsertId()`. The genuine raw-C *storage* modules; they gate non-SQLite support. |
| `src/webhooks/manager.zig`, `src/indexer/label_backfill.zig`, `src/indexer/v1/handlers.zig` | **Port off raw C** — non-storage files that call the re-exported `db.c` directly (~63/14/5 calls) and break when `pub const c` is removed. Move onto `Statement`/`Backend`; `manager.zig` holds the only `RETURNING` clause → branch on `caps.returning`. |
| `schema/sqlite/` (move) · `schema/postgres/` (NEW, generated) | Relocate canonical schema under `sqlite/`; add generated `postgres/`. `loadSchemaFiles` logic moves into each driver's `applySchema`. |
| `tools/gen_pg_schema.py` | **NEW.** Transpile sqlite→postgres DDL at build; wire into `build.zig`. |
| `build.zig` / `build.zig.zon` | Add pg.zig (`zig-0.15` branch); add `-Dbackend` option for conditional `sqlite3` linking; run `gen_pg_schema.py`. Keep `sqlite3` linked for rainbow-backfill/`test_db_reader`. |
| `src/config.zig` | Add `backend_kind` enum `{sqlite,postgres}` from `DATABASE_BACKEND`/`--backend` (default `.sqlite`) + `DATABASE_URL` alongside `DATABASE_PATH`, and `DATABASE_POOL_SIZE` (API reader pool, default ~10). |
| `src/api/server.zig`, `src/api/handler.zig` | Adopt **acquire-per-request**: `Server`/`GraphQLHandler` hold a `*Pool`; `handleConnectionThread` does `acquire(.reader)`/`defer release`, passing the per-request `*Database` to the resolvers (webhook-admin writes `acquire(.writer)`). SQLite pool is degenerate, so behaviour is unchanged there. |
| `src/indexer/write_buffer.zig` | No change except `flush` wrapping a `Tx` guard. |
| `src/rainbow/rainbow.zig` | **No change.** Stays a direct SQLite `@cImport`, out of scope. |
| `src/indexer_main.zig`, `indexer_v1/v2_main.zig` | Open a `Pool`, `acquire(.writer)` once and pin it for the run. `api_main.zig` opens a `Pool` and hands it to the server. (Replaces today's `Database.init(alloc, path)`; otherwise backend-blind.) |

---

## Implementation Plan & Timeline

| Phase | Work | Effort |
|-------|------|--------|
| **0 — Introduce the seam (SQLite-only, no behaviour change)** | Add `backend.zig` + `drivers/sqlite.zig` wrapping today's exact C path, stmt cache, PRAGMA block, `loadSchemaFiles`/`migrate`. `server_side_undo=true` (triggers unchanged). Reshape `Database` to hold a `Backend`; make `Query` a compat alias. Move the `@cImport` into the driver. Full `zig build test` matrix must stay byte-identical green. Validates the seam **before** a second backend exists. | ~1.5 wk |
| **1 — Transactions + legacy raw-C call sites** | `transactions.zig` + `sync.zig` `BEGIN IMMEDIATE` → `Tx`/`Savepoint`. Port every raw-C site onto `Statement`: storage `ensip16` (109), `webhooks` (65), `unknown_labels` (48), **plus** the non-storage `webhooks/manager.zig` (63, incl. the `RETURNING` clause), `indexer/label_backfill.zig` (14), `indexer/v1/handlers.zig` (5). Hide `last_insert_rowid` behind `db.lastInsertId()`; branch `RETURNING` on `caps.returning`. Eliminate `pub const c`. Re-run the reorg/integration suite. | ~1.5 wk |
| **2 — Dialect + route divergent SQL** | Add Dialect builders; route the 25 `INSERT OR REPLACE` + 21 `INSERT OR IGNORE` + 1 `RETURNING` + 1 `last_insert_rowid` sites + reorg restore/JSON builders through them. SQLite Dialect emits today's exact SQL → still no behaviour change. Split schema into `schema/sqlite` + add `gen_pg_schema.py`. | ~1 wk |
| **3 — Reorg capture across backends + A/B parity** *(highest-risk)* | **(3a)** Generate `installPgTriggers` (the two PL/pgSQL functions + `FOR EACH ROW` triggers from `PROTECTED_TABLES`/`REORG_ACTIVE_TABLES`); add the #3 SQLite-IOR guardrail test + the `->>::type` replay cast + the `replayUndo` ordering assert — per the [settled design](#postgres-trigger-design-settled). **(3b)** Implement the write-path `captureBefore` + `mutateProtected` chokepoint + 3-layer compile-time coverage map — the trigger-less *fallback* only. **(3c)** A/B parity (3 lanes: same-backend SQLite, cross-backend SQLite↔Postgres, adversarial site coverage). Also fix the `materializePccDomainExpiry` over-capture. SQLite + Postgres keep `server_side_undo=true`. | ~1.5 wk |
| **4 — PostgreSQL driver** | `drivers/postgres.zig` on pg.zig: Conn/Stmt/Row (sequential `prepareForBind`+`bind`), pool with txn connection pinning, literal-aware `?`→`$N` lexer, `ON CONFLICT`/`RETURNING`, **coercing column getters**, `SET` config, `information_schema`, `applySchema` + `installPgTriggers`. Transpiler rules B1–B3 + per-column type-class parity test. Wire `selectBackend` + `config.backend_kind` + `DATABASE_URL`. Postgres-container CI lane runs the same storage/integration tests + a round-trip test per hash/addr/u256 column. Validate full indexer flow + a reorg rollback on Postgres. | ~2.5 wk |
| **5 — Publish SPI + harden fallback** | Publish `backend.zig` as the documented third-party SPI with a driver-conformance test both shipped drivers pass; document the extension recipe and the `server_side_undo` choice (triggers vs write-path fallback). Keep the forced-`false` CI lane so the fallback stays exercised. | ~1 wk |

**Total: ~9 weeks.** Phases 0–3 are SQLite-only and independently shippable — they deliver the
modular seam and the portable reorg path with no second backend, de-risking everything before
PostgreSQL work begins.

### Implementation status (SQLite-only seam)

- **Phase 0 — DONE.** `backend.zig` (SPI) + `drivers/sqlite.zig` (owns the `@cImport`, `SqliteConn`,
  stmt cache, PRAGMA/serialized config); `Database` holds a `Backend`; `Query` is a compat alias for
  `backend.Statement`; the driver owns the connection. Suite byte-identical green.
- **Phase 1 — DONE.** `Tx`/`TxMode` guards; `transactions.zig`/`sync.zig` on them; every raw-C site
  ported off `pub const c` (storage `ensip16`/`webhooks`/`unknown_labels`, plus `webhooks/manager.zig`
  incl. its `RETURNING` clause branched on `caps.returning`, `indexer/label_backfill.zig`,
  `indexer/v1/handlers.zig`); `last_insert_rowid` behind `db.lastInsertId()`. `pub const c` has no
  consumers outside `drivers/`.
- **Phase 2 — DONE (except reorg_undo, owned by Phase 3).**
  - Dialect builders (`upsert`/`insertSelect`/`returning`/`jsonObject`/`jsonExtract`/`nowEpoch`/
    `placeholder`) added, SQLite-emitting today's exact SQL; unit-tested. `upsert` takes per-column
    `value_exprs` (empty ⇒ all `?`; else inline literals/`LOWER(?)`/`NULL`), so expression-bearing
    upserts route with **zero bind-sequence changes**.
  - `gen_pg_schema.py` transpiler (B1–B4 + AUTOINCREMENT→BIGSERIAL, `strftime`→`EXTRACT(EPOCH…)`, and
    seed `INSERT OR IGNORE`→`ON CONFLICT DO NOTHING`) with a FORBIDDEN-token guard + table-count parity;
    **wired into `build.zig`** (runs every build → drift guard). Generates `schema/postgres/…`.
  - Conflict-key map `schema_keys.zig` + `Database.upsertSql`/`upsertExprSql`/`insertSelectSql`. **All
    26** non-reorg `INSERT OR …` call sites routed: 21 pure-placeholder via `upsertSql`; 4 literal/
    wrapper sites (`registrations` `LOWER(?)`, `v1/backfill.zig` ×2, `migrate()` root-row) +
    `resolver_addresses`' `NULL` via `upsertExprSql`; the one `INSERT…SELECT`
    (`backfillResolverEntitiesFromNames`) via `insertSelectSql`. Two review passes (memory + indexing
    correctness) clean; full suite byte-identical green; all 25 conflict keys pinned.
  - **Deferred to Phase 3:** all of `reorg_undo.zig` (restore/cursor/active builders) — the only
    remaining live `INSERT OR …` sites — routed there holistically with `jsonExtract` +
    `introspectColumns` casts.
  - **Not done (intentional):** schema kept canonical at `schema/schema.sql` (the optional
    `schema/sqlite/` move was skipped as disruptive churn).
- **Phase 3 — IN PROGRESS.** Sequenced into independently-verifiable, behaviour-neutral increments
  (each build-green + full-suite-green, mirroring Phase 2). The unit of work is SQLite-only since no
  PG driver exists yet (Phase 4); PG-only pieces are *built and unit-tested now* but only *run* under
  Phase 4 (golden-string generators, cast threaded as a SQLite no-op). Corrected facts from the
  understanding pass: **`registrations` is already in `PROTECTED_TABLES`** (the "Bug 3 / unprotected"
  claim was false — it collapses to a regression-test guard); **`unknown_labels` is genuinely absent**
  from both trigger arrays (the `ON DELETE CASCADE` rollback gap is real).
  - **W1 — DONE.** `introspectColumns` added as a connection-bound `VTable`/`Database` op (NOT the
    conn-less `Dialect`), `ColumnInfo{name,sql_type,pk_pos}` + `freeColumnInfo` in `backend.zig`,
    SQLite impl = `PRAGMA table_info`; `reorg_undo.getColumns`/`pkColumn` reimplemented on it
    (behaviour-neutral). Snapshot test; both reviewers clean.
  - **W2 — DONE.** `Dialect.jsonExtract` gained `cast_type: ?[]const u8` (SQLite ignores it; PG appends
    `::<type>` because `->>` yields text). Golden-string test proves SQLite output unchanged.
  - **W3 — DONE.** Routed `reorg_undo.zig`'s SQL through the dialect, behaviour-neutral on SQLite
    (proven by the exact-reconcile invariant + empirical byte-equivalence of the restore SQL incl.
    composite-PK `resolver_versions`). `getRestoreSql`→`introspectColumns` + `dialect.upsert(value_exprs
    = jsonExtract-per-col)` with the table's PK (all `pk_pos>0` cols) as the conflict target and each
    column's type threaded as the PG `->>` cast; `setCursor`'s two IOR→`dialect.upsert` (reorg_cursor
    conflict=protocol, reorg_active conflict=id, `1` literal preserved via `value_exprs`); the three
    op-`I` `json_extract` sites in `replayUndo`→`dialect.jsonExtract` (the single-PK delete now casts by
    the PK's type — closes a latent PG text-vs-bigint bug for `unknown_labels.id`). Retired the now-dead
    `pkColumn`. Trigger *bodies* + `rowJson` stay raw SQLite (PG triggers are W10). Verified: the
    one-shot post-sync backfills run cursor-disarmed (W4 synergy) so the new W6 `unknown_labels`
    UPDATE/DELETE triggers don't self-capture — documented as an invariant at the backfill block. Both
    reviewers clean.
  - **W4 — DONE (bug).** `Indexer.materializePccUncaptured` disarms the cursor (`reorg_undo.clearCursor`)
    around the one-shot bulk `UPDATE names` (`names.zig:767`) and re-arms lazily via
    `invalidateReorgCursor`. Not merely bloat: a captured row would wrongly revert the PCC expiry
    mirror on a later reorg. Bonus: also stops backfill's `updateNameCreationDateIfEarlier`/
    `backfillUnknownLabels` from over-capturing. Tests: positive (survives reorg) + non-vacuous pre-fix
    control. Both reviewers clean.
  - **W6 — DONE (bug).** Added `unknown_labels` to `REORG_ACTIVE_TABLES` (single `id` PK, no `protocol`
    col, `name_id` FK→`names` `ON DELETE CASCADE`). op-`I` reversal removes post-N rows with no cascade
    path. Cascade-vs-replay ordering proven safe (recursive_triggers gives the child a lower undo id;
    replayUndo walks id DESC, parent-first); production `name_id` is always null so the cascade never
    reaches it. Bonus: also fixes permanent loss of DNS-healing deletes on rollback. Confirmed the
    *only* `ON DELETE CASCADE` FK in the schema → no other gap of this class. Non-vacuous test; both
    reviewers clean.
  - **W5 — DONE (guard).** Renew-then-reorg regression test for `registrations` (already PROTECTED).
  - **W7/W8 — DONE (comptime coverage guards).** `sync.zig` rollback delete-lists hoisted to
    module-level `pub const` (single source of truth) and a `comptime` block asserts both directions:
    **(G1)** every rollback-deleted table is reorg-captured or explicitly insert-only-waived; **(G2)**
    every `PROTECTED` table is also in a rollback delete-list (so updates *and* post-N inserts are
    both handled; `REORG_ACTIVE` exempt — op-`I` removes their inserts). Replaces the brittle external
    grep-lint with robust in-language guards; both smoke-tested to fire on an injected gap. The guard
    **immediately caught two real latent gaps** by forcing honest waiver classification:
    - **`orphaned_registrations` — FIXED.** Not insert-only (`deleteOrphanedRegistrations` deletes a
      resolved orphan in place). A pre-N orphan resolved post-N was permanently lost on rollback (the
      pre-N source `NameRegistered` never re-processes). Added to `PROTECTED_TABLES` (has `protocol`,
      single `id` PK) → op-`D` capture/restore; composes correctly with the `block_number` delete for
      all create/delete-block combos. Non-vacuous straddle test; reviewer-confirmed.
    - **`events` — accepted waiver, now honest.** `updatePlaceholderEventsByName` patches the
      denormalized `name`/`namehash` in place. Deliberately NOT captured (canonical `data` JSON
      untouched, idempotent self-heal on re-sync, and its no-protocol-filter `UPDATE` would make
      capture cross-protocol-ambiguous); residual = a reorged-out resolving event leaves a stale
      derived column. Documented in the waiver rather than
      mis-labelled "append-only". The other waivers (block_hashes, name_history, resolvers) verified
      genuinely insert-only.
  - **W7/W8 — coverage lints** (comptime sync-delete ⊆ trigger-arrays; CI grep golden ~60-site
    inventory) — land AFTER W5/W6 so the protected set is correct.
  - **W10 — DONE (scaffolding).** `reorg_undo.pgTriggerInstallSql` generates the two generic PL/pgSQL
    capture functions + per-table FOR EACH ROW triggers from `PROTECTED_TABLES`/`REORG_ACTIVE_TABLES`
    (cursor gate in the body; `to_jsonb(OLD/NEW)::text` snapshot; op = `LEFT(TG_OP, 1)` so it can't
    disagree with the firing event; trigger names match the SQLite scheme; protected {U,D}, active
    {I,U,D}; idempotent CREATE OR REPLACE + DROP/CREATE). Golden-string test pins it (53 triggers + 2
    functions). Pure string-gen — the PG driver *executes* it in Phase 4. Correctness reviewer PASS;
    the settled-design doc was updated to match the emitted SQL exactly (no drift).
  - **W11 — DONE (folded).** New reorg regression tests live in `tests/integration.zig` alongside the
    existing reorg suite (no separate `test-reorg` root needed).
  - **W9 — deferred (PG-only scaffolding):** `mutateProtected`/`coverage_map`/`captureBefore` write-path
    fallback is only needed by a `server_side_undo=false` third-party backend; both shipped backends use
    `server_side_undo=true` (triggers). Not required for the SQLite or Postgres ship path.
  - **Defer to Phase 4:** PG `introspectColumns` (`information_schema`), `::type` cast *emission* +
    round-trip, `installPgTriggers` *execution*, cross-backend A/B Lane 2 (H1 decode-and-canonicalize),
    and the optional W9 write-path fallback if a third-party backend ever sets `server_side_undo=false`.
- **Phase 4 — STARTED; pg.zig integrated, driver next.** The sandbox proxy actually *allows* github +
  the Docker registry — the blocker was that zig's package fetcher can't CONNECT-tunnel the proxy. Cached
  `pg.zig` (pinned `78d52e5`, zig-0.15) + its deps `buffer`/`metrics` via `curl` + `zig fetch`, added `pg`
  to `build.zig.zon`/`build.zig`, and a smoke test confirms **pg.zig compiles under Zig 0.15.2** (TLS off
  ⇒ `PlainStream`, no openssl/libc; the tarball was fetched via curl + `zig fetch`). A **live
  PostgreSQL 17** is set up (apt; `127.0.0.1:5432`, `ensv2_test`, scram-sha-256) and
  **verified end-to-end**: `zig build test-pg` has pg.zig connect over TCP
  and round-trip a typed query, AND the low-level prepared-statement path the driver adapts onto
  (`conn.prepare` → sequential `stmt.bind` → `execute` → `Result.next` → `Row.get`) with the ownership
  rules pinned (verified against pg.zig source): execute transfers the Stmt arena to the Result (no
  `stmt.deinit` after); the Result must be drained before connection reuse; `bind` OID-coerces ints and
  takes the bare `null` for NULL. **`drivers/postgres.zig` now exists and is live-validated** against the
  local PG (`tests/storage/postgres_driver_test.zig`, `test-pg` 7/7 green): the `VTable`/`StmtVTable` on
  pg.zig — `open`/`close` (size-1 pool, pinned conn), `execRaw`, `?`→`$N` at prepare via
  `renumberPlaceholders`, sequential binds (`bindText`/`Int64`/`Int`/`Null`), drain-aware exec/step,
  **OID-dispatching coercing getters** (`columnInt64`/`Int` read int2/int4/int8/bool via `row.oids[col]`;
  `columnText` for text), NULL handling, and `begin`/`commit`/`rollback`. Verified round-trip:
  prepared INSERT (+NULL) → SELECT with bound param → typed/coerced reads; and a tx commit-keeps /
  rollback-drops. Remaining driver refinements: `introspectColumns` live-validation (its query needs a
  conn-state fix — used by reorg replay, not core CRUD); `finalize` should fully drain after a *partial*
  step (robust in a tx); real `changes()` (affected-rows, currently stubbed 0); optional prepared-stmt
  caching; then `applySchema`/`installPgTriggers` execution, `selectBackend`/config/`DATABASE_URL`, and
  the cross-backend A/B-parity lane.
  **Schema transpilation validated end-to-end (test-pg 6/6):** the transpiled `schema/postgres/schema.sql`
  (all 38 tables, BIGSERIAL, the seed `INSERT…ON CONFLICT DO NOTHING`, the `->>` expression index) loads
  cleanly into a real PostgreSQL 17 after `DROP SCHEMA public CASCADE`, and a PG-dialect `ON CONFLICT DO
  UPDATE` upsert round-trips on the real `sync_state` table (overwrites by PK, no duplicate) through the
  full driver path — so the Phase-2 `gen_pg_schema.py` output is confirmed valid Postgres.
  **First cross-backend A/B parity proven (test-pg 7/7):** the real storage `insertName` (the 33-column
  `INSERT … ON CONFLICT(protocol,namehash) DO UPDATE SET col = excluded.col` upsert — already
  dialect-agnostic, *not* a Phase-2 `INSERT OR REPLACE` routing site since `excluded.` upsert is valid on
  both SQLite ≥3.24 and Postgres) and `getNameByNamehash` (the 33-column read through the coercing getters)
  run against a **PG-backed `Database` constructed directly** over the live backend with
  `schema/postgres/schema.sql` loaded, and the round-tripped `models.Name` is asserted **identical to the
  SQLite baseline** across the full type spread — TEXT (`name`/`label`/`owner` addr-hex), BIGINT
  (`expiry` u64, `created_block`), SMALLINT↔`bool` (`is_wrapped`/`migrated`/`is_normalized`), u256-as-TEXT
  (`token_id`), and nullable BIGINT (`wrapper_expiry` `?i64`). This is the first proof that production
  storage code — driver + PG dialect + OID-coercing getters — behaves identically on both backends end to
  end (not just hand-written probe SQL). Constructed `Database` directly (`.{ .allocator, .backend }`)
  rather than refactoring core `Database.init`/`loadSchemaFiles` for a backend seam yet — that wiring
  (`initWithBackend` + `selectBackend`/`DATABASE_URL`) remains the next Phase-4 step.
  **`Database.initWithBackend` landed — the shared bootstrap now runs on PG end-to-end
  (test-pg 10/10).** `init(allocator, path)` is a thin SQLite wrapper over the new
  `initWithBackend(allocator, backend)`; both backends share one path
  (loadSchemaFiles → migrate → reorg_undo.ensureSchema → installTriggers), each step made
  internally dialect-aware: (a) `isPostgres()` = `dialect.placeholder == .dollar`;
  (b) `hasTable` rewritten dialect-agnostic via `introspectColumns` (empty ⇒ absent on both
  backends — replaces the `sqlite_master` query); (c) `loadSchemaFiles` picks `schema/postgres/`
  vs `schema/`; (d) `migrate()` gates the SQLite-legacy in-place upgrades (the `is_normalized`
  ADD COLUMN, the `columnExists`-driven legacy `accounts` reshape) behind `!isPostgres()`, while
  the `CREATE TABLE IF NOT EXISTS`/index/backfill/synthetic-root-insert steps run on both;
  (e) `reorg_undo.ensureSchema` branches to BIGSERIAL/BIGINT, and `installTriggers` execs the
  generated PL/pgSQL `pgTriggerInstallSql` on PG (vs the per-table CREATE TRIGGER loop on SQLite).
  The headline test bootstraps a PG-backed `Database` via `initWithBackend`, round-trips
  `insertName`, then arms the v2 cursor and UPDATEs `names` — proving the **generated Postgres
  reorg-trigger DDL actually fires** (first live execution; capture row written with op `U`,
  `to_jsonb(OLD)` holding the pre-update row). Two reviewers (memory + correctness) ran on the diff.
  **Driver capability added — materialized result sets.** Surfaced by `initWithBackend`'s migrate:
  `backfillFromExistingData` (and much of the storage/indexer layer) iterates one query while
  issuing others per row — fine on SQLite (many live statements per connection), but a single
  pinned PG connection cannot hold a live server-side cursor and prepare concurrently
  (`UnexpectedDBMessage`). The PG driver's read path now **materializes** every result set into
  owned memory on `execute()` (a `union(enum){null,int,text}` per column, decoded via pg.zig's
  own getters) and releases the `pg.Result`/connection immediately; `step()`/getters read from the
  buffer. This decouples `Statement` lifetime from connection state and is the general fix for the
  nested-query pattern. Also fixed: `introspectColumns` casts the information_schema domain columns
  to `::text`/`::bigint` (pg.zig's native `row.get` is OID-strict), and a **statement-arena leak**
  (memory-reviewer Finding 1) where `doExecute` set `executed=true` *before* `execute()`, routing a
  failed execute into the no-op `freeRows` branch instead of `stmt.deinit()` — now flagged only after
  a successful execute, with a regression test (failed execute + deinit under the leak allocator).
  **Deferred to the dedicated "reorg rollback on PG" increment** (needs the replay round-trip test
  rig; none of these is reached by a wired path today since no binary calls `initWithBackend` with PG
  yet): (A — *headline*, correctness-reviewer) `getRestoreSql` (+ the op-`I` PK delete) build the
  restore upsert's `ON CONFLICT` target from `pk_pos > 0`, which on PG is the synthetic
  `id BIGSERIAL`, not the business `UNIQUE` key. SQLite's `INSERT OR REPLACE` resolves a conflict on
  *any* unique constraint, but PG's explicit `ON CONFLICT ("id")` only catches an `id` collision — so
  a delete-then-reinsert-same-key straddling N (the live row holds the business key under a *new*
  `id`) raises a `unique_violation` and **aborts the PG rollback** where SQLite recovers. Fix: on PG,
  target `schema_keys.conflictColsFor(table)` and drop `id` from the restored columns. (C) the PG
  trigger generator emits `CREATE TRIGGER` for every PROTECTED/REORG_ACTIVE table with no per-table
  existence guard (the SQLite loop has `tableExists`); safe on the init path (full schema loaded
  first) but add a guard for a future PG replay re-install. (D) `changes()` is still stubbed to 0 on
  PG — not used on any init/migrate/reorg-replay path, but must be implemented (CommandComplete tag
  count) before live PG *indexing* writers (which branch on affected-row counts) are enabled.
  Still next: `selectBackend` + `config.backend_kind`/`DATABASE_URL` + the PG-URL parser, then wiring
  the indexer/API mains to `initWithBackend(selectBackend(cfg))`, then the reorg-rollback-on-PG lane.
  **`selectBackend` + config-driven open landed (test-pg 13/13).** `config.Config` gains
  `backend_kind: BackendKind{sqlite,postgres}` (default sqlite) + `database_url: ?[]const u8`, parsed in
  `fromEnv`: explicit `DATABASE_BACKEND` wins (unrecognized → `log.warn` + fall through), else inferred
  from a `postgres://`/`postgresql://` `DATABASE_URL` scheme, else sqlite (so existing SQLite deployments
  are untouched). A new **`src/storage/db_open.zig`** holds `selectBackend(allocator, kind, sqlite_path,
  database_url) !Backend` (sqlite → `sqlite_driver.open(path)`; postgres → `parseUrl` → `postgres.open`;
  postgres-without-URL is a hard `error.MissingDatabaseUrl`, no silent fallback) and
  `openFromConfig(allocator, cfg) !Database` = `initWithBackend(selectBackend(cfg…))`. **Layering:**
  db_open is deliberately *not* imported by `database.zig`, so the core storage layer (compiled into every
  binary) stays free of the `pg` dependency — only code that opens a config-selected DB (this module, via
  lib or a future main) pulls in pg.zig; the exe modules/build.zig are untouched this increment.
  **`postgres.parseUrl`** parses `postgres://[user[:password]@]host[:port]/database[?…]` borrowing slices
  from the URL (open() dupes them); userinfo splits on the *first* `:` (passwords may contain `:`),
  authority on the *last* `@` (passwords may contain `@`), host:port on the *last* `:` — RFC/libpq-correct;
  panic-free on all malformed inputs (adversarially fuzzed: every bad URL returns a typed error, never an
  out-of-bounds slice). Percent-encoding + IPv6 literals are unsupported (documented; clean error, not a
  panic). **`postgres.open` now OWNS its connection params** — `pg.Pool.init` only copies the opts struct
  (dupes host only under TLS, which is off), so it *borrows* host/username/password/database for the pool's
  lifetime; open() dupes all four into PgConn-owned memory and `close()` frees them after `pool.deinit()`,
  making the Backend self-contained (no hidden ConnectOpts/URL-lifetime dependency). Tests: `parseUrl`
  (happy + `:`/`@`-in-password + empty-authority default + scheme/port/missing-db errors), `selectBackend`
  (sqlite + postgres dispatch + missing-URL error), and `openFromConfig(Config postgres)` → bootstrapped
  PG Database with an `insertName` round-trip. Two reviewers clean (memory: open()/close() errdefer chain
  frees each duped string exactly once on every failure interleaving, no leak/double-free; adversarial:
  parser correct + panic-free, no silent postgres→sqlite fallback).
  **Mains wired to config-driven open (test-pg 14/14; the real `ensv2-api` binary connects to live PG).**
  The three indexer mains switched `Database.init(cfg.database_path)` → `db_open.openFromConfig(cfg)` (full
  bootstrap) + an experimental-PG `log.warn`; `api_main` switched `initWithoutSchema(cfg.database_path)` →
  the new `db_open.openFromConfigReadonly(cfg)` (selectBackend + bare `Database`, NO bootstrap/migrate — the
  API is a read-only consumer and must not take a startup write lock that collides with the indexer; the
  no-write-lock invariant is preserved on both backends). `sync.checkIntegrity` gained a PG branch
  (`SELECT 1` liveness probe vs SQLite's `PRAGMA quick_check` page-integrity check — an intentional,
  in-code-documented asymmetry: deep verification is the server's job on PG). `build.zig` adds the `pg`
  module to exactly the 6 modules that root at a `db_open`-importing main (indexer/v1/v2 exes, api exe,
  unit_tests, api_tests); `database.zig` stays pg-free so the storage core and non-main targets
  (`indexer_test`, tools) don't pull pg. **SQLite is exactly behavior-neutral** for existing deployments
  (no `DATABASE_BACKEND`/`DATABASE_URL` ⇒ `backend_kind=.sqlite` ⇒ `selectBackend(.sqlite, database_path,
  null)` ⇒ the same `sqlite_driver.open` + same bootstrap as before — full suite stays 510/510). The
  startup DB log is now backend-aware (`sqlite <path>` vs `postgres (via DATABASE_URL)` — never logs the
  URL/password). Runtime-validated: `ensv2-api` started with `DATABASE_BACKEND=postgres` +
  `DATABASE_URL=…ensv2_test` logged "Database connected" + "API server listening", and a
  `openFromConfigReadonly` test reads a row a writer bootstrapped, without bootstrapping itself. A general
  adversarial review confirmed SQLite neutrality + the read-only invariant + correct build-target coverage.
  **Phase 4 backend seam is now complete end-to-end** (driver → dialect → schema → reorg → init →
  selectBackend → config → mains). Remaining before live PG *indexing* in production: the
  reorg-rollback-on-PG fix (Finding A — `getRestoreSql` keying on `id` vs the business key) and a real
  `changes()` (Finding D); the experimental warn gates operators until then.
  **Finding A FIXED — reorg rollback no longer aborts on Postgres (test-pg 15/15).**
  `reorg_undo.getRestoreSql` now derives the restore's `ON CONFLICT` target from
  `schema_keys.conflictColsFor(table) orelse pk_cols` instead of the introspected PK. The bug:
  on PG the restore conflicted on the surrogate `id BIGSERIAL`, so a row DELETEd then
  reINSERTed under the same business key within a reorg window (live row carries the key under a
  fresh `id`) raised a `unique_violation` on the business UNIQUE that `ON CONFLICT (id)` can't
  catch → aborted the whole rollback (SQLite's `INSERT OR REPLACE` conflicts on *any* unique, so
  it recovered). The fix is a **no-op for SQLite** (its `dialectUpsert` ignores conflict_cols), so
  the SQLite restore SQL is byte-identical and existing reorg behavior is unchanged (full suite
  510/510). **Coverage:** `conflictColsFor` gained the 6 reorg-captured tables that have a
  surrogate `id` PK + a separate business UNIQUE and weren't already dialect-upsert sites —
  `registry_entries`, `eac_roles`, `resolver_metadata`, `resolver_approvals`, `reverse_records`
  (inline `UNIQUE`), and `unknown_labels` (a reorg_active table whose uniqueness is a
  `CREATE UNIQUE INDEX(labelhash, parent_node)`, both NOT NULL; ON CONFLICT infers the index). All
  22 PROTECTED + 3 REORG_ACTIVE tables now resolve correctly: every surrogate-id+UNIQUE table via
  its business key, and only the natural-PK reorg_active tables (`accounts`→address,
  `v1_controllers`→controller_address) via the PK fallback. The 6 PG UNIQUE constraints were
  verified present in `schema/postgres/schema.sql`. A new PG regression test reproduces the exact
  delete-then-reinsert-same-key scenario on `names` and asserts the rollback succeeds and restores
  the pre-reorg row including its surrogate `id`. Two reviewers ran (memory: no leak/UAF — the
  conflict_cols slice is static or borrowed and consumed synchronously by `dialect.upsert`;
  correctness: coverage complete, op-`I` delete unchanged + still correct, SQLite neutral).
  **Boundary noted** (the schema's only FK is `unknown_labels.name_id → names(id) ON DELETE
  CASCADE`): the `names` restore's `id = excluded.id` could reassign `names.id` on a same-key
  reinsert, which would `foreign_key_violation` if a live child referenced the new id — but
  `unknown_labels.name_id` is always NULL in practice (the sole `insertUnknownLabel` site passes
  null), so the CASCADE never fires and the residual is theoretical. The fix is a strict
  improvement (prior behavior was an *unconditional* abort). Any future change that populates
  `unknown_labels.name_id` must revisit the names-restore id handling. Remaining for live PG
  *indexing*: only Finding D (`changes()` affected-row count) now.
  **Finding D FIXED — `changes()` returns the real affected-row count on PG (test-pg 16/16).**
  pg.zig's `Result` consumes and discards the `CommandComplete` row count, and there is no public
  API on `Result`/`Stmt` to recover it for a prepared statement (audited the full surface). So the
  driver's `exec()` now drains the response directly off the pinned connection — `stmt.execute()`
  then a `self.conn.read()` loop capturing the count from the `CommandComplete` tag
  (`affectedFromCommandTag`: trailing digit-run, NUL-tolerant — actually more robust than pg.zig's
  own `rowsAffected`), then `result.deinit()`. This is a faithful copy of pg.zig's internal
  `conn.execOpts` drain (which also calls `conn.read()` directly; the "should not be called
  directly" note is app-facing guidance, not a correctness constraint). The materializing
  `step()`/read path is unchanged and `changes()` is 0 there (matches SQLite's `changes()`-after-
  SELECT). Leak-safe (executed flag set only after a successful execute, mirroring the earlier
  fix; both error paths — in-`execute` and in-drain — leave the conn idle with no double-`Z` and
  free the Result arena exactly once). New driver test asserts INSERT 3 / UPDATE 2 / UPDATE 0
  (the `registrations.zig if changes()==0` control-flow case) / DELETE 1, plus a clean follow-on
  SELECT proving the manual drain doesn't desync the connection. Two reviewers clean (memory:
  no leak/UAF/double-free; protocol: no desync, count correct, no safer API missed); one parity
  nit applied (`else` branch now marks the conn `.fail` via `conn.unexpectedDBMessage`).
  **Phase 4 is now feature-complete for both read and write paths on PostgreSQL** — every gate
  that blocked live PG *indexing* (Finding A reorg rollback, Finding D affected-rows) is closed.
  What remains is breadth, not capability: a full cross-backend run of the storage/integration
  suites against PG and a real end-to-end indexer run on PG (the experimental warn stays until a
  maintainer signs off on that broader validation).
  **Cross-backend storage-suite run: 130/130 on PostgreSQL (SQLite still 510/510).** Made
  `helpers.createTestDatabase` backend-aware (`TEST_BACKEND=postgres` → open `ensv2_test`, reset
  `public` per test for isolation, `initWithBackend` + PG webhooks 001) and added a
  `test-storage-pg` build lane that re-runs the six storage suites (names/resolvers/roles/query/
  registry_entries/webhooks — 130 tests) against PG by reusing the compiled binaries with the env
  set. The run surfaced and fixed four real SQLite-isms in the storage write path (each a no-op or
  behavior-neutral on SQLite — full suite stays 510/510):
  (1) the webhooks `002` `ALTER … ADD COLUMN secret` is a SQLite-legacy idempotent backfill that
  errors on PG (001 already has the column); the PG test helper loads only 001.
  (2) `webhooks.insertWebhook` used `lastInsertId()` (SQLite rowid; the PG stub returns -1 →
  `@intCast` panic) → now `INSERT … RETURNING id` read via `step()` on PG (SQLite keeps its
  `exec()`+`lastInsertId()` path).
  (3) scalar two-arg `MAX(a,b)`/`MIN(a,b)` (accounts upsert, known_subregistries/known_resolvers
  upserts, `updateDomainExpiryIfGreater`) is SQLite-only; PG needs `GREATEST`/`LEAST` (its MAX/MIN
  are aggregate-only). Added `Dialect.scalar_max`/`scalar_min` (MAX/MIN vs GREATEST/LEAST — same
  `FN(a,b)` call syntax, all call-site args non-null so the NULL-handling difference is moot) and
  routed the sites through it (dynamic SQL, still statement-cached by content on both backends).
  (4) in PG's `ON CONFLICT DO UPDATE SET col = FN(col, excluded.col)`, the unqualified existing
  `col` is ambiguous with `excluded` → table-qualify it (`accounts.col`, `known_resolvers.col`);
  SQLite accepts the qualified form too. (Also fixed a latent double-close in the PG test-helper
  setup error path.) Storage tests run under the leak-detecting testing.allocator, so 130/130 also
  clears the new dynamic-SQL allocations.
  **events `json_extract` + `unknown_labels` `strftime` FIXED + cross-backend tested (SQLite
  test-storage 144/144; PG test-storage-pg 132/132).** The events filter/sort query builder routed
  its raw `json_extract(data,'$.x')` through `dialect.jsonExtract(data, x, null)` wrapped in explicit
  `CAST(… AS INTEGER)` / `LOWER(…)` (new helpers `jsonDataInt`/`jsonDataLower`/`expirySortExpr`) — the
  explicit CAST keeps the SQLite form byte-identical and is valid PG; the `.expiry` sort + the
  registration-style expiry filter (with/without the `$.expiration` fallback) are both dialect-built.
  `EventSortField.toSql()` returns `""` for `.expiry` (built via `expirySortExpr` instead). bind order
  is unchanged (the JSON expressions carry no placeholders). `unknown_labels.incrementBackfillAttempt`
  swapped `strftime('%s','now')` → `dialect.nowEpoch`. New cross-backend tests (in names_test, run in
  both lanes) assert the data_json_owner filter, expiry ascending sort, and `expiry_gte` filter on both
  backends, plus the backfill-attempt now-epoch UPDATE. Two reviewers clean (memory: all intermediates
  freed once, clause ownership single-owner; correctness: SQLite byte-equivalent, PG correct, bind
  order preserved, the `[2048]u8` ORDER-BY buffer is actually *less* pressured on PG since its
  expressions are ~4 bytes shorter per JSON fragment). One pre-existing, never-triggered edge recorded:
  `CAST(<non-numeric string> AS INTEGER)` is lenient on SQLite (→0) but errors on PG — moot because
  `data.$.expiry`/`$.duration` are always JSON integers from the indexer.
  **Integration suite retargeted at PostgreSQL: 35/35 (SQLite still 35/35).** `tests/integration.zig`'s
  30 inline `Database.init(:memory:)` calls now route through a backend-aware `testDb(allocator)`; the
  new `test-integration-pg` lane (TEST_BACKEND=postgres) runs the whole suite on PG. Because several
  tests hold TWO databases at once (the reorg reconcile comparator: clean-build-at-N vs rollback(N)),
  each PG test gets its OWN uniquely-named schema via `SET search_path TO it_N` (monotonic per
  sequential test; DROP IF EXISTS makes re-runs idempotent) — `public` would have them clobber each
  other. This **proves reorg rollback on PG end-to-end**: the reconcile comparator byte-compares
  rollback(N) against a clean build at N across every entity table (accounts/reverse_records/resolver_*/
  registrations/registry_entries/orphaned_registrations/unknown_labels, multi-protocol isolation, the
  op-`I` reversals, the PCC-materialize cases) — far stronger than the Finding-A unit test. Two
  production fixes this required: (a) `introspectColumns` was hardcoded to `table_schema = 'public'`,
  so a non-default search_path introspected the wrong schema (and `hasTable` saw leftover `public`
  tables → `loadSchemaFiles` skipped); now `table_schema = COALESCE(current_schema(), 'public')` with
  the PK subquery constrained to the same schema (also fixes a latent cross-schema PK-leak); for a
  normal production connection `current_schema()` = `public`, so it's semantically identical there
  (driver/storage PG lanes still 16/16 + 132/132). (b) the reconcile `dumpTable` helper used SQLite
  `PRAGMA table_info` → now the dialect-agnostic `db.introspectColumns`. Correctness-reviewed: the
  change is a strict improvement; the only note is that the content-ordered reconcile comparator can't
  catch a multi-column `pk_pos`-*ordering* regression — harmless because every multi-column conflict
  target comes from the pinned `schema_keys.conflictColsFor` (which overrides the `pk_pos`-derived
  order); the `pk_pos` fallback is only reached by single-column natural-key tables.
  **PostgreSQL is now validated across the entire test surface** — driver (test-pg 16/16), storage
  suites (test-storage-pg 132/132), and integration incl. the reorg reconcile (test-integration-pg
  35/35).
  **End-to-end indexer run on PG — DONE, and it found a real bug.** `ensv2-indexer`
  (DATABASE_BACKEND=postgres) against live Sepolia: bootstrapped PG (loaded schema/postgres, migrate,
  reorg triggers), indexed a 300-block V1 range, committed the batch transaction, and wrote real data
  to PG (names=1, registries=2, block_hashes=1, sync_state v1→10893510) — no crash, no PG error; V2
  then began its subregistry backfill (the 7.5M-block backfill is why a full continuous run doesn't
  terminate quickly in-sandbox). **The bug it surfaced:** `storage/transactions.zig`'s
  begin/commit/rollback wrappers passed `db` (the `*Database`) to the vtable instead of
  `db.backend.ptr` (the driver connection — what the `Tx` guard and every other call site pass). The
  wrong pointer's field offsets landed benignly on SQLite (the bug was latent/masked) but cast to a
  garbage `*pg.Conn` on Postgres → segfault at `conn.begin`. Fixed to pass `db.backend.ptr`; the
  combined indexer then runs cleanly on BOTH backends (SQLite reaches the same "Synced v1" checkpoint),
  and the full suite stays 512/512 (tests exercise the already-correct `Tx` guard, not the wrappers —
  which is why only the live indexer caught it). **`ensv2-indexer-v1` "crash" — INVESTIGATED, not a
  real bug.** During the E2E session one specific incrementally-built `ensv2-indexer-v1` binary crashed
  deterministically with `Illegal instruction at 0x…` right after "Dropped non-essential indexes" on
  BOTH backends — but it does NOT reproduce in any clean rebuild (5+ runs across markers/no-markers,
  8MB/256MB stack: 0 crashes, V1 syncs every time). A raw SIGILL with no Zig panic message +
  non-reproducible-after-rebuild is the signature of the sandbox's known virtiofs build-cache
  corruption (see the build memory), NOT a source-level bug. The V1-only binary runs reliably in clean
  builds; nothing in `startSingleProtocol` is broken. The experimental-backend warning stays pending a
  longer real production sync (a range with actual registrations indexed end-to-end), but the PG
  backend is functionally complete and end-to-end-proven for the main `ensv2-indexer`.
  The **network-independent slice is done + unit-tested**: `src/storage/drivers/postgres_dialect.zig`
  — the PG `Dialect` (`ON CONFLICT` upsert/insertSelect over non-key cols with the all-key→`DO NOTHING`
  edge; `(src::jsonb ->> 'col')::cast` jsonExtract; `jsonb_build_object`; `EXTRACT(EPOCH…)`;
  `placeholder = .dollar`) + the literal-aware `?`→`$N` lexer (`renumberPlaceholders`: bare `?`
  auto-numbers, explicit `?N` preserved so the reorg restore's single `?1` stays one param, `?` inside
  `'…'`/`"…"` skipped). 11 golden tests; both reviewers clean (lexer fuzzed 20k iterations; the
  id-preservation divergence vs SQLite's delete+reinsert assessed unobservable — no FK references the
  `.replace` tables' autoincrement ids). The eventual `drivers/postgres.zig` wires `pg_dialect` +
  `renumberPlaceholders` into its `Backend`/prepare.
- **Post-Phase-4 hardening (2026-06-05) — subregistry backfill on PG proven + chunked; crash
  root-cause nailed.** Closed the last indexer write-path not yet exercised on PG: the V2
  subregistry historical backfill (`event_fetchers.backfillSubregistryEvents`; the E2E run above
  was killed mid-backfill). Ran it on live Sepolia against BOTH backends (`10893210→10895200`,
  BATCH_SIZE=200) — discovery SQL (`MIN`+`GROUP BY`+`LEFT JOIN`), the `registerSubregistry` upsert
  (GREATEST + table-qualified), the nested register-while-iterating (works on PG via the driver's
  result materialization), and the backfill `getLogs` all produced **byte-identical results to
  SQLite** (same discovery log, fetch/skip counts, final data names=1/registries=2/
  known_subregistries=1/sync→10895200; 0 crashes). No PG-specific defect in the
  discovery/registration/backfill/V2-write path.
  **Then fixed the one real (backend-agnostic) robustness gap:** the backfill did a *single*
  address-filtered `getLogsMultiAddress` over `[start_block, discovery_block-1]` (≈7.5M blocks),
  which block-range-capped RPCs reject → caught+warned → historical events silently dropped. Now
  wrapped in the same adaptive-chunking loop as `indexSubregistryEvents` STEP 1 (MAX 10000 / MIN
  500, halve-on-error+sleep, skip-ahead MIN on persistent failure, grow-back +25%, inter-chunk
  rate-limit). Per-chunk event processing is byte-identical to before (same ENS+TransferSingle
  dispatch, errors caught; `markEventBlock` still omitted — correct, these pre-window blocks are
  never reorg-rolled-back per `indexer.zig` `undo_keep_from = to_block - 1000`). Build/fmt green,
  suite 512/512, chunked backfill empirically completes multi-chunk with identical PG↔SQLite data;
  a 3-lens adversarial review (memory + indexing-correctness + control-flow, each finding
  independently verified) found **0 confirmed defects**. Tradeoff: the common empty 7.5M range now
  costs ~750 chunks (one-time per subregistry, then cached in `known_subregistries`) — the inherent
  cost of robustness, same as main indexing already pays. The wide `start_block` floor is
  deliberate (catches events a subregistry emitted *before* its `SubregistryUpdate` registration).
  **Crash root-cause CORRECTED (supersedes the `ensv2-indexer-v1` SIGILL note above):** the
  recurring `Illegal instruction`/SIGSEGV is the **virtiofs install-copy of the ~16 MB indexer
  binary into `zig-out/bin/`** corrupting it — after a clean rebuild `md5(zig-out/bin/ensv2-indexer)`
  ≠ the same artifact installed to a container-fs prefix; the virtiofs copy crashes at startup
  (varying addr per rebuild, even `--help`, on BOTH backends), the container-fs copy runs perfectly,
  and a clean rebuild does NOT reliably fix it (the install step re-corrupts the `zig-out` copy).
  **Fix:** build with `--prefix` onto a container-local (non-virtiofs) filesystem and run the
  binaries from there; always
  smoke-test the indexer binary before trusting any runtime-crash result (recorded in the build
  memory).
  **Where this leaves the migration:** Phases 0–4 are complete and PG is proven across every test
  lane (driver 16/16, storage-pg 132/132, integration-pg 35/35) + a live indexer run including the
  now-hardened backfill. Remaining: (1) a longer **production sign-off sync** (a range with real
  registrations indexed end-to-end) to lift the experimental-backend warning; (2) **Phase 5** —
  publish `backend.zig` as the documented third-party SPI with a driver-conformance test both
  shipped drivers pass, document the `server_side_undo` choice, and keep a forced-`false` fallback
  CI lane. Phase 5 is NOT started. *(Superseded by the next entry — Phase 5 is now done.)*
- **Phase 5 + production sign-off (2026-06-05) — DONE. Phases 0–5 are all complete.**
  **Production sign-off sync — PASSED; experimental warning lifted.** Indexed the
  registration-dense Sepolia range `10980700→10989200` (8,500 blocks; ~46 V2 `NameRegistered`
  + renewals + registry/resolver traffic) end-to-end on BOTH backends with the production
  binary (`--from-block/--to-block`, full subregistry-discovery backfills, webhook workers
  started): PG wrote names=1392, registrations=115, events=3409, resolvers=1390,
  eac_roles=202, accounts=30, both protocols checkpointed exactly at 10989200, zero errors.
  A full-table A/B against an identical SQLite run (every table, volatile wall-clock columns
  and surrogate ids excluded, deterministic ordering) reported **full parity on every chain-derived column**: all 27 compared tables have identical key sets (zero missing/extra rows on either side), `events` is byte-identical across all 3,409 rows including the `data` JSON, and the only differing columns anywhere are ingestion-wall-clock fields (`names.updated_at`, `resolver_*.timestamp`, `eac_roles.timestamp`, `v1_controllers.created_at`, `block_hashes.timestamp`) — which differ between any two runs by construction. The
  `indexer_main` experimental-PG warning (whose stated reasons — reorg rollback +
  affected-row counts — were both already fixed) is removed. Two non-PG findings from the
  first sign-off attempt: (a) the *combined* indexer never indexes the Sepolia legacy-V1
  contracts (`should_index_v1` keys on `temp_registrar_start_block`, which is 0 on Sepolia —
  Sepolia "V1" registrations on the fresh 10893210 deployment are visible only to lanes that
  fetch those contracts), backend-independent, documented here as a known indexer-scope
  gate; (b) the webhook manager's own SQLite queue DB on a virtiofs path SIGBUSed under 8
  worker threads in-sandbox — environment-only, fixed for the runs via `WEBHOOK_DB_PATH` on
  the overlay.
  **Phase 5 — delivered.** (1) `Capabilities` wired for real: `Backend` carries `caps`
  (statically declared per driver: both `server_side_undo=true`, `returning=true`,
  `savepoints=true`; placeholders `.qmark`/`.dollar`; PG `pooled=true`), exposed via
  `Database.caps()`. (2) **`server_side_undo=false` is rejected** at
  `Database.initWithBackend` (`error.UnsupportedBackendCapabilities`) — see scope decision
  below. (3) **Driver-conformance suite** `tests/storage/backend_conformance_test.zig` (20
  named tests): caps sanity + the rejection, sequential 1-based binds + copy semantics,
  NULL handling through every accessor, step ordering/done, `changes()` after DML exec,
  the insert-id idiom (lastInsertId vs RETURNING, mirroring `webhooks.zig`), owned-vs-borrowed
  text lifetimes, i64 extremes + bool coercion, Address/Hash binder round-trips,
  `introspectColumns` (incl. empty-on-missing, which `hasTable` relies on), `Tx`
  commit/rollback-on-deinit, savepoint nesting, multi-statement `exec`, every `Dialect`
  builder round-tripped through real SQL (upsert replace/ignore, insertSelect, returning,
  jsonObject, jsonExtract+cast, nowEpoch, scalar max/min), placeholder-in-literal
  preservation, and prepare-failure usability. Wired into `test-storage`, the default
  `test`, and the `test-storage-pg` loop — **both shipped drivers pass** (SQLite
  test-storage 164/164; PG test-storage-pg 152/152). Its first PG run immediately caught a
  real driver bug: jsonb result columns came back with the 1-byte binary version header
  (0x01) still attached → `materializeValue` now strips it (OID 3802). Two driver logs were
  re-leveled err→warn (prepare failure ×2, the caps guard) because the default test runner
  fails any test that emits err-level logs and the suite exercises those paths; callers
  still receive + report the errors. (4) **SPI published**: `docs/backend-spi.md` documents
  the full contract (VTable/StmtVTable slot semantics, ownership rules incl. the
  materialized-result-set allowance, Dialect, Capabilities, threading = single pinned
  session, the corrected extension recipe, and how to run the conformance suite as the
  acceptance gate); the sqlite driver is exported from `lib.zig` alongside postgres.
  Full matrix green: `zig build test` 532/532, integration 35/35 (SQLite) + 35/35 (PG),
  test-pg 16/16, graphql 120/120. Both project reviewers (memory + indexing-correctness)
  ran on the diff: **no findings** (one docs nit applied).
  **Scope decision — the planned forced-`false` CI lane is replaced by a rejection guard.**
  The Phase-5 row predates Phase 3's W9 deferral: the write-path capture fallback was never
  built (recorded twice as "not required for the SQLite or Postgres ship path"), so there is
  nothing for a forced-`false` lane to exercise — and a backend silently declaring `false`
  would have indexed with broken reorg rollback. The honest hardening is to refuse such a
  backend at open time (loud failure, pinned by the conformance suite) and document W9 as
  the prerequisite for ever accepting `false`. If W9 lands, swap the guard for the fallback
  + revive the forced-`false` lane per the original plan.
- **Post-Phase-5 follow-on #1 (2026-06-06) — connection pool / acquire-per-request API
  topology: DONE.** The last correctness-relevant gap in the PG story: the API is
  thread-per-request and shared ONE `*Database` across all request threads — safe-ish on
  SQLite only by `SERIALIZED` (and even there racy at the Zig layer, see the design-section
  note), and protocol-corrupting on PG (same class as the webhook-manager crash). Shipped:
  `src/storage/pool.zig` (exclusive-checkout session pool, see the design-section reality
  note for the two deliberate divergences from the sketch), `DATABASE_POOL_SIZE` (default
  10), and the API conversion — `Server` holds a `*Pool`; the three REST endpoints and the
  two GraphQL dispatch sites acquire/release per request (GraphQL block-scopes the session
  so it returns to the pool *before* response serialization and the possibly-slow client
  socket write); `GraphQLHandler` lost its `database` field (the session is set on the
  per-request executor copy + `LoaderContext`); REST row frees use the session's allocator
  (allocator-identity correctness if the pool ever opens with a different allocator).
  **Validation:** 6 pool tests in both lanes (test-storage 170/170, test-storage-pg 157/158
  +1 skip) — exclusive ownership, exhaustion blocking, a 6-thread concurrent-query hammer,
  deinit-drain, and a shutdown test pinning the parked-acquirer/`PoolClosed` race found by
  review; LIVE: `ensv2-api` served **180/180 concurrent mixed GraphQL+REST requests on BOTH
  backends** (PG: 10 sessions against ensv2_signoff; SQLite: 10 file sessions), zero errors,
  correct data (`_meta` at 10989200). Full matrix green incl. the previously-missed
  `test-api` lane (the reviewers caught stale inline tests in handler/server that broke
  `zig build test` — fixed; also `postgres_driver_test`'s Config literal gained the new
  field). Three review rounds (memory ×2 + indexing-correctness): all findings fixed, incl.
  the acquire/deinit shutdown race (closed-state + broadcast; a lone `signal` could be
  swallowed by a parked acquirer exiting `PoolClosed`, starving `deinit`) and the
  ReleaseFast-compiled-out double-release assert (now an unconditional panic).
  **Disposition of the remaining optional follow-ons:** (a) **pipelining/`COPY` fast-paths —
  deferred**, benchmark-driven opt-in per the risk table; nothing blocks on it and the
  events bulk path is already batched at the write-buffer layer. (b) **`events` partitioning
  on PG — stays a deployment-appendix option** (pure ops DDL, no code support needed).
  (c) **W9 write-path fallback — unchanged**; the `server_side_undo=false` rejection guard
  stands until a trigger-less backend actually matters. *(Superseded by the next entry.)*
- **Post-Phase-5 follow-on #2 (2026-06-06) — W9 write-path capture fallback: DONE. The
  rejection guard is replaced by a working fallback; the plan has no unimplemented items
  left.** `server_side_undo=false` now opens normally: `initWithBackend` skips trigger
  install and the storage mutators capture pre-images themselves.
  **Implementation.** New helper block in `reorg_undo.zig` (`captureWhere`,
  `captureWhereBinder` for runtime-arity IN-lists, `captureUpsert` — comptime WHERE from
  `schema_keys.conflictColsFor`, `captureActiveWhere`, `activeRowExists` for I-vs-U branch
  discrimination; anytype bind dispatch over Protocol/Hash/Address/ints/optionals/slices).
  Each capture is ONE atomic `INSERT…SELECT` into `reorg_undo` mirroring the trigger
  semantics exactly: per-row cursor gate (`EXISTS` on `reorg_cursor` for the row's own
  protocol + scalar-subquery block tag) for protected tables, `reorg_active` context for
  active tables, `dialect.jsonObject` over introspected columns as the snapshot — so
  multi-row WHEREs capture every matched row like FOR EACH ROW, and new columns are
  auto-captured. **All 65 inventoried sites instrumented** (fresh inventory reconciled
  against the appendix: the delta is exactly the W6–W8 additions): names 22 calls (incl.
  the explicit `unknown_labels` cascade pre-capture at `deleteNameByNamehash` — the one
  `ON DELETE CASCADE` the triggers caught via recursion), resolvers 24, the rest across
  registrations/registry_entries/roles/ensip16/events/sync/accounts/v1_controllers/
  unknown_labels/v1-handlers. Helpers no-op on shipped backends (one bool check).
  **Validation — the lane the plan asked for, proven non-vacuous.** New build step
  `test-integration-fallback` runs the FULL integration suite with SQLite doctored to
  `server_side_undo=false` (no triggers): **38/38 green**, including the full-table
  reconcile (rollback ≡ clean-sync-at-N). A **control experiment** (capture force-disabled)
  fails **20/35** — the first lane wiring (via tests/helpers) was exposed as vacuous by
  this control (integration tests build their DB via their own `testDb`) and re-wired;
  always run the control. Three NEW adversarial hard-site tests close the Lane-3 gaps the
  correctness review found (they run in trigger, fallback, AND PG lanes): the dynamic-IN
  reachability flip + rollback (the only runtime-binder site), names-delete restoring
  `unknown_labels` cascade children (surrogate-id-preserving restore keeps the FK valid),
  and key-scoped `resolver_texts` delete + `created_block`-lowering revert (replay restores
  created_block, then the created-after delete removes the row — rollback ≡ clean sync).
  Remaining hard cases (v1_controllers straddle, accounts cross-protocol I+U, bulk
  resolver-record deletes) were already covered by the existing suite, per review.
  **Review findings fixed (memory ×1 + indexing-correctness ×1):** (a) pre-existing
  `Statement` bound-string overflow was a use-after-free (free-then-bind past 32 tracked
  binds) — now `error.TooManyBoundParams` BEFORE binding, and `setRegistriesReachability`
  chunks its IN-list at 24/statement (mutation + capture both), removing the only
  production path that could exceed the cap; (b) the v1-handler heal's capture failure was
  swallowed (`catch {}`) while the DELETE proceeded — now `catch return` (skip the delete,
  preserving capture-mutation atomicity parity with triggers); (c) the SPI doc still
  promised the old rejection — `docs/backend-spi.md` + the `Capabilities` doc now state the
  real contract: `false` ⇒ write-path fallback covering exactly the instrumented mutators
  (raw SQL elsewhere is NOT captured), `test-integration-fallback` as the conformance gate,
  and `true` only with real triggers (else helpers no-op ⇒ silent corruption).
  **Capture-parity verified adversarially:** 15+ sites sampled — every capture WHERE is
  textually identical to its mutation's predicate, binds in order, SET args excluded; all
  18 `captureUpsert` arg lists match `schema_keys` conflict order; `resolver_approvals`'
  NULL-context never-matches mirrors ON CONFLICT's NULL-distinct semantics; double-mutation
  ordering and capture-then-failed-mutation are restore-equivalent to triggers.
  **Bonus: the new cascade test caught a REAL pre-existing PG-trigger-lane reorg bug.** On
  SQLite, `recursive_triggers` fires the `unknown_labels` cascade-capture BEFORE the parent
  `names` capture, so id-DESC replay restores parent-then-child (FK-valid). On PostgreSQL the
  cascade fires AFTER the parent's trigger — replay then restored the child first and hit the
  immediate `name_id` FK, aborting the rollback. Fixed backend-independently in `replayUndo`:
  a two-pass walk (every other table first, `unknown_labels` — the schema's only FK child —
  second; newest-first order preserved within each pass), with the per-entry logic factored
  into `replayEntry`. All three lanes (trigger SQLite, write-path, PG triggers) now pass the
  cascade test 38/38.
  **Known limitations (documented in the SPI doc):** coverage = instrumented mutators only
  (the grep-lint/coverage-map idea from the original plan is subsumed by the behavioral
  gate + the review inventory); per-capture introspection+SQL build is unoptimized (fallback
  lane only — shipped backends pay one branch).

---

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| A new protected table/site is added without trigger coverage (forgotten from the arrays) and without a fallback waiver → silent reorg corruption (the 2026-06-02 failure class) | Medium | Critical | Now bounded to the *fallback* (shipped backends keep triggers). Three-layer compile-time coverage map: comptime assert every protected table has a declared strategy; comptime cross-check `sync.zig` delete-lists ⊆ `PROTECTED ∪ REORG_ACTIVE`; CI grep-lint vs the 60-site golden inventory so a 61st site **fails the build** until wrapped |
| Generated Postgres PL/pgSQL triggers diverge from SQLite semantics (implicit-DELETE vs ON-CONFLICT-UPDATE, `to_jsonb` key-order/type) → non-equivalent rollback | Low | High | **Design settled, doc-verified & adversarially approved** (see [Postgres trigger design](#postgres-trigger-design-settled)); divergence is only the 12 literal-IOR op-letters (`replayUndo` treats `U`≡`D`). A/B Lane 2 under harness rule **H1** (decode-and-canonicalize `old_row` + post-rollback state, never raw-string compare) is the backstop |
| Write-path fallback bit-rots — no shipped backend uses it by default, so a third-party NoSQL backend is first to hit a capture bug (esp. the bulk/dynamic sites) | Medium | High | Dedicated CI lane forces `server_side_undo=false` on SQLite and runs the full reorg suite (`d663945`) every PR; A/B Lane 3 adversarially seeds every hard site with a cursor active |
| `materializePccDomainExpiry` self-captures one row per wrapped name (cursor still armed on first sync) — unbounded over-capture, under triggers *and* write-path | High | Low | Mechanism-independent fix: wrap in `clearCursor()`/`invalidateReorgCursor()` or run before the cursor is armed; test that `reorg_undo` is empty after a clean first bulk sync |
| `?`→`$N` rewriter mangles SQL (a `?` inside a quoted string, etc.) | Medium | High | Proper literal-aware lexer with focused unit tests (quoted strings, double-quoted idents, dollar-quoting, comments); memoize per unique SQL; fuzz against the storage modules' real SQL corpus |
| Erased vtable sacrifices compile-time safety at the boundary | Low | Medium | Comptime `VTable{…}` literal (a missing field is a compile error) + `verifyVTable()`; ship a driver-conformance suite as an executable spec |
| Postgres prepared statements are per-connection; mishandling the pool breaks reuse or txn coherence | Medium | High | `prepare`/`begin` check out and **pin** one pooled connection for a `Statement`/`Tx`; single-writer indexer uses a 1–2 conn write pool; read conns get their own caches; assert pinning in tests |
| Two schema dialects drift; the transpiler misses a DDL construct (runtime, not compile-time, failure) | Low | Medium | SQLite is the single source of truth; **generate** Postgres at build; schema-parity test (same 38 tables) + **per-column type-class assertion** (integer-vs-text, 337 cols); build fails on an unrecognized DDL token |
| A future schema change adds a genuine PG `BOOLEAN` (strict-read by `getBool`) or a `SELECT *` (ordinal fragility), defeating the coercing-getter guarantees | Low | High | Build-time enforcement: transpiler asserts **no `BOOLEAN` token** survives (rule B2) + per-column type-class parity; a **lint forbids `SELECT *`** in `src/storage/*.zig`. Both convert a latent Postgres-runtime failure into a compile error |
| A coercing `colInt64` silently mis-parses a malformed/oversized numeric and returns a wrong `i64`, masking a transpiler/data bug | Low | Medium | `colInt64` only ever sees integer-class types (B1/B2); treat unparseable text→int as a **driver panic in debug**, not silent 0; the type-class parity assertion catches an INTEGER↔TEXT regression independently of the read path |
| `unknown_labels.name_id → names(id) ON DELETE CASCADE` cascade-deletes uncaptured rows on a reorg-time `names` delete → rollback ≠ clean-sync-at-N (pre-existing, both backends) | Low | Medium | Surfaced by the construct audit. Assess relevance (`unknown_labels` is a backfill work queue, may self-heal); if it matters, add `unknown_labels` to `PROTECTED_TABLES` (+ `name_id` index) so both backends' triggers capture the cascade. The A/B Lane-3 suite should include a names-delete-with-`unknown_labels`-children case |
| Per-mutation `captureBefore` adds SELECT+INSERT for non-trigger backends (more I/O than in-engine capture) | Low | Low | Capture only runs at chain head (cursor set), never during bulk backfill; the write buffer's dedup already collapses redundant mutations; SQLite keeps the zero-extra-SELECT trigger path |
| pg.zig bugs / API gaps for txn-pinned prepared stmts + pipelining | Low | Medium | **Surface verified** against `zig-0.15` source — sequential `Stmt.bind` + `prepareForBind` (dynamic arity), `begin/commit/rollback`, per-conn named cache, borrowed row lifetime, no `io` param all present (see Decision 2). Residual: pipelining/`COPY` fast-paths are an opt-in not yet verified; keep SQLite as fallback |

---

## Decisions recorded (previously open)

- **Do NOT flip SQLite to write-path capture.** Server-side triggers stay canonical for SQLite —
  audited, and they capture bulk/dynamic multi-row mutations per-row for free. *(Settled by the
  60-site audit.)*
- **Postgres uses generated PL/pgSQL AFTER triggers by default** (`server_side_undo=true`), not
  write-path. Write-path is the fallback for trigger-less backends only. *(Settled by the audit.)*
- **Connection routing: a `Pool` provides per-connection `Database` sessions; indexer pins one writer,
  API acquires one reader per request thread.** Verified topology: separate binaries; API is
  thread-per-request; the indexer write loop is single-threaded and its status thread touches no DB.
  SQLite's pool is degenerate (the one shared serialized conn — zero behaviour change); Postgres uses
  a writer pool of 1 + a reader pool of `DATABASE_POOL_SIZE`. *(Settled; see [Connection routing & pooling](#connection-routing--pooling).)*
- **Schema construct pass complete — the schema is vanilla.** 38 tables / 104 indexes / 1 `CHECK` / 1
  FK / 0 views/triggers/FTS/`COLLATE`/generated/`WITHOUT ROWID`/reserved-word columns. Transpiler
  scope is fully bounded (`AUTOINCREMENT`, `strftime` defaults, `INTEGER`→`BIGINT`, the lone `BOOLEAN`,
  and one `json_extract` expression index — rules B1–B4). One pre-existing cascade-FK reorg gap flagged
  to verify (`unknown_labels`). *(Settled by the construct audit.)*
- **pg.zig (`zig-0.15`) exposes the surface the design needs.** Verified against source: sequential
  `Stmt.bind` + `prepareForBind` (so dynamic-arity queries work), `conn.begin/commit/rollback`,
  per-connection named statement cache (`cache_name`/`deallocate`), borrowed row-data lifetime, and a
  `Pool.init` with **no `io` param** on this branch. The `Statement`↔`Stmt` mapping table lives in
  Decision 2. *(Open only: optional pipelining/`COPY` fast-paths for the events bulk path.)*
- **The Postgres reorg-trigger design is settled, doc-verified, and adversarially approved.** Two
  generic PL/pgSQL functions (cursor gate in the body since `WHEN` forbids subqueries), `to_jsonb(OLD)`
  snapshot, protected {U,D}/active {I,U,D} trigger sets. The only divergence is the **12 literal-IOR
  sites** (SQLite `D` / PG `U`), harmless since `replayUndo` treats `U`≡`D`. Issue #3 guardrail
  (SQLite `dialect.upsert` keeps literal `INSERT OR REPLACE`) and the `->>`-needs-`::bigint`-cast on
  replay are specified. *(Settled by the trigger-design workflow; see [Postgres trigger design](#postgres-trigger-design-settled).)*
- **Read-path typing is fixed in ONE place (coercing PG getters), not per-site.** A ~290-site audit
  found **0 type mismatches** and **no `SELECT *`**; the nine `Query` modules and legacy
  `sqlite3_column_*` readers need **zero read edits**. Residuals are *writes/DDL only*, with exact
  refs: `v1_controllers.zig:16,18,42,65` + `schema.sql:629` (the lone `BOOLEAN` → transpiler rule B2,
  no Zig change) and `reorg_undo.zig:92,118` (`PRAGMA table_info` → `dialect.introspectColumns`).
  *(Settled by the read-path audit.)*

## Open Questions

- ~~Conflict-key source of truth for `dialect.upsert`~~ — **RESOLVED (static map).** A comptime
  `table → conflict-cols` map lives in `src/storage/schema_keys.zig` (`conflictColsFor`), consumed by
  `Database.upsertSql(allocator, table, cols, action)`. Every in-scope table has exactly one
  `UNIQUE(...)`/natural-PK constraint besides its autoincrement `id`, so the target is unambiguous and
  derived directly from `schema/schema.sql`. SQLite ignores the key (the verb implies it), so it is
  invisible to behavioural tests — its sole guard is the `schema_keys` unit test that pins **all 25
  entries** and asserts the map has no extra/missing rows (wired into `test-storage`). Phase 4
  validates the keys live against the Postgres catalog. Desync risk is therefore caught at build time
  (count/pins) and at Phase-4 integration (real `ON CONFLICT`).
- `BIGINT` (Postgres) vs `INTEGER` (SQLite) boundary values — keep numeric semantics identical for
  `u64` expiries mapped to `i64` (`safeU64ToI64`) and unsigned-ish columns across backends. (pg.zig
  accepts `i64` natively and `u64` "coerced if it fits", so the existing `safeU64ToI64` clamp is the
  integration point; verify the few sentinel/maxima columns.)
- Does shipping Postgres (where re-index-from-scratch on a large remote DB is far costlier than on a
  local SQLite file) change the calculus toward a real migration tool, or does the empty migration
  ladder stay retired forever?

---

## Appendix: Reorg capture-site inventory

This is the **golden fixture** for the coverage-map CI lint (§ Reorg undo-log strategy → Guarding
coverage). It is the verified set of every site that mutates a `PROTECTED`/`REORG_ACTIVE` table and
therefore needs undo capture. An independent grep sweep (literal + dynamic `allocPrint` table names)
across `src/storage/*.zig` and the three non-storage raw-C files found **no missed site**; all 23
tables are accounted for, and `sync.zig`'s created-after delete-lists correctly handle brand-new
rows so they need no capture.

**Totals:** ~60 require-capture sites across ~14 files, exercising **35 `UPDATE`**, **13
`INSERT OR REPLACE`** (implicit-delete on SQLite / `ON CONFLICT DO UPDATE` on Postgres), **12
`DELETE`**, and **2 active-table `INSERT`** operations. (Upsert sites have both an insert and an
on-conflict-update branch, so the per-op tallies sum to slightly more than the site count.)

| Table | Sites | Capture mechanism today (SQLite triggers) |
|-------|------:|-------------------------------------------|
| `names` | 23 | AFTER UPDATE/DELETE: `insertName` upsert U-branch + 21 plain UPDATEs + `deleteNameByNamehash` (also looped by `recursivelyGcEmptyDomain`). Brand-new `insertName` rows reversed by `sync.zig created_block>N`. |
| `registries` | 2 | AFTER UPDATE (`updateRegistryPlaceholderName`); `insertRegistry` is `INSERT OR IGNORE` → reversed by `created_block>N`. |
| `registrations` | 3 | AFTER UPDATE (expiry/registrant/economics); insert is `INSERT OR IGNORE` → `block_number>N`. |
| `registry_entries` | 1 | `upsertSubregistry` `ON CONFLICT DO UPDATE` U-branch; brand-new → `updated_block>N`. |
| `approvals` | 2 | `updateApprovalTokenId` UPDATE; `insertApproval` `INSERT OR REPLACE` (implicit DELETE). |
| `eac_roles` | 2 | `upsertEACRole` `ON CONFLICT DO UPDATE` (AFTER UPDATE); `deleteEACRole` DELETE. |
| `resolver_addresses` … `resolver_interfaces` (8 record tables) | 2 each | `store…` `INSERT OR REPLACE` (implicit DELETE) + bulk `delete…` DELETE. |
| `resolver_texts` | 3 | `INSERT OR REPLACE` + **two** delete paths: bulk `deleteResolverTexts` (@732) **and** key-scoped `deleteResolverText` (@799, empty-value `TextChanged`). |
| `resolver_versions` | 1 | `INSERT OR REPLACE`. |
| `resolver_metadata`, `resolver_approvals` | 1 each | `ON CONFLICT DO UPDATE` via **raw-C** sqlite (still fires triggers). |
| `resolver_dns_records` | 2 | `INSERT OR REPLACE` + DELETE. |
| `resolver_dns_zonehashes`, `resolver_authorisations` | 1 each | `INSERT OR REPLACE`. |
| `reverse_records` | 1 | `upsertReverseRecord` `ON CONFLICT DO UPDATE` (AFTER UPDATE); brand-new → `block_number>N`. |
| `accounts` *(active)* | 1 | `upsertAccount` → **both** op-`I` (new) and op-`U` (conflict) captured via `reorg_active` triggers; `replayUndo` op-`I` clears only this protocol's seen-flag. Excluded from `sync.zig` delete loops (cross-protocol). |
| `v1_controllers` *(active)* | 2 | `addController` (`I`+`U`) + `removeController` (`U`) via `reorg_active` triggers; reversed by `replayUndo`. |

**Hard cases the A/B suite must exercise** (each a named test): `setRegistriesReachability` bulk
`IN(...)` multi-row UPDATE; `recursivelyGcEmptyDomain` cascade DELETE down a parent chain; **both**
`resolver_texts` delete paths; `updateNameCreationDate` lowering `created_block` (undo-log is the
*only* correct rollback path, since it defeats the `created_block>N` net); `v1_controllers`
remove-then-readd straddling N (op `U` then `I`); `accounts` cross-protocol rollback (rolling back
V1 must not drop a row V2 still claims).

**`INSERT OR IGNORE` sites are correctly *not* captured** (no implicit delete, no UPDATE): brand-new
rows in `registries`/`registrations`/`resolvers`/`events`/`unknown_labels`/`orphaned_registrations`
are reversed by `sync.zig`'s `created_block`/`block_number`/`updated_block > N` deletes, which run
*after* `clearCursor` + `replayUndo` so they never self-capture.

---

## Appendix: PostgreSQL deployment considerations

These are PostgreSQL-driver-specific operational notes; they live below the abstraction and do not
affect the interface.

### Connection pooling

pg.zig ships a built-in pool with background reconnection:

```zig
var pool = try pg.Pool.init(allocator, .{
    .size = 10, .connect_timeout = 5000, .idle_timeout = 300000,
    .database = "ensv2", .host = "localhost", .port = 5432,
});
```

The single-writer indexer needs only a small write pool (1–2 conns) with connection pinning for
transactions; the read-heavy GraphQL API can use a larger pool. Consider PgBouncer for connection
multiplexing in production.

### Performance tuning

```sql
ALTER SYSTEM SET shared_buffers = '256MB';
ALTER SYSTEM SET work_mem = '64MB';
ALTER SYSTEM SET maintenance_work_mem = '128MB';
ALTER SYSTEM SET effective_cache_size = '1GB';
ALTER SYSTEM SET random_page_cost = 1.1;  -- SSD
```

### Indexes & partitioning

All SQLite indexes translate directly. Postgres-only additions worth considering:

```sql
CREATE INDEX idx_names_active ON names (protocol, namehash) WHERE ejected = false; -- partial
CREATE INDEX idx_events_block_brin ON events USING BRIN (block_number);            -- time-series
```

Partition the unbounded `events` table by block range so re-indexing recent blocks is a
`DROP TABLE events_pN` (instant, no `VACUUM`) instead of a large `DELETE`:

```sql
CREATE TABLE events (
    id BIGSERIAL, block_number BIGINT NOT NULL, log_index INTEGER NOT NULL,
    tx_hash TEXT NOT NULL, event_type TEXT NOT NULL, protocol TEXT NOT NULL,
    namehash TEXT, data JSONB, created_at BIGINT NOT NULL,
    PRIMARY KEY (id, block_number)
) PARTITION BY RANGE (block_number);

CREATE TABLE events_p0 PARTITION OF events FOR VALUES FROM (0) TO (1000000);
-- … add partitions ahead of need; ~1M blocks ≈ 83 days on mainnet
```

`names` is bounded (~1.5M rows, stable after migration) and is **not** partitioned.

### Re-indexing strategies

| Scenario | SQLite | PostgreSQL |
|----------|--------|------------|
| Full re-index (fresh start) | `rm database.db` | Create new DB, index into it, swap with `ALTER DATABASE … RENAME` |
| Re-index recent blocks | delete by block predicate | `DROP TABLE events_pN` (with partitioning) + `DELETE` from small tables |
| Fix specific records | normal UPDATE/DELETE | normal UPDATE/DELETE |

### Future enhancements unlocked by Postgres

LISTEN/NOTIFY for webhooks (replace polling), full-text name search, JSONB queries on event data,
read replicas for the GraphQL workload.

---

## References

- [pg.zig](https://github.com/karlseguin/pg.zig) · [commit history](https://github.com/karlseguin/pg.zig/commits/master) · [async fork](https://github.com/lalinsky/pg.zig)
- [zqlite.zig](https://github.com/karlseguin/zqlite.zig) · [vrischmann/zig-sqlite](https://github.com/vrischmann/zig-sqlite) ([design notes](https://rischmann.fr/blog/how-i-built-zig-sqlite))
- Zig DB tooling surveyed: [HARMONICOM/dig](https://github.com/HARMONICOM/dig), [Tony-ArtZ/zorm](https://github.com/Tony-ArtZ/zorm), [tinyzimmer/sqlc-gen-zig](https://github.com/tinyzimmer/sqlc-gen-zig)
- [matklad — comptime Zig ORM (why to avoid)](https://matklad.github.io/2025/03/19/comptime-zig-orm.html) · [kristoff.it — simplistic comptime SQLite](https://kristoff.it/blog/simplistic-comptime-sqlite/)
- [PostgreSQL docs](https://www.postgresql.org/docs/) · [Zig Package Manager](https://ziglang.org/documentation/master/#Package-Management)
