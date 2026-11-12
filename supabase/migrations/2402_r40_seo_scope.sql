-- 2402_r40_seo_scope.sql
-- Release 40, SEO scope (the owner: "let's do cars from 2005 and newer. And let's turn off us and Mexico cities for now,
-- even other provinces. Don't delete them but just turn them off. Keep it to every neighborhood in Ontario. And don't make
-- individually different pages for every synonym of a service. Instead, have each group of a service as one page per
-- specific year make and model with all the synonyms listed on the page.").
--   A. Ontario only. Every place region but Ontario is switched off (place_regions.is_enabled; nothing is deleted): their
--      place pages answer 404 and leave every sitemap, the place directory and the place roots. Every Ontario place keeps its
--      pages, its cities, towns and neighbourhoods included. An Admin can switch a region back on (Admin > Settings > Search).
--   B. The edge knows the market. app.place_market_mask() is the set of regions that are on (a bit for each Canadian province
--      and territory, one for the United States, one for Mexico); the Worker's tick stores it and answers a place page of a
--      region that is off 404 before the app loads (web/src/lib/edge/scraper-guard.ts offMarketPlace), not only US and
--      Mexican ones. app.place_foreign_on() (the flag of the Worker before this release) now says whether any region but
--      Ontario is on, which keeps that Worker correct until the new one is deployed.
--   C. Cars from 2005 on. Program setting vpage_min_year (2005): a model year below it has no vehicle page in any tree
--      (/cars, /buy, /t/<term>, the language versions): its year, trim, place and colour pages answer 404 (the Worker answers
--      them at the edge from the tick's vpage_min_year), and it leaves every sitemap, IndexNow and every list of years and
--      models on the pages. A model with only older years and none of our cars has no page either. The stored sitemap shape
--      stamp (0119, 0123) counts the setting, so a change is read live until the job stores the shape again.
--   D. One page per service group. Terms with the same search intent become synonyms (place_terms.canonical_slug) of the
--      group's term; no term is deleted. A synonym's place pages and vehicle pages answer 301 with the group's page
--      (public.place_hub returns the redirect; the vehicle trees read the synonym map in public.vehicle_tiers), they are in
--      no sitemap and no vehicle tree, and the group's pages list them ("Also searched as: ..."). A synonym of a synonym
--      is pointed at the group's term (trigger), so a group is always one hop.
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

-- ================================================================ A. Ontario only
do $$
declare n integer;
begin
  select count(*) into n from place_regions where code <> 'CA-ON' and is_enabled;
  update place_regions set is_enabled = false where code <> 'CA-ON' and is_enabled;
  update place_regions set is_enabled = true where code = 'CA-ON' and not is_enabled;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (null, 'place_market_ontario', 'place_regions', 'all but CA-ON', jsonb_build_object('regions_switched_off', n,
          'ontario_places', (select count(*) from places p join place_regions r on r.id = p.region_id where r.code = 'CA-ON' and p.is_active)));
end $$;
comment on column place_regions.is_enabled is 'Pages and sitemaps for this region''s places (Admin > Settings > Search). 2402: Ontario on, every other province, state and territory off (our market); a new region starts off.';

-- the tier sitemaps span the place ids that can have pages: up to the last place of a region that is on (the Ontario
-- places are loaded first), not the last place of all (hundreds of thousands of empty US and Mexican ids)
create index if not exists places_region_max_idx on places (region_id, id);
create or replace function app.vpage_place_max() returns integer
language plpgsql stable security definer set search_path = public, app as $$
declare n integer;
begin
  if app.vpage_has('places') then
    execute $q$ select coalesce(greatest((select max(m.id) from place_regions r, lateral (select max(p.id) id from places p where p.region_id = r.id) m where r.is_enabled),
                                         (select max(p.id) from places p where p.kind = 1 and exists (select 1 from place_regions r where r.country = p.country and r.is_enabled))), 0) $q$ into n;
    return n;
  end if;
  return (select count(*) from app.vpage_landing_places());
end $$;

-- ================================================================ B. the edge knows the market
-- bits 0 to 12: the Canadian provinces and territories in this order; 13: any US region; 14: any Mexican region
create or replace function app.place_market_mask() returns integer
language sql stable security definer set search_path = public, app as $$
  select coalesce(sum(distinct case when r.country = 'CA' then 1 << (array_position(array['ON', 'QC', 'BC', 'AB', 'MB', 'SK', 'NS', 'NB', 'NL', 'PE', 'YT', 'NT', 'NU'], split_part(r.code, '-', 2)) - 1)
                                    when r.country = 'US' then 1 << 13 else 1 << 14 end), 0)::integer
    from place_regions r where r.is_enabled and (r.country <> 'CA' or split_part(r.code, '-', 2) = any (array['ON', 'QC', 'BC', 'AB', 'MB', 'SK', 'NS', 'NB', 'NL', 'PE', 'YT', 'NT', 'NU']))
$$;
revoke all on function app.place_market_mask() from public, anon, authenticated;
grant execute on function app.place_market_mask() to service_role;

-- the Worker of release 37 answers US and Mexican place pages 404 while this is false
create or replace function app.place_foreign_on() returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from place_regions where is_enabled and code <> 'CA-ON')
$$;

-- ================================================================ C. the setting
alter table program_settings add column vpage_min_year integer not null default 2005 check (vpage_min_year between 1900 and 2100);
comment on column program_settings.vpage_min_year is 'Vehicle pages (2402): the oldest model year with pages (2005). Older years answer 404 in every tree and leave the sitemaps and the lists of years.';

create or replace function app.vpage_settings_json(s program_settings) returns jsonb
language sql immutable as $$
  select jsonb_build_object('index_mode', s.vpage_index_mode, 'model_min_years', s.vpage_model_min_years, 'popular_from_year', s.vpage_popular_from_year,
    'year_min_cars', s.vpage_year_min_cars, 'trim_min_cars', s.vpage_trim_min_cars, 'gas_cents', s.vpage_gas_cents_per_litre,
    'premium_extra_cents', s.vpage_premium_extra_cents, 'elec_cents', s.vpage_electricity_cents_per_kwh,
    'place_index', s.vpage_place_index, 'colour_index', s.vpage_colour_index, 'term_index', s.vpage_term_index, 'buy_index', s.vpage_buy_index,
    'detailing_index', s.vpage_detailing_index, 'bodyshop_index', s.vpage_bodyshop_index, 'finance_disclaimer', s.vpage_finance_disclaimer,
    'min_year', s.vpage_min_year)
$$;

-- the Worker's tick: the market and the oldest model year, for the edge 404s
create or replace function app.server_jobs_due() returns jsonb
language plpgsql volatile security definer set search_path = public, app as $$
declare v jsonb := app.server_jobs_due_pre2350();
begin
  return v || jsonb_build_object('place_foreign', app.place_foreign_on(), 'place_market', app.place_market_mask(), 'vpage_min_year', (app.settings()).vpage_min_year);
end $$;

-- ================================================================ C. the years on the pages and in the sitemaps
create or replace function app.vpage_year_rows(p_make text, p_model text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('year', y.year, 'path', app.vpage_path(y.make_slug, y.model_slug, y.year), 'vclass', y.vclass,
           'powertrains', y.powertrains, 'l100_min', y.l100_min, 'l100_max', y.l100_max, 'kwh100_min', y.kwh100_min, 'ev_range_max', y.ev_range_max,
           'fuels', y.fuels, 'drives', y.drives,
           'engines', (select coalesce(jsonb_agg(distinct jsonb_build_object('displ', v -> 'displ', 'cyl', v -> 'cyl', 'turbo', v -> 'turbo', 'fuel', v ->> 'fuel')), '[]'::jsonb)
                         from jsonb_array_elements(y.variants) v),
           'trims', (select coalesce(jsonb_agg(jsonb_build_object('slug', t.slug, 'name', t.name) order by t.rank), '[]'::jsonb)
                       from vehicle_catalog_trims t where t.make_slug = y.make_slug and t.model_slug = y.model_slug and t.year = y.year))
         order by y.year desc), '[]'::jsonb)
    from vehicle_catalog_years y where y.make_slug = p_make and y.model_slug = p_model and y.year >= (app.settings()).vpage_min_year
