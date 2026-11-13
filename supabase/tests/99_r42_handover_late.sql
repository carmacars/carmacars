-- 99: a late return is a choice, never a charge by itself, and what the one-screen handover prefills (2660, release 42,
-- docs/changes/2026-11-12-r42-handover.md). Uses only helpers.sql. Fixtures start with "lh".
select test.suite('99 r42 late return choice and handover defaults (2660)');

select test.mk_user('lh_admin', 'admin');
select test.mk_user('lh_fleet', 'va', 'fleet');
select test.mk_user('lh_cs', 'va', 'cs');
select test.mk_user('lh_mkt', 'owner');
update staff_profiles set single_limit_cents = 10000 where user_id = test.id('lh_cs');
select test.mk_owner('lh_o');
select test.mk_vehicle('LHV', 'lh_o');
select test.mk_renter('lh_r');
create function test.lh_line(p_number text, p_key text) returns text language sql as $$
  select coalesce((select li.amount_cents || '+' || li.hst_cents from booking_line_items li
    where li.booking_id = test.id('booking:' || p_number) and li.assessment_key = p_key and li.voided_at is null and li.amount_cents > 0), 'none') $$;
create function test.lh_decide(p_user text, p_number text, p jsonb) returns jsonb language sql as $$
  select public.door(test.id(p_user), null, 'ops_do', 'late_return_decide', p || jsonb_build_object('booking', test.id('booking:' || p_number))) $$;
create function test.lh_late(p_number text, p_minutes integer) returns void language plpgsql as $$
begin
  set session_replication_role = replica;
  update bookings set checked_in_at = return_at + make_interval(mins => p_minutes), minutes_late = p_minutes, extra_days = p_minutes / 1440
   where id = test.id('booking:' || p_number);
  set session_replication_role = origin;
end $$;

-- ---------------------------------------------------------------- 1. back 26 hours late: nothing is charged by itself
select test.mk_booking('LH-1', 'LHV', 'lh_r', '2031-03-03 10:00', '2031-03-05 10:00', 'returned');
select test.lh_late('LH-1', 1560);
create temp table lh_cost as select app.booking_daily_cost_cents(test.id('booking:LH-1')) d,
  (select t.amount_cents from app.booking_fee_term(test.id('booking:LH-1'), 'late_return_fee') t) h;
select app.late_return_assess(test.id('booking:LH-1'));
select test.eq('late: a pending choice, no late line, one To do for Fleet',
  (select status from late_return_decisions where booking_id = test.id('booking:LH-1')) || '/' || test.lh_line('LH-1', 'late_return_extra_days') || '/' || test.lh_line('LH-1', 'late_return_fee')
  || '/' || (select count(*) || ':' || min(queue) from tasks where booking_id = test.id('booking:LH-1') and task_type = 'late_return_decision' and status = 'open'),
  'pending/none/none/1:fleet');
select app.late_return_assess(test.id('booking:LH-1'));
select test.eq('late: assessing again makes no second To do', (select count(*) from tasks where booking_id = test.id('booking:LH-1') and task_type = 'late_return_decision'), 1::bigint);

