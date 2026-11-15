-- 3014 (release 48): the security checks (supabase/tests/99_r35sec_security.sql) over the merged release
-- (docs/changes/2026-11-14-r48-plan-first-instalment.md).
--   1. The two tables of the site calls (2995) have row-level security like every table: they are read and written only
--      by the server's functions (no policy: nobody reads them directly).
--   2. Two helpers of the signing and the card name (2910, 2912) were executable by PUBLIC: for the server only, as
--      every SECURITY DEFINER helper (the functions that call them run as their owner).
alter table app.inbound_call_media enable row level security;
alter table app.call_backfill enable row level security;

revoke all on function app.esign_pick(text, uuid, text) from public, anon, authenticated;
grant execute on function app.esign_pick(text, uuid, text) to service_role;
revoke all on function app.card_name_ok(uuid, text, text) from public, anon, authenticated;
grant execute on function app.card_name_ok(uuid, text, text) to service_role;
