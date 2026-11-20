-- 3151 (release 48, part AN): one make, one model family and one body per car, everywhere (the filters, facets, pages).
-- The owner (Nov 20, urgent): the car filters split models ("CLA 250" and "CLA-Class" and similar). Every car normalised to
-- its canonical make, model family (Mercedes-Benz CLA-Class) and trim (CLA250 4MATIC); filters and facets group by family,
-- the trim is a detail; every make, model, body and year value audited for the same problem (BMW 3 Series vs 330i ...).
-- 0520 (app.car_model_family) already maps Mercedes-Benz and BMW model codes to their family on every save. Left over:
--   a. makes written several ways (Mercedes, Mercedes Benz, MB, Chevy, VW, Rolls Royce, Landrover);
--   b. other makes: the trim typed into the model ("Range Rover Sport V6", "Escalade ESV", "911 Turbo S", "Macan S");
--   c. trims written several ways: "CLA250-4M" and "CLA250 4MATIC", "228i xDrive GC", "Sle", "AMG GT C" under AMG GT;
--   d. bodies: "Compact SUV", "Mid-size SUV" and "SUV"; "Mid-size sedan" and "Sedan"; "Four-door coupe" and "Coupe";
--   e. the /cars filter listed every trim as its own option under the family (web: features/fleet/FleetBrowser.tsx).
-- 1. Reference tables car_make_names (every spelling of a make -> the make) and car_model_families (make, family, aliases),
--    seeded with the fleet's makes and the common ones; an Admin adds a family with one insert.
-- 2. app.car_identity(make, model, trim) -> {make, model (the family), trim, known}: the make by its name table; Mercedes-Benz
--    and BMW by 0520's rule; other makes by the longest family the model starts with (the rest of the model goes to the trim);
--    then the trim cleaned (4M -> 4MATIC, GC -> Gran Coupe, trim codes in capitals, the family not repeated). A model it
--    cannot read with certainty is left as typed (known false: Data health lists it).
-- 3. app.car_body(text): Sedan, Coupe, Convertible, SUV, Hatchback, Wagon, Minivan, Pickup truck, Van (or the value as typed).
-- 4. Triggers: vehicles (make, model, trim) and the listing's body (0073's app.listing_norm_body, widened) on every save; then
--    every car on file normalised now (audit log, the listing copy and cache refreshed, the public address unchanged).
-- 5. Data health: a year outside 1980 .. next year + 1 and a model family not recognised are listed.
-- Same rule in the web: web/src/features/vin/car-identity.ts (portable, no imports outside its folder).
-- SCHEMA_MARKER 3151. docs/changes/2026-11-20-r48-motion-covers-filters.md.
set local check_function_bodies = off;

-- ================================================================ 1. the reference tables
create table if not exists car_make_names (
  key  text primary key check (key ~ '^[A-Z0-9]{1,40}$'),
  make text not null check (btrim(make) <> '')
);
comment on table car_make_names is 'Release 48 AN (3151): every spelling of a make (upper case, letters and digits only) and the make as we write it.';
create table if not exists car_model_families (
  make    text not null,
  family  text not null,
  aliases text[] not null default '{}',
  primary key (make, family)
);
comment on table car_model_families is 'Release 48 AN (3151): the model families of each make (the filters group by them); aliases are other spellings of the family. Mercedes-Benz and BMW are also read by their model codes (0520).';
alter table car_make_names enable row level security;
alter table car_model_families enable row level security;
create policy read_all on car_make_names for select to anon, authenticated using (true);
create policy read_all on car_model_families for select to anon, authenticated using (true);
revoke all on table car_make_names, car_model_families from public, anon, authenticated;
grant select on table car_make_names, car_model_families to anon, authenticated;
grant select, insert, update, delete on table car_make_names, car_model_families to service_role;
create trigger audit_car_make_names after insert or update or delete on car_make_names for each row execute function app.audit_row();
create trigger audit_car_model_families after insert or update or delete on car_model_families for each row execute function app.audit_row();

