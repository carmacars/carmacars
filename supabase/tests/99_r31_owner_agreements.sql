-- 99: owner agreements for every special deal (migration 0640, docs/changes/2026-11-07-r31-owner-agreements.md). Fixtures "q31".
-- Amounts here are test values, not any supplier's.
select test.suite('99 r31 owner agreements: fleet lease, referral override, agreements checklist');
select test.mk_user('q31_admin', 'admin');
select test.mk_user('q31_va', 'va', 'fleet');
select test.mk_owner('q31_sup');
update owners set owner_type = 'corporation', corporation_name = 'Example Fleet Supply Inc.', signing_officer_name = 'Pat Example' where id = test.id('owner:q31_sup');
select test.mk_vehicle('Q31A', 'q31_sup', 'managed', 45000, 2500, 3000, date '2026-08-01');
select test.mk_vehicle('Q31B', 'q31_sup', 'managed', 45000, 2500, 3000, date '2026-08-01');
create function test.q31do(p_name text, p jsonb, p_user text default 'q31_admin') returns jsonb language sql as $$ select app.door(test.id(p_user), 'aal2', 'ops_do', p_name, p) $$;
create function test.q31ea() returns text language sql stable as $$
  select string_agg(variant || ':' || status, ',' order by variant <> 'standard', status = 'draft', agreement_number) from owner_agreements where owner_id = test.id('owner:q31_sup') and kind = 'enrollment' and status <> 'void' $$;
create function test.q31terms(p_regular bigint, p_from text) returns jsonb language sql as $$
  select test.q31do('fleet_lease_terms_save', jsonb_build_object('owner_id', test.id('owner:q31_sup'), 'regular_cents', p_regular, 'troubled_cents', 21000,
    'claim_profit_bps', 2500, 'early_writeoff_bps', 10000, 'writeoff_months', 12, 'later_writeoff_bps', 4000, 'notice_days', 60, 'from', p_from)) $$;

-- ---------------------------------------------------------------- 1. terms first, then the cars
select test.throws('a car needs the supplier''s lease terms first',
  format($$select test.q31do('fleet_lease_car_set', '{"vehicle_id": "%s", "tier": "regular", "delivered_on": "2026-08-05", "reason": "Delivered"}')$$, test.id('vehicle:Q31A')), 'lease terms first');
select test.throws('every number is entered (no default rate)',
  format($$select test.q31do('fleet_lease_terms_save', '{"owner_id": "%s", "troubled_cents": 21000}')$$, test.id('owner:q31_sup')), 'Regular Rate');
select test.lives('Admin enters the supplier''s terms', $$select test.q31terms(61000, '2026-08-01')$$);
select test.throws('an owner cannot set a tier',
  format($$select app.fleet_lease_car_set(test.id('q31_sup'), '{"vehicle_id": "%s", "tier": "regular", "delivered_on": "2026-08-05", "reason": "x y z"}')$$, test.id('vehicle:Q31A')), 'Only staff');
select test.lives('car A delivered Aug 5, Regular',
  format($$select test.q31do('fleet_lease_car_set', '{"vehicle_id": "%s", "tier": "regular", "delivered_on": "2026-08-05", "reason": "Delivered"}')$$, test.id('vehicle:Q31A')));
select test.lives('a fleet staff member adds car B, delivered Aug 25, Troubled',
  format($$select test.q31do('fleet_lease_car_set', '{"vehicle_id": "%s", "tier": "troubled", "delivered_on": "2026-08-25", "reason": "Delivered, needs work"}', 'q31_va')$$, test.id('vehicle:Q31B')));
select test.eq('each car''s lease is its tier''s rate', (select string_agg(lease_tier || '=' || monthly_cents, ',' order by lease_tier) from vehicle_owner_arrangements
  where owner_id = test.id('owner:q31_sup') and cancelled_at is null), 'regular=61000,troubled=21000');
select test.eq('the pay model is fleet lease', app.owner_pay_model(test.id('owner:q31_sup')), 'fleet_lease');
select test.eq('the signed standard agreement ended; a Fleet Supplier Lease Agreement waits for the signature', test.q31ea(), 'standard:ended,fleet_lease:draft');
select test.eq('in arrears: delivered Aug 5, first paid Sep 10 (the August statement)', app.fleet_first_pay_month(date '2026-08-05'), date '2026-08-01');
select test.eq('delivered Aug 25: the first Payout Date one full month later is Oct 10', app.payout_date(app.fleet_first_pay_month(date '2026-08-25')), date '2026-10-10');

