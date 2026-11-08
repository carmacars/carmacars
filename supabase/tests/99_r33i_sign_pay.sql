-- 99: release 33 part I (migration 0750, docs/changes/2026-11-07-r33-sign-and-pay.md): one rule for signing and paying
-- (each way the sign page and the payment used to disagree), deposit keep reasons, the card fee of a debit deposit, expired
-- card holds and the hold re-authorized by the job. Fixtures start with "ri" and "RI-".
select test.suite('99 r33i sign and pay');

select test.mk_user('ri_admin', 'admin');
select test.mk_user('ri_cs', 'va', 'cs');
select test.mk_user('ri_fin', 'va', 'finance');
update staff_profiles set single_limit_cents = 500000 where user_id in (test.id('ri_cs'), test.id('ri_fin'));

create table test.ri (k text primary key, v jsonb);
create function test.riv(p text) returns jsonb language sql stable as $$ select v from test.ri where k = p $$;
create function test.rib(p text) returns bookings language sql stable security definer as $$
  select * from public.bookings where id = coalesce((test.riv(p) ->> 'booking_id')::uuid, (test.riv(p) ->> 'id')::uuid) $$;
create function test.riu(p text) returns uuid language sql stable security definer as $$
  select r.user_id from public.renters r where r.id = (test.rib(p)).renter_id $$;
-- what the renter's page reads (my_booking, as the renter)
create function test.ri_my(p text) returns jsonb language plpgsql as $$
declare v jsonb; n text := (test.rib(p)).booking_number; u uuid := test.riu(p);
begin
  perform test.login(u);
  v := public.my_booking(n);
  perform test.logout();
  return v;
end $$;
create function test.ri_state(p text) returns jsonb language sql stable as $$ select public.server_booking_sign_pay((test.rib(p)).id) $$;
create function test.ri_facts(p text) returns jsonb language sql stable as $$ select public.server_booking_payment_facts((test.rib(p)).id) $$;
-- the payment rule as it was before 0750 (signed or completed and for the approved offer version)
create function test.ri_old(p text) returns boolean language sql stable as $$ select (app.server_booking_payment_facts_pre0750((test.rib(p)).id) ->> 'agreement_signed')::boolean $$;
create function test.ri_sign(p text) returns void language plpgsql as $$
begin
  perform public.renter_sign_agreement((test.rib(p)).id, test.riu(p), 'I agree', (select a.document_sha256 from rental_agreements a where a.booking_id = (test.rib(p)).id and a.status = 'open'),
    '[{"code":"tracking_disabling","version":"v","text":"t"},{"code":"identity_verification","version":"v","text":"t"},{"code":"electronic_signature","version":"v","text":"t"},{"code":"card_authorization","version":"v","text":"t"}]'::jsonb, 'Rina Sign');
end $$;
create function test.ri_open(p text, p_sha text) returns void language plpgsql as $$
begin
  perform public.renter_open_agreement((test.rib(p)).id, test.riu(p), 'rental-test', repeat(p_sha, 64), 'bookings/ri/' || p || '-' || p_sha || '.pdf');
end $$;

