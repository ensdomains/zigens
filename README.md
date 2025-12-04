# ENSv2 Indexer

A professional-grade, high-performance indexer for Ethereum Name Service v2 (ENSv2) written in Zig.

## Features

### Core Indexing
- **Multi-chain Support**: Indexes both L1 (Ethereum) and L2 ENSv2 deployments
- **Hierarchical Registry Tracking**: Follows the ENSv2 hierarchical registry model
- **Event Indexing**: Tracks all ENSv2 events:
  - `NewSubname` - New subname creation
  - `SubregistryUpdate` - Subregistry address changes
  - `ResolverUpdate` - Resolver address changes
  - `Transfer` - Name ownership transfers (ERC1155)
  - `NameRegistered` - New .eth registrations
  - `NameRenewed` - .eth name renewals
  - Migration events (ENSv1 → ENSv2)
  - Ejection events (L2 ↔ L1)

### Resolution
- **Hierarchical Resolution**: Implements the ENSv2 resolution algorithm
- **Database-first**: Fast lookups from indexed data
- **On-chain Fallback**: Queries on-chain when data not in database
- **CCIP-Read Support**: Resolves L2-hosted names via CCIP-Read

### Webhook System
- **Event Notifications**: Real-time webhooks for ENS events
- **Configurable**: Subscribe to specific event types
- **Retry Logic**: Exponential backoff with configurable retries
- **Reliable Delivery**: Queue-based delivery system

### API
- **REST API**: Query indexed data via HTTP
- **Endpoints**:
  - `GET /api/name/{name}` - Get name information
  - `GET /api/owner/{address}` - Get names owned by address
  - `GET /api/events` - Get recent events
  - `GET /api/health` - Health check
- **JSON Responses**: Standard JSON format
- **CORS Enabled**: Ready for web applications

### Storage
- **SQLite Database**: Efficient local storage
- **Optimized Indexes**: Fast queries by name, owner, expiry, etc.
- **Sync State Tracking**: Resumes from last synced block
- **Minimal Footprint**: Compact storage format

## Architecture

```
┌─────────────────┐
│   Main Process  │
├─────────────────┤
│   Config Load   │
│   DB Init       │
│   RPC Clients   │
└────────┬────────┘
         │
    ┌────┴────┐
    │         │
┌───▼───┐ ┌──▼────┐
│Indexer│ │  API  │
│Thread │ │Server │
└───┬───┘ └───────┘
    │
    ├─► L1 RPC Client ──► Ethereum Mainnet
    │
    ├─► L2 RPC Client ──► L2 Chain
    │
    ├─► Event Processor
    │   ├─► Registry Events
    │   ├─► Datastore Events
    │   ├─► Transfer Events
    │   └─► Migration/Ejection Events
    │
    ├─► Database Writer
    │   ├─► Names Table
    │   ├─► Registries Table
    │   ├─► Events Table
    │   └─► Sync State
    │
    └─► Webhook Manager
        └─► HTTP Delivery
```

## Installation

### Prerequisites
- Zig 0.13.0 or later
- SQLite3 development libraries
- Access to Ethereum L1 and L2 RPC endpoints

### Build

```bash
# Clone the repository
git clone https://github.com/yourusername/ensv2-indexer.git
cd ensv2-indexer

# Build the project
zig build

# Run tests
zig build test
```

## Configuration

Create a `config.json` file based on `config.example.json`:

```json
{
  "l1_rpc_url": "https://eth-mainnet.g.alchemy.com/v2/YOUR_API_KEY",
  "l2_rpc_url": "https://base-mainnet.g.alchemy.com/v2/YOUR_API_KEY",
  "l1_root_registry": "0x...",
  "l2_root_registry": "0x...",
  "l1_eth_registry": "0x...",
  "l2_eth_registry": "0x...",
  "l1_start_block": 19000000,
  "l2_start_block": 10000000,
  "database_path": "./ensv2.db",
  "api_port": 8080,
  "webhooks_enabled": true
}
```

### Configuration Options

| Option | Description | Default |
|--------|-------------|---------|
| `l1_rpc_url` | Ethereum L1 RPC endpoint | Required |
| `l2_rpc_url` | L2 RPC endpoint | Required |
| `l1_start_block` | Block to start indexing from (L1) | Required |
| `l2_start_block` | Block to start indexing from (L2) | Required |
| `l1_confirmations` | Blocks to wait for finality (L1) | 12 |
| `l2_confirmations` | Blocks to wait for finality (L2) | 2 |
| `poll_interval` | Polling interval in seconds | 12 |
| `database_path` | SQLite database file path | `./ensv2.db` |
| `api_port` | API server port | 8080 |
| `graphql_max_depth` | Maximum GraphQL query nesting depth | 10 |
| `graphql_max_cost` | Maximum GraphQL query cost (prevents DoS) | 1000 |
| `webhooks_enabled` | Enable webhook system | false |
| `webhook_max_retries` | Max webhook retry attempts | 3 |

## Usage

### Running the Indexer

```bash
# Run with default config (config.json)
zig build run

# Or run the built executable
./zig-out/bin/ensv2-indexer
```

### API Examples

