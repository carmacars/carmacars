-- 99: R50 hotfix 2 (migrations 5070, 5071 and 5074). The academy waits 2 minutes after a failed try and allows 10 tries a day; a
-- first check below the pass mark is held for one fix of the questions marked wrong (kept in the database, never replayed);
-- a salesperson who has not passed the academy gets no lead alert, cannot claim, cannot be given a lead and sees no lead
-- list, even with the onboarding gate switched off; an Admin's waiver counts as passed. Fixtures start with "lac".
select test.suite('99 r50h2 academy fix once, leads after the academy');

select test.mk_user('lac_admin', 'admin');
select test.mk_user('lac_learn', 'va', 'cs');     -- learners (exempt from the onboarding gate as every test person)
select test.mk_user('lac_learn2', 'va', 'cs');
select test.mk_user('lac_rep', 'va', 'sales');    -- an onboarded salesperson (exempt)
select test.mk_user('lac_mid', 'va', 'sales');    -- a salesperson mid-academy: not exempt, every other step done
update staff_profiles set onboarding_exempt = false, agreement_waived_at = now(), agreement_waived_by = test.id('lac_admin'), agreement_waived_reason = 'Signed on paper',
       whatsapp_joined = array['sales', 'team'], onboarding_approved_at = now(), onboarding_approved_by = test.id('lac_admin')
 where user_id = test.id('lac_mid');

