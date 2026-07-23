//! Declarative event-dispatch configuration for the Indexer.
//!
//! The event->handler tables and their two config-struct shapes, split out of
//! indexer.zig. Handlers are referenced as `Indexer.<handler>` (they are aliases on
//! the Indexer struct); indexer.zig re-exports every table/struct here as
//! `pub const X = event_config.X;`, so all existing `Indexer.X` uses are unchanged.

const abi = @import("abi_eth.zig");
const models = @import("../types/models.zig");
const rpc = @import("../rpc/client.zig");
const Hash = @import("../types/hash.zig").Hash;
const Address = @import("../types/address.zig").Address;
const Indexer = @import("indexer.zig").Indexer;

// Event configuration tables for declarative event indexing
pub const RegistryEventConfig = struct {
    event_hash: Hash,
    handler: *const fn (*Indexer, models.Protocol, rpc.Log) anyerror!void,
    name: []const u8,
};

pub const ETH_REGISTRY_EVENTS = [_]RegistryEventConfig{
    .{ .event_hash = abi.EventSignatures.name_registered_hash, .handler = Indexer.handleNameRegistered, .name = "NameRegistered" },
    .{ .event_hash = abi.EventSignatures.name_renewed_hash, .handler = Indexer.handleNameRenewed, .name = "NameRenewed" },
    .{ .event_hash = abi.EventSignatures.name_burned_hash, .handler = Indexer.handleNameBurned, .name = "NameBurned" },
    .{ .event_hash = abi.EventSignatures.token_regenerated_hash, .handler = Indexer.handleTokenRegenerated, .name = "TokenRegenerated" },
    .{ .event_hash = abi.EventSignatures.eac_roles_changed_hash, .handler = Indexer.handleEACRolesChanged, .name = "EACRolesChanged" },
    // LabelRegistered on the main ETH Registry happens during V1→V2 migration
    // (migration controllers call ETHRegistry directly, not through a subregistry)
    .{ .event_hash = abi.EventSignatures.label_registered_hash, .handler = Indexer.handleLabelRegistered, .name = "LabelRegistered" },
};

pub const ETH_REGISTRAR_EVENTS = [_]RegistryEventConfig{
    .{ .event_hash = abi.EventSignatures.commitment_made_hash, .handler = Indexer.handleCommitmentMade, .name = "CommitmentMade" },
    .{ .event_hash = abi.EventSignatures.eth_name_registered_hash, .handler = Indexer.handleETHNameRegistered, .name = "ETH NameRegistered" },
    .{ .event_hash = abi.EventSignatures.eth_name_renewed_hash, .handler = Indexer.handleETHNameRenewed, .name = "ETH NameRenewed" },
};

// ENS-specific subregistry events from PermissionedRegistry (and UserRegistry/WrapperRegistry)
pub const SUBREGISTRY_ENS_EVENTS = [_]RegistryEventConfig{
    .{ .event_hash = abi.EventSignatures.label_registered_hash, .handler = Indexer.handleLabelRegistered, .name = "LabelRegistered" },
    .{ .event_hash = abi.EventSignatures.label_reserved_hash, .handler = Indexer.handleLabelReserved, .name = "LabelReserved" },
    .{ .event_hash = abi.EventSignatures.label_unregistered_hash, .handler = Indexer.handleLabelUnregistered, .name = "LabelUnregistered" },
    .{ .event_hash = abi.EventSignatures.expiry_updated_hash, .handler = Indexer.handleExpiryUpdated, .name = "ExpiryUpdated" },
    .{ .event_hash = abi.EventSignatures.parent_updated_hash, .handler = Indexer.handleParentUpdated, .name = "ParentUpdated" },
    .{ .event_hash = abi.EventSignatures.subregistry_updated_hash, .handler = Indexer.handleSubregistryUpdated, .name = "SubregistryUpdated" },
    .{ .event_hash = abi.EventSignatures.resolver_updated_hash, .handler = Indexer.handleResolverUpdated, .name = "ResolverUpdated" },
    .{ .event_hash = abi.EventSignatures.token_regenerated_hash, .handler = Indexer.handleTokenRegenerated, .name = "TokenRegenerated" },
    .{ .event_hash = abi.EventSignatures.eac_roles_changed_hash, .handler = Indexer.handleEACRolesChanged, .name = "EACRolesChanged" },
};

