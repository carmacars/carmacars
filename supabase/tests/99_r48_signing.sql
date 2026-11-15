-- 99 r48: signing that does not refuse a real renter, and a returning renter signs in one tap (migrations 2910, 2911,
-- docs/changes/2026-11-14-r48-signing.md). Fixtures start with "r48".
select test.suite('99 r48 signing');
grant usage on schema test to service_role;
create temp table r48_was as select esign_strict, esign_code_required, booking_licence_required, amend_without_signature from program_settings limit 1;
update program_settings set esign_strict = true, esign_code_required = true, booking_licence_required = false, amend_without_signature = false;

-- ---------------------------------------------------------------- 1. names compared tolerantly
select test.eq('names: case, accents, hyphens, extra spaces and a middle name are ignored',
  app.person_names_match('  JOSÉ  maría García-López ', 'Jose Lopez'), true);
select test.eq('names: the order of the names and a comma', app.person_names_match('Smith, John', 'John A. Smith'), true);
select test.eq('names: an initial for the first name', app.person_names_match('J. Smith', 'John Smith'), true);
select test.eq('names: an apostrophe', app.person_names_match('Mary O''Neil', 'mary oneil'), true);
select test.eq('names: written together', app.person_names_match('Anne Marie Lee', 'AnneMarie Lee'), true);
select test.eq('names: another person is not the same name', app.person_names_match('Jane Smith', 'John Smith'), false);
select test.eq('names: one word alone is not enough', app.person_names_match('Smith', 'John Smith'), false);
select test.eq('names: an empty name never matches', app.person_names_match('', ''), false);
select test.eq('initials: first and last word', app.person_initials('José María García-López'), 'JL');

-- ---------------------------------------------------------------- fixtures: one renter, two bookings
select test.mk_user('r48_cs', 'va', 'cs');
select test.mk_owner('r48_o');
select test.mk_vehicle('R48V', 'r48_o');
insert into vehicle_listings (vehicle_id, slug, headline, status, home_area) values (test.id('vehicle:R48V'), 'r48-test', 'Signing test car', 'published', 'Leslieville');
create function test.r48_req(p_key text, p_days integer, p_drivers jsonb) returns jsonb language sql stable as $$
  select jsonb_build_object(
    'request_key', 'r48-key-' || p_key, 'vehicle_id', test.id('vehicle:R48V'),
    'pickup_at', date_trunc('hour', now() + make_interval(days => p_days)) + interval '3 hours',
    'return_at', date_trunc('hour', now() + make_interval(days => p_days + 3)) + interval '3 hours',
    'booking_type', 'standard', 'coverage_option', 1,
    'renter', jsonb_build_object('full_name', 'Rae Returning', 'date_of_birth', '1991-04-04', 'email', 'rae.r48@example.test', 'mobile', '416-555-0148',
                                 'licence_class', 'G', 'licence_issuer', 'ON', 'licence_number', 'R4800-00000-00404', 'licence_expiry', '2031-04-04',
                                 'address_line1', '48 Example Street', 'city', 'Toronto', 'province', 'ON', 'postal_code', 'M5H 2N2'),
    'additional_drivers', p_drivers,
    'consents', jsonb_build_object('terms', jsonb_build_object('accepted', true, 'version', 't', 'text', 'I agree.'),
                                   'privacy', jsonb_build_object('accepted', true, 'version', 'p', 'text', 'I agree.')))
$$;
create table test.r48 (k text primary key, v uuid);
insert into test.r48 select 'a', (app.submit_booking_request(test.r48_req('a', 40, '[{"full_name": "Dee Driver", "date_of_birth": "1988-02-02", "email": "dee.r48@example.test", "licence_class": "G"}]'::jsonb)) ->> 'booking_id')::uuid;
create function test.r48b(p text) returns uuid language sql stable as $$ select v from test.r48 where k = p $$;
create function test.r48u(p text) returns uuid language sql stable security definer as $$
  select r.user_id from public.bookings b join public.renters r on r.id = b.renter_id where b.id = test.r48b(p) $$;
create function test.r48_signer(p text, p_role text) returns uuid language sql stable security definer as $$
  select g.id from public.rental_agreement_signers g join public.rental_agreements a on a.id = g.agreement_id
   where a.booking_id = test.r48b(p) and a.status = 'open' and g.signer_role = p_role limit 1 $$;
create function test.r48_consents() returns jsonb language sql immutable as $$
  select '[{"code":"tracking_disabling","version":"v","text":"t"},{"code":"identity_verification","version":"v","text":"t"},{"code":"electronic_signature","version":"v","text":"t"},{"code":"card_authorization","version":"v","text":"t"}]'::jsonb $$;
