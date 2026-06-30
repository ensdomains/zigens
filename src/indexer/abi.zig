// ============================================================================
// Event signatures and their compile-time keccak-256 hashes.
//
// Single source of truth for which on-chain events the indexer cares about.
// `abi_eth.zig` re-exports `EventSignatures` so handler files can reach the
// hashes via `abi.EventSignatures.<name>_hash` (used as `topics[0]` matchers
// in the dispatcher hot loop).
//
// Why these hashes live here and not in eth.zig:
//   * The signature *strings* are project-specific knowledge — every indexer
//     cares about a different set of events. A library can't enumerate them
//     for us.
//   * The *hashes* are computed at comptime via `keccak.eventSignature`, which
//     produces static [32]u8 constants baked into the binary. eth.zig's
//     keccak is a C library (XKCP) and runtime-only; using it would force
//     lazy initialization of every signature for no correctness benefit.
//
// Historical: this file used to also contain an `ABI` struct with hand-rolled
// decoders (decodeUint256/decodeAddress/decodeString/...). All handlers were
// migrated to `abi_eth.zig` (eth.zig-backed schema-driven decode) and the
// dead struct + its tests were removed once the new path was verified end-
// to-end on real on-chain data.
// ============================================================================

const Hash = @import("../types/hash.zig").Hash;
const keccak = @import("../utils/keccak.zig");

/// Compute event signature hash at compile time
inline fn eventHash(comptime sig: []const u8) Hash {
    const hash_bytes = keccak.eventSignature(sig);
    return Hash{ .bytes = hash_bytes };
}

