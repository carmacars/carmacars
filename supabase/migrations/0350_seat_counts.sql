-- 0350_seat_counts.sql
-- Seats from the VIN or a seat table, never a guess of 5 for an SUV (docs/changes/2026-11-06-seat-counts.md).
--
-- The owner, November 1, 2026: the GMC Yukon XL is an 8 seater, but "7+ seats" on /cars does not show it. Live, the
-- Yukon XL had no seats at all and the 2026 Hyundai Palisade SEL showed 5. Since 0094 a car whose decode gave no seat
-- count got "the usual number for the body", and app.body_default_seats answered 5 for every SUV and MPV: a 3-row SUV
-- or a minivan became a 5 seater (marked body_default, to confirm on Admin > Today), and a car added without a body got
-- nothing.
--
-- From now on the seats of a listing come from, in this order:
--   1. a person (Admin > Today "Confirm gearbox and seats", the listing review, a partner's sheet): never changed here;
--   2. the VIN decode's seat count, when it has one (2 to 9);
--   3. app.seat_counts: a maintained table by make, model and trim (3-row SUVs and minivans, with the captain's chair
--      trims at 7), source 'seat_table';
--   4. the body, only where it cannot be wrong: 4 for a coupe or convertible, 5 for a sedan, hatchback or wagon;
--   5. otherwise empty: never 5 for an SUV, a crossover or an MPV. The car shows "Seats missing" in Admin > Cars, its
--      publish gates say "Details not shown: seats", and Admin > Today asks to confirm them.
-- It runs when a listing is made, when a car's make, model, trim, body or VIN changes, and after every VIN fill. The
-- backfill below corrects every car whose seats are empty or came from the body default, and records each change in
-- the audit log (action seats_backfill_0350). The fleet filter, the JSON-LD and the car page all read the listing's
-- seats (vehicle_listings.seats, the public row's "seats"), so one value is shown everywhere.

-- ================================================================ 1. the seat table
create table if not exists app.seat_counts (
  id serial primary key,
  make text not null,          -- app.slugify of the make: 'gmc', 'mercedes-benz'
  model text not null,         -- app.slugify of the model: 'yukon-xl'; also matches a longer model ('palisade-sel')
  trim_pattern text,           -- a case-insensitive regular expression on the trim (null: any trim)
  seats smallint not null check (seats between 2 and 9),
  note text
);
comment on table app.seat_counts is
  'Seats by make, model and trim (0350), used when the VIN decode gives none. A row with a trim pattern wins over the row without. Maintained here; add a model with a migration.';
revoke all on app.seat_counts from public, anon, authenticated;

insert into app.seat_counts (make, model, trim_pattern, seats, note) values
  -- GM full-size: 8 with the bench, 7 with second-row captain's chairs
  ('gmc', 'yukon', 'denali|captain', 7, 'Denali: captain''s chairs'), ('gmc', 'yukon', null, 8, null),
  ('gmc', 'yukon-xl', 'denali|captain', 7, 'Denali: captain''s chairs'), ('gmc', 'yukon-xl', null, 8, null),
  ('chevrolet', 'tahoe', 'premier|high country|captain', 7, null), ('chevrolet', 'tahoe', null, 8, null),
  ('chevrolet', 'suburban', 'premier|high country|captain', 7, null), ('chevrolet', 'suburban', null, 8, null),
  ('chevrolet', 'traverse', 'premier|high country|rs|z71|captain', 7, null), ('chevrolet', 'traverse', null, 8, null),
  ('cadillac', 'escalade', null, 7, null), ('cadillac', 'escalade-esv', null, 7, null), ('cadillac', 'xt6', null, 7, null),
  ('buick', 'enclave', 'avenir|premium|captain', 7, null), ('buick', 'enclave', null, 8, null),
  ('gmc', 'acadia', null, 7, null),
  -- Hyundai, Kia, Genesis
  ('hyundai', 'palisade', 'calligraphy|limited|ultimate|captain', 7, 'captain''s chairs'), ('hyundai', 'palisade', null, 8, null),
  ('hyundai', 'ioniq-9', null, 7, null),
  ('kia', 'telluride', 'sx|x-pro|prestige|captain', 7, 'captain''s chairs'), ('kia', 'telluride', null, 8, null),
  ('kia', 'carnival', 'sx-prestige|sxl|prestige|captain', 7, null), ('kia', 'carnival', null, 8, null),
  ('kia', 'sedona', null, 8, null), ('kia', 'sorento', null, 7, null), ('kia', 'ev9', null, 7, null),
  ('genesis', 'gv80', '3-row|third', 7, null),
  -- Toyota, Lexus
  ('toyota', 'highlander', 'limited|platinum|captain', 7, null), ('toyota', 'highlander', null, 8, null),
  ('toyota', 'grand-highlander', 'limited|platinum|captain', 7, null), ('toyota', 'grand-highlander', null, 8, null),
  ('toyota', 'sequoia', 'platinum|capstone|captain', 7, null), ('toyota', 'sequoia', null, 8, null),
  ('toyota', 'sienna', 'xse|limited|platinum|woodland|captain', 7, null), ('toyota', 'sienna', null, 8, null),
  ('lexus', 'gx', null, 7, null), ('lexus', 'lx', null, 8, null), ('lexus', 'tx', null, 7, null),
  -- Honda, Acura
  ('honda', 'pilot', 'elite|black edition|trailsport|captain', 7, null), ('honda', 'pilot', null, 8, null),
  ('honda', 'odyssey', 'elite|black edition|captain', 7, null), ('honda', 'odyssey', null, 8, null),
  ('acura', 'mdx', null, 7, null),
  -- Volkswagen, Audi
  ('volkswagen', 'atlas', 'captain', 6, null), ('volkswagen', 'atlas', null, 7, null),
  ('audi', 'q7', null, 7, null),
  -- Ford, Lincoln
  ('ford', 'explorer', 'captain', 6, null), ('ford', 'explorer', null, 7, null),
  ('ford', 'expedition', 'platinum|king ranch|captain', 7, null), ('ford', 'expedition', null, 8, null),
  ('ford', 'expedition-max', 'platinum|king ranch|captain', 7, null), ('ford', 'expedition-max', null, 8, null),
  ('lincoln', 'navigator', null, 7, null), ('lincoln', 'navigator-l', null, 7, null), ('lincoln', 'aviator', null, 7, null),
  -- Stellantis
  ('chrysler', 'pacifica', null, 7, null), ('chrysler', 'voyager', null, 7, null), ('chrysler', 'grand-caravan', null, 7, null),
  ('dodge', 'grand-caravan', null, 7, null), ('dodge', 'durango', null, 7, null),
  ('jeep', 'grand-cherokee-l', null, 7, null), ('jeep', 'wagoneer', 'captain', 7, null), ('jeep', 'wagoneer', null, 8, null),
  ('jeep', 'grand-wagoneer', 'captain', 7, null), ('jeep', 'grand-wagoneer', null, 8, null),
  -- German luxury
  ('mercedes-benz', 'gls', null, 7, null), ('mercedes-benz', 'gls-class', null, 7, null), ('mercedes-benz', 'eqs-suv', null, 7, null),
  ('bmw', 'x7', null, 7, null),
  -- Nissan, Infiniti, Mazda, Subaru, Mitsubishi, Volvo, Rivian
  ('nissan', 'pathfinder', 'platinum|captain', 7, null), ('nissan', 'pathfinder', null, 8, null),
  ('nissan', 'armada', 'platinum|captain', 7, null), ('nissan', 'armada', null, 8, null),
  ('infiniti', 'qx80', 'captain', 7, null), ('infiniti', 'qx80', null, 8, null), ('infiniti', 'qx60', null, 7, null),
  ('mazda', 'cx-90', 'captain|signature', 7, null), ('mazda', 'cx-90', null, 8, null),
  ('subaru', 'ascent', 'limited|touring|premier|onyx|captain', 7, null), ('subaru', 'ascent', null, 8, null),
  ('mitsubishi', 'outlander', null, 7, null),
  ('volvo', 'xc90', null, 7, null), ('volvo', 'ex90', null, 7, null),
  ('rivian', 'r1s', null, 7, null),
  ('tesla', 'model-x', null, 7, null)
on conflict do nothing;

-- The seats of a make, model and trim from the table (null: not in it). An exact model wins over a model that starts
-- with the table's (a 'palisade-sel' is a Palisade), a trim row over the row for every trim.
create or replace function app.seat_count_for(p_make text, p_model text, p_trim text) returns smallint
language sql stable security definer set search_path = public, app as $$
  select s.seats from app.seat_counts s
   where s.make = app.slugify(coalesce(p_make, ''))
     and (s.model = app.slugify(coalesce(p_model, '')) or app.slugify(coalesce(p_model, '')) like s.model || '-%')
     and (s.trim_pattern is null or (coalesce(p_trim, '') || ' ' || coalesce(p_model, '')) ~* s.trim_pattern)
   order by (s.model = app.slugify(coalesce(p_model, ''))) desc, length(s.model) desc, (s.trim_pattern is null), s.id
   limit 1
$$;

-- ================================================================ 2. the body default: only where it cannot be wrong
-- Was (0094): 5 for an SUV, a crossover and an MPV too. A 3-row SUV or a minivan is 7 or 8, so those get nothing.
create or replace function app.body_default_seats(p text) returns integer
language sql immutable as $$
  select case when p is null then null
              when p ~* 'suv|sport utility|crossover|mpv|multi.?purpose|van|truck|pickup' then null
              when p ~* 'convertible|cabrio|coupe|roadster' then 4
              when p ~* 'sedan|saloon|hatch|wagon|liftback|notchback' then 5 end
$$;

-- ================================================================ 3. the seats of one car
-- The value the car should have and where it comes from: {seats, source} (seats null: nobody knows).
create or replace function app.seats_guess(p_vehicle uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
  d vin_decodes;
  l vehicle_listings;
  n integer;
begin
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then return null; end if;
  if v.vin is not null then
    select * into d from vin_decodes z where z.vin = upper(v.vin) and z.ok order by z.decoded_at desc limit 1;
    if d.seats between 2 and 9 then return jsonb_build_object('seats', d.seats, 'source', 'decoded', 'decode_id', d.id); end if;
  end if;
  n := app.seat_count_for(v.make, v.model, v.trim);
  if n is not null then return jsonb_build_object('seats', n, 'source', 'seat_table'); end if;
  select * into l from vehicle_listings where vehicle_id = p_vehicle;
  n := app.body_default_seats(coalesce(nullif(btrim(v.body_type), ''), d.body_class, l.body_style));
  if n is not null then return jsonb_build_object('seats', n, 'source', 'body_default'); end if;
  return jsonb_build_object('seats', null, 'source', null);
end $$;

-- Sets the listing's seats from app.seats_guess when they are empty or came from a guess (body_default, seat_table, or
-- an older decode). A person's value, a partner sheet's and any value of unknown origin are never changed. Returns
-- {vehicle_id, from, to, source} when it changed them, else null.
create or replace function app.seats_refresh(p_vehicle uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  l vehicle_listings;
  src text;
  g jsonb;
  n integer;
begin
  select * into l from vehicle_listings where vehicle_id = p_vehicle;
  if l.id is null then return null; end if;
  if exists (select 1 from vehicles v where v.id = p_vehicle and coalesce(v.is_sample, false)) then return null; end if;
  src := case when jsonb_typeof(l.spec_sources -> 'seats') = 'object' then l.spec_sources #>> '{seats,source}'
              when l.spec_sources ? 'seats' then 'other' end;
  if l.seats is not null and coalesce(src, 'unknown') not in ('body_default', 'seat_table', 'decoded') then return null; end if;
  g := app.seats_guess(p_vehicle);
  n := (g ->> 'seats')::integer;
  -- the body's 5 for an SUV or a minivan (0094) was a guess the body no longer makes: empty, to be confirmed
  if n is null then
    if l.seats is null or src is distinct from 'body_default' then return null; end if;
    update vehicle_listings set seats = null, spec_sources = spec_sources - 'seats' where id = l.id;
    return jsonb_build_object('vehicle_id', p_vehicle, 'from', l.seats, 'to', null, 'source', null);
  end if;
  if n = l.seats and src is not distinct from (g ->> 'source') then return null; end if;
  -- a decoded value stays unless the decode now says otherwise (it never gives way to the table or the body)
  if src = 'decoded' and g ->> 'source' <> 'decoded' then return null; end if;
  update vehicle_listings set seats = n,
         spec_sources = coalesce(spec_sources, '{}'::jsonb) || jsonb_build_object('seats', (g - 'seats') || jsonb_build_object('at', now()))
   where id = l.id;
  return jsonb_build_object('vehicle_id', p_vehicle, 'from', l.seats, 'to', n, 'source', g ->> 'source');
end $$;
revoke all on function app.seat_count_for(text, text, text), app.seats_guess(uuid), app.seats_refresh(uuid) from public, anon, authenticated;
grant execute on function app.seat_count_for(text, text, text), app.seats_guess(uuid), app.seats_refresh(uuid) to service_role;

-- after each VIN fill (0082, 0094): the table and the right body default
alter function app.vin_fill_missing(uuid) rename to vin_fill_missing_pre0350;
create or replace function app.vin_fill_missing(p_vehicle uuid) returns text[]
language plpgsql security definer set search_path = public, app as $$
declare v_out text[] := app.vin_fill_missing_pre0350(p_vehicle);
begin
  if app.seats_refresh(p_vehicle) is not null and not ('seats' = any (v_out)) then v_out := v_out || 'seats'::text; end if;
  return v_out;
end $$;

-- a new listing, and a car whose make, model, trim, body or VIN changed
create or replace function app.seats_on_listing() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.seats_refresh(new.vehicle_id);
  return null;
end $$;
drop trigger if exists seats_on_listing on vehicle_listings;
create trigger seats_on_listing after insert on vehicle_listings for each row execute function app.seats_on_listing();

create or replace function app.seats_on_vehicle() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.seats_refresh(new.id);
  return null;
end $$;
drop trigger if exists seats_on_vehicle on vehicles;
create trigger seats_on_vehicle after update of make, model, trim, body_type, vin on vehicles for each row
  when ((old.make, old.model, old.trim, old.body_type, old.vin) is distinct from (new.make, new.model, new.trim, new.body_type, new.vin))
  execute function app.seats_on_vehicle();

-- ================================================================ 4. "Seats missing" in Admin > Cars
alter function app.admin_read(uuid, text, jsonb) rename to admin_read_0046;
create or replace function app.admin_read(p_admin uuid, p_what text, p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb := app.admin_read_0046(p_admin, p_what, p);
begin
  if p_what = 'vehicles' and jsonb_typeof(v_out) = 'array' then
    return (select coalesce(jsonb_agg(x || jsonb_build_object('seats', l.seats, 'seats_missing', not coalesce(v.is_sample, false) and l.seats is null)
              order by ordinality), '[]'::jsonb)
              from jsonb_array_elements(v_out) with ordinality e(x, ordinality)
              join vehicles v on v.id = (e.x ->> 'id')::uuid left join vehicle_listings l on l.vehicle_id = v.id);
  end if;
  return v_out;
end $$;
revoke all on function app.admin_read(uuid, text, jsonb) from public, anon, authenticated;
grant execute on function app.admin_read(uuid, text, jsonb) to service_role;

-- ================================================================ 5. the backfill: every car whose seats were a guess or empty
do $$
declare
  r record;
  c jsonb;
  changed integer := 0;
  lines text[] := '{}';
begin
  for r in select v.id from vehicles v join vehicle_listings l on l.vehicle_id = v.id
            where not coalesce(v.is_sample, false) order by v.created_at loop
    c := app.seats_refresh(r.id);
    if c is not null then
      changed := changed + 1;
      lines := lines || format('%s: %s to %s (%s)', app.vehicle_name(r.id), coalesce(c ->> 'from', 'empty'), c ->> 'to', c ->> 'source');
      insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
      values (null, 'seats_backfill_0350', 'vehicles', r.id::text, jsonb_build_object('seats', c -> 'from'), jsonb_build_object('seats', c -> 'to', 'source', c ->> 'source'));
    end if;
  end loop;
  raise notice 'seats 0350: % cars changed%', changed, case when changed > 0 then ': ' || array_to_string(lines, '; ') else '' end;
end $$;

-- the server may run every function here (suite 06), nobody else
revoke all on function app.seats_on_listing(), app.seats_on_vehicle(), app.vin_fill_missing(uuid), app.body_default_seats(text) from public, anon, authenticated;
grant execute on function app.seats_on_listing(), app.seats_on_vehicle(), app.vin_fill_missing(uuid), app.body_default_seats(text) to service_role;
