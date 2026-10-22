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
  ('chauffeur-service', 'rental', 'chauffeur service', 'Chauffeur Service', '{}', 'request', null, 'We book a professional driver with a luxury car or van by the hour, two hours minimum (our chauffeur service). Send the date and the trip, and we reply with the vehicle and the price.', 300),
  ('car-with-driver', 'rental', 'car with driver', 'Car With Driver', '{}', 'request', null, 'A car with a professional driver, booked by the hour through our chauffeur service. Send us the details and we reply with the vehicle and the price.', 310);
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
  e text;
begin
  select pg_get_constraintdef(oid) into d from pg_constraint where conrelid = 'leads'::regclass and conname = 'leads_kind_check';
  -- the list as written by 0088 (kind = ANY (ARRAY['a'::text, ...])) or by 0093 (kind = ANY ('{a,b}'::text[])): the
  -- expression inside ANY (...) is evaluated, so every kind already allowed is kept whichever form it is in
  e := substring(coalesce(d, '') from 'ANY \((.*)\)\)\)$');
  if e is not null then execute format('select array(select unnest(%s)::text)', e) into v; end if;
  if v is null or cardinality(v) = 0 then raise exception 'leads_kind_check: cannot read the allowed kinds from %', d; end if;
  foreach k in array array['buyer', 'finance', 'place_request', 'detailing', 'bodyshop'] loop
    if not k = any (v) then v := v || k; end if;
  end loop;
  execute 'alter table leads drop constraint if exists leads_kind_check';
  -- written as ARRAY['a', ...], the form 0088 wrote and the later migrations read
  execute format('alter table leads add constraint leads_kind_check check (kind = any (array[%s]))', (select string_agg(quote_literal(x), ', ') from unnest(v) x));
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
select app.guide_release_0095('renter', 'find-a-car-and-send-a-request', 'chapter', 'start-here', 'Every booking starts as a request. A person checks the car and the price, then sends you an offer. Nothing is charged until you approve, sign and pay.

:::flow
Request | You pick a car and dates
Offer | We confirm the price
Sign | The rental agreement
Pay | Your card is authorized
Verify | Licence, selfie, coverage
Pick up | We hand over the keys
:::

## Find a car

Start on carmacars.ca. You do not need to sign in to look around.

1. Go to `carmacars.ca` and press **Find a car**.
2. Add your pickup and return dates. The list then shows the cars that are free and what the whole trip costs.
3. Narrow the list with Filters: type, seats, transmission and daily rate.
4. Open a car to see its photos, rates, what is included and its own calendar. Its car code (like CC-7F3A) is under the price: quote it when you call or chat with us, and we know the car at once.

![](/guides/img/public-02-cars-desktop-b6cd4fb8.jpg "desktop; size: 1440 880; address: carmacars.ca/cars; pins: 1 86.1 4.0, 2 11.1 56.8, 3 3.0 82.3, 4 34.0 87.5")

## Choose your dates on the car page

1. Under Dates and price, tap your pickup date, then your return date. Hatched days are already booked.
2. Choose the Pickup time and the Return time.
3. Want it brought to you? Tick **Deliver it to me** or **Pick it up from me at the end**. Open Add-ons to add a baby seat, flowers, a full tank and more.
4. Check Your estimate, then press **Request to book**. The add-ons you chose come with you.

![](/guides/img/public-03-car-page-desktop-73be4d63.jpg "desktop; size: 1120 760; address: carmacars.ca/cars/bmw-330i; pins: 1 24.4 39.7, 2 12.9 68.2, 3 3.0 76.2, 4 97.0 50.0")

> Watch out: A request does not hold the car. The car is booked only once you approve the offer, sign and pay.

## Send your request

The request has five short steps. Your answers are saved as you go, so you can come back.

1. Step 1, Dates and delivery: check the car and tap your dates in the calendar.
2. Set the Pickup time and Return time. Any time, day or night, with at least 2 hours of notice.
3. Your request, on the right, shows the estimated total as you go.

![](/guides/img/public-04-book-1-trip-desktop-63a3738b.jpg "desktop; size: 1440 1002; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 1 9.2 67.1, 2 15.3 91.0, 3 91.1 54.7")

4. Choose where you get the car: **At our location**, **Deliver it to an address** or **At the airport**. Then choose where you return it.
5. Press **Continue to driver details**.

![](/guides/img/public-04-book-1-trip-desktop-befba4f6.jpg "desktop; size: 760 942; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 4 5.3 26.2, 5 61.8 93.3")

6. Step 2, The driver: fill in your first and last name, email, mobile number and date of birth.
7. Someone else will drive too? Add them under Additional drivers. Each needs a G2 or G licence and signs the agreement.
8. Press **Continue to licence**.

![](/guides/img/public-05-book-2-driver-desktop-7b572499.jpg "desktop; size: 980 1032; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 6 30.6 21.1, 7 30.6 64.8, 8 55.6 88.0")

9. Step 3: choose your Licence class, for example Ontario G2.
10. Choose how the car is covered: Option 1 (OPCF 27 on your own auto policy), Option 2 (rental coverage on your credit card) or Option 3 (the CarmaCars Protection Plan). You can change this any time before pickup.
11. Choose the Booking type: Standard, or Non-refundable for 10% off with no refund.
12. Add anything we should know in the notes, for example a flight number.
13. Press **Continue to add-ons**. Step 4, Add-ons: tick what you want (see Add-ons below), then press **Review request**.

![](/guides/img/public-06-book-3-licence-desktop-22bb144e.jpg "desktop; size: 760 1452; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 9 61.8 11.2, 10 92.1 32.2, 11 92.1 50.4, 12 92.1 66.9, 13 71.7 97.0")

14. Step 5, Check it and send: read every line. Use Edit beside a line to change it.
15. Tick the box to confirm you are 18 or older and agree to the Terms of use and Privacy policy.
16. Press **Send request**. Nothing is charged and no card is needed.

![](/guides/img/public-07-book-4-review-desktop-005f4c0b.jpg "desktop; size: 760 492; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 14 92.1 24.8, 15 3.9 59.3, 16 73.7 89.0")

17. The confirmation shows your request number, for example CC-10021. Keep it for any question.
18. A person checks the calendar, your dates and your place, usually within 2 hours, day or night. Your offer arrives by email and in Trips.

![](/guides/img/public-08-book-5-sent-phone-14a99ccf.jpg "phone; size: 390 755; pins: 17 32.8 12.3")

## Add-ons

Extras for your trip, such as a baby seat, a child or booster seat, flowers waiting in the car, a chauffeur, an umbrella, a phone charger or a full tank of gas.

1. On the car page (under Add-ons) or in step 4 of the request, tick an add-on or use + and − for seats. The estimate shows the price at once.
2. Each add-on shows its price: a trip, a day (with the most for a trip) or an hour. HST is added.
3. Some need notice, for example flowers need 24 hours. Seats and other items show how many are left for your dates.
4. A chauffeur is confirmed by our team in your offer.

With a full tank of gas (prepaid) you can return the car at any fuel level, with no fuel charge.

## Ask in the chat

The chat button sits in the corner of every page.

1. Press it and write your question: a car, your dates, the price, how booking works. The CarmaCars assistant answers right away with prices from our booking system.
2. Want a person? Press **Talk to a person**. When our team is away, leave your name and email or phone with **Send my details** and tick "Email me a copy of this chat".
3. Press **End chat** when you are done. If you gave your email, a copy of the chat arrives by email.

A price in the chat is for the dates you asked. Nothing is booked until you approve an offer, sign and pay.
', 'Find a car and send a request', 'Search the fleet, pick dates and add-ons, and send a request in five short steps.',
  'Every booking starts as a request. A person checks the car and the price, then sends you an offer. Nothing is charged until you approve, sign and pay.

:::flow
Request | You pick a car and dates
Offer | We confirm the price
Sign | The rental agreement
Pay | Your card is authorized
Verify | Licence, selfie, coverage
Pick up | We hand over the keys
:::

## Find a car

Start on carmacars.ca. You do not need to sign in to look around.

1. Go to `carmacars.ca` and press **Find a car**.
2. Add your pickup and return dates. The list then shows the cars that are free and what the whole trip costs.
3. Narrow the list with Filters: type, seats, transmission and daily rate.
4. Open a car to see its photos, rates, what is included and its own calendar. Its car code (like CC-7F3A) is under the price: quote it when you call or chat with us, and we know the car at once.

![](/guides/img/public-02-cars-desktop-b6cd4fb8.jpg "desktop; size: 1440 880; address: carmacars.ca/cars; pins: 1 86.1 4.0, 2 11.1 56.8, 3 3.0 82.3, 4 34.0 87.5")

## Choose your dates on the car page

1. Under Dates and price, tap your pickup date, then your return date. Hatched days are already booked.
2. Choose the Pickup time and the Return time.
3. Want it brought to you? Tick **Deliver it to me** or **Pick it up from me at the end**. Open Add-ons to add a baby seat, flowers, a full tank and more.
4. Check Your estimate, then press **Request to book**. The add-ons you chose come with you.

![](/guides/img/public-03-car-page-desktop-73be4d63.jpg "desktop; size: 1120 760; address: carmacars.ca/cars/bmw-330i; pins: 1 24.4 39.7, 2 12.9 68.2, 3 3.0 76.2, 4 97.0 50.0")

> Watch out: A request does not hold the car. The car is booked only once you approve the offer, sign and pay.

## Send your request

The request has five short steps. Your answers are saved as you go, so you can come back.

1. Step 1, Dates and delivery: check the car and tap your dates in the calendar.
2. Set the Pickup time and Return time. Any time, day or night, with at least 2 hours of notice.
3. Your request, on the right, shows the estimated total as you go.

![](/guides/img/public-04-book-1-trip-desktop-63a3738b.jpg "desktop; size: 1440 1002; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 1 9.2 67.1, 2 15.3 91.0, 3 91.1 54.7")

4. Choose where you get the car: **At our location**, **Deliver it to an address** or **At the airport**. Then choose where you return it.
5. Press **Continue to driver details**.

![](/guides/img/public-04-book-1-trip-desktop-befba4f6.jpg "desktop; size: 760 942; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 4 5.3 26.2, 5 61.8 93.3")

6. Step 2, The driver: fill in your first and last name, email, mobile number and date of birth.
7. Someone else will drive too? Add them under Additional drivers. Each needs a G2 or G licence and signs the agreement.
8. Press **Continue to licence**.

![](/guides/img/public-05-book-2-driver-desktop-7b572499.jpg "desktop; size: 980 1032; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 6 30.6 21.1, 7 30.6 64.8, 8 55.6 88.0")

9. Step 3: choose your Licence class, for example Ontario G2.
10. Choose how the car is covered: Option 1 (OPCF 27 on your own auto policy), Option 2 (rental coverage on your credit card) or Option 3 (the CarmaCars Protection Plan). You can change this any time before pickup.
11. Choose the Booking type: Standard, or Non-refundable for 10% off with no refund.
12. Add anything we should know in the notes, for example a flight number.
13. Press **Continue to add-ons**. Step 4, Add-ons: tick what you want (see Add-ons below), then press **Review request**.

![](/guides/img/public-06-book-3-licence-desktop-22bb144e.jpg "desktop; size: 760 1452; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 9 61.8 11.2, 10 92.1 32.2, 11 92.1 50.4, 12 92.1 66.9, 13 71.7 97.0")

14. Step 5, Check it and send: read every line. Use Edit beside a line to change it.
15. Tick the box to confirm you are 18 or older and agree to the Terms of use and Privacy policy.
16. Press **Send request**. Nothing is charged and no card is needed.

![](/guides/img/public-07-book-4-review-desktop-005f4c0b.jpg "desktop; size: 760 492; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 14 92.1 24.8, 15 3.9 59.3, 16 73.7 89.0")

17. The confirmation shows your request number, for example CC-10021. Keep it for any question.
18. A person checks the calendar, your dates and your place, usually within 2 hours, day or night. Your offer arrives by email and in Trips.

![](/guides/img/public-08-book-5-sent-phone-14a99ccf.jpg "phone; size: 390 755; pins: 17 32.8 12.3")

## Add-ons

Extras for your trip, such as a baby seat, a child or booster seat, flowers waiting in the car, a chauffeur, an umbrella, a phone charger or a full tank of gas.

1. On the car page (under Add-ons) or in step 4 of the request, tick an add-on or use + and − for seats. The estimate shows the price at once.
2. Each add-on shows its price: a trip, a day (with the most for a trip) or an hour. HST is added.
3. Some need notice, for example flowers need 24 hours. Seats and other items show how many are left for your dates.
4. A chauffeur is confirmed by our team in your offer.

With a full tank of gas (prepaid) you can return the car at any fuel level, with no fuel charge.

## Ask in the chat

The chat button sits in the corner of every page.

1. Press it and write your question: a car, your dates, the price, how booking works. The CarmaCars assistant answers right away with prices from our booking system.
2. Want a person? Press **Talk to a person**. When our team is away, leave your name and email or phone with **Send my details** and tick "Email me a copy of this chat".
3. Press **End chat** when you are done. If you gave your email, a copy of the chat arrives by email.

A price in the chat is for the dates you asked. Nothing is booked until you approve an offer, sign and pay.

## Carry on later

- Your name, email and mobile number are saved as you type them, so nothing is lost if you stop. We open an account for you with that email.
- Every form that saves as you type says so under it: "Saved as you type so you can pick up where you left off.", with a link to the privacy policy.
- On the same phone or computer, open `carmacars.ca/account` (or the request page again) to carry on, no password needed.
- We send you one email, "Continue your request". One tap signs you in, confirms your email and opens your request on any device. You need it before you can accept an offer, sign or pay.
- Already have an account? The form says "You have an account: we sent you a sign-in link".
',
  '<p class="gd-p">Every booking starts as a request. A person checks the car and the price, then sends you an offer. Nothing is charged until you approve, sign and pay.</p><ol class="gd-flow"><li><b>1</b><span>Request</span><em>You pick a car and dates</em></li><li><b>2</b><span>Offer</span><em>We confirm the price</em></li><li><b>3</b><span>Sign</span><em>The rental agreement</em></li><li><b>4</b><span>Pay</span><em>Your card is authorized</em></li><li><b>5</b><span>Verify</span><em>Licence, selfie, coverage</em></li><li><b>6</b><span>Pick up</span><em>We hand over the keys</em></li></ol><section class="gd-task" id="find-a-car-and-send-a-request-find-a-car" data-gd-task><h2 class="gd-h2">Find a car</h2><p class="gd-p">Start on carmacars.ca. You do not need to sign in to look around.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Go to <span class="gd-url">carmacars.ca</span> and press <b class="gd-ui">Find a car</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Add your pickup and return dates. The list then shows the cars that are free and what the whole trip costs.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Narrow the list with Filters: type, seats, transmission and daily rate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Open a car to see its photos, rates, what is included and its own calendar. Its car code (like CC-7F3A) is under the price: quote it when you call or chat with us, and we know the car at once.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/cars</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/880"><img src="/guides/img/public-02-cars-desktop-b6cd4fb8.jpg" alt="" loading="lazy" decoding="async" width="1440" height="880"><span class="gd-pin" style="left:86.1%;top:4%" aria-hidden="true">1</span><span class="gd-pin" style="left:11.1%;top:56.8%" aria-hidden="true">2</span><span class="gd-pin" style="left:3%;top:82.3%" aria-hidden="true">3</span><span class="gd-pin" style="left:34%;top:87.5%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="find-a-car-and-send-a-request-choose-your-dates-on-the-car-page" data-gd-task><h2 class="gd-h2">Choose your dates on the car page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Under Dates and price, tap your pickup date, then your return date. Hatched days are already booked.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the Pickup time and the Return time.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Want it brought to you? Tick <b class="gd-ui">Deliver it to me</b> or <b class="gd-ui">Pick it up from me at the end</b>. Open Add-ons to add a baby seat, flowers, a full tank and more.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Check Your estimate, then press <b class="gd-ui">Request to book</b>. The add-ons you chose come with you.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/cars/bmw-330i</span></div><div class="gd-imgwrap" style="aspect-ratio:1120/760"><img src="/guides/img/public-03-car-page-desktop-73be4d63.jpg" alt="" loading="lazy" decoding="async" width="1120" height="760"><span class="gd-pin" style="left:24.4%;top:39.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:12.9%;top:68.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:3%;top:76.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:97%;top:50%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>A request does not hold the car. The car is booked only once you approve the offer, sign and pay.</div></aside></section><section class="gd-task" id="find-a-car-and-send-a-request-send-your-request" data-gd-task><h2 class="gd-h2">Send your request</h2><p class="gd-p">The request has five short steps. Your answers are saved as you go, so you can come back.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Step 1, Dates and delivery: check the car and tap your dates in the calendar.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Set the Pickup time and Return time. Any time, day or night, with at least 2 hours of notice.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Your request, on the right, shows the estimated total as you go.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1002"><img src="/guides/img/public-04-book-1-trip-desktop-63a3738b.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1002"><span class="gd-pin" style="left:9.2%;top:67.1%" aria-hidden="true">1</span><span class="gd-pin" style="left:15.3%;top:91%" aria-hidden="true">2</span><span class="gd-pin" style="left:91.1%;top:54.7%" aria-hidden="true">3</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="4"><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Choose where you get the car: <b class="gd-ui">At our location</b>, <b class="gd-ui">Deliver it to an address</b> or <b class="gd-ui">At the airport</b>. Then choose where you return it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Continue to driver details</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:760/942"><img src="/guides/img/public-04-book-1-trip-desktop-befba4f6.jpg" alt="" loading="lazy" decoding="async" width="760" height="942"><span class="gd-pin" style="left:5.3%;top:26.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:61.8%;top:93.3%" aria-hidden="true">5</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="6"><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Step 2, The driver: fill in your first and last name, email, mobile number and date of birth.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Someone else will drive too? Add them under Additional drivers. Each needs a G2 or G licence and signs the agreement.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Press <b class="gd-ui">Continue to licence</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:980/1032"><img src="/guides/img/public-05-book-2-driver-desktop-7b572499.jpg" alt="" loading="lazy" decoding="async" width="980" height="1032"><span class="gd-pin" style="left:30.6%;top:21.1%" aria-hidden="true">6</span><span class="gd-pin" style="left:30.6%;top:64.8%" aria-hidden="true">7</span><span class="gd-pin" style="left:55.6%;top:88%" aria-hidden="true">8</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="9"><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Step 3: choose your Licence class, for example Ontario G2.</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Choose how the car is covered: Option 1 (OPCF 27 on your own auto policy), Option 2 (rental coverage on your credit card) or Option 3 (the CarmaCars Protection Plan). You can change this any time before pickup.</div></li><li><span class="gd-n" aria-hidden="true">11</span><div class="gd-t">Choose the Booking type: Standard, or Non-refundable for 10% off with no refund.</div></li><li><span class="gd-n" aria-hidden="true">12</span><div class="gd-t">Add anything we should know in the notes, for example a flight number.</div></li><li><span class="gd-n" aria-hidden="true">13</span><div class="gd-t">Press <b class="gd-ui">Continue to add-ons</b>. Step 4, Add-ons: tick what you want (see Add-ons below), then press <b class="gd-ui">Review request</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:760/1452"><img src="/guides/img/public-06-book-3-licence-desktop-22bb144e.jpg" alt="" loading="lazy" decoding="async" width="760" height="1452"><span class="gd-pin" style="left:61.8%;top:11.2%" aria-hidden="true">9</span><span class="gd-pin" style="left:92.1%;top:32.2%" aria-hidden="true">10</span><span class="gd-pin" style="left:92.1%;top:50.4%" aria-hidden="true">11</span><span class="gd-pin" style="left:92.1%;top:66.9%" aria-hidden="true">12</span><span class="gd-pin" style="left:71.7%;top:97%" aria-hidden="true">13</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="14"><li><span class="gd-n" aria-hidden="true">14</span><div class="gd-t">Step 5, Check it and send: read every line. Use Edit beside a line to change it.</div></li><li><span class="gd-n" aria-hidden="true">15</span><div class="gd-t">Tick the box to confirm you are 18 or older and agree to the Terms of use and Privacy policy.</div></li><li><span class="gd-n" aria-hidden="true">16</span><div class="gd-t">Press <b class="gd-ui">Send request</b>. Nothing is charged and no card is needed.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:760/492"><img src="/guides/img/public-07-book-4-review-desktop-005f4c0b.jpg" alt="" loading="lazy" decoding="async" width="760" height="492"><span class="gd-pin" style="left:92.1%;top:24.8%" aria-hidden="true">14</span><span class="gd-pin" style="left:3.9%;top:59.3%" aria-hidden="true">15</span><span class="gd-pin" style="left:73.7%;top:89%" aria-hidden="true">16</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol" start="17"><li><span class="gd-n" aria-hidden="true">17</span><div class="gd-t">The confirmation shows your request number, for example CC-10021. Keep it for any question.</div></li><li><span class="gd-n" aria-hidden="true">18</span><div class="gd-t">A person checks the calendar, your dates and your place, usually within 2 hours, day or night. Your offer arrives by email and in Trips.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/755"><img src="/guides/img/public-08-book-5-sent-phone-14a99ccf.jpg" alt="" loading="lazy" decoding="async" width="390" height="755"><span class="gd-pin" style="left:32.8%;top:12.3%" aria-hidden="true">17</span></div></div></figure></div></section><section class="gd-task" id="find-a-car-and-send-a-request-add-ons" data-gd-task><h2 class="gd-h2">Add-ons</h2><p class="gd-p">Extras for your trip, such as a baby seat, a child or booster seat, flowers waiting in the car, a chauffeur, an umbrella, a phone charger or a full tank of gas.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On the car page (under Add-ons) or in step 4 of the request, tick an add-on or use + and − for seats. The estimate shows the price at once.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each add-on shows its price: a trip, a day (with the most for a trip) or an hour. HST is added.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Some need notice, for example flowers need 24 hours. Seats and other items show how many are left for your dates.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A chauffeur is confirmed by our team in your offer.</div></li></ol></div><p class="gd-p">With a full tank of gas (prepaid) you can return the car at any fuel level, with no fuel charge.</p></section><section class="gd-task" id="find-a-car-and-send-a-request-ask-in-the-chat" data-gd-task><h2 class="gd-h2">Ask in the chat</h2><p class="gd-p">The chat button sits in the corner of every page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press it and write your question: a car, your dates, the price, how booking works. The CarmaCars assistant answers right away with prices from our booking system.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Want a person? Press <b class="gd-ui">Talk to a person</b>. When our team is away, leave your name and email or phone with <b class="gd-ui">Send my details</b> and tick &quot;Email me a copy of this chat&quot;.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">End chat</b> when you are done. If you gave your email, a copy of the chat arrives by email.</div></li></ol></div><p class="gd-p">A price in the chat is for the dates you asked. Nothing is booked until you approve an offer, sign and pay.</p></section><section class="gd-task" id="find-a-car-and-send-a-request-carry-on-later" data-gd-task><h2 class="gd-h2">Carry on later</h2><ul class="gd-ul"><li>Your name, email and mobile number are saved as you type them, so nothing is lost if you stop. We open an account for you with that email.</li><li>Every form that saves as you type says so under it: &quot;Saved as you type so you can pick up where you left off.&quot;, with a link to the privacy policy.</li><li>On the same phone or computer, open <span class="gd-url">carmacars.ca/account</span> (or the request page again) to carry on, no password needed.</li><li>We send you one email, &quot;Continue your request&quot;. One tap signs you in, confirms your email and opens your request on any device. You need it before you can accept an offer, sign or pay.</li><li>Already have an account? The form says &quot;You have an account: we sent you a sign-in link&quot;.</li></ul></section>');
