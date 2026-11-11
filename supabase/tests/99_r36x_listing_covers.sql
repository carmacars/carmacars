-- 99: release 36 helper X (migration 2100): the listing's first photo (plain, with a model, or the flyer). Who may choose it,
-- the job it queues, the worker's answer, the site and the Marketplace showing it first only while it is current (the flyer
-- follows the live price), and the settings it is made from. Fixtures start with "rxc"; every address is example.test.
select test.suite('99 r36x listing covers (2100)');

select test.mk_user('rxc_admin', 'admin');
select test.mk_user('rxc_sales', 'va', 'sales');
select test.mk_user('rxc_fin', 'va', 'finance');
select test.mk_owner('rxc_olive');
select test.mk_vehicle('rxc_car', 'rxc_olive');

create temp table rxci as select (app.start_listing_intake(test.id('rxc_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:rxc_car'))) ->> 'intake_id')::uuid as i;
create temp table rxcp as select (app.record_listing_upload(test.id('rxc_admin'), (select i from rxci), jsonb_build_object('shot_type', 'front_left',
  'original_path', 'vehicles/original/rxc/front.jpg', 'width', 3000, 'height', 2000, 'byte_size', 900000, 'mime_type', 'image/jpeg')) ->> 'photo_id')::uuid as p;
update vehicle_photos set status = 'approved', is_public = true, is_cover = true, processed_path = 'vehicles/' || test.id('vehicle:rxc_car') || '/front.jpg',
       width = 1800, height = 1200, cutout = jsonb_build_object('mask', 'vehicles/x/work/mask.png')
 where id = (select p from rxcp);
insert into vehicle_listings (vehicle_id) values (test.id('vehicle:rxc_car')) on conflict (vehicle_id) do nothing;
update vehicle_listings set status = 'published', slug = coalesce(slug, 'rxc-car-test') where vehicle_id = test.id('vehicle:rxc_car');

create function pg_temp.dr(p_user text, p_call text, p_name text, p jsonb) returns jsonb language sql as
$$ select public.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;

-- ---------------------------------------------------------------- settings and the default
select test.eq('plain by default', (select cover_style from vehicle_listings where vehicle_id = test.id('vehicle:rxc_car')), 'plain');
select test.ok('the model words are a setting and keep "fully clothed" and "adult"',
  (select listing_cover_model_prompt ~* 'fully clothed' and listing_cover_model_prompt ~* 'adult' from app.settings()));
select test.throws('the flyer''s colours are checked', $$update program_settings set listing_cover_flyer = listing_cover_flyer || '{"accent": "red"}' where id = (select id from app.settings())$$, 'check');
select test.eq('the flyer words are filled for the car (with no live price the price line is left out)',
  (select (s ->> 'headline') <> '' and ((s ->> 'offer') = '' or (s ->> 'offer') ~ '^From \$[0-9,.]+ a day$') and (s ->> 'cta') = 'Book at carmacars.ca' from (select app.cover_flyer_spec(test.id('vehicle:rxc_car')) s) x), true);

