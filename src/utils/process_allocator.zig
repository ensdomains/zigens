//! Process-wide allocator selection for the long-running binaries, plus
//! truthful live-byte accounting for the per-batch memory line.
//!
//! ## Why this module exists
//!
//! `std.heap.DebugAllocator` is a *debugging* allocator and must not back a
//! long-running process. Small allocations are served from 128 KiB mmap'd
//! "buckets", each subdivided into fixed size-class slots, and a bucket is
//! returned to the OS only once every slot ever handed out from it has been
//! freed (`freed_count == allocated_count`). A single surviving slot pins the
//! whole 128 KiB.
//!
//! The indexer's allocation shape defeats that completely. Every batch bursts
//! ~10^5 short-lived small allocations — the `eth_getLogs` JSON DOM: one
//! string per address/topic/data field plus the hash-map arrays behind each
//! log object — interleaved with a steadily growing set of long-lived ones
//! (known-resolver and account-observation cache keys, write-buffer entries,
//! the placeholder ledger). The survivors scatter thinly across an
//! ever-growing number of buckets, each pinning its full 128 KiB, so RSS
//! climbs linearly per batch with no leak anywhere.
//!
//! Worse, the figure that would have exposed it lied. `total_requested_bytes`
//! counts *requested* bytes, never the pinned bucket pages, so the per-batch
//! "allocator live" line stayed in single-digit MB while RSS approached the
//! host limit — reading exactly like a healthy process until the OS refused a
//! mapping and `error.OutOfMemory` aborted the batch.
//!
//! Measured at the indexer's allocation shape on a 4 GB host, 120k
//! allocations per batch with 1-in-400 surviving:
//!
//! | allocator            | batch 0 | batch 100        | outcome        |
//! |----------------------|---------|------------------|----------------|
//! | DebugAllocator       |   29 MB | 2,102 MB (186x)  | OOM-killed     |
//! | libc malloc (musl)   |   69 MB |    88 MB         | flat           |
//! | smp_allocator        |   56 MB |    71 MB         | flat           |
//!
//! Measured under musl specifically: the production image is Alpine, and a
//! glibc result would not have transferred.
//!
//! libc malloc is the default here because libc is already linked into every
//! one of these executables for sqlite3, so Zig and SQLite share one arena
//! instead of two heaps that each retain freed memory independently.
//! `DebugAllocator` stays reachable via `ALLOCATOR=debug` for leak hunting,
//! where a bounded run is the whole point and its accounting is what you want.
const std = @import("std");
const zsys = @import("system.zig");
const memstat = @import("memstat.zig");

pub const Kind = enum {
    libc,
    debug,

    pub fn toString(self: Kind) []const u8 {
        return switch (self) {
            .libc => "libc",
            .debug => "debug",
        };
    }
};

/// `ALLOCATOR=debug` opts into `DebugAllocator` (leak reports, double-free
/// detection) for a bounded diagnostic run. Anything else — including unset —
/// selects libc malloc, so production cannot accidentally inherit the
/// debugging allocator.
pub fn kindFromEnv() Kind {
    const raw = zsys.getenv("ALLOCATOR") orelse return .libc;
    if (std.ascii.eqlIgnoreCase(raw, "debug") or std.ascii.eqlIgnoreCase(raw, "gpa")) return .debug;
    return .libc;
}