create function app.car_key(p text) returns text language sql immutable parallel safe as $$
  select regexp_replace(upper(coalesce(p, '')), '[^A-Z0-9]+', '', 'g')
$$;

insert into car_make_names (key, make)
select app.car_key(a), m from (values
  ('Mercedes-Benz', 'Mercedes-Benz'), ('Mercedes', 'Mercedes-Benz'), ('Benz', 'Mercedes-Benz'), ('MB', 'Mercedes-Benz'), ('Mercedes-AMG', 'Mercedes-Benz'),
  ('Mercedes AMG', 'Mercedes-Benz'), ('Merce', 'Mercedes-Benz'), ('Mercedes-Maybach', 'Mercedes-Benz'),
  ('BMW', 'BMW'), ('Audi', 'Audi'), ('Land Rover', 'Land Rover'), ('Range Rover', 'Land Rover'), ('Rolls-Royce', 'Rolls-Royce'), ('McLaren', 'McLaren'),
  ('GMC', 'GMC'), ('Volkswagen', 'Volkswagen'), ('VW', 'Volkswagen'), ('Chevrolet', 'Chevrolet'), ('Chevy', 'Chevrolet'), ('MINI', 'MINI'), ('Kia', 'Kia'),
  ('Hyundai', 'Hyundai'), ('Toyota', 'Toyota'), ('Honda', 'Honda'), ('Ford', 'Ford'), ('Tesla', 'Tesla'), ('Porsche', 'Porsche'), ('Ferrari', 'Ferrari'),
  ('Lamborghini', 'Lamborghini'), ('Bentley', 'Bentley'), ('Maserati', 'Maserati'), ('Cadillac', 'Cadillac'), ('Lincoln', 'Lincoln'), ('Infiniti', 'Infiniti'),
  ('Lexus', 'Lexus'), ('Acura', 'Acura'), ('Nissan', 'Nissan'), ('Mazda', 'Mazda'), ('Jeep', 'Jeep'), ('Dodge', 'Dodge'), ('Ram', 'Ram'), ('Chrysler', 'Chrysler'),
  ('Mitsubishi', 'Mitsubishi'), ('Subaru', 'Subaru'), ('Volvo', 'Volvo'), ('Genesis', 'Genesis'), ('Jaguar', 'Jaguar'), ('Alfa Romeo', 'Alfa Romeo'),
  ('Aston Martin', 'Aston Martin'), ('Buick', 'Buick'), ('Polestar', 'Polestar'), ('Rivian', 'Rivian'), ('FIAT', 'FIAT')) x(a, m)
on conflict (key) do nothing;

