-- Migration 012: Add registrant column to names table
-- The registrant is the original account that registered the domain (from NameRegistered event)
-- This is separate from the owner which can change via transfers

-- Add registrant column (defaults to owner for existing records)
ALTER TABLE names ADD COLUMN registrant TEXT;

-- Backfill registrant from owner for existing records
UPDATE names SET registrant = owner WHERE registrant IS NULL;

-- Create index for efficient registrant lookups
CREATE INDEX IF NOT EXISTS idx_names_registrant ON names(registrant);