// TransferSingle is ERC1155 standard - uses topic-only query with two-stage filtering:
// 1) Token ID entropy filter: ENS uses hash-like IDs (>2^64), most ERC1155s use small sequential IDs
// 2) Known subregistry HashSet filter: O(1) lookup
// This achieves O(1) RPC scalability regardless of subregistry count
pub const SUBREGISTRY_TRANSFER_EVENT = RegistryEventConfig{
    .event_hash = abi.EventSignatures.transfer_single_hash,
    .handler = Indexer.handleTransfer,
    .name = "TransferSingle",
};

// Resolver events have different handler signature (include resolver address)
pub const ResolverEventConfig = struct {
    event_hash: Hash,
    handler: *const fn (*Indexer, models.Protocol, Address, rpc.Log) anyerror!void,
    name: []const u8,
};

pub const RESOLVER_EVENTS = [_]ResolverEventConfig{
    // Legacy resolver events (2017 Public Resolver: 0x112234455c3a32fd11230c42e7bccd4a84e02010)
    .{ .event_hash = abi.EventSignatures.legacy_addr_changed_hash, .handler = Indexer.handleLegacyAddrChanged, .name = "AddrChanged (legacy)" },
    .{ .event_hash = abi.EventSignatures.legacy_content_changed_hash, .handler = Indexer.handleLegacyContentChanged, .name = "ContentChanged (legacy)" },
    // Modern resolver events (EIP-2304+)
    .{ .event_hash = abi.EventSignatures.address_changed_hash, .handler = Indexer.handleAddressChanged, .name = "AddressChanged" },
    .{ .event_hash = abi.EventSignatures.content_hash_changed_hash, .handler = Indexer.handleContentHashChanged, .name = "ContenthashChanged" },
    .{ .event_hash = abi.EventSignatures.text_changed_hash, .handler = Indexer.handleTextChanged, .name = "TextChanged" },
    .{ .event_hash = abi.EventSignatures.legacy_text_changed_hash, .handler = Indexer.handleLegacyTextChanged, .name = "TextChanged (legacy)" },
    .{ .event_hash = abi.EventSignatures.authorisation_changed_hash, .handler = Indexer.handleAuthorisationChanged, .name = "AuthorisationChanged" },
    .{ .event_hash = abi.EventSignatures.approved_hash, .handler = Indexer.handleApproved, .name = "Approved" },
    .{ .event_hash = abi.EventSignatures.dns_record_changed_hash, .handler = Indexer.handleDnsRecordChanged, .name = "DNSRecordChanged" },
    .{ .event_hash = abi.EventSignatures.dns_record_deleted_hash, .handler = Indexer.handleDnsRecordDeleted, .name = "DNSRecordDeleted" },
    .{ .event_hash = abi.EventSignatures.dns_zonehash_changed_hash, .handler = Indexer.handleDnsZonehashChanged, .name = "DNSZonehashChanged" },
    .{ .event_hash = abi.EventSignatures.abi_changed_hash, .handler = Indexer.handleABIChanged, .name = "ABIChanged" },
    .{ .event_hash = abi.EventSignatures.pubkey_changed_hash, .handler = Indexer.handlePubkeyChanged, .name = "PubkeyChanged" },
    .{ .event_hash = abi.EventSignatures.name_changed_hash, .handler = Indexer.handleNameChanged, .name = "NameChanged" },
    .{ .event_hash = abi.EventSignatures.interface_changed_hash, .handler = Indexer.handleInterfaceChanged, .name = "InterfaceChanged" },
    .{ .event_hash = abi.EventSignatures.version_changed_hash, .handler = Indexer.handleVersionChanged, .name = "VersionChanged" },
    .{ .event_hash = abi.EventSignatures.alias_changed_hash, .handler = Indexer.handleAliasChanged, .name = "AliasChanged" },
    .{ .event_hash = abi.EventSignatures.eac_roles_changed_hash, .handler = Indexer.handleResolverEACRolesChanged, .name = "EACRolesChanged" },
    .{ .event_hash = abi.EventSignatures.named_resource_hash, .handler = Indexer.handleNamedResource, .name = "NamedResource" },
    .{ .event_hash = abi.EventSignatures.named_text_resource_hash, .handler = Indexer.handleNamedTextResource, .name = "NamedTextResource" },
    .{ .event_hash = abi.EventSignatures.named_data_resource_hash, .handler = Indexer.handleNamedDataResource, .name = "NamedDataResource" },
    .{ .event_hash = abi.EventSignatures.named_addr_resource_hash, .handler = Indexer.handleNamedAddrResource, .name = "NamedAddrResource" },
};