-- a session complete up to the signature (code, reading, initials unless saved ones are used, consents)
create function test.r48_session(p_ref uuid, p_initials boolean default true) returns uuid language plpgsql as $$
declare
  v uuid;
  k text;
begin
  v := (public.server_esign_start(jsonb_build_object('context', 'rental_agreement', 'signer_ref', p_ref, 'ip', '203.0.113.9', 'user_agent', 'test',
                                                     'documents', '[{"title":"t","sha256":"x"}]'::jsonb)) ->> 'id')::uuid;
  perform public.server_esign_code_set(v, 'email', repeat('c', 64), '203.0.113.9', 'test');
  perform public.server_esign_code_check(v, repeat('c', 64), '203.0.113.9', 'test');
  perform public.server_esign_step(v, 'viewed', '{}', '203.0.113.9', 'test');
  for k in select unnest(required_initials) from esign_sessions where id = v and p_initials loop
    perform public.server_esign_step(v, 'initial', jsonb_build_object('code', k, 'path', 'esign/' || v || '/initials-' || k || '.png'), '203.0.113.9', 'test');
  end loop;
  for k in select unnest(required_consents) from esign_sessions where id = v loop
    perform public.server_esign_step(v, 'consent', jsonb_build_object('code', k, 'text', 'I agree'), '203.0.113.9', 'test');
  end loop;
  return v;
end $$;
create function test.r48_stroke(p_session uuid) returns text language plpgsql as $$
declare
  p text := 'esign/' || p_session || '/signature-' || gen_random_uuid() || '.png';
begin
  perform public.server_esign_step(p_session, 'signature', jsonb_build_object('method', 'drawn', 'path', p), '203.0.113.9', 'test');
  return p;
end $$;
create function test.r48_open(p text) returns void language plpgsql as $$
begin
  perform app.send_offer(test.r48b(p), test.id('r48_cs'));
  perform public.renter_approve_offer(test.r48b(p), 1, test.r48u(p));
  perform public.renter_open_agreement(test.r48b(p), test.r48u(p), 'rental-test', repeat('a', 64), 'bookings/' || test.r48b(p) || '/agreement.pdf');
end $$;
grant execute on all functions in schema test to authenticated, anon, service_role;
grant select on test.r48 to authenticated, service_role;
create temp table r48_x (k text primary key, v text);

update renters set address_line1 = '48 Example Street', city = 'Toronto', province = 'ON', postal_code = 'M5H 2N2' where id = (select renter_id from bookings where id = test.r48b('a'));
update drivers set licence_number = 'R4800-00000-00404', licence_expiry = '2031-04-04', licence_issuer = 'ON'
 where id = (select driver_id from booking_drivers where booking_id = test.r48b('a') and role = 'renter');
update booking_drivers set licence_number = 'R4800-00000-00404', licence_expiry = '2031-04-04', licence_issuer = 'ON' where booking_id = test.r48b('a') and role = 'renter';
insert into coverage_proofs (booking_id, coverage_option, status, insurer_name, policy_number, policy_expiry)
values (test.r48b('a'), 1, 'submitted', 'Example Mutual', 'TEST-POLICY-48', current_date + 300);
select test.r48_open('a');

-- ---------------------------------------------------------------- 2. the drawing sent is an earlier stroke: signed with the latest
insert into r48_x values ('sa', test.r48_session(test.r48_signer('a', 'renter')));
insert into r48_x values ('stroke1', test.r48_stroke((select v::uuid from r48_x where k = 'sa')));
insert into r48_x values ('stroke2', test.r48_stroke((select v::uuid from r48_x where k = 'sa')));
select test.throws('match: a drawing of another signing is still refused',
  $$select public.renter_sign_agreement(test.r48b('a'), test.r48u('a'), 'I sign.', repeat('a', 64), test.r48_consents(), null, 'esign/00000000-0000-4000-8000-000000000048/signature-00000000-0000-4000-8000-000000000001.png', '203.0.113.7', 'test')$$,
  'does not match this signing page');
select test.lives('match: the renter presses Sign while the last stroke uploads (the page sends the first stroke): signed, no error',
  format($$select public.renter_sign_agreement(test.r48b('a'), test.r48u('a'), 'I sign.', repeat('a', 64), test.r48_consents(), null, %L, '203.0.113.7', 'test')$$, (select v from r48_x where k = 'stroke1')));
select test.eq('match: the signature recorded is the session''s latest drawing',
  (select s.provider_signature from signature_records s join rental_agreement_signers g on g.signature_record_id = s.id where g.id = (select g2.id from rental_agreement_signers g2 join rental_agreements a on a.id = g2.agreement_id where a.booking_id = test.r48b('a') and g2.signer_role = 'renter')),
  (select v from r48_x where k = 'stroke2'));
