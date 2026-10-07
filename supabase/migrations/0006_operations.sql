-- 0006_operations.sql
-- Field jobs, condition reports with photos, VA task queues, message log and templates,
-- daily checks, tracker devices / commands / owner access blocks, the monthly franchisor
-- fleet report and the 10-vehicle minimum.

-- ---------------------------------------------------------------- field jobs
-- One row per piece of in-person work. Field staff see only the jobs assigned to them.
create table field_jobs (
  id              uuid primary key default gen_random_uuid(),
  kind            text not null check (kind in (
                    'handover', 'delivery', 'return_check_in', 'pickup_from_renter', 'detail',
                    'photo_shoot', 'tracker_install', 'tracker_removal', 'registry_run', 'recovery', 'other')),
  booking_id      uuid references bookings (id),
  vehicle_id      uuid not null references vehicles (id),
  assigned_to     uuid references users (id),
  dispatched_by   uuid references users (id),          -- Fleet
  scheduled_at    timestamptz not null,
  place           text,
  instructions    text,
  status          text not null default 'scheduled'
                  check (status in ('scheduled', 'acknowledged', 'in_progress', 'done', 'cancelled')),
  acknowledged_at timestamptz,
  started_at      timestamptz,
  completed_at    timestamptz,
  -- detailing (procedure 18): what the detailer found before cleaning
  cleaning_grade  text check (cleaning_grade in ('standard', 'cleaning', 'heavy', 'pet', 'smoking')),
  belongings_found text,
  fuel_or_charge_ok boolean,
  reviewed_by     uuid references users (id),          -- Fleet reviews photos within 1 hour
  reviewed_at     timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  check (status <> 'done' or completed_at is not null)
);
create index field_jobs_assignee_idx on field_jobs (assigned_to, scheduled_at);
create index field_jobs_booking_idx on field_jobs (booking_id);
create index field_jobs_vehicle_idx on field_jobs (vehicle_id, scheduled_at);
create trigger field_jobs_updated before update on field_jobs for each row execute function app.set_updated_at();

-- ---------------------------------------------------------------- condition reports (RA Part 4)
create table condition_reports (
  id               uuid primary key default gen_random_uuid(),
  vehicle_id       uuid not null references vehicles (id),
  booking_id       uuid references bookings (id),       -- null for a baseline or exit report
  field_job_id     uuid references field_jobs (id),
  kind             text not null check (kind in ('baseline', 'pickup', 'return', 'swap_out', 'swap_in', 'exit', 'ready')),
  performed_by     uuid references users (id),          -- Field; the Owner on a Self-Managed car; the renter on a renewal day
  performed_by_role text not null default 'field' check (performed_by_role in ('field', 'owner', 'renter', 'staff')),
  performed_at     timestamptz not null default now(),
  odometer_km      integer check (odometer_km >= 0),
  fuel_pct         smallint check (fuel_pct between 0 and 100),   -- fuel or battery charge
  cleanliness      text check (cleanliness in ('clean', 'cleaning', 'heavy', 'pet', 'smoking')),
  odour            boolean,
  keys_count       smallint check (keys_count >= 0),
  extras           jsonb,                               -- baby seats, winter tires, cable, spare, tools
  tracker_reporting boolean,                            -- "Tracker in place and reporting"
  licence_seen     boolean,                             -- original licence matched to Part 1
  card_seen        boolean,                             -- physical Card on File matched to Part 1
  unattended       boolean not null default false,
  renter_present   boolean not null default true,
  renter_signed_at timestamptz,
  staff_signed_at  timestamptz,
  signature_request_id uuid references signature_requests (id),
  document_id      uuid references documents (id),
  notes            text,
  reviewed_by      uuid references users (id),          -- Fleet compares both photo sets
  reviewed_at      timestamptz,
  created_at       timestamptz not null default now(),
  check (kind not in ('pickup', 'return', 'swap_out', 'swap_in') or booking_id is not null)
);
create index condition_reports_booking_idx on condition_reports (booking_id);
create index condition_reports_vehicle_idx on condition_reports (vehicle_id, performed_at desc);
-- one pickup and one return report per booking (swaps are separate kinds)
create unique index condition_reports_one_per_kind on condition_reports (booking_id, kind) where kind in ('pickup', 'return');

create table condition_report_damages (
  id                  uuid primary key default gen_random_uuid(),
  condition_report_id uuid not null references condition_reports (id) on delete cascade,
  label               text not null,                    -- "D1", "D2" as marked on the report
  location            text not null,
  description         text not null,
  is_new              boolean not null default false,   -- not on the pickup report
  found_later         boolean not null default false,   -- not visible at return: reported within 48 hours (T8)
  reported_to_renter_at timestamptz,
  unique (condition_report_id, label)
);

