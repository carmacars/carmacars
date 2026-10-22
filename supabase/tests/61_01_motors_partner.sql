-- 61: a partner's whole fleet and the chauffeur service (migration 0093). The import (the partner, 62 cars, 11
-- chauffeur vehicles, published, keyed so a second run adds nothing), the renter's rates from the sheet rates (10%
-- markup, nearest dollar) with the 3+ day tier in the quote, the 12 cars with insurance included and no credit card
-- needed (coverage option 4 confirmed by itself, a debit card accepted at payment, the deposit and the ages kept), the
-- approximate year left out of the name and the public row, the split on the partner's rates (the sheet amount, the
-- 20% cut, the payout, the markup CarmaCars keeps) on a sample booking and its statement line, Admin's per-car and
-- per-partner pricing, and a chauffeur request with its quote. Fixtures start "pm".
select test.suite('61 01 Motors partner');

select test.mk_user('pm_admin', 'admin');
select test.mk_user('pm_cs', 'va', 'cs');
select test.mk_user('pm_fleet', 'va', 'fleet');
select test.mk_renter('pm_rita');

create function test.pm_car(p_sheet text) returns uuid language sql stable as $$
  select v.id from vehicles v join partners p on p.id = v.partner_id where p.business_name = '01 Motors' and v.partner_sheet_name = p_sheet $$;
create function test.pm_rc(p_sheet text) returns rate_cards language sql stable as $$
  select * from rate_cards r where r.vehicle_id = test.pm_car(p_sheet) and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now()) $$;
create function test.pm_at(p_days integer, p_len integer) returns timestamptz language sql stable as $$
  select (app.today() + p_days)::timestamp at time zone 'America/Toronto' + interval '10 hours' $$;

-- ================================================================ 1. the import
select test.eq('partner: 01 Motors, on the partner-rate basis, 20% commission, 10% markup, no portal sign-in',
  (select format('%s %s %s %s %s', p.payout_basis, p.commission_bps, p.markup_bps, o.kind, o.user_id is null) from partners p join owners o on o.id = p.owner_id where p.business_name = '01 Motors'),
  'partner_rate 2000 1000 partner t');
select test.eq('cars: 62, each a partner car with its sheet rates, a fleet number and a car code, no VIN or plate invented',
  (select format('%s %s %s %s %s %s', count(*), count(r.vehicle_id), count(distinct v.fleet_number), count(v.car_code), count(v.vin), count(v.plate))
     from vehicles v left join partner_rates r on r.vehicle_id = v.id where v.partner_id = (select id from partners where business_name = '01 Motors')),
  '62 62 62 62 0 0');
select test.eq('cars: all published as requests (bookable)',
  (select format('%s %s', count(*) filter (where l.status = 'published'), count(*) filter (where app.vehicle_bookable(v.id)))
     from vehicles v join vehicle_listings l on l.vehicle_id = v.id where v.partner_id = (select id from partners where business_name = '01 Motors')), '62 62');
select test.eq('cars: the 12 with insurance included and no credit card needed',
  (select string_agg(partner_sheet_name, ', ' order by partner_sheet_name) from vehicles where insurance_included and no_credit_card
     and partner_id = (select id from partners where business_name = '01 Motors')),
  'BMW M4 Comp Black, BMW M440i Gran Coupe, Bentley Bentayga, Cadillac Escalade ESV, Ferrari California T, Lamborghini Urus, Mclaren 570s, Mercedes G63 AMG, Mercedes GLS600 Maybach, Mercedes S580, Mercedes S63 AMG, Range Rover Autobiography');
select test.eq('a car from its row name: make, model, trim and colour in proper case', (select format('%s|%s|%s|%s', make, model, trim, colour) from vehicles where id = test.pm_car('Mercedes C43 AMG Blue')),
  'Mercedes-Benz|C-Class|C43 AMG|Blue');
select test.eq('ESV stays in capitals', (select trim from vehicles where id = test.pm_car('Cadillac Escalade ESV')), 'ESV');
select test.eq('a second run adds nothing (keyed by the partner and the row name)',
  app.partner_fleet_import_0093('{"partner": {"business_name": "01 Motors"}, "cars": [{"sheet": "Mercedes A220"}], "chauffeur": [{"sheet": "Sprinter Van Blue", "name": "Sprinter again", "slug": "sprinter-again", "kind": "chauffeur_only", "passengers": 1, "rentals": [], "two_hour": 1, "three_plus": 1, "sort": 1}]}') - 'partner_id',
  '{"cars_kept": 1, "cars_added": 0, "chauffeur_added": 0}'::jsonb);