-- ---------------------------------------------------------------- who chooses
select test.throws('Finance does not choose the first photo', format($$select pg_temp.dr('rxc_fin', 'ops_do', 'listing_cover_set', jsonb_build_object('vehicle', %L, 'style', 'flyer'))$$, test.id('vehicle:rxc_car')), 'chooses the first photo');
select test.throws('an unknown style is refused', format($$select pg_temp.dr('rxc_admin', 'ops_do', 'listing_cover_set', jsonb_build_object('vehicle', %L, 'style', 'poster'))$$, test.id('vehicle:rxc_car')), 'plain, with a model or a flyer');
create temp table rxc_set as select pg_temp.dr('rxc_sales', 'ops_do', 'listing_cover_set', jsonb_build_object('vehicle', test.id('vehicle:rxc_car'), 'style', 'flyer')) r;
select test.eq('Sales chooses the flyer', (select r ->> 'style' from rxc_set), 'flyer');
select test.eq('one flyer job queued with the words filled in', (select count(*)::int from listing_jobs where vehicle_id = test.id('vehicle:rxc_car') and kind = 'cover_flyer' and input #>> '{cover,flyer,cta}' = 'Book at carmacars.ca'), 1);
select pg_temp.dr('rxc_sales', 'ops_do', 'listing_cover_set', jsonb_build_object('vehicle', test.id('vehicle:rxc_car'), 'style', 'flyer'));
select test.eq('choosing it again does not queue it twice', (select count(*)::int from listing_covers where vehicle_id = test.id('vehicle:rxc_car') and style = 'flyer'), 1);
select test.eq('until it is made the site shows the plain cover', (app.public_listing_photos(test.id('vehicle:rxc_car')) -> 0 ->> 'path'), 'vehicles/' || test.id('vehicle:rxc_car') || '/front.jpg');

-- ---------------------------------------------------------------- the worker's answer
update listing_jobs set status = 'running', locked_at = now(), attempts = 1 where vehicle_id = test.id('vehicle:rxc_car') and kind = 'cover_flyer';
select app.worker_listing_result((select id from listing_jobs where vehicle_id = test.id('vehicle:rxc_car') and kind = 'cover_flyer'), jsonb_build_object('ok', true, 'provider', 'carmacars',
  'output', jsonb_build_object('cover', jsonb_build_object('status', 'made', 'path', 'vehicles/' || test.id('vehicle:rxc_car') || '/cover/f1.jpg', 'width', 1800, 'height', 1200))));
select test.eq('made', (select status from listing_covers where vehicle_id = test.id('vehicle:rxc_car') and style = 'flyer'), 'made');
select test.eq('the site shows the flyer first', (app.public_listing_photos(test.id('vehicle:rxc_car')) -> 0 ->> 'path'), 'vehicles/' || test.id('vehicle:rxc_car') || '/cover/f1.jpg');
select test.eq('and keeps the plain cover right after it', (app.public_listing_photos(test.id('vehicle:rxc_car')) -> 1 ->> 'path'), 'vehicles/' || test.id('vehicle:rxc_car') || '/front.jpg');
select test.eq('the cards'' cover too', (app.public_listing_row(test.id('vehicle:rxc_car')) #>> '{cover,path}'), 'vehicles/' || test.id('vehicle:rxc_car') || '/cover/f1.jpg');

-- the words change (or the price): the flyer is out of date, the plain cover shows, and the job makes it again
update program_settings set listing_cover_flyer = listing_cover_flyer || '{"cta": "Rent it today"}' where id = (select id from app.settings());
select test.eq('changed words: the plain cover shows again', (app.public_listing_photos(test.id('vehicle:rxc_car')) -> 0 ->> 'path'), 'vehicles/' || test.id('vehicle:rxc_car') || '/front.jpg');
select test.eq('the job queues a new flyer', app.job_listing_covers(), 1);
select test.eq('with the new words', (select input #>> '{cover,flyer,cta}' from listing_jobs where vehicle_id = test.id('vehicle:rxc_car') and kind = 'cover_flyer' and status = 'queued'), 'Rent it today');

-- the live price: a new rate is in the flyer's words (so a flyer made before it is out of date)
create temp table rxc_key as select app.cover_flyer_key(test.id('vehicle:rxc_car')) k;
update rate_cards set daily_rate_cents = daily_rate_cents + 500 where vehicle_id = test.id('vehicle:rxc_car');
select test.eq('the new price is in the offer', app.cover_flyer_spec(test.id('vehicle:rxc_car')) ->> 'offer', 'From $105 a day');
select test.ok('and the flyer''s key changes with it', app.cover_flyer_key(test.id('vehicle:rxc_car')) <> (select k from rxc_key));

-- with a model: the image model's words from the settings; back to plain at any time
select pg_temp.dr('rxc_admin', 'ops_do', 'listing_cover_set', jsonb_build_object('vehicle', test.id('vehicle:rxc_car'), 'style', 'model'));
select test.ok('the model job carries the settings'' words', (select input #>> '{cover,prompt}' ~* 'fully clothed' from listing_jobs where vehicle_id = test.id('vehicle:rxc_car') and kind = 'cover_model'));
update listing_jobs set status = 'running', locked_at = now(), attempts = 1 where vehicle_id = test.id('vehicle:rxc_car') and kind = 'cover_model';
select app.worker_listing_result((select id from listing_jobs where vehicle_id = test.id('vehicle:rxc_car') and kind = 'cover_model'), jsonb_build_object('ok', true, 'provider', 'carmacars',
  'output', jsonb_build_object('cover', jsonb_build_object('status', 'made', 'path', 'site/elsewhere.jpg'))));
select test.eq('a file outside the car''s cover folder is not kept', (select status from listing_covers where vehicle_id = test.id('vehicle:rxc_car') and style = 'model'), 'failed');
select pg_temp.dr('rxc_admin', 'ops_do', 'listing_cover_set', jsonb_build_object('vehicle', test.id('vehicle:rxc_car'), 'style', 'plain'));
select test.eq('plain again: the cover photo first', (app.public_listing_photos(test.id('vehicle:rxc_car')) -> 0 ->> 'path'), 'vehicles/' || test.id('vehicle:rxc_car') || '/front.jpg');
select test.eq('the read says what is chosen', (pg_temp.dr('rxc_sales', 'va_read', 'listing_cover', jsonb_build_object('vehicle', test.id('vehicle:rxc_car'))) ->> 'style'), 'plain');
select test.ok('the functions are the server''s only', not has_function_privilege('authenticated', 'app.listing_cover_set(uuid, jsonb)', 'execute')
  and not has_function_privilege('anon', 'app.job_listing_covers()', 'execute'));