create table condition_report_photos (
  id                  uuid primary key default gen_random_uuid(),
  condition_report_id uuid not null references condition_reports (id) on delete cascade,
  seq                 integer not null check (seq > 0),  -- the fixed order of procedure 3
  shot                text not null check (shot in (
                        'front', 'front_left', 'left', 'rear_left', 'rear', 'rear_right', 'right', 'front_right',
                        'roof', 'windshield', 'wheel_front_left', 'wheel_front_right', 'wheel_rear_left', 'wheel_rear_right',
                        'instrument_cluster', 'front_seats', 'rear_seats', 'trunk', 'keys', 'damage_closeup',
                        'licence', 'other')),
  damage_id           uuid references condition_report_damages (id),
  storage_bucket      text not null default 'condition-photos',
  storage_path        text not null,
  taken_at            timestamptz not null default now(), -- time stamp from the upload
  uploaded_by         uuid references users (id),
  unique (condition_report_id, seq),
  check ((shot = 'damage_closeup') = (damage_id is not null))
);

alter table documents add column condition_report_id uuid references condition_reports (id);

-- ---------------------------------------------------------------- VA task queues
create table tasks (
  id            uuid primary key default gen_random_uuid(),
  queue         text not null check (queue in ('finance', 'fleet', 'cs', 'sales', 'admin')),
  task_type     text not null,                          -- e.g. 'verify_renter', 'price_findings', 'match_toll'
  title         text not null,
  detail        text,
  procedure_no  smallint check (procedure_no between 1 and 20),
  priority      text not null default 'normal' check (priority in ('low', 'normal', 'high', 'urgent')),
  status        text not null default 'open' check (status in ('open', 'in_progress', 'waiting', 'done', 'cancelled')),
  due_at        timestamptz,
  assigned_to   uuid references users (id),
  escalated     boolean not null default false,         -- "Escalate to admin when ..."
  escalated_at  timestamptz,
  escalation_reason text,
  booking_id    uuid references bookings (id),
  vehicle_id    uuid references vehicles (id),
  owner_id      uuid references owners (id),
  renter_id     uuid references renters (id),
  related_table text,                                    -- any other record (incident, toll, invoice, claim)
  related_id    uuid,
  created_by    uuid references users (id),
  created_at    timestamptz not null default now(),
  completed_by  uuid references users (id),
  completed_at  timestamptz,
  updated_at    timestamptz not null default now(),
  check (status <> 'done' or completed_at is not null),
  check (not escalated or escalation_reason is not null)
);
create index tasks_queue_idx on tasks (queue, status, due_at);
create index tasks_assignee_idx on tasks (assigned_to, status);
create index tasks_booking_idx on tasks (booking_id);
create trigger tasks_updated before update on tasks for each row execute function app.set_updated_at();

-- ---------------------------------------------------------------- messages
create table message_templates (
  code        text primary key,                         -- T1 .. T26
  purpose     text not null,
  audience    text not null check (audience in ('renter', 'owner', 'internal')),
  body        text,                                     -- current wording; docs/source/operating_procedures.md is the master
  version     integer not null default 1,
  updated_at  timestamptz not null default now()
);

create table messages (
  id            uuid primary key default gen_random_uuid(),
  direction     text not null check (direction in ('outbound', 'inbound')),
  channel       text not null check (channel in ('email', 'sms', 'whatsapp', 'phone', 'portal', 'push')),
  template_code text references message_templates (code),
  subject       text,
  body          text,
  to_address    text,
  from_address  text,
  user_id       uuid references users (id),             -- the person written to or heard from
  renter_id     uuid references renters (id),
  owner_id      uuid references owners (id),
  booking_id    uuid references bookings (id),
  vehicle_id    uuid references vehicles (id),
  related_table text,
  related_id    uuid,
  sent_by       uuid references users (id),             -- null = sent by the system
  provider      text,
  provider_ref  text,
  status        text not null default 'queued' check (status in ('queued', 'sent', 'delivered', 'failed', 'received')),
  occurred_at   timestamptz not null default now(),     -- sent or received; a cancellation email's time counts
  created_at    timestamptz not null default now()
);
create index messages_booking_idx on messages (booking_id, occurred_at);
create index messages_owner_idx on messages (owner_id, occurred_at);
create index messages_renter_idx on messages (renter_id, occurred_at);
create trigger messages_append_only before delete on messages for each row execute function app.forbid_change();

