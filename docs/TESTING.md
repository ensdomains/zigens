# ENSv2 Indexer - Testing Guide

## Overview

The ENSv2 Indexer now runs as **separate processes** for production reliability:
- **ensv2-indexer-v1**: Indexes V1 (legacy ENS) events
- **ensv2-indexer-v2**: Indexes V2 (new ENS) events
- **ensv2-indexer**: Combined V1+V2 indexer
- **ensv2-api**: Serves GraphQL and REST APIs to query indexed data

**Why separate processes?**
- ✅ Complete isolation - no shared state or connection conflicts
- ✅ Independent scaling and rate limiting
- ✅ Better error handling - one chain failing doesn't affect the other
- ✅ Production-ready architecture used by major indexers

## Quick Start

### 1. Build All Binaries

```bash
zig build
```

This creates:
- `zig-out/bin/ensv2-indexer-v1` - V1 indexer (separate process)
- `zig-out/bin/ensv2-indexer-v2` - V2 indexer (separate process)
- `zig-out/bin/ensv2-indexer` - Combined indexer
- `zig-out/bin/ensv2-api` - The API server

### 2. Configure Environment

Edit `.env` file with your RPC URLs:

```bash
# RPC Configuration (REQUIRED - add your API key)
RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_API_KEY

# Indexing Configuration
NETWORK=sepolia
START_BLOCK=6800000
BATCH_SIZE=10
POLL_INTERVAL=12
RATE_LIMIT_PER_SECOND=10

# Database
DATABASE_PATH=./data/ens.db

# API Server Configuration
API_PORT=8085

# Memory & Performance
MAX_MEMORY_MB=512
CHECKPOINT_INTERVAL=100
```

### 3. Run the Indexers (Recommended: Separate Processes)

**Terminal 1 - V1 Indexer:**
```bash
./zig-out/bin/ensv2-indexer-v1
```

**Terminal 2 - V2 Indexer:**
```bash
./zig-out/bin/ensv2-indexer-v2
```

**Expected Output:**
```
info: ENSv2 Indexer starting...
info: Network: sepolia
info: RPC: [CONFIGURED]
info: Start block: 6800000
info: Batch size: 10
info: Database initialized at: ./data/ens.db
info: Database integrity check passed
info: Indexer started - indexing blocks...
info: Indexing l1 from block 6800001 to 7234567
```

The indexer will:
- ✅ Check database integrity on startup
- ✅ Resume from last synced block (resumability)
- ✅ Detect and handle blockchain reorgs automatically
- ✅ Rate limit RPC requests
- ✅ Create checkpoints every 100 blocks
- ✅ Handle L1 and L2 errors independently

### 4. Run the API Server (Optional)

In a **separate terminal**:

```bash
./zig-out/bin/ensv2-api
```

**Expected Output:**
```
info: ENSv2 API Server starting...
info: Network: sepolia
info: Database: ./data/ens.db
info: Port: 8085
info: Database connected
info: API server listening on port 8085
info: Ready to serve requests
```

## Testing the API

### Health Check

```bash
curl http://localhost:8085/api/health
```

**Response:**
```json
{"status":"ok","service":"ensv2-indexer"}
```

### GraphQL Playground

**Open in your browser:**
```
http://localhost:8085/graphql
```

You'll see an HTML playground with:
- Example queries
- Full GraphQL schema documentation
- Interactive query examples

### GraphQL Queries (POST)

**Query a domain:**
```bash
curl -X POST http://localhost:8085/graphql \
  -H "Content-Type: application/json" \
  -d '{
    "query": "{domain(id:\"vitalik.eth\"){name owner{id} resolver{address} expiryDate isMigrated}}"
  }'
```

**Response:**
```json
{
  "data": {
    "domain": {
      "name": "vitalik.eth",
      "owner": {"id": "0x123..."},
      "resolver": {"address": "0x456..."},
      "expiryDate": 1735689600,
      "isMigrated": false
    }
  }
}
```

**Query an account:**
```bash
curl -X POST http://localhost:8085/graphql \
  -H "Content-Type: application/json" \
  -d '{
    "query": "{account(id:\"0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045\"){id domains{name} registrations{domain{name}}}}"
  }'
```

**Response:**
```json
{
  "data": {
    "account": {
      "id": "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
      "domains": [],
      "registrations": []
    }
  }
}
```

### REST API Endpoints

**Query by name:**
```bash
curl http://localhost:8085/api/name/vitalik.eth
```

