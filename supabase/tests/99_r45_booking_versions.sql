-- 99: migration 2861 (release 45): "Restore this version" on a confirmed booking. A 7 day booking changed to 4 days,
-- then 3, then 7 again (repriced), and a fee changed: every change is a version with its fee lines; a preview shows the
-- difference and changes nothing; the restore puts back the dates, the car, the rental charge and the fee lines exactly,
-- as one logged edit with the reason; the checks of an edit hold (who, the car free); payments are never touched.
-- Fixtures "rvz"; example.test only.
select test.suite('99 r45 booking versions (2861)');

select test.mk_user('rvz_admin', 'admin');
select test.mk_user('rvz_sales', 'va', 'sales');
select test.mk_user('rvz_fleet', 'va', 'fleet');
select test.mk_owner('rvz_o');
select test.mk_vehicle('RVZA', 'rvz_o');
select test.mk_renter('rvz_r');
select test.mk_renter('rvz_q');
update program_settings set staff_may_edit_bookings = true, staff_may_edit_fees = true;

select test.mk_booking('CC-RVZ1', 'RVZA', 'rvz_r', to_char(now() at time zone 'America/Toronto' + interval '20 days', 'YYYY-MM-DD 10:00'),
  to_char(now() at time zone 'America/Toronto' + interval '27 days', 'YYYY-MM-DD 10:00'), 'confirmed', 56000);
-- a fee set for this booking (a young driver fee, as typed when the rental was entered)
select app.booking_line_overrides_store(test.id('booking:CC-RVZ1'), test.id('rvz_admin'), '{"young_driver_21_25": 5000}'::jsonb, 'Set when the rental was entered');
select app.sync_booking_price(test.id('booking:CC-RVZ1'));
create temp table rvz0 as select b.pickup_at, b.return_at, b.rental_charge_cents, b.total_due_at_booking_cents total, app.booking_fee_lines(b.id) lines,
  (select count(*) from payments p where p.booking_id = b.id) pays, (select coalesce(sum(amount_cents), 0) from payments p where p.booking_id = b.id) paid
  from bookings b where b.id = test.id('booking:CC-RVZ1');
grant select on rvz0 to public;

create function pg_temp.edit(p_days integer) returns jsonb language sql as $$
  select app.door(test.id('rvz_admin'), 'aal2', 'ops_do', 'booking_staff_edit', jsonb_build_object('booking', 'CC-RVZ1',
    'changes', jsonb_build_object('return_at', (select pickup_at + make_interval(days => p_days) from bookings where id = test.id('booking:CC-RVZ1'))), 'reason', 'Renter asked')) $$;
create function pg_temp.vers(p_user text default 'rvz_admin') returns jsonb language sql as $$
  select app.door(test.id(p_user), 'aal2', 'ops_read', 'booking_versions', jsonb_build_object('booking', 'CC-RVZ1', '_va', case when p_user = 'rvz_admin' then null else replace(p_user, 'rvz_', '') end)) $$;
create function pg_temp.restore(p_version integer, p_preview boolean, p_user text default 'rvz_admin', p_reason text default 'Back as agreed') returns jsonb language sql as $$
  select app.door(test.id(p_user), 'aal2', 'ops_do', 'booking_version_restore', jsonb_build_object('booking', 'CC-RVZ1', 'version', p_version, 'preview', p_preview,
    'reason', p_reason, '_va', case when p_user = 'rvz_admin' then null else replace(p_user, 'rvz_', '') end)) $$;

select test.eq('no change yet: no versions', jsonb_array_length(pg_temp.vers() -> 'versions'), 0);
select pg_temp.edit(4);
select pg_temp.edit(3);
select pg_temp.edit(7);
select app.door(test.id('rvz_admin'), 'aal2', 'ops_do', 'booking_fees_change', jsonb_build_object('booking', 'CC-RVZ1', 'lines', jsonb_build_object('young_driver_21_25', 9000), 'reason', 'Driver is 24'));

select test.eq('version 1 (before the first change) and one after each change, the fee change too', jsonb_array_length(pg_temp.vers() -> 'versions'), 5);
select test.eq('version 1 is the booking as confirmed: 7 days, its rental charge, its fee lines',
  (select (v ->> 'billable_days') || '|' || (v ->> 'rental_charge_cents') || '|' || (v -> 'lines' ->> 'young_driver_21_25') from jsonb_array_elements(pg_temp.vers() -> 'versions') v where (v ->> 'no')::int = 1),
  (select '7|' || rental_charge_cents || '|' || (lines ->> 'young_driver_21_25') from rvz0));
