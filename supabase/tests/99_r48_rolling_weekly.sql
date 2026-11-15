-- 99: long-term rentals paid weekly (2981, docs/changes/2026-11-14-r48-rolling-weekly.md). Fixtures start with "r8w"
-- and use example.test only. Times are relative to the clock.
select test.suite('99 r48 rolling weekly');

select test.mk_user('r8w_admin', 'admin');
select test.mk_user('r8w_cs', 'va', 'cs');
select test.mk_user('r8w_field', 'field', null, 'driver_detailer');
select test.mk_owner('r8w_olive');
select test.mk_renter('r8w_rita');
select test.mk_renter('r8w_ivan');
select test.mk_vehicle('r8w_a', 'r8w_olive');
select test.mk_vehicle('r8w_b', 'r8w_olive');
update renters set mobile = '+14165550248' where id = test.id('renter:r8w_rita');

create or replace function test.rw(p_shift interval) returns text language sql stable as $$
  select to_char((now() + p_shift) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI')
$$;
create or replace function test.r8w_do(p_who text, p_name text, p jsonb) returns jsonb language sql as $$
  select app.door(test.id(p_who), 'aal2', 'ops_do', p_name, p)
$$;

-- a car out, returning in a day (inside the 48 hour lead)
select test.mk_booking('RW-1', 'r8w_a', 'r8w_rita', test.rw('-5 days'), test.rw('1 day'), 'on_rent');
-- a car with a later booking after its return
select test.mk_booking('RW-2', 'r8w_b', 'r8w_ivan', test.rw('-2 days'), test.rw('3 days'), 'on_rent');
select test.mk_booking('RW-3', 'r8w_b', 'r8w_rita', test.rw('6 days'), test.rw('9 days'), 'confirmed');

-- ================================================================ who and when
select test.throws('field staff cannot make a booking long-term weekly',
  $$select test.r8w_do('r8w_field', 'rolling_weekly_set', '{"booking": "RW-1", "on": true}')$$, 'only');
select test.throws('a later booking on the car is named before it can be long-term',
  $$select test.r8w_do('r8w_admin', 'rolling_weekly_set', '{"booking": "RW-2", "on": true}')$$, 'booking RW-3');
select test.eq('customer service turns it on',
  test.r8w_do('r8w_cs', 'rolling_weekly_set', '{"booking": "RW-1", "on": true}') ->> 'changed', 'true');
select test.eq('a second time changes nothing',
  test.r8w_do('r8w_cs', 'rolling_weekly_set', '{"booking": "RW-1", "on": true}') ->> 'changed', 'false');

-- ================================================================ the calendar keeps the car out
select test.ok('a block from the return, until notice',
  exists (select 1 from vehicle_calendar_blocks c join bookings b on b.id = c.booking_id
           where b.booking_number = 'RW-1' and c.source = 'rolling' and c.removed_at is null and c.starts_at = b.return_at and c.ends_at is null));
select test.ok('the car is not free a month after the return',
  not app.vehicle_is_available(test.id('vehicle:r8w_a'), now() + interval '30 days', now() + interval '31 days'));
select test.ok('the booking''s own next week is never refused by its block',
  app.vehicle_is_available(test.id('vehicle:r8w_a'), (select return_at from bookings where booking_number = 'RW-1'),
                           (select return_at + interval '7 days' from bookings where booking_number = 'RW-1'), test.id('booking:RW-1')));

-- ================================================================ 48 hours before: the To do and the link
select test.eq('the job is due', app.rolling_job_due(), true);
select test.ok('the link is due for RW-1', public.server_rolling_links_due() @> '[{"booking_number": "RW-1"}]');
select test.eq('an Admin To do', (select count(*)::int from tasks where booking_id = test.id('booking:RW-1') and task_type = 'rolling_week_due' and status = 'open'), 1);
select test.eq('the next week is an approved extension of 7 days',
  (select (new_return_at - previous_return_at)::text from booking_extensions where booking_id = test.id('booking:RW-1') and rolling and status = 'approved'), '7 days');
select test.eq('once per return: a second sweep adds nothing', app.rolling_sweep(), 0);
select test.eq('the pay link of the week', public.server_rolling_payreq(test.id('booking:RW-1'), encode(sha256(convert_to('rwTokenAAAAAAAAAAAAAAAAAAAA01', 'UTF8')), 'hex')) ->> 'ok', 'true');
select test.eq('it is for the week''s price',
  (select q.amount_cents from payment_requests q join booking_extensions e on e.id = q.extension_id where q.booking_id = test.id('booking:RW-1') and q.status = 'open'),
  (select total_cents from booking_extensions where booking_id = test.id('booking:RW-1') and rolling and status = 'approved'));
select test.throws('a link that is not the request''s is refused',
  $$select public.server_rolling_link_send((select id from payment_requests where booking_id = test.id('booking:RW-1') and status = 'open'), 'https://carmacars.example.test/pay/rwTokenBBBBBBBBBBBBBBBBBBBB01')$$, 'not this request');
select test.eq('the link goes by text',
  public.server_rolling_link_send((select id from payment_requests where booking_id = test.id('booking:RW-1') and status = 'open'),
    'https://carmacars.example.test/pay/rwTokenAAAAAAAAAAAAAAAAAAAA01') ->> 'ok', 'true');
select test.ok('the text is queued, urgent, with the link',
  exists (select 1 from phone_outbox o where o.booking_id = test.id('booking:RW-1') and o.sms_kind = 'rolling_week_link' and o.urgent and o.body like '%/pay/rwTokenAAAAAAAAAAAAAAAAAAAA01%'));

-- ================================================================ the weekly payment moves the return
create temp table r8w_before as select return_at, (select total_cents from booking_extensions where booking_id = b.id and rolling and status = 'approved') as week
  from bookings b where booking_number = 'RW-1';
select test.throws('a different amount is refused (the week''s price is named)',
  $$select test.r8w_do('r8w_cs', 'record_booking_payment', '{"booking": "RW-1", "method": "cash", "amount_cents": 100}')$$, 'record that amount');
select test.eq('recording the week''s payment',
  test.r8w_do('r8w_admin', 'record_booking_payment', '{"booking": "RW-1", "method": "cash", "covers": "rental"}') ->> 'rolling', 'true');
select test.throws('customer service above its own limit: an Admin records it',
  $$select test.r8w_do('r8w_cs', 'record_booking_payment', '{"booking": "RW-1", "method": "cash"}')$$, 'an Admin records it');
select test.eq('the return moved 7 days', (select (b.return_at - x.return_at)::text from bookings b, r8w_before x where b.booking_number = 'RW-1'), '7 days');
select test.eq('the payment is the week''s extension payment',
  (select p.amount_cents from payments p where p.booking_id = test.id('booking:RW-1') and p.purpose = 'extension' and p.method = 'cash'), (select week from r8w_before));
select test.ok('the week''s lines are paid',
  not exists (select 1 from booking_line_items l where l.booking_id = test.id('booking:RW-1') and l.stage = 'extension' and l.payment_id is null));
select test.eq('the To do closed by itself', (select status from tasks where booking_id = test.id('booking:RW-1') and task_type = 'rolling_week_due'), 'done');
select test.eq('the link is closed (paid another way)', (select status from payment_requests where booking_id = test.id('booking:RW-1') and extension_id is not null), 'cancelled');
select test.ok('the block follows the new return',
  exists (select 1 from vehicle_calendar_blocks c join bookings b on b.id = c.booking_id
           where b.booking_number = 'RW-1' and c.source = 'rolling' and c.removed_at is null and c.starts_at = b.return_at));

-- ================================================================ the renter's link pays a week too
update rolling_rentals set reminded_for = null where booking_id = test.id('booking:RW-1');
-- the reminder of the new return comes 48 hours before it: brought forward here by the lead time
update program_settings set rolling_weekly_lead_hours = 336 where id = (app.settings()).id;
select test.ok('the next reminder', public.server_rolling_links_due() @> '[{"booking_number": "RW-1"}]');
create temp table r8w_link as select (public.server_rolling_payreq(test.id('booking:RW-1'), encode(sha256(convert_to('rwTokenCCCCCCCCCCCCCCCCCCCC02', 'UTF8')), 'hex')) ->> 'id')::uuid as id;
select public.server_payreq_attach((select id from r8w_link), 'pi_rw_test_1');
create temp table r8w_before2 as select return_at from bookings where booking_number = 'RW-1';
select test.eq('paid by the link',
  public.server_payreq_settle((select id from r8w_link), jsonb_build_object('id', 'pi_rw_test_1', 'status', 'succeeded', 'charge_id', 'ch_rw_test_1',
    'amount', (select amount_cents from payment_requests where id = (select id from r8w_link)))) ->> 'ok', 'true');
select test.eq('the link moved the return 7 more days', (select (b.return_at - x.return_at)::text from bookings b, r8w_before2 x where b.booking_number = 'RW-1'), '7 days');
select test.eq('two weeks paid', (app.rolling_state(test.id('booking:RW-1')) ->> 'weeks_paid')::int, 2);
update program_settings set rolling_weekly_lead_hours = 48 where id = (app.settings()).id;

-- ================================================================ the notice
select test.throws('the last day is not before the paid return',
  $$select test.r8w_do('r8w_cs', 'rolling_weekly_end', jsonb_build_object('booking', 'RW-1', 'end_on', to_char(now() at time zone 'America/Toronto', 'YYYY-MM-DD')))$$, 'paid to');
select test.lives('End rental on a date after the paid return',
  $$select test.r8w_do('r8w_cs', 'rolling_weekly_end', jsonb_build_object('booking', 'RW-1', 'end_on', to_char((now() + interval '18 days') at time zone 'America/Toronto', 'YYYY-MM-DD')))$$);
select test.ok('the block ends on the last day',
  exists (select 1 from vehicle_calendar_blocks c join rolling_rentals r on r.booking_id = c.booking_id
           where c.booking_id = test.id('booking:RW-1') and c.source = 'rolling' and c.removed_at is null and c.ends_at = r.end_at));
select test.ok('the car is free after the last day',
  app.vehicle_is_available(test.id('vehicle:r8w_a'), now() + interval '20 days', now() + interval '22 days'));
select test.ok('the next week stops at the last day',
  (app.rolling_state(test.id('booking:RW-1')) ->> 'next_return_at')::timestamptz = (select end_at from rolling_rentals where booking_id = test.id('booking:RW-1')));

-- ================================================================ the connector and the end
select test.eq('change_booking with rolling_weekly false (the connector''s door)',
  test.r8w_do('r8w_admin', 'booking_staff_edit', '{"booking": "RW-1", "changes": {"rolling_weekly": false}, "reason": "renter moved to monthly"}') -> 'rolling_weekly' ->> 'changed', 'true');
select test.eq('off: the block is gone',
  (select count(*)::int from vehicle_calendar_blocks where booking_id = test.id('booking:RW-1') and source = 'rolling' and removed_at is null), 0);
select test.eq('the state read', (app.door(test.id('r8w_cs'), 'aal2', 'ops_read', 'rolling_weekly_state', '{"booking": "RW-1"}') ->> 'on'), 'false');
select test.eq('on again by change_booking', test.r8w_do('r8w_admin', 'booking_staff_edit', '{"booking": "RW-1", "changes": {"rolling_weekly": true}, "reason": "weekly again"}') -> 'rolling_weekly' ->> 'ok', 'true');
-- the car back (written straight in: the return's own checks are not this test's), then what the trigger runs
do $$
begin
  perform set_config('session_replication_role', 'replica', true);
  update bookings set status = 'returned', checked_in_at = now() where id = test.id('booking:RW-1');
  perform set_config('session_replication_role', 'origin', true);
end $$;
select app.rolling_sync_block(test.id('booking:RW-1'));
select test.eq('the car back: the block goes',
  (select count(*)::int from vehicle_calendar_blocks where booking_id = test.id('booking:RW-1') and source = 'rolling' and removed_at is null), 0);
select test.ok('a long-term weekly booking that ended is not swept', not exists (select 1 from app.rolling_reminders_due() b where b.id = test.id('booking:RW-1')));
select test.ok('the browser never reads rolling_rentals', not has_table_privilege('anon', 'rolling_rentals', 'select') and not has_table_privilege('authenticated', 'rolling_rentals', 'insert'));
