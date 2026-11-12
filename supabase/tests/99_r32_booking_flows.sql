-- 99: release 32 booking flows (docs/changes/2026-11-07-r32-booking-flows.md): "Returned" in one tap (the 0195 record-now
-- path: late charges from the entered time, the overdue notices stop, the Fleet task for the photos), one card charge for
-- the rental and the fees (0680), the licence link in the request and offer emails (0681). Fixtures start with "rf".
select test.suite('99 r32 booking flows');

select test.mk_user('r32f_admin', 'admin');
select test.mk_user('r32f_fleet', 'va', 'fleet');
select test.mk_user('r32f_cs', 'va', 'cs');
select test.mk_user('r32f_fin', 'va', 'finance');
select test.mk_user('r32f_field', 'field', null, 'driver');
update staff_profiles set single_limit_cents = 500000 where user_id in (test.id('r32f_cs'), test.id('r32f_fin'));
select test.mk_owner('r32f_o');
select test.mk_vehicle('R32FV', 'r32f_o');
select test.mk_vehicle('R32FW', 'r32f_o');
select test.mk_vehicle('R32FX', 'r32f_o');
select test.mk_renter('r32f_r');
create function test.rf_t(p interval) returns text language sql stable as $$
  select to_char((now() + p) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI') $$;
create function test.rf_returned(p_user text, p_booking text, p jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select public.door(test.id(p_user), null, 'ops_do', 'handover_record_now',
    jsonb_build_object('booking', p_booking, 'kind', 'return', 'reason', 'Returned: marked with one tap, photos and readings later') || p) $$;

-- ================================================================ 1. "Returned" in one tap
select test.mk_booking('R32F-1', 'R32FV', 'r32f_r', test.rf_t(- interval '3 days'), test.rf_t(- interval '5 hours'), 'on_rent');
select test.mk_booking('R32F-2', 'R32FW', 'r32f_r', test.rf_t(- interval '2 days'), test.rf_t(interval '20 minutes'), 'on_rent');
update bookings set odometer_out_km = 20000, handed_over_at = pickup_at where id in (test.id('booking:R32F-1'), test.id('booking:R32F-2'));
-- the overdue notice of R32F-1 waits in the outbox
select app.ntf_emit('renter_late_return_first', 'booking', test.id('booking:R32F-1'), 'rf-t13', jsonb_build_object('booking_id', test.id('booking:R32F-1')));
select app.process_events();
select test.ok('overdue: its notice waits in the outbox', exists (select 1 from notification_outbox o join app_events e on e.id = o.event_id
  where e.entity_id = test.id('booking:R32F-1') and o.code = 'renter_late_return_first' and o.status in ('queued', 'delayed')));
select app.raise_task(p_type => 'late_return', p_title => 'R32F-1 is late', p_booking => test.id('booking:R32F-1'), p_dedupe => 'late_return:rf-1');

select test.throws('Finance does not record a return (the database decides who may)', $$select test.rf_returned('r32f_fin', 'R32F-1')$$, 'Only an Admin');
select test.throws('the return time is never in the future', $$select test.rf_returned('r32f_fleet', 'R32F-1', jsonb_build_object('at', now() + interval '2 hours'))$$, 'not in the future');
-- Fleet marks it returned 2 hours ago (it came back 3 hours late), km and fuel given
select test.lives('Fleet: Returned, at an earlier time, with km and fuel', $$select test.rf_returned('r32f_fleet', 'R32F-1',
  jsonb_build_object('at', now() - interval '2 hours', 'odometer_km', 20450, 'fuel_pct', 80))$$);
select test.eq('the booking is returned at the entered time, late by about 3 hours',
  (select status::text || '/' || (abs(extract(epoch from checked_in_at - (now() - interval '2 hours'))) < 60)::text || '/' || (minutes_late between 175 and 185)::text from bookings where id = test.id('booking:R32F-1')),
  'returned/true/true');
select test.eq('the readings are on the check-in report', (select odometer_km || '/' || fuel_pct from condition_reports where booking_id = test.id('booking:R32F-1') and kind = 'return'), '20450/80');
select test.ok('Fleet has the task for the photos and readings', exists (select 1 from tasks where task_type = 'handover_details' and status = 'open'
  and related_id = (select id from condition_reports where booking_id = test.id('booking:R32F-1') and kind = 'return')));
select test.ok('the overdue notice is stopped', not exists (select 1 from notification_outbox o join app_events e on e.id = o.event_id
  where e.entity_id = test.id('booking:R32F-1') and o.code = any (app.overdue_codes()) and o.status in ('queued', 'delayed')));
select test.ok('the late return To do is closed', not exists (select 1 from tasks where task_type in ('late_return', 'late_return_admin') and booking_id = test.id('booking:R32F-1')
  and status in ('open', 'in_progress', 'waiting')));
select app.notify_reminders(now());
select app.notify_booking_staff(now());
select test.ok('no new late alert once returned', not exists (select 1 from app_events e where e.entity_id = test.id('booking:R32F-1')
  and e.code in ('staff_late_return_alert', 'renter_late_return_first', 'renter_late_return_final', 'renter_return_due') and e.dedupe_key not like '%:rf-t13'));  -- the suite's own notice (above) is not a new alert, however fast the suite runs
select test.throws('twice: refused (already recorded)', $$select test.rf_returned('r32f_fleet', 'R32F-1')$$, null);

-- due today, not yet late: field staff mark it returned now, no readings: no late charge
select test.lives('field staff: Returned now, no readings', $$select test.rf_returned('r32f_field', 'R32F-2')$$);
select test.eq('returned, not late', (select status::text || '/' || coalesce(minutes_late, 0) || '/' || coalesce(extra_days, 0) from bookings where id = test.id('booking:R32F-2')), 'returned/0/0');

-- customer service may too
select test.mk_booking('R32F-3', 'R32FX', 'r32f_r', test.rf_t(- interval '2 days'), test.rf_t(- interval '1 hour'), 'on_rent');
update bookings set handed_over_at = pickup_at where id = test.id('booking:R32F-3');
select test.lives('customer service: Returned', $$select test.rf_returned('r32f_cs', 'R32F-3')$$);
select test.eq('returned', (select status::text from bookings where id = test.id('booking:R32F-3')), 'returned');

-- ================================================================ 2. one card charge for the rental and the fees (0680)
create table test.rf (k text primary key, v jsonb);
create function test.rfb(p text) returns bookings language sql stable security definer as $$ select * from public.bookings where booking_number = p $$;
select test.mk_vehicle('R32FY', 'r32f_o');
select test.mk_booking('R32F-4', 'R32FY', 'r32f_r', test.rf_t(interval '3 days'), test.rf_t(interval '6 days'), 'confirmed');
-- the booking: a rental of $300 and $50 of fees open, a card saved on file
do $$
declare v_b uuid := test.id('booking:R32F-4'); v_pm uuid;
begin
  delete from booking_line_items where booking_id = v_b;
  delete from payments where booking_id = v_b;
  insert into booking_line_items (booking_id, charge_type, quantity, unit_amount_cents, amount_cents, hst_applies, hst_cents, revenue_class, stage)
  select v_b, 'rental_charge', 1, 30000, 30000, false, 0, f.revenue_class, 'booking' from fee_types f where f.code = 'rental_charge';
  update bookings set total_due_at_booking_cents = 35000, bill_to = 'renter' where id = v_b;
  insert into payment_methods (renter_id, card_brand, card_last4, status) values (test.id('renter:r32f_r'), 'visa', '4242', 'active') returning id into v_pm;
  insert into payment_method_secrets (payment_method_id, processor_customer_id, processor_method_id) values (v_pm, 'cus_rf', 'pm_rf');
  update bookings set card_on_file_id = v_pm where id = v_b;
end $$;
select test.eq('open: $300 rental, $50 fees', app.booking_part_open(test.id('booking:R32F-4'), 'rental') || '/' || app.booking_part_open(test.id('booking:R32F-4'), 'fees'), '30000/5000');
select test.throws('customer service does not charge a saved card', $$select public.door(test.id('r32f_cs'), 'aal2', 'ops_do', 'card_charge_begin', jsonb_build_object('booking', 'R32F-4', 'covers', 'balance', 'reason', 'Rental and fees'))$$, 'Fleet or an Admin');
select test.throws('never more than is open', $$select public.door(test.id('r32f_fin'), 'aal2', 'ops_do', 'card_charge_begin', jsonb_build_object('booking', 'R32F-4', 'covers', 'balance', 'amount_cents', 40000, 'reason', 'Rental and fees'))$$, 'have $350.00 open');
insert into test.rf select 'c1', public.door(test.id('r32f_fin'), 'aal2', 'ops_do', 'card_charge_begin', jsonb_build_object('booking', 'R32F-4', 'covers', 'balance', 'reason', 'Rental and fees'));
select test.eq('one charge for everything open, split rental first',
  (select (v ->> 'amount_cents') || '/' || (v #>> '{parts,rental}') || '/' || (v #>> '{parts,fees}') || '/' || (v ->> 'covers') from test.rf where k = 'c1'), '35000/30000/5000/balance');
select test.eq('the receipt (Stripe''s description) lists both', (select v ->> 'reason' from test.rf where k = 'c1'), 'Rental $300.00 and fees $50.00');
select test.eq('one pending booking-total card payment', (select count(*) || '/' || min(purpose) || '/' || min(amount_cents) from payments where booking_id = test.id('booking:R32F-4') and method = 'card'), '1/booking_total/35000');
select public.door(test.id('r32f_fin'), 'aal2', 'ops_do', 'card_charge_finish', jsonb_build_object('payment', (select v ->> 'payment_id' from test.rf where k = 'c1'), 'ok', true, 'intent_id', 'pi_rf1', 'reason', 'Rental and fees'));
select test.eq('charged once: nothing open for the rental or the fees', app.booking_part_open(test.id('booking:R32F-4'), 'rental') || '/' || app.booking_part_open(test.id('booking:R32F-4'), 'fees'), '0/0');
select test.eq('one succeeded charge only', (select count(*) from payments where booking_id = test.id('booking:R32F-4') and kind = 'charge' and status = 'succeeded')::integer, 1);
select test.eq('the split is kept', (select string_agg(part || ':' || amount_cents, ',' order by part) from payment_part_allocations where payment_id = (select (v ->> 'payment_id')::uuid from test.rf where k = 'c1')), 'fees:5000,rental:30000');

-- an insurer pays the rental: the one charge takes only what the renter owes
insert into insurers (id, name, billing_email) values (test.id('insurer:r32f'), 'Example Insurance R32F', 'claims-r32f@example.test');
select test.mk_booking('R32F-9', 'R32FY', 'r32f_r', test.rf_t(interval '10 days'), test.rf_t(interval '13 days'), 'confirmed');
do $$
declare v_b uuid := test.id('booking:R32F-9');
begin
  delete from booking_line_items where booking_id = v_b;
  delete from payments where booking_id = v_b;
  insert into booking_line_items (booking_id, charge_type, quantity, unit_amount_cents, amount_cents, hst_applies, hst_cents, revenue_class, stage)
  select v_b, 'rental_charge', 1, 30000, 30000, false, 0, f.revenue_class, 'booking' from fee_types f where f.code = 'rental_charge';
  update bookings set total_due_at_booking_cents = 35000, bill_to = 'insurer', insurer_id = test.id('insurer:r32f'),
         insurer_share_cents = 30000, insurer_hst_cents = 0, card_on_file_id = (select card_on_file_id from bookings where id = test.id('booking:R32F-4'))
   where id = v_b;
end $$;
insert into test.rf select 'c9', public.door(test.id('r32f_fin'), 'aal2', 'ops_do', 'card_charge_begin', jsonb_build_object('booking', 'R32F-9', 'covers', 'balance', 'reason', 'Rental and fees'));
select test.eq('insurer billed: the one charge is the renter''s $50 only', (select v ->> 'amount_cents' from test.rf where k = 'c9'), '5000');
select test.eq('the Money tab lists it once, for the rental and the fees, with both amounts',
  (select x ->> 'covers' || '/' || (x #>> '{parts,rental}') || '/' || (x #>> '{parts,fees}')
     from jsonb_array_elements(public.door(test.id('r32f_fin'), 'aal2', 'ops_read', 'booking_money', jsonb_build_object('booking', 'R32F-4')) -> 'payments') x
    where x ->> 'id' = (select v ->> 'payment_id' from test.rf where k = 'c1')), 'balance/30000/5000');
select test.throws('nothing open: refused', $$select public.door(test.id('r32f_fin'), 'aal2', 'ops_do', 'card_charge_begin', jsonb_build_object('booking', 'R32F-4', 'covers', 'balance', 'reason', 'Rental and fees'))$$, 'Nothing is open');

-- part of the balance: the rental first; then the fees alone with no amount: what the fees have open
select test.mk_vehicle('R32FZ', 'r32f_o');
select test.mk_booking('R32F-5', 'R32FZ', 'r32f_r', test.rf_t(interval '3 days'), test.rf_t(interval '6 days'), 'confirmed');
do $$
declare v_b uuid := test.id('booking:R32F-5');
begin
  delete from booking_line_items where booking_id = v_b;
  delete from payments where booking_id = v_b;
  insert into booking_line_items (booking_id, charge_type, quantity, unit_amount_cents, amount_cents, hst_applies, hst_cents, revenue_class, stage)
  select v_b, 'rental_charge', 1, 20000, 20000, false, 0, f.revenue_class, 'booking' from fee_types f where f.code = 'rental_charge';
  update bookings set total_due_at_booking_cents = 24000, bill_to = 'renter', card_on_file_id = (test.rfb('R32F-4')).card_on_file_id where id = v_b;
end $$;
-- $30 of the fees paid in cash: never charged to the card
select public.door(test.id('r32f_fin'), 'aal2', 'ops_do', 'record_booking_payment', jsonb_build_object('booking', 'R32F-5', 'covers', 'fees', 'method', 'cash', 'amount_cents', 3000, 'received_on', (now() at time zone 'America/Toronto')::date));
select test.eq('open after the cash: $200 rental, $10 fees', app.booking_part_open(test.id('booking:R32F-5'), 'rental') || '/' || app.booking_part_open(test.id('booking:R32F-5'), 'fees'), '20000/1000');
insert into test.rf select 'c2', public.door(test.id('r32f_fin'), 'aal2', 'ops_do', 'card_charge_begin', jsonb_build_object('booking', 'R32F-5', 'covers', 'balance', 'reason', 'Rental and fees'));
select test.eq('the balance leaves out what was paid in cash', (select (v ->> 'amount_cents') || '/' || (v #>> '{parts,rental}') || '/' || (v #>> '{parts,fees}') from test.rf where k = 'c2'), '21000/20000/1000');
select public.door(test.id('r32f_fin'), 'aal2', 'ops_do', 'card_charge_finish', jsonb_build_object('payment', (select v ->> 'payment_id' from test.rf where k = 'c2'), 'ok', false, 'error', 'card_declined'));
select test.eq('declined: still open, nothing allocated as paid', app.booking_part_open(test.id('booking:R32F-5'), 'rental') || '/' || app.booking_part_open(test.id('booking:R32F-5'), 'fees'), '20000/1000');
insert into test.rf select 'c3', public.door(test.id('r32f_fin'), 'aal2', 'ops_do', 'card_charge_begin', jsonb_build_object('booking', 'R32F-5', 'covers', 'balance', 'amount_cents', 5000, 'reason', 'Rental and fees'));
select test.eq('part of the balance: the rental first', (select (v #>> '{parts,rental}') || '/' || (v #>> '{parts,fees}') || '/' || (v ->> 'reason') from test.rf where k = 'c3'), '5000/0/Rental $50.00');
select public.door(test.id('r32f_fin'), 'aal2', 'ops_do', 'card_charge_finish', jsonb_build_object('payment', (select v ->> 'payment_id' from test.rf where k = 'c3'), 'ok', true, 'intent_id', 'pi_rf3'));
insert into test.rf select 'c4', public.door(test.id('r32f_fin'), 'aal2', 'ops_do', 'card_charge_begin', jsonb_build_object('booking', 'R32F-5', 'covers', 'fees', 'reason', 'Fees'));
select test.eq('the fees alone, no amount: what the fees have open', (select v ->> 'amount_cents' from test.rf where k = 'c4'), '1000');

-- ================================================================ 3. the licence link in the request and offer emails (0681)
select test.mk_vehicle('R32FL', 'r32f_o');
select test.mk_booking('R32F-7', 'R32FL', 'r32f_r', test.rf_t(interval '5 days'), test.rf_t(interval '8 days'), 'requested');
select test.ok('every booking email has licence_missing', app.ntf_booking(test.id('booking:R32F-7')) ? 'licence_missing');
select test.eq('a request with no licence on file: the emails link to the upload',
  (app.ntf_booking(test.id('booking:R32F-7')) ->> 'licence_missing')::boolean
    = exists (select 1 from booking_drivers bd where bd.booking_id = test.id('booking:R32F-7') and bd.role = 'renter'
              and jsonb_array_length(app.licence_status(bd.booking_id, bd.driver_id) -> 'missing') > 0), true);
select test.eq('a confirmed booking: no licence link (coverage comes after approval, on the booking page)', (app.ntf_booking(test.id('booking:R32F-4')) ->> 'licence_missing'), 'false');
select test.eq('the request and offer emails read it', (select count(*) from notification_catalogue where code in ('renter_request_received', 'renter_offer_ready', 'renter_offer_reminder')
  and variables @> '[{"name": "licence_missing"}]'::jsonb)::integer, 3);
select test.eq('their main link is unchanged', (select string_agg(link_path, ',' order by code) from notification_catalogue where code in ('renter_request_received', 'renter_offer_ready')),
  '/account/bookings/{{booking_number}}/offer,/account/bookings/{{booking_number}}/request');