select test.eq('chauffeur vehicles: 11, the "/ rental" ones linked to their rental cars',
  (select format('%s %s %s', count(*), count(*) filter (where kind = 'chauffeur_rental'), sum(cardinality(rental_vehicle_ids))) from chauffeur_vehicles), '11 6 9');
select test.eq('drivers 18 to 20 follow Program settings like every car (0087)',
  (select count(*) from vehicles where not allows_18_to_20 and partner_id = (select id from partners where business_name = '01 Motors')), 0::bigint);

-- ================================================================ 2. the renter's rates and the 3+ day tier
select test.eq('rate card: 1-2 days, 3+ days, 7+ days (a week, 30 days) at the sheet rate plus 10%, to the dollar',
  (select format('%s %s %s %s %s', (rc).daily_rate_cents, (rc).weekend_rate_cents, (rc).multi_day_rate_cents, (rc).weekly_rate_cents, (rc).monthly_rate_cents)
     from (select test.pm_rc('Mercedes C43 AMG Blue') rc) x), '27500 27500 24800 154000 660000');
select test.eq('rounding: $175 becomes $193 (half a dollar up)', app.partner_renter_cents(17500, 1000), 19300::bigint);
select test.eq('the engine: 3 to 6 days at the multi-day rate, capped at the week',
  (select string_agg(format('%s:%s:%s', d, r.rate_applied, r.rental_charge_cents), ' ' order by d)
     from generate_series(1, 8) d, public.calc_rental_charge(test.pm_at(10, 0), d, 27500, 27500, 154000, 660000, 'America/Toronto', 24800) r),
  '1:daily:27500 2:daily:55000 3:multi_day:74400 4:multi_day:99200 5:multi_day:124000 6:multi_day:148800 7:weekly:154000 8:weekly:176000');
select test.eq('the engine: no multi-day rate, 0003''s rules', (select rental_charge_cents from public.calc_rental_charge(test.pm_at(10, 0), 3, 10000, 10000, 56000, 180000, 'America/Toronto', null)), 30000::bigint);
select test.eq('the quote (car page and request) uses the 3+ day tier',
  (select format('%s %s', q ->> 'rental_charge_cents', q -> 'lines' -> 0 -> 'detail' ->> 'rate_rule')
     from (select app.quote_booking(test.pm_car('Mercedes C43 AMG Blue'), test.pm_at(20, 0), test.pm_at(23, 0)) q) x),
  '74400 3 days at the 3+ day rate');
select test.eq('the quote: 7 days at the 7+ day rate', (app.quote_booking(test.pm_car('Mercedes C43 AMG Blue'), test.pm_at(20, 0), test.pm_at(27, 0)) ->> 'rental_charge_cents'), '154000');
select test.eq('the public row: the tiers, the flags, the year left out',
  (select format('%s %s %s %s %s %s', r ->> 'multi_day_rate_cents', r ->> 'long_term_rate_cents', r ->> 'insurance_included', r ->> 'no_credit_card', coalesce(r ->> 'year', 'none'), r ->> 'guideline_rates')
     from (select app.public_listing_row(test.pm_car('Mercedes S580')) r) x), '63300 60500 true true none true');
select test.eq('approximate year: not in the name or the web address', (select app.vehicle_name(v.id) || ' /cars/' || l.slug from vehicles v join vehicle_listings l on l.vehicle_id = v.id where v.id = test.pm_car('Mercedes S580')),
  'Mercedes-Benz S-Class S580 /cars/mercedes-benz-s-class-s580');

-- ================================================================ 3. Admin: a car's sheet rates and flags, the partner's pricing
select test.throws('pricing: only an Admin', format('select app.partner_car_save(%L, %L)', test.id('pm_fleet'), jsonb_build_object('vehicle_id', test.pm_car('Audi S5'), 'base_cents', 24000)), 'Admin');
select test.throws('pricing: the rate a day goes down with the length', format('select app.partner_car_save(%L, %L)', test.id('pm_admin'),
  jsonb_build_object('vehicle_id', test.pm_car('Audi S5'), 'base_cents', 20000, 'multi_day_cents', 25000, 'long_term_cents', 20000)), 'goes down');
select app.partner_car_save(test.id('pm_admin'), jsonb_build_object('vehicle_id', test.pm_car('Audi S5'), 'base_cents', 24000, 'markup_bps', 1500, 'year', 2023));
select test.eq('a negotiated rate and the car''s own markup: the renter''s rates follow; the year confirmed',
  (select format('%s %s %s %s', (test.pm_rc('Audi S5')).daily_rate_cents, (test.pm_rc('Audi S5')).multi_day_rate_cents, v.year, v.year_approximate) from vehicles v where v.id = test.pm_car('Audi S5')),
  '27600 23000 2023 f');
