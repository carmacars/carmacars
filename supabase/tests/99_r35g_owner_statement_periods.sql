-- 99: release 35 part G (migration 1155): owner statement periods cut off on the 7th, and the revenue earned in a period.
-- The $0 statements: a rental counted only once returned or closed, only when every line was paid by card, and a car only
-- with such a rental. Now: the payout on the 10th covers the revenue earned through the 7th; a rental spanning periods is
-- recognised by its rental days inside each, exactly once; insurer-billed and past-trip rentals count; hidden revenue is on
-- the statement; an invoice deducts from payouts only from its "deduct from payouts starting" date. Fixtures start with "osp".
select test.suite('99 r35g owner statement periods');

select test.mk_user('osp_admin', 'admin');
select test.mk_owner('osp_olga');
select test.mk_vehicle('OSP1', 'osp_olga');
select test.mk_vehicle('OSP2', 'osp_olga');
update vehicles set enrollment_date = null where id = test.id('vehicle:OSP2');
select test.mk_renter('osp_r1', false); select test.mk_renter('osp_r2', false); select test.mk_renter('osp_r3', false);
select test.mk_renter('osp_r4', false); select test.mk_renter('osp_r5', false);

-- the period
select test.eq('cutoff: the 7th by default', (app.settings()).statement_cutoff_day, 7);
select test.eq('the October statement (paid November 10) ends November 7', app.statement_period_end(date '2026-10-01'), date '2026-11-07');
select test.eq('its payout stays on the 10th', app.payout_date(date '2026-10-01'), date '2026-11-10');

-- R1: a rental inside the period, closed and paid
select test.mk_booking('OSP-R1', 'OSP1', 'osp_r1', '2026-10-20 10:00', '2026-10-23 10:00', 'closed', 30000);
-- R2: a long-term renter on rent across the cutoff: November 1 to 15 (14 days), 7 of them through November 7
select test.mk_booking('OSP-R2', 'OSP1', 'osp_r2', '2026-11-01 10:00', '2026-11-15 10:00', 'on_rent', 140000);
-- R3: returned, not closed, billed to an insurer (no card payment on its lines), on a car with no enrollment date
select test.mk_booking('OSP-R3', 'OSP2', 'osp_r3', '2026-10-25 10:00', '2026-10-28 10:00', 'returned', 0);
select test.mk_line('OSP-R3', 'rental_charge', 36000, false);
-- R4: after the cutoff: the next statement
select test.mk_booking('OSP-R4', 'OSP1', 'osp_r4', '2026-11-09 10:00', '2026-11-11 10:00', 'closed', 20000);
-- R5: hidden from the owner until the statement: on the statement at its true amounts
select test.mk_booking('OSP-R5', 'OSP1', 'osp_r5', '2026-11-03 10:00', '2026-11-05 10:00', 'closed', 20000);
update bookings set owner_visibility = 'until_statement' where id = test.id('booking:OSP-R5');

-- an invoice deducted from payouts, starting with the December 10 payout
insert into owner_invoices (id, invoice_number, owner_id, vehicle_id, kind, period_month, billing_date, payment_method, status, fees_cents, hst_cents)
values (test.id('inv:osp'), 'OSP-INV-1', test.id('owner:osp_olga'), test.id('vehicle:OSP1'), 'monthly', date '2026-10-01', date '2026-10-15', 'pre_authorized_debit', 'issued', 10000, 1300);
update owner_invoices set collect_by = 'payout', deduct_from_payout_on = date '2026-12-10' where id = test.id('inv:osp');

select app.build_owner_statement(test.id('owner:osp_olga'), date '2026-10-01');
create temp view osp_st as select * from owner_statements where owner_id = test.id('owner:osp_olga') and status <> 'void';
create function pg_temp.line(p_month date, p_booking text) returns owner_statement_lines language sql as $$
  select l.* from owner_statement_lines l join osp_st s on s.id = l.owner_statement_id
   where s.statement_month = p_month and l.line_type = 'rental' and l.booking_id = test.id('booking:' || p_booking) $$;
create function pg_temp.split(p_booking text) returns booking_splits language sql as $$ select * from booking_splits where booking_id = test.id('booking:' || p_booking) $$;

select test.eq('October: the period is the earliest booking through November 7',
  (select period_starts_on || '/' || period_ends_on || '/' || payout_date from osp_st where statement_month = date '2026-10-01'), '2026-10-20/2026-11-07/2026-11-10');
select test.eq('a rental inside the period: in full', (pg_temp.line(date '2026-10-01', 'OSP-R1')).amount_cents, (pg_temp.split('OSP-R1')).owner_payout_cents);
select test.ok('a rental inside the period: not partial', not (pg_temp.line(date '2026-10-01', 'OSP-R1')).partial);
select test.eq('on rent across the cutoff: 7 of its 14 days', (select earned_days || '/' || rental_days || '/' || partial from pg_temp.line(date '2026-10-01', 'OSP-R2')), '7/14/true');
select test.eq('on rent across the cutoff: half its Owner Revenue', (pg_temp.line(date '2026-10-01', 'OSP-R2')).owner_revenue_cents, round((pg_temp.split('OSP-R2')).owner_revenue_cents / 2.0)::bigint);
select test.ok('insurer-billed, returned and not closed, on a car with no enrollment date: counted',
  (pg_temp.line(date '2026-10-01', 'OSP-R3')).amount_cents > 0 and (pg_temp.split('OSP-R3')).uncollected_cents > 0);
