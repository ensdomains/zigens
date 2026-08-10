const std = @import("std");
const zsys = @import("../utils/system.zig");
const constants = @import("../constants.zig");
const models = @import("../types/models.zig");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;

// Note: SQLite thread-safety configuration (sqlite3_config) must be called
// at the start of main() BEFORE any other SQLite operations.
// See indexer_main.zig and api_main.zig for the initialization.

// Import all module functions
const names = @import("names.zig");
const resolvers = @import("resolvers.zig");
const heal_targets = @import("heal_targets.zig");
const registry_entries = @import("registry_entries.zig");
const reorg_undo = @import("reorg_undo.zig");
const resolve_cache = @import("../resolve/cache.zig");
const finality = @import("finality.zig");
const schema = @import("schema.zig");

// Re-export types for use by other modules
pub const OrderDir = names.OrderDir;
pub const NameSortField = names.NameSortField;
pub const NameFilters = names.NameFilters;
pub const KeysetAnchor = names.KeysetAnchor;
const sync = @import("sync.zig");
const events = @import("events.zig");
pub const EventOrderDir = events.OrderDir;
pub const EventSortField = events.EventSortField;
pub const EventFilterOptions = events.EventFilterOptions;
const webhooks = @import("webhooks.zig");
const transactions = @import("transactions.zig");
const roles = @import("roles.zig");
pub const RolePaginationOptions = roles.RolePaginationOptions;
pub const RoleCountFilters = roles.RoleCountFilters;
const ensip16 = @import("ensip16.zig");
const named_resources = @import("named_resources.zig");
const registrations = @import("registrations.zig");
pub const RegistrationFilterOptions = registrations.RegistrationFilterOptions;
const accounts = @import("accounts.zig");
pub const AccountFilters = accounts.AccountFilters;
pub const AccountSortField = accounts.AccountSortField;
pub const Account = accounts.Account;
pub const NamedResource = named_resources.NamedResource;
pub const ResolverEntityFilters = resolvers.ResolverEntityFilters;
pub const ResolverEntitySortField = resolvers.ResolverEntitySortField;

// Query abstraction module
pub const query = @import("query.zig");
pub const Query = query.Query;

// Backend SPI + statement-seam driver (Phase 0: SQLite). Connection lifecycle
// (open/close), exec, and prepare are owned by the driver and dispatched through
// `Database.backend.vtable`.
const backend_mod = @import("backend.zig");
const sqlite_driver = @import("drivers/sqlite.zig");
const schema_keys = @import("schema_keys.zig");
/// RAII transaction guard, re-exported for storage modules.
pub const Tx = backend_mod.Tx;
/// SQLite serialized-mode setup; call once at process start before any DB open.
pub const configureSqliteThreadSafety = sqlite_driver.configureSerialized;