select app.guide_release_0095('renter', 'after-your-trip', 'chapter', 'during-your-trip', 'We check the car with you at the return. Your deposit balance comes back, and your receipts and agreement stay in your portal.

## The return and your deposit

- At the return we check the odometer, fuel or charge, keys and cleanliness, take photos and compare with pickup. You sign on our screen.
- We release the deposit balance after you return the car. If a toll, ticket or claim is still open, we may hold back what we expect it to cost for a while.
- Your statement appears under Documents.

## Review your rental

1. Open the trip under Past, then press **Review your rental**.
2. Tap the stars. Add a title and a few words if you like. Both are optional.
3. Tick **Show my review on the site with my first name** only if you agree to it being shown.
4. Press **Send my review**.

![](/guides/img/renter-14-review-desktop-c6c61830.jpg "desktop; size: 1440 672; address: carmacars.ca/account/bookings/CC-10058/review; pins: 2 25.0 33.6, 3 3.5 84.5, 4 18.1 92.4")

## Documents, notifications and profile

1. **Documents**: your agreements, receipts, statements and uploads. Press **View** or **Download**.
2. **Notifications**: notices from us. Use **Mark as read** or **Mark all as read**, and choose which optional emails you get.
3. **Profile**: your contact details (**Save**), drivers, your Card on File and your marketing choice.

![](/guides/img/renter-15-documents-desktop-fd428a63.jpg "desktop; size: 1440 560; address: carmacars.ca/account/documents; pins: 1 91.8 35.7")

> Tip: Your legal name is locked once you are verified. To change it or your email, call or message us.
', 'After your trip', 'The return, your deposit, reviews, documents and your profile.',
  'We check the car with you at the return. Your deposit balance comes back, and your receipts and agreement stay in your portal.

## The return and your deposit

- At the return we check the odometer, fuel or charge, keys and cleanliness, take photos and compare with pickup. You sign on our screen.
- We release the deposit balance after you return the car. If a toll, ticket or claim is still open, we may hold back what we expect it to cost for a while.
- Your statement appears under Documents.

## Review your rental

1. Open the trip under Past, then press **Review your rental**.
2. Tap the stars. Add a title and a few words if you like. Both are optional.
3. Tick **Show my review on the site with my first name** only if you agree to it being shown.
4. Press **Send my review**.

![](/guides/img/renter-14-review-desktop-c6c61830.jpg "desktop; size: 1440 672; address: carmacars.ca/account/bookings/CC-10058/review; pins: 2 25.0 33.6, 3 3.5 84.5, 4 18.1 92.4")

## Documents, notifications and profile

1. **Documents**: your agreements, receipts, statements and uploads. Press **View** or **Download**.
2. **Notifications**: notices from us. Use **Mark as read** or **Mark all as read**, and choose which optional emails you get.
3. **Profile**: your contact details (**Save**), drivers, your Card on File and your marketing choice.

![](/guides/img/renter-15-documents-desktop-fd428a63.jpg "desktop; size: 1440 560; address: carmacars.ca/account/documents; pins: 1 91.8 35.7")

> Tip: Your legal name is locked once you are verified. To change it or your email, call or message us.

## Sign in with your phone number

No password needed: we text you a 6-digit code from the CarmaCars number.

1. On `carmacars.ca/sign-in`, press **Use my phone number instead**.
2. Enter your mobile number and press **Text me a code**. Codes go to Canadian mobile numbers.
3. Type the 6-digit code from the text (on most phones it fills itself in), or press **Sign in**. The code works for 5 minutes; **Send a new code** after a minute if it did not arrive.
4. To sign in by phone every time, open **Profile**, press **Add and verify my phone number**, enter the code we text you, then choose **My phone number (a code by text)** under Sign in with. The sign-in page then opens on your phone number.

> Tip: New here? On Create account, press Sign up with my phone number instead: your name, your mobile number and the code. An account made by phone has no email yet: you can send requests, accept offers and sign, and the pay page asks for your email before your first payment, for the receipts. A booking request you sent earlier with the same mobile number is added to your account once the code is checked.
',
  '<p class="gd-p">We check the car with you at the return. Your deposit balance comes back, and your receipts and agreement stay in your portal.</p><section class="gd-task" id="after-your-trip-the-return-and-your-deposit" data-gd-task><h2 class="gd-h2">The return and your deposit</h2><ul class="gd-ul"><li>At the return we check the odometer, fuel or charge, keys and cleanliness, take photos and compare with pickup. You sign on our screen.</li><li>We release the deposit balance after you return the car. If a toll, ticket or claim is still open, we may hold back what we expect it to cost for a while.</li><li>Your statement appears under Documents.</li></ul></section><section class="gd-task" id="after-your-trip-review-your-rental" data-gd-task><h2 class="gd-h2">Review your rental</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the trip under Past, then press <b class="gd-ui">Review your rental</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Tap the stars. Add a title and a few words if you like. Both are optional.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Tick <b class="gd-ui">Show my review on the site with my first name</b> only if you agree to it being shown.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Send my review</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10058/review</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/672"><img src="/guides/img/renter-14-review-desktop-c6c61830.jpg" alt="" loading="lazy" decoding="async" width="1440" height="672"><span class="gd-pin" style="left:25%;top:33.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:3.5%;top:84.5%" aria-hidden="true">3</span><span class="gd-pin" style="left:18.1%;top:92.4%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="after-your-trip-documents-notifications-and-profile" data-gd-task><h2 class="gd-h2">Documents, notifications and profile</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Documents</b>: your agreements, receipts, statements and uploads. Press <b class="gd-ui">View</b> or <b class="gd-ui">Download</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Notifications</b>: notices from us. Use <b class="gd-ui">Mark as read</b> or <b class="gd-ui">Mark all as read</b>, and choose which optional emails you get.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Profile</b>: your contact details (<b class="gd-ui">Save</b>), drivers, your Card on File and your marketing choice.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/documents</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/560"><img src="/guides/img/renter-15-documents-desktop-fd428a63.jpg" alt="" loading="lazy" decoding="async" width="1440" height="560"><span class="gd-pin" style="left:91.8%;top:35.7%" aria-hidden="true">1</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Your legal name is locked once you are verified. To change it or your email, call or message us.</div></aside></section><section class="gd-task" id="after-your-trip-sign-in-with-your-phone-number" data-gd-task><h2 class="gd-h2">Sign in with your phone number</h2><p class="gd-p">No password needed: we text you a 6-digit code from the CarmaCars number.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On <span class="gd-url">carmacars.ca/sign-in</span>, press <b class="gd-ui">Use my phone number instead</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Enter your mobile number and press <b class="gd-ui">Text me a code</b>. Codes go to Canadian mobile numbers.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Type the 6-digit code from the text (on most phones it fills itself in), or press <b class="gd-ui">Sign in</b>. The code works for 5 minutes; <b class="gd-ui">Send a new code</b> after a minute if it did not arrive.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">To sign in by phone every time, open <b class="gd-ui">Profile</b>, press <b class="gd-ui">Add and verify my phone number</b>, enter the code we text you, then choose <b class="gd-ui">My phone number (a code by text)</b> under Sign in with. The sign-in page then opens on your phone number.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>New here? On Create account, press Sign up with my phone number instead: your name, your mobile number and the code. An account made by phone has no email yet: you can send requests, accept offers and sign, and the pay page asks for your email before your first payment, for the receipts. A booking request you sent earlier with the same mobile number is added to your account once the code is checked.</div></aside></section>');
select app.guide_release_0095('owner', 'start-here', 'start', null, '### Who this guide is for

Owners who list one or more cars with CarmaCars, whether Managed, Self-managed or Turo only. Your portal shows each car, its bookings, your invoices, statements and payouts, and every form to sign.

### What you need

- The email address you applied or were invited with
- Each car''s VIN, ownership permit and insurance details
- A Canadian bank account for your fees and payouts

## Your first sign-in

1. New to CarmaCars? Apply at `carmacars.ca/list-your-car`. Your account is made at the end of the application: open the email "Confirm your CarmaCars account" within 24 hours and its link opens your owner portal.
2. Invited by us? Open the invitation email within 24 hours, choose a password and press **Save the new password**.
3. Next time, go to `carmacars.ca/sign-in`, enter your Email and Password and press **Sign in**.
4. Forgot your password? Press **Forgot your password?** on the sign-in page and follow the email.

![](/guides/img/public-09-sign-in-phone-1f766061.jpg "phone; size: 390 645; pins: 3 95.4 78.4")

> Good to know: Email links work for 24 hours, once. If a link has expired, the page it opens has **Send me a new link**.
', 'Start here', 'Who this is for and your first sign-in.',
  '### Who this guide is for

Owners who list one or more cars with CarmaCars, whether Managed, Self-managed or Turo only. Your portal shows each car, its bookings, your invoices, statements and payouts, and every form to sign.

### What you need

- The email address you applied or were invited with
- Each car''s VIN, ownership permit and insurance details
- A Canadian bank account for your fees and payouts

## Your first sign-in

1. New to CarmaCars? Apply at `carmacars.ca/list-your-car`. Your account is made at the end of the application: open the email "Confirm your CarmaCars account" within 24 hours and its link opens your owner portal.
2. Invited by us? Open the invitation email within 24 hours, choose a password and press **Save the new password**.
3. Next time, go to `carmacars.ca/sign-in`, enter your Email and Password and press **Sign in**.
4. Forgot your password? Press **Forgot your password?** on the sign-in page and follow the email.
5. Rather use your phone? Press **Use my phone number instead** on the sign-in page, enter your mobile number and the 6-digit code we text you. Add and verify your number first under **Profile**, Sign-in, so it opens your owner portal.

![](/guides/img/public-09-sign-in-phone-1f766061.jpg "phone; size: 390 645; pins: 3 95.4 78.4")

> Good to know: Email links work for 24 hours, once. If a link has expired, the page it opens has **Send me a new link**.
',
  '<h3 class="gd-h3">Who this guide is for</h3><p class="gd-p">Owners who list one or more cars with CarmaCars, whether Managed, Self-managed or Turo only. Your portal shows each car, its bookings, your invoices, statements and payouts, and every form to sign.</p><h3 class="gd-h3">What you need</h3><ul class="gd-ul"><li>The email address you applied or were invited with</li><li>Each car&#39;s VIN, ownership permit and insurance details</li><li>A Canadian bank account for your fees and payouts</li></ul><section class="gd-task" id="start-here-your-first-sign-in" data-gd-task><h2 class="gd-h2">Your first sign-in</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">New to CarmaCars? Apply at <span class="gd-url">carmacars.ca/list-your-car</span>. Your account is made at the end of the application: open the email &quot;Confirm your CarmaCars account&quot; within 24 hours and its link opens your owner portal.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Invited by us? Open the invitation email within 24 hours, choose a password and press <b class="gd-ui">Save the new password</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Next time, go to <span class="gd-url">carmacars.ca/sign-in</span>, enter your Email and Password and press <b class="gd-ui">Sign in</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Forgot your password? Press <b class="gd-ui">Forgot your password?</b> on the sign-in page and follow the email.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Rather use your phone? Press <b class="gd-ui">Use my phone number instead</b> on the sign-in page, enter your mobile number and the 6-digit code we text you. Add and verify your number first under <b class="gd-ui">Profile</b>, Sign-in, so it opens your owner portal.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/645"><img src="/guides/img/public-09-sign-in-phone-1f766061.jpg" alt="" loading="lazy" decoding="async" width="390" height="645"><span class="gd-pin" style="left:95.4%;top:78.4%" aria-hidden="true">3</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Email links work for 24 hours, once. If a link has expired, the page it opens has <b class="gd-ui">Send me a new link</b>.</div></aside></section>');