select test.eq('saved: the drawn signature and initials are saved on the renter''s profile',
  (select (saved_signature_path = (select v from r48_x where k = 'stroke2'))::text || '/' || (saved_initials_path like 'esign/' || (select v from r48_x where k = 'sa') || '/initials-%')::text
     from renters r join bookings b on b.renter_id = r.id where b.id = test.r48b('a')), 'true/true');

-- ---------------------------------------------------------------- 3. typed names are never refused for a renter
select test.eq('typed: a name that matches tolerantly raises nothing',
  (select app.typed_name_refused(test.r48b('a'), 'Rae Returning', 'rae  RETURNING') or exists (select 1 from tasks where task_type = 'signature_name_review' and booking_id = test.r48b('a'))), false);
select test.eq('typed: a name that still differs is accepted', app.typed_name_refused(test.r48b('a'), 'Rae Returning', 'Ray Smith'), false);
select test.eq('typed: staff get a To do to check it', (select count(*) from tasks where task_type = 'signature_name_review' and booking_id = test.r48b('a') and queue = 'cs'), 1::bigint);

-- ---------------------------------------------------------------- 4. the second booking: prefilled, signed in one tap
insert into test.r48 select 'b', (app.submit_booking_request(test.r48_req('b', 60, '[]'::jsonb)) ->> 'booking_id')::uuid;
select test.eq('fixtures: the same renter books again', (select count(distinct renter_id) from bookings where id in (test.r48b('a'), test.r48b('b'))), 1::bigint);
select test.eq('prefill: what the renter gave before (licence, insurer and policy of the last booking, the drivers, the initials, a saved signature)',
  (select concat_ws('/', p ->> 'licence_number', p ->> 'insurer_name', p ->> 'policy_number', p ->> 'date_of_birth', p ->> 'city', p -> 'drivers_before' -> 0 ->> 'full_name', p ->> 'initials', p ->> 'saved_signature')
     from public.renter_prefill(test.r48b('b'), test.r48u('b')) p),
  'R4800-00000-00404/Example Mutual/TEST-POLICY-48/1991-04-04/Toronto/Dee Driver/RR/true');
select test.throws('prefill: only the renter of the booking', format($$select public.renter_prefill(%L, %L)$$, test.r48b('b'), test.id('r48_cs')), 'for the renter of the booking');
select test.eq('prefill: never readable by a signed-in user directly',
  has_function_privilege('authenticated', 'public.renter_prefill(uuid, uuid)', 'execute')::text || '/' || has_function_privilege('authenticated', 'public.server_esign_use_saved(uuid, text, text, text)', 'execute')::text, 'false/false');

select test.r48_open('b');
insert into r48_x values ('sb', test.r48_session(test.r48_signer('b', 'renter'), false));
insert into r48_x select 'ip', (public.server_esign_start(jsonb_build_object('context', 'rental_agreement', 'signer_ref', test.r48_signer('b', 'renter'), 'method', 'remote', 'documents', '[{"title":"other","sha256":"y"}]'::jsonb)) ->> 'id');
update esign_sessions set method = 'in_person' where id = (select v::uuid from r48_x where k = 'ip');
select test.throws('saved: never on a staff member''s device', format($$select public.server_esign_use_saved(%L, 'signature')$$, (select v from r48_x where k = 'ip')), 'No saved signature');
select test.eq('saved: the signing page offers the saved signature, the saved initials and the initials',
  (select (j ->> 'saved_signature') || '/' || (j ->> 'saved_initials') || '/' || (j ->> 'initials') from public.server_esign_saved((select v::uuid from r48_x where k = 'sb')) j), 'true/true/RR');
select test.eq('saved: one tap initials every key term',
  (select jsonb_array_length(j -> 'initials') = jsonb_array_length(j -> 'required_initials') from public.server_esign_use_saved((select v::uuid from r48_x where k = 'sb'), 'initials', '203.0.113.9', 'test') j), true);
select test.eq('saved: one tap puts the signature in the session: ready to sign',
  (select (j ->> 'signature') || '/' || (j ->> 'ready') from public.server_esign_use_saved((select v::uuid from r48_x where k = 'sb'), 'signature', '203.0.113.9', 'test') j), 'drawn/true');
select test.eq('saved: the steps are in the trail, marked saved',
  (select count(*) filter (where kind = 'signature') || '/' || (count(*) filter (where kind = 'initial') > 0) from esign_events where session_id = (select v::uuid from r48_x where k = 'sb') and (detail ->> 'saved')::boolean), '1/true');
