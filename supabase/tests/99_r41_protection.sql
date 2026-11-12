-- 99: change a booking's protection in one step (migration 2540): staff choose any of the three options with a required reason,
-- the price follows, the renter is told once; the renter changes it on their booking page (the Protection Plan at once, their own
-- insurance or card coverage before pickup, leaving the Protection Plan by a request with proof that customer service reviews);
-- the same rules for both. Fixtures start with "pr".
select test.suite('99 r41 protection');
select set_config('app.paper_fixture', 'on', false);

select test.mk_user('pr_admin', 'admin');
select test.mk_user('pr_cs', 'va', 'cs');
select test.mk_user('pr_sales', 'va', 'sales');
select test.mk_user('pr_fin', 'va', 'finance');
update staff_profiles set single_limit_cents = 900000 where user_id in (test.id('pr_cs'), test.id('pr_sales'), test.id('pr_fin'));
create temp table pr_prog as select id, weekend_premium_bps, staff_may_edit_fees from program_settings;
update program_settings set weekend_premium_bps = 0, staff_may_edit_fees = true where id = (app.settings()).id;

create table test.pr (k text primary key, v jsonb);
grant select on test.pr to authenticated, service_role;
create function test.prv(p text) returns jsonb language sql stable as $$ select v from test.pr where k = p $$;
create function test.prb(p text) returns bookings language sql stable security definer as $$
  select * from public.bookings where id = coalesce((test.prv(p) ->> 'booking_id')::uuid, (test.prv(p) ->> 'id')::uuid) $$;
create function test.pru(p text) returns uuid language sql stable security definer as $$
  select r.user_id from public.renters r where r.id = (test.prb(p)).renter_id $$;
