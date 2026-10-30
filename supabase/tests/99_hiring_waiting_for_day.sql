-- 99: no interview invitation without an open call time (migration 0211). Uses test.h99field of 99_careers_hiring.sql.
-- Fixtures start with "hwd".
select test.suite('99 hiring waiting for a day');
select test.mk_user('hwd_admin', 'admin');

-- no open day for any role (the days of earlier tests are put back at the end)
create temp table hwd_days as select id from interview_days where active;
update interview_days set active = false where id in (select id from hwd_days);
create temp table hwd as select null::text k, null::jsonb v limit 0;
insert into hwd select 'a', public.server_hiring_apply(jsonb_build_object('role', 'field-staff', 'full_name', 'Hwda Tester', 'email', 'hwda@hwd.example.test', 'phone', '416-555-0177', 'answers', test.h99field()), null);
insert into hwd select 'b', public.server_hiring_apply(jsonb_build_object('role', 'field-staff', 'full_name', 'Hwdb Tester', 'email', 'hwdb@hwd.example.test', 'phone', '416-555-0178', 'answers', test.h99field()), null);
select app.process_events();

select test.eq('a pass with no open day: invited', (select v ->> 'outcome' from hwd where k = 'a'), 'invited');
select test.ok('waiting for a day, and no invitation email', (select waiting_for_day from job_applications where email = 'hwda@hwd.example.test')
  and not exists (select 1 from notification_outbox where code = 'applicant_invited' and to_address = 'hwda@hwd.example.test'));
-- b was emailed before this release, while no time was open (as in production on October 30)
update job_applications set waiting_for_day = false, no_slots_since = null where email = 'hwdb@hwd.example.test';
select test.ok('the booking link says there is no time', (public.server_hiring_booking((select token from job_applications where email = 'hwdb@hwd.example.test')) ->> 'no_slots')::boolean);
select test.ok('and records the visit', (select no_slots_seen_at is not null and no_slots_since is not null from job_applications where email = 'hwdb@hwd.example.test'));
select test.ok('Admin > Hiring: the role''s applicants invited with no open day', exists (
  select 1 from jsonb_array_elements(public.door(test.id('hwd_admin'), 'aal2', 'admin_read', 'hiring', '{}') -> 'waiting') w where w ->> 'slug' = 'field-staff' and (w ->> 'count')::int >= 2));

-- the Admin adds a day for Field staff: the waiting invitation goes, and "New times are open" to the one already emailed
select test.ok('a day added releases them', (public.door(test.id('hwd_admin'), 'aal2', 'admin_do', 'hiring_day_save',
  jsonb_build_object('day', app.today() + 4, 'start_time', '09:00', 'end_time', '12:00', 'mode', 'phone', 'roles', 'field-staff')) ->> 'released')::int >= 2);
select app.process_events();
select test.eq('the waiting invitation is queued', (select status from notification_outbox where code = 'applicant_invited' and to_address = 'hwda@hwd.example.test' order by created_at desc limit 1), 'queued');
select test.ok('"New times are open" to the one emailed with no time, with every variable', exists (select 1 from notification_outbox where code = 'applicant_new_times' and to_address = 'hwdb@hwd.example.test'
  and status = 'queued' and missing_variables = '{}' and payload ->> 'booking_url' like '%/careers/book/%'));
select test.ok('no one is waiting any more', not exists (select 1 from job_applications where email like '%@hwd.example.test' and (waiting_for_day or no_slots_since is not null)));
select test.ok('the warning is gone for the role', not exists (
  select 1 from jsonb_array_elements(public.door(test.id('hwd_admin'), 'aal2', 'admin_read', 'hiring', '{}') -> 'waiting') w where w ->> 'slug' = 'field-staff'));
select test.eq('a pass now is invited', (select public.server_hiring_apply(jsonb_build_object('role', 'field-staff', 'full_name', 'Hwdc Tester', 'email', 'hwdc@hwd.example.test', 'phone', '416-555-0179', 'answers', test.h99field()), null) ->> 'outcome'), 'invited');
select test.eq('and gets the invitation at once', (select waiting_for_day from job_applications where email = 'hwdc@hwd.example.test'), false);

update interview_days set active = true where id in (select id from hwd_days);
