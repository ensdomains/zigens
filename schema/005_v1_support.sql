-- ENSv2 Indexer Database Schema - V1 Support
-- Adds columns and tables needed for complete ENS V1 integration

-- ============================================================================
-- V1 ENHANCEMENTS TO NAMES TABLE
-- ============================================================================

-- Add columns for Name Wrapper state tracking
ALTER TABLE names ADD COLUMN is_wrapped INTEGER NOT NULL DEFAULT 0;
ALTER TABLE names ADD COLUMN wrapper_fuses TEXT DEFAULT NULL;
ALTER TABLE names ADD COLUMN wrapper_expiry INTEGER DEFAULT NULL;

-- Add columns to distinguish V1 from V2 names
ALTER TABLE names ADD COLUMN is_v1_name INTEGER NOT NULL DEFAULT 0;
ALTER TABLE names ADD COLUMN v1_label_hash TEXT DEFAULT NULL;

-- Indexes for new columns
CREATE INDEX IF NOT EXISTS idx_names_is_wrapped ON names(is_wrapped);
CREATE INDEX IF NOT EXISTS idx_names_is_v1_name ON names(is_v1_name);
CREATE INDEX IF NOT EXISTS idx_names_v1_label_hash ON names(v1_label_hash);
CREATE INDEX IF NOT EXISTS idx_names_wrapper_expiry ON names(wrapper_expiry);

-- ============================================================================
-- V1 LABELS TABLE
-- ============================================================================
-- Maps TokenID → label for ENS V1 Base Registrar .eth names
-- The Base Registrar (ERC721) uses tokenId = uint256(keccak256(label))
-- We need to store the actual label text when we see it in events

CREATE TABLE IF NOT EXISTS v1_labels (
  token_id TEXT PRIMARY KEY,           -- The ERC721 token ID (keccak256 of label)
  label TEXT NOT NULL,                  -- The actual label text (e.g., "vitalik")
  namehash TEXT NOT NULL,               -- The full namehash (e.g., hash("vitalik.eth"))
  first_seen_block INTEGER NOT NULL,    -- Block where we first learned this mapping
  first_seen_tx TEXT NOT NULL,          -- Transaction where we first learned this mapping
  source TEXT NOT NULL                  -- How we learned it: "NameRegistered" | "NameRenewed" | "Transfer" | "Controller"
);

CREATE INDEX IF NOT EXISTS idx_v1_labels_label ON v1_labels(label);
CREATE INDEX IF NOT EXISTS idx_v1_labels_namehash ON v1_labels(namehash);

-- ============================================================================
-- NAME HISTORY TABLE
-- ============================================================================
-- Tracks all state changes to names (ownership, resolver, expiry)
-- Useful for historical queries and audit trails

CREATE TABLE IF NOT EXISTS name_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  chain TEXT NOT NULL,
  namehash TEXT NOT NULL,               -- The name that changed
  name TEXT NOT NULL,                   -- Human-readable name
  change_type TEXT NOT NULL,            -- "ownership" | "resolver" | "expiry" | "wrapper" | "creation" | "migration"
  old_value TEXT,                       -- Previous value (NULL for creation)
  new_value TEXT NOT NULL,              -- New value
  block_number INTEGER NOT NULL,
  tx_hash TEXT NOT NULL,
  log_index INTEGER NOT NULL,
  timestamp INTEGER NOT NULL,
  UNIQUE(chain, namehash, change_type, block_number, log_index)
);

CREATE INDEX IF NOT EXISTS idx_name_history_namehash ON name_history(namehash);
CREATE INDEX IF NOT EXISTS idx_name_history_chain_name ON name_history(chain, name);
CREATE INDEX IF NOT EXISTS idx_name_history_change_type ON name_history(change_type);
CREATE INDEX IF NOT EXISTS idx_name_history_block ON name_history(chain, block_number);
CREATE INDEX IF NOT EXISTS idx_name_history_timestamp ON name_history(timestamp);
