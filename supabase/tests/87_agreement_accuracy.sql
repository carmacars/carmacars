-- 87: the rental agreements, accurate and dynamic (migration 0154, docs/changes/2026-10-24-agreement-accuracy.md): the
-- facts both documents print, the versions (a correction filed, a material change signed again, the pickup and return
-- copies), the signing session (identity code, initials, consents, drawn signature) that every signing path needs, the
-- completeness check at check-out with the Admin's override, and the dispute evidence pack. Uses the operations helpers
-- of 09 (test.op_photos, test.op_deposit_payment). Fixtures start with "ag".
select test.suite('87 agreement accuracy');
grant usage on schema test to service_role;
grant execute on all functions in schema test to authenticated, anon, service_role;

select test.eq('settings: the signing session and the check-out check are on by default, the typed fallback off',
  (select string_agg(column_name || '=' || column_default, ',' order by column_name) from information_schema.columns
    where table_name = 'program_settings' and column_name in ('esign_strict', 'agreement_claim_check', 'esign_typed_fallback')),
  'agreement_claim_check=false,esign_strict=false,esign_typed_fallback=false');
-- helpers.sql turned the first two off for the earlier suites (its defaults too); this suite turns them on
update program_settings set esign_strict = true, agreement_claim_check = true;
-- the licence before an offer is accepted (82 leaves it on) is not this suite's subject: its booking has no licence images
update program_settings set booking_licence_required = false;

select test.mk_user('ag_admin', 'admin');
select test.mk_user('ag_cs', 'va', 'cs');
select test.mk_user('ag_fin', 'va', 'finance');
select test.mk_owner('ag_o');
select test.mk_vehicle('AGV', 'ag_o');
update vehicles set vin = '1HGCM82633A004352', colour = 'Black', fleet_number = 'F-21', plate = 'AGTEST1' where id = test.id('vehicle:AGV');
insert into vehicle_listings (vehicle_id, slug, headline, status, home_area) values (test.id('vehicle:AGV'), 'ag-test', 'Agreement test car', 'published', 'Leslieville');
insert into tracker_devices (id, serial_number, vehicle_id, status, installed_at, tested_at) values (test.id('trk:AGV'), 'AG-TRK-1', test.id('vehicle:AGV'), 'installed', now(), now());
insert into tracker_status (tracker_device_id, reported_at, speed_kmh, ignition_on) values (test.id('trk:AGV'), now(), 0, false);

create function test.ag_req(p_key text, p_days integer) returns jsonb language sql stable as $$
  select jsonb_build_object(
    'request_key', 'ag-key-' || p_key, 'vehicle_id', test.id('vehicle:AGV'),
    'pickup_at', date_trunc('hour', now() + make_interval(days => p_days)) + interval '3 hours',
    'return_at', date_trunc('hour', now() + make_interval(days => p_days + 3)) + interval '3 hours',
    'booking_type', 'standard', 'coverage_option', 2,
    'renter', jsonb_build_object('full_name', 'Ana Accurate', 'date_of_birth', '1990-05-05', 'email', 'ana.ag@example.test', 'mobile', '416-555-0187',
                                 'licence_class', 'G', 'licence_issuer', 'ON', 'licence_number', 'A1234-56789-00505', 'licence_expiry', '2031-05-05',
                                 'address_line1', '1 Example Street', 'city', 'Toronto', 'province', 'ON', 'postal_code', 'M5H 2N2'),
    'additional_drivers', '[{"full_name": "Dee Accurate", "date_of_birth": "1988-02-02", "email": "dee.ag@example.test", "licence_class": "G"}]'::jsonb,
    'consents', jsonb_build_object('terms', jsonb_build_object('accepted', true, 'version', 't', 'text', 'I agree.'),
                                   'privacy', jsonb_build_object('accepted', true, 'version', 'p', 'text', 'I agree.')))
$$;
create table test.ag (k text primary key, v uuid);
grant select on test.ag to authenticated, service_role;
insert into test.ag select 'a', (app.submit_booking_request(test.ag_req('a', 0)) ->> 'booking_id')::uuid;
create function test.agb(p text) returns uuid language sql stable as $$ select v from test.ag where k = p $$;
create function test.agu(p text) returns uuid language sql stable security definer as $$
  select r.user_id from public.bookings b join public.renters r on r.id = b.renter_id where b.id = test.agb(p) $$;
