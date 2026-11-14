-- 99: release 47 part B (2895 to 2899): crash alerts that mean something, the photo standard on the connector, the staff
-- digests, insurer rentals with no known end date, a capture clash. Fixtures start with "r47b".
select test.suite('99 r47b alerts and digests');

select test.mk_user('r47b_admin', 'admin');
select test.mk_owner('r47b_o');
select test.mk_vehicle('R47BV', 'r47b_o');
select test.mk_renter('r47b_r');

-- ---------------------------------------------------------------- 2895: the kinds
select test.eq('kinds: network, transition, stale build, translation, foreign, crash',
  app.client_error_kind('Failed to fetch') || ',' || app.client_error_kind('network error') || ',' || app.client_error_kind('Load failed') || ','
  || app.client_error_kind('Transition was aborted because of invalid state. Viewport size changed') || ','
  || app.client_error_kind('Server Action "40ab" was not found on the server.') || ','
  || app.client_error_kind('Failed to execute ''removeChild'' on ''Node'': The node to be removed is not a child of this node.') || ','
  || app.client_error_kind('The object can not be found here.') || ','
  || app.client_error_kind('Script error.') || ','
  || app.client_error_kind('Maximum call stack size exceeded.', '') || ','
  || app.client_error_kind('Maximum call stack size exceeded.', 'RangeError\n at f (https://x/_next/static/chunks/1.js:1:2)') || ','
  || app.client_error_kind('Minified React error #441; visit https://react.dev/errors/441'),
  'network,network,network,transition,stale_build,translation,translation,foreign,foreign,crash,crash');
select test.eq('browsers in a few words',
  app.ua_browser('Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/30.0 Chrome/143.0.0.0 Mobile Safari/537.36') || '|'
  || app.ua_browser('Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.4 Mobile/15E148 Safari/604.1') || '|'
  || app.ua_browser('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/157.0.0.0 Safari/537.36 Edg/157.0.0.0') || '|'
  || app.ua_browser(null),
  'Samsung Internet 30 on Android|Safari 26 on iPhone|Edge 157 on Windows|unknown browser');

select public.server_client_error(jsonb_build_object('message', 'Failed to fetch', 'path', '/r47b/net'));
select test.ok('noise: kept with its kind, no To do',
  exists (select 1 from client_errors where path = '/r47b/net' and kind = 'network')
  and not exists (select 1 from tasks where title like 'Website crash on /r47b/net%'));
select test.eq('noise: the call says so', public.server_client_error(jsonb_build_object('message', 'Transition was aborted', 'path', '/r47b/net')), 'noise');

select public.server_client_error(jsonb_build_object('message', 'r47b TypeError: x is undefined', 'path', '/r47b/page', 'visitor', 'r47b-visitor-1', 'ua', 'Mozilla/5.0 (Windows NT 10.0) Chrome/157.0.0.0 Safari/537.36'));
select public.server_client_error(jsonb_build_object('message', 'r47b TypeError: x is undefined', 'path', '/r47b/page', 'visitor', 'r47b-visitor-1', 'ua', 'Mozilla/5.0 (Windows NT 10.0) Chrome/157.0.0.0 Safari/537.36'));
select test.eq('a crash: one To do, the count and one person, priority high',
  (select count(*) || '|' || min(priority) || '|' || (min(title) like 'Website crash on /r47b/page (2 times, 1 person): r47b TypeError%')::text
     || '|' || (min(detail) like '%Browsers: Chrome 157 on Windows.%')::text from tasks where task_type = 'site_alert' and title like 'Website crash on /r47b/page%'),
  '1|high|true|true');
select public.server_client_error(jsonb_build_object('message', 'r47b TypeError: x is undefined', 'path', '/r47b/page', 'visitor', 'r47b-visitor-2'));
select public.server_client_error(jsonb_build_object('message', 'r47b TypeError: x is undefined', 'path', '/r47b/page', 'visitor', 'r47b-visitor-3'));
select test.eq('three people the same day: urgent, still one To do',
  (select count(*) || '|' || min(priority) || '|' || (min(title) like '%(4 times, 3 people)%')::text from tasks where task_type = 'site_alert' and title like 'Website crash on /r47b/page%'),
  '1|urgent|true');
update tasks set status = 'done', completed_at = now() where task_type = 'site_alert' and title like 'Website crash on /r47b/page%';
select public.server_client_error(jsonb_build_object('message', 'r47b TypeError: x is undefined', 'path', '/r47b/page', 'visitor', 'r47b-visitor-4'));
select test.eq('a To do closed today stays closed (written again, not reopened)',
  (select count(*) || '|' || min(status) from tasks where task_type = 'site_alert' and title like 'Website crash on /r47b/page%'), '1|done');

-- ---------------------------------------------------------------- 2896: the photo standard
select test.ok('photo standard: the fleet, Gemini today and the totals',
  (select r ? 'gemini' and r -> 'gemini' ? 'used_today' and r -> 'gemini' ? 'daily_limit' and r -> 'totals' ? 'cover_sample' and jsonb_typeof(r -> 'cars') = 'array'
     from app.photo_standard_read(test.id('r47b_admin'), '{}'::jsonb) r));
