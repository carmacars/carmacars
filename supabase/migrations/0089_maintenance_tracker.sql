-- 0089: the maintenance and service tracker (October 21, 2026).
--
-- The owner: "We need a maintenance and service tracker for every car so we can track when the last oil changes were and
-- brakes and tires and if they're on summers or all seasons or winters. When service stuff is done and billed, it should
-- auto update the status of each car and reset the timers and reminders for service."
--
--   1. Service items with intervals (Admin settings; by class and by car): oil and filter, tire rotation, brakes, tires,
--      the seasonal tire swap (Ontario dates), safety inspection, registration (plate sticker), battery, wipers, filters,
--      alignment, fluids, annual inspection. Each car keeps, per item: last done (date, km), next due by date and/or km
--      (whichever first), the date the km projection gives, and the status (ok, due soon, overdue, unknown).
--   2. Tire sets per car (summer, all-season, winter, all-weather), the set on the car, swaps.
--   3. Odometer readings from everything the system already gets (handover and return reports, field staff moves, the
--      rental's odometer out and in, listing photos, the car record, services, a manual reading), and km a day from them.
--   4. Recording a service in one step: items, date, odometer, shop, cost, receipt, who pays, billed. It creates or links
--      the bill (a company expense, an owner cost on the owner's statement, a claim cost, or a post-rental charge to the
--      renter) and resets each item's timer. An expense entered under a service category does the same.
--   5. Reminders: one Fleet task per car with what is due, a To do line, one morning digest line; no other email.
--      Handover is refused while the safety inspection or the registration has expired (on by default); "block new bookings
--      when overdue" per item (off by default).
--   6. Reads for the fleet overview, the car's Maintenance tab (Admin and Fleet), the owner's service history.
--   7. Backfill: every real car gets its items ("unknown, record the last service") and one task to enter them.
--   8. The winter tire add-on follows the tires: offered on a car with a winter set, or with no tire record yet.

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists maint_due_soon_km integer not null default 1000 check (maint_due_soon_km between 0 and 20000),
  add column if not exists maint_due_soon_days integer not null default 14 check (maint_due_soon_days between 0 and 120),
  add column if not exists maint_default_km_per_day integer not null default 60 check (maint_default_km_per_day between 0 and 1000),
  add column if not exists maint_km_per_day_window_days integer not null default 90 check (maint_km_per_day_window_days between 14 and 730),
  add column if not exists maint_winter_on_reminder text not null default '11-01' check (maint_winter_on_reminder ~ '^(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$'),
  add column if not exists maint_winter_on_by text not null default '12-01' check (maint_winter_on_by ~ '^(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$'),
  add column if not exists maint_winter_off_from text not null default '04-01' check (maint_winter_off_from ~ '^(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$'),
  add column if not exists maint_winter_off_by text not null default '05-01' check (maint_winter_off_by ~ '^(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$'),
  add column if not exists maint_tire_replace_mm numeric(3,1) not null default 3.0 check (maint_tire_replace_mm between 1.0 and 8.0),
  add column if not exists maint_tire_soon_mm numeric(3,1) not null default 4.0 check (maint_tire_soon_mm between 1.0 and 10.0),
  add column if not exists maint_tasks_enabled boolean not null default true,
  add column if not exists maint_digest_enabled boolean not null default true,
  add column if not exists maint_winter_addon_link boolean not null default true;

comment on column program_settings.maint_due_soon_km is 'Maintenance (0089): an item is due soon this many km before it is due (an item may set its own)';
comment on column program_settings.maint_due_soon_days is 'Maintenance (0089): an item is due soon this many days before it is due (an item may set its own)';
comment on column program_settings.maint_default_km_per_day is 'Maintenance (0089): km a day assumed for a car with no readings or rentals yet';
comment on column program_settings.maint_km_per_day_window_days is 'Maintenance (0089): the days of odometer readings the km a day is worked out from';
comment on column program_settings.maint_winter_on_reminder is 'Maintenance (0089): MM-DD, the reminder to put winter tires on starts (Ontario: early November)';
comment on column program_settings.maint_winter_on_by is 'Maintenance (0089): MM-DD, winter tires on by this day (December 1)';
comment on column program_settings.maint_winter_off_from is 'Maintenance (0089): MM-DD, winter tires may come off from this day (April 1); the reminder starts';
comment on column program_settings.maint_winter_off_by is 'Maintenance (0089): MM-DD, winter tires still on after this day are overdue to come off';
comment on column program_settings.maint_tire_replace_mm is 'Maintenance (0089): tread depth (mm) at or under which tires are overdue for replacement';
comment on column program_settings.maint_tire_soon_mm is 'Maintenance (0089): tread depth (mm) at or under which tires are due soon';
comment on column program_settings.maint_tasks_enabled is 'Maintenance (0089): one Fleet task per car with what is due, and one to record the last service of a car with none';
comment on column program_settings.maint_digest_enabled is 'Maintenance (0089): one line in the Admin''s and Fleet''s morning digest (no other email)';
comment on column program_settings.maint_winter_addon_link is 'Maintenance (0089): the Winter tires add-on is offered only on cars with a winter set (or no tire record yet)';

-- ================================================================ 2. tables
create table service_items (
  code                        text primary key check (code ~ '^[a-z][a-z0-9_]{1,40}$'),
  label                       text not null,
  kind                        text not null check (kind in ('interval', 'record', 'expiry', 'tires', 'seasonal')),
  interval_km                 integer check (interval_km between 0 and 500000),
  interval_months             integer check (interval_months between 0 and 240),
  due_soon_km                 integer check (due_soon_km between 0 and 50000),
  due_soon_days               integer check (due_soon_days between 0 and 365),
  block_bookings_when_overdue boolean not null default false,
  block_handover_when_expired boolean not null default false,
  excluded_fuels              fuel_type[] not null default '{}',
  active                      boolean not null default true,
  sort_order                  integer not null default 100,
  help                        text,
  updated_at                  timestamptz not null default now(),
  updated_by                  uuid references users (id)
);
comment on table service_items is 'Maintenance (0089): the service items and their default intervals (Admin > Settings > Maintenance). A km or month interval of 0 or empty means none. Whichever comes first is due.';

create table service_item_rules (
  id                          uuid primary key default gen_random_uuid(),
  item_code                   text not null references service_items (code) on delete cascade,
  vehicle_class               vehicle_class,
  vehicle_id                  uuid references vehicles (id) on delete cascade,
  interval_km                 integer check (interval_km between 0 and 500000),
  interval_months             integer check (interval_months between 0 and 240),
  due_soon_km                 integer check (due_soon_km between 0 and 50000),
  due_soon_days               integer check (due_soon_days between 0 and 365),
  block_bookings_when_overdue boolean,
  active                      boolean,
  note                        text,
  updated_at                  timestamptz not null default now(),
  updated_by                  uuid references users (id),
  check (num_nonnulls(vehicle_class, vehicle_id) = 1)
);
create unique index service_item_rules_class on service_item_rules (item_code, vehicle_class) where vehicle_class is not null;
create unique index service_item_rules_car on service_item_rules (item_code, vehicle_id) where vehicle_id is not null;
comment on table service_item_rules is 'Maintenance (0089): an item''s interval for a class or one car; empty fields follow the class, then the default (car before class before default).';

create table vehicle_tire_sets (
  id                uuid primary key default gen_random_uuid(),
  vehicle_id        uuid not null references vehicles (id) on delete cascade,
  season            text not null check (season in ('summer', 'all_season', 'winter', 'all_weather')),
  size              text check (length(size) <= 40),
  brand             text check (length(brand) <= 60),
  model             text check (length(model) <= 60),
  tread_mm          numeric(3,1) check (tread_mm between 0 and 20),
  tread_measured_on date,
  made_on           date,
  purchased_on      date,
  storage_location  text check (length(storage_location) <= 200),
  on_car            boolean not null default false,
  retired_on        date,
  retired_reason    text,
  notes             text,
  created_by        uuid references users (id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create unique index vehicle_tire_sets_one_on_car on vehicle_tire_sets (vehicle_id) where on_car and retired_on is null;
create index vehicle_tire_sets_vehicle on vehicle_tire_sets (vehicle_id);
comment on table vehicle_tire_sets is 'Maintenance (0089): a car''s tire sets: season, size, brand, tread depth, made (DOT) and purchase dates, where it is stored, and the set on the car.';

create table vehicle_odometer_readings (
  id          uuid primary key default gen_random_uuid(),
  vehicle_id  uuid not null references vehicles (id) on delete cascade,
  read_at     timestamptz not null default now(),
  km          integer not null check (km between 1 and 2000000),
  source      text not null check (source in ('handover', 'return', 'condition_report', 'move', 'rental', 'listing', 'car', 'service', 'manual')),
  source_id   uuid,
  created_by  uuid references users (id),
  created_at  timestamptz not null default now(),
  voided_at   timestamptz,
  voided_by   uuid references users (id),
  void_reason text
);
create unique index vehicle_odometer_readings_source on vehicle_odometer_readings (vehicle_id, source, source_id) where source_id is not null;
create index vehicle_odometer_readings_vehicle on vehicle_odometer_readings (vehicle_id, read_at desc);
comment on table vehicle_odometer_readings is 'Maintenance (0089): every odometer reading the system gets (handover, return, moves, the rental, listing, the car record, services, by hand). The current odometer is the highest reading not voided; km a day comes from the readings.';

create table vehicle_service_records (
  id                   uuid primary key default gen_random_uuid(),
  vehicle_id           uuid not null references vehicles (id) on delete cascade,
  done_on              date not null,
  odometer_km          integer check (odometer_km between 0 and 2000000),
  odometer_estimated   boolean not null default false,
  shop                 text check (length(shop) <= 200),
  notes                text check (length(notes) <= 2000),
  cost_cents           bigint not null default 0 check (cost_cents >= 0),
  hst_cents            bigint not null default 0 check (hst_cents >= 0),
  payer                text not null check (payer in ('company', 'owner', 'claim', 'renter', 'none')),
  billing_status       text not null check (billing_status in ('billed', 'not_billed', 'needs_admin', 'no_charge')),
  company_expense_id   uuid references company_expenses (id),
  owner_deduction_id   uuid references owner_deductions (id),
  claim_id             uuid references claims (id),
  claim_entry_id       uuid references claim_ledger_entries (id),
  booking_id           uuid references bookings (id),
  booking_line_item_id uuid references booking_line_items (id),
  receipt_document_id  uuid references documents (id),
  source               text not null default 'manual' check (source in ('manual', 'expense')),
  created_by           uuid references users (id),
  created_at           timestamptz not null default now(),
  billed_at            timestamptz,
  billed_by            uuid references users (id),
  voided_at            timestamptz,
  voided_by            uuid references users (id),
  void_reason          text
);
create index vehicle_service_records_vehicle on vehicle_service_records (vehicle_id, done_on desc);
create unique index vehicle_service_records_expense on vehicle_service_records (company_expense_id) where company_expense_id is not null and voided_at is null;
comment on table vehicle_service_records is 'Maintenance (0089): a service done on a car (one or more items), with its bill: a company expense, an owner cost on the owner''s statement, a claim cost, or a post-rental charge to the renter.';

create table vehicle_service_record_items (
  record_id   uuid not null references vehicle_service_records (id) on delete cascade,
  item_code   text not null references service_items (code),
  expires_on  date,
  tread_mm    numeric(3,1) check (tread_mm between 0 and 20),
  tire_set_id uuid references vehicle_tire_sets (id),
  primary key (record_id, item_code)
);
comment on table vehicle_service_record_items is 'Maintenance (0089): the items a service record covers, with an expiry date (inspection, registration), a tread depth or the tire set put on.';

create table vehicle_service_items (
  vehicle_id        uuid not null references vehicles (id) on delete cascade,
  item_code         text not null references service_items (code) on delete cascade,
  last_done_on      date,
  last_done_km      integer,
  last_record_id    uuid references vehicle_service_records (id) on delete set null,
  expires_on        date,
  expires_source    text check (expires_source in ('record', 'manual', 'renewal_month', 'turo')),
  next_due_on       date,
  next_due_km       integer,
  projected_due_on  date,
  status            text not null default 'unknown' check (status in ('ok', 'due_soon', 'overdue', 'unknown', 'none', 'off')),
  detail            text,
  status_changed_at timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  primary key (vehicle_id, item_code)
);
create index vehicle_service_items_status on vehicle_service_items (status) where status in ('overdue', 'due_soon', 'unknown');
comment on table vehicle_service_items is 'Maintenance (0089): each car''s state per item: last done, next due by date and km, the date the km projection gives, the status. Kept up to date by app.maint_refresh.';

create table vehicle_tire_swaps (
  id          uuid primary key default gen_random_uuid(),
  vehicle_id  uuid not null references vehicles (id) on delete cascade,
  from_set_id uuid references vehicle_tire_sets (id),
  to_set_id   uuid not null references vehicle_tire_sets (id),
  swapped_on  date not null,
  odometer_km integer,
  record_id   uuid references vehicle_service_records (id) on delete set null,
  created_by  uuid references users (id),
  created_at  timestamptz not null default now()
);
create index vehicle_tire_swaps_vehicle on vehicle_tire_swaps (vehicle_id, swapped_on desc);
comment on table vehicle_tire_swaps is 'Maintenance (0089): the swap history of a car''s tire sets.';

create table maintenance_categories (
  category_code text primary key references company_expense_categories (code) on delete cascade,
  item_codes    text[] not null default '{}',
  updated_at    timestamptz not null default now(),
  updated_by    uuid references users (id)
);
comment on table maintenance_categories is 'Maintenance (0089): the expense categories that are a service: an expense with a car in one of them records a service of these items (and a service recorded here is entered under the matching category).';

do $$
declare t text;
begin
  foreach t in array array['service_items', 'service_item_rules', 'vehicle_tire_sets', 'vehicle_odometer_readings', 'vehicle_service_records',
                           'vehicle_service_record_items', 'vehicle_service_items', 'vehicle_tire_swaps', 'maintenance_categories'] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
    execute format('revoke all on %I from anon, authenticated', t);
    execute format('create trigger audit_%s after insert or update or delete on %I for each row execute function app.audit_row()', t, t);
  end loop;
end $$;

-- ================================================================ 3. reference rows
insert into service_items (code, label, kind, interval_km, interval_months, due_soon_km, due_soon_days, block_handover_when_expired, excluded_fuels, sort_order, help) values
  ('oil_filter', 'Oil and filter', 'interval', 8000, 6, null, null, false, '{electric}', 10, 'Engine oil and oil filter. 8,000 km or 6 months, whichever first.'),
  ('tire_rotation', 'Tire rotation', 'interval', 10000, null, null, null, false, '{}', 20, 'Rotate the tires on the car every 10,000 km.'),
  ('brake_inspection', 'Brake inspection', 'interval', 20000, 12, null, null, false, '{}', 30, 'Pads, rotors, calipers and brake fluid checked. 20,000 km or 12 months.'),
  ('brake_pads_rotors', 'Brake pads and rotors', 'record', null, null, null, null, false, '{}', 40, 'Recorded when replaced. Set an interval here if you want a reminder.'),
  ('tires', 'Tires: tread and age', 'tires', null, 72, null, 180, false, '{}', 50, 'From the set on the car: due soon at 4 mm of tread or 5.5 years old, overdue at 3 mm or 6 years. Record new tires when replaced.'),
  ('seasonal_swap', 'Seasonal tire swap', 'seasonal', null, null, null, null, false, '{}', 60, 'Ontario: winter tires on by December 1 (reminder from early November), off after April 1 (reminder from early April). All-weather tires need no swap.'),
  ('safety_certificate', 'Safety inspection or certificate', 'expiry', null, 12, null, 30, true, '{}', 70, 'The expiry date of the current safety inspection or certificate. Handover is refused once it has expired.'),
  ('registration', 'Registration and plate sticker', 'expiry', null, 12, null, 30, true, '{}', 80, 'The plate sticker''s expiry. From the plate renewal month until a renewal is recorded. Handover is refused once a recorded expiry has passed.'),
  ('battery', 'Battery', 'interval', null, 48, null, 30, false, '{}', 90, 'Tested or replaced. 4 years.'),
  ('wipers', 'Wiper blades', 'interval', null, 12, null, null, false, '{}', 100, 'Every 12 months, before winter.'),
  ('cabin_filter', 'Cabin air filter', 'interval', 24000, 12, null, null, false, '{}', 110, '24,000 km or 12 months.'),
  ('engine_air_filter', 'Engine air filter', 'interval', 30000, 24, null, null, false, '{electric}', 120, '30,000 km or 24 months.'),
  ('alignment', 'Wheel alignment', 'interval', 20000, 12, null, null, false, '{}', 130, 'Checked every 20,000 km or 12 months, and after hitting a curb or a pothole.'),
  ('fluids', 'Fluids check', 'interval', 8000, 6, null, null, false, '{}', 140, 'Coolant, brake, transmission and washer fluids topped up or changed.'),
  ('annual_inspection', 'Annual inspection', 'interval', null, 12, null, 30, false, '{}', 150, 'A full multi-point inspection once a year.');

insert into company_expense_categories (code, label, gl_account, is_active) values
  ('maint_service', 'Car maintenance and service', '5100', true),
  ('maint_oil', 'Car service: oil change', '5100', true),
  ('maint_tires', 'Car service: tires (new tires)', '5100', true),
  ('maint_tire_service', 'Car service: tire rotation or seasonal swap', '5100', true),
  ('maint_brakes', 'Car service: brakes', '5100', true),
  ('maint_inspection', 'Car service: safety or annual inspection', '5100', true),
  ('maint_registration', 'Car registration and plate sticker', '5100', true),
  ('maint_battery', 'Car service: battery', '5100', true)
on conflict (code) do nothing;

insert into maintenance_categories (category_code, item_codes) values
  ('maint_service', '{}'), ('maint_oil', '{oil_filter,fluids}'), ('maint_tires', '{tires}'), ('maint_tire_service', '{tire_rotation}'),
  ('maint_brakes', '{brake_inspection,brake_pads_rotors}'), ('maint_inspection', '{safety_certificate,annual_inspection}'),
  ('maint_registration', '{registration}'), ('maint_battery', '{battery}');

alter table owner_deductions drop constraint if exists owner_deductions_kind_check;
alter table owner_deductions add constraint owner_deductions_kind_check check (kind in ('plate_renewal', 'owner_booking_toll', 'owner_booking_ticket',
  'lender_handover_cost', 'claim_shortfall', 'owner_booking_deductible', 'retransfer_fee', 'refund_share', 'chargeback_share', 'kickback_reversal',
  'agreed_in_writing', 'staff_commission_adjustment', 'maintenance'));

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, description) values
  ('maintenance_due', 'fleet', 'Service due', 'normal', 'none', null, 'A car has a service item due soon or overdue (Maintenance). Book it, then record it: the timers reset.'),
  ('maintenance_backfill', 'fleet', 'Record the last service', 'low', 'none', null, 'A car has service items with no record yet. Enter the last oil change, brakes, tires and so on once, so the reminders know when they are due.'),
  ('maintenance_bill', 'admin', 'A service to bill', 'normal', 'none', null, 'A service was recorded above the assistant''s single limit: an Admin bills it (company expense, owner cost, claim or renter).')
on conflict (task_type) do update set queue = excluded.queue, title = excluded.title, priority = excluded.priority, description = excluded.description;

-- ================================================================ 4. the rules and the numbers
create or replace function app.maint_tracked(v vehicles) returns boolean
language sql immutable as $$
  select not coalesce(v.is_sample, false) and v.retired_at is null and v.status::text not in ('exited', 'total_loss', 'declined')
$$;

-- MM-DD in a year (February 29 falls back to the 28th)
create or replace function app.maint_md(p_md text, p_year integer) returns date
language sql immutable as $$
  select make_date(p_year, split_part(p_md, '-', 1)::integer,
                   least(split_part(p_md, '-', 2)::integer, extract(day from (make_date(p_year, split_part(p_md, '-', 1)::integer, 1) + interval '1 month - 1 day'))::integer))
$$;

create or replace function app.maint_km_text(p_km numeric) returns text
language sql immutable as $$ select to_char(round(p_km), 'FM999,999,999') || ' km' $$;
create or replace function app.maint_date_text(p_on date) returns text
language sql immutable as $$ select to_char(p_on, 'Mon FMDD, YYYY') $$;

-- The effective settings of every item for one car: the car's rule, else the class's, else the default.
create or replace function app.maint_rules(p_vehicle uuid)
returns table (code text, label text, kind text, interval_km integer, interval_months integer, soon_km integer, soon_days integer,
               block_bookings boolean, block_handover boolean, active boolean, sort_order integer, rule_source text)
language sql stable security definer set search_path = public, app as $$
  select i.code, i.label, i.kind,
         nullif(coalesce(c.interval_km, k.interval_km, i.interval_km), 0),
         nullif(coalesce(c.interval_months, k.interval_months, i.interval_months), 0),
         coalesce(c.due_soon_km, k.due_soon_km, i.due_soon_km),
         coalesce(c.due_soon_days, k.due_soon_days, i.due_soon_days),
         coalesce(c.block_bookings_when_overdue, k.block_bookings_when_overdue, i.block_bookings_when_overdue),
         i.block_handover_when_expired,
         coalesce(c.active, k.active, i.active) and not (v.fuel is not null and v.fuel = any (i.excluded_fuels)),
         i.sort_order,
         case when c.id is not null then 'car' when k.id is not null then 'class' else 'default' end
    from service_items i
    join vehicles v on v.id = p_vehicle
    left join service_item_rules k on k.item_code = i.code and k.vehicle_class = v.class
    left join service_item_rules c on c.item_code = i.code and c.vehicle_id = v.id
   order by i.sort_order, i.code
$$;

create or replace function app.maint_current_km(p_vehicle uuid) returns integer
language sql stable security definer set search_path = public, app as $$
  select nullif(greatest(coalesce((select odometer_km from vehicles where id = p_vehicle), 0),
                         coalesce((select max(km) from vehicle_odometer_readings where vehicle_id = p_vehicle and voided_at is null), 0)), 0)
$$;

-- The odometer on a day: the last reading up to the end of that day.
create or replace function app.maint_km_at(p_vehicle uuid, p_on date) returns integer
language sql stable security definer set search_path = public, app as $$
  select km from vehicle_odometer_readings
   where vehicle_id = p_vehicle and voided_at is null and read_at < app.local_midnight(p_on + 1)
   order by read_at desc limit 1
$$;

-- Km a day: from the readings of the window (the last reading against the one at the window's start), else from the
-- rentals' odometer out and in over the last year, else Program settings.
create or replace function app.maint_km_per_day(p_vehicle uuid, p_today date default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  d date := coalesce(p_today, app.today());
  s program_settings := app.settings(d);
  a record;
  b record;
  v_days numeric;
  v_km numeric;
begin
  select read_at, km into b from vehicle_odometer_readings where vehicle_id = p_vehicle and voided_at is null and read_at < app.local_midnight(d + 1)
   order by read_at desc limit 1;
  if b.km is not null then
    select read_at, km into a from vehicle_odometer_readings where vehicle_id = p_vehicle and voided_at is null
       and read_at <= app.local_midnight(d - s.maint_km_per_day_window_days) order by read_at desc limit 1;
    if a.km is null then
      select read_at, km into a from vehicle_odometer_readings where vehicle_id = p_vehicle and voided_at is null order by read_at, km limit 1;
    end if;
    v_days := extract(epoch from (b.read_at - a.read_at)) / 86400.0;
    if v_days >= 14 and b.km > a.km then
      return jsonb_build_object('rate', round((b.km - a.km) / v_days, 1), 'source', 'readings', 'days', round(v_days));
    end if;
  end if;
  select sum(odometer_in_km - odometer_out_km), extract(epoch from (now() - min(coalesce(handed_over_at, pickup_at)))) / 86400.0
    into v_km, v_days
    from bookings where vehicle_id = p_vehicle and odometer_in_km > odometer_out_km and coalesce(checked_in_at, return_at) >= now() - interval '365 days';
  if v_km > 0 and v_days > 0 then
    return jsonb_build_object('rate', round(v_km / greatest(v_days, 14), 1), 'source', 'rentals', 'days', round(v_days));
  end if;
  return jsonb_build_object('rate', s.maint_default_km_per_day, 'source', 'default', 'days', null);
end $$;

create or replace function app.maint_season_label(p text) returns text
language sql immutable as $$
  select case p when 'summer' then 'Summer' when 'all_season' then 'All-season' when 'winter' then 'Winter' when 'all_weather' then 'All-weather' else p end
$$;

create or replace function app.maint_status_rank(p text) returns integer
language sql immutable as $$
  select case p when 'overdue' then 0 when 'due_soon' then 1 when 'unknown' then 2 when 'ok' then 3 when 'none' then 4 else 5 end
$$;

-- Recompute every item of one car as of a day; creates the rows a car is missing. Returns the car's worst status.
create or replace function app.maint_refresh(p_vehicle uuid, p_today date default null) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  d date := coalesce(p_today, app.today());
  s program_settings := app.settings(d);
  v vehicles;
  r record;
  it vehicle_service_items;
  ts vehicle_tire_sets;
  cur integer;
  rate numeric;
  st text; nd date; nk integer; pd date; det text;
  ex date; src text;
  base_km integer;
  soon_km integer; soon_days integer;
  age_from date;
  y integer; w_rem date; w_on date; w_off date; w_off_by date;
  m smallint;
  has_winter boolean;
  worst text;
begin
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then return null; end if;
  if not app.maint_tracked(v) then
    -- a sample, retired or departed car: nothing to track (rows kept only while it has service records)
    if not exists (select 1 from vehicle_service_records where vehicle_id = p_vehicle) then delete from vehicle_service_items where vehicle_id = p_vehicle; end if;
    return null;
  end if;
  cur := app.maint_current_km(p_vehicle);
  rate := (app.maint_km_per_day(p_vehicle, d) ->> 'rate')::numeric;
  select * into ts from vehicle_tire_sets where vehicle_id = p_vehicle and on_car and retired_on is null;
  has_winter := exists (select 1 from vehicle_tire_sets t where t.vehicle_id = p_vehicle and t.retired_on is null and t.season = 'winter');
  y := extract(year from d)::integer;
  w_rem := app.maint_md(s.maint_winter_on_reminder, y); w_on := app.maint_md(s.maint_winter_on_by, y);
  w_off := app.maint_md(s.maint_winter_off_from, y); w_off_by := app.maint_md(s.maint_winter_off_by, y);

  for r in select * from app.maint_rules(p_vehicle) loop
    insert into vehicle_service_items (vehicle_id, item_code, status) values (p_vehicle, r.code, 'unknown') on conflict do nothing;
    select * into it from vehicle_service_items where vehicle_id = p_vehicle and item_code = r.code;
    st := null; nd := null; nk := null; pd := null; det := null; ex := it.expires_on; src := it.expires_source;
    soon_km := coalesce(r.soon_km, s.maint_due_soon_km); soon_days := coalesce(r.soon_days, s.maint_due_soon_days);

    if not r.active then
      st := 'off'; det := 'Not tracked for this car';

    elsif r.kind = 'tires' then
      if ts.id is null then st := 'unknown'; det := 'No tire set on file: add the set on the car';
      else
        age_from := coalesce(ts.made_on, ts.purchased_on);
        if r.interval_months is not null and age_from is not null then nd := age_from + make_interval(months => r.interval_months); end if;
        if ts.tread_mm is null and age_from is null then st := 'unknown';
        elsif (ts.tread_mm is not null and ts.tread_mm <= s.maint_tire_replace_mm) or (nd is not null and d >= nd) then st := 'overdue';
        elsif (ts.tread_mm is not null and ts.tread_mm <= s.maint_tire_soon_mm) or (nd is not null and d >= nd - soon_days) then st := 'due_soon';
        else st := 'ok'; end if;
        det := concat_ws(', ', app.maint_season_label(ts.season) || ' tires on',
                         case when ts.tread_mm is not null then 'tread ' || ts.tread_mm || ' mm' else 'measure the tread' end,
                         case when age_from is not null then 'made ' || to_char(age_from, 'Mon YYYY') end);
      end if;

    elsif r.kind = 'seasonal' then
      if ts.id is null then st := 'unknown'; det := 'No tire set on file: add the set on the car';
      elsif ts.season = 'all_weather' then st := 'ok'; det := 'All-weather tires on: no seasonal swap';
      elsif ts.season = 'winter' then
        -- winter tires going on a few weeks before the reminder is fine (October); still on in summer is overdue
        if d >= w_off_by and d < w_rem - 31 then st := 'overdue'; nd := w_off_by; det := 'Winter tires still on: swap them off (due by ' || app.maint_date_text(w_off_by) || ')';
        elsif d >= w_off and d < w_off_by then st := 'due_soon'; nd := w_off_by; det := 'Swap the winter tires off by ' || app.maint_date_text(w_off_by);
        else st := 'ok'; nd := case when d >= w_off_by then app.maint_md(s.maint_winter_off_from, y + 1) else w_off end;
             det := 'Winter tires on until ' || app.maint_date_text(nd);
        end if;
      else
        if d >= w_on or d < w_off then
          st := 'overdue'; nd := case when d >= w_on then w_on else app.maint_md(s.maint_winter_on_by, y - 1) end;
          det := app.maint_season_label(ts.season) || ' tires on: winter tires were due on by ' || app.maint_date_text(nd);
        elsif d >= w_rem then st := 'due_soon'; nd := w_on; det := 'Put the winter tires on by ' || app.maint_date_text(w_on);
        else st := 'ok'; nd := w_on; det := app.maint_season_label(ts.season) || ' tires on; winter tires go on by ' || app.maint_date_text(w_on);
        end if;
        if st <> 'ok' and not has_winter then det := det || ' (no winter set on file)'; end if;
      end if;

    elsif r.kind = 'expiry' then
      if r.code = 'registration' and (ex is null or src = 'renewal_month') then
        select g.plate_renewal_month into m from vehicle_registrations g
         where g.vehicle_id = p_vehicle and g.retransferred_on is null and g.plate_renewal_month is not null order by g.registered_on desc limit 1;
        if m is not null then
          ex := (make_date(y, m, 1) + interval '1 month - 1 day')::date;
          if ex < d then ex := (make_date(y + 1, m, 1) + interval '1 month - 1 day')::date; end if;
          src := 'renewal_month';
        else
          select t.plate_expires_on into ex from turo_listings t where t.vehicle_id = p_vehicle and t.plate_expires_on is not null order by t.created_at desc limit 1;
          src := case when ex is not null then 'turo' end;
        end if;
      end if;
      if ex is null and r.interval_months is not null and it.last_done_on is not null then
        ex := it.last_done_on + make_interval(months => r.interval_months); src := 'record';
      end if;
      if ex is distinct from it.expires_on or src is distinct from it.expires_source then
        update vehicle_service_items set expires_on = ex, expires_source = src where vehicle_id = p_vehicle and item_code = r.code;
      end if;
      nd := ex;
      if ex is null then st := 'unknown'; det := 'Record the expiry date';
      elsif d > ex then st := 'overdue'; det := 'Expired on ' || app.maint_date_text(ex);
      elsif d >= ex - soon_days then st := 'due_soon'; det := 'Expires on ' || app.maint_date_text(ex);
      else st := 'ok'; det := 'Valid until ' || app.maint_date_text(ex); end if;
      if src = 'renewal_month' then det := det || ' (from the plate renewal month: record the renewal to confirm)'; end if;

    elsif r.interval_km is null and r.interval_months is null then
      st := 'none';
      det := case when it.last_done_on is null then 'No record yet' else 'Last done ' || app.maint_date_text(it.last_done_on)
                  || coalesce(' at ' || app.maint_km_text(it.last_done_km), '') end;

    else
      if it.last_done_on is null and it.last_done_km is null then st := 'unknown'; det := 'Record the last service';
      else
        base_km := coalesce(it.last_done_km, app.maint_km_at(p_vehicle, it.last_done_on));
        if r.interval_km is not null and base_km is not null then nk := base_km + r.interval_km; end if;
        if r.interval_months is not null and it.last_done_on is not null then nd := it.last_done_on + make_interval(months => r.interval_months); end if;
        if nk is not null and coalesce(rate, 0) > 0 and cur is not null then pd := d + greatest(ceil((nk - cur) / rate), 0)::integer; end if;
        if nk is null and nd is null then st := 'unknown'; det := 'Record the odometer of the last service';
        else
          if (nk is not null and cur is not null and cur >= nk) or (nd is not null and d > nd) then st := 'overdue';
          elsif (nk is not null and cur is not null and cur >= nk - soon_km) or (nd is not null and d >= nd - soon_days) then st := 'due_soon';
          else st := 'ok'; end if;
          det := 'Next ' || concat_ws(' or ', case when nk is not null then 'at ' || app.maint_km_text(nk) end, case when nd is not null then 'by ' || app.maint_date_text(nd) end);
          if st = 'overdue' and nk is not null and cur is not null and cur >= nk then det := det || ' (' || app.maint_km_text(cur - nk) || ' over)'; end if;
        end if;
      end if;
    end if;

    update vehicle_service_items set status = st, next_due_on = nd, next_due_km = nk, projected_due_on = pd, detail = det,
           status_changed_at = case when status is distinct from st then now() else status_changed_at end, updated_at = now()
     where vehicle_id = p_vehicle and item_code = r.code
       and (status, next_due_on, next_due_km, projected_due_on, detail) is distinct from (st, nd, nk, pd, det);
    if st in ('overdue', 'due_soon', 'unknown', 'ok') and (worst is null or app.maint_status_rank(st) < app.maint_status_rank(worst)) then worst := st; end if;
  end loop;
  return coalesce(worst, 'ok');
end $$;

-- ================================================================ 5. odometer readings
create or replace function app.maint_add_reading(p_vehicle uuid, p_km integer, p_at timestamptz, p_source text, p_source_id uuid default null, p_by uuid default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
begin
  if p_vehicle is null or p_km is null or p_km <= 0 then return null; end if;
  if p_source_id is not null then
    insert into vehicle_odometer_readings (vehicle_id, read_at, km, source, source_id, created_by)
    values (p_vehicle, coalesce(p_at, now()), p_km, p_source, p_source_id, p_by)
    on conflict (vehicle_id, source, source_id) where source_id is not null
    do update set km = excluded.km, read_at = excluded.read_at, voided_at = null, voided_by = null, void_reason = null
    returning id into v_id;
  else
    insert into vehicle_odometer_readings (vehicle_id, read_at, km, source, created_by) values (p_vehicle, coalesce(p_at, now()), p_km, p_source, p_by)
    returning id into v_id;
  end if;
  if p_source <> 'car' then
    update vehicles set odometer_km = p_km where id = p_vehicle and coalesce(odometer_km, 0) < p_km;
  end if;
  return v_id;
end $$;

-- After a reading: the car's items again (never stops the work that brought the reading). The tasks follow with the
-- morning watch, or at once when a service is recorded.
create or replace function app.maint_after_reading(p_vehicle uuid) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.maint_refresh(p_vehicle);
exception when others then
  raise warning 'maintenance refresh of % failed: %', p_vehicle, sqlerrm;
end $$;

create or replace function app.maint_condition_report_reading() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  begin
    if new.odometer_km is not null and new.odometer_km > 0 then
      perform app.maint_add_reading(new.vehicle_id, new.odometer_km, coalesce(new.completed_at, new.performed_at, now()),
        case new.kind when 'pickup' then 'handover' when 'return' then 'return' else 'condition_report' end, new.id, new.performed_by);
      perform app.maint_after_reading(new.vehicle_id);
    end if;
  exception when others then raise warning 'odometer reading not kept: %', sqlerrm;
  end;
  return null;
end $$;
create trigger condition_reports_maint_reading after insert or update of odometer_km on condition_reports
  for each row execute function app.maint_condition_report_reading();

create or replace function app.maint_booking_reading() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  begin
    if new.odometer_out_km is distinct from old.odometer_out_km and new.odometer_out_km > 0 then
      perform app.maint_add_reading(new.vehicle_id, new.odometer_out_km, coalesce(new.handed_over_at, new.pickup_at), 'rental', app.maint_uuid_tag(new.id, 'out'));
    end if;
    if new.odometer_in_km is distinct from old.odometer_in_km and new.odometer_in_km > 0 then
      perform app.maint_add_reading(new.vehicle_id, new.odometer_in_km, coalesce(new.checked_in_at, new.return_at), 'rental', app.maint_uuid_tag(new.id, 'in'));
    end if;
    if (new.odometer_out_km is distinct from old.odometer_out_km) or (new.odometer_in_km is distinct from old.odometer_in_km) then
      perform app.maint_after_reading(new.vehicle_id);
    end if;
  exception when others then raise warning 'odometer reading not kept: %', sqlerrm;
  end;
  return null;
end $$;

-- a stable id for one of two readings of the same row (a rental's out and in, a move's start and end)
create or replace function app.maint_uuid_tag(p_id uuid, p_tag text) returns uuid
language sql immutable as $$ select md5(p_id::text || ':' || p_tag)::uuid $$;

create trigger bookings_maint_reading after update of odometer_out_km, odometer_in_km on bookings
  for each row execute function app.maint_booking_reading();

create or replace function app.maint_move_reading() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  begin
    if new.odometer_start > 0 and (tg_op = 'INSERT' or new.odometer_start is distinct from old.odometer_start) then
      perform app.maint_add_reading(new.vehicle_id, new.odometer_start, new.started_at, 'move', app.maint_uuid_tag(new.id, 'start'), new.staff_user_id);
    end if;
    if new.odometer_end > 0 and (tg_op = 'INSERT' or new.odometer_end is distinct from old.odometer_end) then
      perform app.maint_add_reading(new.vehicle_id, new.odometer_end, coalesce(new.ended_at, now()), 'move', app.maint_uuid_tag(new.id, 'end'), new.staff_user_id);
      perform app.maint_after_reading(new.vehicle_id);
    end if;
  exception when others then raise warning 'odometer reading not kept: %', sqlerrm;
  end;
  return null;
end $$;
create trigger vehicle_moves_maint_reading after insert or update of odometer_start, odometer_end on vehicle_moves
  for each row execute function app.maint_move_reading();

create or replace function app.maint_listing_reading() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  begin
    if new.odometer_km > 0 and (tg_op = 'INSERT' or new.odometer_km is distinct from old.odometer_km) then
      perform app.maint_add_reading(new.vehicle_id, new.odometer_km, coalesce(new.submitted_at, now()), 'listing', new.id, new.started_by);
      perform app.maint_after_reading(new.vehicle_id);
    end if;
  exception when others then raise warning 'odometer reading not kept: %', sqlerrm;
  end;
  return null;
end $$;
create trigger listing_intakes_maint_reading after insert or update of odometer_km on listing_intakes
  for each row execute function app.maint_listing_reading();

-- The car record's odometer (owner wizard, VIN decode intake, Admin's edit, handover and return): a reading, unless the
-- same km was just read from the report that moved it.
create or replace function app.maint_vehicle_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  begin
    if new.odometer_km > 0 and (tg_op = 'INSERT' or new.odometer_km is distinct from old.odometer_km) and pg_trigger_depth() = 1
       and not exists (select 1 from vehicle_odometer_readings r where r.vehicle_id = new.id and r.km = new.odometer_km and r.created_at > now() - interval '10 minutes') then
      perform app.maint_add_reading(new.id, new.odometer_km, now(), 'car', null, app.uid());
    end if;
    if tg_op = 'INSERT' or new.odometer_km is distinct from old.odometer_km or new.is_sample is distinct from old.is_sample
       or new.retired_at is distinct from old.retired_at or new.status is distinct from old.status or new.class is distinct from old.class
       or new.fuel is distinct from old.fuel then
      perform app.maint_refresh(new.id);
    end if;
  exception when others then raise warning 'maintenance refresh not done: %', sqlerrm;
  end;
  return null;
end $$;
create trigger vehicles_maint_after after insert or update of odometer_km, is_sample, retired_at, status, class, fuel on vehicles
  for each row execute function app.maint_vehicle_after();

-- ================================================================ 6. blocking
-- Handover: an expiry item set to block (safety inspection, registration) whose recorded expiry has passed.
create or replace function app.maint_handover_block(p_vehicle uuid, p_today date default null) returns text
language sql stable security definer set search_path = public, app as $$
  select string_agg(r.label || ' expired on ' || app.maint_date_text(vi.expires_on), '; ' order by r.sort_order)
    from vehicle_service_items vi
    join app.maint_rules(p_vehicle) r on r.code = vi.item_code
   where vi.vehicle_id = p_vehicle and r.kind = 'expiry' and r.block_handover and r.active
     and vi.expires_on < coalesce(p_today, app.today()) and vi.expires_source in ('record', 'manual', 'turo')
$$;

-- New bookings: an item set to block new bookings while it is overdue (off by default).
create or replace function app.maint_booking_block(p_vehicle uuid) returns text
language plpgsql security definer set search_path = public, app as $$
begin
  if not exists (select 1 from service_items where block_bookings_when_overdue and active)
     and not exists (select 1 from service_item_rules where block_bookings_when_overdue) then
    return null;
  end if;
  perform app.maint_refresh(p_vehicle);
  return (select string_agg(r.label || ': ' || coalesce(vi.detail, 'overdue'), '; ' order by r.sort_order)
            from vehicle_service_items vi join app.maint_rules(p_vehicle) r on r.code = vi.item_code
           where vi.vehicle_id = p_vehicle and vi.status = 'overdue' and r.block_bookings and r.active);
end $$;

create or replace function app.maint_bookings_before() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_msg text;
begin
  if tg_op = 'UPDATE' then
    if old.status = 'confirmed' and new.status = 'on_rent' and new.booking_type <> 'owner' then
      v_msg := app.maint_handover_block(new.vehicle_id);
      if v_msg is not null then
        raise exception 'Do not release the car: %. Renew it, record it under Maintenance, then hand the car over', v_msg using errcode = '23514';
      end if;
    end if;
  elsif new.booking_type <> 'owner' and coalesce(new.added_mode, '') not in ('in_progress', 'past')
        and new.status::text in ('requested', 'offered', 'tentative', 'pending_payment', 'confirmed') then
    v_msg := app.maint_booking_block(new.vehicle_id);
    if v_msg is not null then
      raise exception 'This car takes no new bookings until its overdue service is done and recorded (%). Choose another car, or record the service under Maintenance', v_msg
        using errcode = '23514';
    end if;
  end if;
  return new;
end $$;
create trigger a00_maint_before before insert or update of status on bookings
  for each row execute function app.maint_bookings_before();

-- ================================================================ 7. tasks
create or replace function app.maint_tasks(p_vehicle uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  s program_settings := app.settings();
  v_due text;
  v_n integer;
  v_over integer;
  v_block boolean;
  v_at date;
  v_task uuid;
  v_title text;
  v_prio text;
  v_unknown integer;
begin
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then return; end if;
  if not s.maint_tasks_enabled or not app.maint_tracked(v) then
    update tasks set status = 'cancelled', completed_at = now(), completion_note = 'Maintenance reminders are off for this car'
     where vehicle_id = p_vehicle and task_type in ('maintenance_due', 'maintenance_backfill') and status in ('open', 'in_progress', 'waiting');
    return;
  end if;
  select string_agg(i.label || ': ' || case vi.status when 'overdue' then 'overdue' else 'due soon' end || coalesce(' (' || vi.detail || ')', ''), '; '
                    order by app.maint_status_rank(vi.status), least(vi.next_due_on, vi.projected_due_on) nulls last, i.sort_order),
         count(*), count(*) filter (where vi.status = 'overdue'),
         bool_or(vi.status = 'overdue' and i.block_handover_when_expired),
         min(least(vi.next_due_on, vi.projected_due_on))
    into v_due, v_n, v_over, v_block, v_at
    from vehicle_service_items vi join service_items i on i.code = vi.item_code
   where vi.vehicle_id = p_vehicle and vi.status in ('overdue', 'due_soon');
  select id into v_task from tasks where dedupe_key = 'maint_due:' || p_vehicle and status in ('open', 'in_progress', 'waiting');
  if coalesce(v_n, 0) > 0 then
    v_title := format('%s: %s', app.vehicle_name(p_vehicle) || coalesce(' ' || v.plate, ''),
                      case when v_over > 0 then v_over || ' service item' || case when v_over > 1 then 's' else '' end || ' overdue'
                           else v_n || ' service item' || case when v_n > 1 then 's' else '' end || ' due soon' end);
    v_prio := case when v_block then 'urgent' when v_over > 0 then 'high' else 'normal' end;
    if v_task is null then
      perform app.raise_task(p_type => 'maintenance_due', p_title => v_title, p_detail => v_due, p_vehicle => p_vehicle, p_owner => v.owner_id,
        p_related_table => 'vehicles', p_related_id => p_vehicle, p_due_at => app.local_midnight(greatest(coalesce(v_at, app.today()), app.today())),
        p_priority => v_prio, p_dedupe => 'maint_due:' || p_vehicle, p_queue => 'fleet');
    else
      update tasks set title = v_title, detail = v_due, priority = v_prio, due_at = app.local_midnight(greatest(coalesce(v_at, app.today()), app.today()))
       where id = v_task and (title, detail, priority) is distinct from (v_title, v_due, v_prio);
    end if;
  elsif v_task is not null then
    update tasks set status = 'done', completed_at = now(), completion_note = 'Nothing due now: the service was recorded' where id = v_task;
  end if;

  -- the car's last service, entered once
  select count(*) into v_unknown from vehicle_service_items where vehicle_id = p_vehicle and status = 'unknown';
  if v_unknown > 0 then
    if not exists (select 1 from tasks where dedupe_key = 'maint_backfill:' || p_vehicle) then
      perform app.raise_task(p_type => 'maintenance_backfill',
        p_title => format('Record the last service: %s', app.vehicle_name(p_vehicle) || coalesce(' ' || v.plate, '')),
        p_detail => format('%s service item%s with no record yet (oil change, brakes, tires and so on). Enter what you know once: the reminders work from it.',
                           v_unknown, case when v_unknown > 1 then 's' else '' end),
        p_vehicle => p_vehicle, p_owner => v.owner_id, p_related_table => 'vehicles', p_related_id => p_vehicle,
        p_dedupe => 'maint_backfill:' || p_vehicle, p_queue => 'fleet', p_priority => 'low');
    end if;
  else
    update tasks set status = 'done', completed_at = now(), completion_note = 'Every service item has a record'
     where dedupe_key = 'maint_backfill:' || p_vehicle and status in ('open', 'in_progress', 'waiting');
  end if;
end $$;

-- ================================================================ 8. who may do what
create or replace function app.maint_can(p_user uuid, p_what text) returns boolean
language sql stable security definer set search_path = public, app as $$
  select case p_what
    when 'read' then app.user_is_admin(p_user) or app.user_va_has(p_user, 'fleet', 'finance')
    when 'record' then app.user_is_admin(p_user) or app.user_va_has(p_user, 'fleet', 'finance')
    when 'settings' then app.user_is_admin(p_user)
    else false end
$$;

create or replace function app.maint_assert(p_user uuid, p_what text) returns void
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.maint_can(p_user, p_what) then
    raise exception '%', case p_what when 'settings' then 'Only an Admin changes the maintenance settings'
                                     else 'Only an Admin, Fleet or Finance works with maintenance' end using errcode = '42501';
  end if;
end $$;

-- Who pays, as a car allows (owner agreement 11.1: the owner pays for maintenance and routine wear).
create or replace function app.maint_payers(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case
    when v.supply_type = 'company' or v.owner_id is null then
      '[["company","CarmaCars (company expense)"],["claim","A claim"],["renter","The renter (post-rental charge)"],["none","No charge (warranty, free)"]]'::jsonb
    when v.supply_type = 'partner' then
      '[["owner","The partner (pays the shop directly)"],["company","CarmaCars (company expense)"],["claim","A claim"],["renter","The renter (post-rental charge)"],["none","No charge (warranty, free)"]]'::jsonb
    else
      '[["owner","The owner (deducted on the owner''s statement)"],["company","CarmaCars (company expense)"],["claim","A claim"],["renter","The renter (post-rental charge)"],["none","No charge (warranty, or the owner paid the shop)"]]'::jsonb
    end
    from vehicles v where v.id = p_vehicle
$$;
create or replace function app.maint_default_payer(p_vehicle uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case when v.supply_type = 'company' or v.owner_id is null then 'company' else 'owner' end from vehicles v where v.id = p_vehicle
$$;

-- ================================================================ 9. items done: reset the timers
create or replace function app.maint_rebuild_item(p_vehicle uuid, p_item text) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  x record;
begin
  select r.id, r.done_on, case when r.odometer_estimated then null else r.odometer_km end as km, ri.expires_on, ri.tread_mm
    into x
    from vehicle_service_records r join vehicle_service_record_items ri on ri.record_id = r.id
   where r.vehicle_id = p_vehicle and ri.item_code = p_item and r.voided_at is null
   order by r.done_on desc, r.created_at desc limit 1;
  insert into vehicle_service_items (vehicle_id, item_code) values (p_vehicle, p_item) on conflict do nothing;
  update vehicle_service_items vi
     set last_done_on = x.done_on,
         last_done_km = coalesce(x.km, case when x.id is not null then app.maint_km_at(p_vehicle, x.done_on) end),
         last_record_id = x.id,
         expires_on = case when (select kind from service_items where code = p_item) = 'expiry'
                           then case when x.id is not null then x.expires_on
                                     when vi.expires_source in ('renewal_month', 'turo') then vi.expires_on end
                           else vi.expires_on end,
         expires_source = case when (select kind from service_items where code = p_item) = 'expiry'
                               then case when x.id is not null and x.expires_on is not null then 'record'
                                         when x.id is null and vi.expires_source in ('renewal_month', 'turo') then vi.expires_source end
                               else vi.expires_source end,
         updated_at = now()
   where vi.vehicle_id = p_vehicle and vi.item_code = p_item;
end $$;

-- Swap the set on the car (from a service record, or on its own).
create or replace function app.maint_swap_to(p_by uuid, p_vehicle uuid, p_set uuid, p_on date, p_km integer, p_record uuid, p_store text default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  t vehicle_tire_sets;
  f vehicle_tire_sets;
  v_id uuid;
begin
  select * into t from vehicle_tire_sets where id = p_set and vehicle_id = p_vehicle and retired_on is null for update;
  if t.id is null then raise exception 'Choose one of this car''s tire sets' using errcode = '22023'; end if;
  select * into f from vehicle_tire_sets where vehicle_id = p_vehicle and on_car and retired_on is null for update;
  if f.id = t.id then return null; end if;
  if f.id is not null then
    update vehicle_tire_sets set on_car = false, storage_location = coalesce(nullif(btrim(p_store), ''), storage_location), updated_at = now() where id = f.id;
  end if;
  update vehicle_tire_sets set on_car = true, storage_location = null, updated_at = now() where id = t.id;
  insert into vehicle_tire_swaps (vehicle_id, from_set_id, to_set_id, swapped_on, odometer_km, record_id, created_by)
  values (p_vehicle, f.id, t.id, p_on, p_km, p_record, p_by) returning id into v_id;
  update vehicle_service_items set last_done_on = greatest(coalesce(last_done_on, p_on), p_on), last_done_km = coalesce(p_km, last_done_km), updated_at = now()
   where vehicle_id = p_vehicle and item_code = 'seasonal_swap';
  return v_id;
end $$;

-- The bill of a service record: a company expense, an owner cost on the owner's statement, a claim cost, or a post-rental
-- charge to the renter. Billing above an assistant's single limit waits for an Admin.
create or replace function app.maint_bill_record(p_by uuid, p_record uuid) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  r vehicle_service_records;
  v vehicles;
  c claims;
  b bookings;
  v_total bigint;
  v_desc text;
  v_cat text;
  v_id uuid;
  v_limit bigint;
begin
  select * into r from vehicle_service_records where id = p_record for update;
  select * into v from vehicles where id = r.vehicle_id;
  if r.billing_status = 'billed' or r.voided_at is not null then return r.billing_status; end if;
  v_total := r.cost_cents + r.hst_cents;
  if r.payer = 'none' or v_total = 0 or (r.payer = 'owner' and v.supply_type = 'partner') then
    update vehicle_service_records set billing_status = 'no_charge' where id = p_record;
    return 'no_charge';
  end if;
  if not app.user_is_admin(p_by) then
    v_limit := coalesce((select sp.single_limit_cents from staff_profiles sp where sp.user_id = p_by), 0);
    if v_total > v_limit then
      update vehicle_service_records set billing_status = 'needs_admin' where id = p_record;
      perform app.raise_task(p_type => 'maintenance_bill', p_queue => 'admin',
        p_title => format('Bill a service of %s on %s (above the assistant''s limit)', app.fmt_money(v_total), app.vehicle_name(r.vehicle_id)),
        p_detail => format('Recorded by an assistant whose single limit is %s. Open the car''s Maintenance tab and press Bill now.', app.fmt_money(v_limit)),
        p_vehicle => r.vehicle_id, p_owner => v.owner_id, p_related_table => 'vehicle_service_records', p_related_id => r.id,
        p_dedupe => 'maint_bill:' || r.id, p_created_by => p_by);
      return 'needs_admin';
    end if;
  end if;
  v_desc := 'Service: ' || coalesce((select string_agg(i.label, ', ' order by i.sort_order) from vehicle_service_record_items ri join service_items i on i.code = ri.item_code
                                      where ri.record_id = r.id), 'other work')
            || coalesce(' at ' || r.shop, '') || ', ' || app.maint_date_text(r.done_on);
  if r.payer = 'company' then
    select m.category_code into v_cat from maintenance_categories m
     where (select array_agg(ri.item_code) from vehicle_service_record_items ri where ri.record_id = r.id) <@ m.item_codes and cardinality(m.item_codes) > 0
     order by cardinality(m.item_codes) limit 1;
    perform set_config('app.maint_record', r.id::text, true);
    insert into company_expenses (expense_on, category, description, amount_cents, hst_cents, vehicle_id, owner_id, document_id, created_by)
    values (r.done_on, coalesce(v_cat, 'maint_service'), left(v_desc, 500), r.cost_cents, r.hst_cents, r.vehicle_id, v.owner_id, r.receipt_document_id, p_by)
    returning id into v_id;
    perform set_config('app.maint_record', '', true);
    update vehicle_service_records set company_expense_id = v_id where id = p_record;
  elsif r.payer = 'owner' then
    if v.owner_id is null or v.supply_type <> 'program_owner' then
      raise exception 'This car has no program owner to bill: choose CarmaCars, a claim, the renter or no charge' using errcode = '23514';
    end if;
    insert into owner_deductions (owner_id, vehicle_id, kind, description, amount_cents, hst_cents, incurred_on, receipt_document_id, status, created_by)
    values (v.owner_id, r.vehicle_id, 'maintenance', left(v_desc, 500), v_total, r.hst_cents, r.done_on, r.receipt_document_id, 'open', p_by)
    returning id into v_id;
    update vehicle_service_records set owner_deduction_id = v_id where id = p_record;
  elsif r.payer = 'claim' then
    select * into c from claims where id = r.claim_id;
    if c.id is null or c.vehicle_id is distinct from r.vehicle_id then raise exception 'Choose a claim on this car' using errcode = '22023'; end if;
    if c.status in ('closed', 'withdrawn', 'denied', 'distributed') then
      raise exception 'Claim % is %: a cost cannot be added. Choose another way to pay', c.claim_number, c.status using errcode = '23514';
    end if;
    insert into claim_ledger_entries (claim_id, entry_date, kind, amount_cents, description, document_id, created_by)
    values (c.id, r.done_on, 'repair', v_total, left(v_desc, 500), r.receipt_document_id, p_by)
    returning id into v_id;
    update vehicle_service_records set claim_entry_id = v_id where id = p_record;
  elsif r.payer = 'renter' then
    select * into b from bookings where id = r.booking_id;
    if b.id is null or b.vehicle_id is distinct from r.vehicle_id then raise exception 'Choose a rental of this car' using errcode = '22023'; end if;
    if b.status::text in ('cancelled', 'declined', 'expired', 'requested', 'offered') then
      raise exception 'Booking % is %: charge the renter on a rental that happened', b.booking_number, b.status using errcode = '23514';
    end if;
    v_id := app.set_assessed_line(b.id, 'maint:' || r.id, 'damage_at_cost', 1, v_total, v_total, left(v_desc, 300),
                                  jsonb_build_object('service_record_id', r.id), p_by, null, r.receipt_document_id);
    update vehicle_service_records set booking_line_item_id = v_id where id = p_record;
  end if;
  update vehicle_service_records set billing_status = 'billed', billed_at = now(), billed_by = p_by where id = p_record;
  update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'Billed'
   where dedupe_key = 'maint_bill:' || p_record and status in ('open', 'in_progress', 'waiting');
  return 'billed';
end $$;

-- Record a service: p {vehicle_id, done_on, odometer_km, shop, notes, items: [{code, expires_on, tread_mm, tire_set_id,
-- new_set: {season, size, brand, model, tread_mm, made_on}}], cost_cents, hst_cents, payer, billed, claim_id, booking_id,
-- receipt: {storage_path, mime_type, sha256, title}}
create or replace function app.maint_record(p_by uuid, p jsonb, p_source text default 'manual', p_expense uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  d date := coalesce(nullif(p ->> 'done_on', '')::date, app.today());
  v_km integer := nullif(p ->> 'odometer_km', '')::integer;
  v_est boolean := false;
  v_cost bigint := coalesce(nullif(p ->> 'cost_cents', '')::bigint, 0);
  v_hst bigint := coalesce(nullif(p ->> 'hst_cents', '')::bigint, 0);
  v_payer text := coalesce(nullif(p ->> 'payer', ''), '');
  v_billed boolean := coalesce((p ->> 'billed')::boolean, true);
  v_doc uuid;
  v_id uuid;
  x jsonb;
  v_code text;
  v_kind text;
  v_set uuid;
  v_codes text[] := '{}';
  v_status text;
  v_months integer;
begin
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid;
  if v.id is null then raise exception 'Choose the car' using errcode = '22023'; end if;
  if d > app.today() then raise exception 'The date of the service cannot be in the future' using errcode = '22023'; end if;
  if d < date '2000-01-01' then raise exception 'Check the date of the service' using errcode = '22023'; end if;
  if v_km is not null and (v_km < 0 or v_km > 2000000) then raise exception 'Check the odometer (km)' using errcode = '22023'; end if;
  if v_cost < 0 or v_hst < 0 then raise exception 'The cost cannot be negative' using errcode = '22023'; end if;
  if v_payer = '' then v_payer := app.maint_default_payer(v.id); end if;
  if v_payer not in ('company', 'owner', 'claim', 'renter', 'none') then raise exception 'Choose who pays' using errcode = '22023'; end if;
  if v_payer = 'owner' and (v.owner_id is null or v.supply_type = 'company') then
    raise exception 'This car has no owner to bill: choose CarmaCars, a claim, the renter or no charge' using errcode = '23514';
  end if;
  if v_payer = 'claim' and nullif(p ->> 'claim_id', '') is null then raise exception 'Choose the claim that pays' using errcode = '22023'; end if;
  if v_payer = 'renter' and nullif(p ->> 'booking_id', '') is null then raise exception 'Choose the rental the renter is charged on' using errcode = '22023'; end if;
  if p_source = 'manual' and jsonb_array_length(coalesce(p -> 'items', '[]'::jsonb)) = 0 then
    raise exception 'Tick what was done (at least one item)' using errcode = '22023';
  end if;
  if v_km is null then v_km := app.maint_km_at(v.id, d); v_est := v_km is not null; end if;

  if p -> 'receipt' ->> 'storage_path' is not null then
    insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, uploaded_by, vehicle_id, owner_id)
    values ('receipt', left(coalesce(p -> 'receipt' ->> 'title', 'Service receipt'), 200), 'documents', p -> 'receipt' ->> 'storage_path',
            p -> 'receipt' ->> 'mime_type', p -> 'receipt' ->> 'sha256', p_by, v.id, v.owner_id)
    returning id into v_doc;
  end if;
  v_doc := coalesce(v_doc, nullif(p ->> 'receipt_document_id', '')::uuid);

  insert into vehicle_service_records (vehicle_id, done_on, odometer_km, odometer_estimated, shop, notes, cost_cents, hst_cents, payer, billing_status,
                                       claim_id, booking_id, receipt_document_id, source, company_expense_id, created_by)
  values (v.id, d, v_km, v_est, nullif(btrim(p ->> 'shop'), ''), nullif(btrim(p ->> 'notes'), ''), v_cost, v_hst, v_payer,
          case when p_source = 'expense' then 'billed' when v_billed then 'not_billed' else 'not_billed' end,
          case when v_payer = 'claim' then nullif(p ->> 'claim_id', '')::uuid end, case when v_payer = 'renter' then nullif(p ->> 'booking_id', '')::uuid end,
          v_doc, p_source, p_expense, p_by)
  returning id into v_id;
  if p_source = 'expense' then update vehicle_service_records set billed_at = now(), billed_by = p_by where id = v_id; end if;

  for x in select * from jsonb_array_elements(coalesce(p -> 'items', '[]'::jsonb)) loop
    v_code := coalesce(x ->> 'code', x #>> '{}');
    select kind, interval_months into v_kind, v_months from service_items where code = v_code;
    if v_kind is null then raise exception 'Unknown service item %', v_code using errcode = '22023'; end if;
    if v_code = any (v_codes) then continue; end if;
    v_codes := v_codes || v_code;
    v_set := nullif(x ->> 'tire_set_id', '')::uuid;
    -- new tires: a new set on the car, the old one retired as replaced
    if v_kind = 'tires' and x ? 'new_set' and nullif(x -> 'new_set' ->> 'season', '') is not null then
      update vehicle_tire_sets set on_car = false, retired_on = d, retired_reason = 'Replaced', updated_at = now()
       where vehicle_id = v.id and on_car and retired_on is null;
      insert into vehicle_tire_sets (vehicle_id, season, size, brand, model, tread_mm, tread_measured_on, made_on, purchased_on, on_car, created_by)
      values (v.id, x -> 'new_set' ->> 'season', nullif(btrim(x -> 'new_set' ->> 'size'), ''), nullif(btrim(x -> 'new_set' ->> 'brand'), ''),
              nullif(btrim(x -> 'new_set' ->> 'model'), ''), nullif(x -> 'new_set' ->> 'tread_mm', '')::numeric, d,
              nullif(x -> 'new_set' ->> 'made_on', '')::date, d, true, p_by)
      returning id into v_set;
    elsif v_kind = 'tires' and nullif(x ->> 'tread_mm', '') is not null then
      update vehicle_tire_sets set tread_mm = (x ->> 'tread_mm')::numeric, tread_measured_on = d, updated_at = now()
       where vehicle_id = v.id and on_car and retired_on is null;
    end if;
    if v_kind = 'seasonal' and v_set is not null then
      perform app.maint_swap_to(p_by, v.id, v_set, d, case when v_est then null else v_km end, v_id, x ->> 'store_removed_at');
    end if;
    if v_kind = 'expiry' and nullif(x ->> 'expires_on', '') is not null and (x ->> 'expires_on')::date < d then
      raise exception 'The new expiry date is before the service date' using errcode = '22023';
    end if;
    insert into vehicle_service_record_items (record_id, item_code, expires_on, tread_mm, tire_set_id)
    values (v_id, v_code,
            case when v_kind = 'expiry' then coalesce(nullif(x ->> 'expires_on', '')::date, case when v_months > 0 then d + make_interval(months => v_months) end) end,
            nullif(x ->> 'tread_mm', '')::numeric, v_set);
    perform app.maint_rebuild_item(v.id, v_code);
  end loop;

  if v_km is not null and not v_est then perform app.maint_add_reading(v.id, v_km, app.local_midnight(d) + interval '12 hours', 'service', v_id, p_by); end if;
  v_status := case when p_source = 'expense' then 'billed' when v_billed then app.maint_bill_record(p_by, v_id) else
                (case when v_payer = 'none' or v_cost + v_hst = 0 then 'no_charge' else 'not_billed' end) end;
  if v_status = 'no_charge' or (not v_billed and v_status = 'no_charge') then update vehicle_service_records set billing_status = 'no_charge' where id = v_id; end if;
  perform app.maint_refresh(v.id);
  perform app.maint_tasks(v.id);
  return jsonb_build_object('id', v_id, 'billing_status', (select billing_status from vehicle_service_records where id = v_id),
                            'status', (select jsonb_object_agg(item_code, status) from vehicle_service_items where vehicle_id = v.id and item_code = any (v_codes)));
end $$;

-- Bill a service recorded without its bill (or waiting for an Admin): the cost, who pays and the receipt may change here.
create or replace function app.maint_bill(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r vehicle_service_records;
  v_status text;
begin
  select * into r from vehicle_service_records where id = nullif(p ->> 'id', '')::uuid for update;
  if r.id is null or r.voided_at is not null then raise exception 'Service record not found' using errcode = 'P0002'; end if;
  if r.billing_status = 'billed' then raise exception 'This service is already billed' using errcode = '23514'; end if;
  if r.billing_status = 'needs_admin' and not app.user_is_admin(p_by) then raise exception 'An Admin bills this service (above your single limit)' using errcode = '42501'; end if;
  update vehicle_service_records
     set cost_cents = coalesce(nullif(p ->> 'cost_cents', '')::bigint, cost_cents), hst_cents = coalesce(nullif(p ->> 'hst_cents', '')::bigint, hst_cents),
         payer = coalesce(nullif(p ->> 'payer', ''), payer),
         claim_id = coalesce(nullif(p ->> 'claim_id', '')::uuid, claim_id), booking_id = coalesce(nullif(p ->> 'booking_id', '')::uuid, booking_id),
         receipt_document_id = coalesce(nullif(p ->> 'receipt_document_id', '')::uuid, receipt_document_id),
         billing_status = 'not_billed'
   where id = r.id;
  select * into r from vehicle_service_records where id = r.id;
  if r.payer not in ('company', 'owner', 'claim', 'renter', 'none') then raise exception 'Choose who pays' using errcode = '22023'; end if;
  if r.payer = 'claim' and r.claim_id is null then raise exception 'Choose the claim that pays' using errcode = '22023'; end if;
  if r.payer = 'renter' and r.booking_id is null then raise exception 'Choose the rental the renter is charged on' using errcode = '22023'; end if;
  v_status := app.maint_bill_record(p_by, r.id);
  return jsonb_build_object('id', r.id, 'billing_status', v_status);
end $$;

-- Void a service record: its bill goes too (the expense voided, an open owner cost waived, a renter line not yet on a
-- statement voided); a bill already on a statement or a claim stays and the void is refused with what to do.
create or replace function app.maint_void(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r vehicle_service_records;
  v_reason text := nullif(btrim(p ->> 'reason'), '');
  v_item text;
begin
  select * into r from vehicle_service_records where id = nullif(p ->> 'id', '')::uuid for update;
  if r.id is null or r.voided_at is not null then raise exception 'Service record not found' using errcode = 'P0002'; end if;
  if v_reason is null then raise exception 'Give the reason' using errcode = '22023'; end if;
  if not app.user_is_admin(p_by) and not (r.created_by = p_by and r.billing_status in ('not_billed', 'needs_admin', 'no_charge')) then
    raise exception 'Only an Admin voids a service that is billed' using errcode = '42501';
  end if;
  if r.owner_deduction_id is not null and exists (select 1 from owner_deductions where id = r.owner_deduction_id and status <> 'open') then
    raise exception 'The owner cost is already on a statement: add a credit for the owner instead' using errcode = '23514';
  end if;
  if r.claim_entry_id is not null then
    raise exception 'The cost is on a claim''s ledger, which cannot change: record a correcting entry on the claim' using errcode = '23514';
  end if;
  if r.booking_line_item_id is not null and exists (select 1 from booking_line_items where id = r.booking_line_item_id and statement_id is not null) then
    raise exception 'The renter''s charge is already on a statement: refund it on the booking instead' using errcode = '23514';
  end if;
  update vehicle_service_records set voided_at = now(), voided_by = p_by, void_reason = v_reason where id = r.id;
  if r.company_expense_id is not null and r.source = 'manual' then
    perform set_config('app.maint_record', r.id::text, true);
    update company_expenses set voided_at = now(), void_reason = 'Service record voided: ' || v_reason where id = r.company_expense_id and voided_at is null;
    perform set_config('app.maint_record', '', true);
  end if;
  update owner_deductions set status = 'waived' where id = r.owner_deduction_id and status = 'open';
  update booking_line_items set voided_at = now(), voided_by = p_by, void_reason = 'Service record voided' where id = r.booking_line_item_id and voided_at is null;
  for v_item in select item_code from vehicle_service_record_items where record_id = r.id loop
    perform app.maint_rebuild_item(r.vehicle_id, v_item);
  end loop;
  update tasks set status = 'cancelled', completed_at = now(), completion_note = 'Service record voided'
   where dedupe_key = 'maint_bill:' || r.id and status in ('open', 'in_progress', 'waiting');
  perform app.maint_refresh(r.vehicle_id);
  perform app.maint_tasks(r.vehicle_id);
  return jsonb_build_object('id', r.id, 'voided', true);
end $$;

-- An expense entered under a service category (Admin > Expenses) records the service; voiding it voids that record.
create or replace function app.maint_expense_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  m maintenance_categories;
  r vehicle_service_records;
  v_item text;
begin
  if coalesce(current_setting('app.maint_record', true), '') <> '' then return null; end if;
  if tg_op = 'INSERT' then
    if new.vehicle_id is null or new.voided_at is not null then return null; end if;
    select * into m from maintenance_categories where category_code = new.category;
    if m.category_code is null then return null; end if;
    perform app.maint_record(coalesce(new.created_by, app.uid()),
      jsonb_build_object('vehicle_id', new.vehicle_id, 'done_on', new.expense_on, 'notes', new.description, 'cost_cents', new.amount_cents,
                         'hst_cents', coalesce(new.hst_cents, 0), 'payer', 'company', 'receipt_document_id', new.document_id,
                         'items', to_jsonb(m.item_codes)), 'expense', new.id);
  elsif new.voided_at is not null and old.voided_at is null then
    select * into r from vehicle_service_records where company_expense_id = new.id and voided_at is null;
    if r.id is null then return null; end if;
    if r.source = 'expense' then
      update vehicle_service_records set voided_at = now(), voided_by = app.uid(), void_reason = 'Expense voided: ' || coalesce(new.void_reason, '') where id = r.id;
      for v_item in select item_code from vehicle_service_record_items where record_id = r.id loop
        perform app.maint_rebuild_item(r.vehicle_id, v_item);
      end loop;
      perform app.maint_refresh(r.vehicle_id);
      perform app.maint_tasks(r.vehicle_id);
    else
      update vehicle_service_records set billing_status = 'not_billed', company_expense_id = null, billed_at = null, billed_by = null where id = r.id;
    end if;
  end if;
  return null;
end $$;
create trigger company_expenses_maint after insert or update of voided_at on company_expenses
  for each row execute function app.maint_expense_after();

-- ================================================================ 10. tire sets, readings and settings
create or replace function app.maint_tire_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  t vehicle_tire_sets;
  v_vehicle uuid;
  v_id uuid := nullif(p ->> 'id', '')::uuid;
  v_on boolean := coalesce((p ->> 'on_car')::boolean, false);
begin
  if v_id is not null then
    select * into t from vehicle_tire_sets where id = v_id;
    if t.id is null then raise exception 'Tire set not found' using errcode = 'P0002'; end if;
    v_vehicle := t.vehicle_id;
  else
    v_vehicle := nullif(p ->> 'vehicle_id', '')::uuid;
    if not exists (select 1 from vehicles where id = v_vehicle) then raise exception 'Choose the car' using errcode = '22023'; end if;
  end if;
  if coalesce(p ->> 'season', t.season, '') not in ('summer', 'all_season', 'winter', 'all_weather') then
    raise exception 'Choose the kind of tires: summer, all-season, winter or all-weather' using errcode = '22023';
  end if;
  if nullif(p ->> 'tread_mm', '')::numeric not between 0 and 20 then raise exception 'Tread depth is in mm, between 0 and 20' using errcode = '22023'; end if;
  if v_on then update vehicle_tire_sets set on_car = false, updated_at = now() where vehicle_id = v_vehicle and on_car and id is distinct from v_id; end if;
  if v_id is null then
    insert into vehicle_tire_sets (vehicle_id, season, size, brand, model, tread_mm, tread_measured_on, made_on, purchased_on, storage_location, on_car, notes, created_by)
    values (v_vehicle, p ->> 'season', nullif(btrim(p ->> 'size'), ''), nullif(btrim(p ->> 'brand'), ''), nullif(btrim(p ->> 'model'), ''),
            nullif(p ->> 'tread_mm', '')::numeric, case when nullif(p ->> 'tread_mm', '') is not null then coalesce(nullif(p ->> 'tread_measured_on', '')::date, app.today()) end,
            nullif(p ->> 'made_on', '')::date, nullif(p ->> 'purchased_on', '')::date, case when v_on then null else nullif(btrim(p ->> 'storage_location'), '') end,
            v_on, nullif(btrim(p ->> 'notes'), ''), p_by)
    returning id into v_id;
  else
    update vehicle_tire_sets set
      season = coalesce(nullif(p ->> 'season', ''), season), size = case when p ? 'size' then nullif(btrim(p ->> 'size'), '') else size end,
      brand = case when p ? 'brand' then nullif(btrim(p ->> 'brand'), '') else brand end, model = case when p ? 'model' then nullif(btrim(p ->> 'model'), '') else model end,
      tread_mm = case when p ? 'tread_mm' then nullif(p ->> 'tread_mm', '')::numeric else tread_mm end,
      tread_measured_on = case when p ? 'tread_mm' and nullif(p ->> 'tread_mm', '') is not null then coalesce(nullif(p ->> 'tread_measured_on', '')::date, app.today()) else tread_measured_on end,
      made_on = case when p ? 'made_on' then nullif(p ->> 'made_on', '')::date else made_on end,
      purchased_on = case when p ? 'purchased_on' then nullif(p ->> 'purchased_on', '')::date else purchased_on end,
      storage_location = case when v_on then null when p ? 'storage_location' then nullif(btrim(p ->> 'storage_location'), '') else storage_location end,
      on_car = case when p ? 'on_car' then v_on else on_car end, notes = case when p ? 'notes' then nullif(btrim(p ->> 'notes'), '') else notes end, updated_at = now()
     where id = v_id;
  end if;
  perform app.maint_refresh(v_vehicle);
  perform app.maint_tasks(v_vehicle);
  return jsonb_build_object('id', v_id);
end $$;

create or replace function app.maint_door(p_user uuid, p_call text, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_vehicle uuid := nullif(p ->> 'vehicle_id', '')::uuid;
  v_id uuid;
  r record;
  t vehicle_tire_sets;
begin
  case p_name
  when 'maint_overview' then perform app.maint_assert(p_user, 'read'); return app.maint_overview(p_user);
  when 'maint_vehicle' then perform app.maint_assert(p_user, 'read'); return app.maint_vehicle(p_user, v_vehicle);
  when 'maint_owner' then
    if not (app.user_is_admin(p_user) or app.user_is_owner_of(p_user, (select owner_id from vehicles where id = v_vehicle))) then
      raise exception 'Not permitted' using errcode = '42501';
    end if;
    return app.maint_owner_history(v_vehicle);
  when 'maint_settings' then perform app.maint_assert(p_user, 'settings'); return app.maint_settings_read();
  when 'maint_receipt' then
    -- a service receipt, for the people who read maintenance (the Admin's documents route serves any document)
    perform app.maint_assert(p_user, 'read');
    return (select jsonb_build_object('bucket', dc.storage_bucket, 'path', dc.storage_path, 'mime_type', dc.mime_type)
              from documents dc where dc.id = nullif(p ->> 'document', '')::uuid and dc.purged_at is null
               and exists (select 1 from vehicle_service_records r where r.receipt_document_id = dc.id));
  when 'maint_record' then perform app.maint_assert(p_user, 'record'); return app.maint_record(p_user, p);
  when 'maint_bill' then perform app.maint_assert(p_user, 'record'); return app.maint_bill(p_user, p);
  when 'maint_void' then perform app.maint_assert(p_user, 'record'); return app.maint_void(p_user, p);
  when 'maint_tire_save' then perform app.maint_assert(p_user, 'record'); return app.maint_tire_save(p_user, p);
  when 'maint_tire_swap' then
    perform app.maint_assert(p_user, 'record');
    select * into t from vehicle_tire_sets where id = nullif(p ->> 'to_set_id', '')::uuid;
    if t.id is null then raise exception 'Choose the set that goes on' using errcode = '22023'; end if;
    if coalesce(nullif(p ->> 'swapped_on', '')::date, app.today()) > app.today() then raise exception 'The swap date cannot be in the future' using errcode = '22023'; end if;
    v_id := app.maint_swap_to(p_user, t.vehicle_id, t.id, coalesce(nullif(p ->> 'swapped_on', '')::date, app.today()), nullif(p ->> 'odometer_km', '')::integer, null, p ->> 'storage_location');
    if nullif(p ->> 'odometer_km', '')::integer > 0 then perform app.maint_add_reading(t.vehicle_id, (p ->> 'odometer_km')::integer, now(), 'manual', null, p_user); end if;
    perform app.maint_refresh(t.vehicle_id); perform app.maint_tasks(t.vehicle_id);
    return jsonb_build_object('id', v_id);
  when 'maint_tire_retire' then
    perform app.maint_assert(p_user, 'record');
    if nullif(btrim(p ->> 'reason'), '') is null then raise exception 'Give the reason (worn out, sold, damaged)' using errcode = '22023'; end if;
    update vehicle_tire_sets set retired_on = app.today(), retired_reason = btrim(p ->> 'reason'), on_car = false, updated_at = now()
     where id = nullif(p ->> 'id', '')::uuid and retired_on is null returning * into t;
    if t.id is null then raise exception 'Tire set not found' using errcode = 'P0002'; end if;
    perform app.maint_refresh(t.vehicle_id); perform app.maint_tasks(t.vehicle_id);
    return jsonb_build_object('id', t.id);
  when 'maint_reading_add' then
    perform app.maint_assert(p_user, 'record');
    if not exists (select 1 from vehicles where id = v_vehicle) then raise exception 'Choose the car' using errcode = '22023'; end if;
    if nullif(p ->> 'km', '') is null or (p ->> 'km')::integer not between 1 and 2000000 then raise exception 'Enter the odometer in km' using errcode = '22023'; end if;
    if (p ->> 'km')::integer < coalesce(app.maint_current_km(v_vehicle), 0) and not coalesce((p ->> 'confirmed')::boolean, false) then
      raise exception 'The reading (% km) is lower than the last one on file (% km): check it, and tick that you checked it', p ->> 'km', app.maint_current_km(v_vehicle) using errcode = '23514';
    end if;
    v_id := app.maint_add_reading(v_vehicle, (p ->> 'km')::integer, coalesce(nullif(p ->> 'read_at', '')::timestamptz, now()), 'manual', null, p_user);
    perform app.maint_refresh(v_vehicle); perform app.maint_tasks(v_vehicle);
    return jsonb_build_object('id', v_id);
  when 'maint_reading_void' then
    perform app.maint_assert(p_user, 'settings');
    update vehicle_odometer_readings set voided_at = now(), voided_by = p_user, void_reason = coalesce(nullif(btrim(p ->> 'reason'), ''), 'Wrong reading')
     where id = nullif(p ->> 'id', '')::uuid and voided_at is null returning vehicle_id into v_vehicle;
    if v_vehicle is null then raise exception 'Reading not found' using errcode = 'P0002'; end if;
    -- the car record follows the highest reading left
    update vehicles set odometer_km = (select max(km) from vehicle_odometer_readings where vehicle_id = v_vehicle and voided_at is null) where id = v_vehicle
       and odometer_km > coalesce((select max(km) from vehicle_odometer_readings where vehicle_id = v_vehicle and voided_at is null), 0);
    perform app.maint_refresh(v_vehicle); perform app.maint_tasks(v_vehicle);
    return jsonb_build_object('ok', true);
  when 'maint_item_save' then
    perform app.maint_assert(p_user, 'settings');
    update service_items set
      label = coalesce(nullif(btrim(p ->> 'label'), ''), label),
      interval_km = case when p ? 'interval_km' then nullif(p ->> 'interval_km', '')::integer else interval_km end,
      interval_months = case when p ? 'interval_months' then nullif(p ->> 'interval_months', '')::integer else interval_months end,
      due_soon_km = case when p ? 'due_soon_km' then nullif(p ->> 'due_soon_km', '')::integer else due_soon_km end,
      due_soon_days = case when p ? 'due_soon_days' then nullif(p ->> 'due_soon_days', '')::integer else due_soon_days end,
      block_bookings_when_overdue = coalesce((p ->> 'block_bookings_when_overdue')::boolean, block_bookings_when_overdue),
      block_handover_when_expired = case when kind = 'expiry' then coalesce((p ->> 'block_handover_when_expired')::boolean, block_handover_when_expired) else false end,
      active = coalesce((p ->> 'active')::boolean, active), updated_at = now(), updated_by = p_user
     where code = p ->> 'code';
    if not found then raise exception 'Service item not found' using errcode = 'P0002'; end if;
    perform app.maint_refresh_all();
    return jsonb_build_object('ok', true);
  when 'maint_rule_save' then
    perform app.maint_assert(p_user, 'settings');
    if not exists (select 1 from service_items where code = p ->> 'item_code') then raise exception 'Choose the service item' using errcode = '22023'; end if;
    if (nullif(p ->> 'vehicle_class', '') is null) = (v_vehicle is null) then raise exception 'Choose a class or a car' using errcode = '22023'; end if;
    select id into v_id from service_item_rules where item_code = p ->> 'item_code'
       and (vehicle_id = v_vehicle or vehicle_class::text = nullif(p ->> 'vehicle_class', ''));
    if v_id is null then
      insert into service_item_rules (item_code, vehicle_class, vehicle_id, updated_by) values (p ->> 'item_code', nullif(p ->> 'vehicle_class', '')::vehicle_class, v_vehicle, p_user)
      returning id into v_id;
    end if;
    update service_item_rules set interval_km = nullif(p ->> 'interval_km', '')::integer, interval_months = nullif(p ->> 'interval_months', '')::integer,
           due_soon_km = nullif(p ->> 'due_soon_km', '')::integer, due_soon_days = nullif(p ->> 'due_soon_days', '')::integer,
           block_bookings_when_overdue = nullif(p ->> 'block_bookings_when_overdue', '')::boolean, active = nullif(p ->> 'active', '')::boolean,
           note = nullif(btrim(p ->> 'note'), ''), updated_at = now(), updated_by = p_user
     where id = v_id;
    if v_vehicle is not null then perform app.maint_refresh(v_vehicle); perform app.maint_tasks(v_vehicle); else perform app.maint_refresh_all(); end if;
    return jsonb_build_object('id', v_id);
  when 'maint_rule_delete' then
    perform app.maint_assert(p_user, 'settings');
    delete from service_item_rules where id = nullif(p ->> 'id', '')::uuid returning vehicle_id into v_vehicle;
    perform app.maint_refresh_all();
    return jsonb_build_object('ok', true);
  when 'maint_category_save' then
    perform app.maint_assert(p_user, 'settings');
    if not exists (select 1 from company_expense_categories where code = p ->> 'category_code') then raise exception 'Choose an expense category' using errcode = '22023'; end if;
    if exists (select 1 from jsonb_array_elements_text(coalesce(p -> 'item_codes', '[]'::jsonb)) c where not exists (select 1 from service_items i where i.code = c)) then
      raise exception 'Unknown service item' using errcode = '22023';
    end if;
    if coalesce((p ->> 'remove')::boolean, false) then
      delete from maintenance_categories where category_code = p ->> 'category_code';
    else
      insert into maintenance_categories (category_code, item_codes, updated_by)
      values (p ->> 'category_code', array(select jsonb_array_elements_text(coalesce(p -> 'item_codes', '[]'::jsonb))), p_user)
      on conflict (category_code) do update set item_codes = excluded.item_codes, updated_at = now(), updated_by = p_user;
    end if;
    return jsonb_build_object('ok', true);
  else
    raise exception 'Unknown action %', p_name using errcode = '22023';
  end case;
end $$;

create or replace function app.maint_refresh_all() returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v uuid;
  n integer := 0;
begin
  for v in select id from vehicles x where app.maint_tracked(x) loop
    perform app.maint_refresh(v);
    perform app.maint_tasks(v);
    n := n + 1;
  end loop;
  return n;
end $$;

-- ================================================================ 11. reads
create or replace function app.maint_item_json(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', r.code, 'label', r.label, 'kind', r.kind, 'interval_km', r.interval_km, 'interval_months', r.interval_months,
           'soon_km', r.soon_km, 'soon_days', r.soon_days, 'block_bookings', r.block_bookings, 'block_handover', r.block_handover, 'active', r.active,
           'rule_source', r.rule_source, 'last_done_on', vi.last_done_on, 'last_done_km', vi.last_done_km, 'expires_on', vi.expires_on,
           'expires_source', vi.expires_source, 'next_due_on', vi.next_due_on, 'next_due_km', vi.next_due_km, 'projected_due_on', vi.projected_due_on,
           'due_on', least(vi.next_due_on, vi.projected_due_on), 'status', coalesce(vi.status, 'unknown'), 'detail', vi.detail,
           'status_changed_at', vi.status_changed_at) order by r.sort_order), '[]'::jsonb)
    from app.maint_rules(p_vehicle) r
    left join vehicle_service_items vi on vi.vehicle_id = p_vehicle and vi.item_code = r.code
$$;

create or replace function app.maint_overview(p_user uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v uuid;
begin
  -- a car with no rows yet (added before its first refresh) gets them now
  for v in select x.id from vehicles x where app.maint_tracked(x) and not exists (select 1 from vehicle_service_items vi where vi.vehicle_id = x.id) loop
    perform app.maint_refresh(v);
  end loop;
  return jsonb_build_object(
    'today', app.today(),
    'can_settings', app.maint_can(p_user, 'settings'),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'label', label) order by sort_order), '[]'::jsonb) from service_items where active),
    'to_bill', (select count(*) from vehicle_service_records where voided_at is null and billing_status in ('not_billed', 'needs_admin')),
    'cars', (select coalesce(jsonb_agg(c order by (c ->> 'rank')::integer, c ->> 'due_on' nulls last, c ->> 'name'), '[]'::jsonb) from (
      select jsonb_build_object(
        'vehicle_id', x.id, 'name', app.vehicle_name(x.id), 'plate', x.plate, 'fleet_number', x.fleet_number, 'vehicle_status', x.status,
        'class', x.class, 'supply_type', x.supply_type, 'owner_name', (select o.legal_name from owners o where o.id = x.owner_id),
        'current_km', app.maint_current_km(x.id), 'km_per_day', app.maint_km_per_day(x.id) -> 'rate',
        'worst', coalesce(w.worst, 'unknown'), 'rank', app.maint_status_rank(coalesce(w.worst, 'unknown')),
        'overdue', coalesce(w.overdue, 0), 'due_soon', coalesce(w.due_soon, 0), 'unknown', coalesce(w.unknown, 0), 'due_on', w.due_on,
        'next', w.next,
        'tires', (select jsonb_build_object('season', t.season, 'tread_mm', t.tread_mm) from vehicle_tire_sets t where t.vehicle_id = x.id and t.on_car and t.retired_on is null),
        'chips', w.chips,
        'last_service_on', (select max(done_on) from vehicle_service_records s where s.vehicle_id = x.id and s.voided_at is null)) as c
        from vehicles x
        left join lateral (
          select (array_agg(vi.status order by app.maint_status_rank(vi.status)) filter (where vi.status in ('overdue', 'due_soon', 'unknown', 'ok')))[1] as worst,
                 count(*) filter (where vi.status = 'overdue') as overdue, count(*) filter (where vi.status = 'due_soon') as due_soon,
                 count(*) filter (where vi.status = 'unknown') as unknown,
                 min(least(vi.next_due_on, vi.projected_due_on)) filter (where vi.status in ('overdue', 'due_soon', 'ok')) as due_on,
                 (array_agg(jsonb_build_object('code', vi.item_code, 'label', i.label, 'status', vi.status, 'detail', vi.detail, 'due_on', least(vi.next_due_on, vi.projected_due_on))
                     order by app.maint_status_rank(vi.status), least(vi.next_due_on, vi.projected_due_on) nulls last, i.sort_order)
                   filter (where vi.status in ('overdue', 'due_soon', 'ok')))[1] as next,
                 jsonb_agg(jsonb_build_object('code', vi.item_code, 'label', i.label, 'status', vi.status) order by i.sort_order)
                   filter (where vi.status not in ('off')) as chips
            from vehicle_service_items vi join service_items i on i.code = vi.item_code
           where vi.vehicle_id = x.id) w on true
       where app.maint_tracked(x)) s(c)));
end $$;

create or replace function app.maint_vehicle(p_user uuid, p_vehicle uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
begin
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  perform app.maint_refresh(p_vehicle);
  return jsonb_build_object(
    'vehicle_id', v.id, 'name', app.vehicle_name(v.id), 'plate', v.plate, 'class', v.class, 'fuel', v.fuel, 'supply_type', v.supply_type,
    'tracked', app.maint_tracked(v), 'today', app.today(),
    'current_km', app.maint_current_km(v.id), 'km_per_day', app.maint_km_per_day(v.id),
    'items', app.maint_item_json(v.id),
    'handover_block', app.maint_handover_block(v.id),
    'tire_sets', (select coalesce(jsonb_agg(to_jsonb(t) order by t.retired_on nulls first, t.on_car desc, t.created_at), '[]'::jsonb) from vehicle_tire_sets t where t.vehicle_id = v.id),
    'swaps', (select coalesce(jsonb_agg(jsonb_build_object('swapped_on', w.swapped_on, 'odometer_km', w.odometer_km,
                'from', (select app.maint_season_label(season) from vehicle_tire_sets where id = w.from_set_id),
                'to', (select app.maint_season_label(season) from vehicle_tire_sets where id = w.to_set_id)) order by w.swapped_on desc, w.created_at desc), '[]'::jsonb)
                from vehicle_tire_swaps w where w.vehicle_id = v.id),
    'records', (select coalesce(jsonb_agg(jsonb_build_object(
                  'id', r.id, 'done_on', r.done_on, 'odometer_km', r.odometer_km, 'odometer_estimated', r.odometer_estimated, 'shop', r.shop, 'notes', r.notes,
                  'cost_cents', r.cost_cents, 'hst_cents', r.hst_cents, 'payer', r.payer, 'billing_status', r.billing_status, 'source', r.source,
                  'items', (select coalesce(jsonb_agg(jsonb_build_object('code', ri.item_code, 'label', i.label, 'expires_on', ri.expires_on, 'tread_mm', ri.tread_mm) order by i.sort_order), '[]'::jsonb)
                              from vehicle_service_record_items ri join service_items i on i.code = ri.item_code where ri.record_id = r.id),
                  'company_expense_id', r.company_expense_id,
                  'owner_deduction', (select jsonb_build_object('id', od.id, 'status', od.status) from owner_deductions od where od.id = r.owner_deduction_id),
                  'claim_number', (select claim_number from claims where id = r.claim_id), 'booking_number', (select booking_number from bookings where id = r.booking_id),
                  'receipt_document_id', r.receipt_document_id, 'created_by_name', (select full_name from users where id = r.created_by), 'created_at', r.created_at,
                  'voided_at', r.voided_at, 'void_reason', r.void_reason) order by r.done_on desc, r.created_at desc), '[]'::jsonb)
                  from vehicle_service_records r where r.vehicle_id = v.id),
    'readings', (select coalesce(jsonb_agg(x order by x ->> 'read_at' desc), '[]'::jsonb) from (
                   select jsonb_build_object('id', o.id, 'read_at', o.read_at, 'km', o.km, 'source', o.source, 'voided_at', o.voided_at) as x
                     from vehicle_odometer_readings o where o.vehicle_id = v.id order by o.read_at desc limit 25) z),
    'payers', app.maint_payers(v.id), 'default_payer', app.maint_default_payer(v.id),
    'claims', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'claim_number', c.claim_number, 'status', c.status) order by c.created_at desc), '[]'::jsonb)
                 from claims c where c.vehicle_id = v.id and c.status not in ('closed', 'withdrawn', 'denied', 'distributed')),
    'bookings', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'booking_number', b.booking_number, 'pickup_at', b.pickup_at, 'return_at', b.return_at) order by b.pickup_at desc), '[]'::jsonb)
                   from (select * from bookings b where b.vehicle_id = v.id and b.status::text in ('on_rent', 'returned', 'closed') order by b.pickup_at desc limit 12) b),
    'rules', (select coalesce(jsonb_agg(to_jsonb(k)), '[]'::jsonb) from service_item_rules k where k.vehicle_id = v.id),
    'can_settings', app.maint_can(p_user, 'settings'), 'is_admin', app.user_is_admin(p_user),
    'limit_cents', case when app.user_is_admin(p_user) then null else coalesce((select single_limit_cents from staff_profiles where user_id = p_user), 0) end,
    'hst_bps', coalesce((app.settings()).hst_bps, 1300));
end $$;

-- The owner's view of a car: what was done, when, and what is due. Costs only of what was billed to the owner.
create or replace function app.maint_owner_history(p_vehicle uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.maint_refresh(p_vehicle);
  return jsonb_build_object(
    'items', (select coalesce(jsonb_agg(jsonb_build_object('label', i.label, 'status', vi.status, 'detail', vi.detail, 'last_done_on', vi.last_done_on) order by i.sort_order), '[]'::jsonb)
                from vehicle_service_items vi join service_items i on i.code = vi.item_code where vi.vehicle_id = p_vehicle and vi.status not in ('off')),
    'tires', (select jsonb_build_object('season', app.maint_season_label(t.season), 'tread_mm', t.tread_mm) from vehicle_tire_sets t where t.vehicle_id = p_vehicle and t.on_car and t.retired_on is null),
    'records', (select coalesce(jsonb_agg(jsonb_build_object(
                  'done_on', r.done_on, 'odometer_km', case when r.odometer_estimated then null else r.odometer_km end, 'shop', r.shop,
                  'items', (select string_agg(i.label, ', ' order by i.sort_order) from vehicle_service_record_items ri join service_items i on i.code = ri.item_code where ri.record_id = r.id),
                  'billed_to_you_cents', case when r.payer = 'owner' and r.owner_deduction_id is not null then r.cost_cents + r.hst_cents end,
                  'paid_by', case r.payer when 'owner' then case when r.owner_deduction_id is not null then 'Deducted on your statement' else 'You' end
                                          when 'company' then 'CarmaCars' when 'claim' then 'A claim' when 'renter' then 'The renter' else 'No charge' end)
                  order by r.done_on desc, r.created_at desc), '[]'::jsonb)
                  from vehicle_service_records r where r.vehicle_id = p_vehicle and r.voided_at is null));
end $$;

create or replace function app.maint_settings_read() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'items', (select coalesce(jsonb_agg(to_jsonb(i) order by i.sort_order), '[]'::jsonb) from service_items i),
    'rules', (select coalesce(jsonb_agg(to_jsonb(k) || jsonb_build_object('vehicle_name', case when k.vehicle_id is not null then app.vehicle_name(k.vehicle_id) || coalesce(' ' || v.plate, '') end)
                order by k.item_code, k.vehicle_class nulls last), '[]'::jsonb)
                from service_item_rules k left join vehicles v on v.id = k.vehicle_id),
    'categories', (select coalesce(jsonb_agg(jsonb_build_object('code', c.code, 'label', c.label, 'item_codes', m.item_codes, 'is_service', m.category_code is not null) order by c.label), '[]'::jsonb)
                     from company_expense_categories c left join maintenance_categories m on m.category_code = c.code where c.is_active),
    'classes', (select jsonb_agg(e.enumlabel order by e.enumsortorder) from pg_enum e where e.enumtypid = 'vehicle_class'::regtype),
    'vehicles', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', app.vehicle_name(x.id) || coalesce(' ' || x.plate, '')) order by x.make, x.model), '[]'::jsonb)
                   from vehicles x where app.maint_tracked(x)))
