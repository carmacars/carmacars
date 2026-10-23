-- 80: the second rental agreement (migration 0127, docs/changes/2026-10-23-second-rental-agreement.md). Blind Spot Car
-- Rental's agreement as a form of Admin > Settings > Forms filled for every booking: uploaded and checked by an Admin,
-- opened beside the rental agreement, signed with the same one signature (its SHA-256 checked), its signed copy stored
-- once the rental agreement is countersigned and carried by the renter's email. The facts it needs (the mailing address
-- in its parts, the HST number, the insurer of an insurance replacement rental), and Admin > Today until it is set up.
-- Fixtures start with "ra2" (and "RA2" for the car).
select test.suite('80 second rental agreement');
grant usage on schema test to service_role;
grant execute on all functions in schema test to authenticated, anon, service_role;

select test.mk_owner('ra2_one');
select test.mk_vehicle('RA2', 'ra2_one');
insert into vehicle_listings (vehicle_id, slug, headline, status, home_area) values (test.id('vehicle:RA2'), 'ra2-test', 'Second agreement test car', 'published', 'Leslieville');
select test.mk_user('ra2_cs', 'va', 'cs');
select test.mk_user('ra2_admin', 'admin');
create function test.ra2_req(p_key text, p_email text, p_name text, p_days integer) returns jsonb language sql stable as $$
  select jsonb_build_object(
    'request_key', 'ra2-key-' || p_key, 'vehicle_id', test.id('vehicle:RA2'),
    'pickup_at', date_trunc('day', now() + make_interval(days => p_days)) + interval '15 hours',
    'return_at', date_trunc('day', now() + make_interval(days => p_days + 3)) + interval '15 hours',
    'booking_type', 'standard', 'coverage_option', 2,
    'renter', jsonb_build_object('full_name', p_name, 'date_of_birth', '1990-05-05', 'email', p_email, 'mobile', '416-555-0142', 'licence_class', 'G', 'licence_issuer', 'ON'),
    'consents', jsonb_build_object('terms', jsonb_build_object('accepted', true, 'version', 't', 'text', 'I agree.'),
                                   'privacy', jsonb_build_object('accepted', true, 'version', 'p', 'text', 'I agree.')))
$$;
create table test.ra2 (k text primary key, v uuid);
insert into test.ra2 select 'a', (app.submit_booking_request(test.ra2_req('a', 'ana.ra2@example.test', 'Ana Second', 50)) ->> 'booking_id')::uuid;
insert into test.ra2 select 'b', (app.submit_booking_request(test.ra2_req('b', 'bo.ra2@example.test', 'Bo Second', 60)) ->> 'booking_id')::uuid;
grant select on test.ra2 to authenticated, service_role;
create function test.ra2b(p text) returns uuid language sql stable as $$ select v from test.ra2 where k = p $$;
create function test.ra2u(p text) returns uuid language sql stable security definer as $$
  select r.user_id from public.bookings b join public.renters r on r.id = b.renter_id where b.id = test.ra2b(p) $$;
create function test.ra2_consents() returns jsonb language sql immutable as $$
  select '[{"code":"tracking_disabling","version":"v","text":"t"},{"code":"identity_verification","version":"v","text":"t"},{"code":"electronic_signature","version":"v","text":"t"},{"code":"card_authorization","version":"v","text":"t"}]'::jsonb $$;

select app.send_offer(test.ra2b('a'), test.id('ra2_cs'));
select public.renter_approve_offer(test.ra2b('a'), 1, test.ra2u('a'));
select public.renter_open_agreement(test.ra2b('a'), test.ra2u('a'), 'rental-test', repeat('a', 64), 'bookings/a/x.pdf');
-- b is an insurance replacement rental (billed to the insurer)
insert into insurers (id, name) values (test.id('insurer:ra2'), 'Example Mutual');
update bookings set bill_to = 'insurer', insurer_id = test.id('insurer:ra2'), insurer_claim_number = 'CLM-1', insurer_adjuster_name = 'Pat Adjuster', insurer_authorized_days = 3
 where id = test.ra2b('b');