create function test.ag_signer(p text, p_role text) returns uuid language sql stable security definer as $$
  select g.id from public.rental_agreement_signers g join public.rental_agreements a on a.id = g.agreement_id
   where a.booking_id = test.agb(p) and a.status in ('open', 'signed', 'completed') and g.signer_role = p_role limit 1 $$;
create function test.ag_consents() returns jsonb language sql immutable as $$
  select '[{"code":"tracking_disabling","version":"v","text":"t"},{"code":"identity_verification","version":"v","text":"t"},{"code":"electronic_signature","version":"v","text":"t"},{"code":"card_authorization","version":"v","text":"t"}]'::jsonb $$;
-- a complete signing session, as the signing page builds it (the code's hash is the site's; here a made-up one)
create function test.ag_session(p_ctx text, p_ref uuid, p_sig text) returns uuid language plpgsql as $$
declare
  v uuid;
  k text;
begin
  v := (public.server_esign_start(jsonb_build_object('context', p_ctx, 'signer_ref', p_ref, 'ip', '203.0.113.9', 'user_agent', 'test',
                                                     'documents', '[{"title":"t","sha256":"x"}]'::jsonb)) ->> 'id')::uuid;
  perform public.server_esign_code_set(v, 'email', repeat('c', 64), '203.0.113.9', 'test');
  perform public.server_esign_code_check(v, repeat('c', 64), '203.0.113.9', 'test');
  perform public.server_esign_step(v, 'viewed', '{}', '203.0.113.9', 'test');
  for k in select unnest(required_initials) from esign_sessions where id = v loop
    perform public.server_esign_step(v, 'initial', jsonb_build_object('code', k, 'path', 'sig/initials-' || k || '.png'), '203.0.113.9', 'test');
  end loop;
  for k in select unnest(required_consents) from esign_sessions where id = v loop
    perform public.server_esign_step(v, 'consent', jsonb_build_object('code', k, 'text', 'I agree'), '203.0.113.9', 'test');
  end loop;
  perform public.server_esign_step(v, 'geolocation', '{"lat": 43.65, "lng": -79.38, "accuracy": 20}', '203.0.113.9', 'test');
  perform public.server_esign_step(v, 'signature', jsonb_build_object('method', 'drawn', 'path', p_sig), '203.0.113.9', 'test');
  return v;
end $$;

-- the renter's home address and licence, as the renter details step records them before signing
update renters set address_line1 = '1 Example Street', city = 'Toronto', province = 'ON', postal_code = 'M5H 2N2' where id = (select renter_id from bookings where id = test.agb('a'));
update drivers set licence_number = 'A1234-56789-00505', licence_expiry = '2031-05-05', licence_issuer = 'ON'
 where id = (select driver_id from booking_drivers where booking_id = test.agb('a') and role = 'renter');
update booking_drivers set licence_number = 'A1234-56789-00505', licence_expiry = '2031-05-05', licence_issuer = 'ON' where booking_id = test.agb('a') and role = 'renter';
select app.send_offer(test.agb('a'), test.id('ag_cs'));
select public.renter_approve_offer(test.agb('a'), 1, test.agu('a'));
select public.renter_open_agreement(test.agb('a'), test.agu('a'), 'rental-test', repeat('a', 64), 'bookings/' || test.agb('a') || '/agreement.pdf');
-- the site records what the document printed when it renders it (version 1 is that, not the booking at countersigning)
select public.server_agreement_rendered(test.agb('a'), null);
select test.eq('rendered: what the open agreement printed is kept with it',
  (select (rendered_snapshot -> 'renter' ->> 'address') from rental_agreements where booking_id = test.agb('a') and status = 'open'), '1 Example Street, Toronto, ON M5H 2N2');

-- ---------------------------------------------------------------- 1. the facts both agreements print
select test.eq('facts: the deposit, how it is held, the lines, the late terms, the car',
  (select (x -> 'deposit' ->> 'pay_method') || '/' || (jsonb_array_length(x -> 'lines') > 0) || '/' || (x -> 'vehicle' ->> 'fleet_number') || '/' || (x -> 'vehicle' ->> 'vin')
     || '/' || coalesce(x ->> 'pickup', 'none') || '/' || coalesce(x ->> 'return', 'none')
     from public.server_agreement_extra(test.agb('a'), test.agu('a')) x), 'card/true/F-21/1HGCM82633A004352/none/none');
