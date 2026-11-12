-- 99: Release 41 reminders (2590): the townhall reminders to every staff member and Admin (the day before, the morning of,
-- 15 minutes before; once each; never folded without a push), the townhall card's read (the day before, the warning after a
-- miss), the interview call reminders and the day's calls, a booked live call as an alert and a To-do, and the AI interview
-- that decides by itself (the bar, knock-outs, hire, live call, Sales or decline, each once). Fixtures start with "r41r";
-- every address is example.test.
select test.suite('99 r41 reminders');

select test.mk_user('r41r_admin', 'admin');
select test.mk_user('r41r_cs', 'va', 'cs');
update staff_profiles set functions = array[va_function::text] where user_id = test.id('r41r_cs');
create function test.r41at(p_local text) returns timestamptz language sql immutable as $$ select p_local::timestamp at time zone 'America/Toronto' $$;
create function test.r41ev(p_rule text, p_user text, p_step text) returns bigint language sql stable as $$
  select count(*) from app_events e where e.code like 'staff_alert_%' and e.payload ->> 'rule' = p_rule and e.entity_id = test.id(p_user) and e.dedupe_key like '%:' || p_step || ':%' $$;
update program_settings set townhall_weekday = 3, townhall_time = '13:00', hiring_auto_hire_sales = true, hiring_ai_auto_decide = true, hiring_auto_hire_mark = 80;

-- ================================================================ 1. townhall reminders (Wednesday January 15, 2031, 1:00 pm)
select test.ok('the rules are on and wired', (select bool_and(enabled and wired) from staff_alert_rules where rule in ('townhall_reminder', 'interview_reminder', 'live_call_booked')));
select test.eq('Tuesday 9:59 am: nothing yet', app.townhall_reminders(test.r41at('2031-01-14 09:59')), 0);
select app.townhall_reminders(test.r41at('2031-01-14 10:05'));
select test.eq('Tuesday 10:05 am: the day-before reminder to staff and to the Admin', test.r41ev('townhall_reminder', 'r41r_cs', 'day_before') || '/' || test.r41ev('townhall_reminder', 'r41r_admin', 'day_before'), '1/1');
select app.townhall_reminders(test.r41at('2031-01-14 15:00'));
select test.eq('never twice', test.r41ev('townhall_reminder', 'r41r_cs', 'day_before'), 1::bigint);
select test.ok('everyone''s alert keeps its push (not folded into "N or more alerts")',
  not exists (select 1 from app_events e where e.code like 'staff_alert_%' and e.payload ->> 'rule' = 'townhall_reminder' and e.payload ? '_nopush'));
select app.townhall_reminders(test.r41at('2031-01-15 09:05'));
select test.eq('Wednesday 9:05 am: the morning reminder', test.r41ev('townhall_reminder', 'r41r_cs', 'morning'), 1::bigint);
select test.eq('12:30 pm: the hour before is 1068''s alert, not a fourth reminder', app.townhall_reminders(test.r41at('2031-01-15 12:30')), 0);
insert into townhall_attendance (meeting_at, user_id, method, confirmed_at) values (test.r41at('2031-01-15 13:00'), test.id('r41r_admin'), 'checkin', now());
select app.townhall_reminders(test.r41at('2031-01-15 12:46'));
select test.eq('12:46 pm: "check in now" to whoever has not checked in', test.r41ev('townhall_reminder', 'r41r_cs', 'checkin') || '/' || test.r41ev('townhall_reminder', 'r41r_admin', 'checkin'), '1/0');
select test.ok('it carries the join path', exists (select 1 from app_events e where e.payload ->> 'rule' = 'townhall_reminder' and e.entity_id = test.id('r41r_cs')
  and e.dedupe_key like '%:checkin:%' and e.payload ->> 'alert_title' = 'Townhall: check in now'));
delete from townhall_attendance where user_id = test.id('r41r_admin') and meeting_at = test.r41at('2031-01-15 13:00');

