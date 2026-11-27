-- 5165_r50h2_indexnow_drain.sql
-- Release 50 hotfix 2 (the coordinator: maximise the crawl rate legitimately, IndexNow pings on change). The gsc run of
-- Nov 27 01:43 UTC: IndexNow on, its key file answering, 8,580 changed pages waiting and 0 sent in a day; the sweep
-- answered "changed pages first" (0220: it waits while changed pages wait). The changed pages go out only through the
-- site's search job claim (server_seo_claim), which runs with the AI writer and had stopped reaching them, so neither
-- the changed pages nor the sweep moved. Now the gsc workflow also sends the changed pages itself:
--   app.server_indexnow_changed_claim(n): up to n waiting changed pages (the oldest first, inside the search scope, not
--   while their back-off holds), answered as the search job's are, through app.server_indexnow_sent (0220).
-- A changed page outside the search scope (Core) can never be claimed; it is set aside (attempts 5) so it no longer
-- holds the sweep back.
set local check_function_bodies = off;

create function app.server_indexnow_changed_claim(p_limit integer default 1000) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  w indexnow_sweep;
  v_n integer := least(greatest(coalesce(p_limit, 1000), 1), 10000);
begin
  if not coalesce((app.settings()).indexnow_enabled, false) then return jsonb_build_object('paths', '[]'::jsonb, 'why', 'IndexNow is off'); end if;
  select * into w from indexnow_sweep limit 1;
  if w.q_backoff_until > now() then return jsonb_build_object('paths', '[]'::jsonb, 'why', 'changed pages wait until ' || w.q_backoff_until); end if;
  update indexnow_queue set attempts = 5, last_error = 'outside the search scope'
   where sent_at is null and attempts < 5 and not app.crawl_scope_ok(path);
  return jsonb_build_object('paths', coalesce((select jsonb_agg(q.path order by q.queued_at, q.path)
      from (select path, queued_at from indexnow_queue where sent_at is null and attempts < 5 order by queued_at, path limit v_n) q), '[]'::jsonb));
end $$;

revoke all on function app.server_indexnow_changed_claim(integer) from public, anon, authenticated;
grant execute on function app.server_indexnow_changed_claim(integer) to service_role;