select app.send_offer(test.ra2b('b'), test.id('ra2_cs'));
select public.renter_approve_offer(test.ra2b('b'), 1, test.ra2u('b'));
select public.renter_open_agreement(test.ra2b('b'), test.ra2u('b'), 'rental-test', repeat('d', 64), 'bookings/b/x.pdf');

-- ---------------------------------------------------------------- 1. the template, before it is in use
update program_settings set company_hst_number = null where id = (select id from app.settings());
update site_settings set mailing_address = '2967 Dundas St W, Unit 208B, Toronto, ON M6P 1Z2' where singleton;
select test.eq('the form is there from the start, without its PDF, unchecked',
  (select count(*) || '/' || bool_and(file_key is null) || '/' || bool_and(not verified) || '/' || min(kind) from pdf_templates where form_code = 'BLINDSPOT-RA'), '1/true/true/booking_overlay');
select test.eq('the representative: Ahmad, written in a script hand until an image is uploaded',
  (select rep_name || '/' || (signature_key is null) from rental_form_settings where form_code = 'BLINDSPOT-RA'), 'Ahmad/true');
select test.eq('no template in use: nothing to fill', public.server_blindspot_facts(test.ra2b('a'), test.ra2u('a')) -> 'template', 'null'::jsonb);
select test.throws('no template in use: no second agreement is opened',
  $$select public.server_open_agreement_companion(test.ra2b('a'), test.ra2u('a'), (select id from pdf_templates where form_code = 'BLINDSPOT-RA'), 'bookings/' || test.ra2b('a') || '/blindspot-1.pdf', repeat('1', 64))$$, 'not in use');
select test.ok('Admin > Today: the HST number to enter, and the PDF to upload',
  (select count(*) = 2 from jsonb_array_elements(app.site_setup_problems()) x where x ->> 'field' in ('company_hst_number', 'rental_form')));
select test.eq('Admin > Today: each links to its settings',
  (select string_agg(x ->> 'href', ',' order by x ->> 'href') from jsonb_array_elements(app.site_setup_problems()) x where x ->> 'field' in ('company_hst_number', 'rental_form')),
  '/admin/settings/forms,/admin/settings/program');

