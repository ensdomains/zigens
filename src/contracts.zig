const std = @import("std");
const Address = @import("types/address.zig").Address;

pub const Network = enum {
    sepolia,
    mainnet,

    pub fn toString(self: Network) []const u8 {
        return switch (self) {
            .sepolia => "sepolia",
            .mainnet => "mainnet",
        };
    }

    pub fn fromString(s: []const u8) !Network {
        if (std.ascii.eqlIgnoreCase(s, "sepolia")) return .sepolia;
        if (std.ascii.eqlIgnoreCase(s, "mainnet")) return .mainnet;
        return error.UnknownNetwork;
    }
};

pub const ContractAddresses = struct {
    // Pre-V1 (Temporary Registrar - Auction System 2017-2019)
    temporary_registrar: Address,

    // V1 (Legacy) Contracts
    old_ens_registry: Address, // Pre-migration registry (0x314159265dD8dbb310642f98f50C066173C1259b, deployed 2017)
    old_public_resolver: Address, // Legacy public resolver (0x112234455c3a32fd11230c42e7bccd4a84e02010, deployed 2017)
    ens_registry: Address, // New registry with fallback (0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e, deployed block 9380380)
    base_registrar: Address,
    eth_registrar_controller: Address,
    public_resolver: Address,
    reverse_registrar: Address,
    name_wrapper: Address,

    // L1 (New) Contracts
    root_registry: Address,
    eth_registry: Address,
    registry_datastore: Address,
    eth_reverse_registrar: Address,

    // L2 Contracts
    l2_eth_registry: Address,
    l2_eth_registrar: Address,
    l2_registry_datastore: Address,

    // Migration Contracts (V1→V2)
    migration_helper: Address, // V1 side: initiates migration by transferring tokens
    locked_migration_controller: Address, // V2 side: receives locked/wrapped names
    unlocked_migration_controller: Address, // V2 side: receives unlocked/unwrapped names

    // Deployment blocks for efficient sync start
    v1_deployment_block: u64,
    l1_deployment_block: u64,
    l2_deployment_block: u64,

    // Historical block markers (mainnet only, 0 for testnets)
    temp_registrar_start_block: u64, // Temporary Registrar deployment (May 2017)
    v1_migration_block: u64, // V1 Permanent Registrar deployment (May 2019)
    name_wrapper_deployment_block: u64, // Name Wrapper deployment (September 2022)
};

pub fn getContractAddresses(network: Network) !ContractAddresses {
    return switch (network) {
        .sepolia => sepoliaAddresses(),
        .mainnet => mainnetAddresses(),
    };
}

const ContractAddressesJson = struct {
    temporary_registrar: []const u8,
    old_ens_registry: []const u8,
    old_public_resolver: []const u8,
    ens_registry: []const u8,
    base_registrar: []const u8,
    eth_registrar_controller: []const u8,
    public_resolver: []const u8,
    reverse_registrar: []const u8,
    name_wrapper: []const u8,
    root_registry: []const u8,
    eth_registry: []const u8,
    registry_datastore: []const u8,
    eth_reverse_registrar: []const u8,
    l2_eth_registry: []const u8,
    l2_eth_registrar: []const u8,
    l2_registry_datastore: []const u8,
    migration_helper: []const u8,
    locked_migration_controller: []const u8,
    unlocked_migration_controller: []const u8,
    v1_deployment_block: u64,
    l1_deployment_block: u64,
    l2_deployment_block: u64,
    temp_registrar_start_block: u64,
    v1_migration_block: u64,
    name_wrapper_deployment_block: u64,
};

