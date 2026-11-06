-- 99: release 28, operations (docs/changes/2026-11-07-r28-operations.md): an accepted booking is booked (0540), deposits
-- stay holds (0541), amended agreements and the cleaning fee (0542), owner referral links (0543), the Blind Spot form's
-- facts and typed corrections (0544), one-screen handovers and the renter's own check-in and checkout (0545), owner
-- handoffs (0546), partner invoices (0547). Fixtures start with "r8".
select test.suite('99 r28 operations');

select test.mk_user('r8_admin', 'admin');
select test.mk_user('r8_cs', 'va', 'cs');
select test.mk_user('r8_fleet', 'va', 'fleet');
select test.mk_user('r8_fin', 'va', 'finance');
update staff_profiles set single_limit_cents = 500000 where user_id in (test.id('r8_cs'), test.id('r8_fin'));
update program_settings set weekend_premium_bps = 0 where id = (app.settings()).id;

create table test.r8 (k text primary key, v jsonb);
grant select on test.r8 to authenticated, service_role;
create function test.r8v(p text) returns jsonb language sql stable as $$ select v from test.r8 where k = p $$;
create function test.r8b(p text) returns bookings language sql stable security definer as $$
  select * from public.bookings where id = coalesce((test.r8v(p) ->> 'booking_id')::uuid, (test.r8v(p) ->> 'id')::uuid) $$;
create function test.r8u(p text) returns uuid language sql stable security definer as $$
  select r.user_id from public.renters r where r.id = (test.r8b(p)).renter_id $$;