-- ---------------------------------------------------------------- 2. Admin > Settings > Forms
select test.eq('Forms: the registry forms'' list leaves it out; it has its own card',
  (select (select count(*) from jsonb_array_elements(app.form_templates(test.id('ra2_admin')) -> 'forms') f where f ->> 'form_code' = 'BLINDSPOT-RA')
          || '/' || (app.form_templates(test.id('ra2_admin')) #>> '{rental_forms,0,form_code}') || '/' || (app.form_templates(test.id('ra2_admin')) #>> '{rental_forms,0,rep,name}')), '0/BLINDSPOT-RA/Ahmad');
select test.throws('Forms: only Admins upload it',
  $$select app.door(test.id('ra2_cs'), 'aal2', 'ops_do', 'rental_form_upload', ('{"form_code":"BLINDSPOT-RA","file_key":"forms/templates/BLINDSPOT-RA/x.pdf","sha256":"' || repeat('e', 64) || '"}')::jsonb)$$, null);
select test.throws('Forms: a file outside the form''s folder is refused',
  $$select app.rental_form_upload(test.id('ra2_admin'), ('{"form_code":"BLINDSPOT-RA","file_key":"forms/templates/SR-LV-006/x.pdf","sha256":"' || repeat('e', 64) || '"}')::jsonb)$$, 'Unknown file');
select test.throws('Forms: it is not mapped field by field',
  $$select app.door(test.id('ra2_admin'), 'aal2', 'ops_do', 'form_template_upload', '{"form_code":"BLINDSPOT-RA","file_key":"forms/templates/BLINDSPOT-RA/x.pdf","fields":[{"name":"a"}]}')$$, 'filled for each booking');
select test.throws('Forms: it cannot be checked before its PDF is uploaded',
  $$select app.rental_form_check(test.id('ra2_admin'), jsonb_build_object('template', (select id from pdf_templates where form_code = 'BLINDSPOT-RA' and is_current)))$$, 'Upload the PDF first');
select test.eq('Forms: the upload is a new version',
  app.rental_form_upload(test.id('ra2_admin'), ('{"form_code":"BLINDSPOT-RA","file_key":"forms/templates/BLINDSPOT-RA/one.pdf","sha256":"' || repeat('e', 64) || '","page_count":"2","file_name":"blindspot.pdf"}')::jsonb) ->> 'same', 'false');
select test.eq('Forms: stored with its SHA-256, current and unchecked',
  (select sha256 || '/' || verified || '/' || file_name || '/' || page_count from pdf_templates where form_code = 'BLINDSPOT-RA' and is_current), repeat('e', 64) || '/false/blindspot.pdf/2');
select test.eq('Forms: the same file again is the same version',
  app.rental_form_upload(test.id('ra2_admin'), ('{"form_code":"BLINDSPOT-RA","file_key":"forms/templates/BLINDSPOT-RA/two.pdf","sha256":"' || repeat('e', 64) || '"}')::jsonb) ->> 'same', 'true');
select test.eq('Admin > Today: now "check it"',
  (select x ->> 'message' like 'Check the Blind Spot rental agreement%' from jsonb_array_elements(app.site_setup_problems()) x where x ->> 'field' = 'rental_form'), true);
select app.rental_form_check(test.id('ra2_admin'), jsonb_build_object('template', (select id from pdf_templates where form_code = 'BLINDSPOT-RA' and is_current)));
select test.eq('Forms: checked, in use for bookings; Admin > Today has nothing more about it',
  (select verified::text from pdf_templates where form_code = 'BLINDSPOT-RA' and is_current) || '/' || (select count(*) from jsonb_array_elements(app.site_setup_problems()) x where x ->> 'field' = 'rental_form'), 'true/0');
select test.throws('Forms: the representative''s name is letters only',
  $$select app.rental_form_rep(test.id('ra2_admin'), '{"form_code":"BLINDSPOT-RA","rep_name":"Ahmad <b>"}')$$, 'letters');
select test.eq('Forms: the full name for the signature record, and a signature image',
  app.rental_form_rep(test.id('ra2_admin'), ('{"form_code":"BLINDSPOT-RA","rep_full_name":"A. Representative","signature_key":"forms/signatures/BLINDSPOT-RA/s.png","signature_sha256":"' || repeat('f', 64) || '"}')::jsonb),
  '{"name": "Ahmad", "full_name": "A. Representative", "has_signature": true}'::jsonb);
select test.eq('Forms: the image removed, the name is written again',
  app.rental_form_rep(test.id('ra2_admin'), '{"form_code":"BLINDSPOT-RA","clear_signature":true}') ->> 'has_signature', 'false');
select test.eq('Forms: the Admin''s sample reads the settings',
  (select (p #>> '{mailing,street}') || '/' || (p #>> '{mailing,unit}') || '/' || (p #>> '{mailing,postal_code}') || '/' || coalesce(p ->> 'hst_number', 'none') || '/' || (p #>> '{rep,name}')
     from app.rental_form_preview(test.id('ra2_admin'), jsonb_build_object('template', (select id from pdf_templates where form_code = 'BLINDSPOT-RA' and is_current))) p),
  '2967 Dundas St W/208B/M6P 1Z2/none/Ahmad');

-- ---------------------------------------------------------------- 3. the facts
update program_settings set company_hst_number = '79878 1234 RT0001' where id = (select id from app.settings());
select test.eq('facts: the mailing address in its parts, the HST number, the template',
  (select (x #>> '{mailing,street}') || '/' || (x #>> '{mailing,city}') || '/' || (x ->> 'hst_number') || '/' || ((x #>> '{template,sha256}') = repeat('e', 64))
     from public.server_blindspot_facts(test.ra2b('a'), test.ra2u('a')) x), '2967 Dundas St W/Toronto/79878 1234 RT0001/true');
select test.eq('Admin > Today: the HST number entered, nothing about it',
  (select count(*) from jsonb_array_elements(app.site_setup_problems()) x where x ->> 'field' = 'company_hst_number'), 0::bigint);
select test.throws('facts: for the renter of the booking or staff',
  $$select public.server_blindspot_facts(test.ra2b('a'), test.ra2u('b'))$$, 'renter of this booking');
select test.eq('facts: a booking billed to the renter has no insurer', public.server_blindspot_facts(test.ra2b('a'), test.id('ra2_cs')) -> 'insurer', 'null'::jsonb);
select test.eq('facts: an insurance replacement rental names the insurer, the claim and the adjuster',
  (select (x #>> '{insurer,name}') || '/' || (x #>> '{insurer,claim_number}') || '/' || (x #>> '{insurer,adjuster_name}') || '/' || (x #>> '{insurer,authorized_days}')
     from public.server_blindspot_facts(test.ra2b('b'), test.id('ra2_cs')) x), 'Example Mutual/CLM-1/Pat Adjuster/3');

-- ---------------------------------------------------------------- 4. opened beside the rental agreement
create function test.ra2_tpl() returns uuid language sql stable as $$ select id from pdf_templates where form_code = 'BLINDSPOT-RA' and is_current $$;
select test.throws('open: another renter cannot',
  $$select public.server_open_agreement_companion(test.ra2b('a'), test.ra2u('b'), test.ra2_tpl(), 'bookings/' || test.ra2b('a') || '/blindspot-1.pdf', repeat('1', 64))$$, 'renter of this booking');
select test.throws('open: a file outside the booking''s folder is refused',
  $$select public.server_open_agreement_companion(test.ra2b('a'), test.ra2u('a'), test.ra2_tpl(), 'bookings/elsewhere/blindspot-1.pdf', repeat('1', 64))$$, 'needs its file');
insert into test.ra2 select 'c1', public.server_open_agreement_companion(test.ra2b('a'), test.ra2u('a'), test.ra2_tpl(), 'bookings/' || test.ra2b('a') || '/blindspot-1.pdf', repeat('1', 64));
select test.eq('open: the same document is the same second agreement',
  public.server_open_agreement_companion(test.ra2b('a'), test.ra2u('a'), test.ra2_tpl(), 'bookings/' || test.ra2b('a') || '/blindspot-1.pdf', repeat('1', 64)), test.ra2b('c1'));
insert into test.ra2 select 'c2', public.server_open_agreement_companion(test.ra2b('a'), test.ra2u('a'), test.ra2_tpl(), 'bookings/' || test.ra2b('a') || '/blindspot-2.pdf', repeat('2', 64));
select test.eq('open: a changed document replaces it while unsigned',
  (select string_agg(status, ',' order by created_at) from rental_agreement_companions where booking_id = test.ra2b('a')), 'superseded,open');
select test.eq('open: its document is a rental agreement document of the booking, named for Blind Spot',
  (select d.title || '/' || d.kind || '/' || d.storage_bucket from documents d join rental_agreement_companions c on c.document_id = d.id where c.id = test.ra2b('c2')),
  'Blind Spot rental agreement ' || (select booking_number from bookings where id = test.ra2b('a')) || '/rental_agreement/agreements');
select test.eq('open: the server reads the current one',
  (select (x ->> 'id')::uuid = test.ra2b('c2') and x ->> 'status' = 'open' and x ->> 'document_sha256' = repeat('2', 64) from public.server_agreement_companion(test.ra2b('a')) x), true);
select test.login(test.ra2u('a'));
select test.eq('reads: the renter sees their own second agreements', (select count(*) from rental_agreement_companions), 2::bigint);
select test.logout();
select test.login(test.ra2u('b'));
select test.eq('reads: another renter sees none of them', (select count(*) from rental_agreement_companions where booking_id = test.ra2b('a')), 0::bigint);
select test.logout();

-- ---------------------------------------------------------------- 5. one signature for both
select test.throws('sign: a page without the second agreement''s SHA-256 is refused, nothing is signed',
  $$select public.renter_sign_agreement(test.ra2b('a'), test.ra2u('a'), 'I sign.', repeat('a', 64), test.ra2_consents(), 'Ana Second', null, '203.0.113.7', 'test')$$, 'Blind Spot rental agreement changed');
select test.throws('sign: a second agreement that changed is refused',
  $$select public.renter_sign_agreement(test.ra2b('a'), test.ra2u('a'), 'I sign.', repeat('a', 64), test.ra2_consents(), 'Ana Second', null, '203.0.113.7', 'test', repeat('1', 64))$$, 'Blind Spot rental agreement changed');
select test.eq('sign: still open after a refusal', (select status from rental_agreements where booking_id = test.ra2b('a') and status <> 'voided'), 'open');
select test.lives('sign: the renter signs both with one signature',
  $$select public.renter_sign_agreement(test.ra2b('a'), test.ra2u('a'), 'I sign.', repeat('a', 64), test.ra2_consents(), 'Ana Second', null, '203.0.113.7', 'test', repeat('2', 64))$$);
select test.eq('sign: the second agreement records the rental agreement''s signature',
  (select c.status || '/' || (c.renter_signed_at is not null) || '/' || s.signer_role || '/' || s.method from rental_agreement_companions c join signature_records s on s.id = c.renter_record_id where c.id = test.ra2b('c2')),
  'signed/true/renter/typed');
select test.eq('sign: a signed second agreement is not replaced',
  public.server_open_agreement_companion(test.ra2b('a'), test.ra2u('a'), test.ra2_tpl(), 'bookings/' || test.ra2b('a') || '/blindspot-3.pdf', repeat('3', 64)), test.ra2b('c2'));
select test.lives('sign: a booking without a second agreement signs as before',
  $$select public.renter_sign_agreement(test.ra2b('b'), test.ra2u('b'), 'I sign.', repeat('d', 64), test.ra2_consents(), 'Bo Second', null, '203.0.113.7', 'test')$$);

-- ---------------------------------------------------------------- 6. the signed copy and the email
select test.throws('signed copy: only once the rental agreement is countersigned',
  $$select public.server_attach_companion_signed(test.ra2b('c2'), 'bookings/a/blindspot-signed.pdf', repeat('9', 64))$$, 'countersigned');
update rental_agreements set status = 'completed', completed_at = now() where booking_id = test.ra2b('a') and status = 'signed';
insert into test.ra2 select 'sd', public.server_attach_companion_signed(test.ra2b('c2'), 'bookings/a/blindspot-signed.pdf', repeat('9', 64));
select test.eq('signed copy: stored with the booking, the second agreement completed',
  (select c.status || '/' || d.title || '/' || d.sha256 from rental_agreement_companions c join documents d on d.id = c.signed_document_id where c.id = test.ra2b('c2')),
  'completed/Blind Spot rental agreement ' || (select booking_number from bookings where id = test.ra2b('a')) || ', signed/' || repeat('9', 64));
select test.eq('signed copy: stored once', public.server_attach_companion_signed(test.ra2b('c2'), 'bookings/a/other.pdf', repeat('8', 64)), test.ra2b('sd'));
insert into notification_outbox (id, code, category, priority, audience, to_address, entity, entity_id, dedupe_key)
select test.id('outbox:ra2'), 'renter_agreement_signed', 'transactional', 1, 'renter', 'ana.ra2@example.test', 'rental_agreement', a.id, 'ra2-test-signed'
  from rental_agreements a where a.booking_id = test.ra2b('a') and a.status = 'completed';
select test.eq('email: "Your signed rental agreement" carries the signed Blind Spot agreement',
  (select x ->> 'key' from jsonb_array_elements(app.outbox_attachments(test.id('outbox:ra2'))) x where x ->> 'filename' like 'Blind Spot%'), test.ra2b('sd')::text);
select test.ok('email: it does not wait once the signed copy is stored', (select send_after <= now() + interval '1 minute' from notification_outbox where id = test.id('outbox:ra2')));
