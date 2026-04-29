-- First-class registrations table.
-- Previously, registrations were derived on-the-fly from `events` with JSON parsing.
-- This table stores each registration once, enabling fast queries and joins.

CREATE TABLE IF NOT EXISTS registrations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  protocol TEXT NOT NULL,
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
  UNIQUE(protocol, transaction_hash, log_index)
);

CREATE INDEX IF NOT EXISTS idx_registrations_protocol_registrant ON registrations(protocol, registrant);
CREATE INDEX IF NOT EXISTS idx_registrations_protocol_namehash ON registrations(protocol, namehash);
CREATE INDEX IF NOT EXISTS idx_registrations_protocol_registered_at ON registrations(protocol, registered_at);
CREATE INDEX IF NOT EXISTS idx_registrations_protocol_expiry ON registrations(protocol, expiry);

-- Backfill from existing events on first run. Uses json_extract for V1 owner payload.
-- This INSERT is idempotent thanks to the UNIQUE constraint.
-- registrant has a final `n.owner` fallback and is filtered out if it remains NULL;
-- the registrations.registrant column is NOT NULL, and we'd rather skip a row than fail the migration.
INSERT OR IGNORE INTO registrations
  (protocol, namehash, label, parent_name, registrant, registered_at, expiry, block_number, transaction_hash, log_index, event_type)
SELECT
  e.protocol,
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
JOIN names n ON n.namehash = e.namehash AND n.protocol = e.protocol
WHERE e.event_type IN ('NameRegistered', 'LabelRegistered')
  AND e.namehash IS NOT NULL;
