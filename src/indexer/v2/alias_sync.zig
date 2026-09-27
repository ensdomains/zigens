//! Shared-registry alias derivation: bring `names` to the fixpoint defined in
//! `storage/name_aliases.zig` — one row per (label, live referring parent).
//!
//! The problem, in one sentence: a `PermissionedRegistry` can be the subregistry of
//! several parent names at once, `getSubregistry(label)` returns it for every one of
//! them, so every label in it resolves under every one of them — but
//! `LabelRegistered` is emitted by the child registry and names no parent, so the
//! handler can only attribute the label to ONE of them and the remaining
//! fully-qualified names are never stored.
//!
//! This is the other half of the fix. The handlers pick the parent the chain events
//! attach to (live pointer first — see `resolveSubregistryParent`) and write that
//! one row; this pass adds the rest as `is_alias = 1` rows derived from it.
//!
//! ## Why a derivation and not a handler fan-out
//!
//!   * `events` and `registrations` are UNIQUE(protocol, tx_hash, log_index), so one
//!     log physically cannot carry N rows — a fan-out inside the handler would
//!     silently drop rows 2..N there.
//!   * The adopting parent's `SubregistryUpdated` arrives AFTER the labels already
//!     in the registry were indexed, so a registration-time fan-out cannot see it.
//!     Only a state-derived pass covers both orders.
//!   * It makes `--backfill` replay exact without touching the replay path: the rows
//!     are a pure function of `names` + `registries` + `registry_entries`, so
//!     re-running once those are rebuilt reproduces them byte for byte. (The replay's
//!     V2 names step reconstructs each row from the FQDN frozen into its event, which
//!     by construction only ever holds one.)
//!
//! ## Bounded work, unbounded convergence
//!
//! `LIVE_BUDGET_ROWS` caps how many rows one live pass writes, so a shared registry
//! holding a large label set cannot stall a batch: the remainder is picked up by the
//! next batch, and the log says so rather than going quiet. The budget changes the
//! PATH only — the fixpoint is the same, and `runToFixpoint` (used by `--backfill`)
//! removes the cap so a replay converges in one pass and can be compared byte for
//! byte against a live database.
const std = @import("std");
const models = @import("../../types/models.zig");
const name_aliases = @import("../../storage/name_aliases.zig");
const Indexer = @import("../indexer.zig").Indexer;

/// Rows fetched per plan statement. One indexed anti-join page; also the ceiling on
/// how many unbuildable rows can sit in front of buildable ones without the cursor
/// stepping over them.
const PLAN_PAGE: usize = 500;

/// Rows one LIVE pass may write before deferring the rest to the next batch. Each
/// row costs an insert plus the reachability probe at the insert chokepoint, so this
/// is the knob that keeps a first-time materialisation off the critical path.
const LIVE_BUDGET_ROWS: u64 = 2000;

/// Pages per registry per pass, as a runaway guard: bounds the work even if every row
/// is unbuildable, so the cursor walks that registry's whole plan. Unbounded mode raises
/// it; it never removes it.
const MAX_PAGES_PER_REGISTRY: usize = 64;

/// Registries taken off the change queue in one pass.
const MAX_REGISTRIES_PER_PASS: usize = 16;

pub const Stats = struct {
    /// Registries taken off the queue this pass.
    registries_processed: usize = 0,
    /// Registries that converged and left the queue.
    registries_converged: usize = 0,
    aliases_written: u64 = 0,
    aliases_deleted: u64 = 0,
    /// Plan rows that cannot be built — their namehash already belongs to a primary.
    skipped_collisions: u64 = 0,
    /// True when the budget stopped the pass with registries still queued.
    work_remaining: bool = false,
};

pub const Options = struct {
    /// Null removes the row budget: converge every queued registry. Used by replay.
    budget_rows: ?u64 = LIVE_BUDGET_ROWS,
    /// Registries to take off the queue in one pass.
    max_registries: usize = MAX_REGISTRIES_PER_PASS,
    max_pages_per_registry: usize = MAX_PAGES_PER_REGISTRY,
};

/// One bounded pass: drain as much of the change queue as the budget allows.
///
/// A steady state is an empty queue, which costs exactly one indexed lookup against the
/// small `alias_work` table. Nothing scans `names` until a registry is actually enqueued
/// by a change, which is what makes this safe to call after every batch — the earlier
/// re-derive-everything form measured 23.8s per batch at 1.6M names.
pub fn syncSharedRegistryAliases(self: *Indexer, protocol: models.Protocol, now: i64) !Stats {
    return syncSharedRegistryAliasesOpts(self, protocol, now, .{});
}

/// Converge everything, no row budget — for `--backfill`, where the point is to land on
/// exactly the rows a live run reached. Enqueues every candidate first, so it does not
/// depend on a queue the replay never built.
pub fn runToFixpoint(self: *Indexer, protocol: models.Protocol, now: i64) !Stats {
    _ = try name_aliases.enqueueAllAliasCandidates(self.database, protocol, 0);
    return syncSharedRegistryAliasesOpts(self, protocol, now, .{
        .budget_rows = null,
        .max_registries = std.math.maxInt(usize),
        .max_pages_per_registry = 1 << 20,
    });
}

/// Re-enqueue every candidate registry: the self-heal for a missed enqueue. Cheap — it
/// reads the small pointer mirror plus the registries that still hold derived rows.
pub fn sweep(self: *Indexer, protocol: models.Protocol, block_number: u64) !usize {
    return name_aliases.sweepAliasCandidates(self.database, protocol, block_number);
}