-- the card's read: shown from the day before; the warning to whoever missed the last one (staff only)
update program_settings set townhall_weekday = extract(isodow from app.today() + 1)::int, townhall_time = '13:00';
-- the last townhall before the next one, whatever meetings the other suites left
insert into townhall_meetings (meeting_at, absent)
select greatest(now() - interval '6 days', coalesce((select max(m.meeting_at) + interval '1 second' from townhall_meetings m where m.meeting_at < app.townhall_next(now())), '-infinity')),
       array[test.id('r41r_cs')];
select test.eq('the card shows tomorrow''s townhall, with the warning for staff who missed the last one',
  (select (v ->> 'card') || '/' || (v ->> 'missed_last') || '/' || (v ->> 'checked_in') from (select app.door(test.id('r41r_cs'), 'aal2', 'ops_read', 'townhall_link', '{}') v) x), 'true/true/false');
select test.eq('an Admin sees the card, never the lock warning', (select (v ->> 'card') || '/' || (v ->> 'missed_last') from (select app.door(test.id('r41r_admin'), 'aal2', 'admin_read', 'townhall_link', '{}') v) x), 'true/false');
update program_settings set townhall_weekday = extract(isodow from app.today() + 3)::int;
select test.eq('three days ahead: no card yet', (select v ->> 'card' from (select app.door(test.id('r41r_cs'), 'aal2', 'ops_read', 'townhall_link', '{}') v) x), 'false');
delete from townhall_meetings where absent = array[test.id('r41r_cs')];
update program_settings set townhall_weekday = 3, townhall_time = '13:00';

-- ================================================================ 2. a live call booked; the interview reminders (Thursday January 16, 2031)
insert into interview_days (id, day, start_time, end_time, mode) values (test.id('r41r_day'), '2031-01-16', '11:00', '12:00', 'video');
insert into interview_slots (id, day_id, starts_at, ends_at) values (test.id('r41r_slot'), test.id('r41r_day'), test.r41at('2031-01-16 11:00'), test.r41at('2031-01-16 11:15'));
insert into job_applications (id, role_id, full_name, email, phone, status)
  values (test.id('r41r_field'), (select id from hiring_roles where slug = 'field-staff'), 'R41r Field', 'r41r_field@example.test', '+15555550142', 'invited');
select test.ok('a new applicant: an alert for information, nothing to do',
  (select bool_and(e.payload ->> 'alert_body' like '%Nothing to do%') and count(*) = 1 from app_events e where e.payload ->> 'rule' = 'application_new' and e.entity_id = test.id('r41r_field')));
update job_applications set status = 'booked', slot_id = test.id('r41r_slot'), meet_url = 'https://meet.example.test/r41r', booked_at = now() where id = test.id('r41r_field');
select test.eq('booked: one alert and one Admin To-do due at the call',
  (select count(*) from app_events e where e.payload ->> 'rule' = 'live_call_booked' and e.entity_id = test.id('r41r_field')) || '/' ||
  (select count(*) || ':' || bool_and(due_at = test.r41at('2031-01-16 11:00')) from tasks where task_type = 'interview_call' and related_id = test.id('r41r_field') and status = 'open'), '1/1:true');
select test.eq('the day''s calls with the call link', (select string_agg(full_name || '|' || link || '|' || status, ',') from app.interview_calls_of('2031-01-16')), 'R41r Field|https://meet.example.test/r41r|booked');
select test.eq('8:00 am: nothing yet', app.interview_reminders(test.r41at('2031-01-16 08:00')), 0);
select app.interview_reminders(test.r41at('2031-01-16 09:05'));
select test.eq('9:05 am: the morning of, with the day''s calls',
  (select string_agg(e.payload ->> 'alert_title' || ' / ' || (e.payload ->> 'alert_body'), ',') from app_events e where e.payload ->> 'rule' = 'interview_reminder' and e.dedupe_key like '%morning:20310116%'),
  '1 interview call today / 11:00 R41r Field (' || (select coalesce(short_title, title) from hiring_roles where slug = 'field-staff') || ')');
