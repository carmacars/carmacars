-- 24: the automatic owner debit, the statement emails with their PDFs, and the company statement sections
-- (migration 0037). Fixtures start with "od". Instants are Toronto times through test.od_at.
select test.suite('24 owner debit');
create or replace function test.od_at(p text) returns timestamptz language sql immutable as $$ select (p::timestamp at time zone 'America/Toronto') $$;
grant execute on function test.od_at(text) to service_role, authenticated;

select test.mk_user('od_admin', 'admin');
select test.mk_user('od_fin', 'va', 'finance');
-- the verification Admin (0036 may have made it already)
insert into users (id, email, full_name) values (test.id('od_verify_admin'), 'verify-admin@carmacars.ca', 'Verify Admin') on conflict do nothing;
insert into user_roles (user_id, role) select id, 'admin' from users where lower(email) = 'verify-admin@carmacars.ca' on conflict do nothing;
update users set status = 'active' where lower(email) = 'verify-admin@carmacars.ca';
select test.mk_owner('od_olga');
select test.mk_owner('od_nina');
select test.mk_vehicle('ODA', 'od_olga', p_enrolled => date '2026-09-01');
select test.mk_vehicle('ODB', 'od_olga', p_enrolled => date '2026-09-01');
select test.mk_vehicle('ODC', 'od_nina', p_enrolled => date '2026-09-01');
-- earlier months are settled, so January's run carries only January
insert into owner_invoices (owner_id, vehicle_id, kind, period_month, billing_date, status, created_by)
select v.owner_id, v.id, 'monthly', m, m + 14, 'draft', null
  from vehicles v cross join (values (date '2026-09-01'), (date '2026-10-01'), (date '2026-11-01'), (date '2026-12-01')) x(m)
 where v.id in (test.id('vehicle:ODA'), test.id('vehicle:ODB'), test.id('vehicle:ODC'));
update owner_invoices set status = 'issued' where vehicle_id in (test.id('vehicle:ODA'), test.id('vehicle:ODB'), test.id('vehicle:ODC'));
update owner_invoices set status = 'paid' where vehicle_id in (test.id('vehicle:ODA'), test.id('vehicle:ODB'), test.id('vehicle:ODC'));
-- Olga's pre-authorized debit, as the pay page saves it after a debit clears
select app.record_owner_payment_method(test.id('owner:od_olga'), null, jsonb_build_object('kind', 'pre_authorized_debit', 'brand_or_bank', 'Test Bank',
  'last4', '6789', 'processor_customer_id', 'cus_od_olga', 'processor_method_id', 'pm_od_olga', 'processor_mandate_id', 'mandate_od_olga'));

-- ---------------------------------------------------------------- 1. settings and dates
select test.eq('settings: on by default, 10 days of notice, 2 attempts, 3 days apart, debit on the billing day',
  (select owner_debit_enabled || '/' || owner_debit_notice_days || '/' || owner_debit_max_attempts || '/' || owner_debit_retry_gap_days || '/' || billing_day
     from app.settings()), 'true/10/2/3/15');
select test.eq('dates: the debit day of January is the 15th', app.owner_debit_date(date '2027-01-20'), date '2027-01-15');
select test.eq('dates: on the 5th the next debit is this month''s; on the 6th it is next month''s',
  app.owner_debit_next_date(date '2027-01-05') || ' ' || app.owner_debit_next_date(date '2027-01-06'), '2027-01-15 2027-02-15');
select test.eq('mandate: Olga has one, Nina none',
  (app.owner_debit_mandate(test.id('owner:od_olga')) ->> 'mandate_id') || '/' || coalesce(app.owner_debit_mandate(test.id('owner:od_nina')) ->> 'mandate_id', 'none'),
  'mandate_od_olga/none');

-- ---------------------------------------------------------------- 2. the notice day
select test.eq('job: not due the day before the notice day', app.job_owner_debit_notices(test.od_at('2027-01-04 12:00')), 'not_due');
select test.eq('job: not due before the run hour', app.job_owner_debit_notices(test.od_at('2027-01-05 05:00')), 'not_due');
select test.eq('job: runs on the notice day (the 15th less 10 days)', app.job_owner_debit_notices(test.od_at('2027-01-05 07:00')), 'succeeded');
select test.eq('job: once per debit day', app.job_owner_debit_notices(test.od_at('2027-01-05 08:00')), 'already_run');
create table test.od as
  select 'iA'::text as k, (select id from owner_invoices where vehicle_id = test.id('vehicle:ODA') and period_month = '2027-01-01' and status <> 'void') as v
  union all select 'iB', (select id from owner_invoices where vehicle_id = test.id('vehicle:ODB') and period_month = '2027-01-01' and status <> 'void')
  union all select 'iC', (select id from owner_invoices where vehicle_id = test.id('vehicle:ODC') and period_month = '2027-01-01' and status <> 'void');
grant select on test.od to service_role, authenticated;
create or replace function test.odv(p text) returns uuid language sql stable as $$ select v from test.od where k = p $$;
select test.eq('notice day: January''s invoices exist and are issued (they were drafts before)',
  (select string_agg(status, ',' order by invoice_number) from owner_invoices where id in (test.odv('iA'), test.odv('iB'), test.odv('iC'))), 'issued,issued,issued');
select test.eq('notice day: the owner_fee_invoice email of each issued invoice is queued',
  (select count(*) from app_events where code = 'owner_fee_invoice' and entity_id in (test.odv('iA'), test.odv('iB'), test.odv('iC'))), 3::bigint);
select test.eq('notice day: one notice for Olga, both invoices, the total of their balances',
  (select cardinality(invoice_ids) || '/' || (total_cents = (select sum(balance_cents) from owner_invoices where id in (test.odv('iA'), test.odv('iB'))))
          || '/' || bank_last4 || '/' || debit_on from owner_debit_notices where owner_id = test.id('owner:od_olga')), '2/true/6789/2027-01-15');
select test.eq('notice day: one scheduled attempt per invoice, each with its own idempotency key',
  (select count(*) || '/' || count(distinct idempotency_key) || '/' || min(status) || '/' || min(attempt_no) from owner_debit_attempts where owner_id = test.id('owner:od_olga')), '2/2/scheduled/1');
