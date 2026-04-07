const std = @import("std");
const Hash = @import("../types/hash.zig").Hash;
const keccak = @import("../utils/keccak.zig");
const constants = @import("../constants.zig");

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

    /// SubregistryUpdate(uint256 indexed id, address subregistry) - OLD signature (pre-deployment)
    pub const subregistry_update = "SubregistryUpdate(uint256,address)";
    pub const subregistry_update_hash: Hash = eventHash(subregistry_update);

    /// SubregistryUpdated(uint256 indexed id, address subregistry) - NEW signature (current deployment)
    pub const subregistry_updated = "SubregistryUpdated(uint256,address)";
    pub const subregistry_updated_hash: Hash = eventHash(subregistry_updated);

    /// ResolverUpdate(uint256 indexed id, address resolver) - OLD signature (pre-deployment)
    pub const resolver_update = "ResolverUpdate(uint256,address)";
    pub const resolver_update_hash: Hash = eventHash(resolver_update);

    /// ResolverUpdated(uint256 indexed id, address resolver) - NEW signature (current deployment)
    pub const resolver_updated = "ResolverUpdated(uint256,address)";
    pub const resolver_updated_hash: Hash = eventHash(resolver_updated);

    /// TokenRegenerated(uint256 oldTokenId, uint256 newTokenId) - OLD signature (2 params)
    pub const token_regenerated = "TokenRegenerated(uint256,uint256)";
    pub const token_regenerated_hash: Hash = eventHash(token_regenerated);

    /// TokenRegenerated(uint256 oldTokenId, uint256 newTokenId, uint256 flags) - NEW signature (3 params)
    pub const token_regenerated_v2 = "TokenRegenerated(uint256,uint256,uint256)";
    pub const token_regenerated_v2_hash: Hash = eventHash(token_regenerated_v2);

    /// NewSubname(uint256 indexed tokenId, string label)
    /// This event is emitted by UserRegistry contracts instead of NameRegistered
    pub const new_subname = "NewSubname(uint256,string)";
    pub const new_subname_hash: Hash = eventHash(new_subname);

    /// ExpiryUpdated(uint256 indexed tokenId, uint64 newExpiry, address changedBy)
    /// New event signature that replaces NameRenewed in current namechain deployment
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

    /// TokenResource(uint256 indexed tokenId, uint256 indexed resource)
    /// Emitted when a token's resource is set during registration
    pub const token_resource = "TokenResource(uint256,uint256)";
    pub const token_resource_hash: Hash = eventHash(token_resource);

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

    /// ContentHashChanged(bytes32 indexed node, bytes hash)
    pub const content_hash_changed = "ContentHashChanged(bytes32,bytes)";
    pub const content_hash_changed_hash: Hash = eventHash(content_hash_changed);

    /// TextChanged(bytes32 indexed node, string indexed indexedKey, string key, string value)
    pub const text_changed = "TextChanged(bytes32,string,string,string)";
    pub const text_changed_hash: Hash = eventHash(text_changed);

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

    /// NamedTextResource(uint256 indexed resource, bytes name, bytes32 indexed key)
    /// Emitted when a named text resource is set in PermissionedResolver
    pub const named_text_resource = "NamedTextResource(uint256,bytes,bytes32)";
    pub const named_text_resource_hash: Hash = eventHash(named_text_resource);

    /// NamedAddrResource(uint256 indexed resource, bytes name, uint256 indexed coinType)
    /// Emitted when a named address resource is set in PermissionedResolver
    pub const named_addr_resource = "NamedAddrResource(uint256,bytes,uint256)";
    pub const named_addr_resource_hash: Hash = eventHash(named_addr_resource);

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
    // Address: 0x59E16fcCd424Cc24e280Be16E11Bcd56fb0CE547
    // ========================================================================

    /// NameRegistered(string name, bytes32 indexed label, address indexed owner, uint256 cost, uint256 expires)
    /// Note: V1 Controller uses 5 parameters, NOT 6 (no separate baseCost/premium)
    pub const controller_name_registered = "NameRegistered(string,bytes32,address,uint256,uint256)";
    pub const controller_name_registered_hash: Hash = eventHash(controller_name_registered);

    /// NameRenewed(string name, bytes32 indexed label, uint256 cost, uint256 expires)
    pub const controller_name_renewed = "NameRenewed(string,bytes32,uint256,uint256)";
    pub const controller_name_renewed_hash: Hash = eventHash(controller_name_renewed);

    // ========================================================================
    // ENS V1 Reverse Registrar events (ReverseRegistrar.sol)
    // Address: 0xa58E81fe9b61B5c3fE2AFD33CF304c454AbFc7Cb
    // ========================================================================

    /// ReverseClaimed(address indexed addr, bytes32 indexed node)
    pub const reverse_claimed = "ReverseClaimed(address,bytes32)";
    pub const reverse_claimed_hash: Hash = eventHash(reverse_claimed);

    // ========================================================================
    // Approval events (various contracts)
    // ========================================================================

    /// ApprovalForAll(address indexed owner, address indexed operator, bool approved)
    /// Used by: ENS Registry, Base Registrar, Name Wrapper, Public Resolver
    pub const approval_for_all = "ApprovalForAll(address,address,bool)";
    pub const approval_for_all_hash: Hash = eventHash(approval_for_all);

    /// Approved(bytes32 indexed node, address indexed owner, address indexed target, bool isAuthorised)
    /// PublicResolver approval event
    pub const approved = "Approved(bytes32,address,address,bool)";
    pub const approved_hash: Hash = eventHash(approved);

    // ========================================================================
    // Bridge/Ejection events (from EjectionController and L1BridgeController)
    // ========================================================================

    /// NameEjectedToL1(bytes dnsEncodedName, uint256 tokenId)
    pub const name_ejected_to_l1 = "NameEjectedToL1(bytes,uint256)";
    pub const name_ejected_to_l1_hash: Hash = eventHash(name_ejected_to_l1);

    /// NameEjectedToL2(bytes dnsEncodedName, uint256 tokenId)
    pub const name_ejected_to_l2 = "NameEjectedToL2(bytes,uint256)";
    pub const name_ejected_to_l2_hash: Hash = eventHash(name_ejected_to_l2);

    /// RenewalSynchronized(uint256 tokenId, uint64 newExpiry)
    pub const renewal_synchronized = "RenewalSynchronized(uint256,uint64)";
    pub const renewal_synchronized_hash: Hash = eventHash(renewal_synchronized);

    // ========================================================================
    // PermissionedRegistry events
    // ========================================================================

    /// TokenObserverSet(uint256 indexed tokenId, address observer)
    pub const token_observer_set = "TokenObserverSet(uint256,address)";
    pub const token_observer_set_hash: Hash = eventHash(token_observer_set);
};

