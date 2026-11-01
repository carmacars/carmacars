-- 0430: messages when a booking starts and ends, also when the pickup was never recorded
-- (docs/changes/2026-11-07-booking-moments.md). The owner: "There isn't enough messaging and emails when a booking is
-- ending or starting. The booking that ended 44 mins ago, I had to manually reach out to them."
--
-- Why: every reminder and late notice of the end of a rental keyed on status on_rent. A booking whose pickup nobody
-- tapped stays confirmed, so it got no return reminder, no late notice and no late task, although Bookings > Now (0330)
-- already counted it as out ("pickup not recorded"). On November 1 every overdue booking was one of those.
--
-- 1. Out for messaging: app.booking_is_out(booking, now) is on rent, or confirmed with its pickup time passed and no
--    handover or check-in recorded (not a placeholder, and not "ended, never closed": the same car went out again after
--    it). The booking's status is never changed by it. Used by every renter reminder and late notice of the end of a
--    rental, the staff late alerts, the late tasks (app.job_ops_watch), the late panel and its buttons
--    (app.late_panel, app.late_action). Bookings > Now already counts the same rentals as out (0330's own test).
--    A confirmed booking counts for the late notices for 24 hours after its return time (no old booking is chased).
-- 2. Pickup not recorded: 30 minutes after the pickup time (notify_pickup_unrecorded_minutes) one task for Fleet
--    ("Record pickup for CC-xxxxx, or mark no-show") and an alert to the field staff on the handover (in the app, on
--    their phone, and a text) and to Fleet in the app. At 3 hours (notify_pickup_unrecorded_admin_minutes) a task
--    and an alert for the Admins. Once per booking and pickup time; the tasks close themselves when the booking leaves
--    confirmed (picked up: done; cancelled or no-show: cancelled).
-- 3. The renter's start and end, by email, by text (their channel, 0096) and on their phone where they turned alerts
--    on (0300), each once per booking and per pickup or return time (a moved time sends it again):
--      day before pickup (T5, as before), pickup in about 2 hours (renter_pickup_soon, new), "you're all set" 30
--      minutes after a pickup that was not recorded (renter_trip_started, new; renter_rental_started still goes when
--      the handover is recorded), 24 hours before the return (T6, as before), about 3 hours before (renter_return_soon,
--      new, with the one-tap Extend link), at the return time (renter_return_due, new), T13 automatically at 15
--      minutes late (was at 0) and T14 automatically at 2 hours (late_admin_minutes, at least 30 minutes after T13). The
--      late panel's T13 and T14 buttons send the same notices, so never twice. T5 and T6 are skipped when the pickup or
--      the return is already inside the window of the shorter reminder, which says the same thing with the right day.
--    The late notices and the short reminders go only between 7 am and 10 pm Toronto time (notify_renter_from_hour,
--    notify_renter_until_hour): overnight they wait until 7 am, when the job checks again (a car returned in the night
--    gets nothing). An insurer-billed booking messages the renter like any other (they hold the car).
-- 4. Not back: 15 minutes after the return time (notify_not_back_minutes) with no return recorded, an alert to the
--    field staff of the return (else the handover) and to the Admins, in the app, on their phone and by text
--    ("CC-xxxxx not back: renter name, phone"), at any hour. The late_return_admin task stays as it was.
-- 5. Settings: one switch per moment (all on) under Settings > Text alerts, "Booking start and end", and in Program
--    settings with the other notify_ values.
-- No applied migration is edited.
set local check_function_bodies = off;

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;
create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0430: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. settings (every moment on)
alter table program_settings
  add column if not exists notify_pickup_soon boolean not null default true,
  add column if not exists notify_pickup_soon_hours integer not null default 2 check (notify_pickup_soon_hours between 1 and 12),
  add column if not exists notify_trip_started boolean not null default true,
  add column if not exists notify_return_soon boolean not null default true,
  add column if not exists notify_return_soon_hours integer not null default 3 check (notify_return_soon_hours between 1 and 12),
  add column if not exists notify_return_due boolean not null default true,
  add column if not exists notify_late_auto boolean not null default true,
  add column if not exists notify_late_first_minutes integer not null default 15 check (notify_late_first_minutes between 0 and 110),
  add column if not exists notify_renter_from_hour integer not null default 7 check (notify_renter_from_hour between 0 and 23),
  add column if not exists notify_renter_until_hour integer not null default 22 check (notify_renter_until_hour between 1 and 24),
  add column if not exists notify_pickup_unrecorded boolean not null default true,
  add column if not exists notify_pickup_unrecorded_minutes integer not null default 30 check (notify_pickup_unrecorded_minutes between 5 and 600),
  add column if not exists notify_pickup_unrecorded_admin_minutes integer not null default 180 check (notify_pickup_unrecorded_admin_minutes between 10 and 1440),
  add column if not exists notify_not_back boolean not null default true,
  add column if not exists notify_not_back_minutes integer not null default 15 check (notify_not_back_minutes between 0 and 600);
comment on column program_settings.notify_pickup_soon is 'Booking start (0430): the renter gets "see you at 2:00 pm today" about notify_pickup_soon_hours before the pickup (email, text, phone alert).';
comment on column program_settings.notify_trip_started is 'Booking start (0430): "you''re all set" to the renter when the pickup time passed and nobody recorded the handover (renter_rental_started goes when it is recorded).';
comment on column program_settings.notify_return_soon is 'Booking end (0430): the renter gets "your rental ends at 5:00 pm" with the Extend link about notify_return_soon_hours before the return.';
comment on column program_settings.notify_return_due is 'Booking end (0430): the renter gets "your booking ended at 5:00 pm, return now or extend" at the return time.';
comment on column program_settings.notify_late_auto is 'Booking end (0430): send T13 (notify_late_first_minutes late) and T14 (late_admin_minutes late) automatically. Off: only from the late panel''s buttons.';
comment on column program_settings.notify_late_first_minutes is 'Booking end (0430): minutes after the return time that T13 goes (15).';
comment on column program_settings.notify_renter_from_hour is 'Booking start and end (0430): the late notices and the short reminders go to renters from this Toronto hour (7) until notify_renter_until_hour (22). Overnight they wait.';
comment on column program_settings.notify_pickup_unrecorded is 'Booking start (0430): a task for Fleet and an alert to the field staff when the pickup time passed and no pickup is recorded; the Admins at notify_pickup_unrecorded_admin_minutes.';
comment on column program_settings.notify_not_back is 'Booking end (0430): an alert to the return''s field staff and the Admins (app, phone, text) notify_not_back_minutes after the return time with no return recorded.';

-- ================================================================ 2. out, for messaging
create or replace function app.booking_is_out(b bookings, p_now timestamptz default now()) returns boolean
language sql stable security definer set search_path = public, app as $$
  select case
    when b.status = 'on_rent' then true
    when b.status = 'confirmed' and b.pickup_at <= p_now and b.handed_over_at is null and b.checked_in_at is null
         and not coalesce(b.is_placeholder, false)
         -- ended, never closed (0330): the same car went out again after this booking's return
         and not exists (select 1 from bookings n where n.vehicle_id = b.vehicle_id and n.id <> b.id and not coalesce(n.is_placeholder, false)
                           and n.pickup_at >= b.return_at - interval '1 hour' and n.pickup_at <= p_now
                           and (n.status in ('on_rent', 'returned', 'closed') or (n.status = 'confirmed' and n.pickup_at <= p_now)))
      then true
    else false end
$$;
comment on function app.booking_is_out(bookings, timestamptz) is 'Out for messaging (0430): on rent, or confirmed with its pickup time passed and no handover or check-in recorded (not a placeholder, not ended and never closed). Never changes the status.';

-- out, and nothing at all recorded for the pickup (no handover, no completed pickup condition report)
create or replace function app.booking_pickup_unrecorded(b bookings, p_now timestamptz default now()) returns boolean
language sql stable security definer set search_path = public, app as $$
  select b.status = 'confirmed' and app.booking_is_out(b, p_now)
     and not exists (select 1 from condition_reports c where c.booking_id = b.id and c.kind = 'pickup' and c.completed_at is not null)
$$;

-- the hours the late notices and the short reminders may reach a renter (7 am to 10 pm Toronto)
create or replace function app.renter_notice_hours(p_now timestamptz default now()) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.local_hour(p_now) >= s.notify_renter_from_hour and app.local_hour(p_now) < s.notify_renter_until_hour
    from (select (app.settings(app.local_date(p_now))).*) s
$$;

-- a text to a member of staff (their phone on file), for the alerts of this migration; never twice for one key
create or replace function app.staff_text(p_user uuid, p_body text, p_booking uuid, p_kind text, p_dedupe text) returns boolean
language plpgsql security definer set search_path = public, app as $$
declare
  v_phone text;
begin
  select app.phone_e164(u.phone) into v_phone from users u where u.id = p_user and u.status = 'active' and nullif(btrim(coalesce(u.phone, '')), '') is not null;
  if v_phone is null then return false; end if;
  perform app.phone_outbox_put(v_phone, p_body, 'staff', p_booking, null, p_kind, null, p_dedupe, now());
  return true;
end $$;
revoke all on function app.booking_is_out(bookings, timestamptz) from public, anon, authenticated;
revoke all on function app.booking_pickup_unrecorded(bookings, timestamptz) from public, anon, authenticated;
revoke all on function app.renter_notice_hours(timestamptz) from public, anon, authenticated;
revoke all on function app.staff_text(uuid, text, uuid, text, text) from public, anon, authenticated;
grant execute on function app.booking_is_out(bookings, timestamptz) to service_role;
grant execute on function app.booking_pickup_unrecorded(bookings, timestamptz) to service_role;
grant execute on function app.renter_notice_hours(timestamptz) to service_role;
grant execute on function app.staff_text(uuid, text, uuid, text, text) to service_role;

-- ================================================================ 3. the renter's emails
-- CATALOGUE 0430 START (generated by supabase/seed/0430_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('renter_pickup_soon', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'See you at {{pickup_time}} today: your {{vehicle_name}}', 'Bring your licence and the card ending {{card_last4}}.', 'About 2 hours before pickup', 'Reminders job (every 5 minutes, migration 0430): a confirmed booking whose pickup is about 2 hours away (Program settings, notify_pickup_soon_hours) and not yet handed over. Sent once per pickup time, so again after the pickup moves. Only between 7 am and 10 pm Toronto time; an earlier pickup has the day-before reminder only. Off with notify_pickup_soon.', null, '/account/bookings/{{booking_number}}/pickup', '[{"name":"booking_number","type":"string"},{"name":"card_last4","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"missing_items","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"pickup_date","type":"string"},{"name":"pickup_place","type":"string"},{"name":"pickup_time","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"},{"name":"verification_pending","type":"boolean"}]'::jsonb, 'templates/renter_pickup_soon.html', 'templates/renter_pickup_soon.txt'),
  ('renter_trip_started', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'You''re all set with the {{vehicle_name}}', 'Return by {{return_time}} on {{return_date}} at {{return_place}}.', '30 minutes after the pickup time, when the handover was not recorded', 'Reminders job (every 5 minutes, migration 0430): the pickup time of a confirmed booking passed 30 minutes ago (notify_pickup_unrecorded_minutes) and the handover was not recorded, so the rental-started email has not gone. The car is treated as out. Sent once per pickup time, never after renter_rental_started. Off with notify_trip_started.', null, '/account/bookings/{{booking_number}}', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"km_allowance","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"overage_rate","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"return_place","type":"string"},{"name":"return_time","type":"string"},{"name":"roadside_phone","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_trip_started.html', 'templates/renter_trip_started.txt'),
  ('renter_return_soon', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Your rental ends at {{return_time}}', 'Return to {{return_place}} with the same fuel and all keys, or extend in one tap.', 'About 3 hours before return', 'Reminders job (every 5 minutes, migration 0430): a booking that is out (on rent, or confirmed with its pickup time passed and no handover recorded) has its return about 3 hours away (notify_return_soon_hours). Sent once per return time, so again after an extension moves it. Only between 7 am and 10 pm Toronto time. Off with notify_return_soon.', null, '/account/bookings/{{booking_number}}/extend', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"fuel_out","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"late_fee_hourly","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"return_place","type":"string"},{"name":"return_time","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_return_soon.html', 'templates/renter_return_soon.txt'),
  ('renter_return_due', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Your booking ended at {{return_time}}', 'Please return the {{vehicle_name}} now, or extend if you need more time.', 'At the return time', 'Reminders job (every 5 minutes, migration 0430): the return time of a booking that is out has come and no return is recorded. Sent once per return time, in the first 15 minutes (T13 follows at 15 minutes late). Only between 7 am and 10 pm Toronto time. Off with notify_return_due.', null, '/account/bookings/{{booking_number}}/extend', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"late_fee_hourly","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"return_place","type":"string"},{"name":"return_time","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_return_due.html', 'templates/renter_return_due.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 0430 END
update notification_catalogue set emitted_by = 'app.notify_reminders (0430)'
 where code in ('renter_pickup_soon', 'renter_trip_started', 'renter_return_soon', 'renter_return_due');

-- the existing notices of the start and end: their new timing (the copy of emails/src/emails)
update notification_catalogue set timing = '15 minutes after the return time',
       trigger_text = 'Reminders job (every 5 minutes): the return time has passed, the booking is still out (on rent, or confirmed with its pickup time passed and no handover recorded, migration 0430) and no paid extension covers the time. Sent once per return time, 15 minutes late (notify_late_first_minutes; renter_return_due goes at the return time). Between 7 am and 10 pm Toronto time; overnight it waits until 7 am. The late panel sends the same notice by hand, never twice. (Message template T13.)'
 where code = 'renter_late_return_first';
update notification_catalogue set
       trigger_text = 'Reminders job (every 5 minutes): the booking is 2 hours past its return time (late_admin_minutes), still out (on rent, or confirmed with no handover recorded, migration 0430), with no paid extension, and T13 went at least 30 minutes ago. Between 7 am and 10 pm Toronto time; overnight it waits until 7 am. The late panel sends the same notice by hand, never twice. The deadline shown is 1 hour after this email is sent. (Message template T14.)'
 where code = 'renter_late_return_final';
update notification_catalogue set
       trigger_text = 'Reminders job (every 5 minutes): the booking is out (on rent, or confirmed with its pickup time passed and no handover recorded, migration 0430) and the return time is 24 hours away. Sent once per return time, so it is sent again after an extension moves the return. Not sent when the return is already inside the 3 hours of renter_return_soon. (Message template T6.)'
 where code = 'renter_return_reminder';
update notification_catalogue set
       trigger_text = 'Reminders job (every 5 minutes): booking status is confirmed and the pickup time is 24 hours away. Sent once per pickup time. Not sent when the pickup is already inside the 2 hours of renter_pickup_soon (migration 0430). (Message template T5.)'
 where code = 'renter_booking_reminder';

-- the staff alerts: in the app and on the phone only (no email, so nothing from the daily email limit), texted by
-- app.notify_booking_staff
insert into notification_catalogue (code, audience, also_sent_to, category, subject, preheader, has_email, priority, emitted_by, link_path,
                                    timing, trigger_text, variables, push_topic)
values
  ('staff_pickup_unrecorded', 'staff_va_fleet', '{}'::text[], 'transactional', 'Record pickup for {{booking_number}}, or mark no-show',
   '{{vehicle_name}} for {{renter_name}} was due out at {{pickup_time}}. No pickup is recorded yet.', false, 3,
   'app.notify_booking_staff (0430)', '/staff/bookings/{{booking_number}}', '30 minutes after the pickup time',
   'Reminders job (every 5 minutes, migration 0430): the pickup time of a confirmed booking passed notify_pickup_unrecorded_minutes ago and no handover or pickup condition report is recorded. To the field staff on the handover (also a text) and to Fleet, with a Fleet task. Once per booking and pickup time.',
   '[{"name":"booking_number","type":"string"},{"name":"vehicle_name","type":"string"},{"name":"renter_name","type":"string"},{"name":"renter_phone","type":"string"},{"name":"pickup_time","type":"string"},{"name":"pickup_date","type":"string"}]'::jsonb,
   'handovers'),
  ('staff_pickup_unrecorded_admin', 'staff_admin', '{}'::text[], 'transactional', 'Pickup still not recorded: {{booking_number}}',
   '{{vehicle_name}} for {{renter_name}} ({{renter_phone}}) was due out {{pickup_date}} at {{pickup_time}}. Record it or mark a no-show.', false, 3,
   'app.notify_booking_staff (0430)', '/admin/bookings/{{booking_number}}', '3 hours after the pickup time',
   'Reminders job (every 5 minutes, migration 0430): still no pickup recorded notify_pickup_unrecorded_admin_minutes after the pickup time. To the Admins, with an Admin task. Once per booking and pickup time.',
   '[{"name":"booking_number","type":"string"},{"name":"vehicle_name","type":"string"},{"name":"renter_name","type":"string"},{"name":"renter_phone","type":"string"},{"name":"pickup_time","type":"string"},{"name":"pickup_date","type":"string"}]'::jsonb,
   'alerts'),
  ('staff_not_back', 'staff_field', '{}'::text[], 'transactional', '{{booking_number}} not back: {{renter_name}}, {{renter_phone}}',
   'Due back at {{return_time}} ({{vehicle_name}}). Call the renter.', false, 3,
   'app.notify_booking_staff (0430)', '/staff/bookings/{{booking_number}}', '15 minutes after the return time',
   'Reminders job (every 5 minutes, migration 0430): a booking that is out is notify_not_back_minutes past its return time with no return recorded. To the field staff of the return (else of the handover), also by text, at any hour. Once per booking and return time.',
   '[{"name":"booking_number","type":"string"},{"name":"vehicle_name","type":"string"},{"name":"renter_name","type":"string"},{"name":"renter_phone","type":"string"},{"name":"return_time","type":"string"},{"name":"return_date","type":"string"}]'::jsonb,
   'handovers'),
  ('staff_not_back_admin', 'staff_admin', '{}'::text[], 'transactional', '{{booking_number}} not back: {{renter_name}}, {{renter_phone}}',
   'Due back at {{return_time}} ({{vehicle_name}}). Call the renter.', false, 3,
   'app.notify_booking_staff (0430)', '/admin/bookings/{{booking_number}}', '15 minutes after the return time',
   'Reminders job (every 5 minutes, migration 0430): a booking that is out is notify_not_back_minutes past its return time with no return recorded. To the Admins, also by text, at any hour. Once per booking and return time.',
   '[{"name":"booking_number","type":"string"},{"name":"vehicle_name","type":"string"},{"name":"renter_name","type":"string"},{"name":"renter_phone","type":"string"},{"name":"return_time","type":"string"},{"name":"return_date","type":"string"}]'::jsonb,
   'alerts')
on conflict (code) do nothing;
select app.notification_catalogue_refresh();

-- phone alerts: the renter's start and end are pickups and returns; the return time is urgent
update notification_catalogue c set push_topic = t.topic
  from (values ('renter_pickup_soon', 'handovers'), ('renter_trip_started', 'handovers'), ('renter_return_soon', 'handovers'),
               ('renter_return_due', 'alerts')) as t(code, topic)
 where c.code = t.code and c.push_topic is null;

-- the texts (Settings > Text alerts). Urgent: the job sends them only from 7 am to 10 pm, so the text quiet hours
-- (9 pm to 8 am) must not hold them past the pickup or the return.
insert into sms_templates (code, label, body, urgent, sort_order) values
  ('renter_pickup_soon', 'Pickup in about 2 hours', 'CarmaCars: see you today at {{pickup_time}} for the {{vehicle_name}} at {{pickup_place}}. Bring your licence and the card you booked with. Details: {{link}}', true, 51),
  ('renter_trip_started', 'Trip started (pickup not recorded)', 'CarmaCars: you''re all set with the {{vehicle_name}}. Return by {{return_date}} at {{return_time}}, {{return_place}}. Trip details and help: {{link}}', false, 54),
  ('renter_return_soon', 'Return in about 3 hours', 'CarmaCars: booking {{booking_number}} ends at {{return_time}}. Please return it to {{return_place}} with the same fuel, clean and with all keys. Need more time? Extend: {{link}}', true, 56),
  ('renter_return_due', 'Return time', 'CarmaCars: your booking {{booking_number}} ended at {{return_time}}. Please return the {{vehicle_name}} now, or extend here if you need more time: {{link}}', true, 62)
on conflict (code) do nothing;
-- T13 now follows the return time notice by 15 minutes: it says what is different (unless an Admin changed it)
update sms_templates set label = 'Late return (15 minutes)',
       body = 'CarmaCars: booking {{booking_number}} is past its return time of {{return_time}}. Late fees start 30 minutes after it. Please return the car now or extend: {{link}}'
 where code = 'renter_late_return_first'
   and body = 'CarmaCars: booking {{booking_number}} ended at {{return_time}}. Please return the car now or extend: {{link}}';

-- while emails are held for the email limit (0212), these go by text at once too
update site_settings set email_limit_text_codes = (select array_agg(distinct x order by x) from unnest(email_limit_text_codes || array[
  'renter_pickup_soon', 'renter_trip_started', 'renter_return_reminder', 'renter_return_soon', 'renter_return_due',
  'renter_late_return_first', 'renter_late_return_final']::text[]) x);

-- the links: the short reminders of the end open Extend, the pickup one the pickup page
alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre0430;
create function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare x jsonb := coalesce(app.ntf_payload_pre0430(p_code, p_event, p_to), '{}'::jsonb);
begin
  if p_code in ('renter_return_soon', 'renter_return_due') and x ? 'booking_number' then
    x := x || jsonb_build_object('_url', app.ntf_link('booking_extend', x));
  elsif p_code = 'renter_pickup_soon' and x ? 'booking_number' then
    x := x || jsonb_build_object('_url', app.ntf_link('booking_pickup', x));
  end if;
  return x;
end $$;
select pg_temp.copy_grants('app.notification_payload(text, app_events, jsonb)'::regprocedure, 'app.ntf_payload_pre0430(text, app_events, jsonb)'::regprocedure);

-- ================================================================ 4. tasks
insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  ('pickup_unrecorded',       'fleet', 'Record the pickup, or mark a no-show',      'high',   'minutes', 0, 3, null, 'The pickup time passed 30 minutes ago and nothing is recorded (0430)'),
  ('pickup_unrecorded_admin', 'admin', 'Pickup still not recorded after 3 hours',   'urgent', 'minutes', 0, 3, null, 'Escalation of pickup_unrecorded (0430)')
on conflict (task_type) do nothing;

-- the tasks close themselves: picked up, cancelled, no-show; a late task when the booking is closed or cancelled
create or replace function app.booking_moments_tasks_close() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status is not distinct from old.status then return null; end if;
  if old.status = 'confirmed' then
    perform app.resolve_tasks(array['pickup_unrecorded', 'pickup_unrecorded_admin'], new.id, null,
      case when new.status in ('on_rent', 'returned', 'closed') then 'Closed by itself: the pickup is recorded'
           else 'Closed by itself: the booking is ' || replace(new.status::text, '_', ' ') end,
      new.status::text in ('cancelled', 'no_show', 'expired', 'declined'));
  end if;
  if new.status::text in ('closed', 'cancelled', 'no_show', 'expired', 'declined') then
    perform app.resolve_tasks(array['late_return', 'late_return_admin'], new.id, null,
      'Closed by itself: the booking is ' || replace(new.status::text, '_', ' '), new.status::text <> 'closed');
  end if;
  return null;
end $$;
drop trigger if exists bookings_moments_tasks_close on bookings;
create trigger bookings_moments_tasks_close after update of status on bookings for each row execute function app.booking_moments_tasks_close();

-- the late tasks of ops-watch (every 15 minutes) for every rental that is out
select pg_temp.patch_fn('app.job_ops_watch(timestamptz)'::regprocedure,
  'from bookings b where b.status = ''on_rent'' and b.return_at < p_now',
  'from bookings b where b.status in (''on_rent'', ''confirmed'') and app.booking_is_out(b, p_now) and b.return_at < p_now
                and (b.status = ''on_rent'' or b.return_at > p_now - interval ''24 hours'')');

-- the late panel and its buttons
select pg_temp.patch_fn('app.late_panel(uuid)'::regprocedure,
  '''late'', b.status = ''on_rent'' and b.return_at < now()',
  '''late'', app.booking_is_out(b) and b.return_at < now(), ''pickup_unrecorded'', app.booking_pickup_unrecorded(b)');
select pg_temp.patch_fn('app.late_action(uuid, uuid, text, jsonb)'::regprocedure,
  'if b.status <> ''on_rent'' or b.return_at > now() then',
  'if not app.booking_is_out(b) or b.return_at > now() then');

-- ================================================================ 5. the reminders job (every 5 minutes)
create or replace function app.notify_reminders(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings(app.local_date(p_now));
  r record;
  v_n integer := 0;
  v_id bigint;
  v_m integer;
  v_lead interval;
  v_day boolean := app.renter_notice_hours(p_now);
  v_t13 timestamptz;
begin
  -- booking reminder (T5), once per pickup time; a pickup already inside the "pickup soon" window gets that one
  for r in select b.id, b.pickup_at from bookings b
            where b.status = 'confirmed' and b.booking_type <> 'owner' and b.pickup_at > p_now
              and b.pickup_at <= p_now + make_interval(hours => s.notify_booking_reminder_hours)
              and not (s.notify_pickup_soon and v_day and b.pickup_at <= p_now + make_interval(hours => s.notify_pickup_soon_hours)) loop
    v_id := app.ntf_emit('renter_booking_reminder', 'booking', r.id, 'pickup:' || extract(epoch from r.pickup_at)::bigint, jsonb_build_object('booking_id', r.id));
    v_n := v_n + (v_id is not null)::integer;
  end loop;
  -- pickup in about 2 hours (0430), once per pickup time
  if s.notify_pickup_soon and v_day then
    for r in select b.id, b.pickup_at from bookings b
              where b.status = 'confirmed' and b.booking_type <> 'owner' and not coalesce(b.is_placeholder, false) and b.handed_over_at is null
                and b.pickup_at > p_now and b.pickup_at <= p_now + make_interval(hours => s.notify_pickup_soon_hours) loop
      v_id := app.ntf_emit('renter_pickup_soon', 'booking', r.id, 'pickup:' || extract(epoch from r.pickup_at)::bigint, jsonb_build_object('booking_id', r.id));
      v_n := v_n + (v_id is not null)::integer;
    end loop;
  end if;
  -- pickup details when the window opens (the field job trigger covers later changes)
  for r in select j.id from field_jobs j join bookings b on b.id = j.booking_id
            where j.kind in ('handover', 'delivery') and j.status not in ('cancelled', 'done') and j.assigned_to is not null
              and b.status = 'confirmed' and b.pickup_at > p_now and b.pickup_at <= p_now + make_interval(hours => s.notify_pickup_details_hours) loop
    perform app.ntf_field_job_details((select fj from field_jobs fj where fj.id = r.id), p_now);
  end loop;
  -- "you're all set" when the pickup time passed and nobody recorded the handover (0430); never after renter_rental_started
  if s.notify_trip_started then
    for r in select b.id, b.pickup_at from bookings b
              where b.status = 'confirmed' and b.booking_type <> 'owner' and app.booking_is_out(b, p_now)
                and b.pickup_at <= p_now - make_interval(mins => s.notify_pickup_unrecorded_minutes)
                and b.pickup_at > p_now - interval '24 hours' and b.return_at > p_now
                and not exists (select 1 from app_events e where e.dedupe_key = 'renter_rental_started:' || b.id || ':on_rent') loop
      v_id := app.ntf_emit('renter_trip_started', 'booking', r.id, 'pickup:' || extract(epoch from r.pickup_at)::bigint, jsonb_build_object('booking_id', r.id));
      v_n := v_n + (v_id is not null)::integer;
    end loop;
  end if;
  -- return reminder (T6), once per return time (so again after an extension moves it), for every rental that is out;
  -- a return already inside the "return soon" window gets that one
  for r in select b.id, b.return_at from bookings b
            where b.status in ('on_rent', 'confirmed') and b.booking_type <> 'owner' and app.booking_is_out(b, p_now) and b.return_at > p_now
              and b.return_at <= p_now + make_interval(hours => s.notify_return_reminder_hours)
              and not (s.notify_return_soon and v_day and b.return_at <= p_now + make_interval(hours => s.notify_return_soon_hours)) loop
    v_id := app.ntf_emit('renter_return_reminder', 'booking', r.id, 'return:' || extract(epoch from r.return_at)::bigint, jsonb_build_object('booking_id', r.id));
    v_n := v_n + (v_id is not null)::integer;
  end loop;
  -- return in about 3 hours (0430), once per return time
  if s.notify_return_soon and v_day then
    for r in select b.id, b.return_at from bookings b
              where b.status in ('on_rent', 'confirmed') and b.booking_type <> 'owner' and app.booking_is_out(b, p_now)
                and b.return_at > p_now and b.return_at <= p_now + make_interval(hours => s.notify_return_soon_hours) loop
      v_id := app.ntf_emit('renter_return_soon', 'booking', r.id, 'return:' || extract(epoch from r.return_at)::bigint, jsonb_build_object('booking_id', r.id));
      v_n := v_n + (v_id is not null)::integer;
    end loop;
  end if;
  -- at the return time (0430), in the minutes before T13 (overnight, T13 says it at 7 am instead)
  if s.notify_return_due and v_day then
    for r in select b.id, b.return_at from bookings b
              where b.status in ('on_rent', 'confirmed') and b.booking_type <> 'owner' and app.booking_is_out(b, p_now)
                and b.return_at <= p_now and b.return_at > p_now - make_interval(mins => greatest(s.notify_late_first_minutes, 5)) loop
      v_id := app.ntf_emit('renter_return_due', 'booking', r.id, 'r' || extract(epoch from r.return_at)::bigint, jsonb_build_object('booking_id', r.id));
      v_n := v_n + (v_id is not null)::integer;
    end loop;
  end if;
  -- late returns: the renter at T13 and T14 (the late panel's buttons send the same events); Fleet at each staff stage;
  -- admins too at the final stage. Every rental that is out; a confirmed one for 24 hours after its return time.
  for r in select b.id, b.return_at, b.booking_type from bookings b
            where b.status in ('on_rent', 'confirmed') and app.booking_is_out(b, p_now) and b.return_at <= p_now
              and (b.status = 'on_rent' or b.return_at > p_now - interval '24 hours') loop
    if r.booking_type <> 'owner' and s.notify_late_auto and v_day and p_now >= r.return_at + make_interval(mins => s.notify_late_first_minutes) then
      v_id := app.ntf_emit('renter_late_return_first', 'booking', r.id, 'r' || extract(epoch from r.return_at)::bigint, jsonb_build_object('booking_id', r.id));
      v_n := v_n + (v_id is not null)::integer;
    end if;
    foreach v_m in array s.notify_late_staff_minutes loop
      if p_now >= r.return_at + make_interval(mins => v_m) and v_m < s.late_admin_minutes then
        v_id := app.ntf_emit('staff_late_return_alert', 'booking', r.id, v_m || 'm:' || extract(epoch from r.return_at)::bigint,
          jsonb_build_object('booking_id', r.id, '_roles', jsonb_build_array('staff_va_fleet'),
                             'late_stage', case when v_m = 0 then 'Return time passed' else v_m || ' minutes late' end,
                             'late_action', 'Call the renter, check the tracker and offer a paid extension.',
                             'late_action_short', 'Call the renter and check the tracker.'));
        v_n := v_n + (v_id is not null)::integer;
      end if;
    end loop;
    if p_now >= r.return_at + make_interval(mins => s.late_admin_minutes) then
      if r.booking_type <> 'owner' and s.notify_late_auto and v_day then
        -- the final notice never lands together with the first (an overnight late return: T13 at 7 am, T14 at 7:30)
        select e.created_at into v_t13 from app_events e
         where e.dedupe_key = 'renter_late_return_first:' || r.id || ':r' || extract(epoch from r.return_at)::bigint;
        if v_t13 is not null and v_t13 <= p_now - interval '30 minutes' then
          v_id := app.ntf_emit('renter_late_return_final', 'booking', r.id, 'r' || extract(epoch from r.return_at)::bigint, jsonb_build_object('booking_id', r.id));
          v_n := v_n + (v_id is not null)::integer;
        end if;
      end if;
      v_id := app.ntf_emit('staff_late_return_alert', 'booking', r.id, 'final:' || extract(epoch from r.return_at)::bigint,
        jsonb_build_object('booking_id', r.id, '_roles', jsonb_build_array('staff_va_fleet', 'staff_admin'),
                           'late_stage', (s.late_admin_minutes / 60.0)::numeric(6, 1)::text || ' hours, final notice due',
                           'late_action', 'Call twice. Send the final notice. Tell an admin now.',
                           'late_action_short', 'Call twice and send the final notice.'));
      v_n := v_n + (v_id is not null)::integer;
    end if;
  end loop;
  -- offer reminder: the set hours before expiry, or halfway for a short window
  for r in select b.id, b.current_offer_version, o.sent_at, o.expires_at from bookings b
             join booking_offers o on o.booking_id = b.id and o.version = b.current_offer_version and o.status = 'sent'
            where b.status = 'offered' and o.expires_at > p_now loop
    v_lead := case when r.expires_at - r.sent_at < make_interval(hours => s.notify_offer_halfway_below_hours) then (r.expires_at - r.sent_at) / 2
                   else make_interval(hours => s.notify_offer_reminder_hours) end;
    if p_now >= r.expires_at - v_lead then
      v_id := app.ntf_emit('renter_offer_reminder', 'booking', r.id, 'v' || r.current_offer_version,
        jsonb_build_object('booking_id', r.id, 'time_left', case when r.expires_at - p_now >= interval '2 hours'
                                                                  then floor(extract(epoch from (r.expires_at - p_now)) / 3600)::integer || ' hours'
                                                                  else greatest(ceil(extract(epoch from (r.expires_at - p_now)) / 60), 1)::integer || ' minutes' end));
      v_n := v_n + (v_id is not null)::integer;
    end if;
  end loop;
  -- identity and coverage chase before pickup
  for r in select b.id from bookings b
            where b.status = 'confirmed' and b.booking_type <> 'owner' and b.pickup_at > p_now
              and b.pickup_at <= p_now + make_interval(hours => s.notify_identity_chase_hours)
              and app.ntf_missing_items(b.id) <> '' loop
    v_id := app.ntf_emit('renter_identity_needed', 'booking', r.id, 'chase', jsonb_build_object('booking_id', r.id));
    v_n := v_n + (v_id is not null)::integer;
  end loop;
  -- the renter left the agreement unsigned while paying (same key as 0019's, so never twice)
  for r in select a.id as agreement_id, a.booking_id, g.id as signer_id, g.signer_name, g.signer_email, g.user_id
             from rental_agreements a join bookings b on b.id = a.booking_id
             join rental_agreement_signers g on g.agreement_id = a.id and g.signer_role = 'renter' and g.signed_at is null
            where a.status = 'open' and b.status = 'pending_payment'
              and a.opened_at <= p_now - make_interval(mins => s.notify_agreement_unsigned_minutes) loop
    v_id := app.emit_event('renter_agreement_ready', 'rental_agreement', r.agreement_id,
      jsonb_build_object('booking_id', r.booking_id, 'signer_id', r.signer_id, 'signer_role', 'renter', 'signer_name', r.signer_name,
                         'signer_email', r.signer_email, 'signer_user_id', r.user_id, 'reminder', true),
      'renter_agreement_ready:' || r.agreement_id || ':' || r.signer_id);
    v_n := v_n + (v_id is not null)::integer;
  end loop;
  -- a request unanswered past the waiting time (not one sent back from an offer)
  for r in select b.id, b.requested_at from bookings b
            where b.status = 'requested' and b.current_offer_version is null
              and b.requested_at <= p_now - make_interval(mins => s.notify_request_waiting_minutes)
              and not exists (select 1 from booking_info_requests q where q.booking_id = b.id) loop
    v_id := app.ntf_emit('staff_request_waiting', 'booking', r.id, 'waiting', jsonb_build_object('booking_id', r.id,
      'request_received_at', app.fmt_at(r.requested_at),
      'waiting_time', floor(extract(epoch from (p_now - r.requested_at)) / 3600)::integer || ' hours '
                      || (floor(extract(epoch from (p_now - r.requested_at)) / 60)::integer % 60) || ' minutes',
      'assigned_to', coalesce((select u.full_name from tasks t join users u on u.id = t.assigned_to
                                where t.booking_id = r.id and t.status in ('open', 'in_progress') order by t.created_at limit 1), 'Nobody yet')));
    v_n := v_n + (v_id is not null)::integer;
  end loop;
  -- a Card on File charge still unpaid 24 hours into a rental: now to Finance and the admins
  for r in select p.id, p.booking_id from payments p join bookings b on b.id = p.booking_id
            where p.status = 'failed' and p.purpose not in ('booking_total', 'deposit') and b.status = 'on_rent'
              and p.created_at <= p_now - make_interval(hours => s.notify_payment_failed_alert_hours)
              and not exists (select 1 from payments q where q.parent_payment_id = p.id and q.status = 'succeeded') loop
    v_id := app.ntf_emit('staff_payment_failed', 'payment', r.id, 'unpaid24',
      jsonb_build_object('booking_id', r.booking_id, '_roles', jsonb_build_array('staff_va_finance', 'staff_admin'), '_immediate', true));
    v_n := v_n + (v_id is not null)::integer;
  end loop;
  -- the staff alerts of the start and end (0430)
  v_n := v_n + app.notify_booking_staff(p_now);
  return v_n;
end $$;

-- Pickup not recorded and not back: the field staff, Fleet and the Admins (0430). In the app and on the phone (the
-- catalogue rows have no email) and by text to the field staff and the Admins with a phone on file.
create or replace function app.notify_booking_staff(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings(app.local_date(p_now));
  r record;
  u record;
  v_n integer := 0;
  v_id bigint;
  v_epoch bigint;
  v_base text := rtrim(coalesce(s.notify_base_url, 'https://carmacars.ca'), '/');
  v_who text;
begin
  if s.notify_pickup_unrecorded then
    for r in select b.id, b.booking_number, b.vehicle_id, b.renter_id, b.pickup_at, app.vehicle_name(b.vehicle_id) as car
               from bookings b
              where b.status = 'confirmed' and b.booking_type <> 'owner' and app.booking_pickup_unrecorded(b, p_now)
                and b.pickup_at <= p_now - make_interval(mins => s.notify_pickup_unrecorded_minutes)
                and b.pickup_at > p_now - interval '7 days' and b.return_at > p_now - interval '24 hours' loop
      v_epoch := extract(epoch from r.pickup_at)::bigint;
      v_id := app.ntf_emit('staff_pickup_unrecorded', 'booking', r.id, 'fleet:' || v_epoch,
        jsonb_build_object('booking_id', r.id, '_roles', jsonb_build_array('staff_va_fleet'),
                           '_url', app.ntf_link('va_fleet_booking', jsonb_build_object('booking_number', r.booking_number))));
      if v_id is not null then
        v_n := v_n + 1;
        perform app.raise_task(p_type => 'pickup_unrecorded', p_title => format('Record pickup for %s, or mark no-show', r.booking_number),
          p_detail => format('The %s was due out %s. Nothing is recorded yet, so the renter''s messages run as if the car is out. Record the pickup on the booking, or mark it a no-show.',
                             r.car, app.fmt_at(r.pickup_at)),
          p_booking => r.id, p_vehicle => r.vehicle_id, p_renter => r.renter_id, p_due_at => p_now, p_dedupe => 'pickup_unrecorded:' || r.id || ':' || v_epoch);
        for u in select distinct on (j.assigned_to) j.assigned_to as id, j.id as job_id from field_jobs j
                  where j.booking_id = r.id and j.kind in ('handover', 'delivery') and j.status <> 'cancelled' and j.assigned_to is not null
                  order by j.assigned_to, j.scheduled_at desc loop
          perform app.ntf_emit('staff_pickup_unrecorded', 'booking', r.id, 'u:' || u.id || ':' || v_epoch,
            jsonb_build_object('booking_id', r.id, 'recipient_user_id', u.id, '_url', app.ntf_link('field_job', jsonb_build_object('job_id', u.job_id))));
          perform app.staff_text(u.id, format('CarmaCars: record the pickup for %s (%s, due %s), or mark it a no-show: %s',
                                              r.booking_number, r.car, app.fmt_time(r.pickup_at), app.ntf_link('field_job', jsonb_build_object('job_id', u.job_id))),
                                 r.id, 'pickup_unrecorded', 'pickup_unrecorded:' || r.id || ':' || v_epoch || ':' || u.id);
        end loop;
      end if;
      if r.pickup_at <= p_now - make_interval(mins => s.notify_pickup_unrecorded_admin_minutes) then
        v_id := app.ntf_emit('staff_pickup_unrecorded_admin', 'booking', r.id, 'admin:' || v_epoch,
          jsonb_build_object('booking_id', r.id, '_roles', jsonb_build_array('staff_admin'), '_url', v_base || '/admin/bookings/' || r.booking_number));
        if v_id is not null then
          v_n := v_n + 1;
          perform app.raise_task(p_type => 'pickup_unrecorded_admin', p_title => format('Pickup of %s still not recorded', r.booking_number),
            p_detail => format('The %s was due out %s. Fleet was told at %s minutes. Record the pickup, or mark it a no-show.',
                               r.car, app.fmt_at(r.pickup_at), s.notify_pickup_unrecorded_minutes),
            p_booking => r.id, p_vehicle => r.vehicle_id, p_renter => r.renter_id, p_due_at => p_now,
            p_dedupe => 'pickup_unrecorded_admin:' || r.id || ':' || v_epoch, p_escalation_reason => 'pickup not recorded');
        end if;
      end if;
    end loop;
  end if;

  if s.notify_not_back then
    for r in select b.id, b.booking_number, b.return_at, app.vehicle_name(b.vehicle_id) as car, rn.legal_name, rn.mobile
               from bookings b left join renters rn on rn.id = b.renter_id
              where b.status in ('on_rent', 'confirmed') and b.booking_type <> 'owner' and app.booking_is_out(b, p_now)
                and b.return_at <= p_now - make_interval(mins => s.notify_not_back_minutes) and b.return_at > p_now - interval '24 hours' loop
      v_epoch := extract(epoch from r.return_at)::bigint;
      v_who := concat_ws(', ', nullif(btrim(coalesce(r.legal_name, '')), ''), case when nullif(btrim(coalesce(r.mobile, '')), '') is not null then 'call ' || r.mobile end);
      v_id := app.ntf_emit('staff_not_back_admin', 'booking', r.id, 'admin:' || v_epoch,
        jsonb_build_object('booking_id', r.id, '_roles', jsonb_build_array('staff_admin'), '_url', v_base || '/admin/bookings/' || r.booking_number));
      continue when v_id is null;
      v_n := v_n + 1;
      for u in select x.id from users x where x.status = 'active' and app.user_is_admin(x.id) loop
        perform app.staff_text(u.id, format('CarmaCars: %s not back, due %s (%s). %s. Booking: %s', r.booking_number, app.fmt_time(r.return_at), r.car,
                                            coalesce(nullif(v_who, ''), 'No renter phone on file'), v_base || '/admin/bookings/' || r.booking_number),
                               r.id, 'not_back', 'not_back:' || r.id || ':' || v_epoch || ':' || u.id);
      end loop;
      -- the field staff of the return, else of the handover
      for u in select distinct on (j.assigned_to) j.assigned_to as id, j.id as job_id, j.kind from field_jobs j
                where j.booking_id = r.id and j.status <> 'cancelled' and j.assigned_to is not null
                  and (j.kind in ('return_check_in', 'pickup_from_renter')
                       or (j.kind in ('handover', 'delivery') and not exists (
                             select 1 from field_jobs k where k.booking_id = r.id and k.status <> 'cancelled' and k.assigned_to is not null
                                and k.kind in ('return_check_in', 'pickup_from_renter'))))
                order by j.assigned_to, j.scheduled_at desc loop
        perform app.ntf_emit('staff_not_back', 'booking', r.id, 'u:' || u.id || ':' || v_epoch,
          jsonb_build_object('booking_id', r.id, 'recipient_user_id', u.id, '_url', app.ntf_link('field_job', jsonb_build_object('job_id', u.job_id))));
        perform app.staff_text(u.id, format('CarmaCars: %s not back, due %s (%s). %s. Job: %s', r.booking_number, app.fmt_time(r.return_at), r.car,
                                            coalesce(nullif(v_who, ''), 'No renter phone on file'), app.ntf_link('field_job', jsonb_build_object('job_id', u.job_id))),
                               r.id, 'not_back', 'not_back:' || r.id || ':' || v_epoch || ':' || u.id);
      end loop;
    end loop;
  end if;
  return v_n;
end $$;
revoke all on function app.notify_booking_staff(timestamptz) from public, anon, authenticated;
grant execute on function app.notify_booking_staff(timestamptz) to service_role;
