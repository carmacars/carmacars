-- 99: migration 0790 (release 33, part M): asked to record an agreement signed on paper, the database answers with the
-- refusal of 0720 first (not "Upload the scan"), after the check of who may record it. Fixtures "q3m"; example.test only.
select test.suite('99 r33m paper refused first (0790)');
select set_config('app.paper_fixture', '', false);
select test.mk_user('q3m_admin', 'admin');
select test.mk_user('q3m_cs', 'va', 'cs');
select test.mk_owner('q3m_o');

select test.throws('an owner''s debit agreement on paper, no scan: refused with the reason, not "Upload the scan"',
  format($$select app.record_paper_signature(%L, jsonb_build_object('doc_type', 'debit_agreement', 'target_id', %L, 'signer_name', 'Pat Example', 'signed_on', current_date))$$,
    test.id('q3m_admin'), test.id('owner:q3m_o')), 'signed in the portal only');
select test.throws('with a scan: refused the same way',
  format($$select app.record_paper_signature(%L, jsonb_build_object('doc_type', 'owner_agreement', 'target_id', %L, 'signer_name', 'Pat Example', 'signed_on', current_date,
    'scan', jsonb_build_object('path', 'paper/q3m.pdf', 'sha256', repeat('a', 64))))$$, test.id('q3m_admin'), test.id('owner:q3m_o')), 'signed in the portal only');
select test.throws('a rental agreement on paper: refused', format($$select app.record_paper_signature(%L, '{"doc_type": "rental_agreement", "target_id": "%s", "signer_name": "Pat Example", "signed_on": "2026-11-01"}')$$,
  test.id('q3m_cs'), gen_random_uuid()), 'signed in the portal only');
select test.throws('who may record is still checked first: customer service and an owner''s agreement',
  format($$select app.record_paper_signature(%L, jsonb_build_object('doc_type', 'debit_agreement', 'target_id', %L, 'signer_name', 'Pat Example', 'signed_on', current_date))$$,
    test.id('q3m_cs'), test.id('owner:q3m_o')), 'Admin');
select test.throws('signed out: refused', $$select app.record_paper_signature(null, '{"doc_type": "debit_agreement"}')$$, 'Sign in first');
select test.eq('nothing recorded', (select count(*) from paper_signatures where owner_id = test.id('owner:q3m_o'))::int, 0);
select test.eq('the website and the signed-in roles cannot call it', has_function_privilege('authenticated', 'app.record_paper_signature(uuid, jsonb)', 'execute')
  or has_function_privilege('anon', 'app.record_paper_signature(uuid, jsonb)', 'execute'), false);
