-- 51: a real car's page in the sample cars' format (migration 0073): specs in the samples' words, the samples'
-- headline, a short blurb with nothing about where the car is kept, selling features from the VIN decode, a clean web
-- address (the colour only on a clash) with a 301 from the old one, the eight studio stand-ins with the model's name,
-- the model handed to the photo worker, and the refresh of the listings already live. Fixtures start with "rf".
select test.suite('51 real car listing format');

update program_settings set listing_publish_new_cars_automatically = false;
select test.mk_user('rf_admin', 'admin');
select test.mk_owner('rf_own');

-- the 2022 Chevrolet Malibu LS of October 21, 2026, with what the VIN decoder (vPIC) said about it
insert into vin_decodes (vin, provider, ok, raw, year, make, model, trim, body_class, fuel, drivetrain, transmission, doors, seats, engine)
values ('1G1ZB5ST1NF214336', 'vpic', true, jsonb_build_object('BodyClass', 'Sedan/Saloon', 'DriveType', 'FWD/Front-Wheel Drive', 'Turbo', 'Yes', 'SeatRows', '2',
          'KeylessIgnition', 'Standard', 'RearVisibilitySystem', 'Standard', 'SemiautomaticHeadlampBeamSwitching', 'Standard', 'LowerBeamHeadlampLightSource', 'LED',
          'BlindSpotMon', 'Optional', 'LaneKeepSystem', 'Optional', 'CIB', 'Optional', 'ForwardCollisionWarning', 'Optional'),
        2022, 'Chevrolet', 'Malibu', 'LS (1LS)', 'Sedan/Saloon', 'gasoline', 'FWD/Front-Wheel Drive', 'Continuously Variable Transmission (CVT)', 4, 5, '1.5 L, 4 cylinders');
insert into vehicles (id, owner_id, year, make, model, trim, colour, vin, plate, class, status, management_mode, onboarding_method, body_type)
values (test.id('vehicle:RF1'), test.id('owner:rf_own'), 2022, 'Chevrolet', 'Malibu', 'LS', 'Black', '1G1ZB5ST1NF214336', 'RF1AAA', 'standard', 'available', 'managed', 'transfer', 'Sedan/Saloon');
do $$ begin perform app.ensure_listing(test.id('vehicle:RF1')); end $$;
update vehicle_listings set body_style = 'Sedan/Saloon', transmission = 'Continuously Variable Transmission (CVT)', drivetrain = 'FWD/Front-Wheel Drive',
       seats = 5, doors = 4, home_area = 'Pickering'
 where vehicle_id = test.id('vehicle:RF1');

-- ================================================================ 1. specs in the samples' words
select test.eq('body, gearbox and drive read like the sample cars''',
  (select concat_ws('|', body_style, transmission, drivetrain) from vehicle_listings where vehicle_id = test.id('vehicle:RF1')),
  'Sedan|Automatic (CVT)|Front-wheel drive');
select test.eq('other decoder words', concat_ws('|', app.listing_norm_body('Sport Utility Vehicle (SUV)/Multi-Purpose Vehicle (MPV)'), app.listing_norm_body('Hatchback/Liftback/Notchback'),
  app.listing_norm_body('Pickup'), app.listing_norm_transmission('Automatic'), app.listing_norm_transmission('Manual/Standard'), app.listing_norm_drive('AWD/All-Wheel Drive'),
  app.listing_norm_drive('4WD/4-Wheel Drive/4x4')), 'SUV|Hatchback|Pickup truck|Automatic|Manual|All-wheel drive|Four-wheel drive');

-- ================================================================ 2. the equipment the features may name
select test.eq('known: the decoder''s standard items, the age rules and the basics, in order (never an optional item)',
  (select string_agg(x, ', ') from jsonb_array_elements_text(app.vehicle_equipment(test.id('vehicle:RF1')) -> 'known') x),
  'Backup camera, Push-button start, Turbocharged engine, Automatic high beams, LED headlights, Bluetooth, Air conditioning, Cruise control, Automatic transmission');
select test.ok('maybe: what the model may confirm for the trim (Apple CarPlay and Android Auto first)',
  (app.vehicle_equipment(test.id('vehicle:RF1')) -> 'maybe' ->> 0) = 'Apple CarPlay and Android Auto'
  and not (app.vehicle_equipment(test.id('vehicle:RF1')) -> 'maybe') ? 'Blind spot assist');
