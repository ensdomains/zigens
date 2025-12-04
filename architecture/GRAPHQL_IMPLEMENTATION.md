# GraphQL Implementation Strategy

**Status:** Option A Implemented (2025-01-28)
**Current Implementation:** Schema-first with build-time introspection generation

---

## Overview

This document outlines the GraphQL server implementation strategy for the ENSv2 indexer. We evaluated multiple approaches and chose a pragmatic path forward while documenting future evolution options.

## Current Implementation: Option A (Schema-First)

### Architecture

```
schema.graphql (source of truth)
    ↓
tools/generate_introspection.py (build-time)
    ↓
src/api/introspection.json (generated)
    ↓
@embedFile in src/api/graphql.zig (compile-time)
    ↓
Binary (runtime)
```

### Components

1. **`schema.graphql`** - GraphQL Schema Definition Language
   - Standard GraphQL SDL format
   - Single source of truth for API schema
   - Compatible with GraphQL ecosystem tools
   - ~150 lines with documentation

2. **`tools/generate_introspection.py`** - Build-time Code Generator
   - Parses GraphQL SDL (no external dependencies)
   - Generates introspection JSON for autocomplete
   - Runs automatically during `zig build`
   - Simple regex-based parser (~150 lines)

3. **`src/api/introspection.json`** - Generated Artifact
   - Auto-generated, never manually edited
   - Contains full schema introspection data
   - Embedded in binary at compile-time via `@embedFile`

4. **`src/api/graphql.zig`** - GraphQL Handler
   - Field parser extracts requested fields from queries
   - Manual resolver mapping (explicit field handling)
   - Returns only requested fields (efficient)
   - ~500 lines of Zig code

### Benefits

✅ **Maintainability:** Schema in standard format, easy to update
✅ **Tooling:** Compatible with GraphQL validators, visualizers, IDEs
✅ **No Runtime Cost:** Introspection embedded at compile-time
✅ **Professional UX:** Full autocomplete and documentation in GraphiQL
✅ **Simple:** No complex parsing or code-gen at runtime
✅ **Zero Dependencies:** Pure Zig + Python build script

### Limitations

⚠️ **Manual Resolvers:** Must manually implement field mapping in Zig
⚠️ **No Type Safety:** Schema not connected to Zig types
⚠️ **Repetitive:** Adding fields requires editing both schema and resolver code
⚠️ **Limited SDL Support:** Parser handles basic types only (no unions, interfaces)

### When to Use

**Perfect for:**
- Indexers and subgraphs (read-heavy, simple queries)
- Small to medium schemas (< 50 types)
- Teams comfortable with manual resolver mapping
- Projects prioritizing simplicity and zero dependencies

**Not ideal for:**
- Complex schemas with deep nesting
- Frequent schema changes
- Teams wanting compile-time type safety
- Projects needing GraphQL Federation

---

## Future Options

### Option B: Generic Field Resolution (2-3 hours)

**Goal:** Eliminate manual field mapping through reflection and schema-driven resolution.

#### Architecture

```
schema.graphql
    ↓
Zig SDL Parser (comptime)
    ↓
Generic Field Resolver (runtime)
    ↓
Automatic struct → GraphQL mapping
```

#### Implementation Plan

1. **Zig SDL Parser** (~1 hour)
   ```zig
   // Parse schema.graphql at comptime
   const schema = comptime parseGraphQLSchema(@embedFile("../schema.graphql"));

   // Generate type mappings
   const type_map = comptime buildTypeMap(schema);
   ```

2. **Generic Resolver** (~1 hour)
   ```zig
   // Automatically resolve fields based on struct reflection
   fn resolveField(T: type, obj: T, field_name: []const u8) !Value {
       inline for (@typeInfo(T).Struct.fields) |field| {
           if (std.mem.eql(u8, field.name, field_name)) {
               return Value.from(@field(obj, field.name));
           }
       }
       return error.FieldNotFound;
   }
   ```

3. **Query Execution** (~30 min)
   ```zig
   // Execute query against schema
   fn executeQuery(query: []const u8, root: anytype) ![]u8 {
       const ast = try parseQuery(query);
       var result = try executeSelection(ast.selections, root);
       return serializeJSON(result);
   }
   ```

#### Benefits

✅ Add new fields by only editing schema
✅ Automatic field resolution via reflection
✅ Reduced boilerplate code
✅ Better schema-code alignment

#### Trade-offs

⚠️ More complex implementation (~300 lines)
⚠️ Comptime reflection overhead
⚠️ Less explicit control over field resolution
⚠️ Debugging can be harder

#### Effort: 2-3 hours
#### Complexity: Medium
#### Use When: Schema changes frequently, want to reduce boilerplate

