-- 99: a flat monthly payment per car for the owner (migration 0196, docs/changes/2026-10-30-flat-monthly-owner-pay.md).
-- Fixtures start with "fm". August and September 2026, both in the past.
select test.suite('99 flat monthly owner pay');
grant usage on schema test to service_role;
grant execute on all functions in schema test to authenticated, anon, service_role;

select test.mk_user('fm_admin', 'admin');
select test.mk_user('fm_cs', 'va', 'cs');
select test.mk_owner('fm_o');
select test.mk_vehicle('FMA', 'fm_o', 'managed', 45000, 2500, 3500, date '2026-07-01');
select test.mk_vehicle('FMB', 'fm_o', 'managed', 45000, 2500, 3500, date '2026-07-01');
select test.mk_renter('fm_r');
create function test.fmpay(p_user text, p jsonb) returns jsonb language sql as $$ select app.door(test.id(p_user), 'aal2', 'ops_do', 'car_pay_set', p) $$;
create function test.fmb(p text) returns uuid language sql stable as $$ select test.id('booking:' || p) $$;
create function test.fmv(p text) returns uuid language sql stable as $$ select test.id('vehicle:' || p) $$;

-- ================================================================ 1. set it on the car's terms
select test.throws('customer service may not set the owner''s pay',
  format($$select test.fmpay('fm_cs', '{"vehicle_id": "%s", "arrangement": "flat_monthly", "monthly_cents": 90000, "from": "2026-08-01", "reason": "Cohost"}')$$, test.fmv('FMA')), 'Only an Admin');
select test.throws('an amount is needed',
  format($$select test.fmpay('fm_admin', '{"vehicle_id": "%s", "arrangement": "flat_monthly", "monthly_cents": 0, "from": "2026-08-01", "reason": "Cohost"}')$$, test.fmv('FMA')), 'amount a month');
