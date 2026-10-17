-- 33: the owner's legal review (migrations 0052 and 0053), "CarmaCars: legal text changes before launch". Fixtures start
-- with "lr". Each block quotes the approved item it checks. Instants are Toronto times through test.lr_at.
select test.suite('33 legal review');
grant usage on schema test to service_role;
create or replace function test.lr_at(p text) returns timestamptz language sql immutable as $$ select (p::timestamp at time zone 'America/Toronto') $$;
grant execute on function test.lr_at(text) to service_role, authenticated;
create table test.lr (k text primary key, v jsonb);
grant select on test.lr to service_role, authenticated;
create function test.lrv(p text) returns jsonb language sql stable as $$ select v from test.lr where k = p $$;
create function test.lr_sha(p text) returns text language sql immutable as $$ select md5(p) || md5(p || 'lr') $$;

select test.mk_user('lr_admin', 'admin');
select test.mk_user('lr_cs', 'va', 'cs');

-- ================================================================ 1. billing and pre-authorized debit
-- Payee name: "[company legal name], operating as CarmaCars"
select test.eq('payee: the legal name, operating as CarmaCars', app.owner_payee_name(), (select company_legal_name from app.settings()) || ', operating as CarmaCars');
select test.eq('payee: in the PAD agreement''s first paragraph (1.2)', app.owner_debit_terms() #>> '{agreement,personal,0}' like 'You authorize ' || app.owner_payee_name() || ', to debit the bank account you give%', true);
-- Stripe mandate description (1.3)
select test.eq('mandate description (1.3), word for word', app.owner_mandate_description(),
  (select company_legal_name from app.settings()) || ' o/a CarmaCars: fees on your CarmaCars invoices on the 15th of each month, with notice 10 days before. A debit returned for insufficient funds is retried once for the same amount.');
-- New [Late Fee rule] text
select test.eq('Late Fee rule, word for word', app.owner_late_fee_rule(),
  'If your bank returns the automatic debit of an invoice for insufficient funds, we add the $50.00 Late Fee to that invoice once and try the original amount again within 30 days, as section 4.4 of your Enrollment Agreement sets out. The Late Fee is collected with your next debit.');
select test.eq('Late Fee rule: the second paragraph of the PAD agreement, both forms', (app.owner_debit_terms() #>> '{agreement,personal,1}') || '|' || (app.owner_debit_terms() #>> '{agreement,business,1}'),
  app.owner_late_fee_rule() || '|' || app.owner_late_fee_rule());
select test.ok('Late Fee rule: no catalogue email keeps the old rule', not exists (select 1 from notification_catalogue where concat(subject, preheader, trigger_text) like '%try again from the%'));

-- two owners on the automatic debit: Nora (her bank returns for insufficient funds) and Carl (his account is closed)
select test.mk_owner('lr_nora');
select test.mk_owner('lr_carl');
select test.mk_vehicle('LRN', 'lr_nora', p_enrolled => date '2026-09-01');
select test.mk_vehicle('LRC', 'lr_carl', p_enrolled => date '2026-09-01');
update owners set auto_debit_paused = true, auto_debit_paused_reason = 'other suites' where id not in (test.id('owner:lr_nora'), test.id('owner:lr_carl'));
insert into owner_invoices (owner_id, vehicle_id, kind, period_month, billing_date, status)
select v.owner_id, v.id, 'monthly', date '2028-03-01', date '2028-03-15', 'draft' from vehicles v where v.id in (test.id('vehicle:LRN'), test.id('vehicle:LRC'));
insert into owner_invoice_lines (owner_invoice_id, kind, description, amount_cents, hst_applies, hst_cents)
select i.id, 'adjustment', 'March fees', 47500, true, 6175 from owner_invoices i where i.vehicle_id in (test.id('vehicle:LRN'), test.id('vehicle:LRC')) and i.period_month = '2028-03-01';
update owner_invoices set status = 'issued' where vehicle_id in (test.id('vehicle:LRN'), test.id('vehicle:LRC'));
insert into test.lr select 'inv_n', to_jsonb((select id from owner_invoices where vehicle_id = test.id('vehicle:LRN') and period_month = '2028-03-01'));
insert into test.lr select 'inv_c', to_jsonb((select id from owner_invoices where vehicle_id = test.id('vehicle:LRC') and period_month = '2028-03-01'));
insert into test.lr select 'bal_n', to_jsonb((select balance_cents from owner_invoices where id = (test.lrv('inv_n') #>> '{}')::uuid));
create function test.inv(p text) returns owner_invoices language sql stable as $$ select * from owner_invoices where id = (test.lrv(p) #>> '{}')::uuid $$;
create function test.att(p text) returns owner_debit_attempts language sql stable as $$
  select * from owner_debit_attempts where owner_invoice_id = (test.lrv(p) #>> '{}')::uuid order by attempt_no desc, created_at desc limit 1 $$;
select app.record_owner_payment_method(test.id('owner:lr_nora'), null, jsonb_build_object('kind', 'pre_authorized_debit', 'brand_or_bank', 'Test Bank',
  'last4', '2227', 'processor_customer_id', 'cus_lr_nora', 'processor_method_id', 'pm_lr_nora', 'processor_mandate_id', 'mandate_lr_nora'));
select app.record_owner_payment_method(test.id('owner:lr_carl'), null, jsonb_build_object('kind', 'pre_authorized_debit', 'brand_or_bank', 'Test Bank',
  'last4', '3335', 'processor_customer_id', 'cus_lr_carl', 'processor_method_id', 'pm_lr_carl', 'processor_mandate_id', 'mandate_lr_carl'));
select app.owner_debit_schedule(test.id('owner:lr_nora'), date '2028-03-15', null, null, date '2028-03-01');
select app.owner_debit_schedule(test.id('owner:lr_carl'), date '2028-03-15', null, null, date '2028-03-01');
select count(*) from jsonb_array_elements(app.owner_debit_claim(test.lr_at('2028-03-15 07:00'), 100));
select app.owner_debit_submitted((test.att('inv_n')).id, '{"intent_id":"pi_lr_n1","status":"processing"}');
select app.owner_debit_submitted((test.att('inv_c')).id, '{"intent_id":"pi_lr_c1","status":"processing"}');

-- 6.1 Stripe test NSF return: one retry, original amount, Late Fee as a separate invoice line, shown in the next pre-debit notice
select app.owner_debit_result('pi_lr_n1', '{"status":"requires_payment_method","error_code":"insufficient_funds","error_message":"The customer''s account has insufficient funds to cover this payment."}');
select test.eq('NSF: the invoice failed; the $50.00 Late Fee is its own line, "Late Fee", once',
  (select (test.inv('inv_n')).status || '/' || string_agg(description || ':' || amount_cents, ',') from owner_invoice_lines where owner_invoice_id = (test.inv('inv_n')).id and kind = 'late_fee'),
  'failed/Late Fee:5000');
select test.eq('NSF: one retry, for the original invoice amount only, on the later of the 18th and 3 business days after the return',
  (select a.is_retry || '/' || a.status || '/' || (a.amount_cents = (test.lrv('bal_n'))::bigint) || '/' || a.debit_on || '/' || a.original_debit_on
     from owner_debit_attempts a where a.id = (test.att('inv_n')).id),
  'true/scheduled/true/' || greatest(date '2028-03-18', app.add_business_days(app.today(), 3)) || '/2028-03-15');
select test.eq('NSF: the owner gets the failed-debit email (not the returned one)',
  (select count(*) filter (where code = 'owner_payment_failed') || '/' || count(*) filter (where code = 'owner_debit_returned') from app_events
    where entity_id in ((test.inv('inv_n')).id, (test.att('inv_n')).id) or (code = 'owner_debit_returned' and payload ->> 'owner_id' = test.id('owner:lr_nora')::text)), '1/0');
select app.process_events(100000);
select test.eq('NSF: the failed-debit email (7.4) names the original amount and the retry date',
  (select (payload ->> 'amount') || '/' || (payload ->> 'retry_amount') || '/' || (payload ->> 'retry_date') || '/' || (payload ->> 'late_fee')
     from notification_outbox where code = 'owner_payment_failed' and entity_id = (test.inv('inv_n')).id order by created_at desc limit 1),
  app.fmt_money((test.lrv('bal_n'))::bigint) || '/' || app.fmt_money((test.lrv('bal_n'))::bigint) || '/' || app.fmt_day(greatest(date '2028-03-18', app.add_business_days(app.today(), 3))) || '/$50.00');
select test.eq('NSF: the failed-debit email''s copy, as approved',
  (select (preheader = 'A {{late_fee}} late fee is added to your next debit. We retry {{amount}} on or after {{retry_date}}.') from notification_catalogue where code = 'owner_payment_failed'), true);
create table test.lr_retry as select x from jsonb_array_elements(app.owner_debit_claim(test.lr_at('2028-03-18 07:00'), 100)) x
  where (x #>> '{metadata,owner_id}')::uuid = test.id('owner:lr_nora');
grant select on test.lr_retry to service_role;
select test.eq('NSF: the retry debits the original amount, never the Late Fee', (select (x ->> 'amount_cents')::bigint from test.lr_retry), (test.lrv('bal_n'))::bigint);
select app.owner_debit_submitted((test.att('inv_n')).id, '{"intent_id":"pi_lr_n2","status":"processing"}');
insert into test.lr select 'n2', app.owner_debit_result('pi_lr_n2', '{"status":"succeeded","charge_id":"py_lr_n2"}');
select test.eq('NSF: the retry clears: the fees are paid, the Late Fee waits on the invoice (issued)',
  (test.lrv('n2') ->> 'status') || '/' || (test.inv('inv_n')).status || '/' || (test.inv('inv_n')).balance_cents, 'succeeded/issued/5000');
select test.eq('NSF: the next pre-debit notice lists the Late Fee and the next scheduled debit collects it',
  (select (r ->> 'invoices') || '/' || (r ->> 'total_cents') from (select app.owner_debit_schedule(test.id('owner:lr_nora'), date '2028-04-15', null, null, date '2028-04-01') r) x), '1/5000');
select test.eq('NSF: the notice reads "Late Fee" for that invoice',
  (select e ->> 'covers' from app_events ev cross join lateral jsonb_array_elements(app.notification_payload('owner_debit_notice', ev, '{"audience":"owner"}'::jsonb) -> 'debit_items') e
    where ev.code = 'owner_debit_notice' and ev.entity_id = (select id from owner_debit_notices where owner_id = test.id('owner:lr_nora') and debit_on = '2028-04-15')), 'Late Fee');

-- 6.2 Stripe test non-NSF return (account closed): no retry, invoice paused, Admin alerted, owner emailed
select app.owner_debit_result('pi_lr_c1', '{"status":"requires_payment_method","error_code":"account_closed","error_message":"The customer''s bank account has been closed."}');
select test.eq('not NSF: no retry, no Late Fee, the invoice''s automatic debit paused',
  (test.inv('inv_c')).status || '/' || (test.inv('inv_c')).late_fee_cents || '/' || (test.inv('inv_c')).auto_debit_paused || '/'
  || (select count(*) from owner_debit_attempts a where a.owner_invoice_id = (test.inv('inv_c')).id and a.status = 'scheduled'), 'failed/0/true/0');
select test.eq('not NSF: an Admin is alerted (task and exception email) and the owner is emailed (no "we retry" email)',
  (select count(*) from tasks t where t.related_id = (test.inv('inv_c')).id and t.task_type = 'owner_debit_returned' and t.queue = 'admin') || '/'
  || (select count(*) from app_events e where e.entity_id = (test.att('inv_c')).id and e.code = 'staff_owner_debit_exception') || '/'
  || (select count(*) from app_events e where e.entity_id = (test.att('inv_c')).id and e.code = 'owner_debit_returned') || '/'
  || (select count(*) from app_events e where e.entity_id = (test.inv('inv_c')).id and e.code = 'owner_payment_failed'), '1/1/1/0');
select test.eq('not NSF: the invoice keeps no retry date (0056) and the Admin task reads the reason once',
  coalesce((test.inv('inv_c')).retry_on::text, 'none') || '/' || (select (detail like '%has been closed. It is not retried%')::text from tasks t where t.related_id = (test.inv('inv_c')).id and t.task_type = 'owner_debit_returned'),
  'none/true');
select test.eq('the finance task for a failed debit no longer says "retry on the 18th" (0056)',
  (select description from task_rules where task_type = 'debit_failed') like 'Insufficient funds: the Late Fee is added and the original amount is tried once more within 30 days.%', true);
select app.process_events(100000);
select test.eq('not NSF: the owner''s email names the debit and the bank''s reason',
  (select (payload ->> 'debit_date') || ' / ' || (payload ->> 'bank_reason') from notification_outbox where code = 'owner_debit_returned' and entity_id = (test.att('inv_c')).id),
  app.fmt_day(date '2028-03-15') || ' / The customer''s bank account has been closed.');
select test.eq('not NSF: the debit is not tried again on the next debit day', (select r ->> 'invoices' from (select app.owner_debit_schedule(test.id('owner:lr_carl'), date '2028-04-15', null, null, date '2028-04-01') r) x), '0');

-- a return too late for a retry within 30 days of the original debit: the Late Fee stays, no retry, paused
insert into owner_invoices (owner_id, vehicle_id, kind, billing_date, status) values (test.id('owner:lr_nora'), test.id('vehicle:LRN'), 'adjustment', app.today() - 45, 'draft');
insert into test.lr select 'inv_late', to_jsonb((select id from owner_invoices where vehicle_id = test.id('vehicle:LRN') and kind = 'adjustment' order by created_at desc limit 1));
insert into owner_invoice_lines (owner_invoice_id, kind, description, amount_cents, hst_applies, hst_cents) values ((test.inv('inv_late')).id, 'adjustment', 'Registry cost', 10000, true, 1300);
update owner_invoices set status = 'issued' where id = (test.inv('inv_late')).id;
update owner_invoices set status = 'processing' where id = (test.inv('inv_late')).id;
insert into owner_debit_attempts (owner_invoice_id, owner_id, attempt_no, debit_on, amount_cents, idempotency_key, status)
values ((test.inv('inv_late')).id, test.id('owner:lr_nora'), 1, app.today() - 40, 11300, 'lr-late', 'processing');
insert into test.lr select 'late', app.owner_debit_fail((test.att('inv_late')).id, 'insufficient_funds', 'insufficient funds');
select test.eq('NSF too late (more than 30 days after the debit): no retry, the Late Fee once, paused',
  (test.lrv('late') ->> 'retry') || '/' || (test.inv('inv_late')).late_fee_cents
  || '/' || (test.inv('inv_late')).auto_debit_paused, 'false/5000/true');

-- attempts per invoice 1: the Late Fee and the amount come off the next payout
update program_settings set owner_debit_max_attempts = 1 where id = (app.settings()).id;
select test.eq('one attempt: the Late Fee rule says it is deducted from the next payout', app.owner_late_fee_rule() like '%The Late Fee and the amount owed are deducted from your next payout.', true);
select test.eq('one attempt: the mandate description has no retry', app.owner_mandate_description() like '%with notice 10 days before.', true);
insert into owner_invoices (owner_id, vehicle_id, kind, billing_date, status) values (test.id('owner:lr_nora'), test.id('vehicle:LRN'), 'adjustment', date '2028-05-01', 'draft');
insert into test.lr select 'inv_one', to_jsonb((select id from owner_invoices where vehicle_id = test.id('vehicle:LRN') and kind = 'adjustment' and billing_date = '2028-05-01'));
insert into owner_invoice_lines (owner_invoice_id, kind, description, amount_cents, hst_applies, hst_cents) values ((test.inv('inv_one')).id, 'adjustment', 'Plate renewal', 12000, true, 1560);
update owner_invoices set status = 'issued' where id = (test.inv('inv_one')).id;
update owner_invoices set status = 'processing' where id = (test.inv('inv_one')).id;
insert into owner_debit_attempts (owner_invoice_id, owner_id, attempt_no, debit_on, amount_cents, idempotency_key, status)
values ((test.inv('inv_one')).id, test.id('owner:lr_nora'), 1, date '2028-05-15', 13560, 'lr-one', 'processing');
insert into test.lr select 'one', app.owner_debit_fail((test.att('inv_one')).id, 'insufficient_funds', 'insufficient funds');
select test.eq('one attempt: in arrears with the Late Fee, deducted from the next payout', (test.lrv('one') ->> 'invoice_status') || '/' || (test.inv('inv_one')).late_fee_cents, 'in_arrears/5000');
update program_settings set owner_debit_max_attempts = 2 where id = (app.settings()).id;
select test.throws('settings: more than one retry is not allowed', format($$update program_settings set owner_debit_max_attempts = 3 where id = %L$$, (app.settings()).id), 'owner_debit_max_attempts');

-- 6.3 Invoice-page PAD flow: unticking the second box creates no recurring mandate
insert into owner_invoices (owner_id, vehicle_id, kind, billing_date, status) values (test.id('owner:lr_carl'), test.id('vehicle:LRC'), 'adjustment', date '2028-06-01', 'draft');
insert into test.lr select 'inv_pay', to_jsonb((select id from owner_invoices where vehicle_id = test.id('vehicle:LRC') and kind = 'adjustment' and billing_date = '2028-06-01'));
insert into owner_invoice_lines (owner_invoice_id, kind, description, amount_cents, hst_applies, hst_cents) values ((test.inv('inv_pay')).id, 'adjustment', 'Registry cost', 10000, true, 1300);
update owner_invoices set status = 'issued' where id = (test.inv('inv_pay')).id;
create table test.lr_pm as select count(*) as n from owner_payment_methods where owner_id = test.id('owner:lr_carl') and kind = 'pre_authorized_debit' and status = 'active';
grant select on test.lr_pm to service_role;
insert into test.lr select 'once', public.server_record_owner_invoice_payment((test.inv('inv_pay')).id, jsonb_build_object('status', 'succeeded', 'method', 'pre_authorized_debit', 'amount_cents', 11300,
    'processor', jsonb_build_object('payment_id', 'pi_lr_once', 'customer_id', 'cus_lr_carl', 'method_id', 'pm_lr_once', 'mandate_id', 'mandate_lr_once'),
    'bank', jsonb_build_object('name', 'Test Bank', 'last4', '1111'), 'save_method', false), test.id('lr_carl'));
select test.eq('one-time debit only (the recurring box unticked): the invoice is paid, no mandate is kept, no confirmation is sent',
  (test.lrv('once') ->> 'invoice_status')
  || '/' || ((select count(*) from owner_payment_methods where owner_id = test.id('owner:lr_carl') and kind = 'pre_authorized_debit' and status = 'active') = (select n from test.lr_pm))
  || '/' || (select count(*) from owner_payment_methods m join owner_payment_method_secrets s on s.owner_payment_method_id = m.id where s.processor_mandate_id = 'mandate_lr_once'),
  'paid/true/0');
insert into owner_invoices (owner_id, vehicle_id, kind, billing_date, status) values (test.id('owner:lr_carl'), test.id('vehicle:LRC'), 'adjustment', date '2028-06-02', 'draft');
insert into test.lr select 'inv_pay2', to_jsonb((select id from owner_invoices where vehicle_id = test.id('vehicle:LRC') and kind = 'adjustment' and billing_date = '2028-06-02'));
insert into owner_invoice_lines (owner_invoice_id, kind, description, amount_cents, hst_applies, hst_cents) values ((test.inv('inv_pay2')).id, 'adjustment', 'Registry cost', 10000, true, 1300);
update owner_invoices set status = 'issued' where id = (test.inv('inv_pay2')).id;
insert into test.lr select 'rec', public.server_record_owner_invoice_payment((test.inv('inv_pay2')).id, jsonb_build_object('status', 'succeeded', 'method', 'pre_authorized_debit', 'amount_cents', 11300,
    'processor', jsonb_build_object('payment_id', 'pi_lr_rec', 'customer_id', 'cus_lr_carl', 'method_id', 'pm_lr_rec', 'mandate_id', 'mandate_lr_rec'),
    'bank', jsonb_build_object('name', 'Test Bank', 'last4', '2222'), 'save_method', true), test.id('lr_carl'));
select test.eq('recurring box ticked: the mandate is kept and the confirmation (1.5) is sent once',
  (test.lrv('rec') ->> 'invoice_status')
  || '/' || (select count(*) from owner_payment_methods m join owner_payment_method_secrets s on s.owner_payment_method_id = m.id where s.processor_mandate_id = 'mandate_lr_rec' and m.status = 'active')
  || '/' || (select count(*) from app_events e where e.code = 'owner_pad_confirmed' and e.entity_id in (select m.id from owner_payment_methods m join owner_payment_method_secrets s on s.owner_payment_method_id = m.id where s.processor_mandate_id = 'mandate_lr_rec')),
  'paid/1/1');
select app.process_events(100000);
select test.eq('confirmation (1.5): the payee, and the full text of the accepted recurring agreement below the summary',
  (select (payload ->> 'payee_name') || '|' || (payload ->> 'agreement_1') || '|' || (payload ->> 'agreement_2') from notification_outbox where code = 'owner_pad_confirmed' and to_address = 'lr_carl@example.test' order by created_at desc limit 1),
  app.owner_payee_name() || '|' || (app.owner_debit_terms() #>> '{agreement,personal,0}') || '|' || app.owner_late_fee_rule());
-- Void notice (6.2)
select test.ok('void notice (6.2): the approved sentence and its values',
  exists (select 1 from notification_catalogue c where c.code = 'owner_payment_reversed' and c.variables @> '[{"name":"debit_date"}]'::jsonb));

-- ================================================================ 2. signatures
-- 6.4 the corporate countersignature with the signing officer's name; staff appear only as "Proposed by" or "Added by"
select test.eq('countersignature wording, as approved', app.corporate_signature_text(),
  format('Signed electronically for %s, operating as CarmaCars, by %s, %s, under a standing authorization dated %s.',
         (select company_legal_name from app.settings()), (select signing_officer_name from app.settings()), (select signing_officer_title from app.settings()),
         (select to_char(signing_officer_authorized_on, 'FMMonth FMDD, YYYY') from app.settings())));
select test.eq('every automatic countersignature made since 0053 has the approved wording, in the signing officer''s name (method "automatic")',
  (select count(*) from signature_records r where r.signer_role = 'carmacars' and r.method = 'automatic' and r.consent_text not like 'Signed electronically for %, operating as CarmaCars%'), 0::bigint);
select test.eq('no automatic countersignature names a staff member as the signer',
  (select count(*) from signature_records r where r.signer_role = 'carmacars' and r.method = 'automatic' and r.signer_user_id is not null
      and r.signer_user_id is distinct from (select signing_officer_user_id from app.settings())), 0::bigint);
select test.eq('staff are recorded only as "Proposed by: <name>" or "Added by: <name>"',
  (select count(*) from signature_records where staff_attribution is not null and staff_attribution !~ '^(Proposed by|Added by): .+'), 0::bigint);

-- 6.5 two-owner enrollment: two signing links, two signature records, agreements effective only after both sign
insert into users (id, email, full_name) values (test.id('lr_olive'), 'olive.lr@example.test', 'Olive Owner');
create function test.lr_vin(p text) returns text language sql immutable as $$ select upper(substr(md5('lr-vin-' || p), 1, 17)) $$;
insert into test.lr select 'app', to_jsonb((public.server_submit_owner_application(jsonb_build_object('source', 'web',
  'owner', jsonb_build_object('owner_type', 'individual', 'legal_name', 'Olive Owner', 'first_name', 'Olive', 'last_name', 'Owner', 'email', 'olive.lr@example.test',
                              'phone', '+16475550111', 'address_line1', '20 King Street West', 'city', 'Toronto', 'province', 'ON', 'postal_code', 'M5H 1A1',
                              'licence_number', 'O1234-56789-01299', 'date_of_birth', '1984-04-04'),
  'vehicles', jsonb_build_array(
    jsonb_build_object('vin', test.lr_vin('1'), 'plate', 'LRAA101', 'year', 2022, 'make', 'Toyota', 'model', 'Camry', 'colour', 'White', 'odometer_km', 20000,
                       'title_status', 'owned_outright', 'management_mode', 'managed', 'onboarding_method', 'transfer', 'current_insurer', 'Intact', 'title_brand_clear', true),
    jsonb_build_object('vin', test.lr_vin('2'), 'plate', 'LRAA102', 'year', 2023, 'make', 'Honda', 'model', 'CR-V', 'colour', 'Blue', 'odometer_km', 10000,
                       'title_status', 'financed', 'finance_party_name', 'TD Auto Finance', 'management_mode', 'managed', 'onboarding_method', 'transfer', 'current_insurer', 'Aviva'))),
  test.id('lr_olive')) ->> 'owner_id')::uuid);
create function test.lr_owner() returns uuid language sql stable as $$ select (test.lrv('app') #>> '{}')::uuid $$;
select public.admin_set_vehicle_terms(v.id, test.id('lr_admin'), '{}') from vehicles v where v.owner_id = test.lr_owner();
select test.eq('co-owner: an Admin adds the other Owner named in the Title Schedule', jsonb_array_length(public.door(test.id('lr_admin'), null, 'ops_do', 'owner_cosigner_add',
  jsonb_build_object('owner_id', test.lr_owner(), 'name', 'Colin Coowner', 'email', 'colin.lr@example.test'))), 1);
select public.owner_open_agreements(test.lr_owner(), test.id('lr_olive'), jsonb_build_array(
  jsonb_build_object('key', 'enrollment', 'template_version', 'enrollment-test', 'sha256', test.lr_sha('ea'), 'storage_path', 'owners/lr/ea.pdf'),
  jsonb_build_object('key', 'title_holding', 'template_version', 'title-test', 'sha256', test.lr_sha('ta'), 'storage_path', 'owners/lr/ta.pdf')));
select test.eq('co-owner: opening the documents emails the other Owner their own signing link', (select count(*) from app_events where code = 'owner_cosigner_sign'
  and (payload ->> 'owner_id')::uuid = test.lr_owner()), 1::bigint);
select app.process_events(100000);
select test.eq('co-owner: the link goes to the other Owner, to /sign/owner/<their token>',
  (select to_address || ' ' || (payload ->> 'sign_url' = 'https://carmacars.ca/sign/owner/' || (select token from owner_cosigners where owner_id = test.lr_owner()))
     from notification_outbox where code = 'owner_cosigner_sign' and (payload ->> 'owner_name') = 'Olive Owner'), 'colin.lr@example.test true');
select public.owner_sign_agreements(test.lr_owner(), test.id('lr_olive'), jsonb_build_object('typed_name', 'Olive Owner',
  'consent_text', 'I have read these documents and I sign them electronically. One signature for: Enrollment Agreement; Title-Holding and Lease Agreement.',
  'initials', '{"own_insurance":"OO","fees_no_income":"OO","tracker_downtime":"OO"}'::jsonb,
  'documents', jsonb_build_array(jsonb_build_object('key', 'enrollment', 'sha256', test.lr_sha('ea')), jsonb_build_object('key', 'title_holding', 'sha256', test.lr_sha('ta')))));
select test.eq('co-owner: after the first Owner signs, nothing takes effect: the agreements wait, no countersignature, the vehicles wait',
  (select string_agg(a.status || ':' || r.status, ',' order by a.kind) from owner_agreements a join signature_requests r on r.id = a.signature_request_id where a.owner_id = test.lr_owner())
  || '/' || (select count(*) from signature_records x join owner_agreements a on a.signature_request_id = x.signature_request_id where a.owner_id = test.lr_owner() and x.signer_role = 'carmacars')
  || '/' || (select count(*) from vehicle_onboardings ob join vehicles v on v.id = ob.vehicle_id where v.owner_id = test.lr_owner() and ob.status = 'documents_signed'),
  'sent:partially_signed,sent:partially_signed/0/0');
select test.eq('co-owner: the portal shows who still signs', (app.owner_signing_needed(test.lr_owner()) -> 'waiting_for') ->> 0, 'Colin Coowner');
select test.throws('co-owner: the other Owner must tick the statement', format($$select public.server_owner_cosigner_sign(%L, %L)$$,
  (select token from owner_cosigners where owner_id = test.lr_owner()), jsonb_build_object('typed_name', 'Colin Coowner', 'consent_text', 'I sign for myself and for every Owner named in them.',
  'documents', (select jsonb_agg(jsonb_build_object('signature_request_id', q.signature_request_id, 'sha256', q.sha256)) from app.owner_open_requests(test.lr_owner()) q))), 'statement');
select test.throws('co-owner: their typed name must be their own legal name', format($$select public.server_owner_cosigner_sign(%L, %L)$$,
  (select token from owner_cosigners where owner_id = test.lr_owner()), jsonb_build_object('typed_name', 'Olive Owner', 'consent_text', 'I have read these documents and I sign them electronically.',
  'documents', (select jsonb_agg(jsonb_build_object('signature_request_id', q.signature_request_id, 'sha256', q.sha256)) from app.owner_open_requests(test.lr_owner()) q))), 'full legal name');
select test.eq('co-owner: the last Owner signs with their link: the agreements take effect',
  (public.server_owner_cosigner_sign((select token from owner_cosigners where owner_id = test.lr_owner()), jsonb_build_object('typed_name', 'Colin Coowner',
     'consent_text', 'I have read these documents and I sign them electronically.', 'initials', 'CC', 'ip', '203.0.113.7', 'user_agent', 'test',
     'documents', (select jsonb_agg(jsonb_build_object('signature_request_id', q.signature_request_id, 'sha256', q.sha256)) from app.owner_open_requests(test.lr_owner()) q))) ->> 'complete'), 'true');
select test.eq('co-owner: two owner signature records and the countersignature on each document; the agreements are signed',
  (select string_agg(a.kind || ':' || a.status || ':' || (select string_agg(x.signer_role || '=' || x.signer_name, '+' order by x.created_at) from signature_records x where x.signature_request_id = a.signature_request_id), ',' order by a.kind)
     from owner_agreements a where a.owner_id = test.lr_owner()),
  'enrollment:signed:owner_individual=Olive Owner+owner_individual=Colin Coowner+carmacars=' || (select coalesce(signing_officer_name, 'CarmaCars') from app.settings())
  || ',title_holding:signed:owner_individual=Olive Owner+owner_individual=Colin Coowner+carmacars=' || (select coalesce(signing_officer_name, 'CarmaCars') from app.settings()));
select test.eq('co-owner: the link works once', public.server_owner_cosigner_sign((select token from owner_cosigners where owner_id = test.lr_owner()), '{}'::jsonb) ->> 'repeat', 'true');

-- Form C witness may sign on screen in person on the same device
insert into test.lr select 'fc', public.owner_form_c_open(test.id('lr_olive'), (select id from vehicles where vin = test.lr_vin('2')), test.lr_sha('fc'), 'owners/' || test.lr_owner() || '/forms/form-c.pdf', 'forms-cd-screen');
select test.throws('Form C on screen: the witness is another adult', format($$select public.sign_request_sign(test.id('lr_olive'), %L, %L)$$, test.lrv('fc') ->> 'id',
  jsonb_build_object('typed_name', 'Olive Owner', 'consent_text', 'I sign.', 'document_sha256', test.lr_sha('fc'), 'initials', 'OO', 'acknowledgments', '["1","2","3"]'::jsonb,
                     'witness_name', 'Olive Owner', 'witness_statement', 'I witnessed Olive Owner sign in my presence.')), 'another adult');
select test.throws('Form C on screen: the witness ticks the statement, word for word', format($$select public.sign_request_sign(test.id('lr_olive'), %L, %L)$$, test.lrv('fc') ->> 'id',
  jsonb_build_object('typed_name', 'Olive Owner', 'consent_text', 'I sign.', 'document_sha256', test.lr_sha('fc'), 'initials', 'OO', 'acknowledgments', '["1","2","3"]'::jsonb,
                     'witness_name', 'Wanda Witness', 'witness_statement', 'I saw it.')), 'I witnessed Olive Owner sign in my presence.');
select public.sign_request_sign(test.id('lr_olive'), (test.lrv('fc') ->> 'id')::uuid,
  jsonb_build_object('typed_name', 'Olive Owner', 'consent_text', 'I sign Form C electronically, in the presence of my witness.', 'document_sha256', test.lr_sha('fc'), 'initials', 'oo',
                     'acknowledgments', '["1","2","3"]'::jsonb, 'witness_name', 'Wanda Witness', 'witness_statement', 'I witnessed Olive Owner sign in my presence.'));
select test.eq('Form C on screen: the owner''s and the witness''s records (typed name and statement), the form approved',
  (select string_agg(x.signer_role || '=' || x.signer_name || coalesce(':' || x.consent_text, ''), ' | ' order by x.created_at) from signature_records x
     where x.signature_request_id = (test.lrv('fc') ->> 'signature_request_id')::uuid and x.signer_role = 'witness')
  || ' / ' || (select f.status || ':' || f.signed_method || ':' || f.witness_1_name from owner_agreement_forms f where f.owner_id = test.lr_owner() and f.form_code = 'C' and f.status = 'approved'),
  'witness=Wanda Witness:I witnessed Olive Owner sign in my presence. / approved:screen:Wanda Witness');

-- 6.7 investment agreement shows "Awaiting countersignature" until the Admin countersigns
insert into users (id, email, full_name) values (test.id('lr_ivy'), 'ivy.lr@example.test', 'Ivy Investor');
insert into investors (id, user_id, legal_name, investor_type, email, status) values (test.id('inv:lr_ivy'), test.id('lr_ivy'), 'Ivy Investor', 'individual', 'ivy.lr@example.test', 'prospect');
insert into test.lr select 'ia', public.door(test.id('lr_admin'), null, 'ops_do', 'sign_request_create', jsonb_build_object('doc_type', 'investment_agreement', 'investor_id', test.id('inv:lr_ivy'),
  'exemption_category', 'accredited_investor', 'document', jsonb_build_object('path', 'investors/lr/ia.pdf', 'sha256', test.lr_sha('ia'))));
select public.sign_request_sign(test.id('lr_ivy'), (test.lrv('ia') ->> 'id')::uuid, jsonb_build_object('typed_name', 'Ivy Investor', 'consent_text', 'I agree',
  'document_sha256', test.lr_sha('ia'), 'legal_advice_choice', 'declined', 'initials', 'II'));
select test.eq('investment: signed by the investor, not countersigned automatically: "Awaiting countersignature"',
  (select x ->> 'awaiting_countersignature' from jsonb_array_elements(public.door(test.id('lr_admin'), null, 'ops_read', 'investment_countersign_state', jsonb_build_object('investor_id', test.id('inv:lr_ivy')))) x)
  || '/' || (select count(*) from signature_records r join investment_agreements a on a.signature_request_id = r.signature_request_id where a.investor_id = test.id('inv:lr_ivy') and r.signer_role = 'carmacars')
  || '/' || (select x ->> 'awaiting_countersignature' from jsonb_array_elements(public.my_sign_requests(test.id('lr_ivy')) -> 'signed') x), 'true/0/true');
select test.throws('investment: Countersign is for Admins', format($$select public.door(test.id('lr_cs'), null, 'ops_do', 'investment_countersign', %L)$$,
  jsonb_build_object('agreement_id', (select id from investment_agreements where investor_id = test.id('inv:lr_ivy')))), '');
select public.door(test.id('lr_admin'), null, 'ops_do', 'investment_countersign', jsonb_build_object('agreement_id', (select id from investment_agreements where investor_id = test.id('inv:lr_ivy'))));
select test.eq('investment: after Countersign it is fully signed: the signing officer''s record, the request completed',
  (select x ->> 'awaiting_countersignature' from jsonb_array_elements(public.door(test.id('lr_admin'), null, 'ops_read', 'investment_countersign_state', jsonb_build_object('investor_id', test.id('inv:lr_ivy')))) x)
  || '/' || (select r.signer_name || ':' || r.method from signature_records r join investment_agreements a on a.signature_request_id = r.signature_request_id where a.investor_id = test.id('inv:lr_ivy') and r.signer_role = 'carmacars')
  || '/' || (select s.status from signature_requests s join investment_agreements a on a.signature_request_id = s.id where a.investor_id = test.id('inv:lr_ivy')),
  'false/' || (select coalesce(signing_officer_name, '-') from app.settings()) || ':typed/completed');
select test.eq('investment: a second Countersign is a replay', public.door(test.id('lr_admin'), null, 'ops_do', 'investment_countersign',
  jsonb_build_object('agreement_id', (select id from investment_agreements where investor_id = test.id('inv:lr_ivy')))) ->> 'repeat', 'true');

-- staff agreements are countersigned automatically
insert into test.lr select 'sa', public.door(test.id('lr_admin'), null, 'ops_do', 'sign_request_create', jsonb_build_object('doc_type', 'staff_agreement', 'staff_user_id', test.id('lr_cs'),
  'title', 'VA Agreement', 'document', jsonb_build_object('path', 'staff/lr/va.pdf', 'sha256', test.lr_sha('va'))));
select public.sign_request_sign(test.id('lr_cs'), (test.lrv('sa') ->> 'id')::uuid, jsonb_build_object('typed_name', 'Lr Cs', 'consent_text', 'I agree', 'document_sha256', test.lr_sha('va')));
select test.eq('staff agreement: countersigned automatically with the approved wording',
  (select r.method || '/' || (r.consent_text = app.corporate_signature_text()) from signature_records r where r.signature_request_id = (test.lrv('sa') ->> 'signature_request_id')::uuid and r.signer_role = 'carmacars'),
  'automatic/true');

-- ================================================================ 3. the Enrollment Agreement (checked in the web unit tests: 4.4, 4.5, 4.6, Schedule A)
-- ================================================================ 4. renter side: 6.6 staff-added rental, no card charge until the renter signs (30_supply_manual_rentals.sql)
select test.eq('Protection Plan: the charge renters read', (select label from fee_types where code = 'coverage_sold'), 'Protection Plan');
select test.eq('Protection Plan: no site copy calls it coverage or insurance', (select count(*) from site_content_blocks
  where coalesce(body, '') || coalesce(data::text, '') ~* '(coverage|insurance) (bought|sold|purchased) through CarmaCars|buy coverage from you'), 0::bigint);

-- ================================================================ privileges
select test.throws('privileges: a browser session cannot sign as another Owner', $$set local role authenticated; select public.server_owner_cosigner_sign('x', '{}')$$, 'permission denied');
select test.throws('privileges: nor read their link', $$set local role authenticated; select public.server_owner_cosigner_facts('x')$$, 'permission denied');
select test.eq('privileges: the new table has row-level security and is audited',
  (select relrowsecurity::text from pg_class where relname = 'owner_cosigners') || '/' || (select count(*) from pg_trigger where tgname = 'audit_owner_cosigners'), 'true/1');
