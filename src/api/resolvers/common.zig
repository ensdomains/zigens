/// Common imports and utilities for ENS GraphQL resolvers
const std = @import("std");
pub const db = @import("../../storage/database.zig");
pub const models = @import("../../types/models.zig");
pub const Hash = @import("../../types/hash.zig").Hash;
pub const Address = @import("../../types/address.zig").Address;
pub const namehash_fn = @import("../../types/hash.zig").namehash;
pub const json_utils = @import("../../utils/json.zig");

// Import generic GraphQL library
pub const parser = @import("../../lib/graphql/parser.zig");
pub const pagination = @import("../../lib/graphql/pagination.zig");

// Import ENS-specific modules
pub const builders = @import("../builders/builders.zig");
pub const loaders = @import("../loaders.zig");

/// Helper to escape JSON strings
pub fn escapeJsonString(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    return json_utils.escapeString(allocator, s);
}

/// Context for nested field resolution
pub const NestedContext = builders.NestedContext;
