-- 0073: a real car's page looks exactly like a sample car's (docs/changes/2026-10-21-real-car-listing-format.md)
--
-- The owner, October 21, 2026, after publishing the first real car (a 2022 Chevrolet Malibu LS): its page looked
-- very different from the 20 sample cars, and its stand-in photo looked nothing like theirs. From now on every real
-- car, existing and future, gets the sample cars' format automatically:
--   1. the specs in the samples' words ("Sedan", "Automatic (CVT)", "Front-wheel drive"), not the VIN decoder's
--   2. the copy: the samples' headline ("2022 Chevrolet Malibu LS for rent in Toronto"), a short blurb in their voice,
--      six selling features from the VIN decode and the trim (the model may add only what is standard on that trim),
--      nothing about where the car is kept; the description may be short (8 words and up), like the samples'
--   3. a clean web address (2022-chevrolet-malibu-ls; the colour, then a short code, only when another car has it),
--      the old one kept as a 301
--   4. stand-in images: the eight studio shots of the sample cars, drawn for the car's body and colour with its
--      model's name behind it (web/src/features/car/studio.ts), until its own photos are approved
--   5. real photos: the photo worker learns the car's model, to letter its name behind the car (lettering.ts)
--   6. every real listing is brought to the new format now (section 7), through the same functions.

-- ================================================================ 1. settings: the samples' short blurb is a valid description
-- and, like the samples, a car needs no questions of its own (the page always answers the common ones)
update program_settings set listing_description_words = int4range(8, 161), listing_faq_count = int4range(0, 9)
 where id = (app.settings()).id or effective_from > app.today();
alter table program_settings alter column listing_description_words set default int4range(8, 161),
  alter column listing_faq_count set default int4range(0, 9);

-- ================================================================ 2. specs in the sample cars' words
create or replace function app.listing_norm_body(p text) returns text
language sql immutable as $$
  select case
    when p is null or btrim(p) = '' then p
    when p ~* 'pick.?up' then 'Pickup truck'
    when p ~* 'minivan' then 'Minivan'
    when p ~* 'cargo van|^van' then 'Van'
    when p ~* 'sport utility vehicle|multi.?purpose' then 'SUV'
    when p ~* 'crossover utility' then 'Crossover SUV'
    when p ~* 'convertible|cabriolet' then 'Convertible'
    when p ~* '^sedan/saloon$|^sedan$' then 'Sedan'
    when p ~* 'hatchback' then 'Hatchback'
    when p ~* 'wagon' then 'Wagon'
    when p ~* '^coupe' then 'Coupe'
    when p ~ '/' then initcap(btrim(regexp_replace(split_part(p, '/', 1), '\s*\(.*\)', '')))
    else btrim(p) end
$$;

create or replace function app.listing_norm_transmission(p text) returns text
language sql immutable as $$
  select case
    when p is null or btrim(p) = '' then p
    when p ~* 'manual' then 'Manual'
    when p ~* 'continuously|cvt' then 'Automatic (CVT)'
    when p ~* 'dual.?clutch|dct' then 'Automatic (dual-clutch)'
    when p ~* 'auto' then 'Automatic'
    else btrim(p) end
$$;

create or replace function app.listing_norm_drive(p text) returns text
language sql immutable as $$
  select case
    when p is null or btrim(p) = '' then p
    when p ~* 'all.?wheel|awd' then 'All-wheel drive'
    when p ~* 'four.?wheel|4wd|4x4' then 'Four-wheel drive'
    when p ~* 'front.?wheel|fwd' then 'Front-wheel drive'
    when p ~* 'rear.?wheel|rwd' then 'Rear-wheel drive'
    else btrim(p) end
$$;

create or replace function app.vehicle_listing_norm_specs() returns trigger
language plpgsql set search_path = public, app as $$
begin
  new.body_style := app.listing_norm_body(new.body_style);
  new.transmission := app.listing_norm_transmission(new.transmission);
  new.drivetrain := app.listing_norm_drive(new.drivetrain);
  return new;
