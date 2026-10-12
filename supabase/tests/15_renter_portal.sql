-- 15: the renter portal (migration 0028). Every fixture label starts with "rp" (and "RP" for cars).
select test.suite('15 renter portal');
grant usage on schema test to service_role;
grant execute on all functions in schema test to authenticated, anon, service_role;

select test.mk_owner('rp_one');
select test.mk_vehicle('RP1', 'rp_one');
insert into vehicle_listings (vehicle_id, slug, headline, status, home_area)
values (test.id('vehicle:RP1'), 'rp-one-test', 'Portal test car', 'published', 'Leslieville');
select test.mk_user('rp_cs', 'va', 'cs');

create function test.rp_req(p_key text, p_email text, p_name text) returns jsonb language sql stable as $$
  select jsonb_build_object(
    'request_key', 'rp-key-' || p_key, 'vehicle_id', test.id('vehicle:RP1'),
    'pickup_at', date_trunc('day', now() + interval '40 days') + interval '15 hours',
    'return_at', date_trunc('day', now() + interval '43 days') + interval '15 hours',
    'booking_type', 'standard', 'coverage_option', 2,
    'renter', jsonb_build_object('full_name', p_name, 'date_of_birth', '1988-04-04', 'email', p_email, 'mobile', '416-555-0142', 'licence_class', 'G', 'licence_issuer', 'ON'),
    'consents', jsonb_build_object(
      'terms', jsonb_build_object('accepted', true, 'version', 't', 'text', 'I agree.'),
      'privacy', jsonb_build_object('accepted', true, 'version', 'p', 'text', 'I agree.')))
$$;
create table test.rp (k text primary key, v uuid);
insert into test.rp select 'a', (app.submit_booking_request(test.rp_req('a', 'amy.rp@example.test', 'Amy Portal')) ->> 'booking_id')::uuid;
insert into test.rp select 'b', (app.submit_booking_request(test.rp_req('b', 'ben.rp@example.test', 'Ben Portal')) ->> 'booking_id')::uuid;
grant select on test.rp to authenticated, service_role;
create function test.rpb(p text) returns uuid language sql stable as $$ select v from test.rp where k = p $$;
create function test.rpn(p text) returns text language sql stable security definer as $$ select booking_number from public.bookings where id = test.rpb(p) $$;
create function test.rpu(p text) returns uuid language sql stable security definer as $$
  select r.user_id from public.bookings b join public.renters r on r.id = b.renter_id where b.id = test.rpb(p) $$;

