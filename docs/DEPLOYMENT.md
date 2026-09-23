# ENS Indexer (zigens) — Deployment Guide

Production deployment for the ENS indexer (V1 + V2). Configuration is via a `.env` file (see
[`.env.example`](../.env.example)); contract addresses are **built into the binary per `NETWORK`**
(`src/contracts.zig`) — you do not set them manually.

> **Ports:** the binary defaults to `API_PORT=8080` (`.env.example`). The Docker image sets
> `API_PORT=5655` and exposes `5655` (API) + `3001` (status). The examples below assume the native
> `8080`; substitute `5655` when running the published image.

## Quick Start

### Docker (recommended)

1. **Clone**
```bash
git clone <repository-url>
cd zigens
```

2. **Configure**
```bash
cp .env.example .env
# Edit .env — set RPC_URL and NETWORK (sepolia | mainnet)
```

3. **Start**
```bash
docker-compose up -d
```

4. **Check status** (Docker maps the API to `5655`)
```bash
docker-compose logs -f indexer
curl http://localhost:5655/api/health
```

### Native

#### Prerequisites
- Zig **0.15.2+**
- SQLite3
- systemd (for service management)

#### Build
```bash
zig build                       # all binaries; use -Doptimize=ReleaseSafe for production
# Binaries land in zig-out/bin/:
#   ensv2-indexer        (combined V1 + V2 — can also serve the API)
#   ensv2-indexer-v1 / -v2   (single-protocol)
#   ensv2-api            (standalone read-only GraphQL API)
#   rainbow-backfill     (label backfill tool)
```

#### Install as a system service

1. **Data directory + config**
```bash
sudo mkdir -p /var/lib/ensv2-indexer
sudo cp .env /var/lib/ensv2-indexer/.env       # the binary reads .env from its working dir
sudo chmod 600 /var/lib/ensv2-indexer/.env
sudo chown -R ens:ens /var/lib/ensv2-indexer
```

2. **Binary**
```bash
sudo cp zig-out/bin/ensv2-indexer /usr/local/bin/
sudo chmod +x /usr/local/bin/ensv2-indexer
```

3. **systemd unit**
```bash
sudo nano /etc/systemd/system/ensv2-indexer.service
```
```ini
[Unit]
Description=ENS Indexer (zigens)
After=network.target

[Service]
Type=simple
User=ens
Group=ens
WorkingDirectory=/var/lib/ensv2-indexer
ExecStart=/usr/local/bin/ensv2-indexer
Restart=always
RestartSec=10

# Security
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/ensv2-indexer

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=ensv2-indexer

[Install]
WantedBy=multi-user.target
```

4. **Enable + start**
```bash
sudo systemctl daemon-reload
sudo systemctl enable ensv2-indexer
sudo systemctl start ensv2-indexer
sudo systemctl status ensv2-indexer
```

5. **Logs**
```bash
sudo journalctl -u ensv2-indexer -f
```

## Configuration

All configuration is environment variables loaded from `.env` (full list in
[`.env.example`](../.env.example)). Common settings:

```bash
RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_API_KEY
NETWORK=sepolia            # or mainnet — selects the built-in contract address set
DATABASE_PATH=./data/ens.db
START_BLOCK=0              # 0 = from the contract deployment block
POLL_INTERVAL=12          # seconds between chain-head polls
BATCH_SIZE=1000           # blocks per batch (see note under Performance Tuning)
API_PORT=8080
WEBHOOKS_ENABLED=false
```

### Contract addresses

You do **not** configure contract addresses manually. They are compiled into the binary per network
(`src/contracts.zig`); selecting `NETWORK=sepolia` or `NETWORK=mainnet` picks the V1 (legacy registry,
registrar, name wrapper) and V2 (permissioned registry, L2 registrar) address set. You only provide
`RPC_URL` for the matching chain.

### RPC providers

Alchemy, Infura, QuickNode, Ankr, or your own node. The indexer rate-limits its own RPC usage
(`RATE_LIMIT_PER_SECOND`).

## API Endpoints

API served on `API_PORT` (`8080` native, `5655` in Docker).

### REST
- `GET /api/health` — health check
- `GET /api/name/{name}` — name information
- `GET /api/owner/{address}` — names owned by an address
- `GET /api/events` — recent events
- `GET /api/webhooks` — webhook management (CRUD; optional Basic Auth)
- `GET /metrics` — Prometheus metrics (when `METRICS_ENABLED=true`)

### GraphQL
- `GET /graphql` — GraphiQL playground
- `POST /graphql` — queries

```graphql
{
  domain(id: "alice.eth") {
    id
    name
    owner { id }
    resolver { id address }
    expiryDate
    isMigrated
  }
}
```

## Webhooks

Enable with `WEBHOOKS_ENABLED=true`, then register via the REST API:

```bash
curl -X POST http://localhost:8080/api/webhooks \
  -H 'content-type: application/json' \
  -d '{"url":"https://your-server.com/webhook","event_types":["NameRegistered","Transfer","NameRenewed"]}'
```

A signing `secret` is generated automatically per webhook (used for the `X-Webhook-Signature` HMAC).

### Payload

