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
    // ═══════════════════════════════════════════════════════════════════════
    //  V1 Protocol (Legacy ENS — currently the only ENS on mainnet)
    // ═══════════════════════════════════════════════════════════════════════
    // Pre-V1 Temporary Registrar (Auction System, 2017-2019)
    temporary_registrar: Address,

    // V1 contracts
    old_ens_registry: Address, // Pre-migration registry (0x314159265dD8dbb310642f98f50C066173C1259b, deployed 2017)
    old_public_resolver: Address, // Legacy public resolver (0x112234455c3a32fd11230c42e7bccd4a84e02010, deployed 2017)
    ens_registry: Address, // New registry with fallback (0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e, deployed block 9380380)
    base_registrar: Address,
    eth_registrar_controller: Address,
    public_resolver: Address,
    reverse_registrar: Address,
    name_wrapper: Address,

    // ═══════════════════════════════════════════════════════════════════════
    //  V2 Protocol (ENSv2 — Sepolia only today; mainnet not deployed yet)
    // ═══════════════════════════════════════════════════════════════════════
    root_registry: Address,
    eth_registry: Address,
    eth_registrar_v2: Address,
    eth_reverse_registrar: Address,

    // ═══════════════════════════════════════════════════════════════════════
    //  Migration (V1 → V2)
    // ═══════════════════════════════════════════════════════════════════════
    locked_migration_controller: Address, // V2 side: receives locked/wrapped names
    unlocked_migration_controller: Address, // V2 side: receives unlocked/unwrapped names

    // ═══════════════════════════════════════════════════════════════════════
    //  Deployment blocks (sync start markers)
    // ═══════════════════════════════════════════════════════════════════════
    v1_deployment_block: u64, // V1 Permanent Registrar (Base Registrar) deployment
    v2_deployment_block: u64, // V2 protocol deployment (0 if not deployed on this network)

    // V1 historical markers (mainnet specific; 0 on testnets)
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

fn sepoliaAddresses() ContractAddresses {
    return .{
        // Temporary Registrar (not used on Sepolia testnet)
        .temporary_registrar = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable,

        // V1 Contracts (mainnet via tenderly fork)
        .old_ens_registry = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable, // Not applicable on tenderly fork
        .old_public_resolver = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable, // Not applicable on tenderly fork
        .ens_registry = Address.fromHex("0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e") catch unreachable,
        .base_registrar = Address.fromHex("0x57f1887a8bf19b14fc0df6fd9b2acc9af147ea85") catch unreachable,
        .eth_registrar_controller = Address.fromHex("0xfb3cE5D01e0f33f41DbB39035dB9745962F1f968") catch unreachable,
        .public_resolver = Address.fromHex("0xE99638b40E4Fff0129D56f03b55b6bbC4BBE49b5") catch unreachable,
        .reverse_registrar = Address.fromHex("0xA0a1AbcDAe1a2a4A2EF8e9113Ff0e02DD81DC0C6") catch unreachable,
        .name_wrapper = Address.fromHex("0x0635513f179D50A207757E05759CbD106d7dFcE8") catch unreachable,

        // V2 Contracts (tenderly fork — current deployment)
        .root_registry = Address.fromHex("0xfd43dc00ab0d0e247a2827d15dddfc5bd9646a29") catch unreachable, // RootRegistry
        .eth_registry = Address.fromHex("0x31a2bb5d933557cce1b3129993193896d074db92") catch unreachable, // ETHRegistry
        .eth_registrar_v2 = Address.fromHex("0x26e5e80e8f36607ef401443fb34eea363c86e8f7") catch unreachable, // ETHRegistrar
        .eth_reverse_registrar = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable, // Not in current deployment table

        // Migration Contracts (V1→V2, tenderly fork)
        .locked_migration_controller = Address.fromHex("0x7ca1ded4d929ebd8b09e24c2da8e909014abecd8") catch unreachable, // LockedMigrationController
        .unlocked_migration_controller = Address.fromHex("0x5587003f8eeee1bc236d48ab39059cbfd99207d7") catch unreachable, // UnlockedMigrationController

        // Deployment blocks (verified from on-protocol)
        .v1_deployment_block = 4700000, // V1 ENS deployment on Sepolia
        .v2_deployment_block = 9374806, // V2 ENS deployment on Sepolia

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

        // V2 Mainnet Contracts (ENSv2 — not yet deployed; zero placeholders)
        .root_registry = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable,
        .eth_registry = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable,
        .eth_registrar_v2 = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable,
        .eth_reverse_registrar = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable,

        // Migration Contracts (Not yet deployed on mainnet)
        .locked_migration_controller = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable,
        .unlocked_migration_controller = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable,

        // Deployment blocks
        // ENS Registry + Temporary Registrar deployed in block 3327417 (May 2017)
        // V1 Permanent Registrar (Base Registrar) deployed in block 9380410 (May 2019 migration)
        // Name Wrapper deployed in block 15628465 (September 2022)
        .v1_deployment_block = 9380410, // V1 Permanent Registrar deployment (migration from temporary)
        .v2_deployment_block = 0, // V2 not deployed on mainnet yet

        // Historical block markers (mainnet specific)
        .temp_registrar_start_block = 3327417, // Temporary Registrar deployment (May 2017)
        .v1_migration_block = 9380410, // V1 Permanent Registrar deployment (May 2019)
        .name_wrapper_deployment_block = 15628465, // Name Wrapper deployment (September 2022)
    };
}
