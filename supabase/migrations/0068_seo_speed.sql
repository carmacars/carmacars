-- 0068: search pages read fast (October 19, 2026).
--
-- Deploy runs 39310793167 and the live check 39334242566: the sitemaps and the landing pages read the public fleet
-- (app.public_fleet, one app.public_listing_row per car) once per landing page. The sitemap read took about 5 s on a
-- local database with 20 cars, past the 3 s statement timeout of the anon role on Supabase, and a landing page about
-- 0.5 s locally, more on the small production database (one answered 500). Now a snapshot of each page's matching cars
-- and prices is kept on the page row: written from one read of the fleet every 10 minutes (pg_cron) and at once by the
-- search job; a page reads it when the fleet has not changed since (a cheap stamp of the cars, listings, rates, photos
-- and classes), and otherwise reads the fleet live as before. The sitemap's date for a landing page is the last time its
-- cars changed, read from the row. The car copy scan reads the site facts once instead of several times per car.

alter table seo_pages
  add column cars_snapshot jsonb,           -- {cars: [up to 24 card rows], counts: {...}} from app.seo_snapshot_refresh
  add column snapshot_stamp text,           -- app.seo_fleet_stamp() when the snapshot was written
  add column snapshot_at timestamptz,
  add column cars_changed_at timestamptz;   -- the last time the matching cars or their prices changed (sitemap lastmod)

-- what the public fleet is built from, summed up cheaply: a change to any of it changes the stamp
create or replace function app.seo_fleet_stamp() returns text
language sql stable security definer set search_path = public, app as $$
  select md5(concat_ws('|',
    (select count(*) || '/' || coalesce(max(updated_at)::text, '') from vehicles),
    (select count(*) || '/' || coalesce(max(updated_at)::text, '') from vehicle_listings),
    (select count(*) || '/' || coalesce(max(created_at)::text, '') || '/' || coalesce(max(effective_to)::text, '') from rate_cards),
    (select count(*) || '/' || coalesce(max(greatest(created_at, approved_at, replaced_at))::text, '') from vehicle_photos),
    (select count(*) || '/' || coalesce(sum(hashtext(vehicle_id::text || class_code)), 0) from vehicle_class_links),
    (select coalesce(max(updated_at)::text, '') from vehicle_classes),
    current_date::text))
$$;

-- every active page's cars from one read of the fleet; returns the number of pages whose cars changed
create or replace function app.seo_snapshot_refresh() returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v_stamp text := app.seo_fleet_stamp();
  v_fleet jsonb;
  v_changed integer := 0;
  p record;
  v_cars jsonb;
  v_snap jsonb;
begin
  select coalesce(jsonb_agg(r), '[]'::jsonb) into v_fleet from app.public_fleet('{}'::jsonb) r;
  for p in select * from seo_pages where is_active for update loop
    select coalesce(jsonb_agg(e.v order by (e.v ->> 'daily_rate_cents')::bigint nulls last), '[]'::jsonb) into v_cars
      from jsonb_array_elements(v_fleet) e(v) where app.seo_match(e.v, p.match);
    v_snap := jsonb_build_object('cars', (select coalesce(jsonb_agg(x.v order by x.n), '[]'::jsonb)
                                            from jsonb_array_elements(v_cars) with ordinality x(v, n) where x.n <= 24),
                                 'counts', app.seo_counts_of(v_cars));
    if p.cars_snapshot is distinct from v_snap then
      v_changed := v_changed + 1;
      update seo_pages set cars_snapshot = v_snap, snapshot_stamp = v_stamp, snapshot_at = now(),
             cars_changed_at = case when p.cars_snapshot is null then coalesce(cars_changed_at, now()) else now() end
       where slug = p.slug;
    else
      update seo_pages set snapshot_stamp = v_stamp, snapshot_at = now() where slug = p.slug;
    end if;
  end loop;
  return v_changed;
end $$;

-- the snapshot when it is current, else the live read (as 0061)
create or replace function app.seo_page_snapshot(p seo_pages) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when p.cars_snapshot is not null and p.snapshot_stamp = app.seo_fleet_stamp() then p.cars_snapshot end
$$;

