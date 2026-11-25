-- 4701_r50_site_errors.sql
-- Release 50: staff kept landing on server error pages, and nothing outside the site could read the errors. Three
-- read-only Admin connector tools, and the server's own errors kept beside the browser's.
--   1. Server errors are kept: the Worker's request errors (Next's onRequestError, src/instrumentation.ts) go to
--      client_errors with kind 'server' through public.server_error_log (service role, 300 an hour at most like the
--      browser's, no Admin task: a real crash in a page still reaches the browser's error page and is counted there).
--   2. site_errors {hours, kind, path, limit}: the errors of the last hours (24 by default, at most 30 days) grouped by
--      page (ids folded to :id) and message, with the count, the people, first and last seen, the kinds and the viewers'
--      roles. Emails, phone numbers, ids, tokens and long numbers are masked.
--   3. site_health: the site checks that are not ok (and their failures of the last 24 hours) and the data health
--      problems of the last run.
--   4. search_console_issues {limit}: the pages Google sees with an error (5xx, 404, soft 404, redirect errors, blocked,
--      crawl anomalies), the other pages not indexed by bucket, the sitemaps with errors or warnings or still pending,
--      and the last coverage summary. Only what the Search Console sync stored (1860, 2420): read from the database.
-- All three run in app.api_call (wrapped: api_call_pre4701) as an Admin's key (admin:read) and are logged in api_calls.
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

-- ================================================================ 1. the server's errors
alter table client_errors drop constraint client_errors_kind_check;
alter table client_errors add constraint client_errors_kind_check
  check (kind = any (array['crash', 'network', 'transition', 'stale_build', 'translation', 'foreign', 'server']));

create function public.server_error_log(p jsonb) returns text
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_user uuid := case when coalesce(p ->> 'user_id', '') ~ '^[0-9a-f-]{36}$' then (p ->> 'user_id')::uuid end;
begin
  if (select count(*) from client_errors where kind = 'server' and created_at > now() - interval '1 hour') >= 300 then return 'limited'; end if;
  if v_user is not null and not exists (select 1 from users where id = v_user) then v_user := null; end if;
  insert into client_errors (path, message, stack, ua, digest, user_id, kind)
  values (left(coalesce(nullif(btrim(p ->> 'path'), ''), '/'), 300), left(coalesce(nullif(btrim(p ->> 'message'), ''), 'Unknown server error'), 500),
          left(p ->> 'stack', 4000), left(coalesce(p ->> 'ua', 'server'), 300), left(p ->> 'digest', 100), v_user, 'server');
  return 'kept';
end $$;
revoke all on function public.server_error_log(jsonb) from public, anon, authenticated;
grant execute on function public.server_error_log(jsonb) to service_role;

-- ================================================================ 2. the tools' reads
create function app.redact_text(s text) returns text
language sql immutable set search_path = public, app, pg_temp as $$
  select regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(coalesce(s, ''),
    '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '[email]', 'g'),
    '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', ':id', 'g'),
    '(eyJ[A-Za-z0-9_-]{8,}(\.[A-Za-z0-9_-]+)*|(sk|pk|rk|whsec)_[A-Za-z0-9_]{8,}|[A-Za-z0-9_-]{32,})', '[token]', 'g'),
    '\+?[0-9][0-9 ().-]{8,}[0-9]', '[number]', 'g'),
    '(token|key|secret|password|code)=[^&\s]+', '\1=[hidden]', 'gi')
$$;

create function app.viewer_role(p_user uuid) returns text
language sql stable security definer set search_path = public, app, pg_temp as $$
  select case when p_user is null then 'visitor'
              when app.user_is_admin(p_user) then 'admin'
              when app.user_is_staff(p_user) then coalesce('staff:' || (select string_agg(f, '+' order by f) from staff_profiles sp, unnest(sp.functions) f where sp.user_id = p_user), 'staff')
              when app.user_is_field(p_user) then 'field'
              when exists (select 1 from owners o where o.user_id = p_user) then 'owner'
              when exists (select 1 from renters r where r.user_id = p_user) then 'renter'
              else 'signed_in' end
$$;

