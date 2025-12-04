# Indexer Refactoring & Performance Optimization Plan

## Executive Summary
This document outlines a comprehensive refactoring plan to improve code quality, reduce duplication, and enhance performance through parallelization and batching.

## Current State Analysis

### Code Duplication Issues
1. **29 repetitive event query patterns** - Nearly identical blocks for fetching events
2. **9+ chain-specific conditionals** - `if (chain == .l1) X else Y` repeated throughout
3. **Hardcoded contract addresses** - No centralized contract resolution
4. **Similar event handlers** - Repetitive structure across 20+ handler functions

### Performance Issues
1. **Sequential event fetching** - Events fetched one-by-one despite being independent
2. **No RPC batching** - Individual RPC calls instead of batch requests
3. **Sequential chain indexing** - L1 and L2 indexed sequentially, not in parallel

## Refactoring Plan

### Phase 1: Code Organization & Abstractions (Non-Breaking Changes)

#### 1.1: Chain-Specific Contract Helper Methods
**Goal:** Eliminate repetitive `if (chain == .l1) X else Y` patterns

**Implementation:**
```zig
// Add to Indexer struct
inline fn getEthRegistry(self: *Indexer, chain: models.Chain) Address {
    return if (chain == .l1) self.config.contracts.eth_registry
           else self.config.contracts.l2_eth_registry;
}

inline fn getDatastore(self: *Indexer, chain: models.Chain) Address {
    return if (chain == .l1) self.config.contracts.l1_datastore
           else self.config.contracts.l2_datastore;
}

inline fn getBridgeController(self: *Indexer, chain: models.Chain) Address {
    return if (chain == .l1) self.config.contracts.l1_bridge_controller
           else self.config.contracts.l2_ejection_controller;
}

inline fn getClient(self: *Indexer, chain: models.Chain) *rpc.Client {
    return if (chain == .l1) self.l1_client else self.l2_client;
}
```

**Benefits:**
- Single source of truth for contract addresses
- Easier to update/maintain
- More readable code
- ~50 lines of code saved

---

#### 1.2: Generic Event Indexing Function
**Goal:** Abstract the repetitive event fetching pattern

**Current Pattern (repeated 29 times):**
```zig
const topics = [_]?Hash{abi.EventSignatures.some_event_hash};
const logs = try client.getLogs(from_block, to_block, contract, &topics);
defer {
    for (logs) |*log| {
        log.deinit(self.allocator);
    }
    self.allocator.free(logs);
}

for (logs) |log| {
    try self.handleSomeEvent(chain, log);
}
```

**New Abstraction:**
```zig
const EventIndexConfig = struct {
    event_hash: Hash,
    contract: Address,
    handler: *const fn(*Indexer, models.Chain, rpc.Log) anyerror!void,
    name: []const u8, // For logging
};

fn indexEvent(
    self: *Indexer,
    chain: models.Chain,
    client: *rpc.Client,
    from_block: u64,
    to_block: u64,
    config: EventIndexConfig,
) !void {
    const topics = [_]?Hash{config.event_hash};
    const logs = try client.getLogs(from_block, to_block, config.contract, &topics);
    defer {
        for (logs) |*log| {
            log.deinit(self.allocator);
        }
        self.allocator.free(logs);
    }

    std.log.info("    Found {d} {s} event{s}", .{
        logs.len,
        config.name,
        if (logs.len == 1) "" else "s",
    });

    for (logs) |log| {
        try config.handler(self, chain, log);
    }
}
```

**Usage:**
```zig
// Before: ~15 lines per event type
// After: 1 line per event type
try self.indexEvent(chain, client, from_block, to_block, .{
    .event_hash = abi.EventSignatures.name_registered_hash,
    .contract = self.getEthRegistry(chain),
    .handler = handleNameRegistered,
    .name = "NameRegistered",
});
```

**Benefits:**
- ~400+ lines of code saved
- Consistent logging format
- Easier to add new event types
- Single place to modify event indexing logic

---

#### 1.3: Event Configuration Table
**Goal:** Replace hardcoded event handling with data-driven approach

**Implementation:**
```zig
const EventConfig = struct {
    event_hash: Hash,
    handler: *const fn(*Indexer, models.Chain, rpc.Log) anyerror!void,
    name: []const u8,
    get_contract: *const fn(*Indexer, models.Chain) Address,
};

// Compile-time event registry
const ETH_REGISTRY_EVENTS = [_]EventConfig{
    .{ .event_hash = abi.EventSignatures.name_registered_hash, .handler = handleNameRegistered, .name = "NameRegistered", .get_contract = getEthRegistry },
    .{ .event_hash = abi.EventSignatures.name_renewed_hash, .handler = handleNameRenewed, .name = "NameRenewed", .get_contract = getEthRegistry },
    .{ .event_hash = abi.EventSignatures.name_burned_hash, .handler = handleNameBurned, .name = "NameBurned", .get_contract = getEthRegistry },
    // ... etc
};

fn indexEthRegistryEvents(...) !void {
    inline for (ETH_REGISTRY_EVENTS) |event_config| {
        const contract = event_config.get_contract(self, chain);
        try self.indexEvent(chain, client, from_block, to_block, .{
            .event_hash = event_config.event_hash,
            .contract = contract,
            .handler = event_config.handler,
            .name = event_config.name,
        });
    }
}
```

**Benefits:**
- Self-documenting event configuration
- Easy to add/remove events
- Compile-time safety
- ~200 lines saved

---

### Phase 2: Performance Optimization

#### 2.1: Parallel Event Fetching
**Goal:** Fetch independent events concurrently

