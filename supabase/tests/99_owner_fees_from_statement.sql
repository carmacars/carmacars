-- 99: owner fees taken from the revenue statement (migration 0204, docs/changes/2026-10-31-owner-fees-from-statement.md). Fixtures "fs".
-- September 2026 (in the past): a closed rental makes revenue; the September invoice is taken from the September statement.
select test.suite('99 owner fees from statement');
select test.mk_user('fs_admin', 'admin');
select test.mk_owner('fs_o');
select test.mk_owner('fs_p');
select test.mk_vehicle('FSA', 'fs_o', 'managed', 45000, 2500, 3500, date '2026-08-01');
select test.mk_vehicle('FSP', 'fs_p', 'managed', 45000, 2500, 3500, date '2026-08-01');
select test.mk_renter('fs_r');
select test.mk_booking('FS-1', 'FSA', 'fs_r', '2026-09-05 10:00', '2026-09-08 10:00', 'closed', 30000);
select app.compute_booking_split(test.id('booking:FS-1'));

select test.throws('only an Admin sets how fees are paid', $$select app.door(test.id('fs_o'), 'aal2', 'ops_do', 'owner_fees_paid_from', jsonb_build_object('owner', test.id('owner:fs_o'), 'fees_paid_from', 'statement'))$$, null);
select test.eq('Bank debit by default', app.door(test.id('fs_admin'), 'aal2', 'ops_read', 'owner_fees_paid_from', jsonb_build_object('owner', test.id('owner:fs_o'))) ->> 'fees_paid_from', 'debit');
select test.lives('an Admin chooses Take from revenue statement',
  $$select app.door(test.id('fs_admin'), 'aal2', 'ops_do', 'owner_fees_paid_from', jsonb_build_object('owner', test.id('owner:fs_o'), 'fees_paid_from', 'statement'))$$);
insert into owner_invoices (id, owner_id, vehicle_id, kind, period_month, billing_date, status, fees_cents, hst_cents)
values (test.id('inv:fs:aug'), test.id('owner:fs_o'), test.id('vehicle:FSA'), 'monthly', date '2026-09-01', date '2026-09-15', 'issued', 4000, 520),
       (test.id('inv:fs:big'), test.id('owner:fs_o'), test.id('vehicle:FSA'), 'adjustment', null, date '2026-09-20', 'issued', 50000, 0),
       (test.id('inv:fs:up'), test.id('owner:fs_o'), test.id('vehicle:FSA'), 'upfront', null, date '2026-09-01', 'issued', 1000, 0),
       (test.id('inv:fs:p'), test.id('owner:fs_p'), test.id('vehicle:FSP'), 'monthly', date '2026-09-01', date '2026-09-15', 'issued', 4000, 520);
select test.eq('the owner''s monthly and adjustment invoices are from the statement; the upfront one and another owner''s are not',
  (select string_agg(right(invoice_number, 0) || from_statement::text, ',' order by billing_date, fees_cents) from owner_invoices where id in (test.id('inv:fs:aug'), test.id('inv:fs:big'), test.id('inv:fs:up'), test.id('inv:fs:p'))),
  'false,true,false,true');
select test.eq('no automatic debit', app.owner_debit_block(test.id('inv:fs:aug')), 'taken from the revenue statement');
select test.eq('the other owner is debited as before', app.owner_debit_block(test.id('inv:fs:p')) is distinct from 'taken from the revenue statement', true);

create table test.fsst as select app.build_owner_statement(test.id('owner:fs_o'), date '2026-09-01') as id;
select test.eq('the statement shows the invoice paid from it',
  (select description || ':' || amount_cents from owner_statement_lines where owner_statement_id = (select id from test.fsst) and owner_invoice_id = test.id('inv:fs:aug')),
  (select 'Invoice ' || invoice_number || ', paid from statement:-4520' from owner_invoices where id = test.id('inv:fs:aug')));
select test.eq('the big one is taken as far as the payout goes: nothing left to pay out',
  (select payout_cents || '/' || balance_carried_forward_cents from owner_statements where id = (select id from test.fsst)), '0/0');
select test.eq('what was taken: the September invoice in full and part of the big one',
  (select -sum(amount_cents) > 4520 and count(*) = 2 from owner_statement_lines where owner_statement_id = (select id from test.fsst) and line_type = 'fees_deducted'), true);
select app.approve_owner_statement((select id from test.fsst), test.id('fs_admin'));
select test.eq('approved: the September invoice is paid from the statement, the big one part paid',
  (select string_agg(status || ':' || from_statement, ',' order by billing_date) from owner_invoices where id in (test.id('inv:fs:aug'), test.id('inv:fs:big'))), 'deducted:true,partially_deducted:true');
select test.eq('the owner portal says so', (select x ->> 'from_statement' from jsonb_array_elements(app.owner_portal_home(test.id('fs_o')) -> 'invoices') x where x ->> 'id' = test.id('inv:fs:aug')::text), 'true');
-- 2 months after billing, still owing: back to the debit, with an Admin task
update owner_invoices set billing_date = app.today() - 70 where id = test.id('inv:fs:big');
select test.eq('the fallback moves it', app.owner_fees_statement_fallback(test.id('owner:fs_o')), 1);
select test.eq('back to the bank debit after the notice',
  (select status || '/' || from_statement || '/' || (debit_on >= app.today() + 10) || '/' || (from_statement_fallback_at is not null) from owner_invoices where id = test.id('inv:fs:big')), 'issued/false/true/true');
select test.eq('Admin has a task', (select count(*) from tasks where task_type = 'owner_fees_statement_fallback' and related_id = test.id('inv:fs:big') and queue = 'admin'), 1::bigint);
select test.lives('back to Bank debit', $$select app.door(test.id('fs_admin'), 'aal2', 'ops_do', 'owner_fees_paid_from', jsonb_build_object('owner', test.id('owner:fs_o'), 'fees_paid_from', 'debit'))$$);
