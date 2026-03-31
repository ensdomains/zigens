# Storage Layer Organization

This directory contains the database layer for the ENSv2 indexer.

## Current Structure

```
src/storage/
├── database.zig          - Main database struct with all operations (2050 lines, 45 functions)
└── README.md             - This file
```

## Function Categories

The `database.zig` file contains 45 functions organized into categories:

### Core Operations (5 functions)
- `init()`, `deinit()` - Database lifecycle
- `exec()`, `loadSchemaFiles()`, `migrate()` - Schema management

### Name Operations (12 functions)
- `insertRegistry()`, `insertName()` - Create
- `getNameByNamehash()`, `getNameByTokenId()` - Read
- `updateNameExpiry()`, `updateNameOwner()`, `updateNameResolver()` - Update
- `deleteNameByNamehash()`, `updateNameTokenIdByNamehash()` - Delete/Update by namehash
- `getNamesByOwner()`, `getAllNames()` - Query

### Resolver Operations (8 functions)
- `storeResolverAddress()`, `storeResolverContentHash()`, `storeResolverText()` - Store
- `getResolverAddress()`, `getResolverContentHash()`, `getResolverText()` - Read
- `getResolverTextKeys()`, `getResolversToIndex()` - Query

### Sync/Migration Operations (13 functions)
- `getSyncState()`, `setSyncState()` - Sync state
- `storeBlockHash()`, `getBlockHash()`, `rollbackToBlock()`, `pruneOldBlockHashes()` - Block tracking
- `registerSubregistry()`, `registerResolver()` - Cache management
- `getSubregistriesToIndex()`, `getResolversToIndex()` - Index queries
- `insertMigration()`, `insertRenewalSync()`, `insertTokenObserver()` - Bridge events
- `deleteDataAfterBlock()` - Cleanup
- `checkIntegrity()` - Validation

### Event Operations (3 functions)
- `insertEvent()`, `getRecentEvents()` - Events
- `insertApproval()` - Approvals

### Webhook Operations (3 functions)
- `insertWebhook()`, `deleteWebhook()`, `getWebhooks()` - Webhooks

### Transaction Operations (3 functions)
- `beginTransaction()`, `commitTransaction()`, `rollbackTransaction()` - Transactions

## Design Considerations

### Why One File?

**Advantages:**
- ✅ All database operations in one place
- ✅ Easy to search (`grep "pub fn"`)
- ✅ No circular dependencies
- ✅ Single source of truth for DB access
- ✅ Consistent error handling patterns

**Disadvantages:**
- ❌ 2050 lines is long for navigation
- ❌ Many responsibilities in one struct

### Future Refactoring Options

If the file becomes unmanageable, here are safe refactoring strategies:

#### Option 1: Section Comments (DONE ✅)
Add clear section markers for easy navigation:
```zig
// ============================================================================
// NAME OPERATIONS
// ============================================================================
pub fn insertName(...) { }
```

#### Option 2: Separate Module Files (Future)
Split into modules while keeping API identical:
```
src/storage/
├── database.zig       - Core struct + re-exports
├── db_names.zig       - Name operations
├── db_resolvers.zig   - Resolver operations
├── db_sync.zig        - Sync operations
etc.
```

Use re-exports to maintain API:
```zig
// db_names.zig
pub fn insertName(db: *Database, name: models.Name) !void { }

// database.zig
pub const Database = struct {
    pub const insertName = @import("db_names.zig").insertName;
};

// Usage (UNCHANGED):
db.insertName(...);  // Still works!
```

#### Option 3: Trait-based Design (Future)
Use Zig interfaces for swappable implementations:
```zig
pub const NameRepository = struct {
    ptr: *anyopaque,
    insertFn: *const fn(*anyopaque, models.Name) !void,
    // ...
};
```

## Current Decision: Keep Single File

**Rationale:**
- 45 lines per function is reasonable
- File length (2050) is manageable with good editor navigation
- No circular dependency issues
- Premature splitting could introduce bugs
- Clear section comments provide 90% of benefits with 0% risk

## Navigation Tips

### In VS Code/Zed:
- `Cmd+P` → type function name → jump directly
- `Cmd+Shift+O` → see outline of all functions
- Fold sections with section comments

### Command Line:
```bash
# Find all functions
grep "pub fn" database.zig

# Find name operations
grep "pub fn.*Name" database.zig

# Jump to function
vim +/insertName database.zig
```

## Testing Strategy

The storage layer should have unit tests for each operation category:
```bash
# Future test organization
src/storage/
├── database.zig
├── database_test.zig        - Integration tests
├── names_test.zig           - Name operation tests
├── resolvers_test.zig       - Resolver operation tests
└── sync_test.zig            - Sync operation tests
```

## Performance Notes

- All queries use prepared statements
- Indexes defined in schema files (`schema/*.sql`)
- Transactions used for batch operations
- Cache tables (`known_subregistries`, `known_resolvers`) for performance
