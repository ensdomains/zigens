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

/// Read a table's column names via PRAGMA table_info. Caller owns the returned
/// slice and each string. Table names come from PROTECTED_TABLES (trusted), so
/// string interpolation here is safe.
fn getColumns(db: *Database, allocator: std.mem.Allocator, table: []const u8) ![][]u8 {
    const sql = try std.fmt.allocPrint(allocator, "PRAGMA table_info(\"{s}\")", .{table});
    defer allocator.free(sql);

    var q = try Query.init(db, sql);
    defer q.deinit();

    var cols: std.ArrayList([]u8) = .{};
    errdefer {
        for (cols.items) |c| allocator.free(c);
        cols.deinit(allocator);
    }
    while (try q.step()) {
        const name = q.getTextSlice(1) orelse continue; // col 1 = name
        try cols.append(allocator, try allocator.dupe(u8, name));
    }
    return cols.toOwnedSlice(allocator);
}

fn freeColumns(allocator: std.mem.Allocator, cols: [][]u8) void {
    for (cols) |c| allocator.free(c);
    allocator.free(cols);
}

/// Name of the (single-column) primary key of `table`, from PRAGMA table_info. Used to
/// reverse an op-'I' capture by deleting the after-N row by its key. Caller owns it.
fn pkColumn(db: *Database, allocator: std.mem.Allocator, table: []const u8) ![]u8 {
    const sql = try std.fmt.allocPrint(allocator, "PRAGMA table_info(\"{s}\")", .{table});
    defer allocator.free(sql);
    var q = try Query.init(db, sql);
    defer q.deinit();
    while (try q.step()) {
        if (q.getInt64(5) > 0) { // col 5 = pk position (0 = not part of pk)
            const name = q.getTextSlice(1) orelse continue;
            return allocator.dupe(u8, name);
        }
    }
    return error.NoPrimaryKey;
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
/// is shared by v1+v2); `v1_controllers` is V1-only. Both have a single-column PK.
pub const REORG_ACTIVE_TABLES = [_][]const u8{ "accounts", "v1_controllers" };

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

/// Set the block currently being processed for `protocol`. Enables undo capture
/// (both the per-protocol cursor for generic tables and the single-row active
/// context for cross-protocol tables like accounts).
pub fn setCursor(db: *Database, protocol: models.Protocol, block_number: u64) !void {
    {
        var q = try Query.initCached(db, "INSERT OR REPLACE INTO reorg_cursor(protocol, block_number) VALUES (?, ?)");
        defer q.deinit();
        try q.bindTextStatic(protocol.toString());
        try q.bindInt64(@intCast(block_number));
        try q.exec();
    }
    var qa = try Query.initCached(db, "INSERT OR REPLACE INTO reorg_active(id, protocol, block_number) VALUES (1, ?, ?)");
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
            if (std.mem.eql(u8, e.table, "accounts")) {
                // accounts is cross-protocol (shared address key): clear only THIS
                // protocol's seen flag, then drop the row only if the other protocol
                // never saw it — so an independent per-protocol rollback never deletes an
                // account the still-synced protocol established.
                const this_seen = if (protocol == .v1) "seen_v1" else "seen_v2";
                const upd = try std.fmt.allocPrint(allocator, "UPDATE \"{s}\" SET {s} = 0 WHERE address = json_extract(?1, '$.address')", .{ e.table, this_seen });
                defer allocator.free(upd);
                var uq = try Query.init(db, upd);
                defer uq.deinit();
                try uq.bindText(e.old_row);
                try uq.exec();

                const del = try std.fmt.allocPrint(allocator, "DELETE FROM \"{s}\" WHERE address = json_extract(?1, '$.address') AND seen_v1 = 0 AND seen_v2 = 0", .{e.table});
                defer allocator.free(del);
                var dq = try Query.init(db, del);
                defer dq.deinit();
                try dq.bindText(e.old_row);
                try dq.exec();
            } else {
                // Single-protocol reorg_active table (v1_controllers): the row did not
                // exist at N, so delete it by primary key.
                const pk = try pkColumn(db, allocator, e.table);
                defer allocator.free(pk);
                const del = try std.fmt.allocPrint(allocator, "DELETE FROM \"{s}\" WHERE \"{s}\" = json_extract(?1, '$.{s}')", .{ e.table, pk, pk });
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

    const cols = try getColumns(db, allocator, table);
    defer freeColumns(allocator, cols);

    var sql: std.ArrayList(u8) = .{};
    errdefer sql.deinit(allocator);
    try sql.writer(allocator).print("INSERT OR REPLACE INTO \"{s}\" (", .{table});
    for (cols, 0..) |c, i| {
        if (i > 0) try sql.appendSlice(allocator, ", ");
        try sql.writer(allocator).print("\"{s}\"", .{c});
    }
    try sql.appendSlice(allocator, ") VALUES (");
    for (cols, 0..) |c, i| {
        if (i > 0) try sql.appendSlice(allocator, ", ");
        try sql.writer(allocator).print("json_extract(?1, '$.{s}')", .{c});
    }
    try sql.appendSlice(allocator, ")");

    const owned = try sql.toOwnedSlice(allocator);
    errdefer allocator.free(owned);
    const key = try allocator.dupe(u8, table);
    errdefer allocator.free(key);
    try cache.put(key, owned);
    return owned;
}

/// Prune undo entries older than `keep_from_block` (retention housekeeping).
pub fn pruneBelow(db: *Database, protocol: models.Protocol, keep_from_block: u64) !void {
    var q = try Query.initCached(db, "DELETE FROM reorg_undo WHERE protocol = ? AND block_number < ?");
    defer q.deinit();
    try q.bindTextStatic(protocol.toString());
    try q.bindInt64(@intCast(keep_from_block));
    try q.exec();
}
