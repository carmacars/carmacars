-- 3264_r48rw_owner_tracker_alerts.sql
-- Release 48, part RW: owners get tracker alerts (docs/changes/2026-11-20-r48-rewards-calendar-notify.md). The owner,
-- Nov 20 13:02: "owners should get tracker alerts too (live once the trackers are installed)".
--   Real time, to the car's owner: the car at an impound lot, an auto shop or a shipping port; possible theft (out of
--   Ontario, far outside its zone, or moving with no active booking); the tracker disconnected or tampered with; a crash or
--   impact; a vehicle health warning; over 180 km/h.
--   Weekly (not real time): driving behaviour (speeding, hard braking and acceleration, late-night driving) and the
--   kilometres driven against the allowance.
--   Each is its own switch in the owner's notification preferences (3260: tracker_theft, tracker_tamper, tracker_crash,
--   tracker_place on by default; tracker_health, tracker_speed, tracker_weekly off). Nothing is sent until
--   trackers_available is on in Program settings (the trackers are not in hand yet).
--   An owner is told about their car only: never who rented it, the booking or the renter's details. The words are
--   written here, not copied from the staff alert.
-- New for it: tracker_alerts takes the kinds impact, tamper, health, place and theft; a tracker (or its relay) may send
-- an "event" with a point (impact, tamper, health, harsh_brake, harsh_accel); tracker_places are the places watched.
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

alter table program_settings
  add column if not exists tracker_owner_alerts_enabled boolean not null default true,
  add column if not exists tracker_owner_speed_kmh integer not null default 180 check (tracker_owner_speed_kmh between 100 and 400),
  add column if not exists tracker_owner_night_from_hour smallint not null default 0 check (tracker_owner_night_from_hour between 0 and 23),
  add column if not exists tracker_owner_night_until_hour smallint not null default 5 check (tracker_owner_night_until_hour between 0 and 23);
comment on column program_settings.tracker_owner_alerts_enabled is 'Owner tracker alerts (3264): on or off. They also wait for trackers_available.';
comment on column program_settings.tracker_owner_speed_kmh is 'Owner tracker alerts (3264): the speed an owner is told about (180 km/h).';
comment on column program_settings.tracker_owner_night_from_hour is 'Owner tracker alerts (3264): late-night driving in the weekly summary counts trips that start from this hour, Toronto time.';
comment on column program_settings.tracker_owner_night_until_hour is 'Owner tracker alerts (3264): ... until this hour.';

alter table tracker_alerts drop constraint tracker_alerts_kind_check;
alter table tracker_alerts add constraint tracker_alerts_kind_check
  check (kind = any (array['speeding', 'left_ontario', 'left_zone', 'overdue_driving', 'battery_low', 'unplugged', 'offline', 'impact', 'tamper', 'health', 'place', 'theft']));