**Current:** Sequential
```zig
indexEthRegistryEvents()  // Waits
indexETHRegistrarEvents() // Waits
indexDatastoreEvents()    // Waits
```

**New:** Parallel
```zig
const Thread = std.Thread;

// Fetch all independent events in parallel
var threads = std.ArrayList(Thread).init(allocator);
defer threads.deinit();

try threads.append(try Thread.spawn(.{}, indexEthRegistryEventsAsync, .{...}));
try threads.append(try Thread.spawn(.{}, indexETHRegistrarEventsAsync, .{...}));
try threads.append(try Thread.spawn(.{}, indexDatastoreEventsAsync, .{...}));

// Wait for all to complete
for (threads.items) |thread| {
    thread.join();
}

// Then process dependent events
indexSubregistryEvents(); // Depends on DatastoreEvents completing
```

**Constraints:**
- Must respect event dependency order (documented in code)
- Thread-safe database access required
- Error propagation from threads

**Expected Improvement:** 2-3x faster for block ranges with many events

---

#### 2.2: RPC Request Batching
**Goal:** Batch multiple getLogs calls into single JSON-RPC request

**Current:** Individual requests
```
RPC Call 1: getLogs(NameRegistered)
RPC Call 2: getLogs(NameRenewed)
RPC Call 3: getLogs(NameBurned)
Total: 3 network round trips
```

**New:** Batched requests
```
RPC Batch Call: [
    getLogs(NameRegistered),
    getLogs(NameRenewed),
    getLogs(NameBurned),
]
Total: 1 network round trip
```

**Implementation:**
- Add batch request support to rpc.Client
- Modify indexEvent to support batching
- Process responses in parallel

**Expected Improvement:** 5-10x faster for block ranges (reduced network latency)

---

#### 2.3: Parallel Chain Indexing
**Goal:** Index L1 and L2 simultaneously

**Current:**
```zig
indexChain(.l1, l1_client);  // Waits
indexChain(.l2, l2_client);  // Waits
```

**New:**
```zig
const l1_thread = try Thread.spawn(.{}, indexChain, .{.l1, l1_client});
const l2_thread = try Thread.spawn(.{}, indexChain, .{.l2, l2_client});

l1_thread.join();
l2_thread.join();
```

**Constraints:**
- Database must handle concurrent writes safely (SQLite already does)
- Error handling from both threads

**Expected Improvement:** 2x faster overall indexing

---

## Implementation Strategy

### Step 1: Add Helper Methods (Low Risk)
1. Add chain-specific contract getters
2. Replace all instances
3. Test thoroughly
4. **Commit**

### Step 2: Add Event Indexing Abstraction (Medium Risk)
1. Create indexEvent helper function
2. Refactor one event type as proof-of-concept
3. Test thoroughly
4. Refactor remaining event types
5. **Commit**

### Step 3: Add Event Configuration Tables (Medium Risk)
1. Create event config structs
2. Refactor one function (e.g., indexEthRegistryEvents)
3. Test thoroughly
4. Refactor remaining functions
5. **Commit**

### Step 4: Add Parallel Event Fetching (High Risk)
1. Add thread pool support
2. Identify independent event groups
3. Implement parallel fetching for one group
4. Test thoroughly (look for race conditions)
5. Roll out to remaining groups
6. **Commit**

### Step 5: Add RPC Batching (High Risk)
1. Implement batch request in rpc.Client
2. Test batch requests thoroughly
3. Modify event indexing to use batches
4. **Commit**

### Step 6: Add Parallel Chain Indexing (Medium Risk)
1. Add thread support to main loop
2. Test error handling
3. **Commit**

---

## Testing Strategy

### After Each Step:
1. **Build test:** `zig build`
2. **Unit tests:** Run existing tests
3. **Integration test:** Re-index a known block range
4. **Verify data:** Compare with previous database state
5. **Performance test:** Measure indexing speed

### Rollback Plan:
- Each step is committed separately
- Easy to revert if issues found
- Can cherry-pick successful changes

---

## Expected Outcomes

### Code Quality:
- **50%+ reduction** in code duplication
- **More maintainable** - changes in one place
- **Self-documenting** - event configs are declarative
- **Type-safe** - compile-time checking

### Performance:
- **2-3x faster** event fetching (parallelization)
- **5-10x faster** RPC calls (batching)
- **2x faster** overall (parallel chains)
- **Combined: 10-20x faster** indexing in ideal cases

### Developer Experience:
- **Easier to add new events** - just add to config table
- **Easier to debug** - less code to trace through
- **Easier to test** - smaller, focused functions
- **Better logs** - consistent formatting

---

## Risk Assessment

### Low Risk:
- Helper methods (easy to test, easy to revert)
- Event abstraction (doesn't change logic)

### Medium Risk:
- Event config tables (more complex refactor)
- Parallel chain indexing (concurrency)

### High Risk:
- Parallel event fetching (race conditions possible)
- RPC batching (new network code)

### Mitigation:
- Incremental implementation
- Thorough testing at each step
- Git commits after each working step
- Can disable parallelization via config if issues arise

---

## Timeline Estimate

- **Phase 1.1:** 1-2 hours (Helper methods)
- **Phase 1.2:** 2-3 hours (Event abstraction)
- **Phase 1.3:** 2-3 hours (Event config tables)
- **Phase 2.1:** 4-6 hours (Parallel events)
- **Phase 2.2:** 6-8 hours (RPC batching)
- **Phase 2.3:** 2-3 hours (Parallel chains)

**Total: 17-25 hours** of focused development + testing

---

## Next Steps

1. Review and approve this plan
2. Start with Phase 1.1 (lowest risk, immediate benefit)
3. Proceed incrementally, testing at each step
4. Adjust plan based on learnings

