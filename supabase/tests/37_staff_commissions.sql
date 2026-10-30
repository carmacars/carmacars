-- 37: staff commissions (migration 0058): the choice "I sourced this client" or "Entered for CarmaCars", prices typed
-- by hand with their flags, Add a rental for every staff function and field staff, quotes for every assistant, the
-- commission from accruing to paid, the flat 10% outside Sales, the Sales tiers (49, 50, 99 and 100 rental days), the
-- month's recalculation, refunds and chargebacks (reversal and clawback of the difference), own rentals, payouts,
-- commissions as kickbacks before Owner Revenue on an owner's car (not on a partner's or a CarmaCars-owned car), the
-- field staff referral fee as the same commission, emails, To do and the doors. Fixtures start with "sc".
select test.suite('37 staff commissions');

select test.mk_user('sc_admin', 'admin');
select test.mk_user('sc_sales', 'va', 'sales');
select test.mk_user('sc_cs', 'va', 'cs');
select test.mk_user('sc_fin', 'va', 'finance');
select test.mk_user('sc_fleet', 'va', 'fleet');
select test.mk_user('sc_field', 'field', null, null, 'SCFIELD');
select test.mk_renter('sc_rita');
select test.mk_renter('sc_ron');
select test.mk_owner('sc_olive');
select test.mk_vehicle('sc_prog', 'sc_olive');
update staff_profiles set single_limit_cents = 500000 where user_id in (test.id('sc_cs'), test.id('sc_fin'), test.id('sc_fleet'), test.id('sc_sales'));

create temp table s37 as select null::text as k, null::jsonb as v limit 0;
create or replace function test.s37(p_k text) returns jsonb language sql stable as $$ select v from pg_temp.s37 where k = p_k $$;
create or replace function test.s37b(p_k text) returns bookings language sql stable as $$
  select * from bookings where id = coalesce((test.s37(p_k) ->> 'booking_id')::uuid, (test.s37(p_k) ->> 'id')::uuid) $$;
create or replace function test.s37c(p_k text) returns staff_commissions language sql stable as $$
  select * from staff_commissions where booking_id = (test.s37b(p_k)).id and kind = 'commission' order by created_at desc limit 1 $$;
