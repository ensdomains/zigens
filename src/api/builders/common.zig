/// Common imports and utilities for ENS entity builders
const std = @import("std");
pub const db = @import("../../storage/database.zig");
pub const models = @import("../../types/models.zig");
pub const Hash = @import("../../types/hash.zig").Hash;
pub const Address = @import("../../types/address.zig").Address;
pub const json_utils = @import("../../utils/json.zig");
pub const ens_normalize = @import("ens_normalize");

// Import generic GraphQL library
pub const parser = @import("../../lib/graphql/parser.zig");

// Import ENS-specific modules
pub const fields = @import("../ens_fields.zig");
pub const json_builder = @import("../json_builder.zig");
pub const loaders_mod = @import("../loaders.zig");
pub const resolvers_mod = @import("../../storage/resolvers.zig");

/// Max uint64 value representing "no expiry" for subnames
pub const NO_EXPIRY: u64 = std.math.maxInt(u64);

/// Check if expiry value represents a valid expiry date (not 0 or max uint64)
pub fn hasValidExpiry(expiry: u64) bool {
    return expiry > 0 and expiry < NO_EXPIRY;
}

/// Context for nested field resolution
pub const NestedContext = struct {
    database: *db.Database,
    depth: u32,
    allocator: std.mem.Allocator,
    loaders: ?*anyopaque,
};

/// Helper to escape JSON strings
pub fn escapeJsonString(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    return json_utils.escapeString(allocator, s);
}
