-- 0095: local search, places and terms (October 22, 2026). The owner's goal: carmacars.ca ranks for "Toronto car
-- rental", "car rental Toronto" and every close variant, and for each way of renting, buying help and detailing in
-- every place CarmaCars can serve. Change record: docs/changes/2026-10-22-local-seo.md.
--
--   1  landing pages: a page can list cars by body style (a convertible, an SUV, a van), by a flag of the car (no credit
--      card needed, insurance comes with the car: vehicles.no_credit_card and vehicles.insurance_included of the
--      partner cars, read when the columns exist), or by any of several rules; a page may need more real cars than
--      Program settings before it is indexed (seo_pages.min_real_cars); IndexNow hears of a page when it may be indexed
--   2  one name, address and phone everywhere: the business address of the structured data and the listings is the
--      street address the site shows (the owner, October 21: 1570 Midland Ave); a summary of published reviews for
--      the business node, given only from seo_rating_min_reviews reviews
--   3  places: country > province or state > region > city or town > neighbourhood, airports and landmarks, for
--      Canada, the United States and Mexico, from GeoNames (CC BY 4.0), OpenStreetMap (ODbL) and the US Census Gazetteer
--      (public domain) through the places workflow, kept compact; every region on by default, each can be switched off;
--      the workflow stops before the database passes a size cap (Program settings, 6 GB)
--   4  terms: every way people search for renting, buying help, detailing and body work, editable in Admin; the
--      detailing and body shop services
--   5  hubs: one page per place and term (/car-rental/<place>, /car-rental/<term>/<place>, /buy/<term>/<place>,
--      /detailing/<term>/<place>, /body-shop/<term>/<place>) from real data only: the distance to us, the delivery price
--      from our rate cards within the delivery reach (a request beyond it), the nearest airport, the landmarks the
--      sources list, the live matching cars, the places around; sitemaps by primary key range; one Admin switch per
--      tier (on), and an optional quality gate (off)
--   6  requests from those pages: a car to buy, financing or lease options, a car in a place we do not serve yet,
--      detailing, body work; each a lead with a task for the team
--   7  the door: Admin > Settings > Search, places and terms
--   8  security and privileges
--   9  the guides of this release

-- ================================================================ 1. landing pages: body styles, flags, any of several rules
alter table seo_pages add column if not exists min_real_cars integer check (min_real_cars is null or min_real_cars >= 1);
comment on column seo_pages.min_real_cars is 'Real matching cars this page needs before it is indexed (0095); empty: Program settings seo_landing_min_real_cars. The pages for cars with no credit card needed or insurance with the car need 3.';
comment on table seo_pages is 'Landing pages at /car-rental/<slug> (0061, 0095). facts: what the copy may say about the place or use; match: which live cars it lists (classes, fuels, seats_min, young, bodies: body style words, flags: car flags that must be true, any: a list of such rules of which one must hold); copy: seo_title, meta_description, h1, intro, sections [{heading, body}], faq. Rows are added by the content seed and edited in Admin > Settings > Search.';

-- one rule (the rules of 0061, plus body style words and car flags)
create or replace function app.seo_match_one(r jsonb, m jsonb) returns boolean
language sql immutable as $$
  select (jsonb_typeof(m -> 'classes') is distinct from 'array'
          or exists (select 1 from jsonb_array_elements_text(r -> 'classes') c where c = any (array(select jsonb_array_elements_text(m -> 'classes')))))
     and (jsonb_typeof(m -> 'fuels') is distinct from 'array' or (r ->> 'fuel') = any (array(select jsonb_array_elements_text(m -> 'fuels'))))
     and (m ->> 'seats_min' is null or coalesce((r ->> 'seats')::integer, 0) >= (m ->> 'seats_min')::integer)
     and (not coalesce((m ->> 'young')::boolean, false) or coalesce((r ->> 'allows_18_to_20')::boolean, false))
     and (jsonb_typeof(m -> 'bodies') is distinct from 'array'
          or exists (select 1 from jsonb_array_elements_text(m -> 'bodies') b where lower(coalesce(r ->> 'body_style', '')) like '%' || lower(b) || '%'))
     and (jsonb_typeof(m -> 'flags') is distinct from 'array'
          or not exists (select 1 from jsonb_array_elements_text(m -> 'flags') f where not coalesce((r ->> f)::boolean, false)))
$$;

-- a car taking requests that meets the rule, and one of the "any" rules when there are some
create or replace function app.seo_match(r jsonb, m jsonb) returns boolean
language sql immutable as $$
  select coalesce((r ->> 'taking_requests')::boolean, false)
     and app.seo_match_one(r, m)
     and (jsonb_typeof(m -> 'any') is distinct from 'array' or jsonb_array_length(m -> 'any') = 0
          or exists (select 1 from jsonb_array_elements(m -> 'any') a where app.seo_match_one(r, a)))
$$;

-- the real cars taking requests that match, from the tables (the footer reads it on every page): the car's own row
-- (its flags, whatever columns it has), its classes, its listing's seats and body style
create or replace function app.seo_real_count(p_match jsonb) returns integer
language sql stable security definer set search_path = public, app as $$
  select count(*)::integer
    from vehicle_listings l join vehicles v on v.id = l.vehicle_id join public_vehicle_listings pv on pv.vehicle_id = v.id
   where l.status = 'published' and v.management_mode <> 'turo_only' and not v.is_sample
     and app.seo_match(to_jsonb(v) || jsonb_build_object('taking_requests', true, 'classes', to_jsonb(app.vehicle_class_list(v.id)), 'fuel', v.fuel::text,
                                                         'seats', l.seats, 'body_style', coalesce(nullif(l.body_style, ''), v.body_type)), p_match)
$$;

create or replace function app.seo_page_indexable(p seo_pages) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p.is_active and p.copy <> '{}'::jsonb
     and (p.kind = 'location' or app.seo_real_count(p.match) >= coalesce(p.min_real_cars, (app.settings()).seo_landing_min_real_cars))
$$;

-- IndexNow hears of a landing page only when it may be indexed (a page under its threshold is noindex)
create or replace function app.indexnow_on_page() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if tg_table_name = 'seo_pages' and (tg_op = 'INSERT' or new.content_updated_at is distinct from old.content_updated_at) then
    if app.seo_page_indexable(new) then perform app.indexnow_queue_path(app.seo_page_path(new.slug), 'landing page'); end if;
  elsif tg_table_name = 'articles' and (tg_op = 'INSERT' or new.content_updated_at is distinct from old.content_updated_at) then
    perform app.indexnow_queue_path('/guides/' || new.slug, 'article');
    perform app.indexnow_queue_path('/guides', 'articles');
  end if;
  return null;
end $$;

-- the snapshots of 0068, for the landing pages and the rental terms; a page whose cars changed and that may be indexed
-- goes to IndexNow (a page for a use enters search when its cars arrive)
alter table seo_pages add column if not exists was_indexable boolean;
create or replace function app.seo_snapshot_refresh() returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v_stamp text := app.seo_fleet_stamp();
  v_fleet jsonb;
  v_changed integer := 0;
  p seo_pages;
  t record;
  v_cars jsonb;
  v_snap jsonb;
  v_ix boolean;
begin
  select coalesce(jsonb_agg(r), '[]'::jsonb) into v_fleet from app.public_fleet('{}'::jsonb) r;
  for p in select * from seo_pages where is_active for update loop
    select coalesce(jsonb_agg(e.v order by (e.v ->> 'daily_rate_cents')::bigint nulls last), '[]'::jsonb) into v_cars
      from jsonb_array_elements(v_fleet) e(v) where app.seo_match(e.v, p.match);
    v_snap := jsonb_build_object('cars', (select coalesce(jsonb_agg(x.v order by x.n), '[]'::jsonb)
                                            from jsonb_array_elements(v_cars) with ordinality x(v, n) where x.n <= 24),
                                 'counts', app.seo_counts_of(v_cars));
    v_ix := app.seo_page_indexable(p);
    if p.cars_snapshot is distinct from v_snap or p.was_indexable is distinct from v_ix then
      if p.cars_snapshot is distinct from v_snap then v_changed := v_changed + 1; end if;
      update seo_pages set cars_snapshot = v_snap, snapshot_stamp = v_stamp, snapshot_at = now(), was_indexable = v_ix,
             cars_changed_at = case when p.cars_snapshot is null then coalesce(cars_changed_at, now()) when p.cars_snapshot is distinct from v_snap then now() else cars_changed_at end
       where slug = p.slug;
      if v_ix and (p.was_indexable is distinct from true or p.cars_snapshot is distinct from v_snap) and p.cars_snapshot is not null then
        perform app.indexnow_queue_path(app.seo_page_path(p.slug), 'landing page cars');
      end if;
    else
      update seo_pages set snapshot_stamp = v_stamp, snapshot_at = now() where slug = p.slug;
    end if;
  end loop;
  -- the rental terms of the place hubs (section 4): the cars each term lists, cheapest first
  if to_regclass('public.place_terms') is not null then
    for t in select slug, match, cars_snapshot from place_terms where vertical = 'rental' and is_active loop
      select coalesce(jsonb_agg(e.v order by (e.v ->> 'daily_rate_cents')::bigint nulls last), '[]'::jsonb) into v_cars
        from jsonb_array_elements(v_fleet) e(v) where app.seo_match(e.v, t.match);
      v_snap := jsonb_build_object('cars', (select coalesce(jsonb_agg(x.v order by x.n), '[]'::jsonb) from jsonb_array_elements(v_cars) with ordinality x(v, n) where x.n <= 12),
                                   'counts', app.seo_counts_of(v_cars));
      if t.cars_snapshot is distinct from v_snap then
        update place_terms set cars_snapshot = v_snap, snapshot_stamp = v_stamp, cars_changed_at = now() where slug = t.slug;
        v_changed := v_changed + 1;
      else
        update place_terms set snapshot_stamp = v_stamp where slug = t.slug and snapshot_stamp is distinct from v_stamp;
      end if;
    end loop;
  end if;
  return v_changed;
end $$;

-- ================================================================ 2. one name, address and phone; the review summary
-- The business address (structured data, Admin's business listings) was the mailing address of 0061; the site shows
-- the street address. One address everywhere: the street address the site shows, while the business address is
-- still 0061's own value (an Admin's edit is kept).
update site_settings s set
  business_street = btrim(m[1]), business_city = btrim(m[2]), business_region = 'ON', business_postal_code = upper(btrim(m[3]))
  from (select regexp_match(street_address, '^\s*([^,]+),\s*([^,]+),\s*ON\s+([A-Za-z]\d[A-Za-z] ?\d[A-Za-z]\d)\s*$') as m, id from site_settings) x
 where x.id = s.id and s.business_street = '2967 Dundas St W, Unit 208B' and x.m is not null;
-- a street address without its postal code yet (0079 adds it): the street and the city, the postal code stays empty
update site_settings s set business_street = btrim(m[1]), business_city = btrim(m[2]), business_region = 'ON', business_postal_code = null
  from (select regexp_match(street_address, '^\s*([^,]+),\s*([^,]+),\s*ON\s*$') as m, id from site_settings) x
 where x.id = s.id and s.business_street = '2967 Dundas St W, Unit 208B' and x.m is not null;
comment on column site_settings.business_street is 'Street address of the business (NAP): the structured data, the footer, the contact page and every listing show this one address (0095). Keep it the address renters come to.';

-- Published reviews of the whole business: the count and average, given only from seo_rating_min_reviews of them
-- (the home page shows the reviews themselves next to it). Null below that.
create or replace function app.public_business_rating() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when count(*) >= (app.settings()).seo_rating_min_reviews
              then jsonb_build_object('count', count(*), 'average', round(avg(r.rating)::numeric, 1)) end
    from reviews r where r.status = 'published'
$$;
create or replace function public.business_rating() returns jsonb language sql stable security definer set search_path = public, app as $$ select app.public_business_rating() $$;

