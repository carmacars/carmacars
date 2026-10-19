-- 41: calendar sync, booking recovery emails and the site check (migration 0062). Calendar links added by Fleet (not
-- customer service), imported trips as External booking blocks widened by the turnaround that availability respects,
-- moved and removed trips, a block a person removed staying removed, clashes with a confirmed booking (urgent task,
-- email, To do) and with an offer, failures and their one alert, the export link (busy times only, per platform,
-- rotation). Recovery: the delay, the sending hours, two reminders at most, stopped when the renter acts (the queued
-- email skipped), a staff member handling, unsubscribed, marketing consent for a request, the offer's own expiry
-- reminder. Site check: the threshold, one alert and one recovery email to the alert address, the cooldown, the
-- internal checks (emails, jobs, backup, Stripe), the status panel and To do. Fixtures start with "c62".
select test.suite('41 calendar sync, recovery, site check');

select test.mk_user('c62_admin', 'admin');
select test.mk_user('c62_fleet', 'va', 'fleet');
select test.mk_user('c62_cs', 'va', 'cs');
select test.mk_owner('c62_owner');
select test.mk_vehicle('c62car', 'c62_owner');
select test.mk_vehicle('c62car2', 'c62_owner');
select test.mk_renter('c62_rita');
select test.mk_renter('c62_ravi');
create or replace function test.c62v() returns uuid language sql immutable as $$ select test.id('vehicle:c62car') $$;
create or replace function test.at62(p text) returns timestamptz language sql immutable as $$ select (p::timestamp at time zone 'America/Toronto') $$;
create or replace function test.flush62() returns integer language sql as $$ select app.process_events(100000) $$;
create temp table s41 (k text primary key, v jsonb);
-- the site alert emails of this suite (07 builds one of each for the catalogue)
create or replace function test.ev62(p_code text) returns bigint language sql stable as $$ select count(*) from app_events where code = p_code and entity_id is distinct from test.id('nt_alert') $$;
grant all on s41 to public;
create or replace function test.s41(p_k text) returns jsonb language sql stable as $$ select v from pg_temp.s41 where k = p_k $$;
update program_settings set turnaround_buffer_minutes = 120, turnaround_block_enabled = true, calendar_sync_minutes = 10, calendar_feed_alert_failures = 3,
  uptime_alert_email = 'site.alerts@example.test';
update vehicles set turnaround_block_minutes = null where id in (test.c62v(), test.id('vehicle:c62car2'));

-- ================================================================ 1. calendar links: who may add them
select test.eq('settings: every 10 minutes, alert after 3 failures, recovery on, two reminders, 9 to 21, site check every 5 minutes, 3 in a row',
  (select format('%s %s %s %s %s-%s %s %s', calendar_sync_minutes, calendar_feed_alert_failures, recovery_emails_enabled, recovery_max_emails,
                 recovery_send_from_hour, recovery_send_until_hour, uptime_interval_minutes, uptime_fail_threshold) from (select (app.settings()).*) s),
  '10 3 t 2 9-21 5 3');
