-- 0020_operations.sql
-- Day-to-day operations on top of the request-to-book model of migration 0016:
--
--   1. Pickup and return for field staff on a phone: app.complete_handover() and
--      app.complete_return(), the required photo list per report kind and vehicle class, and the
--      check that stops a handover or a return with photos missing.
--   2. After the return: app.assess_check_in() (the post-rental charge lines), damage found in
--      the 48-hour photo review, app.issue_booking_statement() and app.settle_deposit().
--   3. Field jobs: create, assign, reassign, accept, start, complete, cancel; delivery and pickup
--      jobs created when a booking with delivery is confirmed; today's and tomorrow's list per
--      staff member; vehicle_moves (who drove which car, from when to when).
--   4. Calendar: field jobs, vehicle moves and Turo trips on the master calendar; preview and
--      apply for drag and resize; the per-vehicle calendar with everything for one car.
--   5. Rates and fees: app.set_rate_card() with history, per-vehicle fee overrides, per-booking
--      fee terms, bulk rate change with preview.
--   6. Tasks: rules per task type (queue, priority, due time), the triggers that create tasks,
--      complete, assign, snooze, escalate, the work-queue views per role, quick replies.
--   7. Scheduled jobs that are pure SQL: deposits-due, ops-watch, expiry-watch, reconcile.
--   8. Incidents and breakdowns: opening one with its first-response steps, vehicle swap,
--      tracker disable request and approval.
--   9. Reconciliation of processor payouts against payments.
--
-- Relies on migrations 0001 to 0017 only. Notes, decisions and assumptions:
-- docs/changes/0020_operations.md.
--
-- No enum value is added here, so nothing in this file is affected by the rule that a new enum
-- value cannot be used in the transaction that adds it. Where a view or an SQL-language function
-- compares booking statuses it still compares status::text, as migration 0016 does, so that this
-- file can be applied in the same transaction as an earlier one if a host ever does that.
--
-- Events (app.emit_event of migration 0017) are emitted only for things that start in the
-- functions and triggers of this file. Status changes of bookings, payments, statements and
-- incidents are turned into events elsewhere. Dedupe key: code:entity_id:discriminator.

-- ================================================================ 1. settings and new columns
alter table program_settings
  add column if not exists opening_hours jsonb not null
    default '{"open": "09:00", "close": "18:00", "days": [1, 2, 3, 4, 5, 6, 7]}'::jsonb,
  add column if not exists insurer_terms_days integer not null default 30,
  -- the waiting times and warning windows of the operating procedures, so an Admin can change them
  add column if not exists incident_report_hours          integer not null default 48 check (incident_report_hours > 0),   -- renter's written report after an accident
  add column if not exists tracker_notice_minutes         integer not null default 60 check (tracker_notice_minutes >= 0), -- notice before a disable, where required
  add column if not exists tracker_reading_max_minutes    integer not null default 5 check (tracker_reading_max_minutes between 1 and 5),
  add column if not exists statement_interest_days        integer not null default 7 check (statement_interest_days >= 0), -- interest starts this long after a statement
  add column if not exists deposit_due_warning_business_days integer not null default 2 check (deposit_due_warning_business_days >= 0),
  add column if not exists holdback_warning_days          integer not null default 3 check (holdback_warning_days >= 0),
  add column if not exists chase_offer_hours              integer not null default 6 check (chase_offer_hours > 0),
  add column if not exists verification_due_hours         integer not null default 24 check (verification_due_hours >= 0), -- before pickup
  add column if not exists chase_verification_hours       integer not null default 48 check (chase_verification_hours > 0),
  add column if not exists handover_schedule_hours        integer not null default 24 check (handover_schedule_hours >= 0), -- before pickup
  add column if not exists take_deposit_lead_minutes      integer not null default 60 check (take_deposit_lead_minutes >= 0),
  add column if not exists job_acknowledge_lead_minutes   integer not null default 120 check (job_acknowledge_lead_minutes >= 0),
  add column if not exists late_admin_minutes             integer not null default 120 check (late_admin_minutes >= 0),
  add column if not exists provisional_watch_days         integer not null default 3 check (provisional_watch_days >= 0),
  add column if not exists turo_expiry_notice_days        integer not null default 14 check (turo_expiry_notice_days >= 0),
  add column if not exists plate_renewal_notice_days      integer not null default 30 check (plate_renewal_notice_days >= 0),
  add column if not exists payout_unmatched_business_days integer not null default 5 check (payout_unmatched_business_days >= 0),
  add column if not exists early_return_minutes           integer not null default 60 check (early_return_minutes >= 0);
comment on column program_settings.opening_hours is
  'Toronto opening hours: open and close as HH:MI, days as ISO weekdays (1 = Monday). Task due times that count "in opening hours" use them.';
comment on column program_settings.insurer_terms_days is 'Days after which an unpaid insurer invoice is called overdue in lists and reminders.';

-- The Deposit may be waived by an Admin before handover. The amount waived is kept.
alter table bookings
  add column if not exists deposit_waived_cents  bigint not null default 0 check (deposit_waived_cents >= 0),
  add column if not exists deposit_waived_by     uuid references users (id),
  add column if not exists deposit_waived_at     timestamptz,
  add column if not exists deposit_waiver_reason text;

-- Condition reports: what the phone checklist records beyond migration 0006.
alter table condition_reports
  add column if not exists renter_signature_ref     text,       -- reference to the stored on-screen signature
  add column if not exists staff_signature_ref      text,
  add column if not exists renter_declined_to_sign  boolean not null default false,
  add column if not exists renter_decline_reason    text,
  add column if not exists car_diagram              jsonb,      -- damage positions on the car outline
  add column if not exists belongings_found         text,
  add column if not exists findings                 jsonb,      -- kilometres, fuel, lateness, cleaning, keys, damage (T7)
  add column if not exists completed_at             timestamptz, -- signed and closed: nothing in it changes after this
  add column if not exists completed_by             uuid references users (id);

alter table condition_report_damages
  add column if not exists kind              text,              -- scratch, dent, chip, crack, tear, stain, missing part, other
  add column if not exists size_cm           numeric(7, 1) check (size_cm >= 0),
  add column if not exists position          jsonb,             -- where on the car diagram
  add column if not exists status_vs_pickup  text check (status_vs_pickup in ('unchanged', 'worse', 'new'));

alter table condition_report_photos
  add column if not exists device_taken_at timestamptz,         -- the phone's own clock, for evidence
  add column if not exists latitude        numeric(9, 6),
  add column if not exists longitude       numeric(9, 6),
  add column if not exists width           integer check (width > 0),
  add column if not exists height          integer check (height > 0),
  add column if not exists quality_flags   jsonb,               -- blur, darkness, size warnings from the phone
  add column if not exists purge_after     timestamptz;         -- a licence photo taken at handover: kept 90 days

-- Charge lines made by the Check-in assessment: which finding a line is for, and its records.
alter table booking_line_items
  add column if not exists assessment_key  text,                -- for example 'mileage_overage', 'damage:<incident>'
  add column if not exists supporting_refs jsonb;               -- condition reports, photos, receipts, estimates
create index if not exists booking_line_items_assessment_idx on booking_line_items (booking_id, assessment_key)
  where assessment_key is not null;

alter table field_jobs
  add column if not exists auto_created  boolean not null default false,  -- made by the booking, not typed by Fleet
  add column if not exists cancel_reason text,
  add column if not exists created_by    uuid references users (id);

alter table tasks
  add column if not exists sla_minutes     integer,             -- the time allowed, from the task's rule
  add column if not exists wake_at         timestamptz,         -- a waiting task comes back at this time
  add column if not exists waiting_reason  text,
  add column if not exists completion_rule text,                -- what must be true before the task can be marked done
  add column if not exists completion_note text,
  add column if not exists dedupe_key      text;                -- one open task per key
create unique index if not exists tasks_one_open_per_key on tasks (dedupe_key)
  where dedupe_key is not null and status in ('open', 'in_progress', 'waiting');
create index if not exists tasks_wake_idx on tasks (wake_at) where status = 'waiting';

create sequence if not exists renter_statement_number_seq start 20001;

-- ================================================================ 2. who is acting (by user id)
-- The server acts for a named user, so these take the user's id (as app.user_is_staff of 0016).
create or replace function app.user_va_has(p_user uuid, variadic p_functions text[] default '{}') returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (
    select 1 from user_roles r join users u on u.id = r.user_id
      join staff_profiles sp on sp.user_id = r.user_id and sp.staff_type = 'va' and sp.is_active
     where r.user_id = p_user and r.role = 'va' and u.status = 'active'
       and (cardinality(p_functions) = 0 or sp.va_function::text = any (p_functions)))
$$;