/// `now` is the chain time the parent-expiry test is evaluated at — an expired parent resolves
/// nothing beneath it, so it owes no derived names. Chain time, never a wall clock: the derivation
/// has to stay reproducible by a replay.
pub fn syncSharedRegistryAliasesOpts(self: *Indexer, protocol: models.Protocol, now: i64, opts: Options) !Stats {
    var stats: Stats = .{};

    const items = try name_aliases.takeAliasWork(self.database, self.allocator, protocol, opts.max_registries);
    defer name_aliases.freeAliasWork(self.allocator, items);
    if (items.len == 0) return stats;

    for (items) |item| {
        if (opts.budget_rows) |budget| {
            if (stats.aliases_written >= budget) {
                stats.work_remaining = true;
                break;
            }
        }
        stats.registries_processed += 1;

        // Delete first. A parent that repointed from one shared registry to another is a
        // delete of the old FQDN and an insert of the new one, and deleting first means the
        // intermediate state is "fewer names", never "this label under a parent that no
        // longer refers to it". Scoped to the registry, so its cost is that registry's
        // derived rows rather than every derived row in the database.
        // Scoped as narrowly as the work item allows: a label item checks only its own
        // derived rows, an edge item has to check the registry's (every one of them may have
        // gone stale). The difference is 13.1s vs microseconds on a registry holding 1.4M.
        stats.aliases_deleted += try name_aliases.deleteStaleAliasesScoped(self.database, protocol, item.registry, item.label, now);

        // A label item is a point operation: O(live parents) rows, one indexed lookup. No
        // cursor, no paging — this is the path a registration in a shared registry takes,
        // and keeping it off the whole-registry scan is what bounds the steady state.
        if (item.label) |label| {
            const keys = try name_aliases.aliasPlanBatch(self.database, self.allocator, protocol, item.registry, label, now, .{}, PLAN_PAGE);
            defer name_aliases.freeAliasPlan(self.allocator, keys);
            for (keys) |key| {
                if (try buildAlias(self, protocol, key)) {
                    stats.aliases_written += 1;
                } else {
                    stats.skipped_collisions += 1;
                }
            }
            _ = try name_aliases.completeAliasWork(self.database, protocol, item.registry, label, false);
            stats.registries_converged += 1;
            continue;
        }

        // Stable storage for the cursor: plan keys are freed at the end of each page, so a
        // cursor a later page binds must be copied out rather than aliased.
        var canonical_buf: [66]u8 = undefined;
        var parent_buf: [66]u8 = undefined;
        var canonical_len: usize = 0;
        var cursor = item.cursor;
        var reached_end = false;
        var pages: usize = 0;
        while (pages < opts.max_pages_per_registry) : (pages += 1) {
            if (opts.budget_rows) |budget| {
                if (stats.aliases_written >= budget) break;
            }
            const keys = try name_aliases.aliasPlanBatch(self.database, self.allocator, protocol, item.registry, null, now, cursor, PLAN_PAGE);
            defer name_aliases.freeAliasPlan(self.allocator, keys);
            if (keys.len == 0) {
                reached_end = true;
                break;
            }

            var advanced = false;
            for (keys) |key| {
                if (try buildAlias(self, protocol, key)) {
                    stats.aliases_written += 1;
                } else {
                    // Not an error, and the cursor still moves past it: a permanently
                    // unbuildable row must not head every subsequent page and starve the
                    // rows behind it.
                    stats.skipped_collisions += 1;
                }
                canonical_len = @min(key.canonical_id.len, canonical_buf.len);
                @memcpy(canonical_buf[0..canonical_len], key.canonical_id[0..canonical_len]);
                _ = key.parent_namehash.toHexBuf(&parent_buf);
                advanced = true;
                if (opts.budget_rows) |budget| {
                    if (stats.aliases_written >= budget) break;
                }
            }
            if (advanced) {
                cursor = .{ .canonical_id = canonical_buf[0..canonical_len], .parent_namehash = &parent_buf };
                // Persisted as we go, so a crash or a budget stop resumes here rather than
                // rescanning this registry from the beginning.
                try name_aliases.saveAliasWorkCursorHex(self.database, protocol, item.registry, canonical_buf[0..canonical_len], &parent_buf);
            }
            if (keys.len < PLAN_PAGE) {
                reached_end = true;
                break;
            }
        }

        if (reached_end) {
            if (try name_aliases.completeAliasWork(self.database, protocol, item.registry, null, item.restart)) {
                stats.registries_converged += 1;
            }
        } else {
            stats.work_remaining = true;
        }
    }

    if (stats.aliases_written > 0 or stats.aliases_deleted > 0 or stats.work_remaining) {
        std.log.info(
            "shared-registry aliases: +{d} derived, -{d} stale, {d} collision(s) skipped across {d} work item(s), {d} converged{s}",
            .{
                stats.aliases_written,
                stats.aliases_deleted,
                stats.skipped_collisions,
                stats.registries_processed,
                stats.registries_converged,
                if (stats.work_remaining) " — budget reached, continuing next batch" else "",
            },
        );
    }
    return stats;
}

/// Materialise the one alias row `key` asks for. Returns false when it cannot be
/// built, which is not an error — see `name_aliases.buildAliasRow` for the guards.
fn buildAlias(self: *Indexer, protocol: models.Protocol, key: name_aliases.AliasPlanKey) !bool {
    var row = (try name_aliases.buildAliasRow(self.database, self.allocator, protocol, key)) orelse return false;
    defer row.deinit(self.allocator);
    // Through the shared chokepoint, so the derived row gets the same is_normalized /
    // is_reachable stamps a handler-written one does — `<label>.<parent>` can be
    // non-normalized where `<label>.<other>` was normalized, and only the chokepoint
    // decides either.
    try self.insertName(row);
    return true;
}
