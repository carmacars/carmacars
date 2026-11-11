-- 99: renter extension offers, the late fee of 0480 and the 90 minute buffer between trips
-- (docs/changes/2026-11-07-extend-offers.md). Fixtures start with "ex" and use example.test only. Every time is set
-- relative to the clock (the functions take the time), so nothing depends on when the suite runs.
select test.suite('99 extend offers');
update program_settings set extension_auto_approve = true, extension_discount_bps = 500, extension_short_discount_bps = 1000, max_rental_days = 365,
       late_fee_hourly_bps = 1750, late_fee_hourly_min_cents = 2500, booking_buffer_minutes = 90 where id = (app.settings()).id;

select test.mk_user('ex_admin', 'admin');
select test.mk_owner('ex_olive');
select test.mk_renter('ex_rita');
select test.mk_renter('ex_ivan');
select test.mk_renter('ex_lena');
select test.mk_vehicle('ex_a', 'ex_olive');
select test.mk_vehicle('ex_b', 'ex_olive');
select test.mk_vehicle('ex_c', 'ex_olive');
select test.mk_vehicle('ex_d', 'ex_olive');
select test.mk_vehicle('ex_e', 'ex_olive');
select test.mk_vehicle('ex_f', 'ex_olive');
select test.mk_vehicle('ex_g', 'ex_olive');
select test.mk_vehicle('ex_h', 'ex_olive');
insert into insurers (id, name, billing_email) values (test.id('insurer:ex'), 'Example Insurance EX', 'claims-ex@example.test');

