-- 99: calendar invites by email (migration 5000, docs/changes/2026-11-24-r50-calendar-invites.md): the weekly townhall to
-- every staff member and Admin (REQUEST with the weekly RRULE, Toronto time), its updates and cancellations, the series
-- cancelled for someone who left, the interview call's REQUEST and CANCEL, the files on the email and the download.
-- Fixtures "ci50".
select test.suite('99 r50 calendar invites: townhall series, updates, cancellations, interview calls, the attached .ics');
select test.mk_user('ci50_admin', 'admin');
select test.mk_user('ci50_sales', 'va', 'sales');
select test.mk_user('ci50_field', 'field');
create function test.ci50_last(p_user text) returns calendar_invites language sql stable as $$
  select * from calendar_invites where user_id = test.id(p_user) and kind = 'townhall' order by created_at desc, seq desc limit 1 $$;
create function test.ci50_n(p_user text) returns bigint language sql stable as $$
  select count(*) from calendar_invites where user_id = test.id(p_user) and kind = 'townhall' $$;

-- ================================================================ 1. the series
select app.townhall_invites_sweep(now());
select test.eq('a staff member gets the weekly invite', (test.ci50_last('ci50_sales')).method, 'REQUEST');
select test.eq('field staff too', (test.ci50_last('ci50_field')).method, 'REQUEST');
select test.eq('and the Admin', (test.ci50_last('ci50_admin')).method, 'REQUEST');
select test.eq('the first invite is SEQUENCE 0', (test.ci50_last('ci50_sales')).seq, 0);
select test.eq('the email that carries it is queued for the person', (select count(*) from app_events where code = 'staff_townhall_invite' and payload ->> 'recipient_user_id' = test.id('ci50_sales')::text), 1::bigint);
select test.ok('the email carries the invite''s id', exists (select 1 from app_events where code = 'staff_townhall_invite' and payload ->> '_ics_id' = (test.ci50_last('ci50_sales')).id::text));
select test.eq('a second sweep sends nothing new', app.townhall_invites_sweep(now()), 0);

create temp table ci50_ics as select app.calendar_invite_ics((test.ci50_last('ci50_sales')).id) as t;
select test.ok('METHOD:REQUEST', (select t from ci50_ics) like '%METHOD:REQUEST%');
select test.ok('weekly on the townhall''s day', (select t from ci50_ics) like '%RRULE:FREQ=WEEKLY;BYDAY=' || app.ics_byday((app.settings()).townhall_weekday) || E'\r\n%');
select test.ok('Toronto time with its zone', (select t from ci50_ics) like '%BEGIN:VTIMEZONE%TZID:America/Toronto%' and (select t from ci50_ics) like '%DTSTART;TZID=America/Toronto:' || app.ics_local(app.townhall_next(now())) || '%');
select test.ok('the start is the townhall''s local time', (select t from ci50_ics) like '%T' || replace(lpad((app.settings()).townhall_time, 5, '0'), ':', '') || '00%');
select test.ok('the organizer', (select t from ci50_ics) like '%ORGANIZER;CN=CarmaCars:mailto:hello@carmacars.ca%');
select test.ok('the location is the call page in the site', (select t from ci50_ics) like '%LOCATION:https://carmacars.ca/staff/townhall/live%');
select test.ok('the person is the attendee', (select t from ci50_ics) like '%ATTENDEE;%mailto:ci50_sales@example.test%');
select test.ok('lines end in CRLF', (select t from ci50_ics) like E'BEGIN:VCALENDAR\r\n%' and (select t from ci50_ics) like E'%END:VCALENDAR\r\n');
select test.ok('no line is longer than 75 characters', not exists (select 1 from regexp_split_to_table((select t from ci50_ics), E'\r\n') l where length(l) > 75));

-- the file on the email (the events routed to the outbox as the notify job does)
select app.process_events();
create temp table ci50_files as select app.outbox_inline_files(o.id) f from notification_outbox o join app_events e on e.id = o.event_id
 where e.payload ->> '_ics_id' = (test.ci50_last('ci50_sales')).id::text;
