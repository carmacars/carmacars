-- 99: the messages of a booking's start and end, also when nobody recorded the pickup (0430,
-- docs/changes/2026-11-07-booking-moments.md). Fixtures start with "bm" and use example.test and 555 numbers only.
-- app.notify_reminders takes the time, so every check is at a fixed Toronto hour of today (noon unless it says so)
-- and never depends on when the suite runs.
select test.suite('99 booking moments');
update program_settings set field_jobs_auto = false, phone_enabled = true where id = (app.settings()).id;

select test.mk_user('bm_admin', 'admin');
select test.mk_user('bm_fleet', 'va', 'fleet');
select test.mk_user('bm_field', 'field');
update users set phone = '+16475550142' where id = test.id('bm_field');
update users set phone = '+16475550143' where id = test.id('bm_admin');
select test.mk_owner('bm_olive');
select test.mk_vehicle('bm_end', 'bm_olive');
select test.mk_vehicle('bm_unrec', 'bm_olive');
select test.mk_vehicle('bm_soon', 'bm_olive');
select test.mk_vehicle('bm_ins', 'bm_olive');
select test.mk_vehicle('bm_canc', 'bm_olive');
select test.mk_vehicle('bm_ret', 'bm_olive');
select test.mk_vehicle('bm_night', 'bm_olive');
select test.mk_vehicle('bm_started', 'bm_olive');
select test.mk_vehicle('bm_late', 'bm_olive');
select test.mk_vehicle('bm_off', 'bm_olive');
select test.mk_renter('bm_rita');
select test.mk_renter('bm_ivan');
insert into insurers (id, name, billing_email) values (test.id('insurer:bm'), 'Example Insurance BM', 'claims-bm@example.test');

-- today at a Toronto wall-clock time, and that time as text for test.mk_booking
create or replace function test.bm_at(p_hhmm text, p_shift interval default '0'::interval) returns timestamptz language sql stable as $$
  select (((now() at time zone 'America/Toronto')::date + p_hhmm::time) at time zone 'America/Toronto') + p_shift
