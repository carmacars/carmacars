-- 99: the listing page's plain steps and its photos (migration 0521): the four steps "Photos (n of 14) > Cover plates >
-- Review > Live on the site" with what each needs, a photo filed under the wrong shot taken off (kept, audited, never on
-- a live listing), and two-seaters needing no rear seats photo. Fixtures start with "lsp"; every address is example.test.
select test.suite('99 listing steps and photos');

select test.mk_user('lsp_admin', 'admin');
select test.mk_user('lsp_fin', 'va', 'finance');
select test.mk_owner('lsp_olive');
select test.mk_vehicle('lsp_car', 'lsp_olive');
select test.mk_vehicle('lsp_two', 'lsp_olive');
create temp table s99ls as select (app.start_listing_intake(test.id('lsp_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:lsp_car'))) ->> 'intake_id')::uuid as car,
  (app.start_listing_intake(test.id('lsp_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:lsp_two'))) ->> 'intake_id')::uuid as two;
create or replace function test.lsp_up(p_intake uuid, p_shot text) returns uuid language sql as $$
  select (app.record_listing_upload(test.id('lsp_admin'), p_intake, jsonb_build_object('shot_type', p_shot,
          'original_path', 'vehicles/original/' || p_intake || '/' || p_shot || '-' || md5(random()::text) || '.jpg', 'width', 3000, 'height', 2000,
          'byte_size', 900000, 'mime_type', 'image/jpeg')) ->> 'photo_id')::uuid $$;
create or replace function test.lsp_steps(p_intake uuid) returns jsonb language sql as $$
  select app.door(test.id('lsp_admin'), 'aal2', 'ops_read', 'listing_steps', jsonb_build_object('intake', p_intake)) $$;

-- ================================================================ the steps
select test.eq('a new listing: step 1, "Photos (0 of 14)", what to do',
  (select format('%s | %s | %s', s ->> 'current', s #>> '{steps,0,title}', s #>> '{steps,0,need}') from (select test.lsp_steps(car) s from s99ls) x),
  '1 | Photos (0 of 14) | Take the photos on the shot list, or submit to start with sample photos.');
select test.eq('four steps, in order', (select string_agg(x ->> 'title', ' > ' order by (x ->> 'n')::int) from s99ls, jsonb_array_elements(test.lsp_steps(car) -> 'steps') x),
  'Photos (0 of 14) > Cover plates > Review > Live on the site');
select test.lsp_up(car, 'front_left') from s99ls;
select test.ok('a photo in: 1 of 14, the missing ones named', (select s #>> '{steps,0,title}' = 'Photos (1 of 14)' and s #>> '{steps,0,need}' like '%Missing: Front, Left side%'
  from (select test.lsp_steps(car) s from s99ls) x));
select test.throws('finance may not read a listing''s steps', format($$select app.door(%L, 'aal2', 'ops_read', 'listing_steps', '{"intake": "%s"}')$$, test.id('lsp_fin'), (select car from s99ls)), 'Not permitted');

-- ================================================================ a photo filed under the wrong shot
select test.lsp_up(car, 'front') as wrong from s99ls \gset
select test.eq('taken off: the shot is missing again',
  (select app.door(test.id('lsp_admin'), 'aal2', 'ops_do', 'listing_photo_remove', jsonb_build_object('photo', :'wrong')) -> 'missing' ? 'Front'), true);
select test.ok('the file is kept, marked replaced, and the removal is audited',
  (select replaced_at is not null from vehicle_photos where id = :'wrong')
  and exists (select 1 from audit_log where action = 'listing_photo_remove' and entity_id = :'wrong' and actor_user_id = test.id('lsp_admin')));
select test.ok('the capture screen no longer lists it',
  not exists (select 1 from s99ls, jsonb_array_elements(app.listing_capture(test.id('lsp_admin'), car) -> 'shots') s, jsonb_array_elements(s -> 'photos') p where p ->> 'id' = :'wrong'));
select test.throws('twice is refused', format($$select app.listing_photo_remove(%L, '{"photo": "%s"}')$$, test.id('lsp_admin'), :'wrong'), 'already taken off');
select test.throws('finance may not take photos off', format($$select app.listing_photo_remove(%L, '{"photo": "%s"}')$$, test.id('lsp_fin'), (select test.lsp_up(car, 'left') from s99ls)), 'Not permitted');
insert into vehicle_listings (vehicle_id, status, slug) values (test.id('vehicle:lsp_car'), 'published', 'ls-car-test')
on conflict (vehicle_id) do update set status = 'published', slug = 'ls-car-test';
select test.throws('a live listing''s photos change in the review instead',
  format($$select app.listing_photo_remove(%L, '{"photo": "%s"}')$$, test.id('lsp_admin'), (select id from vehicle_photos where vehicle_id = test.id('vehicle:lsp_car') and shot_type = 'front_left' and replaced_at is null limit 1)),
  'reject the photo in the review');
select test.eq('live: step 4 done, the address given', (select format('%s %s %s', s ->> 'live', s #>> '{steps,3,done}', s ->> 'slug') from (select test.lsp_steps(car) s from s99ls) x), 'true true ls-car-test');
update vehicle_listings set status = 'draft' where vehicle_id = test.id('vehicle:lsp_car');

-- ================================================================ two-seaters
insert into vehicle_listings (vehicle_id, status, seats) values (test.id('vehicle:lsp_two'), 'draft', 2)
on conflict (vehicle_id) do update set seats = 2;
select test.ok('a two-seater: rear seats not required (13 required)', (select s #>> '{steps,0,title}' = 'Photos (0 of 13)' from (select test.lsp_steps(two) s from s99ls) x));
select test.ok('not in the missing shots', not ('Rear seats' = any (app.listing_missing_shots(test.id('vehicle:lsp_two')))));
select test.ok('the capture screen marks it optional', (select not (s ->> 'required')::boolean from s99ls, jsonb_array_elements(app.listing_capture(test.id('lsp_admin'), two) -> 'shots') s where s ->> 'code' = 'rear_seats'));
select test.ok('no photo problem for it', not exists (select 1 from unnest(app.listing_photo_problems(test.id('vehicle:lsp_two'))) x where x like 'Rear seats%'));
select test.ok('a five-seater still needs it', 'Rear seats' = any (app.listing_missing_shots(test.id('vehicle:lsp_car'))));