select app.partner_pricing_save(test.id('pm_admin'), jsonb_build_object('id', (select id from partners where business_name = '01 Motors'), 'markup_bps', 1200));
select test.eq('the partner''s markup: every car without its own follows', ((test.pm_rc('Mercedes A220')).daily_rate_cents), 15700::bigint);
select app.partner_pricing_save(test.id('pm_admin'), jsonb_build_object('id', (select id from partners where business_name = '01 Motors'), 'markup_bps', null));
select test.eq('back to Program settings (10%)', ((test.pm_rc('Mercedes A220')).daily_rate_cents), 15400::bigint);
select test.eq('the partner page lists each car with its sheet and renter rates',
  (select format('%s %s %s', c ->> 'base_cents', c ->> 'renter_daily_cents', c ->> 'commission_effective_bps')
     from jsonb_array_elements(app.partner_detail(test.id('pm_admin'), (select id from partners where business_name = '01 Motors')) -> 'cars') c
    where c ->> 'sheet_name' = 'Mercedes A220'), '14000 15400 2000');

-- ================================================================ 4. a request on a car with insurance included: option 4, confirmed
create temp table s61 (k text primary key, v jsonb);
insert into s61 select 'req', app.submit_booking_request(jsonb_build_object(
  'request_key', 'pm-key-1', 'vehicle_id', test.pm_car('Mercedes S580'), 'pickup_at', test.pm_at(15, 0), 'return_at', test.pm_at(18, 0),
  'booking_type', 'standard', 'coverage_option', null,
  'consents', jsonb_build_object('terms', jsonb_build_object('accepted', true, 'version', 'terms-2026-10', 'text', 'I am 18 or older and agree to the Terms of Use.'),
                                 'privacy', jsonb_build_object('accepted', true, 'version', 'privacy-2026-10', 'text', 'I agree to the Privacy Policy.')),
  'renter', jsonb_build_object('full_name', 'Pat Morgan', 'date_of_birth', '1985-03-03', 'email', 'pm.pat@example.test', 'mobile', '416-555-0161',
                               'licence_class', 'G', 'licence_issuer', 'ON')));
select test.eq('request: accepted with no coverage option sent', (select v ->> 'ok' from s61 where k = 'req'), 'true');
select test.eq('request: coverage option 4, confirmed at once with its proof; the deposit kept',
  (select format('%s %s %s %s %s', b.coverage_option, b.coverage_confirmed_at is not null, c.status, c.coverage_option, b.deposit_cents > 0)
     from bookings b join coverage_proofs c on c.booking_id = b.id where b.id = (select (v ->> 'booking_id')::uuid from s61 where k = 'req')),
  '4 t confirmed 4 t');
select test.eq('request: the 3+ day rate snapshot and the partner basis on the booking',
  (select format('%s %s %s %s', b.multi_day_rate_cents, b.partner_sheet_rental_cents, b.partner_cut_bps, b.rental_charge_cents)
     from bookings b where b.id = (select (v ->> 'booking_id')::uuid from s61 where k = 'req')), '63300 172500 2000 189900');
select test.eq('readiness: coverage confirmed', (app.booking_readiness((select (v ->> 'booking_id')::uuid from s61 where k = 'req')) ->> 'coverage_confirmed'), 'true');
select test.throws('option 4 is never changed by the renter', format('select app.set_coverage_option(%L, %L, 1)',
  (select (v ->> 'booking_id')::uuid from s61 where k = 'req'), (select id from users where email = 'pm.pat@example.test')), 'included');
select test.throws('option 4 sent for another car is refused', format($q$select %s$q$, $q2$app.submit_booking_request(jsonb_build_object(
  'request_key', 'pm-key-2', 'vehicle_id', test.pm_car('Audi A5 Conv'), 'pickup_at', test.pm_at(15, 0), 'return_at', test.pm_at(18, 0), 'booking_type', 'standard', 'coverage_option', 4,
  'consents', jsonb_build_object('terms', jsonb_build_object('accepted', true, 'version', 'terms-2026-10', 'text', 'x'), 'privacy', jsonb_build_object('accepted', true, 'version', 'privacy-2026-10', 'text', 'x')),
  'renter', jsonb_build_object('full_name', 'Pat Morgan', 'date_of_birth', '1985-03-03', 'email', 'pm.pat2@example.test', 'mobile', '416-555-0162', 'licence_class', 'G', 'licence_issuer', 'ON')))$q2$), 'option 1, 2 or 3');
