//! Discovery backfills for contracts that become known mid-sync (resolvers
//! first sighted via ResolverUpdated, subregistries via SubregistryUpdated,
//! and the durable init-gap heal ledger). Their initialize()-time events fire
//! before the pointer that makes them known, so each one owes a sweep from
//! its deployment block up to the current batch.
//!
//! Everything here is batched across the whole set of contracts owed a sweep:
//!
//!  - Deployment anchors come from one 8-ary bisection over ALL addresses at
//!    once, each round a handful of JSON-RPC batches of eth_getCode probes.
//!    A 140k-block window resolves in ~6 rounds instead of ~17 serial probes
//!    per contract.
//!  - Sweeps run as multi-address eth_getLogs over groups of contracts sorted
//!    by anchor, so a hundred resolvers cost one call per block chunk instead
//!    of one call per contract per chunk. The chunk size starts at the whole
//!    range and only shrinks when the provider rejects it; the learned ceiling
//!    persists on the Indexer for the rest of the run.
//!
//! Per-target outcomes still land in the init-gap heal ledger, so a failed
//! group is retried later exactly as a failed single sweep was.

const std = @import("std");
const zsys = @import("../utils/system.zig");
const models = @import("../types/models.zig");
const rpc = @import("../rpc/client.zig");
const Hash = @import("../types/hash.zig").Hash;
const Address = @import("../types/address.zig").Address;
const Indexer = @import("indexer.zig").Indexer;
const utils = @import("utils.zig");

pub const RESOLVER_HEAL_TASK = "resolver_init_gaps";
pub const SUBREGISTRY_HEAL_TASK = "subregistry_init_gaps";
pub const HEAL_MAX_ATTEMPTS: u32 = 8;

pub const Kind = enum {
    resolver,
    subregistry,

    fn task(self: Kind) []const u8 {
        return switch (self) {
            .resolver => RESOLVER_HEAL_TASK,
            .subregistry => SUBREGISTRY_HEAL_TASK,
        };
    }

    fn label(self: Kind) []const u8 {
        return switch (self) {
            .resolver => "resolver",
            .subregistry => "subregistry",
        };
    }
};

/// Interior probes per open interval per round (8-ary search).
const PROBES_PER_ROUND: usize = 7;
/// eth_getCode probes per HTTP request. Deliberately not its own env knob:
/// RPC_MAX_BATCH_REQUESTS already caps what the rpc client puts in one HTTP
/// batch, and the ladder below learns a size the provider actually accepts.
/// Cap on the memoised-anchor map. One entry is 28 bytes, so this is a few MB at
/// the ceiling; past it the cache simply stops growing and those contracts are
/// bisected as before, which is a slowdown and never a wrong answer.
const ANCHOR_CACHE_MAX: usize = 200_000;

/// A found deployment block is immutable, so it is worth remembering: the
/// bisection costs ~log2(ceil - floor) `eth_getCode` probes per contract and
/// `backfillDiscovered` re-ran it on every call. A batch that rolls back and
/// retries re-registers its resolvers (sync_driver drops the dedup caches on
/// purpose, so the retry re-queues them), so a shrinking batch paid the full
/// probe cost once per attempt.
///
/// Only FOUND anchors are stored. A null means "no code up to this ceiling",
/// which a later, higher ceiling may well resolve — memoising that would make a
/// contract deployed after the probe permanently invisible.
pub const AnchorCache = std.AutoHashMap([20]u8, u64);

fn anchorCacheGet(cache: *AnchorCache, addr: Address) ?u64 {
    return cache.get(addr.bytes);
}

fn anchorCachePut(cache: *AnchorCache, addr: Address, anchor: u64) void {
    if (cache.count() >= ANCHOR_CACHE_MAX) return;
    cache.put(addr.bytes, anchor) catch {};
}

const PROBE_HTTP_BATCH: usize = 96;
/// Size a non-rate-limit rejection (batch cap, response size) falls back to.
const PROBE_FALLBACK_BATCH: usize = 8;
/// Sizes a rate-limited probe walks down before any contract degrades to the
/// floor — single probes are the last rung, since a throttling provider answers
/// a narrow request long before a wide one.
const PROBE_BATCH_LADDER = [_]usize{ PROBE_HTTP_BATCH, 32, PROBE_FALLBACK_BATCH, 1 };
/// Same-size retries per rung after a rate-limit rejection. One, because the
/// rpc client has already retried that request itself with backoff.
const PROBE_RATE_LIMIT_RETRIES: u32 = 1;
/// Cooldown waits a whole discovery backfill may spend sitting out throttles.
/// They escalate 1s, 2s, 4s, 8s (rpc.retryBackoffMs), so the run waits at most
/// ~31s in total before anchors start degrading to the floor — bounded far
/// inside SYNC_FAILURE_EXIT_MINUTES, and the heal ledger still owns the rest.
const PROBE_COOLDOWN_BUDGET: u32 = 6;
/// Contracts per multi-address eth_getLogs request.
const GROUP_MAX_ADDRESSES: usize = 100;
const SWEEP_MIN_CHUNK: u64 = 500;

pub const Outcome = struct {
    total: usize = 0,
    no_history: usize = 0,
    /// Contracts whose deployment block was already memoised, so they cost no probes.
    anchors_cached: usize = 0,
    swept: usize = 0,
    failed: usize = 0,
    groups: usize = 0,
    calls: usize = 0,
    events: usize = 0,
    /// Targets left unswept because the cycle's time budget ran out. They keep
    /// `completed = 0` in the ledger, so the next cycle picks them up — the
    /// ledger IS the resume state, no extra bookkeeping needed.
    deferred: usize = 0,
};

const Interval = struct {
    lo: u64,
    hi: u64,
    state: enum { open, done, none, failed },
};

