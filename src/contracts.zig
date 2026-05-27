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

    /// EIP-155 chain ID. Used as the leading segment of entity IDs (Resolver
    /// `{chainId}-{protocol}-{address}-{namehash}`, …) so that when this
    /// indexer is later extended to multi-chain plugins (basenames, lineanames,
    /// 3DNS) entity IDs remain globally unique across chains without a schema
    /// migration.
    pub fn chainId(self: Network) u64 {
        return switch (self) {
            .sepolia => 11155111,
            .mainnet => 1,
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

    // ═══════════════════════════════════════════════════════════════════════
    //  V2 Protocol (ENSv2)
    // ═══════════════════════════════════════════════════════════════════════

    // — Core ENSv2 Registries —
    root_registry: Address, // RootRegistry — top-level ENSv2 registry
    eth_registry: Address, // ETHRegistry — .eth TLD registry

    // — ENSv2 Resolvers —
    ens_v1_resolver: Address, // ENSV1Resolver — V1-compatible resolver for V2 names
    ens_v2_resolver: Address, // ENSV2Resolver — native V2 resolver
    permissioned_resolver_impl: Address, // PermissionedResolverImpl implementation
    public_resolver_set: Address, // PublicResolverSet — set of public resolvers
    public_resolver_v2: Address, // PublicResolverV2 — public resolver for V2
    managed_universal_resolver_proxy: Address, // ManagedUniversalResolverProxy
    upgradable_universal_resolver_proxy: Address, // UpgradableUniversalResolverProxy
    universal_resolver_v2: Address, // UniversalResolverV2

    // — ENSv2 Registrars —
    eth_registrar_v2: Address, // ETHRegistrar — .eth registrar
    batch_registrar: Address, // BatchRegistrar — owner-only batch reserve/renew
    testnet_v1_premigration_registrar: Address, // TestnetV1PremigrationRegistrar — second BatchRegistrar on testnets
    dns_v1_mirror_root_batch_registrar: Address, // DNSV1MirrorRootBatchRegistrar

    // — ENSv2 Reverse Registrar —
    eth_reverse_registrar: Address, // V2 reverse registrar (may be same as proxy)

    // — ENSv2 Auxiliary —
    approved_upgrade_gate: Address, // ApprovedUpgradeGate
    contract_namer: Address, // ContractNamer
    graveyard: Address, // Graveyard — burned name collection
    hca_factory: Address, // HCAFactory — human-readable contract address factory
    label_store: Address, // LabelStore — label storage
    standard_rent_price_oracle: Address, // StandardRentPriceOracle
    user_registry_impl: Address, // UserRegistryImpl
    verifiable_factory: Address, // VerifiableFactory
    wrapper_registry_impl: Address, // WrapperRegistryImpl

    // — Test-only Mocks —
    mock_dai: Address, // MockDAI — testnet only
    mock_usdc: Address, // MockUSDC — testnet only

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

        // V1 Sepolia Contracts (fresh deployment alongside V2)
        .old_ens_registry = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable, // Not applicable for testnets
        .old_public_resolver = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable, // Not applicable for testnets
        .ens_registry = Address.fromHex("0xb6fb46e1458915dd828633d91e1df8e4c3f2d4dd") catch unreachable,
        .base_registrar = Address.fromHex("0xa51c9e6efe589407c72984e93b45e35a71a398ec") catch unreachable,
        .eth_registrar_controller = Address.fromHex("0xb5778cf6cc9586d9ce740039c84dfb1802f307bc") catch unreachable,
        .public_resolver = Address.fromHex("0xb441cb480460eb8b2964dcb82b64a883b14abf3e") catch unreachable,
        .reverse_registrar = Address.fromHex("0x26e5e80e8f36607ef401443fb34eea363c86e8f7") catch unreachable,
        .name_wrapper = Address.fromHex("0x250a6c640297f605b63c6e91c7cd376f04b288da") catch unreachable,

        // V2 Sepolia Contracts (ENSv2 deployment)
        .root_registry = Address.fromHex("0xc960f7217d3643b525ef36bec8adf86953cd9ab8") catch unreachable,
        .eth_registry = Address.fromHex("0xdedb92913a25abe1f7bcdd85d8a344a43b398b67") catch unreachable,
        .ens_v1_resolver = Address.fromHex("0x422484c2d51f92830bfb563fa5e172aa2d8b884b") catch unreachable,
        .ens_v2_resolver = Address.fromHex("0x6a923e0b9d722510b268280a381878818841629c") catch unreachable,
        .permissioned_resolver_impl = Address.fromHex("0xdce5205a553573ffd47629327dddf36186022ffa") catch unreachable,
        .public_resolver_set = Address.fromHex("0xfef98bae02b882b00efa02f3d7b379bee6cda86b") catch unreachable,
        .public_resolver_v2 = Address.fromHex("0x5239a812ec9a62f46dbb5de8f346c8efe7553a9f") catch unreachable,
        .managed_universal_resolver_proxy = Address.fromHex("0x6d80f2172cfdec5730fe683860c33d26fc42e6f1") catch unreachable,
        .upgradable_universal_resolver_proxy = Address.fromHex("0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe") catch unreachable,
        .universal_resolver_v2 = Address.fromHex("0x2f8a180604c42457cb56c7c4f708748ff1f91df1") catch unreachable,
        .eth_registrar_v2 = Address.fromHex("0x8c2e866b439358c41ae05de9cbe8a00bfefaffca") catch unreachable,
        .batch_registrar = Address.fromHex("0xb39c2da7143dffa4a097970887fa6f1d17c1d60f") catch unreachable,
        .testnet_v1_premigration_registrar = Address.fromHex("0xdf60c561ca35ad3c89d24bba854654b1c3477078") catch unreachable,
        .dns_v1_mirror_root_batch_registrar = Address.fromHex("0x9c53569d0c545a6743d6073a081acb977154eaf9") catch unreachable,
        .eth_reverse_registrar = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable, // TBD
        .approved_upgrade_gate = Address.fromHex("0x2c83019d86ff3be9cc269687215f4731158a8b6f") catch unreachable,
        .contract_namer = Address.fromHex("0xfc8bf9234969d6b85729b756fa9e14bb84a06754") catch unreachable,
        .graveyard = Address.fromHex("0x802453f2f077d5a0c3d0f9a6eb2a36dcfa3c6e0d") catch unreachable,
        .hca_factory = Address.fromHex("0x358680728dedb552adaa9f5eb5d4395b291cf943") catch unreachable,
        .label_store = Address.fromHex("0x23ea712da760c4e09fc9be108f1f1da6d5d6d053") catch unreachable,
        .standard_rent_price_oracle = Address.fromHex("0xe19d37839f42f7d2694d8c5712f412c66a218161") catch unreachable,
        .user_registry_impl = Address.fromHex("0x0f99e7ea74903afcb7224d0354fd7428a6f92917") catch unreachable,
        .verifiable_factory = Address.fromHex("0xd2a632d8a8b67c2c4398c255cbd7af8dd7236198") catch unreachable,
        .wrapper_registry_impl = Address.fromHex("0x9d9d230d9b894d3cc14fc7801031f45cd5007f18") catch unreachable,

        // Test-only mocks
        .mock_dai = Address.fromHex("0xe915cebbc1570a74177b6c589fed1e8f53117559") catch unreachable,
        .mock_usdc = Address.fromHex("0x3dfc8b53dafa5ebbb071a8b97678ab534ed838d9") catch unreachable,

        // Migration Contracts (V1→V2, Sepolia deployment)
        .migration_helper = Address.fromHex("0x11cfa7e034dafb7439cc1cc8b6e547f5c82ad021") catch unreachable,
        .locked_migration_controller = Address.fromHex("0xf91c34ed840889ed96f806f882fd50506a336edb") catch unreachable,
        .unlocked_migration_controller = Address.fromHex("0x056138ef5660f7113a3b0adc08ac3683310e7fbc") catch unreachable,

        // Deployment blocks (verified from on-protocol)
        .v1_deployment_block = 10893210, // Fresh V1+V2 redeployment on Sepolia
        .v2_deployment_block = 10893210, // Fresh V1+V2 redeployment on Sepolia

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

        // V2 Mainnet Contracts (ENSv2 deployment)
        .root_registry = Address.fromHex("0xc960f7217d3643b525ef36bec8adf86953cd9ab8") catch unreachable,
        .eth_registry = Address.fromHex("0xdedb92913a25abe1f7bcdd85d8a344a43b398b67") catch unreachable,
        .ens_v1_resolver = Address.fromHex("0x422484c2d51f92830bfb563fa5e172aa2d8b884b") catch unreachable,
        .ens_v2_resolver = Address.fromHex("0x6a923e0b9d722510b268280a381878818841629c") catch unreachable,
        .permissioned_resolver_impl = Address.fromHex("0xdce5205a553573ffd47629327dddf36186022ffa") catch unreachable,
        .public_resolver_set = Address.fromHex("0xfef98bae02b882b00efa02f3d7b379bee6cda86b") catch unreachable,
        .public_resolver_v2 = Address.fromHex("0x5239a812ec9a62f46dbb5de8f346c8efe7553a9f") catch unreachable,
        .managed_universal_resolver_proxy = Address.fromHex("0x6d80f2172cfdec5730fe683860c33d26fc42e6f1") catch unreachable,
        .upgradable_universal_resolver_proxy = Address.fromHex("0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe") catch unreachable,
        .universal_resolver_v2 = Address.fromHex("0x2f8a180604c42457cb56c7c4f708748ff1f91df1") catch unreachable,
        .eth_registrar_v2 = Address.fromHex("0x8c2e866b439358c41ae05de9cbe8a00bfefaffca") catch unreachable,
        .batch_registrar = Address.fromHex("0xb39c2da7143dffa4a097970887fa6f1d17c1d60f") catch unreachable,
        .testnet_v1_premigration_registrar = Address.fromHex("0xdf60c561ca35ad3c89d24bba854654b1c3477078") catch unreachable,
        .dns_v1_mirror_root_batch_registrar = Address.fromHex("0x9c53569d0c545a6743d6073a081acb977154eaf9") catch unreachable,
        .eth_reverse_registrar = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable, // TBD
        .approved_upgrade_gate = Address.fromHex("0x2c83019d86ff3be9cc269687215f4731158a8b6f") catch unreachable,
        .contract_namer = Address.fromHex("0xfc8bf9234969d6b85729b756fa9e14bb84a06754") catch unreachable,
        .graveyard = Address.fromHex("0x802453f2f077d5a0c3d0f9a6eb2a36dcfa3c6e0d") catch unreachable,
        .hca_factory = Address.fromHex("0x358680728dedb552adaa9f5eb5d4395b291cf943") catch unreachable,
        .label_store = Address.fromHex("0x23ea712da760c4e09fc9be108f1f1da6d5d6d053") catch unreachable,
        .standard_rent_price_oracle = Address.fromHex("0xe19d37839f42f7d2694d8c5712f412c66a218161") catch unreachable,
        .user_registry_impl = Address.fromHex("0x0f99e7ea74903afcb7224d0354fd7428a6f92917") catch unreachable,
        .verifiable_factory = Address.fromHex("0xd2a632d8a8b67c2c4398c255cbd7af8dd7236198") catch unreachable,
        .wrapper_registry_impl = Address.fromHex("0x9d9d230d9b894d3cc14fc7801031f45cd5007f18") catch unreachable,

        // Test-only mocks (zero on mainnet — not deployed)
        .mock_dai = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable,
        .mock_usdc = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable,

        // Migration Contracts (V2 mainnet deployment)
        .migration_helper = Address.fromHex("0x11cfa7e034dafb7439cc1cc8b6e547f5c82ad021") catch unreachable,
        .locked_migration_controller = Address.fromHex("0xf91c34ed840889ed96f806f882fd50506a336edb") catch unreachable,
        .unlocked_migration_controller = Address.fromHex("0x056138ef5660f7113a3b0adc08ac3683310e7fbc") catch unreachable,

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
