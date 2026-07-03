//! Root for the resolution-layer test lane (`zig build test-resolve`).
//!
//! Rooted at `src/` level (not inside `src/resolve/`) so the module boundary is
//! the whole `src/` tree — the resolution modules import sibling packages
//! (`../storage`, `../rpc`, `../types`) that would otherwise escape a narrower
//! module root. The tests themselves live next to the code they exercise; the
//! imports below pull their `test` blocks into this compile.

const std = @import("std");

test {
    _ = @import("resolve/cache.zig");
    _ = @import("resolve/client.zig");
    _ = @import("resolve/primary.zig");
    _ = @import("resolve/universal.zig");
    _ = @import("resolve/ccip.zig");
    _ = @import("resolve/ccip_transport.zig");
}
