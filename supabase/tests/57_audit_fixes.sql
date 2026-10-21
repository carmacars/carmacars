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
