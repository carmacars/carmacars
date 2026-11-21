-- 99: tracker events, their evidence and the pound database (migrations 3320 and 3321, release 48 part TRK).
-- Off by default (nothing changes); on: a speeding record per limit, once per window; harsh driving; tampering; driving at
-- night; the evidence record of every alert; the renter's notice (the charge and the clause), the owner's (no renter, no
-- booking), by email, in the app and by text, each in the preferences; a charge with its evidence in the registry and the
-- dispute kit; the pound lots, the flag on the booking, Fleet's To do and the recovery charge path; the signed ingest's
-- replay guard and rate. Fixtures start with "tv"; every address is example.test; device ids and lots are made up.
select test.suite('99 r48 TRK: tracker events');

select test.mk_user('tv_admin', 'admin');
select test.mk_user('tv_fleet', 'va', 'fleet');
select test.mk_user('tv_fin', 'va', 'finance');
select test.mk_user('tv_cs', 'va', 'cs');
select test.mk_owner('tv_owner');
select test.mk_owner('tv_other');
select test.mk_vehicle('tv_car1', 'tv_owner');
select test.mk_vehicle('tv_car2', 'tv_owner');
select test.mk_vehicle('tv_car3', 'tv_other');
select test.mk_renter('tv_rita');
select test.mk_renter('tv_sam');
create or replace function test.tvt(p interval) returns text language sql stable as $$
  select to_char((now() + p) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI') $$;
select test.mk_booking('TV-1', 'tv_car1', 'tv_rita', test.tvt('-3 days'), test.tvt('2 days'), 'on_rent');
select test.mk_booking('TV-2', 'tv_car2', 'tv_sam', test.tvt('-3 days'), test.tvt('2 days'), 'on_rent');
update bookings set handed_over_at = now() - interval '3 days' where id in (test.id('booking:TV-1'), test.id('booking:TV-2'));
create or replace function test.tvp(p_dev text, p_ago integer, p_lat numeric, p_lng numeric, p_speed numeric, p_ign boolean, p_extra jsonb default '{}')
returns jsonb language sql stable as $$
  select jsonb_build_object('device', p_dev, 'at', to_char((now() - make_interval(secs => p_ago)) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                            'lat', p_lat, 'lng', p_lng, 'speed', p_speed, 'ignition', p_ign, 'heading', 90) || p_extra $$;
create or replace function test.tvin(variadic p jsonb[]) returns jsonb language sql as $$ select public.server_tracker_ingest(jsonb_build_object('points', to_jsonb(p))) $$;
create or replace function test.tvdo(p_user text, p_name text, p jsonb default '{}') returns jsonb
language sql as $$ select app.door(test.id(p_user), 'aal2', 'ops_do', p_name, p) $$;
create or replace function test.tvread(p_user text, p_name text, p jsonb default '{}') returns jsonb
language sql as $$ select app.door(test.id(p_user), 'aal2', 'ops_read', p_name, p) $$;
select test.tvdo('tv_admin', 'tracker_pair', jsonb_build_object('vehicle_id', test.id('vehicle:tv_car1'), 'device', 'TVDEV-1', 'installed_on', (app.today() - 5)::text));
select test.tvdo('tv_admin', 'tracker_pair', jsonb_build_object('vehicle_id', test.id('vehicle:tv_car2'), 'device', 'TVDEV-2', 'installed_on', (app.today() - 5)::text));
select test.tvdo('tv_admin', 'tracker_pair', jsonb_build_object('vehicle_id', test.id('vehicle:tv_car3'), 'device', 'TVDEV-3', 'installed_on', (app.today() - 5)::text));
create or replace function test.tvn(p_vehicle text, p_kind text) returns bigint language sql stable as $$
  select count(*) from tracker_alerts where vehicle_id = test.id('vehicle:' || p_vehicle) and kind = p_kind $$;

-- ================================================================ 1. off by default: the alerts of 0400 only
select test.eq('Tracker events are off until an Admin turns them on', (select events_on from tracker_settings), false);
select test.tvin(test.tvp('TVDEV-1', 9000, 43.70, -79.40, 60, true), test.tvp('TVDEV-1', 8990, 43.70, -79.41, 190, true), test.tvp('TVDEV-1', 8980, 43.70, -79.42, 0, false, '{"event": "tamper"}'));
select test.eq('off: the speeding alert of 0400, no record per limit, no tampering alert, no evidence, no renter or owner notice',
  format('%s %s %s %s %s', (select count(*) from tracker_alerts where vehicle_id = test.id('vehicle:tv_car1') and kind = 'speeding' and tier is null),
    (select count(*) from tracker_alerts where vehicle_id = test.id('vehicle:tv_car1') and tier is not null), test.tvn('tv_car1', 'tamper'),
    (select count(*) from tracker_evidence where vehicle_id = test.id('vehicle:tv_car1')),
    (select count(*) from app_events where code in ('renter_tracker_notice', 'renter_driving_notice', 'owner_tracker_alert') and payload ->> 'vehicle_id' = test.id('vehicle:tv_car1')::text)),
  '1 0 0 0 0');

-- ================================================================ 2. the settings
select test.throws('fleet staff cannot change the tracker settings', $$select test.tvdo('tv_fleet', 'tracker_settings_save', '{"events_on": true}')$$, 'Only an Admin');
select test.throws('a window of 2 minutes is refused, in plain words', $$select test.tvdo('tv_admin', 'tracker_settings_save', '{"event_window_minutes": 2}')$$, 'the window 5 to 1440 minutes');
select test.eq('an Admin turns Tracker events on (pound_minutes 0 for these tests)',
  (select format('%s %s %s', v ->> 'events_on', v ->> 'event_window_minutes', v ->> 'pound_minutes') from (select test.tvdo('tv_admin', 'tracker_settings_save', '{"events_on": true, "pound_minutes": 0}') as v) x), 'true 30 0');
select test.eq('the speeding charges are the Program settings of 3102: $500, $1,000 and $2,500',
  (select format('%s %s %s', speeding_180_fee_cents, speeding_220_fee_cents, speeding_300_fee_cents) from app.settings()), '50000 100000 250000');
select test.eq('what an event means: the fee and the clause of a speeding record; a heads-up below 180; a breach outside Ontario',
  format('%s|%s|%s|%s', app.tracker_event_terms('speeding', 220) ->> 'fee_cents', app.tracker_event_terms('speeding', 220) ->> 'clause',
         app.tracker_event_terms('speeding') ->> 'renter', app.tracker_event_terms('left_ontario') ->> 'renter'), '100000|10.5 Speeding charges|heads_up|notice');

-- ================================================================ 3. speeding: one record per limit and window
select test.tvin(test.tvp('TVDEV-1', 7200, 43.70, -79.40, 100, true), test.tvp('TVDEV-1', 7170, 43.70, -79.41, 187, true), test.tvp('TVDEV-1', 7140, 43.70, -79.42, 192, true),
                 test.tvp('TVDEV-1', 7110, 43.70, -79.43, 185, true));
select test.eq('three readings over 180 km/h in a minute make one record, of the fastest reading',
  (select count(*) || ' ' || max(speed_kmh) || ' ' || max(source) from tracker_alerts where vehicle_id = test.id('vehicle:tv_car1') and tier = 180), '1 192 reading');
select test.eq('the renter is told once: the $500 charge over 180 km/h',
  (select count(*) || ' ' || bool_and(e.payload ->> 'event_fee' like 'A speeding charge of $500.00 plus HST applies (over 180 km/h).%')
     from app_events e where e.code = 'renter_tracker_notice' and e.payload ->> 'vehicle_id' = test.id('vehicle:tv_car1')::text), '1 true');
select test.tvin(test.tvp('TVDEV-1', 6900, 43.70, -79.44, 189, true));
select test.eq('another reading over 180 inside the window: still one record (never a flood)', (select count(*) from tracker_alerts where vehicle_id = test.id('vehicle:tv_car1') and tier = 180), 1::bigint);
select test.tvin(test.tvp('TVDEV-1', 6870, 43.70, -79.45, 226, true));
select test.eq('a higher limit inside the window raises the same record (never a second alert), and keeps what it was',
  (select count(*) || ' ' || max(tier) || ' ' || max(speed_kmh) || ' ' || max(facts ->> 'raised_from') || ' ' || max(facts ->> 'first_speed_kmh') from tracker_alerts where vehicle_id = test.id('vehicle:tv_car1') and tier is not null), '1 220 226 180 192');
select test.tvin(test.tvp('TVDEV-1', 6840, 43.70, -79.46, 190, true));
select test.eq('...and a lower one after it changes nothing', (select count(*) || ' ' || max(tier) from tracker_alerts where vehicle_id = test.id('vehicle:tv_car1') and tier is not null), '1 220');
select test.tvin(test.tvp('TVDEV-1', 4000, 43.70, -79.47, 184, true));
select test.eq('after the window (30 minutes) a new record', (select string_agg(tier::text, ',' order by at) from tracker_alerts where vehicle_id = test.id('vehicle:tv_car1') and tier is not null), '220,180');
select test.eq('the alert carries the fee and the clause',
  (select fee_code || '|' || clause || '|' || (booking_id = test.id('booking:TV-1')) from tracker_alerts where vehicle_id = test.id('vehicle:tv_car1') and tier = 220), 'speeding_220|10.5 Speeding charges|true');
select test.eq('a replayed batch changes nothing', (select (test.tvin(test.tvp('TVDEV-1', 7170, 43.70, -79.41, 187, true)) ->> 'accepted') || ' ' || (select count(*) from tracker_alerts where vehicle_id = test.id('vehicle:tv_car1') and tier is not null)), '0 2');

-- the evidence record
select test.eq('every alert has an evidence record: the map point, the speed, the time, the source, the fee, the clause and a seal',
  (select format('%s|%s|%s|%s|%s|%s|%s|%s', e.kind, e.tier, e.lat, e.lng, e.speed_kmh, e.source, e.fee_code, e.sha256 ~ '^[0-9a-f]{64}$' and e.device = 'TVDEV-1' and e.at = a.at and e.booking_id = a.booking_id)
     from tracker_evidence e join tracker_alerts a on a.id = e.alert_id where a.vehicle_id = test.id('vehicle:tv_car1') and a.tier = 220), 'speeding|220|43.70000|-79.45000|226|reading|speeding_220|t');
select test.eq('the record keeps the readings around the event (the history kept by the ingest)',
  (select jsonb_array_length(e.readings) >= 1 and e.sealed_at is not null from tracker_evidence e join tracker_alerts a on a.id = e.alert_id where a.vehicle_id = test.id('vehicle:tv_car1') and a.tier = 220), true);
select test.eq('the seal is the SHA-256 of the record: a changed reading no longer matches',
  (select e.sha256 = app.tracker_evidence_seal(e) and e.sha256 <> app.tracker_evidence_seal(jsonb_populate_record(e, '{"speed_kmh": 150}'::jsonb))
     from tracker_evidence e join tracker_alerts a on a.id = e.alert_id where a.vehicle_id = test.id('vehicle:tv_car1') and a.tier = 220), true);
select test.eq('the speeding alert level (0400) on the same reading does not double the record of the limit: no evidence, no notice of its own',
  (select count(*) from tracker_evidence e where e.vehicle_id = test.id('vehicle:tv_car1') and e.kind = 'speeding' and e.tier is null), 0::bigint);

-- ================================================================ 4. the notices: renter, owner, staff
select test.eq('the renter''s notice of the raised record says what happened, the new charge and the clause, and asks calmly',
  (select format('%s|%s|%s|%s|%s', e.payload ->> 'event_title', e.payload ->> 'event_what' like 'The Tracker in your % recorded 226 km/h on %',
                 e.payload ->> 'event_fee' like 'A speeding charge of $1,000.00 plus HST applies (over 220 km/h).%', e.payload ->> 'event_clause', e.payload ->> 'event_ask' like 'Please slow down.%')
     from app_events e join tracker_alerts a on e.dedupe_key = 'renter_tracker_notice:' || a.id || ':220' where a.vehicle_id = test.id('vehicle:tv_car1') and a.tier = 220),
  'Speeding over 220 km/h|t|t|Rental agreement: 10.5 Speeding charges.|t');
select test.eq('the owner''s alert names the car, the speed and the time, never the renter or the booking',
  (select format('%s|%s|%s', e.payload ->> 'event_what' like 'Your % was recorded at 226 km/h on %', e.payload ? 'booking_id' or e.payload ? 'renter_id' or e.payload ? 'booking_number' or e.payload ? 'event_fee',
                 e.payload ->> 'owner_id' = test.id('owner:tv_owner')::text)
     from app_events e join tracker_alerts a on e.dedupe_key = 'owner_tracker_alert:' || a.id || ':220' where a.vehicle_id = test.id('vehicle:tv_car1') and a.tier = 220), 't|f|t');
select test.eq('one notice per record and per raise to each: the record, its raise and the later record',
  (select count(*) filter (where code = 'renter_tracker_notice') || ' ' || count(*) filter (where code = 'owner_tracker_alert') from app_events
    where code in ('renter_tracker_notice', 'owner_tracker_alert') and payload ->> 'vehicle_id' = test.id('vehicle:tv_car1')::text), '3 3');
select app.process_events(100000);
select test.eq('the renter''s notice is queued as a branded email, the booking''s, never muted',
  (select format('%s|%s|%s', count(*), min(o.status), bool_and(o.booking_id = test.id('booking:TV-1')))
     from notification_outbox o where o.code = 'renter_tracker_notice' and o.renter_id = test.id('renter:tv_rita')), '3|queued|t');
select test.eq('every variable of the four templates is filled', (select count(*) from notification_outbox where code in ('renter_tracker_notice', 'renter_driving_notice', 'owner_tracker_alert', 'staff_pound_flag') and cardinality(missing_variables) > 0), 0::bigint);
select test.eq('...and shows in the renter''s portal (in-app, push topic alerts)',
  (select count(*) from notifications n where n.code = 'renter_tracker_notice' and n.user_id = (select user_id from renters where id = test.id('renter:tv_rita')))
    || ' ' || (select push_topic from notification_catalogue where code = 'renter_tracker_notice'), '3 alerts');
select test.eq('the owner''s alert is queued as a branded email to the car''s owner, with no booking on it',
  (select format('%s|%s|%s', count(*), min(o.status), bool_and(o.booking_id is null and o.renter_id is null))
     from notification_outbox o where o.code = 'owner_tracker_alert' and o.owner_id = test.id('owner:tv_owner')), '3|queued|t');
select test.eq('Admins and fleet staff got each record as an in-app notice (0400), customer service none',
  (select count(*) filter (where user_id = test.id('tv_admin')) || '/' || count(*) filter (where user_id = test.id('tv_fleet')) || '/' || count(*) filter (where user_id = test.id('tv_cs'))
     from notifications where code like 'staff_tracker_alert%' and title like 'Speeding over%' and created_at > now() - interval '1 hour'), '3/3/0');
select test.eq('each notice has its text, the same words; the charge notice is urgent',
  (select string_agg(code || ':' || urgent, ',' order by code) from sms_templates where code in ('renter_tracker_notice', 'renter_driving_notice', 'owner_tracker_alert')),
  'owner_tracker_alert:false,renter_driving_notice:false,renter_tracker_notice:true');
select test.eq('the text of a notice: what happened and the charge, with the link',
  (select app.sms_text_for('renter_tracker_notice', e.payload, 'renter', test.id('booking:TV-1')) ->> 'body' like 'CarmaCars: Speeding over 220 km/h. 226 km/h recorded. A $1,000.00 charge applies (agreement 10.5). Please slow down. Details: http%'
     from app_events e join tracker_alerts a on e.dedupe_key = 'renter_tracker_notice:' || a.id || ':220' where a.vehicle_id = test.id('vehicle:tv_car1') and a.tier = 220), true);
select test.eq('preferences: the owner''s alert and the renter''s heads-up can be muted; the charge notice is always sent',
  (select string_agg(code || ':' || user_can_mute, ',' order by code) from notification_catalogue where code in ('renter_tracker_notice', 'renter_driving_notice', 'owner_tracker_alert')),
  'owner_tracker_alert:true,renter_driving_notice:true,renter_tracker_notice:false');
insert into notification_preferences (user_id, code, email_enabled, in_app_enabled)
select o.user_id, 'owner_tracker_alert', false, false from owners o where o.id = test.id('owner:tv_owner');

-- a heads-up: over the alert level, under 180 (car 2, a new trip)
select test.tvin(test.tvp('TVDEV-2', 7200, 43.70, -79.40, 100, true), test.tvp('TVDEV-2', 7170, 43.70, -79.41, 152, true));
select test.eq('over the alert level and under 180: a heads-up with no charge ("Please slow down")',
  (select format('%s|%s|%s', e.code, e.payload ->> 'event_title', e.payload ->> 'event_fee' like 'No charge this time. Over 180 km/h there is a speeding charge of $500.00 plus HST%')
     from app_events e join tracker_alerts a on e.dedupe_key = 'renter_driving_notice:' || a.id where a.vehicle_id = test.id('vehicle:tv_car2') and a.kind = 'speeding'),
  'renter_driving_notice|Please slow down|t');
select app.process_events(100000);
select test.eq('an owner who muted the alert gets no email for the next event',
  (select string_agg(distinct o.status, ',') from notification_outbox o where o.code = 'owner_tracker_alert' and o.owner_id = test.id('owner:tv_owner') and o.payload ->> 'vehicle_id' = test.id('vehicle:tv_car2')::text) is distinct from 'queued', true);

-- ================================================================ 5. harsh driving, tampering, unplugged, night
select test.tvin(test.tvp('TVDEV-2', 6000, 43.71, -79.40, 60, true, '{"event": "harsh_brake"}'), test.tvp('TVDEV-2', 5940, 43.71, -79.41, 70, true, '{"event": "harsh_accel"}'));
select test.eq('two hard events: marked, no alert yet (3 in the window)', (select count(*) from tracker_harsh where vehicle_id = test.id('vehicle:tv_car2')) || ' ' || test.tvn('tv_car2', 'harsh_driving'), '2 0');
select test.tvin(test.tvp('TVDEV-2', 5880, 43.71, -79.42, 80, true), test.tvp('TVDEV-2', 5875, 43.71, -79.42, 5, true), test.tvp('TVDEV-2', 5800, 43.71, -79.43, 50, true, '{"event": "harsh_turn"}'));
select test.eq('the third (75 km/h lost in 5 seconds, worked out from the readings) makes one alert; a fourth in the window none',
  (select count(*) || ' ' || max(source) || ' ' || max(facts ->> 'count') from tracker_alerts where vehicle_id = test.id('vehicle:tv_car2') and kind = 'harsh_driving')
    || ' ' || (select count(*) from tracker_harsh where vehicle_id = test.id('vehicle:tv_car2')), '1 derived 3 4');
select test.eq('harsh driving: a heads-up to the renter with no charge, an alert to the owner',
  (select string_agg(e.code || ':' || (e.payload ->> 'event_title'), ',' order by e.code) from app_events e join tracker_alerts a on e.dedupe_key like '%:' || a.id
    where a.vehicle_id = test.id('vehicle:tv_car2') and a.kind = 'harsh_driving' and e.code in ('renter_driving_notice', 'owner_tracker_alert')),
  'owner_tracker_alert:Easy on the car, please,renter_driving_notice:Easy on the car, please');
select test.tvin(test.tvp('TVDEV-2', 5000, 43.71, -79.44, 0, false, '{"event": "tamper"}'), test.tvp('TVDEV-2', 4990, 43.71, -79.44, 0, false, '{"event": "tamper", "power": false}'));
select test.eq('the tracker reports tampering twice and loses power: one tampering alert, one unplugged alert, each with its record and the renter''s notice (10.4, 12.3)',
  format('%s %s %s %s', test.tvn('tv_car2', 'tamper'), test.tvn('tv_car2', 'unplugged'),
    (select count(*) from tracker_evidence where vehicle_id = test.id('vehicle:tv_car2') and kind in ('tamper', 'unplugged') and source in ('device_event', 'reading')),
    (select count(*) from app_events e join tracker_alerts a on e.dedupe_key = 'renter_tracker_notice:' || a.id where a.vehicle_id = test.id('vehicle:tv_car2') and a.kind in ('tamper', 'unplugged')
        and e.payload ->> 'event_clause' = 'Rental agreement: 10.4 Care; 12.3 Grounds (5); 12.4 Disabling.')), '1 1 2 2');
select test.eq('driving at night is off by default', test.tvn('tv_car2', 'after_hours'), 0::bigint);
update tracker_settings set night_on = true, night_from = ((now() - interval '70 minutes') at time zone 'America/Toronto')::time, night_to = ((now() + interval '60 minutes') at time zone 'America/Toronto')::time;
select test.tvin(test.tvp('TVDEV-2', 3600, 43.71, -79.45, 40, true), test.tvp('TVDEV-2', 3000, 43.71, -79.46, 45, true));
select test.eq('on: one alert per car and night, to staff and the owner, not to the renter (the agreement sets no curfew)',
  format('%s %s %s', test.tvn('tv_car2', 'after_hours'),
    (select count(*) from app_events e join tracker_alerts a on e.dedupe_key = 'owner_tracker_alert:' || a.id where a.vehicle_id = test.id('vehicle:tv_car2') and a.kind = 'after_hours'),
    (select count(*) from app_events e join tracker_alerts a on e.dedupe_key like 'renter_%:' || a.id where a.vehicle_id = test.id('vehicle:tv_car2') and a.kind = 'after_hours')), '1 1 0');
update tracker_settings set night_on = false;

-- ================================================================ 6. a charge with its evidence attached
create temp table tv_a as select a.id from tracker_alerts a where a.vehicle_id = test.id('vehicle:tv_car1') and a.tier = 220;
select test.throws('fleet staff do not add a speeding charge', format($$select test.tvdo('tv_fleet', 'tracker_alert_charge', '{"alert_id": "%s"}')$$, (select id from tv_a)), 'Admin or Finance');
select test.throws('an event with no set charge is not billed', format($$select test.tvdo('tv_admin', 'tracker_alert_charge', '{"alert_id": "%s"}')$$,
  (select id from tracker_alerts where vehicle_id = test.id('vehicle:tv_car2') and kind = 'harsh_driving')), 'no set charge');
create temp table tv_c as select test.tvdo('tv_fin', 'tracker_alert_charge', jsonb_build_object('alert_id', (select id from tv_a), 'note', 'Recorded on Highway 401')) as v;
select test.eq('Finance charges the record: the speeding charge of its limit ($1,000), with the evidence complete',
  (select format('%s %s %s', v ->> 'amount_cents', v ->> 'speed_kmh', v ->> 'evidence_status') from tv_c), '100000 226 ok');
select test.eq('the fee line names its evidence record, and the record its line',
  (select (li.supporting_refs ->> 'tracker_evidence_id') = e.id::text and e.line_item_id = li.id and a.line_item_id = li.id and li.charge_type = 'speeding_220'
     from tv_c c join booking_line_items li on li.id = (c.v ->> 'line_item_id')::uuid join tracker_evidence e on e.id = (c.v ->> 'evidence_id')::uuid join tracker_alerts a on a.id = e.alert_id), true);
select test.eq('the evidence registry (3190) finds the tracker''s record on the line: the event, the speed series and the map',
  (select format('%s|%s|%s', h -> 'tracker_event' ->> 'speed_kmh', h -> 'speed_series' ->> 'speed_kmh', h -> 'tracker_map' ? 'evidence_id')
     from (select app.fee_evidence_have((v ->> 'line_item_id')::uuid) as h from tv_c) x), '226|226|t');
select test.eq('...and the record is attached to the line as evidence', (select count(*) from fee_evidence fe join tv_c c on fe.line_item_id = (c.v ->> 'line_item_id')::uuid where fe.kind = 'tracker_event' and fe.note like 'Tracker evidence record %SHA-256%'), 1::bigint);
-- a charged record is never raised: a higher limit in its window is a record of its own
select test.eq('an Admin charges the later record over 180 km/h: $500',
  test.tvdo('tv_admin', 'tracker_alert_charge', jsonb_build_object('alert_id', (select id from tracker_alerts where vehicle_id = test.id('vehicle:tv_car1') and tier = 180))) ->> 'amount_cents', '50000');
select test.tvin(test.tvp('TVDEV-1', 3900, 43.70, -79.48, 231, true));
select test.eq('a charged record stays as it is: a higher limit in its window after the charge is a record of its own',
  (select string_agg(tier::text || ':' || (line_item_id is not null), ',' order by at) from tracker_alerts where vehicle_id = test.id('vehicle:tv_car1') and tier is not null), '220:true,180:true,220:false');
select test.throws('one event is one charge: the higher record of an event already charged is not billed on top',
  format($$select test.tvdo('tv_admin', 'tracker_alert_charge', '{"alert_id": "%s"}')$$, (select id from tracker_alerts where vehicle_id = test.id('vehicle:tv_car1') and tier = 220 and line_item_id is null)), 'one event is one charge');
select test.eq('the one-charge wording of 10.5 is published to accept (the terms pop-up), and the notices say it',
  (select count(*) || ' ' || bool_and(requires_acceptance and body like '%one event is one charge%') from terms_versions where doc_key = 'rental_agreement' and version = 'rental-v3-r48trk')
  || ' ' || (select bool_and(e.payload ->> 'event_fee' like '%One event is one charge, at the highest limit reached.%') from app_events e where e.code = 'renter_tracker_notice' and e.payload ->> 'event_title' like 'Speeding over%'
              and e.payload ->> 'vehicle_id' = test.id('vehicle:tv_car1')::text), '1 true true');
select test.throws('a record is charged once', format($$select test.tvdo('tv_admin', 'tracker_alert_charge', '{"alert_id": "%s"}')$$, (select id from tv_a)), 'already charged');
create temp table tv_pack as select app.dispute_pack_build_variant(test.id('tv_admin'), '{"booking": "TV-1", "variant": "small_claims"}'::jsonb) as v;
select test.eq('the dispute kit (3192) carries every tracker event of the booking with its record, seal, readings and the notice sent',
  (select format('%s|%s|%s|%s', jsonb_array_length(d -> 'tracker_events'), x ->> 'sha256' ~ '^[0-9a-f]{64}$', jsonb_array_length(x -> 'readings') >= 1, x -> 'notices' -> 0 ->> 'code')
     from (select public.server_dispute_evidence((select (v ->> 'id')::uuid from tv_pack)) as d) q,
          jsonb_array_elements(d -> 'tracker_events') x where x ->> 'tier' = '220' and x ->> 'line_item_id' is not null), '3|t|t|renter_tracker_notice');

-- ================================================================ 7. the pound database
select test.eq('the pound database starts with the lots the Toronto and Peel police publish, without pins and not yet checked',
  (select count(*) || ' ' || count(*) filter (where latitude is not null) || ' ' || count(*) filter (where checked_at is not null) || ' ' || count(*) filter (where phone is not null and source_url is not null) from pound_lots), '7 0 0 7');
select test.throws('fleet staff cannot change the pound lots', $$select test.tvdo('tv_fleet', 'pound_lot_save', '{"name": "Tv Example Pound", "address": "1 Example Road, Toronto, ON"}')$$, 'Only an Admin');
select test.throws('a pound lot needs its name and address', $$select test.tvdo('tv_admin', 'pound_lot_save', '{"name": "Tv Example Pound"}')$$, 'name and its address');
select test.throws('a pin outside Ontario is refused', $$select test.tvdo('tv_admin', 'pound_lot_save', '{"name": "Tv Example Pound", "address": "1 Example Road, Toronto, ON", "latitude": 10, "longitude": -79}')$$, 'a pin in Ontario');
create temp table tv_lot as select test.tvdo('tv_admin', 'pound_lot_save', '{"name": "Tv Example Pound", "address": "1 Example Road, Toronto, ON", "phone": "416-555-0100", "hours": "Open 24 hours", "latitude": 43.75, "longitude": -79.5, "checked": true}') as v;
select test.eq('an Admin adds a lot with its phone, hours and pin, and marks it checked', (select format('%s|%s|%s|%s', v ->> 'phone', v ->> 'hours', v ->> 'latitude', v ->> 'checked_at' is not null) from tv_lot), '416-555-0100|Open 24 hours|43.75000|t');
select test.throws('the same lot twice is refused', $$select test.tvdo('tv_admin', 'pound_lot_save', '{"name": "tv example pound", "address": "1 Example Road, Toronto, ON"}')$$, 'already in the list');
select test.eq('the website fills pins only where there is none', (select public.server_pound_lot_pins(jsonb_build_array(jsonb_build_object('id', (select v ->> 'id' from tv_lot), 'lat', 44, 'lng', -80),
  jsonb_build_object('id', (select id from pound_lots where name = 'Classic Towing'), 'lat', 43.6, 'lng', -79.5)))) || ' ' || (select latitude from pound_lots where name = 'Tv Example Pound'), '1 43.75000');
update pound_lots set latitude = null, longitude = null where name = 'Classic Towing';

-- car 1 drives, then parks 60 m from the lot
select test.tvin(test.tvp('TVDEV-1', 2400, 43.74, -79.49, 40, true), test.tvp('TVDEV-1', 1800, 43.7505, -79.5, 0, false));
select test.eq('parked at a known pound: one alert with the lot, its evidence record, and the flag on the booking',
  (select format('%s|%s|%s|%s|%s', a.kind, a.facts ->> 'lot_name', f.status, f.booking_id = test.id('booking:TV-1'), e.pound_lot_id = f.pound_lot_id)
     from pound_flags f join tracker_alerts a on a.id = f.alert_id join tracker_evidence e on e.id = f.evidence_id where f.vehicle_id = test.id('vehicle:tv_car1')), 'pound|Tv Example Pound|open|t|t');
select test.tvin(test.tvp('TVDEV-1', 1200, 43.7505, -79.5, 0, false), test.tvp('TVDEV-1', 600, 43.7506, -79.5001, 0, false));
select test.eq('still parked there: no second alert or flag', test.tvn('tv_car1', 'pound') || ' ' || (select count(*) from pound_flags where vehicle_id = test.id('vehicle:tv_car1')), '1 1');
select test.eq('Fleet gets an urgent To do on the booking with the lot''s phone and the fee path',
  (select format('%s|%s|%s|%s', t.queue, t.priority, t.booking_id = test.id('booking:TV-1'), t.detail like '%Phone 416-555-0100.%non-return charge ($1,000.00) or the theft recovery charge ($1,500.00)%')
     from tasks t where t.task_type = 'pound_recovery' and t.vehicle_id = test.id('vehicle:tv_car1')), 'fleet|urgent|t|t');
select test.eq('...the booking''s history says so', (select count(*) from booking_events where booking_id = test.id('booking:TV-1') and note like 'Flag: the tracker shows the car parked at a pound (Tv Example Pound%'), 1::bigint);
select test.eq('...the staff alert of 0400 (in-app and push, its own switch in Settings > Alerts) and the branded email to Fleet and Admins',
  (select count(*) from app_events where code = 'staff_tracker_alert_fleet' and payload ->> 'alert_kind' = 'pound' and entity_id = test.id('vehicle:tv_car1')) || ' ' ||
  (select count(*) from app_events where code = 'staff_pound_flag' and payload ->> 'lot_phone' = '416-555-0100' and payload ->> 'booking_line' = 'Booking TV-1')
  || ' ' || (select string_agg(rule, ',' order by rule) from staff_alert_rules where rule in ('tracker_pound', 'tracker_tamper', 'tracker_harsh', 'tracker_night') and wired and enabled),
  '1 1 tracker_harsh,tracker_night,tracker_pound,tracker_tamper');
select test.eq('the renter is told: at an impound lot, the costs and the clauses',
  (select format('%s|%s|%s', e.payload ->> 'event_title', e.payload ->> 'event_fee' like 'The towing, impound and storage costs are yours, at cost. The non-return charge ($1,000.00) or the theft recovery charge ($1,500.00)%',
                 e.payload ->> 'event_clause') from app_events e join tracker_alerts a on e.dedupe_key = 'renter_tracker_notice:' || a.id where a.vehicle_id = test.id('vehicle:tv_car1') and a.kind = 'pound'),
  'Your rental is at an impound lot|t|Rental agreement: 6 Tolls, tickets and fines; 10.6 Non-return; 10.8 Theft recovery.');
select app.process_events(100000);
select test.eq('the pound email is queued to fleet staff and Admins at once (urgent: not in the staff digest)',
  (select count(*) filter (where recipient_user_id = test.id('tv_fleet')) || '/' || count(*) filter (where recipient_user_id = test.id('tv_admin')) from notification_outbox where code = 'staff_pound_flag' and status = 'queued'), '1/1');

-- the path
create temp table tv_f as select id from pound_flags where vehicle_id = test.id('vehicle:tv_car1');
select test.throws('customer service does not resolve a pound flag', format($$select test.tvdo('tv_cs', 'pound_flag_resolve', '{"id": "%s", "path": "no_charge", "note": "Recovered"}')$$, (select id from tv_f)), 'Admin, Finance or Fleet');
select test.throws('the path needs a note', format($$select test.tvdo('tv_fleet', 'pound_flag_resolve', '{"id": "%s", "path": "non_return"}')$$, (select id from tv_f)), 'Say what happened');
create temp table tv_r as select test.tvdo('tv_fleet', 'pound_flag_resolve', jsonb_build_object('id', (select id from tv_f), 'path', 'non_return', 'note', 'Towed to the pound after the final notice',
  'cost_label', 'Tow and 2 days of storage', 'cost_cents', 42000)) as v;
select test.eq('Fleet records the non-return path: the non-return charge ($1,000) and the recovery cost, through the return charges of 3190',
  (select string_agg((x ->> 'fee') || ':' || (x ->> 'amount_cents'), ',' order by x ->> 'fee') from tv_r, jsonb_array_elements(v -> 'lines') x), 'non_return_fee:100000,recovery_cost:42000');
select test.eq('each line carries the tracker''s evidence record: the registry has the Tracker map, and still asks for the final notice and the receipt',
  (select string_agg(li.charge_type || ':' || li.evidence_status || ':' || array_to_string(li.evidence_missing, '+') || ':' || (app.fee_evidence_have(li.id) -> 'tracker_event' ->> 'kind'), ',' order by li.charge_type)
     from booking_line_items li where li.booking_id = test.id('booking:TV-1') and li.charge_type in ('non_return_fee', 'recovery_cost') and li.voided_at is null),
  'non_return_fee:needs_evidence:final_notice:pound,recovery_cost:needs_evidence:receipt:pound');
select test.eq('the flag is charged, its To do done, its alert seen',
  (select f.status || '|' || f.path || '|' || jsonb_array_length(f.lines) || '|' || (select t.status from tasks t where t.dedupe_key = 'pound_recovery:' || f.id) || '|' || (a.ack_at is not null)
     from pound_flags f join tracker_alerts a on a.id = f.alert_id where f.id = (select id from tv_f)), 'charged|non_return|2|done|true');
select test.throws('a flag is resolved once', format($$select test.tvdo('tv_admin', 'pound_flag_resolve', '{"id": "%s", "path": "no_charge", "note": "Recovered again"}')$$, (select id from tv_f)), 'already resolved');
select test.eq('a lot a flag names is switched off, not deleted; one with no flag is deleted',
  (select test.tvdo('tv_admin', 'pound_lot_save', jsonb_build_object('id', (select v ->> 'id' from tv_lot), 'remove', true)) ->> 'switched_off')
    || ' ' || (select test.tvdo('tv_admin', 'pound_lot_save', jsonb_build_object('id', (select id from pound_lots where name = 'J A Towing'), 'remove', true)) ->> 'removed'), 'true true');
select test.eq('...seven lots left, the one with a flag off', (select count(*) || ' ' || count(*) filter (where not is_active) from pound_lots), '7 1');
-- car 3 (no rental under way) parks at another lot: a flag with nobody to charge; the hourly job sees a car that stopped reporting there
select test.tvdo('tv_admin', 'pound_lot_save', '{"name": "Tv Second Pound", "address": "2 Example Road, Mississauga, ON", "latitude": 43.6, "longitude": -79.7, "radius_m": 300}');
update tracker_settings set pound_minutes = 30;
select test.tvin(test.tvp('TVDEV-3', 3000, 43.6010, -79.7, 0, false));
select test.eq('30 minutes are needed: just parked, no flag yet', (select count(*) from pound_flags where vehicle_id = test.id('vehicle:tv_car3')), 0::bigint);
update staff_alert_rules set enabled = false where rule = 'tracker_pound';
select test.eq('the hourly job flags it once the minutes have passed', app.job_tracker(now()) ->> 'pound_flags', '1');
select app.process_events(100000);
select test.eq('with the pound rule off in Settings > Alerts, the flag and its To do are made but staff get no notice or email for it',
  (select count(*) from pound_flags where vehicle_id = test.id('vehicle:tv_car3')) || ' ' || (select count(*) from tasks where task_type = 'pound_recovery' and vehicle_id = test.id('vehicle:tv_car3'))
  || ' ' || (select count(*) from notifications n where n.user_id in (test.id('tv_fleet'), test.id('tv_admin')) and n.code like 'staff_tracker_alert%' and n.title like 'At a pound:%Tv Second Pound')
  || ' ' || (select count(*) from notification_outbox o where o.code = 'staff_pound_flag' and o.recipient_user_id in (test.id('tv_fleet'), test.id('tv_admin')) and o.payload ->> 'lot_name' = 'Tv Second Pound'), '1 1 0 0');
update staff_alert_rules set enabled = true where rule = 'tracker_pound';
select test.eq('...a flag with no booking', (select count(*) from pound_flags where vehicle_id = test.id('vehicle:tv_car3') and booking_id is null), 1::bigint);
select test.throws('no rental under way: there is nobody to charge', format($$select test.tvdo('tv_fleet', 'pound_flag_resolve', '{"id": "%s", "path": "theft_recovery", "note": "Recovered by police"}')$$,
  (select id from pound_flags where vehicle_id = test.id('vehicle:tv_car3'))), 'nobody to charge');
select test.eq('...so Fleet records it recovered with no charge',
  test.tvdo('tv_fleet', 'pound_flag_resolve', jsonb_build_object('id', (select id from pound_flags where vehicle_id = test.id('vehicle:tv_car3')), 'path', 'no_charge', 'note', 'Our own drop-off for storage')) ->> 'path', 'no_charge');
select test.eq('...the flag is recovered', (select status from pound_flags where vehicle_id = test.id('vehicle:tv_car3')), 'recovered');
select test.tvin(test.tvp('TVDEV-3', 300, 43.65, -79.4, 30, true));
select test.eq('driving away clears the lot from the tracker''s state', (select ts.pound_lot_id is null from tracker_status ts join tracker_devices d on d.id = ts.tracker_device_id where d.serial_number = 'TVDEV-3'), true);

-- ================================================================ 7b. leaving the province, leaving the country (3326)
update users set phone = '+14165550191' where id = test.id('tv_admin');
select test.eq('in Canada, roughly: Toronto, Montreal, Winnipeg, Vancouver and Halifax in; Buffalo, Detroit, Seattle, Plattsburgh and Duluth out',
  format('%s %s %s %s %s | %s %s %s %s %s', app.tracker_in_canada(43.65, -79.38), app.tracker_in_canada(45.50, -73.57), app.tracker_in_canada(49.90, -97.14), app.tracker_in_canada(49.45, -123.1),
         app.tracker_in_canada(44.65, -63.57), app.tracker_in_canada(42.886, -78.878), app.tracker_in_canada(42.35, -83.10), app.tracker_in_canada(47.61, -122.33), app.tracker_in_canada(44.70, -73.45),
         app.tracker_in_canada(46.79, -92.10)), 't t t t t | f f f f f');
select test.tvin(test.tvp('TVDEV-2', 280, 45.50, -73.57, 60, true));
select test.eq('Montreal: left Ontario, still in Canada: the province alert only, with its evidence record',
  test.tvn('tv_car2', 'left_ontario') || ' ' || test.tvn('tv_car2', 'left_canada') || ' ' || (select count(*) from tracker_evidence where vehicle_id = test.id('vehicle:tv_car2') and kind = 'left_ontario'), '1 0 1');
select test.eq('...Admins and on-duty Fleet are told at once: the locked staff alert, the urgent email and a text; the owner and the renter (clause 10.1) too',
  (select format('%s %s %s %s %s', (select count(*) from app_events e where e.code = 'staff_alert_urgent' and e.payload ->> 'rule' = 'tracker_province' and e.entity_id = a.vehicle_id),
     (select count(*) from app_events e where e.dedupe_key = 'staff_border_alert:' || a.id and e.payload ->> 'border_title' = 'Left Ontario'),
     (select count(*) from phone_outbox o where o.dedupe_key like 'sms:staff_border:' || a.id || ':%' and o.to_number = '+14165550191' and o.body like 'CarmaCars: Left Ontario:%'),
     (select count(*) from app_events e where e.dedupe_key = 'owner_tracker_alert:' || a.id),
     (select e.payload ->> 'event_clause' from app_events e where e.dedupe_key = 'renter_tracker_notice:' || a.id))
     from tracker_alerts a where a.vehicle_id = test.id('vehicle:tv_car2') and a.kind = 'left_ontario'), '1 1 1 1 Rental agreement: 10.1 Area; 12.3 Grounds.');
select test.tvin(test.tvp('TVDEV-2', 200, 42.886, -78.878, 50, true), test.tvp('TVDEV-2', 190, 42.88, -78.87, 50, true));
select test.eq('Buffalo: left Canada, one alert for the crossing (not one per reading), with its evidence record and an urgent Fleet To do',
  (select format('%s %s %s %s', count(*), max(a.source), (select count(*) from tracker_evidence e where e.alert_id = max(a.id::text)::uuid and e.lat = 42.88000),
     (select t.queue || '/' || t.priority from tasks t where t.dedupe_key = 'left_canada:' || max(a.id::text)))
     from tracker_alerts a where a.vehicle_id = test.id('vehicle:tv_car2') and a.kind = 'left_canada'), '1 reading 1 fleet/urgent');
select test.eq('...the staff alert (locked), email and text; the owner''s alert; the renter''s notice says written approval is needed, with the clause',
  (select format('%s %s %s %s|%s|%s', (select count(*) from app_events e where e.code = 'staff_alert_urgent' and e.payload ->> 'rule' = 'tracker_canada' and e.entity_id = a.vehicle_id),
     (select count(*) from app_events e where e.dedupe_key = 'staff_border_alert:' || a.id and e.payload ->> 'border_title' = 'Left Canada'),
     (select count(*) from phone_outbox o where o.dedupe_key like 'sms:staff_border:' || a.id || ':%' and o.to_number = '+14165550191'),
     (select e.payload ->> 'event_what' like 'Your % left Canada on %' and not (e.payload ? 'booking_id') from app_events e where e.dedupe_key = 'owner_tracker_alert:' || a.id),
     (select e.payload ->> 'event_fee' from app_events e where e.dedupe_key = 'renter_tracker_notice:' || a.id),
     (select e.payload ->> 'event_clause' from app_events e where e.dedupe_key = 'renter_tracker_notice:' || a.id))
     from tracker_alerts a where a.vehicle_id = test.id('vehicle:tv_car2') and a.kind = 'left_canada'),
  '1 1 1 t|No set charge. Leaving Canada needs our written approval before you go: without it we may end the rental and recover the car, at your cost.|Rental agreement: 10.1 Area; 12.3 Grounds.');
select test.tvin(test.tvp('TVDEV-2', 150, 43.65, -79.38, 40, true));
select test.tvin(test.tvp('TVDEV-2', 100, 42.35, -83.10, 40, true));
select test.eq('back in Ontario, then Detroit: a new crossing is a new alert of each kind', test.tvn('tv_car2', 'left_ontario') || ' ' || test.tvn('tv_car2', 'left_canada'), '2 2');
select app.process_events(100000);
select test.eq('the border email goes to Fleet and Admins at once (at most three urgent emails an hour each, then the digest); 0400''s notice is not sent twice for a crossing; the rules are locked on; the owner''s alert stays the owner''s to mute',
  format('%s %s %s %s', (select count(*) filter (where o.status = 'queued' and o.status_reason = 'urgent') >= 2 and count(*) = 8 from notification_outbox o where o.code = 'staff_border_alert' and o.recipient_user_id in (test.id('tv_fleet'), test.id('tv_admin'))),
    (select count(*) from notifications n where n.code like 'staff_tracker_alert%' and n.user_id = test.id('tv_fleet') and (n.title like 'Left Canada:%' or n.title like 'Left Ontario:%tv_car2%')),
    (select bool_and(fixed and enabled and tier = 'urgent') from staff_alert_rules where rule in ('tracker_province', 'tracker_canada')),
    (select user_can_mute from notification_catalogue where code = 'owner_tracker_alert')), 't 0 t t');
select test.eq('10.1 says leaving Canada needs written approval, published to accept with the speeding wording',
  (select requires_acceptance and body like '%out of Canada always requires our written approval%' and summary like '%one speeding event is one charge%' from terms_versions where version = 'rental-v3-r48trk2'), true);
select test.tvin(test.tvp('TVDEV-2', 50, 43.65, -79.38, 40, true));

-- ================================================================ 8. what the screens read
select test.eq('Fleet tracking reads the events with their records, the flags, the lots, the fees and what this person may do',
  (select format('%s|%s|%s|%s|%s|%s', v ->> 'on', jsonb_array_length(v -> 'events') >= 8, jsonb_array_length(v -> 'flags'), jsonb_array_length(v -> 'lots'), v -> 'fees' ->> 'speeding_300', v -> 'can')
     from (select test.tvread('tv_fleet', 'tracker_events') as v) x), 'true|t|2|8|250000|{"charge": false, "manage": false, "resolve": true}');
select test.eq('the charged record shows its line; an uncharged speeding record can be charged',
  (select string_agg((x ->> 'tier') || ':' || (x ->> 'chargeable') || ':' || coalesce(x -> 'line' ->> 'amount_cents', 'none'), ',' order by x ->> 'tier', x ->> 'at')
     from jsonb_array_elements(test.tvread('tv_admin', 'tracker_events') -> 'events') x where x ->> 'kind' = 'speeding' and x ->> 'tier' is not null), '180:true:50000,220:true:100000,220:true:none');
select test.eq('customer service reads them, with nothing to do', (select test.tvread('tv_cs', 'tracker_events') -> 'can')::text, '{"charge": false, "manage": false, "resolve": false}');
select test.throws('an owner does not read the staff''s list', $$select app.door((select user_id from owners where id = test.id('owner:tv_owner')), 'aal2', 'ops_read', 'tracker_events')$$, 'CarmaCars staff');
select test.eq('an owner reads the events of their own cars: the event, the time and the place, never the renter or the booking',
  (select format('%s|%s|%s', jsonb_array_length(v -> 'events') >= 8, (select bool_and(not (x ? 'booking_number' or x ? 'booking_id' or x ? 'renter')) from jsonb_array_elements(v -> 'events') x),
                 (select count(*) from jsonb_array_elements(v -> 'events') x where x ->> 'vehicle_id' = test.id('vehicle:tv_car3')::text))
     from (select app.door((select user_id from owners where id = test.id('owner:tv_owner')), 'aal1', 'ops_read', 'owner_tracker_events') as v) q), 't|t|0');
select test.throws('another owner''s car is refused', format($$select app.door(%L, 'aal1', 'ops_read', 'owner_tracker_events', %L)$$,
  (select user_id from owners where id = test.id('owner:tv_other')), jsonb_build_object('vehicle', test.id('vehicle:tv_car1'))), 'Only the owner of this car');
select test.throws('a renter is refused', format($$select app.door(%L, 'aal1', 'ops_read', 'owner_tracker_events')$$, (select user_id from renters where id = test.id('renter:tv_rita'))), 'Only a car''s owner');

-- ================================================================ 9. the signed ingest: replay and rate
select test.eq('a signed request is taken once: the same signature again is refused as a replay',
  (select (public.server_tracker_ingest_signed(jsonb_build_object('points', jsonb_build_array(test.tvp('TVDEV-3', 200, 43.65, -79.41, 30, true))), repeat('a', 64), 1) ->> 'accepted')
    || ' ' || (public.server_tracker_ingest_signed(jsonb_build_object('points', jsonb_build_array(test.tvp('TVDEV-3', 190, 43.65, -79.42, 30, true))), repeat('a', 64), 1) ->> 'refused')), '1 replay');
select test.eq('...and its points are not stored', (select ts.longitude from tracker_status ts join tracker_devices d on d.id = ts.tracker_device_id where d.serial_number = 'TVDEV-3'), -79.41::numeric);
select test.eq('a signature that is not one is refused', public.server_tracker_ingest_signed('{"points": []}'::jsonb, 'nope', 1) ->> 'refused', 'signature');
update tracker_settings set ingest_per_minute = 10;
delete from app.rate_limit_hits where key = 'tracker_ingest';
select test.eq('more requests a minute than the setting allows are refused (the relay retries)',
  (select string_agg(coalesce(public.server_tracker_ingest_signed('{"points": []}'::jsonb, lpad(to_hex(g), 64, '0'), 1) ->> 'refused', 'ok'), ',' order by g) from generate_series(1, 12) g),
  'ok,ok,ok,ok,ok,ok,ok,ok,ok,ok,rate,rate');
update tracker_settings set ingest_per_minute = 240;
update app.tracker_ingest_seen set at = now() - interval '11 minutes';
select public.server_tracker_ingest_signed('{"points": []}'::jsonb, repeat('b', 64), 1);
select test.eq('old signatures are forgotten after 10 minutes', (select count(*) from app.tracker_ingest_seen), 1::bigint);

-- ================================================================ 10. privileges and retention
select test.eq('no browser role calls these functions or reads the replay table',
  (select bool_or(has_function_privilege(r, f, 'execute')) from unnest(array['anon', 'authenticated']) r,
     unnest(array['app.tracker_alert_charge(uuid, jsonb)', 'app.pound_flag_resolve(uuid, jsonb)', 'app.pound_lot_save(uuid, jsonb)', 'public.server_tracker_ingest_signed(jsonb, text, bigint)',
                  'public.server_pound_lot_pins(jsonb)', 'app.tracker_events(uuid, jsonb)', 'app.owner_tracker_events(uuid, jsonb)', 'app.tracker_ingest(jsonb)']) f)
    or has_table_privilege('authenticated', 'app.tracker_ingest_seen', 'select'), false);
select test.eq('the new tables have row level security, Admin and staff only',
  (select bool_and(c.relrowsecurity) and count(*) = 5 from pg_class c where c.oid in ('pound_lots'::regclass, 'tracker_evidence'::regclass, 'tracker_harsh'::regclass, 'pound_flags'::regclass, 'app.tracker_ingest_seen'::regclass))
  and not exists (select 1 from pg_policies where tablename in ('pound_lots', 'tracker_evidence', 'tracker_harsh', 'pound_flags') and (roles && array['anon', 'public']::name[])), true);
delete from tracker_alerts where kind = 'harsh_driving' and vehicle_id = test.id('vehicle:tv_car2');
select test.eq('the evidence record outlives its alert', (select count(*) from tracker_evidence e where e.kind = 'harsh_driving' and e.vehicle_id = test.id('vehicle:tv_car2') and e.alert_id is null), 1::bigint);
update tracker_harsh set at = now() - interval '200 days' where vehicle_id = test.id('vehicle:tv_car2');
select test.eq('the hourly job deletes old harsh driving marks with the history', (app.job_tracker(now()) ->> 'harsh_deleted')::int >= 4, true);
update tracker_settings set events_on = false, pound_minutes = 20;
-- nothing left for the next suite's event run
select app.process_events(100000);