/// Live-byte accounting that does not depend on the backing allocator's
/// internals. RSS-versus-live is the one comparison that separates a leak
/// (both climb together) from allocator retention (RSS climbs alone), so the
/// per-batch memory line needs a live figure that stays true whichever
/// allocator is selected — musl has no `mallinfo2`, and
/// `total_requested_bytes` exists only on `DebugAllocator`.
///
/// Two relaxed atomic updates per operation; `alloc` already costs far more.
pub const Counting = struct {
    backing: std.mem.Allocator,
    live: std.atomic.Value(usize) = .init(0),
    peak: std.atomic.Value(usize) = .init(0),
    reported: std.atomic.Value(bool) = .init(false),
    largest_reported: std.atomic.Value(usize) = .init(0),
    refusals: std.atomic.Value(usize) = .init(0),
    /// Tests set this false to drive the refusal path without logging.
    report_refusals: bool = true,

    pub fn init(backing: std.mem.Allocator) Counting {
        return .{ .backing = backing };
    }

    pub fn allocator(self: *Counting) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    /// Nothing in these processes legitimately needs a single allocation this
    /// large. The biggest honest ones are an RPC response body (capped at
    /// 50 MB) and a hash table doubling at its 4M-entry ceiling (~200 MB), so a
    /// request past this threshold means a length came from somewhere it should
    /// not have — a wire-declared message size, a decoded payload length, a
    /// result set materialised whole.
    ///
    /// This threshold only *reports*; `max_single` below is the one that
    /// refuses. Two levels because they answer different questions: a request
    /// between them is suspicious but survivable and worth naming — especially
    /// when it SUCCEEDS, which is invisible today and is what grows into the
    /// ceiling on a bigger host — while one past `max_single` cannot be
    /// legitimate at all.
    pub const LARGE_ALLOC_WARN_BYTES: usize = 256 * 1024 * 1024;

    /// Hard ceiling on a SINGLE allocation. Set from `MAX_SINGLE_ALLOC_MB`
    /// (0 disables) by `init`.
    ///
    /// This is a sanity invariant, not a memory budget: the largest honest
    /// single allocation in these processes is a 50 MB RPC body, so a request
    /// past a gigabyte is always a length that escaped validation. The known
    /// live example is the Postgres driver, which reads a `u32` message length
    /// off the wire and hands it straight to `alloc`/`realloc` — up to 4 GiB+1,
    /// with no bound and `error.OutOfMemory` as its only failure mode. A
    /// desynced or corrupt length there asks for gigabytes at once.
    ///
    /// Refusing costs nothing, because such a request already fails on a host
    /// this size — it just fails namelessly, and on a *larger* host it would
    /// instead succeed and balloon RSS. Refusing makes the outcome identical
    /// everywhere and logged. It does not repair the driver's missing bound;
    /// that belongs upstream. It stops one bad length from being
    /// indistinguishable from genuine exhaustion.
    var max_single: std.atomic.Value(usize) = .init(0);

    /// Pure predicate — no logging, so it is testable without tripping the
    /// test runner's logged-error count. Zero means the guard is off.
    fn exceedsSingleCap(n: usize) bool {
        const cap = max_single.load(.monotonic);
        return cap != 0 and n > cap;
    }

    /// Unlike `reportFailure` this is not rate-limited: a refusal the log never
    /// mentions is worse than no guard at all. `report_refusals` exists so a
    /// test can drive the refusal path without emitting an error.
    fn reportRefusal(self: *Counting, n: usize, ret_addr: usize) void {
        _ = self.refusals.fetchAdd(1, .monotonic);
        if (!self.report_refusals) return;
        // maxInt(usize) exactly is worth calling out by name: it is the "clamp on
        // u256 overflow" sentinel that decoders use (readUint256AsUsize and
        // friends), so seeing it means a 32-byte word of 0xff reached a length
        // without being range-checked — a different bug from merely asking for
        // too much.
        // Advice has to differ by case. maxInt(usize) exactly is the sentinel a
        // decoder returns when a 32-byte word overflows a usize, so raising the
        // ceiling would only let a corrupt length through to fail as a real OOM,
        // and disabling the guard restores the opaque stall it exists to name.
        const advice = if (n == std.math.maxInt(usize))
            " This is exactly maxInt(usize) — the sentinel a decoder returns when a 32-byte word overflows a usize, i.e. an unchecked wire-declared length, NOT a large-but-real request. Do NOT raise MAX_SINGLE_ALLOC_MB for this: the fix belongs at the decode site."
        else
            " Raise MAX_SINGLE_ALLOC_MB, or set it to 0 to disable, if this request is genuine.";
        std.log.err("REFUSED a single allocation of {d} bytes ({d} MB), over the {d} MB sanity ceiling.{s}", .{ n, n / (1024 * 1024), max_single.load(.monotonic) / (1024 * 1024), advice });
        // The call site is the whole answer and ret_addr is already in hand;
        // without it a refusal only says "somewhere". Unwinding is best-effort:
        // a stripped build simply prints less.
        std.debug.dumpCurrentStackTrace(.{ .first_address = ret_addr });
    }

    /// Only reports a size larger than any already reported, so a repeating
    /// allocation logs once rather than every batch.
    fn noteLarge(self: *Counting, n: usize) void {
        if (n < LARGE_ALLOC_WARN_BYTES) return;
        if (n <= self.largest_reported.load(.monotonic)) return;
        self.largest_reported.store(n, .monotonic);
        std.log.warn("single allocation of {d} MB (live {d} MB) — larger than any legitimate one in this process; a length is coming from untrusted input", .{
            n / (1024 * 1024),
            self.live.load(.monotonic) / (1024 * 1024),
        });
    }

    fn add(self: *Counting, n: usize) void {
        self.noteLarge(n);
        const now = self.live.fetchAdd(n, .monotonic) + n;
        // Racy against a concurrent max, which only ever understates the peak
        // by one in-flight allocation — not worth a CAS loop on this path.
        if (now > self.peak.load(.monotonic)) self.peak.store(now, .monotonic);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        if (exceedsSingleCap(len)) {
            self.reportRefusal(len, ret_addr);
            return null;
        }
        const p = self.backing.rawAlloc(len, alignment, ret_addr) orelse {
            self.reportFailure(len);
            return null;
        };
        self.add(len);
        return p;
    }

    /// `error.OutOfMemory` on its own is close to undiagnosable: it says
    /// nothing about whether the process had grown large or a single request
    /// was absurd, and those have opposite fixes. One request for more than
    /// the machine has — a length decoded from a malformed payload, a result
    /// set materialised whole — fails instantly while RSS sits at its normal
    /// level and the host still shows memory free, which reads like a phantom.
    /// So name the request: its size next to live/peak/RSS separates "we grew
    /// into the ceiling" from "something asked for 3 GB at once".
    ///
    /// Rate-limited to one report per process so a failing loop cannot flood
    /// the log, and deliberately allocation-free on this path.
    fn reportFailure(self: *Counting, len: usize) void {
        if (self.reported.swap(true, .monotonic)) return;
        const memstat_mod = @import("memstat.zig");
        std.log.err(
            "allocation of {d} bytes ({d} MB) FAILED: live {d} MB, peak {d} MB, rss {d} MB. " ++
                "A request far larger than live+rss indicates one oversized allocation, " ++
                "not gradual growth.",
            .{
                len,
                len / (1024 * 1024),
                self.live.load(.monotonic) / (1024 * 1024),
                self.peak.load(.monotonic) / (1024 * 1024),
                (memstat_mod.rssBytes() orelse 0) / (1024 * 1024),
            },
        );
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        // A grow in place commits memory without ever reaching `alloc`, so the
        // ceiling has to be checked here too or it is bypassed by one realloc.
        if (new_len > memory.len and exceedsSingleCap(new_len)) {
            self.reportRefusal(new_len, ret_addr);
            return false;
        }
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        if (new_len >= memory.len) {
            self.add(new_len - memory.len);
        } else {
            _ = self.live.fetchSub(memory.len - new_len, .monotonic);
        }
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and exceedsSingleCap(new_len)) {
            self.reportRefusal(new_len, ret_addr);
            return null;
        }
        // No failure report here: `Allocator.realloc` probes `rawRemap` first
        // and falls back to alloc+copy when it declines, so null is ordinary
        // control flow rather than an allocation failure. The fallback's
        // `rawAlloc` is where a real one surfaces.
        const p = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        if (new_len >= memory.len) {
            self.add(new_len - memory.len);
        } else {
            _ = self.live.fetchSub(memory.len - new_len, .monotonic);
        }
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
        _ = self.live.fetchSub(memory.len, .monotonic);
    }
};

