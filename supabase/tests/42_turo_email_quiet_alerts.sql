-- 42: Turo by email and the quiet site alerts (migration 0063). Turo leaves the iCal platforms; per car the Turo listing
-- name; Turo's trip emails (parsed by the Worker) booked, changed, extended and cancelled as External booking blocks
-- with the turnaround, an older email changing nothing, the same email twice, a clash with a confirmed booking,
-- unclear emails to review (task, excerpt, resolve by adding the trip, dismiss), emails not from Turo or not forwarded
-- by rent@, requests, Gmail's forwarding confirmation for the Admins, trips added and cancelled by hand, the bookings
-- to block and free on Turo ("Done on Turo"), the log kept without bodies. Site check: a short problem never emails,
-- a real outage (15 minutes for pages, 30 for emails and Stripe, at once for the backup, never for jobs) emails once
-- with one recovery, at most 3 a day, nothing in the quiet hours unless the site is fully down for an hour, the morning
-- digest line, /api/health waiting for the website deploy, To do. Fixtures start with "t63".
select test.suite('42 Turo by email, quiet site alerts');

select test.mk_user('t63_admin', 'admin');
select test.mk_user('t63_fleet', 'va', 'fleet');
select test.mk_user('t63_cs', 'va', 'cs');
select test.mk_owner('t63_owner');
select test.mk_vehicle('t63car', 't63_owner');
select test.mk_vehicle('t63car2', 't63_owner');
select test.mk_renter('t63_rita');
create or replace function test.t63v(p text default 't63car') returns uuid language sql immutable as $$ select test.id('vehicle:' || p) $$;
create or replace function test.at63(p text) returns timestamptz language sql immutable as $$ select (p::timestamp at time zone 'America/Toronto') $$;
create or replace function test.fl63(p_name text, p jsonb, p_user text default 't63_fleet') returns jsonb language sql as $$
  select app.door(test.id(p_user), '', case when p_user like '%admin' then 'admin_do' else 'va_do' end, p_name, p) $$;
create or replace function test.rd63(p_user text default 't63_fleet') returns jsonb language sql as $$
  select app.door(test.id(p_user), '', case when p_user like '%admin' then 'admin_read' else 'va_read' end, 'calendar_sync', '{}') $$;
create or replace function test.car63(p_user text default 't63_fleet', p text default 't63car') returns jsonb language sql as $$
  select c from jsonb_array_elements(test.rd63(p_user) -> 'cars') c where c ->> 'id' = test.t63v(p)::text $$;
-- one email as the Worker hands it over
create or replace function test.mail63(p_mid text, p_kind text, p_extra jsonb default '{}') returns jsonb language sql as $$
  select app.turo_email_receive(jsonb_build_object('message_id', p_mid, 'envelope_from', 'rent@carmacars.ca', 'from_turo', true, 'kind', p_kind,
           'trip_id', '48211907', 'vehicle_id', test.t63v(), 'guest_first_name', 'Ayesha', 'method', 'rules', 'subject', 'Ayesha ' || p_kind || ' a trip',
           'sent_at', test.at63('2031-04-01 09:00'), 'missing', '[]'::jsonb) || p_extra, test.at63('2031-04-01 09:05')) $$;
create or replace function test.blk63(p text default 't63car') returns text language sql as $$
  select coalesce(string_agg(format('%s %s %s', to_char(k.starts_at at time zone 'America/Toronto', 'MM-DD HH24:MI'), to_char(k.ends_at at time zone 'America/Toronto', 'MM-DD HH24:MI'), k.note), ' | ' order by k.starts_at), 'none')
    from vehicle_calendar_blocks k where k.vehicle_id = test.t63v(p) and k.source = 'external' and k.removed_at is null $$;
create temp table s42 (k text primary key, v jsonb);
grant all on s42 to public;
create or replace function test.s42(p_k text) returns jsonb language sql stable as $$ select v from pg_temp.s42 where k = p_k $$;
update program_settings set turnaround_buffer_minutes = 120, turnaround_block_enabled = true, turo_email_enabled = true, turo_email_forwarders = 'rent@carmacars.ca',
  uptime_alert_email = 'site.alerts@example.test';
update vehicles set turnaround_block_minutes = null where id in (test.t63v(), test.t63v('t63car2'));

-- ================================================================ 1. Turo is not an iCal platform any more
select test.eq('settings: Turo by email on, the inbound address, rent@ forwards, 90 days of log',
  (select format('%s %s %s %s', turo_email_enabled, turo_email_address, turo_email_forwarders, turo_email_keep_days) from (select (app.settings()).*) s),
  't trips@in.carmacars.ca rent@carmacars.ca 90');
select test.throws('a Turo calendar link is refused, in words', $$ select test.fl63('calendar_feed_add', jsonb_build_object('vehicle', test.t63v(), 'platform', 'turo', 'url', 'https://turo.example/x.ics')) $$,
  'Turo has no calendar link%');
