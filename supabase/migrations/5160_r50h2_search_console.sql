-- 5160_r50h2_search_console.sql
-- Release 50 hotfix 2 (the owner: "does the Search Console auto-correct actually fix Search Console errors?"). What the
-- data showed on Nov 27 (search_console_issues, heal_status, the gsc run of 01:43 UTC):
--   * the sitemaps the Admin saw "with errors" were partly files the property no longer holds: app.gsc_sitemap_latest kept
--     the last row of every file ever stored (873 rows for a property of 500), so a file removed on Nov 6 still showed its
--     error. The view now holds the files of the last stored run only.
--   * /sitemap-families.xml was in Search Console with an error and 0 addresses: a failed read answered an empty file (the
--     web fix: a failed read answers 503, and the tracker pages moved to the pages file).
--   * the self-healing gsc playbooks (4800: a missing car page redirected, a restart on 5xx) never ran (0 successes, 0
--     failures): the coverage sample inspects sitemap addresses, which the site lists, so it never met a gone page. The
--     gsc workflow now also checks the pages Google shows in search on the live site (web/scripts/gsc-coverage.mjs).
--   * the searches themselves (app.gsc_page_query) had no read for the connector: search_console_queries (admin:read).
-- No applied migration is edited: app.api_call is wrapped (api_call_pre5160).
set local check_function_bodies = off;

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. the sitemaps of the last run only
-- one run stores every file in one statement (one now()); a file the property dropped has no row in it
create or replace view app.gsc_sitemap_latest with (security_invoker = true) as
  select distinct on (l.path) l.path, l.at, l.is_index, l.is_pending, l.last_downloaded, l.errors, l.warnings, l.submitted, l.indexed
    from app.gsc_sitemap_log l
   where l.at >= (select max(x.at) from app.gsc_sitemap_log x) - interval '30 minutes'
   order by l.path, l.at desc;
revoke all on app.gsc_sitemap_latest from public, anon, authenticated;
grant select on app.gsc_sitemap_latest to service_role;

-- ================================================================ 2. the searches, for the connector (Admins)
create function app.search_console_queries(p_by uuid, p jsonb default '{}') returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v_limit integer := least(greatest(coalesce(nullif(p ->> 'limit', '')::integer, 200), 1), 1000);
  v_match text := nullif(btrim(left(coalesce(p ->> 'contains', ''), 80)), '');
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin reads Search Console' using errcode = '42501'; end if;
  return jsonb_build_object(
    'window_end', (select max(window_end) from app.gsc_page_query),
    'totals', (select jsonb_build_object('queries', count(*), 'clicks', coalesce(sum(clicks), 0), 'impressions', coalesce(sum(impressions), 0)) from app.gsc_page_query where kind = 'query'),
    'queries', coalesce((select jsonb_agg(jsonb_build_object('query', q.key, 'clicks', q.clicks, 'impressions', q.impressions, 'ctr', q.ctr, 'position', round(q.position, 1)) order by q.impressions desc, q.key)
        from (select * from app.gsc_page_query where kind = 'query' and (v_match is null or strpos(lower(key), lower(v_match)) > 0)
               order by impressions desc, key limit v_limit) q), '[]'::jsonb),
    'pages', coalesce((select jsonb_agg(jsonb_build_object('path', g.key, 'clicks', g.clicks, 'impressions', g.impressions, 'ctr', g.ctr, 'position', round(g.position, 1)) order by g.impressions desc, g.key)
        from (select * from app.gsc_page_query where kind = 'page' and (v_match is null or strpos(lower(key), lower(v_match)) > 0)
               order by impressions desc, key limit v_limit) g), '[]'::jsonb),
    'note', 'Search Analytics over the last 28 settled days, stored by the gsc workflow (the top 5,000 searches and pages). Searches only: no person.');
end $$;

alter function app.api_call(text, text, jsonb, text) rename to api_call_pre5160;
create function app.api_call(p_hash text, p_tool text, p_args jsonb, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  a jsonb := case when jsonb_typeof(p_args) = 'object' then p_args else '{}'::jsonb end;
  chk jsonb;
  k api_keys;
  v_result jsonb;
begin
  if p_tool <> 'search_console_queries' then return app.api_call_pre5160(p_hash, p_tool, p_args, p_client); end if;
  chk := app.api_key_check(p_hash, 'admin:read', p_tool, a, p_client);
  if not (chk ->> 'ok')::boolean then return chk; end if;
  k := jsonb_populate_record(null::api_keys, chk -> 'key');
  perform app.door_begin(k.user_id, 'aal2');
  begin
    v_result := app.search_console_queries(k.user_id, a);
  exception when others then
    insert into api_calls (key_id, user_id, tool, target, args, ok, error, client) values (k.id, k.user_id, p_tool, p_tool, a, false, left(sqlerrm, 500), left(p_client, 64));
    return jsonb_build_object('ok', false, 'status', case sqlstate when '42501' then 403 else 400 end, 'error', regexp_replace(sqlerrm, '^.*?ERROR:\s*', ''));
  end;
  insert into api_calls (key_id, user_id, tool, target, args, ok, client) values (k.id, k.user_id, p_tool, p_tool, a, true, left(p_client, 64));
  return jsonb_build_object('ok', true, 'result', v_result);
end $$;
select pg_temp.copy_grants('app.api_call(text, text, jsonb, text)'::regprocedure, 'app.api_call_pre5160(text, text, jsonb, text)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['search_console_queries', 'api_call_pre5160']) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
