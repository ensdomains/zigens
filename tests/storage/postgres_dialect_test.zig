//! Golden-string tests for the PostgreSQL dialect builders + the `?`→`$N` lexer
//! (src/storage/drivers/postgres_dialect.zig). Pure string transformation — no
//! pg.zig and no running Postgres — so these pin the exact SQL the Phase-4 driver
//! will emit, validating the dialect without a live backend.
const std = @import("std");
const testing = std.testing;
const lib = @import("lib");

const pg = lib.storage.postgres_dialect;
const d = pg.pg_dialect;

test "pg dialect: upsert replace builds ON CONFLICT DO UPDATE over non-key cols" {
    const a = testing.allocator;
    const sql = try d.upsert(a, "names", &.{ "protocol", "namehash", "owner", "resolver" }, &.{}, &.{ "protocol", "namehash" }, .replace);
    defer a.free(sql);
    try testing.expectEqualStrings(
        "INSERT INTO \"names\" (\"protocol\", \"namehash\", \"owner\", \"resolver\") VALUES (?, ?, ?, ?) ON CONFLICT (\"protocol\", \"namehash\") DO UPDATE SET \"owner\" = EXCLUDED.\"owner\", \"resolver\" = EXCLUDED.\"resolver\"",
        sql,
    );
}

test "pg dialect: upsert ignore builds ON CONFLICT DO NOTHING" {
    const a = testing.allocator;
    const sql = try d.upsert(a, "events", &.{ "tx_hash", "log_index" }, &.{}, &.{ "protocol", "tx_hash", "log_index" }, .ignore);
    defer a.free(sql);
    try testing.expectEqualStrings(
        "INSERT INTO \"events\" (\"tx_hash\", \"log_index\") VALUES (?, ?) ON CONFLICT DO NOTHING",
        sql,
    );
}

test "pg dialect: upsert replace with all-key columns falls back to DO NOTHING" {
    const a = testing.allocator;
    const sql = try d.upsert(a, "reorg_cursor", &.{"protocol"}, &.{}, &.{"protocol"}, .replace);
    defer a.free(sql);
    try testing.expectEqualStrings(
        "INSERT INTO \"reorg_cursor\" (\"protocol\") VALUES (?) ON CONFLICT (\"protocol\") DO NOTHING",
        sql,
    );
}

test "pg dialect: upsert with value_exprs keeps literals/wrappers inline" {
    const a = testing.allocator;
    const sql = try d.upsert(a, "reorg_active", &.{ "id", "protocol", "block_number" }, &.{ "1", "?", "?" }, &.{"id"}, .replace);
    defer a.free(sql);
    try testing.expectEqualStrings(
        "INSERT INTO \"reorg_active\" (\"id\", \"protocol\", \"block_number\") VALUES (1, ?, ?) ON CONFLICT (\"id\") DO UPDATE SET \"protocol\" = EXCLUDED.\"protocol\", \"block_number\" = EXCLUDED.\"block_number\"",
        sql,
    );
}

test "pg dialect: insertSelect wraps body with ON CONFLICT DO NOTHING" {
    const a = testing.allocator;
    const sql = try d.insertSelect(a, "resolvers", &.{ "protocol", "address" }, "SELECT n.protocol, n.resolver FROM names n", &.{ "protocol", "namehash", "address" }, .ignore);
    defer a.free(sql);
    try testing.expectEqualStrings(
        "INSERT INTO \"resolvers\" (\"protocol\", \"address\") SELECT n.protocol, n.resolver FROM names n ON CONFLICT DO NOTHING",
        sql,
    );
}

test "pg dialect: jsonExtract emits ->> with optional cast" {
    const a = testing.allocator;
    const no_cast = try d.jsonExtract(a, "?1", "owner", null);
    defer a.free(no_cast);
    try testing.expectEqualStrings("(?1::jsonb ->> 'owner')", no_cast);

    const cast = try d.jsonExtract(a, "?1", "block_number", "bigint");
    defer a.free(cast);
    try testing.expectEqualStrings("(?1::jsonb ->> 'block_number')::bigint", cast);
}

test "pg dialect: jsonObject + returning + nowEpoch + placeholder" {
    const a = testing.allocator;
    const obj = try d.jsonObject(a, &.{ "protocol", "namehash" }, "OLD");
    defer a.free(obj);
    try testing.expectEqualStrings("jsonb_build_object('protocol', OLD.\"protocol\", 'namehash', OLD.\"namehash\")", obj);

    const ret = try d.returning(a, "id");
    defer a.free(ret);
    try testing.expectEqualStrings(" RETURNING id", ret);

    try testing.expectEqual(@as(@TypeOf(d.placeholder), .dollar), d.placeholder);
    try testing.expectEqualStrings("EXTRACT(EPOCH FROM now())::bigint", d.nowEpoch);
}

test "renumberPlaceholders: bare ? becomes $1,$2,… positionally" {
    const a = testing.allocator;
    const out = try pg.renumberPlaceholders(a, "INSERT INTO \"t\" (\"a\", \"b\", \"c\") VALUES (?, ?, ?)");
    defer a.free(out);
    try testing.expectEqualStrings("INSERT INTO \"t\" (\"a\", \"b\", \"c\") VALUES ($1, $2, $3)", out);
}

test "renumberPlaceholders: explicit ?1 is preserved as $1 (referenced N times)" {
    const a = testing.allocator;
    const out = try pg.renumberPlaceholders(a, "VALUES ((?1::jsonb ->> 'a'), (?1::jsonb ->> 'b'), (?1::jsonb ->> 'c'))");
    defer a.free(out);
    try testing.expectEqualStrings("VALUES (($1::jsonb ->> 'a'), ($1::jsonb ->> 'b'), ($1::jsonb ->> 'c'))", out);
}

test "renumberPlaceholders: ? inside string literals and identifiers is untouched" {
    const a = testing.allocator;
    const out = try pg.renumberPlaceholders(a, "SET name = 'is it? yes' WHERE x = ? AND y = 'a''?''b' AND \"c?d\" = ?");
    defer a.free(out);
    try testing.expectEqualStrings("SET name = 'is it? yes' WHERE x = $1 AND y = 'a''?''b' AND \"c?d\" = $2", out);
}

test "renumberPlaceholders: LOWER(?) wrapper and mixed literals" {
    const a = testing.allocator;
    const out = try pg.renumberPlaceholders(a, "VALUES (?, ?, LOWER(?), 'migration', NULL, ?)");
    defer a.free(out);
    try testing.expectEqualStrings("VALUES ($1, $2, LOWER($3), 'migration', NULL, $4)", out);
}