select app.guide_release_0095('owner', 'home-and-your-vehicles', 'chapter', 'apply-and-get-your-car-listed', 'Home tells you what to do next. Each car has its own page with its status, terms, bookings, invoices and photos.

## Home at a glance

1. The menu: Home, Vehicles, Bookings, Invoices, Statements, Payouts, Documents, Banking, Notifications and Profile.
2. Your vehicles: each car with its status and what it needs next.
3. Money: what is due now, your fees each month, the next billing date and the next payout date.
4. Got another car? Press **Add a vehicle**.

![](/guides/img/owner-01-home-desktop-841aa611.jpg "desktop; size: 1440 760; address: carmacars.ca/owner; pins: 1 32.6 22.9, 2 42.7 52.6, 3 74.7 50.0, 4 38.9 46.1")

> Tip: When something needs you (a signature, a payment or an upload), it is the first thing on Home.

## A car''s page

Open Vehicles, then a car.

1. The top shows the car, its plate and how it is enrolled, with its status.
2. Terms: the Insurance Fee, the Revenue Share, your enrolment date and a link to the listing.
3. Bookings shows every trip in your car. **Book it for myself** reserves it for you.
4. Leaving explains the exit notice and has the button to give it.

![](/guides/img/owner-03-vehicle-desktop-fc3e7e98.jpg "desktop; size: 1440 1292; address: carmacars.ca/owner/vehicles/aece3b1c-489e-4ad0-a2f0-c34415506c58; pins: 1 47.9 14.9, 2 73.4 24.6, 3 23.3 76.4, 4 81.9 64.6")

While a car is being set up, its page also shows the onboarding checklist and the uploads it still needs: the ownership permit, the lender''s permission and the insurance.

## Take new listing photos

Good photos get more bookings. You can shoot them yourself with your phone.

1. On the car''s page, press **Add listing photos** (or **Take new photos** for a car already live).
2. Read the tips for each shot: daylight, a plain background, the phone held landscape.
3. Press **Take photo** for each shot in the list. Press **Retake** if one is not right.
4. The bar shows how many required photos you have.
5. Press **Submit for listing**. New photos replace the current ones once our team approves them.

![](/guides/img/field-06-photo-shoot-capture-phone-d0b13740.jpg "phone; size: 390 610; pins: 4 92.3 43.4, 3 76.9 70.2")
', 'Home and your vehicles', 'What Home shows, each car''s page, adding a car and new listing photos.',
  'Home tells you what to do next. Each car has its own page with its status, terms, bookings, invoices and photos.

## Home at a glance

1. The menu: Home, Vehicles, Bookings, Invoices, Statements, Payouts, Documents, Banking, Notifications and Profile.
2. Your vehicles: each car with its status and what it needs next.
3. Money: what is due now, your fees each month, the next billing date and the next payout date.
4. Got another car? Press **Add a vehicle**.

![](/guides/img/owner-01-home-desktop-841aa611.jpg "desktop; size: 1440 760; address: carmacars.ca/owner; pins: 1 32.6 22.9, 2 42.7 52.6, 3 74.7 50.0, 4 38.9 46.1")

> Tip: When something needs you (a signature, a payment or an upload), it is the first thing on Home.

## A car''s page

Open Vehicles, then a car.

1. The top shows the car, its plate and how it is enrolled, with its status.
2. Terms: the Insurance Fee, the Revenue Share, your enrolment date and a link to the listing.
3. Bookings shows every trip in your car. **Book it for myself** reserves it for you.
4. Leaving explains the exit notice and has the button to give it.

![](/guides/img/owner-03-vehicle-desktop-fc3e7e98.jpg "desktop; size: 1440 1292; address: carmacars.ca/owner/vehicles/aece3b1c-489e-4ad0-a2f0-c34415506c58; pins: 1 47.9 14.9, 2 73.4 24.6, 3 23.3 76.4, 4 81.9 64.6")

While a car is being set up, its page also shows the onboarding checklist and the uploads it still needs: the ownership permit, the lender''s permission and the insurance.

## Service and maintenance

On a car''s page, under Service and maintenance.

- What is due on your car (oil change, tires, brakes, inspections, the registration) and the tires on it.
- Every service we recorded: the date, the odometer, the shop, what was done and who paid.
- You pay for maintenance and routine wear (your agreement, 11.1). A service we paid for shows its amount and is deducted on your next statement as an owner cost.
- It is read only: call or message us about a service.

## Take new listing photos

Good photos get more bookings. You can shoot them yourself with your phone.

1. On the car''s page, press **Add listing photos** (or **Take new photos** for a car already live).
2. Read the tips for each shot: daylight, a plain background, the phone held landscape.
3. Press **Take photo** for each shot in the list. Press **Retake** if one is not right.
4. The bar shows how many required photos you have.
5. Press **Submit for listing**. New photos replace the current ones once our team approves them.

![](/guides/img/field-06-photo-shoot-capture-phone-d0b13740.jpg "phone; size: 390 610; pins: 4 92.3 43.4, 3 76.9 70.2")
',
  '<p class="gd-p">Home tells you what to do next. Each car has its own page with its status, terms, bookings, invoices and photos.</p><section class="gd-task" id="home-and-your-vehicles-home-at-a-glance" data-gd-task><h2 class="gd-h2">Home at a glance</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The menu: Home, Vehicles, Bookings, Invoices, Statements, Payouts, Documents, Banking, Notifications and Profile.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Your vehicles: each car with its status and what it needs next.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Money: what is due now, your fees each month, the next billing date and the next payout date.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Got another car? Press <b class="gd-ui">Add a vehicle</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/760"><img src="/guides/img/owner-01-home-desktop-841aa611.jpg" alt="" loading="lazy" decoding="async" width="1440" height="760"><span class="gd-pin" style="left:32.6%;top:22.9%" aria-hidden="true">1</span><span class="gd-pin" style="left:42.7%;top:52.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:74.7%;top:50%" aria-hidden="true">3</span><span class="gd-pin" style="left:38.9%;top:46.1%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>When something needs you (a signature, a payment or an upload), it is the first thing on Home.</div></aside></section><section class="gd-task" id="home-and-your-vehicles-a-car-s-page" data-gd-task><h2 class="gd-h2">A car&#39;s page</h2><p class="gd-p">Open Vehicles, then a car.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The top shows the car, its plate and how it is enrolled, with its status.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Terms: the Insurance Fee, the Revenue Share, your enrolment date and a link to the listing.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Bookings shows every trip in your car. <b class="gd-ui">Book it for myself</b> reserves it for you.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Leaving explains the exit notice and has the button to give it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/vehicles/aece3b1c-489e-4ad0-a2f0-c34415506c58</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1292"><img src="/guides/img/owner-03-vehicle-desktop-fc3e7e98.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1292"><span class="gd-pin" style="left:47.9%;top:14.9%" aria-hidden="true">1</span><span class="gd-pin" style="left:73.4%;top:24.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:23.3%;top:76.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:81.9%;top:64.6%" aria-hidden="true">4</span></div></div></figure></div><p class="gd-p">While a car is being set up, its page also shows the onboarding checklist and the uploads it still needs: the ownership permit, the lender&#39;s permission and the insurance.</p></section><section class="gd-task" id="home-and-your-vehicles-service-and-maintenance" data-gd-task><h2 class="gd-h2">Service and maintenance</h2><p class="gd-p">On a car&#39;s page, under Service and maintenance.</p><ul class="gd-ul"><li>What is due on your car (oil change, tires, brakes, inspections, the registration) and the tires on it.</li><li>Every service we recorded: the date, the odometer, the shop, what was done and who paid.</li><li>You pay for maintenance and routine wear (your agreement, 11.1). A service we paid for shows its amount and is deducted on your next statement as an owner cost.</li><li>It is read only: call or message us about a service.</li></ul></section><section class="gd-task" id="home-and-your-vehicles-take-new-listing-photos" data-gd-task><h2 class="gd-h2">Take new listing photos</h2><p class="gd-p">Good photos get more bookings. You can shoot them yourself with your phone.</p><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On the car&#39;s page, press <b class="gd-ui">Add listing photos</b> (or <b class="gd-ui">Take new photos</b> for a car already live).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Read the tips for each shot: daylight, a plain background, the phone held landscape.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Take photo</b> for each shot in the list. Press <b class="gd-ui">Retake</b> if one is not right.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The bar shows how many required photos you have.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Submit for listing</b>. New photos replace the current ones once our team approves them.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/610"><img src="/guides/img/field-06-photo-shoot-capture-phone-d0b13740.jpg" alt="" loading="lazy" decoding="async" width="390" height="610"><span class="gd-pin" style="left:92.3%;top:43.4%" aria-hidden="true">4</span><span class="gd-pin" style="left:76.9%;top:70.2%" aria-hidden="true">3</span></div></div></figure></div></section>');
select app.guide_release_0095('admin', 'partners-company-cars-and-rentals-added-by-hand', 'chapter', 'fleet-and-listings', 'A car comes from one of three places: a program owner, CarmaCars itself, or a partner rental company. You add cars and rentals by hand, retire cars, and delete cars that were added by mistake.

## Add a car

**Cars** > **Vehicles**, then **Add a car**. Start with the VIN: everything else about the car comes from it.

1. Type or paste the VIN. At the 17th character the car is looked up: one line shows the year, make, model, trim, body, seats, doors, fuel, drive, gearbox and engine. Press Edit only if something is wrong.
2. No VIN at hand? Press **No VIN at hand? Add the car by its plate** and choose the year, make and model from the lists. The VIN can be added later; the details fill in then.
3. Tap the colour (it is not in the VIN). Leave it empty and it is read from the cover photo once the car has one.
4. Check the class. It is set from the make, model, body and age (a 2016 Porsche Macan is Premium, an SUV is SUV) and the line under it says why. Change it if it is wrong.
5. Choose who supplies it: **A program owner''s car** (choose the owner; the car starts its onboarding), **CarmaCars-owned (company fleet)** (no owner; all of its revenue is CarmaCars'') or **A partner rental company''s car** (choose the partner; leave the commission empty to use the partner''s).
6. The daily rate is filled in from similar cars, else the class. Keep it, change it, or empty it and set the rates later on the car''s Rates tab. Press **Add the car**.

> Tip: The title, description and features are written by themselves right after the car is added, from the VIN details. Change any of them on the car''s listing; a field you change is kept.

> Good to know: Every car gets a fleet number and its standard settings the moment it is added: a complete rate card (the daily rate you typed or the suggested one, weekend, weekly and monthly from it, the kilometres a day, the extra kilometre rate, the deposit and the delivery and pickup fee of its class) and drivers 18 to 20 allowed. Each value set this way says (Set automatically) on the car''s Overview and Rates tab until you change it. The defaults come from Settings: Program and Fee defaults.

> Tip: A VIN that does not add up (one character misread) shows a warning; you can still save it. A VIN the decoder cannot read asks only the year, make and model and never stops you: the details fill in when it is read later. The duplicate check runs as for every car: a VIN only once, a plate on one active car, and a likely twin waits for you in Similar cars before it is published.

On a car''s page, **Who supplies the car** shows the supplier and the commission, and changes them. Vehicles filters by supply type.

## Partners

**Owners and partners** > **Partners**. Partner rental companies whose cars we rent out on commission.

1. Press **Add a partner**: business and legal name, contacts, HST number, commission and insurance with its expiry date.
2. Open a partner for its cars, bookings, statements, payouts and documents. A warning shows when its insurance expires soon, and Tasks gets a reminder (Program settings sets how many days before).
3. Banking (Admins only): **Save the payout account** for the account we pay the partner into. The account number is stored encrypted. Press **Verify** once checked.
4. Portal: **Invite to the owner portal** gives the partner the owner portal with its cars, bookings, statements and the partner agreement, filled in and signed on screen in three taps.
5. Signed on paper? Press **Print the partner agreement**, then record the signed scan under Record a paper signature.

## Add a rental by hand

**Bookings** > **Add a rental**. For phone, walk-in, Turo, partner and insurer bookings.

1. Choose the car and the dates. The check shows clashes with other bookings and the cleaning time after each trip. An Admin may book over a clash with a reason.
2. The dates decide the case, shown under them (nothing to tick): a pickup ahead is an upcoming rental, handed over at pickup as usual. A pickup already passed with the return ahead is a rental already underway: it is recorded as on trip from the pickup you enter, on any active car (even one closed to public bookings), and anything a handover checks that is still missing (signature, licence check, coverage proof, deposit, condition report, insurance) becomes a task. A return already passed is a rental that has ended: kept as completed, paid another way or unpaid.
3. Find the renter by name, email or phone, or add a new one: name, email, phone, date of birth and licence. Add any other drivers.
4. Check the price: the car''s rates, extras, coverage and deposit. An Admin may set the price by hand; assistants use the rate sheet and the discounts allowed.
5. A car whose listing is not finished (a draft listing, onboarding, no photos or no rates yet) can be rented at once: it shows Listing not finished in the car list and stays off the public site. With no rates yet, type the rental charge for the whole rental and the reason.
6. An owner''s car that is not on the fleet insurance policy yet: only an Admin adds its rentals, and ticks I checked that this car is insured for this rental. An owner''s car needs its terms (Revenue Share) first. The handover still needs the car on the fleet policy: press **Insurer confirmed** once the insurer confirms it.
7. Choose Where it came from and how it is paid: **Paid another way**, **Send a payment link**, **Charge the saved card when the renter signs** or **Unpaid: invoice later**.
8. Press **Check the calendar and the price**. Tick **Do not email the renter** if they should not get the confirmation. Press **Add the rental**.

> Tip: The rental is on the calendars at once (a payment link waits for the payment). The renter signs the rental agreement in their portal, or on paper and you record it. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign, and until then the rental is awaiting signature. On the booking, **Verified in person** records a licence checked at the counter. A rental already underway can be paid by payment link (the renter signs, then pays from their booking) or the saved card, like an upcoming one.

## Retire or delete a car

**Cars** > **Retire or delete**, or the car''s own page.

1. **Retire this car** takes the car off the site and the calendars and keeps every record. It needs no future confirmed booking. **Restore** brings it back.
2. **Delete this car** removes a car added by mistake, with its photos. Only a car with nothing tied to money (no confirmed or paid booking, payment, statement, toll or damage). Type the plate or the name to confirm.
3. Booking requests that never confirmed and never took money (requested, offered, declined, expired) do not stop a delete. The confirmation lists them; they are removed with the car and a copy is kept. The renters stay on file.
4. On the same page, **Delete all sample cars** deletes every sample car that meets the rule at once, with its requests. Type DELETE SAMPLE CARS to confirm; the ones kept show why, with the booking numbers.

## Sample cars on the site

**Cars** > **Vehicles**, or **Settings** > **Site**. The 20 example cars the site started with, so the fleet never looks empty while the real cars are listed.

1. **Hide sample cars** takes every sample car off the site in one click. Nothing stops it: not an enquiry, not an old request.
2. **Show sample cars** puts the 20 back, with their photos and rates. Ones that were deleted are made again.
3. On the site each one is marked "Example car". They never appear in search engines or the sitemap.
4. A request on a sample car is never a booking. It becomes an enquiry (number EQ-1001 and up) and customer service gets the task Suggest a similar real car.

> Tip: Hide the sample cars once enough real cars are on the site. Delete all sample cars removes them for good.

## Why a car is not on the site yet

**Cars** > **Vehicles**, the card Not on the site yet.

1. Every real car that is not on the site is listed with its next step first: the rates, Publish now, the listing review.
2. The same car is a line on To do with **Set rates and publish**. The car comes off both once it is on the site.
3. A car without photos is marked sample photos: once listed it shows a sample photo until its real photos are approved.

## Tolls when two rentals overlap

Bookings held for an insurer and other placeholders are never matched to a toll. When two real rentals overlap the toll time, nobody is charged automatically: the toll waits in the work queue under Two rentals, with both bookings, and you choose who pays.
', 'Partners, company cars and rentals added by hand', 'Add a car, partners, add a rental, retire or delete a car, sample cars and tolls with two rentals.',
  'A car comes from one of three places: a program owner, CarmaCars itself, or a partner rental company. You add cars and rentals by hand, retire cars, and delete cars that were added by mistake.

## Add a car

**Cars** > **Vehicles**, then **Add a car**. Start with the VIN: everything else about the car comes from it.

1. Type or paste the VIN. At the 17th character the car is looked up: one line shows the year, make, model, trim, body, seats, doors, fuel, drive, gearbox and engine. Press Edit only if something is wrong.
2. No VIN at hand? Press **No VIN at hand? Add the car by its plate** and choose the year, make and model from the lists. The VIN can be added later; the details fill in then.
3. Tap the colour (it is not in the VIN). Leave it empty and it is read from the cover photo once the car has one.
4. Check the class. It is set from the make, model, body and age (a 2016 Porsche Macan is Premium, an SUV is SUV) and the line under it says why. Change it if it is wrong.
5. Choose who supplies it: **A program owner''s car** (choose the owner; the car starts its onboarding), **CarmaCars-owned (company fleet)** (no owner; all of its revenue is CarmaCars'') or **A partner rental company''s car** (choose the partner; leave the commission empty to use the partner''s).
6. The daily rate is filled in from similar cars, else the class. Keep it, change it, or empty it and set the rates later on the car''s Rates tab. Press **Add the car**.

> Tip: The title, description and features are written by themselves right after the car is added, from the VIN details. Change any of them on the car''s listing; a field you change is kept.

> Good to know: Every car gets a fleet number and its standard settings the moment it is added: a complete rate card (the daily rate you typed or the suggested one, weekend, weekly and monthly from it, the kilometres a day, the extra kilometre rate, the deposit and the delivery and pickup fee of its class) and drivers 18 to 20 allowed. Each value set this way says (Set automatically) on the car''s Overview and Rates tab until you change it. The defaults come from Settings: Program and Fee defaults.

> Tip: A VIN that does not add up (one character misread) shows a warning; you can still save it. A VIN the decoder cannot read asks only the year, make and model and never stops you: the details fill in when it is read later. The duplicate check runs as for every car: a VIN only once, a plate on one active car, and a likely twin waits for you in Similar cars before it is published.

On a car''s page, **Who supplies the car** shows the supplier and the commission, and changes them. Vehicles filters by supply type.

## Partners

**Owners and partners** > **Partners**. Partner rental companies whose cars we rent out on commission.

1. Press **Add a partner**: business and legal name, contacts, HST number, commission and insurance with its expiry date.
2. Open a partner for its cars, bookings, statements, payouts and documents. A warning shows when its insurance expires soon, and Tasks gets a reminder (Program settings sets how many days before).
3. Banking (Admins only): **Save the payout account** for the account we pay the partner into. The account number is stored encrypted. Press **Verify** once checked.
4. Portal: **Invite to the owner portal** gives the partner the owner portal with its cars, bookings, statements and the partner agreement, filled in and signed on screen in three taps.
5. Signed on paper? Press **Print the partner agreement**, then record the signed scan under Record a paper signature.

## A partner fleet on its own rates

Some partners send a price sheet of their own rates instead of sharing what the renter pays. 01 Motors works this way: its whole fleet is on the site, and staff manage its cars (it has no portal sign-in yet; add its email on the partner page and invite it later).

1. **Owners and partners** > **Partners** > the partner. **Pricing** shows how it is paid: the renter pays the partner''s sheet rate plus the markup (10% unless you set another), rounded to the nearest dollar; CarmaCars keeps the markup plus its cut (20% of the sheet rate); the partner is owed the rest of its sheet rate. Press **Edit pricing** to change the markup, the cut or the basis for every car at once.
2. **Cars** lists each car with its sheet rates a day (1 to 2 days, 3 or more, 7 or more) and the renter''s rates. Press **Edit** on a car to change a negotiated rate, give that car its own markup or cut, mark it **Insurance included** or **No credit card needed**, or confirm its model year. The renter''s rates change at once.
3. The site shows these cars with their tiers (1 to 2 days, 3 to 6 days, 7 days or more) and "Guideline rates; final price confirmed after review". A car with insurance included needs no coverage choice from the renter (coverage option 4, confirmed by itself); a car with no credit card needed takes a debit card for the payment and the deposit. The deposit, the licence and identity checks and the ages stay the same.
4. The price sheet has no years, VINs or plates. Until you confirm the year, the site leaves it out and says "Year confirmed when you book"; an offer waits until the year is confirmed (Edit on the car, Model year). Add the plate and the VIN on the car''s page before its first handover.
5. Real photos: open the car (its name in Cars), **Photos**, and add them. Once approved they replace the eight studio stand-ins.

> Good to know: The partner''s monthly statement shows each rental at the sheet rate, the cut and the payout; never what the renter paid. A refund lowers the partner''s share in proportion; a discount CarmaCars gives comes out of the markup.

## Add a rental by hand

**Bookings** > **Add a rental**. For phone, walk-in, Turo, partner and insurer bookings.

1. Choose the car and the dates. The check shows clashes with other bookings and the cleaning time after each trip. An Admin may book over a clash with a reason.
2. The dates decide the case, shown under them (nothing to tick): a pickup ahead is an upcoming rental, handed over at pickup as usual. A pickup already passed with the return ahead is a rental already underway: it is recorded as on trip from the pickup you enter, on any active car (even one closed to public bookings), and anything a handover checks that is still missing (signature, licence check, coverage proof, deposit, condition report, insurance) becomes a task. A return already passed is a rental that has ended: kept as completed, paid another way or unpaid.
3. Find the renter by name, email or phone, or add a new one: name, email, phone, date of birth and licence. Add any other drivers.
4. Check the price: the car''s rates, extras, coverage and deposit. An Admin may set the price by hand; assistants use the rate sheet and the discounts allowed.
5. A car whose listing is not finished (a draft listing, onboarding, no photos or no rates yet) can be rented at once: it shows Listing not finished in the car list and stays off the public site. With no rates yet, type the rental charge for the whole rental and the reason.
6. An owner''s car that is not on the fleet insurance policy yet: only an Admin adds its rentals, and ticks I checked that this car is insured for this rental. An owner''s car needs its terms (Revenue Share) first. The handover still needs the car on the fleet policy: press **Insurer confirmed** once the insurer confirms it.
7. Choose Where it came from and how it is paid: **Paid another way**, **Send a payment link**, **Charge the saved card when the renter signs** or **Unpaid: invoice later**.
8. Press **Check the calendar and the price**. Tick **Do not email the renter** if they should not get the confirmation. Press **Add the rental**.

> Tip: The rental is on the calendars at once (a payment link waits for the payment). The renter signs the rental agreement in their portal, or on paper and you record it. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign, and until then the rental is awaiting signature. On the booking, **Verified in person** records a licence checked at the counter. A rental already underway can be paid by payment link (the renter signs, then pays from their booking) or the saved card, like an upcoming one.

## Retire or delete a car

**Cars** > **Retire or delete**, or the car''s own page.

1. **Retire this car** takes the car off the site and the calendars and keeps every record. It needs no future confirmed booking. **Restore** brings it back.
2. **Delete this car** removes a car added by mistake, with its photos. Only a car with nothing tied to money (no confirmed or paid booking, payment, statement, toll or damage). Type the plate or the name to confirm.
3. Booking requests that never confirmed and never took money (requested, offered, declined, expired) do not stop a delete. The confirmation lists them; they are removed with the car and a copy is kept. The renters stay on file.
4. On the same page, **Delete all sample cars** deletes every sample car that meets the rule at once, with its requests. Type DELETE SAMPLE CARS to confirm; the ones kept show why, with the booking numbers.

## Sample cars on the site

**Cars** > **Vehicles**, or **Settings** > **Site**. The 20 example cars the site started with, so the fleet never looks empty while the real cars are listed.

1. **Hide sample cars** asks first ("Hide all 20 sample cars from the site?"); press **Hide them** to take every sample car off the site at once, or **Keep them**. Nothing else stops it: not an enquiry, not an old request.
2. **Show sample cars** puts the 20 back, with their photos and rates. Ones that were deleted are made again.
3. On the site each one is marked "Example car". They never appear in search engines or the sitemap.
4. A request on a sample car is never a booking. It becomes an enquiry (number EQ-1001 and up) and customer service gets the task Suggest a similar real car.

> Tip: Hide the sample cars once enough real cars are on the site. Delete all sample cars removes them for good.

## Why a car is not on the site yet

**Cars** > **Vehicles**, the card Not on the site yet.

1. Every real car that is not on the site is listed with its next step first: the rates, Publish now, the listing review.
2. The same car is a line on To do with **Set rates and publish**. The car comes off both once it is on the site.
3. A car without photos is marked sample photos: once listed it shows a sample photo until its real photos are approved.

## Tolls when two rentals overlap

Bookings held for an insurer and other placeholders are never matched to a toll. When two real rentals overlap the toll time, nobody is charged automatically: the toll waits in the work queue under Two rentals, with both bookings, and you choose who pays.
',
  '<p class="gd-p">A car comes from one of three places: a program owner, CarmaCars itself, or a partner rental company. You add cars and rentals by hand, retire cars, and delete cars that were added by mistake.</p><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-add-a-car" data-gd-task><h2 class="gd-h2">Add a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, then <b class="gd-ui">Add a car</b>. Start with the VIN: everything else about the car comes from it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type or paste the VIN. At the 17th character the car is looked up: one line shows the year, make, model, trim, body, seats, doors, fuel, drive, gearbox and engine. Press Edit only if something is wrong.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">No VIN at hand? Press <b class="gd-ui">No VIN at hand? Add the car by its plate</b> and choose the year, make and model from the lists. The VIN can be added later; the details fill in then.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Tap the colour (it is not in the VIN). Leave it empty and it is read from the cover photo once the car has one.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Check the class. It is set from the make, model, body and age (a 2016 Porsche Macan is Premium, an SUV is SUV) and the line under it says why. Change it if it is wrong.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Choose who supplies it: <b class="gd-ui">A program owner&#39;s car</b> (choose the owner; the car starts its onboarding), <b class="gd-ui">CarmaCars-owned (company fleet)</b> (no owner; all of its revenue is CarmaCars&#39;) or <b class="gd-ui">A partner rental company&#39;s car</b> (choose the partner; leave the commission empty to use the partner&#39;s).</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">The daily rate is filled in from similar cars, else the class. Keep it, change it, or empty it and set the rates later on the car&#39;s Rates tab. Press <b class="gd-ui">Add the car</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The title, description and features are written by themselves right after the car is added, from the VIN details. Change any of them on the car&#39;s listing; a field you change is kept.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Every car gets a fleet number and its standard settings the moment it is added: a complete rate card (the daily rate you typed or the suggested one, weekend, weekly and monthly from it, the kilometres a day, the extra kilometre rate, the deposit and the delivery and pickup fee of its class) and drivers 18 to 20 allowed. Each value set this way says (Set automatically) on the car&#39;s Overview and Rates tab until you change it. The defaults come from Settings: Program and Fee defaults.</div></aside><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A VIN that does not add up (one character misread) shows a warning; you can still save it. A VIN the decoder cannot read asks only the year, make and model and never stops you: the details fill in when it is read later. The duplicate check runs as for every car: a VIN only once, a plate on one active car, and a likely twin waits for you in Similar cars before it is published.</div></aside><p class="gd-p">On a car&#39;s page, <b class="gd-ui">Who supplies the car</b> shows the supplier and the commission, and changes them. Vehicles filters by supply type.</p></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-partners" data-gd-task><h2 class="gd-h2">Partners</h2><p class="gd-p"><b class="gd-ui">Owners and partners</b> &gt; <b class="gd-ui">Partners</b>. Partner rental companies whose cars we rent out on commission.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Add a partner</b>: business and legal name, contacts, HST number, commission and insurance with its expiry date.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a partner for its cars, bookings, statements, payouts and documents. A warning shows when its insurance expires soon, and Tasks gets a reminder (Program settings sets how many days before).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Banking (Admins only): <b class="gd-ui">Save the payout account</b> for the account we pay the partner into. The account number is stored encrypted. Press <b class="gd-ui">Verify</b> once checked.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Portal: <b class="gd-ui">Invite to the owner portal</b> gives the partner the owner portal with its cars, bookings, statements and the partner agreement, filled in and signed on screen in three taps.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Signed on paper? Press <b class="gd-ui">Print the partner agreement</b>, then record the signed scan under Record a paper signature.</div></li></ol></div></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-a-partner-fleet-on-its-own-rates" data-gd-task><h2 class="gd-h2">A partner fleet on its own rates</h2><p class="gd-p">Some partners send a price sheet of their own rates instead of sharing what the renter pays. 01 Motors works this way: its whole fleet is on the site, and staff manage its cars (it has no portal sign-in yet; add its email on the partner page and invite it later).</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Owners and partners</b> &gt; <b class="gd-ui">Partners</b> &gt; the partner. <b class="gd-ui">Pricing</b> shows how it is paid: the renter pays the partner&#39;s sheet rate plus the markup (10% unless you set another), rounded to the nearest dollar; CarmaCars keeps the markup plus its cut (20% of the sheet rate); the partner is owed the rest of its sheet rate. Press <b class="gd-ui">Edit pricing</b> to change the markup, the cut or the basis for every car at once.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Cars</b> lists each car with its sheet rates a day (1 to 2 days, 3 or more, 7 or more) and the renter&#39;s rates. Press <b class="gd-ui">Edit</b> on a car to change a negotiated rate, give that car its own markup or cut, mark it <b class="gd-ui">Insurance included</b> or <b class="gd-ui">No credit card needed</b>, or confirm its model year. The renter&#39;s rates change at once.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The site shows these cars with their tiers (1 to 2 days, 3 to 6 days, 7 days or more) and &quot;Guideline rates; final price confirmed after review&quot;. A car with insurance included needs no coverage choice from the renter (coverage option 4, confirmed by itself); a car with no credit card needed takes a debit card for the payment and the deposit. The deposit, the licence and identity checks and the ages stay the same.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The price sheet has no years, VINs or plates. Until you confirm the year, the site leaves it out and says &quot;Year confirmed when you book&quot;; an offer waits until the year is confirmed (Edit on the car, Model year). Add the plate and the VIN on the car&#39;s page before its first handover.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Real photos: open the car (its name in Cars), <b class="gd-ui">Photos</b>, and add them. Once approved they replace the eight studio stand-ins.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The partner&#39;s monthly statement shows each rental at the sheet rate, the cut and the payout; never what the renter paid. A refund lowers the partner&#39;s share in proportion; a discount CarmaCars gives comes out of the markup.</div></aside></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-add-a-rental-by-hand" data-gd-task><h2 class="gd-h2">Add a rental by hand</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Add a rental</b>. For phone, walk-in, Turo, partner and insurer bookings.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose the car and the dates. The check shows clashes with other bookings and the cleaning time after each trip. An Admin may book over a clash with a reason.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The dates decide the case, shown under them (nothing to tick): a pickup ahead is an upcoming rental, handed over at pickup as usual. A pickup already passed with the return ahead is a rental already underway: it is recorded as on trip from the pickup you enter, on any active car (even one closed to public bookings), and anything a handover checks that is still missing (signature, licence check, coverage proof, deposit, condition report, insurance) becomes a task. A return already passed is a rental that has ended: kept as completed, paid another way or unpaid.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Find the renter by name, email or phone, or add a new one: name, email, phone, date of birth and licence. Add any other drivers.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Check the price: the car&#39;s rates, extras, coverage and deposit. An Admin may set the price by hand; assistants use the rate sheet and the discounts allowed.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A car whose listing is not finished (a draft listing, onboarding, no photos or no rates yet) can be rented at once: it shows Listing not finished in the car list and stays off the public site. With no rates yet, type the rental charge for the whole rental and the reason.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">An owner&#39;s car that is not on the fleet insurance policy yet: only an Admin adds its rentals, and ticks I checked that this car is insured for this rental. An owner&#39;s car needs its terms (Revenue Share) first. The handover still needs the car on the fleet policy: press <b class="gd-ui">Insurer confirmed</b> once the insurer confirms it.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Choose Where it came from and how it is paid: <b class="gd-ui">Paid another way</b>, <b class="gd-ui">Send a payment link</b>, <b class="gd-ui">Charge the saved card when the renter signs</b> or <b class="gd-ui">Unpaid: invoice later</b>.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Press <b class="gd-ui">Check the calendar and the price</b>. Tick <b class="gd-ui">Do not email the renter</b> if they should not get the confirmation. Press <b class="gd-ui">Add the rental</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The rental is on the calendars at once (a payment link waits for the payment). The renter signs the rental agreement in their portal, or on paper and you record it. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign, and until then the rental is awaiting signature. On the booking, <b class="gd-ui">Verified in person</b> records a licence checked at the counter. A rental already underway can be paid by payment link (the renter signs, then pays from their booking) or the saved card, like an upcoming one.</div></aside></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-retire-or-delete-a-car" data-gd-task><h2 class="gd-h2">Retire or delete a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Retire or delete</b>, or the car&#39;s own page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Retire this car</b> takes the car off the site and the calendars and keeps every record. It needs no future confirmed booking. <b class="gd-ui">Restore</b> brings it back.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Delete this car</b> removes a car added by mistake, with its photos. Only a car with nothing tied to money (no confirmed or paid booking, payment, statement, toll or damage). Type the plate or the name to confirm.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Booking requests that never confirmed and never took money (requested, offered, declined, expired) do not stop a delete. The confirmation lists them; they are removed with the car and a copy is kept. The renters stay on file.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">On the same page, <b class="gd-ui">Delete all sample cars</b> deletes every sample car that meets the rule at once, with its requests. Type DELETE SAMPLE CARS to confirm; the ones kept show why, with the booking numbers.</div></li></ol></div></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-sample-cars-on-the-site" data-gd-task><h2 class="gd-h2">Sample cars on the site</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, or <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Site</b>. The 20 example cars the site started with, so the fleet never looks empty while the real cars are listed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Hide sample cars</b> asks first (&quot;Hide all 20 sample cars from the site?&quot;); press <b class="gd-ui">Hide them</b> to take every sample car off the site at once, or <b class="gd-ui">Keep them</b>. Nothing else stops it: not an enquiry, not an old request.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Show sample cars</b> puts the 20 back, with their photos and rates. Ones that were deleted are made again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the site each one is marked &quot;Example car&quot;. They never appear in search engines or the sitemap.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A request on a sample car is never a booking. It becomes an enquiry (number EQ-1001 and up) and customer service gets the task Suggest a similar real car.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Hide the sample cars once enough real cars are on the site. Delete all sample cars removes them for good.</div></aside></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-why-a-car-is-not-on-the-site-yet" data-gd-task><h2 class="gd-h2">Why a car is not on the site yet</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, the card Not on the site yet.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every real car that is not on the site is listed with its next step first: the rates, Publish now, the listing review.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The same car is a line on To do with <b class="gd-ui">Set rates and publish</b>. The car comes off both once it is on the site.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A car without photos is marked sample photos: once listed it shows a sample photo until its real photos are approved.</div></li></ol></div></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-tolls-when-two-rentals-overlap" data-gd-task><h2 class="gd-h2">Tolls when two rentals overlap</h2><p class="gd-p">Bookings held for an insurer and other placeholders are never matched to a toll. When two real rentals overlap the toll time, nobody is charged automatically: the toll waits in the work queue under Two rentals, with both bookings, and you choose who pays.</p></section>');
