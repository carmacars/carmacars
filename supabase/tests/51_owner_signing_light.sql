-- 51: owner signing without rendering on the page (documents found by content key), signed copies as background jobs,
-- and the first and last month invoice only by an Admin's choice (0075). Fixtures start with "sl".
select test.suite('51 owner signing light, first and last month choice');
grant usage on schema test to service_role;
create table test.sl (k text primary key, v jsonb);
create function test.slv(p text) returns jsonb language sql stable as $$ select v from test.sl where k = p $$;
create function test.sl_do(p_user text, p_name text, p jsonb) returns jsonb language sql as $$ select public.door(test.id(p_user), null, 'ops_do', p_name, p) $$;

select test.mk_user('sl_admin', 'admin');
select test.mk_user('sl_cs', 'va', 'cs');
update program_settings set trackers_available = false;

-- an owner (a corporation) who applied themselves, with one car; approved with terms and no first and last choice
insert into users (id, email, full_name) values (test.id('sl_sam'), 'sam.sl@example.test', 'Sam Signer');
insert into test.sl select 'app', public.server_submit_owner_application(jsonb_build_object('source', 'web',
  'owner', jsonb_build_object('owner_type', 'corporation', 'legal_name', 'Sample Holdings Ltd.', 'corporation_name', 'Sample Holdings Ltd.', 'first_name', 'Sam',
                              'signing_officer_name', 'Sam Signer', 'signing_officer_title', 'President', 'email', 'sam.sl@example.test',
                              'phone', '+16475550188', 'address_line1', '2 Bay Street', 'city', 'Toronto', 'province', 'ON', 'postal_code', 'M5J 2R8',
                              'licence_number', 'S1234-56789-01234', 'date_of_birth', '1980-03-03'),
  'vehicles', jsonb_build_array(jsonb_build_object('vin', upper(substr(md5('sl-vin-1'), 1, 17)), 'plate', 'SLAA101', 'year', 2022, 'make', 'Chevrolet', 'model', 'Malibu', 'colour', 'Grey',
    'odometer_km', 40000, 'title_status', 'owned_outright', 'management_mode', 'managed', 'onboarding_method', 'transfer', 'current_insurer', 'Aviva', 'title_brand_clear', true))),
  test.id('sl_sam'));
