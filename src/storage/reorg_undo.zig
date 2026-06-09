/// Reorg undo-log — makes `rollbackToBlock(N)` bit-equivalent to a clean sync at N
/// by reversing in-place mutations (UPDATE) and clear-DELETEs to rows that existed
/// at or before the reorg block. Inserts (rows created after N) are handled by the
/// existing created_block/block_number deletes in sync.zig.
///
/// Design (protocol-agnostic, schema-driven — no per-table hardcoding):
///   - `reorg_cursor(protocol, block_number)` holds the block currently being
///     processed, set per event by the indexer. AFTER UPDATE/DELETE triggers on the
///     protected tables capture the OLD row (as a json_object of every column) tagged
///     with that block — but ONLY while a cursor is set, so backfill/replay (no
///     cursor) and the rollback itself (cursor cleared) never self-capture.
///   - Many derived tables (resolver records, approvals, …) are rewritten with
///     `INSERT OR REPLACE`, whose implicit row delete only fires the AFTER DELETE
///     trigger when `PRAGMA recursive_triggers = ON` — Database.init sets it, so
///     in-place overwrites are captured too (not just explicit UPDATE/DELETE).
///   - accounts is cross-protocol (no `protocol` column); it is captured by dedicated
///     triggers keyed off the single-row `reorg_active` context instead, and its
///     after-N first insertions are removed by sync.zig's `first_seen_block > N` delete.
///   - `rollbackToBlock(N)` calls `replayUndo`: reverse-applies every captured row
///     with block > N (newest-first via id DESC) using a generic INSERT OR REPLACE
///     reconstructed from `PRAGMA table_info`, then prunes those undo rows.
const std = @import("std");
const db_module = @import("database.zig");
const backend = @import("backend.zig");
const Database = db_module.Database;
const Query = db_module.Query;
const models = @import("../types/models.zig");

/// The mutation surface that needs undo coverage: every derived table mutated in
/// place (UPDATE) or via clear-DELETE. Inserts are covered by sync.zig's deletes.
/// Each table must carry a `protocol` column (verified: all do).
pub const PROTECTED_TABLES = [_][]const u8{
    "names",
    "registries",
    "registrations",
    "orphaned_registrations",
    "registry_entries",
    "approvals",
    "eac_roles",
    "resolver_addresses",
    "resolver_contenthashes",
    "resolver_texts",
    "resolver_aliases",
    "resolver_pubkeys",
    "resolver_abis",
    "resolver_names",
    "resolver_interfaces",
    "resolver_versions",
    "resolver_metadata",
    "resolver_approvals",
    "resolver_dns_records",
    "resolver_dns_zonehashes",
    "resolver_authorisations",
    "reverse_records",
};

/// Create the undo-log + cursor tables (idempotent). Called from Database.init.
pub fn ensureSchema(db: *Database) !void {
    if (db.isPostgres()) {
        // Same three tables, Postgres DDL: BIGSERIAL for the surrogate key (vs SQLite's
        // INTEGER PRIMARY KEY AUTOINCREMENT) and explicit BIGINT for block numbers.
        try db.exec(
            \\CREATE TABLE IF NOT EXISTS reorg_undo (
            \\  id BIGSERIAL PRIMARY KEY,
            \\  protocol TEXT NOT NULL,
            \\  block_number BIGINT NOT NULL,
            \\  table_name TEXT NOT NULL,
            \\  op TEXT NOT NULL,
            \\  old_row TEXT NOT NULL
            \\);
        );
        try db.exec("CREATE INDEX IF NOT EXISTS idx_reorg_undo_lookup ON reorg_undo(protocol, block_number)");
        try db.exec(
            \\CREATE TABLE IF NOT EXISTS reorg_cursor (
            \\  protocol TEXT PRIMARY KEY,
            \\  block_number BIGINT NOT NULL
            \\);
        );
        try db.exec(
            \\CREATE TABLE IF NOT EXISTS reorg_active (
            \\  id BIGINT PRIMARY KEY CHECK (id = 1),
            \\  protocol TEXT NOT NULL,
            \\  block_number BIGINT NOT NULL
            \\);
        );
        return;
    }
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS reorg_undo (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  protocol TEXT NOT NULL,
        \\  block_number INTEGER NOT NULL,
        \\  table_name TEXT NOT NULL,
        \\  op TEXT NOT NULL,
        \\  old_row TEXT NOT NULL
        \\);
    );
    try db.exec("CREATE INDEX IF NOT EXISTS idx_reorg_undo_lookup ON reorg_undo(protocol, block_number)");
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS reorg_cursor (
        \\  protocol TEXT PRIMARY KEY,
        \\  block_number INTEGER NOT NULL
        \\);
    );
    // Single-row "active processing context". Cross-protocol tables that can't carry
    // a `protocol` column (accounts) can't use the OLD.protocol cursor lookup, so the
    // indexer records which (protocol, block) is being processed right now here, and
    // the dedicated accounts triggers read it to tag their captures. Kept in lockstep
    // with reorg_cursor by setCursor/clearCursor.
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS reorg_active (
        \\  id INTEGER PRIMARY KEY CHECK (id = 1),
        \\  protocol TEXT NOT NULL,
        \\  block_number INTEGER NOT NULL
        \\);
    );
}

