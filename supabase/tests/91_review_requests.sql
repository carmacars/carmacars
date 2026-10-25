-- 91: the review request program (migration 0138, docs/changes/2026-10-24-review-requests.md). The settings, the sending
-- hours, the mid-trip check-in, the request at the return, the reminder and the final follow-up; the hold while a return or
-- later charge is open and its release; the stop (on-site review, "I already left a review", staff, a Google match,
-- unsubscribed); staff's Ask for a review, Send anyway and Mark reviewed through the door; the renter's page by token;
-- the Google connection without the vault; the earlier review emails not sent while it is on. Fixtures start with "rv".
select test.suite('91 review requests');
update program_settings set review_program_enabled = true;
select test.mk_user('rv_admin', 'admin');
select test.mk_user('rv_cs', 'va', 'cs');
select test.mk_user('rv_fleet', 'va', 'fleet');
select test.mk_owner('rv_owner');
select test.mk_vehicle('rv_car', 'rv_owner');
select test.mk_renter('rv_maya');
select test.mk_renter('rv_unsub');
select test.mk_renter('rv_guest', false);
-- Toronto wall-clock times as timestamptz
create or replace function test.rvt(p text) returns timestamptz language sql immutable as $$ select p::timestamp at time zone 'America/Toronto' $$;
create or replace function test.rvb(p text) returns uuid language sql immutable as $$ select test.id('booking:' || p) $$;
-- volatile: read after a write in the same statement
create or replace function test.rvev(p_code text, p text) returns bigint language sql volatile as $$ select count(*) from app_events where code = p_code and entity_id = test.rvb(p) $$;
create or replace function test.rvr(p text) returns review_requests language sql volatile as $$ select * from review_requests where booking_id = test.rvb(p) $$;

-- ---------------------------------------------------------------- 1. settings and the sending hours
select test.eq('settings: on, check-in for 2 days or more 24 h after pickup, request 60 min after check-in, reminder 24 h, final 7 days, 9 am to 9 pm, hold on',
  (select format('%s %s %s %s %s %s %s %s-%s %s %s', review_program_enabled, review_checkin_enabled, review_checkin_min_days, review_checkin_after_hours,
     review_ask_after_minutes, review_reminder_hours, review_final_days, review_send_from_hour, review_send_until_hour, review_hold_incidentals, review_google_auto_match)
     from program_settings order by effective_from desc limit 1), 't t 2 24 60 24 7 9-21 t t');
select test.eq('the program is on by default for a new settings row (the suites before this one switched it off)',
  (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'review_program_enabled'), 'false');
select test.eq('window: 8:59 am is closed, 9:00 am open, 8:59 pm open, 9:00 pm closed',
  app.review_in_window(test.rvt('2026-11-05 08:59'), 9, 21)::text || app.review_in_window(test.rvt('2026-11-05 09:00'), 9, 21)::text
  || app.review_in_window(test.rvt('2026-11-05 20:59'), 9, 21)::text || app.review_in_window(test.rvt('2026-11-05 21:00'), 9, 21)::text, 'falsetruetruefalse');
select test.eq('next opening: early morning waits for 9 am, late evening for 9 am tomorrow, noon is now',
  to_char(app.review_next_window(test.rvt('2026-11-05 06:10'), 9, 21) at time zone 'America/Toronto', 'MM-DD HH24:MI') || ' '
  || to_char(app.review_next_window(test.rvt('2026-11-05 22:30'), 9, 21) at time zone 'America/Toronto', 'MM-DD HH24:MI') || ' '
  || to_char(app.review_next_window(test.rvt('2026-11-05 12:00'), 9, 21) at time zone 'America/Toronto', 'MM-DD HH24:MI'), '11-05 09:00 11-06 09:00 11-05 12:00');
select test.eq('next opening across the change from daylight time (November 1, 2026)',
  to_char(app.review_next_window(test.rvt('2026-10-31 23:00'), 9, 21) at time zone 'America/Toronto', 'MM-DD HH24:MI'), '11-01 09:00');
