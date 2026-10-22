-- 52: VIN-first entry (migration 0082). The class inferred from the make, model, trim, body and age (Porsche Macan and
-- Cadillac CTS are not Standard; SUVs are SUV; a person's class is kept); what a VIN tells the form in one call (check
-- digit, decode, the car already in the fleet, class, starting rate); a new car on every path gets its decoded details,
-- its class and its copy queued at once; nothing a person entered is overwritten; a VIN decoded later fills the car;
-- the colour from the cover photo; the backfill. Fixtures start with "vf".
select test.suite('52 VIN-first entry');

update program_settings set listing_publish_new_cars_automatically = true;
select test.mk_user('vf_admin', 'admin');
select test.mk_user('vf_cs', 'va', 'cs');
select test.mk_owner('vf_own');

-- the decodes on file, as the server records them (the fake decoder's cars; the check digits are right)
select app.record_vin_decode('WP1AB2A56GLB12345', 'fake', '{"ok": true, "year": "2016", "make": "Porsche", "model": "Macan", "trim": "S", "body_class": "Sport Utility Vehicle (SUV)/Multi-Purpose Vehicle (MPV)", "fuel": "gasoline", "drivetrain": "AWD/All-Wheel Drive", "transmission": "Automatic, 7 speeds", "doors": "5", "seats": "5", "engine": "3.0 L, V6, turbo"}');
select app.record_vin_decode('1G6AX5SX5F0123456', 'fake', '{"ok": true, "year": "2015", "make": "Cadillac", "model": "CTS", "trim": "Luxury", "body_class": "Sedan/Saloon", "fuel": "gasoline", "drivetrain": "AWD/All-Wheel Drive", "transmission": "Automatic, 8 speeds", "doors": "4", "seats": "5", "engine": "2.0 L, 4 cylinders, turbo"}');
select app.record_vin_decode('1FM5K8D87LGA12345', 'fake', '{"ok": true, "year": "2020", "make": "Ford", "model": "Explorer", "trim": "XLT", "body_class": "Sport Utility Vehicle (SUV)/Multi-Purpose Vehicle (MPV)", "fuel": "gasoline", "drivetrain": "4WD/4-Wheel Drive/4x4", "transmission": "Automatic, 10 speeds", "doors": "4", "seats": "7", "engine": "2.3 L, 4 cylinders, turbo"}');
select app.record_vin_decode('2HGFC2F59KH123456', 'fake', '{"ok": true, "year": "2019", "make": "Honda", "model": "Civic", "trim": "LX", "body_class": "Sedan/Saloon", "fuel": "hybrid", "drivetrain": "FWD/Front-Wheel Drive", "transmission": "Continuously Variable Transmission (CVT)", "doors": "4", "seats": "5", "engine": "2.0 L, 4 cylinders"}');
select app.record_vin_decode('ZZZZZ12370A123456', 'fake', '{"ok": false, "error_code": "unknown_sample"}');

-- ================================================================ 1. the class
select test.eq('class: a 2016 Porsche Macan is Premium (a Porsche, Luxury when newer)', app.infer_vehicle_class(2016, 'PORSCHE', 'Macan', 'S', 'Sport Utility Vehicle (SUV)/Multi-Purpose Vehicle (MPV)') ->> 'class', 'premium');
select test.ok('class: the reason says why', (app.infer_vehicle_class(2016, 'Porsche', 'Macan', 'S', null) ->> 'why') like 'Premium: a Porsche, % years old (Luxury when newer)');
select test.eq('class: a new Porsche Macan is Luxury', app.infer_vehicle_class(extract(year from app.today())::integer, 'Porsche', 'Macan', null, null) ->> 'class', 'luxury');
select test.eq('class: a 2015 Cadillac CTS is Premium', app.infer_vehicle_class(2015, 'Cadillac', 'CTS', 'Luxury', 'Sedan/Saloon') ->> 'class', 'premium');
select test.eq('class: an Escalade is Luxury, any spelling of the make', app.infer_vehicle_class(2023, 'CADILLAC', 'Escalade', null, null) ->> 'class', 'luxury');
select test.eq('class: Mercedes-Benz GLE is Luxury, GLC and C-Class Premium',
  (app.infer_vehicle_class(2022, 'Mercedes-Benz', 'GLE-Class', null, 'SUV') ->> 'class') || '/' || (app.infer_vehicle_class(2022, 'MERCEDES BENZ', 'GLC', null, 'SUV') ->> 'class')
  || '/' || (app.infer_vehicle_class(2022, 'mercedes-benz', 'C-Class', 'C300', 'Sedan') ->> 'class'), 'luxury/premium/premium');
select test.eq('class: BMW X5 Luxury, M340i Premium', (app.infer_vehicle_class(2022, 'BMW', 'X5', null, null) ->> 'class') || '/' || (app.infer_vehicle_class(2022, 'BMW', 'M340i', null, null) ->> 'class'), 'luxury/premium');
select test.eq('class: an exotic make is Exotic', app.infer_vehicle_class(2023, 'Ferrari', 'Roma', null, 'Coupe') ->> 'class', 'exotic');
select test.eq('class: a Ford Explorer (an SUV by its body) is SUV', app.infer_vehicle_class(2020, 'Ford', 'Explorer', 'XLT', 'Sport Utility Vehicle (SUV)/Multi-Purpose Vehicle (MPV)') ->> 'class', 'suv');
select test.eq('class: a minivan and a pickup are SUV', (app.infer_vehicle_class(2020, 'Honda', 'Odyssey', null, 'Minivan') ->> 'class') || '/' || (app.infer_vehicle_class(2020, 'Ford', 'F-150', null, 'Pickup') ->> 'class'), 'suv/suv');
select test.eq('class: a Ford Mustang is Premium (a sports model)', app.infer_vehicle_class(2021, 'Ford', 'Mustang', 'GT', 'Coupe') ->> 'class', 'premium');
select test.eq('class: a Kia Forte and a Toyota Corolla are Economy, a Corolla Cross SUV',
  (app.infer_vehicle_class(2021, 'KIA', 'Forte', 'LXS', 'Sedan/Saloon') ->> 'class') || '/' || (app.infer_vehicle_class(2022, 'Toyota', 'Corolla', 'LE', 'Sedan') ->> 'class')
  || '/' || (app.infer_vehicle_class(2022, 'Toyota', 'Corolla Cross', null, 'Sport Utility Vehicle (SUV)') ->> 'class'), 'economy/economy/suv');
select test.eq('class: anything else is Standard', app.infer_vehicle_class(2022, 'Chevrolet', 'Malibu', 'LS', 'Sedan/Saloon') ->> 'class', 'standard');
select test.eq('class: the label is the class list''s ("SUV", not "Suv")', app.infer_vehicle_class(2020, 'Ford', 'Explorer', null, 'SUV') ->> 'why', 'SUV: an SUV, van or pickup');
-- the rules are rows an Admin may change
insert into vehicle_class_rules (rank, make_key, model_re, class, note) values (5, 'chevrolet', '^malibu', 'premium', 'a test rule');
select test.eq('class: a rule of a lower rank wins', app.infer_vehicle_class(2022, 'Chevrolet', 'Malibu', null, null) ->> 'class', 'premium');
update vehicle_class_rules set is_active = false where note = 'a test rule';
select test.eq('class: an inactive rule is skipped', app.infer_vehicle_class(2022, 'Chevrolet', 'Malibu', null, null) ->> 'class', 'standard');
select test.login(test.id('vf_cs'));
select test.eq('class: an assistant reads the rules but changes none', test.visible('select 1 from vehicle_class_rules') > 40
  and test.affected($$update vehicle_class_rules set rank = 1 where note = 'a test rule'$$) = 0, true);
select test.logout();
select test.login(test.id('vf_admin'));
select test.eq('class: an Admin changes them', test.affected($$update vehicle_class_rules set rank = 6 where note = 'a test rule'$$), 1::bigint);
select test.logout();

-- ================================================================ 2. what a VIN tells the form
select test.eq('facts: a VIN with a wrong character is not valid', app.vin_facts('WP1AB2A56GLB1234O') ->> 'valid', 'false');
select test.eq('facts: the check digit is checked (and the VIN is still valid)',
  (app.vin_facts('WP1AB2A56GLB12345') ->> 'check_ok') || '/' || (app.vin_facts('WP1AB2A57GLB12345') ->> 'check_ok') || '/' || (app.vin_facts('WP1AB2A57GLB12345') ->> 'valid'), 'true/false/true');
select test.eq('facts: the decode in the listing''s words', (select concat_ws('|', f #>> '{decode,year}', f #>> '{decode,make}', f #>> '{decode,model}', f #>> '{decode,trim}', f #>> '{decode,body}',
    f #>> '{decode,drivetrain}', f #>> '{decode,transmission}', f #>> '{decode,seats}', f #>> '{decode,doors}', f #>> '{decode,engine}', f #>> '{decode,fuel}')
    from (select app.vin_facts('wp1ab2a56glb12345') f) x), '2016|Porsche|Macan|S|SUV|All-wheel drive|Automatic|5|5|3.0 L, V6, turbo|gasoline');
select test.eq('facts: the class with the decode', app.vin_facts('WP1AB2A56GLB12345') #>> '{class,class}', 'premium');
select test.eq('facts: the starting rate is the Premium class''s (similar cars, else its default), not the Standard one',
  (app.vin_facts('WP1AB2A56GLB12345') #>> '{rates,daily_cents}')::bigint, (app.listing_default_daily(null, '{"class": "premium", "make": "Porsche", "model": "Macan"}') ->> 'daily_cents')::bigint);
select test.ok('facts: with no similar cars, the Premium default',
  (app.vin_facts('1G6AX5SX5F0123456') -> 'rates' ->> 'source') <> 'class' or (app.vin_facts('1G6AX5SX5F0123456') #>> '{rates,daily_cents}')::bigint
    = coalesce(((app.settings()).listing_default_daily_rate_cents ->> 'premium')::bigint, 10900));
select test.eq('facts: a VIN the decoder could not read says so, with no class', (select (f ->> 'decode') is null and (f ->> 'decode_failed_at') is not null and (f ->> 'class') is null
  from (select app.vin_facts('ZZZZZ12370A123456') f) x), true);
select test.eq('facts: a list of trims is no trim', coalesce(app.decode_trim('S, Final Edition SE, SE'), '-') || '/' || coalesce(app.decode_trim('S / SE / R-Line'), '-') || '/' || app.decode_trim('LS (1LS)'), '-/-/LS (1LS)');
select test.eq('facts: the class hint for year, make and model typed by hand', app.vin_class_hint('{"year": 2015, "make": "Cadillac", "model": "CTS"}') #>> '{class,class}', 'premium');
select test.eq('facts: a class chosen by hand sets the rate', (app.vin_class_hint('{"year": 2015, "make": "Cadillac", "model": "CTS", "class": "luxury"}') #>> '{rates,daily_cents}')::bigint,
  coalesce(((app.settings()).listing_default_daily_rate_cents ->> 'luxury')::bigint, 18900));

-- ================================================================ 3. Add a car (Admin): a company car from the VIN alone
create temp table vf_add as select app.vehicle_add(test.id('vf_admin'), jsonb_build_object('supply_type', 'company', 'vin', 'WP1AB2A56GLB12345',
  'class', 'premium', 'class_source', 'inferred', 'rates', jsonb_build_object('daily', 10900))) r;
grant all on vf_add to public;
create function test.vf_car() returns vehicles language sql stable as $$ select * from vehicles where id = (select (r ->> 'vehicle_id')::uuid from vf_add) $$;
select test.eq('add: year, make, model, trim, body and fuel from the decode',
  (select concat_ws('|', year, make, model, trim, body_type, fuel) from test.vf_car() v), '2016|Porsche|Macan|S|Sport Utility Vehicle (SUV)/Multi-Purpose Vehicle (MPV)|gasoline');
select test.eq('add: the listing''s seats, doors, gearbox, drive, body and engine from the decode',
  (select concat_ws('|', l.seats, l.doors, l.transmission, l.drivetrain, l.body_style, l.specs ->> 'engine') from vehicle_listings l where l.vehicle_id = (test.vf_car()).id),
  '5|5|Automatic|All-wheel drive|SUV|3.0 L, V6, turbo');
select test.eq('add: the class inferred, and marked so', (select v.class::text || '/' || (v.spec_sources #>> '{class,source}') from test.vf_car() v), 'premium/inferred');
select test.ok('add: the copy is queued and asked for first, with the plain copy in place',
  exists (select 1 from car_copy c where c.vehicle_id = (test.vf_car()).id and c.status = 'pending' and c.asked_at is not null and c.copy <> '{}'::jsonb)
  and exists (select 1 from vehicle_listings l where l.vehicle_id = (test.vf_car()).id and l.headline like '2016 Porsche Macan S%'));
select test.ok('add: published at once with its rates', (select (r #>> '{listing,published}')::boolean from vf_add));
select test.eq('add: the search job takes the new car with the cars asked for first',
  (select bool_or((c ->> 'vehicle_id')::uuid = (test.vf_car()).id) from jsonb_array_elements(app.server_seo_claim('vf-test', 1 + (select count(*)::integer from car_copy where asked_at is not null and vehicle_id <> (test.vf_car()).id)) -> 'cars') c), true);
update car_copy set status = 'pending', locked_at = null where vehicle_id = (test.vf_car()).id;
select test.eq('facts: the VIN is now taken, by that car', (app.vin_facts('WP1AB2A56GLB12345') #>> '{taken,vehicle_id}')::uuid, (test.vf_car()).id);

-- a class chosen by a person is kept; a person's values win over the decode
create temp table vf_add2 as select app.vehicle_add(test.id('vf_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1G6AX5SX5F0123456',
  'class', 'luxury', 'trim', 'Premium Luxury', 'colour', 'Silver')) r;
grant all on vf_add2 to public;
select test.eq('add: a person''s class and trim are kept, the colour marked as theirs',
  (select concat_ws('|', v.class, v.trim, v.spec_sources #>> '{class,source}', v.spec_sources #>> '{colour,source}') from vehicles v where v.id = (select (r ->> 'vehicle_id')::uuid from vf_add2)),
  'luxury|Premium Luxury|person|person');

-- by its plate, with year, make and model from the lists: never refused for want of a decode
create temp table vf_add3 as select app.vehicle_add(test.id('vf_admin'), jsonb_build_object('supply_type', 'company', 'plate', 'VF3 AAA',
  'year', 2021, 'make', 'Ford', 'model', 'Mustang')) r;
grant all on vf_add3 to public;
select test.eq('add: by plate, no decode: the class from the make and model', (select class::text from vehicles where id = (select (r ->> 'vehicle_id')::uuid from vf_add3)), 'premium');
-- a VIN the decoder could not read: year, make and model typed, saved all the same
create temp table vf_add4 as select app.vehicle_add(test.id('vf_admin'), jsonb_build_object('supply_type', 'company', 'vin', 'ZZZZZ12370A123456',
  'year', 2019, 'make', 'Toyota', 'model', 'Corolla')) r;
grant all on vf_add4 to public;
select test.ok('add: a VIN not decoded is saved with the three facts', exists (select 1 from vehicles where id = (select (r ->> 'vehicle_id')::uuid from vf_add4) and class = 'economy'));
select test.throws('add: with neither decode nor year, make and model, the three are asked for',
  $$select app.vehicle_add(test.id('vf_admin'), '{"supply_type": "company", "vin": "1HGCV1F31LA123456"}')$$, '%year, make and model%');

-- ================================================================ 4. a car for an owner (staff) and the owner's own application
create temp table vf_staff as select app.staff_add_owner_car(test.id('vf_cs'), jsonb_build_object('owner_id', test.id('owner:vf_own'),
  'vehicle', jsonb_build_object('vin', '1FM5K8D87LGA12345', 'title_status', 'owned_outright', 'management_mode', 'managed', 'colour', 'Blue'))) r;
grant all on vf_staff to public;
create function test.vf_scar() returns vehicles language sql stable as $$ select * from vehicles where id = (select (r ->> 'vehicle_id')::uuid from vf_staff) $$;
select test.eq('owner car (assistant): from the VIN alone, everything decoded, SUV',
  (select concat_ws('|', v.year, v.make, v.model, v.trim, v.class, v.colour) from test.vf_scar() v), '2020|Ford|Explorer|XLT|suv|Blue');
select test.eq('owner car: the listing details', (select concat_ws('|', l.seats, l.drivetrain) from vehicle_listings l where l.vehicle_id = (test.vf_scar()).id), '7|Four-wheel drive');
select test.ok('owner car: the copy queued at once', exists (select 1 from car_copy c where c.vehicle_id = (test.vf_scar()).id and c.asked_at is not null));
select test.ok('owner car: the class link of the old default is gone (SUV, not Standard and SUV)',
  not exists (select 1 from vehicle_class_links k where k.vehicle_id = (test.vf_scar()).id and k.class_code = 'standard'));

select test.mk_user('vf_olga', 'owner');
create temp table vf_app as select app.submit_owner_application(jsonb_build_object(
  'owner', jsonb_build_object('owner_type', 'individual', 'legal_name', 'Olga Vf', 'first_name', 'Olga', 'last_name', 'Vf',
                              'address_line1', '5 Owner Road', 'city', 'Toronto', 'province', 'ON', 'postal_code', 'M4M 1A1',
                              'email', 'olga.vf@example.test', 'phone', '4165550199', 'licence_number', 'T1234-56789-01299', 'date_of_birth', '1985-04-09'),
  'vehicles', jsonb_build_array(jsonb_build_object('vin', '2HGFC2F59KH123456', 'plate', 'VF0001', 'year', 2019, 'make', 'Honda', 'model', 'Civic', 'colour', 'Red',
    'odometer_km', 50000, 'title_status', 'owned_outright', 'management_mode', 'managed', 'onboarding_method', 'transfer', 'current_insurer', 'Intact',
    'class', 'exotic'))), test.id('vf_olga')) r;
grant all on vf_app to public;
create function test.vf_ocar() returns vehicles language sql stable as $$ select * from vehicles where id = ((select r from vf_app) #>> '{vehicles,0,vehicle_id}')::uuid $$;
select test.eq('owner''s application: the class is inferred (an owner does not choose it)', (test.vf_ocar()).class::text, 'standard');
select test.eq('owner''s application: the decoded details filled; the fuel the owner chose... none: the decode''s',
  (select concat_ws('|', v.trim, v.fuel, l.seats, l.transmission) from test.vf_ocar() v join vehicle_listings l on l.vehicle_id = v.id), 'LX|hybrid|5|Automatic (CVT)');
select test.ok('owner''s application: copy queued, the car not published before the decision',
  exists (select 1 from car_copy c where c.vehicle_id = (test.vf_ocar()).id)
  and not exists (select 1 from vehicle_listings l where l.vehicle_id = (test.vf_ocar()).id and l.status = 'published'));

-- ================================================================ 5. nothing a person entered is overwritten; decoded later
insert into vehicles (id, owner_id, year, make, model, trim, vin, plate, class, status, management_mode, onboarding_method, spec_sources)
values (test.id('vehicle:VF9'), test.id('owner:vf_own'), 2015, 'Cadillac', 'CTS', 'Base', '1G6AX5SX7F0654321', 'VF9XXX', 'standard', 'onboarding', 'managed', 'transfer',
        '{"trim": {"source": "person"}}');
select app.record_vin_decode('1G6AX5SX7F0654321', 'fake', (select jsonb_build_object('ok', true, 'year', '2015', 'make', 'Cadillac', 'model', 'CTS', 'trim', 'Luxury',
  'body_class', 'Sedan/Saloon', 'fuel', 'gasoline', 'drivetrain', 'AWD/All-Wheel Drive', 'transmission', 'Automatic, 8 speeds', 'doors', '4', 'seats', '5', 'engine', '2.0 L, 4 cylinders, turbo')));
select app.ensure_listing(test.id('vehicle:VF9'));
update vehicle_listings set seats = 4, spec_sources = '{"seats": {"source": "person"}}' where vehicle_id = test.id('vehicle:VF9');
select test.eq('fill: the empty fields only', (select string_agg(x, ',' order by x) from unnest(app.vin_fill_missing(test.id('vehicle:VF9'))) x),
  'body_style,body_type,doors,drivetrain,engine,transmission');
select test.eq('fill: a person''s trim and seats are kept', (select v.trim || '/' || l.seats from vehicles v join vehicle_listings l on l.vehicle_id = v.id where v.id = test.id('vehicle:VF9')), 'Base/4');
select test.eq('fill: a second run fills nothing', cardinality(app.vin_fill_missing(test.id('vehicle:VF9'))), 0);
select test.eq('class: a car whose class nobody chose gets the inferred one; a person''s stays',
  (app.vehicle_infer_class(test.id('vehicle:VF9')) ->> 'class') || '/' || coalesce(app.vehicle_infer_class((select (r ->> 'vehicle_id')::uuid from vf_add2)) ->> 'class', 'kept'), 'premium/kept');

-- a VIN the decoder could not read is tried again, then the car fills itself
insert into vehicles (id, owner_id, year, make, model, vin, plate, class, status, management_mode, onboarding_method)
values (test.id('vehicle:VF10'), test.id('owner:vf_own'), 2020, 'Kia', 'Forte', 'KNAFK4A6XF5123456', 'VF10XX', 'standard', 'onboarding', 'managed', 'transfer');
select test.ok('later: the VIN is due for a decode', app.vin_decode_due(100000) @> '[{"vin": "KNAFK4A6XF5123456"}]');
select test.ok('later: the cron gate calls the listing worker while a VIN waits', (app.server_jobs_due() ->> 'listing')::boolean);
select app.record_vin_decode('KNAFK4A6XF5123456', 'fake', '{"ok": true, "year": "2015", "make": "Kia", "model": "Forte", "trim": "LX", "body_class": "Sedan/Saloon", "fuel": "gasoline", "seats": "5"}');
select test.eq('later: the decode fills the car', app.vin_decoded_apply('KNAFK4A6XF5123456'), 1);
select test.eq('later: and its class', (select class::text || '/' || trim from vehicles where id = test.id('vehicle:VF10')), 'economy/LX');
select test.ok('later: no longer due', not (app.vin_decode_due(100000) @> '[{"vin": "KNAFK4A6XF5123456"}]'));
select test.ok('later: a VIN tried in the last 6 hours waits', not (app.vin_decode_due(100000) @> '[{"vin": "ZZZZZ12370A123456"}]'));

-- ================================================================ 6. the colour from the cover photo
update program_settings set ai_vision_enabled = true;
insert into vehicle_photos (id, vehicle_id, angle, original_path, processed_path, status, is_cover, is_public, variants)
values (test.id('photo:VF10'), test.id('vehicle:VF10'), 'front_left', 'o/vf10.jpg', 'p/vf10.webp', 'approved', true, true,
        '[{"width": 1600, "format": "webp", "path": "p/vf10-1600.webp"}, {"width": 800, "format": "jpg", "path": "p/vf10-800.jpg"}, {"width": 480, "format": "jpg", "path": "p/vf10-480.jpg"}]');
select test.ok('copy: a public photo with no shot type does not stop the template (release 2)', app.car_copy_template('{"car": {"year": 2015, "make": "Kia", "model": "Forte"}, "photos": [null, "front"]}'::jsonb) ? 'h1');
select test.eq('colour: a car with no colour and a cover photo is due, its smallest JPEG of 400 px or more',
  (select c ->> 'path' from jsonb_array_elements(app.colour_read_due(100000) -> 'cars') c where (c ->> 'vehicle_id')::uuid = test.id('vehicle:VF10')), 'p/vf10-480.jpg');
select test.ok('colour: a car whose colour a person entered is not', not exists (select 1 from jsonb_array_elements(app.colour_read_due(100000) -> 'cars') c where (c ->> 'vehicle_id')::uuid = (test.vf_scar()).id));
select test.eq('colour: a colour that is not a swatch is not stored', app.colour_read_record(jsonb_build_object('vehicle_id', test.id('vehicle:VF10'), 'photo_id', test.id('photo:VF10'), 'ok', true, 'colour', 'Chartreuse', 'model', 'fake', 'neurons', 3)) ->> 'set', 'false');
select test.eq('colour: a swatch is stored', app.colour_read_record(jsonb_build_object('vehicle_id', test.id('vehicle:VF10'), 'photo_id', test.id('photo:VF10'), 'ok', true, 'colour', 'Red', 'model', 'fake', 'neurons', 3)) ->> 'set', 'true');
select test.eq('colour: marked as detected, and the calls counted',
  (select colour || '/' || (spec_sources #>> '{colour,source}') from vehicles where id = test.id('vehicle:VF10'))
  || '/' || (select count(*) from provider_calls where purpose = 'colour_read' and vehicle_id = test.id('vehicle:VF10')), 'Red/detected/2');
select test.ok('colour: no longer due', not exists (select 1 from jsonb_array_elements(app.colour_read_due(100000) -> 'cars') c where (c ->> 'vehicle_id')::uuid = test.id('vehicle:VF10')));
update vehicles set colour = null, spec_sources = spec_sources - 'colour' where id = test.id('vehicle:VF10');
select test.ok('colour: the same photo is not read again after an answer', not exists (select 1 from jsonb_array_elements(app.colour_read_due(100000) -> 'cars') c where (c ->> 'vehicle_id')::uuid = test.id('vehicle:VF10')));
update program_settings set ai_vision_enabled = false;
select test.eq('colour: nothing while the vision model is off', app.colour_read_due(100000) ->> 'allowed', 'false');

-- ================================================================ 7. privileges
select test.ok('privileges: the new functions are the server''s only', not has_function_privilege('authenticated', 'app.vin_facts(text)', 'execute')
  and not has_function_privilege('anon', 'public.server_vin_facts(text)', 'execute') and has_function_privilege('service_role', 'public.server_vin_facts(text)', 'execute')
  and not has_function_privilege('authenticated', 'public.server_colour_read_record(jsonb)', 'execute'));
select test.ok('privileges: the wrapped add functions keep their callers', has_function_privilege('service_role', 'app.vehicle_add_core(uuid, jsonb)', 'execute')
  and not has_function_privilege('anon', 'app.add_owner_vehicle(uuid, jsonb, uuid, uuid)', 'execute'));

update program_settings set listing_publish_new_cars_automatically = false;