/// Load full contract address set from a JSON file. Used to override hardcoded
/// network defaults for CI / fresh deployments. All fields required.
pub fn loadFromJson(allocator: std.mem.Allocator, path: []const u8) !ContractAddresses {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(contents);

    const parsed = try std.json.parseFromSlice(
        ContractAddressesJson,
        allocator,
        contents,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const j = parsed.value;
    return ContractAddresses{
        .temporary_registrar = try Address.fromHex(j.temporary_registrar),
        .old_ens_registry = try Address.fromHex(j.old_ens_registry),
        .old_public_resolver = try Address.fromHex(j.old_public_resolver),
        .ens_registry = try Address.fromHex(j.ens_registry),
        .base_registrar = try Address.fromHex(j.base_registrar),
        .eth_registrar_controller = try Address.fromHex(j.eth_registrar_controller),
        .public_resolver = try Address.fromHex(j.public_resolver),
        .reverse_registrar = try Address.fromHex(j.reverse_registrar),
        .name_wrapper = try Address.fromHex(j.name_wrapper),
        .root_registry = try Address.fromHex(j.root_registry),
        .eth_registry = try Address.fromHex(j.eth_registry),
        .registry_datastore = try Address.fromHex(j.registry_datastore),
        .eth_reverse_registrar = try Address.fromHex(j.eth_reverse_registrar),
        .l2_eth_registry = try Address.fromHex(j.l2_eth_registry),
        .l2_eth_registrar = try Address.fromHex(j.l2_eth_registrar),
        .l2_registry_datastore = try Address.fromHex(j.l2_registry_datastore),
        .migration_helper = try Address.fromHex(j.migration_helper),
        .locked_migration_controller = try Address.fromHex(j.locked_migration_controller),
        .unlocked_migration_controller = try Address.fromHex(j.unlocked_migration_controller),
        .v1_deployment_block = j.v1_deployment_block,
        .l1_deployment_block = j.l1_deployment_block,
        .l2_deployment_block = j.l2_deployment_block,
        .temp_registrar_start_block = j.temp_registrar_start_block,
        .v1_migration_block = j.v1_migration_block,
        .name_wrapper_deployment_block = j.name_wrapper_deployment_block,
    };
}

fn sepoliaAddresses() ContractAddresses {
    return .{
        // Temporary Registrar (not used on Sepolia testnet)
        .temporary_registrar = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable,

        // V1 Sepolia Contracts
        .old_ens_registry = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable, // Not applicable for testnets
        .old_public_resolver = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable, // Not applicable for testnets
        .ens_registry = Address.fromHex("0x17795c119b8155ab9d3357c77747ba509695d7cb") catch unreachable,
        .base_registrar = Address.fromHex("0xb16870800de7444f6b2ebd885465412a5e581614") catch unreachable,
        .eth_registrar_controller = Address.fromHex("0x99e517db3db5ec5424367b8b50cd11ddcb0008f1") catch unreachable,
        .public_resolver = Address.fromHex("0x0e14ee0592da66bb4c8a8090066bc8a5af15f3e6") catch unreachable,
        .reverse_registrar = Address.fromHex("0xf79f9970030fe60bd89d21591c7f2d80d7d21242") catch unreachable,
        .name_wrapper = Address.fromHex("0xca7e6d0ddc5f373197bbe6fc2f09c2314399f028") catch unreachable,

        // L1 Sepolia Contracts (V2 deployment)
        .root_registry = Address.fromHex("0x3a3e15a5d27ff6f05c844313312f2e72096d3ed3") catch unreachable,
        .eth_registry = Address.fromHex("0x796fff2e907449be8d5921bcc215b1b76d89d080") catch unreachable,
        .registry_datastore = Address.fromHex("0x2a1d9588f3931fc7495867c82cd0d78cfb144945") catch unreachable,
        .eth_reverse_registrar = Address.fromHex("0xa35e6c5dc06e820cc6716ca33dfcd203503fb1d3") catch unreachable,

        // L2 Sepolia Contracts (V2 deployment - same chain as L1, different contract version)
        .l2_eth_registry = Address.fromHex("0x796fff2e907449be8d5921bcc215b1b76d89d080") catch unreachable,
        .l2_eth_registrar = Address.fromHex("0x68586418353b771cf2425ed14a07512aa880c532") catch unreachable,
        .l2_registry_datastore = Address.fromHex("0x2a1d9588f3931fc7495867c82cd0d78cfb144945") catch unreachable,

        // Migration Contracts (V1→V2, Sepolia deployment)
        .migration_helper = Address.fromHex("0x8fa8b82a70e400ba99423c8f76cc2cead2adc590") catch unreachable,
        .locked_migration_controller = Address.fromHex("0x22cd7e6a89f5bf4510ef22b3dd4ef190d22f95c3") catch unreachable,
        .unlocked_migration_controller = Address.fromHex("0x76ae358d9ad91651b78463ae609dadc9e7ce4402") catch unreachable,

        // Deployment blocks (verified from on-chain)
        // For Sepolia testnet, these are the actual deployment blocks
        .v1_deployment_block = 4700000, // ENS V1 deployment on Sepolia
        .l1_deployment_block = 9374806, // V2 deployment block on Sepolia
        .l2_deployment_block = 9374806, // V2 deployment block on Sepolia (same chain)

        // Historical markers (not applicable for testnets)
        .temp_registrar_start_block = 0,
        .v1_migration_block = 0,
        .name_wrapper_deployment_block = 0,
    };
}

fn mainnetAddresses() ContractAddresses {
    return .{
        // Temporary Registrar (Pre-V1 Migration, May 2017 - May 2019)
        .temporary_registrar = Address.fromHex("0x6090A6e47849629b7245Dfa1Ca21D94cd15878Ef") catch unreachable,

        // V1 Mainnet Contracts (ENS V1 - Current Production)
        .old_ens_registry = Address.fromHex("0x314159265dD8dbb310642f98f50C066173C1259b") catch unreachable, // Pre-migration registry (2017-2020)
        .old_public_resolver = Address.fromHex("0x112234455c3a32fd11230c42e7bccd4a84e02010") catch unreachable, // Legacy public resolver (2017)
        .ens_registry = Address.fromHex("0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e") catch unreachable,
        .base_registrar = Address.fromHex("0x57f1887a8BF19b14fC0dF6Fd9B2acc9Af147eA85") catch unreachable,
        .eth_registrar_controller = Address.fromHex("0x283Af0B28c62C092C9727F1Ee09c02CA627EB7F5") catch unreachable,
        .public_resolver = Address.fromHex("0xF29100983E058B709F3D539b0c765937B804AC15") catch unreachable,
        .reverse_registrar = Address.fromHex("0xa58E81fe9b61B5c3fE2AFD33CF304c454AbFc7Cb") catch unreachable,
        .name_wrapper = Address.fromHex("0xD4416b13d2b3a9aBae7AcD5D6C2BbDBE25686401") catch unreachable,

        // L1 Mainnet Contracts (ENS V2 - Not yet deployed on mainnet)
        // Using zero addresses as placeholders until V2 deploys
        .root_registry = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable,
        .eth_registry = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable,
        .registry_datastore = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable,
        .eth_reverse_registrar = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable,

        // L2 Contracts (Not applicable for mainnet L1)
        .l2_eth_registry = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable,
        .l2_eth_registrar = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable,
        .l2_registry_datastore = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable,

        // Migration Contracts (Not yet deployed on mainnet)
        .migration_helper = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable,
        .locked_migration_controller = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable,
        .unlocked_migration_controller = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable,

        // Deployment blocks
        // ENS Registry + Temporary Registrar deployed in block 3327417 (May 2017)
        // V1 Permanent Registrar (Base Registrar) deployed in block 9380410 (May 2019 migration)
        // Name Wrapper deployed in block 15628465 (September 2022)
        .v1_deployment_block = 9380410, // V1 Permanent Registrar deployment (migration from temporary)
        .l1_deployment_block = 0, // V2 not deployed yet
        .l2_deployment_block = 0, // Not applicable for L1

        // Historical block markers (mainnet specific)
        .temp_registrar_start_block = 3327417, // Temporary Registrar deployment (May 2017)
        .v1_migration_block = 9380410, // V1 Permanent Registrar deployment (May 2019)
        .name_wrapper_deployment_block = 15628465, // Name Wrapper deployment (September 2022)
    };
}

