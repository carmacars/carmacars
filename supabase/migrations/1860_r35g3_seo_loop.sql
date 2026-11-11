-- 1860_r35g3_seo_loop.sql
-- Release 35, gaps round 3 (owner messages 3874, 3742, 3351, 2463, 2614).
--   A. The SEO action loop on the Search Console sync (the gsc workflow, web/scripts/gsc-search.mjs, gsc-pages.mjs):
--      per-query and per-page Search Analytics (28-day window), the URL Inspection state of the pages inspected, with the
--      sitemap that listed each; an Admin page (Marketing > SEO) and a read-only staff page (Sales > SEO) with the goal
--      tracker (Program settings seo_click_goal, 5,000,000 clicks a month), the best queries and pages, the pages shown
--      a lot and clicked little (seo_low_ctr_pct, seo_low_ctr_min_impressions) and the crawled / discovered-not-indexed
--      counts by sitemap; IndexNow is told about every inspected page that is not indexed, again after 1, 2, 4 ... days
--      (a backoff, at most 30 days); a weekly owner digest through the email outbox at the lowest priority, so the day's
--      email limit and the providers' budgets apply (Program settings seo_digest_on).
--   B. Cached-only serving by usage: when the month's Worker requests or CPU time reach usage_cached_pct (Program
--      settings, 70) of the allowance, the vehicle and SEO pages are served from the edge copy only (long
--      stale-while-revalidate, no database read). It ends by itself below the line or when the month turns.
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
  add column seo_click_goal bigint not null default 5000000 check (seo_click_goal > 0),
  add column seo_low_ctr_pct numeric(5, 2) not null default 1.0 check (seo_low_ctr_pct > 0 and seo_low_ctr_pct <= 100),
  add column seo_low_ctr_min_impressions integer not null default 100 check (seo_low_ctr_min_impressions >= 1),
  add column seo_digest_on boolean not null default true,
  add column usage_cached_pct integer not null default 70 check (usage_cached_pct between 1 and 100),
  add column usage_cached_since timestamptz;
comment on column program_settings.seo_click_goal is 'SEO (1860): the goal in Google clicks a month, shown on Marketing > SEO and in the weekly digest.';
comment on column program_settings.seo_low_ctr_pct is 'SEO (1860): a page with at least seo_low_ctr_min_impressions impressions in 28 days and a click rate below this percent is listed as shown a lot and clicked little.';
comment on column program_settings.seo_low_ctr_min_impressions is 'SEO (1860): the fewest impressions in 28 days for a page to count as shown a lot.';
comment on column program_settings.seo_digest_on is 'SEO (1860): the weekly SEO digest email to the alert address (uptime_alert_email), Monday morning.';
comment on column program_settings.usage_cached_pct is 'Usage (1860): from this share of the month''s Worker requests or CPU time allowance, vehicle and SEO pages are served from the edge copy only (no database read) until the share falls below it or the month turns.';
comment on column program_settings.usage_cached_since is 'Usage (1860): when cached-only serving by usage began (set by the check; empty while off).';

-- ================================================================ A. what Search Console says
create table if not exists app.gsc_page_query (
  kind        text not null check (kind in ('query', 'page')),
  key         text not null check (length(key) between 1 and 2000),
  clicks      integer not null default 0 check (clicks >= 0),
  impressions integer not null default 0 check (impressions >= 0),
  ctr         numeric,
  position    numeric,
  window_end  date not null,
  stored_at   timestamptz not null default now(),
  primary key (kind, key)
);
comment on table app.gsc_page_query is 'Search Analytics by query and by page over the last 28 days (1860), replaced by each gsc run: the top rows of each, by clicks, and the pages with most impressions.';
alter table app.gsc_page_query enable row level security;
revoke all on app.gsc_page_query from public, anon, authenticated;
grant all on app.gsc_page_query to service_role;
create index if not exists gsc_page_query_rank on app.gsc_page_query (kind, clicks desc, impressions desc);

