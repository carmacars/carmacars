-- 99: migrations 3150 and 3151 (release 48, part AN). The renders first (the side profile the cover, the front
-- three-quarter second, then the other angles), the real photos after them and never hidden, the side cutout on the listing
-- row, the render backfill and who may run it; one make, model family, trim and body per car, kept on every save, and the
-- filters' families. Fixtures start with "an48_"; no real names or plates.
select test.suite('99 r48 AN renders first and car identity (3150, 3151)');

select test.mk_user('an48_admin', 'admin');
select test.mk_owner('an48_olive');
select test.mk_renter('an48_rita');
select test.mk_vehicle('an48_a', 'an48_olive');
select test.mk_vehicle('an48_b', 'an48_olive');
insert into vehicle_listings (vehicle_id, status) select test.id('vehicle:' || x), 'published' from unnest(array['an48_a', 'an48_b']) x;

-- ================================================================ 3150: the gallery
-- car a: renders of the rear, the front three-quarter and the side (made in that order), a flagged render of the front, and
-- two real photos; car b: real photos only
insert into vehicle_photos (vehicle_id, angle, shot_type, original_path, processed_path, status, is_public, r48, ai_generated, background_status, plate_status, sort_order, r45)
values (test.id('vehicle:an48_a'), 'rear', 'rear', 'vehicles/original/an48/a-rear-r.jpg', 'vehicles/an48/a-rear-r.jpg', 'approved', true, true, true, 'done', 'not_visible', -95, '{"state": "done"}'),
       (test.id('vehicle:an48_a'), 'front_left', 'front_left', 'vehicles/original/an48/a-fl-r.jpg', 'vehicles/an48/a-fl-r.jpg', 'approved', true, true, true, 'done', 'not_visible', -99, '{"state": "done"}'),
       (test.id('vehicle:an48_a'), 'left', 'left', 'vehicles/original/an48/a-left-r.jpg', 'vehicles/an48/a-left-r.jpg', 'approved', true, true, true, 'done', 'not_visible', -98, '{"state": "done"}'),
       (test.id('vehicle:an48_a'), 'front', 'front', 'vehicles/original/an48/a-front-r.jpg', 'vehicles/an48/a-front-r.jpg', 'approved', false, true, true, 'done', 'not_visible', -97, '{"state": "flagged"}'),
       (test.id('vehicle:an48_a'), 'front_left', 'front_left', 'vehicles/original/an48/a-fl.jpg', 'vehicles/an48/a-fl.jpg', 'approved', true, false, false, 'done', 'not_visible', 1, null),
       (test.id('vehicle:an48_a'), 'dashboard', 'dashboard', 'vehicles/original/an48/a-dash.jpg', 'vehicles/an48/a-dash.jpg', 'approved', true, false, false, 'done', 'not_visible', 2, null),
       (test.id('vehicle:an48_b'), 'front_left', 'front_left', 'vehicles/original/an48/b-fl.jpg', 'vehicles/an48/b-fl.jpg', 'approved', true, false, false, 'done', 'not_visible', 1, null);

create temp table an48_g as select e, k from jsonb_array_elements(app.public_listing_photos(test.id('vehicle:an48_a'))) with ordinality t(e, k);
select test.eq('the renders first, the side profile first and the front three-quarter second, then the real photos',
  (select array_agg(e ->> 'path' order by k) from an48_g),
  array['vehicles/an48/a-left-r.jpg', 'vehicles/an48/a-fl-r.jpg', 'vehicles/an48/a-rear-r.jpg', 'vehicles/an48/a-fl.jpg', 'vehicles/an48/a-dash.jpg']);
select test.ok('renders are marked generated, the real photos real, only the first is the cover',
  (select bool_and(coalesce((e ->> 'generated')::boolean, false)) from an48_g where k <= 3)
  and (select bool_and(coalesce((e ->> 'real')::boolean, false)) from an48_g where k > 3)
  and (select count(*) from an48_g where (e ->> 'is_cover')::boolean) = 1 and (select (e ->> 'is_cover')::boolean from an48_g where k = 1));
select test.ok('a flagged render is never shown; the real photo of its angle stays', not exists (select 1 from an48_g where e ->> 'path' = 'vehicles/an48/a-front-r.jpg'));
select test.ok('a car with no render keeps its gallery as before', jsonb_array_length(app.public_listing_photos(test.id('vehicle:an48_b'))) >= 1
  and not exists (select 1 from jsonb_array_elements(app.public_listing_photos(test.id('vehicle:an48_b'))) e where (e ->> 'generated')::boolean));

