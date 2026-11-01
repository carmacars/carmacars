-- 99: the model spreadsheets, live (migration 0420). Fixtures start with "imd". The aggregation is checked on March
-- 2031, a month no other suite books, so the totals are this suite's alone.
select test.suite('99 investor model');
select test.mk_user('imd_admin', 'admin');
select test.mk_user('imd_fin', 'va', 'finance');
-- an investor signs in with a plain account; the investors row makes them one (as in suite 18)
select test.mk_user('imd_inv1', 'renter');
select test.mk_user('imd_inv2', 'renter');
select test.mk_owner('imd_owner');
select test.mk_vehicle('imdV1', 'imd_owner', p_share_bps => 3000);
select test.mk_vehicle('imdV2', 'imd_owner', p_share_bps => 3000);
select test.mk_vehicle('imdV3', 'imd_owner', p_share_bps => 3000);
select test.mk_vehicle('imdV4', 'imd_owner', p_share_bps => 3000);
select test.mk_renter('imd_renter');
insert into insurers (id, name) values (test.id('imd_insurer'), 'Imd Example Insurance');

-- A: three days across the month end (March 30 and 31 in March, April 1 in April), renter-billed, $300 of rental
select test.mk_booking('IMD-1', 'imdV1', 'imd_renter', '2031-03-30 10:00', '2031-04-02 10:00', 'closed', 30000);
-- B: five days inside March, billed to an insurer, $500 of rental and a $75 delivery fee
select test.mk_booking('IMD-2', 'imdV2', 'imd_renter', '2031-03-10 09:00', '2031-03-15 09:00', 'closed', 50000);
select test.mk_line('IMD-2', 'delivery', 7500);
update bookings set bill_to = 'insurer', insurer_id = test.id('imd_insurer') where id = test.id('booking:IMD-2');
-- C: a placeholder held for an insurer (confirmed, not blocking the calendar, never handed over): not revenue
select test.mk_booking('IMD-3', 'imdV3', 'imd_renter', '2031-03-05 09:00', '2031-03-08 09:00', 'confirmed', 99900);
update bookings set blocks_calendar = false, blocks_calendar_changed_by = test.id('imd_admin'), blocks_calendar_changed_at = now(), blocks_calendar_reason = 'Held for an insurer'
 where id = test.id('booking:IMD-3');
-- D: cancelled: not revenue
select test.mk_booking('IMD-4', 'imdV4', 'imd_renter', '2031-03-20 09:00', '2031-03-22 09:00', 'cancelled', 88800);
insert into company_expenses (expense_on, category, description, amount_cents, created_by) values
  (date '2031-03-03', 'software', 'Imd hosting', 10000, test.id('imd_admin')),
  (date '2031-03-04', 'marketing', 'Imd ads', 4000, test.id('imd_admin')),
  (date '2031-03-05', 'marketing', 'Imd voided', 999, test.id('imd_admin'));
update company_expenses set voided_at = now(), void_reason = 'test' where description = 'Imd voided';

create temp table imd_mar as select app.finance_model_month(date '2031-03-01') as v;
create temp table imd_apr as select app.finance_model_month(date '2031-04-01') as v;

select test.eq('accrual: the rental is spread by day, two of the three days of A in March ($200) and all of B ($500)',
  (select (v ->> 'rental_cents')::bigint from imd_mar), 70000::bigint);
select test.eq('accrual: the third day of A is April''s ($100)', (select (v ->> 'rental_cents')::bigint from imd_apr), 10000::bigint);
select test.eq('accrual: rented days by day (2 + 5 in March)', (select (v ->> 'rented_days')::numeric from imd_mar), 7::numeric);
select test.eq('insurer split: B is insurer-billed ($500), A renter-billed ($200)',
  (select (v ->> 'rental_insurer_cents') || '/' || (v ->> 'rental_renter_cents') from imd_mar), '50000/20000');
