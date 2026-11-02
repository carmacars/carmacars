-- 99: owner leads from the application as it is filled in (migration 0344). The draft and the contact capture make an
-- owner lead in the pipeline (website form, unfinished) with the car of the draft and the calculator's estimate;
-- deduplicated by email and phone; left 30 minutes it is chased (a Sales task, the follow-ups saying "finish your
-- application" with a link that opens the draft; not also the capture's Admin task); sent, it moves to Applied and the
-- follow-ups and task stop. Fixtures start with "ouf".
select test.suite('99 owner unfinished applications');
select test.mk_user('ouf_sales', 'va', 'sales');
create temp table ouf as select null::text as k, null::jsonb as v limit 0;
create function test.ouf(p_k text) returns jsonb language sql stable as $$ select v from pg_temp.ouf where k = p_k $$;
create function test.ouf_lead(p_email text) returns leads language sql stable as $$ select * from leads where lower(email) = p_email order by created_at desc limit 1 $$;

-- a visitor starts: the draft (the first step: name, mobile, email and the car; the calculator's car and estimate)
insert into ouf select 'd1', app.save_form_draft('owner_application', jsonb_build_object('step', 0,
  'owner', jsonb_build_object('first_name', 'Nina', 'last_name', 'Field', 'email', 'ouf_nina@example.test', 'phone', '416-555-0141'),
  'vehicles', jsonb_build_array(jsonb_build_object('key', 'a', 'year', '2021', 'make', 'Toyota', 'model', 'RAV4')),
  'calc', jsonb_build_object('year', 2021, 'make', 'Toyota', 'model', 'RAV4', 'estimate_cents', 145000)), '0');
insert into ouf select 'c1', app.capture_contact(jsonb_build_object('visitor_id', gen_random_uuid(), 'form', 'owner_application', 'ref', test.ouf('d1') ->> 'draft_id',
  'draft_token', test.ouf('d1') ->> 'token', 'name', 'Nina Field', 'email', 'ouf_nina@example.test', 'phone', '416-555-0141'));
select test.eq('autosave lead: an owner lead in the pipeline, website form unfinished, with the car and the estimate, no follow-up yet',
  (select l.kind || '/' || l.pipeline_stage || '/' || l.pipeline_source || '/' || l.vehicle_text || '/' || (l.payload #>> '{calculator,estimate_cents}') || '/' || coalesce(l.followup_next_at::text, 'none')
     from leads l where l.email = 'ouf_nina@example.test'), 'owner_program/new/unfinished_form/2021 Toyota RAV4/145000/none');
-- the car changed in the draft follows onto the lead
select app.save_form_draft('owner_application', (select data from form_drafts where id = (test.ouf('d1') ->> 'draft_id')::uuid)
  || jsonb_build_object('vehicles', jsonb_build_array(jsonb_build_object('key', 'a', 'vin', '2T3P1RFV5MC000001', 'year', '2021', 'make', 'Toyota', 'model', 'RAV4 XLE'))), '1', 1, null, test.ouf('d1') ->> 'token');
select test.eq('autosave lead: the car typed later is on the lead', (test.ouf_lead('ouf_nina@example.test')).vehicle_text, '2021 Toyota RAV4 XLE');

-- dedupe: an owner lead with the same phone (written another way) is open; a second capture joins it
insert into leads (kind, name, email, phone, source) values ('owner_program', 'Omar Older', 'ouf_omar@example.test', '(647) 555-0168', 'web');
insert into ouf select 'd2', app.save_form_draft('owner_application', jsonb_build_object('step', 0, 'owner', jsonb_build_object('first_name', 'Omar')), '0');
select app.capture_contact(jsonb_build_object('visitor_id', gen_random_uuid(), 'form', 'owner_application', 'ref', test.ouf('d2') ->> 'draft_id',
  'draft_token', test.ouf('d2') ->> 'token', 'name', 'Omar Older', 'phone', '+1 647 555 0168'));
select test.eq('dedupe: one owner lead for the phone, the draft on it', (select count(*)::int || '/' || max(payload ->> 'draft_id') from leads
  where kind in ('owner_program', 'owner_recruit', 'other') and right(regexp_replace(phone, '\D', '', 'g'), 10) = '6475550168'), '1/' || (test.ouf('d2') ->> 'draft_id'));
select app.capture_contact(jsonb_build_object('visitor_id', gen_random_uuid(), 'form', 'owner_application', 'ref', test.ouf('d1') ->> 'draft_id',
  'draft_token', test.ouf('d1') ->> 'token', 'name', 'Nina Field', 'email', 'OUF_NINA@example.test'));
select test.eq('dedupe: the same email again, still one lead', (select count(*)::int from leads where lower(email) = 'ouf_nina@example.test'), 1);

-- 30 minutes: not before
select test.eq('unfinished: not chased while they are still at it', app.owner_unfinished_chase(), 0);
alter table form_drafts disable trigger form_drafts_before_write;
update form_drafts set updated_at = now() - interval '31 minutes' where id = (test.ouf('d1') ->> 'draft_id')::uuid;
alter table form_drafts enable trigger form_drafts_before_write;
update contact_captures set last_at = now() - interval '31 minutes' where lead_id = (test.ouf_lead('ouf_nina@example.test')).id;
select test.eq('unfinished: chased after 30 minutes, once', app.owner_unfinished_chase() || '/' || app.owner_unfinished_chase(), '1/0');
select test.eq('unfinished: a Sales task, the lead given to a real Sales person, the follow-ups due now',
  (select t.queue || '/' || (t.title like 'Unfinished owner application: Nina Field%') || '/' || (t.assigned_to = (test.ouf_lead('ouf_nina@example.test')).assigned_to)
     from tasks t where t.related_table = 'leads' and t.related_id = (test.ouf_lead('ouf_nina@example.test')).id and t.task_type = 'owner_unfinished_application')
  || '/' || (not app.staff_is_test((test.ouf_lead('ouf_nina@example.test')).assigned_to)) || '/' || ((test.ouf_lead('ouf_nina@example.test')).followup_next_at <= now()),
  'sales/true/true/true/true');
select test.ok('unfinished: no second chase from the capture (its task is the Sales task)', (select bool_and(task_id is not null) from contact_captures where lead_id = (test.ouf_lead('ouf_nina@example.test')).id));
select app.owner_followup_send((test.ouf_lead('ouf_nina@example.test')).id);
insert into ouf select 'mail', (select payload from notification_outbox where entity_id = (test.ouf_lead('ouf_nina@example.test')).id and code = 'owner_recruit_outreach' order by created_at desc limit 1);
select test.eq('follow-up: "finish your application", with the car', test.ouf('mail') ->> 'subject_line', 'Finish your application to list 2021 Toyota RAV4 XLE');
select test.ok('follow-up: the link opens their saved draft', (app.resume_form_draft(substring(test.ouf('mail') ->> 'message_body' from 'resume\?t=([A-Za-z0-9_-]+)')) ->> 'draft_id') = test.ouf('d1') ->> 'draft_id');
select test.ok('follow-up: the next one is planned', (test.ouf_lead('ouf_nina@example.test')).followup_next_at > now());

-- sent: Applied, the follow-ups and the task stop
select test.mk_owner('ouf_nin');
insert into owner_applications (owner_id, source, form_draft_id) values (test.id('owner:ouf_nin'), 'web', (test.ouf('d1') ->> 'draft_id')::uuid);
select test.eq('sent: the lead is Applied with the owner; no follow-up due; the task done',
  (select l.pipeline_stage || '/' || (l.owner_id = test.id('owner:ouf_nin')) || '/' || coalesce(l.followup_next_at::text, 'none') from leads l where l.id = (test.ouf_lead('ouf_nina@example.test')).id)
  || '/' || (select t.status from tasks t where t.related_table = 'leads' and t.related_id = (test.ouf_lead('ouf_nina@example.test')).id and t.task_type = 'owner_unfinished_application'),
  'applied/true/none/done');
select test.mk_user('ouf_admin', 'admin');
select test.eq('the Admin can move a lead to Applied by hand', app.owner_pipeline_do(test.id('ouf_admin'), 'owner_pipeline_save', jsonb_build_object('id', (select id from leads where email = 'ouf_omar@example.test'), 'stage', 'applied')) ->> 'stage', 'applied');
select test.ok('new functions: not callable from a browser', not has_function_privilege('authenticated', 'app.owner_unfinished_chase(timestamptz)', 'execute')
  and not has_function_privilege('anon', 'app.owner_capture_lead(uuid)', 'execute'));
