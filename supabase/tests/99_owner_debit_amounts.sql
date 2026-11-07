-- 99: the owner-debit amounts in plain words, the fee check and the debit preview (migration 0584). Fixtures start with
-- "oda" or "ODA"; every address is example.test. November 2026: the run for the November 15 debit.
select test.suite('99 owner debit amounts');

select test.mk_user('oda_admin', 'admin');
select test.mk_user('oda_fin', 'va', 'finance');
select test.mk_user('oda_sales', 'va', 'sales');
select test.mk_owner('oda_olga');
-- a full month; a car enrolled on November 11 (20 of 30 days); Turo-Only; a shareholder's car; a flat monthly payment
-- all month; terms with no fees; a company car
select test.mk_vehicle('ODAFULL', 'oda_olga', 'managed', 45000, 2500, 3500, date '2026-09-01');
select test.mk_vehicle('ODAPART', 'oda_olga', 'managed', 45000, 2500, 3500, date '2026-11-11');
select test.mk_vehicle('ODATURO', 'oda_olga', 'turo_only', 0, 0, 3500, date '2026-09-01');
select test.mk_vehicle('ODASHARE', 'oda_olga', 'managed', 45000, 2500, 9000, date '2026-09-01', true);
select test.mk_vehicle('ODAFLAT', 'oda_olga', 'managed', 45000, 2500, 3500, date '2026-09-01');
select test.mk_vehicle('ODAZERO', 'oda_olga', 'managed', 0, 0, 3500, date '2026-09-01');
select test.mk_vehicle('ODACO', 'oda_olga', 'managed', 45000, 2500, 3500, date '2026-09-01');
-- no tracker installed yet: no Tracker Fee (0239); the fee check agrees (0601)
select test.mk_vehicle('ODANOTRK', 'oda_olga', 'managed', 45000, 2500, 3500, date '2026-09-01');
update vehicles set tracker_installed_on = null where id = test.id('vehicle:ODANOTRK');
update vehicles set supply_type = 'company' where id = test.id('vehicle:ODACO');
select app.door(test.id('oda_admin'), 'aal2', 'ops_do', 'car_pay_set', jsonb_build_object('vehicle_id', test.id('vehicle:ODAFLAT'), 'arrangement', 'flat_monthly',
  'monthly_cents', 90000, 'from', '2026-09-01', 'reason', 'Cohost wants a flat amount'));

select app.generate_owner_invoices(date '2026-11-15');
create temp table oda_inv as
  select v.plate_label, i.* from owner_invoices i
    join (values ('ODAFULL'), ('ODAPART'), ('ODATURO'), ('ODASHARE'), ('ODAFLAT'), ('ODAZERO'), ('ODACO'), ('ODANOTRK')) v(plate_label) on i.vehicle_id = test.id('vehicle:' || v.plate_label)
   where i.kind = 'monthly' and i.period_month = date '2026-11-01' and i.status <> 'void';

select test.eq('a flat-rate or no-fee plan is never invoiced a monthly fee: only the two cars with fees are',
  (select string_agg(plate_label, ',' order by plate_label) from oda_inv), 'ODAFULL,ODANOTRK,ODAPART');
select test.eq('no tracker installed: the Insurance Fee only', (select fees_cents from oda_inv where plate_label = 'ODANOTRK'), 45000::bigint);
select test.eq('the car enrolled on the 11th: 20 of 30 days', (select days_billed || '/' || days_in_month from oda_inv where plate_label = 'ODAPART'), '20/30');

-- ================================================================ the plain line
create temp table oda_plain as select plate_label, app.owner_invoice_plain(id, false) j, app.owner_invoice_plain(id, true) s from oda_inv;
select test.eq('the fee as the agreement words it, and its period', (select (j ->> 'fee') || ' / ' || (j ->> 'period') from oda_plain where plate_label = 'ODAPART'), 'monthly fee / November 2026');
select test.ok('how it was worked out: prorated, 20 of 30 days', (select j ->> 'how' like 'prorated: 20 of 30 days%' from oda_plain where plate_label = 'ODAPART'));
select test.ok('a full month says so', (select j ->> 'how' like 'full month%' from oda_plain where plate_label = 'ODAFULL'));
select test.ok('the line names the amount, the car, the fee and the period',
  (select j ->> 'line' ilike '$%: % c 300 odapart, monthly fee, november 2026' from oda_plain where plate_label = 'ODAPART'), (select j ->> 'line' from oda_plain where plate_label = 'ODAPART'));
select test.ok('the owner''s link is the invoice page, the staff''s the owner in Admin',
  (select j ->> 'url' like '%/owner/invoices/' || (j ->> 'invoice_number') and s ->> 'url' like '%/admin/owners/%#inv-' || (s ->> 'invoice_number') from oda_plain where plate_label = 'ODAFULL'));

-- in the emails: the debit list of a notice and the staff email carry the line for each amount
create or replace function test.oda_payload(p_code text, p_kind text) returns jsonb language plpgsql as $$
declare v bigint := app.ntf_emit(p_code, 'owner', test.id('owner:oda_olga'), 'oa-' || p_code, jsonb_build_object('owner_id', test.id('owner:oda_olga'), 'exception', p_kind));
begin
  return (select app.notification_payload(p_code, e, '{}'::jsonb) from app_events e where e.id = v);