-- ================================================================ 3. places (compact: about 200 bytes a place with its indexes)
-- Regions: the provinces and territories of Canada, the states, DC and territories of the United States, the states of
-- Mexico. Each can be switched off in Admin; all are on by default. A region has pages only once the places workflow
-- loaded it.
create table place_regions (
  id          smallint generated always as identity primary key,
  code        text not null unique check (code ~ '^[A-Z]{2}-[A-Z0-9]{1,3}$'),
  country     text not null check (country in ('CA', 'US', 'MX')),
  name        text not null,
  is_enabled  boolean not null default true,
  sort_order  smallint not null default 100,
  loaded_at   timestamptz,
  places      integer not null default 0,
  skipped     text                                  -- why the last import did not load it (the size cap)
);
comment on table place_regions is 'Regions of the place pages (0095). is_enabled: pages and sitemaps for its places (Admin > Settings > Search). loaded_at and places: the places workflow''s last load.';

insert into place_regions (code, country, name, sort_order)
select 'CA-' || c, 'CA', n, case when c = 'ON' then 1 else 10 + o end from unnest(
  array['ON', 'QC', 'BC', 'AB', 'MB', 'SK', 'NS', 'NB', 'NL', 'PE', 'YT', 'NT', 'NU'],
  array['Ontario', 'Quebec', 'British Columbia', 'Alberta', 'Manitoba', 'Saskatchewan', 'Nova Scotia', 'New Brunswick', 'Newfoundland and Labrador', 'Prince Edward Island', 'Yukon', 'Northwest Territories', 'Nunavut'])
  with ordinality x(c, n, o);
insert into place_regions (code, country, name, sort_order)
select 'US-' || c, 'US', n, 100 + o from unnest(
  array['NY', 'MI', 'OH', 'PA', 'VT', 'NH', 'ME', 'MA', 'CT', 'RI', 'NJ', 'DE', 'MD', 'DC', 'VA', 'WV', 'NC', 'SC', 'GA', 'FL', 'AL', 'MS', 'TN', 'KY', 'IN', 'IL', 'WI', 'MN', 'IA', 'MO', 'AR', 'LA',
        'TX', 'OK', 'KS', 'NE', 'SD', 'ND', 'MT', 'WY', 'CO', 'NM', 'AZ', 'UT', 'ID', 'NV', 'CA', 'OR', 'WA', 'AK', 'HI', 'PR', 'VI', 'GU', 'AS', 'MP'],
  array['New York', 'Michigan', 'Ohio', 'Pennsylvania', 'Vermont', 'New Hampshire', 'Maine', 'Massachusetts', 'Connecticut', 'Rhode Island', 'New Jersey', 'Delaware', 'Maryland',
        'District of Columbia', 'Virginia', 'West Virginia', 'North Carolina', 'South Carolina', 'Georgia', 'Florida', 'Alabama', 'Mississippi', 'Tennessee', 'Kentucky', 'Indiana', 'Illinois',
        'Wisconsin', 'Minnesota', 'Iowa', 'Missouri', 'Arkansas', 'Louisiana', 'Texas', 'Oklahoma', 'Kansas', 'Nebraska', 'South Dakota', 'North Dakota', 'Montana', 'Wyoming', 'Colorado',
        'New Mexico', 'Arizona', 'Utah', 'Idaho', 'Nevada', 'California', 'Oregon', 'Washington', 'Alaska', 'Hawaii', 'Puerto Rico', 'U.S. Virgin Islands', 'Guam', 'American Samoa',
        'Northern Mariana Islands']) with ordinality x(c, n, o);
insert into place_regions (code, country, name, sort_order)
select 'MX-' || c, 'MX', n, 200 + o from unnest(
  array['AGU', 'BCN', 'BCS', 'CAM', 'CHP', 'CHH', 'COA', 'COL', 'CMX', 'DUR', 'GUA', 'GRO', 'HID', 'JAL', 'MEX', 'MIC', 'MOR', 'NAY', 'NLE', 'OAX', 'PUE', 'QUE', 'ROO', 'SLP', 'SIN', 'SON',
        'TAB', 'TAM', 'TLA', 'VER', 'YUC', 'ZAC'],
  array['Aguascalientes', 'Baja California', 'Baja California Sur', 'Campeche', 'Chiapas', 'Chihuahua', 'Coahuila', 'Colima', 'Mexico City', 'Durango', 'Guanajuato', 'Guerrero', 'Hidalgo',
        'Jalisco', 'State of Mexico', 'Michoacan', 'Morelos', 'Nayarit', 'Nuevo Leon', 'Oaxaca', 'Puebla', 'Queretaro', 'Quintana Roo', 'San Luis Potosi', 'Sinaloa', 'Sonora', 'Tabasco',
        'Tamaulipas', 'Tlaxcala', 'Veracruz', 'Yucatan', 'Zacatecas']) with ordinality x(c, n, o);

-- kind: 1 country, 2 province or state, 3 region (county, census division), 4 area (the GTA), 5 city or town,
-- 6 neighbourhood, 7 airport, 8 landmark. flags: 1 in the GTA, 2 GeoNames, 4 OpenStreetMap, 8 US Census, 16 curated,
-- 32 test fixture. src_id: the GeoNames id; a place only OpenStreetMap has: minus its node id; only the Census: minus
-- (10^13 + its GEOID). lat and lng as 4-byte reals (about a metre).
create table places (
  id           integer generated always as identity primary key,
  parent_id    integer references places (id) on delete set null,
  kind         smallint not null check (kind between 1 and 8),
  region_id    smallint references place_regions (id),
  flags        smallint not null default 0,
  lat          real check (lat between -90 and 90),
  lng          real check (lng between -180 and 180),
  population   integer check (population >= 0),
  src_id       bigint,
  updated_on   date not null default current_date,
  slug         text not null check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name         text not null,
  country      text not null check (country in ('CA', 'US', 'MX')),
  iata         text check (iata is null or iata ~ '^[A-Z]{3}$'),
  landing_slug text,
  is_active    boolean not null default true
);
create index places_slug_idx on places using hash (slug);
create index places_src_idx on places using hash (src_id);
create index places_parent_idx on places (parent_id);
create index places_airports_idx on places (lat, lng) where kind = 7;
create index places_tops_idx on places (kind) where kind in (1, 2, 4);
comment on table places is 'Places for the hub pages (0095), kept small. From GeoNames (CC BY 4.0), OpenStreetMap (ODbL, © OpenStreetMap contributors) and the US Census Gazetteer (public domain) through .github/workflows/places.yml; the countries, Ontario and the GTA are curated. Slugs are unique (the import checks; the index is a hash index to stay small). A city with a landing page uses its slug.';

-- the workflow loads a region into the staging table, then app.places_import_apply puts it in place
create table places_staging (
  src_id        bigint primary key,
  kind          smallint not null,
  flags         smallint not null default 0,
  region_code   text,
  country       text not null,
  lat           real,
  lng           real,
  population    integer,
  parent_src_id bigint,
  slug          text not null,
  name          text not null,
  iata          text
);
create table place_imports (
  id          integer generated always as identity primary key,
  regions     text[] not null,
  sources     text[] not null default '{geonames}',
  started_at  timestamptz not null default now(),
  finished_at timestamptz,
  counts      jsonb not null default '{}'::jsonb,   -- per region: loaded, skipped and why; per country and kind
  run_url     text,
  error       text
);
comment on table place_imports is 'Runs of the places workflow (0095): what was loaded, what was skipped (the database size cap) and the counts per country and kind.';

alter table program_settings add column if not exists place_db_cap_mb integer not null default 6144 check (place_db_cap_mb between 100 and 100000);
comment on column program_settings.place_db_cap_mb is 'The places workflow stops loading regions before the whole database would pass this size (MB). Default 6 GB: the Supabase Pro plan includes 8 GB.';

-- the curated top: Canada, the United States, Mexico (real GeoNames ids, so the import finds them), Ontario, the GTA
insert into places (kind, flags, lat, lng, src_id, slug, name, country) values
  (1, 16, 60.10867, -113.64258, 6251999, 'canada', 'Canada', 'CA'),
  (1, 16, 39.76, -98.5, 6252001, 'united-states', 'United States', 'US'),
  (1, 16, 23.0, -102.0, 3996063, 'mexico', 'Mexico', 'MX');
insert into places (parent_id, kind, region_id, flags, lat, lng, src_id, slug, name, country)
select (select id from places where slug = 'canada'), 2, (select id from place_regions where code = 'CA-ON'), 16, 49.25014, -84.49983, 6093943, 'ontario', 'Ontario', 'CA';
insert into places (parent_id, kind, region_id, flags, lat, lng, slug, name, country)
select (select id from places where slug = 'ontario'), 4, (select id from place_regions where code = 'CA-ON'), 17, 43.6532, -79.3832, 'gta', 'Greater Toronto Area', 'CA';

create or replace function app.place_kind(k smallint) returns text
language sql immutable as $$
  select (array['country', 'province', 'region', 'area', 'city', 'neighbourhood', 'airport', 'landmark'])[k]
$$;

-- the regions that make up the GTA (GeoNames names them by the census division)
create or replace function app.place_is_gta_region(p_name text) returns boolean
language sql immutable as $$
  select lower(coalesce(p_name, '')) ~ '^((city of )?toronto( division)?|(regional municipality of )?(peel|york|durham|halton)( region)?)$'
$$;

-- What the loader may still add: the database size now and the cap (Program settings).
create or replace function public.server_places_budget() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('db_bytes', pg_database_size(current_database()), 'cap_bytes', (app.settings()).place_db_cap_mb::bigint * 1024 * 1024,
                            'places', (select count(*) from places), 'places_bytes', pg_total_relation_size('places'))
$$;

create or replace function public.server_places_import_begin(p_regions text[], p_sources text[], p_run_url text default null) returns integer
language plpgsql security definer set search_path = public, app as $$
declare v integer;
begin
  truncate places_staging;
  insert into place_imports (regions, sources, run_url) values (p_regions, p_sources, p_run_url) returning id into v;
  return v;
end $$;
create or replace function public.server_places_stage_clear() returns void
language sql security definer set search_path = public, app as $$ truncate places_staging $$;

