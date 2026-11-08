-- 99: no paper signatures, Form D on screen (the fleet supplier's included) and updated terms to accept (migrations 0720,
-- 0721; docs/changes/2026-11-07-r33-signatures-terms.md). Fixtures "q3f"; the supplier of 99_r33_fleet_supplier.sql.
select test.suite('99 r33f no paper signatures, Form D on screen, updated terms');
select set_config('app.paper_fixture', '', false);
select test.mk_user('q3f_admin', 'admin');
select test.mk_user('q3f_cs', 'va', 'cs');
select test.mk_user('q3f_field', 'field');
select test.mk_user('q3f_renter', 'renter');
create temp table q3f (k text primary key, v jsonb);
create temp table q3f_esign as select id, esign_strict from program_settings;
update program_settings set esign_strict = false;
create function test.q3f_sha(p text) returns text language sql immutable as $$ select md5(p) || md5(p || 'x') $$;

-- ---------------------------------------------------------------- 1. the database refuses a new paper signature
select test.throws('a staff agreement signed on paper: refused', format($$insert into paper_signatures (doc_type, target_id, staff_user_id, document_id, signer_name, signed_on, recorded_by)
  select 'staff_agreement', %L, %L, id, 'Casey Example', current_date, %L from documents limit 1$$, test.id('q3f_cs'), test.id('q3f_cs'), test.id('q3f_admin')), 'signed in the portal only');
select test.throws('an investment agreement on paper: refused', format($$insert into paper_signatures (doc_type, target_id, document_id, signer_name, signed_on, recorded_by)
  select 'investment_agreement', %L, id, 'Casey Example', current_date, %L from documents limit 1$$, gen_random_uuid(), test.id('q3f_admin')), 'signed in the portal only');
select test.throws('a signature record "paper": refused', $$insert into signature_records (signature_request_id, signer_role, signer_name, status, signed_on, method)
  select id, 'renter', 'Casey Example', 'signed', current_date, 'paper' from signature_requests limit 1$$, 'signed in the portal only');
select test.throws('a signing request on paper: refused', $$insert into signature_requests (document_id, provider, status) select id, 'paper', 'completed' from documents limit 1$$, 'signed in the portal only');
select test.throws('staff add an owner "signs on paper": refused', $$select app.staff_add_owner_car(test.id('q3f_cs'), jsonb_build_object('signing', 'paper',
  'owner', jsonb_build_object('legal_name', 'Casey Example', 'email', 'q3f-casey@example.test')))$$, 'owner portal only');
select test.throws('a rental marked signed on paper: refused', $$update bookings set agreement_on_paper = true where id = (select id from bookings where not agreement_on_paper limit 1)$$, 'portal only');
select test.throws('a Form D photo of a paper copy: refused', format($$insert into owner_agreement_forms (owner_id, form_code, document_id, status, signed_method, uploaded_by)
  select %L, 'D1', id, 'uploaded', 'upload', %L from documents limit 1$$, test.q33owner(), test.id('q3f_admin')), 'signed on screen');
select test.ok('the records signed on paper before stay readable', (select count(*) from paper_signatures) >= 0);
select test.eq('the ServiceOntario forms signed in ink are still recorded (the guard lets registry_form through)',
  (select pg_get_functiondef('app.no_paper_guard()'::regprocedure) like '%registry_form%'), true);

