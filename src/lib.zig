/// Library root module for test imports
/// Re-exports all components needed for testing
pub const zsys = @import("utils/system.zig");
pub const storage = struct {
    pub const database = @import("storage/database.zig");
    pub const backend = @import("storage/backend.zig");
    pub const postgres_dialect = @import("storage/drivers/postgres_dialect.zig");
    pub const postgres = @import("storage/drivers/postgres.zig");
    pub const sqlite = @import("storage/drivers/sqlite.zig");
    pub const Database = database.Database;
    pub const Query = database.Query;

    pub const names = @import("storage/names.zig");
    pub const events = @import("storage/events.zig");
    pub const resolvers = @import("storage/resolvers.zig");
    pub const roles = @import("storage/roles.zig");
    pub const webhooks = @import("storage/webhooks.zig");
    pub const registrations = @import("storage/registrations.zig");
    pub const sync = @import("storage/sync.zig");
    pub const reorg_undo = @import("storage/reorg_undo.zig");
    pub const v1_controllers = @import("storage/v1_controllers.zig");
    pub const unknown_labels = @import("storage/unknown_labels.zig");
    pub const registry_entries = @import("storage/registry_entries.zig");
    pub const name_prefetch = @import("storage/name_prefetch.zig");
    pub const names_registry = @import("storage/names_registry.zig");
    pub const db_open = @import("storage/db_open.zig");
    pub const pool = @import("storage/pool.zig");
};

pub const config = @import("config.zig");
pub const contracts = @import("contracts.zig");

pub const api = struct {
    pub const eac_roles = @import("api/eac_roles.zig");
    // Exposed so the conformance harness reaches GraphQLHandler through the SAME
    // module graph as `lib.Database` (one Database type across the test).
    pub const handler = @import("api/handler.zig");
    // MCP protocol core — transport-free (processMcp + Executor), so the
    // test lane drives the full JSON-RPC surface over a seeded database.
    pub const mcp = @import("api/mcp.zig");
};

/// Resolution layer (Tasks 04-06). Exposed so tests can build a LiveContext / Resolver
/// and drive the flag-ON live-resolution path against a pre-seeded cache (no network).
pub const resolve = struct {
    pub const client = @import("resolve/client.zig");
    pub const cache = @import("resolve/cache.zig");
    pub const universal = @import("resolve/universal.zig");
    pub const primary = @import("resolve/primary.zig");
};
pub const rpc = struct {
    pub const client = @import("rpc/client.zig");
};

pub const indexer = struct {
    pub const label_backfill = @import("indexer/label_backfill.zig");
};

pub const types = struct {
    pub const models = @import("types/models.zig");
    pub const address = @import("types/address.zig");
    pub const Address = address.Address;
    pub const hash = @import("types/hash.zig");
    pub const Hash = hash.Hash;
    pub const namehash = hash.namehash;
    pub const keccak256 = hash.keccak256;
};

// Direct access for convenience
pub const Database = storage.Database;
pub const Address = types.Address;
pub const Hash = types.Hash;
pub const models = types.models;
pub const namehash = types.namehash;
pub const keccak256 = types.keccak256;

/// Compute labelhash (keccak256 of a single label)
pub fn labelhash(allocator: @import("std").mem.Allocator, label: []const u8) !Hash {
    return keccak256(allocator, label);
}
