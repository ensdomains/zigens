const std = @import("std");
const Address = @import("address.zig").Address;
const Hash = @import("hash.zig").Hash;

/// Chain identifier
pub const Chain = enum {
    l1,
    l2,

    pub fn toString(self: Chain) []const u8 {
        return switch (self) {
            .l1 => "l1",
            .l2 => "l2",
        };
    }

    pub fn fromString(s: []const u8) !Chain {
        if (std.mem.eql(u8, s, "l1")) return .l1;
        if (std.mem.eql(u8, s, "l2")) return .l2;
        return error.InvalidChain;
    }
};

/// Registry entry in the ENSv2 system
pub const Registry = struct {
    /// Address of the registry contract
    address: Address,
    /// Chain where this registry exists
    chain: Chain,
    /// Name this registry is responsible for (e.g., "eth", "alice.eth")
    name: []const u8,
    /// Namehash of the name
    namehash: Hash,
    /// Address of the parent registry (zero for root)
    parent_registry: Address,
    /// Block number when this registry was created
    created_block: u64,
    /// Timestamp when this registry was created
    created_at: i64,

    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

/// Name entry in ENSv2
pub const Name = struct {
    /// Full name (e.g., "alice.eth") - optional for names where label is unknown
    name: ?[]const u8,
    /// Namehash
    namehash: Hash,
    /// Label (rightmost part, e.g., "alice") - optional for names where label is unknown
    label: ?[]const u8,
    /// Label hash
    label_hash: Hash,
    /// Parent name (e.g., "eth") - optional if parent is unknown
    parent_name: ?[]const u8,
    /// Parent namehash
    parent_namehash: Hash,
    /// Chain where this name is registered
    chain: Chain,
    /// Registry contract managing this name
    registry: Address,
    /// Current owner address
    owner: Address,
    /// Original registrant address (from NameRegistered event)
    /// This does not change on transfers, unlike owner
    registrant: Address,
    /// Resolver address
    resolver: Address,
    /// Token ID in the registry's ERC1155
    token_id: u256,
    /// Canonical ID (token_id with lower 32 bits cleared)
    /// Used for storage lookups, ignoring version
    canonical_id: u256,
    /// Token version (lower 32 bits of token_id)
    /// Increments when a name is regenerated
    token_version: u32,
    /// Expiration timestamp (0 if no expiration)
    expiry: u64,
    /// Whether the registry is locked
    registry_locked: bool,
    /// Whether this is a migrated name from ENSv1
    migrated: bool,
    /// Whether this is an ejected name (on L1 but registered on L2)
    ejected: bool,
    /// Block number when created
    created_block: u64,
    /// Timestamp when created
    created_at: i64,
    /// Timestamp of the current registration (updates on re-registration)
    registered_at: i64,
    /// Block number of last update
    updated_block: u64,
    /// Timestamp of last update
    updated_at: i64,
    /// Whether this name is wrapped in the Name Wrapper contract
    is_wrapped: bool,
    /// Fuses set on the wrapped name (if wrapped)
    wrapper_fuses: ?[]const u8,
    /// Expiry timestamp for the wrapped name (if wrapped)
    wrapper_expiry: ?i64,
    /// Whether this is a V1 ENS name (.eth second-level domain or V1 subdomain)
    is_v1_name: bool,
    /// V1 label hash (for V1 names - keccak256 of the label)
    v1_label_hash: ?[]const u8,

    pub fn deinit(self: *Name, allocator: std.mem.Allocator) void {
        if (self.name) |n| allocator.free(n);
        if (self.label) |l| allocator.free(l);
        if (self.parent_name) |p| allocator.free(p);
        if (self.wrapper_fuses) |fuses| {
            allocator.free(fuses);
        }
        if (self.v1_label_hash) |hash| {
            allocator.free(hash);
        }
    }

    pub fn isExpired(self: Name) bool {
        if (self.expiry == 0) return false;
        const now: u64 = @intCast(std.time.timestamp());
        return now >= self.expiry;
    }
};

/// Resolver record
pub const Resolver = struct {
    /// Resolver address
    address: Address,
    /// Chain where this resolver exists
    chain: Chain,
    /// Name this resolver is set for
    name: []const u8,
    /// Namehash
    namehash: Hash,
    /// Block number when set
    set_block: u64,
    /// Timestamp when set
    set_at: i64,

    pub fn deinit(self: *Resolver, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

/// Event types in ENSv2
pub const EventType = enum {
    // Registry events
    new_subname,
    subregistry_update,
    resolver_update,
    transfer,

    // Registration events
    name_registered,
    name_renewed,
    name_burned,
    commitment_made,

    // Token events
    token_regenerated,
    approval,

    // Migration events
    name_migrated,

    // Ejection events
    name_ejected_to_l1,
    name_returned_to_l2,

    // ENSIP-16 Offchain metadata events
    metadata_changed,
    resolver_approved,

    // Resolver record change events
    text_changed,
    address_changed,
    contenthash_changed,
    abi_changed,
    pubkey_changed,
    name_changed,
    interface_changed,

    // EAC (Enhanced Access Control) events
    eac_roles_changed,

    // OwnedResolver events
    version_changed,
    alias_changed,

    pub fn toString(self: EventType) []const u8 {
        return switch (self) {
            .new_subname => "NewSubname",
            .subregistry_update => "SubregistryUpdate",
            .resolver_update => "ResolverUpdate",
            .transfer => "Transfer",
            .name_registered => "NameRegistered",
            .name_renewed => "NameRenewed",
            .name_burned => "NameBurned",
            .commitment_made => "CommitmentMade",
            .token_regenerated => "TokenRegenerated",
            .approval => "Approval",
            .name_migrated => "NameMigrated",
            .name_ejected_to_l1 => "NameEjectedToL1",
            .name_returned_to_l2 => "NameReturnedToL2",
            .metadata_changed => "MetadataChanged",
            .resolver_approved => "ResolverApproved",
            .text_changed => "TextChanged",
            .address_changed => "AddressChanged",
            .contenthash_changed => "ContenthashChanged",
            .abi_changed => "ABIChanged",
            .pubkey_changed => "PubkeyChanged",
            .name_changed => "NameChanged",
            .interface_changed => "InterfaceChanged",
            .eac_roles_changed => "EACRolesChanged",
            .version_changed => "VersionChanged",
            .alias_changed => "AliasChanged",
        };
    }

    pub fn fromString(s: []const u8) ?EventType {
        if (std.mem.eql(u8, s, "NewSubname")) return .new_subname;
        if (std.mem.eql(u8, s, "SubregistryUpdate")) return .subregistry_update;
        if (std.mem.eql(u8, s, "ResolverUpdate")) return .resolver_update;
        if (std.mem.eql(u8, s, "Transfer")) return .transfer;
        if (std.mem.eql(u8, s, "NameRegistered")) return .name_registered;
        if (std.mem.eql(u8, s, "NameRenewed")) return .name_renewed;
        if (std.mem.eql(u8, s, "NameBurned")) return .name_burned;
        if (std.mem.eql(u8, s, "CommitmentMade")) return .commitment_made;
        if (std.mem.eql(u8, s, "TokenRegenerated")) return .token_regenerated;
        if (std.mem.eql(u8, s, "Approval")) return .approval;
        if (std.mem.eql(u8, s, "NameMigrated")) return .name_migrated;
        if (std.mem.eql(u8, s, "NameEjectedToL1")) return .name_ejected_to_l1;
        if (std.mem.eql(u8, s, "NameReturnedToL2")) return .name_returned_to_l2;
        if (std.mem.eql(u8, s, "MetadataChanged")) return .metadata_changed;
        if (std.mem.eql(u8, s, "ResolverApproved")) return .resolver_approved;
        if (std.mem.eql(u8, s, "TextChanged")) return .text_changed;
        if (std.mem.eql(u8, s, "AddressChanged")) return .address_changed;
        if (std.mem.eql(u8, s, "ContenthashChanged")) return .contenthash_changed;
        if (std.mem.eql(u8, s, "ABIChanged")) return .abi_changed;
        if (std.mem.eql(u8, s, "PubkeyChanged")) return .pubkey_changed;
        if (std.mem.eql(u8, s, "NameChanged")) return .name_changed;
        if (std.mem.eql(u8, s, "InterfaceChanged")) return .interface_changed;
        if (std.mem.eql(u8, s, "EACRolesChanged")) return .eac_roles_changed;
        if (std.mem.eql(u8, s, "VersionChanged")) return .version_changed;
        if (std.mem.eql(u8, s, "AliasChanged")) return .alias_changed;
        return null;
    }
};

/// Event record
pub const Event = struct {
    /// Event type
    event_type: EventType,
    /// Chain where event occurred
    chain: Chain,
    /// Block number
    block_number: u64,
    /// Transaction hash
    tx_hash: Hash,
    /// Log index in transaction
    log_index: u32,
    /// Contract address that emitted the event
    contract_address: Address,
    /// Name affected by this event
    name: ?[]const u8,
    /// Namehash
    namehash: ?Hash,
    /// Additional data (JSON encoded)
    data: []const u8,
    /// Timestamp
    timestamp: i64,

    pub fn deinit(self: *Event, allocator: std.mem.Allocator) void {
        if (self.name) |n| allocator.free(n);
        allocator.free(self.data);
    }
};

/// Webhook configuration
pub const Webhook = struct {
    /// Webhook ID
    id: u64,
    /// URL to send events to
    url: []const u8,
    /// Event types to listen for (empty = all)
    event_types: []const EventType,
    /// Whether this webhook is active
    active: bool,
    /// Number of retry attempts on failure
    max_retries: u32,
    /// Created timestamp
    created_at: i64,

    pub fn deinit(self: *Webhook, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.event_types);
    }
};

/// Migration direction
pub const MigrationDirection = enum {
    to_l1,
    to_l2,

    pub fn toString(self: MigrationDirection) []const u8 {
        return switch (self) {
            .to_l1 => "to_l1",
            .to_l2 => "to_l2",
        };
    }

    pub fn fromString(s: []const u8) !MigrationDirection {
        if (std.mem.eql(u8, s, "to_l1")) return .to_l1;
        if (std.mem.eql(u8, s, "to_l2")) return .to_l2;
        return error.InvalidDirection;
    }
};

/// Migration record
pub const Migration = struct {
    /// Migration ID
    id: u64,
    /// Chain where the migration event occurred
    chain: Chain,
    /// Token ID being migrated
    token_id: u256,
    /// Migration direction
    direction: MigrationDirection,
    /// DNS-encoded name
    dns_encoded_name: []const u8,
    /// Block number
    block_number: u64,
    /// Transaction hash
    tx_hash: Hash,
    /// Log index
    log_index: u32,
    /// Timestamp
    timestamp: i64,

    pub fn deinit(self: *Migration, allocator: std.mem.Allocator) void {
        allocator.free(self.dns_encoded_name);
    }
};

/// Renewal synchronization record (cross-chain renewal sync)
pub const RenewalSync = struct {
    /// Record ID
    id: u64,
    /// Chain where the sync event occurred
    chain: Chain,
    /// Token ID being renewed
    token_id: u256,
    /// New expiration timestamp
    new_expiry: u64,
    /// Block number
    block_number: u64,
    /// Transaction hash
    tx_hash: Hash,
    /// Log index
    log_index: u32,
    /// Timestamp
    timestamp: i64,
};

/// Token observer record
pub const TokenObserver = struct {
    /// Record ID
    id: u64,
    /// Chain where the observer was set
    chain: Chain,
    /// Token ID being observed
    token_id: u256,
    /// Observer contract address
    observer: Address,
    /// Block number
    block_number: u64,
    /// Transaction hash
    tx_hash: Hash,
    /// Log index
    log_index: u32,
    /// Timestamp
    timestamp: i64,
};

/// EAC (Enhanced Access Control) role types
/// Each role is a nybble (4 bits) in the role bitmap
pub const EACRole = enum(u8) {
    // Owner roles (lower 128 bits)
    registrar = 0, // Can register names
    renew = 4, // Can renew names
    set_subregistry = 8, // Can set subregistries
    set_resolver = 12, // Can set resolvers
    set_token_observer = 16, // Can set token observers
    burn = 20, // Can burn tokens

    // Admin roles would be at (role + 128)
    // We don't need to enumerate all of them here

    pub fn toString(self: EACRole) []const u8 {
        return switch (self) {
            .registrar => "REGISTRAR",
            .renew => "RENEW",
            .set_subregistry => "SET_SUBREGISTRY",
            .set_resolver => "SET_RESOLVER",
            .set_token_observer => "SET_TOKEN_OBSERVER",
            .burn => "BURN",
        };
    }
};

/// EAC role assignment record
pub const EACRoleAssignment = struct {
    /// Record ID
    id: u64,
    /// Chain
    chain: Chain,
    /// Resource (token ID or resource identifier) as hex string
    resource: []const u8,
    /// Account that has the role
    account: Address,
    /// Role bitmap as hex string
    role_bitmap: []const u8,
    /// Block number
    block_number: u64,
    /// Transaction hash
    tx_hash: Hash,
    /// Log index
    log_index: u32,
    /// Timestamp
    timestamp: i64,
    /// Domain name (resolved from resource/canonical_id, null for global roles)
    name: ?[]const u8 = null,

    pub fn deinit(self: *EACRoleAssignment, allocator: std.mem.Allocator) void {
        allocator.free(self.resource);
        allocator.free(self.role_bitmap);
        if (self.name) |n| allocator.free(n);
    }
};

/// ENSIP-16: Resolver metadata (offchain GraphQL endpoint)
pub const ResolverMetadata = struct {
    /// Record ID
    id: u64,
    /// Chain
    chain: Chain,
    /// Resolver contract address
    resolver: Address,
    /// GraphQL endpoint URL for offchain data
    graphql_url: []const u8,
    /// Block number
    block_number: u64,
    /// Transaction hash
    tx_hash: Hash,
    /// Timestamp
    timestamp: i64,

    pub fn deinit(self: *ResolverMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.graphql_url);
    }
};

/// ENSIP-16: Resolver approval/delegation record
pub const ResolverApproval = struct {
    /// Record ID
    id: u64,
    /// Chain
    chain: Chain,
    /// Resolver contract address
    resolver: Address,
    /// Namehash of the name being delegated
    namehash: Hash,
    /// Optional context for namespacing (typically owner address)
    context: ?[]const u8,
    /// Delegate address
    delegate: Address,
    /// Whether approved (true) or revoked (false)
    approved: bool,
    /// Block number
    block_number: u64,
    /// Transaction hash
    tx_hash: Hash,
    /// Log index
    log_index: u32,
    /// Timestamp
    timestamp: i64,

    pub fn deinit(self: *ResolverApproval, allocator: std.mem.Allocator) void {
        if (self.context) |ctx| {
            allocator.free(ctx);
        }
    }
};
