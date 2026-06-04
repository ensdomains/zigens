const std = @import("std");
pub const c = @cImport({
    @cInclude("sqlite3.h");
});
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
const registry_entries = @import("registry_entries.zig");
const reorg_undo = @import("reorg_undo.zig");

// Re-export types for use by other modules
pub const OrderDir = names.OrderDir;
pub const NameSortField = names.NameSortField;
pub const NameFilters = names.NameFilters;
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
const registrations = @import("registrations.zig");
pub const RegistrationFilterOptions = registrations.RegistrationFilterOptions;
const accounts = @import("accounts.zig");
pub const AccountFilters = accounts.AccountFilters;
pub const AccountSortField = accounts.AccountSortField;
pub const Account = accounts.Account;
pub const ResolverEntity = resolvers.ResolverEntity;
pub const ResolverEntityFilters = resolvers.ResolverEntityFilters;
pub const ResolverEntitySortField = resolvers.ResolverEntitySortField;

// Query abstraction module
pub const query = @import("query.zig");
pub const Query = query.Query;

// SQLITE_TRANSIENT - For Zig 0.15.1, we can't use the C constant due to alignment issues
// Instead, we use null which tells SQLite to make a copy of the string
// This is functionally equivalent to SQLITE_TRANSIENT for our use case
pub inline fn SQLITE_TRANSIENT() c.sqlite3_destructor_type {
    return null;
}