-- ---------------------------------------------------------------- daily checks (procedure 19)
create table daily_checks (
  id           uuid primary key default gen_random_uuid(),
  check_date   date not null,                           -- Toronto date
  kind         text not null check (kind in ('opening', 'closing')),
  items        jsonb not null default '{}',             -- each numbered line and its result
  issues       text,
  completed_by uuid references users (id),
  completed_at timestamptz,
  unique (check_date, kind)
);

-- ---------------------------------------------------------------- tracker
create table tracker_devices (
  id            uuid primary key default gen_random_uuid(),
  serial_number text not null unique,
  imei          text unique,
  sim_iccid     text,
  firmware      text,
  vehicle_id    uuid references vehicles (id),
  status        text not null default 'in_stock'
                check (status in ('in_stock', 'installed', 'removed', 'faulty', 'lost')),
  installed_at  timestamptz,
  installed_by  uuid references users (id),
  tested_at     timestamptz,                             -- location, lock, alarm and shut-off tested while parked
  removed_at    timestamptz,
  removed_by    uuid references users (id),
  last_seen_at  timestamptz,
  created_at    timestamptz not null default now(),
  check (status <> 'installed' or vehicle_id is not null)
);
create unique index tracker_devices_one_per_vehicle on tracker_devices (vehicle_id) where status = 'installed';

-- Latest known state per device (the position history itself stays with the tracker service
-- for 12 months; only what a decision relied on is copied here).
create table tracker_status (
  tracker_device_id uuid primary key references tracker_devices (id) on delete cascade,
  reported_at   timestamptz not null,
  latitude      numeric(9, 6),
  longitude     numeric(9, 6),
  speed_kmh     numeric(6, 1),
  ignition_on   boolean,
  engine_enabled boolean,
  locked        boolean,
  tamper_alert  boolean not null default false
);

-- Owner access to a vehicle's tracker: live location always; lock, alarm and shut-off
-- are blocked during every rental CarmaCars manages (not an Owner Booking).
create table tracker_access_blocks (
  id          uuid primary key default gen_random_uuid(),
  vehicle_id  uuid not null references vehicles (id),
  booking_id  uuid references bookings (id),
  reason      text not null default 'managed_rental' check (reason in ('managed_rental', 'admin')),
  starts_at   timestamptz not null default now(),
  ends_at     timestamptz,                               -- null = still blocked
  created_by  uuid references users (id),                -- Fleet, or null when set by the booking trigger
  ended_by    uuid references users (id),
  check (ends_at is null or ends_at >= starts_at)
);
create unique index tracker_access_blocks_one_open on tracker_access_blocks (vehicle_id, booking_id) where ends_at is null;
create index tracker_access_blocks_vehicle_idx on tracker_access_blocks (vehicle_id, starts_at);

create or replace function app.owner_controls_blocked(p_vehicle uuid, p_at timestamptz default now())
returns boolean language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from tracker_access_blocks b
                  where b.vehicle_id = p_vehicle and b.starts_at <= p_at and (b.ends_at is null or b.ends_at > p_at))
$$;

-- Command log: who, why, on what authority, and what the tracker showed at that moment.
create table tracker_commands (
  id                uuid primary key default gen_random_uuid(),
  tracker_device_id uuid not null references tracker_devices (id),
  vehicle_id        uuid not null references vehicles (id),
  booking_id        uuid references bookings (id),
  incident_id       uuid,                                -- FK added in 0008
  command           text not null check (command in ('locate', 'lock', 'unlock', 'alarm', 'engine_disable', 'engine_enable')),
  actor_type        text not null check (actor_type in ('admin', 'staff', 'owner', 'system')),
  requested_by      uuid references users (id),          -- who
  reason_code       text not null check (reason_code in (
                      'handover', 'return', 'self_managed_window', 'install_test', 'late_return', 'unpaid_charge',
                      'serious_breach', 'coverage_ended', 'suspected_theft', 'abandonment', 'fraud', 'unsafe_driving',
                      'tracker_tampering', 'authority_order', 'safety_re_enable', 'owner_protecting_vehicle', 'other')),
  reason            text not null check (length(btrim(reason)) > 0),   -- why, in words
  notice_sent_at    timestamptz,                         -- T14: one hour's notice where the agreement requires it
  approved_by       uuid references users (id),          -- only an Admin approves disabling
  approved_at       timestamptz,
  -- what the Tracker showed immediately before the command
  observed_at       timestamptz,
  observed_speed_kmh numeric(6, 1),
  observed_ignition_on boolean,
  screenshot_document_id uuid references documents (id), -- pre-disable Tracker screenshot
  status            text not null default 'requested'
                    check (status in ('requested', 'approved', 'rejected', 'blocked', 'sent', 'confirmed', 'failed')),
  sent_at           timestamptz,
  result_at         timestamptz,
  provider_ref      text,
  error             text,
  created_at        timestamptz not null default now(),
  check (actor_type = 'system' or requested_by is not null),
  -- Never while moving: a shut-off is sent only when the Tracker shows the car stationary with
  -- the ignition off, observed just before, and only with an Admin's approval.
  check (command <> 'engine_disable' or status not in ('sent', 'confirmed', 'failed')
         or (approved_by is not null and observed_at is not null
             and observed_speed_kmh = 0 and observed_ignition_on = false))
);
create index tracker_commands_vehicle_idx on tracker_commands (vehicle_id, created_at desc);
create index tracker_commands_booking_idx on tracker_commands (booking_id);
-- the log is permanent
create trigger tracker_commands_no_delete before delete on tracker_commands
  for each row execute function app.forbid_change();