select app.guide_release_0095('admin', 'chauffeur-service', 'chapter', 'partners-company-cars-and-rentals-added-by-hand', null, 'Chauffeur service', 'Chauffeur requests: quote, confirm and close them; the vehicles and their hourly rates.',
  'Visitors book a driver and a luxury car or van by the hour on carmacars.ca/chauffeur. The vehicles come from a partner''s chauffeur price guide, each with a rate for 2 hours and a rate for 3 hours or more.

:::flow
Request | The visitor sends the date, hours and addresses
Quote | You check with the partner and send the quote
Confirm | The client agrees and pays
Done | Mark it completed after the trip
:::

## The requests

**Bookings** > **Chauffeur**. Each request has its number (CH-1001 and up), the vehicle, the date and start time, the hours, the pickup and drop-off addresses, the passengers, the occasion and the notes.

1. The **Quote** column is the price for the client: the hours at the 2-hour rate (exactly 2 hours) or the 3+ hour rate (3 hours or more), before HST, then HST and the total. The line under it is the quote line to send.
2. **Partner, CarmaCars** shows the partner''s sheet amount, what the partner is owed (the sheet amount less the cut) and what CarmaCars keeps (the markup plus the cut).
3. Check the vehicle and the driver with the partner for that time. To change the vehicle or the hours, press **Change**: the quote is worked out again.
4. Send the quote line by email or phone, then press **Quoted** and say how you sent it. The task in the queue is done.
5. When the client agrees, take the payment (a payment link, or at pickup), press **Confirm** and note how it is paid.
6. After the trip press **Completed**. **Decline** or **Cancel** closes a request with the reason.

> Tip: To do has a line **Chauffeur requests to quote** while any request is new, and the card Chauffeur today lists the confirmed trips of the day.

## The vehicles and their rates

**Owners and partners** > **Partners** > the partner, card Chauffeur vehicles.

1. Each vehicle shows the partner''s rates an hour and the client''s (the markup added, rounded to the nearest dollar).
2. Press **Edit** to change a rate, give it its own markup or cut, change the passengers, or take it off the site.
3. A vehicle the partner also rents (chauffeur / rental) links to its car pages on the public page.

> Good to know: Booking requests for cars, offers and payments do not cover chauffeur trips: a chauffeur request is a quote that you send and confirm here.
',
  '<p class="gd-p">Visitors book a driver and a luxury car or van by the hour on carmacars.ca/chauffeur. The vehicles come from a partner&#39;s chauffeur price guide, each with a rate for 2 hours and a rate for 3 hours or more.</p><ol class="gd-flow"><li><b>1</b><span>Request</span><em>The visitor sends the date, hours and addresses</em></li><li><b>2</b><span>Quote</span><em>You check with the partner and send the quote</em></li><li><b>3</b><span>Confirm</span><em>The client agrees and pays</em></li><li><b>4</b><span>Done</span><em>Mark it completed after the trip</em></li></ol><section class="gd-task" id="chauffeur-service-the-requests" data-gd-task><h2 class="gd-h2">The requests</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Chauffeur</b>. Each request has its number (CH-1001 and up), the vehicle, the date and start time, the hours, the pickup and drop-off addresses, the passengers, the occasion and the notes.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The <b class="gd-ui">Quote</b> column is the price for the client: the hours at the 2-hour rate (exactly 2 hours) or the 3+ hour rate (3 hours or more), before HST, then HST and the total. The line under it is the quote line to send.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Partner, CarmaCars</b> shows the partner&#39;s sheet amount, what the partner is owed (the sheet amount less the cut) and what CarmaCars keeps (the markup plus the cut).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check the vehicle and the driver with the partner for that time. To change the vehicle or the hours, press <b class="gd-ui">Change</b>: the quote is worked out again.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Send the quote line by email or phone, then press <b class="gd-ui">Quoted</b> and say how you sent it. The task in the queue is done.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">When the client agrees, take the payment (a payment link, or at pickup), press <b class="gd-ui">Confirm</b> and note how it is paid.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">After the trip press <b class="gd-ui">Completed</b>. <b class="gd-ui">Decline</b> or <b class="gd-ui">Cancel</b> closes a request with the reason.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>To do has a line <b class="gd-ui">Chauffeur requests to quote</b> while any request is new, and the card Chauffeur today lists the confirmed trips of the day.</div></aside></section><section class="gd-task" id="chauffeur-service-the-vehicles-and-their-rates" data-gd-task><h2 class="gd-h2">The vehicles and their rates</h2><p class="gd-p"><b class="gd-ui">Owners and partners</b> &gt; <b class="gd-ui">Partners</b> &gt; the partner, card Chauffeur vehicles.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each vehicle shows the partner&#39;s rates an hour and the client&#39;s (the markup added, rounded to the nearest dollar).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Edit</b> to change a rate, give it its own markup or cut, change the passengers, or take it off the site.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A vehicle the partner also rents (chauffeur / rental) links to its car pages on the public page.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Booking requests for cars, offers and payments do not cover chauffeur trips: a chauffeur request is a quote that you send and confirm here.</div></aside></section>');
