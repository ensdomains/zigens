//! Module root for the "graphql" test import (build.zig's graphql_lib_mod).
//!
//! Sits at src/ (not src/lib/graphql/) so the module's path covers the whole src/
//! tree: metrics.zig reaches src/utils/system.zig via a relative import, which Zig
//! 0.16 rejects when the module is rooted inside lib/graphql/ ("import of file
//! outside module path"). Re-exports the same surface as lib/graphql/graphql.zig.

const graphql = @import("lib/graphql/graphql.zig");

pub const parser = graphql.parser;
pub const pagination = graphql.pagination;
pub const complexity = graphql.complexity;
pub const metrics = graphql.metrics;
pub const fields = graphql.fields;
pub const json_builder = graphql.json_builder;
pub const Lexer = graphql.Lexer;
pub const Parser = graphql.Parser;
pub const Document = graphql.Document;
pub const Operation = graphql.Operation;
pub const Field = graphql.Field;
pub const Argument = graphql.Argument;
pub const Value = graphql.Value;
pub const Executor = graphql.Executor;
pub const ExecutionContext = graphql.ExecutionContext;
pub const ResolverFn = graphql.ResolverFn;
pub const FieldResult = graphql.FieldResult;
pub const PageInfo = graphql.PageInfo;
pub const ComplexityLimits = graphql.ComplexityLimits;
pub const ComplexityAnalysis = graphql.ComplexityAnalysis;
pub const ComplexityAnalyzer = graphql.ComplexityAnalyzer;
pub const FieldType = graphql.FieldType;
pub const FieldValue = graphql.FieldValue;
pub const FieldDef = graphql.FieldDef;
pub const FieldGetter = graphql.FieldGetter;
pub const CustomWriter = graphql.CustomWriter;
pub const escapeJsonString = graphql.escapeJsonString;
pub const handleFieldFromTable = graphql.handleFieldFromTable;
pub const MAX_QUERY_DEPTH = graphql.MAX_QUERY_DEPTH;
pub const NestedContext = graphql.NestedContext;
pub const NestedHandler = graphql.NestedHandler;
pub const NestedFieldDef = graphql.NestedFieldDef;
pub const EntityConfig = graphql.EntityConfig;
pub const buildEntityJson = graphql.buildEntityJson;
pub const buildEntityArrayJson = graphql.buildEntityArrayJson;