select test.throws('facts: only the renter or staff read them', format($$select public.server_agreement_extra(%L, %L)$$, test.agb('a'), test.id('ag_o')), 'Only the renter');
select test.eq('facts: each driver''s address (the renter''s from the renter record)',
  (select x -> 'drivers' -> (select d.id::text from booking_drivers d where d.booking_id = test.agb('a') and d.role = 'renter') ->> 'address'
     from public.server_agreement_extra(test.agb('a'), test.agu('a')) x), '1 Example Street, Toronto, ON M5H 2N2');
select test.eq('plan: the agreement is open (the site renders it again when the booking changes)', app.agreement_plan(test.agb('a')) ->> 'state', 'unsigned');

-- ---------------------------------------------------------------- 2. signing needs the whole session
select test.throws('signing: a typed name alone is refused',
  $$select public.renter_sign_agreement(test.agb('a'), test.agu('a'), 'I sign.', repeat('a', 64), test.ag_consents(), 'Ana Accurate', null, '203.0.113.7', 'test')$$, 'Confirm your identity with the code');
create temp table ag_s as select public.server_esign_start(jsonb_build_object('context', 'rental_agreement', 'signer_ref', test.ag_signer('a', 'renter'), 'ip', '203.0.113.9', 'user_agent', 'test')) j;
select test.eq('session: the renter initials five terms and gives three consents; the code goes to the phone or email on file, masked',
  (select jsonb_array_length(j -> 'required_initials') || '/' || jsonb_array_length(j -> 'required_consents') || '/' || (j -> 'channels' -> 0 ->> 'to') from ag_s), '5/3/***-***-0187');
select test.throws('session: no initial before the code', format($$select public.server_esign_step(%L, 'initial', '{"code":"damage","path":"x"}')$$, (select j ->> 'id' from ag_s)), 'Confirm the code first');
select public.server_esign_code_set((select (j ->> 'id')::uuid from ag_s), 'sms', repeat('1', 64));
select test.throws('session: another code within 30 seconds is refused', format($$select public.server_esign_code_set(%L, 'sms', %L)$$, (select j ->> 'id' from ag_s), repeat('2', 64)), 'Wait a few seconds');
select test.eq('session: a wrong code is counted', public.server_esign_code_check((select (j ->> 'id')::uuid from ag_s), repeat('9', 64)) ->> 'wrong', 'true');
select test.eq('session: the right code verifies', public.server_esign_code_check((select (j ->> 'id')::uuid from ag_s), repeat('1', 64)) ->> 'verified', 'true');
select test.throws('session: a typed signature needs the Admin''s fallback', format($$select public.server_esign_step(%L, 'signature', '{"method":"typed","path":"Ana"}')$$, (select j ->> 'id' from ag_s)), 'Draw your signature');
select test.eq('session: not ready until viewed, initialled, consented and drawn', public.server_esign_view((select (j ->> 'id')::uuid from ag_s)) ->> 'ready', 'false');
select test.ag_session('rental_agreement', test.ag_signer('a', 'renter'), 'bookings/a/sig.png');
select test.throws('signing: the drawn signature must be the session''s',
  $$select public.renter_sign_agreement(test.agb('a'), test.agu('a'), 'I sign.', repeat('a', 64), test.ag_consents(), null, 'bookings/a/other.png', '203.0.113.7', 'test')$$, 'does not match');
select test.lives('signing: with the session, the renter signs',
  $$select public.renter_sign_agreement(test.agb('a'), test.agu('a'), 'I sign.', repeat('a', 64), test.ag_consents(), null, 'bookings/a/sig.png', '203.0.113.7', 'test')$$);
select test.eq('signing: the session is closed with the signature record, every step in the trail',
  (select (s.signature_record_id is not null)::text || '/' || ((select count(*) from esign_events e where e.session_id = s.id and e.kind in ('code_sent', 'code_verified', 'viewed', 'initial', 'consent', 'geolocation', 'signature', 'signed')) >= 13)::text
     from esign_sessions s where s.signer_ref = test.ag_signer('a', 'renter') and s.signed_at is not null), 'true/true');