select test.lives('saved: the renter signs with it (the page sends the saved key)',
  format($$select public.renter_sign_agreement(test.r48b('b'), test.r48u('b'), 'I sign.', repeat('a', 64), test.r48_consents(), null, %L, '203.0.113.7', 'test')$$, (select v from r48_x where k = 'stroke2')));
select test.eq('saved: the second agreement carries the same signature',
  (select s.provider_signature from signature_records s join rental_agreement_signers g on g.signature_record_id = s.id join rental_agreements a on a.id = g.agreement_id where a.booking_id = test.r48b('b') and g.signer_role = 'renter'),
  (select v from r48_x where k = 'stroke2'));

-- ---------------------------------------------------------------- 5. the saved signature is the renter's alone
select test.throws('saved: never for an additional driver',
  format($$select public.server_esign_use_saved(%L, 'signature')$$, test.r48_session((select g.id from rental_agreement_signers g join rental_agreements a on a.id = g.agreement_id where a.booking_id = test.r48b('a') and g.signer_role = 'additional_driver'))),
  'No saved signature');

-- ---------------------------------------------------------------- 6. the card in the renter's name (2912)
select test.eq('card: a middle name, a shortened first name, an initial, accents, order and hyphens match',
  (select bool_and(app.card_name_matches(c, n)) from (values ('ALEX J RETURNING', 'Alexander Returning'), ('R RETURNING', 'Rae Returning'), ('RETURNING/RAE', 'Rae Returning'),
     ('RENEE DUBE', 'Renée Dubé'), ('M HUSSEIN-ALI', 'Mohammed Ali'), ('Maria Garcia Lopez', 'Maria Lopez')) v(c, n)), true);
select test.eq('card: another person or a nickname does not match', (select bool_or(app.card_name_matches(c, n)) from (values ('Jane Doe', 'Rae Returning'), ('BOB SMITH', 'Robert Smith')) v(c, n)), false);
insert into payment_methods (renter_id, cardholder_name, card_brand, card_last4, is_credit, funding)
select renter_id, x.n, 'visa', x.l, true, 'credit' from bookings, (values ('RAE M RETURNING', '1111'), ('SAM OTHER', '2222')) x(n, l) where id = test.r48b('b');
update bookings set card_on_file_id = (select id from payment_methods where card_last4 = '1111' and renter_id = bookings.renter_id) where id = test.r48b('b');
select test.eq('card: a tolerant match raises nothing', (select count(*) from tasks where task_type = 'card_name_review' and booking_id = test.r48b('b')), 0::bigint);
update bookings set card_on_file_id = (select id from payment_methods where card_last4 = '2222' and renter_id = bookings.renter_id) where id = test.r48b('b');
select test.eq('card: a name that still differs does not block: staff get "Check the name on the card"',
  (select count(*) from tasks where task_type = 'card_name_review' and booking_id = test.r48b('b') and status = 'open' and queue = 'cs'), 1::bigint);
select test.eq('card: credit card coverage is not refused for the name (staff review), and says it does not match',
  (select (j ->> 'problem') is null and not (j ->> 'name_matches')::boolean from app.card_coverage_check(test.r48b('b')) j), true);
select test.throws('accept: only staff', format($$select public.staff_accept_card_name(%L, %L, 'looks fine')$$, test.r48u('b'), test.r48b('b')), 'Only an Admin or staff');
select test.throws('accept: a short reason is required', format($$select public.staff_accept_card_name(%L, %L, ' ')$$, test.id('r48_cs'), test.r48b('b')), 'why this card is fine');
select test.lives('accept: staff who verify bookings accept the card with a reason', format($$select public.staff_accept_card_name(%L, %L, 'Spouse card, licence seen')$$, test.id('r48_cs'), test.r48b('b')));
select test.eq('accept: logged on the history with the reason, the To do closed, the card now counts as in the name',
  (select (select count(*) from booking_events e where e.booking_id = test.r48b('b') and e.details ->> 'what' = 'card_name_accepted' and e.details ->> 'reason' = 'Spouse card, licence seen')
       || '/' || (select count(*) from tasks where task_type = 'card_name_review' and booking_id = test.r48b('b') and status = 'open')
       || '/' || (app.card_coverage_check(test.r48b('b')) ->> 'name_matches')), '1/0/true');
update program_settings set card_name_check = false;
select test.eq('setting: off, the rule is off entirely', app.card_name_ok(test.r48b('a'), 'Somebody Else', 'Rae Returning'), true);
update program_settings set card_name_check = true;
select test.eq('setting: on by default', (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'card_name_check'), 'true');

update program_settings set esign_strict = w.esign_strict, esign_code_required = w.esign_code_required, booking_licence_required = w.booking_licence_required,
       amend_without_signature = w.amend_without_signature from r48_was w;
