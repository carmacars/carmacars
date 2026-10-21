-- 49: no roadblocks to a listing, the fleet policy at the handover, and the proof of coverage (migration 0070).
-- A car with only the basics publishes (rates from similar cars, details by default, sample photos, copy for the writer)
-- and is public while its paperwork is open; what is left shows as warnings; the handover waits for the fleet policy;
-- coverage option 2 confirms itself with a paid credit card and the renter's confirmation, never with a debit card;
-- option 1 needs the insurer, policy number and an expiry that covers the rental. Fixtures start with "nr".
select test.suite('49 listing without roadblocks, coverage');

select test.mk_user('nr_admin', 'admin');
select test.mk_owner('nr_own');
select test.mk_vehicle('NR2', 'nr_own');
select test.mk_renter('nr_rita');
select test.mk_renter('nr_ben');

-- ================================================================ 1. a car with only the basics
insert into vehicles (id, owner_id, year, make, model, vin, plate, class, status, management_mode, onboarding_method, on_fleet_policy)
values (test.id('vehicle:NR1'), test.id('owner:nr_own'), 2021, 'Kia', 'Forte NR', 'NR1KIAFORTE000001', 'NR1AAA', 'standard', 'onboarding', 'managed', 'transfer', false);

select test.eq('only year, make, model and a plate or VIN block a listing', app.listing_spec_problems(test.id('vehicle:NR1')), '{}'::text[]);
select test.ok('the rest are warnings: colour, body style, seats, transmission',
  app.listing_spec_warnings(test.id('vehicle:NR1')) @> array['Colour', 'Seats', 'Transmission']);
select test.eq('not on the site: one gate, publish', (select string_agg(x ->> 'code', ',') from jsonb_array_elements(app.vehicle_public_gates(test.id('vehicle:NR1'))) x), 'listing');
select test.ok('warnings name the fleet policy (a handover gate) and the missing rates',
  (select bool_or(x ->> 'code' = 'fleet_policy' and x ->> 'stage' = 'handover') and bool_or(x ->> 'code' = 'rates')
     from jsonb_array_elements(app.vehicle_listing_warnings(test.id('vehicle:NR1'))) x));

select test.ok('an Admin publishes it as it is', (app.publish_listing(test.id('vehicle:NR1'), test.id('nr_admin')) ->> 'status') = 'published');
select test.ok('rates from defaults (similar cars or $75 a day), the weekend, weekly and monthly rates follow',
  exists (select 1 from rate_cards r where r.vehicle_id = test.id('vehicle:NR1') and r.effective_to is null and r.daily_rate_cents > 0
             and r.weekend_rate_cents > 0 and r.weekly_rate_cents > 0 and r.monthly_rate_cents > 0));
select test.eq('details by default: 5 seats, automatic, a headline from the car',
  (select format('%s %s %s', l.seats, l.transmission, l.headline) from vehicle_listings l where l.vehicle_id = test.id('vehicle:NR1')),
  '5 Automatic 2021 Kia Forte NR');
select test.ok('the copy is left to the writer', (select needs_rewrite from vehicle_listings where vehicle_id = test.id('vehicle:NR1')));
select test.ok('public while its onboarding is open', exists (select 1 from public_vehicle_listings p where p.vehicle_id = test.id('vehicle:NR1')));
select test.eq('still onboarding', (select status::text from vehicles where id = test.id('vehicle:NR1')), 'onboarding');
select test.eq('no gates left', app.vehicle_public_gates(test.id('vehicle:NR1')), '[]'::jsonb);
select test.ok('the defaults are audited', exists (select 1 from audit_log where action = 'listing_defaults' and entity_id = test.id('vehicle:NR1')::text));

-- the gates that stay
insert into vehicles (id, owner_id, year, make, model, vin, plate, class, status, management_mode, onboarding_method)
values (test.id('vehicle:NR3'), test.id('owner:nr_own'), 2020, 'Kia', '', 'NR3KIAFORTE000003', 'NR3AAA', 'standard', 'onboarding', 'managed', 'transfer');
select test.throws('a car without its model is not published', $$select app.publish_listing(test.id('vehicle:NR3'), test.id('nr_admin'))$$, '%details missing: Model%');
update vehicles set model = 'Rio NR', status = 'ready_to_list' where id = test.id('vehicle:NR3');
update vehicles set status = 'out_of_service' where id = test.id('vehicle:NR3');
select test.throws('a car out of service is not published', $$select app.publish_listing(test.id('vehicle:NR3'), test.id('nr_admin'))$$, '%out of service%');

-- ================================================================ 2. the handover waits for the fleet policy
select test.mk_booking('NR-1', 'NR1', 'nr_rita', '2031-03-02 10:00', '2031-03-05 10:00', 'confirmed');
select test.ok('the readiness says the fleet policy is missing',
  (app.booking_readiness(test.id('booking:NR-1')) -> 'missing') ? 'fleet_policy' and not (app.booking_readiness(test.id('booking:NR-1')) ->> 'vehicle_on_policy')::boolean);
select test.throws('the car is not released before it is on the fleet policy',
  $$select app.complete_handover(test.id('booking:NR-1'), test.id('nr_admin'), '{}'::jsonb)$$, '%not on the fleet insurance policy%');
update vehicles set on_fleet_policy = true where id = test.id('vehicle:NR1');
select test.ok('on the policy: nothing about it in the readiness',
  not ((app.booking_readiness(test.id('booking:NR-1')) -> 'missing') ? 'fleet_policy') and (app.booking_readiness(test.id('booking:NR-1')) ->> 'vehicle_on_policy')::boolean);
