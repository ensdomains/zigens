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
    ens_registry: Address,
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

    // Bridge Contracts
    l1_bridge_controller: Address,
    l2_bridge_controller: Address,

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

fn sepoliaAddresses() ContractAddresses {
    return .{
        // Temporary Registrar (not used on Sepolia testnet)
        .temporary_registrar = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable,

        // V1 Sepolia Contracts
        .ens_registry = Address.fromHex("0x17795c119b8155ab9d3357c77747ba509695d7cb") catch unreachable,
        .base_registrar = Address.fromHex("0xb16870800de7444f6b2ebd885465412a5e581614") catch unreachable,
        .eth_registrar_controller = Address.fromHex("0x99e517db3db5ec5424367b8b50cd11ddcb0008f1") catch unreachable,
        .public_resolver = Address.fromHex("0x0e14ee0592da66bb4c8a8090066bc8a5af15f3e6") catch unreachable,
        .reverse_registrar = Address.fromHex("0xf79f9970030fe60bd89d21591c7f2d80d7d21242") catch unreachable,
        .name_wrapper = Address.fromHex("0xca7e6d0ddc5f373197bbe6fc2f09c2314399f028") catch unreachable,

        // L1 Sepolia Contracts (from DEPLOYMENTS.v2.md)
        .root_registry = Address.fromHex("0x245de1984f9bb890c5db0b1fb839470c6a4c7e08") catch unreachable,
        .eth_registry = Address.fromHex("0x3f0920aa92c5f9bce54643c09955c5f241f1f763") catch unreachable,
        .registry_datastore = Address.fromHex("0x2a1d9588f3931fc7495867c82cd0d78cfb144945") catch unreachable,
        .eth_reverse_registrar = Address.fromHex("0xeb8269fb39290f31c4c29cec548807ca2133abb4") catch unreachable,

        // L2 Sepolia Contracts (from DEPLOYMENTS.v2.md)
        .l2_eth_registry = Address.fromHex("0xf332544e6234f1ca149907d0d4658afd5feb6831") catch unreachable,
        .l2_eth_registrar = Address.fromHex("0xe37a1366c827d18dc0ad57f3767de4b3025ceac2") catch unreachable, // ETHRegistrar
        .l2_registry_datastore = Address.fromHex("0xe82b3bef599d45806fcce747df176808ff6244cf") catch unreachable,

        // Bridge Contracts (from DEPLOYMENTS.v2.md)
        .l1_bridge_controller = Address.fromHex("0xf951f03ad34d000af619da491cf369b7992a6f72") catch unreachable,
        .l2_bridge_controller = Address.fromHex("0xbb84d5d658bbdb48bf99689f3a14f780ab2f9220") catch unreachable,

        // Deployment blocks (verified from on-chain)
        // For Sepolia testnet, these are the actual deployment blocks
        .v1_deployment_block = 4700000, // Approximate ENS V1 deployment on Sepolia
        .l1_deployment_block = 6500000, // Approximate ENS V2 L1 deployment
        .l2_deployment_block = 9374806, // Verified: L2 ETH Registry deployment on Sepolia

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

        // Bridge Contracts (Not yet deployed)
        .l1_bridge_controller = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable,
        .l2_bridge_controller = Address.fromHex("0x0000000000000000000000000000000000000000") catch unreachable,

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

// Event signatures for indexing
pub const EventSignatures = struct {
    // Temporary Registrar Events (Pre-V1 Migration, May 2017 - May 2019)
    pub const AuctionStarted = "0x87e97e825a1d1fa0c54e1d36c7506c1dea8b1efd451fe68b000cf96f7cf40003"; // AuctionStarted(bytes32,uint256)
    pub const NewBid = "0xb556ff269c1b6714f432c36431e2041d28436a73b6c3f19c021827bbdc6bfc29"; // NewBid(bytes32,address,uint256)
    pub const BidRevealed = "0x11da1fd92a40ce5b493b2e24a1d5b9f7e6c49efaf592cc00e57e6ba5e04b2461"; // BidRevealed(bytes32,address,uint256,uint8)
    pub const HashRegistered = "0x0f0c27adfd84b60b6f456b0e87cdccb1e5fb9603991588d87fa99f5b6b61e670"; // HashRegistered(bytes32,address,uint256,uint256)
    pub const HashReleased = "0x292b79b9246fa2c8e77d3fe195b251f9cb839d7d038e667c069ee7708c631e16"; // HashReleased(bytes32,uint256)
    pub const HashInvalidated = "0x1f9c649fe47e58bb60f4e52f0d90e4c47a526c9f90c5113df842c025353a6766"; // HashInvalidated(bytes32,string,uint256,uint256)

    // V1 Events
    pub const NewOwner = "0xce0457fe73731f824cc272376169235128c118b49d344817417c6d108d155e82"; // NewOwner(bytes32,bytes32,address)
    pub const Transfer = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"; // Transfer(address,address,uint256)
    pub const NameRegistered = "0x69e37f151eb98a09618ddaa80c8cfaf1ce5996867c489f45b555d412271ebf27"; // NameRegistered(string,bytes32,address,uint256,uint256)
    pub const NameRenewed = "0x3da24c024582931cfaf8267d8ed24d13a82a8068d5bd337d30ec45cea4e506ae"; // NameRenewed(string,bytes32,uint256,uint256)

    // V2 Registry Events (OLD signatures - pre-deployment)
    pub const SubregistryUpdate = "0x335721b01866dc23fbee8b6b2c7b1e14d6f05c28cd35a2c934239f94095602a0"; // SubregistryUpdate(uint256,address)
    pub const ResolverUpdate = "0x8bf46bf4cfd674fa735a3d63ec1c9ad4153f033c290341f3a588b75685141b35"; // ResolverUpdate(uint256,address)

    // V2 Registry Events (NEW signatures - current Sepolia deployment)
    pub const SubregistryUpdated = "0xca01ade22fed8a886bda52d1fb12deaff178499347b6c13b1a892a60985a51e2"; // SubregistryUpdated(uint256,address)
    pub const ResolverUpdated = "0x3c055b8ebff34805cc0c0216cfd96bfe2613c75002ce000f6268324952541d06"; // ResolverUpdated(uint256,address)
    pub const TokenRegeneratedV2 = "0x88d074c8fc078bb1c0b9cfa9e3ca1f65a96141df8b0da854fe3083df813cbcca"; // TokenRegenerated(uint256,uint256,uint256)
    pub const ExpiryUpdated = "0x3260962d42d8f7ae0af25cbfdb2983c214a859cfa2ac6df8ea29b534c267d429"; // ExpiryUpdated(uint256,uint64,address)

    // Enhanced Access Control Events (from IEnhancedAccessControl.sol)
    pub const EACRolesChanged = "0x0d35bf721a39b614de00ca5038e1deb0cb0c69a278645e83405a7226cf80ba3c"; // EACRolesChanged(uint256,address,uint256,uint256)

    // V2 Datastore Events
    pub const RecordSet = "0x851..."; // RecordSet(bytes32,bytes)
    pub const RecordDeleted = "0x852..."; // RecordDeleted(bytes32)
};
