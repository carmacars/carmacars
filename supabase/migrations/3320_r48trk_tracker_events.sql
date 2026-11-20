-- 3320 (release 48, part TRK; docs/changes/2026-11-20-r48-tracker-alerts.md): tracker events, their evidence and the pound database.
-- The owner (Nov 20): tracker events create alerts, never a flood; the renter is told plainly what happened, the fee and
-- the clause; the car's owner is told too; Admin and Fleet get an evidence record per event that goes into the evidence
-- registry and the dispute kit; a car parked at a known pound flags the booking and opens the recovery fee path.
-- The trackers are not installed yet: all of it is behind Tracking settings > "Tracker events" (tracker_settings.events_on,
-- off). Off, the ingest and the alerts are exactly those of 0400.
--
-- 1. Settings (tracker_settings): events_on, renter_notices, owner_notices, event_window_minutes (one alert per car, kind
--    and window: 30), harsh driving (on, the change of speed a second, how many in the window), driving at night (off,
--    its hours), the pound radius and minutes parked, the ingest's requests a minute. The speeding charges stay the
--    Program settings of 3102 (speeding_180/220/300_fee_cents: $500, $1,000, $2,500), the recovery charges those of 3190.
-- 2. tracker_alerts gains the kinds harsh_driving, after_hours (driving at night), tamper and pound, and tier (a speeding
--    record over 180, 220 or 300 km/h), source (tracker reading, device event, worked out from readings, job), fee_code,
--    clause, facts, the notices sent and the fee line once charged.
-- 3. The ingest (app.tracker_ingest, wrapped): a point may carry "event" (harsh_brake, harsh_accel, harsh_turn, tamper).
--    Before the batch moves the hot rows, app.tracker_events_scan reads the new points of paired trackers: a speeding
--    record at the highest limit passed (the fastest reading), harsh driving (device events, or a change of speed
--    between two readings 1 to 10 seconds apart), tampering, driving at night. One alert per car, kind and window: a
--    higher speeding limit passed later in the window raises the same record (and tells the renter the new charge), it
--    never makes a second one. After the batch, the pound scan and the evidence readings.
-- 4. tracker_evidence: one record per alert (the map point, speed, time, source, the readings 5 minutes each side, a
--    SHA-256 seal), kept when the alert is deleted. app.tracker_alert_charge bills an event with its evidence attached
--    through the existing paths (app.speeding_charge_add, app.return_charge_add); the evidence registry
--    (app.fee_evidence_have) and the dispute kit (public.server_dispute_evidence, tracker_events) read it.
-- 5. Notices (catalogue rows in 3321): renter_tracker_notice (a fee or a breach: always sent), renter_driving_notice (a
--    heads-up with no fee: the renter may mute it), owner_tracker_alert (the car's owner, no renter or booking: may be
--    muted), staff_pound_flag (Fleet and Admins). Staff keep staff_tracker_alert (0400) for every kind.
-- 6. The pound database: pound_lots (name, address, phone, hours, pin, radius), Admin edits; seeded with the lots the
--    Toronto and Peel police publish, without pins (the website finds each pin from the address). A car parked inside a
--    lot's radius for pound_minutes: the alert, a pound_flags row on the booking, an urgent Fleet To do and email, and
--    app.pound_flag_resolve records the path: the non-return or theft recovery charge with the costs (3190), recovered
--    with no charge, or not a pound.
-- No applied migration is edited: app.tracker_ingest, app.tracker_settings_save, app.job_tracker, app.fee_evidence_have,
-- public.server_dispute_evidence and app.door are wrapped (_pre3320).
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

-- ================================================================ 1. settings
alter table tracker_settings
  add column if not exists events_on            boolean not null default false,
  add column if not exists renter_notices       boolean not null default true,
  add column if not exists owner_notices        boolean not null default true,
  add column if not exists event_window_minutes integer not null default 30 check (event_window_minutes between 5 and 1440),
  add column if not exists harsh_on             boolean not null default true,
  add column if not exists harsh_kmh_per_s      numeric(4, 1) not null default 14 check (harsh_kmh_per_s between 5 and 40),
  add column if not exists harsh_count          integer not null default 3 check (harsh_count between 1 and 20),
  add column if not exists night_on             boolean not null default false,
  add column if not exists night_from           time not null default '00:00',
  add column if not exists night_to             time not null default '05:00',
  add column if not exists pound_radius_m       integer not null default 150 check (pound_radius_m between 30 and 1000),
  add column if not exists pound_minutes        integer not null default 20 check (pound_minutes between 0 and 720),
  add column if not exists ingest_per_minute    integer not null default 240 check (ingest_per_minute between 10 and 6000);
comment on column tracker_settings.events_on is 'Tracker events (3320): on, tracker events make evidence records, renter and owner notices, speeding records per limit, harsh driving, tampering and pound alerts. Off (until the trackers are installed): the alerts of 0400 only, to staff.';
comment on column tracker_settings.event_window_minutes is 'Tracker events (3320): one alert per car and kind in this many minutes, never a flood.';
comment on column tracker_settings.harsh_kmh_per_s is 'Harsh driving (3320): a change of speed of this many km/h a second between two readings 1 to 10 seconds apart counts as one (14 is about 0.4 g).';
comment on column tracker_settings.ingest_per_minute is 'The tracker ingest (3320): signed requests accepted a minute; more are answered 429 and the relay retries.';

-- ================================================================ 2. alerts, evidence, the pound tables
alter table tracker_alerts drop constraint if exists tracker_alerts_kind_check;
alter table tracker_alerts add constraint tracker_alerts_kind_check check (kind in ('speeding', 'left_ontario', 'left_zone', 'overdue_driving', 'battery_low', 'unplugged', 'offline',
  'harsh_driving', 'after_hours', 'tamper', 'pound'));
alter table tracker_alerts
  add column if not exists tier             smallint check (tier in (180, 220, 300)),
  add column if not exists source           text not null default 'reading' check (source in ('reading', 'device_event', 'derived', 'job')),
  add column if not exists fee_code         text references fee_types (code),
  add column if not exists clause           text,
  add column if not exists facts            jsonb not null default '{}'::jsonb check (jsonb_typeof(facts) = 'object'),
  add column if not exists renter_notice_at timestamptz,
  add column if not exists owner_notice_at  timestamptz,
  add column if not exists line_item_id     uuid references booking_line_items (id) on delete set null;
create index if not exists tracker_alerts_vehicle_kind on tracker_alerts (vehicle_id, kind, at desc);
create index if not exists tracker_alerts_booking on tracker_alerts (booking_id) where booking_id is not null;
create index if not exists tracker_alerts_line on tracker_alerts (line_item_id) where line_item_id is not null;
create index if not exists tracker_alerts_fee on tracker_alerts (fee_code) where fee_code is not null;
comment on column tracker_alerts.tier is 'A speeding record (3320): the limit passed, 180, 220 or 300 km/h (rental agreement 10.5). Null: the speeding alert level of Tracking settings, with no charge.';
comment on column tracker_alerts.source is 'Where the event comes from (3320): reading (a tracker reading), device_event (the tracker''s own alarm), derived (worked out from readings), job (the hourly check).';

create table pound_lots (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(btrim(name)) between 2 and 120),
  address     text not null check (char_length(btrim(address)) between 5 and 240),
  city        text check (char_length(city) <= 80),
  phone       text check (char_length(phone) <= 40),
  hours       text check (char_length(hours) <= 240),
  serves      text check (char_length(serves) <= 240),
  latitude    numeric(8, 5) check (latitude between 41 and 57),
  longitude   numeric(8, 5) check (longitude between -96 and -74),
  radius_m    integer check (radius_m between 30 and 1000),
  source_url  text check (char_length(source_url) <= 400),
  notes       text check (char_length(notes) <= 1000),
  is_active   boolean not null default true,
  checked_at  timestamptz,
  checked_by  uuid references users (id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  updated_by  uuid references users (id) on delete set null,
  check ((latitude is null) = (longitude is null))
);
create unique index pound_lots_name_address on pound_lots (lower(btrim(name)), lower(btrim(address)));
create index pound_lots_checked_by on pound_lots (checked_by) where checked_by is not null;
create index pound_lots_updated_by on pound_lots (updated_by) where updated_by is not null;
comment on table pound_lots is 'The pound database (3320): known Ontario impound and pound lots (name, address, phone, hours), edited in Admin > Cars > Fleet tracking. A tracker parked within radius_m (Tracking settings when empty) of a lot with a pin flags the booking. checked_at: an Admin confirmed the details.';

create table tracker_evidence (
  id           uuid primary key default gen_random_uuid(),
  alert_id     uuid unique references tracker_alerts (id) on delete set null,
  kind         text not null,
  tier         smallint,
  vehicle_id   uuid not null references vehicles (id) on delete cascade,
  booking_id   uuid references bookings (id) on delete set null,
  device       text,
  at           timestamptz not null,
  lat          numeric(8, 5),
  lng          numeric(8, 5),
  speed_kmh    smallint,
  source       text not null,
  title        text not null,
  detail       text,
  fee_code     text references fee_types (code),
  clause       text,
  facts        jsonb not null default '{}'::jsonb,
  readings     jsonb not null default '[]'::jsonb check (jsonb_typeof(readings) = 'array'),
  sealed_at    timestamptz,
  sha256       text,
  line_item_id uuid references booking_line_items (id) on delete set null,
  pound_lot_id uuid references pound_lots (id) on delete set null,
  created_at   timestamptz not null default now()
);
create index tracker_evidence_vehicle on tracker_evidence (vehicle_id, at desc);
create index tracker_evidence_booking on tracker_evidence (booking_id) where booking_id is not null;
create index tracker_evidence_line on tracker_evidence (line_item_id) where line_item_id is not null;
create index tracker_evidence_open on tracker_evidence (at) where sealed_at is null;
create index tracker_evidence_fee on tracker_evidence (fee_code) where fee_code is not null;
create index tracker_evidence_lot on tracker_evidence (pound_lot_id) where pound_lot_id is not null;
comment on table tracker_evidence is 'The evidence record of a tracker event (3320): the map point, speed, time and source, the readings 5 minutes each side (sealed 10 minutes after the event with a SHA-256 of the record), the fee and the clause. Kept when the alert is deleted; linked to the fee line once charged, where the evidence registry (3190) and the dispute kit (3192) read it.';