---

### Option C: Full Code Generation (1-2 days)

**Goal:** Production-ready, type-safe GraphQL server with compile-time validation.

#### Architecture

```
schema.graphql
    ↓
codegen/generate_types.zig (build-time)
    ↓
Generated Zig types + interfaces
    ↓
User implements resolvers
    ↓
Compile-time type checking
```

#### Implementation Plan

1. **Type Generator** (~4 hours)
   ```zig
   // Generate Zig types from schema
   // Input: schema.graphql
   // Output: src/api/generated_types.zig

   pub const Domain = struct {
       id: []const u8,
       name: ?[]const u8,
       owner: Account,
       // ... all fields from schema
   };
   ```

2. **Resolver Interface Generator** (~2 hours)
   ```zig
   // Generate resolver interfaces
   pub const Resolvers = struct {
       domain: *const fn(ctx: *Context, id: []const u8) anyerror!?Domain,
       domains: *const fn(ctx: *Context, args: DomainsArgs) anyerror![]Domain,
       // ... all queries from schema
   };

   // User implements:
   pub fn resolveDomain(ctx: *Context, id: []const u8) !?Domain {
       const name = try ctx.db.getNameByNamehash(id);
       return domainFromName(name);
   }
   ```

3. **Execution Engine** (~6 hours)
   ```zig
   // Full GraphQL executor
   - Query parsing and validation
   - Fragment support
   - Directive handling (@skip, @include)
   - Variable substitution
   - Error handling and reporting
   ```

4. **Build Integration** (~2 hours)
   ```zig
   // build.zig
   const codegen = b.addExecutable(.{
       .name = "graphql-codegen",
       .root_source_file = .{ .path = "codegen/main.zig" },
   });

   const run_codegen = b.addRunArtifact(codegen);
   run_codegen.addArg("schema.graphql");
   run_codegen.addArg("src/api/generated_types.zig");

   exe.step.dependOn(&run_codegen.step);
   ```

#### Benefits

✅ **Full Type Safety:** Compile-time checking of resolvers
✅ **IDE Support:** Full autocomplete in Zig code
✅ **GraphQL Spec:** Support for fragments, directives, variables
✅ **Refactoring:** Type errors when schema changes
✅ **Performance:** Optimized code generation
✅ **Reusable:** Can be packaged as a library

#### Features

- ✅ Type-safe resolvers with generated interfaces
- ✅ Fragment support (`...UserFields`)
- ✅ Directive support (`@skip`, `@include`)
- ✅ Variable substitution (`$first: Int`)
- ✅ Input validation
- ✅ Error reporting with line/column numbers
- ✅ Nested field resolution
- ✅ Custom scalar types
- ✅ Enum support

#### Trade-offs

⚠️ **Significant upfront work** (1-2 days)
⚠️ **More complex build** (codegen step)
⚠️ **Learning curve** (understanding generated code)
⚠️ **Overkill for simple schemas**

#### Effort: 1-2 days
#### Complexity: High
#### Use When:
- Large, complex schemas (50+ types)
- Multiple developers
- Frequent schema changes
- Need GraphQL Federation
- Production system requiring type safety

---

## Comparison Matrix

| Feature | Option A (Current) | Option B (Generic) | Option C (Codegen) |
|---------|-------------------|-------------------|-------------------|
| **Implementation Time** | ✅ Done (30 min) | 🟡 2-3 hours | 🔴 1-2 days |
| **Complexity** | ✅ Low | 🟡 Medium | 🔴 High |
| **Type Safety** | ❌ No | 🟡 Runtime | ✅ Compile-time |
| **Boilerplate** | 🔴 High | 🟡 Medium | ✅ Low |
| **Schema Changes** | 🔴 Manual sync | 🟡 Schema only | ✅ Auto-detected |
| **Performance** | ✅ Excellent | ✅ Good | ✅ Excellent |
| **Dependencies** | ✅ Zero (Zig + Python) | ✅ Zero (Pure Zig) | ✅ Zero (Pure Zig) |
| **GraphQL Spec** | 🟡 Basic queries | 🟡 Basic queries | ✅ Full spec |
| **Fragments** | ❌ No | ❌ No | ✅ Yes |
| **Directives** | ❌ No | ❌ No | ✅ Yes |
| **Variables** | ❌ No | ❌ No | ✅ Yes |
| **Maintainability** | 🟡 Medium | ✅ Good | ✅ Excellent |
| **Debugging** | ✅ Easy | 🟡 Medium | 🔴 Complex |

---

## Decision Log

### 2025-01-28: Chose Option A

**Context:** Building ENSv2 indexer with GraphQL API for querying domains.

