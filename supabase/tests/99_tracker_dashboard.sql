-- 99: Fleet tracking (migration 0400). The ingest (a batch of the generic JSON): unknown devices become in-stock devices,
-- the hot row moves once per device per batch, the history is thinned, trips close with the ignition, a replayed batch
-- changes nothing; the alerts (speeding, left Ontario, left the zone, still driving after the return time, low battery,
-- unplugged, offline), once each, with an in-app notice to Admins and fleet staff; pairing (the install date starts the
-- Tracker Fee), the read for Admins and fleet staff only, the settings, the ingest key, the hourly job and retention.
-- Fixtures start with "tk"; every address is example.test; device ids are made up.
select test.suite('99 tracker dashboard');

select test.mk_user('tk_admin', 'admin');
select test.mk_user('tk_fleet', 'va', 'fleet');
select test.mk_user('tk_cs', 'va', 'cs');
select test.mk_owner('tk_owner');
select test.mk_vehicle('tk_car1', 'tk_owner');
select test.mk_vehicle('tk_car2', 'tk_owner');
select test.mk_renter('tk_rita');
update vehicles set tracker_installed_on = null, tracker_install_pending = true where id in (test.id('vehicle:tk_car1'), test.id('vehicle:tk_car2'));
create or replace function test.tkt(p interval) returns text language sql stable as $$
  select to_char((now() + p) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI') $$;
-- rita has car 1 on rent; it was due back two hours ago (she is late)
select test.mk_booking('TK-1', 'tk_car1', 'tk_rita', test.tkt('-3 days'), test.tkt('-2 hours'), 'on_rent');
update bookings set handed_over_at = now() - interval '3 days' where id = test.id('booking:TK-1');

-- a point, as the generic JSON carries it (time: seconds before now)
create or replace function test.tkp(p_dev text, p_ago integer, p_lat numeric, p_lng numeric, p_speed numeric, p_ign boolean, p_extra jsonb default '{}')
returns jsonb language sql stable as $$
  select jsonb_build_object('device', p_dev, 'at', to_char((now() - make_interval(secs => p_ago)) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                            'lat', p_lat, 'lng', p_lng, 'speed', p_speed, 'ignition', p_ign, 'heading', 90) || p_extra $$;
create or replace function test.tkdo(p_user text, p_name text, p jsonb default '{}') returns jsonb
language sql as $$ select app.door(test.id(p_user), 'aal2', 'ops_do', p_name, p) $$;

-- ================================================================ 1. helpers
select test.eq('the time: ISO with Z, ISO with an offset, Unix seconds and milliseconds; no offset is refused',
  format('%s|%s|%s|%s|%s', app.tracker_time('"2026-11-01T12:00:00Z"') = '2026-11-01 12:00:00+00', app.tracker_time('"2026-11-01T08:00:00-04:00"') = '2026-11-01 12:00:00+00',
         app.tracker_time('1793534400') = to_timestamp(1793534400), app.tracker_time('1793534400000') = to_timestamp(1793534400),
         coalesce(app.tracker_time('"2026-11-01 12:00"')::text, 'null')), 't|t|t|t|null');
select test.eq('Ontario: Toronto, Ottawa, Windsor, Thunder Bay and Niagara Falls ON in; Buffalo, Detroit, Montreal, Gatineau north and Niagara Falls NY out',
  format('%s %s %s %s %s | %s %s %s %s %s', app.tracker_in_ontario(43.65, -79.38), app.tracker_in_ontario(45.42, -75.69), app.tracker_in_ontario(42.30, -83.00),
         app.tracker_in_ontario(48.38, -89.25), app.tracker_in_ontario(43.09, -79.08), app.tracker_in_ontario(42.886, -78.878), app.tracker_in_ontario(42.35, -83.10),
         app.tracker_in_ontario(45.50, -73.57), app.tracker_in_ontario(45.60, -75.75), app.tracker_in_ontario(43.09, -78.95)),
  't t t t t | f f f f f');
select test.ok('distance: Toronto to Mississauga is about 25 km', app.tracker_km(43.6532, -79.3832, 43.5890, -79.6441) between 21 and 23);

-- ================================================================ 2. the ingest key and the door's rules
select test.throws('only an Admin makes the ingest key', $$select test.tkdo('tk_fleet', 'tracker_key_new')$$, 'Only an Admin');
create temp table tk_key as select test.tkdo('tk_admin', 'tracker_key_new') as v;
select test.eq('the key is shown once, kept in the vault (stand-in here), and the website reads it back',
  (select (v ->> 'key') like 'trk_%' and length(v ->> 'key') = 68 and app.tracker_ingest_key() = (v ->> 'key')
          and (select ingest_key_hint from tracker_settings) = right(v ->> 'key', 4) from tk_key), true);
select test.throws('customer service cannot read Fleet tracking', format('select app.door(%L, %L, %L, %L)', test.id('tk_cs'), 'aal2', 'ops_read', 'tracker_fleet'), 'Admins and fleet staff');
select test.throws('an owner cannot read Fleet tracking', format('select app.door(%L, %L, %L, %L)', test.id('tk_owner'), 'aal2', 'ops_read', 'tracker_fleet'), 'Admins and fleet staff');

-- ================================================================ 3. an unknown device, then pairing
select test.eq('a device nobody paired: kept as an in-stock device with its hot row, no history',
  public.server_tracker_ingest(jsonb_build_object('points', jsonb_build_array(test.tkp('TKDEV-1', 3000, 43.65, -79.38, 0, false, '{"battery": 90, "power": true}'))))
    ->> 'new_devices', '1');
select test.eq('the unpaired device shows on the dashboard with its last report',
  (select count(*) from jsonb_array_elements(app.door(test.id('tk_fleet'), 'aal2', 'ops_read', 'tracker_fleet') -> 'unpaired') u where u ->> 'serial' = 'TKDEV-1'), 1::bigint);
select test.eq('no history for a device on no car', (select count(*) from tracker_points where vehicle_id = test.id('vehicle:tk_car1')), 0::bigint);
select test.throws('fleet staff cannot pair', $$select test.tkdo('tk_fleet', 'tracker_pair', jsonb_build_object('vehicle_id', test.id('vehicle:tk_car1'), 'device', 'TKDEV-1'))$$, 'Only an Admin');
select test.throws('an install date in the future is refused',
  $$select test.tkdo('tk_admin', 'tracker_pair', jsonb_build_object('vehicle_id', test.id('vehicle:tk_car1'), 'device', 'TKDEV-1', 'installed_on', (current_date + 3)::text))$$, 'future');
select test.tkdo('tk_admin', 'tracker_pair', jsonb_build_object('vehicle_id', test.id('vehicle:tk_car1'), 'device', 'TKDEV-1', 'installed_on', (app.today() - 2)::text));
select test.eq('paired: installed on the car, and the install date starts the Tracker Fee (0239)',
  (select d.status || '/' || (v.tracker_installed_on = app.today() - 2) || '/' || v.tracker_install_pending from tracker_devices d join vehicles v on v.id = d.vehicle_id where d.serial_number = 'TKDEV-1'),
  'installed/true/false');
select test.throws('a tracker on one car cannot be paired with another',
  $$select test.tkdo('tk_admin', 'tracker_pair', jsonb_build_object('vehicle_id', test.id('vehicle:tk_car2'), 'device', 'TKDEV-1'))$$, 'Remove it from that car first');
-- a replacement on car 2 later: the first device of car 2, then its replacement keeps the fee date
select test.tkdo('tk_admin', 'tracker_pair', jsonb_build_object('vehicle_id', test.id('vehicle:tk_car2'), 'device', 'TKDEV-2', 'installed_on', (app.today() - 10)::text));
select test.tkdo('tk_admin', 'tracker_pair', jsonb_build_object('vehicle_id', test.id('vehicle:tk_car2'), 'device', 'TKDEV-3', 'imei', '860000000000003'));
select test.eq('a replacement: the old tracker is removed, the car keeps its Tracker Fee date',
  (select string_agg(serial_number || ':' || status, ',' order by serial_number) from tracker_devices where serial_number in ('TKDEV-2', 'TKDEV-3'))
    || '/' || (select (tracker_installed_on = app.today() - 10)::text from vehicles where id = test.id('vehicle:tk_car2')), 'TKDEV-2:removed,TKDEV-3:installed/true');

-- ================================================================ 4. a drive: thinned history, one trip with its booking
-- car 1 drives east on the 401 at 60 km/h for 5 minutes, a point every 10 seconds (31 points), then parks
create temp table tk_drive as
  select jsonb_agg(test.tkp('TKDEV-1', 1000 - i * 10, 43.70, -79.60 + i * 0.002, case when i = 30 then 0 else 60 end, i < 30,
                            jsonb_build_object('odometer', 12000 + i * 0.165, 'battery', 88)) order by i) as pts
    from generate_series(0, 30) i;
create temp table tk_r1 as select public.server_tracker_ingest(jsonb_build_object('points', (select pts from tk_drive))) as v;
select test.eq('the batch: 31 accepted, one device', (select (v ->> 'accepted') || '/' || (v ->> 'devices') from tk_r1), '31/1');
select test.ok('the history is thinned: about one point a minute plus the ignition changes, not 31',
  (select count(*) from tracker_points where vehicle_id = test.id('vehicle:tk_car1')) between 5 and 9,
  (select count(*)::text from tracker_points where vehicle_id = test.id('vehicle:tk_car1')));
select test.eq('one trip, closed by the ignition, on rita''s booking, about 5 km at 60 km/h top speed',
  (select count(*) || '/' || min(closed_by) || '/' || bool_and(booking_id = test.id('booking:TK-1')) || '/' || (min(km) between 4.5 and 5.5) || '/' || max(max_speed_kmh)
     from tracker_trips where vehicle_id = test.id('vehicle:tk_car1')), '1/ignition/true/true/60');
select test.eq('the hot row: parked, ignition off, no trip under way, odometer and battery kept',
  (select ignition_on || '/' || speed_kmh || '/' || coalesce(trip_started_at::text, 'none') || '/' || odometer_km || '/' || battery_pct
     from tracker_status s join tracker_devices d on d.id = s.tracker_device_id where d.serial_number = 'TKDEV-1'), 'false/0.0/none/12005.0/88');
select test.eq('the same batch again (a replay or a retry) changes nothing',
  (select v ->> 'accepted' || '/' || (v ->> 'old') from (select public.server_tracker_ingest(jsonb_build_object('points', (select pts from tk_drive))) as v) x)
    || '/' || (select count(*) from tracker_trips where vehicle_id = test.id('vehicle:tk_car1')), '0/31/1');
select test.eq('junk is left out: a bad device id, no position, 0,0, and a time without its offset',
  (public.server_tracker_ingest(jsonb_build_object('points', jsonb_build_array(
     jsonb_build_object('device', 'x', 'at', '2026-11-01T12:00:00Z', 'lat', 43.6, 'lng', -79.4),
     jsonb_build_object('device', 'TKDEV-1', 'at', '2026-11-01T12:00:00Z'),
     jsonb_build_object('device', 'TKDEV-1', 'at', '2026-11-01T12:00:00Z', 'lat', 0, 'lng', 0),
     jsonb_build_object('device', 'TKDEV-1', 'at', '2026-11-01 12:00', 'lat', 43.6, 'lng', -79.4)))) ->> 'skipped'), '4');
select test.throws('a batch is a list of points', $$select public.server_tracker_ingest('{"points": {}}')$$, 'list');

-- ================================================================ 5. alerts
-- speeding twice in one trip: one alert
select public.server_tracker_ingest(jsonb_build_object('points', jsonb_build_array(
  test.tkp('TKDEV-1', 120, 43.71, -79.50, 80, true), test.tkp('TKDEV-1', 110, 43.71, -79.49, 152, true), test.tkp('TKDEV-1', 100, 43.71, -79.47, 161, true))));
select test.eq('speeding: one alert per trip, with the booking and the speed',
  (select count(*) || '/' || min(speed_kmh) || '/' || bool_and(booking_id = test.id('booking:TK-1')) from tracker_alerts where kind = 'speeding' and vehicle_id = test.id('vehicle:tk_car1')), '1/152/true');
-- out of Ontario (Buffalo), twice: one alert
select public.server_tracker_ingest(jsonb_build_object('points', jsonb_build_array(test.tkp('TKDEV-1', 90, 42.886, -78.878, 50, true))));
select public.server_tracker_ingest(jsonb_build_object('points', jsonb_build_array(test.tkp('TKDEV-1', 80, 42.887, -78.870, 50, true))));
select test.eq('left Ontario: one alert while it stays out', (select count(*) from tracker_alerts where kind = 'left_ontario' and vehicle_id = test.id('vehicle:tk_car1')), 1::bigint);
-- low battery and unplugged
select public.server_tracker_ingest(jsonb_build_object('points', jsonb_build_array(test.tkp('TKDEV-1', 70, 43.65, -79.38, 0, false, '{"battery": 12, "power": false}'))));
select test.eq('low tracker battery and unplugged: one alert each, and back in Ontario resets the flag',
  (select string_agg(kind, ',' order by kind) from tracker_alerts where vehicle_id = test.id('vehicle:tk_car1') and kind in ('battery_low', 'unplugged'))
    || '/' || (select outside_ontario from tracker_status s join tracker_devices d on d.id = s.tracker_device_id where d.serial_number = 'TKDEV-1'),
  'battery_low,unplugged/false');
-- the optional zone (a 30 km circle round downtown Toronto) and still driving after the return time
select test.tkdo('tk_admin', 'tracker_settings_save', '{"zone_name": "GTA core", "zone_lat": 43.65, "zone_lng": -79.38, "zone_radius_km": 30}');
select public.server_tracker_ingest(jsonb_build_object('points', jsonb_build_array(test.tkp('TKDEV-1', 60, 43.90, -78.85, 70, true))));
select public.server_tracker_ingest(jsonb_build_object('points', jsonb_build_array(test.tkp('TKDEV-1', 50, 43.91, -78.84, 72, true))));
select test.eq('left the zone (Oshawa is 45 km out) and still driving after the return time: one alert each',
  (select string_agg(kind || ':' || n, ',' order by kind) from (select kind, count(*) n from tracker_alerts where vehicle_id = test.id('vehicle:tk_car1')
     and kind in ('left_zone', 'overdue_driving') group by kind) x), 'left_zone:1,overdue_driving:1');
select test.ok('the zone alert names the zone', exists (select 1 from tracker_alerts where kind = 'left_zone' and title like 'Left GTA core:%'));
-- the notices: Admins and fleet staff, push topic alerts
select app.process_events(100000);
select test.eq('each alert reached the Admin and the fleet staff member as an in-app notice',
  (select count(*) filter (where user_id = test.id('tk_admin') and code = 'staff_tracker_alert') || '/'
          || count(*) filter (where user_id = test.id('tk_fleet') and code = 'staff_tracker_alert_fleet') || '/'
          || count(*) filter (where user_id = test.id('tk_cs'))
     from notifications where code like 'staff_tracker_alert%' and created_at > now() - interval '1 hour'),
  (select count(*) || '/' || count(*) || '/0' from tracker_alerts where vehicle_id = test.id('vehicle:tk_car1')));
select test.eq('the notices go by push under "alerts"', (select string_agg(push_topic, ',' order by code) from notification_catalogue where code like 'staff_tracker_alert%'), 'alerts,alerts');

-- ================================================================ 6. the read
create temp table tk_read as select app.door(test.id('tk_fleet'), 'aal2', 'ops_read', 'tracker_fleet') as v;
select test.eq('fleet staff read the car: its position, the renter and booking, the device',
  (select (c -> 'pos' ->> 'lat') || '/' || (c -> 'booking' ->> 'number') || '/' || (c -> 'booking' ->> 'renter') || '/' || (c -> 'device' ->> 'serial') || '/' || (c -> 'booking' ->> 'overdue')
     from tk_read, jsonb_array_elements(v -> 'cars') c where c ->> 'vehicle_id' = test.id('vehicle:tk_car1')::text),
  '43.91/TK-1/' || (select legal_name from renters where id = test.id('renter:tk_rita')) || '/TKDEV-1/true');
select test.eq('fleet staff do not see the ingest key''s ending; trips per booking are listed',
  (select coalesce(v -> 'settings' ->> 'key_hint', 'hidden') || '/' || ((select count(*) from jsonb_array_elements(v -> 'bookings') b where b ->> 'number' = 'TK-1') = 1) from tk_read), 'hidden/true');
select test.eq('acknowledge one alert (with a note)',
  test.tkdo('tk_fleet', 'tracker_alert_ack', jsonb_build_object('id', (select id from tracker_alerts where kind = 'speeding' and vehicle_id = test.id('vehicle:tk_car1')), 'note', 'Called the renter')) ->> 'acknowledged', '1');
select test.ok('then all at once', (test.tkdo('tk_admin', 'tracker_alert_ack', '{"all": true}') ->> 'acknowledged')::integer > 0);
select test.eq('nothing left open', (select count(*) from tracker_alerts where ack_at is null), 0::bigint);
select test.ok('a trip''s route for the map', jsonb_array_length(app.door(test.id('tk_admin'), 'aal2', 'ops_read', 'tracker_trip_path',
  jsonb_build_object('trip', (select id from tracker_trips where vehicle_id = test.id('vehicle:tk_car1') order by started_at limit 1))) -> 'path') >= 4);
select test.eq('Tracker seen on the cars list is the last report (the device row is not written on every report)',
  (select (x ->> 'tracker_seen')::timestamptz = (select s.reported_at from tracker_status s join tracker_devices d on d.id = s.tracker_device_id where d.serial_number = 'TKDEV-1')
     from jsonb_array_elements(app.door(test.id('tk_admin'), 'aal2', 'admin_read', 'vehicles')) x where x ->> 'id' = test.id('vehicle:tk_car1')::text), true);

-- ================================================================ 7. settings, demo mode
select test.throws('settings are checked', $$select test.tkdo('tk_admin', 'tracker_settings_save', '{"speed_alert_kmh": 20}')$$, 'Check the values');
select test.throws('history is kept at most 365 days (the privacy policy keeps Tracker data 12 months)', $$select test.tkdo('tk_admin', 'tracker_settings_save', '{"history_days": 400}')$$, 'Check the values');
select test.eq('demo mode is off by default', (select demo from tracker_settings), false);
select test.eq('turned on (and the zone cleared)', test.tkdo('tk_admin', 'tracker_settings_save', '{"demo": true, "zone_name": ""}') ->> 'demo', 'true');
select test.eq('the Live map knows; the zone is gone', (app.door(test.id('tk_admin'), 'aal2', 'admin_read', 'live_map') ->> 'tracker_demo') || '/' || coalesce((select zone_name from tracker_settings), 'no zone'), 'true/no zone');
select test.tkdo('tk_admin', 'tracker_settings_save', '{"demo": false}');

-- ================================================================ 8. the hourly job: quiet trips, offline, retention
-- car 2's tracker reports a trip start, then goes quiet for 7 hours
select public.server_tracker_ingest(jsonb_build_object('points', jsonb_build_array(
  test.tkp('TKDEV-3', 7 * 3600 + 120, 43.60, -79.70, 40, true, '{"odometer": 500}'), test.tkp('TKDEV-3', 7 * 3600, 43.62, -79.66, 45, true, '{"odometer": 503.2}'))));
insert into tracker_points (vehicle_id, at, lat_e6, lng_e6) values (test.id('vehicle:tk_car2'), now() - interval '200 days', 43600000, -79700000);
create temp table tk_job as select app.job_tracker() as v;
select test.eq('the job: the quiet trip is closed, the tracker is reported offline once, old history deleted',
  (select count(*) from tracker_trips where vehicle_id = test.id('vehicle:tk_car2') and closed_by = 'quiet')
    || '/' || (select count(*) from tracker_alerts where kind = 'offline' and vehicle_id = test.id('vehicle:tk_car2'))
    || '/' || (select count(*) from tracker_points where vehicle_id = test.id('vehicle:tk_car2') and at < now() - interval '100 days'), '1/1/0');
select app.job_tracker();
select test.eq('run again: no second offline alert', (select count(*) from tracker_alerts where kind = 'offline' and vehicle_id = test.id('vehicle:tk_car2')), 1::bigint);

-- ================================================================ 9. unpairing and privacy
select test.tkdo('tk_admin', 'tracker_unpair', jsonb_build_object('device_id', (select id from tracker_devices where serial_number = 'TKDEV-3')));
select test.eq('unpaired: the device is removed, the car''s position leaves the map',
  (select status from tracker_devices where serial_number = 'TKDEV-3') || '/' || (select count(*) from app.vehicle_positions where vehicle_id = test.id('vehicle:tk_car2')), 'removed/0');
select test.ok('the telemetry tables carry no row audit; the alerts and settings do',
  not exists (select 1 from pg_trigger where tgname in ('audit_tracker_points', 'audit_tracker_trips', 'audit_tracker_status'))
  and exists (select 1 from pg_trigger where tgname = 'audit_tracker_alerts') and exists (select 1 from pg_trigger where tgname = 'audit_tracker_settings'));
select test.ok('no browser role reaches the history, trips or alerts except Admins and fleet staff (policies)',
  (select count(*) from pg_policies where tablename in ('tracker_points', 'tracker_trips', 'tracker_alerts')) = 6
  and not exists (select 1 from pg_policies where tablename = 'tracker_status' and policyname = 'owner_read'));
