-- 99: Release 43 hiring rules (2680): instant hire is for Sales only (every other role that passes books an interview date),
-- video answers only (a typed answer is refused), each answer scored out of 10, and the Admin's "Redo the AI interview"
-- (staff access ends, the old interview stays as history, a fresh video interview link). Fixtures start with "rq43h";
-- every address is example.test.
select test.suite('99 r43 hiring rules');

select test.mk_user('rq43h_admin', 'admin');
select test.mk_user('rq43h_staff', 'va', 'cs');
update program_settings set hiring_auto_hire_sales = true, hiring_ai_auto_decide = true, hiring_auto_hire_mark = 80, hiring_ai_followups = 0;
update app_events set processed_at = now() where processed_at is null;

create function test.rq43h_app(p_k text, p_slug text, p_score int default 88) returns uuid language plpgsql as $$
declare v uuid := test.id('rq43h_' || p_k);
begin
  insert into job_applications (id, role_id, full_name, email, phone, status)
  select v, r.id, 'Rq43h ' || initcap(p_k), 'rq43h_' || p_k || '@example.test', '+15555550143', 'interviewed' from hiring_roles r where r.slug = p_slug;
  insert into ai_interviews (application_id, role_id, questions, state, expires_at, interview_score, recommendation, scored_at, result)
  select v, a.role_id, '[]'::jsonb, 'scored', now() + interval '7 days', p_score, 'hire', now(), '{}'::jsonb from job_applications a where a.id = v;
  return v;
end $$;

-- ================================================================ 1. instant hire is for Sales only
select test.rq43h_app('sales', 'sales-remote');
select test.rq43h_app('cs', 'va-customer-service');
select test.rq43h_app('fleet', 'va-fleet-operations');
select test.rq43h_app('field', 'field-staff');
select test.rq43h_app('inperson', 'sales-in-person');
select app.hiring_ai_auto_decide(now());
select test.eq('over the bar: Sales (remote or in person) is hired; every other role books an interview date',
  (select string_agg(a.email || '=' || o.outcome, ',' order by a.email) from hiring_ai_outcomes o join job_applications a on a.id = o.application_id where a.email like 'rq43h\_%@example.test'),
  'rq43h_cs@example.test=live_call,rq43h_field@example.test=live_call,rq43h_fleet@example.test=live_call,rq43h_inperson@example.test=hire,rq43h_sales@example.test=hire');
select test.eq('only Sales is listed for the one-step Hire',
  (select string_agg(a.email, ',' order by a.email) from jsonb_array_elements(public.server_hire_auto_due(50) -> 'applications') x join job_applications a on a.id = (x ->> 'id')::uuid where a.email like 'rq43h\_%@example.test'),
  'rq43h_inperson@example.test,rq43h_sales@example.test');
select test.ok('the Admin alert does not say hired for the interview date',
  (select bool_and(e.payload ->> 'alert_body' like '%interview date%') from app_events e where e.payload ->> 'rule' = 'interview_finished' and e.entity_id in (test.id('rq43h_cs'), test.id('rq43h_fleet'), test.id('rq43h_field'))));
select app.hiring_field_to_call(now());
select test.eq('a customer service pass is invited (the booking link), a Sales pass is not touched',
  (select string_agg(email || '=' || status, ',' order by email) from job_applications where email in ('rq43h_cs@example.test', 'rq43h_fleet@example.test', 'rq43h_field@example.test', 'rq43h_sales@example.test')),
  'rq43h_cs@example.test=invited,rq43h_field@example.test=invited,rq43h_fleet@example.test=invited,rq43h_sales@example.test=interviewed');
select app.process_events();
select test.eq('with the invitation email carrying the booking link', (select count(*) from notification_outbox o where o.code = 'applicant_invited' and o.to_address = 'rq43h_cs@example.test'), 1::bigint);
select test.eq('the settings flag lists Sales only', (app.k_jobs_due() ->> 'hire_auto')::boolean, true);

-- the booking slots: every role that is not Sales is on the townhall hour's day, once
select app.townhall_field_slots(now());
select test.ok('the day lists the customer service, fleet and field roles and not Sales',
  exists (select 1 from interview_days d where d.note like 'Field calls in the hour before the weekly townhall%' and d.day >= current_date
            and d.role_ids @> array[(select id from hiring_roles where slug = 'va-customer-service'), (select id from hiring_roles where slug = 'field-staff'), (select id from hiring_roles where slug = 'va-fleet-operations')]
            and not d.role_ids && array(select id from hiring_roles where slug in ('sales-remote', 'sales-in-person'))));
