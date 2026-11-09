-- 99: an extension costs the booking's all-in price a day (migration 1201): the total charged for the booked period
-- (rental after discounts, every fee, one-time fees included, HST) over its days, times the added days; hours under a
-- day at the hourly rule, never more than a day; no discount; one line, HST included, with the booking's HST share;
-- staff edits that make a live booking longer reach the same total. Fixtures "hz"; example.test only.
select test.suite('99 r35h extension all-in');

select test.mk_user('hz_admin', 'admin');
select test.mk_owner('hz_o');
select test.mk_vehicle('HZA', 'hz_o');
select test.mk_vehicle('HZB', 'hz_o');
select test.mk_renter('hz_r');
-- an extension discount set in Program settings is not applied any more
update program_settings set extension_discount_bps = 500, extension_short_discount_bps = 1000 where id = (app.settings()).id;

-- a 4-day booking: $400 rental, a $60 Protection Plan for the trip, $50 delivery (one-time), HST on each
select test.mk_booking('CC-HZ1', 'HZA', 'hz_r', to_char(now() at time zone 'America/Toronto' + interval '10 days', 'YYYY-MM-DD 10:00'),
  to_char(now() at time zone 'America/Toronto' + interval '14 days', 'YYYY-MM-DD 10:00'), 'confirmed', 40000);
update booking_line_items set payment_id = null where booking_id = test.id('booking:CC-HZ1');
select test.mk_line('CC-HZ1', 'coverage_sold', 6000, false);
select test.mk_line('CC-HZ1', 'delivery', 5000, false);
create temp table hz as select sum(amount_cents + hst_cents)::bigint as total, sum(hst_cents)::bigint as hst
  from booking_line_items where booking_id = test.id('booking:CC-HZ1') and stage = 'booking' and voided_at is null and charged_to_renter;
grant select on hz to public;
create or replace function test.hz_prev(p_number text, p_span interval) returns jsonb language sql stable as $$
  select app.preview_extension(b.id, b.return_at + p_span) from bookings b where b.booking_number = p_number $$;

select test.eq('the booked period''s all-in price: the lines with HST, 4 days, the price a day',
  (select (a ->> 'total_cents') || '/' || (a ->> 'days') || '/' || (a ->> 'per_day_cents') from app.booking_all_in(test.id('booking:CC-HZ1')) a),
  (select total || '/4/' || round(total / 4.0) from hz));
select test.eq('1 day: the all-in price a day, one line', (select (v ->> 'total_cents') || '/' || jsonb_array_length(v -> 'lines') from test.hz_prev('CC-HZ1', interval '1 day') v),
  (select round(total / 4.0) || '/1' from hz));
select test.eq('3 days: 3 x the all-in price a day', (test.hz_prev('CC-HZ1', interval '3 days') ->> 'total_cents')::bigint, (select round(total * 3 / 4.0)::bigint from hz));
select test.eq('10 days: 10 x the all-in price a day (one-time delivery averaged in)', (test.hz_prev('CC-HZ1', interval '10 days') ->> 'total_cents')::bigint, (select round(total * 10 / 4.0)::bigint from hz));
select test.ok('the price grows with the length (1 to 20 days)',
  not exists (select 1 from generate_series(2, 20) n where (test.hz_prev('CC-HZ1', make_interval(days => n)) ->> 'total_cents')::bigint
                                                        < (test.hz_prev('CC-HZ1', make_interval(days => n - 1)) ->> 'total_cents')::bigint));
select test.eq('the line says it: "Extension: 3 days at $X/day (all-in)"', test.hz_prev('CC-HZ1', interval '3 days') -> 'lines' -> 0 ->> 'description',
  (select 'Extension: 3 days at ' || app.fmt_money(round(total / 4.0)) || '/day (all-in)' from hz));
select test.eq('its HST is the booked period''s share, so amount and HST add up to the all-in price (never HST on top)',
  (select ((l ->> 'amount_cents')::bigint + (l ->> 'hst_cents')::bigint) || '/' || (l ->> 'hst_cents') from jsonb_array_elements(test.hz_prev('CC-HZ1', interval '3 days') -> 'lines') l),
  (select round(total * 3 / 4.0) || '/' || round(round(total * 3 / 4.0) * hst::numeric / total) from hz));
select test.eq('no discount and no saving shown', (select (v ->> 'discount_bps') || '/' || (v ->> 'save_cents') || '/' || ((v ->> 'regular_total_cents') = (v ->> 'total_cents')) from test.hz_prev('CC-HZ1', interval '1 day') v), '0/0/true');
select test.eq('the price a day is given for the screen', (test.hz_prev('CC-HZ1', interval '2 days') ->> 'per_day_cents')::bigint, (select round(total / 4.0)::bigint from hz));
select test.eq('the six offers carry it too', (app.extension_offers(test.id('booking:CC-HZ1')) ->> 'per_day_cents')::bigint, (select round(total / 4.0)::bigint from hz));

-- hours: the hourly late fee with HST, never more than a day
select test.eq('2 hours: the hourly late fee for 2 hours with HST (under a day)',
  (test.hz_prev('CC-HZ1', interval '2 hours') ->> 'total_cents')::bigint,
  least(2 * app.late_fee_hourly_cents(test.id('booking:CC-HZ1')) + public.calc_hst(2 * app.late_fee_hourly_cents(test.id('booking:CC-HZ1'))), (select round(total / 4.0)::bigint from hz)));