```json
{
  "event_type": "NameRegistered",
  "protocol": "v2",
  "block_number": 12345678,
  "tx_hash": "0x...",
  "log_index": 7,
  "contract_address": "0x...",
  "name": "alice.eth",
  "namehash": "0x...",
  "data": { "owner": "0x...", "expires": 1735689600 },
  "timestamp": 1704067200
}
```

Verify `X-Webhook-Signature` = `HMAC-SHA256(secret, "{X-Webhook-Timestamp}.{body}")`.

## Monitoring

### Health
```bash
curl http://localhost:8080/api/health
```

### Database
```bash
DB=/var/lib/ensv2-indexer/data/ens.db
sqlite3 "$DB" "SELECT * FROM sync_state;"                                  # per-protocol sync state
sqlite3 "$DB" "SELECT COUNT(*) FROM names;"                                # indexed names
sqlite3 "$DB" "SELECT * FROM events ORDER BY timestamp DESC LIMIT 10;"     # recent events
```

The GraphQL `_meta { block { number } hasIndexingErrors }` field also reports sync head + error state.

### Logs
```bash
docker-compose logs -f indexer            # Docker
sudo journalctl -u ensv2-indexer -f       # systemd
sudo journalctl -u ensv2-indexer -p err   # errors only
```

## Performance Tuning

### Database optimization
```bash
DB=/var/lib/ensv2-indexer/data/ens.db
sqlite3 "$DB" "VACUUM;"
sqlite3 "$DB" "ANALYZE;"
```

### Polling interval
`POLL_INTERVAL` (seconds): lower = more real-time, higher RPC usage; higher = less real-time, lower usage.

### Batch size
`BATCH_SIZE` controls blocks per batch (the indexer also auto-shrinks/grows the range adaptively on RPC
errors). **Note an in-repo inconsistency to reconcile:** `.env.example` ships `BATCH_SIZE=1000` while the
compiled default in `src/config.zig` is `2000`. Set it explicitly in `.env` to avoid ambiguity.

## Backup

SQLite — use the online `.backup` command (safe while running, WAL-consistent) or stop + copy:

```bash
DB=/var/lib/ensv2-indexer/data/ens.db
# Online (preferred):
sqlite3 "$DB" ".backup '/backup/ens-$(date +%Y%m%d).db'"

# Or offline:
sudo systemctl stop ensv2-indexer
cp "$DB" /backup/ens-$(date +%Y%m%d).db
sudo systemctl start ensv2-indexer
```

### Automated
```bash
# crontab — daily online backup at 02:00
0 2 * * * sqlite3 /var/lib/ensv2-indexer/data/ens.db ".backup '/backup/ens-$(date +\%Y\%m\%d).db'"
```

## Troubleshooting

### Indexer not syncing
```bash
# 1. RPC connectivity
curl -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' "$RPC_URL"

# 2. Logs
sudo journalctl -u ensv2-indexer -n 100
```
3. Verify `NETWORK` matches your `RPC_URL`'s chain.

### High CPU/memory
- Increase `POLL_INTERVAL`, reduce `BATCH_SIZE`.
- Ensure the DB is optimized (`VACUUM`, `ANALYZE`).
- Check for SQLite write-lock contention during heavy initial sync.

### API not responding
```bash
sudo systemctl status ensv2-indexer
netstat -tuln | grep 8080         # or 5655 under Docker
sudo ufw status
```

## Security

### Firewall
```bash
sudo ufw allow 8080/tcp                        # native (use 5655 for Docker)
sudo ufw allow from YOUR_IP to any port 8080   # or restrict to specific IPs
```

### API exposure
The GraphQL/REST API is **read-only** and per-IP rate-limited (`RATE_LIMIT_PER_SECOND`; set
`TRUSTED_PROXY_HOPS` when behind a proxy so limiting keys on the real client IP). The webhook
management API can require Basic Auth (`WEBHOOK_ADMIN_USERNAME` / `WEBHOOK_ADMIN_PASSWORD`). For a
public deployment, front it with a reverse proxy.

### SSL/TLS (nginx)
```nginx
server {
    listen 443 ssl;
    server_name indexer.yourdomain.com;

    ssl_certificate     /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;

    location / {
        proxy_pass http://localhost:8080;     # or 5655 under Docker
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```
(Set `TRUSTED_PROXY_HOPS=1` so the rate limiter reads the proxied client IP.)

## Scaling

### Multiple instances
Run multiple indexers for redundancy — separate `DATABASE_PATH` per instance, on different hosts, with
the API requests load-balanced.

### Read replicas
Serve API queries from read-only copies of the SQLite DB:
1. Snapshot with `sqlite3 ".backup"` (or `rsync` a quiesced copy) — **not** `pg_dump` (this is SQLite).
2. Run `ensv2-api` instances pointed at the replica (`DATABASE_PATH`).
3. Route read traffic to the replicas.

> A PostgreSQL backend (for real concurrency/replication) is planned but not yet implemented — see
> [`postgresql-migration-plan.md`](postgresql-migration-plan.md).

## Support

- GitHub Issues: `<repository-url>/issues`
- Docs: [`../README.md`](../README.md), [`TESTING.md`](TESTING.md)
- ENS Discord: https://chat.ens.domains/