-- a Toronto wall-clock string some time from now, for test.mk_booking
create or replace function test.ext(p_shift interval) returns text language sql stable as $$
  select to_char((now() + p_shift) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI')
$$;
-- the booking's stored rates: one daily rate every day (no weekend rate), so the day of the week never matters
create or replace function test.ex_rates(p_number text, p_daily bigint, p_weekly bigint default null, p_monthly bigint default null) returns void
language plpgsql as $$
begin
  -- a fixture written straight in: the rate lock of a confirmed booking (booking_before_write) is passed over
  perform set_config('session_replication_role', 'replica', true);
  update bookings set daily_rate_cents = p_daily, weekend_rate_cents = p_daily, weekly_rate_cents = coalesce(p_weekly, p_daily * 7),
         monthly_rate_cents = coalesce(p_monthly, p_daily * 30), multi_day_rate_cents = null where booking_number = p_number;
  perform set_config('session_replication_role', 'origin', true);
end $$;
create or replace function test.ex_opt(p_number text, p_code text, p_key text) returns text language sql stable as $$
  select o ->> p_key from jsonb_array_elements(app.extension_offers(test.id('booking:' || p_number)) -> 'options') o where o ->> 'code' = p_code
$$;

-- ================================================================ 1. the late fee
-- an old booking (its term frozen as it was given: $25 flat) and two new ones
select test.mk_booking('EX-OLD', 'ex_a', 'ex_rita', test.ext('-2 days'), test.ext('2 days'), 'confirmed');
select test.ex_rates('EX-OLD', 85000);
select set_config('app.late_fee_freeze', 'on', false);
insert into booking_fee_terms (booking_id, fee_type_code, amount_cents, cap_cents, percent_bps, source)
values (test.id('booking:EX-OLD'), 'late_return_fee', 2500, null, 15000, 'default');
select set_config('app.late_fee_freeze', 'off', false);
select test.mk_booking('EX-850', 'ex_b', 'ex_rita', test.ext('-2 days'), test.ext('5 hours'), 'on_rent');
select test.ex_rates('EX-850', 85000, 400000, 1500000);
select test.mk_booking('EX-80', 'ex_c', 'ex_ivan', test.ext('-2 days'), test.ext('5 hours'), 'on_rent');
select test.ex_rates('EX-80', 8000);

select test.eq('late fee: 17.5% of a $850 daily rate is $148.75 an hour', app.late_fee_hourly_cents(test.id('booking:EX-850')), 14875::bigint);
select test.eq('late fee: at least $25 an hour ($80 daily rate)', app.late_fee_hourly_cents(test.id('booking:EX-80')), 2500::bigint);
select test.eq('late fee: an existing booking keeps its flat $25 (daily rate $850)', app.late_fee_hourly_cents(test.id('booking:EX-OLD')), 2500::bigint);
-- confirming a new booking freezes the new policy into its terms: the rate, and the minimum
select test.mk_vehicle('ex_n', 'ex_olive');
select test.mk_booking('EX-NEW', 'ex_n', 'ex_lena', test.ext('3 days'), test.ext('6 days'), 'pending_payment');
select test.ex_rates('EX-NEW', 85000);
select app.snapshot_booking_fee_terms(test.id('booking:EX-NEW'));
select test.eq('late fee: a new booking''s term records 17.5% and the $25 minimum',
  (select rate_bps || '/' || amount_cents || '/' || source from booking_fee_terms where booking_id = test.id('booking:EX-NEW') and fee_type_code = 'late_return_fee'),
  '1750/2500/default');
select test.eq('late fee: the check-in charge uses it (3 hours late at $850: 3 x $148.75)',
  (select l.late_fee_cents from app.booking_fee_term(test.id('booking:EX-NEW'), 'late_return_fee') t,
          public.calc_late_return(180, 85000, t.amount_cents, t.percent_bps, t.grace_minutes) l), 44625::bigint);
select test.eq('late fee: grace 30 minutes and the 1.5 x daily cap per 24 hours unchanged',
  (select t.grace_minutes || '/' || t.percent_bps from app.booking_fee_term(test.id('booking:EX-NEW'), 'late_return_fee') t), '30/15000');
-- a fee set by hand for one booking stays flat
update booking_fee_terms set source = 'booking', amount_cents = 4000, override_by = test.id('ex_admin'), override_reason = 'Agreed with the renter'
 where booking_id = test.id('booking:EX-NEW') and fee_type_code = 'late_return_fee';
select test.eq('late fee: a fee set by hand is flat', app.late_fee_hourly_cents(test.id('booking:EX-NEW')), 4000::bigint);
-- the freeze of 0480: a booking with no term yet gets its terms as they were (flat)
select test.mk_booking('EX-FRZ', 'ex_h', 'ex_lena', test.ext('8 days'), test.ext('9 days'), 'requested');
select test.ex_rates('EX-FRZ', 85000);
begin;
select app.freeze_late_fee_terms() > 0 as froze \gset ex_
select app.late_fee_hourly_cents(test.id('booking:EX-FRZ')) as frozen_fee,
       (select rate_bps is null from booking_fee_terms where booking_id = test.id('booking:EX-FRZ') and fee_type_code = 'late_return_fee') as flat \gset ex_
rollback;
select test.eq('late fee: the migration''s freeze keeps an existing booking at $25 flat', :'ex_froze' || '/' || :'ex_frozen_fee' || '/' || :'ex_flat', 't/2500/t');

-- ================================================================ 4. the six options
-- the booked rate a day: the stored rental charge over its days (a weekend day in the period makes it higher; the weekday of the run never matters)
create or replace function test.ex_booked(p_number text) returns numeric language sql stable as $$ select rental_charge_cents::numeric / billable_days from bookings where booking_number = p_number $$;
select test.eq('offers: the six options, in order',
  (select string_agg(o ->> 'code', ' ' order by n) from jsonb_array_elements(app.extension_offers(test.id('booking:EX-850')) -> 'options') with ordinality x(o, n)),
  '1h 3h 1d 3d 1w 1m');
select test.eq('1 hour at $850: $148.75 less 10% (rental before HST)',
  (app.preview_extension(test.id('booking:EX-850'), (select return_at + interval '1 hour' from bookings where booking_number = 'EX-850')) ->> 'rental_difference_cents')::bigint, 13387::bigint);
select test.eq('3 hours at $850: 3 x $148.75 less 10%',
  (app.preview_extension(test.id('booking:EX-850'), (select return_at + interval '3 hours' from bookings where booking_number = 'EX-850')) ->> 'rental_difference_cents')::bigint, 40162::bigint);
-- 1066: whole days at the same rate as the booked period ($320 for 3 days); this file sets the offer's discount to 5% (the default is 0%)
select test.eq('1 day: the booked rate less 5%', (app.preview_extension(test.id('booking:EX-850'), (select return_at + interval '1 day' from bookings where booking_number = 'EX-850')) ->> 'rental_difference_cents')::bigint, round(round(test.ex_booked('EX-850') * 1) * 0.95)::bigint);
select test.eq('3 days: 3 x the booked rate less 5%', (app.preview_extension(test.id('booking:EX-850'), (select return_at + interval '3 days' from bookings where booking_number = 'EX-850')) ->> 'rental_difference_cents')::bigint, round(round(test.ex_booked('EX-850') * 3) * 0.95)::bigint);
select test.eq('1 week: 7 x the booked rate less 5%', (app.preview_extension(test.id('booking:EX-850'), (select return_at + interval '7 days' from bookings where booking_number = 'EX-850')) ->> 'rental_difference_cents')::bigint, round(round(test.ex_booked('EX-850') * 7) * 0.95)::bigint);
select test.eq('1 month: 30 x the booked rate less 5%', (app.preview_extension(test.id('booking:EX-850'), (select return_at + interval '30 days' from bookings where booking_number = 'EX-850')) ->> 'rental_difference_cents')::bigint, round(round(test.ex_booked('EX-850') * 30) * 0.95)::bigint);
select test.eq('an option''s price is its rental and HST, with the regular price beside it and 5% saved (1 day)',
  test.ex_opt('EX-850', '1d', 'total_cents') || '/' || test.ex_opt('EX-850', '1d', 'regular_total_cents') || '/' || test.ex_opt('EX-850', '1d', 'save_pct'),
  (round(round(test.ex_booked('EX-850') * 1) * 0.95)::bigint + public.calc_hst(round(round(test.ex_booked('EX-850') * 1) * 0.95)::bigint)) || '/' || (round(test.ex_booked('EX-850'))::bigint + public.calc_hst(round(test.ex_booked('EX-850'))::bigint)) || '/5');
select test.eq('1 hour: what being an hour late would cost instead (the hourly fee, with HST; 1063: no extra day under a day)',
  test.ex_opt('EX-850', '1h', 'late_cost_cents'), (14875 + public.calc_hst(14875))::text);
select test.eq('1 hour: you save 10%', test.ex_opt('EX-850', '1h', 'save_pct'), '10');
select test.eq('lead-time pricing never applies to an extension',
  (select count(*) from jsonb_array_elements(app.preview_extension(test.id('booking:EX-850'), (select return_at + interval '3 days' from bookings where booking_number = 'EX-850')) -> 'lines') l
    where l ->> 'charge_type' = 'lead_time'), 0::bigint);
-- $60 a day: 3 hours at $25 less 10% ($67.50) is more than a day less 5% ($57): the day is offered instead
select test.mk_booking('EX-60', 'ex_d', 'ex_ivan', test.ext('-1 day'), test.ext('6 hours'), 'on_rent');
select test.ex_rates('EX-60', 6000);
select test.eq('short or a day: 1 hour stays hours ($22.50), 3 hours fall back to the 1 day option',
  test.ex_opt('EX-60', '1h', 'pricing') || '/' || (app.preview_extension(test.id('booking:EX-60'), (select return_at + interval '1 hour' from bookings where booking_number = 'EX-60')) ->> 'rental_difference_cents')
    || '/' || test.ex_opt('EX-60', '3h', 'fallback_to'), 'short/2250/1d');
select test.eq('short or a day: 3 hours are priced as a day ($60 less 5%)',
  (app.preview_extension(test.id('booking:EX-60'), (select return_at + interval '3 hours' from bookings where booking_number = 'EX-60')) ->> 'rental_difference_cents')::bigint, 5700::bigint);
select test.eq('$80 a day: 3 hours at $25 less 10% is $67.50, under a day ($76): hours',
  (app.preview_extension(test.id('booking:EX-80'), (select return_at + interval '3 hours' from bookings where booking_number = 'EX-80')) ->> 'rental_difference_cents')::bigint, 6750::bigint);

-- ================================================================ insurer, owner, a car switched off
select test.mk_booking('EX-INS', 'ex_e', 'ex_lena', test.ext('-1 day'), test.ext('6 hours'), 'on_rent');
update bookings set bill_to = 'insurer', insurer_id = test.id('insurer:ex'), insurer_claim_number = 'CLM-EX-1' where booking_number = 'EX-INS';
select test.eq('insurer-billed: no offers, a reason, the request path stays',
  (select (x ->> 'offers') || '/' || jsonb_array_length(x -> 'options') || '/' || (x ->> 'message' like '%insurer%') from app.extension_offers(test.id('booking:EX-INS')) x), 'false/0/true');
select test.eq('insurer-billed: priced as before 0480, with no discount',
  (app.preview_extension(test.id('booking:EX-INS'), (select return_at + interval '1 day' from bookings where booking_number = 'EX-INS')) ->> 'pricing'), 'regular');
update vehicles set extension_offers = false where id = test.id('vehicle:ex_d');
select test.eq('a car switched off: no offers', (app.extension_offers(test.id('booking:EX-60')) ->> 'offers'), 'false');
update vehicles set extension_offers = true where id = test.id('vehicle:ex_d');

-- ================================================================ 2. after the return time, while the car is out
select test.mk_booking('EX-LATE', 'ex_f', 'ex_rita', test.ext('-2 days'), test.ext('-50 minutes'), 'on_rent');
select test.ex_rates('EX-LATE', 85000);
select test.eq('late and still out: extendable, priced from the original return (3 hours = 3 x $148.75 less 10%)',
  (select (p ->> 'ok') || '/' || (p ->> 'rental_difference_cents') from app.preview_extension(test.id('booking:EX-LATE'),
     (select return_at + interval '3 hours' from bookings where booking_number = 'EX-LATE')) p), 'true/40162');
select test.eq('late and still out: the late charges so far are shown (50 minutes: 1 hour, no extra day under a day, 1063)',
  (app.extension_offers(test.id('booking:EX-LATE')) -> 'late' ->> 'owed_cents')::bigint, 14875::bigint);
select test.eq('late: the 1 hour option ends in the past (10 minutes from now is fine, 50 minutes ago is not)',
  test.ex_opt('EX-LATE', '1h', 'available') || '/' || coalesce(test.ex_opt('EX-LATE', '1h', 'reason'), ''), 'true/');
select test.mk_booking('EX-BACK', 'ex_g', 'ex_ivan', test.ext('-3 days'), test.ext('-2 hours'), 'returned');
select test.eq('returned: too late', (select (p ->> 'ok') || '/' || (p -> 'problems' -> 0 ->> 'code')
  from app.preview_extension(test.id('booking:EX-BACK'), now() + interval '1 day') p), 'false/not_extendable');
select test.mk_vehicle('ex_k', 'ex_olive');
select test.mk_booking('EX-KEYS', 'ex_k', 'ex_ivan', test.ext('-3 days'), test.ext('-2 hours'), 'confirmed');
select set_config('session_replication_role', 'replica', false);
update bookings set checked_in_at = now() - interval '1 hour' where booking_number = 'EX-KEYS';
select set_config('session_replication_role', 'origin', false);
select test.ok('confirmed with a return recorded: too late',
  exists (select 1 from jsonb_array_elements(app.preview_extension(test.id('booking:EX-KEYS'), now() + interval '1 day') -> 'problems') x where x ->> 'code' = 'too_late'));

-- ================================================================ 3. approved at once, or a request
select test.eq('self-serve: the 3 hour option is approved at once (car free, licence valid, card on file)',
  (select (r ->> 'status') || '/' || (r ->> 'auto_approved') || '/' || (r ->> 'option_code') from app.request_extension_option(test.id('booking:EX-LATE'), test.id('ex_rita'), '3h') r),
  'approved/true/3h');
select test.eq('self-serve: no task for customer service', (select count(*) from tasks where task_type = 'review_extension' and booking_id = test.id('booking:EX-LATE')), 0::bigint);
-- paid after the return time while the car is out: the return moves and the late charges for the old time are gone
select test.eq('paid after the return time while out: confirmed, the return moves to 3 hours after the original',
  (select (r ->> 'ok') || '/' || ((r ->> 'return_at')::timestamptz = b.original_return_at + interval '3 hours')
     from bookings b, app.confirm_extension_payment((select id from booking_extensions where booking_id = b.id and status = 'approved'),
            '{"processor": "stripe", "payment_id": "pi_test_ex_late"}'::jsonb,
            (select total_cents from booking_extensions where booking_id = b.id and status = 'approved'), now(), test.id('ex_rita')) r
    where b.booking_number = 'EX-LATE'), 'true/true');
select test.eq('paid: no longer late', (app.extension_offers(test.id('booking:EX-LATE')) ->> 'late'), null::text);

-- licence expiring before the new return: a request for customer service
update drivers set licence_expiry = (now() at time zone 'America/Toronto')::date + 1 where id = test.id('driver:ex_ivan');
select test.eq('licence expiring: requested',
  (select r ->> 'status' from app.request_extension_option(test.id('booking:EX-80'), test.id('ex_ivan'), '3d') r), 'requested');
select test.eq('licence expiring: a task for customer service', (select count(*) from tasks where task_type = 'review_extension' and booking_id = test.id('booking:EX-80')), 1::bigint);
update drivers set licence_expiry = date '2030-01-01' where id = test.id('driver:ex_ivan');
-- self-serve approval off
update program_settings set extension_auto_approve = false where id = (app.settings()).id;
select test.eq('self-serve approval off: requested',
  (select r ->> 'status' from app.request_extension_option(test.id('booking:EX-850'), test.id('ex_rita'), '1d') r), 'requested');
update program_settings set extension_auto_approve = true where id = (app.settings()).id;
-- staff approve keeps the offer's price
select test.eq('staff approval keeps the offer price',
  (select (v ->> 'pricing') || '/' || (v ->> 'rental_difference_cents') from app.approve_extension(
     (select id from booking_extensions where booking_id = test.id('booking:EX-850') and status = 'requested'), test.id('ex_admin')) v), 'days/' || round(round(test.ex_booked('EX-850') * 1) * 0.95)::bigint);
-- an insurer booking's request is never approved at once
select app.request_extension(test.id('booking:EX-INS'), test.id('ex_lena'), (select return_at + interval '1 day' from bookings where booking_number = 'EX-INS'));
select test.eq('insurer-billed: a request for staff', (select status from booking_extensions where booking_id = test.id('booking:EX-INS')), 'requested');
-- an unpaid balance with no card on file
select test.mk_booking('EX-BAL', 'ex_g', 'ex_lena', test.ext('1 day'), test.ext('3 days'), 'confirmed');
update bookings set card_on_file_id = null where booking_number = 'EX-BAL';
select test.eq('nothing unpaid and no card on file: approved at once',
  app.extension_auto_refusal(test.id('booking:EX-BAL'), app.preview_extension(test.id('booking:EX-BAL'), (select return_at + interval '1 day' from bookings where booking_number = 'EX-BAL'))), null::text);
select test.mk_line('EX-BAL', 'rental_charge', 5000, false);
select test.eq('an unpaid balance and no card on file: a request for staff',
  app.extension_auto_refusal(test.id('booking:EX-BAL'), app.preview_extension(test.id('booking:EX-BAL'), (select return_at + interval '1 day' from bookings where booking_number = 'EX-BAL'))),
  'An unpaid balance and no card on file');
update bookings set card_on_file_id = test.id('card:ex_lena') where booking_number = 'EX-BAL';
select test.eq('an unpaid balance with a card on file: approved at once',
  app.extension_auto_refusal(test.id('booking:EX-BAL'), app.preview_extension(test.id('booking:EX-BAL'), (select return_at + interval '1 day' from bookings where booking_number = 'EX-BAL'))), null::text);

-- ================================================================ 5 and 6. the buffer, the reasons
-- a booking 90 minutes or less after this one's return
select test.mk_booking('EX-B1', 'ex_h', 'ex_rita', test.ext('-1 day'), test.ext('1 day'), 'on_rent');
select test.ex_rates('EX-B1', 10000);
select test.mk_booking('EX-B2', 'ex_h', 'ex_ivan', test.ext('3 days'), test.ext('5 days'), 'confirmed');
update bookings set blocks_calendar = true where booking_number in ('EX-B1', 'EX-B2');
select test.eq('reasons: 1 week clashes with the next booking ("Booked from ..."), 1 day is free',
  test.ex_opt('EX-B1', '1w', 'available') || '/' || (test.ex_opt('EX-B1', '1w', 'reason') like 'Booked from %') || '/' || test.ex_opt('EX-B1', '1d', 'available'),
  'false/true/true');
select test.eq('reasons: available until 90 minutes before the next pickup',
  ((app.extension_offers(test.id('booking:EX-B1')) ->> 'available_until')::timestamptz = (select pickup_at - interval '90 minutes' from bookings where booking_number = 'EX-B2'))::text
  || '/' || (app.extension_offers(test.id('booking:EX-B1')) ->> 'available_until_text' like 'Available until %'), 'true/true');
insert into vehicle_calendar_blocks (vehicle_id, reason, starts_at, ends_at, note, source)
values (test.id('vehicle:ex_c'), 'service', now() + interval '1 day', now() + interval '2 days', 'Oil change', 'staff');
select test.eq('reasons: a service block', test.ex_opt('EX-80', '1w', 'reason'), 'Blocked for maintenance');

-- the buffer, both ways: a trip may end 90 minutes before the next one starts and start 90 minutes after one ends
select test.eq('buffer: before the next pickup, 89 minutes is taken, 90 and 91 are free',
  (select string_agg(app.vehicle_is_available(test.id('vehicle:ex_h'), b.pickup_at - interval '1 day', b.pickup_at - make_interval(mins => m))::text, '/' order by m)
     from bookings b, unnest(array[89, 90, 91]) m where b.booking_number = 'EX-B2'), 'false/true/true');
select test.eq('buffer: after a return, 89 minutes is taken, 90 and 91 are free',
  (select string_agg(app.vehicle_is_available(test.id('vehicle:ex_h'), b.return_at + make_interval(mins => m), b.return_at + interval '1 day' + make_interval(mins => m))::text, '/' order by m)
     from bookings b, unnest(array[89, 90, 91]) m where b.booking_number = 'EX-B2'), 'false/true/true');
select test.eq('buffer: the turnaround setting follows booking_buffer_minutes', (select turnaround_buffer_minutes from program_settings where id = (app.settings()).id), 90);
update program_settings set turnaround_buffer_minutes = 75 where id = (app.settings()).id;
select test.eq('buffer: either setting changes the one buffer', (select booking_buffer_minutes from program_settings where id = (app.settings()).id), 75);
-- a new dated row: the one given sets the other (both default to 90)
insert into program_settings (effective_from, turnaround_buffer_minutes) values (date '2099-01-01', 100);
insert into program_settings (effective_from, booking_buffer_minutes) values (date '2099-01-02', 80);
insert into program_settings (effective_from) values (date '2099-01-03');
select test.eq('buffer: a new dated row takes the buffer it was given, either name, else 90',
  (select string_agg(booking_buffer_minutes || '=' || turnaround_buffer_minutes, ' ' order by effective_from) from program_settings where effective_from >= date '2099-01-01'),
  '100=100 80=80 90=90');
delete from program_settings where effective_from >= date '2099-01-01';
update program_settings set booking_buffer_minutes = 90 where id = (app.settings()).id;
-- an existing booking closer than the buffer is not changed, the calendar rings it
select test.mk_booking('EX-B3', 'ex_h', 'ex_lena', test.ext('5 days 1 hour'), test.ext('6 days'), 'confirmed');
update bookings set blocks_calendar = true where booking_number = 'EX-B3';
delete from vehicle_calendar_blocks where vehicle_id = test.id('vehicle:ex_h') and source = 'turnaround';
select set_config('request.jwt.claim.sub', test.id('ex_admin')::text, false);
select test.eq('clash ring: a booking 60 minutes after another rings, both stay as they were',
  (select string_agg(e ->> 'booking_number' || ':' || (e -> 'clash')::text, ' ' order by e ->> 'booking_number')
     from jsonb_array_elements(app.admin_calendar(now(), now() + interval '8 days', test.id('vehicle:ex_h')) -> 'vehicles') v, jsonb_array_elements(v -> 'entries') e
    where e ->> 'booking_number' in ('EX-B2', 'EX-B3')), 'EX-B2:["EX-B3"] EX-B3:["EX-B2"]');
select set_config('request.jwt.claim.sub', '', false);

-- ================================================================ 2. the end-of-booking messages after a paid extension
-- at fixed Toronto hours of today: back at noon, T13 at 12:20, paid at 12:30, nothing more for the old time
create or replace function test.ex_at(p_hhmm text, p_shift interval default '0'::interval) returns timestamptz language sql stable as $$
  select (((now() at time zone 'America/Toronto')::date + p_hhmm::time) at time zone 'America/Toronto') + p_shift
$$;
create or replace function test.ex_events(p_code text) returns bigint language sql stable as $$
  select count(*) from app_events where code = p_code and entity = 'booking' and entity_id = test.id('booking:EX-T13')
$$;
select test.mk_vehicle('ex_t', 'ex_olive');
select test.mk_booking('EX-T13', 'ex_t', 'ex_rita', to_char(test.ex_at('12:00', '-2 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
                       to_char(test.ex_at('12:00') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'on_rent');
select app.notify_reminders(test.ex_at('12:20'));
select test.eq('T13 goes for the old return time', test.ex_events('renter_late_return_first'), 1::bigint);
select set_config('app.ex_ext', app.request_extension(test.id('booking:EX-T13'), test.id('ex_rita'), test.ex_at('12:00', '1 day'))::text, false);
select test.eq('paid at 12:30 (late, still out): confirmed',
  (app.confirm_extension_payment(current_setting('app.ex_ext')::uuid, '{"processor": "stripe", "payment_id": "pi_test_ex_t13"}'::jsonb,
     (select total_cents from booking_extensions where id = current_setting('app.ex_ext')::uuid), test.ex_at('12:30'), test.id('ex_rita')) ->> 'ok'), 'true');
select app.notify_reminders(test.ex_at('14:30'));
select test.eq('after payment: no T14 and no second T13 for the old time', test.ex_events('renter_late_return_final') || '/' || test.ex_events('renter_late_return_first'), '0/1');
select app.notify_reminders(test.ex_at('10:00', '1 day'));
select test.eq('after payment: the reminder of the new return goes (3 hours before it)', test.ex_events('renter_return_soon'), 1::bigint);
select test.ok('the reminder carries the offer line ("Extend at 5% off: from $... for 1 more day" or the plain line)',
  app.extension_offer_line(test.id('booking:EX-T13'), test.ex_at('10:00', '1 day')) ~ '^(Extend at 5% off: from \$[0-9,.]+ for 1 more day|Need more time\? Extend)$');
select test.eq('the offer line of an extendable booking', app.extension_offer_line(test.id('booking:EX-850')) ~ '^Extend at 5% off: from \$[0-9,.]+ for 1 more day$', true);
select test.eq('the plain line of an insurer-billed booking', app.extension_offer_line(test.id('booking:EX-INS')), 'Need more time? Extend');
-- an approved extension not paid lapses once the car is back
select test.mk_vehicle('ex_l', 'ex_olive');
select test.mk_booking('EX-LAPSE', 'ex_l', 'ex_lena', test.ext('-2 days'), test.ext('-30 minutes'), 'on_rent');
update bookings set bill_to = 'renter' where booking_number = 'EX-LAPSE';
insert into booking_extensions (booking_id, seq, status, previous_return_at, new_return_at, previous_days, new_days,
    previous_rental_charge_cents, new_rental_charge_cents, rental_difference_cents, total_cents, approved_at, auto_approved)
select b.id, 1, 'approved', b.return_at, b.return_at + interval '1 day', b.billable_days, b.billable_days + 1, b.rental_charge_cents, b.rental_charge_cents + 9500, 9500, 10735, now(), true
  from bookings b where b.booking_number = 'EX-LAPSE';
select app.lapse_extensions(now());
select test.eq('an approved extension stays open while the car is out', (select status from booking_extensions where booking_id = test.id('booking:EX-LAPSE')), 'approved');
select set_config('session_replication_role', 'replica', false);
update bookings set status = 'returned', checked_in_at = now() where booking_number = 'EX-LAPSE';
select set_config('session_replication_role', 'origin', false);
select app.lapse_extensions(now());
select test.ok('back without paying: it lapsed or was declined', (select status from booking_extensions where booking_id = test.id('booking:EX-LAPSE')) in ('lapsed', 'declined'));

-- ================================================================ 7. no card on file: the pay link (0482)
select test.mk_vehicle('ex_p', 'ex_olive');
select test.mk_booking('EX-LINK', 'ex_p', 'ex_ivan', test.ext('-1 day'), test.ext('5 hours'), 'on_rent');
update bookings set bill_to = 'renter', card_on_file_id = null where booking_number = 'EX-LINK';
select test.ex_rates('EX-LINK', 10000);
select test.eq('pay link: no card on file, approved at once',
  (select r ->> 'status' from app.request_extension_option(test.id('booking:EX-LINK'), test.id('ex_ivan'), '1d') r), 'approved');
select set_config('app.ex_link_ext', (select id::text from booking_extensions where booking_id = test.id('booking:EX-LINK') and status = 'approved'), false);
select set_config('app.ex_link', (public.renter_extension_payreq(current_setting('app.ex_link_ext')::uuid, test.id('ex_ivan'), encode(sha256('ex-link-a'::bytea), 'hex')) ->> 'id'), false);
select test.eq('pay link: a charge for exactly the extension''s price',
  (select q.kind || '/' || q.covers || '/' || (q.amount_cents = e.total_cents)::text from payment_requests q join booking_extensions e on e.id = q.extension_id where q.id = current_setting('app.ex_link')::uuid),
  'charge/extension/true');
select test.throws('pay link: only the booking''s renter',
  format('select public.renter_extension_payreq(%L, %L, %L)', current_setting('app.ex_link_ext'), test.id('ex_rita'), encode(sha256('ex-link-b'::bytea), 'hex')));
-- a second link replaces the first
select set_config('app.ex_link', (public.renter_extension_payreq(current_setting('app.ex_link_ext')::uuid, test.id('ex_ivan'), encode(sha256('ex-link-c'::bytea), 'hex')) ->> 'id'), false);
select test.eq('pay link: a new link closes the earlier one',
  (select count(*) from payment_requests where extension_id = current_setting('app.ex_link_ext')::uuid and status = 'open'), 1::bigint);
update payment_requests set processor_intent_id = 'pi_test_ex_link' where id = current_setting('app.ex_link')::uuid;
-- a wrong amount cannot confirm it: refunded
select test.eq('pay link: an amount that is not the price is refunded',
  (public.server_payreq_settle(current_setting('app.ex_link')::uuid, jsonb_build_object('id', 'pi_test_ex_link', 'status', 'succeeded', 'charge_id', 'ch_test_ex_link',
     'amount', (select total_cents + 1 from booking_extensions where id = current_setting('app.ex_link_ext')::uuid))) ->> 'refund'), 'true');
select set_config('app.ex_link', (public.renter_extension_payreq(current_setting('app.ex_link_ext')::uuid, test.id('ex_ivan'), encode(sha256('ex-link-d'::bytea), 'hex')) ->> 'id'), false);
update payment_requests set processor_intent_id = 'pi_test_ex_link2' where id = current_setting('app.ex_link')::uuid;
select test.eq('pay link: paid, the extension is confirmed',
  (public.server_payreq_settle(current_setting('app.ex_link')::uuid, jsonb_build_object('id', 'pi_test_ex_link2', 'status', 'succeeded', 'charge_id', 'ch_test_ex_link2',
     'amount', (select total_cents from booking_extensions where id = current_setting('app.ex_link_ext')::uuid))) ->> 'ok'), 'true');
select test.eq('pay link: the return moved a day and the link is paid',
  (select (b.return_at = e.new_return_at)::text || '/' || e.status || '/' || q.status from bookings b join booking_extensions e on e.booking_id = b.id
     join payment_requests q on q.extension_id = e.id and q.id = current_setting('app.ex_link')::uuid where b.booking_number = 'EX-LINK'),
  'true/confirmed/paid');
select test.eq('pay link: a repeat of the same payment changes nothing',
  (public.server_payreq_settle(current_setting('app.ex_link')::uuid, jsonb_build_object('id', 'pi_test_ex_link2', 'status', 'succeeded', 'amount', 1)) ->> 'repeat'), 'true');
select test.throws('pay link: a confirmed extension has nothing to pay',
  format('select public.renter_extension_payreq(%L, %L, %L)', current_setting('app.ex_link_ext'), test.id('ex_ivan'), encode(sha256('ex-link-e'::bytea), 'hex')));
