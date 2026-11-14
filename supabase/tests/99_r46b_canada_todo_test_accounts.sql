-- 99: migration 2880 (release 46, part B): a test account (the live checks' "Verify Invitation") never needs the Canadian
-- terms: not in the badge of the Admin list, not counted by the To do's closing rule. Fixtures "cta"; example.test and the
-- invitation check's +verify- address form only.
select test.suite('99 r46b Canada To do leaves out test accounts (2880)');

select test.mk_user('cta_admin', 'admin');
select test.mk_user('cta_real', 'va', 'cs');   -- in Canada, signed with the old terms
select test.mk_user('cta_test', 'va', 'sales'); -- the same, but a test account
update users set email = 'delivered+verify-cta-invite@resend.dev', full_name = 'Verify Invitation' where id = test.id('cta_test');
update staff_profiles set location_country = 'CA', location_city = 'Toronto' where user_id in (test.id('cta_real'), test.id('cta_test'));

create function pg_temp.send(p_user text, p_country text, p_currency text, p_platform text, p_reissue boolean default false) returns jsonb language sql as $$
  select app.sign_request_create(test.id('cta_admin'), jsonb_build_object('doc_type', 'staff_agreement', 'staff_user_id', test.id(p_user), 'title', 'Staff agreement',
    'document', jsonb_build_object('path', 'staff/' || test.id(p_user) || '/to-sign/' || md5(p_user || p_country || clock_timestamp()::text) || '.pdf', 'sha256', md5(p_user || clock_timestamp()::text) || md5(p_country)),
    'extra', jsonb_build_object('generated', true, 'reissue', p_reissue, 'values', jsonb_build_object('country', p_country, 'currency', p_currency, 'platform', p_platform)))) $$;
update sign_requests set status = 'signed', signed_at = now(), method = 'typed' where id = (pg_temp.send('cta_real', 'Philippines', 'USD', 'OnlineJobs.ph') ->> 'id')::uuid;
update sign_requests set status = 'signed', signed_at = now(), method = 'typed' where id = (pg_temp.send('cta_test', 'Philippines', 'USD', 'OnlineJobs.ph') ->> 'id')::uuid;

select test.ok('the test account is a test account', app.staff_is_test(test.id('cta_test')));
select test.ok('the real one needs the Canadian terms', app.staff_agreement_needs_canada(test.id('cta_real')));
select test.ok('the test account does not', not app.staff_agreement_needs_canada(test.id('cta_test')));
select test.ok('the Admin list badges the real one only', (select bool_and((x ->> 'needs_canada_terms')::boolean = (x ->> 'user_id' = test.id('cta_real')::text))
  from jsonb_array_elements(app.door(test.id('cta_admin'), 'aal2', 'ops_read', 'staff_agreements', '{}'::jsonb)) x where x ->> 'user_id' in (test.id('cta_real')::text, test.id('cta_test')::text)));

-- the To do closes once the real one has a new agreement, though the test account still has the old terms
update tasks set status = 'done' where task_type = 'staff_agreement_canada' and status in ('open', 'in_progress', 'waiting');
select app.raise_task(p_type => 'staff_agreement_canada', p_queue => 'admin', p_title => 'Send 2 staff in Canada a new agreement', p_dedupe => 'staff_agreement_canada:cta');
select pg_temp.send('cta_real', 'Canada', 'CAD', 'Interac e-Transfer or direct deposit', true);
select test.ok('the To do closes when only a test account is left', not exists (select 1 from tasks where task_type = 'staff_agreement_canada' and status = 'open'));