select app.guide_release_0095('admin', 'live-visitors-and-live-chat', 'chapter', 'tolls-and-tickets', 'See who is on the site right now and what they look at, with buying signals, and answer the live chat. The CarmaCars assistant answers the chat first; you take over whenever you want, and it hands over by itself for complaints, damage, payments and anything it should not answer.

## Live visitors

Visitors who accepted analytics (or got the notice in Canada outside Quebec and the US), known customers on their own booking pages and anyone in a chat.

1. Open **Today** > **Live visitors**. The tiles count who is on the site now, hot visitors now, known customers, visits and chats today. The menu shows how many hot visitors are on the site.
2. Each visitor shows a booking likelihood from 0 to 100, with Hot (60 or more), Warm (30 or more) or Cold. The list is sorted by it; choose "Most recent" in Sort, or tick "Hot and warm only".
3. "Why" gives the three strongest reasons, for example "Pickup tomorrow · Reached step 3 of the request form · Tapped to call". The badges are all the signals of the visit; the dots say how strong each is.
4. Each visitor also shows their name when known (signed in, or arrived from one of our emails), otherwise "Visitor from Toronto, phone"; the page and car they are on, and how many others look at that car now; the device, city, the site or campaign that sent them and "from an ad".
5. Suggested: the best next step and the message to send. Press **Invite to chat with this message** to send it at once, **Edit the message** to change it first, **Offer a 10% discount code**, **Assign to Sales** or, when their dates are taken, **Suggest a similar free car**.
6. Press **Pages** for every page and event of the visit with each signal''s points, or **Start a chat** to write your own message. They see it in a bubble and reply from it.
7. Below: hot visitors today (and whether someone acted), the signals of the last 24 hours, and the most viewed cars of the week with prices shown and the car most compared with each. The page refreshes by itself every few seconds.

## The signals

Each signal adds points to the booking likelihood. They come from what the visitor does on the site, never from what they type.

- Intent: dates searched again and again, saw the full price, reached the booking form (and which step), came back for the same car on another day, comparing two or three cars, read the cancellation policy, read about the deposit, insurance or requirements, tapped to call, text or WhatsApp us or copied our number, checked delivery, looked through many photos or stayed long on one car.
- Urgency: pickup within 72 hours, weekend or holiday dates, on a phone late at night, came from a city or model page or a "near me" search.
- Value: a weekly or monthly rental, a premium car, SUV or van, adding a driver, asked about young drivers, a business email.
- Hesitation: watching the price (sorted by lowest price, lowered the price limit), left after seeing the price, unsure about the deposit, trouble with a form, the car not free for their dates.
- Context: came from an ad, a past renter, an offer or payment waiting, a game code not used yet, a popular car. The signals of known customers (offer opened, pay page left, change proposal, request stopped, returning visitor, viewing spree) count too.

## Hot visitors and the actions

- When a visitor turns hot, everyone with Live visitors open sees an alert at the top of the page. Turn on desktop alerts in Live chat to get one on your computer too; none come in the quiet hours (11 pm to 7 am). No email is sent.
- A discount code is single use, 10% off the rental charge (at most $75), valid 3 days, one per visitor a week and 10 a day per person. Admins and Sales send them; the code goes in the chat with the message.
- Assign to Sales gives the visitor to the Sales person on shift (or to you if you work Sales) and raises a task with the reasons and the contact when we know who they are.
- Each action shows on the visitor ("Invited by Lena, 2 min ago") so two people do not write to the same visitor.

## Signal settings

1. Open **Today** > **Live visitors** and press **Signal settings**.
2. Score and actions: from how many points a visitor is hot or warm, when a signal is strong or medium, the hot alert, and the discount code (percent, most off a booking, days valid, codes a day per person, whether customer service may send codes, and the message).
3. Each signal: on or off, its points, its thresholds (for example 72 hours for "Pickup soon", 3 searches for "Searching dates again and again"), the suggested action and the message. {car}, {days}, {pickup} and the other words in braces are filled in from the visit.
4. Press **Save the signals**. The next look at each visit uses them.

## Follow-up tasks

Signals of known visitors become tasks with a suggested action, for example "Call or message Maya Chen: opened offer CC-1042 twice, no answer for 6 hours".

- An offer opened and not answered: after 6 hours, to Sales when the booking is credited to someone in Sales, otherwise customer service.
- The pay page left without paying: after 30 minutes, customer service. The change proposal opened twice: customer service.
- A booking request started and stopped, or a viewing spree, by a known visitor: Sales.
- A task closes by itself when the renter answers the offer, pays or answers the proposal. Each signal raises one task only.
- The thresholds are in **Settings** > **Program**, group "Live visitors and live chat". Follow-ups done count in My sales.

## Recovery emails

Known renters who stop before finishing get one polite reminder, and at most one more a day later.

- An offer opened and not answered: after 4 hours. The pay page left without paying: after an hour. A change proposal opened and not answered: after 4 hours.
- A booking request started and not sent: after 2 hours, and only to renters who agreed to hear from us (marketing consent).
- Sent only between 9:00 and 21:00 Toronto time, never to someone who unsubscribed, and never while a staff member is handling the renter (a task they took, a chat with a person, a message from staff).
- They stop as soon as the renter answers, pays or sends the request; a reminder still waiting is not sent. The delays and hours are in Program settings, "Booking recovery emails".

## Interest in a car

**Cars** > **Vehicles**, a car, Overview: "Interest on the site" shows who is looking now, views today and in 7 days, the people who saw the price for their dates, conversion over 30 days (requests from the people who viewed it), the cars most often compared with it, and the last 14 days. The Vehicles list has "Most viewed cars this week".

## A renter''s visits

On a renter''s page (People > Renters, the name) and on a booking''s History tab, "On the site" lists when they viewed the offer, opened the change proposal, viewed or left the pay page, which cars they looked at, and their chats.

## Live chat

1. A visitor who asks for a person is a line on To do, marked Now: press **Open the chat**. Or open **Bookings** > **Live chat**. The menu counts chats waiting for a person. Open chats come first, those waiting for a person on top, with their minutes against the first reply target (5 minutes).
2. Choose a conversation. Beside it you see the visitor''s page, pages, signals, and the renter with their bookings when known.
3. Press **Take over**: the assistant stops and the visitor reads that you joined. Writing a reply also takes over. Press **Send** (or Enter).
4. **Hand back to the assistant** lets it answer again. **Close** ends the chat; if the visitor gave an email they get a copy. **Email the transcript** sends it any time.
5. Notify me: "Email me when a chat waits (while I am on shift)" and desktop alerts in this browser. You are on shift while Live chat or Live visitors is open.

> Tip: The assistant only repeats prices from our pricing (a quote or the car''s rates), never offers discounts or promises a car, never talks about insurance and never names a provider. Each reply it was not allowed to send says so in the conversation. When nobody is on shift, the chat asks for the visitor''s name, email or phone and raises a task. A booking from a chat you handled is credited only when you choose "I sourced this client" on the quote or offer.

## The assistant''s settings

In Program settings, "Live visitors and live chat": the chat on or off, the AI first or not, its model, the neurons it may use a day (6,000, about 10 chats; then chats wait for a person), the greeting on car pages after some seconds (off by default), how long chats and visits are kept (12 months and 90 days, as the privacy policy says).
', 'Live visitors and live chat', 'Who is on the site now, how likely each visitor is to book and why, one-click actions, follow-ups, interest per car, the chat inbox.',
  'See who is on the site right now and what they look at, with buying signals, and answer the live chat. The CarmaCars assistant answers the chat first; you take over whenever you want, and it hands over by itself for complaints, damage, payments and anything it should not answer.

## Live visitors

Visitors who accepted analytics (or got the notice in Canada outside Quebec and the US), known customers on their own booking pages and anyone in a chat.

1. Open **Today** > **Live visitors**. The tiles count who is on the site now, hot visitors now, known customers, visits and chats today. The menu shows how many hot visitors are on the site.
2. Each visitor shows a booking likelihood from 0 to 100, with Hot (60 or more), Warm (30 or more) or Cold. The list is sorted by it; choose "Most recent" in Sort, or tick "Hot and warm only".
3. "Why" gives the three strongest reasons, for example "Pickup tomorrow · Reached step 3 of the request form · Tapped to call". The badges are all the signals of the visit; the dots say how strong each is.
4. Each visitor also shows their name when known (signed in, or arrived from one of our emails), otherwise "Visitor from Toronto, phone"; the page and car they are on, and how many others look at that car now; the device, city, the site or campaign that sent them and "from an ad".
5. Suggested: the best next step and the message to send. Press **Invite to chat with this message** to send it at once, **Edit the message** to change it first, **Offer a 10% discount code**, **Assign to Sales** or, when their dates are taken, **Suggest a similar free car**.
6. Press **Pages** for every page and event of the visit with each signal''s points, or **Start a chat** to write your own message. They see it in a bubble and reply from it.
7. Below: hot visitors today (and whether someone acted), the signals of the last 24 hours, and the most viewed cars of the week with prices shown and the car most compared with each. The page refreshes by itself every few seconds.

## The signals

Each signal adds points to the booking likelihood. They come from what the visitor does on the site, never from what they type.

- Intent: dates searched again and again, saw the full price, reached the booking form (and which step), came back for the same car on another day, comparing two or three cars, read the cancellation policy, read about the deposit, insurance or requirements, tapped to call, text or WhatsApp us or copied our number, checked delivery, looked through many photos or stayed long on one car.
- Urgency: pickup within 72 hours, weekend or holiday dates, on a phone late at night, came from a city or model page or a "near me" search.
- Value: a weekly or monthly rental, a premium car, SUV or van, adding a driver, asked about young drivers, a business email.
- Hesitation: watching the price (sorted by lowest price, lowered the price limit), left after seeing the price, unsure about the deposit, trouble with a form, the car not free for their dates.
- Context: came from an ad, a past renter, an offer or payment waiting, a game code not used yet, a popular car. The signals of known customers (offer opened, pay page left, change proposal, request stopped, returning visitor, viewing spree) count too.

## Hot visitors and the actions

- When a visitor turns hot, everyone with Live visitors open sees an alert at the top of the page. Turn on desktop alerts in Live chat to get one on your computer too; none come in the quiet hours (11 pm to 7 am). No email is sent.
- A discount code is single use, 10% off the rental charge (at most $75), valid 3 days, one per visitor a week and 10 a day per person. Admins and Sales send them; the code goes in the chat with the message.
- Assign to Sales gives the visitor to the Sales person on shift (or to you if you work Sales) and raises a task with the reasons and the contact when we know who they are.
- Each action shows on the visitor ("Invited by Lena, 2 min ago") so two people do not write to the same visitor.

## Signal settings

1. Open **Today** > **Live visitors** and press **Signal settings**.
2. Score and actions: from how many points a visitor is hot or warm, when a signal is strong or medium, the hot alert, and the discount code (percent, most off a booking, days valid, codes a day per person, whether customer service may send codes, and the message).
3. Each signal: on or off, its points, its thresholds (for example 72 hours for "Pickup soon", 3 searches for "Searching dates again and again"), the suggested action and the message. {car}, {days}, {pickup} and the other words in braces are filled in from the visit.
4. Press **Save the signals**. The next look at each visit uses them.

## Follow-up tasks

Signals of known visitors become tasks with a suggested action, for example "Call or message Maya Chen: opened offer CC-1042 twice, no answer for 6 hours".

- An offer opened and not answered: after 6 hours, to Sales when the booking is credited to someone in Sales, otherwise customer service.
- The pay page left without paying: after 30 minutes, customer service. The change proposal opened twice: customer service.
- A booking request started and stopped, or a viewing spree, by a known visitor: Sales.
- A task closes by itself when the renter answers the offer, pays or answers the proposal. Each signal raises one task only.
- The thresholds are in **Settings** > **Program**, group "Live visitors and live chat". Follow-ups done count in My sales.

## Recovery emails

Known renters who stop before finishing get one polite reminder, and at most one more a day later.

- An offer opened and not answered: after 4 hours. The pay page left without paying: after an hour. A change proposal opened and not answered: after 4 hours.
- A booking request started and not sent: after 2 hours, and only to renters who agreed to hear from us (marketing consent).
- Sent only between 9:00 and 21:00 Toronto time, never to someone who unsubscribed, and never while a staff member is handling the renter (a task they took, a chat with a person, a message from staff).
- They stop as soon as the renter answers, pays or sends the request; a reminder still waiting is not sent. The delays and hours are in Program settings, "Booking recovery emails".

## Interest in a car

**Cars** > **Vehicles**, a car, Overview: "Interest on the site" shows who is looking now, views today and in 7 days, the people who saw the price for their dates, conversion over 30 days (requests from the people who viewed it), the cars most often compared with it, and the last 14 days. The Vehicles list has "Most viewed cars this week".

## A renter''s visits

On a renter''s page (People > Renters, the name) and on a booking''s History tab, "On the site" lists when they viewed the offer, opened the change proposal, viewed or left the pay page, which cars they looked at, and their chats.

## Live chat

1. A visitor who asks for a person is a line on To do, marked Now: press **Open the chat**. Or open **Bookings** > **Live chat**. The menu counts chats waiting for a person. Open chats come first, those waiting for a person on top, with their minutes against the first reply target (5 minutes).
2. Choose a conversation. Beside it you see the visitor''s page, pages, signals, and the renter with their bookings when known.
3. Press **Take over**: the assistant stops and the visitor reads that you joined. Writing a reply also takes over. Press **Send** (or Enter).
4. **Hand back to the assistant** lets it answer again. **Close** ends the chat; if the visitor gave an email they get a copy. **Email the transcript** sends it any time.
5. Notify me: "Email me when a chat waits (while I am on shift)" and desktop alerts in this browser. You are on shift while Live chat or Live visitors is open.

> Tip: The assistant only repeats prices from our pricing (a quote or the car''s rates), never offers discounts or promises a car, never talks about insurance and never names a provider. Each reply it was not allowed to send says so in the conversation. When nobody is on shift, the chat asks for the visitor''s name, email or phone and raises a task. A booking from a chat you handled is credited only when you choose "I sourced this client" on the quote or offer.

## The assistant''s settings

In Program settings, "Live visitors and live chat": the chat on or off, the AI first or not, its model, the neurons it may use a day (6,000, about 10 chats; then chats wait for a person), the greeting on car pages after some seconds (off by default), how long chats and visits are kept (12 months and 90 days, as the privacy policy says).

## What a visitor typed

A visitor who typed contact details into a form shows them on their line: "Typed into the booking request, not sent: Maya Chen, maya@example.com", with **Email not confirmed** until they open the link we emailed, and **Renter page**.
',
  '<p class="gd-p">See who is on the site right now and what they look at, with buying signals, and answer the live chat. The CarmaCars assistant answers the chat first; you take over whenever you want, and it hands over by itself for complaints, damage, payments and anything it should not answer.</p><section class="gd-task" id="live-visitors-and-live-chat-live-visitors" data-gd-task><h2 class="gd-h2">Live visitors</h2><p class="gd-p">Visitors who accepted analytics (or got the notice in Canada outside Quebec and the US), known customers on their own booking pages and anyone in a chat.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Today</b> &gt; <b class="gd-ui">Live visitors</b>. The tiles count who is on the site now, hot visitors now, known customers, visits and chats today. The menu shows how many hot visitors are on the site.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each visitor shows a booking likelihood from 0 to 100, with Hot (60 or more), Warm (30 or more) or Cold. The list is sorted by it; choose &quot;Most recent&quot; in Sort, or tick &quot;Hot and warm only&quot;.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">&quot;Why&quot; gives the three strongest reasons, for example &quot;Pickup tomorrow · Reached step 3 of the request form · Tapped to call&quot;. The badges are all the signals of the visit; the dots say how strong each is.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Each visitor also shows their name when known (signed in, or arrived from one of our emails), otherwise &quot;Visitor from Toronto, phone&quot;; the page and car they are on, and how many others look at that car now; the device, city, the site or campaign that sent them and &quot;from an ad&quot;.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Suggested: the best next step and the message to send. Press <b class="gd-ui">Invite to chat with this message</b> to send it at once, <b class="gd-ui">Edit the message</b> to change it first, <b class="gd-ui">Offer a 10% discount code</b>, <b class="gd-ui">Assign to Sales</b> or, when their dates are taken, <b class="gd-ui">Suggest a similar free car</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Press <b class="gd-ui">Pages</b> for every page and event of the visit with each signal&#39;s points, or <b class="gd-ui">Start a chat</b> to write your own message. They see it in a bubble and reply from it.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Below: hot visitors today (and whether someone acted), the signals of the last 24 hours, and the most viewed cars of the week with prices shown and the car most compared with each. The page refreshes by itself every few seconds.</div></li></ol></div></section><section class="gd-task" id="live-visitors-and-live-chat-the-signals" data-gd-task><h2 class="gd-h2">The signals</h2><p class="gd-p">Each signal adds points to the booking likelihood. They come from what the visitor does on the site, never from what they type.</p><ul class="gd-ul"><li>Intent: dates searched again and again, saw the full price, reached the booking form (and which step), came back for the same car on another day, comparing two or three cars, read the cancellation policy, read about the deposit, insurance or requirements, tapped to call, text or WhatsApp us or copied our number, checked delivery, looked through many photos or stayed long on one car.</li><li>Urgency: pickup within 72 hours, weekend or holiday dates, on a phone late at night, came from a city or model page or a &quot;near me&quot; search.</li><li>Value: a weekly or monthly rental, a premium car, SUV or van, adding a driver, asked about young drivers, a business email.</li><li>Hesitation: watching the price (sorted by lowest price, lowered the price limit), left after seeing the price, unsure about the deposit, trouble with a form, the car not free for their dates.</li><li>Context: came from an ad, a past renter, an offer or payment waiting, a game code not used yet, a popular car. The signals of known customers (offer opened, pay page left, change proposal, request stopped, returning visitor, viewing spree) count too.</li></ul></section><section class="gd-task" id="live-visitors-and-live-chat-hot-visitors-and-the-actions" data-gd-task><h2 class="gd-h2">Hot visitors and the actions</h2><ul class="gd-ul"><li>When a visitor turns hot, everyone with Live visitors open sees an alert at the top of the page. Turn on desktop alerts in Live chat to get one on your computer too; none come in the quiet hours (11 pm to 7 am). No email is sent.</li><li>A discount code is single use, 10% off the rental charge (at most $75), valid 3 days, one per visitor a week and 10 a day per person. Admins and Sales send them; the code goes in the chat with the message.</li><li>Assign to Sales gives the visitor to the Sales person on shift (or to you if you work Sales) and raises a task with the reasons and the contact when we know who they are.</li><li>Each action shows on the visitor (&quot;Invited by Lena, 2 min ago&quot;) so two people do not write to the same visitor.</li></ul></section><section class="gd-task" id="live-visitors-and-live-chat-signal-settings" data-gd-task><h2 class="gd-h2">Signal settings</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Today</b> &gt; <b class="gd-ui">Live visitors</b> and press <b class="gd-ui">Signal settings</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Score and actions: from how many points a visitor is hot or warm, when a signal is strong or medium, the hot alert, and the discount code (percent, most off a booking, days valid, codes a day per person, whether customer service may send codes, and the message).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each signal: on or off, its points, its thresholds (for example 72 hours for &quot;Pickup soon&quot;, 3 searches for &quot;Searching dates again and again&quot;), the suggested action and the message. {car}, {days}, {pickup} and the other words in braces are filled in from the visit.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Save the signals</b>. The next look at each visit uses them.</div></li></ol></div></section><section class="gd-task" id="live-visitors-and-live-chat-follow-up-tasks" data-gd-task><h2 class="gd-h2">Follow-up tasks</h2><p class="gd-p">Signals of known visitors become tasks with a suggested action, for example &quot;Call or message Maya Chen: opened offer CC-1042 twice, no answer for 6 hours&quot;.</p><ul class="gd-ul"><li>An offer opened and not answered: after 6 hours, to Sales when the booking is credited to someone in Sales, otherwise customer service.</li><li>The pay page left without paying: after 30 minutes, customer service. The change proposal opened twice: customer service.</li><li>A booking request started and stopped, or a viewing spree, by a known visitor: Sales.</li><li>A task closes by itself when the renter answers the offer, pays or answers the proposal. Each signal raises one task only.</li><li>The thresholds are in <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>, group &quot;Live visitors and live chat&quot;. Follow-ups done count in My sales.</li></ul></section><section class="gd-task" id="live-visitors-and-live-chat-recovery-emails" data-gd-task><h2 class="gd-h2">Recovery emails</h2><p class="gd-p">Known renters who stop before finishing get one polite reminder, and at most one more a day later.</p><ul class="gd-ul"><li>An offer opened and not answered: after 4 hours. The pay page left without paying: after an hour. A change proposal opened and not answered: after 4 hours.</li><li>A booking request started and not sent: after 2 hours, and only to renters who agreed to hear from us (marketing consent).</li><li>Sent only between 9:00 and 21:00 Toronto time, never to someone who unsubscribed, and never while a staff member is handling the renter (a task they took, a chat with a person, a message from staff).</li><li>They stop as soon as the renter answers, pays or sends the request; a reminder still waiting is not sent. The delays and hours are in Program settings, &quot;Booking recovery emails&quot;.</li></ul></section><section class="gd-task" id="live-visitors-and-live-chat-interest-in-a-car" data-gd-task><h2 class="gd-h2">Interest in a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, a car, Overview: &quot;Interest on the site&quot; shows who is looking now, views today and in 7 days, the people who saw the price for their dates, conversion over 30 days (requests from the people who viewed it), the cars most often compared with it, and the last 14 days. The Vehicles list has &quot;Most viewed cars this week&quot;.</p></section><section class="gd-task" id="live-visitors-and-live-chat-a-renter-s-visits" data-gd-task><h2 class="gd-h2">A renter&#39;s visits</h2><p class="gd-p">On a renter&#39;s page (People &gt; Renters, the name) and on a booking&#39;s History tab, &quot;On the site&quot; lists when they viewed the offer, opened the change proposal, viewed or left the pay page, which cars they looked at, and their chats.</p></section><section class="gd-task" id="live-visitors-and-live-chat-live-chat" data-gd-task><h2 class="gd-h2">Live chat</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A visitor who asks for a person is a line on To do, marked Now: press <b class="gd-ui">Open the chat</b>. Or open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Live chat</b>. The menu counts chats waiting for a person. Open chats come first, those waiting for a person on top, with their minutes against the first reply target (5 minutes).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose a conversation. Beside it you see the visitor&#39;s page, pages, signals, and the renter with their bookings when known.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Take over</b>: the assistant stops and the visitor reads that you joined. Writing a reply also takes over. Press <b class="gd-ui">Send</b> (or Enter).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Hand back to the assistant</b> lets it answer again. <b class="gd-ui">Close</b> ends the chat; if the visitor gave an email they get a copy. <b class="gd-ui">Email the transcript</b> sends it any time.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Notify me: &quot;Email me when a chat waits (while I am on shift)&quot; and desktop alerts in this browser. You are on shift while Live chat or Live visitors is open.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The assistant only repeats prices from our pricing (a quote or the car&#39;s rates), never offers discounts or promises a car, never talks about insurance and never names a provider. Each reply it was not allowed to send says so in the conversation. When nobody is on shift, the chat asks for the visitor&#39;s name, email or phone and raises a task. A booking from a chat you handled is credited only when you choose &quot;I sourced this client&quot; on the quote or offer.</div></aside></section><section class="gd-task" id="live-visitors-and-live-chat-the-assistant-s-settings" data-gd-task><h2 class="gd-h2">The assistant&#39;s settings</h2><p class="gd-p">In Program settings, &quot;Live visitors and live chat&quot;: the chat on or off, the AI first or not, its model, the neurons it may use a day (6,000, about 10 chats; then chats wait for a person), the greeting on car pages after some seconds (off by default), how long chats and visits are kept (12 months and 90 days, as the privacy policy says).</p></section><section class="gd-task" id="live-visitors-and-live-chat-what-a-visitor-typed" data-gd-task><h2 class="gd-h2">What a visitor typed</h2><p class="gd-p">A visitor who typed contact details into a form shows them on their line: &quot;Typed into the booking request, not sent: Maya Chen, maya@example.com&quot;, with <b class="gd-ui">Email not confirmed</b> until they open the link we emailed, and <b class="gd-ui">Renter page</b>.</p></section>');
