# ENSv2 Indexer

A high-performance indexer for Ethereum Name Service v2 (ENSv2) written in Zig.

## Features

### Core Indexing
- **Multi-chain Support**: Indexes both L1 (Ethereum) and L2 ENSv2 deployments
- **Hierarchical Registry Tracking**: Follows the ENSv2 hierarchical registry model
- **Dynamic Contract Discovery**: Uses ENSv2's on-chain registry events to automatically discover and index new subregistries and resolvers.
- **Event Indexing**: Tracks all ENSv2 events:
  - `NameRegistered` - New .eth registrations
  - `NewSubname` - Subname creation
  - `NameRenewed` - Name renewals
  - `NameBurned` - Name burns
  - `SubregistryUpdate` - Subregistry address changes
  - `ResolverUpdate` - Resolver address changes
  - `Transfer` - Name ownership transfers (ERC1155)
  - `EACRolesChanged` - Extended access control role changes
  - Migration events (ENSv1 → ENSv2)
  - Ejection events (L2 ↔ L1)
- **Resolver Data Indexing**: Tracks resolver record changes:
  - `AddressChanged` - ETH and multi-coin addresses
  - `TextChanged` - Text records (avatar, url, etc.)
  - `ContentHashChanged` - Content hashes
  - `ABIChanged`, `PubkeyChanged`, `NameChanged`, `InterfaceChanged`

### GraphQL API
- **Full GraphQL Support**: Query indexed data via GraphQL
- **Relay-style Pagination**: Cursor-based pagination for large datasets
- **Rich Filtering**: Filter by owner, name, registrant, etc.
- **Nested Queries**: Fetch domains with resolvers, subdomains, events in single query
- **Query Complexity Limits**: Built-in DoS protection

### Webhook System
- **Event Notifications**: Real-time webhooks for ENS events
- **Configurable**: Subscribe to specific event types
- **Retry Logic**: Exponential backoff with configurable retries
- **Reliable Delivery**: Queue-based delivery system

### Storage
- **SQLite Database**: Efficient local storage
- **Optimized Indexes**: Fast queries by name, owner, expiry, etc.
- **Sync State Tracking**: Resumes from last synced block

### Performance
- **Optimized RPC Queries**: Multi-address batching with OR-topic matching
  - 99% reduction in RPC calls vs naive polling
  - Scales to thousands of resolvers/subregistries
- **ENS Name Normalization**: Fast ENSIP-15 normalization with caching

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Entry Points                          │
├─────────────┬─────────────┬─────────────┬───────────────┤
│ ensv2-api   │ensv2-indexer│ensv2-indexer│rainbow-backfill│
│ (GraphQL)   │   (L1+L2)   │  -l1 / -l2  │ (label hash)  │
└──────┬──────┴──────┬──────┴──────┬──────┴───────────────┘
       │             │             │
       ▼             ▼             ▼
┌─────────────────────────────────────────────────────────┐
│                   Shared Components                      │
├─────────────────────────────────────────────────────────┤
│  Storage Layer    │  RPC Client     │  Config/Env       │
│  ├─ names.zig     │  ├─ Batch calls │  └─ .env files    │
│  ├─ events.zig    │  ├─ Multi-addr  │                   │
│  ├─ resolvers.zig │  └─ OR-topics   │                   │
│  ├─ roles.zig     │                 │                   │
│  └─ webhooks.zig  │                 │                   │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
                   ┌─────────────┐
                   │   SQLite    │
                   │   Database  │
                   └─────────────┘
```

## Installation

### Prerequisites
- Zig 0.15.x
- Access to Ethereum L1/L2 RPC endpoints (Alchemy, Infura, etc.)

### Build

```bash
# Clone the repository
git clone https://github.com/ensdomains/ensv2-indexer.git
cd ensv2-indexer

# Build all binaries
zig build

# Run tests
zig build test
```

### Binaries

| Binary | Description |
|--------|-------------|
| `ensv2-indexer` | Main indexer (V1 + V2) |
| `ensv2-indexer-v1` | V1-only indexer |
| `ensv2-indexer-v2` | V2-only indexer |
| `ensv2-api` | Standalone GraphQL API server |
| `rainbow-backfill` | Rainbow table label backfill |

## Configuration

Configuration is done via environment variables. Create a `.env` file:

```bash
# RPC URL
RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_API_KEY

# Network Configuration
NETWORK=sepolia  # or mainnet
START_BLOCK=0

# Indexer Configuration
POLL_INTERVAL=12
BATCH_SIZE=1000
MAX_BLOCKS_PER_REQUEST=1000

# Rate Limiting
RATE_LIMIT_PER_SECOND=10

# Database
DATABASE_PATH=./data/ens.db

# API Server
API_PORT=8080
API_ENABLED=true

# GraphQL Limits
GRAPHQL_MAX_DEPTH=10
GRAPHQL_MAX_COST=1000