select test.throws('trail: the audit trail is never changed', $$delete from esign_events$$, 'append-only');
select test.eq('signing: what it printed is kept when it is countersigned, not before', (select signed_snapshot is null from rental_agreements where booking_id = test.agb('a') and status = 'signed'), true);
-- the driver signs on their own link the same way
select test.ag_session('rental_agreement', test.ag_signer('a', 'additional_driver'), 'drivers/a/sig.png');
select test.eq('session: a driver initials three terms, two consents', (select array_length(required_initials, 1) || '/' || array_length(required_consents, 1) from esign_sessions where signer_ref = test.ag_signer('a', 'additional_driver') order by created_at desc limit 1), '3/2');
select test.lives('signing: the driver signs with their session',
  $$select public.driver_sign_agreement(test.ag_signer('a', 'additional_driver'), 'I sign.', repeat('a', 64), test.ag_consents(), null, 'drivers/a/sig.png', '203.0.113.8', 'test')$$);
select test.eq('certificate: both signers, with the code, the initials and the place',
  (select jsonb_array_length(c) || '/' || (c -> 0 ->> 'otp_channel') || '/' || (select count(*) from jsonb_object_keys(c -> 0 -> 'initials')) || '/' || (c -> 0 -> 'geo' ->> 'lat')
     from public.server_esign_certificate('rental_agreement', array[test.ag_signer('a', 'renter'), test.ag_signer('a', 'additional_driver')]) c), '2/email/5/43.65');

-- countersigned: the booking is confirmed; version 1 is the agreement as signed
insert into payments (id, booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at)
select test.id('pay:ag'), b.id, b.renter_id, 'booking_total', 'charge', 'card', 50000, 'succeeded', now() from bookings b where b.id = test.agb('a');
update rental_agreements set status = 'completed', completed_at = now() where booking_id = test.agb('a') and status = 'signed';
update signature_requests set status = 'completed', completed_at = now() where id = (select signature_request_id from bookings where id = test.agb('a'));
set session_replication_role = replica;
update bookings set status = 'confirmed' where id = test.agb('a');
set session_replication_role = origin;
select test.eq('versions: version 1 is the signed agreement, what it printed kept', (select version_no || '/' || kind || '/' || status from agreement_versions where booking_id = test.agb('a'))
  || '/' || (select (signed_snapshot -> 'dates' ->> 'return_at') is not null from rental_agreements where booking_id = test.agb('a') and status = 'completed'), '1/signed/signed/true');
select test.eq('plan: nothing changed', app.agreement_plan(test.agb('a')) ->> 'state' || coalesce((app.agreement_plan(test.agb('a')) -> 'changes')::text, ''), 'current');

-- ---------------------------------------------------------------- 3. a correction is filed, a material change signed again
update renters set address_line2 = 'Unit 4' where id = (select renter_id from bookings where id = test.agb('a'));
select test.eq('touch: a change queues the booking''s agreements', (select count(*) from agreement_jobs where kind = 'version' and ref = test.agb('a')), 1::bigint);
create temp table ag_p1 as select app.agreement_plan(test.agb('a')) p;
select test.eq('plan: the address is a correction, not signed again',
  (select (p ->> 'kind') || '/' || (p ->> 'material') || '/' || (p -> 'changes' -> 0 ->> 'label') || '/' || (p -> 'changes' -> 0 ->> 'after') from ag_p1),
  'correction/false/Renter: address/1 Example Street, Unit 4, Toronto, ON M5H 2N2');
select test.throws('add: a stale plan is refused (the job runs again)',
  format($$select public.server_agreement_version_add(%L, '{"snapshot_sha": "x", "carmacars": {"path": "bookings/%s/v.pdf", "sha256": "%s"}}')$$, test.agb('a'), test.agb('a'), repeat('b', 64)), 'changed while');
select test.eq('add: version 2 filed, both documents stored',
  public.server_agreement_version_add(test.agb('a'), jsonb_build_object('snapshot_sha', (select p ->> 'snapshot_sha' from ag_p1),
    'carmacars', jsonb_build_object('path', 'bookings/' || test.agb('a') || '/v2.pdf', 'sha256', repeat('b', 64)),
    'blindspot', jsonb_build_object('path', 'bookings/' || test.agb('a') || '/v2-bs.pdf', 'sha256', repeat('c', 64)))) ->> 'status', 'filed');