$$;
create or replace function test.bmt(p_hhmm text, p_shift interval default '0'::interval) returns text language sql stable as $$
  select to_char(test.bm_at(p_hhmm, p_shift) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI')
$$;
create or replace function test.bm_events(p_code text, p_number text) returns bigint language sql stable as $$
  select count(*) from app_events where code = p_code and entity = 'booking' and entity_id = test.id('booking:' || p_number)
$$;
-- 0970: the one "not back" alert of a booking and its return time
create or replace function test.bm_nb(p_number text) returns bigint language sql stable as $$
  select count(*) from app_events where code = 'staff_alert_urgent' and payload ->> 'rule' = 'booking_not_back' and entity_id = test.id('booking:' || p_number)
$$;

-- confirmed, picked up yesterday by the clock and never recorded, back at 2:30 pm today
select test.mk_booking('BM-END', 'bm_end', 'bm_rita', test.bmt('12:00', '-1 day'), test.bmt('14:30'), 'confirmed');
insert into field_jobs (id, kind, booking_id, vehicle_id, assigned_to, scheduled_at, place)
values (test.id('job:bm-end-return'), 'return_check_in', test.id('booking:BM-END'), test.id('vehicle:bm_end'), test.id('bm_field'), test.bm_at('14:30'), '1 Example Street, Toronto');
-- confirmed, the pickup was at 11:20 and nobody recorded it, out for three days; the field staff member did the handover
select test.mk_booking('BM-UNREC', 'bm_unrec', 'bm_ivan', test.bmt('11:20'), test.bmt('11:20', '3 days'), 'confirmed');
insert into field_jobs (id, kind, booking_id, vehicle_id, assigned_to, scheduled_at, place)
values (test.id('job:bm-unrec'), 'handover', test.id('booking:BM-UNREC'), test.id('vehicle:bm_unrec'), test.id('bm_field'), test.bm_at('11:20'), '1 Example Street, Toronto');
-- confirmed, the pickup at 1:30 pm
select test.mk_booking('BM-SOON', 'bm_soon', 'bm_rita', test.bmt('13:30'), test.bmt('13:30', '2 days'), 'confirmed');
-- on rent, billed to an insurer, back at 1:00 pm: the renter holds the car, so the renter is told
select test.mk_booking('BM-INS', 'bm_ins', 'bm_ivan', test.bmt('12:00', '-2 days'), test.bmt('13:00'), 'on_rent');
update bookings set total_due_at_booking_cents = 50000, bill_to = 'insurer', insurer_id = test.id('insurer:bm'), insurer_claim_number = 'CLM-BM-1',
       insurer_share_cents = 44248, insurer_hst_cents = 5752 where id = test.id('booking:BM-INS');
-- cancelled and returned rentals whose return time passed: nothing
select test.mk_booking('BM-CANC', 'bm_canc', 'bm_rita', test.bmt('12:00', '-2 days'), test.bmt('11:00'), 'cancelled');
select test.mk_booking('BM-RET', 'bm_ret', 'bm_rita', test.bmt('12:00', '-2 days'), test.bmt('11:00'), 'returned');
-- on rent, due back at 11 pm the day before yesterday
select test.mk_booking('BM-NIGHT', 'bm_night', 'bm_ivan', test.bmt('12:00', '-4 days'), test.bmt('23:00', '-2 days'), 'on_rent');
-- confirmed and unrecorded, but the rental-started email already went: no "you're all set" on top
select test.mk_booking('BM-STARTED', 'bm_started', 'bm_ivan', test.bmt('11:00'), test.bmt('11:00', '2 days'), 'confirmed');
select app.ntf_emit('renter_rental_started', 'booking', test.id('booking:BM-STARTED'), 'on_rent', jsonb_build_object('booking_id', test.id('booking:BM-STARTED')));

-- ================================================================ out, for messaging
select test.eq('out: on rent, and confirmed with the pickup passed and nothing recorded; not cancelled, returned or a future pickup',
  (select string_agg(b.booking_number || '=' || app.booking_is_out(b, test.bm_at('12:00')), ' ' order by b.booking_number) from bookings b
    where b.booking_number in ('BM-END', 'BM-UNREC', 'BM-SOON', 'BM-INS', 'BM-CANC', 'BM-RET')),
  'BM-CANC=false BM-END=true BM-INS=true BM-RET=false BM-SOON=false BM-UNREC=true');
select test.eq('out: the status is never changed', (select status::text from bookings where id = test.id('booking:BM-END')), 'confirmed');

-- ================================================================ overnight (yesterday, before everything else)
select app.notify_reminders(test.bm_at('03:00', '-1 day'));
select test.eq('overnight: no late notice to the renter at 3 am, the Admins are told at once',
  test.bm_events('renter_late_return_first', 'BM-NIGHT') || '/' || test.bm_events('renter_return_due', 'BM-NIGHT') || '/' || test.bm_nb('BM-NIGHT'), '0/0/1');
select app.notify_reminders(test.bm_at('07:00', '-1 day'));
select test.eq('overnight: at 7 am T13 alone, not the return time notice and not T14 in the same run',
  test.bm_events('renter_late_return_first', 'BM-NIGHT') || '/' || test.bm_events('renter_return_due', 'BM-NIGHT') || '/' || test.bm_events('renter_late_return_final', 'BM-NIGHT'), '1/0/0');
update app_events set created_at = test.bm_at('07:00', '-1 day') where dedupe_key = 'renter_late_return_first:' || test.id('booking:BM-NIGHT') || ':r' || extract(epoch from test.bm_at('23:00', '-2 days'))::bigint;
select app.notify_reminders(test.bm_at('07:35', '-1 day'));
select test.eq('overnight: T14 half an hour after T13', test.bm_events('renter_late_return_final', 'BM-NIGHT'), 1::bigint);

-- ================================================================ noon
select app.notify_reminders(test.bm_at('12:00'));
select test.eq('return soon: the confirmed booking never recorded as picked up gets "ends at 2:30 pm" 3 hours before',
  test.bm_events('renter_return_soon', 'BM-END'), 1::bigint);
select test.eq('return soon: and not also the 24-hour "ends tomorrow" reminder', test.bm_events('renter_return_reminder', 'BM-END'), 0::bigint);
select test.eq('return soon: the insurer-billed rental still tells the renter', test.bm_events('renter_return_soon', 'BM-INS'), 1::bigint);
select test.eq('pickup soon: "see you at 1:30 pm today", and not the day-before reminder as well',
  test.bm_events('renter_pickup_soon', 'BM-SOON') || '/' || test.bm_events('renter_booking_reminder', 'BM-SOON'), '1/0');
select test.eq('trip started: "you''re all set" 40 minutes after a pickup nobody recorded', test.bm_events('renter_trip_started', 'BM-UNREC'), 1::bigint);
select test.eq('trip started: never after the rental-started email', test.bm_events('renter_trip_started', 'BM-STARTED'), 0::bigint);
select test.eq('cancelled and returned rentals get nothing at their end',
  (select count(*) from app_events where entity = 'booking' and entity_id in (test.id('booking:BM-CANC'), test.id('booking:BM-RET'))
      and code in ('renter_return_soon', 'renter_return_due', 'renter_late_return_first', 'renter_late_return_final', 'renter_return_reminder',
                   'staff_late_return_alert', 'staff_not_back', 'staff_not_back_admin')), 0::bigint);

-- pickup not recorded: one task for Fleet, the field staff member in the app and by text, Fleet in the app; no Admin yet
select test.eq('pickup not recorded: Fleet and the field staff member are told, the Admins not yet',
  (select count(*) filter (where dedupe_key like '%:fleet:%') || '/' || count(*) filter (where dedupe_key like '%:u:' || test.id('bm_field') || ':%')
     from app_events where code = 'staff_pickup_unrecorded' and entity_id = test.id('booking:BM-UNREC'))
  || '/' || test.bm_events('staff_pickup_unrecorded_admin', 'BM-UNREC'), '1/1/0');
select test.eq('pickup not recorded: one Fleet task "Record pickup for BM-UNREC, or mark no-show"',
  (select count(*) || ':' || max(title) || ':' || max(queue) from tasks where booking_id = test.id('booking:BM-UNREC') and task_type = 'pickup_unrecorded' and status = 'open'),
  '1:Record pickup for BM-UNREC, or mark no-show:fleet');
select test.ok('pickup not recorded: the field staff member gets a text with the job link',
  exists (select 1 from phone_outbox where to_number = '+16475550142' and booking_id = test.id('booking:BM-UNREC') and kind = 'staff'
             and body like 'CarmaCars: record the pickup for BM-UNREC%' and body like '%/staff/field/jobs/%'));

-- the same run again: nothing twice
select app.notify_reminders(test.bm_at('12:00'));
select app.notify_reminders(test.bm_at('12:10'));
select test.eq('dedupe: a second and third run send nothing again',
  test.bm_events('renter_return_soon', 'BM-END') || '/' || test.bm_events('renter_trip_started', 'BM-UNREC') || '/'
  || (select count(*) from app_events where code = 'staff_pickup_unrecorded' and entity_id = test.id('booking:BM-UNREC')) || '/'
  || (select count(*) from tasks where booking_id = test.id('booking:BM-UNREC') and task_type = 'pickup_unrecorded')
  || '/' || (select count(*) from phone_outbox where to_number = '+16475550142' and booking_id = test.id('booking:BM-UNREC')), '1/1/2/1/1');

-- the in-app notices and what they link to (the email outbox row of the renter, the field job of the staff member)
select app.process_events(null, test.bm_at('12:10'));
select test.ok('in the app: the field staff member''s notice opens the job',
  exists (select 1 from notifications n where n.user_id = test.id('bm_field') and n.code = 'staff_pickup_unrecorded'
             and n.title = 'Record pickup for BM-UNREC, or mark no-show' and n.url like '%/staff/field/jobs/' || test.id('job:bm-unrec')));
select test.ok('staff alerts never use the email limit: no email row for them',
  not exists (select 1 from notification_outbox where code in ('staff_pickup_unrecorded', 'staff_pickup_unrecorded_admin', 'staff_not_back', 'staff_not_back_admin')));
select test.ok('the renter''s "ends at" email is queued to the renter',
  exists (select 1 from notification_outbox where code = 'renter_return_soon' and booking_id = test.id('booking:BM-END') and to_address = 'bm_rita@example.test'));
select test.eq('the text of "ends at": the time, the place and the Extend link',
  (select (app.sms_text_for(o.code, o.payload, 'renter', o.booking_id) ->> 'body') ~ '^CarmaCars: booking BM-END ends at 2:30 pm\. .*/account/bookings/BM-END/extend$'
     from notification_outbox o where o.code = 'renter_return_soon' and o.booking_id = test.id('booking:BM-END') limit 1), true);

-- ================================================================ at the return time, then late
select app.notify_reminders(test.bm_at('14:31'));
select test.eq('return time: the renter is not chased inside the 15 minute grace (0970)',
  test.bm_events('renter_return_due', 'BM-END') || '/' || test.bm_events('renter_late_return_first', 'BM-END'), '0/0');
select app.notify_reminders(test.bm_at('14:46'));
select test.eq('15 minutes late: T13 goes by itself, once (the grace took the return time notice''s place)',
  test.bm_events('renter_late_return_first', 'BM-END') || '/' || test.bm_events('renter_return_due', 'BM-END'), '1/0');
select test.eq('15 minutes late: one alert for the field staff of the return, Fleet and the Admins (0970), the Admin by text with the renter''s phone',
  (select count(*) from app_events where code = 'staff_alert_urgent' and payload ->> 'rule' = 'booking_not_back' and entity_id = test.id('booking:BM-END') and payload ->> 'assigned_to' = test.id('bm_field')::text)
  || '/' || (test.bm_events('staff_not_back_admin', 'BM-END') + test.bm_events('staff_not_back', 'BM-END'))
  || '/' || (select count(*) from phone_outbox where to_number = '+16475550143' and booking_id = test.id('booking:BM-END')
                and body like 'CarmaCars: BM-END not back: due 2:30 pm%' and body like '%call 647-555-0199%'), '1/0/1');
select app.job_ops_watch(test.bm_at('14:46'));
select test.eq('late: the late_return task is raised for the confirmed booking too',
  (select count(*) from tasks where booking_id = test.id('booking:BM-END') and task_type = 'late_return' and status = 'open'), 1::bigint);
-- T14 two hours late, never in the same run as T13
update app_events set created_at = test.bm_at('14:46') where dedupe_key = 'renter_late_return_first:' || test.id('booking:BM-END') || ':r' || extract(epoch from test.bm_at('14:30'))::bigint;
select app.notify_reminders(test.bm_at('16:31'));
select test.eq('2 hours late: T14 goes by itself, once', test.bm_events('renter_late_return_final', 'BM-END'), 1::bigint);
select app.notify_reminders(test.bm_at('16:40'));
select test.eq('2 hours late: and not twice', test.bm_events('renter_late_return_final', 'BM-END'), 1::bigint);

-- an extension moves the return: the short reminder goes again for the new time
set session_replication_role = replica;
update bookings set return_at = test.bm_at('19:00') where id = test.id('booking:BM-END');
set session_replication_role = origin;
select app.notify_reminders(test.bm_at('16:45'));
select test.eq('a new return time arms "ends at" again', test.bm_events('renter_return_soon', 'BM-END'), 2::bigint);

-- ================================================================ escalation and closing
select app.notify_reminders(test.bm_at('14:25'));
select test.eq('pickup not recorded after 3 hours: the Admins are told, with an Admin task',
  test.bm_events('staff_pickup_unrecorded_admin', 'BM-UNREC') || '/'
  || (select count(*) from tasks where booking_id = test.id('booking:BM-UNREC') and task_type = 'pickup_unrecorded_admin' and status = 'open' and queue = 'admin'), '1/1');
insert into booking_cancellations (booking_id, received_at, cancelled_by, reason) values (test.id('booking:BM-UNREC'), now(), 'renter', 'renter_request');
update bookings set status = 'cancelled' where id = test.id('booking:BM-UNREC');
select test.eq('the booking is cancelled: both tasks close themselves',
  (select string_agg(status, ',' order by task_type) from tasks where booking_id = test.id('booking:BM-UNREC') and task_type like 'pickup_unrecorded%'), 'cancelled,cancelled');

-- the late panel's T13 button for a confirmed booking past its return time (it used to say the car is not late)
select test.mk_booking('BM-LATE', 'bm_late', 'bm_rita', to_char((now() - interval '2 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
                       to_char((now() - interval '20 minutes') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'confirmed');
create temp table bm_t13 as select app.late_action(test.id('bm_fleet'), test.id('booking:BM-LATE'), 't13') ->> 'already_sent' as first;
select test.eq('late panel: T13 by hand for a booking nobody recorded as picked up, and a second press sends nothing',
  (select first from bm_t13) || '/' || (app.late_action(test.id('bm_fleet'), test.id('booking:BM-LATE'), 't13') ->> 'already_sent'), 'false/true');
select test.eq('late panel: one T13', test.bm_events('renter_late_return_first', 'BM-LATE'), 1::bigint);
select app.notify_reminders(now());
select test.eq('late panel: the job never sends T13 again after the button', test.bm_events('renter_late_return_first', 'BM-LATE'), 1::bigint);
select test.eq('late panel: the confirmed booking counts as late, and the panel says the pickup is not recorded',
  (select (x ->> 'late') || '/' || (x ->> 'pickup_unrecorded') from app.late_panel(test.id('booking:BM-LATE')) x), 'true/true');

-- ================================================================ switches
update program_settings set notify_return_soon = false where id = (app.settings()).id;
select test.mk_booking('BM-OFF', 'bm_off', 'bm_ivan', test.bmt('12:00', '-1 day'), test.bmt('20:00'), 'on_rent');
select app.notify_reminders(test.bm_at('18:00'));
select test.eq('a moment switched off in Settings is not sent', test.bm_events('renter_return_soon', 'BM-OFF'), 0::bigint);
update program_settings set notify_return_soon = true where id = (app.settings()).id;
select test.ok('every new moment has its text, on, in Settings > Text alerts',
  (select count(*) from sms_templates where enabled and code in ('renter_pickup_soon', 'renter_trip_started', 'renter_return_soon', 'renter_return_due')) = 4);