/// Read a table's column names via the backend's schema introspection. Caller
/// owns the returned slice and each string. Table names come from
/// PROTECTED_TABLES (trusted).
fn getColumns(db: *Database, allocator: std.mem.Allocator, table: []const u8) ![][]u8 {
    const info = try db.introspectColumns(allocator, table);
    defer backend.freeColumnInfo(allocator, info);

    var cols: std.ArrayList([]u8) = .{};
    errdefer {
        for (cols.items) |c| allocator.free(c);
        cols.deinit(allocator);
    }
    for (info) |col| {
        try cols.append(allocator, try allocator.dupe(u8, col.name));
    }
    return cols.toOwnedSlice(allocator);
}

fn freeColumns(allocator: std.mem.Allocator, cols: [][]u8) void {
    for (cols) |c| allocator.free(c);
    allocator.free(cols);
}

/// Build `json_object('c1', <alias>."c1", ...)` over every column. `alias` is OLD
/// (UPDATE/DELETE) or NEW (INSERT). Caller owns the returned slice.
fn rowJson(allocator: std.mem.Allocator, cols: [][]u8, alias: []const u8) ![]u8 {
    var jobj: std.ArrayList(u8) = .{};
    errdefer jobj.deinit(allocator);
    try jobj.appendSlice(allocator, "json_object(");
    for (cols, 0..) |c, i| {
        if (i > 0) try jobj.appendSlice(allocator, ", ");
        try jobj.writer(allocator).print("'{s}', {s}.\"{s}\"", .{ c, alias, c });
    }
    try jobj.appendSlice(allocator, ")");
    return jobj.toOwnedSlice(allocator);
}

/// Install AFTER UPDATE + AFTER DELETE triggers on every protected table. Generated
/// from the live schema (PRAGMA table_info) so new columns are captured automatically.
/// Idempotent (CREATE TRIGGER IF NOT EXISTS). Must run AFTER the tables exist and be
/// re-run if a protected table is dropped/recreated (e.g. replay rebuilds `names`).
pub fn installTriggers(db: *Database) !void {
    if (db.isPostgres()) {
        // Postgres can't gate triggers on a subquery WHEN, so the cursor/active-context
        // gate lives in two shared PL/pgSQL functions; the per-table FOR EACH ROW triggers
        // cover the same {U,D} (protected) / {I,U,D} (active) ops as the SQLite triggers.
        // Multi-statement DDL execs through the simple-query protocol in one call.
        const sql = try pgTriggerInstallSql(db.allocator);
        defer db.allocator.free(sql);
        try db.exec(sql);
        return;
    }
    const allocator = db.allocator;
    for (PROTECTED_TABLES) |table| {
        if (!try tableExists(db, table)) continue;
        const cols = try getColumns(db, allocator, table);
        defer freeColumns(allocator, cols);

        const jobj = try rowJson(allocator, cols, "OLD");
        defer allocator.free(jobj);

        try createTrigger(db, allocator, table, "u", "UPDATE", "U", jobj);
        try createTrigger(db, allocator, table, "d", "DELETE", "D", jobj);
    }

    // Tables with no `protocol` column can't use the OLD.protocol cursor lookup; capture
    // them via the single-row reorg_active context instead (INSERT/UPDATE/DELETE).
    for (REORG_ACTIVE_TABLES) |table| try installReorgActiveTriggers(db, table);
}

