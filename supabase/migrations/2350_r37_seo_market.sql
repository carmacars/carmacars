-- 2350_r37_seo_market.sql
-- Release 37, SEO gap fix (the owner: "fix the SEO", "I want Search Console to be insane").
--   A. The place pages keep to our market. Every region of the United States and Mexico had its place pages switched on
--      (0095: "all are on by default"), so crawlers fetched hundreds of thousands of pages for small US towns and Mexican
--      cities (toddsville-ny, villa-del-mar-ciudad-del-carmen-cam) that we never serve: each a render, many answered 503
--      under crawler load. The existing switch (place_regions.is_enabled, Admin > Settings > Search) is set off for the
--      US and Mexico: their place pages answer 404 (public.place_hub returns null: app.place_enabled) and leave every
--      sitemap, the place directory and the place roots. Canada stays on, Ontario first (sort order). An Admin can
--      switch any region back on.
--   B. The Worker's five-minute tick learns whether any region outside Canada is on (place_foreign): while none is,
--      the Worker answers a US or Mexican place address 404 at the edge, before the app loads (no render, no database).
--   C. The place sitemap index lists only the files that hold pages (the place directory's stored pages, 0115), not
--      one file per 25,000 ids up to the last place: no empty sitemap files for the regions switched off.
--   D. Languages: a string added or changed in the last seo_i18n_grace_days days (Program setting, 7) does not count
--      against a language's coverage until the seo-i18n workflow has had the time to translate it. Before this, a
--      release that added 8 strings (r37: 37 to 45) dropped every language below 90% and noindexed its existing pages
--      until the workflow ran. A page still shows English for its own missing strings and is noindex while any of
--      them is missing (web/src/features/i18n/route.tsx).
-- No applied migration is edited: functions are wrapped or replaced with the same signature.
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

-- ================================================================ A. the market
do $$
declare n integer;
begin
  select count(*) into n from place_regions where country in ('US', 'MX') and is_enabled;
  update place_regions set is_enabled = false where country in ('US', 'MX') and is_enabled;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (null, 'place_market_canada', 'place_regions', 'US,MX', jsonb_build_object('regions_switched_off', n,
          'places', (select count(*) from places p join place_regions r on r.id = p.region_id where r.country in ('US', 'MX') and p.is_active)));
end $$;
alter table place_regions alter column is_enabled set default false;
comment on column place_regions.is_enabled is 'Pages and sitemaps for this region''s places (Admin > Settings > Search). 2350: Canada on, the United States and Mexico off (our market); a new region starts off.';

-- ================================================================ B. the Worker's tick
create or replace function app.place_foreign_on() returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from place_regions where is_enabled and country <> 'CA')
$$;
revoke all on function app.place_foreign_on() from public, anon, authenticated;
grant execute on function app.place_foreign_on() to service_role;

alter function app.server_jobs_due() rename to server_jobs_due_pre2350;
create function app.server_jobs_due() returns jsonb
language plpgsql volatile security definer set search_path = public, app as $$
declare v jsonb := app.server_jobs_due_pre2350();
begin
  return v || jsonb_build_object('place_foreign', app.place_foreign_on());
end $$;
select pg_temp.copy_grants('app.server_jobs_due()'::regprocedure, 'app.server_jobs_due_pre2350()'::regprocedure);

-- ================================================================ C. place sitemap files that hold pages
alter function public.place_sitemap_files() rename to place_sitemap_files_pre2350;
create function public.place_sitemap_files() returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := public.place_sitemap_files_pre2350();
  n integer := (select place_sitemap_file_urls from app.settings());
  pages integer[];
begin
  -- the directory's stored pages (1,000 ids each, enabled places only, refreshed hourly); before its first refresh, all
  select array_agg(distinct g) into pages
    from app.place_directory_cache c,
         lateral (values (((c.page - 1) * 1000) / n + 1), ((c.page * 1000 - 1) / n + 1)) x(g);
  if pages is null then return v; end if;
  return coalesce((select jsonb_agg(f order by f ->> 'vertical', f ->> 'term', (f ->> 'page')::integer)
                     from jsonb_array_elements(v) f where (f ->> 'page')::integer = any (pages)), '[]'::jsonb);
end $$;
select pg_temp.copy_grants('public.place_sitemap_files()'::regprocedure, 'public.place_sitemap_files_pre2350()'::regprocedure);
revoke all on function public.place_sitemap_files_pre2350() from public, anon, authenticated;