select test.eq('add: the renter gets the corrected copies by email', (select count(*) from app_events where code = 'renter_agreement_version' and payload ->> 'booking_id' = test.agb('a')::text), 1::bigint);
insert into notification_outbox (id, code, category, priority, audience, to_address, entity, entity_id, booking_id, dedupe_key)
values (test.id('outbox:ag'), 'renter_agreement_version', 'transactional', 2, 'renter', 'ana.ag@example.test', 'agreement_version',
        (select id from agreement_versions where booking_id = test.agb('a') and version_no = 2), test.agb('a'), 'ag-outbox-test');
select test.eq('add: the email carries both documents', jsonb_array_length(app.outbox_attachments(test.id('outbox:ag'))), 2);
-- staff extend the rental by two days (the edit screens of the long-rentals branch write the booking the same way)
set session_replication_role = replica;
update bookings set return_at = return_at + interval '2 days', billable_days = public.calc_billable_days(pickup_at, return_at + interval '2 days'),
  km_allowance_total = km_allowance_per_day * public.calc_billable_days(pickup_at, return_at + interval '2 days') where id = test.agb('a');
set session_replication_role = origin;
create temp table ag_p2 as select app.agreement_plan(test.agb('a')) p;
select test.eq('plan: a later due-back is material: the renter and the driver sign',
  (select (p ->> 'kind') || '/' || (p ->> 'material') || '/' || (select string_agg(s ->> 'role', ',' order by s ->> 'role' desc) from jsonb_array_elements(p -> 'signers') s) from ag_p2),
  'change/true/renter,additional_driver');
select public.server_agreement_version_add(test.agb('a'), jsonb_build_object('snapshot_sha', (select p ->> 'snapshot_sha' from ag_p2),
  'carmacars', jsonb_build_object('path', 'bookings/' || test.agb('a') || '/v3.pdf', 'sha256', repeat('d', 64))));
select test.eq('add: version 3 waits for two signatures, each sent a link by email (and a text to the mobile)',
  (select v.status || '/' || (select count(*) from agreement_version_signers g where g.version_id = v.id and g.status = 'waiting') from agreement_versions v where v.booking_id = test.agb('a') and v.version_no = 3)
  || '/' || (select count(*) from app_events where code = 'renter_agreement_version' and payload ->> 'needs_signature' = 'true' and payload ->> 'booking_id' = test.agb('a')::text)
  || '/' || (select count(*) from phone_outbox where booking_id = test.agb('a') and sms_kind = 'agreement_version'), 'awaiting_signature/2/2/1');
select test.eq('state: the booking shows the version waiting, and a task for customer service',
  (select (public.door(test.id('ag_cs'), null, 'ops_read', 'agreement_state', jsonb_build_object('booking', test.agb('a'))) -> 'waiting' ->> 'version_no'))
  || '/' || (select count(*) from tasks where dedupe_key = 'agreement_signature_waiting:' || test.agb('a') and status = 'open'), '3/1');
create temp table ag_tok as select g.link_token, g.id, g.role from agreement_version_signers g join agreement_versions v on v.id = g.version_id where v.booking_id = test.agb('a') and v.version_no = 3;
select test.eq('link: the page reads the version and the masked contact', (select public.server_agreement_version_link(link_token) -> 'version' ->> 'version_no' from ag_tok where role = 'renter'), '3');
select test.throws('sign: without the session it is refused',
  format($$select public.server_agreement_version_sign(%L, '{"carmacars_sha256": "%s", "consent_text": "I sign"}')$$, (select link_token from ag_tok where role = 'renter'), repeat('d', 64)), 'Confirm your identity');
select test.ag_session('agreement_version', (select id from ag_tok where role = 'renter'), 'bookings/a/v3-sig.png');
select test.throws('sign: a changed document is refused',
  format($$select public.server_agreement_version_sign(%L, '{"carmacars_sha256": "%s", "consent_text": "I sign"}')$$, (select link_token from ag_tok where role = 'renter'), repeat('e', 64)), 'document changed');