create or replace function app.guard_tracker_command() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  -- An Owner keeps live location, but lock, alarm and shut-off are refused while blocked.
  if new.actor_type = 'owner' and new.command <> 'locate'
     and app.owner_controls_blocked(new.vehicle_id, coalesce(new.sent_at, now())) then
    if tg_op = 'INSERT' then
      new.status := 'blocked';
      new.error := 'Owner controls are blocked during a rental CarmaCars manages';
    elsif new.status in ('approved', 'sent', 'confirmed') then
      raise exception 'Owner controls are blocked during a rental CarmaCars manages' using errcode = '42501';
    end if;
  end if;
  -- Neither party uses the shut-off on a moving vehicle; nobody but an admin approves one.
  if new.command = 'engine_disable' and new.status in ('approved', 'sent', 'confirmed') then
    if new.actor_type <> 'owner' and (new.approved_by is null or not exists (
         select 1 from user_roles r where r.user_id = new.approved_by and r.role = 'admin')) then
      raise exception 'Only an Admin approves disabling a vehicle' using errcode = '42501';
    end if;
    if new.status in ('sent', 'confirmed')
       and (new.observed_at is null or new.observed_speed_kmh is distinct from 0 or new.observed_ignition_on is distinct from false) then
      raise exception 'Never disable while moving: the Tracker must show the vehicle stationary with the ignition off'
        using errcode = '23514';
    end if;
    if new.status in ('sent', 'confirmed') and new.observed_at < coalesce(new.sent_at, now()) - interval '5 minutes' then
      raise exception 'The Tracker reading is more than 5 minutes old: read it again before disabling' using errcode = '23514';
    end if;
  end if;
  -- the who and why of a command never change after it is logged
  if tg_op = 'UPDATE' and (new.requested_by is distinct from old.requested_by or new.reason is distinct from old.reason
       or new.command is distinct from old.command or new.vehicle_id is distinct from old.vehicle_id
       or new.actor_type is distinct from old.actor_type) then
    raise exception 'A logged tracker command cannot be rewritten' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger tracker_commands_guard before insert or update on tracker_commands
  for each row execute function app.guard_tracker_command();

-- ---------------------------------------------------------------- franchisor fleet report
-- The rental fleet = vehicles on the Fleet Policy. Turo-Only vehicles are never counted.
create or replace function app.fleet_count(p_on date default app.today(), p_exclude_exit_notice boolean default false)
returns integer language sql stable security definer set search_path = public, app as $$
  select count(*)::integer from vehicles v
   where v.management_mode <> 'turo_only'
     and v.fleet_policy_added_on is not null and v.fleet_policy_added_on <= p_on
     and (v.fleet_policy_removed_on is null or v.fleet_policy_removed_on > p_on)
     and (not p_exclude_exit_notice or v.status <> 'exit_notice')
$$;

create table fleet_reports (
  id               uuid primary key default gen_random_uuid(),
  report_month     date not null unique check (extract(day from report_month) = 1),  -- due on the 1st
  as_of            date not null,
  vehicle_count    integer not null check (vehicle_count >= 0),
  min_required     integer not null default 10,
  meets_minimum    boolean generated always as (vehicle_count >= min_required) stored,
  matches_broker_list boolean,                            -- step 2: matched to the broker's vehicle list
  broker_differences text,
  status           text not null default 'draft' check (status in ('draft', 'prepared', 'sent')),
  prepared_by      uuid references users (id),
  prepared_at      timestamptz,
  sent_to          text,
  sent_at          timestamptz,
  document_id      uuid references documents (id),
  message_id       uuid references messages (id),
  created_at       timestamptz not null default now(),
  check (status <> 'sent' or sent_at is not null)
);

