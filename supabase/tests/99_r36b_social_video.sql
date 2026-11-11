-- 99: release 36b item 2 (migration 2210): the short video of a car. Who may make it, the photos it is made from (real,
-- approved, on the site; never a generated view), the words and the price from Program settings, the saved file's folder and
-- type, removal. Fixtures start with "rbv"; addresses are example.test.
select test.suite('99 r36b social video (2210)');

select test.mk_user('rbv_admin', 'admin');
select test.mk_user('rbv_sales', 'va', 'sales');
select test.mk_user('rbv_fin', 'va', 'finance');
select test.mk_owner('rbv_olive');
select test.mk_vehicle('rbv_car', 'rbv_olive');
create function pg_temp.v() returns uuid language sql as $$ select test.id('vehicle:rbv_car') $$;
create function pg_temp.dr(p_user text, p_call text, p_name text, p jsonb) returns jsonb language sql as
$$ select public.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;
create temp table rbvi as select (app.start_listing_intake(test.id('rbv_admin'), jsonb_build_object('vehicle_id', pg_temp.v())) ->> 'intake_id')::uuid as i;
create temp table rbvp as select (app.record_listing_upload(test.id('rbv_admin'), (select i from rbvi), jsonb_build_object('shot_type', 'front_left',
  'original_path', 'vehicles/original/rbv/front.jpg', 'width', 3000, 'height', 2000, 'byte_size', 900000, 'mime_type', 'image/jpeg')) ->> 'photo_id')::uuid as p;
update vehicle_photos set status = 'approved', is_public = true, is_cover = true, processed_path = 'vehicles/' || pg_temp.v() || '/front.jpg', width = 1800, height = 1200 where id = (select p from rbvp);
insert into vehicle_listings (vehicle_id) values (pg_temp.v()) on conflict (vehicle_id) do nothing;
update vehicle_listings set status = 'published', slug = coalesce(slug, 'rbv-car-test') where vehicle_id = pg_temp.v();
-- an approved generated view of the rear (2200) is on the site but never in a video
insert into listing_angle_makes (vehicle_id, shot_type, sources, status, path, reviewed_by, reviewed_at)
values (pg_temp.v(), 'rear', array[(select p from rbvp)], 'approved', 'vehicles/' || pg_temp.v() || '/generated/' || gen_random_uuid() || '.jpg', test.id('rbv_admin'), now());

select test.eq('settings: brand, 2.5 seconds a photo, 8 photos at most', (select format('%s %s %s', social_video_brand, social_video_seconds_per_photo, social_video_max_photos) from app.settings()), 'CarmaCars 2.5 8');
select test.throws('Finance does not make videos', format($$select pg_temp.dr('rbv_fin', 'ops_read', 'social_video_kit', jsonb_build_object('vehicle', %L))$$, pg_temp.v()), 'makes social videos');
create temp table rbvk as select pg_temp.dr('rbv_sales', 'ops_read', 'social_video_kit', jsonb_build_object('vehicle', pg_temp.v())) k;
select test.eq('Sales reads the kit: the real photo only (never the AI view)', (select k -> 'photos' from rbvk), jsonb_build_array('vehicles/' || pg_temp.v() || '/front.jpg'));
select test.ok('the call to action is filled from the live price, or the price part left out',
  (select case when k ->> 'price' is null then k ->> 'cta' = 'Book at carmacars.ca' else k ->> 'cta' = 'From ' || (k ->> 'price') || ' a day · Book at carmacars.ca' end from rbvk));
select test.throws('a file outside the car''s social folder is refused', format($$select pg_temp.dr('rbv_sales', 'ops_do', 'social_video_save', jsonb_build_object('vehicle', %L, 'path', 'vehicles/x/social/a.mp4', 'mime', 'video/mp4', 'seconds', 10, 'bytes', 1000))$$, pg_temp.v()), 'social folder');
select test.throws('only mp4 or webm', format($$select pg_temp.dr('rbv_sales', 'ops_do', 'social_video_save', jsonb_build_object('vehicle', %L, 'path', 'vehicles/%s/social/%s.mp4', 'mime', 'video/quicktime', 'seconds', 10, 'bytes', 1000))$$, pg_temp.v(), pg_temp.v(), gen_random_uuid()), 'check');
create temp table rbvs as select pg_temp.dr('rbv_sales', 'ops_do', 'social_video_save', jsonb_build_object('vehicle', pg_temp.v(), 'path', 'vehicles/' || pg_temp.v() || '/social/' || gen_random_uuid() || '.mp4', 'mime', 'video/mp4', 'seconds', 12.5, 'bytes', 4000000)) r;
select test.eq('Sales saves the video: listed with who made it', (select count(*)::int from social_videos where vehicle_id = pg_temp.v() and created_by = test.id('rbv_sales') and seconds = 12.5), 1);
select test.eq('and the kit lists it', (select jsonb_array_length(r -> 'videos') from rbvs), 1);
select test.throws('Finance does not remove it', format($$select pg_temp.dr('rbv_fin', 'ops_do', 'social_video_remove', jsonb_build_object('id', %L))$$, (select r ->> 'saved' from rbvs)), 'makes social videos');
select test.eq('the Admin removes it', (select jsonb_array_length(pg_temp.dr('rbv_admin', 'ops_do', 'social_video_remove', jsonb_build_object('id', (select r ->> 'saved' from rbvs))) -> 'videos')), 0);
