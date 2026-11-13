-- 99: release 35, part S2 (migrations 1050 to 1053; docs/changes/2026-11-08-r35-showroom-v2-shift-jobs.md): field jobs on
-- shifts (who does them, claiming, sharing, giving up, swapping, Fleet's moves, the alert), the showroom v2 and the image model's
-- limit, failed photos made again, and marketing scenes. Fixtures start with "s2"; every address is example.test.
select test.suite('99 r35s2 shift jobs, showroom v2, photos, marketing scenes');
grant usage on schema test to service_role;

delete from field_shift_offers; delete from field_shift_plans;
select set_config('app.fx_no_slot', 'on', false); update field_jobs set shift_slot_id = null where shift_slot_id is not null; select set_config('app.fx_no_slot', 'off', false);
delete from field_shift_slots;
-- the open field work other suites left is closed, so only this suite's jobs go on these shifts
update field_jobs set status = 'cancelled' where status in ('scheduled', 'acknowledged');
create temp table s2_prev as select field_jobs_auto_assign as aa, academy_gate as gate, field_jobs_auto as fa from app.settings();
update program_settings set field_jobs_auto_assign = 'least_busy', academy_gate = true, field_jobs_auto = false where id = (select id from app.settings());
select test.mk_user('s2_admin', 'admin');
select test.mk_user('s2_fleet', 'va', 'fleet');
select test.mk_user('s2_cs', 'va', 'cs');
select test.mk_user('s2_a', 'field');
select test.mk_user('s2_b', 'field');
select test.mk_user('s2_c', 'field');
select test.mk_owner('s2_o');
select test.mk_vehicle('S2CAR', 's2_o', 'managed', 45000, 2500, 3500, date '2026-08-01');
create function test.s2_ops(p_who text, p_name text, p jsonb) returns jsonb language sql as $$ select public.door(test.id(p_who), null, 'ops_do', p_name, p) $$;
create function test.s2_fd(p_who text, p_name text, p jsonb default '{}') returns jsonb language sql as $$ select public.door(test.id(p_who), null, 'field_do', p_name, p) $$;
create function test.s2_at(p_days integer, p_hour integer) returns timestamptz language sql as $$
  select ((app.today() + p_days)::timestamp + make_interval(hours => p_hour)) at time zone 'America/Toronto' $$;
create function test.s2_slot(p_days integer, p_hour integer) returns uuid language sql as $$
  select id from field_shift_slots where starts_at = test.s2_at(p_days, p_hour) and cancelled_at is null order by created_at desc limit 1 $$;
create function test.s2_job(p_kind text, p_at timestamptz) returns uuid language sql as $$
  insert into field_jobs (kind, vehicle_id, scheduled_at, auto_created) values (p_kind, test.id('vehicle:S2CAR'), p_at, true) returning id $$;
create function test.s2_who(p_job uuid) returns text language sql as $$
  select coalesce((select split_part(u.full_name, ' ', 2) from field_jobs j join users u on u.id = j.assigned_to where j.id = p_job), 'nobody') $$;

-- ================================================================ shifts with jobs
select test.s2_ops('s2_fleet', 'field_slot_publish', jsonb_build_object('starts_at', test.s2_at(1, 9), 'ends_at', test.s2_at(1, 17), 'capacity', 2));
select test.s2_ops('s2_fleet', 'field_slot_publish', jsonb_build_object('starts_at', test.s2_at(2, 9), 'ends_at', test.s2_at(2, 13), 'capacity', 1));
select test.s2_ops('s2_fleet', 'field_slot_publish', jsonb_build_object('starts_at', test.s2_at(2, 14), 'ends_at', test.s2_at(2, 20), 'capacity', 1));
create temp table s2j as select test.s2_job('handover', test.s2_at(1, 10)) as h, test.s2_job('detail', test.s2_at(1, 12)) as d, test.s2_job('return_check_in', test.s2_at(1, 15)) as r,
  test.s2_job('detail', test.s2_at(2, 16)) as late, test.s2_job('photo_shoot', test.s2_at(2, 21)) as night, test.s2_job('detail', test.s2_at(3, 10)) as nextday,
  test.s2_job('detail', test.s2_at(2, 10)) as morning;
grant select on s2j to public;
select test.eq('a job goes on the shift covering its time', (select shift_slot_id from field_jobs where id = (select h from s2j)), test.s2_slot(1, 9));
select test.eq('nobody on the shift: the job waits on it with nobody', test.s2_who((select h from s2j)), 'nobody');
select test.eq('two shifts that day: the one covering its time', (select shift_slot_id from field_jobs where id = (select late from s2j)), test.s2_slot(2, 14));
select test.eq('after both: the nearest', (select shift_slot_id from field_jobs where id = (select night from s2j)), test.s2_slot(2, 14));
select test.eq('a day without shifts, known ahead: the day before (0880''s rule), on the shift of its hour, its real time kept',
  (select (shift_slot_id = test.s2_slot(2, 9))::text || '/' || work_day::text || '/' || (scheduled_at = test.s2_at(3, 10))::text from field_jobs where id = (select nextday from s2j)),
  'true/' || (app.today() + 2)::text || '/true');
select test.eq('an open shift shows its jobs to field staff looking for one: 1 pickup, 1 return, 1 clean',
  (select (o -> 'jobs' ->> 'pickups') || '/' || (o -> 'jobs' ->> 'returns') || '/' || (o -> 'jobs' ->> 'cleans')
     from jsonb_array_elements(public.door(test.id('s2_a'), null, 'field_read', 'my_shifts', '{}') -> 'open') o where (o ->> 'id')::uuid = test.s2_slot(1, 9)), '1/1/1');

-- ================================================================ claiming: the jobs come with the shift
select test.s2_fd('s2_a', 'shift_take', jsonb_build_object('slot', test.s2_slot(1, 9)));
select test.eq('A claims the shift: its jobs are A''s', (select string_agg(test.s2_who(x), ',') from unnest(array[(select h from s2j), (select d from s2j), (select r from s2j)]) x), 'A,A,A');
select test.eq('on A''s Today of that day', (select count(*) from jsonb_array_elements(app.fx_today(test.id('s2_a'), app.today() + 1) -> 'cards') c where c ->> 'type' = 'job'), 3::bigint);
select test.eq('and on A''s My shifts', (select (m -> 'jobs' ->> 'total') from jsonb_array_elements(public.door(test.id('s2_a'), null, 'field_read', 'my_shifts', '{}') -> 'mine') m), '3');
select test.s2_fd('s2_b', 'shift_take', jsonb_build_object('slot', test.s2_slot(1, 9)));
select test.eq('B joins: the jobs are shared, least busy first',
  (select count(*) filter (where assigned_to = test.id('s2_a')) || '/' || count(*) filter (where assigned_to = test.id('s2_b')) from field_jobs where shift_slot_id = test.s2_slot(1, 9)), '2/1');
create temp table s2m as select (m ->> 'id')::uuid as id from jsonb_array_elements(app.fx_today(test.id('s2_b'), app.today() + 1) -> 'mates') m limit 1;
grant select on s2m to public;
select test.ok('B sees A''s jobs of the shift under Also on your shift', (select id from s2m) is not null);
select test.throws('C (not on the shift) cannot take one', format($$select test.s2_fd('s2_c', 'job_take', jsonb_build_object('job', %L))$$, (select id from s2m)), 'Only someone on this job');
select test.ok('B takes one of A''s', test.s2_fd('s2_b', 'job_take', jsonb_build_object('job', (select id from s2m))) is not null);
select test.eq('it is B''s now', (select assigned_to from field_jobs where id = (select id from s2m)), test.id('s2_b'));
-- A gives the shift up: A's jobs go to B (still on it)
select test.s2_fd('s2_a', 'shift_cancel', jsonb_build_object('id', (select id from field_shift_plans where staff_id = test.id('s2_a') and cancelled_at is null), 'reason', 'Exam that day'));
select test.eq('A gave it up: every job of the shift is B''s', (select string_agg(distinct test.s2_who(id), ',') from field_jobs where shift_slot_id = test.s2_slot(1, 9)), 'B');

-- ================================================================ Fleet: a person on a shift, or a shift
select test.throws('a person with no shift that day is refused', format($$select test.s2_ops('s2_fleet', 'field_job_assign', jsonb_build_object('id', %L, 'to', %L))$$,
  (select morning from s2j), test.id('s2_c')), 'is not on a shift that day');
select test.s2_fd('s2_c', 'shift_take', jsonb_build_object('slot', test.s2_slot(2, 14)));
select test.eq('C claims the afternoon shift: its jobs are C''s', (select string_agg(test.s2_who(x), ',') from unnest(array[(select late from s2j), (select night from s2j)]) x), 'C,C');
select test.eq('the morning shift has nobody: its jobs wait', test.s2_who((select morning from s2j)) || ',' || test.s2_who((select nextday from s2j)), 'nobody,nobody');
select test.ok('Fleet gives the morning job to C (on a shift that day)', test.s2_ops('s2_fleet', 'field_job_assign', jsonb_build_object('id', (select morning from s2j), 'to', test.id('s2_c'))) is not null);
select test.eq('on C''s shift, chosen by hand', (select (shift_slot_id = test.s2_slot(2, 14))::text || '/' || shift_pinned::text from field_jobs where id = (select morning from s2j)), 'true/true');
select test.throws('customer service cannot move a job to a shift', format($$select test.s2_ops('s2_cs', 'field_job_shift', jsonb_build_object('id', %L, 'slot', %L))$$, (select late from s2j), test.s2_slot(2, 9)), 'Only Fleet');
select test.eq('Fleet moves a job to the morning shift (nobody on it): it waits there', (test.s2_ops('s2_fleet', 'field_job_shift', jsonb_build_object('id', (select late from s2j), 'slot', test.s2_slot(2, 9))) ->> 'assigned_to') is null, true);
select test.eq('the board shows each shift''s jobs', (select (s -> 'jobs' ->> 'total') from jsonb_array_elements(public.door(test.id('s2_admin'), null, 'ops_read', 'field_board', '{}') -> 'slots') s
  where (s ->> 'id')::uuid = test.s2_slot(2, 9)), '2');

-- ================================================================ a swap moves the jobs with the shifts
select test.s2_fd('s2_b', 'swap_ask', jsonb_build_object('mine', (select id from field_shift_plans where staff_id = test.id('s2_b') and cancelled_at is null),
  'theirs', (select id from field_shift_plans where staff_id = test.id('s2_c') and cancelled_at is null)));
select test.s2_fd('s2_c', 'swap_answer', jsonb_build_object('id', (select id from field_shift_offers where kind = 'swap' and status = 'open' and from_staff = test.id('s2_b')), 'accept', true));
select test.eq('swapped: day 1''s jobs are C''s, day 2''s B''s',
  (select string_agg(distinct test.s2_who(id), ',') from field_jobs where shift_slot_id = test.s2_slot(1, 9)) || '/' ||
  (select string_agg(distinct test.s2_who(id), ',') from field_jobs where shift_slot_id = test.s2_slot(2, 14)), 'C/B');

-- ================================================================ a cancelled shift sends its jobs on; Unassign
select test.s2_ops('s2_fleet', 'field_slot_cancel', jsonb_build_object('id', test.s2_slot(2, 9)));
select test.eq('the cancelled morning shift''s job went to the afternoon shift', (select shift_slot_id from field_jobs where id = (select late from s2j)), test.s2_slot(2, 14));
select test.s2_ops('s2_fleet', 'field_job_unassign', jsonb_build_object('id', (select night from s2j)));
select test.eq('Unassign: no shift and nobody', (select (shift_slot_id is null and assigned_to is null)::text from field_jobs where id = (select night from s2j)), 'true');

-- ================================================================ a shift with jobs and nobody, within 24 hours
-- a shift that starts within 24 hours and stays on one Toronto day (a run late in the evening used to cross midnight)
create temp table s2soon_at as select case when extract(hour from now() at time zone 'America/Toronto') < 16
  then date_trunc('minute', now()) + interval '3 hours' else test.s2_at(1, 5) end as s;
select test.s2_ops('s2_fleet', 'field_slot_publish', jsonb_build_object('starts_at', (select s from s2soon_at), 'ends_at', (select s from s2soon_at) + interval '3 hours'));
create temp table s2soon as select test.s2_job('detail', (select s from s2soon_at) + interval '1 hour') as id;
select test.eq('the soon shift holds the job', (select shift_slot_id from field_jobs where id = (select id from s2soon)) =
  (select id from field_shift_slots where starts_at = (select s from s2soon_at) and cancelled_at is null), true);
select app.job_field_shift_jobs();
select app.job_field_shift_jobs();
select test.eq('Fleet and Admin alerted once with a To do', (select count(*) from tasks where task_type = 'field_shift_no_one'
  and related_id = (select shift_slot_id from field_jobs where id = (select id from s2soon))), 1::bigint);
select test.ok('the job functions are the service role''s only', not has_function_privilege('authenticated', 'app.fx_job_take(uuid, jsonb)', 'execute')
  and not has_function_privilege('anon', 'app.field_job_to_shift(uuid, jsonb)', 'execute') and has_function_privilege('service_role', 'app.job_field_shift_jobs(timestamptz)', 'execute'));

-- ================================================================ the showroom v2 and the image service
select test.eq('the image model''s daily limit is 100 by default', (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'listing_showroom_ai_daily'), '100');
-- r44 (2780) wraps photo_showroom: the v2 comparison is in the function it wraps
select test.ok('Apply showroom and Frame again compare with v2', (pg_get_functiondef('app.photo_showroom(uuid, jsonb)'::regprocedure) || coalesce(pg_get_functiondef(to_regprocedure('app.photo_showroom_pre2780(uuid, jsonb)')), '')) like '%studio_showroom_v2%'
  and pg_get_functiondef('app.listing_photos_reframe(uuid, jsonb)'::regprocedure) like '%studio_showroom_v2%'
  and (pg_get_functiondef('app.photo_showroom(uuid, jsonb)'::regprocedure) || coalesce(pg_get_functiondef(to_regprocedure('app.photo_showroom_pre2780(uuid, jsonb)')), '')) not like '%studio_showroom_v1%');
select test.eq('the image service makes only the cut-out unless switched on', public.server_listing_image_mode() ->> 'cf_transformations', 'false');

-- ================================================================ failed photos made again
select test.mk_vehicle('S2PIC', 's2_o');
create temp table s2i as select (app.start_listing_intake(test.id('s2_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:S2PIC'))) ->> 'intake_id')::uuid as i;
create temp table s2p as select (app.record_listing_upload(test.id('s2_admin'), (select i from s2i), jsonb_build_object('shot_type', 'front_left',
  'original_path', 'vehicles/original/s2/front-left.jpg', 'width', 3000, 'height', 2000, 'byte_size', 900000, 'mime_type', 'image/jpeg')) ->> 'photo_id')::uuid as p;
