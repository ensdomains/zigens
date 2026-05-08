-- Drop redundant V2 NameRegistered rows from the registrations table.
--
-- Background: prior to this migration, both V2 handlers wrote to
-- `registrations` for fresh .eth registrations:
--   * handleETHNameRegistered (IETHRegistrar.NameRegistered, payment metadata)
--   * handleLabelRegistered   (PermissionedRegistry.LabelRegistered, canonical)
-- Both fire in the same transaction for the same name, so each fresh V2
-- registration produced two rows. Migrations and V1 names were already
-- single-rowed.
--
-- The handler write is now removed from handleETHNameRegistered; this
-- migration cleans up rows previously inserted by it. We delete a V2
-- NameRegistered row only when a LabelRegistered row exists for the same
-- (protocol, namehash) — never blindly, so we don't lose data if for some
-- reason the LabelRegistered handler didn't fire.
--
-- Idempotent: re-running on a clean DB is a no-op.

DELETE FROM registrations
WHERE protocol = 'v2'
  AND event_type = 'NameRegistered'
  AND EXISTS (
    SELECT 1
    FROM registrations r2
    WHERE r2.protocol   = 'v2'
      AND r2.namehash   = registrations.namehash
      AND r2.event_type = 'LabelRegistered'
  );