select app.guide_release_0095('admin', 'discount-games-and-leads', 'chapter', 'texts-and-calls-the-quo-phone-line', 'Visitors who are not signed in and browse a few cars get one quick game: spin the wheel, scratch to reveal, quick blackjack, cup shuffle or Plinko. Every play wins a promo code. To see the code they give a first name and an email (a mobile number is optional), so you get a lead. It is on by default; nothing needs setting up.

## What the visitor sees

- After 2 car pages, or 60 seconds on the site, or (on a computer) when the mouse heads for the tabs. A card slides in at the bottom; on a phone it is a sheet at the bottom, never a full-screen block, and it always closes.
- Never for someone signed in or already known by email, never on booking, pay, sign or sign-in pages, never on the first page of a visit from a search engine on a phone, never over the cookie banner. After closing it, not again for 14 days; after claiming, never again.
- Every play wins: 5% off (70 in 100), 10% off (25), 15% off (4) or $50 off a rental of 3 days or more (1). The prize is decided before the game starts; the game only shows it. The short terms with the game list the prizes and say the chances differ.
- The code (for example WIN-7KQ4-XM2P) comes off the rental charge only, up to $75 for a percentage, on one booking, within 7 days, one per person, email, phone and device, never with another code. The email with the code goes either way; one reminder goes 24 hours before it expires. Offers only with the marketing box ticked.
- On this device the code fills itself into the promo code box of the request form. Like every promo code, the discount is shared with the owner in the split.

## Leads

**Bookings** > **Leads**.

1. The tiles: plays, claims, codes on booking requests, bookings, revenue and discounts from game codes in the last 30 days, then the same by game and by prize.
2. Each claim: when, the name (and "on the site now"), email and phone, the prize and game, the code and whether it is used (with the booking), marketing consent, and the visit: cars and pages viewed, minutes, city and device.
3. Press **Call** or **Email**, then **Contacted** (it is yours). **Close** with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.
4. A visitor who viewed 3 cars or more also gets a Sales task, for example "Claimed 10% off, viewed 6 cars: Maya". It closes when the code goes on a request.

## Settings

**Settings** > **Discount games**.

- On or off, the cap for percentage codes ($75), how long a code is good for (7 days), when it shows (2 car pages, 60 seconds, exit intent), the days before it shows again after closing (14), the cars viewed for a Sales task (3) and the reminder (24 hours).
- Prizes and games: each prize with its percent or dollars, a minimum rental length and its chance; each game''s weight (0 turns it off). Press **Save prizes and games**. Codes already sent keep their value.
', 'Discount games and leads', 'The giveaway game, the code it sends, game leads to call, and the report.',
  'Visitors who are not signed in and browse a few cars get one quick game: spin the wheel, scratch to reveal, quick blackjack, cup shuffle or Plinko. Every play wins a promo code. To see the code they give a first name and an email (a mobile number is optional), so you get a lead. It is on by default; nothing needs setting up.

## What the visitor sees

- After 2 car pages, or 60 seconds on the site, or (on a computer) when the mouse heads for the tabs. A card slides in at the bottom; on a phone it is a sheet at the bottom, never a full-screen block, and it always closes.
- Never for someone signed in or already known by email, never on booking, pay, sign or sign-in pages, never on the first page of a visit from a search engine on a phone, never over the cookie banner. After closing it, not again for 14 days; after claiming, never again.
- Every play wins: 5% off (70 in 100), 10% off (25), 15% off (4) or $50 off a rental of 3 days or more (1). The prize is decided before the game starts; the game only shows it. The short terms with the game list the prizes and say the chances differ.
- The code (for example WIN-7KQ4-XM2P) comes off the rental charge only, up to $75 for a percentage, on one booking, within 7 days, one per person, email, phone and device, never with another code. The email with the code goes either way; one reminder goes 24 hours before it expires. Offers only with the marketing box ticked.
- On this device the code fills itself into the promo code box of the request form. Like every promo code, the discount is shared with the owner in the split.

## Leads

**Bookings** > **Leads**.

1. The tiles: plays, claims, codes on booking requests, bookings, revenue and discounts from game codes in the last 30 days, then the same by game and by prize.
2. Each claim: when, the name (and "on the site now"), email and phone, the prize and game, the code and whether it is used (with the booking), marketing consent, and the visit: cars and pages viewed, minutes, city and device.
3. Press **Call** or **Email**, then **Contacted** (it is yours). **Close** with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.
4. A visitor who viewed 3 cars or more also gets a Sales task, for example "Claimed 10% off, viewed 6 cars: Maya". It closes when the code goes on a request.

## Contact details typed into forms

**Bookings** > **Leads**, the card "Typed into forms" at the top.

1. When someone types a name, email or phone into the request to book, the contact form, List your car, the owner application, Create an account, the discount game or the chat, it is saved as soon as each field is valid, even if they never press Send.
2. Each line: when, the name (and "On the site now"), email and phone, the form, and Sent or Not sent. "Email not confirmed" means the account was opened from the form and the person has not opened the link we emailed them yet.
3. After 30 minutes without sending, To do shows "Unfinished request from Maya Chen: follow up" (not raised from 23:00 to 07:00, the quiet hours of the site alerts). Call or email them; the task closes by itself when they send the form.
4. Only what they typed is saved, and never used for offers without their consent.

> Good to know: A new email gets an account at once (no password, email not confirmed) and one email "Continue your request" 30 minutes later, between 9:00 and 21:00. Until they open its link they cannot accept an offer, sign, pay or upload documents. An account never confirmed closes after 30 days; the lead stays. It is on by default; the times and the To do are in **Settings** > **Program**, the card "Forms left unfinished".

## Settings

**Settings** > **Discount games**.

- On or off, the cap for percentage codes ($75), how long a code is good for (7 days), when it shows (2 car pages, 60 seconds, exit intent), the days before it shows again after closing (14), the cars viewed for a Sales task (3) and the reminder (24 hours).
- Prizes and games: each prize with its percent or dollars, a minimum rental length and its chance; each game''s weight (0 turns it off). Press **Save prizes and games**. Codes already sent keep their value.
',
  '<p class="gd-p">Visitors who are not signed in and browse a few cars get one quick game: spin the wheel, scratch to reveal, quick blackjack, cup shuffle or Plinko. Every play wins a promo code. To see the code they give a first name and an email (a mobile number is optional), so you get a lead. It is on by default; nothing needs setting up.</p><section class="gd-task" id="discount-games-and-leads-what-the-visitor-sees" data-gd-task><h2 class="gd-h2">What the visitor sees</h2><ul class="gd-ul"><li>After 2 car pages, or 60 seconds on the site, or (on a computer) when the mouse heads for the tabs. A card slides in at the bottom; on a phone it is a sheet at the bottom, never a full-screen block, and it always closes.</li><li>Never for someone signed in or already known by email, never on booking, pay, sign or sign-in pages, never on the first page of a visit from a search engine on a phone, never over the cookie banner. After closing it, not again for 14 days; after claiming, never again.</li><li>Every play wins: 5% off (70 in 100), 10% off (25), 15% off (4) or $50 off a rental of 3 days or more (1). The prize is decided before the game starts; the game only shows it. The short terms with the game list the prizes and say the chances differ.</li><li>The code (for example WIN-7KQ4-XM2P) comes off the rental charge only, up to $75 for a percentage, on one booking, within 7 days, one per person, email, phone and device, never with another code. The email with the code goes either way; one reminder goes 24 hours before it expires. Offers only with the marketing box ticked.</li><li>On this device the code fills itself into the promo code box of the request form. Like every promo code, the discount is shared with the owner in the split.</li></ul></section><section class="gd-task" id="discount-games-and-leads-leads" data-gd-task><h2 class="gd-h2">Leads</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Leads</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The tiles: plays, claims, codes on booking requests, bookings, revenue and discounts from game codes in the last 30 days, then the same by game and by prize.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each claim: when, the name (and &quot;on the site now&quot;), email and phone, the prize and game, the code and whether it is used (with the booking), marketing consent, and the visit: cars and pages viewed, minutes, city and device.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Call</b> or <b class="gd-ui">Email</b>, then <b class="gd-ui">Contacted</b> (it is yours). <b class="gd-ui">Close</b> with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A visitor who viewed 3 cars or more also gets a Sales task, for example &quot;Claimed 10% off, viewed 6 cars: Maya&quot;. It closes when the code goes on a request.</div></li></ol></div></section><section class="gd-task" id="discount-games-and-leads-contact-details-typed-into-forms" data-gd-task><h2 class="gd-h2">Contact details typed into forms</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Leads</b>, the card &quot;Typed into forms&quot; at the top.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">When someone types a name, email or phone into the request to book, the contact form, List your car, the owner application, Create an account, the discount game or the chat, it is saved as soon as each field is valid, even if they never press Send.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each line: when, the name (and &quot;On the site now&quot;), email and phone, the form, and Sent or Not sent. &quot;Email not confirmed&quot; means the account was opened from the form and the person has not opened the link we emailed them yet.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">After 30 minutes without sending, To do shows &quot;Unfinished request from Maya Chen: follow up&quot; (not raised from 23:00 to 07:00, the quiet hours of the site alerts). Call or email them; the task closes by itself when they send the form.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Only what they typed is saved, and never used for offers without their consent.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A new email gets an account at once (no password, email not confirmed) and one email &quot;Continue your request&quot; 30 minutes later, between 9:00 and 21:00. Until they open its link they cannot accept an offer, sign, pay or upload documents. An account never confirmed closes after 30 days; the lead stays. It is on by default; the times and the To do are in <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>, the card &quot;Forms left unfinished&quot;.</div></aside></section><section class="gd-task" id="discount-games-and-leads-settings" data-gd-task><h2 class="gd-h2">Settings</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Discount games</b>.</p><ul class="gd-ul"><li>On or off, the cap for percentage codes ($75), how long a code is good for (7 days), when it shows (2 car pages, 60 seconds, exit intent), the days before it shows again after closing (14), the cars viewed for a Sales task (3) and the reminder (24 hours).</li><li>Prizes and games: each prize with its percent or dollars, a minimum rental length and its chance; each game&#39;s weight (0 turns it off). Press <b class="gd-ui">Save prizes and games</b>. Codes already sent keep their value.</li></ul></section>');
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
select app.guide_release_0095('admin', 'settings', 'chapter', 'search-car-pages-landing-pages-and-guides', 'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Coverage prices, Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.
5. Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press **Save the defaults**.
6. Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.
7. Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).
8. Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.
9. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")

## Official ServiceOntario forms

The five official forms are loaded with a draft mapping to the owner, car, company and lender details. Until you check a form, owners get a data sheet with the values.

1. Open **Settings** > **Forms**. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Press **Download a filled preview** for one car and check each value against the form.
3. Change a field if needed: What goes in it (or "The owner signs here"), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed, and owners sign it with their other documents. Each form not checked yet is also a line on To do with the same button and Preview it.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, or on paper.

1. Investor: open **People** > **Investors** and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Once the investor signs, the agreement shows **Awaiting countersignature** on the investor''s page and on To do. It is not countersigned automatically: check it and press **Countersign**. CarmaCars is bound once it has countersigned and the funds clear.
3. Staff: open **People** > **Staff**. Under Staff agreements, press **Send the agreement to sign** beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.
4. A field staff member''s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.
5. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
6. Your own PDF instead? **Send a PDF to sign** still works.
7. Signed on paper instead? Press **Record paper signature** in the same place and upload the scan.
8. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

**Settings** > **Guides**. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## The guides keep up by themselves

After every update of the site that changes the portals, the guides are checked without anyone asking.

1. Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.
2. The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal''s own labels and menu, checked, and published. The PDFs of those guides are printed again.
3. Such a section says **Changed automatically on** and the date, in the list of guides and in the guide''s editor. Not right? Open the section and press **Revert**: the text it replaced comes back, published at once.
4. This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section''s history. There is nothing to review.
5. A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.

> Tip: The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.
', 'Settings', 'Site, program settings, official forms mapping, insurers and the other lists.',
  'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Coverage prices, Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.
5. Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press **Save the defaults**.
6. Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.
7. Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).
8. Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.
9. Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.
10. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")

## Official ServiceOntario forms

The five official forms are loaded with a draft mapping to the owner, car, company and lender details. Until you check a form, owners get a data sheet with the values.

1. Open **Settings** > **Forms**. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Press **Download a filled preview** for one car and check each value against the form.
3. Change a field if needed: What goes in it (or "The owner signs here"), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed, and owners sign it with their other documents. Each form not checked yet is also a line on To do with the same button and Preview it.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, or on paper.

1. Investor: open **People** > **Investors** and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Once the investor signs, the agreement shows **Awaiting countersignature** on the investor''s page and on To do. It is not countersigned automatically: check it and press **Countersign**. CarmaCars is bound once it has countersigned and the funds clear.
3. Staff: open **People** > **Staff**. Under Staff agreements, press **Send the agreement to sign** beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.
4. A field staff member''s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.
5. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
6. Your own PDF instead? **Send a PDF to sign** still works.
7. Signed on paper instead? Press **Record paper signature** in the same place and upload the scan.
8. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

**Settings** > **Guides**. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## The guides keep up by themselves

After every update of the site that changes the portals, the guides are checked without anyone asking.

1. Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.
2. The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal''s own labels and menu, checked, and published. The PDFs of those guides are printed again.
3. Such a section says **Changed automatically on** and the date, in the list of guides and in the guide''s editor. Not right? Open the section and press **Revert**: the text it replaced comes back, published at once.
4. This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section''s history. There is nothing to review.
5. A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.

> Tip: The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.
',
  '<p class="gd-p">Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.</p><section class="gd-task" id="settings-the-settings-page" data-gd-task><h2 class="gd-h2">The Settings page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Site setup lists what is still missing on the public site, with <b class="gd-ui">Open site settings</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Program settings: every timing and policy value.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Forms: the official ServiceOntario PDFs and what goes in each field.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Insurers: insurance companies billed for bookings.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-24-settings-desktop-89b31691.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:32.6%;top:33%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.8%;top:40.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.4%;top:40.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:25.8%;top:73.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:25.8%;top:84.9%" aria-hidden="true">5</span></div></div></figure></div><p class="gd-p">The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Coverage prices, Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.</p></section><section class="gd-task" id="settings-program-settings" data-gd-task><h2 class="gd-h2">Program settings</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month&#39;s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press <b class="gd-ui">Save the defaults</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Change a value and press <b class="gd-ui">Save</b>. It is saved as a new row from today; the rows before stay as they were.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/program</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/admin-25-program-settings-desktop-d16b066c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:25.8%;top:22%" aria-hidden="true">1</span><span class="gd-pin" style="left:27.8%;top:49%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="settings-official-serviceontario-forms" data-gd-task><h2 class="gd-h2">Official ServiceOntario forms</h2><p class="gd-p">The five official forms are loaded with a draft mapping to the owner, car, company and lender details. Until you check a form, owners get a data sheet with the values.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. Each form shows &quot;Mapping to check&quot; (a draft is ready) or &quot;Official PDF in use&quot;. Its notes say what the form is for and which boxes are left blank on purpose.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download a filled preview</b> for one car and check each value against the form.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Change a field if needed: What goes in it (or &quot;The owner signs here&quot;), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for owners</b>. Every owner&#39;s form of that kind is filled again, except ones already signed or filed, and owners sign it with their other documents. Each form not checked yet is also a line on To do with the same button and Preview it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A new version from ServiceOntario? Press <b class="gd-ui">Upload the official fillable PDF</b>: the fields of the same name keep their mapping.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company&#39;s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner&#39;s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person.</div></aside></section><section class="gd-task" id="settings-agreements-to-sign-investors-and-staff" data-gd-task><h2 class="gd-h2">Agreements to sign: investors and staff</h2><p class="gd-p">Investment agreements and staff agreements are made from the person&#39;s record and signed in their own portal, or on paper.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Investor: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Investors</b> and the investor. Under Investment agreement, press <b class="gd-ui">Send the agreement to sign</b>. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press <b class="gd-ui">Send to sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Once the investor signs, the agreement shows <b class="gd-ui">Awaiting countersignature</b> on the investor&#39;s page and on To do. It is not countersigned automatically: check it and press <b class="gd-ui">Countersign</b>. CarmaCars is bound once it has countersigned and the funds clear.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Staff: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Staff</b>. Under Staff agreements, press <b class="gd-ui">Send the agreement to sign</b> beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A field staff member&#39;s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Your own PDF instead? <b class="gd-ui">Send a PDF to sign</b> still works.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Signed on paper instead? Press <b class="gd-ui">Record paper signature</b> in the same place and upload the scan.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Sent by mistake? Press <b class="gd-ui">Withdraw</b> and give the reason.</div></li></ol></div></section><section class="gd-task" id="settings-the-user-guides" data-gd-task><h2 class="gd-h2">The user guides</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Guides</b>. The guide of each portal, as people read it under Guide.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each guide shows its version, when it was published and whether there are unpublished changes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a guide and press a section. Change its text and press <b class="gd-ui">Show the preview</b> to see it as people will. Press <b class="gd-ui">Save the draft</b>; each save is kept in the section&#39;s history.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Move a section with the arrows, hide it, or press <b class="gd-ui">Add a chapter</b>. Upload a screenshot under Screenshots and paste the line it gives you.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Publish version</b> (the next number). The portals show the new version at once.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.</div></li></ol></div></section><section class="gd-task" id="settings-the-guides-keep-up-by-themselves" data-gd-task><h2 class="gd-h2">The guides keep up by themselves</h2><p class="gd-p">After every update of the site that changes the portals, the guides are checked without anyone asking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal&#39;s own labels and menu, checked, and published. The PDFs of those guides are printed again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Such a section says <b class="gd-ui">Changed automatically on</b> and the date, in the list of guides and in the guide&#39;s editor. Not right? Open the section and press <b class="gd-ui">Revert</b>: the text it replaced comes back, published at once.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section&#39;s history. There is nothing to review.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The card &quot;The guides keep up by themselves&quot; at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.</div></aside></section><section class="gd-task" id="settings-insurers-and-the-other-lists" data-gd-task><h2 class="gd-h2">Insurers and the other lists</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press <b class="gd-ui">Add</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.</div></li></ol></div></section>');
