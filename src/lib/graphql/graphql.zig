//! Generic GraphQL Library for Zig
//!
//! A complete GraphQL implementation including:
//! - Lexer and Parser for GraphQL queries
//! - Query executor with resolver pattern
//! - Relay-spec cursor pagination
//! - Query complexity analysis for DoS protection
//! - JSON string escaping for response writers
//!
//! Usage:
//! ```zig
//! const graphql = @import("lib/graphql/graphql.zig");
//!
//! // Parse a query
//! var p = try graphql.Parser.init(allocator, query_string);
//! var doc = try p.parseDocument();
//! defer doc.deinit(allocator);
//!
//! // Analyze complexity
//! var analyzer = graphql.ComplexityAnalyzer.init(allocator, .{});
//! const analysis = try analyzer.analyzeDocument(&doc);
//!
//! defer loader.deinit();
//! ```

const std = @import("std");

// ============================================================================
// Module Imports
// ============================================================================

pub const parser = @import("parser.zig");
pub const pagination = @import("pagination.zig");
pub const complexity = @import("complexity.zig");
pub const metrics = @import("metrics.zig");
pub const fields = @import("fields.zig");

// ============================================================================
// Parser Types
// ============================================================================

/// GraphQL Lexer - tokenizes GraphQL source
pub const Lexer = parser.Lexer;

/// GraphQL Parser - parses GraphQL queries into AST
pub const Parser = parser.Parser;

/// Parsed GraphQL document containing operations
pub const Document = parser.Document;

/// GraphQL operation (query, mutation, subscription)
pub const Operation = parser.Operation;

/// GraphQL field selection
pub const Field = parser.Field;

/// GraphQL argument
pub const Argument = parser.Argument;

/// GraphQL value (string, int, bool, list, object, etc.)
pub const Value = parser.Value;

/// GraphQL executor for running queries
pub const Executor = parser.Executor;

/// Execution context passed to resolvers
pub const ExecutionContext = parser.ExecutionContext;

/// Resolver function type
pub const ResolverFn = parser.ResolverFn;

/// Result from a field resolver
pub const FieldResult = parser.FieldResult;

// ============================================================================
// Pagination Types
// ============================================================================

/// Page information for Relay-style pagination
pub const PageInfo = pagination.PageInfo;

// ============================================================================
// Complexity Analysis Types
// ============================================================================

/// Query complexity limits configuration
pub const ComplexityLimits = complexity.ComplexityLimits;

/// Result of complexity analysis
pub const ComplexityAnalysis = complexity.ComplexityAnalysis;

/// Query complexity analyzer
pub const ComplexityAnalyzer = complexity.ComplexityAnalyzer;

// ============================================================================
// JSON Escaping
// ============================================================================

/// JSON string escape utility
pub const escapeJsonString = fields.escapeJsonString;

// ============================================================================
// Tests
// ============================================================================

test {
    // Run all submodule tests
    std.testing.refAllDecls(@This());
}