pub const Database = struct {
    allocator: std.mem.Allocator,
    db: ?*c.sqlite3,
    /// Prepared statement cache: maps SQL string → pre-compiled sqlite3_stmt
    stmt_cache: std.StringHashMap(*c.sqlite3_stmt),
    /// EIP-155 chain ID for entity-ID formatting (`{chainId}-{protocol}-…`).
    /// Set by callers via `setChainId` after init; defaults to 0 so the build
    /// fails loudly if a path forgets to populate it (the emitted id would be
    /// `0-v1-…` — visibly wrong but not unsafe).
    chain_id: u64 = 0,

    /// Records the chain ID this database serves data for. The value flows
    /// into Resolver entity IDs at JSON-build time. Called by both the
    /// indexer and the API at startup from the network config.
    pub fn setChainId(self: *Database, chain_id: u64) void {
        self.chain_id = chain_id;
    }

    // ========================================================================
    // CORE FUNCTIONS (kept in this file)
    // ========================================================================

    /// Load and execute schema files from schema/ directory
    fn loadSchemaFiles(self: *Database) !void {
        // Skip schema loading if database already has tables (schema was applied in a previous run).
        // Re-running CREATE INDEX IF NOT EXISTS on a large DB rebuilds any missing indexes,
        // which can take minutes on millions of rows (e.g., after dropSyncIndexes interrupted).
        // The deferred index strategy (dropSyncIndexes/createSyncIndexes) handles index lifecycle.
        if (self.hasTable("names")) {
            std.log.info("Database schema already applied, skipping schema loading", .{});
            return;
        }

        std.log.info("Loading schema files from schema/ directory...", .{});

        // Open schema directory
        var schema_dir = std.fs.cwd().openDir("schema", .{ .iterate = true }) catch |err| {
            std.log.err("Failed to open schema/ directory: {}", .{err});
            std.log.err("Make sure the schema/ directory exists in the current working directory", .{});
            return error.SchemaDirectoryNotFound;
        };
        defer schema_dir.close();

        // Collect all .sql files
        var file_list: std.ArrayList([]const u8) = .{};
        defer {
            for (file_list.items) |f| self.allocator.free(f);
            file_list.deinit(self.allocator);
        }

        var iter = schema_dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".sql")) {
                const filename = try self.allocator.dupe(u8, entry.name);
                try file_list.append(self.allocator, filename);
            }
        }

        // Sort files alphabetically (001_*.sql, 002_*.sql, etc.)
        std.mem.sort([]const u8, file_list.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        // Execute each schema file in order
        for (file_list.items) |filename| {
            std.log.info("  Applying schema: {s}", .{filename});

            // Read file contents
            const file_content = schema_dir.readFileAlloc(self.allocator, filename, 1024 * 1024) catch |err| {
                std.log.err("Failed to read schema file {s}: {}", .{ filename, err });
                return error.SchemaFileReadFailed;
            };
            defer self.allocator.free(file_content);

            // Execute SQL
            try self.exec(file_content);
        }

        std.log.info("Schema loading complete ({d} file{s} applied)", .{
            file_list.items.len,
            if (file_list.items.len == 1) "" else "s",
        });
    }

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Database {
        var db: ?*c.sqlite3 = null;

        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        const result = c.sqlite3_open(path_z.ptr, &db);
        if (result != c.SQLITE_OK) {
            std.log.err("Failed to open database: {s}", .{c.sqlite3_errmsg(db)});
            return error.DatabaseOpenFailed;
        }

        var database = Database{
            .allocator = allocator,
            .db = db,
            .stmt_cache = std.StringHashMap(*c.sqlite3_stmt).init(allocator),
        };

        // Enable WAL mode for better concurrency (allows concurrent reads during writes)
        try database.exec("PRAGMA journal_mode=WAL;");

        // Performance and reliability PRAGMAs (values from constants.zig)
        try database.exec(std.fmt.comptimePrint("PRAGMA busy_timeout = {d};", .{constants.SQLite.busy_timeout_ms}));
        try database.exec("PRAGMA synchronous = NORMAL;"); // Faster writes (safe with WAL)
        try database.exec(std.fmt.comptimePrint("PRAGMA cache_size = {d};", .{constants.SQLite.cache_size_kb}));
        try database.exec("PRAGMA foreign_keys = ON;"); // Enable foreign key constraints
        try database.exec("PRAGMA temp_store = memory;"); // Use RAM for temp tables
        // Required by the reorg undo-log: derived tables (resolver records, approvals,
        // …) are rewritten with INSERT OR REPLACE, whose implicit row delete only fires
        // the AFTER DELETE capture trigger when recursive triggers are enabled. Without
        // this, in-place overwrites would silently bypass undo capture (see reorg_undo.zig).
        try database.exec("PRAGMA recursive_triggers = ON;");

        // Load and apply the consolidated schema from schema/schema.sql.
        // The expected workflow for schema changes is to re-index from scratch
        // — `schema/schema.sql` defines the final shape of every table. The
        // `migrate()` scaffold below is intentionally kept as an empty hook
        // so future emergency in-place migrations have a wired path without
        // re-introducing the per-file migration ladder.
        try database.loadSchemaFiles();
        try database.migrate();

        // Reorg undo-log: capture tables + per-table triggers so rollbackToBlock can
        // reverse in-place mutations. Generated from the live schema; gated by
        // reorg_cursor (no capture unless the indexer sets the current block).
        try reorg_undo.ensureSchema(&database);
        try reorg_undo.installTriggers(&database);

        return database;
    }

    /// Scaffold for in-place migrations against existing databases that
    /// pre-date a schema change. **Currently a no-op:** the consolidated
    /// `schema/schema.sql` defines the final shape, and the documented
    /// upgrade path is re-indexing.
    ///
    /// Add idempotent ALTER/UPDATE statements here when a future schema
    /// change must be applied to existing databases without a full re-sync.
    /// Use `try self.exec("ALTER TABLE … ADD COLUMN …")` — `exec()` swallows
    /// the "duplicate column name" error when the column already exists, so
    /// each migration block is safe to re-run.
    fn migrate(self: *Database) !void {
        // Add the `is_normalized` column to pre-existing `names` tables. Idempotent:
        // exec() swallows the "duplicate column" error on DBs that already have it
        // (fresh DBs get it from schema.sql). DEFAULT 1 keeps existing rows visible
        // until the indexer recomputes the flag on the next write/heal of each name.
        if (self.hasTable("names")) {
            try self.exec("ALTER TABLE names ADD COLUMN is_normalized INTEGER NOT NULL DEFAULT 1");
            try self.exec("CREATE INDEX IF NOT EXISTS idx_names_is_normalized ON names(is_normalized)");
        }

        // `loadSchemaFiles` short-circuits when `names` exists (to avoid
        // multi-minute index rebuilds on large DBs), so any *new* tables
        // introduced after the original schema must be created here too.
        //
        // If a previous build created `accounts` with the old single-protocol
        // shape (`first_seen_protocol TEXT`), drop and recreate with the new
        // per-protocol-flag shape. The table is a derived projection of names/
        // registrations, so dropping is safe — the backfill below repopulates.
        if (self.hasTable("accounts") and self.columnExists("accounts", "first_seen_protocol")) {
            try self.exec("DROP TABLE accounts");
            std.log.info("Dropped legacy `accounts` (single-protocol shape) for per-protocol-flag migration", .{});
        }
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS accounts (
            \\  address TEXT PRIMARY KEY,
            \\  seen_v1 INTEGER NOT NULL DEFAULT 0,
            \\  seen_v2 INTEGER NOT NULL DEFAULT 0,
            \\  first_seen_block INTEGER NOT NULL,
            \\  first_seen_timestamp INTEGER NOT NULL
            \\)
        );
        try self.exec("CREATE INDEX IF NOT EXISTS idx_accounts_seen_v1 ON accounts(seen_v1) WHERE seen_v1 = 1");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_accounts_seen_v2 ON accounts(seen_v2) WHERE seen_v2 = 1");

        // One-time backfill of the new entity tables. Skipped when the
        // backfill source tables (`names`, `sync_state`) don't exist yet —
        // that happens in `initWithoutSchema` test fixtures that create
        // only the tables they care about. Once the indexer event handlers
        // maintain these tables in real time (Phase 3), these backfills
        // become belt-and-suspenders for any DB that was indexed before
        // the writers were wired up.
        if (self.hasTable("names") and self.hasTable("sync_state")) {
            if ((try accounts.getAccountCount(self)) == 0) {
                const n = try accounts.backfillFromExistingData(self);
                if (n > 0) std.log.info("Backfilled {d} accounts from existing data", .{n});
            }
            if ((try resolvers.getResolverEntityCount(self)) == 0) {
                const n = try resolvers.backfillResolverEntitiesFromNames(self);
                if (n > 0) std.log.info("Backfilled {d} resolver entities from names.resolver", .{n});
            }
            // Ensure the root domain row exists (subgraph parity). The ENS root
            // (namehash 0x000…000, empty name) isn't created by any event handler
            // — the subgraph constructs it implicitly. Insert a synthetic row
            // with `parent_namehash` self-referential to the root namehash; any
            // ancestor walker terminates when it sees `namehash == parent_namehash`,
            // mirroring how the subgraph handles the root.
            //
            // The cleanup-DELETE in front is one-time defensive plumbing: an
            // earlier migration draft inserted the root with `parent_namehash = ''`,
            // which makes downstream Hash.fromHex readers throw. INSERT OR IGNORE
            // never overwrites, so we delete-and-recreate to guarantee the row
            // has the current shape. The DELETE-key on (namehash, parent_namehash='')
            // makes the fixup idempotent — once corrected, the predicate matches
            // nothing on subsequent boots.
            try self.exec(
                \\DELETE FROM names
                \\WHERE namehash = '0x0000000000000000000000000000000000000000000000000000000000000000'
                \\  AND parent_namehash = ''
            );
            try self.exec(
                \\INSERT OR IGNORE INTO names (
                \\  protocol, name, namehash, label, label_hash,
                \\  parent_name, parent_namehash, registry, owner, resolver,
                \\  token_id, canonical_id, token_version,
                \\  created_block, created_at, updated_block, updated_at
                \\) VALUES (
                \\  'v1', '',
                \\  '0x0000000000000000000000000000000000000000000000000000000000000000',
                \\  '',
                \\  '0x0000000000000000000000000000000000000000000000000000000000000000',
                \\  '',
                \\  '0x0000000000000000000000000000000000000000000000000000000000000000',
                \\  '0x0000000000000000000000000000000000000000',
                \\  '0x0000000000000000000000000000000000000000',
                \\  '0x0000000000000000000000000000000000000000',
                \\  '0', '0', 0,
                \\  0, 0, 0, 0
                \\)
            );
        }
    }

    /// Initialize database without auto-loading schemas (for custom schema directories)
    pub fn initWithoutSchema(allocator: std.mem.Allocator, path: []const u8) !Database {
        var db: ?*c.sqlite3 = null;

        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        const result = c.sqlite3_open(path_z.ptr, &db);
        if (result != c.SQLITE_OK) {
            std.log.err("Failed to open database: {s}", .{c.sqlite3_errmsg(db)});
            return error.DatabaseOpenFailed;
        }

        var database = Database{
            .allocator = allocator,
            .db = db,
            .stmt_cache = std.StringHashMap(*c.sqlite3_stmt).init(allocator),
        };

        // Enable WAL mode for better concurrency
        try database.exec("PRAGMA journal_mode=WAL;");

        // Performance and reliability PRAGMAs (values from constants.zig)
        try database.exec(std.fmt.comptimePrint("PRAGMA busy_timeout = {d};", .{constants.SQLite.busy_timeout_ms}));
        try database.exec("PRAGMA synchronous = NORMAL;");
        try database.exec(std.fmt.comptimePrint("PRAGMA cache_size = {d};", .{constants.SQLite.cache_size_kb}));
        try database.exec("PRAGMA foreign_keys = ON;");
        try database.exec("PRAGMA temp_store = memory;");
        // Match the writer connection (see init): harmless on this read-only path.
        try database.exec("PRAGMA recursive_triggers = ON;");

        // Intentionally no `migrate()` here. The API is a read-only consumer of
        // a DB that the indexer is the sole writer of. Running migrate from the
        // API path would take a brief write lock at startup that collides with
        // an indexer running on the same file — see git history for the bug
        // this caused. Schema bootstrap is the indexer's responsibility.

        return database;
    }

    pub fn deinit(self: *Database) void {
        // Finalize all cached prepared statements and free their keys
        var it = self.stmt_cache.iterator();
        while (it.next()) |entry| {
            _ = c.sqlite3_finalize(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.stmt_cache.deinit();

        if (self.db) |db| {
            _ = c.sqlite3_close(db);
        }
    }

    /// Check if a table exists in the database
    fn hasTable(self: *Database, table_name: []const u8) bool {
        var q = Query.init(self, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?") catch return false;
        defer q.deinit();
        q.bindText(table_name) catch return false;
        return (q.step() catch return false);
    }

    /// `pragma_table_info` returns one row per column on the given table.
    /// We use it from `migrate()` to detect legacy column layouts that need
    /// in-place migration.
    fn columnExists(self: *Database, table_name: []const u8, column_name: []const u8) bool {
        var q = Query.init(self, "SELECT 1 FROM pragma_table_info(?) WHERE name = ?") catch return false;
        defer q.deinit();
        q.bindText(table_name) catch return false;
        q.bindText(column_name) catch return false;
        return (q.step() catch return false);
    }

    pub fn exec(self: *Database, sql: []const u8) !void {
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        var err_msg: [*c]u8 = null;
        const result = c.sqlite3_exec(self.db, sql_z.ptr, null, null, &err_msg);

        if (result != c.SQLITE_OK) {
            defer c.sqlite3_free(err_msg);

            // Gracefully handle "duplicate column" errors from ALTER TABLE ADD COLUMN
            // These occur when schema migrations have already been applied
            if (err_msg != null) {
                const err_str = std.mem.span(err_msg);
                if (std.mem.indexOf(u8, err_str, "duplicate column name") != null) {
                    std.log.debug("Skipping duplicate column: {s}", .{err_msg});
                    return; // Silently ignore duplicate column errors
                }
            }

            std.log.err("SQL error: {s}", .{err_msg});
            return error.SqlExecFailed;
        }
    }

    // ========================================================================
    // BULK SYNC INDEX MANAGEMENT
    // ========================================================================

    /// Drop non-essential indexes for faster bulk inserts during initial sync.
    /// Keeps only indexes required for sync lookup operations:
    /// - UNIQUE constraints (built into table defs, can't be dropped)
    /// - idx_names_namehash, idx_names_token_id, idx_names_canonical_id (handler lookups)
    /// - idx_v1_labels_*, idx_v1_controllers_active (V1 handler lookups)
    /// - idx_registries_*, idx_known_*_last_indexed, idx_orphaned_* (sync tracking)
    /// - idx_block_hashes_timestamp (block tracking)
    pub fn dropSyncIndexes(self: *Database) !void {
        std.log.info("Dropping non-essential indexes for bulk sync...", .{});

        // Events table: drop all 8 indexes (none needed during sync)
        try self.exec("DROP INDEX IF EXISTS idx_events_protocol");
        try self.exec("DROP INDEX IF EXISTS idx_events_type");
        try self.exec("DROP INDEX IF EXISTS idx_events_block");
        try self.exec("DROP INDEX IF EXISTS idx_events_name");
        try self.exec("DROP INDEX IF EXISTS idx_events_namehash");
        try self.exec("DROP INDEX IF EXISTS idx_events_contract_address");
        try self.exec("DROP INDEX IF EXISTS idx_events_protocol_type_block");
        try self.exec("DROP INDEX IF EXISTS idx_events_block_log");

        // Names table: drop 13 of 16 indexes (keep namehash, token_id, canonical_id)
        try self.exec("DROP INDEX IF EXISTS idx_names_protocol");
        try self.exec("DROP INDEX IF EXISTS idx_names_name");
        try self.exec("DROP INDEX IF EXISTS idx_names_label");
        try self.exec("DROP INDEX IF EXISTS idx_names_owner");
        try self.exec("DROP INDEX IF EXISTS idx_names_expiry");
        try self.exec("DROP INDEX IF EXISTS idx_names_registry");
        try self.exec("DROP INDEX IF EXISTS idx_names_resolver");
        try self.exec("DROP INDEX IF EXISTS idx_names_created_block");
        try self.exec("DROP INDEX IF EXISTS idx_names_registrant");
        try self.exec("DROP INDEX IF EXISTS idx_names_v1_label_hash");
        try self.exec("DROP INDEX IF EXISTS idx_names_parent_namehash");
        try self.exec("DROP INDEX IF EXISTS idx_names_is_wrapped");
        try self.exec("DROP INDEX IF EXISTS idx_names_is_v1_name");
        try self.exec("DROP INDEX IF EXISTS idx_names_wrapper_expiry");

        // Resolvers table: drop all 2 indexes (write-only during sync)
        try self.exec("DROP INDEX IF EXISTS idx_resolvers_protocol");
        try self.exec("DROP INDEX IF EXISTS idx_resolvers_namehash");

        // Resolver addresses: drop all 3 indexes
        try self.exec("DROP INDEX IF EXISTS idx_resolver_addresses_namehash");
        try self.exec("DROP INDEX IF EXISTS idx_resolver_addresses_resolver");
        try self.exec("DROP INDEX IF EXISTS idx_resolver_addresses_context");

        // Resolver contenthashes: drop all 3 indexes
        try self.exec("DROP INDEX IF EXISTS idx_resolver_contenthashes_namehash");
        try self.exec("DROP INDEX IF EXISTS idx_resolver_contenthashes_resolver");
        try self.exec("DROP INDEX IF EXISTS idx_resolver_contenthashes_context");

        // Resolver texts: drop all 4 indexes
        try self.exec("DROP INDEX IF EXISTS idx_resolver_texts_namehash");
        try self.exec("DROP INDEX IF EXISTS idx_resolver_texts_resolver");
        try self.exec("DROP INDEX IF EXISTS idx_resolver_texts_key");
        try self.exec("DROP INDEX IF EXISTS idx_resolver_texts_context");

        // Resolver records (aliases, pubkeys, abis, names, interfaces): drop all 5
        try self.exec("DROP INDEX IF EXISTS idx_resolver_aliases_resolver");
        try self.exec("DROP INDEX IF EXISTS idx_resolver_pubkeys_namehash");
        try self.exec("DROP INDEX IF EXISTS idx_resolver_abis_namehash");
        try self.exec("DROP INDEX IF EXISTS idx_resolver_names_namehash");
        try self.exec("DROP INDEX IF EXISTS idx_resolver_interfaces_namehash");

        // Resolver metadata & approvals (ENSIP-16): drop all 6
        try self.exec("DROP INDEX IF EXISTS idx_resolver_metadata_protocol");
        try self.exec("DROP INDEX IF EXISTS idx_resolver_metadata_resolver");
        try self.exec("DROP INDEX IF EXISTS idx_resolver_approvals_protocol");
        try self.exec("DROP INDEX IF EXISTS idx_resolver_approvals_namehash");
        try self.exec("DROP INDEX IF EXISTS idx_resolver_approvals_delegate");
        try self.exec("DROP INDEX IF EXISTS idx_resolver_approvals_context");

        // Approvals table: drop all 3 indexes
        try self.exec("DROP INDEX IF EXISTS idx_approvals_protocol");
        try self.exec("DROP INDEX IF EXISTS idx_approvals_token_id");
        try self.exec("DROP INDEX IF EXISTS idx_approvals_owner");

        // Name history: drop all 5 indexes
        try self.exec("DROP INDEX IF EXISTS idx_name_history_namehash");
        try self.exec("DROP INDEX IF EXISTS idx_name_history_protocol_name");
        try self.exec("DROP INDEX IF EXISTS idx_name_history_change_type");
        try self.exec("DROP INDEX IF EXISTS idx_name_history_block");
        try self.exec("DROP INDEX IF EXISTS idx_name_history_timestamp");

        // EAC roles: drop all 5 indexes
        try self.exec("DROP INDEX IF EXISTS idx_eac_roles_protocol");
        try self.exec("DROP INDEX IF EXISTS idx_eac_roles_resource");
        try self.exec("DROP INDEX IF EXISTS idx_eac_roles_account");
        try self.exec("DROP INDEX IF EXISTS idx_eac_roles_block");
        try self.exec("DROP INDEX IF EXISTS idx_eac_roles_contract");

        // Temporary registrar pre-migration table indexes (the
        // temp_auctions/temp_bids/temp_bid_reveals/temp_invalidations tables
        // were removed; only temp_pre_migration_names remains).
        try self.exec("DROP INDEX IF EXISTS idx_temp_pre_migration_label_hash");
        try self.exec("DROP INDEX IF EXISTS idx_temp_pre_migration_protocol");

        // Rainbow labels & unknown labels: drop all 5 indexes
        try self.exec("DROP INDEX IF EXISTS idx_rainbow_source");
        try self.exec("DROP INDEX IF EXISTS idx_rainbow_block");
        try self.exec("DROP INDEX IF EXISTS idx_unknown_labels_backfill");
        try self.exec("DROP INDEX IF EXISTS idx_unknown_labels_tx_hash");
        try self.exec("DROP INDEX IF EXISTS idx_unknown_labels_labelhash");

        std.log.info("Dropped non-essential indexes for bulk sync performance", .{});
    }

    /// Recreate all indexes after bulk sync is complete.
    /// This is much faster than maintaining indexes during bulk inserts.
    pub fn createSyncIndexes(self: *Database) !void {
        const timer = std.time.milliTimestamp();
        std.log.info("Recreating indexes after bulk sync...", .{});

        // Events table indexes (8)
        try self.exec("CREATE INDEX IF NOT EXISTS idx_events_protocol ON events(protocol)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_events_type ON events(event_type)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_events_block ON events(block_number)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_events_name ON events(name)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_events_namehash ON events(namehash)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_events_contract_address ON events(contract_address)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_events_protocol_type_block ON events(protocol, event_type, block_number)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_events_block_log ON events(block_number, log_index)");

        // Names table indexes (14)
        try self.exec("CREATE INDEX IF NOT EXISTS idx_names_protocol ON names(protocol)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_names_name ON names(name)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_names_label ON names(label)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_names_owner ON names(owner)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_names_expiry ON names(expiry)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_names_registry ON names(protocol, registry)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_names_resolver ON names(protocol, resolver)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_names_created_block ON names(protocol, created_block)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_names_registrant ON names(registrant)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_names_v1_label_hash ON names(v1_label_hash)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_names_parent_namehash ON names(parent_namehash)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_names_is_wrapped ON names(is_wrapped)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_names_is_v1_name ON names(is_v1_name)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_names_wrapper_expiry ON names(wrapper_expiry)");

        // Resolvers table indexes (2)
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolvers_protocol ON resolvers(protocol)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolvers_namehash ON resolvers(namehash)");

        // Resolver addresses indexes (3)
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_addresses_namehash ON resolver_addresses(namehash)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_addresses_resolver ON resolver_addresses(resolver)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_addresses_context ON resolver_addresses(protocol, namehash, context)");

        // Resolver contenthashes indexes (3)
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_contenthashes_namehash ON resolver_contenthashes(namehash)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_contenthashes_resolver ON resolver_contenthashes(resolver)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_contenthashes_context ON resolver_contenthashes(protocol, namehash, context)");

        // Resolver texts indexes (4)
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_texts_namehash ON resolver_texts(namehash)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_texts_resolver ON resolver_texts(resolver)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_texts_key ON resolver_texts(key)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_texts_context ON resolver_texts(protocol, namehash, context)");

        // Resolver records indexes (5)
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_aliases_resolver ON resolver_aliases(resolver)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_pubkeys_namehash ON resolver_pubkeys(namehash)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_abis_namehash ON resolver_abis(namehash)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_names_namehash ON resolver_names(namehash)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_interfaces_namehash ON resolver_interfaces(namehash)");

        // Resolver metadata & approvals (ENSIP-16) indexes (6)
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_metadata_protocol ON resolver_metadata(protocol)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_metadata_resolver ON resolver_metadata(protocol, resolver)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_approvals_protocol ON resolver_approvals(protocol)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_approvals_namehash ON resolver_approvals(protocol, namehash)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_approvals_delegate ON resolver_approvals(protocol, delegate)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_approvals_context ON resolver_approvals(protocol, context)");

        // Approvals table indexes (3)
        try self.exec("CREATE INDEX IF NOT EXISTS idx_approvals_protocol ON approvals(protocol)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_approvals_token_id ON approvals(token_id)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_approvals_owner ON approvals(owner)");

        // Name history indexes (5)
        try self.exec("CREATE INDEX IF NOT EXISTS idx_name_history_namehash ON name_history(namehash)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_name_history_protocol_name ON name_history(protocol, name)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_name_history_change_type ON name_history(change_type)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_name_history_block ON name_history(protocol, block_number)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_name_history_timestamp ON name_history(timestamp)");

        // EAC roles indexes (5)
        try self.exec("CREATE INDEX IF NOT EXISTS idx_eac_roles_protocol ON eac_roles(protocol)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_eac_roles_resource ON eac_roles(protocol, resource)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_eac_roles_account ON eac_roles(protocol, account)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_eac_roles_block ON eac_roles(protocol, block_number)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_eac_roles_contract ON eac_roles(protocol, contract_address)");

        // Temporary registrar pre-migration table indexes (only
        // temp_pre_migration_names remains after the V1 audit cleanup).
        try self.exec("CREATE INDEX IF NOT EXISTS idx_temp_pre_migration_label_hash ON temp_pre_migration_names(label_hash)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_temp_pre_migration_protocol ON temp_pre_migration_names(protocol)");

        // Rainbow labels & unknown labels indexes (5)
        try self.exec("CREATE INDEX IF NOT EXISTS idx_rainbow_source ON rainbow_labels(source)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_rainbow_block ON rainbow_labels(first_seen_block)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_unknown_labels_backfill ON unknown_labels(backfill_attempts, created_at) WHERE backfill_attempts < 3");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_unknown_labels_tx_hash ON unknown_labels(transaction_hash)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_unknown_labels_labelhash ON unknown_labels(labelhash)");

        const elapsed = std.time.milliTimestamp() - timer;
        std.log.info("Index recreation complete ({d}ms)", .{elapsed});
    }

    // ========================================================================
    // RE-EXPORTED FUNCTIONS FROM MODULES
    // ========================================================================
    // All functions below delegate to their respective module implementations.
    // This maintains the exact same API: db.insertName(...) still works!

    // Names module (15 functions)
    pub const insertRegistry = names.insertRegistry;
    pub const insertName = names.insertName;
    pub const getNameByNamehash = names.getNameByNamehash;
    pub const getNameStringByNamehash = names.getNameStringByNamehash;
    pub const getNameByNamehashAndProtocol = names.getNameByNamehashAndProtocol;
    pub const getNamehashByResolver = names.getNamehashByResolver;
    pub const updateNameExpiry = names.updateNameExpiry;
    pub const clearNameExpiry = names.clearNameExpiry;
    pub const updateDomainExpiryIfGreater = names.updateDomainExpiryIfGreater;
    pub const materializePccDomainExpiry = names.materializePccDomainExpiry;
    pub const updateNameOwner = names.updateNameOwner;
    pub const markNameMigrated = names.markNameMigrated;
    pub const upsertReverseRecord = resolvers.upsertReverseRecord;
    pub const getReverseRecordNamehash = resolvers.getReverseRecordNamehash;
    pub const updateNameResolver = names.updateNameResolver;
    pub const updateResolvedAddressToNull = names.updateResolvedAddressToNull;
    pub const recursivelyGcEmptyDomain = names.recursivelyGcEmptyDomain;
    pub const updateNameTTL = names.updateNameTTL;
    pub const updateNameIsLegacy = names.updateNameIsLegacy;
    pub const applyLatestResolverFromEvents = resolvers.applyLatestResolverFromEvents;
    pub const getNameByTokenIdAndRegistry = names.getNameByTokenIdAndRegistry;
    pub const deleteNameByNamehash = names.deleteNameByNamehash;
    pub const updateNameTokenIdByNamehash = names.updateNameTokenIdByNamehash;
    pub const getNamesByOwner = names.getNamesByOwner;
    pub const getAllNames = names.getAllNames;
    pub const getAllNamesWithOrder = names.getAllNamesWithOrder;
    pub const getFilteredNames = names.getFilteredNames;
    pub const countRowsBeforeNamehash = names.countRowsBeforeNamehash;
    pub const OrderDir = names.OrderDir;
    pub const NameSortField = names.NameSortField;
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
    pub const getTextRecordKeys = resolvers.getTextRecordKeys;
    pub const getTextRecord = resolvers.getTextRecord;
    pub const getResolversToIndex = resolvers.getResolversToIndex;
    pub const getResolversByOwner = resolvers.getResolversByOwner;
    pub const upsertResolverEntity = resolvers.upsertResolverEntity;
    pub const getResolverEntityCount = resolvers.getResolverEntityCount;
    pub const backfillResolverEntitiesFromNames = resolvers.backfillResolverEntitiesFromNames;
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
    pub const AliasRecord = resolvers.AliasRecord;
    pub const getResolverAliases = resolvers.getResolverAliases;
    pub const storeResolverPubkey = resolvers.storeResolverPubkey;
    pub const storeResolverABI = resolvers.storeResolverABI;
    pub const storeResolverName = resolvers.storeResolverName;
    pub const storeResolverInterface = resolvers.storeResolverInterface;
    pub const storeResolverVersion = resolvers.storeResolverVersion;
    pub const PubkeyRecord = resolvers.PubkeyRecord;
    pub const getPubkeyRecord = resolvers.getPubkeyRecord;
    pub const getAbiContentTypes = resolvers.getAbiContentTypes;
    pub const getReverseNameRecord = resolvers.getReverseNameRecord;
    pub const getLatestNameByNamehash = resolvers.getLatestNameByNamehash;
    pub const InterfaceRecord = resolvers.InterfaceRecord;
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
    pub const setSyncState = sync.setSyncState;
    pub const storeBlockHash = sync.storeBlockHash;
    pub const getBlockHash = sync.getBlockHash;
    pub const rollbackToBlock = sync.rollbackToBlock;
    pub const pruneOldBlockHashes = sync.pruneOldBlockHashes;
    pub const checkIntegrity = sync.checkIntegrity;
    pub const registerSubregistry = sync.registerSubregistry;
    pub const registerResolver = sync.registerResolver;
    pub const discoverAndGetSubregistries = sync.discoverAndGetSubregistries;
    pub const deleteDataAfterBlock = sync.deleteDataAfterBlock;
    pub const OrphanedRegistration = sync.OrphanedRegistration;
    pub const insertOrphanedRegistration = sync.insertOrphanedRegistration;
    pub const getOrphanedRegistrations = sync.getOrphanedRegistrations;
    pub const deleteOrphanedRegistrations = sync.deleteOrphanedRegistrations;

    // Events module
    pub const insertEvent = events.insertEvent;
    pub const getRecentEvents = events.getRecentEvents;
    pub const getRecentEventsWithOrder = events.getRecentEventsWithOrder;
    pub const EventOrderDir = events.OrderDir;
    pub const EventSortField = events.EventSortField;
    pub const EventFilterOptions = events.EventFilterOptions;
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
    pub const deleteEACRole = roles.deleteEACRole;
    pub const RolePaginationOptions = roles.RolePaginationOptions;
    pub const getRolesWithPagination = roles.getRolesWithPagination;
    pub const getTotalRoleCount = roles.getTotalRoleCount;
    pub const getRoleCountFiltered = roles.getRoleCountFiltered;
    pub const RoleCountFilters = roles.RoleCountFilters;

    // ENSIP-16 module (7 functions)
    pub const upsertResolverMetadata = ensip16.upsertResolverMetadata;
    pub const getResolverMetadata = ensip16.getResolverMetadata;
    pub const getAllResolverMetadata = ensip16.getAllResolverMetadata;
    pub const upsertResolverApproval = ensip16.upsertResolverApproval;
    pub const isApprovedFor = ensip16.isApprovedFor;
    pub const getApprovalsForName = ensip16.getApprovalsForName;
    pub const getApprovalsForDelegate = ensip16.getApprovalsForDelegate;

    // Registrations module
    // Registrations read directly from the dedicated `registrations` table
    // (schema/021), not derived from `events`. Single canonical writer per
    // (protocol, namehash) — see registrations.zig for the full rationale.
    pub const RegistrationFilterOptions = registrations.RegistrationFilterOptions;
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
    pub const collectSubregistrySubtree = registry_entries.collectSubtreeRooted;
    pub const setRegistriesReachability = registry_entries.setRegistriesReachability;
    pub const markNameUnreachableByNamehash = registry_entries.markNameUnreachableByNamehash;

    // Accounts module — first-class Account entity (subgraph parity)
    pub const upsertAccount = accounts.upsertAccount;
    pub const getAccount = accounts.getAccount;
    pub const getAccountCount = accounts.getAccountCount;
    pub const getFilteredAccounts = accounts.getFilteredAccounts;
};