do $$
declare i integer;
begin
  for i in 1 .. 3 loop
    insert into test.pr select 'car' || i, app.vehicle_add(test.id('pr_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1XFCXPR00000000' || lpad(i::text, 2, '0'),
      'plate', 'PRT00' || i, 'year', 2024, 'make', 'Kia', 'model', 'K5', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
  end loop;
end $$;
create function test.prreq(p_car text, p_from interval, p_to interval, p_n integer) returns jsonb language sql stable as $$
  select jsonb_build_object('vehicle_id', (test.prv(p_car) ->> 'vehicle_id')::uuid, 'pickup_at', date_trunc('hour', now()) + p_from, 'return_at', date_trunc('hour', now()) + p_to,
    'renter', jsonb_build_object('full_name', 'Pia Protect', 'email', 'pia.protect' || p_n || '@example.test', 'mobile', '(289) 555-084' || p_n, 'date_of_birth', '1990-04-05'),
    'coverage_option', 2, 'sales_choice', 'sourced', 'channels', jsonb_build_object('email', true, 'text', false),
    'rental_pay_method', 'e_transfer', 'deposit_pay_method', 'cash') $$;
create function test.pr_confirm(p text) returns void language plpgsql as $$
declare v_driver uuid := (select bd.driver_id from booking_drivers bd where bd.booking_id = (test.prb(p)).id and bd.role = 'renter');
  k text;
begin
  foreach k in array array['licence_front', 'licence_back', 'selfie'] loop
    perform app.register_verification_upload((test.prb(p)).id, test.pru(p), k, v_driver, 'renters/pr/' || p || '-' || k || '-' || gen_random_uuid() || '.jpg', repeat('e', 64), 'image/jpeg', null, 'identity');
  end loop;
  perform public.renter_save_details(test.pru(p), jsonb_build_object('licence_number', 'N1234-12345-12345', 'licence_issuer', 'ON', 'licence_class', 'G',
    'licence_expiry', (now() + interval '3 years')::date), (test.prb(p)).id);
  perform public.renter_approve_offer((test.prb(p)).id, 1, test.pru(p));
  perform app.door(test.id('pr_cs'), 'aal2', 'ops_do', 'record_booking_payment', jsonb_build_object('booking', (test.prb(p)).booking_number, 'covers', 'rental', 'method', 'e_transfer', 'reference', 'PR-ET-' || p));
  update bookings set status = 'confirmed' where id = (test.prb(p)).id;
end $$;
create function test.pr_line(p text) returns bigint language sql stable security definer as $$
  select coalesce(sum(amount_cents), 0) from public.booking_line_items where booking_id = (test.prb(p)).id and charge_type = 'coverage_sold' and stage = 'booking' and voided_at is null $$;
create function test.pr_mails(p text) returns bigint language sql stable security definer as $$
  select count(*) from public.app_events where entity_id = (test.prb(p)).id and code = 'renter_coverage_switched' $$;
create function test.pr_do(p_user text, p text, p_to integer, p_reason text default 'Renter called to change it', p_extra jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select app.door(test.id(p_user), 'aal2', 'ops_do', 'protection_change', jsonb_build_object('booking', (test.prb(p)).booking_number, 'to', p_to, 'reason', p_reason) || p_extra) $$;
-- two cards on the list: one covers these cars, one has no rental car damage coverage
insert into card_rental_coverage (country, issuer, card, coverage, max_msrp_cents, network, cdw_included, source_url, note)
values ('US', 'PR Test Bank', 'Covered Visa', 'primary', 6500000, 'visa', 'yes', 'https://example.test/covered', 'test'),
       ('US', 'PR Test Bank', 'Bare Visa', 'none', null, 'visa', 'no', 'https://example.test/bare', 'test');
create function test.prcard(p text) returns uuid language sql stable as $$ select id from card_rental_coverage where issuer = 'PR Test Bank' and card = p $$;
update vehicles set estimated_value_cents = 3000000 where id in (select (v ->> 'vehicle_id')::uuid from test.pr where k like 'car%');
update fee_defaults set amount_cents = 4000, note = 'test' where fee_type_code = 'coverage_sold' and vehicle_class is null and effective_to is null;

-- ================================================================ 1. staff: the three options, a reason, the price
insert into test.pr select 'b1', app.door(test.id('pr_cs'), 'aal2', 'ops_do', 'offer_create', test.prreq('car1', interval '6 days', interval '10 days', 1));
select test.pr_confirm('b1');
select test.eq('confirmed on card coverage', (test.prb('b1')).status::text || '/' || (test.prb('b1')).coverage_option, 'confirmed/2');
insert into test.pr select 'q1', app.door(test.id('pr_cs'), 'aal2', 'ops_read', 'protection_options', jsonb_build_object('booking', (test.prb('b1')).booking_number));
select test.eq('the dialog lists the three options, the current one marked', (select string_agg((x ->> 'option') || ':' || (x ->> 'current') || ':' || (x ->> 'available'), ',') from jsonb_array_elements(test.prv('q1') -> 'options') x),
  '1:false:true,2:true:false,3:false:true');
select test.eq('the plan: its price, a day, and the total with HST it adds', (test.prv('q1') ->> 'plan_cents') || '/' || (test.prv('q1') ->> 'plan_daily_cents') || '/' ||
  ((test.prv('q1') -> 'options' -> 2 ->> 'change_cents')::bigint = 4000 + public.calc_hst(4000, (test.prb('b1')).hst_bps)), '4000/' || round(4000.0 / (test.prb('b1')).billable_days)::bigint || '/true');
select test.eq('no deposit rule follows the coverage: the deposit does not change', (test.prv('q1') -> 'options' -> 2 ->> 'deposit_change_cents'), '0');
select test.eq('each option says what the renter provides', (test.prv('q1') -> 'options' -> 0 ->> 'needs') like '%OPCF 27%' and (test.prv('q1') -> 'options' -> 1 ->> 'needs') like '%coverage letter%', true);
select test.throws('a reason is required', format($$select test.pr_do('pr_cs', 'b1', 3, '')$$), 'Give the reason');
select test.throws('sales does not change a confirmed booking', format($$select test.pr_do('pr_sales', 'b1', 3)$$), 'request or an offer');
select test.throws('finance does not change it', format($$select test.pr_do('pr_fin', 'b1', 3)$$), 'Only an Admin');
select test.throws('the option it has is refused', format($$select test.pr_do('pr_cs', 'b1', 2)$$), 'already');

-- card coverage to own insurance: no price change, a proof task, the renter told once
select test.throws('OPCF 27 needs the renter''s acknowledgement to upload the policy', format($$select test.pr_do('pr_cs', 'b1', 1)$$), 'upload your auto policy');
insert into test.pr select 'c1', test.pr_do('pr_cs', 'b1', 1, 'Card does not cover a car of this value', '{"opcf27_ack": true}');
select test.eq('now OPCF 27, same total', (test.prb('b1')).coverage_option || '/' || (test.prv('c1') ->> 'difference_cents'), '1/0');
select test.eq('recorded with the reason, by staff', (select direction || '/' || side || '/' || note from coverage_switches where id = (test.prv('c1') ->> 'switch_id')::uuid), 'to_own/staff/Card does not cover a car of this value');
select test.eq('customer service gets the OPCF 27 proof task', (select title from tasks where booking_id = (test.prb('b1')).id and task_type = 'coverage_proof_needed' and status = 'open'), format('Booking %s: get the renter''s OPCF 27 proof', (test.prb('b1')).booking_number));
select test.eq('the renter is emailed once', test.pr_mails('b1'), 1::bigint);
select test.eq('the audit log has it', (select count(*) from audit_log where entity_table = 'coverage_switches' and entity_id = test.prv('c1') ->> 'switch_id'), 1::bigint);

-- to the Protection Plan: the line, the balance to collect (never charged by itself), one more email
insert into test.pr select 'c2', test.pr_do('pr_admin', 'b1', 3, 'Renter wants the plan');
select test.eq('on the plan, $40.00 line', (test.prb('b1')).coverage_option || '/' || test.pr_line('b1'), '3/4000');
select test.eq('the difference is a balance to collect', (test.prv('c2') ->> 'open_cents')::bigint, 4000 + public.calc_hst(4000, (test.prb('b1')).hst_bps));
select test.eq('no payment was made by the change', (select count(*) from payments where booking_id = (test.prb('b1')).id and created_at > now() - interval '1 second' and kind = 'charge' and purpose <> 'booking_total'), 0::bigint);
select test.eq('emailed once more', test.pr_mails('b1'), 2::bigint);
-- back to card coverage although the plan came from OPCF 27: it lands on the option asked for
select test.throws('card coverage needs a card from the list', format($$select test.pr_do('pr_cs', 'b1', 2)$$), 'Pick your credit card');
select test.throws('a card without coverage is refused, the other options named', format($$select test.pr_do('pr_cs', 'b1', 2, 'x', jsonb_build_object('card', %L, 'card_ack', true))$$, test.prcard('Bare Visa')), 'choose OPCF 27');
select test.throws('a covering card still needs the acknowledgement to pay with it', format($$select test.pr_do('pr_cs', 'b1', 2, 'x', jsonb_build_object('card', %L))$$, test.prcard('Covered Visa')), 'pay for the rental with this card');
select test.throws('customer service cannot override the rule', format($$select test.pr_do('pr_cs', 'b1', 2, 'x', '{"override": true}')$$), 'Only an Admin overrides');
insert into test.pr select 'c3', test.pr_do('pr_admin', 'b1', 2, 'Renter showed their card letter', '{"override": true}');
select test.eq('the Admin override is recorded with its reason', (select override_reason from coverage_switches where id = (test.prv('c3') ->> 'switch_id')::uuid) || '/' || (test.prv('c3') ->> 'override'), 'Renter showed their card letter/true');
select test.eq('lands on card coverage, the plan line gone', (test.prb('b1')).coverage_option || '/' || test.pr_line('b1') || '/' || (select to_option from coverage_switches where id = (test.prv('c3') ->> 'switch_id')::uuid), '2/0/2');
select test.eq('the proof task asks for the card proof', (select title from tasks where booking_id = (test.prb('b1')).id and task_type = 'coverage_proof_needed' and status = 'open'), format('Booking %s: get the renter''s card coverage proof', (test.prb('b1')).booking_number));
select test.eq('one email for that change', test.pr_mails('b1'), 3::bigint);
select test.eq('the r35 switch reads the same rules', app.coverage_switch_block(test.prb('b1'), 'card'), 'This booking is not on the Protection Plan');

-- ================================================================ 2. the renter
insert into test.pr select 'b2', app.door(test.id('pr_cs'), 'aal2', 'ops_do', 'offer_create', test.prreq('car2', interval '6 days', interval '9 days', 2));
select test.pr_confirm('b2');
insert into test.pr select 'rq', public.renter_protection_options((test.prb('b2')).id, test.pru('b2'));
select test.eq('the renter sees the three options; the plan applies now', (test.prv('rq') -> 'options' -> 2 ->> 'applies') || '/' || (test.prv('rq') -> 'options' -> 2 ->> 'available'), 'now/true');
select test.eq('the renter does not see staff names or the proof path', (test.prv('rq') ->> 'side'), 'renter');
select test.throws('another renter cannot change it', format($$select public.renter_protection_change(%L, %L, '{"to": 3}')$$, (test.prb('b2')).id, test.pru('b1')), null);
insert into test.pr select 'r1', public.renter_protection_change((test.prb('b2')).id, test.pru('b2'), '{"to": 3}');
select test.eq('the renter added the plan at once', (test.prb('b2')).coverage_option || '/' || test.pr_line('b2') || '/' || (test.prv('r1') ->> 'applied'), '3/4000/true');
select test.eq('the difference is the balance the renter pays on the booking page', (public.renter_balance((test.prb('b2')).id, test.pru('b2')) ->> 'balance_cents')::bigint, 4000 + public.calc_hst(4000, (test.prb('b2')).hst_bps));
select test.eq('recorded as the renter''s change', (select side from coverage_switches where id = (test.prv('r1') ->> 'switch_id')::uuid), 'renter');
select test.eq('the renter gets the email with the amount to pay', test.pr_mails('b2'), 1::bigint);

-- leaving the plan: proof and review
select test.throws('without proof it is refused', format($$select public.renter_protection_change(%L, %L, '{"to": 1, "opcf27_ack": true, "insurer_name": "Aviva", "policy_number": "P1", "policy_expiry": "2099-01-01"}')$$, (test.prb('b2')).id, test.pru('b2')), 'Add your proof');
select test.throws('a policy that ends before the return is refused', format($$select public.renter_protection_change(%L, %L, jsonb_build_object('to', 1, 'opcf27_ack', true, 'insurer_name', 'Aviva', 'policy_number', 'P1', 'policy_expiry', current_date, 'proof_path', %L))$$,
  (test.prb('b2')).id, test.pru('b2'), 'renters/' || test.pru('b2') || '/' || (test.prb('b2')).id || '/protection-x.pdf'), 'still be active');
insert into test.pr select 'r2', public.renter_protection_change((test.prb('b2')).id, test.pru('b2'), jsonb_build_object('to', 1, 'opcf27_ack', true, 'insurer_name', 'Aviva', 'policy_number', 'P-22', 'policy_expiry', '2099-01-01',
  'reason', 'I have my own policy', 'proof_path', 'renters/' || test.pru('b2') || '/' || (test.prb('b2')).id || '/protection-1.pdf', 'proof_mime', 'application/pdf'));
select test.eq('not applied yet: a request in review, a task for customer service', (test.prv('r2') ->> 'applied') || '/' || (test.prb('b2')).coverage_option || '/' ||
  (select count(*) from tasks where booking_id = (test.prb('b2')).id and task_type = 'protection_change_review' and status = 'open'), 'false/3/1');
select test.eq('the booking page shows it pending', public.renter_protection_options((test.prb('b2')).id, test.pru('b2')) #>> '{request,status}', 'pending');
select test.throws('one request at a time', format($$select public.renter_protection_change(%L, %L, jsonb_build_object('to', 1, 'opcf27_ack', true, 'proof_path', %L))$$,
  (test.prb('b2')).id, test.pru('b2'), 'renters/' || test.pru('b2') || '/' || (test.prb('b2')).id || '/protection-2.pdf'), 'waiting for our review');
select test.throws('sales does not review it', format($$select app.door(%L, 'aal2', 'ops_do', 'protection_review', jsonb_build_object('request', %L, 'approve', true))$$, test.id('pr_sales'), test.prv('r2') ->> 'request_id'), 'Customer service or an Admin');
insert into test.pr select 'a2', app.door(test.id('pr_cs'), 'aal2', 'ops_do', 'protection_review', jsonb_build_object('request', test.prv('r2') ->> 'request_id', 'approve', true));
select test.eq('approved: OPCF 27, the plan line gone, the coverage confirmed', (test.prb('b2')).coverage_option || '/' || test.pr_line('b2') || '/' || ((test.prb('b2')).coverage_confirmed_at is not null), '1/0/true');
select test.eq('the request and its task are closed', (select status from protection_requests where id = (test.prv('r2') ->> 'request_id')::uuid) || '/' ||
  (select count(*) from tasks where booking_id = (test.prb('b2')).id and task_type in ('protection_change_review', 'coverage_proof_needed') and status in ('open', 'in_progress', 'waiting')), 'approved/0');
select test.eq('the policy from the request is the confirmed proof', (select policy_number from coverage_proofs where booking_id = (test.prb('b2')).id and status = 'confirmed' and coverage_option = 1), 'P-22');
select test.eq('the renter is emailed once for it', test.pr_mails('b2'), 2::bigint);
select test.eq('the audit log has the request', (select count(*) from audit_log where entity_table = 'protection_requests' and entity_id = test.prv('r2') ->> 'request_id') > 0, true);

-- a declined request needs the reason, and can be withdrawn
select public.renter_protection_change((test.prb('b2')).id, test.pru('b2'), '{"to": 3}');
insert into test.pr select 'r3', public.renter_protection_change((test.prb('b2')).id, test.pru('b2'), jsonb_build_object('to', 1, 'opcf27_ack', true, 'insurer_name', 'Aviva', 'policy_number', 'P-22', 'policy_expiry', '2099-01-01',
  'proof_path', 'renters/' || test.pru('b2') || '/' || (test.prb('b2')).id || '/protection-3.pdf'));
select test.throws('declining needs a reason', format($$select app.door(%L, 'aal2', 'ops_do', 'protection_review', jsonb_build_object('request', %L, 'approve', false))$$, test.id('pr_cs'), test.prv('r3') ->> 'request_id'), 'Say why');
select app.door(test.id('pr_cs'), 'aal2', 'ops_do', 'protection_review', jsonb_build_object('request', test.prv('r3') ->> 'request_id', 'approve', false, 'note', 'The pink slip is unreadable'));
select test.eq('declined: still on the plan, the reason on the renter''s page', (test.prb('b2')).coverage_option || '/' || (public.renter_protection_options((test.prb('b2')).id, test.pru('b2')) #>> '{request,decision_note}'), '3/The pink slip is unreadable');
insert into test.pr select 'r4', public.renter_protection_change((test.prb('b2')).id, test.pru('b2'), jsonb_build_object('to', 1, 'opcf27_ack', true, 'insurer_name', 'Aviva', 'policy_number', 'P-23', 'policy_expiry', '2099-01-01',
  'proof_path', 'renters/' || test.pru('b2') || '/' || (test.prb('b2')).id || '/protection-4.pdf'));
select public.renter_protection_change((test.prb('b2')).id, test.pru('b2'), '{"withdraw": true}');
select test.eq('withdrawn: its task is closed', (select status from protection_requests where id = (test.prv('r4') ->> 'request_id')::uuid) || '/' ||
  (select count(*) from tasks where booking_id = (test.prb('b2')).id and task_type = 'protection_change_review' and status = 'open'), 'withdrawn/0');

-- ================================================================ 3. the rules shared by both paths
select test.eq('during the rental the renter can add the plan but not leave it', coalesce(app.protection_block(jsonb_populate_record(test.prb('b2'), '{"status": "on_rent", "added_mode": null}'), 1, 'renter'), '') like 'Your rental has started%', true);
select test.eq('during the rental staff still can (0890)', app.protection_block(jsonb_populate_record(test.prb('b2'), '{"status": "on_rent", "added_mode": null}'), 1, 'staff') is null, true);
select test.eq('an offer: the renter chooses when approving', app.protection_block(jsonb_populate_record(test.prb('b2'), '{"status": "offered"}'), 1, 'renter') like 'You choose your protection%', true);
insert into incidents (kind, vehicle_id, booking_id, description) values ('accident', (test.prb('b2')).vehicle_id, (test.prb('b2')).id, 'test');
select test.throws('after damage is reported the staff change is refused', format($$select test.pr_do('pr_admin', 'b2', 1, 'Damage test', '{"opcf27_ack": true}')$$), 'Damage was reported');
select test.throws('and the renter''s too', format($$select public.renter_protection_change(%L, %L, jsonb_build_object('to', 1, 'opcf27_ack', true, 'insurer_name', 'A', 'policy_number', 'P', 'policy_expiry', '2099-01-01', 'proof_path', %L))$$,
  (test.prb('b2')).id, test.pru('b2'), 'renters/' || test.pru('b2') || '/' || (test.prb('b2')).id || '/protection-5.pdf'), 'Damage was reported');
select test.throws('and the r35 switch', format($$select app.coverage_switch(%L, jsonb_build_object('booking', %L, 'to', 'card'))$$, test.id('pr_admin'), (test.prb('b2')).booking_number), 'Damage was reported');

-- ================================================================ 4. an offer: staff change it, the offer goes out again once
insert into test.pr select 'b3', app.door(test.id('pr_cs'), 'aal2', 'ops_do', 'offer_create', test.prreq('car3', interval '8 days', interval '11 days', 3));
insert into test.pr select 'c4', test.pr_do('pr_sales', 'b3', 1, 'Renter has OPCF 27', '{"opcf27_ack": true}');
select test.eq('the offer is version 2 on OPCF 27, sent once', (test.prb('b3')).status::text || '/' || (test.prb('b3')).current_offer_version || '/' || (test.prb('b3')).coverage_option || '/' ||
  (select count(*) from app_events where entity_id = (test.prb('b3')).id and code like 'renter_offer%'), 'offered/2/1/2');
select test.eq('no change email on an offer', test.pr_mails('b3'), 0::bigint);

-- ================================================================ 5. the coverage order for the renter: card, then OPCF 27, then the plan
select test.throws('the renter cannot pick card coverage without a card from the list', format($$select public.renter_protection_change(%L, %L, '{"to": 2}')$$, (test.prb('b3')).id, test.pru('b3')), null);
select test.eq('the request form''s check: a covering card is covered, the other is not', (public.server_coverage_choice_check(jsonb_build_object('vehicle_id', (test.prv('car3') ->> 'vehicle_id'), 'option', 2,
  'pickup_at', now() + interval '5 days', 'return_at', now() + interval '8 days', 'card', test.prcard('Covered Visa'), 'card_ack', true)) ->> 'result') || '/' ||
  (public.server_coverage_choice_check(jsonb_build_object('vehicle_id', (test.prv('car3') ->> 'vehicle_id'), 'option', 2,
  'pickup_at', now() + interval '5 days', 'return_at', now() + interval '8 days', 'card', test.prcard('Bare Visa'), 'card_ack', true)) ->> 'result'), 'covered/not_covered');
select test.eq('covered and acknowledged: no problem', public.server_coverage_choice_check(jsonb_build_object('vehicle_id', (test.prv('car3') ->> 'vehicle_id'), 'option', 2,
  'pickup_at', now() + interval '5 days', 'return_at', now() + interval '8 days', 'card', test.prcard('Covered Visa'), 'card_ack', true)) ->> 'problem', null);
select test.throws('the website request with card coverage and no card is refused', format($$select app.submit_booking_request(%L::jsonb)$$,
  jsonb_build_object('vehicle_id', test.prv('car3') ->> 'vehicle_id', 'pickup_at', date_trunc('hour', now()) + interval '20 days', 'return_at', date_trunc('hour', now()) + interval '22 days',
    'coverage_option', 2, 'booking_type', 'renter', 'request_key', gen_random_uuid(), 'details', '{"source": "web"}'::jsonb,
    'renter', jsonb_build_object('full_name', 'Wes Web', 'email', 'wes.web@example.test', 'mobile', '(289) 555-0849', 'date_of_birth', '1990-04-05', 'licence_class', 'G', 'licence_issuer', 'ON'),
    'consents', jsonb_build_object('terms', jsonb_build_object('accepted', true, 'version', 'v', 'text', 't'), 'privacy', jsonb_build_object('accepted', true, 'version', 'v', 'text', 't')))), null);
select test.eq('nothing was kept from the refused request', (select count(*) from bookings where vehicle_id = (test.prv('car3') ->> 'vehicle_id')::uuid and pickup_at > now() + interval '19 days'), 0::bigint);

delete from card_rental_coverage where issuer = 'PR Test Bank';
update fee_defaults set amount_cents = null where fee_type_code = 'coverage_sold' and note = 'test';
update program_settings p set weekend_premium_bps = w.weekend_premium_bps, staff_may_edit_fees = w.staff_may_edit_fees from pr_prog w where w.id = p.id;
update rate_cards set weekend_rate_cents = weekend_rate_cents where effective_to is null and weekend_rate_cents <= daily_rate_cents;