select app.guide_release_0095('admin', 'the-investor-deck', 'chapter', 'add-ons', 'The investor deck is a slide deck in the investor portal at `/investor/deck`. Signed-in investors see it while it is shown; Admins always see it. Its figures come from the database when it opens: the owner fee tiers, the partner commission, the real cars'' public rates, delivery, add-ons and renter fees, the deductible and deposits, and the investment terms of Program settings.

## Preview and settings

1. Go to **Investors** and press **Investor deck**. The button says whether investors see it now.
2. The page shows the settings, then the whole deck as investors see it.
3. **Show the deck to investors**: on, investors see it under Investor deck and on their Investments page; off, only Admins see it.
4. **Multiplier on the money we invest (x)**: the company''s own figure, shown large on the profitability slide with its footnote (internal, not audited).
5. **Yearly percentage of the current offer (%)**: used by the worked examples and the calculator. Each investor''s own percentage is the one in their agreement.
6. Press **Save deck settings**. Every change is in the audit log.

To hide or show it in one click, use **Hide the deck from investors** or **Show the deck to investors** on Investors.

> Good to know: The deck shows no internal costs, fleet counts or staff pay. Every example is labelled as an illustration, with the forward-looking statements notice on every slide and in the PDF.
', 'The investor deck', 'Preview the deck, show or hide it, and set its multiplier and percentage.',
  'The investor deck is a slide deck in the investor portal at `/investor/deck`. Signed-in investors see it while it is shown; Admins always see it. Its figures come from the database when it opens: the owner fee tiers, the partner commission, the real cars'' public rates, delivery, add-ons and renter fees, the deductible and deposits, and the investment terms of Program settings.

## Preview and settings

1. Go to **Investors** and press **Investor deck**. The button says whether investors see it now.
2. The page shows the settings, then the whole deck as investors see it.
3. **Show the deck to investors**: on, investors see it under Investor deck and on their Investments page; off, only Admins see it.
4. **Multiplier on the money we invest (x)**: the company''s own figure, shown large on the profitability slide with its footnote (internal, not audited).
5. **Yearly percentage of the current offer (%)**: used by the worked examples and the calculator. Each investor''s own percentage is the one in their agreement.
6. Press **Save deck settings**. Every change is in the audit log.

To hide or show it in one click, use **Hide the deck from investors** or **Show the deck to investors** on Investors.

How we make money is one slide with the seven revenue lines: our own cars, owners'' cars fully managed with coverage under our fleet policy, coverage under our fleet policy for owners who manage their own cars, Turo management, brokering partner fleets with the chauffeur service, detailing, and the body shop. The features include maintenance and service tracking, phone number sign-in, saving contacts from unfinished forms and smart Turo car matching.

> Good to know: The deck shows no internal costs, fleet counts or staff pay. Every example is labelled as an illustration, with the forward-looking statements notice on every slide and in the PDF.
',
  '<p class="gd-p">The investor deck is a slide deck in the investor portal at <span class="gd-url">/investor/deck</span>. Signed-in investors see it while it is shown; Admins always see it. Its figures come from the database when it opens: the owner fee tiers, the partner commission, the real cars&#39; public rates, delivery, add-ons and renter fees, the deductible and deposits, and the investment terms of Program settings.</p><section class="gd-task" id="the-investor-deck-preview-and-settings" data-gd-task><h2 class="gd-h2">Preview and settings</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Go to <b class="gd-ui">Investors</b> and press <b class="gd-ui">Investor deck</b>. The button says whether investors see it now.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The page shows the settings, then the whole deck as investors see it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Show the deck to investors</b>: on, investors see it under Investor deck and on their Investments page; off, only Admins see it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Multiplier on the money we invest (x)</b>: the company&#39;s own figure, shown large on the profitability slide with its footnote (internal, not audited).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Yearly percentage of the current offer (%)</b>: used by the worked examples and the calculator. Each investor&#39;s own percentage is the one in their agreement.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Press <b class="gd-ui">Save deck settings</b>. Every change is in the audit log.</div></li></ol></div><p class="gd-p">To hide or show it in one click, use <b class="gd-ui">Hide the deck from investors</b> or <b class="gd-ui">Show the deck to investors</b> on Investors.</p><p class="gd-p">How we make money is one slide with the seven revenue lines: our own cars, owners&#39; cars fully managed with coverage under our fleet policy, coverage under our fleet policy for owners who manage their own cars, Turo management, brokering partner fleets with the chauffeur service, detailing, and the body shop. The features include maintenance and service tracking, phone number sign-in, saving contacts from unfinished forms and smart Turo car matching.</p><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The deck shows no internal costs, fleet counts or staff pay. Every example is labelled as an illustration, with the forward-looking statements notice on every slide and in the PDF.</div></aside></section>');
select app.guide_release_0095('admin', 'maintenance-and-service', 'chapter', 'usage-and-paid-usage', null, 'Maintenance and service', 'The fleet overview, recording a service and its bill, tires and swaps, the odometer, intervals, reminders and blocks.',
  'Every real car has its service items: oil, tire rotation, brakes, tires, the seasonal swap, the safety inspection, the registration, battery, wipers, filters, alignment, fluids and the annual inspection. Record a service once and the bill is made and the timers reset by themselves.

## The fleet overview

Open **Cars** > **Maintenance**.

1. Every real car (sample cars are left out), most urgent first: overdue, then due soon, then cars with no record yet, then all OK.
2. Each car shows what is due next, its odometer, its km a day, the tires on it and the date of its last service.
3. Use Show, Service item, Sort and the search (car, plate or owner) to narrow the list, then press Apply.
4. Press **Record a service** on a car to record it without leaving the list.

| Status | Means |
| --- | --- |
| Overdue | Past its km or its date (whichever came first), or expired |
| Due soon | Within 1,000 km or 14 days of it (each item may have its own; inspections and registration: 30 days) |
| Unknown | No record yet: record the last time it was done |
| OK | Done, and not due soon |

## Record a service in one step

From the overview, the car''s **Maintenance** tab, or a To do line.

1. Tick what was done. The items due are ticked already.
2. Check the date and the odometer (filled with the current reading). Type the shop, the cost before HST and the HST (worked out at 13%, change it to match the receipt).
3. Who pays: the owner (deducted on the owner''s next statement, owner agreement 11.1; the default for an owner''s car), CarmaCars (a company expense; the default for a company car), a claim (a repair cost on the claim), the renter (a charge at cost on the rental), or no charge.
4. Leave **The bill is in: bill it now** ticked to make the bill now, or untick it and press **Bill now** on the record when the bill comes in. Add the receipt.
5. Press **Record the service**. Each item done is OK again, with its next date and km.

- An inspection or the registration: type the new expiry date, or leave it empty for 12 months from the service.
- Tires: type the tread depth measured, or tick New tires put on (the old set is retired as replaced).
- Seasonal swap: choose the set that went on and where the removed set is stored.
- An expense entered under Money, Expenses with a car and a service category (Car service: oil change, brakes, and so on) records the service too. Voiding either voids the other.
- **Void** on a record sets the timers back. A company expense is voided and an open owner cost is waived; a cost already on a statement or a claim stays, and the void is refused with what to do.

## Tires and the seasonal swap

On the car''s **Maintenance** tab, under Tires.

1. **Add a tire set**: kind (summer, all-season, winter or all-weather), size, brand, tread depth, made (DOT) and bought dates, where it is stored, and whether it is on the car.
2. **Put on the car** swaps sets and keeps the swap in the history.
3. Tires are due soon at 4 mm of tread or 5.5 years old, overdue at 3 mm or 6 years.
4. The swap follows Ontario: winter tires on by December 1 (reminder from November 1), off after April 1 (reminder from April 1, overdue after May 1). All-weather tires need no swap.

> Tip: The Winter tires add-on is offered only on cars with a winter set (on the car or stored), or with no tire record yet. A car on winter tires says so on the add-on.

## The odometer

- The current odometer is the highest reading from handover and return reports, field staff moves, the rental''s odometer out and in, listing photos, the car record, services and readings added by hand.
- Km a day comes from the readings of the last 90 days (else the rentals, else 60 km a day). It gives the date a km interval will be reached.
- **Add a reading** on the car; a reading lower than the last one needs the tick. An Admin can void a wrong reading.

## Intervals, reminders and blocks

Open **Settings** > **Maintenance**.

- Each item''s default interval: **Change**. Whichever of km and months comes first is due; 0 or empty means not by that measure.
- **Add an interval** for a class or one car. A car''s own comes first, then its class''s, then the default. On the car''s tab, **Set an interval for this car** does the same.
- Which expense categories are a service, and the items each records.
- Reminders: one Fleet task per car with what is due, To do lines (cars due, services to bill, cars with no record yet) and one line in the morning digest. No other email.
- Handover is refused while a recorded safety inspection or registration has expired. Block new bookings when overdue is off for every item until you turn it on.

Cars that were in the fleet before maintenance came in start as unknown, with one task each to record the last service. Enter what you know once.
',
  '<p class="gd-p">Every real car has its service items: oil, tire rotation, brakes, tires, the seasonal swap, the safety inspection, the registration, battery, wipers, filters, alignment, fluids and the annual inspection. Record a service once and the bill is made and the timers reset by themselves.</p><section class="gd-task" id="maintenance-and-service-the-fleet-overview" data-gd-task><h2 class="gd-h2">The fleet overview</h2><p class="gd-p">Open <b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Maintenance</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every real car (sample cars are left out), most urgent first: overdue, then due soon, then cars with no record yet, then all OK.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each car shows what is due next, its odometer, its km a day, the tires on it and the date of its last service.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Use Show, Service item, Sort and the search (car, plate or owner) to narrow the list, then press Apply.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Record a service</b> on a car to record it without leaving the list.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Status</th><th scope="col">Means</th></tr></thead><tbody><tr><td>Overdue</td><td>Past its km or its date (whichever came first), or expired</td></tr><tr><td>Due soon</td><td>Within 1,000 km or 14 days of it (each item may have its own; inspections and registration: 30 days)</td></tr><tr><td>Unknown</td><td>No record yet: record the last time it was done</td></tr><tr><td>OK</td><td>Done, and not due soon</td></tr></tbody></table></div></section><section class="gd-task" id="maintenance-and-service-record-a-service-in-one-step" data-gd-task><h2 class="gd-h2">Record a service in one step</h2><p class="gd-p">From the overview, the car&#39;s <b class="gd-ui">Maintenance</b> tab, or a To do line.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Tick what was done. The items due are ticked already.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the date and the odometer (filled with the current reading). Type the shop, the cost before HST and the HST (worked out at 13%, change it to match the receipt).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Who pays: the owner (deducted on the owner&#39;s next statement, owner agreement 11.1; the default for an owner&#39;s car), CarmaCars (a company expense; the default for a company car), a claim (a repair cost on the claim), the renter (a charge at cost on the rental), or no charge.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Leave <b class="gd-ui">The bill is in: bill it now</b> ticked to make the bill now, or untick it and press <b class="gd-ui">Bill now</b> on the record when the bill comes in. Add the receipt.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Record the service</b>. Each item done is OK again, with its next date and km.</div></li></ol></div><ul class="gd-ul"><li>An inspection or the registration: type the new expiry date, or leave it empty for 12 months from the service.</li><li>Tires: type the tread depth measured, or tick New tires put on (the old set is retired as replaced).</li><li>Seasonal swap: choose the set that went on and where the removed set is stored.</li><li>An expense entered under Money, Expenses with a car and a service category (Car service: oil change, brakes, and so on) records the service too. Voiding either voids the other.</li><li><b class="gd-ui">Void</b> on a record sets the timers back. A company expense is voided and an open owner cost is waived; a cost already on a statement or a claim stays, and the void is refused with what to do.</li></ul></section><section class="gd-task" id="maintenance-and-service-tires-and-the-seasonal-swap" data-gd-task><h2 class="gd-h2">Tires and the seasonal swap</h2><p class="gd-p">On the car&#39;s <b class="gd-ui">Maintenance</b> tab, under Tires.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Add a tire set</b>: kind (summer, all-season, winter or all-weather), size, brand, tread depth, made (DOT) and bought dates, where it is stored, and whether it is on the car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Put on the car</b> swaps sets and keeps the swap in the history.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Tires are due soon at 4 mm of tread or 5.5 years old, overdue at 3 mm or 6 years.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The swap follows Ontario: winter tires on by December 1 (reminder from November 1), off after April 1 (reminder from April 1, overdue after May 1). All-weather tires need no swap.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The Winter tires add-on is offered only on cars with a winter set (on the car or stored), or with no tire record yet. A car on winter tires says so on the add-on.</div></aside></section><section class="gd-task" id="maintenance-and-service-the-odometer" data-gd-task><h2 class="gd-h2">The odometer</h2><ul class="gd-ul"><li>The current odometer is the highest reading from handover and return reports, field staff moves, the rental&#39;s odometer out and in, listing photos, the car record, services and readings added by hand.</li><li>Km a day comes from the readings of the last 90 days (else the rentals, else 60 km a day). It gives the date a km interval will be reached.</li><li><b class="gd-ui">Add a reading</b> on the car; a reading lower than the last one needs the tick. An Admin can void a wrong reading.</li></ul></section><section class="gd-task" id="maintenance-and-service-intervals-reminders-and-blocks" data-gd-task><h2 class="gd-h2">Intervals, reminders and blocks</h2><p class="gd-p">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Maintenance</b>.</p><ul class="gd-ul"><li>Each item&#39;s default interval: <b class="gd-ui">Change</b>. Whichever of km and months comes first is due; 0 or empty means not by that measure.</li><li><b class="gd-ui">Add an interval</b> for a class or one car. A car&#39;s own comes first, then its class&#39;s, then the default. On the car&#39;s tab, <b class="gd-ui">Set an interval for this car</b> does the same.</li><li>Which expense categories are a service, and the items each records.</li><li>Reminders: one Fleet task per car with what is due, To do lines (cars due, services to bill, cars with no record yet) and one line in the morning digest. No other email.</li><li>Handover is refused while a recorded safety inspection or registration has expired. Block new bookings when overdue is off for every item until you turn it on.</li></ul><p class="gd-p">Cars that were in the fleet before maintenance came in start as unknown, with one task each to record the last service. Enter what you know once.</p></section>');
select app.guide_release_0095('va', 'start-here', 'start', null, '### Who this guide is for

CarmaCars assistants (VAs) in Customer service, Finance, Fleet and Sales. Read chapter 1, then the chapter for your function. If you cover more than one, read each of them.

### What you need

- The invitation email from CarmaCars (the link works for 24 hours)
- A computer for your shift. The portal also works on a phone
- An authenticator app on your phone, if your Admin turns on two-step sign-in

## Your first sign-in

1. Open the invitation email and press its link within 24 hours. Choose a password of 8 characters or more and press **Save the new password**.
2. You land in your portal, on **To do**, working as your main function.
3. At the top of the page, fill in your Home address and Postal code and press **Save my home address**. You need it before you add a rental or earn a commission. Change it later under **Profile**, at the top of the menu.
4. Next time, sign in at `carmacars.ca/sign-in` with your Email and Password, then **Sign in**.
5. Link expired? Press **Send me a new link** on the page it opens, or ask an Admin for a password link.

![](/guides/img/public-09-sign-in-phone-1f766061.jpg "phone; size: 390 645; pins: 3 95.4 78.4")

> Good to know: Recommended: open your profile and press **Set up two-step sign-in**. Scan the code with your authenticator app, type the 6 digits and press **Continue**. After that every sign-in asks for a code.
', 'Start here', 'Who this is for and your first sign-in.',
  '### Who this guide is for

CarmaCars assistants (VAs) in Customer service, Finance, Fleet and Sales. Read chapter 1, then the chapter for your function. If you cover more than one, read each of them.

### What you need

- The invitation email from CarmaCars (the link works for 24 hours)
- A computer for your shift. The portal also works on a phone
- An authenticator app on your phone, if your Admin turns on two-step sign-in

## Your first sign-in

1. Open the invitation email and press its link within 24 hours. Choose a password of 8 characters or more and press **Save the new password**.
2. You land in your portal, on **To do**, working as your main function.
3. At the top of the page, fill in your Home address and Postal code and press **Save my home address**. You need it before you add a rental or earn a commission. Change it later under **Profile**, at the top of the menu.
4. Next time, sign in at `carmacars.ca/sign-in` with your Email and Password, then **Sign in**.
5. Link expired? Press **Send me a new link** on the page it opens, or ask an Admin for a password link.
6. Sign in with your phone: on **Profile**, press **Add and verify my phone number** and enter the 6-digit code we text you. Then press **Use my phone number instead** on the sign-in page. Two-step sign-in still asks for your authenticator code.

![](/guides/img/public-09-sign-in-phone-1f766061.jpg "phone; size: 390 645; pins: 3 95.4 78.4")

> Good to know: Recommended: open your profile and press **Set up two-step sign-in**. Scan the code with your authenticator app, type the 6 digits and press **Continue**. After that every sign-in asks for a code.
',
  '<h3 class="gd-h3">Who this guide is for</h3><p class="gd-p">CarmaCars assistants (VAs) in Customer service, Finance, Fleet and Sales. Read chapter 1, then the chapter for your function. If you cover more than one, read each of them.</p><h3 class="gd-h3">What you need</h3><ul class="gd-ul"><li>The invitation email from CarmaCars (the link works for 24 hours)</li><li>A computer for your shift. The portal also works on a phone</li><li>An authenticator app on your phone, if your Admin turns on two-step sign-in</li></ul><section class="gd-task" id="start-here-your-first-sign-in" data-gd-task><h2 class="gd-h2">Your first sign-in</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the invitation email and press its link within 24 hours. Choose a password of 8 characters or more and press <b class="gd-ui">Save the new password</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">You land in your portal, on <b class="gd-ui">To do</b>, working as your main function.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">At the top of the page, fill in your Home address and Postal code and press <b class="gd-ui">Save my home address</b>. You need it before you add a rental or earn a commission. Change it later under <b class="gd-ui">Profile</b>, at the top of the menu.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Next time, sign in at <span class="gd-url">carmacars.ca/sign-in</span> with your Email and Password, then <b class="gd-ui">Sign in</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Link expired? Press <b class="gd-ui">Send me a new link</b> on the page it opens, or ask an Admin for a password link.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Sign in with your phone: on <b class="gd-ui">Profile</b>, press <b class="gd-ui">Add and verify my phone number</b> and enter the 6-digit code we text you. Then press <b class="gd-ui">Use my phone number instead</b> on the sign-in page. Two-step sign-in still asks for your authenticator code.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/645"><img src="/guides/img/public-09-sign-in-phone-1f766061.jpg" alt="" loading="lazy" decoding="async" width="390" height="645"><span class="gd-pin" style="left:95.4%;top:78.4%" aria-hidden="true">3</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Recommended: open your profile and press <b class="gd-ui">Set up two-step sign-in</b>. Scan the code with your authenticator app, type the 6 digits and press <b class="gd-ui">Continue</b>. After that every sign-in asks for a code.</div></aside></section>');
