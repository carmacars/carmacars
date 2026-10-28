-- 0185: paid before the renter signs. A renter approved an offer online and left the pay page without signing or paying;
-- staff take the rental and the fees in cash at the office ("The rental and fees", amount empty): both parts are
-- recorded in one step and the booking is confirmed, waiting for the renter's signature; the car is not released until
-- they sign; they sign in person on the staff member's device and CarmaCars countersigns at once (the signed copy is
-- queued). A renter who signed before paying is countersigned on the parts paid another way. Fixtures start with "pb".
select test.suite('99 paid before signing');

select test.mk_user('pb_admin', 'admin');
select test.mk_user('pb_cs', 'va', 'cs');
update staff_profiles set single_limit_cents = 500000 where user_id = test.id('pb_cs');

create table test.pb (k text primary key, v jsonb);
create function test.pbv(p text) returns jsonb language sql stable as $$ select v from test.pb where k = p $$;
create function test.pbb(p text) returns bookings language sql stable security definer as $$
  select * from public.bookings where id = coalesce((test.pbv(p) ->> 'booking_id')::uuid, (test.pbv(p) ->> 'id')::uuid) $$;
create function test.pbu(p text) returns uuid language sql stable security definer as $$
  select r.user_id from public.renters r where r.id = (test.pbb(p)).renter_id $$;