-- One staged region in place: new places inserted (a slug already used gets a short suffix), known ones updated
-- (their slug kept), parents set from the staged parents. Returns the counts.
create or replace function app.places_import_apply(p_import integer, p_region text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_added integer; v_updated integer; v_parents integer;
  v_region smallint := (select id from place_regions where code = p_region);
begin
  update places p set kind = case when p.flags & 16 <> 0 then p.kind else s.kind end, flags = (p.flags & 17) | s.flags,
         region_id = coalesce((select id from place_regions where code = s.region_code), p.region_id),
         lat = s.lat, lng = s.lng, population = s.population, name = case when p.flags & 16 <> 0 then p.name else s.name end, iata = s.iata,
         is_active = true, updated_on = current_date
    from places_staging s where s.src_id = p.src_id
     and (p.lat, p.lng, p.population, p.name, p.iata, p.flags & ~17, p.is_active) is distinct from (s.lat, s.lng, s.population, s.name, s.iata, s.flags, true);
  get diagnostics v_updated = row_count;
  with n as (
    select s.*, row_number() over (partition by s.slug order by s.population desc nulls last, s.src_id) as dup
      from places_staging s where not exists (select 1 from places p where p.src_id = s.src_id))
  insert into places (kind, region_id, flags, lat, lng, population, src_id, slug, name, country, iata)
  select n.kind, (select id from place_regions where code = n.region_code), n.flags, n.lat, n.lng, n.population, n.src_id,
         case when n.dup = 1 and not exists (select 1 from places p where p.slug = n.slug) and not exists (select 1 from seo_pages sp where sp.slug = n.slug)
              then n.slug else n.slug || '-' || substr(md5(n.src_id::text), 1, 5) end,
         n.name, n.country, n.iata
    from n;
  get diagnostics v_added = row_count;
  update places p set parent_id = q.id
    from places_staging s join places q on q.src_id = s.parent_src_id
   where s.src_id = p.src_id and p.parent_id is distinct from q.id;
  get diagnostics v_parents = row_count;
  if v_region is not null then
    update place_regions set loaded_at = now(), skipped = null, places = (select count(*) from places where region_id = v_region) where id = v_region;
  end if;
  update place_imports set counts = counts || jsonb_build_object(p_region, jsonb_build_object('staged', (select count(*) from places_staging), 'added', v_added, 'updated', v_updated, 'parents', v_parents))
   where id = p_import;
  return jsonb_build_object('region', p_region, 'staged', (select count(*) from places_staging), 'added', v_added, 'updated', v_updated, 'parents', v_parents);
end $$;
create or replace function public.server_places_import_apply(p_import integer, p_region text) returns jsonb
language sql security definer set search_path = public, app as $$ select app.places_import_apply(p_import, p_region) $$;

-- After the last region: provinces under their country, the GTA, the landing pages that are a place's page, the
-- counts per country and kind, the regions skipped, and the top pages to IndexNow.
create or replace function app.places_import_finish(p_import integer, p_skipped jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  pg seo_pages;
  v_place places;
  v_linked integer := 0;
  v_counts jsonb;
begin
  update places p set parent_id = c.id from places c where p.kind = 2 and p.parent_id is null and c.kind = 1 and c.country = p.country;
  with recursive gta(id) as (
    select id from places where kind = 3 and region_id = (select id from place_regions where code = 'CA-ON') and app.place_is_gta_region(name)
    union select p.id from places p join gta on p.parent_id = gta.id)
  update places p set flags = case when p.id in (select id from gta) then p.flags | 1 else p.flags & ~1 end
   where p.kind > 4 and (p.id in (select id from gta)) <> (p.flags & 1 <> 0);
  for pg in select * from seo_pages where kind = 'location' loop
    select * into v_place from places p
     where p.is_active and p.region_id = (select id from place_regions where code = 'CA-ON')
       and ((pg.facts ? 'airport_code' and p.kind = 7 and p.iata = pg.facts ->> 'airport_code')
            or (not pg.facts ? 'airport_code' and p.kind in (5, 6, 8) and lower(p.name) = lower(regexp_replace(pg.name, ' \(.*\)$', ''))))
     order by (p.landing_slug = pg.slug) desc nulls last, p.kind, p.population desc nulls last limit 1;
    if v_place.id is not null and v_place.slug <> pg.slug then
      update places set slug = slug || '-' || id where slug = pg.slug and id <> v_place.id;
      update places set slug = pg.slug, landing_slug = pg.slug where id = v_place.id;
      v_linked := v_linked + 1;
    elsif v_place.id is not null and v_place.landing_slug is distinct from pg.slug then
      update places set landing_slug = pg.slug where id = v_place.id;
    end if;
    v_place := null;
  end loop;
  update place_regions r set skipped = x.value #>> '{}' from jsonb_each(coalesce(p_skipped, '{}'::jsonb)) x where r.code = x.key;
  select jsonb_object_agg(country, k) into v_counts from (
    select country, jsonb_object_agg(app.place_kind(kind), n) k from (select country, kind, count(*) n from places group by country, kind) a group by country) b;
  update place_imports set finished_at = now(), counts = counts || jsonb_build_object('skipped', coalesce(p_skipped, '{}'::jsonb), 'by_country', v_counts, 'linked', v_linked,
                                                                                    'places_bytes', pg_total_relation_size('places'))
   where id = p_import;
  perform app.indexnow_queue_path('/car-rental/' || p.slug, 'places') from places p where p.kind in (1, 2) and app.place_enabled(p);
  return jsonb_build_object('linked', v_linked, 'by_country', v_counts, 'places_bytes', pg_total_relation_size('places'));
end $$;
create or replace function public.server_places_import_finish(p_import integer, p_skipped jsonb default '{}'::jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.places_import_finish(p_import, p_skipped) $$;

-- ================================================================ 4. terms and services
alter table program_settings
  add column if not exists place_hubs_index boolean not null default true,
  add column if not exists sale_hubs_index boolean not null default true,
  add column if not exists detailing_hubs_index boolean not null default true,
  add column if not exists bodyshop_hubs_index boolean not null default true,
  add column if not exists place_quality_gate boolean not null default false,
  add column if not exists place_delivery_reach_km integer not null default 80 check (place_delivery_reach_km between 1 and 5000),
  add column if not exists place_sitemap_file_urls integer not null default 25000 check (place_sitemap_file_urls between 1000 and 50000),
  add column if not exists sale_disclaimer text not null default 'CarmaCars rents cars and does detailing and body work. We do not sell, finance or lease cars, and we are not a lender, a dealer or a leasing company. Tell us what you need and we will help where we can.';
comment on column program_settings.place_hubs_index is 'Rental place pages (/car-rental/<place>, /car-rental/<term>/<place>): in search and the sitemaps. On by default.';
comment on column program_settings.sale_hubs_index is 'Buying help pages (/buy/<term>/<place>): in search and the sitemaps. On by default.';
comment on column program_settings.detailing_hubs_index is 'Detailing place pages (/detailing/<term>/<place>): in search and the sitemaps. On by default.';
comment on column program_settings.bodyshop_hubs_index is 'Body shop place pages (/body-shop/<term>/<place>): in search and the sitemaps. On by default.';
comment on column program_settings.place_quality_gate is 'Quality gate for the place pages. Off: every page of an enabled region is indexed. On: only places within the delivery reach, and for rental only terms with a real matching car. Search engines can treat many similar pages as low value; the gate lowers that risk.';
comment on column program_settings.place_delivery_reach_km is 'Place pages: places within this distance of our location (straight line) are offered delivery; beyond it, a page says we serve the Toronto area and takes a request for a car there';
comment on column program_settings.place_sitemap_file_urls is 'Place pages: addresses per sitemap file (Google allows 50,000)';
comment on column program_settings.sale_disclaimer is 'The notice on every buying help page. Say "we connect you" only once a partner exists.';

create table place_terms (
  slug           text primary key check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  vertical       text not null check (vertical in ('rental', 'sale', 'detailing', 'bodyshop')),
  phrase         text not null check (char_length(phrase) between 2 and 60),   -- as searched, lower case: "car hire"
  title          text not null check (char_length(title) between 2 and 60),    -- as a heading: "Car Hire"
  canonical_slug text references place_terms (slug) on delete set null,        -- a synonym whose pages point to another term's
  match          jsonb not null default '{}'::jsonb check (jsonb_typeof(match) = 'object'),   -- rental: which live cars (section 1's rules)
  served         text not null default 'yes' check (served in ('yes', 'request')),           -- request: not offered directly, the page takes a request
  landing_slug   text,                                                         -- the landing page for this way of renting (Toronto-wide)
  service_code   text,                                                         -- detailing and body shop: the service it belongs to
  lead_kind      text check (lead_kind is null or lead_kind in ('buyer', 'finance', 'detailing', 'bodyshop', 'place_request')),
  intent_note    text not null default '' check (char_length(intent_note) <= 600),   -- one or two true sentences, tokens allowed
  faq            jsonb not null default '[]'::jsonb check (jsonb_typeof(faq) = 'array'),
  sort_order     integer not null default 100,
  is_active      boolean not null default true,
  cars_snapshot  jsonb,
  snapshot_stamp text,
  cars_changed_at timestamptz,
  updated_by     uuid references users (id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create trigger place_terms_updated before update on place_terms for each row execute function app.set_updated_at();
comment on table place_terms is 'How people search (0095): rental, buying help, detailing and body shop terms; one page per enabled place and term. Admin > Settings > Search edits them. The vehicle pages (vehiclepages) read the same table.';

create table shop_services (
  code             text primary key check (code ~ '^[a-z0-9_]+$'),
  vertical         text not null check (vertical in ('detailing', 'bodyshop')),
  name             text not null,
  description      text not null,
  from_price_cents bigint check (from_price_cents is null or from_price_cents > 0),   -- empty: price on request
  sort_order       integer not null default 100,
  is_active        boolean not null default true,
  updated_at       timestamptz not null default now()
);
create trigger shop_services_updated before update on shop_services for each row execute function app.set_updated_at();
comment on table shop_services is 'The detailing and body shop services CarmaCars offers (0095), on /detailing and /body-shop. A starting price only when an Admin sets one; otherwise "price on request".';

insert into shop_services (code, vertical, name, description, sort_order) values
  ('detailing', 'detailing', 'Interior and exterior detailing', 'A full detail, an interior or an exterior detail, a hand wash, or a wax.', 10),
  ('correction_coating', 'detailing', 'Paint correction and ceramic coating', 'Polishing out swirls and light scratches, then a ceramic coating to protect the paint.', 20),
  ('mobile', 'detailing', 'Mobile detailing', 'We come to your home or office and detail the car there.', 30),
  ('tint_ppf_wrap', 'detailing', 'Window tint, PPF and wraps', 'Window tint, paint protection film (clear bra) and vinyl wraps.', 40),
  ('collision', 'bodyshop', 'Collision and accident repair', 'Repairs after a collision, including frame and structural work, with or without an insurance claim.', 10),
  ('dents_scratches', 'bodyshop', 'Dents, scratches and bumpers', 'Dent repair, paintless dent repair, scratch repair, bumper repair and hail damage.', 20),
  ('paint_rust', 'bodyshop', 'Painting and rust repair', 'Panel and full painting, paint matching and rust repair.', 30),
  ('glass', 'bodyshop', 'Windshield repair', 'Chips and cracks in the windshield repaired.', 40);

-- rental terms: what each lists (the classes and body styles of our cars, the partner flags) and its landing page
insert into place_terms (slug, vertical, phrase, title, match, served, landing_slug, intent_note, sort_order) values
  ('car-rental', 'rental', 'car rental', 'Car Rental', '{}', 'yes', 'toronto', 'Rent by the day, the week or up to {{maxDays}} days at a time. Drivers {{minAge}} and older with an Ontario {{licence}} licence can rent.', 10),
  ('rent-a-car', 'rental', 'rent a car', 'Rent a Car', '{}', 'yes', 'toronto', 'Choose a car, send a request with no payment, and pay only once we confirm the car and the price.', 20),
  ('car-hire', 'rental', 'car hire', 'Car Hire', '{}', 'yes', 'toronto', 'Car hire with CarmaCars works by request: you choose the car and dates, and we confirm the full price before you pay.', 30),
  ('cars-for-hire', 'rental', 'cars for hire', 'Cars for Hire', '{}', 'yes', 'toronto', 'Every car for hire shows its own photos, calendar, rates, deposit and kilometres included.', 40),
  ('vehicle-rental', 'rental', 'vehicle rental', 'Vehicle Rental', '{}', 'yes', 'toronto', 'Each vehicle has its own page with its real rates and its calendar.', 50),
  ('auto-rental', 'rental', 'auto rental', 'Auto Rental', '{}', 'yes', 'toronto', 'Third-party liability coverage is included in every rate; for damage to the car you choose one of three options before pickup.', 60),
  ('rental-cars', 'rental', 'rental cars', 'Rental Cars', '{}', 'yes', 'toronto', 'The rental cars below are the ones in our fleet now, cheapest first, with the price each one shows today.', 70),
  ('cheap-car-rental', 'rental', 'cheap car rental', 'Cheap Car Rental', '{"classes": ["economy", "standard"]}', 'yes', 'economy', 'The lowest daily rates in our fleet are on the economy and standard cars. Trips of {{weekFrom}} days or more use the weekly rate.', 80),
  ('luxury-car-rental', 'rental', 'luxury car rental', 'Luxury Car Rental', '{"classes": ["premium", "luxury", "exotic"]}', 'yes', 'luxury', 'Premium, luxury and exotic cars, each with photos of that car, its rates and its deposit.', 90),
  ('exotic-car-rental', 'rental', 'exotic car rental', 'Exotic Car Rental', '{"classes": ["exotic"]}', 'yes', 'exotic', 'Exotic cars carry a higher deposit, shown on each car''s page and taken about {{depLead}} before pickup, never when you book.', 100),
  ('suv-rental', 'rental', 'SUV rental', 'SUV Rental', '{"any": [{"classes": ["suv"]}, {"bodies": ["suv"]}]}', 'yes', 'suv', 'SUVs for families, luggage and winter roads. Winter tires are available as an add-on.', 110),
  ('van-rental', 'rental', 'van rental', 'Van Rental', '{"any": [{"classes": ["van"]}, {"bodies": ["van"]}, {"seats_min": 7}]}', 'yes', 'minivan', 'Vans and seven-seat cars for groups, moves and airport runs with luggage.', 120),
  ('minivan-rental', 'rental', 'minivan rental', 'Minivan Rental', '{"any": [{"classes": ["van"]}, {"bodies": ["minivan", "van"]}, {"seats_min": 7}]}', 'yes', 'minivan', 'Minivans with seven or more seats, one car instead of two for a family trip.', 130),
  ('truck-rental', 'rental', 'truck rental', 'Truck Rental', '{"any": [{"classes": ["pickup"]}, {"bodies": ["pickup", "truck"]}]}', 'yes', null, 'Pickup trucks are listed here when one is in our fleet. Tell us what you need to move and we will suggest a car.', 140),
  ('convertible-rental', 'rental', 'convertible rental', 'Convertible Rental', '{"any": [{"classes": ["convertible"]}, {"bodies": ["convertible", "cabriolet", "spyder", "spider", "roadster"]}]}', 'yes', 'convertible', 'Convertibles for summer drives. Each car''s page shows its seats and its luggage space.', 150),
  ('monthly-car-rental', 'rental', 'monthly car rental', 'Monthly Car Rental', '{}', 'yes', 'monthly', 'One booking runs up to {{maxDays}} days and renews with a new agreement. A trip of {{weekFrom}} to {{maxDaysLess1}} days never costs more than the car''s monthly rate.', 160),
  ('long-term-car-rental', 'rental', 'long term car rental', 'Long Term Car Rental', '{}', 'yes', 'monthly', 'For longer stays, renew month after month: the deposit carries over to the next agreement.', 170),
  ('weekly-car-rental', 'rental', 'weekly car rental', 'Weekly Car Rental', '{}', 'yes', 'weekly', 'Trips of {{weekFrom}} days or more use the weekly rate, and shorter trips never cost more than it.', 180),
  ('weekend-car-rental', 'rental', 'weekend car rental', 'Weekend Car Rental', '{}', 'yes', 'weekend', 'A rental day that starts on a Friday or a Saturday uses the car''s weekend day rate.', 190),
  ('one-way-car-rental', 'rental', 'one way car rental', 'One Way Car Rental', '{}', 'yes', 'car-delivery', 'We deliver the car to one address and can collect it from another within our delivery area, each for the car''s delivery and return pickup fees.', 200),
  ('airport-car-rental', 'rental', 'airport car rental', 'Airport Car Rental', '{}', 'yes', 'airport', 'We meet you with the car at Toronto Pearson or Billy Bishop at the time we confirm. There is no counter.', 210),
  ('insurance-replacement-rental', 'rental', 'insurance replacement rental', 'Insurance Replacement Rental', '{}', 'yes', 'insurance-replacement', 'When your adjuster approves a rental, we can bill your insurance company directly, and we deliver the car to you.', 220),
  ('collision-replacement-car', 'rental', 'collision replacement car', 'Collision Replacement Car', '{}', 'yes', 'insurance-replacement', 'A car while yours is repaired after a collision, billed to your insurer when your adjuster approves it.', 230),
  ('car-rental-near-me', 'rental', 'car rental near me', 'Car Rental Near Me', '{}', 'yes', 'car-delivery', 'We bring the car to you: to a home, condo, hotel or office, for the delivery fee shown on each car''s page.', 240),
  ('car-rental-delivery', 'rental', 'car rental delivery', 'Car Rental Delivery', '{}', 'yes', 'car-delivery', 'Delivery to your address and collection at the end, or pickup from our location at no charge.', 250),
  ('car-rental-under-25', 'rental', 'car rental under 25', 'Car Rental Under 25', '{}', 'yes', 'under-25', 'Drivers {{minAge}} and older can rent; drivers under {{fullAge}} pay a young driver fee for each day, shown on each car''s page.', 260),
  ('car-rental-18-year-old', 'rental', 'car rental 18 year old', 'Car Rental at 18', '{"young": true}', 'yes', 'young-drivers', 'The cars listed here take drivers aged {{youngA}}, with an Ontario {{licence}} licence and a young driver fee for each day.', 270),
  ('car-rental-no-credit-card', 'rental', 'car rental no credit card', 'Car Rental With No Credit Card', '{"flags": ["no_credit_card"]}', 'yes', 'no-credit-card', 'Only the cars marked "no credit card needed" are listed: a debit card in your name pays and holds the deposit on those cars.', 280),
  ('car-rental-with-insurance-included', 'rental', 'car rental with insurance included', 'Car Rental With the Car''s Insurance', '{"flags": ["insurance_included"]}', 'yes', 'insurance-included', 'Only the cars whose owner''s insurance comes with the car are listed: you need no auto policy of your own for those cars.', 290),
  ('chauffeur-service', 'rental', 'chauffeur service', 'Chauffeur Service', '{}', 'request', null, 'We do not offer a chauffeur service ourselves. Tell us the date and the trip, and we will tell you what we can arrange.', 300),
  ('car-with-driver', 'rental', 'car with driver', 'Car With Driver', '{}', 'request', null, 'A car with a driver is not something we offer directly. Send us the details and we will reply with what is possible.', 310);
update place_terms set lead_kind = 'place_request' where vertical = 'rental' and served = 'request';

-- buying help: never a dealer, lender or leasing company; a request the team answers
insert into place_terms (slug, vertical, phrase, title, served, lead_kind, intent_note, sort_order) values
  ('cars-for-sale', 'sale', 'cars for sale', 'Cars for Sale', 'request', 'buyer', 'We do not sell cars. Tell us the car you are looking for and we will help where we can, and you can rent a similar car first.', 10),
  ('used-cars', 'sale', 'used cars', 'Used Cars', 'request', 'buyer', 'Renting the same model for a week before you buy shows you how it fits your commute, your parking and your family.', 20),
  ('used-cars-for-sale', 'sale', 'used cars for sale', 'Used Cars for Sale', 'request', 'buyer', 'We are not a dealer. Tell us the make, model and budget you have in mind and we will help where we can.', 30),
  ('buy-a-car', 'sale', 'buy a car', 'Buy a Car', 'request', 'buyer', 'Before you buy, rent the model you are considering and drive it on your own roads for a few days.', 40),
  ('car-dealership', 'sale', 'car dealership', 'Car Dealership', 'request', 'buyer', 'CarmaCars is not a dealership. We rent cars and can help you try a model before you shop for one.', 50),
  ('car-financing', 'sale', 'car financing', 'Car Financing', 'request', 'finance', 'We are not a lender and do not arrange loans. Tell us what you need and we will help where we can.', 60),
  ('auto-loans', 'sale', 'auto loans', 'Auto Loans', 'request', 'finance', 'We do not lend money. Renting by the month can bridge the time while you arrange a loan with your bank or a lender.', 70),
  ('bad-credit-car-loans', 'sale', 'bad credit car loans', 'Bad Credit Car Loans', 'request', 'finance', 'We do not lend money or check credit for loans. A monthly rental is one way to have a car while you rebuild your credit.', 80),
  ('car-leasing', 'sale', 'car leasing', 'Car Leasing', 'request', 'finance', 'We do not lease cars. A monthly rental has no long-term contract: each booking runs up to {{maxDays}} days.', 90),
  ('lease-a-car', 'sale', 'lease a car', 'Lease a Car', 'request', 'finance', 'We are not a leasing company. Compare a lease with renting month to month, which you can stop at the end of any booking.', 100),
  ('lease-takeover', 'sale', 'lease takeover', 'Lease Takeover', 'request', 'finance', 'We do not arrange lease takeovers. A monthly rental can cover the weeks while a takeover is completed.', 110),
  ('certified-pre-owned', 'sale', 'certified pre-owned', 'Certified Pre-Owned', 'request', 'buyer', 'We do not sell certified pre-owned cars. Rent the model first, then shop for one with confidence.', 120),
  ('sell-my-car', 'sale', 'sell my car', 'Sell My Car', 'request', 'buyer', 'We do not buy cars. If you would rather keep your car and have it earn, our owner program rents it out for you.', 130),
  ('trade-in', 'sale', 'trade in', 'Trade In', 'request', 'buyer', 'We do not take trade-ins. If you are between cars, rent one by the week or the month while you decide.', 140);

-- detailing and body shop: each term with its service
insert into place_terms (slug, vertical, phrase, title, served, service_code, lead_kind, intent_note, sort_order)
select x.slug, 'detailing', x.phrase, x.title, 'yes', x.svc, 'detailing', x.note, x.o * 10 from (values
  ('car-detailing', 'car detailing', 'Car Detailing', 'detailing', 'A full detail inside and out, an interior or an exterior detail, a hand wash or a wax.', 1),
  ('auto-detailing', 'auto detailing', 'Auto Detailing', 'detailing', 'Interior and exterior detailing, done by hand.', 2),
  ('mobile-detailing', 'mobile detailing', 'Mobile Detailing', 'mobile', 'We come to your home or office and detail the car there.', 3),
  ('car-wash', 'car wash', 'Car Wash', 'detailing', 'A hand wash of the outside of the car, on its own or as part of a detail.', 4),
  ('hand-car-wash', 'hand car wash', 'Hand Car Wash', 'detailing', 'Washed by hand, not by a machine.', 5),
  ('interior-detailing', 'interior detailing', 'Interior Detailing', 'detailing', 'Seats, carpets, mats, dashboard and windows cleaned inside.', 6),
  ('exterior-detailing', 'exterior detailing', 'Exterior Detailing', 'detailing', 'The paint, wheels, tires, glass and trim cleaned and protected.', 7),
  ('full-detail', 'full detail', 'Full Detail', 'detailing', 'The interior and the exterior together.', 8),
  ('car-cleaning', 'car cleaning', 'Car Cleaning', 'detailing', 'A thorough clean of the car, inside, outside or both.', 9),
  ('steam-cleaning', 'steam cleaning', 'Steam Cleaning', 'detailing', 'Steam for upholstery, carpets and hard-to-reach parts of the interior.', 10),
  ('odour-removal', 'odour removal', 'Odour Removal', 'detailing', 'Interior cleaning aimed at smoke, pet and food odours.', 11),
  ('headlight-restoration', 'headlight restoration', 'Headlight Restoration', 'detailing', 'Cloudy or yellowed headlight lenses polished clear.', 12),
  ('paint-correction', 'paint correction', 'Paint Correction', 'correction_coating', 'Machine polishing that removes swirls and light scratches from the paint.', 13),
  ('polishing', 'polishing', 'Car Polishing', 'correction_coating', 'Polishing the paint to restore its gloss.', 14),
  ('buffing', 'buffing', 'Car Buffing', 'correction_coating', 'Buffing the paint by machine, usually before a wax or a coating.', 15),
  ('ceramic-coating', 'ceramic coating', 'Ceramic Coating', 'correction_coating', 'A ceramic coating over corrected paint, for gloss and easier washing.', 16),
  ('ppf', 'PPF', 'PPF', 'tint_ppf_wrap', 'Paint protection film on the parts of the car that take stone chips.', 17),
  ('paint-protection-film', 'paint protection film', 'Paint Protection Film', 'tint_ppf_wrap', 'A clear film that protects the paint from chips and scratches.', 18),
  ('clear-bra', 'clear bra', 'Clear Bra', 'tint_ppf_wrap', 'Clear bra is another name for paint protection film on the front of the car.', 19),
  ('window-tint', 'window tint', 'Window Tint', 'tint_ppf_wrap', 'Window tint film, applied within the rules for tinted windows where you drive.', 20),
  ('car-wrap', 'car wrap', 'Car Wrap', 'tint_ppf_wrap', 'A vinyl wrap that changes the colour or finish of the car and protects the paint under it.', 21),
  ('vinyl-wrap', 'vinyl wrap', 'Vinyl Wrap', 'tint_ppf_wrap', 'Vinyl wrap for the whole car or parts of it, such as the roof or the mirrors.', 22),
  ('wax', 'wax', 'Car Wax', 'detailing', 'A hand wax after a wash, for shine and a layer of protection.', 23),
  ('engine-bay-cleaning', 'engine bay cleaning', 'Engine Bay Cleaning', 'detailing', 'The engine bay cleaned and dressed with care around the electrical parts.', 24),
  ('pet-hair-removal', 'pet hair removal', 'Pet Hair Removal', 'detailing', 'Pet hair removed from seats, carpets and the cargo area.', 25),
  ('upholstery-cleaning', 'upholstery cleaning', 'Upholstery Cleaning', 'detailing', 'Cloth seats and carpets shampooed and extracted.', 26),
  ('leather-conditioning', 'leather conditioning', 'Leather Conditioning', 'detailing', 'Leather seats cleaned and conditioned.', 27)) x(slug, phrase, title, svc, note, o);

insert into place_terms (slug, vertical, phrase, title, served, service_code, lead_kind, intent_note, sort_order)
select x.slug, 'bodyshop', x.phrase, x.title, 'yes', x.svc, 'bodyshop', x.note, x.o * 10 from (values
  ('auto-body-shop', 'auto body shop', 'Auto Body Shop', 'collision', 'Collision repair, dents, scratches, painting and windshield repair, with a car to drive while yours is fixed.', 1),
  ('body-shop', 'body shop', 'Body Shop', 'collision', 'Body work of every size, from a scratch to a collision repair.', 2),
  ('collision-repair', 'collision repair', 'Collision Repair', 'collision', 'Repairs after a collision, with or without an insurance claim.', 3),
  ('collision-centre', 'collision centre', 'Collision Centre', 'collision', 'Collision repair, and a rental car delivered to you while yours is repaired.', 4),
  ('collision-center', 'collision center', 'Collision Center', 'collision', 'Collision repair, and a rental car delivered to you while yours is repaired.', 5),
  ('accident-repair', 'accident repair', 'Accident Repair', 'collision', 'Repairs after an accident, and help with the insurance claim paperwork we handle for repairs.', 6),
  ('auto-body-repair', 'auto body repair', 'Auto Body Repair', 'collision', 'Body panels, bumpers and paint repaired.', 7),
  ('car-body-repair', 'car body repair', 'Car Body Repair', 'collision', 'Dents, scratches, bumpers and panels repaired.', 8),
  ('frame-repair', 'frame repair', 'Frame Repair', 'collision', 'Frame and structural repairs after a collision.', 9),
  ('insurance-claim-repair', 'insurance claim repair', 'Insurance Claim Repair', 'collision', 'Repairs paid through your insurance claim, and a replacement rental your insurer may cover.', 10),
  ('dent-repair', 'dent repair', 'Dent Repair', 'dents_scratches', 'Dents repaired and the panel refinished when needed.', 11),
  ('paintless-dent-repair', 'paintless dent repair', 'Paintless Dent Repair', 'dents_scratches', 'Small dents pushed out from behind the panel when the paint is not broken.', 12),
  ('scratch-repair', 'scratch repair', 'Scratch Repair', 'dents_scratches', 'Scratches polished out or repainted, depending on their depth.', 13),
  ('bumper-repair', 'bumper repair', 'Bumper Repair', 'dents_scratches', 'Bumper cracks, scuffs and dents repaired or the bumper replaced.', 14),
  ('hail-damage-repair', 'hail damage repair', 'Hail Damage Repair', 'dents_scratches', 'Hail dents repaired, often without repainting.', 15),
  ('car-painting', 'car painting', 'Car Painting', 'paint_rust', 'A panel or the whole car painted, matched to the original colour.', 16),
  ('auto-paint', 'auto paint', 'Auto Paint', 'paint_rust', 'Paint repair and refinishing.', 17),
  ('paint-touch-up', 'paint touch up', 'Paint Touch Up', 'paint_rust', 'Chips and small scratches touched up.', 18),
  ('rust-repair', 'rust repair', 'Rust Repair', 'paint_rust', 'Rust cut out or treated, then the area refinished.', 19),
  ('windshield-repair', 'windshield repair', 'Windshield Repair', 'glass', 'Chips and small cracks in the windshield repaired.', 20)) x(slug, phrase, title, svc, note, o);

-- ================================================================ 5. hubs: the public reads
-- where a distance is measured from: our location (Program settings) or, until it is set, central Toronto
create or replace function app.place_origin() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when s.company_latitude is not null and s.company_longitude is not null
              then jsonb_build_object('lat', s.company_latitude, 'lng', s.company_longitude, 'label', 'our location')
              else jsonb_build_object('lat', 43.6532, 'lng', -79.3832, 'label', 'central Toronto') end
    from (select (app.settings()).*) s
$$;

create or replace function app.place_enabled(p places) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p.is_active and case when p.kind = 1 then exists (select 1 from place_regions r where r.country = p.country and r.is_enabled)
                              else coalesce((select r.is_enabled from place_regions r where r.id = p.region_id), false) end
$$;

create or replace function app.place_km(p places) returns numeric
language sql stable security definer set search_path = public, app as $$
  select case when p.lat is not null and p.kind not in (1, 2)
              then round(app.distance_km((o ->> 'lat')::numeric, (o ->> 'lng')::numeric, p.lat::numeric, p.lng::numeric), 0) end
    from (select app.place_origin() o) x
$$;

-- the lowest delivery fee of our real cars (cached for the request by the planner as a stable call)
create or replace function app.place_base_delivery_cents() returns bigint
language sql stable security definer set search_path = public, app as $$
  select min(rc.delivery_fee_cents)
    from vehicles v join vehicle_listings l on l.vehicle_id = v.id and l.status = 'published'
    join rate_cards rc on rc.vehicle_id = v.id and rc.effective_from <= now() and (rc.effective_to is null or rc.effective_to > now())
   where not v.is_sample and v.management_mode <> 'turo_only' and rc.delivery_fee_cents is not null
$$;

-- delivery to a place from our lowest real delivery fee and the per-kilometre rule (as app.delivery_fee counts it),
-- only within the delivery reach; an airport's own surcharge
create or replace function app.place_delivery(p places) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_km numeric := app.place_km(p);
  v_base bigint;
  v_fee bigint;
  v_sur bigint;
begin
  if v_km is null or v_km > s.place_delivery_reach_km then
    return jsonb_build_object('in_reach', false, 'km', v_km, 'reach_km', s.place_delivery_reach_km);
  end if;
  v_base := app.place_base_delivery_cents();
  if p.kind = 7 and p.iata is not null then select a.surcharge_cents into v_sur from airports a where a.is_active and a.code = p.iata; end if;
  if v_base is not null then
    v_fee := v_base;
    if s.delivery_per_km_cents > 0 then
      v_fee := v_base + round(s.delivery_per_km_cents * v_km)::bigint;
      if s.delivery_min_cents is not null then v_fee := greatest(v_fee, s.delivery_min_cents); end if;
      if s.delivery_max_cents is not null then v_fee := least(v_fee, s.delivery_max_cents); end if;
      v_fee := (round(v_fee::numeric / s.delivery_round_cents) * s.delivery_round_cents)::bigint;
    end if;
    v_fee := v_fee + coalesce(v_sur, 0);
  end if;
  return jsonb_build_object('in_reach', true, 'km', v_km, 'reach_km', s.place_delivery_reach_km, 'fee_from_cents', v_fee, 'per_km_cents', s.delivery_per_km_cents);
end $$;

create or replace function app.place_hub_path(p_vertical text, p_term text, p_place text) returns text
language sql immutable as $$
  select case p_vertical
    when 'rental' then case when p_term = 'car-rental' then '/car-rental/' || p_place else '/car-rental/' || p_term || '/' || p_place end
    when 'sale' then '/buy/' || p_term || '/' || p_place
    when 'bodyshop' then '/body-shop/' || p_term || '/' || p_place
    else '/detailing/' || p_term || '/' || p_place end
$$;

-- may this hub be indexed: its tier's switch, its region, the term is its own (not a synonym pointing elsewhere), and
-- with the quality gate on: within the delivery reach, and for rental a real matching car
create or replace function app.place_hub_indexable(p places, t place_terms, p_in_reach boolean, p_real_cars integer) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.place_enabled(p) and t.is_active and t.canonical_slug is null and p.kind <> 8
     and case t.vertical when 'rental' then s.place_hubs_index when 'sale' then s.sale_hubs_index when 'bodyshop' then s.bodyshop_hubs_index else s.detailing_hubs_index end
     and (not s.place_quality_gate
          or ((p.kind in (1, 2, 4) or coalesce(p_in_reach, false))
              and (t.vertical <> 'rental' or t.served = 'request' or coalesce(p_real_cars, 0) >= 1)))
    from (select (app.settings()).*) s
$$;

create or replace function app.place_brief(p places) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('slug', p.slug, 'kind', app.place_kind(p.kind), 'name', p.name, 'country', p.country,
                            'region', (select r.code from place_regions r where r.id = p.region_id), 'region_name', (select r.name from place_regions r where r.id = p.region_id))
$$;

-- One hub: the term, the place and its family, the distance and delivery, the nearest airport, the landmarks near
-- it, the live cars (the term's for rental, the cheapest for the others), and whether it may be indexed. Null when
-- the place or the term is unknown or inactive, or the region is switched off.
create or replace function app.public_place_hub(p_vertical text, p_term text, p_place text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  p places;
  t place_terms;
  s program_settings := app.settings();
  v_delivery jsonb;
  v_cars jsonb;
  v_counts jsonb;
  v_real integer;
  v_anc jsonb := '[]'::jsonb;
  q places;
  q_t place_terms;
  v_sib integer;
begin
  select * into p from places where slug = lower(btrim(p_place)) order by id limit 1;
  select * into t from place_terms where slug = lower(btrim(p_term)) and vertical = p_vertical and is_active;
  if p.id is null or t.slug is null or not app.place_enabled(p) then return null; end if;
  v_delivery := app.place_delivery(p);
  q := p;
  for i in 1 .. 8 loop
    exit when q.parent_id is null;
    select * into q from places where id = q.parent_id;
    exit when q.id is null;
    v_anc := jsonb_build_array(app.place_brief(q)) || v_anc;
  end loop;
  -- the term's cars (rental), or for the other families the cars of the rental offer they lead to (snapshot, else live)
  if t.vertical = 'rental' then q_t := t;
  else select * into q_t from place_terms x where x.slug = case when t.vertical = 'bodyshop' then 'insurance-replacement-rental' else 'car-rental' end;
  end if;
  if q_t.cars_snapshot is not null and q_t.snapshot_stamp = app.seo_fleet_stamp() then
    v_cars := q_t.cars_snapshot -> 'cars'; v_counts := q_t.cars_snapshot -> 'counts';
  else
    select coalesce(jsonb_agg(r order by (r ->> 'daily_rate_cents')::bigint nulls last), '[]'::jsonb) into v_cars from app.public_fleet('{}'::jsonb) r where app.seo_match(r, coalesce(q_t.match, '{}'::jsonb));
    v_counts := app.seo_counts_of(v_cars);
  end if;
  v_cars := (select coalesce(jsonb_agg(e.v order by e.n), '[]'::jsonb) from jsonb_array_elements(coalesce(v_cars, '[]'::jsonb)) with ordinality e(v, n) where e.n <= case when t.vertical = 'rental' then 12 else 6 end);
  if t.vertical = 'rental' then v_real := app.seo_real_count(t.match); end if;
  -- the places around: siblings under the same parent, nearest first (neighbourhoods: of the same city)
  v_sib := coalesce(p.parent_id, -1);
  return jsonb_build_object(
    'term', jsonb_build_object('slug', t.slug, 'vertical', t.vertical, 'phrase', t.phrase, 'title', t.title, 'served', t.served, 'landing_slug', t.landing_slug,
                               'lead_kind', t.lead_kind, 'service_code', t.service_code, 'intent_note', t.intent_note, 'faq', t.faq,
                               'canonical_path', case when t.canonical_slug is not null then app.place_hub_path(t.vertical, t.canonical_slug, p.slug) end,
                               'landing_path', case when t.landing_slug is not null and exists (select 1 from seo_pages sp where sp.slug = t.landing_slug and app.seo_page_indexable(sp)) then app.seo_page_path(t.landing_slug) end),
    'place', app.place_brief(p) || jsonb_build_object('lat', p.lat, 'lng', p.lng, 'gta', p.flags & 1 <> 0, 'landing_slug', p.landing_slug, 'iata', p.iata,
                               'sources', jsonb_strip_nulls(jsonb_build_object('geonames', nullif(p.flags & 2 <> 0, false), 'osm', nullif(p.flags & 4 <> 0, false),
                                                                             'census', nullif(p.flags & 8 <> 0, false), 'fixture', nullif(p.flags & 32 <> 0, false)))),
    'path', app.place_hub_path(t.vertical, t.slug, p.slug),
    'ancestors', v_anc,
    'children', (select coalesce(jsonb_agg(app.place_brief(c) order by c.population desc nulls last, c.name), '[]'::jsonb)
                   from (select * from places c where c.parent_id = p.id and c.kind <> 8 and c.is_active order by c.population desc nulls last, c.name limit 30) c),
    'gta_members', case when p.slug = 'gta' then (select coalesce(jsonb_agg(app.place_brief(c) order by c.population desc nulls last), '[]'::jsonb)
                   from (select * from places c where c.flags & 1 <> 0 and c.kind = 5 and c.is_active order by c.population desc nulls last limit 30) c) end,
    'nearby', case when p.lat is not null and p.kind in (5, 6, 7) then
                (select coalesce(jsonb_agg(n.j order by n.d), '[]'::jsonb)
                   from (select app.place_brief(c) || jsonb_build_object('km', round(app.distance_km(p.lat::numeric, p.lng::numeric, c.lat::numeric, c.lng::numeric), 0)) as j,
                                (c.lat - p.lat) ^ 2 + ((c.lng - p.lng) * cos(radians(p.lat))) ^ 2 as d from places c
                          where c.parent_id = v_sib and c.id <> p.id and c.is_active and c.kind = case when p.kind = 6 then 6 else 5 end and c.lat is not null
                          order by 2 limit 8) n) else '[]'::jsonb end,
    'landmarks', case when p.kind in (5, 6) then
                (select coalesce(jsonb_agg(jsonb_build_object('name', l.name, 'km', l.km) order by l.km), '[]'::jsonb)
                   from (select c.name, round(app.distance_km(p.lat::numeric, p.lng::numeric, c.lat::numeric, c.lng::numeric), 1) as km from places c
                          where c.parent_id = p.id and c.kind = 8 and c.is_active order by c.population desc nulls last, c.name limit 6) l) else '[]'::jsonb end,
    'airport', case when p.lat is not null and p.kind not in (1, 2, 7) then
                (select jsonb_build_object('name', a.name, 'iata', a.iata, 'slug', a.slug, 'km', round(app.distance_km(p.lat::numeric, p.lng::numeric, a.lat::numeric, a.lng::numeric), 0))
                   from places a where a.kind = 7 and a.is_active and a.lat between p.lat - 3 and p.lat + 3
                  order by (a.lat - p.lat) ^ 2 + ((a.lng - p.lng) * cos(radians(p.lat))) ^ 2 limit 1) end,
    'origin', app.place_origin(),
    'delivery', v_delivery,
    'cars', coalesce(v_cars, '[]'::jsonb),
    'counts', coalesce(v_counts, app.seo_counts_of('[]'::jsonb)),
    'real_cars', v_real,
    'disclaimer', case when t.vertical = 'sale' then s.sale_disclaimer end,
    'service', case when t.service_code is not null then (select jsonb_build_object('code', d.code, 'name', d.name, 'description', d.description, 'from_price_cents', d.from_price_cents)
                                                           from shop_services d where d.code = t.service_code and d.is_active) end,
    'related_terms', (select coalesce(jsonb_agg(jsonb_build_object('slug', x.slug, 'title', x.title, 'path', app.place_hub_path(x.vertical, x.slug, p.slug)) order by x.sort_order), '[]'::jsonb)
                        from (select * from place_terms x where x.vertical = t.vertical and x.is_active and x.slug <> t.slug and x.canonical_slug is null order by x.sort_order limit 12) x),
    'rental_terms', case when t.vertical <> 'rental' then (select coalesce(jsonb_agg(jsonb_build_object('slug', x.slug, 'title', x.title, 'path', app.place_hub_path('rental', x.slug, p.slug)) order by x.sort_order), '[]'::jsonb)
                        from (select * from place_terms x where x.vertical = 'rental' and x.is_active and x.served = 'yes'
                                and x.slug = any (case when t.vertical = 'bodyshop' then array['insurance-replacement-rental', 'collision-replacement-car', 'car-rental-delivery', 'car-rental']
                                                       else array['car-rental', 'car-rental-delivery', 'weekly-car-rental', 'monthly-car-rental'] end) order by x.sort_order) x) end,
    'indexable', app.place_hub_indexable(p, t, coalesce((v_delivery ->> 'in_reach')::boolean, false), v_real),
    'lastmod', greatest(p.updated_on::timestamptz, t.updated_at, t.cars_changed_at));
end $$;

create or replace function public.place_hub(p_vertical text, p_term text, p_place text) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.public_place_hub(p_vertical, p_term, p_place) $$;

-- the entry points: countries, provinces and states, the GTA, the largest cities near us (the /car-rental hub)
create or replace function public.place_roots() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'tops', (select coalesce(jsonb_agg(app.place_brief(p) order by p.kind, (select r.sort_order from place_regions r where r.id = p.region_id) nulls first, p.name), '[]'::jsonb)
               from places p where (p.kind in (1, 4) or (p.kind = 2 and p.country = 'CA')) and app.place_enabled(p)),
    'cities', (select coalesce(jsonb_agg(app.place_brief(c) order by c.population desc nulls last), '[]'::jsonb)
                 from (select * from places c where c.kind = 5 and c.flags & 1 <> 0 and c.landing_slug is null and c.is_active order by c.population desc nulls last limit 24) c),
    'attribution', jsonb_build_object('geonames', exists (select 1 from places where flags & 34 <> 0), 'osm', exists (select 1 from places where flags & 4 <> 0)))
$$;

-- every active term (for links between the landing pages and the place pages, and for the vehicle pages)
create or replace function public.place_terms_public() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('slug', t.slug, 'vertical', t.vertical, 'phrase', t.phrase, 'title', t.title, 'landing_slug', t.landing_slug, 'service_code', t.service_code)
                            order by t.vertical, t.sort_order), '[]'::jsonb)
    from place_terms t where t.is_active and t.canonical_slug is null
$$;

-- which of these slugs are places with pages (the landing pages link to place pages only once the place is loaded)
create or replace function public.places_known(p_slugs text[]) returns text[]
language sql stable security definer set search_path = public, app as $$
  select coalesce(array_agg(p.slug), '{}') from places p where p.slug = any (p_slugs) and app.place_enabled(p)
$$;

-- the service pages (/detailing, /body-shop)
create or replace function public.shop_services_public(p_vertical text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'services', (select coalesce(jsonb_agg(jsonb_build_object('code', d.code, 'name', d.name, 'description', d.description, 'from_price_cents', d.from_price_cents,
                   'terms', (select coalesce(jsonb_agg(jsonb_build_object('slug', t.slug, 'title', t.title) order by t.sort_order), '[]'::jsonb) from place_terms t where t.service_code = d.code and t.is_active))
                   order by d.sort_order), '[]'::jsonb) from shop_services d where d.is_active and d.vertical = p_vertical),
    'reach_km', (app.settings()).place_delivery_reach_km,
    'origin', app.place_origin())
$$;

-- The sitemaps of the hubs: per term, files of place_sitemap_file_urls places by id range (a primary key range scan;
-- no page is rendered). A base rental page of a place with a landing page is that landing page (in its own sitemap);
-- a term whose landing page is Toronto-wide sends Toronto's page there.
create or replace function public.place_sitemap_files() returns jsonb
language sql stable security definer set search_path = public, app as $$
  with s as (select (app.settings()).*),
       mx as (select coalesce(max(id), 0) as m from places),
       tm as (select t.vertical, t.slug, t.updated_at, t.cars_changed_at from place_terms t, s
               where t.is_active and t.canonical_slug is null
                 and case t.vertical when 'rental' then s.place_hubs_index when 'sale' then s.sale_hubs_index when 'bodyshop' then s.bodyshop_hubs_index else s.detailing_hubs_index end
                 and (not s.place_quality_gate or t.vertical <> 'rental' or t.served = 'request' or app.seo_real_count(t.match) >= 1))
  select coalesce(jsonb_agg(jsonb_build_object('file', tm.vertical || '.' || tm.slug || '.' || g, 'vertical', tm.vertical, 'term', tm.slug, 'page', g,
                                               'lastmod', greatest(tm.updated_at, tm.cars_changed_at)) order by tm.vertical, tm.slug, g), '[]'::jsonb)
    from tm, mx, s, generate_series(1, greatest(1, ceil(mx.m::numeric / s.place_sitemap_file_urls)::integer)) g
$$;

create or replace function public.place_sitemap(p_vertical text, p_term text, p_page integer) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with s as (select (app.settings()).*),
       t as (select * from place_terms where slug = p_term and vertical = p_vertical and is_active and canonical_slug is null),
       o as (select app.place_origin() o),
       en as (select id from place_regions where is_enabled)
  select coalesce(jsonb_agg(jsonb_build_object('path', app.place_hub_path(t.vertical, t.slug, p.slug), 'lastmod', p.updated_on) order by p.id), '[]'::jsonb)
    from s, t, o, places p
   where p.id > (greatest(p_page, 1) - 1) * s.place_sitemap_file_urls and p.id <= greatest(p_page, 1) * s.place_sitemap_file_urls
     and p.is_active and p.kind <> 8 and (p.region_id in (select id from en) or (p.kind = 1 and exists (select 1 from place_regions r where r.country = p.country and r.is_enabled)))
     and not (t.vertical = 'rental' and t.slug = 'car-rental' and p.landing_slug is not null)
     and not (t.vertical = 'rental' and t.landing_slug is not null and p.slug = 'toronto')
     and (not s.place_quality_gate or p.kind in (1, 2, 4)
          or app.distance_km((o.o ->> 'lat')::numeric, (o.o ->> 'lng')::numeric, p.lat::numeric, p.lng::numeric) <= s.place_delivery_reach_km)
$$;

-- ================================================================ 6. requests from the hubs and the service pages
do $$
declare
  d text;
  v text[];
  k text;
begin
  select pg_get_constraintdef(oid) into d from pg_constraint where conrelid = 'leads'::regclass and conname = 'leads_kind_check';
  select array_agg(m[1]) into v from regexp_matches(coalesce(d, ''), '''([a-z_]+)''', 'g') m;
  if v is null then v := array['owner_program', 'contact', 'insurer', 'launch_notice', 'other']; end if;
  foreach k in array array['buyer', 'finance', 'place_request', 'detailing', 'bodyshop'] loop
    if not k = any (v) then v := v || k; end if;
  end loop;
  execute 'alter table leads drop constraint if exists leads_kind_check';
  execute format('alter table leads add constraint leads_kind_check check (kind = any (%L::text[]))', v);
end $$;

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, description) values
  ('detailing_request', 'cs', 'Detailing request', 'high', 'opening_minutes', 60, 'A detailing request from /detailing or a detailing page: reply with a price and a time, and offer a rental while the car is with us (0095)'),
  ('bodyshop_request', 'cs', 'Body shop request', 'high', 'opening_minutes', 60, 'A body shop request from /body-shop or a body shop page: reply with the next step, and offer an insurance replacement rental (0095)'),
  ('buyer_lead', 'sales', 'Help finding a car to buy', 'normal', 'opening_minutes', 120, 'Someone asked for help finding a car to buy. CarmaCars does not sell cars: offer a rental of the model first and help where we can (0095)'),
  ('finance_lead', 'sales', 'Financing or lease question', 'normal', 'opening_minutes', 120, 'Someone asked about financing or leasing. CarmaCars does not lend or lease: say so, and offer a monthly rental where it helps (0095)'),
  ('place_request', 'cs', 'A car in a place we do not serve yet', 'normal', 'opening_minutes', 120, 'A request for a car outside the delivery reach, or for a service we do not offer directly (0095)')
on conflict (task_type) do nothing;

create or replace function app.submit_place_lead(p jsonb, p_ip text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid := gen_random_uuid();
  v_kind text := p ->> 'kind';
  v_email text := nullif(lower(btrim(p ->> 'email')), '');
  v_phone text := nullif(btrim(p ->> 'phone'), '');
  v_name text := nullif(btrim(p ->> 'name'), '');
  v_set program_settings := app.settings();
  v_payload jsonb := app.strip_transient(coalesce(p -> 'payload', '{}'::jsonb));
  v_task uuid;
begin
  if nullif(btrim(p_ip), '') is not null and not app.rate_limit('lead:ip:' || btrim(p_ip), v_set.lead_hourly_limit, interval '1 hour') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;
  if v_kind is null or v_kind not in ('buyer', 'finance', 'place_request', 'detailing', 'bodyshop') then
    raise exception 'Unknown kind of request: %', v_kind using errcode = '22023';
  end if;
  if v_email is null and v_phone is null then raise exception 'Give an email address or a phone number so we can reply' using errcode = '22023'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a full email address, for example name@example.com' using errcode = '22023'; end if;
  if char_length(coalesce(p ->> 'message', '')) > 2000 then raise exception 'The message is too long (2,000 characters at most)' using errcode = '22023'; end if;
  insert into leads (id, kind, name, email, phone, message, payload, source, source_url, referrer)
  values (v_id, v_kind, v_name, v_email, v_phone, nullif(btrim(p ->> 'message'), ''), v_payload, coalesce(nullif(p ->> 'source', ''), 'web'), p ->> 'source_url', p ->> 'referrer');
  v_task := app.raise_task(p_type => case v_kind when 'detailing' then 'detailing_request' when 'bodyshop' then 'bodyshop_request' when 'buyer' then 'buyer_lead'
                                                 when 'finance' then 'finance_lead' else 'place_request' end,
                           p_detail => concat_ws(' ', coalesce(v_name, 'Someone'), 'asked',
                             case v_kind when 'detailing' then 'for detailing:' when 'bodyshop' then 'for body work:' when 'buyer' then 'for help finding a car:'
                                         when 'finance' then 'about financing or leasing:' else 'for a car:' end,
                             concat_ws(', ', v_payload ->> 'service', v_payload ->> 'vehicle', v_payload ->> 'damage', v_payload ->> 'place', v_payload ->> 'date',
                                       v_payload ->> 'where', case when v_payload ->> 'insurance_claim' = 'yes' then 'insurance claim' end, v_payload ->> 'term'),
                             nullif(btrim(p ->> 'message'), '')),
                           p_related_table => 'leads', p_related_id => v_id, p_dedupe => 'lead:' || v_id);
  return jsonb_build_object('ok', true, 'lead_id', v_id);
end $$;
create or replace function public.submit_place_lead(p jsonb, p_ip text default null) returns jsonb
language sql security definer set search_path = public, app as $$ select app.submit_place_lead(p, p_ip) $$;

-- ================================================================ 7. the door: Admin > Settings > Search, places and terms
create or replace function app.place_overview(p_admin uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare s program_settings := app.settings();
begin
  perform app.assert_admin(p_admin);
  return jsonb_build_object(
    'settings', jsonb_build_object('place_hubs_index', s.place_hubs_index, 'sale_hubs_index', s.sale_hubs_index, 'detailing_hubs_index', s.detailing_hubs_index,
                                   'bodyshop_hubs_index', s.bodyshop_hubs_index, 'place_quality_gate', s.place_quality_gate, 'place_delivery_reach_km', s.place_delivery_reach_km,
                                   'place_db_cap_mb', s.place_db_cap_mb, 'sale_disclaimer', s.sale_disclaimer),
    'regions', (select coalesce(jsonb_agg(jsonb_build_object('code', r.code, 'name', r.name, 'country', r.country, 'enabled', r.is_enabled, 'places', r.places,
                                                             'loaded_at', r.loaded_at, 'skipped', r.skipped) order by r.sort_order, r.code), '[]'::jsonb) from place_regions r),
    'places', (select coalesce(jsonb_object_agg(country, k), '{}'::jsonb) from (
                 select country, jsonb_object_agg(app.place_kind(kind), n) k from (select country, kind, count(*) n from places where is_active group by country, kind) a group by country) b),
    'terms', (select coalesce(jsonb_agg(to_jsonb(t) - 'cars_snapshot' - 'snapshot_stamp' order by t.vertical, t.sort_order), '[]'::jsonb) from place_terms t),
    'services', (select coalesce(jsonb_agg(to_jsonb(d) order by d.vertical, d.sort_order), '[]'::jsonb) from shop_services d),
    'size', public.server_places_budget(),
    'imports', (select coalesce(jsonb_agg(to_jsonb(i) order by i.id desc), '[]'::jsonb) from (select * from place_imports order by id desc limit 5) i),
    'origin', app.place_origin());
end $$;

-- a term: phrase, title, the synonym it points to, its note and questions, on or off; a new term (vertical, slug)
create or replace function app.place_term_save(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_slug text := lower(btrim(p ->> 'slug'));
  t place_terms;
begin
  perform app.assert_admin(p_admin);
  if v_slug is null or v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' then raise exception 'Give the term a web address: lower case words joined by hyphens' using errcode = '22023'; end if;
  if concat_ws(' ', p ->> 'intent_note', p ->> 'title', p ->> 'phrase') ~ ('[' || chr(8210) || chr(8211) || chr(8212) || chr(8213) || ']') then raise exception 'No long dashes: use a comma, a colon or a full stop' using errcode = '22023'; end if;
  if concat_ws(' ', p ->> 'intent_note', p ->> 'title') ~* '18122211|canada inc' then raise exception 'Name CarmaCars, never the numbered company' using errcode = '22023'; end if;
  select * into t from place_terms where slug = v_slug;
  if t.slug is null then
    if coalesce(p ->> 'vertical', '') not in ('rental', 'sale', 'detailing', 'bodyshop') then raise exception 'Choose rental, buying help, detailing or body shop for a new term' using errcode = '22023'; end if;
    insert into place_terms (slug, vertical, phrase, title, served, lead_kind, service_code, intent_note, sort_order, updated_by)
    values (v_slug, p ->> 'vertical', coalesce(nullif(btrim(p ->> 'phrase'), ''), replace(v_slug, '-', ' ')), coalesce(nullif(btrim(p ->> 'title'), ''), initcap(replace(v_slug, '-', ' '))),
            case when p ->> 'vertical' = 'sale' then 'request' else coalesce(nullif(p ->> 'served', ''), 'yes') end,
            case p ->> 'vertical' when 'sale' then 'buyer' when 'detailing' then 'detailing' when 'bodyshop' then 'bodyshop' end,
            nullif(p ->> 'service_code', ''), coalesce(p ->> 'intent_note', ''), coalesce((p ->> 'sort_order')::integer, 500), p_admin);
  else
    update place_terms set phrase = coalesce(nullif(btrim(p ->> 'phrase'), ''), phrase), title = coalesce(nullif(btrim(p ->> 'title'), ''), title),
           canonical_slug = case when p ? 'canonical_slug' then nullif(btrim(p ->> 'canonical_slug'), '') else canonical_slug end,
           intent_note = coalesce(p ->> 'intent_note', intent_note), faq = coalesce(p -> 'faq', faq),
           served = case when vertical = 'sale' then 'request' else coalesce(nullif(p ->> 'served', ''), served) end,
           match = case when p ? 'match' and vertical = 'rental' then p -> 'match' else match end,
           is_active = coalesce((p ->> 'is_active')::boolean, is_active), sort_order = coalesce((p ->> 'sort_order')::integer, sort_order), updated_by = p_admin
     where slug = v_slug;
  end if;
  if (select canonical_slug from place_terms where slug = v_slug) = v_slug then raise exception 'A term cannot point to itself' using errcode = '22023'; end if;
  return (select to_jsonb(x) - 'cars_snapshot' - 'snapshot_stamp' from place_terms x where slug = v_slug);
end $$;

create or replace function app.shop_service_save(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_admin);
  update shop_services set name = coalesce(nullif(btrim(p ->> 'name'), ''), name), description = coalesce(nullif(btrim(p ->> 'description'), ''), description),
         from_price_cents = case when p ? 'from_price_cents' then nullif(p ->> 'from_price_cents', '')::bigint else from_price_cents end,
         is_active = coalesce((p ->> 'is_active')::boolean, is_active)
   where code = p ->> 'code';
  if not found then raise exception 'Unknown service' using errcode = '22023'; end if;
  return (select to_jsonb(d) from shop_services d where code = p ->> 'code');
end $$;

-- the place settings on the row in force (and any row dated later), and a region on or off
create or replace function app.place_settings_save(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_admin);
  if coalesce(p ->> 'sale_disclaimer', '') ~ ('[' || chr(8210) || chr(8211) || chr(8212) || chr(8213) || ']') then raise exception 'No long dashes in the notice' using errcode = '22023'; end if;
  if p ? 'region' then
    update place_regions set is_enabled = coalesce((p ->> 'enabled')::boolean, is_enabled) where code = upper(p ->> 'region');
    if not found then raise exception 'Unknown region %', p ->> 'region' using errcode = '22023'; end if;
  end if;
  update program_settings set
    place_hubs_index = coalesce((p ->> 'place_hubs_index')::boolean, place_hubs_index),
    sale_hubs_index = coalesce((p ->> 'sale_hubs_index')::boolean, sale_hubs_index),
    detailing_hubs_index = coalesce((p ->> 'detailing_hubs_index')::boolean, detailing_hubs_index),
    bodyshop_hubs_index = coalesce((p ->> 'bodyshop_hubs_index')::boolean, bodyshop_hubs_index),
    place_quality_gate = coalesce((p ->> 'place_quality_gate')::boolean, place_quality_gate),
    place_delivery_reach_km = coalesce((p ->> 'place_delivery_reach_km')::integer, place_delivery_reach_km),
    place_db_cap_mb = coalesce((p ->> 'place_db_cap_mb')::integer, place_db_cap_mb),
    sale_disclaimer = coalesce(nullif(btrim(p ->> 'sale_disclaimer'), ''), sale_disclaimer)
   where id = (app.settings()).id or effective_from > app.today();
  return app.place_overview(p_admin) - 'terms' - 'services' - 'imports';
end $$;

create or replace function app.places95(p_user uuid, p_call text, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  case p_name
  when 'place_overview' then return app.place_overview(p_user);
  when 'place_term_save' then return app.place_term_save(p_user, p);
  when 'shop_service_save' then return app.shop_service_save(p_user, p);
  when 'place_settings_save' then return app.place_settings_save(p_user, p);
  else raise exception 'Unknown action %', p_name using errcode = '22023';
  end case;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0095;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call = 'admin_read' and p_name = 'place_overview')
     or (p_call = 'admin_do' and p_name in ('place_term_save', 'shop_service_save', 'place_settings_save')) then
    perform app.door_begin(p_user, p_aal);
    return app.places95(p_user, p_call, p_name, coalesce(p, '{}'::jsonb));
  end if;
  return app.door_pre0095(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ 8. security, audit, privileges
do $$
declare t text;
begin
  foreach t in array array['places', 'places_staging', 'place_imports', 'place_regions', 'place_terms', 'shop_services'] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
    execute format('revoke all on %I from anon, authenticated', t);
  end loop;
  foreach t in array array['place_terms', 'shop_services', 'place_regions'] loop
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function app.audit_row()', 'audit_' || t, t);
  end loop;
end $$;

do $$
declare
  f record;
  g text;
  v_old oid := 'app.door_pre0095(uuid, text, text, text, jsonb)'::regprocedure;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['seo_match_one', 'seo_match', 'seo_real_count', 'seo_page_indexable', 'indexnow_on_page', 'seo_snapshot_refresh',
              'public_business_rating', 'place_kind', 'place_is_gta_region', 'places_import_apply', 'places_import_finish', 'place_origin', 'place_enabled', 'place_km',
              'place_base_delivery_cents', 'place_delivery', 'place_hub_path', 'place_hub_indexable', 'place_brief', 'public_place_hub', 'submit_place_lead', 'place_overview',
              'place_term_save', 'shop_service_save', 'place_settings_save', 'places95']))
        or (n.nspname = 'public' and p.proname = any (array['server_places_budget', 'server_places_import_begin', 'server_places_stage_clear', 'server_places_import_apply',
              'server_places_import_finish', 'submit_place_lead']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
  execute 'revoke all on function app.door(uuid, text, text, text, jsonb) from public, anon, authenticated';
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, v_old, 'execute') then execute format('grant execute on function app.door(uuid, text, text, text, jsonb) to %I', g); end if;
  end loop;
  revoke all on function public.business_rating(), public.place_hub(text, text, text), public.place_roots(), public.place_terms_public(), public.places_known(text[]), public.shop_services_public(text),
    public.place_sitemap_files(), public.place_sitemap(text, text, integer) from public;
  grant execute on function public.business_rating(), public.place_hub(text, text, text), public.place_roots(), public.place_terms_public(), public.places_known(text[]), public.shop_services_public(text),
    public.place_sitemap_files(), public.place_sitemap(text, text, integer) to anon, authenticated, service_role;
end $$;

-- the home, the landing hub, the contact page and the service pages are new or changed: tell IndexNow
select app.indexnow_queue_path(x, 'local search 0095') from unnest(array['/', '/car-rental', '/contact', '/detailing', '/body-shop']) x;
select app.seo_snapshot_refresh();

-- ================================================================ 9. the guides of this release
create or replace function app.guide_release_0095(p_portal text, p_slug text, p_kind text, p_after text, p_base_md text, p_title text, p_blurb text,
                                                  p_md text, p_html text) returns text
language sql security definer set search_path = public, app as $$
  select app.guide_release_section(p_portal, p_slug, p_kind, p_after, p_base_md, p_title, p_blurb, p_md, p_html)
$$;
revoke all on function app.guide_release_0095(text, text, text, text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function app.guide_release_0095(text, text, text, text, text, text, text, text, text) to service_role;

-- GUIDES 0095 START (generated by supabase/seed/0095_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_0095('admin', 'search-car-pages-landing-pages-and-guides', 'chapter', 'discount-games-and-leads', 'The text of every car page, the landing pages for each area and way of renting, and the guides are written by Workers AI from the facts in the database, checked and published by themselves. Nobody has to type or review anything. You can still change any line; what you change is kept.

## The copy of a car

**Cars** > **Vehicles**, then the car, then its Listing tab. The same card is on the listing review.

1. The card says who wrote the text: a plain copy from the car''s facts while the written copy is prepared (usually minutes), then Workers AI.
2. Every field is shown: search title and description, heading, introduction, highlights, good for, what''s included, pickup and delivery, requirements, questions and the photo descriptions.
3. To change a field press **Change**, then **Save and lock**. A locked field is kept by every new version. **Unlock** lets it be written again.
4. **Write again** asks for a new version now. A new version is also written by itself when the car''s facts change: its rates, specs, area or photos.

> Good to know: The checks refuse long dashes, sales words, the numbered company, any number that is not in the car''s facts (a price, a seat count) and equipment the facts do not list. A version that fails is asked again with the problems named; if it still fails, the page keeps its current text and it is tried again later.

## Landing pages and guides

**Settings** > **All settings**, then Search.

1. Today: the Workers AI used for search copy and in all, and IndexNow (addresses waiting and sent).
2. Car copy: every real car, who wrote its text, and whether its facts changed since.
3. Landing pages: each place and way of renting, whether it is in search, its cars and who wrote it. A page for a way of renting (monthly, SUV) goes into search once enough real cars match it (Program settings).
4. Open **Edit** on a page or a guide to change its text. Edited fields are locked. **Write again** asks for a new version; on a guide, the brief says what it must cover.

## Search engines and business listings

**Settings** > **All settings**, then Site settings.

1. Search engines: paste the Google Search Console value (HTML tag) or the file name (HTML file), and the Bing value. The steps are on the card.
2. Business name, address and phone: the exact text for every listing, and the description and categories.
3. Business listings: press **Copy** beside each line and paste it into Google Business Profile, Bing Places, Apple Business Connect, Yelp, Yellow Pages and Facebook. Tick each one when it is done.

> Good to know: Changed pages are sent to IndexNow (Bing and the other engines that use it) by themselves. Google reads the sitemap: submit carmacars.ca/sitemap.xml once in Search Console.
', 'Search: car pages, landing pages and guides', 'Car copy written by itself, landing pages, place pages for every place and term, detailing and body shop, guides, business listings and IndexNow.',
  'The text of every car page, the landing pages for each area and way of renting, and the guides are written by Workers AI from the facts in the database, checked and published by themselves. Nobody has to type or review anything. You can still change any line; what you change is kept.

## The copy of a car

**Cars** > **Vehicles**, then the car, then its Listing tab. The same card is on the listing review.

1. The card says who wrote the text: a plain copy from the car''s facts while the written copy is prepared (usually minutes), then Workers AI.
2. Every field is shown: search title and description, heading, introduction, highlights, good for, what''s included, pickup and delivery, requirements, questions and the photo descriptions.
3. To change a field press **Change**, then **Save and lock**. A locked field is kept by every new version. **Unlock** lets it be written again.
4. **Write again** asks for a new version now. A new version is also written by itself when the car''s facts change: its rates, specs, area or photos.

> Good to know: The checks refuse long dashes, sales words, the numbered company, any number that is not in the car''s facts (a price, a seat count) and equipment the facts do not list. A version that fails is asked again with the problems named; if it still fails, the page keeps its current text and it is tried again later.

## Landing pages and guides

**Settings** > **All settings**, then Search.

1. Today: the Workers AI used for search copy and in all, and IndexNow (addresses waiting and sent).
2. Car copy: every real car, who wrote its text, and whether its facts changed since.
3. Landing pages: each place and way of renting, whether it is in search, its cars and who wrote it. A page for a way of renting (monthly, SUV) goes into search once enough real cars match it (Program settings).
4. Open **Edit** on a page or a guide to change its text. Edited fields are locked. **Write again** asks for a new version; on a guide, the brief says what it must cover.

## Search engines and business listings

**Settings** > **All settings**, then Site settings.

1. Search engines: paste the Google Search Console value (HTML tag) or the file name (HTML file), and the Bing value. The steps are on the card.
2. Business name, address and phone: the exact text for every listing, and the description and categories.
3. Business listings: press **Copy** beside each line and paste it into Google Business Profile, Bing Places, Apple Business Connect, Yelp, Yellow Pages and Facebook. Tick each one when it is done.

> Good to know: Changed pages are sent to IndexNow (Bing and the other engines that use it) by themselves. Google reads the sitemap: submit carmacars.ca/sitemap.xml once in Search Console.

## Place pages

Every place we have, from a country down to a neighbourhood, gets a page for every term people search with: renting (car hire, SUV rental, monthly car rental ...), buying help (used cars, car financing ...), detailing (ceramic coating, window tint ...) and body work (collision repair, dent repair ...). Each page is written from real data only: the distance from us, the delivery price within our reach, the nearest airport, the landmarks near it, our live cars and the places around it. A place far from Toronto says we serve the Toronto area and takes a request instead. **Settings** > **All settings**, then Search.

1. Place pages: four switches, one for each family, put the pages in search and in the sitemaps. All four are on.
2. Quality gate: off. On, only places within the delivery reach are in search, and rental pages only with a real matching car. Search engines can treat many similar pages as low value; the gate lowers that risk.
3. Delivery reach: places within this distance of our location are offered delivery. Database size cap: the places import stops before the database passes it.
4. Regions and places: every province, state and territory is on. Untick a region to take its pages and sitemaps off the site.
5. Terms and services: change a term''s title or what is true about it, point a synonym to another term (its pages then leave search), switch a term off, or add one. Give a service a starting price, or leave it empty for "price on request".

> Good to know: A region has pages once the places workflow has loaded it: GitHub, Actions, places, Run workflow, with the regions or all. The run loads Ontario first and names any region it skipped because of the size cap.

## Requests from the place pages

The buying help, detailing and body shop pages, and the pages of places beyond our reach, have a request form. Each request is a lead with a task in **To do**: detailing and body shop requests are due within an hour of opening and show in Today. Buying help pages say plainly that CarmaCars does not sell, finance or lease cars; the notice at the top is set under Place pages.

## One name, address and phone

The footer, the contact page, the structured data and every business listing show the business address of Site settings. Keep it the address renters come to, and change it there only.
',
  '<p class="gd-p">The text of every car page, the landing pages for each area and way of renting, and the guides are written by Workers AI from the facts in the database, checked and published by themselves. Nobody has to type or review anything. You can still change any line; what you change is kept.</p><section class="gd-task" id="search-car-pages-landing-pages-and-guides-the-copy-of-a-car" data-gd-task><h2 class="gd-h2">The copy of a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, then the car, then its Listing tab. The same card is on the listing review.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The card says who wrote the text: a plain copy from the car&#39;s facts while the written copy is prepared (usually minutes), then Workers AI.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Every field is shown: search title and description, heading, introduction, highlights, good for, what&#39;s included, pickup and delivery, requirements, questions and the photo descriptions.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">To change a field press <b class="gd-ui">Change</b>, then <b class="gd-ui">Save and lock</b>. A locked field is kept by every new version. <b class="gd-ui">Unlock</b> lets it be written again.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Write again</b> asks for a new version now. A new version is also written by itself when the car&#39;s facts change: its rates, specs, area or photos.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The checks refuse long dashes, sales words, the numbered company, any number that is not in the car&#39;s facts (a price, a seat count) and equipment the facts do not list. A version that fails is asked again with the problems named; if it still fails, the page keeps its current text and it is tried again later.</div></aside></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-landing-pages-and-guides" data-gd-task><h2 class="gd-h2">Landing pages and guides</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">All settings</b>, then Search.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Today: the Workers AI used for search copy and in all, and IndexNow (addresses waiting and sent).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Car copy: every real car, who wrote its text, and whether its facts changed since.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Landing pages: each place and way of renting, whether it is in search, its cars and who wrote it. A page for a way of renting (monthly, SUV) goes into search once enough real cars match it (Program settings).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Open <b class="gd-ui">Edit</b> on a page or a guide to change its text. Edited fields are locked. <b class="gd-ui">Write again</b> asks for a new version; on a guide, the brief says what it must cover.</div></li></ol></div></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-search-engines-and-business-listings" data-gd-task><h2 class="gd-h2">Search engines and business listings</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">All settings</b>, then Site settings.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Search engines: paste the Google Search Console value (HTML tag) or the file name (HTML file), and the Bing value. The steps are on the card.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Business name, address and phone: the exact text for every listing, and the description and categories.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Business listings: press <b class="gd-ui">Copy</b> beside each line and paste it into Google Business Profile, Bing Places, Apple Business Connect, Yelp, Yellow Pages and Facebook. Tick each one when it is done.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Changed pages are sent to IndexNow (Bing and the other engines that use it) by themselves. Google reads the sitemap: submit carmacars.ca/sitemap.xml once in Search Console.</div></aside></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-place-pages" data-gd-task><h2 class="gd-h2">Place pages</h2><p class="gd-p">Every place we have, from a country down to a neighbourhood, gets a page for every term people search with: renting (car hire, SUV rental, monthly car rental ...), buying help (used cars, car financing ...), detailing (ceramic coating, window tint ...) and body work (collision repair, dent repair ...). Each page is written from real data only: the distance from us, the delivery price within our reach, the nearest airport, the landmarks near it, our live cars and the places around it. A place far from Toronto says we serve the Toronto area and takes a request instead. <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">All settings</b>, then Search.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Place pages: four switches, one for each family, put the pages in search and in the sitemaps. All four are on.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Quality gate: off. On, only places within the delivery reach are in search, and rental pages only with a real matching car. Search engines can treat many similar pages as low value; the gate lowers that risk.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Delivery reach: places within this distance of our location are offered delivery. Database size cap: the places import stops before the database passes it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Regions and places: every province, state and territory is on. Untick a region to take its pages and sitemaps off the site.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Terms and services: change a term&#39;s title or what is true about it, point a synonym to another term (its pages then leave search), switch a term off, or add one. Give a service a starting price, or leave it empty for &quot;price on request&quot;.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A region has pages once the places workflow has loaded it: GitHub, Actions, places, Run workflow, with the regions or all. The run loads Ontario first and names any region it skipped because of the size cap.</div></aside></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-requests-from-the-place-pages" data-gd-task><h2 class="gd-h2">Requests from the place pages</h2><p class="gd-p">The buying help, detailing and body shop pages, and the pages of places beyond our reach, have a request form. Each request is a lead with a task in <b class="gd-ui">To do</b>: detailing and body shop requests are due within an hour of opening and show in Today. Buying help pages say plainly that CarmaCars does not sell, finance or lease cars; the notice at the top is set under Place pages.</p></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-one-name-address-and-phone" data-gd-task><h2 class="gd-h2">One name, address and phone</h2><p class="gd-p">The footer, the contact page, the structured data and every business listing show the business address of Site settings. Keep it the address renters come to, and change it there only.</p></section>');
-- GUIDES 0095 END
