-- Orphaned registrations table
-- Stores NameRegistered events that were skipped because no parent had claimed
-- the subregistry at the time. These are processed when a parent claims the subregistry.

CREATE TABLE IF NOT EXISTS orphaned_registrations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  chain TEXT NOT NULL,
  subregistry_address TEXT NOT NULL,
  token_id TEXT NOT NULL,
  label TEXT NOT NULL,
  expiry INTEGER NOT NULL,
  owner TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  tx_hash TEXT NOT NULL,
  log_index INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  UNIQUE(chain, tx_hash, log_index)
);

CREATE INDEX IF NOT EXISTS idx_orphaned_subregistry ON orphaned_registrations(chain, subregistry_address);
CREATE INDEX IF NOT EXISTS idx_orphaned_block ON orphaned_registrations(block_number);