select test.eq('sign: the renter signs; the version still waits for the driver',
  public.server_agreement_version_sign((select link_token from ag_tok where role = 'renter'), jsonb_build_object('carmacars_sha256', repeat('d', 64), 'consent_text', 'I sign', 'ip', '203.0.113.9')) ->> 'version_signed', 'false');
select test.ag_session('agreement_version', (select id from ag_tok where role = 'additional_driver'), 'drivers/a/v3-sig.png');
create temp table ag_last as select public.server_agreement_version_sign((select link_token from ag_tok where role = 'additional_driver'), jsonb_build_object('carmacars_sha256', repeat('d', 64), 'consent_text', 'I sign')) r;
select test.eq('sign: the driver signs: version 3 is signed, its signed copies queued, the task done',
  (select r ->> 'version_signed' from ag_last) || '/' || (select count(*) from agreement_jobs where kind = 'version_signed') || '/' || (select count(*) from tasks where dedupe_key = 'agreement_signature_waiting:' || test.agb('a') and status = 'open'), 'true/1/0');
select test.eq('plan: current again', app.agreement_plan(test.agb('a')) ->> 'state', 'current');

-- ---------------------------------------------------------------- 4. check-out: the completeness check, the "as picked up" copy
insert into coverage_proofs (booking_id, coverage_option, status, card_issuer, card_last4, confirmed_at) values (test.agb('a'), 2, 'confirmed', 'Example Bank', '4242', now());
update bookings set coverage_confirmed_at = now() where id = test.agb('a');
select test.eq('missing: what a claim needs and what is only recommended',
  (select string_agg(x ->> 'key', ',' order by x ->> 'key') from jsonb_array_elements(app.agreement_missing(test.agb('a'))) x where (x ->> 'required')::boolean),
  'drivers.' || (select driver_id from booking_drivers where booking_id = test.agb('a') and role = 'additional') || '.licence_expiry,drivers.'
  || (select driver_id from booking_drivers where booking_id = test.agb('a') and role = 'additional') || '.licence_issuer,drivers.'
  || (select driver_id from booking_drivers where booking_id = test.agb('a') and role = 'additional') || '.licence_number');
update booking_drivers set identity_method = 'staff_review', identity_verified_on = current_date where booking_id = test.agb('a');
select test.throws('check-out: refused while a claim field is blank',
  $$select app.complete_handover(test.agb('a'), test.id('ag_admin'), jsonb_build_object('odometer_km', 20000, 'fuel_pct', 100, 'keys_count', 2, 'licence_seen', true, 'card_seen', true,
     'tracker_reporting', true, 'renter_signature_ref', 'sig/r', 'staff_signature_ref', 'sig/s', 'photos', test.op_photos('pickup')))$$,
  'missing what a claim needs');
select test.throws('override: only an Admin overrides', format($$select public.door(%L, null, 'ops_do', 'agreement_override', jsonb_build_object('booking', %L, 'reason', 'Driver is at the counter'))$$, test.id('ag_cs'), test.agb('a')), 'Only an Admin');
select test.throws('fill: a licence that expires before the return is refused',
  format($$select public.door(%L, null, 'ops_do', 'agreement_fill', jsonb_build_object('booking', %L, 'drivers', jsonb_build_array(jsonb_build_object('driver_id', %L, 'licence_number', 'd1234', 'licence_issuer', 'on', 'licence_expiry', '2020-01-01'))))$$,
    test.id('ag_cs'), test.agb('a'), (select driver_id from booking_drivers where booking_id = test.agb('a') and role = 'additional')), 'expires before the return');
select test.eq('fill: customer service fills the driver''s licence on the booking: nothing a claim needs is missing',
  (select count(*) from jsonb_array_elements(public.door(test.id('ag_cs'), null, 'ops_do', 'agreement_fill', jsonb_build_object('booking', test.agb('a'),
     'drivers', jsonb_build_array(jsonb_build_object('driver_id', (select driver_id from booking_drivers where booking_id = test.agb('a') and role = 'additional'),
       'licence_number', 'd1234-56789-00202', 'licence_issuer', 'on', 'licence_expiry', '2032-02-02', 'address_line1', '9 Example Ave', 'city', 'Toronto', 'province', 'on', 'postal_code', 'm4m1a1')))) -> 'missing') x
    where (x ->> 'required')::boolean), 0::bigint);
