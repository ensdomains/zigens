//! Single source of truth for each table's `ON CONFLICT` target.
//!
//! Every entry is the UNIQUE (or natural PRIMARY KEY) constraint that SQLite's
//! `INSERT OR REPLACE`/`INSERT OR IGNORE` conflicts on, and that Postgres needs
//! as its explicit `ON CONFLICT (...)` target. Derived directly from
//! `schema/schema.sql`: each of these tables has exactly one such constraint
//! (tables with an autoincrement `id` PK carry a separate single `UNIQUE(...)`),
//! so the target is unambiguous. SQLite ignores the key (the verb implies it);
//! it is load-bearing only for the Postgres backend.
//!
//! Used by two consumers: the dialect upsert call sites, AND the reorg-undo restore
//! (`reorg_undo.getRestoreSql`). The latter is why the last group below — protected
//! tables that are NOT dialect-upsert sites but ARE reorg-captured — must be present:
//! their restore must conflict on the business UNIQUE, not the surrogate `id`, or a
//! reorg that deletes-then-reinserts the same key would abort with a unique_violation
//! on Postgres (SQLite's `INSERT OR REPLACE` conflicts on any unique constraint, so it
//! never hit this).
const std = @import("std");

const conflict_keys = std.StaticStringMap([]const []const u8).initComptime(.{
    .{ "sync_state", &[_][]const u8{"protocol"} },
    .{ "block_hashes", &[_][]const u8{ "protocol", "block_number" } },
    .{ "registries", &[_][]const u8{ "protocol", "address", "namehash" } },
    .{ "names", &[_][]const u8{ "protocol", "namehash" } },
    .{ "resolvers", &[_][]const u8{ "protocol", "namehash", "address" } },
    .{ "resolver_addresses", &[_][]const u8{ "protocol", "resolver", "namehash", "coin_type" } },
    .{ "resolver_contenthashes", &[_][]const u8{ "protocol", "resolver", "namehash" } },
    .{ "resolver_texts", &[_][]const u8{ "protocol", "resolver", "namehash", "key" } },
    .{ "resolver_aliases", &[_][]const u8{ "resolver", "from_name" } },
    .{ "resolver_pubkeys", &[_][]const u8{ "protocol", "resolver", "namehash" } },
    .{ "resolver_abis", &[_][]const u8{ "protocol", "resolver", "namehash", "content_type" } },
    .{ "resolver_names", &[_][]const u8{ "protocol", "resolver", "namehash" } },
    .{ "resolver_interfaces", &[_][]const u8{ "protocol", "resolver", "namehash", "interface_id" } },
    .{ "resolver_authorisations", &[_][]const u8{ "protocol", "resolver", "namehash", "owner", "target" } },
    .{ "resolver_dns_records", &[_][]const u8{ "protocol", "resolver", "namehash", "dns_name", "resource" } },
    .{ "resolver_dns_zonehashes", &[_][]const u8{ "protocol", "resolver", "namehash" } },
    .{ "resolver_versions", &[_][]const u8{ "resolver", "namehash" } },
    .{ "events", &[_][]const u8{ "protocol", "tx_hash", "log_index" } },
    .{ "event_attributions", &[_][]const u8{ "protocol", "tx_hash", "log_index", "namehash" } },
    .{ "approvals", &[_][]const u8{ "protocol", "token_id", "registry" } },
    .{ "v1_labels", &[_][]const u8{"token_id"} },
    .{ "name_history", &[_][]const u8{ "protocol", "namehash", "change_type", "block_number", "log_index" } },
    .{ "temp_pre_migration_names", &[_][]const u8{ "protocol", "namehash" } },
    .{ "backfill_status", &[_][]const u8{"task"} },
    .{ "init_gap_heal_targets", &[_][]const u8{ "task", "protocol", "address" } },
    .{ "orphaned_registrations", &[_][]const u8{ "protocol", "tx_hash", "log_index" } },
    .{ "registrations", &[_][]const u8{ "protocol", "transaction_hash", "log_index" } },
    // Reorg-captured tables that are NOT dialect-upsert sites — present here solely so
    // getRestoreSql conflicts on the business UNIQUE (not the surrogate `id`). The first
    // five are PROTECTED tables with an inline `UNIQUE(...)`; `unknown_labels` is a
    // reorg_active table whose uniqueness is a separate `CREATE UNIQUE INDEX` (both cols
    // NOT NULL, so no NULL-distinct surprise) — ON CONFLICT infers the index fine.
    .{ "registry_entries", &[_][]const u8{ "protocol", "parent_registry", "canonical_id" } },
    .{ "eac_roles", &[_][]const u8{ "protocol", "resource", "account", "contract_address" } },
    .{ "resolver_metadata", &[_][]const u8{ "protocol", "resolver" } },
    .{ "resolver_approvals", &[_][]const u8{ "protocol", "resolver", "namehash", "context", "delegate" } },
    .{ "resolver_named_resources", &[_][]const u8{ "protocol", "resolver", "resource" } },
    .{ "resolver_links", &[_][]const u8{ "protocol", "resolver", "namehash" } },
    .{ "resolver_datas", &[_][]const u8{ "protocol", "resolver", "namehash", "key" } },
    .{ "resolver_kinds", &[_][]const u8{ "protocol", "resolver" } },
    .{ "reverse_records", &[_][]const u8{ "protocol", "address" } },
    .{ "unknown_labels", &[_][]const u8{ "labelhash", "parent_node" } },
    // Resolution cache — created via resolve/cache.zig `ensureSchema` (not the
    // drop-and-reindex base schema, so it appears here rather than being derived
    // from schema/schema.sql). Its composite PRIMARY KEY is the ON CONFLICT target.
    .{ "resolution_cache", &[_][]const u8{ "chain_id", "target", "selector_key", "arg_hash", "block_dep_hash" } },
    // Finality tiers — created via storage/finality.zig `ensureSchema` (also not in the
    // base schema); one row per (chain_id, tier) with tier in ('safe','finalized').
    .{ "finality_state", &[_][]const u8{ "chain_id", "tier" } },
});