select test.eq('Google Calendar is an iCal platform', test.fl63('calendar_feed_add', jsonb_build_object('vehicle', test.t63v('t63car2'), 'platform', 'google', 'url', 'https://calendar.google.example/t63.ics')) ->> 'platform_name', 'Google Calendar');

-- ================================================================ 2. the car's Turo listing
select test.throws('customer service may not set the Turo listing', $$ select test.fl63('turo_link_save', jsonb_build_object('vehicle', test.t63v(), 'listing_name', 'x y z'), 't63_cs') $$, 'Calendar sync is for Admins and Fleet');
select test.throws('a listing name or a Turo car number is needed', $$ select test.fl63('turo_link_save', jsonb_build_object('vehicle', test.t63v())) $$, 'Type the car''s name as Turo shows it%');
select test.throws('the Turo car number is digits', $$ select test.fl63('turo_link_save', jsonb_build_object('vehicle', test.t63v(), 'turo_vehicle_id', 'glc-21')) $$, 'The Turo car number is the number at the end%');
select test.fl63('turo_link_save', jsonb_build_object('vehicle', test.t63v(), 'listing_name', 'Mercedes-Benz C-Class 2023', 'turo_vehicle_id', '2711093'));
select test.eq('saved with its email feed (no link, never fetched)', (select format('%s %s %s', l.listing_name, l.turo_vehicle_id, f.kind || '/' || f.platform || '/' || coalesce(f.url, 'no url'))
  from turo_vehicle_links l join calendar_feeds f on f.vehicle_id = l.vehicle_id and f.kind = 'email' where l.vehicle_id = test.t63v()), 'Mercedes-Benz C-Class 2023 2711093 email/turo/no url');
select test.eq('the email feed is never due a read', (select count(*) from jsonb_array_elements(app.calendar_feeds_due(500, now() + interval '1 day')) x
  where x ->> 'id' = (select id::text from calendar_feeds where vehicle_id = test.t63v() and kind = 'email')), 0::bigint);
select test.eq('the Worker''s keys: the listing, the Turo number, the plate and VIN of the car',
  (select format('%s %s %s %s', c ->> 'listing_name', c ->> 'turo_vehicle_id', (c ->> 'plate') = (select plate from vehicles where id = test.t63v()), length(c ->> 'vin'))
     from jsonb_array_elements(public.turo_match_keys() -> 'cars') c where c ->> 'vehicle_id' = test.t63v()::text), 'Mercedes-Benz C-Class 2023 2711093 t 17');
select test.eq('the Worker''s wrappers are for the server only',
  has_function_privilege('anon', 'public.turo_email_receive(jsonb)', 'execute') or has_function_privilege('authenticated', 'public.turo_match_keys()', 'execute'), false);
select test.throws('an email feed cannot be changed as a calendar link', $$ select test.fl63('calendar_feed_remove', jsonb_build_object('id', (select id from calendar_feeds where vehicle_id = test.t63v() and kind = 'email'))) $$,
  'Turo trips come by email%');

-- ================================================================ 3. booked, the same email twice, changed, extended, an older email, cancelled
insert into s42 values ('b', test.mail63('t63-booked', 'booked', jsonb_build_object('starts_at', test.at63('2031-04-10 10:00'), 'ends_at', test.at63('2031-04-12 10:00'))));
select test.eq('booked: applied, with a short audit line', (test.s42('b') ->> 'status') || ' | ' || (test.s42('b') ->> 'audit'),
  'applied | Booked: Turo trip 48211907, 2023 Mercedes-Benz C 300 t63car, Thu, Apr 10 at 10:00 am to Sat, Apr 12 at 10:00 am (Ayesha)');
select test.eq('an External booking block with the 2-hour turnaround, the trip number in the note, no guest name', test.blk63(), '04-10 08:00 04-12 12:00 Turo: Turo trip 48211907');
select test.eq('availability respects it at once', app.vehicle_is_available(test.t63v(), test.at63('2031-04-12 11:00'), test.at63('2031-04-13 10:00')), false);
select test.eq('only the first name is kept; the log has no excerpt for an email that was read', (select guest_first_name from turo_calendar_trips where trip_id = '48211907')
  || ' ' || (select (excerpt is null)::text || ' ' || status || ' ' || method from turo_inbound_emails where message_id = 't63-booked'), 'Ayesha true applied rules');
select test.eq('the same email again changes nothing', test.mail63('t63-booked', 'booked') ->> 'status', 'duplicate');
select test.eq('the export for Getaround shows the Turo trip as Booked; Turo''s own trips are not echoed',
  (select (app.calendar_export_ics(token, 'getaround', test.at63('2031-04-01 12:00')) ~ 'DTSTART:20310410T1200') || ' ' || (app.calendar_export_ics(token, 'turo', test.at63('2031-04-01 12:00')) ~ 'DTSTART:20310410T1200')
     from vehicle_calendar_exports where vehicle_id = test.t63v()), 'true false');