const DebugGpa = std.heap.DebugAllocator(.{ .thread_safe = true, .enable_memory_limit = true });

// Singleton process state. `smp_allocator` is a documented singleton and
// `DebugAllocator` must outlive every allocation made through it, so both
// belong at file scope rather than in a caller's stack frame.
var debug_gpa: DebugGpa = .init;
var counting: Counting = undefined;
var selected_kind: Kind = .libc;
var initialized = false;

/// Select the process allocator, wire up the memory line, and return the
/// allocator every subsystem should use. Call once, from `main`.
pub fn init() std.mem.Allocator {
    std.debug.assert(!initialized);
    selected_kind = kindFromEnv();
    const backing: std.mem.Allocator = switch (selected_kind) {
        .libc => std.heap.c_allocator,
        .debug => debug_gpa.allocator(),
    };
    counting = Counting.init(backing);
    // Generous by design: well above every legitimate allocation, low enough
    // that a corrupt length is refused rather than attempted.
    const cap_mb = std.fmt.parseInt(usize, zsys.getenv("MAX_SINGLE_ALLOC_MB") orelse "1024", 10) catch 1024;
    Counting.max_single.store(cap_mb * 1024 * 1024, .monotonic);
    initialized = true;
    memstat.live_bytes_fn = &liveBytes;
    memstat.peak_bytes_fn = &peakBytes;
    return counting.allocator();
}

/// Tear down. Returns true when the selected allocator detected leaks, which
/// only `DebugAllocator` can do — `ALLOCATOR=debug` is how you ask.
pub fn deinit() bool {
    if (!initialized) return false;
    initialized = false;
    memstat.live_bytes_fn = null;
    memstat.peak_bytes_fn = null;
    return switch (selected_kind) {
        .libc => false,
        .debug => debug_gpa.deinit() == .leak,
    };
}