-- ---------------------------------------------------------------- 2. the payables on the statements
select app.flat_credits_sync(test.id('owner:q31_sup'), date '2026-08-01');
select test.eq('August: car A part month by the day, the calculation on the line; car B waits',
  (select string_agg(amount_cents || ' ' || description, ' | ') from owner_credits where owner_id = test.id('owner:q31_sup') and kind = 'flat_monthly' and status = 'open'),
  '53129 Lease payment, August 2026, Regular car: $610.00 a month x 27 of 31 days (Aug 5, 2026 to Aug 31, 2026) = $531.29');
select app.flat_credits_sync(test.id('owner:q31_sup'), date '2026-09-01');
select test.eq('September: car B''s August and September are both on it (its first payment, Oct 10)',
  (select string_agg(to_char(flat_month, 'Mon') || '=' || amount_cents, ',' order by flat_month) from owner_credits where vehicle_id = test.id('vehicle:Q31B') and kind = 'flat_monthly' and status = 'open'),
  'Aug=4742,Sep=21000');
select test.ok('the statement builds with the lease lines', app.build_owner_statement(test.id('owner:q31_sup'), date '2026-08-01') is not null);
select test.eq('the statement''s lease line', (select count(*) from owner_statement_lines l join owner_statements s on s.id = l.owner_statement_id
  where s.owner_id = test.id('owner:q31_sup') and s.statement_month = date '2026-08-01' and l.line_type = 'flat_payment'), 1::bigint);

-- ---------------------------------------------------------------- 3. the tier is fixed; only an Admin corrects a mistake
select test.throws('staff cannot change a car''s tier once it is on the lease',
  format($$select test.q31do('fleet_lease_car_set', '{"vehicle_id": "%s", "tier": "regular", "reason": "Work done"}', 'q31_va')$$, test.id('vehicle:Q31B')), 'tier is fixed');
select test.throws('nor can a fleet staff member correct it',
  format($$select test.q31do('fleet_lease_tier_correct', '{"vehicle_id": "%s", "tier": "regular", "reason": "Typed the wrong tier"}', 'q31_va')$$, test.id('vehicle:Q31B')), 'Admin');
select test.throws('a correction needs the reason',
  format($$select test.q31do('fleet_lease_tier_correct', '{"vehicle_id": "%s", "tier": "regular"}')$$, test.id('vehicle:Q31B')), 'mistake');
select test.lives('an Admin corrects a tier entered by mistake',
  format($$select test.q31do('fleet_lease_tier_correct', '{"vehicle_id": "%s", "tier": "regular", "reason": "Entered as Troubled by mistake"}')$$, test.id('vehicle:Q31B')));
select test.eq('from the delivery (no statement approved yet), at the Regular Rate',
  (select string_agg(lease_tier || ':' || starts_on || ':' || monthly_cents, ',') from vehicle_owner_arrangements where vehicle_id = test.id('vehicle:Q31B') and cancelled_at is null), 'regular:2026-08-25:61000');
select test.ok('kept in the audit log', exists (select 1 from audit_log where action = 'fleet_lease_tier_corrected' and entity_id = test.id('vehicle:Q31B')::text));
select test.lives('back to Troubled (the tests below use it)',
  format($$select test.q31do('fleet_lease_tier_correct', '{"vehicle_id": "%s", "tier": "troubled", "reason": "Undo the test correction"}')$$, test.id('vehicle:Q31B')));

-- ---------------------------------------------------------------- 3b. no fees: never an owner invoice or a debit for a fleet lease car
select test.throws('no first and last month invoice', format($$insert into owner_invoices (owner_id, vehicle_id, kind, status) values (%L, %L, 'upfront', 'draft')$$,
  test.id('owner:q31_sup'), test.id('vehicle:Q31A')), 'fleet lease');
select test.throws('no custom fee invoice either', format($$insert into owner_invoices (owner_id, vehicle_id, kind, status) values (%L, %L, 'custom', 'draft')$$,
  test.id('owner:q31_sup'), test.id('vehicle:Q31B')), 'fleet lease');
select test.throws('no owner-level invoice for a supplier whose every car is leased', format($$insert into owner_invoices (owner_id, kind, status) values (%L, 'custom', 'draft')$$,
  test.id('owner:q31_sup')), 'fleet lease');