/// Derived tables that lack a `protocol` column and so are captured via reorg_active
/// rather than the generic OLD.protocol triggers. `accounts` is cross-protocol (its row
/// is shared by v1+v2); `v1_controllers` is V1-only; `unknown_labels` is an unresolved-
/// label queue (`name_id` FK to `names` `ON DELETE CASCADE`). Each has a single-column
/// PK (`id`/`address`). Without `unknown_labels` here, a post-N row whose `name_id` is
/// null or points at a pre-N name has no rollback delete path (no cascade, no created-
/// block delete) and persists as a stale row; the op-`I` reversal removes it.
pub const REORG_ACTIVE_TABLES = [_][]const u8{ "accounts", "v1_controllers", "unknown_labels" };

/// reorg_active-keyed triggers for a no-`protocol`-column table. UPDATE/DELETE capture
/// OLD; INSERT captures NEW (op 'I'). Capturing the INSERT lets a rollback retire a row
/// first created after N precisely (replayUndo's 'I' handler), rather than a lossy
/// column-predicate delete — which matters for cross-protocol `accounts` (don't drop the
/// other protocol's row) and for `v1_controllers` (a remove-then-readd straddling N).
fn installReorgActiveTriggers(db: *Database, table: []const u8) !void {
    const allocator = db.allocator;
    if (!try tableExists(db, table)) return;
    const cols = try getColumns(db, allocator, table);
    defer freeColumns(allocator, cols);

    const jobj_old = try rowJson(allocator, cols, "OLD");
    defer allocator.free(jobj_old);
    try createActiveTrigger(db, allocator, table, "u", "UPDATE", "U", jobj_old);
    try createActiveTrigger(db, allocator, table, "d", "DELETE", "D", jobj_old);

    const jobj_new = try rowJson(allocator, cols, "NEW");
    defer allocator.free(jobj_new);
    try createActiveTrigger(db, allocator, table, "i", "INSERT", "I", jobj_new);
}

fn createActiveTrigger(db: *Database, allocator: std.mem.Allocator, table: []const u8, suffix: []const u8, event: []const u8, op: []const u8, jobj: []const u8) !void {
    const sql = try std.fmt.allocPrint(allocator,
        \\CREATE TRIGGER IF NOT EXISTS "{s}_reorg_undo_{s}" AFTER {s} ON "{s}"
        \\WHEN EXISTS (SELECT 1 FROM reorg_active WHERE id = 1)
        \\BEGIN
        \\  INSERT INTO reorg_undo(protocol, block_number, table_name, op, old_row)
        \\  SELECT protocol, block_number, '{s}', '{s}', {s}
        \\  FROM reorg_active WHERE id = 1;
        \\END;
    , .{ table, suffix, event, table, table, op, jobj });
    defer allocator.free(sql);
    try db.exec(sql);
}

fn createTrigger(db: *Database, allocator: std.mem.Allocator, table: []const u8, suffix: []const u8, event: []const u8, op: []const u8, jobj: []const u8) !void {
    const sql = try std.fmt.allocPrint(allocator,
        \\CREATE TRIGGER IF NOT EXISTS "{s}_reorg_undo_{s}" AFTER {s} ON "{s}"
        \\WHEN (SELECT block_number FROM reorg_cursor WHERE protocol = OLD.protocol) IS NOT NULL
        \\BEGIN
        \\  INSERT INTO reorg_undo(protocol, block_number, table_name, op, old_row)
        \\  VALUES (OLD.protocol,
        \\          (SELECT block_number FROM reorg_cursor WHERE protocol = OLD.protocol),
        \\          '{s}', '{s}', {s});
        \\END;
    , .{ table, suffix, event, table, table, op, jobj });
    defer allocator.free(sql);
    try db.exec(sql);
}