/// Bisect the first block at which each address has code — its deployment
/// block — using batched probes across every address at once. Result i is
/// null when address i has no code at or before `ceil` (provably nothing to
/// sweep). A probe failure degrades that address to `floor`: slower, never
/// lossy. `prober` must expose `probe(probes, out)` filling `out[i]` with
/// null on failure.
pub fn searchAnchors(allocator: std.mem.Allocator, prober: anytype, addrs: []const Address, floor: u64, ceil: u64) ![]?u64 {
    const out = try allocator.alloc(?u64, addrs.len);
    errdefer allocator.free(out);
    if (addrs.len == 0) return out;
    if (ceil <= floor) {
        @memset(out, floor);
        return out;
    }

    const intervals = try allocator.alloc(Interval, addrs.len);
    defer allocator.free(intervals);
    for (intervals) |*iv| iv.* = .{ .lo = floor, .hi = ceil, .state = .open };

    var probes: std.ArrayList(rpc.Client.CodeProbe) = .empty;
    defer probes.deinit(allocator);
    var owners: std.ArrayList(usize) = .empty;
    defer owners.deinit(allocator);
    var answers: std.ArrayList(?bool) = .empty;
    defer answers.deinit(allocator);

    for (addrs, 0..) |addr, i| {
        try probes.append(allocator, .{ .address = addr, .block = ceil });
        try owners.append(allocator, i);
        try probes.append(allocator, .{ .address = addr, .block = floor });
        try owners.append(allocator, i);
    }
    try answers.resize(allocator, probes.items.len);
    prober.probe(probes.items, answers.items);
    var p: usize = 0;
    while (p < probes.items.len) : (p += 2) {
        const iv = &intervals[owners.items[p]];
        const at_ceil = answers.items[p] orelse {
            iv.state = .failed;
            continue;
        };
        if (!at_ceil) {
            iv.state = .none;
            continue;
        }
        const at_floor = answers.items[p + 1] orelse {
            iv.state = .failed;
            continue;
        };
        if (at_floor) {
            iv.hi = floor;
            iv.state = .done;
        }
    }

    while (true) {
        probes.clearRetainingCapacity();
        owners.clearRetainingCapacity();
        for (intervals, 0..) |*iv, i| {
            if (iv.state != .open) continue;
            if (iv.hi - iv.lo <= 1) {
                iv.state = .done;
                continue;
            }
            const interior = iv.hi - iv.lo - 1;
            const count: u64 = @min(interior, PROBES_PER_ROUND);
            const step = (iv.hi - iv.lo) / (count + 1);
            var j: u64 = 0;
            while (j < count) : (j += 1) {
                try probes.append(allocator, .{ .address = addrs[i], .block = iv.lo + step * (j + 1) });
                try owners.append(allocator, i);
            }
        }
        if (probes.items.len == 0) break;
        try answers.resize(allocator, probes.items.len);
        prober.probe(probes.items, answers.items);
        for (probes.items, 0..) |probe, k| {
            const iv = &intervals[owners.items[k]];
            if (iv.state != .open) continue;
            const has = answers.items[k] orelse {
                iv.state = .failed;
                continue;
            };
            if (has) {
                if (probe.block < iv.hi) iv.hi = probe.block;
            } else if (probe.block > iv.lo) {
                iv.lo = probe.block;
            }
        }
    }

    for (intervals, 0..) |iv, i| {
        out[i] = switch (iv.state) {
            .none => null,
            .failed => floor,
            .done => iv.hi,
            .open => unreachable,
        };
    }
    return out;
}

/// Batch size to try after a failure at `current`, or null when the ladder is
/// spent and the affected contracts must degrade to the floor. A rate limit
/// walks every rung (the provider is busy, not strict); any other rejection
/// keeps the historical single shrink to PROBE_FALLBACK_BATCH.
fn nextProbeBatchSize(current: usize, rate_limited: bool) ?usize {
    if (current <= 1) return null;
    if (!rate_limited) return if (current > PROBE_FALLBACK_BATCH) PROBE_FALLBACK_BATCH else null;
    for (PROBE_BATCH_LADDER) |rung| {
        if (rung < current) return rung;
    }
    return null;
}

fn rejectionLabel(rate_limited: bool) []const u8 {
    return if (rate_limited) "rate limit" else "provider rejection";
}

/// Fill `out` from `ctx`, batching probes and walking the batch ladder whenever
/// the provider rejects a request. `ctx` must expose `fetch(probes, out) !void`
/// and `cooldown() bool` (sleep before retrying the same batch; false once the
/// run's wait budget is spent). A rate limit retries the SAME batch first — a
/// narrower request is no more welcome than the wide one while a provider is
/// throttling — and only then shrinks. Entries still unanswered when the ladder
/// is spent stay null, which the caller degrades to the configured floor, and
/// every one of those says so in the log. Once the wait budget is gone a
/// throttle is handled like any other rejection — one shrink, then the floor —
/// so a provider that rejects everything cannot grind the round through every
/// rung for every probe; the heal ledger retries those targets later. Returns
/// the batch size in force at the end so the caller keeps what it learned.
fn probeBatched(ctx: anytype, probes: []const rpc.Client.CodeProbe, out: []?bool, batch_start: usize) usize {
    @memset(out, null);
    var batch = @max(batch_start, 1);
    var start: usize = 0;
    var attempt: u32 = 0;
    var waits_spent = false;
    while (start < probes.len) {
        const end = @min(start + batch, probes.len);
        if (ctx.fetch(probes[start..end], out[start..end])) {
            start = end;
            attempt = 0;
        } else |err| {
            const rate_limited = err == error.RpcRateLimited;
            if (rate_limited and attempt < PROBE_RATE_LIMIT_RETRIES and !waits_spent) {
                if (ctx.cooldown()) {
                    attempt += 1;
                    continue;
                }
                waits_spent = true;
            }
            const walk_ladder = rate_limited and !waits_spent;
            if (nextProbeBatchSize(batch, walk_ladder)) |next| {
                std.log.warn("  Discovery anchor probe batch of {d} failed ({}, {s}); retrying in batches of {d}", .{ end - start, err, rejectionLabel(rate_limited), next });
                batch = next;
                attempt = 0;
                continue;
            }
            std.log.warn("  Discovery anchor probe batch of {d} failed ({}, {s}) with the batch ladder exhausted; {d} contract(s) fall back to the configured floor", .{ end - start, err, rejectionLabel(rate_limited), end - start });
            @memset(out[start..end], null);
            start = end;
            attempt = 0;
        }
    }
    return batch;
}

