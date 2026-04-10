# ENSv2 Indexer - Deployment Guide

## Quick Start

### Docker Deployment (Recommended)

1. **Clone the repository**
```bash
git clone <repository-url>
cd ensv2-indexer
```

2. **Create configuration**
```bash
cp config.example.json config.json
# Edit config.json with your RPC endpoints and contract addresses
```

3. **Start with Docker Compose**
```bash
docker-compose up -d
```

4. **Check status**
```bash
docker-compose logs -f ensv2-indexer
curl http://localhost:8080/api/health
```

### Native Deployment

#### Prerequisites
- Zig 0.13.0 or later
- SQLite3
- systemd (for service management)

#### Build

```bash
# Build optimized release
zig build -Doptimize=ReleaseFast

# Binary will be in zig-out/bin/ensv2-indexer
```

#### Install as System Service

1. **Create config directory**
```bash
sudo mkdir -p /etc/ensv2-indexer
sudo cp config.json /etc/ensv2-indexer/
sudo chmod 600 /etc/ensv2-indexer/config.json
```

2. **Copy binary**
```bash
sudo cp zig-out/bin/ensv2-indexer /usr/local/bin/
sudo chmod +x /usr/local/bin/ensv2-indexer
```

3. **Create data directory**
```bash
sudo mkdir -p /var/lib/ensv2-indexer
sudo chown ens:ens /var/lib/ensv2-indexer
```

4. **Create systemd service**
```bash
sudo nano /etc/systemd/system/ensv2-indexer.service
```

```ini
[Unit]
Description=ENSv2 Indexer
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

5. **Enable and start service**
```bash
sudo systemctl daemon-reload
sudo systemctl enable ensv2-indexer
sudo systemctl start ensv2-indexer
sudo systemctl status ensv2-indexer
```

6. **View logs**
```bash
sudo journalctl -u ensv2-indexer -f
```

## Configuration

### Required Settings

```json
{
  "rpc_url": "https://eth-mainnet.g.alchemy.com/v2/YOUR_API_KEY",
  "root_registry": "0x...",
  "eth_registry": "0x...",
  "registry_datastore": "0x...",
  "start_block": 19000000
}
```

### Contract Addresses

You'll need to obtain the deployed contract addresses for:
- Root Registry
- .eth Registry
- Registry Datastore
- L1 Registry Datastore
- L2 Registry Datastore
- L1 Universal Resolver
- L1 Fallback Resolver
- L1/L2 Migration Contracts
- L1/L2 Ejection Controllers

These will be published by ENS DAO when ENSv2 is deployed.

### RPC Providers

Recommended RPC providers:
- **Alchemy**: https://www.alchemy.com/
- **Infura**: https://www.infura.io/
- **QuickNode**: https://www.quicknode.com/
- **Ankr**: https://www.ankr.com/

### Starting Block Numbers

Set `l1_start_block` and `l2_start_block` to the block where ENSv2 contracts were deployed. This reduces initial sync time.

## API Endpoints

### REST API

- `GET /api/health` - Health check
- `GET /api/name/{name}` - Get name information
- `GET /api/owner/{address}` - Get names owned by address
- `GET /api/events` - Get recent events

### GraphQL API

- `GET /graphql` - GraphQL Playground (documentation)
- `POST /graphql` - GraphQL queries

Example GraphQL query:
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

### Register a Webhook

```sql
INSERT INTO webhooks (url, event_types, active, max_retries, created_at)
VALUES (
  'https://your-server.com/webhook',
  '["NameRegistered","Transfer","NameRenewed"]',
  1,
  3,
  strftime('%s', 'now')
);
```

### Webhook Payload

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

## Monitoring

### Health Checks

```bash
# Check if service is running
curl http://localhost:8080/api/health

# Should return:
# {"status":"ok","service":"ensv2-indexer"}
```

### Database Monitoring

```bash
# Check sync state
sqlite3 /var/lib/ensv2-indexer/ensv2.db "SELECT * FROM sync_state;"

# Check indexed names count
sqlite3 /var/lib/ensv2-indexer/ensv2.db "SELECT COUNT(*) FROM names;"

# Check recent events
sqlite3 /var/lib/ensv2-indexer/ensv2.db "SELECT * FROM events ORDER BY timestamp DESC LIMIT 10;"
```

### Logs

```bash
# Docker
docker-compose logs -f ensv2-indexer

# Systemd
sudo journalctl -u ensv2-indexer -f

# Check for errors
sudo journalctl -u ensv2-indexer -p err
```

## Performance Tuning

### Database Optimization

```bash
# Optimize database
sqlite3 /var/lib/ensv2-indexer/ensv2.db "VACUUM;"
sqlite3 /var/lib/ensv2-indexer/ensv2.db "ANALYZE;"
```

### Polling Interval

Adjust `poll_interval` in config.json:
- Faster polling (6-12s): More real-time, higher RPC usage
- Slower polling (30-60s): Less real-time, lower RPC usage

### Batch Size

The indexer processes blocks in batches of 1000. For slower RPC endpoints, you may want to reduce this in the source code.

## Backup

### Database Backup

```bash
# Stop indexer
sudo systemctl stop ensv2-indexer

# Backup database
cp /var/lib/ensv2-indexer/ensv2.db /backup/ensv2-$(date +%Y%m%d).db

# Start indexer
sudo systemctl start ensv2-indexer
```

### Automated Backups

```bash
# Add to crontab
0 2 * * * /usr/local/bin/backup-ensv2.sh
```

## Troubleshooting

### Indexer Not Syncing

1. Check RPC connectivity
```bash
curl -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  YOUR_RPC_URL
```

2. Check logs for errors
```bash
sudo journalctl -u ensv2-indexer -n 100
```

3. Verify contract addresses are correct

### High CPU/Memory Usage

- Reduce polling interval
- Reduce batch size
- Check for database lock issues
- Ensure database is optimized (VACUUM, ANALYZE)

### API Not Responding

1. Check if service is running
```bash
sudo systemctl status ensv2-indexer
```

2. Check if port is accessible
```bash
netstat -tuln | grep 8080
```

3. Check firewall rules
```bash
sudo ufw status
```

## Security

### Firewall

```bash
# Allow API port (if public)
sudo ufw allow 8080/tcp

# Or restrict to specific IPs
sudo ufw allow from YOUR_IP to any port 8080
```

### API Authentication

For production, add authentication:
- Use reverse proxy (nginx) with basic auth
- Implement API keys
- Use OAuth2/JWT tokens

### SSL/TLS

Use a reverse proxy (nginx, caddy) for SSL:

```nginx
server {
    listen 443 ssl;
    server_name indexer.yourdomain.com;

    ssl_certificate /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;

    location / {
        proxy_pass http://localhost:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

## Scaling

### Multiple Instances

Run multiple indexers for redundancy:
- Use different database files
- Run on different servers
- Load balance API requests

### Read Replicas

Create read-only database replicas for API queries:
1. Replicate database using rsync/pg_dump
2. Run API-only instances pointing to replica
3. Route read traffic to replicas

## Support

- GitHub Issues: <repository-url>/issues
- Documentation: <repository-url>/docs
- ENS Discord: https://chat.ens.domains/