fn tableExists(db: *Database, table: []const u8) !bool {
    var q = try Query.init(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?");
    defer q.deinit();
    try q.bindText(table);
    return try q.step();
}

// ── Postgres trigger installation (generated; executed by the PG driver in Phase 4) ──
// Mirror of the SQLite triggers above, expressed as two generic PL/pgSQL functions plus
// per-table FOR EACH ROW triggers. Postgres can't gate a trigger's WHEN on a subquery,
// so the cursor/active-context gate lives in the function body. The row snapshot is
// `to_jsonb(OLD/NEW)::text` (whole row, vs SQLite's per-column json_object — both yield a
// column-keyed JSON object that replayUndo extracts the same way per backend). The op
// letter is derived from the firing event (`LEFT(TG_OP, 1)` ⇒ I/U/D), so it can never
// disagree with the trigger's event. Trigger names match the SQLite
// `"<t>_reorg_undo_<i|u|d>"` scheme so the two backends are interchangeable. Protected
// tables capture {U,D}; reorg_active tables capture {I,U,D}. See the settled design in
// docs/postgresql-migration-plan.md ("Postgres trigger design").

const PG_CAPTURE_PROTOCOL_FN =
    \\CREATE OR REPLACE FUNCTION reorg_capture_protocol() RETURNS trigger AS $$
    \\DECLARE
    \\  cur_block bigint;
    \\BEGIN
    \\  SELECT block_number INTO cur_block FROM reorg_cursor WHERE protocol = OLD.protocol;
    \\  IF cur_block IS NOT NULL THEN
    \\    INSERT INTO reorg_undo (protocol, block_number, table_name, op, old_row)
    \\    VALUES (OLD.protocol, cur_block, TG_TABLE_NAME, LEFT(TG_OP, 1), to_jsonb(OLD)::text);
    \\  END IF;
    \\  RETURN NULL;
    \\END;
    \\$$ LANGUAGE plpgsql;
    \\
;

const PG_CAPTURE_ACTIVE_FN =
    \\CREATE OR REPLACE FUNCTION reorg_capture_active() RETURNS trigger AS $$
    \\DECLARE
    \\  act_protocol text;
    \\  act_block bigint;
    \\BEGIN
    \\  SELECT protocol, block_number INTO act_protocol, act_block FROM reorg_active WHERE id = 1;
    \\  IF FOUND THEN
    \\    INSERT INTO reorg_undo (protocol, block_number, table_name, op, old_row)
    \\    VALUES (act_protocol, act_block, TG_TABLE_NAME, LEFT(TG_OP, 1),
    \\            to_jsonb(CASE WHEN TG_OP = 'INSERT' THEN NEW ELSE OLD END)::text);
    \\  END IF;
    \\  RETURN NULL;
    \\END;
    \\$$ LANGUAGE plpgsql;
    \\
;

fn appendPgTrigger(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), table: []const u8, suffix: []const u8, event: []const u8, func: []const u8) !void {
    try buf.writer(allocator).print(
        \\DROP TRIGGER IF EXISTS "{s}_reorg_undo_{s}" ON "{s}";
        \\CREATE TRIGGER "{s}_reorg_undo_{s}" AFTER {s} ON "{s}" FOR EACH ROW EXECUTE FUNCTION {s}();
        \\
    , .{ table, suffix, table, table, suffix, event, table, func });
}

/// Generate the full Postgres reorg-trigger DDL — the two PL/pgSQL capture functions
/// plus per-table FOR EACH ROW triggers built from PROTECTED_TABLES / REORG_ACTIVE_TABLES.
/// Pure string generation (no connection); the Postgres driver executes it at schema-install
/// time in Phase 4. Idempotent (CREATE OR REPLACE FUNCTION + DROP/CREATE TRIGGER). Caller
/// owns the returned SQL.
pub fn pgTriggerInstallSql(allocator: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, PG_CAPTURE_PROTOCOL_FN);
    try buf.appendSlice(allocator, PG_CAPTURE_ACTIVE_FN);
    for (PROTECTED_TABLES) |table| {
        try appendPgTrigger(allocator, &buf, table, "u", "UPDATE", "reorg_capture_protocol");
        try appendPgTrigger(allocator, &buf, table, "d", "DELETE", "reorg_capture_protocol");
    }
    for (REORG_ACTIVE_TABLES) |table| {
        try appendPgTrigger(allocator, &buf, table, "i", "INSERT", "reorg_capture_active");
        try appendPgTrigger(allocator, &buf, table, "u", "UPDATE", "reorg_capture_active");
        try appendPgTrigger(allocator, &buf, table, "d", "DELETE", "reorg_capture_active");
    }
    return buf.toOwnedSlice(allocator);
}

