-- 99: the AI interview of the remote assistant roles (migration 0380, docs/changes/2026-11-07-ai-interviews.md). The link
-- instead of the live call, the consent before recording, answers in order (voice or typed), the follow-ups (two at most),
-- the transcripts and the scores counted in the AI budget, the AI's scores checked (quotes from the answers only), the
-- Admin's reads and doors (a live call, a new link), the expiry, the removal with the application, and the privileges.
-- Fixtures start with "aiv"; example.test addresses only.
select test.suite('99 ai interviews');
-- 1060 (part K) turned on by default: Sales referral of every VA applicant, AI interviews for every role, auto-hire; this suite tests the rules before them
update program_settings set hiring_refer_va_to_sales = false, hiring_ai_all_roles = false, hiring_auto_hire_sales = false;
-- the events earlier suites left are theirs: this suite processes only its own (each staff alert fans out to every Admin
-- the earlier suites made, minutes of work that kept the CI's fast job past its time limit)
update app_events set processed_at = now() where processed_at is null;
select test.mk_user('aiv_admin', 'admin');
select test.mk_user('aiv_cs', 'va', 'cs');

create or replace function test.aiv_app(p_k text, p_role text, p_status text default 'new', p_score int default 90) returns uuid language sql as $$
  insert into job_applications (role_id, status, full_name, email, phone, score, work_mode)
  select r.id, p_status, initcap(p_k) || ' Tester', p_k || '@aiv.example.test', '+639170000' || lpad((length(p_k) * 7 % 1000)::text, 3, '0'), p_score, r.work_mode
    from hiring_roles r where r.slug = p_role
  returning id $$;
create or replace function test.aiv(p_k text) returns job_applications language sql stable as $$ select * from job_applications where email = p_k || '@aiv.example.test' $$;
create or replace function test.aiv_iv(p_k text) returns ai_interviews language sql stable as $$ select i.* from ai_interviews i join job_applications a on a.id = i.application_id where a.email = p_k || '@aiv.example.test' $$;
create or replace function test.aiv_out(p_k text, p_code text) returns bigint language plpgsql as $$
begin
  perform app.process_events();
  return (select count(*) from notification_outbox o where o.code = p_code and o.to_address = p_k || '@aiv.example.test');
end $$;
create or replace function test.aiv_tok(p_k text) returns text language sql stable as $$ select token from test.aiv(p_k) $$;
-- no interview day open for any role during this suite: the live invitation waits for a day (0211)
create temp table aiv_days as select id from interview_days where active;
update interview_days set active = false where id in (select id from aiv_days);

-- ================================================================ 1. settings and who gets the interview
select test.eq('on by default: 7 days, 4 follow-ups (2590), the Whisper model',
  (select hiring_ai_interviews::text || '/' || hiring_ai_interview_days || '/' || hiring_ai_followups || '/' || hiring_ai_transcribe_model from app.settings()),
  'true/7/4/@cf/openai/whisper-large-v3-turbo');
-- this suite walks the 0380 interview: nine questions, two follow-ups at most, the Admin deciding (2590 has them as settings)
update program_settings set hiring_ai_followups = 2, hiring_ai_harder = false, hiring_ai_auto_decide = false;

select test.aiv_app('aivcs', 'va-customer-service');
select app.hiring_screen((test.aiv('aivcs')).id);
select test.eq('a remote assistant who passes: invited, with an interview', (test.aiv('aivcs')).status || '/' || (test.aiv_iv('aivcs')).state, 'invited/sent');
select test.eq('one email: the interview link, not the booking link', test.aiv_out('aivcs', 'applicant_ai_interview') || '/' || test.aiv_out('aivcs', 'applicant_invited'), '1/0');
select app.process_events();
select test.ok('the email carries the personal link and the last day',
  (select o.payload ->> 'interview_url' like '%/careers/interview/' || test.aiv_tok('aivcs') and o.payload ->> 'expires_on' <> '' and o.payload ->> 'question_count' = '9'
     from notification_outbox o where o.code = 'applicant_ai_interview' and o.to_address = 'aivcs@aiv.example.test'));
select test.ok('the link works 7 days', (select expires_at between now() + interval '6 days 23 hours' and now() + interval '7 days 1 minute' from test.aiv_iv('aivcs')));
select test.ok('no interview day needed: not waiting for a day, not counted as waiting', not (test.aiv('aivcs')).waiting_for_day
  and not exists (select 1 from jsonb_array_elements(app.hiring_waiting_by_role()) w where w ->> 'slug' = 'va-customer-service'));

select test.aiv_app('aivfield', 'field-staff');
select app.hiring_screen((test.aiv('aivfield')).id);
select test.eq('an in-person role keeps its call: no interview, the invitation waits for a day', (select (test.aiv_iv('aivfield')).id is null)::text || '/' || (test.aiv('aivfield')).waiting_for_day, 'true/true');

update program_settings set hiring_ai_interviews = false where id = (app.settings()).id;
select test.aiv_app('aivoff', 'va-fleet-operations');
select app.hiring_screen((test.aiv('aivoff')).id);
select test.eq('turned off: a remote assistant gets the live call again', (select (test.aiv_iv('aivoff')).id is null)::text || '/' || test.aiv_out('aivoff', 'applicant_ai_interview'), 'true/0');
update program_settings set hiring_ai_interviews = true where id = (app.settings()).id;

-- Invite anyway also sends the interview to a remote assistant below the bar
select test.aiv_app('aivfin', 'va-finance-billing', 'below_bar', 40);
select app.door(test.id('aiv_admin'), 'aal2', 'admin_do', 'hiring_invite', jsonb_build_object('id', (test.aiv('aivfin')).id));
select test.eq('Invite anyway: the interview link', test.aiv_out('aivfin', 'applicant_ai_interview')::text || '/' || (test.aiv_iv('aivfin')).state, '1/sent');

-- ================================================================ 2. the questions and the consent
select test.eq('nine questions, from the role', jsonb_array_length((test.aiv_iv('aivcs')).questions), 9);
select test.ok('they cover every rubric topic (2590''s reliability and written English come with the harder questions)', (select bool_and(exists (select 1 from jsonb_array_elements((test.aiv_iv('aivcs')).questions) q where q -> 'topics' ? (t ->> 'key')))
  from jsonb_array_elements(app.ai_interview_topics()) t where t ->> 'key' not in ('reliability', 'written')));
select test.ok('the role''s own scenario, schedule and pay are asked', (test.aiv_iv('aivcs')).questions::text like '%Three chats and a call arrive together%'
  and (test.aiv_iv('aivcs')).questions::text like '%US$400 a month%' and (test.aiv_iv('aivcs')).questions::text like '%9:00 am Toronto time%');
select test.ok('the finance role asks its own', (test.aiv_iv('aivfin')).questions::text like '%bookkeeping or billing%' and (test.aiv_iv('aivfin')).questions::text like '%new bank details%');
select test.ok('never a test: not in the questions, the consent or the email', (test.aiv_iv('aivcs')).questions::text !~* '\m(test|exam)\M' and app.ai_interview_consent_text() !~* '\m(test|exam)\M'
  and (select template_text from notification_catalogue where code = 'applicant_ai_interview') is not null
  and not exists (select 1 from notification_catalogue where code = 'applicant_ai_interview' and (subject || preheader) ~* '\m(test|exam)\M'));
select test.eq('the weights make 100; moving to Canada is never scored', (select sum((t ->> 'weight')::int)::text || '/' || max(t ->> 'weight') filter (where t ->> 'key' = 'canada')
  from jsonb_array_elements(app.ai_interview_topics()) t), '100/0');

create temp table aiv_v as select 'view'::text k, public.server_ai_interview(test.aiv_tok('aivcs')) v;
grant all on aiv_v to public;
select test.eq('the page: sent, consent needed, question 1 first', (select (v ->> 'state') || '/' || (v ->> 'consent_needed') || '/' || (v #>> '{next,seq}') || '/' || (v #>> '{next,key}') from aiv_v),
  'sent/true/1/experience');
select test.eq('an unknown link', public.server_ai_interview(repeat('0', 64)) ->> 'error', 'not_found');
select test.eq('no answer before the consent', public.server_ai_interview_answer(test.aiv_tok('aivcs'), '{"seq":1,"mode":"typed","text":"Hello"}') ->> 'error', 'consent');
select test.eq('the start needs the consent', public.server_ai_interview_start(test.aiv_tok('aivcs'), '{}') ->> 'error', 'consent');
select test.eq('consent given: started', public.server_ai_interview_start(test.aiv_tok('aivcs'), '{"consent":true}') ->> 'state', 'started');
select test.ok('the consent is kept with the words shown', (select consent_at is not null and consent_text = app.ai_interview_consent_text() from test.aiv_iv('aivcs')));

-- ================================================================ 3. answers in order, voice or typed
select test.eq('an answer out of order', public.server_ai_interview_answer(test.aiv_tok('aivcs'), '{"seq":2,"mode":"typed","text":"Hello"}') ->> 'error', 'order');
select test.eq('an empty typed answer', public.server_ai_interview_answer(test.aiv_tok('aivcs'), '{"seq":1,"mode":"typed","text":"  "}') ->> 'error', 'empty');
select test.eq('typed answer 1: the next is question 2', public.server_ai_interview_answer(test.aiv_tok('aivcs'),
  '{"seq":1,"mode":"typed","text":"I worked two years as a chat support agent for a US internet provider, answering about sixty chats a day."}') #>> '{next,seq}', '2');
select test.eq('the same answer pressed twice: answered as the first', public.server_ai_interview_answer(test.aiv_tok('aivcs'), '{"seq":1,"mode":"typed","text":"again"}') ->> 'repeat', 'true');
select test.eq('a voice answer needs its own audio key', public.server_ai_interview_answer(test.aiv_tok('aivcs'), '{"seq":2,"mode":"voice","audio_key":"hiring/interviews/other/2-abc.webm"}') ->> 'error', 'invalid');
select test.eq('voice answer 2: kept, its transcript waits', (select public.server_ai_interview_answer(test.aiv_tok('aivcs'), jsonb_build_object('seq', 2, 'mode', 'voice',
  'audio_key', 'hiring/interviews/' || (test.aiv_iv('aivcs')).id || '/2-k3x9.webm', 'audio_type', 'audio/webm', 'audio_bytes', 81234, 'audio_seconds', 41.5)) #>> '{next,seq}'), '3');
select test.eq('pending', (select transcript_state from ai_interview_answers where interview_id = (test.aiv_iv('aivcs')).id and seq = 2), 'pending');
update ai_interview_answers set created_at = now() - interval '5 minutes' where interview_id = (test.aiv_iv('aivcs')).id and seq = 2;
select test.ok('the tick runs the interviews job for it', (app.server_jobs_due() ->> 'interviews')::boolean
  and exists (select 1 from jsonb_array_elements(public.server_ai_interviews_due(5) -> 'transcribe') x where x ->> 'audio_key' like '%/2-k3x9.webm'));
select public.server_ai_interview_transcript(jsonb_build_object('answer_id', (select id from ai_interview_answers where interview_id = (test.aiv_iv('aivcs')).id and seq = 2),
  'ok', false, 'reason', 'quota', 'model', '@cf/openai/whisper-large-v3-turbo', 'neurons', 0, 'called', false));
select test.eq('a quota refusal is no attempt: still pending', (select transcript_state || '/' || transcribe_attempts from ai_interview_answers where interview_id = (test.aiv_iv('aivcs')).id and seq = 2), 'pending/0');
select public.server_ai_interview_transcript(jsonb_build_object('answer_id', (select id from ai_interview_answers where interview_id = (test.aiv_iv('aivcs')).id and seq = 2),
  'ok', true, 'text', 'Yes, a customer was angry about a late refund. I said sorry, checked the account and escalated it.', 'model', '@cf/openai/whisper-large-v3-turbo', 'neurons', 33, 'duration_ms', 1800));
select test.eq('transcribed', (select transcript_state from ai_interview_answers where interview_id = (test.aiv_iv('aivcs')).id and seq = 2), 'done');
select test.ok('its neurons count in the live share of the allowance', exists (select 1 from provider_calls where purpose = 'interview_transcribe' and units = 33 and unit = 'neurons')
  and app.ai_tier('interview_transcribe') = 'live' and app.ai_tier('interview_followup') = 'live' and app.ai_tier('interview_score') = 'background'
  and app.ai_feature_label('interview_score') = 'Hiring interviews: scores and recommendation' and app.ai_feature_label('chat') = 'Visitor live chat');

-- ================================================================ 4. follow-ups: two at most, after a question, never a test
create temp table aiv_ans as select seq, id from ai_interview_answers where false;
grant all on aiv_ans to public;
select test.eq('a follow-up after answer 2: asked next, as answer 3', (public.server_ai_interview_followup(test.aiv_tok('aivcs'), jsonb_build_object('answer_id',
  (select id from ai_interview_answers where interview_id = (test.aiv_iv('aivcs')).id and seq = 2), 'text', 'What exactly did you check on the account?', 'called', true, 'ok', true, 'neurons', 12))
  -> 'next') ->> 'kind' || '/' || ((public.server_ai_interview(test.aiv_tok('aivcs')) -> 'next') ->> 'seq'), 'followup/3');
select test.ok('its neurons are counted too', exists (select 1 from provider_calls where purpose = 'interview_followup' and units = 12));
select test.eq('the follow-up answered: back to question 3', public.server_ai_interview_answer(test.aiv_tok('aivcs'), '{"seq":3,"mode":"typed","text":"The refund date and the payment method."}') #>> '{next,key}', 'social');
select test.ok('no follow-up of a follow-up', (public.server_ai_interview_followup(test.aiv_tok('aivcs'), jsonb_build_object('answer_id',
  (select id from ai_interview_answers where interview_id = (test.aiv_iv('aivcs')).id and seq = 3), 'text', 'And then?')) -> 'next') ->> 'kind' = 'question');
select public.server_ai_interview_answer(test.aiv_tok('aivcs'), '{"seq":4,"mode":"typed","text":"Some posts."}');
select test.ok('a follow-up that calls it a test is not asked', (public.server_ai_interview_followup(test.aiv_tok('aivcs'), jsonb_build_object('answer_id',
  (select id from ai_interview_answers where interview_id = (test.aiv_iv('aivcs')).id and seq = 4), 'text', 'For this test, give an example?')) -> 'next') ->> 'kind' = 'question');
select public.server_ai_interview_followup(test.aiv_tok('aivcs'), jsonb_build_object('answer_id', (select id from ai_interview_answers where interview_id = (test.aiv_iv('aivcs')).id and seq = 4),
  'text', 'Which page did you post for, and what did you post?'));
select public.server_ai_interview_answer(test.aiv_tok('aivcs'), '{"seq":5,"mode":"typed","text":"A furniture shop page: Marketplace listings and Canva posts every week."}');
select public.server_ai_interview_answer(test.aiv_tok('aivcs'), '{"seq":6,"mode":"typed","text":"Car rentals."}');
select test.eq('two follow-ups used: a third is not asked', (public.server_ai_interview_followup(test.aiv_tok('aivcs'), jsonb_build_object('answer_id',
  (select id from ai_interview_answers where interview_id = (test.aiv_iv('aivcs')).id and seq = 6), 'text', 'Tell me more?')) -> 'next') ->> 'kind' || '/' || (test.aiv_iv('aivcs')).followups_used, 'question/2');

-- ================================================================ 5. the last answer: submitted, Interviewed, waiting for an Admin
select public.server_ai_interview_answer(test.aiv_tok('aivcs'), jsonb_build_object('seq', s, 'mode', 'typed', 'text',
  case s when 7 then 'I acknowledge every chat and the call within fifteen minutes, use the templates and log each one.'
         when 8 then 'Yes, I can work six days a week from nine in the morning Toronto time, and the pay works for me.'
         when 9 then 'Fiber at 100 Mbps with a mobile backup and a power station.'
         when 10 then 'I finished a college degree in business. I am not studying and I have no other clients.'
         else 'A long-term career. Maybe Canada one day.' end)) from generate_series(7, 11) s;
select test.eq('all nine answered: submitted, the application Interviewed', (test.aiv_iv('aivcs')).state || '/' || (test.aiv('aivcs')).status, 'submitted/interviewed');
select test.eq('the page says it is done, with nothing more to ask', (select (v ->> 'state') || '/' || coalesce(v ->> 'next', 'none') from (select public.server_ai_interview(test.aiv_tok('aivcs')) v) x), 'submitted/none');
select test.eq('no answer after it', public.server_ai_interview_answer(test.aiv_tok('aivcs'), '{"seq":12,"mode":"typed","text":"More"}') ->> 'error', 'closed');
select test.ok('the scoring is due with every answer and the role', (app.server_jobs_due() ->> 'interviews')::boolean
  and (select jsonb_array_length(x -> 'answers') = 11 and x ->> 'role_slug' = 'va-customer-service' from jsonb_array_elements(public.server_ai_interviews_due(5) -> 'score') x
        where (x ->> 'interview_id')::uuid = (test.aiv_iv('aivcs')).id));

-- ================================================================ 6. the scores, checked
select public.server_ai_interview_scored(jsonb_build_object('interview_id', (test.aiv_iv('aivcs')).id, 'ok', false, 'reason', 'quota', 'called', false));
select test.ok('the allowance used: it waits an hour, no attempt counted', (select state = 'submitted' and score_attempts = 0 and next_attempt_at > now() + interval '50 minutes' from test.aiv_iv('aivcs')));
select test.eq('the AI''s scores: a quote not in the answers is dropped, the recommendation kept to the four', (public.server_ai_interview_scored(jsonb_build_object(
  'interview_id', (test.aiv_iv('aivcs')).id, 'ok', true, 'model', 'fake-interview-v1', 'neurons', 0, 'result', jsonb_build_object(
    'topics', jsonb_build_array(
      jsonb_build_object('key', 'experience', 'score', 4, 'evidence', 'I worked two years as a chat support agent'),
      jsonb_build_object('key', 'english', 'score', 5, 'evidence', 'I have ten years in a call centre'),
      jsonb_build_object('key', 'hours_pay', 'score', 5, 'evidence', 'Yes, I can work six days a week'),
      jsonb_build_object('key', 'internet', 'score', 9, 'evidence', 'Fiber at 100 Mbps')),
    'english', jsonb_build_object('level', 'good', 'score', 4, 'notes', 'Clear sentences.'),
    'red_flags', jsonb_build_array('Short answer on social media'), 'recommendation', 'hire_now', 'summary', 'Solid chat support background.')))) ->> 'recommendation', 'live_call');
select test.eq('scored', (test.aiv_iv('aivcs')).state, 'scored');
select test.eq('the quote said is kept, the invented one dropped, a score out of 1 to 5 dropped',
  (select string_agg(t ->> 'key' || ':' || coalesce(t ->> 'score', '-') || ':' || (t ->> 'evidence' is not null)::text, ',' order by t ->> 'key')
     from jsonb_array_elements((test.aiv_iv('aivcs')).result -> 'topics') t where t ->> 'key' in ('experience', 'english', 'hours_pay', 'internet')),
  'english:5:false,experience:4:true,hours_pay:5:true,internet:-:false');
select test.ok('the interview score of 100 from the weights, the English and the red flags kept', (select interview_score between 1 and 100 and result #>> '{english,level}' = 'good'
  and result -> 'red_flags' = '["Short answer on social media"]'::jsonb from test.aiv_iv('aivcs')));
select test.eq('the AI never decides: the application waits as Interviewed, no decision recorded', (test.aiv('aivcs')).status || '/' ||
  (select count(*) from hiring_decisions where application_id = (test.aiv('aivcs')).id), 'interviewed/0');

-- Sales instead is never the recommendation of a Sales role
select test.aiv_app('aivsales', 'sales-remote');
select app.hiring_screen((test.aiv('aivsales')).id);
select public.server_ai_interview_start(test.aiv_tok('aivsales'), '{"consent":true}');
select public.server_ai_interview_answer(test.aiv_tok('aivsales'), jsonb_build_object('seq', s, 'mode', 'typed', 'text', 'I sold phones in a mall for a year.')) from generate_series(1, 9) s;
select test.eq('remote sales: Sales instead becomes decline', public.server_ai_interview_scored(jsonb_build_object('interview_id', (test.aiv_iv('aivsales')).id, 'ok', true,
  'result', '{"recommendation":"sales","topics":[]}'::jsonb)) ->> 'recommendation', 'decline');

-- ================================================================ 7. Admin: the reads and the doors
select test.ok('the candidate page has the interview: answers in order, the result, the consent', (select (x #>> '{ai_interview,state}') = 'scored'
  and jsonb_array_length(x #> '{ai_interview,answers}') = 11 and (x #>> '{ai_interview,answers,1,audio_key}') like '%/2-k3x9.webm'
  and (x #>> '{ai_interview,answers,2,kind}') = 'followup' and (x #>> '{ai_interview,recommendation}') = 'live_call' and (x #>> '{ai_interview,consent_text}') is not null
  from (select app.door(test.id('aiv_admin'), 'aal2', 'admin_read', 'hiring_application', jsonb_build_object('id', (test.aiv('aivcs')).id)) x) y));
select test.ok('the list shows the state and the recommendation', exists (select 1 from jsonb_array_elements(app.door(test.id('aiv_admin'), 'aal2', 'admin_read', 'hiring', '{}') -> 'applications') x
  where x ->> 'email' = 'aivcs@aiv.example.test' and x #>> '{ai,state}' = 'scored' and x #>> '{ai,recommendation}' = 'live_call'));
select test.ok('Hiring has the setting and the interviews waiting for a decision', (select (x #>> '{ai_interviews,enabled}')::boolean and (x #>> '{ai_interviews,waiting}')::int >= 1
  from (select app.door(test.id('aiv_admin'), 'aal2', 'admin_read', 'hiring', '{}') x) y));
select test.throws('staff who are not Admins cannot read it', $$ select app.door(test.id('aiv_cs'), 'aal1', 'admin_read', 'hiring_application', jsonb_build_object('id', (test.aiv('aivcs')).id)) $$);

-- the Admin decides with the rubric, as after a call (0226)
select app.door(test.id('aiv_admin'), 'aal2', 'admin_do', 'hiring_score', jsonb_build_object('id', (test.aiv('aivsales')).id, 'decision', 'no'));
select test.eq('the rubric''s decision after the AI interview', (select outcome from hiring_decisions where application_id = (test.aiv('aivsales')).id), 'decline');

-- Invite to a live call: the booking link; it waits for a day like any invitation (0211)
select app.door(test.id('aiv_admin'), 'aal2', 'admin_do', 'hiring_ai_live_call', jsonb_build_object('id', (test.aiv('aivcs')).id));
select test.eq('a live call: invited, the booking invitation waiting for an interview day', (test.aiv('aivcs')).status || '/' || (test.aiv('aivcs')).waiting_for_day, 'invited/true');
select test.ok('the interview stays on the page', (test.aiv_iv('aivcs')).state = 'scored');
select test.throws('a live call needs an interview', $$ select app.door(test.id('aiv_admin'), 'aal2', 'admin_do', 'hiring_ai_live_call', jsonb_build_object('id', (test.aiv('aivfield')).id)) $$, '%no AI interview%');
select test.throws('a new link for a done interview is refused', $$ select app.door(test.id('aiv_admin'), 'aal2', 'admin_do', 'hiring_ai_new_link', jsonb_build_object('id', (test.aiv('aivcs')).id)) $$, '%done already%');

-- ================================================================ 8. the link expires; a new one
select app.job_hiring(now() + interval '8 days');
select test.eq('8 days on: the link has expired', (test.aiv_iv('aivfin')).state, 'expired');
select test.eq('the page says so and asks nothing', (select (v ->> 'state') || '/' || coalesce(v ->> 'next', 'none') from (select public.server_ai_interview(test.aiv_tok('aivfin')) v) x), 'expired/none');
select app.door(test.id('aiv_admin'), 'aal2', 'admin_do', 'hiring_ai_new_link', jsonb_build_object('id', (test.aiv('aivfin')).id));
select test.eq('a new link: 7 more days, a second email', (test.aiv_iv('aivfin')).state || '/' || (test.aiv_iv('aivfin')).links_sent || '/' || test.aiv_out('aivfin', 'applicant_ai_interview'), 'sent/2/2');
select app.door(test.id('aiv_admin'), 'aal2', 'admin_do', 'hiring_ai_settings', '{"enabled":false}');
select test.eq('the setting from Hiring', (select hiring_ai_interviews from app.settings())::text, 'false');
select app.door(test.id('aiv_admin'), 'aal2', 'admin_do', 'hiring_ai_settings', '{"enabled":true}');

-- ================================================================ 9. removed with the application
update job_applications set status = 'rejected', decided_at = now() - interval '13 months' where id = (test.aiv('aivcs')).id;
create temp table aiv_gone as select (test.aiv('aivcs')).id app_id, (test.aiv_iv('aivcs')).id iv_id;
grant all on aiv_gone to public;
select app.job_hiring(now());
select test.ok('12 months after the decision: no transcript, no prompt, no result', (select i.purged_at is not null and i.result is null and i.consent_text is null from ai_interviews i where i.id = (select iv_id from aiv_gone))
  and not exists (select 1 from ai_interview_answers w where w.interview_id = (select iv_id from aiv_gone) and (w.transcript is not null or w.prompt <> '')));
select test.ok('the audio file is listed for removal', exists (select 1 from jsonb_array_elements(public.server_ai_interviews_due(5) -> 'purge') x where x ->> 'audio_key' like '%/2-k3x9.webm'));
select test.ok('the job removes it and marks it', public.server_ai_audio_purged(array(select (x ->> 'answer_id')::uuid from jsonb_array_elements(public.server_ai_interviews_due(5) -> 'purge') x)) >= 1);
select test.ok('nothing left to remove', not exists (select 1 from ai_interview_answers w where w.interview_id = (select iv_id from aiv_gone) and w.audio_key is not null)
  and jsonb_array_length(public.server_ai_interviews_due(5) -> 'purge') = 0);

select test.ok('the audit log keeps the changes, never the words', not exists (select 1 from audit_log l where l.entity_table in ('ai_interviews', 'ai_interview_answers')
  and (l.after::text like '%k3x9%' or l.after::text like '%refund%' or l.before::text like '%refund%')));
-- ================================================================ 10. privileges
select test.ok('the interview functions are server only', not has_function_privilege('anon', 'public.server_ai_interview(text)', 'execute')
  and not has_function_privilege('authenticated', 'public.server_ai_interview_answer(text, jsonb)', 'execute')
  and not has_function_privilege('anon', 'public.server_ai_interview_start(text, jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'public.server_ai_interview_scored(jsonb)', 'execute')
  and has_function_privilege('service_role', 'public.server_ai_interview_answer(text, jsonb)', 'execute')
  and not has_function_privilege('anon', 'app.hiring_ai_live_call(uuid, jsonb)', 'execute'));
select test.ok('the tables are for Admins only', not has_table_privilege('anon', 'ai_interviews', 'select')
  and (select count(*) = 2 from pg_policies where tablename in ('ai_interviews', 'ai_interview_answers') and qual like '%is_admin%'));
update interview_days set active = true where id in (select id from aiv_days);
update program_settings set hiring_ai_followups = 4, hiring_ai_harder = true, hiring_ai_auto_decide = true;
