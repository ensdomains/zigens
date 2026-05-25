const std = @import("std");
const Address = @import("address.zig").Address;
const Hash = @import("hash.zig").Hash;

/// ENS protocol version (v1 = legacy ENS; v2 = ENSv2). Distinguishes which name
/// system a row belongs to in the unified DB. Not a blockchain identifier.
pub const Protocol = enum {
    v1,
    v2,

    pub fn toString(self: Protocol) []const u8 {
        return switch (self) {
            .v1 => "v1",
            .v2 => "v2",
        };
    }

    pub fn fromString(s: []const u8) !Protocol {
        if (std.mem.eql(u8, s, "v1")) return .v1;
        if (std.mem.eql(u8, s, "v2")) return .v2;
        return error.InvalidProtocol;
    }
};

/// Registry entry in the ENSv2 system
pub const Registry = struct {
    /// Address of the registry contract
    address: Address,
    /// Chain where this registry exists
    protocol: Protocol,
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
    protocol: Protocol,
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
    /// Canonical-resolution reachability flag. Set to false when an ancestor
    /// label's `setSubregistry` repoints away from this name's source registry
    /// (or its expiry passes / LabelUnregistered fires). Default-filtered out
    /// of GraphQL queries unless `includeUnreachable: true` is passed.
    is_reachable: bool = true,
    /// Timestamp (seconds) when this name first became unreachable. Null
    /// while `is_reachable = true`.
    unreachable_since: ?i64 = null,
    /// V1 ENS Registry TTL (from `NewTTL(node, ttl)`). Null when never set;
    /// only populated for V1 names whose owner explicitly called `setTTL`.
    /// Not used by V2 (no equivalent concept).
    ttl: ?u64 = null,
    /// V1 ENS Registry provenance: true when the row's most recent update
    /// came from the legacy pre-2020 ENS Registry (0x314159…). False once
    /// the new Registry (0x00…2e1e) emits an event for the same node.
    /// Always false for V2 rows.
    is_legacy: bool = false,
    /// V1-only materialized `resolvedAddress` (subgraph parity). Populated by
    /// `handleV1NewResolver` after calling `addr(node)` on the resolver. Null
    /// for V2 rows and for V1 rows where the call has not yet been made — the
    /// API layer falls back to a query-time `Resolver.addr(coinType:60)` lookup
    /// when null.
    resolved_address: ?Address = null,

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
    protocol: Protocol,
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
    // Registry events (ENSIP-16)
    new_subname,
    subregistry_update,
    subregistry_updated,
    resolver_update,
    resolver_updated,
    transfer,

    // Registration events
    name_registered,
    name_renewed,
    name_burned,
    label_registered,
    label_reserved,
    label_unregistered,
    expiry_updated,
    commitment_made,

    // Parent events
    parent_updated,

    // Token events
    token_regenerated,
    approval,

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

    // V1 → V2 migration: emitted on the V1 row when a token transfers to a
    // MigrationController. Distinct from `name_registered`/`label_registered`
    // so consumers can filter on "migration" specifically (vs first-time mint).
    name_migrated,

    // V1 NameWrapper lifecycle: distinct from `.transfer` so consumers can
    // filter wrap/unwrap separately from ERC721/ERC1155 transfers.
    name_wrapped,
    name_unwrapped,
    fuses_set,

    // V1 ReverseRegistrar.claim: distinct from `.transfer` since the on-chain
    // event is `ReverseClaimed`, not a token transfer. Surfaces via the
    // existing Account.primaryName GraphQL path.
    reverse_claimed,

    // V1 ENS Registry setOwner: an `(node, owner)` ownership change emitted
    // by the Registry contract directly (vs ERC721/ERC1155 transfer of a
    // token-backed name). Subgraph models this as a distinct entity — we
    // mirror that with its own event_type so clients don't conflate it
    // with token transfers.
    registry_transfer,

    pub fn toString(self: EventType) []const u8 {
        return switch (self) {
            .new_subname => "NewSubname",
            .subregistry_update => "SubregistryUpdate",
            .subregistry_updated => "SubregistryUpdated",
            .resolver_update => "ResolverUpdate",
            .resolver_updated => "ResolverUpdated",
            .transfer => "Transfer",
            .name_registered => "NameRegistered",
            .name_renewed => "NameRenewed",
            .name_burned => "NameBurned",
            .label_registered => "LabelRegistered",
            .label_reserved => "LabelReserved",
            .label_unregistered => "LabelUnregistered",
            .expiry_updated => "ExpiryUpdated",
            .commitment_made => "CommitmentMade",
            .parent_updated => "ParentUpdated",
            .token_regenerated => "TokenRegenerated",
            .approval => "Approval",
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
            .name_migrated => "NameMigrated",
            .name_wrapped => "NameWrapped",
            .name_unwrapped => "NameUnwrapped",
            .fuses_set => "FusesSet",
            .reverse_claimed => "ReverseClaimed",
            .registry_transfer => "RegistryTransfer",
        };
    }

    pub fn fromString(s: []const u8) ?EventType {
        if (std.mem.eql(u8, s, "NewSubname")) return .new_subname;
        if (std.mem.eql(u8, s, "SubregistryUpdate")) return .subregistry_update;
        if (std.mem.eql(u8, s, "SubregistryUpdated")) return .subregistry_updated;
        if (std.mem.eql(u8, s, "ResolverUpdate")) return .resolver_update;
        if (std.mem.eql(u8, s, "ResolverUpdated")) return .resolver_updated;
        if (std.mem.eql(u8, s, "Transfer")) return .transfer;
        if (std.mem.eql(u8, s, "NameRegistered")) return .name_registered;
        if (std.mem.eql(u8, s, "NameRenewed")) return .name_renewed;
        if (std.mem.eql(u8, s, "NameBurned")) return .name_burned;
        if (std.mem.eql(u8, s, "CommitmentMade")) return .commitment_made;
        if (std.mem.eql(u8, s, "TokenRegenerated")) return .token_regenerated;
        if (std.mem.eql(u8, s, "Approval")) return .approval;
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
        if (std.mem.eql(u8, s, "LabelRegistered")) return .label_registered;
        if (std.mem.eql(u8, s, "LabelReserved")) return .label_reserved;
        if (std.mem.eql(u8, s, "LabelUnregistered")) return .label_unregistered;
        if (std.mem.eql(u8, s, "ExpiryUpdated")) return .expiry_updated;
        if (std.mem.eql(u8, s, "ParentUpdated")) return .parent_updated;
        if (std.mem.eql(u8, s, "NameMigrated")) return .name_migrated;
        if (std.mem.eql(u8, s, "NameWrapped")) return .name_wrapped;
        if (std.mem.eql(u8, s, "NameUnwrapped")) return .name_unwrapped;
        if (std.mem.eql(u8, s, "FusesSet")) return .fuses_set;
        if (std.mem.eql(u8, s, "ReverseClaimed")) return .reverse_claimed;
        if (std.mem.eql(u8, s, "RegistryTransfer")) return .registry_transfer;
        return null;
    }
};

