-- 0400: the Fleet tracking dashboard and the tracker ingest (docs/changes/2026-11-06-tracker-dashboard.md). The owner's brief:
-- "fully custom tracker dashboard"; CarmaCars' own trackers (made in China) are not ready yet, so everything is built for
-- the hardware and fed by the simulator until then. SCHEMA_MARKER 0400.
--
-- 1. tracker_settings: one row, Admin's. The history rate and how long history, trips and alerts are kept (at most 365
--    days: the privacy policy keeps Tracker data 12 months), the speeding limit, the low battery level, the grace after
--    the return time, the offline hours, the Ontario alert, one optional zone, demo mode (off) and the ingest key (kept
--    in Supabase Vault through 0147's app.crm_secret_put, never in a column).
-- 2. tracker_status (0006), the one hot row per device, gains the odometer, battery, fuel, power, the trip under way and
--    the alert flags. It stays out of the row audit (0013) and is written once per device per batch, in place (fillfactor
--    70 keeps the update on the same page, with no index touched).
-- 3. tracker_points: the history, thinned at ingest: a moving car keeps one point per tracker_settings.history_seconds
--    (60), an ignition change always, a parked car one point an hour. Compact columns (micro-degrees as integers), one
--    index, no row audit, no foreign key on the hot path but the car's. Retention deletes in small runs every hour.
-- 4. tracker_trips: one row per trip (ignition on to off) when it ends, with the booking it belongs to, the km (odometer
--    or the GPS distance) and the top speed. tracker_alerts: speeding, left Ontario, left the zone, still driving after
--    the return time, low tracker battery, unplugged, offline; each one row (deduplicated by its key), an in-app notice to
--    Admins (staff_tracker_alert) and fleet staff (staff_tracker_alert_fleet), push topic "alerts".
-- 5. app.tracker_ingest(p): a batch of positions (the generic JSON of /api/tracker/ingest, any adapter's output). Unknown
--    device ids become in-stock devices (Admin pairs them); the car's state, trips and alerts are worked out in the same
--    call. One call per batch, one statement per device for the hot row and one insert for the history.
-- 6. The door (ops_read, ops_do): tracker_fleet (everything the dashboard shows, Admin and fleet staff), tracker_trip_path,
--    tracker_pair and tracker_unpair (the install date feeds the Tracker Fee, 0239), tracker_settings_save,
--    tracker_key_new, tracker_alert_ack (Admin and fleet staff).
-- 7. Privacy: positions are for Admin and fleet staff only. The owner's read of tracker_status (0012) and Finance's are
--    removed; the new tables are Admin and fleet only.
-- 8. app.job_tracker (hourly): closes trips of trackers that went quiet, raises offline alerts, deletes old history.
-- 9. "Tracker seen" on the cars list reads the hot row (the device row is no longer written on every report).
-- No applied migration is edited.

-- ================================================================ 1. settings
create table tracker_settings (
  id                    boolean primary key default true check (id),
  history_seconds       integer not null default 60 check (history_seconds between 10 and 3600),
  history_days          integer not null default 90 check (history_days between 7 and 365),
  trip_days             integer not null default 365 check (trip_days between 30 and 365),
  speed_alert_kmh       integer not null default 140 check (speed_alert_kmh between 60 and 250),
  battery_low_pct       integer not null default 20 check (battery_low_pct between 1 and 90),
  overdue_grace_minutes integer not null default 15 check (overdue_grace_minutes between 0 and 240),
  offline_hours         integer not null default 6 check (offline_hours between 1 and 168),
  ontario_alert         boolean not null default true,
  zone_name             text check (zone_name is null or length(btrim(zone_name)) between 1 and 60),
  zone_lat              numeric(8, 5) check (zone_lat between 41 and 57),
  zone_lng              numeric(8, 5) check (zone_lng between -96 and -74),
  zone_radius_km        numeric(6, 1) check (zone_radius_km between 1 and 1000),
  demo                  boolean not null default false,
  ingest_key_ref        uuid,
  ingest_key_set_at     timestamptz,
  ingest_key_hint       text,
  updated_at            timestamptz not null default now(),
  updated_by            uuid references users (id),
  check ((zone_lat is null) = (zone_lng is null) and (zone_lat is null) = (zone_radius_km is null))
);
comment on table tracker_settings is 'Fleet tracking (0400): one row. The history rate and retention, the alert levels, the optional zone, demo mode and the ingest key (its Vault id only).';
insert into tracker_settings (id) values (true) on conflict do nothing;
alter table tracker_settings enable row level security;
revoke all on tracker_settings from anon, authenticated;
create policy admin_all on tracker_settings for all to authenticated using (app.is_admin()) with check (app.is_admin());
create trigger audit_tracker_settings after insert or update or delete on public.tracker_settings for each row execute function app.audit_row();

create or replace function app.tracker_settings() returns tracker_settings
language sql stable security definer set search_path = public, app as $$ select * from tracker_settings where id $$;

-- ================================================================ 2. the hot row
alter table tracker_status
  add column if not exists odometer_km         numeric(9, 1),
  add column if not exists battery_pct         smallint check (battery_pct between 0 and 100),
  add column if not exists fuel_pct            smallint check (fuel_pct between 0 and 100),
  add column if not exists power_on            boolean,
  add column if not exists received_at         timestamptz,
  add column if not exists history_at          timestamptz,
  add column if not exists trip_started_at     timestamptz,
  add column if not exists trip_start_lat      numeric(8, 5),
  add column if not exists trip_start_lng      numeric(8, 5),
  add column if not exists trip_start_odometer numeric(9, 1),
  add column if not exists trip_m              integer not null default 0,
  add column if not exists trip_max_kmh        numeric(5, 1),
  add column if not exists trip_alerted        boolean not null default false,
  add column if not exists outside_ontario     boolean not null default false,
  add column if not exists outside_zone        boolean not null default false,
  add column if not exists battery_alerted     boolean not null default false,
  add column if not exists offline_alerted     boolean not null default false;
alter table tracker_status set (fillfactor = 70);
comment on column tracker_status.battery_pct is 'Fleet tracking (0400): the tracker''s own backup battery, percent.';
comment on column tracker_status.power_on is 'Fleet tracking (0400): the tracker has the car''s power (false: unplugged or cut).';
comment on column tracker_status.history_at is 'Fleet tracking (0400): the last point kept in tracker_points (the history is thinned at ingest).';
comment on column tracker_status.trip_started_at is 'Fleet tracking (0400): the trip under way (ignition on), null when parked; closed into tracker_trips.';

-- ================================================================ 3. history, trips and alerts
create table tracker_points (
  vehicle_id  uuid not null references vehicles (id) on delete cascade,
  at          timestamptz not null,
  lat_e6      integer not null check (lat_e6 between -90000000 and 90000000),
  lng_e6      integer not null check (lng_e6 between -180000000 and 180000000),
  speed_kmh   smallint,
  heading     smallint,
  ignition    boolean,
  odometer_km real,
  battery_pct smallint,
  fuel_pct    smallint
);
create index tracker_points_vehicle_at on tracker_points (vehicle_id, at);
create index tracker_points_at_brin on tracker_points using brin (at);
comment on table tracker_points is 'Fleet tracking (0400): position history, thinned at ingest (tracker_settings.history_seconds) and kept tracker_settings.history_days. Telemetry: no row audit.';

create table tracker_trips (
  id            uuid primary key default gen_random_uuid(),
  vehicle_id    uuid not null references vehicles (id) on delete cascade,
  booking_id    uuid references bookings (id) on delete set null,
  started_at    timestamptz not null,
  ended_at      timestamptz not null,
  start_lat     numeric(8, 5), start_lng numeric(8, 5),
  end_lat       numeric(8, 5), end_lng numeric(8, 5),
  km            numeric(8, 1) not null check (km >= 0),
  max_speed_kmh smallint,
  closed_by     text not null default 'ignition' check (closed_by in ('ignition', 'quiet', 'unpaired')),
  check (ended_at >= started_at)
);
create index tracker_trips_vehicle on tracker_trips (vehicle_id, started_at desc);
create index tracker_trips_booking on tracker_trips (booking_id) where booking_id is not null;
create index tracker_trips_started on tracker_trips (started_at);
comment on table tracker_trips is 'Fleet tracking (0400): one row per trip (ignition on to off), written when it ends, with its booking, km and top speed.';

create table tracker_alerts (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null check (kind in ('speeding', 'left_ontario', 'left_zone', 'overdue_driving', 'battery_low', 'unplugged', 'offline')),
  vehicle_id  uuid references vehicles (id) on delete cascade,
  booking_id  uuid references bookings (id) on delete set null,
  device_id   uuid references tracker_devices (id) on delete cascade,
  at          timestamptz not null,
  lat         numeric(8, 5), lng numeric(8, 5),
  speed_kmh   smallint,
  title       text not null,
  detail      text,
  dedupe_key  text not null unique,
  ack_at      timestamptz,
  ack_by      uuid references users (id),
  ack_note    text,
  created_at  timestamptz not null default now()
);
create index tracker_alerts_created on tracker_alerts (created_at desc);
create index tracker_alerts_open on tracker_alerts (created_at desc) where ack_at is null;
comment on table tracker_alerts is 'Fleet tracking (0400): speeding, left Ontario, left the zone, still driving after the return time, low tracker battery, unplugged, offline. Each also an in-app notice to Admins and fleet staff (push topic alerts).';
create trigger audit_tracker_alerts after insert or update or delete on public.tracker_alerts for each row execute function app.audit_row();

do $$
declare t text;
begin
  foreach t in array array['tracker_points', 'tracker_trips', 'tracker_alerts'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from anon, authenticated', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
    execute format('create policy fleet_read on %I for select to authenticated using (app.va_has(''fleet''))', t);
    execute format('grant select on %I to authenticated', t);
    execute format('grant all on %I to service_role', t);
  end loop;
end $$;

-- the row audit (0013) leaves the telemetry alone (a later app.attach_audit() too)
create or replace function app.attach_audit() returns integer
language plpgsql as $$
declare
  t record;
  n integer := 0;
  v_skip text[] := array[
    'audit_log', 'status_history', 'data_access_log', 'job_runs',   -- logs
    'tracker_status', 'tracker_points', 'tracker_trips',            -- telemetry, overwritten continuously or written by the ingest (0400)
    'condition_report_photos', 'vehicle_photos', 'photo_jobs',      -- media bookkeeping
    'messages', 'incident_events',                                  -- already append-only records
    'guide_reads', 'app_events'                                     -- open counters and the internal event queue (0074)
  ];
  v_redact text[] := array['payment_method_secrets', 'payment_processor_details', 'owner_payment_method_secrets',
                           'owner_payout_accounts', 'investor_bank_accounts'];
begin
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind = 'r' and c.relname <> all (v_skip)
              and not exists (select 1 from pg_trigger g where g.tgrelid = c.oid and g.tgname = 'audit_' || c.relname)
  loop
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function app.audit_row(%s)',
                   'audit_' || t.relname, t.relname,
                   case when t.relname = any (v_redact) then quote_literal('redact') else '' end);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function app.attach_audit() from public;

-- ================================================================ 7. privacy: positions for Admin and fleet staff only
drop policy if exists owner_read on tracker_status;
drop policy if exists va_read on tracker_status;
create policy va_read on tracker_status for select to authenticated using (app.va_has('fleet'));

-- ================================================================ the notices (in-app only, push topic "alerts")
insert into notification_catalogue (code, audience, also_sent_to, category, subject, preheader, has_email, priority, emitted_by, link_path, push_topic)
values ('staff_tracker_alert', 'staff_admin', '{}'::text[], 'transactional', '{{alert_title}}', '{{alert_detail}}', false, 3,
        'app.tracker_alert (0400)', '/admin/vehicles/tracking', 'alerts'),
       ('staff_tracker_alert_fleet', 'staff_va_fleet', '{}'::text[], 'transactional', '{{alert_title}}', '{{alert_detail}}', false, 3,
        'app.tracker_alert (0400)', '/staff/fleet#tracking', 'alerts')
on conflict (code) do nothing;

-- ================================================================ helpers
-- a number in range from the batch (text or number), else null
create or replace function app.tracker_num(p text, p_min numeric, p_max numeric) returns numeric
language sql immutable as $$
  select case when p ~ '^\s*-?[0-9]{1,9}(\.[0-9]{1,12})?\s*$' and p::numeric between p_min and p_max then p::numeric end
$$;
-- true, false, 1, 0, "on", "off", "true", "false"; else null
create or replace function app.tracker_bool(p jsonb) returns boolean
language sql immutable as $$
  select case when p is null or jsonb_typeof(p) = 'null' then null
              when jsonb_typeof(p) = 'boolean' then (p #>> '{}')::boolean
              when lower(p #>> '{}') in ('1', 'true', 'on', 'yes') then true
              when lower(p #>> '{}') in ('0', 'false', 'off', 'no') then false end
$$;
-- an instant: Unix seconds or milliseconds, or ISO 8601 with its offset (Z or +hh:mm); else null
create or replace function app.tracker_time(p jsonb) returns timestamptz
language plpgsql stable as $$
declare
  t text := p #>> '{}';
begin
  if p is null or t is null then return null; end if;
  if t ~ '^[0-9]{9,13}(\.[0-9]+)?$' then
    return to_timestamp(case when t::numeric > 100000000000 then t::numeric / 1000 else t::numeric end);
  elsif t ~ '^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}(:?\d{2})?)$' then
    return t::timestamptz;
  end if;
  return null;
exception when others then
  return null;
end $$;
-- the great-circle distance in km
create or replace function app.tracker_km(a_lat numeric, a_lng numeric, b_lat numeric, b_lng numeric) returns float8
language sql immutable as $$
  select 2 * 6371.0088 * asin(least(1, sqrt(
    power(sin(radians((b_lat - a_lat)::float8) / 2), 2)
    + cos(radians(a_lat::float8)) * cos(radians(b_lat::float8)) * power(sin(radians((b_lng - a_lng)::float8) / 2), 2))))
$$;
-- Ontario, simplified by hand to about 2 km along the US and Quebec borders near the crossings (the Detroit and St. Clair
-- rivers, Lake Huron, the St. Marys River, Lake Superior, Pigeon River, Rainy River, Lake of the Woods, Manitoba, Hudson
-- and James Bays, the Quebec line, the Ottawa River, the St. Lawrence, Lake Ontario, the Niagara River and Lake Erie).
-- A point near a border may read wrong by a kilometre or two; the alert is a prompt to call, not proof.
create or replace function app.tracker_in_ontario(p_lat numeric, p_lng numeric) returns boolean
language plpgsql immutable as $$
declare
  -- longitude, latitude
  poly float8[] := array[
    [-95.153, 49.384], [-95.153, 52.833], [-88.987, 56.846], [-85.0, 55.3], [-82.3, 55.15], [-82.25, 52.95], [-81.35, 52.15],
    [-80.45, 51.33], [-79.517, 51.46], [-79.517, 47.55], [-79.44, 47.25], [-79.2, 46.8], [-78.75, 46.3], [-77.85, 46.1],
    [-77.25, 45.82], [-76.68, 45.57], [-76.3, 45.47], [-75.82, 45.45], [-75.45, 45.53], [-74.98, 45.56], [-74.64, 45.64],
    [-74.38, 45.57], [-74.34, 45.21], [-74.5, 45.07], [-74.75, 44.99], [-75.1, 44.88], [-75.5, 44.68], [-75.85, 44.43],
    [-76.2, 44.27], [-76.37, 44.1], [-76.8, 43.63], [-77.6, 43.62], [-78.7, 43.63], [-79.07, 43.27], [-79.05, 43.1],
    [-78.98, 42.95], [-78.91, 42.88], [-79.3, 42.69], [-80.05, 42.55], [-81.25, 42.21], [-82.1, 41.92], [-82.5, 41.68],
    [-83.14, 41.95], [-83.1, 42.15], [-83.04, 42.32], [-82.85, 42.36], [-82.55, 42.55], [-82.47, 42.83], [-82.42, 43.0],
    [-82.13, 43.58], [-82.32, 44.5], [-82.55, 45.35], [-83.5, 45.88], [-83.57, 46.1], [-84.12, 46.53], [-84.55, 46.47],
    [-84.85, 46.9], [-85.6, 47.3], [-86.5, 47.65], [-88.37, 48.3], [-89.58, 48.0], [-90.4, 48.1], [-90.84, 48.24],
    [-91.5, 48.05], [-92.35, 48.27], [-92.95, 48.62], [-93.85, 48.61], [-94.6, 48.72], [-94.83, 49.33], [-95.153, 49.384]];
  n integer := array_length(poly, 1);
  x float8 := p_lng; y float8 := p_lat;
  inside boolean := false;
  i integer; j integer;
begin
  if p_lat is null or p_lng is null then return null; end if;
  -- the GTA and its surroundings: inside at once
  if y between 43.3 and 44.9 and x between -80.6 and -77.0 and not (y < 43.62 and x > -79.0) then return true; end if;
  j := n;
  for i in 1..n loop
    if ((poly[i][2] > y) <> (poly[j][2] > y))
       and (x < (poly[j][1] - poly[i][1]) * (y - poly[i][2]) / (poly[j][2] - poly[i][2]) + poly[i][1]) then
      inside := not inside;
    end if;
    j := i;
  end loop;
  return inside;
end $$;

-- the car's photo, as the Live map shows it (0242)
create or replace function app.tracker_car_photo(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce((select jsonb_build_object('path', ph.processed_path, 'variants', ph.variants, 'alt', ph.alt_text, 'sample', false)
                     from vehicle_photos ph where ph.vehicle_id = p_vehicle and ph.is_cover and ph.is_public and ph.status = 'approved' and ph.replaced_at is null
                      and ph.processed_path is not null limit 1),
                  (app.vehicle_sample_photos(p_vehicle) -> 0) || jsonb_build_object('sample', true))
$$;

-- the booking a car was on at that moment (a placeholder is not a rental)
create or replace function app.tracker_booking_at(p_vehicle uuid, p_at timestamptz) returns uuid
language sql stable security definer set search_path = public, app as $$
  select b.id from bookings b
   where b.vehicle_id = p_vehicle and b.status in ('on_rent', 'returned', 'closed') and not coalesce(b.is_placeholder, false)
     and coalesce(b.handed_over_at, b.pickup_at) <= p_at and (b.checked_in_at is null or b.checked_in_at > p_at)
   order by coalesce(b.handed_over_at, b.pickup_at) desc limit 1
$$;

-- one alert: its row (once per key) and the notices to Admins and fleet staff
create or replace function app.tracker_alert(p_kind text, p_device uuid, p_vehicle uuid, p_booking uuid, p_at timestamptz, p_lat numeric, p_lng numeric,
                                             p_speed numeric, p_title text, p_detail text, p_key text) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
  v_payload jsonb;
begin
  insert into tracker_alerts (kind, device_id, vehicle_id, booking_id, at, lat, lng, speed_kmh, title, detail, dedupe_key)
  values (p_kind, p_device, p_vehicle, p_booking, p_at, round(p_lat, 5), round(p_lng, 5), round(p_speed)::smallint, left(p_title, 200), left(p_detail, 500), p_key)
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  if v_id is null then return null; end if;
  v_payload := jsonb_build_object('alert_title', left(p_title, 200), 'alert_detail', coalesce(left(p_detail, 500), ''), 'alert_id', v_id, 'alert_kind', p_kind,
                                  'vehicle_id', p_vehicle, 'booking_id', p_booking,
                                  'booking_number', (select booking_number from bookings where id = p_booking));
  perform app.emit_event('staff_tracker_alert', 'vehicle', p_vehicle, v_payload, 'tracker_alert:' || v_id);
  perform app.emit_event('staff_tracker_alert_fleet', 'vehicle', p_vehicle, v_payload, 'tracker_alert_fleet:' || v_id);
  return v_id;
end $$;

-- a car's name for an alert ("2024 Toyota Corolla (CC-7F3A)")
create or replace function app.tracker_car_label(p_vehicle uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select app.vehicle_name(v.id) || coalesce(' (' || v.car_code || ')', '') from vehicles v where v.id = p_vehicle
$$;

-- a trip ends: one row, the hot row's trip fields cleared by the caller
create or replace function app.tracker_close_trip(p_vehicle uuid, st tracker_status, p_end timestamptz, p_lat numeric, p_lng numeric, p_odo numeric, p_by text)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  v_km numeric;
  v_id uuid;
begin
  if p_vehicle is null or st.trip_started_at is null then return null; end if;
  v_km := case when st.trip_start_odometer is not null and p_odo is not null and p_odo >= st.trip_start_odometer
                    and p_odo - st.trip_start_odometer <= greatest(st.trip_m / 1000.0 * 1.5 + 5, 5)
               then p_odo - st.trip_start_odometer else st.trip_m / 1000.0 end;
  -- a blip (under 100 m and under 2 minutes) is not a trip
  if v_km < 0.1 and p_end - st.trip_started_at < interval '2 minutes' then return null; end if;
  insert into tracker_trips (vehicle_id, booking_id, started_at, ended_at, start_lat, start_lng, end_lat, end_lng, km, max_speed_kmh, closed_by)
  values (p_vehicle, app.tracker_booking_at(p_vehicle, st.trip_started_at), st.trip_started_at, greatest(p_end, st.trip_started_at),
          st.trip_start_lat, st.trip_start_lng, round(p_lat, 5), round(p_lng, 5), round(v_km, 1), round(coalesce(st.trip_max_kmh, 0))::smallint, p_by)
  returning id into v_id;
  return v_id;
end $$;

-- ================================================================ 5. the ingest
-- p: {"points": [{"device", "at", "lat", "lng", "speed", "heading", "ignition", "odometer", "battery", "power", "fuel"}]}
-- (docs/tracker-ingest.md). Points older than the device's last report are skipped (a replayed or late batch changes
-- nothing); the rest, in time order per device, move the hot row, the trip and the alerts.
create or replace function app.tracker_ingest(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s tracker_settings := app.tracker_settings();
  v_pts jsonb := p -> 'points';
  v_now timestamptz := clock_timestamp();
  pt record;
  d tracker_devices;
  st tracker_status;
  v_dev text;
  v_live boolean;           -- an installed device on a car: history, trips and alerts
  v_moving boolean;
  v_ign boolean;
  v_km float8;
  v_hours float8;
  v_keep boolean;
  v_total integer := 0; v_ok integer := 0; v_old integer := 0; v_new_dev integer := 0; v_devices integer := 0;
  -- the history kept, inserted once at the end
  h_vehicle uuid[] := '{}'; h_at timestamptz[] := '{}'; h_lat integer[] := '{}'; h_lng integer[] := '{}'; h_speed smallint[] := '{}';
  h_heading smallint[] := '{}'; h_ign boolean[] := '{}'; h_odo real[] := '{}'; h_bat smallint[] := '{}'; h_fuel smallint[] := '{}';
begin
  if jsonb_typeof(v_pts) is distinct from 'array' then
    raise exception 'The batch needs "points", a list' using errcode = '22023';
  end if;
  v_total := jsonb_array_length(v_pts);
  if v_total > 5000 then raise exception 'At most 5000 points a batch' using errcode = '22023'; end if;

  for pt in
    select t.dev, t.at, t.lat, t.lng, t.speed, t.heading, t.ign, t.odo, t.bat, t.fuel, t.pow
      from (select nullif(btrim(x ->> 'device'), '') as dev, app.tracker_time(x -> 'at') as at,
                   app.tracker_num(x ->> 'lat', -90, 90) as lat, app.tracker_num(x ->> 'lng', -180, 180) as lng,
                   app.tracker_num(x ->> 'speed', 0, 400) as speed, app.tracker_num(x ->> 'heading', 0, 360) as heading,
                   app.tracker_bool(x -> 'ignition') as ign, app.tracker_num(x ->> 'odometer', 0, 9999999) as odo,
                   app.tracker_num(x ->> 'battery', 0, 100) as bat, app.tracker_num(x ->> 'fuel', 0, 100) as fuel, app.tracker_bool(x -> 'power') as pow
              from jsonb_array_elements(v_pts) x
             where jsonb_typeof(x) = 'object') t
     where t.dev ~ '^[A-Za-z0-9._:-]{3,64}$' and t.at is not null and t.lat is not null and t.lng is not null
       and not (t.lat = 0 and t.lng = 0)
       and t.at <= v_now + interval '10 minutes' and t.at > v_now - interval '7 days'
     order by t.dev, t.at
  loop
    if pt.dev is distinct from v_dev then
      if v_dev is not null then perform app.tracker_finish(st, d, s, v_now); end if;
      v_dev := pt.dev; v_devices := v_devices + 1;
      select * into d from tracker_devices where serial_number = pt.dev or imei = pt.dev
       order by (status = 'installed') desc, (serial_number = pt.dev) desc limit 1;
      if d.id is null then
        insert into tracker_devices (serial_number, status) values (pt.dev, 'in_stock') returning * into d;
        v_new_dev := v_new_dev + 1;
      end if;
      insert into tracker_status (tracker_device_id, reported_at) values (d.id, '-infinity') on conflict (tracker_device_id) do nothing;
      select * into st from tracker_status where tracker_device_id = d.id for update;
      v_live := d.status = 'installed' and d.vehicle_id is not null;
    end if;
    if pt.at <= st.reported_at then v_old := v_old + 1; continue; end if;
    v_ok := v_ok + 1;
    v_moving := coalesce(pt.speed, 0) >= 3;
    v_ign := coalesce(pt.ign, v_moving);

    -- the trip: its distance (a jump faster than 300 km/h is a GPS glitch and is left out) and top speed
    if st.trip_started_at is not null and st.latitude is not null then
      v_km := app.tracker_km(st.latitude, st.longitude, pt.lat, pt.lng);
      v_hours := greatest(extract(epoch from pt.at - st.reported_at) / 3600.0, 1 / 3600.0);
      if v_km <= 0.3 or v_km / v_hours <= 300 then st.trip_m := st.trip_m + round(v_km * 1000)::integer; end if;
    end if;
    if v_ign and st.trip_started_at is null then
      st.trip_started_at := pt.at; st.trip_start_lat := round(pt.lat, 5); st.trip_start_lng := round(pt.lng, 5);
      st.trip_start_odometer := coalesce(pt.odo, st.odometer_km); st.trip_m := 0; st.trip_max_kmh := 0; st.trip_alerted := false;
    end if;
    if st.trip_started_at is not null then
      st.trip_max_kmh := greatest(coalesce(st.trip_max_kmh, 0), coalesce(pt.speed, 0));
      if v_live and coalesce(pt.speed, 0) >= s.speed_alert_kmh and not st.trip_alerted then
        perform app.tracker_alert('speeding', d.id, d.vehicle_id, app.tracker_booking_at(d.vehicle_id, pt.at), pt.at, pt.lat, pt.lng, pt.speed,
          format('Speeding: %s at %s km/h', app.tracker_car_label(d.vehicle_id), round(pt.speed)),
          format('Over the %s km/h alert level at %s.', s.speed_alert_kmh, app.fmt_at(pt.at)),
          'speed:' || d.id || ':' || extract(epoch from st.trip_started_at)::bigint);
        st.trip_alerted := true;
      end if;
    end if;

    -- the history: thinned (moving: one point per history_seconds; parked: one an hour; an ignition change always)
    v_keep := v_live and (st.history_at is null or v_ign is distinct from st.ignition_on
              or (v_moving and pt.at - st.history_at >= make_interval(secs => s.history_seconds))
              or (not v_moving and pt.at - st.history_at >= interval '1 hour'));
    if v_keep then
      h_vehicle := h_vehicle || d.vehicle_id; h_at := h_at || pt.at;
      h_lat := h_lat || round(pt.lat * 1000000)::integer; h_lng := h_lng || round(pt.lng * 1000000)::integer;
      h_speed := h_speed || round(coalesce(pt.speed, 0))::smallint; h_heading := h_heading || (round(pt.heading)::integer % 360)::smallint;
      h_ign := h_ign || v_ign; h_odo := h_odo || pt.odo::real; h_bat := h_bat || round(pt.bat)::smallint; h_fuel := h_fuel || round(pt.fuel)::smallint;
      st.history_at := pt.at;
    end if;

    -- the hot row (a field a point leaves out keeps its last value: a heartbeat carries the battery, a fix the position)
    st.reported_at := pt.at; st.received_at := v_now;
    st.latitude := round(pt.lat, 6); st.longitude := round(pt.lng, 6);
    st.speed_kmh := round(coalesce(pt.speed, 0), 1); st.ignition_on := v_ign;
    if pt.heading is not null and (v_moving or st.heading_deg is null) then st.heading_deg := (round(pt.heading)::integer % 360)::smallint; end if;
    st.odometer_km := coalesce(round(pt.odo, 1), st.odometer_km);
    st.battery_pct := coalesce(round(pt.bat)::smallint, st.battery_pct);
    st.fuel_pct := coalesce(round(pt.fuel)::smallint, st.fuel_pct);
    if pt.pow is not null then
      if v_live and not pt.pow and coalesce(st.power_on, true) then
        perform app.tracker_alert('unplugged', d.id, d.vehicle_id, app.tracker_booking_at(d.vehicle_id, pt.at), pt.at, pt.lat, pt.lng, pt.speed,
          format('Tracker unplugged: %s', app.tracker_car_label(d.vehicle_id)),
          format('The tracker lost the car''s power at %s. It runs on its own battery (%s).', app.fmt_at(pt.at), coalesce(round(pt.bat) || '%', 'level unknown')),
          'power:' || d.id || ':' || extract(epoch from pt.at)::bigint);
      end if;
      st.power_on := pt.pow;
    end if;
    st.offline_alerted := false;

    -- the trip ends with the ignition off
    if not v_ign and st.trip_started_at is not null then
      if v_live then perform app.tracker_close_trip(d.vehicle_id, st, pt.at, pt.lat, pt.lng, coalesce(pt.odo, st.odometer_km), 'ignition'); end if;
      st.trip_started_at := null; st.trip_start_lat := null; st.trip_start_lng := null; st.trip_start_odometer := null;
      st.trip_m := 0; st.trip_max_kmh := null; st.trip_alerted := false;
    end if;
  end loop;
  if v_dev is not null then perform app.tracker_finish(st, d, s, v_now); end if;

  if cardinality(h_at) > 0 then
    insert into tracker_points (vehicle_id, at, lat_e6, lng_e6, speed_kmh, heading, ignition, odometer_km, battery_pct, fuel_pct)
    select * from unnest(h_vehicle, h_at, h_lat, h_lng, h_speed, h_heading, h_ign, h_odo, h_bat, h_fuel);
  end if;
  return jsonb_build_object('received', v_total, 'accepted', v_ok, 'old', v_old, 'skipped', v_total - v_ok - v_old,
                            'devices', v_devices, 'new_devices', v_new_dev, 'kept', cardinality(h_at));
end $$;

-- the end of one device's points in a batch: the alerts that depend on where the car is now, then the hot row, in place
create or replace function app.tracker_finish(st tracker_status, d tracker_devices, s tracker_settings, p_now timestamptz) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_live boolean := d.status = 'installed' and d.vehicle_id is not null;
  v_out boolean;
  v_booking uuid;
  b record;
  v_car text;
begin
  if st.reported_at = '-infinity' then
    delete from tracker_status where tracker_device_id = st.tracker_device_id and reported_at = '-infinity';
    return;
  end if;
  if v_live then
    v_car := app.tracker_car_label(d.vehicle_id);
    v_booking := app.tracker_booking_at(d.vehicle_id, st.reported_at);
    -- left Ontario (rental agreement 10.1: the car stays in Ontario unless we agree in writing)
    v_out := not coalesce(app.tracker_in_ontario(st.latitude, st.longitude), true);
    if s.ontario_alert and v_out and not st.outside_ontario then
      perform app.tracker_alert('left_ontario', d.id, d.vehicle_id, v_booking, st.reported_at, st.latitude, st.longitude, st.speed_kmh,
        format('Left Ontario: %s', v_car), format('Outside Ontario at %s.', app.fmt_at(st.reported_at)),
        'ontario:' || d.vehicle_id || ':' || extract(epoch from st.reported_at)::bigint);
    end if;
    st.outside_ontario := v_out;
    -- the optional zone
    if s.zone_lat is not null then
      v_out := app.tracker_km(s.zone_lat, s.zone_lng, st.latitude, st.longitude) > s.zone_radius_km;
      if v_out and not st.outside_zone then
        perform app.tracker_alert('left_zone', d.id, d.vehicle_id, v_booking, st.reported_at, st.latitude, st.longitude, st.speed_kmh,
          format('Left %s: %s', s.zone_name, v_car), format('More than %s km from the zone''s centre at %s.', s.zone_radius_km, app.fmt_at(st.reported_at)),
          'zone:' || d.vehicle_id || ':' || extract(epoch from st.reported_at)::bigint);
      end if;
      st.outside_zone := v_out;
    else
      st.outside_zone := false;
    end if;
    -- still driving after the return time (once per booking)
    if coalesce(st.speed_kmh, 0) >= 5 then
      select bk.id, bk.booking_number, bk.return_at into b from bookings bk
       where bk.vehicle_id = d.vehicle_id and bk.status = 'on_rent' and not coalesce(bk.is_placeholder, false)
         and bk.return_at + make_interval(mins => s.overdue_grace_minutes) < st.reported_at
       order by bk.return_at desc limit 1;
      if b.id is not null then
        perform app.tracker_alert('overdue_driving', d.id, d.vehicle_id, b.id, st.reported_at, st.latitude, st.longitude, st.speed_kmh,
          format('Still driving after the return time: %s', v_car),
          format('Booking %s was due back %s; moving at %s km/h at %s.', b.booking_number, app.fmt_at(b.return_at), round(st.speed_kmh), app.fmt_at(st.reported_at)),
          'overdue:' || b.id);
      end if;
    end if;
  end if;
  -- low tracker battery (once until it charges back 5 points above the level)
  if st.battery_pct is not null then
    if v_live and st.battery_pct < s.battery_low_pct and not st.battery_alerted then
      perform app.tracker_alert('battery_low', d.id, d.vehicle_id, v_booking, st.reported_at, st.latitude, st.longitude, st.speed_kmh,
        format('Tracker battery low: %s', v_car), format('%s%% at %s.', st.battery_pct, app.fmt_at(st.reported_at)),
        'battery:' || d.id || ':' || extract(epoch from st.reported_at)::bigint);
      st.battery_alerted := true;
    elsif st.battery_pct >= s.battery_low_pct + 5 then
      st.battery_alerted := false;
    end if;
  end if;
  update tracker_status t
     set (reported_at, received_at, latitude, longitude, speed_kmh, ignition_on, heading_deg, odometer_km, battery_pct, fuel_pct, power_on,
          history_at, trip_started_at, trip_start_lat, trip_start_lng, trip_start_odometer, trip_m, trip_max_kmh, trip_alerted,
          outside_ontario, outside_zone, battery_alerted, offline_alerted)
       = (st.reported_at, st.received_at, st.latitude, st.longitude, st.speed_kmh, st.ignition_on, st.heading_deg, st.odometer_km, st.battery_pct,
          st.fuel_pct, st.power_on, st.history_at, st.trip_started_at, st.trip_start_lat, st.trip_start_lng, st.trip_start_odometer, st.trip_m,
          st.trip_max_kmh, st.trip_alerted, st.outside_ontario, st.outside_zone, st.battery_alerted, st.offline_alerted)
   where t.tracker_device_id = st.tracker_device_id;
end $$;

-- the ingest key, for the website to check signatures (service role only)
create or replace function app.tracker_ingest_key() returns text
language sql stable security definer set search_path = public, app as $$
  select app.crm_secret_get((select ingest_key_ref from tracker_settings where id))
$$;

-- ================================================================ 6. what the dashboard reads and does
create or replace function app.tracker_assert(p_user uuid, p_manage boolean) returns void
language plpgsql stable security definer set search_path = public, app as $$
begin
  if app.user_is_admin(p_user) then return; end if;
  if not p_manage and app.user_va_has(p_user, 'fleet') then return; end if;
  raise exception '%', case when p_manage then 'Only an Admin can change the trackers' else 'Fleet tracking is for Admins and fleet staff' end using errcode = '42501';
end $$;

create or replace function app.tracker_fleet(p_user uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s tracker_settings := app.tracker_settings();
  v_admin boolean := app.user_is_admin(p_user);
  v_since timestamptz := now() - make_interval(days => least(greatest(coalesce((p ->> 'days')::integer, 30), 1), 365));
begin
  perform app.tracker_assert(p_user, false);
  return (
    with cars as (
      select v.id, v.car_code, v.plate, v.status::text as vstatus, app.vehicle_name(v.id) as name, v.tracker_installed_on, v.management_mode::text as mode,
             d.id as device_id, d.serial_number, d.imei, d.firmware, d.installed_at,
             ts.reported_at, ts.received_at, ts.latitude, ts.longitude, ts.speed_kmh, ts.heading_deg, ts.ignition_on, ts.odometer_km, ts.battery_pct, ts.fuel_pct,
             ts.power_on, ts.trip_started_at, ts.trip_m, ts.trip_max_kmh, ts.outside_ontario, ts.outside_zone,
             bk.id as booking_id, bk.booking_number, bk.status::text as bstatus, bk.pickup_at, bk.return_at, r.legal_name as renter
        from vehicles v
        left join tracker_devices d on d.vehicle_id = v.id and d.status = 'installed'
        left join tracker_status ts on ts.tracker_device_id = d.id and ts.reported_at > '-infinity'
        left join lateral (select b.* from bookings b where b.vehicle_id = v.id and not coalesce(b.is_placeholder, false)
                             and (b.status = 'on_rent' or (b.status = 'confirmed' and b.pickup_at < now() + interval '24 hours'))
                            order by (b.status = 'on_rent') desc, b.pickup_at limit 1) bk on true
        left join renters r on r.id = bk.renter_id
       where v.retired_at is null and not coalesce(v.is_sample, false)
    )
    select jsonb_build_object(
      'at', now(), 'admin', v_admin, 'demo', s.demo,
      'settings', jsonb_build_object('history_seconds', s.history_seconds, 'history_days', s.history_days, 'trip_days', s.trip_days,
                    'speed_alert_kmh', s.speed_alert_kmh, 'battery_low_pct', s.battery_low_pct, 'overdue_grace_minutes', s.overdue_grace_minutes,
                    'offline_hours', s.offline_hours, 'ontario_alert', s.ontario_alert, 'zone_name', s.zone_name, 'zone_lat', s.zone_lat,
                    'zone_lng', s.zone_lng, 'zone_radius_km', s.zone_radius_km, 'demo', s.demo,
                    'key_set', s.ingest_key_ref is not null, 'key_hint', case when v_admin then s.ingest_key_hint end, 'key_set_at', s.ingest_key_set_at),
      'hq', app.delivery_origin(),
      'cars', coalesce((select jsonb_agg(jsonb_build_object(
          'vehicle_id', c.id, 'code', c.car_code, 'name', c.name, 'plate', c.plate, 'status', c.vstatus, 'mode', c.mode, 'photo', app.tracker_car_photo(c.id),
          'device', case when c.device_id is not null then jsonb_build_object('id', c.device_id, 'serial', c.serial_number, 'imei', c.imei, 'firmware', c.firmware,
                      'installed_at', c.installed_at, 'fee_from', c.tracker_installed_on) end,
          'pos', case when c.reported_at is not null and c.latitude is not null then jsonb_build_object('lat', c.latitude::float8, 'lng', c.longitude::float8,
                   'speed', c.speed_kmh::float8, 'heading', c.heading_deg, 'ignition', c.ignition_on, 'at', c.reported_at, 'odometer', c.odometer_km::float8,
                   'battery', c.battery_pct, 'fuel', c.fuel_pct, 'power', c.power_on, 'outside_ontario', c.outside_ontario, 'outside_zone', c.outside_zone) end,
          'trip', case when c.trip_started_at is not null then jsonb_build_object('started_at', c.trip_started_at, 'km', round(c.trip_m / 1000.0, 1), 'max', c.trip_max_kmh) end,
          'booking', case when c.booking_id is not null then jsonb_build_object('id', c.booking_id, 'number', c.booking_number, 'status', c.bstatus, 'renter', c.renter,
                       'pickup_at', c.pickup_at, 'return_at', c.return_at, 'overdue', c.bstatus = 'on_rent' and c.return_at < now()) end)
          order by (c.booking_id is not null and c.bstatus = 'on_rent') desc, c.name) from cars c), '[]'::jsonb),
      -- devices reporting that are not on a car yet (pair them)
      'unpaired', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'serial', d.serial_number, 'imei', d.imei, 'status', d.status,
                    'last_seen', ts.reported_at, 'battery', ts.battery_pct, 'lat', ts.latitude::float8, 'lng', ts.longitude::float8) order by ts.reported_at desc nulls last)
                  from tracker_devices d left join tracker_status ts on ts.tracker_device_id = d.id and ts.reported_at > '-infinity'
                 where d.status in ('in_stock', 'removed') and (ts.reported_at > now() - interval '30 days' or d.status = 'in_stock')), '[]'::jsonb),
      'alerts', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'kind', a.kind, 'title', a.title, 'detail', a.detail, 'at', a.at, 'vehicle_id', a.vehicle_id,
                    'booking_number', (select booking_number from bookings where id = a.booking_id), 'lat', a.lat::float8, 'lng', a.lng::float8,
                    'ack_at', a.ack_at, 'ack_by', (select full_name from users where id = a.ack_by), 'ack_note', a.ack_note) order by (a.ack_at is null) desc, a.at desc)
                  from (select * from tracker_alerts x where x.ack_at is null or x.created_at > now() - interval '7 days' order by x.created_at desc limit 100) a), '[]'::jsonb),
      'open_alerts', (select count(*) from tracker_alerts where ack_at is null),
      -- trips per booking (the last 30 days by default): km, top speed and the trips themselves
      'bookings', coalesce((select jsonb_agg(x order by x ->> 'last' desc) from (
          select jsonb_build_object('booking_id', b.id, 'number', b.booking_number, 'status', b.status, 'renter', r.legal_name, 'vehicle_id', b.vehicle_id,
                   'vehicle', app.vehicle_name(b.vehicle_id), 'trips', count(t.*), 'km', round(sum(t.km), 1), 'max_speed', max(t.max_speed_kmh),
                   'first', min(t.started_at), 'last', max(t.ended_at),
                   'list', jsonb_agg(jsonb_build_object('id', t.id, 'started_at', t.started_at, 'ended_at', t.ended_at, 'km', t.km, 'max', t.max_speed_kmh) order by t.started_at desc)) as x
            from tracker_trips t join bookings b on b.id = t.booking_id left join renters r on r.id = b.renter_id
           where t.started_at > v_since
           group by b.id, r.legal_name) q), '[]'::jsonb),
      'counts', jsonb_build_object(
        'cars', (select count(*) from cars),
        'tracked', (select count(*) from cars where device_id is not null),
        'moving', (select count(*) from cars where reported_at > now() - interval '15 minutes' and speed_kmh >= 3),
        'parked', (select count(*) from cars where reported_at > now() - interval '15 minutes' and coalesce(speed_kmh, 0) < 3),
        'offline', (select count(*) from cars where device_id is not null and (reported_at is null or reported_at <= now() - interval '15 minutes')),
        'on_rent', (select count(*) from cars where bstatus = 'on_rent'))));