select test.eq('placeholders and cancelled bookings are left out: two rentals in March', (select (v ->> 'rentals')::int from imd_mar), 2);
select test.eq('fees by kind, before HST: the delivery fee', (select (v #>> '{fees_by_kind,delivery,cents}')::bigint from imd_mar), 7500::bigint);
select test.eq('fees total', (select (v ->> 'fees_cents')::bigint from imd_mar), 7500::bigint);
select test.eq('owner share: 70% of the rental the owner''s cars earned in March',
  (select (v ->> 'owner_share_cents')::bigint from imd_mar), 49000::bigint);
select test.eq('expenses by category, voided left out',
  (select (v #>> '{expenses_by_category,software,cents}') || '/' || (v #>> '{expenses_by_category,marketing,cents}') || '/' || (v ->> 'expenses_cents') from imd_mar), '10000/4000/14000');
select test.eq('a future month is not complete', (select v ->> 'complete' from imd_mar), 'false');
select test.ok('cash received by method is grouped by channel', (select jsonb_typeof(v -> 'cash_by_method') = 'object' from imd_mar));

-- the job fills the summary table (the current month and the ones since launch)
select test.ok('the job refreshes the summary table', (select (app.job_finance_model() ->> 'months')::int >= 1));
select test.ok('the current month is in the table, not complete', exists (select 1 from finance_model_actuals where month = app.month_start(app.today()) and not complete));

-- ---------------------------------------------------------------- permissions
insert into investors (id, user_id, legal_name, investor_type, status, email) values
  (test.id('imd:inv1'), test.id('imd_inv1'), 'Ina Example', 'individual', 'active', 'imd_inv1@example.test'),
  (test.id('imd:inv2'), test.id('imd_inv2'), 'Oz Example', 'individual', 'active', 'imd_inv2@example.test');
insert into documents (id, kind, storage_bucket, storage_path) values (test.id('imd:docc'), 'other', 'documents', 'imd/c.pdf'), (test.id('imd:docd'), 'other', 'documents', 'imd/d.pdf');
insert into investment_agreements (id, investor_id, agreement_number, status, schedule_c_document_id, schedule_d_document_id, exemption_category, legal_advice_choice) values
  (test.id('imd:agr1'), test.id('imd:inv1'), 'IA-IMD-1', 'signed', test.id('imd:docc'), test.id('imd:docd'), 'accredited_investor', 'declined'),
  (test.id('imd:agr2'), test.id('imd:inv2'), 'IA-IMD-2', 'signed', test.id('imd:docc'), test.id('imd:docd'), 'accredited_investor', 'declined');
insert into investments (id, investor_id, agreement_id, is_initial, principal_cents, yearly_bps, investment_date, lockup_end_date) values
  (test.id('imd:x1'), test.id('imd:inv1'), test.id('imd:agr1'), true, 5000000, 3000, date '2026-03-01', date '2026-09-01'),
  (test.id('imd:x2'), test.id('imd:inv2'), test.id('imd:agr2'), true, 7700000, 3000, date '2026-03-01', date '2026-09-01');
insert into investment_returns (id, investment_id, return_month, opening_invested_cents, yearly_bps, days_earning, days_in_month, return_cents, disposition, payment_date, closing_invested_cents) values
  (test.id('imd:r1'), test.id('imd:x1'), date '2026-09-01', 5000000, 3000, 30, 30, 125000, 'pay', date '2026-10-15', 5000000),
  (test.id('imd:r2'), test.id('imd:x2'), date '2026-09-01', 7700000, 3000, 30, 30, 192500, 'pay', date '2026-10-15', 7700000);

select test.throws('an investor cannot read the internal model',
  format($s$select public.door(%L, 'aal2', 'admin_read', 'finance_model', '{}')$s$, test.id('imd_inv1')), 'Admins only');
select test.throws('Finance cannot read it either (no permission says Finance sees company statements)',
  format($s$select public.door(%L, 'aal2', 'admin_read', 'finance_model', '{}')$s$, test.id('imd_fin')), 'Admins only');
select test.throws('an investor cannot change the assumptions',
  format($s$select public.door(%L, 'aal2', 'admin_save', 'finance_model_inputs', '{"inputs": {"insurancePremium": 1}}')$s$, test.id('imd_inv1')), 'Admins only');
select test.throws('an investor cannot refresh the actuals',
  format($s$select public.door(%L, 'aal2', 'admin_do', 'finance_model_refresh', '{}')$s$, test.id('imd_inv1')), 'Admins only');
select test.ok('an Admin reads the model: actuals, assumptions, investors on file and the terms',
  (select jsonb_typeof(x -> 'actuals') = 'array' and x ? 'inputs' and jsonb_typeof(x -> 'investors') = 'array' and (x #>> '{terms,min_cents}') is not null
     from (select public.door(test.id('imd_admin'), 'aal2', 'admin_read', 'finance_model', '{}') as x) q));
select public.door(test.id('imd_admin'), 'aal2', 'admin_save', 'finance_model_inputs', '{"inputs": {"insurancePremium": 24000, "utilTarget": 0.6}}');
select test.eq('an Admin saves the assumptions (the premium entered)', (select inputs ->> 'insurancePremium' from finance_model_settings), '24000');
select test.throws('the assumptions are an object', format($s$select public.door(%L, 'aal2', 'admin_save', 'finance_model_inputs', '{"inputs": [1]}')$s$, test.id('imd_admin')), 'named values');
select test.eq('an investor reads their own sheet terms (their name, the minimum, nothing about the fleet)',
  (select (x ->> 'legal_name') || '/' || (x ? 'cars')::text || '/' || (x ? 'premium')::text from (select public.door(test.id('imd_inv1'), 'aal2', 'investor_read', 'model_terms', '{}') as x) q), 'Ina Example/false/false');
select test.eq('an investor''s statements are their own only',
  (select string_agg(r ->> 'return_cents', ',') from jsonb_array_elements(public.door(test.id('imd_inv1'), 'aal2', 'investor_read', 'statements', '{}')) r), '125000');
select test.ok('another investor''s statement is not readable by id',
  (select public.door(test.id('imd_inv1'), 'aal2', 'investor_read', 'statement', jsonb_build_object('id', test.id('imd:r2'))) is null or
          public.door(test.id('imd_inv1'), 'aal2', 'investor_read', 'statement', jsonb_build_object('id', test.id('imd:r2'))) = 'null'::jsonb));
select test.throws('the model readers are for the server only', $$set local role authenticated; select app.finance_model_read(null)$$, 'permission denied');

-- row level security: a signed-in investor's own session sees no internal row and no other investor's numbers
select set_config('request.jwt.claim.sub', test.id('imd_inv1')::text, false);
set role authenticated;
select test.eq('RLS: an investor sees no actuals', test.visible('select 1 from finance_model_actuals'), 0::bigint);
select test.eq('RLS: an investor sees no assumptions', test.visible('select 1 from finance_model_settings'), 0::bigint);
select test.eq('RLS: an investor sees only their own investment', test.visible($q$select 1 from investments where investor_id in ('$q$ || test.id('imd:inv1') || $q$', '$q$ || test.id('imd:inv2') || $q$')$q$), 1::bigint);
select test.eq('RLS: an investor sees only their own Returns', test.visible($q$select 1 from investment_returns where id in ('$q$ || test.id('imd:r1') || $q$', '$q$ || test.id('imd:r2') || $q$')$q$), 1::bigint);
reset role;
select set_config('request.jwt.claim.sub', test.id('imd_fin')::text, false);
set role authenticated;
select test.eq('RLS: Finance sees no actuals', test.visible('select 1 from finance_model_actuals'), 0::bigint);
reset role;
select set_config('request.jwt.claim.sub', test.id('imd_admin')::text, false);
set role authenticated;
select test.ok('RLS: an Admin''s session reads the actuals', test.visible('select 1 from finance_model_actuals') > 0);
reset role;
select set_config('request.jwt.claim.sub', '', false);
