/// ENS Entity JSON Builders
///
/// This module re-exports all entity builder functions.
/// Due to circular dependencies between builders (domain handlers call event builders,
/// event handlers call domain builders, etc.), the implementation remains in a single file.
///
/// Exported builders:
/// - buildDomainJson: Build JSON for Domain entities
/// - buildEventJson: Build JSON for Event entities
/// - buildRegistrationJson: Build JSON for Registration entities
/// - buildAccountJson: Build JSON for Account entities
/// - buildResolverJson: Build JSON for Resolver entities
const impl = @import("impl.zig");

// Re-export all public functions and types
pub const NestedContext = impl.NestedContext;
pub const buildDomainJson = impl.buildDomainJson;
pub const buildEventJson = impl.buildEventJson;
pub const buildRegistrationJson = impl.buildRegistrationJson;
pub const buildAccountJson = impl.buildAccountJson;
pub const buildResolverJson = impl.buildResolverJson;
pub const buildWrappedDomainJson = impl.buildWrappedDomainJson;
pub const effectiveResolver = impl.effectiveResolver;
pub const parseDomainEventsFilter = impl.parseDomainEventsFilter;