select test.mail63('t63-changed', 'changed', jsonb_build_object('starts_at', test.at63('2031-04-11 12:00'), 'ends_at', test.at63('2031-04-13 10:00'), 'sent_at', test.at63('2031-04-02 09:00')));
select test.eq('changed: the same block moves', test.blk63(), '04-11 10:00 04-13 12:00 Turo: Turo trip 48211907');
select test.mail63('t63-extended', 'extended', jsonb_build_object('ends_at', test.at63('2031-04-16 10:00'), 'sent_at', test.at63('2031-04-03 09:00')));
select test.eq('extended with only the new end: the start stays', test.blk63(), '04-11 10:00 04-16 12:00 Turo: Turo trip 48211907');
select test.eq('an older email (sent before the last one applied) changes nothing', (test.mail63('t63-late', 'changed', jsonb_build_object('starts_at', test.at63('2031-04-10 10:00'),
  'ends_at', test.at63('2031-04-12 10:00'), 'sent_at', test.at63('2031-04-01 10:00'))) ->> 'reason') || ' | ' || test.blk63(),
  'Older than the last email about this trip | 04-11 10:00 04-16 12:00 Turo: Turo trip 48211907');

-- a clash with a confirmed CarmaCars booking: the 0062 machinery (urgent task, email, To do)
select test.mk_booking('T63-B1', 't63car', 't63_rita', '2031-05-10 10:00', '2031-05-12 10:00', 'confirmed');
select test.mail63('t63-clash', 'booked', jsonb_build_object('trip_id', '48219999', 'starts_at', test.at63('2031-05-11 10:00'), 'ends_at', test.at63('2031-05-13 10:00'), 'sent_at', test.at63('2031-04-04 09:00')));
select test.eq('a Turo trip over a confirmed booking: an urgent Fleet task and the email', (select queue || ' ' || priority || ' ' || title from tasks where task_type = 'calendar_conflict'
  and booking_id = test.id('booking:T63-B1') and status = 'open') || ' ' || (select count(*) from app_events e join calendar_conflicts k on k.id = e.entity_id
  where e.code = 'staff_calendar_conflict' and k.booking_id = test.id('booking:T63-B1')),
  'fleet urgent Double booking: 2023 Mercedes-Benz C 300 t63car on Turo and T63-B1 1');
select test.mail63('t63-clash-cancel', 'cancelled', jsonb_build_object('trip_id', '48219999', 'vehicle_id', null, 'sent_at', test.at63('2031-04-05 09:00')));
select test.eq('cancelled (no car needed): the block goes, the clash closes by itself', (select status from tasks where task_type = 'calendar_conflict' and booking_id = test.id('booking:T63-B1'))
  || ' ' || (select status from turo_calendar_trips where trip_id = '48219999') || ' ' || test.blk63(), 'done cancelled 04-11 10:00 04-16 12:00 Turo: Turo trip 48211907');
select test.eq('a cancellation of a trip never seen frees nothing', test.mail63('t63-cancel-unknown', 'cancelled', jsonb_build_object('trip_id', '11112222')) ->> 'reason',
  'Turo trip 11112222 was not on the calendar: nothing to free');
insert into s42 values ('rebook', test.mail63('t63-rebook', 'booked', jsonb_build_object('trip_id', '48219999',
  'starts_at', test.at63('2031-06-01 10:00'), 'ends_at', test.at63('2031-06-02 10:00'), 'sent_at', test.at63('2031-04-06 09:00'))));
select test.eq('a booking again after a cancellation books it again', (test.s42('rebook') ->> 'status') || ' ' || (select status from turo_calendar_trips where trip_id = '48219999'), 'applied booked');

-- ================================================================ 4. what is ignored, what waits for a person
select test.eq('not forwarded by rent@: ignored', test.mail63('t63-stranger', 'booked', jsonb_build_object('envelope_from', 'someone@example.test', 'trip_id', '55550001',
  'starts_at', test.at63('2031-07-01 10:00'), 'ends_at', test.at63('2031-07-02 10:00'))) ->> 'reason', 'Not forwarded by an allowed mailbox (Program settings, Turo by email)');
select test.eq('Gmail''s forwarding envelope counts as rent@', test.mail63('t63-fwd', 'other', jsonb_build_object('envelope_from', 'rent+caf_=trips=in.carmacars.ca@carmacars.ca')) ->> 'reason',
  'Not about a trip (news, payouts, reviews)');
select test.eq('not from Turo: ignored', test.mail63('t63-notturo', 'booked', jsonb_build_object('from_turo', false)) ->> 'reason', 'Not an email from Turo');
select test.eq('a trip request: nothing blocked until it is booked', test.mail63('t63-request', 'request') ->> 'reason',
  'A trip request waiting for your answer on Turo: nothing is blocked until it is booked');
select test.eq('none of these blocked anything or made a trip', (select count(*) from turo_calendar_trips where trip_id = '55550001') || ' ' || test.blk63(),
  '0 04-11 10:00 04-16 12:00 Turo: Turo trip 48211907 | 06-01 08:00 06-02 12:00 Turo: Turo trip 48219999');
