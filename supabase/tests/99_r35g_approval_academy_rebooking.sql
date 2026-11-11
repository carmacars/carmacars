-- 99: release 35 part G (migration 1154). Onboarding step 4 (approved by an Admin or a Fleet VA), the academy's safeguards
-- (90% pass mark, reading time, random order, cooldown, tries a day, too-fast flag, an Admin's reset) and the rebooking claim
-- (a returning renter's lead goes to the salesperson of their last booking). Fixtures start with "gap".
select test.suite('99 r35g approval, academy, rebooking');

select test.mk_user('gap_admin', 'admin');
select test.mk_user('gap_fleet', 'va', 'fleet');     -- onboarded (exempt as every test person)
select test.mk_user('gap_rep', 'va', 'sales');       -- onboarded salesperson
select test.mk_user('gap_hire', 'va', 'sales');      -- the new hire
select test.mk_user('gap_cs', 'va', 'cs');           -- a learner
select test.mk_user('gap_verify', 'va', 'sales');
update staff_profiles set onboarding_exempt = false where user_id in (test.id('gap_hire'), test.id('gap_verify'));
update users set email = 'verify-gap@carmacars.ca' where id = test.id('gap_verify');

create function pg_temp.dr(p_user text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb language sql as
$$ select public.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;
create function pg_temp.st(p_user text) returns text language sql as $$ select app.staff_onboarding_state(test.id(p_user)) ->> 'step' $$;
create function pg_temp.task_status(p_user text) returns text language sql as
$$ select string_agg(status, ',' order by created_at) from tasks where task_type = 'approve_onboarding' and related_id = test.id(p_user) $$;

-- ================================================================ A. step 4: approved
insert into academy_waivers (user_id, waived_by, reason) values (test.id('gap_hire'), test.id('gap_admin'), 'Passed elsewhere');
update staff_profiles set agreement_waived_at = now(), agreement_waived_by = test.id('gap_admin'), agreement_waived_reason = 'Signed on paper' where user_id = test.id('gap_hire');
select test.eq('approval: not asked before the WhatsApp groups', pg_temp.task_status('gap_hire'), null);
select pg_temp.dr('gap_hire', 'ops_do', 'staff_whatsapp_confirm', '{"sales": true, "team": true}');
select test.eq('approval: WhatsApp confirmed: waiting for approval', pg_temp.st('gap_hire'), 'approval');
select test.eq('approval: not fully onboarded yet', app.staff_fully_onboarded(test.id('gap_hire')), false);
select test.eq('approval: one open Fleet To do', (select queue || ':' || status || ':' || title from tasks where task_type = 'approve_onboarding' and related_id = test.id('gap_hire')), 'fleet:open:Approve Gap Hire''s onboarding');
select test.eq('approval: Welcome shows the step, open and not done',
  (select (s ->> 'open') || '/' || (s ->> 'done') from jsonb_array_elements(pg_temp.dr('gap_hire', 'ops_read', 'staff_welcome') -> 'steps') s where s ->> 'key' = 'approval'), 'true/false');
select test.ok('approval: the Fleet VA sees the person waiting',
  exists (select 1 from jsonb_array_elements(pg_temp.dr('gap_fleet', 'va_read', 'staff_onboarding_approvals')) x where x ->> 'user_id' = test.id('gap_hire')::text));
select test.throws('approval: never by the person', $$select pg_temp.dr('gap_hire', 'ops_do', 'staff_onboarding_approve', jsonb_build_object('user', test.id('gap_hire')))$$);
select test.throws('approval: not by Sales', $$select pg_temp.dr('gap_rep', 'ops_do', 'staff_onboarding_approve', jsonb_build_object('user', test.id('gap_hire')))$$, 'Admins and Fleet only');
select test.throws('reject: needs the reason', $$select pg_temp.dr('gap_fleet', 'va_do', 'staff_onboarding_reject', jsonb_build_object('user', test.id('gap_hire'), 'reason', ''))$$, 'reason');
select pg_temp.dr('gap_fleet', 'va_do', 'staff_onboarding_reject', jsonb_build_object('user', test.id('gap_hire'), 'reason', 'Join the Sales group with your work number'));
select test.eq('reject: still held', app.staff_fully_onboarded(test.id('gap_hire')), false);
select test.eq('reject: the To do is cancelled', pg_temp.task_status('gap_hire'), 'cancelled');
select test.eq('reject: Welcome shows the reason',
  (select s ->> 'reject_reason' from jsonb_array_elements(pg_temp.dr('gap_hire', 'ops_read', 'staff_welcome') -> 'steps') s where s ->> 'key' = 'approval'), 'Join the Sales group with your work number');
select test.eq('ask again: asked', (pg_temp.dr('gap_hire', 'ops_do', 'staff_onboarding_ask_again') ->> 'asked')::boolean, true);
select test.eq('ask again: a new open To do', pg_temp.task_status('gap_hire'), 'cancelled,open');
select pg_temp.dr('gap_fleet', 'va_do', 'staff_onboarding_approve', jsonb_build_object('user', test.id('gap_hire')));
select test.eq('approved by a Fleet VA: fully onboarded', app.staff_fully_onboarded(test.id('gap_hire')), true);
select test.eq('approved: the step is done', pg_temp.st('gap_hire'), 'done');
select test.eq('approved: the To do is done', pg_temp.task_status('gap_hire'), 'cancelled,done');
select test.eq('approved: logged', (select count(*)::int from audit_log where action = 'staff_onboarding_approved' and entity_id = test.id('gap_hire')::text and actor_user_id = test.id('gap_fleet')), 1);
select test.throws('approved: not twice', $$select pg_temp.dr('gap_admin', 'admin_do', 'staff_onboarding_approve', jsonb_build_object('user', test.id('gap_hire')))$$, 'not waiting for approval');
-- the WhatsApp confirmation taken back takes the approval with it
select pg_temp.dr('gap_admin', 'ops_do', 'staff_whatsapp_mark', jsonb_build_object('user', test.id('gap_hire'), 'joined', false));
select test.ok('take back: the approval goes too', (select onboarding_approved_at from staff_profiles where user_id = test.id('gap_hire')) is null);
select pg_temp.dr('gap_admin', 'ops_do', 'staff_whatsapp_mark', jsonb_build_object('user', test.id('gap_hire'), 'joined', true));
select test.eq('marked again: waiting for approval again', pg_temp.st('gap_hire'), 'approval');
select test.eq('Admin approves everyone waiting', (pg_temp.dr('gap_admin', 'admin_do', 'staff_onboarding_approve_all') ->> 'approved')::int >= 1, true);
select test.eq('approve all: onboarded', app.staff_fully_onboarded(test.id('gap_hire')), true);
select test.throws('approve all: an Admin''s action', $$select pg_temp.dr('gap_fleet', 'va_do', 'staff_onboarding_approve_all')$$, 'Admin');
select test.eq('verify accounts stay exempt', app.staff_fully_onboarded(test.id('gap_verify')), true);
select test.ok('verify accounts are never listed', not exists (select 1 from jsonb_array_elements(pg_temp.dr('gap_admin', 'admin_read', 'staff_onboarding_approvals')) x where x ->> 'user_id' = test.id('gap_verify')::text));

-- ================================================================ B. the academy's safeguards
-- the defaults (an earlier suite may have changed them)
update program_settings set academy_pass_bps = 9000, academy_read_wpm = 200, academy_fail_cooldown_minutes = 30, academy_attempts_per_day = 3, academy_rapid_seconds = 3 where id = (app.settings()).id;
select test.eq('academy: the pass mark is 90% by default', (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'academy_pass_bps'), '9000');
select test.eq('academy: 30 minutes after a failed try, 3 tries a day, flagged under 3 s a question',
  (select academy_fail_cooldown_minutes || '/' || academy_attempts_per_day || '/' || academy_rapid_seconds from program_settings where id = (app.settings()).id), '30/3/3');
create temp table gap_q as select q.id, q.answer, q.sort, jsonb_array_length(q.options) n, q.options from academy_questions q join academy_sections s on s.id = q.section_id where s.slug = 'prices-and-deposits';
create function pg_temp.start() returns jsonb language sql as $$ select pg_temp.dr('gap_cs', 'ops_do', 'academy_quiz_start', '{"section": "prices-and-deposits"}') $$;
create function pg_temp.submit(p_right boolean) returns jsonb language sql as $$
  select pg_temp.dr('gap_cs', 'ops_do', 'academy_quiz_submit', jsonb_build_object('section', 'prices-and-deposits',
    'answers', (select jsonb_object_agg(id::text, case when p_right then answer else (answer + 1) % n end) from gap_q))) $$;
select test.ok('reading: the section has a reading time', app.academy_read_seconds((select id from academy_sections where slug = 'prices-and-deposits')) > 0);
select test.ok('reading: no questions in the section read', jsonb_array_length(pg_temp.dr('gap_cs', 'ops_read', 'academy_section', '{"path": "cs", "section": "prices-and-deposits"}') -> 'questions') = 0);
select test.throws('reading: the quiz waits until the section is opened and read', $$select pg_temp.start()$$, 'Read the section first');
select pg_temp.dr('gap_cs', 'ops_do', 'academy_opened', '{"section": "prices-and-deposits"}');
select test.throws('reading: still reading right after opening', $$select pg_temp.start()$$, 'Read the section first');
update academy_section_opens set opened_at = now() - interval '2 hours' where user_id = test.id('gap_cs');
create temp table gap_quiz as select pg_temp.start() j;
select test.eq('start: every question once', (select count(distinct x ->> 'id')::int from gap_quiz, jsonb_array_elements(j -> 'questions') x), (select count(*)::int from gap_q));
select test.ok('start: no answers handed out', not exists (select 1 from gap_quiz, jsonb_array_elements(j -> 'questions') x where x ? 'answer' or x ? 'explain'));
select test.ok('start: each shown option maps back to its question''s option by its key', not exists (
  select 1 from gap_quiz, jsonb_array_elements(j -> 'questions') x join gap_q q on q.id::text = x ->> 'id',
         generate_series(0, jsonb_array_length(x -> 'options') - 1) i
   where q.options -> ((x -> 'keys' ->> i)::int) <> x -> 'options' -> i));
select test.ok('start: the order is random (20 handouts are not all the same)', (
  select count(distinct o) > 1 from (select (select string_agg(x ->> 'id', ',') from jsonb_array_elements(app.academy_quiz_start(test.id('gap_cs'), jsonb_build_object('section', 'prices-and-deposits', 'n', g)) -> 'questions') x) o
                                       from generate_series(1, 20) g) z));
create temp table gap_fail as select pg_temp.submit(false) j;
select test.eq('fail: not passed', (select (j ->> 'passed')::boolean from gap_fail), false);
select test.ok('fail: the right answers are not shown', not exists (select 1 from gap_fail, jsonb_array_elements(j -> 'results') r where r -> 'answer' <> 'null'::jsonb or coalesce(r ->> 'explain', '') <> ''));
select test.eq('fail: answered in no time: flagged', (select flagged from academy_attempts where user_id = test.id('gap_cs') order by created_at desc limit 1), true);
select test.throws('cooldown: 30 minutes after a failed try', $$select pg_temp.start()$$, 'wait 30 minutes');
update program_settings set academy_fail_cooldown_minutes = 0 where id = (app.settings()).id;
select pg_temp.start(); select pg_temp.submit(false);
select pg_temp.start(); select pg_temp.submit(false);
select test.throws('daily: the 4th try today is refused', $$select pg_temp.start()$$, 'tries of this quiz today');
select test.throws('submit: without a started quiz', $$select pg_temp.submit(true)$$, 'Start the quiz first');
select test.eq('daily: three attempts on record', (select count(*)::int from academy_attempts where user_id = test.id('gap_cs')), 3);
-- the Admin's reset: the section starts over (reading clock too); the attempts stay on record
select test.throws('reset: an Admin''s action', $$select pg_temp.dr('gap_fleet', 'admin_do', 'academy_reset', jsonb_build_object('user_id', test.id('gap_cs'), 'sections', jsonb_build_array((select id from academy_sections where slug = 'prices-and-deposits'))))$$);
select test.throws('reset: the sections are chosen', $$select pg_temp.dr('gap_admin', 'admin_do', 'academy_reset', jsonb_build_object('user_id', test.id('gap_cs')))$$, 'Choose the sections');
-- the page's ticks: s_<section id>
select pg_temp.dr('gap_admin', 'admin_do', 'academy_reset', jsonb_build_object('user_id', test.id('gap_cs'), 's_' || (select id from academy_sections where slug = 'prices-and-deposits'), true,
  's_' || (select id from academy_sections where slug = 'coverage-and-drivers'), false));
select test.eq('reset: logged, the ticked section only', (select count(*)::int from audit_log where entity_table = 'academy_resets'), 1);
select test.eq('reset: the attempts stay on record', (select count(*)::int from academy_attempts where user_id = test.id('gap_cs')), 3);
select test.throws('reset: the reading time starts again', $$select pg_temp.start()$$, 'Read the section first');
select pg_temp.dr('gap_cs', 'ops_do', 'academy_opened', '{"section": "prices-and-deposits"}');
update academy_section_opens set opened_at = now() - interval '2 hours' where user_id = test.id('gap_cs');
select pg_temp.start();
update academy_quiz_starts set started_at = now() - interval '5 minutes' where user_id = test.id('gap_cs');
select test.eq('reset: tries again today, and a pass', (pg_temp.submit(true) ->> 'passed')::boolean, true);
select test.eq('pass: answered at a normal pace: not flagged', (select flagged from academy_attempts where user_id = test.id('gap_cs') order by created_at desc limit 1), false);
select test.eq('pass: the section is passed', app.academy_passed(test.id('gap_cs'), (select id from academy_sections where slug = 'prices-and-deposits')), true);
update program_settings set academy_fail_cooldown_minutes = 30 where id = (app.settings()).id;

-- ================================================================ C. rebooking: the last booking's salesperson claims the lead
select test.mk_owner('gap_owner');
select test.mk_vehicle('gap_car', 'gap_owner');
select test.mk_renter('gap_back');
update renters set mobile = '647-555-0731' where id = test.id('renter:gap_back');  -- a phone of its own (the fixtures share one)
select test.mk_booking('GAP-1', 'gap_car', 'gap_back', '2026-09-10 10:00', '2026-09-13 10:00', 'closed');
update bookings set sales_staff_id = test.id('gap_rep'), sales_source = 'manual_rental', sales_attributed_at = now() where id = test.id('booking:GAP-1');
insert into leads (id, kind, name, email, source) values (test.id('lead:gap1'), 'contact', 'Gap Back', 'GAP_BACK@example.test', 'web');
select test.eq('rebooking: claimed for the salesperson of the last booking', (select claimed_by from lead_claims where lead_id = test.id('lead:gap1')), test.id('gap_rep'));
select test.eq('rebooking: with the normal claim window', (select (expires_at - claimed_at) = make_interval(mins => app.sl_window('renter')) from lead_claims where lead_id = test.id('lead:gap1')), true);
select test.eq('rebooking: logged as a claim', (select note from lead_claim_log where lead_id = test.id('lead:gap1') and action = 'claim'), 'Rebooking: credited on their last booking');
-- by phone too
insert into leads (id, kind, name, phone, source) values (test.id('lead:gap2'), 'contact', 'Gap Back', '(647) 555-0731', 'web');
select test.eq('rebooking: matched by phone', (select claimed_by from lead_claims where lead_id = test.id('lead:gap2')), test.id('gap_rep'));
-- a new person: the pool
insert into leads (id, kind, name, email, source) values (test.id('lead:gap3'), 'contact', 'New Person', 'gap.new@example.test', 'web');
select test.ok('rebooking: a new person goes to the pool', not exists (select 1 from lead_claims where lead_id = test.id('lead:gap3')));
-- the salesperson not fully onboarded: the pool
update staff_profiles set onboarding_exempt = false where user_id = test.id('gap_rep');
insert into leads (id, kind, name, email, source) values (test.id('lead:gap4'), 'contact', 'Gap Back', 'gap_back@example.test', 'web');
select test.ok('rebooking: not to a salesperson not onboarded', not exists (select 1 from lead_claims where lead_id = test.id('lead:gap4')));
update staff_profiles set onboarding_exempt = true where user_id = test.id('gap_rep');
-- an owner lead is not a rebooking
insert into leads (id, kind, name, email, source) values (test.id('lead:gap5'), 'owner_program', 'Gap Back', 'gap_back@example.test', 'web');
select test.ok('rebooking: renter leads only', not exists (select 1 from lead_claims where lead_id = test.id('lead:gap5')));