create or replace function app.public_seo_page(p_slug text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with p as (select * from seo_pages where slug = lower(btrim(p_slug)) and is_active and copy <> '{}'::jsonb),
       s as (select app.seo_page_snapshot(p) as snap from p),
       c as (select case when s.snap is not null then s.snap -> 'cars' else
                (select coalesce(jsonb_agg(r order by (r ->> 'daily_rate_cents')::bigint nulls last), '[]'::jsonb)
                   from app.public_fleet('{}'::jsonb) r where app.seo_match(r, p.match)) end as cars,
                    s.snap -> 'counts' as counts
               from p, s)
  select jsonb_build_object('slug', p.slug, 'kind', p.kind, 'name', p.name, 'path', app.seo_page_path(p.slug), 'copy', p.copy,
           'facts', p.facts, 'indexable', app.seo_page_indexable(p), 'lastmod', greatest(p.content_updated_at, p.cars_changed_at),
           'cars', (select coalesce(jsonb_agg(e.v order by e.n), '[]'::jsonb) from jsonb_array_elements(c.cars) with ordinality e(v, n) where e.n <= 24),
           'airport', case when p.facts ? 'airport_code' then (select jsonb_build_object('code', a.code, 'name', a.name, 'surcharge_cents', a.surcharge_cents)
                                                               from airports a where a.code = p.facts ->> 'airport_code' and a.is_active) end,
           'delivery_per_km_cents', (app.settings()).delivery_per_km_cents,
           'distance_km', case when (app.settings()).company_latitude is not null and p.facts ? 'lat'
                               then round(app.distance_km((app.settings()).company_latitude, (app.settings()).company_longitude,
                                                          (p.facts ->> 'lat')::numeric, (p.facts ->> 'lng')::numeric), 0) end,
           'nearby', (select coalesce(jsonb_agg(jsonb_build_object('slug', n.slug, 'name', n.name, 'path', app.seo_page_path(n.slug)) order by n.sort_order), '[]'::jsonb)
                        from seo_pages n where n.slug <> p.slug and n.kind = p.kind
                          and (jsonb_typeof(p.facts -> 'nearby') is distinct from 'array' or n.slug = any (array(select jsonb_array_elements_text(p.facts -> 'nearby'))))
                          and app.seo_page_indexable(n)),
           'other', (select coalesce(jsonb_agg(jsonb_build_object('slug', n.slug, 'name', n.name, 'path', app.seo_page_path(n.slug)) order by n.sort_order), '[]'::jsonb)
                        from seo_pages n where n.kind <> p.kind and app.seo_page_indexable(n)
                          and (jsonb_typeof(p.facts -> 'nearby') is distinct from 'array' or n.slug = any (array(select jsonb_array_elements_text(p.facts -> 'nearby'))))))
         || coalesce(c.counts, app.seo_counts_of(c.cars))
    from p, c
$$;

-- the hub: every page with its counts; the fleet is read live only when a snapshot is missing or out of date
create or replace function app.public_seo_pages() returns jsonb
language sql stable security definer set search_path = public, app as $$
  with st as (select app.seo_fleet_stamp() as stamp),
       pg as (select p, case when p.cars_snapshot is not null and p.snapshot_stamp = st.stamp then p.cars_snapshot -> 'counts' end as n
                from seo_pages p, st where p.is_active and p.copy <> '{}'::jsonb),
       f as materialized (select r from app.public_fleet('{}'::jsonb) r where exists (select 1 from pg where pg.n is null)),
       x as (select pg.p, coalesce(pg.n, app.seo_counts_of((select coalesce(jsonb_agg(f.r), '[]'::jsonb) from f where app.seo_match(f.r, (pg.p).match)))) as n
               from pg)
  select coalesce(jsonb_agg(jsonb_build_object('slug', (x.p).slug, 'kind', (x.p).kind, 'name', (x.p).name, 'path', app.seo_page_path((x.p).slug),
           'h1', (x.p).copy ->> 'h1', 'summary', (x.p).copy ->> 'meta_description', 'indexable', app.seo_page_indexable(x.p),
           'lastmod', greatest((x.p).content_updated_at, (x.p).cars_changed_at)) || x.n order by (x.p).kind, (x.p).sort_order, (x.p).name), '[]'::jsonb)
    from x
$$;

-- the sitemap: a landing page's date is its text's or its cars' last change, from the row (no fleet read)
create or replace function app.public_sitemap_rows() returns table (path text, kind text, lastmod timestamptz, images jsonb)
language sql stable security definer set search_path = public, app as $$
  select s.path, s.kind, s.lastmod,
         case when s.kind = 'car' then (select coalesce(jsonb_agg(jsonb_build_object('loc', ph.processed_path, 'title', ph.alt_text) order by ph.is_cover desc, st.seq), '[]'::jsonb)
                                         from vehicle_listings l join vehicle_photos ph on ph.vehicle_id = l.vehicle_id
                                         left join listing_shot_types st on st.code = ph.shot_type
                                        where '/cars/' || l.slug = s.path and ph.is_public and ph.status = 'approved' and ph.replaced_at is null
                                          and ph.processed_path is not null) end
    from app.public_sitemap() s
  union all
  select app.seo_page_path(p.slug), 'landing', greatest(p.content_updated_at, p.cars_changed_at), null
    from seo_pages p where app.seo_page_indexable(p)
  union all
  select '/guides/' || a.slug, 'article', a.content_updated_at, null from articles a where a.is_published
$$;

revoke all on function app.seo_fleet_stamp(), app.seo_snapshot_refresh(), app.seo_page_snapshot(seo_pages) from public, anon, authenticated;
grant execute on function app.seo_fleet_stamp(), app.seo_snapshot_refresh(), app.seo_page_snapshot(seo_pages) to service_role;

-- the search job (every 5 minutes through the Worker) and pg_cron (every 10 minutes) keep the snapshots current
create or replace function public.server_seo_snapshots() returns integer
language sql security definer set search_path = public, app as $$ select app.seo_snapshot_refresh() $$;
revoke all on function public.server_seo_snapshots() from public, anon, authenticated;
grant execute on function public.server_seo_snapshots() to service_role;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-seo-snapshots', '3,13,23,33,43,53 * * * *', 'select app.seo_snapshot_refresh()');
  end if;
end $$;

-- ================================================================ the car copy scan (0061) reads the site facts once
-- app.car_copy_facts evaluated public.site_facts() several times per car (about 0.4 s a car); the scan, which runs at
-- every search job, on Write again and on an edit, took 17 to 40 s with 41 cars. The facts now take the site facts as
-- an argument, read once per scan (the same facts, so the same hashes: nothing is written again).
create or replace function app.car_copy_facts_of(p_vehicle uuid, p_site jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with v as (select * from vehicles where id = p_vehicle),
       l as (select * from vehicle_listings where vehicle_id = p_vehicle),
       rc as (select r.* from rate_cards r where r.vehicle_id = p_vehicle and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now())
              order by r.effective_from desc limit 1),
       s as (select * from site_settings limit 1),
       f as (select p_site j),
       vd as (select d.* from vin_decodes d join v on upper(d.vin) = upper(v.vin) where d.ok order by d.decoded_at desc limit 1)
  select jsonb_strip_nulls(jsonb_build_object(
    'car', jsonb_build_object(
      'year', v.year, 'make', v.make, 'model', v.model, 'trim', nullif(btrim(v.trim), ''), 'colour', nullif(btrim(v.colour), ''),
      'body_style', coalesce(nullif(btrim(l.body_style), ''), nullif(btrim(v.body_type), '')),
      'seats', l.seats, 'doors', l.doors,
      'fuel', case v.fuel when 'gasoline' then 'Gas' when 'diesel' then 'Diesel' when 'hybrid' then 'Hybrid' when 'plug_in_hybrid' then 'Plug-in hybrid'
                          when 'electric' then 'Electric' end,
      'transmission', nullif(btrim(l.transmission), ''), 'drivetrain', coalesce(nullif(btrim(l.drivetrain), ''), vd.drivetrain),
      'luggage', nullif(btrim(l.luggage), ''), 'engine', coalesce(l.specs ->> 'engine', vd.engine),
      'consumption', l.specs ->> 'consumption', 'range', l.specs ->> 'range',
      'equipment', case when jsonb_typeof(l.specs -> 'equipment') = 'array' then l.specs -> 'equipment' end,
      'classes', (select jsonb_agg(c.label order by c.sort_order) from vehicle_classes c where c.code = any (app.vehicle_class_list(v.id)))),
    'prices', case when rc.id is not null then jsonb_build_object(
      'daily', app.money_words(rc.daily_rate_cents), 'weekend_day', app.money_words(rc.weekend_rate_cents),
      'weekly', app.money_words(rc.weekly_rate_cents), 'monthly', app.money_words(rc.monthly_rate_cents),
      'monthly_days', (f.j ->> 'max_rental_days')::integer, 'km_per_day', rc.km_allowance_per_day,
      'extra_km', app.money_words(rc.overage_cents_per_km), 'deposit', app.money_words(rc.deposit_cents),
      'delivery_fee', app.money_words(rc.delivery_fee_cents), 'return_pickup_fee', app.money_words(rc.pickup_fee_cents),
      'tax', 'HST ' || app.fmt_pct((f.j ->> 'hst_bps')::integer) || ' added') end,
    'place', jsonb_build_object('area', coalesce(nullif(btrim(l.home_area), ''), s.city), 'city', s.city, 'region', s.region,
      'delivery', 'Delivered to any address for the car''s delivery fee' || case when (f.j ->> 'delivery_per_km_cents')::integer > 0 then ' plus distance' else '' end,
      'airports', (select jsonb_agg(a ->> 'name') from jsonb_array_elements(f.j -> 'airports') a),
      'pickup', 'Collect it at our location at no charge, or have it delivered'),
    'rules', jsonb_build_object(
      'min_age', (f.j ->> 'min_renter_age')::integer,
      'young_driver_fee_ages', (select jsonb_agg((b ->> 'from_age') || ' to ' || (b ->> 'to_age')) from jsonb_array_elements(f.j -> 'young_driver_bands') b
                                 where v.allows_18_to_20 or (b ->> 'from_age')::integer >= 21),
      'drivers_18_to_20', v.allows_18_to_20,
      'licence', 'Ontario ' || array_to_string(array(select jsonb_array_elements_text(f.j -> 'accepted_licence_classes')), ' or ') || ' licence',
      'card', 'A credit card in the renter''s name', 'identity', 'Licence and identity checked before pickup',
      'max_rental_days', (f.j ->> 'max_rental_days')::integer, 'request', 'Request to book with no payment; pay after we confirm'),
    'included', jsonb_build_array('Third-party liability coverage', 'Roadside assistance, 24 hours a day',
      case when rc.km_allowance_per_day is not null then rc.km_allowance_per_day || ' km a day' end, 'Handover in person with a walk-around of the car'),
    'photos', (select jsonb_agg(distinct ph.shot_type order by ph.shot_type) from vehicle_photos ph
                where ph.vehicle_id = v.id and ph.is_public and ph.status = 'approved' and ph.replaced_at is null),
    'staff_note', nullif(btrim(l.staff_note), ''),
    'brand', s.brand_name))
    from v left join l on true left join rc on true cross join s cross join f left join vd on true
$$;

create or replace function app.car_copy_facts(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.car_copy_facts_of(p_vehicle, public.site_facts()) $$;

create or replace function app.car_copy_scan() returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  v_facts jsonb;
  v_hash text;
  cc car_copy;
  n integer := 0;
  v_site jsonb := public.site_facts();
begin
  -- one scan at a time (the five-minute tick, a click on Write again and an edit can meet)
  perform pg_advisory_xact_lock(hashtext('carmacars:car_copy_scan'));
  for r in select v.id from vehicles v join vehicle_listings l on l.vehicle_id = v.id where app.car_copy_eligible(v.id) loop
    v_facts := app.car_copy_facts_of(r.id, v_site);
    v_hash := md5(v_facts::text);
    insert into car_copy (vehicle_id, facts, facts_hash, status, next_attempt_at) values (r.id, v_facts, v_hash, 'pending', now())
    on conflict (vehicle_id) do nothing;
    if found then n := n + 1; end if;
    select * into cc from car_copy where vehicle_id = r.id for update;
    if cc.facts_hash is distinct from v_hash then
      update car_copy set facts = v_facts, facts_hash = v_hash, attempts = 0, next_attempt_at = now(),
             status = case when status = 'running' and locked_at > now() - interval '10 minutes' then status else 'pending' end
       where vehicle_id = r.id returning * into cc;
      n := n + 1;
    end if;
    -- the plain copy while there is no written copy (or the plain one is out of date)
    if cc.source = 'template' and (cc.copy = '{}'::jsonb or cc.copy_facts_hash is distinct from v_hash) then
      begin
        perform app.car_copy_apply(r.id, app.car_copy_template(v_facts), 'template', v_hash);
        update car_copy set status = 'pending', next_attempt_at = least(next_attempt_at, now()) where vehicle_id = r.id;
      exception when sqlstate '23514' then
        update car_copy set problems = array['The plain copy could not be made: ' || sqlerrm] where vehicle_id = r.id;
      end;
    end if;
  end loop;
  -- a running row left behind by a worker that stopped
  update car_copy set status = 'pending', locked_at = null, worker = null where status = 'running' and locked_at < now() - interval '10 minutes';
  return n;
end $$;
revoke all on function app.car_copy_facts_of(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.car_copy_facts_of(uuid, jsonb) to service_role;

select app.seo_snapshot_refresh();