create function test.sl_owner() returns uuid language sql stable as $$ select (test.slv('app') ->> 'owner_id')::uuid $$;
create function test.sl_car() returns uuid language sql stable as $$ select (test.slv('app') #>> '{vehicles,0,vehicle_id}')::uuid $$;
update owners set user_id = test.id('sl_sam') where id = test.sl_owner() and user_id is null;

-- ================================================================ 1. approve without a choice: nothing invoiced, a to-do
insert into test.sl select 'approve', test.sl_do('sl_admin', 'application_approve', jsonb_build_object('id', test.slv('app') ->> 'application_id', 'cars', jsonb_build_array(
  jsonb_build_object('vehicle_id', test.sl_car(), 'terms', jsonb_build_object('insurance_fee_cents', 40000), 'invoices', '[]'::jsonb))));
select test.eq('approve without a first and last choice: no invoice, and Admin > Today asks for it',
  (select count(*) from owner_invoices where vehicle_id = test.sl_car()) || '/'
  || (select count(*) from tasks where task_type = 'first_last_decide' and vehicle_id = test.sl_car() and status = 'open' and queue = 'admin'
        and title = 'Decide the first and last month invoice for ' || app.vehicle_name(test.sl_car())), '0/1');
select test.eq('the bulk path (owner page Issue) makes nothing without a choice', jsonb_array_length(public.admin_issue_upfront_invoices(test.sl_owner(), test.id('sl_admin'))), 0);
select test.eq('Admin > Today lists the decision with a link to the owner''s Terms tab',
  (select (i ->> 'count')::int > 0 and (i ->> 'href') like '/admin/owners/%?tab=terms' from jsonb_array_elements(app.admin_todo(test.id('sl_admin')) -> 'items') i where i ->> 'key' = 'first_last_decide'), true);
select test.eq('the to-do is raised once', (select count(*) from tasks where task_type = 'first_last_decide' and vehicle_id = test.sl_car()), 1::bigint);

-- ================================================================ 2. documents found by content key, no render on the page
select test.eq('content: nothing open for an unknown key', jsonb_array_length(public.server_open_by_content(test.id('sl_sam'), array[repeat('1', 64)])), 0);
select public.owner_open_agreements(test.sl_owner(), test.id('sl_sam'), jsonb_build_array(
  jsonb_build_object('key', 'enrollment', 'template_version', 'enrollment-test', 'sha256', repeat('a', 64), 'storage_path', 'owners/sl/enrollment-aaaa.pdf')));
select public.owner_open_agreements(test.sl_owner(), test.id('sl_sam'), jsonb_build_array(
  jsonb_build_object('key', 'title_holding', 'template_version', 'title-test', 'sha256', repeat('b', 64), 'storage_path', 'owners/sl/title_holding-bbbb.pdf')));
select test.eq('content: documents opened one per request each get their own request',
  (select count(distinct signature_request_id) from owner_agreements where owner_id = test.sl_owner() and kind in ('enrollment', 'title_holding') and status = 'sent'), 2::bigint);
select test.eq('content: the key is recorded on the document by its file',
  public.server_document_content_key(test.id('sl_sam'), 'owners/sl/enrollment-aaaa.pdf', repeat('c', 64))
  + public.server_document_content_key(test.id('sl_sam'), 'owners/sl/title_holding-bbbb.pdf', repeat('d', 64)), 2);
select test.eq('content: the page finds each open request by its key, with the SHA-256 recorded at opening',
  (select string_agg((x ->> 'sha256') || '=' || ((x ->> 'signature_request_id')::uuid = (select a.signature_request_id from owner_agreements a where a.owner_id = test.sl_owner()
     and a.kind = case when x ->> 'content_key' = repeat('c', 64) then 'enrollment' else 'title_holding' end))::text, ',' order by x ->> 'content_key')
     from jsonb_array_elements(public.server_open_by_content(test.id('sl_sam'), array[repeat('c', 64), repeat('d', 64)])) x),
  repeat('a', 64) || '=true,' || repeat('b', 64) || '=true');
select test.mk_user('sl_other', 'renter');
select test.eq('content: another user finds nothing', jsonb_array_length(public.server_open_by_content(test.id('sl_other'), array[repeat('c', 64)])), 0);
select test.eq('content: another user cannot set a key', public.server_document_content_key(test.id('sl_other'), 'owners/sl/enrollment-aaaa.pdf', repeat('e', 64)), 0);
select test.eq('content: opening the same content again keeps the same request (idempotent)',
  (public.owner_open_agreements(test.sl_owner(), test.id('sl_sam'), jsonb_build_array(
     jsonb_build_object('key', 'enrollment', 'template_version', 'enrollment-test', 'sha256', repeat('a', 64), 'storage_path', 'owners/sl/enrollment-aaaa.pdf'))) #>> '{requests,0,signature_request_id}')::uuid
  = (select signature_request_id from owner_agreements where owner_id = test.sl_owner() and kind = 'enrollment'), true);
select test.throws('content: the key must be a SHA-256', $$select public.server_document_content_key(test.id('sl_sam'), 'x', 'nope')$$, 'SHA-256');

-- ================================================================ 3. signing: the legal act first, no invoice
insert into test.sl select 'signed', public.owner_sign_agreements(test.sl_owner(), test.id('sl_sam'), jsonb_build_object('typed_name', 'Sam Signer', 'consent_text', 'I sign.',
  'initials', '{"own_insurance":"SS","fees_no_income":"SS","tracker_downtime":"SS"}'::jsonb,
  'documents', jsonb_build_array(jsonb_build_object('key', 'enrollment', 'sha256', repeat('a', 64)), jsonb_build_object('key', 'title_holding', 'sha256', repeat('b', 64)))));
select test.eq('signing: both documents signed by the corporation''s officer and countersigned, against the SHA-256 opened',
  (select count(*) from signature_records r join owner_agreements a on a.signature_request_id = r.signature_request_id
    where a.owner_id = test.sl_owner() and r.document_sha256 in (repeat('a', 64), repeat('b', 64))) || '/'
  || (select string_agg(distinct signer_role, ',' order by signer_role) from signature_records r join owner_agreements a on a.signature_request_id = r.signature_request_id where a.owner_id = test.sl_owner()),
  '4/carmacars,owner_corporation');
select test.eq('signing creates no invoice and leaves the to-do open; the car waits at documents signed',
  (select count(*) from owner_invoices where vehicle_id = test.sl_car()) || '/'
  || (select count(*) from tasks where task_type = 'first_last_decide' and vehicle_id = test.sl_car() and status = 'open') || '/'
  || (select status from vehicle_onboardings where vehicle_id = test.sl_car()), '0/1/documents_signed');

-- ================================================================ 4. signed copies as jobs; the "Signed" email waits for them
select public.server_pdf_jobs_enqueue((select jsonb_agg(jsonb_build_object('kind', 'owner_signed_copy', 'ref', x ->> 'signature_request_id', 'owner_id', test.sl_owner(),
  'user_id', test.id('sl_sam'), 'payload', jsonb_build_object('doc', x))) from jsonb_array_elements(test.slv('signed') -> 'signed') x));
select public.server_pdf_jobs_enqueue((select jsonb_agg(jsonb_build_object('kind', 'owner_signed_copy', 'ref', x ->> 'signature_request_id', 'owner_id', test.sl_owner(),
  'user_id', test.id('sl_sam'))) from jsonb_array_elements(test.slv('signed') -> 'signed') x));
select test.eq('jobs: one job per signed copy, a second enqueue keeps them', (select count(*) from pdf_jobs where owner_id = test.sl_owner()), 2::bigint);
insert into notification_outbox (code, category, priority, audience, owner_id, dedupe_key, payload)
values ('owner_agreement_signed', 'transactional', 2, 'owner', test.sl_owner(), 'sl-signed-email', '{}');
select test.eq('jobs: the owner''s "Signed" email waits for the signed copies',
  (select send_after > now() + interval '10 minutes' from notification_outbox where dedupe_key = 'sl-signed-email'), true);
insert into test.sl select 'claim', public.server_pdf_jobs_claim('sl-worker', 1);
select test.eq('jobs: a claim takes one job and marks it running', jsonb_array_length(test.slv('claim')) || '/' || (select status from pdf_jobs where id = (test.slv('claim') #>> '{0,id}')::uuid), '1/running');
select public.server_pdf_job_fail((test.slv('claim') #>> '{0,id}')::uuid, 'renderer exploded');
select test.eq('jobs: a failed run is queued again later, with its error',
  (select status || '/' || (next_attempt_at > now()) || '/' || last_error from pdf_jobs where id = (test.slv('claim') #>> '{0,id}')::uuid), 'queued/true/renderer exploded');
update pdf_jobs set next_attempt_at = now() - interval '1 second' where owner_id = test.sl_owner();
-- the first copy was attached (by an earlier run); the claim sees it and finishes that job without rendering
insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, owner_id)
values ('enrollment_agreement', 'Vehicle Enrollment Agreement, signed', 'agreements', 'owners/sl/enrollment-signed.pdf', 'application/pdf', repeat('9', 64), test.sl_owner());
update signature_requests set signed_document_id = (select id from documents where storage_path = 'owners/sl/enrollment-signed.pdf')
 where id = (select signature_request_id from owner_agreements where owner_id = test.sl_owner() and kind = 'enrollment');
insert into test.sl select 'claim2', public.server_pdf_jobs_claim('sl-worker', 5);
select test.eq('jobs: a copy already attached is finished without a render; the other is claimed',
  jsonb_array_length(test.slv('claim2')) || '/' || (select count(*) from pdf_jobs where owner_id = test.sl_owner() and status = 'done'), '1/1');
select test.eq('jobs: the email still waits while a copy is being made', (select send_after > now() from notification_outbox where dedupe_key = 'sl-signed-email'), true);
select public.server_pdf_job_done((test.slv('claim2') #>> '{0,id}')::uuid);
select test.eq('jobs: when the last copy is made the email goes', (select send_after <= now() from notification_outbox where dedupe_key = 'sl-signed-email'), true);
select test.eq('jobs: the email carries the signed copies attached so far',
  (select string_agg(x ->> 'k', ',') from jsonb_array_elements(app.outbox_attachments((select id from notification_outbox where dedupe_key = 'sl-signed-email'))) x), 'document');
-- a job that keeps failing: a task for an Admin after the last attempt
select public.server_pdf_jobs_enqueue(jsonb_build_array(jsonb_build_object('kind', 'renter_signed_copy', 'ref', gen_random_uuid())));
update pdf_jobs set attempts = max_attempts - 1 where kind = 'renter_signed_copy';
insert into test.sl select 'claim3', public.server_pdf_jobs_claim('sl-worker', 1);
select public.server_pdf_job_fail((test.slv('claim3') #>> '{0,id}')::uuid, 'still broken');
select test.eq('jobs: after the last attempt the job is failed and an Admin gets a task',
  (select status from pdf_jobs where id = (test.slv('claim3') #>> '{0,id}')::uuid) || '/'
  || (select count(*) from tasks where task_type = 'signed_copy_failed' and related_id = (test.slv('claim3') #>> '{0,id}')::uuid and queue = 'admin'), 'failed/1');
select test.eq('jobs: the job calls are the server''s only',
  has_function_privilege('authenticated', 'public.server_pdf_jobs_claim(text, integer)', 'execute') || '/' || has_function_privilege('anon', 'public.server_open_by_content(uuid, text[])', 'execute')
  || '/' || has_function_privilege('service_role', 'public.server_pdf_jobs_claim(text, integer)', 'execute'), 'false/false/true');

-- ================================================================ 5. each choice
-- "No invoice": nothing is made, the to-do closes, the signed car moves on
insert into test.sl select 'none', test.sl_do('sl_admin', 'first_last_choose', jsonb_build_object('vehicle_id', test.sl_car(), 'action', 'none'));
select test.eq('choice none: no invoice, the to-do is done, the signed car is past "upfront paid"',
  (select count(*) from owner_invoices where vehicle_id = test.sl_car()) || '/'
  || (select status from tasks where task_type = 'first_last_decide' and vehicle_id = test.sl_car()) || '/'
  || (select status from vehicle_onboardings where vehicle_id = test.sl_car()) || '/'
  || (select first_last_choice from vehicle_onboardings where vehicle_id = test.sl_car()), '0/done/upfront_paid/none');
select test.throws('choice: only an Admin decides', format($$select public.door(test.id('sl_cs'), null, 'va_do', 'first_last_choose', %L)$$,
  jsonb_build_object('vehicle_id', test.sl_car(), 'action', 'send')), '');

-- three more cars, added by staff for the owner (0067) with each choice
create function test.sl_add(p_key text, p_vin text, p_plan jsonb) returns void language sql as $$
  insert into test.sl select p_key, test.sl_do('sl_admin', 'staff_add_owner_car', jsonb_build_object('owner_id', test.sl_owner(), 'signing', 'email',
    'vehicle', jsonb_build_object('vin', upper(substr(md5(p_vin), 1, 17)), 'plate', upper(substr(md5(p_vin), 1, 7)), 'year', 2021, 'make', 'Toyota', 'model', 'Camry', 'colour', 'White',
      'odometer_km', 50000, 'title_status', 'owned_outright', 'management_mode', 'managed', 'onboarding_method', 'transfer', 'current_insurer', 'Aviva', 'title_brand_clear', true),
    'plan', p_plan))
$$;
select test.sl_add('send', 'sl-vin-send', jsonb_build_object('terms', jsonb_build_object('insurance_fee_cents', 41000), 'invoices', '[{"type": "first_last", "action": "send", "amount_cents": 81234}]'::jsonb));
select test.sl_add('draft', 'sl-vin-draft', jsonb_build_object('terms', jsonb_build_object('insurance_fee_cents', 42000), 'invoices', '[{"type": "first_last", "action": "draft"}]'::jsonb));
select test.sl_add('paid', 'sl-vin-paid', jsonb_build_object('terms', jsonb_build_object('insurance_fee_cents', 43000), 'invoices', jsonb_build_array(jsonb_build_object('type', 'first_last', 'action', 'paid',
  'payment', jsonb_build_object('method', 'e_transfer', 'reference', 'CAxSL999', 'received_on', app.today())))));
select test.sl_add('nochoice', 'sl-vin-later', jsonb_build_object('terms', jsonb_build_object('insurance_fee_cents', 44000), 'invoices', '[]'::jsonb));
create function test.sl_v(p text) returns uuid language sql stable as $$ select (test.slv(p) ->> 'vehicle_id')::uuid $$;
create function test.sl_upfront(p text) returns owner_invoices language sql stable as $$ select * from owner_invoices where vehicle_id = test.sl_v(p) and kind = 'upfront' and status <> 'void' $$;
select test.eq('choice send (staff added the car): issued now at the exact amount, emailed',
  (test.sl_upfront('send')).status || '/' || (test.sl_upfront('send')).fees_cents || '/'
  || (select count(*) from app_events where code = 'owner_upfront_invoice' and entity_id = (test.sl_upfront('send')).id) || '/'
  || (select first_last_choice || ':' || first_last_choice_cents from vehicle_onboardings where vehicle_id = test.sl_v('send')), 'issued/81234/1/send:81234');
select test.eq('choice draft: a draft at 2 x the Insurance Fee, never emailed',
  (test.sl_upfront('draft')).status || '/' || (test.sl_upfront('draft')).fees_cents || '/'
  || (select count(*) from app_events where code = 'owner_upfront_invoice' and entity_id = (test.sl_upfront('draft')).id), 'draft/84000/0');
select test.eq('choice paid: issued quietly and recorded as paid by e-Transfer with its reference',
  (test.sl_upfront('paid')).status || '/'
  || (select count(*) from manual_payments m where m.owner_invoice_id = (test.sl_upfront('paid')).id and m.method = 'e_transfer' and m.reference = 'CAxSL999') || '/'
  || (select count(*) from app_events where code = 'owner_upfront_invoice' and entity_id = (test.sl_upfront('paid')).id), 'paid/1/0');
select test.eq('no choice for a car staff added: nothing invoiced, the to-do names the car',
  (select count(*) from owner_invoices where vehicle_id = test.sl_v('nochoice')) || '/'
  || (select count(*) from tasks where task_type = 'first_last_decide' and vehicle_id = test.sl_v('nochoice') and status = 'open'), '0/1');
select test.eq('the Terms tab shows each car''s choice and its invoice',
  (select string_agg(coalesce(c #>> '{first_last,choice}', 'undecided') || ':' || coalesce(c #>> '{first_last,invoice,status}', '-'), ',' order by c #>> '{first_last,choice}' nulls last)
     from jsonb_array_elements(public.door(test.id('sl_admin'), null, 'ops_read', 'owner_terms', jsonb_build_object('owner_id', test.sl_owner())) -> 'cars') c),
  'draft:draft,none:-,paid:paid,send:issued,undecided:-');
select test.throws('choice: a car with a first and last invoice keeps it (change it on the invoice screen)',
  format($$select test.sl_do('sl_admin', 'first_last_choose', %L)$$, jsonb_build_object('vehicle_id', test.sl_v('send'), 'action', 'none')), 'void it on the invoice screen first');
select test.eq('...and nothing was voided', (test.sl_upfront('send')).status, 'issued');
select test.throws('choice: Already paid by e-Transfer needs its reference',
  format($$select test.sl_do('sl_admin', 'first_last_choose', %L)$$, jsonb_build_object('vehicle_id', test.sl_v('nochoice'), 'action', 'paid', 'payment', jsonb_build_object('method', 'e_transfer'))), 'reference');
select test.sl_do('sl_admin', 'first_last_choose', jsonb_build_object('vehicle_id', test.sl_v('nochoice'), 'action', 'send'));
select test.eq('choice from the Terms tab: sent at 2 x the Insurance Fee, the to-do closed',
  (test.sl_upfront('nochoice')).status || '/' || (test.sl_upfront('nochoice')).fees_cents || '/'
  || (select status from tasks where task_type = 'first_last_decide' and vehicle_id = test.sl_v('nochoice')), 'issued/88000/done');
-- the bulk path follows a choice whose invoice was voided since
select test.sl_do('sl_admin', 'owner_invoice_void', jsonb_build_object('id', (test.sl_upfront('nochoice')).id, 'reason', 'Wrong month'));
insert into test.sl select 'again', public.admin_issue_upfront_invoices(test.sl_owner(), test.id('sl_admin'));
select test.eq('the owner page''s path makes the chosen invoice again after a void',
  jsonb_array_length(test.slv('again')) || '/' || (select count(*) from owner_invoices where vehicle_id = test.sl_v('nochoice') and kind = 'upfront' and status = 'issued'), '1/1');
