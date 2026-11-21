-- 99: people on the live map (migrations 3350 and 3351, release 48 part MAP). Staff only on shift or on a job, after the
-- electronic monitoring policy (its copy by email, in-app and push, locked); renters and owners only around a pickup or
-- return; everyone can turn it off except staff during an active job; the latest position only plus a job's points; Admin
-- and Fleet see everyone, customer service and Sales renters at a pickup or return, Finance and field staff no one.
-- Fixtures start with "mp"; every address is example.test.
select test.suite('99 r48 MAP: people on the live map');

select test.mk_user('mp_admin', 'admin');
select test.mk_user('mp_fleet', 'va', 'fleet');
select test.mk_user('mp_cs', 'va', 'cs');
select test.mk_user('mp_fin', 'va', 'finance');
select test.mk_user('mp_field', 'field', null, 'driver');
select test.mk_owner('mp_owner');
select test.mk_vehicle('mp_car', 'mp_owner');
select test.mk_renter('mp_rita');
select test.mk_renter('mp_sam');
create or replace function test.mpt(p interval) returns text language sql stable as $$
  select to_char((now() + p) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI') $$;
select test.mk_booking('MP-1', 'mp_car', 'mp_rita', test.mpt('1 hour'), test.mpt('3 days'), 'confirmed');
select test.mk_booking('MP-2', 'mp_car', 'mp_sam', test.mpt('10 days'), test.mpt('12 days'), 'confirmed');
create or replace function test.mpdo(p_user text, p_name text, p jsonb default '{}') returns jsonb
language sql as $$ select app.door(test.id(p_user), 'aal2', 'ops_do', p_name, p) $$;
create or replace function test.mpread(p_user text, p_name text, p jsonb default '{}') returns jsonb
language sql as $$ select app.door(test.id(p_user), 'aal2', 'ops_read', p_name, p) $$;
create or replace function test.mppos(p_lat numeric, p_lng numeric, p_src text default 'web') returns jsonb
language sql stable as $$ select jsonb_build_object('lat', p_lat, 'lng', p_lng, 'accuracy_m', 12, 'at', now(), 'source', p_src) $$;
create or replace function test.mpwho(p_reader text) returns text language sql as $$
  select coalesce((select string_agg(x ->> 'name', ',' order by x ->> 'name') from jsonb_array_elements(test.mpread(p_reader, 'live_people') -> 'people') x), '') $$;

-- ================================================================ 1. tables closed, functions closed
select test.eq('the three tables have RLS on and nothing for anon or authenticated',
  (select bool_and(c.relrowsecurity) and not bool_or(has_table_privilege('authenticated', c.oid, 'select') or has_table_privilege('anon', c.oid, 'select'))
     from pg_class c where c.relname in ('location_prefs', 'person_locations', 'location_job_points') and c.relnamespace = 'public'::regnamespace), true);
select test.eq('the location functions are the service role''s only',
  (select bool_or(has_function_privilege('authenticated', p.oid, 'execute')) from pg_proc p where p.pronamespace = 'app'::regnamespace and p.proname like 'location%'), false);

-- ================================================================ 2. staff: policy first, then only on shift or on a job
select test.eq('staff off duty, no policy yet: nothing is stored and the policy is asked for',
  format('%s %s', test.mpdo('mp_fleet', 'location_report', test.mppos(43.65, -79.38)) ->> 'why', (select count(*) from person_locations where user_id = test.id('mp_fleet'))), 'policy 0');
select test.throws('an old policy version is refused', $$ select test.mpdo('mp_fleet', 'location_policy_accept', '{"version":"old"}') $$, '%policy changed%');
select test.throws('renters cannot accept the staff policy', $$ select test.mpdo('mp_rita', 'location_policy_accept', jsonb_build_object('version', app.location_policy() ->> 'version')) $$, '%Staff only%');
select test.mpdo('mp_fleet', 'location_policy_accept', jsonb_build_object('version', app.location_policy() ->> 'version'));
select test.mpdo('mp_fleet', 'location_policy_accept', jsonb_build_object('version', app.location_policy() ->> 'version'));
select test.eq('accepted once: one copy queued (email), the audit log has it',
  format('%s %s', (select count(*) from app_events where code = 'staff_location_policy' and entity_id = test.id('mp_fleet')),
         (select (count(*) > 0)::text from audit_log where entity_table = 'location_prefs' and entity_id = test.id('mp_fleet')::text)), '1 true');
select test.eq('policy accepted, still off duty: not stored', test.mpdo('mp_fleet', 'location_report', test.mppos(43.65, -79.38)) ->> 'why', 'off_duty');
insert into staff_clock_entries (user_id, started_at, created_by) values (test.id('mp_fleet'), now() - interval '1 hour', test.id('mp_fleet'));
-- a function's writes are not seen by the other parts of the same statement: the call goes first, on its own (\gset)
select test.mpdo('mp_fleet', 'location_report', test.mppos(43.65, -79.38)) ->> 'stored' as r \gset
select test.eq('clocked in: stored, the latest only', format('%s %s %s', :'r',
  (select reason from person_locations where user_id = test.id('mp_fleet')), (select count(*) from location_job_points where user_id = test.id('mp_fleet'))), 'true shift 0');
select test.eq('a second report within 20 seconds is not stored', test.mpdo('mp_fleet', 'location_report', test.mppos(43.70, -79.40)) ->> 'why', 'soon');
select test.eq('a reading older than 2 minutes is not stored',
  test.mpdo('mp_fleet', 'location_report', test.mppos(43.70, -79.40) || jsonb_build_object('at', now() - interval '10 minutes')) ->> 'why', 'stale');
select test.throws('a position out of range is refused', $$ select test.mpdo('mp_fleet', 'location_report', '{"lat": 200, "lng": 0}') $$, '%could not be read%');
select test.mpdo('mp_fleet', 'location_prefs_save', '{"sharing_on": false}') ->> 'why' as r \gset
select test.eq('on shift, staff may turn it off; the position goes at once',
  format('%s %s', :'r', (select count(*) from person_locations where user_id = test.id('mp_fleet'))), 'off 0');
select test.mpdo('mp_fleet', 'location_prefs_save', '{"sharing_on": true}');
select test.eq('back on: the next report is stored', test.mpdo('mp_fleet', 'location_report', test.mppos(43.65, -79.38)) ->> 'stored', 'true');

-- field staff on a job: locked on, job points kept
select test.mpdo('mp_field', 'location_policy_accept', jsonb_build_object('version', app.location_policy() ->> 'version'));
insert into field_jobs (id, kind, booking_id, vehicle_id, assigned_to, scheduled_at, place, status)
values (test.id('job:mp1'), 'handover', test.id('booking:MP-1'), test.id('vehicle:mp_car'), test.id('mp_field'), now() + interval '30 minutes', '1 Example St', 'acknowledged');
select test.mpdo('mp_field', 'location_report', test.mppos(43.60, -79.50, 'app')) ->> 'reason' as r \gset
select test.eq('field staff on a job, not clocked in: stored for the job, with a job point', format('%s %s %s', :'r',
  (select source || '/' || (field_job_id = test.id('job:mp1')) from person_locations where user_id = test.id('mp_field')),
  (select count(*) from location_job_points where field_job_id = test.id('job:mp1'))), 'job app/true 1');
select test.throws('during an active job, sharing cannot be turned off', $$ select test.mpdo('mp_field', 'location_prefs_save', '{"sharing_on": false}') $$, '%stays on during an active job%');
update field_jobs set status = 'done', completed_at = now() where id = test.id('job:mp1');
select test.eq('the job done (not on shift): the position leaves the map at once; the job''s point stays as its proof',
  format('%s %s', (select count(*) from person_locations where user_id = test.id('mp_field')), (select count(*) from location_job_points where field_job_id = test.id('job:mp1'))), '0 1');

-- ================================================================ 3. renters and owners: only around a pickup or return
select test.mpdo('mp_rita', 'location_report', test.mppos(43.66, -79.39)) ->> 'stored' as r \gset
select test.eq('Rita, pickup in an hour: stored for the pickup', format('%s %s', :'r',
  (select reason || '/' || (booking_id = test.id('booking:MP-1')) from person_locations where user_id = test.id('mp_rita'))), 'true pickup/true');
select test.mpdo('mp_sam', 'location_report', test.mppos(43.70, -79.30)) ->> 'why' as r \gset
select test.eq('Sam, pickup in 10 days: hidden, nothing stored', format('%s %s', :'r',
  (select count(*) from person_locations where user_id = test.id('mp_sam'))), 'no_booking 0');
select test.eq('the owner of the car, at the same pickup: stored', test.mpdo('mp_owner', 'location_report', test.mppos(43.67, -79.41)) ->> 'stored', 'true');

-- ================================================================ 4. who sees whom
select test.eq('Admin and Fleet see everyone on the map (staff on shift, the renter and the owner)', test.mpwho('mp_admin') || ' | ' || test.mpwho('mp_fleet'),
  'Mp Fleet,Mp Owner,Mp Rita | Mp Fleet,Mp Owner,Mp Rita');
select test.eq('customer service sees only the renter at a pickup; Finance and field staff see no one',
  format('%s | %s | %s %s', test.mpwho('mp_cs'), test.mpwho('mp_fin'), test.mpread('mp_fin', 'live_people') ->> 'scope', test.mpread('mp_cs', 'live_people') ->> 'scope'), 'Mp Rita |  | none renters');
select test.throws('a renter cannot read the map', $$ select test.mpread('mp_rita', 'live_people') $$, '%Staff only%');
select test.eq('a marker carries the role, the reason and the booking', (select format('%s %s %s', x ->> 'role', x ->> 'reason', x ->> 'booking_number')
  from jsonb_array_elements(test.mpread('mp_admin', 'live_people') -> 'people') x where x ->> 'name' = 'Mp Rita'), 'renter pickup MP-1');
select test.eq('my_location tells the person their own state', (select format('%s %s %s', s ->> 'kind', s ->> 'share', (s -> 'latest' is not null)::text) from test.mpread('mp_rita', 'my_location') s), 'renter true true');

-- ================================================================ 5. off means off; the job purges what stops qualifying
select test.mpdo('mp_rita', 'location_prefs_save', '{"sharing_on": false}') ->> 'share' as r \gset
select test.eq('Rita turns it off: her position goes at once',
  format('%s %s', :'r', (select count(*) from person_locations where user_id = test.id('mp_rita'))), 'false 0');
update staff_clock_entries set ended_at = now() where user_id = test.id('mp_fleet') and ended_at is null;
select ((app.location_purge() ->> 'locations_deleted')::int >= 1)::text as r \gset
select test.eq('clocked out: the location job deletes the position (no history)',
  format('%s %s', :'r', (select count(*) from person_locations where user_id = test.id('mp_fleet'))), 'true 0');
update location_job_points set at = now() - interval '31 days' where field_job_id = test.id('job:mp1');
select (app.job_tracker() ? 'job_points_deleted')::text as r \gset
select test.eq('a job''s points are deleted after 30 days', format('%s %s', :'r', (select count(*) from location_job_points where field_job_id = test.id('job:mp1'))), 'true 0');

-- ================================================================ 6. the notification
select app.process_events(100000);
select test.eq('the policy copy: a branded email to the staff member, in-app and push, locked (transactional)',
  format('%s %s %s %s', (select count(*) from notification_outbox o where o.code = 'staff_location_policy' and o.recipient_user_id = test.id('mp_fleet')),
    (select count(*) from notifications n where n.code = 'staff_location_policy' and n.user_id = test.id('mp_fleet')),
    (select push_topic || '/' || user_can_mute::text || '/' || category from notification_catalogue where code = 'staff_location_policy'),
    (select count(*) from notification_outbox o where o.code = 'staff_location_policy' and o.recipient_user_id = test.id('mp_field'))), '1 1 documents/false/transactional 1');
select test.eq('the guides and the academy section are published', format('%s %s', (select count(*) from academy_sections where slug = 'r48-map-people'),
  (select count(*) from academy_questions q join academy_sections s on s.id = q.section_id where s.slug = 'r48-map-people')), '1 3');