create table tracker_places (
  id         uuid primary key default gen_random_uuid(),
  kind       text not null check (kind in ('impound', 'auto_shop', 'port')),
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
comment on table tracker_places is 'Tracker alerts (3264): the impound lots, auto shops and shipping ports watched. A car that stops inside a place''s radius raises an alert for staff and for its owner. An Admin keeps the list.';
create table tracker_driving_events (
  id         bigserial primary key,
  vehicle_id uuid not null references vehicles (id) on delete cascade,
  booking_id uuid references bookings (id) on delete set null,
  at         timestamptz not null,
  kind       text not null check (kind in ('harsh_brake', 'harsh_accel')),
  unique (vehicle_id, at, kind)
);
create index tracker_driving_events_booking_idx on tracker_driving_events (booking_id) where booking_id is not null;
comment on table tracker_driving_events is 'Tracker alerts (3264): hard braking and hard acceleration a tracker reported, counted in the owner''s weekly driving summary. Never an alert by itself.';
create table owner_tracker_weeklies (
  owner_id uuid not null references owners (id) on delete cascade,
  week_of  date not null,
  sent     boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (owner_id, week_of)
);
comment on table owner_tracker_weeklies is 'Tracker alerts (3264): the weeks an owner''s driving summary was handled (once an owner a week).';
do $$
declare t text;
begin
  foreach t in array array['tracker_places', 'tracker_driving_events', 'owner_tracker_weeklies'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from public, anon, authenticated', t);
    execute format('grant all on %I to service_role', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
  end loop;
end $$;
grant usage on sequence tracker_driving_events_id_seq to service_role;
revoke all on sequence tracker_driving_events_id_seq from public, anon, authenticated;
create trigger tracker_places_updated before update on tracker_places for each row execute function app.set_updated_at();
create trigger audit_tracker_places after insert or update or delete on tracker_places for each row execute function app.audit_row();

-- ================================================================ the owner's alert
create function app.owner_tracker_live() returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce(s.trackers_available, false) and s.tracker_owner_alerts_enabled from app.settings() s
$$;

-- p_type: a notify type (tracker_theft, tracker_tamper, tracker_crash, tracker_place, tracker_health, tracker_speed)
create function app.owner_tracker_alert(p_vehicle uuid, p_type text, p_title text, p_text text, p_key text, p_at timestamptz default now()) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  o owners;
begin
  if not app.owner_tracker_live() then return null; end if;
  select * into v from vehicles where id = p_vehicle;
  select * into o from owners where id = v.owner_id;
  if o.id is null or o.kind <> 'program' or o.status::text <> 'active' then return null; end if;
  return app.emit_event('owner_tracker_alert', 'vehicle', p_vehicle, jsonb_build_object(
    'owner_id', o.id, 'vehicle_id', p_vehicle, 'rule', p_type,
    'first_name', coalesce(nullif(btrim(o.first_name), ''), nullif(split_part(btrim(coalesce(o.legal_name, '')), ' ', 1), ''), 'there'),
    'car_name', app.vehicle_name(p_vehicle), 'alert_title', left(p_title, 160), 'alert_text', left(p_text, 400), 'alert_time', app.fmt_at(p_at)),
    'owner_tracker_alert:' || p_key);
end $$;

-- every tracker alert staff get: the owner's own version of it, in words that name the car only
create function app.owner_tracker_from_alert() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_car text;
  v_type text;
  v_title text;
  v_text text;
  v_booked boolean := new.booking_id is not null;
begin
  if not app.owner_tracker_live() or new.vehicle_id is null then return null; end if;
  v_car := app.vehicle_name(new.vehicle_id);
  if new.kind in ('unplugged', 'offline', 'tamper') then
    v_type := 'tracker_tamper';
    v_title := format('Tracker alert: your %s''s tracker %s', v_car, case new.kind when 'unplugged' then 'lost power' when 'offline' then 'stopped reporting' else 'was tampered with' end);
    v_text := 'The tracker may have been disconnected. CarmaCars has the same alert and is checking the car now.';
  elsif new.kind = 'theft' or new.kind = 'left_ontario' or (new.kind = 'left_zone' and not v_booked) then
    v_type := 'tracker_theft';
    v_title := format('Possible theft: your %s', v_car);
    v_text := case new.kind when 'left_ontario' then 'It has left Ontario.' when 'left_zone' then 'It is far outside its area with no active booking.' else 'It is moving with no active booking.' end
              || ' CarmaCars has the same alert and is acting on it now. We will call you.';
  elsif new.kind = 'impact' then
    v_type := 'tracker_crash';
    v_title := format('Possible crash: your %s''s tracker felt an impact', v_car);
    v_text := 'CarmaCars has the same alert and is checking on the car and the driver now. We will call you with what we find.';
  elsif new.kind = 'place' then
    v_type := 'tracker_place';
    v_title := format('Your %s stopped at %s', v_car, coalesce(nullif(split_part(coalesce(new.detail, ''), '|', 1), ''), 'a watched place'));
    v_text := 'That is an impound lot, an auto shop or a shipping port on our watch list. CarmaCars has the same alert and is checking why.';
  elsif new.kind = 'health' then
    v_type := 'tracker_health';
    v_title := format('Vehicle health warning: your %s', v_car);
    v_text := coalesce(nullif(left(new.detail, 200), ''), 'The tracker read a warning from the car.') || ' CarmaCars will have it looked at.';
  elsif new.kind = 'speeding' and coalesce(new.speed_kmh, 0) >= s.tracker_owner_speed_kmh then
    v_type := 'tracker_speed';
    v_title := format('Your %s was driven at %s km/h', v_car, new.speed_kmh);
    v_text := format('That is over %s km/h. The rental agreement charges for it; CarmaCars is following up with the driver.', s.tracker_owner_speed_kmh);
  else
    return null;
  end if;
  perform app.owner_tracker_alert(new.vehicle_id, v_type, v_title, v_text, new.id::text, new.at);
  return null;
exception when others then
  raise warning 'owner tracker alert not sent for %: %', new.id, sqlerrm;
  return null;
end $$;
create trigger tracker_alerts_owner after insert on tracker_alerts for each row execute function app.owner_tracker_from_alert();

-- ================================================================ events a tracker sends with a point
-- {"points": [{"device", "at", "lat", "lng", ..., "event": "impact" | "tamper" | "health" | "harsh_brake" | "harsh_accel", "detail": "..."}]}
alter function app.tracker_ingest(jsonb) rename to tracker_ingest_pre3264;
create function app.tracker_ingest(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb := app.tracker_ingest_pre3264(p);
  e record;
  d tracker_devices;
  n integer := 0;
begin
  for e in
    select nullif(btrim(x ->> 'device'), '') as dev, app.tracker_time(x -> 'at') as at, lower(btrim(x ->> 'event')) as ev, left(nullif(btrim(coalesce(x ->> 'detail', '')), ''), 200) as detail,
           app.tracker_num(x ->> 'lat', -90, 90) as lat, app.tracker_num(x ->> 'lng', -180, 180) as lng, app.tracker_num(x ->> 'speed', 0, 400) as speed
      from jsonb_array_elements(case when jsonb_typeof(p -> 'points') = 'array' then p -> 'points' else '[]'::jsonb end) x
     where jsonb_typeof(x) = 'object' and lower(btrim(coalesce(x ->> 'event', ''))) in ('impact', 'tamper', 'health', 'harsh_brake', 'harsh_accel')
     limit 500
  loop
    continue when e.dev is null or e.at is null or e.at > now() + interval '10 minutes' or e.at < now() - interval '7 days';
    select * into d from tracker_devices where (serial_number = e.dev or imei = e.dev) and status = 'installed' and vehicle_id is not null limit 1;
    continue when d.id is null;
    if e.ev in ('harsh_brake', 'harsh_accel') then
      insert into tracker_driving_events (vehicle_id, booking_id, at, kind) values (d.vehicle_id, app.tracker_booking_at(d.vehicle_id, e.at), e.at, e.ev) on conflict do nothing;
    else
      perform app.tracker_alert(e.ev, d.id, d.vehicle_id, app.tracker_booking_at(d.vehicle_id, e.at), e.at, e.lat, e.lng, e.speed,
        format('%s: %s', case e.ev when 'impact' then 'Impact felt' when 'tamper' then 'Tracker tampered with' else 'Vehicle health warning' end, app.tracker_car_label(d.vehicle_id)),
        coalesce(e.detail, case e.ev when 'impact' then 'The tracker felt an impact. Call the driver.' when 'tamper' then 'The tracker reported tampering.' else 'The tracker read a warning from the car.' end),
        'ev:' || d.id || ':' || e.ev || ':' || (extract(epoch from e.at)::bigint / 600));
    end if;
    n := n + 1;
  end loop;
  return r || jsonb_build_object('events', n);
end $$;
select pg_temp.copy_grants('app.tracker_ingest(jsonb)'::regprocedure, 'app.tracker_ingest_pre3264(jsonb)'::regprocedure);

-- ================================================================ the watch: a watched place, moving with no booking
create function app.job_owner_tracker(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  pl tracker_places;
  v_place integer := 0; v_theft integer := 0;
  v_day text := to_char(app.local_date(p_now), 'YYYYMMDD');
begin
  if not coalesce((app.settings()).trackers_available, false) then return jsonb_build_object('live', false); end if;
  for r in
    select d.id as device_id, d.vehicle_id, st.latitude, st.longitude, st.speed_kmh, st.ignition_on, st.reported_at
      from tracker_devices d join tracker_status st on st.tracker_device_id = d.id
     where d.status = 'installed' and d.vehicle_id is not null and st.latitude is not null and st.reported_at > p_now - interval '20 minutes'
  loop
    -- stopped inside a watched place
    if coalesce(r.speed_kmh, 0) < 5 then
      select * into pl from tracker_places x where x.is_active and app.tracker_km(r.latitude, r.longitude, x.latitude, x.longitude) * 1000 <= x.radius_m
       order by app.tracker_km(r.latitude, r.longitude, x.latitude, x.longitude) limit 1;
      if pl.id is not null and app.tracker_alert('place', r.device_id, r.vehicle_id, app.tracker_booking_at(r.vehicle_id, r.reported_at), r.reported_at, r.latitude, r.longitude, r.speed_kmh,
           format('%s is at %s (%s)', app.tracker_car_label(r.vehicle_id), pl.name, case pl.kind when 'impound' then 'impound lot' when 'auto_shop' then 'auto shop' else 'shipping port' end),
           pl.name || '|' || pl.kind, 'place:' || r.vehicle_id || ':' || pl.id || ':' || v_day) is not null then
        v_place := v_place + 1;
      end if;
    end if;
    -- moving with nobody meant to be driving: no rental out, no Owner Booking, no staff move or field job under way
    if coalesce(r.speed_kmh, 0) >= 20 and app.tracker_booking_at(r.vehicle_id, r.reported_at) is null
       and not exists (select 1 from bookings b where b.vehicle_id = r.vehicle_id and b.status::text in ('confirmed', 'on_rent') and b.pickup_at - interval '3 hours' <= r.reported_at and b.return_at + interval '6 hours' >= r.reported_at)
       and not exists (select 1 from field_jobs j where j.vehicle_id = r.vehicle_id and j.status in ('acknowledged', 'in_progress') and j.scheduled_at between r.reported_at - interval '12 hours' and r.reported_at + interval '12 hours')
       and not exists (select 1 from vehicle_moves m where m.vehicle_id = r.vehicle_id and m.created_at > r.reported_at - interval '6 hours') then
      if app.tracker_alert('theft', r.device_id, r.vehicle_id, null, r.reported_at, r.latitude, r.longitude, r.speed_kmh,
           format('Moving with no booking: %s', app.tracker_car_label(r.vehicle_id)),
           format('Driving at %s km/h with no rental out, no Owner Booking and no staff job. Check now.', round(r.speed_kmh)), 'theft:' || r.vehicle_id || ':' || v_day) is not null then
        v_theft := v_theft + 1;
      end if;
    end if;
  end loop;
  return jsonb_build_object('live', true, 'place', v_place, 'theft', v_theft);
end $$;

-- ================================================================ the weekly driving summary
create function app.owner_tracker_week(p_owner uuid, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
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
      'over_limit', (select count(*) from tracker_alerts x where x.vehicle_id = v.id and x.kind = 'speeding' and x.speed_kmh >= s.tracker_owner_speed_kmh and x.at >= v_from and x.at < v_to)::text,
      'hard_braking', (select count(*) from tracker_driving_events x where x.vehicle_id = v.id and x.kind = 'harsh_brake' and x.at >= v_from and x.at < v_to)::text,
      'hard_acceleration', (select count(*) from tracker_driving_events x where x.vehicle_id = v.id and x.kind = 'harsh_accel' and x.at >= v_from and x.at < v_to)::text,
      'late_night', coalesce(t.night, 0)::text) as obj
      from vehicles v
      left join lateral (select sum(tt.km) as km, sum(tt.km) filter (where tt.booking_id is not null) as km_booked,
                                count(*) filter (where case when s.tracker_owner_night_from_hour <= s.tracker_owner_night_until_hour
                                    then extract(hour from (tt.started_at at time zone 'America/Toronto')) >= s.tracker_owner_night_from_hour and extract(hour from (tt.started_at at time zone 'America/Toronto')) < s.tracker_owner_night_until_hour
                                    else extract(hour from (tt.started_at at time zone 'America/Toronto')) >= s.tracker_owner_night_from_hour or extract(hour from (tt.started_at at time zone 'America/Toronto')) < s.tracker_owner_night_until_hour end) as night
                           from tracker_trips tt where tt.vehicle_id = v.id and tt.started_at >= v_from and tt.started_at < v_to) t on true
      left join lateral (select sum(coalesce(b.km_allowance_per_day, 0) * greatest(ceil(extract(epoch from least(b.return_at, v_to) - greatest(b.pickup_at, v_from)) / 86400.0), 0))::numeric as allowed
                           from bookings b where b.vehicle_id = v.id and b.status::text in ('on_rent', 'returned', 'closed') and b.pickup_at < v_to and b.return_at > v_from) a on true
     where v.owner_id = p_owner and v.retired_at is null
       and exists (select 1 from tracker_devices d where d.vehicle_id = v.id and d.status = 'installed')
       and coalesce(t.km, 0) > 0) c;
  if v_cars is null then return null; end if;
  return jsonb_build_object('owner_id', p_owner, 'first_name', coalesce(nullif(btrim(o.first_name), ''), nullif(split_part(btrim(coalesce(o.legal_name, '')), ' ', 1), ''), 'there'),
    'week_label', app.fmt_day(v_monday - 7) || ' to ' || app.fmt_day(v_monday - 1), 'speed_limit', s.tracker_owner_speed_kmh::text, 'cars', v_cars);
end $$;

create function app.job_owner_tracker_weekly(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v_local timestamp := p_now at time zone 'America/Toronto';
  v_monday date := v_local::date - (extract(isodow from v_local)::integer - 1);
  o record;
  pl jsonb;
  f record;
  n integer := 0;
begin
  if not app.owner_tracker_live() then return 0; end if;
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

-- ================================================================ the watched places (Admin)
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
  if (p ->> 'kind') not in ('impound', 'auto_shop', 'port') or nullif(btrim(coalesce(p ->> 'name', '')), '') is null
     or (p ->> 'latitude') is null or (p ->> 'longitude') is null then
    raise exception 'Enter the kind of place, its name and where it is (latitude and longitude)' using errcode = '22023';
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
begin
  if not app.user_is_admin(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  return jsonb_build_object('live', app.owner_tracker_live(), 'trackers_available', coalesce((app.settings()).trackers_available, false),
    'speed_kmh', (app.settings()).tracker_owner_speed_kmh,
    'places', (select coalesce(jsonb_agg(to_jsonb(x) order by x.kind, x.name), '[]'::jsonb) from (select id, kind, name, latitude, longitude, radius_m, is_active, note from tracker_places) x),
    'sent_30d', (select count(*) from notification_outbox where code = 'owner_tracker_alert' and created_at > now() - interval '30 days'));
end $$;

insert into notification_catalogue (code, audience, category, subject, preheader, timing, trigger_text, link_path, variables, template_html, template_text, emitted_by, priority, push_topic)
values
  ('owner_tracker_alert', 'owner', 'transactional', '{{alert_title}}', '{{alert_text}}', 'Immediate',
   'Owner tracker alerts (3264): the owner''s car is at a watched place (impound lot, auto shop, shipping port), may be stolen, its tracker was disconnected or tampered with, felt an impact, read a health warning, or was driven over 180 km/h. Only while trackers_available is on, and only the types the owner has on.',
   '/owner/vehicles/{{vehicle_id}}',
   '[{"name":"first_name","type":"string"},{"name":"car_name","type":"string"},{"name":"alert_title","type":"string"},{"name":"alert_text","type":"string"},{"name":"alert_time","type":"string"},{"name":"vehicle_id","type":"string"}]'::jsonb,
   'templates/owner_tracker_alert.html', 'templates/owner_tracker_alert.txt', 'app.owner_tracker_alert (3264)', 2, 'alerts'),
  ('owner_tracker_weekly', 'owner', 'transactional', 'How your cars were driven: {{week_label}}', 'Speeding, hard braking, late-night driving and kilometres against the allowance.', 'Weekly, Monday',
   'Owner tracker alerts (3264): Monday from 9:00 Toronto time, once an owner a week, only for an owner who switched the weekly driving summary on and whose car with a tracker was driven last week.',
   '/owner/vehicles',
   '[{"name":"first_name","type":"string"},{"name":"week_label","type":"string"},{"name":"speed_limit","type":"string"},{"name":"cars","type":"list","fields":["car_name","km","allowance","over","speeding","over_limit","hard_braking","hard_acceleration","late_night"]}]'::jsonb,
   'templates/owner_tracker_weekly.html', 'templates/owner_tracker_weekly.txt', 'app.job_owner_tracker_weekly (3264)', 4, null)
on conflict (code) do nothing;
update notification_catalogue set pref_type = 'tracker_weekly', no_text = true where code = 'owner_tracker_weekly';
update notification_catalogue set pref_type = null where code = 'owner_tracker_alert';
insert into sms_templates (code, label, body, urgent, sort_order) values
  ('owner_tracker_alert', 'Owner tracker alert', 'CarmaCars: {{alert_title}}. {{alert_text}} {{link}}', true, 400)
on conflict (code) do nothing;

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
            where n.nspname in ('app', 'public') and (p.proname ~ '^(owner_tracker_|job_owner_tracker|tracker_places_)' or p.proname ~ '_pre3264$')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
