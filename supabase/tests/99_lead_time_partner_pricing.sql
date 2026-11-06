-- 99: lead-time pricing (0360) and 01 Motors on our own pricing (0361). Fixtures start with "ltp".
select test.suite('99 lead-time and partner pricing');
-- 2026-11-06: the quotes below run from 30 to 78 hours from now and expect weekday rates ($100 a day). When that window touches
-- a Saturday or Sunday (Toronto time) the weekend rate applies and the amounts differ, so the suite runs on the other days.
select exists (select 1 from generate_series(0, 48) h where extract(isodow from (now() + interval '30 hours' + make_interval(hours => h)) at time zone 'America/Toronto') >= 6) as ltp_weekend \gset
\if :ltp_weekend
\echo 99 lead-time and partner pricing: skipped, the 30 to 78 hour window touches a weekend
\quit
\endif
select test.mk_user('ltp_admin', 'admin');
select test.mk_user('ltp_cs', 'va', 'cs');
select test.mk_owner('ltp_owner');
select test.mk_vehicle('ltp_car', 'ltp_owner');
select test.mk_vehicle('ltp_car2', 'ltp_owner');
-- the quotes below start 30 hours from now: one rate every day of the week, so the amounts do not depend on the weekday
-- the suite runs on (a Friday run put a Saturday in them at the weekend rate; the weekend premium is put back before part 8)
create temp table ltp_wk as select id, weekend_premium_bps from program_settings;
update program_settings set weekend_premium_bps = 0;
create temp table ltp_rc as select id, weekend_rate_cents from rate_cards where vehicle_id in (test.id('vehicle:ltp_car'), test.id('vehicle:ltp_car2'));
update rate_cards set weekend_rate_cents = daily_rate_cents where id in (select id from ltp_rc);
select test.mk_renter('ltp_rita');
-- a pickup at 10:00 Toronto time, so many days from today
create function test.ltp_at(p_days integer, p_hour integer default 10) returns timestamptz language sql stable as $$
  select (app.today() + p_days)::timestamp at time zone 'America/Toronto' + make_interval(hours => p_hour) $$;
create function test.ltp_line(q jsonb, p_type text) returns jsonb language sql immutable as $$
  select l from jsonb_array_elements(q -> 'lines') l where l ->> 'charge_type' = p_type limit 1 $$;
create temp table s99ltp (k text primary key, v jsonb);

-- ================================================================ 1. the tiers and their boundaries
-- the earlier suites run with it off (helpers.sql); on for this suite, off again at its end
update program_settings set lead_time_enabled = true;
select test.eq('defaults: insurer bookings not adjusted, four tiers',
  (select format('%s %s %s', lead_time_enabled, lead_time_insurer, lead_time_tiers::text) from app.settings()),
  't f [{"bps": 1500, "from_hours": 0}, {"bps": 1000, "from_hours": 24}, {"bps": 0, "from_hours": 72}, {"bps": -500, "from_hours": 336}]');
select test.eq('each tier and its boundaries (hours ahead: percentage)',
  (select string_agg(h::text || ':' || (app.lead_time_for(test.id('vehicle:ltp_car'), timestamptz '2026-11-20 12:00-05' + make_interval(secs => h * 3600), timestamptz '2026-11-20 12:00-05') ->> 'bps'), ' ' order by h)
     from unnest(array[-5, 0, 1, 23.99, 24, 25, 71.99, 72, 100, 335.99, 336, 400, 2000]::numeric[]) h),
  '-5:1500 0:1500 1:1500 23.99:1500 24:1000 25:1000 71.99:1000 72:0 100:0 335.99:0 336:-500 400:-500 2000:-500');
select test.eq('the words of the line', format('%s | %s | %s', app.lead_time_text(1500), app.lead_time_text(1000), app.lead_time_text(-500)),
  'Short-notice pricing +15% | Short-notice pricing +10% | Booked ahead ' || chr(8722) || '5%');