**Query by owner:**
```bash
curl http://localhost:8085/api/owner/0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045
```

**Get recent events:**
```bash
curl http://localhost:8085/api/events
```

## GraphQL Schema

### Available Queries

```graphql
type Query {
  domain(id: String!): Domain
  domains(first: Int = 100, skip: Int = 0, where: DomainFilter): [Domain!]!
  account(id: String!): Account
  registrations(first: Int = 100, skip: Int = 0, where: RegistrationFilter): [Registration!]!
  events(first: Int = 100, skip: Int = 0): [Event!]!
}
```

### Domain Type

```graphql
type Domain {
  id: String!
  name: String
  labelName: String
  labelhash: String
  parent: Domain
  subdomains: [Domain!]!
  resolvedAddress: Account
  owner: Account!
  resolver: Resolver
  ttl: Int
  isMigrated: Boolean!
  createdAt: Int!
  registrant: Account
  registrationDate: Int
  expiryDate: Int
}
```

### Example Queries

**Get full domain info:**
```graphql
{
  domain(id: "alice.eth") {
    id
    name
    labelName
    labelhash
    owner { id }
    resolver {
      id
      address
    }
    parent {
      name
    }
    expiryDate
    isMigrated
    createdAt
  }
}
```

**Query multiple domains:**
```graphql
{
  domains(first: 10, where: { owner: "0x123..." }) {
    id
    name
    owner { id }
    expiryDate
  }
}
```

### GraphQL Variables

The API supports GraphQL variables for parameterized queries, making your queries more flexible and secure.

**Basic variable usage:**
```bash
curl -X POST http://localhost:8085/graphql \
  -H 'Content-Type: application/json' \
  -d '{
    "query": "query($limit: Int!) { domains(first: $limit) { name } }",
    "variables": {"limit": 5}
  }'
```

**Multiple variables:**
```bash
curl -X POST http://localhost:8085/graphql \
  -H 'Content-Type: application/json' \
  -d '{
    "query": "query($first: Int!, $pattern: String!) { domains(first: $first, where: {name_contains_nocase: $pattern}) { name } }",
    "variables": {"first": 10, "pattern": "vitalik"}
  }'
```

**Variable syntax:**
- Variable definitions go in parentheses after `query`: `query($varName: Type!)`
- `!` makes a variable required
- Variables are referenced with `$`: `domains(first: $limit)`
- Supported types: `Int`, `String`, `Boolean`, `Float`

**Example with filters:**
```graphql
query($registrant: String!, $minExpiry: Int!) {
  registrations(
    where: {
      registrant: $registrant
      expiryDate_gte: $minExpiry
    }
    first: 20
  ) {
    name
    expiryDate
    registrant { id }
  }
}
```

Variables:
```json
{
  "registrant": "0x1234567890123456789012345678901234567890",
  "minExpiry": 1700000000
}
```

### Query Complexity Limiting

The API enforces query complexity limits to prevent denial-of-service attacks from expensive queries. Complexity is calculated based on:

1. **Query Depth**: Maximum nesting level of fields
2. **Query Cost**: Total cost considering field count and pagination multipliers

**Default Limits:**
- Max Depth: 10 levels
- Max Cost: 1000 points
- Field Cost: 1 point per field
- List Multiplier: Based on `first` or `limit` arguments (capped at 100)

**How Cost is Calculated:**

```
field_cost = base_cost (1) × multiplier (from 'first' arg)
total_cost = field_cost + (nested_fields_cost × multiplier)
```

**Example Costs:**

Simple query (low cost):
```graphql
query {
  domains(first: 2) {
    name
    owner { id }
  }
}
# Cost: 8 points (2 domains × 4 fields)
```

Expensive query (rejected):
```graphql
query {
  domains(first: 100) {
    name
    owner { id }
    subdomains(first: 100) {
      name
      owner { id }
    }
  }
}
# Cost: 40,800 points - REJECTED (exceeds 1000 limit)
```

**Error Response:**

When a query exceeds complexity limits:
```json
{
  "errors": [{
    "message": "Query complexity (40800) exceeds maximum allowed cost"
  }]
}
```

**Monitoring Complexity:**

Query complexity is logged with each request:
```
debug: Query complexity: depth=3, cost=8
```

For queries that exceed limits:
```
warning: Query complexity violation: Query complexity (40800) exceeds maximum allowed cost
```

**Best Practices:**

1. Use reasonable `first` values (10-100 instead of 1000+)
2. Avoid deeply nested queries with pagination at each level
3. Request only the fields you need
4. Split large queries into multiple smaller requests