select test.eq('the invite email is in the outbox', (select count(*) from ci50_files), 1::bigint);
select test.eq('it attaches a text/calendar file', (select f #>> '{0,content_type}' from ci50_files), 'text/calendar; method=REQUEST; charset=UTF-8');
select test.eq('named for the townhall', (select f #>> '{0,filename}' from ci50_files), 'carmacars-townhall.ics');
select test.ok('the file is the invite', (select f #>> '{0,content}' from ci50_files) like 'BEGIN:VCALENDAR%METHOD:REQUEST%');
select test.eq('an email without an invite attaches nothing', app.outbox_inline_files(gen_random_uuid()), '[]'::jsonb);

-- ================================================================ 2. a new time: an update of the same event
update program_settings set townhall_time = '14:30' where id = (app.settings()).id;
select test.eq('a new time sends the update at once', (test.ci50_last('ci50_sales')).seq, 1);
select test.ok('same UID, new start', (test.ci50_last('ci50_sales')).uid = 'townhall@carmacars.ca' and app.calendar_invite_ics((test.ci50_last('ci50_sales')).id) like '%T143000%');
select test.ok('the email says it is an update', (select (payload ->> 'is_update')::boolean from app_events where code = 'staff_townhall_invite' and payload ->> '_ics_id' = (test.ci50_last('ci50_sales')).id::text));

-- ================================================================ 3. one townhall cancelled ahead, then back on
insert into townhall_cancellations (meeting_at, reason, cancelled_by) values (app.townhall_next(now() + interval '8 days'), 'Public holiday', test.id('ci50_admin'));
select test.eq('a cancelled townhall sends CANCEL', (test.ci50_last('ci50_field')).method, 'CANCEL');
select test.eq('for that one meeting', (test.ci50_last('ci50_field')).recurrence_id, app.townhall_next(now() + interval '8 days'));
select test.ok('RECURRENCE-ID and STATUS:CANCELLED in the file', app.calendar_invite_ics((test.ci50_last('ci50_field')).id) like '%METHOD:CANCEL%RECURRENCE-ID;TZID=America/Toronto:%STATUS:CANCELLED%');
select test.ok('the cancellation email names the reason', exists (select 1 from app_events where code = 'staff_townhall_cancelled' and payload ->> 'reason' = 'Public holiday' and payload ->> 'recipient_user_id' = test.id('ci50_field')::text));
select test.eq('nothing more on the next sweep', app.townhall_invites_sweep(now()), 0);
delete from townhall_cancellations where reason = 'Public holiday';
select test.eq('back on: the series is sent again', (test.ci50_last('ci50_field')).method, 'REQUEST');
select test.ok('with a higher SEQUENCE', (test.ci50_last('ci50_field')).seq > 1);

-- ================================================================ 4. someone leaves the team
update staff_profiles set is_active = false where user_id = test.id('ci50_field');
select app.townhall_invites_sweep(now());
select test.ok('the series is cancelled for them', (test.ci50_last('ci50_field')).method = 'CANCEL' and (test.ci50_last('ci50_field')).recurrence_id is null);
select test.eq('once', app.townhall_invites_sweep(now()), 0);
select test.eq('the others keep theirs', (test.ci50_last('ci50_sales')).method, 'REQUEST');

-- ================================================================ 5. the download
select test.ok('Add to calendar: METHOD:PUBLISH, the same UID', app.door(test.id('ci50_sales'), 'aal2', 'ops_read', 'townhall_ics', '{}') ->> 'ics' like '%METHOD:PUBLISH%UID:townhall@carmacars.ca%');
select test.ok('without an attendee', app.door(test.id('ci50_sales'), 'aal2', 'ops_read', 'townhall_ics', '{}') ->> 'ics' not like '%ATTENDEE%');
select test.throws('a renter cannot read it', $$select app.townhall_ics(test.mk_renter('ci50_renter'))$$, '%Staff only%');

-- ================================================================ 6. interview calls
insert into interview_days (day, start_time, end_time, mode, note) values (app.local_date(now()) + 2, '08:00', '20:00', 'video', 'ci50 day');
insert into interview_slots (day_id, starts_at, ends_at) select d.id, now() + interval '44 hours', now() + interval '44 hours 15 minutes' from interview_days d where d.note = 'ci50 day';
insert into interview_slots (day_id, starts_at, ends_at) select d.id, now() + interval '45 hours', now() + interval '45 hours 15 minutes' from interview_days d where d.note = 'ci50 day';
insert into job_applications (role_id, status, full_name, email, phone) select id, 'invited', 'Ci Fifty', 'cand@ci50.example.test', '+14165550111' from hiring_roles where slug = 'va-fleet-operations';
create function test.ci50_app() returns job_applications language sql stable as $$ select * from job_applications where email = 'cand@ci50.example.test' $$;
create function test.ci50_iv() returns calendar_invites language sql stable as $$
  select * from calendar_invites where application_id = (test.ci50_app()).id order by created_at desc, seq desc limit 1 $$;
select app.hiring_book((test.ci50_app()).token, (select s.id from interview_slots s join interview_days d on d.id = s.day_id where d.note = 'ci50 day' order by s.starts_at limit 1));
select test.eq('booking sends the call''s invite', (test.ci50_iv()).method, 'REQUEST');
select test.ok('at the slot''s time, with the call link', (test.ci50_iv()).starts_at = (select s.starts_at from interview_slots s where s.id = (test.ci50_app()).slot_id)
  and app.calendar_invite_ics((test.ci50_iv()).id) like '%LOCATION:' || (test.ci50_app()).meet_url || '%');
select test.ok('on the booking confirmation', exists (select 1 from app_events where code = 'applicant_booked' and payload ->> '_ics_id' = (test.ci50_iv()).id::text));
select app.hiring_book((test.ci50_app()).token, (select s.id from interview_slots s join interview_days d on d.id = s.day_id where d.note = 'ci50 day' order by s.starts_at desc limit 1));
select test.eq('moved: an update of the same event', (test.ci50_iv()).seq, 1);
select test.ok('same UID, new time', (test.ci50_iv()).uid = 'interview-' || (test.ci50_app()).id || '@carmacars.ca' and (test.ci50_iv()).method = 'REQUEST'
  and (test.ci50_iv()).starts_at = (select s.starts_at from interview_slots s where s.id = (test.ci50_app()).slot_id));
select app.hiring_cancel((test.ci50_app()).token);
select test.eq('cancelled: METHOD:CANCEL', (test.ci50_iv()).method, 'CANCEL');
select test.ok('on the cancellation email', exists (select 1 from app_events where code = 'applicant_cancelled' and payload ->> '_ics_id' = (test.ci50_iv()).id::text));
select test.ok('the file says so', app.calendar_invite_ics((test.ci50_iv()).id) like '%METHOD:CANCEL%SEQUENCE:2%STATUS:CANCELLED%');
select test.eq('a reminder carries no invite', app.interview_invite('applicant_reminder', test.ci50_app()), null::uuid);