select test.throws('the sending hours must open before they close', $$update program_settings set review_send_from_hour = 21, review_send_until_hour = 9$$, 'program_settings_review_hours_check');
select test.throws('the final follow-up comes after the reminder', $$update program_settings set review_reminder_hours = 200, review_final_days = 7$$, 'program_settings_review_final_check');
select test.throws('the Google review link must be https', $$update site_settings set google_review_link = 'http://g.page/x'$$, 'site_settings_google_review_link_check');

-- ---------------------------------------------------------------- 2. the mid-trip check-in
select test.mk_booking('RV-1', 'rv_car', 'rv_maya', '2026-11-02 10:00', '2026-11-05 10:00', 'on_rent');
select test.mk_booking('RV-2', 'rv_car', 'rv_maya', '2026-11-10 10:00', '2026-11-11 10:00', 'on_rent');
select test.eq('check-in: not before 24 hours on the trip', app.review_step(test.rvb('RV-1'), test.rvt('2026-11-03 09:30')), null::text);
select test.eq('check-in: 24 hours after the pickup, inside the hours', app.review_step(test.rvb('RV-1'), test.rvt('2026-11-03 10:05')), 'checkin');
select test.eq('check-in: once (the event and the time)',
  test.rvev('renter_trip_checkin', 'RV-1') || '/' || coalesce(app.review_step(test.rvb('RV-1'), test.rvt('2026-11-03 12:00')), 'none') || '/' || ((test.rvr('RV-1')).checkin_sent_at = test.rvt('2026-11-03 10:05')), '1/none/true');
select test.eq('check-in: no review request during the trip', test.rvev('renter_review_ask', 'RV-1'), 0::bigint);
select test.eq('check-in: a one-day rental gets none', coalesce(app.review_step(test.rvb('RV-2'), test.rvt('2026-11-11 08:00')), 'none') || '/' || test.rvev('renter_trip_checkin', 'RV-2'), 'none/0');
select test.mk_booking('RV-1N', 'rv_car', 'rv_maya', '2026-12-01 10:00', '2026-12-04 10:00', 'on_rent');
select test.eq('check-in: due at 11 pm, waits for 9 am', coalesce(app.review_step(test.rvb('RV-1N'), test.rvt('2026-12-02 23:00')), 'none') || '/' || app.review_step(test.rvb('RV-1N'), test.rvt('2026-12-03 09:03')), 'none/checkin');
select test.eq('check-in: the email''s link is the booking, the text has its own words',
  (select app.notification_payload('renter_trip_checkin', e, '{}'::jsonb) ->> '_url' from app_events e where e.code = 'renter_trip_checkin' and e.entity_id = test.rvb('RV-1')) || ' | '
  || (select left(body, 40) from sms_templates where code = 'renter_trip_checkin'),
  'https://carmacars.ca/account/bookings/RV-1 | CarmaCars: how is the {{vehicle_name}} g');

-- ---------------------------------------------------------------- 3. the request, the reminder, the final follow-up
select test.mk_booking('RV-3', 'rv_car', 'rv_maya', '2026-11-12 10:00', '2026-11-15 10:00', 'returned');
select test.eq('request: not before an hour after the check-in', app.review_step(test.rvb('RV-3'), test.rvt('2026-11-15 10:30')), null::text);
select test.eq('request: an hour after the check-in', app.review_step(test.rvb('RV-3'), test.rvt('2026-11-15 11:01')), 'ask');
select test.eq('request: sent once, asked', test.rvev('renter_review_ask', 'RV-3') || '/' || (test.rvr('RV-3')).status || '/' || coalesce(app.review_step(test.rvb('RV-3'), test.rvt('2026-11-15 15:00')), 'none'), '1/asked/none');
select test.ok('request: the email links the review page by token, "I already left a review" and Google',
  (select x ->> 'review_url' = 'https://carmacars.ca/review/' || (test.rvr('RV-3')).token and x ->> '_url' = x ->> 'review_url'
          and x ->> 'review_done_url' = x ->> 'review_url' || '?done=1' and x ? 'google_review_url'
     from (select app.notification_payload('renter_review_ask', e, '{}'::jsonb) x from app_events e where e.code = 'renter_review_ask' and e.entity_id = test.rvb('RV-3')) q));