grant select on s2i, s2p to public;
select app.enqueue_listing_job((select i from s2i), 'process_photo', (select p from s2p))
 where not exists (select 1 from listing_jobs j where j.vehicle_photo_id = (select p from s2p) and j.kind = 'process_photo');
update listing_jobs set status = 'failed', attempts = 4, error = 'quota: Image transformations are rate limited', finished_at = now() where intake_id = (select i from s2i) and kind = 'process_photo';
update listing_intakes set state = 'failed', failed_at = now(), reason = 'process_photo: quota' where id = (select i from s2i);
select test.throws('customer service cannot retry failed photos', format($$select test.s2_ops('s2_cs', 'photo_retry_failed', jsonb_build_object('intake', %L))$$, (select i from s2i)), 'An Admin or Fleet');
select test.eq('Fleet marks the listing''s failed photos', (test.s2_ops('s2_fleet', 'photo_retry_failed', jsonb_build_object('intake', (select i from s2i))) ->> 'queued'), '1');
select test.eq('the retry job queues it again and the listing leaves Failed', (select app.job_photo_retry()) like '1 failed photo(s) queued again, 1 listing(s)%', true);
select test.eq('queued with fresh attempts, the intake no longer Failed',
  (select j.status || '/' || j.attempts || '/' || (i.state <> 'failed')::text from listing_jobs j join listing_intakes i on i.id = j.intake_id where j.intake_id = (select i from s2i) and j.kind = 'process_photo'),
  'queued/0/true');
