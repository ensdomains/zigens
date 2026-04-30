-- ENSv2 Indexer Database Schema
-- Migration 023: Reverse-resolution records (V1 + V2)
--
-- Stores the (address → node) binding emitted by ReverseClaimed (V1) and the
-- equivalent V2 ETHReverseRegistrar event. Without this table, reverse lookups
-- must scan the events feed; with it, a single point query answers
-- "what reverse did this address claim?".
--
-- Note: presence of a reverse claim DOES NOT prove the reverse name resolves
-- forward to the claimant — primary-name verification (round-trip check) must
-- be performed by consumers via the resolver record path.

CREATE TABLE IF NOT EXISTS reverse_records (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  protocol TEXT NOT NULL,                -- 'v1' or 'v2'
  address TEXT NOT NULL,                 -- the address claiming this reverse (lowercased 0x-prefixed)
  namehash TEXT NOT NULL,                -- the reverse node (V1: keccak(<addr>.addr.reverse))
  block_number INTEGER NOT NULL,
  transaction_hash TEXT NOT NULL,
  log_index INTEGER NOT NULL,
  timestamp INTEGER NOT NULL,
  UNIQUE(protocol, address)              -- one current reverse per (protocol, address)
);

CREATE INDEX IF NOT EXISTS idx_reverse_records_protocol_address ON reverse_records(protocol, address);
CREATE INDEX IF NOT EXISTS idx_reverse_records_namehash ON reverse_records(namehash);
