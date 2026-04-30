# ENSv2 Indexer Database Schema

This directory contains SQL schema files for the ENSv2 indexer database.

## Structure

```
schema/
├── 001_initial.sql       - Core tables (names, resolvers, events, etc.)
├── 002_bridge_events.sql - Bridge/cross-chain event tables
└── README.md             - This file
```

## Schema Files

Schema files are numbered sequentially and executed in order:
- `001_*.sql` - Initial schema (always runs first)
- `002_*.sql` - Bridge events migration
- `00X_*.sql` - Future migrations...

## Adding New Migrations

When you need to add new tables or modify the schema:

1. **Create a new migration file**:
   ```bash
   touch schema/003_my_new_feature.sql
   ```

2. **Write the SQL** (use `CREATE TABLE IF NOT EXISTS`):
   ```sql
   -- Migration 003: Description of changes

   CREATE TABLE IF NOT EXISTS my_new_table (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     -- ... columns
   );

   CREATE INDEX IF NOT EXISTS idx_my_table ON my_new_table(column);
   ```

3. **Rebuild and run**:
   ```bash
   zig build
   ./zig-out/bin/ensv2-indexer
   ```

## Schema Design Principles

### 1. Idempotent Migrations
Always use `IF NOT EXISTS` clauses so migrations can run multiple times safely:
```sql
CREATE TABLE IF NOT EXISTS ...
CREATE INDEX IF NOT EXISTS ...
```

### 2. Performance Indexes
Create indexes for:
- Foreign keys
- Frequently filtered columns (protocol, block_number)
- Join columns (namehash, token_id)

### 3. UNIQUE Constraints
Use UNIQUE constraints to prevent duplicates:
```sql
UNIQUE(protocol, transaction_hash, log_index)
```

### 4. Timestamps
Always include timestamp fields for auditing:
```sql
timestamp INTEGER NOT NULL
```

## Relationship to GraphQL Schema

**Important:** SQL and GraphQL schemas serve different purposes:

### SQL Schema (This directory)
- **Storage layer** - How data is stored in SQLite
- Optimized for: Performance, consistency, relationships
- Contains: Tables, indexes, constraints
- Example: `names` table with 20+ columns

### GraphQL Schema (`src/api/graphql.zig`)
- **API layer** - How data is queried by users
- Optimized for: User experience, flexibility
- Contains: Types, queries, mutations
- Example: `Domain` type that joins multiple tables

### Example Mapping

**SQL:**
```sql
-- Multiple tables
names (id, name, owner, resolver, ...)
resolver_addresses (namehash, coin_type, address, ...)
resolver_texts (namehash, key, value, ...)
```

**GraphQL:**
```graphql
type Domain {
  name: String!
  owner: Account!
  resolver: Resolver
  addresses: [CryptoAddress!]!  # Joined from resolver_addresses
  texts: [TextRecord!]!         # Joined from resolver_texts
}
```

## Testing Schemas

You can test SQL schemas directly:

```bash
# Apply schema to test database
sqlite3 test.db < schema/001_initial.sql
sqlite3 test.db < schema/002_bridge_events.sql

# Inspect structure
sqlite3 test.db ".schema names"
sqlite3 test.db ".tables"
```

## Migration Tracking

The indexer automatically:
1. Loads all `*.sql` files from `schema/` directory in order
2. Executes them on startup (idempotent, safe to re-run)
3. No manual migration tracking needed (thanks to `IF NOT EXISTS`)

## Best Practices

### DO:
✅ Use `IF NOT EXISTS` for idempotent migrations
✅ Create indexes for frequently queried columns
✅ Document each migration with comments
✅ Test schema changes with real data
✅ Keep migrations small and focused

### DON'T:
❌ Drop tables in migrations (data loss!)
❌ Remove indexes without analysis
❌ Forget UNIQUE constraints (duplicates!)
❌ Skip documentation
❌ Mix schema changes with data changes

## Future Enhancements

Potential improvements:
- Version tracking table to know which migrations ran
- Rollback scripts (though with `IF NOT EXISTS` they're less critical)
- Schema validation tests
- Auto-generate GraphQL types from SQL schema