pub const Database = struct {
    allocator: std.mem.Allocator,
    /// Active backend. exec/prepare/begin/commit/close dispatch through its
    /// vtable; the connection state (handle + statement cache) lives inside the
    /// backend's driver, not on `Database`.
    backend: backend_mod.Backend,
    /// EIP-155 chain ID for entity-ID formatting (`{chainId}-{protocol}-…`).
    /// Set by callers via `setChainId` after init; defaults to 0 so the build
    /// fails loudly if a path forgets to populate it (the emitted id would be
    /// `0-v1-…` — visibly wrong but not unsafe).
    chain_id: u64 = 0,
    /// SQLite page-cache size (MB) applied by dropSyncIndexes for bulk sync.
    /// Set by the indexer from Config (SYNC_CACHE_MB, .env-aware); process env
    /// still overrides inside dropSyncIndexes. Paths that never bulk-sync
    /// (API, tools, tests) keep the default.
    sync_cache_mb: u64 = 512,

    /// Records the chain ID this database serves data for. The value flows
    /// into Resolver entity IDs at JSON-build time. Called by both the
    /// indexer and the API at startup from the network config.
    pub fn setChainId(self: *Database, chain_id: u64) void {
        self.chain_id = chain_id;
    }

    // ========================================================================
    // CORE FUNCTIONS (kept in this file)
    // ========================================================================

    /// Build a Database over an already-opened backend (SQLite or Postgres) and run
    /// the full bootstrap: load the dialect-appropriate schema (schema/ vs
    /// schema/postgres/), run migrations, then install the reorg undo-log tables +
    /// triggers. Takes ownership of `be` — the returned Database's deinit() closes it.
    ///
    /// Every step here is internally dialect-aware: loadSchemaFiles picks the dir,
    /// migrate() skips the SQLite-only in-place upgrades on Postgres, and
    /// reorg_undo.ensureSchema/installTriggers branch on the dialect. Both backends
    /// therefore share this one bootstrap path, and `selectBackend`-driven callers
    /// (next step) can hand it either driver's Backend.
    pub fn initWithBackend(allocator: std.mem.Allocator, be: backend_mod.Backend) !Database {
        var database = Database{
            .allocator = allocator,
            .backend = be,
        };
        errdefer database.deinit();

        // Backends without in-engine undo capture (server_side_undo=false) use
        // the application write-path fallback: the storage mutators capture
        // pre-images via reorg_undo.captureWhere/captureUpsert/captureActive*
        // (no triggers installed below). See docs/backend-spi.md.
        if (!be.caps.server_side_undo) {
            std.log.info("backend has no server-side undo triggers; write-path reorg capture active", .{});
        }

        // Load and apply the consolidated schema. The expected workflow for schema
        // changes is to re-index from scratch — schema.sql defines the final shape of
        // every table. The `migrate()` scaffold is kept as a thin hook so future
        // emergency in-place migrations have a wired path without re-introducing the
        // per-file migration ladder.
        try schema.loadSchemaFiles(&database);
        try schema.migrate(&database);

        // Reorg undo-log: capture tables + per-table triggers so rollbackToBlock can
        // reverse in-place mutations. Generated from the live schema; gated by
        // reorg_cursor (no capture unless the indexer sets the current block).
        try reorg_undo.ensureSchema(&database);
        if (be.caps.server_side_undo) try reorg_undo.installTriggers(&database);

        // Resolution cache: idempotent CREATE so already-synced deployments gain the
        // table without a reindex. Must exist before rollbackToBlock, which purges it.
        try resolve_cache.ensureSchema(&database);
        // Finality tiers (Task 09): idempotent CREATE, same rationale.
        try finality.ensureSchema(&database);

        return database;
    }

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Database {
        // The SQLite driver opens the connection (+ applies PRAGMAs, incl.
        // recursive_triggers, load-bearing for the reorg undo-log) and owns the
        // connection state. initWithBackend runs the shared bootstrap.
        return initWithBackend(allocator, try sqlite_driver.open(allocator, path));
    }

    /// Initialize database without auto-loading schemas (for custom schema directories)
    pub fn initWithoutSchema(allocator: std.mem.Allocator, path: []const u8) !Database {
        // Driver opens + applies the same PRAGMAs as init (recursive_triggers is
        // harmless on this read-only path).
        const database = Database{
            .allocator = allocator,
            .backend = try sqlite_driver.open(allocator, path),
        };

        // Intentionally no `migrate()` here. The API is a read-only consumer of
        // a DB that the indexer is the sole writer of. Running migrate from the
        // API path would take a brief write lock at startup that collides with
        // an indexer running on the same file — see git history for the bug
        // this caused. Schema bootstrap is the indexer's responsibility.

        return database;
    }

    pub fn deinit(self: *Database) void {
        self.backend.vtable.close(self.backend.ptr);
    }

    /// Check if a table exists in the database. Dialect-agnostic: introspectColumns
    /// returns an empty slice for a missing table on both backends (SQLite PRAGMA
    /// table_info yields no rows; Postgres information_schema yields no rows), and any
    /// I/O error is treated as "absent" to preserve the previous swallow-and-return-false
    /// contract its callers (loadSchemaFiles/migrate guards) rely on.
    pub fn hasTable(self: *Database, table_name: []const u8) bool {
        const cols = self.introspectColumns(self.allocator, table_name) catch return false;
        defer backend_mod.freeColumnInfo(self.allocator, cols);
        return cols.len > 0;
    }

    /// `pragma_table_info` returns one row per column on the given table.
    /// We use it from `migrate()` to detect legacy column layouts that need
    /// in-place migration.
    pub fn columnExists(self: *Database, table_name: []const u8, column_name: []const u8) bool {
        var q = Query.init(self, "SELECT 1 FROM pragma_table_info(?) WHERE name = ?") catch return false;
        defer q.deinit();
        q.bindText(table_name) catch return false;
        q.bindText(column_name) catch return false;
        return (q.step() catch return false);
    }

    /// Execute a parameterless statement, dispatched through the backend.
    pub fn exec(self: *Database, sql: []const u8) !void {
        return self.backend.vtable.execRaw(self.backend.ptr, sql);
    }

    /// Prepare a statement through the active backend (Phase 0: SQLite).
    /// Returns a backend-agnostic `Query` (= `backend.Statement`).
    pub fn prepare(self: *Database, sql: []const u8) !query.Query {
        return self.backend.vtable.prepare(self.backend.ptr, sql, false);
    }

    /// Prepare a statement using the per-`Database` prepared-statement cache.
    pub fn prepareCached(self: *Database, sql: []const u8) !query.Query {
        return self.backend.vtable.prepare(self.backend.ptr, sql, true);
    }

    /// ROWID of the most recent successful INSERT on this connection.
    pub fn lastInsertId(self: *Database) i64 {
        return self.backend.vtable.lastInsertId(self.backend.ptr);
    }

    /// The active backend's SQL-dialect builders.
    pub fn dialect(self: *Database) *const backend_mod.Dialect {
        return self.backend.dialect;
    }

    pub fn caps(self: *Database) backend_mod.Capabilities {
        return self.backend.caps;
    }

    /// True when the active backend is PostgreSQL. The dialect's placeholder style
    /// (`$N` vs `?`) is the load-bearing discriminator the rest of the seam keys on.
    pub fn isPostgres(self: *Database) bool {
        return self.backend.dialect.placeholder == .dollar;
    }

    /// Column metadata (name, declared type, PK position) for `table`, queried
    /// from the live schema via the backend. Caller owns the result and frees it
    /// with `backend.freeColumnInfo`.
    pub fn introspectColumns(self: *Database, allocator: std.mem.Allocator, table: []const u8) ![]backend_mod.ColumnInfo {
        return self.backend.vtable.introspectColumns(self.backend.ptr, allocator, table);
    }

    /// Build a backend-appropriate upsert statement for `table`, inserting
    /// `cols` (in bind order) with `action` on conflict. The caller owns the
    /// returned SQL and must free it after preparing. The conflict key is
    /// resolved centrally from the schema (the Postgres `ON CONFLICT` target;
    /// ignored by SQLite, whose verb implies it).
    pub fn upsertSql(
        self: *Database,
        allocator: std.mem.Allocator,
        table: []const u8,
        cols: []const []const u8,
        action: backend_mod.ConflictAction,
    ) ![]u8 {
        const conflict_cols = schema_keys.conflictColsFor(table) orelse return error.UnknownUpsertTable;
        return self.backend.dialect.upsert(allocator, table, cols, &.{}, conflict_cols, action);
    }

    /// Multi-row `upsertSql` (all-`?` placeholders, bound row-major). Callers
    /// must guarantee no two rows share the table's conflict key in one
    /// statement — Postgres rejects that outright where sequential single-row
    /// upserts were silently per-row.
    pub fn upsertMultiSql(
        self: *Database,
        allocator: std.mem.Allocator,
        table: []const u8,
        cols: []const []const u8,
        rows: usize,
        action: backend_mod.ConflictAction,
    ) ![]u8 {
        const conflict_cols = schema_keys.conflictColsFor(table) orelse return error.UnknownUpsertTable;
        return self.backend.dialect.upsertMulti(allocator, table, cols, rows, conflict_cols, action);
    }

    /// Like `upsertSql`, but each column's value is given by `value_exprs[i]` — a
    /// `?` placeholder, a SQL literal (`'migration'`/`NULL`/`0`), or a wrapper
    /// (`LOWER(?)`). For upserts whose original `VALUES` mixed binds with literals.
    pub fn upsertExprSql(
        self: *Database,
        allocator: std.mem.Allocator,
        table: []const u8,
        cols: []const []const u8,
        value_exprs: []const []const u8,
        action: backend_mod.ConflictAction,
    ) ![]u8 {
        const conflict_cols = schema_keys.conflictColsFor(table) orelse return error.UnknownUpsertTable;
        return self.backend.dialect.upsert(allocator, table, cols, value_exprs, conflict_cols, action);
    }

    /// Backend-appropriate `INSERT … <select_body>` upsert (no `VALUES`). For the
    /// one-time `INSERT OR IGNORE … SELECT` seeding paths. Caller owns the result.
    pub fn insertSelectSql(
        self: *Database,
        allocator: std.mem.Allocator,
        table: []const u8,
        cols: []const []const u8,
        select_body: []const u8,
        action: backend_mod.ConflictAction,
    ) ![]u8 {
        const conflict_cols = schema_keys.conflictColsFor(table) orelse return error.UnknownUpsertTable;
        return self.backend.dialect.insertSelect(allocator, table, cols, select_body, conflict_cols, action);
    }

    // ========================================================================
    // BULK SYNC INDEX MANAGEMENT
    // ========================================================================

    /// Drop non-essential indexes for faster bulk inserts during initial sync.
    /// Keeps only indexes required for sync lookup operations:
    /// - UNIQUE constraints (built into table defs, can't be dropped)
    /// - idx_names_namehash, idx_names_token_id, idx_names_canonical_id (handler lookups)
    /// - idx_events_name (the in-place event name-patch matches events by name)
    /// - idx_v1_labels_*, idx_v1_controllers_active (V1 handler lookups)
    /// - idx_registries_*, idx_known_*_last_indexed, idx_orphaned_* (sync tracking)
    /// - idx_block_hashes_timestamp (block tracking)
    pub fn dropSyncIndexes(self: *Database) !void {
        return schema.dropSyncIndexes(self);
    }

    /// Recreate all indexes after bulk sync is complete.
    /// This is much faster than maintaining indexes during bulk inserts.
    pub fn createSyncIndexes(self: *Database) !void {
        return schema.createSyncIndexes(self);
    }

    /// Truncate the SQLite WAL and log its depth (no-op on PostgreSQL).
    pub fn checkpointWal(self: *Database) void {
        return schema.checkpointWal(self);
    }

    /// Drain the WAL between bulk-sync chunks without truncating (no-op on PostgreSQL).
    /// Current -wal file size in bytes (SQLite only; null when unavailable).
    pub fn walFileSize(self: *Database) ?u64 {
        return schema.walFileSize(self);
    }

    pub fn checkpointWalPassive(self: *Database) void {
        return schema.checkpointWalPassive(self);
    }

    // ========================================================================
    // RE-EXPORTED FUNCTIONS FROM MODULES
    // ========================================================================
    // All functions below delegate to their respective module implementations.
    // This maintains the exact same API: db.insertName(...) still works!

    // Init-gap heal ledger (storage/heal_targets.zig)
    pub const enqueueHealTarget = heal_targets.enqueueHealTarget;
    pub const recordHealTargetSuccess = heal_targets.recordHealTargetSuccess;
    pub const recordHealTargetFailure = heal_targets.recordHealTargetFailure;
    pub const pendingHealTargets = heal_targets.pendingHealTargets;
    pub const hasPendingHealTargets = heal_targets.hasPendingHealTargets;
    pub const countExhaustedHealTargets = heal_targets.countExhaustedHealTargets;
    pub const resetHealTargets = heal_targets.resetHealTargets;

    // Names module (15 functions)
    pub const insertRegistry = names.insertRegistry;
    pub const insertName = names.insertName;
    pub const insertNamesBatch = names.insertNamesBatch;
    pub const getNameByNamehash = names.getNameByNamehash;
    pub const getNameStringByNamehash = names.getNameStringByNamehash;
    pub const getNameByNamehashAndProtocol = names.getNameByNamehashAndProtocol;
    pub const getNamehashByResolver = names.getNamehashByResolver;
    pub const updateNameExpiry = names.updateNameExpiry;
    pub const updateDomainExpiryIfGreater = names.updateDomainExpiryIfGreater;
    pub const materializePccDomainExpiry = names.materializePccDomainExpiry;
    pub const updateNameOwner = names.updateNameOwner;
    pub const markNameMigrated = names.markNameMigrated;
    pub const upsertReverseRecord = resolvers.upsertReverseRecord;
    pub const getReverseRecordNamehash = resolvers.getReverseRecordNamehash;
    pub const updateNameResolver = names.updateNameResolver;
    pub const recursivelyGcEmptyDomain = names.recursivelyGcEmptyDomain;
    pub const applyLatestResolverFromEvents = resolvers.applyLatestResolverFromEvents;
    pub const getNameByTokenIdAndRegistry = names.getNameByTokenIdAndRegistry;
    pub const getUniqueNameByCanonicalId = names.getUniqueNameByCanonicalId;
    pub const deleteNameByNamehash = names.deleteNameByNamehash;
    pub const updateNameTokenIdByNamehash = names.updateNameTokenIdByNamehash;
    pub const getNamesByOwner = names.getNamesByOwner;
    pub const getAllNames = names.getAllNames;
    pub const getAllNamesWithOrder = names.getAllNamesWithOrder;
    pub const getFilteredNames = names.getFilteredNames;
    pub const countRowsBeforeNamehash = names.countRowsBeforeNamehash;
    pub const getFilteredNamesKeyset = names.getFilteredNamesKeyset;
    pub const NameFilters = names.NameFilters;
    pub const getRegistriesByOwner = names.getRegistriesByOwner;
    pub const getRegistry = names.getRegistry;
    pub const countDirectSubdomains = names.countDirectSubdomains;
    pub const hasDirectSubdomains = names.hasDirectSubdomains;
    pub const getSubdomains = names.getSubdomains;
    pub const updateRegistryPlaceholderName = names.updateRegistryPlaceholderName;
    pub const updatePlaceholderEventsByName = names.updatePlaceholderEventsByName;
    pub const getFilteredNameCount = names.getFilteredNameCount;

    // Resolver module (11 functions)
    pub const storeResolverAddress = resolvers.storeResolverAddress;
    pub const storeResolverContentHash = resolvers.storeResolverContentHash;
    pub const storeResolverText = resolvers.storeResolverText;
    pub const getAddressRecord = resolvers.getAddressRecord;
    pub const getAddressRecords = resolvers.getAddressRecords;
    pub const getCoinTypes = resolvers.getCoinTypes;
    pub const countEventsBeforeCursor = events.countEventsBeforeCursor;
    pub const getContentHashRecord = resolvers.getContentHashRecord;
    pub const getAddressRecordsBatch = resolvers.getAddressRecordsBatch;
    pub const getContentHashesBatch = resolvers.getContentHashesBatch;
    pub const getTextRecordsBatch = resolvers.getTextRecordsBatch;
    pub const getTextRecordKeys = resolvers.getTextRecordKeys;
    pub const getTextRecord = resolvers.getTextRecord;
    pub const getResolversByOwner = resolvers.getResolversByOwner;
    pub const upsertResolverEntity = resolvers.upsertResolverEntity;
    pub const getFilteredResolverEntities = resolvers.getFilteredResolverEntities;
    pub const deleteResolverAddresses = resolvers.deleteResolverAddresses;
    pub const deleteResolverContentHash = resolvers.deleteResolverContentHash;
    pub const deleteResolverTexts = resolvers.deleteResolverTexts;
    pub const deleteResolverText = resolvers.deleteResolverText;
    pub const storeResolverAuthorisation = resolvers.storeResolverAuthorisation;
    pub const storeResolverDnsRecord = resolvers.storeResolverDnsRecord;
    pub const deleteResolverDnsRecord = resolvers.deleteResolverDnsRecord;
    pub const storeResolverDnsZonehash = resolvers.storeResolverDnsZonehash;
    pub const deleteResolverAlias = resolvers.deleteResolverAlias;
    pub const deleteResolverPubkeys = resolvers.deleteResolverPubkeys;
    pub const deleteResolverAbis = resolvers.deleteResolverAbis;
    pub const deleteResolverNames = resolvers.deleteResolverNames;
    pub const deleteResolverInterfaces = resolvers.deleteResolverInterfaces;
    pub const storeResolverAlias = resolvers.storeResolverAlias;
    pub const getResolverAliases = resolvers.getResolverAliases;
    pub const storeResolverPubkey = resolvers.storeResolverPubkey;
    pub const storeResolverABI = resolvers.storeResolverABI;
    pub const storeResolverName = resolvers.storeResolverName;
    pub const storeResolverInterface = resolvers.storeResolverInterface;
    pub const storeResolverVersion = resolvers.storeResolverVersion;
    pub const getPubkeyRecord = resolvers.getPubkeyRecord;
    pub const getAbiContentTypes = resolvers.getAbiContentTypes;
    pub const getReverseNameRecord = resolvers.getReverseNameRecord;
    pub const getLatestNameByNamehash = resolvers.getLatestNameByNamehash;
    pub const getInterfaceRecords = resolvers.getInterfaceRecords;
    pub const getNodeRecordVersion = resolvers.getNodeRecordVersion;
    pub const getResolverNodeCount = resolvers.getResolverNodeCount;
    pub const getResolverAliasCount = resolvers.getResolverAliasCount;
    pub const getResolverRoleHolderCount = resolvers.getResolverRoleHolderCount;
    pub const getResolverRoles = resolvers.getResolverRoles;

    // Names module - resolver query
    pub const getNamesByResolver = names.getNamesByResolver;
    pub const getDomainByResolver = names.getDomainByResolver;
    pub const WrappedDomainFilters = names.WrappedDomainFilters;
    pub const getWrappedDomains = names.getWrappedDomains;

    // Sync module (14 functions)
    pub const getSyncState = sync.getSyncState;
    pub const getSyncStateFull = sync.getSyncStateFull;
    pub const ProtocolSync = sync.ProtocolSync;
    pub const setSyncState = sync.setSyncState;
    pub const storeBlockHash = sync.storeBlockHash;
    pub const getBlockHash = sync.getBlockHash;
    pub const setFinality = finality.setFinality;
    pub const getFinality = finality.getFinality;
    pub const rollbackToBlock = sync.rollbackToBlock;
    pub const pruneOldBlockHashes = sync.pruneOldBlockHashes;
    pub const checkIntegrity = sync.checkIntegrity;
    pub const probeLiveness = sync.probeLiveness;
    pub const ensureSyncPathIndexes = schema.ensureSyncPathIndexes;
    pub const registerSubregistry = sync.registerSubregistry;
    pub const registerResolver = sync.registerResolver;
    pub const registerResolverIfNew = sync.registerResolverIfNew;
    pub const isKnownResolver = sync.isKnownResolver;
    pub const discoverAndGetSubregistries = sync.discoverAndGetSubregistries;
    pub const getSubregistryCreatedBlock = sync.getSubregistryCreatedBlock;
    pub const deleteDataAfterBlock = sync.deleteDataAfterBlock;
    pub const OrphanedRegistration = sync.OrphanedRegistration;
    pub const insertOrphanedRegistration = sync.insertOrphanedRegistration;
    pub const getOrphanedRegistrations = sync.getOrphanedRegistrations;
    pub const deleteOrphanedRegistrations = sync.deleteOrphanedRegistrations;

    // Events module
    pub const insertEvent = events.insertEvent;
    pub const insertEventsBatch = events.insertEventsBatch;
    pub const repairPlaceholderEvents = events.repairPlaceholderEvents;
    pub const insertEventIfNew = events.insertEventIfNew;
    pub const getRecentEvents = events.getRecentEvents;
    pub const getEventsFiltered = events.getEventsFiltered;
    pub const getEventsByNamehash = events.getEventsByNamehash;
    pub const getEventsByDomain = events.getEventsByDomain;
    pub const insertApproval = events.insertApproval;
    pub const updateApprovalTokenId = events.updateApprovalTokenId;
    pub const getEventCount = events.getEventCount;
    pub const countEventsByNamehash = events.countEventsByNamehash;

    // Webhooks module (3 functions)
    pub const insertWebhook = webhooks.insertWebhook;
    pub const deleteWebhook = webhooks.deleteWebhook;
    pub const getWebhooks = webhooks.getWebhooks;
    pub const getWebhook = webhooks.getWebhook;
    pub const updateWebhook = webhooks.updateWebhook;

    // Transactions module (3 functions)
    pub const beginTransaction = transactions.beginTransaction;
    pub const commitTransaction = transactions.commitTransaction;
    pub const rollbackTransaction = transactions.rollbackTransaction;

    // Roles module (7 functions)
    pub const upsertEACRole = roles.upsertEACRole;
    pub const getRolesByResource = roles.getRolesByResource;
    pub const getRolesByAccount = roles.getRolesByAccount;
    pub const getRolesFiltered = roles.getRolesFiltered;
    pub const deleteEACRole = roles.deleteEACRole;
    pub const getRolesWithPagination = roles.getRolesWithPagination;
    pub const getTotalRoleCount = roles.getTotalRoleCount;
    pub const getRoleCountFiltered = roles.getRoleCountFiltered;
    pub const getLabelRoleHolderCount = roles.getLabelRoleHolderCount;

    // ENSIP-16 module (7 functions)
    pub const upsertResolverMetadata = ensip16.upsertResolverMetadata;
    pub const getResolverMetadata = ensip16.getResolverMetadata;
    pub const getAllResolverMetadata = ensip16.getAllResolverMetadata;
    pub const upsertResolverApproval = ensip16.upsertResolverApproval;
    pub const upsertNamedResource = named_resources.upsertNamedResource;
    pub const getNamedResources = named_resources.getNamedResources;
    pub const isApprovedFor = ensip16.isApprovedFor;
    pub const getApprovalsForName = ensip16.getApprovalsForName;
    pub const getApprovalsForDelegate = ensip16.getApprovalsForDelegate;

    // Registrations module
    // Registrations read directly from the dedicated `registrations` table
    // (schema/021), not derived from `events`. Single canonical writer per
    // (protocol, namehash) — see registrations.zig for the full rationale.
    pub const getRegistrations = registrations.getRegistrations;
    pub const getRegistrationCount = registrations.getRegistrationCount;
    pub const insertRegistration = registrations.insertRegistration;
    pub const updateRegistrationEconomics = registrations.updateRegistrationEconomics;
    pub const updateRegistrationExpiry = registrations.updateRegistrationExpiry;
    pub const updateRegistrationRegistrant = registrations.updateRegistrationRegistrant;
    pub const countRegistrationsBeforeCursor = registrations.countRegistrationsBeforeCursor;

    // Registry entries module — on-chain Entry mirror & reachability cascade
    pub const upsertRegistryEntrySubregistry = registry_entries.upsertSubregistry;
    pub const getRegistryEntrySubregistry = registry_entries.getSubregistry;
    pub const getRegistryEntryLiveParents = registry_entries.getLiveParents;
    pub const collectSubregistrySubtree = registry_entries.collectSubtreeRooted;
    pub const isRegistryReachable = registry_entries.isRegistryReachable;
    pub const reconcileV2Reachability = registry_entries.reconcileV2Reachability;
    pub const setRegistriesReachability = registry_entries.setRegistriesReachability;
    pub const markNameUnreachableByNamehash = registry_entries.markNameUnreachableByNamehash;

    // Accounts module — first-class Account entity (subgraph parity)
    pub const upsertAccount = accounts.upsertAccount;
    pub const getAccount = accounts.getAccount;
    pub const getFilteredAccounts = accounts.getFilteredAccounts;
};