pub fn liveBytes() usize {
    if (!initialized) return 0;
    return counting.live.load(.monotonic);
}

/// How many allocations the sanity ceiling has refused. A caller comparing this
/// across an operation can tell a poison length (refused) from genuine memory
/// pressure (the backing allocator said no) — the two need opposite recoveries.
pub fn refusalCount() usize {
    if (!initialized) return 0;
    return counting.refusals.load(.monotonic);
}

pub fn peakBytes() usize {
    if (!initialized) return 0;
    return counting.peak.load(.monotonic);
}

pub fn kind() Kind {
    return selected_kind;
}

test "counting allocator tracks live and peak bytes" {
    var c = Counting.init(std.testing.allocator);
    const a = c.allocator();

    const first = try a.alloc(u8, 1024);
    try std.testing.expectEqual(@as(usize, 1024), c.live.load(.monotonic));

    const second = try a.alloc(u8, 2048);
    try std.testing.expectEqual(@as(usize, 3072), c.live.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 3072), c.peak.load(.monotonic));

    a.free(second);
    try std.testing.expectEqual(@as(usize, 1024), c.live.load(.monotonic));
    // Peak is a high-water mark, so freeing must not lower it.
    try std.testing.expectEqual(@as(usize, 3072), c.peak.load(.monotonic));

    a.free(first);
    try std.testing.expectEqual(@as(usize, 0), c.live.load(.monotonic));
}

test "counting allocator follows shrinking and growing reallocations" {
    var c = Counting.init(std.testing.allocator);
    const a = c.allocator();

    var buf = try a.alloc(u8, 64);
    try std.testing.expectEqual(@as(usize, 64), c.live.load(.monotonic));

    buf = try a.realloc(buf, 4096);
    try std.testing.expectEqual(@as(usize, 4096), c.live.load(.monotonic));

    buf = try a.realloc(buf, 32);
    try std.testing.expectEqual(@as(usize, 32), c.live.load(.monotonic));

    a.free(buf);
    try std.testing.expectEqual(@as(usize, 0), c.live.load(.monotonic));
    // At least the largest buffer, and possibly more: growing may hold the old
    // and new allocations at once, which a high-water mark should include.
    try std.testing.expect(c.peak.load(.monotonic) >= 4096);
}

test "the oversized-allocation ceiling refuses only past the cap, and is off at zero" {
    const prev = Counting.max_single.load(.monotonic);
    defer Counting.max_single.store(prev, .monotonic);

    Counting.max_single.store(1024 * 1024, .monotonic);
    try std.testing.expect(!Counting.exceedsSingleCap(1024));
    try std.testing.expect(!Counting.exceedsSingleCap(1024 * 1024));
    try std.testing.expect(Counting.exceedsSingleCap(1024 * 1024 + 1));

    // Zero disables the guard entirely, including for absurd sizes.
    Counting.max_single.store(0, .monotonic);
    try std.testing.expect(!Counting.exceedsSingleCap(std.math.maxInt(usize)));
}

test "a refused allocation surfaces as OutOfMemory rather than a partial success" {
    var c = Counting.init(std.testing.allocator);
    c.report_refusals = false;
    const a = c.allocator();
    const prev = Counting.max_single.load(.monotonic);
    defer Counting.max_single.store(prev, .monotonic);
    Counting.max_single.store(4096, .monotonic);

    // Under the ceiling still works, and is still accounted for.
    const ok = try a.alloc(u8, 2048);
    try std.testing.expectEqual(@as(usize, 2048), c.live.load(.monotonic));
    a.free(ok);

    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 8192));
    // A refusal must not move the accounting.
    try std.testing.expectEqual(@as(usize, 0), c.live.load(.monotonic));

    // The ceiling must also hold on the realloc paths: a grow commits memory
    // without passing through `alloc`, so guarding `alloc` alone would let one
    // realloc walk straight past it.
    const grown = try a.alloc(u8, 2048);
    try std.testing.expectError(error.OutOfMemory, a.realloc(grown, 1024 * 1024));
    try std.testing.expectEqual(@as(usize, 2048), c.live.load(.monotonic));
    a.free(grown);
    try std.testing.expectEqual(@as(usize, 0), c.live.load(.monotonic));
}

test "unset and unrecognised ALLOCATOR never select the debugging allocator" {
    // Production must not be able to inherit DebugAllocator by accident; only
    // an explicit opt-in selects it.
    try std.testing.expectEqual(Kind.libc, kindFromEnv());
}