## Production Deployment

### Using systemd

**Indexer service** (`/etc/systemd/system/ensv2-indexer.service`):
```ini
[Unit]
Description=ENSv2 Indexer
After=network.target

[Service]
Type=simple
User=ens
WorkingDirectory=/opt/ensv2-indexer
ExecStart=/opt/ensv2-indexer/zig-out/bin/ensv2-indexer
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

**API service** (`/etc/systemd/system/ensv2-api.service`):
```ini
[Unit]
Description=ENSv2 API Server
After=network.target ensv2-indexer.service

[Service]
Type=simple
User=ens
WorkingDirectory=/opt/ensv2-indexer
ExecStart=/opt/ensv2-indexer/zig-out/bin/ensv2-api
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

**Enable and start:**
```bash
sudo systemctl enable ensv2-indexer ensv2-api
sudo systemctl start ensv2-indexer ensv2-api
sudo systemctl status ensv2-indexer ensv2-api
```

### Using Docker Compose

```yaml
version: '3.8'

services:
  indexer:
    build: .
    command: /app/zig-out/bin/ensv2-indexer
    volumes:
      - ./data:/app/data
      - ./.env:/app/.env
    restart: unless-stopped

  api:
    build: .
    command: /app/zig-out/bin/ensv2-api
    ports:
      - "8085:8085"
    volumes:
      - ./data:/app/data
      - ./.env:/app/.env
    restart: unless-stopped
    depends_on:
      - indexer
```

## Monitoring

### Check Indexer Progress

```bash
# View logs
tail -f /var/log/ensv2-indexer.log

# Check sync state
sqlite3 ./data/ens.db "SELECT * FROM sync_state;"
```

### Check API Health

```bash
# Health endpoint
curl http://localhost:8085/api/health

# Query indexed names count
sqlite3 ./data/ens.db "SELECT COUNT(*) FROM names;"

# Query recent events
sqlite3 ./data/ens.db "SELECT * FROM events ORDER BY block_number DESC LIMIT 10;"
```

## Troubleshooting

### Indexer Not Starting

**Check RPC URLs:**
```bash
grep RPC_URL .env
```

**Check database permissions:**
```bash
ls -la ./data/ens.db
```

**View detailed logs:**
```bash
./zig-out/bin/ensv2-indexer 2>&1 | tee indexer.log
```

### API Returning "Not Found"

This means no data has been indexed yet. Run the indexer first to populate the database.

### Database Corruption

```bash
# Backup
cp ./data/ens.db ./data/ens.db.backup

# Check integrity
sqlite3 ./data/ens.db "PRAGMA integrity_check;"

# If corrupted, the indexer will detect on startup
./zig-out/bin/ensv2-indexer
```

### Reorg Detected

The indexer automatically handles reorgs:
```
error: REORG DETECTED at block 7123456 on l1!
warn: Rolling back l1 to block 7123450
```

This is **normal** and the indexer will automatically:
1. Detect the reorg by comparing block hashes
2. Find the last valid block
3. Delete invalid data
4. Re-index from the safe block

## Performance Tuning

### Indexer

**Fast sync** (uses more RPC requests):
```bash
BATCH_SIZE=100
RATE_LIMIT_PER_SECOND=50
```

**Conservative sync** (gentler on RPC):
```bash
BATCH_SIZE=10
RATE_LIMIT_PER_SECOND=5
```

### API

**Scale horizontally** - run multiple API instances:
```bash
# Terminal 1
API_PORT=8085 ./zig-out/bin/ensv2-api

# Terminal 2
API_PORT=8086 ./zig-out/bin/ensv2-api

# Terminal 3
API_PORT=8087 ./zig-out/bin/ensv2-api
```

Then use a load balancer (nginx, haproxy) to distribute requests.

## Summary

✅ **Separate processes** - Indexer and API run independently
✅ **GraphQL API** - Full GraphQL support with playground
✅ **REST API** - Simple REST endpoints
✅ **Production ready** - Reorg handling, resumability, error isolation
✅ **Scalable** - Can run multiple API instances
✅ **Observable** - Health checks, logs, database queries

**Next Steps:**
1. Add your RPC URLs to `.env`
2. Start the indexer: `./zig-out/bin/ensv2-indexer`
3. Start the API: `./zig-out/bin/ensv2-api`
4. Open GraphQL playground: http://localhost:8085/graphql
5. Start querying!
