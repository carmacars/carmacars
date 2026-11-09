-- 99: field jobs go only to field staff who passed the academy and hold a taken shift (migration 0880, release 35, part T,
-- docs/changes/2026-11-08-r35-field-assign-gate.md). Fixtures "r35t"; example.test only.
select test.suite('99 r35t field assignment gate');
grant usage on schema test to service_role;

delete from field_shift_plans; delete from field_shift_slots;
select test.mk_user('r35t_admin', 'admin');
select test.mk_user('r35t_fleet', 'va', 'fleet');
select test.mk_user('r35t_cs', 'va', 'cs');
select test.mk_user('r35t_ok', 'field');
select test.mk_user('r35t_ok2', 'field');
select test.mk_user('r35t_new', 'field');
select test.mk_user('r35t_none', 'field');
select test.mk_owner('r35t_o');
select test.mk_vehicle('R35TA', 'r35t_o', 'managed', 45000, 2500, 3500, date '2026-08-01');
update program_settings set field_jobs_auto_assign = 'least_busy', academy_gate = true;
-- the new hire is held by the academy gate; the others never enrolled
select app.academy_enroll(test.id('r35t_new'), test.id('r35t_admin'), 'hire', now());
create function test.r35t_ops(p_who text, p_name text, p jsonb) returns jsonb language sql as $$ select public.door(test.id(p_who), null, 'ops_do', p_name, p) $$;
create function test.r35t_field(p_who text, p_name text, p jsonb default '{}') returns jsonb language sql as $$ select public.door(test.id(p_who), null, 'field_do', p_name, p) $$;
create function test.r35t_at(p_days integer, p_hour integer) returns timestamptz language sql as $$
  select ((app.today() + p_days)::timestamp + make_interval(hours => p_hour)) at time zone 'America/Toronto' $$;

-- ================================================================ 1. slots
select test.throws('CS cannot publish slots', $$select test.r35t_ops('r35t_cs', 'field_slot_publish', jsonb_build_object('starts_at', test.r35t_at(1, 9), 'ends_at', test.r35t_at(1, 17)))$$, 'Fleet or an Admin');
select test.eq('Fleet publishes the same slot on 3 days', (test.r35t_ops('r35t_fleet', 'field_slot_publish',
  jsonb_build_object('starts_at', test.r35t_at(1, 9), 'ends_at', test.r35t_at(1, 17), 'capacity', 1, 'repeat_days', 3)) ->> 'slots')::int, 3);
select test.throws('a shift of more than 16 hours is refused', $$select test.r35t_ops('r35t_fleet', 'field_slot_publish', jsonb_build_object('starts_at', test.r35t_at(5, 1), 'ends_at', test.r35t_at(5, 20)))$$, '16 hours');
create temp table r35t_slot as select id, starts_at from field_shift_slots order by starts_at limit 1;
grant select on r35t_slot to public;

-- ================================================================ 2. taking shifts
select test.eq('a field person takes a slot', (test.r35t_field('r35t_ok', 'shift_take', jsonb_build_object('slot', (select id from r35t_slot))) ->> 'id') is not null, true);
select test.throws('the slot (capacity 1) is full for the next person', format($$select test.r35t_field('r35t_ok2', 'shift_take', jsonb_build_object('slot', %L))$$, (select id from r35t_slot)), 'full');
select test.throws('a person held by the academy cannot take shifts', format($$select test.r35t_field('r35t_new', 'shift_take', jsonb_build_object('slot', %L))$$, (select id from field_shift_slots order by starts_at offset 1 limit 1)), 'has not passed the academy yet');
select test.throws('Fleet cannot put a held person on a shift either', format($$select test.r35t_ops('r35t_fleet', 'field_shift_plan_add', jsonb_build_object('staff', %L, 'slot', %L))$$, test.id('r35t_new'), (select id from field_shift_slots order by starts_at offset 1 limit 1)), 'academy');
select test.eq('Fleet puts a person on the second day', (test.r35t_ops('r35t_fleet', 'field_shift_plan_add', jsonb_build_object('staff', test.id('r35t_ok2'), 'slot', (select id from field_shift_slots order by starts_at offset 1 limit 1))) ->> 'id') is not null, true);
select test.eq('the open slots show what the person holds', (select jsonb_array_length(public.door(test.id('r35t_ok'), null, 'field_read', 'my_shifts', '{}') -> 'mine')), 1);
select test.throws('a non-field user has no shifts', $$select public.door(test.id('r35t_cs'), null, 'field_read', 'my_shifts', '{}')$$);
select test.eq('audited: every take is a logged row', (select count(*) >= 2 from audit_log where entity_table = 'field_shift_plans' and action = 'INSERT'), true);
-- a held person who somehow holds a shift (direct insert, as a fixture) is still skipped by the automatic assignment
insert into field_shift_plans (slot_id, staff_id, starts_at, ends_at, created_by)
select s.id, test.id('r35t_new'), s.starts_at, s.ends_at, test.id('r35t_admin') from field_shift_slots s order by s.starts_at limit 1;

