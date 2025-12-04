-- ENSv2 Indexer Database Schema
-- Migration 002: Bridge and Cross-Chain Events
-- Added: 2025-01-XX for bridge event tracking

-- ============================================================================
-- MIGRATIONS (Cross-chain name migrations)
-- ============================================================================

CREATE TABLE IF NOT EXISTS migrations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  chain TEXT NOT NULL,
  token_id TEXT NOT NULL,
  direction TEXT NOT NULL,  -- 'to_l1' or 'to_l2'
  dns_encoded_name TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  transaction_hash TEXT NOT NULL,
  log_index INTEGER NOT NULL,
  timestamp INTEGER NOT NULL,
  UNIQUE(chain, transaction_hash, log_index)
);

CREATE INDEX IF NOT EXISTS idx_migrations_token_id ON migrations(chain, token_id);
CREATE INDEX IF NOT EXISTS idx_migrations_block ON migrations(chain, block_number);
CREATE INDEX IF NOT EXISTS idx_migrations_direction ON migrations(direction);

-- ============================================================================
-- RENEWAL SYNCS (Cross-chain renewal synchronization)
-- ============================================================================

CREATE TABLE IF NOT EXISTS renewal_syncs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  chain TEXT NOT NULL,
  token_id TEXT NOT NULL,
  new_expiry INTEGER NOT NULL,
  block_number INTEGER NOT NULL,
  transaction_hash TEXT NOT NULL,
  log_index INTEGER NOT NULL,
  timestamp INTEGER NOT NULL,
  UNIQUE(chain, transaction_hash, log_index)
);

CREATE INDEX IF NOT EXISTS idx_renewal_syncs_token_id ON renewal_syncs(chain, token_id);
CREATE INDEX IF NOT EXISTS idx_renewal_syncs_block ON renewal_syncs(chain, block_number);

-- ============================================================================
-- TOKEN OBSERVERS (Observer assignments for tokens)
-- ============================================================================

CREATE TABLE IF NOT EXISTS token_observers (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  chain TEXT NOT NULL,
  token_id TEXT NOT NULL,
  observer TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  transaction_hash TEXT NOT NULL,
  log_index INTEGER NOT NULL,
  timestamp INTEGER NOT NULL,
  UNIQUE(chain, transaction_hash, log_index)
);

CREATE INDEX IF NOT EXISTS idx_token_observers_token_id ON token_observers(chain, token_id);
CREATE INDEX IF NOT EXISTS idx_token_observers_block ON token_observers(chain, block_number);
CREATE INDEX IF NOT EXISTS idx_token_observers_observer ON token_observers(observer);