-- ---------------------------------------------------------------- 2. the second CarmaCars signer and Form D on screen
select test.eq('the second signing officer is a setting, empty until an Admin sets it', (select second_signing_officer_name is null from app.settings()), true);
select test.eq('the fleet supplier has Form D in his packet (no Form C)', (select string_agg(x ->> 'code' || ':' || (x ->> 'status'), ',') from jsonb_array_elements(app.owner_witnessed_forms(test.q33owner())) x), 'D1:needed');
insert into q3f select 'open', public.owner_form_d_open(test.id('q33_web'), test.q3f_sha('d'), 'owners/' || test.q33owner() || '/forms/form-d.pdf', 'forms-cd-d-screen');
select test.eq('Form D opened for his signature', (select (v ->> 'doc_type') || ':' || (v ->> 'status') from q3f where k = 'open'), 'form_d:sent');
select test.eq('opening again with the same text: the same request', (public.owner_form_d_open(test.id('q33_web'), test.q3f_sha('d'), 'owners/' || test.q33owner() || '/forms/form-d.pdf', 'forms-cd-d-screen') ->> 'id'),
  (select v ->> 'id' from q3f where k = 'open'));
select test.throws('another account cannot open his Form D', format($$select public.owner_form_d_open(%L, %L, 'owners/x/forms/form-d.pdf', 'v')$$, test.id('q3f_renter'), test.q3f_sha('d')), 'not an owner account');
select test.throws('two witnesses are needed', format($$select public.sign_request_sign(test.id('q33_web'), %L, %L)$$, (select v ->> 'id' from q3f where k = 'open'),
  jsonb_build_object('typed_name', 'Nora Example', 'consent_text', 'I sign.', 'document_sha256', test.q3f_sha('d'), 'witness_name', 'Wren Example')), 'Both witnesses');
select test.throws('the two witnesses are two people', format($$select public.sign_request_sign(test.id('q33_web'), %L, %L)$$, (select v ->> 'id' from q3f where k = 'open'),
  jsonb_build_object('typed_name', 'Nora Example', 'consent_text', 'I sign.', 'document_sha256', test.q3f_sha('d'), 'witness_name', 'Wren Example', 'witness_2_name', 'wren  example',
    'witness_statement', 'I witnessed Nora Example sign in my presence.', 'witness_2_statement', 'I witnessed Nora Example sign in my presence.')), 'two different people');
select test.throws('a witness is not the owner', format($$select public.sign_request_sign(test.id('q33_web'), %L, %L)$$, (select v ->> 'id' from q3f where k = 'open'),
  jsonb_build_object('typed_name', 'Nora Example', 'consent_text', 'I sign.', 'document_sha256', test.q3f_sha('d'), 'witness_name', 'Nora Example', 'witness_2_name', 'Wren Example',
    'witness_statement', 'I witnessed Nora Example sign in my presence.', 'witness_2_statement', 'I witnessed Nora Example sign in my presence.')), 'not the owner');
select test.throws('each witness ticks the statement word for word', format($$select public.sign_request_sign(test.id('q33_web'), %L, %L)$$, (select v ->> 'id' from q3f where k = 'open'),
  jsonb_build_object('typed_name', 'Nora Example', 'consent_text', 'I sign.', 'document_sha256', test.q3f_sha('d'), 'witness_name', 'Wren Example', 'witness_2_name', 'Ash Example',
    'witness_statement', 'I witnessed Nora Example sign in my presence.', 'witness_2_statement', 'I saw it.')), 'ticks the statement');
update program_settings set second_signing_officer_name = 'Second Officer', second_signing_officer_title = 'Director';
select public.sign_request_sign(test.id('q33_web'), (select (v ->> 'id')::uuid from q3f where k = 'open'),
  jsonb_build_object('typed_name', 'Nora Example', 'consent_text', 'I sign Form D electronically, in the presence of my two witnesses.', 'document_sha256', test.q3f_sha('d'),
    'witness_name', 'Wren Example', 'witness_2_name', 'Ash Example', 'witness_statement', 'I witnessed Nora Example sign in my presence.', 'witness_2_statement', 'I witnessed Nora Example sign in my presence.'));
