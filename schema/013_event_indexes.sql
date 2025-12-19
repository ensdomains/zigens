-- Additional indexes for events table performance
-- These indexes improve query performance for common access patterns

-- Index for filtering events by contract address
CREATE INDEX IF NOT EXISTS idx_events_contract_address ON events(contract_address);

-- Compound index for common query pattern: chain + event_type + block_number
-- Used for filtered event queries with ordering by block
CREATE INDEX IF NOT EXISTS idx_events_chain_type_block ON events(chain, event_type, block_number);

-- Compound index for ordering by block and log index (cursor pagination)
CREATE INDEX IF NOT EXISTS idx_events_block_log ON events(block_number, log_index);