select test.ok('after the cutoff: not on this statement', (pg_temp.line(date '2026-10-01', 'OSP-R4')).booking_id is null);
select test.eq('hidden from the owner: on the statement in full', (pg_temp.line(date '2026-10-01', 'OSP-R5')).amount_cents, (pg_temp.split('OSP-R5')).owner_payout_cents);
select test.ok('the statement is not $0', (select payout_cents from osp_st where statement_month = date '2026-10-01') > 0);
select test.ok('the invoice is not deducted before December 10',
  not exists (select 1 from owner_statement_lines l join osp_st s on s.id = l.owner_statement_id where s.statement_month = date '2026-10-01' and l.owner_invoice_id = test.id('inv:osp')));
select test.eq('rebuilt: the same lines (recognised once)',
  (select count(*)::int from owner_statement_lines l join osp_st s on s.id = l.owner_statement_id where s.statement_month = date '2026-10-01' and l.line_type = 'rental'),
  (select count(*)::int from (select app.build_owner_statement(test.id('owner:osp_olga'), date '2026-10-01')) x,
     owner_statement_lines l join osp_st s on s.id = l.owner_statement_id where s.statement_month = date '2026-10-01' and l.line_type = 'rental'));

select app.approve_owner_statement((select id from osp_st where statement_month = date '2026-10-01'), test.id('osp_admin'));
select test.ok('approved: the partial rental is not marked paid out', (pg_temp.split('OSP-R2')).owner_statement_id is null);
select test.ok('approved: the whole rental is', (pg_temp.split('OSP-R1')).owner_statement_id is not null);

-- R2 comes back on November 15 and is closed: the November statement (November 8 to December 7) takes the rest
-- (written straight, as the import path: the check-in forms have suites of their own)
set session_replication_role = replica;
update bookings set status = 'closed', checked_in_at = return_at where id = test.id('booking:OSP-R2');
set session_replication_role = origin;
select app.build_owner_statement(test.id('owner:osp_olga'), date '2026-11-01');
select test.eq('November: the period is November 8 to December 7, paid December 10',
  (select period_starts_on || '/' || period_ends_on || '/' || payout_date from osp_st where statement_month = date '2026-11-01'), '2026-11-08/2026-12-07/2026-12-10');
select test.eq('the rest of the long rental: 7 more days, not partial', (select earned_days || '/' || partial from pg_temp.line(date '2026-11-01', 'OSP-R2')), '7/false');
select test.eq('recognised exactly once: the two lines add up to its payout',
  (pg_temp.line(date '2026-10-01', 'OSP-R2')).amount_cents + (pg_temp.line(date '2026-11-01', 'OSP-R2')).amount_cents, (pg_temp.split('OSP-R2')).owner_payout_cents);
select test.ok('the rental after the cutoff is on November''s', (pg_temp.line(date '2026-11-01', 'OSP-R4')).amount_cents > 0);
select test.ok('a rental already paid out is not on it again', (pg_temp.line(date '2026-11-01', 'OSP-R1')).booking_id is null);
select test.eq('the invoice is deducted from the December 10 payout',
  (select -sum(l.amount_cents) from owner_statement_lines l join osp_st s on s.id = l.owner_statement_id where s.statement_month = date '2026-11-01' and l.owner_invoice_id = test.id('inv:osp')), 11300::bigint);

-- the Admin sets the date on the invoice page
select test.throws('deduct from: Admins only', $$ select public.door(test.id('osp_olga'), 'aal2', 'admin_do', 'owner_invoice_deduct_from', jsonb_build_object('id', 'OSP-INV-1', 'date', '2027-01-10')) $$);
select public.door(test.id('osp_admin'), 'aal2', 'admin_do', 'owner_invoice_deduct_from', jsonb_build_object('id', 'OSP-INV-1', 'date', '2027-01-10'));
select test.eq('deduct from: saved', (select deduct_from_payout_on from owner_invoices where id = test.id('inv:osp')), date '2027-01-10');
select test.eq('deduct from: on the invoice read', public.door(test.id('osp_admin'), 'aal2', 'ops_read', 'owner_invoice_admin', jsonb_build_object('id', 'OSP-INV-1')) ->> 'deduct_from_payout_on', '2027-01-10');
select test.eq('deduct from: logged', (select count(*)::int from audit_log where action = 'owner_invoice_deduct_from' and entity_id = test.id('inv:osp')::text), 1);
select app.build_owner_statement(test.id('owner:osp_olga'), date '2026-11-01');
select test.ok('deduct from January: not on the December 10 payout',
  not exists (select 1 from owner_statement_lines l join osp_st s on s.id = l.owner_statement_id where s.statement_month = date '2026-11-01' and l.owner_invoice_id = test.id('inv:osp')));
