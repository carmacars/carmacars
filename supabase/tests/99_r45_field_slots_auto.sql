-- 99: migration 2864 (release 45): field shift slots published by themselves. On by default with the owner's template
-- (10:00 to 17:00, one person, every second day from November 23, 2026), 14 days ahead; only forward after the latest
-- slot already published, never before field_slots_auto_from; a cancelled one is not published again; a handover or return
-- no slot covers gets a slot of its own (not before field_slots_auto_from); the hourly job does it. Fixtures "fsa".
select test.suite('99 r45 field slots auto (2864)');

select test.eq('on by default', (select column_default from test.shipped_defaults where column_name = 'field_slots_auto'), 'true');
select test.eq('the default template: 10:00 to 17:00, one person, every second day from November 23, 2026',
  (select string_agg((t ->> 'start') || '-' || (t ->> 'end') || ':' || (t ->> 'people') || ':every ' || (t ->> 'every') || ' from ' || (t ->> 'anchor'), ',') from jsonb_array_elements((app.settings()).field_slot_template) t),
  '10:00-17:00:1:every 2 from 2026-11-23');
select test.eq('14 days ahead, nothing before November 23, 2026', (app.settings()).field_slots_auto_days || '|' || (app.settings()).field_slots_auto_from, '14|2026-11-23');
select test.throws('a template must be well formed', $$ update program_settings set field_slot_template = '[{"days": [8], "start": "9", "end": "15:00"}]' $$, 'field_slot_template_ok');
select test.throws('"every" needs its anchor day', $$ update program_settings set field_slot_template = '[{"every": 2, "start": "10:00", "end": "17:00"}]' $$, 'field_slot_template_ok');

-- a clean world: no slots, the template every second day from today, from today on
delete from field_shift_offers;
delete from field_shift_plans;
delete from field_shift_slots;
update program_settings set field_slots_auto = true, field_slots_auto_days = 6, field_slots_auto_from = app.today(),
  field_slot_template = jsonb_build_array(jsonb_build_object('every', 2, 'anchor', app.today() + 1, 'start', '10:00', 'end', '17:00', 'people', 1));
select test.mk_user('fsa_fleet', 'va', 'fleet');

select app.field_slots_auto_publish(now());
select test.eq('every second day in the window, at 10:00 to 17:00 Toronto, for one person',
  (select string_agg((app.local_date(starts_at) - app.today())::text || '@' || to_char(starts_at at time zone 'America/Toronto', 'HH24:MI') || '-' || to_char(ends_at at time zone 'America/Toronto', 'HH24:MI') || 'x' || capacity, ',' order by starts_at)
     from field_shift_slots where auto_source = 'template'), '1@10:00-17:00x1,3@10:00-17:00x1,5@10:00-17:00x1');
select test.eq('each once: again publishes nothing new', (app.field_slots_auto_publish(now()) ->> 'template'), '0');

-- only forward from the latest slot: a later window adds only the days after it; a cancelled last one is not redone
update field_shift_slots set cancelled_at = now(), cancelled_by = test.id('fsa_fleet') where id = (select id from field_shift_slots where auto_source = 'template' order by starts_at desc limit 1);
update program_settings set field_slots_auto_days = 10;
select app.field_slots_auto_publish(now());
select test.eq('forward only, the rhythm kept, the cancelled one not published again',
  (select string_agg((app.local_date(starts_at) - app.today())::text || case when cancelled_at is not null then 'c' else '' end, ',' order by starts_at) from field_shift_slots where auto_source = 'template'), '1,3,5c,7,9');

-- never before field_slots_auto_from, nor before a slot already published by hand later on
delete from field_shift_slots;
update program_settings set field_slots_auto_from = app.today() + 4;
select app.field_slots_auto_publish(now());
select test.eq('nothing before field_slots_auto_from', (select min(app.local_date(starts_at)) - app.today() from field_shift_slots where auto_source = 'template'), 5);
delete from field_shift_slots;
update program_settings set field_slots_auto_from = app.today();
insert into field_shift_slots (starts_at, ends_at, capacity, created_by)
select ((app.today() + 5) + time '10:00') at time zone 'America/Toronto', ((app.today() + 5) + time '17:00') at time zone 'America/Toronto', 1, test.id('fsa_fleet');
select app.field_slots_auto_publish(now());
select test.eq('the days before a slot already published are never filled in', (select string_agg((app.local_date(starts_at) - app.today())::text, ',' order by starts_at) from field_shift_slots where cover_booking_id is null), '5,7,9');