end $$;

-- a trip's route (at most 500 points) for the map
create or replace function app.tracker_trip_path(p_user uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  t tracker_trips;
  v_n integer;
begin
  perform app.tracker_assert(p_user, false);
  select * into t from tracker_trips where id = (p ->> 'trip')::uuid;
  if t.id is null then raise exception 'Trip not found' using errcode = 'P0002'; end if;
  select count(*) into v_n from tracker_points where vehicle_id = t.vehicle_id and at between t.started_at and t.ended_at;
  return jsonb_build_object('trip', to_jsonb(t), 'path', coalesce((
    select jsonb_agg(jsonb_build_array(round(q.lng_e6 / 1e6, 6), round(q.lat_e6 / 1e6, 6)) order by q.at)
      from (select x.*, row_number() over (order by x.at) as n from tracker_points x
             where x.vehicle_id = t.vehicle_id and x.at between t.started_at and t.ended_at) q
     where v_n <= 500 or q.n % ceil(v_n / 500.0)::integer = 1 or q.n = v_n), '[]'::jsonb));
end $$;

-- pair a device with a car: the install date starts the Tracker Fee (0239) when the car has none yet; a device the car
-- had before is marked removed (a replacement keeps the car's fee date)
create or replace function app.tracker_pair(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_vehicle uuid := (p ->> 'vehicle_id')::uuid;
  v_ref text := nullif(btrim(coalesce(p ->> 'device', '')), '');
  v_on date := coalesce(nullif(p ->> 'installed_on', '')::date, app.today());
  d tracker_devices;
  v vehicles;
  st tracker_status;
begin
  perform app.tracker_assert(p_user, true);
  select * into v from vehicles where id = v_vehicle;
  if v.id is null then raise exception 'Choose a car' using errcode = '22023'; end if;
  if v_ref is null then raise exception 'Enter the tracker''s device ID (its IMEI or serial number)' using errcode = '22023'; end if;
  if v_ref !~ '^[A-Za-z0-9._:-]{3,64}$' then raise exception 'A device ID has 3 to 64 letters, digits, dots, dashes, colons or underscores' using errcode = '22023'; end if;
  if v_on > app.today() then raise exception 'The install date cannot be in the future' using errcode = '22023'; end if;
  select * into d from tracker_devices where id::text = v_ref or serial_number = v_ref or imei = v_ref order by (status = 'installed') desc limit 1;
  if d.id is not null and d.status = 'installed' and d.vehicle_id is distinct from v_vehicle then
    raise exception 'This tracker is on %. Remove it from that car first', app.vehicle_name(d.vehicle_id) using errcode = '23514';
  end if;
  -- the car's previous tracker comes off (its open trip ends)
  for st in select s.* from tracker_devices x join tracker_status s on s.tracker_device_id = x.id
             where x.vehicle_id = v_vehicle and x.status = 'installed' and x.id is distinct from d.id and s.trip_started_at is not null loop
    perform app.tracker_close_trip(v_vehicle, st, st.reported_at, st.latitude, st.longitude, st.odometer_km, 'unpaired');
    update tracker_status set trip_started_at = null, trip_m = 0, trip_max_kmh = null, trip_alerted = false where tracker_device_id = st.tracker_device_id;
  end loop;
  update tracker_devices set status = 'removed', removed_at = now(), removed_by = p_user
   where vehicle_id = v_vehicle and status = 'installed' and id is distinct from d.id;
  if d.id is null then
    insert into tracker_devices (serial_number, imei, sim_iccid, vehicle_id, status, installed_at, installed_by)
    values (v_ref, nullif(btrim(p ->> 'imei'), ''), nullif(btrim(p ->> 'sim'), ''), v_vehicle, 'installed', app.local_midnight(v_on) + interval '12 hours', p_user)
    returning * into d;
  else
    update tracker_devices set vehicle_id = v_vehicle, status = 'installed', installed_at = app.local_midnight(v_on) + interval '12 hours', installed_by = p_user,
                               removed_at = null, removed_by = null,
                               imei = coalesce(nullif(btrim(p ->> 'imei'), ''), imei), sim_iccid = coalesce(nullif(btrim(p ->> 'sim'), ''), sim_iccid)
     where id = d.id returning * into d;
  end if;
  -- the hot row starts fresh for this car (no trip, no flags carried over from the bench)
  update tracker_status set trip_started_at = null, trip_m = 0, trip_max_kmh = null, trip_alerted = false, outside_ontario = false, outside_zone = false,
                            battery_alerted = false, offline_alerted = false, history_at = null
   where tracker_device_id = d.id;
  update vehicles set tracker_install_pending = false, tracker_installed_on = coalesce(tracker_installed_on, v_on) where id = v_vehicle;
  return jsonb_build_object('device_id', d.id, 'vehicle_id', v_vehicle, 'fee_from', (select tracker_installed_on from vehicles where id = v_vehicle));
end $$;

create or replace function app.tracker_unpair(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  d tracker_devices;
  st tracker_status;
begin
  perform app.tracker_assert(p_user, true);
  select * into d from tracker_devices where id = (p ->> 'device_id')::uuid;
  if d.id is null or d.status <> 'installed' then raise exception 'This tracker is not on a car' using errcode = '22023'; end if;
  select * into st from tracker_status where tracker_device_id = d.id for update;
  if st.trip_started_at is not null then
    perform app.tracker_close_trip(d.vehicle_id, st, st.reported_at, st.latitude, st.longitude, st.odometer_km, 'unpaired');
  end if;
  update tracker_status set trip_started_at = null, trip_m = 0, trip_max_kmh = null, trip_alerted = false where tracker_device_id = d.id;
  update tracker_devices set status = case when coalesce(p ->> 'faulty', 'false')::boolean then 'faulty' else 'removed' end, removed_at = now(), removed_by = p_user
   where id = d.id;
  return jsonb_build_object('device_id', d.id, 'vehicle_id', d.vehicle_id);
end $$;

create or replace function app.tracker_settings_save(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s tracker_settings := app.tracker_settings();
  v_zone boolean := nullif(btrim(coalesce(p ->> 'zone_name', '')), '') is not null;
begin
  perform app.tracker_assert(p_user, true);
  update tracker_settings set
    history_seconds = coalesce((p ->> 'history_seconds')::integer, s.history_seconds),
    history_days = coalesce((p ->> 'history_days')::integer, s.history_days),
    trip_days = coalesce((p ->> 'trip_days')::integer, s.trip_days),
    speed_alert_kmh = coalesce((p ->> 'speed_alert_kmh')::integer, s.speed_alert_kmh),
    battery_low_pct = coalesce((p ->> 'battery_low_pct')::integer, s.battery_low_pct),
    overdue_grace_minutes = coalesce((p ->> 'overdue_grace_minutes')::integer, s.overdue_grace_minutes),
    offline_hours = coalesce((p ->> 'offline_hours')::integer, s.offline_hours),
    ontario_alert = coalesce((p ->> 'ontario_alert')::boolean, s.ontario_alert),
    demo = coalesce((p ->> 'demo')::boolean, s.demo),
    zone_name = case when p ? 'zone_name' then case when v_zone then btrim(p ->> 'zone_name') end else s.zone_name end,
    zone_lat = case when p ? 'zone_name' then case when v_zone then (p ->> 'zone_lat')::numeric end else s.zone_lat end,
    zone_lng = case when p ? 'zone_name' then case when v_zone then (p ->> 'zone_lng')::numeric end else s.zone_lng end,
    zone_radius_km = case when p ? 'zone_name' then case when v_zone then (p ->> 'zone_radius_km')::numeric end else s.zone_radius_km end,
    updated_at = now(), updated_by = p_user
  where id;
  return to_jsonb(app.tracker_settings()) - 'ingest_key_ref';
exception when check_violation then
  raise exception 'Check the values: history every 10 to 3600 seconds, kept 7 to 365 days; trips 30 to 365 days; speed 60 to 250 km/h; battery 1 to 90%%; a zone needs its name, centre and radius (1 to 1000 km) in Ontario' using errcode = '23514';
end $$;

-- a new ingest key (shown once): the relay or the tracker service signs each batch with it
create or replace function app.tracker_key_new(p_user uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_key text := 'trk_' || replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  v_ref uuid;
begin
  perform app.tracker_assert(p_user, true);
  v_ref := app.crm_secret_put((select ingest_key_ref from tracker_settings where id), v_key, 'tracker-ingest');
  update tracker_settings set ingest_key_ref = v_ref, ingest_key_set_at = now(), ingest_key_hint = right(v_key, 4), updated_at = now(), updated_by = p_user where id;
  return jsonb_build_object('key', v_key, 'hint', right(v_key, 4));
end $$;

create or replace function app.tracker_alert_ack(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  n integer;
begin
  perform app.tracker_assert(p_user, false);
  if coalesce((p ->> 'all')::boolean, false) then
    update tracker_alerts set ack_at = now(), ack_by = p_user where ack_at is null;
  else
    update tracker_alerts set ack_at = now(), ack_by = p_user, ack_note = left(nullif(btrim(p ->> 'note'), ''), 300)
     where id = (p ->> 'id')::uuid and ack_at is null;
  end if;
  get diagnostics n = row_count;
  return jsonb_build_object('acknowledged', n);
end $$;

-- ================================================================ 8. the hourly job: quiet trackers and retention
create or replace function app.job_tracker(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s tracker_settings := app.tracker_settings();
  st tracker_status;
  d tracker_devices;
  v_closed integer := 0; v_offline integer := 0; v_points bigint := 0; v_trips bigint := 0; v_alerts bigint := 0;
begin
  -- a trip whose tracker went quiet for 30 minutes ends at its last report
  for st in select * from tracker_status where trip_started_at is not null and reported_at < p_now - interval '30 minutes' for update skip locked loop
    select * into d from tracker_devices where id = st.tracker_device_id;
    if d.status = 'installed' then
      perform app.tracker_close_trip(d.vehicle_id, st, st.reported_at, st.latitude, st.longitude, st.odometer_km, 'quiet');
    end if;
    update tracker_status set trip_started_at = null, trip_start_lat = null, trip_start_lng = null, trip_start_odometer = null, trip_m = 0,
                              trip_max_kmh = null, trip_alerted = false
     where tracker_device_id = st.tracker_device_id;
    v_closed := v_closed + 1;
  end loop;
  -- a tracker on a car that stopped reporting (rental agreement 12.3, ground 5)
  for st in select ts.* from tracker_status ts join tracker_devices x on x.id = ts.tracker_device_id
             where x.status = 'installed' and x.vehicle_id is not null and not ts.offline_alerted and ts.reported_at > '-infinity'
               and ts.reported_at < p_now - make_interval(hours => s.offline_hours) for update of ts skip locked loop
    select * into d from tracker_devices where id = st.tracker_device_id;
    perform app.tracker_alert('offline', d.id, d.vehicle_id, app.tracker_booking_at(d.vehicle_id, p_now), st.reported_at, st.latitude, st.longitude, null,
      format('Tracker not reporting: %s', app.tracker_car_label(d.vehicle_id)),
      format('Last report %s (more than %s hours ago).', app.fmt_at(st.reported_at), s.offline_hours),
      'offline:' || d.id || ':' || extract(epoch from st.reported_at)::bigint);
    update tracker_status set offline_alerted = true where tracker_device_id = st.tracker_device_id;
    v_offline := v_offline + 1;
  end loop;
  -- retention, a slice at a time (each run at most 50,000 points)
  delete from tracker_points where ctid in (select ctid from tracker_points where at < p_now - make_interval(days => s.history_days) limit 50000);
  get diagnostics v_points = row_count;
  delete from tracker_trips where started_at < p_now - make_interval(days => s.trip_days);
  get diagnostics v_trips = row_count;
  delete from tracker_alerts where created_at < p_now - make_interval(days => s.trip_days) and ack_at is not null;
  get diagnostics v_alerts = row_count;
  return jsonb_build_object('trips_closed', v_closed, 'offline', v_offline, 'points_deleted', v_points, 'trips_deleted', v_trips, 'alerts_deleted', v_alerts);
end $$;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-tracker', '23 * * * *', $q$select app.job_tracker()$q$);
  end if;
end $$;

-- ================================================================ 9. "Tracker seen" from the hot row
do $$
declare
  f record;
  v_old text := $o$'tracker_seen', (select max(t.last_seen_at) from tracker_devices t where t.vehicle_id = v.id and t.removed_at is null))$o$;
  v_new text := $n$'tracker_seen', (select max(greatest(t.last_seen_at, nullif(s.reported_at, '-infinity'))) from tracker_devices t left join tracker_status s on s.tracker_device_id = t.id where t.vehicle_id = v.id and t.removed_at is null))$n$;
  n integer := 0;
begin
  for f in select p.oid::regprocedure as sig, pg_get_functiondef(p.oid) as def from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
            where ns.nspname = 'app' and p.prokind = 'f' and position(v_old in pg_get_functiondef(p.oid)) > 0 loop
    execute replace(f.def, v_old, v_new);
    n := n + 1;
  end loop;
  if n = 0 then raise exception '0400: the cars list''s Tracker seen was not found'; end if;
end $$;

-- ================================================================ the Live map knows demo mode
alter function app.live_map(uuid, jsonb) rename to live_map_pre0400;
create function app.live_map(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.live_map_pre0400(p_by, p);
begin
  if v is null then return v; end if;
  return v || jsonb_build_object('tracker_demo', (app.tracker_settings()).demo);
end $$;

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0400;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'ops_read' and p_name in ('tracker_fleet', 'tracker_trip_path') then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'tracker_fleet' then app.tracker_fleet(p_user, coalesce(p, '{}'::jsonb) - '_va')
                       else app.tracker_trip_path(p_user, coalesce(p, '{}'::jsonb)) end;
  end if;
  if p_call = 'ops_do' and p_name in ('tracker_pair', 'tracker_unpair', 'tracker_settings_save', 'tracker_key_new', 'tracker_alert_ack') then
    perform app.door_begin(p_user, p_aal);
    return case p_name
      when 'tracker_pair' then app.tracker_pair(p_user, coalesce(p, '{}'::jsonb))
      when 'tracker_unpair' then app.tracker_unpair(p_user, coalesce(p, '{}'::jsonb))
      when 'tracker_settings_save' then app.tracker_settings_save(p_user, coalesce(p, '{}'::jsonb) - '_va')
      when 'tracker_key_new' then app.tracker_key_new(p_user)
      else app.tracker_alert_ack(p_user, coalesce(p, '{}'::jsonb)) end;
  end if;
  return app.door_pre0400(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ the website's calls (service role)
create or replace function public.server_tracker_ingest(p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.tracker_ingest(p) $$;
create or replace function public.server_tracker_ingest_key() returns text
language sql stable security invoker set search_path = public, app as $$ select app.tracker_ingest_key() $$;

-- ================================================================ privileges
do $$
declare
  g text;
  pair text[];
  f text;
begin
  foreach pair slice 1 in array array[
      array['app.live_map(uuid, jsonb)', 'app.live_map_pre0400(uuid, jsonb)'],
      array['app.door(uuid, text, text, text, jsonb)', 'app.door_pre0400(uuid, text, text, text, jsonb)']] loop
    execute format('revoke all on function %s from public, anon, authenticated', pair[1]);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, pair[2]::regprocedure, 'execute') then execute format('grant execute on function %s to %I', pair[1], g); end if;
    end loop;
    execute format('revoke all on function %s from public, anon, authenticated', pair[2]);
    execute format('grant execute on function %s to service_role', pair[2]);
  end loop;
  foreach f in array array['app.tracker_settings()', 'app.tracker_car_photo(uuid)', 'app.tracker_booking_at(uuid, timestamptz)',
      'app.tracker_alert(text, uuid, uuid, uuid, timestamptz, numeric, numeric, numeric, text, text, text)', 'app.tracker_car_label(uuid)',
      'app.tracker_close_trip(uuid, tracker_status, timestamptz, numeric, numeric, numeric, text)', 'app.tracker_ingest(jsonb)',
      'app.tracker_finish(tracker_status, tracker_devices, tracker_settings, timestamptz)', 'app.tracker_ingest_key()', 'app.tracker_assert(uuid, boolean)',
      'app.tracker_fleet(uuid, jsonb)', 'app.tracker_trip_path(uuid, jsonb)', 'app.tracker_pair(uuid, jsonb)', 'app.tracker_unpair(uuid, jsonb)',
      'app.tracker_settings_save(uuid, jsonb)', 'app.tracker_key_new(uuid)', 'app.tracker_alert_ack(uuid, jsonb)', 'app.job_tracker(timestamptz)',
      'public.server_tracker_ingest(jsonb)', 'public.server_tracker_ingest_key()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
  -- pure helpers, no data
  foreach f in array array['app.tracker_num(text, numeric, numeric)', 'app.tracker_bool(jsonb)', 'app.tracker_time(jsonb)',
      'app.tracker_km(numeric, numeric, numeric, numeric)', 'app.tracker_in_ontario(numeric, numeric)'] loop
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $$;
