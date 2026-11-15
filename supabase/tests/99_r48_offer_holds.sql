-- 99_r48_offer_holds: offers expire in 12 hours and never past 1 hour before pickup; an accepted offer not paid holds the
-- car 2 hours, then the hold ends (2961). Fixtures start with "oh48".
select test.suite('99 r48 offer holds');

select test.mk_user('oh48_cs', 'va', 'cs');
select test.mk_user('oh48_admin', 'admin');
select test.mk_owner('oh48_own');
select test.mk_vehicle('OH48V', 'oh48_own');
select test.mk_vehicle('OH48W', 'oh48_own');
select test.mk_renter('oh48_ren');
update program_settings set offer_expiry_hours = 12, offer_cutoff_before_pickup_minutes = 60, offer_unpaid_hold_minutes = 120;

-- the settings and their defaults
select test.eq('defaults: an offer is open 12 hours',
  (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'offer_expiry_hours'), '12');
select test.eq('defaults: never past 60 minutes before the pickup',
  (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'offer_cutoff_before_pickup_minutes'), '60');
select test.eq('defaults: an accepted unpaid offer holds the car 120 minutes',
  (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'offer_unpaid_hold_minutes'), '120');

-- requests, as staff answer them (Toronto wall clock)
create function pg_temp.req(p_number text, p_vehicle text, p_pickup timestamptz, p_days integer) returns uuid language sql as $$
  select test.mk_booking(p_number, p_vehicle, 'oh48_ren', to_char(p_pickup at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
                         to_char((p_pickup + make_interval(days => p_days)) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'requested') $$;
create function pg_temp.bk(p text) returns bookings language sql as $$ select * from bookings where booking_number = p $$;

select pg_temp.req('OH4801', 'OH48V', date_trunc('hour', now()) + interval '5 days', 2);
select pg_temp.req('OH4802', 'OH48V', date_trunc('minute', now()) + interval '5 hours', 1);
select pg_temp.req('OH4803', 'OH48W', date_trunc('minute', now()) + interval '40 minutes', 1);
-- the fixtures' charge lines come with a paid charge: these renters have paid nothing yet
update payments set status = 'cancelled' where booking_id in (select id from bookings where booking_number like 'OH48%');
select app.send_offer(test.id('booking:OH4801'), test.id('oh48_cs'));
select app.send_offer(test.id('booking:OH4802'), test.id('oh48_cs'));
select app.send_offer(test.id('booking:OH4803'), test.id('oh48_cs'));

select test.ok('offer: open 12 hours when the pickup is days away',
  abs(extract(epoch from (pg_temp.bk('OH4801')).offer_expires_at - (now() + interval '12 hours'))) < 120);
select test.eq('offer: never past 1 hour before the pickup',
  (pg_temp.bk('OH4802')).offer_expires_at, (pg_temp.bk('OH4802')).pickup_at - interval '1 hour');
select test.eq('offer: a pickup within the hour, open until the pickup',
  (pg_temp.bk('OH4803')).offer_expires_at, (pg_temp.bk('OH4803')).pickup_at);
select set_config('request.jwt.claim.sub', test.id('oh48_admin')::text, false);
select test.eq('offer: the calendar shows an open offer as a hold until it expires',
  (select e ->> 'hold_until' from jsonb_array_elements(app.admin_calendar(now(), now() + interval '8 days') -> 'vehicles') v, jsonb_array_elements(v -> 'entries') e
    where e ->> 'booking_number' = 'OH4801')::timestamptz, (pg_temp.bk('OH4801')).offer_expires_at);
select set_config('request.jwt.claim.sub', '', false);
select test.ok('offer: an open offer does not block the car (the first to pay gets it)',
  app.vehicle_is_available(test.id('vehicle:OH48V'), (pg_temp.bk('OH4801')).pickup_at, (pg_temp.bk('OH4801')).return_at, null));

-- accepted, not paid: the car is held, until the hold ends
select app.approve_offer(test.id('booking:OH4801'), 1, test.id('oh48_ren'));
select test.eq('accepted: waiting for payment', (pg_temp.bk('OH4801')).status::text, 'pending_payment');
select test.ok('accepted: the hold ends 2 hours after accepting',
  abs(extract(epoch from app.unpaid_hold_until(pg_temp.bk('OH4801')) - (now() + interval '2 hours'))) < 120);
select test.ok('accepted: the car is held for those dates',
  not app.vehicle_is_available(test.id('vehicle:OH48V'), (pg_temp.bk('OH4801')).pickup_at, (pg_temp.bk('OH4801')).return_at, null));
select set_config('request.jwt.claim.sub', test.id('oh48_admin')::text, false);
select test.eq('accepted: the calendar shows the hold until it ends',
  (select e ->> 'hold_until' from jsonb_array_elements(app.admin_calendar(now(), now() + interval '8 days') -> 'vehicles') v, jsonb_array_elements(v -> 'entries') e
    where e ->> 'booking_number' = 'OH4801')::timestamptz, app.unpaid_hold_until(pg_temp.bk('OH4801')));
select set_config('request.jwt.claim.sub', '', false);
select test.eq('accepted: nothing ends while the hold runs', app.expire_unpaid(now()), 0);

-- the hold ran out (accepted 3 hours ago): the car is free again
update bookings set offer_approved_at = now() - interval '3 hours' where booking_number = 'OH4801';
select test.ok('hold over: the car is no longer held',
  app.vehicle_is_available(test.id('vehicle:OH48V'), (pg_temp.bk('OH4801')).pickup_at, (pg_temp.bk('OH4801')).return_at, null));
select test.ok('hold over: the public calendar shows the days free',
  not exists (select 1 from app.public_vehicle_calendar(test.id('vehicle:OH48V'), app.local_date(now()), app.local_date(now() + interval '10 days')) c
               where c.unavailable_from < (pg_temp.bk('OH4801')).return_at and c.unavailable_to > (pg_temp.bk('OH4801')).pickup_at));
delete from job_runs where job_name = 'offers-expire';
select test.eq('the offers job ends the hold', app.job_offers_expire(now()), 'succeeded');
select test.eq('the job records the holds ended', (select summary ->> 'holds_ended' from job_runs where job_name = 'offers-expire' order by started_at desc limit 1), '1');
select test.eq('still free: a fresh offer at the same price (version 2)',
  (select b.status::text || '/' || b.current_offer_version || '/' || (b.offer_approved_at is null)::text from bookings b where b.booking_number = 'OH4801'), 'offered/2/true');
select test.eq('still free: the same total as the accepted offer',
  (select o2.total_cents = o1.total_cents from booking_offers o1, booking_offers o2
    where o1.booking_id = test.id('booking:OH4801') and o1.version = 1 and o2.booking_id = o1.booking_id and o2.version = 2), true);
select test.ok('still free: the renter is texted the link to pay',
  exists (select 1 from phone_outbox x where x.booking_id = test.id('booking:OH4801') and x.dedupe_key = 'unpaid_reopen:' || test.id('booking:OH4801') || ':v2'
           and x.body like '%pay here to book it%'));
select test.ok('still free: the booking history says why',
  exists (select 1 from booking_events e where e.booking_id = test.id('booking:OH4801') and e.kind = 'reopened' and e.note like 'Not paid within 120 minutes%'));
select test.ok('still free: the fresh offer never passes the cut-off before the pickup',
  (pg_temp.bk('OH4801')).offer_expires_at <= (pg_temp.bk('OH4801')).pickup_at - interval '1 hour');

-- the pickup too close to offer again: the booking expires
select app.approve_offer(test.id('booking:OH4803'), 1, test.id('oh48_ren'));
update bookings set offer_approved_at = now() - interval '3 hours' where booking_number = 'OH4803';
select test.eq('pickup too close: the hold ends and the booking expires', (select app.expire_unpaid(now())), 1);
select test.eq('pickup too close: expired', (pg_temp.bk('OH4803')).status::text, 'expired');
select test.ok('pickup too close: logged with the reason',
  exists (select 1 from booking_events e where e.booking_id = test.id('booking:OH4803') and e.kind = 'offer_expired' and e.to_status = 'expired' and e.note like 'Not paid within%'));
select test.ok('expired: never blocks the car',
  app.vehicle_is_available(test.id('vehicle:OH48W'), (pg_temp.bk('OH4803')).pickup_at, (pg_temp.bk('OH4803')).return_at, null));

-- not touched: a booking with a payment in, an offline payment
select pg_temp.req('OH4804', 'OH48W', date_trunc('hour', now()) + interval '9 days', 2);
update payments set status = 'cancelled' where booking_id = test.id('booking:OH4804');
select app.send_offer(test.id('booking:OH4804'), test.id('oh48_cs'));
select app.approve_offer(test.id('booking:OH4804'), 1, test.id('oh48_ren'));
update bookings set offer_approved_at = now() - interval '3 hours' where booking_number = 'OH4804';
insert into payments (booking_id, purpose, kind, amount_cents, status) values (test.id('booking:OH4804'), 'booking_total', 'charge', 1000, 'succeeded');
select test.eq('paid in: no hold limit', app.unpaid_hold_until(pg_temp.bk('OH4804')), null::timestamptz);
select pg_temp.req('OH4805', 'OH48W', date_trunc('hour', now()) + interval '14 days', 2);
update payments set status = 'cancelled' where booking_id = test.id('booking:OH4805');
select app.send_offer(test.id('booking:OH4805'), test.id('oh48_cs'));
select app.approve_offer(test.id('booking:OH4805'), 1, test.id('oh48_ren'));
update bookings set offer_approved_at = now() - interval '3 hours' where booking_number = 'OH4805';
select test.eq('by card, accepted 3 hours ago: the hold is over', app.unpaid_hold_over(pg_temp.bk('OH4805')), true);
update program_settings set offer_unpaid_hold_minutes = 0;
select test.eq('setting 0: no limit', app.unpaid_hold_until(pg_temp.bk('OH4805')), null::timestamptz);
update program_settings set offer_unpaid_hold_minutes = 120;
select test.eq('only the bookings whose hold ran out are touched', app.expire_unpaid(now()), 1);
select test.eq('the paid one still waits for its signature', (pg_temp.bk('OH4804')).status::text, 'pending_payment');

-- the one-time sweep: an accepted booking whose dates are past and nothing paid expires quietly
select test.mk_booking('OH4806', 'OH48W', 'oh48_ren', '2026-01-10 10:00', '2026-01-12 10:00', 'pending_payment');
update bookings set rental_pay_method = 'e_transfer' where booking_number = 'OH4806';
update payments set status = 'cancelled' where booking_id = test.id('booking:OH4806');
select test.eq('job: an offline payment is not timed', app.expire_unpaid(now()), 0);
select test.eq('sweep: past and never paid, it expires', app.expire_unpaid(now(), true), 1);
select test.ok('sweep: logged in the booking history without telling the renter',
  (pg_temp.bk('OH4806')).status = 'expired'
  and exists (select 1 from booking_events e where e.booking_id = test.id('booking:OH4806') and e.kind = 'adjusted' and e.to_status = 'expired')
  and not exists (select 1 from booking_events e where e.booking_id = test.id('booking:OH4806') and e.kind = 'offer_expired'));
