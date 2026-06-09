/// Library root module for test imports
/// Re-exports all components needed for testing
pub const storage = struct {
    pub const database = @import("storage/database.zig");
    pub const backend = @import("storage/backend.zig");
    pub const postgres_dialect = @import("storage/drivers/postgres_dialect.zig");
    pub const postgres = @import("storage/drivers/postgres.zig");
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