/// Set the block currently being processed for `protocol`. Enables undo capture
/// (both the per-protocol cursor for generic tables and the single-row active
/// context for cross-protocol tables like accounts).
pub fn setCursor(db: *Database, protocol: models.Protocol, block_number: u64) !void {
    const dialect = db.dialect();
    {
        const sql = try dialect.upsert(db.allocator, "reorg_cursor", &.{ "protocol", "block_number" }, &.{}, &.{"protocol"}, .replace);
        defer db.allocator.free(sql);
        var q = try Query.initCached(db, sql);
        defer q.deinit();
        try q.bindTextStatic(protocol.toString());
        try q.bindInt64(@intCast(block_number));
        try q.exec();
    }
    const sql = try dialect.upsert(db.allocator, "reorg_active", &.{ "id", "protocol", "block_number" }, &.{ "1", "?", "?" }, &.{"id"}, .replace);
    defer db.allocator.free(sql);
    var qa = try Query.initCached(db, sql);
    defer qa.deinit();
    try qa.bindTextStatic(protocol.toString());
    try qa.bindInt64(@intCast(block_number));
    try qa.exec();
}

/// Clear the cursor for `protocol` — disables undo capture (used during backfill
/// and inside rollback so neither self-captures). Also clears the single-row active
/// context so the accounts triggers stop capturing (sequential v1/v2 processing
/// means no other protocol is live-capturing concurrently).
pub fn clearCursor(db: *Database, protocol: models.Protocol) !void {
    {
        var q = try Query.initCached(db, "DELETE FROM reorg_cursor WHERE protocol = ?");
        defer q.deinit();
        try q.bindTextStatic(protocol.toString());
        try q.exec();
    }
    try db.exec("DELETE FROM reorg_active");
}

/// Reverse-apply every captured mutation with block_number > `block_number` for
/// `protocol`, newest-first (id DESC), restoring each OLD row via INSERT OR REPLACE.
/// Then delete those undo rows. MUST be called with the cursor cleared (no capture).
pub fn replayUndo(db: *Database, protocol: models.Protocol, block_number: u64) !void {
    const allocator = db.allocator;

    // Per-table restore-SQL cache: "INSERT OR REPLACE INTO t(cols) VALUES(json_extract(?1,'$.c'),...)"
    var restore_sql = std.StringHashMap([]u8).init(allocator);
    defer {
        var it = restore_sql.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        restore_sql.deinit();
    }

    const Entry = struct { table: []u8, op: []u8, old_row: []u8 };
    var entries: std.ArrayList(Entry) = .{};
    defer {
        for (entries.items) |e| {
            allocator.free(e.table);
            allocator.free(e.op);
            allocator.free(e.old_row);
        }
        entries.deinit(allocator);
    }

    // Collect all rows first, then finalize the read cursor before running the
    // restore + delete writes (newest-first, so INSERT OR REPLACE walks each row
    // back to its state as of `block_number`).
    {
        var sel = try Query.init(db, "SELECT id, table_name, op, old_row FROM reorg_undo WHERE protocol = ? AND block_number > ? ORDER BY id DESC");
        defer sel.deinit();
        try sel.bindTextStatic(protocol.toString());
        try sel.bindInt64(@intCast(block_number));
        while (try sel.step()) {
            const t = sel.getTextSlice(1) orelse continue;
            const o = sel.getTextSlice(2) orelse continue;
            const r = sel.getTextSlice(3) orelse continue;
            const td = try allocator.dupe(u8, t);
            errdefer allocator.free(td);
            const od = try allocator.dupe(u8, o);
            errdefer allocator.free(od);
            const rd = try allocator.dupe(u8, r);
            errdefer allocator.free(rd);
            try entries.append(allocator, .{ .table = td, .op = od, .old_row = rd });
        }
    }

    for (entries.items) |e| {
        if (std.mem.eql(u8, e.op, "I")) {
            // A row first-created after N (op 'I', from a reorg_active table's INSERT
            // trigger). Reverse it by retiring only this rollback's contribution.
            const dialect = db.dialect();
            if (std.mem.eql(u8, e.table, "accounts")) {
                // accounts is cross-protocol (shared address key): clear only THIS
                // protocol's seen flag, then drop the row only if the other protocol
                // never saw it — so an independent per-protocol rollback never deletes an
                // account the still-synced protocol established.
                const this_seen = if (protocol == .v1) "seen_v1" else "seen_v2";
                const addr = try dialect.jsonExtract(allocator, "?1", "address", null); // text key, no cast
                defer allocator.free(addr);
                const upd = try std.fmt.allocPrint(allocator, "UPDATE \"{s}\" SET {s} = 0 WHERE address = {s}", .{ e.table, this_seen, addr });
                defer allocator.free(upd);
                var uq = try Query.init(db, upd);
                defer uq.deinit();
                try uq.bindText(e.old_row);
                try uq.exec();

                const del = try std.fmt.allocPrint(allocator, "DELETE FROM \"{s}\" WHERE address = {s} AND seen_v1 = 0 AND seen_v2 = 0", .{ e.table, addr });
                defer allocator.free(del);
                var dq = try Query.init(db, del);
                defer dq.deinit();
                try dq.bindText(e.old_row);
                try dq.exec();
            } else {
                // Single-protocol reorg_active table (v1_controllers, unknown_labels):
                // the row did not exist at N, so delete it by primary key. The PK's
                // declared type is the Postgres `->>` cast — numeric PKs like
                // unknown_labels.id need it; SQLite ignores the cast.
                const info = try db.introspectColumns(allocator, e.table);
                defer backend.freeColumnInfo(allocator, info);
                const pk = for (info) |col| {
                    if (col.pk_pos > 0) break col;
                } else return error.NoPrimaryKey;
                const cast: ?[]const u8 = if (pk.sql_type.len == 0) null else pk.sql_type;
                const key_expr = try dialect.jsonExtract(allocator, "?1", pk.name, cast);
                defer allocator.free(key_expr);
                const del = try std.fmt.allocPrint(allocator, "DELETE FROM \"{s}\" WHERE \"{s}\" = {s}", .{ e.table, pk.name, key_expr });
                defer allocator.free(del);
                var dq = try Query.init(db, del);
                defer dq.deinit();
                try dq.bindText(e.old_row);
                try dq.exec();
            }
            continue;
        }
        const sql = try getRestoreSql(db, allocator, &restore_sql, e.table);
        var rq = try Query.init(db, sql);
        defer rq.deinit();
        try rq.bindText(e.old_row); // ?1
        try rq.exec();
    }

    // Drop the replayed undo entries.
    var del = try Query.init(db, "DELETE FROM reorg_undo WHERE protocol = ? AND block_number > ?");
    defer del.deinit();
    try del.bindTextStatic(protocol.toString());
    try del.bindInt64(@intCast(block_number));
    try del.exec();
}