-- ================================================================ 3. the coverage of the next days
select test.eq('the board shows the next 7 days; the days with nobody are the ones with no taken shift',
  (select string_agg((c ->> 'people'), ',' order by c ->> 'day') from jsonb_array_elements(public.door(test.id('r35t_fleet'), null, 'ops_read', 'field_board', '{}') -> 'coverage') c), '0,2,1,0,0,0,0');
select test.eq('the board lists every field person with the academy state, and the Admin',
  (select string_agg((s ->> 'name') || '=' || (s ->> 'locked') || '/' || (s ->> 'admin'), ',' order by s ->> 'name')
     from jsonb_array_elements(public.door(test.id('r35t_admin'), null, 'ops_read', 'field_board', '{}') -> 'staff') s where s ->> 'name' ilike 'r35t %'),
  'R35t Admin=false/true,R35t New=true/false,R35t None=false/false,R35t Ok=false/false,R35t Ok2=false/false');
select test.throws('CS cannot read the board', $$select public.door(test.id('r35t_cs'), null, 'ops_read', 'field_board', '{}')$$);

-- ================================================================ 4. the automatic assignment
select test.eq('auto: the person holding a shift at that time, not held, gets it', app.field_auto_assignee((select starts_at + interval '1 hour' from r35t_slot)), test.id('r35t_ok'));
select test.eq('auto: a day that has shifts is worked by the people holding one that day', app.field_auto_assignee((select starts_at - interval '2 hours' from r35t_slot)), test.id('r35t_ok'));
select test.eq('auto: the held new hire with a shift is skipped (the first day has only the other person)',
  app.field_auto_assignee((select starts_at + interval '2 hours' from r35t_slot)) = test.id('r35t_ok'), true);
select test.eq('auto: a person with no shift never gets one', (select count(*) from field_shift_plans where staff_id = test.id('r35t_none')), 0::bigint);

-- ================================================================ 4b. work lands only on days with shifts
-- shifts exist on tomorrow (day 1) and the day after (day 2); day 3 and today have none
select test.eq('work day: a day with shifts is its own work day', app.field_work_day(test.r35t_at(1, 10), true), app.today() + 1);
-- 1051: a day with a published shift (taken or not) is a day with shifts; day 3 has an open one, day 4 none
select test.eq('work day: a day with only an open shift is its own work day (1051)', app.field_work_day(test.r35t_at(3, 10), true), app.today() + 3);
select test.eq('work day: known in advance, a day without shifts moves to the day before (day 4 -> day 3)', app.field_work_day(test.r35t_at(4, 10), true), app.today() + 3);
select test.eq('work day: it comes in on a day without shifts: the next day with shifts (today -> day 1)', app.field_work_day(test.r35t_at(0, 12), false), app.today() + 1);
select test.eq('work day: coming in on a day with no later day with shifts: nobody', app.field_work_day(test.r35t_at(30, 12), false) is null, true);
select test.eq('auto: work due on day 3 waits on day 3''s open shift (nobody on it yet, 1051)', app.field_auto_assignee(test.r35t_at(3, 10)) is null, true);
select test.eq('auto: work due today (no shifts today) goes to the next day with shifts: day 1', app.field_auto_assignee(test.r35t_at(0, 23)), test.id('r35t_ok'));
-- a booking whose pickup falls on day 3: its handover job is planned for day 2, at its real time; the booking is untouched
update program_settings set field_jobs_auto = true;
select test.mk_renter('r35t_r');
select test.mk_booking('R35T-1', 'R35TA', 'r35t_r', (app.today() + 3)::text || ' 10:00', (app.today() + 5)::text || ' 10:00', 'confirmed', 30000);
select test.eq('booking: the warning names the handover on the day nobody holds a shift (its open shift is the day it is worked, 1051)',
  (select (w ->> 'leg') || '/' || (w ->> 'day') || '/' || (w ->> 'work_day') from jsonb_array_elements(app.field_no_shift_days(test.id('booking:R35T-1'))) w limit 1),
  'handover/' || (app.today() + 3)::text || '/' || (app.today() + 3)::text);