insert into s42 values ('r', test.mail63('t63-unclear', 'booked', jsonb_build_object('trip_id', '53007788', 'vehicle_id', null, 'missing', '["car"]'::jsonb,
  'vehicle_hint', 'Mercedes-Benz GLC', 'excerpt', 'Priya booked your Mercedes-Benz GLC. Trip start: Nov 6, 2026 10:00 AM. Call Priya at [phone].',
  'starts_at', test.at63('2031-08-06 10:00'), 'ends_at', test.at63('2031-08-08 10:00'))));
select test.eq('a car that cannot be told apart: review, a Fleet task, the redacted excerpt kept for it', (test.s42('r') ->> 'status') || ' | ' || (test.s42('r') ->> 'reason')
  || ' | ' || (select queue || ' ' || title from tasks where task_type = 'turo_email_review' and related_id = (test.s42('r') ->> 'id')::uuid)
  || ' | ' || (select left(excerpt, 15) from turo_inbound_emails where id = (test.s42('r') ->> 'id')::uuid),
  'review | Could not read: car | fleet Turo email to check: Ayesha booked a trip | Priya booked yo');
select test.eq('Calendar sync lists it for review, To do counts it',
  (select count(*) from jsonb_array_elements(test.rd63() -> 'turo' -> 'review') x where x ->> 'id' = test.s42('r') ->> 'id') || ' '
  || (select i ->> 'count' from jsonb_array_elements(app.admin_todo(test.id('t63_admin')) -> 'items') i where i ->> 'key' = 'turo_emails'), '1 1');
insert into s42 values ('fix', test.fl63('turo_trip_add', jsonb_build_object('email', test.s42('r') ->> 'id', 'vehicle', test.t63v('t63car2'), 'trip_id', '53007788',
  'starts_at', test.at63('2031-08-06 10:00'), 'ends_at', test.at63('2031-08-08 10:00'), 'guest_first_name', 'Priya')));
select test.eq('resolved by adding the trip: the block, the email resolved, its excerpt gone, the task done', test.blk63('t63car2')
  || ' | ' || (select format('%s %s %s', status, excerpt is null, method) from turo_inbound_emails where id = (test.s42('r') ->> 'id')::uuid)
  || ' | ' || (select status from tasks where task_type = 'turo_email_review' and related_id = (test.s42('r') ->> 'id')::uuid),
  '08-06 08:00 08-08 12:00 Turo: Turo trip 53007788 | resolved t staff | done');
insert into s42 values ('r2', test.mail63('t63-unclear2', 'changed', jsonb_build_object('trip_id', null, 'missing', '["trip id"]'::jsonb)));
select test.fl63('turo_review_dismiss', jsonb_build_object('id', test.s42('r2') ->> 'id'));
select test.eq('dismissed: no task left, nothing waits', (select format('%s %s', status, excerpt is null) from turo_inbound_emails where id = (test.s42('r2') ->> 'id')::uuid)
  || ' ' || (select count(*) from turo_inbound_emails where status = 'review'), 'dismissed t 0');

-- ================================================================ 5. by hand
insert into s42 values ('m', test.fl63('turo_trip_add', jsonb_build_object('vehicle', test.t63v('t63car2'), 'starts_at', test.at63('2031-09-01 09:00'), 'ends_at', test.at63('2031-09-03 09:00'))));
select test.eq('a trip added by hand without a number gets one', (select trip_id ~ '^M-[0-9A-F]{8}$' from turo_calendar_trips where id = (test.s42('m') ->> 'trip')::uuid)::text
  || ' ' || (test.s42('m') ->> 'audit' like 'Added by hand: Turo trip (no number), %'), 'true true');
select test.throws('the end must be after the start', $$ select test.fl63('turo_trip_add', jsonb_build_object('vehicle', test.t63v('t63car2'), 'starts_at', test.at63('2031-09-05 09:00'), 'ends_at', test.at63('2031-09-04 09:00'))) $$,
  'The end is not after the start');
select test.fl63('turo_trip_cancel', jsonb_build_object('id', test.s42('m') ->> 'trip'));
select test.eq('cancelled by hand: its block goes', test.blk63('t63car2'), '08-06 08:00 08-08 12:00 Turo: Turo trip 53007788');
select test.eq('the car''s Turo trips on Calendar sync, the Turo feed not listed as a calendar link',
  (select string_agg(t ->> 'trip_id' || ':' || (t ->> 'blocked') || ':' || coalesce(t ->> 'guest_first_name', '-'), ' ' order by t ->> 'starts_at') from jsonb_array_elements(test.car63() -> 'turo' -> 'trips') t)
  || ' | ' || jsonb_array_length(test.car63() -> 'feeds'), '48211907:true:Ayesha 48219999:true:Ayesha | 0');

-- ================================================================ 6. Gmail's forwarding confirmation
select app.turo_email_receive(jsonb_build_object('message_id', 't63-gmail', 'kind', 'forwarding_confirmation', 'code', '418377214',
  'url', 'https://mail-settings.google.com/mail/vf-abc', 'subject', '(#418377214) Gmail Forwarding Confirmation - Receive Mail from rent@carmacars.ca'), test.at63('2031-04-07 10:00'));