select test.eq('fill: kept in capitals on the driver and the booking''s driver', (select licence_number || '/' || licence_issuer from booking_drivers where booking_id = test.agb('a') and role = 'additional'), 'D1234-56789-00202/ON');
-- the in-progress readings (signed at pickup after them) are in the facts before the check-out completes
insert into condition_reports (vehicle_id, booking_id, kind, odometer_km, fuel_pct) values (test.id('vehicle:AGV'), test.agb('a'), 'pickup', 20000, 100);
select test.eq('pickup: the readings of a check-out in progress are in the facts; the version due is the correction of the fill, not a pickup copy',
  (select (x -> 'pickup' ->> 'odometer_km') || '/' || (x -> 'pickup' ->> 'completed') from public.server_agreement_extra(test.agb('a'), test.agu('a')) x) || '/' || (app.agreement_plan(test.agb('a')) ->> 'kind')
  || '/' || (select string_agg(c ->> 'after', '|') from jsonb_array_elements(app.agreement_plan(test.agb('a')) -> 'changes') c where c ->> 'label' like '%address'), '20000/false/correction/9 Example Ave, Toronto, ON M4M 1A1');
insert into payments (id, booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at)
select test.id('dep:ag'), b.id, b.renter_id, 'deposit', 'hold', 'card', b.deposit_cents, 'authorized', now() from bookings b where b.id = test.agb('a');
select app.record_deposit_taken(test.agb('a'), test.id('dep:ag'), test.id('ag_admin'));
select test.lives('check-out: complete now',
  $$select app.complete_handover(test.agb('a'), test.id('ag_admin'), jsonb_build_object('odometer_km', 20000, 'fuel_pct', 100, 'keys_count', 2, 'licence_seen', true, 'card_seen', true,
     'tracker_reporting', true, 'renter_signature_ref', 'sig/r', 'staff_signature_ref', 'sig/s', 'photos', test.op_photos('pickup')))$$);
