//! Tests for the contract-manifest loader (Task 08). Kept in a SEPARATE file (not inline
//! in manifest.zig) because config.zig imports manifest.zig, so inline tests would be
//! pulled into every lane that compiles config — and the validation tests deliberately
//! std.log.err on the fail-fast paths, which the default test runner counts as failures.
//! This file is the root of the `test-manifest` lane, which uses the quiet runner and
//! setCwd(.) so it can read the committed manifests/ reference files.
//!
//! Run `MANIFEST_GEN=1 zig build test-manifest` to (re)generate the reference manifests
//! from the current code defaults; the drift test then asserts they load back to those
//! exact defaults.

const std = @import("std");
const testing = std.testing;
const manifest = @import("manifest.zig");
const contracts = @import("contracts.zig");
const Network = contracts.Network;
const ContractAddresses = contracts.ContractAddresses;

fn expectEqualContracts(code: ContractAddresses, loaded: ContractAddresses) !void {
    inline for (@typeInfo(ContractAddresses).@"struct".fields) |f| {
        try testing.expectEqual(@field(code, f.name), @field(loaded, f.name));
    }
}

test "reference manifests load to the code defaults (and regen with MANIFEST_GEN=1)" {
    const a = testing.allocator;
    const gen = std.process.hasEnvVarConstant("MANIFEST_GEN");
    const nets = [_]struct { net: Network, path: []const u8 }{
        .{ .net = .sepolia, .path = "manifests/sepolia.zon" },
        .{ .net = .mainnet, .path = "manifests/mainnet.zon" },
    };
    for (nets) |n| {
        const code = try contracts.getContractAddresses(n.net);
        if (gen) {
            std.fs.cwd().makePath("manifests") catch {};
            var buf: std.ArrayList(u8) = .{};
            defer buf.deinit(a);
            try manifest.serialize(buf.writer(a), code, n.net);
            const f = try std.fs.cwd().createFile(n.path, .{});
            defer f.close();
            try f.writeAll(buf.items);
            std.debug.print("generated {s}\n", .{n.path});
            continue;
        }
        const loaded = try manifest.loadManifest(a, n.path, n.net);
        try expectEqualContracts(code, loaded);
    }
}

const Address = @import("types/address.zig").Address;
const ZERO_ADDR = "0x0000000000000000000000000000000000000000";
const A_REAL = "0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e";

/// Every ContractAddresses Address field, declared with the zero address — the minimal
/// COMPLETE manifest that passes the required-present check. Tests mutate copies of it.
const all_present: []const manifest.Contract = blk: {
    var arr: []const manifest.Contract = &.{};
    for (@typeInfo(ContractAddresses).@"struct".fields) |f| {
        if (f.type == Address) arr = arr ++ &[_]manifest.Contract{.{ .name = f.name, .address = ZERO_ADDR }};
    }
    break :blk arr;
};

fn withContracts(contracts_slice: []const manifest.Contract) manifest.Manifest {
    return .{
        .manifest_version = 1,
        .chain_id = Network.sepolia.chainId(),
        .contracts = contracts_slice,
        .blocks = std.mem.zeroes(manifest.Blocks),
    };
}

test "manifest validation fails fast on bad/wrong/unknown/missing/duplicate contracts" {
    // A complete, all-zero manifest is valid.
    _ = try manifest.toContractAddresses(withContracts(all_present), .sepolia);

    // Wrong chain_id for the target network (checked first).
    try testing.expectError(manifest.Error.ManifestChainMismatch, manifest.toContractAddresses(withContracts(all_present), .mainnet));

    // Unknown contract name (errors during the loop, before the required-present check).
    try testing.expectError(manifest.Error.ManifestUnknownContract, manifest.toContractAddresses(withContracts(&.{.{ .name = "not_a_contract", .address = A_REAL }}), .sepolia));

    // Malformed address on a present, active contract.
    try testing.expectError(manifest.Error.ManifestBadAddress, manifest.toContractAddresses(withContracts(&.{.{ .name = "ens_registry", .address = "0xnothex" }}), .sepolia));

    // OMITTING a contract fails fast (the spec's cardinal rule): drop the last entry.
    try testing.expectError(manifest.Error.ManifestMissingContract, manifest.toContractAddresses(withContracts(all_present[0 .. all_present.len - 1]), .sepolia));

    // DUPLICATE contract name fails fast.
    var dup: [all_present.len + 1]manifest.Contract = undefined;
    @memcpy(dup[0..all_present.len], all_present);
    dup[all_present.len] = all_present[0];
    try testing.expectError(manifest.Error.ManifestDuplicateContract, manifest.toContractAddresses(withContracts(&dup), .sepolia));

    // A present-but-.disabled contract keeps the zero address even with a real one supplied.
    var dis: [all_present.len]manifest.Contract = all_present[0..all_present.len].*;
    for (&dis) |*c| {
        if (std.mem.eql(u8, c.name, "ens_registry")) c.* = .{ .name = "ens_registry", .address = A_REAL, .status = .disabled };
    }
    const ca = try manifest.toContractAddresses(withContracts(&dis), .sepolia);
    try testing.expect(ca.ens_registry.isZero());
}