-- Toronto time: the hours are counted on Toronto clocks, across a change of the clocks
select test.eq('fall back: requested 10:30 EDT, pickup two weeks later at 10:00 EST is 335.5 hours on the clocks: 0%, not booked ahead',
  (select format('%s %s', l ->> 'hours', l ->> 'bps') from (select app.lead_time_for(test.id('vehicle:ltp_car'), timestamptz '2026-11-08 10:00-05', timestamptz '2026-10-25 10:30-04') l) x),
  '335.50 0');
select test.eq('spring forward: requested 09:30 EST, pickup the next day 10:00 EDT is 24.5 hours on the clocks (23.5 elapsed): +10%',
  (select format('%s %s', l ->> 'hours', l ->> 'bps') from (select app.lead_time_for(test.id('vehicle:ltp_car'), timestamptz '2027-03-14 10:00-04', timestamptz '2027-03-13 09:30-05') l) x),
  '24.50 1000');
select test.eq('a tier table is checked: first from 0, rising hours, -50% to +50%',
  format('%s %s %s %s', app.lead_time_tiers_ok('[{"from_hours": 0, "bps": 1500}]'), app.lead_time_tiers_ok('[{"from_hours": 5, "bps": 0}]'),
         app.lead_time_tiers_ok('[{"from_hours": 0, "bps": 0}, {"from_hours": 0, "bps": 100}]'), app.lead_time_tiers_ok('[{"from_hours": 0, "bps": 6000}]')),
  't f f f');
select test.throws('Program settings refuse a bad tier table',
  $q$update program_settings set lead_time_tiers = '[{"from_hours": 24, "bps": 100}]' where effective_from = (select max(effective_from) from program_settings)$q$, 'lead_time_tiers_ok');

-- ================================================================ 2. the quote: the rental charge only, one line
insert into s99ltp select 'q30h', app.quote_booking(test.id('vehicle:ltp_car'), now() + interval '30 hours', now() + interval '78 hours',
  '{"pickup_method": "delivered", "pickup_location": {"kind": "delivery", "distance_km": 10}}');
select test.eq('30 hours ahead: the rental charge $200, "Short-notice pricing +10%" $20, after the rental line',
  (select format('%s %s %s %s', test.ltp_line(v, 'rental_charge') ->> 'amount_cents', test.ltp_line(v, 'lead_time') ->> 'description',
                 test.ltp_line(v, 'lead_time') ->> 'amount_cents', (v -> 'lines' -> 1 ->> 'charge_type')) from s99ltp where k = 'q30h'),
  '20000 Short-notice pricing +10% 2000 lead_time');
select test.eq('only the rental charge is adjusted: the delivery fee and the deposit are not; HST on the adjusted rental',
  (select format('%s %s %s', test.ltp_line(v, 'delivery') is not null, v ->> 'deposit_cents', (v ->> 'hst_cents')::bigint = (select sum((l ->> 'hst_cents')::bigint) from jsonb_array_elements(v -> 'lines') l))
     from s99ltp where k = 'q30h'), 't 100000 t');
select test.eq('the quote carries the percentage and the amount',
  (select format('%s %s', v ->> 'lead_time_bps', v ->> 'lead_time_cents') from s99ltp where k = 'q30h'), '1000 2000');
select test.eq('3 to 13 days ahead: no line', (select count(*) from jsonb_array_elements(app.quote_booking(test.id('vehicle:ltp_car'), test.ltp_at(5), test.ltp_at(7)) -> 'lines') l
  where l ->> 'charge_type' = 'lead_time'), 0::bigint);
select test.eq('20 days ahead: "Booked ahead -5%" off the rental charge',
  (select format('%s %s', test.ltp_line(q, 'lead_time') ->> 'amount_cents', test.ltp_line(q, 'rental_charge') ->> 'amount_cents')
     from (select app.quote_booking(test.id('vehicle:ltp_car'), test.ltp_at(20), test.ltp_at(22)) q) x),
  format('%s %s', -public.calc_bps((app.quote_booking(test.id('vehicle:ltp_car'), test.ltp_at(20), test.ltp_at(22)) ->> 'rental_charge_cents')::bigint, 500),
         app.quote_booking(test.id('vehicle:ltp_car'), test.ltp_at(20), test.ltp_at(22)) ->> 'rental_charge_cents'));
