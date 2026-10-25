-- 85: long rentals (migration 0132): the monthly rate past 30 days, the longest booking for renters and for staff, the
-- monthly periods and their caps, a fee line set by hand (quick rental form, offer, an existing booking with its change
-- record and who may), the rental paid in parts with the deposit its own way, and the periods of a long rental (their
-- agreements, invoices, payments and the deposit carried over). Fixtures start with "lr".
select test.suite('85 long rentals');

select test.mk_user('lng_admin', 'admin');
select test.mk_user('lng_cs', 'va', 'cs');
select test.mk_user('lng_sales', 'va', 'sales');
select test.mk_user('lng_fleet', 'va', 'fleet');
update staff_profiles set single_limit_cents = 900000 where user_id in (test.id('lng_cs'), test.id('lng_sales'));

create table test.lng (k text primary key, v jsonb);
grant select on test.lng to authenticated, service_role;
create function test.lngv(p text) returns jsonb language sql stable as $$ select v from test.lng where k = p $$;
create function test.lngb(p text) returns bookings language sql stable security definer as $$
  select * from public.bookings where id = coalesce((test.lngv(p) ->> 'booking_id')::uuid, (test.lngv(p) ->> 'id')::uuid) $$;
do $$
declare i integer;
begin
  for i in 1 .. 5 loop
    insert into test.lng select 'car' || i, app.vehicle_add(test.id('lng_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1XFCXLR00000000' || lpad(i::text, 2, '0'),
      'plate', 'LRC00' || i, 'year', 2024, 'make', 'Kia', 'model', 'K5', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
  end loop;
end $$;
create function test.lngcar(p text) returns uuid language sql stable as $$ select (test.lngv(p) ->> 'vehicle_id')::uuid $$;
-- the owner's case: picked up yesterday, six weeks, a driver of 23, the rent in cash, the deposit by e-Transfer
create function test.lngrent(p_car text, p jsonb default '{}'::jsonb) returns jsonb language sql stable as $$
  select jsonb_build_object('vehicle_id', test.lngcar(p_car), 'pickup_at', date_trunc('hour', now()) - interval '1 day', 'return_at', date_trunc('hour', now()) + interval '41 days',
    'coverage_option', 3, 'source', 'walk_in', 'sales_choice', 'for_carmacars', 'agreement', 'paper',
    'drivers', jsonb_build_array(jsonb_build_object('role', 'renter', 'date_of_birth', (current_date - interval '23 years')::date)),
    'renter', jsonb_build_object('full_name', 'Yusuf Long', 'email', 'yusuf.long.' || p_car || '@example.test', 'mobile', '4165550142', 'date_of_birth', (current_date - interval '23 years')::date,
                                 'licence_number', 'L1234-12345-12345'),
    'payment', jsonb_build_object('mode', 'other_way', 'method', 'cash', 'received_on', app.today()),
    'deposit', jsonb_build_object('method', 'e_transfer', 'reference', 'ETDEP-' || p_car)) || p $$;

-- ================================================================ 1. the monthly rate and the longest booking
select test.eq('30 days: the monthly rate', (public.calc_rental_charge(now(), 30, 10000, 10000, 70000, 300000)).rental_charge_cents, 300000::bigint);
select test.eq('42 days: the monthly rate for each 30 days', (public.calc_rental_charge(now(), 42, 10000, 10000, 70000, 300000)).rental_charge_cents, 420000::bigint);
select test.eq('42 days: rate applied monthly', (public.calc_rental_charge(now(), 42, 10000, 10000, 70000, 300000)).rate_applied, 'monthly');
select test.eq('20 days: still the weekly rate capped at the monthly', (public.calc_rental_charge(now(), 20, 10000, 10000, 70000, 300000)).rental_charge_cents, 200000::bigint);
select test.eq('the longest online booking is 365 days by default', (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'max_rental_days'), '365');
update program_settings set max_rental_days = 365, staff_max_rental_days = 730, staff_may_edit_fees = true, staff_may_edit_bookings = true;   -- earlier files change the settings
select test.ok('a renter''s quote for six weeks is priced at the monthly rate',
  (app.price_quote(test.lngcar('car1'), now() + interval '2 days', now() + interval '44 days', '{}'::jsonb) ->> 'rental_charge_cents')::bigint = 420000);
select test.throws('a renter''s quote past the longest booking is refused', $$select app.price_quote(test.lngcar('car1'), now() + interval '2 days', now() + interval '400 days', '{}'::jsonb)$$, 'Shorten the dates');
select test.eq('the periods of six weeks: 30 days then the rest',
  (select string_agg(days::text, '+' order by seq) from app.rental_periods(timestamptz '2026-11-10 14:00-05', timestamptz '2026-12-22 14:00-05')), '30+12');
select test.eq('one period when it fits', (select count(*)::integer from app.rental_periods(now(), now() + interval '30 days')), 1);
select test.eq('a capped per-day fee: its cap for each period',
  app.calc_capped_periods(2000, timestamptz '2026-11-10 14:00-05', timestamptz '2026-12-22 14:00-05', 30000), 30000::bigint + 24000);

-- ================================================================ 2. the quick rental form: six weeks, underway, fees by hand, paid in parts
select test.ok('the quote of six weeks underway: priced, with two periods and fees this person may change',
  (select (q #>> '{quote,rental_charge_cents}')::bigint = 420000 and jsonb_array_length(q -> 'periods') = 2 and (q ->> 'may_edit_fees')::boolean and q ->> 'phase' = 'in_progress'
     from (select app.door(test.id('lng_admin'), 'aal2', 'ops_read', 'manual_rental_quote', test.lngrent('car1')) q) x));
select test.ok('the quote prices the young driver fee and the Protection Plan typed by hand',
  (select (select sum((l ->> 'amount_cents')::bigint) from jsonb_array_elements(q #> '{quote,lines}') l where l ->> 'charge_type' in ('young_driver_21_25', 'coverage_sold')) = 65000
     from (select app.door(test.id('lng_admin'), 'aal2', 'ops_read', 'manual_rental_quote',
             test.lngrent('car1', '{"line_overrides": {"young_driver_21_25": 25000, "coverage_sold": 40000}}')) q) x));
insert into test.lng select 'r1', app.door(test.id('lng_admin'), 'aal2', 'ops_do', 'manual_rental_create', test.lngrent('car1',
  '{"line_overrides": {"young_driver_21_25": 25000, "coverage_sold": 40000}, "fee_reason": "Agreed at the counter",
    "payment": {"mode": "other_way", "method": "cash", "amount_cents": 300000},
    "more_payments": [{"method": "e_transfer", "amount_cents": 200000, "reference": "ET-LR-778899"}]}'::jsonb
  || jsonb_build_object('payment', jsonb_build_object('mode', 'other_way', 'method', 'cash', 'amount_cents', 300000, 'received_on', app.today()))));
select test.eq('the rental six weeks long is on trip', (test.lngb('r1')).status::text, 'on_rent');
select test.eq('42 billable days', (test.lngb('r1')).billable_days, 42);
select test.eq('the rental charge at the monthly rate', (test.lngb('r1')).rental_charge_cents, 420000::bigint);
select test.eq('the young driver fee as typed', (select amount_cents from booking_line_items where booking_id = (test.lngb('r1')).id and charge_type = 'young_driver_21_25' and voided_at is null), 25000::bigint);
select test.eq('the Protection Plan as typed', (select amount_cents from booking_line_items where booking_id = (test.lngb('r1')).id and charge_type = 'coverage_sold' and voided_at is null), 40000::bigint);
select test.eq('the fees typed are recorded', (select count(*)::integer from booking_fee_changes where booking_id = (test.lngb('r1')).id and changed_by = test.id('lng_admin')), 2);
select test.eq('the rent in cash and the e-Transfer, the deposit by e-Transfer: four records',
  (select string_agg(method || ':' || coalesce(covers, 'whole'), ',' order by method, covers) from manual_payments where booking_id = (test.lngb('r1')).id),
  'cash:whole,e_transfer:deposit,e_transfer:fees,e_transfer:rental');
select test.eq('the deposit is taken by e-Transfer', (select d.paid_method from deposits d where d.booking_id = (test.lngb('r1')).id), 'e_transfer');
select test.eq('what is left to collect: the total less 5,000.00', (test.lngv('r1') ->> 'open_cents')::bigint, (test.lngb('r1')).total_due_at_booking_cents - 500000);
select test.eq('the rental part is paid in full (the lines are tied)', app.booking_part_open((test.lngb('r1')).id, 'rental'), 0::bigint);

-- ================================================================ 3. a fee changed on an existing booking
select test.throws('fleet does not change fees', $$select app.door(test.id('lng_fleet'), 'aal2', 'ops_do', 'booking_fees_change',
  jsonb_build_object('booking', (test.lngb('r1')).booking_number, 'lines', '{"young_driver_21_25": 1000}'::jsonb))$$, 'changes a fee');
select test.lives('customer service changes the young driver fee after confirmation', $$select app.door(test.id('lng_cs'), 'aal2', 'ops_do', 'booking_fees_change',
  jsonb_build_object('booking', (test.lngb('r1')).booking_number, 'lines', '{"young_driver_21_25": 20000}'::jsonb, 'reason', 'Loyal customer'))$$);
select test.eq('the line follows', (select amount_cents from booking_line_items where booking_id = (test.lngb('r1')).id and charge_type = 'young_driver_21_25' and voided_at is null), 20000::bigint);
select test.eq('the change is recorded with the before, the after and who',
  (select before_cents || '>' || after_cents || '/' || (changed_by = test.id('lng_cs'))::text || '/' || booking_status from booking_fee_changes
    where booking_id = (test.lngb('r1')).id and reason = 'Loyal customer'), '25000>20000/true/on_rent');
select test.ok('the booking''s history says it', exists (select 1 from booking_events e where e.booking_id = (test.lngb('r1')).id and e.note like 'Young driver, 21 to 25: $250.00 to $200.00%'));
update program_settings set staff_may_edit_fees = false;
select test.throws('with the setting off, customer service does not', $$select app.door(test.id('lng_cs'), 'aal2', 'ops_do', 'booking_fees_change',
  jsonb_build_object('booking', (test.lngb('r1')).booking_number, 'lines', '{"young_driver_21_25": 1000}'::jsonb))$$, 'changes a fee');
update program_settings set staff_may_edit_fees = true;
select test.ok('the fees read: lines with the hand-set flag, the history and may edit',
  (select jsonb_array_length(x -> 'history') = 3 and (x ->> 'may_edit')::boolean and exists (select 1 from jsonb_array_elements(x -> 'lines') l where l ->> 'key' = 'coverage_sold' and (l ->> 'set_by_hand')::boolean)
     from (select app.door(test.id('lng_sales'), 'aal2', 'ops_read', 'booking_fees', jsonb_build_object('booking', (test.lngb('r1')).booking_number)) x) q));
select test.lives('back to the computed amount', $$select app.door(test.id('lng_admin'), 'aal2', 'ops_do', 'booking_fees_change',
  jsonb_build_object('booking', (test.lngb('r1')).booking_number, 'lines', '{"coverage_sold": null}'::jsonb))$$);
select test.ok('the Protection Plan is the price table''s again (per day, 42 days)', (select amount_cents <> 40000 from booking_line_items where booking_id = (test.lngb('r1')).id and charge_type = 'coverage_sold' and voided_at is null));

-- ================================================================ 4. an offer: fees by hand from customer service, long dates
select test.ok('customer service previews a six-week offer with the young driver fee changed',
  (select (x ->> 'ok')::boolean and (x #>> '{booking,billable_days}')::integer >= 42
          and exists (select 1 from jsonb_array_elements(x #> '{booking,lines}') l where l ->> 'charge_type' = 'young_driver_21_25' and (l ->> 'amount_cents')::bigint = 9900)
     from (select app.door(test.id('lng_cs'), 'aal2', 'ops_read', 'offer_preview', jsonb_build_object('vehicle_id', test.lngcar('car2'),
             'pickup_at', date_trunc('hour', now()) + interval '3 days', 'return_at', date_trunc('hour', now()) + interval '45 days', 'coverage_option', 1, 'sales_choice', 'sourced',
             'renter', jsonb_build_object('full_name', 'Ola Offer', 'email', 'ola.lr@example.test', 'mobile', '4165550177', 'date_of_birth', (current_date - interval '22 years')::date),
             'line_overrides', '{"young_driver_21_25": 9900}'::jsonb)) x) q));
select test.ok('a staff offer of 400 days is allowed (staff limit 730)',
  (select (x ->> 'ok')::boolean from (select app.door(test.id('lng_admin'), 'aal2', 'ops_read', 'offer_preview', jsonb_build_object('vehicle_id', test.lngcar('car3'),
     'pickup_at', date_trunc('hour', now()) + interval '3 days', 'return_at', date_trunc('hour', now()) + interval '403 days', 'coverage_option', 1,
     'renter', jsonb_build_object('full_name', 'Ola Offer', 'email', 'ola.lr@example.test', 'mobile', '4165550177', 'date_of_birth', '1990-01-01'))) x) q));

-- ================================================================ 5. an on-trip booking edited directly (0132, the owner's addition)
select test.ok('the edit form: the rental on trip may be edited by customer service',
  (select x ->> 'refusal' is null and x ->> 'status' = 'on_rent' from (select app.door(test.id('lng_cs'), 'aal2', 'ops_read', 'booking_edit_form', jsonb_build_object('booking', (test.lngb('r1')).booking_number)) x) q));
select test.throws('fleet does not edit a booking', $$select app.door(test.id('lng_fleet'), 'aal2', 'ops_do', 'booking_staff_edit',
  jsonb_build_object('booking', (test.lngb('r1')).booking_number, 'changes', jsonb_build_object('notes', 'x')))$$, 'edits a booking');
insert into test.lng select 'e1', app.door(test.id('lng_cs'), 'aal2', 'ops_do', 'booking_staff_edit', jsonb_build_object('booking', (test.lngb('r1')).booking_number,
  'changes', jsonb_build_object('return_at', (test.lngb('r1')).return_at + interval '7 days'), 'lines', '{"young_driver_21_25": 30000}'::jsonb,
  'reason', 'Extended a week by phone', 'tell_renter', true));
select test.eq('extended a week: 49 days', (test.lngb('r1')).billable_days, 49);
select test.eq('the rental is repriced at the monthly rate', (test.lngb('r1')).rental_charge_cents, 490000::bigint);
select test.eq('the young driver fee as changed in the same edit', (select amount_cents from booking_line_items where booking_id = (test.lngb('r1')).id and charge_type = 'young_driver_21_25' and voided_at is null), 30000::bigint);
select test.eq('still on trip', (test.lngb('r1')).status::text, 'on_rent');
select test.ok('the edit is recorded with who, why and the totals',
  (select e.edited_by = test.id('lng_cs') and e.reason = 'Extended a week by phone' and e.told_renter and e.total_after_cents > e.total_before_cents
     from booking_staff_edits e where e.booking_id = (test.lngb('r1')).id));
select test.ok('the renter is told: an applied change by staff', exists (select 1 from booking_change_requests c where c.booking_id = (test.lngb('r1')).id and c.status = 'applied' and c.source = 'staff_calendar'));
select test.ok('more to collect after the extension', (test.lngv('e1') ->> 'open_cents')::bigint > 0);
select test.lives('a second cash payment recorded', $$select app.door(test.id('lng_cs'), 'aal2', 'ops_do', 'record_booking_payment',
  jsonb_build_object('booking', (test.lngb('r1')).booking_number, 'covers', 'rental', 'method', 'cash', 'amount_cents', 70000))$$);
select test.throws('customer service does not change the deposit', $$select app.door(test.id('lng_cs'), 'aal2', 'ops_do', 'booking_staff_edit',
  jsonb_build_object('booking', (test.lngb('r1')).booking_number, 'changes', jsonb_build_object('deposit_cents', 1)))$$, 'Only an Admin');
select test.lives('an Admin swaps the car on trip, quietly', $$select app.door(test.id('lng_admin'), 'aal2', 'ops_do', 'booking_staff_edit',
  jsonb_build_object('booking', (test.lngb('r1')).booking_number, 'changes', jsonb_build_object('vehicle_id', test.lngcar('car4')), 'reason', 'Brake noise'))$$);
select test.eq('the car follows, with the swap of record', (select count(*)::integer from booking_vehicle_swaps s where s.booking_id = (test.lngb('r1')).id and s.to_vehicle_id = test.lngcar('car4')), 1);
select test.throws('extending over another booking is refused with its number', format($$select app.door(test.id('lng_admin'), 'aal2', 'ops_do', 'booking_staff_edit',
  jsonb_build_object('booking', %L, 'changes', jsonb_build_object('return_at', %L::timestamptz + interval '1000 days')))$$,
  (test.lngb('r1')).booking_number, (test.lngb('r1')).return_at), 'days');

-- ================================================================ 6. the Stripe events the site now hears (0132)
with p as (insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at)
           select b.id, b.renter_id, 'post_rental', 'charge', 'card', 50000, 'succeeded', now() from bookings b where b.id = (test.lngb('r1')).id returning id)
insert into payment_processor_details (payment_id, processor, processor_payment_id, processor_charge_id) select id, 'stripe', 'pi_lng1', 'ch_lng1' from p;
select test.eq('a refund made in Stripe''s dashboard is recorded',
  public.server_stripe_refund_event('{"refund_id": "re_lng1", "status": "succeeded", "amount_cents": 2000, "intent_id": "pi_lng1", "charge_id": "ch_lng1"}') ->> 'recorded', 'true');
select test.eq('the same event again changes nothing', public.server_stripe_refund_event('{"refund_id": "re_lng1", "status": "succeeded", "amount_cents": 2000, "intent_id": "pi_lng1"}') ->> 'unchanged', 'true');
select test.eq('one refund record', (select count(*)::integer from payments x join payment_processor_details pd on pd.payment_id = x.id where pd.processor_refund_id = 're_lng1'), 1);
select test.ok('Finance has the task', exists (select 1 from tasks t where t.dedupe_key = 'stripe_refund_outside:re_lng1'));
select test.eq('a failed refund is marked failed', public.server_stripe_refund_event('{"refund_id": "re_lng1", "status": "failed"}') ->> 'failed', 'true');
select test.ok('with a task to give it back another way', exists (select 1 from tasks t where t.dedupe_key = 'stripe_refund_failed:re_lng1'));
select test.eq('a dispute is recorded', public.server_stripe_dispute_event('{"dispute_id": "dp_lng1", "status": "needs_response", "amount_cents": 50000, "reason": "fraudulent", "charge_id": "ch_lng1", "evidence_due_at": "2030-01-10T00:00:00Z"}') ->> 'recorded', 'true');
select test.eq('the Admin and Finance get tasks', (select count(*)::integer from tasks t where t.dedupe_key in ('stripe_dispute:dp_lng1', 'stripe_dispute_finance:dp_lng1')), 2);
select test.eq('the dispute closes as lost', (public.server_stripe_dispute_event('{"dispute_id": "dp_lng1", "status": "lost"}') ->> 'status'), 'lost');
select test.ok('lost, resolved', (select status = 'lost' and resolved_at is not null from disputes where processor_dispute_ref = 'dp_lng1'));
select test.eq('an object of no payment of ours is ignored', public.server_stripe_dispute_event('{"dispute_id": "dp_x", "charge_id": "ch_none"}') ->> 'ignored', 'no payment of ours');

-- ================================================================ 7. a renter's details corrected (0132)
select test.throws('fleet does not edit a renter', $$select app.door(test.id('lng_fleet'), 'aal2', 'ops_do', 'renter_edit', jsonb_build_object('booking', (test.lngb('r1')).booking_number, 'email', 'x@example.test'))$$, 'corrects a renter');
select test.throws('an email of another person is refused by name', format($$select app.door(test.id('lng_cs'), 'aal2', 'ops_do', 'renter_edit', jsonb_build_object('booking', %L, 'email', 'lng_admin@example.test'))$$,
  (test.lngb('r1')).booking_number), 'already on file');
insert into test.lng select 're1', app.door(test.id('lng_cs'), 'aal2', 'ops_do', 'renter_edit', jsonb_build_object('booking', (test.lngb('r1')).booking_number,
  'email', 'Yusuf.Right@Example.test', 'licence_expiry', '2031-05-01', 'staff_note', 'Prefers texts', 'reason', 'Typo at the counter'));
select test.eq('the email is corrected on the renter and the account', (select r.email || '/' || u.email from renters r join users u on u.id = r.user_id where r.id = (test.lngb('r1')).renter_id), 'yusuf.right@example.test/yusuf.right@example.test');
select test.eq('the result says the email changed (the server updates the sign-in)', test.lngv('re1') ->> 'email_changed', 'true');
select test.eq('the licence expiry follows to the booking''s driver', (select licence_expiry from booking_drivers where booking_id = (test.lngb('r1')).id and role = 'renter'), date '2031-05-01');
select test.ok('the correction is kept with who and why', exists (select 1 from renter_edits e where e.renter_id = (test.lngb('r1')).renter_id and e.edited_by = test.id('lng_cs') and e.email_changed and e.reason = 'Typo at the counter'));
select test.ok('the edit form shows it', (select jsonb_array_length(x -> 'edits') = 1 and (x ->> 'may_edit')::boolean from (select app.door(test.id('lng_sales'), 'aal2', 'ops_read', 'renter_edit_form', jsonb_build_object('booking', (test.lngb('r1')).booking_number)) x) q));

-- ================================================================ 8. a forgotten fee added, the balance, paid by link (0132, booking CC-10012)
select test.ok('the fees read suggests the additional driver fee for the days, and shows the balance by part',
  (select (x #> '{parts}') ? 'balance' from (select app.door(test.id('lng_cs'), 'aal2', 'ops_read', 'booking_fees', jsonb_build_object('booking', (test.lngb('r1')).booking_number)) x) q));
select test.lives('a charge of its own, without HST', $$select app.door(test.id('lng_cs'), 'aal2', 'ops_do', 'booking_custom_fee',
  jsonb_build_object('booking', (test.lngb('r1')).booking_number, 'label', 'Parking ticket handling', 'amount_cents', 4000, 'hst', false))$$);
select test.eq('the line is on the booking, no HST', (select amount_cents || '/' || hst_cents from booking_line_items where booking_id = (test.lngb('r1')).id and charge_type = 'custom_fee' and voided_at is null), '4000/0');
select app.sync_booking_price((test.lngb('r1')).id);
select test.eq('it survives a reprice', (select count(*)::integer from booking_line_items where booking_id = (test.lngb('r1')).id and charge_type = 'custom_fee' and voided_at is null), 1);
select test.ok('something is open after the charge', app.booking_part_open((test.lngb('r1')).id, 'balance') > 0);
select test.ok('the balance is what the rental and the fees leave open', app.booking_part_open((test.lngb('r1')).id, 'balance') = app.booking_part_open((test.lngb('r1')).id, 'rental') + app.booking_part_open((test.lngb('r1')).id, 'fees'));
insert into test.lng select 'pr', app.door(test.id('lng_cs'), 'aal2', 'ops_do', 'payreq_create', jsonb_build_object('booking', (test.lngb('r1')).booking_number, 'kind', 'charge', 'covers', 'balance',
  'channel', 'link', 'token_sha256', md5(random()::text) || md5(random()::text), 'reason', 'the balance after the changes'));
select test.eq('a pay link for exactly the balance', (test.lngv('pr') ->> 'amount_cents')::bigint, app.booking_part_open((test.lngb('r1')).id, 'balance'));
-- paid by card through the link: the balance is nothing
update payment_requests set processor_intent_id = 'pi_lngbal' where id = (test.lngv('pr') ->> 'id')::uuid;
select test.eq('the card pays the balance', public.server_payreq_settle((test.lngv('pr') ->> 'id')::uuid, jsonb_build_object('id', 'pi_lngbal', 'status', 'succeeded', 'amount', (test.lngv('pr') ->> 'amount_cents')::bigint)) ->> 'ok', 'true');
select test.eq('nothing open after it', app.booking_part_open((test.lngb('r1')).id, 'balance'), 0::bigint);
select test.eq('rental and fees each closed', app.booking_part_open((test.lngb('r1')).id, 'rental') + app.booking_part_open((test.lngb('r1')).id, 'fees'), 0::bigint);
select test.throws('the renter''s own pay link: nothing owing now', format($$select public.renter_balance_payreq(%L, (select r.user_id from renters r where r.id = %L), %L)$$,
  (test.lngb('r1')).id, (test.lngb('r1')).renter_id, md5(random()::text) || md5(random()::text)), 'Nothing is owing');
-- paid in full by card on the website, then a fee forgotten is added: it is open (it used to read as paid)
insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at)
select b.id, b.renter_id, 'booking_total', 'charge', 'card', 1, 'succeeded', now() from bookings b where b.id = (test.lngb('r1')).id;
select app.door(test.id('lng_admin'), 'aal2', 'ops_do', 'booking_custom_fee', jsonb_build_object('booking', (test.lngb('r1')).booking_number, 'label', 'Young driver fee forgotten', 'amount_cents', 10000));
select test.eq('after a card payment of the whole booking, the fee added later is open (less the 1 cent paid)', app.booking_part_open((test.lngb('r1')).id, 'balance'), 11300::bigint - 1);

-- ================================================================ 9. every confirmed booking gets its agreement (0132, booking CC-10013)
insert into test.lng select 'r5', app.door(test.id('lng_admin'), 'aal2', 'ops_do', 'manual_rental_create', test.lngrent('car5', '{"agreement": "send", "line_overrides": {}}'::jsonb
  || jsonb_build_object('pickup_at', date_trunc('hour', now()) + interval '2 days', 'return_at', date_trunc('hour', now()) + interval '9 days')));
select test.ok('a rental added to sign online, with no agreement yet, is due', (select app.booking_needs_agreement(b) from bookings b where b.id = (test.lngb('r5')).id));
select test.ok('the job lists it with the renter''s account', exists (select 1 from jsonb_array_elements(public.server_agreements_due(50)) x where x ->> 'booking_id' = (test.lngb('r5')).id::text and x ->> 'renter_user_id' is not null));
select test.ok('one signed on paper is not', not (select app.booking_needs_agreement(b) from bookings b where b.id = (test.lngb('r1')).id));
select public.server_agreement_auto_done((test.lngb('r5')).id, false, 'render failed'), public.server_agreement_auto_done((test.lngb('r5')).id, false, 'render failed'), public.server_agreement_auto_done((test.lngb('r5')).id, false, 'render failed');
select test.ok('after three failures it stops trying and staff get a task', not (select app.booking_needs_agreement(b) from bookings b where b.id = (test.lngb('r5')).id)
  and exists (select 1 from tasks t where t.dedupe_key = 'agreement_auto_failed:' || (test.lngb('r5')).id));
select test.ok('the jobs flag says when there is work', (app.server_jobs_due() ? 'agreements'));
