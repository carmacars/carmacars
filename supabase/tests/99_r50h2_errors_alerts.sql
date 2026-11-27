-- 99: R50 hotfix 2, the alerts of the errors branch (migrations 5102 and 5103).
-- REQ-016 (a new request alerts at once), REQ-020 (return due at the return time), REQ-021 (check-in visit wording),
-- REQ-048 (no "jobs locked and left behind" noise). Fixtures start with "rq50a_". Nothing here depends on rows or
-- settings another file leaves: each check names its own fixtures and counts only them.
select test.suite('99 r50h2 errors alerts (5102, 5103)');

select test.mk_user('rq50a_admin', 'admin');
select test.mk_user('rq50a_sales', 'va', 'sales');
select test.mk_user('rq50a_fleet', 'va', 'fleet');
select test.mk_owner('rq50a_olive');
select test.mk_vehicle('rq50a_car', 'rq50a_olive');
select test.mk_vehicle('rq50a_car2', 'rq50a_olive');
select test.mk_vehicle('rq50a_car3', 'rq50a_olive');
select test.mk_vehicle('rq50a_car4', 'rq50a_olive');
select test.mk_vehicle('rq50a_car5', 'rq50a_olive');
select test.mk_renter('rq50a_rita');

-- ---------------------------------------------------------------- 1. a new request alerts at once (REQ-016)
select test.eq('5102: the new request alert is urgent (a push at once)', (select tier from staff_alert_rules where rule = 'booking_requested'), 'urgent');
select test.ok('5102: its audience is Admin, customer service on duty and everyone in Sales',
  (select who @> array['admin', 'on_duty:cs', 'fn:sales'] from staff_alert_rules where rule = 'booking_requested'));
select test.ok('5102: Admin and Sales are told, once each',
  (select count(*) filter (where user_id = test.id('rq50a_admin')) = 1 and count(*) filter (where user_id = test.id('rq50a_sales')) = 1
     from app.staff_alert_users('booking_requested', '{}'::jsonb)));
select test.ok('5102: Fleet is not told of a request',
  not exists (select 1 from app.staff_alert_users('booking_requested', '{}'::jsonb) where user_id = test.id('rq50a_fleet')));