const RpcProber = struct {
    indexer: *Indexer,
    client: *rpc.Client,
    calls: *usize,
    /// Batch size learned this run: a provider that rejected the wide batch is
    /// not asked for it again every round. It never persists below the
    /// non-rate-limit fallback, because throttles pass.
    batch: *usize,
    cooldowns_left: *u32,

    fn fetch(self: RpcProber, probes: []const rpc.Client.CodeProbe, out: []?bool) !void {
        self.indexer.rate_limiter.acquire();
        self.calls.* += 1;
        const answers = try self.client.getCodeBatch(probes);
        defer self.client.allocator.free(answers);
        @memcpy(out, answers);
    }

    fn cooldown(self: RpcProber) bool {
        if (self.cooldowns_left.* == 0) return false;
        const spent = PROBE_COOLDOWN_BUDGET - self.cooldowns_left.*;
        self.cooldowns_left.* -= 1;
        const delay_ms = rpc.retryBackoffMs(spent + 1);
        std.log.warn("  Discovery anchor probe rate-limited; waiting {d}ms before retrying the same batch ({d} wait(s) left this run)", .{ delay_ms, self.cooldowns_left.* });
        zsys.sleep(delay_ms * std.time.ns_per_ms);
        return true;
    }

    fn probe(self: RpcProber, probes: []const rpc.Client.CodeProbe, out: []?bool) void {
        self.batch.* = probeBatched(self, probes, out, @max(self.batch.*, PROBE_FALLBACK_BATCH));
    }
};

const Target = struct {
    addr: Address,
    anchor: u64,
    /// Highest block this target's sweep may touch. The init gap is exactly the
    /// events a contract emitted BEFORE the indexer knew it existed, so
    /// everything from its first-seen block onward was already indexed by the
    /// ordinary path — re-sweeping it costs provider scan time and re-dispatches
    /// events that are already stored.
    ceil: u64,
};

/// The sweep window for one target: `null` means nothing is owed.
///
/// Two rules, and the asymmetry between them is deliberate:
///   - an UNKNOWN ceiling (0) falls back to `to_block`, i.e. the pre-existing
///     full-history sweep. Reading 0 as a literal ceiling would sweep nothing
///     and leave the init gap forever — a silent permanent hole, which is far
///     worse than the redundant scan it replaces.
///   - a known ceiling is clamped to `to_block`, because no sweep may run past
///     the block the indexer has actually reached.
/// A ceiling below the anchor means the contract was already known at its own
/// deployment block, so no unseen events exist.
fn sweepWindow(anchor: u64, raw_ceil: u64, to_block: u64) ?u64 {
    const ceil = if (raw_ceil == 0) to_block else @min(raw_ceil, to_block);
    if (ceil < anchor) return null;
    return ceil;
}

/// Sort by ceiling first so a group is ceiling-homogeneous: the group sweeps to
/// its highest member's ceiling, and clustering equal ceilings keeps the
/// over-sweep above a member's own ceiling near zero. Anchor breaks ties, which
/// preserves the anchor clustering that keeps a group's block span tight.
fn targetLessThan(_: void, a: Target, b: Target) bool {
    if (a.ceil != b.ceil) return a.ceil < b.ceil;
    return a.anchor < b.anchor;
}