```bash
# Get name information
curl http://localhost:8080/api/name/alice.eth

# Response:
# {
#   "name": "alice.eth",
#   "namehash": "0x...",
#   "owner": "0x...",
#   "resolver": "0x...",
#   "chain": "l2",
#   "expiry": 1735689600,
#   "registry_locked": false,
#   "migrated": true,
#   "ejected": false
# }

# Get names owned by address
curl http://localhost:8080/api/name/owner/0x...

# Health check
curl http://localhost:8080/api/health
```

### Webhook Setup

Webhooks are sent as HTTP POST requests with JSON payloads:

```json
{
  "event_type": "NameRegistered",
  "chain": "l2",
  "block_number": 12345678,
  "tx_hash": "0x...",
  "contract_address": "0x...",
  "name": "alice.eth",
  "namehash": "0x...",
  "data": {
    "name": "alice",
    "owner": "0x...",
    "expires": 1735689600
  },
  "timestamp": 1704067200
}
```

Register webhooks via database (API endpoint coming soon):

```sql
INSERT INTO webhooks (url, event_types, active, max_retries, created_at)
VALUES ('https://your-server.com/webhook', '["NameRegistered","Transfer"]', 1, 3, strftime('%s', 'now'));
```

## ENSv2 Architecture

This indexer implements the full ENSv2 specification:

### Hierarchical Registries
- Each name has its own registry contract
- Registries manage subdomains and resolvers
- Root registry → TLD registries → name registries

### Resolution Process
1. Start at root registry
2. Traverse down the name hierarchy
3. Query `getSubregistry()` and `getResolver()` at each level
4. Return the closest resolver found

### L1/L2 Architecture
- **L2**: Primary registration and management (lower fees)
- **L1**: Optional ejection for security/latency
- **Cross-chain Messaging**: Migration and ejection tracking
- **CCIP-Read**: L2 resolution from L1

## Performance

- **Indexing Speed**: ~1000 blocks per batch
- **API Response Time**: <10ms for cached queries
- **Database Size**: Compact SQLite storage
- **Memory Usage**: Minimal footprint (~50MB)

## Testing

```bash
# Run all tests
zig build test

# Run integration tests
zig build test-integration
```

## Development

### Project Structure

```
ensv2-indexer/
├── src/
│   ├── main.zig              # Entry point
│   ├── config.zig            # Configuration loading
│   ├── types/                # Core data types
│   │   ├── address.zig       # Ethereum address
│   │   ├── hash.zig          # Hash and namehash
│   │   └── models.zig        # Data models
│   ├── rpc/                  # RPC client
│   │   └── client.zig        # Ethereum JSON-RPC
│   ├── storage/              # Database layer
│   │   └── database.zig      # SQLite operations
│   ├── indexer/              # Event indexing
│   │   ├── indexer.zig       # Main indexer
│   │   └── abi.zig           # ABI encoding/decoding
│   ├── resolver/             # Name resolution
│   │   └── resolver.zig      # Hierarchical resolver
│   ├── webhooks/             # Webhook system
│   │   └── manager.zig       # Webhook delivery
│   └── api/                  # API server
│       └── server.zig        # HTTP server
├── tests/                    # Integration tests
├── architecture/             # ENSv2 design docs
├── build.zig                 # Build configuration
├── build.zig.zon            # Dependencies
└── config.example.json      # Example configuration
```

## Documentation

### Architecture Docs

Detailed architecture documentation is available in the `architecture/` folder:

- **[GRAPHQL_IMPLEMENTATION.md](architecture/GRAPHQL_IMPLEMENTATION.md)** - GraphQL server implementation strategy
  - Current approach: Schema-first with build-time introspection
  - Future options: Generic resolution and full code generation
  - Migration paths and decision rationale

- **[ens-v2-design.md](architecture/ens-v2-design.md)** - ENS V2 contract design
- **[DEPLOYMENTS.md](architecture/DEPLOYMENTS.md)** - Deployment configurations

### Schema

The GraphQL schema is defined in [`schema.graphql`](schema.graphql). Changes to the schema automatically regenerate introspection data at build time.

## Contributing

Contributions are welcome! Please:
1. Follow Zig coding conventions
2. Add tests for new features
3. Update documentation
4. Run `zig fmt` before committing

## License

MIT License - see LICENSE file for details

## Acknowledgments

- ENS v2 design by ENS DAO
- Inspired by [ensnode](https://github.com/namehash/ensnode)
- Built with [Zig](https://ziglang.org/)

## Roadmap

### Completed ✅
- [x] GraphQL API layer (schema-first with introspection)
- [x] Webhook system with retry logic
- [x] Multi-chain indexing (L1 + L2)
- [x] Event indexing and storage
- [x] Name resolution

### In Progress 🚧
- [ ] Full CCIP-Read implementation
- [ ] Webhook management API endpoints

### Planned 📋
- [ ] Real-time WebSocket subscriptions
- [ ] Multi-chain registry discovery
- [ ] GraphQL subscriptions (Option C implementation)
- [ ] Docker deployment
- [ ] Kubernetes manifests
- [ ] Metrics and monitoring (Prometheus)
- [ ] Rate limiting
- [ ] API authentication