select test.eq('the Admins see the code and link; Fleet does not', (test.rd63('t63_admin') -> 'turo' -> 'confirmation' ->> 'code') || ' ' || (test.rd63('t63_admin') -> 'turo' -> 'confirmation' ->> 'url')
  || ' ' || coalesce(test.rd63() -> 'turo' ->> 'confirmation', 'hidden'), '418377214 https://mail-settings.google.com/mail/vf-abc hidden');
select test.eq('To do: Gmail forwarding to confirm', (select i ->> 'count' from jsonb_array_elements(app.admin_todo(test.id('t63_admin')) -> 'items') i where i ->> 'key' = 'gmail_forwarding'), '1');
select app.turo_email_receive(jsonb_build_object('message_id', 't63-after-confirm', 'envelope_from', 'rent+caf_=trips=in.carmacars.ca@carmacars.ca', 'from_turo', true, 'kind', 'other'), test.at63('2031-04-08 10:00'));
select test.eq('a forwarded Turo email after it means forwarding works: the To do line clears', (select i ->> 'count' from jsonb_array_elements(app.admin_todo(test.id('t63_admin')) -> 'items') i where i ->> 'key' = 'gmail_forwarding'), '0');
select test.throws('a confirmation link from elsewhere is refused', $$ select app.turo_email_receive(jsonb_build_object('message_id', 't63-gmail-bad', 'kind', 'forwarding_confirmation', 'code', '1234567', 'url', 'https://evil.example/mail/vf')) $$, null);

-- ================================================================ 7. Done on Turo: our bookings, blocked there by hand
select test.eq('the confirmed booking is listed to block on Turo, with the turnaround', (select string_agg(format('%s %s %s', b ->> 'booking_number',
  to_char((b ->> 'starts_at')::timestamptz at time zone 'America/Toronto', 'MM-DD HH24:MI'), to_char((b ->> 'ends_at')::timestamptz at time zone 'America/Toronto', 'MM-DD HH24:MI')), ' ')
  from jsonb_array_elements(test.car63() -> 'turo' -> 'block') b), 'T63-B1 05-10 08:00 05-12 12:00');
select test.fl63('turo_block_done', jsonb_build_object('booking', test.id('booking:T63-B1')));
select test.eq('ticked: gone from the list', jsonb_array_length(test.car63() -> 'turo' -> 'block'), 0);
update bookings set pickup_at = test.at63('2031-05-11 10:00'), return_at = test.at63('2031-05-13 10:00') where id = test.id('booking:T63-B1');
select test.eq('its dates change: back on the list with what was blocked', (select (b ->> 'booking_number') || ' was ' || to_char((b -> 'was' ->> 'ends_at')::timestamptz at time zone 'America/Toronto', 'MM-DD HH24:MI')
  from jsonb_array_elements(test.car63() -> 'turo' -> 'block') b), 'T63-B1 was 05-12 12:00');
select test.fl63('turo_block_done', jsonb_build_object('booking', test.id('booking:T63-B1')));
insert into booking_cancellations (booking_id, booked_at, received_at, start_at, cancelled_by, reason, tier, refund_bps, total_paid_cents, refund_cents, retained_cents)
values (test.id('booking:T63-B1'), now() - interval '1 day', now(), test.at63('2031-05-10 10:00'), 'renter', 'renter_request', 'full', 10000, 0, 0, 0);
update bookings set status = 'cancelled' where id = test.id('booking:T63-B1');
select test.eq('cancelled here: listed to free on Turo', (select (b ->> 'booking_number') || ' ' || (b ->> 'why') from jsonb_array_elements(test.car63() -> 'turo' -> 'free') b), 'T63-B1 cancelled');
select test.fl63('turo_unblock_done', jsonb_build_object('booking', test.id('booking:T63-B1')));
select test.eq('freed: nothing left either way; every tick is in the audit log', jsonb_array_length(test.car63() -> 'turo' -> 'free') || ' ' || jsonb_array_length(test.car63() -> 'turo' -> 'block')
  || ' ' || (select count(*) from audit_log where entity_table = 'turo_blocked_bookings' and entity_id = test.id('booking:T63-B1')::text), '0 0 3');

-- ================================================================ 8. the log: no bodies, kept 90 days
select test.eq('no email body is stored: the log holds parsed fields and short lines only',
  (select count(*) from information_schema.columns where table_name = 'turo_inbound_emails' and column_name in ('body', 'html', 'raw', 'text')), 0::bigint);
update turo_inbound_emails set received_at = test.at63('2031-04-01 09:05') - interval '91 days' where message_id = 't63-stranger';
update turo_inbound_emails set received_at = test.at63('2031-04-01 09:05') - interval '15 days', excerpt = 'old excerpt', status = 'review' where message_id = 't63-request';
select test.mail63('t63-housekeeping', 'other');
select test.eq('the next email clears the log after 90 days and excerpts after 14', (select count(*) from turo_inbound_emails where message_id = 't63-stranger')
  || ' ' || (select coalesce(excerpt, 'none') from turo_inbound_emails where message_id = 't63-request'), '0 none');
update turo_inbound_emails set status = 'ignored' where message_id = 't63-request';