/// The conflict-key columns for `table`, or null if the table is not a known
/// upsert target (callers turn this into `error.UnknownUpsertTable`).
pub fn conflictColsFor(table: []const u8) ?[]const []const u8 {
    return conflict_keys.get(table);
}

test "conflictColsFor matches every schema-derived key" {
    // Pins all 29 entries against schema/schema.sql — the sole guard on these
    // keys, since SQLite ignores them and only Postgres (Phase 4) exercises them.
    const expected = .{
        .{ "sync_state", &[_][]const u8{"protocol"} },
        .{ "block_hashes", &[_][]const u8{ "protocol", "block_number" } },
        .{ "registries", &[_][]const u8{ "protocol", "address", "namehash" } },
        .{ "names", &[_][]const u8{ "protocol", "namehash" } },
        .{ "resolvers", &[_][]const u8{ "protocol", "namehash", "address" } },
        .{ "resolver_addresses", &[_][]const u8{ "protocol", "resolver", "namehash", "coin_type" } },
        .{ "resolver_contenthashes", &[_][]const u8{ "protocol", "resolver", "namehash" } },
        .{ "resolver_texts", &[_][]const u8{ "protocol", "resolver", "namehash", "key" } },
        .{ "resolver_aliases", &[_][]const u8{ "resolver", "from_name" } },
        .{ "resolver_pubkeys", &[_][]const u8{ "protocol", "resolver", "namehash" } },
        .{ "resolver_abis", &[_][]const u8{ "protocol", "resolver", "namehash", "content_type" } },
        .{ "resolver_names", &[_][]const u8{ "protocol", "resolver", "namehash" } },
        .{ "resolver_interfaces", &[_][]const u8{ "protocol", "resolver", "namehash", "interface_id" } },
        .{ "resolver_authorisations", &[_][]const u8{ "protocol", "resolver", "namehash", "owner", "target" } },
        .{ "resolver_dns_records", &[_][]const u8{ "protocol", "resolver", "namehash", "dns_name", "resource" } },
        .{ "resolver_dns_zonehashes", &[_][]const u8{ "protocol", "resolver", "namehash" } },
        .{ "resolver_versions", &[_][]const u8{ "resolver", "namehash" } },
        .{ "events", &[_][]const u8{ "protocol", "tx_hash", "log_index" } },
        .{ "event_attributions", &[_][]const u8{ "protocol", "tx_hash", "log_index", "namehash" } },
        .{ "approvals", &[_][]const u8{ "protocol", "token_id", "registry" } },
        .{ "v1_labels", &[_][]const u8{"token_id"} },
        .{ "name_history", &[_][]const u8{ "protocol", "namehash", "change_type", "block_number", "log_index" } },
        .{ "temp_pre_migration_names", &[_][]const u8{ "protocol", "namehash" } },
        .{ "backfill_status", &[_][]const u8{"task"} },
        .{ "init_gap_heal_targets", &[_][]const u8{ "task", "protocol", "address" } },
        .{ "orphaned_registrations", &[_][]const u8{ "protocol", "tx_hash", "log_index" } },
        .{ "registrations", &[_][]const u8{ "protocol", "transaction_hash", "log_index" } },
        .{ "registry_entries", &[_][]const u8{ "protocol", "parent_registry", "canonical_id" } },
        .{ "eac_roles", &[_][]const u8{ "protocol", "resource", "account", "contract_address" } },
        .{ "resolver_metadata", &[_][]const u8{ "protocol", "resolver" } },
        .{ "resolver_approvals", &[_][]const u8{ "protocol", "resolver", "namehash", "context", "delegate" } },
        .{ "resolver_named_resources", &[_][]const u8{ "protocol", "resolver", "resource" } },
        .{ "resolver_links", &[_][]const u8{ "protocol", "resolver", "namehash" } },
        .{ "resolver_datas", &[_][]const u8{ "protocol", "resolver", "namehash", "key" } },
        .{ "resolver_kinds", &[_][]const u8{ "protocol", "resolver" } },
        .{ "reverse_records", &[_][]const u8{ "protocol", "address" } },
        .{ "unknown_labels", &[_][]const u8{ "labelhash", "parent_node" } },
        .{ "resolution_cache", &[_][]const u8{ "chain_id", "target", "selector_key", "arg_hash", "block_dep_hash" } },
        .{ "finality_state", &[_][]const u8{ "chain_id", "tier" } },
    };
    inline for (expected) |e| {
        try std.testing.expectEqualDeep(@as(?[]const []const u8, e[1]), conflictColsFor(e[0]));
    }
    try std.testing.expectEqual(@as(usize, expected.len), conflict_keys.keys().len);
    try std.testing.expectEqual(@as(?[]const []const u8, null), conflictColsFor("no_such_table"));
}