create function pg_temp.dr(p_user text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb language sql as
$$ select public.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;

-- ================================================================ 1. the waits (5070)
select test.eq('waits: 1 minute after a failed try (5203, was 2) and 10 tries a day by default',
  (select string_agg(column_default, '/' order by column_name) from information_schema.columns
    where table_name = 'program_settings' and column_name in ('academy_attempts_per_day', 'academy_fail_cooldown_minutes')), '10/1');
-- (the row's values are not checked here: earlier 99_ files set their own waits, and a 99_ file never depends on another's data)

-- ================================================================ 2. fix once (5070)
update program_settings set academy_read_wpm = 0, academy_fail_cooldown_minutes = 2, academy_attempts_per_day = 10 where id = (app.settings()).id;
create temp table lac_q as select q.id, q.answer, q.sort, jsonb_array_length(q.options) n from academy_questions q join academy_sections s on s.id = q.section_id where s.slug = 'prices-and-deposits';
create function pg_temp.answers(p_right integer, p_flip_first boolean default false) returns jsonb language sql as $$
  select jsonb_build_object('section', 'prices-and-deposits', 'answers', (select jsonb_object_agg(id::text,
    case when p_flip_first and sort = 1 then (answer + 1) % n when sort <= p_right then answer else (answer + 1) % n end) from lac_q)) $$;
create function pg_temp.attempts(p_user text) returns integer language sql as $$ select count(*)::int from academy_attempts where user_id = test.id(p_user) $$;

select pg_temp.dr('lac_learn', 'ops_do', 'academy_quiz_start', '{"section": "prices-and-deposits"}');
create temp table lac_first as select pg_temp.dr('lac_learn', 'ops_do', 'academy_quiz_submit', pg_temp.answers((select count(*)::int from lac_q) - 2)) j;
select test.eq('first check below the mark: held for the fix, not passed', (select (j ->> 'fix') || '/' || (j ->> 'passed') from lac_first), 'true/false');
select test.eq('first check: the wrong questions are named', (select jsonb_array_length(j -> 'wrong') from lac_first), 2);
select test.ok('first check: no right answer and no explanation handed out', (select not (j ? 'results') and j::text !~ '"answer"' and j::text !~ '"explain"' from lac_first));
select test.eq('first check: no attempt recorded', pg_temp.attempts('lac_learn'), 0);
select test.eq('first check: the fix is kept in the database', (select cardinality(fix_wrong) from academy_quiz_starts where user_id = test.id('lac_learn')), 2);
-- starting again hands back the same fix, never a new first check
create temp table lac_again as select pg_temp.dr('lac_learn', 'ops_do', 'academy_quiz_start', '{"section": "prices-and-deposits"}') j;
select test.ok('start again: the same fix comes back (no new first check)',
  (select j -> 'fix' -> 'wrong' from lac_again) @> (select j -> 'wrong' from lac_first) and (select jsonb_array_length(j -> 'fix' -> 'wrong') from lac_again) = 2);
-- the fix: a right answer changed to wrong is ignored; only the questions marked wrong change
create temp table lac_fixed as select pg_temp.dr('lac_learn', 'ops_do', 'academy_quiz_submit', pg_temp.answers(99, true)) j;
select test.eq('the fix: only the wrong ones change, all right now: passed', (select (j ->> 'passed') || '/' || (j ->> 'fixed') || '/' || (j ->> 'score_bps') from lac_fixed), 'true/true/10000');
select test.eq('the fix: one attempt recorded', pg_temp.attempts('lac_learn'), 1);
select test.throws('the fix: cannot be sent again', $$select pg_temp.dr('lac_learn', 'ops_do', 'academy_quiz_submit', pg_temp.answers(99))$$, 'Start the quiz first');

-- a fix still wrong: the try fails, is recorded, and the 2-minute wait follows
select pg_temp.dr('lac_learn2', 'ops_do', 'academy_quiz_start', '{"section": "prices-and-deposits"}');
select pg_temp.dr('lac_learn2', 'ops_do', 'academy_quiz_submit', pg_temp.answers(1));
select test.eq('a fix still wrong: failed and recorded', (pg_temp.dr('lac_learn2', 'ops_do', 'academy_quiz_submit', pg_temp.answers(1)) ->> 'passed')::boolean, false);
select test.eq('a fix still wrong: one attempt', pg_temp.attempts('lac_learn2'), 1);
select test.throws('a fix still wrong: wait 2 minutes', $$select pg_temp.dr('lac_learn2', 'ops_do', 'academy_quiz_start', '{"section": "prices-and-deposits"}')$$, 'wait 2 minutes');
update academy_attempts set created_at = created_at - interval '3 minutes' where user_id = test.id('lac_learn2');
select pg_temp.dr('lac_learn2', 'ops_do', 'academy_quiz_start', '{"section": "prices-and-deposits"}');
select test.eq('after the wait: a passing first check is graded at once', (select (x ->> 'passed') || '/' || (x ->> 'fixed') from (
  select pg_temp.dr('lac_learn2', 'ops_do', 'academy_quiz_submit', pg_temp.answers(99)) x) z), 'true/false');

-- ================================================================ 3. leads only after the academy (5071), even with the gate off
update program_settings set staff_onboarding_gate = false where id = (app.settings()).id;
insert into chat_staff_prefs (user_id, last_seen_at) values (test.id('lac_mid'), now()), (test.id('lac_rep'), now())
  on conflict (user_id) do update set last_seen_at = excluded.last_seen_at;
insert into leads (id, kind, name, email, source) values (test.id('lead:lac1'), 'contact', 'Lac Lead', 'lead.lac1@example.test', 'web');
select test.eq('mid-academy: fully onboarded by the switch, still no leads', app.staff_fully_onboarded(test.id('lac_mid')) || '/' || app.staff_leads_ok(test.id('lac_mid')), 'true/false');
select test.ok('lead alert: the salesperson on shift gets it, the one mid-academy does not',
  exists (select 1 from app.staff_alert_users('staff_lead_new', '{}') u where u.user_id = test.id('lac_rep'))
  and not exists (select 1 from app.staff_alert_users('staff_lead_new', '{}') u where u.user_id = test.id('lac_mid')));
insert into notifications (user_id, code, title, entity, entity_id, dedupe_key) values
  (test.id('lac_mid'), 'staff_lead_new', 'New lead', 'lead', test.id('lead:lac1'), 'lac:mid'),
  (test.id('lac_rep'), 'staff_lead_new', 'New lead', 'lead', test.id('lead:lac1'), 'lac:rep');
select test.eq('lead alert: no notice is written to the one mid-academy (bell, push, email, text)',
  (select string_agg(dedupe_key, ',' order by dedupe_key) from notifications where dedupe_key like 'lac:%'), 'lac:rep');
-- only the lead rules: an owner trip (on shift for fleet, customer service and sales) still reaches the one mid-academy
select test.ok('other alerts: an on-shift rule that is not about leads still reaches the one mid-academy',
  exists (select 1 from app.staff_alert_users('owner_trip_new', '{}') u where u.user_id = test.id('lac_mid')));
select test.ok('lead codes: an exact list (leaderboard, lead_time, override_requested, owner_trip_new are not leads)',
  app.lead_notice_code('staff_lead_new') and app.lead_notice_code('visitor_signal')
  and not app.lead_notice_code('leaderboard') and not app.lead_notice_code('lead_time') and not app.lead_notice_code('override_requested')
  and not app.staff_alert_is_lead('owner_trip_new'));
insert into notifications (user_id, code, title, entity, entity_id, dedupe_key) values
  (test.id('lac_mid'), 'staff_booking_request_new', 'Top of the leaderboard', 'leaderboard', null, 'lacx:board'),
  (test.id('lac_mid'), 'staff_booking_request_new', 'Lead time', 'lead_time', null, 'lacx:time');
select test.eq('notice fence: leaderboard and lead_time notices still reach the one mid-academy',
  (select count(*)::int from notifications where dedupe_key like 'lacx:%'), 2);
select test.throws('claim: refused',$$insert into lead_claims (lead_id, claimed_by, expires_at, cap_at) values (test.id('lead:lac1'), test.id('lac_mid'), now() + interval '1 hour', now() + interval '2 hours')$$, 'has not finished onboarding');
select test.throws('Admin reassign: refused', $$select pg_temp.dr('lac_admin', 'ops_do', 'lead_reassign', jsonb_build_object('lead', test.id('lead:lac1'), 'to', test.id('lac_mid')))$$, 'has not finished onboarding');
update leads set assigned_to = test.id('lac_mid') where id = test.id('lead:lac1');
select test.eq('assignment: not given', (select assigned_to from leads where id = test.id('lead:lac1')), null::uuid);
select test.ok('assignee list: left out', not exists (select 1 from jsonb_array_elements(app.lead_assignees()) x where x ->> 'id' = test.id('lac_mid')::text));
select test.throws('lead list: nothing', $$select pg_temp.dr('lac_mid', 'va_read', 'sales_leads', '{}'::jsonb)$$, 'Leads are for');
select test.lives('lead list: the onboarded salesperson reads it', $$select pg_temp.dr('lac_rep', 'va_read', 'sales_leads', '{}'::jsonb)$$);
-- an Admin's waiver counts as passed
insert into academy_waivers (user_id, waived_by, reason) values (test.id('lac_mid'), test.id('lac_admin'), 'Passed elsewhere');
select test.eq('waived: leads open', app.staff_leads_ok(test.id('lac_mid')), true);
select test.lives('waived: the claim goes through', $$insert into lead_claims (lead_id, claimed_by, expires_at, cap_at) values (test.id('lead:lac1'), test.id('lac_mid'), now() + interval '1 hour', now() + interval '2 hours')$$);
-- the waiver taken away: the held lead goes back at once, with the reason
update academy_waivers set revoked_at = now(), revoked_by = test.id('lac_admin') where user_id = test.id('lac_mid');
select test.ok('waiver taken away: the held lead goes back at once',
  not exists (select 1 from lead_claims where lead_id = test.id('lead:lac1') and claimed_by = test.id('lac_mid'))
  and coalesce((select assigned_to from leads where id = test.id('lead:lac1')), test.id('lac_rep')) <> test.id('lac_mid'));
select test.eq('waiver taken away: the note says the academy',
  (select note from lead_claim_log where lead_id = test.id('lead:lac1') and user_id = test.id('lac_mid') and action = 'release' order by id desc limit 1),
  'Academy not passed: the lead went back');

-- ================================================================ 4. the townhall KPI slide: real staff only (5074)
select test.ok('KPI slide: no test or Verify account and nobody with no KPI',
  not exists (select 1 from jsonb_array_elements(app.townhall_staff_kpis(app.today() - 7)) x
               where app.staff_is_test((x ->> 'user_id')::uuid) or (x ->> 'tracked')::int = 0));
select test.ok('KPI slide: a real salesperson is listed', exists (select 1 from jsonb_array_elements(app.townhall_staff_kpis(app.today() - 7)) x where x ->> 'user_id' = test.id('lac_rep')::text));
update users set email = 'verify-lacrep@carmacars.ca' where id = test.id('lac_rep');   -- a Verify account
select test.ok('KPI slide: the test salesperson is left out', app.staff_is_test(test.id('lac_rep'))
  and not exists (select 1 from jsonb_array_elements(app.townhall_staff_kpis(app.today() - 7)) x where x ->> 'user_id' = test.id('lac_rep')::text));

update program_settings set staff_onboarding_gate = true, academy_read_wpm = 200 where id = (app.settings()).id;
