-- 99: the owner signs each government form on screen (migration 1000, docs/changes/2026-11-08-r35-form-signing.md): the
-- session of the forms (checked against the records and the form's SHA-256), one signature record per form with the
-- signer, the way, the time, the IP address and the version, a form changed after signing shown as changed (the owner is
-- asked again: the checklist step opens, one reminder email), the staff read with the signature beside the form (never on
-- it), the checklist step done only when every form is signed. Fixtures "r35q".
select test.suite('99 r35q government form signing');
update program_settings set esign_strict = true;
select test.mk_user('r35q_admin', 'admin');
select test.mk_user('r35q_fleet', 'va', 'fleet');
select test.mk_user('r35q_cs', 'va', 'cs');
select test.mk_user('r35q_fin', 'va', 'finance');
create function test.r35q(p_call text, p_name text, p jsonb, p_user text default 'r35q_admin') returns jsonb language sql as $$ select app.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;
create function test.r35q_owner(p_label text) returns uuid language plpgsql as $$
declare v_user uuid := test.mk_user(p_label, 'owner');
begin
  update users set email = p_label || '@example.test', full_name = 'Pat Example' where id = v_user;
  insert into owners (id, user_id, owner_type, legal_name, first_name, last_name, status, email, phone, address_line1, city, province, postal_code, country)
  values (test.id('owner:' || p_label), v_user, 'individual', 'Pat Example', 'Pat', 'Example', 'active', p_label || '@example.test', '+16475550199',
          '1 Example Way', 'Toronto', 'ON', 'M5V 1A1', 'CA');
  return test.id('owner:' || p_label);
end $$;
select test.r35q_owner('r35q_ola');
select test.r35q_owner('r35q_other');
create table test.r35q_app as select app.submit_owner_application(jsonb_build_object('owner_id', test.id('owner:r35q_ola'), 'source', 'web', 'vehicles', jsonb_build_array(jsonb_build_object(
  'vin', '1HGCM82633A871001', 'plate', 'R35Q001', 'year', 2021, 'make', 'Hyundai', 'model', 'Sonata', 'colour', 'Blue', 'odometer_km', 20000, 'held_by', 'individual',
  'title_status', 'owned_outright', 'management_mode', 'managed', 'onboarding_method', 'co_registrant', 'current_insurer', 'Example Insurer'))), test.id('r35q_ola')) as r;
create function test.r35q_v() returns uuid language sql stable as $$ select ((select r from test.r35q_app) #>> '{vehicles,0,vehicle_id}')::uuid $$;
select app.application_approve(test.id('r35q_admin'), jsonb_build_object('id', (select r ->> 'application_id' from test.r35q_app), 'cars', jsonb_build_array(jsonb_build_object('vehicle_id', test.r35q_v(),
  'terms', jsonb_build_object('management_mode', 'managed', 'onboarding_method', 'co_registrant'), 'invoices', '[]'::jsonb, 'first_last', jsonb_build_object('action', 'none')))));
create function test.r35q_cur() returns government_form_fills language sql stable as $$
  select * from government_form_fills where vehicle_id = test.r35q_v() and form_code = 'R35Q-TEST' and superseded_at is null $$;
create function test.r35q_sha() returns text language sql stable as $$ select app.government_form_values_sha((test.r35q_cur()).id) $$;
create function test.r35q_docs(p_sha text default null) returns jsonb language sql stable as $$
  select jsonb_build_array(jsonb_build_object('kind', 'govform', 'ref', (test.r35q_cur()).id, 'title', 'R35Q-TEST', 'sha256', coalesce(p_sha, test.r35q_sha()))) $$;
-- a complete session (the code, read, the consents, the drawn signature), as the agreements' tests do
create function test.r35q_session(p_sig text, p_docs jsonb default null) returns uuid language plpgsql as $$
declare
  v uuid;
  k text;
begin
  v := (public.server_esign_start(jsonb_build_object('context', 'documents', 'signer_ref', test.id('r35q_ola'), 'owner_id', test.id('owner:r35q_ola'), 'role', 'owner',
         'ip', '203.0.113.9', 'user_agent', 'test', 'documents', coalesce(p_docs, test.r35q_docs()))) ->> 'id')::uuid;
  perform public.server_esign_code_set(v, 'email', repeat('e', 64), '203.0.113.9', 'test');
  perform public.server_esign_code_check(v, repeat('e', 64), '203.0.113.9', 'test');
  perform public.server_esign_step(v, 'viewed', '{}', '203.0.113.9', 'test');
  for k in select unnest(required_consents) from esign_sessions where id = v loop
    perform public.server_esign_step(v, 'consent', jsonb_build_object('code', k, 'text', 'I agree'), '203.0.113.9', 'test');
  end loop;
  perform public.server_esign_step(v, 'signature', jsonb_build_object('method', 'drawn', 'path', p_sig), '203.0.113.9', 'test');
  return v;
end $$;
create function test.r35q_sign(p_sig text, p_sha text default null) returns jsonb language sql as $$
  select public.owner_gov_forms_sign(test.id('r35q_ola'), jsonb_build_object('drawn_signature', p_sig, 'ip', '203.0.113.7', 'user_agent', 'test',
    'consent_text', 'I have read this form and I sign it electronically.', 'forms', jsonb_build_array(jsonb_build_object('fill', (test.r35q_cur()).id, 'sha256', coalesce(p_sha, test.r35q_sha()))))) $$;

-- ================================================================ a test form that is the publisher's PDF (an Admin's upload), the only form the car needs
insert into pdf_templates (id, form_code, version, title, kind, file_key, sha256, page_count, field_names, field_map, verified, verified_by, verified_at, is_current, uploaded_by, mapped_by, mapped_at)
values (test.id('tpl:r35q'), 'R35Q-TEST', 'official-r35q-1', 'R35Q-TEST: test form', 'acroform', 'forms/templates/R35Q-TEST/official-r35q.pdf', repeat('c', 64), 1,
        '[{"name": "vin_box", "type": "text", "label": "Vehicle Identification Number", "max_length": 17}, {"name": "name_box", "type": "text", "label": "Name"}]'::jsonb,
        '{"vin_box": {"source": "vehicle.vin", "transform": "upper", "required": true}, "name_box": {"source": "owner.legal_name", "transform": "upper"}}'::jsonb,
        true, test.id('r35q_admin'), now(), true, test.id('r35q_admin'), test.id('r35q_admin'), now());
-- what the forms ask of the owner and the car, so the test form is complete (set before the form is made: a change of the car makes its forms again)
insert into owner_private_details (owner_id, licence_number, date_of_birth) values (test.id('owner:r35q_ola'), 'P1234-56789-01201', '1985-04-12')
  on conflict (owner_id) do update set licence_number = excluded.licence_number, date_of_birth = excluded.date_of_birth;
update vehicles set body_type = 'Sedan' where id = test.r35q_v();
update vehicle_onboardings set government_forms = array['R35Q-TEST'] where vehicle_id = test.r35q_v();
select app.fill_government_form(test.r35q_v(), 'R35Q-TEST', null);
select test.eq('fixture: the form is made and ready', (test.r35q_cur()).status || '/' || (test.r35q_cur()).mode, 'ready/pdf');

-- ================================================================ 1. unsigned: the checklist step waits on the owner
select test.eq('an unsigned form: state, signable, one to sign',
  app.government_form_sign_state((test.r35q_cur()).id) || '/' || (select signable from app.gov_forms_sign_rows(test.r35q_v())) || '/' || (app.gov_forms_sign_counts(test.r35q_v()) ->> 'to_sign'),
  'unsigned/true/1');
select test.eq('the government forms step is a To do for the owner (not done by being made)',
  (select status || '/' || coalesce(waits_on, '') || '/' || coalesce(next_action, '') from app.onboarding_checklist(test.r35q_v()) where code = 'government_forms'),
  'open/owner/Sign your government forms');
select test.eq('the overview counts them for the checklist',
  (test.r35q('ops_read', 'onboarding_overview', jsonb_build_object('owner_id', test.id('owner:r35q_ola'))) #>> '{cars,0,forms,to_sign}'), '1');
select test.eq('the owner''s list shows the state and the form can be signed',
  (select (f ->> 'sign_state') || '/' || (f ->> 'signable') from jsonb_array_elements(test.r35q('ops_read', 'government_forms', jsonb_build_object('vehicle_id', test.r35q_v()), 'r35q_ola') #> '{cars,0,forms}') f where f ->> 'form_code' = 'R35Q-TEST'),
  'unsigned/true');
select test.eq('the owner''s sign page reads the form (values and SHA-256) for their own car only',
  (app.owner_gov_forms_to_sign(test.id('r35q_ola'), jsonb_build_object('vehicle_id', test.r35q_v())) #>> '{forms,0,sha256}') = test.r35q_sha()
  and app.owner_gov_forms_to_sign(test.id('r35q_other'), jsonb_build_object('vehicle_id', test.r35q_v())) is null, true);

-- a form that waits for the signature is reminded after a day, once (counted for this car; other cars' fixtures are not ours)
create function test.r35q_mails(p_status text default null) returns bigint language sql stable as $$
  select count(*) from notification_outbox where dedupe_key like 'owner_forms_to_sign:' || test.r35q_v() || ':%' and (p_status is null or status = p_status) $$;
select app.government_forms_sign_nudge(now());
select test.eq('a form made a moment ago is not reminded yet', test.r35q_mails(), 0::bigint);
update government_form_fills set generated_at = now() - interval '2 days' where vehicle_id = test.r35q_v() and form_code = 'R35Q-TEST';
select app.government_forms_sign_nudge(now());
select test.eq('unsigned for a day: one reminder', test.r35q_mails('queued'), 1::bigint);
select app.government_forms_sign_nudge(now());
select test.eq('and the same state is not reminded twice', test.r35q_mails(), 1::bigint);

-- ================================================================ 2. the session and the signature
select test.throws('a changed SHA-256 is refused when the session starts',
  format($$select public.server_esign_start(%L)$$, jsonb_build_object('context', 'documents', 'signer_ref', test.id('r35q_ola'), 'owner_id', test.id('owner:r35q_ola'), 'documents', test.r35q_docs(repeat('0', 64)))),
  'changed after you opened it');
select test.throws('another person cannot start a session for the owner''s form',
  format($$select public.server_esign_start(%L)$$, jsonb_build_object('context', 'documents', 'signer_ref', test.id('r35q_other'), 'owner_id', test.id('owner:r35q_other'), 'documents', test.r35q_docs())), 'Not found');
select test.throws('forms and agreements are not signed in one session',
  format($$select public.server_esign_start(%L)$$, jsonb_build_object('context', 'documents', 'signer_ref', test.id('r35q_ola'), 'owner_id', test.id('owner:r35q_ola'),
    'documents', test.r35q_docs() || jsonb_build_array(jsonb_build_object('kind', 'packet', 'ref', 'enrollment', 'title', 'x', 'sha256', repeat('0', 64))))), 'own page');
select test.throws('no signature without a complete session', $$select test.r35q_sign('esign/r35q/sig.png')$$, 'draw your signature before signing');
create table test.r35q_s1 as select test.r35q_session('esign/r35q/sig.png') as id;
select test.eq('the session names the owner from the records; no key terms to initial, two consents',
  (select signer_name || '/' || cardinality(required_initials) || '/' || array_to_string(required_consents, ',') from esign_sessions where id = (select id from test.r35q_s1)), 'Pat Example/0/esign,erecords');
select test.throws('the drawn signature must be the session''s', $$select test.r35q_sign('esign/r35q/other.png')$$, 'does not match');
select test.throws('another owner cannot sign the form', format($$select public.owner_gov_forms_sign(%L, %L)$$, test.id('r35q_other'),
  jsonb_build_object('drawn_signature', 'esign/r35q/sig.png', 'forms', jsonb_build_array(jsonb_build_object('fill', (test.r35q_cur()).id, 'sha256', test.r35q_sha())))), 'not yours');
select test.eq('signed: one record', (test.r35q_sign('esign/r35q/sig.png') ->> 'signed'), '1');
select test.eq('the record: signer, way, version, IP address, device, session; the signature is a stored drawing',
  (select signer_name || '/' || method || '/' || form_version || '/' || host(ip_address) || '/' || user_agent || '/' || (esign_session_id = (select id from test.r35q_s1)) || '/' || signature_path
     from government_form_signatures where vehicle_id = test.r35q_v() and form_code = 'R35Q-TEST'),
  'Pat Example/drawn/1/203.0.113.7/test/true/esign/r35q/sig.png');
select test.eq('the session is closed and its trail has the steps',
  (select (signed_at is not null) || '/' || (select count(*) from esign_events e where e.session_id = s.id and e.kind in ('started', 'viewed', 'consent', 'signature', 'signed'))
     from esign_sessions s where s.id = (select id from test.r35q_s1)), 'true/6');
select test.eq('signed: the state, and the form on the official PDF is untouched (no signature in its values)',
  app.government_form_sign_state((test.r35q_cur()).id) || '/' || (not (test.r35q_cur()).field_values::text ilike '%esign%'), 'signed/true');
select test.throws('the same session signs once only', $$select test.r35q_sign('esign/r35q/sig.png')$$, 'draw your signature before signing');
select test.eq('the checklist step is done when every form is signed',
  (select status from app.onboarding_checklist(test.r35q_v()) where code = 'government_forms'), 'done');
select test.eq('signed count in the overview', (test.r35q('ops_read', 'onboarding_overview', jsonb_build_object('owner_id', test.id('owner:r35q_ola'))) #>> '{cars,0,forms}')::jsonb ->> 'signed', '1');
select test.throws('a signature is never changed', $$update government_form_signatures set signer_name = 'X'$$, 'never changed');
select test.throws('a signature is never removed', $$delete from government_form_signatures$$, 'never changed');

-- ================================================================ 3. staff: the form with the signature beside it
select test.eq('the staff read: signed, who and when, the way, the version, nothing changed; customer service reads it too',
  (select (x ->> 'sign_state') || '/' || (x #>> '{signature,signer_name}') || '/' || (x #>> '{signature,method}') || '/' || (x #>> '{signature,form_version}') || '/' || (x #>> '{signature,same_values}')
     || '/' || (x #>> '{signature,ip}') || '/' || jsonb_array_length(x -> 'signatures')
     from (select test.r35q('va_read', 'government_form_fill', jsonb_build_object('fill', (test.r35q_cur()).id), 'r35q_cs') x) y),
  'signed/Pat Example/drawn/1/true/203.0.113.7/1');
select test.eq('the owner''s list now says signed', (select f ->> 'sign_state' from jsonb_array_elements(test.r35q('ops_read', 'government_forms', jsonb_build_object('vehicle_id', test.r35q_v()), 'r35q_ola') #> '{cars,0,forms}') f where f ->> 'form_code' = 'R35Q-TEST'), 'signed');
select app.government_forms_sign_nudge(now());
select test.eq('no new reminder for a signed form (the one waiting is still the only one)', test.r35q_mails(), 1::bigint);

-- ================================================================ 4. changed after signing: asked again
create table test.r35q_e1 as select test.r35q('va_do', 'government_form_edit', jsonb_build_object('fill', (test.r35q_cur()).id, 'field', 'name_box',
  'value', 'EXAMPLE, PAT Q', 'reason', 'The registry writes the last name first'), 'r35q_fleet') as r;
select test.eq('changed since signed (version 2, the earlier signature kept)',
  (select r ->> 'version' from test.r35q_e1) || '/' || app.government_form_sign_state((test.r35q_cur()).id), '2/changed');
select test.eq('the staff read marks it changed and names the box; the signature stays beside it with its version',
  (select (x ->> 'sign_state') || '/' || (x #>> '{signature,form_version}') || '/' || (x #>> '{signature,current_version}') || '/' || (x #>> '{signature,same_values}') || '/' || (x #>> '{signature,changed}')
     from (select test.r35q('va_read', 'government_form_fill', jsonb_build_object('fill', (test.r35q_cur()).id), 'r35q_cs') x) y),
  'changed/1/2/false/["name_box"]');
select test.eq('the step opens again for the owner: sign again',
  (select status || '/' || coalesce(waits_on, '') || '/' || coalesce(next_action, '') from app.onboarding_checklist(test.r35q_v()) where code = 'government_forms'),
  'open/owner/Sign the government forms again: a value changed after you signed');
select test.eq('the overview counts one changed', (test.r35q('ops_read', 'onboarding_overview', jsonb_build_object('owner_id', test.id('owner:r35q_ola'))) #>> '{cars,0,forms,changed}'), '1');
select test.eq('the owner''s list says changed', (select f ->> 'sign_state' from jsonb_array_elements(test.r35q('ops_read', 'government_forms', jsonb_build_object('vehicle_id', test.r35q_v()), 'r35q_ola') #> '{cars,0,forms}') f where f ->> 'form_code' = 'R35Q-TEST'), 'changed');
select test.throws('the old signature does not sign the new version (the old SHA-256 is refused)', format($$select test.r35q_sign('esign/r35q/sig.png', %L)$$, (select values_sha from government_form_signatures limit 1)), 'changed after you opened it');

-- one reminder email, once for this state
select app.government_forms_sign_nudge(now());
select test.eq('a form changed after it was signed: a new reminder replaces the one still waiting', test.r35q_mails('queued') || '/' || test.r35q_mails('skipped'), '1/1');
select test.eq('the reminder: the signing email, to the owner, with the link to the forms and a note that asks to sign again',
  (select code || '/' || to_address || '/' || ((payload ->> 'sign_url') like '%/owner/sign/forms/' || test.r35q_v()) || '/' || ((payload ->> 'note') like '%sign%again%')
     from notification_outbox where dedupe_key like 'owner_forms_to_sign:' || test.r35q_v() || ':%' and status = 'queued'),
  'owner_agreement_to_sign/r35q_ola@example.test/true/true');
select test.eq('queued once', (select count(*) from notification_outbox where dedupe_key like 'owner_forms_to_sign:' || test.r35q_v() || ':%' and status = 'queued'), 1::bigint);
select app.government_forms_sign_nudge(now());
select test.eq('the same state is not reminded again', test.r35q_mails(), 2::bigint);
select test.eq('the daily job runs it (nothing new)', app.notify_daily_checks(now()) >= 0, true);

-- a form with a value missing cannot be signed and is not reminded
select test.r35q('ops_do', 'government_form_edit', jsonb_build_object('fill', (test.r35q_cur()).id, 'field', 'vin_box', 'value', '', 'reason', 'The VIN is checked at the counter'));
select test.eq('a form that misses a value is not signable', (select signable::text from app.gov_forms_sign_rows(test.r35q_v())), 'false');
select test.throws('a session is not started for a form that misses a value',
  format($$select public.server_esign_start(%L)$$, jsonb_build_object('context', 'documents', 'signer_ref', test.id('r35q_ola'), 'owner_id', test.id('owner:r35q_ola'), 'documents', test.r35q_docs())), 'still missing');
select test.r35q('ops_do', 'government_form_edit', jsonb_build_object('fill', (test.r35q_cur()).id, 'field', 'vin_box', 'value', '1HGCM82633A871001', 'reason', 'Read at the counter'));

-- signed again: the new version, a second record, the first kept
create table test.r35q_s2 as select test.r35q_session('esign/r35q/sig2.png') as id;
select test.eq('signed again: one record for the new version', (test.r35q_sign('esign/r35q/sig2.png') ->> 'signed'), '1');
select test.eq('signed again: both records stay, the latest is for version 4 and matches the values now',
  (select count(*) || '/' || max(form_version) from government_form_signatures where vehicle_id = test.r35q_v() and form_code = 'R35Q-TEST') || '/' || app.government_form_sign_state((test.r35q_cur()).id),
  '2/4/signed');
select test.eq('the step is done again', (select status from app.onboarding_checklist(test.r35q_v()) where code = 'government_forms'), 'done');

-- a form signed in ink needs no signature on screen
update government_form_fills set status = 'signed', missing = '{}', signed_at = now() where id = (test.r35q_cur()).id;
select test.eq('signed in ink: ink', app.government_form_sign_state((test.r35q_cur()).id), 'ink');
select test.throws('and no session is started for it', format($$select public.server_esign_start(%L)$$, jsonb_build_object('context', 'documents', 'signer_ref', test.id('r35q_ola'),
  'owner_id', test.id('owner:r35q_ola'), 'documents', test.r35q_docs())), 'signed in ink');

-- ================================================================ privileges
select test.ok('privileges: the service role only', has_function_privilege('service_role', 'public.owner_gov_forms_sign(uuid, jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'public.owner_gov_forms_sign(uuid, jsonb)', 'execute') and not has_function_privilege('anon', 'public.owner_gov_forms_to_sign(uuid, jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'app.government_form_sign_state(uuid)', 'execute') and not has_function_privilege('authenticated', 'app.government_forms_sign_nudge(timestamptz)', 'execute'));
select test.ok('privileges: the signatures table is not readable by anon', not has_table_privilege('anon', 'government_form_signatures', 'select'));
-- leave the shared catalogue as it was
update government_form_fills set superseded_at = now() where form_code = 'R35Q-TEST' and superseded_at is null;
update pdf_templates set is_current = false where form_code = 'R35Q-TEST';
-- the suites run with the strict signing steps off (helpers.sql); later suites sign with the older steps
update program_settings set esign_strict = false;