select test.eq('reminder: not before 24 hours', app.review_step(test.rvb('RV-3'), test.rvt('2026-11-16 10:59')), null::text);
select test.eq('reminder: due at 11 am the next day', app.review_step(test.rvb('RV-3'), test.rvt('2026-11-16 11:02')), 'reminder');
select test.eq('final: not before 7 days, then sent; the sequence is finished',
  coalesce(app.review_step(test.rvb('RV-3'), test.rvt('2026-11-21 12:00')), 'none') || '/' || app.review_step(test.rvb('RV-3'), test.rvt('2026-11-22 11:30')) || '/' || (test.rvr('RV-3')).status,
  'none/final/finished');
select test.eq('final: nothing more after it', coalesce(app.review_step(test.rvb('RV-3'), test.rvt('2026-11-30 12:00')), 'none') || '/'
  || test.rvev('renter_review_reminder', 'RV-3') || test.rvev('renter_review_final', 'RV-3'), 'none/11');
select test.mk_booking('RV-3L', 'rv_car', 'rv_maya', '2026-11-12 10:00', '2026-11-15 20:30', 'returned');
select test.eq('request: a check-in at 8:30 pm waits for 9 am the next day',
  coalesce(app.review_step(test.rvb('RV-3L'), test.rvt('2026-11-15 21:35')), 'none') || '/' || app.review_step(test.rvb('RV-3L'), test.rvt('2026-11-16 09:04')), 'none/ask');
select test.mk_booking('RV-3O', 'rv_car', 'rv_maya', '2026-08-01 10:00', '2026-08-03 10:00', 'closed');
select test.eq('request: too late 45 days after the return (stopped)', app.review_step(test.rvb('RV-3O'), test.rvt('2026-11-16 12:00')) || '/' || (test.rvr('RV-3O')).stop_reason, 'stopped:too_late/too_late');
select test.mk_booking('RV-OW', 'rv_car', 'rv_maya', '2026-11-12 10:00', '2026-11-13 10:00', 'returned', null, 'owner');
select test.eq('an Owner Booking gets nothing', coalesce(app.review_step(test.rvb('RV-OW'), test.rvt('2026-11-13 12:00')), 'none') || '/' || (select count(*) from review_requests where booking_id = test.rvb('RV-OW')), 'none/0');

-- ---------------------------------------------------------------- 4. the hold
select test.mk_booking('RV-4', 'rv_car', 'rv_maya', '2026-11-12 10:00', '2026-11-14 10:00', 'returned');
create table test.rv_line as select test.mk_line('RV-4', 'late_return_fee', 5000) id;
select test.mk_line('RV-4', 'toll_amount', 1200);
select test.eq('hold: a late return fee and a toll not on a statement: held, with both reasons',
  app.review_step(test.rvb('RV-4'), test.rvt('2026-11-14 12:00')) || '/' || (test.rvr('RV-4')).status || '/' || array_to_string((test.rvr('RV-4')).hold_reasons, ','), 'held/held/late,tolls');
select test.eq('hold: no review request while held', test.rvev('renter_review_ask', 'RV-4'), 0::bigint);
select test.eq('hold: the items say what is open', (select string_agg(x ->> 'reason' || ':' || (x ->> 'state'), ', ' order by x ->> 'reason') from jsonb_array_elements(app.review_hold_items(test.rvb('RV-4'))) x),
  'late:not on a statement yet, tolls:not on a statement yet');
select test.eq('hold: on the list (Admin, customer service)',
  (select string_agg(x ->> 'booking_number', ',') from jsonb_array_elements(app.door(test.id('rv_cs'), 'aal2', 'ops_read', 'review_overview', '{}') -> 'held') x where x ->> 'booking_number' like 'RV-%')
  || '/' || (app.door(test.id('rv_admin'), 'aal2', 'ops_read', 'review_overview', '{}') ->> 'on_hold'), 'RV-4/1');
-- the late fee is waived (0130 voids the line); the toll goes on a statement the deposit covered
update booking_line_items set voided_at = now(), voided_by = test.id('rv_admin'), void_reason = 'waived: test' where id = (select id from test.rv_line);
insert into booking_statements (id, booking_id, statement_number, kind, charges_cents, hst_cents, deposit_applied_cents, sent_at)
values (test.id('stmt:RV-4'), test.rvb('RV-4'), 'S-RV-4', 'later_charge', 1200, 0, 1200, now());
update booking_line_items set statement_id = test.id('stmt:RV-4') where booking_id = test.rvb('RV-4') and charge_type = 'toll_amount';
select test.eq('hold: released by itself once waived and settled (the deposit covered the toll), then the request goes',
  app.review_step(test.rvb('RV-4'), test.rvt('2026-11-16 10:00')) || '/' || (test.rvr('RV-4')).status || '/' || ((test.rvr('RV-4')).released_at is not null), 'ask/asked/true');
