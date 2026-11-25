-- 99: R50 hotfix (5064, 5065; docs/changes/2026-11-25-r50-hotfix.md). The Admin's calendar: the townhall invite email is
-- never put in the Admin's daily digest or held by the 3-an-hour cap; the Admin's calendar feed carries the weekly townhall
-- (8 meetings, stable UIDs, a cancelled one left out) and every booked interview call; a field staff member's feed carries
-- the townhall too. Fixtures "r5hc".
select test.suite('99 r50 hotfix: the Admin''s calendar (townhall invite not digested or capped; the feed has townhalls and interviews)');
select test.mk_user('r5hc_admin', 'admin');
select test.mk_user('r5hc_field', 'field');
-- the events earlier files left unprocessed are not this file's: marked done so process_events() reaches this file's
update app_events set processed_at = now(), process_note = 'test: left by an earlier file' where processed_at is null;

-- ================================================================ 1. the townhall invite reaches the Admin on its own
-- the Admin is at the cap of immediate emails (3 urgent ones in the last hour)
insert into notification_outbox (id, code, category, priority, audience, recipient_user_id, to_address, to_name, payload, dedupe_key, status, status_reason, send_after)
select gen_random_uuid(), 'staff_digest_hourly', 'transactional', 2, 'staff_admin', test.id('r5hc_admin'), 'r5hc_admin@example.test', 'R5hc', '{}'::jsonb,
       'r5hc-cap-' || g, 'queued', 'urgent', now() from generate_series(1, 3) g;
delete from calendar_invites where user_id = test.id('r5hc_admin');
select app.townhall_invites_sweep(now());
select app.process_events();
create temp table r5hc_inv as select o.* from notification_outbox o where o.code = 'staff_townhall_invite' and o.recipient_user_id = test.id('r5hc_admin');
select test.eq('the Admin''s townhall invite is in the outbox', (select count(*) from r5hc_inv), 1::bigint);
select test.ok('never in the Admin''s daily digest, never held by the cap: it goes on its own',
  (select status in ('queued', 'delayed', 'sending', 'sent') and coalesce(status_reason, '') not like '%digest%' from r5hc_inv));
select test.eq('no digest line was made of it', (select count(*) from staff_email_digest_items i where i.outbox_id = (select id from r5hc_inv)), 0::bigint);
select test.ok('it carries the .ics', (select app.outbox_inline_files(id) #>> '{0,content}' from r5hc_inv) like 'BEGIN:VCALENDAR%METHOD:REQUEST%');

-- ================================================================ 2. the Admin's feed: townhalls and interviews
insert into interview_days (day, start_time, end_time, mode, note) values (app.local_date(now()) + 3, '08:00', '20:00', 'video', 'r5hc day');
insert into interview_slots (day_id, starts_at, ends_at) select d.id, now() + interval '70 hours', now() + interval '70 hours 15 minutes' from interview_days d where d.note = 'r5hc day';
insert into job_applications (role_id, status, full_name, email, phone) select id, 'invited', 'Rhona Hotfix', 'cand@r5hc.example.test', '+14165550177' from hiring_roles where slug = 'va-fleet-operations';
select app.hiring_book((select token from job_applications where email = 'cand@r5hc.example.test'),
  (select s.id from interview_slots s join interview_days d on d.id = s.day_id where d.note = 'r5hc day' limit 1));
select test.eq('the interview is booked', (select status from job_applications where email = 'cand@r5hc.example.test'), 'booked');

select app.shift_feed_set(test.id('r5hc_admin'), '{"scope":"all","action":"create"}');
select app.shift_feed_set(test.id('r5hc_field'), '{"scope":"mine","action":"create"}');
create temp table r5hc_feed as select
  app.shift_feed_ics((select token from shift_feeds where user_id = test.id('r5hc_admin') and scope = 'all' and revoked_at is null)) as admin_ics,
  app.shift_feed_ics((select token from shift_feeds where user_id = test.id('r5hc_field') and scope = 'mine' and revoked_at is null)) as field_ics;
select test.ok('the Admin''s feed has the next townhall, Toronto time, with a stable UID',
  (select admin_ics from r5hc_feed) like '%UID:townhall-' || to_char(app.townhall_next(now()) at time zone 'America/Toronto', 'YYYYMMDD') || '@carmacars.ca%'
  and (select admin_ics from r5hc_feed) like '%DTSTART;TZID=America/Toronto:' || app.ics_local(app.townhall_next(now())) || '%');
select test.ok('each townhall has its LAST-MODIFIED', (select admin_ics from r5hc_feed) ~ 'UID:townhall-[0-9]{8}@carmacars\.ca\r\nDTSTAMP:[0-9TZ]+\r\nLAST-MODIFIED:[0-9]{8}T[0-9]{6}Z');
select test.eq('eight townhalls', (select count(*) from regexp_matches((select admin_ics from r5hc_feed), 'UID:townhall-', 'g')), 8::bigint);
select test.ok('the townhall''s call page', (select admin_ics from r5hc_feed) like '%LOCATION:https://carmacars.ca/staff/townhall/live%');
select test.ok('the booked interview: its UID, the applicant''s first name and the role',
  (select admin_ics from r5hc_feed) like '%UID:interview-' || (select id from job_applications where email = 'cand@r5hc.example.test') || '@carmacars.ca%'
  and (select admin_ics from r5hc_feed) like '%SUMMARY:Interview call: Rhona%' and position('Fleet' in (select admin_ics from r5hc_feed)) > 0);
select test.ok('at the slot''s time', (select admin_ics from r5hc_feed) like '%DTSTART;TZID=America/Toronto:'
  || app.ics_local((select s.starts_at from interview_slots s join job_applications a on a.slot_id = s.id where a.email = 'cand@r5hc.example.test')) || '%');
select test.ok('the applicant''s full name is not in the feed', position('Hotfix' in (select admin_ics from r5hc_feed)) = 0);
select test.ok('a field staff member''s feed has the townhall', (select field_ics from r5hc_feed) like '%UID:townhall-%');
select test.ok('but no interview', position('UID:interview-' in (select field_ics from r5hc_feed)) = 0);
select test.ok('no line is longer than 75 octets',
  not exists (select 1 from regexp_split_to_table((select admin_ics from r5hc_feed), E'\r\n') l where octet_length(l) > 75));

-- a townhall cancelled ahead leaves the feed
insert into townhall_cancellations (meeting_at, reason, cancelled_by) values (app.townhall_next(now() + interval '8 days'), 'r5hc holiday', test.id('r5hc_admin'));
select test.ok('a cancelled townhall is left out',
  position('UID:townhall-' || to_char(app.townhall_next(now() + interval '8 days') at time zone 'America/Toronto', 'YYYYMMDD') || '@'
    in app.shift_feed_ics((select token from shift_feeds where user_id = test.id('r5hc_admin') and scope = 'all' and revoked_at is null))) = 0);
delete from townhall_cancellations where reason = 'r5hc holiday';

-- ================================================================ cleanup
delete from calendar_invites where application_id in (select id from job_applications where email = 'cand@r5hc.example.test');
delete from job_applications where email = 'cand@r5hc.example.test';
delete from interview_slots where day_id in (select id from interview_days where note = 'r5hc day');
delete from interview_days where note = 'r5hc day';
delete from notification_outbox where dedupe_key like 'r5hc-cap-%';
