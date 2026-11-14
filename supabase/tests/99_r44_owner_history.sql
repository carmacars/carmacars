-- 99: migration 2830 (release 44): the owner portal's Rental history. Every rental on the owner's cars that they may see,
-- oldest first, with their earnings exactly as their approved statements count them; never a booking hidden from them, a
-- request, a test booking, a cancellation without a kept charge, another owner's car or anything about the renter.
-- Fixtures start with "ohx"; every address is example.test.
select test.suite('99 r44 owner rental history (2830)');

select test.mk_user('ohx_admin', 'admin');
select test.mk_owner('ohx_ann'); select test.mk_owner('ohx_ben');
select test.mk_vehicle('OHX1', 'ohx_ann'); select test.mk_vehicle('OHX2', 'ohx_ann'); select test.mk_vehicle('OHX9', 'ohx_ben');
select test.mk_renter('ohx_r1', false); select test.mk_renter('ohx_r2', false); select test.mk_renter('ohx_r3', false);
select test.mk_renter('ohx_r4', false); select test.mk_renter('ohx_r5', false); select test.mk_renter('ohx_r6', false);
select test.mk_renter('ohx_r7', false); select test.mk_renter('ohx_r8', false);
update renters set legal_name = 'Zed Quillfeather' where id = test.id('renter:ohx_r1');
update renters set email = 'ohx-test@resend.dev' where id = test.id('renter:ohx_r7');

-- R1: an ordinary closed rental on OHX1; R2: one on OHX2 later
select test.mk_booking('OHX-R1', 'OHX1', 'ohx_r1', '2026-10-10 10:00', '2026-10-13 10:00', 'closed', 30000);
select test.mk_booking('OHX-R2', 'OHX2', 'ohx_r2', '2026-10-20 10:00', '2026-10-22 10:00', 'closed', 20000);
-- H1: hidden from the owner ("never" shown)
select test.mk_booking('OHX-H1', 'OHX1', 'ohx_r3', '2026-10-15 10:00', '2026-10-17 10:00', 'closed', 20000);
update bookings set owner_visibility = 'never' where id = test.id('booking:OHX-H1');
-- C1: cancelled, nothing paid
select test.mk_booking('OHX-C1', 'OHX1', 'ohx_r4', '2026-10-24 10:00', '2026-10-27 10:00', 'cancelled', 0, 'standard', null, '2026-10-10 10:00');
select test.mk_line('OHX-C1', 'rental_charge', 40950, false);
insert into booking_cancellations (booking_id, received_at, cancelled_by, reason, channel, total_paid_cents)
values (test.id('booking:OHX-C1'), timestamp '2026-10-20 15:00' at time zone 'America/Toronto', 'renter', 'renter_request', 'email', 0);
-- C3: a no-show paid in full and kept
select test.mk_booking('OHX-C3', 'OHX2', 'ohx_r5', '2026-10-26 10:00', '2026-10-28 10:00', 'no_show', 20000, 'standard', null, '2026-10-10 10:00');
insert into booking_cancellations (booking_id, received_at, cancelled_by, reason, channel, total_paid_cents)
values (test.id('booking:OHX-C3'), timestamp '2026-10-26 12:00' at time zone 'America/Toronto', 'carmacars', 'no_show', 'system', 22600);
-- U1: confirmed for later; Q1: a request never confirmed; T1: a test renter's booking
select test.mk_booking('OHX-U1', 'OHX1', 'ohx_r6', '2027-01-10 10:00', '2027-01-12 10:00', 'confirmed', 20000);
select test.mk_booking('OHX-Q1', 'OHX1', 'ohx_r8', '2027-02-10 10:00', '2027-02-12 10:00', 'requested', 20000);
select test.mk_booking('OHX-T1', 'OHX2', 'ohx_r7', '2026-10-05 10:00', '2026-10-07 10:00', 'closed', 20000);
-- B1: another owner's car
select test.mk_booking('OHX-B1', 'OHX9', 'ohx_r2', '2026-10-01 10:00', '2026-10-03 10:00', 'closed', 20000);

create function pg_temp.h(p_car text default null, p_newest boolean default false, p_offset integer default 0, p_limit integer default 50) returns jsonb
language sql as $$ select public.owner_portal_rental_history(test.id('ohx_ann'), case when p_car is null then null else test.id('vehicle:' || p_car) end, p_newest, p_offset, p_limit) $$;
create function pg_temp.nums(j jsonb) returns text language sql as $$ select string_agg(e ->> 'booking_number', ',' order by o) from jsonb_array_elements(j -> 'rows') with ordinality x(e, o) $$;
create function pg_temp.row_of(j jsonb, p_number text) returns jsonb language sql as $$ select e from jsonb_array_elements(j -> 'rows') e where e ->> 'booking_number' = p_number $$;

-- before any statement: the rentals, not yet on a statement
select test.eq('oldest first: the rentals the owner may see, nothing else (no hidden, request, test, unpaid cancellation or other owner''s booking)',
  pg_temp.nums(pg_temp.h()), 'OHX-R1,OHX-R2,OHX-U1');
select test.ok('before a statement: not yet on a statement', (pg_temp.row_of(pg_temp.h(), 'OHX-R1') -> 'earned_cents') = 'null'::jsonb
  and (pg_temp.h() ->> 'not_on_statement')::integer = 3);

