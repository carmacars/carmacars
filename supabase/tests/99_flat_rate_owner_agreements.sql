-- 99: the flat-rate owner agreement set (migration 0205, docs/changes/2026-10-31-flat-rate-owner-agreements.md). Fixtures "fr".
select test.suite('99 flat rate owner agreements');
select test.mk_user('q21fr_admin', 'admin');
select test.mk_owner('q21fr_o');
select test.mk_vehicle('FRA', 'q21fr_o', 'managed', 45000, 2500, 3500, date '2026-08-01');
create function test.r21frpay(p jsonb) returns jsonb language sql as $$ select app.door(test.id('q21fr_admin'), 'aal2', 'ops_do', 'car_pay_set', p) $$;
create function test.r21frea() returns text language sql stable as $$
  select string_agg(variant || ':' || status, ',' order by created_at) from owner_agreements where owner_id = test.id('owner:q21fr_o') and kind = 'enrollment' $$;

select test.eq('revenue share: the standard set', app.owner_pay_model(test.id('owner:q21fr_o')), 'standard');
select test.eq('the lawyer flag is on by default', (app.settings()).owner_flat_agreements_awaiting_lawyer, true);
select test.lives('the car moves to a flat monthly payment',
  format($$select test.r21frpay('{"vehicle_id": "%s", "arrangement": "flat_monthly", "monthly_cents": 90000, "from": "2026-11-01", "reason": "Cohost wants a flat amount"}')$$, test.id('vehicle:FRA')));
select test.eq('the pay model is flat rate', app.owner_pay_model(test.id('owner:q21fr_o')), 'flat_rate');
select test.eq('the signed standard agreement ended; a flat-rate one waits for the signature', test.r21frea(), 'standard:ended,flat_rate:draft');
select test.eq('the car''s schedule moved to the new agreement',
  (select a.variant from vehicle_schedules s join owner_agreements a on a.id = s.owner_agreement_id where s.vehicle_id = test.id('vehicle:FRA')), 'flat_rate');
select test.eq('the facts say so: pay model, the set, a re-signing, the lawyer flag',
  (select f ->> 'pay_model' || '/' || (f #>> '{agreements,0,variant}') || '/' || (f #>> '{agreements,0,replaces}') || '/' || (f ->> 'flat_rate_review')
     from (select app.owner_agreement_facts(test.id('owner:q21fr_o'), test.id('q21fr_admin')) f) x), 'flat_rate/flat_rate/true/true');
select test.eq('Admin reads the owner''s set', app.door(test.id('q21fr_admin'), 'aal2', 'ops_read', 'owner_agreement_set', jsonb_build_object('owner', test.id('owner:q21fr_o'))) ->> 'variant', 'flat_rate');
-- back to the revenue share before the new one is signed: the signed standard agreement is in force again
select test.lives('back to the revenue share',
  format($$select test.r21frpay('{"vehicle_id": "%s", "arrangement": "revenue_share", "from": "2026-11-01", "reason": "Back to the split"}')$$, test.id('vehicle:FRA')));
select test.eq('the signed agreement is back, the unsigned one void', test.r21frea(), 'standard:signed,flat_rate:void');
select test.throws('only an Enrollment Agreement is flat rate',
  $$insert into owner_agreements (owner_id, kind, agreement_number, status, variant) values (test.id('owner:q21fr_o'), 'title_holding', 'TA-fr-x', 'draft', 'flat_rate')$$, 'owner_agreements_variant_kind');