/// Sweep every contract in `addrs` from its deployment block to `to_block`
/// and record each one's outcome in the init-gap heal ledger (v2 only, the
/// ledger's authoritative protocol). Never fails: a failed group is logged
/// and its targets stay owed in the ledger.
/// `ceils`, when given, is aligned with `addrs` and caps each target's sweep
/// individually; 0 means "unknown, use `to_block`". Pass null to sweep every
/// address to `to_block` (the discovery-time path already knows its own ceiling
/// and passes `from_block - 1` as `to_block`).
/// `deadline_ms`, when given, stops the pass between groups once the wall clock
/// passes it. The first group always runs, so a budget smaller than one group's
/// cost degrades to slow progress rather than to none at all.
pub fn backfillDiscovered(self: *Indexer, protocol: models.Protocol, client: *rpc.Client, kind: Kind, addrs: []const Address, to_block: u64, ceils: ?[]const u64, deadline_ms: ?i64) Outcome {
    std.debug.assert(ceils == null or ceils.?.len == addrs.len);
    var outcome: Outcome = .{ .total = addrs.len };
    if (addrs.len == 0) return outcome;
    const started = zsys.milliTimestamp();
    const floor = self.config.start_block;

    if (to_block < floor) {
        for (addrs) |addr| recordOutcome(self, kind, protocol, addr, null);
        outcome.no_history = addrs.len;
        return outcome;
    }

    var probe_calls: usize = 0;
    var probe_batch: usize = PROBE_HTTP_BATCH;
    var probe_cooldowns: u32 = PROBE_COOLDOWN_BUDGET;
    const prober = RpcProber{
        .indexer = self,
        .client = client,
        .calls = &probe_calls,
        .batch = &probe_batch,
        .cooldowns_left = &probe_cooldowns,
    };
    // Split off the contracts whose deployment block is already known; only the
    // rest reach the prober. A fully cached call issues no probes at all.
    var to_probe: std.ArrayList(Address) = .empty;
    defer to_probe.deinit(self.allocator);
    const anchors = self.allocator.alloc(?u64, addrs.len) catch |err| {
        for (addrs) |addr| recordOutcome(self, kind, protocol, addr, err);
        outcome.failed = addrs.len;
        return outcome;
    };
    defer self.allocator.free(anchors);
    for (addrs, anchors) |addr, *slot| {
        if (anchorCacheGet(&self.anchor_cache, addr)) |cached| {
            slot.* = cached;
        } else {
            slot.* = null;
            to_probe.append(self.allocator, addr) catch |err| {
                // Same treatment as the other allocation failures here: leave every
                // target owed in the ledger rather than probe a partial set and
                // mis-scatter the results.
                for (addrs) |a| recordOutcome(self, kind, protocol, a, err);
                outcome.failed = addrs.len;
                return outcome;
            };
        }
    }
    outcome.anchors_cached = addrs.len - to_probe.items.len;

    if (to_probe.items.len > 0) {
        const probed = searchAnchors(self.allocator, prober, to_probe.items, floor, to_block) catch |err| {
            std.log.warn("  Discovery anchor search failed ({}); {d} {s}(s) left for the heal ledger", .{ err, addrs.len, kind.label() });
            for (addrs) |addr| recordOutcome(self, kind, protocol, addr, err);
            outcome.failed = addrs.len;
            return outcome;
        };
        defer self.allocator.free(probed);
        // Scatter the results back onto the slots they came from, in order.
        var pi: usize = 0;
        for (addrs, anchors) |addr, *slot| {
            if (slot.* != null) continue;
            slot.* = probed[pi];
            if (probed[pi]) |a| anchorCachePut(&self.anchor_cache, addr, a);
            pi += 1;
        }
        std.debug.assert(pi == to_probe.items.len);
    }
    outcome.calls += probe_calls;

    var targets: std.ArrayList(Target) = .empty;
    defer targets.deinit(self.allocator);
    for (addrs, anchors, 0..) |addr, anchor, i| {
        if (anchor) |a| {
            if (sweepWindow(a, if (ceils) |cs| cs[i] else 0, to_block)) |ceil| {
                targets.append(self.allocator, .{ .addr = addr, .anchor = a, .ceil = ceil }) catch {
                    recordOutcome(self, kind, protocol, addr, error.OutOfMemory);
                    outcome.failed += 1;
                };
            } else {
                // Nothing owed — same outcome as "no history".
                recordOutcome(self, kind, protocol, addr, null);
                outcome.no_history += 1;
            }
        } else {
            recordOutcome(self, kind, protocol, addr, null);
            outcome.no_history += 1;
        }
    }
    std.mem.sort(Target, targets.items, {}, targetLessThan);
    if (targets.items.len > 0) {
        // Report the ceiling range the sweeps will actually use, not the head:
        // with per-target ceilings these differ by ~100k blocks on a real heal,
        // and the old line made a capped sweep look like a full-history one.
        std.log.info("  Discovery anchors: floor {d}, ceil {d}..{d} (head {d}), {d} target(s) spanning {d}..{d}", .{
            floor,
            targets.items[0].ceil,
            targets.items[targets.items.len - 1].ceil,
            to_block,
            targets.items.len,
            targets.items[0].anchor,
            targets.items[targets.items.len - 1].anchor,
        });
    }

    var start: usize = 0;
    var swept_groups: usize = 0;
    while (start < targets.items.len) {
        // Between groups only, and never before the first one. Stopping mid-group
        // would be the dangerous version: sweepTargets records each member's
        // outcome, so a half-swept group could mark members complete for a range
        // it never read. Guaranteeing one group per cycle rules out the livelock
        // where a budget below one group's cost makes no progress forever.
        if (swept_groups > 0 and deadline_ms != null and zsys.milliTimestamp() >= deadline_ms.?) {
            outcome.deferred = targets.items.len - start;
            std.log.info("  Discovery backfill: time budget reached after {d} group(s); {d} target(s) stay owed for the next cycle", .{ swept_groups, outcome.deferred });
            break;
        }
        const end = @min(start + GROUP_MAX_ADDRESSES, targets.items.len);
        const group = targets.items[start..end];
        // Sorted by ceiling, so the last member's is the group's maximum. Using
        // the max over-sweeps the lower-ceiling members (harmless: those blocks
        // are already indexed and the inserts conflict-ignore) whereas using the
        // min would under-sweep the higher ones, which is a permanent gap.
        sweepTargets(self, protocol, client, kind, group, group[group.len - 1].ceil, &outcome);
        swept_groups += 1;
        start = end;
    }

    std.log.info("Discovery backfill: {d} {s}(s) — {d} without history, {d} swept in {d} group(s), {d} failed, {d} deferred; {d} anchors cached, {d} events, {d} RPC calls, {d}ms", .{
        outcome.total,
        kind.label(),
        outcome.no_history,
        outcome.swept,
        outcome.groups,
        outcome.failed,
        outcome.deferred,
        outcome.anchors_cached,
        outcome.events,
        outcome.calls,
        zsys.milliTimestamp() - started,
    });
    return outcome;
}

/// Sweep one group and record every member's outcome. A provider that rejects
/// the address list (or a group too dense for its response cap even at the
/// minimum block chunk) fails with a non-transport error; the group is then
/// split in half and each half swept on its own, down to single contracts, so
/// a strict provider costs extra calls rather than parking targets.
fn sweepTargets(self: *Indexer, protocol: models.Protocol, client: *rpc.Client, kind: Kind, group: []const Target, to_block: u64, outcome: *Outcome) void {
    if (group.len == 0) return;
    var group_addrs: std.ArrayList(Address) = .empty;
    defer group_addrs.deinit(self.allocator);
    for (group) |t| group_addrs.append(self.allocator, t.addr) catch {};
    if (group_addrs.items.len != group.len) {
        for (group) |t| recordOutcome(self, kind, protocol, t.addr, error.OutOfMemory);
        outcome.failed += group.len;
        return;
    }
    outcome.groups += 1;
    const sweep = sweepGroup(self, protocol, client, kind, group_addrs.items, group[0].anchor, to_block);
    outcome.calls += sweep.calls;
    outcome.events += sweep.events;
    const err = sweep.err orelse {
        for (group) |t| recordOutcome(self, kind, protocol, t.addr, null);
        outcome.swept += group.len;
        return;
    };
    const splittable = group.len > 1 and (err == error.BackfillIncomplete or err == error.RpcError or err == error.RpcRateLimited or err == error.StreamTooLong);
    if (splittable) {
        std.log.warn("  {s} group sweep {d}-{d} rejected for {d} contract(s) ({}); splitting the group", .{ kind.label(), group[0].anchor, to_block, group.len, err });
        const mid = group.len / 2;
        sweepTargets(self, protocol, client, kind, group[0..mid], to_block, outcome);
        sweepTargets(self, protocol, client, kind, group[mid..], to_block, outcome);
        return;
    }
    std.log.warn("  {s} group sweep {d}-{d} failed for {d} contract(s) (queued for retry): {}", .{ kind.label(), group[0].anchor, to_block, group.len, err });
    for (group) |t| recordOutcome(self, kind, protocol, t.addr, err);
    outcome.failed += group.len;
}