/// Event record
pub const Event = struct {
    /// Event type
    event_type: EventType,
    /// Chain where event occurred
    protocol: Protocol,
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

    // ------------------------------------------------------------------------
    // Registration economics (populated only when this Event was synthesised
    // from a `registrations` row — see storage/registrations.zig:rowToEvent).
    // Null otherwise. Stored as u256 decimal strings because wei values
    // routinely exceed i64 range.
    // ------------------------------------------------------------------------
    /// Base rent cost in wei (decimal-encoded u256). Null when the Controller
    /// event has not been observed for this registration.
    base_cost: ?[]const u8 = null,
    /// Auction premium portion in wei (decimal-encoded u256). "0" for legacy
    /// 5-arg controller. Null when the Controller event was not observed.
    premium: ?[]const u8 = null,
    /// Human-readable label from the Controller event preimage (e.g., "vitalik").
    /// Null when the Controller event was not observed.
    label_name: ?[]const u8 = null,
    /// Referrer bytes32 hex from the 7-arg UnwrappedEthRegistrarController
    /// variant. Null for older variants / unobserved events.
    referrer: ?[]const u8 = null,

    pub fn deinit(self: *Event, allocator: std.mem.Allocator) void {
        if (self.name) |n| allocator.free(n);
        allocator.free(self.data);
        if (self.base_cost) |s| allocator.free(s);
        if (self.premium) |s| allocator.free(s);
        if (self.label_name) |s| allocator.free(s);
        if (self.referrer) |s| allocator.free(s);
    }
};

/// Webhook configuration
pub const Webhook = struct {
    /// Webhook ID
    id: u64,
    /// URL to send events to
    url: []const u8,
    /// Per-webhook HMAC-SHA256 secret (hex-encoded). Returned to the registrant once
    /// at creation time so they can verify incoming `X-Webhook-Signature` headers.
    secret: []const u8,
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
        allocator.free(self.secret);
        allocator.free(self.event_types);
    }
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
    protocol: Protocol,
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
    protocol: Protocol,
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
    protocol: Protocol,
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