$$;

-- the phrases of a group's synonyms ("Also searched as"), defined here for the page reads below (section D)
create or replace function app.place_term_also(p_slug text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(t.phrase order by t.sort_order, t.slug), '[]'::jsonb) from place_terms t where t.canonical_slug = p_slug and t.is_active and t.slug <> p_slug
$$;

alter function app.vehicle_year_page(text, text, integer) rename to vehicle_year_page_pre2402;
create function app.vehicle_year_page(p_make text, p_model text, p_year integer) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v jsonb; mn integer := (app.settings()).vpage_min_year;
begin
  if p_year is null or p_year < mn then return null; end if;
  v := app.vehicle_year_page_pre2402(p_make, p_model, p_year);
  if v is null then return null; end if;
  if (v -> 'prev' ->> 'year')::integer < mn then v := jsonb_set(v, '{prev}', 'null'::jsonb); end if;
  return v || jsonb_build_object('also', app.place_term_also('car-rental'));
end $$;
select pg_temp.copy_grants('app.vehicle_year_page(text, text, integer)'::regprocedure, 'app.vehicle_year_page_pre2402(text, text, integer)'::regprocedure);
revoke all on function app.vehicle_year_page_pre2402(text, text, integer) from public, anon, authenticated;

alter function app.vehicle_trim_page(text, text, integer, text) rename to vehicle_trim_page_pre2402;
create function app.vehicle_trim_page(p_make text, p_model text, p_year integer, p_trim text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v jsonb; mn integer := (app.settings()).vpage_min_year;
begin
  if p_year is null or p_year < mn then return null; end if;
  v := app.vehicle_trim_page_pre2402(p_make, p_model, p_year, p_trim);
  if v is null then return null; end if;
  if (v -> 'prev' ->> 'year')::integer < mn then v := jsonb_set(v, '{prev}', 'null'::jsonb); end if;
  v := jsonb_set(v, '{trim_years}', coalesce((select jsonb_agg(e order by n) from jsonb_array_elements(v -> 'trim_years') with ordinality x(e, n) where (e ->> 'year')::integer >= mn), '[]'::jsonb));
  return v || jsonb_build_object('also', app.place_term_also('car-rental'));
end $$;
select pg_temp.copy_grants('app.vehicle_trim_page(text, text, integer, text)'::regprocedure, 'app.vehicle_trim_page_pre2402(text, text, integer, text)'::regprocedure);
revoke all on function app.vehicle_trim_page_pre2402(text, text, integer, text) from public, anon, authenticated;

-- a model page lists only the years from vpage_min_year (vpage_year_rows); a catalog model with only older years and none of
-- our cars has no page
alter function app.vehicle_model_page(text, text) rename to vehicle_model_page_pre2402;
create function app.vehicle_model_page(p_make text, p_model text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v jsonb; mn integer := (app.settings()).vpage_min_year;
begin
  v := app.vehicle_model_page_pre2402(p_make, p_model);
  if v is null or v ? 'redirect' then return v; end if;
  if coalesce((v ->> 'in_catalog')::boolean, false) and jsonb_array_length(coalesce(v -> 'years', '[]'::jsonb)) = 0
     and coalesce((v -> 'inventory' ->> 'real_exact')::integer, 0) = 0
     and exists (select 1 from vehicle_catalog_years y where y.make_slug = v -> 'make' ->> 'slug' and y.model_slug = v -> 'model' ->> 'slug') then return null; end if;
  return v || jsonb_build_object('years_with_data', (select count(*) filter (where y.powertrains > 0) from vehicle_catalog_years y
                                                      where y.make_slug = v -> 'make' ->> 'slug' and y.model_slug = v -> 'model' ->> 'slug' and y.year >= mn),
                                 'also', app.place_term_also('car-rental'));
end $$;
select pg_temp.copy_grants('app.vehicle_model_page(text, text)'::regprocedure, 'app.vehicle_model_page_pre2402(text, text)'::regprocedure);
revoke all on function app.vehicle_model_page_pre2402(text, text) from public, anon, authenticated;

-- a make page lists the models with a year from vpage_min_year, their first year and year count from it
alter function app.vehicle_make_page(text) rename to vehicle_make_page_pre2402;
create function app.vehicle_make_page(p_make text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v jsonb; mn integer := (app.settings()).vpage_min_year;
begin
  v := app.vehicle_make_page_pre2402(p_make);
  if v is null then return null; end if;
  return v || jsonb_build_object('also', app.place_term_also('car-rental'),
    'models', coalesce((select jsonb_agg(e || jsonb_build_object('first_year', greatest((e ->> 'first_year')::integer, mn), 'years', y.n) order by x.n)
                          from jsonb_array_elements(v -> 'models') with ordinality x(e, n)
                          join lateral (select count(*) n from vehicle_catalog_years yy where yy.make_slug = v -> 'make' ->> 'slug' and yy.model_slug = e ->> 'slug' and yy.year >= mn) y on y.n > 0), '[]'::jsonb));
end $$;
select pg_temp.copy_grants('app.vehicle_make_page(text)'::regprocedure, 'app.vehicle_make_page_pre2402(text)'::regprocedure);
revoke all on function app.vehicle_make_page_pre2402(text) from public, anon, authenticated;

-- every address of the trees (the stored sitemaps, IndexNow): no year below vpage_min_year, no model with only older years
create or replace function app.vpage_all(p_make text default null) returns table (level text, make_slug text, path text, lastmod timestamptz, indexable boolean)
language sql stable security definer set search_path = public, app as $$
  with s as (select app.settings() s),
       mn as (select ((select s from s)).vpage_min_year y),
       cars as materialized (select c.make_slug, c.model_slug, c.year, c.trim_slug, c.content_updated_at from app.vpage_cars() c where not c.is_sample),
       ym as (select y.make_slug, y.model_slug, count(*) filter (where y.powertrains > 0 and y.year >= (select y from mn)) n,
                     count(*) filter (where y.year >= (select y from mn)) shown, max(y.updated_at) upd from vehicle_catalog_years y group by 1, 2)
  select 'make', mk.slug, app.vpage_path(mk.slug), greatest(mk.updated_at, (select max(c.content_updated_at) from cars c where c.make_slug = mk.slug)), true
    from vehicle_catalog_makes mk where p_make is null or mk.slug = p_make
  union all
  select 'model', m.make_slug, app.vpage_path(m.make_slug, m.slug), greatest(m.updated_at, ym.upd, x.upd),
         app.vpage_gate('model', coalesce(ym.n, 0)::integer, coalesce(x.n, 0)::integer, false, null, (select s from s))
    from vehicle_catalog_models m left join ym on ym.make_slug = m.make_slug and ym.model_slug = m.slug
    left join lateral (select count(*) n, max(c.content_updated_at) upd from cars c where c.make_slug = m.make_slug and c.model_slug = m.slug) x on true
   where (p_make is null or m.make_slug = p_make) and (ym.make_slug is null or ym.shown > 0 or x.n > 0)
  union all
  select 'year', y.make_slug, app.vpage_path(y.make_slug, y.model_slug, y.year), greatest(y.updated_at, x.upd),
         app.vpage_gate('year', 0, coalesce(x.n, 0)::integer, p.make_slug is not null, y.year, (select s from s))
    from vehicle_catalog_years y left join vehicle_catalog_popular p on p.make_slug = y.make_slug and p.model_slug = y.model_slug
    left join lateral (select count(*) n, max(c.content_updated_at) upd from cars c where c.make_slug = y.make_slug and c.model_slug = y.model_slug and c.year = y.year) x on true
   where (p_make is null or y.make_slug = p_make) and y.year >= (select y from mn)
  union all
  select 'trim', t.make_slug, app.vpage_path(t.make_slug, t.model_slug, t.year, t.slug), greatest(t.updated_at, x.upd),
         app.vpage_gate('trim', 0, coalesce(x.n, 0)::integer, false, t.year, (select s from s))
    from vehicle_catalog_trims t
    left join lateral (select count(*) n, max(c.content_updated_at) upd from cars c where c.make_slug = t.make_slug and c.model_slug = t.model_slug and c.year = t.year and c.trim_slug = t.slug) x on true
   where (p_make is null or t.make_slug = p_make) and t.year >= (select y from mn)
$$;

-- the trims of the place and colour sitemaps
create or replace function app.vpage_trim_indexed(p_from integer, p_to integer) returns table (ord integer, make_slug text, model_slug text, year smallint, slug text, lastmod timestamptz)
language sql stable security definer set search_path = public, app as $$
  with s as (select app.settings() s),
       cars as materialized (select c.make_slug, c.model_slug, c.year, c.trim_slug, c.content_updated_at from app.vpage_cars() c where not c.is_sample)
  select t.ord, t.make_slug, t.model_slug, t.year, t.slug, greatest(t.updated_at, x.upd)
    from vehicle_catalog_trims t
    left join lateral (select count(*) n, max(c.content_updated_at) upd from cars c where c.make_slug = t.make_slug and c.model_slug = t.model_slug and c.year = t.year and c.trim_slug = t.slug) x on true
   where t.ord > p_from and t.ord <= p_to and t.year >= ((select s from s)).vpage_min_year
     and app.vpage_gate('trim', 0, coalesce(x.n, 0)::integer, false, t.year, (select s from s))
   order by t.ord
$$;

-- the language versions (2302): only cars from vpage_min_year
create or replace function app.vehicle_language_paths() returns table (path text, lastmod timestamptz)
language sql stable security definer set search_path = public, app as $$
  with s as (select * from app.settings()),
  cars as (select c.make_slug, c.model_slug, c.year, c.trim_slug, vc.slug colour, coalesce(c.content_updated_at, c.first_published_at) m
             from app.vpage_cars() c join vehicles v on v.id = c.vehicle_id
             left join vehicle_colours vc on vc.slug = lower(btrim(coalesce(v.colour, '')))
            where not c.is_sample and c.trim_slug is not null and c.model_slug is not null and c.year is not null and c.year >= (select vpage_min_year from s)),
  base as (select app.vpage_path(make_slug, model_slug, year, trim_slug) p, colour, max(m) m from cars group by 1, 2),
  places as (select l.slug from app.vpage_landing_places() l, s where s.vpage_place_index
              order by nullif(l.facts ->> 'population', '')::numeric desc nulls last, l.slug limit (select seo_i18n_vehicle_places from s)),
  terms as (select t.slug from place_terms t, s where s.vpage_term_index and t.is_active and t.canonical_slug is null and t.served = 'yes'
               and (t.vertical = 'detailing' or t.slug ~ '(^|-)(dui|suspend|suspended|suspension|bad-driv|driving-record|bad-record)'))
  select x.path, max(x.m) from (
    select b.p path, b.m from base b
    union all select b.p || '/' || pl.slug, b.m from base b cross join places pl
    union all select b.p || '/' || pl.slug || '/' || b.colour, b.m from base b cross join places pl, s where b.colour is not null and s.vpage_colour_index
    union all select '/t/' || t.slug || substr(b.p, 6), b.m from base b cross join terms t) x
  group by x.path
$$;

-- renting vs owning (2003): no page and no sitemap row for a year below vpage_min_year
create or replace function public.sitemap_families() returns jsonb
language sql stable security definer set search_path = public, app as $$
  with s as (select (app.settings()).*),
  ev as (select '/events/' || slug path, updated_at lastmod from seo_events where is_active),
  ap as (select '/airport-car-rental/' || lower(code) path, updated_at lastmod from airports where is_active),
  pop as (select y.make_slug, y.model_slug, y.year::integer y from vehicle_catalog_popular p join vehicle_catalog_years y on y.make_slug = p.make_slug and y.model_slug = p.model_slug
           where y.year >= greatest(extract(year from now())::integer - 11, (select vpage_min_year from s))),
  cities as (select p.slug from places p, s where p.kind = 5 and app.place_enabled(p) and app.place_km(p) <= s.place_delivery_reach_km order by app.place_km(p) limit 20),
  rvo as (select '/rent-vs-own/' || make_slug || '/' || model_slug || '/' || y path, null::timestamptz lastmod from pop
          union all
          select '/rent-vs-own/' || make_slug || '/' || model_slug || '/' || y || '/' || c.slug, null from pop, cities c where pop.y >= extract(year from now())::integer - 2),
  hubs as (select x path, null::timestamptz lastmod from unnest(array['/events', '/airport-car-rental', '/rent-vs-own']) x
           union all select '/gps-tracker', null from s where s.tracker_product_enabled)
  select coalesce(jsonb_agg(jsonb_build_object('path', path, 'lastmod', lastmod)), '[]'::jsonb) from (select * from hubs union all select * from ev union all select * from ap union all select * from rvo limit 45000) a
$$;

alter function public.rent_vs_own_page(text, text, integer, text) rename to rent_vs_own_page_pre2402;
create function public.rent_vs_own_page(p_make text, p_model text, p_year integer, p_city text default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_year is null or p_year < (app.settings()).vpage_min_year then return null; end if;
  return public.rent_vs_own_page_pre2402(p_make, p_model, p_year, p_city);
end $$;
select pg_temp.copy_grants('public.rent_vs_own_page(text, text, integer, text)'::regprocedure, 'public.rent_vs_own_page_pre2402(text, text, integer, text)'::regprocedure);
revoke all on function public.rent_vs_own_page_pre2402(text, text, integer, text) from public, anon, authenticated;

-- ================================================================ D. one page per service group
-- a term's group: follow canonical_slug to the term that has the pages
create or replace function app.place_term_root(p_slug text) returns text
language sql stable security definer set search_path = public, app as $$
  with recursive c(slug, nxt, d) as (
    select t.slug, t.canonical_slug, 0 from place_terms t where t.slug = p_slug
    union all select t.slug, t.canonical_slug, c.d + 1 from c join place_terms t on t.slug = c.nxt where c.d < 8)
  select slug from c order by d desc limit 1
$$;

-- a synonym always points at its group's term, and a term that becomes a synonym takes its own synonyms with it
create or replace function app.place_terms_group_before() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.canonical_slug is not null then
    new.canonical_slug := coalesce(app.place_term_root(new.canonical_slug), new.canonical_slug);
    if new.canonical_slug = new.slug then raise exception 'A term cannot point to itself or to one of its own synonyms' using errcode = '22023'; end if;
  end if;
  return new;
end $$;
create or replace function app.place_terms_group_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.canonical_slug is not null then
    update place_terms set canonical_slug = new.canonical_slug where canonical_slug = new.slug and slug <> new.canonical_slug;
  end if;
  return null;
end $$;
revoke all on function app.place_term_root(text), app.place_term_also(text), app.place_terms_group_before(), app.place_terms_group_after() from public, anon, authenticated;
grant execute on function app.place_term_root(text), app.place_term_also(text), app.place_terms_group_before(), app.place_terms_group_after() to service_role;
create trigger place_terms_group_before before insert or update of canonical_slug on place_terms for each row execute function app.place_terms_group_before();
create trigger place_terms_group_after after update of canonical_slug on place_terms for each row when (new.canonical_slug is distinct from old.canonical_slug)
  execute function app.place_terms_group_after();

-- the groups: the same search intent is one page. Kept apart: interior and exterior detailing, ceramic coating, window tint,
-- PPF, wraps, financing, leasing, lease takeover, insurance replacement rental and each mechanical service.
do $$
declare n integer := 0; k integer;
begin
  update place_terms t set canonical_slug = g.root from (values
    -- renting
    ('car-rental', 'rent-a-car'), ('car-rental', 'car-hire'), ('car-rental', 'cars-for-hire'), ('car-rental', 'vehicle-rental'), ('car-rental', 'auto-rental'),
    ('car-rental', 'rental-cars'), ('car-rental', 'car-rental-near-me'),
    ('monthly-car-rental', 'long-term-car-rental'),
    ('insurance-replacement-rental', 'collision-replacement-car'),
    ('rental-car-while-car-is-in-the-shop', 'loaner-car'), ('rental-car-while-car-is-in-the-shop', 'courtesy-car'), ('rental-car-while-car-is-in-the-shop', 'replacement-car-rental'),
    ('dui-car-rental', 'car-rental-after-impaired-driving-conviction'),
    ('high-risk-driver-car-rental', 'car-rental-with-bad-driving-record'), ('high-risk-driver-car-rental', 'car-rental-with-demerit-points'),
    ('uber-rental-car', 'rideshare-car-rental'), ('uber-rental-car', 'lyft-rental-car'), ('uber-rental-car', 'hopp-car-rental'),
    ('uber-eats-car-rental', 'delivery-driver-car-rental'), ('uber-eats-car-rental', 'doordash-car-rental'), ('uber-eats-car-rental', 'skipthedishes-car-rental'),
    ('uber-eats-car-rental', 'instacart-car-rental'), ('uber-eats-car-rental', 'amazon-flex-car-rental'), ('uber-eats-car-rental', 'gig-driver-car-rental'),
    ('car-rental-under-25', 'car-rental-18-year-old'),
    ('new-driver-car-rental', 'g2-driver-car-rental'),
    ('newcomer-to-canada-car-rental', 'international-student-car-rental'), ('newcomer-to-canada-car-rental', 'international-licence-car-rental'),
    ('debit-card-car-rental', 'car-rental-no-credit-card'),
    ('chauffeur-service', 'car-with-driver'), ('chauffeur-service', 'car-service'),
    ('black-car-service', 'executive-car-service'),
    -- buying help
    ('cars-for-sale', 'buy-a-car'), ('used-cars', 'used-cars-for-sale'), ('car-financing', 'auto-loans'), ('car-leasing', 'lease-a-car'),
    -- detailing
    ('car-detailing', 'auto-detailing'), ('car-detailing', 'full-detail'), ('car-detailing', 'car-cleaning'),
    ('car-wash', 'hand-car-wash'),
    ('paint-correction', 'polishing'), ('paint-correction', 'buffing'),
    ('paint-protection-film', 'ppf'), ('paint-protection-film', 'clear-bra'),
    ('car-wrap', 'vinyl-wrap'),
    -- body shop
    ('collision-repair', 'auto-body-shop'), ('collision-repair', 'body-shop'), ('collision-repair', 'collision-centre'), ('collision-repair', 'collision-center'),
    ('collision-repair', 'accident-repair'), ('collision-repair', 'auto-body-repair'), ('collision-repair', 'car-body-repair'), ('collision-repair', 'insurance-claim-repair'),
    ('car-painting', 'auto-paint'),
    ('car-repair', 'auto-repair')
  ) g(root, member)
  where t.slug = g.member and t.canonical_slug is distinct from g.root
    and exists (select 1 from place_terms r where r.slug = g.root and r.vertical = t.vertical and r.canonical_slug is null);
  get diagnostics n = row_count;
  -- the synonyms made before (0115, 0121) point at their group's term (one hop)
  update place_terms t set canonical_slug = app.place_term_root(t.canonical_slug)
   where t.canonical_slug is not null and app.place_term_root(t.canonical_slug) is distinct from t.canonical_slug;
  get diagnostics k = row_count;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (null, 'place_term_groups', 'place_terms', 'r40', jsonb_build_object('grouped', n, 'repointed', k,
          'groups', (select count(*) from place_terms where canonical_slug is null and is_active), 'synonyms', (select count(*) from place_terms where canonical_slug is not null)));
end $$;

-- a synonym's place page answers 301 with its group's page; the group's page lists its synonyms; the rentals linked from a
-- page are groups only
alter function app.public_place_hub(text, text, text) rename to public_place_hub_pre2402;
create function app.public_place_hub(p_vertical text, p_term text, p_place text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare t place_terms; r place_terms; p places; v jsonb; v_to text;
begin
  select * into t from place_terms where slug = lower(btrim(p_term)) and vertical = p_vertical and is_active;
  if t.slug is not null and t.canonical_slug is not null then
    select * into r from place_terms where slug = app.place_term_root(t.slug) and is_active and canonical_slug is null;
    select * into p from places where slug = lower(btrim(p_place)) order by id limit 1;
    if r.slug is null or p.id is null or not app.place_enabled(p) then return null; end if;
    v_to := app.place_hub_path(r.vertical, r.slug, p.slug);
    return jsonb_build_object('redirect', v_to, 'path', app.place_hub_path(t.vertical, t.slug, p.slug),
                              'term', jsonb_build_object('slug', t.slug, 'vertical', t.vertical, 'canonical_path', v_to));
  end if;
  v := app.public_place_hub_pre2402(p_vertical, p_term, p_place);
  if v is null then return null; end if;
  v := jsonb_set(v, '{term,synonyms}', app.place_term_also(t.slug));
  -- the places linked from the page are places whose region is on (a country page lists Ontario, not the provinces that are off)
  v := v || jsonb_build_object(
    'children', coalesce((select jsonb_agg(e order by n) from jsonb_array_elements(v -> 'children') with ordinality x(e, n)
                           where exists (select 1 from places q where q.slug = e ->> 'slug' and app.place_enabled(q))), '[]'::jsonb),
    'nearby', coalesce((select jsonb_agg(e order by n) from jsonb_array_elements(v -> 'nearby') with ordinality x(e, n)
                           where exists (select 1 from places q where q.slug = e ->> 'slug' and app.place_enabled(q))), '[]'::jsonb),
    -- a country page says where we operate: its provinces that are on (Ontario)
    'operating', case when v -> 'place' ->> 'kind' = 'country' then
                   (select coalesce(jsonb_agg(app.place_brief(q) order by pr.sort_order, q.name), '[]'::jsonb)
                      from places q join place_regions pr on pr.id = q.region_id
                     where q.kind = 2 and q.is_active and pr.is_enabled and q.country = v -> 'place' ->> 'country') end);
  if jsonb_typeof(v -> 'gta_members') = 'array' then
    v := jsonb_set(v, '{gta_members}', coalesce((select jsonb_agg(e order by n) from jsonb_array_elements(v -> 'gta_members') with ordinality x(e, n)
                                                 where exists (select 1 from places q where q.slug = e ->> 'slug' and app.place_enabled(q))), '[]'::jsonb));
  end if;
  if jsonb_typeof(v -> 'rental_terms') = 'array' then
    v := jsonb_set(v, '{rental_terms}', coalesce((select jsonb_agg(e order by n) from jsonb_array_elements(v -> 'rental_terms') with ordinality x(e, n)
                                                  where not exists (select 1 from place_terms s where s.slug = e ->> 'slug' and s.canonical_slug is not null)), '[]'::jsonb));
  end if;
  return v;
end $$;
select pg_temp.copy_grants('app.public_place_hub(text, text, text)'::regprocedure, 'app.public_place_hub_pre2402(text, text, text)'::regprocedure);
revoke all on function app.public_place_hub_pre2402(text, text, text) from public, anon, authenticated;

-- the vehicle trees: each group term's synonyms ("also") and the synonym map the /t pages answer 301 with ('' is the
-- car rental group, whose tree is /cars)
create or replace function app.vpage_tiers() returns jsonb
language sql stable security definer set search_path = public, app as $$
  with terms as materialized (select * from app.vpage_terms())
  select jsonb_build_object(
    'settings', app.vpage_settings_json(app.settings()),
    'places', app.vpage_place_links(),
    'colours', (select coalesce(jsonb_agg(jsonb_build_object('slug', x.slug, 'name', x.name, 'hex', x.hex) order by x.sort), '[]'::jsonb) from vehicle_colours x),
    'terms', (select coalesce(jsonb_agg(jsonb_build_object('slug', t.slug, 'name', t.name, 'kind', t.kind, 'lead', t.lead, 'phrase', t.phrase, 'also', app.place_term_also(t.slug))
                                        order by t.kind, t.sort, t.slug), '[]'::jsonb) from terms t),
    'synonyms', (select coalesce(jsonb_object_agg(s.slug, case when s.canonical_slug = 'car-rental' then '' else s.canonical_slug end), '{}'::jsonb)
                   from place_terms s where s.is_active and s.canonical_slug is not null
                    and (s.canonical_slug = 'car-rental' or exists (select 1 from terms t where t.slug = s.canonical_slug))))
$$;

-- ================================================================ the stored shapes
-- 0119's stamp, with the oldest model year and the regions that are on (the place tier files span their places)
create or replace function app.vehicle_sitemap_switches() returns text
language sql stable security definer set search_path = public, app as $$
  select md5(coalesce((select string_agg(e.key || '=' || e.value::text, ',' order by e.key)
                         from jsonb_each(to_jsonb(app.settings())) e where e.key ~ '^vpage_(.*_index|index_mode|min_year)$'), '')
             || '|' || coalesce((select string_agg(t.prefix, ',') from app.vpage_trees() t), '')
             || '|' || coalesce((select string_agg(r.code, ',' order by r.code) from place_regions r where r.is_enabled), ''))
$$;

-- the place roots (/car-rental's provinces and countries) are kept an hour (app.place_roots_cache): a region switched on or
-- off refreshes them at once, so a region that is off is never listed
create or replace function app.place_regions_roots_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.place_roots_refresh();
  return null;
end $$;
revoke all on function app.place_regions_roots_after() from public, anon, authenticated;
grant execute on function app.place_regions_roots_after() to service_role;
create trigger place_regions_roots_after after update of is_enabled on place_regions for each statement execute function app.place_regions_roots_after();

-- stored now: the files without the older years, the trees without the synonyms, the place directory and roots with Ontario only
select app.place_roots_refresh();
select app.vehicle_sitemap_files_refresh();
select app.vehicle_sitemap_shape_refresh();
select app.place_directory_refresh();
select app.sitemap_priority_refresh();