insert into car_model_families (make, family, aliases)
select m, f, coalesce(al, '{}') from (values
  ('Audi', 'A3', null::text[]), ('Audi', 'A4', null), ('Audi', 'A5', array['A5 Sportback']), ('Audi', 'A6', null), ('Audi', 'A7', null), ('Audi', 'A8', null),
  ('Audi', 'Q3', null), ('Audi', 'Q4 e-tron', null), ('Audi', 'Q5', null), ('Audi', 'Q7', null), ('Audi', 'Q8', null), ('Audi', 'R8', null), ('Audi', 'S3', null),
  ('Audi', 'S4', null), ('Audi', 'S5', null), ('Audi', 'S6', null), ('Audi', 'S7', null), ('Audi', 'S8', null), ('Audi', 'RS 5', null), ('Audi', 'RS 7', null),
  ('Audi', 'e-tron', null), ('Audi', 'TT', null),
  ('Land Rover', 'Range Rover', null), ('Land Rover', 'Range Rover Sport', null), ('Land Rover', 'Range Rover Velar', array['Velar']),
  ('Land Rover', 'Range Rover Evoque', array['Evoque']), ('Land Rover', 'Defender', null), ('Land Rover', 'Discovery', null), ('Land Rover', 'Discovery Sport', null),
  ('Porsche', '911', null), ('Porsche', '718 Boxster', array['Boxster']), ('Porsche', '718 Cayman', array['Cayman']), ('Porsche', 'Cayenne', null),
  ('Porsche', 'Macan', null), ('Porsche', 'Panamera', null), ('Porsche', 'Taycan', null),
  ('Cadillac', 'Escalade', null), ('Cadillac', 'CT4', null), ('Cadillac', 'CT5', null), ('Cadillac', 'CTS', null), ('Cadillac', 'XT4', null), ('Cadillac', 'XT5', null),
  ('Cadillac', 'XT6', null), ('Cadillac', 'Lyriq', null),
  ('Chevrolet', 'Corvette', null), ('Chevrolet', 'Suburban', null), ('Chevrolet', 'Tahoe', null), ('Chevrolet', 'Malibu', null), ('Chevrolet', 'Equinox', null),
  ('Chevrolet', 'Silverado 1500', array['Silverado']), ('Chevrolet', 'Camaro', null), ('Chevrolet', 'Traverse', null), ('Chevrolet', 'Trax', null), ('Chevrolet', 'Blazer', null),
  ('Ferrari', '488', null), ('Ferrari', 'California', null), ('Ferrari', 'F8 Tributo', array['F8']), ('Ferrari', 'Roma', null), ('Ferrari', 'Portofino', null),
  ('Ferrari', 'SF90 Stradale', array['SF90']), ('Ferrari', '296 GTB', array['296']), ('Ferrari', '812 Superfast', array['812']),
  ('Lamborghini', 'Urus', null), ('Lamborghini', 'Huracan', array['Huracán']), ('Lamborghini', 'Aventador', null), ('Lamborghini', 'Revuelto', null),
  ('Ford', 'Mustang', null), ('Ford', 'F-150', null), ('Ford', 'Explorer', null), ('Ford', 'Escape', null), ('Ford', 'Bronco', null), ('Ford', 'Bronco Sport', null),
  ('Ford', 'Edge', null), ('Ford', 'Expedition', null), ('Ford', 'Transit', null), ('Ford', 'Maverick', null),
  ('GMC', 'Yukon', null), ('GMC', 'Yukon XL', null), ('GMC', 'Sierra 1500', array['Sierra']), ('GMC', 'Acadia', null), ('GMC', 'Terrain', null),
  ('Honda', 'Civic', null), ('Honda', 'Accord', null), ('Honda', 'CR-V', null), ('Honda', 'HR-V', null), ('Honda', 'Pilot', null), ('Honda', 'Odyssey', null),
  ('Hyundai', 'Elantra', null), ('Hyundai', 'Sonata', null), ('Hyundai', 'Tucson', null), ('Hyundai', 'Santa Fe', null), ('Hyundai', 'Palisade', null),
  ('Hyundai', 'Kona', null), ('Hyundai', 'Ioniq 5', null), ('Hyundai', 'Venue', null),
  ('Kia', 'Forte', null), ('Kia', 'K5', null), ('Kia', 'Sportage', null), ('Kia', 'Sorento', null), ('Kia', 'Telluride', null), ('Kia', 'Carnival', null),
  ('Kia', 'Soul', null), ('Kia', 'Seltos', null), ('Kia', 'EV6', null), ('Kia', 'Niro', null),
  ('Toyota', 'Camry', null), ('Toyota', 'Corolla', null), ('Toyota', 'RAV4', null), ('Toyota', 'Highlander', null), ('Toyota', 'Sienna', null),
  ('Toyota', 'Tacoma', null), ('Toyota', 'Tundra', null), ('Toyota', '4Runner', null), ('Toyota', 'Prius', null), ('Toyota', 'Corolla Cross', null),
  ('Volkswagen', 'Jetta', null), ('Volkswagen', 'Golf', null), ('Volkswagen', 'Passat', null), ('Volkswagen', 'Tiguan', null), ('Volkswagen', 'Atlas', null),
  ('Volkswagen', 'Beetle', null), ('Volkswagen', 'Taos', null), ('Volkswagen', 'ID.4', null),
  ('Tesla', 'Model 3', null), ('Tesla', 'Model Y', null), ('Tesla', 'Model S', null), ('Tesla', 'Model X', null), ('Tesla', 'Cybertruck', null),
  ('Mazda', 'MX-5', array['Miata', 'MX-5 Miata']), ('Mazda', 'Mazda3', array['3']), ('Mazda', 'CX-5', null), ('Mazda', 'CX-30', null), ('Mazda', 'CX-50', null),
  ('Mazda', 'CX-9', null), ('Mazda', 'CX-90', null),
  ('Mitsubishi', 'Outlander', null), ('Mitsubishi', 'RVR', null), ('Mitsubishi', 'Eclipse Cross', null),
  ('Jeep', 'Wrangler', null), ('Jeep', 'Grand Cherokee', null), ('Jeep', 'Cherokee', null), ('Jeep', 'Compass', null), ('Jeep', 'Patriot', null),
  ('Chrysler', 'Pacifica', null), ('Chrysler', '300', null), ('Dodge', 'Charger', null), ('Dodge', 'Challenger', null), ('Dodge', 'Durango', null),
  ('Dodge', 'Grand Caravan', null), ('Ram', '1500', null),
  ('Lincoln', 'Navigator', null), ('Lincoln', 'Aviator', null), ('Lincoln', 'Corsair', null), ('Lincoln', 'Nautilus', null),
  ('Infiniti', 'Q50', null), ('Infiniti', 'Q60', null), ('Infiniti', 'QX50', null), ('Infiniti', 'QX55', null), ('Infiniti', 'QX60', null), ('Infiniti', 'QX80', null),
  ('Maserati', 'Levante', null), ('Maserati', 'Ghibli', null), ('Maserati', 'Quattroporte', null), ('Maserati', 'Grecale', null), ('Maserati', 'MC20', null),
  ('Bentley', 'Bentayga', null), ('Bentley', 'Continental GT', array['Continental']), ('Bentley', 'Flying Spur', null),
  ('Rolls-Royce', 'Ghost', null), ('Rolls-Royce', 'Cullinan', null), ('Rolls-Royce', 'Phantom', null), ('Rolls-Royce', 'Wraith', null), ('Rolls-Royce', 'Dawn', null),
  ('Rolls-Royce', 'Spectre', null),
  ('McLaren', '570S', null), ('McLaren', '600LT', null), ('McLaren', '720S', null), ('McLaren', '750S', null), ('McLaren', 'Artura', null), ('McLaren', 'GT', null),
  ('Nissan', 'Altima', null), ('Nissan', 'Sentra', null), ('Nissan', 'Rogue', null), ('Nissan', 'Pathfinder', null), ('Nissan', 'Murano', null), ('Nissan', 'Kicks', null),
  ('Lexus', 'RX', null), ('Lexus', 'NX', null), ('Lexus', 'ES', null), ('Lexus', 'IS', null), ('Lexus', 'GX', null), ('Lexus', 'LX', null),
  ('Acura', 'MDX', null), ('Acura', 'RDX', null), ('Acura', 'TLX', null), ('Acura', 'Integra', null),
  ('Genesis', 'G70', null), ('Genesis', 'G80', null), ('Genesis', 'G90', null), ('Genesis', 'GV70', null), ('Genesis', 'GV80', null),
  ('Volvo', 'XC40', null), ('Volvo', 'XC60', null), ('Volvo', 'XC90', null), ('Volvo', 'S60', null), ('Volvo', 'S90', null),
  ('Subaru', 'Outback', null), ('Subaru', 'Forester', null), ('Subaru', 'Crosstrek', null), ('Subaru', 'WRX', null), ('Subaru', 'Impreza', null),
  ('Jaguar', 'F-Pace', null), ('Jaguar', 'F-Type', null), ('Jaguar', 'E-Pace', null), ('Jaguar', 'XF', null),
  ('Aston Martin', 'DB11', null), ('Aston Martin', 'DBX', null), ('Aston Martin', 'Vantage', null),
  ('MINI', 'Cooper', null), ('MINI', 'Countryman', null), ('Buick', 'Enclave', null), ('Buick', 'Encore', null), ('Polestar', '2', null), ('Rivian', 'R1S', null)
) x(m, f, al)
on conflict (make, family) do nothing;