select test.eq('nothing left for the next run', (select app.job_photo_retry()) like '0 failed%', true);

-- ================================================================ marketing scenes
select test.ok('the scenes: Highway, and Brick building picking its reference photo by itself',
  exists (select 1 from jsonb_array_elements((app.settings()).marketing_scenes) x where x ->> 'code' = 'highway' and x ->> 'label' = 'Highway')
  and exists (select 1 from jsonb_array_elements((app.settings()).marketing_scenes) x where x ->> 'code' = 'brick_building' and (x ->> 'needs_reference')::boolean and x ->> 'auto_reference' = 'shareholder_wide')
  and jsonb_array_length((app.settings()).marketing_scenes) >= 6);
update vehicle_photos set cutout = jsonb_build_object('auto_mask', 'vehicles/s2/work/front-left-mask.png'), processed_path = 'vehicles/s2/front-left.jpg', status = 'processed' where id = (select p from s2p);
-- no photo picked by itself (the automatic choice off) and none chosen: Brick building is not used
update program_settings set marketing_scenes = (select jsonb_agg(x - 'auto_reference' order by k) from jsonb_array_elements(marketing_scenes) with ordinality t(x, k)) where id = (select id from app.settings());
select test.throws('Brick building is not used before its reference photo is chosen', format($$select test.s2_ops('s2_fleet', 'marketing_set', jsonb_build_object('vehicle', %L, 'scene', 'brick_building'))$$, test.id('vehicle:S2PIC')), 'Choose the reference photo');
select test.throws('field staff cannot make marketing photos', format($$select public.door(%L, null, 'ops_do', 'marketing_set', jsonb_build_object('vehicle', %L, 'scene', 'mix'))$$, test.id('s2_a'), test.id('vehicle:S2PIC')));
select test.eq('Fleet makes a marketing set in one scene', (test.s2_ops('s2_fleet', 'marketing_set', jsonb_build_object('vehicle', test.id('vehicle:S2PIC'), 'scene', 'highway')) ->> 'queued'), '1');
create temp table s2mk as select id from vehicle_marketing_photos where vehicle_id = test.id('vehicle:S2PIC');
grant select on s2mk to public;
select test.eq('a marketing job carries the scene and the cut-out, never the website photo',
  (select (j.input #>> '{marketing,scene}') || '/' || (j.input #>> '{marketing,mask}') || '/' || (j.vehicle_photo_id is null)::text from listing_jobs j where j.kind = 'marketing_photo' and j.input #>> '{marketing,id}' = (select id::text from s2mk)),
  'highway/vehicles/s2/work/front-left-mask.png/true');
select test.throws('one set at a time', format($$select test.s2_ops('s2_fleet', 'marketing_set', jsonb_build_object('vehicle', %L))$$, test.id('vehicle:S2PIC')), 'being made now');
create temp table s2mc as select j.id from app.claim_listing_jobs('s2-w', 100, array['marketing_photo']) j where j.input #>> '{marketing,id}' = (select id::text from s2mk);
grant select on s2mc to public;
select app.worker_listing_result((select id from s2mc), jsonb_build_object('ok', true, 'provider', 'ai', 'output', jsonb_build_object('marketing',
  jsonb_build_object('id', (select id from s2mk), 'status', 'made', 'path', 'vehicles/s2/marketing/x.jpg', 'provider', 'ai'))));
select test.eq('made: kept on the marketing copy', (select status || '/' || path from vehicle_marketing_photos where id = (select id from s2mk)), 'made/vehicles/s2/marketing/x.jpg');
select test.eq('the website photo is untouched', (select processed_path from vehicle_photos where id = (select p from s2p)), 'vehicles/s2/front-left.jpg');
select test.eq('the newest set is read by Sales too', (select jsonb_array_length(public.door(test.id('s2_cs'), null, 'ops_read', 'marketing_photos', jsonb_build_object('vehicle', test.id('vehicle:S2PIC'))) -> 'photos')), 1);
select test.throws('only an Admin chooses a scene''s reference', format($$select test.s2_ops('s2_fleet', 'marketing_scene_reference', jsonb_build_object('code', 'brick_building', 'photo', %L))$$, (select p from s2p)), 'An Admin');
update program_settings set marketing_scenes = (select jsonb_agg(case when x ->> 'code' = 'brick_building' then x || '{"auto_reference": "shareholder_wide"}'::jsonb else x end order by k)
  from jsonb_array_elements(marketing_scenes) with ordinality t(x, k)) where id = (select id from app.settings());
update owners set is_shareholder = true where id = test.id('owner:s2_o');
update vehicles set make = 'Mercedes-Benz' where id = test.id('vehicle:S2PIC');
update vehicle_photos set width = 4000, height = 1000 where id = (select p from s2p);
select test.eq('Brick building picks by itself the widest outside photo as taken of a shareholder''s Mercedes-Benz', app.marketing_auto_reference(), (select p from s2p));
select test.ok('and is ready, marked as picked by itself', (select (x ->> 'ready')::boolean and (x ->> 'auto')::boolean
  from jsonb_array_elements(public.door(test.id('s2_admin'), null, 'ops_read', 'marketing_scene_refs', '{}') -> 'scenes') x where x ->> 'code' = 'brick_building'));
select test.eq('the picker lists the shareholders'' cars first',
  (select (public.door(test.id('s2_admin'), null, 'ops_read', 'marketing_scene_refs', '{}') -> 'photos' -> 0 ->> 'shareholder')), 'true');
select test.ok('an Admin picks the reference photo', test.s2_ops('s2_admin', 'marketing_scene_reference', jsonb_build_object('code', 'brick_building', 'photo', (select p from s2p))) is not null);
select test.eq('ready: the reference file is the photo''s original', (select app.marketing_reference_path(x -> 'reference') from jsonb_array_elements((app.settings()).marketing_scenes) x where x ->> 'code' = 'brick_building'),
  'vehicles/original/s2/front-left.jpg');
select test.throws('an upload path that is not ours is refused', $$select test.s2_ops('s2_admin', 'marketing_scene_reference', '{"code": "highway", "path": "../etc/x.jpg"}'::jsonb)$$, 'not one of ours');
select test.throws('the scenes list is checked', $$update program_settings set marketing_scenes = '[{"code": "Bad Code!", "label": "x", "made": "photo"}]'::jsonb where id = (select id from app.settings())$$, 'check');

-- ================================================================ the CARMA plate (1056)
update listing_jobs set status = 'succeeded', finished_at = now() where vehicle_photo_id = (select p from s2p) and status in ('queued', 'running');
update vehicle_photos set plate_status = 'covered', plate_style = 'cover', plate_boxes = '[{"x": 0.4, "y": 0.6, "w": 0.15, "h": 0.07}]'::jsonb,
       uncovered_path = 'vehicles/original/s2/front-left-uncovered.jpg', processed_path = 'vehicles/s2/front-left-c111111.jpg', shot_type = 'rear_left',
       variants = '[{"width": 800, "format": "jpg", "path": "vehicles/s2/front-left-c111111-800.jpg"}]'::jsonb
 where id = (select p from s2p);
select test.eq('the CARMA plate is the default way to treat a plate', (select plate_cover_style from app.settings()), 'carma');
select test.eq('every photo covered the old way is queued to be made again', app.plate_redo_queue((select p from s2p)), 1);
create temp table s2pr as select j.id, j.input from listing_jobs j where j.kind = 'plate_redo' and j.input #>> '{plate,photo_id}' = (select p::text from s2p);
grant select on s2pr to public;
select test.eq('from its uncovered file, the rear plate, its sizes', (select (input #>> '{plate,source}') || '/' || (input #>> '{plate,end}') || '/' || (input #> '{plate,widths}')::text from s2pr),
  'vehicles/original/s2/front-left-uncovered.jpg/rear/[800]');
select test.eq('not twice', app.plate_redo_queue((select p from s2p)), 0);
create temp table s2prc as select j.id from app.claim_listing_jobs('s2-w', 100, array['plate_redo']) j where j.id = (select id from s2pr);
grant select on s2prc to public;
select app.worker_listing_result((select id from s2pr), jsonb_build_object('ok', true, 'provider', 'carmacars', 'output', jsonb_build_object('plate',
  jsonb_build_object('processed_path', 'vehicles/' || test.id('vehicle:S2PIC') || '/front-left-pabc123.jpg', 'variants', jsonb_build_array(jsonb_build_object('width', 800, 'format', 'jpg', 'path', 'x'))))));
select test.eq('the new file, the style carma, the plate check kept', (select (processed_path like '%-pabc123.jpg')::text || '/' || plate_style || '/' || plate_status from vehicle_photos where id = (select p from s2p)),
  'true/carma/covered');
update vehicle_photos set plate_carry = '{"boxes": [{"x": 0.1, "y": 0.1, "w": 0.1, "h": 0.05}], "style": "pixelate"}'::jsonb where id = (select p from s2p);
select test.eq('a cover carried over is drawn the new way', (select plate_carry ->> 'style' from vehicle_photos where id = (select p from s2p)), 'carma');
update vehicle_photos set plate_carry = null where id = (select p from s2p);

-- ================================================================ the toast with a pulse (1055)
select test.eq('no unread alert: nothing', public.server_alert_latest(test.id('s2_fleet')) -> 'latest', 'null'::jsonb);
insert into notifications (user_id, code, title, url, dedupe_key) select test.id('s2_fleet'), 'staff_booking_request_new', 'New booking request CC-S2', '/staff/bookings/CC-S2', 's2-pulse-1'
 where exists (select 1 from notification_catalogue where code = 'staff_booking_request_new' and audience like 'staff%');
select test.eq('a new request: the newest unread alert, as a request', (select l ->> 'kind' || '/' || (l ->> 'title') from (select public.server_alert_latest(test.id('s2_fleet')) -> 'latest' as l) x),
  'request/New booking request CC-S2');
select test.ok('the pulse read is the service role''s only', not has_function_privilege('authenticated', 'public.server_alert_latest(uuid)', 'execute'));

update program_settings set field_jobs_auto_assign = (select aa from s2_prev), academy_gate = (select gate from s2_prev), field_jobs_auto = (select fa from s2_prev) where id = (select id from app.settings());
-- this suite's shifts go (0880's suite starts from none)
delete from field_shift_offers; select set_config('app.fx_no_slot', 'on', false); update field_jobs set shift_slot_id = null where shift_slot_id is not null; select set_config('app.fx_no_slot', 'off', false); delete from field_shift_plans; delete from field_shift_slots;