do $$
declare i integer;
begin
  for i in 1 .. 3 loop
    insert into test.r8 select 'car' || i, app.vehicle_add(test.id('r8_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1XFCXMM00000099' || lpad(i::text, 2, '0'),
      'plate', 'R8C00' || i, 'year', 2024, 'make', 'Kia', 'model', 'K5', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
  end loop;
end $$;
create function test.r8car(p text) returns uuid language sql stable as $$ select (test.r8v(p) ->> 'vehicle_id')::uuid $$;
create function test.r8req(p_car text, p_from interval, p_to interval, p_who text, p jsonb default '{}'::jsonb) returns jsonb language sql stable as $$
  select jsonb_build_object('vehicle_id', test.r8car(p_car), 'pickup_at', date_trunc('hour', now()) + p_from, 'return_at', date_trunc('hour', now()) + p_to,
    'renter', jsonb_build_object('full_name', 'R8 ' || initcap(p_who), 'email', 'r8.' || p_who || '@example.test', 'mobile', '(289) 555-01' || lpad((length(p_who) * 7 % 100)::text, 2, '0'), 'date_of_birth', '1990-02-03'),
    'coverage_option', 1, 'sales_choice', 'sourced', 'channels', jsonb_build_object('email', false, 'text', false)) || p $$;
create function test.r8_licence(p text) returns void language plpgsql as $$
declare v_driver uuid := (select bd.driver_id from booking_drivers bd where bd.booking_id = (test.r8b(p)).id and bd.role = 'renter');
  k text;
begin
  foreach k in array array['licence_front', 'licence_back', 'selfie'] loop
    perform app.register_verification_upload((test.r8b(p)).id, test.r8u(p), k, v_driver, 'renters/rq/' || p || '-' || k || '-' || gen_random_uuid() || '.jpg', repeat('e', 64), 'image/jpeg', null, 'identity');
  end loop;
  perform public.renter_save_details(test.r8u(p), jsonb_build_object('licence_number', 'N1234-12345-12345', 'licence_issuer', 'ON', 'licence_class', 'G',
    'licence_expiry', (now() + interval '3 years')::date), (test.r8b(p)).id);
end $$;

-- ================================================================ A1. accepted = booked
insert into test.r8 select 'a', app.door(test.id('r8_cs'), 'aal2', 'ops_do', 'offer_create', test.r8req('car1', interval '5 days', interval '8 days', 'alma', '{"rental_pay_method": "e_transfer"}'));
insert into test.r8 select 'b', app.door(test.id('r8_cs'), 'aal2', 'ops_do', 'offer_create', test.r8req('car1', interval '6 days', interval '9 days', 'bert'));
select test.eq('A1: two offers out on the same car and overlapping dates', (select string_agg(status::text, ',' order by booking_number) from bookings where id in ((test.r8b('a')).id, (test.r8b('b')).id)), 'offered,offered');
select test.r8_licence('a');
select public.renter_approve_offer((test.r8b('a')).id, (test.r8b('a')).current_offer_version, test.r8u('a'));
select test.eq('A1: the renter accepted: waiting for payment, and booked', (test.r8b('a')).status::text || ':' || app.booking_is_booked(test.r8b('a')), 'pending_payment:true');
select test.ok('A1: the car is no longer free for those dates (availability counts the accepted booking)',
  not app.vehicle_is_available(test.r8car('car1'), (test.r8b('a')).pickup_at + interval '1 day', (test.r8b('a')).pickup_at + interval '2 days'));
select test.eq('A1: the other open offer went back to staff with a Re-offer To do',
  (test.r8b('b')).status::text || ':' || (select count(*) from tasks where booking_id = (test.r8b('b')).id and task_type = 'reoffer_booking' and status = 'open'), 'requested:1');
select test.eq('A1: no To do for payment yet (the pickup is more than 48 hours away)', (select app.booked_unpaid_tasks()), 0);
insert into test.r8 select 'c', app.door(test.id('r8_cs'), 'aal2', 'ops_do', 'offer_create', test.r8req('car2', interval '20 hours', interval '3 days', 'cleo', '{"rental_pay_method": "e_transfer"}'));
select test.r8_licence('c');
select public.renter_approve_offer((test.r8b('c')).id, (test.r8b('c')).current_offer_version, test.r8u('c'));
select test.eq('A1: within 48 hours of the pickup, unpaid: the To do is raised', app.booked_unpaid_tasks(), 1);
select test.eq('A1: ... one "booked, payment due" To do', (select count(*) from tasks where booking_id = (test.r8b('c')).id and task_type = 'booked_unpaid' and status = 'open'), 1::bigint);
select app.booked_unpaid_tasks();
select test.eq('A1: run again: still one', (select count(*) from tasks where booking_id = (test.r8b('c')).id and task_type = 'booked_unpaid'), 1::bigint);

-- ================================================================ A5. deposits stay holds
select test.eq('A5: a deposit is a hold for any rental length', public.calc_deposit_method(45, 7), 'card_hold');
select test.ok('A5: nothing is captured by itself; extended holds start off', not (app.settings()).deposit_auto_capture and not (app.settings()).deposit_extended_holds);
select test.mk_owner('r8_o');
select test.mk_vehicle('R8V', 'r8_o');
select test.mk_renter('r8_dee');
select test.mk_booking('R8-D1', 'R8V', 'r8_dee', to_char((now() - interval '3 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
                       to_char((now() + interval '20 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'on_rent');
insert into payments (id, booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at)
values (test.id('pay:r8d1'), test.id('booking:R8-D1'), test.id('renter:r8_dee'), 'deposit', 'hold', 'card', 100000, 'authorized', now() - interval '6 days');
insert into payment_processor_details (payment_id, processor, processor_payment_id) values (test.id('pay:r8d1'), 'stripe', 'pi_r8_old_hold');
insert into deposits (booking_id, amount_cents, method, status, hold_payment_id, taken_at, hold_expires_at)
values (test.id('booking:R8-D1'), 100000, 'card_hold', 'held', test.id('pay:r8d1'), now() - interval '6 days', now() + interval '20 hours');
select test.eq('A5: the real expiry from Stripe''s capture_before is recorded',
  public.server_deposit_hold_expiry('pi_r8_old_hold', extract(epoch from now() + interval '22 hours')::bigint, false) ->> 'ok', 'true');
select test.eq('A5: ... on the deposit', (select hold_expiry_from_bank from deposits where booking_id = test.id('booking:R8-D1')), true);
create temp table r8_sweep as select public.server_deposit_guard_sweep() s;
select test.eq('A5: a hold nearing expiry with the car out: a To do to re-authorize, and no capture',
  (select count(*) from tasks where booking_id = test.id('booking:R8-D1') and task_type = 'deposit_hold_expiring' and status = 'open') || ':'
  || (select jsonb_array_length(s -> 'captures') from r8_sweep), '1:0');
select test.throws('A5: re-authorize needs a saved card', format($$select app.door(%L, 'aal2', 'ops_do', 'hold_reauth_begin', '{"booking": "R8-D1"}')$$, test.id('r8_fin')), 'no saved card');
insert into payment_method_secrets (payment_method_id, processor, processor_customer_id, processor_method_id) values (test.id('card:r8_dee'), 'stripe', 'cus_r8', 'pm_r8');
update payment_methods set status = 'active' where id = test.id('card:r8_dee');
select test.throws('A5: fleet does not re-authorize', format($$select app.door(%L, 'aal2', 'ops_do', 'hold_reauth_begin', '{"booking": "R8-D1"}')$$, test.id('r8_fleet')), 'Finance or an Admin');
insert into test.r8 select 'reauth', app.door(test.id('r8_fin'), 'aal2', 'ops_do', 'hold_reauth_begin', '{"booking": "R8-D1"}');
select test.eq('A5: re-authorize: what is still held, on the saved card, the old hold to release',
  (test.r8v('reauth') ->> 'amount_cents') || ':' || (test.r8v('reauth') ->> 'method_id') || ':' || (test.r8v('reauth') ->> 'old_intent') || ':' || (test.r8v('reauth') ->> 'extended'), '100000:pm_r8:pi_r8_old_hold:false');
select app.door(test.id('r8_fin'), 'aal2', 'ops_do', 'hold_reauth_finish', jsonb_build_object('deposit', test.r8v('reauth') ->> 'deposit_id', 'amount_cents', 100000, 'ok', true,
  'intent_id', 'pi_r8_new_hold', 'capture_before', extract(epoch from now() + interval '29 days')::bigint, 'extended', true));
select test.eq('A5: the new hold is the deposit''s, the old one cancelled, the To do closed, the ledger says so',
  (select (pd.processor_payment_id = 'pi_r8_new_hold') || ':' || d.hold_extended || ':' || (d.hold_expires_at > now() + interval '28 days') from deposits d join payment_processor_details pd on pd.payment_id = d.hold_payment_id where d.booking_id = test.id('booking:R8-D1'))
  || '/' || (select status from payments where id = test.id('pay:r8d1'))
  || '/' || (select count(*) from tasks where booking_id = test.id('booking:R8-D1') and task_type = 'deposit_hold_expiring' and status = 'open')
  || '/' || (select count(*) from deposit_events e join deposits d on d.id = e.deposit_id where d.booking_id = test.id('booking:R8-D1') and e.kind = 'hold_renewed'),
  'true:true:true/cancelled/0/1');

-- ================================================================ A7, A8
select test.eq('A7: the heavy cleaning fee is $300 from today, editable as every fee default',
  (select amount_cents from fee_defaults where fee_type_code = 'cleaning_heavy' and vehicle_class is null and effective_from <= app.today() and (effective_to is null or effective_to > app.today())), 30000::bigint);

-- ================================================================ A10. owner referral links
select test.mk_owner('r8_max');
select test.mk_owner('r8_kar');
select test.mk_vehicle('R8M', 'r8_max', p_share_bps => 4000, p_insurance => 35000);
select test.mk_renter('r8_ren');
select test.mk_booking('R8-M1', 'R8M', 'r8_ren', to_char((now() - interval '6 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
                       to_char((now() - interval '3 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'closed');
select test.mk_line('R8-M1', 'rental_charge', 30000);
select app.compute_booking_split(test.id('booking:R8-M1'));
select test.throws('A10: only an Admin links owners', format($$select app.door(%L, 'aal2', 'ops_do', 'owner_referral_link_save', %L)$$, test.id('r8_fin'),
  jsonb_build_object('referrer_owner_id', test.id('owner:r8_kar'), 'referred_owner_id', test.id('owner:r8_max'))), 'Only an Admin');
select app.door(test.id('r8_admin'), 'aal2', 'admin_do', 'owner_referral_link_save', jsonb_build_object('referrer_owner_id', test.id('owner:r8_kar'), 'referred_owner_id', test.id('owner:r8_max'),
  'share_bps', 1000, 'effective_from', (app.month_start(app.today()) - interval '2 months')::date));
create temp table r8_split as select s.owner_revenue_cents, s.payout_month from booking_splits s where s.booking_id = test.id('booking:R8-M1');
select test.ok('A10: the referred booking has a revenue base', (select owner_revenue_cents > 0 from r8_split));
create temp table r8_st as select app.build_owner_statement(test.id('owner:r8_kar'), (select payout_month from r8_split)) id;
select test.eq('A10: the referrer''s statement has a referral share line per referred car, 10 points of the revenue base, added to the payout',
  (select count(*) || ':' || sum(amount_cents) from owner_statement_lines where owner_statement_id = (select id from r8_st) and line_type = 'referral_share')
  || '/' || (select kickbacks_earned_cents from owner_statements where id = (select id from r8_st)),
  '1:' || (select round(owner_revenue_cents * 0.1)::bigint from r8_split) || '/' || (select round(owner_revenue_cents * 0.1)::bigint from r8_split));
select app.build_owner_statement(test.id('owner:r8_kar'), (select payout_month from r8_split));
select test.eq('A10: built again as a draft: paid once', (select count(*) from owner_referral_shares where referrer_owner_id = test.id('owner:r8_kar')), 1::bigint);
select test.eq('A10: the referrer sees the referred cars read only, never the other owner''s name',
  (select jsonb_array_length(c) || ':' || (strpos(c::text, 'R8 Max') = 0) from (select public.server_owner_referred_cars(test.id('r8_kar')) c) q), '1:true');
select test.eq('A10: the referred owner sees nothing of the sort', jsonb_array_length(public.server_owner_referred_cars(test.id('r8_max'))), 0);

-- ================================================================ A11. the Blind Spot form
select test.eq('A11: the form''s facts carry the late fee per hour and the readings',
  (select (x ? 'late_fee_cents') || ':' || (x -> 'readings' ? 'fuel_out_pct') from (select app.blindspot_extra(test.id('booking:R8-M1')) x) q), 'true:true');
select app.door(test.id('r8_fleet'), 'aal2', 'ops_do', 'blindspot_boxes_save', jsonb_build_object('booking', 'R8-M1', 'boxes', jsonb_build_object('claim', 'CLM-R8-1', '14-1', 'Typed by staff')));
select test.eq('A11: typed corrections are kept by box, and the claim number goes back to the booking',
  (app.blindspot_extra(test.id('booking:R8-M1')) -> 'overrides' ->> '14-1') || ':' || (select insurer_claim_number from bookings where id = test.id('booking:R8-M1')), 'Typed by staff:CLM-R8-1');
select app.door(test.id('r8_fleet'), 'aal2', 'ops_do', 'blindspot_boxes_save', jsonb_build_object('booking', 'R8-M1', 'boxes', jsonb_build_object('14-1', '')));
select test.eq('A11: an emptied box goes back to the booking''s value', (app.blindspot_extra(test.id('booking:R8-M1')) -> 'overrides') ? '14-1', false);

-- ================================================================ A2, A3. one screen, the renter's own checkout
select test.mk_renter('r8_ret');
select test.mk_booking('R8-R1', 'R8V', 'r8_ret', to_char((now() - interval '40 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
                       to_char((now() - interval '38 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'on_rent');
update bookings set odometer_out_km = 10000 where id = test.id('booking:R8-R1');
create function test.r8_photo(p_booking text, p_scope text, p_angle text) returns jsonb language sql stable as $$
  select jsonb_build_object('bucket', 'condition-photos', 'path', 'bookings/' || test.id('booking:' || p_booking) || '/' || p_scope || '/' || gen_random_uuid() || '.jpg', 'angle', p_angle) $$;
create temp table r8_r1 as select public.server_return_claim_submit((select return_link_token from bookings where id = test.id('booking:R8-R1')),
  jsonb_build_object('odometer_km', 10400, 'fuel_pct', 75, 'photos', jsonb_build_array(test.r8_photo('R8-R1', 'return-claim', 'front'), test.r8_photo('R8-R1', 'return-claim', 'odometer')))) r;
select test.eq('A2: the renter''s own checkout with km, fuel and photos completes the trip at once, at their time, angles kept',
  (select r ->> 'status' from r8_r1) || '/' || (select status::text || ':' || odometer_in_km || ':' || fuel_in_pct from bookings where id = test.id('booking:R8-R1'))
  || '/' || (select string_agg(coalesce(p.angle, '-'), ',' order by p.seq) from condition_report_photos p join condition_reports c on c.id = p.condition_report_id where c.booking_id = test.id('booking:R8-R1') and c.kind = 'return')
  || '/' || (select count(*) from tasks where booking_id = test.id('booking:R8-R1') and task_type in ('return_claim_review', 'handover_details') and status = 'open'),
  'completed/returned:10400:75/front,odometer/0');

select test.mk_booking('R8-R2', 'R8V', 'r8_ret', to_char((now() - interval '30 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
                       to_char((now() - interval '28 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'on_rent');
select test.throws('A2: one screen: Finance does not hand cars over', format($$select app.door(%L, 'aal2', 'ops_do', 'handover_one_screen', %L)$$, test.id('r8_fin'),
  jsonb_build_object('booking', 'R8-R2', 'kind', 'return')), 'record a check-out or check-in');
select app.door(test.id('r8_fleet'), 'aal2', 'ops_do', 'handover_one_screen', jsonb_build_object('booking', 'R8-R2', 'kind', 'return', 'odometer_km', 12000, 'fuel_pct', 100,
  'photos', jsonb_build_array(test.r8_photo('R8-R2', 'one-screen', 'rear'), test.r8_photo('R8-R2', 'one-screen', null))));
select test.eq('A2: one screen: returned, the report complete with its photos and who took them, no "add the details" To do',
  (select status::text from bookings where id = test.id('booking:R8-R2'))
  || '/' || (select (not details_pending) || ':' || (completed_at is not null) from condition_reports where booking_id = test.id('booking:R8-R2') and kind = 'return')
  || '/' || (select count(*) || ':' || bool_and(uploaded_by = test.id('r8_fleet')) from condition_report_photos p join condition_reports c on c.id = p.condition_report_id where c.booking_id = test.id('booking:R8-R2'))
  || '/' || (select count(*) from tasks where booking_id = test.id('booking:R8-R2') and task_type = 'handover_details' and status = 'open'),
  'returned/true:true/2:true/0');
select test.throws('A3: only this booking''s photos', format($$select app.door(%L, 'aal2', 'ops_do', 'handover_one_screen', %L)$$, test.id('r8_fleet'),
  jsonb_build_object('booking', 'R8-R2', 'kind', 'return', 'photos', jsonb_build_array(test.r8_photo('R8-R1', 'one-screen', null)))), 'not uploaded for this booking');

-- ================================================================ A4. pickup from and return to the owner
select test.throws('A4: customer service does not record it', format($$select app.door(%L, 'aal2', 'ops_do', 'owner_handoff_save', %L)$$, test.id('r8_cs'),
  jsonb_build_object('vehicle', test.id('vehicle:R8V'), 'kind', 'pickup_from_owner')), 'Fleet or field');
select app.door(test.id('r8_fleet'), 'aal2', 'ops_do', 'owner_handoff_save', jsonb_build_object('vehicle', test.id('vehicle:R8V'), 'kind', 'pickup_from_owner', 'odometer_km', 15000, 'fuel_pct', 50,
  'photos', jsonb_build_array(jsonb_build_object('bucket', 'condition-photos', 'path', 'vehicles/' || test.id('vehicle:R8V') || '/owner-handoff/' || gen_random_uuid() || '.jpg', 'angle', 'front'))));
select test.eq('A4: the owner reads it (read only); another owner does not',
  (select jsonb_array_length(public.server_owner_handoffs(test.id('r8_o'), test.id('vehicle:R8V'))) || ':' || ((public.server_owner_handoffs(test.id('r8_o'), test.id('vehicle:R8V')) -> 0 ->> 'odometer_km'))), '1:15000');
select test.throws('A4: another owner does not', format($$select public.server_owner_handoffs(%L, %L)$$, test.id('r8_kar'), test.id('vehicle:R8V')), 'Not permitted');

-- ================================================================ A12. partner invoices
insert into referral_partners (id, kind, status, business_name, contact_name, email, referral_code, rate_kind, flat_cents, default_kickback_bps)
values (test.id('rp:r8'), 'body_shop', 'active', 'R8 Collision', 'Sam Shop', 'r8.shop@example.test', 'R8SHOP1', 'flat', 2500, 1000);
select test.throws('A12: fleet writes no invoice', format($$select app.door(%L, 'aal2', 'ops_do', 'partner_invoice_save', %L)$$, test.id('r8_fleet'), jsonb_build_object('partner_id', test.id('rp:r8'))), 'Finance or an Admin');
insert into test.r8 select 'pi', app.door(test.id('r8_fin'), 'aal2', 'ops_do', 'partner_invoice_save', jsonb_build_object('partner_id', test.id('rp:r8'), 'kind', 'repair',
  'claim_number', 'CLM-R8-9', 'partner_total_cents', 1250000,
  'lines', jsonb_build_array(jsonb_build_object('description', '', 'percent_bps', 1000), jsonb_build_object('description', 'Storage days', 'quantity', 2, 'unit_cents', 5000, 'hst', false))));
select test.eq('A12: the lines: 10% of the claim total with HST (the default wording), and a fixed line without; the totals',
  (select string_agg(description || ':' || amount_cents || ':' || hst_cents, ',' order by sort) from partner_invoice_lines where invoice_id = (test.r8v('pi') ->> 'id')::uuid)
  || '/' || (test.r8v('pi') ->> 'total_cents') || '/' || (test.r8v('pi') ->> 'state'),
  'Outsourced repair services:125000:16250,Storage days:10000:0/151250/draft');
insert into test.r8 select 'pis', app.door(test.id('r8_fin'), 'aal2', 'ops_do', 'partner_invoice_send', jsonb_build_object('id', test.r8v('pi') ->> 'id'));
select test.eq('A12: sent: numbered, due, emailed to the partner (logged)',
  ((test.r8v('pis') ->> 'invoice_number') ~ '^PI-\d{6}$') || ':' || (test.r8v('pis') ->> 'state') || ':' || (test.r8v('pis') ->> 'sent_to') || ':' || ((test.r8v('pis') ->> 'due_on') is not null)
  || ':' || (select count(*) from notification_outbox where code = 'partner_invoice' and entity_id = (test.r8v('pi') ->> 'id')::uuid), 'true:sent:r8.shop@example.test:true:1');
select test.throws('A12: a sent invoice is not edited', format($$select app.door(%L, 'aal2', 'ops_do', 'partner_invoice_save', %L)$$, test.id('r8_fin'), jsonb_build_object('id', test.r8v('pi') ->> 'id')), 'only a draft');
select app.door(test.id('r8_fin'), 'aal2', 'ops_do', 'partner_invoice_pay', jsonb_build_object('id', test.r8v('pi') ->> 'id', 'method', 'cheque', 'amount_cents', 100000, 'reference', '000123'));
select test.eq('A12: a cheque recorded: partly paid, the ledger per partner and per claim',
  (select (x #>> '{totals,received_cents}') || ':' || (x #>> '{totals,outstanding_cents}') || ':' || (x -> 'by_claim' -> 0 ->> 'claim_number') || ':' || (x -> 'invoices' -> 0 ->> 'state')
     from (select app.door(test.id('r8_admin'), 'aal2', 'ops_read', 'partner_invoices', '{}'::jsonb) x) q), '100000:51250:CLM-R8-9:partly_paid');
update partner_invoices set due_on = app.today() - 10 where id = (test.r8v('pi') ->> 'id')::uuid;
select test.eq('A12: one reminder after the due date', app.partner_invoice_reminders(), 1);
select test.eq('A12: ... once', app.partner_invoice_reminders(), 0);
select test.eq('A12: the partner''s page lists it with its link', jsonb_array_length(public.server_partner_invoices_of(test.id('rp:r8'))), 1);

update program_settings set weekend_premium_bps = 1500 where id = (app.settings()).id;