select test.eq('notice day: the invoices carry the debit day',
  (select string_agg(debit_on::text, ',') from owner_invoices where id in (test.odv('iA'), test.odv('iB'))), '2027-01-15,2027-01-15');
select test.eq('notice day: the owner_debit_notice email is queued for Olga',
  (select count(*) from app_events e join owner_debit_notices n on n.id = e.entity_id where e.code = 'owner_debit_notice' and n.owner_id = test.id('owner:od_olga')), 1::bigint);
select test.eq('no mandate: nothing is scheduled for Nina', (select count(*) from owner_debit_attempts where owner_id = test.id('owner:od_nina')), 0::bigint);
select test.eq('no mandate: the notice is recorded as missing, Nina is asked to set up banking, an Admin gets the exception and a task',
  (select n.mandate_missing || '/' ||
          (select count(*) from app_events e where e.entity_id = n.id and e.code = 'owner_debit_setup_needed') || '/' ||
          (select count(*) from app_events e where e.entity_id = n.id and e.code = 'staff_owner_debit_exception') || '/' ||
          (select count(*) from tasks t where t.owner_id = n.owner_id and t.task_type = 'owner_debit_no_mandate' and t.status = 'open')
     from owner_debit_notices n where n.owner_id = test.id('owner:od_nina')), 'true/1/1/1');
select test.eq('run log: the notice run counts the notices, the owners without a mandate and the scheduled debits (every owner of this database)',
  (select notices_sent >= 1 and no_mandate >= 1 and scheduled >= 2 and status = 'succeeded' from owner_debit_runs where run_on = '2027-01-05' and kind = 'notice'), true);
-- from here on only Olga and Nina are debited (the other owners of this database are paused)
update owners set auto_debit_paused = true, auto_debit_paused_reason = 'other suites' where id not in (test.id('owner:od_olga'), test.id('owner:od_nina'));
select app.process_events(100000);
select test.eq('emails: the notice carries the invoices, the total and the account',
  (select (o.payload ->> 'debit_date') || '/' || jsonb_array_length(o.payload -> 'debit_items') || '/' || (o.payload ->> 'bank_last4') || '/' || (o.payload ->> 'debit_count_text')
     from notification_outbox o join owner_debit_notices n on n.id = o.entity_id
    where o.code = 'owner_debit_notice' and n.owner_id = test.id('owner:od_olga') and n.debit_on = '2027-01-15'), 'Fri, Jan 15, 2027/2/6789/2 invoices');
select test.eq('emails: the monthly invoice says it will be debited, and when',
  (select payload ->> 'bank_last4' like 'By pre-authorized debit on Fri, Jan 15, 2027 from your account ending 6789%' from notification_outbox
    where code = 'owner_fee_invoice' and entity_id = test.odv('iA') limit 1), true);
select test.eq('emails: Nina is asked to set up banking, with her invoice listed',
  (select (o.payload ->> 'debit_date') || '/' || jsonb_array_length(o.payload -> 'debit_items') from notification_outbox o join owner_debit_notices n on n.id = o.entity_id
    where o.code = 'owner_debit_setup_needed' and n.owner_id = test.id('owner:od_nina')), 'Fri, Jan 15, 2027/1');
select test.throws('schedule: a debit closer than the notice days is refused',
  format('select app.owner_debit_schedule(%L, %L::date, null, null, %L::date)', test.id('owner:od_olga'), '2027-01-15', '2027-01-08'), 'needs its notice 10 days before');