select test.eq('non-refundable 20 days ahead: the 10% discount on the rental charge from the rates, and -5% beside it',
  (select format('%s %s %s', (q ->> 'rental_charge_cents')::bigint, -(test.ltp_line(q, 'non_refundable_discount') ->> 'amount_cents')::bigint, -(test.ltp_line(q, 'lead_time') ->> 'amount_cents')::bigint)
     from (select app.quote_booking(test.id('vehicle:ltp_car'), test.ltp_at(20), test.ltp_at(22), '{"booking_type": "non_refundable"}') q) x),
  (select format('%s %s %s', r, public.calc_bps(r, 1000), public.calc_bps(r, 500)) from (select (app.quote_booking(test.id('vehicle:ltp_car'), test.ltp_at(20), test.ltp_at(22)) ->> 'rental_charge_cents')::bigint r) x));
insert into promo_codes (code, description, percent_bps, valid_from, valid_until, is_active)
values ('LTPTEN', 'Ten off', 1000, now() - interval '1 day', now() + interval '30 days', true);
select test.eq('a promo code: worked out on the rental charge from the rates; the short-notice line stays',
  (select format('%s %s', test.ltp_line(q, 'promo_discount') ->> 'amount_cents', test.ltp_line(q, 'lead_time') ->> 'amount_cents')
     from (select app.quote_booking(test.id('vehicle:ltp_car'), now() + interval '30 hours', now() + interval '78 hours', '{"promo_code": "LTPTEN"}') q) x),
  '-2000 2000');
-- ================================================================ 3. turned off globally and per car
update program_settings set lead_time_enabled = false;
select test.eq('off in Program settings: no line on any car', (select count(*) from jsonb_array_elements(app.quote_booking(test.id('vehicle:ltp_car'), now() + interval '30 hours', now() + interval '78 hours') -> 'lines') l
  where l ->> 'charge_type' = 'lead_time'), 0::bigint);
update program_settings set lead_time_enabled = true;
select app.vehicle_lead_time_save(test.id('ltp_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:ltp_car2'), 'mode', 'off'));
select test.eq('off for one car: that car has no line, the other still has', format('%s %s',
  (select count(*) from jsonb_array_elements(app.quote_booking(test.id('vehicle:ltp_car2'), now() + interval '30 hours', now() + interval '78 hours') -> 'lines') l where l ->> 'charge_type' = 'lead_time'),
  (select count(*) from jsonb_array_elements(app.quote_booking(test.id('vehicle:ltp_car'), now() + interval '30 hours', now() + interval '78 hours') -> 'lines') l where l ->> 'charge_type' = 'lead_time')), '0 1');
select app.vehicle_lead_time_save(test.id('ltp_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:ltp_car2'), 'mode', 'own',
  'tiers', '[{"from_hours": 0, "bps": 2500}, {"from_hours": 48, "bps": 0}]'::jsonb));
select test.eq('its own tiers: 30 hours ahead +25%', (test.ltp_line(app.quote_booking(test.id('vehicle:ltp_car2'), now() + interval '30 hours', now() + interval '78 hours'), 'lead_time') ->> 'amount_cents'), '5000');
select test.throws('its own tiers are checked', format('select app.vehicle_lead_time_save(%L, %L)', test.id('ltp_admin'),
  jsonb_build_object('vehicle_id', test.id('vehicle:ltp_car2'), 'mode', 'own', 'tiers', '[{"from_hours": 3, "bps": 100}]'::jsonb)), 'Each tier');
select test.throws('only an Admin sets a car''s lead-time pricing', format('select app.vehicle_lead_time_save(%L, %L)', test.id('ltp_cs'),
  jsonb_build_object('vehicle_id', test.id('vehicle:ltp_car2'), 'mode', 'off')));
