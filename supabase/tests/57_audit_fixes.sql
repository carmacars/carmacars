-- 57: the audit fixes of 0079 (October 21, 2026): the company address on CarmaCars' documents, a listing row for every
-- real car, the commission base (rental charge only, refunds of other charges never lower it), add-on photos.
select test.suite('57 audit fixes');

select test.mk_user('af_admin', 'admin');
select test.mk_user('af_fin', 'va', 'finance');
select test.mk_owner('af_owner');
select test.mk_vehicle('AF1', 'af_owner');
select test.mk_renter('af_rita');
insert into investors (id, legal_name, investor_type) values (test.id('inv:af'), 'Ana Investor', 'individual');

-- ================================================================ 1. the company address
select test.eq('address: Program settings hold the owner''s mailing address', (app.settings()).company_address,
  '2967 Dundas St W, Unit 208B, Toronto, ON M6P 1Z2');
select test.eq('address: the street address has its postal code', (select street_address from site_settings where singleton),
  '1570 Midland Ave, Toronto, ON M1P 3C3');
select test.eq('address: the owner Enrollment Agreement (notice clause) prints it',
  app.owner_agreement_facts_0029(test.id('owner:af_owner'), test.id('af_admin')) #>> '{company,address}', '2967 Dundas St W, Unit 208B, Toronto, ON M6P 1Z2');
select test.eq('address: the staff agreement prints it',
  app.staff_agreement_prepare_0057(test.id('af_admin'), test.id('af_fin')) #>> '{company,address}', '2967 Dundas St W, Unit 208B, Toronto, ON M6P 1Z2');
select test.eq('address: the investor agreement prints it',
  app.investor_agreement_prepare(test.id('af_admin'), test.id('inv:af')) #>> '{company,address}', '2967 Dundas St W, Unit 208B, Toronto, ON M6P 1Z2');
select test.eq('address: the ServiceOntario registry context has it',
  app.registry_context_0022(test.id('vehicle:AF1')) #>> '{registrant,address}', '2967 Dundas St W, Unit 208B, Toronto, ON M6P 1Z2');
-- emptied in Program settings: the site's mailing address stands in
update program_settings set company_address = ' ';
select test.eq('address: with none in Program settings, the site''s mailing address',
  app.registry_context_0022(test.id('vehicle:AF1')) #>> '{registrant,address}', '2967 Dundas St W, Unit 208B, Toronto, ON M6P 1Z2');
update program_settings set company_address = '10 New Street, Toronto, ON M5V 1A1';
select test.eq('address: a later change in Program settings is printed',
  app.staff_agreement_prepare_0057(test.id('af_admin'), test.id('af_fin')) #>> '{company,address}', '10 New Street, Toronto, ON M5V 1A1');
update program_settings set company_address = '2967 Dundas St W, Unit 208B, Toronto, ON M6P 1Z2';

-- ================================================================ 2. a listing row for every real car
insert into vehicles (id, owner_id, year, make, model, plate, class, status, management_mode, onboarding_method)
values (test.id('vehicle:AFN'), test.id('owner:af_owner'), 2021, 'KIA', 'Forte', 'AFN123', 'standard', 'onboarding', 'managed', 'transfer');
select test.eq('listing: a car added gets its draft listing at once (Publish now on the car page)',
  (select status || '/' || coalesce(slug, '-') || '/' || array_to_string(channels, ',') from vehicle_listings where vehicle_id = test.id('vehicle:AFN')), 'draft/-/website');
select test.ok('listing: the car is in the listings list as not on the site',
  exists (select 1 from jsonb_array_elements(app.vehicle_public_gates(test.id('vehicle:AFN'))) g where g ->> 'code' = 'listing'));
select test.lives('listing: a listing written in full for a new car replaces the empty draft',
  $$insert into vehicle_listings (vehicle_id, slug, headline, status) values (test.id('vehicle:AF1'), 'af1-test', 'Test car', 'draft')$$);
select test.eq('listing: one row per car, the one written', (select count(*) || '/' || max(headline) from vehicle_listings where vehicle_id = test.id('vehicle:AF1')), '1/Test car');
update vehicle_listings set headline = 'Worked on' where vehicle_id = test.id('vehicle:AFN');
select test.throws('listing: a draft someone worked on is never replaced',
  $$insert into vehicle_listings (vehicle_id, status) values (test.id('vehicle:AFN'), 'draft')$$, 'duplicate key');
select test.eq('listing: every real car has its row', (select count(*) from vehicles v where not v.is_sample
  and not exists (select 1 from vehicle_listings l where l.vehicle_id = v.id)), 0::bigint);

-- ================================================================ 3. the commission base
-- 3 days at $100.00 = $300.00 rental; delivery $75.00, kilometres $35.00, an add-on $20.00, late extra day $100.00
select test.mk_booking('AF-1', 'AF1', 'af_rita', '2026-11-02 10:00', '2026-11-05 10:00', 'closed', 30000);
update bookings set confirmed_at = booked_at where id = test.id('booking:AF-1');
select test.mk_line('AF-1', 'delivery', 7500);
select test.mk_line('AF-1', 'mileage_overage', 3500);
select test.mk_line('AF-1', 'addon', 2000);
select test.eq('base: the rental charge only (no delivery, kilometres or add-on)',
  app.commission_base_cents(test.id('booking:AF-1')) || '/' || app.sales_revenue_cents(test.id('booking:AF-1')), '30000/30000');
select test.mk_line('AF-1', 'late_return_extra_days', 10000);
select test.mk_line('AF-1', 'late_return_fee', 5000);
select test.eq('base: late extra days count, the late fee does not', app.commission_base_cents(test.id('booking:AF-1')), 40000::bigint);

-- a refund of the delivery, entered by an Admin with what it is for
create temp table af_r1 as select public.door(test.id('af_admin'), null, 'admin_do', 'request_refund',
  jsonb_build_object('booking', test.id('booking:AF-1'), 'amount_cents', 8475, 'reason', 'goodwill', 'refund_of', 'delivery', 'note', 'Delivery was late')) r;
select test.eq('refund: what it is for is kept', (select refund_of from refunds where id = (select (r ->> 'id')::uuid from af_r1)), 'delivery');
update refunds set status = 'approved', approved_by = test.id('af_admin'), approved_at = now() where id = (select (r ->> 'id')::uuid from af_r1);
select test.eq('base: a delivery refund does not lower it', app.commission_base_cents(test.id('booking:AF-1')), 40000::bigint);
-- a kilometre refund, entered by Finance
create temp table af_r2 as select public.door(test.id('af_fin'), null, 'va_do', 'request_refund',
  jsonb_build_object('booking', test.id('booking:AF-1'), 'amount_cents', 3955, 'reason', 'pricing_error', 'refund_of', 'kilometres')) r;
update refunds set status = 'approved', approved_by = test.id('af_admin'), approved_at = now() where id = (select (r ->> 'id')::uuid from af_r2);
select test.eq('base: a kilometre refund does not lower it', app.commission_base_cents(test.id('booking:AF-1')), 40000::bigint);
select test.throws('refund: an unknown kind is refused', format($$select public.door(%L, null, 'admin_do', 'request_refund', %L)$$, test.id('af_admin'),
  jsonb_build_object('booking', test.id('booking:AF-1'), 'amount_cents', 100, 'reason', 'goodwill', 'refund_of', 'tips')), 'Say what the refund is for');
-- a refund of the rental charge comes off before tax
create temp table af_r3 as select public.door(test.id('af_admin'), null, 'admin_do', 'request_refund',
  jsonb_build_object('booking', test.id('booking:AF-1'), 'amount_cents', 5650, 'reason', 'breakdown_unused_days', 'refund_of', 'rental')) r;
update refunds set status = 'approved', approved_by = test.id('af_admin'), approved_at = now() where id = (select (r ->> 'id')::uuid from af_r3);
select test.eq('base: a rental refund of $56.50 takes $50.00 off', app.commission_base_cents(test.id('booking:AF-1')), 35000::bigint);
-- an older refund that says nothing is the rental (as before)
insert into refunds (booking_id, reason, amount_cents, status, requested_by, approved_by, approved_at)
values (test.id('booking:AF-1'), 'goodwill', 1130, 'approved', test.id('af_admin'), test.id('af_admin'), now());
select test.eq('base: a refund that does not say is taken as the rental (as before 0079)', app.commission_base_cents(test.id('booking:AF-1')), 34000::bigint);
-- a change of booking's refund: its new price is already in the booking
insert into refunds (booking_id, reason, amount_cents, status, requested_by, approved_by, approved_at, note)
values (test.id('booking:AF-1'), 'other', 11300, 'approved', test.id('af_admin'), test.id('af_admin'), now(), 'Change of booking: one day shorter');
select test.eq('refund: a change of booking''s refund is marked as such', (select refund_of from refunds where note = 'Change of booking: one day shorter'), 'booking_change');
select test.eq('base: a change of booking''s refund is not taken off twice', app.commission_base_cents(test.id('booking:AF-1')), 34000::bigint);

-- a refund spread over the lines (a cancellation share): only its rental lines count
select test.mk_booking('AF-2', 'AF1', 'af_rita', '2026-11-12 10:00', '2026-11-14 10:00', 'closed', 20000);
update bookings set confirmed_at = booked_at where id = test.id('booking:AF-2');
select test.mk_line('AF-2', 'delivery', 10000);
insert into refunds (id, booking_id, reason, refund_bps, amount_cents, status, requested_by, approved_by, approved_at)
values (test.id('refund:AF-2'), test.id('booking:AF-2'), 'goodwill', 5000, 16950, 'approved', test.id('af_admin'), test.id('af_admin'), now());
select app.allocate_refund(test.id('refund:AF-2'));
select test.eq('base: a refund spread over rental and delivery takes off only the rental part (50% of $200.00)',
  app.commission_base_cents(test.id('booking:AF-2')), 10000::bigint);
select test.eq('base: booked revenue the same', app.sales_revenue_cents(test.id('booking:AF-2')), 10000::bigint);

-- ================================================================ 4. add-on photos
select test.eq('add-ons: every one has a photo', (select count(*) from addons where photo_path is null), 0::bigint);
select test.eq('add-ons: the studio illustrations', (select photo_path from addons where code = 'flowers'), '/addon-photos/flowers.svg');

-- ================================================================ 5. privileges
select test.ok('doors: the helpers are not callable by signed-in users',
  not has_function_privilege('authenticated', 'app.refund_rental_part_cents(uuid, integer)', 'execute')
  and not has_function_privilege('authenticated', 'app.company_address()', 'execute')
  and not has_function_privilege('anon', 'app.admin_do(uuid, text, jsonb)', 'execute'));
select test.ok('doors: admin_do and va_do keep their privileges',
  has_function_privilege('service_role', 'app.admin_do(uuid, text, jsonb)', 'execute') and has_function_privilege('service_role', 'app.va_do(uuid, text, jsonb)', 'execute'));

-- ================================================================ 6. the second audit
-- 6a. the pickup fee follows the delivery fee when left empty
select test.eq('pickup: an empty pickup fee is the delivery fee',
  (app.rate_card_check(test.id('vehicle:AFN'), jsonb_build_object('daily', 9000, 'delivery', 12000, 'deposit', 50000)) #>> '{values,pickup}'), '12000');
select test.eq('pickup: a pickup fee typed as 0 stays not offered',
  (app.rate_card_check(test.id('vehicle:AFN'), jsonb_build_object('daily', 9000, 'delivery', 12000, 'pickup', 0, 'deposit', 50000)) #>> '{values,pickup}'), '0');
-- 6b. the street address stays public, with its postal code (the owner's answer)
select test.eq('street address: still shown publicly', (select show_street_address from site_settings where singleton), true);
-- 6c. template copy is never compared
insert into vehicles (id, owner_id, year, make, model, plate, class, status, management_mode, onboarding_method)
values (test.id('vehicle:AFC1'), test.id('owner:af_owner'), 2021, 'Volkswagen', 'Jetta', 'AFC111', 'standard', 'available', 'managed', 'transfer'),
       (test.id('vehicle:AFC2'), test.id('owner:af_owner'), 2015, 'Cadillac', 'CTS', 'AFC222', 'standard', 'available', 'managed', 'transfer');
update vehicle_listings set status = 'published', slug = 'afc-' || substr(vehicle_id::text, 1, 6), headline = 'A car to rent in Toronto with delivery',
       description = 'This car is available to rent in Toronto. Collect it at our location or have it delivered. Send a request with your dates and we confirm the car and the price before you pay anything.'
 where vehicle_id in (test.id('vehicle:AFC1'), test.id('vehicle:AFC2'));
insert into car_copy (vehicle_id, facts, facts_hash, source) values (test.id('vehicle:AFC1'), '{}', 'x', 'template'), (test.id('vehicle:AFC2'), '{}', 'y', 'template')
on conflict (vehicle_id) do update set source = 'template';
select app.check_listing_similarity(test.id('vehicle:AFC1'), 'copy');
select test.eq('similarity: two cars sharing only the template copy are not flagged',
  (select count(*) from listing_similarity_flags where kind = 'copy' and test.id('vehicle:AFC1') in (vehicle_id, other_vehicle_id)), 0::bigint);
update car_copy set source = 'ai' where vehicle_id in (test.id('vehicle:AFC1'), test.id('vehicle:AFC2'));
select app.check_listing_similarity(test.id('vehicle:AFC1'), 'copy');
select test.ok('similarity: copy written for each car is still compared',
  exists (select 1 from listing_similarity_flags where kind = 'copy' and vehicle_id = test.id('vehicle:AFC1')));
-- 6d. a shareholder's own car
select test.throws('shareholder: an Admin only', format($$select app.set_shareholder_car(%L, %L)$$, test.id('af_fin'),
  jsonb_build_object('vehicle', test.id('vehicle:AF1'), 'on', true)), null);
select app.set_shareholder_car(test.id('af_admin'), jsonb_build_object('vehicle', test.id('vehicle:AF1'), 'on', true, 'reason', 'The partner''s own car'));
select test.eq('shareholder: the car is a shareholder''s car and the owner a shareholder',
  (select v.is_shareholder_owned::text || '/' || v.billing_case || '/' || o.is_shareholder from vehicles v join owners o on o.id = v.owner_id where v.id = test.id('vehicle:AF1')), 'true/shareholder/true');
select test.ok('shareholder: in the audit log with the reason', exists (select 1 from audit_log where action = 'shareholder_car' and entity_id = test.id('vehicle:AF1')::text and after ->> 'reason' = 'The partner''s own car'));
select test.eq('shareholder: through the Admin door', (public.door(test.id('af_admin'), null, 'admin_do', 'shareholder_car', jsonb_build_object('vehicle', test.id('vehicle:AF1'), 'on', false)) ->> 'shareholder'), 'false');
select test.eq('shareholder: turned off, the owner is no longer a shareholder', (select is_shareholder from owners where id = test.id('owner:af_owner')), false);
-- 6h. a shareholder's own car never gets a first and last month
select app.set_shareholder_car(test.id('af_admin'), jsonb_build_object('vehicle', test.id('vehicle:AF1'), 'on', true, 'reason', 'test'));
select test.throws('shareholder: no first and last month invoice for a shareholder''s car',
  format($$insert into owner_invoices (owner_id, vehicle_id, kind, status, invoice_number, billing_date) values (%L, %L, 'upfront', 'draft', 'INV-AF-1', current_date)$$,
         test.id('owner:af_owner'), test.id('vehicle:AF1')), 'shareholder');
select app.set_shareholder_car(test.id('af_admin'), jsonb_build_object('vehicle', test.id('vehicle:AF1'), 'on', false, 'reason', 'test'));
-- 6i. Protection Plan prices for every class and age band
select test.eq('coverage: one price for every class and age band', (select count(distinct (class_code, age_band)) from coverage_prices
  where vehicle_id is null and effective_to is null and class_code in ('economy', 'standard', 'premium', 'suv', 'luxury', 'exotic', 'van', 'pickup')), 24::bigint);
select test.eq('coverage: a standard car, a driver 26 and over', (app.coverage_term(test.id('vehicle:AFN'), '26_plus', app.today()) ->> 'amount_cents'), '2800');
-- 6e. the cancellation tiers from Program settings, unchanged
select test.eq('cancellation: the tiers as before',
  (select r1.refund_bps || '/' || r2.refund_bps || '/' || r3.refund_bps || '/' || r4.refund_bps
     from public.calc_cancellation(now() - interval '2 hours', now(), now() + interval '72 hours', false, 10000) r1,
          public.calc_cancellation(now() - interval '5 days', now(), now() + interval '72 hours', false, 10000) r2,
          public.calc_cancellation(now() - interval '5 days', now(), now() + interval '30 hours', false, 10000) r3,
          public.calc_cancellation(now() - interval '5 days', now(), now() + interval '3 hours', false, 10000) r4), '9500/7500/5000/0');
update program_settings set cancel_refund_48h_plus_bps = 8000;
select test.eq('cancellation: an Admin''s new percentage applies', (public.calc_cancellation(now() - interval '5 days', now(), now() + interval '72 hours', false, 10000)).refund_cents, 8000::bigint);
update program_settings set cancel_refund_48h_plus_bps = 7500;

-- 6f. add-ons bought after booking with no card on file, paid online
select test.mk_booking('AF-3', 'AF1', 'af_rita', to_char(now() + interval '20 days', 'YYYY-MM-DD 10:00'), to_char(now() + interval '23 days', 'YYYY-MM-DD 10:00'), 'confirmed', 30000);
create temp table af_buy as select app.booking_addon_buy(test.id('booking:AF-3'), test.id('af_rita'), jsonb_build_object('code', 'umbrella')) f;
select app.booking_addon_paid(((select f from af_buy) ->> 'booking_addon_id')::uuid, test.id('af_rita'), null, null);
select test.eq('add-on pay: the unpaid add-on is due on the booking',
  (app.my_unpaid_addons(test.id('booking:AF-3'), test.id('af_rita')) ->> 'total_cents')::bigint, ((select f from af_buy) ->> 'amount_cents')::bigint);
select test.throws('add-on pay: only the renter reads it', format($$select app.my_unpaid_addons(%L, %L)$$, test.id('booking:AF-3'), test.id('af_fin')), 'renter');
select test.eq('add-on pay: another amount is refused (and refunded by the caller)',
  app.addons_paid_online(test.id('booking:AF-3'), test.id('af_rita'), '{"processor": "stripe", "payment_id": "pi_af_1"}', 1) ->> 'reason', 'amount_mismatch');
select test.eq('add-on pay: the right amount is recorded',
  app.addons_paid_online(test.id('booking:AF-3'), test.id('af_rita'), '{"processor": "stripe", "payment_id": "pi_af_1", "charge_id": "ch_af_1"}',
                         ((select f from af_buy) ->> 'amount_cents')::bigint) ->> 'ok', 'true');
select test.eq('add-on pay: nothing left to pay, the line and the add-on paid, the Finance task closed',
  (app.unpaid_addons(test.id('booking:AF-3')) ->> 'total_cents') || '/' ||
  (select (ba.payment_id is not null and li.payment_id = ba.payment_id)::text from booking_addons ba join booking_line_items li on li.id = ba.line_item_id
    where ba.id = ((select f from af_buy) ->> 'booking_addon_id')::uuid) || '/' ||
  (select string_agg(status, ',') from tasks where task_type = 'addon_payment' and related_id = ((select f from af_buy) ->> 'booking_addon_id')::uuid), '0/true/done');
select test.eq('add-on pay: the same payment again is a replay',
  app.addons_paid_online(test.id('booking:AF-3'), test.id('af_rita'), '{"processor": "stripe", "payment_id": "pi_af_1"}', 1) ->> 'already', 'true');

-- 6g. the card forms opened
select public.server_payment_intent_opened(jsonb_build_object('payment_id', 'pi_af_open', 'purpose', 'booking_total', 'booking_id', test.id('booking:AF-3'), 'amount_cents', 33900, 'by', test.id('af_rita')));
select public.server_payment_intent_opened(jsonb_build_object('payment_id', 'pi_af_open', 'purpose', 'booking_total', 'booking_id', test.id('booking:AF-3'), 'amount_cents', 33900, 'by', test.id('af_rita')));
select test.eq('intents: a card form opened is on record once, counted each time', (select times_opened || '/' || amount_cents from payment_intents_opened where processor_payment_id = 'pi_af_open'), '2/33900');
select test.ok('intents: not callable by signed-in users', not has_function_privilege('authenticated', 'public.server_payment_intent_opened(jsonb)', 'execute')
  and not has_function_privilege('anon', 'public.server_addons_paid_online(uuid, uuid, jsonb, bigint)', 'execute'));