select test.mk_booking('RV-5', 'rv_car', 'rv_maya', '2026-11-12 10:00', '2026-11-14 10:00', 'returned');
select test.mk_line('RV-5', 'smoking', 30000);
insert into booking_statements (id, booking_id, statement_number, kind, charges_cents, hst_cents, deposit_applied_cents, sent_at)
values (test.id('stmt:RV-5'), test.rvb('RV-5'), 'S-RV-5', 'check_in', 30000, 3900, 10000, now());
update booking_line_items set statement_id = test.id('stmt:RV-5') where booking_id = test.rvb('RV-5') and charge_type = 'smoking';
select test.eq('hold: a smoking charge on a statement not paid (deposit short) holds', app.review_step(test.rvb('RV-5'), test.rvt('2026-11-14 12:00')) || '/' || array_to_string((test.rvr('RV-5')).hold_reasons, ','), 'held/smoking');
update booking_statements set paid_at = now() where id = test.id('stmt:RV-5');
select test.eq('hold: paid, released', app.review_step(test.rvb('RV-5'), test.rvt('2026-11-14 13:00')), 'ask');
select test.mk_booking('RV-6', 'rv_car', 'rv_maya', '2026-11-12 10:00', '2026-11-14 10:00', 'returned');
select test.mk_line('RV-6', 'cleaning', 15000);
select test.eq('hold: a cleaning charge holds', app.review_step(test.rvb('RV-6'), test.rvt('2026-11-14 12:00')), 'held');
select test.throws('Send anyway: not a renter''s or field staff''s call', $$select app.door(test.id('rv_maya'), 'aal1', 'ops_do', 'review_send_anyway', '{"booking":"RV-6"}')$$, 'Not permitted');
select test.eq('Send anyway: staff release it and the request goes now',
  (app.review_send_anyway(test.id('rv_cs'), test.rvb('RV-6'), test.rvt('2026-11-14 12:30')) ->> 'step') || '/' || ((test.rvr('RV-6')).send_anyway_by = test.id('rv_cs')), 'ask/true');
select test.eq('Send anyway: stays released while the charge is open', coalesce(app.review_step(test.rvb('RV-6'), test.rvt('2026-11-14 18:00')), 'none') <> 'held', true);
select test.mk_booking('RV-6H', 'rv_car', 'rv_maya', '2026-11-12 10:00', '2026-11-14 10:00', 'returned');
select test.mk_line('RV-6H', 'cleaning', 15000);
update program_settings set review_hold_incidentals = false;
select test.eq('hold off (setting): the request goes with a charge open', app.review_step(test.rvb('RV-6H'), test.rvt('2026-11-14 12:00')), 'ask');
update program_settings set review_hold_incidentals = true;

-- ---------------------------------------------------------------- 5. the stop
select test.mk_booking('RV-7', 'rv_car', 'rv_maya', '2026-11-12 10:00', '2026-11-14 10:00', 'closed');
select test.eq('stop: asked', app.review_step(test.rvb('RV-7'), test.rvt('2026-11-14 12:00')), 'ask');
insert into reviews (booking_id, renter_id, vehicle_id, rating, title) values (test.rvb('RV-7'), test.id('renter:rv_maya'), test.id('vehicle:rv_car'), 5, 'Great');
select test.eq('stop: an on-site review stops it at once, no reminder',
  (test.rvr('RV-7')).status || ':' || (test.rvr('RV-7')).stop_reason || '/' || coalesce(app.review_step(test.rvb('RV-7'), test.rvt('2026-11-15 12:00')), 'none'), 'stopped:onsite_review/none');