create table if not exists app.gsc_url_inspection (
  path           text primary key check (path ~ '^/[^ ]*$'),
  state          text not null,
  bucket         text not null check (bucket in ('indexed', 'crawled', 'discovered', 'unknown', 'other')),
  sitemap        text,
  last_crawl     timestamptz,
  inspected_at   timestamptz not null default now(),
  pings          integer not null default 0 check (pings >= 0),
  next_ping_at   timestamptz
);
comment on table app.gsc_url_inspection is 'The pages inspected with the URL Inspection API (1860): their coverage state and the sitemap that listed them. A page that is not indexed is sent to IndexNow again after 1, 2, 4 ... days (pings, next_ping_at; at most 30 days).';
alter table app.gsc_url_inspection enable row level security;
revoke all on app.gsc_url_inspection from public, anon, authenticated;
grant all on app.gsc_url_inspection to service_role;
create index if not exists gsc_url_inspection_bucket on app.gsc_url_inspection (bucket, sitemap);

-- the workflow's rows: [{kind, key, clicks, impressions, ctr, position}] with the window's last day; replaces the kind's rows
create function app.gsc_pages_store(p jsonb) returns integer
language plpgsql security definer set search_path = public, app as $$
declare n integer := 0; v_end date := coalesce(nullif(p ->> 'window_end', '')::date, app.today()); k text;
begin
  for k in select distinct x ->> 'kind' from jsonb_array_elements(coalesce(p -> 'rows', '[]'::jsonb)) x where (x ->> 'kind') in ('query', 'page') loop
    delete from app.gsc_page_query where kind = k;
    insert into app.gsc_page_query (kind, key, clicks, impressions, ctr, position, window_end)
    select k, left(x ->> 'key', 2000), greatest(coalesce((x ->> 'clicks')::numeric, 0), 0)::int, greatest(coalesce((x ->> 'impressions')::numeric, 0), 0)::int,
           nullif(x ->> 'ctr', '')::numeric, nullif(x ->> 'position', '')::numeric, v_end
      from jsonb_array_elements(p -> 'rows') x where (x ->> 'kind') = k and coalesce(x ->> 'key', '') <> ''
    on conflict (kind, key) do nothing;
    n := n + (select count(*) from app.gsc_page_query where kind = k);
  end loop;
  return n;
end $$;

