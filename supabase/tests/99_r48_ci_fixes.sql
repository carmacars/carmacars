-- 99: Propose a change prices a change as it lands (migration 3050; docs/changes/2026-11-15-r48-ci-fixes.md): a later
-- return costs the booking's all-in price a day; a typed total is met to the cent; the preview changes nothing; accepting
-- lands on the total agreed. Fixtures start with "x50"; addresses are example.test.
select test.suite('99 r48 ci fixes');
select test.mk_user('x50_admin', 'admin');
select test.mk_owner('x50_o');
select test.mk_vehicle('X50A', 'x50_o');
select test.mk_renter('x50_r');
-- a 1-day booking: $220 rental and a $60 Protection Plan, HST on each
select test.mk_booking('CC-X501', 'X50A', 'x50_r', to_char(now() at time zone 'America/Toronto' + interval '10 days', 'YYYY-MM-DD 10:00'),
  to_char(now() at time zone 'America/Toronto' + interval '11 days', 'YYYY-MM-DD 10:00'), 'confirmed', 22000);
select test.mk_line('CC-X501', 'coverage_sold', 6000, false);
select app.sync_booking_price(test.id('booking:CC-X501'));
create temp table x50 as select total_due_at_booking_cents t, return_at r from bookings where booking_number = 'CC-X501';
grant select on x50 to public;
create function test.x50_prev(p jsonb) returns jsonb language sql as $$
  select app.preview_booking_change(test.id('booking:CC-X501'), p) $$;

select test.eq('the price a day is the booked total over its day', (test.x50_prev(jsonb_build_object('return_at', (select r + interval '1 day' from x50))) ->> 'per_day_cents')::bigint,
  (select t from x50));
select test.eq('one more day: exactly twice the 1-day total, priced at the all-in day',
  (select (v -> 'after' ->> 'total_cents') || '/' || (v ->> 'total_difference_cents') || '/' || (v ->> 'pricing') from test.x50_prev(jsonb_build_object('return_at', (select r + interval '1 day' from x50))) v),
  (select (2 * t) || '/' || t || '/all_in_day' from x50));
select test.eq('two more days: three times', (test.x50_prev(jsonb_build_object('return_at', (select r + interval '2 days' from x50))) -> 'after' ->> 'total_cents')::bigint,
  (select 3 * t from x50));
select test.eq('a typed total is met to the cent', (select (v -> 'after' ->> 'total_cents') || '/' || (v ->> 'pricing') from test.x50_prev(jsonb_build_object('return_at', (select r + interval '1 day' from x50), 'total_cents', 70000)) v),
  '70000/typed_total');
select test.eq('the preview changes nothing', (select total_due_at_booking_cents || '/' || (return_at = (select r from x50)) from bookings where booking_number = 'CC-X501'),
  (select t || '/true' from x50));
select test.ok('a typed rental charge is kept as typed', (test.x50_prev(jsonb_build_object('return_at', (select r + interval '1 day' from x50), 'rental_charge_cents', 30000)) -> 'after' ->> 'rental_charge_cents')::bigint = 30000);

-- proposed, accepted and applied: the booking lands on the total the renter agreed to
select app.propose_booking_change(test.id('x50_admin'), jsonb_build_object('booking', 'CC-X501', 'return_at', (select r + interval '1 day' from x50), 'note', 'One more day, as asked.'));
select test.eq('the proposal carries the all-in difference', (select total_difference_cents from booking_change_requests where booking_id = test.id('booking:CC-X501') order by created_at desc limit 1),
  (select t from x50));
update booking_change_requests set status = 'approved', renter_agreed_at = now() where booking_id = test.id('booking:CC-X501') and status = 'proposed';
select app.apply_booking_change((select id from booking_change_requests where booking_id = test.id('booking:CC-X501') order by created_at desc limit 1),
  test.id('x50_admin'), jsonb_build_object('payment_id', 'pi_x50'), (select t from x50));
select test.eq('applied: the booking is the agreed total, 2 days', (select total_due_at_booking_cents || '/' || billable_days from bookings where booking_number = 'CC-X501'),
  (select (2 * t) || '/2' from x50));