select test.mk_booking('RV-8', 'rv_car', 'rv_maya', '2026-11-12 10:00', '2026-11-14 10:00', 'returned');
select app.review_step(test.rvb('RV-8'), test.rvt('2026-11-14 12:00'));
select test.eq('the page by token: first name, car, length, handover; nothing else',
  (select x ->> 'first_name' || '/' || (x ->> 'vehicle' like '%Mercedes-Benz%') || '/' || (x ->> 'days') || '/' || (x ->> 'delivered') || '/' || (x ->> 'reviewed')
     || '/' || (x ? 'email') || (x ? 'mobile') from (select public.server_review_helper((test.rvr('RV-8')).token) x) q), 'Rv/true/2/false/false/falsefalse');
select test.eq('the page by token: a wrong token reads nothing', public.server_review_helper(gen_random_uuid()) ->> 'ok', 'false');
select public.server_review_helper_act((test.rvr('RV-8')).token, 'reviewed');
select test.eq('stop: "I already left a review" stops it', (test.rvr('RV-8')).stop_reason || '/' || coalesce(app.review_step(test.rvb('RV-8'), test.rvt('2026-11-15 12:00')), 'none'), 'renter_said_reviewed/none');
select test.throws('the page''s actions: only the known ones', $$select public.server_review_helper_act((select token from review_requests limit 1), 'publish')$$, 'Unknown action');
select test.mk_booking('RV-9', 'rv_car', 'rv_maya', '2026-11-12 10:00', '2026-11-14 10:00', 'returned');
select app.review_step(test.rvb('RV-9'), test.rvt('2026-11-14 12:00'));
select test.eq('stop: staff mark it reviewed (through the door)',
  (app.door(test.id('rv_fleet'), 'aal2', 'ops_do', 'review_mark_reviewed', '{"booking":"RV-9"}') ->> 'stopped') || '/' || (test.rvr('RV-9')).stop_reason, 'true/staff_marked_reviewed');
select test.mk_booking('RV-10', 'rv_car', 'rv_unsub', '2026-11-12 10:00', '2026-11-14 10:00', 'returned');
update users set marketing_unsubscribed_at = now() where id = test.id('rv_unsub');
select test.eq('stop: an unsubscribed renter is never asked', app.review_step(test.rvb('RV-10'), test.rvt('2026-11-14 12:00')) || '/' || test.rvev('renter_review_ask', 'RV-10'), 'stopped:unsubscribed/0');
select test.mk_booking('RV-11', 'rv_car', 'rv_guest', '2026-11-12 10:00', '2026-11-14 10:00', 'returned');
select test.eq('a renter without an account is asked (the address is not unsubscribed)', app.review_step(test.rvb('RV-11'), test.rvt('2026-11-14 12:00')), 'ask');