-- the inspected pages: [{path, state, bucket, sitemap, last_crawl}]; a page that is not indexed goes to IndexNow now and
-- again after 1, 2, 4 ... days; an indexed one leaves the schedule
create function app.gsc_urls_store(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare r record; v_n integer := 0; v_q integer := 0; v_on boolean := coalesce((app.settings()).indexnow_enabled, false);
begin
  for r in select x ->> 'path' path, coalesce(nullif(x ->> 'state', ''), 'Unknown') state,
                  case when (x ->> 'bucket') in ('indexed', 'crawled', 'discovered', 'unknown', 'other') then x ->> 'bucket' else 'other' end bucket,
                  nullif(left(x ->> 'sitemap', 300), '') sitemap, nullif(x ->> 'last_crawl', '')::timestamptz last_crawl
             from jsonb_array_elements(coalesce(case when jsonb_typeof(p) = 'array' then p else p -> 'urls' end, '[]'::jsonb)) x
            where (x ->> 'path') ~ '^/[a-z0-9/._-]*$' and length(x ->> 'path') <= 500 loop
    insert into app.gsc_url_inspection as u (path, state, bucket, sitemap, last_crawl) values (r.path, r.state, r.bucket, r.sitemap, r.last_crawl)
    on conflict (path) do update set state = excluded.state, bucket = excluded.bucket, sitemap = coalesce(excluded.sitemap, u.sitemap),
                                     last_crawl = excluded.last_crawl, inspected_at = now(),
                                     pings = case when excluded.bucket = 'indexed' then 0 else u.pings end,
                                     next_ping_at = case when excluded.bucket = 'indexed' then null else u.next_ping_at end;
    v_n := v_n + 1;
    if r.bucket <> 'indexed' and v_on then
      update app.gsc_url_inspection u set pings = u.pings + 1, next_ping_at = now() + least(interval '30 days', interval '1 day' * power(2, least(u.pings, 5)))
       where u.path = r.path and (u.next_ping_at is null or u.next_ping_at <= now());
      if found then perform app.indexnow_queue_path(r.path, 'not indexed'); v_q := v_q + 1; end if;
    end if;
  end loop;
  delete from app.gsc_url_inspection where inspected_at < now() - interval '120 days';
  return jsonb_build_object('stored', v_n, 'indexnow_queued', v_q);
end $$;
revoke all on function app.gsc_pages_store(jsonb), app.gsc_urls_store(jsonb) from public, anon, authenticated;
grant execute on function app.gsc_pages_store(jsonb), app.gsc_urls_store(jsonb) to service_role;

-- who may read the SEO page: an Admin, or sales staff (read only)
create function app.seo_assert_reader(p_user uuid) returns void
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_user is null or not (app.user_is_admin(p_user) or app.user_va_has(p_user, 'sales')) then
    raise exception 'Only an Admin or sales staff may read this' using errcode = '42501';
  end if;
end $$;

create function app.seo_data(p_now timestamptz default now(), p_read_only boolean default false) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  v_last date := (select max(day) from app.gsc_search_daily where impressions > 0 or clicks > 0);
  c28 bigint := 0; i28 bigint := 0; v_month bigint := 0; v_cov app.gsc_coverage_log;
begin
  if v_last is not null then
    select coalesce(sum(clicks), 0), coalesce(sum(impressions), 0) into c28, i28 from app.gsc_search_daily where day > v_last - 28 and day <= v_last;
    select coalesce(sum(clicks), 0) into v_month from app.gsc_search_daily where day >= date_trunc('month', v_last)::date and day <= v_last;
  end if;
  select * into v_cov from app.gsc_coverage_log order by at desc limit 1;
  return jsonb_build_object(
    'goal', jsonb_build_object('target', ps.seo_click_goal, 'clicks_28d', c28, 'impressions_28d', i28, 'month_to_date', v_month, 'last_day', v_last,
      'pace_30d', round(c28 * 30.0 / 28), 'share_bps', case when ps.seo_click_goal > 0 then least(round(c28 * 30.0 / 28 * 10000 / ps.seo_click_goal), 99999) else 0 end),
    'weeks', coalesce((select jsonb_agg(w order by w ->> 'week') from (
        select jsonb_build_object('week', d.wk, 'clicks', d.c, 'impressions', d.i) w
          from (select date_trunc('week', day)::date wk, sum(clicks) c, sum(impressions) i from app.gsc_search_daily
                 where day > coalesce(v_last, app.today()) - 84 group by 1 order by 1 desc limit 12) d) x), '[]'::jsonb),
    'top_queries', coalesce((select jsonb_agg(jsonb_build_object('key', key, 'clicks', clicks, 'impressions', impressions, 'ctr', ctr, 'position', position))
        from (select * from app.gsc_page_query where kind = 'query' order by clicks desc, impressions desc limit 25) q), '[]'::jsonb),
    'top_pages', coalesce((select jsonb_agg(jsonb_build_object('key', key, 'clicks', clicks, 'impressions', impressions, 'ctr', ctr, 'position', position))
        from (select * from app.gsc_page_query where kind = 'page' order by clicks desc, impressions desc limit 25) q), '[]'::jsonb),
    'low_ctr', coalesce((select jsonb_agg(jsonb_build_object('key', key, 'clicks', clicks, 'impressions', impressions, 'ctr', ctr, 'position', position))
        from (select * from app.gsc_page_query where kind = 'page' and impressions >= ps.seo_low_ctr_min_impressions
                 and coalesce(ctr, case when impressions > 0 then clicks::numeric / impressions else 0 end) * 100 < ps.seo_low_ctr_pct
               order by impressions desc limit 25) q), '[]'::jsonb),
    'low_ctr_line', jsonb_build_object('pct', ps.seo_low_ctr_pct, 'min_impressions', ps.seo_low_ctr_min_impressions),
    'by_sitemap', coalesce((select jsonb_agg(jsonb_build_object('sitemap', sm, 'inspected', n, 'indexed', i, 'crawled', c, 'discovered', d, 'unknown', u) order by (c + d) desc, n desc)
        from (select coalesce(sitemap, '(not named)') sm, count(*) n, count(*) filter (where bucket = 'indexed') i, count(*) filter (where bucket = 'crawled') c,
                     count(*) filter (where bucket = 'discovered') d, count(*) filter (where bucket = 'unknown') u
                from app.gsc_url_inspection group by 1 order by count(*) filter (where bucket in ('crawled', 'discovered')) desc, count(*) desc limit 30) s), '[]'::jsonb),
    'coverage', case when v_cov.id is null then null else jsonb_build_object('at', v_cov.at, 'inspected', v_cov.inspected, 'buckets', app.gsc_coverage_buckets(v_cov)) end,
    'indexnow', jsonb_build_object('waiting', (select count(*) from indexnow_queue where sent_at is null and attempts < 5),
      'sent_7d', (select count(*) from indexnow_queue where sent_at > p_now - interval '7 days'),
      'not_indexed_scheduled', (select count(*) from app.gsc_url_inspection where bucket <> 'indexed' and next_ping_at is not null)),
    'digest', jsonb_build_object('on', ps.seo_digest_on),
    'read_only', p_read_only);
end $$;
create function app.seo_actions(p_user uuid, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.seo_assert_reader(p_user);
  return app.seo_data(p_now, not app.user_is_admin(p_user));
end $$;
create function public.server_seo_actions(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.seo_actions(p_user) $$;
revoke all on function app.seo_assert_reader(uuid), app.seo_data(timestamptz, boolean), app.seo_actions(uuid, timestamptz), public.server_seo_actions(uuid) from public, anon, authenticated;
grant execute on function app.seo_assert_reader(uuid), app.seo_data(timestamptz, boolean), app.seo_actions(uuid, timestamptz), public.server_seo_actions(uuid) to service_role;

-- ---------------------------------------------------------------- the weekly owner digest, through the outbox
insert into notification_link_paths (key, path) values ('admin_seo', '/admin/marketing/seo') on conflict (key) do nothing;
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('staff_seo_digest', 'staff_admin', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Search this week: {{clicks_28d}} clicks in 28 days, {{goal_share}} of the monthly goal', '{{indexed_line}}', 'Monday morning', 'Scheduled (the hourly usage job, migration 1860): every Monday morning, Toronto time, to the alert address in Program settings (uptime_alert_email) while Program settings "SEO digest" is on. It goes through the email outbox like every email, at the lowest priority, so the day''s email limit and the providers'' budgets apply and it waits for the next day when the limit is used. Search Console clicks against the monthly goal, the best queries and pages, and the pages Google shows but nobody clicks.', null, '/admin/marketing/seo', '[{"name":"clicks_28d","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"goal","type":"string"},{"name":"goal_line","type":"string"},{"name":"goal_share","type":"string"},{"name":"impressions_28d","type":"string"},{"name":"indexed_line","type":"string"},{"name":"indexnow_line","type":"string"},{"name":"low_ctr","type":"list","fields":["key","impressions","ctr"]},{"name":"top_queries","type":"list","fields":["key","clicks","position"]}]'::jsonb, 'templates/staff_seo_digest.html', 'templates/staff_seo_digest.txt')
on conflict (code) do update set
  audience = excluded.audience, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing, trigger_text = excluded.trigger_text,
  link_path = excluded.link_path, variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();

-- Monday from 07:00 Toronto time, once a week (the dedupe key is the week), to the alert address; priority 5 so it is the
-- first to wait when the day's limit is used (outbox_claim). Nothing is queued while the email limit for the day is used.
create function app.seo_digest_enqueue(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  v_to text := lower(btrim(coalesce(ps.uptime_alert_email, '')));
  v_day date := app.local_date(p_now);
  v_key text := 'seo_digest:' || date_trunc('week', v_day)::date;
  d jsonb; g jsonb; v_pace jsonb := app.email_pace(p_now); v_cov jsonb; v_idx text;
begin
  if not ps.seo_digest_on or v_to = '' or v_to !~ '^[^@ ]+@[^@ ]+$' then return 0; end if;
  if extract(isodow from v_day) <> 1 or app.local_hour(p_now) < 7 then return 0; end if;
  if exists (select 1 from notification_outbox where dedupe_key = v_key) then return 0; end if;
  if coalesce((v_pace ->> 'day_used')::int, 0) >= coalesce((v_pace ->> 'day_cap')::int, 0) then return 0; end if;
  if not exists (select 1 from app.gsc_search_daily where clicks > 0 or impressions > 0) then return 0; end if;
  d := app.seo_data(p_now, true);
  g := d -> 'goal';
  v_cov := d -> 'coverage' -> 'buckets';
  v_idx := case when v_cov is null then 'No index sample yet'
    else format('%s of the sampled pages Google knows are indexed; %s crawled, not indexed; %s discovered, not indexed',
         coalesce(round(100.0 * (v_cov ->> 'indexed')::numeric / nullif((v_cov ->> 'indexed')::numeric + (v_cov ->> 'crawled')::numeric + (v_cov ->> 'discovered')::numeric + coalesce((v_cov ->> 'other')::numeric, 0), 0))::text || '%', 'n/a'),
         v_cov ->> 'crawled', v_cov ->> 'discovered') end;
  insert into notification_outbox (code, category, priority, audience, to_address, to_name, entity, payload, missing_variables, dedupe_key, status, send_after)
  values ('staff_seo_digest', 'transactional', 5, 'staff_admin', v_to, 'CarmaCars', 'seo_digest',
    jsonb_build_object(
      'clicks_28d', to_char((g ->> 'clicks_28d')::bigint, 'FM999,999,999,990'), 'impressions_28d', to_char((g ->> 'impressions_28d')::bigint, 'FM999,999,999,990'),
      'goal', to_char((g ->> 'target')::bigint, 'FM999,999,999,990'), 'goal_share', round((g ->> 'share_bps')::numeric / 100) || '%',
      'goal_line', format('At this pace the month brings about %s clicks, %s%% of the %s goal.', to_char((g ->> 'pace_30d')::bigint, 'FM999,999,999,990'),
                          round((g ->> 'share_bps')::numeric / 100), to_char((g ->> 'target')::bigint, 'FM999,999,999,990')),
      'indexed_line', v_idx,
      'indexnow_line', format('%s addresses sent in 7 days, %s waiting', d #>> '{indexnow,sent_7d}', d #>> '{indexnow,waiting}'),
      'top_queries', coalesce((select jsonb_agg(jsonb_build_object('key', x ->> 'key', 'clicks', to_char((x ->> 'clicks')::bigint, 'FM999,999,990'), 'position', round((x ->> 'position')::numeric, 1)::text))
                                 from (select x from jsonb_array_elements(d -> 'top_queries') x limit 8) t), '[]'::jsonb),
      'low_ctr', coalesce((select jsonb_agg(jsonb_build_object('key', x ->> 'key', 'impressions', to_char((x ->> 'impressions')::bigint, 'FM999,999,990'),
                                 'ctr', round(coalesce((x ->> 'ctr')::numeric, 0) * 100, 1)::text || '%'))
                                 from (select x from jsonb_array_elements(d -> 'low_ctr') x limit 8) t), '[]'::jsonb)),
    '{}'::text[], v_key, 'queued', p_now)
  on conflict (dedupe_key) do nothing;
  return 1;
end $$;
revoke all on function app.seo_digest_enqueue(timestamptz) from public, anon, authenticated;
grant execute on function app.seo_digest_enqueue(timestamptz) to service_role;

-- ================================================================ B. cached-only serving by usage
-- true from usage_cached_pct of the month's Worker requests or CPU time allowance; the share is the month's own, so it
-- falls to nothing when the month turns. Changes are written once to the audit log.
create function app.usage_cached_share(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce((select jsonb_build_object('service', s ->> 'service', 'label', s ->> 'label', 'share_bps', (s ->> 'share_bps')::int, 'used_text', s ->> 'used_text', 'included_text', s ->> 'included_text')
                     from (select app.usage_state(sv, p_now) s from unnest(array['workers_requests', 'workers_cpu']) sv) q
                    order by (s ->> 'share_bps')::int desc limit 1), jsonb_build_object('share_bps', 0))
$$;

create function app.usage_cached_check(p_now timestamptz default now()) returns boolean
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  m jsonb := app.usage_cached_share(p_now);
  v_on boolean := (m ->> 'share_bps')::int >= ps.usage_cached_pct * 100;
begin
  if v_on and ps.usage_cached_since is null then
    update program_settings set usage_cached_since = p_now where id = ps.id;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (null, 'usage_cached_on', 'program_settings', ps.id::text, jsonb_build_object('usage', m, 'line_pct', ps.usage_cached_pct));
  elsif not v_on and ps.usage_cached_since is not null then
    update program_settings set usage_cached_since = null where id = ps.id;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (null, 'usage_cached_off', 'program_settings', ps.id::text, jsonb_build_object('usage', m, 'line_pct', ps.usage_cached_pct));
  end if;
  return v_on;
end $$;
revoke all on function app.usage_cached_share(timestamptz), app.usage_cached_check(timestamptz) from public, anon, authenticated;
grant execute on function app.usage_cached_share(timestamptz), app.usage_cached_check(timestamptz) to service_role;

-- the Worker's five-minute tick says it (custom-worker.ts writes the flag the fetch handler reads)
alter function app.server_jobs_due() rename to server_jobs_due_pre1860;
create function app.server_jobs_due() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb := app.server_jobs_due_pre1860();
begin
  return v || jsonb_build_object('cached_only', app.usage_cached_check());
end $$;
select pg_temp.copy_grants('app.server_jobs_due()'::regprocedure, 'app.server_jobs_due_pre1860()'::regprocedure);

-- the hourly usage job also checks it and queues the digest
alter function app.job_usage_refresh(timestamptz) rename to job_usage_refresh_pre1860;
create function app.job_usage_refresh(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb := app.job_usage_refresh_pre1860(p_now);
begin
  perform app.usage_cached_check(p_now);
  perform app.seo_digest_enqueue(p_now);
  return coalesce(v, '{}'::jsonb) || jsonb_build_object('cached_only', (select usage_cached_since is not null from program_settings limit 1));
end $$;
select pg_temp.copy_grants('app.job_usage_refresh(timestamptz)'::regprocedure, 'app.job_usage_refresh_pre1860(timestamptz)'::regprocedure);

-- Settings > Usage shows the state
alter function app.usage_page(uuid, timestamptz) rename to usage_page_pre1860;
create function app.usage_page(p_user uuid, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.usage_page_pre1860(p_user, p_now);
  ps program_settings := app.settings(app.local_date(p_now));
  m jsonb := app.usage_cached_share(p_now);
begin
  return v || jsonb_build_object('cached_only', jsonb_build_object('on', ps.usage_cached_since is not null, 'since', ps.usage_cached_since, 'line_pct', ps.usage_cached_pct,
    'service', m ->> 'service', 'label', m ->> 'label', 'share_bps', (m ->> 'share_bps')::int, 'used_text', m ->> 'used_text', 'included_text', m ->> 'included_text',
    'resets_at', (date_trunc('month', p_now at time zone 'America/Toronto') + interval '1 month') at time zone 'America/Toronto'));
end $$;
select pg_temp.copy_grants('app.usage_page(uuid, timestamptz)'::regprocedure, 'app.usage_page_pre1860(uuid, timestamptz)'::regprocedure);
