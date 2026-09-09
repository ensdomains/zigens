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
/// eth_getCode probes per HTTP request, and the size retried when a provider
/// rejects a full batch.
const PROBE_HTTP_BATCH: usize = 96;
const PROBE_FALLBACK_BATCH: usize = 8;
/// Contracts per multi-address eth_getLogs request.
const GROUP_MAX_ADDRESSES: usize = 100;
const SWEEP_MIN_CHUNK: u64 = 500;

pub const Outcome = struct {
    total: usize = 0,
    no_history: usize = 0,
    swept: usize = 0,
    failed: usize = 0,
    groups: usize = 0,
    calls: usize = 0,
    events: usize = 0,
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

const RpcProber = struct {
    indexer: *Indexer,
    client: *rpc.Client,
    calls: *usize,

    /// Provider rejected a full-size batch (batch cap, size limit): retry the
    /// same probes in small batches so one strict provider costs a few extra
    /// round trips instead of collapsing every anchor to the floor.
    fn probeSmall(self: RpcProber, probes: []const rpc.Client.CodeProbe, out: []?bool) void {
        var start: usize = 0;
        while (start < probes.len) : (start += PROBE_FALLBACK_BATCH) {
            const end = @min(start + PROBE_FALLBACK_BATCH, probes.len);
            self.indexer.rate_limiter.acquire();
            self.calls.* += 1;
            const answers = self.client.getCodeBatch(probes[start..end]) catch |err| {
                std.log.warn("  Discovery anchor probe batch failed ({}); {d} contract(s) fall back to the configured floor", .{ err, end - start });
                @memset(out[start..end], null);
                continue;
            };
            defer self.client.allocator.free(answers);
            @memcpy(out[start..end], answers);
        }
    }

    fn probe(self: RpcProber, probes: []const rpc.Client.CodeProbe, out: []?bool) void {
        var start: usize = 0;
        while (start < probes.len) : (start += PROBE_HTTP_BATCH) {
            const end = @min(start + PROBE_HTTP_BATCH, probes.len);
            self.indexer.rate_limiter.acquire();
            self.calls.* += 1;
            if (self.client.getCodeBatch(probes[start..end])) |answers| {
                defer self.client.allocator.free(answers);
                @memcpy(out[start..end], answers);
            } else |err| {
                std.log.warn("  Discovery anchor probe batch of {d} failed ({}); retrying in batches of {d}", .{ end - start, err, PROBE_FALLBACK_BATCH });
                self.probeSmall(probes[start..end], out[start..end]);
            }
        }
    }
};

const Target = struct {
    addr: Address,
    anchor: u64,
};

fn targetLessThan(_: void, a: Target, b: Target) bool {
    return a.anchor < b.anchor;
}

/// Sweep every contract in `addrs` from its deployment block to `to_block`
/// and record each one's outcome in the init-gap heal ledger (v2 only, the
/// ledger's authoritative protocol). Never fails: a failed group is logged
/// and its targets stay owed in the ledger.
pub fn backfillDiscovered(self: *Indexer, protocol: models.Protocol, client: *rpc.Client, kind: Kind, addrs: []const Address, to_block: u64) Outcome {
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
    const prober = RpcProber{ .indexer = self, .client = client, .calls = &probe_calls };
    const anchors = searchAnchors(self.allocator, prober, addrs, floor, to_block) catch |err| {
        std.log.warn("  Discovery anchor search failed ({}); {d} {s}(s) left for the heal ledger", .{ err, addrs.len, kind.label() });
        for (addrs) |addr| recordOutcome(self, kind, protocol, addr, err);
        outcome.failed = addrs.len;
        return outcome;
    };
    defer self.allocator.free(anchors);
    outcome.calls += probe_calls;

    var targets: std.ArrayList(Target) = .empty;
    defer targets.deinit(self.allocator);
    for (addrs, anchors) |addr, anchor| {
        if (anchor) |a| {
            targets.append(self.allocator, .{ .addr = addr, .anchor = a }) catch {
                recordOutcome(self, kind, protocol, addr, error.OutOfMemory);
                outcome.failed += 1;
            };
        } else {
            recordOutcome(self, kind, protocol, addr, null);
            outcome.no_history += 1;
        }
    }
    std.mem.sort(Target, targets.items, {}, targetLessThan);
    if (targets.items.len > 0) {
        std.log.info("  Discovery anchors: floor {d}, ceil {d}, {d} target(s) spanning {d}..{d}", .{ floor, to_block, targets.items.len, targets.items[0].anchor, targets.items[targets.items.len - 1].anchor });
    }

    var start: usize = 0;
    while (start < targets.items.len) {
        const end = @min(start + GROUP_MAX_ADDRESSES, targets.items.len);
        sweepTargets(self, protocol, client, kind, targets.items[start..end], to_block, &outcome);
        start = end;
    }

    std.log.info("Discovery backfill: {d} {s}(s) — {d} without history, {d} swept in {d} group(s), {d} failed; {d} events, {d} RPC calls, {d}ms", .{
        outcome.total,
        kind.label(),
        outcome.no_history,
        outcome.swept,
        outcome.groups,
        outcome.failed,
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
    const splittable = group.len > 1 and (err == error.BackfillIncomplete or err == error.RpcError or err == error.StreamTooLong);
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
                if (err != error.RpcError and err != error.StreamTooLong) {
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
                            std.log.warn("  Backfill handler error ({s}): {}", .{ cfg.name, err });
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