-- ---------------------------------------------------------------- 6. Google
select test.eq('Google: not connected, nothing to sync; the cron gate says no', (public.server_review_google_sync_begin() ->> 'connected') || '/' || (public.server_jobs_due() ->> 'reviews'), 'false/false');
select test.throws('Google: connect needs the vault (none on this database)', $$select app.door(test.id('rv_admin'), 'aal2', 'admin_do', 'review_google_connect', '{"refresh_token":"x"}')$$, 'vault');
select test.throws('Google: connect is for an Admin', $$select app.door(test.id('rv_cs'), 'aal2', 'admin_do', 'review_google_connect', '{"refresh_token":"x"}')$$, null);
select test.eq('Google: the settings read says so', (app.door(test.id('rv_admin'), 'aal2', 'admin_read', 'review_settings', '{}') #>> '{google,status}') || '/'
  || (app.door(test.id('rv_admin'), 'aal2', 'admin_read', 'review_settings', '{}') #>> '{google,vault}'), 'not_connected/false');
update review_google_link set status = 'connected';
select test.eq('Google: connected without the token in the vault: nothing to sync', public.server_review_google_sync_begin() ->> 'connected', 'false');
select test.eq('...and an error to connect again', (select status from review_google_link), 'error');
select test.mk_booking('RV-12', 'rv_car', 'rv_maya', '2026-11-12 10:00', '2026-11-14 10:00', 'returned');
select app.review_step(test.rvb('RV-12'), test.rvt('2026-11-14 12:00'));
select test.eq('Google: the job''s reviews and matches are recorded',
  app.review_google_sync_finish(jsonb_build_object('status', 'connected', 'location_name', 'locations/123', 'location_title', 'CarmaCars',
     'reviews', jsonb_build_array(
        jsonb_build_object('id', 'rv-g1', 'reviewer_name', 'Rv Maya', 'star_rating', 5, 'comment', 'Clean car', 'reviewed_at', '2026-11-15T15:00:00Z'),
        jsonb_build_object('id', 'rv-g2', 'reviewer_name', 'R.', 'star_rating', 4, 'comment', null, 'reviewed_at', '2026-11-15T16:00:00Z'),
        jsonb_build_object('id', 'rv-g3', 'reviewer_name', 'Somebody Else', 'star_rating', 2, 'reviewed_at', '2026-11-15T17:00:00Z')),
     'matches', jsonb_build_array(jsonb_build_object('id', 'rv-g1', 'booking_id', test.rvb('RV-12'), 'status', 'matched', 'score', 0.95),
                                  jsonb_build_object('id', 'rv-g2', 'booking_id', test.rvb('RV-11'), 'status', 'suggested', 'score', 0.6),
                                  jsonb_build_object('id', 'rv-g3', 'status', 'unmatched'))), test.rvt('2026-11-16 08:00')) ->> 'matched', '1');
select test.eq('...a clear match stops the requests; a suggestion waits for staff; no match stays unmatched',
  (test.rvr('RV-12')).stop_reason || '/' || (select string_agg(id || ':' || match_status, ',' order by id) from google_reviews where id like 'rv-g%'),
  'google_review/rv-g1:matched,rv-g2:suggested,rv-g3:unmatched');
select test.eq('Google: a suggested match waits for staff: the renter is still asked', coalesce((test.rvr('RV-11')).stop_reason, 'none'), 'none');
select test.throws('Google: fleet cannot match reviews', $$select app.door(test.id('rv_fleet'), 'aal2', 'ops_do', 'review_google_match', '{"id":"rv-g2","act":"confirm"}')$$, 'Customer service or an Admin');
select test.eq('Google: customer service confirms the suggestion; the requests stop',
  (app.door(test.id('rv_cs'), 'aal2', 'ops_do', 'review_google_match', '{"id":"rv-g2","act":"confirm"}') ->> 'match_status') || '/' || (test.rvr('RV-11')).stop_reason, 'confirmed/google_review');
select test.eq('Google: staff assign a review to a booking by its number',
  app.door(test.id('rv_admin'), 'aal2', 'ops_do', 'review_google_match', '{"id":"rv-g3","act":"assign","booking":"RV-5"}') ->> 'match_status', 'confirmed');
select app.review_google_sync_finish(jsonb_build_object('status', 'connected', 'reviews', '[]'::jsonb,
  'matches', jsonb_build_array(jsonb_build_object('id', 'rv-g2', 'status', 'unmatched'))), test.rvt('2026-11-16 14:00'));
select test.eq('Google: a later sync never undoes a staff decision', (select match_status from google_reviews where id = 'rv-g2'), 'confirmed');
select app.review_google_sync_finish('{"status":"api_not_approved","error":"403 the API is not enabled"}', test.rvt('2026-11-16 15:00'));
select test.eq('Google: the API not approved yet is shown, nothing else breaks', (select status || ':' || last_error from review_google_link), 'api_not_approved:403 the API is not enabled');
select test.eq('overview: Google reviews detected and their average rating; on-site reviews counted',
  (select (x #>> '{detected,google}') || '/' || (x #>> '{rating,google_avg}') || '/' || ((x #>> '{rating,onsite_n}')::integer >= 1)
     from (select app.review_overview(test.id('rv_admin'), 3650) x) q), '3/3.67/true');
update review_google_link set status = 'not_connected', last_error = null;

-- ---------------------------------------------------------------- 7. staff: the panel and Ask for a review
select test.mk_booking('RV-13', 'rv_car', 'rv_maya', '2026-11-12 10:00', '2026-11-14 10:00', 'returned');
select test.eq('panel: what comes next and the hold items', (app.door(test.id('rv_cs'), 'aal2', 'ops_read', 'review_request', '{"booking":"RV-13"}') ->> 'next')
  || '/' || jsonb_typeof(app.door(test.id('rv_cs'), 'aal2', 'ops_read', 'review_request', '{"booking":"RV-13"}') -> 'hold_items'), 'ask/array');
select test.throws('panel: not for a renter', $$select app.door(test.id('rv_maya'), 'aal1', 'ops_read', 'review_request', '{"booking":"RV-13"}')$$, 'Not permitted');
select test.eq('Ask for a review: sent now inside the hours, else at the next opening (and marked)',
  (select (x ->> 'sent')::boolean = app.review_in_window(now(), 9, 21) from (select app.review_ask_now(test.id('rv_cs'), test.rvb('RV-13')) x) q)
  and (test.rvr('RV-13')).manual_asks = 1, true);
select test.throws('Ask for a review: not twice in 24 hours', $$select app.review_ask_now(test.id('rv_cs'), test.rvb('RV-13'))$$, 'less than 24 hours');
select test.throws('Ask for a review: never after they reviewed', $$select app.review_ask_now(test.id('rv_cs'), test.rvb('RV-9'))$$, 'Already reviewed');
select test.throws('Ask for a review: never after an unsubscribe', $$select app.review_ask_now(test.id('rv_cs'), test.rvb('RV-10'))$$, 'unsubscribed');
select test.throws('Ask for a review: not an Owner Booking', $$select app.review_ask_now(test.id('rv_cs'), test.rvb('RV-OW'))$$, 'Owner Booking');
select test.eq('Ask for a review: in the booking''s history', (select count(*) from booking_events where booking_id = test.rvb('RV-13') and kind = 'review_request'), 1::bigint);

-- ---------------------------------------------------------------- 8. the earlier review emails, the job
select test.eq('while on: 0023''s and 0061''s review emails are not recorded (so not sent)',
  test.affected(format($$insert into marketing_sends (code, booking_id, renter_id) values ('renter_review_request', %L, %L)$$, test.rvb('RV-13'), test.id('renter:rv_maya')))
  + test.affected(format($$insert into marketing_sends (code, booking_id, renter_id) values ('renter_google_review_request', %L, %L)$$, test.rvb('RV-13'), test.id('renter:rv_maya'))), 0::bigint);
select test.eq('while on: no decision task for a problem booking (the hold list replaces it)', app.hold_review_request(test.rvb('RV-6')), false);
select test.mk_booking('RV-14', 'rv_car', 'rv_maya', '2026-11-20 10:00', '2026-11-23 10:00', 'on_rent');
select test.ok('the job runs every booking due and says what it sent', app.job_review_requests(test.rvt('2026-11-21 11:00')) like 'review requests: %checkin%');
update program_settings set review_program_enabled = false;
select test.eq('off: the job sends nothing; a step reads nothing', app.job_review_requests(test.rvt('2026-11-21 12:00')) || '/' || coalesce(app.review_step(test.rvb('RV-14'), test.rvt('2026-11-21 12:00')), 'none'), 'review requests are off/none');
update program_settings set review_program_enabled = true;
select test.eq('the texts: CarmaCars, the link, no long dash',
  (select count(*) from sms_templates where code in ('renter_trip_checkin', 'renter_review_ask', 'renter_review_reminder', 'renter_review_final') and app.sms_template_ok(body)), 4::bigint);
select test.eq('the catalogue: the four emails, the check-in a service message, the others marketing',
  (select string_agg(code || '=' || category, ',' order by code) from notification_catalogue where code in ('renter_trip_checkin', 'renter_review_ask', 'renter_review_reminder', 'renter_review_final')),
  'renter_review_ask=marketing,renter_review_final=marketing,renter_review_reminder=marketing,renter_trip_checkin=transactional');
set role anon;
select test.eq('anon: no privilege on the new tables', test.visible('select * from review_requests') + test.visible('select * from google_reviews') + test.visible('select * from review_google_link'), -3::bigint);
select test.throws('anon: cannot read the page by token (the server does)', $$select public.server_review_helper(gen_random_uuid())$$, null);
select test.throws('anon: cannot reach the door', $$select app.door(null, 'aal1', 'ops_read', 'review_overview', '{}')$$, null);
reset role;
set role authenticated;
select test.throws('a signed-in visitor cannot run the Google sync', $$select public.server_review_google_sync_begin()$$, null);
reset role;
update program_settings set review_program_enabled = false;