create table fleet_report_vehicles (
  id              uuid primary key default gen_random_uuid(),
  fleet_report_id uuid not null references fleet_reports (id) on delete cascade,
  vehicle_id      uuid not null references vehicles (id),
  change          text not null default 'listed' check (change in ('listed', 'added', 'removed')),
  year            smallint not null,
  make            text not null,
  model           text not null,
  vin             text not null,
  plate           text,
  date_added      date,
  date_removed    date,
  unique (fleet_report_id, vehicle_id, change)
);

-- Weekly recount (each Monday) and any ad hoc count.
create table fleet_counts (
  id             uuid primary key default gen_random_uuid(),
  counted_on     date not null,
  on_policy      integer not null,
  less_exit_notice integer not null,                     -- count less cars under exit notice
  min_required   integer not null,
  warned_admin   boolean not null default false,
  counted_by     uuid references users (id),
  created_at     timestamptz not null default now(),
  unique (counted_on)
);

-- Build (or rebuild while still a draft) the report for a month from the fleet register.
create or replace function app.build_fleet_report(p_month date, p_by uuid default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  v_month date := app.month_start(p_month);
  v_prev date := (app.month_start(p_month) - interval '1 month')::date;
  v_id uuid;
  v_count integer := app.fleet_count(app.month_start(p_month));
begin
  insert into fleet_reports (report_month, as_of, vehicle_count, min_required, status, prepared_by, prepared_at)
  values (v_month, v_month, v_count, (app.settings(v_month)).min_fleet_count, 'prepared', p_by, now())
  on conflict (report_month) do update
     set vehicle_count = excluded.vehicle_count, as_of = excluded.as_of, prepared_by = excluded.prepared_by,
         prepared_at = excluded.prepared_at, status = 'prepared'
   where fleet_reports.status <> 'sent'
  returning id into v_id;
  if v_id is null then
    raise exception 'The fleet report for % has already been sent', v_month;
  end if;
  delete from fleet_report_vehicles where fleet_report_id = v_id;
  insert into fleet_report_vehicles (fleet_report_id, vehicle_id, change, year, make, model, vin, plate, date_added, date_removed)
  select v_id, v.id,
         case when v.fleet_policy_added_on >= v_prev then 'added' else 'listed' end,
         v.year, v.make, v.model, v.vin, v.plate, v.fleet_policy_added_on, null
    from vehicles v
   where v.management_mode <> 'turo_only' and v.fleet_policy_added_on <= v_month
     and (v.fleet_policy_removed_on is null or v.fleet_policy_removed_on > v_month)
  union all
  select v_id, v.id, 'removed', v.year, v.make, v.model, v.vin, v.plate, v.fleet_policy_added_on, v.fleet_policy_removed_on
    from vehicles v
   where v.fleet_policy_removed_on > v_prev and v.fleet_policy_removed_on <= v_month;
  return v_id;
end $$;

-- The fleet must be 10 or more at all times. A vehicle's return is never delayed, so the
-- database does not block a removal; it raises an urgent admin task the moment a change
-- leaves the count at the warning level (11) or below.
create or replace function app.watch_fleet_minimum() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_set program_settings := app.settings();
  v_count integer;
begin
  if (tg_op = 'UPDATE' and (new.fleet_policy_removed_on is distinct from old.fleet_policy_removed_on
        or new.status is distinct from old.status)
      and (new.fleet_policy_removed_on is not null or new.status in ('exit_notice', 'exited', 'total_loss'))) then
    v_count := app.fleet_count(app.today(), true);
    if v_set.id is not null and v_count <= v_set.fleet_warning_count then
      insert into tasks (queue, task_type, title, detail, procedure_no, priority, vehicle_id, escalated, escalated_at, escalation_reason)
      values ('admin', 'fleet_minimum',
              case when v_count < v_set.min_fleet_count then 'Fleet is below the franchise minimum' else 'Fleet is at the franchise warning level' end,
              format('%s vehicles on the Fleet Policy, less those under exit notice. Minimum %s.', v_count, v_set.min_fleet_count),
              20, 'urgent', new.id, true, now(), 'count under 10 or about to be');
    end if;
  end if;
  return new;
end $$;
create trigger vehicles_watch_fleet_minimum after update on vehicles
  for each row execute function app.watch_fleet_minimum();
