//! Module root for the "graphql" test import (build.zig's graphql_lib_mod).
//!
//! Sits at src/ (not src/lib/graphql/) so the module's path covers the whole src/
//! tree: metrics.zig reaches src/utils/system.zig via a relative import, which Zig
//! 0.16 rejects when the module is rooted inside lib/graphql/ ("import of file
//! outside module path"). Exposes the namespaces the test roots actually use.

const graphql = @import("lib/graphql/graphql.zig");

pub const parser = graphql.parser;
pub const pagination = graphql.pagination;
pub const complexity = graphql.complexity;
