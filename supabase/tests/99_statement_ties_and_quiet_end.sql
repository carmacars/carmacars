-- 99: the company statement ties a payment of an owner invoice on a car not yet enrolled (migration 0281); the text quiet hours end on the clock (0282).
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

-- 0282: the text quiet hours end at the hour on the clock, also on the days the clocks change (21:00 to 8:00 here)
select test.suite('99 text quiet end on the clock');
-- every settings row (a dated one answers for its own days)
create temp table qe_s as select id, sms_quiet_hours, sms_quiet_from_hour, sms_quiet_until_hour from program_settings;
update program_settings set sms_quiet_hours = true, sms_quiet_from_hour = 21, sms_quiet_until_hour = 8;
select test.eq('the night the clocks go back: held until 8:00 on the clock',
  to_char(app.sms_quiet_end(timestamptz '2026-11-01 01:30 America/Toronto') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), '2026-11-01 08:00');
select test.eq('the night the clocks go forward: held until 8:00 on the clock',
  to_char(app.sms_quiet_end(timestamptz '2027-03-13 23:00 America/Toronto') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), '2027-03-14 08:00');
select test.eq('an ordinary night: 8:00 the next morning',
  to_char(app.sms_quiet_end(timestamptz '2026-11-10 22:15 America/Toronto') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), '2026-11-11 08:00');
update program_settings p set sms_quiet_hours = q.sms_quiet_hours, sms_quiet_from_hour = q.sms_quiet_from_hour, sms_quiet_until_hour = q.sms_quiet_until_hour
  from qe_s q where p.id = q.id;
