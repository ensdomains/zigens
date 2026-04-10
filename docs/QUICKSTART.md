# ENSv2 Indexer - Quick Start Guide

## Prerequisites Check

Before running the indexer, ensure you have:

```bash
# Check Zig version
zig version
# Should output: 0.13.0 or later

# Check SQLite
sqlite3 --version
# Should output: 3.x.x

# Check system dependencies
which curl  # For HTTP requests
which git   # For version control
```

## Fix Zig Installation (Current Issue)

Your Zig installation has a z3 library dependency issue. Fix it:

```bash
# Option 1: Reinstall Zig
brew uninstall zig
brew install zig

# Option 2: Fix z3 symlink
brew reinstall z3
brew link --overwrite z3

# Option 3: Download official Zig binary
curl -L https://ziglang.org/download/0.13.0/zig-macos-aarch64-0.13.0.tar.xz | tar -xJ
export PATH="$PWD/zig-macos-aarch64-0.13.0:$PATH"
```

## Build & Test

Once Zig is fixed:

```bash
# 1. Build the project
zig build

# 2. Run unit tests
zig build test

# 3. Run integration tests
zig build test-integration

# 4. Build optimized release
zig build -Doptimize=ReleaseFast
```

## Configuration

```bash
# 1. Copy example config
cp config.example.json config.json

# 2. Edit config with your settings
nano config.json
```

**Required changes:**
- `rpc_url`: Your Ethereum RPC
- Contract addresses (will be available after ENSv2 deployment)
- Start blocks (deployment blocks)

## Run Locally

```bash
# Run the indexer
./zig-out/bin/ensv2-indexer

# Or with zig build run
zig build run

# Expected output:
# ENSv2 Indexer starting...
# L1 RPC: https://eth-mainnet.g.alchemy.com/v2/...
# L2 RPC: https://base-mainnet.g.alchemy.com/v2/...
# Database initialized at: ./ensv2.db
# API server starting on port 8080
# Indexer starting...
```

## Verify It's Working

```bash
# In another terminal:

# 1. Check health
curl http://localhost:8080/api/health
# Should return: {"status":"ok","service":"ensv2-indexer"}

# 2. Try GraphQL playground
open http://localhost:8080/graphql

# 3. Query a name (after some indexing)
curl http://localhost:8080/api/name/alice.eth

# 4. Check sync status
sqlite3 ensv2.db "SELECT * FROM sync_state;"
```

## Test with Mock Data

Since ENSv2 isn't deployed yet, you can test with mock data:

```bash
# Connect to database
sqlite3 ensv2.db

# Insert test name
INSERT INTO names (
  namehash, name, label, label_hash, parent_name, parent_namehash,
  chain, registry, owner, resolver, token_id, expiry, registry_locked,
  migrated, ejected, created_block, created_at, updated_block, updated_at
) VALUES (
  '0x1234...', 'test.eth', 'test', '0xabcd...', 'eth', '0x9876...',
  'l2', '0x0000000000000000000000000000000000000001',
  '0x0000000000000000000000000000000000000123',
  '0x0000000000000000000000000000000000000456',
  '12345', 1735689600, 0, 1, 0, 100, 1704067200, 100, 1704067200
);

# Query it
SELECT * FROM names WHERE name = 'test.eth';

# Exit
.quit

# Now query via API
curl http://localhost:8080/api/name/test.eth
```

## GraphQL Examples

```bash
# Query a domain
curl -X POST http://localhost:8080/graphql \
  -H "Content-Type: application/json" \
  -d '{"query": "{ domain(id: \"test.eth\") { id name owner { id } } }"}'

# Query an account
curl -X POST http://localhost:8080/graphql \
  -H "Content-Type: application/json" \
  -d '{"query": "{ account(id: \"0x123...\") { id domains { id name } } }"}'
```

## Docker Deployment

```bash
# Build Docker image
docker build -t ensv2-indexer .

# Run with Docker Compose
docker-compose up -d

# View logs
docker-compose logs -f

# Stop
docker-compose down
```

## Common Issues

### Issue: Zig z3 library error
```bash
dyld: Library not loaded: /opt/homebrew/opt/z3/lib/libz3.4.13.dylib
```

**Fix**: See "Fix Zig Installation" section above.

### Issue: SQLite not found
```bash
ld: library not found for -lsqlite3
```

**Fix**:
```bash
# macOS
brew install sqlite3

# Linux
sudo apt-get install libsqlite3-dev

# Verify
pkg-config --libs sqlite3
```

### Issue: Can't connect to RPC
```bash
RPC error: Failed to connect
```

**Fix**:
- Check RPC URL is correct
- Verify API key is valid
- Test with curl:
  ```bash
  curl -X POST -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    YOUR_RPC_URL
  ```

### Issue: Port already in use
```bash
error: AddressInUse
```

**Fix**:
```bash
# Find process using port 8080
lsof -i :8080

# Kill it
kill -9 <PID>

# Or change port in config.json
```

## Development Workflow

```bash
# 1. Make changes to source code

# 2. Run tests
zig build test

# 3. Build and run
zig build run

# 4. Test API
curl http://localhost:8080/api/health

# 5. Format code
zig fmt src/

# 6. Commit
git add .
git commit -m "Your changes"
```

## Production Deployment

See `DEPLOYMENT.md` for detailed production deployment instructions including:
- Systemd service setup
- Docker deployment
- Reverse proxy configuration
- SSL/TLS setup
- Monitoring and backups

## Next Steps

1. **Fix Zig installation** (current blocker)
2. **Run tests** to verify everything works
3. **Index testnet data** (when ENSv2 testnet is available)
4. **Deploy to production** (when ENSv2 mainnet is live)

## Resources

- **Full Documentation**: `README.md`
- **Deployment Guide**: `DEPLOYMENT.md`
- **Project Summary**: `PROJECT_SUMMARY.md`
- **ENSv2 Spec**: `architecture/ens-v2-design.md`

## Support

Need help?
- Check logs: `journalctl -u ensv2-indexer -f` (systemd) or `docker-compose logs -f`
- Read troubleshooting: `DEPLOYMENT.md#troubleshooting`
- Open an issue: <repository-url>/issues

---

**Ready to start!** Fix the Zig installation and you're good to go. 🚀
