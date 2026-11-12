-- 2428_r40_old_leads_in_pool.sql
-- Release 40. The owner, Nov 12: "Bulk leads should actually just be available for any sales person to claim." Every open lead
-- nobody holds is already on the lead list for any fully onboarded salesperson to claim (1152), at any age. Next lead (the
-- pool, app.sl_open_pool) skipped leads older than 90 days, so the older ones were only reachable by searching the list.
-- Next lead now serves every open lead: hot ones first, then the last 90 days oldest first (as before), then the older
-- ones newest first. Pacing, the cap, Admin assignments (2411) and the call holds (2320) are unchanged.
create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '2428: the text to change was not found in %: %', p_sig, left(p_old, 120); end if;
  execute replace(d, p_old, p_new);
end $$;

select pg_temp.patch_fn('app.sl_open_pool(uuid, text, timestamptz)'::regprocedure,
  'and l.created_at > p_now - interval ''90 days''
',
  '');
select pg_temp.patch_fn('app.sl_open_pool(uuid, text, timestamptz)'::regprocedure,
  'desc, l.created_at asc',
  'desc, (l.created_at > p_now - interval ''90 days'') desc,
            case when l.created_at > p_now - interval ''90 days'' then l.created_at end asc, l.created_at desc');
