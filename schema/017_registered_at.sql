ALTER TABLE names ADD COLUMN registered_at INTEGER;
UPDATE names SET registered_at = created_at WHERE registered_at IS NULL;