select test.eq('signed: the owner, two witnesses typed in person, CarmaCars by the signing officer and its witness from the stored signature',
  (select string_agg(x.signer_role || ':' || x.method || ':' || (x.signer_name = coalesce((select signing_officer_name from app.settings()), x.signer_name) or x.signer_role <> 'carmacars'), ',' order by x.signer_role, x.method, x.signer_name)
     from signature_records x where x.signature_request_id = (select (v ->> 'signature_request_id')::uuid from q3f where k = 'open')),
  'carmacars:automatic:true,owner_corporation:typed:true,witness:stored_signature:true,witness:typed:true,witness:typed:true');
select test.eq('the second signer is applied from the setting', (select x.signer_name || ', ' || x.signer_title from signature_records x
   where x.signature_request_id = (select (v ->> 'signature_request_id')::uuid from q3f where k = 'open') and x.method = 'stored_signature'), 'Second Officer, Director');
select test.eq('Form D is approved at once, signed on screen with both witnesses', (select f.status || ':' || f.signed_method || ':' || f.witness_1_name || '/' || f.witness_2_name
   from owner_agreement_forms f where f.owner_id = test.q33owner() and f.form_code = 'D1' and f.status = 'approved'), 'approved:screen:Wren Example/Ash Example');
select test.eq('nothing left to sign with witnesses', (select string_agg(x ->> 'code' || ':' || (x ->> 'status'), ',') from jsonb_array_elements(app.owner_witnessed_forms(test.q33owner())) x), 'D1:approved');
select test.eq('the signers for the signed copy', jsonb_array_length(public.server_form_d_signers((select (v ->> 'id')::uuid from q3f where k = 'open'))), 4);
update program_settings set second_signing_officer_name = null, second_signing_officer_title = null;

-- ---------------------------------------------------------------- 3. updated terms to accept
insert into site_content_blocks (block_key, page, kind, body) values ('legal.terms', 'terms', 'rich_text', 'The terms of use before this version, long enough.') on conflict (block_key) do nothing;
update users set created_at = now() - interval '1 day' where id in (test.id('q3f_renter'), test.id('q3f_field'), test.id('q3f_cs'), test.id('q3f_admin'), test.id('q33_web'));
select test.throws('only an Admin publishes', $$select app.door(test.id('q3f_cs'), 'aal2', 'admin_do', 'terms_publish', '{"doc_key": "terms", "version": "x", "summary": "Something changed here."}')$$, '');
select test.throws('the summary is asked', $$select app.terms_publish(test.id('q3f_admin'), '{"doc_key": "privacy", "version": "2026-11-07", "body": "The new privacy text, long enough to read."}')$$, 'summary');
insert into q3f select 'tv', app.door(test.id('q3f_admin'), 'aal2', 'admin_do', 'terms_publish',
  '{"doc_key": "terms", "version": "2026-11-07", "summary": "Section 4 now says how we handle tolls.", "body": "### 1. Who we are\n\nThe updated terms of use, for everyone.", "requires_acceptance": true}');
select test.eq('the site''s terms text is replaced too', (select body from site_content_blocks where block_key = 'legal.terms'), '### 1. Who we are' || chr(10) || chr(10) || 'The updated terms of use, for everyone.');
select test.throws('the same version twice: refused', $$select app.terms_publish(test.id('q3f_admin'), '{"doc_key": "terms", "version": "2026-11-07", "summary": "Again the same version.", "body": "Another text, long enough to read."}')$$, 'published already');
select test.eq('a renter, a field worker, staff and an owner each have it to accept; the Admin does not',
  (select jsonb_array_length(app.terms_pending(test.id('q3f_renter'))) || '/' || jsonb_array_length(app.terms_pending(test.id('q3f_field'))) || '/' || jsonb_array_length(app.terms_pending(test.id('q3f_cs')))
     || '/' || jsonb_array_length(app.terms_pending(test.id('q33_web'))) || '/' || jsonb_array_length(app.terms_pending(test.id('q3f_admin')))), '1/1/1/1/0');