select test.eq('booking: the Fleet read gives the same', jsonb_array_length(public.door(test.id('r35t_fleet'), null, 'ops_read', 'field_no_shift_days', jsonb_build_object('booking', test.id('booking:R35T-1')))) >= 1, true);
select test.eq('booking: the handover job keeps the real time and waits on day 3''s open shift with nobody (1051)',
  (select coalesce(string_agg((j.assigned_to is null)::text || '/' || coalesce(j.work_day::text, 'own day') || '/' || (j.scheduled_at = test.r35t_at(3, 10))::text, ','), 'none')
     from field_jobs j where j.booking_id = test.id('booking:R35T-1') and j.kind = 'handover'),
  'true/own day/true');
select test.mk_booking('R35T-2', 'R35TA', 'r35t_r', app.today()::text || ' 23:30', (app.today() + 1)::text || ' 12:00', 'confirmed', 30000);
select test.eq('booking: a handover that comes in on a day without shifts goes to the next day with shifts, at its real time',
  (select (j.assigned_to = test.id('r35t_ok'))::text || '/' || j.work_day::text || '/' || (j.scheduled_at = ((app.today()::text || ' 23:30')::timestamp at time zone 'America/Toronto'))::text
     from field_jobs j where j.booking_id = test.id('booking:R35T-2') and j.kind = 'handover'), 'true/' || (app.today() + 1)::text || '/true');
select test.eq('booking: its own time is unchanged', (select pickup_at = test.r35t_at(3, 10) from bookings where id = test.id('booking:R35T-1')), true);
select test.eq('booking: a pickup on a day with shifts has no warning', jsonb_array_length(app.field_no_shift_days(null)) >= 0 and not exists (
  select 1 from jsonb_array_elements(app.field_no_shift_days(null)) w where (w ->> 'day')::date = app.today() + 1 and w ->> 'booking_number' = 'R35T-1'), true);
update program_settings set field_jobs_auto_assign = 'none';
select test.eq('auto: off means nobody', app.field_auto_assignee((select starts_at + interval '1 hour' from r35t_slot)) is null, true);
update program_settings set field_jobs_auto_assign = 'least_busy';
-- a cancelled shift no longer counts
select test.ok('Fleet takes the person off the first shift', test.r35t_ops('r35t_fleet', 'field_shift_plan_cancel', jsonb_build_object('id', (select id from field_shift_plans where staff_id = test.id('r35t_ok') and cancelled_at is null limit 1))) is not null);
select test.eq('auto: a cancelled shift gives nobody', app.field_auto_assignee((select starts_at + interval '1 hour' from r35t_slot)) is null, true);

