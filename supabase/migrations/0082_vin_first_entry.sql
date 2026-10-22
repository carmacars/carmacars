-- 0082_vin_first_entry.sql
-- The owner, October 21, 2026: "Put in a VIN and the description and title and everything gets generated automatically
-- from that rather than having to type in any details manually." (docs/changes/2026-10-21-vin-first-entry.md)
--   1. Every place a car is added (Admin > Add a car, Add a car for an owner by an Admin or an assistant, the owner's own
--      application) starts from the VIN: one decode (stored once per VIN, vin_decodes) gives the year, make, model,
--      trim, body, doors, seats, fuel, drivetrain, transmission and engine. app.vin_facts answers for a VIN in one call:
--      the check digit, the decode on file, a car already in the fleet, the class and the starting daily rate.
--   2. The pricing class is inferred from the make, model, trim, body and age (vehicle_class_rules, editable rows with
--      sensible defaults: exotic and luxury makes and models, premium makes, sports models, SUVs, small cars), and it
--      sets the rates the form starts from. A person's choice of class is kept.
--   3. A new car gets every decoded detail its listing needs (the empty ones only; nothing a person entered is
--      overwritten), its class, and its copy queued at once (car_copy, asked first) so the search job writes the title,
--      the description and the features with car-copy-v2 (0073) right after it is added. The copy itself is unchanged.
--   4. The colour, which is not in the VIN: when it is empty and the car has a cover photo, the vision model (Workers AI,
--      Program settings ai_vision_model) names it from the photo; a person's colour is never replaced.
--   5. A VIN the decoder could not read is decoded again later (the listing worker's run), and the car gets the details
--      then. Existing real cars get their missing decoded details now; a program owner's car whose class nobody chose
--      gets the inferred class.
-- Functions changed are wrapped (renamed with the suffix _pre0082). No applied migration is edited.

-- ================================================================ 1. the class from the make, model, trim, body and age
create table vehicle_class_rules (
  id          uuid primary key default gen_random_uuid(),
  rank        integer not null default 100,
  make_key    text check (make_key is null or make_key ~ '^[a-z0-9]+$'),
  model_re    text,
  trim_re     text,
  body_re     text,
  class       vehicle_class not null,
  aged_years  smallint check (aged_years between 1 and 60),
  aged_class  vehicle_class,
  note        text not null check (length(note) between 2 and 200),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check ((aged_years is null) = (aged_class is null))
);
create index vehicle_class_rules_rank_idx on vehicle_class_rules (rank) where is_active;
create trigger vehicle_class_rules_updated before update on vehicle_class_rules for each row execute function app.set_updated_at();
comment on table vehicle_class_rules is 'How a new car''s pricing class is inferred (0082). The active rule of the lowest rank that matches wins: make_key (letters and digits of the make, lower case; null: any make), model_re, trim_re and body_re (case-insensitive patterns; null: any). aged_class applies once the car is aged_years old or more (a 2016 Porsche Macan is Premium, a new one Luxury). No rule: Standard.';

-- The make as a rule names it: "Mercedes-Benz", "MERCEDES BENZ" and "mercedes-benz" are all mercedesbenz.
create or replace function app.make_key(p text) returns text
language sql immutable as $$ select nullif(regexp_replace(lower(coalesce(p, '')), '[^a-z0-9]', '', 'g'), '') $$;

insert into vehicle_class_rules (rank, make_key, model_re, body_re, class, aged_years, aged_class, note)
select x.rank, x.make_key, x.model_re, x.body_re, x.class::vehicle_class, x.aged_years, x.aged_class::vehicle_class, x.note
  from (values
  -- exotic makes
  (10, 'ferrari', null, null, 'exotic', null, null, 'an exotic make'),
  (10, 'lamborghini', null, null, 'exotic', null, null, 'an exotic make'),
  (10, 'mclaren', null, null, 'exotic', null, null, 'an exotic make'),
  (10, 'rollsroyce', null, null, 'exotic', null, null, 'an exotic make'),
  (10, 'bentley', null, null, 'exotic', null, null, 'an exotic make'),
  (10, 'astonmartin', null, null, 'exotic', null, null, 'an exotic make'),
  (10, 'bugatti', null, null, 'exotic', null, null, 'an exotic make'),
  (10, 'lotus', null, null, 'luxury', null, null, 'a sports car make'),
  -- luxury models (Premium once they are older)
  (15, 'porsche', '^(911|cayman|boxster|718|taycan|panamera)', null, 'luxury', 12, 'premium', 'a Porsche sports car'),
  (20, 'porsche', null, null, 'luxury', 8, 'premium', 'a Porsche'),
  (20, 'mercedesbenz', '^(s|gle|gls|g|eqs|sl|amg gt|maybach)([- ]?class|[ -]?[0-9]|$)|amg|maybach', null, 'luxury', 8, 'premium', 'a flagship Mercedes-Benz'),
  (20, 'bmw', '^(7|8)( series|[0-9]{2})|^x[5-7]|^m[2-8]( |$|[a-z])|^i[x7]|^xm|alpina', null, 'luxury', 8, 'premium', 'a flagship BMW'),
  (20, 'audi', '^(a8|q7|q8|r8|s8|rs ?[0-9q]|e-tron gt)', null, 'luxury', 8, 'premium', 'a flagship Audi'),
  (20, 'lexus', '^(ls|lx|lc|gx)', null, 'luxury', 8, 'premium', 'a flagship Lexus'),
  (20, 'landrover', '^range rover( sport)?$|^range rover (autobiography|sv)', null, 'luxury', 8, 'premium', 'a Range Rover'),
  (20, 'cadillac', '^(escalade|ct6|lyriq|celestiq)', null, 'luxury', 8, 'premium', 'a flagship Cadillac'),
  (20, 'lincoln', '^navigator', null, 'luxury', 8, 'premium', 'a Lincoln Navigator'),
  (20, 'genesis', '^(g90|gv80)', null, 'luxury', 8, 'premium', 'a flagship Genesis'),
  (20, 'tesla', '^model (s|x)', null, 'luxury', 8, 'premium', 'a Tesla Model S or X'),
  (20, 'chevrolet', '^corvette', null, 'luxury', 12, 'premium', 'a Corvette'),
  (20, 'nissan', '^gt-?r', null, 'luxury', 12, 'premium', 'a Nissan GT-R'),
  (20, 'maserati', null, null, 'luxury', 10, 'premium', 'a Maserati'),
  (20, 'lucid', null, null, 'luxury', 10, 'premium', 'a Lucid'),
  -- premium makes
  (40, 'mercedesbenz', null, null, 'premium', null, null, 'a premium make'),
  (40, 'bmw', null, null, 'premium', null, null, 'a premium make'),
  (40, 'audi', null, null, 'premium', null, null, 'a premium make'),
  (40, 'lexus', null, null, 'premium', null, null, 'a premium make'),
  (40, 'acura', null, null, 'premium', null, null, 'a premium make'),
  (40, 'infiniti', null, null, 'premium', null, null, 'a premium make'),
  (40, 'cadillac', null, null, 'premium', null, null, 'a premium make'),
  (40, 'lincoln', null, null, 'premium', null, null, 'a premium make'),
  (40, 'genesis', null, null, 'premium', null, null, 'a premium make'),
  (40, 'volvo', null, null, 'premium', null, null, 'a premium make'),
  (40, 'landrover', null, null, 'premium', null, null, 'a premium make'),
  (40, 'jaguar', null, null, 'premium', null, null, 'a premium make'),
  (40, 'alfaromeo', null, null, 'premium', null, null, 'a premium make'),
  (40, 'tesla', null, null, 'premium', null, null, 'a premium make'),
  (40, 'polestar', null, null, 'premium', null, null, 'a premium make'),
  (40, 'rivian', null, null, 'premium', null, null, 'a premium make'),
  -- sports and premium models of the other makes
  (45, 'ford', '^mustang', null, 'premium', null, null, 'a sports model'),
  (45, 'chevrolet', '^camaro', null, 'premium', null, null, 'a sports model'),
  (45, 'dodge', '^challenger', null, 'premium', null, null, 'a sports model'),
  (45, 'mazda', '^(mx-?5|miata)', null, 'premium', null, null, 'a sports model'),
  (45, 'toyota', '^(gr )?supra', null, 'premium', null, null, 'a sports model'),
  (45, 'nissan', '^(370z|z)$', null, 'premium', null, null, 'a sports model'),
  (45, 'chrysler', '^pacifica', null, 'premium', null, null, 'a premium minivan'),
  -- SUVs, minivans, vans and pickups of the other makes
  (50, null, null, 'sport utility|suv|crossover|multi.?purpose|mpv|minivan|pick.?up|truck|\mvan\M', 'suv', null, null, 'an SUV, van or pickup'),
  -- small cars
  (60, 'kia', '^(rio|forte|soul)', null, 'economy', null, null, 'a small car'),
  (60, 'hyundai', '^(accent|elantra|venue)', null, 'economy', null, null, 'a small car'),
  (60, 'toyota', '^(yaris|corolla)$|^corolla (hatchback|im)', null, 'economy', null, null, 'a small car'),
  (60, 'nissan', '^(versa|sentra|micra)', null, 'economy', null, null, 'a small car'),
  (60, 'chevrolet', '^(spark|sonic|cruze)', null, 'economy', null, null, 'a small car'),
  (60, 'mitsubishi', '^mirage', null, 'economy', null, null, 'a small car'),
  (60, 'honda', '^fit', null, 'economy', null, null, 'a small car'),
  (60, 'ford', '^(fiesta|focus)', null, 'economy', null, null, 'a small car')
  ) x(rank, make_key, model_re, body_re, class, aged_years, aged_class, note);

create or replace function app.class_label(p_code text) returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce((select c.label from vehicle_classes c where c.code = p_code), initcap(p_code))
$$;

-- The class for a car: {class, rule, why}. why reads "Premium: a Porsche, 10 years old (Luxury when newer)".
create or replace function app.infer_vehicle_class(p_year integer, p_make text, p_model text, p_trim text default null, p_body text default null)
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare
  r vehicle_class_rules;
  v_age integer := case when p_year between 1900 and 2200 then extract(year from app.today())::integer - p_year end;
  v_class vehicle_class;
  v_aged boolean;
begin
  select * into r from vehicle_class_rules x
   where x.is_active
     and (x.make_key is null or x.make_key = app.make_key(p_make))
     and (x.model_re is null or coalesce(p_model, '') ~* x.model_re)
     and (x.trim_re is null or coalesce(p_trim, '') ~* x.trim_re)
     and (x.body_re is null or coalesce(p_body, '') ~* x.body_re)
   order by x.rank, (x.model_re is not null) desc, (x.trim_re is not null) desc, (x.body_re is not null) desc, x.created_at
   limit 1;
  if r.id is null then
    return jsonb_build_object('class', 'standard', 'rule', null, 'why', app.class_label('standard') || ': the default class');
  end if;
  v_aged := r.aged_years is not null and v_age is not null and v_age >= r.aged_years;
  v_class := case when v_aged then r.aged_class else r.class end;
  return jsonb_build_object('class', v_class, 'rule', r.id,
    'why', app.class_label(v_class::text) || ': ' || r.note
           || case when v_aged then format(', %s years old (%s when newer)', v_age, app.class_label(r.class::text)) else '' end);
end $$;

-- ================================================================ 2. what a VIN tells us, in one call
-- The decoder lists every trim a VIN may be when the VIN does not say ("S, Final Edition SE, SE"): no trim then.
create or replace function app.decode_trim(p text) returns text
language sql immutable as $$ select case when p ~ ',|\s/\s' then null else nullif(btrim(p), '') end $$;

-- The decode on file in the listing's words (the specs as the sample cars show them, 0073).
create or replace function app.vin_decode_json(d vin_decodes) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when d.id is null then null else jsonb_build_object(
    'year', d.year, 'make', d.make, 'model', d.model, 'trim', app.decode_trim(d.trim),
    'body', app.listing_norm_body(d.body_class), 'body_class', d.body_class, 'fuel', d.fuel,
    'drivetrain', app.listing_norm_drive(d.drivetrain), 'transmission', app.listing_norm_transmission(d.transmission),
    'doors', d.doors, 'seats', d.seats, 'engine', d.engine, 'decoded_at', d.decoded_at) end
$$;

-- The class and the starting daily rate for a car's facts (Add a car, before the car exists): p {year, make, model,
-- trim, body}. The rate is app.listing_default_daily (0070): the median of similar real cars, else the class default.
create or replace function app.vin_class_hint(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  c jsonb := app.infer_vehicle_class(nullif(p ->> 'year', '')::integer, p ->> 'make', p ->> 'model', p ->> 'trim', p ->> 'body');
  v_class text := coalesce(nullif(p ->> 'class', ''), c ->> 'class');
begin
  return jsonb_build_object('class', c, 'rates',
    app.listing_default_daily(null, jsonb_build_object('class', v_class, 'make', p ->> 'make', 'model', p ->> 'model')));
end $$;

-- Everything the form needs for a VIN: {vin, valid, check_ok, decode, decode_failed_at, taken, class, rates}. Stable:
-- the caller decodes (vPIC) when there is no decode on file yet, records it, and asks again.
create or replace function app.vin_facts(p_vin text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_vin text := app.clean_vin(p_vin);
  d vin_decodes;
  f vin_decodes;
  x vehicles;
  h jsonb;
begin
  if v_vin is null then
    return jsonb_build_object('vin', upper(regexp_replace(coalesce(p_vin, ''), '[\s-]', '', 'g')), 'valid', false);
  end if;
  select * into d from vin_decodes z where z.vin = v_vin and z.ok order by z.decoded_at desc limit 1;
  if d.id is null then select * into f from vin_decodes z where z.vin = v_vin and not z.ok order by z.decoded_at desc limit 1; end if;
  select * into x from vehicles z where upper(z.vin) = v_vin order by z.retired_at nulls first limit 1;
  if d.id is not null then
    h := app.vin_class_hint(jsonb_build_object('year', d.year, 'make', d.make, 'model', d.model, 'trim', app.decode_trim(d.trim), 'body', d.body_class));
  end if;
  return jsonb_build_object('vin', v_vin, 'valid', true, 'check_ok', app.vin_check_ok(v_vin),
    'decode', app.vin_decode_json(d),
    'decode_failed_at', f.decoded_at, 'decode_failures', (select count(*) from vin_decodes z where z.vin = v_vin and not z.ok),
    'taken', case when x.id is not null then jsonb_build_object('vehicle_id', x.id, 'name', app.vehicle_name(x.id),
               'supply', lower(app.supply_label(x.supply_type)), 'retired', x.retired_at is not null, 'is_sample', x.is_sample) end,
    'class', h -> 'class', 'rates', h -> 'rates');
end $$;

-- ================================================================ 3. a new car gets its details, its class and its copy
-- The decoded details a car is missing, filled from the decode on file: on the car (trim, body, fuel when it was only
-- the default) and on its listing (seats, doors, gearbox, drive, body, engine). Only empty fields, and never one a
-- person entered (spec_sources.<field>.source = 'person'). Returns the fields filled.
create or replace function app.vin_fill_missing(p_vehicle uuid) returns text[]
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  l vehicle_listings;
  d vin_decodes;
  v_src jsonb;
  v_lsrc jsonb;
  v_mark jsonb;
  v_out text[] := '{}';
  v_specs jsonb;
  person boolean;
begin
  select * into v from vehicles where id = p_vehicle for update;
  if v.id is null or v.vin is null or coalesce(v.is_sample, false) then return v_out; end if;
  select * into d from vin_decodes z where z.vin = upper(v.vin) and z.ok order by z.decoded_at desc limit 1;
  if d.id is null then return v_out; end if;
  v_mark := jsonb_build_object('source', 'decoded', 'decode_id', d.id, 'at', now());
  v_src := coalesce(v.spec_sources, '{}'::jsonb);
  if nullif(btrim(v.trim), '') is null and app.decode_trim(d.trim) is not null and coalesce(v_src #>> '{trim,source}', '') <> 'person' then
    v.trim := app.decode_trim(d.trim); v_src := v_src || jsonb_build_object('trim', v_mark); v_out := v_out || 'trim'::text; end if;
  if nullif(btrim(v.body_type), '') is null and nullif(btrim(d.body_class), '') is not null and coalesce(v_src #>> '{body_type,source}', '') <> 'person' then
    v.body_type := d.body_class; v_src := v_src || jsonb_build_object('body_type', v_mark); v_out := v_out || 'body_type'::text; end if;
  -- the fuel: a car added without one got gasoline by default (no source); the decode knows better
  if d.fuel is not null and v.fuel is distinct from d.fuel and not (v_src ? 'fuel') then
    v.fuel := d.fuel; v_src := v_src || jsonb_build_object('fuel', v_mark); v_out := v_out || 'fuel'::text; end if;
  if cardinality(v_out) > 0 then
    update vehicles set trim = v.trim, body_type = v.body_type, fuel = v.fuel, spec_sources = v_src where id = p_vehicle;
  end if;

  perform app.ensure_listing(p_vehicle);
  select * into l from vehicle_listings where vehicle_id = p_vehicle for update;
  v_lsrc := coalesce(l.spec_sources, '{}'::jsonb);
  person := false;
  if l.seats is null and d.seats is not null and coalesce(v_lsrc #>> '{seats,source}', '') <> 'person' then
    l.seats := d.seats; v_lsrc := v_lsrc || jsonb_build_object('seats', v_mark); v_out := v_out || 'seats'::text; person := true; end if;
  if l.doors is null and d.doors between 1 and 6 and coalesce(v_lsrc #>> '{doors,source}', '') <> 'person' then
    l.doors := d.doors; v_lsrc := v_lsrc || jsonb_build_object('doors', v_mark); v_out := v_out || 'doors'::text; person := true; end if;
  if nullif(btrim(l.transmission), '') is null and nullif(btrim(d.transmission), '') is not null and coalesce(v_lsrc #>> '{transmission,source}', '') <> 'person' then
    l.transmission := d.transmission; v_lsrc := v_lsrc || jsonb_build_object('transmission', v_mark); v_out := v_out || 'transmission'::text; person := true; end if;
  if nullif(btrim(l.drivetrain), '') is null and nullif(btrim(d.drivetrain), '') is not null and coalesce(v_lsrc #>> '{drivetrain,source}', '') <> 'person' then
    l.drivetrain := d.drivetrain; v_lsrc := v_lsrc || jsonb_build_object('drivetrain', v_mark); v_out := v_out || 'drivetrain'::text; person := true; end if;
  if nullif(btrim(l.body_style), '') is null and nullif(btrim(coalesce(v.body_type, d.body_class)), '') is not null and coalesce(v_lsrc #>> '{body_style,source}', '') <> 'person' then
    l.body_style := coalesce(nullif(btrim(v.body_type), ''), d.body_class); v_lsrc := v_lsrc || jsonb_build_object('body_style', v_mark); v_out := v_out || 'body_style'::text; person := true; end if;
  v_specs := coalesce(l.specs, '{}'::jsonb);
  if nullif(btrim(v_specs ->> 'engine'), '') is null and nullif(btrim(d.engine), '') is not null and coalesce(v_lsrc #>> '{engine,source}', '') <> 'person' then
    v_specs := v_specs || jsonb_build_object('engine', d.engine); v_lsrc := v_lsrc || jsonb_build_object('engine', v_mark); v_out := v_out || 'engine'::text; person := true; end if;
  if person then
    update vehicle_listings set seats = l.seats, doors = l.doors, transmission = l.transmission, drivetrain = l.drivetrain,
           body_style = l.body_style, specs = v_specs, spec_sources = v_lsrc
     where id = l.id;
  end if;
  return v_out;
end $$;

-- The pricing class of a car, with where it came from (spec_sources.class): the class of the old link it replaces is
-- taken off the car's classes when the schema added it (a person's extra classes stay).
create or replace function app.vehicle_set_class(p_vehicle uuid, p_class vehicle_class, p_source jsonb) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
begin
  select * into v from vehicles where id = p_vehicle for update;
  if v.id is null then return; end if;
  if v.class is distinct from p_class then
    delete from vehicle_class_links where vehicle_id = p_vehicle and class_code = v.class::text and source in ('vehicle', 'migrated');
  end if;
  update vehicles set class = p_class, spec_sources = coalesce(spec_sources, '{}'::jsonb) || jsonb_build_object('class', p_source) where id = p_vehicle;
end $$;

-- The class of a car nobody chose a class for: inferred from its facts. A person's class is kept.
create or replace function app.vehicle_infer_class(p_vehicle uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  c jsonb;
begin
  select * into v from vehicles where id = p_vehicle;
  if v.id is null or coalesce(v.spec_sources #>> '{class,source}', '') = 'person' then return null; end if;
  c := app.infer_vehicle_class(v.year, v.make, v.model, v.trim, coalesce(nullif(btrim(v.body_type), ''),
         (select l.body_style from vehicle_listings l where l.vehicle_id = v.id)));
  if v.class is distinct from (c ->> 'class')::vehicle_class or not (coalesce(v.spec_sources, '{}'::jsonb) ? 'class') then
    perform app.vehicle_set_class(p_vehicle, (c ->> 'class')::vehicle_class, jsonb_build_object('source', 'inferred', 'rule', c ->> 'rule', 'why', c ->> 'why', 'at', now()));
  end if;
  return c;
end $$;

-- The car's copy, now: its row queued and asked for first (the search job takes asked rows first, 0061), with the plain
-- copy in place while the AI copy is written. Returns whether it was queued (a sample car or an unpublished one is not).
create or replace function app.car_copy_queue(p_vehicle uuid) returns boolean
language plpgsql security definer set search_path = public, app as $$
declare
  v_facts jsonb;
  v_hash text;
  cc car_copy;
begin
  if not app.car_copy_eligible(p_vehicle) then return false; end if;
  v_facts := app.car_copy_facts(p_vehicle);
  v_hash := md5(v_facts::text);
  insert into car_copy (vehicle_id, facts, facts_hash, status, next_attempt_at, asked_at)
  values (p_vehicle, v_facts, v_hash, 'pending', now(), now())
  on conflict (vehicle_id) do update set facts = excluded.facts, facts_hash = excluded.facts_hash, attempts = 0, next_attempt_at = now(), asked_at = now(),
    status = case when car_copy.status = 'running' and car_copy.locked_at > now() - interval '10 minutes' then car_copy.status else 'pending' end
  returning * into cc;
  if cc.source = 'template' and (cc.copy = '{}'::jsonb or cc.copy_facts_hash is distinct from v_hash) then
    begin
      perform app.car_copy_apply(p_vehicle, app.car_copy_template(v_facts), 'template', v_hash);
      update car_copy set status = 'pending', next_attempt_at = now(), asked_at = now() where vehicle_id = p_vehicle;
    exception when sqlstate '23514' then
      update car_copy set problems = array['The plain copy could not be made: ' || sqlerrm] where vehicle_id = p_vehicle;
    end;
  end if;
  return true;
end $$;

-- After a car is added (every path): the decoded details it is missing, its class (p.class with p.class_source
-- 'person' is a person's choice; otherwise inferred), the colour's source, and its copy queued. Never raises: adding the
-- car is what counts; anything that fails here is done again by the next run (backfill, copy scan).
create or replace function app.vehicle_after_add(p_vehicle uuid, p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_filled text[] := '{}';
  v_class jsonb;
  v_copy boolean := false;
  v_given text := nullif(p ->> 'class', '');
begin
  if p_vehicle is null then return '{}'::jsonb; end if;
  begin
    v_filled := app.vin_fill_missing(p_vehicle);
    if v_given is not null and coalesce(p ->> 'class_source', 'person') <> 'inferred' then
      perform app.vehicle_set_class(p_vehicle, v_given::vehicle_class, jsonb_build_object('source', 'person', 'by', p_by, 'at', now()));
      v_class := jsonb_build_object('class', v_given, 'source', 'person');
    else
      v_class := app.vehicle_infer_class(p_vehicle) || jsonb_build_object('source', 'inferred');
    end if;
    if nullif(btrim(p ->> 'colour'), '') is not null then
      update vehicles set spec_sources = coalesce(spec_sources, '{}'::jsonb) || jsonb_build_object('colour', jsonb_build_object('source', 'person', 'by', p_by, 'at', now()))
       where id = p_vehicle and not (coalesce(spec_sources, '{}'::jsonb) ? 'colour');
    end if;
    perform app.ensure_listing(p_vehicle);
    v_copy := app.car_copy_queue(p_vehicle);
  exception when others then
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'vehicle_after_add_failed', 'vehicles', p_vehicle::text, jsonb_build_object('error', sqlerrm));
  end;
  return jsonb_build_object('filled', to_jsonb(v_filled), 'class', v_class, 'copy_queued', v_copy);
end $$;

-- An owner's car (the owner's application, a car staff add for an owner, Add a car for a program owner).
alter function app.add_owner_vehicle(uuid, jsonb, uuid, uuid) rename to add_owner_vehicle_pre0082;
create or replace function app.add_owner_vehicle(p_owner uuid, p_v jsonb, p_by uuid default null, p_application uuid default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb := app.add_owner_vehicle_pre0082(p_owner, p_v, p_by, p_application);
  v_staff boolean := p_by is not null and (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet'));
begin
  -- the class is staff's to choose; an owner's own application gets the inferred class
  return v_out || jsonb_build_object('after_add', app.vehicle_after_add((v_out ->> 'vehicle_id')::uuid, p_by,
    case when v_staff then coalesce(p_v, '{}'::jsonb) else coalesce(p_v, '{}'::jsonb) - 'class' - 'class_source' end));
end $$;

-- Add a car (Admin): CarmaCars-owned and partner cars are inserted here directly.
alter function app.vehicle_add_core(uuid, jsonb) rename to vehicle_add_core_pre0082;
create or replace function app.vehicle_add_core(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb := app.vehicle_add_core_pre0082(p_by, p);
begin
  if coalesce(p ->> 'supply_type', 'program_owner') = 'program_owner' then return v_out; end if;  -- done in add_owner_vehicle
  return v_out || jsonb_build_object('after_add', app.vehicle_after_add((v_out ->> 'vehicle_id')::uuid, p_by, p));
end $$;

-- ================================================================ 4. the colour from the cover photo
create table vehicle_colour_reads (
  vehicle_id  uuid primary key references vehicles (id) on delete cascade,
  photo_id    uuid references vehicle_photos (id) on delete set null,
  attempts    integer not null default 0,
  last_at     timestamptz,
  ok          boolean,
  colour      text,
  model       text,
  error       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create trigger vehicle_colour_reads_updated before update on vehicle_colour_reads for each row execute function app.set_updated_at();
comment on table vehicle_colour_reads is 'The colour read from a car''s cover photo by the vision model (0082): one row per car, the photo read, the answer. Tried again for a new cover photo, else at most 3 times an hour apart.';

-- The cover photo of a car, as an image the vision model can read: the smallest JPEG or PNG size of 400 pixels or
-- more, else the processed photo, else the original.
create or replace function app.vehicle_cover_image(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('photo_id', ph.id,
    'bucket', case when vv.path is not null or ph.processed_path is not null then 'vehicle-public' else 'vehicle-originals' end,
    'path', coalesce(vv.path, ph.processed_path, ph.original_path))
    from vehicle_photos ph
    left join lateral (select x ->> 'path' as path from jsonb_array_elements(case when jsonb_typeof(ph.variants) = 'array' then ph.variants else '[]'::jsonb end) x
                        where (x ->> 'format') in ('jpg', 'jpeg', 'png') and coalesce((x ->> 'width')::integer, 0) >= 400
                        order by (x ->> 'width')::integer limit 1) vv on true
   where ph.vehicle_id = p_vehicle and ph.replaced_at is null and ph.status <> 'rejected'
   order by ph.is_cover desc, (ph.angle in ('front', 'front_left', 'front_right', 'left', 'right')) desc, ph.is_public desc, ph.sort_order, ph.created_at
   limit 1
$$;

-- The cars whose colour is due to be read: real, not retired, no colour, none entered by a person, with a photo, not
-- read from this photo yet (or a failed read more than an hour ago, at most 3 times), while the vision model is on and
-- today's allowance has room. {allowed, reason, model, fallback_model, cars: [{vehicle_id, photo_id, bucket, path}]}
create or replace function app.colour_read_due(p_limit integer default 3) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b jsonb := app.ai_vision_budget();
begin
  if not coalesce((b ->> 'enabled')::boolean, false) then return jsonb_build_object('allowed', false, 'reason', 'The vision model is off in Program settings', 'cars', '[]'::jsonb); end if;
  if (b ->> 'all_used')::bigint >= (b ->> 'all_limit')::bigint then return jsonb_build_object('allowed', false, 'reason', 'Today''s allowance for the vision model is used up', 'cars', '[]'::jsonb); end if;
  return jsonb_build_object('allowed', true, 'model', b ->> 'model', 'fallback_model', b ->> 'fallback_model', 'cars', coalesce((
    select jsonb_agg(c.img || jsonb_build_object('vehicle_id', c.id)) from (
      select v.id, app.vehicle_cover_image(v.id) as img
        from vehicles v left join vehicle_colour_reads r on r.vehicle_id = v.id
       where not coalesce(v.is_sample, false) and v.retired_at is null and nullif(btrim(v.colour), '') is null
         and coalesce(v.spec_sources #>> '{colour,source}', '') <> 'person'
         and app.vehicle_cover_image(v.id) is not null
         and (r.vehicle_id is null or r.photo_id is distinct from (app.vehicle_cover_image(v.id) ->> 'photo_id')::uuid
              or (not coalesce(r.ok, false) and r.attempts < 3 and r.last_at < now() - interval '1 hour'))
       order by v.created_at desc limit greatest(coalesce(p_limit, 3), 0)) c), '[]'::jsonb));
end $$;

-- The vision model's answer for one car: p {vehicle_id, photo_id, ok, colour, model, neurons, error, duration_ms}. The
-- colour is set when it is one of the swatches, the car still has none and no person entered one.
create or replace function app.colour_read_record(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_vehicle uuid := (p ->> 'vehicle_id')::uuid;
  v_colour text := nullif(btrim(p ->> 'colour'), '');
  v_set boolean := false;
begin
  if v_colour is not null and v_colour not in ('Black', 'White', 'Grey', 'Silver', 'Blue', 'Red', 'Green', 'Brown', 'Beige', 'Gold', 'Orange', 'Yellow', 'Purple') then
    v_colour := null;
  end if;
  insert into provider_calls (provider, purpose, vehicle_id, ok, error, duration_ms, cost_microusd, units, unit)
  values (left(coalesce(p ->> 'model', 'workers-ai'), 120), 'colour_read', v_vehicle, coalesce((p ->> 'ok')::boolean, false), left(p ->> 'error', 500),
          greatest(coalesce((p ->> 'duration_ms')::integer, 0), 0), 0, greatest(coalesce((p ->> 'neurons')::integer, 0), 0), 'neurons');
  insert into vehicle_colour_reads (vehicle_id, photo_id, attempts, last_at, ok, colour, model, error)
  values (v_vehicle, nullif(p ->> 'photo_id', '')::uuid, 1, now(), v_colour is not null, v_colour, p ->> 'model', left(p ->> 'error', 500))
  on conflict (vehicle_id) do update set
    attempts = case when vehicle_colour_reads.photo_id is distinct from excluded.photo_id then 1 else vehicle_colour_reads.attempts + 1 end,
    photo_id = excluded.photo_id, last_at = now(), ok = excluded.ok, colour = excluded.colour, model = excluded.model, error = excluded.error;
  if v_colour is not null then
    update vehicles set colour = v_colour,
           spec_sources = coalesce(spec_sources, '{}'::jsonb) || jsonb_build_object('colour', jsonb_build_object('source', 'detected', 'model', p ->> 'model', 'photo_id', p ->> 'photo_id', 'at', now()))
     where id = v_vehicle and nullif(btrim(colour), '') is null and coalesce(spec_sources #>> '{colour,source}', '') <> 'person';
    v_set := found;
    if v_set then
      insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
      values (null, 'vehicle_colour_detected', 'vehicles', v_vehicle::text, jsonb_build_object('colour', v_colour, 'model', p ->> 'model'));
    end if;
  end if;
  return jsonb_build_object('vehicle_id', v_vehicle, 'colour', v_colour, 'set', v_set);
end $$;

-- ================================================================ 5. VINs decoded later, and the cars that wait for them
-- Real cars with a VIN and no decode that worked: decoded again by the listing worker's run, at most 5 times, 6 hours
-- apart. [{vin}]
create or replace function app.vin_decode_due(p_limit integer default 5) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('vin', x.vin)), '[]'::jsonb) from (
    select distinct upper(v.vin) as vin
      from vehicles v
     where v.vin is not null and not coalesce(v.is_sample, false) and v.retired_at is null
       and not exists (select 1 from vin_decodes d where d.vin = upper(v.vin) and d.ok)
       and (select count(*) from vin_decodes d where d.vin = upper(v.vin)) < 5
       and not exists (select 1 from vin_decodes d where d.vin = upper(v.vin) and d.decoded_at > now() - interval '6 hours')
     limit greatest(coalesce(p_limit, 5), 0)) x
$$;

-- A decode recorded for a VIN: every real car with it gets its missing details and, when nobody chose, its class.
create or replace function app.vin_decoded_apply(p_vin text) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  n integer := 0;
begin
  for r in select v.id from vehicles v where upper(v.vin) = app.clean_vin(p_vin) and not coalesce(v.is_sample, false) loop
    if cardinality(app.vin_fill_missing(r.id)) > 0 then n := n + 1; end if;
    if not (coalesce((select spec_sources from vehicles where id = r.id), '{}'::jsonb) ? 'class') then perform app.vehicle_infer_class(r.id); end if;
  end loop;
  return n;
end $$;

-- The Worker's cron gate (0076) calls the listing worker only when it has work: a VIN to decode again or a colour to
-- read is work too (the listing worker's run does both, web/src/server/car-details.ts).
alter function app.server_jobs_due() rename to server_jobs_due_pre0082;
create or replace function app.server_jobs_due() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb := app.server_jobs_due_pre0082();
  c jsonb;
begin
  if coalesce((v ->> 'listing')::boolean, false) then return v; end if;
  if jsonb_array_length(app.vin_decode_due(1)) > 0 then return v || jsonb_build_object('listing', true); end if;
  c := app.colour_read_due(1);
  if coalesce((c ->> 'allowed')::boolean, false) and jsonb_array_length(c -> 'cars') > 0 then return v || jsonb_build_object('listing', true); end if;
  return v;
end $$;

-- ================================================================ 6. the doors (the server's service role)
create or replace function public.server_vin_facts(p_vin text) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.vin_facts(p_vin) $$;
create or replace function public.server_vin_class_hint(p jsonb) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.vin_class_hint(p) $$;
create or replace function public.server_vin_decode_due(p_limit integer default 5) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.vin_decode_due(p_limit) $$;
create or replace function public.server_vin_decoded_apply(p_vin text) returns integer
language sql volatile security invoker set search_path = public, app as $$ select app.vin_decoded_apply(p_vin) $$;
create or replace function public.server_colour_read_due(p_limit integer default 3) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.colour_read_due(p_limit) $$;
create or replace function public.server_colour_read_record(p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.colour_read_record(p) $$;

-- A public photo whose shot type was never set (the column allows it) gave the template a null photo name, and
-- jsonb_build_object refused it: one such car stopped car_copy_scan and with it the whole server_jobs_due gate. Every
-- car now gets its copy queued at once, so the template skips nameless photos (release 2 integration).
alter function app.car_copy_template(jsonb) rename to car_copy_template_pre0082;
create or replace function app.car_copy_template(p_facts jsonb) returns jsonb
language sql immutable as $$
  select app.car_copy_template_pre0082(case when jsonb_typeof(p_facts -> 'photos') = 'array'
    then jsonb_set(p_facts, '{photos}', coalesce((select jsonb_agg(x) from jsonb_array_elements(p_facts -> 'photos') x where jsonb_typeof(x) = 'string'), '[]'::jsonb))
    else p_facts end)
$$;

-- ================================================================ privileges
alter table vehicle_class_rules enable row level security;
alter table vehicle_colour_reads enable row level security;
create policy admin_all on vehicle_class_rules for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy staff_read on vehicle_class_rules for select to authenticated using (app.is_staff());
create policy admin_all on vehicle_colour_reads for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on vehicle_class_rules, vehicle_colour_reads from anon, authenticated;
grant select on vehicle_class_rules to authenticated;
grant insert, update on vehicle_class_rules to authenticated;   -- admin_all decides who; a rule is turned off, never deleted
grant select on vehicle_colour_reads to authenticated;
grant all on vehicle_class_rules, vehicle_colour_reads to service_role;
create trigger audit_vehicle_class_rules after insert or update or delete on vehicle_class_rules for each row execute function app.audit_row();
create trigger audit_vehicle_colour_reads after insert or update or delete on vehicle_colour_reads for each row execute function app.audit_row();

do $$
declare
  f record;
  r record;
  v_new regprocedure;
  g text;
begin
  -- new functions: the service role only
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and p.proname = any (array['make_key', 'decode_trim', 'class_label', 'infer_vehicle_class', 'vin_decode_json', 'vin_class_hint', 'vin_facts', 'vin_fill_missing',
                     'vehicle_set_class', 'vehicle_infer_class', 'car_copy_queue', 'vehicle_after_add', 'vehicle_cover_image', 'colour_read_due', 'colour_read_record',
                     'vin_decode_due', 'vin_decoded_apply']))
               or (n.nspname = 'public' and p.proname = any (array['server_vin_facts', 'server_vin_class_hint', 'server_vin_decode_due', 'server_vin_decoded_apply',
                     'server_colour_read_due', 'server_colour_read_record']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
  -- the wrapped ones: the new function gets the privileges the old one had
  for r in select p.oid, m.new_name, oidvectortypes(p.proargtypes) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             join (values ('add_owner_vehicle_pre0082', 'add_owner_vehicle'), ('vehicle_add_core_pre0082', 'vehicle_add_core'), ('server_jobs_due_pre0082', 'server_jobs_due'),
                         ('car_copy_template_pre0082', 'car_copy_template')) m(old_name, new_name)
               on m.old_name = p.proname
            where n.nspname = 'app' loop
    v_new := format('app.%I(%s)', r.new_name, r.args)::regprocedure;
    execute format('revoke all on function %s from public, anon, authenticated', v_new);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;

-- ================================================================ 7. the real cars on file now
-- Every real car with a VIN gets the decoded details it is missing (nothing a person entered is touched); a program
-- owner's car added before this migration never had its class chosen (the owner's application and Add a car for an
-- owner had no class; Add a car dropped it for a program owner), so it gets the inferred class. CarmaCars-owned and
-- partner cars keep the class staff chose. The copy follows by itself: the search job's scan sees the new facts.
do $$
declare
  r record;
begin
  for r in select v.id, v.supply_type, v.spec_sources from vehicles v where not coalesce(v.is_sample, false) and v.vin is not null loop
    perform app.vin_fill_missing(r.id);
  end loop;
  for r in select v.id from vehicles v where not coalesce(v.is_sample, false) and v.supply_type = 'program_owner'
              and not (coalesce(v.spec_sources, '{}'::jsonb) ? 'class') loop
    perform app.vehicle_infer_class(r.id);
  end loop;
end $$;
