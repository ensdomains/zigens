-- V1 Controller tracking for dynamic discovery
-- Tracks which controller contracts were active at different times

CREATE TABLE IF NOT EXISTS v1_controllers (
    controller_address TEXT PRIMARY KEY,
    added_block_number INTEGER NOT NULL,
    removed_block_number INTEGER,  -- NULL if still active
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    added_tx_hash TEXT NOT NULL,
    removed_tx_hash TEXT,
    created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_v1_controllers_active ON v1_controllers(is_active);
CREATE INDEX IF NOT EXISTS idx_v1_controllers_added_block ON v1_controllers(added_block_number);