select app.interview_reminders(test.r41at('2031-01-16 10:05'));
select test.eq('10:05 am: an hour before the first call', (select count(*) from app_events e where e.payload ->> 'rule' = 'interview_reminder' and e.dedupe_key like '%first:20310116%'), 1::bigint);
select app.interview_reminders(test.r41at('2031-01-16 10:51'));
select app.interview_reminders(test.r41at('2031-01-16 10:56'));
select test.eq('10 minutes before: once, with the candidate and the link',
  (select string_agg(e.payload ->> 'alert_body', ',') from app_events e where e.payload ->> 'rule' = 'interview_reminder' and e.entity_id = test.id('r41r_field')),
  'Video call: https://meet.example.test/r41r');
select test.eq('Admin Today reads the day''s calls', jsonb_typeof(app.door(test.id('r41r_admin'), 'aal2', 'admin_read', 'interviews_today', '{}')), 'array');
select test.throws('staff cannot read them', $$select app.door(test.id('r41r_cs'), 'aal2', 'ops_read', 'interviews_today', '{}')$$);
update job_applications set status = 'interviewed', interviewed_at = now() where id = test.id('r41r_field');
select test.eq('the call held: the To-do is done by itself', (select string_agg(status, ',') from tasks where task_type = 'interview_call' and related_id = test.id('r41r_field')), 'done');

-- ================================================================ 3. the AI interview decides by itself
insert into job_applications (id, role_id, full_name, email, status)
select test.id('r41r_' || x.k), (select id from hiring_roles where slug = x.slug), 'R41r ' || initcap(x.k), 'r41r_' || x.k || '@example.test', 'interviewed'
  from (values ('pass', 'sales-remote'), ('ko', 'va-customer-service'), ('low', 'va-customer-service'), ('fpass', 'field-staff')) x(k, slug);
insert into ai_interviews (application_id, role_id, questions, state, expires_at, interview_score, recommendation, scored_at, result)
select a.id, a.role_id, '[]'::jsonb, 'scored', now() + interval '7 days', case a.full_name when 'R41r Low' then 60 else 88 end,
       case a.full_name when 'R41r Low' then 'sales' else 'hire' end, now(),
       case a.full_name when 'R41r Ko' then '{"knockouts": ["Has classes during the shift hours"]}'::jsonb else '{}'::jsonb end
  from job_applications a where a.id in (test.id('r41r_pass'), test.id('r41r_ko'), test.id('r41r_low'), test.id('r41r_fpass'));
select app.hiring_ai_auto_decide(now());
select test.eq('over the bar: hired (remote) or the live call (field); a knock-out declines despite the score; under the bar with a Sales fit: Sales',
  (select string_agg(a.full_name || '=' || o.outcome, ',' order by a.full_name) from hiring_ai_outcomes o join job_applications a on a.id = o.application_id where a.full_name like 'R41r %'),
  'R41r Fpass=live_call,R41r Ko=decline,R41r Low=sales,R41r Pass=hire');
select test.eq('the emails go once, by themselves', (select string_agg(a.full_name || '=' || d.email_code || ':' || (d.sent_at is not null), ',' order by a.full_name)
  from hiring_decisions d join job_applications a on a.id = d.application_id where a.full_name in ('R41r Ko', 'R41r Low')), 'R41r Ko=applicant_declined:true,R41r Low=applicant_referred:true');
select test.eq('never twice', app.hiring_ai_auto_decide(now()), 0);
select test.eq('the pass is hired by one-step Hire as Sales remote, at the bar', (select x ->> 'function' || ':' || (x ->> 'mark') from jsonb_array_elements(public.server_hire_auto_due(10) -> 'applications') x
  where (x ->> 'id')::uuid = test.id('r41r_pass')), 'sales_remote:80');