-- ================================================================ 5. manual assignment
create temp table r35t_job as select app.create_field_job('detail', test.id('vehicle:R35TA'), test.r35t_at(2, 11), test.id('r35t_fleet')) as id;
grant select on r35t_job to public;
select test.throws('manual: a person the academy holds is refused with a clear message', format($$select test.r35t_ops('r35t_fleet', 'field_job_assign', jsonb_build_object('id', %L, 'to', %L))$$, (select id from r35t_job), test.id('r35t_new')), 'R35t New has not passed the academy yet');
select test.throws('manual: the same when the job is made with that person', format($$select app.create_field_job('detail', %L, now() + interval '3 days', %L, null, %L)$$, test.id('vehicle:R35TA'), test.id('r35t_fleet'), test.id('r35t_new')), 'has not passed the academy yet');
select test.ok('manual: a person who passed is assigned', test.r35t_ops('r35t_fleet', 'field_job_assign', jsonb_build_object('id', (select id from r35t_job), 'to', test.id('r35t_ok2'))) is not null);
select test.eq('manual: assigned (and told)', (select assigned_to from field_jobs where id = (select id from r35t_job)) = test.id('r35t_ok2'), true);
select test.eq('manual: the Admin can be assigned', (test.r35t_ops('r35t_admin', 'field_job_assign', jsonb_build_object('id', (select id from r35t_job), 'to', test.id('r35t_admin'))) ->> 'id') is not null, true);
select test.eq('manual: the removed person was told about the change (a reassignment)', (select count(*) from app_events where code = 'staff_field_job_changed' and entity_id = (select id from r35t_job) and payload ->> 'recipient_user_id' = test.id('r35t_ok2')::text), 1::bigint);
select test.eq('Admin: the field portal opens for the Admin who holds a job', (public.door(test.id('r35t_admin'), null, 'roles', null, '{}') ->> 'field')::boolean, true);
select test.ok('Admin: the field jobs read answers', public.door(test.id('r35t_admin'), null, 'field_read', 'jobs', '{}') is not null);

-- ================================================================ 6. taking a job off
select test.ok('unassign: a job is taken off (quietly)', test.r35t_ops('r35t_fleet', 'field_job_unassign', jsonb_build_object('id', (select id from r35t_job))) is not null);
select test.eq('unassign: nobody has it', (select assigned_to is null from field_jobs where id = (select id from r35t_job)), true);
select test.eq('unassign: the Admin who had it was not told (no "tell them")', (select count(*) from app_events where code = 'staff_field_job_changed' and entity_id = (select id from r35t_job) and payload ->> 'recipient_user_id' = test.id('r35t_admin')::text), 0::bigint);
select test.ok('assign again', test.r35t_ops('r35t_fleet', 'field_job_assign', jsonb_build_object('id', (select id from r35t_job), 'to', test.id('r35t_ok2'))) is not null);
select test.ok('unassign with "tell them" ticked', test.r35t_ops('r35t_fleet', 'field_job_assign', jsonb_build_object('id', (select id from r35t_job), 'to', '', 'tell', true)) is not null);
select test.eq('unassign: ticked, the person was told', (select count(*) from app_events where code = 'staff_field_job_changed' and entity_id = (select id from r35t_job) and payload ->> 'recipient_user_id' = test.id('r35t_ok2')::text and payload ->> 'job_change_headline' = 'This job is no longer yours'), 2::bigint);
select test.throws('CS cannot unassign', format($$select test.r35t_ops('r35t_cs', 'field_job_unassign', jsonb_build_object('id', %L))$$, (select id from r35t_job)));

-- ================================================================ 7. row-level security
set role authenticated;
select set_config('request.jwt.claim.sub', test.id('r35t_ok2')::text, false);
select test.eq('rls: a field person sees only their own taken shifts', (select count(*) from field_shift_plans where staff_id <> test.id('r35t_ok2')), 0::bigint);
select test.eq('rls: and cannot write', (select count(*) from (select 1) x where has_table_privilege('authenticated', 'field_shift_plans', 'insert')), 0::bigint);
select set_config('request.jwt.claim.sub', test.id('r35t_cs')::text, false);
select test.eq('rls: customer service sees none', (select count(*) from field_shift_plans), 0::bigint);
reset role;
select test.ok('privileges: the board functions are for the service role only', has_function_privilege('service_role', 'app.field_board(uuid)', 'execute') and not has_function_privilege('authenticated', 'app.field_board(uuid)', 'execute'));
