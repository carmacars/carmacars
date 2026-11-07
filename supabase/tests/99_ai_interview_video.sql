-- 99: the AI interview on video (migration 0585, docs/changes/2026-11-07-ai-interview-video.md): the settings (Answer time,
-- Retakes allowed, Keep interview videos), an answer with its video and its audio track, an answer the time ran out on,
-- the consent naming the video, the videos deleted after the setting's days, and the Admin's read. Fixtures start with
-- "aivv"; example.test addresses only.
select test.suite('99 ai interview video');
update app_events set processed_at = now() where processed_at is null;
select test.mk_user('aivv_admin', 'admin');
select test.mk_user('aivv_cs', 'va', 'cs');
create temp table aivv_days as select id from interview_days where active;
update interview_days set active = false where id in (select id from aivv_days);

insert into job_applications (role_id, status, full_name, email, phone, score, work_mode)
select r.id, 'new', 'Vida Example', 'vida@aivv.example.test', '+639170000555', 90, r.work_mode from hiring_roles r where r.slug = 'va-customer-service';
create or replace function test.aivv() returns job_applications language sql stable as $$ select * from job_applications where email = 'vida@aivv.example.test' $$;
create or replace function test.aivv_iv() returns ai_interviews language sql stable as $$ select i.* from ai_interviews i where i.application_id = (test.aivv()).id $$;
select app.hiring_screen((test.aivv()).id);

-- ================================================================ settings
select test.eq('by default: 2:00 to answer, no retake, videos kept 90 days',
  (select hiring_ai_answer_seconds || '/' || hiring_ai_retakes || '/' || hiring_ai_video_days from app.settings()), '120/0/90');
select test.eq('the candidate page reads them', (select (v ->> 'answer_seconds') || '/' || (v ->> 'retakes') from (select public.server_ai_interview((test.aivv()).token) v) x), '120/0');
select test.throws('only an Admin changes them', format($$select app.door(%L, 'aal2', 'admin_do', 'hiring_ai_settings', '{"answer_minutes": 3}')$$, test.id('aivv_cs')), '');
select test.throws('the answer time is 1 to 3 minutes', format($$select app.door(%L, 'aal2', 'admin_do', 'hiring_ai_settings', '{"answer_minutes": 5}')$$, test.id('aivv_admin')), 'Answer time');
select test.eq('an Admin sets 3 minutes, one retake, 30 days',
  (select (v ->> 'answer_seconds') || '/' || (v ->> 'retakes') || '/' || (v ->> 'video_days') from (select app.door(test.id('aivv_admin'), 'aal2', 'admin_do', 'hiring_ai_settings',
    '{"answer_minutes": 3, "retakes": 1, "video_days": 30}') v) x), '180/1/30');
select test.eq('Hiring shows them', (select (h #>> '{ai_interviews,answer_seconds}') || '/' || (h #>> '{ai_interviews,retakes}') || '/' || (h #>> '{ai_interviews,video_days}')
  from (select app.door(test.id('aivv_admin'), 'aal2', 'admin_read', 'hiring', '{}') h) x), '180/1/30');
select app.door(test.id('aivv_admin'), 'aal2', 'admin_do', 'hiring_ai_settings', '{"answer_minutes": 2, "retakes": 0, "video_days": 90}');

-- ================================================================ the consent names the video
select test.ok('the consent names the video and how long it is kept', app.ai_interview_consent_text() ~ 'recorded on video' and app.ai_interview_consent_text() ~ '90 days');
select public.server_ai_interview_start((test.aivv()).token, '{"consent": true}');
select test.ok('kept with the interview as shown', (select consent_text ~ 'recorded on video' from test.aivv_iv()));

-- ================================================================ answers
create temp table aivv_k as select 'hiring/interviews/' || (test.aivv_iv()).id || '/1-abc123' as base;
select test.eq('a video key of another interview is refused', public.server_ai_interview_answer((test.aivv()).token, jsonb_build_object('seq', 1, 'mode', 'voice',
  'audio_key', (select base from aivv_k) || '.webm', 'video_key', 'hiring/interviews/00000000-0000-0000-0000-000000000000/1-abc123-v.webm')) ->> 'error', 'invalid');
create temp table aivv_r as select 1 as seq, public.server_ai_interview_answer((test.aivv()).token, jsonb_build_object('seq', 1, 'mode', 'voice', 'audio_key', (select base from aivv_k) || '.webm',
  'audio_type', 'audio/webm', 'audio_bytes', 40000, 'audio_seconds', 41.5, 'video_key', (select base from aivv_k) || '-v.webm', 'video_type', 'video/webm;codecs=vp8,opus',
  'video_bytes', 5200000)) v;
select test.eq('a video answer: kept with its video and its audio track, the transcript waits',
  (select (r.v ->> 'ok') || '/' || w.mode || '/' || w.video_key || '/' || w.video_type || '/' || w.video_bytes || '/' || w.audio_key || '/' || w.transcript_state
     from aivv_r r join ai_interview_answers w on w.id = (r.v ->> 'answer_id')::uuid where r.seq = 1),
  'true/voice/' || (select base from aivv_k) || '-v.webm/video/webm;codecs=vp8,opus/5200000/' || (select base from aivv_k) || '.webm/pending');
insert into aivv_r select 2, public.server_ai_interview_answer((test.aivv()).token, '{"seq": 2, "mode": "none"}');
select test.eq('the time ran out with nothing recorded: kept as no answer',
  (select w.mode || '/' || w.transcript from aivv_r r join ai_interview_answers w on w.id = (r.v ->> 'answer_id')::uuid where r.seq = 2), 'none/No answer: the time ran out.');

-- ================================================================ the Admin's read
select test.eq('the candidate page has each answer''s video and the days it is kept',
  (select (x #>> '{ai_interview,answers,0,video_key}') || '/' || (x #>> '{ai_interview,answers,1,mode}') || '/' || (x #>> '{ai_interview,video_days}')
     from (select app.door(test.id('aivv_admin'), 'aal2', 'admin_read', 'hiring_application', jsonb_build_object('id', (test.aivv()).id)) x) y),
  (select base from aivv_k) || '-v.webm/none/90');

-- ================================================================ the videos deleted after the setting's days
select test.ok('a new video is not due', not exists (select 1 from jsonb_array_elements(public.server_ai_interviews_due(5) -> 'videos') e
  where e ->> 'video_key' = (select base from aivv_k) || '-v.webm'));
update ai_interview_answers set created_at = now() - interval '91 days' where video_key = (select base from aivv_k) || '-v.webm';
select test.ok('after 90 days it is due for deletion, and the job runs for it', app.ai_interviews_due()
  and exists (select 1 from jsonb_array_elements(public.server_ai_interviews_due(5) -> 'videos') e where e ->> 'video_key' = (select base from aivv_k) || '-v.webm'));
create temp table aivv_p as select public.server_ai_video_purged(array(select id from ai_interview_answers where video_key = (select base from aivv_k) || '-v.webm')) n;
select test.eq('deleted: the video is gone, the sound and the transcript stay',
  (select n::text from aivv_p) || '/' || (select (video_key is null)::text || '/' || (video_purged_at is not null)::text || '/' || (audio_key is not null)::text from ai_interview_answers w
    where w.interview_id = (test.aivv_iv()).id and w.seq = 1), '1/true/true/true');
select test.ok('only the service key reads the job''s list and deletes', not has_function_privilege('authenticated', 'public.server_ai_video_purged(uuid[])', 'execute'));

update interview_days set active = true where id in (select id from aivv_days);
update job_applications set status = 'withdrawn' where id = (test.aivv()).id;