select app.vehicle_lead_time_save(test.id('ltp_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:ltp_car2'), 'mode', 'program'));

-- ================================================================ 4. locked on the request and the offer
insert into s99ltp select 'b1', to_jsonb(app.request_booking(test.id('renter:ltp_rita'), test.id('vehicle:ltp_car'), now() + interval '30 hours', now() + interval '78 hours'));
create function test.ltp_b() returns bookings language sql stable as $$ select * from bookings where id = (select (v #>> '{}')::uuid from s99ltp where k = 'b1') $$;
select test.eq('the request locks +10% with its hours ahead',
  (select format('%s %s %s', b.lead_time_bps, b.lead_time_source, b.lead_time_hours between 29.9 and 30.1) from test.ltp_b() b), '1000 auto t');
select test.eq('the booking''s lines: the rental charge and "Short-notice pricing +10%"; the total includes it',
  (select format('%s %s %s', li.description, li.amount_cents, b.subtotal_at_booking_cents)
     from test.ltp_b() b join booking_line_items li on li.booking_id = b.id and li.charge_type = 'lead_time' and li.voided_at is null), 'Short-notice pricing +10% 2000 22000');
select app.send_offer((test.ltp_b()).id, test.id('ltp_cs'));
-- the tiers change after the offer went out: the offer and the booking keep their price
update program_settings set lead_time_tiers = '[{"from_hours": 0, "bps": 3000}]';
select app.sync_booking_price((test.ltp_b()).id);
select test.eq('after the offer: the tiers changed, the price is worked out again and the percentage stays locked',
  (select format('%s %s %s', b.status, b.lead_time_bps, (select li.amount_cents from booking_line_items li where li.booking_id = b.id and li.charge_type = 'lead_time' and li.voided_at is null))
     from test.ltp_b() b), 'offered 1000 2000');
update program_settings set lead_time_tiers = '[{"from_hours": 0, "bps": 1500}, {"from_hours": 24, "bps": 1000}, {"from_hours": 72, "bps": 0}, {"from_hours": 336, "bps": -500}]'
;
select test.ok('the offer version shows the line', exists (select 1 from booking_offers o where o.booking_id = (test.ltp_b()).id and o::text like '%Short-notice pricing +10%%'));

-- ================================================================ 5. staff override it
select test.throws('an offer out is changed by editing the offer', format('select app.booking_lead_time_set(%L, %L, 500)', test.id('ltp_cs'), (test.ltp_b()).id), 'edit the offer');
select app.offer_revise(test.id('ltp_cs'), jsonb_build_object('booking', (test.ltp_b()).id, 'lead_time', jsonb_build_object('bps', 500), 'notify', false));
select test.eq('staff set +5% on the offer, edited in place: the line follows, its words too',
  (select format('%s %s %s', b.lead_time_bps, b.lead_time_source, li.description || ' ' || li.amount_cents)
     from test.ltp_b() b join booking_line_items li on li.booking_id = b.id and li.charge_type = 'lead_time' and li.voided_at is null), '500 staff Short-notice pricing +5% 1000');
select app.offer_revise(test.id('ltp_admin'), jsonb_build_object('booking', (test.ltp_b()).id, 'lead_time', jsonb_build_object('bps', 0), 'notify', false));
select test.eq('staff set none: the line is gone', (select count(*) from booking_line_items li where li.booking_id = (test.ltp_b()).id and li.charge_type = 'lead_time' and li.voided_at is null), 0::bigint);
select app.offer_revise(test.id('ltp_admin'), jsonb_build_object('booking', (test.ltp_b()).id, 'lead_time', jsonb_build_object('auto', true), 'notify', false));
select test.eq('back to the tier of the request (the review screen and an offer edited in place)',
  (select format('%s %s', b.lead_time_bps, b.lead_time_source) from test.ltp_b() b), '1000 auto');
select test.throws('a renter cannot set it', format('select app.booking_lead_time_set(%L, %L, 0)', test.id('ltp_rita'), (test.ltp_b()).id), 'Staff');
select app.offer_revise(test.id('ltp_admin'), jsonb_build_object('booking', (test.ltp_b()).id, 'changes', jsonb_build_object('rental_charge_cents', 25000, 'price_tax', 'plus', 'price_reason', 'Agreed on the phone'), 'notify', false));
select test.eq('a price typed by hand replaces it: $250, no lead-time line',
  (select format('%s %s', b.subtotal_at_booking_cents, (select count(*) from booking_line_items li where li.booking_id = b.id and li.charge_type = 'lead_time' and li.voided_at is null))
     from test.ltp_b() b), '25000 0');
select test.eq('staff typing a price in a quote: no adjustment', (select (app.quote_lead_time(test.id('vehicle:ltp_car'), now() + interval '30 hours',
  '{"staff_rental_charge_cents": 20000}') ->> 'bps') from (select set_config('app.staff_pricing', 'on', true)) x), '0');

-- ================================================================ 6. insurer bookings
select test.eq('billed to an insurer: not adjusted (Program settings, by default)',
  (select count(*) from jsonb_array_elements(app.price_lines(jsonb_build_object('pickup_at', now() + interval '30 hours', 'return_at', now() + interval '78 hours',
     'daily_rate_cents', 10000, 'weekend_rate_cents', 12000, 'weekly_rate_cents', 56000, 'monthly_rate_cents', 180000, 'hst_bps', 1300,
     'lead_time_bps', 1000, 'insurer_billed', true)) -> 'lines') l where l ->> 'charge_type' = 'lead_time'), 0::bigint);
update program_settings set lead_time_insurer = true;
select test.eq('with the setting on, an insurer booking is adjusted too',
  (select count(*) from jsonb_array_elements(app.price_lines(jsonb_build_object('pickup_at', now() + interval '30 hours', 'return_at', now() + interval '78 hours',
     'daily_rate_cents', 10000, 'weekend_rate_cents', 12000, 'weekly_rate_cents', 56000, 'monthly_rate_cents', 180000, 'hst_bps', 1300,
     'lead_time_bps', 1000, 'insurer_billed', true)) -> 'lines') l where l ->> 'charge_type' = 'lead_time'), 1::bigint);
update program_settings set lead_time_insurer = false;
select test.eq('an Owner Booking is never adjusted', (app.price_lines(jsonb_build_object('pickup_at', now() + interval '30 hours', 'return_at', now() + interval '78 hours',
  'booking_type', 'owner', 'lead_time_bps', 1000)) ->> 'lead_time_cents'), '0');

-- ================================================================ 7. owner revenue and commissions count it with the rental
insert into s99ltp select 'b2', to_jsonb(app.request_booking(test.id('renter:ltp_rita'), test.id('vehicle:ltp_car2'), now() + interval '30 hours', now() + interval '78 hours'));
set session_replication_role = replica;
update bookings set status = 'closed', confirmed_at = now(), handed_over_at = pickup_at, checked_in_at = return_at where id = (select (v #>> '{}')::uuid from s99ltp where k = 'b2');
set session_replication_role = origin;
select app.compute_booking_split((select (v #>> '{}')::uuid from s99ltp where k = 'b2'));
select test.eq('the split''s rental charge is the rental after the short-notice line ($200 + $20)',
  (select rental_charge_cents from booking_splits where booking_id = (select (v #>> '{}')::uuid from s99ltp where k = 'b2')), 22000::bigint);
select test.ok('the commission lines include it', 'lead_time' = any (app.commission_line_types()));
select test.ok('it is never a fee on the site', not ((app.public_site_facts() -> 'fees') ? 'lead_time'));

-- the weekend premium and the cars' weekend rates back (the partner rates below use the weekend rule; 99 weekend above
-- daily checks every current card)
update program_settings p set weekend_premium_bps = w.weekend_premium_bps from ltp_wk w where w.id = p.id;
update rate_cards r set weekend_rate_cents = x.weekend_rate_cents from ltp_rc x where x.id = r.id;
-- ================================================================ 8. 01 Motors: listed rates less 10%, our rules, the 20% kickback
create function test.ltp_pm(p_sheet text) returns uuid language sql stable as $$
  select v.id from vehicles v join partners p on p.id = v.partner_id where p.business_name = '01 Motors' and v.partner_sheet_name = p_sheet $$;
select test.eq('the partner: no markup, 10% discount, 20% kickback',
  (select format('%s %s %s %s', p.markup_bps is null, coalesce(p.discount_bps, (app.settings()).partner_discount_bps), p.commission_bps, p.payout_basis) from partners p where p.business_name = '01 Motors'), 't 1000 2000 partner_rate');
select test.eq('listed rates kept as given (C43 AMG Blue: $250 / $225 / $200)',
  (select format('%s %s %s', base_cents, multi_day_cents, long_term_cents) from partner_rates where vehicle_id = test.ltp_pm('Mercedes C43 AMG Blue')), '25000 22500 20000');
select test.eq('our base = 90% of listed, to the dollar: daily $225, 3+ days $203 ($202.50 up), 7+ days $180 a day; the weekend rule gives $259',
  (select format('%s %s %s %s %s', daily_rate_cents, multi_day_rate_cents, weekly_rate_cents, monthly_rate_cents, weekend_rate_cents)
     from rate_cards where vehicle_id = test.ltp_pm('Mercedes C43 AMG Blue') and effective_to is null), '22500 20300 126000 540000 25900');
select test.ok('no partner car has a weekend rate at or below its daily rate', not exists (select 1 from rate_cards r join vehicles v on v.id = r.vehicle_id
  where v.supply_type = 'partner' and r.effective_to is null and r.weekend_rate_cents <= r.daily_rate_cents));
insert into s99ltp select 'pmq', app.quote_booking(test.ltp_pm('Mercedes C43 AMG Blue'), test.ltp_at(20), test.ltp_at(23),
  '{"pickup_method": "delivered", "pickup_location": {"kind": "delivery", "distance_km": 10}, "drivers": [{"role": "renter", "age": 23}]}');
select test.eq('the quote: 3 days at our 3+ day rate ($609), booked ahead -5% ($30.45 off), the delivery and young driver fees added, HST on all',
  (select format('%s %s %s %s %s', test.ltp_line(v, 'rental_charge') ->> 'amount_cents', test.ltp_line(v, 'lead_time') ->> 'amount_cents',
                 test.ltp_line(v, 'delivery') is not null, test.ltp_line(v, 'young_driver_21_25') is not null,
                 (v ->> 'hst_cents')::bigint = (select sum(public.calc_hst((l ->> 'amount_cents')::bigint, 1300)) from jsonb_array_elements(v -> 'lines') l where (l ->> 'hst_applies')::boolean))
     from s99ltp where k = 'pmq'), '60900 -3045 t t t');
select test.eq('the fleet cards for those dates: the rental after booked ahead ($609 - $30.45)',
  (select rental_charge_cents from app.search_available(test.ltp_at(20), test.ltp_at(23)) where vehicle_id = test.ltp_pm('Mercedes C43 AMG Blue')), 57855::bigint);
select test.eq('the non-refundable discount applies to a partner car too', (select test.ltp_line(app.quote_booking(test.ltp_pm('Mercedes C43 AMG Blue'), test.ltp_at(20), test.ltp_at(23),
  '{"booking_type": "non_refundable"}'), 'non_refundable_discount') ->> 'amount_cents'), '-6090');

-- a booking on it, requested 21 days before pickup (written as the request writes it, in September so its month can be
-- stated), from the request to the split
insert into bookings (id, booking_number, booking_type, status, vehicle_id, renter_id, source, booked_at, requested_at, pickup_at, return_at, original_return_at,
    billable_days, rate_card_id, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, multi_day_rate_cents, rate_applied, daily_days, weekend_days,
    rental_charge_cents, discount_cents, km_allowance_per_day, km_allowance_total, overage_cents_per_km, deposit_cents, card_on_file_id, hst_bps)
select test.id('booking:LTP-PM'), 'LTP-PM', 'standard', 'requested', rc.vehicle_id, test.id('renter:ltp_rita'), 'web',
       timestamptz '2026-08-20 10:00-04', timestamptz '2026-08-20 10:00-04', timestamptz '2026-09-10 10:00-04', timestamptz '2026-09-13 10:00-04', timestamptz '2026-09-13 10:00-04',
       3, rc.id, rc.daily_rate_cents, rc.weekend_rate_cents, rc.weekly_rate_cents, rc.monthly_rate_cents, rc.multi_day_rate_cents, 'multi_day', 0, 0,
       3 * rc.multi_day_rate_cents, 0, 200, 600, 35, 100000, test.id('card:ltp_rita'), 1300
  from rate_cards rc where rc.vehicle_id = test.ltp_pm('Mercedes C43 AMG Blue') and rc.effective_to is null;
select app.sync_booking_price(test.id('booking:LTP-PM'));
insert into s99ltp values ('pmb', to_jsonb(test.id('booking:LTP-PM')));
create function test.ltp_pmb() returns bookings language sql stable as $$ select * from bookings where id = (select (v #>> '{}')::uuid from s99ltp where k = 'pmb') $$;
select test.eq('the booking: listed rental 3 x $225 = $675, 20% kickback, 10% discount, no markup',
  (select format('%s %s %s %s %s', b.partner_sheet_rental_cents, b.partner_cut_bps, b.partner_discount_bps, b.partner_markup_bps is null, b.lead_time_bps) from test.ltp_pmb() b),
  '67500 2000 1000 t -500');
set session_replication_role = replica;
update bookings set status = 'closed', confirmed_at = now(), handed_over_at = pickup_at, checked_in_at = return_at where id = (test.ltp_pmb()).id;
set session_replication_role = origin;
-- paid in full
insert into payments (id, booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at)
select test.id('payment:LTP-PM'), b.id, b.renter_id, 'booking_total', 'charge', 'card', b.total_due_at_booking_cents, 'succeeded', b.booked_at from bookings b where b.id = test.id('booking:LTP-PM');
update booking_line_items set payment_id = test.id('payment:LTP-PM') where booking_id = test.id('booking:LTP-PM') and voided_at is null;
select app.compute_booking_split((test.ltp_pmb()).id);
select test.eq('the split: rental $578.55, listed $675, kickback receivable $135 (20% of listed), payable $540, our part -$96.45',
  (select format('%s %s %s %s %s %s', rental_charge_cents, partner_sheet_cents, partner_kickback_cents, company_share_cents, owner_payout_cents, partner_markup_cents)
     from booking_splits where booking_id = (test.ltp_pmb()).id), '57855 67500 13500 13500 54000 -9645');
insert into s99ltp select 'pmstmt', to_jsonb(app.build_owner_statement((select owner_id from partners where business_name = '01 Motors'), date '2026-09-01', test.id('ltp_admin')));
select test.eq('the partner''s statement: the listed rental, the kickback and the amount payable; never our price',
  (select format('%s %s %s', l.rental_charge_cents, l.amount_cents, l.description like '%at your listed rate $675.00, less the 20% kickback to CarmaCars ($135.00), payable to you $540.00%')
     from owner_statement_lines l where l.booking_id = (test.ltp_pmb()).id and l.line_type = 'rental'), '67500 54000 t');
select test.eq('Admin''s partner page: the receivable and the payable',
  (select format('%s %s %s', r ->> 'listed_cents', r ->> 'kickback_cents', r ->> 'payable_cents')
     from jsonb_array_elements(app.partner_detail(test.id('ltp_admin'), (select id from partners where business_name = '01 Motors')) -> 'money' -> 'rentals') r
    where r ->> 'booking_number' = (test.ltp_pmb()).booking_number), '67500 13500 54000');
select test.eq('the fees stay ours: nothing but the listed rental reaches the partner', (select owner_revenue_cents from booking_splits where booking_id = (test.ltp_pmb()).id), 67500::bigint);

-- Admin: the partner's discount and a car's own; the rates follow
select app.partner_pricing_save(test.id('ltp_admin'), jsonb_build_object('id', (select id from partners where business_name = '01 Motors'), 'discount_bps', 2000));
select test.eq('a 20% discount for the partner: A220 $140 listed becomes $112', (select daily_rate_cents from rate_cards where vehicle_id = test.ltp_pm('Mercedes A220') and effective_to is null), 11200::bigint);
select app.partner_car_save(test.id('ltp_admin'), jsonb_build_object('vehicle_id', test.ltp_pm('Mercedes A220'), 'discount_bps', 0));
select test.eq('a car''s own discount of 0: sold at its listed rate', (select daily_rate_cents from rate_cards where vehicle_id = test.ltp_pm('Mercedes A220') and effective_to is null), 14000::bigint);
select app.partner_pricing_save(test.id('ltp_admin'), jsonb_build_object('id', (select id from partners where business_name = '01 Motors'), 'discount_bps', 1000));
select app.partner_car_save(test.id('ltp_admin'), jsonb_build_object('vehicle_id', test.ltp_pm('Mercedes A220'), 'discount_bps', null));
select test.eq('back to 10%: $126', (select daily_rate_cents from rate_cards where vehicle_id = test.ltp_pm('Mercedes A220') and effective_to is null), 12600::bigint);
select test.eq('applying the same rates again adds no rate card', (select count(*) from rate_cards where vehicle_id = test.ltp_pm('Mercedes A220') and effective_to is null and
  app.partner_rates_apply(test.ltp_pm('Mercedes A220')) = id), 1::bigint);

-- a booking made on 0093's markup keeps its price and 0093's split (the overage shared)
insert into bookings (id, booking_number, booking_type, status, vehicle_id, renter_id, booked_at, pickup_at, return_at, original_return_at, billable_days,
    checked_in_at, handed_over_at, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, rate_applied, daily_days, weekend_days,
    rental_charge_cents, discount_cents, km_allowance_per_day, km_allowance_total, overage_cents_per_km, deposit_cents, card_on_file_id,
    subtotal_at_booking_cents, hst_at_booking_cents, total_due_at_booking_cents)
values (test.id('booking:LTP-OLD'), 'LTP-OLD', 'standard', 'closed', test.ltp_pm('Mercedes C43 AMG White'), test.id('renter:ltp_rita'),
    timestamptz '2026-09-01 10:00-04', timestamptz '2026-09-10 10:00-04', timestamptz '2026-09-13 10:00-04', timestamptz '2026-09-13 10:00-04', 3,
    timestamptz '2026-09-13 10:00-04', timestamptz '2026-09-10 10:00-04', 27500, 27500, 154000, 660000, 'multi_day', 0, 0,
    74400, 0, 200, 600, 35, 100000, test.id('card:ltp_rita'), 74400, public.calc_hst(74400), 74400 + public.calc_hst(74400));
update bookings set partner_markup_bps = 1000, partner_discount_bps = null where id = test.id('booking:LTP-OLD');
select test.mk_line('LTP-OLD', 'rental_charge', 74400);
select app.compute_booking_split(test.id('booking:LTP-OLD'));
select test.eq('0093''s booking: renter $744, listed $675, 20% $135, partner $540, CarmaCars $69 above the listed rental',
  (select format('%s %s %s %s %s', rental_charge_cents, partner_sheet_cents, company_share_cents, owner_payout_cents, partner_markup_cents)
     from booking_splits where booking_id = test.id('booking:LTP-OLD')), '74400 67500 13500 54000 6900');

update program_settings set lead_time_enabled = false;
