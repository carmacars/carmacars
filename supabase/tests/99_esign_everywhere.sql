-- 99: every signature through the signing session (migration 0193, docs/changes/2026-10-27-esign-everywhere.md): the
-- owner's agreements, another Owner's link, Form C on screen, the staff and investment agreements, an updated Vehicle
-- Schedule. Each signing function refuses a signature without a complete session (the code, the reading, the key terms
-- initialled, the consents, the drawn signature); the session is checked against the documents; the signature records
-- name it; the certificate reads it; /verify finds the signed copies. Uses 87's idea of a session helper. Fixtures start
-- with "ee".
select test.suite('99 esign everywhere');
grant usage on schema test to service_role;
update program_settings set esign_strict = true;

create function test.ee_sha(p text) returns text language sql immutable as $$ select md5(p) || md5(p || 'ee') $$;
create table test.ee (k text primary key, v jsonb);
create function test.eev(p text) returns jsonb language sql stable as $$ select v from test.ee where k = p $$;
-- a complete session: the code (by email), read, each term initialled, each consent, the place, the drawn signature
create function test.ee_session(p_ctx text, p_ref uuid, p_docs jsonb, p_owner uuid, p_sig text) returns uuid language plpgsql as $$
declare
  v uuid;
  k text;
begin
  v := (public.server_esign_start(jsonb_build_object('context', p_ctx, 'signer_ref', p_ref, 'owner_id', p_owner, 'role', 'owner', 'ip', '203.0.113.9',
                                                     'user_agent', 'test', 'documents', p_docs)) ->> 'id')::uuid;
  perform public.server_esign_code_set(v, 'email', repeat('e', 64), '203.0.113.9', 'test');
  perform public.server_esign_code_check(v, repeat('e', 64), '203.0.113.9', 'test');
  perform public.server_esign_step(v, 'viewed', '{}', '203.0.113.9', 'test');
  for k in select unnest(required_initials) from esign_sessions where id = v loop
    perform public.server_esign_step(v, 'initial', jsonb_build_object('code', k, 'path', 'esign/' || v || '/initials-' || k || '.png'), '203.0.113.9', 'test');
  end loop;
  for k in select unnest(required_consents) from esign_sessions where id = v loop
    perform public.server_esign_step(v, 'consent', jsonb_build_object('code', k, 'text', 'I agree'), '203.0.113.9', 'test');
  end loop;
  perform public.server_esign_step(v, 'geolocation', '{"lat": 43.65, "lng": -79.38, "accuracy": 25}', '203.0.113.9', 'test');
  perform public.server_esign_step(v, 'signature', jsonb_build_object('method', 'drawn', 'path', p_sig), '203.0.113.9', 'test');
  return v;
end $$;

select test.mk_user('ee_admin', 'admin');
select test.mk_user('ee_cs', 'va', 'cs');

-- ================================================================ 1. the owner's agreements, and another Owner's link
insert into users (id, email, full_name) values (test.id('ee_olga'), 'olga.ee@example.test', 'Olga Owner');
create function test.ee_vin(p text) returns text language sql immutable as $$ select upper(substr(md5('ee-vin-' || p), 1, 17)) $$;
insert into test.ee select 'app', to_jsonb((public.server_submit_owner_application(jsonb_build_object('source', 'web',
  'owner', jsonb_build_object('owner_type', 'individual', 'legal_name', 'Olga Owner', 'first_name', 'Olga', 'last_name', 'Owner', 'email', 'olga.ee@example.test',
                              'phone', '+16475550182', 'address_line1', '30 King Street West', 'city', 'Toronto', 'province', 'ON', 'postal_code', 'M5H 1A1',
                              'licence_number', 'O1234-56789-01821', 'date_of_birth', '1985-05-05'),
  'vehicles', jsonb_build_array(
    jsonb_build_object('vin', test.ee_vin('1'), 'plate', 'EEAA101', 'year', 2023, 'make', 'Honda', 'model', 'Civic', 'colour', 'Grey', 'odometer_km', 15000,
                       'title_status', 'financed', 'finance_party_name', 'TD Auto Finance', 'management_mode', 'managed', 'onboarding_method', 'transfer', 'current_insurer', 'Aviva'))),
  test.id('ee_olga')) ->> 'owner_id')::uuid);
