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
const ensip16 = @import("ensip16.zig");
const registrations = @import("registrations.zig");
pub const RegistrationFilterOptions = registrations.RegistrationFilterOptions;

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
        try database.exec("PRAGMA synchronous = NORMAL;");       // Faster writes (safe with WAL)
        try database.exec(std.fmt.comptimePrint("PRAGMA cache_size = {d};", .{constants.SQLite.cache_size_kb}));
        try database.exec("PRAGMA foreign_keys = ON;");          // Enable foreign key constraints
        try database.exec("PRAGMA temp_store = memory;");        // Use RAM for temp tables

        // Load and apply schema files from schema/ directory
        try database.loadSchemaFiles();

        // Run migrations (if any manual migrations are needed)
        try database.migrate();

        return database;
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

    /// Finalize and clear all cached prepared statements.
    /// Call before DDL operations (DROP TABLE, DELETE FROM large tables)
    /// to release any implicit locks held by cached statements.
    pub fn clearStatementCache(self: *Database) void {
        var it = self.stmt_cache.iterator();
        while (it.next()) |entry| {
            _ = c.sqlite3_finalize(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.stmt_cache.clearRetainingCapacity();
    }

    /// Check if a table exists in the database
    fn hasTable(self: *Database, table_name: []const u8) bool {
        var q = Query.init(self, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?") catch return false;
        defer q.deinit();
        q.bindText(table_name) catch return false;
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

    fn migrate(self: *Database) !void {
        const token_id_utils = @import("../types/token_id.zig");

        // Migration 1: Add canonical_id and token_version columns to names table
        // Check if columns exist
        const check_sql = "PRAGMA table_info(names)";
        const check_sql_z = try self.allocator.dupeZ(u8, check_sql);
        defer self.allocator.free(check_sql_z);

        var stmt: ?*c.sqlite3_stmt = null;
        const prepare_result = c.sqlite3_prepare_v2(self.db, check_sql_z.ptr, -1, &stmt, null);
        if (prepare_result != c.SQLITE_OK) {
            std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(self.db)});
            return error.PrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        var has_canonical_id = false;
        var has_token_version = false;

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const col_name = c.sqlite3_column_text(stmt, 1);
            const name = std.mem.span(col_name);
            if (std.mem.eql(u8, name, "canonical_id")) {
                has_canonical_id = true;
            }
            if (std.mem.eql(u8, name, "token_version")) {
                has_token_version = true;
            }
        }

        if (!has_canonical_id or !has_token_version) {
            std.log.info("Running migration: Adding canonical_id and token_version columns", .{});

            // Add columns if they don't exist
            if (!has_canonical_id) {
                try self.exec("ALTER TABLE names ADD COLUMN canonical_id TEXT NOT NULL DEFAULT ''");
            }
            if (!has_token_version) {
                try self.exec("ALTER TABLE names ADD COLUMN token_version INTEGER NOT NULL DEFAULT 0");
            }

            // Update existing rows to populate canonical_id and token_version from token_id
            const update_sql =
                \\SELECT namehash, token_id FROM names WHERE canonical_id = '' OR token_version = 0
            ;

            const update_sql_z = try self.allocator.dupeZ(u8, update_sql);
            defer self.allocator.free(update_sql_z);

            var select_stmt: ?*c.sqlite3_stmt = null;
            const select_prepare_result = c.sqlite3_prepare_v2(self.db, update_sql_z.ptr, -1, &select_stmt, null);
            if (select_prepare_result != c.SQLITE_OK) {
                std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(self.db)});
                return error.PrepareFailed;
            }
            defer _ = c.sqlite3_finalize(select_stmt);

            while (c.sqlite3_step(select_stmt) == c.SQLITE_ROW) {
                const namehash = c.sqlite3_column_text(select_stmt, 0);
                const token_id_str = c.sqlite3_column_text(select_stmt, 1);

                // Parse token_id from hex string
                const token_id_slice = std.mem.span(token_id_str);
                const hex_str = if (std.mem.startsWith(u8, token_id_slice, "0x")) token_id_slice[2..] else token_id_slice;
                const token_id = std.fmt.parseInt(u256, hex_str, 16) catch continue;

                // Calculate canonical_id and version
                const canonical_id = token_id_utils.getCanonicalId(token_id);
                const version = token_id_utils.getTokenVersion(token_id);

                // Format canonical_id as hex string
                var canonical_buf: [66]u8 = undefined;
                const canonical_hex = try std.fmt.bufPrint(&canonical_buf, "0x{x:0>64}", .{canonical_id});

                // Update the row
                const update_row_sql =
                    \\UPDATE names SET canonical_id = ?, token_version = ? WHERE namehash = ?
                ;

                const update_row_sql_z = try self.allocator.dupeZ(u8, update_row_sql);
                defer self.allocator.free(update_row_sql_z);

                var update_stmt: ?*c.sqlite3_stmt = null;
                const update_prepare_result = c.sqlite3_prepare_v2(self.db, update_row_sql_z.ptr, -1, &update_stmt, null);
                if (update_prepare_result != c.SQLITE_OK) {
                    std.log.err("Failed to prepare SQL statement: {s}", .{c.sqlite3_errmsg(self.db)});
                    return error.PrepareFailed;
                }
                defer _ = c.sqlite3_finalize(update_stmt);

                _ = c.sqlite3_bind_text(update_stmt, 1, canonical_hex.ptr, @intCast(canonical_hex.len), SQLITE_TRANSIENT());
                _ = c.sqlite3_bind_int64(update_stmt, 2, @intCast(version));
                _ = c.sqlite3_bind_text(update_stmt, 3, namehash, -1, SQLITE_TRANSIENT());

                _ = c.sqlite3_step(update_stmt);
            }

            // Create index if it doesn't exist
            try self.exec("CREATE INDEX IF NOT EXISTS idx_names_canonical_id ON names(canonical_id)");

            std.log.info("Migration completed successfully", .{});
        }

        // Migration 2: Registry-scoped unique constraints (migration 020)
        // For existing DBs, the schema files are skipped, so we need to apply the constraint
        // changes here. Check if the approvals table has a 'registry' column as a proxy.
        if (self.hasTable("approvals")) {
            var has_registry_col = false;

            const check_approvals_sql = "PRAGMA table_info(approvals)";
            const check_approvals_z = try self.allocator.dupeZ(u8, check_approvals_sql);
            defer self.allocator.free(check_approvals_z);

            var stmt2: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, check_approvals_z.ptr, -1, &stmt2, null) == c.SQLITE_OK) {
                defer _ = c.sqlite3_finalize(stmt2);
                while (c.sqlite3_step(stmt2) == c.SQLITE_ROW) {
                    const col_name2 = c.sqlite3_column_text(stmt2, 1);
                    if (std.mem.eql(u8, std.mem.span(col_name2), "registry")) {
                        has_registry_col = true;
                        break;
                    }
                }
            }

            if (!has_registry_col) {
                std.log.info("Running migration: Registry-scoped unique constraints (020)", .{});

                // Recreate eac_roles with contract_address in unique constraint
                try self.exec(
                    \\CREATE TABLE IF NOT EXISTS eac_roles_new (
                    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
                    \\  chain TEXT NOT NULL,
                    \\  resource TEXT NOT NULL,
                    \\  account TEXT NOT NULL,
                    \\  role_bitmap TEXT NOT NULL,
                    \\  block_number INTEGER NOT NULL,
                    \\  transaction_hash TEXT NOT NULL,
                    \\  log_index INTEGER NOT NULL,
                    \\  timestamp INTEGER NOT NULL,
                    \\  contract_address TEXT NOT NULL DEFAULT '',
                    \\  UNIQUE(chain, resource, account, contract_address)
                    \\)
                );
                try self.exec("INSERT OR IGNORE INTO eac_roles_new SELECT id, chain, resource, account, role_bitmap, block_number, transaction_hash, log_index, timestamp, contract_address FROM eac_roles");
                try self.exec("DROP TABLE eac_roles");
                try self.exec("ALTER TABLE eac_roles_new RENAME TO eac_roles");
                try self.exec("CREATE INDEX IF NOT EXISTS idx_eac_roles_chain ON eac_roles(chain)");
                try self.exec("CREATE INDEX IF NOT EXISTS idx_eac_roles_resource ON eac_roles(chain, resource)");
                try self.exec("CREATE INDEX IF NOT EXISTS idx_eac_roles_account ON eac_roles(chain, account)");
                try self.exec("CREATE INDEX IF NOT EXISTS idx_eac_roles_block ON eac_roles(chain, block_number)");
                try self.exec("CREATE INDEX IF NOT EXISTS idx_eac_roles_contract ON eac_roles(chain, contract_address)");

                // Recreate approvals with registry in unique constraint
                try self.exec(
                    \\CREATE TABLE IF NOT EXISTS approvals_new (
                    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
                    \\  chain TEXT NOT NULL,
                    \\  token_id TEXT NOT NULL,
                    \\  owner TEXT NOT NULL,
                    \\  approved TEXT NOT NULL,
                    \\  block_number INTEGER NOT NULL,
                    \\  tx_hash TEXT NOT NULL,
                    \\  timestamp INTEGER NOT NULL,
                    \\  registry TEXT NOT NULL DEFAULT '',
                    \\  UNIQUE(chain, token_id, registry)
                    \\)
                );
                try self.exec("INSERT OR IGNORE INTO approvals_new SELECT id, chain, token_id, owner, approved, block_number, tx_hash, timestamp, '' FROM approvals");
                try self.exec("DROP TABLE approvals");
                try self.exec("ALTER TABLE approvals_new RENAME TO approvals");
                try self.exec("CREATE INDEX IF NOT EXISTS idx_approvals_chain ON approvals(chain)");
                try self.exec("CREATE INDEX IF NOT EXISTS idx_approvals_token_id ON approvals(token_id)");
                try self.exec("CREATE INDEX IF NOT EXISTS idx_approvals_owner ON approvals(owner)");

                std.log.info("Migration 020 completed: registry-scoped constraints applied", .{});
            }
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
        try self.exec("DROP INDEX IF EXISTS idx_events_chain");
        try self.exec("DROP INDEX IF EXISTS idx_events_type");
        try self.exec("DROP INDEX IF EXISTS idx_events_block");
        try self.exec("DROP INDEX IF EXISTS idx_events_name");
        try self.exec("DROP INDEX IF EXISTS idx_events_namehash");
        try self.exec("DROP INDEX IF EXISTS idx_events_contract_address");
        try self.exec("DROP INDEX IF EXISTS idx_events_chain_type_block");
        try self.exec("DROP INDEX IF EXISTS idx_events_block_log");

        // Names table: drop 13 of 16 indexes (keep namehash, token_id, canonical_id)
        try self.exec("DROP INDEX IF EXISTS idx_names_chain");
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
        try self.exec("DROP INDEX IF EXISTS idx_resolvers_chain");
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
        try self.exec("DROP INDEX IF EXISTS idx_resolver_metadata_chain");
        try self.exec("DROP INDEX IF EXISTS idx_resolver_metadata_resolver");
        try self.exec("DROP INDEX IF EXISTS idx_resolver_approvals_chain");
        try self.exec("DROP INDEX IF EXISTS idx_resolver_approvals_namehash");
        try self.exec("DROP INDEX IF EXISTS idx_resolver_approvals_delegate");
        try self.exec("DROP INDEX IF EXISTS idx_resolver_approvals_context");

        // Approvals table: drop all 3 indexes
        try self.exec("DROP INDEX IF EXISTS idx_approvals_chain");
        try self.exec("DROP INDEX IF EXISTS idx_approvals_token_id");
        try self.exec("DROP INDEX IF EXISTS idx_approvals_owner");

        // Name history: drop all 5 indexes
        try self.exec("DROP INDEX IF EXISTS idx_name_history_namehash");
        try self.exec("DROP INDEX IF EXISTS idx_name_history_chain_name");
        try self.exec("DROP INDEX IF EXISTS idx_name_history_change_type");
        try self.exec("DROP INDEX IF EXISTS idx_name_history_block");
        try self.exec("DROP INDEX IF EXISTS idx_name_history_timestamp");

        // EAC roles: drop all 5 indexes
        try self.exec("DROP INDEX IF EXISTS idx_eac_roles_chain");
        try self.exec("DROP INDEX IF EXISTS idx_eac_roles_resource");
        try self.exec("DROP INDEX IF EXISTS idx_eac_roles_account");
        try self.exec("DROP INDEX IF EXISTS idx_eac_roles_block");
        try self.exec("DROP INDEX IF EXISTS idx_eac_roles_contract");

        // Temporary registrar tables: drop all 15 indexes
        try self.exec("DROP INDEX IF EXISTS idx_temp_auctions_status");
        try self.exec("DROP INDEX IF EXISTS idx_temp_auctions_winner");
        try self.exec("DROP INDEX IF EXISTS idx_temp_auctions_label");
        try self.exec("DROP INDEX IF EXISTS idx_temp_auctions_start_block");
        try self.exec("DROP INDEX IF EXISTS idx_temp_bids_label_hash");
        try self.exec("DROP INDEX IF EXISTS idx_temp_bids_bidder");
        try self.exec("DROP INDEX IF EXISTS idx_temp_bids_revealed");
        try self.exec("DROP INDEX IF EXISTS idx_temp_bids_block");
        try self.exec("DROP INDEX IF EXISTS idx_temp_bid_reveals_label_hash");
        try self.exec("DROP INDEX IF EXISTS idx_temp_bid_reveals_bidder");
        try self.exec("DROP INDEX IF EXISTS idx_temp_bid_reveals_block");
        try self.exec("DROP INDEX IF EXISTS idx_temp_bid_reveals_status");
        try self.exec("DROP INDEX IF EXISTS idx_temp_invalidations_label_hash");
        try self.exec("DROP INDEX IF EXISTS idx_temp_invalidations_name");
        try self.exec("DROP INDEX IF EXISTS idx_temp_invalidations_block");
        try self.exec("DROP INDEX IF EXISTS idx_temp_pre_migration_label_hash");
        try self.exec("DROP INDEX IF EXISTS idx_temp_pre_migration_chain");

        // Bridge events: drop all 8 indexes
        try self.exec("DROP INDEX IF EXISTS idx_migrations_token_id");
        try self.exec("DROP INDEX IF EXISTS idx_migrations_block");
        try self.exec("DROP INDEX IF EXISTS idx_migrations_direction");
        try self.exec("DROP INDEX IF EXISTS idx_renewal_syncs_token_id");
        try self.exec("DROP INDEX IF EXISTS idx_renewal_syncs_block");
        try self.exec("DROP INDEX IF EXISTS idx_token_observers_token_id");
        try self.exec("DROP INDEX IF EXISTS idx_token_observers_block");
        try self.exec("DROP INDEX IF EXISTS idx_token_observers_observer");

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
        try self.exec("CREATE INDEX IF NOT EXISTS idx_events_chain ON events(chain)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_events_type ON events(event_type)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_events_block ON events(block_number)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_events_name ON events(name)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_events_namehash ON events(namehash)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_events_contract_address ON events(contract_address)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_events_chain_type_block ON events(chain, event_type, block_number)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_events_block_log ON events(block_number, log_index)");

        // Names table indexes (14)
        try self.exec("CREATE INDEX IF NOT EXISTS idx_names_chain ON names(chain)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_names_name ON names(name)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_names_label ON names(label)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_names_owner ON names(owner)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_names_expiry ON names(expiry)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_names_registry ON names(chain, registry)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_names_resolver ON names(chain, resolver)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_names_created_block ON names(chain, created_block)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_names_registrant ON names(registrant)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_names_v1_label_hash ON names(v1_label_hash)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_names_parent_namehash ON names(parent_namehash)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_names_is_wrapped ON names(is_wrapped)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_names_is_v1_name ON names(is_v1_name)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_names_wrapper_expiry ON names(wrapper_expiry)");

        // Resolvers table indexes (2)
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolvers_chain ON resolvers(chain)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolvers_namehash ON resolvers(namehash)");

        // Resolver addresses indexes (3)
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_addresses_namehash ON resolver_addresses(namehash)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_addresses_resolver ON resolver_addresses(resolver)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_addresses_context ON resolver_addresses(chain, namehash, context)");

        // Resolver contenthashes indexes (3)
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_contenthashes_namehash ON resolver_contenthashes(namehash)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_contenthashes_resolver ON resolver_contenthashes(resolver)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_contenthashes_context ON resolver_contenthashes(chain, namehash, context)");

        // Resolver texts indexes (4)
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_texts_namehash ON resolver_texts(namehash)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_texts_resolver ON resolver_texts(resolver)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_texts_key ON resolver_texts(key)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_texts_context ON resolver_texts(chain, namehash, context)");

        // Resolver records indexes (5)
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_aliases_resolver ON resolver_aliases(resolver)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_pubkeys_namehash ON resolver_pubkeys(namehash)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_abis_namehash ON resolver_abis(namehash)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_names_namehash ON resolver_names(namehash)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_interfaces_namehash ON resolver_interfaces(namehash)");

        // Resolver metadata & approvals (ENSIP-16) indexes (6)
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_metadata_chain ON resolver_metadata(chain)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_metadata_resolver ON resolver_metadata(chain, resolver)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_approvals_chain ON resolver_approvals(chain)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_approvals_namehash ON resolver_approvals(chain, namehash)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_approvals_delegate ON resolver_approvals(chain, delegate)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_resolver_approvals_context ON resolver_approvals(chain, context)");

        // Approvals table indexes (3)
        try self.exec("CREATE INDEX IF NOT EXISTS idx_approvals_chain ON approvals(chain)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_approvals_token_id ON approvals(token_id)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_approvals_owner ON approvals(owner)");

        // Name history indexes (5)
        try self.exec("CREATE INDEX IF NOT EXISTS idx_name_history_namehash ON name_history(namehash)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_name_history_chain_name ON name_history(chain, name)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_name_history_change_type ON name_history(change_type)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_name_history_block ON name_history(chain, block_number)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_name_history_timestamp ON name_history(timestamp)");

        // EAC roles indexes (5)
        try self.exec("CREATE INDEX IF NOT EXISTS idx_eac_roles_chain ON eac_roles(chain)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_eac_roles_resource ON eac_roles(chain, resource)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_eac_roles_account ON eac_roles(chain, account)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_eac_roles_block ON eac_roles(chain, block_number)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_eac_roles_contract ON eac_roles(chain, contract_address)");

        // Temporary registrar indexes (17)
        try self.exec("CREATE INDEX IF NOT EXISTS idx_temp_auctions_status ON temp_auctions(status)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_temp_auctions_winner ON temp_auctions(winner_address)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_temp_auctions_label ON temp_auctions(label)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_temp_auctions_start_block ON temp_auctions(start_block)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_temp_bids_label_hash ON temp_bids(label_hash)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_temp_bids_bidder ON temp_bids(bidder_address)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_temp_bids_revealed ON temp_bids(revealed)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_temp_bids_block ON temp_bids(block_number)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_temp_bid_reveals_label_hash ON temp_bid_reveals(label_hash)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_temp_bid_reveals_bidder ON temp_bid_reveals(bidder_address)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_temp_bid_reveals_block ON temp_bid_reveals(block_number)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_temp_bid_reveals_status ON temp_bid_reveals(status)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_temp_invalidations_label_hash ON temp_invalidations(label_hash)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_temp_invalidations_name ON temp_invalidations(name)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_temp_invalidations_block ON temp_invalidations(invalidation_block)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_temp_pre_migration_label_hash ON temp_pre_migration_names(label_hash)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_temp_pre_migration_chain ON temp_pre_migration_names(chain)");

        // Bridge events indexes (8)
        try self.exec("CREATE INDEX IF NOT EXISTS idx_migrations_token_id ON migrations(chain, token_id)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_migrations_block ON migrations(chain, block_number)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_migrations_direction ON migrations(direction)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_renewal_syncs_token_id ON renewal_syncs(chain, token_id)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_renewal_syncs_block ON renewal_syncs(chain, block_number)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_token_observers_token_id ON token_observers(chain, token_id)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_token_observers_block ON token_observers(chain, block_number)");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_token_observers_observer ON token_observers(observer)");

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
    pub const getNamehashByResolver = names.getNamehashByResolver;
    pub const updateNameExpiry = names.updateNameExpiry;
    pub const updateNameOwner = names.updateNameOwner;
    pub const updateNameResolver = names.updateNameResolver;
    pub const getNameByTokenIdAndRegistry = names.getNameByTokenIdAndRegistry;
    pub const deleteNameByNamehash = names.deleteNameByNamehash;
    pub const updateNameTokenIdByNamehash = names.updateNameTokenIdByNamehash;
    pub const getNamesByOwner = names.getNamesByOwner;
    pub const getNamesByRegistrant = names.getNamesByRegistrant;
    pub const getAllNames = names.getAllNames;
    pub const getAllNamesWithOrder = names.getAllNamesWithOrder;
    pub const getFilteredNames = names.getFilteredNames;
    pub const OrderDir = names.OrderDir;
    pub const NameSortField = names.NameSortField;
    pub const NameFilters = names.NameFilters;
    pub const getRegistriesByOwner = names.getRegistriesByOwner;
    pub const countDirectSubdomains = names.countDirectSubdomains;
    pub const hasDirectSubdomains = names.hasDirectSubdomains;
    pub const batchCountDirectSubdomains = names.batchCountDirectSubdomains;
    pub const getSubdomains = names.getSubdomains;
    pub const updateRegistryPlaceholderName = names.updateRegistryPlaceholderName;
    pub const getTotalNameCount = names.getTotalNameCount;
    pub const getFilteredNameCount = names.getFilteredNameCount;

    // Resolver module (11 functions)
    pub const storeResolverAddress = resolvers.storeResolverAddress;
    pub const storeResolverContentHash = resolvers.storeResolverContentHash;
    pub const storeResolverText = resolvers.storeResolverText;
    pub const getResolverAddress = resolvers.getResolverAddress;
    pub const getResolverContentHash = resolvers.getResolverContentHash;
    pub const getResolverTextKeys = resolvers.getResolverTextKeys;
    pub const getResolverText = resolvers.getResolverText;
    pub const getResolverTextKeysByResolver = resolvers.getResolverTextKeysByResolver;
    pub const getResolverTextByResolver = resolvers.getResolverTextByResolver;
    pub const getResolversToIndex = resolvers.getResolversToIndex;
    pub const getResolversByOwner = resolvers.getResolversByOwner;
    pub const deleteResolverAddresses = resolvers.deleteResolverAddresses;
    pub const deleteResolverContentHash = resolvers.deleteResolverContentHash;
    pub const deleteResolverTexts = resolvers.deleteResolverTexts;
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
    pub const getResolverPubkey = resolvers.getResolverPubkey;
    pub const getResolverAbiContentTypes = resolvers.getResolverAbiContentTypes;
    pub const getResolverReverseName = resolvers.getResolverReverseName;
    pub const InterfaceRecord = resolvers.InterfaceRecord;
    pub const getResolverInterfaces = resolvers.getResolverInterfaces;
    pub const getResolverVersion = resolvers.getResolverVersion;
    pub const getResolverNodeCount = resolvers.getResolverNodeCount;
    pub const getResolverAliasCount = resolvers.getResolverAliasCount;
    pub const getResolverRoleHolderCount = resolvers.getResolverRoleHolderCount;
    pub const getResolverRoles = resolvers.getResolverRoles;

    // Names module - resolver query
    pub const getNamesByResolver = names.getNamesByResolver;

    // Sync module (14 functions)
    pub const getSyncState = sync.getSyncState;
    pub const setSyncState = sync.setSyncState;
    pub const storeBlockHash = sync.storeBlockHash;
    pub const getBlockHash = sync.getBlockHash;
    pub const rollbackToBlock = sync.rollbackToBlock;
    pub const pruneOldBlockHashes = sync.pruneOldBlockHashes;
    pub const checkIntegrity = sync.checkIntegrity;
    pub const isSubregistryKnown = sync.isSubregistryKnown;
    pub const registerSubregistry = sync.registerSubregistry;
    pub const registerResolver = sync.registerResolver;
    pub const getSubregistriesToIndex = sync.getSubregistriesToIndex;
    pub const insertMigration = sync.insertMigration;
    pub const insertRenewalSync = sync.insertRenewalSync;
    pub const insertTokenObserver = sync.insertTokenObserver;
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
    pub const getTotalEventCount = events.getTotalEventCount;
    pub const getEventCount = events.getEventCount;
    pub const countEventsByNamehash = events.countEventsByNamehash;
    pub const countEventsByDomain = events.countEventsByDomain;

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

    // ENSIP-16 module (7 functions)
    pub const upsertResolverMetadata = ensip16.upsertResolverMetadata;
    pub const getResolverMetadata = ensip16.getResolverMetadata;
    pub const getAllResolverMetadata = ensip16.getAllResolverMetadata;
    pub const upsertResolverApproval = ensip16.upsertResolverApproval;
    pub const isApprovedFor = ensip16.isApprovedFor;
    pub const getApprovalsForName = ensip16.getApprovalsForName;
    pub const getApprovalsForDelegate = ensip16.getApprovalsForDelegate;

    // Registrations module
    // These functions query registration events with proper contract filtering
    // to avoid duplicates from non-authoritative contracts
    pub const RegistrationFilterOptions = registrations.RegistrationFilterOptions;
    pub const getRegistrations = registrations.getRegistrations;
    pub const getRegistrationCount = registrations.getRegistrationCount;
    pub const getTotalRegistrationCount = registrations.getTotalRegistrationCount;
};