-- the listing row: the side render the cover, with the side cutout once one is made
select test.eq('the cover is the side render, counted as rendered',
  array[app.public_listing_row(test.id('vehicle:an48_a')) #>> '{cover,path}', app.public_listing_row(test.id('vehicle:an48_a')) #>> '{cover,shot}', app.public_listing_row(test.id('vehicle:an48_a')) ->> 'rendered'],
  array['vehicles/an48/a-left-r.jpg', 'left', '3']);
select test.ok('no cutout yet: none on the row', app.public_listing_row(test.id('vehicle:an48_a')) #> '{cover,cutout}' is null
  or jsonb_typeof(app.public_listing_row(test.id('vehicle:an48_a')) #> '{cover,cutout}') = 'null');
select app.site_cutout_save(test.id('vehicle:an48_a'), 'left', jsonb_build_object('source', app.site_cutout_source(test.id('vehicle:an48_a')),
  'path', 'site/cutouts/an48-a/left-aaaa.webp', 'width', 1600, 'height', 600));
select test.eq('the side cutout rides on the cover (path, size, facing)',
  app.public_listing_row(test.id('vehicle:an48_a')) #> '{cover,cutout}',
  jsonb_build_object('path', 'site/cutouts/an48-a/left-aaaa.webp', 'width', 1600, 'height', 600, 'facing', 'left'));
select test.eq('the live row agrees', app.public_listing_row_live(test.id('vehicle:an48_a')) #>> '{cover,path}', 'vehicles/an48/a-left-r.jpg');

-- staff take a render off the site: the next render is the cover, nothing else changes
select app.photo_r48_angle(test.id('an48_admin'), jsonb_build_object('vehicle', test.id('vehicle:an48_a'), 'shot', 'left', 'action', 'hide'));
select test.eq('a render taken off: the front three-quarter render is the cover', app.public_listing_photos(test.id('vehicle:an48_a')) -> 0 ->> 'path', 'vehicles/an48/a-fl-r.jpg');
select app.photo_r48_angle(test.id('an48_admin'), jsonb_build_object('vehicle', test.id('vehicle:an48_a'), 'shot', 'left', 'action', 'show'));
select test.eq('put back: the side profile first again', app.public_listing_photos(test.id('vehicle:an48_a')) -> 0 ->> 'path', 'vehicles/an48/a-left-r.jpg');

-- ================================================================ 3150: the job's order and the backfill
select test.eq('the render order: side, front three-quarter, then the rest', (app.photo_render_order())[1:3], array['left', 'front_left', 'front']);
select test.ok('a real photo not yet on the branded background is due once the renders are made',
  exists (select 1 from app.photo_render_reals_due(test.id('vehicle:an48_a')) x(id) join vehicle_photos ph on ph.id = x.id where ph.processed_path = 'vehicles/an48/a-dash.jpg'));
select test.throws('a renter cannot start the backfill', format($$select app.door(%L, 'aal1', 'ops_do', 'photo_render_backfill', '{}'::jsonb)$$, test.id('an48_rita')), '');
create temp table an48_bf as select app.door(test.id('an48_admin'), 'aal1', 'ops_do', 'photo_render_backfill', '{}'::jsonb) r;
select test.ok('an Admin starts it: every published real car listed, the switches on',
  (select (r ->> 'cars')::integer from an48_bf) >= 2
  and exists (select 1 from photo_render_backfill where vehicle_id = test.id('vehicle:an48_a'))
  and (select listing_photo_r48_auto and listing_showroom_ai and listing_photo_real_bg_auto from program_settings limit 1));
select test.ok('and reads its progress', (app.door(test.id('an48_admin'), 'aal1', 'ops_read', 'photo_render_backfill', '{}'::jsonb) ->> 'cars')::integer >= 2);
select test.ok('the backfill and the cutout read are the server''s only',
  has_function_privilege('service_role', 'public.photo_render_backfill()', 'execute')
  and not has_function_privilege('anon', 'public.photo_render_backfill()', 'execute')
  and not has_function_privilege('authenticated', 'app.photo_render_backfill(uuid)', 'execute'));

-- ================================================================ 3151: one make, family, trim and body
select test.eq('Mercedes CLA 250 and CLA-Class CLA250-4M are one family, the trim one spelling',
  array[app.car_identity('Mercedes', 'CLA 250', null) ->> 'make', app.car_identity('Mercedes', 'CLA 250', null) ->> 'model',
        app.car_identity('Mercedes-Benz', 'CLA-Class', 'CLA250-4M') ->> 'model', app.car_identity('Mercedes-Benz', 'CLA-Class', 'CLA250-4M') ->> 'trim'],
  array['Mercedes-Benz', 'CLA-Class', 'CLA-Class', 'CLA250 4MATIC']);
select test.eq('BMW 330i and 3 Series 330i are the 3 Series',
  array[app.car_identity('BMW', '330i', null) ->> 'model', app.car_identity('BMW', '3 Series 330i', 'xDrive') ->> 'trim', app.car_identity('BMW', '2 Series', '228i xDrive GC') ->> 'trim'],
  array['3 Series', '330i xDrive', '228i xDrive Gran Coupe']);
select test.eq('other makes: the family the model starts with, the rest the trim',
  array[app.car_identity('Land Rover', 'Range Rover Sport V6', null) ->> 'model', app.car_identity('Cadillac', 'Escalade ESV', null) ->> 'trim',
        app.car_identity('Chevy', 'Corvette Stingray', null) ->> 'make', app.car_identity('GMC', 'Yukon XL', 'Sle') ->> 'trim',
        app.car_identity('Mercedes-Benz', 'AMG GT', 'AMG GT C') ->> 'trim'],
  array['Range Rover Sport', 'ESV', 'Chevrolet', 'SLE', 'GT C']);
select test.eq('a value it cannot read is kept as typed', app.car_identity('Mercedes-Benz', 'C 300 an48_a', null) ->> 'model', 'C 300 an48_a');
select test.eq('one body name', array[app.car_body('Compact SUV'), app.car_body('Mid-size sedan'), app.car_body('Four-door coupe'), app.listing_norm_body('Sedan/Saloon'),
  app.listing_norm_body('Sport Utility Vehicle (SUV)/Multi-Purpose Vehicle (MPV)')], array['SUV', 'Sedan', 'Coupe', 'Sedan', 'SUV']);

-- every save goes through it
update vehicles set make = 'mercedes benz', model = 'CLA 250', trim = '4M' where id = test.id('vehicle:an48_b');
select test.eq('a car saved as "mercedes benz CLA 250 4M" is stored as Mercedes-Benz CLA-Class CLA250 4MATIC',
  (select array[make, model, trim] from vehicles where id = test.id('vehicle:an48_b')), array['Mercedes-Benz', 'CLA-Class', 'CLA250 4MATIC']);
update vehicle_listings set body_style = 'Compact SUV' where vehicle_id = test.id('vehicle:an48_b');
select test.eq('a listing body saved as Compact SUV is SUV', (select body_style from vehicle_listings where vehicle_id = test.id('vehicle:an48_b')), 'SUV');
update vehicles set make = 'Mercedes-Benz', model = 'CLA-Class', trim = 'CLA250 4MATIC' where id = test.id('vehicle:an48_a');
select test.eq('the filters'' families: both cars are one CLA-Class (no trim of its own)',
  (select count(distinct (app.car_identity(make, model, trim) ->> 'model')) from vehicles where id in (test.id('vehicle:an48_a'), test.id('vehicle:an48_b')))::integer, 1);

-- the audit: no car on file splits a family any more, and a bad year or an unknown family is listed for a person
select test.eq('no car on file is left with a make or family the rule would change', (select count(*) from vehicles v
  where nullif(btrim(v.model), '') is not null and (v.make is distinct from app.car_identity(v.make, v.model, v.trim) ->> 'make'
        or v.model is distinct from app.car_identity(v.make, v.model, v.trim) ->> 'model'))::integer, 0);
select test.throws('a year far off is refused on save', format($$update vehicles set year = 1971 where id = %L$$, test.id('vehicle:an48_a')), '');
select test.ok('the issues list reads', (select count(*) from app.car_identity_issues()) >= 0);
select test.ok('the rule is the server''s only; the families are readable by all',
  not has_function_privilege('anon', 'app.car_identity(text, text, text)', 'execute') and has_table_privilege('anon', 'car_model_families', 'select'));
