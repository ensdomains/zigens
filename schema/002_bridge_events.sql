-- ENSv2 Indexer Database Schema
-- Migration 002: V2 token observers
-- Originally created to track cross-protocol bridge events alongside token observers.
-- The bridge-related tables (migrations, renewal_syncs) were removed in 2026-04;
-- `token_observers` remains because it tracks the V2 Registry's TokenObserverSet
-- event and is not bridging. Filename kept to preserve migration ordering.

-- ============================================================================
-- TOKEN OBSERVERS (V2 Registry TokenObserverSet event)
-- ============================================================================

CREATE TABLE IF NOT EXISTS token_observers (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  protocol TEXT NOT NULL,
  token_id TEXT NOT NULL,
  observer TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  transaction_hash TEXT NOT NULL,
  log_index INTEGER NOT NULL,
  timestamp INTEGER NOT NULL,
  UNIQUE(protocol, transaction_hash, log_index)
);

CREATE INDEX IF NOT EXISTS idx_token_observers_token_id ON token_observers(protocol, token_id);
CREATE INDEX IF NOT EXISTS idx_token_observers_block ON token_observers(protocol, block_number);
CREATE INDEX IF NOT EXISTS idx_token_observers_observer ON token_observers(observer);
