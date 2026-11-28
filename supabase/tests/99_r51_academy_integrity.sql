-- 99: R51 academy integrity (migration 5300, REQ-130; docs/changes/2026-11-27-r51-staff.md). A submit whose page report
-- shows automation, scripted clicks, a pointer that jumps, paste or copy, the page left too often or answers too fast is
-- voided: no grade, an attempt kept with its reasons, the Admins alerted. A clean report is graded as before. Fixtures "ai51".
select test.suite('99 r51 academy integrity: the page report, voided attempts, the alert, Admin''s read');

select test.mk_user('ai51_admin', 'admin');
select test.mk_user('ai51_a', 'va', 'cs');
select test.mk_user('ai51_b', 'va', 'cs');
select test.mk_user('ai51_c', 'va', 'cs');
create function pg_temp.dr(p_user text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb language sql as
$$ select public.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;
update program_settings set academy_read_wpm = 0, academy_fail_cooldown_minutes = 2, academy_attempts_per_day = 10, academy_rapid_seconds = 0,
       academy_integrity_void = true, academy_focus_loss_max = 2, academy_answer_floor_seconds = 2 where id = (app.settings()).id;
create temp table ai51_q as select q.id, q.answer from academy_questions q join academy_sections s on s.id = q.section_id where s.slug = 'prices-and-deposits';
create function pg_temp.sub(p_integrity jsonb) returns jsonb language sql as $$
  select jsonb_build_object('section', 'prices-and-deposits', 'answers', (select jsonb_object_agg(id::text, answer) from ai51_q)) ||
         case when p_integrity is null then '{}'::jsonb else jsonb_build_object('integrity', p_integrity) end $$;
create function pg_temp.clean() returns jsonb language sql as $$
  select jsonb_build_object('webdriver', false, 'cdp', false, 'markers', '[]'::jsonb, 'untrusted', 0, 'jumps', 0, 'pastes', 0, 'copies', 0, 'leaves', 0,
    'gaps_ms', (select jsonb_agg(9000) from ai51_q)) $$;
create function pg_temp.reasons(p jsonb) returns text language sql as $$ select array_to_string(app.academy_integrity_reasons(p, 6), ',') $$;

-- ================================================================ 1. the reasons
select test.eq('a clean report: no reason', pg_temp.reasons(pg_temp.clean()), '');
select test.eq('no report (the API, a test): no reason, graded as before', pg_temp.reasons(null), '');
select test.eq('navigator.webdriver', pg_temp.reasons(pg_temp.clean() || '{"webdriver": true}'), 'automation');
select test.eq('a driver marker', pg_temp.reasons(pg_temp.clean() || '{"markers": ["__pwInitScripts"]}'), 'automation');
select test.eq('the devtools protocol probe', pg_temp.reasons(pg_temp.clean() || '{"cdp": true}'), 'automation');
select test.eq('clicks not made by a person', pg_temp.reasons(pg_temp.clean() || '{"untrusted": 3}'), 'synthetic_events');
select test.eq('one pointer jump is allowed, two are not', pg_temp.reasons(pg_temp.clean() || '{"jumps": 1}') || '|' || pg_temp.reasons(pg_temp.clean() || '{"jumps": 2}'), '|pointer_jumps');
select test.eq('paste and copy', pg_temp.reasons(pg_temp.clean() || '{"pastes": 1, "copies": 2}'), 'paste,copy');
select test.eq('two focus losses are allowed (setting), three are not', pg_temp.reasons(pg_temp.clean() || '{"leaves": 2}') || '|' || pg_temp.reasons(pg_temp.clean() || '{"leaves": 3}'), '|focus_lost');
select test.eq('half the questions (at least 3) under the 2-second floor: too fast',
  pg_temp.reasons(pg_temp.clean() || '{"gaps_ms": [500, 600, 700, 9000, 9000, 9000]}') || '|' || pg_temp.reasons(pg_temp.clean() || '{"gaps_ms": [500, 600, 9000, 9000, 9000, 9000]}'), 'too_fast|');
update program_settings set academy_answer_floor_seconds = 0 where id = (app.settings()).id;
select test.eq('a floor of 0 is off', pg_temp.reasons(pg_temp.clean() || '{"gaps_ms": [1, 1, 1, 1, 1, 1]}'), '');
update program_settings set academy_answer_floor_seconds = 2 where id = (app.settings()).id;
select test.eq('the words for the alert', app.academy_integrity_words(array['automation', 'paste']), 'browser automation detected; paste attempted');

-- ================================================================ 2. a voided submit
select pg_temp.dr('ai51_a', 'ops_do', 'academy_quiz_start', '{"section": "prices-and-deposits"}');
create temp table ai51_v as select pg_temp.dr('ai51_a', 'ops_do', 'academy_quiz_submit', pg_temp.sub(pg_temp.clean() || '{"webdriver": true, "pastes": 1}')) j;
select test.eq('voided: the answer says so and is not a pass, even with every answer right',
  (select (j ->> 'voided') || '/' || (j ->> 'passed') || '/' || (j ->> 'score_bps') from ai51_v), 'true/false/0');
select test.ok('voided: the message names the reasons', (select j ->> 'message' like 'This attempt was voided: browser automation detected; paste attempted.%' from ai51_v));
select test.eq('voided: the attempt is kept, voided, with its reasons, and not passed',
  (select voided || '/' || passed || '/' || array_to_string(void_reasons, ',') from academy_attempts where user_id = test.id('ai51_a') order by created_at desc limit 1), 'true/false/automation,paste');
select test.eq('voided: what the page saw is kept (counts only)',
  (select (integrity ->> 'webdriver') || '/' || (integrity ->> 'pastes') || '/' || (integrity ? 'gaps_ms') from academy_attempts where user_id = test.id('ai51_a') order by created_at desc limit 1), 'true/1/false');
select test.eq('voided: the section is not passed', app.academy_passed(test.id('ai51_a'), (select id from academy_sections where slug = 'prices-and-deposits')), false);
select test.eq('voided: the started quiz is ended', (select count(*) from academy_quiz_starts where user_id = test.id('ai51_a')), 0::bigint);
select test.throws('voided: the wait after a failed try follows', $$select pg_temp.dr('ai51_a', 'ops_do', 'academy_quiz_start', '{"section": "prices-and-deposits"}')$$, 'wait');
select test.eq('voided: the Admins get the alert, with the person''s academy page',
  (select (payload ->> 'alert_title' like 'Academy: % attempt voided') || '/' || (payload ->> 'path_admin') from app_events
    where payload ->> 'rule' = 'academy_integrity' and payload ->> 'kind' like 'academy_integrity:void%' order by id desc limit 1),
  'true//admin/academy/staff/' || test.id('ai51_a'));
select test.eq('a voided attempt can never be a pass (constraint)', (select count(*) from academy_attempts where voided and passed), 0::bigint);

-- ================================================================ 3. a clean submit is graded as before
select pg_temp.dr('ai51_b', 'ops_do', 'academy_quiz_start', '{"section": "prices-and-deposits"}');
select test.eq('clean: graded and passed', (pg_temp.dr('ai51_b', 'ops_do', 'academy_quiz_submit', pg_temp.sub(pg_temp.clean())) ->> 'passed')::boolean, true);
select test.eq('clean: the attempt keeps the report and no reason',
  (select voided || '/' || cardinality(void_reasons) || '/' || (integrity ->> 'fast') from academy_attempts where user_id = test.id('ai51_b') order by created_at desc limit 1), 'false/0/0');

-- ================================================================ 4. the setting off: graded, the reasons kept and alerted
update program_settings set academy_integrity_void = false where id = (app.settings()).id;
select pg_temp.dr('ai51_c', 'ops_do', 'academy_quiz_start', '{"section": "prices-and-deposits"}');
create temp table ai51_f as select pg_temp.dr('ai51_c', 'ops_do', 'academy_quiz_submit', pg_temp.sub(pg_temp.clean() || '{"untrusted": 4}')) j;
select test.eq('off: graded (passed) with the flags', (select (j ->> 'passed') || '/' || (j -> 'flags' ->> 0) from ai51_f), 'true/synthetic_events');
select test.eq('off: the attempt is flagged, not voided, with the reason',
  (select voided || '/' || flagged || '/' || array_to_string(void_reasons, ',') from academy_attempts where user_id = test.id('ai51_c') order by created_at desc limit 1), 'false/true/synthetic_events');
select test.ok('off: the Admins are alerted (flagged)', exists (select 1 from app_events where payload ->> 'rule' = 'academy_integrity' and payload ->> 'kind' like 'academy_integrity:flag%'));
update program_settings set academy_integrity_void = true where id = (app.settings()).id;

-- ================================================================ 5. Admin reads them; nobody else
select test.eq('Admin: the person''s flagged attempts, with the words',
  (select string_agg(x ->> 'words', ' | ') from jsonb_array_elements(pg_temp.dr('ai51_admin', 'admin_read', 'academy_voided', jsonb_build_object('user_id', test.id('ai51_a')))) x),
  'browser automation detected; paste attempted');
select test.throws('staff cannot read it', $$select app.academy_voided_read(test.id('ai51_b'), jsonb_build_object('user_id', test.id('ai51_a')))$$);
select test.eq('the rule is on for the Admins', (select who::text || '/' || enabled from staff_alert_rules where rule = 'academy_integrity'), '{admin}/true');
select test.eq('the browser roles cannot call the reasons', has_function_privilege('authenticated', 'app.academy_integrity_reasons(jsonb, integer)', 'execute'), false);