end $$;
drop trigger if exists vehicle_listings_norm_specs on vehicle_listings;
create trigger vehicle_listings_norm_specs before insert or update of body_style, transmission, drivetrain on vehicle_listings
  for each row execute function app.vehicle_listing_norm_specs();

-- ================================================================ 3. the equipment a car's features may name
-- known: what the VIN decode (NHTSA vPIC) reports as standard, the drivetrain, the third row, and what every car of
-- that age has (a backup camera from 2019, the Canadian rule of May 2018; Bluetooth from 2012). maybe: what is common
-- on the trim; the search job's model takes one only when it is sure it is standard on every car of that trim sold in
-- Canada. In the order renters care about.
create or replace function app.vehicle_equipment(p_vehicle uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
  l vehicle_listings;
  r jsonb := '{}'::jsonb;
  k text[] := '{}';
  m text[] := '{}';
  std text := '^\s*standard\s*$';
  b text;
begin
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then return jsonb_build_object('known', '[]'::jsonb, 'maybe', '[]'::jsonb); end if;
  select * into l from vehicle_listings where vehicle_id = p_vehicle;
  select coalesce(d.raw, '{}'::jsonb) into r from vin_decodes d where upper(d.vin) = upper(v.vin) and d.ok order by d.decoded_at desc limit 1;
  r := coalesce(r, '{}'::jsonb);
  if r ->> 'Results' is not null and jsonb_typeof(r -> 'Results') = 'array' then r := coalesce(r -> 'Results' -> 0, '{}'::jsonb); end if;
  b := lower(coalesce(l.body_style, v.body_type, ''));

  if v.fuel::text = 'electric' then k := k || 'Electric, no gas stops'::text; end if;
  if v.fuel::text in ('hybrid', 'plug_in_hybrid') then k := k || 'Hybrid engine'::text; end if;
  if coalesce(l.drivetrain, r ->> 'DriveType', '') ~* 'all.?wheel|awd' then k := k || 'All-wheel drive'::text;
  elsif coalesce(l.drivetrain, r ->> 'DriveType', '') ~* 'four.?wheel|4wd|4x4' then k := k || 'Four-wheel drive'::text; end if;
  if coalesce(l.seats, 0) >= 7 or coalesce(r ->> 'SeatRows', '') ~ '^[3-9]' then k := k || 'Third-row seating'::text; end if;
  if r ->> 'AdaptiveCruiseControl' ~* std then k := k || 'Adaptive cruise control'::text; end if;
  if r ->> 'BlindSpotMon' ~* std then k := k || 'Blind spot assist'::text; end if;
  if r ->> 'LaneKeepSystem' ~* std or r ->> 'LaneCenteringAssistance' ~* std then k := k || 'Lane keeping assist'::text; end if;
  if r ->> 'CIB' ~* std or r ->> 'PedestrianAutomaticEmergencyBraking' ~* std then k := k || 'Automatic emergency braking'::text; end if;
  if r ->> 'RearVisibilitySystem' ~* std or v.year >= 2019 then k := k || 'Backup camera'::text; end if;
  if r ->> 'KeylessIgnition' ~* std then k := k || 'Push-button start'::text; end if;
  if r ->> 'Turbo' ~* '^\s*yes' and v.fuel::text not in ('electric') then k := k || 'Turbocharged engine'::text; end if;
  if r ->> 'RearCrossTrafficAlert' ~* std then k := k || 'Rear cross traffic alert'::text; end if;
  if r ->> 'ForwardCollisionWarning' ~* std then k := k || 'Forward collision alert'::text; end if;
  if r ->> 'ParkAssist' ~* std then k := k || 'Parking assist'::text; end if;
  if r ->> 'SemiautomaticHeadlampBeamSwitching' ~* std then k := k || 'Automatic high beams'::text; end if;
  if r ->> 'LowerBeamHeadlampLightSource' ~* 'led' then k := k || 'LED headlights'::text; end if;
  if v.year >= 2012 then k := k || 'Bluetooth'::text; end if;
  k := k || array['Air conditioning', 'Cruise control'];
  if coalesce(l.transmission, '') ~* 'auto' then k := k || 'Automatic transmission'::text; end if;
  -- a person's own list on the listing (specs.equipment) is known too, first
  if jsonb_typeof(l.specs -> 'equipment') = 'array' then
    k := array(select jsonb_array_elements_text(l.specs -> 'equipment')) || k;
  end if;

  if v.year >= 2017 then m := m || 'Apple CarPlay and Android Auto'::text; end if;
  m := m || array['Heated front seats', 'Heated steering wheel', 'Remote start', 'Sunroof', 'Leather seats', 'Wireless phone charging'];
  if b ~ 'suv|sport utility|crossover|wagon' then m := m || array['Power tailgate', 'Roof rails']; end if;
  if b ~ 'van|minivan' then m := m || array['Power sliding doors', 'Rear climate controls']; end if;
  if b ~ 'pick.?up|truck' then m := m || array['Tow hitch', 'Bed liner']; end if;
  if b ~ 'convertible|cabriolet' then m := m || 'Power soft top'::text; end if;

  return jsonb_build_object(
    'known', (select coalesce(jsonb_agg(x order by o), '[]'::jsonb) from (select distinct on (lower(x)) x, o from unnest(k) with ordinality u(x, o) order by lower(x), o) d),
    'maybe', (select coalesce(jsonb_agg(x order by o), '[]'::jsonb) from (select distinct on (lower(x)) x, o from unnest(m) with ordinality u(x, o)
                where not (lower(x) = any (array(select lower(y) from unnest(k) y))) order by lower(x), o) d));
end $$;

-- The facts of the copy: the equipment lists added; where the car is kept taken out (it is never in the copy).
alter function app.car_copy_facts_of(uuid, jsonb) rename to car_copy_facts_of_pre0073;
create or replace function app.car_copy_facts_of(p_vehicle uuid, p_site jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  f jsonb := app.car_copy_facts_of_pre0073(p_vehicle, p_site);
  e jsonb := app.vehicle_equipment(p_vehicle);
begin
  if f is null then return f; end if;
  f := f #- '{place,area}';
  return jsonb_set(f, '{car}', coalesce(f -> 'car', '{}'::jsonb) || jsonb_build_object('equipment_known', e -> 'known', 'equipment_maybe', e -> 'maybe'));
end $$;

-- ================================================================ 4. the plain copy and the copy put live, in the samples' format
create or replace function app.car_copy_headline(p_facts jsonb) returns text
language sql immutable as $$
  select case when length(full_ || ' for rent in ' || city) <= 70 then full_ || ' for rent in ' || city else name_ || ' for rent in ' || city end
    from (select concat_ws(' ', p_facts #>> '{car,year}', p_facts #>> '{car,make}', p_facts #>> '{car,model}', nullif(btrim(p_facts #>> '{car,trim}'), '')) full_,
                 concat_ws(' ', p_facts #>> '{car,year}', p_facts #>> '{car,make}', p_facts #>> '{car,model}') name_,
                 coalesce(p_facts #>> '{place,city}', 'Toronto') city) x
$$;

-- The plain blurb (the same words as plainBlurb in web/src/features/seo/copy.ts): from the body alone, in the voice of
-- the sample cars, nothing the facts do not support, nothing about where the car is kept.
create or replace function app.car_copy_blurb(p_facts jsonb) returns text
language plpgsql immutable as $$
declare
  b text := lower(coalesce(p_facts #>> '{car,body_style}', ''));
  mk text := coalesce(p_facts #>> '{car,make}', '');
  n integer := nullif(p_facts #>> '{car,seats}', '')::integer;
  seats text := case when n between 0 and 9 then (array['zero','one','two','three','four','five','six','seven','eight','nine'])[n + 1] else n::text end;
  awd boolean := coalesce(p_facts #>> '{car,drivetrain}', '') ~* 'all|four|4wd|awd|4x4';
begin
  if coalesce(p_facts #>> '{car,fuel}', '') ~* 'electric' then
    return 'Electric, so no gas stations. Charge it up, return it with the charge you left with, and that is the whole fuel policy.';
  end if;
  if b ~ 'van|mpv' then return 'Room for ' || coalesce(seats, 'everyone') || ' and their bags. The airport run or the cottage weekend with everybody in one car.'; end if;
  if b ~ 'pick.?up|truck' then return 'A ' || mk || ' pickup with an open box. Moving day, a hardware run or a load of firewood.'; end if;
  if b ~ 'convertible|cabriolet|roadster' then return 'Roof down along the lakeshore. The ' || mk || ' for the days when the drive is the point.'; end if;
  if b ~ 'coupe' then return 'A ' || mk || ' for the days when the drive is the point, with a low seat and a bit of life in the steering.'; end if;
  if b ~ 'suv|sport utility|crossover' then
    return 'A high seat, a big boot and room for ' || coalesce(seats, 'the family') || case when awd then ', with all-wheel drive for whatever February brings' else '' end || '. Good for weekends out of the city.';
  end if;
  if b ~ 'hatch|wagon|liftback' then return 'Easy to park downtown, with a wide opening at the back for bags, groceries and a stroller.'; end if;
  return 'A comfortable ' || mk || ' sedan with room for ' || coalesce(seats, 'four adults') || ' and a proper trunk. Easy to park in the city and quiet on the highway.';
end $$;

alter function app.car_copy_template(jsonb) rename to car_copy_template_pre0073;
create or replace function app.car_copy_template(p_facts jsonb) returns jsonb
language plpgsql immutable as $$
declare
  c jsonb := app.car_copy_template_pre0073(p_facts);
  hl jsonb := (select coalesce(jsonb_agg(x), '[]'::jsonb) from (select x from jsonb_array_elements_text(coalesce(p_facts #> '{car,equipment_known}', '[]'::jsonb)) x limit 6) q);
begin
  if jsonb_array_length(hl) < 3 then hl := c -> 'highlights'; end if;
  return c || jsonb_build_object(
    'h1', app.car_copy_headline(p_facts),
    'intro', app.car_copy_blurb(p_facts),
    'highlights', hl,
    -- the page answers prices, kilometres, delivery and payment for every car; the plain copy adds only the seats
    'faq', jsonb_build_array(jsonb_build_object('question', 'How many people fit in the ' || (p_facts #>> '{car,model}') || '?',
      'answer', coalesce('It has ' || (p_facts #>> '{car,seats}') || ' seats.', 'Ask us before you book.'))),
    'pickup_delivery', 'Collect it at our location at no charge, or we deliver it to your address'
                       || coalesce(' for ' || (p_facts #>> '{prices,delivery_fee}'), '') || '. We hand it over in person and walk around the car with you.');
end $$;

-- Every copy put live carries the samples' headline (unless a person locked theirs: 0061 keeps locked fields).
alter function app.car_copy_apply(uuid, jsonb, text, text) rename to car_copy_apply_pre0073;
create or replace function app.car_copy_apply(p_vehicle uuid, p_copy jsonb, p_source text, p_facts_hash text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  f jsonb := (select facts from car_copy where vehicle_id = p_vehicle);
begin
  if f is null or f = '{}'::jsonb then f := app.car_copy_facts(p_vehicle); end if;
  return app.car_copy_apply_pre0073(p_vehicle, coalesce(p_copy, '{}'::jsonb) || jsonb_build_object('h1', app.car_copy_headline(f)), p_source, p_facts_hash);
end $$;

-- The car page tells the site which copy fields a person locked (only those override the search text built from the car).
alter function app.public_car_page(text) rename to public_car_page_pre0073;
create or replace function app.public_car_page(p_slug text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when r is null or r ? 'redirect' then r
              else r || jsonb_build_object('copy_locked', (select to_jsonb(cc.locked) from car_copy cc where cc.vehicle_id = (r ->> 'vehicle_id')::uuid)) end
    from (select app.public_car_page_pre0073(p_slug) r) x
$$;

-- ================================================================ 5. clean web addresses
-- year-make-model-trim, like 2022-chevrolet-malibu-ls; with the colour when another car (live or redirected) has it,
-- then a short code. Never one that belonged to another car.
create or replace function app.listing_slug(p_vehicle uuid) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
  v_base text;
  v_try text;
  v_n integer := 4;
  free_ boolean;
begin
  select * into v from vehicles where id = p_vehicle;
  v_base := left(app.slugify(concat_ws(' ', v.year::text, v.make, v.model, v.trim)), 80);
  foreach v_try in array array[v_base, left(app.slugify(concat_ws(' ', v.year::text, v.make, v.model, v.trim, v.colour)), 90)] loop
    select not exists (select 1 from vehicle_listings l where l.slug = v_try and l.vehicle_id <> v.id)
       and not exists (select 1 from listing_redirects r where r.from_path = '/cars/' || v_try and r.vehicle_id is distinct from v.id)
      into free_;
    if v_try is not null and free_ then return v_try; end if;
  end loop;
  loop
    v_try := left(app.slugify(concat_ws(' ', v.year::text, v.make, v.model, v.trim, v.colour)), 90) || '-' || substr(md5(v.id::text), 1, v_n);
    exit when not exists (select 1 from vehicle_listings l where l.slug = v_try and l.vehicle_id <> v.id)
          and not exists (select 1 from listing_redirects r where r.from_path = '/cars/' || v_try and r.vehicle_id is distinct from v.id);
    v_n := v_n + 1;
  end loop;
  return v_try;
end $$;

-- The address of a published car stays fixed, except when this migration (or a later one) moves it on purpose,
-- leaving a 301 behind.
create or replace function app.vehicle_listing_before_update() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if old.first_published_at is not null and new.slug is distinct from old.slug
     and coalesce(current_setting('app.listing_slug_move', true), '') <> old.vehicle_id::text then
    raise exception 'The web address of a car that has been published does not change' using errcode = '23514';
  end if;
  if (new.headline, new.description, new.features, new.seats, new.transmission, new.specs, new.body_style, new.drivetrain,
      new.doors, new.luggage, new.faq, new.home_area, new.seo_title, new.seo_description, new.staff_note, new.status,
      new.canonical_vehicle_id)
     is distinct from
     (old.headline, old.description, old.features, old.seats, old.transmission, old.specs, old.body_style, old.drivetrain,
      old.doors, old.luggage, old.faq, old.home_area, old.seo_title, old.seo_description, old.staff_note, old.status,
      old.canonical_vehicle_id) then
    new.content_updated_at := now();
  end if;
  return new;
end $$;

-- Move a real car to its clean address: the old one answers 301, redirects that pointed at it follow, both go to IndexNow.
create or replace function app.listing_move_to_clean_slug(p_vehicle uuid) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  l vehicle_listings;
  v_new text;
begin
  select * into l from vehicle_listings where vehicle_id = p_vehicle for update;
  if l.id is null or l.slug is null then return null; end if;
  v_new := app.listing_slug(p_vehicle);
  if v_new = l.slug then return v_new; end if;
  perform set_config('app.listing_slug_move', p_vehicle::text, true);
  update vehicle_listings set slug = v_new where id = l.id;
  perform set_config('app.listing_slug_move', '', true);
  delete from listing_redirects where from_path = '/cars/' || v_new;
  insert into listing_redirects (from_path, to_path, status_code, reason, vehicle_id)
  values ('/cars/' || l.slug, '/cars/' || v_new, 301, 'Clean web address (0073)', p_vehicle)
  on conflict (from_path) do update set to_path = excluded.to_path, status_code = 301, reason = excluded.reason, vehicle_id = excluded.vehicle_id, updated_at = now();
  update listing_redirects set to_path = '/cars/' || v_new, updated_at = now() where to_path = '/cars/' || l.slug and from_path <> '/cars/' || v_new;
  if l.status in ('published', 'paused') then
    begin
      perform app.indexnow_queue_path('/cars/' || v_new, 'clean address');
      perform app.indexnow_queue_path('/cars/' || l.slug, 'moved');
    exception when others then null;
    end;
  end if;
  return v_new;
end $$;

-- ================================================================ 6. stand-in images in the sample cars' studio style
-- The drawing for a car: its body shape and its paint (the same rules as studioShape and studioPaint in studio.ts).
create or replace function app.studio_shape(p_vehicle uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case
    when b ~* 'convertible|cabriolet|roadster|spyder|spider' then 'roadster'
    when b ~* 'coupe' then 'fastback'
    when b ~* 'van|minivan|mpv' then 'van'
    when b ~* 'pick.?up|truck' then 'suvlg'
    when b ~* 'suv|sport utility|crossover|cuv' then case when coalesce(l.seats, 5) >= 7 or b ~* 'full|large|mid.?size' then 'suvlg' else 'suv' end
    when b ~* 'hatch|liftback|wagon|compact' then 'compact'
    else 'sedan' end
    from vehicles v
    left join vehicle_listings l on l.vehicle_id = v.id
    cross join lateral (select coalesce(nullif(l.body_style, ''), nullif(v.body_type, ''),
                                        (select d.body_class from vin_decodes d where upper(d.vin) = upper(v.vin) and d.ok order by d.decoded_at desc limit 1), '') as b) x
   where v.id = p_vehicle
$$;

create or replace function app.studio_paint(p_colour text) returns text
language sql immutable as $$
  select case
    when c ~ 'white|pearl|snow|ivory|alabaster|glacier|polar|chalk' then 'white'
    when c ~ 'black|obsidian|onyx|ebony|jet|midnight|night' then 'black'
    when c ~ 'silver|platinum|aluminium|aluminum|chrome|steel' then 'silver'
    when c ~ 'grey|gray|graphite|gunmetal|charcoal|slate|titanium|magnetic|cement|ash' then 'grey'
    when c ~ 'red|maroon|burgundy|crimson|ruby|cherry|wine' then 'red'
    when c ~ 'blue|navy|azure|cobalt|sapphire|teal' then 'blue'
    when c ~ 'green|olive|emerald|lime|jade' then 'green'
    when c ~ 'beige|tan|sand|champagne|gold|cream|khaki' then 'beige'
    when c ~ 'brown|bronze|copper|mocha|espresso' then 'brown'
    when c ~ 'orange|amber' then 'orange'
    when c ~ 'yellow' then 'yellow'
    else 'grey' end
    from (select lower(coalesce(p_colour, '')) c) x
$$;

-- The eight shots of a stand-in set, as the sample cars have them, at /sample-photos/studio/<shape>/<paint>/<shot>/<NAME>.svg.
create or replace function app.vehicle_studio_photos(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'path', '/sample-photos/studio/' || app.studio_shape(v.id) || '/' || app.studio_paint(v.colour) || '/' || s.k || '/'
                   || replace(left(btrim(regexp_replace(upper(coalesce(v.model, 'car')), '[^A-Z0-9 &.-]+', ' ', 'g')), 24), ' ', '%20') || '.svg',
           'alt', left(format('Representative studio image of a %s %s like the %s, %s', app.studio_paint(v.colour), app.sample_body_label(app.sample_body_key(v.id)),
                              concat_ws(' ', v.year::text, v.make, v.model), s.view), 200),
           'width', 1800, 'height', 1200, 'shot', s.shot, 'label', coalesce(st.label, s.view), 'is_cover', s.n = 1, 'sample', true, 'studio', true)
         order by s.n), '[]'::jsonb)
    from vehicles v
    cross join (values (1, 'lead', 'front_left', 'front three-quarter view'), (2, 'side', 'left', 'side profile'), (3, 'rear34', 'rear_left', 'rear three-quarter view'),
                       (4, 'front', 'front', 'from the front'), (5, 'rear', 'rear', 'from the rear'), (6, 'dash', 'dashboard', 'dashboard and steering wheel'),
                       (7, 'seats', 'front_seats', 'seats'), (8, 'wheel', 'wheel', 'wheel')) s(n, k, shot, view)
    left join listing_shot_types st on st.code = s.shot
   where v.id = p_vehicle
$$;

-- The sample photos of a car (0054): the library's photos when an Admin added some for its make, model or body type;
-- otherwise the stand-in studio set (was one built-in picture per body type).
alter function app.vehicle_sample_photos(uuid) rename to vehicle_sample_photos_pre0073;
create or replace function app.vehicle_sample_photos(p_vehicle uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.vehicle_sample_photos_pre0073(p_vehicle);
begin
  if jsonb_array_length(coalesce(x, '[]'::jsonb)) = 0 or (x -> 0) ? 'builtin' then
    return app.vehicle_studio_photos(p_vehicle);
  end if;
  return x;
end $$;

-- The photo worker letters the model's name behind the car: the job's photo carries the model.
alter function app.listing_job_context(uuid) rename to listing_job_context_pre0073;
create or replace function app.listing_job_context(p_job uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when x -> 'photo' is null or jsonb_typeof(x -> 'photo') <> 'object' then x
              else jsonb_set(x, '{photo,model}', to_jsonb((select v.model from vehicles v where v.id = (x ->> 'vehicle_id')::uuid))) end
    from (select app.listing_job_context_pre0073(p_job) x) q
$$;

-- ================================================================ privileges
-- new functions: the service role only; the renamed ones keep their privileges and the ones in their place get the same
do $$
declare
  f record;
  r record;
  v_new regprocedure;
  g text;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['listing_norm_body', 'listing_norm_transmission', 'listing_norm_drive', 'vehicle_listing_norm_specs',
              'vehicle_equipment', 'car_copy_headline', 'car_copy_blurb', 'listing_move_to_clean_slug', 'studio_shape', 'studio_paint', 'vehicle_studio_photos'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
  for r in select p.oid, m.new_name, oidvectortypes(p.proargtypes) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             join (values ('car_copy_facts_of_pre0073', 'car_copy_facts_of'), ('car_copy_template_pre0073', 'car_copy_template'),
                          ('car_copy_apply_pre0073', 'car_copy_apply'), ('public_car_page_pre0073', 'public_car_page'),
                          ('vehicle_sample_photos_pre0073', 'vehicle_sample_photos'), ('listing_job_context_pre0073', 'listing_job_context')) m(old_name, new_name)
               on m.old_name = p.proname
            where n.nspname = 'app' loop
    v_new := format('app.%I(%s)', r.new_name, r.args)::regprocedure;
    execute format('revoke all on function %s from public, anon, authenticated', v_new);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;

-- ================================================================ 7. every real listing in the new format, now
-- The specs in the samples' words (the trigger), the clean address with its 301, and the copy: the plain copy of the
-- new format at once (a person's locked fields kept), then the search job writes the AI copy again with car-copy-v2.
create or replace function app.listing_format_refresh() returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  v_site jsonb := public.site_facts();
  v_facts jsonb;
  v_hash text;
  n integer := 0;
begin
  update vehicle_listings l set body_style = l.body_style, transmission = l.transmission, drivetrain = l.drivetrain
    from vehicles v where v.id = l.vehicle_id and not v.is_sample;
  for r in select l.vehicle_id from vehicle_listings l join vehicles v on v.id = l.vehicle_id
            where not v.is_sample and l.slug is not null and l.status in ('published', 'paused') loop
    perform app.listing_move_to_clean_slug(r.vehicle_id);
  end loop;
  for r in select v.id from vehicles v join vehicle_listings l on l.vehicle_id = v.id where app.car_copy_eligible(v.id) loop
    v_facts := app.car_copy_facts_of(r.id, v_site);
    v_hash := md5(v_facts::text);
    insert into car_copy (vehicle_id, facts, facts_hash) values (r.id, v_facts, v_hash)
    on conflict (vehicle_id) do update set facts = excluded.facts, facts_hash = excluded.facts_hash;
    begin
      perform app.car_copy_apply(r.id, app.car_copy_template(v_facts), 'template', v_hash);
    exception when sqlstate '23514' then
      update car_copy set problems = array['The plain copy could not be made: ' || sqlerrm] where vehicle_id = r.id;
    end;
    update car_copy set status = 'pending', attempts = 0, next_attempt_at = now(), asked_at = now(), locked_at = null, worker = null
     where vehicle_id = r.id;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function app.listing_format_refresh() from public, anon, authenticated;
grant execute on function app.listing_format_refresh() to service_role;
select app.listing_format_refresh();