do $$
declare i integer;
begin
  for i in 1 .. 2 loop
    insert into test.pb select 'car' || i, app.vehicle_add(test.id('pb_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1XFCXPB00000000' || lpad(i::text, 2, '0'),
      'plate', 'PBC00' || i, 'year', 2024, 'make', 'Kia', 'model', 'K5', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
  end loop;
end $$;
-- an offer paid by card online, the deposit by card, with a fee (a renter of 22: the young driver fee): the rental part and the fees part
create function test.pb_offer(p_key text, p_car text, p_email text, p_from interval) returns void language plpgsql as $$
declare v_driver uuid; k text;
begin
  insert into test.pb select p_key, app.door(test.id('pb_admin'), 'aal2', 'ops_do', 'offer_create', jsonb_build_object(
    'vehicle_id', (test.pbv(p_car) ->> 'vehicle_id')::uuid, 'pickup_at', date_trunc('hour', now()) + p_from, 'return_at', date_trunc('hour', now()) + p_from + interval '3 days',
    'renter', jsonb_build_object('full_name', 'Paula Before', 'email', p_email, 'mobile', '(289) 555-0' || (100 + length(p_key))::text, 'date_of_birth', (now() - interval '22 years')::date),
    'coverage_option', 2, 'rental_pay_method', 'card', 'deposit_pay_method', 'card', 'channels', jsonb_build_object('email', false, 'text', false)));
  v_driver := (select bd.driver_id from booking_drivers bd where bd.booking_id = (test.pbb(p_key)).id and bd.role = 'renter');
  foreach k in array array['licence_front', 'licence_back', 'selfie'] loop
    perform app.register_verification_upload((test.pbb(p_key)).id, test.pbu(p_key), k, v_driver, 'renters/pb/' || p_key || '-' || k || '-' || gen_random_uuid() || '.jpg', repeat('e', 64), 'image/jpeg', null, 'identity');
  end loop;
  perform public.renter_save_details(test.pbu(p_key), jsonb_build_object('licence_number', 'P1234-12345-12345', 'licence_issuer', 'ON', 'licence_class', 'G',
    'licence_expiry', (now() + interval '3 years')::date), (test.pbb(p_key)).id);
  perform public.renter_approve_offer((test.pbb(p_key)).id, (test.pbb(p_key)).current_offer_version, test.pbu(p_key));
end $$;
create function test.pb_consents() returns jsonb language sql immutable as $$
  select '[{"code":"tracking_disabling","version":"v","text":"t"},{"code":"identity_verification","version":"v","text":"t"},{"code":"electronic_signature","version":"v","text":"t"},{"code":"card_authorization","version":"v","text":"t"}]'::jsonb $$;
create function test.pb_open(p text) returns numeric language sql stable security definer as $$
  select app.booking_part_open((test.pbb(p)).id, 'rental') + app.booking_part_open((test.pbb(p)).id, 'fees') $$;

-- ================================================================ 1. paid in cash, not signed: recorded whole, confirmed
select test.pb_offer('b1', 'car1', 'paula.before@example.test', interval '5 days');
select public.renter_open_agreement((test.pbb('b1')).id, test.pbu('b1'), 'rental-test', repeat('e', 64), 'bookings/pb/b1.pdf');
select test.eq('approved, not signed, not paid; no card saved', (select b.status || '/' || a.status || '/' || (b.card_on_file_id is null)
  from test.pbb('b1') b join rental_agreements a on a.booking_id = b.id and a.status <> 'voided'), 'pending_payment/open/true');
select test.ok('the booking has a rental part and a fees part open', app.booking_part_open((test.pbb('b1')).id, 'rental') > 0 and app.booking_part_open((test.pbb('b1')).id, 'fees') > 0);
insert into test.pb select 'open1', jsonb_build_object('cents', test.pb_open('b1'));

-- a part fails: nothing of the payment stays (one transaction)
select test.throws('over the single payment limit: refused whole', $$select app.door(test.id('pb_cs'), 'aal2', 'ops_do', 'record_booking_payment',
  jsonb_build_object('booking', (test.pbb('b1')).booking_number, 'covers', 'both', 'method', 'cash', 'amount_cents', 900000))$$, null);
select test.eq('refused: no payment recorded', (select count(*) from manual_payments where booking_id = (test.pbb('b1')).id), 0::bigint);

insert into test.pb select 'p1', app.door(test.id('pb_cs'), 'aal2', 'ops_do', 'record_booking_payment',
  jsonb_build_object('booking', (test.pbb('b1')).booking_number, 'covers', 'both', 'method', 'cash'));
select test.eq('the rental and fees in cash, amount empty: both parts recorded, the whole amount, nothing open',
  (select count(*) || '/' || string_agg(covers, ',' order by covers) || '/' || sum(amount_cents) from manual_payments where booking_id = (test.pbb('b1')).id and voided_at is null)
    || '/' || test.pb_open('b1'),
  '2/fees,rental/' || (test.pbv('open1') ->> 'cents') || '/0');
select test.eq('the answer: recorded and confirmed, waiting for the signature',
  (test.pbv('p1') ->> 'ok') || '/' || (test.pbv('p1') ->> 'confirmed') || '/' || (test.pbv('p1') #>> '{confirm,awaiting_signature}') || '/' || jsonb_array_length(test.pbv('p1') -> 'parts'),
  'true/true/true/2');
select test.eq('confirmed (paid), the agreement still waits for the renter; no card saved',
  (select b.status || '/' || s.status || '/' || (b.card_on_file_id is null) from test.pbb('b1') b join signature_requests s on s.id = b.signature_request_id), 'confirmed/sent/true');
select test.eq('the confirmation says it waits for the signature', (select details ->> 'awaiting_signature' from booking_events where booking_id = (test.pbb('b1')).id and kind = 'confirmed'), 'true');
select test.eq('awaiting signature on the booking (the handover ready check and the lists read it)', app.booking_awaiting_signature((test.pbb('b1')).id), true);
select test.eq('the confirmation task is done', (select count(*) from tasks where booking_id = (test.pbb('b1')).id and task_type = 'confirm_offline_booking' and status = 'open'), 0::bigint);
select test.eq('Sign now on this device: the renter still signs, paid already',
  (select (x ->> 'paid_unsigned') || '/' || (x #>> '{agreement,status}') || '/' || (select count(*) from jsonb_array_elements(x -> 'signers') g where g ->> 'role' = 'renter' and g ->> 'signed_at' is null)
     from (select app.door(test.id('pb_cs'), 'aal2', 'ops_read', 'in_person_signing', jsonb_build_object('booking', (test.pbb('b1')).id)) x) q), 'true/open/1');

-- ================================================================ 2. the car is not released before the renter signs
select test.throws('check-out refused: the renter has not signed', $$update bookings set status = 'on_rent' where id = (test.pbb('b1')).id$$, 'has not signed');

-- ================================================================ 3. the renter signs on the staff device: countersigned now
insert into test.pb select 'sign1', app.door(test.id('pb_cs'), 'aal2', 'ops_do', 'sign_in_person', jsonb_build_object(
  'booking', (test.pbb('b1')).id, 'signer', (select g.id from rental_agreement_signers g join rental_agreements a on a.id = g.agreement_id
                                               where a.booking_id = (test.pbb('b1')).id and a.status = 'open' and g.signer_role = 'renter'),
  'typed_name', 'Paula Before', 'sha', repeat('e', 64), 'consent_text', 'I agree', 'consents', test.pb_consents(), 'device', 'test device',
  'identity', jsonb_build_object('name_confirmed', true, 'licence_seen', true)));
select test.eq('signed in person: the agreement is completed (countersigned) at once', test.pbv('sign1') ->> 'agreement_status', 'completed');
select test.eq('the countersignature is CarmaCars'', automatic, after the renter''s',
  (select string_agg(s.signer_role || ':' || s.method, ',' order by s.signed_at, s.signer_role desc) from signature_records s join test.pbb('b1') b on s.signature_request_id = b.signature_request_id),
  'renter:typed,carmacars:automatic');
select test.eq('the request is completed; no longer awaiting the signature', (select s.status from signature_requests s where s.id = (test.pbb('b1')).signature_request_id)
  || '/' || app.booking_awaiting_signature((test.pbb('b1')).id), 'completed/false');
select test.eq('the signed copy is queued for the renter', (select count(*) from pdf_jobs where kind = 'renter_signed_copy' and ref = (test.pbb('b1')).id and status = 'queued'), 1::bigint);
select test.eq('the renter gets the signed agreement email', (select count(*) from app_events where code = 'renter_agreement_signed' and (payload ->> 'booking_id')::uuid = (test.pbb('b1')).id), 1::bigint);
select test.eq('signed: the signature guard lets the check-out go on', app.booking_confirmed_unsigned((test.pbb('b1')).id), false);

-- ================================================================ 4. signed before paying (the pay page left), paid in parts another way
select test.pb_offer('b2', 'car2', 'paula.signed@example.test', interval '9 days');
select public.renter_open_agreement((test.pbb('b2')).id, test.pbu('b2'), 'rental-test', repeat('f', 64), 'bookings/pb/b2.pdf');
select public.renter_sign_agreement((test.pbb('b2')).id, test.pbu('b2'), 'I agree', repeat('f', 64), test.pb_consents(), 'Paula Before');
select test.eq('signed online, not paid', (select b.status || '/' || a.status from test.pbb('b2') b join rental_agreements a on a.booking_id = b.id and a.status <> 'voided'), 'pending_payment/signed');
insert into test.pb select 'p2a', app.door(test.id('pb_cs'), 'aal2', 'ops_do', 'record_booking_payment',
  jsonb_build_object('booking', (test.pbb('b2')).booking_number, 'covers', 'rental', 'method', 'e_transfer', 'reference', 'PB2RENT'));
select test.eq('the rental alone: recorded, not confirmed (the fees are open)', (test.pbv('p2a') ->> 'confirmed') || '/' || (test.pbb('b2')).status, 'false/pending_payment');
insert into test.pb select 'p2b', app.door(test.id('pb_cs'), 'aal2', 'ops_do', 'record_booking_payment',
  jsonb_build_object('booking', (test.pbb('b2')).booking_number, 'covers', 'fees', 'method', 'cash'));
select test.eq('the fees after: confirmed and countersigned on the parts paid (no single payment of the whole amount)',
  (test.pbv('p2b') ->> 'confirmed') || '/' || (select b.status || '/' || s.status from test.pbb('b2') b join signature_requests s on s.id = b.signature_request_id), 'true/confirmed/completed');
select test.eq('signed before confirming: not waiting for a signature', (select details ->> 'awaiting_signature' from booking_events where booking_id = (test.pbb('b2')).id and kind = 'confirmed')
  || '/' || app.booking_awaiting_signature((test.pbb('b2')).id), 'false/false');
select test.eq('the same e-Transfer reference again is the same payment', (app.door(test.id('pb_cs'), 'aal2', 'ops_do', 'record_booking_payment',
  jsonb_build_object('booking', (test.pbb('b2')).booking_number, 'covers', 'rental', 'method', 'e_transfer', 'reference', 'pb2rent')) ->> 'repeat'), 'true');
