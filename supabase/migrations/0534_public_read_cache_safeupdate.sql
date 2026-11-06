-- 0534 (hotfix r27b, part 1c): 0533's trigger dropped the public reads' kept copy with a DELETE without a WHERE clause,
-- which pg_safeupdate refuses on the company server: every save of the site or program settings failed. The delete now
-- names its rows.
create or replace function app.public_read_cache_drop() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  delete from app.public_read_cache where key is not null;
  return null;
end $$;