-- ================================================================ D. languages: a grace for new strings
alter table program_settings add column seo_i18n_grace_days integer not null default 7 check (seo_i18n_grace_days between 0 and 90);
comment on column program_settings.seo_i18n_grace_days is 'Languages (2350): a template string added or changed within this many days does not count against a language''s coverage until it is translated (a release never noindexes the language pages already indexed). The page that uses it stays noindex until it is translated.';

create or replace function public.seo_languages_state() returns jsonb
language sql stable security definer set search_path = public, app as $$
  with s as materialized (select seo_i18n_min_coverage_bps bps, seo_i18n_grace_days grace from app.settings()),
  x as (select key, hash, updated_at > now() - make_interval(days => (select grace from s)) fresh from seo_string_sources),
  n as (select count(*) total from x),
  c as (select s.lang, count(*) done from seo_strings s join x on x.key = s.key and x.hash = s.source_hash group by s.lang),
  -- the fresh strings a language still lacks: left out of its count until the grace ends
  f as (select l.code lang, count(*) fresh from seo_languages l join x on x.fresh
         where not exists (select 1 from seo_strings s where s.lang = l.code and s.key = x.key and s.source_hash = x.hash) group by l.code)
  select coalesce(jsonb_agg(jsonb_build_object('code', l.code, 'name', l.name, 'native_name', l.native_name, 'hreflang', l.hreflang, 'dir', l.dir,
           'coverage_bps', case when n.total > 0 then (coalesce(c.done, 0) * 10000 / n.total)::integer else 0 end,
           'ready', n.total - coalesce(f.fresh, 0) > 0
                    and coalesce(c.done, 0) * 10000 >= (n.total - coalesce(f.fresh, 0)) * (select bps from s)) order by l.sort_order), '[]'::jsonb)
    from seo_languages l cross join n left join c on c.lang = l.code left join f on f.lang = l.code where l.is_active
$$;

-- ================================================================ E. the queries within reach (ranking 5 to 30)
-- The SEO page (Marketing > SEO, Sales > SEO) lists the queries Google shows the site for at an average position between
-- seo_striking_min_pos and seo_striking_max_pos (Program settings, 5 and 30) with at least seo_low_ctr_min_impressions
-- impressions in 28 days, by impressions: the pages to tune (title, description, the answer on the page, links from home).
alter table program_settings
  add column seo_striking_min_pos numeric(5, 1) not null default 5 check (seo_striking_min_pos >= 1),
  add column seo_striking_max_pos numeric(5, 1) not null default 30 check (seo_striking_max_pos >= 1);
alter table program_settings add constraint program_settings_seo_striking_range check (seo_striking_min_pos <= seo_striking_max_pos);
comment on column program_settings.seo_striking_min_pos is 'SEO (2350): the best average position of a query listed as within reach on the SEO page (5).';
comment on column program_settings.seo_striking_max_pos is 'SEO (2350): the worst average position of a query listed as within reach on the SEO page (30).';

alter function app.seo_data(timestamptz, boolean) rename to seo_data_pre2350;
create function app.seo_data(p_now timestamptz default now(), p_read_only boolean default false) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.seo_data_pre2350(p_now, p_read_only);
  ps program_settings := app.settings(app.local_date(p_now));
begin
  return v || jsonb_build_object(
    'striking', coalesce((select jsonb_agg(jsonb_build_object('key', key, 'clicks', clicks, 'impressions', impressions, 'ctr', ctr, 'position', position) order by impressions desc, key)
        from (select * from app.gsc_page_query where kind = 'query' and impressions >= ps.seo_low_ctr_min_impressions
                 and position between ps.seo_striking_min_pos and ps.seo_striking_max_pos
               order by impressions desc, key limit 25) x), '[]'::jsonb),
    'striking_line', jsonb_build_object('min_pos', ps.seo_striking_min_pos, 'max_pos', ps.seo_striking_max_pos, 'min_impressions', ps.seo_low_ctr_min_impressions));
end $$;
select pg_temp.copy_grants('app.seo_data(timestamptz, boolean)'::regprocedure, 'app.seo_data_pre2350(timestamptz, boolean)'::regprocedure);
revoke all on function app.seo_data_pre2350(timestamptz, boolean) from public, anon, authenticated;

-- ================================================================ F. r37's vehicle language check: granted by name, not to PUBLIC
-- (2302 granted it to anon, authenticated and service_role but left PUBLIC's default execute; the security suite names it)
revoke all on function public.vehicle_language_ok(text) from public;
grant execute on function public.vehicle_language_ok(text) to anon, authenticated, service_role;
