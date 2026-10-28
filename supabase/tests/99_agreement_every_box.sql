-- 99: every box of the Blind Spot agreement (migration 0178, docs/changes/2026-10-27-agreement-every-box.md): CarmaCars'
-- HST account in box 1, the card coverage provider asked for and filled on the Agreement card, and in the snapshot a
-- version compares. Uses 87's booking test.agb('a') (card coverage).
select test.suite('99 agreement every box');

select test.eq('settings: CarmaCars'' GST/HST account is the default (box 1; the live row is set by the migration)',
  (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'company_hst_number'), '''76339 9177 RT0001''::text');

update coverage_proofs set coverage_provider = null where booking_id = test.agb('a');
select test.eq('missing: card coverage without its provider is listed (recommended: check-out does not wait for it)',
  (select count(*) from jsonb_array_elements(app.agreement_missing(test.agb('a'))) x where x ->> 'key' = 'coverage.coverage_provider' and not (x ->> 'required')::boolean), 1::bigint);
select test.eq('fill: customer service fills the provider on the booking: no longer missing',
  (select count(*) from jsonb_array_elements(public.door(test.id('ag_cs'), null, 'ops_do', 'agreement_fill',
     jsonb_build_object('booking', test.agb('a'), 'coverage', jsonb_build_object('coverage_provider', ' Assurant '))) -> 'missing') x
    where x ->> 'key' = 'coverage.coverage_provider'), 0::bigint);
select test.eq('fill: kept trimmed on the coverage proof', (select coverage_provider from coverage_proofs where booking_id = test.agb('a') order by created_at desc limit 1), 'Assurant');
select test.eq('detail: what boxes 12 and 13 print', public.server_coverage_detail(test.agb('a')) ->> 'coverage_provider', 'Assurant');
select test.eq('snapshot: a version compares the provider (a correction, not material)',
  app.agreement_snapshot(test.agb('a')) #>> '{coverage,provider}', 'Assurant');
select test.eq('privileges: the new functions are the service role''s only',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where ((n.nspname = 'public' and p.proname = 'server_coverage_detail') or (n.nspname = 'app' and p.proname in ('coverage_detail', 'agreement_fill', 'agreement_missing', 'agreement_snapshot')))
      and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))), 0::bigint);

-- 0182: coverage details typed on the Agreement card before any proof was uploaded
delete from coverage_proofs where booking_id = test.agb('a');
select public.door(test.id('ag_cs'), null, 'ops_do', 'agreement_fill',
  jsonb_build_object('booking', test.agb('a'), 'coverage', jsonb_build_object('insurer_name', 'Allstate', 'policy_number', 'P-123', 'policy_expiry', '2027-05-01')));
select test.eq('fill without proof: a submitted coverage proof is created with the details (no document, not confirmed)',
  (select status || '/' || policy_number || '/' || (proof_document_id is null)::text from coverage_proofs where booking_id = test.agb('a')), 'submitted/P-123/true');
select test.ok('fill without proof: the audit log records who entered it',
  exists (select 1 from audit_log where action = 'coverage_entered_without_proof' and entity_id = test.agb('a')::text));

-- 0183: the insurer and adjuster at any status, staff uploads, the whole agreement editable
insert into insurers (name) values ('0183 Test Insurer') on conflict do nothing;
select test.eq('insurer: customer service records the claim and adjuster on a booking at any status',
  public.door(test.id('ag_cs'), null, 'ops_do', 'booking_insurer_save', jsonb_build_object('booking', test.agb('a'), 'bill_to', 'insurer',
    'insurer_id', (select id from insurers where name = '0183 Test Insurer'), 'claim_number', 'CL-9', 'adjuster_name', 'Ada Adjuster', 'adjuster_email', 'ada@ins.example.test')) ->> 'bill_to', 'insurer');
select test.eq('insurer: kept on the booking', (select insurer_claim_number || '/' || insurer_adjuster_name from bookings where id = test.agb('a')), 'CL-9/Ada Adjuster');
select test.throws('insurer: billing an insurer needs the insurer', format($$select public.door(%L, null, 'ops_do', 'booking_insurer_save', jsonb_build_object('booking', %L, 'bill_to', 'insurer', 'insurer_id', ''))$$,
  test.id('ag_cs'), test.agb('a')), 'Choose the insurer');
select test.throws('insurer: a bad adjuster email is refused', format($$select public.door(%L, null, 'ops_do', 'booking_insurer_save', jsonb_build_object('booking', %L, 'adjuster_email', 'nope'))$$,
  test.id('ag_cs'), test.agb('a')), '%adjuster%email%');
select public.door(test.id('ag_cs'), null, 'ops_do', 'booking_insurer_save', jsonb_build_object('booking', test.agb('a'), 'bill_to', 'renter'));
select test.ok('insurer: each save is in the audit log', (select count(*) >= 2 from audit_log where action = 'booking_insurer_save' and entity_id = test.agb('a')::text));

select test.ok('upload: staff upload the insurance policy; it is linked to the coverage record',
  (public.door(test.id('ag_cs'), null, 'ops_do', 'staff_document_register', jsonb_build_object('booking', test.agb('a'), 'kind', 'coverage_proof',
     'path', 'staff/x/coverage_proof-1.pdf', 'mime', 'application/pdf', 'sha256', repeat('b', 64))) ->> 'document_id') is not null
  and exists (select 1 from verification_uploads u join coverage_proofs c on c.id = u.coverage_proof_id where u.booking_id = test.agb('a') and u.kind = 'coverage_proof' and u.uploaded_by = test.id('ag_cs')));
select test.ok('upload: an insurer letter is kept on the booking',
  (public.door(test.id('ag_cs'), null, 'ops_do', 'staff_document_register', jsonb_build_object('booking', test.agb('a'), 'kind', 'insurer_document', 'path', 'staff/x/insurer-1.pdf')) ->> 'ok')::boolean);
select test.throws('upload: an unknown kind is refused', format($$select public.door(%L, null, 'ops_do', 'staff_document_register', jsonb_build_object('booking', %L, 'kind', 'selfie', 'path', 'x'))$$,
  test.id('ag_cs'), test.agb('a')), 'Choose what the document is');

select test.ok('edit: the Agreement card has every printed field with its value',
  (app.agreement_state(test.id('ag_cs'), test.agb('a')) #> '{current,renter}') ? 'legal_name' and jsonb_array_length(app.agreement_state(test.id('ag_cs'), test.agb('a')) #> '{current,drivers}') >= 1);
select test.throws('edit: only an Admin corrects the legal name', format($$select public.door(%L, null, 'ops_do', 'agreement_fill', jsonb_build_object('booking', %L, 'renter', jsonb_build_object('legal_name', 'New Name')))$$,
  test.id('ag_cs'), test.agb('a')), '%Admin%legal name%');
select test.throws('esign: a corrected number must be a Canadian or US mobile', $$select public.server_esign_set_mobile(gen_random_uuid(), '555', null)$$, 'Enter a Canadian or US mobile number');
select test.throws('esign: no session, nothing to correct', $$select public.server_esign_set_mobile(gen_random_uuid(), '+14165550123', null)$$, '%signing has ended%');