create temp table rq43h_days as select count(*) n from interview_days where note like 'Field calls in the hour before the weekly townhall%';
grant all on rq43h_days to public;
update interview_days set role_ids = (select array_agg(id) from hiring_roles where staff_kind = 'field') where note like 'Field calls in the hour before the weekly townhall%' and day >= current_date;
select app.townhall_field_slots(now());
select test.eq('an existing day is updated, not duplicated', (select count(*) from interview_days where note like 'Field calls in the hour before the weekly townhall%') - (select n from rq43h_days), 0::bigint);
select test.ok('and has the non-Sales roles again', exists (select 1 from interview_days d where d.note like 'Field calls in the hour before the weekly townhall%' and d.day >= current_date
  and d.role_ids @> array[(select id from hiring_roles where slug = 'va-customer-service')]));

-- ================================================================ 2. video answers only
insert into job_applications (id, role_id, full_name, email, phone, status)
select test.id('rq43h_vid'), r.id, 'Rq43h Vid', 'rq43h_vid@example.test', '+15555550144', 'invited' from hiring_roles r where r.slug = 'va-customer-service';
select app.ai_interview_send((select a from job_applications a where a.id = test.id('rq43h_vid')));
select public.server_ai_interview_start((select token from job_applications where id = test.id('rq43h_vid')), '{"consent":true}');
select test.eq('a typed answer is refused', public.server_ai_interview_answer((select token from job_applications where id = test.id('rq43h_vid')),
  '{"seq":1,"mode":"typed","text":"I would rather type."}') ->> 'error', 'video_only');
select test.eq('nothing was kept', (select count(*) from ai_interview_answers w join ai_interviews i on i.id = w.interview_id where i.application_id = test.id('rq43h_vid')), 0::bigint);
select test.eq('a video answer is kept', public.server_ai_interview_answer((select token from job_applications where id = test.id('rq43h_vid')), jsonb_build_object('seq', 1, 'mode', 'voice',
  'audio_key', 'hiring/interviews/' || (select id from ai_interviews where application_id = test.id('rq43h_vid')) || '/1-abc.webm', 'audio_type', 'audio/webm', 'audio_bytes', 4000, 'audio_seconds', 30,
  'video_key', 'hiring/interviews/' || (select id from ai_interviews where application_id = test.id('rq43h_vid')) || '/1-abc-v.webm', 'video_type', 'video/webm', 'video_bytes', 90000)) ->> 'ok', 'true');
select test.eq('an answer the time ran out on stays none', public.server_ai_interview_answer((select token from job_applications where id = test.id('rq43h_vid')),
  '{"seq":2,"mode":"none"}') ->> 'ok', 'true');
select test.eq('kept as none', (select mode from ai_interview_answers w join ai_interviews i on i.id = w.interview_id where i.application_id = test.id('rq43h_vid') and w.seq = 2), 'none');
select test.ok('the written English question is spoken', (select (app.ai_interview_questions((select id from hiring_roles where slug = 'va-customer-service')))::text not like '%type this answer%'
  and app.ai_interview_questions((select id from hiring_roles where slug = 'va-customer-service'))::text like '%Say out loud, to the camera%'));

-- ================================================================ 3. each answer scored out of 10
insert into job_applications (id, role_id, full_name, email, status) select test.id('rq43h_sc'), r.id, 'Rq43h Sc', 'rq43h_sc@example.test', 'interviewed' from hiring_roles r where r.slug = 'va-customer-service';
insert into ai_interviews (id, application_id, role_id, questions, state, expires_at, submitted_at)
select test.id('rq43h_sc_iv'), test.id('rq43h_sc'), r.id, '[]'::jsonb, 'submitted', now() + interval '7 days', now() from hiring_roles r where r.slug = 'va-customer-service';
insert into ai_interview_answers (interview_id, seq, question_key, kind, prompt, mode, transcript)
select test.id('rq43h_sc_iv'), s, 'experience', 'question', 'Q' || s, 'voice', 'I answered sixty chats a day for two years in a call centre.' from generate_series(1, 3) s;
select test.eq('scored', public.server_ai_interview_scored(jsonb_build_object('interview_id', test.id('rq43h_sc_iv'), 'ok', true, 'called', false, 'result', jsonb_build_object(
  'recommendation', 'hire', 'topics', '[]'::jsonb,
  'answers', jsonb_build_array(
    jsonb_build_object('seq', 1, 'score', 8, 'reason', 'Specific, with numbers.'),
    jsonb_build_object('seq', 1, 'score', 2, 'reason', 'a second entry for the same answer'),
    jsonb_build_object('seq', 2, 'score', 11, 'reason', 'out of range'),
    jsonb_build_object('seq', 2, 'score', 0, 'reason', 'out of range'),
    jsonb_build_object('seq', 3, 'score', 7.5, 'reason', 'not an integer'),
    jsonb_build_object('seq', 9, 'score', 5, 'reason', 'no such answer'),
    jsonb_build_object('seq', 2, 'score', 10, 'reason', repeat('x', 300)),
    jsonb_build_object('seq', 'x', 'score', 5, 'reason', 'bad seq'))))) ->> 'scored', 'true');