$$;

-- ================================================================ 12. the daily watch, To do and the digest line
create or replace function app.job_maintenance_watch(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v_day date := app.local_date(p_now);
  v_run uuid;
  n integer;
begin
  if app.local_hour(p_now) < 6 then return 'not_due'; end if;
  v_run := app.job_claim('maintenance-watch', v_day::text);
  if v_run is null then return 'already_run'; end if;
  begin
    n := app.maint_refresh_all();
    perform app.job_succeed(v_run, jsonb_build_object('day', v_day, 'cars', n));
    return 'succeeded';
  exception when others then
    perform app.job_fail(v_run, sqlerrm);
    return 'failed';
  end;
end $$;

create or replace function app.maint_digest_line() returns jsonb
language sql stable security definer set search_path = public, app as $$
  with c as (
    select x.id,
           bool_or(vi.status = 'overdue') as over, bool_or(vi.status = 'due_soon') as soon, bool_or(vi.status = 'unknown') as unknown
      from vehicles x join vehicle_service_items vi on vi.vehicle_id = x.id
     where app.maint_tracked(x) group by x.id)
  select case when count(*) filter (where over or soon) = 0 then null else jsonb_build_object(
    'line', format('Maintenance: %s car%s overdue, %s due soon', count(*) filter (where over), case when count(*) filter (where over) = 1 then '' else 's' end,
                   count(*) filter (where soon and not over)),
    'meta', format('%s car%s with no service record yet', count(*) filter (where unknown), case when count(*) filter (where unknown) = 1 then '' else 's' end)) end
    from c
$$;

alter function app.notify_digests(text, uuid, timestamptz) rename to notify_digests_pre0089;
create or replace function app.notify_digests(p_slot text, p_run uuid, p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb;
begin
  if p_slot = 'morning' and (app.settings(app.local_date(p_now))).maint_digest_enabled then
    begin
      v := app.maint_digest_line();
      if v is not null then
        insert into staff_digest_items (role, code, digest_slot, line, meta, url, dedupe_key, created_at)
        values ('admin', 'staff_expiry_watch', 'next', v ->> 'line', v ->> 'meta', (app.settings()).notify_base_url || '/admin/maintenance',
                'maint_day:admin:' || app.local_date(p_now), p_now - interval '1 second'),
               ('va_fleet', 'staff_expiry_watch', 'next', v ->> 'line', v ->> 'meta', (app.settings()).notify_base_url || '/va/maintenance',
                'maint_day:va_fleet:' || app.local_date(p_now), p_now - interval '1 second')
        on conflict (dedupe_key) do nothing;
      end if;
    exception when others then raise warning 'maintenance digest line not added: %', sqlerrm;
    end;
  end if;
  return app.notify_digests_pre0089(p_slot, p_run, p_now);
end $$;

alter function app.admin_todo(uuid) rename to admin_todo_pre0089;
create or replace function app.admin_todo(p_admin uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.admin_todo_pre0089(p_admin);
begin
  return jsonb_set(v, '{items}', coalesce(v -> 'items', '[]'::jsonb) || jsonb_build_array(
    jsonb_build_object('key', 'maintenance_due', 'label', 'Cars with a service overdue or due soon', 'button', 'See them', 'href', '/admin/maintenance?show=due',
                       'count', (select count(distinct vi.vehicle_id) from vehicle_service_items vi join vehicles x on x.id = vi.vehicle_id
                                  where vi.status in ('overdue', 'due_soon') and app.maint_tracked(x))),
    jsonb_build_object('key', 'maintenance_bill', 'label', 'Services recorded and not billed yet', 'button', 'Bill them', 'href', '/admin/maintenance?show=bill',
                       'count', (select count(*) from vehicle_service_records where voided_at is null and billing_status in ('not_billed', 'needs_admin'))),
    jsonb_build_object('key', 'maintenance_unknown', 'label', 'Cars with no service record yet', 'button', 'Record', 'href', '/admin/maintenance?show=unknown',
                       'count', (select count(distinct vi.vehicle_id) from vehicle_service_items vi join vehicles x on x.id = vi.vehicle_id
                                  where vi.status = 'unknown' and app.maint_tracked(x)))));
end $$;

-- ================================================================ 13. the winter tire add-on follows the tires
create or replace function app.maint_winter_state(p_vehicle uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case when not exists (select 1 from vehicle_tire_sets t where t.vehicle_id = p_vehicle and t.retired_on is null) then 'unknown'
              when exists (select 1 from vehicle_tire_sets t where t.vehicle_id = p_vehicle and t.retired_on is null and t.on_car and t.season = 'winter') then 'on'
              when exists (select 1 from vehicle_tire_sets t where t.vehicle_id = p_vehicle and t.retired_on is null and t.season = 'winter') then 'stored'
              else 'none' end
$$;

create or replace function app.addon_applies(a addons, v vehicles, p_at timestamptz) returns boolean
language sql stable security definer set search_path = public, app as $$
  select (cardinality(a.vehicle_classes) = 0 or v.class = any (a.vehicle_classes))
     and (cardinality(a.vehicle_ids) = 0 or v.id = any (a.vehicle_ids))
     and not (v.id = any (a.excluded_vehicle_ids))
     and not (v.fuel is not null and v.fuel = any (a.excluded_fuel_types))
     and (cardinality(a.available_months) = 0 or p_at is null
          or extract(month from app.local_date(p_at))::integer = any (a.available_months))
     -- 0089: winter tires only on a car that has a winter set (on it or stored), or no tire record yet
     and not (a.code = 'winter_tire' and coalesce((app.settings()).maint_winter_addon_link, true) and app.maint_winter_state(v.id) = 'none')
$$;

create or replace function app.addons_for_car(p_vehicle uuid, p_pickup timestamptz default null, p_return timestamptz default null, p_booking uuid default null)
returns jsonb language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'code', a.code, 'name', a.name,
           'description', case when a.code = 'winter_tire' and app.maint_winter_state(v.id) = 'on'
                               then concat_ws(' ', nullif(a.description, ''), 'This car is on winter tires now.') else a.description end,
           'photo_path', a.photo_path,
           'pricing_unit', a.pricing_unit, 'unit_price_cents', app.addon_unit_price(a, v), 'max_days', a.max_days, 'cap_cents', a.cap_cents,
           'min_hours', a.min_hours, 'hst_applies', a.hst_applies, 'lead_time_hours', a.lead_time_hours, 'max_per_booking', a.max_per_booking,
           'needs_confirmation', a.needs_confirmation, 'prepaid_fuel', a.prepaid_fuel, 'non_refundable_after_lead', a.non_refundable_after_lead,
           'available', case when a.stock_count is null or p_pickup is null or p_return is null then null
                             else greatest(a.stock_count - app.addon_held(a.id, p_pickup, p_return, p_booking), 0) end,
           'notice_ok', p_pickup is null or a.lead_time_hours = 0 or p_pickup >= now() + make_interval(hours => a.lead_time_hours))
           order by a.sort_order, a.name), '[]'::jsonb)
    from addons a join vehicles v on v.id = p_vehicle
   where a.active and a.price_cents is not null and app.addon_applies(a, v, p_pickup)
$$;

-- ================================================================ 14. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0089;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_read', 'ops_do', 'admin_read', 'admin_do', 'va_read', 'va_do') and p_name like 'maint\_%' then
    perform app.door_begin(p_user, p_aal);
    if p_call in ('ops_read', 'admin_read', 'va_read') and p_name not in ('maint_overview', 'maint_vehicle', 'maint_owner', 'maint_settings', 'maint_receipt') then
      raise exception 'Unknown screen %', p_name using errcode = '22023';
    end if;
    return app.maint_door(p_user, p_call, p_name, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre0089(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ 15. backfill
-- readings from what the system already holds, so km a day works from the first day
insert into vehicle_odometer_readings (vehicle_id, read_at, km, source, source_id, created_by)
select c.vehicle_id, coalesce(c.completed_at, c.performed_at, c.created_at), c.odometer_km,
       case c.kind when 'pickup' then 'handover' when 'return' then 'return' else 'condition_report' end, c.id, c.performed_by
  from condition_reports c where c.odometer_km > 0
on conflict do nothing;
insert into vehicle_odometer_readings (vehicle_id, read_at, km, source, source_id)
select b.vehicle_id, coalesce(b.handed_over_at, b.pickup_at), b.odometer_out_km, 'rental', app.maint_uuid_tag(b.id, 'out') from bookings b where b.odometer_out_km > 0
union all
select b.vehicle_id, coalesce(b.checked_in_at, b.return_at), b.odometer_in_km, 'rental', app.maint_uuid_tag(b.id, 'in') from bookings b where b.odometer_in_km > 0
on conflict do nothing;
insert into vehicle_odometer_readings (vehicle_id, read_at, km, source, source_id, created_by)
select m.vehicle_id, m.started_at, m.odometer_start, 'move', app.maint_uuid_tag(m.id, 'start'), m.staff_user_id from vehicle_moves m where m.odometer_start > 0
union all
select m.vehicle_id, coalesce(m.ended_at, m.started_at), m.odometer_end, 'move', app.maint_uuid_tag(m.id, 'end'), m.staff_user_id from vehicle_moves m where m.odometer_end > 0
on conflict do nothing;
insert into vehicle_odometer_readings (vehicle_id, read_at, km, source, source_id, created_by)
select i.vehicle_id, coalesce(i.submitted_at, i.created_at), i.odometer_km, 'listing', i.id, i.started_by from listing_intakes i where i.odometer_km > 0
on conflict do nothing;
insert into vehicle_odometer_readings (vehicle_id, read_at, km, source)
select v.id, v.updated_at, v.odometer_km, 'car' from vehicles v
 where v.odometer_km > 0 and not exists (select 1 from vehicle_odometer_readings r where r.vehicle_id = v.id and r.km = v.odometer_km);

-- every real car: its items (unknown until the last service is recorded) and its tasks
do $$ begin perform app.maint_refresh_all(); end $$;

-- ================================================================ 16. the daily job
do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-maintenance-watch', '23 * * * *', 'select app.job_maintenance_watch()');
  end if;
end $$;

-- ================================================================ 17. privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and (p.proname like 'maint\_%' or p.proname like '%\_pre0089'
            or p.proname = any (array['job_maintenance_watch', 'notify_digests', 'admin_todo', 'addon_applies', 'addons_for_car', 'door', 'guide_release_0089']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ================================================================ 18. the guides for this release
create or replace function app.guide_release_0089(p_portal text, p_slug text, p_kind text, p_after text, p_base_md text, p_title text, p_blurb text,
                                                  p_md text, p_html text) returns text
language sql security definer set search_path = public, app as $$
  select app.guide_release_section(p_portal, p_slug, p_kind, p_after, p_base_md, p_title, p_blurb, p_md, p_html)
$$;
revoke all on function app.guide_release_0089(text, text, text, text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function app.guide_release_0089(text, text, text, text, text, text, text, text, text) to service_role;

-- GUIDES 0089 START (generated by supabase/seed/0089_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_0089('owner', 'home-and-your-vehicles', 'chapter', 'apply-and-get-your-car-listed', 'Home tells you what to do next. Each car has its own page with its status, terms, bookings, invoices and photos.

## Home at a glance

1. The menu: Home, Vehicles, Bookings, Invoices, Statements, Payouts, Documents, Banking, Notifications and Profile.
2. Your vehicles: each car with its status and what it needs next.
3. Money: what is due now, your fees each month, the next billing date and the next payout date.
4. Got another car? Press **Add a vehicle**.

![](/guides/img/owner-01-home-desktop-841aa611.jpg "desktop; size: 1440 760; address: carmacars.ca/owner; pins: 1 32.6 22.9, 2 42.7 52.6, 3 74.7 50.0, 4 38.9 46.1")

> Tip: When something needs you (a signature, a payment or an upload), it is the first thing on Home.

## A car''s page

Open Vehicles, then a car.

1. The top shows the car, its plate and how it is enrolled, with its status.
2. Terms: the Insurance Fee, the Revenue Share, your enrolment date and a link to the listing.
3. Bookings shows every trip in your car. **Book it for myself** reserves it for you.
4. Leaving explains the exit notice and has the button to give it.

![](/guides/img/owner-03-vehicle-desktop-fc3e7e98.jpg "desktop; size: 1440 1292; address: carmacars.ca/owner/vehicles/aece3b1c-489e-4ad0-a2f0-c34415506c58; pins: 1 47.9 14.9, 2 73.4 24.6, 3 23.3 76.4, 4 81.9 64.6")

While a car is being set up, its page also shows the onboarding checklist and the uploads it still needs: the ownership permit, the lender''s permission and the insurance.

## Take new listing photos

Good photos get more bookings. You can shoot them yourself with your phone.

1. On the car''s page, press **Add listing photos** (or **Take new photos** for a car already live).
2. Read the tips for each shot: daylight, a plain background, the phone held landscape.
3. Press **Take photo** for each shot in the list. Press **Retake** if one is not right.
4. The bar shows how many required photos you have.
5. Press **Submit for listing**. New photos replace the current ones once our team approves them.

![](/guides/img/field-06-photo-shoot-capture-phone-d0b13740.jpg "phone; size: 390 610; pins: 4 92.3 43.4, 3 76.9 70.2")
', 'Home and your vehicles', 'What Home shows, each car''s page, adding a car and new listing photos.',
  'Home tells you what to do next. Each car has its own page with its status, terms, bookings, invoices and photos.

## Home at a glance

1. The menu: Home, Vehicles, Bookings, Invoices, Statements, Payouts, Documents, Banking, Notifications and Profile.
2. Your vehicles: each car with its status and what it needs next.
3. Money: what is due now, your fees each month, the next billing date and the next payout date.
4. Got another car? Press **Add a vehicle**.

![](/guides/img/owner-01-home-desktop-841aa611.jpg "desktop; size: 1440 760; address: carmacars.ca/owner; pins: 1 32.6 22.9, 2 42.7 52.6, 3 74.7 50.0, 4 38.9 46.1")

> Tip: When something needs you (a signature, a payment or an upload), it is the first thing on Home.

## A car''s page

Open Vehicles, then a car.

1. The top shows the car, its plate and how it is enrolled, with its status.
2. Terms: the Insurance Fee, the Revenue Share, your enrolment date and a link to the listing.
3. Bookings shows every trip in your car. **Book it for myself** reserves it for you.
4. Leaving explains the exit notice and has the button to give it.

![](/guides/img/owner-03-vehicle-desktop-fc3e7e98.jpg "desktop; size: 1440 1292; address: carmacars.ca/owner/vehicles/aece3b1c-489e-4ad0-a2f0-c34415506c58; pins: 1 47.9 14.9, 2 73.4 24.6, 3 23.3 76.4, 4 81.9 64.6")

While a car is being set up, its page also shows the onboarding checklist and the uploads it still needs: the ownership permit, the lender''s permission and the insurance.

## Service and maintenance

On a car''s page, under Service and maintenance.

- What is due on your car (oil change, tires, brakes, inspections, the registration) and the tires on it.
- Every service we recorded: the date, the odometer, the shop, what was done and who paid.
- You pay for maintenance and routine wear (your agreement, 11.1). A service we paid for shows its amount and is deducted on your next statement as an owner cost.
- It is read only: call or message us about a service.

## Take new listing photos

Good photos get more bookings. You can shoot them yourself with your phone.

1. On the car''s page, press **Add listing photos** (or **Take new photos** for a car already live).
2. Read the tips for each shot: daylight, a plain background, the phone held landscape.
3. Press **Take photo** for each shot in the list. Press **Retake** if one is not right.
4. The bar shows how many required photos you have.
5. Press **Submit for listing**. New photos replace the current ones once our team approves them.

![](/guides/img/field-06-photo-shoot-capture-phone-d0b13740.jpg "phone; size: 390 610; pins: 4 92.3 43.4, 3 76.9 70.2")
',
  '<p class="gd-p">Home tells you what to do next. Each car has its own page with its status, terms, bookings, invoices and photos.</p><section class="gd-task" id="home-and-your-vehicles-home-at-a-glance" data-gd-task><h2 class="gd-h2">Home at a glance</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The menu: Home, Vehicles, Bookings, Invoices, Statements, Payouts, Documents, Banking, Notifications and Profile.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Your vehicles: each car with its status and what it needs next.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Money: what is due now, your fees each month, the next billing date and the next payout date.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Got another car? Press <b class="gd-ui">Add a vehicle</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/760"><img src="/guides/img/owner-01-home-desktop-841aa611.jpg" alt="" loading="lazy" decoding="async" width="1440" height="760"><span class="gd-pin" style="left:32.6%;top:22.9%" aria-hidden="true">1</span><span class="gd-pin" style="left:42.7%;top:52.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:74.7%;top:50%" aria-hidden="true">3</span><span class="gd-pin" style="left:38.9%;top:46.1%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>When something needs you (a signature, a payment or an upload), it is the first thing on Home.</div></aside></section><section class="gd-task" id="home-and-your-vehicles-a-car-s-page" data-gd-task><h2 class="gd-h2">A car&#39;s page</h2><p class="gd-p">Open Vehicles, then a car.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The top shows the car, its plate and how it is enrolled, with its status.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Terms: the Insurance Fee, the Revenue Share, your enrolment date and a link to the listing.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Bookings shows every trip in your car. <b class="gd-ui">Book it for myself</b> reserves it for you.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Leaving explains the exit notice and has the button to give it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/vehicles/aece3b1c-489e-4ad0-a2f0-c34415506c58</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1292"><img src="/guides/img/owner-03-vehicle-desktop-fc3e7e98.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1292"><span class="gd-pin" style="left:47.9%;top:14.9%" aria-hidden="true">1</span><span class="gd-pin" style="left:73.4%;top:24.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:23.3%;top:76.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:81.9%;top:64.6%" aria-hidden="true">4</span></div></div></figure></div><p class="gd-p">While a car is being set up, its page also shows the onboarding checklist and the uploads it still needs: the ownership permit, the lender&#39;s permission and the insurance.</p></section><section class="gd-task" id="home-and-your-vehicles-service-and-maintenance" data-gd-task><h2 class="gd-h2">Service and maintenance</h2><p class="gd-p">On a car&#39;s page, under Service and maintenance.</p><ul class="gd-ul"><li>What is due on your car (oil change, tires, brakes, inspections, the registration) and the tires on it.</li><li>Every service we recorded: the date, the odometer, the shop, what was done and who paid.</li><li>You pay for maintenance and routine wear (your agreement, 11.1). A service we paid for shows its amount and is deducted on your next statement as an owner cost.</li><li>It is read only: call or message us about a service.</li></ul></section><section class="gd-task" id="home-and-your-vehicles-take-new-listing-photos" data-gd-task><h2 class="gd-h2">Take new listing photos</h2><p class="gd-p">Good photos get more bookings. You can shoot them yourself with your phone.</p><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On the car&#39;s page, press <b class="gd-ui">Add listing photos</b> (or <b class="gd-ui">Take new photos</b> for a car already live).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Read the tips for each shot: daylight, a plain background, the phone held landscape.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Take photo</b> for each shot in the list. Press <b class="gd-ui">Retake</b> if one is not right.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The bar shows how many required photos you have.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Submit for listing</b>. New photos replace the current ones once our team approves them.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/610"><img src="/guides/img/field-06-photo-shoot-capture-phone-d0b13740.jpg" alt="" loading="lazy" decoding="async" width="390" height="610"><span class="gd-pin" style="left:92.3%;top:43.4%" aria-hidden="true">4</span><span class="gd-pin" style="left:76.9%;top:70.2%" aria-hidden="true">3</span></div></div></figure></div></section>');
select app.guide_release_0089('admin', 'maintenance-and-service', 'chapter', 'add-ons', null, 'Maintenance and service', 'The fleet overview, recording a service and its bill, tires and swaps, the odometer, intervals, reminders and blocks.',
  'Every real car has its service items: oil, tire rotation, brakes, tires, the seasonal swap, the safety inspection, the registration, battery, wipers, filters, alignment, fluids and the annual inspection. Record a service once and the bill is made and the timers reset by themselves.

## The fleet overview

Open **Cars** > **Maintenance**.

1. Every real car (sample cars are left out), most urgent first: overdue, then due soon, then cars with no record yet, then all OK.
2. Each car shows what is due next, its odometer, its km a day, the tires on it and the date of its last service.
3. Use Show, Service item, Sort and the search (car, plate or owner) to narrow the list, then press Apply.
4. Press **Record a service** on a car to record it without leaving the list.

| Status | Means |
| --- | --- |
| Overdue | Past its km or its date (whichever came first), or expired |
| Due soon | Within 1,000 km or 14 days of it (each item may have its own; inspections and registration: 30 days) |
| Unknown | No record yet: record the last time it was done |
| OK | Done, and not due soon |

## Record a service in one step

From the overview, the car''s **Maintenance** tab, or a To do line.

1. Tick what was done. The items due are ticked already.
2. Check the date and the odometer (filled with the current reading). Type the shop, the cost before HST and the HST (worked out at 13%, change it to match the receipt).
3. Who pays: the owner (deducted on the owner''s next statement, owner agreement 11.1; the default for an owner''s car), CarmaCars (a company expense; the default for a company car), a claim (a repair cost on the claim), the renter (a charge at cost on the rental), or no charge.
4. Leave **The bill is in: bill it now** ticked to make the bill now, or untick it and press **Bill now** on the record when the bill comes in. Add the receipt.
5. Press **Record the service**. Each item done is OK again, with its next date and km.

- An inspection or the registration: type the new expiry date, or leave it empty for 12 months from the service.
- Tires: type the tread depth measured, or tick New tires put on (the old set is retired as replaced).
- Seasonal swap: choose the set that went on and where the removed set is stored.
- An expense entered under Money, Expenses with a car and a service category (Car service: oil change, brakes, and so on) records the service too. Voiding either voids the other.
- **Void** on a record sets the timers back. A company expense is voided and an open owner cost is waived; a cost already on a statement or a claim stays, and the void is refused with what to do.

## Tires and the seasonal swap

On the car''s **Maintenance** tab, under Tires.

1. **Add a tire set**: kind (summer, all-season, winter or all-weather), size, brand, tread depth, made (DOT) and bought dates, where it is stored, and whether it is on the car.
2. **Put on the car** swaps sets and keeps the swap in the history.
3. Tires are due soon at 4 mm of tread or 5.5 years old, overdue at 3 mm or 6 years.
4. The swap follows Ontario: winter tires on by December 1 (reminder from November 1), off after April 1 (reminder from April 1, overdue after May 1). All-weather tires need no swap.

> Tip: The Winter tires add-on is offered only on cars with a winter set (on the car or stored), or with no tire record yet. A car on winter tires says so on the add-on.

## The odometer

- The current odometer is the highest reading from handover and return reports, field staff moves, the rental''s odometer out and in, listing photos, the car record, services and readings added by hand.
- Km a day comes from the readings of the last 90 days (else the rentals, else 60 km a day). It gives the date a km interval will be reached.
- **Add a reading** on the car; a reading lower than the last one needs the tick. An Admin can void a wrong reading.

## Intervals, reminders and blocks

Open **Settings** > **Maintenance**.

- Each item''s default interval: **Change**. Whichever of km and months comes first is due; 0 or empty means not by that measure.
- **Add an interval** for a class or one car. A car''s own comes first, then its class''s, then the default. On the car''s tab, **Set an interval for this car** does the same.
- Which expense categories are a service, and the items each records.
- Reminders: one Fleet task per car with what is due, To do lines (cars due, services to bill, cars with no record yet) and one line in the morning digest. No other email.
- Handover is refused while a recorded safety inspection or registration has expired. Block new bookings when overdue is off for every item until you turn it on.

Cars that were in the fleet before maintenance came in start as unknown, with one task each to record the last service. Enter what you know once.
',
  '<p class="gd-p">Every real car has its service items: oil, tire rotation, brakes, tires, the seasonal swap, the safety inspection, the registration, battery, wipers, filters, alignment, fluids and the annual inspection. Record a service once and the bill is made and the timers reset by themselves.</p><section class="gd-task" id="maintenance-and-service-the-fleet-overview" data-gd-task><h2 class="gd-h2">The fleet overview</h2><p class="gd-p">Open <b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Maintenance</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every real car (sample cars are left out), most urgent first: overdue, then due soon, then cars with no record yet, then all OK.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each car shows what is due next, its odometer, its km a day, the tires on it and the date of its last service.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Use Show, Service item, Sort and the search (car, plate or owner) to narrow the list, then press Apply.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Record a service</b> on a car to record it without leaving the list.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Status</th><th scope="col">Means</th></tr></thead><tbody><tr><td>Overdue</td><td>Past its km or its date (whichever came first), or expired</td></tr><tr><td>Due soon</td><td>Within 1,000 km or 14 days of it (each item may have its own; inspections and registration: 30 days)</td></tr><tr><td>Unknown</td><td>No record yet: record the last time it was done</td></tr><tr><td>OK</td><td>Done, and not due soon</td></tr></tbody></table></div></section><section class="gd-task" id="maintenance-and-service-record-a-service-in-one-step" data-gd-task><h2 class="gd-h2">Record a service in one step</h2><p class="gd-p">From the overview, the car&#39;s <b class="gd-ui">Maintenance</b> tab, or a To do line.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Tick what was done. The items due are ticked already.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the date and the odometer (filled with the current reading). Type the shop, the cost before HST and the HST (worked out at 13%, change it to match the receipt).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Who pays: the owner (deducted on the owner&#39;s next statement, owner agreement 11.1; the default for an owner&#39;s car), CarmaCars (a company expense; the default for a company car), a claim (a repair cost on the claim), the renter (a charge at cost on the rental), or no charge.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Leave <b class="gd-ui">The bill is in: bill it now</b> ticked to make the bill now, or untick it and press <b class="gd-ui">Bill now</b> on the record when the bill comes in. Add the receipt.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Record the service</b>. Each item done is OK again, with its next date and km.</div></li></ol></div><ul class="gd-ul"><li>An inspection or the registration: type the new expiry date, or leave it empty for 12 months from the service.</li><li>Tires: type the tread depth measured, or tick New tires put on (the old set is retired as replaced).</li><li>Seasonal swap: choose the set that went on and where the removed set is stored.</li><li>An expense entered under Money, Expenses with a car and a service category (Car service: oil change, brakes, and so on) records the service too. Voiding either voids the other.</li><li><b class="gd-ui">Void</b> on a record sets the timers back. A company expense is voided and an open owner cost is waived; a cost already on a statement or a claim stays, and the void is refused with what to do.</li></ul></section><section class="gd-task" id="maintenance-and-service-tires-and-the-seasonal-swap" data-gd-task><h2 class="gd-h2">Tires and the seasonal swap</h2><p class="gd-p">On the car&#39;s <b class="gd-ui">Maintenance</b> tab, under Tires.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Add a tire set</b>: kind (summer, all-season, winter or all-weather), size, brand, tread depth, made (DOT) and bought dates, where it is stored, and whether it is on the car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Put on the car</b> swaps sets and keeps the swap in the history.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Tires are due soon at 4 mm of tread or 5.5 years old, overdue at 3 mm or 6 years.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The swap follows Ontario: winter tires on by December 1 (reminder from November 1), off after April 1 (reminder from April 1, overdue after May 1). All-weather tires need no swap.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The Winter tires add-on is offered only on cars with a winter set (on the car or stored), or with no tire record yet. A car on winter tires says so on the add-on.</div></aside></section><section class="gd-task" id="maintenance-and-service-the-odometer" data-gd-task><h2 class="gd-h2">The odometer</h2><ul class="gd-ul"><li>The current odometer is the highest reading from handover and return reports, field staff moves, the rental&#39;s odometer out and in, listing photos, the car record, services and readings added by hand.</li><li>Km a day comes from the readings of the last 90 days (else the rentals, else 60 km a day). It gives the date a km interval will be reached.</li><li><b class="gd-ui">Add a reading</b> on the car; a reading lower than the last one needs the tick. An Admin can void a wrong reading.</li></ul></section><section class="gd-task" id="maintenance-and-service-intervals-reminders-and-blocks" data-gd-task><h2 class="gd-h2">Intervals, reminders and blocks</h2><p class="gd-p">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Maintenance</b>.</p><ul class="gd-ul"><li>Each item&#39;s default interval: <b class="gd-ui">Change</b>. Whichever of km and months comes first is due; 0 or empty means not by that measure.</li><li><b class="gd-ui">Add an interval</b> for a class or one car. A car&#39;s own comes first, then its class&#39;s, then the default. On the car&#39;s tab, <b class="gd-ui">Set an interval for this car</b> does the same.</li><li>Which expense categories are a service, and the items each records.</li><li>Reminders: one Fleet task per car with what is due, To do lines (cars due, services to bill, cars with no record yet) and one line in the morning digest. No other email.</li><li>Handover is refused while a recorded safety inspection or registration has expired. Block new bookings when overdue is off for every item until you turn it on.</li></ul><p class="gd-p">Cars that were in the fleet before maintenance came in start as unknown, with one task each to record the last service. Enter what you know once.</p></section>');
select app.guide_release_0089('va', 'car-maintenance', 'chapter', 'add-ons', null, 'Car maintenance', 'The maintenance list, recording a service in one step, tires and swaps, readings, and billing.',
  'Fleet keeps every car serviced: oil, tires, brakes, inspections and the registration. Finance bills what Fleet records. Recording a service resets its reminders and makes its bill.

## What is due

Open **Field work** > **Maintenance** (Finance: **Money** > **Maintenance bills**).

1. Every car, most urgent first: overdue (red), due soon, no record yet (dashed), all OK.
2. Your To do has one Service due task per car listing what is due. Open it: the car opens with the record pop-up.
3. A car with no record yet has one task to record its last service. Enter what you know once.

## Record a service

1. Press **Record a service** on the car (or **Record** on one item of the car''s Maintenance).
2. Tick what was done, check the date and the odometer, type the shop, the cost before HST and the HST, and add the receipt.
3. Who pays: the owner for an owner''s car (deducted on their statement), CarmaCars for a company car, a claim, the renter, or no charge.
4. Leave **The bill is in: bill it now** ticked, or untick it and press **Bill now** on the record later.
5. Press **Record the service**. The items done are OK again.

> Watch out: Above your single limit the service is recorded and the timers reset, but an Admin bills it: you see "An Admin bills it".

## Tires, swaps and readings

- Under Tires: **Add a tire set** (kind, size, brand, tread, made and bought dates, where it is stored), **Put on the car** to swap.
- Ontario: winter tires on by December 1 (reminder from November 1), off after April 1. Tires are due soon at 4 mm of tread, overdue at 3 mm.
- **Add a reading** when you see the odometer. Handover, return and move readings come in by themselves.
- A car whose recorded safety inspection or registration has expired cannot be handed over until the renewal is recorded.
',
  '<p class="gd-p">Fleet keeps every car serviced: oil, tires, brakes, inspections and the registration. Finance bills what Fleet records. Recording a service resets its reminders and makes its bill.</p><section class="gd-task" id="car-maintenance-what-is-due" data-gd-task><h2 class="gd-h2">What is due</h2><p class="gd-p">Open <b class="gd-ui">Field work</b> &gt; <b class="gd-ui">Maintenance</b> (Finance: <b class="gd-ui">Money</b> &gt; <b class="gd-ui">Maintenance bills</b>).</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every car, most urgent first: overdue (red), due soon, no record yet (dashed), all OK.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Your To do has one Service due task per car listing what is due. Open it: the car opens with the record pop-up.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A car with no record yet has one task to record its last service. Enter what you know once.</div></li></ol></div></section><section class="gd-task" id="car-maintenance-record-a-service" data-gd-task><h2 class="gd-h2">Record a service</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Record a service</b> on the car (or <b class="gd-ui">Record</b> on one item of the car&#39;s Maintenance).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Tick what was done, check the date and the odometer, type the shop, the cost before HST and the HST, and add the receipt.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Who pays: the owner for an owner&#39;s car (deducted on their statement), CarmaCars for a company car, a claim, the renter, or no charge.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Leave <b class="gd-ui">The bill is in: bill it now</b> ticked, or untick it and press <b class="gd-ui">Bill now</b> on the record later.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Record the service</b>. The items done are OK again.</div></li></ol></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Above your single limit the service is recorded and the timers reset, but an Admin bills it: you see &quot;An Admin bills it&quot;.</div></aside></section><section class="gd-task" id="car-maintenance-tires-swaps-and-readings" data-gd-task><h2 class="gd-h2">Tires, swaps and readings</h2><ul class="gd-ul"><li>Under Tires: <b class="gd-ui">Add a tire set</b> (kind, size, brand, tread, made and bought dates, where it is stored), <b class="gd-ui">Put on the car</b> to swap.</li><li>Ontario: winter tires on by December 1 (reminder from November 1), off after April 1. Tires are due soon at 4 mm of tread, overdue at 3 mm.</li><li><b class="gd-ui">Add a reading</b> when you see the odometer. Handover, return and move readings come in by themselves.</li><li>A car whose recorded safety inspection or registration has expired cannot be handed over until the renewal is recorded.</li></ul></section>');
-- GUIDES 0089 END
