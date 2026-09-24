-- Shift the seeded demo analytics forward so the data always ends today.
--
-- Used by .aviator/scripts/preview-setup.sh at every preview launch, and safe to
-- run on a schedule against a local database: it is a no-op until the newest
-- event is at least a day old. See preview-setup.sh for why the shift is by
-- whole days and applied to every table with the same offset.
DO $$
DECLARE
  latest      timestamptz;
  shift_days  integer;
BEGIN
  SELECT max(created_at) INTO latest FROM website_event;

  IF latest IS NULL THEN
    RAISE NOTICE 'no seeded events — nothing to shift';
    RETURN;
  END IF;

  shift_days := floor(extract(epoch FROM (now() - latest)) / 86400)::int;

  IF shift_days < 1 THEN
    RAISE NOTICE 'demo data is already current';
    RETURN;
  END IF;

  UPDATE session       SET created_at = created_at + make_interval(days => shift_days);
  UPDATE website_event SET created_at = created_at + make_interval(days => shift_days);
  UPDATE event_data    SET created_at = created_at + make_interval(days => shift_days);
  UPDATE session_data  SET created_at = created_at + make_interval(days => shift_days);
  UPDATE revenue       SET created_at = created_at + make_interval(days => shift_days);

  RAISE NOTICE 'shifted demo analytics forward % day(s)', shift_days;
END $$;
