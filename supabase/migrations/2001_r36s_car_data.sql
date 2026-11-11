-- 2001_r36s_car_data.sql
-- Release 36, SEO (docs/changes/2026-11-11-r36-seo-growth.md), part 3: more car data on every car page, each value
-- from a free source with its attribution, loaded by the seo-data workflow (web/scripts/seo-data.mjs; nothing is
-- hard-coded in a template, nothing is estimated). vehicle_specs (1100) gains:
--   fields   msrp_usd, msrp_cad (OEM price lists or a curated CSV), production_start, production_end, assembly_plant,
--            markets, production_total, na_sales (Wikidata, curated CSV), common_problem (NHTSA complaints by component,
--            the curated CSV), recall_item (NHTSA and Transport Canada campaigns, code = the campaign number),
--            tc_recalls (Transport Canada's count), sunroof, headlights, carplay, android_auto, passengers, suitcases,
--            battery_kwh, charge_dc_kw, charge_ac_kw, charge_connector, body_style, doors, ground_clearance_mm,
--            turning_circle_m, warranty
--   sources  transport_canada, wikidata
--   lists    several rows per model year and field for paint_colour, features, common_problem, recall_item,
--            assembly_plant, markets (the unique key is by value for those)
-- The derived figures (feature ratings out of 10, the parkability score) are computed on the page from these values
-- with the method shown (web/src/features/seo/car-kit.ts), never stored.
-- The targets: the fleet's models first, then the catalog's popular models of the last 12 model years
-- (vehicle_catalog_popular), so the importer covers the car pages people search for, not only our own cars.
-- Part 4 (parking) is here too: place_pois gains parking lots and street parking from OpenStreetMap, with their detail.
-- No applied migration is edited.

create or replace function app.spec_is_list(p_field text) returns boolean
language sql immutable parallel safe as $$
  select p_field in ('paint_colour', 'features', 'common_problem', 'recall_item', 'assembly_plant', 'markets')
$$;

alter table vehicle_specs drop constraint if exists vehicle_specs_field_check;
alter table vehicle_specs add constraint vehicle_specs_field_check check (field in (
  'tire_size', 'rim_size', 'fuel_city_l100', 'fuel_highway_l100', 'fuel_combined_l100', 'fuel_type', 'tank_l', 'kwh100_combined', 'range_km', 'features', 'paint_colour',
  'hp', 'torque_nm', 'zero_100_s', 'top_speed_kmh', 'drivetrain', 'transmission', 'curb_kg', 'towing_kg', 'seats', 'cargo_l', 'length_mm', 'width_mm', 'height_mm',
  'wheelbase_mm', 'safety_overall', 'safety_frontal', 'safety_side', 'safety_rollover', 'recalls', 'engine',
  -- 2001
  'msrp_usd', 'msrp_cad', 'production_start', 'production_end', 'assembly_plant', 'markets', 'production_total', 'na_sales', 'common_problem', 'recall_item',
  'tc_recalls', 'sunroof', 'headlights', 'carplay', 'android_auto', 'passengers', 'suitcases', 'battery_kwh', 'charge_dc_kw', 'charge_ac_kw', 'charge_connector',
  'body_style', 'doors', 'ground_clearance_mm', 'turning_circle_m', 'warranty'));
alter table vehicle_specs drop constraint if exists vehicle_specs_source_check;
alter table vehicle_specs add constraint vehicle_specs_source_check check (source in ('nhtsa_vpic', 'nhtsa_recalls', 'nhtsa_ratings', 'nhtsa_complaints', 'fueleconomy_gov', 'oem',
  'open_dataset', 'transport_canada', 'wikidata'));

drop index if exists vehicle_specs_key;
create unique index vehicle_specs_key on vehicle_specs (lower(make), lower(model), year, lower(trim), field, coalesce(code, ''), (case when app.spec_is_list(field) then value else '' end));
comment on column vehicle_specs.field is 'The figure (1100; 2001 added prices, production, plants, markets, problems, recall campaigns, equipment, charging, body). List fields (app.spec_is_list) keep one row per value.';

-- the loader (1100) with the list fields of 2001 in its conflict key, and a prune by source for specs
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
      values (btrim(r ->> 'make'), btrim(r ->> 'model'), (r ->> 'year')::integer, coalesce(btrim(r ->> 'trim'), ''), r ->> 'field', left(btrim(r ->> 'value'), 400),
              nullif(btrim(r ->> 'code'), ''), r ->> 'source', r ->> 'source_url', (r ->> 'fetched_at')::timestamptz)
      on conflict (lower(make), lower(model), year, lower(trim), field, coalesce(code, ''), (case when app.spec_is_list(field) then value else '' end))
      do update set value = excluded.value, source = excluded.source, source_url = excluded.source_url, fetched_at = excluded.fetched_at;
    elsif v_kind = 'maintenance' then
      insert into vehicle_maintenance_costs (make, segment, per_year_cents, per_10k_km_cents, assumptions, source, source_url, fetched_at)
      values (coalesce(btrim(r ->> 'make'), ''), btrim(r ->> 'segment'), (r ->> 'per_year_cents')::integer, (r ->> 'per_10k_km_cents')::integer, r ->> 'assumptions',
              r ->> 'source', r ->> 'source_url', (r ->> 'fetched_at')::timestamptz)
      on conflict (make, segment) do update set per_year_cents = excluded.per_year_cents, per_10k_km_cents = excluded.per_10k_km_cents, assumptions = excluded.assumptions,
        source = excluded.source, source_url = excluded.source_url, fetched_at = excluded.fetched_at;
    else
      insert into place_pois (kind, agency, ref, name, lat, lng, source, source_url, licence, attribution, fetched_at, detail)
      values (r ->> 'kind', nullif(btrim(r ->> 'agency'), ''), r ->> 'ref', btrim(r ->> 'name'), (r ->> 'lat')::numeric, (r ->> 'lng')::numeric, r ->> 'source',
              r ->> 'source_url', r ->> 'licence', r ->> 'attribution', (r ->> 'fetched_at')::timestamptz, coalesce(r -> 'detail', '{}'::jsonb))
      on conflict (source, coalesce(agency, ''), ref) do update set kind = excluded.kind, name = excluded.name, lat = excluded.lat, lng = excluded.lng,
        source_url = excluded.source_url, licence = excluded.licence, attribution = excluded.attribution, fetched_at = excluded.fetched_at, detail = excluded.detail;
    end if;
    v_n := v_n + 1;
  end loop;
  if p -> 'prune' ->> 'before' is not null then
    if v_kind = 'pois' then
      delete from place_pois where source = p -> 'prune' ->> 'source' and coalesce(agency, '') = coalesce(p -> 'prune' ->> 'agency', '') and fetched_at < (p -> 'prune' ->> 'before')::timestamptz
        and (p -> 'prune' ->> 'kinds' is null or kind = any (array(select jsonb_array_elements_text(p -> 'prune' -> 'kinds'))));
    elsif v_kind = 'specs' then
      delete from vehicle_specs where source = p -> 'prune' ->> 'source' and fetched_at < (p -> 'prune' ->> 'before')::timestamptz
        and (p -> 'prune' ->> 'fields' is null or field = any (array(select jsonb_array_elements_text(p -> 'prune' -> 'fields'))));
    end if;
    get diagnostics v_pruned = row_count;
  end if;
  return jsonb_build_object('kind', v_kind, 'loaded', v_n, 'pruned', v_pruned);
end $$;

-- the targets: the fleet's models, then the catalog's popular models of the last 12 model years, newest first
create or replace function app.server_seo_data_targets(p_limit integer default 400) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with fleet as (
    select distinct v.make, v.model, v.year::integer as year, 0 pri from vehicles v join vehicle_listings l on l.vehicle_id = v.id
     where l.status = 'published' and v.year is not null and v.make is not null and v.model is not null),
  popular as (
    select mk.name make, md.name model, y.year::integer as year, 1 pri
      from vehicle_catalog_popular p join vehicle_catalog_makes mk on mk.slug = p.make_slug
      join vehicle_catalog_models md on md.make_slug = p.make_slug and md.slug = p.model_slug
      join vehicle_catalog_years y on y.make_slug = p.make_slug and y.model_slug = p.model_slug
     where y.year >= extract(year from now())::integer - 11),
  one as (select distinct on (lower(make), lower(model), year) make, model, year, pri from (select * from fleet union all select * from popular) a
           order by lower(make), lower(model), year, pri)
  select coalesce(jsonb_agg(jsonb_build_object('make', x.make, 'model', x.model, 'year', x.year)), '[]'::jsonb)
    from (select * from one order by pri, year desc, make, model limit greatest(least(p_limit, 5000), 1)) x
$$;

-- ================================================================ part 4: parking for the place pages
-- OpenStreetMap parking (amenity=parking: lots and garages, with access, fee and capacity when tagged; parking:lane /
-- parking:both|left|right on streets: street parking by side), loaded with the hotels by the seo-data workflow.
alter table place_pois add column if not exists detail jsonb not null default '{}'::jsonb check (jsonb_typeof(detail) = 'object');
alter table place_pois drop constraint if exists place_pois_kind_check;
alter table place_pois add constraint place_pois_kind_check check (kind in ('go_station', 'rail_station', 'subway_station', 'bus_stop', 'hotel', 'parking_lot', 'street_parking'));
comment on column place_pois.detail is 'What the source says beyond the name (2001): for parking, {parking: surface|multi-storey|underground|street, fee: yes|no, capacity, access, maxstay, sides}. Shown as given, never inferred.';

-- the nearest of each kind (1100) with the detail
create or replace function public.place_pois_near(p_lat numeric, p_lng numeric, p_km numeric default 5, p_each integer default 5) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('kind', x.kind, 'agency', x.agency, 'name', x.name, 'km', round(x.km, 1), 'source', x.source, 'detail', x.detail,
                                               'source_url', x.source_url, 'licence', x.licence, 'attribution', x.attribution, 'fetched_at', x.fetched_at)
                            order by x.kind, x.km), '[]'::jsonb)
    from (select p.*, app.distance_km(p_lat, p_lng, p.lat, p.lng) km, row_number() over (partition by p.kind order by app.distance_km(p_lat, p_lng, p.lat, p.lng), p.name) n
            from place_pois p
           where p_lat is not null and p_lng is not null
             and p.lat between p_lat - least(greatest(p_km, 0.5), 25) / 111.0 and p_lat + least(greatest(p_km, 0.5), 25) / 111.0
             and p.lng between p_lng - least(greatest(p_km, 0.5), 25) / (111.0 * greatest(cos(radians(p_lat)), 0.2)) and p_lng + least(greatest(p_km, 0.5), 25) / (111.0 * greatest(cos(radians(p_lat)), 0.2))) x
   where x.km <= least(greatest(p_km, 0.5), 25) and x.n <= least(greatest(p_each, 1), 10)
$$;
revoke all on function public.place_pois_near(numeric, numeric, numeric, integer), app.spec_is_list(text) from public, anon, authenticated;
grant execute on function public.place_pois_near(numeric, numeric, numeric, integer), app.spec_is_list(text) to service_role;
