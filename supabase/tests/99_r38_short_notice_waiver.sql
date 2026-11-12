-- 99: "Waive short-notice upcharge" (2370): Admin or staff, with a reason, audited; offers, Add a rental and extensions;
-- the owner's minimum daily rate (1205) still applies to staff. Fixtures start with "sw".
select test.suite('99 r38 short-notice waiver');
create temp table sw_prog as select id, lead_time_enabled, weekend_premium_bps from program_settings;
update program_settings set lead_time_enabled = true, weekend_premium_bps = 0 where id is not null;
select test.mk_user('sw_admin', 'admin');
select test.mk_user('sw_sales', 'va', 'sales');
select test.mk_renter('sw_rita');
update staff_profiles set single_limit_cents = 500000 where user_id = test.id('sw_sales');

create temp table s99sw as select null::text as k, null::jsonb as v limit 0;
do $$
declare i integer;
begin
  for i in 1 .. 4 loop
    insert into s99sw select 'car' || i, app.vehicle_add(test.id('sw_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1SWCXMM00000000' || lpad(i::text, 2, '0'),
      'plate', 'SWC00' || i, 'year', 2024, 'make', 'Kia', 'model', 'K5', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
  end loop;
end $$;
-- three days from 10 hours from now: +15% short notice on $300.00 ($45.00)
create or replace function test.s99sw(p_car text, p jsonb default '{}'::jsonb) returns jsonb language sql stable as $$
  select jsonb_build_object('vehicle_id', (select (v ->> 'vehicle_id')::uuid from pg_temp.s99sw where k = p_car),
    'pickup_at', date_trunc('hour', now()) + interval '10 hours', 'return_at', date_trunc('hour', now()) + interval '82 hours', 'renter_id', test.id('renter:sw_rita'),
    'coverage_option', 1, 'source', 'phone', 'rental_pay_method', 'card', 'deposit_pay_method', 'card', 'sales_choice', 'for_carmacars',
    'payment', jsonb_build_object('mode', 'link')) || p $$;
create or replace function test.s99swl(p_lines jsonb, p_type text) returns bigint language sql stable as $$
  select sum((l ->> 'amount_cents')::bigint) from jsonb_array_elements(p_lines) l where l ->> 'charge_type' = p_type $$;
create or replace function test.s99swb(p_k text) returns bookings language sql stable as $$
  select * from bookings where id = (select (v ->> 'booking_id')::uuid from pg_temp.s99sw where k = p_k) $$;
create or replace function test.s99swi(p_booking uuid, p_type text) returns bigint language sql stable as $$
  select sum(amount_cents) from booking_line_items where booking_id = p_booking and charge_type = p_type and voided_at is null $$;

-- ================================================================ offers
select test.eq('an offer for pickup in 10 hours has the short-notice line (+15% of $300.00)',
  (select test.s99swl(x #> '{booking,lines}', 'lead_time') from (select app.door(test.id('sw_sales'), 'aal2', 'ops_read', 'offer_preview', test.s99sw('car1')) x) q), 4500::bigint);
select test.eq('waived with a reason (staff): no short-notice line, the rental charge is the rate sheet''s',
  (select coalesce(test.s99swl(x #> '{booking,lines}', 'lead_time'), 0) || ' ' || test.s99swl(x #> '{booking,lines}', 'rental_charge')
     from (select app.door(test.id('sw_sales'), 'aal2', 'ops_read', 'offer_preview', test.s99sw('car1', '{"waive_short_notice": true, "short_notice_waive_reason": "Regular renter, agreed on the phone"}')) x) q), '0 30000');
select test.ok('waiving without a reason is refused',
  (select x ->> 'error' from (select app.door(test.id('sw_sales'), 'aal2', 'ops_read', 'offer_preview', test.s99sw('car1', '{"waive_short_notice": true}')) x) q) like '%reason for waiving%');
select test.throws('a renter never waives it', $$select app.short_notice_waive_begin(test.id('sw_rita'), '{"waive_short_notice": true, "short_notice_waive_reason": "please"}')$$, '%Admin or staff%');
insert into s99sw select 'offer', app.door(test.id('sw_sales'), 'aal2', 'ops_do', 'offer_create',
  test.s99sw('car1', '{"waive_short_notice": true, "short_notice_waive_reason": "Regular renter", "notify": false}'));
select test.eq('the offer made keeps the waiver: who, why and the +15% it took away, and no line',
  (select (b.short_notice_waived_by = test.id('sw_sales'))::text || ' ' || b.short_notice_waive_reason || ' ' || b.short_notice_waived_bps || ' ' || coalesce(b.lead_time_bps, 0)
     from test.s99swb('offer') b), 'true Regular renter 1500 0');
select test.eq('no short-notice line on the offer', coalesce(test.s99swi((test.s99swb('offer')).id, 'lead_time'), 0), 0::bigint);
select test.ok('the waiver is in the audit log', exists (select 1 from audit_log where action = 'short_notice_waive' and entity_id = (test.s99swb('offer')).id::text and actor_user_id = test.id('sw_sales')));
select test.ok('the waiver is waived for this call only: the next offer has the line again',
  (select test.s99swl(x #> '{booking,lines}', 'lead_time') from (select app.door(test.id('sw_sales'), 'aal2', 'ops_read', 'offer_preview', test.s99sw('car2')) x) q) = 4500);

-- the owner's minimum still applies to staff: $110.00 a day on the car, the waiver cannot take it under
update vehicles set price_min_daily_cents = 11000 where id = (select (v ->> 'vehicle_id')::uuid from s99sw where k = 'car3');
select test.eq('staff within the price limits: waived, the minimum daily rate brings it back to $330.00',
  (select (x #>> '{booking,subtotal_at_booking_cents}')::bigint from (select app.door(test.id('sw_sales'), 'aal2', 'ops_read', 'offer_preview',
     test.s99sw('car3', '{"waive_short_notice": true, "short_notice_waive_reason": "Regular renter"}')) x) q), 33000::bigint);

-- ================================================================ Add a rental
select test.eq('Add a rental''s check shows the short-notice line its booking gets',
  (select test.s99swl(x #> '{quote,lines}', 'lead_time') from (select app.door(test.id('sw_admin'), 'aal2', 'ops_read', 'manual_rental_quote', test.s99sw('car2')) x) q), 4500::bigint);
select test.eq('a pickup already passed (a walk-in, picked up yesterday) is not short notice: no line in the check',
  (select coalesce(test.s99swl(x #> '{quote,lines}', 'lead_time'), 0) from (select app.door(test.id('sw_admin'), 'aal2', 'ops_read', 'manual_rental_quote',
     test.s99sw('car2', jsonb_build_object('pickup_at', date_trunc('hour', now()) - interval '24 hours', 'return_at', date_trunc('hour', now()) + interval '48 hours'))) x) q), 0::bigint);
select test.eq('waived in the check: no line, and the check says so',
  (select coalesce(test.s99swl(x #> '{quote,lines}', 'lead_time'), 0) || ' ' || (x ->> 'short_notice_waived') from (select app.door(test.id('sw_admin'), 'aal2', 'ops_read', 'manual_rental_quote',
     test.s99sw('car2', '{"waive_short_notice": true, "short_notice_waive_reason": "Insurer approved rate"}')) x) q), '0 true');
insert into s99sw select 'manual', app.door(test.id('sw_admin'), 'aal2', 'ops_do', 'manual_rental_create',
  test.s99sw('car2', '{"waive_short_notice": true, "short_notice_waive_reason": "Insurer approved rate"}'));
select test.eq('the rental added by hand has no short-notice line and keeps the waiver',
  coalesce(test.s99swi((test.s99swb('manual')).id, 'lead_time'), 0) || ' ' || (test.s99swb('manual')).short_notice_waive_reason, '0 Insurer approved rate');
select test.ok('the rental''s history says it was waived and why',
  exists (select 1 from booking_events e where e.booking_id = (test.s99swb('manual')).id and e.note like 'Short-notice upcharge (+15%) waived: Insurer approved rate%'));

-- ================================================================ on a booking made already, and extensions
insert into s99sw select 'plain', app.door(test.id('sw_admin'), 'aal2', 'ops_do', 'manual_rental_create', test.s99sw('car4'));
select test.eq('without the switch the rental has the line ($45.00)', test.s99swi((test.s99swb('plain')).id, 'lead_time'), 4500::bigint);
insert into s99sw select 'allin0', app.booking_all_in((test.s99swb('plain')).id);
select test.throws('a booking waived without a reason is refused', format($$select app.door(test.id('sw_sales'), 'aal2', 'ops_do', 'short_notice_waive', '{"booking_id": "%s"}')$$, (test.s99swb('plain')).id), '%reason for waiving%');
select test.throws('a renter never waives a booking''s upcharge', format($$select app.short_notice_waive(test.id('sw_rita'), '{"booking_id": "%s", "reason": "please waive"}')$$, (test.s99swb('plain')).id), '%Admin or staff%');
-- the extension rule (1201) on a booking whose line was charged and then waived: the all-in price a day leaves it out
update bookings set short_notice_waived_at = now(), short_notice_waived_by = test.id('sw_admin'), short_notice_waive_reason = 'Extension goodwill', short_notice_waived_bps = 1500
 where id = (test.s99swb('plain')).id;
select test.eq('an extension''s all-in price a day leaves a waived line out ($45.00 + $5.85 HST over 3 days: $16.95 a day less)',
  (select (v ->> 'per_day_cents')::bigint from s99sw where k = 'allin0') - (app.booking_all_in((test.s99swb('plain')).id) ->> 'per_day_cents')::bigint, 1695::bigint);
update bookings set short_notice_waived_at = null, short_notice_waived_by = null, short_notice_waive_reason = null, short_notice_waived_bps = null
 where id = (test.s99swb('plain')).id;
-- a booking waiting for payment is not priced again (withdraw the offer first); a confirmed one keeps its line for extensions
select test.throws('waived on a booking waiting for payment: refused (an offer out is withdrawn first)',
  format($$select app.door(test.id('sw_sales'), 'aal2', 'ops_do', 'short_notice_waive', '{"booking_id": "%s", "reason": "Regular renter"}')$$, (test.s99swb('plain')).id), '%withdraw it%');
-- confirmed as if signed and paid (the fixture skips the agreement; the triggers are off for this one row only)
set session_replication_role = replica;
update bookings set status = 'confirmed' where id = (test.s99swb('plain')).id;
set session_replication_role = origin;
insert into s99sw select 'w', app.door(test.id('sw_sales'), 'aal2', 'ops_do', 'short_notice_waive', jsonb_build_object('booking_id', (test.s99swb('plain')).id, 'reason', 'Extension goodwill'));
select test.eq('waived on a confirmed booking: the line charged stays, extensions leave it out',
  test.s99swi((test.s99swb('plain')).id, 'lead_time') || ' ' || ((select (v ->> 'per_day_cents')::bigint from s99sw where k = 'allin0') - (app.booking_all_in((test.s99swb('plain')).id) ->> 'per_day_cents')::bigint),
  '4500 1695');
insert into s99sw select 'u', app.door(test.id('sw_admin'), 'aal2', 'ops_do', 'short_notice_waive', jsonb_build_object('booking_id', (test.s99swb('plain')).id, 'waive', false, 'reason', 'Renter changed the dates'));
select test.eq('taken back by an Admin: the waiver is gone and extensions count the line again',
  ((test.s99swb('plain')).short_notice_waived_at is null)::text || ' ' || (app.booking_all_in((test.s99swb('plain')).id) ->> 'per_day_cents'),
  'true ' || (select v ->> 'per_day_cents' from s99sw where k = 'allin0'));
select test.ok('both changes are in the audit log', (select count(*) from audit_log where entity_id = (test.s99swb('plain')).id::text and action in ('short_notice_waive', 'short_notice_unwaive')) = 2);

-- the settings as they were (99_weekend_above_daily and later suites read the weekend premium), and the cards made at 0%
-- raised again by their own rule (0271's trigger)
update program_settings p set lead_time_enabled = w.lead_time_enabled, weekend_premium_bps = w.weekend_premium_bps from sw_prog w where w.id = p.id;
update rate_cards set weekend_rate_cents = weekend_rate_cents where effective_to is null and weekend_rate_cents <= daily_rate_cents;
