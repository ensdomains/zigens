//! Flush-time multi-row writers for the entity tables the V2 bulk path
//! buffers (indexer/write_buffer.zig): name owner/resolver updates,
//! registrations and their registrar economics, Resolver entity bindings and
//! account observations. Each replaces one round trip per event with one
//! statement per chunk — on a remote Postgres the per-row round trips were
//! ~13 of the ~15 statements a single .eth registration cost.
//!
//! INVARIANT (enforced by the handler routing sites): these run only while
//! the reorg cursor is DISARMED, exactly like the eac_roles flush — every
//! table here is capture-protected and a flush-time capture would tag undo
//! rows with the batch's last block. Armed (near-tip) batches keep the direct
//! per-event writers, which capture correctly.
//!
//! Every statement here is plain SQL that both backends run unchanged: the
//! inserts go through the dialect's multi-row upsert builder, the updates
//! through a CTE-of-VALUES shape (see batchedUpdateSql).

const std = @import("std");
const zsys = @import("../utils/system.zig");
const db_module = @import("database.zig");
const Database = db_module.Database;
const Query = db_module.Query;
const models = @import("../types/models.zig");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;

/// Rows per statement. Every text bind is static (scratch-arena or
/// buffer-owned), so the driver's copied-bind cap does not apply.
const BATCH_ROWS: usize = 200;

/// One portable statement that updates `set_cols` on every `table` row whose
/// `key_cols` match a row of the bound VALUES list:
///
///   WITH v(k…, c…) AS (VALUES (?, …), …)
///   UPDATE table SET c = (SELECT c FROM v WHERE v.k = table.k …), …[, extra]
///   WHERE EXISTS (SELECT 1 FROM v WHERE v.k = table.k …)
///
/// Plain SQL on both backends (CTEs and correlated subqueries are older than
/// every SQLite and Postgres we run), so there is no per-dialect branch.
/// Bind order: the VALUES rows (key columns then set columns, row-major),
/// then the binds of `extra_set`. Every VALUES cell is CAST AS TEXT so
/// Postgres never has to infer a parameter type from the CTE.
fn batchedUpdateSql(allocator: std.mem.Allocator, table: []const u8, key_cols: []const []const u8, set_cols: []const []const u8, extra_set: ?[]const u8, rows: usize) ![]u8 {
    var sql: std.ArrayList(u8) = .empty;
    errdefer sql.deinit(allocator);
    try sql.appendSlice(allocator, "WITH v(");
    for (key_cols, 0..) |c, i| {
        if (i > 0) try sql.appendSlice(allocator, ", ");
        try sql.appendSlice(allocator, c);
    }
    for (set_cols) |c| {
        try sql.appendSlice(allocator, ", ");
        try sql.appendSlice(allocator, c);
    }
    try sql.appendSlice(allocator, ") AS (VALUES ");
    const cells = key_cols.len + set_cols.len;
    for (0..rows) |r| {
        try sql.appendSlice(allocator, if (r == 0) "(" else ", (");
        for (0..cells) |c| {
            try sql.appendSlice(allocator, if (c == 0) "CAST(? AS TEXT)" else ", CAST(? AS TEXT)");
        }
        try sql.append(allocator, ')');
    }
    try sql.appendSlice(allocator, ") UPDATE ");
    try sql.appendSlice(allocator, table);
    try sql.appendSlice(allocator, " SET ");
    for (set_cols, 0..) |c, i| {
        if (i > 0) try sql.appendSlice(allocator, ", ");
        try sql.appendSlice(allocator, c);
        try sql.appendSlice(allocator, " = (SELECT ");
        try sql.appendSlice(allocator, c);
        try sql.appendSlice(allocator, " FROM v WHERE ");
        try appendKeyMatch(&sql, allocator, table, key_cols);
        try sql.append(allocator, ')');
    }
    if (extra_set) |extra| {
        try sql.appendSlice(allocator, ", ");
        try sql.appendSlice(allocator, extra);
    }
    try sql.appendSlice(allocator, " WHERE EXISTS (SELECT 1 FROM v WHERE ");
    try appendKeyMatch(&sql, allocator, table, key_cols);
    try sql.append(allocator, ')');
    return sql.toOwnedSlice(allocator);
}

fn appendKeyMatch(sql: *std.ArrayList(u8), allocator: std.mem.Allocator, table: []const u8, key_cols: []const []const u8) !void {
    for (key_cols, 0..) |k, i| {
        if (i > 0) try sql.appendSlice(allocator, " AND ");
        try sql.appendSlice(allocator, "v.");
        try sql.appendSlice(allocator, k);
        try sql.appendSlice(allocator, " = ");
        try sql.appendSlice(allocator, table);
        try sql.append(allocator, '.');
        try sql.appendSlice(allocator, k);
    }
}