const SweepResult = struct {
    calls: usize = 0,
    events: usize = 0,
    err: ?anyerror = null,
};

fn sweepGroup(self: *Indexer, protocol: models.Protocol, client: *rpc.Client, kind: Kind, addrs: []const Address, from_block: u64, to_block: u64) SweepResult {
    var result: SweepResult = .{};
    if (to_block < from_block) return result;

    const resolver_topics_len = Indexer.RESOLVER_EVENTS.len;
    const subregistry_topics_len = Indexer.SUBREGISTRY_ENS_EVENTS.len + 1;
    var topics_buf: [@max(resolver_topics_len, subregistry_topics_len)]Hash = undefined;
    const topics: []const Hash = switch (kind) {
        .resolver => blk: {
            inline for (Indexer.RESOLVER_EVENTS, 0..) |cfg, i| topics_buf[i] = cfg.event_hash;
            break :blk topics_buf[0..resolver_topics_len];
        },
        .subregistry => blk: {
            inline for (Indexer.SUBREGISTRY_ENS_EVENTS, 0..) |cfg, i| topics_buf[i] = cfg.event_hash;
            topics_buf[Indexer.SUBREGISTRY_ENS_EVENTS.len] = Indexer.SUBREGISTRY_TRANSFER_EVENT.event_hash;
            break :blk topics_buf[0..subregistry_topics_len];
        },
    };

    var chunk_from = from_block;
    var chunk_size = startChunk(self, to_block - from_block + 1);
    var transient_failures: u8 = 0;
    var skipped_ranges: usize = 0;

    while (chunk_from <= to_block) {
        var retry_size = @min(chunk_size, to_block - chunk_from + 1);
        const logs = while (retry_size >= SWEEP_MIN_CHUNK or retry_size == to_block - chunk_from + 1) {
            const chunk_to = @min(chunk_from + retry_size - 1, to_block);
            self.rate_limiter.acquire();
            result.calls += 1;
            const fetched = client.getLogsMultiAddress(.{
                .from_block = chunk_from,
                .to_block = chunk_to,
                .addresses = addrs,
                .topic0_or = topics,
            }) catch |err| {
                if (err != error.RpcError and err != error.RpcRateLimited and err != error.StreamTooLong) {
                    transient_failures += 1;
                    if (transient_failures > 3) {
                        result.err = err;
                        return result;
                    }
                    std.log.warn("    Sweep chunk {d}-{d} transport error ({any}); retrying same size (attempt {d}/3)", .{ chunk_from, chunk_to, err, transient_failures });
                    continue;
                }
                if (retry_size < SWEEP_MIN_CHUNK) break null;
                retry_size = @max(retry_size / 2, SWEEP_MIN_CHUNK / 2);
                lowerChunkCeiling(self, retry_size);
                std.log.info("    Sweep chunk {d}-{d} too large ({any}), reducing to {d} blocks", .{ chunk_from, chunk_to, err, retry_size });
                continue;
            };
            transient_failures = 0;
            chunk_size = retry_size;
            break fetched;
        } else null;

        const chunk_logs = logs orelse {
            std.log.warn("    {s} sweep failed at block {d} even with min chunk, skipping ahead", .{ kind.label(), chunk_from });
            skipped_ranges += 1;
            chunk_from += SWEEP_MIN_CHUNK;
            chunk_size = SWEEP_MIN_CHUNK * 2;
            continue;
        };
        defer {
            for (chunk_logs) |*log| log.deinit(self.allocator);
            self.allocator.free(chunk_logs);
        }

        self.warmBlockTimestampCache(protocol, &.{chunk_logs});
        result.events += dispatch(self, protocol, kind, chunk_logs);

        chunk_from += chunk_size;
        chunk_size = growChunk(self, chunk_size);
    }

    if (skipped_ranges > 0) {
        std.log.warn("  {s} sweep incomplete: {d} range(s) skipped", .{ kind.label(), skipped_ranges });
        result.err = error.BackfillIncomplete;
    }
    return result;
}

fn dispatch(self: *Indexer, protocol: models.Protocol, kind: Kind, logs: []const rpc.Log) usize {
    var processed: usize = 0;
    for (logs) |log| {
        if (log.topics.len == 0) continue;
        const sig = log.topics[0];
        switch (kind) {
            .resolver => {
                inline for (Indexer.RESOLVER_EVENTS) |cfg| {
                    if (sig.eql(cfg.event_hash)) {
                        cfg.handler(self, protocol, log.address, log) catch |err| {
                            // Coordinates, not just the event name: without the
                            // block/tx/log_index there is no way to find the
                            // payload that failed. The batch dispatch path
                            // already logs them via skipMalformedEvent.
                            if (utils.isMalformedEventError(err)) {
                                utils.skipMalformedEvent(log, err);
                            } else {
                                std.log.warn("  Backfill handler error ({s}) at block {d} log_index {d}: {}", .{ cfg.name, log.block_number, log.log_index, err });
                            }
                        };
                        processed += 1;
                        break;
                    }
                }
            },
            .subregistry => {
                inline for (Indexer.SUBREGISTRY_ENS_EVENTS) |cfg| {
                    if (sig.eql(cfg.event_hash)) {
                        cfg.handler(self, protocol, log) catch |err| {
                            std.log.warn("  Backfill handler error ({s}): {}", .{ cfg.name, err });
                        };
                        processed += 1;
                        break;
                    }
                }
                if (sig.eql(Indexer.SUBREGISTRY_TRANSFER_EVENT.event_hash)) {
                    Indexer.SUBREGISTRY_TRANSFER_EVENT.handler(self, protocol, log) catch |err| {
                        std.log.warn("  Backfill transfer error: {}", .{err});
                    };
                    processed += 1;
                }
            },
        }
    }
    return processed;
}