-- ================================================================ 9. the site check: alerts that do not spam
delete from site_alerts;
update uptime_checks set status = 'unknown', consecutive_failures = 0, failing_since = null;
update tasks set status = 'cancelled' where task_type = 'site_alert' and status in ('open', 'in_progress', 'waiting');
update program_settings set uptime_fail_threshold = 3, uptime_page_alert_minutes = 15, uptime_email_alert_minutes = 30, uptime_stripe_alert_minutes = 30,
  uptime_max_alert_emails = 3, uptime_quiet_from_hour = 23, uptime_quiet_until_hour = 7, uptime_quiet_outage_minutes = 60;
-- a page result at a Toronto time, then the round's emails (each statement below sees the one before)
create or replace function test.pg63(p_key text, p_ok boolean, p_at text, p_detail text default 'Answered 503 with Error 1102 (the web host stopped the page)') returns text
language plpgsql as $$
declare v text;
begin
  v := app.uptime_record(p_key, p_ok, case when p_ok then 200 else 503 end, 100, case when p_ok then 'Answered 200' else p_detail end, test.at63(p_at));
  return v || ' ' || (app.uptime_notify(test.at63(p_at)) ->> 'alerts');
end $$;
create or replace function test.mails63(p_code text default 'staff_site_alert') returns bigint language sql as $$
  select count(*) from app_events e join site_alerts a on a.id = e.entity_id where e.code = p_code $$;
create or replace function test.todo63(p_key text) returns text language sql as $$
  select i ->> 'count' from jsonb_array_elements(app.admin_todo(test.id('t63_admin')) -> 'items') i where i ->> 'key' = p_key $$;