/// Event signatures for ENSv2 contracts
pub const EventSignatures = struct {
    // ========================================================================
    // IRegistry events (from common/registry/interfaces/IRegistry.sol)
    // ========================================================================

    /// NameRegistered(uint256 indexed tokenId, string label, uint64 expiration, address registeredBy)
    pub const name_registered = "NameRegistered(uint256,string,uint64,address)";
    pub const name_registered_hash: Hash = eventHash(name_registered);

    /// NameRenewed(uint256 indexed tokenId, uint64 newExpiration, address renewedBy)
    pub const name_renewed = "NameRenewed(uint256,uint64,address)";
    pub const name_renewed_hash: Hash = eventHash(name_renewed);

    /// NameBurned(uint256 indexed tokenId, address burnedBy)
    pub const name_burned = "NameBurned(uint256,address)";
    pub const name_burned_hash: Hash = eventHash(name_burned);

    /// SubregistryUpdated(uint256 indexed id, address indexed subregistry, address indexed sender)
    pub const subregistry_updated = "SubregistryUpdated(uint256,address,address)";
    pub const subregistry_updated_hash: Hash = eventHash(subregistry_updated);

    /// ResolverUpdated(uint256 indexed id, address indexed resolver, address indexed sender)
    pub const resolver_updated = "ResolverUpdated(uint256,address,address)";
    pub const resolver_updated_hash: Hash = eventHash(resolver_updated);

    /// TokenRegenerated(uint256 oldTokenId, uint256 newTokenId)
    pub const token_regenerated = "TokenRegenerated(uint256,uint256)";
    pub const token_regenerated_hash: Hash = eventHash(token_regenerated);

    /// ExpiryUpdated(uint256 indexed tokenId, uint64 newExpiry, address changedBy)
    /// New event signature that replaces NameRenewed in the current V2 deployment
    pub const expiry_updated = "ExpiryUpdated(uint256,uint64,address)";
    pub const expiry_updated_hash: Hash = eventHash(expiry_updated);

    /// LabelRegistered(uint256 indexed tokenId, bytes32 indexed labelHash, string label, address owner, uint64 expiry, address indexed sender)
    /// Emitted when a label is registered (owner != 0) in PermissionedRegistry
    pub const label_registered = "LabelRegistered(uint256,bytes32,string,address,uint64,address)";
    pub const label_registered_hash: Hash = eventHash(label_registered);

    /// LabelReserved(uint256 indexed tokenId, bytes32 indexed labelHash, string label, uint64 expiry, address indexed sender)
    /// Emitted when a label is reserved (owner == 0) in PermissionedRegistry
    pub const label_reserved = "LabelReserved(uint256,bytes32,string,uint64,address)";
    pub const label_reserved_hash: Hash = eventHash(label_reserved);

    /// LabelUnregistered(uint256 indexed tokenId, address indexed sender)
    /// Emitted when a label is unregistered in PermissionedRegistry
    pub const label_unregistered = "LabelUnregistered(uint256,address)";
    pub const label_unregistered_hash: Hash = eventHash(label_unregistered);

    /// ParentUpdated(IRegistry indexed parent, string label, address indexed sender)
    /// Emitted when the parent of a registry is changed
    pub const parent_updated = "ParentUpdated(address,string,address)";
    pub const parent_updated_hash: Hash = eventHash(parent_updated);

    /// Label(bytes32 indexed labelHash, string label)
    /// Emitted by the LabelStore contract: an on-chain labelhash->preimage dictionary
    /// used to heal unknown labels.
    pub const label_store_label = "Label(bytes32,string)";
    pub const label_store_label_hash: Hash = eventHash(label_store_label);

    // ========================================================================
    // Enhanced Access Control events (from common/access-control/interfaces/IEnhancedAccessControl.sol)
    // ========================================================================

    /// EACRolesChanged(uint256 indexed resource, address indexed account, uint256 oldRoleBitmap, uint256 newRoleBitmap)
    /// Emitted when roles are changed for an account on a resource (tokenId)
    pub const eac_roles_changed = "EACRolesChanged(uint256,address,uint256,uint256)";
    pub const eac_roles_changed_hash: Hash = eventHash(eac_roles_changed);

    // ========================================================================
    // IETHRegistrar events (from L2/registrar/interfaces/IETHRegistrar.sol)
    // ========================================================================

    /// CommitmentMade(bytes32 commitment)
    pub const commitment_made = "CommitmentMade(bytes32)";
    pub const commitment_made_hash: Hash = eventHash(commitment_made);

    /// IETHRegistrar.NameRegistered (extended version with payment details)
    /// NameRegistered(uint256 indexed tokenId, string label, address owner, IRegistry subregistry, address resolver, uint64 duration, IERC20 paymentToken, bytes32 referrer, uint256 base, uint256 premium)
    pub const eth_name_registered = "NameRegistered(uint256,string,address,address,address,uint64,address,bytes32,uint256,uint256)";
    pub const eth_name_registered_hash: Hash = eventHash(eth_name_registered);

    /// IETHRegistrar.NameRenewed (extended version with payment details)
    /// NameRenewed(uint256 indexed tokenId, string label, uint64 duration, uint64 newExpiry, IERC20 paymentToken, bytes32 referrer, uint256 base)
    pub const eth_name_renewed = "NameRenewed(uint256,string,uint64,uint64,address,bytes32,uint256)";
    pub const eth_name_renewed_hash: Hash = eventHash(eth_name_renewed);

    // ========================================================================
    // ERC1155 events (for ownership tracking)
    // ========================================================================

    /// TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value)
    pub const transfer_single = "TransferSingle(address,address,address,uint256,uint256)";
    pub const transfer_single_hash: Hash = eventHash(transfer_single);

    /// TransferBatch(address indexed operator, address indexed from, address indexed to, uint256[] ids, uint256[] values)
    pub const transfer_batch = "TransferBatch(address,address,address,uint256[],uint256[])";
    pub const transfer_batch_hash: Hash = eventHash(transfer_batch);

    /// Approval(address indexed owner, address indexed approved, uint256 indexed tokenId)
    pub const approval = "Approval(address,address,uint256)";
    pub const approval_hash: Hash = eventHash(approval);

    // ========================================================================
    // Resolver events (from resolver contracts)
    // ========================================================================

    /// AddrChanged(bytes32 indexed node, address a)
    /// Legacy resolver event (2017) — ETH address only (coinType=60)
    pub const legacy_addr_changed = "AddrChanged(bytes32,address)";
    pub const legacy_addr_changed_hash: Hash = eventHash(legacy_addr_changed);

    /// ContentChanged(bytes32 indexed node, bytes32 hash)
    /// Legacy resolver event (2017) — fixed bytes32 content hash
    pub const legacy_content_changed = "ContentChanged(bytes32,bytes32)";
    pub const legacy_content_changed_hash: Hash = eventHash(legacy_content_changed);

    /// AddressChanged(bytes32 indexed node, uint256 coinType, bytes newAddress)
    pub const address_changed = "AddressChanged(bytes32,uint256,bytes)";
    pub const address_changed_hash: Hash = eventHash(address_changed);

    /// ContenthashChanged(bytes32 indexed node, bytes hash)
    /// Note: lowercase 'h' in `Contenthash` — this is the canonical ENS event name
    /// emitted by both V1 PublicResolver and V2 PermissionedResolver / OwnedResolver.
    pub const content_hash_changed = "ContenthashChanged(bytes32,bytes)";
    pub const content_hash_changed_hash: Hash = eventHash(content_hash_changed);

    /// TextChanged(bytes32 indexed node, string indexed indexedKey, string key, string value)
    pub const text_changed = "TextChanged(bytes32,string,string,string)";
    pub const text_changed_hash: Hash = eventHash(text_changed);

    /// TextChanged(bytes32 indexed node, string indexed indexedKey, string value)
    /// Legacy 3-arg variant emitted by the 2017 LegacyPublicResolver. No `key`
    /// in the non-indexed payload — only the hashed indexed key is on-chain.
    pub const legacy_text_changed = "TextChanged(bytes32,string,string)";
    pub const legacy_text_changed_hash: Hash = eventHash(legacy_text_changed);

    /// AuthorisationChanged(bytes32 indexed node, address indexed owner, address indexed target, bool isAuthorised)
    /// Legacy V1 PublicResolver `Authorisable` mixin event.
    pub const authorisation_changed = "AuthorisationChanged(bytes32,address,address,bool)";
    pub const authorisation_changed_hash: Hash = eventHash(authorisation_changed);

    /// Approved(address owner, bytes32 indexed node, address indexed delegate, bool indexed approved)
    /// Per-name delegate approval (PublicResolver 2023+); the modern successor
    /// to AuthorisationChanged. Feeds resolver_approvals (context = NULL).
    pub const approved = "Approved(address,bytes32,address,bool)";
    pub const approved_hash: Hash = eventHash(approved);

    /// DNSRecordChanged(bytes32 indexed node, bytes name, uint16 resource, bytes record)
    /// ENSIP-17 DNS resolver event — V1 PublicResolver + V2 PublicResolverV2.
    pub const dns_record_changed = "DNSRecordChanged(bytes32,bytes,uint16,bytes)";
    pub const dns_record_changed_hash: Hash = eventHash(dns_record_changed);

    /// DNSRecordDeleted(bytes32 indexed node, bytes name, uint16 resource)
    /// ENSIP-17 DNS resolver event — V1 PublicResolver + V2 PublicResolverV2.
    pub const dns_record_deleted = "DNSRecordDeleted(bytes32,bytes,uint16)";
    pub const dns_record_deleted_hash: Hash = eventHash(dns_record_deleted);

    /// DNSZonehashChanged(bytes32 indexed node, bytes lastzonehash, bytes zonehash)
    /// ENSIP-17 DNS resolver event — V1 PublicResolver + V2 PublicResolverV2.
    pub const dns_zonehash_changed = "DNSZonehashChanged(bytes32,bytes,bytes)";
    pub const dns_zonehash_changed_hash: Hash = eventHash(dns_zonehash_changed);

    /// ABIChanged(bytes32 indexed node, uint256 indexed contentType)
    pub const abi_changed = "ABIChanged(bytes32,uint256)";
    pub const abi_changed_hash: Hash = eventHash(abi_changed);

    /// PubkeyChanged(bytes32 indexed node, bytes32 x, bytes32 y)
    pub const pubkey_changed = "PubkeyChanged(bytes32,bytes32,bytes32)";
    pub const pubkey_changed_hash: Hash = eventHash(pubkey_changed);

    /// NameChanged(bytes32 indexed node, string name)
    pub const name_changed = "NameChanged(bytes32,string)";
    pub const name_changed_hash: Hash = eventHash(name_changed);

    /// InterfaceChanged(bytes32 indexed node, bytes4 indexed interfaceID, address implementer)
    pub const interface_changed = "InterfaceChanged(bytes32,bytes4,address)";
    pub const interface_changed_hash: Hash = eventHash(interface_changed);

    /// VersionChanged(bytes32 indexed node, uint64 newVersion)
    pub const version_changed = "VersionChanged(bytes32,uint64)";
    pub const version_changed_hash: Hash = eventHash(version_changed);

    /// AliasChanged(bytes indexed indexedFromName, bytes indexed indexedToName, bytes fromName, bytes toName)
    pub const alias_changed = "AliasChanged(bytes,bytes,bytes,bytes)";
    pub const alias_changed_hash: Hash = eventHash(alias_changed);

    /// NamedResource(uint256 indexed resource, bytes name)
    /// Emitted when a named resource is set in PermissionedResolver
    pub const named_resource = "NamedResource(uint256,bytes)";
    pub const named_resource_hash: Hash = eventHash(named_resource);

    /// NamedTextResource(uint256 indexed resource, bytes name, bytes32 indexed keyHash, string key)
    /// Emitted when a named text resource is set in PermissionedResolver.
    /// NOTE: signature changed from the prior 3-arg form to 4 args (plaintext key
    /// appended) in the latest PermissionedResolver deployment.
    pub const named_text_resource = "NamedTextResource(uint256,bytes,bytes32,string)";
    pub const named_text_resource_hash: Hash = eventHash(named_text_resource);

    /// NamedAddrResource(uint256 indexed resource, bytes name, uint256 indexed coinType)
    /// Emitted when a named address resource is set in PermissionedResolver
    pub const named_addr_resource = "NamedAddrResource(uint256,bytes,uint256)";
    pub const named_addr_resource_hash: Hash = eventHash(named_addr_resource);

    /// NamedDataResource(uint256 indexed resource, bytes name, bytes32 indexed keyHash, string key)
    /// Emitted by the latest PermissionedResolver alongside `DataChanged`. Carries
    /// the plaintext key (the bytes32 hash is the topic) and the resource id.
    pub const named_data_resource = "NamedDataResource(uint256,bytes,bytes32,string)";
    pub const named_data_resource_hash: Hash = eventHash(named_data_resource);

    /// DataChanged(bytes32 indexed node, string indexedKey, string key, bytes value)
    /// New generic key/value record event in the latest PermissionedResolver.
    /// Mirrors `TextChanged` but the value is `bytes` instead of `string`.
    pub const data_changed = "DataChanged(bytes32,string,string,bytes)";
    pub const data_changed_hash: Hash = eventHash(data_changed);

    // ========================================================================
    // ENS Temporary Registrar events (Pre-V1 Migration, May 2017 - May 2019)
    // Address: 0x6090A6e47849629b7245Dfa1Ca21D94cd15878Ef
    // Deployed: Block 3327417 (May 2017)
    // Vickrey auction system for .eth second-level domains
    // ========================================================================

    /// AuctionStarted(bytes32 indexed hash, uint256 registrationDate)
    pub const auction_started = "AuctionStarted(bytes32,uint256)";
    pub const auction_started_hash: Hash = eventHash(auction_started);

    /// NewBid(bytes32 indexed hash, address indexed bidder, uint256 deposit)
    pub const new_bid = "NewBid(bytes32,address,uint256)";
    pub const new_bid_hash: Hash = eventHash(new_bid);

    /// BidRevealed(bytes32 indexed hash, address indexed owner, uint256 value, uint8 status)
    pub const bid_revealed = "BidRevealed(bytes32,address,uint256,uint8)";
    pub const bid_revealed_hash: Hash = eventHash(bid_revealed);

    /// HashRegistered(bytes32 indexed hash, address indexed owner, uint256 value, uint256 registrationDate)
    pub const hash_registered = "HashRegistered(bytes32,address,uint256,uint256)";
    pub const hash_registered_hash: Hash = eventHash(hash_registered);

    /// HashReleased(bytes32 indexed hash, uint256 value)
    pub const hash_released = "HashReleased(bytes32,uint256)";
    pub const hash_released_hash: Hash = eventHash(hash_released);

    /// HashInvalidated(bytes32 indexed hash, string indexed name, uint256 value, uint256 registrationDate)
    pub const hash_invalidated = "HashInvalidated(bytes32,string,uint256,uint256)";
    pub const hash_invalidated_hash: Hash = eventHash(hash_invalidated);

    // ========================================================================
    // ENS V1 Registry events (ENSRegistry.sol - post-2020 migration)
    // Address: 0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e
    // ========================================================================

    /// NewOwner(bytes32 indexed node, bytes32 indexed label, address owner)
    pub const new_owner = "NewOwner(bytes32,bytes32,address)";
    pub const new_owner_hash: Hash = eventHash(new_owner);

    /// Transfer(bytes32 indexed node, address owner)
    /// NOTE: This is ENS Registry Transfer, NOT ERC721 Transfer!
    pub const registry_transfer = "Transfer(bytes32,address)";
    pub const registry_transfer_hash: Hash = eventHash(registry_transfer);

    /// NewResolver(bytes32 indexed node, address resolver)
    pub const new_resolver = "NewResolver(bytes32,address)";
    pub const new_resolver_hash: Hash = eventHash(new_resolver);

    /// NewTTL(bytes32 indexed node, uint64 ttl)
    pub const new_ttl = "NewTTL(bytes32,uint64)";
    pub const new_ttl_hash: Hash = eventHash(new_ttl);

    // ========================================================================
    // ENS V1 Name Wrapper events (NameWrapper.sol)
    // Address: 0xD4416b13d2b3a9aBae7AcD5D6C2BbDBE25686401
    // Deployed: September 2022 (block 15628465)
    // ========================================================================

    /// NameWrapped(bytes32 indexed node, bytes name, address owner, uint32 fuses, uint64 expiry)
    pub const name_wrapped = "NameWrapped(bytes32,bytes,address,uint32,uint64)";
    pub const name_wrapped_hash: Hash = eventHash(name_wrapped);

    /// NameUnwrapped(bytes32 indexed node, address owner)
    pub const name_unwrapped = "NameUnwrapped(bytes32,address)";
    pub const name_unwrapped_hash: Hash = eventHash(name_unwrapped);

    /// FusesSet(bytes32 indexed node, uint32 fuses)
    pub const fuses_set = "FusesSet(bytes32,uint32)";
    pub const fuses_set_hash: Hash = eventHash(fuses_set);

    /// ExpiryExtended(bytes32 indexed node, uint64 expiry)
    pub const expiry_extended = "ExpiryExtended(bytes32,uint64)";
    pub const expiry_extended_hash: Hash = eventHash(expiry_extended);

    // ========================================================================
    // ENS V1 Base Registrar events (BaseRegistrarImplementation.sol)
    // Address: 0x57f1887a8BF19b14fC0dF6Fd9B2acc9Af147eA85
    // ========================================================================

    /// NameRegistered(uint256 indexed id, address indexed owner, uint256 expires)
    /// This is Base Registrar's NameRegistered, different from ETHRegistrarController
    pub const base_registrar_name_registered = "NameRegistered(uint256,address,uint256)";
    pub const base_registrar_name_registered_hash: Hash = eventHash(base_registrar_name_registered);

    /// NameRenewed(uint256 indexed id, uint256 expires)
    /// This is Base Registrar's NameRenewed
    pub const base_registrar_name_renewed = "NameRenewed(uint256,uint256)";
    pub const base_registrar_name_renewed_hash: Hash = eventHash(base_registrar_name_renewed);

    /// Transfer(address indexed from, address indexed to, uint256 indexed tokenId)
    /// ERC721 Transfer from Base Registrar
    pub const erc721_transfer = "Transfer(address,address,uint256)";
    pub const erc721_transfer_hash: Hash = eventHash(erc721_transfer);

    /// ControllerAdded(address indexed controller)
    pub const controller_added = "ControllerAdded(address)";
    pub const controller_added_hash: Hash = eventHash(controller_added);

    /// ControllerRemoved(address indexed controller)
    pub const controller_removed = "ControllerRemoved(address)";
    pub const controller_removed_hash: Hash = eventHash(controller_removed);

    // ========================================================================
    // ENS V1 ETH Registrar Controller events (ETHRegistrarController.sol)
    // Address: 0x59E16fcCd424Cc24e280Be16E11Bcd56fb0CE547 (legacy),
    //          0xb5778cf6... (current mainnet + fresh Sepolia deployment)
    //
    // Three historical NameRegistered signatures coexist on mainnet:
    //   1. Legacy 5-arg (LegacyEthRegistrarController, earliest deployment):
    //      NameRegistered(string,bytes32,address,uint256,uint256)
    //   2. Wrapped 6-arg (WrappedEthRegistrarController, ~block 16,925,618):
    //      NameRegistered(string,bytes32,address,uint256,uint256,uint256)
    //      Adds explicit baseCost/premium split.
    //   3. Unwrapped 7-arg (UnwrappedEthRegistrarController, newer + current
    //      Sepolia 0xb5778cf6...):
    //      NameRegistered(string,bytes32,address,uint256,uint256,uint256,bytes32)
    //      Adds non-indexed `referrer` (bytes32) at the tail.
    // All three share `bytes32 indexed label` (topic[1]) and
    // `address indexed owner` (topic[2]); only topic[0] (signature hash) and
    // the non-indexed data tail differ.
    // ========================================================================

    /// NameRegistered(string name, bytes32 indexed label, address indexed owner, uint256 cost, uint256 expires)
    /// Legacy 5-arg: original LegacyEthRegistrarController (no baseCost/premium split, no referrer)
    pub const controller_name_registered = "NameRegistered(string,bytes32,address,uint256,uint256)";
    pub const controller_name_registered_hash: Hash = eventHash(controller_name_registered);

    /// NameRegistered(string name, bytes32 indexed label, address indexed owner, uint256 baseCost, uint256 premium, uint256 expires)
    /// 6-arg WrappedEthRegistrarController: baseCost/premium split, no referrer.
    /// Mainnet-only (the fresh Sepolia deployment skipped this generation).
    pub const wrapped_controller_name_registered = "NameRegistered(string,bytes32,address,uint256,uint256,uint256)";
    pub const wrapped_controller_name_registered_hash: Hash = eventHash(wrapped_controller_name_registered);

    /// NameRegistered(string label, bytes32 indexed labelhash, address indexed owner, uint256 baseCost, uint256 premium, uint256 expires, bytes32 referrer)
    /// 7-arg UnwrappedEthRegistrarController: baseCost/premium split + non-indexed referrer tag.
    /// Also the current Sepolia deployment (0xb5778cf6...).
    pub const unwrapped_controller_name_registered = "NameRegistered(string,bytes32,address,uint256,uint256,uint256,bytes32)";
    pub const unwrapped_controller_name_registered_hash: Hash = eventHash(unwrapped_controller_name_registered);

    /// NameRenewed(string name, bytes32 indexed label, uint256 cost, uint256 expires)
    pub const controller_name_renewed = "NameRenewed(string,bytes32,uint256,uint256)";
    pub const controller_name_renewed_hash: Hash = eventHash(controller_name_renewed);

    /// NameRenewed(string label, bytes32 indexed labelhash, uint256 cost, uint256 expires, bytes32 referrer)
    /// 5-arg UnwrappedEthRegistrarController: adds non-indexed referrer tag at
    /// the data tail. Same labelhash indexed-topic shape as the legacy variant.
    /// Also the current Sepolia deployment.
    pub const unwrapped_controller_name_renewed = "NameRenewed(string,bytes32,uint256,uint256,bytes32)";
    pub const unwrapped_controller_name_renewed_hash: Hash = eventHash(unwrapped_controller_name_renewed);

    // ========================================================================
    // ENS V1 Reverse Registrar events (ReverseRegistrar.sol)
    // Address: 0xa58E81fe9b61B5c3fE2AFD33CF304c454AbFc7Cb
    // ========================================================================

    /// V1 ReverseRegistrar: ReverseClaimed(address indexed addr, bytes32 indexed node)
    pub const reverse_claimed = "ReverseClaimed(address,bytes32)";
    pub const reverse_claimed_hash: Hash = eventHash(reverse_claimed);

    /// V2 L2ReverseRegistrar / StandaloneReverseRegistrar:
    /// NameForAddrChanged(address indexed addr, string name)
    /// V2 reverse resolution stores the primary name directly on the reverse
    /// registrar rather than going through a node-keyed registry.
    pub const name_for_addr_changed = "NameForAddrChanged(address,string)";
    pub const name_for_addr_changed_hash: Hash = eventHash(name_for_addr_changed);

    // ========================================================================
    // Approval events (various contracts)
    // ========================================================================

    /// ApprovalForAll(address indexed owner, address indexed operator, bool approved)
    /// Used by: ENS Registry, Base Registrar, Name Wrapper, Public Resolver
    pub const approval_for_all = "ApprovalForAll(address,address,bool)";
    pub const approval_for_all_hash: Hash = eventHash(approval_for_all);

    /// TokenResource(uint256 indexed tokenId, uint256 indexed resource)
    /// Emitted when a token's resource is set during registration. Still emitted
    /// by PermissionedRegistry post-audit; not currently subscribed to.
    pub const token_resource = "TokenResource(uint256,uint256)";
    pub const token_resource_hash: Hash = eventHash(token_resource);

    // ========================================================================
    // PermissionedRegistry events
    // ========================================================================

    /// RegistryCreated()
    /// Emitted by PermissionedRegistry, WrapperRegistry, UserRegistry constructors.
    /// The cleanest signal to discover newly-deployed subregistries.
    pub const registry_created = "RegistryCreated()";
    pub const registry_created_hash: Hash = eventHash(registry_created);
};