do $$
declare i integer;
begin
  for i in 1 .. 2 loop
    insert into test.ri select 'car' || i, app.vehicle_add(test.id('ri_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1XFCXMM00000097' || lpad(i::text, 2, '0'),
      'plate', 'RI00' || i, 'year', 2024, 'make', 'Kia', 'model', 'K5', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
  end loop;
end $$;
create function test.ri_offer(p_car text, p_email text, p_mobile text, p_from interval) returns jsonb language sql as $$
  select app.door(test.id('ri_cs'), 'aal2', 'ops_do', 'offer_create', jsonb_build_object('vehicle_id', (test.riv(p_car) ->> 'vehicle_id')::uuid,
    'pickup_at', date_trunc('hour', now()) + p_from, 'return_at', date_trunc('hour', now()) + p_from + interval '3 days',
    'renter', jsonb_build_object('full_name', 'Rina Sign', 'email', p_email, 'mobile', p_mobile, 'date_of_birth', '1990-05-06'),
    'coverage_option', 1, 'sales_choice', 'sourced', 'channels', jsonb_build_object('email', false, 'text', false), 'notify', false)) $$;
create function test.ri_ready(p text) returns void language plpgsql as $$
declare v_driver uuid := (select bd.driver_id from booking_drivers bd where bd.booking_id = (test.rib(p)).id and bd.role = 'renter');
  k text;
begin
  foreach k in array array['licence_front', 'licence_back', 'selfie'] loop
    perform app.register_verification_upload((test.rib(p)).id, test.riu(p), k, v_driver, 'renters/ri/' || p || '-' || k || '-' || gen_random_uuid() || '.jpg', repeat('e', 64), 'image/jpeg', null, 'identity');
  end loop;
  perform public.renter_save_details(test.riu(p), jsonb_build_object('licence_number', 'R1234-12345-12345', 'licence_issuer', 'ON', 'licence_class', 'G',
    'licence_expiry', (now() + interval '3 years')::date), (test.rib(p)).id);
  perform public.renter_approve_offer((test.rib(p)).id, (test.rib(p)).current_offer_version, test.riu(p));
end $$;

-- ================================================================ 1a. CC-10080: the offer revised after the renter signed
insert into test.ri select 'b1', test.ri_offer('car1', 'rina.sign@example.test', '(289) 555-0841', interval '6 days');
select test.ri_ready('b1');
select test.eq('approved: the rule asks to sign, then pay', test.ri_state('b1') ->> 'step', 'sign');
select test.eq('the renter''s page carries the same rule', test.ri_my('b1') #>> '{sign_pay,step}', 'sign');
select test.ri_open('b1', 'a');
select test.ri_sign('b1');
select test.eq('signed for version 1: pay', test.ri_state('b1') ->> 'step' || '/' || (test.ri_facts('b1') ->> 'agreement_signed'), 'pay/true');
-- the state of CC-10080: version 2 of the offer approved while the agreement signed for version 1 stayed live (an
-- approval that opened no new agreement: staff on the renter's word, or the agreement's render failing after the approval)
update booking_offers set status = 'superseded' where booking_id = (test.rib('b1')).id and version = 1;
insert into booking_offers select (jsonb_populate_record(null::booking_offers, to_jsonb(o) || jsonb_build_object('id', gen_random_uuid(), 'version', 2, 'status', 'approved'))).*
  from booking_offers o where o.booking_id = (test.rib('b1')).id and o.version = 1;
update bookings set current_offer_version = 2, offer_approved_version = 2 where id = (test.rib('b1')).id;
select test.eq('version 2 approved: waiting for payment', (test.rib('b1')).status::text || '/' || (test.rib('b1')).offer_approved_version, 'pending_payment/2');
-- the disagreement (before 0750): the page saw a signature, the payment refused it
select test.ok('the page''s agreement has the renter''s signature (the old sign page sent the renter to pay)', test.ri_my('b1') #>> '{agreement,renter_signed_at}' is not null);
select test.eq('the old payment rule said not signed (the loop)', test.ri_old('b1'), false);
-- one rule now: sign again, for the current version, never sent to pay
select test.eq('the rule: sign, the signature is stale', (test.ri_state('b1') ->> 'step') || '/' || (test.ri_state('b1') ->> 'stale'), 'sign/true');
select test.eq('the renter''s page says the same', (test.ri_my('b1') #>> '{sign_pay,step}') || '/' || (test.ri_my('b1') #>> '{sign_pay,stale}'), 'sign/true');
select test.eq('the payment agrees: not signed', test.ri_facts('b1') ->> 'agreement_signed', 'false');
select test.ri_open('b1', 'b');
select test.eq('a fresh agreement for version 2; the old one voided', (select string_agg(coalesce(offer_version::text, '-') || ':' || status, ',' order by opened_at) from rental_agreements where booking_id = (test.rib('b1')).id), '1:voided,2:open');
select test.eq('open: still sign, no longer stale', (test.ri_state('b1') ->> 'step') || '/' || (test.ri_state('b1') ->> 'stale'), 'sign/false');
select test.ri_sign('b1');
select test.eq('signed for version 2: pay, and the payment agrees', (test.ri_state('b1') ->> 'step') || '/' || (test.ri_facts('b1') ->> 'agreement_signed') || '/' || test.ri_old('b1'), 'pay/true/true');
select test.eq('what is due', (test.ri_state('b1') ->> 'due_cents')::bigint, (test.rib('b1')).renter_due_at_booking_cents);

-- ================================================================ 1b. a driver who must sign before payment has not
insert into test.ri select 'b2', test.ri_offer('car2', 'rina.two@example.test', '(289) 555-0842', interval '12 days');
select test.ri_ready('b2');
select test.ri_open('b2', 'c');
select test.ri_sign('b2');
insert into rental_agreement_signers (agreement_id, signer_role, signer_name, signer_email, required_before_payment, booking_driver_id)
select a.id, 'additional_driver', 'Dana Driver', 'dana.driver@example.test', true, (select d.id from booking_drivers d where d.booking_id = a.booking_id limit 1)
  from rental_agreements a where a.booking_id = (test.rib('b2')).id and a.status = 'signed';
select test.eq('the old payment rule said signed (the card was then authorized and refused)', test.ri_old('b2'), true);
select test.eq('the rule: waiting for the driver, who is named', (test.ri_state('b2') ->> 'step') || '/' || (test.ri_state('b2') #>> '{waiting,0}'), 'drivers/Dana Driver');
select test.eq('the payment agrees: not signed yet', test.ri_facts('b2') ->> 'agreement_signed', 'false');
update rental_agreement_signers set signed_at = now(), signature_record_id = (select s.id from signature_records s where s.signer_role = 'renter' order by s.signed_at desc limit 1) where signer_name = 'Dana Driver';
select test.eq('the driver signed: pay', (test.ri_state('b2') ->> 'step') || '/' || (test.ri_facts('b2') ->> 'agreement_signed'), 'pay/true');

-- ================================================================ 1c. an agreement without an offer version
update rental_agreements set offer_version = null where booking_id = (test.rib('b2')).id and status = 'signed';
select test.eq('a standard booking: an agreement with no version is not for the approved offer (sign again)', (test.ri_state('b2') ->> 'step') || '/' || (test.ri_state('b2') ->> 'stale') || '/' || test.ri_old('b2'), 'sign/true/false');
-- a rental added while underway with a payment link (0074): its agreement has no version, the database's live payment accepts it
-- written straight into that state (the guards of the status are not what is tested here)
set session_replication_role = replica;
update bookings set added_by_staff = true, added_mode = 'in_progress', payment_mode = 'link', status = 'on_rent', handed_over_at = now() where id = (test.rib('b2')).id;
set session_replication_role = origin;
select test.eq('added while underway: the link is due', app.booking_link_due(test.rib('b2')), true);
select test.eq('the old payment rule refused it (an approved version on the booking)', test.ri_old('b2'), false);
select test.eq('the rule: signed, pay with the link', (test.ri_state('b2') ->> 'step') || '/' || (test.ri_facts('b2') ->> 'agreement_signed'), 'pay/true');
select test.eq('other bookings: none', public.server_booking_sign_pay(gen_random_uuid()), null::jsonb);

-- ================================================================ 2. deposit keep reasons
select test.mk_owner('ri_o');
select test.mk_vehicle('RIA', 'ri_o'); select test.mk_vehicle('RIB', 'ri_o'); select test.mk_vehicle('RIC', 'ri_o'); select test.mk_vehicle('RID', 'ri_o');
select test.mk_renter('ri_r');
select test.mk_renter('ri_debit');
insert into payment_method_secrets (payment_method_id, processor, processor_customer_id, processor_method_id) values (test.id('card:ri_r'), 'stripe', 'cus_ri', 'pm_ri');
insert into payment_method_secrets (payment_method_id, processor, processor_customer_id, processor_method_id) values (test.id('card:ri_debit'), 'stripe', 'cus_rid', 'pm_rid');
update payment_methods set funding = 'debit', is_credit = false where id = test.id('card:ri_debit');
create function test.ri_hold(p text, p_expires timestamptz) returns uuid language plpgsql as $$
declare v_pay uuid := test.id('hold:' || p);
begin
  insert into payments (id, booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at)
  select v_pay, b.id, b.renter_id, 'deposit', 'hold', 'card', 100000, 'authorized', now() - interval '5 days' from bookings b where b.id = test.id('booking:' || p);
  insert into payment_processor_details (payment_id, processor, processor_payment_id) values (v_pay, 'stripe', 'pi_' || p);
  insert into deposits (booking_id, amount_cents, method, status, hold_payment_id, taken_at, hold_expires_at)
  values (test.id('booking:' || p), 100000, 'card_hold', 'held', v_pay, now() - interval '5 days', p_expires);
  return v_pay;
end $$;
create function test.ri_dep(p text) returns deposits language sql stable as $$ select * from deposits where booking_id = test.id('booking:' || p) $$;
select test.mk_booking('RI-1', 'RIA', 'ri_r', to_char(now() at time zone 'America/Toronto' + interval '3 days', 'YYYY-MM-DD 10:00'), to_char(now() at time zone 'America/Toronto' + interval '6 days', 'YYYY-MM-DD 10:00'), 'confirmed');
select test.ri_hold('RI-1', now() + interval '6 days');
select test.throws('a reason not on the list is refused', $$select app.door(test.id('ri_fin'), 'aal2', 'ops_do', 'hold_action_begin', jsonb_build_object('booking', 'RI-1', 'action', 'capture', 'amount_cents', 5000, 'reason_code', 'vibes'))$$, 'from the list');
select test.throws('Other needs its note', $$select app.door(test.id('ri_fin'), 'aal2', 'ops_do', 'hold_action_begin', jsonb_build_object('booking', 'RI-1', 'action', 'capture', 'amount_cents', 5000, 'reason_code', 'other'))$$, 'Other');
insert into test.ri select 'k1', app.door(test.id('ri_fin'), 'aal2', 'ops_do', 'hold_action_begin', jsonb_build_object('booking', 'RI-1', 'action', 'capture', 'amount_cents', 5000, 'reason_code', 'fuel', 'reason_note', 'A quarter tank'));
insert into test.ri select 'k2', app.door(test.id('ri_fin'), 'aal2', 'ops_do', 'hold_action_finish', jsonb_build_object('deposit', test.riv('k1') ->> 'deposit_id', 'action', 'capture', 'amount_cents', 5000, 'ok', true,
  'reason_code', 'fuel', 'reason_note', 'A quarter tank'));
select test.eq('kept with its reason: the code and the note on the payment and the deposit event',
  (select reason_code || '/' || reason_note from payments where id = (test.riv('k2') ->> 'payment_id')::uuid) || '/' ||
  (select reason_code || ':' || note from deposit_events where payment_id = (test.riv('k2') ->> 'payment_id')::uuid and kind = 'captured'), 'fuel/A quarter tank/fuel:Fuel: A quarter tank');
select test.eq('the Money tab reads the reason in words', public.server_booking_charge_reasons(test.id('booking:RI-1')) #>> '{reasons,0,label}', 'Fuel');
select test.eq('the renter''s receipt names the reason', app.pdf_facts('receipt', test.riv('k2') ->> 'payment_id', null) ->> 'reason', 'Fuel: A quarter tank');
-- a later charge on the saved card, with its reason
select test.mk_booking('RI-2', 'RIB', 'ri_r', to_char(now() at time zone 'America/Toronto' - interval '6 days', 'YYYY-MM-DD 10:00'), to_char(now() at time zone 'America/Toronto' - interval '3 days', 'YYYY-MM-DD 10:00'), 'returned');
insert into test.ri select 'c1', app.door(test.id('ri_fin'), 'aal2', 'ops_do', 'card_charge_begin', jsonb_build_object('booking', 'RI-2', 'amount_cents', 2500, 'covers', 'later', 'reason_code', 'tolls', 'reason_note', '407 ETR'));
select test.eq('the later charge: its reason in words for the processor, the code on the payment', (test.riv('c1') ->> 'reason') || '/' || (select reason_code from payments where id = (test.riv('c1') ->> 'payment_id')::uuid), 'Tolls: 407 ETR/tolls');

-- ================================================================ 3. the card fee of a deposit charged to a debit card
select test.mk_booking('RI-3', 'RIC', 'ri_debit', to_char(now() at time zone 'America/Toronto' + interval '2 days', 'YYYY-MM-DD 10:00'), to_char(now() at time zone 'America/Toronto' + interval '5 days', 'YYYY-MM-DD 10:00'), 'confirmed');
select test.eq('the fee: 2.9% and $0.30 by default', public.server_debit_deposit_fee(100000), 2930::bigint);
insert into test.ri select 'f1', app.door(test.id('ri_fin'), 'aal2', 'ops_do', 'card_charge_begin', jsonb_build_object('booking', 'RI-3', 'covers', 'deposit', 'reason', 'Security deposit'));
select test.eq('the debit deposit is charged with its fee, apart', (test.riv('f1') ->> 'amount_cents') || '/' || (test.riv('f1') ->> 'deposit_cents') || '/' || (test.riv('f1') ->> 'fee_cents'), '102930/100000/2930');
select app.door(test.id('ri_fin'), 'aal2', 'ops_do', 'card_charge_finish', jsonb_build_object('payment', test.riv('f1') ->> 'payment_id', 'ok', true, 'intent_id', 'pi_rif1', 'reason', 'Security deposit'));
select test.eq('the deposit is the deposit only (its refund returns the deposit only)', (select method || '/' || amount_cents || '/' || captured_cents from test.ri_dep('RI-3')), 'charged/100000/100000');
select test.eq('the receipt lists the deposit and the non-refundable fee', (select string_agg(x ->> 'label', ' | ') from jsonb_array_elements(app.pdf_facts('receipt', test.riv('f1') ->> 'payment_id', null) -> 'lines') x),
  'Security deposit (refundable) | Card processing fee for a debit deposit (non-refundable)');
select test.eq('the Money tab has the fee', (public.server_booking_charge_reasons(test.id('booking:RI-3')) #>> '{fees,0,fee_cents}')::bigint, 2930::bigint);
update program_settings set debit_deposit_fee_bps = 0, debit_deposit_fee_cents = 0;
select test.eq('an Admin can set it to nothing', public.server_debit_deposit_fee(100000), 0::bigint);
update program_settings set debit_deposit_fee_bps = 290, debit_deposit_fee_cents = 30;

-- ================================================================ 4. an expired hold, and the hold re-authorized by the job
-- Stripe refuses the capture: the hold lapsed (canceled)
select test.mk_booking('RI-4', 'RID', 'ri_r', to_char(now() at time zone 'America/Toronto' + interval '1 days', 'YYYY-MM-DD 10:00'), to_char(now() at time zone 'America/Toronto' + interval '4 days', 'YYYY-MM-DD 10:00'), 'confirmed');
select test.ri_hold('RI-4', now() + interval '3 days');
insert into test.ri select 'x1', app.door(test.id('ri_fin'), 'aal2', 'ops_do', 'hold_action_begin', jsonb_build_object('booking', 'RI-4', 'action', 'capture', 'amount_cents', 5000, 'reason_code', 'damage'));
insert into test.ri select 'x2', app.door(test.id('ri_fin'), 'aal2', 'ops_do', 'hold_action_finish', jsonb_build_object('deposit', test.riv('x1') ->> 'deposit_id', 'action', 'capture', 'amount_cents', 5000, 'ok', false, 'lapsed', true, 'error', 'The card hold has expired.'));
select test.eq('lapsed: a plain sentence, no processor words', test.riv('x2') ->> 'reason', 'The card hold has expired, so nothing can be kept from it. Charge the card on file instead.');
select test.eq('the deposit is marked: Hold expired (expiry now), still held, nothing kept', (select (hold_lapsed_at is not null)::text || '/' || (hold_expires_at <= now())::text || '/' || status || '/' || captured_cents from test.ri_dep('RI-4')), 'true/true/held/0');
select test.throws('keep it again: refused before Stripe', $$select app.door(test.id('ri_fin'), 'aal2', 'ops_do', 'hold_action_begin', jsonb_build_object('booking', 'RI-4', 'action', 'capture', 'amount_cents', 5000, 'reason_code', 'damage'))$$, 'has expired');
-- the guard sweep marks a hold past its expiry
update deposits set hold_lapsed_at = null, hold_expires_at = now() - interval '1 hour' where booking_id = test.id('booking:RI-1') and status = 'held';
select public.server_deposit_guard_sweep();
-- RI-1's hold was captured above; a fresh one past its expiry
select test.mk_booking('RI-5', 'RIA', 'ri_r', to_char(now() at time zone 'America/Toronto' + interval '20 days', 'YYYY-MM-DD 10:00'), to_char(now() at time zone 'America/Toronto' + interval '22 days', 'YYYY-MM-DD 10:00'), 'confirmed');
select test.ri_hold('RI-5', now() - interval '2 hours');
select public.server_deposit_guard_sweep();
select test.ok('the sweep marks a hold past its expiry', (test.ri_dep('RI-5')).hold_lapsed_at is not null);
-- about 24 hours before expiry: the job re-authorizes
select test.mk_booking('RI-6', 'RIB', 'ri_r', to_char(now() at time zone 'America/Toronto' - interval '2 days', 'YYYY-MM-DD 10:00'), to_char(now() at time zone 'America/Toronto' + interval '3 days', 'YYYY-MM-DD 10:00'), 'on_rent');
select test.ri_hold('RI-6', now() + interval '20 hours');
select test.ok('due: the hold expiring within 24 hours', exists (select 1 from jsonb_array_elements(public.server_deposit_reauth_due(50)) x where x ->> 'booking_number' = 'RI-6'));
select test.ok('the deposit job is due', (public.server_jobs_due() ->> 'deposits')::boolean);
select test.ok('a hold expiring later is not due yet', not exists (select 1 from jsonb_array_elements(public.server_deposit_reauth_due(50)) x where x ->> 'booking_number' in ('RI-1', 'RI-4', 'RI-5')));
insert into test.ri select 'j1', public.server_deposit_reauth_begin((test.ri_dep('RI-6')).id);
select test.eq('begin: the saved card and what is held', (test.riv('j1') ->> 'ok') || '/' || (test.riv('j1') ->> 'customer_id') || '/' || (test.riv('j1') ->> 'amount_cents') || '/' || (test.riv('j1') ->> 'old_intent'), 'true/cus_ri/100000/pi_RI-6');
select test.ok('tried once: not due again for 6 hours', not exists (select 1 from jsonb_array_elements(public.server_deposit_reauth_due(50)) x where x ->> 'booking_number' = 'RI-6'));
select test.eq('a second begin at once is skipped', public.server_deposit_reauth_begin((test.ri_dep('RI-6')).id) ->> 'skip', 'true');
insert into test.ri select 'j2', public.server_deposit_reauth_finish(jsonb_build_object('deposit', (test.ri_dep('RI-6')).id, 'amount_cents', 100000, 'ok', false, 'error', 'The card was declined.'));
select test.eq('failed: not re-authorized', test.riv('j2') ->> 'ok', 'false');
select test.ok('an alert to Finance and an Admin', exists (select 1 from app_events e where e.code like 'staff_alert_%' and e.payload ->> 'rule' = 'deposit_reauth_failed' and e.entity_id = (test.ri_dep('RI-6')).id));
select test.ok('the history says so in words', exists (select 1 from booking_events e where e.booking_id = test.id('booking:RI-6') and e.note like 'The deposit hold was not re-authorized automatically: The card was declined.%'));
update deposits set reauth_tried_at = null where booking_id = test.id('booking:RI-6');
insert into test.ri select 'j3', public.server_deposit_reauth_begin((test.ri_dep('RI-6')).id);
insert into test.ri select 'j4', public.server_deposit_reauth_finish(jsonb_build_object('deposit', (test.ri_dep('RI-6')).id, 'amount_cents', 100000, 'ok', true, 'intent_id', 'pi_RI-6-b',
  'capture_before', extract(epoch from now() + interval '7 days')::bigint));
select test.eq('re-authorized: a new hold, held a week more', (test.riv('j4') ->> 'ok') || '/' || ((test.ri_dep('RI-6')).hold_expires_at > now() + interval '6 days')::text || '/' ||
  (select processor_payment_id from payment_processor_details where payment_id = (test.ri_dep('RI-6')).hold_payment_id), 'true/true/pi_RI-6-b');
select test.ok('no longer due', not exists (select 1 from jsonb_array_elements(public.server_deposit_reauth_due(50)) x where x ->> 'booking_number' = 'RI-6'));
select test.throws('the job''s functions are the server''s only', $$set local role authenticated; select public.server_deposit_reauth_due(1)$$, 'permission denied');