select test.eq('review: the steps, nothing saved',
  (select (test.fmpay('fm_admin', jsonb_build_object('vehicle_id', test.fmv('FMA'), 'monthly_cents', 90000, 'from', '2026-08-01', 'reason', 'Cohost wants a flat amount', 'preview', true)) #>> '{steps,0}'))
  || '/' || (select count(*) from vehicle_owner_arrangements),
  'From Aug 1, 2026 CarmaCars pays the owner $900.00 a month for this car, part months by the day, on the monthly owner statement./0');
select test.lives('FMA: $900 a month from August 1',
  format($$select test.fmpay('fm_admin', '{"vehicle_id": "%s", "arrangement": "flat_monthly", "monthly_cents": 90000, "from": "2026-08-01", "reason": "Cohost wants a flat amount"}')$$, test.fmv('FMA')));
select test.lives('FMB: $900 a month from August 11 (a part month)',
  format($$select test.fmpay('fm_admin', '{"vehicle_id": "%s", "arrangement": "flat_monthly", "monthly_cents": 90000, "from": "2026-08-11", "reason": "Cohost wants a flat amount"}')$$, test.fmv('FMB')));
select test.eq('the car''s terms carry it', (app.ct_car(test.fmv('FMB'), true) #>> '{pay,arrangement}') || '/' || (app.ct_car(test.fmv('FMB'), false) #>> '{pay,monthly_cents}'), 'flat_monthly/90000');

-- ================================================================ 2. the month's rentals and expenses
select test.mk_booking('FM-1', 'FMA', 'fm_r', '2026-08-05 10:00', '2026-08-08 10:00', 'closed', 30000);
select test.mk_booking('FM-2', 'FMA', 'fm_r', '2026-08-12 10:00', '2026-08-14 10:00', 'closed', 20000);
select test.mk_booking('FM-3', 'FMB', 'fm_r', '2026-08-03 10:00', '2026-08-06 10:00', 'closed', 30000);
select test.mk_booking('FM-4', 'FMB', 'fm_r', '2026-08-20 10:00', '2026-08-22 10:00', 'closed', 20000);
select app.compute_booking_split(test.fmb('FM-2'));
select app.door(test.id('fm_admin'), 'aal2', 'ops_do', 'booking_owner_expense_add', '{"booking": "FM-2", "category": "cleaning", "amount_cents": 5000, "reason": "Interior detail after the trip"}');
select app.door(test.id('fm_admin'), 'aal2', 'ops_do', 'booking_owner_expense_add', '{"booking": "FM-2", "category": "repair", "amount_cents": 8000, "reason": "Owner asked for a new wiper set"}');
create table test.fmexp as select (select id from booking_owner_expenses where booking_id = test.fmb('FM-2') and category = 'repair') as repair;
select test.throws('only an Admin charges an expense to the owner',
  format($$select app.door(%L, 'aal2', 'ops_do', 'booking_owner_expense_charge', jsonb_build_object('id', (select repair from test.fmexp), 'charge', true))$$, test.id('fm_cs')), 'Only an Admin');
select test.eq('an Admin charges the repair to the owner; the read says so',
  (select string_agg(x ->> 'charge_to_owner', ',' order by x ->> 'category') from jsonb_array_elements(
     app.door(test.id('fm_admin'), 'aal2', 'ops_do', 'booking_owner_expense_charge', jsonb_build_object('id', (select repair from test.fmexp), 'charge', true)) -> 'expenses') x),
  'false,true');
select test.eq('the split of a flat booking: CarmaCars keeps all of it, the expenses are not taken from the owner',
  (select company_share_bps || '/' || owner_expense_cents || '/' || (company_share_cents = owner_revenue_cents) || '/' || owner_payout_cents || '/' || (flat_arrangement_id is not null)
     from booking_splits where booking_id = test.fmb('FM-2')), '10000/0/true/0/true');
select test.eq('the owner''s booking row: one expense, the repair',
  (select string_agg(e ->> 'category', ',') from app.owner_portal_bookings(test.id('fm_o')) b, jsonb_array_elements(b.owner_expenses) e where b.booking_id = test.fmb('FM-2')), 'repair');

-- ================================================================ 3. the August statement
create table test.fmaug as select app.build_owner_statement(test.id('owner:fm_o'), date '2026-08-01') as id;
create function test.fml(p_vehicle text, p_type text) returns bigint language sql stable as $$
  select coalesce(sum(amount_cents), 0) from owner_statement_lines where owner_statement_id = (select id from test.fmaug) and vehicle_id = test.fmv(p_vehicle) and line_type = p_type $$;
select test.eq('full month: one flat payment line of $900.00 for FMA', test.fml('FMA', 'flat_payment'), 90000::bigint);
select test.eq('part month: FMB from August 11, 21 of 31 days', test.fml('FMB', 'flat_payment'), public.calc_prorated_fee(90000, 21, 31));
select test.eq('part month: the line says the days',
  (select description from owner_statement_lines where owner_statement_id = (select id from test.fmaug) and vehicle_id = test.fmv('FMB') and line_type = 'flat_payment'),
  'Flat monthly payment, August 2026: $900.00 a month, 21 of 31 days (Aug 11, 2026 to Aug 31, 2026)');
select test.eq('FMA: its rentals are listed with no Owner Revenue, no Revenue Share and nothing paid',
  (select count(*) || '/' || sum(owner_revenue_cents) || '/' || sum(revenue_share_cents) || '/' || sum(amount_cents) from owner_statement_lines
    where owner_statement_id = (select id from test.fmaug) and vehicle_id = test.fmv('FMA') and line_type = 'rental'), '2/0/0/0');
select test.eq('no insurance, fees or revenue share deducted on FMA',
  (select count(*) from owner_statement_lines where owner_statement_id = (select id from test.fmaug) and vehicle_id = test.fmv('FMA') and (line_type = 'fees_deducted' or revenue_share_cents <> 0)), 0::bigint);
select test.eq('the expense not charged is not on the statement; the charged one is an owner cost',
  (select string_agg(line_type || ':' || amount_cents, ',') from owner_statement_lines where owner_statement_id = (select id from test.fmaug) and line_type = 'owner_cost'), 'owner_cost:-8000');
select test.eq('FMB: the rental before the flat period keeps the revenue share',
  (select revenue_share_cents from owner_statement_lines where owner_statement_id = (select id from test.fmaug) and booking_id = test.fmb('FM-3')), public.calc_bps(30000, 3500));
select test.eq('FMB: the rental in the flat period has none',
  (select revenue_share_cents || '/' || amount_cents from owner_statement_lines where owner_statement_id = (select id from test.fmaug) and booking_id = test.fmb('FM-4')), '0/0');
select test.eq('FMA''s totals: the flat payment, the charged expense, nothing else',
  (select owner_revenue_cents || '/' || revenue_share_cents || '/' || flat_payment_cents || '/' || owner_costs_deducted_cents || '/' || payable_cents
     from owner_statement_vehicles where owner_statement_id = (select id from test.fmaug) and vehicle_id = test.fmv('FMA')), '0/0/90000/8000/82000');
select test.eq('the statement: revenue share only from FM-3, the payout adds up',
  (select revenue_share_cents || '/' || flat_payment_cents || '/' || payout_cents from owner_statements where id = (select id from test.fmaug)),
  public.calc_bps(30000, 3500) || '/' || (90000 + public.calc_prorated_fee(90000, 21, 31)) || '/'
  || (90000 + public.calc_prorated_fee(90000, 21, 31) - 8000 + 30000 - public.calc_bps(30000, 3500)));
select test.eq('rebuilding the draft gives the same flat lines (no second credit)',
  (select app.build_owner_statement(test.id('owner:fm_o'), date '2026-08-01') = (select id from test.fmaug)) || '/'
  || (select count(*) from owner_credits where owner_id = test.id('owner:fm_o') and kind = 'flat_monthly' and status = 'open') || '/' || test.fml('FMA', 'flat_payment'), 'true/2/90000');

-- the Fees: none for a month all flat, a part month billed for the other days only
select test.eq('August invoice of FMA (all flat): none', app.generate_owner_invoice(test.fmv('FMA'), date '2026-08-01') is null, true);
create table test.fminv as select app.generate_owner_invoice(test.fmv('FMB'), date '2026-08-01') as id;
select test.eq('August invoice of FMB: the Insurance Fee for 10 of 31 days',
  (select l.amount_cents from test.fminv i join owner_invoice_lines l on l.owner_invoice_id = i.id and l.kind = 'insurance_fee'),
  round(45000 * 10 / 31.0)::bigint);

-- ================================================================ 4. switching mid-month keeps the earlier statement
select app.approve_owner_statement((select id from test.fmaug), test.id('fm_admin'));
create table test.fmsnap as select s.payout_cents, (select md5(string_agg(l.line_type || l.amount_cents || coalesce(l.revenue_share_cents, 0) || coalesce(l.description, ''), '|' order by l.id))
  from owner_statement_lines l where l.owner_statement_id = s.id) as lines from owner_statements s where s.id = (select id from test.fmaug);
select test.throws('a change inside the approved month is refused',
  format($$select test.fmpay('fm_admin', '{"vehicle_id": "%s", "arrangement": "revenue_share", "from": "2026-08-20", "reason": "Back to the split"}')$$, test.fmv('FMA')), 'is approved');
select test.lives('FMA back to revenue share from September 16',
  format($$select test.fmpay('fm_admin', '{"vehicle_id": "%s", "arrangement": "revenue_share", "from": "2026-09-16", "reason": "Back to the split"}')$$, test.fmv('FMA')));
select test.eq('history: the period ends September 15',
  (select string_agg(starts_on || '..' || coalesce(ends_on::text, ''), ',') from vehicle_owner_arrangements where vehicle_id = test.fmv('FMA') and cancelled_at is null), '2026-08-01..2026-09-15');
select test.mk_booking('FM-5', 'FMA', 'fm_r', '2026-09-05 10:00', '2026-09-07 10:00', 'closed', 20000);
select test.mk_booking('FM-6', 'FMA', 'fm_r', '2026-09-20 10:00', '2026-09-22 10:00', 'closed', 20000);
create table test.fmsep as select app.build_owner_statement(test.id('owner:fm_o'), date '2026-09-01') as id;
select test.eq('September: FMA is paid 15 of 30 days, FMB the full month',
  (select string_agg(amount_cents::text, ',' order by vehicle_id = test.fmv('FMB')) from owner_statement_lines where owner_statement_id = (select id from test.fmsep) and line_type = 'flat_payment'),
  public.calc_prorated_fee(90000, 15, 30) || ',90000');
select test.eq('September: the rental on a flat day stays with CarmaCars, the one after the switch is shared',
  (select string_agg(b.booking_number || ':' || l.revenue_share_cents, ',' order by b.booking_number) from owner_statement_lines l join bookings b on b.id = l.booking_id
    where l.owner_statement_id = (select id from test.fmsep) and l.line_type = 'rental'), 'FM-5:0,FM-6:' || public.calc_bps(20000, 3500));
select test.eq('the August statement is as it was approved',
  (select (s.payout_cents = x.payout_cents) and x.lines = (select md5(string_agg(l.line_type || l.amount_cents || coalesce(l.revenue_share_cents, 0) || coalesce(l.description, ''), '|' order by l.id))
     from owner_statement_lines l where l.owner_statement_id = s.id) from owner_statements s, test.fmsnap x where s.id = (select id from test.fmaug)), true);
insert into test.fminv select app.generate_owner_invoice(test.fmv('FMA'), date '2026-09-01');
select test.eq('September invoice of FMA: the Insurance Fee for the 15 days after the switch',
  (select l.amount_cents from owner_invoices i join owner_invoice_lines l on l.owner_invoice_id = i.id and l.kind = 'insurance_fee' where i.vehicle_id = test.fmv('FMA') and i.period_month = date '2026-09-01'), 22500::bigint);
select test.eq('the car''s terms: revenue share now, one flat period in the history',
  (app.ct_car(test.fmv('FMA'), true) #>> '{pay,arrangement}') || '/' || jsonb_array_length(app.ct_car(test.fmv('FMA'), true) #> '{pay,periods}'), 'revenue_share/1');

-- ================================================================ privileges
set role authenticated;
select test.throws('authenticated: no direct call', $$select app.car_pay_set(gen_random_uuid(), '{}')$$, null);
reset role;
