-- Temporary Registrar Pre-Migration Events
-- Stores NewOwner events from the temporary registrar period (2017-2019)
-- These events will be backfilled with labels after V1 migration data is indexed

CREATE TABLE IF NOT EXISTS temp_pre_migration_names (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  protocol TEXT NOT NULL,
  namehash TEXT NOT NULL,
  label_hash TEXT NOT NULL,
  parent_node TEXT NOT NULL,
  owner TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  tx_hash TEXT NOT NULL,
  log_index INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  UNIQUE(protocol, namehash)
);

CREATE INDEX IF NOT EXISTS idx_temp_pre_migration_label_hash ON temp_pre_migration_names(label_hash);
CREATE INDEX IF NOT EXISTS idx_temp_pre_migration_protocol ON temp_pre_migration_names(protocol);

-- Track backfill status
CREATE TABLE IF NOT EXISTS backfill_status (
  task TEXT PRIMARY KEY,
  completed INTEGER NOT NULL DEFAULT 0,
  completed_at INTEGER,
  records_processed INTEGER DEFAULT 0
);
