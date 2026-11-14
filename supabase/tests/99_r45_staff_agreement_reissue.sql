-- 99: migration 2862 (release 45): "Send a new agreement" for a staff agreement already sent or signed. Who in Canada
-- still has terms that are not Canadian; a new agreement voids the one waiting and keeps the signed one on file as
-- superseded (the portal stays open); the Admin list says so; the one-time To do closes when nobody is left.
-- Fixtures "sar"; example.test only.
select test.suite('99 r45 staff agreement reissue (2862)');

select test.mk_user('sar_admin', 'admin');
select test.mk_user('sar_ca', 'va', 'sales');   -- in Canada, agreement waiting with the old terms
select test.mk_user('sar_cb', 'va', 'cs');      -- in Canada, signed with the old terms
select test.mk_user('sar_cc', 'va', 'cs');      -- in Canada, signed with Canadian terms
select test.mk_user('sar_ph', 'va', 'cs');      -- in the Philippines, the old terms are right
update staff_profiles set location_country = 'CA', location_city = 'Toronto' where user_id in (test.id('sar_ca'), test.id('sar_cb'), test.id('sar_cc'));
update staff_profiles set location_country = 'PH', location_city = 'Manila' where user_id = test.id('sar_ph');

create function pg_temp.send(p_user text, p_country text, p_currency text, p_platform text, p_reissue boolean default false) returns jsonb language sql as $$
  select app.sign_request_create(test.id('sar_admin'), jsonb_build_object('doc_type', 'staff_agreement', 'staff_user_id', test.id(p_user), 'title', 'Staff agreement',
    'document', jsonb_build_object('path', 'staff/' || test.id(p_user) || '/to-sign/' || md5(p_user || p_country || clock_timestamp()::text) || '.pdf', 'sha256', md5(p_user || clock_timestamp()::text) || md5(p_country)),
    'extra', jsonb_build_object('generated', true, 'reissue', p_reissue, 'values', jsonb_build_object('country', p_country, 'currency', p_currency, 'platform', p_platform)))) $$;
create function pg_temp.sign(p_id uuid) returns void language sql as $$
  update sign_requests set status = 'signed', signed_at = now(), method = 'typed' where id = p_id $$;

select pg_temp.send('sar_ca', 'Philippines', 'USD', 'OnlineJobs.ph');
select pg_temp.sign((pg_temp.send('sar_cb', 'Philippines', 'USD', 'OnlineJobs.ph') ->> 'id')::uuid);
select pg_temp.sign((pg_temp.send('sar_cc', 'Canada', 'CAD', 'Interac e-Transfer or direct deposit') ->> 'id')::uuid);
select pg_temp.send('sar_ph', 'Philippines', 'USD', 'OnlineJobs.ph');

select test.eq('who needs Canadian terms: the ones in Canada with the old terms, waiting or signed',
  (select string_agg(replace(u.email, '@example.test', ''), ',' order by u.email) from users u where u.email like 'sar\_%' escape '\' and app.staff_agreement_needs_canada(u.id)), 'sar_ca,sar_cb');
select test.ok('an uploaded PDF records no terms: not counted', app.staff_terms_canadian('{}'::jsonb) is null);
select test.ok('the Admin list says it', (select bool_and((x ->> 'needs_canada_terms')::boolean = (x ->> 'email' in ('sar_ca@example.test', 'sar_cb@example.test')))
  from jsonb_array_elements(app.door(test.id('sar_admin'), 'aal2', 'ops_read', 'staff_agreements', '{}'::jsonb)) x where x ->> 'email' like 'sar\_%' escape '\'));

-- the one-time To do (the migration made it for the people of the live database)
select app.raise_task(p_type => 'staff_agreement_canada', p_queue => 'admin', p_title => 'Send 2 staff in Canada a new agreement', p_dedupe => 'staff_agreement_canada:test');

-- signed: a new agreement keeps the signed one, superseded
create temp table sar_new as select (pg_temp.send('sar_cb', 'Canada', 'CAD', 'Interac e-Transfer or direct deposit', true) ->> 'id')::uuid id;
select test.ok('the signed one stays on file, signed and superseded by the new one',
  exists (select 1 from sign_requests s, sar_new n where s.staff_user_id = test.id('sar_cb') and s.status = 'signed' and s.superseded_by = n.id and s.superseded_at is not null));
select test.ok('their portal stays open until they sign the new one', app.staff_agreement_signed(test.id('sar_cb')));
select test.ok('the new one waits for their signature', (select status from sign_requests s, sar_new n where s.id = n.id) = 'sent');
select test.ok('they no longer need Canadian terms', not app.staff_agreement_needs_canada(test.id('sar_cb')));
select test.ok('the Admin list shows the superseded one', (select x -> 'superseded' ->> 'id' is not null
  from jsonb_array_elements(app.door(test.id('sar_admin'), 'aal2', 'ops_read', 'staff_agreements', '{}'::jsonb)) x where x ->> 'email' = 'sar_cb@example.test'));
select test.ok('the To do stays while someone is left', exists (select 1 from tasks where task_type = 'staff_agreement_canada' and status = 'open'));
select test.ok('it is in the audit log', exists (select 1 from audit_log a, sar_new n where a.action = 'staff_agreement_reissued' and a.entity_id = n.id::text));

-- waiting: the old one is voided
select pg_temp.send('sar_ca', 'Canada', 'CAD', 'Interac e-Transfer or direct deposit', true);
select test.eq('the one waiting with the old terms is voided', (select string_agg(status || ':' || coalesce(void_reason, ''), ',' order by sent_at) from sign_requests where staff_user_id = test.id('sar_ca')),
  'voided:A new version was sent,sent:');
select test.ok('the To do closes when nobody is left', not exists (select 1 from tasks where task_type = 'staff_agreement_canada' and status = 'open'));

select test.throws('only an Admin sends one', $$ select app.sign_request_create(test.id('sar_ca'), jsonb_build_object('doc_type', 'staff_agreement', 'staff_user_id', test.id('sar_cc'),
  'document', jsonb_build_object('path', 'staff/x.pdf', 'sha256', repeat('a', 64)), 'extra', jsonb_build_object('reissue', true))) $$, null);
