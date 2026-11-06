-- 99: release 28, operations (docs/changes/2026-11-07-r28-operations.md): an accepted booking is booked (0540), deposits
-- stay holds (0541), amended agreements and the cleaning fee (0542), owner referral links (0543), the Blind Spot form's
-- facts and typed corrections (0544), one-screen handovers and the renter's own check-in and checkout (0545), owner
-- handoffs (0546), partner invoices (0547). Fixtures start with "rq".
select test.suite('99 r28 operations');

select test.mk_user('rq_admin', 'admin');
select test.mk_user('rq_cs', 'va', 'cs');
select test.mk_user('rq_fleet', 'va', 'fleet');
select test.mk_user('rq_fin', 'va', 'finance');
update staff_profiles set single_limit_cents = 500000 where user_id in (test.id('rq_cs'), test.id('rq_fin'));
update program_settings set weekend_premium_bps = 0 where id = (app.settings()).id;

create table test.rq (k text primary key, v jsonb);
grant select on test.rq to authenticated, service_role;
create function test.rqv(p text) returns jsonb language sql stable as $$ select v from test.rq where k = p $$;
create function test.rqb(p text) returns bookings language sql stable security definer as $$
  select * from public.bookings where id = coalesce((test.rqv(p) ->> 'booking_id')::uuid, (test.rqv(p) ->> 'id')::uuid) $$;
create function test.rqu(p text) returns uuid language sql stable security definer as $$
  select r.user_id from public.renters r where r.id = (test.rqb(p)).renter_id $$;