-- the enrollment of a listed car keeps it live
update vehicles set status = 'ready_to_list' where id = test.id('vehicle:NR1');
select test.eq('enrolled while published: available at once', (select status::text from vehicles where id = test.id('vehicle:NR1')), 'available');
update vehicles set status = 'ready_to_list' where id = test.id('vehicle:NR1');
select test.eq('an available car stays available through its enrollment', (select status::text from vehicles where id = test.id('vehicle:NR1')), 'available');

-- ================================================================ 3. coverage option 2: the paid credit card and the renter's word
select test.mk_booking('NR-2', 'NR2', 'nr_rita', '2031-04-02 10:00', '2031-04-05 10:00', 'pending_payment');
update bookings set coverage_option = 2, card_on_file_id = null, coverage_confirmed_at = null where id = test.id('booking:NR-2');
select test.eq('before payment the renter''s confirmation waits for the card',
  public.renter_coverage_card_confirm(test.id('booking:NR-2'), test.id('nr_rita'), '{"issuer": "Amex"}') ->> 'state', 'awaiting_payment');
select test.ok('the wording is kept with the confirmation',
  (select renter_confirmation_text like 'I confirm that the credit card I pay this booking with includes rental car damage coverage%' from coverage_proofs where booking_id = test.id('booking:NR-2')));
update bookings set card_on_file_id = test.id('card:nr_rita') where id = test.id('booking:NR-2');
select test.eq('paid with a credit card: confirmed by itself, the card recorded',
  (select format('%s %s %s %s', c.status, c.auto_confirmed, c.card_funding, c.card_last4) from coverage_proofs c where c.booking_id = test.id('booking:NR-2')),
  'confirmed t credit 4242');
select test.ok('the booking''s coverage is confirmed', (app.booking_readiness(test.id('booking:NR-2')) ->> 'coverage_confirmed')::boolean);
select test.eq('staff see it: option, paid card, confirmation',
  (select format('%s %s %s', d ->> 'option', d -> 'paid_card' ->> 'credit', (d -> 'proofs' -> 0 ->> 'renter_confirmed_at') is not null) from (select app.coverage_detail(test.id('booking:NR-2')) d) x),
  '2 true t');

-- a debit card never confirms it
update payment_methods set is_credit = false where id = test.id('card:nr_ben');
select test.mk_booking('NR-3', 'NR2', 'nr_ben', '2031-05-02 10:00', '2031-05-05 10:00', 'pending_payment');
update bookings set coverage_option = 2, card_on_file_id = test.id('card:nr_ben'), coverage_confirmed_at = null where id = test.id('booking:NR-3');
select test.eq('a debit card: not confirmed', public.renter_coverage_card_confirm(test.id('booking:NR-3'), test.id('nr_ben'), '{}') ->> 'state', 'not_credit');
select test.ok('the readiness still waits for coverage', not (app.booking_readiness(test.id('booking:NR-3')) ->> 'coverage_confirmed')::boolean);
select test.throws('another renter cannot confirm it', $$select public.renter_coverage_card_confirm(test.id('booking:NR-3'), test.id('nr_rita'), '{}')$$);

-- ================================================================ 4. coverage option 1: the policy in full
select test.mk_booking('NR-4', 'NR2', 'nr_rita', '2031-06-02 10:00', '2031-06-05 10:00', 'confirmed');
update bookings set coverage_option = 1 where id = test.id('booking:NR-4');
select test.throws('OPCF 27 without the policy number and expiry is refused',
  $$select app.register_verification_upload(test.id('booking:NR-4'), test.id('nr_rita'), 'coverage_proof', null, 'renters/x/nr4.pdf', null, 'application/pdf', '{"coverage_option": "1", "insurer_name": "Intact"}', 'documents')$$,
  '%insurer, the policy number and the policy expiry%');
select test.throws('a policy that ends before the return is refused',
  $$select app.register_verification_upload(test.id('booking:NR-4'), test.id('nr_rita'), 'coverage_proof', null, 'renters/x/nr4.pdf', null, 'application/pdf', '{"coverage_option": "1", "insurer_name": "Intact", "policy_number": "P-1", "policy_expiry": "2031-06-03"}', 'documents')$$,
  '%run to the return date%');
select test.ok('the full proof is registered for review',
  app.register_verification_upload(test.id('booking:NR-4'), test.id('nr_rita'), 'coverage_proof', null, 'renters/x/nr4.pdf', null, 'application/pdf',
    '{"coverage_option": "1", "insurer_name": "Intact", "policy_number": "P-1", "policy_expiry": "2031-12-31"}', 'documents') is not null);
select test.ok('it waits for staff', not (app.booking_readiness(test.id('booking:NR-4')) ->> 'coverage_confirmed')::boolean);

-- ================================================================ 5. privileges
select test.ok('the renter functions are for the server only',
  not has_function_privilege('authenticated', 'public.renter_coverage_card_confirm(uuid, uuid, jsonb)', 'execute')
  and not has_function_privilege('anon', 'public.renter_coverage_state(uuid, uuid)', 'execute'));
select test.ok('the new app functions are not open', not has_function_privilege('authenticated', 'app.vehicle_listing_warnings(uuid)', 'execute')
  and not has_function_privilege('authenticated', 'app.coverage_card_try_confirm(uuid)', 'execute'));
select test.ok('the wrappers keep the privileges of what they wrap',
  has_function_privilege('service_role', 'app.door(uuid, text, text, text, jsonb)', 'execute')
  and has_function_privilege('authenticated', 'app.door(uuid, text, text, text, jsonb)', 'execute') = has_function_privilege('authenticated', 'app.door_pre0070(uuid, text, text, text, jsonb)', 'execute'));