create table tracker_harsh (
  vehicle_id uuid not null references vehicles (id) on delete cascade,
  at         timestamptz not null,
  kind       text not null check (kind in ('harsh_brake', 'harsh_accel', 'harsh_turn')),
  source     text not null check (source in ('device_event', 'derived')),
  delta_kmh  smallint,
  speed_kmh  smallint,
  lat        numeric(8, 5),
  lng        numeric(8, 5)
);
create index tracker_harsh_vehicle_at on tracker_harsh (vehicle_id, at);
comment on table tracker_harsh is 'Harsh driving marks (3320): one row per hard brake, hard acceleration or sharp turn (the tracker''s own event, or a change of speed between two readings). harsh_count of them in the window make one alert. Telemetry: no row audit, deleted with the position history.';

create table pound_flags (
  id            uuid primary key default gen_random_uuid(),
  alert_id      uuid unique references tracker_alerts (id) on delete set null,
  evidence_id   uuid references tracker_evidence (id) on delete set null,
  pound_lot_id  uuid references pound_lots (id) on delete set null,
  lot_name      text not null,
  lot_address   text,
  vehicle_id    uuid not null references vehicles (id) on delete cascade,
  booking_id    uuid references bookings (id) on delete set null,
  since         timestamptz not null,
  status        text not null default 'open' check (status in ('open', 'charged', 'recovered', 'dismissed')),
  path          text check (path in ('non_return', 'theft_recovery', 'no_charge', 'not_a_pound')),
  note          text check (char_length(note) <= 1000),
  lines         jsonb not null default '[]'::jsonb,
  resolved_at   timestamptz,
  resolved_by   uuid references users (id) on delete set null,
  created_at    timestamptz not null default now(),
  check ((status = 'open') = (resolved_at is null))
);
create index pound_flags_open on pound_flags (created_at desc) where status = 'open';
create index pound_flags_booking on pound_flags (booking_id) where booking_id is not null;
create index pound_flags_vehicle on pound_flags (vehicle_id);
create index pound_flags_lot on pound_flags (pound_lot_id) where pound_lot_id is not null;
create index pound_flags_evidence on pound_flags (evidence_id) where evidence_id is not null;
create index pound_flags_resolved_by on pound_flags (resolved_by) where resolved_by is not null;
comment on table pound_flags is 'A car parked at a known pound (3320): the flag on its booking, with the path Fleet recorded: the non-return or theft recovery charge with the recovery costs (3190), recovered with no charge, or not a pound.';

alter table tracker_status
  add column if not exists pound_lot_id uuid,
  add column if not exists pound_since  timestamptz;

create table app.tracker_ingest_seen (
  sig text primary key check (sig ~ '^[0-9a-f]{64}$'),
  at  timestamptz not null default now()
);
create index tracker_ingest_seen_at on app.tracker_ingest_seen (at);
comment on table app.tracker_ingest_seen is 'The tracker ingest''s replay guard (3320): the signature of each request accepted in the last 10 minutes (the signature covers the timestamp and the body, and a timestamp is refused after 5 minutes). The same signed request twice is refused.';
alter table app.tracker_ingest_seen enable row level security;
revoke all on app.tracker_ingest_seen from public, anon, authenticated;
grant all on app.tracker_ingest_seen to service_role;

