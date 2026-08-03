//! Manifest-driven contract configuration (Task 08): config-as-data.
//!
//! Contract addresses + deployment blocks can be supplied by a versioned `.zon` manifest
//! (path via MANIFEST_PATH) instead of the hardcoded `contracts.getContractAddresses`
//! switch, so a redeployment or proxy change is a config edit, not a recompile. When
//! MANIFEST_PATH is empty the code switch is used unchanged (100% backward compatible).
//!
//! Format (see manifests/README.txt + the committed reference manifests): a `.zon` with a
//! `manifest_version`, a `chain_id` (must match NETWORK), an array of `.contracts` (each
//! `{ name, address, status?, start_block? }`), and a `.blocks` object. A contract's
//! `name` must be a known `ContractAddresses` address field; `status = .disabled` (or the
//! zero address) leaves that address zero, which the indexer already skips.
//!
//! Fail-fast (never a silent mis-index): a bad address, a wrong chain_id, an unknown or
//! DUPLICATE contract name, or an OMITTED contract is a startup error. Every contract must
//! be explicitly declared (zero address if not deployed) so a dropped line can't silently
//! remove a contract from the indexed set.

const std = @import("std");
const zsys = @import("utils/system.zig");
const contracts = @import("contracts.zig");
const Address = @import("types/address.zig").Address;

const ContractAddresses = contracts.ContractAddresses;
const Network = contracts.Network;

pub const Status = enum { active, disabled };

pub const Contract = struct {
    name: []const u8,
    address: []const u8,
    /// active is indexed; disabled leaves the address zero (the indexer's isActiveContract
    /// guard then skips it). (A 'shadow' status was removed: ENS V2 migration is parent-first —
    /// MigrationHelper reverts ParentNotMigrated — so shadow/placeholder parents never occur.)
    status: Status = .active,
    /// Per-contract sync start (informational in v1; the indexer uses the block markers).
    start_block: u64 = 0,
};

pub const Blocks = struct {
    v1_deployment_block: u64,
    v2_deployment_block: u64,
    v1_end_block: u64 = 0,
    temp_registrar_start_block: u64,
    v1_migration_block: u64,
    name_wrapper_deployment_block: u64,
};

pub const Manifest = struct {
    manifest_version: u32,
    chain_id: u64,
    contracts: []const Contract,
    blocks: Blocks,
};

pub const Error = error{
    ManifestChainMismatch,
    ManifestBadAddress,
    ManifestUnknownContract,
    ManifestMissingContract,
    ManifestDuplicateContract,
    ManifestParseError,
};

/// Count of Address fields on ContractAddresses (the set a manifest must fully declare).
const addr_count = blk: {
    var n: usize = 0;
    for (@typeInfo(ContractAddresses).@"struct".fields) |f| {
        if (f.type == Address) n += 1;
    }
    break :blk n;
};

/// Load a `.zon` manifest at `path` into a `ContractAddresses`, validated against
/// `network`. The returned struct is by-value (no allocation to free). Fails fast on any
/// misconfiguration.
pub fn loadManifest(allocator: std.mem.Allocator, path: []const u8, network: Network) !ContractAddresses {
    const raw = try zsys.readFileAlloc(allocator, path, 1 << 20);
    defer allocator.free(raw);
    const src = try allocator.dupeZ(u8, raw); // zon parser needs a sentinel-terminated slice
    defer allocator.free(src);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const m = std.zon.parse.fromSliceAlloc(Manifest, arena.allocator(), src, null, .{}) catch {
        std.log.err("MANIFEST_PATH '{s}': malformed .zon manifest", .{path});
        return Error.ManifestParseError;
    };

    return toContractAddresses(m, network);
}