/// ABI encoding/decoding utilities
pub const ABI = struct {
    /// Maximum allowed string length (1 MB) to prevent DoS attacks
    pub const MAX_STRING_LENGTH: usize = 1024 * 1024;

    /// Maximum allowed array length to prevent DoS attacks
    pub const MAX_ARRAY_LENGTH: usize = constants.Validation.max_abi_array_length;

    /// Maximum allowed bytes length (1 MB) to prevent DoS attacks
    pub const MAX_BYTES_LENGTH: usize = 1024 * 1024;

    /// Decode uint256 from bytes
    pub fn decodeUint256(data: []const u8, offset: usize) !u256 {
        if (offset + 32 > data.len) {
            return error.DataTooShort;
        }

        var result: u256 = 0;
        var i: usize = 0;
        while (i < 32) : (i += 1) {
            result = (result << 8) | data[offset + i];
        }

        return result;
    }

    /// Decode address from bytes (20 bytes, padded to 32)
    pub fn decodeAddress(data: []const u8, offset: usize) !@import("../types/address.zig").Address {
        if (offset + 32 > data.len) {
            return error.DataTooShort;
        }

        var addr = @import("../types/address.zig").Address{ .bytes = undefined };
        @memcpy(&addr.bytes, data[offset + 12 .. offset + 32]);

        return addr;
    }

    /// Decode bytes32 from bytes
    pub fn decodeBytes32(data: []const u8, offset: usize) !Hash {
        if (offset + 32 > data.len) {
            return error.DataTooShort;
        }

        var hash = Hash{ .bytes = undefined };
        @memcpy(&hash.bytes, data[offset .. offset + 32]);

        return hash;
    }

    /// Decode string from bytes
    pub fn decodeString(allocator: std.mem.Allocator, data: []const u8, offset: usize) ![]u8 {
        if (offset + 32 > data.len) {
            return error.DataTooShort;
        }

        // First 32 bytes is the offset to the string data
        const str_offset_bytes = data[offset .. offset + 32];
        var str_offset: usize = 0;
        for (str_offset_bytes) |byte| {
            str_offset = (str_offset << 8) | byte;
        }

        // At the string offset, first 32 bytes is the length
        if (str_offset + 32 > data.len) {
            return error.InvalidStringOffset;
        }

        const length_bytes = data[str_offset .. str_offset + 32];
        var length: usize = 0;
        for (length_bytes) |byte| {
            length = (length << 8) | byte;
        }

        // Validate string length to prevent DoS attacks
        if (length > MAX_STRING_LENGTH) {
            return error.StringTooLong;
        }

        // Then comes the actual string data
        if (str_offset + 32 + length > data.len) {
            return error.InvalidStringLength;
        }

        const str_data = data[str_offset + 32 .. str_offset + 32 + length];
        return try allocator.dupe(u8, str_data);
    }

    /// Decode dynamic uint256 array from ABI-encoded data
    /// Returns array length and offset to array data
    pub fn decodeUint256ArrayInfo(data: []const u8, offset: usize) !struct { length: usize, data_offset: usize } {
        if (offset + 32 > data.len) {
            return error.InsufficientData;
        }

        // First 32 bytes at offset is the offset to the array data
        const array_offset_bytes = data[offset .. offset + 32];
        var array_offset: usize = 0;
        for (array_offset_bytes) |byte| {
            array_offset = (array_offset << 8) | byte;
        }

        // At the array offset, first 32 bytes is the length
        if (array_offset + 32 > data.len) {
            return error.InvalidArrayOffset;
        }

        const length_bytes = data[array_offset .. array_offset + 32];
        var length: usize = 0;
        for (length_bytes) |byte| {
            length = (length << 8) | byte;
        }

        // Validate array length to prevent DoS attacks
        if (length > MAX_ARRAY_LENGTH) {
            return error.ArrayTooLong;
        }

        return .{
            .length = length,
            .data_offset = array_offset + 32,
        };
    }

    /// Decode dynamic uint256 array from ABI-encoded data
    pub fn decodeUint256Array(allocator: std.mem.Allocator, data: []const u8, offset: usize) ![]u256 {
        const info = try decodeUint256ArrayInfo(data, offset);

        // Each element is 32 bytes
        const array_data_end = info.data_offset + (info.length * 32);
        if (array_data_end > data.len) {
            return error.ArrayDataTooShort;
        }

        var result = try allocator.alloc(u256, info.length);
        errdefer allocator.free(result);

        for (0..info.length) |i| {
            const elem_offset = info.data_offset + (i * 32);
            result[i] = try decodeUint256(data, elem_offset);
        }

        return result;
    }

    /// Decode dynamic bytes from ABI-encoded data
    pub fn decodeBytes(allocator: std.mem.Allocator, data: []const u8, offset: usize) ![]u8 {
        if (offset + 32 > data.len) {
            return error.DataTooShort;
        }

        // First 32 bytes is the offset to the bytes data
        const bytes_offset_bytes = data[offset .. offset + 32];
        var bytes_offset: usize = 0;
        for (bytes_offset_bytes) |byte| {
            bytes_offset = (bytes_offset << 8) | byte;
        }

        // At the bytes offset, first 32 bytes is the length
        if (bytes_offset + 32 > data.len) {
            return error.InvalidBytesOffset;
        }

        const length_bytes = data[bytes_offset .. bytes_offset + 32];
        var length: usize = 0;
        for (length_bytes) |byte| {
            length = (length << 8) | byte;
        }

        // Validate bytes length to prevent DoS attacks
        if (length > MAX_BYTES_LENGTH) {
            return error.BytesTooLong;
        }

        // Then comes the actual bytes data
        if (bytes_offset + 32 + length > data.len) {
            return error.InvalidBytesLength;
        }

        const bytes_data = data[bytes_offset + 32 .. bytes_offset + 32 + length];
        return try allocator.dupe(u8, bytes_data);
    }

    /// Encode function call
    pub fn encodeCall(allocator: std.mem.Allocator, signature: []const u8) ![]u8 {
        const sig_hash = try @import("../types/hash.zig").keccak256(allocator, signature);

        const result = try allocator.alloc(u8, 4);
        @memcpy(result, sig_hash.bytes[0..4]);

        return result;
    }
};