**Requirements:**
- Professional autocomplete in playground
- Field-based query responses (not over-fetching)
- Schema maintainability
- Fast iteration speed

**Decision:** Implement Option A (Schema-First)

**Rationale:**
1. **Good Enough:** Covers 95% of indexer query patterns
2. **Fast:** Implemented in 30 minutes
3. **Simple:** Easy to understand and maintain
4. **Professional:** Full autocomplete and documentation
5. **Zero Risk:** Proven approach, no complex dependencies

**Future Path:**
- Option B if schema changes become frequent (> 2-3 times/week)
- Option C if scaling to multiple teams or need Federation

---

## Migration Paths

### Option A → Option B

**When:** Schema changes frequently, manual resolvers become tedious

**Steps:**
1. Implement Zig SDL parser (use schema.graphql as-is)
2. Add generic field resolver with reflection
3. Replace manual field mapping gradually
4. Keep schema.graphql unchanged

**Effort:** 2-3 hours
**Risk:** Low (can migrate incrementally)

### Option A → Option C

**When:** Need full GraphQL spec, type safety, or Federation

**Steps:**
1. Implement type codegen from schema.graphql
2. Generate resolver interfaces
3. Implement resolvers against generated interfaces
4. Add full query executor
5. Keep schema.graphql unchanged

**Effort:** 1-2 days
**Risk:** Medium (big refactor, but schema stays same)

### Option B → Option C

**When:** Need compile-time type safety

**Steps:**
1. Add codegen on top of SDL parser
2. Generate types from parsed schema
3. Convert generic resolvers to typed resolvers
4. Add full executor features

**Effort:** 1 day
**Risk:** Low (builds on existing parser)

---

## Recommendations

### Stick with Option A if:
- ✅ Current query patterns work well
- ✅ Schema changes < 2 times/week
- ✅ Team comfortable with manual resolvers
- ✅ < 30 types in schema

### Upgrade to Option B if:
- ❌ Adding fields feels repetitive
- ❌ Schema changes frequently
- ❌ Want less boilerplate
- ✅ Okay with reflection-based resolution

### Upgrade to Option C if:
- ❌ Need fragments, directives, variables
- ❌ Need GraphQL Federation
- ❌ Multiple teams working on schema
- ❌ Production system needing type safety
- ✅ Can invest 1-2 days in infrastructure

---

## Alternative Approaches Considered

### Rust GraphQL Library (async-graphql)

**Why Not Chosen:**
- Adds Rust toolchain dependency
- Requires C ABI wrapper (~300 lines)
- Async handling complexity (Rust async ↔ Zig)
- Binary size increase (~1-2MB)
- Effort: 3-5 days

**When to Reconsider:**
- Need GraphQL subscriptions (WebSocket)
- Team already uses Rust
- Need GraphQL Federation

### Go GraphQL Library (gqlgen)

**Why Not Chosen:**
- Go runtime overhead (2-10MB memory)
- Dynamic linking required
- GC pauses
- CGO performance overhead
- Cross-compilation difficulties

**When to Reconsider:**
- Never. Go runtime doesn't fit Zig philosophy.

### Node.js Sidecar (Apollo Server)

**Why Not Chosen:**
- Two processes to deploy
- Network hop overhead
- Node.js runtime dependency
- More complex monitoring

**When to Reconsider:**
- Need Apollo Studio integration
- Team strongly prefers JavaScript
- Need extensive plugin ecosystem

---

## Related Documentation

- [schema.graphql](../schema.graphql) - GraphQL schema definition
- [src/api/graphql.zig](../src/api/graphql.zig) - Current implementation
- [tools/generate_introspection.py](../tools/generate_introspection.py) - Build-time generator

---

## Questions?

**Q: Can we use GraphQL fragments with Option A?**
A: No, but most indexer queries don't need them. Upgrade to Option C if needed.

**Q: What about GraphQL subscriptions (real-time)?**
A: Not supported in any option. Would need WebSocket support + event streaming. Consider Rust async-graphql for this.

**Q: Can we change schema without rebuilding?**
A: No, introspection is embedded at compile-time. This is intentional for zero runtime cost.

**Q: How do we add a new field?**
A:
1. Add field to `schema.graphql`
2. Run `zig build` (auto-regenerates introspection)
3. Add field handling in `buildArrayResponse()`

**Q: What's the performance overhead of reflection in Option B?**
A: Minimal. Zig's comptime reflection is zero-cost at runtime.

**Q: Can we package Option C as a reusable library?**
A: Yes! That would be a valuable contribution to the Zig ecosystem.

---

**Last Updated:** 2025-01-28
**Author:** Claude + User
**Status:** Living Document