select test.eq('per-answer scores kept (first per seq, integer 1 to 10, an existing answer), the invalid dropped',
  (select string_agg((e ->> 'seq') || ':' || (e ->> 'score'), ',' order by (e ->> 'seq')::int) from ai_interviews i, jsonb_array_elements(i.result -> 'answers') e where i.id = test.id('rq43h_sc_iv')), '1:8,2:10');
select test.eq('a long reason is cut to 200 characters; the others keep theirs',
  (select string_agg(length(e ->> 'reason')::text, ',' order by (e ->> 'seq')::int) from ai_interviews i, jsonb_array_elements(i.result -> 'answers') e where i.id = test.id('rq43h_sc_iv')), '23,200');
select test.ok('the topics, the 0 to 100 score and the bar are still there', (select state = 'scored' and interview_score between 0 and 100 and result ? 'topics' and app.hire_auto_mark(r) = 80
  from ai_interviews i join hiring_roles r on r.id = i.role_id where i.id = test.id('rq43h_sc_iv')));
select test.ok('the Admin read carries them', (select jsonb_array_length(x #> '{ai_interview,result,answers}') = 2
  from (select app.door(test.id('rq43h_admin'), 'aal2', 'admin_read', 'hiring_application', jsonb_build_object('id', test.id('rq43h_sc'))) x) y));

-- ================================================================ 4. redo the AI interview
update users set status = 'active' where id = test.id('rq43h_staff');
insert into job_applications (id, role_id, full_name, email, phone, status, hired_user_id)
select test.id('rq43h_redo'), r.id, 'Rq43h Redo', 'rq43h_redo@example.test', '+15555550145', 'hired', test.id('rq43h_staff') from hiring_roles r where r.slug = 'va-customer-service';
insert into ai_interviews (id, application_id, role_id, questions, state, expires_at, interview_score, recommendation, scored_at, result, links_sent)
select test.id('rq43h_redo_iv'), test.id('rq43h_redo'), r.id, '[]'::jsonb, 'scored', now() + interval '7 days', 90, 'hire', now(), '{}'::jsonb, 1 from hiring_roles r where r.slug = 'va-customer-service';
insert into ai_interview_answers (interview_id, seq, question_key, kind, prompt, mode, transcript)
values (test.id('rq43h_redo_iv'), 1, 'experience', 'question', 'Old question', 'voice', 'Old transcript kept as history.');
insert into hiring_ai_outcomes (application_id, outcome, score, mark) values (test.id('rq43h_redo'), 'hire', 90, 80);
select app.process_events();
select test.throws('only an Admin', $$ select app.door(test.id('rq43h_staff'), 'aal1', 'admin_do', 'hiring_ai_redo', jsonb_build_object('id', test.id('rq43h_redo'))) $$);
select app.door(test.id('rq43h_admin'), 'aal2', 'admin_do', 'hiring_ai_redo', jsonb_build_object('id', test.id('rq43h_redo')));
select test.eq('the application is Invited again, unlinked from the staff account', (select status || '/' || (hired_user_id is null) from job_applications where id = test.id('rq43h_redo')), 'invited/true');
select test.eq('their staff access ended', (select status::text from users where id = test.id('rq43h_staff')), 'suspended');
select test.ok('the staff profile ended too', not exists (select 1 from staff_profiles where user_id = test.id('rq43h_staff') and is_active));
select test.eq('the old interview is kept as history with its answer', (select (interview ->> 'interview_score') || '/' || jsonb_array_length(answers) || '/' || (answers -> 0 ->> 'transcript')
  from ai_interview_history where application_id = test.id('rq43h_redo')), '90/1/Old transcript kept as history.');
select test.eq('a fresh interview, waiting to be taken', (select i.state || '/' || i.links_sent || '/' || (i.expires_at between now() + interval '6 days 23 hours' and now() + interval '7 days 1 minute')
  || '/' || (select count(*) from ai_interview_answers w where w.interview_id = i.id) from ai_interviews i where i.application_id = test.id('rq43h_redo')), 'sent/2/true/0');
select app.process_events();
select test.eq('the new video interview link went by email, with the explanation', (select count(*) from notification_outbox o where o.code = 'applicant_ai_interview' and o.to_address = 'rq43h_redo@example.test'
  and o.payload ->> 'redo' = '1' and o.payload ->> 'interview_url' like '%/careers/interview/%'), 1::bigint);
select test.ok('the old outcome is cleared', not exists (select 1 from hiring_ai_outcomes where application_id = test.id('rq43h_redo')));
-- the new interview, passed: customer service books an interview date, it is not hired by itself
update ai_interviews set state = 'scored', interview_score = 92, recommendation = 'hire', scored_at = now(), result = '{}'::jsonb where application_id = test.id('rq43h_redo');
update job_applications set status = 'interviewed' where id = test.id('rq43h_redo');
select app.hiring_ai_auto_decide(now());
select test.eq('the pass is the interview date, not an instant hire', (select outcome from hiring_ai_outcomes where application_id = test.id('rq43h_redo')), 'live_call');
select test.eq('it is not listed for one-step Hire', (select count(*) from jsonb_array_elements(public.server_hire_auto_due(50) -> 'applications') x where (x ->> 'id')::uuid = test.id('rq43h_redo')), 0::bigint);
select app.hiring_field_to_call(now());
select test.eq('it is invited to book', (select status from job_applications where id = test.id('rq43h_redo')), 'invited');
select app.process_events();
select test.eq('with a second invitation email, not suppressed', (select count(*) from notification_outbox o where o.code = 'applicant_invited' and o.to_address = 'rq43h_redo@example.test'), 1::bigint);
-- a hired Sales applicant redoes the interview and may be hired by itself again
insert into job_applications (id, role_id, full_name, email, phone, status)
select test.id('rq43h_sredo'), r.id, 'Rq43h Sredo', 'rq43h_sredo@example.test', '+15555550146', 'interviewed' from hiring_roles r where r.slug = 'sales-remote';
insert into ai_interviews (application_id, role_id, questions, state, expires_at, interview_score, recommendation, scored_at, result)
select test.id('rq43h_sredo'), role_id, '[]'::jsonb, 'scored', now() + interval '7 days', 90, 'hire', now(), '{}'::jsonb from job_applications where id = test.id('rq43h_sredo');
select app.door(test.id('rq43h_admin'), 'aal2', 'admin_do', 'hiring_ai_redo', jsonb_build_object('id', test.id('rq43h_sredo')));
update ai_interviews set state = 'scored', interview_score = 91, recommendation = 'hire', scored_at = now(), result = '{}'::jsonb where application_id = test.id('rq43h_sredo');
update job_applications set status = 'interviewed' where id = test.id('rq43h_sredo');
select app.hiring_ai_auto_decide(now());
select test.eq('Sales: the redone pass is an instant hire', (select outcome from hiring_ai_outcomes where application_id = test.id('rq43h_sredo')), 'hire');

-- ================================================================ 5. privileges
select test.ok('the server can run the new functions; the public cannot', has_function_privilege('service_role', 'app.hiring_ai_redo(uuid, jsonb)', 'execute')
  and not has_function_privilege('anon', 'app.hiring_ai_redo(uuid, jsonb)', 'execute') and not has_function_privilege('authenticated', 'app.hiring_ai_redo(uuid, jsonb)', 'execute')
  and has_function_privilege('service_role', 'public.server_ai_interview_scored(jsonb)', 'execute') and not has_function_privilege('anon', 'public.server_ai_interviews_due(integer)', 'execute'));
select test.ok('the history is for Admins only, with its audit trigger', not has_table_privilege('anon', 'ai_interview_history', 'select') and not has_table_privilege('authenticated', 'ai_interview_history', 'insert')
  and exists (select 1 from pg_policies where tablename = 'ai_interview_history' and qual like '%is_admin%')
  and exists (select 1 from pg_trigger where tgrelid = 'ai_interview_history'::regclass and tgname = 'audit_ai_interview_history'));
update program_settings set hiring_ai_followups = 4;
