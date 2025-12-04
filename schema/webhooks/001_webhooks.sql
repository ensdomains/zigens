-- Webhook Database Schema
-- Separate SQLite database for webhook management and delivery queue
-- This allows webhook workers to operate independently from the main indexer

-- ============================================================================
-- WEBHOOK CONFIGURATION
-- ============================================================================

CREATE TABLE IF NOT EXISTS webhooks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  url TEXT NOT NULL,
  event_types TEXT NOT NULL,  -- JSON array of event types to subscribe to
  active INTEGER NOT NULL DEFAULT 1,
  max_retries INTEGER NOT NULL DEFAULT 3,
  created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_webhooks_active ON webhooks(active);

-- ============================================================================
-- WEBHOOK DELIVERY QUEUE
-- ============================================================================

-- Webhook delivery queue for async, persistent delivery
-- Survives restarts and handles rate limiting per endpoint
CREATE TABLE IF NOT EXISTS webhook_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    webhook_id INTEGER NOT NULL,
    webhook_url TEXT NOT NULL,  -- Denormalized for faster worker processing
    event_type TEXT NOT NULL,
    chain TEXT NOT NULL,
    block_number INTEGER NOT NULL,
    tx_hash TEXT NOT NULL,
    contract_address TEXT NOT NULL,
    payload TEXT NOT NULL,      -- Full JSON payload
    timestamp INTEGER NOT NULL,

    -- Delivery tracking
    status TEXT NOT NULL DEFAULT 'pending',  -- pending, processing, delivered, failed
    retry_count INTEGER NOT NULL DEFAULT 0,
    last_attempt_at INTEGER,
    next_retry_at INTEGER,       -- For rate limiting and exponential backoff
    error_message TEXT,

    created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
    updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),

    FOREIGN KEY (webhook_id) REFERENCES webhooks(id) ON DELETE CASCADE
);

-- Index for worker queries (fetch pending/retry items)
CREATE INDEX IF NOT EXISTS idx_webhook_queue_status_next_retry
    ON webhook_queue(status, next_retry_at, webhook_url);

-- Index for cleanup queries (old delivered/failed items)
CREATE INDEX IF NOT EXISTS idx_webhook_queue_status_created
    ON webhook_queue(status, created_at);

-- Index for per-webhook queries
CREATE INDEX IF NOT EXISTS idx_webhook_queue_webhook_id
    ON webhook_queue(webhook_id);