// ========================================================================
// V1 EVENT CONFIGURATIONS (ENS V1 - Mainnet)
// ========================================================================

// ENS Registry events (0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e)
pub const V1_REGISTRY_EVENTS = [_]RegistryEventConfig{
    .{ .event_hash = abi.EventSignatures.new_owner_hash, .handler = Indexer.handleV1NewOwner, .name = "NewOwner" },
    .{ .event_hash = abi.EventSignatures.registry_transfer_hash, .handler = Indexer.handleV1RegistryTransfer, .name = "RegistryTransfer" },
    .{ .event_hash = abi.EventSignatures.new_resolver_hash, .handler = Indexer.handleV1NewResolver, .name = "NewResolver" },
    .{ .event_hash = abi.EventSignatures.new_ttl_hash, .handler = Indexer.handleV1NewTTL, .name = "NewTTL" },
};

// Name Wrapper events (0xD4416b13d2b3a9aBae7AcD5D6C2BbDBE25686401)
pub const V1_NAME_WRAPPER_EVENTS = [_]RegistryEventConfig{
    .{ .event_hash = abi.EventSignatures.name_wrapped_hash, .handler = Indexer.handleV1NameWrapped, .name = "NameWrapped" },
    .{ .event_hash = abi.EventSignatures.name_unwrapped_hash, .handler = Indexer.handleV1NameUnwrapped, .name = "NameUnwrapped" },
    .{ .event_hash = abi.EventSignatures.fuses_set_hash, .handler = Indexer.handleV1FusesSet, .name = "FusesSet" },
    .{ .event_hash = abi.EventSignatures.expiry_extended_hash, .handler = Indexer.handleV1ExpiryExtended, .name = "ExpiryExtended" },
    .{ .event_hash = abi.EventSignatures.transfer_single_hash, .handler = Indexer.handleV1NameWrapperTransferSingle, .name = "NameWrapper TransferSingle" },
    .{ .event_hash = abi.EventSignatures.transfer_batch_hash, .handler = Indexer.handleV1NameWrapperTransferBatch, .name = "NameWrapper TransferBatch" },
};

// Base Registrar events (0x57f1887a8BF19b14fC0dF6Fd9B2acc9Af147eA85)
pub const V1_BASE_REGISTRAR_EVENTS = [_]RegistryEventConfig{
    .{ .event_hash = abi.EventSignatures.erc721_transfer_hash, .handler = Indexer.handleV1ERC721Transfer, .name = "Transfer" },
    .{ .event_hash = abi.EventSignatures.base_registrar_name_registered_hash, .handler = Indexer.handleV1BaseRegistrarNameRegistered, .name = "NameRegistered" },
    .{ .event_hash = abi.EventSignatures.base_registrar_name_renewed_hash, .handler = Indexer.handleV1BaseRegistrarNameRenewed, .name = "NameRenewed" },
    .{ .event_hash = abi.EventSignatures.controller_added_hash, .handler = Indexer.handleV1ControllerAdded, .name = "ControllerAdded" },
    .{ .event_hash = abi.EventSignatures.controller_removed_hash, .handler = Indexer.handleV1ControllerRemoved, .name = "ControllerRemoved" },
    // Basenames (Base mainnet): registerWithRecord is the canonical registration
    // flow and emits ONLY this event (plain NameRegistered never fires there).
    // Signature-disjoint from every ENS registrar topic — inert off Base.
    .{ .event_hash = abi.EventSignatures.basenames_registrar_name_registered_with_record_hash, .handler = Indexer.handleBasenamesRegistrarNameRegisteredWithRecord, .name = "NameRegisteredWithRecord (basenames)" },
};