-- ================================================================ 2. the rule
create function app.car_make(p text) returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce((select n.make from car_make_names n where n.key = app.car_key(p)), nullif(btrim(regexp_replace(coalesce(p, ''), '\s+', ' ', 'g')), ''), p)
$$;

-- the trim as one spelling: 4M -> 4MATIC, GC -> Gran Coupe, trim codes in capitals, the family not repeated, each word once
create function app.car_trim_clean(p_make text, p_family text, p_trim text) returns text
language plpgsql immutable as $$
declare
  t text := btrim(regexp_replace(coalesce(p_trim, ''), '\s+', ' ', 'g'));
  codes constant text[] := array['SLE', 'SLT', 'SEL', 'SE', 'LE', 'XLE', 'XSE', 'LX', 'EX', 'EX-L', 'LT', 'LS', 'LTZ', 'XLT', 'AWD', 'FWD', 'RWD', '4WD',
    'ESV', 'HSE', 'SV', 'SR5', 'TRD', 'GTS', 'GT', 'RS', 'GS-P', 'GS', 'GX', 'GXL', 'SXT', 'RT', 'R/T', 'SRT', 'AT4', 'XL', 'ST', 'SR', 'SL', 'S'];
  w text; out text[] := '{}';
begin
  if t = '' then return null; end if;
  -- Mercedes-Benz: "CLA250-4M", "C300 4M" -> 4MATIC
  t := regexp_replace(t, '(\d)-4M(\+?)(?=\s|$)', '\1 4MATIC\2', 'gi');
  t := regexp_replace(t, '(^|\s)4M(\+?)(\s|$)', '\14MATIC\2\3', 'gi');
  -- BMW: "228i xDrive GC" -> Gran Coupe
  if upper(coalesce(p_make, '')) = 'BMW' then t := regexp_replace(t, '(^|\s)GC(\s|$)', '\1Gran Coupe\2', 'g'); end if;
  -- the family repeated at the start ("AMG GT C" under AMG GT keeps "GT C")
  if p_family is not null and app.car_key(left(t, length(p_family))) = app.car_key(p_family) and length(t) > length(p_family)
     and substr(t, length(p_family) + 1, 1) = ' ' then
    t := btrim(case when p_family = 'AMG GT' then 'GT' || substr(t, length(p_family) + 1) else substr(t, length(p_family) + 1) end);
  end if;
  foreach w in array regexp_split_to_array(t, ' ') loop
    continue when w = '';
    out := out || case when upper(w) = any (codes) and w <> upper(w) and w !~ '[0-9]' and length(w) <= 4 then upper(w) else w end;
  end loop;
  return app.mf_join(out);
