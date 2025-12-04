-- Schema for tracking unknown subdomain labels that need backfill
-- These are labels from NewOwner events where we only have the labelhash
-- but not the actual label text. We'll batch-fetch transaction calldata
-- later to extract the label text.

CREATE TABLE IF NOT EXISTS unknown_labels (
    id INTEGER PRIMARY KEY AUTOINCREMENT,

    -- The name record this label belongs to (may be NULL if name wasn't created)
    name_id INTEGER,

    -- Transaction hash where the label was used (we'll fetch this tx to get calldata)
    transaction_hash TEXT NOT NULL,

    -- The labelhash we're trying to resolve
    labelhash TEXT NOT NULL,

    -- The namehash of the subdomain (for reference)
    namehash TEXT NOT NULL,

    -- Parent node (for reconstructing full name once we have label)
    parent_node TEXT NOT NULL,

    -- Owner address (from the NewOwner event)
    owner TEXT NOT NULL,

    -- Block number where this was first seen
    block_number INTEGER NOT NULL,

    -- When this record was created (for tracking backfill age)
    created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),

    -- Track backfill attempts
    backfill_attempts INTEGER NOT NULL DEFAULT 0,
    last_backfill_attempt INTEGER,

    FOREIGN KEY (name_id) REFERENCES names(id) ON DELETE CASCADE
);

-- Index for efficient backfill queries
CREATE INDEX IF NOT EXISTS idx_unknown_labels_backfill
    ON unknown_labels(backfill_attempts, created_at)
    WHERE backfill_attempts < 3;  -- Don't keep trying forever

-- Index for looking up by transaction hash
CREATE INDEX IF NOT EXISTS idx_unknown_labels_tx_hash
    ON unknown_labels(transaction_hash);

-- Index for looking up by labelhash (avoid duplicates)
CREATE INDEX IF NOT EXISTS idx_unknown_labels_labelhash
    ON unknown_labels(labelhash);

-- Unique constraint: Don't track the same labelhash multiple times
CREATE UNIQUE INDEX IF NOT EXISTS idx_unknown_labels_unique
    ON unknown_labels(labelhash, parent_node);
