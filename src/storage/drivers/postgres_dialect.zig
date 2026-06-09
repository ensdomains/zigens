//! PostgreSQL SQL-dialect builders + the `?`→`$N` placeholder lexer.
//!
//! This module is intentionally free of any `pg.zig` / libpq dependency: it is
//! pure string transformation, so it builds and unit-tests with no Postgres
//! present. The `drivers/postgres.zig` connection driver (Phase 4, pg.zig) wires
//! `pg_dialect` into its `Backend` and calls `renumberPlaceholders` at prepare
//! time. Storage code keeps writing `?` placeholders (and SQLite-style `?N`); the
//! driver renumbers them to Postgres `$N` here.
const std = @import("std");
const backend = @import("../backend.zig");

fn appendQuotedIdent(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), ident: []const u8) !void {
    try buf.append(allocator, '"');
    try buf.appendSlice(allocator, ident);
    try buf.append(allocator, '"');
}

fn isConflictCol(conflict_cols: []const []const u8, col: []const u8) bool {
    for (conflict_cols) |c| {
        if (std.mem.eql(u8, c, col)) return true;
    }
    return false;
}

/// `INSERT INTO "t" (cols) VALUES (…) ON CONFLICT … DO NOTHING/UPDATE`. Placeholders
/// stay `?` (the driver renumbers to `$N`). `value_exprs` empty ⇒ one `?` per column,
/// else the given per-column expression. `.ignore` ⇒ `ON CONFLICT DO NOTHING`; `.replace`
/// ⇒ `ON CONFLICT (conflict_cols) DO UPDATE SET <non-key col> = EXCLUDED.<col>` (or
/// `DO NOTHING` if every column is part of the conflict key).
fn dialectUpsert(allocator: std.mem.Allocator, table: []const u8, cols: []const []const u8, value_exprs: []const []const u8, conflict_cols: []const []const u8, action: backend.ConflictAction) anyerror![]u8 {
    std.debug.assert(value_exprs.len == 0 or value_exprs.len == cols.len);
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "INSERT INTO ");
    try appendQuotedIdent(allocator, &buf, table);
    try buf.appendSlice(allocator, " (");
    for (cols, 0..) |col, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try appendQuotedIdent(allocator, &buf, col);
    }
    try buf.appendSlice(allocator, ") VALUES (");
    for (cols, 0..) |_, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, if (value_exprs.len == 0) "?" else value_exprs[i]);
    }
    try buf.append(allocator, ')');
    try appendOnConflict(allocator, &buf, cols, conflict_cols, action);
    return buf.toOwnedSlice(allocator);
}

/// `INSERT INTO "t" (cols) <select_body> ON CONFLICT … DO NOTHING/UPDATE`.
fn dialectInsertSelect(allocator: std.mem.Allocator, table: []const u8, cols: []const []const u8, select_body: []const u8, conflict_cols: []const []const u8, action: backend.ConflictAction) anyerror![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "INSERT INTO ");
    try appendQuotedIdent(allocator, &buf, table);
    try buf.appendSlice(allocator, " (");
    for (cols, 0..) |col, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try appendQuotedIdent(allocator, &buf, col);
    }
    try buf.appendSlice(allocator, ") ");
    try buf.appendSlice(allocator, select_body);
    try appendOnConflict(allocator, &buf, cols, conflict_cols, action);
    return buf.toOwnedSlice(allocator);
}

fn appendOnConflict(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), cols: []const []const u8, conflict_cols: []const []const u8, action: backend.ConflictAction) !void {
    switch (action) {
        .ignore => try buf.appendSlice(allocator, " ON CONFLICT DO NOTHING"),
        .replace => {
            try buf.appendSlice(allocator, " ON CONFLICT (");
            for (conflict_cols, 0..) |c, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try appendQuotedIdent(allocator, buf, c);
            }
            try buf.appendSlice(allocator, ") DO ");
            // SET every non-conflict column to its EXCLUDED (proposed) value.
            var first = true;
            for (cols) |col| {
                if (isConflictCol(conflict_cols, col)) continue;
                if (first) try buf.appendSlice(allocator, "UPDATE SET ");
                if (!first) try buf.appendSlice(allocator, ", ");
                first = false;
                try appendQuotedIdent(allocator, buf, col);
                try buf.appendSlice(allocator, " = EXCLUDED.");
                try appendQuotedIdent(allocator, buf, col);
            }
            // Every column is part of the conflict key ⇒ nothing to update.
            if (first) try buf.appendSlice(allocator, "NOTHING");
        },
    }
}