create function test.ee_owner() returns uuid language sql stable as $$ select (test.eev('app') #>> '{}')::uuid $$;
select public.admin_set_vehicle_terms(v.id, test.id('ee_admin'), '{}') from vehicles v where v.owner_id = test.ee_owner();
select public.door(test.id('ee_admin'), null, 'ops_do', 'owner_cosigner_add', jsonb_build_object('owner_id', test.ee_owner(), 'name', 'Cora Coowner', 'email', 'cora.ee@example.test'));
select public.owner_open_agreements(test.ee_owner(), test.id('ee_olga'), jsonb_build_array(
  jsonb_build_object('key', 'enrollment', 'template_version', 'enrollment-test', 'sha256', test.ee_sha('ea'), 'storage_path', 'owners/ee/ea.pdf'),
  jsonb_build_object('key', 'title_holding', 'template_version', 'title-test', 'sha256', test.ee_sha('ta'), 'storage_path', 'owners/ee/ta.pdf')));
create function test.ee_packet() returns jsonb language sql immutable as $$
  select jsonb_build_array(jsonb_build_object('kind', 'packet', 'ref', 'enrollment', 'title', 'Enrollment Agreement', 'sha256', test.ee_sha('ea')),
                           jsonb_build_object('kind', 'packet', 'ref', 'title_holding', 'title', 'Title-Holding and Lease Agreement', 'sha256', test.ee_sha('ta'))) $$;
create function test.ee_sign_owner(p_sig text) returns jsonb language sql as $$
  select public.owner_sign_agreements(test.ee_owner(), test.id('ee_olga'), jsonb_build_object('drawn_signature', p_sig, 'ip', '203.0.113.7', 'user_agent', 'test',
    'consent_text', 'I have read these documents and I sign them electronically. One signature for: Enrollment Agreement; Title-Holding and Lease Agreement.',
    'initials', '{"own_insurance":"OO","fees_no_income":"OO","tracker_downtime":"OO"}'::jsonb,
    'documents', jsonb_build_array(jsonb_build_object('key', 'enrollment', 'sha256', test.ee_sha('ea')), jsonb_build_object('key', 'title_holding', 'sha256', test.ee_sha('ta'))))) $$;

select test.throws('owner: the agreements are not signed without a signing session', $$select test.ee_sign_owner('signatures/ee/olga.png')$$, 'initial the key terms, give the consents and draw your signature before signing');
select test.throws('owner: a session is checked against the open documents (a changed SHA-256 is refused)',
  format($$select public.server_esign_start(%L)$$, jsonb_build_object('context', 'documents', 'signer_ref', test.id('ee_olga'), 'owner_id', test.ee_owner(),
    'documents', jsonb_build_array(jsonb_build_object('kind', 'packet', 'ref', 'enrollment', 'title', 'Enrollment Agreement', 'sha256', repeat('0', 64))))), 'documents changed');
select test.throws('owner: nobody starts a session for another person''s owner documents',
  format($$select public.server_esign_start(%L)$$, jsonb_build_object('context', 'documents', 'signer_ref', test.id('ee_cs'), 'owner_id', test.ee_owner(), 'documents', test.ee_packet())), 'Only the owner');
insert into test.ee select 'olga_s', to_jsonb(test.ee_session('documents', test.id('ee_olga'), test.ee_packet(), test.ee_owner(), 'esign/olga/signature.png'));
select test.eq('owner: the session names the owner from the records, initials the Enrollment Agreement''s three confirmations, two consents, the code by text or email',
  (select signer_name || '/' || array_to_string(required_initials, ',') || '/' || array_to_string(required_consents, ',') || '/' || (mobile is not null) || '/' || (email is not null)
     from esign_sessions where id = (test.eev('olga_s') #>> '{}')::uuid),
  'Olga Owner/own_insurance,fees_no_income,tracker_downtime/esign,erecords/true/true');
select test.throws('owner: the drawn signature must be the session''s', $$select test.ee_sign_owner('signatures/ee/other.png')$$, 'does not match');
select test.lives('owner: with the session, the owner signs both documents', $$select test.ee_sign_owner('esign/olga/signature.png')$$);
select test.eq('owner: each of the owner''s records names the session; the session is closed (both documents signed)',
  (select count(*) from signature_records x join owner_agreements a on a.signature_request_id = x.signature_request_id
    where a.owner_id = test.ee_owner() and x.signer_role = 'owner_individual' and x.esign_session_id = (test.eev('olga_s') #>> '{}')::uuid)
  || '/' || (select (signed_at is not null) || ':' || cardinality(signed_refs) from esign_sessions where id = (test.eev('olga_s') #>> '{}')::uuid), '2/true:2');

-- another Owner named in the Title Schedule, with their link (the code by email: no phone on file)
create function test.ee_co() returns owner_cosigners language sql stable as $$ select * from owner_cosigners where owner_id = test.ee_owner() and status <> 'removed' limit 1 $$;
create function test.ee_co_docs() returns jsonb language sql stable as $$
  select jsonb_agg(jsonb_build_object('kind', 'packet', 'ref', q.key, 'title', q.key, 'sha256', q.sha256) order by q.key) from app.owner_open_requests(test.ee_owner()) q $$;
create function test.ee_co_sign(p_sig text) returns jsonb language sql as $$
  select public.server_owner_cosigner_sign((test.ee_co()).token, jsonb_build_object('drawn_signature', p_sig, 'ip', '203.0.113.8', 'user_agent', 'test',
    'consent_text', 'I have read these documents and I sign them electronically.', 'initials', 'CC',
    'documents', (select jsonb_agg(jsonb_build_object('signature_request_id', q.signature_request_id, 'sha256', q.sha256)) from app.owner_open_requests(test.ee_owner()) q))) $$;
select test.throws('co-owner: their link does not sign without a signing session', $$select test.ee_co_sign('esign/cora/signature.png')$$, 'initial the key terms, give the consents and draw your signature before signing');
select test.throws('co-owner: their session covers every open document', format($$select public.server_esign_start(%L)$$,
  jsonb_build_object('context', 'owner_cosigner', 'signer_ref', (test.ee_co()).id, 'documents', jsonb_build_array(test.ee_co_docs() -> 0))), 'documents changed');
insert into test.ee select 'cora_s', to_jsonb(test.ee_session('owner_cosigner', (test.ee_co()).id, test.ee_co_docs(), null, 'esign/cora/signature.png'));
select test.eq('co-owner: the session is theirs (their name, their email only), the confirmations to initial',
  (select signer_name || '/' || coalesce(mobile, 'no phone') || '/' || array_length(required_initials, 1) from esign_sessions where id = (test.eev('cora_s') #>> '{}')::uuid),
  'Cora Coowner/no phone/3');
select test.eq('co-owner: the code by email is the documents'' signing code, to their email',
  (select count(*) from app_events where code = 'document_signing_code' and entity_id = (test.eev('cora_s') #>> '{}')::uuid), 0::bigint);
select public.server_esign_code_email((test.eev('cora_s') #>> '{}')::uuid, '123456');
select test.eq('co-owner: the code email is queued for their email, with what they sign', (select (payload ->> 'signer_email') || '/' || (payload ->> 'document_label')
     from app_events where code = 'document_signing_code' and entity_id = (test.eev('cora_s') #>> '{}')::uuid), 'cora.ee@example.test/your 2 documents');
select app.process_events(100000);
select test.eq('co-owner: the email goes to them (never a renter''s booking email)',
  (select string_agg(to_address, ',') from notification_outbox where code = 'document_signing_code' and payload ->> 'code' = '123456'), 'cora.ee@example.test');
select test.eq('co-owner: with the session, the last Owner signs: the agreements take effect', test.ee_co_sign('esign/cora/signature.png') ->> 'complete', 'true');
select test.eq('co-owner: their records name their session; it is closed',
  (select count(*) from signature_records where esign_session_id = (test.eev('cora_s') #>> '{}')::uuid)
  || '/' || (select (signed_at is not null)::text from esign_sessions where id = (test.eev('cora_s') #>> '{}')::uuid), '2/true');
select test.eq('certificate: the Enrollment Agreement''s: both Owners with their code, initials and place, and the SHA-256 signed',
  (select (c ->> 'sha256') || '/' || jsonb_array_length(c -> 'signers') || '/' || (c #>> '{signers,0,otp_channel}') || '/' || (select count(*) from jsonb_object_keys(c #> '{signers,1,initials}'))
          || '/' || (c #>> '{signers,0,geo,lat}') || '/' || (jsonb_array_length(c #> '{signers,0,events}') >= 10)
     from (select public.server_esign_certificate_for_request((select signature_request_id from owner_agreements where owner_id = test.ee_owner() and kind = 'enrollment')) c) x),
  test.ee_sha('ea') || '/2/email/3/43.65/true');

-- ================================================================ 2. Form C on screen (the owner's session; the witness types their name)
insert into test.ee select 'fc', public.owner_form_c_open(test.id('ee_olga'), (select id from vehicles where vin = test.ee_vin('1')), test.ee_sha('fc'), 'owners/' || test.ee_owner() || '/forms/form-c.pdf', 'forms-cd-screen');
create function test.ee_fc_sign(p_sig text) returns jsonb language sql as $$
  select public.sign_request_sign(test.id('ee_olga'), (test.eev('fc') ->> 'id')::uuid,
    jsonb_build_object('drawn_signature', p_sig, 'consent_text', 'I sign Form C electronically, in the presence of my witness.', 'document_sha256', test.ee_sha('fc'), 'initials', 'OO',
                       'acknowledgments', '["1","2","3"]'::jsonb, 'witness_name', 'Wendy Witness', 'witness_statement', 'I witnessed Olga Owner sign in my presence.')) $$;
select test.throws('Form C: not signed without the owner''s session', $$select test.ee_fc_sign('esign/olga/fc.png')$$, 'initial the key terms, give the consents and draw your signature before signing');
insert into test.ee select 'fc_s', to_jsonb(test.ee_session('documents', test.id('ee_olga'),
  jsonb_build_array(jsonb_build_object('kind', 'request', 'ref', test.eev('fc') ->> 'id', 'title', 'Form C', 'sha256', test.ee_sha('fc'))), null, 'esign/olga/fc.png'));
select test.eq('Form C: the owner initials its three acknowledgments', (select array_to_string(required_initials, ',') from esign_sessions where id = (test.eev('fc_s') #>> '{}')::uuid),
  'read_warning,no_advice,bears_consequences');
select test.lives('Form C: with the session, the owner signs and the witness confirms', $$select test.ee_fc_sign('esign/olga/fc.png')$$);
select test.eq('Form C: the owner''s record names the session, the witness''s does not (typed beside them)',
  (select string_agg(x.signer_role || '=' || (x.esign_session_id is not null), ',' order by x.signer_role) from signature_records x
    where x.signature_request_id = (test.eev('fc') ->> 'signature_request_id')::uuid), 'owner_individual=true,witness=false');

-- ================================================================ 3. the staff and investment agreements
insert into test.ee select 'sa', public.door(test.id('ee_admin'), null, 'ops_do', 'sign_request_create', jsonb_build_object('doc_type', 'staff_agreement', 'staff_user_id', test.id('ee_cs'),
  'title', 'VA Agreement', 'document', jsonb_build_object('path', 'staff/ee/va.pdf', 'sha256', test.ee_sha('va')), 'extra', jsonb_build_object('generated', true)));
create function test.ee_sa_sign(p_sig text) returns jsonb language sql as $$
  select public.sign_request_sign(test.id('ee_cs'), (test.eev('sa') ->> 'id')::uuid, jsonb_build_object('drawn_signature', p_sig, 'consent_text', 'I agree',
    'document_sha256', test.ee_sha('va'), 'ip', '203.0.113.5', 'user_agent', 'test')) $$;
select test.throws('staff agreement: not signed without a signing session', $$select test.ee_sa_sign('esign/cs/sig.png')$$, 'initial the key terms, give the consents and draw your signature before signing');
select test.throws('staff agreement: only the staff member starts its session', format($$select public.server_esign_start(%L)$$, jsonb_build_object('context', 'documents', 'signer_ref', test.id('ee_admin'),
  'documents', jsonb_build_array(jsonb_build_object('kind', 'request', 'ref', test.eev('sa') ->> 'id', 'title', 'VA Agreement', 'sha256', test.ee_sha('va'))))), 'Not found');
insert into test.ee select 'sa_s', to_jsonb(test.ee_session('documents', test.id('ee_cs'),
  jsonb_build_array(jsonb_build_object('kind', 'request', 'ref', test.eev('sa') ->> 'id', 'title', 'VA Agreement', 'sha256', test.ee_sha('va'))), null, 'esign/cs/sig.png'));
select test.eq('staff agreement: the staff member initials confidentiality, the rules and the ending',
  (select array_to_string(required_initials, ',') from esign_sessions where id = (test.eev('sa_s') #>> '{}')::uuid), 'staff_confidentiality,staff_rules,staff_ending');
select test.throws('staff agreement: a session does not sign another drawing', $$select test.ee_sa_sign('esign/cs/other.png')$$, 'does not match');
select test.lives('staff agreement: with the session, the staff member signs', $$select test.ee_sa_sign('esign/cs/sig.png')$$);
select test.eq('staff agreement: the record names the session, the session is closed, CarmaCars countersigned',
  (select (x.esign_session_id = (test.eev('sa_s') #>> '{}')::uuid)::text from signature_records x where x.signature_request_id = (test.eev('sa') ->> 'signature_request_id')::uuid and x.signer_role <> 'carmacars')
  || '/' || (select (signed_at is not null)::text from esign_sessions where id = (test.eev('sa_s') #>> '{}')::uuid)
  || '/' || (select count(*) from signature_records x where x.signature_request_id = (test.eev('sa') ->> 'signature_request_id')::uuid and x.signer_role = 'carmacars'), 'true/true/1');
select public.server_sign_request_attach((test.eev('sa') ->> 'id')::uuid, 'staff/ee/va-signed.pdf', test.ee_sha('va-signed'));
select test.eq('verify: the signed staff agreement is found on /verify', public.server_verify_sha(test.ee_sha('va-signed')) ->> 'found', 'true');
select test.eq('verify: the unsigned original is not a signed copy', public.server_verify_sha(test.ee_sha('va')) ->> 'found', 'false');

insert into users (id, email, full_name) values (test.id('ee_ivan'), 'ivan.ee@example.test', 'Ivan Investor');
insert into investors (id, user_id, legal_name, investor_type, email, status) values (test.id('inv:ee_ivan'), test.id('ee_ivan'), 'Ivan Investor', 'individual', 'ivan.ee@example.test', 'prospect');
insert into test.ee select 'ia', public.door(test.id('ee_admin'), null, 'ops_do', 'sign_request_create', jsonb_build_object('doc_type', 'investment_agreement', 'investor_id', test.id('inv:ee_ivan'),
  'exemption_category', 'accredited_investor', 'document', jsonb_build_object('path', 'investors/ee/ia.pdf', 'sha256', test.ee_sha('ia'))));
select test.throws('investment agreement: not signed without a signing session', format($$select public.sign_request_sign(%L, %L, %L)$$, test.id('ee_ivan'), test.eev('ia') ->> 'id',
  jsonb_build_object('drawn_signature', 'esign/ivan/sig.png', 'consent_text', 'I agree', 'document_sha256', test.ee_sha('ia'), 'legal_advice_choice', 'declined', 'initials', 'II')), 'initial the key terms, give the consents and draw your signature before signing');
insert into test.ee select 'ia_s', to_jsonb(test.ee_session('documents', test.id('ee_ivan'),
  jsonb_build_array(jsonb_build_object('kind', 'request', 'ref', test.eev('ia') ->> 'id', 'title', 'Investment agreement', 'sha256', test.ee_sha('ia'))), null, 'esign/ivan/sig.png'));
select test.eq('investment agreement: Schedule C is initialled in the session', (select array_to_string(required_initials, ',') from esign_sessions where id = (test.eev('ia_s') #>> '{}')::uuid), 'schedule_c');
select test.lives('investment agreement: with the session, the investor signs', format($$select public.sign_request_sign(%L, %L, %L)$$, test.id('ee_ivan'), test.eev('ia') ->> 'id',
  jsonb_build_object('drawn_signature', 'esign/ivan/sig.png', 'consent_text', 'I agree', 'document_sha256', test.ee_sha('ia'), 'legal_advice_choice', 'declined', 'initials', 'II')));
select test.eq('investment agreement: awaiting CarmaCars'' countersignature, the investor''s record names the session',
  (select (x.esign_session_id is not null)::text from signature_records x join investment_agreements a on a.signature_request_id = x.signature_request_id
    where a.investor_id = test.id('inv:ee_ivan') and x.signer_role <> 'carmacars'), 'true');

-- ================================================================ 4. an updated Vehicle Schedule
select test.mk_owner('ee_sam');
select test.mk_vehicle('EES', 'ee_sam', 'managed', 45000, 2500, 3500, date '2026-09-01');
insert into test.ee select 'chg', public.door(test.id('ee_admin'), null, 'ops_do', 'owner_terms_save', jsonb_build_object('vehicle_id', test.id('vehicle:EES'),
  'insurance_fee_cents', 41000, 'revenue_share_bps', 3200, 'effective_from', app.today() + 20, 'confirm_resign', true));
create function test.ee_chg() returns uuid language sql stable as $$ select (test.eev('chg') ->> 'change_id')::uuid $$;
create function test.ee_chg_sha() returns text language sql stable as $$ select public.server_owner_schedule_change(test.id('ee_sam'), test.ee_chg()) ->> 'sha256' $$;
select test.throws('schedule: an updated Vehicle Schedule is not signed with a typed name alone', format($$select public.server_schedule_change_sign(%L, %L)$$, test.id('ee_sam'),
  jsonb_build_object('change_id', test.ee_chg(), 'agree', true, 'name', 'Ee Sam', 'sha256', test.ee_chg_sha())), 'initial the key terms, give the consents and draw your signature before signing');
select test.throws('schedule: its session binds the text on screen', format($$select public.server_esign_start(%L)$$, jsonb_build_object('context', 'documents', 'signer_ref', test.id('ee_sam'),
  'documents', jsonb_build_array(jsonb_build_object('kind', 'schedule_change', 'ref', test.ee_chg(), 'title', 'Updated Vehicle Schedule', 'sha256', repeat('1', 64))))), 'changed since');
insert into test.ee select 'chg_s', to_jsonb(test.ee_session('documents', test.id('ee_sam'),
  jsonb_build_array(jsonb_build_object('kind', 'schedule_change', 'ref', test.ee_chg(), 'title', 'Updated Vehicle Schedule', 'sha256', test.ee_chg_sha())), null, 'esign/sam/sig.png'));
select test.eq('schedule: the owner initials the updated terms', (select signer_name || '/' || array_to_string(required_initials, ',') from esign_sessions where id = (test.eev('chg_s') #>> '{}')::uuid),
  'Ee Sam/schedule_terms');
select test.lives('schedule: with the session, the owner signs', format($$select public.server_schedule_change_sign(%L, %L)$$, test.id('ee_sam'),
  jsonb_build_object('change_id', test.ee_chg(), 'name', 'whatever the page sent', 'sha256', test.ee_chg_sha(), 'drawn_signature', 'esign/sam/sig.png', 'ip', '203.0.113.4')));
select test.eq('schedule: applied, the name signed is the session''s signer, the session recorded and closed, the facts carry the drawn signature',
  (select c.status || '/' || c.owner_signed_name || '/' || (c.esign_session_id = (test.eev('chg_s') #>> '{}')::uuid) from vehicle_term_changes c where c.id = test.ee_chg())
  || '/' || (select (signed_at is not null)::text from esign_sessions where id = (test.eev('chg_s') #>> '{}')::uuid)
  || '/' || (public.server_schedule_change_signed_facts(test.ee_chg()) ->> 'signature_path'), 'applied/Ee Sam/true/true/esign/sam/sig.png');
select public.server_schedule_change_attach(test.ee_chg(), 'owners/ee/schedule-signed.pdf', test.ee_sha('vs-signed'));
select test.eq('schedule: the signed copy is filed with the new schedule and found on /verify',
  (select (c.document_id is not null and s.document_id = c.document_id)::text from vehicle_term_changes c join vehicle_schedules s on s.id = c.new_schedule_id where c.id = test.ee_chg())
  || '/' || (public.server_verify_sha(test.ee_sha('vs-signed')) ->> 'found'), 'true/true');
select test.eq('schedule: the certificate reads the session', (select jsonb_array_length(c) || '/' || (c #>> '{0,signer_name}') || '/' || ((c #> '{0,initials}') ? 'schedule_terms')::text
  from (select public.server_esign_certificate_sessions(array[(test.eev('chg_s') #>> '{}')::uuid]) c) x), '1/Ee Sam/true');

-- ================================================================ 5. the switch, the rental path, privileges
update program_settings set esign_strict = false;
insert into test.ee select 'sa2', public.door(test.id('ee_admin'), null, 'ops_do', 'sign_request_create', jsonb_build_object('doc_type', 'staff_agreement', 'staff_user_id', test.id('ee_cs'),
  'title', 'VA Agreement, update', 'document', jsonb_build_object('path', 'staff/ee/va2.pdf', 'sha256', test.ee_sha('va2'))));
select test.lives('switch: with esign_strict off (an Admin''s choice), a signature without a session is still recorded',
  format($$select public.sign_request_sign(%L, %L, %L)$$, test.id('ee_cs'), test.eev('sa2') ->> 'id', jsonb_build_object('typed_name', 'Ee Cs', 'consent_text', 'I agree', 'document_sha256', test.ee_sha('va2'))));
update program_settings set esign_strict = true;
select test.throws('rental: a rental agreement session still needs its signer (0154''s path unchanged)',
  $$select public.server_esign_start('{"context": "rental_agreement", "signer_ref": "00000000-0000-0000-0000-000000000000"}')$$, 'Nothing to sign here');
select test.eq('privileges: the new functions are the service role''s only',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('server_esign_start', 'server_esign_certificate_for_request', 'server_esign_certificate_sessions', 'server_schedule_change_signed_facts',
                                                  'server_schedule_change_attach', 'server_verify_sha')
      and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))), 0::bigint);
select test.eq('privileges: the session checks are not callable from a browser',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname in ('esign_start_documents', 'esign_ready_doc', 'esign_mark', 'server_esign_start_pre0193')
      and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))), 0::bigint);
select test.throws('privileges: a browser session cannot start a signing session', $$set local role authenticated; select public.server_esign_start('{}')$$, 'permission denied');

update program_settings set esign_strict = false;
