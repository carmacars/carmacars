-- 3353 (release 48, integration of parts RW and TRK; docs/changes/2026-11-20-r48-tracker-alerts.md, "Owner alerts (3353)").
-- RW (3264) and TRK (3320, 3321, 3326) both built tracker events and the owner's tracker alert. TRK's pipeline is the base:
-- its signed, replay-protected, rate-limited ingest, the event table with the 30-minute window, the evidence records with
-- the SHA-256 seal, the pound lots and the province and country exit alerts. RW's extras are layered on it here, and
-- RW's own migration 3264 is gone (it would have applied before 3320):
--   1. tracker_alerts takes the kinds impact (a crash), health (a vehicle health warning), place (an auto shop or a
--      shipping port of tracker_places) and theft (moving with no booking, no Owner Booking and no staff job). A tracker
--      point may carry "event": "impact" | "health" with a "detail" (the ingest, web/src/integrations/tracker/ingest.ts);
--      each is an alert with its evidence record, once per car, kind and window, like 3320's tampering.
--   2. The owner's own alert set, per the owner (Nov 20, 13:02): in real time only an impound lot (3320's pound lots), an
--      auto shop or shipping port (tracker_places), possible theft (moving with no booking, far outside the zone with no
--      booking, out of Ontario, out of Canada), the tracker unplugged, offline or tampered with, a crash, a health
--      warning, and over 180 km/h. Each carries its notify type (3260) in the payload ("rule"): tracker_place,
--      tracker_theft, tracker_tamper, tracker_crash, tracker_health, tracker_speed. Harsh driving, night driving and late
--      returns are no longer an owner's real-time alert: harsh braking and acceleration, late-night trips and kilometres
--      against the allowance are in the weekly driving summary (tracker_weekly, off by default). app.tracker_event_notify
--      (3320, this release) is replaced: the renter's part is unchanged.
--   3. Per-kind owner preferences (3260): theft, tamper, crash and place on by default; health, speed and the summary off.
--      The speed alert's email, text and push are off by default; its notice stays in the portal (3270).
--   4. One owner_tracker_alert template (RW's copy, TRK's event variables: event_title, event_what, event_when,
--      event_map_url, vehicle_name). The words name the car, the time and the place, never the renter or the booking.
--   5. Everything waits for Tracker events (tracker_settings.events_on) and Owner notices (owner_notices), as 3320 does.
-- No applied migration is edited: app.tracker_events_scan, app.job_tracker and app.notify_type_live are wrapped or
-- replaced (all of this release). SCHEMA_MARKER 3353.
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

-- ================================================================ 1. the kinds, the watched places, the weekly summary
alter table tracker_alerts drop constraint if exists tracker_alerts_kind_check;
alter table tracker_alerts add constraint tracker_alerts_kind_check check (kind in ('speeding', 'left_ontario', 'left_zone', 'overdue_driving', 'battery_low', 'unplugged', 'offline',
  'harsh_driving', 'after_hours', 'tamper', 'pound', 'left_canada', 'impact', 'health', 'place', 'theft'));