-- ---------------------------------------------------------------- 3. the owner portal and Admin > Owner debits
select test.eq('portal: the owner sees the next debit, its total and the account',
  (select (h #>> '{auto_debit,next_debit_on}') || '/' || ((h #>> '{auto_debit,next_debit_cents}')::bigint = (select sum(balance_cents) from owner_invoices where id in (test.odv('iA'), test.odv('iB'))))
          || '/' || (h #>> '{auto_debit,bank_last4}') || '/' || (h #>> '{auto_debit,mandate}')
     from public.owner_portal_home(test.id('od_olga')) h), '2027-01-15/true/6789/true');
select test.eq('portal: each invoice shows its scheduled debit',
  (select string_agg(x #>> '{debit,attempt,status}', ',') from jsonb_array_elements(public.owner_portal_home(test.id('od_olga')) -> 'invoices') x
    where (x ->> 'id')::uuid in (test.odv('iA'), test.odv('iB'))), 'scheduled,scheduled');
select test.eq('portal: Nina sees she has no debit set up', public.owner_portal_home(test.id('od_nina')) #>> '{auto_debit,mandate}', 'false');
select test.eq('admin: the debits screen lists the two scheduled debits',
  (select jsonb_array_length(app.admin_read(test.id('od_admin'), 'owner_debits') -> 'upcoming') >= 2), true);
select test.throws('admin: the debits screen is for Admins', format('select app.admin_read(%L, %L)', test.id('od_fin'), 'owner_debits'), 'Admin');

-- ---------------------------------------------------------------- 4. the debit day: claim, submit, settle
select test.eq('claim: nothing before the debit day', jsonb_array_length(app.owner_debit_claim(test.od_at('2027-01-14 12:00'))), 0);
select test.eq('claim: nothing before the run hour', jsonb_array_length(app.owner_debit_claim(test.od_at('2027-01-15 05:00'))), 0);
create table test.od_claim as select x from jsonb_array_elements(app.owner_debit_claim(test.od_at('2027-01-15 07:00'), 100)) x
  where (x #>> '{metadata,owner_id}')::uuid = test.id('owner:od_olga');
grant select on test.od_claim to service_role;
select test.eq('claim: both of Olga''s debits, with the customer, the method, the mandate and the metadata the webhook reads',
  (select count(*) || '/' || min(x ->> 'customer_id') || '/' || min(x ->> 'payment_method_id') || '/' || min(x ->> 'mandate_id') || '/' || min(x #>> '{metadata,purpose}')
          || '/' || bool_and(x #>> '{metadata,debit_attempt_id}' is not null) from test.od_claim), '2/cus_od_olga/pm_od_olga/mandate_od_olga/owner_invoice/true');
select test.eq('claim: the attempts are being submitted', (select string_agg(status, ',') from owner_debit_attempts where owner_id = test.id('owner:od_olga')), 'submitting,submitting');
select test.eq('claim: a second claim at once gets nothing new for Olga',
  (select count(*) from jsonb_array_elements(app.owner_debit_claim(test.od_at('2027-01-15 07:05'), 100)) x where (x #>> '{metadata,owner_id}')::uuid = test.id('owner:od_olga')), 0::bigint);
create or replace function test.od_att(p_inv text) returns uuid language sql stable as $$
  select id from owner_debit_attempts where owner_invoice_id = test.odv(p_inv) order by attempt_no desc limit 1 $$;
select app.owner_debit_submitted(test.od_att('iA'), '{"intent_id":"pi_od_A1","status":"processing"}');
select test.eq('submitted: the attempt is processing, the invoice is processing, a pending debit payment is recorded',
  (select a.status || '/' || i.status || '/' || p.status || '/' || p.method from owner_debit_attempts a join owner_invoices i on i.id = a.owner_invoice_id
     join payments p on p.id = a.payment_id where a.id = test.od_att('iA')), 'processing/processing/pending/pre_authorized_debit');
select test.eq('submitted: a second report is a replay', app.owner_debit_submitted(test.od_att('iA'), '{"intent_id":"pi_od_A1","status":"processing"}') ->> 'repeat', 'true');
select test.eq('submitted: the owner cannot pay it again while it processes',
  (select x ->> 'payable' from jsonb_array_elements(public.owner_portal_home(test.id('od_olga')) -> 'invoices') x where (x ->> 'id')::uuid = test.odv('iA')), 'false');
select test.eq('result: a processing report changes nothing', app.owner_debit_result('pi_od_A1', '{"status":"processing"}') ->> 'status', 'processing');
select test.eq('result: succeeded marks the invoice paid', app.owner_debit_result('pi_od_A1', '{"status":"succeeded","charge_id":"py_od_A1"}') ->> 'invoice_status', 'paid');
select test.eq('result: the payment succeeded, the attempt succeeded, the receipt email is queued',
  (select p.status || '/' || a.status || '/' || (select count(*) from app_events e where e.code = 'owner_payment_received' and e.entity_id = a.owner_invoice_id)
     from owner_debit_attempts a join payments p on p.id = a.payment_id where a.id = test.od_att('iA')), 'succeeded/succeeded/1');
select test.eq('result: the webhook and the poll reporting it again change nothing', app.owner_debit_result('pi_od_A1', '{"status":"succeeded"}') ->> 'repeat', 'true');
select test.eq('result: an unknown PaymentIntent is not a debit', app.owner_debit_result('pi_unknown', '{"status":"succeeded"}') ->> 'reason', 'not_a_debit');

-- ---------------------------------------------------------------- 5. a returned debit, the retry, arrears
select app.owner_debit_submitted(test.od_att('iB'), '{"intent_id":"pi_od_B1","status":"processing"}');
create table test.od_bal as select balance_cents as b from owner_invoices where id = test.odv('iB');
grant select on test.od_bal to service_role;
select test.eq('returned: the invoice is failed with the retry on the retry day (the 18th)',
  (select r ->> 'invoice_status' || '/' || (r ->> 'retry_on') from (select app.owner_debit_result('pi_od_B1',
     '{"status":"requires_payment_method","error_code":"insufficient_funds","error_message":"The bank returned the debit: insufficient funds."}') r) x), 'failed/2027-01-18');
select test.eq('returned: the Late Fee is added once (owner_late_fee_cents)',
  (select late_fee_cents from owner_invoices where id = test.odv('iB')), (select owner_late_fee_cents::bigint from app.settings()));
select test.eq('returned: the payment is failed with the bank''s reason',
  (select p.status || '/' || p.last_decline_code from owner_debit_attempts a join payments p on p.id = a.payment_id where a.processor_intent_id = 'pi_od_B1'),
  'failed/The bank returned the debit: insufficient funds.');
select test.eq('returned for insufficient funds: one retry on the 18th for the original amount only, never the Late Fee (0053)',
  (select a.attempt_no || '/' || a.status || '/' || a.debit_on || '/' || (a.amount_cents = (select b from test.od_bal)) || '/' || a.is_retry
     from owner_debit_attempts a where a.id = test.od_att('iB')), '2/scheduled/2027-01-18/true/true');
select test.eq('returned for insufficient funds: the Late Fee is its own invoice line, "Late Fee"',
  (select string_agg(description || ':' || amount_cents, ',') from owner_invoice_lines where owner_invoice_id = test.odv('iB') and kind = 'late_fee'), 'Late Fee:5000');
select test.eq('returned: the owner and finance are told once',
  (select count(*) filter (where code = 'owner_payment_failed') || '/' || count(*) filter (where code = 'staff_owner_invoice_failed')
     from app_events where entity_id = test.odv('iB')), '1/1');
select test.eq('returned: the failed invoice is payable again from its page',
  (select x ->> 'payable' from jsonb_array_elements(public.owner_portal_home(test.id('od_olga')) -> 'invoices') x where (x ->> 'id')::uuid = test.odv('iB')), 'true');
select test.eq('retry: claimed on the 18th', (select count(*) from jsonb_array_elements(app.owner_debit_claim(test.od_at('2027-01-18 07:00'), 100)) x
   where (x ->> 'attempt_id')::uuid = test.od_att('iB')), 1::bigint);
select app.owner_debit_submitted(test.od_att('iB'), '{"intent_id":"pi_od_B2","status":"processing"}');
select test.eq('retry: the invoice is retry_processing', (select status from owner_invoices where id = test.odv('iB')), 'retry_processing');
select test.eq('retry fails: the last attempt puts the invoice in arrears',
  app.owner_debit_result('pi_od_B2', '{"status":"requires_payment_method","error_message":"Returned again."}') ->> 'invoice_status', 'in_arrears');
select test.eq('retry fails: no third attempt, the in-arrears emails go, no second "we retry" email',
  (select (select count(*) from owner_debit_attempts where owner_invoice_id = test.odv('iB')) || '/' ||
          count(*) filter (where code = 'owner_in_arrears') || '/' || count(*) filter (where code = 'owner_payment_failed')
     from app_events where entity_id = test.odv('iB')), '2/1/1');
select test.eq('retry fails: the vehicle is in arrears and an Admin task is open',
  (select v.in_arrears || '/' || exists (select 1 from tasks t where t.related_id = test.odv('iB') and t.task_type = 'owner_retry_failed')
     from vehicles v where v.id = test.id('vehicle:ODB')), 'true/true');
select test.eq('run log: the 15th''s run counts two sent and one cleared',
  (select submitted || '/' || succeeded || '/' || failed from owner_debit_runs where run_on = '2027-01-15' and kind = 'debit'), '2/1/1');

-- ---------------------------------------------------------------- 6. pauses, the notice amount, cancel, errors
insert into owner_invoices (owner_id, vehicle_id, kind, billing_date, status) values (test.id('owner:od_olga'), test.id('vehicle:ODA'), 'adjustment', date '2027-01-20', 'draft');
insert into test.od select 'iX', id from owner_invoices where vehicle_id = test.id('vehicle:ODA') and kind = 'adjustment' and billing_date = '2027-01-20';
insert into owner_invoice_lines (owner_invoice_id, kind, description, amount_cents, hst_applies, hst_cents) values (test.odv('iX'), 'adjustment', 'Registry cost', 10000, true, 1300);
update owner_invoices set status = 'issued' where id = test.odv('iX');
select test.throws('pause: the reason is required', format('select app.admin_do(%L, %L, %L)', test.id('od_admin'), 'owner_debit_pause', jsonb_build_object('invoice', test.odv('iX'))), 'Give the reason');
select test.throws('pause: Admins only', format('select app.owner_debit_set_pause(%L, %L)', test.id('od_fin'), jsonb_build_object('invoice', test.odv('iX'), 'reason', 'x')), 'Admin');
select app.admin_do(test.id('od_admin'), 'owner_debit_pause', jsonb_build_object('invoice', test.odv('iX'), 'reason', 'Owner disputes the registry cost'));
select test.eq('pause: a paused invoice is not scheduled', app.owner_debit_schedule(test.id('owner:od_olga'), date '2027-02-15', null, null, date '2027-02-01') ->> 'invoices', '0');
select test.eq('pause: the block names it', app.owner_debit_block(test.odv('iX')), 'paused for this invoice');
select test.eq('pause: audited', (select count(*) from audit_log where action = 'owner_debit_pause' and entity_id = test.odv('iX')::text), 1::bigint);
select app.admin_do(test.id('od_admin'), 'owner_debit_resume', jsonb_build_object('invoice', test.odv('iX')));
select test.eq('resume: scheduled again', app.owner_debit_schedule(test.id('owner:od_olga'), date '2027-02-15', null, null, date '2027-02-01') ->> 'invoices', '1');
select app.admin_do(test.id('od_admin'), 'owner_debit_pause', jsonb_build_object('owner', test.id('owner:od_olga'), 'reason', 'Owner on holiday, paying by e-Transfer'));
select test.eq('owner pause: a scheduled debit is skipped on the day, not sent',
  (select count(*) from jsonb_array_elements(app.owner_debit_claim(test.od_at('2027-02-15 07:00'), 100)) x where (x ->> 'attempt_id')::uuid = test.od_att('iX')), 0::bigint);
select test.eq('owner pause: the attempt says why and the invoice can be scheduled again later',
  (select a.status || '/' || a.skip_reason || '/' || coalesce(i.debit_on::text, 'none') from owner_debit_attempts a join owner_invoices i on i.id = a.owner_invoice_id
    where a.id = test.od_att('iX')), 'skipped/paused for this owner/none');
select app.admin_do(test.id('od_admin'), 'owner_debit_resume', jsonb_build_object('owner', test.id('owner:od_olga')));
select app.owner_debit_schedule(test.id('owner:od_olga'), date '2027-03-15', null, null, date '2027-03-01');
insert into owner_invoice_lines (owner_invoice_id, kind, description, amount_cents, hst_applies, hst_cents) values (test.odv('iX'), 'adjustment', 'Second registry cost', 5000, true, 650);
select test.eq('notice amount: a balance grown after the notice is not debited (never more than the notice said)',
  (select count(*) from jsonb_array_elements(app.owner_debit_claim(test.od_at('2027-03-15 07:00'), 100)) x where (x ->> 'attempt_id')::uuid = test.od_att('iX')), 0::bigint);
select test.eq('notice amount: skipped with the reason, an Admin is told',
  (select a.skip_reason || '/' || (select count(*) from app_events e where e.entity_id = a.id and e.code = 'staff_owner_debit_exception') from owner_debit_attempts a where a.id = test.od_att('iX')),
  'the balance is more than the notice/1');
select app.owner_debit_schedule(test.id('owner:od_olga'), date '2027-04-15', null, null, date '2027-04-01');
select test.eq('errors: a passing Stripe error leaves the debit to be sent again with the same key',
  (select (app.owner_debit_claim(test.od_at('2027-04-15 07:00'), 100) @> jsonb_build_array(jsonb_build_object('attempt_id', test.od_att('iX'))))
          || '/' || (app.owner_debit_submit_error(test.od_att('iX'), 'api_error', 'Stripe is unavailable', false) ->> 'status')), 'true/submitting');
select test.eq('errors: not claimed again while it may still be on its way',
  (select count(*) from jsonb_array_elements(app.owner_debit_claim(test.od_at('2027-04-15 07:10'), 100)) x where (x ->> 'attempt_id')::uuid = test.od_att('iX')), 0::bigint);
alter table owner_debit_attempts disable trigger owner_debit_attempts_updated;
update owner_debit_attempts set updated_at = now() - interval '31 minutes' where id = test.od_att('iX');
alter table owner_debit_attempts enable trigger owner_debit_attempts_updated;
select test.eq('errors: claimed again after 30 minutes with the same idempotency key',
  (select (x ->> 'idempotency_key') = (select idempotency_key from owner_debit_attempts where id = test.od_att('iX'))
     from jsonb_array_elements(app.owner_debit_claim(test.od_at('2027-04-15 07:40'), 100)) x where (x ->> 'attempt_id')::uuid = test.od_att('iX')), true);
select app.owner_debit_submitted(test.od_att('iX'), '{"intent_id":"pi_od_X1","status":"processing"}');
select test.eq('cancel: a debit canceled at the processor', app.owner_debit_result('pi_od_X1', '{"status":"canceled"}') ->> 'status', 'canceled');
select test.eq('cancel: the invoice is back to issued, the pending payment cancelled',
  (select i.status || '/' || p.status from owner_invoices i join owner_debit_attempts a on a.owner_invoice_id = i.id join payments p on p.id = a.payment_id
    where a.processor_intent_id = 'pi_od_X1'), 'issued/cancelled');
select app.owner_debit_schedule(test.id('owner:od_olga'), date '2027-05-15', null, null, date '2027-05-01');
select app.owner_debit_claim(test.od_at('2027-05-15 07:00'), 100);
select test.eq('errors: an inactive mandate is a failed debit',
  app.owner_debit_submit_error(test.od_att('iX'), 'payment_intent_mandate_invalid', 'The mandate is no longer active', true) ->> 'invoice_status', 'failed');
select test.eq('errors: not insufficient funds (0053): the method is revoked, no retry, no Late Fee, the invoice''s automatic debit paused',
  (select status from owner_payment_methods where owner_id = test.id('owner:od_olga') and kind = 'pre_authorized_debit' order by created_at desc limit 1) || '/' ||
  (select a.status || '/' || (select count(*) from owner_debit_attempts x where x.owner_invoice_id = i.id and x.status = 'scheduled') || '/' || i.late_fee_cents || '/' || i.auto_debit_paused
     from owner_debit_attempts a join owner_invoices i on i.id = a.owner_invoice_id where a.id = test.od_att('iX')),
  'revoked/failed/0/0/true');
select test.eq('errors: not insufficient funds: the owner gets "returned", an Admin gets the exception and a task; no "we retry" email',
  (select count(*) filter (where e.code = 'owner_debit_returned') || '/' || count(*) filter (where e.code = 'staff_owner_debit_exception' and e.payload ->> 'exception' = 'returned')
          || '/' || (select count(*) from tasks t where t.related_id = test.odv('iX') and t.task_type = 'owner_debit_returned')
          || '/' || (select count(*) from app_events f where f.entity_id = test.odv('iX') and f.code = 'owner_payment_failed')
     from app_events e where e.entity_id = test.od_att('iX')), '1/1/1/0');
-- an Admin resumes the invoice's automatic debit (the owner updated the bank account)
select app.admin_do(test.id('od_admin'), 'owner_debit_resume', jsonb_build_object('invoice', test.odv('iX')));
-- and it is debited again after a new notice (on the June debit day below)
select app.record_owner_payment_method(test.id('owner:od_olga'), null, jsonb_build_object('kind', 'pre_authorized_debit', 'last4', '2223',
  'processor_customer_id', 'cus_od_olga', 'processor_method_id', 'pm_od_olga2b', 'processor_mandate_id', 'mandate_od_olga2b'));
select test.eq('errors: resumed, the invoice is scheduled again with a new notice (a debit, not a retry)',
  (select (r ->> 'invoices') from (select app.owner_debit_schedule(test.id('owner:od_olga'), date '2027-06-15', null, null, date '2027-06-01') r) x), '1');

-- ---------------------------------------------------------------- 7. mandates and banking setup
select test.eq('setup: a verification still to come is saved pending',
  (app.owner_record_debit_setup(test.id('od_nina'), test.id('owner:od_nina'), '{"status":"requires_action","customer_id":"cus_od_nina","method_id":"pm_od_nina","mandate_id":"mandate_od_nina","bank":{"name":"Test Bank","last4":"4321"}}') ->> 'active'), 'false');
select test.eq('setup: no debit until it is verified', app.owner_debit_mandate(test.id('owner:od_nina')) is null, true);
select app.owner_debit_setup_verified('pm_od_nina', 'mandate_od_nina');
select test.eq('setup: verified, the mandate is in force and the Admin task closes',
  (app.owner_debit_mandate(test.id('owner:od_nina')) ->> 'last4') || '/' ||
  (select count(*) from tasks where owner_id = test.id('owner:od_nina') and task_type = 'owner_debit_no_mandate' and status = 'open'), '4321/0');
select test.eq('setup: the bank-details-changed security email is queued',
  (select count(*) from app_events where code = 'owner_bank_details_changed' and entity_id = test.id('owner:od_nina')) >= 1, true);
select test.eq('mandate.updated: an inactive mandate revokes the method', app.owner_mandate_inactive('mandate_od_nina') ->> 'revoked', '1');
select test.eq('mandate.updated: the owner and an Admin are told',
  (select count(*) filter (where code = 'staff_owner_debit_exception') || '/' || count(*) filter (where code = 'owner_bank_details_changed' and dedupe_key like '%:mandate:%')
     from app_events where entity_id = test.id('owner:od_nina')), '1/1');
select test.eq('mandate.updated: a second report changes nothing', app.owner_mandate_inactive('mandate_od_nina') ->> 'revoked', '0');

-- ---------------------------------------------------------------- 8. poll and the run summary
select test.eq('poll: a debit processing longer than owner_debit_poll_hours is asked again',
  (select app.owner_debit_poll(now() + interval '2 days', 100) @> jsonb_build_array(jsonb_build_object('intent_id', 'pi_od_A1'))), false);
select app.owner_debit_schedule(test.id('owner:od_nina'), date '2027-06-15', null, null, date '2027-06-01');
select app.record_owner_payment_method(test.id('owner:od_nina'), null, jsonb_build_object('kind', 'pre_authorized_debit', 'last4', '1111',
  'processor_customer_id', 'cus_od_nina', 'processor_method_id', 'pm_od_nina2', 'processor_mandate_id', 'mandate_od_nina2'));
select app.owner_debit_schedule(test.id('owner:od_nina'), date '2027-06-15', null, null, date '2027-06-01');
select app.owner_debit_claim(test.od_at('2027-06-15 07:00'), 100);
select app.owner_debit_submitted(test.od_att('iC'), '{"intent_id":"pi_od_C1","status":"processing"}');
select app.owner_debit_submitted(test.od_att('iX'), '{"intent_id":"pi_od_X2","status":"processing"}');
select test.eq('poll: listed after the poll hours', app.owner_debit_poll(now() + interval '2 days', 100) @> jsonb_build_array(jsonb_build_object('intent_id', 'pi_od_C1')), true);
select test.eq('poll: not before', app.owner_debit_poll(now() + interval '1 hour', 100) @> jsonb_build_array(jsonb_build_object('intent_id', 'pi_od_C1')), false);
select test.eq('run close: every debit of the day was sent, so the run closes', app.owner_debit_run_close(test.od_at('2027-06-15 09:00')) ->> 'open', 'false');
select app.owner_debit_run_close(test.od_at('2027-06-15 10:00'));
select test.eq('run close: the day''s summary goes to the Admins once',
  (select count(*) from app_events e join owner_debit_runs r on r.id = e.entity_id where e.code = 'staff_owner_debit_run' and r.run_on = '2027-06-15'), 1::bigint);
select test.eq('run close: an earlier run whose debits were all sent (one after a passing error) closes too',
  (select status from owner_debit_runs where run_on = '2027-04-15' and kind = 'debit'), 'succeeded');

-- ---------------------------------------------------------------- 9. test owners: staff notices only to the verification accounts
update owners set is_test = true where id = test.id('owner:od_nina');
select app.ntf_emit('staff_owner_debit_exception', 'owner', test.id('owner:od_nina'), 'test-owner-check', jsonb_build_object('owner_id', test.id('owner:od_nina'), 'exception', 'no_mandate'));
select app.ntf_emit('staff_owner_debit_exception', 'owner', test.id('owner:od_olga'), 'real-owner-check', jsonb_build_object('owner_id', test.id('owner:od_olga'), 'exception', 'no_mandate'));
select app.process_events(100000);
select test.eq('test owner: the staff notice goes only to the verification Admin',
  (select string_agg(distinct to_address, ',') from notification_outbox where dedupe_key like 'staff_owner_debit_exception:' || test.id('owner:od_nina') || ':test-owner-check%'),
  'verify-admin@carmacars.ca');
select test.eq('real owner: every Admin gets it',
  (select count(distinct to_address) > 1 from notification_outbox where dedupe_key like 'staff_owner_debit_exception:' || test.id('owner:od_olga') || ':real-owner-check%'), true);
select test.eq('emails: every variable of the new emails is filled',
  (select count(*) from notification_outbox where code in ('owner_debit_notice', 'owner_debit_setup_needed', 'staff_owner_debit_exception', 'staff_owner_debit_run')
     and missing_variables <> '{}'), 0::bigint);

-- ---------------------------------------------------------------- 10. company statement sections, PDFs and the email
select app.build_company_statement(date '2027-01-01', test.id('od_admin'));
create table test.od_cs as select * from company_statements where statement_month = '2027-01-01';
grant select on test.od_cs to service_role;
select test.eq('sections: every section of blueprint 11 section 3.3 is stored with the statement',
  (select string_agg(s ->> 'key', ',' order by ord) from company_statements cs, jsonb_array_elements(cs.sections) with ordinality x(s, ord) where cs.statement_month = '2027-01-01'),
  'income,fleet,recoveries,held,hst,receivables,cash,owner_fees,funnel,investors,checks,adjustments,supply');
select test.eq('sections: the income summary''s total revenue is the sum of its revenue lines',
  (select (r -> 13 ->> 'cents')::bigint = (select sum((x ->> 'cents')::bigint) from jsonb_array_elements(r) with ordinality q(x, n) where n <= 13)
     from (select s -> 'rows' r from company_statements cs, jsonb_array_elements(cs.sections) s where cs.statement_month = '2027-01-01' and s ->> 'key' = 'income') z), true);
select test.eq('sections: owner fees billed for January match the statement''s owner fee columns',
  (select (s -> 'rows' -> 0 ->> 'cents')::bigint = (select insurance_fees_cents + tracker_fees_cents + install_fees_cents + other_owner_fees_cents
       from company_statement_lines l where l.statement_id = cs.id and l.level = 'total')
     from company_statements cs, jsonb_array_elements(cs.sections) s where cs.statement_month = '2027-01-01' and s ->> 'key' = 'owner_fees'), true);
select test.eq('sections: the net HST line is collected less refunds less paid',
  (select (s -> 'rows' -> 3 ->> 'cents')::bigint = (s -> 'rows' -> 0 ->> 'cents')::bigint + (s -> 'rows' -> 1 ->> 'cents')::bigint + (s -> 'rows' -> 2 ->> 'cents')::bigint
     from company_statements cs, jsonb_array_elements(cs.sections) s where cs.statement_month = '2027-01-01' and s ->> 'key' = 'hst'), true);
select test.eq('sections: the Admin screen reads them', jsonb_array_length(app.admin_read(test.id('od_admin'), 'company_sections', '{"month":"2027-01-01"}')), 13);
select test.eq('PDF facts: the three company statement PDFs carry their title, the sections, and are stored once rendered',
  (select (f ->> 'title') || '/' || jsonb_array_length(f -> 'sections') || '/' || (f ->> 'store')
     from (select app.pdf_facts('company_statement', app.company_doc_key(cs)) f from company_statements cs where cs.statement_month = '2027-01-01') x),
  'CarmaCars statement, January 2027/13/true');
select test.eq('PDF facts: by owner and by vehicle list their rows',
  (select (jsonb_array_length(app.pdf_facts('company_owners', app.company_doc_key(cs)) -> 'owners') > 0) || '/' ||
          (jsonb_array_length(app.pdf_facts('company_vehicles', app.company_doc_key(cs)) -> 'vehicles') > 0)
     from company_statements cs where cs.statement_month = '2027-01-01'), 'true/true');
select test.eq('PDF facts: a key of an older version is not served', (select app.pdf_facts('company_statement', cs.id::text || ':0000') from company_statements cs where cs.statement_month = '2027-01-01'), null::jsonb);
select test.eq('access: company statement PDFs are for Admins only',
  (select app.file_access(test.id('od_admin'), 'company_statement', app.company_doc_key(cs)) || '/' || app.file_access(test.id('od_fin'), 'company_statement', app.company_doc_key(cs))
          || '/' || app.file_access(test.id('od_olga'), 'company_statement', app.company_doc_key(cs))
     from company_statements cs where cs.statement_month = '2027-01-01'), 'true/false/false');
select test.eq('email day: not due on the 9th of February',
  (select count(*) from jsonb_array_elements(app.statement_mail_due(test.od_at('2027-02-09 12:00'))) x where x ->> 'group' = 'company:' || (select id from test.od_cs)), 0::bigint);
select test.eq('email day: the three PDFs are due on the 10th (company_statement_email_day)',
  (select count(*) from jsonb_array_elements(app.statement_mail_due(test.od_at('2027-02-10 12:00'))) x where x ->> 'group' = 'company:' || (select id from test.od_cs)), 3::bigint);
select test.throws('release: refused until its PDF is stored',
  format('select app.statement_mail_release(%L, %L)', 'company_statement', (select app.company_doc_key(cs) from company_statements cs where cs.statement_month = '2027-01-01')), 'Render and store the PDF first');
select app.file_record('company_statement', app.company_doc_key(cs), 'documents', 'generated/company_statement/x/a.pdf', 'sha-a', 'CarmaCars statement') from company_statements cs where cs.statement_month = '2027-01-01';
select test.eq('release: waits for the other two PDFs',
  (select app.statement_mail_release('company_statement', app.company_doc_key(cs)) ->> 'reason' from company_statements cs where cs.statement_month = '2027-01-01'), 'waiting for the other PDFs');
select app.file_record(k, app.company_doc_key(cs), 'documents', 'generated/' || k || '/x/a.pdf', 'sha-' || k, 'CarmaCars statement') from company_statements cs, unnest(array['company_owners', 'company_vehicles']) k where cs.statement_month = '2027-01-01';
select test.eq('release: with all three stored the email goes once',
  (select (app.statement_mail_release('company_vehicles', app.company_doc_key(cs)) ->> 'sent') || '/' || (app.statement_mail_release('company_owners', app.company_doc_key(cs)) ->> 'sent')
     from company_statements cs where cs.statement_month = '2027-01-01'), 'true/false');
select app.process_events(100000);
select test.eq('email: each Admin gets staff_monthly_statements_pdfs with no variable missing',
  (select count(*) > 0 and bool_and(missing_variables = '{}') from notification_outbox where code = 'staff_monthly_statements_pdfs' and entity_id = (select id from test.od_cs)), true);
select test.eq('email: three PDFs are attached',
  (select string_agg(a ->> 'k', ',' order by a ->> 'k') from notification_outbox o, jsonb_array_elements(app.outbox_attachments(o.id)) a
    where o.code = 'staff_monthly_statements_pdfs' and o.entity_id = (select id from test.od_cs) and o.to_address = 'verify-admin@carmacars.ca'),
  'company_owners,company_statement,company_vehicles');
select test.eq('email: the statement link is signed for the company statement PDF',
  (select app.outbox_file_refs(o.id) #>> '{statement_url,k}' from notification_outbox o where o.code = 'staff_monthly_statements_pdfs' and o.entity_id = (select id from test.od_cs) limit 1), 'company_statement');
select test.eq('email: an Admin can send the statements to themselves only',
  (select (app.admin_do(test.id('od_admin'), 'company_statement_email', '{"month":"2027-01-01"}') ->> 'ok') || '/' || (select count(*) from (select app.process_events(100000)) p) || '/' ||
          (select count(distinct to_address) from notification_outbox where code = 'staff_monthly_statements_pdfs' and recipient_user_id = test.id('od_admin'))), 'true/1/1');
select test.eq('owner statements: their email attaches the statement PDF',
  (select coalesce(min(a ->> 'k'), 'none') from notification_outbox o, jsonb_array_elements(app.outbox_attachments(o.id)) a where o.code = 'owner_statement_ready'), 'owner_statement');

-- adjustments to earlier months: January is frozen, then a January fee changes; February shows the difference once
update company_statements set status = 'final', ties_ok = true, finalized_by = test.id('od_admin'), finalized_at = now() where statement_month = '2027-01-01';
insert into owner_invoice_lines (owner_invoice_id, kind, description, amount_cents, hst_applies, hst_cents)
values (test.odv('iC'), 'insurance_fee', 'Insurance Fee correction', 1234, true, 160);
select app.build_company_statement(date '2027-02-01', test.id('od_admin'));
select test.eq('adjustments: February lists January''s insurance fee change',
  (select string_agg((r ->> 'column') || '=' || (r ->> 'cents'), ',') from company_statements cs, jsonb_array_elements(cs.sections) s, jsonb_array_elements(s -> 'rows') r
    where cs.statement_month = '2027-02-01' and s ->> 'key' = 'adjustments' and r ->> 'month' = '2027-01' and r ->> 'column' = 'insurance_fees_cents'),
  'insurance_fees_cents=1234');
select test.eq('adjustments: the frozen January statement itself did not change',
  (select status || '/' || (select insurance_fees_cents from company_statement_lines l where l.statement_id = cs.id and l.level = 'total')
     from company_statements cs where cs.statement_month = '2027-01-01'),
  (select 'final/' || insurance_fees_cents from company_statement_lines l where l.statement_id = (select id from test.od_cs) and l.level = 'total'));
update company_statements set status = 'final', ties_ok = true, finalized_by = test.id('od_admin'), finalized_at = now() where statement_month = '2027-02-01';
select app.build_company_statement(date '2027-03-01', test.id('od_admin'));
select test.eq('adjustments: March does not repeat what February already showed',
  (select count(*) from company_statements cs, jsonb_array_elements(cs.sections) s, jsonb_array_elements(s -> 'rows') r
    where cs.statement_month = '2027-03-01' and s ->> 'key' = 'adjustments' and r ->> 'month' = '2027-01' and r ->> 'column' = 'insurance_fees_cents'), 0::bigint);

-- ---------------------------------------------------------------- 11. owner statement email day
select test.eq('owner statements: an approved statement is emailed on owner_statement_email_day of the following month',
  (select bool_and((x ->> 'due')::date = (date_trunc('month', s.statement_month) + interval '1 month')::date + 9)
     from owner_statements s cross join lateral jsonb_array_elements(app.statement_mail_due(app.local_midnight((date_trunc('month', s.statement_month) + interval '1 month')::date + 9) + interval '12 hours')) x
    where s.status in ('approved', 'paid') and s.sent_at is null and x ->> 'key' = s.id::text), true);

-- ---------------------------------------------------------------- 12. privileges
select test.throws('privileges: a browser session cannot claim debits', $$set local role authenticated; select app.owner_debit_claim(now(), 1)$$, 'permission denied');
select test.throws('privileges: nor report a result', $$set local role authenticated; select public.server_owner_debit_result('pi_x', '{}')$$, 'permission denied');
select test.eq('privileges: row-level security on the three new tables',
  (select count(*) from pg_class where relname in ('owner_debit_runs', 'owner_debit_notices', 'owner_debit_attempts') and relrowsecurity), 3::bigint);
select test.eq('privileges: each new table is audited',
  (select count(*) from pg_trigger where tgname in ('audit_owner_debit_runs', 'audit_owner_debit_notices', 'audit_owner_debit_attempts')), 3::bigint);

-- ---------------------------------------------------------------- 13. 0038: a run of test owners only stays with the verification accounts
insert into owner_debit_runs (id, run_on, kind, submitted) values (test.id('od_test_run'), date '2027-07-15', 'debit', 1);
update owner_debit_attempts set run_id = test.id('od_test_run') where id = test.od_att('iC');
select app.ntf_emit('staff_owner_debit_run', 'owner_debit_run', test.id('od_test_run'), 'summary', '{}'::jsonb);
select app.process_events(100000);
select test.eq('0038: the summary of a run of test owners only goes to the verification Admin',
  (select string_agg(distinct to_address, ',') from notification_outbox where code = 'staff_owner_debit_run' and entity_id = test.id('od_test_run')), 'verify-admin@carmacars.ca');
select test.eq('0038: a run with a real owner goes to every Admin',
  (select count(distinct to_address) > 1 from notification_outbox o join owner_debit_runs r on r.id = o.entity_id where o.code = 'staff_owner_debit_run' and r.run_on = '2027-06-15'), true);
select test.eq('0038: a debit accepted after a passing error no longer shows that error',
  (select coalesce(failure_message, 'none') from owner_debit_attempts where processor_intent_id = 'pi_od_X1'), 'none');
-- a webhook before the run recorded the PaymentIntent (0038); a new invoice of the owner to debit
insert into owner_invoices (owner_id, vehicle_id, kind, billing_date, status) values (test.id('owner:od_olga'), test.id('vehicle:ODA'), 'adjustment', date '2027-08-01', 'draft');
insert into test.od select 'iY', id from owner_invoices where vehicle_id = test.id('vehicle:ODA') and kind = 'adjustment' and billing_date = '2027-08-01';
insert into owner_invoice_lines (owner_invoice_id, kind, description, amount_cents, hst_applies, hst_cents) values (test.odv('iY'), 'adjustment', 'Registry cost', 10000, true, 1300);
update owner_invoices set status = 'issued' where id = test.odv('iY');
select app.owner_debit_schedule(test.id('owner:od_olga'), date '2027-08-15', null, null, date '2027-08-01');
select app.record_owner_payment_method(test.id('owner:od_olga'), null, jsonb_build_object('kind', 'pre_authorized_debit', 'last4', '2222',
  'processor_customer_id', 'cus_od_olga', 'processor_method_id', 'pm_od_olga3', 'processor_mandate_id', 'mandate_od_olga3'));
select app.owner_debit_schedule(test.id('owner:od_olga'), date '2027-08-15', null, null, date '2027-08-01');
create table test.od_race as select (x ->> 'attempt_id')::uuid as a from jsonb_array_elements(app.owner_debit_claim(test.od_at('2027-08-15 07:00'), 100)) x
  where (x #>> '{metadata,owner_id}')::uuid = test.id('owner:od_olga') limit 1;
select test.eq('0038: a succeeded webhook that arrives before the run recorded the PaymentIntent settles the debit',
  app.owner_debit_result('pi_od_race', jsonb_build_object('status', 'succeeded', 'attempt_id', (select a from test.od_race))) ->> 'status', 'succeeded');
select test.eq('0038: the run''s own record afterwards is a replay',
  app.owner_debit_submitted((select a from test.od_race), '{"intent_id":"pi_od_race","status":"processing"}') ->> 'repeat', 'true');

-- ---------------------------------------------------------------- 14. 0039: the PDF of an owner without a sign-in
insert into owners (id, owner_type, legal_name, status, email) values (test.id('owner:od_nosign'), 'individual', 'Od Nosign', 'active', 'od_nosign@example.test');
insert into owner_statements (id, owner_id, statement_month, payout_date, status, approved_by) values (test.id('od_nosign_st'), test.id('owner:od_nosign'), date '2027-01-01', date '2027-02-10', 'approved', test.id('od_admin'));
select test.eq('0039: the server reads an approved statement of an owner with no sign-in for its PDF',
  app.pdf_facts('owner_statement', test.id('od_nosign_st')::text) ->> 'statement_number', (select statement_number from owner_statements where id = test.id('od_nosign_st')));
select test.throws('0039: a signed-in stranger still cannot', format('select app.pdf_facts(%L, %L, %L)', 'owner_statement', test.id('od_nosign_st'), test.id('od_olga')::text), 'not available');
