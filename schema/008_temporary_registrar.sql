-- ENS Temporary Registrar (Auction System) Support
-- Used from May 2017 (block 3327417) to May 2019 (block ~9380410)
-- Vickrey auction system for .eth second-level domains

-- ============================================================================
-- AUCTIONS TABLE
-- ============================================================================
-- Tracks the auction state for .eth names during the temporary registrar period
-- Each .eth name went through an auction process before being registered

CREATE TABLE IF NOT EXISTS temp_auctions (
  label_hash TEXT PRIMARY KEY,           -- keccak256(label) - the auction identifier
  label TEXT,                            -- Actual label (if known from registration)
  status TEXT NOT NULL,                  -- "open" | "reveal" | "finalized" | "released"
  registration_date INTEGER,             -- When auction was finalized (HashRegistered)
  value_eth TEXT,                        -- Winning bid amount in wei
  winner_address TEXT,                   -- Address that won/registered the name
  start_block INTEGER NOT NULL,          -- Block where auction started
  start_tx TEXT NOT NULL,                -- Transaction that started auction
  end_block INTEGER,                     -- Block where auction finalized/released
  end_tx TEXT,                           -- Transaction that finalized/released
  created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_temp_auctions_status ON temp_auctions(status);
CREATE INDEX IF NOT EXISTS idx_temp_auctions_winner ON temp_auctions(winner_address);
CREATE INDEX IF NOT EXISTS idx_temp_auctions_label ON temp_auctions(label);
CREATE INDEX IF NOT EXISTS idx_temp_auctions_start_block ON temp_auctions(start_block);

-- ============================================================================
-- BIDS TABLE
-- ============================================================================
-- Tracks sealed bids placed during auctions
-- In Vickrey auction: bidders submit hash of (bid + secret)

CREATE TABLE IF NOT EXISTS temp_bids (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  label_hash TEXT NOT NULL,              -- Auction being bid on
  bidder_address TEXT NOT NULL,          -- Address placing the bid
  sealed_bid_hash TEXT NOT NULL,         -- Hash commitment (keccak256(labelhash + bidder + value + salt))
  deposit_eth TEXT NOT NULL,             -- Amount deposited with bid (in wei)
  block_number INTEGER NOT NULL,         -- When bid was placed
  tx_hash TEXT NOT NULL,                 -- Transaction containing bid
  log_index INTEGER NOT NULL,
  revealed BOOLEAN NOT NULL DEFAULT 0,   -- Whether bid was revealed
  created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
  UNIQUE(label_hash, bidder_address, sealed_bid_hash)
);

CREATE INDEX IF NOT EXISTS idx_temp_bids_label_hash ON temp_bids(label_hash);
CREATE INDEX IF NOT EXISTS idx_temp_bids_bidder ON temp_bids(bidder_address);
CREATE INDEX IF NOT EXISTS idx_temp_bids_revealed ON temp_bids(revealed);
CREATE INDEX IF NOT EXISTS idx_temp_bids_block ON temp_bids(block_number);

-- ============================================================================
-- BID REVEALS TABLE
-- ============================================================================
-- Tracks revealed bids after bidding period ends
-- Reveals show the actual bid amount and salt

CREATE TABLE IF NOT EXISTS temp_bid_reveals (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  label_hash TEXT NOT NULL,              -- Auction this reveal is for
  bidder_address TEXT NOT NULL,          -- Bidder revealing
  revealed_value_eth TEXT NOT NULL,      -- Actual bid amount (in wei)
  status INTEGER NOT NULL,               -- Reveal status code (from event)
  block_number INTEGER NOT NULL,         -- When revealed
  tx_hash TEXT NOT NULL,                 -- Transaction containing reveal
  log_index INTEGER NOT NULL,
  created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
  UNIQUE(label_hash, bidder_address, block_number, log_index)
);

CREATE INDEX IF NOT EXISTS idx_temp_bid_reveals_label_hash ON temp_bid_reveals(label_hash);
CREATE INDEX IF NOT EXISTS idx_temp_bid_reveals_bidder ON temp_bid_reveals(bidder_address);
CREATE INDEX IF NOT EXISTS idx_temp_bid_reveals_block ON temp_bid_reveals(block_number);
CREATE INDEX IF NOT EXISTS idx_temp_bid_reveals_status ON temp_bid_reveals(status);

-- ============================================================================
-- INVALIDATIONS TABLE
-- ============================================================================
-- Tracks names that were invalidated (usually due to trademark issues)

CREATE TABLE IF NOT EXISTS temp_invalidations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  label_hash TEXT NOT NULL,              -- Label that was invalidated
  name TEXT NOT NULL,                    -- Full name that was invalidated
  registration_date INTEGER NOT NULL,    -- When it was originally registered
  invalidation_block INTEGER NOT NULL,   -- When it was invalidated
  invalidation_tx TEXT NOT NULL,
  log_index INTEGER NOT NULL,
  created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
  UNIQUE(label_hash, invalidation_block, log_index)
);

CREATE INDEX IF NOT EXISTS idx_temp_invalidations_label_hash ON temp_invalidations(label_hash);
CREATE INDEX IF NOT EXISTS idx_temp_invalidations_name ON temp_invalidations(name);
CREATE INDEX IF NOT EXISTS idx_temp_invalidations_block ON temp_invalidations(invalidation_block);
