-- Rainbow table for caching labelhash → label mappings
-- This table is populated automatically as we index the protocol from:
--   1. V1 Controller NameRegistered events (contains label text)
--   2. Transaction calldata decoding (setSubnodeOwner/setSubnodeRecord)
--   3. Other wrapper patterns we can decode
--
-- Purpose: Reuse discovered labels to resolve future unknown labelhashes
-- without needing to re-fetch and re-decode transactions

CREATE TABLE IF NOT EXISTS rainbow_labels (
    labelhash TEXT PRIMARY KEY,
    label TEXT NOT NULL,
    source TEXT NOT NULL CHECK (source IN ('controller', 'calldata', 'wrapper', 'manual')),
    first_seen_block INTEGER NOT NULL,
    first_seen_tx TEXT NOT NULL,
    created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
    updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
);

-- Index for source-based analytics
CREATE INDEX IF NOT EXISTS idx_rainbow_source ON rainbow_labels(source);

-- Index for temporal analysis
CREATE INDEX IF NOT EXISTS idx_rainbow_block ON rainbow_labels(first_seen_block);

-- Statistics table for tracking rainbow table growth
CREATE TABLE IF NOT EXISTS rainbow_stats (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
);

-- Initialize stats
INSERT OR IGNORE INTO rainbow_stats (key, value) VALUES
    ('total_labels', '0'),
    ('controller_labels', '0'),
    ('calldata_labels', '0'),
    ('wrapper_labels', '0'),
    ('manual_labels', '0'),
    ('last_updated_block', '0');