select test.eq('2 hours: priced as hours (no 10% off any more)', test.hz_prev('CC-HZ1', interval '2 hours') ->> 'pricing', 'short');
select test.eq('20 hours: never more than one all-in day', (test.hz_prev('CC-HZ1', interval '20 hours') ->> 'total_cents')::bigint, (select round(total / 4.0)::bigint from hz));
select test.eq('1 day and 2 hours: a day plus the hours, never more than two days',
  (test.hz_prev('CC-HZ1', interval '26 hours') ->> 'total_cents')::bigint,
  (select round(total / 4.0)::bigint + least(2 * app.late_fee_hourly_cents(test.id('booking:CC-HZ1')) + public.calc_hst(2 * app.late_fee_hourly_cents(test.id('booking:CC-HZ1'))), round(total / 4.0)::bigint) from hz));

-- asked, approved and paid: one stored line, the rental grows by its amount before tax
select app.request_extension(test.id('booking:CC-HZ1'), test.id('hz_admin'), (select return_at + interval '3 days' from bookings where booking_number = 'CC-HZ1'));
select app.approve_extension((select id from booking_extensions where booking_id = test.id('booking:CC-HZ1') and status in ('requested', 'approved') limit 1), test.id('hz_admin'))
 where exists (select 1 from booking_extensions where booking_id = test.id('booking:CC-HZ1') and status = 'requested');
create temp table hz_before as select rental_charge_cents r from bookings where id = test.id('booking:CC-HZ1');
grant select on hz_before to public;
select test.eq('paid: confirmed',
  (select r ->> 'ok' from bookings b, app.confirm_extension_payment((select id from booking_extensions where booking_id = b.id and status = 'approved'),
     '{"processor": "stripe", "payment_id": "pi_test_hz1"}'::jsonb, (select total_cents from booking_extensions where booking_id = b.id and status = 'approved'), now(), test.id('hz_admin')) r
    where b.booking_number = 'CC-HZ1'), 'true');
select test.eq('one extension line, its amount and HST adding up to what was paid',
  (select count(*) || '/' || (sum(amount_cents + hst_cents) = (select total_cents from booking_extensions where booking_id = test.id('booking:CC-HZ1') and status = 'confirmed'))
     from booking_line_items where booking_id = test.id('booking:CC-HZ1') and stage = 'extension' and voided_at is null), '1/true');
select test.eq('the booking''s rental charge grows by the line''s amount before tax',
  (select rental_charge_cents - (select r from hz_before) from bookings where id = test.id('booking:CC-HZ1')),
  (select amount_cents from booking_line_items where booking_id = test.id('booking:CC-HZ1') and stage = 'extension' and voided_at is null));
select test.eq('a second extension keeps the booked period''s price a day (the extension is not counted twice)',
  (test.hz_prev('CC-HZ1', interval '1 day') ->> 'per_day_cents')::bigint, (select round(total / 4.0)::bigint from hz));

-- staff: Edit on the booking makes it 4 days longer: the booking's total becomes 2 x the all-in 4 days
select test.mk_booking('CC-HZ2', 'HZB', 'hz_r', to_char(now() at time zone 'America/Toronto' + interval '30 days', 'YYYY-MM-DD 10:00'),
  to_char(now() at time zone 'America/Toronto' + interval '34 days', 'YYYY-MM-DD 10:00'), 'confirmed', 40000);
update bookings set request_details = '{}'::jsonb, coverage_option = 3, coverage_confirmed_at = now() where id = test.id('booking:CC-HZ2');
insert into booking_fee_terms (booking_id, fee_type_code, amount_cents, source, override_by, override_reason) values (test.id('booking:CC-HZ2'), 'coverage_sold', 6000, 'booking', test.id('hz_admin'), 'Priced on the offer');
select app.sync_booking_price(test.id('booking:CC-HZ2'));
create temp table hz2 as select total_due_at_booking_cents t from bookings where id = test.id('booking:CC-HZ2');
grant select on hz2 to public;
select public.door(test.id('hz_admin'), null, 'ops_do', 'booking_staff_edit', jsonb_build_object('booking', 'CC-HZ2', 'changes', jsonb_build_object('return_at',
  (select return_at + interval '4 days' from bookings where booking_number = 'CC-HZ2'))));
select test.eq('staff Edit: 4 days more cost the all-in 4 days again (the total doubles)',
  (select total_due_at_booking_cents from bookings where id = test.id('booking:CC-HZ2')), (select 2 * t from hz2));
select test.eq('staff Edit: the per-trip Protection Plan stays as booked (the price a day carries it)',
  (select sum(amount_cents) from booking_line_items where booking_id = test.id('booking:CC-HZ2') and charge_type = 'coverage_sold' and voided_at is null), 6000::bigint);

-- an insurer-billed booking keeps its pricing
select test.mk_vehicle('HZD', 'hz_o');
select test.mk_booking('CC-HZ4', 'HZD', 'hz_r', to_char(now() at time zone 'America/Toronto' + interval '70 days', 'YYYY-MM-DD 10:00'),
  to_char(now() at time zone 'America/Toronto' + interval '73 days', 'YYYY-MM-DD 10:00'), 'confirmed', 30000);
insert into insurers (id, name, billing_email) values (test.id('insurer:hz'), 'Example Insurance HZ', 'claims-hz@example.test');
update bookings set bill_to = 'insurer', insurer_id = test.id('insurer:hz'), insurer_claim_number = 'CLM-HZ-1' where booking_number = 'CC-HZ4';
select test.eq('insurer-billed: priced as before (regular)', test.hz_prev('CC-HZ4', interval '1 day') ->> 'pricing', 'regular');

update program_settings set extension_discount_bps = 0, extension_short_discount_bps = 0 where id = (app.settings()).id;