-- ---------------------------------------------------------------- 1. reads under row-level security
select test.login(test.rpu('a'));
select test.eq('reads: a renter lists only their own bookings', (select count(*)::int from public.my_bookings()), 1);
select test.eq('reads: their booking reads in full, with the request as sent',
  (select (public.my_booking(test.rpn('a')) ->> 'status') || '/' || (public.my_booking(test.rpn('a')) #>> '{request,coverage_option}')), 'requested/2');
select test.eq('reads: another renter''s booking number reads as nothing', public.my_booking(test.rpn('b')) is null, true);
select test.throws('reads: a browser session cannot call the server wrappers',
  $$select public.server_booking_payment_facts(test.rpb('a'))$$, 'permission denied');
select test.throws('reads: nor sign through them', $$select public.renter_sign_agreement(test.rpb('a'), auth.uid(), 'x', 'x', '[]')$$, 'permission denied');
select test.logout();

-- ---------------------------------------------------------------- 2. the offer, the agreement and the signature
select app.send_offer(test.rpb('a'), test.id('rp_cs'));
select test.login(test.rpu('a'));
select test.eq('offer: the renter reads the version that was sent', (public.my_booking(test.rpn('a')) #>> '{offers,0,status}'), 'sent');
select test.logout();
select public.renter_approve_offer(test.rpb('a'), 1, test.rpu('a'));
select test.throws('agreement: another renter cannot open it',
  $$select public.renter_open_agreement(test.rpb('a'), test.rpu('b'), 'rental-test', repeat('a', 64), 'bookings/a/x.pdf')$$, 'renter of the booking');
select public.renter_open_agreement(test.rpb('a'), test.rpu('a'), 'rental-test', repeat('a', 64), 'bookings/a/x.pdf');
select test.throws('signature: another renter cannot sign it',
  $$select public.renter_sign_agreement(test.rpb('a'), test.rpu('b'), 'I sign.', repeat('a', 64), '[]', 'Amy Portal')$$, 'renter of the booking');
select test.throws('signature: a stale document is refused',
  $$select public.renter_sign_agreement(test.rpb('a'), test.rpu('a'), 'I sign.', repeat('b', 64), '[]', 'Amy Portal')$$, 'document changed');
select test.lives('signature: the renter signs the open agreement, with the four consents',
  $$select public.renter_sign_agreement(test.rpb('a'), test.rpu('a'), 'I sign.', repeat('a', 64),
     '[{"code":"tracking_disabling","version":"v","text":"t"},{"code":"identity_verification","version":"v","text":"t"},{"code":"electronic_signature","version":"v","text":"t"},{"code":"card_authorization","version":"v","text":"t"}]',
     'amy  portal', null, '203.0.113.7', 'test')$$);
select test.eq('signature: the facts the server checks before payment', (public.server_booking_payment_facts(test.rpb('a')) ->> 'agreement_signed')::boolean, true);
select test.login(test.rpu('a'));
select test.eq('signature: the renter sees the agreement signed and the signers',
  (public.my_booking(test.rpn('a')) #>> '{agreement,status}') || '/' || jsonb_array_length(public.my_booking(test.rpn('a')) #> '{agreement,signers}'), 'signed/2');
select test.eq('documents: the renter may read the agreement''s storage key',
  public.my_document((public.my_booking(test.rpn('a')) #>> '{agreement,document_id}')::uuid) ->> 'path', 'bookings/a/x.pdf');
select test.logout();
insert into test.rp select 'doc', agreement_document_id from bookings where id = test.rpb('a');
select test.login(test.rpu('b'));
select test.eq('documents: another renter gets nothing for the same id', public.my_document(test.rpb('doc')) is null, true);
select test.logout();

-- ---------------------------------------------------------------- 3. uploads, details, marketing
select test.throws('uploads: another renter cannot register one',
  $$select public.renter_register_upload(test.rpb('a'), test.rpu('b'), 'coverage_proof', 'bookings/a/c.pdf', repeat('c', 64), 'application/pdf', 'documents')$$, 'renter of the booking');
select test.eq('uploads: the renter registers the coverage proof',
  (public.renter_register_upload(test.rpb('a'), test.rpu('a'), 'coverage_proof', 'bookings/a/c.pdf', repeat('c', 64), 'application/pdf', 'documents',
     null, '{"card_issuer":"Bank","card_last4":"4242"}') ->> 'ok')::boolean, true);
select test.throws('details: an Ontario licence number must look like one',
  $$select public.renter_save_details(test.rpu('a'), '{"licence_number":"12345","licence_issuer":"ON","licence_expiry":"2031-01-01"}')$$, 'Ontario licence number');
select public.renter_save_details(test.rpu('a'), '{"address_line1":"1 Main St","city":"Toronto","province":"ON","postal_code":"m5v 1a1","country":"Canada","licence_number":"A1234-12345-12345","licence_issuer":"ON","licence_expiry":"2031-01-01"}', test.rpb('a'));
select test.eq('details: the address and a valid licence are saved for the renter and the booking',
  'true/' || (select postal_code from renters where user_id = test.rpu('a'))
  || '/' || (select licence_number from booking_drivers where booking_id = test.rpb('a') and role = 'renter'), 'true/M5V 1A1/A1234-12345-12345');
select public.renter_set_marketing(test.rpu('a'), true, 'Send me offers.', 'm1', '203.0.113.7', 'test');
select test.eq('marketing: turning it on records the consent with its words',
  (select u.marketing_opt_in::text || '/' || (select count(*) from consents c where c.user_id = u.id and c.consent_code = 'marketing' and c.text_version = 'm1')
     from users u where u.id = test.rpu('a')), 'true/1');
