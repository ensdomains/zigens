-- First-class registrations table.
-- Previously, registrations were derived on-the-fly from `events` with JSON parsing.
-- This table stores each registration once, enabling fast queries and joins.

CREATE TABLE IF NOT EXISTS registrations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  chain TEXT NOT NULL,
  namehash TEXT NOT NULL,
  label TEXT NOT NULL,
  parent_name TEXT NOT NULL,          -- e.g. "eth" for .eth 2LDs
  registrant TEXT NOT NULL,           -- lowercase 0x-prefixed
  registered_at INTEGER NOT NULL,     -- block timestamp (unix seconds)
  expiry INTEGER,                     -- nullable; null/0 = no expiry
  block_number INTEGER NOT NULL,
  transaction_hash TEXT NOT NULL,
  log_index INTEGER NOT NULL,
  event_type TEXT NOT NULL,           -- 'NameRegistered' (V1/V2-Registrar) | 'LabelRegistered' (V2-Registry)
  UNIQUE(chain, transaction_hash, log_index)
);

CREATE INDEX IF NOT EXISTS idx_registrations_chain_registrant ON registrations(chain, registrant);
CREATE INDEX IF NOT EXISTS idx_registrations_chain_namehash ON registrations(chain, namehash);
CREATE INDEX IF NOT EXISTS idx_registrations_chain_registered_at ON registrations(chain, registered_at);
CREATE INDEX IF NOT EXISTS idx_registrations_chain_expiry ON registrations(chain, expiry);

-- Backfill from existing events on first run. Uses json_extract for V1 owner payload.
-- This INSERT is idempotent thanks to the UNIQUE constraint.
-- registrant has a final `n.owner` fallback and is filtered out if it remains NULL;
-- the registrations.registrant column is NOT NULL, and we'd rather skip a row than fail the migration.
INSERT OR IGNORE INTO registrations
  (chain, namehash, label, parent_name, registrant, registered_at, expiry, block_number, transaction_hash, log_index, event_type)
SELECT
  e.chain,
  n.namehash,
  COALESCE(n.label, ''),
  COALESCE(n.parent_name, ''),
  LOWER(COALESCE(
    json_extract(e.data, '$.registrant'),
    json_extract(e.data, '$.owner'),
    n.registrant,
    n.owner,
    '0x0000000000000000000000000000000000000000'
  )),
  e.timestamp,
  n.expiry,
  e.block_number,
  e.tx_hash,
  e.log_index,
  e.event_type
FROM events e
JOIN names n ON n.namehash = e.namehash AND n.chain = e.chain
WHERE e.event_type IN ('NameRegistered', 'LabelRegistered')
  AND e.namehash IS NOT NULL;
