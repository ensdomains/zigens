//! Minimal test runner for the conformance lane (build.zig wires it via
//! `.test_runner = .{ .path = ..., .mode = .simple }`).
//!
//! Why a custom runner: the error-shape ops intentionally send invalid GraphQL
//! queries, which the handler logs at warn/err. Zig's DEFAULT test runner counts any
//! warn/err log and fails the test regardless of log level, which would make the
//! error-envelope goldens un-testable. This runner is the ROOT of the test binary, so
//! its quiet `logFn` is honored — those expected logs are dropped while the golden
//! assertions still run. Leak detection is preserved (per-test allocator_instance
//! reset + deinit), so CONFORMANCE_LEAKCHECK=1 still catches leaks.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

pub const std_options: std.Options = .{ .logFn = quietLog };
fn quietLog(comptime _: std.log.Level, comptime _: @EnumLiteral(), comptime _: []const u8, _: anytype) void {}

pub fn main(init: std.process.Init.Minimal) void {
    var failed: usize = 0;
    for (builtin.test_functions) |t| {
        // Same per-test wiring as lib/compiler/test_runner.zig: tests reach the io
        // handle via std.testing.io, which reads testing.io_instance.
        testing.environ = init.environ;
        testing.allocator_instance = .{};
        testing.io_instance = .init(testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        const result = t.func();
        testing.io_instance.deinit();
        const leaked = testing.allocator_instance.deinit() == .leak;
        if (result) |_| {
            if (leaked) {
                std.debug.print("LEAK: {s}\n", .{t.name});
                failed += 1;
            } else {
                std.debug.print("ok: {s}\n", .{t.name});
            }
        } else |err| {
            std.debug.print("FAIL: {s}: {}\n", .{ t.name, err });
            failed += 1;
        }
    }
    if (failed != 0) {
        std.debug.print("conformance: {d} test(s) failed\n", .{failed});
        std.process.exit(1);
    }
    std.debug.print("conformance: all tests passed\n", .{});
}