select test.eq('photo standard: one car by its id, with the cover state and no photos',
  (select (r #>> '{cars,0,vehicle_id}') = test.id('vehicle:R47BV')::text and (r #>> '{cars,0,photos}')::int = 0 and r #>> '{cars,0,cover}' in ('none', 'sample', 'real')
     from app.photo_standard_read(test.id('r47b_admin'), jsonb_build_object('vehicle', test.id('vehicle:R47BV')::text)) r), true);
select test.throws('photo standard: an unknown car is not found',
  $$select app.photo_standard_read(test.id('r47b_admin'), '{"vehicle": "NO-SUCH-R47B"}'::jsonb)$$, 'No car matches');
select test.eq('photo standard: the connector answers it (a bad key is refused, not an unknown tool)',
  app.api_call(repeat('0', 64), 'photo_standard', '{}'::jsonb) ->> 'status', '401');

-- ---------------------------------------------------------------- 2897: the staff digests
select app.raise_task(p_type => 'first_day_admin', p_title => 'First day for r47b', p_queue => 'admin', p_dedupe => 'first_day_admin:' || gen_random_uuid());
select app.raise_task(p_type => 'verify_staff_payout', p_title => 'Verify new pay details: r47b', p_queue => 'admin', p_dedupe => 'verify_staff_payout:' || gen_random_uuid());
select test.ok('digests: no To do per hire or per payout any more',
  not exists (select 1 from tasks where title in ('First day for r47b', 'Verify new pay details: r47b')));
select test.lives('digests: written again without error', $$select app.staff_admin_digests_refresh()$$);

-- ---------------------------------------------------------------- 2898: an insurer rental with no known end date
create function test.r47b_t(p interval) returns text language sql stable as $$
  select to_char((now() + p) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI') $$;
select test.mk_booking('R47B-1', 'R47BV', 'r47b_r', test.r47b_t(- interval '2 days 23 hours'), test.r47b_t(- interval '1 hour'), 'on_rent');
update bookings set insurer_claim_number = 'R47B-CLAIM', notes = 'Insurance replacement, end date not known' where id = test.id('booking:R47B-1');
select test.ok('insurer open end: recognised', app.booking_insurer_open_end((select b from bookings b where b.id = test.id('booking:R47B-1'))));
select app.raise_task(p_type => 'late_return_admin', p_title => 'R47B-1 overdue', p_booking => test.id('booking:R47B-1'), p_dedupe => 'late_return_admin:' || test.id('booking:R47B-1'));
select test.ok('insurer open end: no overdue notice', app.ntf_emit('renter_late_return_first', 'booking', test.id('booking:R47B-1'), 'r47b', '{}'::jsonb) is null);
select test.eq('insurer open end: no late-return To do, one "extend or close" To do, still on rent',
  (select count(*) filter (where task_type in ('late_return', 'late_return_admin')) || '|' || count(*) filter (where task_type = 'insurer_end_reached' and status = 'open')
     from tasks where booking_id = test.id('booking:R47B-1')) || '|' || (select status::text from bookings where id = test.id('booking:R47B-1')),
  '0|1|on_rent');
update bookings set return_at = date_trunc('minute', now()) + interval '30 minutes' where id = test.id('booking:R47B-1');
select test.eq('insurer open end: a later end date closes the To do',
  (select count(*) from tasks where booking_id = test.id('booking:R47B-1') and task_type = 'insurer_end_reached' and status = 'open')::integer, 0);

-- ---------------------------------------------------------------- 2899: a capture clash
select test.eq('capture: nothing recorded as failed, nothing changed',
  public.server_booking_payment_captured(test.id('booking:R47B-1'), jsonb_build_object('payment_id', 'pi_r47b')), 0);
select test.ok('capture: only the server calls it',
  not has_function_privilege('authenticated', 'public.server_booking_payment_captured(uuid, jsonb)', 'execute'));

-- ---------------------------------------------------------------- 2896: Stripe for a booking, what the site recorded
select test.eq('stripe_booking: the site''s side of a booking (its payments, holds, pay links and Stripe ids)',
  (select (r ->> 'booking_number') || '|' || jsonb_typeof(r -> 'payments') || '|' || jsonb_typeof(r -> 'holds') || '|' || jsonb_typeof(r -> 'pay_links') || '|' || jsonb_typeof(r -> 'intents') from app.stripe_booking_recorded('R47B-1') r), 'R47B-1|array|array|array|array');
select test.throws('stripe_booking: an unknown booking', $$select app.stripe_booking_recorded('CC-NOPE-R47B')$$, 'No booking');
select test.eq('the Stripe tools are answered by the connector (a bad key is refused, not an unknown tool)',
  (app.api_call(repeat('0', 64), 'stripe_booking', '{"booking": "R47B-1"}'::jsonb) ->> 'status') || (app.api_call(repeat('0', 64), 'stripe_record_paid', '{}'::jsonb) ->> 'status'), '401401');