/// Convert a parsed manifest into a validated ContractAddresses. Reflection over the
/// address fields keeps this in lockstep with the struct — a new field automatically
/// requires (only) a manifest entry, and a manifest entry naming a non-field errors.
pub fn toContractAddresses(m: Manifest, network: Network) !ContractAddresses {
    if (m.chain_id != network.chainId()) {
        std.log.err("manifest chain_id {d} != NETWORK {s} chain_id {d}", .{ m.chain_id, @tagName(network), network.chainId() });
        return Error.ManifestChainMismatch;
    }

    var ca: ContractAddresses = undefined;
    // Start every address zero; blocks come straight from the manifest.
    inline for (@typeInfo(ContractAddresses).@"struct".fields) |f| {
        if (f.type == Address) @field(ca, f.name) = Address.zero;
    }
    ca.v1_deployment_block = m.blocks.v1_deployment_block;
    ca.v2_deployment_block = m.blocks.v2_deployment_block;
    ca.v1_end_block = m.blocks.v1_end_block;
    ca.temp_registrar_start_block = m.blocks.temp_registrar_start_block;
    ca.v1_migration_block = m.blocks.v1_migration_block;
    ca.name_wrapper_deployment_block = m.blocks.name_wrapper_deployment_block;

    var seen = [_]bool{false} ** addr_count;
    for (m.contracts) |c| {
        var matched = false;
        comptime var idx: usize = 0;
        inline for (@typeInfo(ContractAddresses).@"struct".fields) |f| {
            if (f.type == Address) {
                if (std.mem.eql(u8, f.name, c.name)) {
                    if (seen[idx]) {
                        std.log.err("manifest declares contract '{s}' more than once", .{c.name});
                        return Error.ManifestDuplicateContract;
                    }
                    matched = true;
                    seen[idx] = true;
                    if (c.status != .disabled) {
                        @field(ca, f.name) = Address.fromHex(c.address) catch {
                            std.log.err("manifest contract '{s}': bad address '{s}'", .{ c.name, c.address });
                            return Error.ManifestBadAddress;
                        };
                    }
                }
                idx += 1;
            }
        }
        if (!matched) {
            std.log.err("manifest names unknown contract '{s}'", .{c.name});
            return Error.ManifestUnknownContract;
        }
    }

    // Every contract must be EXPLICITLY declared — with the zero address if not deployed,
    // or status=.disabled — so a fat-fingered/omitted line fails fast rather than silently
    // zeroing an address and dropping that contract from the indexed set.
    comptime var check_idx: usize = 0;
    inline for (@typeInfo(ContractAddresses).@"struct".fields) |f| {
        if (f.type == Address) {
            if (!seen[check_idx]) {
                std.log.err("manifest omits contract '{s}' — declare it (zero address if not deployed on this network, or status=.disabled)", .{f.name});
                return Error.ManifestMissingContract;
            }
            check_idx += 1;
        }
    }
    return ca;
}

/// Serialize a ContractAddresses to `.zon` manifest text (used to emit the committed
/// reference manifests from the code defaults). Reflection walks the address fields.
pub fn serialize(writer: anytype, ca: ContractAddresses, network: Network) !void {
    try writer.print(
        \\// Reference contract manifest — generated from src/contracts.zig defaults.
        \\// See manifests/README.txt. A test asserts this loads to the code defaults.
        \\.{{
        \\    .manifest_version = 1,
        \\    .chain_id = {d},
        \\    .contracts = .{{
        \\
    , .{network.chainId()});
    inline for (@typeInfo(ContractAddresses).@"struct".fields) |f| {
        if (f.type == Address) {
            var buf: [42]u8 = undefined;
            const hex = @field(ca, f.name).toHexBuf(&buf);
            try writer.print("        .{{ .name = \"{s}\", .address = \"{s}\" }},\n", .{ f.name, hex });
        }
    }
    try writer.print(
        \\    }},
        \\    .blocks = .{{
        \\        .v1_deployment_block = {d},
        \\        .v2_deployment_block = {d},
        \\        .v1_end_block = {d},
        \\        .temp_registrar_start_block = {d},
        \\        .v1_migration_block = {d},
        \\        .name_wrapper_deployment_block = {d},
        \\    }},
        \\}}
        \\
    , .{
        ca.v1_deployment_block,
        ca.v2_deployment_block,
        ca.v1_end_block,
        ca.temp_registrar_start_block,
        ca.v1_migration_block,
        ca.name_wrapper_deployment_block,
    });
}
