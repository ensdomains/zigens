//! Generic GraphQL Library for Zig
//!
//! A complete GraphQL implementation including:
//! - Lexer and Parser for GraphQL queries
//! - Query executor with resolver pattern
//! - Relay-spec cursor pagination
//! - Query complexity analysis for DoS protection
//! - Generic DataLoader for batching
//! - Table-driven field definitions
//! - JSON response building
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
//! // Use DataLoader for batching
//! const loader = try graphql.DataLoader(Key, Value).init(allocator, batchFn);
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
pub const dataloader = @import("dataloader.zig");
pub const fields = @import("fields.zig");
pub const json_builder = @import("json_builder.zig");

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

/// Result with cursor pagination support
pub const PaginatedResult = pagination.PaginatedResult;

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
// Metrics Types
// ============================================================================

/// Query metrics collector
pub const QueryMetrics = metrics.QueryMetrics;

/// Query metrics summary
pub const QueryMetricsSummary = metrics.QueryMetricsSummary;

// ============================================================================
// DataLoader Types
// ============================================================================

/// Generic DataLoader for batching and caching
pub const DataLoader = dataloader.DataLoader;

/// Cache statistics
pub const CacheStats = dataloader.CacheStats;

// ============================================================================
// Field Definition Types
// ============================================================================

/// Field value types
pub const FieldType = fields.FieldType;

/// Field value union
pub const FieldValue = fields.FieldValue;

/// Field definition for table-driven field handling
pub const FieldDef = fields.FieldDef;

/// Field getter function type
pub const FieldGetter = fields.FieldGetter;

/// Custom writer function type
pub const CustomWriter = fields.CustomWriter;

/// JSON string escape utility
pub const escapeJsonString = fields.escapeJsonString;

/// Handle a field from a field definition table
pub const handleFieldFromTable = fields.handleFieldFromTable;

// ============================================================================
// JSON Builder Types
// ============================================================================

/// Maximum query depth constant
pub const MAX_QUERY_DEPTH = json_builder.MAX_QUERY_DEPTH;

/// Context for nested field resolution
pub const NestedContext = json_builder.NestedContext;

/// Nested field handler function type
pub const NestedHandler = json_builder.NestedHandler;

/// Nested field definition
pub const NestedFieldDef = json_builder.NestedFieldDef;

/// Entity configuration for JSON building
pub const EntityConfig = json_builder.EntityConfig;

/// Build JSON for an entity
pub const buildEntityJson = json_builder.buildEntityJson;

/// Build JSON array for a list of entities
pub const buildEntityArrayJson = json_builder.buildEntityArrayJson;

// ============================================================================
// Tests
// ============================================================================

test {
    // Run all submodule tests
    std.testing.refAllDecls(@This());
}
