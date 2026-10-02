const std = @import("std");
const Address = @import("types/address.zig").Address;

pub const Network = enum {
    sepolia,
    mainnet,
    /// Base mainnet (chain id 8453). Manifest-only: there are no built-in
    /// contract defaults — a deployment MUST set MANIFEST_PATH (the committed
    /// manifests/base.zon is the all-disabled substrate until a Basenames
    /// adapter wires real contracts).
    base,

    pub fn toString(self: Network) []const u8 {
        return switch (self) {
            .sepolia => "sepolia",
            .mainnet => "mainnet",
            .base => "base",
        };
    }

    pub fn fromString(s: []const u8) !Network {
        if (std.ascii.eqlIgnoreCase(s, "sepolia")) return .sepolia;
        if (std.ascii.eqlIgnoreCase(s, "mainnet")) return .mainnet;
        if (std.ascii.eqlIgnoreCase(s, "base")) return .base;
        return error.UnknownNetwork;
    }

    /// EIP-155 chain ID. Used as the leading segment of entity IDs (Resolver
    /// `{chainId}-{protocol}-{address}-{namehash}`, …) so that when this
    /// indexer is later extended to multi-chain plugins (basenames, lineanames,
    /// 3DNS) entity IDs remain globally unique across chains without a schema
    /// migration.
    pub fn chainId(self: Network) u64 {
        return switch (self) {
            .sepolia => 11155111,
            .mainnet => 1,
            .base => 8453,
        };
    }

    /// The registrar root: 2LDs registered through the base-registrar/controller
    /// surface become `<label>.<rootName()>`. Basenames registers under base.eth.
    pub fn rootName(self: Network) []const u8 {
        return switch (self) {
            .sepolia, .mainnet => "eth",
            .base => "base.eth",
        };
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

    // Query-time ENSIP-10 Universal Resolver (Task 06 live-resolution fallback).
    // Manifest data (Task 08): declared per-network in the code default AND the
    // reference manifests; RESOLVE_UNIVERSAL_RESOLVER overrides it at deploy time
    // (config.zig). Address.zero = not wired for this network.
    universal_resolver: Address,

    // ═══════════════════════════════════════════════════════════════════════
    //  V2 Protocol (ENSv2 — Sepolia only today; mainnet not deployed yet)
    // ═══════════════════════════════════════════════════════════════════════
    root_registry: Address,
    eth_registry: Address,
    eth_registrar_v2: Address,
    // ETHRenewerV1 — standalone renewer that emits the same ETH-registrar
    // NameRenewed(uint256,string,uint64,uint64,address,bytes32,uint256); renewals can
    // originate here as well as from eth_registrar_v2. Zero when not deployed.
    eth_renewer_v1: Address,
    // LabelStore — on-chain labelhash→label dictionary. Its Label(bytes32,string) events
    // heal unknown labels (same path as the rainbow table). Zero when not deployed.
    eth_label_store: Address,
    eth_reverse_registrar: Address,
    // BatchRegistrar — owner-only batch reserve/renew. Used by deployer for the
    // standard production pre-migration flow on mainnet. Same ABI as
    // premigration_registrar below; only emits OwnershipTransferred.
    batch_registrar: Address,
    // TestnetV1PremigrationRegistrar — second `BatchRegistrar` instance on
    // testnets, used to reserve names that will later be migrated from V1.
    // Same ABI as batch_registrar (only OwnershipTransferred), the registration
    // events themselves are emitted by ETHRegistry.
    premigration_registrar: Address,

    // ═══════════════════════════════════════════════════════════════════════
    //  Migration (V1 → V2)
    // ═══════════════════════════════════════════════════════════════════════
    migration_helper: Address, // V1 side: initiates migration by transferring tokens
    locked_migration_controller: Address, // V2 side: receives locked/wrapped names
    unlocked_migration_controller: Address, // V2 side: receives unlocked/unwrapped names

    // ═══════════════════════════════════════════════════════════════════════
    //  Deployment blocks (sync start markers)
    // ═══════════════════════════════════════════════════════════════════════
    v1_deployment_block: u64, // V1 Permanent Registrar (Base Registrar) deployment
    v2_deployment_block: u64, // V2 protocol deployment (0 if not deployed on this network)
    // Last block of the V1 era on this network; 0 = V1 has no sunset. Deployment
    // data, not a code constant — set it only when a real cutover is decided.
    v1_end_block: u64 = 0,

    // V1 historical markers (mainnet specific; 0 on testnets)
    temp_registrar_start_block: u64, // Temporary Registrar deployment (May 2017)
    v1_migration_block: u64, // V1 Permanent Registrar deployment (May 2019)
    name_wrapper_deployment_block: u64, // Name Wrapper deployment (September 2022)
};

/// True iff `candidate` is an ACTIVE contract that `addr` matches. A DISABLED contract
/// is represented by the zero address (manifest.zig `status = .disabled` leaves it zero),
/// so a zero `candidate` never matches — that is precisely how a disabled contract is
/// excluded from indexing (Task 08 acceptance criterion 5). Every "is this event from
/// contract X?" check routes through this guard so the zero==disabled invariant holds
/// uniformly.
pub fn isActiveContract(addr: Address, candidate: Address) bool {
    return !candidate.isZero() and addr.eql(candidate);
}

pub fn getContractAddresses(network: Network) !ContractAddresses {
    return switch (network) {
        .sepolia => sepoliaAddresses(),
        .mainnet => mainnetAddresses(),
        // Manifest-only network: silent all-zero defaults would violate the
        // "required present or explicitly disabled; never silent mis-index" rule.
        .base => error.ManifestRequired,
    };
}

fn sepoliaAddresses() ContractAddresses {
    return .{
        // Temporary Registrar (LegacyETHRegistrarController)
        .temporary_registrar = Address.fromHex("0x7e02892cfc2Bfd53a75275451d73cF620e793fc0") catch unreachable,

        // V1 Sepolia Contracts
        .old_ens_registry = Address.fromHex("0x94f523b8261B815b87EFfCf4d18E6aBeF18d6e4b") catch unreachable,
        .old_public_resolver = Address.fromHex("0x0CeEC524b2807841739D3B5E161F5bf1430FFA48") catch unreachable,
        .ens_registry = Address.fromHex("0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e") catch unreachable,
        .base_registrar = Address.fromHex("0x57f1887a8bf19b14fc0df6fd9b2acc9af147ea85") catch unreachable,
        .eth_registrar_controller = Address.fromHex("0xfb3cE5D01e0f33f41DbB39035dB9745962F1f968") catch unreachable,
        .public_resolver = Address.fromHex("0x5239A812ec9A62F46dbb5de8f346C8eFe7553A9f") catch unreachable,
        .reverse_registrar = Address.fromHex("0xA0a1AbcDAe1a2a4A2EF8e9113Ff0e02DD81DC0C6") catch unreachable,
        .name_wrapper = Address.fromHex("0x0635513f179D50A207757E05759CbD106d7dFcE8") catch unreachable,

        // V2 Sepolia Contracts (ENSv2 deployment)
        .root_registry = Address.fromHex("0xb458d6a3a77919449d03e7a6903c26827c1ec43f") catch unreachable,
        .eth_renewer_v1 = Address.fromHex("0xf2ece44980778966b8a0fccb3a9e339440f6e045") catch unreachable,
        .eth_label_store = Address.fromHex("0xed8246ff02203a4d4cb262bd78beaa7408a57cae") catch unreachable,
        .eth_registry = Address.fromHex("0xd4ebcbbdf463c9c45784603db0ddd499bc44a8b4") catch unreachable,
        .eth_registrar_v2 = Address.fromHex("0xf633e7fc17e2bbe0d0965d18ec1821dcb754a3d3") catch unreachable,
        .eth_reverse_registrar = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable, // TBD
        .batch_registrar = Address.fromHex("0x4a4c8b7cdab6b19dc2cdb417cdb53a2ccbaf5322") catch unreachable,
        .premigration_registrar = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable,

        // Migration Contracts (V1→V2, Sepolia deployment)
        .migration_helper = Address.fromHex("0xa8f86ee5cdd28703bd876f3a8c10b1de70f36899") catch unreachable,
        .locked_migration_controller = Address.fromHex("0x6029a063d69b09d23c52a754a90e4fe43adac3a8") catch unreachable,
        .unlocked_migration_controller = Address.fromHex("0x2a35b94df22cc7354570be2284655e2cdc0e64a2") catch unreachable,

        // Deployment blocks (verified on-chain via eth_getCode bisection)
        // Both sides start at this deployment: the V1 contracts above are the
        // long-lived canonical Sepolia ones, but only V1 state from this
        // deployment onwards is relevant to the V2 migration fixtures.
        .v1_deployment_block = 11820289,
        .v2_deployment_block = 11820289,

        // Historical markers (not applicable for testnets)
        .temp_registrar_start_block = 0,
        .v1_migration_block = 0,
        .name_wrapper_deployment_block = 0,

        .universal_resolver = Address.fromHex("0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe") catch unreachable,
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
        .root_registry = Address.zero,
        .eth_registry = Address.zero,
        .eth_registrar_v2 = Address.zero,
        .eth_renewer_v1 = Address.zero,
        .eth_label_store = Address.zero,
        .eth_reverse_registrar = Address.zero,
        .batch_registrar = Address.zero,
        .premigration_registrar = Address.zero,

        // Migration Contracts (Not yet deployed on mainnet)
        .migration_helper = Address.zero,
        .locked_migration_controller = Address.zero,
        .unlocked_migration_controller = Address.zero,

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

        .universal_resolver = Address.zero, // no canonical mainnet UR wired as a default yet; supply via manifest or RESOLVE_UNIVERSAL_RESOLVER
    };
}