do $$
declare i integer;
begin
  for i in 1 .. 3 loop
    insert into test.rq select 'car' || i, app.vehicle_add(test.id('rq_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1XFCXMM00000099' || lpad(i::text, 2, '0'),
      'plate', 'RQC00' || i, 'year', 2024, 'make', 'Kia', 'model', 'K5', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
  end loop;
end $$;
create function test.rqcar(p text) returns uuid language sql stable as $$ select (test.rqv(p) ->> 'vehicle_id')::uuid $$;
create function test.rqreq(p_car text, p_from interval, p_to interval, p_who text, p jsonb default '{}'::jsonb) returns jsonb language sql stable as $$
  select jsonb_build_object('vehicle_id', test.rqcar(p_car), 'pickup_at', date_trunc('hour', now()) + p_from, 'return_at', date_trunc('hour', now()) + p_to,
    'renter', jsonb_build_object('full_name', 'Rq ' || initcap(p_who), 'email', 'rq.' || p_who || '@example.test', 'mobile', '(289) 555-01' || lpad((length(p_who) * 7 % 100)::text, 2, '0'), 'date_of_birth', '1990-02-03'),
    'coverage_option', 1, 'sales_choice', 'sourced', 'channels', jsonb_build_object('email', false, 'text', false)) || p $$;
create function test.rq_licence(p text) returns void language plpgsql as $$
declare v_driver uuid := (select bd.driver_id from booking_drivers bd where bd.booking_id = (test.rqb(p)).id and bd.role = 'renter');
  k text;
begin
  foreach k in array array['licence_front', 'licence_back', 'selfie'] loop
    perform app.register_verification_upload((test.rqb(p)).id, test.rqu(p), k, v_driver, 'renters/rq/' || p || '-' || k || '-' || gen_random_uuid() || '.jpg', repeat('e', 64), 'image/jpeg', null, 'identity');
  end loop;
  perform public.renter_save_details(test.rqu(p), jsonb_build_object('licence_number', 'N1234-12345-12345', 'licence_issuer', 'ON', 'licence_class', 'G',
    'licence_expiry', (now() + interval '3 years')::date), (test.rqb(p)).id);
end $$;

-- ================================================================ A1. accepted = booked
insert into test.rq select 'a', app.door(test.id('rq_cs'), 'aal2', 'ops_do', 'offer_create', test.rqreq('car1', interval '5 days', interval '8 days', 'alma', '{"rental_pay_method": "e_transfer"}'));
insert into test.rq select 'b', app.door(test.id('rq_cs'), 'aal2', 'ops_do', 'offer_create', test.rqreq('car1', interval '6 days', interval '9 days', 'bert'));
select test.eq('A1: two offers out on the same car and overlapping dates', (select string_agg(status::text, ',' order by booking_number) from bookings where id in ((test.rqb('a')).id, (test.rqb('b')).id)), 'offered,offered');
select test.rq_licence('a');
select public.renter_approve_offer((test.rqb('a')).id, (test.rqb('a')).current_offer_version, test.rqu('a'));
select test.eq('A1: the renter accepted: waiting for payment, and booked', (test.rqb('a')).status::text || ':' || app.booking_is_booked(test.rqb('a')), 'pending_payment:true');
select test.ok('A1: the car is no longer free for those dates (availability counts the accepted booking)',
  not app.vehicle_is_available(test.rqcar('car1'), (test.rqb('a')).pickup_at + interval '1 day', (test.rqb('a')).pickup_at + interval '2 days'));
select test.eq('A1: the other open offer went back to staff with a Re-offer To do',
  (test.rqb('b')).status::text || ':' || (select count(*) from tasks where booking_id = (test.rqb('b')).id and task_type = 'reoffer_booking' and status = 'open'), 'requested:1');
select test.eq('A1: no To do for payment yet (the pickup is more than 48 hours away)', (select app.booked_unpaid_tasks()), 0);
insert into test.rq select 'c', app.door(test.id('rq_cs'), 'aal2', 'ops_do', 'offer_create', test.rqreq('car2', interval '20 hours', interval '3 days', 'cleo', '{"rental_pay_method": "e_transfer"}'));
select test.rq_licence('c');
select public.renter_approve_offer((test.rqb('c')).id, (test.rqb('c')).current_offer_version, test.rqu('c'));
select test.eq('A1: within 48 hours of the pickup, unpaid: the To do is raised', app.booked_unpaid_tasks(), 1);
select test.eq('A1: ... one "booked, payment due" To do', (select count(*) from tasks where booking_id = (test.rqb('c')).id and task_type = 'booked_unpaid' and status = 'open'), 1::bigint);
select app.booked_unpaid_tasks();
select test.eq('A1: run again: still one', (select count(*) from tasks where booking_id = (test.rqb('c')).id and task_type = 'booked_unpaid'), 1::bigint);

-- ================================================================ A5. deposits stay holds
select test.eq('A5: a deposit is a hold for any rental length', public.calc_deposit_method(45, 7), 'card_hold');
select test.ok('A5: nothing is captured by itself; extended holds start off', not (app.settings()).deposit_auto_capture and not (app.settings()).deposit_extended_holds);
select test.mk_owner('rq_o');
select test.mk_vehicle('RQV', 'rq_o');
select test.mk_renter('rq_dee');
select test.mk_booking('RQ-D1', 'RQV', 'rq_dee', to_char((now() - interval '3 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
                       to_char((now() + interval '20 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'on_rent');
insert into payments (id, booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at)
values (test.id('pay:rqd1'), test.id('booking:RQ-D1'), test.id('renter:rq_dee'), 'deposit', 'hold', 'card', 100000, 'authorized', now() - interval '6 days');
insert into payment_processor_details (payment_id, processor, processor_payment_id) values (test.id('pay:rqd1'), 'stripe', 'pi_rq_old_hold');
insert into deposits (booking_id, amount_cents, method, status, hold_payment_id, taken_at, hold_expires_at)
values (test.id('booking:RQ-D1'), 100000, 'card_hold', 'held', test.id('pay:rqd1'), now() - interval '6 days', now() + interval '20 hours');
select test.eq('A5: the real expiry from Stripe''s capture_before is recorded',
  public.server_deposit_hold_expiry('pi_rq_old_hold', extract(epoch from now() + interval '22 hours')::bigint, false) ->> 'ok', 'true');
select test.eq('A5: ... on the deposit', (select hold_expiry_from_bank from deposits where booking_id = test.id('booking:RQ-D1')), true);
create temp table rq_sweep as select public.server_deposit_guard_sweep() s;
select test.eq('A5: a hold nearing expiry with the car out: a To do to re-authorize, and no capture',
  (select count(*) from tasks where booking_id = test.id('booking:RQ-D1') and task_type = 'deposit_hold_expiring' and status = 'open') || ':'
  || (select jsonb_array_length(s -> 'captures') from rq_sweep), '1:0');
select test.throws('A5: re-authorize needs a saved card', format($$select app.door(%L, 'aal2', 'ops_do', 'hold_reauth_begin', '{"booking": "RQ-D1"}')$$, test.id('rq_fin')), 'no saved card');
insert into payment_method_secrets (payment_method_id, processor, processor_customer_id, processor_method_id) values (test.id('card:rq_dee'), 'stripe', 'cus_rq', 'pm_rq');
update payment_methods set status = 'active' where id = test.id('card:rq_dee');
select test.throws('A5: fleet does not re-authorize', format($$select app.door(%L, 'aal2', 'ops_do', 'hold_reauth_begin', '{"booking": "RQ-D1"}')$$, test.id('rq_fleet')), 'Finance or an Admin');
insert into test.rq select 'reauth', app.door(test.id('rq_fin'), 'aal2', 'ops_do', 'hold_reauth_begin', '{"booking": "RQ-D1"}');
select test.eq('A5: re-authorize: what is still held, on the saved card, the old hold to release',
  (test.rqv('reauth') ->> 'amount_cents') || ':' || (test.rqv('reauth') ->> 'method_id') || ':' || (test.rqv('reauth') ->> 'old_intent') || ':' || (test.rqv('reauth') ->> 'extended'), '100000:pm_rq:pi_rq_old_hold:false');
select app.door(test.id('rq_fin'), 'aal2', 'ops_do', 'hold_reauth_finish', jsonb_build_object('deposit', test.rqv('reauth') ->> 'deposit_id', 'amount_cents', 100000, 'ok', true,
  'intent_id', 'pi_rq_new_hold', 'capture_before', extract(epoch from now() + interval '29 days')::bigint, 'extended', true));
select test.eq('A5: the new hold is the deposit''s, the old one cancelled, the To do closed, the ledger says so',
  (select (pd.processor_payment_id = 'pi_rq_new_hold') || ':' || d.hold_extended || ':' || (d.hold_expires_at > now() + interval '28 days') from deposits d join payment_processor_details pd on pd.payment_id = d.hold_payment_id where d.booking_id = test.id('booking:RQ-D1'))
  || '/' || (select status from payments where id = test.id('pay:rqd1'))
  || '/' || (select count(*) from tasks where booking_id = test.id('booking:RQ-D1') and task_type = 'deposit_hold_expiring' and status = 'open')
  || '/' || (select count(*) from deposit_events e join deposits d on d.id = e.deposit_id where d.booking_id = test.id('booking:RQ-D1') and e.kind = 'hold_renewed'),
  'true:true:true/cancelled/0/1');

-- ================================================================ A7, A8
select test.eq('A7: the heavy cleaning fee is $300 from today, editable as every fee default',
  (select amount_cents from fee_defaults where fee_type_code = 'cleaning_heavy' and vehicle_class is null and effective_from <= app.today() and (effective_to is null or effective_to > app.today())), 30000::bigint);

-- ================================================================ A10. owner referral links
select test.mk_owner('rq_max');
select test.mk_owner('rq_kar');
select test.mk_vehicle('RQM', 'rq_max', p_share_bps => 4000, p_insurance => 35000);
select test.mk_renter('rq_ren');
select test.mk_booking('RQ-M1', 'RQM', 'rq_ren', to_char((now() - interval '6 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
                       to_char((now() - interval '3 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'closed');
select test.mk_line('RQ-M1', 'rental_charge', 30000);
select app.compute_booking_split(test.id('booking:RQ-M1'));
select test.throws('A10: only an Admin links owners', format($$select app.door(%L, 'aal2', 'ops_do', 'owner_referral_link_save', %L)$$, test.id('rq_fin'),
  jsonb_build_object('referrer_owner_id', test.id('owner:rq_kar'), 'referred_owner_id', test.id('owner:rq_max'))), 'Only an Admin');
select app.door(test.id('rq_admin'), 'aal2', 'admin_do', 'owner_referral_link_save', jsonb_build_object('referrer_owner_id', test.id('owner:rq_kar'), 'referred_owner_id', test.id('owner:rq_max'),
  'share_bps', 1000, 'effective_from', (app.month_start(app.today()) - interval '2 months')::date));
create temp table rq_split as select s.owner_revenue_cents, s.payout_month from booking_splits s where s.booking_id = test.id('booking:RQ-M1');
select test.ok('A10: the referred booking has a revenue base', (select owner_revenue_cents > 0 from rq_split));
create temp table rq_st as select app.build_owner_statement(test.id('owner:rq_kar'), (select payout_month from rq_split)) id;
select test.eq('A10: the referrer''s statement has a referral share line per referred car, 10 points of the revenue base, added to the payout',
  (select count(*) || ':' || sum(amount_cents) from owner_statement_lines where owner_statement_id = (select id from rq_st) and line_type = 'referral_share')
  || '/' || (select kickbacks_earned_cents from owner_statements where id = (select id from rq_st)),
  '1:' || (select round(owner_revenue_cents * 0.1)::bigint from rq_split) || '/' || (select round(owner_revenue_cents * 0.1)::bigint from rq_split));
select app.build_owner_statement(test.id('owner:rq_kar'), (select payout_month from rq_split));
select test.eq('A10: built again as a draft: paid once', (select count(*) from owner_referral_shares where referrer_owner_id = test.id('owner:rq_kar')), 1::bigint);
select test.eq('A10: the referrer sees the referred cars read only, never the other owner''s name',
  (select jsonb_array_length(c) || ':' || (strpos(c::text, 'Rq Max') = 0) from (select public.server_owner_referred_cars(test.id('rq_kar')) c) q), '1:true');
select test.eq('A10: the referred owner sees nothing of the sort', jsonb_array_length(public.server_owner_referred_cars(test.id('rq_max'))), 0);

-- ================================================================ A11. the Blind Spot form
select test.eq('A11: the form''s facts carry the late fee per hour and the readings',
  (select (x ? 'late_fee_cents') || ':' || (x -> 'readings' ? 'fuel_out_pct') from (select app.blindspot_extra(test.id('booking:RQ-M1')) x) q), 'true:true');
select app.door(test.id('rq_fleet'), 'aal2', 'ops_do', 'blindspot_boxes_save', jsonb_build_object('booking', 'RQ-M1', 'boxes', jsonb_build_object('claim', 'CLM-RQ-1', '14-1', 'Typed by staff')));
select test.eq('A11: typed corrections are kept by box, and the claim number goes back to the booking',
  (app.blindspot_extra(test.id('booking:RQ-M1')) -> 'overrides' ->> '14-1') || ':' || (select insurer_claim_number from bookings where id = test.id('booking:RQ-M1')), 'Typed by staff:CLM-RQ-1');
select app.door(test.id('rq_fleet'), 'aal2', 'ops_do', 'blindspot_boxes_save', jsonb_build_object('booking', 'RQ-M1', 'boxes', jsonb_build_object('14-1', '')));
select test.eq('A11: an emptied box goes back to the booking''s value', (app.blindspot_extra(test.id('booking:RQ-M1')) -> 'overrides') ? '14-1', false);

-- ================================================================ A2, A3. one screen, the renter's own checkout
select test.mk_renter('rq_ret');
select test.mk_booking('RQ-R1', 'RQV', 'rq_ret', to_char((now() - interval '40 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
                       to_char((now() - interval '38 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'on_rent');
update bookings set odometer_out_km = 10000 where id = test.id('booking:RQ-R1');
create function test.rq_photo(p_booking text, p_scope text, p_angle text) returns jsonb language sql stable as $$
  select jsonb_build_object('bucket', 'condition-photos', 'path', 'bookings/' || test.id('booking:' || p_booking) || '/' || p_scope || '/' || gen_random_uuid() || '.jpg', 'angle', p_angle) $$;
create temp table rq_r1 as select public.server_return_claim_submit((select return_link_token from bookings where id = test.id('booking:RQ-R1')),
  jsonb_build_object('odometer_km', 10400, 'fuel_pct', 75, 'photos', jsonb_build_array(test.rq_photo('RQ-R1', 'return-claim', 'front'), test.rq_photo('RQ-R1', 'return-claim', 'odometer')))) r;
select test.eq('A2: the renter''s own checkout with km, fuel and photos completes the trip at once, at their time, angles kept',
  (select r ->> 'status' from rq_r1) || '/' || (select status::text || ':' || odometer_in_km || ':' || fuel_in_pct from bookings where id = test.id('booking:RQ-R1'))
  || '/' || (select string_agg(coalesce(p.angle, '-'), ',' order by p.seq) from condition_report_photos p join condition_reports c on c.id = p.condition_report_id where c.booking_id = test.id('booking:RQ-R1') and c.kind = 'return')
  || '/' || (select count(*) from tasks where booking_id = test.id('booking:RQ-R1') and task_type in ('return_claim_review', 'handover_details') and status = 'open'),
  'completed/returned:10400:75/front,odometer/0');

select test.mk_booking('RQ-R2', 'RQV', 'rq_ret', to_char((now() - interval '30 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
                       to_char((now() - interval '28 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'on_rent');
select test.throws('A2: one screen: Finance does not hand cars over', format($$select app.door(%L, 'aal2', 'ops_do', 'handover_one_screen', %L)$$, test.id('rq_fin'),
  jsonb_build_object('booking', 'RQ-R2', 'kind', 'return')), 'record a check-out or check-in');
select app.door(test.id('rq_fleet'), 'aal2', 'ops_do', 'handover_one_screen', jsonb_build_object('booking', 'RQ-R2', 'kind', 'return', 'odometer_km', 12000, 'fuel_pct', 100,
  'photos', jsonb_build_array(test.rq_photo('RQ-R2', 'one-screen', 'rear'), test.rq_photo('RQ-R2', 'one-screen', null))));
select test.eq('A2: one screen: returned, the report complete with its photos and who took them, no "add the details" To do',
  (select status::text from bookings where id = test.id('booking:RQ-R2'))
  || '/' || (select (not details_pending) || ':' || (completed_at is not null) from condition_reports where booking_id = test.id('booking:RQ-R2') and kind = 'return')
  || '/' || (select count(*) || ':' || bool_and(uploaded_by = test.id('rq_fleet')) from condition_report_photos p join condition_reports c on c.id = p.condition_report_id where c.booking_id = test.id('booking:RQ-R2'))
  || '/' || (select count(*) from tasks where booking_id = test.id('booking:RQ-R2') and task_type = 'handover_details' and status = 'open'),
  'returned/true:true/2:true/0');
select test.throws('A3: only this booking''s photos', format($$select app.door(%L, 'aal2', 'ops_do', 'handover_one_screen', %L)$$, test.id('rq_fleet'),
  jsonb_build_object('booking', 'RQ-R2', 'kind', 'return', 'photos', jsonb_build_array(test.rq_photo('RQ-R1', 'one-screen', null)))), 'not uploaded for this booking');

-- ================================================================ A4. pickup from and return to the owner
select test.throws('A4: customer service does not record it', format($$select app.door(%L, 'aal2', 'ops_do', 'owner_handoff_save', %L)$$, test.id('rq_cs'),
  jsonb_build_object('vehicle', test.id('vehicle:RQV'), 'kind', 'pickup_from_owner')), 'Fleet or field');
select app.door(test.id('rq_fleet'), 'aal2', 'ops_do', 'owner_handoff_save', jsonb_build_object('vehicle', test.id('vehicle:RQV'), 'kind', 'pickup_from_owner', 'odometer_km', 15000, 'fuel_pct', 50,
  'photos', jsonb_build_array(jsonb_build_object('bucket', 'condition-photos', 'path', 'vehicles/' || test.id('vehicle:RQV') || '/owner-handoff/' || gen_random_uuid() || '.jpg', 'angle', 'front'))));
select test.eq('A4: the owner reads it (read only); another owner does not',
  (select jsonb_array_length(public.server_owner_handoffs(test.id('rq_o'), test.id('vehicle:RQV'))) || ':' || ((public.server_owner_handoffs(test.id('rq_o'), test.id('vehicle:RQV')) -> 0 ->> 'odometer_km'))), '1:15000');
select test.throws('A4: another owner does not', format($$select public.server_owner_handoffs(%L, %L)$$, test.id('rq_kar'), test.id('vehicle:RQV')), 'Not permitted');

-- ================================================================ A12. partner invoices
insert into referral_partners (id, kind, status, business_name, contact_name, email, referral_code, rate_kind, flat_cents, default_kickback_bps)
values (test.id('rp:rq'), 'body_shop', 'active', 'Rq Collision', 'Sam Shop', 'rq.shop@example.test', 'RQSHOP1', 'flat', 2500, 1000);
select test.throws('A12: fleet writes no invoice', format($$select app.door(%L, 'aal2', 'ops_do', 'partner_invoice_save', %L)$$, test.id('rq_fleet'), jsonb_build_object('partner_id', test.id('rp:rq'))), 'Finance or an Admin');
insert into test.rq select 'pi', app.door(test.id('rq_fin'), 'aal2', 'ops_do', 'partner_invoice_save', jsonb_build_object('partner_id', test.id('rp:rq'), 'kind', 'repair',
  'claim_number', 'CLM-RQ-9', 'partner_total_cents', 1250000,
  'lines', jsonb_build_array(jsonb_build_object('description', '', 'percent_bps', 1000), jsonb_build_object('description', 'Storage days', 'quantity', 2, 'unit_cents', 5000, 'hst', false))));
select test.eq('A12: the lines: 10% of the claim total with HST (the default wording), and a fixed line without; the totals',
  (select string_agg(description || ':' || amount_cents || ':' || hst_cents, ',' order by sort) from partner_invoice_lines where invoice_id = (test.rqv('pi') ->> 'id')::uuid)
  || '/' || (test.rqv('pi') ->> 'total_cents') || '/' || (test.rqv('pi') ->> 'state'),
  'Outsourced repair services:125000:16250,Storage days:10000:0/151250/draft');
insert into test.rq select 'pis', app.door(test.id('rq_fin'), 'aal2', 'ops_do', 'partner_invoice_send', jsonb_build_object('id', test.rqv('pi') ->> 'id'));
select test.eq('A12: sent: numbered, due, emailed to the partner (logged)',
  ((test.rqv('pis') ->> 'invoice_number') ~ '^PI-\d{6}$') || ':' || (test.rqv('pis') ->> 'state') || ':' || (test.rqv('pis') ->> 'sent_to') || ':' || ((test.rqv('pis') ->> 'due_on') is not null)
  || ':' || (select count(*) from notification_outbox where code = 'partner_invoice' and entity_id = (test.rqv('pi') ->> 'id')::uuid), 'true:sent:rq.shop@example.test:true:1');
select test.throws('A12: a sent invoice is not edited', format($$select app.door(%L, 'aal2', 'ops_do', 'partner_invoice_save', %L)$$, test.id('rq_fin'), jsonb_build_object('id', test.rqv('pi') ->> 'id')), 'only a draft');
select app.door(test.id('rq_fin'), 'aal2', 'ops_do', 'partner_invoice_pay', jsonb_build_object('id', test.rqv('pi') ->> 'id', 'method', 'cheque', 'amount_cents', 100000, 'reference', '000123'));
select test.eq('A12: a cheque recorded: partly paid, the ledger per partner and per claim',
  (select (x #>> '{totals,received_cents}') || ':' || (x #>> '{totals,outstanding_cents}') || ':' || (x -> 'by_claim' -> 0 ->> 'claim_number') || ':' || (x -> 'invoices' -> 0 ->> 'state')
     from (select app.door(test.id('rq_admin'), 'aal2', 'ops_read', 'partner_invoices', '{}'::jsonb) x) q), '100000:51250:CLM-RQ-9:partly_paid');
update partner_invoices set due_on = app.today() - 10 where id = (test.rqv('pi') ->> 'id')::uuid;
select test.eq('A12: one reminder after the due date', app.partner_invoice_reminders(), 1);
select test.eq('A12: ... once', app.partner_invoice_reminders(), 0);
select test.eq('A12: the partner''s page lists it with its link', jsonb_array_length(public.server_partner_invoices_of(test.id('rp:rq'))), 1);

update program_settings set weekend_premium_bps = 1500 where id = (app.settings()).id;