do $$
declare t text;
begin
  foreach t in array array['pound_lots', 'tracker_evidence', 'tracker_harsh', 'pound_flags'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from anon, authenticated', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
    execute format('create policy staff_read on %I for select to authenticated using (app.is_staff())', t);
    execute format('grant select on %I to authenticated', t);
    execute format('grant all on %I to service_role', t);
  end loop;
end $$;
create trigger audit_pound_lots after insert or update or delete on pound_lots for each row execute function app.audit_row();
create trigger audit_tracker_evidence after insert or update or delete on tracker_evidence for each row execute function app.audit_row();
create trigger audit_pound_flags after insert or update or delete on pound_flags for each row execute function app.audit_row();

-- the row audit (0013) leaves the telemetry alone: tracker_harsh joins the list of 0400
do $$
declare d text := pg_get_functiondef('app.attach_audit()'::regprocedure);
begin
  if position('''tracker_harsh''' in d) = 0 then
    if position('''tracker_trips'',' in d) = 0 then raise exception '3320: app.attach_audit has no telemetry list to extend'; end if;
    execute replace(d, '''tracker_trips'',', '''tracker_trips'', ''tracker_harsh'',');
  end if;
end $$;

-- the lots the police services publish (Toronto Police Service "Have you been towed?", Peel Regional Police "Towed and
-- Seized Vehicles", read 2026-11-20). No pins: the website finds each from the address (Admin > Cars > Fleet tracking >
-- Pound lots > Find the pins), and an Admin confirms the details (checked_at).
insert into pound_lots (name, address, city, phone, serves, source_url) values
  ('Classic Towing', '41 Westside Drive, Toronto, ON M9C 1B3', 'Toronto', '416-604-3222', 'Toronto Police: west', 'https://tps.ca/services/towing/'),
  ('Abrams Towing Service Ltd.', '124 Lepage Court, Toronto, ON M3J 1Z9', 'Toronto', '416-636-7006', 'Toronto Police: central', 'https://tps.ca/services/towing/'),
  ('JP Towing Service & Storage Ltd.', '11 Glen Scarlett Road, Toronto, ON M6N 1P5', 'Toronto', '416-203-9300', 'Toronto Police: downtown', 'https://tps.ca/services/towing/'),
  ('Williams Towing Service Ltd.', '2671 Markham Road, Toronto, ON M1X 1M4', 'Toronto', '416-299-8383', 'Toronto Police: east', 'https://tps.ca/services/towing/'),
  ('Lyons Auto Body Limited', '1020 Burnhamthorpe Road West, Mississauga, ON', 'Mississauga', '905-277-1456', 'Peel Police: 11 Division; heavy towing for 12 and Airport Divisions', 'https://www.peelpolice.ca/reporting-records/towed-and-seized-vehicles/'),
  ('Atlantic Towing', '6121 Atlantic Avenue, Mississauga, ON', 'Mississauga', '905-564-7072', 'Peel Police: 12 Division and Airport Division (light towing)', 'https://www.peelpolice.ca/reporting-records/towed-and-seized-vehicles/'),
  ('J A Towing', '69 Eastern Avenue, Brampton, ON', 'Brampton', '905-459-1444', 'Peel Police: 21 and 22 Divisions', 'https://www.peelpolice.ca/reporting-records/towed-and-seized-vehicles/')
on conflict do nothing;

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  ('pound_recovery', 'fleet', 'A car is parked at a pound: recover it', 'urgent', 'business_days', 1, 8, null,
   'The tracker shows a car parked at a known impound or pound lot (3320). Call the lot and the renter, recover the car, then record the path on Cars > Fleet tracking > Pound flags: the non-return or theft recovery charge with the tow, impound and storage receipts (rental agreement 10.6 and 10.8), recovered with no charge, or not a pound.')
on conflict (task_type) do update set title = excluded.title, description = excluded.description, priority = excluded.priority, queue = excluded.queue;

-- the staff notices of the new kinds, each with its switch beside the tracker rules of 0462 (Settings > Alerts): off, the
-- kind still makes its alert, evidence record and To do, but no notice to staff (app.notification_recipients, 3321)
insert into staff_alert_rules (rule, label, grp, who, tier, topic, enabled, wired, fixed, hint, sort)
values ('tracker_pound', 'A car is parked at a pound', 'Fleet and cars', '{admin,on_duty:fleet}', 'urgent', 'alerts', true, true, false,
        'Sent by the tracker (3320) as urgent, with an email, when a car is parked at a known impound or pound lot: the booking is flagged and Fleet has a To do.', 130),
       ('tracker_tamper', 'Tracker tampering', 'Fleet and cars', '{admin,on_duty:fleet}', 'urgent', 'alerts', true, true, false,
        'Sent by the tracker (3320) as urgent when it reports tampering (its case opened or it was taken off).', 131),
       ('tracker_harsh', 'Harsh driving', 'Fleet and cars', '{admin,on_duty:fleet}', 'urgent', 'alerts', true, true, false,
        'Sent by the tracker (3320) once per car and window: several hard braking or acceleration events. The count is in Tracker event settings.', 132),
       ('tracker_night', 'Driving at night', 'Fleet and cars', '{admin,on_duty:fleet}', 'urgent', 'alerts', true, true, false,
        'Sent by the tracker (3320) once per car and night, when driving at night is on in Tracker event settings.', 133)
on conflict (rule) do nothing;

-- ================================================================ 3. what an event means: the fee, the clause, who is told
-- renter: 'notice' (a fee or a breach, always sent), 'heads_up' (no fee, may be muted) or null (staff only)
create function app.tracker_event_terms(p_kind text, p_tier integer default null) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case
    when p_kind = 'speeding' and p_tier is not null then jsonb_build_object('fee_code', 'speeding_' || p_tier,
      'fee_cents', case p_tier when 180 then (x.s).speeding_180_fee_cents when 220 then (x.s).speeding_220_fee_cents else (x.s).speeding_300_fee_cents end,
      'clause', '10.5 Speeding charges', 'renter', 'notice', 'owner', true, 'charge', 'speeding')
    when p_kind = 'speeding' then jsonb_build_object('clause', '10.5 Speeding charges', 'renter', 'heads_up', 'owner', true)
    when p_kind = 'harsh_driving' then jsonb_build_object('clause', '9 Damage; 10.2 Prohibited uses', 'renter', 'heads_up', 'owner', true)
    when p_kind = 'left_ontario' then jsonb_build_object('clause', '10.1 Area; 12.3 Grounds', 'renter', 'notice', 'owner', true)
    when p_kind = 'left_zone' then jsonb_build_object('owner', true)
    when p_kind = 'overdue_driving' then jsonb_build_object('fee_code', 'late_return_fee', 'clause', '3.2 Extensions and late return; Part 3 Late return fee', 'renter', 'notice', 'owner', true)
    when p_kind = 'after_hours' then jsonb_build_object('owner', true)
    when p_kind in ('unplugged', 'tamper') then jsonb_build_object('clause', '10.4 Care; 12.3 Grounds (5); 12.4 Disabling', 'renter', 'notice', 'owner', true)
    when p_kind = 'pound' then jsonb_build_object('fee_code', 'non_return_fee', 'fee_cents', (x.s).non_return_fee_cents, 'theft_fee_cents', (x.s).theft_recovery_fee_cents,
      'clause', '6 Tolls, tickets and fines; 10.6 Non-return; 10.8 Theft recovery', 'renter', 'notice', 'owner', true, 'charge', 'pound')
    else '{}'::jsonb end
  from (select app.settings() as s) x
$$;

-- the words of a notice: the renter's (what happened, the fee, the clause, what we ask) and the owner's (no renter, no booking)
create function app.tracker_event_words(a tracker_alerts) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  t jsonb := app.tracker_event_terms(a.kind, a.tier);
  v_car text := coalesce(app.vehicle_name(a.vehicle_id), 'the car');
  v_when text := app.fmt_at(a.at);
  v_speed text := coalesce(a.speed_kmh::text, '');
  v_fee text := case when (t ->> 'fee_cents') is not null then app.fmt_money((t ->> 'fee_cents')::bigint) end;
  v_title text; v_what text; v_fee_line text; v_ask text; v_short text; v_owner text;
begin
  case
    when a.kind = 'speeding' and a.tier is not null then
      v_title := format('Speeding over %s km/h', a.tier);
      v_what := format('The Tracker in your %s recorded %s km/h on %s.', v_car, v_speed, v_when);
      v_fee_line := format('A speeding charge of %s plus HST applies (over %s km/h). It is taken from your Deposit first, and you get the Tracker''s time, place and speed with it.', v_fee, a.tier);
      v_ask := 'Please slow down. Driving faster than 180 km/h is never allowed, and each new record is a new charge.';
      v_short := format('%s km/h recorded. A %s charge applies (agreement 10.5). Please slow down.', v_speed, v_fee);
      v_owner := format('Your %s was recorded at %s km/h on %s. CarmaCars has told the renter and the speeding charge applies.', v_car, v_speed, v_when);
    when a.kind = 'speeding' then
      v_title := 'Please slow down';
      v_what := format('The Tracker in your %s recorded %s km/h on %s.', v_car, v_speed, v_when);
      v_fee_line := format('No charge this time. Over 180 km/h there is a speeding charge of %s plus HST, each time the Tracker records it.', app.fmt_money((app.settings()).speeding_180_fee_cents));
      v_ask := 'Please ease off and keep to the limit. Thank you.';
      v_short := format('%s km/h recorded. No charge this time. Please slow down.', v_speed);
      v_owner := format('Your %s was recorded at %s km/h on %s. CarmaCars has asked the renter to slow down.', v_car, v_speed, v_when);
    when a.kind = 'harsh_driving' then
      v_title := 'Easy on the car, please';
      v_what := format('The Tracker in your %s recorded %s hard braking or acceleration events around %s.', v_car, coalesce(a.facts ->> 'count', 'several'), v_when);
      v_fee_line := 'No charge. Damage or wear caused by rough driving is yours under the agreement.';
      v_ask := 'Please take it easy: smooth braking and acceleration. Thank you.';
      v_short := 'Hard braking or acceleration recorded. No charge. Please take it easy.';
      v_owner := format('Your %s recorded %s hard braking or acceleration events around %s. CarmaCars has asked the renter to take it easy.', v_car, coalesce(a.facts ->> 'count', 'several'), v_when);
    when a.kind = 'left_ontario' then
      v_title := 'Your rental has left Ontario';
      v_what := format('The Tracker shows your %s outside Ontario on %s.', v_car, v_when);
      v_fee_line := 'No set charge. Without our written consent this is a breach of the agreement: we may end the rental and recover the car, at your cost.';
      v_ask := 'Please call us now, or head back into Ontario.';
      v_short := 'The car is outside Ontario, which the agreement does not allow (10.1). Please call us now.';
      v_owner := format('Your %s left Ontario on %s. CarmaCars is contacting the renter.', v_car, v_when);
    when a.kind = 'left_zone' then
      v_title := 'Outside the zone';
      v_owner := format('Your %s left the area CarmaCars watches on %s. CarmaCars is looking into it.', v_car, v_when);
    when a.kind = 'overdue_driving' then
      v_title := 'Your rental is past its return time';
      v_what := format('The Tracker shows your %s still driving on %s, after the return time.', v_car, v_when);
      v_fee_line := 'The late return fee and the rental charge for each extra day keep adding up until the car is back.';
      v_ask := 'Please return the car now, or call us to extend.';
      v_short := 'The car is past its return time and still driving. Late fees are adding up. Please return it or call us.';
      v_owner := format('Your %s was still driving after its return time on %s. CarmaCars is contacting the renter.', v_car, v_when);
    when a.kind = 'after_hours' then
      v_title := 'Driving at night';
      v_owner := format('Your %s was driving at night on %s.', v_car, v_when);
    when a.kind in ('unplugged', 'tamper') then
      v_title := 'The Tracker in your rental needs attention';
      v_what := format('The Tracker in your %s %s on %s.', v_car, case a.kind when 'unplugged' then 'lost the car''s power' else 'reported tampering' end, v_when);
      v_fee_line := 'No set charge. Damage to the Tracker is charged at cost, and if we cannot reach you we may end the rental and disable the car once it is parked.';
      v_ask := 'Please call us now so we can sort it out together.';
      v_short := 'The Tracker in your rental needs attention (agreement 10.4). Please call us now.';
      v_owner := format('The tracker in your %s %s on %s. CarmaCars is contacting the renter.', v_car, case a.kind when 'unplugged' then 'lost the car''s power' else 'reported tampering' end, v_when);
    when a.kind = 'pound' then
      v_title := 'Your rental is at an impound lot';
      v_what := format('The Tracker shows your %s parked at %s (%s) since %s.', v_car, coalesce(a.facts ->> 'lot_name', 'an impound lot'), coalesce(a.facts ->> 'lot_address', 'address on file'), v_when);
      v_fee_line := format('The towing, impound and storage costs are yours, at cost. The non-return charge (%s) or the theft recovery charge (%s), plus HST, applies where section 10.6 or 10.8 does.',
                           v_fee, app.fmt_money((t ->> 'theft_fee_cents')::bigint));
      v_ask := 'Please call us now so we can get the car released.';
      v_short := 'The car is at an impound lot. Recovery costs apply (agreement 10.6). Please call us now.';
      v_owner := format('Your %s is parked at %s (%s). CarmaCars Fleet is recovering it and will keep you posted.', v_car, coalesce(a.facts ->> 'lot_name', 'an impound lot'), coalesce(a.facts ->> 'lot_address', 'address on file'));
    else
      v_title := a.title;
  end case;
  return jsonb_strip_nulls(jsonb_build_object('event_title', v_title, 'event_what', v_what, 'event_fee', v_fee_line,
    'event_clause', case when t ->> 'clause' is not null then 'Rental agreement: ' || (t ->> 'clause') || '.' end,
    'event_ask', v_ask, 'event_short', v_short, 'event_when', v_when, 'event_owner', v_owner,
    'event_map_url', case when a.lat is not null then format('https://www.google.com/maps?q=%s,%s', a.lat, a.lng) end));
end $$;

-- ================================================================ 4. the evidence record and the notices of every alert
create function app.tracker_alert_terms() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare t jsonb;
begin
  if (app.tracker_settings()).events_on then
    t := app.tracker_event_terms(new.kind, new.tier);
    new.fee_code := coalesce(new.fee_code, t ->> 'fee_code');
    new.clause := coalesce(new.clause, t ->> 'clause');
  end if;
  return new;
end $$;
create trigger tracker_alert_terms before insert on tracker_alerts for each row execute function app.tracker_alert_terms();

create function app.tracker_evidence_seal(e tracker_evidence) returns text
language sql stable as $$
  select encode(sha256(convert_to(concat_ws('|', e.id, e.kind, e.tier, e.vehicle_id, e.booking_id, e.device, to_char(e.at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    e.lat, e.lng, e.speed_kmh, e.source, e.fee_code, e.clause, e.facts::text, e.readings::text), 'UTF8')), 'hex')
$$;

-- the readings 5 minutes each side of each open record; sealed once 10 minutes have passed (nothing more can arrive in order)
create function app.tracker_evidence_fill(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare e tracker_evidence; n integer := 0;
begin
  for e in select * from tracker_evidence where sealed_at is null order by at limit 200 for update skip locked loop
    e.readings := coalesce((select jsonb_agg(jsonb_build_object('at', t.at, 'speed_kmh', t.speed_kmh, 'lat', t.lat_e6 / 1e6, 'lng', t.lng_e6 / 1e6, 'ignition', t.ignition) order by t.at)
                              from tracker_points t where t.vehicle_id = e.vehicle_id and t.at between e.at - interval '5 minutes' and e.at + interval '5 minutes'), '[]'::jsonb);
    if e.at < p_now - interval '10 minutes' then e.sealed_at := p_now; end if;
    e.sha256 := app.tracker_evidence_seal(e);
    update tracker_evidence set readings = e.readings, sealed_at = e.sealed_at, sha256 = e.sha256 where id = e.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- the notices of one alert: the renter (while the car is out on their rental) and the car's owner. p_suffix: '' for a new
-- alert; ':<limit>' when a speeding record is raised to a higher limit inside its window (the earlier notice named the lower charge)
create function app.tracker_event_notify(a tracker_alerts, p_suffix text default '') returns void
language plpgsql security definer set search_path = public, app as $$
declare
  s tracker_settings := app.tracker_settings();
  t jsonb := app.tracker_event_terms(a.kind, a.tier);
  w jsonb := app.tracker_event_words(a);
  b bookings;
  v_owner uuid;
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
  -- the car's owner: the event and the place, never the renter or the booking
  if s.owner_notices and coalesce((t ->> 'owner')::boolean, false) and w ->> 'event_owner' is not null then
    select v.owner_id into v_owner from vehicles v where v.id = a.vehicle_id;
    if v_owner is not null then
      perform app.emit_event('owner_tracker_alert', 'vehicle', a.vehicle_id,
        (v_base - 'event_what' - 'event_fee' - 'event_ask' - 'event_short' - 'event_clause') || jsonb_build_object('owner_id', v_owner, 'event_what', w ->> 'event_owner',
           'event_short', left(w ->> 'event_owner', 110)), 'owner_tracker_alert:' || a.id || p_suffix);
      update tracker_alerts set owner_notice_at = now() where id = a.id;
    end if;
  end if;
end $$;

create function app.tracker_alert_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  s tracker_settings := app.tracker_settings();
  e tracker_evidence;
begin
  if not s.events_on or new.vehicle_id is null then return null; end if;
  begin
    -- the speeding alert level (0400) on a reading that also passed a limit: the record of the limit speaks for it
    if new.kind = 'speeding' and new.tier is null and exists (select 1 from tracker_alerts x where x.vehicle_id = new.vehicle_id and x.kind = 'speeding' and x.tier is not null
          and x.at between new.at - make_interval(mins => s.event_window_minutes) and new.at + make_interval(mins => s.event_window_minutes)) then
      return null;
    end if;
    insert into tracker_evidence (alert_id, kind, tier, vehicle_id, booking_id, device, at, lat, lng, speed_kmh, source, title, detail, fee_code, clause, facts, pound_lot_id)
    values (new.id, new.kind, new.tier, new.vehicle_id, new.booking_id, (select d.serial_number from tracker_devices d where d.id = new.device_id), new.at, new.lat, new.lng, new.speed_kmh,
            new.source, new.title, new.detail, new.fee_code, new.clause, new.facts, nullif(new.facts ->> 'lot_id', '')::uuid)
    on conflict (alert_id) do nothing
    returning * into e;
    if e.id is not null then update tracker_evidence set sha256 = app.tracker_evidence_seal(e) where id = e.id; end if;
    perform app.tracker_event_notify(new);
  exception when others then
    raise warning 'tracker event % not completed: %', new.id, sqlerrm;
  end;
  return null;
end $$;
create trigger tracker_alert_after after insert on tracker_alerts for each row execute function app.tracker_alert_after();

-- one event of this release: its alert (once per key) with the limit, the source and the facts, and the staff notices of 0400
create function app.tracker_event_raise(p_kind text, p_tier integer, p_source text, p_device uuid, p_vehicle uuid, p_at timestamptz, p_lat numeric, p_lng numeric, p_speed numeric,
                                        p_title text, p_detail text, p_key text, p_facts jsonb default '{}'::jsonb) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
  v_booking uuid := app.tracker_booking_at(p_vehicle, p_at);
  v_payload jsonb;
begin
  insert into tracker_alerts (kind, tier, source, device_id, vehicle_id, booking_id, at, lat, lng, speed_kmh, title, detail, dedupe_key, facts)
  values (p_kind, p_tier, p_source, p_device, p_vehicle, v_booking, p_at, round(p_lat, 5), round(p_lng, 5), round(p_speed)::smallint, left(p_title, 200), left(p_detail, 500), p_key, coalesce(p_facts, '{}'::jsonb))
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  if v_id is null then return null; end if;
  v_payload := jsonb_build_object('alert_title', left(p_title, 200), 'alert_detail', coalesce(left(p_detail, 500), ''), 'alert_id', v_id, 'alert_kind', p_kind,
                                  'vehicle_id', p_vehicle, 'booking_id', v_booking, 'booking_number', (select booking_number from bookings where id = v_booking));
  perform app.emit_event('staff_tracker_alert', 'vehicle', p_vehicle, v_payload, 'tracker_alert:' || v_id);
  perform app.emit_event('staff_tracker_alert_fleet', 'vehicle', p_vehicle, v_payload, 'tracker_alert_fleet:' || v_id);
  return v_id;
end $$;

-- a speeding record passes a higher limit inside its window: the same record, raised (never a second alert); the staff, the
-- renter and the owner are told the new limit and charge. A record already charged is left as it is (the caller makes a new one).
create function app.tracker_speeding_raise(p_alert uuid, p_tier integer, p_at timestamptz, p_lat numeric, p_lng numeric, p_speed numeric) returns boolean
language plpgsql security definer set search_path = public, app as $$
declare
  a tracker_alerts;
  e tracker_evidence;
  v_payload jsonb;
begin
  select * into a from tracker_alerts where id = p_alert for update;
  if a.id is null or a.line_item_id is not null or coalesce(a.tier, 0) >= p_tier then return false; end if;
  update tracker_alerts set tier = p_tier, at = p_at, lat = round(p_lat, 5), lng = round(p_lng, 5), speed_kmh = round(p_speed)::smallint,
         fee_code = 'speeding_' || p_tier, clause = app.tracker_event_terms('speeding', p_tier) ->> 'clause',
         title = left(format('Speeding over %s km/h: %s at %s km/h', p_tier, app.tracker_car_label(a.vehicle_id), round(p_speed)), 200),
         detail = left(format('Over %s km/h at %s (rental agreement 10.5: %s plus HST). Raised from over %s km/h in the same %s minutes.', p_tier, app.fmt_at(p_at),
                              app.fmt_money((app.tracker_event_terms('speeding', p_tier) ->> 'fee_cents')::bigint), a.tier, (app.tracker_settings()).event_window_minutes), 500),
         facts = facts || jsonb_build_object('limit_kmh', p_tier, 'raised_from', a.tier, 'first_at', a.at, 'first_speed_kmh', a.speed_kmh), ack_at = null, ack_by = null, ack_note = null
   where id = a.id returning * into a;
  update tracker_evidence set tier = a.tier, at = a.at, lat = a.lat, lng = a.lng, speed_kmh = a.speed_kmh, title = a.title, detail = a.detail, fee_code = a.fee_code, clause = a.clause,
         facts = a.facts, sealed_at = null where alert_id = a.id returning * into e;
  if e.id is not null then update tracker_evidence set sha256 = app.tracker_evidence_seal(e) where id = e.id; end if;
  v_payload := jsonb_build_object('alert_title', a.title, 'alert_detail', coalesce(a.detail, ''), 'alert_id', a.id, 'alert_kind', a.kind,
                                  'vehicle_id', a.vehicle_id, 'booking_id', a.booking_id, 'booking_number', (select booking_number from bookings where id = a.booking_id));
  perform app.emit_event('staff_tracker_alert', 'vehicle', a.vehicle_id, v_payload, 'tracker_alert:' || a.id || ':' || p_tier);
  perform app.emit_event('staff_tracker_alert_fleet', 'vehicle', a.vehicle_id, v_payload, 'tracker_alert_fleet:' || a.id || ':' || p_tier);
  perform app.tracker_event_notify(a, ':' || p_tier);
  return true;
end $$;

-- ================================================================ 5. the events of a batch, before it moves the hot rows
create function app.tracker_events_scan(p jsonb, s tracker_settings) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  pt record;
  v_now timestamptz := clock_timestamp();
  v_win interval := make_interval(mins => s.event_window_minutes);
  v_tier integer;
  v_n integer := 0;
  v_harsh text;
  v_count integer;
  v_local time;
  v_night boolean;
  v_car text;
  v_lower uuid;
begin
  if jsonb_typeof(p -> 'points') is distinct from 'array' then return 0; end if;
  -- speeding first, the fastest reading of each car first: one record per car and window at the highest limit passed
  -- (a slower reading of the same window finds the record there); a higher limit later in the window raises the record
  for pt in
    select r.at, r.lat, r.lng, r.speed, d.id as device_id, d.vehicle_id
      from (select nullif(btrim(x ->> 'device'), '') as dev, app.tracker_time(x -> 'at') as at, app.tracker_num(x ->> 'lat', -90, 90) as lat, app.tracker_num(x ->> 'lng', -180, 180) as lng,
                   app.tracker_num(x ->> 'speed', 0, 400) as speed
              from jsonb_array_elements(p -> 'points') x where jsonb_typeof(x) = 'object') r
      join lateral (select d.id, d.vehicle_id from tracker_devices d where (d.serial_number = r.dev or d.imei = r.dev) and d.status = 'installed' and d.vehicle_id is not null
                     order by (d.serial_number = r.dev) desc limit 1) d on true
      left join tracker_status ts on ts.tracker_device_id = d.id
     where r.dev ~ '^[A-Za-z0-9._:-]{3,64}$' and r.at is not null and r.lat is not null and r.lng is not null and not (r.lat = 0 and r.lng = 0) and r.speed > 180
       and r.at <= v_now + interval '10 minutes' and r.at > v_now - interval '7 days' and r.at > coalesce(ts.reported_at, '-infinity')
     order by d.id, r.speed desc, r.at
  loop
    v_tier := case when pt.speed > 300 then 300 when pt.speed > 220 then 220 else 180 end;
    if exists (select 1 from tracker_alerts a where a.vehicle_id = pt.vehicle_id and a.kind = 'speeding' and a.tier >= v_tier and a.at between pt.at - v_win and pt.at + v_win) then
      continue;
    end if;
    select a.id into v_lower from tracker_alerts a
     where a.vehicle_id = pt.vehicle_id and a.kind = 'speeding' and a.tier < v_tier and a.line_item_id is null and a.at between pt.at - v_win and pt.at + v_win
     order by a.tier desc, a.at desc limit 1;
    if v_lower is not null and app.tracker_speeding_raise(v_lower, v_tier, pt.at, pt.lat, pt.lng, pt.speed) then
      v_n := v_n + 1;
    elsif app.tracker_event_raise('speeding', v_tier, 'reading', pt.device_id, pt.vehicle_id, pt.at, pt.lat, pt.lng, pt.speed,
           format('Speeding over %s km/h: %s at %s km/h', v_tier, app.tracker_car_label(pt.vehicle_id), round(pt.speed)),
           format('Over %s km/h at %s (rental agreement 10.5: %s plus HST).', v_tier, app.fmt_at(pt.at), app.fmt_money((app.tracker_event_terms('speeding', v_tier) ->> 'fee_cents')::bigint)),
           'speed' || v_tier || ':' || pt.vehicle_id || ':' || extract(epoch from pt.at)::bigint, jsonb_build_object('limit_kmh', v_tier)) is not null then
      v_n := v_n + 1;
    end if;
  end loop;
  for pt in
    with raw as (
      select nullif(btrim(x ->> 'device'), '') as dev, app.tracker_time(x -> 'at') as at, app.tracker_num(x ->> 'lat', -90, 90) as lat, app.tracker_num(x ->> 'lng', -180, 180) as lng,
             app.tracker_num(x ->> 'speed', 0, 400) as speed, lower(nullif(btrim(x ->> 'event'), '')) as ev
        from jsonb_array_elements(p -> 'points') x where jsonb_typeof(x) = 'object'),
    pts as (
      select r.*, d.id as device_id, d.vehicle_id, nullif(ts.reported_at, '-infinity') as last_at, ts.speed_kmh as last_speed
        from raw r
        join lateral (select d.id, d.vehicle_id from tracker_devices d where (d.serial_number = r.dev or d.imei = r.dev) and d.status = 'installed' and d.vehicle_id is not null
                       order by (d.serial_number = r.dev) desc limit 1) d on true
        left join tracker_status ts on ts.tracker_device_id = d.id
       where r.dev ~ '^[A-Za-z0-9._:-]{3,64}$' and r.at is not null and r.lat is not null and r.lng is not null and not (r.lat = 0 and r.lng = 0)
         and r.at <= v_now + interval '10 minutes' and r.at > v_now - interval '7 days' and r.at > coalesce(ts.reported_at, '-infinity')),
    seq as (
      select q.*, coalesce(lag(q.speed) over w, q.last_speed) as prev_speed, coalesce(lag(q.at) over w, q.last_at) as prev_at
        from pts q window w as (partition by q.device_id order by q.at))
    select q.*, case when q.prev_at is not null and q.speed is not null and q.prev_speed is not null and extract(epoch from q.at - q.prev_at) between 1 and 10
                     then (q.speed - q.prev_speed) / extract(epoch from q.at - q.prev_at) end as rate
      from seq q
     order by q.device_id, q.at
  loop
    v_car := null;
    -- harsh driving: the tracker's own event, or a change of speed between two close readings
    v_harsh := case when pt.ev in ('harsh_brake', 'harsh_accel', 'harsh_turn') then pt.ev
                    when s.harsh_on and pt.rate is not null and abs(pt.rate) >= s.harsh_kmh_per_s then case when pt.rate < 0 then 'harsh_brake' else 'harsh_accel' end end;
    if s.harsh_on and v_harsh is not null then
      insert into tracker_harsh (vehicle_id, at, kind, source, delta_kmh, speed_kmh, lat, lng)
      values (pt.vehicle_id, pt.at, v_harsh, case when pt.ev = v_harsh then 'device_event' else 'derived' end, round(pt.speed - pt.prev_speed)::smallint, round(pt.speed)::smallint, round(pt.lat, 5), round(pt.lng, 5));
      select count(*) into v_count from tracker_harsh h where h.vehicle_id = pt.vehicle_id and h.at between pt.at - v_win and pt.at;
      if v_count >= s.harsh_count and not exists (select 1 from tracker_alerts a where a.vehicle_id = pt.vehicle_id and a.kind = 'harsh_driving' and a.at between pt.at - v_win and pt.at + v_win) then
        v_car := coalesce(v_car, app.tracker_car_label(pt.vehicle_id));
        if app.tracker_event_raise('harsh_driving', null, case when pt.ev = v_harsh then 'device_event' else 'derived' end, pt.device_id, pt.vehicle_id, pt.at, pt.lat, pt.lng, pt.speed,
             format('Harsh driving: %s', v_car), format('%s hard braking or acceleration events in %s minutes, the last at %s.', v_count, s.event_window_minutes, app.fmt_at(pt.at)),
             'harsh:' || pt.vehicle_id || ':' || extract(epoch from pt.at)::bigint,
             jsonb_build_object('count', v_count, 'marks', (select jsonb_agg(jsonb_build_object('at', h.at, 'kind', h.kind, 'source', h.source, 'delta_kmh', h.delta_kmh, 'speed_kmh', h.speed_kmh, 'lat', h.lat, 'lng', h.lng) order by h.at)
                                                              from tracker_harsh h where h.vehicle_id = pt.vehicle_id and h.at between pt.at - v_win and pt.at))) is not null then
          v_n := v_n + 1;
        end if;
      end if;
    end if;
    -- the tracker reports tampering (its case opened or it was taken off)
    if pt.ev in ('tamper', 'removed', 'case_open')
       and not exists (select 1 from tracker_alerts a where a.vehicle_id = pt.vehicle_id and a.kind = 'tamper' and a.at between pt.at - v_win and pt.at + v_win) then
      v_car := coalesce(v_car, app.tracker_car_label(pt.vehicle_id));
      if app.tracker_event_raise('tamper', null, 'device_event', pt.device_id, pt.vehicle_id, pt.at, pt.lat, pt.lng, pt.speed,
           format('Tracker tampering: %s', v_car), format('The tracker reported tampering at %s (rental agreement 10.4 and 12.3).', app.fmt_at(pt.at)),
           'tamper:' || pt.vehicle_id || ':' || extract(epoch from pt.at)::bigint, jsonb_build_object('event', pt.ev)) is not null then
        v_n := v_n + 1;
      end if;
    end if;
    -- driving at night (off unless Tracking settings turn it on): once per car and night, to staff and the owner
    if s.night_on and coalesce(pt.speed, 0) >= 5 then
      v_local := (pt.at at time zone 'America/Toronto')::time;
      v_night := case when s.night_from <= s.night_to then v_local >= s.night_from and v_local < s.night_to else v_local >= s.night_from or v_local < s.night_to end;
      if v_night then
        v_car := coalesce(v_car, app.tracker_car_label(pt.vehicle_id));
        if app.tracker_event_raise('after_hours', null, 'reading', pt.device_id, pt.vehicle_id, pt.at, pt.lat, pt.lng, pt.speed,
             format('Driving at night: %s', v_car), format('Moving at %s km/h at %s (night hours %s to %s).', round(pt.speed), app.fmt_at(pt.at), to_char(s.night_from, 'HH24:MI'), to_char(s.night_to, 'HH24:MI')),
             'night:' || pt.vehicle_id || ':' || to_char((pt.at at time zone 'America/Toronto') - interval '12 hours', 'YYYYMMDD'), '{}'::jsonb) is not null then
          v_n := v_n + 1;
        end if;
      end if;
    end if;
  end loop;
  return v_n;
end $$;

-- ================================================================ 6. the pound scan
-- p_since: the hot rows received since then (a batch); null: every car still at a lot (the hourly job)
create function app.tracker_pound_scan(s tracker_settings, p_since timestamptz, p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  l pound_lots;
  v_parked boolean;
  v_alert uuid;
  v_flag uuid;
  v_booking uuid;
  b bookings;
  n integer := 0;
begin
  if not exists (select 1 from pound_lots where is_active and latitude is not null) then return 0; end if;
  for r in select ts.tracker_device_id, ts.reported_at, ts.latitude, ts.longitude, ts.speed_kmh, ts.ignition_on, ts.pound_lot_id, ts.pound_since, d.vehicle_id
             from tracker_status ts join tracker_devices d on d.id = ts.tracker_device_id
            where d.status = 'installed' and d.vehicle_id is not null and ts.reported_at > '-infinity' and ts.latitude is not null
              and ((p_since is not null and ts.received_at >= p_since) or (p_since is null and ts.pound_lot_id is not null))
  loop
    b := null;
    v_parked := coalesce(r.speed_kmh, 0) < 3 and not coalesce(r.ignition_on, false);
    select * into l from pound_lots x where x.is_active and x.latitude is not null
       and app.tracker_km(x.latitude, x.longitude, r.latitude, r.longitude) * 1000 <= coalesce(x.radius_m, s.pound_radius_m)
     order by app.tracker_km(x.latitude, x.longitude, r.latitude, r.longitude) limit 1;
    if l.id is null or not v_parked then
      if r.pound_lot_id is not null then update tracker_status set pound_lot_id = null, pound_since = null where tracker_device_id = r.tracker_device_id; end if;
      continue;
    end if;
    if r.pound_lot_id is distinct from l.id then
      update tracker_status set pound_lot_id = l.id, pound_since = r.reported_at where tracker_device_id = r.tracker_device_id;
      r.pound_since := r.reported_at;
    end if;
    if greatest(r.reported_at, case when p_since is null then p_now else r.reported_at end) - r.pound_since < make_interval(mins => s.pound_minutes) then continue; end if;
    v_alert := app.tracker_event_raise('pound', null, 'derived', r.tracker_device_id, r.vehicle_id, r.pound_since, r.latitude, r.longitude, 0,
      format('At a pound: %s at %s', app.tracker_car_label(r.vehicle_id), l.name),
      format('Parked at %s, %s since %s.%s', l.name, l.address, app.fmt_at(r.pound_since), coalesce(' Phone ' || l.phone || '.', '')),
      'pound:' || r.vehicle_id || ':' || l.id || ':' || extract(epoch from r.pound_since)::bigint,
      jsonb_strip_nulls(jsonb_build_object('lot_id', l.id, 'lot_name', l.name, 'lot_address', l.address, 'lot_phone', l.phone, 'lot_hours', l.hours)));
    if v_alert is null then continue; end if;
    n := n + 1;
    v_booking := (select a.booking_id from tracker_alerts a where a.id = v_alert);
    insert into pound_flags (alert_id, evidence_id, pound_lot_id, lot_name, lot_address, vehicle_id, booking_id, since)
    values (v_alert, (select e.id from tracker_evidence e where e.alert_id = v_alert), l.id, l.name, l.address, r.vehicle_id, v_booking, r.pound_since)
    on conflict (alert_id) do nothing
    returning id into v_flag;
    begin
      if v_booking is not null then
        select * into b from bookings where id = v_booking;
        perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
          format('Flag: the tracker shows the car parked at a pound (%s, %s) since %s', l.name, l.address, app.fmt_at(r.pound_since)), null, 'system',
          jsonb_build_object('pound_flag_id', v_flag, 'alert_id', v_alert));
      end if;
      perform app.raise_task(p_type => 'pound_recovery', p_queue => 'fleet', p_priority => 'urgent',
        p_title => left(format('At a pound: %s at %s%s', app.tracker_car_label(r.vehicle_id), l.name, coalesce(' (booking ' || b.booking_number || ')', '')), 200),
        p_detail => left(format('The tracker shows the car parked at %s, %s since %s.%s%s Call the lot and the renter, recover the car, then record the path on Cars > Fleet tracking > Pound flags: the non-return charge (%s) or the theft recovery charge (%s) with the tow, impound and storage receipts, recovered with no charge, or not a pound.',
                    l.name, l.address, app.fmt_at(r.pound_since), coalesce(' Phone ' || l.phone || '.', ''), coalesce(' Hours: ' || l.hours || '.', ''),
                    app.fmt_money((app.settings()).non_return_fee_cents), app.fmt_money((app.settings()).theft_recovery_fee_cents)), 900),
        p_booking => v_booking, p_vehicle => r.vehicle_id, p_related_table => 'pound_flags', p_related_id => v_flag, p_dedupe => 'pound_recovery:' || v_flag);
      perform app.emit_event('staff_pound_flag', 'vehicle', r.vehicle_id,
        jsonb_build_object('vehicle_id', r.vehicle_id, 'booking_id', v_booking, 'pound_flag_id', v_flag, 'lot_name', l.name, 'lot_address', l.address, 'lot_phone', coalesce(l.phone, 'not on file'),
                           'lot_hours', coalesce(l.hours, 'not on file'), 'pound_since', app.fmt_at(r.pound_since), 'car_label', app.tracker_car_label(r.vehicle_id),
                           'booking_line', coalesce('Booking ' || b.booking_number, 'No rental under way'),
                           'non_return_fee', app.fmt_money((app.settings()).non_return_fee_cents), 'theft_recovery_fee', app.fmt_money((app.settings()).theft_recovery_fee_cents)),
        'staff_pound_flag:' || v_flag);
    exception when others then
      raise warning 'pound flag % not completed: %', v_flag, sqlerrm;
    end;
  end loop;
  return n;
end $$;

alter function app.tracker_ingest(jsonb) rename to tracker_ingest_pre3320;
create function app.tracker_ingest(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s tracker_settings := app.tracker_settings();
  v_start timestamptz := clock_timestamp();
  v jsonb;
  v_events integer := 0;
begin
  if not s.events_on then return app.tracker_ingest_pre3320(p); end if;
  v_events := app.tracker_events_scan(p, s);
  v := app.tracker_ingest_pre3320(p);
  v_events := v_events + app.tracker_pound_scan(s, v_start, clock_timestamp());
  perform app.tracker_evidence_fill(clock_timestamp());
  return v || jsonb_build_object('events', v_events);
end $$;
select pg_temp.copy_grants('app.tracker_ingest(jsonb)'::regprocedure, 'app.tracker_ingest_pre3320(jsonb)'::regprocedure);

-- the website's one call for a signed request: the replay guard and the rate, then the batch
create function public.server_tracker_ingest_signed(p jsonb, p_sig text, p_ts bigint) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare s tracker_settings := app.tracker_settings();
begin
  if p_sig is null or p_sig !~ '^[0-9a-f]{64}$' then return jsonb_build_object('refused', 'signature'); end if;
  delete from app.tracker_ingest_seen where at < now() - interval '10 minutes';
  begin
    insert into app.tracker_ingest_seen (sig) values (p_sig);
  exception when unique_violation then
    return jsonb_build_object('refused', 'replay');
  end;
  if not app.rate_limit('tracker_ingest', s.ingest_per_minute, interval '1 minute') then return jsonb_build_object('refused', 'rate'); end if;
  return app.tracker_ingest(p);
end $$;
revoke all on function public.server_tracker_ingest_signed(jsonb, text, bigint) from public, anon, authenticated;
grant execute on function public.server_tracker_ingest_signed(jsonb, text, bigint) to service_role;

alter function app.job_tracker(timestamptz) rename to job_tracker_pre3320;
create function app.job_tracker(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s tracker_settings := app.tracker_settings();
  v jsonb := app.job_tracker_pre3320(p_now);
  v_pound integer := 0; v_sealed integer := 0; v_harsh bigint := 0;
begin
  if s.events_on then
    v_pound := app.tracker_pound_scan(s, null, p_now);
    v_sealed := app.tracker_evidence_fill(p_now);
  end if;
  delete from tracker_harsh where at < p_now - make_interval(days => s.history_days);
  get diagnostics v_harsh = row_count;
  return v || jsonb_build_object('pound_flags', v_pound, 'evidence_filled', v_sealed, 'harsh_deleted', v_harsh);
end $$;
select pg_temp.copy_grants('app.job_tracker(timestamptz)'::regprocedure, 'app.job_tracker_pre3320(timestamptz)'::regprocedure);

-- ================================================================ 7. settings and the pound lots (Admin)
alter function app.tracker_settings_save(uuid, jsonb) rename to tracker_settings_save_pre3320;
create function app.tracker_settings_save(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare s tracker_settings;
begin
  perform app.tracker_settings_save_pre3320(p_user, p);
  s := app.tracker_settings();
  begin
  update tracker_settings set
    events_on = coalesce((p ->> 'events_on')::boolean, s.events_on),
    renter_notices = coalesce((p ->> 'renter_notices')::boolean, s.renter_notices),
    owner_notices = coalesce((p ->> 'owner_notices')::boolean, s.owner_notices),
    event_window_minutes = coalesce((p ->> 'event_window_minutes')::integer, s.event_window_minutes),
    harsh_on = coalesce((p ->> 'harsh_on')::boolean, s.harsh_on),
    harsh_kmh_per_s = coalesce((p ->> 'harsh_kmh_per_s')::numeric, s.harsh_kmh_per_s),
    harsh_count = coalesce((p ->> 'harsh_count')::integer, s.harsh_count),
    night_on = coalesce((p ->> 'night_on')::boolean, s.night_on),
    night_from = coalesce(nullif(p ->> 'night_from', '')::time, s.night_from),
    night_to = coalesce(nullif(p ->> 'night_to', '')::time, s.night_to),
    pound_radius_m = coalesce((p ->> 'pound_radius_m')::integer, s.pound_radius_m),
    pound_minutes = coalesce((p ->> 'pound_minutes')::integer, s.pound_minutes),
    ingest_per_minute = coalesce((p ->> 'ingest_per_minute')::integer, s.ingest_per_minute),
    updated_at = now(), updated_by = p_user
  where id;
  exception when check_violation or invalid_datetime_format or datetime_field_overflow or invalid_text_representation then
    raise exception 'Check the event values: the window 5 to 1440 minutes; harsh driving 5 to 40 km/h a second and 1 to 20 events; night hours as HH:MM; the pound radius 30 to 1000 m and 0 to 720 minutes parked; 10 to 6000 ingest requests a minute' using errcode = '23514';
  end;
  return to_jsonb(app.tracker_settings()) - 'ingest_key_ref';
end $$;
select pg_temp.copy_grants('app.tracker_settings_save(uuid, jsonb)'::regprocedure, 'app.tracker_settings_save_pre3320(uuid, jsonb)'::regprocedure);

-- p: {id (to change one), name, address, city, phone, hours, serves, latitude, longitude, radius_m, notes, is_active, checked, remove}
create function app.pound_lot_save(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  l pound_lots;
  v_id uuid := nullif(p ->> 'id', '')::uuid;
  t text;
begin
  if not app.user_is_admin(p_user) then raise exception 'Only an Admin changes the pound lots' using errcode = '42501'; end if;
  if v_id is not null then
    select * into l from pound_lots where id = v_id for update;
    if l.id is null then raise exception 'Pound lot not found' using errcode = 'P0002'; end if;
  end if;
  if coalesce((p ->> 'remove')::boolean, false) then
    if l.id is null then raise exception 'Choose the pound lot to remove' using errcode = '22023'; end if;
    -- a lot a flag names is kept (switched off), so the flag keeps its lot
    if exists (select 1 from pound_flags f where f.pound_lot_id = l.id) then
      update pound_lots set is_active = false, updated_at = now(), updated_by = p_user where id = l.id;
      return jsonb_build_object('id', l.id, 'removed', false, 'switched_off', true);
    end if;
    delete from pound_lots where id = l.id;
    return jsonb_build_object('id', l.id, 'removed', true);
  end if;
  foreach t in array array['name', 'address', 'city', 'phone', 'hours', 'serves', 'notes'] loop
    if p ? t and (p ->> t) ~ '[<>]' then raise exception 'Leave out the characters < and > in the %', t using errcode = '22023'; end if;
  end loop;
  if l.id is null then
    if nullif(btrim(coalesce(p ->> 'name', '')), '') is null or nullif(btrim(coalesce(p ->> 'address', '')), '') is null then
      raise exception 'A pound lot needs its name and its address' using errcode = '22023';
    end if;
    insert into pound_lots (name, address, updated_by) values (btrim(p ->> 'name'), btrim(p ->> 'address'), p_user) returning * into l;
  end if;
  update pound_lots set
    name = case when p ? 'name' and nullif(btrim(p ->> 'name'), '') is not null then btrim(p ->> 'name') else name end,
    address = case when p ? 'address' and nullif(btrim(p ->> 'address'), '') is not null then btrim(p ->> 'address') else address end,
    city = case when p ? 'city' then nullif(btrim(p ->> 'city'), '') else city end,
    phone = case when p ? 'phone' then nullif(btrim(p ->> 'phone'), '') else phone end,
    hours = case when p ? 'hours' then nullif(btrim(p ->> 'hours'), '') else hours end,
    serves = case when p ? 'serves' then nullif(btrim(p ->> 'serves'), '') else serves end,
    notes = case when p ? 'notes' then nullif(btrim(p ->> 'notes'), '') else notes end,
    -- a new address without a new pin drops the old pin (it is found again from the address)
    latitude = case when p ? 'latitude' then nullif(p ->> 'latitude', '')::numeric when p ? 'address' and btrim(p ->> 'address') is distinct from l.address then null else latitude end,
    longitude = case when p ? 'longitude' then nullif(p ->> 'longitude', '')::numeric when p ? 'address' and btrim(p ->> 'address') is distinct from l.address then null else longitude end,
    radius_m = case when p ? 'radius_m' then nullif(p ->> 'radius_m', '')::integer else radius_m end,
    is_active = coalesce((p ->> 'is_active')::boolean, is_active),
    checked_at = case when p ? 'checked' then case when (p ->> 'checked')::boolean then coalesce(checked_at, now()) end else checked_at end,
    checked_by = case when p ? 'checked' then case when (p ->> 'checked')::boolean then coalesce(checked_by, p_user) end else checked_by end,
    updated_at = now(), updated_by = p_user
  where id = l.id returning * into l;
  return to_jsonb(l);
exception
  when check_violation then
    raise exception 'Check the pound lot: a name, an address, a pin in Ontario (latitude 41 to 57, longitude -96 to -74, both or neither) and a radius of 30 to 1000 m' using errcode = '23514';
  when unique_violation then
    raise exception 'That pound lot is already in the list (the same name and address)' using errcode = '23505';
end $$;

-- the website found pins from the addresses (service role): only lots that have none
create function public.server_pound_lot_pins(p jsonb) returns integer
language plpgsql security definer set search_path = public, app as $$
declare x jsonb; n integer := 0; k integer;
begin
  for x in select value from jsonb_array_elements(coalesce(p, '[]'::jsonb)) loop
    update pound_lots set latitude = round((x ->> 'lat')::numeric, 5), longitude = round((x ->> 'lng')::numeric, 5), updated_at = now()
     where id = (x ->> 'id')::uuid and latitude is null and (x ->> 'lat')::numeric between 41 and 57 and (x ->> 'lng')::numeric between -96 and -74;
    get diagnostics k = row_count;
    n := n + k;
  end loop;
  return n;
end $$;
revoke all on function public.server_pound_lot_pins(jsonb) from public, anon, authenticated;
grant execute on function public.server_pound_lot_pins(jsonb) to service_role;

-- ================================================================ 8. a fee charged with its evidence attached
create function app.tracker_evidence_link(p_evidence uuid, p_alert uuid, p_lines uuid[], p_by uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare v_line uuid;
begin
  if p_lines is null or cardinality(p_lines) = 0 then return; end if;
  update tracker_evidence set line_item_id = p_lines[1] where id = p_evidence;
  update tracker_alerts set line_item_id = p_lines[1] where id = p_alert;
  foreach v_line in array p_lines loop
    -- the line names its evidence record (the registry and the dispute kit read it); the update rechecks the line
    update booking_line_items set supporting_refs = coalesce(supporting_refs, '{}'::jsonb) || jsonb_build_object('tracker_evidence_id', p_evidence, 'alert_id', p_alert) where id = v_line;
    insert into fee_evidence (line_item_id, kind, note, added_by)
    values (v_line, 'tracker_event', (select left(format('Tracker evidence record %s: %s. %s SHA-256 %s', e.id, e.title, coalesce(e.detail, ''), coalesce(e.sha256, 'pending')), 2000) from tracker_evidence e where e.id = p_evidence), p_by);
  end loop;
end $$;

-- p: {alert_id, note}: a speeding record becomes its speeding charge (3102), the tracker's record attached
create function app.tracker_alert_charge(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a tracker_alerts;
  e tracker_evidence;
  v jsonb;
begin
  select * into a from tracker_alerts where id = nullif(p ->> 'alert_id', '')::uuid for update;
  if a.id is null then raise exception 'Tracker event not found' using errcode = 'P0002'; end if;
  if a.line_item_id is not null and exists (select 1 from booking_line_items li where li.id = a.line_item_id and li.voided_at is null) then
    raise exception 'This event is already charged' using errcode = '23514';
  end if;
  if a.kind = 'pound' then raise exception 'A pound flag is billed from Pound flags (the non-return or theft recovery charge with its costs)' using errcode = '22023'; end if;
  if a.kind <> 'speeding' or a.tier is null then
    raise exception 'This event carries no set charge under the rental agreement%', coalesce(' (' || a.clause || ')', '') using errcode = '23514';
  end if;
  if a.booking_id is null then raise exception 'No rental was under way at that time: there is nobody to charge' using errcode = '23514'; end if;
  select * into e from tracker_evidence where alert_id = a.id;
  if e.id is null then raise exception 'This event has no evidence record: it cannot be charged' using errcode = '23514'; end if;
  v := app.speeding_charge_add(p_by, jsonb_build_object('booking', a.booking_id, 'over', a.tier, 'alert_id', a.id, 'note', nullif(btrim(coalesce(p ->> 'note', '')), '')));
  perform app.tracker_evidence_link(e.id, a.id, array[(v ->> 'line_item_id')::uuid], p_by);
  update tracker_alerts set ack_at = coalesce(ack_at, now()), ack_by = coalesce(ack_by, p_by), ack_note = coalesce(ack_note, 'Charged') where id = a.id;
  return v || jsonb_build_object('evidence_id', e.id, 'evidence_status', (select li.evidence_status from booking_line_items li where li.id = (v ->> 'line_item_id')::uuid));
end $$;

-- p: {id, path: non_return | theft_recovery | no_charge | not_a_pound, note, police_report, costs: [{label, amount_cents, document_id}]}
-- (one cost may also come flat, from the form: cost_cents, cost_label, cost_document_id)
create function app.pound_flag_resolve(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  f pound_flags;
  v_path text := lower(btrim(coalesce(p ->> 'path', '')));
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
  v jsonb;
  v_lines uuid[];
  v_costs jsonb := case when jsonb_typeof(p -> 'costs') = 'array' then p -> 'costs' else '[]'::jsonb end;
begin
  if nullif(p ->> 'cost_cents', '') is not null and (p ->> 'cost_cents')::bigint > 0 then
    v_costs := v_costs || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('label', coalesce(nullif(btrim(coalesce(p ->> 'cost_label', '')), ''), 'Tow, impound and storage'),
                 'amount_cents', (p ->> 'cost_cents')::bigint, 'document_id', nullif(p ->> 'cost_document_id', ''))));
  end if;
  if not (app.user_is_admin(p_by) or app.user_runs_finance(p_by) or app.user_runs_fleet(p_by)) then
    raise exception 'An Admin, Finance or Fleet resolves a pound flag' using errcode = '42501';
  end if;
  select * into f from pound_flags where id = nullif(p ->> 'id', '')::uuid for update;
  if f.id is null then raise exception 'Pound flag not found' using errcode = 'P0002'; end if;
  if f.status <> 'open' then raise exception 'This pound flag is already resolved' using errcode = '23514'; end if;
  if v_path not in ('non_return', 'theft_recovery', 'no_charge', 'not_a_pound') then
    raise exception 'Choose the path: non_return, theft_recovery, no_charge or not_a_pound' using errcode = '22023';
  end if;
  if v_note is null or char_length(v_note) < 5 then raise exception 'Say what happened (the renter sees it on a charge)' using errcode = '22023'; end if;
  if v_path in ('non_return', 'theft_recovery') then
    if f.booking_id is null then raise exception 'No rental was under way: there is nobody to charge. Choose no_charge' using errcode = '23514'; end if;
    v := app.return_charge_add(p_by, jsonb_strip_nulls(jsonb_build_object('booking', f.booking_id, 'kind', v_path, 'note', v_note, 'costs', v_costs,
           'police_report', nullif(btrim(coalesce(p ->> 'police_report', '')), ''))));
    select array_agg((x ->> 'line_item_id')::uuid) into v_lines from jsonb_array_elements(v -> 'lines') x;
    perform app.tracker_evidence_link(f.evidence_id, f.alert_id, v_lines, p_by);
  end if;
  update pound_flags set status = case v_path when 'no_charge' then 'recovered' when 'not_a_pound' then 'dismissed' else 'charged' end, path = v_path, note = v_note,
         lines = coalesce((select jsonb_agg(x) from unnest(v_lines) x), '[]'::jsonb), resolved_at = now(), resolved_by = p_by
   where id = f.id;
  update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = left('Pound flag: ' || replace(v_path, '_', ' '), 200)
   where dedupe_key = 'pound_recovery:' || f.id and status in ('open', 'in_progress', 'waiting');
  update tracker_alerts set ack_at = coalesce(ack_at, now()), ack_by = coalesce(ack_by, p_by), ack_note = coalesce(ack_note, left('Pound flag: ' || replace(v_path, '_', ' '), 300)) where id = f.alert_id;
  if f.booking_id is not null then
    perform app.log_booking_event(f.booking_id, 'adjusted', (select status::text from bookings where id = f.booking_id), (select status::text from bookings where id = f.booking_id), null,
      format('Pound flag resolved (%s): %s', replace(v_path, '_', ' '), v_note), p_by, 'staff', jsonb_build_object('pound_flag_id', f.id, 'lines', coalesce(v -> 'lines', '[]'::jsonb)));
  end if;
  return jsonb_build_object('ok', true, 'id', f.id, 'path', v_path, 'charge', v,
    'lines', coalesce((select jsonb_agg(jsonb_build_object('line_item_id', li.id, 'fee', li.charge_type, 'amount_cents', li.amount_cents, 'evidence_status', li.evidence_status, 'missing', to_jsonb(li.evidence_missing)))
                         from booking_line_items li where li.id = any (v_lines)), '[]'::jsonb));
end $$;

-- the evidence registry (3190): a fee line that names a tracker evidence record has the tracker's proof
alter function app.fee_evidence_have(uuid) rename to fee_evidence_have_pre3320;
create function app.fee_evidence_have(p_line uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.fee_evidence_have_pre3320(p_line);
  e tracker_evidence;
begin
  select x.* into e from tracker_evidence x
   where x.line_item_id = p_line or x.id = (select nullif(li.supporting_refs ->> 'tracker_evidence_id', '')::uuid from booking_line_items li where li.id = p_line)
   order by (x.line_item_id = p_line) desc nulls last limit 1;
  if e.id is null then return v; end if;
  v := v || jsonb_build_object('tracker_event', jsonb_build_object('evidence_id', e.id, 'kind', e.kind, 'at', e.at, 'lat', e.lat, 'lng', e.lng, 'speed_kmh', e.speed_kmh, 'source', e.source, 'sha256', e.sha256),
                               'tracker_map', coalesce(v -> 'tracker_map', '{}'::jsonb) || jsonb_build_object('evidence_id', e.id, 'readings', jsonb_array_length(e.readings)));
  if e.kind = 'speeding' and e.speed_kmh is not null then
    v := v || jsonb_build_object('speed_series', coalesce(v -> 'speed_series', '{}'::jsonb) || jsonb_build_object('speed_kmh', e.speed_kmh, 'at', e.at, 'evidence_id', e.id));
  end if;
  return v;
end $$;
select pg_temp.copy_grants('app.fee_evidence_have(uuid)'::regprocedure, 'app.fee_evidence_have_pre3320(uuid)'::regprocedure);

-- the dispute kit (3192): every tracker event of the booking with its evidence record and the notice the renter got
alter function public.server_dispute_evidence(uuid) rename to server_dispute_evidence_pre3320;
create function public.server_dispute_evidence(p_pack uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := public.server_dispute_evidence_pre3320(p_pack);
  v_booking uuid := (select k.booking_id from dispute_packs k where k.id = p_pack);
begin
  return v || jsonb_build_object('tracker_events', coalesce((select jsonb_agg(jsonb_build_object(
      'evidence_id', e.id, 'kind', e.kind, 'tier', e.tier, 'title', e.title, 'detail', e.detail, 'at', e.at, 'lat', e.lat, 'lng', e.lng, 'speed_kmh', e.speed_kmh, 'source', e.source,
      'device', e.device, 'clause', e.clause, 'fee_code', e.fee_code, 'line_item_id', e.line_item_id, 'sha256', e.sha256, 'sealed_at', e.sealed_at, 'readings', e.readings, 'facts', e.facts - 'marks',
      'notices', coalesce((select jsonb_agg(jsonb_build_object('code', o.code, 'channel', coalesce(o.channel, 'email'), 'status', o.status, 'queued_at', o.created_at, 'sent_at', o.sent_at, 'provider_id', o.provider_id) order by o.created_at)
                             from notification_outbox o where o.audience = 'renter' and o.code in ('renter_tracker_notice', 'renter_driving_notice') and o.booking_id = e.booking_id
                              and split_part(o.dedupe_key, '|', 1) like o.code || ':' || e.alert_id || '%'), '[]'::jsonb)) order by e.at)
    from tracker_evidence e where e.booking_id = v_booking), '[]'::jsonb));
end $$;
select pg_temp.copy_grants('public.server_dispute_evidence(uuid)'::regprocedure, 'public.server_dispute_evidence_pre3320(uuid)'::regprocedure);

-- ================================================================ 9. what the screens read
create function app.tracker_events(p_user uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s tracker_settings := app.tracker_settings();
  ps program_settings := app.settings();
  v_admin boolean := app.user_is_admin(p_user);
  v_money boolean := v_admin or app.user_runs_finance(p_user);
  v_fleet boolean := v_admin or app.user_runs_fleet(p_user);
begin
  perform app.tracker_assert(p_user, false);
  return jsonb_build_object(
    'on', s.events_on,
    'settings', jsonb_build_object('events_on', s.events_on, 'renter_notices', s.renter_notices, 'owner_notices', s.owner_notices, 'event_window_minutes', s.event_window_minutes,
      'harsh_on', s.harsh_on, 'harsh_kmh_per_s', s.harsh_kmh_per_s, 'harsh_count', s.harsh_count, 'night_on', s.night_on, 'night_from', to_char(s.night_from, 'HH24:MI'),
      'night_to', to_char(s.night_to, 'HH24:MI'), 'pound_radius_m', s.pound_radius_m, 'pound_minutes', s.pound_minutes, 'ingest_per_minute', s.ingest_per_minute, 'speed_alert_kmh', s.speed_alert_kmh),
    'fees', jsonb_build_object('speeding_180', ps.speeding_180_fee_cents, 'speeding_220', ps.speeding_220_fee_cents, 'speeding_300', ps.speeding_300_fee_cents,
      'non_return', ps.non_return_fee_cents, 'theft_recovery', ps.theft_recovery_fee_cents),
    'can', jsonb_build_object('manage', v_admin, 'charge', v_money, 'resolve', v_money or v_fleet),
    'events', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'alert_id', e.alert_id, 'kind', e.kind, 'tier', e.tier, 'title', e.title, 'detail', e.detail, 'at', e.at,
        'lat', e.lat::float8, 'lng', e.lng::float8, 'speed_kmh', e.speed_kmh, 'source', e.source, 'device', e.device, 'clause', e.clause, 'fee_code', e.fee_code,
        'fee_cents', (app.tracker_event_terms(e.kind, e.tier) ->> 'fee_cents')::bigint, 'chargeable', e.kind = 'speeding' and e.tier is not null and e.booking_id is not null,
        'vehicle', app.vehicle_name(e.vehicle_id), 'vehicle_id', e.vehicle_id, 'booking_number', (select b.booking_number from bookings b where b.id = e.booking_id),
        'readings', jsonb_array_length(e.readings), 'sealed', e.sealed_at is not null, 'sha256', e.sha256,
        'renter_notice_at', a.renter_notice_at, 'owner_notice_at', a.owner_notice_at, 'seen', a.ack_at is not null,
        'line', (select jsonb_build_object('id', li.id, 'amount_cents', li.amount_cents, 'evidence_status', li.evidence_status, 'on_statement', li.statement_id is not null)
                   from booking_line_items li where li.id = e.line_item_id and li.voided_at is null)) order by e.at desc)
      from (select * from tracker_evidence x order by x.at desc limit 100) e left join tracker_alerts a on a.id = e.alert_id), '[]'::jsonb),
    'flags', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'status', f.status, 'path', f.path, 'note', f.note, 'lot_name', f.lot_name, 'lot_address', f.lot_address,
        'lot_phone', l.phone, 'lot_hours', l.hours, 'since', f.since, 'vehicle', app.vehicle_name(f.vehicle_id), 'vehicle_id', f.vehicle_id,
        'booking_number', (select b.booking_number from bookings b where b.id = f.booking_id), 'evidence_id', f.evidence_id, 'resolved_at', f.resolved_at,
        'resolved_by', (select u.full_name from users u where u.id = f.resolved_by), 'lines', f.lines) order by (f.status = 'open') desc, f.created_at desc)
      from (select * from pound_flags x order by (x.status = 'open') desc, x.created_at desc limit 50) f left join pound_lots l on l.id = f.pound_lot_id), '[]'::jsonb),
    'lots', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name, 'address', l.address, 'city', l.city, 'phone', l.phone, 'hours', l.hours, 'serves', l.serves,
        'latitude', l.latitude::float8, 'longitude', l.longitude::float8, 'radius_m', l.radius_m, 'notes', l.notes, 'is_active', l.is_active, 'checked', l.checked_at is not null,
        'source_url', l.source_url) order by l.city nulls last, l.name) from pound_lots l), '[]'::jsonb));