pub const NameAddressUpdate = struct {
    namehash: Hash,
    value: Address,
};

pub const NameColumn = enum {
    owner,
    resolver,

    fn name(self: NameColumn) []const u8 {
        return switch (self) {
            .owner => "owner",
            .resolver => "resolver",
        };
    }
};

/// `UPDATE names SET <column> = ?, updated_at = ? WHERE namehash = ?` for many
/// rows in one statement per chunk. Callers pass one entry per namehash (the
/// buffer is keyed by it).
pub fn updateNameAddressColumnBatch(db: *Database, column: NameColumn, rows: []const NameAddressUpdate) !void {
    if (rows.len == 0) return;
    const now = zsys.timestamp();
    var start: usize = 0;
    while (start < rows.len) {
        const n = @min(BATCH_ROWS, rows.len - start);
        const chunk = rows[start .. start + n];
        const sql = try batchedUpdateSql(db.allocator, "names", &.{"namehash"}, &.{column.name()}, "updated_at = ?", n);
        defer db.allocator.free(sql);
        var arena = std.heap.ArenaAllocator.init(db.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        var q = try Query.initCached(db, sql);
        defer q.deinit();
        for (chunk) |r| {
            try q.bindTextStatic(r.namehash.toHexBuf(try scratch.create([66]u8)));
            try q.bindTextStatic(r.value.toHexBuf(try scratch.create([42]u8)));
        }
        try q.bindInt64(now);
        try q.exec();
        start += n;
    }
    for (rows) |r| db.noteNameWriteByNamehash(r.namehash);
}

pub const RegistrationRow = struct {
    protocol: models.Protocol,
    namehash: Hash,
    label: []const u8,
    parent_name: []const u8,
    registrant: Address,
    registered_at: i64,
    expiry: ?u64,
    block_number: u64,
    tx_hash: Hash,
    log_index: u32,
    event_type: models.EventType,
};

/// Conflict-ignoring multi-row insert; rows must be unique on
/// (protocol, transaction_hash, log_index) — the table's conflict key.
pub fn insertRegistrationsBatch(db: *Database, rows: []const RegistrationRow) !void {
    if (rows.len == 0) return;
    const cols = [_][]const u8{ "protocol", "namehash", "label", "parent_name", "registrant", "registered_at", "expiry", "block_number", "transaction_hash", "log_index", "event_type" };
    var start: usize = 0;
    while (start < rows.len) {
        const n = @min(BATCH_ROWS, rows.len - start);
        const chunk = rows[start .. start + n];
        const sql = try db.upsertMultiSql(db.allocator, "registrations", &cols, n, .ignore);
        defer db.allocator.free(sql);
        var arena = std.heap.ArenaAllocator.init(db.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        var q = try Query.initCached(db, sql);
        defer q.deinit();
        for (chunk) |r| {
            try q.bindTextStatic(r.protocol.toString());
            try q.bindTextStatic(r.namehash.toHexBuf(try scratch.create([66]u8)));
            try q.bindTextStatic(r.label);
            try q.bindTextStatic(r.parent_name);
            try q.bindTextStatic(r.registrant.toHexBuf(try scratch.create([42]u8)));
            try q.bindInt64(r.registered_at);
            if (r.expiry) |e| {
                const clamped: i64 = if (e > std.math.maxInt(i64)) 0 else @intCast(e);
                if (e > std.math.maxInt(i64)) {
                    std.log.warn("insertRegistration: expiry {d} exceeds i64 max; storing 0 (matches names.zig convention)", .{e});
                }
                try q.bindInt64(clamped);
            } else {
                try q.bindNull();
            }
            try q.bindInt64(@intCast(r.block_number));
            try q.bindTextStatic(r.tx_hash.toHexBuf(try scratch.create([66]u8)));
            try q.bindInt(@intCast(r.log_index));
            try q.bindTextStatic(r.event_type.toString());
        }
        try q.exec();
        start += n;
    }
}

pub const EconomicsRow = struct {
    protocol: models.Protocol,
    namehash: Hash,
    label_name: []const u8,
    base_cost: u256,
    premium: u256,
    referrer: ?Hash,
};

/// The registrar-side enrichment of `registrations` rows, keyed by
/// (protocol, namehash) exactly like the per-event UPDATE — every row of that
/// name (including earlier registrations of an expired name) takes the values,
/// which is what the direct path has always done.
pub fn updateRegistrationEconomicsBatch(db: *Database, rows: []const EconomicsRow) !void {
    if (rows.len == 0) return;
    var start: usize = 0;
    while (start < rows.len) {
        const n = @min(BATCH_ROWS, rows.len - start);
        const chunk = rows[start .. start + n];
        const sql = try batchedUpdateSql(db.allocator, "registrations", &.{ "protocol", "namehash" }, &.{ "base_cost", "premium", "label_name", "referrer" }, null, n);
        defer db.allocator.free(sql);
        var arena = std.heap.ArenaAllocator.init(db.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        var q = try Query.initCached(db, sql);
        defer q.deinit();
        for (chunk) |r| {
            try q.bindTextStatic(r.protocol.toString());
            try q.bindTextStatic(r.namehash.toHexBuf(try scratch.create([66]u8)));
            try q.bindTextStatic(try std.fmt.allocPrint(scratch, "{d}", .{r.base_cost}));
            try q.bindTextStatic(try std.fmt.allocPrint(scratch, "{d}", .{r.premium}));
            try q.bindTextStatic(r.label_name);
            if (r.referrer) |ref| try q.bindTextStatic(ref.toHexBuf(try scratch.create([66]u8))) else try q.bindNull();
        }
        try q.exec();
        start += n;
    }
}

pub const ResolverEntityRow = struct {
    protocol: models.Protocol,
    address: []const u8,
    name: []const u8,
    namehash: []const u8,
    block_number: u64,
    timestamp: i64,
};

/// Conflict-ignoring multi-row insert on (protocol, namehash, address); the
/// buffer keeps the first sighting per key, matching the per-event insert.
pub fn upsertResolverEntitiesBatch(db: *Database, rows: []const ResolverEntityRow) !void {
    if (rows.len == 0) return;
    const cols = [_][]const u8{ "protocol", "address", "name", "namehash", "set_block", "set_at" };
    var start: usize = 0;
    while (start < rows.len) {
        const n = @min(BATCH_ROWS, rows.len - start);
        const chunk = rows[start .. start + n];
        const sql = try db.upsertMultiSql(db.allocator, "resolvers", &cols, n, .ignore);
        defer db.allocator.free(sql);
        var q = try Query.initCached(db, sql);
        defer q.deinit();
        for (chunk) |r| {
            try q.bindTextStatic(r.protocol.toString());
            try q.bindTextStatic(r.address);
            try q.bindTextStatic(r.name);
            try q.bindTextStatic(r.namehash);
            try q.bindInt64(@intCast(r.block_number));
            try q.bindInt64(r.timestamp);
        }
        try q.exec();
        start += n;
    }
}

pub const AccountRow = struct {
    address: []const u8,
    seen_v1: bool,
    seen_v2: bool,
    first_seen_block: u64,
    first_seen_timestamp: i64,
};

/// Same merge as accounts.upsertAccount (seen flags OR, first-seen MIN), many
/// rows per statement; rows must be unique on address.
pub fn upsertAccountsBatch(db: *Database, rows: []const AccountRow) !void {
    if (rows.len == 0) return;
    const d = db.dialect();
    var start: usize = 0;
    while (start < rows.len) {
        const n = @min(BATCH_ROWS, rows.len - start);
        const chunk = rows[start .. start + n];
        var sql: std.ArrayList(u8) = .empty;
        defer sql.deinit(db.allocator);
        try sql.appendSlice(db.allocator, "INSERT INTO accounts (address, seen_v1, seen_v2, first_seen_block, first_seen_timestamp) VALUES ");
        for (0..n) |i| {
            try sql.appendSlice(db.allocator, if (i == 0) "(?, ?, ?, ?, ?)" else ", (?, ?, ?, ?, ?)");
        }
        const tail = try std.fmt.allocPrint(db.allocator,
            \\ ON CONFLICT(address) DO UPDATE SET
            \\  seen_v1 = {s}(accounts.seen_v1, excluded.seen_v1),
            \\  seen_v2 = {s}(accounts.seen_v2, excluded.seen_v2),
            \\  first_seen_block = {s}(accounts.first_seen_block, excluded.first_seen_block),
            \\  first_seen_timestamp = {s}(accounts.first_seen_timestamp, excluded.first_seen_timestamp)
        , .{ d.scalar_max, d.scalar_max, d.scalar_min, d.scalar_min });
        defer db.allocator.free(tail);
        try sql.appendSlice(db.allocator, tail);
        var q = try Query.initCached(db, sql.items);
        defer q.deinit();
        for (chunk) |r| {
            try q.bindTextStatic(r.address);
            try q.bindInt64(if (r.seen_v1) 1 else 0);
            try q.bindInt64(if (r.seen_v2) 1 else 0);
            try q.bindInt64(@intCast(r.first_seen_block));
            try q.bindInt64(r.first_seen_timestamp);
        }
        try q.exec();
        start += n;
    }
}