// ETH Registrar Controller events
// Multiple controllers have existed (legacy 5/4-param and current 7/5-param
// with referrer). Register both signatures — the handler picks the right
// decoding path based on data length.
pub const V1_ETH_CONTROLLER_EVENTS = [_]RegistryEventConfig{
    .{ .event_hash = abi.EventSignatures.controller_name_registered_hash, .handler = Indexer.handleV1ETHControllerNameRegistered, .name = "NameRegistered" },
    .{ .event_hash = abi.EventSignatures.wrapped_controller_name_registered_hash, .handler = Indexer.handleV1ETHControllerNameRegistered6Arg, .name = "NameRegistered (6-arg)" },
    .{ .event_hash = abi.EventSignatures.unwrapped_controller_name_registered_hash, .handler = Indexer.handleV1ETHControllerNameRegistered7Arg, .name = "NameRegistered (7-arg)" },
    .{ .event_hash = abi.EventSignatures.controller_name_renewed_hash, .handler = Indexer.handleV1ETHControllerNameRenewed, .name = "NameRenewed" },
    .{ .event_hash = abi.EventSignatures.unwrapped_controller_name_renewed_hash, .handler = Indexer.handleV1ETHControllerNameRenewedWithReferrer, .name = "NameRenewed (with referrer)" },
    // Basenames (Base mainnet) controller variants — signature-disjoint from every
    // ENS controller topic above, so they can never fire on ENS networks. Both
    // Basenames controllers (legacy + upgradeable proxy) are reached the same way
    // the ENS ones are: registrar ControllerAdded discovery + the config fallback.
    .{ .event_hash = abi.EventSignatures.basenames_controller_name_registered_hash, .handler = Indexer.handleBasenamesControllerNameRegistered, .name = "NameRegistered (basenames)" },
    .{ .event_hash = abi.EventSignatures.basenames_controller_name_renewed_hash, .handler = Indexer.handleBasenamesControllerNameRenewed, .name = "NameRenewed (basenames)" },
};

// Reverse Registrar events (0xa58E81fe9b61B5c3fE2AFD33CF304c454AbFc7Cb)
pub const V1_REVERSE_REGISTRAR_EVENTS = [_]RegistryEventConfig{
    .{ .event_hash = abi.EventSignatures.reverse_claimed_hash, .handler = Indexer.handleV1ReverseClaimed, .name = "ReverseClaimed" },
};

// V2 ETH Reverse Registrar events (L2ReverseRegistrar / StandaloneReverseRegistrar).
// V2 emits `NameForAddrChanged(address indexed addr, string name)` — there is
// no V1-style `ReverseClaimed(addr, node)` since V2 stores the name directly
// on the reverse registrar rather than going through a separate resolver.
pub const V2_REVERSE_REGISTRAR_EVENTS = [_]RegistryEventConfig{
    .{ .event_hash = abi.EventSignatures.name_for_addr_changed_hash, .handler = Indexer.handleV2NameForAddrChanged, .name = "NameForAddrChanged" },
};

// ETHRenewerV1 — standalone renewer emitting the same eth-registrar NameRenewed.
pub const V2_ETH_RENEWER_EVENTS = [_]RegistryEventConfig{
    .{ .event_hash = abi.EventSignatures.eth_name_renewed_hash, .handler = Indexer.handleETHNameRenewed, .name = "ETH NameRenewed" },
};

// LabelStore — on-chain labelhash->label dictionary; Label events heal unknown labels.
pub const V2_LABEL_STORE_EVENTS = [_]RegistryEventConfig{
    .{ .event_hash = abi.EventSignatures.label_store_label_hash, .handler = Indexer.handleLabelStoreLabel, .name = "Label" },
};