select app.guide_release_0095('va', 'chauffeur-requests', 'chapter', 'customer-service', null, 'Chauffeur requests', 'Quote and confirm a chauffeur request; partner cars with insurance included or no credit card needed.',
  'Customer service and Sales handle the chauffeur requests sent from carmacars.ca/chauffeur, and answer questions about the partner cars on the site.

## Quote a chauffeur request

A new request is a task in your queue: Chauffeur request CH-1001, with the vehicle, the date, the hours and the client''s contact.

1. Open **Chauffeur** from the task (or the menu). Find the request by its number.
2. Check the vehicle and the driver with the partner for that date and time.
3. To change the vehicle or the hours, press **Change**. The quote is worked out again: 2 hours at the 2-hour rate, 3 hours or more at the 3+ hour rate for every hour, then HST.
4. Send the quote line to the client by email or phone. Press **Quoted** and write how you sent it.
5. When the client agrees and the payment is arranged, press **Confirm**. After the trip, press **Completed**.

> Tip: The minimum is 2 hours. The rates on the site are guideline rates: the price is confirmed in the quote.

## Partner cars: insurance included, no credit card

Some partner cars say **Insurance included: no personal auto policy needed** and **No credit card needed: debit accepted** on their page.

1. On these cars the renter does not choose a coverage option: the booking shows "insurance included with the car", already confirmed. There is no proof to review.
2. The renter may pay with a debit card in their own name. A prepaid card is still refused.
3. The deposit, the licence and selfie checks and the ages are the same as on every car.
4. Partner cars without a confirmed model year say "Year confirmed when you book". An offer cannot be sent until an Admin confirms the year: ask an Admin.
',
  '<p class="gd-p">Customer service and Sales handle the chauffeur requests sent from carmacars.ca/chauffeur, and answer questions about the partner cars on the site.</p><section class="gd-task" id="chauffeur-requests-quote-a-chauffeur-request" data-gd-task><h2 class="gd-h2">Quote a chauffeur request</h2><p class="gd-p">A new request is a task in your queue: Chauffeur request CH-1001, with the vehicle, the date, the hours and the client&#39;s contact.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Chauffeur</b> from the task (or the menu). Find the request by its number.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the vehicle and the driver with the partner for that date and time.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">To change the vehicle or the hours, press <b class="gd-ui">Change</b>. The quote is worked out again: 2 hours at the 2-hour rate, 3 hours or more at the 3+ hour rate for every hour, then HST.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Send the quote line to the client by email or phone. Press <b class="gd-ui">Quoted</b> and write how you sent it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">When the client agrees and the payment is arranged, press <b class="gd-ui">Confirm</b>. After the trip, press <b class="gd-ui">Completed</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The minimum is 2 hours. The rates on the site are guideline rates: the price is confirmed in the quote.</div></aside></section><section class="gd-task" id="chauffeur-requests-partner-cars-insurance-included-no-credit-card" data-gd-task><h2 class="gd-h2">Partner cars: insurance included, no credit card</h2><p class="gd-p">Some partner cars say <b class="gd-ui">Insurance included: no personal auto policy needed</b> and <b class="gd-ui">No credit card needed: debit accepted</b> on their page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On these cars the renter does not choose a coverage option: the booking shows &quot;insurance included with the car&quot;, already confirmed. There is no proof to review.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The renter may pay with a debit card in their own name. A prepaid card is still refused.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The deposit, the licence and selfie checks and the ages are the same as on every car.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Partner cars without a confirmed model year say &quot;Year confirmed when you book&quot;. An offer cannot be sent until an Admin confirms the year: ask an Admin.</div></li></ol></div></section>');
select app.guide_release_0095('va', 'discount-game-leads', 'chapter', 'texts-and-calls', 'Visitors who are not signed in play a quick game on the site and win a promo code. To get it they give a first name, an email and sometimes a mobile number. Customer service and Sales follow them up.

## Game leads

**My work** > **Game leads**.

1. Each claim: when, the name (and "on the site now"), email and phone, the prize, the code and whether it is used, marketing consent, and the cars and pages they viewed.
2. Press **Call** or **Email**. Help them pick a car and send a request; the code goes in the promo code box (on their own device it is filled in). Then press **Contacted**.
3. **Close** with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.

A visitor who viewed 3 cars or more also raises a Sales task, for example "Claimed 10% off, viewed 6 cars: Maya". It closes when the code goes on a request.

> Tip: Without marketing consent, talk only about their request and the code they asked for: no other offers. The code takes up to $75 off the rental charge (a percentage), or $50 off a rental of 3 days or more, on one booking within 7 days.
', 'Discount game leads', 'Game leads to call or email, the code they won, whether it is used, and the Sales task.',
  'Visitors who are not signed in play a quick game on the site and win a promo code. To get it they give a first name, an email and sometimes a mobile number. Customer service and Sales follow them up.

## Game leads

**My work** > **Game leads**.

1. Each claim: when, the name (and "on the site now"), email and phone, the prize, the code and whether it is used, marketing consent, and the cars and pages they viewed.
2. Press **Call** or **Email**. Help them pick a car and send a request; the code goes in the promo code box (on their own device it is filled in). Then press **Contacted**.
3. **Close** with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.

A visitor who viewed 3 cars or more also raises a Sales task, for example "Claimed 10% off, viewed 6 cars: Maya". It closes when the code goes on a request.

> Tip: Without marketing consent, talk only about their request and the code they asked for: no other offers. The code takes up to $75 off the rental charge (a percentage), or $50 off a rental of 3 days or more, on one booking within 7 days.

## Contact details typed into forms

The card "Typed into forms" above the game leads lists the name, email and phone people typed into a form on the site without sending it, with "On the site now" and "Email not confirmed". Call or email to help them finish. Only what they typed; no offers without their consent.
',
  '<p class="gd-p">Visitors who are not signed in play a quick game on the site and win a promo code. To get it they give a first name, an email and sometimes a mobile number. Customer service and Sales follow them up.</p><section class="gd-task" id="discount-game-leads-game-leads" data-gd-task><h2 class="gd-h2">Game leads</h2><p class="gd-p"><b class="gd-ui">My work</b> &gt; <b class="gd-ui">Game leads</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each claim: when, the name (and &quot;on the site now&quot;), email and phone, the prize, the code and whether it is used, marketing consent, and the cars and pages they viewed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Call</b> or <b class="gd-ui">Email</b>. Help them pick a car and send a request; the code goes in the promo code box (on their own device it is filled in). Then press <b class="gd-ui">Contacted</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Close</b> with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.</div></li></ol></div><p class="gd-p">A visitor who viewed 3 cars or more also raises a Sales task, for example &quot;Claimed 10% off, viewed 6 cars: Maya&quot;. It closes when the code goes on a request.</p><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Without marketing consent, talk only about their request and the code they asked for: no other offers. The code takes up to $75 off the rental charge (a percentage), or $50 off a rental of 3 days or more, on one booking within 7 days.</div></aside></section><section class="gd-task" id="discount-game-leads-contact-details-typed-into-forms" data-gd-task><h2 class="gd-h2">Contact details typed into forms</h2><p class="gd-p">The card &quot;Typed into forms&quot; above the game leads lists the name, email and phone people typed into a form on the site without sending it, with &quot;On the site now&quot; and &quot;Email not confirmed&quot;. Call or email to help them finish. Only what they typed; no offers without their consent.</p></section>');
select app.guide_release_0095('va', 'car-maintenance', 'chapter', 'assistant', null, 'Car maintenance', 'The maintenance list, recording a service in one step, tires and swaps, readings, and billing.',
  'Fleet keeps every car serviced: oil, tires, brakes, inspections and the registration. Finance bills what Fleet records. Recording a service resets its reminders and makes its bill.

## What is due

Open **Field work** > **Maintenance** (Finance: **Money** > **Maintenance bills**).

1. Every car, most urgent first: overdue (red), due soon, no record yet (dashed), all OK.
2. Your To do has one Service due task per car listing what is due. Open it: the car opens with the record pop-up.
3. A car with no record yet has one task to record its last service. Enter what you know once.

## Record a service

1. Press **Record a service** on the car (or **Record** on one item of the car''s Maintenance).
2. Tick what was done, check the date and the odometer, type the shop, the cost before HST and the HST, and add the receipt.
3. Who pays: the owner for an owner''s car (deducted on their statement), CarmaCars for a company car, a claim, the renter, or no charge.
4. Leave **The bill is in: bill it now** ticked, or untick it and press **Bill now** on the record later.
5. Press **Record the service**. The items done are OK again.

> Watch out: Above your single limit the service is recorded and the timers reset, but an Admin bills it: you see "An Admin bills it".

## Tires, swaps and readings

- Under Tires: **Add a tire set** (kind, size, brand, tread, made and bought dates, where it is stored), **Put on the car** to swap.
- Ontario: winter tires on by December 1 (reminder from November 1), off after April 1. Tires are due soon at 4 mm of tread, overdue at 3 mm.
- **Add a reading** when you see the odometer. Handover, return and move readings come in by themselves.
- A car whose recorded safety inspection or registration has expired cannot be handed over until the renewal is recorded.
',
  '<p class="gd-p">Fleet keeps every car serviced: oil, tires, brakes, inspections and the registration. Finance bills what Fleet records. Recording a service resets its reminders and makes its bill.</p><section class="gd-task" id="car-maintenance-what-is-due" data-gd-task><h2 class="gd-h2">What is due</h2><p class="gd-p">Open <b class="gd-ui">Field work</b> &gt; <b class="gd-ui">Maintenance</b> (Finance: <b class="gd-ui">Money</b> &gt; <b class="gd-ui">Maintenance bills</b>).</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every car, most urgent first: overdue (red), due soon, no record yet (dashed), all OK.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Your To do has one Service due task per car listing what is due. Open it: the car opens with the record pop-up.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A car with no record yet has one task to record its last service. Enter what you know once.</div></li></ol></div></section><section class="gd-task" id="car-maintenance-record-a-service" data-gd-task><h2 class="gd-h2">Record a service</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Record a service</b> on the car (or <b class="gd-ui">Record</b> on one item of the car&#39;s Maintenance).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Tick what was done, check the date and the odometer, type the shop, the cost before HST and the HST, and add the receipt.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Who pays: the owner for an owner&#39;s car (deducted on their statement), CarmaCars for a company car, a claim, the renter, or no charge.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Leave <b class="gd-ui">The bill is in: bill it now</b> ticked, or untick it and press <b class="gd-ui">Bill now</b> on the record later.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Record the service</b>. The items done are OK again.</div></li></ol></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Above your single limit the service is recorded and the timers reset, but an Admin bills it: you see &quot;An Admin bills it&quot;.</div></aside></section><section class="gd-task" id="car-maintenance-tires-swaps-and-readings" data-gd-task><h2 class="gd-h2">Tires, swaps and readings</h2><ul class="gd-ul"><li>Under Tires: <b class="gd-ui">Add a tire set</b> (kind, size, brand, tread, made and bought dates, where it is stored), <b class="gd-ui">Put on the car</b> to swap.</li><li>Ontario: winter tires on by December 1 (reminder from November 1), off after April 1. Tires are due soon at 4 mm of tread, overdue at 3 mm.</li><li><b class="gd-ui">Add a reading</b> when you see the odometer. Handover, return and move readings come in by themselves.</li><li>A car whose recorded safety inspection or registration has expired cannot be handed over until the renewal is recorded.</li></ul></section>');
select app.guide_release_0095('field', 'report-rentals-referrals-and-profile', 'chapter', 'photo-shoots', 'Report anything that happens on the road, add a rental for a renter you found, share your referral link, and keep your details up to date.

## Report something

1. Open **Report** and choose the Car.
2. Choose What happened: **New damage found**, **Warning light**, **Collision while I was driving**, **Ticket or toll while I was driving**, **Lost property found** or **Something else**.
3. Write the Details: where, when and what you see.
4. Press **Take a photo** for each photo, then **Send the report**.

![](/guides/img/field-03-report-phone-2adac4d1.jpg "phone; size: 390 965; pins: 1 92.3 29.5, 2 92.3 37.3, 3 92.3 83.4, 4 92.3 97.9")

> Watch out: In a collision, make sure everyone is safe and call 911 if anyone is hurt. Then call CarmaCars at 289-312-5991 before you send the report.

## Add a rental for a renter you found

Your home address must be in your profile first: until it is, the page asks for it.

1. Open **Add a rental**. Choose the car, the dates and the places, then type the renter''s details. A renter already on file is found by their email. Car already out with the renter? Enter the pickup as when it left: it is recorded as on trip.
2. Press **Check the calendar and the price**. To charge another price, type it with the reason: a price far under the rate sheet is flagged for an Admin, not refused.
3. Choose **Send a payment link** or **Charge the saved card when the renter signs**. You never take payment yourself.
4. Under Who found this client, choose **I sourced this client** or **Entered for CarmaCars**, then press **Add the rental**.

## Commissions

1. You earn 10% of the rental charge (before tax, after discounts, less refunds) of each rental you sourced: one you added and marked I sourced this client, or a booking made with your referral link.
2. It is earned when the rental is completed and paid in full, then an Admin approves it and it is paid on your pay date. Your home address must be in your profile: until it is, a commission waits as not earned yet.
3. **My sales** shows each commission: not earned yet, pending approval, approved, paid or reversed. A refund after payment comes off a later commission.

## Referrals and profile

1. **Referrals**: your own referral link. Press **Copy the link**, or let someone scan its QR code. A booking made with it counts as a rental you sourced.
2. **Profile**: **Save my phone**, your home address (**Change my home address**), **Set up two-step sign-in**, **Change my password** and **Sign out**.

![](/guides/img/field-04-profile-phone-56e58ae3.jpg "phone; size: 390 905; pins: 2 93.6 63.9")
', 'Report, rentals, referrals and profile', 'Report an incident, add a rental, commissions, your referral link and your profile.',
  'Report anything that happens on the road, add a rental for a renter you found, share your referral link, and keep your details up to date.

## Report something

1. Open **Report** and choose the Car.
2. Choose What happened: **New damage found**, **Warning light**, **Collision while I was driving**, **Ticket or toll while I was driving**, **Lost property found** or **Something else**.
3. Write the Details: where, when and what you see.
4. Press **Take a photo** for each photo, then **Send the report**.

![](/guides/img/field-03-report-phone-2adac4d1.jpg "phone; size: 390 965; pins: 1 92.3 29.5, 2 92.3 37.3, 3 92.3 83.4, 4 92.3 97.9")

> Watch out: In a collision, make sure everyone is safe and call 911 if anyone is hurt. Then call CarmaCars at 289-312-5991 before you send the report.

## Add a rental for a renter you found

Your home address must be in your profile first: until it is, the page asks for it.

1. Open **Add a rental**. Choose the car, the dates and the places, then type the renter''s details. A renter already on file is found by their email. Car already out with the renter? Enter the pickup as when it left: it is recorded as on trip.
2. Press **Check the calendar and the price**. To charge another price, type it with the reason: a price far under the rate sheet is flagged for an Admin, not refused.
3. Choose **Send a payment link** or **Charge the saved card when the renter signs**. You never take payment yourself.
4. Under Who found this client, choose **I sourced this client** or **Entered for CarmaCars**, then press **Add the rental**.

## Commissions

1. You earn 10% of the rental charge (before tax, after discounts, less refunds) of each rental you sourced: one you added and marked I sourced this client, or a booking made with your referral link.
2. It is earned when the rental is completed and paid in full, then an Admin approves it and it is paid on your pay date. Your home address must be in your profile: until it is, a commission waits as not earned yet.
3. **My sales** shows each commission: not earned yet, pending approval, approved, paid or reversed. A refund after payment comes off a later commission.

## Referrals and profile

1. **Referrals**: your own referral link. Press **Copy the link**, or let someone scan its QR code. A booking made with it counts as a rental you sourced.
2. **Profile**: **Save my phone**, your home address (**Change my home address**), **Set up two-step sign-in**, **Change my password** and **Sign out**.

![](/guides/img/field-04-profile-phone-56e58ae3.jpg "phone; size: 390 905; pins: 2 93.6 63.9")

## Sign in with your phone number

Quicker on a phone than a password: a 6-digit code by text.

1. On **Profile**, under Sign-in, press **Add and verify my phone number**, enter your mobile number and press **Text me a code**.
2. Type the code from the text (it usually fills itself in) and press **Verify**. Choose **My phone number (a code by text)** under Sign in with.
3. Next time, the sign-in page opens on your phone number: press **Text me a code** and enter the code. Two-step sign-in still asks for your authenticator code.
',
  '<p class="gd-p">Report anything that happens on the road, add a rental for a renter you found, share your referral link, and keep your details up to date.</p><section class="gd-task" id="report-rentals-referrals-and-profile-report-something" data-gd-task><h2 class="gd-h2">Report something</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Report</b> and choose the Car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose What happened: <b class="gd-ui">New damage found</b>, <b class="gd-ui">Warning light</b>, <b class="gd-ui">Collision while I was driving</b>, <b class="gd-ui">Ticket or toll while I was driving</b>, <b class="gd-ui">Lost property found</b> or <b class="gd-ui">Something else</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Write the Details: where, when and what you see.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Take a photo</b> for each photo, then <b class="gd-ui">Send the report</b>.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/965"><img src="/guides/img/field-03-report-phone-2adac4d1.jpg" alt="" loading="lazy" decoding="async" width="390" height="965"><span class="gd-pin" style="left:92.3%;top:29.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:92.3%;top:37.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:92.3%;top:83.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:92.3%;top:97.9%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>In a collision, make sure everyone is safe and call 911 if anyone is hurt. Then call CarmaCars at 289-312-5991 before you send the report.</div></aside></section><section class="gd-task" id="report-rentals-referrals-and-profile-add-a-rental-for-a-renter-you-found" data-gd-task><h2 class="gd-h2">Add a rental for a renter you found</h2><p class="gd-p">Your home address must be in your profile first: until it is, the page asks for it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Add a rental</b>. Choose the car, the dates and the places, then type the renter&#39;s details. A renter already on file is found by their email. Car already out with the renter? Enter the pickup as when it left: it is recorded as on trip.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Check the calendar and the price</b>. To charge another price, type it with the reason: a price far under the rate sheet is flagged for an Admin, not refused.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Choose <b class="gd-ui">Send a payment link</b> or <b class="gd-ui">Charge the saved card when the renter signs</b>. You never take payment yourself.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Under Who found this client, choose <b class="gd-ui">I sourced this client</b> or <b class="gd-ui">Entered for CarmaCars</b>, then press <b class="gd-ui">Add the rental</b>.</div></li></ol></div></section><section class="gd-task" id="report-rentals-referrals-and-profile-commissions" data-gd-task><h2 class="gd-h2">Commissions</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">You earn 10% of the rental charge (before tax, after discounts, less refunds) of each rental you sourced: one you added and marked I sourced this client, or a booking made with your referral link.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">It is earned when the rental is completed and paid in full, then an Admin approves it and it is paid on your pay date. Your home address must be in your profile: until it is, a commission waits as not earned yet.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">My sales</b> shows each commission: not earned yet, pending approval, approved, paid or reversed. A refund after payment comes off a later commission.</div></li></ol></div></section><section class="gd-task" id="report-rentals-referrals-and-profile-referrals-and-profile" data-gd-task><h2 class="gd-h2">Referrals and profile</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Referrals</b>: your own referral link. Press <b class="gd-ui">Copy the link</b>, or let someone scan its QR code. A booking made with it counts as a rental you sourced.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Profile</b>: <b class="gd-ui">Save my phone</b>, your home address (<b class="gd-ui">Change my home address</b>), <b class="gd-ui">Set up two-step sign-in</b>, <b class="gd-ui">Change my password</b> and <b class="gd-ui">Sign out</b>.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/905"><img src="/guides/img/field-04-profile-phone-56e58ae3.jpg" alt="" loading="lazy" decoding="async" width="390" height="905"><span class="gd-pin" style="left:93.6%;top:63.9%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="report-rentals-referrals-and-profile-sign-in-with-your-phone-number" data-gd-task><h2 class="gd-h2">Sign in with your phone number</h2><p class="gd-p">Quicker on a phone than a password: a 6-digit code by text.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On <b class="gd-ui">Profile</b>, under Sign-in, press <b class="gd-ui">Add and verify my phone number</b>, enter your mobile number and press <b class="gd-ui">Text me a code</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Type the code from the text (it usually fills itself in) and press <b class="gd-ui">Verify</b>. Choose <b class="gd-ui">My phone number (a code by text)</b> under Sign in with.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Next time, the sign-in page opens on your phone number: press <b class="gd-ui">Text me a code</b> and enter the code. Two-step sign-in still asks for your authenticator code.</div></li></ol></div></section>');
-- GUIDES 0095 END