create temp table lh_o as select public.door(test.id('lh_cs'), null, 'ops_read', 'late_return', jsonb_build_object('booking', test.id('booking:LH-1'))) r;
select test.eq('options: late by 1 d 2 h; an extension is 2 started days, extra days 1 of up to 2, at the daily cost',
  (select (r ->> 'late') || '/' || (r ->> 'late_text') || '/' || (r #>> '{options,0,days}') || ':' || (r #>> '{options,0,amount_cents}')
          || '/' || (r #>> '{options,1,days}') || ':' || (r #>> '{options,1,max_days}') || ':' || (r #>> '{options,1,amount_cents}') from lh_o),
  'true/1 d 2 h/2:' || (select 2 * d from lh_cost) || '/1:2:' || (select d from lh_cost));
select test.eq('options: the late return fee of the terms is one day and two started hours',
  (select (r #>> '{options,2,amount_cents}')::bigint from lh_o), (select d + 2 * h from lh_cost));
select test.eq('options: customer service decides, does not waive, has its single limit',
  (select (r #>> '{may,decide}') || '/' || (r #>> '{may,waive}') || '/' || (r #>> '{may,limit_cents}') from lh_o), 'true/false/10000');
select test.throws('who: someone outside operations does not read it',
  format($$select public.door(%L, null, 'ops_read', 'late_return', jsonb_build_object('booking', %L))$$, test.id('lh_mkt'), test.id('booking:LH-1')), 'Not permitted');
select test.throws('who: someone outside operations does not choose', $$select test.lh_decide('lh_mkt', 'LH-1', '{"option": "late_fee"}')$$, 'choose the late return charge');
select test.throws('choice: one of the five', $$select test.lh_decide('lh_cs', 'LH-1', '{"option": "double"}')$$, 'Choose how the late return is charged');
select test.throws('choice: extra days from 1 to the started days', $$select test.lh_decide('lh_cs', 'LH-1', '{"option": "extra_days", "days": 3}')$$, 'Choose 1 to 2');
select test.throws('choice: a custom amount needs its reason', $$select test.lh_decide('lh_cs', 'LH-1', '{"option": "custom", "amount_cents": 4000}')$$, 'Say what the amount is for');
select test.throws('choice: a waiver needs its reason', $$select test.lh_decide('lh_fleet', 'LH-1', '{"option": "waive"}')$$, 'Say why');

-- ---------------------------------------------------------------- 2. above the limit, and a waiver: an Admin's
create temp table lh_n as select test.lh_decide('lh_cs', 'LH-1', '{"option": "custom", "amount_cents": 15000, "reason": "Missed the next rental"}') r;
select test.eq('limit: a custom amount above the single limit waits for an Admin: nothing charged, an Admin To do, the Fleet one closed',
  (select r ->> 'status' from lh_n) || '/' || (select status || ':' || option from late_return_decisions where booking_id = test.id('booking:LH-1'))
  || '/' || test.lh_line('LH-1', 'late_return_fee')
  || '/' || (select count(*) || ':' || min(queue) from tasks where booking_id = test.id('booking:LH-1') and task_type = 'late_return_approval' and status = 'open')
  || '/' || (select status from tasks where booking_id = test.id('booking:LH-1') and task_type = 'late_return_decision'),
  'needs_admin/needs_admin:custom/none/1:admin/done');
select test.throws('limit: only an Admin approves', $$select test.lh_decide('lh_fleet', 'LH-1', '{"approve": true}')$$, 'An Admin approves');
create temp table lh_a as select test.lh_decide('lh_admin', 'LH-1', '{"approve": true}') r;
select test.eq('approve: the custom amount is the late fee line with HST, no extra day line, the To do closed, the renter told once',
  (select r ->> 'status' from lh_a) || '/' || test.lh_line('LH-1', 'late_return_fee') || '/' || test.lh_line('LH-1', 'late_return_extra_days')
  || '/' || (select status from tasks where booking_id = test.id('booking:LH-1') and task_type = 'late_return_approval')
  || '/' || (select count(*) from messages where booking_id = test.id('booking:LH-1') and subject = 'Your late return charge' and body like '%Missed the next rental%'),
  'decided/15000+1950/none/done/1');
select test.eq('approve: audited, and in the booking history',
  (select count(*) from audit_log where action = 'late_return_decided' and entity_id = test.id('booking:LH-1')::text and actor_user_id = test.id('lh_admin'))
  || '/' || (select count(*) from booking_events where booking_id = test.id('booking:LH-1') and kind = 'late_return_decided'), '1/2');
select test.throws('decided: staff do not change it', $$select test.lh_decide('lh_cs', 'LH-1', '{"option": "late_fee"}')$$, 'an Admin changes it');

-- ---------------------------------------------------------------- 3. each way writes its lines (an Admin changes the choice)
select test.lh_decide('lh_admin', 'LH-1', '{"option": "extension"}');
select test.eq('extension: every started day at the daily cost, no hourly fee',
  test.lh_line('LH-1', 'late_return_extra_days') || '/' || test.lh_line('LH-1', 'late_return_fee'),
  (select 2 * d || '+' || public.calc_hst(2 * d) from lh_cost) || '/none');
select test.lh_decide('lh_admin', 'LH-1', '{"option": "extra_days", "days": 1}');
select test.eq('extra days: the days chosen at the daily cost', test.lh_line('LH-1', 'late_return_extra_days') || '/' || test.lh_line('LH-1', 'late_return_fee'),
  (select d || '+' || public.calc_hst(d) from lh_cost) || '/none');
select test.lh_decide('lh_admin', 'LH-1', '{"option": "late_fee"}');
select test.eq('late fee: the terms, one extra day and two started hours', test.lh_line('LH-1', 'late_return_extra_days') || '/' || test.lh_line('LH-1', 'late_return_fee'),
  (select d || '+' || public.calc_hst(d) || '/' || 2 * h || '+' || public.calc_hst(2 * h) from lh_cost));
select app.late_return_assess(test.id('booking:LH-1'));
select test.eq('late fee: the next assessment keeps the choice', test.lh_line('LH-1', 'late_return_fee'), (select 2 * h || '+' || public.calc_hst(2 * h) from lh_cost));
select test.lh_decide('lh_admin', 'LH-1', '{"option": "waive", "reason": "Road closed, called ahead"}');
select test.eq('waive: no late line, the reason kept, the renter told there is no charge',
  test.lh_line('LH-1', 'late_return_extra_days') || '/' || test.lh_line('LH-1', 'late_return_fee')
  || '/' || (select option || ':' || reason from late_return_decisions where booking_id = test.id('booking:LH-1'))
  || '/' || (select count(*) from messages where booking_id = test.id('booking:LH-1') and subject = 'Your late return: no charge'),
  'none/none/waive:Road closed, called ahead/1');

-- ---------------------------------------------------------------- 4. within limits, waivers, and not late
select test.mk_booking('LH-2', 'LHV', 'lh_r', '2031-03-10 10:00', '2031-03-12 10:00', 'returned');
select test.lh_late('LH-2', 190);
select app.late_return_assess(test.id('booking:LH-2'));
create temp table lh_w as select test.lh_decide('lh_cs', 'LH-2', '{"option": "waive", "reason": "Traffic on the 401"}') r;
select test.eq('waive: customer service asks, an Admin decides', (select r ->> 'status' from lh_w), 'needs_admin');
create temp table lh_c as select test.lh_decide('lh_cs', 'LH-2', '{"option": "custom", "amount_cents": 4000, "reason": "Half the fee, agreed by phone"}') r;
select test.eq('custom: inside the single limit it is charged at once',
  (select r ->> 'status' from lh_c) || '/' || test.lh_line('LH-2', 'late_return_fee')
  || '/' || (select count(*) from tasks where booking_id = test.id('booking:LH-2') and task_type in ('late_return_decision', 'late_return_approval') and status = 'open'),
  'decided/4000+520/0');
select test.mk_booking('LH-3', 'LHV', 'lh_r', '2031-03-17 10:00', '2031-03-19 10:00', 'returned');
select test.lh_late('LH-3', 190);
select app.late_return_assess(test.id('booking:LH-3'));
select test.eq('waive: Fleet waives at once', (test.lh_decide('lh_fleet', 'LH-3', '{"option": "waive", "reason": "Our car wash was closed"}') ->> 'status'), 'decided');
select test.lh_late('LH-3', 10);
select app.late_return_assess(test.id('booking:LH-3'));
select test.eq('not late any more (the time was corrected inside the grace period): no decision is kept',
  (select count(*) from late_return_decisions where booking_id = test.id('booking:LH-3')), 0::bigint);
select test.throws('not late: there is nothing to choose', $$select test.lh_decide('lh_admin', 'LH-3', '{"option": "late_fee"}')$$, 'did not come back late');
select test.mk_booking('LH-4', 'LHV', 'lh_r', '2031-03-24 10:00', '2031-03-26 10:00', 'on_rent');
select test.throws('still out: chosen once the car is back', $$select test.lh_decide('lh_admin', 'LH-4', '{"option": "late_fee"}')$$, 'once the car is back');

-- ---------------------------------------------------------------- 5. what the one-screen handover prefills
select test.eq('defaults, a pickup with no Tracker and no report: fuel full, one key, no cleanliness',
  (select (r ->> 'fuel_pct') || ':' || (r ->> 'fuel_from') || '/' || (r ->> 'keys_count') || ':' || (r ->> 'keys_from') || '/' || coalesce(r ->> 'cleanliness', 'none')
     from app.handover_defaults(test.id('vehicle:LHV'), test.id('booking:LH-4'), 'pickup') r), '100:full/1:one/none');
insert into condition_reports (vehicle_id, booking_id, kind, performed_by, performed_by_role, completed_at, odometer_km, fuel_pct, keys_count)
values (test.id('vehicle:LHV'), test.id('booking:LH-4'), 'pickup', test.id('lh_fleet'), 'staff', now(), 31000, 75, 2);
select test.eq('defaults, the return: the fuel and keys of the pickup, Standard, the odometer left to type (never lower than at pickup)',
  (select coalesce(r ->> 'odometer_km', 'none') || '/' || (r ->> 'fuel_pct') || ':' || (r ->> 'fuel_from') || '/' || (r ->> 'keys_count') || ':' || (r ->> 'keys_from') || '/' || (r ->> 'cleanliness')
     from app.handover_defaults(test.id('vehicle:LHV'), test.id('booking:LH-4'), 'return') r), 'none/75:pickup/2:pickup/clean');
select test.eq('defaults, the next pickup: the odometer, fuel and keys of the car''s last report',
  (select (r ->> 'odometer_km') || ':' || (r ->> 'odometer_from') || '/' || (r ->> 'fuel_pct') || ':' || (r ->> 'fuel_from') || '/' || (r ->> 'keys_count')
     from app.handover_defaults(test.id('vehicle:LHV'), null, 'pickup') r), '31000:last_report/75:last_report/2');
select test.eq('only the server may call the new functions',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname in ('late_return_decide', 'late_return_options', 'late_return_assess', 'late_return_write', 'handover_defaults')
      and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))), 0::bigint);