select test.ok('the newest is the current one, the others are not', (select bool_and((v ->> 'current')::boolean = ((v ->> 'no')::int = 5)) from jsonb_array_elements(pg_temp.vers() -> 'versions') v));
select test.eq('each change says who and why', (select v ->> 'reason' from jsonb_array_elements(pg_temp.vers() -> 'versions') v where (v ->> 'no')::int = 5), 'Driver is 24');
select test.ok('the live case: back at 7 days but priced differently from the first 7 days, with the dearer fee',
  (select total_due_at_booking_cents from bookings where id = test.id('booking:CC-RVZ1')) <> (select total from rvz0));

-- the preview: the difference, nothing changed
create temp table rvz_pre as select pg_temp.restore(1, true) j;
select test.ok('the preview works out the version''s total', (select (j ->> 'ok')::boolean and (j ->> 'total_after_cents')::bigint = (select total from rvz0) from rvz_pre));
select test.ok('the preview shows the balance before and after', (select j ? 'open_before_cents' and j ? 'open_after_cents' from rvz_pre));
select test.ok('the preview changed nothing', (select count(*) from booking_staff_edits where booking_id = test.id('booking:CC-RVZ1')) = 4
  and (select app.booking_fee_lines(id) ->> 'young_driver_21_25' from bookings where id = test.id('booking:CC-RVZ1')) = '9000');

-- the checks of an edit
select test.throws('a reason is needed', $$ select pg_temp.restore(1, false, 'rvz_admin', '') $$, 'reason');
select test.throws('Fleet does not change bookings', $$ select pg_temp.restore(1, false, 'rvz_fleet') $$, 'Only an Admin');
select test.throws('a version not in the history', $$ select pg_temp.restore(9, false) $$, 'not in this booking');

-- restored
select pg_temp.restore(1, false, 'rvz_sales');
select test.eq('the dates, the rental charge and the fee lines are the version''s exactly',
  (select b.pickup_at = r.pickup_at and b.return_at = r.return_at and b.rental_charge_cents = r.rental_charge_cents and app.booking_fee_lines(b.id) = r.lines
     from bookings b, rvz0 r where b.id = test.id('booking:CC-RVZ1'))::text, 'true');
select test.eq('so is the total', (select total_due_at_booking_cents from bookings where id = test.id('booking:CC-RVZ1')), (select total from rvz0));
select test.eq('it is one more change, by Sales, with the reason and the version', (select e.restored_version || '|' || e.reason from booking_staff_edits e
   where e.booking_id = test.id('booking:CC-RVZ1') order by e.seq desc limit 1), '1|Restored version 1: Back as agreed');
select test.eq('and a version of its own', (select v ->> 'kind' from jsonb_array_elements(pg_temp.vers() -> 'versions') v where (v ->> 'current')::boolean), 'restore');
select test.ok('the booking''s history has it', exists (select 1 from booking_events e where e.booking_id = test.id('booking:CC-RVZ1') and e.note like '%Restored version 1%'));
select test.ok('payments are never touched', (select count(*) = r.pays and coalesce(sum(p.amount_cents), 0) = r.paid from payments p, rvz0 r where p.booking_id = test.id('booking:CC-RVZ1') group by r.pays, r.paid)
  or (select pays = 0 from rvz0));
select test.eq('restoring the version it is already in changes nothing', (pg_temp.restore(6, false) ->> 'changed'), 'false');

-- the car must be free: another booking takes the 4 day version's last days back... the 7 day ones
select pg_temp.edit(4);
select test.mk_booking('CC-RVZ2', 'RVZA', 'rvz_q', to_char((select pickup_at + interval '5 days' from bookings where id = test.id('booking:CC-RVZ1')) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
  to_char((select pickup_at + interval '6 days' from bookings where id = test.id('booking:CC-RVZ1')) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'confirmed', 10000);
select test.ok('the preview says the car is booked', (select (j ->> 'ok')::boolean = false and j ->> 'problem' like '%CC-RVZ2%' from (select pg_temp.restore(1, true) j) x));
select test.throws('and the restore is refused', $$ select pg_temp.restore(1, false) $$, 'CC-RVZ2');
