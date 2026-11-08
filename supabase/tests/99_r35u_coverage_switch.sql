-- 99: switch a booking between card coverage and the Protection Plan (migration 0890): an offer and an active booking, both ways,
-- the totals, the card coverage proof and tasks cleared and restored, the history and audit, the email, who may. Fixtures start with "cs".
select test.suite('99 r35u coverage switch');
select set_config('app.paper_fixture', 'on', false);

select test.mk_user('cs_admin', 'admin');
select test.mk_user('cs_cs', 'va', 'cs');
select test.mk_user('cs_sales', 'va', 'sales');
select test.mk_user('cs_fleet', 'va', 'fleet');
select test.mk_user('cs_fin', 'va', 'finance');
select test.mk_renter('cs_rita');
update staff_profiles set single_limit_cents = 900000 where user_id in (test.id('cs_cs'), test.id('cs_sales'), test.id('cs_fin'));
update program_settings set weekend_premium_bps = 0, staff_may_edit_fees = true where id = (app.settings()).id;

create table test.cs (k text primary key, v jsonb);
grant select on test.cs to authenticated, service_role;
create function test.csv(p text) returns jsonb language sql stable as $$ select v from test.cs where k = p $$;
create function test.csb(p text) returns bookings language sql stable security definer as $$
  select * from public.bookings where id = coalesce((test.csv(p) ->> 'booking_id')::uuid, (test.csv(p) ->> 'id')::uuid) $$;
create function test.csu(p text) returns uuid language sql stable security definer as $$
  select r.user_id from public.renters r where r.id = (test.csb(p)).renter_id $$;