end $$;
update owner_invoices set status = 'issued', issued_at = now() where id in (select id from oda_inv) and status = 'draft';
select test.ok('the owner''s email: each amount with its car, fee, period, how and link',
  (select bool_and(e ? 'line' and e ? 'how' and e ? 'url' and e ? 'period') and count(*) = 3
     from jsonb_array_elements(test.oda_payload('owner_debit_setup_needed', null) -> 'debit_items') e));
select test.ok('the staff email too, with the Admin link',
  (select bool_and(e ->> 'url' like '%/admin/owners/%') and count(*) = 3 from jsonb_array_elements(test.oda_payload('staff_owner_debit_exception', 'no_mandate') -> 'debit_items') e));

-- ================================================================ the fee check
create temp table oda_ref as select 'owner ' || left(md5(test.id('owner:oda_olga')::text), 6) as ref;
create temp table oda_audit as select app.owner_fee_audit(date '2026-11-01') a;
select test.eq('the fee check lists the owner''s November invoices', (select count(*) from oda_audit, jsonb_array_elements(a -> 'rows') e, oda_ref where e ->> 'owner' = ref and e ->> 'kind' = 'monthly'), 3::bigint);
select test.eq('and finds nothing wrong with them (no Tracker Fee before the tracker is installed, as billed)', (select count(*) from oda_audit, jsonb_array_elements(a -> 'problems') e, oda_ref where e ->> 'owner' = ref), 0::bigint);
select test.ok('it never names an owner', (select not (a::text ~* 'oda olga|oda_olga|example\.test') from oda_audit));
-- an invoice that should not be: a monthly fee on the Turo-Only car and on the flat car, and a wrong amount (written
-- around the invoice rules, as a bad production row would be)
set session_replication_role = replica;
insert into owner_invoices (id, owner_id, vehicle_id, kind, period_month, days_billed, days_in_month, billing_date, status)
values (test.id('inv:oda_turo'), test.id('owner:oda_olga'), test.id('vehicle:ODATURO'), 'monthly', date '2026-11-01', 30, 30, date '2026-11-15', 'issued'),
       (test.id('inv:oda_flat'), test.id('owner:oda_olga'), test.id('vehicle:ODAFLAT'), 'monthly', date '2026-11-01', 30, 30, date '2026-11-15', 'issued');
insert into owner_invoice_lines (owner_invoice_id, kind, description, amount_cents, hst_applies, hst_cents) values
  (test.id('inv:oda_turo'), 'insurance_fee', 'Insurance Fee, November 2026 (30 of 30 days)', 45000, true, 5850),
  (test.id('inv:oda_flat'), 'insurance_fee', 'Insurance Fee, November 2026 (30 of 30 days)', 45000, true, 5850);
update owner_invoice_lines set amount_cents = amount_cents + 1000 where owner_invoice_id = (select id from oda_inv where plate_label = 'ODAFULL') and kind = 'insurance_fee';
reset session_replication_role;
create temp table oda_audit2 as select app.owner_fee_audit(date '2026-11-01') a;
select test.eq('the fee check lists each invoice that does not match the agreement, with why',
  (select string_agg(e ->> 'problem', ' | ' order by e ->> 'problem') from oda_audit2, jsonb_array_elements(a -> 'problems') e, oda_ref where e ->> 'owner' = ref),
  'billed $485.00 before HST, the terms give $475.00 (30 of 30 days) | every day on a flat monthly payment: no monthly fee | no fees on this car''s plan (turo-only)');
select test.ok('it changes nothing', (select count(*) = 2 from owner_invoices where id in (test.id('inv:oda_turo'), test.id('inv:oda_flat')) and status = 'issued'));
select test.ok('the deploy reads it with the service key only', not has_function_privilege('authenticated', 'public.server_owner_fee_audit(date)', 'execute'));
-- put back: the rest of the suite sees the invoices as the run made them
set session_replication_role = replica;
delete from owner_invoice_lines where owner_invoice_id in (test.id('inv:oda_turo'), test.id('inv:oda_flat'));
delete from owner_invoices where id in (test.id('inv:oda_turo'), test.id('inv:oda_flat'));
update owner_invoice_lines set amount_cents = amount_cents - 1000 where owner_invoice_id = (select id from oda_inv where plate_label = 'ODAFULL') and kind = 'insurance_fee';
reset session_replication_role;

-- ================================================================ the debit preview
create temp table oda_prev as select app.door(test.id('oda_fin'), 'aal2', 'ops_read', 'owner_debit_preview', jsonb_build_object('on', '2026-11-15')) p;
select test.eq('each owner: the invoices, why each is charged, whether a bank debit is set up',
  (select jsonb_array_length(o -> 'invoices') || ':' || (o ->> 'debit_set_up') || ':' || ((o -> 'invoices' -> 0) ? 'how')::text
     from oda_prev, jsonb_array_elements(p -> 'owners') o where (o ->> 'id')::uuid = test.id('owner:oda_olga')), '3:false:true');
select test.throws('Sales do not see it', format($$select app.door(%L, 'aal2', 'ops_read', 'owner_debit_preview', '{}')$$, test.id('oda_sales')), 'Not permitted');
