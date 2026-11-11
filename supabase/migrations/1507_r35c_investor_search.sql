-- 1507_r35c_investor_search.sql
-- Release 35, part C (item 6): the investor deck shows the site's Search Console traction: clicks, impressions, indexed
-- pages and the growth week by week. Never the fleet's size, its utilisation, the Protection Plan or any cost.
--   * The gsc workflow (.github/workflows/gsc.yml, web/scripts/gsc-search.mjs) now also reads Search Console's
--     Search Analytics by day (the last 90 days; Google's figures settle after about 3 days) into app.gsc_search_daily.
--   * Indexed pages: Search Console's Pages report has no API, so the figure is the one an Admin types from it (Admin >
--     Investors > Deck, kept on the day) when it is recent (30 days); otherwise an estimate from the gsc workflow's
--     coverage sample (the share indexed of the pages Google knows, times the addresses the sitemaps gave Google),
--     labelled as an estimate.
--   * investor_read 'deck_search' (an investor while the deck is shown, an Admin always).
-- No applied migration is edited: app.door is wrapped.
set local check_function_bodies = off;

create table if not exists app.gsc_search_daily (
  day           date primary key,
  clicks        integer not null default 0 check (clicks >= 0),
  impressions   integer not null default 0 check (impressions >= 0),
  ctr           numeric,
  position      numeric,
  indexed_pages integer check (indexed_pages >= 0),
  indexed_by    uuid references users (id),
  stored_at     timestamptz not null default now()
);
comment on table app.gsc_search_daily is 'Search Console by day (1507): clicks, impressions, CTR and average position from the Search Analytics API (the gsc workflow), and the indexed pages an Admin typed from the Pages report (no API). Kept 2 years.';
alter table app.gsc_search_daily enable row level security;
revoke all on app.gsc_search_daily from public, anon, authenticated;
grant all on app.gsc_search_daily to service_role;

-- the workflow's rows: [{day, clicks, impressions, ctr, position}]
create or replace function app.gsc_search_store(p jsonb) returns integer
language plpgsql security definer set search_path = public, app as $$
declare n integer;
begin
  with r as (select (x ->> 'day')::date d, greatest(coalesce((x ->> 'clicks')::numeric, 0), 0)::int c, greatest(coalesce((x ->> 'impressions')::numeric, 0), 0)::int i,
                    nullif(x ->> 'ctr', '')::numeric ctr, nullif(x ->> 'position', '')::numeric pos
               from jsonb_array_elements(case when jsonb_typeof(p) = 'array' then p else coalesce(p -> 'rows', '[]'::jsonb) end) x
              where (x ->> 'day') ~ '^\d{4}-\d{2}-\d{2}$')
  insert into app.gsc_search_daily (day, clicks, impressions, ctr, position)
  select d, c, i, ctr, pos from r
  on conflict (day) do update set clicks = excluded.clicks, impressions = excluded.impressions, ctr = excluded.ctr, position = excluded.position, stored_at = now();
  get diagnostics n = row_count;
  delete from app.gsc_search_daily where day < current_date - 730;
  return n;
end $$;
revoke all on function app.gsc_search_store(jsonb) from public, anon, authenticated;
grant execute on function app.gsc_search_store(jsonb) to service_role;

-- the indexed pages typed by an Admin from Search Console's Pages report
create function app.deck_search_indexed(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v integer := nullif(regexp_replace(coalesce(p ->> 'indexed_pages', ''), '[^0-9]', '', 'g'), '')::integer;
begin
  perform app.assert_admin(p_by);
  if v is null then raise exception 'Type the indexed pages Search Console shows (Indexing > Pages)' using errcode = '22023'; end if;
  insert into app.gsc_search_daily (day, indexed_pages, indexed_by) values (app.today(), v, p_by)
  on conflict (day) do update set indexed_pages = excluded.indexed_pages, indexed_by = p_by;
  return jsonb_build_object('day', app.today(), 'indexed_pages', v);
end $$;

-- the deck's figures: the last 28 days against the 28 before, the weekly trend (12 weeks), the indexed pages
create function app.deck_search(p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_last date := (select max(day) from app.gsc_search_daily where impressions > 0 or clicks > 0);
  c1 bigint; i1 bigint; c0 bigint; i0 bigint;
  v_idx record;
  v_est numeric;
  cov app.gsc_coverage_log;
  b jsonb;
begin
  if v_last is not null then
    select coalesce(sum(clicks), 0), coalesce(sum(impressions), 0) into c1, i1 from app.gsc_search_daily where day > v_last - 28 and day <= v_last;
    select coalesce(sum(clicks), 0), coalesce(sum(impressions), 0) into c0, i0 from app.gsc_search_daily where day > v_last - 56 and day <= v_last - 28;
  end if;
  select day, indexed_pages into v_idx from app.gsc_search_daily where indexed_pages is not null and day > app.local_date(p_now) - 30 order by day desc limit 1;
  if v_idx.day is null then
    select * into cov from app.gsc_coverage_log order by at desc limit 1;
    if cov.id is not null then
      b := app.gsc_coverage_buckets(cov);
      v_est := case when coalesce((b ->> 'indexed')::numeric, 0) + coalesce((b ->> 'crawled')::numeric, 0) + coalesce((b ->> 'discovered')::numeric, 0) + coalesce((b ->> 'other')::numeric, 0) > 0
                    then (b ->> 'indexed')::numeric / ((b ->> 'indexed')::numeric + coalesce((b ->> 'crawled')::numeric, 0) + coalesce((b ->> 'discovered')::numeric, 0) + coalesce((b ->> 'other')::numeric, 0))
                         * coalesce((select sum(submitted) from app.gsc_sitemap_latest where not coalesce(is_index, false)), 0) end;
    end if;
  end if;
  return jsonb_build_object('as_of', v_last,
    'clicks_28d', c1, 'impressions_28d', i1, 'clicks_prev_28d', c0, 'impressions_prev_28d', i0,
    'clicks_growth_pct', case when c0 > 0 then round(100.0 * (c1 - c0) / c0) end, 'impressions_growth_pct', case when i0 > 0 then round(100.0 * (i1 - i0) / i0) end,
    'indexed_pages', coalesce(v_idx.indexed_pages, round(v_est)::bigint), 'indexed_estimate', v_idx.day is null and v_est is not null, 'indexed_on', v_idx.day,
    'weeks', coalesce((select jsonb_agg(jsonb_build_object('week_of', w, 'clicks', c, 'impressions', i) order by w)
                         from (select (date_trunc('week', day::timestamp))::date w, sum(clicks) c, sum(impressions) i from app.gsc_search_daily
                                where v_last is not null and day > v_last - 84 and day <= v_last group by 1) x), '[]'::jsonb));
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1507;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call in ('investor_read', 'admin_read') and p_name = 'deck_search') or (p_call = 'admin_do' and p_name = 'deck_search_indexed') then
    perform app.door_begin(p_user, p_aal);
    if p_name = 'deck_search_indexed' then return app.deck_search_indexed(p_user, coalesce(p, '{}'::jsonb)); end if;
    if not app.user_is_admin(p_user) then
      perform app.investor_of(p_user);
      if not coalesce((select show_to_investors from deck_settings limit 1), false) then raise exception 'The investor deck is not available yet' using errcode = '42501'; end if;
    end if;
    return app.deck_search(now());
  end if;
  return app.door_pre1507(p_user, p_aal, p_call, p_name, p);
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['deck_search_indexed', 'deck_search', 'door_pre1507', 'door'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
