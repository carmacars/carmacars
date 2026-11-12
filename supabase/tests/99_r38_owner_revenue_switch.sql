-- 99: "Counts toward the owner's revenue" on an insurer-billed rental added by hand (2371). Off: out of the owner's
-- statements, payouts and earnings; still the company's revenue and on the insurer invoice. Fixtures start with "orv".
select test.suite('99 r38 owner revenue switch');
select set_config('app.paper_fixture', 'on', false);
select test.mk_user('orv_admin', 'admin');
select test.mk_user('orv_cs', 'va', 'cs');
update staff_profiles set single_limit_cents = 500000 where user_id = test.id('orv_cs');
select test.mk_owner('orv_olive');
select test.mk_vehicle('orvcar', 'orv_olive');
insert into insurers (name, billing_email) values ('Orv Example Mutual', 'claims.orv@example.test');
create temp table s99orv as select null::text as k, null::jsonb as v limit 0;
create or replace function test.s99orv(p jsonb, p_start integer) returns jsonb language sql stable as $$
  select jsonb_build_object('vehicle_id', test.id('vehicle:orvcar'), 'pickup_at', date_trunc('hour', now()) + make_interval(days => p_start), 'return_at', date_trunc('hour', now()) + make_interval(days => p_start + 3),
    'coverage_option', 1, 'source', 'insurer', 'sales_choice', 'for_carmacars', 'agreement', 'paper', 'rental_charge_cents', 30000, 'price_tax', 'plus', 'price_reason', 'Insurer rate',
    'renter', jsonb_build_object('full_name', 'Ora Insured', 'date_of_birth', '1980-01-01', 'email', 'ora.insured@example.test', 'mobile', '4165550142'),
    'insurance', jsonb_build_object('insurer_id', (select id from insurers where name = 'Orv Example Mutual'), 'claim_number', 'ORV-1', 'pays', 'insurer'),
    'payment', jsonb_build_object('mode', 'unpaid', 'method', 'insurer'), 'deposit', jsonb_build_object('method', 'cash')) || p $$;
create or replace function test.s99orvb(p_k text) returns bookings language sql stable as $$
  select * from bookings where id = (select (v ->> 'booking_id')::uuid from pg_temp.s99orv where k = p_k) $$;

select test.throws('off needs the reason', $$select app.door(test.id('orv_cs'), 'aal2', 'ops_do', 'manual_rental_create', test.s99orv('{"counts_for_owner": false}', 3))$$, '%reason%');
select test.throws('only a rental billed to an insurer can be left out',
  $$select app.door(test.id('orv_admin'), 'aal2', 'ops_do', 'manual_rental_create', test.s99orv('{"counts_for_owner": false, "counts_for_owner_reason": "Internal", "insurance": null, "payment": {"mode": "unpaid"}}', 3))$$, '%billed to an insurer%');
insert into s99orv select 'off', app.door(test.id('orv_cs'), 'aal2', 'ops_do', 'manual_rental_create', test.s99orv('{"counts_for_owner": false, "counts_for_owner_reason": "Insurer pays CarmaCars directly"}', 3));
insert into s99orv select 'on', app.door(test.id('orv_admin'), 'aal2', 'ops_do', 'manual_rental_create', test.s99orv('{}', 10));
select test.eq('off (customer service): kept on the booking with the reason, the owner sees the car unavailable',
  ((test.s99orvb('off')).owner_revenue_excluded, (test.s99orvb('off')).owner_revenue_excluded_reason, (test.s99orvb('off')).owner_visibility)::text, '(t,"Insurer pays CarmaCars directly",never)');
select test.ok('on by default', not (test.s99orvb('on')).owner_revenue_excluded);
select app.compute_booking_split((test.s99orvb('off')).id);
select app.compute_booking_split((test.s99orvb('on')).id);
select test.eq('off: no payout to the owner, off every statement month; the company keeps all of it',
  (select sum(owner_payout_cents) || '/' || min(payout_month) || '/' || (sum(company_share_cents) = sum(owner_revenue_cents) and sum(owner_revenue_cents) > 0)
     from booking_splits where booking_id = (test.s99orvb('off')).id), '0/9999-12-01/true');
select test.ok('on: the owner earns their revenue as usual',
  (select sum(owner_payout_cents) > 0 and min(payout_month) < date '9999-01-01' from booking_splits where booking_id = (test.s99orvb('on')).id));
select test.eq('off: still the company''s revenue: the booking''s lines and total are unchanged ($300 + HST)',
  (test.s99orvb('off')).total_due_at_booking_cents, (test.s99orvb('on')).total_due_at_booking_cents);
select test.ok('off: still billed to the insurer', (test.s99orvb('off')).bill_to = 'insurer');
select test.ok('the switch is in the audit log', exists (select 1 from audit_log where action = 'owner_revenue_counts' and entity_id = (test.s99orvb('off')).id::text and actor_user_id = test.id('orv_cs')));
-- back on from the booking, by an Admin
select app.door(test.id('orv_admin'), 'aal2', 'ops_do', 'booking_owner_revenue_set', jsonb_build_object('booking_id', (test.s99orvb('off')).id, 'counts', true));
select test.ok('back on: the owner is paid their share again',
  (select sum(owner_payout_cents) > 0 and min(payout_month) < date '9999-01-01' from booking_splits where booking_id = (test.s99orvb('off')).id) and not (test.s99orvb('off')).owner_revenue_excluded);
select test.throws('an owner never sets it', format($$select app.booking_owner_revenue_set(test.id('orv_olive'), '{"booking_id": "%s", "counts": false, "reason": "mine"}')$$, (test.s99orvb('off')).id), '%Admin or staff%');
-- the partner code field of Add a rental ties an insurer-billed rental to the referral partner (its commission, 2361)
insert into referral_partners (kind, business_name, referral_code, rate_kind, rate_bps) values ('insurance_broker', 'Orv Example Brokers', 'ORVPB1', 'percent', 1000);
insert into s99orv select 'ref', app.door(test.id('orv_admin'), 'aal2', 'ops_do', 'manual_rental_create', test.s99orv('{"referral_code": "ORVPB1"}', 20));
select test.ok('Referred by (partner code) on an insurer-billed rental: the booking is the partner''s',
  (test.s99orvb('ref')).referral_partner_id = (select id from referral_partners where referral_code = 'ORVPB1'));