select test.eq('the coverage label', app.coverage_option_label(4), 'insurance included with the car');

select test.throws('the offer waits for the model year to be confirmed', format('select app.send_offer(%L, %L)', (select (v ->> 'booking_id')::uuid from s61 where k = 'req'), test.id('pm_cs')), 'Confirm the model year');
select app.partner_car_save(test.id('pm_admin'), jsonb_build_object('vehicle_id', test.pm_car('Mercedes S580'), 'year', 2024));
select test.lives('once confirmed, the offer goes', format('select app.send_offer(%L, %L)', (select (v ->> 'booking_id')::uuid from s61 where k = 'req'), test.id('pm_cs')));
select test.eq('the confirmed year is in the name again', app.vehicle_name(test.pm_car('Mercedes S580')), '2024 Mercedes-Benz S-Class S580');

-- ================================================================ 5. no credit card needed: a debit card is accepted
select test.eq('debit on a no-credit-card car: accepted', app.booking_card_ok((select (v ->> 'booking_id')::uuid from s61 where k = 'req'), '{"is_credit": false, "funding": "debit"}'), true);
select test.eq('prepaid on it: refused', app.booking_card_ok((select (v ->> 'booking_id')::uuid from s61 where k = 'req'), '{"is_credit": false, "funding": "prepaid"}'), false);

-- ================================================================ 6. the split on the partner's rates: a sample booking, 3 days on the C43 AMG Blue
insert into bookings (id, booking_number, booking_type, status, vehicle_id, renter_id, booked_at, pickup_at, return_at, original_return_at, billable_days,
    checked_in_at, handed_over_at, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, rate_applied, daily_days, weekend_days,
    rental_charge_cents, discount_cents, km_allowance_per_day, km_allowance_total, overage_cents_per_km, deposit_cents, card_on_file_id,
    subtotal_at_booking_cents, hst_at_booking_cents, total_due_at_booking_cents)
values (test.id('booking:PM-1'), 'PM-1', 'standard', 'closed', test.pm_car('Mercedes C43 AMG Blue'), test.id('renter:pm_rita'),
    timestamptz '2026-09-01 10:00-04', timestamptz '2026-09-10 10:00-04', timestamptz '2026-09-13 10:00-04', timestamptz '2026-09-13 10:00-04', 3,
    timestamptz '2026-09-13 10:00-04', timestamptz '2026-09-10 10:00-04', 27500, 27500, 154000, 660000, 'multi_day', 0, 0,
    74400, 0, 200, 600, 35, 100000, test.id('card:pm_rita'), 74400, public.calc_hst(74400), 74400 + public.calc_hst(74400));
select test.mk_line('PM-1', 'rental_charge', 74400);
select app.compute_booking_split(test.id('booking:PM-1'));
select test.eq('booking: the sheet amount at the partner''s rates (3 x $225), the cut, the markup',
  (select format('%s %s %s', partner_sheet_rental_cents, partner_cut_bps, partner_markup_bps) from bookings where id = test.id('booking:PM-1')), '67500 2000 1000');
select test.eq('split: renter $744, sheet $675, CarmaCars 20% $135, partner $540, markup $69 (CarmaCars keeps $204)',
  (select format('%s %s %s %s %s %s %s', rental_charge_cents, partner_sheet_cents, owner_revenue_cents, company_share_cents, owner_payout_cents, partner_markup_cents,
                 rental_charge_cents - owner_payout_cents)
     from booking_splits where booking_id = test.id('booking:PM-1')), '74400 67500 67500 13500 54000 6900 20400');
-- a refund of half the rental: the partner's share falls in proportion
insert into refunds (id, booking_id, amount_cents, status, reason, approved_by, approved_at, paid_at)
values (test.id('refund:PM-1'), test.id('booking:PM-1'), 37200, 'paid', 'goodwill', test.id('pm_admin'), now(), now());
insert into refund_allocations (refund_id, line_item_id, amount_cents)
select test.id('refund:PM-1'), li.id, 37200 from booking_line_items li where li.booking_id = test.id('booking:PM-1') and li.charge_type = 'rental_charge';
select app.compute_booking_split(test.id('booking:PM-1'));
select test.eq('a half refund halves the partner''s share (sheet $337.50, payout $270)',
  (select format('%s %s', partner_sheet_cents, owner_payout_cents) from booking_splits where booking_id = test.id('booking:PM-1')), '33750 27000');