end $$;

create function app.car_identity(p_make text, p_model text, p_trim text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  mk text := app.car_make(p_make);
  mo text := btrim(regexp_replace(coalesce(p_model, ''), '\s+', ' ', 'g'));
  tr text := nullif(btrim(regexp_replace(coalesce(p_trim, ''), '\s+', ' ', 'g')), '');
  f jsonb; w text[]; k integer; head text; fam text; rest text; has_families boolean;
begin
  if mo = '' then return jsonb_build_object('make', mk, 'model', p_model, 'trim', p_trim, 'known', null); end if;
  if mk in ('Mercedes-Benz', 'BMW') then
    f := app.car_model_family(mk, mo, tr);
    -- a family typed with the trim after it ("CLA-Class CLA250", "3 Series 330i"): the family, the rest to the trim
    if not coalesce((f ->> 'known')::boolean, false) then
      w := regexp_split_to_array(mo, ' ');
      for k in reverse coalesce(array_length(w, 1), 1) - 1 .. 1 loop
        head := array_to_string(w[1:k], ' ');
        -- only a family name itself (no code: "C 300 something" stays as typed, as 0520 wants)
        if coalesce((app.car_model_family(mk, head, null) ->> 'known')::boolean, false) and app.car_model_family(mk, head, null) ->> 'trim' is null then
          f := app.car_model_family(mk, head, concat_ws(' ', array_to_string(w[k + 1:], ' '), tr));
          exit;
        end if;
      end loop;
    end if;
    return jsonb_build_object('make', mk, 'model', f ->> 'model', 'trim', app.car_trim_clean(mk, f ->> 'model', f ->> 'trim'), 'known', (f ->> 'known')::boolean);
  end if;
  has_families := exists (select 1 from car_model_families m where m.make = mk);
  w := regexp_split_to_array(mo, ' ');
  -- the longest family (or its other spelling) the model starts with
  for k in reverse array_length(w, 1) .. 1 loop
    head := app.car_key(array_to_string(w[1:k], ' '));
    select m.family into fam from car_model_families m
     where m.make = mk and (app.car_key(m.family) = head or exists (select 1 from unnest(m.aliases) a where app.car_key(a) = head))
     order by length(m.family) desc limit 1;
    if fam is not null then
      rest := nullif(array_to_string(w[k + 1:], ' '), '');
      return jsonb_build_object('make', mk, 'model', fam, 'trim', app.car_trim_clean(mk, fam, concat_ws(' ', rest, tr)), 'known', true);
    end if;
  end loop;
  return jsonb_build_object('make', mk, 'model', mo, 'trim', app.car_trim_clean(mk, mo, tr), 'known', case when has_families then false end);
end $$;
comment on function app.car_identity(text, text, text) is 'Release 48 AN (3151): {make, model (the family), trim, known} of a car: the make by car_make_names, Mercedes-Benz and BMW by their model codes (0520), other makes by car_model_families; the trim cleaned. The same rule as web/src/features/vin/car-identity.ts.';

-- ================================================================ 3. the body
create function app.car_body(p text) returns text
language sql immutable parallel safe as $$
  select case
    when p is null or btrim(p) = '' then p
    when k ~ '(PICKUP|TRUCK|CREW ?CAB|SUPERCREW)' then 'Pickup truck'
    when k ~ '(MINIVAN|MPV ?$|PEOPLE CARRIER)' and k !~ 'SPORT UTILITY' then 'Minivan'
    when k ~ '(SUV|SPORT UTILITY|CROSSOVER|UTILITY)' then 'SUV'
    when k ~ '(CONVERTIBLE|CABRIO|ROADSTER|SPIDER|SPYDER|VOLANTE)' then 'Convertible'
    when k ~ '(COUPE|COUPÉ)' then 'Coupe'
    when k ~ '(HATCH|LIFTBACK|SPORTBACK)' then 'Hatchback'
    when k ~ '(WAGON|ESTATE|TOURING|AVANT)' then 'Wagon'
    when k ~ '(SEDAN|SALOON)' then 'Sedan'
    when k ~ '\mVAN\M' then 'Van'
    else btrim(p) end
  from (select upper(btrim(p)) k) x
$$;
comment on function app.car_body(text) is 'Release 48 AN (3151): one body name: Sedan, Coupe, Convertible, SUV, Hatchback, Wagon, Minivan, Pickup truck, Van (the size goes in the class).';

-- ================================================================ 4. the triggers and every car on file
-- vehicles: after 0087's name case (a0) and in place of 0520's family rule (a1, the same trigger, its body widened)
create or replace function app.vehicle_model_family() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare f jsonb;
begin
  if new.make is not null then new.make := app.car_make(new.make); end if;
  if new.model is not null and btrim(new.model) <> '' then
    f := app.car_identity(new.make, new.model, new.trim);
    new.make := f ->> 'make';
    new.model := f ->> 'model';
    new.trim := f ->> 'trim';
  end if;
  return new;
end $$;
drop trigger if exists vehicles_a1_model_family on vehicles;
create trigger vehicles_a1_model_family before insert or update of make, model, trim on vehicles for each row execute function app.vehicle_model_family();

-- the listing's body (what the site shows and filters by): 0073's decoder words, then one name (vehicles.body_type keeps the
-- decoder's raw answer, as 0073 wants)
alter function app.listing_norm_body(text) rename to listing_norm_body_pre3151;
create function app.listing_norm_body(p text) returns text language sql immutable as $$ select app.car_body(app.listing_norm_body_pre3151(p)) $$;

create function app.car_identity_backfill() returns integer
language plpgsql security definer set search_path = public, app as $$
declare r record; f jsonb; n integer := 0; v_ids uuid[] := '{}';
begin
  for r in select v.id, v.make, v.model, v.trim, v.is_sample from vehicles v order by v.id loop
    f := app.car_identity(r.make, r.model, r.trim);
    continue when f ->> 'make' is not distinct from r.make and f ->> 'model' is not distinct from r.model and f ->> 'trim' is not distinct from r.trim;
    update vehicles set make = make, model = model, trim = trim where id = r.id;   -- the trigger writes them
    insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
    values (null, 'car_identity', 'vehicles', r.id::text, jsonb_build_object('make', r.make, 'model', r.model, 'trim', r.trim),
            jsonb_build_object('make', f ->> 'make', 'model', f ->> 'model', 'trim', f ->> 'trim',
                               'note', 'One make, model family, trim and body per car (3151); the public address is unchanged'));
    if not coalesce(r.is_sample, false) then
      begin
        perform app.listing_template_copy(r.id);
        perform app.car_copy_queue(r.id);
      exception when others then
        insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (null, 'car_identity_copy_failed', 'vehicles', r.id::text, jsonb_build_object('error', sqlerrm));
      end;
    end if;
    v_ids := v_ids || r.id;
    n := n + 1;
  end loop;
  -- the listings' bodies (0073's trigger runs the widened rule on every save)
  update vehicle_listings set body_style = app.listing_norm_body(body_style) where body_style is distinct from app.listing_norm_body(body_style);
  begin
    perform app.listing_cache_refresh(array(select l.vehicle_id from vehicle_listings l));
  exception when undefined_function then null;
  end;
  return n;
end $$;
revoke all on function app.car_identity_backfill() from public, anon, authenticated;
select app.car_identity_backfill();

-- ================================================================ 5. Data health: years and families
create function app.car_identity_issues() returns table (vehicle_id uuid, issue text)
language sql stable security definer set search_path = public, app as $$
  select v.id, case when v.year is not null and (v.year < 1980 or v.year > extract(year from now())::integer + 1) then 'Year looks wrong'
                    else 'Model family not recognized' end
    from vehicles v
   where v.retired_at is null and not coalesce(v.is_sample, false)
     and ((v.year is not null and (v.year < 1980 or v.year > extract(year from now())::integer + 1))
          or (nullif(btrim(v.model), '') is not null and (app.car_identity(v.make, v.model, v.trim) ->> 'known') = 'false'))
$$;
comment on function app.car_identity_issues() is 'Release 48 AN (3151): the cars whose year is outside 1980 .. next year + 1 or whose model family is not in car_model_families (add the family, or fix the typo): a person fixes them, the filters never split.';
revoke all on function app.car_identity_issues(), app.car_identity(text, text, text), app.car_make(text) from public, anon, authenticated;
grant execute on function app.car_identity_issues(), app.car_identity(text, text, text), app.car_make(text) to service_role;
