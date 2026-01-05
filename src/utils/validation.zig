const std = @import("std");
const constants = @import("../constants.zig");

/// Maximum lengths for various input types (industry standard limits)
pub const MAX_ENS_NAME_LENGTH: usize = 255; // DNS label standard
pub const MAX_HEX_ADDRESS_LENGTH: usize = 42; // "0x" + 40 hex chars
pub const MAX_REQUEST_BODY_SIZE: usize = 1024 * 1024; // 1MB for GraphQL queries
pub const MAX_GRAPHQL_QUERY_LENGTH: usize = constants.Validation.max_graphql_query_length;

/// Validates an ENS name for reasonable length
/// Prevents DoS attacks via extremely long names
pub fn validateEnsName(name: []const u8) !void {
    if (name.len == 0) {
        return error.NameEmpty;
    }
    if (name.len > MAX_ENS_NAME_LENGTH) {
        return error.NameTooLong;
    }
}

/// Validates GraphQL query length
/// Prevents DoS attacks via massive query strings
pub fn validateGraphQLQuery(query: []const u8) !void {
    if (query.len == 0) {
        return error.QueryEmpty;
    }
    if (query.len > MAX_GRAPHQL_QUERY_LENGTH) {
        return error.QueryTooLong;
    }
}

test "validateEnsName accepts valid names" {
    try validateEnsName("example.eth");
    try validateEnsName("subdomain.example.eth");
    try validateEnsName("a");
}

test "validateEnsName rejects empty name" {
    try std.testing.expectError(error.NameEmpty, validateEnsName(""));
}

test "validateEnsName rejects name too long" {
    const long_name = "x" ** 300;
    try std.testing.expectError(error.NameTooLong, validateEnsName(long_name));
}

test "validateGraphQLQuery accepts valid queries" {
    try validateGraphQLQuery("query { domains { name } }");
}

test "validateGraphQLQuery rejects empty query" {
    try std.testing.expectError(error.QueryEmpty, validateGraphQLQuery(""));
}

test "validateGraphQLQuery rejects query too long" {
    const allocator = std.testing.allocator;
    const long_query = try allocator.alloc(u8, MAX_GRAPHQL_QUERY_LENGTH + 1);
    defer allocator.free(long_query);
    @memset(long_query, 'x');
    try std.testing.expectError(error.QueryTooLong, validateGraphQLQuery(long_query));
}