fn startChunk(self: *Indexer, remaining: u64) u64 {
    const ceiling = self.backfill_chunk_ceiling;
    return if (ceiling == 0) remaining else @min(ceiling, remaining);
}

fn lowerChunkCeiling(self: *Indexer, size: u64) void {
    const floor = @max(size, SWEEP_MIN_CHUNK);
    if (self.backfill_chunk_ceiling == 0 or self.backfill_chunk_ceiling > floor) self.backfill_chunk_ceiling = floor;
}

fn growChunk(self: *Indexer, size: u64) u64 {
    const ceiling = self.backfill_chunk_ceiling;
    if (ceiling == 0) return size;
    if (size >= ceiling) return ceiling;
    return @min(size + @max(size / 4, SWEEP_MIN_CHUNK), ceiling);
}

/// Ledger recording. `err == null` is success (including "nothing to sweep").
fn recordOutcome(self: *Indexer, kind: Kind, protocol: models.Protocol, addr: Address, err: ?anyerror) void {
    if (protocol != .v2) return;
    var buf: [42]u8 = undefined;
    const hex = addr.toHexBuf(&buf);
    const task = kind.task();
    if (err) |e| {
        const attempts = self.database.recordHealTargetFailure(task, protocol, hex, zsys.timestamp()) catch 0;
        if (attempts >= HEAL_MAX_ATTEMPTS) {
            std.log.err("init-gap heal: {s} target {s} PARKED after {d} failed attempts (last: {}) — its init events stay missing; delete its init_gap_heal_targets row to re-arm", .{ task, hex, attempts, e });
        }
    } else {
        self.database.recordHealTargetSuccess(task, protocol, hex) catch |rec_err| {
            std.log.warn("Failed to record {s} backfill for {s}: {}", .{ task, hex, rec_err });
        };
    }
}

const testing = std.testing;

const FakeProber = struct {
    deployed: []const ?u64,
    addrs: []const Address,
    calls: *usize,
    probes: *usize,
    fail_index: ?usize = null,

    fn probe(self: FakeProber, probes: []const rpc.Client.CodeProbe, out: []?bool) void {
        self.calls.* += 1;
        self.probes.* += probes.len;
        for (probes, 0..) |p, i| {
            var idx: usize = 0;
            while (idx < self.addrs.len) : (idx += 1) {
                if (self.addrs[idx].eql(p.address)) break;
            }
            if (self.fail_index != null and self.fail_index.? == idx) {
                out[i] = null;
                continue;
            }
            out[i] = if (self.deployed[idx]) |d| p.block >= d else false;
        }
    }
};

fn testAddress(n: u8) Address {
    var a: Address = .{ .bytes = [_]u8{0} ** 20 };
    a.bytes[19] = n;
    return a;
}

test "anchor cache round-trips a found deployment block" {
    var cache = AnchorCache.init(testing.allocator);
    defer cache.deinit();
    const a = testAddress(7);
    try testing.expectEqual(@as(?u64, null), anchorCacheGet(&cache, a));
    anchorCachePut(&cache, a, 11_400_001);
    try testing.expectEqual(@as(?u64, 11_400_001), anchorCacheGet(&cache, a));
    // A different address must not read another's anchor.
    try testing.expectEqual(@as(?u64, null), anchorCacheGet(&cache, testAddress(8)));
}

test "anchor cache stops growing at its cap instead of refusing to answer" {
    var cache = AnchorCache.init(testing.allocator);
    defer cache.deinit();
    // Fill to the cap, then prove a further insert is dropped while every existing
    // entry still answers — past the cap the cost is a re-bisection, never a wrong
    // anchor.
    var i: usize = 0;
    while (i < ANCHOR_CACHE_MAX) : (i += 1) {
        var addr = Address{ .bytes = @splat(0) };
        std.mem.writeInt(u64, addr.bytes[0..8], i, .little);
        anchorCachePut(&cache, addr, 1000 + i);
    }
    try testing.expectEqual(ANCHOR_CACHE_MAX, cache.count());
    const overflow = testAddress(200);
    anchorCachePut(&cache, overflow, 999);
    try testing.expectEqual(ANCHOR_CACHE_MAX, cache.count());
    try testing.expectEqual(@as(?u64, null), anchorCacheGet(&cache, overflow));
    var first = Address{ .bytes = @splat(0) };
    std.mem.writeInt(u64, first.bytes[0..8], @as(u64, 0), .little);
    try testing.expectEqual(@as(?u64, 1000), anchorCacheGet(&cache, first));
}

test "searchAnchors finds exact deployment blocks for many contracts in few rounds" {
    const addrs = [_]Address{ testAddress(1), testAddress(2), testAddress(3), testAddress(4), testAddress(5) };
    const deployed = [_]?u64{ 11_400_001, 11_383_818, 11_523_818, null, 11_500_000 };
    var calls: usize = 0;
    var probes: usize = 0;
    const prober = FakeProber{ .deployed = &deployed, .addrs = &addrs, .calls = &calls, .probes = &probes };
    const anchors = try searchAnchors(testing.allocator, prober, &addrs, 11_383_818, 11_523_818);
    defer testing.allocator.free(anchors);
    try testing.expectEqual(@as(?u64, 11_400_001), anchors[0]);
    try testing.expectEqual(@as(?u64, 11_383_818), anchors[1]);
    try testing.expectEqual(@as(?u64, 11_523_818), anchors[2]);
    try testing.expectEqual(@as(?u64, null), anchors[3]);
    try testing.expectEqual(@as(?u64, 11_500_000), anchors[4]);
    // 140k blocks: one probe round for the ends plus log8(140k) ≈ 6 interior rounds
    try testing.expect(calls <= 8);
    // and far fewer probes than 5 contracts × ~17 serial bisection steps
    try testing.expect(probes <= 5 * 7 * 7 + 10);
}

