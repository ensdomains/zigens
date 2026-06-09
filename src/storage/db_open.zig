//! Backend selection + config-driven Database bootstrap. Kept separate from
//! database.zig so the core storage layer (compiled into every binary) stays free of the
//! Postgres driver / pg.zig dependency: only code that actually opens a config-selected
//! Database (this module, reached via lib or a main that imports it) pulls in `pg`.
const std = @import("std");
const config = @import("../config.zig");
const backend = @import("backend.zig");
const sqlite_driver = @import("drivers/sqlite.zig");
const postgres_driver = @import("drivers/postgres.zig");
const Database = @import("database.zig").Database;

/// Open the backend named by `kind`. SQLite uses `sqlite_path`; Postgres parses
/// `database_url` (required) into ConnectOpts and connects. Caller owns the returned
/// Backend (close via `vtable.close`, or hand it to `Database.initWithBackend`).
pub fn selectBackend(
    allocator: std.mem.Allocator,
    kind: config.BackendKind,
    sqlite_path: []const u8,
    database_url: ?[]const u8,
) !backend.Backend {
    return switch (kind) {
        .sqlite => sqlite_driver.open(allocator, sqlite_path),
        .postgres => blk: {
            const url = database_url orelse return error.MissingDatabaseUrl;
            const opts = try postgres_driver.parseUrl(url);
            break :blk try postgres_driver.open(allocator, opts);
        },
    };
}

/// Config-driven Database bootstrap: select the backend per `cfg`, then run the shared
/// `initWithBackend` (schema load + migrate + reorg install). The returned Database owns
/// the backend; `initWithBackend` closes it on its own failure, so there is no leak window
/// here. This is the entry point the indexer/API mains adopt in place of `Database.init`.
pub fn openFromConfig(allocator: std.mem.Allocator, cfg: config.Config) !Database {
    const be = try selectBackend(allocator, cfg.backend_kind, cfg.database_path, cfg.database_url);
    return Database.initWithBackend(allocator, be);
}