# Webhooks (optional)
WEBHOOKS_ENABLED=false
WEBHOOK_MAX_RETRIES=3
WEBHOOK_DB_PATH=./data/webhooks.db
```

### Configuration Options

| Option | Description | Default |
|--------|-------------|---------|
| `RPC_URL` | Ethereum RPC endpoint | Required |
| `NETWORK` | Network name (sepolia, mainnet) | sepolia |
| `START_BLOCK` | Block to start indexing from | 0 |
| `POLL_INTERVAL` | Polling interval in seconds | 12 |
| `BATCH_SIZE` | Blocks per batch | 1000 |
| `DATABASE_PATH` | SQLite database file path | `./data/ens.db` |
| `API_PORT` | API server port | 8080 |
| `GRAPHQL_MAX_DEPTH` | Maximum GraphQL query nesting | 10 |
| `GRAPHQL_MAX_COST` | Maximum query cost (DoS protection) | 1000 |
| `RATE_LIMIT_PER_SECOND` | API rate limit per IP | 10 |
| `WEBHOOKS_ENABLED` | Enable webhook system | false |

## Usage

### Running the Indexer

```bash
# Run indexer (starts API server automatically)
./zig-out/bin/ensv2-indexer

# Or run with custom database
DATABASE_PATH=/tmp/ens.db ./zig-out/bin/ensv2-indexer

# Run API server only (read-only, no indexing)
./zig-out/bin/ensv2-api --port 8080
```

### GraphQL API

The API is available at `http://localhost:8080/graphql`

#### Query Examples

```graphql
# Get domain by name
query {
  domain(id: "tanrikulu.eth") {
    name
    namehash
    owner
    registrant
    expiryDate
    resolver {
      address
      texts { key value }
      addresses { coinType address }
    }
    subdomains(first: 10) {
      name
      owner
    }
  }
}

# Get domains owned by address
query {
  domains(where: { owner: "0x..." }, first: 20) {
    name
    expiryDate
  }
}

# Get account with registrations
query {
  account(id: "0x...") {
    domains { name }
    registrations {
      domain { name }
      expiryDate
      registrationDate
    }
  }
}

# Get recent events
query {
  events(first: 50, where: { type: "NameRegistered" }) {
    type
    blockNumber
    transactionHash
    domain { name }
  }
}

# Cursor-based pagination
query {
  domainConnection(first: 10, after: "cursor...") {
    edges {
      node { name owner }
      cursor
    }
    pageInfo {
      hasNextPage
      endCursor
    }
  }
}
```

### Webhook Setup

Webhooks are sent as HTTP POST requests with JSON payloads:

```json
{
  "event_type": "NameRegistered",
  "chain": "v2",
  "block_number": 12345678,
  "tx_hash": "0x...",
  "name": "alice.eth",
  "namehash": "0x...",
  "data": {
    "owner": "0x...",
    "expires": 1735689600
  }
}
```

## Project Structure

```
ensv2-indexer/
├── src/
│   ├── main.zig              # Combined indexer + API entry
│   ├── api_main.zig          # Standalone API entry
│   ├── indexer_l1_main.zig   # L1-only indexer entry
│   ├── config.zig            # Configuration loading
│   ├── env.zig               # Environment variable parsing
│   │
│   ├── types/                # Core data types
│   │   ├── address.zig       # Ethereum address
│   │   ├── hash.zig          # Hash and namehash
│   │   ├── token_id.zig      # ERC1155 token IDs
│   │   └── models.zig        # Data models
│   │
│   ├── rpc/                  # RPC client
│   │   └── client.zig        # Ethereum JSON-RPC (batching, multi-address)
│   │
│   ├── storage/              # Database layer
│   │   ├── database.zig      # SQLite connection
│   │   ├── names.zig         # Name/domain storage
│   │   ├── events.zig        # Event storage
│   │   ├── resolvers.zig     # Resolver data storage
│   │   ├── roles.zig         # EAC roles storage
│   │   ├── registrations.zig # Registration queries
│   │   ├── webhooks.zig      # Webhook management
│   │   └── sync.zig          # Sync state tracking
│   │
│   ├── indexer/              # Event indexing
│   │   ├── indexer.zig       # Main indexer logic
│   │   └── abi.zig           # ABI encoding/decoding
│   │
│   ├── api/                  # GraphQL API
│   │   ├── server.zig        # HTTP server
│   │   ├── handler.zig       # Request handler
│   │   ├── resolvers/        # GraphQL resolvers
│   │   └── introspection.json # Schema introspection
│   │
│   └── utils/                # Utilities
│       ├── ens_normalize.zig # ENSIP-15 normalization
│       ├── keccak.zig        # Keccak-256 hashing
│       └── validation.zig    # Input validation
│
├── schema.graphql            # GraphQL schema definition
├── build.zig                 # Build configuration
├── build.zig.zon             # Dependencies
└── .env.example              # Example configuration
```

## Testing

```bash
# Run all tests
zig build test

# Run specific test file
zig test src/storage/events.zig
```

## Documentation

### Architecture Docs

- **[schema.graphql](schema.graphql)** - GraphQL schema definition
- **[architecture/](architecture/)** - Design documents

## Contributing

Contributions are welcome! Please:
1. Follow Zig coding conventions
2. Add tests for new features
3. Update documentation
4. Run `zig fmt` before committing

## License

MIT License - see LICENSE file for details

## Acknowledgments

- ENS v2 design by ENS Labs
- Built with [Zig](https://ziglang.org/)