test "searchAnchors degrades a failed contract to the floor and handles a degenerate range" {
    const addrs = [_]Address{ testAddress(1), testAddress(2) };
    const deployed = [_]?u64{ 150, 120 };
    var calls: usize = 0;
    var probes: usize = 0;
    const prober = FakeProber{ .deployed = &deployed, .addrs = &addrs, .calls = &calls, .probes = &probes, .fail_index = 0 };
    const anchors = try searchAnchors(testing.allocator, prober, &addrs, 100, 200);
    defer testing.allocator.free(anchors);
    try testing.expectEqual(@as(?u64, 100), anchors[0]);
    try testing.expectEqual(@as(?u64, 120), anchors[1]);

    const same = try searchAnchors(testing.allocator, prober, &addrs, 200, 200);
    defer testing.allocator.free(same);
    try testing.expectEqual(@as(?u64, 200), same[0]);
    try testing.expectEqual(@as(?u64, 200), same[1]);
}

test "searchAnchors resolves a contract deployed one block after the floor" {
    const addrs = [_]Address{testAddress(9)};
    const deployed = [_]?u64{101};
    var calls: usize = 0;
    var probes: usize = 0;
    const prober = FakeProber{ .deployed = &deployed, .addrs = &addrs, .calls = &calls, .probes = &probes };
    const anchors = try searchAnchors(testing.allocator, prober, &addrs, 100, 1_000_000);
    defer testing.allocator.free(anchors);
    try testing.expectEqual(@as(?u64, 101), anchors[0]);
}

/// Records the batch sizes it is asked for and fails the first `failures`
/// fetches, so the ladder/backoff progression is observable without network.
const StubProber = struct {
    fail_with: anyerror,
    failures: *usize,
    sizes: *std.ArrayList(usize),
    cooldowns: *usize,
    cooldowns_left: *usize,
    allocator: std.mem.Allocator,

    fn fetch(self: StubProber, probes: []const rpc.Client.CodeProbe, out: []?bool) anyerror!void {
        self.sizes.append(self.allocator, probes.len) catch @panic("stub sizes append");
        if (self.failures.* > 0) {
            self.failures.* -= 1;
            return self.fail_with;
        }
        @memset(out, true);
    }

    fn cooldown(self: StubProber) bool {
        if (self.cooldowns_left.* == 0) return false;
        self.cooldowns_left.* -= 1;
        self.cooldowns.* += 1;
        return true;
    }
};

/// A FakeProber that rate-limits its first `fails_left` fetches, driven through
/// the real probeBatched ladder.
const FlakyProber = struct {
    inner: FakeProber,
    fails_left: *usize,
    batch: *usize,
    cooldowns: *usize,

    fn fetch(self: FlakyProber, probes: []const rpc.Client.CodeProbe, out: []?bool) anyerror!void {
        if (self.fails_left.* > 0) {
            self.fails_left.* -= 1;
            return error.RpcRateLimited;
        }
        self.inner.probe(probes, out);
    }

    fn cooldown(self: FlakyProber) bool {
        self.cooldowns.* += 1;
        return true;
    }

    fn probe(self: FlakyProber, probes: []const rpc.Client.CodeProbe, out: []?bool) void {
        self.batch.* = probeBatched(self, probes, out, self.batch.*);
    }
};

const StubRun = struct {
    sizes: std.ArrayList(usize) = .empty,
    failures: usize = 0,
    cooldowns: usize = 0,
    cooldowns_left: usize = 0,
    learned: usize = 0,
    out: [PROBE_HTTP_BATCH]?bool = undefined,

    fn deinit(self: *StubRun) void {
        self.sizes.deinit(testing.allocator);
    }

    fn run(self: *StubRun, fail_with: anyerror) void {
        var probes: [PROBE_HTTP_BATCH]rpc.Client.CodeProbe = undefined;
        for (&probes, 0..) |*p, i| p.* = .{ .address = testAddress(@intCast(i % 200)), .block = 11_708_980 + i };
        const stub = StubProber{
            .fail_with = fail_with,
            .failures = &self.failures,
            .sizes = &self.sizes,
            .cooldowns = &self.cooldowns,
            .cooldowns_left = &self.cooldowns_left,
            .allocator = testing.allocator,
        };
        self.learned = probeBatched(stub, &probes, &self.out, PROBE_HTTP_BATCH);
    }
};

test "nextProbeBatchSize: a rate limit walks the ladder, other rejections shrink once" {
    try testing.expectEqual(@as(?usize, 32), nextProbeBatchSize(PROBE_HTTP_BATCH, true));
    try testing.expectEqual(@as(?usize, 8), nextProbeBatchSize(32, true));
    try testing.expectEqual(@as(?usize, 1), nextProbeBatchSize(8, true));
    try testing.expectEqual(@as(?usize, null), nextProbeBatchSize(1, true));
    // An off-ladder size (provider-capped start) still descends.
    try testing.expectEqual(@as(?usize, 8), nextProbeBatchSize(16, true));
    // Unchanged behaviour for batch-cap / response-size rejections.
    try testing.expectEqual(@as(?usize, 8), nextProbeBatchSize(PROBE_HTTP_BATCH, false));
    try testing.expectEqual(@as(?usize, null), nextProbeBatchSize(8, false));
    try testing.expectEqual(@as(?usize, null), nextProbeBatchSize(1, false));
}

test "anchor probe: a rate limit retries the same batch and keeps its size" {
    var run: StubRun = .{ .failures = 1, .cooldowns_left = 10 };
    defer run.deinit();
    run.run(error.RpcRateLimited);
    try testing.expectEqualSlices(usize, &[_]usize{ PROBE_HTTP_BATCH, PROBE_HTTP_BATCH }, run.sizes.items);
    try testing.expectEqual(@as(usize, 1), run.cooldowns);
    try testing.expectEqual(@as(usize, PROBE_HTTP_BATCH), run.learned);
    for (run.out) |answer| try testing.expectEqual(@as(?bool, true), answer);
}

