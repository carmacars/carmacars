-- 99: release 35 part B (1400 to 1403): the renter picks their card and the database checks it against the car; OPCF 27
-- needs the pink slip and the endorsement page before payment and before approval; the fuel shortfall line from the tank,
-- the pump price and the multiplier (never a card charge); delivery priced by distance with the included km and the per-car
-- override. Fixtures start with "rb".
select test.suite('99 r35b card pick, OPCF 27 pages, fuel shortfall, delivery distance');
select set_config('app.paper_fixture', 'on', false);

select test.mk_user('rb_admin', 'admin');
select test.mk_user('rb_cs', 'va', 'cs');
select test.mk_user('rb_fleet', 'va', 'fleet');
select test.mk_user('rb_fin', 'va', 'finance');
select test.mk_user('rb_sales', 'va', 'sales');
select test.mk_owner('rb_olga');
select test.mk_vehicle('rb_car', 'rb_olga');
select test.mk_vehicle('rb_ev', 'rb_olga');
select test.mk_renter('rb_rita');
select test.mk_renter('rb_ron');
update vehicles set fuel = 'electric' where id = test.id('vehicle:rb_ev');

create function test.rbcard(p_issuer text, p_card text) returns uuid language sql stable security definer as $$
  select id from public.card_rental_coverage where country = 'CA' and issuer = p_issuer and card = p_card $$;
create function test.rbb(p text) returns bookings language sql stable security definer as $$ select * from public.bookings where id = test.id('booking:' || p) $$;

-- ================================================================ 1. the card list's facts
select test.eq('Scene+ Visa includes no rental car damage coverage', (select cdw_included || '/' || network from card_rental_coverage where id = test.rbcard('Scotiabank', 'Scene+ Visa')), 'no/visa');
select test.eq('the Cobalt card is American Express, decline the CDW, pay in full', (select network || '/' || must_decline_cdw || '/' || must_pay_full from card_rental_coverage where id = test.rbcard('American Express', 'Cobalt Card')), 'amex/yes/yes');
select test.ok('TD First Class leaves out exotic cars and trucks', (select excluded_types @> array['exotic', 'truck'] from card_rental_coverage where id = test.rbcard('TD', 'First Class Travel Visa Infinite')));
select test.eq('HSBC cards are unknown', (select cdw_included from card_rental_coverage where id = test.rbcard('HSBC', 'HSBC Canada cards')), 'unknown');
select test.ok('every Canadian card has a source', not exists (select 1 from card_rental_coverage where country = 'CA' and guide_url is null and source_url is null));
select test.throws('an excluded type outside the list is refused by the table', $$update card_rental_coverage set excluded_types = array['boats'] where card = 'Cobalt Card'$$, 'excluded_types_known');

-- ================================================================ 2. the car's value and types
select test.eq('no value on file', app.vehicle_value(test.id('vehicle:rb_car')) ->> 'source', null::text);
update vehicles set estimated_value_cents = 6000000 where id = test.id('vehicle:rb_car');
select test.eq('the estimate when nothing else', app.vehicle_value(test.id('vehicle:rb_car')) ->> 'source' || ':' || (app.vehicle_value(test.id('vehicle:rb_car')) ->> 'cents'), 'estimate:6000000');
insert into vehicle_buyouts (vehicle_id, offered_on, black_book_value_cents) values (test.id('vehicle:rb_car'), date '2026-10-01', 5500000);
select test.eq('a buyout''s Black Book value comes before the estimate', (app.vehicle_value(test.id('vehicle:rb_car')) ->> 'cents')::bigint, 5500000::bigint);
update vehicles set black_book_value_cents = 5000000 where id = test.id('vehicle:rb_car');
select test.eq('the Black Book on the car comes first', (app.vehicle_value(test.id('vehicle:rb_car')) ->> 'cents')::bigint, 5000000::bigint);
select test.eq('a premium Mercedes is none of the excluded types', app.vehicle_coverage_types(test.id('vehicle:rb_car')), '{}'::text[]);
update vehicles set make = 'Ferrari' where id = test.id('vehicle:rb_ev');
select test.eq('a Ferrari is exotic by its make', app.vehicle_coverage_types(test.id('vehicle:rb_ev')), array['exotic']);
update vehicles set make = 'Mercedes-Benz', class = 'luxury' where id = test.id('vehicle:rb_ev');
select test.eq('a luxury car is luxury', app.vehicle_coverage_types(test.id('vehicle:rb_ev')), array['luxury']);
update vehicles set class = 'premium' where id = test.id('vehicle:rb_ev');