-- CarmaCars-owned cars with rates
do $$
declare i integer;
begin
  for i in 1 .. 7 loop
    insert into s37 select 'car' || i, app.vehicle_add(test.id('sc_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1SCCXMM00000000' || lpad(i::text, 2, '0'),
      'plate', 'SCC00' || i, 'year', 2024, 'make', 'Kia', 'model', 'K5', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
  end loop;
end $$;
create or replace function test.s37v(p text) returns uuid language sql stable as $$ select (test.s37(p) ->> 'vehicle_id')::uuid $$;
-- a rental spec: days from now, or a past rental in last month (start day, days)
create or replace function test.s37r(p_vehicle uuid, p_from interval, p_to interval, p jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select jsonb_build_object('vehicle_id', p_vehicle, 'pickup_at', date_trunc('hour', now()) + p_from, 'return_at', date_trunc('hour', now()) + p_to,
                            'source', 'phone', 'coverage_option', 1, 'renter_id', test.id('renter:sc_rita'), 'payment', jsonb_build_object('mode', 'link')) || p $$;
create or replace function test.s37m() returns date language sql stable as $$ select (app.month_start(app.today()) - interval '1 month')::date $$;
create or replace function test.s37past(p_vehicle uuid, p_day integer, p_days integer, p_renter text default 'sc_rita') returns jsonb language sql as $$
  select jsonb_build_object('vehicle_id', p_vehicle, 'pickup_at', app.local_midnight(test.s37m() + p_day - 1) + interval '10 hours',
    'return_at', app.local_midnight(test.s37m() + p_day - 1 + p_days) + interval '10 hours', 'source', 'phone', 'coverage_option', 1, 'past', true,
    'renter_id', test.id('renter:' || p_renter), 'payment', jsonb_build_object('mode', 'other_way', 'method', 'cash')) $$;
-- an Admin records a completed, paid past rental and credits a staff member as having sourced it
create or replace function test.s37sold(p_k text, p_staff text, p_spec jsonb) returns void language plpgsql as $$
begin
  insert into s37 select p_k, app.manual_rental_create(test.id('sc_admin'), p_spec);
  perform app.sales_reassign(test.id('sc_admin'), jsonb_build_object('booking', (test.s37b(p_k)).id, 'staff', test.id(p_staff), 'sourced', true, 'reason', 'Test: sold by ' || p_staff));
end $$;

-- ================================================================ 1. settings
select test.eq('settings: 10% outside Sales; Sales 10% under 50 days, 15% from 50, 20% from 100',
  (select s.staff_commission_bps || '/' || s.sales_tier_low_bps || '/' || s.sales_tier_mid_bps || '/' || s.sales_tier_high_bps || '/' || s.sales_tier_mid_days || '/' || s.sales_tier_high_days
     from (select (app.settings()).*) s), '1000/1000/1500/2000/50/100');
select test.eq('settings: no price floor, flag discounts over 20%', (select coalesce(s.custom_price_floor_daily_cents::text, 'none') || '/' || s.custom_price_max_discount_bps from (select (app.settings()).*) s), 'none/2000');
select test.ok('settings: no "commission paid from" option (always a kickback on an owner''s car)',
  not exists (select 1 from information_schema.columns where table_name = 'program_settings' and column_name = 'commission_paid_from'));
select test.eq('tiers: 49 days 10%, 50 days 15%, 99 days 15%, 100 days 20%',
  app.sales_tier_bps(49) || '/' || app.sales_tier_bps(50) || '/' || app.sales_tier_bps(99) || '/' || app.sales_tier_bps(100), '1000/1500/1500/2000');
select test.eq('scheme: Sales by tier, others flat', app.commission_scheme(test.id('sc_sales')) || '/' || app.commission_scheme(test.id('sc_cs')) || '/' || app.commission_scheme(test.id('sc_field')),
  'sales_tier/flat/flat');

-- ================================================================ 2. Add a rental for every function and field staff; the choice
select test.eq('who adds a rental: every assistant function and field staff',
  app.manual_rental_role(test.id('sc_fin')) || '/' || app.manual_rental_role(test.id('sc_fleet')) || '/' || app.manual_rental_role(test.id('sc_field')) || '/' || coalesce(app.manual_rental_role(test.id('renter:sc_rita')), 'none'),
  'va/va/field/none');
select test.throws('door: staff must choose sourced or entered for CarmaCars',
  format($$select app.door(%L, 'aal2', 'ops_do', 'manual_rental_create', test.s37r(test.s37v('car1'), interval '3 days', interval '5 days'))$$, test.id('sc_cs')), 'I sourced this client');
insert into s37 select 'cs1', app.door(test.id('sc_cs'), 'aal2', 'ops_do', 'manual_rental_create',
  test.s37r(test.s37v('car1'), interval '3 days', interval '6 days', '{"sales_choice": "sourced", "rental_charge_cents": 21000, "price_reason": "Returning customer, matched a quote"}'));
select test.eq('sourced: credited to the assistant, sourced, the choice recorded',
  (select (sales_staff_id = test.id('sc_cs')) || '/' || sales_sourced || '/' || sales_choice || '/' || (sales_choice_by = test.id('sc_cs')) from test.s37b('cs1')), 'true/true/sourced/true');
select test.eq('custom price: charged as typed, the rate sheet kept beside it, the reason',
  (select rental_charge_cents || '/' || rate_sheet_rental_cents || '/' || custom_price_reason from test.s37b('cs1')), '21000/30000/Returning customer, matched a quote');
select test.eq('custom price: 30% under the rate sheet is flagged (limit 20%), not blocked', (select array_to_string(price_flags, ',') from test.s37b('cs1')), 'discount_over_limit');
select test.ok('custom price: kept in the booking''s history', exists (select 1 from booking_events e where e.booking_id = (test.s37b('cs1')).id and e.kind = 'custom_price'));
select test.eq('commission: not earned yet while the rental is ahead (accruing at 10%)', (select status || '/' || rate_bps from test.s37c('cs1')), 'accruing/1000');
insert into s37 select 'fin1', app.door(test.id('sc_fin'), 'aal2', 'ops_do', 'manual_rental_create',
  test.s37r(test.s37v('car2'), interval '3 days', interval '5 days', '{"sales_choice": "for_carmacars"}'));
select test.eq('entered for CarmaCars: credited for tracking, not sourced, no commission',
  (select (sales_staff_id = test.id('sc_fin')) || '/' || sales_sourced || '/' || sales_choice from test.s37b('fin1')) || '/' || (select count(*) from staff_commissions where booking_id = (test.s37b('fin1')).id),
  'true/false/for_carmacars/0');
select test.throws('custom price: a reason is needed', format($$select app.door(%L, 'aal2', 'ops_do', 'manual_rental_create',
  test.s37r(test.s37v('car3'), interval '3 days', interval '5 days', '{"sales_choice": "sourced", "rental_charge_cents": 15000}'))$$, test.id('sc_fleet')), 'reason');
select test.throws('assistant: the Deposit is still an Admin''s', format($$select app.door(%L, 'aal2', 'ops_do', 'manual_rental_create',
  test.s37r(test.s37v('car3'), interval '3 days', interval '5 days', '{"sales_choice": "sourced", "deposit_cents": 0}'))$$, test.id('sc_fleet')), 'Deposit');
select test.throws('field staff: take no payment themselves', format($$select app.door(%L, 'aal2', 'ops_do', 'manual_rental_create',
  test.s37r(test.s37v('car3'), interval '3 days', interval '5 days', '{"sales_choice": "sourced", "payment": {"mode": "other_way", "method": "cash"}}'))$$, test.id('sc_field')), 'Choose one of the ways shown under Payment');
select test.throws('field staff: do not search renters', format($$select app.door(%L, 'aal2', 'ops_read', 'manual_rental_renters', '{"q": "sc_r"}')$$, test.id('sc_field')), 'renter''s details');
insert into s37 select 'field1', app.door(test.id('sc_field'), 'aal2', 'ops_do', 'manual_rental_create',
  test.s37r(test.s37v('car3'), interval '3 days', interval '5 days', '{"sales_choice": "sourced"}') - 'renter_id'
  || jsonb_build_object('renter', jsonb_build_object('full_name', 'Sc Rita', 'email', (select email from renters where id = test.id('renter:sc_rita')), 'mobile', '4165550199', 'date_of_birth', '1990-01-01')));
select test.eq('field staff: a payment link rental, credited and sourced, the existing renter found by email',
  (select status || '/' || (sales_staff_id = test.id('sc_field')) || '/' || sales_sourced || '/' || (renter_id = test.id('renter:sc_rita')) from test.s37b('field1')), 'pending_payment/true/true/true');
select test.eq('quote preview: everyone may type a price; staff must choose; field staff pay by link or card',
  (select (q ->> 'may_override_price') || '/' || (q ->> 'choice_required') || '/' || (q -> 'payment_modes')::text || '/' || (q ->> 'rate_sheet_cents')
     from (select app.manual_rental_quote(test.id('sc_field'), test.s37r(test.s37v('car4'), interval '3 days', interval '5 days')) q) x),
  'true/true/["link", "card"]/20000');

-- ================================================================ 3. quotes by every assistant; offers and claims
insert into s37 select 'q1', app.door(test.id('sc_fleet'), 'aal2', 'va_do', 'quote_create', jsonb_build_object('vehicle_id', test.s37v('car4'), 'source', 'phone',
  'pickup_at', date_trunc('hour', now()) + interval '20 days', 'return_at', date_trunc('hour', now()) + interval '24 days', 'full_name', 'Quinn Caller', 'email', 'sc.quinn@example.test',
  'mobile', '4165550111', 'date_of_birth', '1985-03-04', 'sales_choice', 'sourced', 'rental_charge_cents', 38000, 'price_reason', 'Four days for the price of a week minus one'));
select test.eq('quote by Fleet: a request, sourced, the price typed with the rate sheet beside it',
  (select status || '/' || sales_sourced || '/' || rental_charge_cents || '/' || rate_sheet_rental_cents from test.s37b('q1')), 'requested/true/38000/40000');
select test.throws('quote: the choice is required', format($$select app.door(%L, 'aal2', 'va_do', 'quote_create', jsonb_build_object('vehicle_id', test.s37v('car4'), 'source', 'phone',
  'pickup_at', date_trunc('hour', now()) + interval '30 days', 'return_at', date_trunc('hour', now()) + interval '32 days', 'full_name', 'Quinn Caller', 'email', 'sc.quinn@example.test',
  'mobile', '4165550111', 'date_of_birth', '1985-03-04'))$$, test.id('sc_fin')), 'I sourced this client');
-- a website request: the offer's sender says they sourced it; an Admin decides
insert into s37 select 'web1', jsonb_build_object('id', app.request_booking(test.id('renter:sc_ron'), test.s37v('car5'), date_trunc('hour', now()) + interval '40 days',
  date_trunc('hour', now()) + interval '43 days', 'standard', null, 'web', test.id('sc_ron')));
-- 0177: Sales answer a website request once it has waited request_sales_after_minutes
update bookings set requested_at = now() - interval '1 hour' where id = (test.s37b('web1')).id;
select test.throws('offer: the sender must choose', format($$select app.door(%L, 'aal2', 'va_do', 'send_offer', jsonb_build_object('booking', %L, 'expires_at', now() + interval '24 hours'))$$,
  test.id('sc_sales'), (test.s37b('web1')).id), 'I sourced this client');
select test.lives('offer: "I sourced this client" on a website request', format($$select app.door(%L, 'aal2', 'va_do', 'send_offer', jsonb_build_object('booking', %L, 'expires_at', now() + interval '24 hours', 'sales_choice', 'sourced'))$$,
  test.id('sc_sales'), (test.s37b('web1')).id));
select test.eq('website request: tracked to the sender, not sourced, a claim for an Admin',
  (select (sales_staff_id = test.id('sc_sales')) || '/' || sales_sourced || '/' || (sales_claim_by = test.id('sc_sales')) from test.s37b('web1')), 'true/false/true');
select test.ok('To do: the claim is listed', (select (i ->> 'count')::integer >= 1 from jsonb_array_elements(app.admin_todo(test.id('sc_admin')) -> 'items') i where i ->> 'key' = 'claims'));
select app.sales_claim_decide(test.id('sc_admin'), jsonb_build_object('booking', (test.s37b('web1')).id, 'accept', true, 'reason', 'The renter came from her Instagram post'));
select test.eq('claim accepted: sourced, the claim cleared, a commission accruing',
  (select sales_sourced || '/' || (sales_claim_by is null) from test.s37b('web1')) || '/' || (test.s37c('web1')).status, 'true/true/accruing');

-- ================================================================ 4. earned, approved, paid (flat 10%)
-- a completed, paid past rental the assistant sourced (last month)
select test.s37sold('cs_done', 'sc_cs', test.s37past(test.s37v('car6'), 3, 4));
select test.eq('earned: completed and paid in full, pending approval at 10% of the rental charge',
  (select c.status || '/' || c.rate_bps || '/' || (c.base_cents = app.sales_revenue_cents(c.booking_id)) || '/' || (c.amount_cents = round(c.base_cents * 0.10)) from test.s37c('cs_done') c),
  'pending_approval/1000/true/true');
select test.eq('base: like booked revenue (before tax, after discounts)', (test.s37c('cs_done')).base_cents, (select rental_charge_cents - discount_cents - staff_discount_cents - promo_discount_cents from test.s37b('cs_done')));
select test.throws('approve: an Admin only', format($$select app.door(%L, 'aal2', 'admin_do', 'commission_approve', jsonb_build_object('ids', jsonb_build_array(%L)))$$,
  test.id('sc_cs'), (test.s37c('cs_done')).id), 'admin');
select test.throws('pay: only approved commissions', format($$select app.commission_payout_record(%L, jsonb_build_object('staff', %L, 'ids', jsonb_build_array(%L), 'method', 'cash'))$$,
  test.id('sc_admin'), test.id('sc_cs'), (test.s37c('cs_done')).id), 'approved');
select app.commission_approve(test.id('sc_admin'), jsonb_build_object('ids', jsonb_build_array((test.s37c('cs_done')).id)));
select test.eq('approved: by the Admin', (select status || '/' || (approved_by = test.id('sc_admin')) from test.s37c('cs_done')), 'approved/true');
select test.ok('approved: one email event to the staff member', exists (select 1 from app_events e where e.code = 'staff_commission_approved' and e.entity_id = test.id('sc_cs')));
select test.ok('approved: the email goes to the staff member only',
  (select count(*) = 1 and bool_and(r.user_id = test.id('sc_cs')) from app_events e cross join lateral app.notification_recipients(e, (select c from notification_catalogue c where c.code = 'staff_commission_approved')) r
    where e.code = 'staff_commission_approved' and e.entity_id = test.id('sc_cs')));
select test.throws('pay: an e-Transfer needs its reference', format($$select app.commission_payout_record(%L, jsonb_build_object('staff', %L, 'method', 'e_transfer'))$$,
  test.id('sc_admin'), test.id('sc_cs')), 'reference');
select test.throws('pay: the pay statement needs its month', format($$select app.commission_payout_record(%L, jsonb_build_object('staff', %L, 'method', 'pay_statement'))$$,
  test.id('sc_admin'), test.id('sc_cs')), 'month');
insert into s37 select 'pay1', app.commission_payout_record(test.id('sc_admin'), jsonb_build_object('staff', test.id('sc_cs'), 'method', 'wise', 'reference', 'WISE-SC-1', 'paid_on', app.today()));
select test.eq('paid: recorded by hand with method and reference', (select c.status || '/' || po.method || '/' || po.reference || '/' || (po.amount_cents = c.amount_cents)
  from staff_commissions c join staff_commission_payouts po on po.id = c.payout_id where c.id = (test.s37c('cs_done')).id), 'paid/wise/WISE-SC-1/true');
select test.ok('paid: an email event with the payment', exists (select 1 from app_events e where e.code = 'staff_commission_paid' and e.entity_id = (test.s37('pay1') ->> 'payout_id')::uuid));
select test.eq('paid: the email''s values', (select x ->> 'payout_method' || '/' || (x ->> 'payout_reference') || '/' || (x ->> 'commission_count') || '/' || (x ->> 'sales_url' like '%/staff/my-sales')
  from app_events e cross join lateral app.notification_payload('staff_commission_paid', e, '{}'::jsonb) x where e.code = 'staff_commission_paid' and e.entity_id = (test.s37('pay1') ->> 'payout_id')::uuid),
  'Wise/WISE-SC-1/1/true');
-- a later refund of half the rental: the difference is clawed back
insert into refunds (booking_id, payment_id, reason, amount_cents, status, requested_by, approved_by, note)
select b.id, (select p.id from payments p where p.booking_id = b.id and p.status = 'succeeded' limit 1), 'other',
       round(b.rental_charge_cents * (10000 + b.hst_bps) / 20000.0)::bigint, 'approved', test.id('sc_admin'), test.id('sc_admin'), 'Test: half refunded'
  from test.s37b('cs_done') b;
select test.eq('refund after payment: the paid commission stays paid; a clawback of the difference, approved, for the next payout',
  (select (test.s37c('cs_done')).status || '/' || c.kind || '/' || c.status || '/' || (c.amount_cents = round((test.s37c('cs_done')).base_cents * 0.10) - (test.s37c('cs_done')).amount_cents)
     from staff_commissions c where c.clawback_of = (test.s37c('cs_done')).id), 'paid/clawback/approved/true');
select test.throws('pay: a clawback alone is nothing to pay', format($$select app.commission_payout_record(%L, jsonb_build_object('staff', %L, 'method', 'cash'))$$,
  test.id('sc_admin'), test.id('sc_cs')), 'nothing to pay');

-- ================================================================ 5. no commission: own rental, cancelled, charged back
insert into renters (id, user_id, legal_name, email, mobile, date_of_birth) values (test.id('renter:sc_own'), test.id('sc_fin'), 'Sc Fin', 'sc_fin@example.test', '4165550177', '1990-02-02');
insert into user_roles (user_id, role) values (test.id('sc_fin'), 'renter') on conflict do nothing;
insert into drivers (renter_id, is_account_holder, user_id, full_name, date_of_birth, licence_class) values (test.id('renter:sc_own'), true, test.id('sc_fin'), 'Sc Fin', '1990-02-02', 'G');
select test.s37sold('own', 'sc_fin', test.s37past(test.s37v('car7'), 3, 2, 'sc_own'));
select test.eq('own rental: no commission', (select count(*) from staff_commissions where booking_id = (test.s37b('own')).id and status not in ('void', 'reversed')), 0::bigint);
update staff_profiles set home_postal_code = 'M6P 1Z2' where user_id = test.id('sc_fleet');
update renters set postal_code = 'm6p1z2', address_line1 = '1 Sc Fleet Lane' where id = test.id('renter:sc_ron');
select test.eq('household rental: none (the renter lives at their postal code)', app.commission_own_reason((test.s37b('web1')).id, test.id('sc_fleet')), 'household rental');
update renters set postal_code = null where id = test.id('renter:sc_ron');
update bookings set status = 'cancelled' where id = (test.s37b('cs1')).id;
select test.eq('cancelled before earning: void, never shown as earned', (select status || '/' || reason from test.s37c('cs1')), 'void/Cancelled booking');

-- ================================================================ 6. the Sales tiers on last month's rental days
-- 20 + 20 + 9 = 49 days
select test.s37sold('t_a', 'sc_sales', test.s37past(test.s37v('car1'), 1, 20));
select test.s37sold('t_b', 'sc_sales', test.s37past(test.s37v('car2'), 1, 20));
select test.s37sold('t_c', 'sc_sales', test.s37past(test.s37v('car3'), 1, 9));
select test.eq('49 days: every rental of the month at 10%', (select string_agg(distinct rate_bps::text, ',') || '/' || max(tier_days) from staff_commissions where staff_id = test.id('sc_sales') and month = test.s37m() and kind = 'commission'), '1000/49');
select test.eq('49 days: the progress says it rises at 50 and 100 days', app.sales_month_progress(test.id('sc_sales'), test.s37m()) ->> 'rises', 'rises to 15% at 50 days / 20% at 100 days');
-- one more day: 50
select test.s37sold('t_d', 'sc_sales', test.s37past(test.s37v('car3'), 12, 1));
select test.eq('50 days: the whole month moves to 15%', (select string_agg(distinct rate_bps::text, ',') || '/' || max(tier_days) from staff_commissions where staff_id = test.id('sc_sales') and month = test.s37m() and kind = 'commission'), '1500/50');
select test.ok('50 days: each amount is 15% of its base', (select bool_and(amount_cents = round(base_cents * 0.15)) from staff_commissions where staff_id = test.id('sc_sales') and month = test.s37m() and kind = 'commission'));
-- 25 + 24 = 99
select test.s37sold('t_e', 'sc_sales', test.s37past(test.s37v('car4'), 1, 25));
select test.s37sold('t_f', 'sc_sales', test.s37past(test.s37v('car5'), 1, 24));
select test.eq('99 days: still 15%', (select string_agg(distinct rate_bps::text, ',') || '/' || max(tier_days) from staff_commissions where staff_id = test.id('sc_sales') and month = test.s37m() and kind = 'commission'), '1500/99');
select test.s37sold('t_g', 'sc_sales', test.s37past(test.s37v('car6'), 10, 1));
select test.eq('100 days: the whole month at 20%, the target reached', (select string_agg(distinct rate_bps::text, ',') || '/' || max(tier_days) from staff_commissions where staff_id = test.id('sc_sales') and month = test.s37m() and kind = 'commission')
  || '/' || (app.sales_month_progress(test.id('sc_sales'), test.s37m()) ->> 'progress_pct'), '2000/100/100');
select test.eq('scorecard: the target of 100 rental days', (select (app.staff_scorecard(test.id('sc_sales'), 1) -> 'sales_target' ->> 'target_days')), '100');
-- a Sales rental of this month cannot be approved before the month ends
insert into s37 select 'now1', app.manual_rental_create(test.id('sc_admin'), test.s37past(test.s37v('car7'), 1, 1) || jsonb_build_object(
  'pickup_at', app.local_midnight(app.today()) - interval '20 hours', 'return_at', app.local_midnight(app.today()) - interval '2 hours'))
  where app.local_midnight(app.today()) - interval '20 hours' >= app.local_midnight(app.month_start(app.today()));
select app.sales_reassign(test.id('sc_admin'), jsonb_build_object('booking', (test.s37b('now1')).id, 'staff', test.id('sc_sales'), 'sourced', true, 'reason', 'Test')) where test.s37('now1') is not null;
select test.ok('this month: a Sales commission waits for the month to end', test.s37('now1') is null or (select (c.status = 'pending_approval') from test.s37c('now1') c));
select test.throws('this month: approving a Sales month still open is refused', format($$select app.commission_approve(%L, jsonb_build_object('ids', jsonb_build_array(%L)))$$,
  test.id('sc_admin'), coalesce((test.s37c('now1')).id, (select id from staff_commissions where staff_id = test.id('sc_sales') and month = test.s37m() limit 1))),
  case when test.s37('now1') is null then 'pending approval' else 'month ends' end);
-- the month's job after the month ended: recalculated, a task for the Admins
select test.eq('month job: runs once after the month', app.job_commission_month(app.local_midnight(app.month_start(app.today())) + interval '7 hours') || '/' ||
  app.job_commission_month(app.local_midnight(app.month_start(app.today())) + interval '8 hours'), 'succeeded/already_run');
select test.ok('month job: an approval task for the Admins', exists (select 1 from tasks where dedupe_key = 'approve_commissions:' || test.s37m() and queue = 'admin'));
-- approve and pay last month; then a refund drops the month to 99 days
select app.commission_approve(test.id('sc_admin'), jsonb_build_object('staff', test.id('sc_sales'), 'month', test.s37m()));
select app.commission_payout_record(test.id('sc_admin'), jsonb_build_object('staff', test.id('sc_sales'), 'method', 'pay_statement', 'pay_period', test.s37m() + interval '1 month'));
select test.eq('paid at 20%: all seven', (select count(*) || '/' || string_agg(distinct rate_bps::text, ',') from staff_commissions where staff_id = test.id('sc_sales') and month = test.s37m() and kind = 'commission' and status = 'paid'), '7/2000');
insert into refunds (booking_id, payment_id, reason, amount_cents, status, requested_by, approved_by, note)
select b.id, (select p.id from payments p where p.booking_id = b.id and p.status = 'succeeded' limit 1), 'other',
       (select sum(p.amount_cents) from payments p where p.booking_id = b.id and p.status = 'succeeded'), 'approved', test.id('sc_admin'), test.id('sc_admin'), 'Test: refunded in full'
  from test.s37b('t_g') b;
select test.eq('refund below the tier: the refunded rental clawed back in full', (select sum(amount_cents) from staff_commissions where clawback_of = (test.s37c('t_g')).id), -(test.s37c('t_g')).amount_cents);
select test.ok('refund below the tier: the month is back at 99 days, and the other six get a clawback of 20% less 15%',
  (select bool_and((select sum(x.amount_cents) from staff_commissions x where x.clawback_of = c.id) = round(c.base_cents * 0.15) - c.amount_cents)
     from staff_commissions c where c.staff_id = test.id('sc_sales') and c.month = test.s37m() and c.kind = 'commission' and c.booking_id <> (test.s37b('t_g')).id)
  and app.commission_month_days(test.id('sc_sales'), test.s37m()) = 99);
select test.eq('My sales: the totals show the reversal', (select (app.staff_sales(test.id('sc_sales'), test.id('sc_sales'), '{}') -> 'commissions' -> 'totals' ->> 'reversed')::bigint > 0), true);

-- ================================================================ 7. chargebacks, an Admin's reversal, a person's own rate
select test.s37sold('cb', 'sc_cs', test.s37past(test.s37v('car7'), 14, 2));
insert into disputes (payment_id, booking_id, amount_cents, status) select p.id, p.booking_id, p.amount_cents, 'lost' from payments p where p.booking_id = (test.s37b('cb')).id and p.status = 'succeeded' limit 1;
select test.eq('charged back: reversed', (select status || '/' || reason from test.s37c('cb')), 'reversed/Charged back');
select test.s37sold('rev', 'sc_cs', test.s37past(test.s37v('car7'), 18, 2));
select app.commission_reverse(test.id('sc_admin'), jsonb_build_object('id', (test.s37c('rev')).id, 'reason', 'Household rental found later'));
select test.eq('Admin reversal: reversed with the reason, and it stays so', (select status || '/' || reason || '/' || admin_reversed from test.s37c('rev')), 'reversed/Household rental found later/true');
select app.staff_commission_rate_set(test.id('sc_admin'), jsonb_build_object('staff', test.id('sc_cs'), 'bps', 1200, 'reason', 'Test rate'));
select test.eq('own rate: an Admin''s flat rate for one person', app.commission_scheme(test.id('sc_cs')) || '/' || (app.sales_month_progress(test.id('sc_cs')) ->> 'rate_bps'), 'override/1200');
select app.staff_commission_rate_set(test.id('sc_admin'), jsonb_build_object('staff', test.id('sc_cs'), 'bps', null, 'reason', 'Back to the setting'));

-- ================================================================ 8. owners: commissions are kickbacks before Owner Revenue
select test.s37sold('own_car', 'sc_cs', test.s37past(test.id('vehicle:sc_prog'), 5, 3));
select test.eq('owner''s car: the staff commission is deducted with the kickbacks before Owner Revenue',
  (select (s.staff_commission_cents = c.amount_cents) || '/' || (s.kickback_cents = s.staff_commission_cents) || '/' || (s.owner_revenue_cents = s.rental_charge_cents + s.mileage_overage_cents - s.kickback_cents)
     from booking_splits s, test.s37c('own_car') c where s.booking_id = c.booking_id), 'true/true/true');
select test.ok('owner''s car: the Revenue Share is taken after the commission',
  (select s.company_share_cents = (select x.company_share_cents from public.calc_split(s.rental_charge_cents, s.mileage_overage_cents, s.kickback_cents, s.company_share_bps) x)
     from booking_splits s where s.booking_id = (test.s37b('own_car')).id));
select test.eq('CarmaCars-owned car: nothing deducted (a CarmaCars expense)', (select coalesce(sum(staff_commission_cents), 0) from booking_splits where booking_id = (test.s37b('t_a')).id), 0::bigint);
-- the statement: its own line, and a change after it on the next statement
select app.build_owner_statement(test.id('owner:sc_olive'), test.s37m());
select test.ok('statement: the rental line carries the staff commission apart from the referral kickback',
  (select l.staff_commission_cents = (test.s37c('own_car')).amount_cents from owner_statement_lines l where l.booking_id = (test.s37b('own_car')).id and l.line_type = 'rental'));
update booking_splits s set owner_statement_id = (select l.owner_statement_id from owner_statement_lines l where l.booking_id = s.booking_id and l.line_type = 'rental' limit 1)
 where s.booking_id = (test.s37b('own_car')).id;
select app.staff_commission_rate_set(test.id('sc_admin'), jsonb_build_object('staff', test.id('sc_cs'), 'bps', 1500, 'reason', 'Test: raised after the statement'));
select test.ok('after the statement: the Owner''s share of a higher commission is an adjustment for the next statement',
  exists (select 1 from owner_deductions d where d.booking_id = (test.s37b('own_car')).id and d.kind = 'staff_commission_adjustment' and d.status = 'open' and d.amount_cents > 0));
select app.staff_commission_rate_set(test.id('sc_admin'), jsonb_build_object('staff', test.id('sc_cs'), 'bps', null, 'reason', 'Back to the setting'));
select test.ok('after the statement: a lower commission is a credit for the next statement',
  exists (select 1 from owner_credits c where c.booking_id = (test.s37b('own_car')).id and c.kind = 'staff_commission_adjustment' and c.status = 'open'));

-- ================================================================ 9. field staff referrals: the same commission
insert into s37 select 'ref', jsonb_build_object('id', app.request_booking(test.id('renter:sc_ron'), test.id('vehicle:sc_prog'), date_trunc('hour', now()) + interval '50 days',
  date_trunc('hour', now()) + interval '52 days', 'standard', null, 'web', test.id('sc_ron'), 'SCFIELD'));
select test.eq('referral code: the field staff member sourced it', (select (sales_staff_id = test.id('sc_field')) || '/' || sales_sourced || '/' || sales_source from test.s37b('ref')), 'true/true/referral');
select test.eq('referral: no 20% Referral Kickback on top (the 10% commission is the referral fee)', app.kickback_ineligible_reason((test.s37b('ref')).id), 'staff referral: earns the staff commission instead');
select test.eq('referral: the field page shows the commission rate', (app.field_referrals(test.id('sc_field')) ->> 'rate_bps'), '1000');

-- ================================================================ 10. To do, the doors, privileges
select test.ok('To do: prices to review and commissions to pay are counted', (select count(*) = 2 from jsonb_array_elements(app.admin_todo(test.id('sc_admin')) -> 'items') i where i ->> 'key' in ('prices', 'commissions_pay')));
select app.price_review(test.id('sc_admin'), jsonb_build_object('booking', (test.s37b('q1')).id, 'note', 'Agreed with the renter'));
select test.ok('price review: marked reviewed', (select price_reviewed_at is not null from test.s37b('q1')));
select test.ok('My sales: every staff function, with commissions', (app.door(test.id('sc_fin'), 'aal2', 'va_read', 'my_sales', '{}') -> 'commissions') is not null
  and (app.door(test.id('sc_field'), 'aal2', 'field_read', 'my_sales', '{}') -> 'commissions') is not null);
select test.throws('Staff commissions: Admins only', format($$select app.door(%L, 'aal2', 'admin_read', 'commissions', '{}')$$, test.id('sc_sales')), 'admin');
select test.ok('Staff commissions: the people and rows for an Admin', jsonb_array_length(app.door(test.id('sc_admin'), 'aal2', 'admin_read', 'commissions', '{}') -> 'people') >= 2);
select test.ok('privileges: a browser session cannot run the commission functions',
  not has_function_privilege('authenticated', 'app.commission_approve(uuid, jsonb)', 'execute') and not has_function_privilege('authenticated', 'app.commission_payout_record(uuid, jsonb)', 'execute')
  and not has_function_privilege('anon', 'app.commission_sync(uuid)', 'execute'));
select test.ok('tables: row-level security on the commission tables', (select bool_and(relrowsecurity) from pg_class where relname in ('staff_commissions', 'staff_commission_payouts')));
select test.ok('catalogue: both staff emails are emitted by something', (select count(*) = 2 from notification_catalogue where code in ('staff_commission_approved', 'staff_commission_paid') and emitted_by is not null));