test "anchor probe: a persistent rate limit shrinks 96-32-8-1 before the floor" {
    var run: StubRun = .{ .failures = std.math.maxInt(usize), .cooldowns_left = 1000 };
    defer run.deinit();
    run.run(error.RpcRateLimited);
    try testing.expectEqualSlices(usize, &[_]usize{ 96, 96, 32, 32, 8, 8, 1, 1 }, run.sizes.items[0..8]);
    try testing.expectEqual(@as(usize, 1), run.learned);
    try testing.expect(run.cooldowns >= 4);
    // Only after the whole ladder is spent does a contract degrade to the floor.
    for (run.out) |answer| try testing.expectEqual(@as(?bool, null), answer);
}

test "anchor probe: a non-rate-limit rejection keeps the single shrink and never waits" {
    var run: StubRun = .{ .failures = std.math.maxInt(usize), .cooldowns_left = 1000 };
    defer run.deinit();
    run.run(error.RpcError);
    try testing.expectEqualSlices(usize, &[_]usize{ 96, 8, 8 }, run.sizes.items[0..3]);
    try testing.expectEqual(@as(usize, PROBE_FALLBACK_BATCH), run.learned);
    try testing.expectEqual(@as(usize, 0), run.cooldowns);
    for (run.out) |answer| try testing.expectEqual(@as(?bool, null), answer);
}

test "anchor probe: an exhausted wait budget degrades to the cheap single shrink" {
    var run: StubRun = .{ .failures = std.math.maxInt(usize), .cooldowns_left = 0 };
    defer run.deinit();
    run.run(error.RpcRateLimited);
    // No waits left, so a throttle costs what a plain rejection costs: one
    // shrink to the fallback size, then the floor — never the whole ladder.
    try testing.expectEqualSlices(usize, &[_]usize{ 96, 8, 8 }, run.sizes.items[0..3]);
    try testing.expectEqual(@as(usize, 0), run.cooldowns);
    try testing.expectEqual(@as(usize, PROBE_FALLBACK_BATCH), run.learned);
}

test "searchAnchors resolves exact anchors despite a rate-limited probe round" {
    const addrs = [_]Address{ testAddress(1), testAddress(2), testAddress(3) };
    const deployed = [_]?u64{ 11_708_990, 11_708_997, null };
    var calls: usize = 0;
    var probe_count: usize = 0;
    var fails_left: usize = 2;
    var batch: usize = PROBE_HTTP_BATCH;
    var cooldowns: usize = 0;
    const flaky = FlakyProber{
        .inner = .{ .deployed = &deployed, .addrs = &addrs, .calls = &calls, .probes = &probe_count },
        .fails_left = &fails_left,
        .batch = &batch,
        .cooldowns = &cooldowns,
    };
    const anchors = try searchAnchors(testing.allocator, flaky, &addrs, 11_708_980, 11_709_000);
    defer testing.allocator.free(anchors);
    try testing.expectEqual(@as(?u64, 11_708_990), anchors[0]);
    try testing.expectEqual(@as(?u64, 11_708_997), anchors[1]);
    try testing.expectEqual(@as(?u64, null), anchors[2]);
    try testing.expect(cooldowns >= 1);
    // The retry answered, so nothing fell back to the floor.
    try testing.expect(anchors[0].? > 11_708_980);
}

test "sweepWindow: an unknown ceiling falls back to the head, never to nothing" {
    // 0 is "the join found no known_* row". It MUST widen to the head, because
    // treating it as a literal ceiling would skip the sweep and leave the init
    // gap permanently unhealed.
    try std.testing.expectEqual(@as(?u64, 11_813_278), sweepWindow(11_700_000, 0, 11_813_278));
    try std.testing.expectEqual(@as(?u64, 500), sweepWindow(500, 0, 500));
}

test "sweepWindow: a known ceiling caps the sweep and is clamped to the head" {
    // The ordinary case: sweep only the pre-discovery window.
    try std.testing.expectEqual(@as(?u64, 11_750_000), sweepWindow(11_708_980, 11_750_000, 11_813_278));
    // Never past the block the indexer has reached, even if first_seen is ahead
    // (possible right after a rollback moved the head backwards).
    try std.testing.expectEqual(@as(?u64, 11_813_278), sweepWindow(11_708_980, 11_900_000, 11_813_278));
}

test "sweepWindow: a ceiling below the anchor owes nothing" {
    // Known at (or before) its own deployment block: no window of unseen events.
    try std.testing.expectEqual(@as(?u64, null), sweepWindow(11_800_000, 11_700_000, 11_813_278));
    // Boundary: equal is a one-block window and IS owed.
    try std.testing.expectEqual(@as(?u64, 11_800_000), sweepWindow(11_800_000, 11_800_000, 11_813_278));
    // A head behind the anchor also owes nothing.
    try std.testing.expectEqual(@as(?u64, null), sweepWindow(11_800_000, 0, 11_700_000));
}

test "targetLessThan groups by ceiling first so a group sweeps to its own max" {
    var ts = [_]Target{
        .{ .addr = testAddress(1), .anchor = 100, .ceil = 900 },
        .{ .addr = testAddress(2), .anchor = 500, .ceil = 200 },
        .{ .addr = testAddress(3), .anchor = 300, .ceil = 200 },
    };
    std.mem.sort(Target, &ts, {}, targetLessThan);
    // Ceiling ascending, anchor breaking ties.
    try std.testing.expectEqual(@as(u64, 200), ts[0].ceil);
    try std.testing.expectEqual(@as(u64, 300), ts[0].anchor);
    try std.testing.expectEqual(@as(u64, 200), ts[1].ceil);
    try std.testing.expectEqual(@as(u64, 500), ts[1].anchor);
    try std.testing.expectEqual(@as(u64, 900), ts[2].ceil);
    // The last member's ceiling is the group maximum, which is what the group
    // loop sweeps to — using the minimum would under-sweep the others.
    try std.testing.expectEqual(@as(u64, 900), ts[ts.len - 1].ceil);
}
