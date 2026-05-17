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

pub const resolveAccount = account.resolveAccount;

pub const resolveRoles = admin.resolveRoles;
pub const resolveRolesConnection = admin.resolveRolesConnection;
pub const resolveResolvers = admin.resolveResolvers;
pub const resolveResolver = admin.resolveResolver;
pub const resolveRegistries = admin.resolveRegistries;
pub const resolveRegistry = admin.resolveRegistry;
pub const resolveMetadata = admin.resolveMetadata;
pub const resolveApprovals = admin.resolveApprovals;