create function app.site_errors(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v_hours integer := least(greatest(coalesce(nullif(p ->> 'hours', '')::integer, 24), 1), 720);
  v_kind text := nullif(btrim(coalesce(p ->> 'kind', '')), '');
  v_path text := nullif(btrim(coalesce(p ->> 'path', '')), '');
  v_limit integer := least(greatest(coalesce(nullif(p ->> 'limit', '')::integer, 100), 1), 500);
  v jsonb;
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin reads the site''s errors' using errcode = '42501'; end if;
  if v_kind is not null and v_kind not in ('all', 'real', 'server', 'crash', 'network', 'transition', 'stale_build', 'translation', 'foreign') then
    raise exception 'kind: all, real (server and crash, the default), server, crash, network, transition, stale_build, translation or foreign' using errcode = '22023';
  end if;
  with e as (
    select regexp_replace(split_part(e.path, '?', 1), '/([0-9a-fA-F-]{36}|[A-Za-z]{1,4}-[0-9]{3,}|[0-9]{3,}|[A-Za-z0-9_-]{20,})(?=/|$)', '/:id', 'g') page,
           left(app.redact_text(regexp_replace(e.message, 'https://react\.dev/errors/([0-9]+)[^ ]*', 'react.dev/errors/\1', 'g')), 300) msg,
           e.kind, e.created_at, e.user_id, e.visitor, e.ua, e.digest
      from client_errors e
     where e.created_at > now() - make_interval(hours => v_hours)
       and (case coalesce(v_kind, 'real') when 'all' then true when 'real' then e.kind in ('server', 'crash') else e.kind = v_kind end)
       and (v_path is null or e.path like v_path || '%')
  ), g as (
    select page, msg, count(*) n, count(distinct coalesce(user_id::text, visitor, md5(coalesce(ua, '')))) people,
           min(created_at) first_seen, max(created_at) last_seen, array_agg(distinct kind) kinds,
           array_agg(distinct app.viewer_role(user_id)) roles, (array_agg(digest order by created_at desc) filter (where digest is not null))[1] digest
      from e group by page, msg
  )
  select jsonb_build_object('hours', v_hours, 'kind', coalesce(v_kind, 'real'),
    'total', coalesce((select sum(n) from g), 0), 'groups', (select count(*) from g),
    'by_kind', coalesce((select jsonb_object_agg(kind, n) from (select kind, count(*) n from e group by kind) k), '{}'::jsonb),
    'items', coalesce((select jsonb_agg(jsonb_build_object('page', page, 'message', msg, 'count', n, 'people', people, 'first_seen', first_seen,
                        'last_seen', last_seen, 'kinds', to_jsonb(kinds), 'roles', to_jsonb(roles), 'digest', digest) order by n desc, last_seen desc)
                       from (select * from g order by n desc, last_seen desc limit v_limit) x), '[]'::jsonb),
    'note', 'Browser errors and the server''s own (kind server, since 4701). The Worker''s logs outside the app (Cloudflare) are not here.')
    into v;
  return v;
end $$;

create function app.site_health_tool(p_by uuid, p jsonb default '{}') returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  h jsonb;
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin reads the site health' using errcode = '42501'; end if;
  h := app.data_health_read(p_by);
  return jsonb_build_object(
    'checks', coalesce((select jsonb_agg(jsonb_build_object('key', c.key, 'label', c.label, 'kind', c.kind, 'path', c.path, 'status', c.status,
              'failing_since', c.failing_since, 'consecutive_failures', c.consecutive_failures, 'last_checked_at', c.last_checked_at, 'last_ok_at', c.last_ok_at,
              'last_http', c.last_http, 'last_ms', c.last_ms, 'detail', left(app.redact_text(c.last_detail), 300), 'advice', c.advice,
              'failures_24h', (select count(*) from uptime_results r where r.check_key = c.key and not r.ok and r.at > now() - interval '24 hours')) order by c.sort)
             from uptime_checks c where c.enabled and (c.status is distinct from 'ok'
               or exists (select 1 from uptime_results r where r.check_key = c.key and not r.ok and r.at > now() - interval '24 hours'))), '[]'::jsonb),
    'checks_ok', (select count(*) from uptime_checks c where c.enabled and c.status = 'ok'),
    'data_health', jsonb_build_object('ran_at', h -> 'ran_at', 'issues', h -> 'issues',
      'problems', coalesce((select jsonb_agg(jsonb_build_object('key', c ->> 'key', 'title', c ->> 'title', 'count', (c ->> 'count')::integer, 'line', left(app.redact_text(c ->> 'line'), 300), 'href', c ->> 'href'))
                            from jsonb_array_elements(coalesce(h -> 'checks', '[]'::jsonb)) c where coalesce((c ->> 'count')::integer, 0) > 0), '[]'::jsonb),
      'fixed', h -> 'fixed'));
end $$;

create function app.search_console_issues(p_by uuid, p jsonb default '{}') returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v_limit integer := least(greatest(coalesce(nullif(p ->> 'limit', '')::integer, 200), 1), 1000);
  v_err text := '(5xx|server error|404|not found|soft 404|redirect error|blocked|crawl anomaly|unauthorized|403|access forbidden|other 4xx)';
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin reads Search Console' using errcode = '42501'; end if;
  return jsonb_build_object(
    'sync_on', (select gsc_sync_on from program_settings limit 1),
    'last_inspected_at', (select max(inspected_at) from app.gsc_url_inspection),
    'errors', coalesce((select jsonb_agg(jsonb_build_object('path', path, 'state', state, 'sitemap', sitemap, 'last_crawl', last_crawl, 'inspected_at', inspected_at) order by inspected_at desc)
              from (select * from app.gsc_url_inspection where state ~* v_err order by inspected_at desc limit v_limit) x), '[]'::jsonb),
    'errors_by_state', coalesce((select jsonb_object_agg(state, n) from (select state, count(*) n from app.gsc_url_inspection where state ~* v_err group by state) s), '{}'::jsonb),
    'not_indexed_by_state', coalesce((select jsonb_object_agg(state, n) from (select state, count(*) n from app.gsc_url_inspection where bucket <> 'indexed' and state !~* v_err group by state) s), '{}'::jsonb),
    'sitemaps', coalesce((select jsonb_agg(jsonb_build_object('path', path, 'errors', errors, 'warnings', warnings, 'pending', is_pending, 'last_downloaded', last_downloaded,
                'submitted', submitted, 'indexed', indexed, 'at', at) order by errors desc, warnings desc)
              from app.gsc_sitemap_latest where coalesce(errors, 0) > 0 or coalesce(warnings, 0) > 0 or is_pending
                 or last_downloaded is null or last_downloaded < now() - interval '7 days'), '[]'::jsonb),
    'coverage', (select jsonb_build_object('at', at, 'inspected', inspected, 'errors', errors, 'by_state', by_state, 'by_bucket', by_bucket)
                   from app.gsc_coverage_log order by at desc limit 1),
    'note', 'What the Search Console sync stored (URL Inspection, sitemaps, coverage). Google''s own report can be newer.');
end $$;

-- ================================================================ 3. the connector
alter function app.api_call(text, text, jsonb, text) rename to api_call_pre4701;
create function app.api_call(p_hash text, p_tool text, p_args jsonb, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  a jsonb := case when jsonb_typeof(p_args) = 'object' then p_args else '{}'::jsonb end;
  chk jsonb;
  k api_keys;
  v_result jsonb;
begin
  if p_tool not in ('site_errors', 'site_health', 'search_console_issues') then return app.api_call_pre4701(p_hash, p_tool, p_args, p_client); end if;
  chk := app.api_key_check(p_hash, 'admin:read', p_tool, a, p_client);
  if not (chk ->> 'ok')::boolean then return chk; end if;
  k := jsonb_populate_record(null::api_keys, chk -> 'key');
  perform app.door_begin(k.user_id, 'aal2');
  begin
    v_result := case p_tool when 'site_errors' then app.site_errors(k.user_id, a)
                            when 'site_health' then app.site_health_tool(k.user_id, a)
                            else app.search_console_issues(k.user_id, a) end;
  exception when others then
    insert into api_calls (key_id, user_id, tool, target, args, ok, error, client) values (k.id, k.user_id, p_tool, p_tool, a, false, left(sqlerrm, 500), left(p_client, 64));
    return jsonb_build_object('ok', false, 'status', case sqlstate when 'P0002' then 404 when '42501' then 403 else 400 end, 'error', regexp_replace(sqlerrm, '^.*?ERROR:\s*', ''));
  end;
  insert into api_calls (key_id, user_id, tool, target, args, ok, client) values (k.id, k.user_id, p_tool, p_tool, a, true, left(p_client, 64));
  return jsonb_build_object('ok', true, 'result', v_result);
end $$;
select pg_temp.copy_grants('app.api_call(text, text, jsonb, text)'::regprocedure, 'app.api_call_pre4701(text, text, jsonb, text)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['redact_text', 'viewer_role', 'site_errors', 'site_health_tool', 'search_console_issues', 'api_call_pre4701']) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