fn getRestoreSql(db: *Database, allocator: std.mem.Allocator, cache: *std.StringHashMap([]u8), table: []const u8) ![]u8 {
    if (cache.get(table)) |sql| return sql;

    // Read column names, per-column value expressions, and the PK conflict target
    // from the live schema, so new columns are restored automatically. Each value
    // expr extracts the column from the captured JSON snapshot (`?1`); on Postgres
    // the column's declared type becomes the `->>` cast (SQLite ignores it). The
    // restore overwrites the existing row by PRIMARY KEY (ON CONFLICT target on PG;
    // implicit for SQLite's INSERT OR REPLACE).
    const info = try db.introspectColumns(allocator, table);
    defer backend.freeColumnInfo(allocator, info);

    const col_names = try allocator.alloc([]const u8, info.len);
    defer allocator.free(col_names);
    const value_exprs = try allocator.alloc([]const u8, info.len);
    var built: usize = 0;
    defer {
        for (value_exprs[0..built]) |e| allocator.free(e);
        allocator.free(value_exprs);
    }
    var pk_cols: std.ArrayList([]const u8) = .{};
    defer pk_cols.deinit(allocator);

    const dialect = db.dialect();
    for (info, 0..) |col, i| {
        col_names[i] = col.name;
        const cast: ?[]const u8 = if (col.sql_type.len == 0) null else col.sql_type;
        value_exprs[i] = try dialect.jsonExtract(allocator, "?1", col.name, cast);
        built += 1;
        if (col.pk_pos > 0) try pk_cols.append(allocator, col.name);
    }

    const sql = try dialect.upsert(allocator, table, col_names, value_exprs, pk_cols.items, .replace);
    errdefer allocator.free(sql);
    const key = try allocator.dupe(u8, table);
    errdefer allocator.free(key);
    try cache.put(key, sql);
    return sql;
}

/// Prune undo entries older than `keep_from_block` (retention housekeeping).
pub fn pruneBelow(db: *Database, protocol: models.Protocol, keep_from_block: u64) !void {
    var q = try Query.initCached(db, "DELETE FROM reorg_undo WHERE protocol = ? AND block_number < ?");
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindInt64(@intCast(keep_from_block));
    try q.exec();
}