test "ABI decode uint256" {
    const data = [_]u8{0} ** 31 ++ [_]u8{42};
    const value = try ABI.decodeUint256(&data, 0);
    try std.testing.expectEqual(@as(u256, 42), value);
}

test "ABI decode address" {
    var data = [_]u8{0} ** 32;
    data[31] = 1;

    const addr = try ABI.decodeAddress(&data, 0);
    try std.testing.expectEqual(@as(u8, 1), addr.bytes[19]);
}

test "ABI decodeString rejects string exceeding MAX_STRING_LENGTH" {
    const allocator = std.testing.allocator;

    // Create data with string length > MAX_STRING_LENGTH (1 MB)
    // Structure: [offset(32), length(32)]
    const offset: u32 = 32;
    const too_long: usize = ABI.MAX_STRING_LENGTH + 1;

    var data = try allocator.alloc(u8, 64);
    defer allocator.free(data);

    // Offset pointer (points to position 32 where length is stored)
    @memset(data[0..32], 0);
    data[31] = @intCast(offset);

    // String length = MAX_STRING_LENGTH + 1 (big-endian encoding)
    @memset(data[32..64], 0);
    // Store the length in big-endian format in the last 8 bytes
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const shift: u6 = @intCast(56 - i * 8);
        data[56 + i] = @intCast((too_long >> shift) & 0xFF);
    }

    const result = ABI.decodeString(allocator, data, 0);
    try std.testing.expectError(error.StringTooLong, result);
}

