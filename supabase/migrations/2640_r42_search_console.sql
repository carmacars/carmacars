-- 2640_r42_search_console.sql
-- Release 42 (docs/changes/2026-11-12-r42-search-console.md). The site reads Google Search Console by itself, once an
-- Admin connects it (Marketing > SEO, "Connect Google Search Console": OAuth with the site's Google client, the
-- webmasters scope, offline access). The refresh token lives in the vault (as the reviews sync's, 0146, and the
-- calendar's, 2303); nothing else stores it.
--   1. app.gsc_link: the one connection (status, account, property, the last sync, its totals and its last error).
--   2. Once a day the site's job (/api/jobs/gsc, when app.server_jobs_due says "gsc") reads Search Analytics for the last
--      28 days by page (app.gsc_page_totals) and by page and query (app.gsc_page_queries), submits the sitemap, and
--      inspects a few written pages Google shows nowhere (kept in app.gsc_url_inspection, 1860: a page that is not
--      indexed is sent to IndexNow on its growing schedule).
--   3. The writer: a landing page or a guide ranking at position 8 to 20, or shown at least 50 times with a click rate
--      under 1%, is written again through the copy queue that exists (status pending: the search job of 0061 takes it
--      within the day's neurons), with its best searches handed to the prompt (app.gsc_rewrite_queue). At most
--      gsc_rewrite_daily_max pages a day, and the same page at most once in 28 days. Program settings turn the sync
--      (gsc_sync_on) and the rewrites (gsc_rewrite_on) off; both are on.
--   4. Marketing > SEO (Admin, and Sales read only) shows the connection, the last sync, the 28-day totals, the best
--      searches, the pages queued and the last error (app.seo_data, key gsc).
-- No applied migration is edited: functions are wrapped.
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

-- ================================================================ settings
alter table program_settings
  add column gsc_sync_on boolean not null default true,
  add column gsc_rewrite_on boolean not null default true,
  add column gsc_rewrite_daily_max integer not null default 5 check (gsc_rewrite_daily_max between 0 and 50),
  add column gsc_inspect_daily_max integer not null default 50 check (gsc_inspect_daily_max between 0 and 500);
comment on column program_settings.gsc_sync_on is 'Search Console (2640): the site reads Search Console once a day while it is connected (Marketing > SEO).';
comment on column program_settings.gsc_rewrite_on is 'Search Console (2640): pages ranking at position 8 to 20, or shown at least 50 times with a click rate under 1%, are written again with their best searches.';
comment on column program_settings.gsc_rewrite_daily_max is 'Search Console (2640): the most pages queued for a rewrite a day; the writer''s own daily limits still apply.';
comment on column program_settings.gsc_inspect_daily_max is 'Search Console (2640): the most written pages with no impressions inspected a day with the URL Inspection API.';

-- ================================================================ the connection and what Search Console says
create table app.gsc_link (
  id              boolean primary key default true check (id),
  status          text not null default 'not_connected' check (status in ('not_connected', 'connected', 'error')),
  account_email   text,
  property        text check (property is null or length(property) <= 300),
  connected_at    timestamptz,
  connected_by    uuid references users (id) on delete set null,
  last_attempt_at timestamptz,
  last_sync_at    timestamptz,
  last_sync_day   date,
  last_error      text,
  last_error_at   timestamptz,
  window_start    date,
  window_end      date,
  clicks          bigint not null default 0 check (clicks >= 0),
  impressions     bigint not null default 0 check (impressions >= 0),
  ctr             numeric,
  position        numeric,
  sitemap_path    text,
  sitemap_at      timestamptz,
  sitemap_error   text,
  inspected_last  integer not null default 0 check (inspected_last >= 0),
  updated_at      timestamptz not null default now()
);
insert into app.gsc_link (id) values (true);
comment on table app.gsc_link is 'Google Search Console (2640): the one connection, its last daily sync and the 28-day totals. The refresh token is in the vault (google_search_console_refresh_token).';
create index gsc_link_connected_by on app.gsc_link (connected_by);

create table app.gsc_page_totals (
  path         text primary key check (path ~ '^/[^ ]*$' and length(path) <= 500),
  clicks       integer not null default 0 check (clicks >= 0),
  impressions  integer not null default 0 check (impressions >= 0),
  ctr          numeric,
  position     numeric,
  window_start date not null,
  window_end   date not null,
  stored_at    timestamptz not null default now()
);
comment on table app.gsc_page_totals is 'Search Analytics by page over the last 28 days (2640), replaced by each daily sync of the site.';

create table app.gsc_page_queries (
  page         text not null check (page ~ '^/[^ ]*$' and length(page) <= 500),
  query        text not null check (length(query) between 1 and 300),
  clicks       integer not null default 0 check (clicks >= 0),
  impressions  integer not null default 0 check (impressions >= 0),
  ctr          numeric,
  position     numeric,
  window_start date not null,
  window_end   date not null,
  stored_at    timestamptz not null default now(),
  primary key (page, query)
);
comment on table app.gsc_page_queries is 'Search Analytics by page and query over the last 28 days (2640), replaced by each daily sync of the site: what people searched when a page was shown.';
create index gsc_page_queries_query on app.gsc_page_queries (query);

create table app.gsc_rewrite_queue (
  id          bigint generated always as identity primary key,
  kind        text not null check (kind in ('page', 'article')),
  ref         text not null check (length(ref) between 1 and 200),
  path        text not null check (path ~ '^/[^ ]*$' and length(path) <= 500),
  reason      text not null check (reason in ('position', 'low_ctr')),
  clicks      integer not null default 0 check (clicks >= 0),
  impressions integer not null default 0 check (impressions >= 0),
  ctr         numeric,
  position    numeric,
  queries     jsonb not null default '[]'::jsonb check (jsonb_typeof(queries) = 'array'),
  status      text not null default 'queued' check (status in ('queued', 'written', 'dropped')),
  queued_at   timestamptz not null default now(),
  queued_day  date not null,
  done_at     timestamptz
);
comment on table app.gsc_rewrite_queue is 'Pages sent to the copy queue because of Search Console (2640): why (position 8 to 20, or shown a lot and clicked little), the figures then, and the best searches handed to the writer.';
create index gsc_rewrite_queue_ref on app.gsc_rewrite_queue (kind, ref, queued_at desc);
create index gsc_rewrite_queue_day on app.gsc_rewrite_queue (queued_day);

do $$
declare t text;
begin
  foreach t in array array['gsc_link', 'gsc_page_totals', 'gsc_page_queries', 'gsc_rewrite_queue'] loop
    execute format('alter table app.%I enable row level security', t);
    execute format('revoke all on app.%I from public, anon, authenticated', t);
    execute format('grant all on app.%I to service_role', t);
  end loop;
end $$;

-- ================================================================ the token (the vault)
create function app.gsc_token_set(p_token text) returns void
language plpgsql security definer set search_path = public, app as $$
declare v_id uuid;
begin
  if to_regnamespace('vault') is null then
    if p_token is null then return; end if;
    raise exception 'The vault is not available on this database' using errcode = '55000';
  end if;
  execute 'select id from vault.secrets where name = $1' into v_id using 'google_search_console_refresh_token';
  if p_token is null then
    if v_id is not null then execute 'delete from vault.secrets where id = $1' using v_id; end if;
  elsif v_id is null then
    execute 'select vault.create_secret($1, $2, $3)' using p_token, 'google_search_console_refresh_token', 'Google Search Console for the daily SEO sync, 2640';
  else
    execute 'select vault.update_secret($1, $2)' using v_id, p_token;
  end if;
end $$;

create function app.gsc_token() returns text
language plpgsql stable security definer set search_path = public, app as $$
declare v text;
begin
  if to_regnamespace('vault') is null then return null; end if;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1' into v using 'google_search_console_refresh_token';
  return v;
end $$;

-- ================================================================ the card (Marketing > SEO)
create function app.gsc_card(p_read_only boolean default true, p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'status', l.status, 'account_email', case when p_read_only then null else l.account_email end, 'property', l.property,
    'connected_at', l.connected_at, 'last_sync_at', l.last_sync_at, 'last_error', l.last_error, 'last_error_at', l.last_error_at,
    'sync_on', ps.gsc_sync_on, 'rewrite_on', ps.gsc_rewrite_on, 'rewrite_daily_max', ps.gsc_rewrite_daily_max,
    'totals', case when l.last_sync_at is null then null else jsonb_build_object('clicks', l.clicks, 'impressions', l.impressions, 'ctr', l.ctr, 'position', l.position,
                'window_start', l.window_start, 'window_end', l.window_end) end,
    'sitemap', jsonb_build_object('path', l.sitemap_path, 'at', l.sitemap_at, 'error', l.sitemap_error),
    'inspected_last', l.inspected_last,
    'top_queries', coalesce((select jsonb_agg(jsonb_build_object('key', q.query, 'clicks', q.c, 'impressions', q.i, 'ctr', case when q.i > 0 then round(q.c::numeric / q.i, 4) end, 'position', q.pos)
                               order by q.c desc, q.i desc, q.query)
        from (select query, sum(clicks) c, sum(impressions) i, round(sum(position * impressions) / nullif(sum(impressions), 0), 1) pos
                from app.gsc_page_queries group by query order by sum(clicks) desc, sum(impressions) desc, query limit 10) q), '[]'::jsonb),
    'queued', coalesce((select jsonb_agg(jsonb_build_object('path', r.path, 'kind', r.kind, 'reason', r.reason, 'status', r.status, 'queued_at', r.queued_at, 'done_at', r.done_at,
                                 'impressions', r.impressions, 'ctr', r.ctr, 'position', r.position,
                                 'queries', coalesce((select jsonb_agg(e ->> 'query') from (select e from jsonb_array_elements(r.queries) e limit 3) t), '[]'::jsonb)) order by r.queued_at desc, r.id desc)
        from (select * from app.gsc_rewrite_queue where queued_at > p_now - interval '28 days' order by queued_at desc, id desc limit 20) r), '[]'::jsonb),
    'queued_waiting', (select count(*) from app.gsc_rewrite_queue where status = 'queued'))
    from app.gsc_link l, app.settings(app.local_date(p_now)) ps
$$;

alter function app.seo_data(timestamptz, boolean) rename to seo_data_pre2640;
create function app.seo_data(p_now timestamptz default now(), p_read_only boolean default false) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.seo_data_pre2640(p_now, p_read_only) || jsonb_build_object('gsc', app.gsc_card(p_read_only, p_now))
$$;
select pg_temp.copy_grants('app.seo_data(timestamptz, boolean)'::regprocedure, 'app.seo_data_pre2640(timestamptz, boolean)'::regprocedure);

-- ================================================================ connect and disconnect (an Admin)
create function app.gsc_connect(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_admin);
  if nullif(p ->> 'refresh_token', '') is null then raise exception 'Google sent no refresh token: connect again and allow offline access' using errcode = '22023'; end if;
  perform app.gsc_token_set(p ->> 'refresh_token');
  -- the first sync is due at once: the next five-minute tick runs it
  update app.gsc_link set status = 'connected', account_email = nullif(btrim(coalesce(p ->> 'email', '')), ''), connected_at = now(), connected_by = p_admin,
         property = null, last_error = null, last_error_at = null, last_attempt_at = null, last_sync_day = null, updated_at = now() where id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_admin, 'gsc_connect', 'gsc_link', 'true', jsonb_build_object('status', 'connected'));
  return app.gsc_card(false);
end $$;

create function app.gsc_disconnect(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_admin);
  perform app.gsc_token_set(null);
  update app.gsc_link set status = 'not_connected', account_email = null, connected_at = null, connected_by = null, last_error = null, last_error_at = null,
         last_attempt_at = null, updated_at = now() where id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_admin, 'gsc_disconnect', 'gsc_link', 'true', jsonb_build_object('status', 'not_connected'));
  return app.gsc_card(false);
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2640;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'admin_do' and p_name in ('gsc_connect', 'gsc_disconnect') then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'gsc_connect' then app.gsc_connect(p_user, coalesce(p, '{}'::jsonb)) else app.gsc_disconnect(p_user, coalesce(p, '{}'::jsonb)) end;
  end if;
  return app.door_pre2640(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2640(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ the daily sync
-- due: connected, on, not done today (Toronto), and not tried in the last hour (a failed run is tried again hourly)
create function app.gsc_sync_due(p_now timestamptz default now()) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((select l.status = 'connected' and (app.settings(app.local_date(p_now))).gsc_sync_on
                          and l.last_sync_day is distinct from app.local_date(p_now)
                          and (l.last_attempt_at is null or l.last_attempt_at < p_now - interval '1 hour')
                     from app.gsc_link l), false)
$$;

-- The job begins: one caller gets the token (the attempt is stamped, so a second tick in the same hour gets nothing),
-- with the written pages of the site, the least recently inspected first, for the URL inspections.
create function public.server_gsc_sync_begin() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare ps program_settings := app.settings(); v_ok boolean;
begin
  if not app.gsc_sync_due() then
    return jsonb_build_object('due', false, 'connected', coalesce((select status = 'connected' from app.gsc_link), false));
  end if;
  update app.gsc_link set last_attempt_at = now(), updated_at = now()
   where id and status = 'connected' and (last_attempt_at is null or last_attempt_at < now() - interval '1 hour') returning true into v_ok;
  if not coalesce(v_ok, false) then return jsonb_build_object('due', false, 'connected', true); end if;
  return jsonb_build_object('due', true, 'connected', true, 'refresh_token', app.gsc_token(), 'property', (select property from app.gsc_link),
    'inspect_max', ps.gsc_inspect_daily_max, 'rewrite_on', ps.gsc_rewrite_on,
    'pages', coalesce((select jsonb_agg(x.path order by x.seen nulls first, x.path)
        from (select w.path, u.inspected_at seen
                from (select '/car-rental/' || p.slug path from seo_pages p where p.is_active
                      union all select '/guides/' || a.slug from articles a where a.is_published
                      union all select '/cars/' || vl.slug from vehicle_listings vl where vl.status = 'published' and vl.slug is not null) w
                left join app.gsc_url_inspection u on u.path = w.path
               where w.path ~ '^/[a-z0-9/._-]*$' and (u.inspected_at is null or u.inspected_at < now() - interval '14 days')
               order by u.inspected_at nulls first, w.path limit 400) x), '[]'::jsonb));
end $$;

-- p: the candidates [{path, reason, clicks, impressions, ctr, position, queries [{query, clicks, impressions, position}]}],
-- the most shown first. A landing page or a guide that is live and not already waiting is set to pending (what "Write
-- again" does), within the day's limit, and not again for 28 days.
create function app.gsc_rewrite_enqueue(p jsonb, p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  v_day date := app.local_date(p_now);
  v_room integer;
  v_n integer := 0;
  x jsonb; v_path text; v_kind text; v_ref text; v_queries jsonb;
begin
  if not ps.gsc_rewrite_on or jsonb_typeof(p) is distinct from 'array' then return 0; end if;
  v_room := ps.gsc_rewrite_daily_max - (select count(*) from app.gsc_rewrite_queue where queued_day = v_day);
  for x in select e from jsonb_array_elements(p) with ordinality t(e, n) order by n limit 200 loop
    exit when v_room <= 0;
    v_path := x ->> 'path';
    if (x ->> 'reason') not in ('position', 'low_ctr') or v_path is null then continue; end if;
    if v_path ~ '^/car-rental/[a-z0-9]+(-[a-z0-9]+)*$' then
      v_kind := 'page'; v_ref := substr(v_path, 13);
      continue when not exists (select 1 from seo_pages where slug = v_ref and is_active and status = 'published');
    elsif v_path ~ '^/guides/[a-z0-9]+(-[a-z0-9]+)*$' then
      v_kind := 'article'; v_ref := substr(v_path, 9);
      continue when not exists (select 1 from articles where slug = v_ref and is_published and status = 'published');
    else
      continue;
    end if;
    continue when exists (select 1 from app.gsc_rewrite_queue q where q.kind = v_kind and q.ref = v_ref and q.queued_at > p_now - interval '28 days');
    -- the searches, cleaned again here: only letters, digits and plain punctuation ever reach the writer
    v_queries := coalesce((select jsonb_agg(jsonb_build_object('query', t.q, 'clicks', t.c, 'impressions', t.i, 'position', t.pos) order by t.n)
        from (select btrim(regexp_replace(regexp_replace(left(lower(e ->> 'query'), 80), '[^[:alnum:] ''&.+-]', ' ', 'g'), '\s+', ' ', 'g')) q, n,
                     greatest(coalesce((e ->> 'clicks')::numeric, 0), 0)::int c, greatest(coalesce((e ->> 'impressions')::numeric, 0), 0)::int i, nullif(e ->> 'position', '')::numeric pos
                from jsonb_array_elements(case when jsonb_typeof(x -> 'queries') = 'array' then x -> 'queries' else '[]'::jsonb end) with ordinality u(e, n) where n <= 8) t
       where length(t.q) >= 3), '[]'::jsonb);
    insert into app.gsc_rewrite_queue (kind, ref, path, reason, clicks, impressions, ctr, position, queries, queued_at, queued_day)
    values (v_kind, v_ref, v_path, x ->> 'reason', greatest(coalesce((x ->> 'clicks')::numeric, 0), 0)::int, greatest(coalesce((x ->> 'impressions')::numeric, 0), 0)::int,
            nullif(x ->> 'ctr', '')::numeric, nullif(x ->> 'position', '')::numeric, v_queries, p_now, v_day);
    if v_kind = 'page' then update seo_pages set status = 'pending', next_attempt_at = p_now, attempts = 0 where slug = v_ref;
    else update articles set status = 'pending', next_attempt_at = p_now, attempts = 0 where slug = v_ref; end if;
    v_room := v_room - 1; v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- The job ends. p: ok, and either error (and reconnect: Google no longer accepts the connection) or property,
-- window_start, window_end, totals {clicks, impressions, ctr, position}, pages [{path, clicks, impressions, ctr,
-- position}], rows [{path, query, ...}], candidates, inspected [{path, state, bucket, sitemap, last_crawl}],
-- sitemap {path, ok, error}, warning.
create function public.server_gsc_sync_finish(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_start date; v_end date; v_pages integer := 0; v_rows integer := 0; v_queued integer := 0; v_inspected integer := 0;
begin
  if not coalesce((p ->> 'ok')::boolean, false) then
    update app.gsc_link set last_error = left(coalesce(nullif(p ->> 'error', ''), 'The Search Console sync failed'), 300), last_error_at = now(),
           status = case when coalesce((p ->> 'reconnect')::boolean, false) and status = 'connected' then 'error' else status end, updated_at = now() where id;
    return jsonb_build_object('ok', false);
  end if;
  if not exists (select 1 from app.gsc_link where status = 'connected') then return jsonb_build_object('ok', false, 'reason', 'not connected'); end if;
  v_start := nullif(p ->> 'window_start', '')::date; v_end := nullif(p ->> 'window_end', '')::date;
  if v_start is null or v_end is null or v_end < v_start then raise exception 'The sync names no date range' using errcode = '22023'; end if;

  delete from app.gsc_page_totals where true;
  insert into app.gsc_page_totals (path, clicks, impressions, ctr, position, window_start, window_end)
  select x ->> 'path', greatest(coalesce((x ->> 'clicks')::numeric, 0), 0)::int, greatest(coalesce((x ->> 'impressions')::numeric, 0), 0)::int,
         nullif(x ->> 'ctr', '')::numeric, nullif(x ->> 'position', '')::numeric, v_start, v_end
    from jsonb_array_elements(case when jsonb_typeof(p -> 'pages') = 'array' then p -> 'pages' else '[]'::jsonb end) x
   where (x ->> 'path') ~ '^/[^ ]*$' and length(x ->> 'path') <= 500
  on conflict (path) do nothing;
  get diagnostics v_pages = row_count;

  delete from app.gsc_page_queries where true;
  insert into app.gsc_page_queries (page, query, clicks, impressions, ctr, position, window_start, window_end)
  select x ->> 'path', left(x ->> 'query', 300), greatest(coalesce((x ->> 'clicks')::numeric, 0), 0)::int, greatest(coalesce((x ->> 'impressions')::numeric, 0), 0)::int,
         nullif(x ->> 'ctr', '')::numeric, nullif(x ->> 'position', '')::numeric, v_start, v_end
    from jsonb_array_elements(case when jsonb_typeof(p -> 'rows') = 'array' then p -> 'rows' else '[]'::jsonb end) x
   where (x ->> 'path') ~ '^/[^ ]*$' and length(x ->> 'path') <= 500 and coalesce(x ->> 'query', '') <> ''
  on conflict (page, query) do nothing;
  get diagnostics v_rows = row_count;

  if jsonb_typeof(p -> 'inspected') = 'array' and jsonb_array_length(p -> 'inspected') > 0 then
    v_inspected := coalesce((app.gsc_urls_store(p -> 'inspected') ->> 'stored')::int, 0);
  end if;

  -- a queued page that is published again was written (by the site's writer or by the batch); one that waited two weeks is let go
  update app.gsc_rewrite_queue q set status = 'written', done_at = now()
   where q.status = 'queued' and ((q.kind = 'page' and exists (select 1 from seo_pages s where s.slug = q.ref and s.status = 'published'))
                               or (q.kind = 'article' and exists (select 1 from articles a where a.slug = q.ref and a.status = 'published')));
  update app.gsc_rewrite_queue set status = 'dropped', done_at = now() where status = 'queued' and queued_at < now() - interval '14 days';
  v_queued := app.gsc_rewrite_enqueue(p -> 'candidates');
  delete from app.gsc_rewrite_queue where queued_at < now() - interval '400 days';

  update app.gsc_link set property = left(nullif(p ->> 'property', ''), 300), last_sync_at = now(), last_sync_day = app.today(),
         window_start = v_start, window_end = v_end,
         clicks = greatest(coalesce((p #>> '{totals,clicks}')::numeric, 0), 0)::bigint, impressions = greatest(coalesce((p #>> '{totals,impressions}')::numeric, 0), 0)::bigint,
         ctr = nullif(p #>> '{totals,ctr}', '')::numeric, position = nullif(p #>> '{totals,position}', '')::numeric,
         sitemap_path = left(nullif(p #>> '{sitemap,path}', ''), 300),
         sitemap_at = case when coalesce((p #>> '{sitemap,ok}')::boolean, false) then now() else sitemap_at end,
         sitemap_error = case when coalesce((p #>> '{sitemap,ok}')::boolean, false) then null else left(nullif(p #>> '{sitemap,error}', ''), 300) end,
         inspected_last = v_inspected,
         last_error = left(nullif(p ->> 'warning', ''), 300), last_error_at = case when nullif(p ->> 'warning', '') is null then null else now() end,
         updated_at = now() where id;
  return jsonb_build_object('ok', true, 'pages', v_pages, 'rows', v_rows, 'queued', v_queued, 'inspected', v_inspected);
end $$;

-- the five-minute tick runs the job only when the day's sync is due
alter function app.server_jobs_due() rename to server_jobs_due_pre2640;
create function app.server_jobs_due() returns jsonb
language plpgsql volatile security definer set search_path = public, app as $$
declare v jsonb := app.server_jobs_due_pre2640();
begin
  return v || jsonb_build_object('gsc', app.gsc_sync_due());
end $$;
select pg_temp.copy_grants('app.server_jobs_due()'::regprocedure, 'app.server_jobs_due_pre2640()'::regprocedure);

-- ================================================================ the writer reads the searches
-- a claimed landing page or guide that Search Console queued carries its best searches (queries) to the prompt
create function app.gsc_claim_queries(c jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare k text;
begin
  if not exists (select 1 from app.gsc_rewrite_queue where status = 'queued') then return c; end if;
  foreach k in array array['pages', 'articles'] loop
    if jsonb_typeof(c -> k) = 'array' and jsonb_array_length(c -> k) > 0 then
      c := jsonb_set(c, array[k], (select jsonb_agg(case when q.queries is null then e.x else e.x || jsonb_build_object('queries', q.queries) end order by e.n)
          from jsonb_array_elements(c -> k) with ordinality e(x, n)
          left join lateral (select coalesce((select jsonb_agg(s ->> 'query') from jsonb_array_elements(r.queries) s), '[]'::jsonb) queries from app.gsc_rewrite_queue r
                              where r.kind = case k when 'pages' then 'page' else 'article' end and r.ref = e.x ->> 'slug' and r.status = 'queued'
                              order by r.queued_at desc limit 1) q on true));
    end if;
  end loop;
  return c;
end $$;

alter function app.server_seo_claim(text, integer) rename to server_seo_claim_pre2640;
create function app.server_seo_claim(p_worker text, p_limit integer default 3) returns jsonb
language sql security definer set search_path = public, app as $$
  select app.gsc_claim_queries(app.server_seo_claim_pre2640(p_worker, p_limit))
$$;
select pg_temp.copy_grants('app.server_seo_claim(text, integer)'::regprocedure, 'app.server_seo_claim_pre2640(text, integer)'::regprocedure);

alter function app.server_seo_result(jsonb) rename to server_seo_result_pre2640;
create function app.server_seo_result(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb := app.server_seo_result_pre2640(p);
begin
  if coalesce((p ->> 'ok')::boolean, false) and (p ->> 'kind') in ('page', 'article') then
    update app.gsc_rewrite_queue set status = 'written', done_at = now() where kind = p ->> 'kind' and ref = p ->> 'id' and status = 'queued';
  end if;
  return v;
end $$;
select pg_temp.copy_grants('app.server_seo_result(jsonb)'::regprocedure, 'app.server_seo_result_pre2640(jsonb)'::regprocedure);

-- ================================================================ grants: the server only
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['gsc_token_set', 'gsc_token', 'gsc_card', 'gsc_connect', 'gsc_disconnect', 'gsc_sync_due', 'gsc_rewrite_enqueue', 'gsc_claim_queries',
              'seo_data_pre2640', 'door_pre2640', 'server_jobs_due_pre2640', 'server_seo_claim_pre2640', 'server_seo_result_pre2640']))
        or (n.nspname = 'public' and p.proname = any (array['server_gsc_sync_begin', 'server_gsc_sync_finish']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
