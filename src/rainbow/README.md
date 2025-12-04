# ENS Rainbow Table

Standalone, high-performance labelhash-to-label reverse lookup for Ethereum Name Service (ENS).

## Overview

ENS stores names as keccak256 hashes on-chain, making reverse lookup (hash → name) impossible without a precomputed rainbow table. This module provides:

- **Coverage**: 133M+ labels (90%+ of all ENS names)
- **Performance**: <1ms lookups with caching
- **Storage**: 2.5-3GB optimized SQLite database
- **License**: MIT (using The Graph Protocol's MIT-licensed data)

## Features

- ✅ Binary labelhash storage (32 bytes vs 66 bytes)
- ✅ WITHOUT ROWID optimization
- ✅ Memory-mapped I/O
- ✅ Read-only, thread-safe access
- ✅ Prepared statement reuse
- ✅ Simple, clean API

## Quick Start

### 1. Build the Rainbow Database

```bash
# One-time setup (10-20 minutes, downloads ~6GB)
./scripts/build_rainbow.sh
```

This creates `./data/ens_rainbow.db` (~2.5-3GB)

### 2. Use in Your Code

```zig
const Rainbow = @import("rainbow/rainbow.zig").Rainbow;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load rainbow table
    var rainbow = try Rainbow.init(allocator, "./data/ens_rainbow.db");
    defer rainbow.deinit();

    // Lookup by binary labelhash
    const labelhash = [32]u8{ /* ... */ };
    if (try rainbow.lookup(labelhash)) |label| {
        defer allocator.free(label);
        std.debug.print("Label: {s}\n", .{label});
    }

    // Or lookup by hex string
    const label_hex = "0x123abc...";
    if (try rainbow.lookupHex(label_hex)) |label| {
        defer allocator.free(label);
        std.debug.print("Label: {s}\n", .{label});
    }

    // Get statistics
    const stats = try rainbow.getDbStats();
    std.debug.print("Total labels: {}\n", .{stats.total_labels});
    std.debug.print("Hit rate: {d:.1}%\n", .{
        @as(f64, @floatFromInt(stats.hits)) / @as(f64, @floatFromInt(stats.lookups)) * 100.0
    });
}
```

## API Reference

### `Rainbow.init(allocator, db_path) !Rainbow`

Initialize rainbow table from database file.

**Parameters:**
- `allocator`: Memory allocator
- `db_path`: Path to SQLite database (e.g., "./data/ens_rainbow.db")

**Returns:** `Rainbow` instance or error if database doesn't exist

**Example:**
```zig
var rainbow = try Rainbow.init(allocator, "./data/ens_rainbow.db");
```

### `Rainbow.deinit()`

Clean up resources and close database.

**Example:**
```zig
defer rainbow.deinit();
```

### `Rainbow.lookup(labelhash) !?[]u8`

Lookup label by 32-byte binary labelhash.

**Parameters:**
- `labelhash`: 32-byte array (keccak256 hash)

**Returns:**
- Owned string slice (caller must free) if found
- `null` if not found

**Example:**
```zig
const labelhash = [32]u8{ /* ... */ };
if (try rainbow.lookup(labelhash)) |label| {
    defer allocator.free(label);
    std.debug.print("Found: {s}\n", .{label});
}
```

### `Rainbow.lookupHex(labelhash_hex) !?[]u8`

Lookup label by hex string (convenience wrapper).

**Parameters:**
- `labelhash_hex`: Hex string with optional "0x" prefix

**Returns:** Same as `lookup()`

**Example:**
```zig
if (try rainbow.lookupHex("0x123abc...")) |label| {
    defer allocator.free(label);
    std.debug.print("Found: {s}\n", .{label});
}
```

### `Rainbow.getDbStats() !DbStats`

Get database and runtime statistics.

**Returns:** `DbStats` struct:
- `total_labels`: Total labels in database
- `lookups`: Number of lookups performed
- `hits`: Number of successful lookups
- `misses`: Number of failed lookups

**Example:**
```zig
const stats = try rainbow.getDbStats();
std.debug.print("Coverage: {}/{} ({d:.1}%)\n", .{
    stats.hits,
    stats.lookups,
    @as(f64, @floatFromInt(stats.hits)) / @as(f64, @floatFromInt(stats.lookups)) * 100.0
});
```

### `computeLabelhash(label) [32]u8`

Compute labelhash from label text (utility function).

**Parameters:**
- `label`: UTF-8 label text

**Returns:** 32-byte keccak256 hash

**Example:**
```zig
const labelhash = computeLabelhash("vitalik");
```

## Database Schema

```sql
CREATE TABLE rainbow_labels (
    labelhash BLOB PRIMARY KEY,    -- 32-byte keccak256 hash
    label TEXT NOT NULL             -- UTF-8 label text
) WITHOUT ROWID;

CREATE TABLE rainbow_metadata (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
```

## Performance

### Storage Efficiency

| Format | Size | Savings |
|--------|------|---------|
| Original (The Graph) | 6.0 GB | baseline |
| Our optimized | 2.5-3 GB | 50-58% |

### Lookup Speed

| Scenario | Time | Notes |
|----------|------|-------|
| Cold (first lookup) | ~1ms | Disk read + B-tree |
| Warm (cached pages) | ~0.3ms | Memory read |
| Memory-mapped | ~0.1ms | mmap optimization |

### Memory Usage

| Component | Size |
|-----------|------|
| SQLite pages | ~50-100 MB |
| mmap (optional) | ~1 GB |
| Total process | ~100-200 MB |

## Data Source

- **Provider**: The Graph Protocol
- **License**: MIT
- **Coverage**: 133M+ labels
- **Data**: `gs://ens-files/preimages/`
- **Format**: Tab-separated `labelhash\tlabel`

## Building from Source

### Prerequisites

- Zig 0.15.1+
- Python 3.x
- SQLite 3.x
- Google Cloud SDK (`gsutil`)

### Build Steps

```bash
# 1. Install Google Cloud SDK
brew install google-cloud-sdk

# 2. Download and build rainbow database
./scripts/build_rainbow.sh

# 3. Run tests
zig build test

# 4. Use in your project
# (see examples above)
```

## Integration with ENS Indexer

The rainbow table is automatically detected and used by the indexer if present:

```bash
# Build rainbow table first
./scripts/build_rainbow.sh

# Run indexer (will auto-detect rainbow table)
./zig-out/bin/ensv2-indexer-l1 --from-block 9456489 --to-block 9457489
```

Expected output:
```
info: Rainbow table loaded from ./data/ens_rainbow.db
info: Running unknown labels backfill...
info: ✅ Resolved via rainbow: vitalik
info: ✅ Resolved via rainbow: alice
info: Resolved 18/20 labels (90% coverage)
```

## Troubleshooting

### Rainbow table not found

```
Error: RainbowNotAvailable
```

**Solution**: Build the rainbow database first:
```bash
./scripts/build_rainbow.sh
```

### Download fails

```
Error: gsutil: command not found
```

**Solution**: Install Google Cloud SDK:
```bash
brew install google-cloud-sdk
```

### Database locked

```
Error: database is locked
```

**Solution**: Close other connections to the database. Rainbow table opens in read-only mode and should be thread-safe.

## Maintenance

### Updating the Rainbow Table

The Graph periodically updates their dataset. To refresh:

```bash
# Delete old data
rm -rf ./rainbow_data
rm ./data/ens_rainbow.db

# Rebuild
./scripts/build_rainbow.sh
```

### Incremental Updates

To add new labels from your own indexing:

```sql
INSERT OR IGNORE INTO rainbow_labels (labelhash, label)
VALUES (?, ?);
```

## License

MIT License - See LICENSE file

## Credits

- **Data**: The Graph Protocol (MIT licensed)
- **Implementation**: ENS Indexer Project
- **ENS Protocol**: ENS DAO

## Related Projects

- [The Graph's ens-rainbow](https://github.com/graphprotocol/ens-rainbow)
- [ENS Contracts](https://github.com/ensdomains/ens-contracts)
- [ENS Metadata Service](https://github.com/ensdomains/ens-metadata-service)