select test.eq('the default alert address is the Admin''s', (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'uptime_alert_email'), '''rent@carmacars.ca''::text');
insert into s41 values ('feed', app.door(test.id('c62_fleet'), '', 'va_do', 'calendar_feed_add',
  jsonb_build_object('vehicle', test.c62v(), 'platform', 'turo', 'url', 'webcal://turo.example/ical/c62.ics')));
select test.eq('Fleet adds a Turo link; webcal is stored as https', test.s41('feed') ->> 'url' || ' ' || (test.s41('feed') ->> 'name'), 'https://turo.example/ical/c62.ics Turo');
create or replace function test.f62() returns uuid language sql stable as $$ select (test.s41('feed') ->> 'id')::uuid $$;
select test.throws('customer service may not add calendar links',
  $$ select app.door(test.id('c62_cs'), '', 'va_do', 'calendar_feed_add', jsonb_build_object('vehicle', test.c62v(), 'platform', 'turo', 'url', 'https://x.example/a.ics')) $$,
  'Calendar sync is for Admins and Fleet');
select test.throws('a link that is not a link', $$ select app.door(test.id('c62_admin'), '', 'admin_do', 'calendar_feed_add', jsonb_build_object('vehicle', test.c62v(), 'url', 'turo calendar')) $$, 'Paste the full calendar link');
select test.throws('a CarmaCars export link pasted by mistake',
  $$ select app.door(test.id('c62_admin'), '', 'admin_do', 'calendar_feed_add', jsonb_build_object('vehicle', test.c62v(), 'url', 'https://carmacars.ca/api/ical/' || repeat('ab', 32) || '.ics')) $$,
  'That is a CarmaCars calendar link');
select test.throws('the same link twice', $$ select app.door(test.id('c62_admin'), '', 'admin_do', 'calendar_feed_add', jsonb_build_object('vehicle', test.c62v(), 'platform', 'turo', 'url', 'https://turo.example/ical/c62.ics')) $$, 'already added');
select test.eq('the link is recorded in the audit log without its address', (select (after ? 'url')::text || ' ' || (after ->> 'platform') from audit_log where entity_table = 'calendar_feeds' and entity_id = test.f62()::text and action = 'INSERT'), 'false turo');
select test.eq('due: a new link is due at once, then not again for 10 minutes',
  jsonb_array_length(app.calendar_feeds_due(50, test.at62('2031-03-01 12:00'))) || ' ' || jsonb_array_length(app.calendar_feeds_due(50, test.at62('2031-03-01 12:05')))
  || ' ' || (select count(*) from jsonb_array_elements(app.calendar_feeds_due(50, test.at62('2031-03-01 12:10'))) x where x ->> 'id' = test.f62()::text), '1 0 1');

-- ================================================================ 2. a confirmed CarmaCars booking, then the Turo trips arrive
select test.mk_booking('C62-B1', 'c62car', 'c62_rita', '2031-03-10 10:00', '2031-03-12 10:00', 'confirmed');
select app.calendar_feed_apply(test.f62(), jsonb_build_array(
  jsonb_build_object('uid', 'trip-1@turo', 'summary', 'Turo trip', 'starts_at', test.at62('2031-03-05 10:00'), 'ends_at', test.at62('2031-03-07 10:00'), 'all_day', false),
  jsonb_build_object('uid', 'block-1@turo', 'summary', 'Unavailable', 'starts_at', test.at62('2031-03-20 00:00'), 'ends_at', test.at62('2031-03-22 00:00'), 'all_day', true)),
  '{"calendar_name": "C 300 on Turo", "etag": "\"e1\""}', test.at62('2031-03-01 12:00'));
select test.eq('two External booking blocks, widened by the 2-hour turnaround, with the platform in the note',
  (select string_agg(format('%s %s %s', to_char(starts_at at time zone 'America/Toronto', 'MM-DD HH24:MI'), to_char(ends_at at time zone 'America/Toronto', 'MM-DD HH24:MI'), note), ' | ' order by starts_at)
     from vehicle_calendar_blocks where vehicle_id = test.c62v() and source = 'external' and removed_at is null),
  '03-05 08:00 03-07 12:00 Turo: Turo trip | 03-19 22:00 03-22 02:00 Turo: Unavailable');
select test.eq('the link: ok, 2 events, the calendar name and etag kept', (select format('%s %s %s %s', last_status, event_count, calendar_name, etag) from calendar_feeds where id = test.f62()), 'ok 2 C 300 on Turo "e1"');
select test.eq('availability: the car is taken during the trip and its turnaround', app.vehicle_is_available(test.c62v(), test.at62('2031-03-07 11:00'), test.at62('2031-03-08 10:00')), false);
select test.eq('availability: free once the turnaround has passed', app.vehicle_is_available(test.c62v(), test.at62('2031-03-07 12:00'), test.at62('2031-03-08 10:00')), true);
select test.eq('availability: an all-day block holds the whole days', app.vehicle_is_available(test.c62v(), test.at62('2031-03-21 09:00'), test.at62('2031-03-21 17:00')), false);
select test.eq('availability: the other car is not affected', app.vehicle_is_available(test.id('vehicle:c62car2'), test.at62('2031-03-06 09:00'), test.at62('2031-03-06 17:00')), true);
select test.throws('a confirmed booking cannot move onto the imported trip',
  $$ update bookings set pickup_at = test.at62('2031-03-06 10:00'), return_at = test.at62('2031-03-08 10:00') where id = test.id('booking:C62-B1') $$, 'The vehicle is not available for these dates');
select test.eq('no clash yet: the confirmed booking is clear of both trips', (select count(*) from calendar_conflicts k join calendar_feed_events e on e.id = k.event_id where e.feed_id = test.f62()), 0::bigint);

-- the trip moves onto the confirmed booking: a clash
select app.calendar_feed_apply(test.f62(), jsonb_build_array(
  jsonb_build_object('uid', 'trip-1@turo', 'summary', 'Turo trip', 'starts_at', test.at62('2031-03-09 10:00'), 'ends_at', test.at62('2031-03-11 10:00')),
  jsonb_build_object('uid', 'block-1@turo', 'summary', 'Unavailable', 'starts_at', test.at62('2031-03-20 00:00'), 'ends_at', test.at62('2031-03-22 00:00'), 'all_day', true)),
  '{}', test.at62('2031-03-01 12:10'));
select test.eq('the moved trip moved its block (same block)',
  (select to_char(k.starts_at at time zone 'America/Toronto', 'MM-DD HH24:MI') from calendar_feed_events e join vehicle_calendar_blocks k on k.id = e.block_id where e.feed_id = test.f62() and e.uid = 'trip-1@turo'),
  '03-09 08:00');
select test.eq('clash: one urgent Fleet task naming the car, the platform and the booking',
  (select format('%s %s %s', queue, priority, title) from tasks where task_type = 'calendar_conflict' and booking_id = test.id('booking:C62-B1')),
  'fleet urgent Double booking: 2023 Mercedes-Benz C 300 c62car on Turo and C62-B1');
select test.eq('clash: one email event to Fleet', (select count(*) from app_events where code = 'staff_calendar_conflict' and payload ->> 'booking_id' = test.id('booking:C62-B1')::text), 1::bigint);
select test.eq('clash: on the Admin To do, second after site problems', (select string_agg(x ->> 'key' || '=' || (x ->> 'count'), ',') from jsonb_array_elements(app.admin_todo(test.id('c62_admin')) -> 'items') with ordinality t(x, n) where n <= 2),
  'site_alerts=' || (select count(*) from site_alerts where resolved_at is null) || ',calendar_conflicts=1');
select app.calendar_feed_apply(test.f62(), null, '{}', test.at62('2031-03-01 12:20'));
select test.eq('not modified: the clash is not raised twice', (select count(*) from app_events where code = 'staff_calendar_conflict' and payload ->> 'booking_id' = test.id('booking:C62-B1')::text)
  || ' ' || (select count(*) from tasks where task_type = 'calendar_conflict' and booking_id = test.id('booking:C62-B1')), '1 1');
select test.flush62();
select test.eq('the clash email reaches Fleet with the times in Toronto',
  (select format('%s | %s | %s', to_address, payload ->> 'external_start', payload ->> 'calendar_url') from notification_outbox where code = 'staff_calendar_conflict' and booking_id = test.id('booking:C62-B1') and to_address = 'c62_fleet@example.test'),
  'c62_fleet@example.test | Sun, Mar 9 at 10:00 am | https://carmacars.ca/va/calendar-sync');
select test.eq('Calendar sync shows the clash to Fleet', (select count(*) from jsonb_array_elements(app.door(test.id('c62_fleet'), '', 'va_read', 'calendar_sync') -> 'conflicts') x where x ->> 'booking_number' = 'C62-B1'), 1::bigint);
-- the trip is cancelled on Turo: it leaves the link; the block goes and the clash closes by itself
select app.calendar_feed_apply(test.f62(), jsonb_build_array(
  jsonb_build_object('uid', 'block-1@turo', 'summary', 'Unavailable', 'starts_at', test.at62('2031-03-20 00:00'), 'ends_at', test.at62('2031-03-22 00:00'), 'all_day', true)),
  '{}', test.at62('2031-03-01 12:30'));
select test.eq('a trip gone from the link frees the car', app.vehicle_is_available(test.c62v(), test.at62('2031-03-05 10:00'), test.at62('2031-03-06 10:00')), true);
select test.eq('its block is removed with the reason', (select removed_reason from vehicle_calendar_blocks k join calendar_feed_events e on e.block_id = k.id where e.uid = 'trip-1@turo'), 'No longer in the Turo calendar');
select test.eq('the clash closed by itself', (select status || ': ' || completion_note from tasks where task_type = 'calendar_conflict' and booking_id = test.id('booking:C62-B1')), 'done: Closed by itself: the dates no longer overlap');
-- a person removes an imported block: it stays removed at the next sync
update vehicle_calendar_blocks k set removed_at = now(), removed_by = test.id('c62_admin'), removed_reason = 'Owner said the car is free'
  from calendar_feed_events e where e.block_id = k.id and e.uid = 'block-1@turo';
select app.calendar_feed_apply(test.f62(), jsonb_build_array(
  jsonb_build_object('uid', 'block-1@turo', 'summary', 'Unavailable', 'starts_at', test.at62('2031-03-20 00:00'), 'ends_at', test.at62('2031-03-22 00:00'), 'all_day', true)),
  '{}', test.at62('2031-03-01 12:40'));
select test.eq('a block a person removed stays removed', (select removed_reason from vehicle_calendar_blocks k join calendar_feed_events e on e.block_id = k.id where e.uid = 'block-1@turo'), 'Owner said the car is free');

-- an offer over a Getaround trip: a task for customer service (its payment would be refused)
insert into s41 values ('ga', app.door(test.id('c62_admin'), '', 'admin_do', 'calendar_feed_add',
  jsonb_build_object('vehicle', test.c62v(), 'platform', 'getaround', 'url', 'https://getaround.example/c62.ics', 'label', 'Getaround (Kia)')));
select test.mk_booking('C62-O1', 'c62car', 'c62_ravi', '2031-04-02 10:00', '2031-04-04 10:00', 'offered');
select app.calendar_feed_apply((test.s41('ga') ->> 'id')::uuid, jsonb_build_array(
  jsonb_build_object('uid', 'ga-1', 'summary', 'Getaround booking', 'starts_at', test.at62('2031-04-03 09:00'), 'ends_at', test.at62('2031-04-03 18:00'))), '{}', test.at62('2031-03-01 12:40'));
select test.eq('an offer over an imported trip: a customer service task, no email',
  (select format('%s %s %s', queue, priority, title) from tasks where task_type = 'calendar_offer_clash' and booking_id = test.id('booking:C62-O1'))
  || ' ' || (select count(*) from app_events where code = 'staff_calendar_conflict' and payload ->> 'booking_id' = test.id('booking:C62-O1')::text),
  'cs high C62-O1 clashes with Getaround (Kia): withdraw the offer or change the dates 0');

-- ================================================================ 3. a link that fails
select app.calendar_feed_failed(test.f62(), 'The platform answered 404 (not found): the link was removed or reset. Copy it again from the platform.', test.at62('2031-03-01 13:00'));
select app.calendar_feed_failed(test.f62(), 'The platform answered 404 (not found)', test.at62('2031-03-01 13:10'));
select test.eq('two failures: no alert yet, the trips stay', (select count(*) from tasks where task_type = 'calendar_feed_failing' and related_id = test.f62())
  || ' ' || (select event_count from calendar_feeds where id = test.f62()), '0 1');
select app.calendar_feed_failed(test.f62(), 'The platform answered 404 (not found)', test.at62('2031-03-01 13:20'));
select app.calendar_feed_failed(test.f62(), 'The platform answered 404 (not found)', test.at62('2031-03-01 13:30'));
select test.eq('the third failure: one Fleet task and one email, not again at the fourth',
  (select count(*) from tasks where task_type = 'calendar_feed_failing' and related_id = test.f62() and status = 'open')
  || ' ' || (select count(*) from app_events where code = 'staff_calendar_feed_failing' and entity_id = test.f62()), '1 1');
select test.eq('To do counts the link', (select x ->> 'count' from jsonb_array_elements(app.admin_todo(test.id('c62_admin')) -> 'items') x where x ->> 'key' = 'calendar_feeds'), '1');
select test.flush62();
select test.eq('the email says how many tries and the last good sync',
  (select payload ->> 'failures' || ' | ' || (payload ->> 'last_success') from notification_outbox where code = 'staff_calendar_feed_failing' and entity_id = test.f62() and to_address = 'c62_admin@example.test'),
  '3 | Sat, Mar 1 at 12:40 pm');
select app.calendar_feed_apply(test.f62(), null, '{}', test.at62('2031-03-01 13:40'));
select test.eq('it works again: the task closes and the count starts over',
  (select status from tasks where task_type = 'calendar_feed_failing' and related_id = test.f62()) || ' ' || (select consecutive_failures || ' ' || last_status from calendar_feeds where id = test.f62()), 'done 0 ok');

-- ================================================================ 4. the export link
select test.mk_booking('C62-B2', 'c62car', 'c62_ravi', '2031-05-10 10:00', '2031-05-12 10:00', 'confirmed');
insert into vehicle_calendar_blocks (vehicle_id, reason, starts_at, ends_at, note) values (test.c62v(), 'service', test.at62('2031-05-20 09:00'), test.at62('2031-05-20 17:00'), 'Oil change');
insert into s41 select 'tok', to_jsonb(token) from vehicle_calendar_exports where vehicle_id = test.c62v();
create or replace function test.ics(p_for text default null) returns text language sql as $$ select app.calendar_export_ics(test.s41('tok') #>> '{}', p_for, test.at62('2031-03-01 12:00')) $$;
select test.eq('every car has a private link of 64 characters', (select count(*) from vehicles v where not exists (select 1 from vehicle_calendar_exports x where x.vehicle_id = v.id))::text
  || ' ' || length(test.s41('tok') #>> '{}'), '0 64');
select test.eq('the file is a calendar with CRLF lines', left(test.ics(), 17) || ' ' || (test.ics() like '%END:VCALENDAR' || e'\r\n'), 'BEGIN:VCALENDAR' || e'\r\n' || ' true');
select test.eq('a confirmed booking with its turnaround, and a service block: "Booked", in UTC',
  (select string_agg(m[1] || '-' || m[2], ' ') from regexp_matches(test.ics(), 'DTSTART:(\d{8}T\d{4})00Z\r\nDTEND:(\d{8}T\d{4})00Z', 'g') m),
  '20310310T1200-20310312T1600 20310510T1200-20310512T1600 20310520T1300-20310520T2100');
select test.eq('nothing personal: no renter name, no booking number, only "Booked"',
  (test.ics() !~ 'C62-B1|Rita|Ravi|Oil change') || ' ' || (select count(*) from regexp_matches(test.ics(), 'SUMMARY:Booked', 'g')), 'true 3');
select test.eq('the link for Turo has Getaround''s trip, not Turo''s own; the plain link has neither; "all" has both',
  (test.ics('turo') ~ '20310403T1100') || ' ' || (test.ics() ~ '20310403T1100') || ' ' || (test.ics('getaround') ~ '20310403T1100') || ' ' || (test.ics('all') ~ '20310403T1100'),
  'true false false true');
select test.eq('each fetch is counted', (select fetches > 0 from vehicle_calendar_exports where vehicle_id = test.c62v()), true);
select test.eq('an unknown link answers nothing', app.calendar_export_ics(repeat('0', 64)) is null and app.calendar_export_ics('nope') is null, true);
insert into s41 values ('rot', app.door(test.id('c62_fleet'), '', 'va_do', 'calendar_export_rotate', jsonb_build_object('vehicle', test.c62v())));
select test.eq('rotate: a new link; the old one stops', (app.calendar_export_ics(test.s41('tok') #>> '{}') is null) || ' ' || (test.s41('rot') ->> 'url' like 'https://carmacars.ca/api/ical/%.ics'), 'true true');
select test.eq('the export is for the server only', has_function_privilege('anon', 'public.calendar_export_ics(text, text)', 'execute')::text
  || has_function_privilege('authenticated', 'app.calendar_feed_apply(uuid, jsonb, jsonb, timestamptz)', 'execute')::text, 'falsefalse');
-- removing a link frees its blocks
select app.door(test.id('c62_admin'), '', 'admin_do', 'calendar_feed_remove', jsonb_build_object('id', test.s41('ga') ->> 'id'));
select test.eq('removing a link frees the car and cancels its clash task',
  app.vehicle_is_available(test.c62v(), test.at62('2031-04-03 10:00'), test.at62('2031-04-03 12:00')) || ' ' || (select status from tasks where task_type = 'calendar_offer_clash' and booking_id = test.id('booking:C62-O1')),
  'true cancelled');

-- ================================================================ 5. booking recovery emails
-- Tuesday March 4, 2031, 14:00 in Toronto: inside the sending hours
create or replace function test.t62(p_add text default '0') returns timestamptz language sql immutable as $$ select test.at62('2031-03-04 14:00') + p_add::interval $$;
select test.mk_booking('C62-R1', 'c62car2', 'c62_rita', '2031-03-20 10:00', '2031-03-22 10:00', 'offered');
update bookings set offer_expires_at = test.t62('3 days') where id = test.id('booking:C62-R1');
insert into visitor_signals (dedupe_key, visitor_id, renter_id, kind, label, booking_id, first_at, last_at)
values ('offer:c62r1:1', test.id('c62vid'), test.id('renter:c62_rita'), 'offer_opened', 'Opened offer C62-R1, not answered', test.id('booking:C62-R1'), test.t62(), test.t62());
select test.eq('offer opened: nothing before 4 hours', app.job_booking_recovery(test.t62('3 hours')), 'sent 0, stopped 0');
select test.eq('after 4 hours: the first reminder', app.job_booking_recovery(test.t62('4 hours 5 minutes')), 'sent 1, stopped 0');
select test.eq('not twice in a row', app.job_booking_recovery(test.t62('4 hours 20 minutes')), 'sent 0, stopped 0');
select test.flush62();
select test.eq('the reminder is queued to Rita, transactional, from bookings, with her booking''s values',
  (select format('%s %s %s | %s | %s', to_address, category, status, payload ->> 'vehicle_name', payload ->> 'offer_expires_at') from notification_outbox where code = 'renter_recovery_offer' and booking_id = test.id('booking:C62-R1')),
  'c62_rita@example.test transactional queued | 2023 Mercedes-Benz C 300 c62car2 | Fri, Mar 7 at 2:00 pm');
-- the second: 24 hours later, but 23:00 is outside the sending hours; it waits for the morning
select test.eq('outside the sending hours nothing goes', app.job_booking_recovery(test.at62('2031-03-05 23:00')), 'outside the sending hours, stopped 0');
select test.eq('the second reminder the next morning', app.job_booking_recovery(test.at62('2031-03-06 09:10')), 'sent 1, stopped 0');
select test.eq('never a third', app.job_booking_recovery(test.at62('2031-03-08 10:00')) || ' ' || (select count(*) from recovery_emails where subject_key = 'offer:c62r1:1'), 'sent 0, stopped 0 2');

-- the pay page left; the renter pays before the queued reminder goes: it is skipped and the series stops
select test.mk_booking('C62-R2', 'c62car2', 'c62_ravi', '2031-04-20 10:00', '2031-04-22 10:00', 'pending_payment');
insert into visitor_signals (dedupe_key, visitor_id, renter_id, kind, label, booking_id, first_at, last_at)
values ('pay:c62r2', test.id('c62vid2'), test.id('renter:c62_ravi'), 'pay_left', 'Left the pay page (C62-R2)', test.id('booking:C62-R2'), test.t62(), test.t62());
select test.eq('pay page left: a reminder after an hour', app.job_booking_recovery(test.t62('30 minutes')) || ' / ' || app.job_booking_recovery(test.t62('65 minutes')), 'sent 0, stopped 0 / sent 1, stopped 0');
select test.flush62();
update notification_outbox set status = 'delayed', send_after = test.t62('1 day') where code = 'renter_recovery_pay' and booking_id = test.id('booking:C62-R2');
set session_replication_role = replica;
update bookings set status = 'confirmed' where id = test.id('booking:C62-R2');
set session_replication_role = default;
select test.eq('he paid: the series stops', app.job_booking_recovery(test.t62('70 minutes')), 'sent 0, stopped 1');
select test.eq('the reminder still waiting is not sent', (select status || ': ' || status_reason from notification_outbox where code = 'renter_recovery_pay' and booking_id = test.id('booking:C62-R2')),
  'skipped: Not sent: paid, or the booking moved on');
select test.eq('and no second one later', app.job_booking_recovery(test.t62('2 days')) || ' ' || (select count(*) from recovery_emails where subject_key = 'pay:c62r2'), 'sent 0, stopped 0 1');

-- a staff member is already handling the renter: no reminder
select test.mk_booking('C62-R3', 'c62car2', 'c62_ravi', '2031-06-01 10:00', '2031-06-03 10:00', 'pending_payment');
insert into visitor_signals (dedupe_key, visitor_id, renter_id, kind, label, booking_id, first_at, last_at)
values ('pay:c62r3', test.id('c62vid2'), test.id('renter:c62_ravi'), 'pay_left', 'Left the pay page (C62-R3)', test.id('booking:C62-R3'), test.t62(), test.t62());
insert into tasks (queue, task_type, title, booking_id, assigned_to) values ('cs', 'visitor_follow_up', 'Call Ravi', test.id('booking:C62-R3'), test.id('c62_cs'));
select test.eq('a task a person took: no reminder', app.job_booking_recovery(test.t62('2 hours')) || ' ' || (select count(*) from recovery_emails where subject_key = 'pay:c62r3'), 'sent 0, stopped 0 0');
-- unsubscribed: no reminder of any kind
delete from tasks where title = 'Call Ravi' and booking_id = test.id('booking:C62-R3');
update users set marketing_unsubscribed_at = test.t62('-1 day') where id = test.id('c62_ravi');
select test.eq('unsubscribed: no reminder', app.job_booking_recovery(test.t62('2 hours')) || ' ' || (select count(*) from recovery_emails where subject_key = 'pay:c62r3'), 'sent 0, stopped 0 0');
update users set marketing_unsubscribed_at = null where id = test.id('c62_ravi');
-- turned off in the renter's preferences
insert into notification_preferences (user_id, code, email_enabled) values (test.id('c62_ravi'), 'renter_recovery_pay', false);
select test.eq('turned off by the renter: no reminder', app.job_booking_recovery(test.t62('2 hours')), 'sent 0, stopped 0');
delete from notification_preferences where user_id = test.id('c62_ravi') and code = 'renter_recovery_pay';
select test.eq('otherwise it goes', app.job_booking_recovery(test.t62('2 hours')), 'sent 1, stopped 0');

-- an offer close to its expiry: the expiry reminder covers it
select test.mk_booking('C62-R4', 'c62car2', 'c62_rita', '2031-07-01 10:00', '2031-07-03 10:00', 'offered');
update bookings set offer_expires_at = test.t62('9 hours') where id = test.id('booking:C62-R4');
insert into visitor_signals (dedupe_key, visitor_id, renter_id, kind, label, booking_id, first_at, last_at)
values ('offer:c62r4:1', test.id('c62vid'), test.id('renter:c62_rita'), 'offer_opened', 'Opened offer C62-R4', test.id('booking:C62-R4'), test.t62(), test.t62());
select test.eq('an offer that expires within 7 hours gets no recovery email', app.job_booking_recovery(test.t62('4 hours 30 minutes')), 'sent 0, stopped 0');

-- a request started and stopped: marketing, so only with express consent
insert into visitor_signals (dedupe_key, visitor_id, renter_id, kind, label, vehicle_id, first_at, last_at)
values ('request:c62:1', test.id('c62vid'), test.id('renter:c62_rita'), 'request_stopped', 'Started a request and stopped', test.id('vehicle:c62car2'), test.t62(), test.t62());
update users set marketing_opt_in = false, marketing_opt_in_at = null where id = test.id('c62_rita');
select test.eq('a request: no consent, no email', app.job_booking_recovery(test.t62('3 hours')), 'sent 0, stopped 0');
update users set marketing_opt_in = true, marketing_opt_in_at = test.t62('-30 days') where id = test.id('c62_rita');
select test.eq('with consent: one reminder', app.job_booking_recovery(test.t62('3 hours')), 'sent 1, stopped 0');
select test.flush62();
select test.eq('marketing: queued with an unsubscribe link and the car''s page',
  (select format('%s %s %s %s', category, status, (payload ->> 'unsubscribe_url') like 'https://carmacars.ca/%token=%', payload ->> 'car_url') from notification_outbox where code = 'renter_recovery_request' and to_address = 'c62_rita@example.test'),
  'marketing queued t https://carmacars.ca/cars');
-- she sends a request: the series stops
select test.mk_booking('C62-R5', 'c62car2', 'c62_rita', '2031-08-01 10:00', '2031-08-03 10:00', 'requested');
update bookings set created_at = test.t62('5 hours') where id = test.id('booking:C62-R5');
select app.job_booking_recovery(test.t62('1 day 4 hours'));
select test.eq('a request sent stops the series', (select string_agg(step || ' ' || stop_reason, ', ') from recovery_emails where subject_key = 'request:c62:1'), '1 A request was sent');
update program_settings set recovery_emails_enabled = false;
select test.eq('recovery switched off: nothing is sent', app.job_booking_recovery(test.t62('3 days')), 'off, stopped 0');
update program_settings set recovery_emails_enabled = true;

-- ================================================================ 6. the site check
-- the earlier suites' failed emails, jobs and webhooks are not this suite's
update notification_outbox set status = 'skipped', status_reason = 'suite 41: cleared' where status in ('failed', 'queued', 'delayed');
update job_runs set finished_at = coalesce(finished_at, started_at) - interval '2 hours', started_at = started_at - interval '2 hours' where status = 'failed';
update webhook_events set error = null where error is not null;
select test.eq('pages: two failures in a row do not alert', app.uptime_record('home', false, 503, 900, 'Answered 503 with Error 1102 (the web host stopped the page)') || ' / '
  || app.uptime_record('home', false, 503, 900, 'Answered 503 with Error 1102 (the web host stopped the page)'), 'failed 1 of 3 / failed 2 of 3');
insert into s41 values ('h3', to_jsonb(app.uptime_record('home', false, 503, 900, 'Answered 503 with Error 1102 (the web host stopped the page)')));
select test.eq('the third does: an alert, an urgent Admin task, one email event', (test.s41('h3') #>> '{}')
  || ' ' || (select priority || ' ' || title from tasks where task_type = 'site_alert' and status = 'open' and dedupe_key = 'site_alert:home')
  || ' ' || test.ev62('staff_site_alert'), 'alert urgent Site problem: Home page 1');
select test.eq('still failing: no second email', app.uptime_record('home', false, 503, 900, 'x') || ' ' || test.ev62('staff_site_alert'), 'still failing 1');
select test.eq('To do: the site problem first', (app.admin_todo(test.id('c62_admin')) -> 'items' -> 0 ->> 'key') || '=' || (app.admin_todo(test.id('c62_admin')) -> 'items' -> 0 ->> 'count'), 'site_alerts=1');
select test.flush62();
select test.eq('the alert goes to the alert address of Program settings only',
  (select string_agg(to_address || ' ' || (payload ->> 'check_label') || ' ' || (payload ->> 'failures'), ', ') from notification_outbox where code = 'staff_site_alert' and entity_id is distinct from test.id('nt_alert')),
  'site.alerts@example.test Home page 4');
insert into s41 values ('h4', to_jsonb(app.uptime_record('home', true, 200, 120, 'Answered 200')));
select test.eq('it passes again: recovered, the task closes, one recovery email', (test.s41('h4') #>> '{}')
  || ' ' || (select status from tasks where task_type = 'site_alert' and dedupe_key = 'site_alert:home') || ' ' || test.ev62('staff_site_recovered'), 'recovered done 1');
select test.flush62();
select test.eq('the recovery email says how long', (select payload ->> 'alert_duration' from notification_outbox where code = 'staff_site_recovered' and entity_id is distinct from test.id('nt_alert')), '1 minutes');
-- within the cooldown: a new alert shows on To do without another email
select app.uptime_record('home', false, 500, 300, 'Answered 500 (server error)'), app.uptime_record('home', false, 500, 300, 'Answered 500 (server error)'), app.uptime_record('home', false, 500, 300, 'Answered 500 (server error)');
select test.eq('within the cooldown: alert open, not emailed', (select emailed::text from site_alerts where check_key = 'home' and resolved_at is null) || ' ' || test.ev62('staff_site_alert'), 'false 1');
select app.uptime_record('home', true, 200, 100, 'Answered 200');
select test.eq('its recovery sends nothing either', test.ev62('staff_site_recovered'), 1::bigint);
-- the checks without requests
select app.uptime_internal(now());
select test.eq('internal checks: emails, jobs, backup and Stripe all pass on a quiet database',
  (select string_agg(key || '=' || status, ' ' order by sort) from uptime_checks where kind = 'internal'), 'email=ok jobs=ok backup=ok stripe=ok');
insert into notification_outbox (code, category, priority, audience, to_address, dedupe_key, status, attempts, last_error)
select 'renter_offer_ready', 'transactional', 1, 'renter', 'x' || g || '@example.test', 'c62-failed-' || g, 'failed', 3, 'provider error' from generate_series(1, 3) g;
insert into job_runs (job_name, run_key, status, started_at, finished_at, error) values ('backup-nightly', 'c62', 'failed', now() - interval '10 minutes', now() - interval '5 minutes', 'pg_dump: connection refused');
insert into webhook_events (provider, event_id, event_type, error) values ('stripe', 'evt_c62', 'payment_intent.succeeded', 'Booking not found');
select app.uptime_internal(now());
select test.eq('3 failed emails, a failed backup (also a failed job) and a failed Stripe event: four alerts',
  (select string_agg(key || '=' || status, ' ' order by sort) from uptime_checks where kind = 'internal') || ' ' || (select count(*) from site_alerts where resolved_at is null),
  'email=failing jobs=failing backup=failing stripe=failing 4');
select test.eq('the backup alert says why', (select detail from site_alerts where check_key = 'backup' and resolved_at is null), 'The last nightly backup failed: pg_dump: connection refused');
update job_runs set status = 'succeeded', error = null where job_name = 'backup-nightly' and run_key = 'c62';
update webhook_events set error = null where event_id = 'evt_c62';
update notification_outbox set status = 'sent', sent_at = now() where dedupe_key like 'c62-failed-%';
select app.uptime_internal(now());
select test.eq('all pass again: every alert resolved', (select count(*) from site_alerts where resolved_at is null), 0::bigint);
update job_runs set finished_at = now() - interval '31 hours', started_at = now() - interval '31 hours' where job_name = 'backup-nightly' and run_key = 'c62';
select app.uptime_internal(now());
select test.eq('no good backup for 31 hours: failing', (select status || ' ' || (last_detail like 'No good backup for more than 30 hours%') from uptime_checks where key = 'backup'), 'failing true');
update job_runs set finished_at = now(), started_at = now() where job_name = 'backup-nightly' and run_key = 'c62';
select app.uptime_internal(now());
-- the job without pg_net: runs the internal checks, asks nothing
update uptime_checks set last_checked_at = now() - interval '10 minutes' where kind = 'internal';
select test.eq('job: due, no pg_net here', app.job_uptime(now()), 'collected 0, asked 0');
select test.eq('job: not due again within 5 minutes', app.job_uptime(now() + interval '1 minute'), 'collected 0');
select test.eq('page details in words', app.uptime_page_detail(503, '<html>error code: 1102</html>', false, null) || ' | ' || app.uptime_page_detail(null, null, true, null) || ' | ' || app.uptime_page_detail(502, '', false, null),
  'Answered 503 with Error 1102 (the web host stopped the page) | No answer within 15 seconds | Answered 502 (server error)');
select test.eq('the car page check reads a public car''s page', app.uptime_url('car_page') ~ '^https://carmacars\.ca/cars', true);
select test.eq('the status panel: every check, for Admins', (select jsonb_array_length(app.door(test.id('c62_admin'), '', 'admin_read', 'site_health') -> 'checks')), 8);
select test.throws('the status panel is not for assistants', $$ select app.site_health(test.id('c62_cs')) $$, null);
select test.eq('the health answer', public.health_ping() ->> 'ok', 'true');

-- ================================================================ 7. the emails of this release are all in the catalogue and emitted by something
select test.eq('8 emails, each with its emitter', (select count(*) from notification_catalogue where (code like 'renter_recovery_%' or code in ('staff_calendar_conflict', 'staff_calendar_feed_failing', 'staff_site_alert', 'staff_site_recovered'))
  and has_email and emitted_by like '%(0062)'), 8::bigint);
select test.eq('the request reminder is marketing, the others transactional',
  (select string_agg(code || ':' || category, ' ' order by code) from notification_catalogue where code like 'renter_recovery_%'),
  'renter_recovery_change:transactional renter_recovery_offer:transactional renter_recovery_pay:transactional renter_recovery_request:marketing');