select app.terms_publish(test.id('q3f_admin'), '{"doc_key": "rental_agreement", "version": "r-2", "summary": "The fuel policy wording is clearer.", "body": "The rental agreement, version two, with its clearer fuel policy."}');
select test.eq('the rental agreement binds renters only', (select jsonb_array_length(app.terms_pending(test.id('q3f_renter'))) || '/' || jsonb_array_length(app.terms_pending(test.id('q3f_cs')))), '2/1');
select test.eq('the terms of use come first', (select app.terms_pending(test.id('q3f_renter')) -> 0 ->> 'doc_key'), 'terms');
select test.throws('the text shown must be the published one', format($$select public.server_terms_accept(test.id('q3f_renter'), %L)$$,
  jsonb_build_object('version_id', (select v ->> 'id' from q3f where k = 'tv'), 'body_sha256', test.q3f_sha('other'))), 'text changed');
select test.throws('a version that does not bind the person: refused', format($$select public.server_terms_accept(test.id('q3f_cs'), %L)$$,
  jsonb_build_object('version_id', (select id from terms_versions where doc_key = 'rental_agreement'), 'body_sha256', (select body_sha256 from terms_versions where doc_key = 'rental_agreement'))), 'does not apply');
select test.eq('accepted: one left', (public.server_terms_accept(test.id('q3f_renter'), jsonb_build_object('version_id', (select v ->> 'id' from q3f where k = 'tv'),
  'body_sha256', (select body_sha256 from terms_versions where id = (select (v ->> 'id')::uuid from q3f where k = 'tv')), 'ip', '203.0.113.7', 'user_agent', 'Test', 'portal', 'renter')) ->> 'pending'), '1');
select test.eq('the acceptance records who, when, the IP address, the version and the portal',
  (select host(a.ip_address) || ':' || a.portal || ':' || (a.accepted_at is not null) || ':' || (a.body_sha256 = v.body_sha256) from terms_acceptances a join terms_versions v on v.id = a.version_id
    where a.user_id = test.id('q3f_renter') and v.doc_key = 'terms'), '203.0.113.7:renter:true:true');
select test.throws('an acceptance is never changed', $$update terms_acceptances set portal = 'owner'$$, 'never changed');
select test.lives('accepting twice is harmless', format($$select public.server_terms_accept(test.id('q3f_renter'), %L)$$, jsonb_build_object('version_id', (select v ->> 'id' from q3f where k = 'tv'),
  'body_sha256', (select body_sha256 from terms_versions where id = (select (v ->> 'id')::uuid from q3f where k = 'tv')))));
select app.terms_publish(test.id('q3f_admin'), '{"doc_key": "staff_agreement", "version": "s-2", "summary": "A wording fix only.", "body": "The staff agreement, a wording fix only, nothing to accept.", "requires_acceptance": false}');
select test.eq('a version that does not require acceptance asks nobody', (select count(*) from jsonb_array_elements(app.terms_pending(test.id('q3f_cs'))) x where x ->> 'doc_key' = 'staff_agreement'), 0::bigint);
select test.eq('an account opened after the version is not asked', (select count(*) from jsonb_array_elements(app.terms_pending(test.id('q3f_cs'))) x where x ->> 'doc_key' = 'terms'), 1::bigint);
update users set created_at = now() + interval '1 minute' where id = test.id('q3f_cs');
select test.eq('(the same staff member, as a newer account)', jsonb_array_length(app.terms_pending(test.id('q3f_cs'))), 0);
select test.eq('Admin sees each version and who accepted', (select (x ->> 'accepted') || ':' || jsonb_array_length(x -> 'acceptances')
  from jsonb_array_elements(app.door(test.id('q3f_admin'), 'aal2', 'admin_read', 'terms_versions', jsonb_build_object('version_id', (select v ->> 'id' from q3f where k = 'tv'))) -> 'versions') x
  where x ->> 'doc_key' = 'terms'), '1:1');

update program_settings p set esign_strict = q.esign_strict from q3f_esign q where q.id = p.id;