create table tracker_places (
  id         uuid primary key default gen_random_uuid(),
  kind       text not null check (kind in ('auto_shop', 'port')),
  name       text not null check (length(name) between 2 and 120),
  latitude   numeric(8, 5) not null check (latitude between -90 and 90),
  longitude  numeric(8, 5) not null check (longitude between -180 and 180),
  radius_m   integer not null default 300 check (radius_m between 50 and 5000),
  is_active  boolean not null default true,
  note       text check (note is null or length(note) <= 300),
  created_by uuid references users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index tracker_places_created_by on tracker_places (created_by) where created_by is not null;
comment on table tracker_places is 'Tracker alerts (3353, from 3264): the auto shops and shipping ports watched. A car that stops inside a place''s radius raises a place alert for staff and its owner, once per car, place and day. Impound lots are the pound lots of 3320. An Admin keeps the list (Settings > Notification preferences).';
create table owner_tracker_weeklies (
  owner_id   uuid not null references owners (id) on delete cascade,
  week_of    date not null,
  sent       boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (owner_id, week_of)
);
comment on table owner_tracker_weeklies is 'Tracker alerts (3353, from 3264): the weeks an owner''s driving summary was handled (once an owner a week).';
do $$
declare t text;
begin
  foreach t in array array['tracker_places', 'owner_tracker_weeklies'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from public, anon, authenticated', t);
    execute format('grant all on %I to service_role', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
  end loop;
end $$;
create trigger tracker_places_updated before update on tracker_places for each row execute function app.set_updated_at();
create trigger audit_tracker_places after insert or update or delete on tracker_places for each row execute function app.audit_row();
create trigger audit_owner_tracker_weeklies after insert or update or delete on owner_tracker_weeklies for each row execute function app.audit_row();

-- the owner's tracker types follow Tracker events (Tracking settings), not a Program setting
create or replace function app.notify_type_live(t notify_types) returns boolean
language sql stable security definer set search_path = public, app as $$
  select t.live_setting is null
      or case when t.live_setting = 'tracker_events' then coalesce((app.tracker_settings()).events_on, false) and coalesce((app.tracker_settings()).owner_notices, false)
              else coalesce((to_jsonb(app.settings()) ->> t.live_setting)::boolean, false) end
$$;
update notify_types set live_setting = 'tracker_events' where code in ('tracker_theft', 'tracker_tamper', 'tracker_crash', 'tracker_place', 'tracker_health', 'tracker_speed', 'tracker_weekly');
update notify_types set detail = 'Moving with no active booking, far outside its area, or leaving Ontario or Canada.' where code = 'tracker_theft';
update notify_types set detail = 'The tracker was unplugged, lost power, stopped reporting or reported tampering.' where code = 'tracker_tamper';
update notify_types set detail = 'Your car stopped at an impound lot, an auto shop or a shipping port.' where code = 'tracker_place';
update notify_types set detail = 'Your car was driven over 180 km/h. The alert always shows on the car''s page.' where code = 'tracker_speed';

-- ================================================================ 2. the owner's words: the type, a title, what happened
-- null: not an owner's real-time alert (harsh driving, night driving, a late return, a speed under 180 km/h, a battery)
create function app.owner_tracker_words(a tracker_alerts) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  w jsonb := app.tracker_event_words(a);
  v_car text := coalesce(app.vehicle_name(a.vehicle_id), 'car');
  v_when text := app.fmt_at(a.at);
  v_type text; v_title text; v_what text;
begin
  case
    when a.kind = 'speeding' and (a.tier is not null or coalesce(a.speed_kmh, 0) > 180) then
      v_type := 'tracker_speed';
      v_title := format('Your %s was driven at %s km/h', v_car, a.speed_kmh);
      v_what := coalesce(w ->> 'event_owner', format('Your %s was recorded at %s km/h on %s.', v_car, a.speed_kmh, v_when))
                || ' That is over 180 km/h: the rental agreement charges for it.';
    when a.kind = 'theft' then
      v_type := 'tracker_theft';
      v_title := format('Possible theft: your %s', v_car);
      v_what := 'It is moving with no active booking. CarmaCars has the same alert and is acting on it now. We will call you.';
    when a.kind = 'left_zone' and a.booking_id is null then
      v_type := 'tracker_theft';
      v_title := format('Possible theft: your %s', v_car);
      v_what := 'It is far outside its area with no active booking. CarmaCars has the same alert and is acting on it now. We will call you.';
    when a.kind = 'left_ontario' then
      v_type := 'tracker_theft';
      v_title := format('Your %s has left Ontario', v_car);
      v_what := coalesce(w ->> 'event_owner', format('Your %s left Ontario on %s.', v_car, v_when)) || ' We will call you if it needs you.';
    when a.kind = 'left_canada' then
      v_type := 'tracker_theft';
      v_title := format('Your %s has left Canada', v_car);
      v_what := coalesce(w ->> 'event_owner', format('Your %s left Canada on %s.', v_car, v_when)) || ' We will call you if it needs you.';
    when a.kind in ('unplugged', 'tamper', 'offline') then
      v_type := 'tracker_tamper';
      v_title := format('Tracker alert: your %s''s tracker %s', v_car, case a.kind when 'unplugged' then 'lost power' when 'offline' then 'stopped reporting' else 'was tampered with' end);
      v_what := case when a.kind = 'offline' then format('The tracker in your %s stopped reporting on %s. CarmaCars has the same alert and is checking the car now.', v_car, v_when)
                     else coalesce(w ->> 'event_owner', format('The tracker in your %s may have been disconnected on %s.', v_car, v_when)) end;
    when a.kind = 'impact' then
      v_type := 'tracker_crash';
      v_title := format('Possible crash: your %s''s tracker felt an impact', v_car);
      v_what := format('The tracker felt an impact on %s. CarmaCars has the same alert and is checking on the car and the driver now. We will call you with what we find.', v_when);
    when a.kind = 'health' then
      v_type := 'tracker_health';
      v_title := format('Vehicle health warning: your %s', v_car);
      v_what := rtrim(coalesce(nullif(left(btrim(coalesce(a.facts ->> 'detail', '')), 200), ''), 'The tracker read a warning from the car'), '.') || '. CarmaCars will have it looked at.';
    when a.kind = 'pound' then
      v_type := 'tracker_place';
      v_title := format('Your %s is at an impound lot', v_car);
      v_what := coalesce(w ->> 'event_owner', format('Your %s is parked at an impound lot. CarmaCars Fleet is recovering it.', v_car));
    when a.kind = 'place' then
      v_type := 'tracker_place';
      v_title := format('Your %s stopped at %s', v_car, coalesce(a.facts ->> 'place_name', 'a watched place'));
      v_what := format('That is %s on our watch list. CarmaCars has the same alert and is checking why.', case a.facts ->> 'place_kind' when 'port' then 'a shipping port' else 'an auto shop' end);
    else
      return null;
  end case;
  return jsonb_build_object('type', v_type, 'title', left(v_title, 160), 'what', left(v_what, 400));
end $$;

-- ================================================================ 3. the notices of one alert (3320's, the owner's part replaced)
create or replace function app.tracker_event_notify(a tracker_alerts, p_suffix text default '') returns void
language plpgsql security definer set search_path = public, app as $$
declare
  s tracker_settings := app.tracker_settings();
  t jsonb := app.tracker_event_terms(a.kind, a.tier);
  w jsonb := app.tracker_event_words(a);
  ow jsonb;
  b bookings;
  o owners;
  v_code text;
  v_base jsonb := w || jsonb_build_object('alert_id', a.id, 'alert_kind', a.kind, 'vehicle_id', a.vehicle_id);
begin
  if s.renter_notices and a.booking_id is not null and t ->> 'renter' is not null then
    select * into b from bookings where id = a.booking_id;
    if b.status::text = 'on_rent' and b.booking_type::text <> 'owner' and not coalesce(b.is_placeholder, false) and b.renter_id is not null then
      v_code := case t ->> 'renter' when 'notice' then 'renter_tracker_notice' else 'renter_driving_notice' end;
      perform app.emit_event(v_code, 'booking', b.id, v_base || jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'renter_id', b.renter_id), v_code || ':' || a.id || p_suffix);
      update tracker_alerts set renter_notice_at = now() where id = a.id;
    end if;
  end if;
  -- the car's owner: the owner's own set (3353), the car, the time and the place, never the renter or the booking
  if not s.owner_notices then return; end if;
  ow := app.owner_tracker_words(a);
  if ow is null then return; end if;
  select x.* into o from vehicles v join owners x on x.id = v.owner_id where v.id = a.vehicle_id;
  if o.id is null then return; end if;
  perform app.emit_event('owner_tracker_alert', 'vehicle', a.vehicle_id, jsonb_strip_nulls(jsonb_build_object(
      'owner_id', o.id, 'vehicle_id', a.vehicle_id, 'alert_id', a.id, 'alert_kind', a.kind, 'rule', ow ->> 'type',
      'first_name', coalesce(nullif(btrim(o.first_name), ''), nullif(split_part(btrim(coalesce(o.legal_name, '')), ' ', 1), ''), 'there'),
      'vehicle_name', coalesce(app.vehicle_name(a.vehicle_id), 'your car'),
      'event_title', ow ->> 'title', 'event_what', ow ->> 'what', 'event_short', left(ow ->> 'what', 110),
      'event_when', w ->> 'event_when', 'event_map_url', w ->> 'event_map_url')),
    'owner_tracker_alert:' || a.id || p_suffix);
  update tracker_alerts set owner_notice_at = now() where id = a.id;
end $$;

-- ================================================================ 4. a crash and a health warning from the tracker
alter function app.tracker_events_scan(jsonb, tracker_settings) rename to tracker_events_scan_pre3353;
create function app.tracker_events_scan(p jsonb, s tracker_settings) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  n integer := app.tracker_events_scan_pre3353(p, s);
  pt record;
  v_now timestamptz := clock_timestamp();
  v_win interval := make_interval(mins => s.event_window_minutes);
  v_car text;
begin
  if jsonb_typeof(p -> 'points') is distinct from 'array' then return n; end if;
  for pt in
    select r.*, d.id as device_id, d.vehicle_id
      from (select nullif(btrim(x ->> 'device'), '') as dev, app.tracker_time(x -> 'at') as at, app.tracker_num(x ->> 'lat', -90, 90) as lat, app.tracker_num(x ->> 'lng', -180, 180) as lng,
                   app.tracker_num(x ->> 'speed', 0, 400) as speed,
                   case lower(btrim(coalesce(x ->> 'event', x ->> 'alarm', ''))) when 'impact' then 'impact' when 'crash' then 'impact' when 'collision' then 'impact' when 'health' then 'health' end as ev,
                   left(nullif(btrim(regexp_replace(coalesce(x ->> 'detail', ''), '[[:cntrl:]]+', ' ', 'g')), ''), 200) as detail
              from jsonb_array_elements(p -> 'points') x where jsonb_typeof(x) = 'object') r
      join lateral (select d.id, d.vehicle_id from tracker_devices d where (d.serial_number = r.dev or d.imei = r.dev) and d.status = 'installed' and d.vehicle_id is not null
                     order by (d.serial_number = r.dev) desc limit 1) d on true
      left join tracker_status ts on ts.tracker_device_id = d.id
     where r.ev is not null and r.dev ~ '^[A-Za-z0-9._:-]{3,64}$' and r.at is not null and r.lat is not null and r.lng is not null and not (r.lat = 0 and r.lng = 0)
       and r.at <= v_now + interval '10 minutes' and r.at > v_now - interval '7 days' and r.at > coalesce(ts.reported_at, '-infinity')
     order by d.id, r.at
  loop
    continue when exists (select 1 from tracker_alerts a where a.vehicle_id = pt.vehicle_id and a.kind = pt.ev and a.at between pt.at - v_win and pt.at + v_win);
    v_car := app.tracker_car_label(pt.vehicle_id);
    if app.tracker_event_raise(pt.ev, null, 'device_event', pt.device_id, pt.vehicle_id, pt.at, pt.lat, pt.lng, pt.speed,
         case pt.ev when 'impact' then format('Impact felt: %s', v_car) else format('Vehicle health warning: %s', v_car) end,
         coalesce(pt.detail, case pt.ev when 'impact' then 'The tracker felt an impact. Call the driver.' else 'The tracker read a warning from the car.' end)
           || format(' At %s.', app.fmt_at(pt.at)),
         pt.ev || ':' || pt.vehicle_id || ':' || extract(epoch from pt.at)::bigint,
         jsonb_strip_nulls(jsonb_build_object('event', pt.ev, 'detail', pt.detail))) is not null then
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
select pg_temp.copy_grants('app.tracker_events_scan(jsonb, tracker_settings)'::regprocedure, 'app.tracker_events_scan_pre3353(jsonb, tracker_settings)'::regprocedure);

-- ================================================================ 5. the watch: a watched place, moving with no booking (every 5 minutes)
create function app.job_owner_tracker(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s tracker_settings := app.tracker_settings();
  r record;
  pl tracker_places;
  v_place integer := 0; v_theft integer := 0;
  v_day text := to_char(app.local_date(p_now), 'YYYYMMDD');
  v_win interval := make_interval(mins => s.event_window_minutes);
begin
  if not s.events_on then return jsonb_build_object('live', false); end if;
  for r in
    select d.id as device_id, d.vehicle_id, st.latitude, st.longitude, st.speed_kmh, st.reported_at
      from tracker_devices d join tracker_status st on st.tracker_device_id = d.id
     where d.status = 'installed' and d.vehicle_id is not null and st.latitude is not null and st.reported_at > p_now - interval '20 minutes'
  loop
    -- stopped inside a watched auto shop or port
    if coalesce(r.speed_kmh, 0) < 5 then
      pl := null;
      select * into pl from tracker_places x where x.is_active and app.tracker_km(r.latitude, r.longitude, x.latitude, x.longitude) * 1000 <= x.radius_m
       order by app.tracker_km(r.latitude, r.longitude, x.latitude, x.longitude) limit 1;
      if pl.id is not null and app.tracker_event_raise('place', null, 'derived', r.device_id, r.vehicle_id, r.reported_at, r.latitude, r.longitude, r.speed_kmh,
           format('%s is at %s (%s)', app.tracker_car_label(r.vehicle_id), pl.name, case pl.kind when 'auto_shop' then 'auto shop' else 'shipping port' end),
           format('Stopped at %s since %s.', pl.name, app.fmt_at(r.reported_at)), 'place:' || r.vehicle_id || ':' || pl.id || ':' || v_day,
           jsonb_build_object('place_id', pl.id, 'place_name', pl.name, 'place_kind', pl.kind)) is not null then
        v_place := v_place + 1;
      end if;
    end if;
    -- moving with nobody meant to be driving: no rental out, no Owner Booking, no staff move or field job under way
    if coalesce(r.speed_kmh, 0) >= 20 and app.tracker_booking_at(r.vehicle_id, r.reported_at) is null
       and not exists (select 1 from bookings b where b.vehicle_id = r.vehicle_id and b.status::text in ('confirmed', 'on_rent') and b.pickup_at - interval '3 hours' <= r.reported_at and b.return_at + interval '6 hours' >= r.reported_at)
       and not exists (select 1 from field_jobs j where j.vehicle_id = r.vehicle_id and j.status in ('acknowledged', 'in_progress') and j.scheduled_at between r.reported_at - interval '12 hours' and r.reported_at + interval '12 hours')
       and not exists (select 1 from vehicle_moves m where m.vehicle_id = r.vehicle_id and m.created_at > r.reported_at - interval '6 hours')
       and not exists (select 1 from tracker_alerts a where a.vehicle_id = r.vehicle_id and a.kind = 'theft' and a.at between r.reported_at - v_win and r.reported_at + v_win) then
      if app.tracker_event_raise('theft', null, 'derived', r.device_id, r.vehicle_id, r.reported_at, r.latitude, r.longitude, r.speed_kmh,
           format('Moving with no booking: %s', app.tracker_car_label(r.vehicle_id)),
           format('Driving at %s km/h with no rental out, no Owner Booking and no staff job. Check now.', round(r.speed_kmh)), 'theft:' || r.vehicle_id || ':' || v_day,
           jsonb_build_object('speed_kmh', round(r.speed_kmh))) is not null then
        v_theft := v_theft + 1;
      end if;
    end if;
  end loop;
  return jsonb_build_object('live', true, 'place', v_place, 'theft', v_theft);
end $$;

-- ================================================================ 6. the weekly driving summary
create function app.owner_tracker_week(p_owner uuid, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  ts tracker_settings := app.tracker_settings();
  v_monday date := app.local_date(p_now) - (extract(isodow from (p_now at time zone 'America/Toronto'))::integer - 1);
  v_from timestamptz := app.local_midnight(v_monday - 7);
  v_to timestamptz := app.local_midnight(v_monday);
  v_cars jsonb;
  o owners;
begin
  select * into o from owners where id = p_owner;
  select jsonb_agg(c.obj order by c.name) into v_cars from (
    select app.vehicle_name(v.id) as name, jsonb_build_object(
      'car_name', app.vehicle_name(v.id),
      'km', app.fmt_km(coalesce(t.km, 0)),
      'allowance', case when coalesce(a.allowed, 0) > 0 then app.fmt_km(a.allowed) else 'No rental days' end,
      'over', case when coalesce(a.allowed, 0) > 0 and coalesce(t.km_booked, 0) > a.allowed then app.fmt_km(t.km_booked - a.allowed) || ' over' else 'Within the allowance' end,
      'speeding', (select count(*) from tracker_alerts x where x.vehicle_id = v.id and x.kind = 'speeding' and x.at >= v_from and x.at < v_to)::text,
      'over_limit', (select count(*) from tracker_alerts x where x.vehicle_id = v.id and x.kind = 'speeding' and (x.tier is not null or x.speed_kmh > 180) and x.at >= v_from and x.at < v_to)::text,
      'hard_braking', (select count(*) from tracker_harsh x where x.vehicle_id = v.id and x.kind = 'harsh_brake' and x.at >= v_from and x.at < v_to)::text,
      'hard_acceleration', (select count(*) from tracker_harsh x where x.vehicle_id = v.id and x.kind = 'harsh_accel' and x.at >= v_from and x.at < v_to)::text,
      'late_night', coalesce(t.night, 0)::text) as obj
      from vehicles v
      left join lateral (select sum(tt.km) as km, sum(tt.km) filter (where tt.booking_id is not null) as km_booked,
                                count(*) filter (where case when ts.night_from <= ts.night_to
                                    then (tt.started_at at time zone 'America/Toronto')::time >= ts.night_from and (tt.started_at at time zone 'America/Toronto')::time < ts.night_to
                                    else (tt.started_at at time zone 'America/Toronto')::time >= ts.night_from or (tt.started_at at time zone 'America/Toronto')::time < ts.night_to end) as night
                           from tracker_trips tt where tt.vehicle_id = v.id and tt.started_at >= v_from and tt.started_at < v_to) t on true
      left join lateral (select sum(coalesce(b.km_allowance_per_day, 0) * greatest(ceil(extract(epoch from least(b.return_at, v_to) - greatest(b.pickup_at, v_from)) / 86400.0), 0))::numeric as allowed
                           from bookings b where b.vehicle_id = v.id and b.status::text in ('on_rent', 'returned', 'closed') and b.pickup_at < v_to and b.return_at > v_from) a on true
     where v.owner_id = p_owner and v.retired_at is null
       and exists (select 1 from tracker_devices d where d.vehicle_id = v.id and d.status = 'installed')
       and coalesce(t.km, 0) > 0) c;
  if v_cars is null then return null; end if;
  return jsonb_build_object('owner_id', p_owner, 'first_name', coalesce(nullif(btrim(o.first_name), ''), nullif(split_part(btrim(coalesce(o.legal_name, '')), ' ', 1), ''), 'there'),
    'week_label', app.fmt_day(v_monday - 7) || ' to ' || app.fmt_day(v_monday - 1), 'speed_limit', '180', 'cars', v_cars);
end $$;

create function app.job_owner_tracker_weekly(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  s tracker_settings := app.tracker_settings();
  v_local timestamp := p_now at time zone 'America/Toronto';
  v_monday date := v_local::date - (extract(isodow from v_local)::integer - 1);
  o record;
  pl jsonb;
  f record;
  n integer := 0;
begin
  if not (s.events_on and s.owner_notices) then return 0; end if;
  if extract(isodow from v_local) <> 1 or extract(hour from v_local) < 9 then return 0; end if;
  for o in select ow.id, ow.user_id from owners ow
            where ow.kind = 'program' and ow.status::text = 'active' and ow.user_id is not null
              and not exists (select 1 from owner_tracker_weeklies w where w.owner_id = ow.id and w.week_of = v_monday)
  loop
    begin
      -- only for an owner who switched the summary on (off by default)
      select * into f from app.notify_pref_of('user', o.user_id, 'tracker_weekly');
      pl := case when f.email or f.push then app.owner_tracker_week(o.id, p_now) end;
      if pl is not null then perform app.emit_event('owner_tracker_weekly', 'owner', o.id, pl, 'owner_tracker_weekly:' || o.id || ':' || v_monday); n := n + 1; end if;
      insert into owner_tracker_weeklies (owner_id, week_of, sent) values (o.id, v_monday, pl is not null) on conflict do nothing;
    exception when others then
      raise warning 'owner driving summary %: %', o.id, sqlerrm;
    end;
  end loop;
  return n;
end $$;

-- ================================================================ 7. the watched places (Admin, Settings > Notification preferences)
-- tracker_place_save {id?, kind, name, latitude, longitude, radius_m, is_active, note} | tracker_place_remove {id}
create function app.tracker_places_do(p_by uuid, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_id uuid := nullif(p ->> 'id', '')::uuid;
begin
  if not app.user_is_admin(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  perform app.rw_act_as(p_by);
  if p_name = 'tracker_place_remove' then
    delete from tracker_places where id = v_id;
    return jsonb_build_object('ok', true);
  end if;
  if p ->> 'kind' = 'impound' then
    raise exception 'Impound lots are the Pound lots of Cars > Fleet tracking: add it there' using errcode = '22023';
  end if;
  if coalesce(p ->> 'kind', '') not in ('auto_shop', 'port') or nullif(btrim(coalesce(p ->> 'name', '')), '') is null
     or (p ->> 'latitude') is null or (p ->> 'longitude') is null then
    raise exception 'Enter the kind of place (an auto shop or a shipping port), its name and where it is (latitude and longitude)' using errcode = '22023';
  end if;
  if v_id is null then
    insert into tracker_places (kind, name, latitude, longitude, radius_m, is_active, note, created_by)
    values (p ->> 'kind', left(btrim(p ->> 'name'), 120), (p ->> 'latitude')::numeric, (p ->> 'longitude')::numeric, coalesce((p ->> 'radius_m')::integer, 300),
            coalesce((p ->> 'is_active')::boolean, true), left(nullif(btrim(coalesce(p ->> 'note', '')), ''), 300), p_by);
  else
    update tracker_places set kind = p ->> 'kind', name = left(btrim(p ->> 'name'), 120), latitude = (p ->> 'latitude')::numeric, longitude = (p ->> 'longitude')::numeric,
           radius_m = coalesce((p ->> 'radius_m')::integer, radius_m), is_active = coalesce((p ->> 'is_active')::boolean, is_active), note = left(nullif(btrim(coalesce(p ->> 'note', '')), ''), 300)
     where id = v_id;
  end if;
  return jsonb_build_object('ok', true);
end $$;
create function app.tracker_places_read(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare s tracker_settings := app.tracker_settings();
begin
  if not app.user_is_admin(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  return jsonb_build_object('live', s.events_on and s.owner_notices, 'events_on', s.events_on, 'owner_notices', s.owner_notices,
    'trackers_available', coalesce((app.settings()).trackers_available, false), 'speed_kmh', 180,
    'pound_lots', (select count(*) from pound_lots where is_active),
    'places', (select coalesce(jsonb_agg(to_jsonb(x) order by x.kind, x.name), '[]'::jsonb) from (select id, kind, name, latitude, longitude, radius_m, is_active, note from tracker_places) x),
    'sent_30d', (select count(*) from notification_outbox where code = 'owner_tracker_alert' and created_at > now() - interval '30 days'));
end $$;

-- ================================================================ 8. the catalogue: the weekly summary's switch; the alert's text is urgent
-- (the rows are 3321's owner_tracker_alert and 3269's owner_tracker_weekly, generated from emails/catalogue.json)
update notification_catalogue set pref_type = 'tracker_weekly', no_text = true, priority = 4, emitted_by = 'app.job_owner_tracker_weekly (3353): Monday, for an owner who switched it on'
 where code = 'owner_tracker_weekly';
update notification_catalogue set pref_type = null, emitted_by = 'app.tracker_event_notify (3320, 3353): an event of the owner''s set on the owner''s car (the type is the payload''s rule)'
 where code = 'owner_tracker_alert';
-- a theft, crash or tamper text goes at once, at night too (the owner chooses the text channel per type)
update sms_templates set urgent = true where code = 'owner_tracker_alert';

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('carmacars-owner-tracker', '*/5 * * * *', $q$select app.job_owner_tracker()$q$);
    perform cron.schedule('carmacars-owner-tracker-weekly', '*/15 * * * *', $q$select app.job_owner_tracker_weekly()$q$);
  end if;
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('app', 'public') and (p.proname ~ '^(owner_tracker_|job_owner_tracker|tracker_places_)' or p.proname in ('tracker_event_notify', 'tracker_events_scan_pre3353'))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
