-- 99: release 36b item 1 (migration 2200): the missing angle made by the image model. Who may make and approve it, only a
-- required angle with no photo, the image model's switch, the worker's answer, approval before it shows, shown after the real
-- photos and labelled, never the cover, gone once a real photo arrives. Fixtures start with "rba"; addresses are example.test.
select test.suite('99 r36b missing angle (2200)');

select test.mk_user('rba_admin', 'admin');
select test.mk_user('rba_fleet', 'va', 'fleet');
select test.mk_user('rba_sales', 'va', 'sales');
select test.mk_user('rba_cs', 'va', 'cs');
select test.mk_user('rba_fin', 'va', 'finance');
select test.mk_owner('rba_olive');
select test.mk_vehicle('rba_car', 'rba_olive');
create function pg_temp.v() returns uuid language sql as $$ select test.id('vehicle:rba_car') $$;
create function pg_temp.dr(p_user text, p_call text, p_name text, p jsonb) returns jsonb language sql as
$$ select public.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;

create temp table rbai as select (app.start_listing_intake(test.id('rba_admin'), jsonb_build_object('vehicle_id', pg_temp.v())) ->> 'intake_id')::uuid as i;
create temp table rbap as select (app.record_listing_upload(test.id('rba_admin'), (select i from rbai), jsonb_build_object('shot_type', 'front_left',
  'original_path', 'vehicles/original/rba/front.jpg', 'width', 3000, 'height', 2000, 'byte_size', 900000, 'mime_type', 'image/jpeg')) ->> 'photo_id')::uuid as p;
update vehicle_photos set status = 'approved', is_public = true, is_cover = true, processed_path = 'vehicles/' || pg_temp.v() || '/front.jpg', width = 1800, height = 1200
 where id = (select p from rbap);
insert into vehicle_listings (vehicle_id) values (pg_temp.v()) on conflict (vehicle_id) do nothing;
update vehicle_listings set status = 'published', slug = coalesce(slug, 'rba-car-test') where vehicle_id = pg_temp.v();
update program_settings set listing_showroom_ai = false where id = (select id from app.settings());

-- ---------------------------------------------------------------- who and what
select test.ok('the prompt is a setting with {angle}', (select listing_angle_prompt like '%{angle}%' from app.settings()));
select test.throws('Finance may not read it', format($$select pg_temp.dr('rba_fin', 'ops_read', 'listing_angles', jsonb_build_object('vehicle', %L))$$, pg_temp.v()), 'Not permitted');
select test.throws('customer service may not make one', format($$select pg_temp.dr('rba_cs', 'ops_do', 'listing_angle_make', jsonb_build_object('vehicle', %L, 'shot', 'rear'))$$, pg_temp.v()), 'An Admin, Fleet or Sales');
select test.ok('Sales reads the missing angles (rear is missing, front left is taken)',
  (select (r -> 'missing') @> '[{"shot": "rear"}]' and not ((r -> 'missing') @> '[{"shot": "front_left"}]') from (select pg_temp.dr('rba_sales', 'ops_read', 'listing_angles', jsonb_build_object('vehicle', pg_temp.v())) r) x));