do $$
declare i integer;
begin
  for i in 1 .. 4 loop
    insert into test.cs select 'car' || i, app.vehicle_add(test.id('cs_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1XFCXSW00000000' || lpad(i::text, 2, '0'),
      'plate', 'CSW00' || i, 'year', 2024, 'make', 'Kia', 'model', 'K5', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
  end loop;
end $$;
create function test.cscar(p text) returns uuid language sql stable as $$ select (test.csv(p) ->> 'vehicle_id')::uuid $$;
create function test.csreq(p_car text, p_from interval, p_to interval, p jsonb default '{}'::jsonb) returns jsonb language sql stable as $$
  select jsonb_build_object('vehicle_id', test.cscar(p_car), 'pickup_at', date_trunc('hour', now()) + p_from, 'return_at', date_trunc('hour', now()) + p_to,
    'renter', jsonb_build_object('full_name', 'Cora Switch', 'email', 'cora.switch@example.test', 'mobile', '(289) 555-0831', 'date_of_birth', '1991-02-03'),
    'coverage_option', 2, 'sales_choice', 'sourced', 'channels', jsonb_build_object('email', true, 'text', false)) || p $$;
create function test.cs_licence(p text) returns void language plpgsql as $$
declare v_driver uuid := (select bd.driver_id from booking_drivers bd where bd.booking_id = (test.csb(p)).id and bd.role = 'renter');
  k text;
begin
  foreach k in array array['licence_front', 'licence_back', 'selfie'] loop
    perform app.register_verification_upload((test.csb(p)).id, test.csu(p), k, v_driver, 'renters/cs/' || p || '-' || k || '-' || gen_random_uuid() || '.jpg', repeat('e', 64), 'image/jpeg', null, 'identity');
  end loop;
  perform public.renter_save_details(test.csu(p), jsonb_build_object('licence_number', 'N1234-12345-12345', 'licence_issuer', 'ON', 'licence_class', 'G',
    'licence_expiry', (now() + interval '3 years')::date), (test.csb(p)).id);
end $$;
-- the Protection Plan is sold at $40.00 a rental (the existing coverage_sold fee, its default)
update fee_defaults set amount_cents = 4000, note = 'test' where fee_type_code = 'coverage_sold' and vehicle_class is null and effective_to is null;
create function test.cs_consents() returns jsonb language sql immutable as $$
  select '[{"code":"tracking_disabling","version":"v","text":"t"},{"code":"identity_verification","version":"v","text":"t"},{"code":"electronic_signature","version":"v","text":"t"},{"code":"card_authorization","version":"v","text":"t"}]'::jsonb $$;
-- a card coverage proof in review and the task that waits for it
create function test.cs_proof(p text) returns void language plpgsql as $$
declare v_cp uuid;
begin
  insert into coverage_proofs (booking_id, coverage_option, status, card_issuer, card_last4, renter_confirmed_at, submitted_at)
  values ((test.csb(p)).id, 2, 'submitted', 'Visa', '4242', now(), now()) returning id into v_cp;
  perform app.raise_task(p_type => 'verify_renter', p_title => 'Documents to review', p_booking => (test.csb(p)).id, p_renter => (test.csb(p)).renter_id,
    p_related_table => 'coverage_proofs', p_related_id => v_cp, p_dedupe => 'verify_renter:' || (test.csb(p)).id);
end $$;
create function test.cs_line(p text) returns bigint language sql stable security definer as $$
  select coalesce(sum(amount_cents), 0) from public.booking_line_items where booking_id = (test.csb(p)).id and charge_type = 'coverage_sold' and stage = 'booking' and voided_at is null $$;

-- ================================================================ 1. an offer
insert into test.cs select 'o1', app.door(test.id('cs_cs'), 'aal2', 'ops_do', 'offer_create', test.csreq('car1', interval '5 days', interval '8 days', '{"message": "Here is your offer"}'));
select test.eq('an offer on card coverage, version 1', (select status || '/' || current_offer_version || '/' || coverage_option from test.csb('o1')), 'offered/1/2');
select test.eq('no Protection Plan line yet', test.cs_line('o1'), 0::bigint);
select test.cs_proof('o1');
select test.eq('the proof is in review and its task is open',
  (select count(*) from coverage_proofs where booking_id = (test.csb('o1')).id and status = 'submitted') || '/' || (select count(*) from tasks where booking_id = (test.csb('o1')).id and task_type = 'verify_renter' and status = 'open'), '1/1');
insert into test.cs select 'st1', app.door(test.id('cs_cs'), 'aal2', 'ops_read', 'coverage_switch_state', jsonb_build_object('booking', (test.csb('o1')).booking_number));
select test.eq('the page may switch to the plan, prices it and cannot go back', (test.csv('st1') ->> 'may') || '/' || (test.csv('st1') #>> '{to_plan,available}') || '/' || (test.csv('st1') #>> '{to_card,available}') || '/' || (test.csv('st1') #>> '{to_plan,amount_cents}'), 'true/true/false/4000');
select test.eq('the preview adds the plan with its HST to the total', (test.csv('st1') #>> '{to_plan,new_total_cents}')::bigint, (test.csb('o1')).total_due_at_booking_cents + (test.csv('st1') #>> '{to_plan,total_cents}')::bigint);

select test.throws('the renter does not switch their own booking here', format($$select app.coverage_switch(%L, jsonb_build_object('booking', %L, 'to', 'plan'))$$, test.csu('o1'), (test.csb('o1')).booking_number), 'Only an Admin');
select test.throws('finance does not switch it', format($$select app.coverage_switch(%L, jsonb_build_object('booking', %L, 'to', 'plan'))$$, test.id('cs_fin'), (test.csb('o1')).booking_number), 'Only an Admin');
select test.throws('back to card coverage is refused while it is on card coverage', format($$select app.coverage_switch(%L, jsonb_build_object('booking', %L, 'to', 'card'))$$, test.id('cs_cs'), (test.csb('o1')).booking_number), 'not on the Protection Plan');

insert into test.cs select 'sw1', app.door(test.id('cs_sales'), 'aal2', 'ops_do', 'coverage_switch', jsonb_build_object('booking', (test.csb('o1')).booking_number, 'to', 'plan', 'note', 'Your card does not cover this car'));
select test.eq('sales switched the offer: still offered, version 2, option 3', (select status || '/' || current_offer_version || '/' || coverage_option from test.csb('o1')), 'offered/2/3');
select test.eq('the Protection Plan line is on the offer: $40.00', test.cs_line('o1'), 4000::bigint);
select test.eq('the total rose by the plan and its HST', (test.csv('sw1') ->> 'difference_cents')::bigint, 4000 + public.calc_hst(4000, (test.csb('o1')).hst_bps));
select test.eq('the new offer total is the booking''s total', (test.csv('sw1') ->> 'total_after_cents')::bigint, (test.csb('o1')).total_due_at_booking_cents);
select test.eq('the renter gets the revised offer, version 2, by the offer email', (select string_agg(code, ',' order by id) from app_events where entity_id = (test.csb('o1')).id and code like 'renter_offer%'), 'renter_offer_ready,renter_offer_ready');
select test.eq('the old offer is superseded', (select string_agg(version || ':' || status, ',' order by version) from booking_offers where booking_id = (test.csb('o1')).id), '1:superseded,2:sent');
select test.eq('the card proof is lapsed and its task cleared', (select count(*) from coverage_proofs where booking_id = (test.csb('o1')).id and status = 'lapsed') || '/' || (select count(*) from tasks where booking_id = (test.csb('o1')).id and task_type = 'verify_renter' and status = 'open'), '1/0');
select test.eq('the switch is recorded with its totals', (select direction || '/' || from_option || '/' || to_option || '/' || booking_status || '/' || offer_version from coverage_switches where id = (test.csv('sw1') ->> 'switch_id')::uuid), 'to_plan/2/3/offered/2');
select test.eq('the booking history says what changed', (select count(*) from booking_events where booking_id = (test.csb('o1')).id and kind = 'adjusted' and details ->> 'coverage_switch' = test.csv('sw1') ->> 'switch_id'), 1::bigint);
select test.eq('the audit log has the switch', (select count(*) from audit_log where entity_table = 'coverage_switches' and entity_id = test.csv('sw1') ->> 'switch_id'), 1::bigint);
select test.eq('the renter''s coverage read shows the switch', (app.renter_coverage((test.csb('o1')).id) #>> '{last_switch,direction}') || '/' || (app.renter_coverage((test.csb('o1')).id) #>> '{last_switch,to_label}'), 'to_plan/the CarmaCars Protection Plan');
select test.throws('already on the plan', format($$select app.coverage_switch(%L, jsonb_build_object('booking', %L, 'to', 'plan'))$$, test.id('cs_admin'), (test.csb('o1')).booking_number), 'on the Protection Plan already');

-- and back: the proof and its task return, the plan line goes, a new version is sent
insert into test.cs select 'sw2', app.door(test.id('cs_fleet'), 'aal2', 'ops_do', 'coverage_switch', jsonb_build_object('booking', (test.csb('o1')).booking_number, 'to', 'card'));
select test.eq('back on card coverage: offered, version 3, option 2', (select status || '/' || current_offer_version || '/' || coverage_option from test.csb('o1')), 'offered/3/2');
select test.eq('the plan line is gone and the total is as before', test.cs_line('o1') || '/' || ((test.csv('sw2') ->> 'total_after_cents')::bigint = (test.csv('sw1') ->> 'total_before_cents')::bigint), '0/true');
select test.eq('the proof is in review again and its task is open again', (select count(*) from coverage_proofs where booking_id = (test.csb('o1')).id and status = 'submitted') || '/' || (select count(*) from tasks where booking_id = (test.csb('o1')).id and task_type = 'verify_renter' and status = 'open'), '1/1');
select test.eq('two switches in the history, newest first', (test.csv('st1') is not null) and (select string_agg(direction, ',' order by created_at, id) from coverage_switches where booking_id = (test.csb('o1')).id) = 'to_plan,to_card', true);

-- ================================================================ 2. a confirmed booking
insert into test.cs select 'o2', app.door(test.id('cs_cs'), 'aal2', 'ops_do', 'offer_create', test.csreq('car2', interval '6 days', interval '9 days', '{"rental_charge_cents": 25000, "price_reason": "Phone deal", "rental_pay_method": "e_transfer", "deposit_pay_method": "cash"}'));
select test.cs_licence('o2');
select public.renter_approve_offer((test.csb('o2')).id, 1, test.csu('o2'));
insert into test.cs select 'p2', app.door(test.id('cs_cs'), 'aal2', 'ops_do', 'record_booking_payment', jsonb_build_object('booking', (test.csb('o2')).booking_number, 'covers', 'rental', 'method', 'e_transfer', 'reference', 'CS-ET-0001'));
select test.eq('confirmed and paid on card coverage', (test.csb('o2')).status::text || '/' || (test.csb('o2')).coverage_option, 'confirmed/2');
select test.cs_proof('o2');
select test.throws('sales does not switch a confirmed booking', format($$select app.coverage_switch(%L, jsonb_build_object('booking', %L, 'to', 'plan'))$$, test.id('cs_sales'), (test.csb('o2')).booking_number), 'request or an offer');
update bookings set status = 'confirmed' where id = (test.csb('o2')).id;
insert into test.cs select 'tot2', jsonb_build_object('before', (test.csb('o2')).total_due_at_booking_cents);
insert into test.cs select 'sw3', app.door(test.id('cs_fleet'), 'aal2', 'ops_do', 'coverage_switch', jsonb_build_object('booking', (test.csb('o2')).booking_number, 'to', 'plan'));
select test.eq('confirmed stays confirmed on the plan', (test.csb('o2')).status::text || '/' || (test.csb('o2')).coverage_option, 'confirmed/3');
select test.eq('the plan line, $40.00 plus its HST, is added', test.cs_line('o2'), 4000::bigint);
select test.eq('the total follows', (test.csb('o2')).total_due_at_booking_cents, (test.csv('tot2') ->> 'before')::bigint + 4000 + public.calc_hst(4000, (test.csb('o2')).hst_bps));
select test.eq('the difference is open to collect, by the usual balance', (test.csv('sw3') ->> 'open_cents')::bigint, 4000 + public.calc_hst(4000, (test.csb('o2')).hst_bps));
select test.eq('only the plan line is open: the rental paid stays paid', app.booking_part_open((test.csb('o2')).id, 'rental'), 0::bigint);
select test.eq('the state read shows the open amount', (app.door(test.id('cs_cs'), 'aal2', 'ops_read', 'coverage_switch_state', jsonb_build_object('booking', (test.csb('o2')).booking_number)) ->> 'open_cents')::bigint, (test.csv('sw3') ->> 'open_cents')::bigint);
select test.eq('the card proof is lapsed; the verification task stays because the licence documents still wait for review', (select count(*) from coverage_proofs where booking_id = (test.csb('o2')).id and status = 'lapsed') || '/' || (select count(*) from tasks where booking_id = (test.csb('o2')).id and task_type = 'verify_renter' and status = 'open'), '1/1');
select test.eq('the readiness is not asking for card coverage proof any more', coalesce((app.booking_readiness((test.csb('o2')).id) -> 'missing') ? 'coverage.card_issuer', false), false);
select test.eq('the renter is emailed once: what changed, the price, what to do', (select count(*) from app_events where entity_id = (test.csb('o2')).id and code = 'renter_coverage_switched'), 1::bigint);
select test.eq('the email carries the rows and the money text',
  (select (app.notification_payload('renter_coverage_switched', e, '{}'::jsonb) -> 'change_rows' -> 1 ->> 'label') || '/' || ((app.notification_payload('renter_coverage_switched', e, '{}'::jsonb) ->> 'money_text') like '%more to pay%')::text
     from app_events e where e.entity_id = (test.csb('o2')).id and e.code = 'renter_coverage_switched'), 'Total with HST/true');
select test.eq('the booking history and the audit log record it', (select count(*) from booking_events where booking_id = (test.csb('o2')).id and details ->> 'coverage_switch' = test.csv('sw3') ->> 'switch_id') || '/' ||
  (select count(*) from audit_log where entity_table = 'coverage_switches' and entity_id = test.csv('sw3') ->> 'switch_id'), '1/1');

-- the difference is collected like any open amount; then the reverse gives it back
insert into test.cs select 'p3', app.door(test.id('cs_cs'), 'aal2', 'ops_do', 'record_booking_payment', jsonb_build_object('booking', (test.csb('o2')).booking_number, 'covers', 'fees', 'method', 'e_transfer', 'reference', 'CS-ET-0002'));
select test.eq('collected: nothing open', app.booking_part_open((test.csb('o2')).id, 'balance'), 0::bigint);
insert into test.cs select 'sw4', app.door(test.id('cs_admin'), 'aal2', 'ops_do', 'coverage_switch', jsonb_build_object('booking', (test.csb('o2')).booking_number, 'to', 'card', 'note', 'The renter chose their card again'));
select test.eq('back on card coverage: confirmed, option 2, the plan line gone', (test.csb('o2')).status::text || '/' || (test.csb('o2')).coverage_option || '/' || test.cs_line('o2'), 'confirmed/2/0');
select test.eq('the total is what it was', (test.csb('o2')).total_due_at_booking_cents, (test.csv('tot2') ->> 'before')::bigint);
select test.eq('the plan was paid: a refund waits for approval and finance has a task', (select count(*) from refunds where id = (test.csv('sw4') ->> 'refund_id')::uuid and status = 'pending_approval') || '/' ||
  (select count(*) from tasks where booking_id = (test.csb('o2')).id and task_type = 'change_refund' and status = 'open'), '1/1');
select test.eq('the card proof and its task came back', (select count(*) from coverage_proofs where booking_id = (test.csb('o2')).id and status = 'submitted') || '/' || (select count(*) from tasks where booking_id = (test.csb('o2')).id and task_type = 'verify_renter' and status = 'open'), '1/1');
select test.eq('the renter is emailed about the reverse too', (select count(*) from app_events where entity_id = (test.csb('o2')).id and code = 'renter_coverage_switched'), 2::bigint);

-- ================================================================ 3. a rental in progress, with the plan priced for the part left
insert into test.cs select 'o3', app.door(test.id('cs_cs'), 'aal2', 'ops_do', 'offer_create', test.csreq('car3', interval '6 days', interval '9 days', '{"rental_pay_method": "e_transfer", "deposit_pay_method": "cash"}'));
select test.cs_licence('o3');
select public.renter_approve_offer((test.csb('o3')).id, 1, test.csu('o3'));
select app.door(test.id('cs_cs'), 'aal2', 'ops_do', 'record_booking_payment', jsonb_build_object('booking', (test.csb('o3')).booking_number, 'covers', 'rental', 'method', 'e_transfer', 'reference', 'CS-ET-0003'));
select public.renter_open_agreement((test.csb('o3')).id, test.csu('o3'), 'rental-test', repeat('e', 64), 'bookings/cs/o3.pdf');
select public.renter_sign_agreement((test.csb('o3')).id, test.csu('o3'), 'I agree', repeat('e', 64), test.cs_consents(), 'Cora Switch');
update booking_drivers set identity_method = 'staff_review', identity_verified_on = app.today() where booking_id = (test.csb('o3')).id;
insert into coverage_proofs (booking_id, coverage_option, status, card_issuer, card_last4, confirmed_at, submitted_at) values ((test.csb('o3')).id, 2, 'confirmed', 'Visa', '4242', now(), now());
update bookings set coverage_confirmed_at = now() where id = (test.csb('o3')).id;
-- the handover itself (deposit, condition report, keys) is other tests' business: the rental is put on trip as the handover leaves it
set session_replication_role = replica;
update bookings set status = 'on_rent', pickup_at = now() - interval '1 day', return_at = now() + interval '2 days' where id = (test.csb('o3')).id;
set session_replication_role = origin;
select test.throws('the amount is for customer service or an Admin', format($$select app.coverage_switch(%L, jsonb_build_object('booking', %L, 'to', 'plan', 'plan_cents', 2500))$$, test.id('cs_fleet'), (test.csb('o3')).booking_number), 'Customer service or an Admin');
insert into test.cs select 'sw5', app.door(test.id('cs_cs'), 'aal2', 'ops_do', 'coverage_switch', jsonb_build_object('booking', (test.csb('o3')).booking_number, 'to', 'plan', 'plan_cents', 2500, 'note', 'Two days left'));
select test.eq('on rent: option 3, the plan for the part left ($25.00)', (test.csb('o3')).status::text || '/' || (test.csb('o3')).coverage_option || '/' || test.cs_line('o3'), 'on_rent/3/2500');
select test.eq('the signed agreement has a new version due: the coverage option and the price changed (rental terms 15.4)', (app.agreement_plan((test.csb('o3')).id) ->> 'state') || '/' ||
  (select bool_or(x ->> 'key' = 'coverage.option') from jsonb_array_elements(app.agreement_plan((test.csb('o3')).id) -> 'changes') x), 'version/true');
select test.eq('on rent the plan is active at once (the car is out): confirmed, the card proof lapsed', (test.csb('o3')).coverage_confirmed_at is not null and
  (select count(*) from coverage_proofs where booking_id = (test.csb('o3')).id and coverage_option = 3 and status = 'confirmed') = 1 and
  (select count(*) from coverage_proofs where booking_id = (test.csb('o3')).id and coverage_option = 2 and status = 'lapsed') = 1, true);
select test.eq('the amount to collect is the plan with its HST', (test.csv('sw5') ->> 'open_cents')::bigint, 2500 + public.calc_hst(2500, (test.csb('o3')).hst_bps));
select test.eq('unpaid plan going back: no refund, no finance task', (select (app.door(test.id('cs_admin'), 'aal2', 'ops_do', 'coverage_switch', jsonb_build_object('booking', (test.csb('o3')).booking_number, 'to', 'card')) ->> 'refund_id') is null), true);
select test.eq('back on card coverage while on rent: the line is gone, the confirmed card proof is back', test.cs_line('o3') || '/' || (test.csb('o3')).coverage_option || '/' || ((test.csb('o3')).coverage_confirmed_at is not null) || '/' ||
  (select count(*) from coverage_proofs where booking_id = (test.csb('o3')).id and coverage_option = 2 and status = 'confirmed'), '0/2/true/1');

-- ================================================================ 4. when it cannot be done
update fee_defaults set amount_cents = null where fee_type_code = 'coverage_sold' and note = 'test';
insert into test.cs select 'o4', app.door(test.id('cs_cs'), 'aal2', 'ops_do', 'offer_create', test.csreq('car4', interval '10 days', interval '12 days'));
select test.throws('no price for the Protection Plan: refused with the reason', format($$select app.coverage_switch(%L, jsonb_build_object('booking', %L, 'to', 'plan'))$$, test.id('cs_admin'), (test.csb('o4')).booking_number), 'no price');
select test.throws('a booking that is cancelled is refused', format($$select app.coverage_switch(%L, jsonb_build_object('booking', %L, 'to', 'plan'))$$, test.id('cs_admin'), (test.csb('o2')).booking_number || 'X'), 'not found');
set session_replication_role = replica;
update bookings set status = 'cancelled' where id = (test.csb('o4')).id;
set session_replication_role = origin;
select test.throws('a cancelled booking is refused', format($$select app.coverage_switch(%L, jsonb_build_object('booking', %L, 'to', 'plan'))$$, test.id('cs_admin'), (test.csb('o4')).booking_number), 'cancelled');
select test.eq('the new email is in the catalogue and emitted by the switch', (select emitted_by || '/' || push_topic from notification_catalogue where code = 'renter_coverage_switched'), 'app.coverage_switch (0890)/bookings');