select test.ok('the copy facts carry both lists and no longer where the car is kept',
  (app.car_copy_facts(test.id('vehicle:RF1')) #> '{car,equipment_known}') ? 'Push-button start' and app.car_copy_facts(test.id('vehicle:RF1')) #> '{place,area}' is null);

-- ================================================================ 3. publish: the samples' format, a clean address, the studio stand-ins
do $$ begin perform app.listing_publish_now(test.id('rf_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:RF1'))); end $$;
select test.eq('the clean web address', (select slug from vehicle_listings where vehicle_id = test.id('vehicle:RF1')), '2022-chevrolet-malibu-ls');
select test.eq('the samples'' headline', (select headline from vehicle_listings where vehicle_id = test.id('vehicle:RF1')), '2022 Chevrolet Malibu LS for rent in Toronto');
select test.eq('a short blurb in the samples'' voice', (select description from vehicle_listings where vehicle_id = test.id('vehicle:RF1')),
  'A comfortable Chevrolet sedan with room for five and a proper trunk. Easy to park in the city and quiet on the highway.');
select test.ok('nothing about where the car is kept, anywhere in its copy',
  (select l.description || l.headline || array_to_string(l.features, ' ') || l.faq::text || cc.copy::text from vehicle_listings l join car_copy cc on cc.vehicle_id = l.vehicle_id
    where l.vehicle_id = test.id('vehicle:RF1')) !~* 'pickering|kept in');
select test.eq('six selling features, not specs', (select array_to_string(features, ', ') from vehicle_listings where vehicle_id = test.id('vehicle:RF1')),
  'Backup camera, Push-button start, Turbocharged engine, Automatic high beams, LED headlights, Bluetooth');
select test.eq('the copy passes the listing rules (a short description is fine now)',
  (select cardinality(app.listing_copy_problems(headline, description, features, faq)) from vehicle_listings where vehicle_id = test.id('vehicle:RF1')), 0);
create temp table rf_page as select public.car_page('2022-chevrolet-malibu-ls') p;
grant all on rf_page to public;
select test.eq('a real car, not an example', (select (p ->> 'is_sample')::boolean from rf_page), false);
select test.eq('eight studio stand-ins, as the sample cars have', (select jsonb_array_length(p -> 'photos') from rf_page), 8);
select test.eq('the lead shot: a black sedan with MALIBU behind it', (select p -> 'photos' -> 0 ->> 'path' from rf_page), '/sample-photos/studio/sedan/black/lead/MALIBU.svg');
select test.eq('the shots in the samples'' order and size', (select string_agg((e ->> 'shot') || ':' || (e ->> 'width') || 'x' || (e ->> 'height'), ',') from rf_page, jsonb_array_elements(p -> 'photos') e),
  'front_left:1800x1200,left:1800x1200,rear_left:1800x1200,front:1800x1200,rear:1800x1200,dashboard:1800x1200,front_seats:1800x1200,wheel:1800x1200');
select test.ok('marked as representative', (select bool_and((e ->> 'sample')::boolean) and bool_and(e ->> 'alt' like 'Representative studio image of a black sedan like the 2022 Chevrolet Malibu%')
  from rf_page, jsonb_array_elements(p -> 'photos') e));
select test.eq('the fleet card shows the lead shot', (app.public_listing_row(test.id('vehicle:RF1')) -> 'cover' ->> 'path'), '/sample-photos/studio/sedan/black/lead/MALIBU.svg');
select test.eq('no locked copy fields', (select p -> 'copy_locked' from rf_page), '[]'::jsonb);

-- other bodies and colours
insert into vehicles (id, owner_id, year, make, model, trim, colour, vin, plate, class, status, management_mode, onboarding_method, body_type)
values (test.id('vehicle:RF2'), test.id('owner:rf_own'), 2023, 'Honda', 'CR-V', 'EX-L', 'Lunar Silver Metallic', null, 'RF2AAA', 'suv', 'available', 'managed', 'transfer', 'Compact SUV');
select test.eq('a compact SUV in silver, its own name', app.vehicle_studio_photos(test.id('vehicle:RF2')) -> 0 ->> 'path', '/sample-photos/studio/suv/silver/lead/CR-V.svg');

-- ================================================================ 4. a second car of the same trim: the colour, then a short code
insert into vehicles (id, owner_id, year, make, model, trim, colour, vin, plate, class, status, management_mode, onboarding_method, body_type)
values (test.id('vehicle:RF3'), test.id('owner:rf_own'), 2022, 'Chevrolet', 'Malibu', 'LS', 'White', null, 'RF3AAA', 'standard', 'available', 'managed', 'transfer', 'Sedan');
select test.eq('the same trim again: its colour in the address', app.listing_slug(test.id('vehicle:RF3')), '2022-chevrolet-malibu-ls-white');
select test.eq('the first car keeps its own', app.listing_slug(test.id('vehicle:RF1')), '2022-chevrolet-malibu-ls');

-- ================================================================ 5. a listing published in the old format is refreshed
-- the old address and the old text, as the Malibu had them before this migration
do $$ begin perform set_config('app.listing_slug_move', test.id('vehicle:RF1')::text, false); end $$;
update vehicle_listings set slug = '2022-chevrolet-malibu-ls-black-d537', headline = '2022 Chevrolet Malibu LS rental in Toronto',
       description = 'This car is a 2022 Chevrolet Malibu LS with a 1.5 L engine. It is black and kept in Pickering. The car is in Pickering.',
       features = array['5 seats', 'Continuously Variable Transmission', 'Gas fuel', 'FWD drivetrain']
 where vehicle_id = test.id('vehicle:RF1');
do $$ begin perform set_config('app.listing_slug_move', '', false); end $$;
update car_copy set source = 'ai', status = 'failed', next_attempt_at = now() + interval '6 hours', prompt_version = 'car-copy-v1' where vehicle_id = test.id('vehicle:RF1');
select test.throws('a published address does not change otherwise', $$update vehicle_listings set slug = 'x-y' where vehicle_id = test.id('vehicle:RF1')$$, '%does not change%');
select test.ok('the refresh runs over every real car', app.listing_format_refresh() >= 1);
select test.eq('the clean address', (select slug from vehicle_listings where vehicle_id = test.id('vehicle:RF1')), '2022-chevrolet-malibu-ls');
select test.eq('the old address answers 301 to the new one', (select concat_ws(' ', status_code, to_path) from listing_redirects where from_path = '/cars/2022-chevrolet-malibu-ls-black-d537'),
  '301 /cars/2022-chevrolet-malibu-ls');
select test.eq('the site follows it', (public.car_page('2022-chevrolet-malibu-ls-black-d537') ->> 'redirect'), '/cars/2022-chevrolet-malibu-ls');
select test.eq('the new text in place at once', (select headline || ' / ' || array_to_string(features[1:2], ', ') from vehicle_listings where vehicle_id = test.id('vehicle:RF1')),
  '2022 Chevrolet Malibu LS for rent in Toronto / Backup camera, Push-button start');
select test.ok('the robotic text and the storage place are gone', (select description from vehicle_listings where vehicle_id = test.id('vehicle:RF1')) !~* 'pickering|this car is');
select test.ok('the AI copy is written again now, first in line', exists (select 1 from car_copy where vehicle_id = test.id('vehicle:RF1') and status = 'pending' and asked_at is not null and next_attempt_at <= now()));
select test.eq('the sample cars are left as they are', (select count(*) from listing_redirects where reason = 'Clean web address (0073)' and vehicle_id in (select id from vehicles where is_sample))::integer, 0);

-- ================================================================ 6. the copy put live always carries the samples' headline
do $$ begin perform app.car_copy_apply(test.id('vehicle:RF1'), (select copy from car_copy where vehicle_id = test.id('vehicle:RF1')) || jsonb_build_object('h1', 'Malibu rental, Toronto'), 'ai'); end $$;
select test.eq('an AI headline in another shape is replaced', (select headline from vehicle_listings where vehicle_id = test.id('vehicle:RF1')), '2022 Chevrolet Malibu LS for rent in Toronto');

-- ================================================================ 7. the photo worker learns the model
insert into listing_intakes (id, vehicle_id, started_by, started_role, review_required, state) values (test.id('intake:RF1'), test.id('vehicle:RF1'), test.id('rf_admin'), 'admin', false, 'processing_photos');
insert into vehicle_photos (id, vehicle_id, shot_type, angle, status, original_path, sort_order)
values (test.id('photo:RF1'), test.id('vehicle:RF1'), 'front_left', 'front_left', 'uploaded', 'vehicles/rf1/lead-o.jpg', 1);
insert into listing_jobs (id, intake_id, vehicle_id, kind, vehicle_photo_id, max_attempts) values (test.id('job:RF1'), test.id('intake:RF1'), test.id('vehicle:RF1'), 'process_photo', test.id('photo:RF1'), 4);
select test.eq('the job''s photo carries the model, for the lettering', app.listing_job_context(test.id('job:RF1')) #>> '{photo,model}', 'Malibu');

update program_settings set listing_publish_new_cars_automatically = false;