-- a handover at 22:00 no slot covers: a slot of its own; one before field_slots_auto_from: none
select test.mk_owner('fsa_o'); select test.mk_vehicle('FSA1', 'fsa_o'); select test.mk_renter('fsa_r');
select test.mk_booking('CC-FSA1', 'FSA1', 'fsa_r', to_char(app.today() + 7, 'YYYY-MM-DD') || ' 22:00', to_char(app.today() + 9, 'YYYY-MM-DD') || ' 12:00', 'confirmed', 10000);
select test.mk_booking('CC-FSA2', 'FSA1', 'fsa_r', to_char(app.today() + 2, 'YYYY-MM-DD') || ' 22:00', to_char(app.today() + 3, 'YYYY-MM-DD') || ' 08:00', 'confirmed', 10000);
update program_settings set field_slots_auto_from = app.today() + 4;
select app.field_slots_auto_publish(now());
select test.eq('the uncovered handover gets a covering slot; the return at 12:00 is in a shift already',
  (select string_agg(cover_leg, ',') from field_shift_slots where cover_booking_id = test.id('booking:CC-FSA1')), 'handover');
select test.ok('90 minutes either side of it', exists (select 1 from field_shift_slots s join bookings b on b.id = s.cover_booking_id
  where b.booking_number = 'CC-FSA1' and s.starts_at = b.pickup_at - interval '90 minutes' and s.ends_at = b.pickup_at + interval '90 minutes'));
select test.ok('none before field_slots_auto_from', not exists (select 1 from field_shift_slots where cover_booking_id = test.id('booking:CC-FSA2')));
select app.field_slots_auto_publish(now());
select test.eq('once', (select count(*) from field_shift_slots where cover_booking_id = test.id('booking:CC-FSA1')), 1::bigint);

-- the hourly job does it; off: nothing
select test.ok('the hourly job publishes', app.job_field_shift_plan(now()) like '% template slot(s), % covering slot(s) published; %');
update program_settings set field_slots_auto = false;
select test.eq('off: nothing published', (app.field_slots_auto_publish(now()) ->> 'off'), 'true');

-- 2867: Fleet giving a job to a person with no shift that day puts them on that day's shift first
select test.mk_user('fsa_field', 'field', null, 'driver');
update academy_enrollments set lock_from = null where user_id = test.id('fsa_field');
insert into field_shift_slots (starts_at, ends_at, capacity, note) values
  ((app.today() + 11)::timestamp at time zone 'America/Toronto' + interval '10 hours', (app.today() + 11)::timestamp at time zone 'America/Toronto' + interval '17 hours', 1, 'fsa 2867');
insert into field_jobs (id, kind, booking_id, vehicle_id, scheduled_at, place)
select test.id('job:fsa2867'), 'handover', b.id, b.vehicle_id, (app.today() + 11)::timestamp at time zone 'America/Toronto' + interval '12 hours', '1 Main St'
  from bookings b where b.booking_number = 'CC-FSA1';
select app.assign_field_job(test.id('job:fsa2867'), test.id('fsa_field'), test.id('fsa_fleet'));
select test.ok('assigned by Fleet with no shift that day: put on the day''s shift, then given the job',
  (select assigned_to = test.id('fsa_field') and shift_slot_id = (select id from field_shift_slots where note = 'fsa 2867') from field_jobs where id = test.id('job:fsa2867'))
  and exists (select 1 from field_shift_plans p join field_shift_slots s on s.id = p.slot_id where s.note = 'fsa 2867' and p.staff_id = test.id('fsa_field') and p.cancelled_at is null));
update field_jobs set status = 'cancelled' where id = test.id('job:fsa2867');
update field_shift_plans set cancelled_at = now(), cancelled_by = test.id('fsa_fleet') where slot_id in (select id from field_shift_slots where note = 'fsa 2867') and cancelled_at is null;
update field_shift_slots set cancelled_at = now(), cancelled_by = test.id('fsa_fleet') where note = 'fsa 2867';

-- as the other suites expect it
delete from field_shift_slots where auto_source is not null and not exists (select 1 from field_shift_plans p where p.slot_id = field_shift_slots.id);
update program_settings set field_slot_template = '[{"every": 2, "anchor": "2026-11-23", "start": "10:00", "end": "17:00", "people": 1}]', field_slots_auto_days = 14, field_slots_auto_from = '2026-11-23';
