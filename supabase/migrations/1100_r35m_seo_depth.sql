-- 1100_r35m_seo_depth.sql
-- Release 35, part M (docs/changes/2026-11-08-r35-seo-depth.md): the programmatic pages made longer from real data.
-- The owner: keep every page, never prune or noindex, fill the empty ones; every sentence from the database or a value
-- computed for that page, never filler (web/src/features/seo/depth.ts).
--   1. Every page indexable: a landing page for a use no longer waits for 2 real matching cars (seo_page_indexable),
--      and the place pages' quality gate is gone (place_hub_indexable; place_quality_gate kept off and ignored). The
--      owner's own switches (a region, a tier) and the synonym rule (a synonym names its term's page as canonical) stay.
--   2. The content epoch: when the facts every page shows change (the Program settings and the fees behind the
--      Requirements section, the fuel prices behind the cost of 100 km) or a release changes the templates, every
--      page's lastmod moves (public.seo_content_epoch; the sitemaps take the later of a page's own date and it).
--   3. Sourced page data, loaded by the seo-data workflow (web/scripts/seo-data/*.mjs): vehicle_specs (one value per
--      model, year, trim and field, with its source and when it was fetched), vehicle_maintenance_costs (a cost
--      table by make and segment, with its assumptions and source) and place_pois (GO stations, transit stops and
--      hotels, with the source, its licence and the attribution to show). A value with no source is refused.
-- No applied migration is edited.

-- ================================================================ 1. every page indexable
create or replace function app.seo_page_indexable(p seo_pages) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p.is_active
$$;

create or replace function app.place_hub_indexable(p places, t place_terms, p_in_reach boolean, p_real_cars integer) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.place_enabled(p) and t.is_active and t.canonical_slug is null and p.kind <> 8
     and case t.vertical when 'rental' then s.place_hubs_index when 'sale' then s.sale_hubs_index when 'bodyshop' then s.bodyshop_hubs_index else s.detailing_hubs_index end
    from (select (app.settings()).*) s
$$;
update program_settings set place_quality_gate = false where place_quality_gate;
alter table program_settings add constraint program_settings_no_quality_gate check (not place_quality_gate);
comment on column program_settings.place_quality_gate is 'Retired (1100): every place page is indexed and filled with its own data instead. Kept off (a check).';
-- the vehicle pages: "index every page" only (the rules mode noindexed the pages that failed them)
update program_settings set vpage_index_mode = 'all' where vpage_index_mode <> 'all';
alter table program_settings add constraint program_settings_vpage_index_all check (vpage_index_mode = 'all');
comment on column program_settings.vpage_index_mode is 'Vehicle pages (0097; 1100): always "all", every make, model, year and trim page indexed. The rules mode is retired.';
comment on column program_settings.seo_landing_min_real_cars is 'Retired (1100): a landing page for a use is indexed whatever its number of real cars; the page lists the nearest similar cars instead.';

-- ================================================================ 2. the content epoch
create table if not exists app.seo_content_epoch (
  id          boolean primary key default true check (id),
  facts_hash  text not null,
  template    text not null,
  changed_at  timestamptz not null default now()
);
comment on table app.seo_content_epoch is 'The date every programmatic page''s content last changed together (1100): the facts all pages show (site_facts, the fuel prices) or the page templates (template). The sitemaps use the later of it and a page''s own date.';
revoke all on app.seo_content_epoch from public, anon, authenticated;
grant select on app.seo_content_epoch to service_role;

create or replace function app.seo_content_facts_hash() returns text
language sql stable security definer set search_path = public, app as $$
  select md5(app.site_facts_live()::text || '|' || coalesce((select concat_ws(',', s.vpage_gas_cents_per_litre, s.vpage_premium_extra_cents, s.vpage_electricity_cents_per_kwh) from (select (app.settings()).*) s), ''))
$$;

-- the template version: a release that changes what the pages say sets a new one (this release: depth-1)
create or replace function app.seo_content_epoch_refresh(p_template text default null) returns timestamptz
language plpgsql security definer set search_path = public, app as $$
declare
  v_hash text := app.seo_content_facts_hash();
  e app.seo_content_epoch;
begin
  select * into e from app.seo_content_epoch;
  if e.id is null then
    insert into app.seo_content_epoch (facts_hash, template) values (v_hash, coalesce(p_template, 'depth-1')) returning * into e;
  elsif e.facts_hash is distinct from v_hash or (p_template is not null and p_template is distinct from e.template) then
    update app.seo_content_epoch set facts_hash = v_hash, template = coalesce(p_template, template), changed_at = now() where id returning * into e;
  end if;
  return e.changed_at;
end $$;

create or replace function app.seo_content_epoch_on_change() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.seo_content_epoch_refresh(null);
  return null;
end $$;
drop trigger if exists seo_content_epoch on program_settings;
create trigger seo_content_epoch after insert or update or delete on program_settings for each statement execute function app.seo_content_epoch_on_change();
drop trigger if exists seo_content_epoch on fee_types;
create trigger seo_content_epoch after insert or update or delete on fee_types for each statement execute function app.seo_content_epoch_on_change();
drop trigger if exists seo_content_epoch on fee_defaults;
create trigger seo_content_epoch after insert or update or delete on fee_defaults for each statement execute function app.seo_content_epoch_on_change();

create or replace function public.seo_content_epoch() returns timestamptz
language sql stable security definer set search_path = public, app as $$
  select coalesce((select changed_at from app.seo_content_epoch), now())
$$;
revoke all on function app.seo_content_facts_hash(), app.seo_content_epoch_refresh(text), app.seo_content_epoch_on_change(), public.seo_content_epoch() from public, anon, authenticated;
grant execute on function app.seo_content_facts_hash(), app.seo_content_epoch_refresh(text), app.seo_content_epoch_on_change(), public.seo_content_epoch() to service_role;

-- this release changes every programmatic page (the depth sections)
select app.seo_content_epoch_refresh('depth-1');

-- ================================================================ 3. sourced page data
-- one value per model, year, trim and field; trim '' is the whole model year
create table if not exists vehicle_specs (
  id          bigint generated always as identity primary key,
  make        text not null check (length(make) between 1 and 60),
  model       text not null check (length(model) between 1 and 80),
  year        integer not null check (year between 1980 and 2100),
  trim        text not null default '' check (length(trim) <= 80),
  field       text not null check (field in ('tire_size', 'rim_size', 'fuel_city_l100', 'fuel_highway_l100', 'fuel_combined_l100', 'fuel_type', 'tank_l',
                                              'kwh100_combined', 'range_km', 'features', 'paint_colour', 'hp', 'torque_nm', 'zero_100_s', 'top_speed_kmh',
                                              'drivetrain', 'transmission', 'curb_kg', 'towing_kg', 'seats', 'cargo_l', 'length_mm', 'width_mm', 'height_mm',
                                              'wheelbase_mm', 'safety_overall', 'safety_frontal', 'safety_side', 'safety_rollover', 'recalls', 'engine')),
  value       text not null check (length(value) between 1 and 400),
  -- a paint colour is one row each (value: the name, code: the OEM code when the source gives it)
  code        text check (code is null or length(code) <= 40),
  source      text not null check (source in ('nhtsa_vpic', 'nhtsa_recalls', 'nhtsa_ratings', 'fueleconomy_gov', 'oem', 'open_dataset')),
  source_url  text not null check (source_url ~ '^https://'),
  fetched_at  timestamptz not null
);
create unique index if not exists vehicle_specs_key on vehicle_specs (lower(make), lower(model), year, lower(trim), field, coalesce(code, ''), (case when field in ('paint_colour', 'features') then value else '' end));
create index if not exists vehicle_specs_find on vehicle_specs (lower(make), lower(model), year);
comment on table vehicle_specs is 'Specs for the vehicle and car pages (1100), each with its source and fetch time (loaded by the seo-data workflow). A field with no row is left off the page; nothing is estimated.';

create table if not exists vehicle_maintenance_costs (
  id               bigint generated always as identity primary key,
  make             text not null default '' check (length(make) <= 60),   -- '' is every make of the segment
  segment          text not null check (length(segment) between 1 and 40), -- the catalog's vehicle class (compact car, midsize SUV ...)
  per_year_cents   integer not null check (per_year_cents between 0 and 2000000),
  per_10k_km_cents integer not null check (per_10k_km_cents between 0 and 2000000),
  assumptions      text not null check (length(assumptions) between 20 and 600),
  source           text not null check (length(source) between 2 and 120),
  source_url       text not null check (source_url ~ '^https://'),
  fetched_at       timestamptz not null,
  unique (make, segment)
);
comment on table vehicle_maintenance_costs is 'The vetted maintenance cost table (1100) by make and segment, with the assumptions shown on the page and its source. Empty: the pages show no estimate.';

create table if not exists place_pois (
  id          bigint generated always as identity primary key,
  kind        text not null check (kind in ('go_station', 'rail_station', 'subway_station', 'bus_stop', 'hotel')),
  agency      text check (agency is null or length(agency) <= 60),   -- GO Transit, TTC, MiWay, YRT, Brampton Transit, DRT; null for a hotel
  ref         text not null check (length(ref) between 1 and 80),    -- the stop_id or the OSM element (node/123)
  name        text not null check (length(name) between 1 and 160),
  lat         numeric(9, 6) not null check (lat between -90 and 90),
  lng         numeric(9, 6) not null check (lng between -180 and 180),
  source      text not null check (source in ('gtfs', 'osm')),
  source_url  text not null check (source_url ~ '^https://'),
  licence     text not null check (length(licence) between 2 and 200),
  attribution text not null check (length(attribution) between 2 and 200),
  fetched_at  timestamptz not null
);
create unique index if not exists place_pois_key on place_pois (source, coalesce(agency, ''), ref);
create index if not exists place_pois_geo on place_pois (lat, lng);
comment on table place_pois is 'Stops and stations from the transit agencies'' GTFS feeds and hotels from OpenStreetMap (1100), for the place pages. Business names and public places only; never a person.';

revoke all on vehicle_specs, vehicle_maintenance_costs, place_pois from public, anon, authenticated;
grant select, insert, update, delete on vehicle_specs, vehicle_maintenance_costs, place_pois to service_role;
alter table vehicle_specs enable row level security;
alter table vehicle_maintenance_costs enable row level security;
alter table place_pois enable row level security;
-- the house rule: every table has the admin policy (no grant to authenticated: the server reads and loads them)
create policy admin_all on vehicle_specs for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on vehicle_maintenance_costs for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on place_pois for all to authenticated using (app.is_admin()) with check (app.is_admin());

-- the reads (the server's, for the pages)
create or replace function public.vehicle_specs_for(p_make text, p_model text, p_year integer) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('trim', s.trim, 'field', s.field, 'value', s.value, 'code', s.code, 'source', s.source, 'source_url', s.source_url, 'fetched_at', s.fetched_at)
                            order by s.field, s.trim, s.value), '[]'::jsonb)
    from vehicle_specs s where lower(s.make) = lower(btrim(p_make)) and lower(s.model) = lower(btrim(p_model)) and s.year = p_year
$$;

create or replace function public.maintenance_cost_for(p_make text, p_segment text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select to_jsonb(x) - 'id' from vehicle_maintenance_costs x
   where lower(x.segment) = lower(btrim(coalesce(p_segment, ''))) and (lower(x.make) = lower(btrim(coalesce(p_make, ''))) or x.make = '')
   order by (x.make = '') limit 1
$$;

-- the nearest of each kind within p_km, at most p_each of each kind
create or replace function public.place_pois_near(p_lat numeric, p_lng numeric, p_km numeric default 5, p_each integer default 5) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('kind', x.kind, 'agency', x.agency, 'name', x.name, 'km', round(x.km, 1), 'source', x.source,
                                               'source_url', x.source_url, 'licence', x.licence, 'attribution', x.attribution, 'fetched_at', x.fetched_at)
                            order by x.kind, x.km), '[]'::jsonb)
    from (select p.*, app.distance_km(p_lat, p_lng, p.lat, p.lng) km, row_number() over (partition by p.kind order by app.distance_km(p_lat, p_lng, p.lat, p.lng), p.name) n
            from place_pois p
           where p_lat is not null and p_lng is not null
             and p.lat between p_lat - least(greatest(p_km, 0.5), 25) / 111.0 and p_lat + least(greatest(p_km, 0.5), 25) / 111.0
             and p.lng between p_lng - least(greatest(p_km, 0.5), 25) / (111.0 * greatest(cos(radians(p_lat)), 0.2)) and p_lng + least(greatest(p_km, 0.5), 25) / (111.0 * greatest(cos(radians(p_lat)), 0.2))) x
   where x.km <= least(greatest(p_km, 0.5), 25) and x.n <= least(greatest(p_each, 1), 10)
$$;

-- the loader: {kind: 'specs' | 'maintenance' | 'pois', rows: [...], prune: {source, agency?, before}} from the seo-data workflow
create or replace function app.server_seo_data_load(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_kind text := p ->> 'kind';
  v_rows jsonb := coalesce(p -> 'rows', '[]'::jsonb);
  v_n integer := 0;
  v_pruned integer := 0;
  r jsonb;
begin
  if v_kind not in ('specs', 'maintenance', 'pois') then raise exception 'seo data: unknown kind %', v_kind; end if;
  if jsonb_typeof(v_rows) <> 'array' or jsonb_array_length(v_rows) > 50000 then raise exception 'seo data: rows must be an array of at most 50,000'; end if;
  for r in select * from jsonb_array_elements(v_rows) loop
    if coalesce(r ->> 'source_url', '') !~ '^https://' or r ->> 'fetched_at' is null then raise exception 'seo data: every row needs its source_url and fetched_at'; end if;
    if v_kind = 'specs' then
      insert into vehicle_specs (make, model, year, trim, field, value, code, source, source_url, fetched_at)
      values (btrim(r ->> 'make'), btrim(r ->> 'model'), (r ->> 'year')::integer, coalesce(btrim(r ->> 'trim'), ''), r ->> 'field', btrim(r ->> 'value'),
              nullif(btrim(r ->> 'code'), ''), r ->> 'source', r ->> 'source_url', (r ->> 'fetched_at')::timestamptz)
      on conflict (lower(make), lower(model), year, lower(trim), field, coalesce(code, ''), (case when field in ('paint_colour', 'features') then value else '' end))
      do update set value = excluded.value, source = excluded.source, source_url = excluded.source_url, fetched_at = excluded.fetched_at;
    elsif v_kind = 'maintenance' then
      insert into vehicle_maintenance_costs (make, segment, per_year_cents, per_10k_km_cents, assumptions, source, source_url, fetched_at)
      values (coalesce(btrim(r ->> 'make'), ''), btrim(r ->> 'segment'), (r ->> 'per_year_cents')::integer, (r ->> 'per_10k_km_cents')::integer, r ->> 'assumptions',
              r ->> 'source', r ->> 'source_url', (r ->> 'fetched_at')::timestamptz)
      on conflict (make, segment) do update set per_year_cents = excluded.per_year_cents, per_10k_km_cents = excluded.per_10k_km_cents, assumptions = excluded.assumptions,
        source = excluded.source, source_url = excluded.source_url, fetched_at = excluded.fetched_at;
    else
      insert into place_pois (kind, agency, ref, name, lat, lng, source, source_url, licence, attribution, fetched_at)
      values (r ->> 'kind', nullif(btrim(r ->> 'agency'), ''), r ->> 'ref', btrim(r ->> 'name'), (r ->> 'lat')::numeric, (r ->> 'lng')::numeric, r ->> 'source',
              r ->> 'source_url', r ->> 'licence', r ->> 'attribution', (r ->> 'fetched_at')::timestamptz)
      on conflict (source, coalesce(agency, ''), ref) do update set kind = excluded.kind, name = excluded.name, lat = excluded.lat, lng = excluded.lng,
        source_url = excluded.source_url, licence = excluded.licence, attribution = excluded.attribution, fetched_at = excluded.fetched_at;
    end if;
    v_n := v_n + 1;
  end loop;
  -- rows of the same source not seen by this run (a stop removed from the feed, a hotel closed) go
  if p -> 'prune' ->> 'before' is not null then
    if v_kind = 'pois' then
      delete from place_pois where source = p -> 'prune' ->> 'source' and coalesce(agency, '') = coalesce(p -> 'prune' ->> 'agency', '') and fetched_at < (p -> 'prune' ->> 'before')::timestamptz;
    elsif v_kind = 'specs' then
      delete from vehicle_specs where source = p -> 'prune' ->> 'source' and fetched_at < (p -> 'prune' ->> 'before')::timestamptz;
    end if;
    get diagnostics v_pruned = row_count;
  end if;
  return jsonb_build_object('kind', v_kind, 'loaded', v_n, 'pruned', v_pruned);
end $$;

-- the cars and models the specs import should look up (the fleet first, then the catalog's popular models)
create or replace function app.server_seo_data_targets(p_limit integer default 400) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('make', x.make, 'model', x.model, 'year', x.year)), '[]'::jsonb)
    from (select distinct v.make, v.model, v.year from vehicles v join vehicle_listings l on l.vehicle_id = v.id
           where l.status = 'published' and v.year is not null and v.make is not null and v.model is not null limit greatest(least(p_limit, 2000), 1)) x
$$;

revoke all on function public.vehicle_specs_for(text, text, integer), public.maintenance_cost_for(text, text), public.place_pois_near(numeric, numeric, numeric, integer),
  app.server_seo_data_load(jsonb), app.server_seo_data_targets(integer) from public, anon, authenticated;
grant execute on function public.vehicle_specs_for(text, text, integer), public.maintenance_cost_for(text, text), public.place_pois_near(numeric, numeric, numeric, integer),
  app.server_seo_data_load(jsonb), app.server_seo_data_targets(integer) to service_role;

-- the fuel prices behind "cost to drive 100 km" on every car page (the vehicle pages' Program settings)
create or replace function public.seo_fuel_prices() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('gas_cents', s.vpage_gas_cents_per_litre, 'premium_extra_cents', s.vpage_premium_extra_cents, 'kwh_cents', s.vpage_electricity_cents_per_kwh)
    from (select (app.settings()).*) s
$$;
revoke all on function public.seo_fuel_prices() from public, anon, authenticated;
grant execute on function public.seo_fuel_prices() to service_role;
