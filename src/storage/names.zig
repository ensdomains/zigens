//! Names storage — public facade over cohesive sibling modules. This file only
//! re-exports; every implementation lives in names_registry / names_write /
//! names_filter / names_read (shared pure helpers in names_common). `names.X`,
//! `db.X`, and `names_storage.X` call sites are unchanged.

const names_registry = @import("names_registry.zig");
const names_write = @import("names_write.zig");
const names_filter = @import("names_filter.zig");
const names_read = @import("names_read.zig");

// Registry operations
pub const insertRegistry = names_registry.insertRegistry;
pub const setSeededRootRegistryCreation = names_registry.setSeededRootRegistryCreation;
pub const setSeededSubregistryCreation = names_registry.setSeededSubregistryCreation;
pub const updateRegistryPlaceholderName = names_registry.updateRegistryPlaceholderName;
pub const updatePlaceholderEventsByName = names_registry.updatePlaceholderEventsByName;
pub const getRegistriesByOwner = names_registry.getRegistriesByOwner;
pub const getRegistry = names_registry.getRegistry;

// Name insert / mutation operations
pub const insertName = names_write.insertName;
pub const insertNamesBatch = names_write.insertNamesBatch;
pub const updateNameIsLegacy = names_write.updateNameIsLegacy;
pub const updateNameExpiry = names_write.updateNameExpiry;
pub const updateV1RenewalExpiry = names_write.updateV1RenewalExpiry;
pub const updateNameOwner = names_write.updateNameOwner;
pub const markNameMigrated = names_write.markNameMigrated;
pub const updateNameResolver = names_write.updateNameResolver;
pub const updateResolvedAddressToNull = names_write.updateResolvedAddressToNull;
pub const updateNameTTL = names_write.updateNameTTL;
pub const deleteNameByNamehash = names_write.deleteNameByNamehash;
pub const recursivelyGcEmptyDomain = names_write.recursivelyGcEmptyDomain;
pub const deleteNameByNamehashScoped = names_write.deleteNameByNamehashScoped;
pub const updateNameTokenIdByNamehash = names_write.updateNameTokenIdByNamehash;
pub const updateNameWrapperState = names_write.updateNameWrapperState;
pub const clearNameExpiry = names_write.clearNameExpiry;
pub const updateNameUnwrapperState = names_write.updateNameUnwrapperState;
pub const updateNameWrapperFuses = names_write.updateNameWrapperFuses;
pub const updateNameWrapperExpiry = names_write.updateNameWrapperExpiry;
pub const updateDomainExpiryIfGreater = names_write.updateDomainExpiryIfGreater;
pub const materializePccDomainExpiry = names_write.materializePccDomainExpiry;
pub const updateNameLabel = names_write.updateNameLabel;
pub const updateNameCreationDateIfEarlier = names_write.updateNameCreationDateIfEarlier;

// Filter engine + filtered / list / count queries
pub const OrderDir = names_filter.OrderDir;
pub const NameSortField = names_filter.NameSortField;
pub const NameFilters = names_filter.NameFilters;
pub const countRowsBeforeNamehash = names_filter.countRowsBeforeNamehash;
pub const getAllNames = names_filter.getAllNames;
pub const getFilteredNames = names_filter.getFilteredNames;
pub const getFilteredNamesKeyset = names_filter.getFilteredNamesKeyset;
pub const KeysetAnchor = names_filter.KeysetAnchor;
pub const getAllNamesWithOrder = names_filter.getAllNamesWithOrder;
pub const getFilteredNameCount = names_filter.getFilteredNameCount;

// Read / query operations (single-row, list, wrapped-domain, subdomain)
pub const getNameByNamehash = names_read.getNameByNamehash;
pub const getNameStringByNamehash = names_read.getNameStringByNamehash;
pub const getNameByNamehashAndProtocol = names_read.getNameByNamehashAndProtocol;
pub const getNamehashByResolver = names_read.getNamehashByResolver;
pub const getNameByTokenIdAndRegistry = names_read.getNameByTokenIdAndRegistry;
pub const getUniqueNameByCanonicalId = names_read.getUniqueNameByCanonicalId;
pub const getNamesByCanonicalIds = names_read.getNamesByCanonicalIds;
pub const getNamesInRegistry = names_read.getNamesInRegistry;
pub const getNamesByNamehashes = names_read.getNamesByNamehashes;
pub const CanonicalNameResolution = names_read.CanonicalNameResolution;
pub const resolveUniqueNamesByCanonicalIds = names_read.resolveUniqueNamesByCanonicalIds;
pub const freeCanonicalNameResolutions = names_read.freeCanonicalNameResolutions;
pub const getNamesByOwner = names_read.getNamesByOwner;
pub const getNamesByResolver = names_read.getNamesByResolver;
pub const WrappedDomainFilters = names_read.WrappedDomainFilters;
pub const getWrappedDomains = names_read.getWrappedDomains;
pub const getDomainByResolver = names_read.getDomainByResolver;
pub const getDomainsByResolvers = names_read.getDomainsByResolvers;
pub const countDirectSubdomains = names_read.countDirectSubdomains;
pub const ParentCountRow = names_read.ParentCountRow;
pub const freeParentCountRows = names_read.freeParentCountRows;
pub const countDirectSubdomainsForParents = names_read.countDirectSubdomainsForParents;
pub const hasDirectSubdomains = names_read.hasDirectSubdomains;
pub const getSubdomains = names_read.getSubdomains;
pub const getSubdomainsForParentsPage = names_read.getSubdomainsForParentsPage;
