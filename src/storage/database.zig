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
const sync = @import("sync.zig");
const events = @import("events.zig");
pub const EventOrderDir = events.OrderDir;
pub const EventFilterOptions = events.EventFilterOptions;
const webhooks = @import("webhooks.zig");
const transactions = @import("transactions.zig");
const roles = @import("roles.zig");
const ensip16 = @import("ensip16.zig");
const registrations = @import("registrations.zig");

// Query abstraction module
pub const query = @import("query.zig");
pub const Query = query.Query;

// SQLITE_TRANSIENT - For Zig 0.15.1, we can't use the C constant due to alignment issues
// Instead, we use null which tells SQLite to make a copy of the string
// This is functionally equivalent to SQLITE_TRANSIENT for our use case
inline fn SQLITE_TRANSIENT() c.sqlite3_destructor_type {
    return null;
}

pub const Database = struct {
    allocator: std.mem.Allocator,
    db: ?*c.sqlite3,

    // ========================================================================
    // CORE FUNCTIONS (kept in this file)
    // ========================================================================

    /// Load and execute schema files from schema/ directory
    fn loadSchemaFiles(self: *Database) !void {
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
        if (self.db) |db| {
            _ = c.sqlite3_close(db);
        }
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
    pub const updateNameSubregistry = names.updateNameSubregistry;
    pub const updateNameResolver = names.updateNameResolver;
    pub const getNameByTokenId = names.getNameByTokenId;
    pub const getNameByCanonicalId = names.getNameByCanonicalId;
    pub const updateNameExpiryByTokenId = names.updateNameExpiryByTokenId;
    pub const deleteNameByTokenId = names.deleteNameByTokenId;
    pub const updateNameTokenId = names.updateNameTokenId;
    pub const getNamesByOwner = names.getNamesByOwner;
    pub const getNamesByRegistrant = names.getNamesByRegistrant;
    pub const getAllNames = names.getAllNames;
    pub const getAllNamesWithOrder = names.getAllNamesWithOrder;
    pub const OrderDir = names.OrderDir;
    pub const getRegistriesByOwner = names.getRegistriesByOwner;
    pub const countDirectSubdomains = names.countDirectSubdomains;
    pub const hasDirectSubdomains = names.hasDirectSubdomains;
    pub const getSubdomains = names.getSubdomains;
    pub const updateRegistryPlaceholderName = names.updateRegistryPlaceholderName;

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
    pub const getSubregistriesToIndex = sync.getSubregistriesToIndex;
    pub const insertMigration = sync.insertMigration;
    pub const insertRenewalSync = sync.insertRenewalSync;
    pub const insertTokenObserver = sync.insertTokenObserver;
    pub const deleteDataAfterBlock = sync.deleteDataAfterBlock;

    // Events module
    pub const insertEvent = events.insertEvent;
    pub const getRecentEvents = events.getRecentEvents;
    pub const getRecentEventsWithOrder = events.getRecentEventsWithOrder;
    pub const EventOrderDir = events.OrderDir;
    pub const EventFilterOptions = events.EventFilterOptions;
    pub const getEventsFiltered = events.getEventsFiltered;
    pub const getEventsByNamehash = events.getEventsByNamehash;
    pub const getEventsByDomain = events.getEventsByDomain;
    pub const insertApproval = events.insertApproval;

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

    // Roles module (4 functions)
    pub const upsertEACRole = roles.upsertEACRole;
    pub const getRolesByResource = roles.getRolesByResource;
    pub const getRolesByAccount = roles.getRolesByAccount;
    pub const deleteEACRole = roles.deleteEACRole;

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
};
