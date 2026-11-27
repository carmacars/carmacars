-- 99: migration 5080 (R50 hotfix 2): the studio renders rebuilt so a paid render can pass. Standard r48.4; the views in the
-- sample photos' order, then the car's real outside photos cut out on the same dealership; the references (listing photos,
-- else check-in and check-out photos); the image calls capped a photo a day, costed, held by the photo budget, a refused view
-- waiting longer each time; the cost guard that pauses the studio and alerts the Admins; the connector's photo_standard;
-- REQ-001 (the sample angle set, one room), REQ-002 (cutouts only where a sample car stood), REQ-005 (the check's cause recorded).
-- Fixtures start with "rq5h2_"; no real names or plates.
select test.suite('99 r50 hotfix 2 studio composite (5080)');

update program_settings set listing_showroom_ai = true, listing_photo_r48_auto = true, listing_photo_r45_auto = false, listing_photo_r45_batch = 200,
       listing_photo_r45_reserve = 0, listing_showroom_ai_daily = 20000, listing_photo_r48_paused_at = null, listing_photo_r48_pause_why = null,
       photo_daily_budget_microusd = 1000000000
 where id = (select id from app.settings());
update listing_jobs set status = 'succeeded', finished_at = now() where kind = 'photo_r45' and status in ('queued', 'running');
-- no studio call of another test file counts here
update provider_calls set created_at = created_at - interval '3 days' where purpose = 'listing_showroom' and created_at > now() - interval '3 days';

select test.mk_user('rq5h2_admin', 'admin');
select test.mk_owner('rq5h2_olive');
select test.mk_vehicle('rq5h2_a', 'rq5h2_olive');   -- listing photos outside, check-in photos inside and outside
select test.mk_vehicle('rq5h2_h', 'rq5h2_olive');   -- check-in photos only

create or replace function test.rq5h2_photo(p_car text, p_shot text, p_r48 boolean, p_r45 jsonb default null, p_sort integer default 0) returns uuid language sql as $$
  insert into vehicle_photos (vehicle_id, angle, shot_type, original_path, processed_path, status, is_public, background_status, ai_generated, r48, sort_order, r45, width, height, plate_status)
  values (test.id('vehicle:' || p_car), case when p_shot = 'studio_extra' then 'other' else p_shot end, p_shot, 'vehicles/original/rq5h2/' || p_shot || '-' || md5(random()::text) || '.jpg',
          case when p_r48 then 'vehicles/rq5h2/' || p_shot || '-' || md5(random()::text) || '.jpg' end, 'approved', true, 'done', p_r48, p_r48, p_sort, p_r45, 1800, 1200, 'not_visible')
  returning id $$;
create or replace function test.rq5h2_live(p_spec text default null) returns jsonb language sql as $$
  select jsonb_build_object('state', 'done', 'spec', 'r45.1', 'tries', 1,
           'gate', jsonb_build_object('pass', true, 'spec', coalesce(p_spec, app.photo_r48_spec()), 'reasons', '[]'::jsonb, 'at', now())) $$;
create or replace function test.rq5h2_row(p_car text, p_shot text) returns vehicle_photos language sql as $$
  select * from vehicle_photos where vehicle_id = test.id('vehicle:' || p_car) and r48 and shot_type = p_shot and replaced_at is null order by created_at desc limit 1 $$;
create or replace function test.rq5h2_gallery(p_car text) returns text language sql as $$
  select string_agg((e ->> 'shot') || case when (e ->> 'is_cover')::boolean then '*' else '' end, ',' order by n)
    from jsonb_array_elements(app.public_listing_photos(test.id('vehicle:' || p_car))) with ordinality t(e, n) $$;

-- ---------------------------------------------------------------- 1. the standard and the order
select test.eq('the standard is r48.4, as the web''s R48_SPEC', app.photo_r48_spec(), 'r48.4');
select test.eq('REQ-001: exactly the sample photos'' angles in their order (studio.ts SHOTS: lead, side, rear34, front, rear, dash, seats, wheel)',
  app.photo_render_order(), array['front_left', 'left', 'rear_left', 'front', 'rear', 'dashboard', 'front_seats', 'wheel']);
select test.ok('REQ-001: every one of them is a shot type of the site', (select count(*) = 8 from listing_shot_types st where st.code = any (app.photo_render_order()) and st.is_public));

-- ---------------------------------------------------------------- 2. the references: listing photos, else check-in photos
create temp table rq5h2_real as select test.rq5h2_photo('rq5h2_a', 'front_left', false, null, 1) as fl, test.rq5h2_photo('rq5h2_a', 'rear', false, null, 2) as rear;
insert into condition_reports (id, vehicle_id, kind) values (test.id('cr:rq5h2_a'), test.id('vehicle:rq5h2_a'), 'baseline'), (test.id('cr:rq5h2_h'), test.id('vehicle:rq5h2_h'), 'baseline');
insert into condition_report_photos (condition_report_id, seq, shot, storage_path)
select test.id('cr:rq5h2_' || c), row_number() over (partition by c), s, 'reports/rq5h2/' || c || '/' || s || '.jpg'
  from unnest(array['a', 'h']) c cross join unnest(array['keys', 'licence', 'other', 'trunk', 'front_left', 'rear', 'instrument_cluster', 'front_seats']) s;
select test.eq('an outside view of a car with outside listing photos: its listing photos only, the same angle first',
  (select string_agg((e ->> 'from') || ':' || (e ->> 'shot'), ',' order by n) from jsonb_array_elements(app.photo_r48_refs(test.id('vehicle:rq5h2_a'), 'front_left')) with ordinality t(e, n)),
  'listing:front_left,listing:rear');
select test.eq('an inside view with no inside listing photo: its listing photos (colour and trim) only; no inside check-in photo is sent',
  (select string_agg((e ->> 'from') || ':' || (e ->> 'shot'), ',' order by n) from jsonb_array_elements(app.photo_r48_refs(test.id('vehicle:rq5h2_a'), 'dashboard')) with ordinality t(e, n)),
  'listing:front_left,listing:rear');
select test.eq('a car with no listing photo: its exterior check-in photos only, the view''s angle first; never keys, a licence, the inside or any other shot',
  (select string_agg((e ->> 'from') || ':' || (e ->> 'shot'), ',' order by n) from jsonb_array_elements(app.photo_r48_refs(test.id('vehicle:rq5h2_h'), 'rear')) with ordinality t(e, n)),
  'handover:rear,handover:front_left');
select test.eq('only the eight outside angles of a check-in or check-out photo go to the image model',
  (select string_agg(coalesce(app.photo_r48_handover_shot(s, null), '-'), ',' order by n) from unnest(array['front_left', 'right', 'rear_right', 'instrument_cluster', 'front_seats', 'trunk', 'licence', 'other', 'keys', 'wheel_front_left']) with ordinality t(s, n)),
  'front_left,right,rear_right,-,-,-,-,-,-,-');
select test.eq('an angle named on the photo wins over its shot, and an inside angle on an outside shot is not sent', app.photo_r48_handover_shot('other', 'rear') || '/' || coalesce(app.photo_r48_handover_shot('front', 'front_seats'), '-'), 'rear/-');

-- ---------------------------------------------------------------- 3. the image model's gate: the cap a photo, the cost, the pause
create temp table rq5h2_v as select test.rq5h2_photo('rq5h2_h', 'front', true, jsonb_build_object('state', 'queued', 'tries', 0)) as id;
create temp table rq5h2_g as select n, app.showroom_ai_gate(jsonb_build_object('photo_id', (select id from rq5h2_v))) as g from generate_series(1, 4) n;
select test.eq('a photo gets listing_photo_r48_daily_tries (3) image calls a day; the fourth waits for tomorrow (a wait, never a try)',
  (select string_agg(coalesce(g ->> 'allowed', 'f') || '/' || coalesce(g ->> 'scope', '-'), ',' order by n) from rq5h2_g), 'true/-,true/-,true/-,false/photo');
select test.eq('the fourth is a limit (2840 waits for tomorrow, no try counted)', (select g ->> 'reason' from rq5h2_g where n = 4), 'limit');
select test.ok('each call is recorded with its photo and car', (select count(*) = 3 and bool_and(c.vehicle_photo_id = (select id from rq5h2_v) and c.vehicle_id = test.id('vehicle:rq5h2_h'))
  from provider_calls c where c.id in (select (g ->> 'call_id')::uuid from rq5h2_g where n <= 3)));
select app.showroom_ai_record(jsonb_build_object('call_id', (select g ->> 'call_id' from rq5h2_g where n = 1), 'ok', true, 'duration_ms', 900));
select app.showroom_ai_record(jsonb_build_object('call_id', (select g ->> 'call_id' from rq5h2_g where n = 2), 'ok', false, 'error', 'blocked: SAFETY'));
select test.eq('an image made costs listing_showroom_ai_call_microusd (0.039 USD); a refused call costs nothing',
  (select string_agg(c.cost_microusd::text, ',' order by n) from rq5h2_g join provider_calls c on c.id = (g ->> 'call_id')::uuid where n <= 2), '39000,0');
select test.ok('so the photo budget sees the studio''s spend', (app.listing_budget() ->> 'photo_spent_microusd')::bigint >= 39000);
-- the photo budget holds the studio steps (2530 held only the upload steps)
select app.photo_r48_queue(null, test.id('vehicle:rq5h2_h'), 'left', false);
update program_settings set photo_daily_budget_microusd = 1 where id = (select id from app.settings());
create temp table rq5h2_claim as select app.worker_claim_listing_jobs('rq5h2', 50) as c;
select test.ok('over the photo budget: no studio step is handed to the worker, and the claim says photos are held',
  (select (c #>> '{held,photos}')::boolean and not exists (select 1 from jsonb_array_elements(c -> 'jobs') e where e ->> 'kind' = 'photo_r45') from rq5h2_claim));
update listing_jobs set status = 'queued', locked_at = null, locked_by = null where id in (select (e ->> 'id')::uuid from rq5h2_claim, jsonb_array_elements(c -> 'jobs') e);
update program_settings set photo_daily_budget_microusd = 1000000000 where id = (select id from app.settings());
-- paused by the cost guard: a studio view waits, another photo's call (an upload's showroom) does not
update program_settings set listing_photo_r48_paused_at = now() where id = (select id from app.settings());
select test.eq('paused: a studio view waits (limit, paused)',
  (select g ->> 'reason' || '/' || (g ->> 'scope') from (select app.showroom_ai_gate(jsonb_build_object('photo_id', (test.rq5h2_row('rq5h2_h', 'left')).id)) g) x), 'limit/paused');
select test.ok('paused: an upload''s showroom photo is still allowed',
  (app.showroom_ai_gate(jsonb_build_object('photo_id', (select fl from rq5h2_real))) ->> 'allowed')::boolean);
update program_settings set listing_photo_r48_paused_at = now() - interval '25 hours' where id = (select id from app.settings());
select test.ok('a day later the pause is over by itself',
  (app.showroom_ai_gate(jsonb_build_object('photo_id', (test.rq5h2_row('rq5h2_h', 'left')).id)) ->> 'allowed')::boolean);
update program_settings set listing_photo_r48_paused_at = null where id = (select id from app.settings());

-- ---------------------------------------------------------------- 4. a refused view waits longer each time
create or replace function test.rq5h2_refuse(p_photo uuid) returns timestamptz language plpgsql as $$
declare v uuid := (select j.id from listing_jobs j where j.vehicle_photo_id = p_photo and j.kind = 'photo_r45' and j.status = 'queued' order by j.created_at desc limit 1);
begin
  update listing_jobs set status = 'running', attempts = attempts + 1, locked_at = now(), locked_by = 'rq5h2', started_at = now() where id = v;
  perform app.worker_listing_result(v, jsonb_build_object('ok', true, 'provider', 'gemini', 'output', jsonb_build_object('r45',
    jsonb_build_object('pass', false, 'spec', app.photo_r48_spec(), 'generated', true, 'why', 'the check refused it', 'reasons', '["looks_cgi"]'::jsonb))));
  return (select j.next_attempt_at from listing_jobs j where j.vehicle_photo_id = p_photo and j.kind = 'photo_r45' and j.status = 'queued' order by j.created_at desc limit 1);
end $$;
create temp table rq5h2_wait as select test.rq5h2_refuse((test.rq5h2_row('rq5h2_h', 'left')).id) - now() as w1;
insert into rq5h2_wait select test.rq5h2_refuse((test.rq5h2_row('rq5h2_h', 'left')).id) - now();
select test.ok('refused once: made again in about 20 minutes (was 2), told why',
  (select min(w1) between interval '19 minutes' and interval '21 minutes' from rq5h2_wait) and (test.rq5h2_row('rq5h2_h', 'left')).r45 -> 'reasons' ? 'looks_cgi',
  (select string_agg(w1::text, ', ') from rq5h2_wait));
select test.ok('refused twice: about an hour', (select max(w1) between interval '59 minutes' and interval '61 minutes' from rq5h2_wait));
select test.rq5h2_refuse((test.rq5h2_row('rq5h2_h', 'left')).id);
select test.eq('refused three times: flagged with the reasons, no step left', (test.rq5h2_row('rq5h2_h', 'left')).r45 ->> 'state', 'flagged');
select test.ok('flagged: never queued again by the job on its own', app.photo_r48_queue(null, test.id('vehicle:rq5h2_h'), 'left', false) is null);

-- ---------------------------------------------------------------- 5. the gate: only renders of r48.4 that passed are live
create temp table rq5h2_old as select test.rq5h2_photo('rq5h2_a', 'left', true, test.rq5h2_live('r48.3') || jsonb_build_object('regate', now())) as id;
select test.ok('a render of r48.3 is never live, even marked for the check in place of 3701',
  not (select app.photo_render_live(ph) from vehicle_photos ph where ph.id = (select id from rq5h2_old)));
select test.eq('the check in place of 3701 queues nothing (its refusal started the tries again: a loop under r48.4)', app.photo_r48_regate_queue(50), 0);
select test.ok('no live render: the photos as before release 50 (5064), never the old render',
  app.public_listing_photos(test.id('vehicle:rq5h2_a')) = coalesce(nullif(app.photo_fallback_gallery(test.id('vehicle:rq5h2_a')), '[]'::jsonb), jsonb_build_array(app.photo_placeholder(test.id('vehicle:rq5h2_a'))))
  and position((select processed_path from vehicle_photos where id = (select id from rq5h2_old)) in app.public_listing_photos(test.id('vehicle:rq5h2_a'))::text) = 0);

-- a render made before r48.4 that was on the site stays until its view is made again, then the new render takes its place
create temp table rq5h2_prev as select test.rq5h2_photo('rq5h2_a', 'rear', true, test.rq5h2_live('r48.3') || jsonb_build_object('prev_live', true, 'state', 'redo')) as id;
select test.ok('an older render that was live stays live while its view is made again', (select app.photo_render_live(ph) from vehicle_photos ph where ph.id = (select id from rq5h2_prev)));
select test.ok('so the car keeps showing it', position((select processed_path from vehicle_photos where id = (select id from rq5h2_prev)) in app.public_listing_photos(test.id('vehicle:rq5h2_a'))::text) > 0);
update vehicle_photos set r45 = r45 || jsonb_build_object('state', 'queued') where id = (select id from rq5h2_prev);
select test.ok('also while the new render is queued', (select app.photo_render_live(ph) from vehicle_photos ph where ph.id = (select id from rq5h2_prev)));
update vehicle_photos set r45 = test.rq5h2_live() || jsonb_build_object('prev_live', true) where id = (select id from rq5h2_prev);
select test.ok('the new render that passed takes its place', (select app.photo_render_live(ph) and ph.r45 #>> '{gate,spec}' = 'r48.4' from vehicle_photos ph where ph.id = (select id from rq5h2_prev)));
update vehicle_photos set r45 = test.rq5h2_live('r48.3') || jsonb_build_object('prev_live', true, 'state', 'flagged') where id = (select id from rq5h2_prev);
select test.ok('a flagged view is off the site', not (select app.photo_render_live(ph) from vehicle_photos ph where ph.id = (select id from rq5h2_prev)));
update vehicle_photos set r45 = test.rq5h2_live('r48.3') || jsonb_build_object('state', 'redo') where id = (select id from rq5h2_prev);
select test.ok('a render of an older standard that was never on the site stays off', not (select app.photo_render_live(ph) from vehicle_photos ph where ph.id = (select id from rq5h2_prev)));
update vehicle_photos set replaced_at = now() where id = (select id from rq5h2_prev);

-- ---------------------------------------------------------------- 6. the gallery: the sample order, then the real photos cut out
update vehicle_photos set replaced_at = now() where id = (select id from rq5h2_old);
create temp table rq5h2_r as select
  test.rq5h2_photo('rq5h2_a', 'dashboard', true, test.rq5h2_live()) as dash,
  test.rq5h2_photo('rq5h2_a', 'left', true, test.rq5h2_live()) as side,
  test.rq5h2_photo('rq5h2_a', 'rear_left', true, test.rq5h2_live()) as r34,
  test.rq5h2_photo('rq5h2_a', 'front_left', true, test.rq5h2_live()) as lead;
select test.eq('the live views in the sample order, the front three-quarter the cover', test.rq5h2_gallery('rq5h2_a'), 'front_left*,left,rear_left,dashboard');
select test.eq('the studio cover is the front three-quarter, as the sample covers', (app.photo_r48_cover(test.id('vehicle:rq5h2_a'))).id, (select lead from rq5h2_r));

-- the extras: once every standard view is made or flagged, the car's real outside photos are cut out (listing_photo_r48_extras)
select test.eq('not before the car''s standard views are all made or flagged', app.photo_r48_extra_queue(test.id('vehicle:rq5h2_a'), 10), 0);
insert into vehicle_photos (vehicle_id, angle, shot_type, original_path, status, is_public, background_status, ai_generated, r48, sort_order, r45)
select test.id('vehicle:rq5h2_a'), a, a, 'vehicles/original/rq5h2/f-' || a || '.jpg', 'processed', false, 'done', true, true, 0, jsonb_build_object('state', 'flagged', 'tries', 3)
  from unnest(array['front', 'rear', 'front_seats', 'wheel']) a;
update program_settings set listing_photo_r48_extras = 1 where id = (select id from app.settings());
-- other test files leave queued views of their own: set aside (flagged) for this section, put back after it
create temp table rq5h2_aside as select ph.id, ph.r45 from vehicle_photos ph where ph.r48 and ph.replaced_at is null and ph.shot_type = any (app.photo_render_order())
  and coalesce(ph.r45 ->> 'state', '') in ('queued', 'redo') and ph.id <> (select id from rq5h2_v);
update vehicle_photos set r45 = r45 || jsonb_build_object('state', 'flagged') where id in (select id from rq5h2_aside);
select test.ok('a standard view waiting (here a queued one of another car) holds the extras', app.photo_r48_views_waiting() and app.photo_r48_extra_queue(test.id('vehicle:rq5h2_a'), 10) = 0);
update vehicle_photos set r45 = r45 || jsonb_build_object('state', 'flagged') where id = (select id from rq5h2_v);
select test.ok('none waiting: no hold', not app.photo_r48_views_waiting());
select test.eq('then at most listing_photo_r48_extras of them (here 1), the first real photo first', app.photo_r48_extra_queue(test.id('vehicle:rq5h2_a'), 10), 1);
create temp table rq5h2_x as select ph.* from vehicle_photos ph where ph.vehicle_id = test.id('vehicle:rq5h2_a') and ph.shot_type = 'studio_extra';
select test.ok('the extra: a generated row of its real photo, off the site, its step in mode r48 with extra',
  (select count(*) = 1 and bool_and(x.r48 and x.ai_generated and not x.is_public and x.r48_source = (select fl from rq5h2_real)) from rq5h2_x x)
  and exists (select 1 from listing_jobs j where j.vehicle_photo_id = (select id from rq5h2_x) and j.kind = 'photo_r45' and j.status = 'queued'
                and (j.input #>> '{r45,extra}')::boolean and j.input #>> '{r45,mode}' = 'r48'));
select test.eq('queued once only', app.photo_r48_extra_queue(test.id('vehicle:rq5h2_a'), 10), 0);
create temp table rq5h2_ctx as select app.listing_job_context((select j.id from listing_jobs j where j.vehicle_photo_id = (select id from rq5h2_x) and j.kind = 'photo_r45' order by j.created_at desc limit 1)) as c;
select test.ok('its step''s reference is its one real photo; no drawing, no stock photo',
  (select c #> '{input,r45,refs}' = jsonb_build_array(jsonb_build_object('bucket', 'vehicle-originals', 'path', (select original_path from vehicle_photos where id = (select fl from rq5h2_real)),
             'shot', 'front_left', 'from', 'listing')) and c #> '{input,r45,guide}' is null and c #> '{input,r45,stock}' is null and c #>> '{input,r45,shot}' = 'studio_extra' from rq5h2_ctx));
update vehicle_photos set processed_path = 'vehicles/rq5h2/extra.jpg', status = 'approved', is_public = true, r45 = test.rq5h2_live() where id = (select id from rq5h2_x);
select test.eq('the real photo, cut out on the dealership, after every view', test.rq5h2_gallery('rq5h2_a'), 'front_left*,left,rear_left,dashboard,studio_extra');
select test.ok('every public photo is a studio view once the car has its renders (the car''s own photo only as its cut-out)',
  (select bool_and(coalesce((e ->> 'generated')::boolean, false)) from jsonb_array_elements(app.public_listing_photos(test.id('vehicle:rq5h2_a'))) e));
update vehicle_photos set replaced_at = now() where id = (select fl from rq5h2_real);
select test.eq('its real photo replaced: the extra goes too', test.rq5h2_gallery('rq5h2_a'), 'front_left*,left,rear_left,dashboard');
select test.ok('a car''s progress counts its eight standard views only (REQ-001)', (app.photo_r48_car(test.id('vehicle:rq5h2_a')) ->> 'done')::int = 4);
update program_settings set listing_photo_r48_extras = 6 where id = (select id from app.settings());
update vehicle_photos ph set r45 = a.r45 from rq5h2_aside a where ph.id = a.id;

-- ---------------------------------------------------------------- 7. the cost guard
insert into provider_calls (provider, purpose, ok, error, duration_ms, cost_microusd, units, unit, vehicle_id, vehicle_photo_id)
select 'google-ai:test', 'listing_showroom', true, null, 1, 39000, 1, 'requests', test.id('vehicle:rq5h2_h'), (test.rq5h2_row('rq5h2_h', 'front')).id from generate_series(1, 30 + 8 * (select count(*)::int from vehicle_photos ph where ph.r48 and coalesce((ph.r45 #>> '{gate,pass}')::boolean, false)
  and ph.r45 #>> '{gate,spec}' = app.photo_r48_spec() and (ph.r45 #>> '{gate,at}')::timestamptz > now() - interval '24 hours'));
create temp table rq5h2_guard as select app.photo_r48_cost_guard() as g;
select test.ok('more than listing_photo_r48_max_calls_per_pass (8) image calls for each passed view in 24 hours: paused, with why',
  (select (g ->> 'paused')::boolean and (g ->> 'calls')::int > 8 * (g ->> 'passed')::int and g ->> 'why' like '%image calls%' from rq5h2_guard)
  and (app.settings()).listing_photo_r48_paused_at is not null, (select g::text from rq5h2_guard));
select test.ok('the Admins are alerted (photo_studio_paused, urgent, System)',
  exists (select 1 from app_events e where e.code like 'staff_alert_%' and e.payload ->> 'rule' = 'photo_studio_paused')
  and exists (select 1 from staff_alert_rules r where r.rule = 'photo_studio_paused' and r.tier = 'urgent' and r.enabled));
select test.ok('paused: the job queues nothing', app.job_photo_r48() like 'paused by the cost guard%');
select test.ok('the Photo standard card shows the guard''s numbers and the pause',
  (select x #>> '{r48_cost,paused_at}' is not null and (x #>> '{r48_cost,calls}')::int >= 30 and (x #>> '{r48_cost,daily_tries}')::int = 3
     from (select app.photo_r45_fleet_read(test.id('rq5h2_admin'), '{}'::jsonb) x) t));
-- normal spend: enough passed views for the calls, no pause
update program_settings set listing_photo_r48_paused_at = null, listing_photo_r48_pause_why = null where id = (select id from app.settings());
update vehicle_photos set r45 = r45 || jsonb_build_object('gate', jsonb_build_object('pass', true, 'spec', app.photo_r48_spec(), 'at', now()))
 where vehicle_id = test.id('vehicle:rq5h2_a') and r48 and replaced_at is null and r45 ->> 'state' = 'flagged';
insert into vehicle_photos (vehicle_id, angle, shot_type, original_path, status, is_public, background_status, ai_generated, r48, sort_order, r45)
select test.id('vehicle:rq5h2_a'), 'other', 'studio_extra', 'vehicles/original/rq5h2/p-' || n || '.jpg', 'processed', false, 'done', true, true, 0, test.rq5h2_live()
  from generate_series(1, (select count(*)::int / 8 + 1 from provider_calls c where c.purpose = 'listing_showroom' and c.ok and c.created_at > now() - interval '24 hours')) n;
select test.ok('calls within the ratio: not paused', not (app.photo_r48_cost_guard() ->> 'paused')::boolean, app.photo_r48_cost_guard()::text);

-- ---------------------------------------------------------------- 8. the connector's photo_standard reads again (3870)
select test.ok('app.comms_listing_files gives one car''s photos with a link each (it failed to parse since 3870)',
  jsonb_array_length(app.comms_listing_files(jsonb_build_object('cars', jsonb_build_array(jsonb_build_object('vehicle_id', test.id('vehicle:rq5h2_a'))))) -> 'cars' -> 0 -> 'images') >= 1);
select test.eq('and leaves a fleet answer as it is', app.comms_listing_files('{"cars": []}'::jsonb), '{"cars": []}'::jsonb);

-- ---------------------------------------------------------------- 9. REQ-001 and REQ-002: one room, cutouts only where a sample car stood
select test.mk_vehicle('rq5h2_c', 'rq5h2_olive');
insert into vehicle_listings (vehicle_id, slug, headline, status, published_at) values (test.id('vehicle:rq5h2_c'), 'rq5h2-c', 'Test car C', 'published', now());
select test.rq5h2_photo('rq5h2_c', 'front_left', false, null, 1);
select app.photo_r48_queue(null, test.id('vehicle:rq5h2_c'), 'front_left', false);
select app.photo_r48_queue(null, test.id('vehicle:rq5h2_c'), 'left', false);
create or replace function test.rq5h2_made(p_photo uuid, p_shot text, p_cutout jsonb) returns jsonb language plpgsql as $$
declare v uuid := (select j.id from listing_jobs j where j.vehicle_photo_id = p_photo and j.kind = 'photo_r45' order by j.created_at desc limit 1);
begin
  update listing_jobs set status = 'running', attempts = attempts + 1, locked_at = now(), locked_by = 'rq5h2', started_at = now() where id = v;
  return app.worker_listing_result(v, jsonb_build_object('ok', true, 'provider', 'ai', 'output', jsonb_build_object(
    'processed_path', 'vehicles/rq5h2/c-' || p_shot || '-r48.jpg', 'width', 1800, 'height', 1200, 'variants', '[]'::jsonb, 'preset_version', 'gemini_r48', 'flags', '[]'::jsonb,
    'showroom', jsonb_build_object('provider', 'ai', 'mode', 'r48', 'spec', app.photo_r48_spec(), 'scene', 'showroom_dark', 'background', 'site/cutouts/room-r48.4.jpg', 'cutout', p_cutout),
    'r45', jsonb_build_object('pass', true, 'spec', app.photo_r48_spec(), 'generated', true, 'plates', '[]'::jsonb, 'view', p_shot, 'reasons', '[]'::jsonb,
      'gate', jsonb_build_object('pass', true, 'spec', app.photo_r48_spec(), 'reasons', '[]'::jsonb, 'at', now())))));
end $$;
select test.rq5h2_made((test.rq5h2_row('rq5h2_c', 'front_left')).id, 'front_left', jsonb_build_object('path', 'site/cutouts/' || test.id('vehicle:rq5h2_c') || '/front_left-abc123.png',
  'width', 1800, 'height', 1200, 'kind', 'matte', 'box', jsonb_build_object('x', 0.1, 'y', 0.3, 'w', 0.8, 'h', 0.5)));
select test.rq5h2_made((test.rq5h2_row('rq5h2_c', 'left')).id, 'left', jsonb_build_object('path', 'site/cutouts/' || test.id('vehicle:rq5h2_c') || '/left-abc124.png',
  'width', 1400, 'height', 560, 'kind', 'cutout'));
select test.eq('REQ-001: the passed views in the sample order, the front three-quarter the cover', test.rq5h2_gallery('rq5h2_c'), 'front_left*,left');
select test.eq('REQ-001: every view stands on the one identical room', (select string_agg(distinct ph.showroom ->> 'background', ',') from vehicle_photos ph
  where ph.vehicle_id = test.id('vehicle:rq5h2_c') and ph.r48 and ph.replaced_at is null), 'site/cutouts/room-r48.4.jpg');
select test.eq('REQ-002: the cover''s cutout is kept, its plate the identical room, against the render it was cut from',
  (select k.kind || '|' || k.source_kind || '|' || k.plate_path || '|' || (k.source_path = (test.rq5h2_row('rq5h2_c', 'front_left')).processed_path)::text
     from site_cutouts k where k.vehicle_id = test.id('vehicle:rq5h2_c') and k.shot = 'front_left'), 'matte|studio|site/cutouts/room-r48.4.jpg|true');
select test.eq('REQ-002: the side profile''s cutout, cropped to the car', (select k.kind || '|' || k.width || 'x' || k.height from site_cutouts k
  where k.vehicle_id = test.id('vehicle:rq5h2_c') and k.shot = 'left'), 'cutout|1400x560');
select test.ok('REQ-002: a card that shows a sample car gets the real car''s cutout on the room, never its full photo',
  exists (select 1 from jsonb_array_elements(app.site_studio_covers(48)) e where (e ->> 'vehicle_id')::uuid = test.id('vehicle:rq5h2_c')
            and e ->> 'path' like 'site/cutouts/%.png' and e ->> 'plate' = 'site/cutouts/room-r48.4.jpg')
  and not exists (select 1 from jsonb_array_elements(app.site_studio_covers(48)) e where e ->> 'path' not like 'site/cutouts/%.png'), app.site_studio_covers(48)::text);
select test.ok('REQ-002: the home hero and its sections get the side profile''s cutout only',
  exists (select 1 from jsonb_array_elements(app.site_cutouts('left', 24)) e where (e ->> 'vehicle_id')::uuid = test.id('vehicle:rq5h2_c')
            and e ->> 'path' = 'site/cutouts/' || test.id('vehicle:rq5h2_c') || '/left-abc124.png'), app.site_cutouts('left', 24)::text);
update vehicle_photos set r45 = r45 || '{"state": "flagged"}' where id = (test.rq5h2_row('rq5h2_c', 'left')).id;
select test.ok('REQ-002: a cutout whose render is no longer live is not shown',
  not exists (select 1 from jsonb_array_elements(app.site_cutouts('left', 24)) e where (e ->> 'vehicle_id')::uuid = test.id('vehicle:rq5h2_c')));
select app.photo_r48_queue(null, test.id('vehicle:rq5h2_c'), 'rear', false);
select test.rq5h2_made((test.rq5h2_row('rq5h2_c', 'rear')).id, 'rear', jsonb_build_object('path', 'site/elsewhere/rear.png', 'width', 10, 'height', 10, 'kind', 'cutout'));
select test.ok('a cutout outside the car''s cutout folder, or of a view the site does not cut out, is never kept',
  not exists (select 1 from site_cutouts k where k.vehicle_id = test.id('vehicle:rq5h2_c') and k.path like '%elsewhere%'));

-- ---------------------------------------------------------------- 10. REQ-005: a check without a verdict keeps its cause
select app.photo_mark_record(jsonb_build_object('model', 'gemini:gemini-3.8-flash', 'ok', false, 'error', 'no verdict: finish MAX_TOKENS, 20 characters',
  'photo_id', (test.rq5h2_row('rq5h2_c', 'front_left')).id, 'duration_ms', 900));
select app.photo_mark_record(jsonb_build_object('model', 'gemini:gemini-3.8-flash', 'ok', true, 'error', 'ignored', 'photo_id', 'not-a-uuid'));
select test.eq('the failed check is recorded with its cause, its photo and its car; a passed one with no error',
  (select string_agg(coalesce(c.error, '-') || '|' || coalesce((c.vehicle_photo_id = (test.rq5h2_row('rq5h2_c', 'front_left')).id)::text, 'none') || '|'
            || coalesce((c.vehicle_id = test.id('vehicle:rq5h2_c'))::text, 'none'), ',' order by c.ok)
     from provider_calls c where c.purpose = 'photo_sort' and c.provider = 'gemini:gemini-3.8-flash' and c.created_at > now() - interval '1 minute'),
  'no verdict: finish MAX_TOKENS, 20 characters|true|true,-|none|none');

select test.ok('the new functions are for the server only', not has_function_privilege('authenticated', 'app.photo_r48_cost_guard()', 'execute')
  and not has_function_privilege('anon', 'app.photo_r48_extra_queue(uuid, integer)', 'execute') and has_function_privilege('service_role', 'app.photo_r48_cost_guard()', 'execute'));

update program_settings set listing_photo_r48_paused_at = null, listing_photo_r48_pause_why = null, listing_photo_r48_extras = 6 where id = (select id from app.settings());