select app.build_owner_statement(test.id('owner:ohx_ann'), date '2026-10-01');
create temp view ohx_st as select * from owner_statements where owner_id = test.id('owner:ohx_ann') and status <> 'void';
select test.eq('a draft statement is not counted: the kept no-show is listed, not yet on a statement',
  pg_temp.nums(pg_temp.h()), 'OHX-R1,OHX-R2,OHX-C3,OHX-U1');
select test.ok('the kept no-show reads as cancelled with a charge kept, amount pending',
  pg_temp.row_of(pg_temp.h(), 'OHX-C3') ->> 'state' = 'cancelled_kept' and (pg_temp.row_of(pg_temp.h(), 'OHX-C3') -> 'earned_cents') = 'null'::jsonb);
select app.approve_owner_statement((select id from ohx_st where statement_month = date '2026-10-01'), test.id('ohx_admin'));

create function pg_temp.line_cents(p_number text) returns bigint language sql as $$
  select sum(l.amount_cents)::bigint from owner_statement_lines l join ohx_st s on s.id = l.owner_statement_id
   where l.line_type = 'rental' and l.booking_id = test.id('booking:' || p_number) and s.status::text not in ('void', 'draft') $$;

select test.ok('the approved statement has a line for R1', pg_temp.line_cents('OHX-R1') > 0);
select test.eq('revenue matches the statement figure (R1)', (pg_temp.row_of(pg_temp.h(), 'OHX-R1') ->> 'earned_cents')::bigint, pg_temp.line_cents('OHX-R1'));
select test.eq('revenue matches the statement figure (the kept no-show)', (pg_temp.row_of(pg_temp.h(), 'OHX-C3') ->> 'earned_cents')::bigint, pg_temp.line_cents('OHX-C3'));
select test.eq('the total is the sum of the statement lines',
  (pg_temp.h() ->> 'earned_cents')::bigint, pg_temp.line_cents('OHX-R1') + pg_temp.line_cents('OHX-R2') + pg_temp.line_cents('OHX-C3'));
select test.ok('hidden booking absent', pg_temp.row_of(pg_temp.h(), 'OHX-H1') is null and pg_temp.h()::text not like '%' || test.id('booking:OHX-H1')::text || '%');
select test.ok('cancelled without a kept charge absent', pg_temp.row_of(pg_temp.h(), 'OHX-C1') is null);
select test.ok('another owner''s car never listed, nor in the car filter',
  pg_temp.row_of(pg_temp.h(), 'OHX-B1') is null and pg_temp.h()::text not like '%' || test.id('vehicle:OHX9')::text || '%'
  and jsonb_array_length(pg_temp.h() -> 'cars') = 2);
select test.ok('asking for another owner''s car gives nothing', (pg_temp.h('OHX9') ->> 'count')::integer = 0);
select test.ok('the other owner sees their own booking only',
  (select string_agg(e ->> 'booking_number', ',') from jsonb_array_elements(public.owner_portal_rental_history(test.id('ohx_ben')) -> 'rows') e) = 'OHX-B1');

select test.eq('statuses in plain states', (select string_agg(e ->> 'state', ',' order by o) from jsonb_array_elements(pg_temp.h() -> 'rows') with ordinality x(e, o)),
  'completed,completed,cancelled_kept,upcoming');
select test.eq('newest first', pg_temp.nums(pg_temp.h(null, true)), 'OHX-U1,OHX-C3,OHX-R2,OHX-R1');
select test.eq('one car', pg_temp.nums(pg_temp.h('OHX2')), 'OHX-R2,OHX-C3');
select test.ok('paged: the count is the whole list, the rows one page',
  pg_temp.nums(pg_temp.h(null, false, 1, 2)) = 'OHX-R2,OHX-C3' and (pg_temp.h(null, false, 1, 2) ->> 'count')::integer = 4);
select test.eq('the days', (pg_temp.row_of(pg_temp.h(), 'OHX-R1') ->> 'days')::integer, 3);
select test.ok('nothing about the renter, payments, deposit or insurer',
  pg_temp.h()::text not like '%Quillfeather%' and pg_temp.h()::text not like '%example.test%' and pg_temp.h()::text not like '%647-555%'
  and pg_temp.h()::text !~* '(renter|deposit|payment|insurer|claim|adjuster|licence|note)');
select test.ok('the owner''s own booking of their car is not a rental', not exists (
  select 1 from jsonb_array_elements(pg_temp.h() -> 'rows') e join bookings b on b.id = (e ->> 'booking_id')::uuid where b.booking_type::text = 'owner'));
select test.ok('server only', not has_function_privilege('authenticated', 'public.owner_portal_rental_history(uuid, uuid, boolean, integer, integer)', 'execute')
  and not has_function_privilege('anon', 'public.owner_portal_rental_history(uuid, uuid, boolean, integer, integer)', 'execute')
  and not has_function_privilege('authenticated', 'app.owner_rental_history(uuid, uuid, boolean, integer, integer)', 'execute')
  and has_function_privilege('service_role', 'public.owner_portal_rental_history(uuid, uuid, boolean, integer, integer)', 'execute'));