select test.throws('the image model off: refused (free credit only)', format($$select pg_temp.dr('rba_fleet', 'ops_do', 'listing_angle_make', jsonb_build_object('vehicle', %L, 'shot', 'rear'))$$, pg_temp.v()), 'image model is off');
update program_settings set listing_showroom_ai = true where id = (select id from app.settings());
select test.throws('an angle already photographed is refused', format($$select pg_temp.dr('rba_fleet', 'ops_do', 'listing_angle_make', jsonb_build_object('vehicle', %L, 'shot', 'front_left'))$$, pg_temp.v()), 'real photo always wins');
select test.throws('the odometer (not shown on the site) is refused', format($$select pg_temp.dr('rba_fleet', 'ops_do', 'listing_angle_make', jsonb_build_object('vehicle', %L, 'shot', 'odometer'))$$, pg_temp.v()), 'Only a required angle');
select pg_temp.dr('rba_fleet', 'ops_do', 'listing_angle_make', jsonb_build_object('vehicle', pg_temp.v(), 'shot', 'rear'));
select test.eq('Fleet makes the rear: one angle job, made from the approved front-left photo', (select count(*)::int from listing_jobs where vehicle_id = pg_temp.v() and kind = 'angle_make'
  and input #>> '{angle,sources,0}' = 'vehicles/' || pg_temp.v() || '/front.jpg' and input #>> '{angle,prompt}' like '%rear view%'), 1);
select test.ok('marked generated, queued', (select generated and status = 'queued' from listing_angle_makes where vehicle_id = pg_temp.v() and shot_type = 'rear'));
select test.throws('not twice at once', format($$select pg_temp.dr('rba_sales', 'ops_do', 'listing_angle_make', jsonb_build_object('vehicle', %L, 'shot', 'rear'))$$, pg_temp.v()), 'already being made');
select test.throws('the generated flag cannot be cleared', $$update listing_angle_makes set generated = false where shot_type = 'rear' and vehicle_id = pg_temp.v()$$, 'check');

-- ---------------------------------------------------------------- the worker's answer
update listing_jobs set status = 'running', locked_at = now(), attempts = 1 where vehicle_id = pg_temp.v() and kind = 'angle_make';
create temp table rbam as select id from listing_angle_makes where vehicle_id = pg_temp.v() and shot_type = 'rear';
select app.worker_listing_result((select id from listing_jobs where vehicle_id = pg_temp.v() and kind = 'angle_make'), jsonb_build_object('ok', true, 'provider', 'ai',
  'output', jsonb_build_object('angle', jsonb_build_object('id', (select id from rbam), 'status', 'made', 'path', 'vehicles/' || pg_temp.v() || '/generated/' || (select id from rbam) || '.jpg', 'width', 1536, 'height', 1024, 'provider', 'ai'))));
select test.eq('made, waiting for approval', (select status from listing_angle_makes where id = (select id from rbam)), 'made');
select test.eq('not on the site before approval', (select count(*)::int from jsonb_array_elements(app.public_listing_photos(pg_temp.v())) e where (e ->> 'generated')::boolean), 0);
select test.throws('Finance may not approve it', format($$select pg_temp.dr('rba_fin', 'ops_do', 'listing_angle_decide', jsonb_build_object('id', %L, 'action', 'approve'))$$, (select id from rbam)), 'An Admin, Fleet or Sales');
select pg_temp.dr('rba_sales', 'ops_do', 'listing_angle_decide', jsonb_build_object('id', (select id from rbam), 'action', 'approve'));
select test.eq('Sales approves it: recorded who', (select status || ' ' || (reviewed_by = test.id('rba_sales'))::text from listing_angle_makes where id = (select id from rbam)), 'approved true');
select test.eq('the site shows it after the real photo, labelled AI view, never the cover',
  (select format('%s|%s|%s|%s', app.public_listing_photos(pg_temp.v()) -> 0 ->> 'path' = 'vehicles/' || pg_temp.v() || '/front.jpg',
     app.public_listing_photos(pg_temp.v()) -> -1 ->> 'label', app.public_listing_photos(pg_temp.v()) -> -1 ->> 'is_cover', app.public_listing_photos(pg_temp.v()) -> -1 ->> 'generated')),
  't|Rear (AI view)|false|true');
select test.eq('the cover photo is still the real photo', (app.cover_photo(pg_temp.v())).processed_path, 'vehicles/' || pg_temp.v() || '/front.jpg');
select test.eq('no vehicle photo (handover, condition and claim evidence) was made from it', (select count(*)::int from vehicle_photos where vehicle_id = pg_temp.v() and processed_path like '%/generated/%'), 0);

-- a real rear photo arrives: the real one wins, the generated view leaves the site
insert into rbap select (app.record_listing_upload(test.id('rba_admin'), (select i from rbai), jsonb_build_object('shot_type', 'rear',
  'original_path', 'vehicles/original/rba/rear.jpg', 'width', 3000, 'height', 2000, 'byte_size', 900000, 'mime_type', 'image/jpeg')) ->> 'photo_id')::uuid;
select test.eq('a real rear photo: the AI view is not shown', (select count(*)::int from jsonb_array_elements(app.public_listing_photos(pg_temp.v())) e where (e ->> 'generated')::boolean), 0);
select pg_temp.dr('rba_admin', 'ops_do', 'listing_angle_decide', jsonb_build_object('id', (select id from rbam), 'action', 'reject'));
select test.eq('the Admin rejects it', (select status from listing_angle_makes where id = (select id from rbam)), 'rejected');
select test.throws('functions are not callable by signed-in users directly', $$set local role authenticated; select app.listing_angle_make(gen_random_uuid(), '{}')$$, 'permission denied');