create or replace function test.flush63() returns integer language sql as $$ select app.process_events(100000) $$;
insert into s42 values ('p1', to_jsonb(test.pg63('home', false, '2031-06-10 12:00') || ' / ' || test.pg63('home', false, '2031-06-10 12:05') || ' / ' || test.pg63('home', false, '2031-06-10 12:10')));
select test.eq('Error 1102 blips: the third in a row is a problem on Site health; no task, no email', (test.s42('p1') #>> '{}')
  || ' / ' || (select status from uptime_checks where key = 'home') || ' ' || (select count(*) from site_alerts where resolved_at is null)
  || ' ' || (select count(*) from tasks where task_type = 'site_alert' and status = 'open') || ' ' || test.mails63(), 'failed 1 of 3 0 / failed 2 of 3 0 / problem 0 / failing 1 0 0');
select test.eq('To do does not count a short problem', test.todo63('site_alerts'), '0');
insert into s42 values ('p2', to_jsonb(test.pg63('home', true, '2031-06-10 12:12')));
select test.eq('it passes after 10 minutes: resolved quietly, no recovery email', (test.s42('p2') #>> '{}') || ' ' || test.mails63('staff_site_recovered'), 'recovered 0 0');
-- a real outage: failing every check for 15 minutes
select test.pg63('home', false, '2031-06-10 13:00'); select test.pg63('home', false, '2031-06-10 13:05'); select test.pg63('home', false, '2031-06-10 13:10');
select test.eq('10 minutes: nothing yet', test.mails63(), 0::bigint);
insert into s42 values ('p3', to_jsonb(test.pg63('home', false, '2031-06-10 13:15')));
select test.eq('15 minutes: an urgent Admin task and one email', (test.s42('p3') #>> '{}') || ' '
  || (select priority || ' ' || title from tasks where task_type = 'site_alert' and status = 'open') || ' ' || test.mails63(), 'still failing 1 urgent Site problem: Home page 1');
insert into s42 values ('p4', to_jsonb(test.pg63('home', false, '2031-06-10 13:20')));
select test.eq('still down: no second email; To do counts it', (test.s42('p4') #>> '{}') || ' ' || test.mails63() || ' ' || test.todo63('site_alerts'), 'still failing 0 1 1');
select test.pg63('home', true, '2031-06-10 13:40');
select test.eq('it passes: one recovery email, the task closes', test.mails63('staff_site_recovered') || ' ' || (select status from tasks where task_type = 'site_alert' order by created_at desc limit 1), '1 done');
select app.uptime_notify(test.at63('2031-06-10 13:45'));
select test.eq('and only one', test.mails63('staff_site_recovered'), 1::bigint);
select test.flush63();
select test.eq('the alert goes to the alert address only; the recovery says how long',
  (select string_agg(to_address || ' ' || (payload ->> 'check_label'), ', ') from notification_outbox o join site_alerts a on a.id = o.entity_id where o.code = 'staff_site_alert')
  || ' | ' || (select payload ->> 'alert_duration' from notification_outbox o join site_alerts a on a.id = o.entity_id where o.code = 'staff_site_recovered'),
  'site.alerts@example.test Home page | 30 minutes');
-- at most three a day: a fourth real outage the same day waits on Site health
select test.pg63('sign_in', false, '2031-06-10 14:00'); select test.pg63('car_page', false, '2031-06-10 14:00'); select test.pg63('health', false, '2031-06-10 14:00');
select test.pg63('sign_in', false, '2031-06-10 14:05'); select test.pg63('car_page', false, '2031-06-10 14:05'); select test.pg63('health', false, '2031-06-10 14:05');
select test.pg63('sign_in', false, '2031-06-10 14:10'); select test.pg63('car_page', false, '2031-06-10 14:10'); select test.pg63('health', false, '2031-06-10 14:10');
select test.pg63('sign_in', false, '2031-06-10 14:15'); select test.pg63('car_page', false, '2031-06-10 14:15'); select test.pg63('health', false, '2031-06-10 14:15');
select test.eq('the fourth alert email of the day is held: the daily limit', test.mails63() || ' ' || (select held_reason from site_alerts where check_key = 'health' and resolved_at is null),
  '3 Daily limit of 3 alert emails reached');
select test.eq('Site health shows it held, with the rules', (select string_agg((o ->> 'label') || ':' || (o ->> 'emailed') || ':' || coalesce(o ->> 'held', '-'), ' ' order by o ->> 'label')
  from jsonb_array_elements(app.site_health(test.id('t63_admin')) -> 'open') o),
  'A car page:true:- Sign-in page:true:- Site health check (/api/health):false:Daily limit of 3 alert emails reached');
select test.pg63('sign_in', true, '2031-06-10 15:00'); select test.pg63('car_page', true, '2031-06-10 15:00'); select test.pg63('health', true, '2031-06-10 15:00');
select test.eq('the two emailed recover with one email each; the held one sends nothing', test.mails63('staff_site_recovered'), 3::bigint);
-- the quiet hours: nothing from 23:00 to 07:00 unless the whole site is down for an hour
select test.pg63('sign_in', false, '2031-06-11 01:00'); select test.pg63('sign_in', false, '2031-06-11 01:05'); select test.pg63('sign_in', false, '2031-06-11 01:10');
select test.pg63('sign_in', false, '2031-06-11 01:20');
select test.eq('a real outage of one page at 1 am waits for the morning', test.mails63() || ' ' || (select held_reason from site_alerts where check_key = 'sign_in' and resolved_at is null),
  '3 Quiet hours: emailed in the morning if it lasts');
select test.pg63('sign_in', false, '2031-06-11 07:00');
select test.eq('still down at 7:00: emailed then', test.mails63(), 4::bigint);
select test.pg63('sign_in', true, '2031-06-11 07:10');
select test.pg63('home', false, '2031-06-12 00:00'); select test.pg63('home', false, '2031-06-12 00:05'); select test.pg63('home', false, '2031-06-12 00:10'); select test.pg63('home', false, '2031-06-12 00:30');
select test.eq('the whole site down at night: nothing at 30 minutes', test.mails63(), 4::bigint);
select test.pg63('home', false, '2031-06-12 01:00');
select test.eq('down for an hour: emailed in the night as a full outage', test.mails63() || ' ' || (select full_outage from site_alerts where check_key = 'home' and resolved_at is null), '5 true');
select test.pg63('home', true, '2031-06-12 01:30');
select test.eq('its recovery in the night goes at once', test.mails63('staff_site_recovered'), 5::bigint);
-- a day outage emailed, recovering in the quiet hours: the recovery waits for the morning
select test.pg63('car_page', false, '2031-06-12 22:30'); select test.pg63('car_page', false, '2031-06-12 22:35'); select test.pg63('car_page', false, '2031-06-12 22:40'); select test.pg63('car_page', false, '2031-06-12 22:45');
select test.eq('emailed at 22:45', test.mails63(), 6::bigint);
select test.pg63('car_page', true, '2031-06-12 23:30');
select test.eq('it recovers at 23:30: no email in the night', test.mails63('staff_site_recovered'), 5::bigint);
select app.uptime_notify(test.at63('2031-06-13 07:00'));
select test.eq('the recovery goes at 7:00', test.mails63('staff_site_recovered'), 6::bigint);
-- the services: emails 30 minutes, Stripe 30 minutes, the backup at once, scheduled jobs never
select app.uptime_record('email', false, null, null, '3 emails failed in the last hour', test.at63('2031-06-13 10:00'));
select app.uptime_record('email', false, null, null, '3 emails failed in the last hour', test.at63('2031-06-13 10:20'));
select test.eq('emails failing for 20 minutes: no email yet', app.uptime_notify(test.at63('2031-06-13 10:20')) ->> 'alerts', '0');
select test.eq('for 30 minutes: emailed', app.uptime_notify(test.at63('2031-06-13 10:30')) ->> 'alerts', '1');
select app.uptime_record('jobs', false, null, null, 'failed runs: owner-debit', test.at63('2031-06-13 08:00'));
select test.eq('a failed scheduled job, even for hours: Site health and the digest only', app.uptime_notify(test.at63('2031-06-13 12:00')) ->> 'alerts', '0');
select test.eq('never emailed, no task', (select count(*) from site_alerts where check_key = 'jobs' and (emailed or task_id is not null)), 0::bigint);
select app.uptime_record('backup', false, null, null, 'The last nightly backup failed: pg_dump: connection refused', test.at63('2031-06-13 12:01'));
select test.eq('the backup failing: emailed at once', app.uptime_notify(test.at63('2031-06-13 12:01')) ->> 'alerts', '1');
select app.uptime_record('stripe', false, null, null, '2 Stripe events failed to process in the last hour', test.at63('2031-06-13 12:02'));
select test.eq('Stripe failing 30 minutes: emailed (the third of June 13)', app.uptime_notify(test.at63('2031-06-13 12:40')) ->> 'alerts', '1');
select test.pg63('home', false, '2031-06-13 13:00'); select test.pg63('home', false, '2031-06-13 13:05'); select test.pg63('home', false, '2031-06-13 13:10'); select test.pg63('home', false, '2031-06-13 13:15');
select test.eq('a fourth real outage that day is held', (select held_reason from site_alerts where check_key = 'home' and resolved_at is null), 'Daily limit of 3 alert emails reached');
select test.pg63('home', false, '2031-06-14 09:00');
select test.eq('the next day it goes (still failing)', (select emailed from site_alerts where check_key = 'home' and resolved_at is null), true);

-- the morning digest: one line for the day's problems
select test.eq('the day in one line', (app.site_check_day_line(test.at63('2031-06-10 00:00'), test.at63('2031-06-11 00:00')) ->> 'line'),
  'Site check: 20 failed checks in the last 24 hours, 3 alert emails');
select test.eq('with the checks and Error 1102 counted', (app.site_check_day_line(test.at63('2031-06-10 00:00'), test.at63('2031-06-11 00:00')) ->> 'meta'),
  'Home page 8 (Error 1102: 8), A car page 4 (Error 1102: 4), Sign-in page 4 (Error 1102: 4), Site health check (/api/health) 4 (Error 1102: 4); 1 held by the quiet hours or the daily limit');
select test.eq('a quiet day has no line', app.site_check_day_line(test.at63('2031-01-01 00:00'), test.at63('2031-01-02 00:00')) is null, true);
update program_settings set notify_digest_morning = '08:00';
select app.notify_digests('morning', gen_random_uuid(), test.at63('2031-06-11 08:00'));
select test.eq('it is in the Admin''s morning digest, once', (select count(*) || ' ' || min(line) from staff_digest_items where dedupe_key = 'site_check_day:2031-06-11' and role = 'admin' and digested_at is not null),
  '1 Site check: 25 failed checks in the last 24 hours, 4 alert emails');

-- /api/health: a website older than the database is waiting for its deploy, not failing
delete from site_alerts where check_key = 'health';
update uptime_checks set status = 'unknown', consecutive_failures = 0, failing_since = null where key = 'health';
select test.eq('the database''s marker; the health answer carries it', app.schema_marker() || ' ' || (app.health_ping() ->> 'schema'), '0063 0063');
insert into s42 values ('w', to_jsonb(app.uptime_page_result('health', 404, '{"Content-Type": "text/html"}', '<html>404</html>', false, null, 80, test.at63('2031-06-15 10:00'))
  || ' ' || app.uptime_page_result('health', 404, '{}', '', false, null, 80, test.at63('2031-06-15 10:05'))
  || ' ' || app.uptime_page_result('health', 404, '{"x-carmacars-schema": "0062"}', '', false, null, 80, test.at63('2031-06-15 10:10'))));
select test.eq('404 from a website without a marker or an older one: waiting for the website deploy', (test.s42('w') #>> '{}')
  || ' | ' || (select status || ' ' || consecutive_failures || ' ' || last_detail from uptime_checks where key = 'health'),
  'waiting waiting waiting | waiting 0 Waiting for the website deploy: the website (0062) is older than the database (0063), so /api/health is not there yet');
select test.eq('no problem, no email', (select count(*) from site_alerts where check_key = 'health'), 0::bigint);
select test.eq('404 from a website as new as the database: a real failure',
  app.uptime_page_result('health', 404, '{"X-CarmaCars-Schema": "0063"}', '', false, null, 80, test.at63('2031-06-15 10:15')), 'failed 1 of 3');
select test.eq('the health check answering ok: working', app.uptime_page_result('health', 200, '{"x-carmacars-schema": "0063"}', '{"ok":true,"schema":"0063"}', false, null, 40, test.at63('2031-06-15 10:20')), 'ok');
select test.eq('Site health: every check with its state', (select string_agg(c ->> 'key' || '=' || (c ->> 'status'), ' ') from jsonb_array_elements(app.site_health(test.id('t63_admin')) -> 'checks') c where c ->> 'key' = 'health'), 'health=ok');

-- ================================================================ 10. the catalogue says what now happens
select test.eq('the alert emails name their new rules and emitter', (select string_agg(code || ':' || emitted_by || ':' || (trigger_text ~ 'quiet'), ' ' order by code)
  from notification_catalogue where code in ('staff_site_alert', 'staff_site_recovered')),
  'staff_site_alert:app.uptime_notify (0063):true staff_site_recovered:app.uptime_notify (0063):true');