create temp table ag_p3 as select app.agreement_plan(test.agb('a')) p;
select test.eq('plan: the "as picked up" copy, countersigned by the staff member who checked the car out',
  (select (p ->> 'kind') || '/' || (p #>> '{pickup,odometer_km}') || '/' || (p ->> 'countersigner' = test.id('ag_admin')::text) from ag_p3), 'pickup/20000/true');
select public.server_agreement_version_add(test.agb('a'), jsonb_build_object('snapshot_sha', (select p ->> 'snapshot_sha' from ag_p3),
  'carmacars', jsonb_build_object('path', 'bookings/' || test.agb('a') || '/v4.pdf', 'sha256', repeat('f', 64))));
select test.eq('pickup: version 4 filed with the check-out report and the countersignature',
  (select kind || '/' || status || '/' || (condition_report_id is not null) || '/' || (countersigned_by = test.id('ag_admin')) from agreement_versions where booking_id = test.agb('a') and version_no = 4),
  'pickup/filed/true/true');

-- ---------------------------------------------------------------- 5. check-in: the closing copy
select app.complete_return(test.agb('a'), test.id('ag_admin'), jsonb_build_object('odometer_km', 20750, 'fuel_pct', 75, 'keys_count', 2, 'cleanliness', 'clean', 'renter_present', true,
  'renter_signature_ref', 'sig/r2', 'staff_signature_ref', 'sig/s2', 'photos', test.op_photos('return')));
create temp table ag_p4 as select app.agreement_plan(test.agb('a')) p;
select test.eq('plan: the closing copy: km in, driven, charged, fuel in',
  (select (p ->> 'kind') || '/' || (p #>> '{return,odometer_km}') || '/' || (p #>> '{return,km_driven}') || '/' || (p #>> '{return,km_charged}') || '/' || (p #>> '{return,fuel_pct}') from ag_p4),
  'return/20750/750/' || (select greatest(750 - km_allowance_total, 0) from bookings where id = test.agb('a')) || '/75');
select public.server_agreement_version_add(test.agb('a'), jsonb_build_object('snapshot_sha', (select p ->> 'snapshot_sha' from ag_p4),
  'carmacars', jsonb_build_object('path', 'bookings/' || test.agb('a') || '/v5.pdf', 'sha256', repeat('5', 64))));
select test.eq('return: the closing copy filed, countersigned by the staff member who checked the car in',
  (select kind || '/' || status || '/' || (countersigned_by = test.id('ag_admin')) from agreement_versions where booking_id = test.agb('a') and version_no = 5), 'return/filed/true');
insert into booking_line_items (booking_id, charge_type, description, unit_amount_cents, amount_cents, hst_applies, hst_cents, revenue_class, stage)
values (test.agb('a'), 'cleaning', 'Cleaning', 5000, 5000, true, 650, (select revenue_class from booking_line_items where booking_id = test.agb('a') limit 1), 'after_return');
select test.eq('return: a charge assessed after the check-in makes a new closing copy', app.agreement_plan(test.agb('a')) ->> 'kind', 'return');

-- ---------------------------------------------------------------- 6. the dispute evidence pack
insert into disputes (payment_id, booking_id, processor_dispute_ref, amount_cents, reason) values (test.id('pay:ag'), test.agb('a'), 'dp_test_ag', 50000, 'fraudulent');
select test.eq('dispute: a disputed payment queues the evidence pack and puts the documents on hold',
  (select count(*) from dispute_packs where booking_id = test.agb('a') and status = 'queued') || '/' || (select count(*) from agreement_jobs where kind = 'dispute_pack' and ref = (select id from dispute_packs where booking_id = test.agb('a')))
  || '/' || (select bool_and(legal_hold) from documents where booking_id = test.agb('a') and kind = 'rental_agreement'), '1/1/true');
select test.eq('dispute: the evidence reads the signing trail, the reports and the messages',
  (select (jsonb_array_length(e -> 'signing' -> 'rental_agreement') >= 2)::text || '/' || jsonb_array_length(e -> 'reports') || '/' || (jsonb_array_length(e -> 'messages') > 0)
     from public.server_dispute_evidence((select id from dispute_packs where booking_id = test.agb('a'))) e), 'true/2/true');
select test.throws('dispute: Customer service does not build a pack', format($$select public.door(%L, null, 'ops_do', 'dispute_pack_build', jsonb_build_object('booking', %L))$$, test.id('ag_cs'), test.agb('a')), 'Admin or Finance');
select test.lives('dispute: Finance builds one on demand', format($$select public.door(%L, null, 'ops_do', 'dispute_pack_build', jsonb_build_object('booking', %L))$$, test.id('ag_fin'), test.agb('a')));
select public.server_dispute_pack_built((select id from dispute_packs where booking_id = test.agb('a') order by created_at limit 1),
  jsonb_build_object('path', 'disputes/' || test.agb('a') || '/pack.pdf', 'sha256', repeat('7', 64), 'size', 1000, 'stripe_file_id', 'file_test'));
select test.eq('dispute: built and staged, an urgent task for the Admin', (select status from dispute_packs where booking_id = test.agb('a') order by created_at limit 1)
  || '/' || (select priority from tasks where task_type = 'dispute_pack_ready' and booking_id = test.agb('a') limit 1), 'staged/urgent');

-- ---------------------------------------------------------------- 7. verify a file, the jobs, the doors
select test.eq('verify: a signed file''s SHA-256 is found, an unknown one is not',
  (select (public.server_verify_sha(repeat('b', 64)) ->> 'found') || '/' || (public.server_verify_sha(repeat('0', 64)) ->> 'found')), 'true/false');
select test.eq('jobs: the cron runs the agreements job when agreement work is due', (app.server_jobs_due() ->> 'agreements'), 'true');
create temp table ag_claim as select public.server_agreement_jobs_claim(5) j;
select test.ok('jobs: claimed', (select jsonb_array_length(j) >= 1 from ag_claim));
select public.server_agreement_job_fail('version', test.agb('a'), 'test failure');
select test.eq('jobs: a failure waits and keeps the error', (select (due_at > now()) || '/' || last_error from agreement_jobs where kind = 'version' and ref = test.agb('a')), 'true/test failure');
select test.throws('door: the agreement card is for staff', format($$select public.door(%L, null, 'ops_read', 'agreement_state', jsonb_build_object('booking', %L))$$, test.id('ag_o'), test.agb('a')), null);
select test.eq('privileges: the new functions are the service role''s only',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'server_esign%' and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))), 0::bigint);

update program_settings set esign_strict = false, agreement_claim_check = false;