select app.hiring_field_to_call(now());
select test.eq('the field pass is invited to book its live call', (select status from job_applications where id = test.id('r41r_fpass')), 'invited');
select test.eq('the Admin is told each outcome, with the score: nothing to decide',
  (select count(*) from app_events e where e.payload ->> 'rule' = 'interview_finished' and e.entity_id in (test.id('r41r_pass'), test.id('r41r_ko'), test.id('r41r_low'), test.id('r41r_fpass'))
     and e.payload ->> 'alert_title' ~ '^AI interview (88|60) of 100: R41r ' and e.payload ->> 'alert_body' ~ '(Nothing to do|You get an alert when it is booked)'), 4::bigint);
select test.eq('Hiring: nothing waits for a decision; the bar is in the read', (select (x #>> '{ai_interviews,waiting}') || '/' || (x #>> '{ai_interviews,pass_mark}')
  from (select app.door(test.id('r41r_admin'), 'aal2', 'admin_read', 'hiring', '{}') x) y), '0/80');
select test.throws('the bar is 50 to 100', $$select app.door(test.id('r41r_admin'), 'aal2', 'admin_do', 'hiring_ai_settings', '{"pass_mark": 40}')$$, '%50 to 100%');
select app.door(test.id('r41r_admin'), 'aal2', 'admin_do', 'hiring_ai_settings', '{"pass_mark": 85, "followups": 5}');
select test.eq('the Admin tunes the bar and the follow-ups', (select hiring_auto_hire_mark || '/' || hiring_ai_followups from app.settings()), '85/5');
update program_settings set hiring_auto_hire_mark = 80, hiring_ai_followups = 4;

-- the AI's knock-outs are kept with its result
update ai_interviews set state = 'submitted', result = null, interview_score = null where application_id = test.id('r41r_ko');
select public.server_ai_interview_scored(jsonb_build_object('interview_id', (select id from ai_interviews where application_id = test.id('r41r_ko')), 'ok', true, 'called', false,
  'result', '{"recommendation": "hire", "topics": [], "knockouts": ["Refuses the pay", " "]}'::jsonb));
select test.eq('knock-outs kept, blanks dropped', (select result -> 'knockouts' from ai_interviews where application_id = test.id('r41r_ko')), '["Refuses the pay"]'::jsonb);
select test.eq('the harder interview: reliability, a typed message, and an objection for Sales',
  (select string_agg(r.slug || '=' || (select string_agg(q ->> 'key', ' ' order by o) from jsonb_array_elements(app.ai_interview_questions(r.id)) with ordinality t(q, o) where q ->> 'key' in ('objection', 'reliability', 'written')), ',' order by r.slug)
     from hiring_roles r where r.slug in ('sales-remote', 'va-customer-service')), 'sales-remote=objection reliability written,va-customer-service=reliability written');
select test.eq('the weights still make 100', (select sum((t ->> 'weight')::int) from jsonb_array_elements(app.ai_interview_topics()) t), 100::bigint);
select test.ok('the consent says the score decides and a person reviews on request', app.ai_interview_consent_text() ~ 'decides by itself' and app.ai_interview_consent_text() ~ 'recorded on video' and app.ai_interview_consent_text() ~ '90 days');

-- ================================================================ 4. grants
select test.ok('the jobs and reads are not for browsers', not has_function_privilege('authenticated', 'app.townhall_reminders(timestamptz)', 'execute')
  and not has_function_privilege('anon', 'app.hiring_ai_auto_decide(timestamptz)', 'execute') and not has_function_privilege('authenticated', 'app.interviews_today(uuid)', 'execute')
  and has_function_privilege('service_role', 'app.job_staff_reminders(timestamptz)', 'execute'));
select test.ok('the outcomes table is for Admins only', not has_table_privilege('anon', 'hiring_ai_outcomes', 'select'));

update job_applications set status = 'withdrawn' where full_name like 'R41r %';