select test.eq('the monthly run makes no Insurance or Tracker Fee invoice', app.generate_owner_invoice(test.id('vehicle:Q31B'), date '2026-10-01'), null::uuid);
select app.generate_owner_invoice(v.id, date '2026-10-01', test.id('q31_admin')) from vehicles v where v.owner_id = test.id('owner:q31_sup');
select test.eq('after the monthly run of its cars, the supplier has no open invoice', (select count(*) from owner_invoices where owner_id = test.id('owner:q31_sup') and status <> 'void'), 0::bigint);
select test.throws('a fleet lease owner''s car is added only with its tier',
  format($$select app.staff_add_owner_car(test.id('q31_admin'), '{"owner_id": "%s", "vehicle": {}}')$$, test.id('owner:q31_sup')), 'choose the car''s tier');

-- ---------------------------------------------------------------- 4. the rates: before signing at once, after signing on the new signature
select test.lives('new rates before signing apply from their date', $$select test.q31terms(62000, '2026-09-01')$$);
select test.eq('car A is repriced from Sep 1, August kept', (select string_agg(monthly_cents || '@' || starts_on, ',' order by starts_on) from vehicle_owner_arrangements
  where vehicle_id = test.id('vehicle:Q31A') and cancelled_at is null), '61000@2026-08-05,62000@2026-09-01');
update owner_agreements set status = 'signed' where owner_id = test.id('owner:q31_sup') and kind = 'enrollment' and status = 'draft';
select test.eq('after signing, new rates wait for the supplier''s signature of a new agreement', (test.q31terms(63000, '2026-12-01') ->> 'resign'), 'true');
select test.eq('the signed one ended, a new one opened', test.q31ea(), 'standard:ended,fleet_lease:ended,fleet_lease:draft');
select test.eq('meanwhile the cars keep the signed rate', (app.flat_arrangement_on(test.id('vehicle:Q31A'), app.today())).monthly_cents, 62000::bigint);
update owner_agreements set status = 'signed' where owner_id = test.id('owner:q31_sup') and kind = 'enrollment' and status = 'draft';
select test.eq('signed: the waiting rates apply from their date', (app.flat_arrangement_on(test.id('vehicle:Q31A'), date '2026-12-15')).monthly_cents, 63000::bigint);
select test.eq('nothing waits any more', (select count(*) from owner_fleet_lease_terms where owner_id = test.id('owner:q31_sup') and awaiting_signature), 0::bigint);

-- ---------------------------------------------------------------- 5. upkeep: the right party pays
select test.lives('Admin sets the Upkeep Table', format($$select test.q31do('upkeep_split_save', '{"owner_id": "%s", "split": {"engine": "supplier", "transmission": "supplier", "tires": "company", "brakes": "company"}}')$$, test.id('owner:q31_sup')));
select test.eq('an engine repair is billed to the supplier',
  test.q31do('fleet_upkeep_cost', jsonb_build_object('vehicle_id', test.id('vehicle:Q31A'), 'cost_type', 'engine', 'amount_cents', 120000, 'description', 'Engine mount')) ->> 'party', 'supplier');
select test.eq('as an owner deduction on its statement', (select count(*) from owner_deductions where vehicle_id = test.id('vehicle:Q31A') and kind = 'maintenance' and upkeep_cost_type = 'engine'), 1::bigint);
select test.eq('tires are the Company''s: nothing billed',
  test.q31do('fleet_upkeep_cost', jsonb_build_object('vehicle_id', test.id('vehicle:Q31A'), 'cost_type', 'tires', 'amount_cents', 80000, 'description', 'Four tires')) ->> 'billed', 'false');
select test.throws('a cost type not in the Upkeep Table is refused',
  format($$select test.q31do('fleet_upkeep_cost', '{"vehicle_id": "%s", "cost_type": "shocks", "amount_cents": 100}')$$, test.id('vehicle:Q31A')), 'Upkeep Table');

select test.lives('r29''s repair costs: a supplier cost type paid by CarmaCars', format($$insert into vehicle_repair_costs (id, vehicle_id, spent_on, vendor_name, description, amount_cents, tax_cents, paid_by, cost_type)
  values (%L, %L, date '2026-10-02', 'Example Garage', 'Transmission service', 90000, 11700, 'company', 'transmission')$$, test.id('repair:q31'), test.id('vehicle:Q31A')));
select test.eq('is billed to the supplier as a deduction', (select amount_cents || '/' || hst_cents from owner_deductions where upkeep_ref = test.id('repair:q31') and status = 'open'), '90000/11700');
update vehicle_repair_costs set voided_at = now() where id = test.id('repair:q31');
select test.eq('voided, the deduction goes', (select count(*) from owner_deductions where upkeep_ref = test.id('repair:q31') and status = 'open'), 0::bigint);