end $$;

-- the owner: the events of their own cars (the event, the time and the place; never the renter or the booking)
create function app.owner_tracker_events(p_user uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_vehicle uuid := nullif(p ->> 'vehicle', '')::uuid;
  v_days integer := least(greatest(coalesce((p ->> 'days')::integer, 30), 1), 90);
begin
  if p_user is null or not exists (select 1 from owners o where o.user_id = p_user) then raise exception 'Only a car''s owner sees its tracker events' using errcode = '42501'; end if;
  if v_vehicle is not null and not app.user_owns_vehicle(p_user, v_vehicle) then raise exception 'Only the owner of this car sees its tracker events' using errcode = '42501'; end if;
  return jsonb_build_object('days', v_days, 'events', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'kind', e.kind, 'tier', e.tier, 'vehicle_id', e.vehicle_id,
      'vehicle', app.vehicle_name(e.vehicle_id), 'at', e.at, 'lat', e.lat::float8, 'lng', e.lng::float8, 'speed_kmh', e.speed_kmh,
      'what', app.tracker_event_words(a) ->> 'event_owner', 'title', app.tracker_event_words(a) ->> 'event_title') order by e.at desc)
    from (select x.* from tracker_evidence x join vehicles v on v.id = x.vehicle_id join owners o on o.id = v.owner_id
           where o.user_id = p_user and (v_vehicle is null or x.vehicle_id = v_vehicle) and x.at > now() - make_interval(days => v_days)
             and x.kind not in ('battery_low', 'offline') order by x.at desc limit 50) e
    join tracker_alerts a on a.id = e.alert_id), '[]'::jsonb));