-- ================================================================ 3. the check
select test.mk_booking('RB-CARD', 'rb_car', 'rb_rita', '2026-12-01 10:00', '2026-12-04 10:00', 'pending_payment');
update bookings set coverage_option = 2 where id = test.id('booking:RB-CARD');
select test.eq('Avion Visa Infinite covers a $50,000 car for 3 days', app.card_product_check(test.id('booking:RB-CARD'), test.rbcard('RBC', 'Avion Visa Infinite')) ->> 'result', 'covered');
select test.eq('Scene+ Visa does not', app.card_product_check(test.id('booking:RB-CARD'), test.rbcard('Scotiabank', 'Scene+ Visa')) #>> '{reasons,0,code}', 'no_cdw');
select test.eq('an American Express card when a Visa paid', app.card_product_check(test.id('booking:RB-CARD'), test.rbcard('American Express', 'Cobalt Card')) #>> '{reasons,0,code}', 'network_mismatch');
select test.eq('an unknown card goes to staff', (select x ->> 'result' || '/' || (x #>> '{reasons,0,code}') from (select app.card_product_check(test.id('booking:RB-CARD'), null) x) q), 'review/unknown_card');
select test.eq('a card whose coverage is not known goes to staff', app.card_product_check(test.id('booking:RB-CARD'), test.rbcard('HSBC', 'HSBC Canada cards')) ->> 'result', 'review');
update vehicles set black_book_value_cents = 9000000 where id = test.id('vehicle:rb_car');
select test.eq('a $90,000 car is over the $65,000 limit', app.card_product_check(test.id('booking:RB-CARD'), test.rbcard('RBC', 'Avion Visa Infinite')) #>> '{reasons,0,code}', 'over_value');
select test.ok('the message names the limit and the other options', (app.card_product_check(test.id('booking:RB-CARD'), test.rbcard('RBC', 'Avion Visa Infinite')) ->> 'message') ~ '\$65,000.*OPCF 27.*Protection Plan');
update vehicles set black_book_value_cents = 5000000, class = 'exotic' where id = test.id('vehicle:rb_car');
select test.eq('an exotic car is left out by TD First Class', app.card_product_check(test.id('booking:RB-CARD'), test.rbcard('TD', 'First Class Travel Visa Infinite')) #>> '{reasons,0,code}', 'excluded_type');
update vehicles set class = 'premium' where id = test.id('vehicle:rb_car');
update bookings set return_at = pickup_at + interval '50 days', original_return_at = pickup_at + interval '50 days', billable_days = public.calc_billable_days(pickup_at, pickup_at + interval '50 days'), km_allowance_total = km_allowance_per_day * public.calc_billable_days(pickup_at, pickup_at + interval '50 days') where id = test.id('booking:RB-CARD');
select test.eq('50 days is over the 48 days', app.card_product_check(test.id('booking:RB-CARD'), test.rbcard('RBC', 'Avion Visa Infinite')) #>> '{reasons,0,code}', 'too_long');
update bookings set return_at = pickup_at + interval '3 days', original_return_at = pickup_at + interval '3 days', billable_days = public.calc_billable_days(pickup_at, pickup_at + interval '3 days'), km_allowance_total = km_allowance_per_day * public.calc_billable_days(pickup_at, pickup_at + interval '3 days') where id = test.id('booking:RB-CARD');
update vehicles set black_book_value_cents = null, estimated_value_cents = null where id = test.id('vehicle:rb_car');
delete from vehicle_buyouts where vehicle_id = test.id('vehicle:rb_car');
select test.eq('a car with no value on file goes to staff', app.card_product_check(test.id('booking:RB-CARD'), test.rbcard('RBC', 'Avion Visa Infinite')) #>> '{reasons,0,code}', 'value_unknown');
update vehicles set black_book_value_cents = 5000000 where id = test.id('vehicle:rb_car');

-- ================================================================ 4. the renter's pick, server-side
select test.throws('a card is required', format($$select public.renter_submit_card_coverage(%L, %L, true, null, null, null)$$, test.id('booking:RB-CARD'), test.id('rb_rita')), 'Choose your card');
select test.throws('a card that does not cover the car is refused with the other options',
  format($$select public.renter_submit_card_coverage(%L, %L, true, null, %L, null)$$, test.id('booking:RB-CARD'), test.id('rb_rita'), test.rbcard('Scotiabank', 'Scene+ Visa')), 'Protection Plan');
select test.throws('another renter cannot pick for this booking',
  format($$select public.renter_submit_card_coverage(%L, %L, true, null, %L, null)$$, test.id('booking:RB-CARD'), test.id('rb_ron'), test.rbcard('RBC', 'Avion Visa Infinite')));
select test.eq('the preview tells the renter before they confirm', public.server_card_coverage_preview(test.id('booking:RB-CARD'), test.id('rb_rita'), test.rbcard('RBC', 'Avion Visa Infinite')) ->> 'result', 'covered');
select test.lives('a covering card is accepted', format($$select public.renter_submit_card_coverage(%L, %L, true, null, %L, null)$$, test.id('booking:RB-CARD'), test.id('rb_rita'), test.rbcard('RBC', 'Avion Visa Infinite')));
select test.eq('the proof keeps the card and the check', (select (card_coverage_id = test.rbcard('RBC', 'Avion Visa Infinite'))::text || '/' || (card_check ->> 'result') from coverage_proofs where booking_id = test.id('booking:RB-CARD') and status = 'submitted'), 'true/covered');
select test.eq('the renter''s read shows the pick', app.renter_coverage(test.id('booking:RB-CARD')) #>> '{card_pick,label}', 'RBC Avion Visa Infinite');
select test.eq('the staff read shows it too', app.coverage_review_facts(test.id('booking:RB-CARD')) #>> '{card_pick,check,result}', 'covered');
-- the car's value rose after the pick: staff cannot approve
update vehicles set black_book_value_cents = 9000000 where id = test.id('vehicle:rb_car');
select test.throws('staff cannot approve a card that no longer covers the car',
  format($$select app.review_coverage_proof(%L, %L, true)$$, (select id from coverage_proofs where booking_id = test.id('booking:RB-CARD') and status = 'submitted'), test.id('rb_cs')), 'does not cover');
update vehicles set black_book_value_cents = 5000000 where id = test.id('vehicle:rb_car');
-- an unknown card typed by the renter goes to review
select test.mk_booking('RB-CARD2', 'rb_car', 'rb_ron', '2026-12-10 10:00', '2026-12-12 10:00', 'pending_payment');
update bookings set coverage_option = 2 where id = test.id('booking:RB-CARD2');
select test.lives('a card not on the list is accepted for review', format($$select public.renter_submit_card_coverage(%L, %L, true, null, null, 'Example Credit Union Visa')$$, test.id('booking:RB-CARD2'), test.id('rb_ron')));
select test.eq('it waits for staff with the typed name', (select card_other || '/' || (card_check ->> 'result') from coverage_proofs where booking_id = test.id('booking:RB-CARD2')), 'Example Credit Union Visa/review');

-- ================================================================ 5. Admin edits the list; who sets a car's value
select test.lives('an Admin sets the excluded types as words', format($$select app.card_coverage_save(%L, jsonb_build_object('key', %L, 'values', jsonb_build_object('excluded_types', 'van, off-road', 'cdw_included', 'yes')))$$,
  test.id('rb_admin'), test.rbcard('HSBC', 'HSBC Canada cards')));
select test.eq('saved as the list', (select excluded_types::text || '/' || cdw_included from card_rental_coverage where id = test.rbcard('HSBC', 'HSBC Canada cards')), '{off_road,van}/yes');
select test.throws('an unknown type is refused', format($$select app.card_coverage_save(%L, jsonb_build_object('key', %L, 'values', jsonb_build_object('excluded_types', 'boats')))$$, test.id('rb_admin'), test.rbcard('HSBC', 'HSBC Canada cards')), 'Excluded types');
select test.throws('customer service does not edit the list', format($$select app.card_coverage_save(%L, jsonb_build_object('key', %L, 'values', jsonb_build_object('cdw_included', 'no')))$$, test.id('rb_cs'), test.rbcard('HSBC', 'HSBC Canada cards')));
select test.lives('fleet sets the car''s value and tank', format($$select app.door(%L, 'aal2', 'ops_do', 'vehicle_value_set', jsonb_build_object('vehicle_id', %L, 'estimated_value_cents', 7000000, 'fuel_tank_litres', 50, 'fuel_grade', 'premium'))$$, test.id('rb_fleet'), test.id('vehicle:rb_car')));
select test.eq('saved', (select estimated_value_cents || '/' || fuel_tank_litres || '/' || fuel_grade from vehicles where id = test.id('vehicle:rb_car')), '7000000/50.0/premium');
select test.throws('customer service reads but does not set it', format($$select app.vehicle_value_set(%L, jsonb_build_object('vehicle_id', %L, 'fuel_tank_litres', 60))$$, test.id('rb_cs'), test.id('vehicle:rb_car')), 'Only an Admin or fleet');
select test.throws('sales does not set it', format($$select app.vehicle_value_set(%L, jsonb_build_object('vehicle_id', %L, 'fuel_tank_litres', 60))$$, test.id('rb_sales'), test.id('vehicle:rb_car')), 'Only an Admin or fleet');
select test.throws('a renter does not read it', format($$select app.vehicle_value_fuel(%L, jsonb_build_object('vehicle_id', %L))$$, test.id('rb_rita'), test.id('vehicle:rb_car')), 'Not permitted');
select test.throws('a bad grade is refused', format($$select app.vehicle_value_set(%L, jsonb_build_object('vehicle_id', %L, 'fuel_grade', 'jet'))$$, test.id('rb_admin'), test.id('vehicle:rb_car')), 'regular, premium or diesel');

-- ================================================================ 6. OPCF 27: the pink slip and the endorsement before payment and approval
select test.mk_booking('RB-OPCF', 'rb_car', 'rb_ron', '2026-12-20 10:00', '2026-12-23 10:00', 'pending_payment');
update bookings set coverage_option = 1 where id = test.id('booking:RB-OPCF');
create function test.rb_opcf(p_page text) returns uuid language sql as $$
  select app.register_verification_upload(test.id('booking:RB-OPCF'), test.id('rb_ron'), 'coverage_proof', null, 'renters/rb/opcf-' || gen_random_uuid() || '.pdf', repeat('a', 64), 'application/pdf',
    jsonb_build_object('coverage_option', '1', 'insurer_name', 'Example Mutual', 'policy_number', 'EX-0001', 'policy_expiry', '2027-06-30', 'page_kind', p_page), 'documents') $$;
select test.eq('both pages are missing before payment', public.server_booking_payment_facts(test.id('booking:RB-OPCF')) -> 'coverage_missing', '["pink slip", "OPCF 27 endorsement"]'::jsonb);
select test.throws('a page must say what it is', $$select test.rb_opcf(null)$$, 'pink slip or the OPCF 27 endorsement');
select test.lives('the pink slip', $$select test.rb_opcf('pink_slip')$$);
select test.eq('the endorsement is still missing', app.opcf27_missing(test.id('booking:RB-OPCF')), array['OPCF 27 endorsement']);
select test.eq('the renter''s read says so', app.renter_coverage(test.id('booking:RB-OPCF')) -> 'opcf27_missing', '["OPCF 27 endorsement"]'::jsonb);
select test.throws('staff cannot approve with one page', format($$select app.review_coverage_proof(%L, %L, true)$$, (select id from coverage_proofs where booking_id = test.id('booking:RB-OPCF')), test.id('rb_cs')), 'Both pages');
select test.lives('the endorsement page', $$select test.rb_opcf('endorsement')$$);
select test.eq('nothing is missing: payment may go ahead', public.server_booking_payment_facts(test.id('booking:RB-OPCF')) -> 'coverage_missing', '[]'::jsonb);
select test.throws('fleet does not review it', format($$select app.review_coverage_proof(%L, %L, false, 'x')$$, (select id from coverage_proofs where booking_id = test.id('booking:RB-OPCF')), test.id('rb_fleet')), 'Only customer service');
select test.throws('a rejection needs the reason', format($$select app.review_coverage_proof(%L, %L, false)$$, (select id from coverage_proofs where booking_id = test.id('booking:RB-OPCF')), test.id('rb_cs')), 'reason');
select test.lives('customer service approves it', format($$select app.review_coverage_proof(%L, %L, true)$$, (select id from coverage_proofs where booking_id = test.id('booking:RB-OPCF')), test.id('rb_cs')));
select test.eq('the proof is confirmed', (select status from coverage_proofs where booking_id = test.id('booking:RB-OPCF')), 'confirmed');
select test.mk_booking('RB-OPCF2', 'rb_car', 'rb_ron', '2027-01-05 10:00', '2027-01-08 10:00', 'pending_payment');
update bookings set coverage_option = 1 where id = test.id('booking:RB-OPCF2');
create temp table rb_prog as select id, opcf27_before_payment from program_settings where id = (app.settings()).id;
update program_settings set opcf27_before_payment = false where id = (app.settings()).id;
select test.eq('with the setting off nothing blocks the payment', public.server_booking_payment_facts(test.id('booking:RB-OPCF2')) -> 'coverage_missing', '[]'::jsonb);
update program_settings p set opcf27_before_payment = r.opcf27_before_payment from rb_prog r where p.id = r.id;
select test.eq('on again: it does', jsonb_array_length(public.server_booking_payment_facts(test.id('booking:RB-OPCF2')) -> 'coverage_missing'), 2);

-- ================================================================ 7. the fuel shortfall
select test.mk_booking('RB-FUEL', 'rb_car', 'rb_rita', '2026-11-01 10:00', '2026-11-04 10:00', 'returned');
update bookings set fuel_out_pct = 100, fuel_in_pct = 50 where id = test.id('booking:RB-FUEL');
-- the car: a 50 L tank of premium (set above); premium at $1.85, times 1.25, plus the $20 fee
select test.eq('50 L x 50% x $1.85 x 1.25 = $57.81, plus $20', (select (x ->> 'energy_cents') || '+' || (x ->> 'fee_cents') || '=' || (x ->> 'total_cents') from (select app.fuel_shortfall(test.id('booking:RB-FUEL')) x) q), '5781+2000=7781');
update vehicles set fuel_tank_litres = null, fuel_grade = null, class = 'standard' where id = test.id('vehicle:rb_car');
select test.eq('no tank on the car: the 65 L default, regular at $1.55', (select (x ->> 'size_source') || '/' || (x ->> 'grade') || '/' || (x ->> 'energy_cents') from (select app.fuel_shortfall(test.id('booking:RB-FUEL')) x) q), 'default/regular/6297');
update vehicles set fuel_tank_litres = 50, fuel_grade = 'premium', class = 'premium' where id = test.id('vehicle:rb_car');
create temp table rb_pay as select count(*) as n from payments where booking_id = test.id('booking:RB-FUEL');
select test.lives('Finance assesses the return', format($$select app.assess_check_in(%L, '{}'::jsonb, %L)$$, test.id('booking:RB-FUEL'), test.id('rb_fin')));
select test.eq('the fuel line is the formula', (select amount_cents from booking_line_items where booking_id = test.id('booking:RB-FUEL') and assessment_key = 'fuel' and voided_at is null), 5781::bigint);
select test.eq('the refuelling fee is the setting', (select amount_cents from booking_line_items where booking_id = test.id('booking:RB-FUEL') and assessment_key = 'fuel_service_fee' and voided_at is null), 2000::bigint);
select test.eq('nothing was charged to a card', (select count(*) from payments where booking_id = test.id('booking:RB-FUEL')), (select n from rb_pay));
select test.lives('a pump receipt still wins', format($$select app.assess_check_in(%L, '{"pump_cost_cents": 4000}'::jsonb, %L)$$, test.id('booking:RB-FUEL'), test.id('rb_fin')));
select test.ok('the receipt prices the fuel line', (select amount_cents >= 4000 and amount_cents <> 5781 from booking_line_items where booking_id = test.id('booking:RB-FUEL') and assessment_key = 'fuel' and voided_at is null));
select test.lives('no fuel charge', format($$select app.assess_check_in(%L, '{"no_fuel_charge": true}'::jsonb, %L)$$, test.id('booking:RB-FUEL'), test.id('rb_fin')));
select test.eq('no fuel and no fee', (select coalesce(sum(amount_cents), 0) from booking_line_items where booking_id = test.id('booking:RB-FUEL') and assessment_key in ('fuel', 'fuel_service_fee') and voided_at is null), 0::bigint);
select test.throws('fleet does not price the return', format($$select app.assess_check_in(%L, '{}'::jsonb, %L)$$, test.id('booking:RB-FUEL'), test.id('rb_fleet')), 'Finance or an Admin');
-- an electric car: 80 kWh x 50% x $0.40 = $16.00, plus $20
select test.mk_booking('RB-EV', 'rb_ev', 'rb_rita', '2026-11-05 10:00', '2026-11-07 10:00', 'returned');
update vehicles set battery_kwh = 80 where id = test.id('vehicle:rb_ev');
update bookings set fuel_out_pct = 90, fuel_in_pct = 40 where id = test.id('booking:RB-EV');
select test.eq('80 kWh x 50% x $0.40 = $16.00, plus $20', (select (x ->> 'kind') || ':' || (x ->> 'energy_cents') || '+' || (x ->> 'fee_cents') from (select app.fuel_shortfall(test.id('booking:RB-EV')) x) q), 'charge:1600+2000');
select test.lives('the EV return is assessed', format($$select app.assess_check_in(%L, '{}'::jsonb, %L)$$, test.id('booking:RB-EV'), test.id('rb_fin')));
select test.eq('the recharging line is the kWh formula', (select amount_cents from booking_line_items where booking_id = test.id('booking:RB-EV') and assessment_key = 'recharging' and voided_at is null), 1600::bigint);
select test.eq('the deposit review''s fuel item suggests it', (app.drr_facts(test.id('booking:RB-EV')) #>> '{fuel,suggested_cents}')::bigint, 3600::bigint);
-- a price change is dated
update program_settings set fuel_prices_updated_on = date '2026-01-01' where id = (app.settings()).id;
select test.ok('a week-old price is on Admin > Today', exists (select 1 from jsonb_array_elements(app.site_setup_problems()) x where x ->> 'field' = 'fuel_prices'));
update program_settings set fuel_price_regular_cents = 149.9 where id = (app.settings()).id;
select test.eq('the new price is dated today', (app.settings()).fuel_prices_updated_on, app.today());
update program_settings set fuel_price_regular_cents = 155 where id = (app.settings()).id;

-- ================================================================ 8. delivery by distance
select test.eq('40 km: $75 with 15 km, then 25 km at $2 = $125', (app.delivery_fee(test.id('vehicle:rb_car'), 'pickup', '{"kind": "delivery", "distance_km": 40}') ->> 'fee_cents')::bigint, 12500::bigint);
select test.eq('10 km: the base alone', (app.delivery_fee(test.id('vehicle:rb_car'), 'return', '{"kind": "delivery", "distance_km": 10}') ->> 'fee_cents')::bigint, 7500::bigint);
select test.eq('no road distance: the straight line x 1.3', app.delivery_fee(test.id('vehicle:rb_car'), 'pickup', '{"kind": "delivery", "lat": 43.80, "lng": -79.30}') ->> 'distance_how', 'straight_line');
select test.ok('the straight line is lengthened by the road factor', (app.delivery_fee(test.id('vehicle:rb_car'), 'pickup', '{"kind": "delivery", "lat": 43.80, "lng": -79.30}') ->> 'distance_km')::numeric
  between app.distance_km((app.settings()).company_latitude, (app.settings()).company_longitude, 43.80, -79.30) * 1.29 and app.distance_km((app.settings()).company_latitude, (app.settings()).company_longitude, 43.80, -79.30) * 1.31);
select test.eq('the quote says what is included', (app.delivery_fee(test.id('vehicle:rb_car'), 'pickup', '{"kind": "delivery", "distance_km": 40}') ->> 'included_km')::numeric, 15.0);
update rate_cards set delivery_fee_cents = 9000, pickup_fee_cents = 9000 where vehicle_id = test.id('vehicle:rb_ev');
select test.ok('a car with its own fee is an override', (select delivery_fee_custom from rate_cards where vehicle_id = test.id('vehicle:rb_ev') and effective_to is null));
select test.eq('its own base is used', (app.delivery_fee(test.id('vehicle:rb_ev'), 'pickup', '{"kind": "delivery", "distance_km": 10}') ->> 'fee_cents')::bigint, 9000::bigint);
create temp table rb_base as select id, delivery_base_cents from program_settings where id = (app.settings()).id;
update program_settings set delivery_base_cents = 8000 where id = (app.settings()).id;
select test.eq('a new base moves the cars that follow it', (select delivery_fee_cents || '/' || pickup_fee_cents from rate_cards where vehicle_id = test.id('vehicle:rb_car') and effective_to is null), '8000/8000');
select test.eq('and leaves the override', (select delivery_fee_cents from rate_cards where vehicle_id = test.id('vehicle:rb_ev') and effective_to is null), 9000::bigint);
update program_settings p set delivery_base_cents = r.delivery_base_cents from rb_base r where p.id = r.id;
select test.eq('back to $75', (select delivery_fee_cents from rate_cards where vehicle_id = test.id('vehicle:rb_car') and effective_to is null), 7500::bigint);