create table test.q31rc as select test.q31do('repair_cost_save', jsonb_build_object('vehicle_id', test.id('vehicle:Q31A'), 'vendor_name', 'Example Garage', 'description', 'Engine sensor',
  'amount_cents', 15000, 'paid_by', 'company', 'cost_type', 'engine')) j;
select test.eq('the repair cost form''s upkeep type bills the supplier too', (select count(*) from owner_deductions d, test.q31rc where d.upkeep_ref = (j ->> 'id')::uuid), 1::bigint);

-- ---------------------------------------------------------------- 6. claims: the profit share, the write-off rule
insert into incidents (id, kind, vehicle_id, occurred_at) values (test.id('inc:q31a'), 'accident', test.id('vehicle:Q31A'), timestamptz '2026-09-15 15:00:00+00');
insert into claims (id, incident_id, vehicle_id, owner_id, path) values (test.id('claim:q31a'), test.id('inc:q31a'), test.id('vehicle:Q31A'), test.id('owner:q31_sup'), 'fleet_policy');
insert into claim_ledger_entries (claim_id, kind, amount_cents) values (test.id('claim:q31a'), 'insurer_payment', 500000), (test.id('claim:q31a'), 'repair', 300000);
select test.lives('Admin settles the claim', $$select app.settle_claim(test.id('claim:q31a'), test.id('q31_admin'))$$);
select test.eq('the supplier''s Claim Profit Share of the $2,000 profit is a credit on its statement',
  (select amount_cents from owner_credits where claim_id = test.id('claim:q31a') and kind = 'claim_profit_share'), 50000::bigint);
select test.eq('the Company keeps the rest', (select company_result_cents from claims where id = test.id('claim:q31a')), 150000::bigint);
insert into incidents (id, kind, vehicle_id, occurred_at) values (test.id('inc:q31b'), 'accident', test.id('vehicle:Q31B'), timestamptz '2026-10-20 15:00:00+00');
insert into claims (id, incident_id, vehicle_id, owner_id, path) values (test.id('claim:q31b'), test.id('inc:q31b'), test.id('vehicle:Q31B'), test.id('owner:q31_sup'), 'total_loss');
select test.lives('a write-off settlement with a lien', $$select app.record_total_loss_settlement(test.id('claim:q31b'), 2000000, date '2026-10-30', 500000, test.id('q31_admin'))$$);
select test.eq('the lender first, then the Early Write-Off Share (under the Write-Off Period) of the balance',
  (select lender_paid_cents || '/' || owner_balance_cents || '/' || fleet_service_months from claims where id = test.id('claim:q31b')), '500000/1500000/1');
select test.eq('paid as a credit on the supplier''s statement', (select amount_cents from owner_credits where claim_id = test.id('claim:q31b') and kind = 'write_off_share'), 1500000::bigint);
select test.ok('an ordinary owner''s claim keeps the old rules', (app.fleet_claim_terms(test.id('claim:q31b'))).id is not null and (select count(*) from claims c where c.owner_id <> test.id('owner:q31_sup') and (app.fleet_claim_terms(c.id)).id is not null) = 0);