delete from refund_allocations where refund_id = test.id('refund:PM-1');
delete from refunds where id = test.id('refund:PM-1');
select app.compute_booking_split(test.id('booking:PM-1'));
insert into s61 select 'stmt', to_jsonb(app.build_owner_statement((select owner_id from partners where business_name = '01 Motors'), date '2026-09-01', test.id('pm_admin')));
select test.eq('the statement: the partner sees the sheet amount, the 20% and the payout, never the renter''s price',
  (select format('%s %s %s %s %s', l.rental_charge_cents, l.partner_sheet_cents, l.revenue_share_cents, l.amount_cents, l.description like '%sheet rate $675%')
     from owner_statement_lines l
    where l.owner_statement_id = (select (v #>> '{}')::uuid from s61 where k = 'stmt')
      and l.booking_id = test.id('booking:PM-1')),
  '67500 67500 13500 54000 t');

-- ================================================================ 7. the chauffeur service
select test.eq('the public list: 11 vehicles with the renter''s hourly rates (the S580: $220 for 2 hours, $193 for 3 or more)',
  (select format('%s %s %s', jsonb_array_length(s -> 'vehicles'), v ->> 'rate_2h_cents', v ->> 'rate_3plus_cents')
     from (select public.chauffeur_services() s) x, jsonb_array_elements(s -> 'vehicles') v where v ->> 'name' = 'Mercedes-Benz S580'), '11 22000 19300');
select test.ok('the public list shows no sheet rate or cut', not (public.chauffeur_services()::text like '%sheet_%' or public.chauffeur_services()::text like '%cut_%'));
insert into s61 select 'ch', public.submit_chauffeur_request(jsonb_build_object('request_key', 'pm-ch-1',
  'vehicle_id', (select id from chauffeur_vehicles where sheet_name = 'Mercedes S580'), 'date', app.today() + 5, 'start_time', '18:30', 'hours', 3,
  'pickup_address', '100 Queen Street West, Toronto', 'dropoff_address', 'Pearson Airport', 'passengers', 2, 'occasion', 'Wedding',
  'name', 'Pat Morgan', 'email', 'pm.ch@example.test', 'phone', '416-555-0163'), '203.0.113.61');
select test.eq('chauffeur request: accepted with its reference', (select v ->> 'ok' from s61 where k = 'ch'), 'true');
select test.eq('chauffeur request: the quote (3 x $193, HST), the partner''s $420 and CarmaCars'' $159; the lead of kind chauffeur; the task',
  (select format('%s %s %s %s %s %s %s', r.renter_cents, r.hst_cents, r.sheet_cents, r.partner_payout_cents, r.carmacars_keep_cents, l.kind,
                 exists (select 1 from tasks t where t.related_id = r.id and t.task_type = 'chauffeur_request'))
     from chauffeur_requests r join leads l on l.id = r.lead_id where r.reference = (select v ->> 'reference' from s61 where k = 'ch')),
  '57900 7527 52500 42000 15900 chauffeur t');
select test.eq('the same request twice is one', (public.submit_chauffeur_request(jsonb_build_object('request_key', 'pm-ch-1'), null) ->> 'created'), 'false');
select test.eq('fewer than 2 hours is refused', (public.submit_chauffeur_request(jsonb_build_object('vehicle_id', (select id from chauffeur_vehicles where sheet_name = 'Mercedes S580'),
  'date', app.today() + 5, 'start_time', '10:00', 'hours', 1, 'pickup_address', 'Somewhere 1', 'passengers', 1, 'name', 'Pat', 'email', 'pm.x@example.test'), null) #>> '{fields,hours}'),
  'Book at least 2 hours (24 at most).');
select test.throws('staff only: a fleet assistant cannot handle chauffeur requests', format('select app.chauffeur_requests_list(%L)', test.id('pm_fleet')), 'Not permitted');
select app.chauffeur_request_update(test.id('pm_cs'), jsonb_build_object('id', (select id from chauffeur_requests where request_key = 'pm-ch-1'), 'hours', 2, 'status', 'quoted', 'quote_note', 'Emailed'));
select test.eq('staff change the hours (2 at the 2-hour rate) and quote: the task is done',
  (select format('%s %s %s %s', r.status, r.renter_cents, r.quoted_at is not null, (select t.status from tasks t where t.related_id = r.id))
     from chauffeur_requests r where r.request_key = 'pm-ch-1'), 'quoted 44000 t done');
select test.eq('To do: the chauffeur line', (select i ->> 'label' from jsonb_array_elements(app.admin_todo(test.id('pm_admin')) -> 'items') i where i ->> 'key' = 'chauffeur'), 'Chauffeur requests to quote');
