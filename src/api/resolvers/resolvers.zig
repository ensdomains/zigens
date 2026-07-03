/// ENS GraphQL Resolver Functions
///
/// This module re-exports all resolver functions organized by domain:
/// - domain: Domain-related resolvers
/// - registration: Registration-related resolvers
/// - event: Event-related resolvers
/// - account: Account-related resolvers
/// - admin: Admin/Role/Registry resolvers
pub const domain = @import("domain.zig");
pub const registration = @import("registration.zig");
pub const event = @import("event.zig");
pub const account = @import("account.zig");
pub const admin = @import("admin.zig");

// Re-export commonly used resolver functions at the top level for convenience
pub const resolveDomain = domain.resolveDomain;
pub const resolveDomains = domain.resolveDomains;
pub const resolveDomainConnection = domain.resolveDomainConnection;

pub const resolveRegistrations = registration.resolveRegistrations;
pub const resolveRegistrationConnection = registration.resolveRegistrationConnection;

pub const resolveEvents = event.resolveEvents;
pub const resolveEventConnection = event.resolveEventConnection;

// Subgraph-parity per-type event queries (S7-S9). Each is a thin wrapper
// around `resolveEvents` that forces a fixed `event_type` filter and reuses
// the existing typed-projection (`as*`) machinery.
pub const resolveTransfers = event.resolveTransfers;
pub const resolveNameRegistereds = event.resolveNameRegistereds;
pub const resolveNameReneweds = event.resolveNameReneweds;
pub const resolveTextChangeds = event.resolveTextChangeds;
pub const resolveAddressChangeds = event.resolveAddressChangeds;
pub const resolveNameWrappeds = event.resolveNameWrappeds;
pub const resolveNameUnwrappeds = event.resolveNameUnwrappeds;
pub const resolveFusesSets = event.resolveFusesSets;
pub const resolveExpiryUpdateds = event.resolveExpiryUpdateds;
pub const resolveResolverUpdateds = event.resolveResolverUpdateds;
pub const resolveLabelRegistereds = event.resolveLabelRegistereds;
pub const resolveReverseClaimeds = event.resolveReverseClaimeds;
pub const resolveRegistryTransfers = event.resolveRegistryTransfers;

pub const resolveAccount = account.resolveAccount;
pub const resolveAccounts = account.resolveAccounts;

pub const resolveRoles = admin.resolveRoles;
pub const resolveRolesConnection = admin.resolveRolesConnection;
/// Renamed Phase 4a: was `resolveResolvers` ("dedicated resolvers for an
/// account"), now `resolveResolversByOwner`. The bare name is reused below
/// for the subgraph-style entity listing added in Phase 4b.
pub const resolveResolversByOwner = admin.resolveResolvers;
pub const resolveResolvers = admin.resolveResolverEntities;
pub const resolveResolver = admin.resolveResolver;
pub const resolveRegistries = admin.resolveRegistries;
pub const resolveRegistry = admin.resolveRegistry;
pub const resolveMetadata = admin.resolveMetadata;
pub const resolveApprovals = admin.resolveApprovals;
pub const resolveWrappedDomains = admin.resolveWrappedDomains;
pub const resolveMeta = admin.resolveMeta;
pub const resolveFinality = admin.resolveFinality;