create or replace function app.user_is_field(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (
    select 1 from user_roles r join users u on u.id = r.user_id
      join staff_profiles sp on sp.user_id = r.user_id and sp.staff_type = 'field' and sp.is_active
     where r.user_id = p_user and r.role = 'field' and u.status = 'active')
$$;

-- Fleet work: an Admin or a Fleet assistant.
create or replace function app.user_runs_fleet(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.user_is_admin(p_user) or app.user_va_has(p_user, 'fleet')
$$;

-- Money work: an Admin or a Finance assistant.
create or replace function app.user_runs_finance(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.user_is_admin(p_user) or app.user_va_has(p_user, 'finance')
$$;

-- True when the statement comes from a browser session (not the server, not a nested trigger).
create or replace function app.from_browser() returns boolean
language sql stable as $$ select pg_catalog.current_setting('role', true) is not distinct from 'authenticated' $$;

-- ================================================================ 3. opening hours
-- The instant that is p_minutes of opening time after p_from. Outside opening hours the clock
-- waits for the next opening. Used for "reply in 15 minutes during opening hours".
create or replace function app.add_opening_minutes(p_from timestamptz, p_minutes integer) returns timestamptz
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_hours jsonb := (app.settings(app.local_date(p_from))).opening_hours;
  v_open time := coalesce((v_hours ->> 'open')::time, time '09:00');
  v_close time := coalesce((v_hours ->> 'close')::time, time '18:00');
  v_days integer[] := coalesce((select array_agg(d::integer) from jsonb_array_elements_text(v_hours -> 'days') d), array[1, 2, 3, 4, 5, 6, 7]);
  v_local timestamp := p_from at time zone 'America/Toronto';
  v_left integer := greatest(coalesce(p_minutes, 0), 0);
  v_day date := (p_from at time zone 'America/Toronto')::date;
  v_start timestamp;
  v_end timestamp;
  v_room integer;
  v_guard integer := 0;
begin
  if v_close <= v_open or cardinality(v_days) = 0 then
    return p_from + make_interval(mins => v_left);     -- hours not usable: count plain minutes
  end if;
  loop
    v_guard := v_guard + 1;
    if v_guard > 400 then return p_from + make_interval(mins => p_minutes); end if;
    if extract(isodow from v_day)::integer = any (v_days) then
      v_start := greatest(v_local, v_day + v_open);
      v_end := v_day + v_close;
      if v_start < v_end then
        v_room := floor(extract(epoch from (v_end - v_start)) / 60)::integer;
        if v_left <= v_room then
          return (v_start + make_interval(mins => v_left)) at time zone 'America/Toronto';
        end if;
        v_left := v_left - v_room;
      end if;
    end if;
    v_day := v_day + 1;
    v_local := v_day::timestamp;
  end loop;
end $$;

-- ================================================================ 4. the photo set
-- Which shots a Condition Report needs, in order. A row with no vehicle class applies to every
-- class; a row for one class replaces it for that class (and may switch a shot off).
create table required_shots (
  id            uuid primary key default gen_random_uuid(),
  report_kind   text not null check (report_kind in ('baseline', 'pickup', 'return', 'swap_out', 'swap_in', 'exit', 'ready')),
  vehicle_class vehicle_class,                       -- null = every class
  seq           integer not null check (seq > 0),    -- the fixed order of procedure 3
  shot          text not null,
  is_required   boolean not null default true,
  guide         text,                                -- the hint shown on the phone
  created_at    timestamptz not null default now()
);
create unique index required_shots_all_key on required_shots (report_kind, shot) where vehicle_class is null;
create unique index required_shots_class_key on required_shots (report_kind, vehicle_class, shot) where vehicle_class is not null;

insert into required_shots (report_kind, seq, shot, guide)
select k.kind, s.seq, s.shot, s.guide
  from unnest(array['baseline', 'pickup', 'return', 'swap_out', 'swap_in', 'exit']) k(kind)
 cross join (values
    (1, 'front', 'Stand 3 metres back, whole car in frame'),
    (2, 'front_left', 'Front-left corner'),
    (3, 'left', 'Left side'),
    (4, 'rear_left', 'Rear-left corner'),
    (5, 'rear', 'Rear'),
    (6, 'rear_right', 'Rear-right corner'),
    (7, 'right', 'Right side'),
    (8, 'front_right', 'Front-right corner'),
    (9, 'roof', 'From the rear corner, phone held high'),
    (10, 'windshield', 'Windshield'),
    (11, 'wheel_front_left', 'Front-left wheel'),
    (12, 'wheel_front_right', 'Front-right wheel'),
    (13, 'wheel_rear_left', 'Rear-left wheel'),
    (14, 'wheel_rear_right', 'Rear-right wheel'),
    (15, 'instrument_cluster', 'Ignition on. Odometer and warning lights readable'),
    (16, 'front_seats', 'Front seats'),
    (17, 'rear_seats', 'Rear seats'),
    (18, 'trunk', 'Trunk'),
    (19, 'keys', 'All keys on the seat')) s(seq, shot, guide);
-- the four "ready" photos after detailing (procedure 18, step 8)
insert into required_shots (report_kind, seq, shot, guide) values
  ('ready', 1, 'front', 'Front'), ('ready', 2, 'rear', 'Rear'),
  ('ready', 3, 'front_seats', 'Front seats'), ('ready', 4, 'instrument_cluster', 'Instrument cluster');

-- The shots one report needs: the class row when there is one, else the general row.
create or replace function app.required_shots_for(p_kind text, p_class vehicle_class)
returns table (seq integer, shot text, guide text)
language sql stable security definer set search_path = public, app as $$
  select r.seq, r.shot, r.guide
    from (select distinct on (s.shot) s.seq, s.shot, s.guide, s.is_required
            from required_shots s
           where s.report_kind = p_kind and (s.vehicle_class is null or s.vehicle_class = p_class)
           order by s.shot, (s.vehicle_class is null)) r
   where r.is_required
   order by r.seq
$$;

-- What stops a report from being completed: a required shot missing, the set out of order, or a
-- damage mark without its close-up. An empty array means the photo set is complete.
create or replace function app.condition_report_problems(p_report uuid) returns text[]
language plpgsql stable security definer set search_path = public, app as $$
declare
  c condition_reports;
  v_class vehicle_class;
  v_problems text[] := '{}';
  v_want text[];
  v_got text[];
begin
  select * into c from condition_reports where id = p_report;
  if c.id is null then raise exception 'Condition Report % not found', p_report; end if;
  select class into v_class from vehicles where id = c.vehicle_id;

  select coalesce(array_agg('missing photo: ' || r.shot order by r.seq), '{}') into v_problems
    from app.required_shots_for(c.kind, v_class) r
   where not exists (select 1 from condition_report_photos p where p.condition_report_id = p_report and p.shot = r.shot);

  if cardinality(v_problems) = 0 then
    -- same order as the list: compare the required shots by the first photo of each
    select array_agg(r.shot order by r.seq) into v_want from app.required_shots_for(c.kind, v_class) r;
    select array_agg(x.shot order by x.first_seq) into v_got
      from (select p.shot, min(p.seq) as first_seq from condition_report_photos p
             where p.condition_report_id = p_report and p.shot = any (coalesce(v_want, '{}'))
             group by p.shot) x;
    if v_want is distinct from v_got then
      v_problems := v_problems || 'the photo set is not in the fixed order'::text;
    end if;
  end if;

  select v_problems || coalesce(array_agg('damage ' || d.label || ' has no close-up photo' order by d.label), '{}') into v_problems
    from condition_report_damages d
   where d.condition_report_id = p_report
     and not exists (select 1 from condition_report_photos p where p.damage_id = d.id);
  return v_problems;
end $$;

-- ================================================================ 5. vehicle moves
-- Every time staff drive a car: who, why, from when to when. The toll matcher reads this to
-- tell a staff move from a rental.
create table vehicle_moves (
  id             uuid primary key default gen_random_uuid(),
  vehicle_id     uuid not null references vehicles (id),
  staff_user_id  uuid not null references users (id),       -- the driver
  purpose        text not null check (purpose in (
                   'delivery', 'pickup_from_renter', 'detail', 'photo_shoot', 'registry_run', 'tracker_install',
                   'tracker_removal', 'recovery', 'service', 'repositioning', 'swap', 'other')),
  started_at     timestamptz not null,
  ended_at       timestamptz,                               -- null = still out
  from_place     text,
  to_place       text,
  odometer_start integer check (odometer_start >= 0),
  odometer_end   integer check (odometer_end >= 0),
  field_job_id   uuid references field_jobs (id),
  booking_id     uuid references bookings (id),
  notes          text,
  created_by     uuid references users (id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  check (ended_at is null or ended_at >= started_at),
  check (odometer_end is null or odometer_start is null or odometer_end >= odometer_start)
);
create unique index vehicle_moves_one_open on vehicle_moves (vehicle_id) where ended_at is null;
create index vehicle_moves_vehicle_idx on vehicle_moves (vehicle_id, started_at);
create index vehicle_moves_staff_idx on vehicle_moves (staff_user_id, started_at);
create index vehicle_moves_job_idx on vehicle_moves (field_job_id);
create trigger vehicle_moves_updated before update on vehicle_moves for each row execute function app.set_updated_at();

-- Start a move. A move still open on the same car is closed at that moment (the car cannot be
-- driven by two people at once). Returns the move's id.
create or replace function app.start_vehicle_move(
  p_vehicle uuid, p_staff uuid, p_purpose text, p_from_place text default null, p_odometer_start integer default null,
  p_job uuid default null, p_booking uuid default null, p_at timestamptz default now(), p_by uuid default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
begin
  if p_staff is null or not (app.user_is_field(p_staff) or app.user_is_staff(p_staff)) then
    raise exception 'A vehicle move is driven by a member of staff' using errcode = '42501';
  end if;
  update vehicle_moves set ended_at = greatest(p_at, started_at) where vehicle_id = p_vehicle and ended_at is null;
  insert into vehicle_moves (vehicle_id, staff_user_id, purpose, started_at, from_place, odometer_start, field_job_id, booking_id, created_by)
  values (p_vehicle, p_staff, p_purpose, p_at, p_from_place, p_odometer_start, p_job, p_booking, coalesce(p_by, p_staff))
  returning id into v_id;
  return v_id;
end $$;

create or replace function app.end_vehicle_move(
  p_move uuid, p_to_place text default null, p_odometer_end integer default null, p_at timestamptz default now())
returns void language plpgsql security definer set search_path = public, app as $$
declare
  m vehicle_moves;
begin
  select * into m from vehicle_moves where id = p_move for update;
  if m.id is null then raise exception 'Vehicle move % not found', p_move; end if;
  if m.ended_at is not null then
    raise exception 'This move has already ended' using errcode = '23514';
  end if;
  update vehicle_moves
     set ended_at = greatest(p_at, m.started_at), to_place = coalesce(p_to_place, to_place),
         odometer_end = coalesce(p_odometer_end, odometer_end)
   where id = p_move;
  if p_odometer_end is not null then
    update vehicles set odometer_km = p_odometer_end where id = m.vehicle_id and coalesce(odometer_km, 0) < p_odometer_end;
  end if;
end $$;

-- ================================================================ 6. tasks: rules, raising, working
-- One row per kind of task: which queue it lands in, how urgent it is, how long it may wait and
-- what must be true before it can be marked done. The times come from the operating procedures.
--   due_kind: opening_minutes (minutes counted inside opening hours), minutes (plain minutes),
--             business_days (the end of that business day), end_of_day, or none (the caller
--             gives the due time, for example "24 hours before pickup").
create table task_rules (
  task_type       text primary key,
  queue           text not null check (queue in ('finance', 'fleet', 'cs', 'sales', 'admin')),
  title           text not null,                       -- used when the caller gives none
  priority        text not null default 'normal' check (priority in ('low', 'normal', 'high', 'urgent')),
  due_kind        text not null default 'none' check (due_kind in ('opening_minutes', 'minutes', 'business_days', 'end_of_day', 'none')),
  due_amount      integer check (due_amount >= 0),
  procedure_no    smallint check (procedure_no between 1 and 20),
  completion_rule text,
  description     text,
  check (due_kind in ('none', 'end_of_day') or due_amount is not null)
);

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  -- procedure 1: inquiry to confirmed booking
  ('booking_request',         'cs',      'New booking request',                             'high',   'opening_minutes', 15,  1,  'offer_sent_or_declined', 'Reply in 15 minutes during opening hours'),
  ('offer_change_requested',  'cs',      'The customer asked for a change',                 'high',   'opening_minutes', 15,  1,  'offer_sent_or_declined', 'Reply in 15 minutes during opening hours'),
  ('offer_expired',           'cs',      'An offer expired without an answer',              'normal', 'opening_minutes', 120, 1,  'offer_sent_or_declined', 'Send again or decline within 2 hours'),
  ('reoffer_booking',         'cs',      'Re-offer: the car was taken',                     'high',   'opening_minutes', 30,  1,  'offer_sent_or_declined', 'Offer another car within 30 minutes; urgent if a payment was taken'),
  ('chase_offer',             'sales',   'Offer expiring soon',                             'normal', 'none',            null, 1, null,                     'An offer expires within 6 hours and is not approved'),
  ('insurer_provisional',     'cs',      'Settle the dates of an insurer booking',          'high',   'none',            null, 1, null,                     'Confirmed, not blocking the car, pickup within 3 days'),
  ('booking_change_approval', 'cs',      'A change to a confirmed booking needs the renter','normal', 'opening_minutes', 120, 6,  null,                     'The renter must agree before a confirmed booking moves'),
  -- procedure 2: verification and coverage
  ('offer_approved_paid',     'cs',      'Booking confirmed: verify drivers and coverage',  'normal', 'none',            null, 2, 'drivers_verified',       'Due 24 hours before pickup; no car is released without it'),
  ('verify_renter',           'cs',      'Identity documents or coverage proof to review',  'high',   'none',            null, 2, 'drivers_verified',       'Due 24 hours before pickup'),
  ('chase_verification',      'cs',      'Verification missing, pickup within 48 hours',    'high',   'none',            null, 2, 'drivers_verified',       'Due 24 hours before pickup'),
  -- procedure 3: handover
  ('schedule_handover',       'fleet',   'Schedule the handover',                           'normal', 'none',            null, 3, 'handover_job_assigned',  'The day before pickup: send Field the job'),
  ('job_unacknowledged',      'fleet',   'A field job is not acknowledged',                 'high',   'none',            null, 3, null,                     'Two hours before the job'),
  ('take_deposit',            'finance', 'Take the Deposit before handover',                'high',   'none',            null, 3, 'deposit_taken',          'Due 1 hour before pickup'),
  ('deposit_declined',        'admin',   'Deposit declined at pickup: do not release the car', 'urgent', 'minutes',      0,   3,  'deposit_taken',          'Escalation of procedure 3'),
  ('handover_blocked',        'admin',   'Handover stopped: do not release the car',        'urgent', 'minutes',         0,   3,  null,                     'Wrong person, licence or card mismatch, unfit to drive, Tracker not reporting'),
  ('review_photos',           'fleet',   'Review the Condition Report photos',              'high',   'opening_minutes', 60,  3,  'report_reviewed',        'Photos reviewed within 1 hour'),
  -- procedure 5: post-rental charges and deposit
  ('price_findings',          'finance', 'Price the return findings',                       'normal', 'end_of_day',      null, 5, 'statement_issued',       'Same day as the findings'),
  ('price_damage',            'admin',   'Damage to price: an Admin''s decision',           'high',   'business_days',   1,   5,  null,                     'Any damage line escalates to an Admin'),
  ('release_deposit',         'finance', 'Deposit balance due back',                        'high',   'none',            null, 5, 'deposit_settled',        'Within 7 business days of Check-in; target 2'),
  ('approve_deposit_release', 'admin',   'Approve a deposit release',                       'high',   'none',            null, 5, 'deposit_settled',        'Above the assistant''s limit, or with a hold-back'),
  ('settle_holdback',         'finance', 'Hold-back reaching 30 days',                      'high',   'none',            null, 5, 'holdback_settled',       'Apply or release by day 30'),
  -- procedures 6 and 7
  ('review_extension',        'cs',      'Extension requested',                             'urgent', 'none',            null, 6, 'extension_decided',      'Confirmed in writing and paid before the return time'),
  ('refund_cancellation',     'finance', 'Refund a cancellation',                           'normal', 'business_days',   10,  7,  'refund_decided',         'Refund within 10 business days; target 2'),
  -- procedure 8
  ('late_return',             'fleet',   'Late return',                                     'urgent', 'minutes',         0,   8,  'booking_returned',       'Call, check the Tracker, offer a paid extension'),
  ('late_return_admin',       'admin',   'Rental 2 hours overdue',                          'urgent', 'minutes',         0,   8,  'booking_returned',       'Tell an Admin at 2 hours'),
  ('approve_tracker_disable', 'admin',   'Approve disabling a vehicle',                     'urgent', 'minutes',         0,   8,  'tracker_command_decided', 'Only an Admin approves; never while moving'),
  -- procedures 9 and 10
  ('incident',                'fleet',   'Incident opened',                                 'urgent', 'minutes',         0,   9,  null,                     'Every incident, immediately'),
  ('breakdown',               'fleet',   'Breakdown: dispatch roadside',                    'urgent', 'minutes',         15,  10, null,                     'Roadside dispatched in 15 minutes'),
  ('vehicle_swap',            'fleet',   'Vehicle swapped: complete both Condition Reports', 'urgent', 'minutes',        60,  10, null,                     'Part 4 Return for the old car, Pickup for the new one'),
  -- procedures 12 to 17: owners and vehicles
  ('owner_intake',            'cs',      'New owner vehicle application',                   'normal', 'business_days',   1,   12, null,                     'Reply in 1 business day'),
  ('check_owner_document',    'cs',      'Owner document uploaded',                         'normal', 'business_days',   1,   12, null,                     null),
  ('collect_upfront',         'finance', 'Collect the upfront invoice',                     'normal', 'business_days',   2,   12, null,                     'Install Fee and first and last month''s Insurance Fee'),
  ('book_registry',           'fleet',   'Book the registry visit',                         'normal', 'none',            null, 12, null,                    'Inside the safety certificate''s 36 days'),
  ('safety_certificate_window', 'fleet', 'Safety certificate window closing',               'high',   'none',            null, 12, null,                    'No registry visit booked'),
  ('turo_expiry',             'cs',      'Turo-Only insurance or plate expiring',           'high',   'none',            null, 13, null,                    '14 days before the expiry'),
  ('plate_renewal',           'fleet',   'Plate renewal due',                               'normal', 'none',            null, 14, null,                    'Renewal month within 30 days'),
  ('debit_failed',            'finance', 'Owner debit failed',                              'high',   'end_of_day',      null, 14, null,                    'Late Fee added; retry on the 18th'),
  ('arrears',                 'finance', 'Owner invoice in arrears',                        'high',   'end_of_day',      null, 14, null,                    'Deduct at the next payout; tell an Admin'),
  ('arrears_removal',         'admin',   'Arrears older than 30 days',                      'high',   'business_days',   1,   14, null,                     'An Admin may remove the vehicle'),
  ('review_statements',       'finance', 'Review the draft owner statements',               'high',   'none',            null, 14, null,                    'Before the payout date'),
  ('owner_exit',              'fleet',   'Owner exit: prepare the re-transfer',             'normal', 'none',            null, 16, null,                    'By the Exit Date'),
  ('list_vehicle',            'fleet',   'List the new vehicle',                            'normal', 'business_days',   2,   17, null,                     'Live in 2 business days'),
  -- procedures 18 to 20
  ('schedule_detail',         'fleet',   'Schedule the detail after a return',              'normal', 'minutes',         1440, 18, null,                    'Within 24 hours of return and before the next handover'),
  ('lost_property',           'cs',      'Belongings found in a returned car',              'normal', 'business_days',   1,   18, null,                     'Bagged and labelled with the booking number'),
  ('opening_checks',          'fleet',   'Opening checks',                                  'high',   'none',            null, 19, null,                    'By 9:00'),
  ('closing_checks',          'fleet',   'Closing checks',                                  'high',   'none',            null, 19, null,                    'By 18:00'),
  ('reconcile',               'finance', 'Processor payout does not match',                 'high',   'end_of_day',      null, 19, 'reconciliation_matched', 'A payment that does not match escalates at the closing check'),
  ('unmatched_payment',       'finance', 'Card payment not found in any payout',            'normal', 'end_of_day',      null, 19, null,                    null),
  ('fleet_report',            'finance', 'Prepare the franchisor fleet report',             'high',   'none',            null, 20, null,                    'Sent on the 1st; prepared the business day before'),
  ('moderate_review',         'cs',      'Review to moderate',                              'low',    'business_days',   1,   null, null,                   null);

-- The due time a rule gives, counted from p_from. Null when the caller must give it.
create or replace function app.task_due(p_due_kind text, p_due_amount integer, p_from timestamptz default now()) returns timestamptz
language sql stable security definer set search_path = public, app as $$
  select case p_due_kind
    when 'opening_minutes' then app.add_opening_minutes(p_from, p_due_amount)
    when 'minutes' then p_from + make_interval(mins => p_due_amount)
    when 'business_days' then app.local_midnight(app.add_business_days(app.local_date(p_from), p_due_amount) + 1)
    when 'end_of_day' then app.local_midnight(app.local_date(p_from) + 1)
  end
$$;

-- Every task, however it is inserted, takes what it lacks from its rule. A task type with no
-- rule is left as written. An explicit priority other than the column default is kept.
create or replace function app.task_fill_from_rule() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  r task_rules;
begin
  select * into r from task_rules where task_type = new.task_type;
  if r.task_type is null then return new; end if;
  new.procedure_no := coalesce(new.procedure_no, r.procedure_no);
  if new.priority = 'normal' then new.priority := r.priority; end if;
  new.completion_rule := coalesce(new.completion_rule, r.completion_rule);
  if r.due_kind in ('opening_minutes', 'minutes') then new.sla_minutes := coalesce(new.sla_minutes, r.due_amount); end if;
  new.due_at := coalesce(new.due_at, app.task_due(r.due_kind, r.due_amount, coalesce(new.created_at, now())));
  return new;
end $$;
create trigger tasks_fill_from_rule before insert on tasks
  for each row execute function app.task_fill_from_rule();

-- Raise a task. With a dedupe key, a task that is still open under that key is returned instead
-- of a second one. The queue, title, priority and due time come from the rule unless given.
create or replace function app.raise_task(
  p_type text, p_title text default null, p_detail text default null,
  p_booking uuid default null, p_vehicle uuid default null, p_owner uuid default null, p_renter uuid default null,
  p_related_table text default null, p_related_id uuid default null,
  p_due_at timestamptz default null, p_priority text default null, p_dedupe text default null,
  p_queue text default null, p_created_by uuid default null, p_escalation_reason text default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  r task_rules;
  v_id uuid;
begin
  select * into r from task_rules where task_type = p_type;
  if r.task_type is null and (p_queue is null or p_title is null) then
    raise exception 'Task type "%" has no rule: give the queue and the title', p_type using errcode = '22023';
  end if;
  if p_dedupe is not null then
    select id into v_id from tasks where dedupe_key = p_dedupe and status in ('open', 'in_progress', 'waiting');
    if v_id is not null then return v_id; end if;
  end if;
  insert into tasks (queue, task_type, title, detail, priority, due_at, booking_id, vehicle_id, owner_id, renter_id,
                     related_table, related_id, created_by, dedupe_key, escalated, escalated_at, escalation_reason)
  values (coalesce(p_queue, r.queue), p_type, coalesce(p_title, r.title), p_detail, coalesce(p_priority, r.priority, 'normal'), p_due_at,
          p_booking, p_vehicle, p_owner, p_renter, p_related_table, p_related_id, p_created_by, p_dedupe,
          p_escalation_reason is not null, case when p_escalation_reason is not null then now() end, p_escalation_reason)
  returning id into v_id;
  return v_id;
end $$;

-- Close the open tasks of the given types on one booking: the step they asked for has happened.
create or replace function app.resolve_tasks(p_types text[], p_booking uuid, p_by uuid default null, p_note text default null,
                                             p_cancel boolean default false)
returns integer language plpgsql security definer set search_path = public, app as $$
declare
  n integer;
begin
  update tasks
     set status = case when p_cancel then 'cancelled' else 'done' end,
         completed_at = now(), completed_by = p_by, completion_note = coalesce(p_note, completion_note)
   where booking_id = p_booking and task_type = any (p_types) and status in ('open', 'in_progress', 'waiting');
  get diagnostics n = row_count;
  return n;
end $$;

-- May this user work this queue? An Admin always; an assistant in the queue's own function.
create or replace function app.user_works_queue(p_user uuid, p_queue text) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.user_is_admin(p_user) or (p_queue <> 'admin' and app.user_va_has(p_user, p_queue))
$$;

-- Why a task cannot be marked done yet; null when it can.
create or replace function app.task_completion_problem(p_task uuid) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  t tasks;
  b bookings;
begin
  select * into t from tasks where id = p_task;
  if t.id is null then raise exception 'Task % not found', p_task; end if;
  if t.completion_rule is null then return null; end if;
  if t.booking_id is not null then select * into b from bookings where id = t.booking_id; end if;

  if t.completion_rule = 'offer_sent_or_declined' then
    if b.id is not null and b.status = 'requested' then
      return 'The request is still waiting: send an offer or decline it';
    end if;
  elsif t.completion_rule = 'drivers_verified' then
    if b.id is not null and b.status in ('confirmed', 'pending_payment') then
      if not exists (select 1 from booking_drivers d where d.booking_id = b.id and d.role = 'renter')
         or exists (select 1 from booking_drivers d join drivers dr on dr.id = d.driver_id
                     where d.booking_id = b.id and d.identity_verified_on is null and dr.identity_status <> 'failed') then
        return 'Every driver must be verified or rejected first';
      end if;
      if b.booking_type <> 'owner' and b.coverage_confirmed_at is null
         and not exists (select 1 from coverage_proofs c where c.booking_id = b.id and c.status = 'rejected') then
        return 'The Coverage Option must be confirmed or rejected first';
      end if;
    end if;
  elsif t.completion_rule = 'handover_job_assigned' then
    if b.id is not null and b.status = 'confirmed' and not exists (
         select 1 from field_jobs j where j.booking_id = b.id and j.kind in ('handover', 'delivery')
            and j.status <> 'cancelled' and j.assigned_to is not null) then
      return 'Assign a field staff member to the handover first';
    end if;
  elsif t.completion_rule = 'deposit_taken' then
    if b.id is not null and b.status = 'confirmed' and b.deposit_cents > 0 and not exists (
         select 1 from deposits d where d.booking_id = b.id and d.status in ('held', 'captured')) then
      return 'The Deposit has not been taken or waived';
    end if;
  elsif t.completion_rule = 'report_reviewed' then
    if t.related_table = 'condition_reports' and exists (
         select 1 from condition_reports c where c.id = t.related_id and c.reviewed_at is null) then
      return 'The photo set has not been reviewed';
    end if;
  elsif t.completion_rule = 'statement_issued' then
    if b.id is not null and b.status = 'returned' and not exists (
         select 1 from booking_statements s where s.booking_id = b.id and s.kind = 'check_in') then
      return 'The Check-in statement has not been issued';
    end if;
  elsif t.completion_rule = 'deposit_settled' then
    if b.id is not null and exists (
         select 1 from deposits d where d.booking_id = b.id and d.status in ('held', 'captured')
            and d.amount_cents - d.applied_cents - d.released_cents - d.held_back_cents > 0) then
      return 'A Deposit balance is still to be applied or released';
    end if;
  elsif t.completion_rule = 'holdback_settled' then
    if b.id is not null and exists (select 1 from deposits d where d.booking_id = b.id and d.held_back_cents > 0) then
      return 'The held-back amount is still held';
    end if;
  elsif t.completion_rule = 'extension_decided' then
    if t.related_table = 'booking_extensions' and exists (
         select 1 from booking_extensions e where e.id = t.related_id and e.status = 'requested') then
      return 'The extension is still waiting for an answer';
    end if;
  elsif t.completion_rule = 'refund_decided' then
    if b.id is not null and exists (select 1 from booking_cancellations c where c.booking_id = b.id and c.refund_cents > 0)
       and not exists (select 1 from refunds r where r.booking_id = b.id and r.status <> 'pending_approval') then
      return 'The refund has not been approved or rejected';
    end if;
  elsif t.completion_rule = 'booking_returned' then
    if b.id is not null and b.status = 'on_rent' then
      return 'The vehicle is not back yet';
    end if;
  elsif t.completion_rule = 'tracker_command_decided' then
    if t.related_table = 'tracker_commands' and exists (
         select 1 from tracker_commands c where c.id = t.related_id and c.status = 'requested') then
      return 'The request has not been approved or rejected';
    end if;
  elsif t.completion_rule = 'reconciliation_matched' then
    if t.related_table = 'payout_reconciliations' and exists (
         select 1 from payout_reconciliations p where p.id = t.related_id and p.status in ('open', 'unmatched')) then
      return 'The payout still has unmatched items';
    end if;
  end if;
  return null;
end $$;

-- Take or hand over a task. Taking it yourself starts it.
create or replace function app.assign_task(p_task uuid, p_assignee uuid, p_by uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  t tasks;
begin
  select * into t from tasks where id = p_task for update;
  if t.id is null then raise exception 'Task % not found', p_task; end if;
  if t.status in ('done', 'cancelled') then
    raise exception 'This task is already %', t.status using errcode = '23514';
  end if;
  if not (app.user_works_queue(p_by, t.queue) or coalesce(t.assigned_to = p_by, false)) then
    raise exception 'Not permitted on the % queue', t.queue using errcode = '42501';
  end if;
  if p_assignee is not null and not app.user_works_queue(p_assignee, t.queue) then
    raise exception 'That person does not work the % queue', t.queue using errcode = '23514';
  end if;
  update tasks
     set assigned_to = p_assignee,
         status = case when p_assignee is null then 'open'
                       when p_assignee = p_by then 'in_progress'
                       when status = 'in_progress' then 'open' else status end,
         wake_at = case when p_assignee = p_by then null else wake_at end
   where id = p_task;
end $$;

-- Put a task aside until a time, with the reason. It returns to the queue by itself.
create or replace function app.snooze_task(p_task uuid, p_by uuid, p_wake_at timestamptz, p_reason text) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  t tasks;
begin
  select * into t from tasks where id = p_task for update;
  if t.id is null then raise exception 'Task % not found', p_task; end if;
  if t.status in ('done', 'cancelled') then
    raise exception 'This task is already %', t.status using errcode = '23514';
  end if;
  if not (app.user_works_queue(p_by, t.queue) or coalesce(t.assigned_to = p_by, false)) then
    raise exception 'Not permitted on the % queue', t.queue using errcode = '42501';
  end if;
  if p_wake_at is null or p_wake_at <= now() then
    raise exception 'Give a time in the future for the task to come back' using errcode = '22023';
  end if;
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'Say what the task is waiting for' using errcode = '22023';
  end if;
  update tasks set status = 'waiting', wake_at = p_wake_at, waiting_reason = p_reason where id = p_task;
end $$;

-- Waiting tasks whose time has come go back to the queue. Returns how many.
create or replace function app.wake_tasks(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  n integer;
begin
  update tasks set status = case when assigned_to is null then 'open' else 'in_progress' end, wake_at = null
   where status = 'waiting' and wake_at is not null and wake_at <= p_now;
  get diagnostics n = row_count;
  return n;
end $$;

-- Mark a task done. Refused while the task's completion rule does not hold; an Admin may force
-- it with a note.
create or replace function app.complete_task(p_task uuid, p_by uuid, p_note text default null, p_force boolean default false)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  t tasks;
  v_problem text;
begin
  select * into t from tasks where id = p_task for update;
  if t.id is null then raise exception 'Task % not found', p_task; end if;
  if t.status in ('done', 'cancelled') then
    raise exception 'This task is already %', t.status using errcode = '23514';
  end if;
  if not (app.user_works_queue(p_by, t.queue) or (coalesce(t.assigned_to = p_by, false) and app.user_is_staff(p_by))) then
    raise exception 'Not permitted on the % queue', t.queue using errcode = '42501';
  end if;
  v_problem := app.task_completion_problem(p_task);
  if v_problem is not null then
    if not (p_force and app.user_is_admin(p_by) and btrim(coalesce(p_note, '')) <> '') then
      raise exception '%', v_problem using errcode = '23514';
    end if;
  end if;
  update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = p_note, wake_at = null
   where id = p_task;
end $$;

create or replace function app.cancel_task(p_task uuid, p_by uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  t tasks;
begin
  select * into t from tasks where id = p_task for update;
  if t.id is null then raise exception 'Task % not found', p_task; end if;
  if not app.user_works_queue(p_by, t.queue) then
    raise exception 'Not permitted on the % queue', t.queue using errcode = '42501';
  end if;
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'Give the reason for cancelling the task' using errcode = '22023';
  end if;
  update tasks set status = 'cancelled', completed_at = now(), completed_by = p_by, completion_note = p_reason, wake_at = null
   where id = p_task and status not in ('done', 'cancelled');
end $$;

-- Escalate to an Admin: the task is flagged with the reason and a copy goes to the admin queue.
-- Returns the admin task's id.
create or replace function app.escalate_task(p_task uuid, p_by uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  t tasks;
  v_admin uuid;
begin
  select * into t from tasks where id = p_task for update;
  if t.id is null then raise exception 'Task % not found', p_task; end if;
  if not (app.user_works_queue(p_by, t.queue) or coalesce(t.assigned_to = p_by, false)) then
    raise exception 'Not permitted on the % queue', t.queue using errcode = '42501';
  end if;
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'Give the reason for escalating' using errcode = '22023';
  end if;
  update tasks set escalated = true, escalated_at = now(), escalation_reason = p_reason where id = p_task;
  v_admin := app.raise_task(p_type => t.task_type, p_title => 'Escalated: ' || t.title, p_detail => p_reason,
      p_booking => t.booking_id, p_vehicle => t.vehicle_id, p_owner => t.owner_id, p_renter => t.renter_id,
      p_related_table => 'tasks', p_related_id => t.id, p_due_at => coalesce(t.due_at, now()),
      p_priority => case when t.priority = 'urgent' then 'urgent' else 'high' end,
      p_dedupe => 'escalated:' || t.id, p_queue => 'admin', p_created_by => p_by, p_escalation_reason => p_reason);
  perform app.emit_event('staff_approval_needed', 'task', v_admin,
    jsonb_build_object('approval_type', 'escalation', 'approval_subject', t.title, 'approval_reason', p_reason,
                       'requested_by', p_by, 'requested_at', now(), 'approval_due', coalesce(t.due_at, now()),
                       'task_type', t.task_type, 'queue', t.queue, 'booking_id', t.booking_id),
    'staff_approval_needed:' || v_admin || ':escalated');
  return v_admin;
end $$;

-- Quick replies: snippets staff insert into a message. Kept by an Admin.
create table quick_replies (
  id          uuid primary key default gen_random_uuid(),
  title       text not null,
  body        text not null,
  audience    text not null default 'renter' check (audience in ('renter', 'owner', 'any')),
  category    text,                                   -- for example 'licence', 'alternative car', 'other dates'
  sort_order  integer not null default 0,
  is_active   boolean not null default true,
  created_by  uuid references users (id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create trigger quick_replies_updated before update on quick_replies for each row execute function app.set_updated_at();

-- ================================================================ 7. field jobs
-- The kinds of job in which staff drive the car, so a vehicle move is recorded with the job.
create or replace function app.field_job_is_move(p_kind text) returns boolean
language sql immutable as $$
  select p_kind in ('delivery', 'detail', 'photo_shoot', 'registry_run', 'tracker_install', 'tracker_removal', 'recovery')
$$;

-- Fleet (or an Admin) creates a job. Handover and return kinds belong to a booking.
create or replace function app.create_field_job(
  p_kind text, p_vehicle uuid, p_scheduled_at timestamptz, p_by uuid,
  p_booking uuid default null, p_assigned_to uuid default null, p_place text default null, p_instructions text default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
  b bookings;
begin
  if not app.user_runs_fleet(p_by) then
    raise exception 'Only Fleet or an Admin dispatches a field job' using errcode = '42501';
  end if;
  if p_kind in ('handover', 'delivery', 'return_check_in', 'pickup_from_renter') then
    select * into b from bookings where id = p_booking;
    if b.id is null then
      raise exception 'A % job belongs to a booking', p_kind using errcode = '23514';
    end if;
    if b.vehicle_id <> p_vehicle then
      raise exception 'The job''s vehicle is not the vehicle of booking %', b.booking_number using errcode = '23514';
    end if;
  end if;
  if p_assigned_to is not null and not app.user_is_field(p_assigned_to) then
    raise exception 'A field job is assigned to active field staff' using errcode = '23514';
  end if;
  if p_scheduled_at is null then
    raise exception 'Give the time of the job' using errcode = '22023';
  end if;
  insert into field_jobs (kind, booking_id, vehicle_id, assigned_to, dispatched_by, scheduled_at, place, instructions, created_by)
  values (p_kind, p_booking, p_vehicle, p_assigned_to, case when p_assigned_to is not null then p_by end, p_scheduled_at,
          p_place, p_instructions, p_by)
  returning id into v_id;
  return v_id;
end $$;

-- Assign a job, or give it to someone else. The new person must acknowledge it again.
create or replace function app.assign_field_job(p_job uuid, p_assignee uuid, p_by uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  j field_jobs;
begin
  if not app.user_runs_fleet(p_by) then
    raise exception 'Only Fleet or an Admin assigns a field job' using errcode = '42501';
  end if;
  select * into j from field_jobs where id = p_job for update;
  if j.id is null then raise exception 'Field job % not found', p_job; end if;
  if j.status in ('done', 'cancelled') then
    raise exception 'This job is % and cannot be reassigned', j.status using errcode = '23514';
  end if;
  if j.status = 'in_progress' and j.assigned_to is distinct from p_assignee then
    raise exception 'This job has started: cancel it and create a new one to change who does it' using errcode = '23514';
  end if;
  if p_assignee is not null and not app.user_is_field(p_assignee) then
    raise exception 'A field job is assigned to active field staff' using errcode = '23514';
  end if;
  if j.assigned_to is not distinct from p_assignee then return; end if;
  update field_jobs
     set assigned_to = p_assignee, dispatched_by = p_by, status = 'scheduled', acknowledged_at = null
   where id = p_job;
end $$;

-- Change the time, place or instructions of a job that has not started.
create or replace function app.reschedule_field_job(p_job uuid, p_by uuid, p_scheduled_at timestamptz default null,
                                                    p_place text default null, p_instructions text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  j field_jobs;
begin
  if not app.user_runs_fleet(p_by) then
    raise exception 'Only Fleet or an Admin changes a field job' using errcode = '42501';
  end if;
  select * into j from field_jobs where id = p_job for update;
  if j.id is null then raise exception 'Field job % not found', p_job; end if;
  if j.status in ('in_progress', 'done', 'cancelled') then
    raise exception 'This job is % and its time and place can no longer change', j.status using errcode = '23514';
  end if;
  update field_jobs
     set scheduled_at = coalesce(p_scheduled_at, scheduled_at), place = coalesce(p_place, place),
         instructions = coalesce(p_instructions, instructions),
         -- a job whose time or place moved must be acknowledged again
         status = case when (p_scheduled_at is not null and p_scheduled_at <> scheduled_at) or (p_place is not null and p_place is distinct from place)
                       then 'scheduled' else status end,
         acknowledged_at = case when (p_scheduled_at is not null and p_scheduled_at <> scheduled_at) or (p_place is not null and p_place is distinct from place)
                                then null else acknowledged_at end
   where id = p_job;
end $$;

-- The assignee accepts the job ("acknowledged").
create or replace function app.accept_field_job(p_job uuid, p_by uuid, p_now timestamptz default now()) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  j field_jobs;
begin
  select * into j from field_jobs where id = p_job for update;
  if j.id is null then raise exception 'Field job % not found', p_job; end if;
  if j.assigned_to is distinct from p_by or not app.user_is_field(p_by) then
    raise exception 'Only the field staff member the job is assigned to accepts it' using errcode = '42501';
  end if;
  if j.status <> 'scheduled' then
    raise exception 'This job is % and cannot be accepted', j.status using errcode = '23514';
  end if;
  update field_jobs set status = 'acknowledged', acknowledged_at = p_now where id = p_job;
end $$;

create or replace function app.start_field_job(p_job uuid, p_by uuid, p_now timestamptz default now()) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  j field_jobs;
begin
  select * into j from field_jobs where id = p_job for update;
  if j.id is null then raise exception 'Field job % not found', p_job; end if;
  if j.assigned_to is distinct from p_by or not app.user_is_field(p_by) then
    raise exception 'Only the field staff member the job is assigned to starts it' using errcode = '42501';
  end if;
  if j.status not in ('scheduled', 'acknowledged') then
    raise exception 'This job is % and cannot be started', j.status using errcode = '23514';
  end if;
  update field_jobs set status = 'in_progress', acknowledged_at = coalesce(acknowledged_at, p_now), started_at = p_now where id = p_job;
end $$;

-- Complete a job that is not a handover or a return (those are completed by
-- app.complete_handover and app.complete_return, with their Condition Report).
-- p_details: cleaning_grade, belongings_found, fuel_or_charge_ok, to_place, odometer_km.
create or replace function app.complete_field_job(p_job uuid, p_by uuid, p_details jsonb default '{}'::jsonb,
                                                  p_now timestamptz default now())
returns void language plpgsql security definer set search_path = public, app as $$
declare
  j field_jobs;
  d jsonb := coalesce(p_details, '{}'::jsonb);
begin
  select * into j from field_jobs where id = p_job for update;
  if j.id is null then raise exception 'Field job % not found', p_job; end if;
  if not ((coalesce(j.assigned_to = p_by, false) and app.user_is_field(p_by)) or app.user_runs_fleet(p_by)) then
    raise exception 'Only the assigned field staff member, Fleet or an Admin completes this job' using errcode = '42501';
  end if;
  if j.status in ('done', 'cancelled') then
    raise exception 'This job is already %', j.status using errcode = '23514';
  end if;
  if j.kind in ('handover', 'delivery', 'return_check_in', 'pickup_from_renter') then
    raise exception 'A % job is completed with its Condition Report: use the handover or return checklist', j.kind using errcode = '23514';
  end if;
  update field_jobs
     set status = 'done', completed_at = p_now, started_at = coalesce(started_at, p_now),
         cleaning_grade = coalesce(d ->> 'cleaning_grade', cleaning_grade),
         belongings_found = coalesce(d ->> 'belongings_found', belongings_found),
         fuel_or_charge_ok = coalesce((d ->> 'fuel_or_charge_ok')::boolean, fuel_or_charge_ok)
   where id = p_job;
  update vehicle_moves
     set to_place = coalesce(d ->> 'to_place', to_place), odometer_end = coalesce((d ->> 'odometer_km')::integer, odometer_end)
   where id = (select m.id from vehicle_moves m where m.field_job_id = p_job order by m.started_at desc limit 1);
  if (d ->> 'odometer_km') is not null then
    update vehicles set odometer_km = (d ->> 'odometer_km')::integer
     where id = j.vehicle_id and coalesce(odometer_km, 0) < (d ->> 'odometer_km')::integer;
  end if;
  if nullif(btrim(coalesce(d ->> 'belongings_found', '')), '') is not null then
    perform app.raise_task(p_type => 'lost_property', p_detail => d ->> 'belongings_found', p_booking => j.booking_id,
                           p_vehicle => j.vehicle_id, p_related_table => 'field_jobs', p_related_id => j.id,
                           p_dedupe => 'lost_property:' || j.id, p_created_by => p_by);
  end if;
end $$;

create or replace function app.cancel_field_job(p_job uuid, p_by uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  j field_jobs;
begin
  if not app.user_runs_fleet(p_by) then
    raise exception 'Only Fleet or an Admin cancels a field job' using errcode = '42501';
  end if;
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'Give the reason for cancelling the job' using errcode = '22023';
  end if;
  select * into j from field_jobs where id = p_job for update;
  if j.id is null then raise exception 'Field job % not found', p_job; end if;
  if j.status = 'done' then
    raise exception 'This job is done and cannot be cancelled' using errcode = '23514';
  end if;
  update field_jobs set status = 'cancelled', cancel_reason = p_reason where id = p_job and status <> 'cancelled';
end $$;

-- After every write to a field job: tell the assignee (events), and keep the vehicle move that
-- goes with a job in which staff drive the car.
create or replace function app.field_job_after_write() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  v_first text;
  v_base jsonb;
  v_changes text[] := '{}';
  v_stamp text := to_char(clock_timestamp() at time zone 'UTC', 'YYYYMMDD"T"HH24MISSUS');
begin
  select * into v from vehicles where id = new.vehicle_id;
  select split_part(btrim(r.legal_name), ' ', 1) into v_first
    from bookings b join renters r on r.id = b.renter_id where b.id = new.booking_id;
  v_base := jsonb_build_object('job_id', new.id, 'job_type', new.kind, 'job_time', new.scheduled_at, 'job_place', new.place,
      'job_note', new.instructions, 'vehicle_id', new.vehicle_id, 'vehicle_name', v.year || ' ' || v.make || ' ' || v.model,
      'vehicle_plate', v.plate, 'booking_id', new.booking_id, 'customer_first_name', v_first);

  -- ---- events for the field staff member
  if tg_op = 'INSERT' then
    if new.assigned_to is not null and new.status not in ('done', 'cancelled') then
      perform app.emit_event('staff_field_job_assigned', 'field_job', new.id, v_base || jsonb_build_object('recipient_user_id', new.assigned_to),
        'staff_field_job_assigned:' || new.id || ':' || new.assigned_to || ':' || v_stamp);
    end if;
  else
    if new.assigned_to is distinct from old.assigned_to then
      if old.assigned_to is not null and old.status not in ('done', 'cancelled') then
        perform app.emit_event('staff_field_job_changed', 'field_job', new.id,
          v_base || jsonb_build_object('recipient_user_id', old.assigned_to, 'job_cancelled', false,
                                       'job_change_headline', 'This job is no longer yours', 'job_changes', jsonb_build_array('reassigned')),
          'staff_field_job_changed:' || new.id || ':' || old.assigned_to || ':' || v_stamp);
      end if;
      if new.assigned_to is not null and new.status not in ('done', 'cancelled') then
        perform app.emit_event('staff_field_job_assigned', 'field_job', new.id, v_base || jsonb_build_object('recipient_user_id', new.assigned_to),
          'staff_field_job_assigned:' || new.id || ':' || new.assigned_to || ':' || v_stamp);
      end if;
    elsif new.assigned_to is not null then
      if new.status = 'cancelled' and old.status <> 'cancelled' then
        perform app.emit_event('staff_field_job_changed', 'field_job', new.id,
          v_base || jsonb_build_object('recipient_user_id', new.assigned_to, 'job_cancelled', true,
                                       'job_change_headline', 'This job is cancelled', 'job_changes', jsonb_build_array('cancelled'),
                                       'cancel_reason', new.cancel_reason),
          'staff_field_job_changed:' || new.id || ':' || new.assigned_to || ':' || v_stamp);
      elsif new.status not in ('done', 'cancelled') then
        if new.scheduled_at is distinct from old.scheduled_at then v_changes := v_changes || 'time'::text; end if;
        if new.place is distinct from old.place then v_changes := v_changes || 'place'::text; end if;
        if new.vehicle_id is distinct from old.vehicle_id then v_changes := v_changes || 'vehicle'::text; end if;
        if cardinality(v_changes) > 0 then
          perform app.emit_event('staff_field_job_changed', 'field_job', new.id,
            v_base || jsonb_build_object('recipient_user_id', new.assigned_to, 'job_cancelled', false,
                                         'job_change_headline', 'This job has changed', 'job_changes', to_jsonb(v_changes),
                                         'previous_time', old.scheduled_at, 'previous_place', old.place),
            'staff_field_job_changed:' || new.id || ':' || new.assigned_to || ':' || v_stamp);
        end if;
      end if;
    end if;
  end if;

  -- ---- the vehicle move that goes with the job
  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    if new.status = 'in_progress' and new.assigned_to is not null and app.field_job_is_move(new.kind) then
      perform app.start_vehicle_move(new.vehicle_id, new.assigned_to, new.kind, null, null, new.id, new.booking_id,
                                     coalesce(new.started_at, now()), new.assigned_to);
    elsif new.status in ('done', 'cancelled') then
      update vehicle_moves
         set ended_at = greatest(coalesce(new.completed_at, now()), started_at), to_place = coalesce(to_place, new.place)
       where field_job_id = new.id and ended_at is null;
      -- collecting a car from the renter: staff drive it back after the return check
      if new.status = 'done' and new.kind = 'pickup_from_renter' and new.assigned_to is not null then
        perform app.start_vehicle_move(new.vehicle_id, new.assigned_to, 'pickup_from_renter', new.place, null, new.id, new.booking_id,
                                       coalesce(new.completed_at, now()), new.assigned_to);
      end if;
    end if;
  end if;
  return null;
end $$;
create trigger field_jobs_after_write after insert or update on field_jobs
  for each row execute function app.field_job_after_write();

-- Today's and tomorrow's jobs of the signed-in field staff member, in time order. Only what is
-- needed on the phone: no money, no contact details beyond the renter's first name (the job's
-- detail screen, field_job_details of migration 0012, carries the rest inside its time window).
create view field_job_list with (security_barrier = true) as
  select j.id as field_job_id,
         case when app.local_date(j.scheduled_at) = app.today() then 'today' else 'tomorrow' end as list_day,
         j.kind, j.status, j.scheduled_at, j.place,
         j.vehicle_id, v.year || ' ' || v.make || ' ' || v.model as vehicle_label, v.colour as vehicle_colour, v.plate,
         j.booking_id, b.booking_number,
         split_part(btrim(r.legal_name), ' ', 1) as renter_first_name,
         j.acknowledged_at, j.started_at, j.completed_at
    from field_jobs j
    join vehicles v on v.id = j.vehicle_id
    left join bookings b on b.id = j.booking_id
    left join renters r on r.id = b.renter_id
   where j.assigned_to = app.uid() and app.is_field() and j.status <> 'cancelled'
     and app.local_date(j.scheduled_at) in (app.today(), app.today() + 1);

-- The same list for one staff member and one Toronto day, for Fleet and Admins (the Today
-- board), and for the server. A field staff member may ask for their own list only.
create or replace function app.staff_field_jobs(p_staff uuid, p_day date default app.today())
returns table (field_job_id uuid, kind text, status text, scheduled_at timestamptz, place text,
               vehicle_id uuid, vehicle_label text, plate text, booking_id uuid, booking_number text,
               renter_first_name text, acknowledged_at timestamptz, started_at timestamptz, completed_at timestamptz)
language plpgsql stable security definer set search_path = public, app as $$
begin
  if app.from_browser() and not (app.is_admin() or app.va_has('fleet', 'cs', 'finance') or (app.is_field() and p_staff = app.uid())) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return query
    select j.id, j.kind, j.status, j.scheduled_at, j.place, j.vehicle_id,
           v.year || ' ' || v.make || ' ' || v.model, v.plate, j.booking_id, b.booking_number,
           split_part(btrim(r.legal_name), ' ', 1), j.acknowledged_at, j.started_at, j.completed_at
      from field_jobs j
      join vehicles v on v.id = j.vehicle_id
      left join bookings b on b.id = j.booking_id
      left join renters r on r.id = b.renter_id
     where j.assigned_to = p_staff and j.status <> 'cancelled' and app.local_date(j.scheduled_at) = p_day
     order by j.scheduled_at, j.id;
end $$;

-- ================================================================ 8. fee terms of one booking
-- One fee for one booking: the booking's own term, then the vehicle's override, then the class
-- default, then the general default, each on the day the booking was made. The first value
-- that is set wins, column by column (a class row may carry only a range).
create or replace function app.booking_fee_term(p_booking uuid, p_fee text)
returns table (amount_cents bigint, cap_cents bigint, percent_bps integer, grace_minutes integer, source text)
language sql stable security definer set search_path = public, app as $$
  with b as (
    select bk.id, bk.vehicle_id, app.local_date(bk.booked_at) as on_date, v.class
      from bookings bk join vehicles v on v.id = bk.vehicle_id where bk.id = p_booking),
  cand as (
    select t.amount_cents, t.cap_cents, t.percent_bps, null::integer as grace_minutes, t.source, 0 as rank
      from booking_fee_terms t where t.booking_id = p_booking and t.fee_type_code = p_fee
    union all
    select o.amount_cents, o.cap_cents, o.percent_bps, null::integer, 'vehicle', 1
      from vehicle_fee_overrides o join b on b.vehicle_id = o.vehicle_id
     where o.fee_type_code = p_fee and o.effective_from <= b.on_date and (o.effective_to is null or o.effective_to > b.on_date)
    union all
    select d.amount_cents, d.cap_cents, d.percent_bps, d.grace_minutes, 'default', case when d.vehicle_class is null then 3 else 2 end
      from fee_defaults d join b on true
     where d.fee_type_code = p_fee and (d.vehicle_class is null or d.vehicle_class = b.class)
       and d.effective_from <= b.on_date and (d.effective_to is null or d.effective_to > b.on_date))
  select (select c.amount_cents from cand c where c.amount_cents is not null order by c.rank limit 1),
         (select c.cap_cents from cand c where c.cap_cents is not null order by c.rank limit 1),
         (select c.percent_bps from cand c where c.percent_bps is not null order by c.rank limit 1),
         (select c.grace_minutes from cand c where c.grace_minutes is not null order by c.rank limit 1),
         (select c.source from cand c where c.amount_cents is not null or c.percent_bps is not null order by c.rank limit 1)
$$;

-- Write the snapshot of every fee rate and cap that applies to a booking (the "B" list of the
-- billing specification). Terms already on the booking, an Admin's override included, are kept.
create or replace function app.snapshot_booking_fee_terms(p_booking uuid) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  f record;
  t record;
  n integer := 0;
begin
  for f in select code from fee_types where code not in ('rental_charge', 'referral_kickback') order by sort_order loop
    continue when exists (select 1 from booking_fee_terms x where x.booking_id = p_booking and x.fee_type_code = f.code);
    select * into t from app.booking_fee_term(p_booking, f.code);
    if t.source is not null then
      insert into booking_fee_terms (booking_id, fee_type_code, amount_cents, cap_cents, percent_bps, source)
      values (p_booking, f.code, t.amount_cents, t.cap_cents, t.percent_bps, t.source);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- An Admin sets one fee for one booking (only charges the catalogue marks "B"), with a reason.
create or replace function app.set_booking_fee_term(p_booking uuid, p_fee text, p_admin uuid, p_reason text,
    p_amount_cents bigint default null, p_cap_cents bigint default null, p_percent_bps integer default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
begin
  if not app.user_is_admin(p_admin) then
    raise exception 'Only an Admin overrides a price on one booking' using errcode = '42501';
  end if;
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'Give the reason for the override' using errcode = '22023';
  end if;
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if b.status in ('closed', 'cancelled', 'no_show', 'expired', 'declined') then
    raise exception 'Booking % is % and its fee terms can no longer change', b.booking_number, b.status using errcode = '23514';
  end if;
  if p_amount_cents is null and p_cap_cents is null and p_percent_bps is null then
    raise exception 'Give an amount, a cap or a percentage' using errcode = '22023';
  end if;
  insert into booking_fee_terms as t (booking_id, fee_type_code, amount_cents, cap_cents, percent_bps, source, override_by, override_reason)
  values (p_booking, p_fee, p_amount_cents, p_cap_cents, p_percent_bps, 'booking', p_admin, p_reason)
  on conflict (booking_id, fee_type_code) do update
     set amount_cents = coalesce(excluded.amount_cents, t.amount_cents), cap_cents = coalesce(excluded.cap_cents, t.cap_cents),
         percent_bps = coalesce(excluded.percent_bps, t.percent_bps), source = 'booking',
         override_by = excluded.override_by, override_reason = excluded.override_reason;
end $$;

-- ================================================================ 9. Condition Reports from the phone
-- In what capacity a person fills a Condition Report: field staff on their own job, Fleet or an
-- Admin, the Owner on a Self-Managed car or an Owner Booking, or the renter (photo set uploaded
-- for an unattended handover or on a renewal day). Anyone else is refused.
create or replace function app.condition_report_actor(p_booking uuid, p_vehicle uuid, p_by uuid, p_job uuid default null) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
begin
  if p_by is null then raise exception 'Say who is filling the Condition Report' using errcode = '42501'; end if;
  if p_booking is not null then select * into b from bookings where id = p_booking; end if;
  if app.user_is_field(p_by) and exists (
       select 1 from field_jobs j
        where j.assigned_to = p_by and j.status <> 'cancelled' and (p_job is null or j.id = p_job)
          and ((p_booking is not null and j.booking_id = p_booking) or (p_vehicle is not null and j.vehicle_id = p_vehicle))) then
    return 'field';
  end if;
  if app.user_runs_fleet(p_by) then return 'staff'; end if;
  if exists (select 1 from vehicles v join owners o on o.id = v.owner_id
              where v.id = coalesce(p_vehicle, b.vehicle_id) and o.user_id = p_by)
     and (b.id is null or b.management_mode = 'self_managed' or b.booking_type = 'owner') then
    return 'owner';
  end if;
  if b.id is not null and app.is_booking_renter(p_booking, p_by) then return 'renter'; end if;
  raise exception 'Not permitted: this Condition Report is not on a job assigned to you' using errcode = '42501';
end $$;

-- Save a Condition Report as it is filled in on the phone (answers, photos and damage marks
-- arrive screen by screen). Creates the report on the first call. p_report may carry:
--   odometer_km, fuel_pct, cleanliness, odour, keys_count, extras, tracker_reporting, licence_seen,
--   card_seen, unattended, renter_present, notes, car_diagram, belongings_found,
--   renter_signature_ref, staff_signature_ref, renter_declined_to_sign, renter_decline_reason,
--   damages: [{label, location, description, is_new, found_later, kind, size_cm, position, status_vs_pickup}],
--   photos:  [{seq, shot, storage_path, storage_bucket, damage_label, device_taken_at, latitude, longitude,
--              width, height, quality_flags}].
-- A photo with the same seq replaces the earlier one (a retake). Once the report is completed
-- nothing in it changes.
create or replace function app.save_condition_report(
  p_booking uuid, p_kind text, p_by uuid, p_report jsonb default '{}'::jsonb, p_job uuid default null, p_vehicle uuid default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  d jsonb := coalesce(p_report, '{}'::jsonb);
  b bookings;
  c condition_reports;
  v_vehicle uuid := p_vehicle;
  v_role text;
  v_id uuid;
  x jsonb;
  v_damage uuid;
  v_retention integer := (app.settings()).retention_id_face_days;
begin
  if p_booking is not null then
    select * into b from bookings where id = p_booking;
    if b.id is null then raise exception 'Booking % not found', p_booking; end if;
    v_vehicle := coalesce(p_vehicle, b.vehicle_id);
  end if;
  if v_vehicle is null then raise exception 'A Condition Report needs a vehicle' using errcode = '22023'; end if;
  v_role := app.condition_report_actor(p_booking, v_vehicle, p_by, p_job);

  select * into c from condition_reports r
   where r.kind = p_kind and r.vehicle_id = v_vehicle and r.booking_id is not distinct from p_booking
     and (p_kind in ('pickup', 'return') or r.completed_at is null)
   order by r.created_at desc limit 1;
  if c.id is not null and c.completed_at is not null then
    raise exception 'This Condition Report is signed and can no longer change' using errcode = '23514';
  end if;

  if c.id is null then
    insert into condition_reports (vehicle_id, booking_id, field_job_id, kind, performed_by, performed_by_role)
    values (v_vehicle, p_booking, p_job, p_kind, p_by, case v_role when 'field' then 'field' when 'owner' then 'owner' when 'renter' then 'renter' else 'staff' end)
    returning id into v_id;
  else
    v_id := c.id;
  end if;

  update condition_reports r set
      field_job_id = coalesce(p_job, r.field_job_id),
      odometer_km = coalesce((d ->> 'odometer_km')::integer, r.odometer_km),
      fuel_pct = coalesce((d ->> 'fuel_pct')::smallint, r.fuel_pct),
      cleanliness = coalesce(d ->> 'cleanliness', r.cleanliness),
      odour = coalesce((d ->> 'odour')::boolean, r.odour),
      keys_count = coalesce((d ->> 'keys_count')::smallint, r.keys_count),
      extras = coalesce(d -> 'extras', r.extras),
      tracker_reporting = coalesce((d ->> 'tracker_reporting')::boolean, r.tracker_reporting),
      licence_seen = coalesce((d ->> 'licence_seen')::boolean, r.licence_seen),
      card_seen = coalesce((d ->> 'card_seen')::boolean, r.card_seen),
      unattended = coalesce((d ->> 'unattended')::boolean, r.unattended),
      renter_present = coalesce((d ->> 'renter_present')::boolean, r.renter_present),
      notes = coalesce(d ->> 'notes', r.notes),
      car_diagram = coalesce(d -> 'car_diagram', r.car_diagram),
      belongings_found = coalesce(d ->> 'belongings_found', r.belongings_found),
      renter_declined_to_sign = coalesce((d ->> 'renter_declined_to_sign')::boolean, r.renter_declined_to_sign),
      renter_decline_reason = coalesce(d ->> 'renter_decline_reason', r.renter_decline_reason),
      renter_signature_ref = coalesce(d ->> 'renter_signature_ref', r.renter_signature_ref),
      renter_signed_at = case when d ->> 'renter_signature_ref' is not null and r.renter_signature_ref is distinct from d ->> 'renter_signature_ref'
                              then now() else r.renter_signed_at end,
      staff_signature_ref = coalesce(d ->> 'staff_signature_ref', r.staff_signature_ref),
      staff_signed_at = case when d ->> 'staff_signature_ref' is not null and r.staff_signature_ref is distinct from d ->> 'staff_signature_ref'
                             then now() else r.staff_signed_at end
   where r.id = v_id;

  for x in select * from jsonb_array_elements(coalesce(d -> 'damages', '[]'::jsonb)) loop
    if x ->> 'label' is null or x ->> 'location' is null or x ->> 'description' is null then
      raise exception 'A damage mark needs a label, a location and a description' using errcode = '22023';
    end if;
    insert into condition_report_damages as dm (condition_report_id, label, location, description, is_new, found_later,
                                                kind, size_cm, position, status_vs_pickup)
    values (v_id, x ->> 'label', x ->> 'location', x ->> 'description', coalesce((x ->> 'is_new')::boolean, false),
            coalesce((x ->> 'found_later')::boolean, false), x ->> 'kind', (x ->> 'size_cm')::numeric, x -> 'position', x ->> 'status_vs_pickup')
    on conflict (condition_report_id, label) do update
       set location = excluded.location, description = excluded.description, is_new = excluded.is_new,
           found_later = excluded.found_later, kind = coalesce(excluded.kind, dm.kind), size_cm = coalesce(excluded.size_cm, dm.size_cm),
           position = coalesce(excluded.position, dm.position), status_vs_pickup = coalesce(excluded.status_vs_pickup, dm.status_vs_pickup);
  end loop;

  for x in select * from jsonb_array_elements(coalesce(d -> 'photos', '[]'::jsonb)) loop
    if x ->> 'seq' is null or x ->> 'shot' is null or x ->> 'storage_path' is null then
      raise exception 'A photo needs its place in the order, its shot and its file' using errcode = '22023';
    end if;
    v_damage := null;
    if x ->> 'shot' = 'damage_closeup' then
      select dm.id into v_damage from condition_report_damages dm where dm.condition_report_id = v_id and dm.label = x ->> 'damage_label';
      if v_damage is null then
        raise exception 'A close-up belongs to a damage mark on this report (label %)', coalesce(x ->> 'damage_label', 'missing') using errcode = '23514';
      end if;
    end if;
    insert into condition_report_photos as ph (condition_report_id, seq, shot, damage_id, storage_bucket, storage_path, uploaded_by,
                                               device_taken_at, latitude, longitude, width, height, quality_flags, purge_after)
    values (v_id, (x ->> 'seq')::integer, x ->> 'shot', v_damage,
            coalesce(x ->> 'storage_bucket', case when x ->> 'shot' = 'licence' then 'identity' else 'condition-photos' end),
            x ->> 'storage_path', p_by, (x ->> 'device_taken_at')::timestamptz, (x ->> 'latitude')::numeric, (x ->> 'longitude')::numeric,
            (x ->> 'width')::integer, (x ->> 'height')::integer, x -> 'quality_flags',
            -- a licence photo taken in person is an ID image: kept 90 days, like the others
            case when x ->> 'shot' = 'licence' then now() + make_interval(days => v_retention) end)
    on conflict (condition_report_id, seq) do update
       set shot = excluded.shot, damage_id = excluded.damage_id, storage_bucket = excluded.storage_bucket,
           storage_path = excluded.storage_path, uploaded_by = excluded.uploaded_by, taken_at = now(),
           device_taken_at = excluded.device_taken_at, latitude = excluded.latitude, longitude = excluded.longitude,
           width = excluded.width, height = excluded.height, quality_flags = excluded.quality_flags, purge_after = excluded.purge_after;
  end loop;
  return v_id;
end $$;

-- ================================================================ 10. the Deposit at pickup
-- The server placed the hold (rental of 7 days or less) or took the charge (longer) and passes
-- the payment here. Returns the deposit's id.
create or replace function app.record_deposit_taken(p_booking uuid, p_payment uuid, p_by uuid default null,
    p_hold_expires_at timestamptz default null, p_now timestamptz default now())
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  p payments;
  v_method text;
  v_id uuid;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if b.booking_type = 'owner' or b.deposit_cents = 0 then
    raise exception 'Booking % has no Deposit to take', b.booking_number using errcode = '23514';
  end if;
  if b.status <> 'confirmed' then
    raise exception 'Booking % is %: the Deposit is taken at pickup of a confirmed booking', b.booking_number, b.status using errcode = '23514';
  end if;
  select * into p from payments where id = p_payment;
  if p.id is null or p.booking_id is distinct from p_booking or p.purpose <> 'deposit' then
    raise exception 'That payment is not a Deposit payment of booking %', b.booking_number using errcode = '23514';
  end if;
  v_method := public.calc_deposit_method(b.billable_days, (app.settings()).deposit_hold_max_days);
  if v_method = 'card_hold' and not (p.kind = 'hold' and p.status in ('authorized', 'succeeded')) then
    raise exception 'A rental of 7 days or less takes a card hold: the hold has not been authorized' using errcode = '23514';
  elsif v_method = 'charged' and not (p.kind = 'charge' and p.status = 'succeeded') then
    raise exception 'A rental over 7 days takes a charged Deposit: the charge has not succeeded' using errcode = '23514';
  end if;
  if p.amount_cents <> b.deposit_cents then
    raise exception 'The Deposit on booking % is % cents; the payment is for % cents', b.booking_number, b.deposit_cents, p.amount_cents
      using errcode = '23514';
  end if;
  insert into deposits as d (booking_id, amount_cents, method, status, hold_payment_id, taken_at, hold_expires_at, captured_cents)
  values (p_booking, b.deposit_cents, v_method, case when v_method = 'card_hold' then 'held' else 'captured' end, p_payment, p_now,
          case when v_method = 'card_hold' then coalesce(p_hold_expires_at, p_now + make_interval(days => (app.settings()).deposit_hold_max_days)) end,
          case when v_method = 'charged' then b.deposit_cents else 0 end)
  on conflict (booking_id) do update
     set amount_cents = excluded.amount_cents, method = excluded.method, status = excluded.status,
         hold_payment_id = excluded.hold_payment_id, taken_at = excluded.taken_at, hold_expires_at = excluded.hold_expires_at,
         captured_cents = excluded.captured_cents
   where d.status in ('pending', 'failed')
  returning id into v_id;
  if v_id is null then
    raise exception 'The Deposit on booking % has already been taken', b.booking_number using errcode = '23514';
  end if;
  insert into deposit_events (deposit_id, kind, amount_cents, payment_id, note, created_by)
  values (v_id, 'taken', b.deposit_cents, p_payment, case when v_method = 'card_hold' then 'card hold' else 'charged' end, p_by);
  perform app.resolve_tasks(array['take_deposit', 'deposit_declined'], p_booking, p_by, 'Deposit taken');
  return v_id;
end $$;

-- The hold or charge was declined at pickup. The car is not released: the renter is told, and
-- an Admin gets an urgent task (procedure 3, "Deposit declined").
create or replace function app.record_deposit_declined(p_booking uuid, p_payment uuid default null, p_decline_code text default null,
    p_by uuid default null, p_now timestamptz default now())
returns void language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v vehicles;
  r renters;
  pm payment_methods;
  v_method text;
  v_id uuid;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if b.status <> 'confirmed' then
    raise exception 'Booking % is %: a Deposit is taken at pickup of a confirmed booking', b.booking_number, b.status using errcode = '23514';
  end if;
  select * into v from vehicles where id = b.vehicle_id;
  select * into r from renters where id = b.renter_id;
  select * into pm from payment_methods where id = b.card_on_file_id;
  v_method := public.calc_deposit_method(b.billable_days, (app.settings()).deposit_hold_max_days);
  insert into deposits as d (booking_id, amount_cents, method, status)
  values (p_booking, b.deposit_cents, v_method, 'failed')
  on conflict (booking_id) do update set status = 'failed' where d.status in ('pending', 'failed')
  returning id into v_id;
  if v_id is null then
    raise exception 'The Deposit on booking % has already been taken', b.booking_number using errcode = '23514';
  end if;
  insert into deposit_events (deposit_id, kind, amount_cents, payment_id, note, created_by)
  values (v_id, 'failed', b.deposit_cents, p_payment, p_decline_code, p_by);
  perform app.raise_task(p_type => 'deposit_declined',
      p_title => format('Booking %s: Deposit declined at pickup. Do not release the car', b.booking_number),
      p_detail => format('The %s for the Deposit was declined%s. The renter may pay another way, or an Admin may waive the Deposit.',
                         case when v_method = 'card_hold' then 'card hold' else 'charge' end,
                         coalesce(' (' || p_decline_code || ')', '')),
      p_booking => p_booking, p_vehicle => b.vehicle_id, p_renter => b.renter_id, p_dedupe => 'deposit_declined:' || p_booking,
      p_created_by => p_by, p_escalation_reason => 'Deposit declined');
  perform app.emit_event('renter_deposit_declined', 'booking', p_booking,
    jsonb_build_object('booking_number', b.booking_number, 'renter_id', b.renter_id,
                       'first_name', split_part(btrim(r.legal_name), ' ', 1),
                       'vehicle_name', v.year || ' ' || v.make || ' ' || v.model,
                       'deposit_amount_cents', b.deposit_cents, 'deposit_method', v_method,
                       'card_brand', pm.card_brand, 'card_last4', pm.card_last4, 'decline_code', p_decline_code),
    'renter_deposit_declined:' || p_booking || ':' || coalesce(p_payment::text, to_char(p_now at time zone 'UTC', 'YYYYMMDD"T"HH24MISS')));
end $$;

-- An Admin waives the Deposit of one booking before handover, with the reason.
create or replace function app.waive_deposit(p_booking uuid, p_admin uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
begin
  if not app.user_is_admin(p_admin) then
    raise exception 'Only an Admin waives a Deposit' using errcode = '42501';
  end if;
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'Give the reason for waiving the Deposit' using errcode = '22023';
  end if;
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if b.status <> 'confirmed' then
    raise exception 'Booking % is %: a Deposit is waived on a confirmed booking, before handover', b.booking_number, b.status using errcode = '23514';
  end if;
  if exists (select 1 from deposits d where d.booking_id = p_booking and d.status in ('held', 'captured')) then
    raise exception 'The Deposit on booking % has already been taken: release it instead', b.booking_number using errcode = '23514';
  end if;
  if b.deposit_cents = 0 then return; end if;
  update bookings
     set deposit_waived_cents = deposit_waived_cents + deposit_cents, deposit_cents = 0,
         deposit_waived_by = p_admin, deposit_waived_at = now(), deposit_waiver_reason = p_reason
   where id = p_booking;
  perform app.resolve_tasks(array['take_deposit', 'deposit_declined'], p_booking, p_admin, 'Deposit waived: ' || p_reason);
end $$;

-- ================================================================ 11. handover
-- One transaction for the end of the handover checklist: the pickup Condition Report is
-- completed, the booking goes on rent (the booking's own trigger checks every precondition
-- again, moves the vehicle to on rent and blocks the Owner's controls) and the job is done.
-- p_report: everything app.save_condition_report takes, plus
--   deposit_payment_id   the hold or charge the server just placed, when not recorded yet
--   deposit_waiver       {"by": admin id, "reason": "..."} in place of a Deposit
--   odometer_confirmed   true when the reading is lower than the last one on file and was checked
-- Returns the Condition Report's id.
create or replace function app.complete_handover(p_booking uuid, p_by uuid, p_report jsonb default '{}'::jsonb,
    p_job uuid default null, p_now timestamptz default now())
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  d jsonb := coalesce(p_report, '{}'::jsonb);
  b bookings;
  v vehicles;
  c condition_reports;
  j field_jobs;
  v_report uuid;
  v_role text;
  v_problems text[];
  v_owner_booking boolean;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if b.status <> 'confirmed' then
    raise exception 'Booking % is %: only a confirmed booking is handed over', b.booking_number, b.status using errcode = '23514';
  end if;
  if not b.blocks_calendar then
    raise exception 'Booking % does not block the calendar: turn the calendar switch on before the car is released', b.booking_number
      using errcode = '23514';
  end if;
  v_owner_booking := b.booking_type = 'owner';
  select * into v from vehicles where id = b.vehicle_id;
  v_role := app.condition_report_actor(p_booking, b.vehicle_id, p_by, p_job);
  if v_role = 'renter' then
    raise exception 'A handover is completed by CarmaCars staff or the vehicle''s Owner' using errcode = '42501';
  end if;

  -- the ready check of the checklist, said plainly before the booking's trigger says it
  if exists (select 1 from booking_drivers x where x.booking_id = p_booking and x.identity_verified_on is null)
     or not exists (select 1 from booking_drivers x where x.booking_id = p_booking and x.role = 'renter') then
    raise exception 'Do not release the car: every driver''s identity must be verified first' using errcode = '23514';
  end if;
  if not v_owner_booking and (b.coverage_confirmed_at is null or not exists (
       select 1 from coverage_proofs x where x.booking_id = p_booking and x.status = 'confirmed')) then
    raise exception 'Do not release the car: no Coverage Option is confirmed' using errcode = '23514';
  end if;

  -- the Deposit: taken by the server just now, waived by an Admin, or already on file
  if d ? 'deposit_waiver' then
    perform app.waive_deposit(p_booking, (d -> 'deposit_waiver' ->> 'by')::uuid, d -> 'deposit_waiver' ->> 'reason');
    select * into b from bookings where id = p_booking;
  elsif d ->> 'deposit_payment_id' is not null
        and not exists (select 1 from deposits x where x.booking_id = p_booking and x.status in ('held', 'captured')) then
    perform app.record_deposit_taken(p_booking, (d ->> 'deposit_payment_id')::uuid, p_by, null, p_now);
  end if;
  if not v_owner_booking and b.deposit_cents > 0
     and not exists (select 1 from deposits x where x.booking_id = p_booking and x.status in ('held', 'captured')) then
    raise exception 'Do not release the car: the Deposit is taken at pickup, before handover' using errcode = '23514';
  end if;

  v_report := app.save_condition_report(p_booking, 'pickup', p_by, d - 'deposit_payment_id' - 'deposit_waiver' - 'odometer_confirmed', p_job);
  select * into c from condition_reports where id = v_report;

  if c.odometer_km is null or c.fuel_pct is null then
    raise exception 'The odometer and the fuel or charge level are required' using errcode = '23514';
  end if;
  if v.odometer_km is not null and c.odometer_km < v.odometer_km and not coalesce((d ->> 'odometer_confirmed')::boolean, false) then
    raise exception 'The odometer reading (%) is lower than the last one on file (%): confirm or correct it', c.odometer_km, v.odometer_km
      using errcode = '23514';
  end if;
  if coalesce(c.keys_count, 0) < 1 then
    raise exception 'Record the number of keys handed over (at least 1)' using errcode = '23514';
  end if;
  if c.unattended and not b.unattended_handover then
    raise exception 'An unattended handover must be approved on the booking by an Admin first' using errcode = '23514';
  end if;
  if not c.unattended then
    if not c.renter_present then
      raise exception 'Hand over only to the Renter, in person' using errcode = '23514';
    end if;
    if c.licence_seen is not true then
      raise exception 'Do not release the car: the original licence was not seen and matched' using errcode = '23514';
    end if;
    if not v_owner_booking and c.card_seen is not true then
      raise exception 'Do not release the car: the physical Card on File was not seen and matched' using errcode = '23514';
    end if;
    if c.renter_signature_ref is null then
      raise exception 'The renter''s signature on the Condition Report is missing' using errcode = '23514';
    end if;
  end if;
  if c.staff_signature_ref is null then
    raise exception 'The signature of the person handing over is missing' using errcode = '23514';
  end if;
  if c.tracker_reporting is not true and not app.user_is_admin(p_by) then
    raise exception 'Do not release the car: the Tracker is not in place and reporting' using errcode = '23514';
  end if;
  v_problems := app.condition_report_problems(v_report);
  if cardinality(v_problems) > 0 then
    raise exception 'The photo set is not complete: %', array_to_string(v_problems, '; ') using errcode = '23514';
  end if;

  update condition_reports
     set performed_at = p_now, completed_at = p_now, completed_by = p_by,
         staff_signed_at = coalesce(staff_signed_at, p_now),
         renter_signed_at = case when unattended then renter_signed_at else coalesce(renter_signed_at, p_now) end
   where id = v_report;

  update bookings
     set status = 'on_rent', handed_over_at = p_now, odometer_out_km = c.odometer_km, fuel_out_pct = c.fuel_pct,
         unattended_handover = c.unattended
   where id = p_booking;
  update vehicles set odometer_km = c.odometer_km where id = b.vehicle_id;

  -- the job: the one given, or the open handover or delivery job of this booking
  select * into j from field_jobs x
   where x.booking_id = p_booking and x.kind in ('handover', 'delivery') and x.status not in ('done', 'cancelled')
     and (p_job is null or x.id = p_job)
   order by (x.assigned_to is not distinct from p_by) desc, x.scheduled_at limit 1;
  if j.id is not null then
    update field_jobs
       set status = 'done', completed_at = p_now, started_at = coalesce(started_at, p_now),
           fuel_or_charge_ok = coalesce((d ->> 'fuel_or_charge_ok')::boolean, fuel_or_charge_ok)
     where id = j.id;
  end if;
  return v_report;
end $$;

-- The handover is stopped ("Do not release the car"): an urgent task for an Admin, with the reason.
create or replace function app.block_handover(p_booking uuid, p_by uuid, p_reason text, p_job uuid default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  perform app.condition_report_actor(p_booking, b.vehicle_id, p_by, p_job);
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'Say why the handover is stopped' using errcode = '22023';
  end if;
  return app.raise_task(p_type => 'handover_blocked',
      p_title => format('Booking %s: handover stopped. Do not release the car', b.booking_number), p_detail => p_reason,
      p_booking => p_booking, p_vehicle => b.vehicle_id, p_renter => b.renter_id,
      p_related_table => case when p_job is not null then 'field_jobs' end, p_related_id => p_job,
      p_dedupe => 'handover_blocked:' || p_booking, p_created_by => p_by, p_escalation_reason => p_reason);
end $$;

-- ================================================================ 12. return
-- Kilometres driven on a booking. With a vehicle swap the two cars' readings are joined:
-- (old car out to swap-out) + (new car swap-in to return).
create or replace function app.booking_km_driven(p_booking uuid) returns integer
language sql stable security definer set search_path = public, app as $$
  select case when b.odometer_in_km is null or b.odometer_out_km is null then null
              else b.odometer_in_km - b.odometer_out_km
                   + coalesce((select sum(c.odometer_km) from condition_reports c where c.booking_id = b.id and c.kind = 'swap_out' and c.completed_at is not null), 0)::integer
                   - coalesce((select sum(c.odometer_km) from condition_reports c where c.booking_id = b.id and c.kind = 'swap_in' and c.completed_at is not null), 0)::integer
         end
    from bookings b where b.id = p_booking
$$;

-- The findings of a return, as one object (message T7): kilometres, fuel, cleaning, lateness,
-- keys and new damage. Read from the booking and its two Condition Reports.
create or replace function app.return_findings(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  o condition_reports;
  i condition_reports;
  v_km integer;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  select * into o from condition_reports where booking_id = p_booking and kind = 'pickup';
  select * into i from condition_reports where booking_id = p_booking and kind = 'return';
  v_km := app.booking_km_driven(p_booking);
  return jsonb_build_object(
    'booking_number', b.booking_number, 'pickup_report_id', o.id, 'return_report_id', i.id,
    'km_out', b.odometer_out_km, 'km_in', b.odometer_in_km, 'km_driven', v_km, 'km_allowance', b.km_allowance_total,
    'km_over', greatest(coalesce(v_km, 0) - b.km_allowance_total, 0),
    'fuel_out_pct', b.fuel_out_pct, 'fuel_in_pct', b.fuel_in_pct,
    'fuel_short_pct', greatest(coalesce(b.fuel_out_pct, 0) - coalesce(b.fuel_in_pct, b.fuel_out_pct, 0), 0),
    'cleanliness', i.cleanliness, 'odour', i.odour,
    'checked_in_at', b.checked_in_at, 'minutes_late', coalesce(b.minutes_late, 0), 'extra_days', b.extra_days,
    'keys_out', o.keys_count, 'keys_in', i.keys_count, 'keys_missing', greatest(coalesce(o.keys_count, 0) - coalesce(i.keys_count, o.keys_count, 0), 0),
    'belongings_found', i.belongings_found, 'renter_declined_to_sign', i.renter_declined_to_sign,
    'new_damage', coalesce((select jsonb_agg(jsonb_build_object('label', dm.label, 'location', dm.location, 'description', dm.description,
                                                             'found_later', dm.found_later, 'incident_id', dm.incident_id) order by dm.label)
                              from condition_report_damages dm where dm.condition_report_id = i.id and dm.is_new), '[]'::jsonb));
end $$;

-- One transaction for the end of the return checklist: the return Condition Report is
-- completed, lateness is worked out (a part day counts as a full day), the booking is returned
-- (its own trigger restores the Owner's controls, moves the vehicle to cleaning, sets the
-- Deposit release date and computes the split) and the job is done. New damage opens an incident.
-- p_report: everything app.save_condition_report takes, plus checked_in_at (the moment the car
-- and keys were taken; now when absent). Returns the findings.
create or replace function app.complete_return(p_booking uuid, p_by uuid, p_report jsonb default '{}'::jsonb,
    p_job uuid default null, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  d jsonb := coalesce(p_report, '{}'::jsonb);
  b bookings;
  c condition_reports;
  j field_jobs;
  t record;
  l record;
  v_report uuid;
  v_role text;
  v_problems text[];
  v_checked_in timestamptz;
  v_minutes integer;
  v_incident uuid;
  v_new_damage text;
  v_swapped boolean;
  v_findings jsonb;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if b.status <> 'on_rent' then
    raise exception 'Booking % is %: only a car that is on rent is checked in', b.booking_number, b.status using errcode = '23514';
  end if;
  v_role := app.condition_report_actor(p_booking, b.vehicle_id, p_by, p_job);
  if v_role = 'renter' then
    raise exception 'A return is checked in by CarmaCars staff or the vehicle''s Owner' using errcode = '42501';
  end if;
  v_checked_in := least(coalesce((d ->> 'checked_in_at')::timestamptz, p_now), p_now);
  if v_checked_in < coalesce(b.handed_over_at, b.pickup_at) then
    raise exception 'The Check-in time cannot be before the handover' using errcode = '22023';
  end if;

  v_report := app.save_condition_report(p_booking, 'return', p_by, d - 'checked_in_at', p_job);
  select * into c from condition_reports where id = v_report;
  v_swapped := exists (select 1 from booking_vehicle_swaps s where s.booking_id = p_booking);

  if c.odometer_km is null or c.fuel_pct is null then
    raise exception 'The odometer and the fuel or charge level are required' using errcode = '23514';
  end if;
  if not v_swapped and b.odometer_out_km is not null and c.odometer_km < b.odometer_out_km then
    raise exception 'The odometer reading (%) is lower than at pickup (%)', c.odometer_km, b.odometer_out_km using errcode = '23514';
  end if;
  if c.keys_count is null then
    raise exception 'Record the number of keys returned' using errcode = '23514';
  end if;
  if c.cleanliness is null then
    raise exception 'Record the cleanliness of the car' using errcode = '23514';
  end if;
  if c.staff_signature_ref is null then
    raise exception 'The signature of the person checking the car in is missing' using errcode = '23514';
  end if;
  if c.renter_present and not c.unattended and c.renter_signature_ref is null
     and not (c.renter_declined_to_sign and btrim(coalesce(c.renter_decline_reason, '')) <> '') then
    raise exception 'The renter signs the return, or is recorded as having declined to sign with the reason' using errcode = '23514';
  end if;
  v_problems := app.condition_report_problems(v_report);
  if cardinality(v_problems) > 0 then
    raise exception 'The photo set is not complete: %', array_to_string(v_problems, '; ') using errcode = '23514';
  end if;

  -- late return: nothing up to the grace period; then each extra day or part day is a full day
  v_minutes := greatest(0, floor(extract(epoch from (v_checked_in - b.return_at)) / 60)::integer);
  select * into t from app.booking_fee_term(p_booking, 'late_return_fee');
  if t.amount_cents is null or t.percent_bps is null or t.grace_minutes is null then
    raise exception 'The late return fee, its daily cap or its grace period is not set in the fee defaults' using errcode = '23514';
  end if;
  select * into l from public.calc_late_return(v_minutes, b.daily_rate_cents, t.amount_cents, t.percent_bps, t.grace_minutes);

  update condition_reports
     set performed_at = v_checked_in, completed_at = p_now, completed_by = p_by,
         staff_signed_at = coalesce(staff_signed_at, p_now),
         renter_signed_at = case when renter_signature_ref is not null then coalesce(renter_signed_at, p_now) else renter_signed_at end
   where id = v_report;

  update bookings
     set status = 'returned', checked_in_at = v_checked_in, odometer_in_km = c.odometer_km, fuel_in_pct = c.fuel_pct,
         minutes_late = v_minutes, extra_days = l.extra_days,
         end_reason = coalesce(end_reason, case when l.extra_days > 0 then 'late_return'
                                                when v_checked_in < b.return_at - make_interval(mins => (app.settings()).early_return_minutes) then 'early_return'
                                                else 'normal' end)
   where id = p_booking;
  update vehicles set odometer_km = c.odometer_km where id = b.vehicle_id and coalesce(odometer_km, 0) <= c.odometer_km;

  select * into j from field_jobs x
   where x.booking_id = p_booking and x.kind in ('return_check_in', 'pickup_from_renter') and x.status not in ('done', 'cancelled')
     and (p_job is null or x.id = p_job)
   order by (x.assigned_to is not distinct from p_by) desc, x.scheduled_at limit 1;
  if j.id is not null then
    update field_jobs
       set status = 'done', completed_at = p_now, started_at = coalesce(started_at, p_now),
           cleaning_grade = case c.cleanliness when 'clean' then 'standard' else c.cleanliness end,
           belongings_found = coalesce(c.belongings_found, belongings_found)
     where id = j.id;
  end if;

  -- any new damage: an incident, and (through the incident) an urgent task for Fleet and an Admin
  select string_agg(dm.label || ': ' || dm.location || ', ' || dm.description, '; ' order by dm.label) into v_new_damage
    from condition_report_damages dm where dm.condition_report_id = v_report and dm.is_new;
  if v_new_damage is not null then
    v_incident := app.open_incident('damage_at_return', b.vehicle_id, p_by,
        jsonb_build_object('description', 'New damage recorded at return: ' || v_new_damage, 'occurred_at', v_checked_in,
                           'place', coalesce(j.place, b.return_place)), p_booking, case when v_role = 'field' then 'field' else 'staff' end, p_now);
    update condition_report_damages set incident_id = v_incident, status_vs_pickup = coalesce(status_vs_pickup, 'new')
     where condition_report_id = v_report and is_new and incident_id is null;
  end if;
  if nullif(btrim(coalesce(c.belongings_found, '')), '') is not null then
    perform app.raise_task(p_type => 'lost_property', p_title => format('Booking %s: belongings found in the car', b.booking_number),
        p_detail => c.belongings_found, p_booking => p_booking, p_vehicle => b.vehicle_id, p_renter => b.renter_id,
        p_dedupe => 'lost_property:' || p_booking, p_created_by => p_by);
  end if;

  v_findings := app.return_findings(p_booking);
  update condition_reports set findings = v_findings where id = v_report;
  return v_findings || jsonb_build_object('condition_report_id', v_report, 'incident_id', v_incident,
                                          'late_extra_days', l.extra_days, 'late_extra_days_cents', l.extra_days_cents, 'late_fee_cents', l.late_fee_cents);
end $$;

-- Fleet compares both photo sets and confirms the findings (procedure 4, step 6). This marks the
-- return report reviewed; the report's own trigger then tells Finance (task and event).
-- p_findings may correct what the report says: cleanliness, odour, notes, and any other key is
-- kept with the findings (for example "pump_cost_cents" when Fleet already has the receipt).
create or replace function app.submit_return_findings(p_booking uuid, p_by uuid, p_findings jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  f jsonb := coalesce(p_findings, '{}'::jsonb);
  b bookings;
  c condition_reports;
  v_findings jsonb;
begin
  if not app.user_runs_fleet(p_by) then
    raise exception 'Fleet or an Admin reviews the photo sets' using errcode = '42501';
  end if;
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  select * into c from condition_reports where booking_id = p_booking and kind = 'return' for update;
  if c.id is null or c.completed_at is null then
    raise exception 'Booking % has no completed return Condition Report', b.booking_number using errcode = '23514';
  end if;
  if c.reviewed_at is not null then
    raise exception 'The return of booking % has already been reviewed', b.booking_number using errcode = '23514';
  end if;
  update condition_reports
     set cleanliness = coalesce(f ->> 'cleanliness', cleanliness), odour = coalesce((f ->> 'odour')::boolean, odour),
         notes = coalesce(f ->> 'notes', notes)
   where id = c.id;
  v_findings := app.return_findings(p_booking) || (f - 'cleanliness' - 'odour' - 'notes');
  insert into messages (direction, channel, template_code, subject, body, booking_id, vehicle_id, related_table, related_id, sent_by, status)
  values ('outbound', 'portal', 'T7', format('Findings, booking %s', b.booking_number),
          format('Booking %s: km out/in %s/%s, allowance %s. Fuel out/in %s/%s. Cleaning %s. Damage %s. Minutes late %s. Keys %s of %s.',
                 b.booking_number, v_findings ->> 'km_out', v_findings ->> 'km_in', v_findings ->> 'km_allowance',
                 v_findings ->> 'fuel_out_pct', v_findings ->> 'fuel_in_pct', coalesce(v_findings ->> 'cleanliness', 'not recorded'),
                 case when jsonb_array_length(v_findings -> 'new_damage') = 0 then 'none'
                      else (select string_agg(x ->> 'label', ', ') from jsonb_array_elements(v_findings -> 'new_damage') x) end,
                 v_findings ->> 'minutes_late', coalesce(v_findings ->> 'keys_in', '?'), coalesce(v_findings ->> 'keys_out', '?')),
          p_booking, b.vehicle_id, 'condition_reports', c.id, p_by, 'sent');
  update condition_reports set findings = v_findings, reviewed_by = p_by, reviewed_at = now() where id = c.id;
  return v_findings;
end $$;

-- Mark any other Condition Report reviewed (the pickup set, a swap, a "ready" set).
create or replace function app.review_condition_report(p_report uuid, p_by uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  c condition_reports;
begin
  if not app.user_runs_fleet(p_by) then
    raise exception 'Fleet or an Admin reviews the photo sets' using errcode = '42501';
  end if;
  select * into c from condition_reports where id = p_report for update;
  if c.id is null then raise exception 'Condition Report % not found', p_report; end if;
  if c.kind = 'return' and c.booking_id is not null then
    perform app.submit_return_findings(c.booking_id, p_by);
    return;
  end if;
  update condition_reports set reviewed_by = p_by, reviewed_at = now() where id = p_report and reviewed_at is null;
end $$;

-- A Condition Report was completed or reviewed: the review task for Fleet, then the findings
-- for Finance. Works the same whether the row was written by the functions above or by Fleet
-- directly under row-level security.
create or replace function app.condition_report_after_write() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v vehicles;
  v_findings jsonb;
  v_has_damage boolean;
begin
  if new.completed_at is not null and (tg_op = 'INSERT' or old.completed_at is null)
     and new.kind in ('pickup', 'return', 'swap_out', 'swap_in') and new.reviewed_at is null then
    if new.booking_id is not null then select * into b from bookings where id = new.booking_id; end if;
    perform app.raise_task(p_type => 'review_photos',
        p_title => format('Review the %s photos%s', replace(new.kind, '_', ' '), coalesce(', booking ' || b.booking_number, '')),
        p_booking => new.booking_id, p_vehicle => new.vehicle_id, p_related_table => 'condition_reports', p_related_id => new.id,
        p_dedupe => 'review_photos:' || new.id);
  end if;

  if new.reviewed_at is not null and (tg_op = 'INSERT' or old.reviewed_at is null) then
    update tasks set status = 'done', completed_at = now(), completed_by = new.reviewed_by
     where task_type = 'review_photos' and related_table = 'condition_reports' and related_id = new.id
       and status in ('open', 'in_progress', 'waiting');
    if new.kind = 'return' and new.booking_id is not null then
      select * into b from bookings where id = new.booking_id;
      select * into v from vehicles where id = new.vehicle_id;
      v_findings := coalesce(new.findings, app.return_findings(new.booking_id));
      v_has_damage := exists (select 1 from condition_report_damages dm where dm.condition_report_id = new.id and dm.is_new);
      if b.status in ('returned', 'closed') and (b.booking_type <> 'owner' or v_has_damage) then
        perform app.raise_task(p_type => 'price_findings',
            p_title => format('Price the findings of booking %s', b.booking_number),
            p_detail => format('Km over %s. Fuel short %s%%. Cleaning %s. Minutes late %s. %s',
                               coalesce(v_findings ->> 'km_over', '0'), coalesce(v_findings ->> 'fuel_short_pct', '0'),
                               coalesce(v_findings ->> 'cleanliness', 'not recorded'), coalesce(v_findings ->> 'minutes_late', '0'),
                               case when v_has_damage then 'New damage recorded: an Admin prices damage.' else 'No new damage.' end),
            p_booking => new.booking_id, p_vehicle => new.vehicle_id, p_renter => b.renter_id,
            p_related_table => 'condition_reports', p_related_id => new.id, p_dedupe => 'price_findings:' || new.booking_id);
      end if;
      perform app.emit_event('staff_return_findings', 'booking', new.booking_id,
        v_findings || jsonb_build_object('vehicle_name', v.year || ' ' || v.make || ' ' || v.model, 'has_damage', v_has_damage,
                                         'deposit_amount_cents', b.deposit_cents, 'condition_report_id', new.id,
                                         'deposit_release_due', (select dp.release_due_on from deposits dp where dp.booking_id = b.id)),
        'staff_return_findings:' || new.booking_id || ':' || new.id);
    end if;
  end if;
  return null;
end $$;
create trigger condition_reports_after_write after insert or update on condition_reports
  for each row execute function app.condition_report_after_write();

-- ---------------------------------------------------------------- damage found in the 48-hour review
-- The renter is told of damage found after hand-back (message T8). Inside the 48 hours after
-- Check-in anyone who may record the damage may report it; later only an Admin, with the reason.
create or replace function app.report_damage_to_renter(p_damage uuid, p_by uuid, p_now timestamptz default now(),
                                                       p_override_reason text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  dm condition_report_damages;
  c condition_reports;
  b bookings;
  v vehicles;
  r renters;
  v_hours integer := (app.settings()).damage_late_report_hours;
begin
  select * into dm from condition_report_damages where id = p_damage for update;
  if dm.id is null then raise exception 'Damage % not found', p_damage; end if;
  if dm.reported_to_renter_at is not null then return; end if;
  select * into c from condition_reports where id = dm.condition_report_id;
  select * into b from bookings where id = c.booking_id;
  if b.id is null or not dm.found_later then
    raise exception 'Only damage found after hand-back on a booking is reported this way' using errcode = '23514';
  end if;
  if not (app.user_runs_fleet(p_by) or app.user_va_has(p_by, 'finance')) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if p_now > b.checked_in_at + make_interval(hours => v_hours)
     and not (app.user_is_admin(p_by) and btrim(coalesce(p_override_reason, '')) <> '') then
    raise exception 'The % hours after Check-in have passed: only an Admin may still report this damage, with the reason', v_hours
      using errcode = '23514';
  end if;
  select * into v from vehicles where id = b.vehicle_id;
  select * into r from renters where id = b.renter_id;
  update condition_report_damages set reported_to_renter_at = p_now where id = p_damage;
  perform app.emit_event('renter_damage_found', 'incident', dm.incident_id,
    jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'renter_id', b.renter_id,
                       'first_name', split_part(btrim(r.legal_name), ' ', 1),
                       'vehicle_name', v.year || ' ' || v.make || ' ' || v.model,
                       'checkin_at', b.checked_in_at, 'inspection_at', p_now,
                       'damage_description', dm.location || ': ' || dm.description, 'damage_id', dm.id, 'condition_report_id', c.id,
                       'photo_ids', (select coalesce(jsonb_agg(p.id order by p.seq), '[]'::jsonb) from condition_report_photos p where p.damage_id = dm.id),
                       'reported_late', p_now > b.checked_in_at + make_interval(hours => v_hours), 'late_reason', p_override_reason),
    'renter_damage_found:' || coalesce(dm.incident_id::text, b.id::text) || ':' || dm.id);
end $$;

-- Record damage that was not on the signed return report: a damage mark on the return report
-- (found later), its close-ups, an incident, and the message to the renter.
-- p_damage: {label, location, description, kind, size_cm, position, photos: [{storage_path, ...}],
--            report_to_renter (default true)}. Returns the incident's id.
create or replace function app.record_late_damage(p_booking uuid, p_by uuid, p_damage jsonb, p_now timestamptz default now(),
                                                  p_override_reason text default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  d jsonb := coalesce(p_damage, '{}'::jsonb);
  b bookings;
  c condition_reports;
  x jsonb;
  v_role text;
  v_label text;
  v_damage uuid;
  v_seq integer;
  v_incident uuid;
  v_hours integer := (app.settings()).damage_late_report_hours;
  v_late boolean;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if b.status not in ('returned', 'closed') then
    raise exception 'Booking % is %: damage found later is recorded after the return', b.booking_number, b.status using errcode = '23514';
  end if;
  v_role := app.condition_report_actor(p_booking, b.vehicle_id, p_by);
  if v_role not in ('field', 'staff') then
    raise exception 'Damage found later is recorded by CarmaCars staff' using errcode = '42501';
  end if;
  if d ->> 'location' is null or d ->> 'description' is null then
    raise exception 'Describe the damage: where it is and what it is' using errcode = '22023';
  end if;
  v_late := p_now > b.checked_in_at + make_interval(hours => v_hours);
  if v_late and not (app.user_is_admin(p_by) and btrim(coalesce(p_override_reason, '')) <> '') then
    raise exception 'The % hours after Check-in have passed: only an Admin may still record this damage against the renter, with the reason', v_hours
      using errcode = '23514';
  end if;
  select * into c from condition_reports where booking_id = p_booking and kind = 'return';
  if c.id is null then
    raise exception 'Booking % has no return Condition Report', b.booking_number using errcode = '23514';
  end if;
  v_label := coalesce(d ->> 'label', 'L' || (select count(*) + 1 from condition_report_damages where condition_report_id = c.id and found_later));
  insert into condition_report_damages (condition_report_id, label, location, description, is_new, found_later, kind, size_cm, position, status_vs_pickup)
  values (c.id, v_label, d ->> 'location', d ->> 'description', true, true, d ->> 'kind', (d ->> 'size_cm')::numeric, d -> 'position', 'new')
  returning id into v_damage;
  select coalesce(max(seq), 0) into v_seq from condition_report_photos where condition_report_id = c.id;
  for x in select * from jsonb_array_elements(coalesce(d -> 'photos', '[]'::jsonb)) loop
    v_seq := v_seq + 1;
    insert into condition_report_photos (condition_report_id, seq, shot, damage_id, storage_path, uploaded_by, device_taken_at,
                                         latitude, longitude, width, height, quality_flags)
    values (c.id, v_seq, 'damage_closeup', v_damage, x ->> 'storage_path', p_by, (x ->> 'device_taken_at')::timestamptz,
            (x ->> 'latitude')::numeric, (x ->> 'longitude')::numeric, (x ->> 'width')::integer, (x ->> 'height')::integer, x -> 'quality_flags');
  end loop;
  v_incident := app.open_incident('damage_found_later', b.vehicle_id, p_by,
      jsonb_build_object('description', format('Damage found after hand-back (%s): %s, %s', v_label, d ->> 'location', d ->> 'description'),
                         'occurred_at', b.checked_in_at), p_booking, case when v_role = 'field' then 'field' else 'staff' end, p_now);
  update condition_report_damages set incident_id = v_incident where id = v_damage;
  -- Fleet or an Admin tells the renter at once; damage recorded by field staff waits for Fleet
  -- to look at it (the incident's task) and report it with app.report_damage_to_renter().
  if coalesce((d ->> 'report_to_renter')::boolean, true) and app.user_runs_fleet(p_by) then
    perform app.report_damage_to_renter(v_damage, p_by, p_now, p_override_reason);
  end if;
  return v_incident;
end $$;

-- ================================================================ 13. incidents and breakdowns
-- The first-response steps of an incident, from procedures 8, 9 and 10, as a list to tick off.
create table incident_steps (
  id           uuid primary key default gen_random_uuid(),
  incident_id  uuid not null references incidents (id) on delete cascade,
  seq          integer not null check (seq > 0),
  step_code    text not null,
  instruction  text not null,
  procedure_no smallint check (procedure_no between 1 and 20),
  owner_role   text not null default 'fleet' check (owner_role in ('fleet', 'admin', 'finance', 'cs')),
  done_at      timestamptz,
  done_by      uuid references users (id),
  note         text,
  created_at   timestamptz not null default now(),
  unique (incident_id, seq),
  check ((done_at is null) = (done_by is null))
);
create index incident_steps_open_idx on incident_steps (incident_id) where done_at is null;

-- Dollars for a sentence: 250000 -> $2,500, 7550 -> $75.50.
create or replace function app.money_text(p_cents bigint) returns text
language sql immutable as $$
  select case when p_cents is null then 'the set amount'
              when p_cents % 100 = 0 then '$' || to_char(p_cents / 100, 'FM999,999,990')
              else '$' || to_char(p_cents / 100.0, 'FM999,999,990.00') end
$$;

-- Open an incident, from the renter's report or from staff, with its first-response steps.
-- p_details: occurred_at, place, description, other_party, police_report_number, anyone_hurt,
--            drivable, breakdown_cause, driver_id, staff_had_car.
-- p_reported_by: 'renter' (the renter of the booking, in the portal), 'staff' (Fleet, CS or an
-- Admin logging a call) or 'field' (field staff, for a car on one of their jobs).
-- A car that is not drivable goes out of service and its calendar is blocked for repair.
-- The amounts and times named in the steps are read from the settings and the fee defaults.
create or replace function app.open_incident(p_kind text, p_vehicle uuid, p_by uuid, p_details jsonb default '{}'::jsonb,
    p_booking uuid default null, p_reported_by text default 'staff', p_now timestamptz default now())
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  d jsonb := coalesce(p_details, '{}'::jsonb);
  b bookings;
  v vehicles;
  v_set program_settings := app.settings();
  v_booking uuid := p_booking;
  v_id uuid;
  v_number text;
  v_drivable boolean := (d ->> 'drivable')::boolean;
  v_hurt boolean := (d ->> 'anyone_hurt')::boolean;
  v_cause text := d ->> 'breakdown_cause';
  v_ded text; v_fee_other text; v_fee_claim text; v_late_hours text;
  v_steps text[][];
  i integer;
begin
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then raise exception 'Vehicle % not found', p_vehicle; end if;
  if v_booking is null then
    select x.id into v_booking from bookings x where x.vehicle_id = p_vehicle and x.status = 'on_rent' order by x.pickup_at desc limit 1;
  end if;
  if v_booking is not null then
    select * into b from bookings where id = v_booking;
    if b.id is null then raise exception 'Booking % not found', v_booking; end if;
  end if;

  if p_reported_by = 'renter' then
    if b.id is null or not app.is_booking_renter(b.id, p_by) then
      raise exception 'A renter reports an incident on their own booking' using errcode = '42501';
    end if;
    if p_kind not in ('accident', 'theft', 'vandalism', 'breakdown') then
      raise exception 'A renter reports an accident, a theft, vandalism or a breakdown' using errcode = '23514';
    end if;
    if b.status <> 'on_rent' then
      raise exception 'Booking % is not on rent', b.booking_number using errcode = '23514';
    end if;
  elsif p_reported_by = 'field' then
    if not (app.user_is_field(p_by) and exists (
              select 1 from field_jobs j where j.assigned_to = p_by and j.status <> 'cancelled'
                 and (j.vehicle_id = p_vehicle or (b.id is not null and j.booking_id = b.id)))) then
      raise exception 'Field staff report an incident on a vehicle of their own jobs' using errcode = '42501';
    end if;
  elsif p_reported_by = 'staff' then
    if not (app.user_runs_fleet(p_by) or app.user_va_has(p_by, 'cs')) then
      raise exception 'Fleet, customer service or an Admin opens an incident' using errcode = '42501';
    end if;
  else
    raise exception 'Unknown reporter "%"', p_reported_by using errcode = '22023';
  end if;
  if btrim(coalesce(d ->> 'description', '')) = '' then
    raise exception 'Describe what happened' using errcode = '22023';
  end if;

  insert into incidents (kind, vehicle_id, booking_id, driver_id, staff_user_id, occurred_at, reported_at, place, description,
                         other_party, police_report_number, anyone_hurt, drivable, breakdown_cause, renter_at_fault,
                         rental_ended, renter_report_due_at, opened_by)
  values (p_kind, p_vehicle, v_booking, (d ->> 'driver_id')::uuid,
          case when coalesce((d ->> 'staff_had_car')::boolean, false) then p_by end,
          coalesce((d ->> 'occurred_at')::timestamptz, p_now), p_now, d ->> 'place', d ->> 'description',
          d -> 'other_party', d ->> 'police_report_number', v_hurt, v_drivable, v_cause,
          case when p_kind <> 'breakdown' or v_cause is null then null else v_cause <> 'mechanical' end,
          -- not drivable after an accident: the rental ends, no replacement, no refund
          p_kind in ('accident', 'theft', 'vandalism') and v_drivable is false and v_booking is not null,
          case when p_kind in ('accident', 'theft', 'vandalism') and v_booking is not null
               then p_now + make_interval(hours => v_set.incident_report_hours) end,
          p_by)
  returning id, incident_number into v_id, v_number;

  insert into incident_events (incident_id, occurred_at, kind, detail, actor_user_id)
  values (v_id, p_now, case when p_reported_by = 'renter' then 'message' else 'call' end,
          format('Incident opened (%s) by %s: %s', p_kind, p_reported_by, d ->> 'description'), p_by);

  -- the amounts the steps name, as they stand for this booking or vehicle today
  v_ded := app.money_text(coalesce(b.deductible_cents, v_set.deductible_cents));
  v_fee_other := app.money_text(coalesce((select t.amount_cents from app.booking_fee_term(v_booking, 'admin_fee_other') t),
                                         (select e.amount_cents from public.effective_fee('admin_fee_other', p_vehicle) e)));
  v_fee_claim := app.money_text(coalesce((select t.amount_cents from app.booking_fee_term(v_booking, 'admin_fee_claim') t),
                                         (select e.amount_cents from public.effective_fee('admin_fee_claim', p_vehicle) e)));
  v_late_hours := v_set.damage_late_report_hours::text;

  -- the first-response steps: {code, instruction, procedure, who}
  v_steps := case
    when p_kind in ('accident', 'theft', 'vandalism') then array[
      array['safety', 'Anyone hurt: call 911. Send the accident instructions (T16) and talk the renter through it', '9', 'fleet'],
      array['log', 'Complete the incident record: booking, driver, time, place, other party, police report number', '9', 'fleet'],
      array['tell_admin', 'Tell an Admin (every incident, immediately)', '9', 'fleet'],
      array['tow', 'Not drivable: tow to an approved shop. The rental ends: no replacement car, no refund', '9', 'fleet'],
      array['renter_report', format('Renter''s written report, photos and all keys within %s hours', v_set.incident_report_hours), '9', 'fleet'],
      array['estimate', 'Estimate from an approved shop only. Total = repair + towing + storage + loss of use', '9', 'fleet'],
      array['broker', format('Total %s or more: an Admin notifies the broker the same day and claims on the fleet policy', v_ded), '9', 'admin'],
      array['owner', 'Send the Owner the incident notice (T17)', '9', 'fleet'],
      array['calendar', 'Block the calendar until the shop releases the car, then detail it', '9', 'fleet'],
      array['bill', format('Under %s: bill at cost plus %s. %s or more: bill %s plus %s', v_ded, v_fee_other, v_ded, v_ded, v_fee_claim), '9', 'finance']]
    when p_kind = 'breakdown' then array[
      array['safety', 'Confirm the renter is safe. Get the location (check the Tracker), the symptom and warning lights', '10', 'fleet'],
      array['roadside', 'Dispatch the roadside provider on file. Send the breakdown message (T18)', '10', 'fleet'],
      array['cause', format('Record the cause. Mechanical, not the renter''s fault: roadside free, and a replacement car or a refund of unused time. Lockout, out of fuel or charge, flat battery from lights left on, tire damage, stuck: the renter pays the call-out cost plus %s', v_fee_other), '10', 'fleet'],
      array['replacement', 'Replacement car: Part 4 Return for the old car, Part 4 Pickup for the new one; enter the new car in the Summary', '10', 'fleet'],
      array['owner', 'Tell the Owner: mechanical repair is the Owner''s cost. Mark the car Out of Service', '10', 'fleet'],
      array['tell_admin', 'Escalate to an Admin when a replacement or refund is needed, on a second breakdown of the same car, or when the car is unsafe', '10', 'fleet']]
    when p_kind in ('late_return', 'non_return') then array[
      array['call', 'At the return time: call, send the first late notice (T13), check the Tracker, offer a paid extension', '8', 'fleet'],
      array['charges', 'After the grace period: the rental charge for each extra day plus the late return fee apply', '8', 'finance'],
      array['final_notice', format('At %s minutes: call twice, send the final notice (T14), tell an Admin', v_set.late_admin_minutes), '8', 'fleet'],
      array['disable', format('%s minutes after the final notice: only an Admin approves disabling, and only when the Tracker shows the car stationary with the ignition off. Never while moving', v_set.tracker_notice_minutes), '8', 'admin'],
      array['police', 'Renter unreachable for a day: an Admin may report the car stolen; give police the Tracker location and tell the Owner', '8', 'admin'],
      array['recover', 'After recovery: return inspection and post-rental charges, plus recovery costs; no refund', '8', 'fleet']]
    when p_kind in ('damage_at_return', 'damage_found_later') then array[
      array['photos', 'Compare the pickup and return photo sets for the damaged area', '9', 'fleet'],
      array['notify', format('Damage not on the signed return report: tell the renter with photos within %s hours of return (T8)', v_late_hours), '4', 'fleet'],
      array['tell_admin', 'Tell an Admin (any damage)', '9', 'fleet'],
      array['estimate', 'Estimate from an approved shop only. Total = repair + towing + storage + loss of use', '9', 'fleet'],
      array['bill', format('Under %s: bill at cost plus %s. %s or more: an Admin claims on the fleet policy and the renter is billed %s plus %s', v_ded, v_fee_other, v_ded, v_ded, v_fee_claim), '9', 'finance'],
      array['owner', 'Send the Owner the incident notice (T17)', '9', 'fleet']]
    else array[
      array['tell_admin', 'Tell an Admin', '8', 'fleet'],
      array['log', 'Record every call, message and decision on the incident with its time', '8', 'fleet']]
  end;
  for i in 1 .. array_length(v_steps, 1) loop
    insert into incident_steps (incident_id, seq, step_code, instruction, procedure_no, owner_role)
    values (v_id, i, v_steps[i][1], v_steps[i][2], v_steps[i][3]::smallint, v_steps[i][4]);
  end loop;

  -- a car that cannot be driven is out of service, and nothing new is confirmed on it
  if v_drivable is false then
    if v.status in ('available', 'on_rent', 'cleaning') then
      update vehicles set status = 'out_of_service' where id = p_vehicle;
    end if;
    if not exists (select 1 from vehicle_calendar_blocks c where c.vehicle_id = p_vehicle and c.reason = 'repair'
                      and c.removed_at is null and c.ends_at is null) then
      insert into vehicle_calendar_blocks (vehicle_id, reason, starts_at, ends_at, note, created_by)
      values (p_vehicle, 'repair', p_now, null, format('Incident %s: not drivable', v_number), p_by);
    end if;
  end if;
  return v_id;
end $$;

-- Tick off one first-response step.
create or replace function app.complete_incident_step(p_step uuid, p_by uuid, p_note text default null) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  s incident_steps;
begin
  if not (app.user_runs_fleet(p_by) or app.user_va_has(p_by, 'cs', 'finance')) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select * into s from incident_steps where id = p_step for update;
  if s.id is null then raise exception 'Incident step % not found', p_step; end if;
  if s.owner_role = 'admin' and not app.user_is_admin(p_by) then
    raise exception 'This step is an Admin''s' using errcode = '42501';
  end if;
  if s.done_at is not null then return; end if;
  update incident_steps set done_at = now(), done_by = p_by, note = p_note where id = p_step;
  insert into incident_events (incident_id, kind, detail, actor_user_id)
  values (s.incident_id, 'decision', format('Step done: %s%s', s.step_code, coalesce('. ' || p_note, '')), p_by);
end $$;

-- A new incident: an urgent task for Fleet, and for an Admin unless it is a breakdown (which
-- reaches an Admin only when a replacement or refund is needed).
create or replace function app.incident_after_insert() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_booking text;
  v_title text;
begin
  select booking_number into v_booking from bookings where id = new.booking_id;
  v_title := format('%s %s (%s)%s', case when new.kind = 'breakdown' then 'Breakdown' else 'Incident' end, new.incident_number,
                    replace(new.kind, '_', ' '), coalesce(', booking ' || v_booking, ''));
  perform app.raise_task(p_type => case when new.kind = 'breakdown' then 'breakdown' else 'incident' end,
      p_title => v_title, p_detail => new.description, p_booking => new.booking_id, p_vehicle => new.vehicle_id,
      p_related_table => 'incidents', p_related_id => new.id, p_dedupe => 'incident:' || new.id || ':fleet', p_created_by => new.opened_by);
  if new.kind <> 'breakdown' then
    perform app.raise_task(p_type => 'incident', p_title => v_title, p_detail => new.description,
        p_booking => new.booking_id, p_vehicle => new.vehicle_id, p_related_table => 'incidents', p_related_id => new.id,
        p_dedupe => 'incident:' || new.id || ':admin', p_queue => 'admin',     -- no creator: the opener must not see the admin queue's copy
        p_escalation_reason => 'every incident, immediately');
  end if;
  return null;
end $$;
create trigger incidents_after_insert after insert on incidents
  for each row execute function app.incident_after_insert();

-- Swap the vehicle of a booking that is on rent (a breakdown that is not the renter's fault).
-- Needs an Admin (procedure 10: "replacement or refund needed"). The old car goes out of
-- service, the new car goes on rent, the Owner's control block moves with the booking, and the
-- swap is recorded. Field staff then complete a swap-out report on the old car and a swap-in
-- report on the new one. The booking's price, rates and Owner (its snapshot) do not change.
create or replace function app.swap_vehicle(p_booking uuid, p_to_vehicle uuid, p_by uuid, p_reason text,
    p_approved_by uuid default null, p_incident uuid default null, p_now timestamptz default now())
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_old vehicles;
  v_new vehicles;
  v_admin uuid := coalesce(p_approved_by, p_by);
  v_swap uuid;
begin
  if not app.user_runs_fleet(p_by) then
    raise exception 'Fleet or an Admin swaps a vehicle' using errcode = '42501';
  end if;
  if not app.user_is_admin(v_admin) then
    raise exception 'A replacement vehicle needs an Admin''s approval' using errcode = '42501';
  end if;
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'Give the reason for the swap' using errcode = '22023';
  end if;
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if b.status <> 'on_rent' then
    raise exception 'Booking % is %: a vehicle is swapped during a rental. Before pickup, change the booking instead', b.booking_number, b.status
      using errcode = '23514';
  end if;
  if p_to_vehicle = b.vehicle_id then
    raise exception 'That is the vehicle the booking already has' using errcode = '23514';
  end if;
  select * into v_old from vehicles where id = b.vehicle_id for update;
  select * into v_new from vehicles where id = p_to_vehicle for update;
  if v_new.id is null then raise exception 'Vehicle % not found', p_to_vehicle; end if;
  if v_new.status <> 'available' or v_new.management_mode = 'turo_only' then
    raise exception 'The replacement vehicle is % and cannot be handed over', v_new.status using errcode = '23514';
  end if;
  if not app.vehicle_is_available(p_to_vehicle, p_now, greatest(b.return_at, p_now + interval '1 minute'), p_booking) then
    raise exception 'The replacement vehicle is not free until the end of this rental' using errcode = '23P01';
  end if;

  insert into booking_vehicle_swaps (booking_id, from_vehicle_id, to_vehicle_id, swapped_at, reason, approved_by)
  values (p_booking, b.vehicle_id, p_to_vehicle, p_now, p_reason, v_admin)
  returning id into v_swap;

  update tracker_access_blocks set ends_at = greatest(p_now, starts_at) where booking_id = p_booking and vehicle_id = b.vehicle_id and ends_at is null;
  update bookings set vehicle_id = p_to_vehicle where id = p_booking;
  update vehicles set status = 'out_of_service' where id = v_old.id and status = 'on_rent';
  update vehicles set status = 'on_rent' where id = v_new.id;
  if b.booking_type <> 'owner' and b.management_mode = 'managed' then
    insert into tracker_access_blocks (vehicle_id, booking_id, reason, starts_at) values (p_to_vehicle, p_booking, 'managed_rental', p_now);
  end if;
  -- open jobs of the booking follow it to the new car
  update field_jobs set vehicle_id = p_to_vehicle where booking_id = p_booking and status in ('scheduled', 'acknowledged');

  if p_incident is not null then
    insert into incident_events (incident_id, occurred_at, kind, detail, actor_user_id)
    values (p_incident, p_now, 'decision',
            format('Replacement vehicle: %s %s %s (%s) in place of %s %s %s (%s). %s', v_new.year, v_new.make, v_new.model, coalesce(v_new.plate, 'no plate'),
                   v_old.year, v_old.make, v_old.model, coalesce(v_old.plate, 'no plate'), p_reason), p_by);
  end if;
  perform app.raise_task(p_type => 'vehicle_swap',
      p_title => format('Booking %s: vehicle swapped. Complete both Condition Reports', b.booking_number),
      p_detail => format('Swap-out report on %s %s %s, swap-in report on %s %s %s. %s', v_old.year, v_old.make, v_old.model,
                         v_new.year, v_new.make, v_new.model, p_reason),
      p_booking => p_booking, p_vehicle => p_to_vehicle, p_related_table => 'booking_vehicle_swaps', p_related_id => v_swap,
      p_dedupe => 'vehicle_swap:' || v_swap, p_created_by => p_by);
  return v_swap;
end $$;

-- Complete a Condition Report that is not the pickup or the return of a booking: swap-out,
-- swap-in, baseline, exit or "ready". The photo set must be complete.
create or replace function app.complete_condition_report(p_report uuid, p_by uuid, p_now timestamptz default now()) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  c condition_reports;
  v_problems text[];
begin
  select * into c from condition_reports where id = p_report for update;
  if c.id is null then raise exception 'Condition Report % not found', p_report; end if;
  if c.kind in ('pickup', 'return') then
    raise exception 'A % report is completed by the handover or return checklist', c.kind using errcode = '23514';
  end if;
  if c.completed_at is not null then return; end if;
  perform app.condition_report_actor(c.booking_id, c.vehicle_id, p_by, c.field_job_id);
  v_problems := app.condition_report_problems(p_report);
  if cardinality(v_problems) > 0 then
    raise exception 'The photo set is not complete: %', array_to_string(v_problems, '; ') using errcode = '23514';
  end if;
  if c.kind in ('swap_out', 'swap_in') and c.odometer_km is null then
    raise exception 'The odometer reading is required on a swap report' using errcode = '23514';
  end if;
  update condition_reports set performed_at = p_now, completed_at = p_now, completed_by = p_by,
         staff_signed_at = coalesce(staff_signed_at, p_now) where id = p_report;
  if c.odometer_km is not null then
    update vehicles set odometer_km = c.odometer_km where id = c.vehicle_id and coalesce(odometer_km, 0) <= c.odometer_km;
  end if;
end $$;

-- ---------------------------------------------------------------- tracker: disabling a vehicle
-- Fleet (or an Admin) asks for a vehicle to be disabled. Nothing is sent: the request waits for
-- an Admin. Where the agreement requires notice (late return, an unpaid charge, a serious
-- breach, coverage ended), the final notice must have been sent at least that long ago
-- (program_settings.tracker_notice_minutes).
create or replace function app.request_tracker_disable(p_vehicle uuid, p_by uuid, p_reason_code text, p_reason text,
    p_booking uuid default null, p_incident uuid default null, p_notice_sent_at timestamptz default null,
    p_now timestamptz default now())
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  b bookings;
  r renters;
  v_notice integer := (app.settings()).tracker_notice_minutes;
  v_device uuid;
  v_id uuid;
begin
  if not app.user_runs_fleet(p_by) then
    raise exception 'Fleet or an Admin requests disabling a vehicle' using errcode = '42501';
  end if;
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then raise exception 'Vehicle % not found', p_vehicle; end if;
  select id into v_device from tracker_devices where vehicle_id = p_vehicle and status = 'installed';
  if v_device is null then
    raise exception 'This vehicle has no installed Tracker' using errcode = '23514';
  end if;
  if p_reason_code in ('late_return', 'unpaid_charge', 'serious_breach', 'coverage_ended') then
    if p_notice_sent_at is null or p_notice_sent_at > p_now - make_interval(mins => v_notice) then
      raise exception 'Notice is required on this ground: the final notice must have been sent at least % minutes ago', v_notice
        using errcode = '23514';
    end if;
  elsif p_reason_code not in ('suspected_theft', 'abandonment', 'fraud', 'unsafe_driving', 'tracker_tampering', 'authority_order') then
    raise exception '"%" is not a ground for disabling a vehicle', p_reason_code using errcode = '23514';
  end if;
  if p_booking is not null then
    select * into b from bookings where id = p_booking;
    select * into r from renters where id = b.renter_id;
  end if;
  insert into tracker_commands (tracker_device_id, vehicle_id, booking_id, incident_id, command, actor_type, requested_by,
                                reason_code, reason, notice_sent_at, status)
  values (v_device, p_vehicle, p_booking, p_incident, 'engine_disable', case when app.user_is_admin(p_by) then 'admin' else 'staff' end, p_by,
          p_reason_code, p_reason, p_notice_sent_at, 'requested')
  returning id into v_id;
  if p_incident is not null then
    insert into incident_events (incident_id, occurred_at, kind, detail, tracker_command_id, actor_user_id)
    values (p_incident, p_now, 'tracker_command', format('Disable requested (%s): %s', p_reason_code, p_reason), v_id, p_by);
  end if;
  perform app.emit_event('staff_disable_approval_needed', 'tracker_command', v_id,
    jsonb_build_object('vehicle_id', p_vehicle, 'vehicle_name', v.year || ' ' || v.make || ' ' || v.model,
                       'booking_id', p_booking, 'booking_number', b.booking_number, 'renter_name', r.legal_name, 'renter_phone', r.mobile,
                       'disable_ground', p_reason_code, 'reason', p_reason, 'final_notice_at', p_notice_sent_at,
                       'requested_at', p_now, 'requested_by', p_by),
    'staff_disable_approval_needed:' || v_id || ':requested');
  return v_id;
end $$;

-- An Admin approves the request with the Tracker reading taken just now. Refused unless the
-- reading is fresh (program_settings.tracker_reading_max_minutes, never more than the 5 minutes
-- the table's own guard allows) and shows the car stationary with the ignition off. The guard
-- of migration 0006 checks the same again when the command is sent.
create or replace function app.approve_tracker_disable(p_command uuid, p_admin uuid, p_observed_at timestamptz,
    p_speed_kmh numeric, p_ignition_on boolean, p_screenshot_document uuid default null, p_now timestamptz default now())
returns void language plpgsql security definer set search_path = public, app as $$
declare
  c tracker_commands;
  v_max integer := (app.settings()).tracker_reading_max_minutes;
begin
  if not app.user_is_admin(p_admin) then
    raise exception 'Only an Admin approves disabling a vehicle' using errcode = '42501';
  end if;
  select * into c from tracker_commands where id = p_command for update;
  if c.id is null then raise exception 'Tracker command % not found', p_command; end if;
  if c.command <> 'engine_disable' or c.status <> 'requested' then
    raise exception 'This command is not a disable request waiting for approval' using errcode = '23514';
  end if;
  if p_observed_at is null or p_observed_at < p_now - make_interval(mins => v_max) or p_observed_at > p_now + interval '1 minute' then
    raise exception 'The Tracker reading is more than % minutes old: read it again before approving', v_max using errcode = '23514';
  end if;
  if p_speed_kmh is distinct from 0 or p_ignition_on is distinct from false then
    raise exception 'Never disable while moving: the Tracker must show the vehicle stationary with the ignition off' using errcode = '23514';
  end if;
  update tracker_commands
     set status = 'approved', approved_by = p_admin, approved_at = p_now, observed_at = p_observed_at,
         observed_speed_kmh = p_speed_kmh, observed_ignition_on = p_ignition_on, screenshot_document_id = p_screenshot_document
   where id = p_command;
  if c.incident_id is not null then
    insert into incident_events (incident_id, occurred_at, kind, detail, tracker_command_id, document_id, actor_user_id)
    values (c.incident_id, p_now, 'decision', 'Disable approved: Tracker shows the car stationary, ignition off', p_command, p_screenshot_document, p_admin);
  end if;
end $$;

create or replace function app.reject_tracker_disable(p_command uuid, p_admin uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  c tracker_commands;
begin
  if not app.user_is_admin(p_admin) then
    raise exception 'Only an Admin decides on disabling a vehicle' using errcode = '42501';
  end if;
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'Give the reason for refusing' using errcode = '22023';
  end if;
  select * into c from tracker_commands where id = p_command for update;
  if c.id is null then raise exception 'Tracker command % not found', p_command; end if;
  if c.command <> 'engine_disable' or c.status <> 'requested' then
    raise exception 'This command is not a disable request waiting for approval' using errcode = '23514';
  end if;
  update tracker_commands set status = 'rejected', error = p_reason, result_at = now() where id = p_command;
  if c.incident_id is not null then
    insert into incident_events (incident_id, kind, detail, tracker_command_id, actor_user_id)
    values (c.incident_id, 'decision', 'Disable refused: ' || p_reason, p_command, p_admin);
  end if;
end $$;

-- A disable request, however it was written: an urgent task for an Admin. A decision closes it.
create or replace function app.tracker_command_task() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
begin
  if new.command <> 'engine_disable' then return null; end if;
  if tg_op = 'INSERT' and new.status = 'requested' and new.actor_type in ('staff', 'admin') then
    select * into v from vehicles where id = new.vehicle_id;
    perform app.raise_task(p_type => 'approve_tracker_disable',
        p_title => format('Approve disabling %s %s %s (%s)', v.year, v.make, v.model, coalesce(v.plate, 'no plate')),
        p_detail => format('%s: %s', new.reason_code, new.reason), p_booking => new.booking_id, p_vehicle => new.vehicle_id,
        p_related_table => 'tracker_commands', p_related_id => new.id, p_dedupe => 'approve_tracker_disable:' || new.id,
        p_escalation_reason => 'only an Admin approves disabling');
  elsif tg_op = 'UPDATE' and old.status = 'requested' and new.status <> 'requested' then
    update tasks set status = 'done', completed_at = now(), completed_by = new.approved_by,
           completion_note = 'Request ' || new.status
     where task_type = 'approve_tracker_disable' and related_id = new.id and status in ('open', 'in_progress', 'waiting');
  end if;
  return null;
end $$;
create trigger tracker_commands_task after insert or update on tracker_commands
  for each row execute function app.tracker_command_task();

-- ================================================================ 14. post-rental charges
-- One charge line of the Check-in assessment, kept in step with its finding: created, changed,
-- or voided when the amount is nil. A line that is already on a statement is left alone.
-- The class (Owner Revenue, company only, pass-through, claim funds), the HST rule and the
-- stage come from the charge catalogue, never from the caller.
create or replace function app.set_assessed_line(p_booking uuid, p_key text, p_charge_type text, p_quantity numeric,
    p_unit_cents bigint, p_amount_cents bigint, p_description text, p_refs jsonb, p_by uuid default null,
    p_incident uuid default null, p_document uuid default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  f fee_types;
  li booking_line_items;
  v_bps integer;
  v_hst bigint;
  v_id uuid;
begin
  select * into f from fee_types where code = p_charge_type;
  if f.code is null then raise exception 'Unknown charge type %', p_charge_type; end if;
  select * into li from booking_line_items
   where booking_id = p_booking and assessment_key = p_key and voided_at is null order by created_at, id limit 1;
  if li.id is not null and li.statement_id is not null then return li.id; end if;
  if coalesce(p_amount_cents, 0) = 0 then
    if li.id is not null then
      update booking_line_items set voided_at = now(), voided_by = p_by, void_reason = 'finding no longer applies' where id = li.id;
    end if;
    return null;
  end if;
  select hst_bps into v_bps from bookings where id = p_booking;
  v_hst := case when f.hst_applies then public.calc_hst(p_amount_cents, v_bps) else 0 end;
  if li.id is null then
    insert into booking_line_items (booking_id, charge_type, description, quantity, unit_amount_cents, amount_cents, hst_applies, hst_cents,
                                    revenue_class, stage, incident_id, supporting_document_id, assessment_key, supporting_refs, created_by)
    values (p_booking, p_charge_type, coalesce(p_description, f.label), p_quantity, p_unit_cents, p_amount_cents, f.hst_applies, v_hst,
            f.revenue_class, f.stage, p_incident, p_document, p_key, p_refs, p_by)
    returning id into v_id;
    return v_id;
  end if;
  update booking_line_items
     set description = coalesce(p_description, f.label), quantity = p_quantity, unit_amount_cents = p_unit_cents,
         amount_cents = p_amount_cents, hst_cents = v_hst, incident_id = p_incident,
         supporting_document_id = coalesce(p_document, supporting_document_id), supporting_refs = p_refs
   where id = li.id;
  return li.id;
end $$;

-- Assess the Check-in of a returned booking: write (or bring up to date) its post-rental charge
-- lines from the findings, each with references to its supporting records. Safe to run again:
-- lines not yet on a statement follow the findings; issued lines never change.
--   mileage overage          (Owner Revenue)   kilometres over the allowance x the booking's rate
--   late return extra days   (Owner Revenue)   each extra day or part day at the booking's daily rate
--   late return fee          (company)         per started hour, capped per 24 hours
--   fuel or recharging       (company)         pump cost plus the markup, or per 10% of battery; plus the service fee
--   cleaning, pet, smoking   (company)         by grade
--   lost key                 (cost: pass-through; fee: company)
--   damage                   under the deductible: at cost (pass-through), loss of use (claim funds)
--                            and the administration fee; at or over it: a claim is opened and the
--                            deductible (claim funds) and the claim administration fee are billed
-- Every rate, cap, fee and threshold is read from the booking, its fee terms, the vehicle's
-- overrides or the defaults. p_findings (all optional): pump_cost_cents, fuel_receipt_document_id,
-- recharge_units, no_fuel_charge, cleaning_grades (array of cleaning, heavy, pet, smoking),
-- cleaning_photo_ids, lost_keys, key_replacement_cost_cents, key_receipt_document_id.
-- Damage lines are an Admin's: for anyone else they are listed as pending and an Admin is asked.
-- Returns the lines, what is still pending, and the totals.
create or replace function app.assess_check_in(p_booking uuid, p_findings jsonb default '{}'::jsonb, p_by uuid default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  f jsonb := coalesce(p_findings, '{}'::jsonb);
  b bookings;
  v vehicles;
  o condition_reports;
  i condition_reports;
  inc incidents;
  cl claims;
  t record;
  l record;
  dp deposits;
  v_refs jsonb;
  v_pending text[] := '{}';
  v_km integer; v_over integer;
  v_short integer; v_units integer; v_pump bigint;
  v_grades text[];
  v_keys integer; v_key_cost bigint;
  v_cost bigint; v_lou bigint; v_repair bigint;
  v_doc uuid;
  v_dref jsonb;
  g record;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if b.status not in ('returned', 'closed') then
    raise exception 'Booking % is %: charges are assessed after the return', b.booking_number, b.status using errcode = '23514';
  end if;
  if p_by is not null and not app.user_runs_finance(p_by) then
    raise exception 'Finance or an Admin prices the findings' using errcode = '42501';
  end if;
  select * into v from vehicles where id = b.vehicle_id;
  select * into o from condition_reports where booking_id = p_booking and kind = 'pickup';
  select * into i from condition_reports where booking_id = p_booking and kind = 'return';
  v_refs := jsonb_build_object('pickup_report_id', o.id, 'return_report_id', i.id);

  if b.booking_type <> 'owner' then
    -- ---- mileage overage
    v_km := app.booking_km_driven(p_booking);
    v_over := greatest(coalesce(v_km, 0) - b.km_allowance_total, 0);
    perform app.set_assessed_line(p_booking, 'mileage_overage', 'mileage_overage', v_over, b.overage_cents_per_km,
        public.calc_mileage_overage(0, coalesce(v_km, 0), b.km_allowance_total, b.overage_cents_per_km),
        format('Mileage overage: %s km driven, %s km included, %s km over', v_km, b.km_allowance_total, v_over),
        v_refs || jsonb_build_object('km_out', b.odometer_out_km, 'km_in', b.odometer_in_km,
          'photo_ids', (select coalesce(jsonb_agg(p.id), '[]'::jsonb) from condition_report_photos p
                         where p.condition_report_id in (o.id, i.id) and p.shot = 'instrument_cluster')), p_by);

    -- ---- late return
    select * into t from app.booking_fee_term(p_booking, 'late_return_fee');
    if t.amount_cents is null or t.percent_bps is null or t.grace_minutes is null then
      raise exception 'The late return fee, its daily cap or its grace period is not set in the fee defaults' using errcode = '23514';
    end if;
    select * into l from public.calc_late_return(coalesce(b.minutes_late, 0), b.daily_rate_cents, t.amount_cents, t.percent_bps, t.grace_minutes);
    perform app.set_assessed_line(p_booking, 'late_return_extra_days', 'late_return_extra_days', l.extra_days, b.daily_rate_cents, l.extra_days_cents,
        format('Late return: %s extra day(s) at the daily rate (%s minutes late)', l.extra_days, b.minutes_late),
        v_refs || jsonb_build_object('return_at', b.return_at, 'checked_in_at', b.checked_in_at, 'minutes_late', b.minutes_late), p_by);
    perform app.set_assessed_line(p_booking, 'late_return_fee', 'late_return_fee', 1, l.late_fee_cents, l.late_fee_cents,
        format('Late return fee: %s minutes late', b.minutes_late),
        v_refs || jsonb_build_object('return_at', b.return_at, 'checked_in_at', b.checked_in_at, 'minutes_late', b.minutes_late), p_by);

    -- ---- fuel or recharging
    v_short := greatest(coalesce(b.fuel_out_pct, 0) - coalesce(b.fuel_in_pct, b.fuel_out_pct, 0), 0);
    v_pump := (f ->> 'pump_cost_cents')::bigint;
    v_units := 0;
    if coalesce((f ->> 'no_fuel_charge')::boolean, false) or v_short = 0 then
      v_pump := 0;
    elsif v.fuel = 'electric' or f ? 'recharge_units' then
      v_units := coalesce((f ->> 'recharge_units')::integer, ceil(v_short / 10.0)::integer);   -- priced per 10% of battery
      v_pump := 0;
    elsif v_pump is null then
      v_pending := v_pending || format('fuel: %s%% short, enter the pump cost from the receipt', v_short);
    end if;
    select * into t from app.booking_fee_term(p_booking, 'fuel');
    if coalesce(v_pump, 0) > 0 and t.percent_bps is null then
      raise exception 'The fuel markup is not set in the fee defaults' using errcode = '23514';
    end if;
    perform app.set_assessed_line(p_booking, 'fuel', 'fuel', 1,
        (select x.fuel_cents from public.calc_fuel_charge(coalesce(v_pump, 0), t.percent_bps, 0) x),
        case when coalesce(v_pump, 0) > 0 then (select x.fuel_cents from public.calc_fuel_charge(v_pump, t.percent_bps, 0) x) else 0 end,
        format('Fuel: %s%% at pickup, %s%% at return; pump cost plus the markup', b.fuel_out_pct, b.fuel_in_pct),
        v_refs || jsonb_build_object('fuel_out_pct', b.fuel_out_pct, 'fuel_in_pct', b.fuel_in_pct, 'pump_cost_cents', v_pump,
                                     'receipt_document_id', f ->> 'fuel_receipt_document_id'),
        p_by, null, (f ->> 'fuel_receipt_document_id')::uuid);
    select * into t from app.booking_fee_term(p_booking, 'recharging');
    perform app.set_assessed_line(p_booking, 'recharging', 'recharging', v_units, t.amount_cents, v_units * coalesce(t.amount_cents, 0),
        format('Recharging: %s%% at pickup, %s%% at return', b.fuel_out_pct, b.fuel_in_pct),
        v_refs || jsonb_build_object('fuel_out_pct', b.fuel_out_pct, 'fuel_in_pct', b.fuel_in_pct), p_by);
    select * into t from app.booking_fee_term(p_booking, 'fuel_service_fee');
    perform app.set_assessed_line(p_booking, 'fuel_service_fee', 'fuel_service_fee', 1, t.amount_cents,
        case when coalesce(v_pump, 0) > 0 or v_units > 0 then coalesce(t.amount_cents, 0) else 0 end,
        null, v_refs || jsonb_build_object('fuel_out_pct', b.fuel_out_pct, 'fuel_in_pct', b.fuel_in_pct), p_by);

    -- ---- cleaning, by grade (odour counts as heavy soiling)
    if f ? 'cleaning_grades' then
      select coalesce(array_agg(x), '{}') into v_grades from jsonb_array_elements_text(f -> 'cleaning_grades') x;
    else
      v_grades := case when i.cleanliness in ('cleaning', 'heavy', 'pet', 'smoking') then array[i.cleanliness] else '{}'::text[] end;
      if coalesce(i.odour, false) and not v_grades && array['heavy', 'smoking'] then
        v_grades := array_remove(v_grades, 'cleaning') || 'heavy'::text;
      end if;
    end if;
    for g in select * from (values ('cleaning', 'cleaning'), ('heavy', 'cleaning_heavy'), ('pet', 'pet_cleaning'), ('smoking', 'smoking')) x(grade, fee) loop
      select * into t from app.booking_fee_term(p_booking, g.fee);
      if g.grade = any (v_grades) and t.amount_cents is null then
        raise exception 'The "%" fee is not set in the fee defaults', g.fee using errcode = '23514';
      end if;
      perform app.set_assessed_line(p_booking, 'cleaning:' || g.grade, g.fee, 1, t.amount_cents,
          case when g.grade = any (v_grades) then t.amount_cents else 0 end, null,
          v_refs || jsonb_build_object('cleanliness', i.cleanliness, 'odour', i.odour, 'photo_ids', coalesce(f -> 'cleaning_photo_ids', '[]'::jsonb)), p_by);
    end loop;

    -- ---- lost key or fob
    v_keys := coalesce((f ->> 'lost_keys')::integer, greatest(coalesce(o.keys_count, 0) - coalesce(i.keys_count, o.keys_count, 0), 0));
    v_key_cost := (f ->> 'key_replacement_cost_cents')::bigint;
    select * into t from app.booking_fee_term(p_booking, 'lost_key_fee');
    if v_keys > 0 and t.amount_cents is null then
      raise exception 'The lost key fee is not set in the fee defaults' using errcode = '23514';
    end if;
    perform app.set_assessed_line(p_booking, 'lost_key_fee', 'lost_key_fee', v_keys, t.amount_cents, v_keys * coalesce(t.amount_cents, 0), null,
        v_refs || jsonb_build_object('keys_out', o.keys_count, 'keys_in', i.keys_count), p_by);
    if v_keys > 0 and v_key_cost is null then
      v_pending := v_pending || format('lost key: %s missing, enter the replacement cost from the invoice', v_keys);
    end if;
    perform app.set_assessed_line(p_booking, 'lost_key_cost', 'lost_key_cost', 1, coalesce(v_key_cost, 0),
        case when v_keys > 0 then coalesce(v_key_cost, 0) else 0 end, null,
        v_refs || jsonb_build_object('keys_out', o.keys_count, 'keys_in', i.keys_count, 'receipt_document_id', f ->> 'key_receipt_document_id'),
        p_by, null, (f ->> 'key_receipt_document_id')::uuid);
  end if;

  -- ---- damage, one incident at a time
  for inc in select * from incidents x
              where x.booking_id = p_booking and x.status <> 'closed'
                and x.kind in ('accident', 'theft', 'vandalism', 'damage_at_return', 'damage_found_later')
              order by x.reported_at, x.id
  loop
    v_cost := app.incident_damage_cost(inc.id);
    if v_cost = 0 then
      v_pending := v_pending || format('damage %s: no estimate or invoice yet; hold back the expected amount from the Deposit', inc.incident_number);
      continue;
    end if;
    if p_by is null or not app.user_is_admin(p_by) then
      v_pending := v_pending || format('damage %s: an Admin prices damage', inc.incident_number);
      perform app.raise_task(p_type => 'price_damage', p_title => format('Booking %s: price the damage of incident %s', b.booking_number, inc.incident_number),
          p_detail => format('Damage cost so far: %s. Any damage line is an Admin''s decision (procedure 5).', app.money_text(v_cost)),
          p_booking => p_booking, p_vehicle => b.vehicle_id, p_related_table => 'incidents', p_related_id => inc.id,
          p_dedupe => 'price_damage:' || inc.id, p_created_by => p_by, p_escalation_reason => 'any damage line');
      continue;
    end if;
    select * into cl from claims where incident_id = inc.id;
    if cl.id is null then
      perform app.open_claim(inc.id, p_by);
      select * into cl from claims where incident_id = inc.id;
    end if;
    select coalesce(sum(amount_cents) filter (where kind = 'loss_of_use'), 0),
           coalesce(sum(amount_cents) filter (where kind in ('repair_estimate', 'repair_invoice', 'towing', 'storage')), 0),
           (array_agg(document_id order by created_at) filter (where document_id is not null))[1]
      into v_lou, v_repair, v_doc
      from incident_costs where incident_id = inc.id and not superseded;
    v_dref := v_refs || jsonb_build_object('incident_id', inc.id, 'incident_number', inc.incident_number, 'claim_id', cl.id,
        'claim_number', cl.claim_number, 'damage_cost_cents', v_cost,
        'cost_ids', (select coalesce(jsonb_agg(c.id), '[]'::jsonb) from incident_costs c where c.incident_id = inc.id and not c.superseded),
        'photo_ids', (select coalesce(jsonb_agg(p.id), '[]'::jsonb) from condition_report_photos p
                        join condition_report_damages dm on dm.id = p.damage_id where dm.incident_id = inc.id));

    if b.booking_type = 'owner' then
      -- an Owner Booking: under the deductible the Owner repairs it; a claim bills the Owner the deductible
      if cl.path = 'fleet_policy' and cl.deductible_billed_cents > 0 and not exists (
           select 1 from owner_deductions od where od.booking_id = p_booking and od.kind = 'owner_booking_deductible'
              and od.description like '%' || cl.claim_number || '%') then
        insert into owner_deductions (owner_id, vehicle_id, kind, description, amount_cents, incurred_on, booking_id, created_by)
        values (b.owner_id, cl.vehicle_id, 'owner_booking_deductible',
                format('Booking %s, claim %s: deductible on an Owner Booking', b.booking_number, cl.claim_number),
                cl.deductible_billed_cents, app.local_date(inc.reported_at), p_booking, p_by);
      end if;
      continue;
    end if;

    if cl.path = 'fleet_policy' and not cl.denied_for_renter_breach then
      perform app.set_assessed_line(p_booking, 'damage:' || inc.id || ':deductible', 'deductible', 1, cl.deductible_billed_cents, cl.deductible_billed_cents,
          format('Deductible, incident %s (claim %s)', inc.incident_number, cl.claim_number), v_dref, p_by, inc.id, v_doc);
      perform app.set_assessed_line(p_booking, 'damage:' || inc.id || ':admin_claim', 'admin_fee_claim', 1, cl.admin_fee_cents, cl.admin_fee_cents,
          format('Administration fee, fleet policy claim %s', cl.claim_number), v_dref, p_by, inc.id, v_doc);
      perform app.set_assessed_line(p_booking, 'damage:' || inc.id || ':cost', 'damage_at_cost', 1, 0, 0, null, v_dref, p_by, inc.id);
      perform app.set_assessed_line(p_booking, 'damage:' || inc.id || ':loss_of_use', 'loss_of_use', 1, 0, 0, null, v_dref, p_by, inc.id);
      perform app.set_assessed_line(p_booking, 'damage:' || inc.id || ':admin_other', 'admin_fee_other', 1, 0, 0, null, v_dref, p_by, inc.id);
    else
      -- at cost (under the deductible), or the full cost when the claim was denied for the renter's breach
      select * into t from app.booking_fee_term(p_booking, 'admin_fee_other');
      perform app.set_assessed_line(p_booking, 'damage:' || inc.id || ':cost', 'damage_at_cost', 1, v_repair, v_repair,
          format('Damage at cost, incident %s: repair, towing and storage as invoiced', inc.incident_number), v_dref, p_by, inc.id, v_doc);
      perform app.set_assessed_line(p_booking, 'damage:' || inc.id || ':loss_of_use', 'loss_of_use',
          coalesce((select sum(days) from incident_costs where incident_id = inc.id and kind = 'loss_of_use' and not superseded), 1),
          b.daily_rate_cents, v_lou, format('Loss of use, incident %s', inc.incident_number), v_dref, p_by, inc.id, v_doc);
      perform app.set_assessed_line(p_booking, 'damage:' || inc.id || ':admin_other', 'admin_fee_other', 1,
          coalesce(nullif(cl.admin_fee_cents, 0), t.amount_cents), coalesce(nullif(cl.admin_fee_cents, 0), t.amount_cents, 0),
          format('Administration fee, incident %s', inc.incident_number), v_dref, p_by, inc.id, v_doc);
      perform app.set_assessed_line(p_booking, 'damage:' || inc.id || ':deductible', 'deductible', 1, 0, 0, null, v_dref, p_by, inc.id);
      perform app.set_assessed_line(p_booking, 'damage:' || inc.id || ':admin_claim', 'admin_fee_claim', 1, 0, 0, null, v_dref, p_by, inc.id);
      update incidents set status = 'billed' where id = inc.id and status in ('open', 'assessing');
    end if;
    perform app.resolve_tasks(array['price_damage'], p_booking, p_by, 'Damage priced');
  end loop;

  perform app.compute_booking_split(p_booking);
  select * into dp from deposits where booking_id = p_booking;
  return jsonb_build_object(
    'booking_id', p_booking, 'booking_number', b.booking_number,
    'lines', coalesce((select jsonb_agg(jsonb_build_object('id', li.id, 'key', li.assessment_key, 'charge_type', li.charge_type,
                 'description', li.description, 'quantity', li.quantity, 'unit_amount_cents', li.unit_amount_cents,
                 'amount_cents', li.amount_cents, 'hst_cents', li.hst_cents, 'belongs_to', li.revenue_class, 'stage', li.stage,
                 'issued', li.statement_id is not null, 'supporting_refs', li.supporting_refs) order by ft.sort_order, li.created_at, li.id)
               from booking_line_items li join fee_types ft on ft.code = li.charge_type
              where li.booking_id = p_booking and li.voided_at is null and li.charged_to_renter
                and li.stage in ('check_in', 'after_return')), '[]'::jsonb),
    'pending', to_jsonb(v_pending),
    'totals', (select jsonb_build_object(
                 'charges_cents', coalesce(sum(li.amount_cents), 0), 'hst_cents', coalesce(sum(li.hst_cents), 0),
                 'total_cents', coalesce(sum(li.amount_cents + li.hst_cents), 0),
                 'owner_revenue_cents', coalesce(sum(li.amount_cents) filter (where li.revenue_class = 'owner_revenue'), 0),
                 'company_only_cents', coalesce(sum(li.amount_cents) filter (where li.revenue_class = 'company_only'), 0),
                 'pass_through_cents', coalesce(sum(li.amount_cents) filter (where li.revenue_class = 'pass_through'), 0),
                 'claim_funds_cents', coalesce(sum(li.amount_cents) filter (where li.revenue_class = 'claim_funds'), 0))
               from booking_line_items li
              where li.booking_id = p_booking and li.voided_at is null and li.charged_to_renter and li.stage in ('check_in', 'after_return')),
    'deposit', case when dp.id is null then null else jsonb_build_object('amount_cents', dp.amount_cents, 'applied_cents', dp.applied_cents,
                 'held_back_cents', dp.held_back_cents, 'released_cents', dp.released_cents,
                 'available_cents', dp.amount_cents - dp.applied_cents - dp.released_cents, 'release_due_on', dp.release_due_on) end);
end $$;

-- ---------------------------------------------------------------- the renter's statement
-- Issue the statement for the post-rental lines that are not on one yet: the Check-in statement
-- the first time (even with no charges), a later-charge statement after that. Every line must
-- carry its supporting record. Damage lines need an Admin. Money does not move here: the
-- Deposit and the card are handled by app.settle_deposit(). Returns the statement's id.
create or replace function app.issue_booking_statement(p_booking uuid, p_by uuid default null, p_now timestamptz default now())
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_kind text;
  v_id uuid;
  v_n integer;
  v_charges bigint; v_hst bigint;
  v_bad text;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if b.status not in ('returned', 'closed') then
    raise exception 'Booking % is %: a statement is issued after the return', b.booking_number, b.status using errcode = '23514';
  end if;
  if p_by is not null and not app.user_runs_finance(p_by) then
    raise exception 'Finance or an Admin issues a statement' using errcode = '42501';
  end if;
  v_kind := case when exists (select 1 from booking_statements s where s.booking_id = p_booking and s.kind = 'check_in')
                 then 'later_charge' else 'check_in' end;
  if v_kind = 'check_in' and not exists (
       select 1 from condition_reports c where c.booking_id = p_booking and c.kind = 'return' and c.reviewed_at is not null) then
    raise exception 'The return of booking % has not been reviewed yet: Fleet confirms the findings first', b.booking_number using errcode = '23514';
  end if;

  select count(*), coalesce(sum(li.amount_cents), 0), coalesce(sum(li.hst_cents), 0),
         string_agg(li.charge_type, ', ') filter (where li.supporting_document_id is null
                                                    and (li.supporting_refs is null or li.supporting_refs = '{}'::jsonb))
    into v_n, v_charges, v_hst, v_bad
    from booking_line_items li
   where li.booking_id = p_booking and li.statement_id is null and li.voided_at is null and li.charged_to_renter
     and li.stage in ('check_in', 'after_return', 'on_decline');
  if v_kind = 'later_charge' and v_n = 0 then
    raise exception 'There is no new charge to put on a statement for booking %', b.booking_number using errcode = '23514';
  end if;
  if v_bad is not null then
    raise exception 'A charge cannot be issued without its supporting record: %', v_bad using errcode = '23514';
  end if;
  if (p_by is null or not app.user_is_admin(p_by)) and exists (
       select 1 from booking_line_items li join fee_types ft on ft.code = li.charge_type
        where li.booking_id = p_booking and li.statement_id is null and li.voided_at is null and ft.family = 'damage') then
    raise exception 'A statement with a damage line needs an Admin' using errcode = '42501';
  end if;

  insert into booking_statements (booking_id, statement_number, kind, issued_at, charges_cents, hst_cents, interest_starts_on, created_by)
  values (p_booking, 'RS-' || nextval('renter_statement_number_seq'), v_kind, p_now, v_charges, v_hst,
          app.local_date(p_now) + (app.settings(app.local_date(p_now))).statement_interest_days, p_by)
  returning id into v_id;
  update booking_line_items li set statement_id = v_id
   where li.booking_id = p_booking and li.statement_id is null and li.voided_at is null and li.charged_to_renter
     and li.stage in ('check_in', 'after_return', 'on_decline');
  perform app.resolve_tasks(array['price_findings'], p_booking, p_by, 'Statement issued');
  return v_id;
end $$;

-- ---------------------------------------------------------------- the Deposit after the return
-- Take the issued, unpaid Charges from the Deposit, hold back what is expected on an open
-- claim, toll or ticket, release the rest, and charge the Card on File for any shortfall. The
-- Deposit does not cap what the renter owes.
--   p_plan: hold_back_cents, hold_back_reason, hold_back_until (a date, at most the hold-back
--   limit after Check-in). With no hold_back_cents the amount already held back stays held.
-- Money at the processor moves by server action: this function records what must happen as
-- payments in status 'pending' (capture, release or refund of the Deposit; charge of the card)
-- and returns them under "server_actions".
-- Approval (docs/permissions.md): a release needs an Admin, or a Finance assistant inside their
-- Single Limit when nothing is held back. Otherwise nothing moves: the proposal goes to an Admin
-- as a task, and the Admin runs this function with the same plan, which approves it.
-- Safe to run again: it only ever acts on what is still unpaid or unreleased.
create or replace function app.settle_deposit(p_booking uuid, p_by uuid, p_plan jsonb default '{}'::jsonb, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  pl jsonb := coalesce(p_plan, '{}'::jsonb);
  b bookings;
  d deposits;
  v_set program_settings := app.settings();
  li record;
  v_available bigint := 0;
  v_due bigint := 0;
  v_apply bigint := 0;
  v_hold bigint := 0;
  v_old_hold bigint := 0;
  v_release bigint := 0;
  v_shortfall bigint := 0;
  v_left bigint;
  v_part bigint;
  v_open bigint;
  v_dep_pay uuid;
  v_card_pay uuid;
  v_rel_pay uuid;
  v_actions jsonb := '[]'::jsonb;
  v_may_release boolean;
  v_awaiting boolean := false;
  v_until date;
  v_max_until date;
  v_captured boolean;
  v_statement uuid;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if b.status not in ('returned', 'closed') then
    raise exception 'Booking % is %: the Deposit is settled after the return', b.booking_number, b.status using errcode = '23514';
  end if;
  if not app.user_runs_finance(p_by) then
    raise exception 'Finance or an Admin settles a Deposit' using errcode = '42501';
  end if;
  select id into v_statement from booking_statements where booking_id = p_booking and kind = 'check_in';
  if v_statement is null then
    raise exception 'Issue the Check-in statement of booking % before settling its Deposit', b.booking_number using errcode = '23514';
  end if;
  select * into d from deposits where booking_id = p_booking for update;
  if d.id is not null and d.status in ('pending', 'failed', 'carried_forward') then
    d := null;     -- nothing was taken on this booking, or it moved to the renewal
  end if;

  -- what is owed: issued lines with no payment yet, less what the Deposit already covered
  select coalesce(sum(x.open_cents), 0) into v_due from (
    select l2.amount_cents + l2.hst_cents - coalesce((select sum(e.amount_cents) from deposit_events e
                                                     where e.line_item_id = l2.id and e.kind = 'applied'), 0) as open_cents
      from booking_line_items l2
     where l2.booking_id = p_booking and l2.statement_id is not null and l2.payment_id is null and l2.voided_at is null and l2.charged_to_renter) x
   where x.open_cents > 0;

  if d.id is not null then
    v_old_hold := d.held_back_cents;
    v_available := d.amount_cents - d.applied_cents - d.released_cents;
    v_apply := least(v_due, v_available);
    v_hold := least(coalesce((pl ->> 'hold_back_cents')::bigint, v_old_hold), v_available - v_apply);
    if v_hold < 0 then raise exception 'A hold-back cannot be negative' using errcode = '22023'; end if;
    v_max_until := app.local_date(b.checked_in_at) + v_set.deposit_holdback_days;
    v_until := coalesce((pl ->> 'hold_back_until')::date, d.held_back_until, v_max_until);
    if v_hold > 0 then
      if coalesce(pl ->> 'hold_back_reason', d.held_back_reason) is null then
        raise exception 'A hold-back needs its reason: the pending claim, toll or ticket' using errcode = '23514';
      end if;
      if v_until > v_max_until then
        raise exception 'An amount may be held back for at most % days after Check-in (until %)', v_set.deposit_holdback_days, v_max_until
          using errcode = '23514';
      end if;
    end if;
    v_release := v_available - v_apply - v_hold;
  end if;
  v_shortfall := v_due - v_apply;

  -- may this person release this amount? (the table's own guard checks the same)
  v_may_release := v_release = 0
                or app.user_is_admin(p_by)
                or (v_hold = 0 and app.may_release_payment(p_by, v_release, true));
  if not v_may_release then
    -- Nothing moves until an Admin approves: a card hold can be captured only once, so what is
    -- applied, held back and released is decided in one step. The plan goes to the Admin.
    perform app.raise_task(p_type => 'approve_deposit_release',
        p_title => format('Booking %s: approve the release of %s of the Deposit', b.booking_number, app.money_text(v_release)),
        p_detail => format('Proposed by Finance: apply %s to Charges, hold back %s%s, release %s, charge the card %s.',
                           app.money_text(v_apply), app.money_text(v_hold), coalesce(' (' || coalesce(pl ->> 'hold_back_reason', d.held_back_reason) || ')', ''),
                           app.money_text(v_release), app.money_text(v_shortfall)),
        p_booking => p_booking, p_vehicle => b.vehicle_id, p_renter => b.renter_id, p_related_table => 'deposits', p_related_id => d.id,
        p_due_at => app.local_midnight(coalesce(d.release_due_on, app.local_date(p_now)) + 1),
        p_dedupe => 'approve_deposit_release:' || d.id, p_created_by => p_by, p_escalation_reason => 'deposit release needs an Admin');
    perform app.emit_event('staff_approval_needed', 'deposit', d.id,
      jsonb_build_object('approval_type', 'deposit_release', 'approval_subject', 'Booking ' || b.booking_number, 'amount_cents', v_release,
                         'approval_reason', case when v_hold > 0 then 'a deposit release with a hold-back' else 'above the assistant''s limit' end,
                         'approval_due', d.release_due_on, 'requested_by', p_by, 'requested_at', p_now, 'booking_id', p_booking, 'plan', pl),
      'staff_approval_needed:' || d.id || ':release:' || v_release || ':' || v_hold);
    return jsonb_build_object('booking_id', p_booking, 'deposit_id', d.id, 'status', 'awaiting_approval', 'charges_due_cents', v_due,
        'deposit_available_cents', v_available, 'applied_cents', 0, 'held_back_cents', v_old_hold, 'released_cents', 0,
        'charged_to_card_cents', 0, 'release_due_on', d.release_due_on,
        'proposed', jsonb_build_object('applied_cents', v_apply, 'held_back_cents', v_hold, 'released_cents', v_release,
                                       'charged_to_card_cents', v_shortfall, 'plan', pl),
        'overdue', d.release_due_on is not null and app.local_date(p_now) > d.release_due_on, 'booking_closed', false, 'server_actions', '[]'::jsonb);
  end if;

  -- ---- the Deposit's own money: capture what is applied or held back (a card hold), or use the charge already taken
  v_captured := d.id is not null and (d.method <> 'card_hold' or d.status = 'captured');
  if d.id is not null and v_apply > 0 then
    if v_captured then
      -- already collected: the charge itself, or the capture made at the first settlement
      v_dep_pay := case when d.method = 'card_hold'
                        then coalesce((select p.id from payments p where p.booking_id = p_booking and p.purpose = 'deposit' and p.kind = 'capture'
                                        order by p.created_at desc limit 1), d.hold_payment_id)
                        else d.hold_payment_id end;
    else
      insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, parent_payment_id, payment_method_id, created_by)
      values (p_booking, b.renter_id, 'deposit', 'capture', 'card', v_apply + v_hold, 'pending', d.hold_payment_id, b.card_on_file_id, p_by)
      returning id into v_dep_pay;
      v_actions := v_actions || jsonb_build_object('action', 'capture_deposit', 'payment_id', v_dep_pay, 'amount_cents', v_apply + v_hold,
                                                   'hold_payment_id', d.hold_payment_id);
    end if;
  elsif d.id is not null and v_hold > v_old_hold and not v_captured then
    insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, parent_payment_id, payment_method_id, created_by)
    values (p_booking, b.renter_id, 'deposit', 'capture', 'card', v_hold, 'pending', d.hold_payment_id, b.card_on_file_id, p_by)
    returning id into v_dep_pay;
    v_actions := v_actions || jsonb_build_object('action', 'capture_deposit', 'payment_id', v_dep_pay, 'amount_cents', v_hold,
                                                 'hold_payment_id', d.hold_payment_id);
  end if;

  -- ---- the card: one pending charge for everything the Deposit does not cover
  if v_shortfall > 0 then
    if b.card_on_file_id is null then
      raise exception 'Booking % has no Card on File to charge the balance of % cents to', b.booking_number, v_shortfall using errcode = '23514';
    end if;
    insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, payment_method_id, created_by)
    values (p_booking, b.renter_id, 'post_rental', 'charge', 'card', v_shortfall, 'pending', b.card_on_file_id, p_by)
    returning id into v_card_pay;
    v_actions := v_actions || jsonb_build_object('action', 'charge_card', 'payment_id', v_card_pay, 'amount_cents', v_shortfall,
                                                 'payment_method_id', b.card_on_file_id);
  end if;

  -- ---- line by line, in catalogue order: the Deposit first, then the card
  v_left := v_apply;
  for li in
    select l2.id, l2.statement_id,
           l2.amount_cents + l2.hst_cents - coalesce((select sum(e.amount_cents) from deposit_events e
                                                    where e.line_item_id = l2.id and e.kind = 'applied'), 0) as open_cents
      from booking_line_items l2 join fee_types ft on ft.code = l2.charge_type
     where l2.booking_id = p_booking and l2.statement_id is not null and l2.payment_id is null and l2.voided_at is null and l2.charged_to_renter
     order by ft.sort_order, l2.created_at, l2.id
  loop
    continue when li.open_cents <= 0;
    v_part := least(li.open_cents, v_left);
    v_open := li.open_cents - v_part;
    if v_part > 0 then
      insert into deposit_events (deposit_id, kind, amount_cents, line_item_id, payment_id, created_by)
      values (d.id, 'applied', v_part, li.id, v_dep_pay, p_by);
      v_left := v_left - v_part;
      update booking_statements set deposit_applied_cents = deposit_applied_cents + v_part where id = li.statement_id;
    end if;
    if v_open > 0 then
      update booking_statements set charged_to_card_cents = charged_to_card_cents + v_open where id = li.statement_id;
    end if;
    update booking_line_items set payment_id = case when v_open > 0 then v_card_pay else v_dep_pay end where id = li.id;
  end loop;

  -- ---- the Deposit row: applied, held back, released
  if d.id is not null then
    if v_hold <> v_old_hold or v_apply > 0 then
      if v_hold > 0 and v_hold <> v_old_hold then
        insert into deposit_events (deposit_id, kind, amount_cents, payment_id, note, created_by)
        values (d.id, 'held_back', v_hold, v_dep_pay, coalesce(pl ->> 'hold_back_reason', d.held_back_reason), p_by);
      end if;
    end if;
    if not v_captured and v_dep_pay is not null then
      insert into deposit_events (deposit_id, kind, amount_cents, payment_id, created_by)
      values (d.id, 'captured', (select amount_cents from payments where id = v_dep_pay), v_dep_pay, p_by);
    end if;
    if v_release > 0 and not v_awaiting then
      insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, parent_payment_id, payment_method_id, created_by)
      values (p_booking, b.renter_id, 'deposit', case when v_captured then 'refund' else 'release' end, 'card', v_release, 'pending',
              d.hold_payment_id, b.card_on_file_id, p_by)
      returning id into v_rel_pay;
      v_actions := v_actions || jsonb_build_object('action', case when v_captured then 'refund_deposit' else 'release_hold' end,
                                                   'payment_id', v_rel_pay, 'amount_cents', v_release, 'hold_payment_id', d.hold_payment_id);
      insert into deposit_events (deposit_id, kind, amount_cents, payment_id, created_by) values (d.id, 'released', v_release, v_rel_pay, p_by);
    end if;
    update deposits dp
       set applied_cents = dp.applied_cents + v_apply,
           held_back_cents = v_hold,
           held_back_reason = case when v_hold > 0 then coalesce(pl ->> 'hold_back_reason', dp.held_back_reason) end,
           held_back_until = case when v_hold > 0 then v_until end,
           captured_cents = case when v_captured then dp.captured_cents
                                 else dp.captured_cents + coalesce((select amount_cents from payments where id = v_dep_pay), 0) end,
           released_cents = dp.released_cents + case when v_awaiting then 0 else v_release end,
           release_approved_by = case when v_release > 0 and not v_awaiting then p_by else dp.release_approved_by end,
           released_at = case when v_release > 0 and not v_awaiting then p_now else dp.released_at end,
           status = case when dp.applied_cents + v_apply + dp.released_cents + case when v_awaiting then 0 else v_release end = dp.amount_cents then 'settled'
                         when not v_captured and v_dep_pay is not null then 'captured'
                         else dp.status end
     where dp.id = d.id;
    update booking_statements
       set held_back_cents = v_hold, deposit_returned_cents = deposit_returned_cents + case when v_awaiting then 0 else v_release end
     where id = v_statement;

    -- a hold-back that has now been applied or released: the renter is told
    if v_old_hold > 0 and v_hold < v_old_hold and not v_awaiting then
      perform app.emit_event('renter_deposit_released', 'deposit', d.id,
        jsonb_build_object('booking_id', p_booking, 'booking_number', b.booking_number, 'renter_id', b.renter_id,
                           'deposit_held_back_cents', v_old_hold, 'holdback_applied_cents', least(v_apply, v_old_hold - v_hold),
                           'release_amount_cents', v_release, 'holdback_reason', d.held_back_reason, 'still_held_back_cents', v_hold),
        'renter_deposit_released:' || d.id || ':' || (d.applied_cents + v_apply) || '-' || (d.released_cents + v_release));
    end if;
  end if;

  perform app.resolve_tasks(array['approve_deposit_release', 'release_deposit'], p_booking, p_by, 'Deposit settled');
  if v_hold = 0 then
    perform app.resolve_tasks(array['settle_holdback'], p_booking, p_by, 'Hold-back settled');
  end if;

  -- statement issued, Deposit settled: the booking is closed (a balance on the card is chased after closing)
  if b.status = 'returned' and not v_awaiting and v_hold = 0 then
    update bookings set status = 'closed' where id = p_booking;
  else
    perform app.compute_booking_split(p_booking);
  end if;

  return jsonb_build_object('booking_id', p_booking, 'deposit_id', d.id, 'charges_due_cents', v_due,
      'deposit_available_cents', v_available, 'applied_cents', v_apply, 'held_back_cents', v_hold,
      'status', 'settled', 'released_cents', v_release,
      'charged_to_card_cents', v_shortfall, 'release_due_on', d.release_due_on,
      'overdue', d.release_due_on is not null and app.local_date(p_now) > d.release_due_on,
      'booking_closed', b.status = 'returned' and not v_awaiting and v_hold = 0, 'server_actions', v_actions);
end $$;

-- The processor's answer to one of the pending payments above. Success: the payment is
-- recorded as paid, claim money goes on the claim's ledger, the split is worked out again and a
-- statement whose lines are all paid is marked paid. Failure: the decline is counted and the
-- next retry is set (1, 3 and 7 days after the first decline); the payment-retries job takes it
-- from there, and adds the declined-payment fee.
create or replace function app.post_rental_payment_result(p_payment uuid, p_succeeded boolean, p_decline_code text default null,
                                                          p_now timestamptz default now())
returns void language plpgsql security definer set search_path = public, app as $$
declare
  p payments;
  li record;
begin
  select * into p from payments where id = p_payment for update;
  if p.id is null then raise exception 'Payment % not found', p_payment; end if;
  if p.status = 'succeeded' then return; end if;
  if not p_succeeded then
    update payments
       set status = 'failed', decline_count = decline_count + 1, last_decline_code = p_decline_code, processed_at = p_now,
           next_retry_at = public.calc_payment_retry_at(
                             coalesce((select min(a.attempted_at) from payment_attempts a where a.payment_id = p_payment and a.outcome = 'declined'), p_now),
                             decline_count)
     where id = p_payment;
    insert into payment_attempts (payment_id, attempt_no, attempted_at, outcome, decline_code)
    values (p_payment, p.decline_count + 1, p_now, 'declined', p_decline_code);
    return;
  end if;
  update payments set status = 'succeeded', processed_at = p_now, next_retry_at = null where id = p_payment;
  -- claim money received from the renter goes on the claim's own ledger
  for li in select l2.id, l2.charge_type, l2.amount_cents, c.id as claim_id
              from booking_line_items l2 join claims c on c.incident_id = l2.incident_id
             where l2.payment_id = p_payment and l2.voided_at is null and l2.amount_cents > 0
               and l2.charge_type in ('deductible', 'damage_at_cost', 'loss_of_use')
               and not exists (select 1 from claim_ledger_entries e where e.line_item_id = l2.id)
  loop
    insert into claim_ledger_entries (claim_id, entry_date, kind, amount_cents, description, payment_id, line_item_id)
    values (li.claim_id, app.local_date(p_now), case when li.charge_type = 'deductible' then 'renter_deductible' else 'renter_at_cost' end,
            li.amount_cents, 'Paid by the renter', p_payment, li.id);
  end loop;
  update booking_statements s set paid_at = p_now
   where s.booking_id = p.booking_id and s.paid_at is null
     and exists (select 1 from booking_line_items l2 where l2.statement_id = s.id and l2.payment_id = p_payment)
     and not exists (select 1 from booking_line_items l2 left join payments q on q.id = l2.payment_id
                      where l2.statement_id = s.id and l2.voided_at is null and (q.id is null or q.status <> 'succeeded'));
  if p.booking_id is not null then
    perform app.compute_booking_split(p.booking_id);
  end if;
end $$;

-- ================================================================ 15. what a booking's status sets in motion
-- Confirmed: the fee terms are written on the booking, the delivery and pickup jobs are created
-- for a booking with delivery, Fleet is asked to schedule the handover and customer service to
-- verify the drivers. On rent, returned, closed, cancelled: the tasks and jobs that no longer
-- apply are closed, and the next ones are raised. This trigger creates jobs and tasks, not events.
create or replace function app.ops_booking_status_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_set program_settings := app.settings();
  v_first text;
begin
  if new.status is not distinct from old.status then return null; end if;

  if new.status = 'confirmed' then
    perform app.snapshot_booking_fee_terms(new.id);
    if new.pickup_method = 'delivered' and not exists (
         select 1 from field_jobs j where j.booking_id = new.id and j.kind = 'delivery' and j.status <> 'cancelled') then
      insert into field_jobs (kind, booking_id, vehicle_id, scheduled_at, place, instructions, auto_created)
      values ('delivery', new.id, new.vehicle_id, new.pickup_at, new.pickup_place, 'Deliver the car and hand it over (procedure 3)', true);
    end if;
    if new.return_method = 'picked_up' and not exists (
         select 1 from field_jobs j where j.booking_id = new.id and j.kind = 'pickup_from_renter' and j.status <> 'cancelled') then
      insert into field_jobs (kind, booking_id, vehicle_id, scheduled_at, place, instructions, auto_created)
      values ('pickup_from_renter', new.id, new.vehicle_id, new.return_at, new.return_place, 'Collect the car and check it in (procedure 4)', true);
    end if;
    perform app.raise_task(p_type => 'schedule_handover',
        p_title => format('Booking %s: schedule the handover', new.booking_number),
        p_detail => case when new.pickup_method = 'delivered' then 'A delivery job was created: assign it to field staff.'
                         else 'The renter collects the car: create the handover job and assign it.' end,
        p_booking => new.id, p_vehicle => new.vehicle_id,
        p_due_at => greatest(new.pickup_at - make_interval(hours => v_set.handover_schedule_hours), now()),
        p_dedupe => 'schedule_handover:' || new.id);
    perform app.raise_task(p_type => 'offer_approved_paid',
        p_title => format('Booking %s confirmed: verify the drivers%s', new.booking_number,
                          case when new.booking_type = 'owner' then '' else ' and the coverage' end),
        p_booking => new.id, p_vehicle => new.vehicle_id, p_renter => new.renter_id,
        p_due_at => greatest(new.pickup_at - make_interval(hours => v_set.verification_due_hours), now()),
        p_dedupe => 'offer_approved_paid:' || new.id);
  elsif new.status = 'on_rent' then
    perform app.resolve_tasks(array['schedule_handover', 'take_deposit', 'offer_approved_paid', 'verify_renter', 'chase_verification',
                                    'handover_blocked', 'insurer_provisional'], new.id, null, 'Handed over');
  elsif new.status = 'returned' then
    perform app.resolve_tasks(array['late_return', 'late_return_admin'], new.id, null, 'Returned');
    perform app.raise_task(p_type => 'schedule_detail', p_title => format('Booking %s returned: schedule the detail', new.booking_number),
        p_booking => new.id, p_vehicle => new.vehicle_id, p_dedupe => 'schedule_detail:' || new.id);
  elsif new.status = 'closed' then
    perform app.resolve_tasks(array['price_findings', 'release_deposit'], new.id, null, 'Booking closed');
  elsif new.status in ('cancelled', 'no_show', 'declined', 'expired') then
    update field_jobs set status = 'cancelled', cancel_reason = 'Booking ' || new.status
     where booking_id = new.id and status in ('scheduled', 'acknowledged');
    perform app.resolve_tasks(array['schedule_handover', 'take_deposit', 'offer_approved_paid', 'verify_renter', 'chase_verification',
                                    'chase_offer', 'job_unacknowledged', 'insurer_provisional'], new.id, null, 'Booking ' || new.status, true);
  end if;
  return null;
end $$;
create trigger bookings_ops_status_after after update of status on bookings
  for each row execute function app.ops_booking_status_after();

-- ================================================================ 16. the other task-creating triggers
-- One function for the tables whose new rows or status changes need a person. Each branch
-- names its queue through the task's rule. Dedupe keys stop a second open task for one record.
create or replace function app.ops_task_trigger() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v vehicles;
  o owners;
  v_set program_settings := app.settings();
  v_renter uuid;
  v_booking uuid;
  v_due timestamptz;
begin
  if tg_table_name = 'booking_cancellations' then
    -- procedure 7: Finance refunds (the percentage of the total paid, and any Deposit in full)
    if new.refund_cents > 0 or new.deposit_returned_cents > 0 then
      select * into b from bookings where id = new.booking_id;
      perform app.raise_task(p_type => 'refund_cancellation', p_title => format('Booking %s cancelled: refund %s', b.booking_number, app.money_text(new.refund_cents)),
          p_detail => format('Tier %s. Deposit to return: %s.', new.tier, app.money_text(new.deposit_returned_cents)),
          p_booking => new.booking_id, p_vehicle => b.vehicle_id, p_renter => b.renter_id, p_dedupe => 'refund_cancellation:' || new.booking_id);
    end if;

  elsif tg_table_name = 'booking_extensions' then
    -- procedure 6: confirmed in writing and paid before the current return time
    if new.status = 'requested' then
      select * into b from bookings where id = new.booking_id;
      perform app.raise_task(p_type => 'review_extension', p_title => format('Booking %s: extension requested', b.booking_number),
          p_detail => format('New return %s (Toronto). Check the calendar, unpaid charges and coverage to the new date.',
                             to_char(new.new_return_at at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI')),
          p_booking => new.booking_id, p_vehicle => b.vehicle_id, p_renter => b.renter_id,
          p_related_table => 'booking_extensions', p_related_id => new.id, p_due_at => new.previous_return_at,
          p_dedupe => 'review_extension:' || new.id);
    end if;

  elsif tg_table_name in ('identity_verifications', 'coverage_proofs') then
    -- procedure 2: documents to review, due before pickup
    if tg_table_name = 'identity_verifications' then
      if new.status <> 'pending' or (tg_op = 'UPDATE' and old.status = 'pending') then return null; end if;
      v_booking := new.booking_id;
      select renter_id into v_renter from drivers where id = new.driver_id;
    else
      if new.status <> 'submitted' or (tg_op = 'UPDATE' and old.status = 'submitted') then return null; end if;
      v_booking := new.booking_id;
    end if;
    if v_booking is not null then
      select * into b from bookings where id = v_booking;
      v_renter := coalesce(v_renter, b.renter_id);
      v_due := greatest(b.pickup_at - make_interval(hours => v_set.verification_due_hours), now());
    end if;
    perform app.raise_task(p_type => 'verify_renter',
        p_title => case when b.id is not null then format('Booking %s: identity documents or coverage proof to review', b.booking_number) end,
        p_booking => v_booking, p_vehicle => b.vehicle_id, p_renter => v_renter,
        p_due_at => coalesce(v_due, app.task_due('business_days', 1)),
        p_dedupe => 'verify_renter:' || coalesce(v_booking::text, new.id::text));

  elsif tg_table_name = 'vehicle_onboardings' then
    select * into v from vehicles where id = new.vehicle_id;
    if tg_op = 'INSERT' then
      if new.status = 'intake' then
        perform app.raise_task(p_type => 'owner_intake', p_title => format('Owner application: %s %s %s', v.year, v.make, v.model),
            p_vehicle => v.id, p_owner => v.owner_id, p_related_table => 'vehicle_onboardings', p_related_id => new.id,
            p_dedupe => 'owner_intake:' || new.id);
      end if;
    elsif new.status is distinct from old.status then
      if new.status = 'upfront_paid' or (new.status = 'registry_booked' and old.status = 'documents_signed') then
        if new.status = 'upfront_paid' then
          perform app.raise_task(p_type => 'book_registry', p_title => format('Book the registry visit: %s %s %s', v.year, v.make, v.model),
              p_vehicle => v.id, p_owner => v.owner_id, p_related_table => 'vehicle_onboardings', p_related_id => new.id,
              p_due_at => coalesce(app.local_midnight(new.safety_certificate_expires_on),
                                   now() + make_interval(days => v_set.safety_certificate_days)),
              p_dedupe => 'book_registry:' || new.id);
        end if;
      elsif new.status = 'enrolled' then
        perform app.raise_task(p_type => 'list_vehicle', p_title => format('List the new vehicle: %s %s %s', v.year, v.make, v.model),
            p_vehicle => v.id, p_owner => v.owner_id, p_related_table => 'vehicle_onboardings', p_related_id => new.id,
            p_dedupe => 'list_vehicle:' || new.id);
      end if;
    end if;

  elsif tg_table_name = 'owner_invoices' then
    if tg_op = 'UPDATE' and new.status is not distinct from old.status then return null; end if;
    if new.kind = 'upfront' and new.status = 'issued' then
      perform app.raise_task(p_type => 'collect_upfront', p_title => format('Collect upfront invoice %s', new.invoice_number),
          p_vehicle => new.vehicle_id, p_owner => new.owner_id, p_related_table => 'owner_invoices', p_related_id => new.id,
          p_dedupe => 'collect_upfront:' || new.id);
    elsif new.status = 'failed' then
      perform app.raise_task(p_type => 'debit_failed', p_title => format('Owner debit failed: invoice %s', new.invoice_number),
          p_vehicle => new.vehicle_id, p_owner => new.owner_id, p_related_table => 'owner_invoices', p_related_id => new.id,
          p_dedupe => 'debit_failed:' || new.id);
    elsif new.status = 'in_arrears' then
      perform app.raise_task(p_type => 'arrears', p_title => format('Owner invoice %s is in arrears', new.invoice_number),
          p_vehicle => new.vehicle_id, p_owner => new.owner_id, p_related_table => 'owner_invoices', p_related_id => new.id,
          p_dedupe => 'arrears:' || new.id);
    end if;

  elsif tg_table_name = 'owner_statements' then
    -- procedure 14: the drafts are reviewed before the payout date (one task per statement month)
    if new.status = 'draft' then
      perform app.raise_task(p_type => 'review_statements',
          p_title => format('Review the draft owner statements for %s', to_char(new.statement_month, 'FMMonth YYYY')),
          p_due_at => app.local_midnight(new.payout_date), p_dedupe => 'review_statements:' || to_char(new.statement_month, 'YYYY-MM'));
    end if;

  elsif tg_table_name = 'vehicle_exits' then
    select * into v from vehicles where id = new.vehicle_id;
    perform app.raise_task(p_type => 'owner_exit', p_title => format('Owner exit: %s %s %s, Exit Date %s', v.year, v.make, v.model, new.exit_date),
        p_vehicle => v.id, p_owner => v.owner_id, p_related_table => 'vehicle_exits', p_related_id => new.id,
        p_due_at => app.local_midnight(new.exit_date), p_dedupe => 'owner_exit:' || new.id);

  elsif tg_table_name = 'reviews' then
    perform app.raise_task(p_type => 'moderate_review', p_booking => new.booking_id, p_vehicle => new.vehicle_id,
        p_related_table => 'reviews', p_related_id => new.id, p_dedupe => 'moderate_review:' || new.id);

  elsif tg_table_name = 'documents' then
    -- an Owner uploaded a document about themselves or their vehicle
    if (to_jsonb(new) ->> 'owner_id') is not null or (to_jsonb(new) ->> 'vehicle_id') is not null then
      select ow.* into o from owners ow
       where ow.user_id = new.uploaded_by
         and (ow.id = (to_jsonb(new) ->> 'owner_id')::uuid
              or exists (select 1 from vehicles vv where vv.id = (to_jsonb(new) ->> 'vehicle_id')::uuid and vv.owner_id = ow.id));
      if o.id is not null then
        perform app.raise_task(p_type => 'check_owner_document', p_title => format('Owner document uploaded: %s (%s)', o.legal_name, new.kind),
            p_vehicle => (to_jsonb(new) ->> 'vehicle_id')::uuid, p_owner => o.id, p_related_table => 'documents', p_related_id => new.id,
            p_dedupe => 'check_owner_document:' || new.id);
      end if;
    end if;
  end if;
  return null;
end $$;

create trigger booking_cancellations_ops_task after insert on booking_cancellations for each row execute function app.ops_task_trigger();
create trigger booking_extensions_ops_task after insert on booking_extensions for each row execute function app.ops_task_trigger();
create trigger identity_verifications_ops_task after insert or update of status on identity_verifications for each row execute function app.ops_task_trigger();
create trigger coverage_proofs_ops_task after insert or update of status on coverage_proofs for each row execute function app.ops_task_trigger();
create trigger vehicle_onboardings_ops_task after insert or update of status on vehicle_onboardings for each row execute function app.ops_task_trigger();
create trigger owner_invoices_ops_task after insert or update of status on owner_invoices for each row execute function app.ops_task_trigger();
create trigger owner_statements_ops_task after insert on owner_statements for each row execute function app.ops_task_trigger();
create trigger vehicle_exits_ops_task after insert on vehicle_exits for each row execute function app.ops_task_trigger();
create trigger reviews_ops_task after insert on reviews for each row execute function app.ops_task_trigger();
create trigger documents_ops_task after insert on documents for each row execute function app.ops_task_trigger();

-- ================================================================ 17. calendar
-- The master calendar's entries of migration 0016 (bookings and calendar blocks, unchanged),
-- and now also field jobs, vehicle moves and Turo trips. The first 21 columns are the ones
-- 0016 defined; four are added at the end. For the new entry types the booking_id column stays
-- empty (so "the entry of booking X" is still one row) and related_booking_id carries the link.
--   field job     Admins and assistants in fleet, finance or customer service
--   vehicle move  Admins and assistants in fleet or finance
--   Turo trip     Admins, assistants in fleet or finance, and the vehicle's Owner
-- Renters, field staff and the anonymous role still see nothing here.
create or replace view calendar_entries with (security_barrier = true) as
  select 'booking'::text as entry_type, b.id as entry_id, b.vehicle_id,
         v.year || ' ' || v.make || ' ' || v.model as vehicle_label, v.plate, v.fleet_number,
         b.id as booking_id, b.booking_number, b.booking_type::text as booking_type, b.status::text as status,
         case when b.status::text in ('requested', 'offered', 'tentative', 'pending_payment') then 'pending'
              when b.status::text = 'confirmed' then 'booked'
              when b.status::text = 'on_rent' then 'out'
              when b.status::text in ('returned', 'closed') then 'done'
              else 'void' end as calendar_state,
         b.pickup_at as starts_at, b.return_at as ends_at,
         b.blocks_calendar,
         (b.blocks_calendar and b.status::text in ('confirmed', 'on_rent')) as is_blocking,
         b.bill_to, b.dates_provisional,
         case when app.is_admin() or app.va_has('cs', 'finance', 'fleet') then i.name end as insurer_name,
         case when app.is_admin() or app.va_has('cs', 'finance', 'fleet') then r.legal_name
              else split_part(btrim(r.legal_name), ' ', 1) end as renter_name,
         null::text as block_reason,
         case when app.is_admin() or app.va_has('cs', 'finance', 'fleet') then b.notes end as note,
         b.id as related_booking_id, null::uuid as assigned_to, null::text as assignee_name, null::text as detail
    from bookings b
    join vehicles v on v.id = b.vehicle_id
    join renters r on r.id = b.renter_id
    left join insurers i on i.id = b.insurer_id
   where app.is_staff() or app.owns_vehicle(b.vehicle_id)
  union all
  select 'block', c.id, c.vehicle_id,
         v.year || ' ' || v.make || ' ' || v.model, v.plate, v.fleet_number,
         null, null, null, 'blocked', 'blocked',
         c.starts_at, c.ends_at, true, true, null, false, null, null, c.reason,
         case when app.is_staff() then c.note end,
         null, null, null, null
    from vehicle_calendar_blocks c
    join vehicles v on v.id = c.vehicle_id
   where c.removed_at is null and (app.is_staff() or app.owns_vehicle(c.vehicle_id))
  union all
  select 'field_job', j.id, j.vehicle_id,
         v.year || ' ' || v.make || ' ' || v.model, v.plate, v.fleet_number,
         null, null, null, j.status, 'job',
         j.scheduled_at, greatest(coalesce(j.completed_at, j.scheduled_at + interval '1 hour'), j.scheduled_at + interval '1 minute'),
         false, false, null, false, null, null, null, j.instructions,
         j.booking_id, j.assigned_to, u.full_name, j.kind
    from field_jobs j
    join vehicles v on v.id = j.vehicle_id
    left join users u on u.id = j.assigned_to
   where j.status <> 'cancelled' and (app.is_admin() or app.va_has('fleet', 'finance', 'cs'))
  union all
  select 'vehicle_move', m.id, m.vehicle_id,
         v.year || ' ' || v.make || ' ' || v.model, v.plate, v.fleet_number,
         null, null, null, case when m.ended_at is null then 'open' else 'done' end, 'move',
         m.started_at, m.ended_at, false, false, null, false, null, null, null,
         nullif(concat_ws(' to ', m.from_place, m.to_place), ''),
         m.booking_id, m.staff_user_id, u.full_name, m.purpose
    from vehicle_moves m
    join vehicles v on v.id = m.vehicle_id
    left join users u on u.id = m.staff_user_id
   where app.is_admin() or app.va_has('fleet', 'finance')
  union all
  select 'turo_trip', t.id, t.vehicle_id,
         v.year || ' ' || v.make || ' ' || v.model, v.plate, v.fleet_number,
         null, null, null, 'turo', 'turo',
         t.starts_at, t.ends_at, false, false, null, false, null, null, null, null,
         null, null, null, t.turo_trip_ref
    from turo_trips t
    join vehicles v on v.id = t.vehicle_id
   where app.is_admin() or app.va_has('fleet', 'finance') or app.owns_vehicle(t.vehicle_id);

-- The master calendar for a date range, as in 0016, with the four new columns at the end.
drop function app.master_calendar(timestamptz, timestamptz);
create function app.master_calendar(p_from timestamptz, p_to timestamptz)
returns table (vehicle_id uuid, vehicle_label text, plate text, fleet_number text, vehicle_status text,
               entry_type text, entry_id uuid, booking_id uuid, booking_number text, booking_type text, status text,
               calendar_state text, starts_at timestamptz, ends_at timestamptz, blocks_calendar boolean, is_blocking boolean,
               bill_to text, dates_provisional boolean, insurer_name text, renter_name text, block_reason text, note text,
               related_booking_id uuid, assigned_to uuid, assignee_name text, detail text)
language sql stable security definer set search_path = public, app as $$
  select v.id, v.year || ' ' || v.make || ' ' || v.model, v.plate, v.fleet_number, v.status::text,
         e.entry_type, e.entry_id, e.booking_id, e.booking_number, e.booking_type, e.status,
         e.calendar_state, e.starts_at, e.ends_at, e.blocks_calendar, e.is_blocking,
         e.bill_to, e.dates_provisional, e.insurer_name, e.renter_name, e.block_reason, e.note,
         e.related_booking_id, e.assigned_to, e.assignee_name, e.detail
    from vehicles v
    left join calendar_entries e
      on e.vehicle_id = v.id and e.starts_at < p_to and (e.ends_at is null or e.ends_at > p_from)
   where (app.is_staff() or app.owns_vehicle(v.id))
     and v.status::text not in ('declined', 'exited')
   order by v.fleet_number nulls last, v.id, e.starts_at, e.entry_id
$$;

-- Everything on one car, for the admin vehicle page: every booking in every status (cancelled
-- ones too), calendar blocks (removed ones flagged), field jobs, vehicle moves, Turo trips,
-- the times the Owner's controls were blocked, incidents, and the exit notice and Exit Date.
-- For Admins and assistants in fleet, finance or customer service.
create or replace function app.vehicle_calendar(p_vehicle uuid, p_from timestamptz, p_to timestamptz)
returns table (entry_type text, entry_id uuid, label text, status text, starts_at timestamptz, ends_at timestamptz,
               is_blocking boolean, booking_id uuid, details jsonb)
language plpgsql stable security definer set search_path = public, app as $$
begin
  if app.from_browser() and not (app.is_admin() or app.va_has('fleet', 'finance', 'cs')) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return query
  select x.entry_type, x.entry_id, x.label, x.status, x.starts_at, x.ends_at, x.is_blocking, x.booking_id, x.details
    from (
      select 'booking'::text as entry_type, b.id as entry_id, b.booking_number || ' ' || r.legal_name as label, b.status::text as status,
             b.pickup_at as starts_at, b.return_at as ends_at, (b.blocks_calendar and b.status::text in ('confirmed', 'on_rent')) as is_blocking,
             b.id as booking_id,
             jsonb_build_object('booking_type', b.booking_type, 'blocks_calendar', b.blocks_calendar, 'bill_to', b.bill_to,
                                'dates_provisional', b.dates_provisional, 'handed_over_at', b.handed_over_at, 'checked_in_at', b.checked_in_at,
                                'pickup_place', b.pickup_place, 'return_place', b.return_place) as details
        from bookings b join renters r on r.id = b.renter_id where b.vehicle_id = p_vehicle
      union all
      select 'block', c.id, c.reason, case when c.removed_at is null then 'blocked' else 'removed' end, c.starts_at, c.ends_at,
             c.removed_at is null, null, jsonb_build_object('note', c.note, 'removed_at', c.removed_at, 'removed_reason', c.removed_reason)
        from vehicle_calendar_blocks c where c.vehicle_id = p_vehicle
      union all
      select 'field_job', j.id, j.kind, j.status, j.scheduled_at, coalesce(j.completed_at, j.scheduled_at + interval '1 hour'), false, j.booking_id,
             jsonb_build_object('assigned_to', j.assigned_to, 'assignee_name', u.full_name, 'place', j.place, 'started_at', j.started_at,
                                'completed_at', j.completed_at, 'cleaning_grade', j.cleaning_grade)
        from field_jobs j left join users u on u.id = j.assigned_to where j.vehicle_id = p_vehicle
      union all
      select 'vehicle_move', m.id, m.purpose, case when m.ended_at is null then 'open' else 'done' end, m.started_at, m.ended_at, false, m.booking_id,
             jsonb_build_object('staff_user_id', m.staff_user_id, 'staff_name', u.full_name, 'from_place', m.from_place, 'to_place', m.to_place,
                                'odometer_start', m.odometer_start, 'odometer_end', m.odometer_end)
        from vehicle_moves m left join users u on u.id = m.staff_user_id where m.vehicle_id = p_vehicle
      union all
      select 'turo_trip', t.id, 'Turo ' || t.turo_trip_ref, 'turo', t.starts_at, t.ends_at, false, null, jsonb_build_object('statement_month', t.statement_month)
        from turo_trips t where t.vehicle_id = p_vehicle
      union all
      select 'owner_controls_blocked', a.id, a.reason, case when a.ends_at is null then 'open' else 'ended' end, a.starts_at, a.ends_at, false, a.booking_id, '{}'::jsonb
        from tracker_access_blocks a where a.vehicle_id = p_vehicle
      union all
      select 'incident', n.id, n.incident_number || ' ' || n.kind, n.status, coalesce(n.occurred_at, n.reported_at), n.closed_at, false, n.booking_id,
             jsonb_build_object('drivable', n.drivable, 'description', n.description)
        from incidents n where n.vehicle_id = p_vehicle
      union all
      select 'exit_notice', e.id, 'Exit notice, Exit Date ' || e.exit_date, e.status, e.notice_received_at, app.local_midnight(e.exit_date + 1), false, null,
             jsonb_build_object('exit_date', e.exit_date, 'notice_ends_on', e.notice_ends_on, 'initiated_by', e.initiated_by)
        from vehicle_exits e where e.vehicle_id = p_vehicle
    ) x
   where x.starts_at < p_to and (x.ends_at is null or x.ends_at > p_from)
   order by x.starts_at, x.entry_type, x.entry_id;
end $$;

-- ---------------------------------------------------------------- drag and resize
-- What moving or resizing a booking on the calendar would do, before anything is changed.
-- p_changes: any of vehicle_id, pickup_at, return_at. The answer says:
--   refusal    why it cannot be done at all (null when it can)
--   action     apply_now          a request, or a confirmed insurer booking with provisional dates
--              resend_offer       an offer is out: it is withdrawn and a new version is sent
--              renter_approval    a confirmed booking: the renter must agree to the change
--              extension          a car on rent: a later return is an extension the renter pays first
--   old, new   vehicle, times, days, rental charge and total; difference_cents is new less old
--   available, conflicts (blocking bookings and calendar blocks in the way), competing (open
--   requests and offers on the same car and dates)
-- Prices use the rates stored on the booking; a request or offer moved to another car takes that
-- car's rate card, exactly as app.adjust_booking() does. A confirmed booking moves only to a
-- car with the same Owner and terms, because its split terms cannot change.
create or replace function app.calendar_preview_change(p_booking uuid, p_changes jsonb, p_now timestamptz default now())
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare
  ch jsonb := coalesce(p_changes, '{}'::jsonb);
  b bookings;
  v vehicles;
  rc rate_cards;
  v_set program_settings;
  v_vehicle uuid; v_pickup timestamptz; v_return timestamptz;
  v_days integer; v_rate record; v_ext record;
  v_daily bigint; v_weekend bigint; v_weekly bigint; v_monthly bigint;
  v_rental bigint := 0; v_disc bigint := 0; v_staff bigint := 0; v_promo bigint := 0;
  v_old_net bigint; v_new_net bigint; v_old_hst bigint; v_new_hst bigint; v_new_total bigint;
  v_refusal text; v_action text; v_available boolean;
  v_arranging boolean;
begin
  if app.from_browser() and not app.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  v_set := app.settings(app.local_date(b.booked_at));
  v_vehicle := coalesce((ch ->> 'vehicle_id')::uuid, b.vehicle_id);
  v_pickup := coalesce((ch ->> 'pickup_at')::timestamptz, b.pickup_at);
  v_return := coalesce((ch ->> 'return_at')::timestamptz, b.return_at);
  v_arranging := b.status in ('requested', 'offered', 'pending_payment');
  select * into v from vehicles where id = v_vehicle;
  v_daily := b.daily_rate_cents; v_weekend := b.weekend_rate_cents; v_weekly := b.weekly_rate_cents; v_monthly := b.monthly_rate_cents;
  select 'none'::text as rate_applied, 0 as daily_days, 0 as weekend_days, 0::bigint as rental_charge_cents into v_rate;

  v_action := case when b.status = 'requested' then 'apply_now'
                   when b.status in ('offered', 'pending_payment') then 'resend_offer'
                   when b.status = 'confirmed' and b.dates_provisional then 'apply_now'
                   when b.status = 'confirmed' then 'renter_approval'
                   when b.status = 'on_rent' then 'extension' end;
  if v_action is null then
    v_refusal := format('A booking that is %s cannot be moved', b.status);
  elsif v.id is null then
    v_refusal := 'That vehicle does not exist';
  elsif v_return <= v_pickup then
    v_refusal := 'The return must be after the pickup';
  elsif public.calc_billable_days(v_pickup, v_return) > v_set.max_rental_days then
    v_refusal := format('A rental is at most %s days; longer stays renew with a new booking', v_set.max_rental_days);
  elsif b.status = 'on_rent' and (v_vehicle <> b.vehicle_id or v_pickup <> b.pickup_at or v_return <= b.return_at) then
    v_refusal := 'A car that is on rent can only have its return moved later (an extension)';
  elsif b.status <> 'on_rent' and v_pickup < p_now and v_pickup <> b.pickup_at then
    v_refusal := 'The pickup cannot be moved into the past';
  elsif b.status = 'confirmed' and b.dates_provisional and v_vehicle <> b.vehicle_id then
    v_refusal := 'While the dates are provisional only the dates can be corrected';
  elsif b.booking_type <> 'owner' and v_vehicle <> b.vehicle_id and not coalesce(app.vehicle_bookable(v_vehicle), false) then
    v_refusal := 'That vehicle is not open for bookings';
  elsif v.exit_date is not null and app.local_date(v_return) > v.exit_date then
    v_refusal := 'The booking would run past the vehicle''s Exit Date';
  elsif b.status = 'confirmed' and v_vehicle <> b.vehicle_id
        and (v.owner_id, v.management_mode) is distinct from (b.owner_id, b.management_mode) then
    v_refusal := 'A confirmed booking can move only to a vehicle of the same Owner and management mode: its split terms cannot change';
  elsif exists (select 1 from booking_drivers d where d.booking_id = p_booking and d.age_band = '18_to_20') and not v.allows_18_to_20 then
    v_refusal := 'A driver aged 18 to 20 may only take a vehicle flagged for them';
  end if;

  if v_refusal is null then
    if v_arranging and v_vehicle <> b.vehicle_id and b.booking_type <> 'owner' then
      select * into rc from rate_cards r
       where r.vehicle_id = v_vehicle and r.effective_from <= p_now and (r.effective_to is null or r.effective_to > p_now);
      if rc.id is null then
        v_refusal := 'That vehicle has no rates set';
      else
        v_daily := rc.daily_rate_cents; v_weekend := rc.weekend_rate_cents; v_weekly := rc.weekly_rate_cents; v_monthly := rc.monthly_rate_cents;
      end if;
    end if;
  end if;

  v_old_net := b.rental_charge_cents - b.discount_cents - b.staff_discount_cents - b.promo_discount_cents;
  v_old_hst := public.calc_hst(b.rental_charge_cents, b.hst_bps) + public.calc_hst(-b.discount_cents, b.hst_bps)
             + public.calc_hst(-b.staff_discount_cents, b.hst_bps) + public.calc_hst(-b.promo_discount_cents, b.hst_bps);
  if v_refusal is null then
    v_days := public.calc_billable_days(v_pickup, v_return);
    if b.booking_type <> 'owner' then
      select * into v_rate from public.calc_rental_charge(v_pickup, v_days, v_daily, v_weekend, v_weekly, v_monthly);
      v_rental := v_rate.rental_charge_cents;
      v_disc := case when b.booking_type = 'non_refundable' then public.calc_bps(v_rental, v_set.non_refundable_discount_bps) else 0 end;
      v_staff := least(b.staff_discount_cents, v_rental - v_disc);
      v_promo := case when b.promo_code_id is null then 0
                      when v_arranging then coalesce(app.promo_discount_cents(b.promo_code_id, v_rental - v_disc - v_staff), 0)
                      else least(b.promo_discount_cents, v_rental - v_disc - v_staff) end;
    end if;
    v_new_net := v_rental - v_disc - v_staff - v_promo;
    v_new_hst := public.calc_hst(v_rental, b.hst_bps) + public.calc_hst(-v_disc, b.hst_bps)
               + public.calc_hst(-v_staff, b.hst_bps) + public.calc_hst(-v_promo, b.hst_bps);
    v_new_total := b.total_due_at_booking_cents - (v_old_net + v_old_hst) + (v_new_net + v_new_hst);
    v_available := app.vehicle_is_available(v_vehicle, v_pickup, v_return, p_booking);
  end if;

  return jsonb_build_object(
    'booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'refusal', v_refusal,
    'action', case when v_refusal is null then v_action else 'refused' end,
    'offer_must_be_resent', v_refusal is null and v_action = 'resend_offer',
    'renter_must_approve', v_refusal is null and v_action in ('renter_approval', 'extension'),
    'old', jsonb_build_object('vehicle_id', b.vehicle_id, 'pickup_at', b.pickup_at, 'return_at', b.return_at, 'billable_days', b.billable_days,
                              'rental_charge_cents', b.rental_charge_cents, 'rental_after_discounts_cents', v_old_net,
                              'total_cents', b.total_due_at_booking_cents),
    'new', case when v_refusal is null then jsonb_build_object('vehicle_id', v_vehicle, 'pickup_at', v_pickup, 'return_at', v_return,
                              'billable_days', v_days, 'rate_applied', v_rate.rate_applied, 'daily_days', v_rate.daily_days, 'weekend_days', v_rate.weekend_days,
                              'daily_rate_cents', v_daily, 'weekend_rate_cents', v_weekend, 'weekly_rate_cents', v_weekly, 'monthly_rate_cents', v_monthly,
                              'rental_charge_cents', v_rental, 'non_refundable_discount_cents', v_disc, 'staff_discount_cents', v_staff,
                              'promo_discount_cents', v_promo, 'rental_after_discounts_cents', v_new_net, 'rental_hst_cents', v_new_hst,
                              'total_cents', v_new_total) end,
    'difference_cents', case when v_refusal is null then v_new_total - b.total_due_at_booking_cents end,
    'difference_before_hst_cents', case when v_refusal is null then v_new_net - v_old_net end,
    'available', v_available,
    'conflicts', case when v_refusal is null then coalesce((
        select jsonb_agg(c order by c ->> 'starts_at') from (
          select jsonb_build_object('entry_type', 'booking', 'id', x.id, 'booking_number', x.booking_number, 'status', x.status,
                                    'starts_at', x.pickup_at, 'ends_at', x.return_at) as c
            from bookings x
           where x.vehicle_id = v_vehicle and x.id <> p_booking and x.blocks_calendar and x.status in ('confirmed', 'on_rent')
             and x.pickup_at < v_return and x.return_at > v_pickup
          union all
          select jsonb_build_object('entry_type', 'block', 'id', k.id, 'reason', k.reason, 'starts_at', k.starts_at, 'ends_at', k.ends_at)
            from vehicle_calendar_blocks k
           where k.vehicle_id = v_vehicle and k.removed_at is null and k.starts_at < v_return and (k.ends_at is null or k.ends_at > v_pickup)) q),
        '[]'::jsonb) end,
    'competing', case when v_refusal is null then coalesce((
        select jsonb_agg(jsonb_build_object('id', x.id, 'booking_number', x.booking_number, 'status', x.status,
                                            'starts_at', x.pickup_at, 'ends_at', x.return_at) order by x.pickup_at)
          from bookings x
         where x.vehicle_id = v_vehicle and x.id <> p_booking and x.status in ('requested', 'offered', 'pending_payment')
           and x.pickup_at < v_return and x.return_at > v_pickup), '[]'::jsonb) end);
end $$;

-- Apply a move or resize, with the reason. What happens follows the preview's "action":
--   apply_now        the booking is adjusted and repriced at once (app.adjust_booking)
--   resend_offer     the offer is withdrawn, the booking adjusted, and a new version sent
--   renter_approval  nothing moves unless p_renter_agreed is true (an Admin recording the renter's
--                    agreement). Without it, customer service gets the task to obtain it. With it,
--                    the booking moves at its stored rates; a higher price becomes a line and a
--                    pending card charge, a lower one a refund request waiting for approval
--   extension        an extension request is recorded: the renter pays before the return moves
-- Open field jobs of the booking follow its new times, places and car. Returns the outcome.
create or replace function app.calendar_apply_change(p_booking uuid, p_by uuid, p_changes jsonb, p_reason text,
    p_renter_agreed boolean default false, p_message text default null, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  ch jsonb := coalesce(p_changes, '{}'::jsonb);
  b bookings;
  pv jsonb;
  nw jsonb;
  v_changes jsonb;
  v_action text;
  v_version integer;
  v_diff bigint; v_diff_hst bigint;
  v_pay uuid; v_refund uuid; v_ext uuid; v_task uuid;
  f fee_types;
  e record;
begin
  if not app.user_is_staff(p_by) then
    raise exception 'Only staff move a booking on the calendar' using errcode = '42501';
  end if;
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'Give the reason for the change' using errcode = '22023';
  end if;
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  pv := app.calendar_preview_change(p_booking, ch, p_now);
  if pv ->> 'refusal' is not null then
    raise exception '%', pv ->> 'refusal' using errcode = '23514';
  end if;
  v_action := pv ->> 'action';
  nw := pv -> 'new';
  -- only what actually changes is passed on
  v_changes := jsonb_strip_nulls(jsonb_build_object(
    'vehicle_id', case when (nw ->> 'vehicle_id')::uuid <> b.vehicle_id then nw -> 'vehicle_id' end,
    'pickup_at', case when (nw ->> 'pickup_at')::timestamptz <> b.pickup_at then nw -> 'pickup_at' end,
    'return_at', case when (nw ->> 'return_at')::timestamptz <> b.return_at then nw -> 'return_at' end));
  if v_changes = '{}'::jsonb then
    raise exception 'Nothing would change' using errcode = '22023';
  end if;

  if v_action = 'apply_now' then
    perform app.adjust_booking(p_booking, p_by, v_changes, p_reason);
  elsif v_action = 'resend_offer' then
    perform app.withdraw_offer(p_booking, p_by, p_reason);
    perform app.adjust_booking(p_booking, p_by, v_changes, p_reason);
    v_version := app.send_offer(p_booking, p_by, coalesce(p_message, p_reason));
  elsif v_action = 'extension' then
    select * into e from public.calc_extension(b.pickup_at, b.billable_days, (nw ->> 'billable_days')::integer,
                                               b.daily_rate_cents, b.weekend_rate_cents, b.weekly_rate_cents, b.monthly_rate_cents);
    if (nw ->> 'billable_days')::integer <= b.billable_days then
      raise exception 'The new return adds no billable day: nothing to extend' using errcode = '23514';
    end if;
    if not (pv ->> 'available')::boolean then
      raise exception 'The vehicle is not free for the extra days' using errcode = '23P01';
    end if;
    insert into booking_extensions (booking_id, seq, status, requested_at, previous_return_at, new_return_at, previous_days, new_days,
                                    previous_rental_charge_cents, new_rental_charge_cents, rental_difference_cents, hst_cents, total_cents)
    values (p_booking, (select coalesce(max(seq), 0) + 1 from booking_extensions where booking_id = p_booking), 'requested', p_now,
            b.return_at, (nw ->> 'return_at')::timestamptz, b.billable_days, (nw ->> 'billable_days')::integer,
            e.previous_rental_charge_cents, e.new_rental_charge_cents, e.rental_difference_cents,
            public.calc_hst(e.rental_difference_cents, b.hst_bps), e.rental_difference_cents + public.calc_hst(e.rental_difference_cents, b.hst_bps))
    returning id into v_ext;
  elsif v_action = 'renter_approval' then
    if not p_renter_agreed then
      v_task := app.raise_task(p_type => 'booking_change_approval',
          p_title => format('Booking %s: a change needs the renter''s agreement', b.booking_number),
          p_detail => format('%s Proposed: pickup %s, return %s (Toronto). Price difference %s.', p_reason,
                             to_char((nw ->> 'pickup_at')::timestamptz at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
                             to_char((nw ->> 'return_at')::timestamptz at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
                             app.money_text((pv ->> 'difference_cents')::bigint)),
          p_booking => p_booking, p_vehicle => b.vehicle_id, p_renter => b.renter_id,
          p_dedupe => 'booking_change_approval:' || p_booking, p_created_by => p_by);
      return pv || jsonb_build_object('applied', false, 'task_id', v_task);
    end if;
    if not app.user_is_admin(p_by) then
      raise exception 'Only an Admin records the renter''s agreement to a change by word; otherwise the renter signs the change' using errcode = '42501';
    end if;
    if b.blocks_calendar and not (pv ->> 'available')::boolean then
      raise exception 'The vehicle is not available for these dates: a confirmed booking or a calendar block overlaps' using errcode = '23P01';
    end if;
    v_diff := (pv ->> 'difference_before_hst_cents')::bigint;
    v_diff_hst := (pv ->> 'difference_cents')::bigint - v_diff;
    update bookings set
        vehicle_id = (nw ->> 'vehicle_id')::uuid, pickup_at = (nw ->> 'pickup_at')::timestamptz, return_at = (nw ->> 'return_at')::timestamptz,
        original_return_at = (nw ->> 'return_at')::timestamptz, billable_days = (nw ->> 'billable_days')::integer,
        km_allowance_total = km_allowance_per_day * (nw ->> 'billable_days')::integer,
        rate_applied = coalesce(nw ->> 'rate_applied', rate_applied),
        daily_days = coalesce((nw ->> 'daily_days')::integer, daily_days), weekend_days = coalesce((nw ->> 'weekend_days')::integer, weekend_days),
        rental_charge_cents = (nw ->> 'rental_charge_cents')::bigint, discount_cents = (nw ->> 'non_refundable_discount_cents')::bigint,
        staff_discount_cents = (nw ->> 'staff_discount_cents')::bigint, promo_discount_cents = (nw ->> 'promo_discount_cents')::bigint,
        subtotal_at_booking_cents = subtotal_at_booking_cents + greatest(v_diff, 0),
        hst_at_booking_cents = hst_at_booking_cents + case when v_diff > 0 then v_diff_hst else 0 end,
        total_due_at_booking_cents = total_due_at_booking_cents + case when v_diff > 0 then v_diff + v_diff_hst else 0 end
     where id = p_booking;
    if v_diff > 0 then
      -- more to pay: a line for the difference and a pending charge of the Card on File
      select * into f from fee_types where code = 'rental_charge';
      insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, payment_method_id, created_by)
      values (p_booking, b.renter_id, 'extension', 'charge', 'card', v_diff + v_diff_hst, 'pending', b.card_on_file_id, p_by)
      returning id into v_pay;
      insert into booking_line_items (booking_id, charge_type, description, quantity, unit_amount_cents, amount_cents, hst_applies, hst_cents,
                                      revenue_class, stage, payment_id, created_by)
      values (p_booking, 'rental_charge', 'Rental charge: difference after a change of booking', 1, v_diff, v_diff, f.hst_applies, v_diff_hst,
              f.revenue_class, 'booking', v_pay, p_by);
    elsif v_diff < 0 then
      -- less to pay: a refund request, which follows the usual approval rules
      insert into refunds (booking_id, payment_id, reason, amount_cents, status, requested_by, note)
      values (p_booking, (select p.id from payments p where p.booking_id = p_booking and p.purpose = 'booking_total' and p.kind = 'charge'
                             and p.status = 'succeeded' order by p.created_at limit 1),
              'other', -(v_diff + v_diff_hst), 'pending_approval', p_by, 'Change of booking: ' || p_reason)
      returning id into v_refund;
    end if;
    perform app.log_booking_event(p_booking, 'adjusted', b.status::text, b.status::text, b.current_offer_version, p_reason, p_by, 'staff',
        v_changes || jsonb_build_object('renter_agreed', true, 'difference_cents', pv -> 'difference_cents'));
    perform app.resolve_tasks(array['booking_change_approval'], p_booking, p_by, 'Change applied');
  end if;

  -- open jobs follow the booking
  select * into b from bookings where id = p_booking;
  update field_jobs j
     set vehicle_id = b.vehicle_id,
         scheduled_at = case when j.kind in ('handover', 'delivery') then b.pickup_at else b.return_at end,
         status = case when j.scheduled_at is distinct from (case when j.kind in ('handover', 'delivery') then b.pickup_at else b.return_at end)
                       then 'scheduled' else j.status end,
         acknowledged_at = case when j.scheduled_at is distinct from (case when j.kind in ('handover', 'delivery') then b.pickup_at else b.return_at end)
                                then null else j.acknowledged_at end
   where j.booking_id = p_booking and j.status in ('scheduled', 'acknowledged')
     and j.kind in ('handover', 'delivery', 'return_check_in', 'pickup_from_renter')
     and v_action <> 'extension'
     and (j.vehicle_id <> b.vehicle_id
          or j.scheduled_at is distinct from (case when j.kind in ('handover', 'delivery') then b.pickup_at else b.return_at end));

  return pv || jsonb_build_object('applied', v_action <> 'extension', 'offer_version', v_version, 'extension_id', v_ext,
                                  'payment_id', v_pay, 'refund_id', v_refund);
end $$;

-- ================================================================ 18. rates and fees
-- Set a vehicle's rate card from a moment on. The card in force is closed at that moment and the
-- new one opened, so the history stays and existing bookings keep their snapshot. A card
-- already scheduled for later stays, and the new one ends where it begins.
-- p_other: km_allowance_per_day, overage_cents_per_km, deposit_cents, delivery_fee_cents,
-- pickup_fee_cents; what is not given is carried over from the card in force, or, for a first
-- card, taken from the fee defaults for the vehicle's class.
-- Who: an Admin; Fleet enters what an Admin set; on a Self-Managed vehicle its Owner.
create or replace function app.set_rate_card(p_vehicle uuid, p_daily_cents bigint, p_weekend_cents bigint, p_weekly_cents bigint,
    p_monthly_cents bigint, p_effective_from timestamptz default now(), p_by uuid default null, p_other jsonb default '{}'::jsonb)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  ot jsonb := coalesce(p_other, '{}'::jsonb);
  v vehicles;
  cur rate_cards;
  v_from timestamptz := coalesce(p_effective_from, now());
  v_next timestamptz;
  v_by_owner boolean := false;
  v_km integer; v_over integer; v_deposit bigint; v_delivery bigint; v_pickup bigint;
  d record;
  v_id uuid;
begin
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then raise exception 'Vehicle % not found', p_vehicle; end if;
  if p_by is not null then
    v_by_owner := v.management_mode = 'self_managed' and exists (select 1 from owners o where o.id = v.owner_id and o.user_id = p_by);
    if not (app.user_runs_fleet(p_by) or v_by_owner) then
      raise exception 'Rates are set by an Admin (entered by Fleet), or by the Owner of a Self-Managed vehicle' using errcode = '42501';
    end if;
  end if;
  if num_nulls(p_daily_cents, p_weekend_cents, p_weekly_cents, p_monthly_cents) > 0
     or least(p_daily_cents, p_weekend_cents, p_weekly_cents, p_monthly_cents) <= 0 then
    raise exception 'The daily, weekend, weekly and monthly rates must all be above zero' using errcode = '22023';
  end if;

  select * into cur from rate_cards r
   where r.vehicle_id = p_vehicle and r.effective_from <= v_from and (r.effective_to is null or r.effective_to > v_from);
  v_km := coalesce((ot ->> 'km_allowance_per_day')::integer, cur.km_allowance_per_day);
  v_over := coalesce((ot ->> 'overage_cents_per_km')::integer, cur.overage_cents_per_km,
                     (select e.amount_cents::integer from public.effective_fee('mileage_overage', p_vehicle, app.local_date(v_from)) e));
  v_deposit := coalesce((ot ->> 'deposit_cents')::bigint, cur.deposit_cents,
                        (select e.amount_cents from public.effective_fee('deposit', p_vehicle, app.local_date(v_from)) e));
  v_delivery := coalesce((ot ->> 'delivery_fee_cents')::bigint, cur.delivery_fee_cents, 0);
  v_pickup := coalesce((ot ->> 'pickup_fee_cents')::bigint, cur.pickup_fee_cents, 0);
  if v_km is null or v_over is null or v_deposit is null then
    raise exception 'A first rate card needs the kilometres per day, and an overage rate and Deposit either given or set in the fee defaults for the class'
      using errcode = '22023';
  end if;
  -- the ranges of the fee defaults (delivery and pickup; the overage of luxury and exotic cars). Nil means "not offered".
  for d in select fd.fee_type_code, fd.min_cents, fd.max_cents from fee_defaults fd
            where fd.fee_type_code in ('delivery', 'pickup', 'mileage_overage') and (fd.vehicle_class is null or fd.vehicle_class = v.class)
              and (fd.min_cents is not null or fd.max_cents is not null)
              and fd.effective_from <= app.local_date(v_from) and (fd.effective_to is null or fd.effective_to > app.local_date(v_from))
  loop
    if (d.fee_type_code = 'delivery' and v_delivery > 0 and (v_delivery < coalesce(d.min_cents, v_delivery) or v_delivery > coalesce(d.max_cents, v_delivery)))
       or (d.fee_type_code = 'pickup' and v_pickup > 0 and (v_pickup < coalesce(d.min_cents, v_pickup) or v_pickup > coalesce(d.max_cents, v_pickup)))
       or (d.fee_type_code = 'mileage_overage' and (v_over < coalesce(d.min_cents, v_over) or v_over > coalesce(d.max_cents, v_over))) then
      raise exception 'The % amount is outside the range the fee defaults allow (% to % cents)', d.fee_type_code, d.min_cents, d.max_cents
        using errcode = '23514';
    end if;
  end loop;

  if cur.id is not null and cur.effective_from = v_from then
    raise exception 'A rate card already starts at that moment: choose a later time' using errcode = '23505';
  end if;
  select min(r.effective_from) into v_next from rate_cards r where r.vehicle_id = p_vehicle and r.effective_from > v_from;
  if cur.id is not null then
    update rate_cards set effective_to = v_from where id = cur.id;
  end if;
  insert into rate_cards (vehicle_id, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, km_allowance_per_day,
                          overage_cents_per_km, deposit_cents, delivery_fee_cents, pickup_fee_cents, effective_from, effective_to, set_by, set_by_owner)
  values (p_vehicle, p_daily_cents, p_weekend_cents, p_weekly_cents, p_monthly_cents, v_km, v_over, v_deposit, v_delivery, v_pickup,
          v_from, v_next, p_by, v_by_owner)
  returning id into v_id;
  return v_id;
end $$;

-- An Admin sets one fee for one vehicle from a date on (only charges the catalogue marks "V").
-- The override in force is closed on that date; the history stays.
create or replace function app.set_vehicle_fee_override(p_vehicle uuid, p_fee text, p_admin uuid, p_reason text,
    p_amount_cents bigint default null, p_cap_cents bigint default null, p_percent_bps integer default null,
    p_effective_from date default app.today())
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  f fee_types;
  v_id uuid;
begin
  if not app.user_is_admin(p_admin) then
    raise exception 'Only an Admin sets a fee for one vehicle' using errcode = '42501';
  end if;
  select * into f from fee_types where code = p_fee;
  if f.code is null then raise exception 'Unknown charge type %', p_fee; end if;
  if not f.change_vehicle then
    raise exception 'The charge "%" cannot be set per vehicle', p_fee using errcode = '23514';
  end if;
  if p_amount_cents is null and p_cap_cents is null and p_percent_bps is null then
    raise exception 'Give an amount, a cap or a percentage' using errcode = '22023';
  end if;
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'Give the reason for the override' using errcode = '22023';
  end if;
  if not exists (select 1 from vehicles where id = p_vehicle) then raise exception 'Vehicle % not found', p_vehicle; end if;
  update vehicle_fee_overrides set effective_to = p_effective_from
   where vehicle_id = p_vehicle and fee_type_code = p_fee and effective_from < p_effective_from
     and (effective_to is null or effective_to > p_effective_from);
  insert into vehicle_fee_overrides as o (vehicle_id, fee_type_code, amount_cents, cap_cents, percent_bps, reason, effective_from, set_by)
  values (p_vehicle, p_fee, p_amount_cents, p_cap_cents, p_percent_bps, p_reason, p_effective_from, p_admin)
  on conflict (vehicle_id, fee_type_code, effective_from) do update
     set amount_cents = excluded.amount_cents, cap_cents = excluded.cap_cents, percent_bps = excluded.percent_bps,
         reason = excluded.reason, set_by = excluded.set_by, effective_to = null
  returning id into v_id;
  return v_id;
end $$;

-- End a vehicle's override on a date: the default applies again from then.
create or replace function app.end_vehicle_fee_override(p_vehicle uuid, p_fee text, p_admin uuid, p_on date default app.today()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  n integer;
begin
  if not app.user_is_admin(p_admin) then
    raise exception 'Only an Admin sets a fee for one vehicle' using errcode = '42501';
  end if;
  update vehicle_fee_overrides set effective_to = greatest(p_on, effective_from + 1)
   where vehicle_id = p_vehicle and fee_type_code = p_fee and effective_from <= p_on and (effective_to is null or effective_to > p_on);
  get diagnostics n = row_count;
  return n;
end $$;

-- Which vehicles a bulk change touches. p_filter: vehicle_ids (array), class, owner_id,
-- management_mode. Vehicles that have left, and Turo-Only vehicles, are never included.
create or replace function app.bulk_rate_vehicles(p_filter jsonb) returns setof uuid
language sql stable security definer set search_path = public, app as $$
  select v.id from vehicles v
   where v.status::text not in ('exited', 'declined', 'total_loss') and v.management_mode::text <> 'turo_only'
     and (not (coalesce(p_filter, '{}'::jsonb) ? 'vehicle_ids')
          or v.id in (select x::uuid from jsonb_array_elements_text(p_filter -> 'vehicle_ids') x))
     and (p_filter ->> 'class' is null or v.class::text = p_filter ->> 'class')
     and (p_filter ->> 'owner_id' is null or v.owner_id = (p_filter ->> 'owner_id')::uuid)
     and (p_filter ->> 'management_mode' is null or v.management_mode::text = p_filter ->> 'management_mode')
$$;

-- What a bulk rate change would do, vehicle by vehicle, before anything is written.
-- p_change: percent_bps (500 = up 5%, -1000 = down 10%) and or add_cents, applied to the fields
-- listed in "fields" (daily, weekend, weekly, monthly; all four when absent), then rounded to
-- round_to_cents (100 = whole dollars; 1 when absent). A Self-Managed vehicle is listed with a
-- note and left out: its Owner sets its rates.
create or replace function app.preview_bulk_rate_change(p_filter jsonb, p_change jsonb)
returns table (vehicle_id uuid, fleet_number text, vehicle_label text, rate_card_id uuid,
               old_daily_cents bigint, new_daily_cents bigint, old_weekend_cents bigint, new_weekend_cents bigint,
               old_weekly_cents bigint, new_weekly_cents bigint, old_monthly_cents bigint, new_monthly_cents bigint,
               will_change boolean, note text)
language plpgsql stable security definer set search_path = public, app as $$
declare
  c jsonb := coalesce(p_change, '{}'::jsonb);
  v_bps integer := coalesce((c ->> 'percent_bps')::integer, 0);
  v_add bigint := coalesce((c ->> 'add_cents')::bigint, 0);
  v_round bigint := greatest(coalesce((c ->> 'round_to_cents')::bigint, 1), 1);
  v_fields text[] := coalesce((select array_agg(x) from jsonb_array_elements_text(c -> 'fields') x), array['daily', 'weekend', 'weekly', 'monthly']);
begin
  if v_bps = 0 and v_add = 0 then
    raise exception 'Give a percentage (percent_bps) or an amount (add_cents) to change the rates by' using errcode = '22023';
  end if;
  return query
  with cards as (
    select v.id as vid, v.fleet_number as fn, v.year || ' ' || v.make || ' ' || v.model as label, v.management_mode as mode, r.*
      from vehicles v
      left join rate_cards r on r.vehicle_id = v.id and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now())
     where v.id in (select app.bulk_rate_vehicles(p_filter))),
  calc as (
    select k.*,
           case when 'daily' = any (v_fields) then (round((k.daily_rate_cents + public.calc_bps(k.daily_rate_cents, v_bps) + v_add)::numeric / v_round) * v_round)::bigint else k.daily_rate_cents end as nd,
           case when 'weekend' = any (v_fields) then (round((k.weekend_rate_cents + public.calc_bps(k.weekend_rate_cents, v_bps) + v_add)::numeric / v_round) * v_round)::bigint else k.weekend_rate_cents end as nwe,
           case when 'weekly' = any (v_fields) then (round((k.weekly_rate_cents + public.calc_bps(k.weekly_rate_cents, v_bps) + v_add)::numeric / v_round) * v_round)::bigint else k.weekly_rate_cents end as nwk,
           case when 'monthly' = any (v_fields) then (round((k.monthly_rate_cents + public.calc_bps(k.monthly_rate_cents, v_bps) + v_add)::numeric / v_round) * v_round)::bigint else k.monthly_rate_cents end as nm
      from cards k)
  select q.vid, q.fn, q.label, q.id, q.daily_rate_cents, q.nd, q.weekend_rate_cents, q.nwe, q.weekly_rate_cents, q.nwk, q.monthly_rate_cents, q.nm,
         q.id is not null and q.mode::text <> 'self_managed' and least(q.nd, q.nwe, q.nwk, q.nm) > 0
           and (q.nd, q.nwe, q.nwk, q.nm) is distinct from (q.daily_rate_cents, q.weekend_rate_cents, q.weekly_rate_cents, q.monthly_rate_cents),
         case when q.id is null then 'no rate card: set rates first'
              when q.mode::text = 'self_managed' then 'Self-Managed: the Owner sets the rates'
              when least(q.nd, q.nwe, q.nwk, q.nm) <= 0 then 'a rate would fall to zero or below'
              when q.nwk > 7 * q.nd then 'weekly rate above 7 times the daily rate'
              when q.nm < q.nwk then 'monthly rate below the weekly rate' end
    from calc q
   order by q.fn nulls last, q.vid;
end $$;

-- Apply the change the preview shows: a new rate card per vehicle from p_effective_from. Admin
-- only. Returns how many vehicles were changed.
create or replace function app.apply_bulk_rate_change(p_filter jsonb, p_change jsonb, p_admin uuid, p_effective_from timestamptz default now())
returns integer language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  n integer := 0;
begin
  if not app.user_is_admin(p_admin) then
    raise exception 'Only an Admin changes rates in bulk' using errcode = '42501';
  end if;
  for r in select * from app.preview_bulk_rate_change(p_filter, p_change) x where x.will_change loop
    perform app.set_rate_card(r.vehicle_id, r.new_daily_cents, r.new_weekend_cents, r.new_weekly_cents, r.new_monthly_cents,
                              p_effective_from, p_admin);
    n := n + 1;
  end loop;
  return n;
end $$;

-- ================================================================ 19. reconciliation (procedure 19)
-- One row per payout the card processor paid to the bank, and one per transaction inside it.
-- The server fetches the payout and its transactions from the processor (an outside call) and
-- hands them to app.record_processor_payout(); matching is done here.
create table payout_reconciliations (
  id                   uuid primary key default gen_random_uuid(),
  processor            text not null default 'stripe',
  processor_payout_ref text not null,
  paid_on              date not null,                         -- the day it reached the bank (Toronto)
  amount_cents         bigint not null,                       -- net amount paid out
  fees_cents           bigint not null default 0,             -- processor fees inside the payout
  item_count           integer not null default 0,
  matched_cents        bigint not null default 0,             -- gross amount of the items matched to payments
  unmatched_cents      bigint not null default 0,             -- gross amount (absolute) of the items not matched
  status               text not null default 'open' check (status in ('open', 'matched', 'unmatched', 'resolved')),
  matched_at           timestamptz,
  resolved_by          uuid references users (id),
  resolved_at          timestamptz,
  note                 text,
  created_by           uuid references users (id),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (processor, processor_payout_ref)
);
create index payout_reconciliations_open_idx on payout_reconciliations (paid_on) where status in ('open', 'unmatched');
create trigger payout_reconciliations_updated before update on payout_reconciliations for each row execute function app.set_updated_at();

create table payout_reconciliation_items (
  id                    uuid primary key default gen_random_uuid(),
  reconciliation_id     uuid not null references payout_reconciliations (id) on delete cascade,
  kind                  text not null default 'charge' check (kind in ('charge', 'refund', 'dispute', 'fee', 'adjustment', 'other')),
  processor_ref         text not null,                        -- the processor's transaction reference
  processor_payment_ref text,                                 -- the payment or refund it belongs to
  amount_cents          bigint not null,                      -- gross; negative for a refund or a lost dispute
  fee_cents             bigint not null default 0,
  occurred_at           timestamptz,
  payment_id            uuid references payments (id),
  status                text not null default 'unmatched' check (status in ('matched', 'unmatched', 'resolved')),
  matched_by            uuid references users (id),           -- null = matched by the system
  matched_at            timestamptz,
  note                  text,
  created_at            timestamptz not null default now(),
  unique (reconciliation_id, processor_ref),
  check (status <> 'matched' or payment_id is not null),
  check (status <> 'resolved' or note is not null)
);
create index payout_reconciliation_items_payment_idx on payout_reconciliation_items (payment_id);
create index payout_reconciliation_items_open_idx on payout_reconciliation_items (reconciliation_id) where status = 'unmatched';

-- Match the items of one payout to payments, bring its totals up to date, and raise a task for
-- Finance when something does not match. An item matches a payment when the processor's
-- references agree and the amounts are equal (a refund or lost dispute as a negative amount).
-- Fee and adjustment items need no payment. Returns the payout's status.
create or replace function app.match_processor_payout(p_reconciliation uuid) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  r payout_reconciliations;
  v_unmatched integer;
  v_status text;
begin
  select * into r from payout_reconciliations where id = p_reconciliation for update;
  if r.id is null then raise exception 'Payout % not found', p_reconciliation; end if;

  update payout_reconciliation_items i
     set payment_id = m.payment_id, status = 'matched', matched_at = now()
    from (select i2.id as item_id,
                 (select p.id from payments p join payment_processor_details d on d.payment_id = p.id
                   where d.processor = r.processor and p.status = 'succeeded'
                     and (d.balance_transaction_id = i2.processor_ref
                          or (i2.processor_payment_ref is not null
                              and i2.processor_payment_ref in (d.processor_payment_id, d.processor_charge_id, d.processor_refund_id)))
                     and p.amount_cents = abs(i2.amount_cents)
                     and (p.kind in ('refund', 'release')) = (i2.amount_cents < 0)
                   order by p.created_at limit 1) as payment_id
            from payout_reconciliation_items i2
           where i2.reconciliation_id = p_reconciliation and i2.status = 'unmatched' and i2.kind in ('charge', 'refund', 'dispute')) m
   where i.id = m.item_id and m.payment_id is not null;
  -- fees and adjustments are the processor's own lines
  update payout_reconciliation_items set status = 'resolved', note = coalesce(note, 'processor ' || kind), matched_at = now()
   where reconciliation_id = p_reconciliation and status = 'unmatched' and kind in ('fee', 'adjustment');

  select count(*) filter (where status = 'unmatched') into v_unmatched from payout_reconciliation_items where reconciliation_id = p_reconciliation;
  v_status := case when v_unmatched > 0 then 'unmatched' when r.status = 'resolved' then 'resolved' else 'matched' end;
  update payout_reconciliations p
     set item_count = (select count(*) from payout_reconciliation_items i where i.reconciliation_id = p.id),
         matched_cents = coalesce((select sum(i.amount_cents) from payout_reconciliation_items i where i.reconciliation_id = p.id and i.status = 'matched'), 0),
         unmatched_cents = coalesce((select sum(abs(i.amount_cents)) from payout_reconciliation_items i where i.reconciliation_id = p.id and i.status = 'unmatched'), 0),
         status = v_status, matched_at = case when v_status = 'matched' then coalesce(p.matched_at, now()) else p.matched_at end
   where p.id = p_reconciliation;

  if v_unmatched > 0 then
    perform app.raise_task(p_type => 'reconcile',
        p_title => format('Payout %s of %s: %s item(s) do not match a payment', r.processor_payout_ref, r.paid_on, v_unmatched),
        p_detail => 'Open the payout, link each item to its payment or explain it. Anything still unmatched escalates to an Admin at the closing check.',
        p_related_table => 'payout_reconciliations', p_related_id => r.id, p_dedupe => 'reconcile:' || r.id);
  else
    update tasks set status = 'done', completed_at = now(), completion_note = 'Payout matched'
     where task_type = 'reconcile' and related_id = r.id and status in ('open', 'in_progress', 'waiting');
  end if;
  return v_status;
end $$;

-- Record a payout and its transactions as fetched from the processor, then match it. Calling it
-- again with the same payout adds any new items and matches again (safe to repeat).
-- p_items: [{ref, payment_ref, kind, amount_cents, fee_cents, occurred_at}]. Returns the payout's id.
create or replace function app.record_processor_payout(p_payout_ref text, p_paid_on date, p_amount_cents bigint, p_items jsonb,
    p_processor text default 'stripe', p_by uuid default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
  x jsonb;
begin
  if btrim(coalesce(p_payout_ref, '')) = '' or p_paid_on is null or p_amount_cents is null then
    raise exception 'A payout needs its reference, its date and its amount' using errcode = '22023';
  end if;
  insert into payout_reconciliations as p (processor, processor_payout_ref, paid_on, amount_cents, created_by)
  values (p_processor, p_payout_ref, p_paid_on, p_amount_cents, p_by)
  on conflict (processor, processor_payout_ref) do update set paid_on = excluded.paid_on, amount_cents = excluded.amount_cents
  returning id into v_id;
  for x in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    if x ->> 'ref' is null or x ->> 'amount_cents' is null then
      raise exception 'A payout item needs its reference and its amount' using errcode = '22023';
    end if;
    insert into payout_reconciliation_items (reconciliation_id, kind, processor_ref, processor_payment_ref, amount_cents, fee_cents, occurred_at)
    values (v_id, coalesce(x ->> 'kind', 'charge'), x ->> 'ref', x ->> 'payment_ref', (x ->> 'amount_cents')::bigint,
            coalesce((x ->> 'fee_cents')::bigint, 0), (x ->> 'occurred_at')::timestamptz)
    on conflict (reconciliation_id, processor_ref) do nothing;
  end loop;
  update payout_reconciliations p
     set fees_cents = coalesce((select sum(i.fee_cents) + coalesce(sum(-i.amount_cents) filter (where i.kind = 'fee'), 0)
                                  from payout_reconciliation_items i where i.reconciliation_id = p.id), 0)
   where p.id = v_id;
  perform app.match_processor_payout(v_id);
  return v_id;
end $$;

-- Finance links an unmatched item to its payment by hand, or explains it (a note is required).
create or replace function app.match_payout_item(p_item uuid, p_by uuid, p_payment uuid default null, p_note text default null) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  i payout_reconciliation_items;
  p payments;
begin
  if not app.user_runs_finance(p_by) then
    raise exception 'Finance or an Admin reconciles payouts' using errcode = '42501';
  end if;
  select * into i from payout_reconciliation_items where id = p_item for update;
  if i.id is null then raise exception 'Payout item % not found', p_item; end if;
  if i.status <> 'unmatched' then
    raise exception 'This item is already %', i.status using errcode = '23514';
  end if;
  if p_payment is not null then
    select * into p from payments where id = p_payment;
    if p.id is null then raise exception 'Payment % not found', p_payment; end if;
    if p.amount_cents <> abs(i.amount_cents) and btrim(coalesce(p_note, '')) = '' then
      raise exception 'The amounts differ (% against % cents): explain the difference in a note', p.amount_cents, abs(i.amount_cents)
        using errcode = '23514';
    end if;
    update payout_reconciliation_items set payment_id = p_payment, status = 'matched', matched_by = p_by, matched_at = now(), note = p_note
     where id = p_item;
  else
    if btrim(coalesce(p_note, '')) = '' then
      raise exception 'Link the item to a payment, or explain it in a note' using errcode = '22023';
    end if;
    -- an item explained without a payment is an Admin's call
    if not app.user_is_admin(p_by) then
      raise exception 'Only an Admin closes a payout item that has no payment' using errcode = '42501';
    end if;
    update payout_reconciliation_items set status = 'resolved', matched_by = p_by, matched_at = now(), note = p_note where id = p_item;
  end if;
  return app.match_processor_payout(i.reconciliation_id);
end $$;

-- ================================================================ 20. scheduled jobs that are pure SQL
-- Same pattern as migration 0015: the wrapper takes the instant to judge by, works out the
-- Toronto day and hour itself and claims a row in job_runs, so a business day runs once.

-- deposits-due, daily from 06:00: Deposits whose balance is due back within the warning window
-- (7 business days after Check-in is the limit), and hold-backs near their last day.
create or replace function app.job_deposits_due(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v_day date := app.local_date(p_now);
  v_set program_settings := app.settings(app.local_date(p_now));
  v_run uuid;
  r record;
  v_due integer := 0; v_overdue integer := 0; v_hold integer := 0;
begin
  if app.local_hour(p_now) < 6 then return 'not_due'; end if;
  v_run := app.job_claim('deposits-due', v_day::text);
  if v_run is null then return 'already_run'; end if;
  begin
    for r in select d.id, d.booking_id, d.release_due_on, d.amount_cents - d.applied_cents - d.released_cents - d.held_back_cents as balance,
                    b.booking_number, b.vehicle_id, b.renter_id
               from deposits d join bookings b on b.id = d.booking_id
              where d.status in ('held', 'captured') and d.release_due_on is not null
                and d.amount_cents - d.applied_cents - d.released_cents - d.held_back_cents > 0
                and d.release_due_on <= app.add_business_days(v_day, v_set.deposit_due_warning_business_days)
    loop
      perform app.raise_task(p_type => 'release_deposit',
          p_title => format('Booking %s: Deposit balance of %s due back by %s', r.booking_number, app.money_text(r.balance), r.release_due_on),
          p_detail => case when r.release_due_on < v_day then 'OVERDUE: the 7 business days after Check-in have passed.'
                           else 'Issue the statement, apply the Charges, hold back what is expected on an open item, release the rest.' end,
          p_booking => r.booking_id, p_vehicle => r.vehicle_id, p_renter => r.renter_id, p_related_table => 'deposits', p_related_id => r.id,
          p_due_at => app.local_midnight(r.release_due_on + 1),
          p_priority => case when r.release_due_on <= v_day then 'urgent' else 'high' end, p_dedupe => 'release_deposit:' || r.id);
      v_due := v_due + 1;
      if r.release_due_on < v_day then v_overdue := v_overdue + 1; end if;
    end loop;
    for r in select d.id, d.booking_id, d.held_back_cents, d.held_back_until, d.held_back_reason, b.booking_number, b.vehicle_id, b.renter_id
               from deposits d join bookings b on b.id = d.booking_id
              where d.held_back_cents > 0 and d.held_back_until is not null
                and d.held_back_until <= v_day + v_set.holdback_warning_days
    loop
      perform app.raise_task(p_type => 'settle_holdback',
          p_title => format('Booking %s: %s held back until %s', r.booking_number, app.money_text(r.held_back_cents), r.held_back_until),
          p_detail => format('Held back for: %s. Apply it or release it by that day.', r.held_back_reason),
          p_booking => r.booking_id, p_vehicle => r.vehicle_id, p_renter => r.renter_id, p_related_table => 'deposits', p_related_id => r.id,
          p_due_at => app.local_midnight(r.held_back_until + 1),
          p_priority => case when r.held_back_until <= v_day then 'urgent' else 'high' end, p_dedupe => 'settle_holdback:' || r.id);
      v_hold := v_hold + 1;
    end loop;
    perform app.job_succeed(v_run, jsonb_build_object('day', v_day, 'deposits_due', v_due, 'overdue', v_overdue, 'holdbacks_due', v_hold));
    return 'succeeded';
  exception when others then
    perform app.job_fail(v_run, sqlerrm);
    return 'failed';
  end;
end $$;

-- ops-watch, every 15 minutes: the tasks that depend on the clock, and waiting tasks whose time
-- has come. It only raises tasks (one per record, by dedupe key): it sends nothing, charges
-- nothing and never disables a car. A run is recorded in job_runs only when it did something.
create or replace function app.job_ops_watch(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v_day date := app.local_date(p_now);
  v_set program_settings := app.settings(app.local_date(p_now));
  v_open time := coalesce((v_set.opening_hours ->> 'open')::time, time '09:00');
  v_close time := coalesce((v_set.opening_hours ->> 'close')::time, time '18:00');
  v_local time := (p_now at time zone 'America/Toronto')::time;
  v_before bigint;
  v_woken integer;
  v_made bigint;
  v_run uuid;
  v_first date;
  v_prep date;
  r record;
begin
  select count(*) into v_before from tasks;
  v_woken := app.wake_tasks(p_now);

  -- an offer about to expire, not approved (Sales when there is a Sales assistant, else customer service)
  for r in select b.id, b.booking_number, b.vehicle_id, b.renter_id, b.offer_expires_at, b.current_offer_version
             from bookings b
            where b.status = 'offered' and b.offer_expires_at > p_now
              and b.offer_expires_at <= p_now + make_interval(hours => v_set.chase_offer_hours)
  loop
    perform app.raise_task(p_type => 'chase_offer', p_title => format('Booking %s: the offer expires soon', r.booking_number),
        p_booking => r.id, p_vehicle => r.vehicle_id, p_renter => r.renter_id, p_due_at => r.offer_expires_at,
        p_dedupe => 'chase_offer:' || r.id || ':' || r.current_offer_version,
        p_queue => case when exists (select 1 from staff_profiles sp join users u on u.id = sp.user_id
                                      where sp.va_function = 'sales' and sp.is_active and u.status = 'active') then 'sales' else 'cs' end);
  end loop;

  -- pickup close, verification or coverage missing
  for r in select b.id, b.booking_number, b.vehicle_id, b.renter_id, b.pickup_at
             from bookings b
            where b.status = 'confirmed' and b.pickup_at > p_now
              and b.pickup_at <= p_now + make_interval(hours => v_set.chase_verification_hours)
              and (exists (select 1 from booking_drivers d where d.booking_id = b.id and d.identity_verified_on is null)
                   or not exists (select 1 from booking_drivers d where d.booking_id = b.id and d.role = 'renter')
                   or (b.booking_type <> 'owner' and b.coverage_confirmed_at is null))
  loop
    perform app.raise_task(p_type => 'chase_verification', p_title => format('Booking %s: verification missing before pickup', r.booking_number),
        p_booking => r.id, p_vehicle => r.vehicle_id, p_renter => r.renter_id,
        p_due_at => greatest(r.pickup_at - make_interval(hours => v_set.verification_due_hours), p_now),
        p_dedupe => 'chase_verification:' || r.id);
  end loop;

  -- pickup today, Deposit not taken
  for r in select b.id, b.booking_number, b.vehicle_id, b.renter_id, b.pickup_at
             from bookings b
            where b.status = 'confirmed' and b.booking_type <> 'owner' and b.deposit_cents > 0
              and app.local_date(b.pickup_at) = v_day
              and not exists (select 1 from deposits d where d.booking_id = b.id and d.status in ('held', 'captured'))
  loop
    perform app.raise_task(p_type => 'take_deposit', p_title => format('Booking %s: take the Deposit before handover', r.booking_number),
        p_booking => r.id, p_vehicle => r.vehicle_id, p_renter => r.renter_id,
        p_due_at => r.pickup_at - make_interval(mins => v_set.take_deposit_lead_minutes), p_dedupe => 'take_deposit:' || r.id);
  end loop;

  -- a rental past its return time; an Admin is told once it is well overdue
  for r in select b.id, b.booking_number, b.vehicle_id, b.renter_id, b.return_at
             from bookings b where b.status = 'on_rent' and b.return_at < p_now
  loop
    perform app.raise_task(p_type => 'late_return', p_title => format('Booking %s: not back at the return time', r.booking_number),
        p_detail => format('Return was due %s (Toronto).', to_char(r.return_at at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI')),
        p_booking => r.id, p_vehicle => r.vehicle_id, p_renter => r.renter_id, p_due_at => r.return_at, p_dedupe => 'late_return:' || r.id);
    if r.return_at <= p_now - make_interval(mins => v_set.late_admin_minutes) then
      perform app.raise_task(p_type => 'late_return_admin', p_title => format('Booking %s: %s minutes overdue', r.booking_number, v_set.late_admin_minutes),
          p_detail => 'Final notice, then an Admin decides on disabling, repossession and police.',
          p_booking => r.id, p_vehicle => r.vehicle_id, p_renter => r.renter_id, p_due_at => p_now, p_dedupe => 'late_return_admin:' || r.id,
          p_escalation_reason => 'rental overdue');
    end if;
  end loop;

  -- a job close to its time with nobody on it, or not acknowledged
  for r in select j.id, j.kind, j.booking_id, j.vehicle_id, j.scheduled_at, j.assigned_to
             from field_jobs j
            where j.status = 'scheduled' and j.scheduled_at > p_now - interval '1 day'
              and j.scheduled_at <= p_now + make_interval(mins => v_set.job_acknowledge_lead_minutes)
  loop
    perform app.raise_task(p_type => 'job_unacknowledged',
        p_title => format('%s job at %s: %s', initcap(replace(r.kind, '_', ' ')), to_char(r.scheduled_at at time zone 'America/Toronto', 'HH24:MI'),
                          case when r.assigned_to is null then 'nobody is assigned' else 'not acknowledged' end),
        p_booking => r.booking_id, p_vehicle => r.vehicle_id, p_related_table => 'field_jobs', p_related_id => r.id,
        p_due_at => r.scheduled_at, p_dedupe => 'job_unacknowledged:' || r.id);
  end loop;

  -- a confirmed booking that does not block the car, with the pickup close
  for r in select b.id, b.booking_number, b.vehicle_id, b.renter_id, b.pickup_at
             from bookings b
            where b.status = 'confirmed' and not b.blocks_calendar and b.pickup_at > p_now
              and b.pickup_at <= p_now + make_interval(days => v_set.provisional_watch_days)
  loop
    perform app.raise_task(p_type => 'insurer_provisional', p_title => format('Booking %s: settle the dates and turn the calendar switch on', r.booking_number),
        p_booking => r.id, p_vehicle => r.vehicle_id, p_renter => r.renter_id, p_due_at => r.pickup_at - interval '1 day',
        p_dedupe => 'insurer_provisional:' || r.id);
  end loop;

  -- the daily checks (procedure 19), an hour before each is due
  if v_local >= v_open - interval '1 hour' and v_local < v_close then
    perform app.raise_task(p_type => 'opening_checks', p_title => format('Opening checks, %s', v_day),
        p_due_at => (v_day + v_open) at time zone 'America/Toronto', p_dedupe => 'opening_checks:' || v_day);
  end if;
  if v_local >= v_close - interval '1 hour' then
    perform app.raise_task(p_type => 'closing_checks', p_title => format('Closing checks, %s', v_day),
        p_due_at => (v_day + v_close) at time zone 'America/Toronto', p_dedupe => 'closing_checks:' || v_day);
  end if;

  -- the franchisor fleet report: the business day before the 1st (procedure 20)
  v_first := (app.month_start(v_day) + interval '1 month')::date;
  v_prep := v_first - 1;
  while not app.is_business_day(v_prep) loop v_prep := v_prep - 1; end loop;
  if v_day = v_prep then
    perform app.raise_task(p_type => 'fleet_report', p_title => format('Fleet report for %s: match it to the broker''s list', to_char(v_first, 'FMMonth YYYY')),
        p_due_at => app.local_midnight(v_first + 1), p_dedupe => 'fleet_report:' || to_char(v_first, 'YYYY-MM'));
  end if;

  select count(*) - v_before into v_made from tasks;
  if v_made = 0 and v_woken = 0 then return 'not_due'; end if;
  v_run := app.job_claim('ops-watch', to_char(p_now at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI"Z"'));
  if v_run is not null then
    perform app.job_succeed(v_run, jsonb_build_object('tasks_raised', v_made, 'tasks_woken', v_woken));
  end if;
  return 'succeeded';
end $$;

-- expiry-watch, daily from 06:00: Turo-Only insurance and plate expiry, the safety certificate
-- window, plate renewals and arrears past the removal date. Raises the tasks and emits the two
-- events the notification layer sends from (the Owner's notice and the staff list).
create or replace function app.job_expiry_watch(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v_day date := app.local_date(p_now);
  v_set program_settings := app.settings(app.local_date(p_now));
  v_run uuid;
  r record;
  v_items jsonb := '[]'::jsonb;
  v_expires date;
begin
  if app.local_hour(p_now) < 6 then return 'not_due'; end if;
  v_run := app.job_claim('expiry-watch', v_day::text);
  if v_run is null then return 'already_run'; end if;
  begin
    for r in select t.id, t.vehicle_id, v.owner_id, v.year || ' ' || v.make || ' ' || v.model as label,
                    t.owner_insurance_expires_on, t.plate_expires_on
               from turo_listings t join vehicles v on v.id = t.vehicle_id
              where t.status in ('listed', 'paused')
                and least(t.owner_insurance_expires_on, t.plate_expires_on) <= v_day + v_set.turo_expiry_notice_days
    loop
      v_expires := least(r.owner_insurance_expires_on, r.plate_expires_on);
      perform app.raise_task(p_type => 'turo_expiry', p_title => format('Turo-Only %s: insurance or plate expires %s', r.label, v_expires),
          p_detail => 'Ask the Owner for renewed proof; unlist the car if proof lapses.', p_vehicle => r.vehicle_id, p_owner => r.owner_id,
          p_related_table => 'turo_listings', p_related_id => r.id, p_due_at => app.local_midnight(v_expires),
          p_dedupe => 'turo_expiry:' || r.id || ':' || v_expires);
      perform app.emit_event('owner_document_due', 'vehicle', r.vehicle_id,
        jsonb_build_object('owner_id', r.owner_id, 'vehicle_name', r.label, 'expires_on', v_expires,
                           'insurance_expires_on', r.owner_insurance_expires_on, 'plate_expires_on', r.plate_expires_on, 'turo_listing_id', r.id),
        'owner_document_due:' || r.vehicle_id || ':' || v_expires);
      v_items := v_items || jsonb_build_object('kind', 'turo_expiry', 'vehicle_id', r.vehicle_id, 'label', r.label, 'expires_on', v_expires);
    end loop;

    for r in select o.id, o.vehicle_id, v.owner_id, v.year || ' ' || v.make || ' ' || v.model as label, o.safety_certificate_expires_on
               from vehicle_onboardings o join vehicles v on v.id = o.vehicle_id
              where o.safety_certificate_expires_on is not null and o.registry_visit_at is null
                and o.status::text not in ('registered', 'tracker_installed', 'on_fleet_policy', 'enrolled', 'declined', 'withdrawn')
                and o.safety_certificate_expires_on <= v_day + v_set.turo_expiry_notice_days
    loop
      perform app.raise_task(p_type => 'safety_certificate_window',
          p_title => format('%s: the safety certificate runs out %s and no registry visit is booked', r.label, r.safety_certificate_expires_on),
          p_vehicle => r.vehicle_id, p_owner => r.owner_id, p_related_table => 'vehicle_onboardings', p_related_id => r.id,
          p_due_at => app.local_midnight(r.safety_certificate_expires_on), p_dedupe => 'safety_certificate_window:' || r.id);
      v_items := v_items || jsonb_build_object('kind', 'safety_certificate', 'vehicle_id', r.vehicle_id, 'label', r.label, 'expires_on', r.safety_certificate_expires_on);
    end loop;

    for r in select distinct on (g.vehicle_id) g.id, g.vehicle_id, v.owner_id, v.year || ' ' || v.make || ' ' || v.model as label, g.plate_renewal_month
               from vehicle_registrations g join vehicles v on v.id = g.vehicle_id
              where g.retransferred_on is null and g.plate_renewal_month is not null
                and v.status::text not in ('exited', 'declined', 'total_loss')
                and g.plate_renewal_month = extract(month from v_day + v_set.plate_renewal_notice_days)::integer
              order by g.vehicle_id, g.registered_on desc
    loop
      perform app.raise_task(p_type => 'plate_renewal', p_title => format('%s: plate renewal due next month', r.label),
          p_vehicle => r.vehicle_id, p_owner => r.owner_id, p_related_table => 'vehicle_registrations', p_related_id => r.id,
          p_due_at => app.local_midnight(app.month_start(v_day + v_set.plate_renewal_notice_days)),
          p_dedupe => 'plate_renewal:' || r.vehicle_id || ':' || to_char(v_day + v_set.plate_renewal_notice_days, 'YYYY-MM'));
      v_items := v_items || jsonb_build_object('kind', 'plate_renewal', 'vehicle_id', r.vehicle_id, 'label', r.label);
    end loop;

    for r in select i.id, i.invoice_number, i.owner_id, i.vehicle_id, i.balance_cents, i.removal_allowed_on
               from owner_invoices i
              where i.status = 'in_arrears' and i.removal_allowed_on is not null and i.removal_allowed_on <= v_day
    loop
      perform app.raise_task(p_type => 'arrears_removal',
          p_title => format('Invoice %s unpaid since the failed retry: the vehicle may be removed', r.invoice_number),
          p_detail => format('Balance %s. Removal allowed from %s (procedure 14).', app.money_text(r.balance_cents), r.removal_allowed_on),
          p_vehicle => r.vehicle_id, p_owner => r.owner_id, p_related_table => 'owner_invoices', p_related_id => r.id,
          p_dedupe => 'arrears_removal:' || r.id, p_escalation_reason => 'arrears past the removal date');
      v_items := v_items || jsonb_build_object('kind', 'arrears', 'vehicle_id', r.vehicle_id, 'invoice_number', r.invoice_number);
    end loop;

    if jsonb_array_length(v_items) > 0 then
      perform app.emit_event('staff_expiry_watch', 'job_run', v_run,
        jsonb_build_object('day', v_day, 'expiry_count', jsonb_array_length(v_items), 'expiry_items', v_items),
        'staff_expiry_watch:' || v_run || ':' || v_day);
    end if;
    perform app.job_succeed(v_run, jsonb_build_object('day', v_day, 'items', jsonb_array_length(v_items)));
    return 'succeeded';
  exception when others then
    perform app.job_fail(v_run, sqlerrm);
    return 'failed';
  end;
end $$;

-- reconcile, daily from 18:00: match every payout that is still open again (payments may have
-- arrived since), and flag card payments that no payout has carried after the usual delay.
-- Fetching the payouts from the processor is the server's part and happens before this.
create or replace function app.job_reconcile(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v_day date := app.local_date(p_now);
  v_set program_settings := app.settings(app.local_date(p_now));
  v_run uuid;
  r record;
  v_open integer := 0; v_still integer := 0; v_orphans integer := 0;
  v_cutoff date;
  v_n integer := 0;
begin
  if app.local_hour(p_now) < 18 then return 'not_due'; end if;
  v_run := app.job_claim('reconcile', v_day::text);
  if v_run is null then return 'already_run'; end if;
  begin
    for r in select id from payout_reconciliations where status in ('open', 'unmatched') order by paid_on, id loop
      v_open := v_open + 1;
      if app.match_processor_payout(r.id) = 'unmatched' then v_still := v_still + 1; end if;
    end loop;
    -- the day that many business days back
    v_cutoff := v_day;
    while v_n < v_set.payout_unmatched_business_days loop
      v_cutoff := v_cutoff - 1;
      if app.is_business_day(v_cutoff) then v_n := v_n + 1; end if;
    end loop;
    for r in select p.id, p.booking_id, p.amount_cents, p.processed_at
               from payments p
              where p.status = 'succeeded' and p.method = 'card' and p.kind in ('charge', 'capture')
                and p.processed_at is not null and app.local_date(p.processed_at) <= v_cutoff
                and exists (select 1 from payout_reconciliations x)                -- only once payouts are being recorded
                and p.processed_at >= (select min(x.created_at) from payout_reconciliations x) - interval '30 days'
                and not exists (select 1 from payout_reconciliation_items i where i.payment_id = p.id)
    loop
      perform app.raise_task(p_type => 'unmatched_payment',
          p_title => format('Card payment of %s not found in any payout', app.money_text(r.amount_cents)),
          p_detail => format('Paid %s (Toronto); no processor payout has carried it yet.', to_char(r.processed_at at time zone 'America/Toronto', 'YYYY-MM-DD')),
          p_booking => r.booking_id, p_related_table => 'payments', p_related_id => r.id, p_dedupe => 'unmatched_payment:' || r.id);
      v_orphans := v_orphans + 1;
    end loop;
    perform app.job_succeed(v_run, jsonb_build_object('day', v_day, 'payouts_checked', v_open, 'payouts_unmatched', v_still, 'payments_without_payout', v_orphans));
    return 'succeeded';
  exception when others then
    perform app.job_fail(v_run, sqlerrm);
    return 'failed';
  end;
end $$;

-- ================================================================ 21. work queues
-- The open work of the caller's queues: an Admin sees every queue, an assistant the queue of
-- their own function and anything assigned to them. Ordered by the screen: priority, then due.
-- The renter appears by first name only; the record itself is opened from the task.
create view work_queue with (security_barrier = true) as
  select t.id as task_id, t.queue, t.task_type, t.title, t.detail, t.procedure_no, t.priority,
         case t.priority when 'urgent' then 1 when 'high' then 2 when 'normal' then 3 else 4 end as priority_rank,
         t.status, t.due_at, t.sla_minutes, (t.due_at is not null and t.due_at < now()) as is_overdue,
         t.created_at, t.assigned_to, u.full_name as assignee_name,
         case when t.status = 'waiting' then 'waiting' when t.assigned_to = app.uid() then 'mine'
              when t.assigned_to is null then 'unassigned' else 'others' end as bucket,
         t.wake_at, t.waiting_reason, t.escalated, t.escalation_reason, t.completion_rule,
         t.booking_id, b.booking_number, t.vehicle_id, v.plate, v.year || ' ' || v.make || ' ' || v.model as vehicle_label,
         t.owner_id, o.legal_name as owner_name, t.renter_id, split_part(btrim(r.legal_name), ' ', 1) as renter_first_name,
         t.related_table, t.related_id
    from tasks t
    left join users u on u.id = t.assigned_to
    left join bookings b on b.id = t.booking_id
    left join vehicles v on v.id = t.vehicle_id
    left join owners o on o.id = t.owner_id
    left join renters r on r.id = t.renter_id
   where t.status in ('open', 'in_progress', 'waiting')
     and (app.is_admin() or (app.is_va() and (t.assigned_to = app.uid() or app.va_has(t.queue))));

create view va_finance_queue with (security_barrier = true) as
  select * from work_queue where queue = 'finance' and (app.is_admin() or app.va_has('finance'));
create view va_fleet_queue with (security_barrier = true) as
  select * from work_queue where queue = 'fleet' and (app.is_admin() or app.va_has('fleet'));
create view va_cs_queue with (security_barrier = true) as
  select * from work_queue where queue = 'cs' and (app.is_admin() or app.va_has('cs'));
create view va_sales_queue with (security_barrier = true) as
  select * from work_queue where queue = 'sales' and (app.is_admin() or app.va_has('sales'));
create view admin_queue with (security_barrier = true) as
  select * from work_queue where queue = 'admin' and app.is_admin();

-- ================================================================ 22. row-level security
do $$
declare
  t text;
begin
  foreach t in array array['required_shots', 'vehicle_moves', 'task_rules', 'quick_replies', 'incident_steps',
                           'payout_reconciliations', 'payout_reconciliation_items'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy admin_all on public.%I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
  end loop;
end $$;

-- reference lists: the photo list is read by anyone who fills a Condition Report; the task rules
-- and quick replies by staff. Only an Admin changes them.
create policy read_all on required_shots for select to authenticated using (true);
create policy va_read on task_rules for select to authenticated using (app.is_va());
create policy va_read on quick_replies for select to authenticated using (app.is_va() and is_active);

-- vehicle moves: Fleet records and corrects them; Finance reads them (proof for tolls and
-- tickets); a field staff member sees the moves they drove. Owners and renters see none.
create policy fleet_read on vehicle_moves for select to authenticated using (app.va_has('fleet', 'finance'));
create policy fleet_insert on vehicle_moves for insert to authenticated with check (app.va_has('fleet') and created_by = app.uid());
create policy fleet_update on vehicle_moves for update to authenticated using (app.va_has('fleet')) with check (app.va_has('fleet'));
create policy field_read on vehicle_moves for select to authenticated using (staff_user_id = app.uid() and app.is_field());

-- incident steps follow the incident: Fleet works them, customer service and Finance read them
create policy va_read on incident_steps for select to authenticated using (app.va_has('fleet', 'cs', 'finance'));
create policy fleet_update on incident_steps for update to authenticated
  using (app.va_has('fleet') and owner_role <> 'admin') with check (app.va_has('fleet') and owner_role <> 'admin');
create trigger incident_steps_guard_approver before update on incident_steps
  for each row execute function app.guard_approver('done_by');

-- reconciliation: Finance reads the payouts and their items; linking an item goes through
-- app.match_payout_item() on the server
create policy finance_read on payout_reconciliations for select to authenticated using (app.va_has('finance'));
create policy finance_read on payout_reconciliation_items for select to authenticated using (app.va_has('finance'));

-- the swap record is part of the toll confirm screen and the booking's history: already readable
-- by customer service, finance and fleet (migration 0012). Nothing to add.

-- ================================================================ 23. privileges
revoke all on required_shots, vehicle_moves, task_rules, quick_replies, incident_steps, payout_reconciliations, payout_reconciliation_items,
  field_job_list, work_queue, va_finance_queue, va_fleet_queue, va_cs_queue, va_sales_queue, admin_queue
  from anon, authenticated;
grant select, insert, update on required_shots, task_rules, quick_replies, vehicle_moves to authenticated;
grant select, update on incident_steps to authenticated;
-- written by the server only
grant select on payout_reconciliations, payout_reconciliation_items to authenticated;
grant select on field_job_list, work_queue, va_finance_queue, va_fleet_queue, va_cs_queue, va_sales_queue, admin_queue, calendar_entries to authenticated;
grant all on required_shots, vehicle_moves, task_rules, quick_replies, incident_steps, payout_reconciliations, payout_reconciliation_items,
  field_job_list, work_queue, va_finance_queue, va_fleet_queue, va_cs_queue, va_sales_queue, admin_queue, calendar_entries
  to service_role;
grant usage on sequence renter_statement_number_seq to service_role;

-- Functions: closed to everyone, then opened one by one. Everything that changes state, moves
-- money or raises work is for the server alone.
do $$
declare
  f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in (
              'user_va_has', 'user_is_field', 'user_runs_fleet', 'user_runs_finance', 'from_browser', 'add_opening_minutes',
              'required_shots_for', 'condition_report_problems', 'start_vehicle_move', 'end_vehicle_move',
              'task_due', 'task_fill_from_rule', 'raise_task', 'resolve_tasks', 'user_works_queue', 'task_completion_problem',
              'assign_task', 'snooze_task', 'wake_tasks', 'complete_task', 'cancel_task', 'escalate_task',
              'field_job_is_move', 'create_field_job', 'assign_field_job', 'reschedule_field_job', 'accept_field_job', 'start_field_job',
              'complete_field_job', 'cancel_field_job', 'field_job_after_write', 'staff_field_jobs',
              'booking_fee_term', 'snapshot_booking_fee_terms', 'set_booking_fee_term',
              'condition_report_actor', 'save_condition_report', 'record_deposit_taken', 'record_deposit_declined', 'waive_deposit',
              'complete_handover', 'block_handover', 'booking_km_driven', 'return_findings', 'complete_return',
              'submit_return_findings', 'review_condition_report', 'condition_report_after_write', 'report_damage_to_renter', 'record_late_damage',
              'money_text', 'open_incident', 'complete_incident_step', 'incident_after_insert', 'swap_vehicle', 'complete_condition_report',
              'request_tracker_disable', 'approve_tracker_disable', 'reject_tracker_disable', 'tracker_command_task',
              'set_assessed_line', 'assess_check_in', 'issue_booking_statement', 'settle_deposit', 'post_rental_payment_result',
              'ops_booking_status_after', 'ops_task_trigger', 'master_calendar', 'vehicle_calendar', 'calendar_preview_change', 'calendar_apply_change',
              'set_rate_card', 'set_vehicle_fee_override', 'end_vehicle_fee_override', 'bulk_rate_vehicles', 'preview_bulk_rate_change', 'apply_bulk_rate_change',
              'match_processor_payout', 'record_processor_payout', 'match_payout_item',
              'job_deposits_due', 'job_ops_watch', 'job_expiry_watch', 'job_reconcile')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;
grant execute on all functions in schema app to service_role;
-- what a browser session may call: read-only helpers and the calendars. Each checks the caller.
grant execute on function app.from_browser(), app.add_opening_minutes(timestamptz, integer), app.money_text(bigint),
  app.required_shots_for(text, vehicle_class), app.field_job_is_move(text) to authenticated;
grant execute on function app.master_calendar(timestamptz, timestamptz), app.vehicle_calendar(uuid, timestamptz, timestamptz),
  app.calendar_preview_change(uuid, jsonb, timestamptz), app.staff_field_jobs(uuid, date) to authenticated;

-- ================================================================ 24. audit
do $$ begin perform app.attach_audit(); end $$;

-- ================================================================ 25. the schedule (pg_cron) and live updates
-- Same pattern as migration 0015: nothing where pg_cron is absent.
do $$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron is not available here: no jobs scheduled';
    return;
  end if;
  begin
    create extension if not exists pg_cron;
  exception when others then
    raise warning 'pg_cron could not be created in this database (%): no jobs scheduled', sqlerrm;
    return;
  end;
  perform cron.schedule('carmacars-deposits-due', '12 * * * *',   'select app.job_deposits_due()');
  perform cron.schedule('carmacars-expiry-watch', '14 * * * *',   'select app.job_expiry_watch()');
  perform cron.schedule('carmacars-reconcile',    '16 * * * *',   'select app.job_reconcile()');
  perform cron.schedule('carmacars-ops-watch',    '*/15 * * * *', 'select app.job_ops_watch()');
end $$;

-- Live calendar and queues: add the tables to Supabase's Realtime publication where it exists
-- (row-level security applies to Realtime). Does nothing on a plain PostgreSQL database.
do $$
declare
  t text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    return;
  end if;
  foreach t in array array['bookings', 'vehicle_calendar_blocks', 'field_jobs', 'tasks', 'vehicle_moves'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
