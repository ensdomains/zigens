# Running the ENS Indexer

## Production Setup

The indexer uses file redirection for logging, which is the standard approach for production services.

### L1 Indexer Only

```bash
# Create logs directory
mkdir -p logs

# Run L1 indexer in background
./zig-out/bin/ensv2-indexer-l1 > logs/indexer-l1.log 2>&1 &

# Monitor logs in real-time
tail -f logs/indexer-l1.log

# Search logs
grep "error" logs/indexer-l1.log
grep "Progress" logs/indexer-l1.log
```

### L2 Indexer Only

```bash
mkdir -p logs
./zig-out/bin/ensv2-indexer-l2 > logs/indexer-l2.log 2>&1 &
tail -f logs/indexer-l2.log
```

### Combined L1 + L2 Indexer

```bash
mkdir -p logs
./zig-out/bin/ensv2-indexer > logs/indexer.log 2>&1 &
tail -f logs/indexer.log
```

## Log Levels

The indexer is configured with `.info` log level by default, showing:
- ✅ **info**: Progress updates, event summaries, checkpoints
- ✅ **warning**: Missing data, skipped events
- ✅ **error**: Failures, critical issues
- ❌ **debug**: Filtered out (per-event details)

### Enable Debug Logging

To see detailed per-event logs during development:

1. Edit the relevant `*_main.zig` file (e.g., `src/indexer_l1_main.zig`)
2. Change `.info` to `.debug`:
   ```zig
   pub const std_options: std.Options = .{
       .log_level = .debug,  // Show all logs including debug
   };
   ```
3. Rebuild: `zig build`
4. Run with file redirection: `./zig-out/bin/ensv2-indexer-l1 > debug.log 2>&1`

## Why File Redirection?

File redirection is **required** for production because:
- Prevents stdout buffer overflow on high-volume logging
- Standard practice for production services (systemd, Docker, Kubernetes)
- Enables log rotation and persistent logs
- Allows use of log analysis tools (grep, awk, etc.)

## Known Issue: Zig 4KB Buffer Limitation

Zig 0.15.1 has a hardcoded 4KB buffer limit in several stdlib functions (`writer.print()`, JSON serialization). This causes `StdoutStreamTooLong` errors when:

1. **Large log output volume** (fixed by `.info` log level + file redirection)
2. **Large RPC batch requests** (fixed by adaptive chunk sizing)

### Predictive Adaptive Chunk Sizing + Retry Logic

The indexer uses **machine learning with automatic retry** to handle all event densities safely:

- **Learns event density** from each processed chunk using exponential moving average
- **Predicts chunk size** = `500 events / learned_density`
- **Starts at 100 blocks** with initial estimate of 5 events/block
- **Adapts 100-100000 blocks** based on learned patterns (1000x dynamic range!)
- **Auto-retries** with smaller chunks if buffer overflow occurs (sudden density spikes)
- **Target**: ~500 events per chunk for optimal 4KB buffer usage

**Example Learning with Retry**:
```
Chunk 1: predicted_density=1.23 → chunk_size=408 → OVERFLOW!
Retry:   predicted_density=1.23 → chunk_size=204 → SUCCESS (1377 events)
Chunk 2: predicted_density=2.88 → chunk_size=174 → OVERFLOW!
Retry:   predicted_density=2.88 → chunk_size=87  → SUCCESS (4487 events)
Chunk 3: predicted_density=28.37 → chunk_size=100 → SUCCESS (13058 events)
(continues learning and adapting...)
```

**Benefits**:
- Zero extra RPC calls (learns from actual data, no pre-flight requests)
- Predicts BEFORE making requests (proactive, not reactive)
- Handles sudden density spikes (reactive retry with exponential backoff)
- Guaranteed zero crashes (retry logic catches all buffer overflows)
- Handles all densities automatically (from 0.1 to 150+ events/block)
- Gets smarter over time (self-improving algorithm)

## Stopping the Indexer

```bash
# Find the process
ps aux | grep ensv2-indexer

# Stop gracefully
pkill ensv2-indexer

# Or kill specific PID
kill <PID>
```

## Log Rotation

For production, consider using `logrotate`:

```bash
# /etc/logrotate.d/ensv2-indexer
/path/to/logs/indexer*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
```