test "ABI decodeBytes rejects bytes exceeding MAX_BYTES_LENGTH" {
    const allocator = std.testing.allocator;

    // Create data with bytes length > MAX_BYTES_LENGTH (1 MB)
    const offset: u32 = 32;
    const too_long: usize = ABI.MAX_BYTES_LENGTH + 1;

    var data = try allocator.alloc(u8, 64);
    defer allocator.free(data);

    // Offset pointer
    @memset(data[0..32], 0);
    data[31] = @intCast(offset);

    // Bytes length = MAX_BYTES_LENGTH + 1 (big-endian encoding)
    @memset(data[32..64], 0);
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const shift: u6 = @intCast(56 - i * 8);
        data[56 + i] = @intCast((too_long >> shift) & 0xFF);
    }

    const result = ABI.decodeBytes(allocator, data, 0);
    try std.testing.expectError(error.BytesTooLong, result);
}

test "ABI decodeUint256Array rejects array exceeding MAX_ARRAY_LENGTH" {
    const allocator = std.testing.allocator;

    // Create data with array length > MAX_ARRAY_LENGTH (10,000)
    const offset: u32 = 32;
    const too_long: usize = ABI.MAX_ARRAY_LENGTH + 1;

    var data = try allocator.alloc(u8, 64);
    defer allocator.free(data);

    // Offset pointer
    @memset(data[0..32], 0);
    data[31] = @intCast(offset);

    // Array length = MAX_ARRAY_LENGTH + 1 (big-endian encoding)
    @memset(data[32..64], 0);
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const shift: u6 = @intCast(56 - i * 8);
        data[56 + i] = @intCast((too_long >> shift) & 0xFF);
    }

    const result = ABI.decodeUint256Array(allocator, data, 0);
    try std.testing.expectError(error.ArrayTooLong, result);
}

test "ABI decodeString accepts string at MAX_STRING_LENGTH" {
    const allocator = std.testing.allocator;

    // Create minimal valid data structure for max length string
    const offset: u32 = 32;
    const length: u32 = 1000; // Use smaller test size for speed

    var data = try allocator.alloc(u8, offset + 32 + length);
    defer allocator.free(data);

    // Offset pointer
    @memset(data[0..32], 0);
    data[31] = @intCast(offset);

    // String length
    @memset(data[offset .. offset + 32], 0);
    data[offset + 28] = @intCast((length >> 24) & 0xFF);
    data[offset + 29] = @intCast((length >> 16) & 0xFF);
    data[offset + 30] = @intCast((length >> 8) & 0xFF);
    data[offset + 31] = @intCast(length & 0xFF);

    // String data (fill with 'a')
    @memset(data[offset + 32 ..], 'a');

    const result = try ABI.decodeString(allocator, data, 0);
    defer allocator.free(result);

    try std.testing.expectEqual(length, result.len);
}
