-- 99: the company statement ties a payment of an owner invoice on a car not yet enrolled (migration 0281).
-- Fixtures start with "sto"; the month is 2033-05, where no other test puts money.
select test.suite('99 statement ties owner invoice cars');
select test.mk_owner('sto_owner');
select test.mk_user('sto_fin', 'admin');
select test.mk_vehicle('sto_car', 'sto_owner', p_enrolled => date '2033-09-01');
update vehicles set enrollment_date = null, fleet_policy_added_on = null where id = test.id('vehicle:sto_car');
insert into owner_invoices (id, invoice_number, owner_id, vehicle_id, kind, billing_date, payment_method, status, fees_cents, hst_cents)
values (test.id('oi:sto'), 'OI-STO-1', test.id('owner:sto_owner'), test.id('vehicle:sto_car'), 'upfront', date '2033-05-10', 'pre_authorized_debit', 'issued', 90000, 11700);
insert into payments (id, owner_id, owner_invoice_id, purpose, kind, method, amount_cents, status, processed_at)
values (test.id('pay:sto'), test.id('owner:sto_owner'), test.id('oi:sto'), 'owner_fees', 'charge', 'e_transfer', 101700, 'succeeded', timestamptz '2033-05-12 12:00 America/Toronto');
select app.build_company_statement(date '2033-05-01', test.id('sto_fin'));
select test.eq('the car of an owner invoice paid in the month has its vehicle line, with the cash collected',
  (select cash_collected_cents from company_statement_lines l join company_statements s on s.id = l.statement_id
    where s.statement_month = date '2033-05-01' and l.level = 'vehicle' and l.vehicle_id = test.id('vehicle:sto_car')), 101700::bigint);
select test.eq('the payments tie: every payment of the month is on a vehicle',
  (select (c ->> 'ok') || '/' || (c ->> 'difference_cents') from company_statements s, jsonb_array_elements(s.checks) c
    where s.statement_month = date '2033-05-01' and c ->> 'check' = 'payments_against_vehicles'), 'true/0');
select test.eq('no tie problem names the payment',
  (select coalesce(tie_problems, '') like '%not tied to a booking or an owner invoice%' from company_statements where statement_month = date '2033-05-01'), false);
