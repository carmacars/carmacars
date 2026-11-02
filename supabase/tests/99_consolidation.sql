-- 99: Release 27 consolidation (migration 0500). Staff reads of Admin's pages scoped to the function (the live map and
-- History for customer service and Sales, Data health lines per function, the Marketplace for Sales), Bookings > Now for
-- finance, field staff's tracker map of their own jobs' cars, and Call and Text through Quo (compose, call log, the
-- buttons' setting). Fixtures start with "cn"; every address is example.test.
select test.suite('99 consolidation');

select test.mk_user('cn_admin', 'admin');
select test.mk_user('cn_cs', 'va', 'cs');
select test.mk_user('cn_sales', 'va', 'sales');
select test.mk_user('cn_fleet', 'va', 'fleet');
select test.mk_user('cn_fin', 'va', 'finance');
select test.mk_user('cn_field', 'field');
select test.mk_user('cn_other_field', 'field');
select test.mk_owner('cn_own');
select test.mk_vehicle('cn_car', 'cn_own');
select test.mk_vehicle('cn_car2', 'cn_own');
select test.mk_renter('cn_rita');
update renters set mobile = '416-555-0463' where id = test.id('renter:cn_rita');
update site_settings set phone = '289-555-0100';

create or replace function test.cn(p_user text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language sql as $$ select app.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;

-- ================================================================ 1. the live map and History for customer service and Sales
select test.ok('customer service reads the live map', test.cn('cn_cs', 'va_read', 'live_map', '{"_va": "cs"}') ? 'pins');
select test.ok('Sales reads the live map, without the fleet layer or the money',
  (select v -> 'fleet' = '[]'::jsonb and (v -> 'kpi' -> 'collected_month_cents') = 'null'::jsonb from (select test.cn('cn_sales', 'va_read', 'live_map', '{"_va": "sales"}') v) x));
select test.throws('fleet staff do not read the live map', $$select test.cn('cn_fleet', 'va_read', 'live_map', '{"_va": "fleet"}')$$, 'customer service and Sales');
select test.throws('finance does not read the live map', $$select test.cn('cn_fin', 'va_read', 'live_map', '{"_va": "finance"}')$$, 'customer service and Sales');
select test.ok('the staff read leaves no Admin pass behind', coalesce(current_setting('app.staff_view', true), '') = '');
select test.throws('a staff member is still no Admin afterwards', format('select app.assert_admin(%L)', test.id('cn_cs')), 'Only an Admin');
select test.ok('customer service reads History', test.cn('cn_cs', 'va_read', 'visitor_history', '{"_va": "cs"}') ? 'rows');
select test.throws('field staff do not read History', $$select test.cn('cn_field', 'va_read', 'visitor_history')$$, 'customer service and Sales');
select test.throws('the Admin read of History stays Admin''s', $$select test.cn('cn_cs', 'admin_read', 'visitor_history')$$);

-- ================================================================ 2. Data health lines per function
insert into data_health_runs (ran_at, issues, checks, fixed) values (now(), 4, jsonb_build_array(
  jsonb_build_object('key', 'car_gaps', 'title', 'Cars', 'line', 'Cars with gaps', 'href', '/admin/vehicles', 'count', 1,
    'items', jsonb_build_array(jsonb_build_object('id', test.id('vehicle:cn_car'), 'text', 'CN car: no plate', 'href', '/admin/vehicles/x', 'fix', null))),
  jsonb_build_object('key', 'licence_waiting', 'title', 'Licences', 'line', 'Licence reviews waiting', 'href', null, 'count', 1, 'items', '[]'::jsonb),
  jsonb_build_object('key', 'lead_followup', 'title', 'Leads', 'line', 'Leads not followed up', 'href', null, 'count', 1,
    'items', jsonb_build_array(jsonb_build_object('id', test.id('x'), 'text', 'A lead', 'href', null, 'fix', jsonb_build_object('action', 'restart_followup', 'label', 'Restart')))),
  jsonb_build_object('key', 'unmatched_payments', 'title', 'Payments', 'line', 'Payments not matched', 'href', '/admin/payments', 'count', 1, 'items', '[]'::jsonb)), '{}'::jsonb);
select test.eq('fleet: the car gaps only', (select string_agg(c ->> 'key', ',') from jsonb_array_elements(test.cn('cn_fleet', 'va_read', 'data_health', '{"_va": "fleet"}') -> 'checks') c), 'car_gaps');
select test.eq('customer service: licences', (select string_agg(c ->> 'key', ',') from jsonb_array_elements(test.cn('cn_cs', 'va_read', 'data_health', '{"_va": "cs"}') -> 'checks') c), 'licence_waiting');
select test.eq('Sales: stalled leads', (select string_agg(c ->> 'key', ',') from jsonb_array_elements(test.cn('cn_sales', 'va_read', 'data_health', '{"_va": "sales"}') -> 'checks') c), 'lead_followup');
select test.eq('finance: unmatched payments', (select string_agg(c ->> 'key', ',') from jsonb_array_elements(test.cn('cn_fin', 'va_read', 'data_health', '{"_va": "finance"}') -> 'checks') c), 'unmatched_payments');
select test.ok('staff never get the one-tap fixes (Admin''s)', (select bool_and(i -> 'fix' = 'null'::jsonb) from jsonb_array_elements(test.cn('cn_sales', 'va_read', 'data_health', '{"_va": "sales"}') -> 'checks') c, jsonb_array_elements(c -> 'items') i));
select test.eq('the count is the function''s', (test.cn('cn_fleet', 'va_read', 'data_health', '{"_va": "fleet"}') ->> 'issues')::int, 1);
select test.throws('staff still cannot fix', format($$select test.cn('cn_fleet', 'ops_do', 'data_health_fix', '{"action": "close_task", "id": "%s"}')$$, test.id('x')), 'Only an Admin');

-- ================================================================ 3. the Marketplace for Sales
select test.ok('Sales reads the Marketplace kits', test.cn('cn_sales', 'va_read', 'marketplace', '{"_va": "sales"}') ? 'settings');
select test.throws('customer service does not', $$select test.cn('cn_cs', 'va_read', 'marketplace', '{"_va": "cs"}')$$, 'Admins and Sales');
select test.throws('Sales cannot log a post (Admin''s)', format($$select test.cn('cn_sales', 'admin_do', 'marketplace_log', '{"vehicle": "%s", "kind": "posted"}')$$, test.id('vehicle:cn_car')), 'Admin');

-- ================================================================ 4. Bookings > Now for finance
select test.ok('finance reads the whole board with the money', (select v ->> 'scope' = 'full' and v ? 'money' from (select test.cn('cn_fin', 'ops_read', 'bookings_now', '{"_va": "finance"}') v) x));

-- ================================================================ 5. field staff: the cars of their own jobs on the tracker map
insert into field_jobs (kind, vehicle_id, assigned_to, scheduled_at, status) values ('delivery', test.id('vehicle:cn_car'), test.id('cn_field'), now() + interval '3 hours', 'scheduled');
select test.eq('field staff see their job''s car only',
  (select string_agg(c ->> 'vehicle_id', ',') from jsonb_array_elements(test.cn('cn_field', 'ops_read', 'tracker_fleet') -> 'cars') c), test.id('vehicle:cn_car')::text);
select test.eq('another field staff member sees none of them', jsonb_array_length(test.cn('cn_other_field', 'ops_read', 'tracker_fleet') -> 'cars'), 0);
select test.ok('fleet staff still see every car', jsonb_array_length(test.cn('cn_fleet', 'ops_read', 'tracker_fleet', '{"_va": "fleet"}') -> 'cars') >= 2);
select test.throws('field staff cannot change the trackers', $$select test.cn('cn_field', 'ops_do', 'tracker_settings_save', '{}')$$, 'Only an Admin');
insert into tracker_trips (id, vehicle_id, started_at, ended_at, km) values (test.id('trip:cn2'), test.id('vehicle:cn_car2'), now() - interval '2 hours', now() - interval '1 hour', 12);
select test.throws('field staff cannot read the trips of other cars', format($$select test.cn('cn_field', 'ops_read', 'tracker_trip_path', '{"trip": "%s"}')$$, test.id('trip:cn2')), 'cars of your jobs');
select test.throws('customer service still cannot read Fleet tracking', $$select test.cn('cn_cs', 'ops_read', 'tracker_fleet')$$, 'Admins and fleet staff');

-- ================================================================ 6. Call and Text through Quo
select test.ok('the buttons go through Quo by default', (test.cn('cn_fleet', 'va_read', 'phone_buttons') ->> 'quo')::boolean);
select test.eq('from the CarmaCars number', test.cn('cn_field', 'field_read', 'phone_buttons') ->> 'from', '+12895550100');
create temp table cn_sent as select test.cn('cn_cs', 'va_do', 'phone_compose', '{"number": "(416) 555-0463", "body": "Hi Rita, your car is ready. CarmaCars"}') v;
select test.ok('customer service: the text is queued to send now from the CarmaCars number',
  (select v -> 'send' ->> 'to' = '+14165550463' and v ->> 'from' = '+12895550100' from cn_sent));
select test.eq('it is in Rita''s conversation, as staff wrote it', (select o.kind || '/' || o.status || '/' || t.match_kind from phone_outbox o join phone_threads t on t.id = o.thread_id
  where o.id = (select (v -> 'send' ->> 'id')::uuid from cn_sent)), 'staff/sending/renter');
select app.server_phone_sent(jsonb_build_object('id', (select v -> 'send' ->> 'id' from cn_sent), 'ok', true, 'quo_id', 'AC-cn-1'));
select test.eq('once sent it shows in the conversation', (select count(*) from phone_activity a where a.quo_id = 'AC-cn-1' and a.renter_id = test.id('renter:cn_rita') and a.sent_by = test.id('cn_cs')), 1::bigint);
select test.throws('fleet staff cannot text a number nobody knows', $$select test.cn('cn_fleet', 'va_do', 'phone_compose', '{"number": "416-555-0911", "body": "Hello. CarmaCars"}')$$, 'people of your work');
select test.ok('fleet staff can text a renter', test.cn('cn_fleet', 'va_do', 'phone_compose', '{"number": "416-555-0463", "body": "Your car is out front. CarmaCars"}') ? 'send');
select test.throws('an empty text is refused', $$select test.cn('cn_sales', 'va_do', 'phone_compose', '{"number": "416-555-0463", "body": "  "}')$$, 'Write the text');
select test.throws('not a number', $$select test.cn('cn_sales', 'va_do', 'phone_compose', '{"number": "abc", "body": "Hi"}')$$, 'not a phone number');
update phone_threads set opted_out_at = now() where number = '+14165550463';
select test.throws('a number that opted out is refused', $$select test.cn('cn_sales', 'va_do', 'phone_compose', '{"number": "416-555-0463", "body": "Hi. CarmaCars"}')$$, 'opted out');
update phone_threads set opted_out_at = null where number = '+14165550463';
select test.ok('a call from the site is logged', (test.cn('cn_field', 'field_do', 'phone_call_log', '{"number": "416-555-0463"}') ->> 'logged')::boolean);
select test.ok('a double tap logs it once', not (test.cn('cn_field', 'field_do', 'phone_call_log', '{"number": "416-555-0463"}') ->> 'logged')::boolean);
select test.eq('the call is in the conversation, by the field staff member',
  (select count(*) from phone_activity a join phone_threads t on t.id = a.thread_id where t.number = '+14165550463' and a.kind = 'call' and a.status = 'dialed' and a.sent_by = test.id('cn_field')), 1::bigint);
select test.throws('an owner cannot use the buttons', $$select test.cn('cn_own', 'va_read', 'phone_buttons')$$);
update program_settings set phone_quo_buttons = false;
select test.ok('off in Program settings: the phone''s own apps', not (test.cn('cn_fleet', 'va_read', 'phone_buttons') ->> 'quo')::boolean);
update program_settings set phone_quo_buttons = true;
