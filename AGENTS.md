# AGENTS.md - ENSv2 Indexer Development Guide

This file provides guidelines for agentic coding agents working on this codebase.

## Project Overview

ENSv2 Indexer is a high-performance Ethereum Name Service indexer written in Zig. It indexes both ENS V1 (legacy) and ENS V2 (new) contract events on Ethereum, provides a GraphQL API, and supports webhooks.

- **Language**: Zig 0.15.1+
- **Database**: SQLite
- **Build System**: Zig build

## Build Commands

> **Newer host glibc note:** if `zig build` fails to *link* with
> `fatal linker error: unhandled relocation type R_X86_64_PC64 ... crt1.o:.sframe`,
> your system glibc/gcc CRT objects are too new for Zig's linker. Pin glibc to
> the host version and re-point the system lib search path, e.g. for glibc 2.43:
> `zig build <step> -Dtarget=native-native-gnu.2.43 --search-prefix /usr`
> (`ldd --version` shows the version; `--search-prefix` lets it still find libsqlite3).

```bash
# Build all binaries
zig build

# Run all tests
zig build test

# Run specific test steps
zig build test-filters
zig build test-events
zig build test-storage
zig build test-graphql
zig build test-graphql-features
zig build test-integration
zig build test-apollo

# Run a single test file
zig test src/storage/names.zig
zig test src/api/filter_test.zig

# Run a specific test within a file
zig test src/storage/names.zig --test-name-pattern "insertName"

# Run the indexer
zig build run-indexer

# Run the API server
zig build run-api
```

### Available Binaries

- `zig-out/bin/ensv2-indexer` - Combined V1+V2 indexer
- `zig-out/bin/ensv2-indexer-v1` - V1-only indexer
- `zig-out/bin/ensv2-indexer-v2` - V2-only indexer
- `zig-out/bin/ensv2-api` - Standalone GraphQL API server
- `zig-out/bin/rainbow-backfill` - Rainbow table label backfill tool

## Code Style Guidelines

### General Principles

- **No comments** - Write self-documenting code instead. Only add comments for complex algorithms.
- **Use `const` by default** - Only use `var` when mutation is required
- **Error handling** - Use `try` for operations that should fail fast, `catch` for recoverable errors
- **Memory** - Always free allocated memory in defer blocks

### Naming Conventions

- **Functions**: `camelCase` (e.g., `getDomainByName`, `insertRegistry`)
- **Types/Structs**: `PascalCase` (e.g., `Address`, `Domain`, `Database`)
- **Constants**: `SCREAMING_SNAKE_CASE` (e.g., `SQL_SELECT_NAMES`, `MAX_DEPTH`)
- **Variables**: `camelCase` (e.g., `allocator`, `query_result`)
- **File names**: `snake_case.zig` (e.g., `names.zig`, `address.zig`)

### Imports

```zig
const std = @import("std");
const testing = std.testing;
const Database = @import("storage/database.zig").Database;
const models = @import("types/models.zig");
const Address = @import("types/address.zig").Address;
```

### Type Annotations

Always annotate function parameters with types and use explicit return types.

```zig
pub fn getName(allocator: std.mem.Allocator, namehash: Hash) !?Name { ... }
```

### Error Handling Patterns

```zig
try someFunction();  // propagate errors
const value = optional_value orelse default_value;  // optionals
const result = maybeFails() catch handleError();  // recoverable
```

### Memory Management

```zig
defer allocator.free(buffer);
defer file.close();

var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
const arena_alloc = arena.allocator();
```

### SQLite Patterns

Use the `Query` abstraction for parameterized queries, check `sql_err` after C calls, and use transactions.

```zig
const stmt = try db.prepare("SELECT * FROM names WHERE namehash = ?");
defer stmt.finalize();
var query = try stmt.query(allocator);
defer query.deinit();
while (try query.next()) |row| { ... }
```

### Testing Patterns

Test files in `tests/` or alongside source as `*_test.zig`. Use helpers from `tests/helpers.zig`.

```zig
test "insertName creates new name" {
    const allocator = testing.allocator;
    const database = try helpers.createTestDatabase(allocator);
    defer helpers.destroyTestDatabase(allocator, database);
    try database.insertName(...);
}
```

### GraphQL API Development

Schema in `schema.graphql`, introspection via `tools/generate_introspection.py`, resolvers in `src/api/resolvers/`, complexity limits in `src/lib/graphql/complexity.zig`.

### Configuration

Environment variables - see `.env.example`: `RPC_URL`, `NETWORK` (sepolia/mainnet), `DATABASE_PATH`, `API_PORT` (default 8080).

### Project Structure

```
src/
├── main.zig              # Entry point
├── indexer_main.zig      # Indexer entry
├── api_main.zig          # API entry
├── config.zig            # Configuration
├── types/                # Data types (address.zig, hash.zig, models.zig)
├── storage/              # Database layer (names.zig, events.zig, resolvers.zig)
├── rpc/                  # RPC client
├── indexer/              # Event indexing
├── api/                  # GraphQL API (server.zig, handler.zig, resolvers/)
└── utils/                # Utilities (ens_normalize.zig, keccak.zig)
tests/
├── storage/              # Storage tests
├── graphql/              # GraphQL tests
├── integration.zig       # Integration tests
└── helpers.zig           # Test utilities
```

### Useful Tools

- `zig fmt` - Format code
- `zig build test --summary all` - Verbose test output
- `sqlite3` - Inspect database directly
- `curl` - Test API endpoints