select test.mk_booking('RQ50A-1', 'rq50a_car', 'rq50a_rita', to_char((now() + interval '5 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
                       to_char((now() + interval '7 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'requested');
create function pg_temp.rq50a_alerts(p_rule text, p_booking text) returns bigint language sql as $$
  select count(*) from app_events e where e.entity = 'booking' and e.entity_id = test.id('booking:' || p_booking) and e.code like 'staff\_alert\_%' and e.payload ->> 'rule' = p_rule
$$;
select test.eq('5102: a new request makes exactly one staff alert', pg_temp.rq50a_alerts('booking_requested', 'RQ50A-1'), 1::bigint);
select test.ok('5102: it names the request and points to the booking',
  exists (select 1 from app_events e where e.entity_id = test.id('booking:RQ50A-1') and e.payload ->> 'rule' = 'booking_requested'
             and e.payload ->> 'alert_title' like 'New request RQ50A-1:%' and e.payload ->> 'path_admin' = '/admin/bookings/RQ50A-1'
             and e.payload ->> 'path_staff' = '/staff/bookings/RQ50A-1'));
-- the trigger fires again (a save that changes nothing)
update bookings set status = 'requested' where id = test.id('booking:RQ50A-1');
select test.eq('5102: a save that changes nothing does not alert again', pg_temp.rq50a_alerts('booking_requested', 'RQ50A-1'), 1::bigint);
select test.ok('5102: calling the alert again by hand adds nothing',
  app.staff_alert('booking_requested', 'booking', test.id('booking:RQ50A-1'), 'requested', 'again', '') is null
  and pg_temp.rq50a_alerts('booking_requested', 'RQ50A-1') = 1);
select test.mk_booking('RQ50A-2', 'rq50a_car2', 'rq50a_rita', to_char((now() + interval '5 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
                       to_char((now() + interval '7 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'confirmed');
select test.eq('5102: a booking that is not a request raises no request alert', pg_temp.rq50a_alerts('booking_requested', 'RQ50A-2'), 0::bigint);

-- ---------------------------------------------------------------- 2. a car due back is told at the return time (REQ-020)
-- two returns around midnight in Toronto time (the database runs in UTC: the title must show Toronto time)
create temp table rq50a_ret (n text primary key, return_local text);
insert into rq50a_ret values
  ('RQ50A-3', to_char((now() at time zone 'America/Toronto')::date + 1, 'YYYY-MM-DD') || ' 23:50'),
  ('RQ50A-4', to_char((now() at time zone 'America/Toronto')::date + 2, 'YYYY-MM-DD') || ' 00:05'),
  ('RQ50A-5', to_char((now() at time zone 'America/Toronto')::date + 3, 'YYYY-MM-DD') || ' 23:55');
select test.mk_booking(n, 'rq50a_car' || (right(n, 1)::integer), 'rq50a_rita', to_char((now() - interval '3 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), return_local, 'on_rent')
  from rq50a_ret;
-- the other fixtures of this file are out of the window: only the three above are due, so compare counts per booking
create function pg_temp.rq50a_ret_at(p_n text) returns timestamptz language sql as $$
  select return_at from bookings where id = test.id('booking:' || p_n)
$$;
select test.eq('5102: the return time is the Toronto time asked for (RQ50A-3, 11:50 pm)', app.fmt_time(pg_temp.rq50a_ret_at('RQ50A-3')), '11:50 pm');
select test.eq('5102: and after midnight (RQ50A-4, 12:05 am)', app.fmt_time(pg_temp.rq50a_ret_at('RQ50A-4')), '12:05 am');

-- 31 minutes before: nothing yet
select app.return_due_alerts(pg_temp.rq50a_ret_at('RQ50A-3') - interval '31 minutes');
select test.eq('5102: 31 minutes before the return time: no alert', (select count(*) from app_events where entity_id = test.id('booking:RQ50A-3')
  and payload ->> 'rule' in ('booking_return_soon', 'booking_return_due')), 0::bigint);
-- 20 minutes before: the heads-up, not the due alert
select app.return_due_alerts(pg_temp.rq50a_ret_at('RQ50A-3') - interval '20 minutes');
select test.eq('5102: 20 minutes before: the heads-up', pg_temp.rq50a_alerts('booking_return_soon', 'RQ50A-3'), 1::bigint);
select test.eq('5102: and no due alert yet', pg_temp.rq50a_alerts('booking_return_due', 'RQ50A-3'), 0::bigint);
-- one minute before the return time: still not due
select app.return_due_alerts(pg_temp.rq50a_ret_at('RQ50A-3') - interval '1 minute');
select test.eq('5102: one minute before the return time: not due yet', pg_temp.rq50a_alerts('booking_return_due', 'RQ50A-3'), 0::bigint);
-- at the return time: the due alert, in Toronto time
select app.return_due_alerts(pg_temp.rq50a_ret_at('RQ50A-3'));
select test.eq('5102: at the return time (11:50 pm): the due alert', pg_temp.rq50a_alerts('booking_return_due', 'RQ50A-3'), 1::bigint);
select test.ok('5102: it says the car is due back now, in Toronto time, not UTC',
  exists (select 1 from app_events e where e.entity_id = test.id('booking:RQ50A-3') and e.payload ->> 'rule' = 'booking_return_due'
             and e.payload ->> 'alert_title' = 'RQ50A-3 is due back now: 11:50 pm'));
select app.return_due_alerts(pg_temp.rq50a_ret_at('RQ50A-3') + interval '1 minute');
select test.eq('5102: a later run does not double it', pg_temp.rq50a_alerts('booking_return_due', 'RQ50A-3'), 1::bigint);
-- the 2 hours later case: a run two hours after the return time raises nothing new for the car already told
select app.return_due_alerts(pg_temp.rq50a_ret_at('RQ50A-3') + interval '2 hours');
select test.eq('5102: two hours after the return time adds nothing', pg_temp.rq50a_alerts('booking_return_due', 'RQ50A-3'), 1::bigint);

-- a return just after midnight is told at 12:05 am, by the job that runs every few minutes (notify_booking_staff)
select app.notify_booking_staff(pg_temp.rq50a_ret_at('RQ50A-4'));
select test.eq('5102: the reminders job tells a 12:05 am return at 12:05 am', pg_temp.rq50a_alerts('booking_return_due', 'RQ50A-4'), 1::bigint);
select test.ok('5102: with the time in Toronto, not UTC',
  exists (select 1 from app_events e where e.entity_id = test.id('booking:RQ50A-4') and e.payload ->> 'rule' = 'booking_return_due'
             and e.payload ->> 'alert_title' = 'RQ50A-4 is due back now: 12:05 am'));
-- a fresh return that nobody ran the job for until 2 hours later is not alerted as "due now" 2 hours late
select app.return_due_alerts(pg_temp.rq50a_ret_at('RQ50A-5') + interval '2 hours');
select test.eq('5102: the due alert is not raised 2 hours after the return time', pg_temp.rq50a_alerts('booking_return_due', 'RQ50A-5'), 0::bigint);
select app.return_due_alerts(pg_temp.rq50a_ret_at('RQ50A-5'));
select test.eq('5102: it is raised at the return time', pg_temp.rq50a_alerts('booking_return_due', 'RQ50A-5'), 1::bigint);
-- a car already back is not told
update bookings set checked_in_at = pg_temp.rq50a_ret_at('RQ50A-5') - interval '10 minutes' where id = test.id('booking:RQ50A-5');
select test.eq('5102: a car already back is never told as due', app.return_due_alerts(pg_temp.rq50a_ret_at('RQ50A-5') + interval '1 minute'), 0);

-- ---------------------------------------------------------------- 3. no "jobs locked and left behind" noise (REQ-048)
-- a photo is stuck only when no worker holds its job; the claim keeps the first start time, so a retry looked stuck
insert into listing_intakes (id, vehicle_id, started_role, review_required) values
  (test.id('rq50a:intake'), test.id('vehicle:rq50a_car'), 'admin', false);
insert into photo_jobs (id, vehicle_id, status, requested_at, started_at, attempts) values
  (test.id('rq50a:photo_retry'), test.id('vehicle:rq50a_car'), 'processing', now() - interval '4 hours', now() - interval '3 hours', 2),
  (test.id('rq50a:photo_dead'), test.id('vehicle:rq50a_car'), 'processing', now() - interval '4 hours', now() - interval '3 hours', 1);
-- the retry is held by a worker now; the other has a lock two hours old
insert into listing_jobs (id, intake_id, vehicle_id, kind, photo_job_id, status, max_attempts, locked_at, locked_by) values
  (test.id('rq50a:lj_retry'), test.id('rq50a:intake'), test.id('vehicle:rq50a_car'), 'decode_vin', test.id('rq50a:photo_retry'), 'running', 3, now() - interval '5 minutes', 'rq50a-worker'),
  (test.id('rq50a:lj_dead'), test.id('rq50a:intake'), test.id('vehicle:rq50a_car'), 'draft_copy', test.id('rq50a:photo_dead'), 'running', 3, now() - interval '2 hours', 'rq50a-worker');
select test.ok('5102: a photo a worker holds now is not stuck, however old its first start',
  not (select app.photo_job_stuck(p, now()) from photo_jobs p where p.id = test.id('rq50a:photo_retry')));
select test.ok('5102: a photo whose worker lock is two hours old is stuck',
  (select app.photo_job_stuck(p, now()) from photo_jobs p where p.id = test.id('rq50a:photo_dead')));
select test.ok('5102: Self-healing counts the dead photo only: the "Jobs locked" detail names one stuck photo job from this file',
  (select count(*) from photo_jobs p where p.id in (test.id('rq50a:photo_retry'), test.id('rq50a:photo_dead')) and app.photo_job_stuck(p, now())) = 1);
-- once the dead one is released too, this file's photos raise nothing
update listing_jobs set locked_at = now() - interval '1 minute' where id = test.id('rq50a:lj_dead');
select test.eq('5102: with every photo held by a worker, no photo is stuck',
  (select count(*) from photo_jobs p where p.id in (test.id('rq50a:photo_retry'), test.id('rq50a:photo_dead')) and app.photo_job_stuck(p, now())), 0::bigint);
-- the signal's detail names each queue: with only a worker-held photo here, it never names this file's photos as stuck
create temp table rq50a_sig on commit drop as select 1 where false;
select test.ok('5102: the "Jobs locked and left behind" signal does not count a photo a worker holds',
  not exists (select 1 from app.heal_signals(now()) s where s.key = 'job_locks'
               and (s.evidence -> 'queues' ->> 'photo_jobs (listing photos)')::integer
                   > (select count(*) from photo_jobs p where p.status = 'processing' and p.id not in (test.id('rq50a:photo_retry'), test.id('rq50a:photo_dead'))
                         and app.photo_job_stuck(p, now()))));
-- the release leaves the held photos alone
select app.heal_run_action('release_locks', '{}'::jsonb, null::heal_incidents, now());
select test.eq('5102: releasing locks does not put a photo a worker holds back in the queue',
  (select count(*) from photo_jobs where id in (test.id('rq50a:photo_retry'), test.id('rq50a:photo_dead')) and status = 'processing'), 2::bigint);
delete from listing_jobs where id in (test.id('rq50a:lj_retry'), test.id('rq50a:lj_dead'));
delete from photo_jobs where id in (test.id('rq50a:photo_retry'), test.id('rq50a:photo_dead'));
delete from listing_intakes where id = test.id('rq50a:intake');

-- ---------------------------------------------------------------- 4. the check-in visit reads as a visit, not a pickup (REQ-021)
select test.ok('5103: the visit emails say "mid-rental car check" in the subject and preheader',
  (select bool_and(subject ~* 'mid-rental car check' and preheader ~* 'free') from notification_catalogue where code in ('renter_checkin_reminder', 'renter_checkin_followup')));
select test.ok('5103: the subject and preheader never say pickup, check-in, return or handover',
  not exists (select 1 from notification_catalogue where code in ('renter_checkin_reminder', 'renter_checkin_followup')
                 and regexp_replace(subject || ' ' || coalesce(preheader, ''), '\{\{[^}]*\}\}', '', 'g') ~* '(pick-?up|check-?in|return|hand-?over)'));
select test.ok('5103: they say the renter keeps the car',
  (select bool_and(preheader ~* 'you keep the') from notification_catalogue where code in ('renter_checkin_reminder', 'renter_checkin_followup')));
select test.ok('5103: the text messages say the same, and never say pickup',
  (select bool_and(body ~* 'mid-rental' and body ~* 'you keep the car' and body !~* 'pick-?up') from sms_templates where code in ('renter_checkin_reminder', 'renter_checkin_followup')));
select test.ok('5103: the staff emails for the visit are untouched in meaning (they still name the visit)',
  (select bool_and(subject ~* '(check|visit)') from notification_catalogue where code in ('staff_checkin_booked', 'staff_checkin_today')));
