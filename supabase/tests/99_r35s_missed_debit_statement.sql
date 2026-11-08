-- 99: a missed owner debit is recovered from the next revenue statement by itself (migration 0871,
-- docs/changes/2026-11-08-r35-missed-debit-statement.md). Fixtures "r35d". September 2026 (in the past): a closed rental
-- makes revenue; three September invoices were debited: one returned for a closed account (not retried), one returned for
-- insufficient funds with its retry still waiting, one being debited right now.
select test.suite('99 r35s missed debit recovered from the next statement');
select test.mk_user('r35d_admin', 'admin');
select test.mk_owner('r35d_o');
select test.mk_vehicle('R35DA', 'r35d_o', 'managed', 45000, 2500, 3500, date '2026-08-01');
select test.mk_renter('r35d_r');
select test.mk_booking('R35D-1', 'R35DA', 'r35d_r', '2026-09-05 10:00', '2026-09-09 10:00', 'closed', 60000);
select app.compute_booking_split(test.id('booking:R35D-1'));
select test.eq('the owner is on the bank debit (the default, unchanged)', (select fees_paid_from from owners where id = test.id('owner:r35d_o')), 'debit');

insert into owner_invoices (id, owner_id, vehicle_id, kind, period_month, billing_date, status, fees_cents, hst_cents, title)
values (test.id('inv:r35d:closed'), test.id('owner:r35d_o'), test.id('vehicle:R35DA'), 'adjustment', null, date '2026-09-15', 'issued', 4000, 520, 'Closed account'),
       (test.id('inv:r35d:nsf'), test.id('owner:r35d_o'), test.id('vehicle:R35DA'), 'adjustment', null, date '2026-09-15', 'issued', 3000, 390, 'Insufficient funds'),
       (test.id('inv:r35d:busy'), test.id('owner:r35d_o'), test.id('vehicle:R35DA'), 'adjustment', null, date '2026-09-15', 'issued', 2000, 260, 'Being debited');
update owner_invoices set status = 'processing' where id in (test.id('inv:r35d:closed'), test.id('inv:r35d:nsf'), test.id('inv:r35d:busy'));
insert into owner_debit_attempts (id, owner_invoice_id, owner_id, attempt_no, debit_on, amount_cents, status, idempotency_key)
select test.id('att:r35d:' || k), test.id('inv:r35d:' || k), test.id('owner:r35d_o'), 1, case when k = 'nsf' then app.today() - 1 else date '2026-09-15' end, i.total_cents, 'processing', 'r35d-' || k
  from unnest(array['closed', 'nsf', 'busy']) k join owner_invoices i on i.id = test.id('inv:r35d:' || k);

select app.owner_debit_fail(test.id('att:r35d:closed'), 'account_closed', 'The account is closed.');
select app.owner_debit_fail(test.id('att:r35d:nsf'), 'insufficient_funds', 'Insufficient funds.');
select test.eq('before: the closed account is failed and paused (no retry), the other waits for its retry',
  (select string_agg(title || '=' || status || '/' || auto_debit_paused, ',' order by title) from owner_invoices where owner_id = test.id('owner:r35d_o')),
  'Being debited=processing/false,Closed account=failed/true,Insufficient funds=failed/false');
select test.eq('the retry is scheduled', (select count(*) from owner_debit_attempts where owner_invoice_id = test.id('inv:r35d:nsf') and status = 'scheduled'), 1::bigint);

-- the statements-draft job builds the September statement: nobody touches the invoices
create table test.r35d_st as select app.build_owner_statement(test.id('owner:r35d_o'), date '2026-09-01') as id;
select test.eq('the missed debits are in arrears; the one being debited is left alone',
  (select string_agg(title || '=' || status, ',' order by title) from owner_invoices where owner_id = test.id('owner:r35d_o')),
  'Being debited=processing,Closed account=in_arrears,Insufficient funds=in_arrears');
select test.eq('the waiting retry is cancelled, with the reason', (select string_agg(status || ':' || skip_reason, ',') from owner_debit_attempts where owner_invoice_id = test.id('inv:r35d:nsf') and attempt_no = 2),
  'canceled:recovered from the revenue statement');
select test.eq('the statement takes both from the payout (with the Late Fee of the insufficient funds)',
  (select count(*) || '/' || (-sum(amount_cents) = (select sum(balance_cents) from owner_invoices where id in (test.id('inv:r35d:closed'), test.id('inv:r35d:nsf'))))
     from owner_statement_lines where owner_statement_id = (select id from test.r35d_st) and owner_invoice_id in (test.id('inv:r35d:closed'), test.id('inv:r35d:nsf'))),
  '2/true');
select test.eq('the one being debited is not on the statement',
  (select count(*) from owner_statement_lines where owner_statement_id = (select id from test.r35d_st) and owner_invoice_id = test.id('inv:r35d:busy')), 0::bigint);
select test.eq('audited', (select count(*) from audit_log where action = 'owner_missed_debit_to_statement' and entity_id in (test.id('inv:r35d:closed')::text, test.id('inv:r35d:nsf')::text)), 2::bigint);
select app.approve_owner_statement((select id from test.r35d_st), test.id('r35d_admin'));
select test.eq('approved: both deducted from the payout', (select string_agg(status, ',' order by title) from owner_invoices where id in (test.id('inv:r35d:closed'), test.id('inv:r35d:nsf'))), 'deducted,deducted');
select test.eq('built again: nothing more to move', app.owner_missed_debits_to_statement(test.id('owner:r35d_o')), 0);
select test.ok('privileges: the service role only', has_function_privilege('service_role', 'app.owner_missed_debits_to_statement(uuid)', 'execute')
  and not has_function_privilege('authenticated', 'app.owner_missed_debits_to_statement(uuid)', 'execute'));
