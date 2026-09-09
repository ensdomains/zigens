//! Process memory instrumentation for the per-batch progress line: resident
//! size from /proc/self/statm next to the allocator's live bytes, so growth
//! can be attributed to Zig-owned structures or to memory outside the GPA.
const std = @import("std");
const zsys = @import("system.zig");

/// Installed by the executable's main: returns the GPA's currently requested bytes.
pub var live_bytes_fn: ?*const fn () usize = null;

pub fn rssBytes() ?usize {
    var backing: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    const content = zsys.readFileAlloc(fba.allocator(), "/proc/self/statm", 256) catch return null;
    var it = std.mem.splitScalar(u8, content, ' ');
    _ = it.next() orelse return null;
    const resident = it.next() orelse return null;
    const pages = std.fmt.parseInt(usize, resident, 10) catch return null;
    return pages * std.heap.pageSize();
}

pub fn liveBytes() ?usize {
    const f = live_bytes_fn orelse return null;
    return f();
}