-- ---------------------------------------------------------------- 7. the agreement facts
insert into vehicle_onboardings (vehicle_id, status) values (test.id('vehicle:Q31A'), 'enrolled'), (test.id('vehicle:Q31B'), 'enrolled');
select test.eq('the facts carry the lease terms, the Upkeep Table and each car''s tier',
  (select (f #>> '{fleet_lease,regular_cents}') || '/' || jsonb_array_length(f #> '{fleet_lease,upkeep}') || '/' || (select string_agg(s ->> 'lease_tier', ',' order by s ->> 'lease_tier') from jsonb_array_elements(f -> 'schedules') s)
     from (select app.owner_agreement_facts(test.id('owner:q31_sup'), test.id('q31_admin')) f) x), '63000/4/regular,troubled');

-- ---------------------------------------------------------------- 8. the referral override, and the checklist
select test.mk_owner('q31_ref');
select test.mk_owner('q31_mgd');
insert into owner_referral_links (id, referrer_owner_id, referred_owner_id, share_bps) values (test.id('link:q31'), test.id('owner:q31_ref'), test.id('owner:q31_mgd'), 1000);
select test.mk_vehicle('Q31M', 'q31_mgd', 'managed', 35000, 0, 4000, date '2026-08-01');
insert into vehicle_onboardings (vehicle_id, status) values (test.id('vehicle:Q31M'), 'enrolled');
create table test.q31list as select app.door(test.id('q31_admin'), 'aal2', 'ops_read', 'owner_agreements_checklist', '{}') j;
select test.eq('the referrer needs a Referral Override Agreement, not sent',
  (select i ->> 'title' || ':' || (i ->> 'status') from test.q31list, jsonb_array_elements(j) o, jsonb_array_elements(o -> 'items') i where o ->> 'owner_id' = test.id('owner:q31_ref')::text and i ->> 'doc' = 'referral'), 'Referral Override Agreement:not_sent');
select test.eq('the supplier''s agreement shows as signed, flagged for the lawyer',
  (select i ->> 'title' || ':' || (i ->> 'status') || ':' || (i ->> 'awaiting_lawyer') from test.q31list, jsonb_array_elements(j) o, jsonb_array_elements(o -> 'items') i
    where o ->> 'owner_id' = test.id('owner:q31_sup')::text and i ->> 'kind' = 'enrollment'), 'Fleet Supplier Lease Agreement:signed:true');
select test.lives('Send emails the referrer', format($$select test.q31do('owner_agreement_send', '{"owner": "%s", "doc": "referral", "link": "%s"}')$$, test.id('owner:q31_ref'), test.id('link:q31')));
select test.eq('the email is queued with the link', (select payload ->> 'sign_url' from notification_outbox where code = 'owner_agreement_to_sign' and owner_id = test.id('owner:q31_ref')),
  rtrim(coalesce((app.settings()).notify_base_url, 'https://carmacars.ca'), '/') || '/owner/referral-agreement/' || test.id('link:q31'));
select test.eq('and the checklist says sent', (select i ->> 'status' from jsonb_array_elements(app.owner_agreements_checklist(test.id('q31_admin'), jsonb_build_object('owner', test.id('owner:q31_ref')))) o,
  jsonb_array_elements(o -> 'items') i where i ->> 'doc' = 'referral'), 'sent');
select test.throws('nothing to send to a supplier whose agreements are signed',
  format($$select test.q31do('owner_agreement_send', '{"owner": "%s", "doc": "packet"}')$$, test.id('owner:q31_sup')), 'Nothing to sign');
select test.throws('another owner cannot open the referrer''s agreement',
  format($$select public.referral_agreement_open(test.id('q31_mgd'), test.id('link:q31'), repeat('a', 64), 'owners/%s/referral/x.pdf', 'referral-v1')$$, test.id('owner:q31_mgd')), 'Only the referrer');
select test.lives('the referrer opens it for signature',
  format($$select public.referral_agreement_open(test.id('q31_ref'), test.id('link:q31'), repeat('b', 64), 'owners/%s/referral/x.pdf', 'referral-v1')$$, test.id('owner:q31_ref')));
select test.eq('a sign request for the referrer, the link sent', (select r.doc_type || '/' || r.signer_role || '/' || l.agreement_status from sign_requests r join owner_referral_links l on l.id = r.referral_link_id
  where r.referral_link_id = test.id('link:q31') and r.status = 'sent'), 'referral_agreement/owner_individual/sent');
select test.eq('the referrer initials three key terms', app.esign_doc_initials('request', 'x', 'referral_agreement'), array['referral_override', 'referral_confidential', 'referral_ending']);
select test.eq('the referrer''s portal facts: the override rate and the referred owner',
  (select (f ->> 'share_bps') || '/' || (f #>> '{referred,legal_name}') from (select public.server_referral_agreement_facts(test.id('q31_ref'), test.id('link:q31')) f) x), '1000/Q31 Mgd');
select test.eq('nobody else reads them', public.server_referral_agreement_facts(test.id('q31_mgd'), test.id('link:q31')), null::jsonb);

-- ---------------------------------------------------------------- 9. standard owners: the schedule facts the agreement now shows
select test.eq('a car''s facts carry the shareholder flag and the onboarding costs',
  (select (s ->> 'shareholder') || '/' || jsonb_typeof(s -> 'one_off_fees') || '/' || (s ->> 'onboarding_by_payout')
     from jsonb_array_elements(app.owner_agreement_facts(test.id('owner:q31_mgd'), test.id('q31_admin')) -> 'schedules') s limit 1), 'false/array/false');

-- ---------------------------------------------------------------- 10. privileges
select test.eq('the new functions are the service role''s only', (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where ((n.nspname = 'app' and p.proname in ('fleet_lease_terms_save', 'fleet_lease_car_set', 'owner_agreement_send', 'owner_agreements_checklist', 'referral_agreement_open'))
     or (n.nspname = 'public' and p.proname in ('referral_agreement_open', 'server_referral_agreement_facts', 'server_referral_agreements')))
    and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))), 0::bigint);