fn dialectReturning(allocator: std.mem.Allocator, col: []const u8) anyerror![]u8 {
    return std.fmt.allocPrint(allocator, " RETURNING {s}", .{col});
}

/// `jsonb_build_object('c', alias."c", …)` — the Postgres counterpart of SQLite's
/// per-column `json_object`.
fn dialectJsonObject(allocator: std.mem.Allocator, cols: []const []const u8, alias: []const u8) anyerror![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "jsonb_build_object(");
    for (cols, 0..) |col, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.writer(allocator).print("'{s}', {s}.\"{s}\"", .{ col, alias, col });
    }
    try buf.append(allocator, ')');
    return buf.toOwnedSlice(allocator);
}

/// Extract a JSON field as text: `(src::jsonb ->> 'col')`, with an optional cast
/// (`->>` always yields `text`, so typed columns need `::<cast_type>` on restore).
fn dialectJsonExtract(allocator: std.mem.Allocator, src: []const u8, col: []const u8, cast_type: ?[]const u8) anyerror![]u8 {
    if (cast_type) |ty| {
        return std.fmt.allocPrint(allocator, "({s}::jsonb ->> '{s}')::{s}", .{ src, col, ty });
    }
    return std.fmt.allocPrint(allocator, "({s}::jsonb ->> '{s}')", .{ src, col });
}

pub const pg_dialect = backend.Dialect{
    .placeholder = .dollar,
    .nowEpoch = "EXTRACT(EPOCH FROM now())::bigint",
    .scalar_max = "GREATEST",
    .scalar_min = "LEAST",
    .upsert = dialectUpsert,
    .insertSelect = dialectInsertSelect,
    .returning = dialectReturning,
    .jsonObject = dialectJsonObject,
    .jsonExtract = dialectJsonExtract,
};

/// Rewrite SQLite-style placeholders into PostgreSQL `$N` placeholders, literal-aware:
///   - bare `?`        → `$1`, `$2`, … (auto-incrementing positional)
///   - explicit `?N`   → `$N` (number preserved; lets one param be referenced N times,
///                       as the reorg restore SQL does with `?1`)
///   - `?` inside a `'…'` string literal or `"…"` quoted identifier is left untouched.
/// Mixing bare `?` and `?N` in one statement is not supported (we never generate that).
///
/// ASSUMPTION: prepared SQL contains no `--`/`/* */` comments and no `$$…$$`
/// dollar-quoted strings — true for everything storage prepares (the only
/// dollar-quoted SQL, the PL/pgSQL reorg triggers, is `execRaw`'d, not prepared,
/// so it never reaches this lexer). A `?` inside such a construct would be wrongly
/// renumbered; add comment/dollar-quote skipping here if that ever changes.
/// Caller owns the returned slice.
pub fn renumberPlaceholders(allocator: std.mem.Allocator, sql: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    var auto: usize = 0;
    var i: usize = 0;
    while (i < sql.len) {
        const c = sql[i];
        switch (c) {
            '\'' => {
                // single-quoted string literal: copy verbatim through the closing quote
                // (handling the '' escape).
                try buf.append(allocator, c);
                i += 1;
                while (i < sql.len) {
                    try buf.append(allocator, sql[i]);
                    if (sql[i] == '\'') {
                        if (i + 1 < sql.len and sql[i + 1] == '\'') {
                            try buf.append(allocator, sql[i + 1]);
                            i += 2;
                            continue;
                        }
                        i += 1;
                        break;
                    }
                    i += 1;
                }
            },
            '"' => {
                // double-quoted identifier: copy verbatim through the closing quote
                // (handling the "" escape).
                try buf.append(allocator, c);
                i += 1;
                while (i < sql.len) {
                    try buf.append(allocator, sql[i]);
                    if (sql[i] == '"') {
                        if (i + 1 < sql.len and sql[i + 1] == '"') {
                            try buf.append(allocator, sql[i + 1]);
                            i += 2;
                            continue;
                        }
                        i += 1;
                        break;
                    }
                    i += 1;
                }
            },
            '?' => {
                i += 1;
                if (i < sql.len and std.ascii.isDigit(sql[i])) {
                    // explicit ?N → $N (preserve the number)
                    try buf.append(allocator, '$');
                    while (i < sql.len and std.ascii.isDigit(sql[i])) : (i += 1) {
                        try buf.append(allocator, sql[i]);
                    }
                } else {
                    // bare ? → next positional $N
                    auto += 1;
                    try buf.writer(allocator).print("${d}", .{auto});
                }
            },
            else => {
                try buf.append(allocator, c);
                i += 1;
            },
        }
    }
    return buf.toOwnedSlice(allocator);
}