end $$;

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre3320;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if p_call = 'ops_do' and p_name in ('tracker_alert_charge', 'pound_flag_resolve', 'pound_lot_save') then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return case p_name
      when 'tracker_alert_charge' then app.tracker_alert_charge(p_user, v)
      when 'pound_flag_resolve' then app.pound_flag_resolve(p_user, v)
      else app.pound_lot_save(p_user, v) end;
  end if;
  if p_call = 'ops_read' and p_name in ('tracker_events', 'owner_tracker_events') then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'tracker_events' then app.tracker_events(p_user, v) else app.owner_tracker_events(p_user, v) end;
  end if;
  return app.door_pre3320(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre3320(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f text;
begin
  foreach f in array array[
    'app.tracker_event_terms(text, integer)', 'app.tracker_event_words(tracker_alerts)', 'app.tracker_alert_terms()', 'app.tracker_evidence_seal(tracker_evidence)',
    'app.tracker_evidence_fill(timestamptz)', 'app.tracker_alert_after()', 'app.tracker_event_notify(tracker_alerts, text)',
    'app.tracker_speeding_raise(uuid, integer, timestamptz, numeric, numeric, numeric)', 'app.tracker_event_raise(text, integer, text, uuid, uuid, timestamptz, numeric, numeric, numeric, text, text, text, jsonb)',
    'app.tracker_events_scan(jsonb, tracker_settings)', 'app.tracker_pound_scan(tracker_settings, timestamptz, timestamptz)', 'app.tracker_ingest_pre3320(jsonb)',
    'app.job_tracker_pre3320(timestamptz)', 'app.tracker_settings_save_pre3320(uuid, jsonb)', 'app.pound_lot_save(uuid, jsonb)', 'app.tracker_evidence_link(uuid, uuid, uuid[], uuid)',
    'app.tracker_alert_charge(uuid, jsonb)', 'app.pound_flag_resolve(uuid, jsonb)', 'app.fee_evidence_have_pre3320(uuid)', 'public.server_dispute_evidence_pre3320(uuid)',
    'app.tracker_events(uuid, jsonb)', 'app.owner_tracker_events(uuid, jsonb)', 'app.door_pre3320(uuid, text, text, text, jsonb)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
