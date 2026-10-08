-- 0025: the owner's answers.
--
-- Every open question was answered; this migration applies the answers. Record:
-- docs/changes/0025_owner_answers.md. No earlier migration is edited. Functions created again
-- here keep their signatures; each says what changed and why.
--
-- Sections:
--   0  settings and reference tables (timing, classes, deposits, kilometres, age, fees,
--      coverage, delivery and airports, site settings, reply-to aliases)
--   1  vehicle swap: revenue follows the car (segments)
--   2  expired offers close and go back to staff
--   3  pricing and the public reads (shared pricer, quote, request, search, fleet)
--   4  review requests held for a staff decision
--   5  cookie consent
--   6  row-level security, privileges, audit

-- =====================================================================================
-- 0. Settings
-- =====================================================================================

-- Timing (decision 3). Every dated row is brought to the owner's answer, so the rule holds
-- whatever date a booking is judged on.
update program_settings
   set turnaround_buffer_minutes = 120,
       booking_min_notice_minutes = 120,
       take_deposit_lead_minutes = 60,
       opening_hours = '{"days": [1, 2, 3, 4, 5, 6, 7], "open": "09:00", "close": "18:00", "always_open": true}'::jsonb,
       company_email = coalesce(nullif(company_email, ''), 'contact@carmacars.ca'),
       company_phone = coalesce(nullif(company_phone, ''), '+16475753377'),
       incident_line_phone = coalesce(nullif(incident_line_phone, ''), '+16475753377'),
       privacy_officer_email = coalesce(nullif(privacy_officer_email, ''), 'privacy@carmacars.ca');

-- The business is always open (decision 3): opening_hours.always_open makes every minute an
-- opening minute for due times. "open" and "close" stay as the times of the daily opening and
-- closing checks (0020's ops-watch job).
create or replace function app.add_opening_minutes(p_from timestamptz, p_minutes integer)
returns timestamptz language plpgsql stable security definer set search_path = public, app as $$
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
  if coalesce((v_hours ->> 'always_open')::boolean, false) or v_close <= v_open or cardinality(v_days) = 0 then
    return p_from + make_interval(mins => v_left);     -- always open, or hours not usable: plain minutes
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

-- a new dated row of settings starts from the same answers
alter table program_settings
  alter column turnaround_buffer_minutes set default 120,
  alter column booking_min_notice_minutes set default 120,
  alter column take_deposit_lead_minutes set default 60,
  alter column opening_hours set default '{"days": [1, 2, 3, 4, 5, 6, 7], "open": "09:00", "close": "18:00", "always_open": true}'::jsonb;

-- Delivery (decision 10): the company's location and the per-kilometre rate. The location
-- and the rate are entered by an Admin; until then a delivery costs the car's delivery fee.
alter table program_settings
  add column company_latitude numeric(9, 6) check (company_latitude between -90 and 90),
  add column company_longitude numeric(9, 6) check (company_longitude between -180 and 180),
  add column delivery_per_km_cents integer not null default 0 check (delivery_per_km_cents >= 0),
  add column delivery_min_cents bigint check (delivery_min_cents >= 0),
  add column delivery_max_cents bigint check (delivery_max_cents >= 0),
  add column delivery_round_cents integer not null default 100 check (delivery_round_cents > 0);

-- The reply-time target, 2 hours: the due time of a new request's task (task_rules, opening
-- minutes, and the business is always open) and the staff alert for a waiting request
-- (notify_request_waiting_minutes, already 120).
update task_rules set due_kind = 'opening_minutes', due_amount = 120 where task_type = 'booking_request';

-- Decision 7: every car takes drivers 18 and up; the young driver fee has no maximum.
alter table vehicles alter column allows_18_to_20 set default true;
update vehicles set allows_18_to_20 = true where not allows_18_to_20;
update fee_defaults set cap_cents = null where fee_type_code in ('young_driver_18_20', 'young_driver_21_25', 'additional_driver');
-- Decision 8: additional driver, 25% of the car's daily rate per day, no maximum.
update fee_defaults set amount_cents = null, percent_bps = 2500 where fee_type_code = 'additional_driver';
-- both fees may be set per car (override) and per booking (booking fee term)
update fee_types set change_vehicle = true, change_booking = true
 where code in ('young_driver_18_20', 'young_driver_21_25', 'additional_driver', 'coverage_sold');
update fee_types set label = 'Coverage sold through CarmaCars' where code = 'coverage_sold';

-- A per-day fee whose term has a percentage and no amount is that percentage of the car's
-- daily rate (decision 8). The same rule serves every fee the pricer reads.
create or replace function app.fee_per_day(p_term jsonb, p_daily bigint)
returns bigint language sql immutable as $$
  select case when (p_term ->> 'amount_cents') is not null then (p_term ->> 'amount_cents')::bigint
              when (p_term ->> 'percent_bps') is not null then public.calc_bps(coalesce(p_daily, 0), (p_term ->> 'percent_bps')::integer) end
$$;

-- =====================================================================================
-- Classes (decision 4): an editable list, several per car
-- =====================================================================================
create table vehicle_classes (
  code        text primary key check (code ~ '^[a-z0-9_]+$'),
  label       text not null,
  sort_order  integer not null default 100,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
insert into vehicle_classes (code, label, sort_order) values
  ('economy', 'Economy', 10), ('standard', 'Standard', 20), ('premium', 'Premium', 30), ('luxury', 'Luxury', 40),
  ('suv', 'SUV', 50), ('convertible', 'Convertible', 60), ('coupe', 'Coupe', 70), ('sedan', 'Sedan', 80),
  ('van', 'Van', 90), ('pickup', 'Pickup', 100)
on conflict (code) do nothing;
-- the existing class values stay as classes
insert into vehicle_classes (code, label, sort_order)
select e.v, initcap(e.v), 200 from unnest(enum_range(null::vehicle_class)::text[]) e(v)
on conflict (code) do nothing;

create table vehicle_class_links (
  vehicle_id  uuid not null references vehicles(id) on delete cascade,
  class_code  text not null references vehicle_classes(code) on update cascade,
  source      text not null default 'staff' check (source in ('migrated', 'vehicle', 'staff', 'listing_draft')),
  added_by    uuid references users(id),
  created_at  timestamptz not null default now(),
  primary key (vehicle_id, class_code)
);
create index vehicle_class_links_class_idx on vehicle_class_links (class_code);
insert into vehicle_class_links (vehicle_id, class_code, source)
select v.id, v.class::text, 'migrated' from vehicles v where v.class is not null
on conflict do nothing;

-- vehicles.class stays as the car's pricing class (fee defaults and photo lists by class);
-- it is always one of the car's classes
create or replace function app.vehicle_class_link_main() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.class is not null then
    insert into vehicle_class_links (vehicle_id, class_code, source) values (new.id, new.class::text, 'vehicle')
    on conflict do nothing;
  end if;
  return null;
end $$;
create trigger vehicles_class_link after insert or update of class on vehicles
  for each row execute function app.vehicle_class_link_main();

create or replace function app.vehicle_class_list(p_vehicle uuid) returns text[]
language sql stable security definer set search_path = public, app as $$
  select coalesce(array_agg(l.class_code order by c.sort_order, c.code), '{}')
    from vehicle_class_links l join vehicle_classes c on c.code = l.class_code
   where l.vehicle_id = p_vehicle and c.is_active
$$;

-- true when the car belongs to any of the classes asked for
create or replace function app.vehicle_in_classes(p_vehicle uuid, p_classes text[]) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from vehicle_class_links l join vehicle_classes c on c.code = l.class_code
                  where l.vehicle_id = p_vehicle and c.is_active and l.class_code = any (p_classes))
$$;

create or replace function app.public_vehicle_classes() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('code', c.code, 'label', c.label) order by c.sort_order, c.code), '[]'::jsonb)
    from vehicle_classes c where c.is_active
$$;

-- Fleet or an Admin sets a car's classes (adds and removes). The pricing class stays.
create or replace function app.set_vehicle_classes(p_vehicle uuid, p_by uuid, p_classes text[])
returns text[] language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  v_bad text;
begin
  if not app.user_runs_fleet(p_by) then
    raise exception 'Fleet or an Admin sets a car''s classes' using errcode = '42501';
  end if;
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then raise exception 'Vehicle % not found', p_vehicle; end if;
  if coalesce(cardinality(p_classes), 0) = 0 then
    raise exception 'A car belongs to at least one class' using errcode = '22023';
  end if;
  select x into v_bad from unnest(p_classes) x where not exists (select 1 from vehicle_classes c where c.code = x and c.is_active) limit 1;
  if v_bad is not null then raise exception 'Unknown class %', v_bad using errcode = '22023'; end if;
  delete from vehicle_class_links where vehicle_id = p_vehicle and not (class_code = any (p_classes)) and class_code <> v.class::text;
  insert into vehicle_class_links (vehicle_id, class_code, source, added_by)
  select p_vehicle, x, 'staff', p_by from unnest(p_classes) x
  on conflict do nothing;
  return app.vehicle_class_list(p_vehicle);
end $$;

-- The listing pipeline's copy draft may propose classes; staff approve them.
alter table listing_drafts
  add column proposed_classes text[] not null default '{}',
  add column classes_decided_by uuid references users(id),
  add column classes_decided_at timestamptz,
  add column classes_approved text[];

create or replace function app.propose_listing_classes(p_draft uuid, p_classes text[])
returns text[] language plpgsql security definer set search_path = public, app as $$
declare
  v_kept text[];
begin
  -- only classes on the list are kept; the rest of the proposal is dropped
  select coalesce(array_agg(distinct lower(btrim(x))), '{}') into v_kept
    from unnest(coalesce(p_classes, '{}')) x where exists (select 1 from vehicle_classes c where c.code = lower(btrim(x)) and c.is_active);
  update listing_drafts set proposed_classes = v_kept where id = p_draft;
  if not found then raise exception 'Draft % not found', p_draft; end if;
  return v_kept;
end $$;

create or replace function app.review_listing_classes(p_draft uuid, p_by uuid, p_approve boolean, p_classes text[] default null)
returns text[] language plpgsql security definer set search_path = public, app as $$
declare
  d listing_drafts;
  v_take text[];
begin
  if not (app.user_runs_fleet(p_by) or app.user_va_has(p_by, 'cs')) then
    raise exception 'Fleet, customer service or an Admin reviews a listing' using errcode = '42501';
  end if;
  select * into d from listing_drafts where id = p_draft for update;
  if d.id is null then raise exception 'Draft % not found', p_draft; end if;
  v_take := case when p_approve then coalesce(p_classes, d.proposed_classes) else '{}' end;
  update listing_drafts set classes_decided_by = p_by, classes_decided_at = now(), classes_approved = v_take where id = p_draft;
  insert into vehicle_class_links (vehicle_id, class_code, source, added_by)
  select d.vehicle_id, x, 'listing_draft', p_by from unnest(v_take) x
   where exists (select 1 from vehicle_classes c where c.code = x and c.is_active)
  on conflict do nothing;
  return app.vehicle_class_list(d.vehicle_id);
end $$;

-- =====================================================================================
-- Deposits and kilometres (decisions 5 and 6): admin-editable choices, set per car
-- =====================================================================================
create table deposit_tiers (
  amount_cents bigint primary key check (amount_cents > 0),
  label        text not null,
  sort_order   integer not null default 100,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
insert into deposit_tiers (amount_cents, label, sort_order) values
  (50000, '$500', 10), (100000, '$1,000', 20), (250000, '$2,500', 30), (500000, '$5,000', 40);

create table km_allowance_choices (
  km_per_day  integer primary key check (km_per_day > 0),
  sort_order  integer not null default 100,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
insert into km_allowance_choices (km_per_day, sort_order) values (400, 10), (300, 20), (200, 30), (150, 40);

-- The choices staff pick from when setting a car's rate card. The Deposit, the daily
-- kilometre allowance and the overage rate are per car on its rate card (rate_cards); a
-- Deposit may also be any other amount.
create or replace function app.rate_card_choices() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'deposit_tiers', coalesce((select jsonb_agg(jsonb_build_object('amount_cents', t.amount_cents, 'label', t.label) order by t.sort_order, t.amount_cents)
                                 from deposit_tiers t where t.is_active), '[]'::jsonb),
    'deposit_any_amount', true,
    'km_allowances', coalesce((select jsonb_agg(k.km_per_day order by k.sort_order, k.km_per_day desc) from km_allowance_choices k where k.is_active), '[]'::jsonb))
$$;

-- An Admin sets a car's Deposit (a tier or any amount): the rate card in force is closed
-- and a copy opens with the new Deposit, as app.set_rate_card does for rates.
create or replace function app.set_vehicle_deposit(p_vehicle uuid, p_by uuid, p_amount_cents bigint, p_from timestamptz default now())
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  rc rate_cards;
  v_id uuid;
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin sets a car''s Deposit' using errcode = '42501'; end if;
  if p_amount_cents is null or p_amount_cents < 0 then raise exception 'The Deposit is 0 or more' using errcode = '22023'; end if;
  select * into rc from rate_cards r where r.vehicle_id = p_vehicle and r.effective_from <= p_from
     and (r.effective_to is null or r.effective_to > p_from) for update;
  if rc.id is null then raise exception 'This vehicle has no rates set' using errcode = '23514'; end if;
  if rc.effective_from = p_from then
    update rate_cards set deposit_cents = p_amount_cents, set_by = p_by where id = rc.id returning id into v_id;
    return v_id;
  end if;
  update rate_cards set effective_to = p_from where id = rc.id;
  insert into rate_cards (vehicle_id, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents,
      km_allowance_per_day, overage_cents_per_km, deposit_cents, delivery_fee_cents, pickup_fee_cents, effective_from, effective_to, set_by)
  values (rc.vehicle_id, rc.daily_rate_cents, rc.weekend_rate_cents, rc.weekly_rate_cents, rc.monthly_rate_cents,
      rc.km_allowance_per_day, rc.overage_cents_per_km, p_amount_cents, rc.delivery_fee_cents, rc.pickup_fee_cents, p_from, rc.effective_to, p_by)
  returning id into v_id;
  return v_id;
end $$;

-- =====================================================================================
-- Coverage sold through CarmaCars (decision 9)
-- =====================================================================================
-- Default prices by car or class and the renter's age band. Staff override the price on a
-- request or an offer with a booking fee term (app.set_booking_fee_term, 'coverage_sold').
-- The provider is never named here or anywhere.
create table coverage_prices (
  id             uuid primary key default gen_random_uuid(),
  vehicle_id     uuid references vehicles(id),
  class_code     text references vehicle_classes(code) on update cascade,
  age_band       text check (age_band in ('18_to_20', '21_to_25', '26_plus')),
  amount_cents   bigint not null check (amount_cents >= 0),
  per_day        boolean not null default true,
  effective_from date not null default current_date,
  effective_to   date,
  note           text,
  set_by         uuid references users(id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  check (vehicle_id is null or class_code is null),
  check (effective_to is null or effective_to > effective_from)
);
create index coverage_prices_lookup_idx on coverage_prices (vehicle_id, class_code, age_band);

-- The coverage price that applies: the term already on the booking when it has an amount
-- (null is returned and the caller keeps it), else the most specific default row: this car
-- and age band, this car, one of its classes and age band, one of its classes, every car and
-- age band, every car. Null when none applies: "priced in your offer".
create or replace function app.coverage_term(p_vehicle uuid, p_age_band text, p_on date, p_current jsonb default null)
returns jsonb language sql stable security definer set search_path = public, app as $$
  select case when (p_current ->> 'amount_cents') is not null or (p_current ->> 'percent_bps') is not null then null else (
    select jsonb_build_object('amount_cents', c.amount_cents, 'per_day', c.per_day, 'source', 'coverage_table',
                              'coverage_price_id', c.id)
      from coverage_prices c
     where c.effective_from <= p_on and (c.effective_to is null or c.effective_to > p_on)
       and (c.vehicle_id = p_vehicle or (c.vehicle_id is null and (c.class_code is null or app.vehicle_in_classes(p_vehicle, array[c.class_code]))))
       and (c.age_band is null or c.age_band = p_age_band)
     order by case when c.vehicle_id is not null then 0 when c.class_code is not null then 2 else 4 end
              + case when c.age_band is not null then 0 else 1 end, c.effective_from desc, c.amount_cents desc
     limit 1) end
$$;

-- The guard of 0012 lets only an Admin override a price on one booking. Decision 9 lets
-- customer service set the coverage price of a request too; every other charge stays an
-- Admin's. Created again with that one exception.
create or replace function app.guard_booking_override() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_code text := case when tg_table_name = 'booking_line_items' then (to_jsonb(new) ->> 'charge_type') else (to_jsonb(new) ->> 'fee_type_code') end;
  v_by uuid := (to_jsonb(new) ->> 'override_by')::uuid;
begin
  if v_by is not null and (tg_op = 'INSERT' or v_by is distinct from (to_jsonb(old) ->> 'override_by')::uuid) then
    if not exists (select 1 from user_roles where user_id = v_by and role = 'admin')
       and not (v_code = 'coverage_sold' and exists (
                  select 1 from staff_profiles sp join user_roles r on r.user_id = sp.user_id and r.role = 'va'
                   where sp.user_id = v_by and sp.va_function = 'cs')) then
      raise exception 'Only an Admin overrides a price on one booking' using errcode = '42501';
    end if;
    if not exists (select 1 from fee_types f where f.code = v_code and f.change_booking) then
      raise exception 'The charge "%" is fixed and cannot be overridden per booking', v_code using errcode = '23514';
    end if;
  end if;
  return new;
end $$;

-- Customer service (or an Admin) prices coverage for one request: the price for the whole
-- booking, kept as a per-booking fee term. On an offer, withdraw it first, price, send again.
create or replace function app.set_coverage_price(p_booking uuid, p_by uuid, p_amount_cents bigint, p_reason text default null)
returns bigint language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs')) then
    raise exception 'Customer service or an Admin prices coverage' using errcode = '42501';
  end if;
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if b.status <> 'requested' then
    raise exception 'Booking % is %: coverage is priced on a request (withdraw an offer first)', b.booking_number, b.status using errcode = '23514';
  end if;
  if p_amount_cents is null or p_amount_cents < 0 then raise exception 'The price is 0 or more' using errcode = '22023'; end if;
  insert into booking_fee_terms as t (booking_id, fee_type_code, amount_cents, cap_cents, percent_bps, source, override_by, override_reason)
  values (p_booking, 'coverage_sold', p_amount_cents, null, null, 'booking', p_by, coalesce(nullif(btrim(p_reason), ''), 'Coverage priced for this booking'))
  on conflict (booking_id, fee_type_code) do update
     set amount_cents = excluded.amount_cents, cap_cents = null, percent_bps = null, source = 'booking',
         override_by = excluded.override_by, override_reason = excluded.override_reason;
  perform app.reprice_booking(p_booking);
  return (select coalesce(sum(li.amount_cents), 0) from booking_line_items li
           where li.booking_id = p_booking and li.charge_type = 'coverage_sold' and li.voided_at is null);
end $$;

-- =====================================================================================
-- Delivery, airports and where the car is handed over (decision 10)
-- =====================================================================================
create table airports (
  id              uuid primary key default gen_random_uuid(),
  code            text not null unique check (code ~ '^[A-Z0-9]{3,4}$'),
  name            text not null,
  latitude        numeric(9, 6) not null check (latitude between -90 and 90),
  longitude       numeric(9, 6) not null check (longitude between -180 and 180),
  distance_km     numeric(7, 1) check (distance_km >= 0),
  surcharge_cents bigint not null default 0 check (surcharge_cents >= 0),
  is_active       boolean not null default true,
  sort_order      integer not null default 100,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
insert into airports (code, name, latitude, longitude, sort_order) values
  ('YYZ', 'Toronto Pearson International Airport', 43.677700, -79.624800, 10),
  ('YTZ', 'Billy Bishop Toronto City Airport', 43.627500, -79.396200, 20);

-- the Owner's pickup address, for Self-Managed and owner-located cars
alter table vehicles
  add column owner_pickup_address text,
  add column owner_pickup_latitude numeric(9, 6) check (owner_pickup_latitude between -90 and 90),
  add column owner_pickup_longitude numeric(9, 6) check (owner_pickup_longitude between -180 and 180);

alter table bookings
  add column pickup_location_kind text check (pickup_location_kind in ('our_location', 'owner_location', 'delivery', 'airport')),
  add column return_location_kind text check (return_location_kind in ('our_location', 'owner_location', 'delivery', 'airport')),
  add column pickup_distance_km numeric(7, 1) check (pickup_distance_km >= 0),
  add column return_distance_km numeric(7, 1) check (return_distance_km >= 0),
  add column pickup_airport_id uuid references airports(id),
  add column return_airport_id uuid references airports(id);

create or replace function app.distance_km(p_lat1 numeric, p_lon1 numeric, p_lat2 numeric, p_lon2 numeric)
returns numeric language sql immutable as $$
  select case when p_lat1 is null or p_lon1 is null or p_lat2 is null or p_lon2 is null then null else
    round((6371 * 2 * asin(sqrt(power(sin(radians(p_lat2 - p_lat1) / 2), 2)
          + cos(radians(p_lat1)) * cos(radians(p_lat2)) * power(sin(radians(p_lon2 - p_lon1) / 2), 2))))::numeric, 1) end
$$;

-- The delivery (or end-of-rental pickup) fee for one leg:
--   our location or the Owner's location: nothing;
--   the renter's address: the car's delivery fee (pickup fee for the return leg) plus the
--     per-kilometre rate times the distance from the company's location, held between the
--     optional minimum and maximum, rounded to the dollar. The distance comes from the server
--     (a maps service); a distance sent from a browser is not used. Without a distance the
--     fee is the car's fee alone and needs_distance says so;
--   an airport: the same, with the airport's driving distance (or the straight-line distance
--     from the company's location when none is entered), plus the airport's surcharge.
create or replace function app.delivery_fee(p_vehicle uuid, p_leg text, p_place jsonb)
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  rc rate_cards;
  a airports;
  v_kind text := coalesce(nullif(p_place ->> 'kind', ''), 'delivery');
  v_base bigint;
  v_km numeric;
  v_fee bigint;
  v_dist_part bigint := 0;
  v_surcharge bigint := 0;
  v_browser boolean := coalesce(pg_catalog.current_setting('role', true), '') in ('anon', 'authenticated');
begin
  if v_kind in ('our_location', 'owner_location') then
    return jsonb_build_object('kind', v_kind, 'fee_cents', 0);
  end if;
  if v_kind not in ('delivery', 'airport') then
    raise exception 'Unknown place kind %', v_kind using errcode = '22023';
  end if;
  select * into rc from rate_cards r
   where r.vehicle_id = p_vehicle and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now());
  v_base := coalesce(case when p_leg = 'return' then rc.pickup_fee_cents else rc.delivery_fee_cents end, 0);
  if v_kind = 'airport' then
    select * into a from airports x
     where x.is_active and (x.id = (p_place ->> 'airport_id')::uuid or x.code = upper(btrim(coalesce(p_place ->> 'airport_code', ''))));
    if a.id is null then raise exception 'Choose an airport from the list' using errcode = '22023'; end if;
    v_km := coalesce(a.distance_km, app.distance_km(s.company_latitude, s.company_longitude, a.latitude, a.longitude));
    v_surcharge := a.surcharge_cents;
  elsif not v_browser then
    v_km := (p_place ->> 'distance_km')::numeric;
  end if;
  v_fee := v_base;
  if v_km is not null and s.delivery_per_km_cents > 0 then
    v_dist_part := round(s.delivery_per_km_cents * v_km)::bigint;
    v_fee := v_base + v_dist_part;
    if s.delivery_min_cents is not null then v_fee := greatest(v_fee, s.delivery_min_cents); end if;
    if s.delivery_max_cents is not null then v_fee := least(v_fee, s.delivery_max_cents); end if;
    v_fee := (round(v_fee::numeric / s.delivery_round_cents) * s.delivery_round_cents)::bigint;
  end if;
  v_fee := v_fee + v_surcharge;
  return jsonb_build_object('kind', v_kind, 'fee_cents', v_fee, 'base_cents', v_base, 'distance_km', v_km,
                            'per_km_cents', s.delivery_per_km_cents, 'distance_cents', v_dist_part,
                            'airport_code', a.code, 'airport_name', a.name, 'airport_surcharge_cents', v_surcharge,
                            'needs_distance', v_kind = 'delivery' and v_km is null);
end $$;

-- Where a request is handed over and returned: our location, the Owner's location
-- (Self-Managed cars and cars with an Owner pickup address), the renter's address (with the
-- distance the server measured) or an airport. Stores the kind, address, distance and
-- airport on the booking. p: {pickup_location: {kind, address, distance_km, airport_code},
-- return_location: {...}}; without them the booking's pickup and return methods decide.
create or replace function app.apply_booking_places(p_booking uuid, p jsonb)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v vehicles;
  leg text;
  pl jsonb;
  v_kind text;
  v_method text;
  v_place text;
  v_air airports;
  v_km numeric;
begin
  select * into b from bookings where id = p_booking for update;
  select * into v from vehicles where id = b.vehicle_id;
  foreach leg in array array['pickup', 'return'] loop
    pl := coalesce(p -> (leg || '_location'), '{}'::jsonb);
    v_method := case leg when 'pickup' then b.pickup_method else b.return_method end;
    v_kind := coalesce(nullif(pl ->> 'kind', ''),
                       case when v_method in ('delivered', 'picked_up') then 'delivery' else 'our_location' end);
    v_place := coalesce(nullif(btrim(coalesce(pl ->> 'address', '')), ''), case leg when 'pickup' then b.pickup_place else b.return_place end);
    v_air := null; v_km := null;
    if v_kind = 'owner_location' then
      if v.management_mode <> 'self_managed' and v.owner_pickup_address is null then
        raise exception 'This car is not handed over at its Owner''s location' using errcode = '23514';
      end if;
      v_place := coalesce(v.owner_pickup_address, v_place);
      v_method := case leg when 'pickup' then 'collected' else 'returned' end;
    elsif v_kind = 'our_location' then
      v_method := case leg when 'pickup' then 'collected' else 'returned' end;
    elsif v_kind = 'airport' then
      select * into v_air from airports x
       where x.is_active and (x.id = (pl ->> 'airport_id')::uuid or x.code = upper(btrim(coalesce(pl ->> 'airport_code', ''))));
      if v_air.id is null then raise exception 'Choose an airport from the list' using errcode = '22023'; end if;
      v_place := v_air.name;
      v_method := case leg when 'pickup' then 'delivered' else 'picked_up' end;
    elsif v_kind = 'delivery' then
      if v_place is null then raise exception 'A delivery needs its address' using errcode = '22023'; end if;
      v_km := (pl ->> 'distance_km')::numeric;
      v_method := case leg when 'pickup' then 'delivered' else 'picked_up' end;
    else
      raise exception 'Unknown place kind %', v_kind using errcode = '22023';
    end if;
    if leg = 'pickup' then
      update bookings set pickup_location_kind = v_kind, pickup_method = v_method, pickup_place = v_place,
                          pickup_distance_km = v_km, pickup_airport_id = v_air.id where id = p_booking;
    else
      update bookings set return_location_kind = v_kind, return_method = v_method, return_place = v_place,
                          return_distance_km = v_km, return_airport_id = v_air.id where id = p_booking;
    end if;
  end loop;
end $$;

-- Staff set or correct the places of a request (the server passes the measured distance).
create or replace function app.set_booking_places(p_booking uuid, p_by uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
begin
  if not app.user_is_staff(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if b.status <> 'requested' then
    raise exception 'Booking % is %: places change on a request (withdraw an offer first)', b.booking_number, b.status using errcode = '23514';
  end if;
  perform app.apply_booking_places(p_booking, p);
  perform app.reprice_booking(p_booking);
  perform app.log_booking_event(p_booking, 'adjusted', 'requested', 'requested', b.current_offer_version, 'Places of handover and return set', p_by);
  return (select jsonb_build_object('pickup_location_kind', x.pickup_location_kind, 'pickup_distance_km', x.pickup_distance_km,
                                    'return_location_kind', x.return_location_kind, 'return_distance_km', x.return_distance_km,
                                    'total_due_at_booking_cents', x.total_due_at_booking_cents)
            from bookings x where x.id = p_booking);
end $$;

-- =====================================================================================
-- Site settings (decision 12), reply-to aliases, Google reviews (decision 11)
-- =====================================================================================
alter table site_settings
  add column phone_display text,
  add column whatsapp_display text,
  add column roadside_phone_display text,
  add column handover_any_time boolean not null default true,
  add column google_place_id text,
  add column listing_time_promise text,
  add column featured_mode text not null default 'random' check (featured_mode in ('random', 'manual')),
  add column mailing_address_required boolean not null default true;

update site_settings
   set public_email = 'contact@carmacars.ca',
       owners_email = 'owners@carmacars.ca',
       phone = '+16475753377', phone_display = '647-575-3377',
       whatsapp = '+16475753377', whatsapp_display = '647-575-3377',
       roadside_phone = '+16475753377', roadside_phone_display = '647-575-3377',
       opening_hours_text = 'Open 24 hours',
       reply_wording = 'within 2 hours',
       social_links = coalesce(social_links, '{}'::jsonb)
                      || '{"instagram": "https://instagram.com/carmacars.ca", "tiktok": "https://tiktok.com/@carmacars.ca",
                           "instagram_handle": "carmacars.ca", "tiktok_handle": "carmacars.ca"}'::jsonb,
       show_street_address = true,
       handover_slots = '{}', handover_any_time = true,
       listing_time_promise = '1 business day',
       featured_mode = 'random',
       airport_delivery = true;

-- What still has to be entered before marketing emails may go out (a street address is
-- shown once entered; the mailing address is required in every marketing email).
create or replace function app.site_setup_problems() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(x), '[]'::jsonb) from (
    select jsonb_build_object('field', 'mailing_address', 'blocks', 'marketing_emails',
                              'message', 'Enter the mailing address before marketing emails go out') as x
      from site_settings s where s.singleton and s.mailing_address_required and nullif(btrim(coalesce(s.mailing_address, '')), '') is null
    union all
    select jsonb_build_object('field', 'street_address', 'blocks', null,
                              'message', 'Enter the street address; it is shown on the website once entered')
      from site_settings s where s.singleton and nullif(btrim(coalesce(s.street_address, '')), '') is null) q
$$;

-- Featured cars: a random choice of the published cars on each visit, or the cars staff mark.
create or replace function app.public_featured_cars(p_limit integer default 6) returns setof jsonb
language sql volatile security definer set search_path = public, app as $$
  select r from (
    select app.public_listing_row(l.vehicle_id) as r, l.is_featured
      from vehicle_listings l join vehicles v on v.id = l.vehicle_id
     where l.status = 'published' and v.management_mode <> 'turo_only'
       and ((select s.featured_mode from site_settings s where s.singleton) = 'random' or l.is_featured)) q
   where r is not null
   order by case when (select s.featured_mode from site_settings s where s.singleton) = 'random' then random() else 0 end,
            (r ->> 'daily_rate_cents')::bigint nulls last
   limit greatest(least(coalesce(p_limit, 6), 24), 1)
$$;

-- Staff mailboxes that replies go to, and which one each email audience replies to.
create table email_aliases (
  address     text primary key check (address ~ '^[a-z0-9._-]+@[a-z0-9.-]+$'),
  purpose     text not null,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
insert into email_aliases (address, purpose) values
  ('contact@carmacars.ca', 'General enquiries'),
  ('bookings@carmacars.ca', 'Bookings and renters'),
  ('owners@carmacars.ca', 'Owners and the owner program'),
  ('billing@carmacars.ca', 'Invoices, statements, payments and payouts'),
  ('privacy@carmacars.ca', 'Privacy and personal information'),
  ('investors@carmacars.ca', 'Investors');

create table email_reply_to (
  id          uuid primary key default gen_random_uuid(),
  audience    text,
  code        text,
  reply_to    text not null references email_aliases(address) on update cascade,
  note        text,
  updated_by  uuid references users(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (audience is not null or code is not null)
);
create unique index email_reply_to_key on email_reply_to (coalesce(audience, ''), coalesce(code, ''));
insert into email_reply_to (audience, reply_to) values
  ('renter', 'bookings@carmacars.ca'), ('owner', 'owners@carmacars.ca'), ('investor', 'investors@carmacars.ca'),
  ('staff_admin', 'contact@carmacars.ca'), ('staff_va_cs', 'contact@carmacars.ca'), ('staff_va_sales', 'contact@carmacars.ca'),
  ('staff_va_finance', 'billing@carmacars.ca'), ('staff_va_fleet', 'contact@carmacars.ca'), ('staff_field', 'contact@carmacars.ca'),
  ('lead', 'contact@carmacars.ca');
-- money emails reply to billing
insert into email_reply_to (code, reply_to, note)
select c.code, 'billing@carmacars.ca', 'money email'
  from notification_catalogue c
 where c.audience in ('renter', 'owner') and c.code ~ '(invoice|statement|receipt|payout|payment|refund|charge|balance)'
on conflict do nothing;

create or replace function app.email_reply_to_for(p_code text, p_audience text) returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce(
    (select r.reply_to from email_reply_to r join email_aliases a on a.address = r.reply_to and a.is_active where r.code = p_code limit 1),
    (select r.reply_to from email_reply_to r join email_aliases a on a.address = r.reply_to and a.is_active
      where r.code is null and r.audience = p_audience limit 1),
    'contact@carmacars.ca')
$$;

alter table notification_outbox add column reply_to text;
create or replace function app.outbox_reply_to() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  new.reply_to := coalesce(new.reply_to, app.email_reply_to_for(new.code, new.audience));
  return new;
end $$;
create trigger notification_outbox_reply_to before insert on notification_outbox
  for each row execute function app.outbox_reply_to();
-- =====================================================================================
-- 1. Vehicle swap: revenue follows the car (segments of a booking)
-- =====================================================================================

-- The split terms a car carries for a booking made on a given day: its Owner, management
-- mode, Revenue Share (the company's share) and the shareholder flag. The same rule as the
-- booking snapshot of 0011 and 0016.
create or replace function app.vehicle_split_terms(p_vehicle uuid, p_on date, p_booking_type text default 'standard')
returns table (owner_id uuid, management_mode management_mode, company_share_bps integer, is_shareholder boolean)
language sql stable security definer set search_path = public, app as $$
  select v.owner_id,
         v.management_mode,
         case when p_booking_type = 'owner' then 0
              when v.is_shareholder_owned then (app.settings(p_on)).shareholder_company_share_bps
              when v.management_mode = 'self_managed' then 0
              else coalesce((app.vehicle_terms(v.id, p_on)).revenue_share_bps,
                            (select s.revenue_share_bps from vehicle_schedules s where s.vehicle_id = v.id and s.superseded_by is null)) end,
         v.is_shareholder_owned
    from vehicles v where v.id = p_vehicle
$$;

-- Availability with the vehicle row locked first, so two writers that both want the car
-- (or the turnaround buffer around it) are served one after the other.
create or replace function app.vehicle_free_locked(p_vehicle uuid, p_from timestamptz, p_to timestamptz, p_ignore uuid default null)
returns boolean language plpgsql security definer set search_path = public, app as $$
begin
  perform 1 from vehicles where id = p_vehicle for no key update;
  return app.vehicle_is_available(p_vehicle, p_from, p_to, p_ignore);
end $$;

-- Each swap keeps the replacement car's split terms as they stood at the swap.
alter table booking_vehicle_swaps
  add column to_owner_id uuid references owners(id),
  add column to_management_mode management_mode,
  add column to_company_share_bps integer check (to_company_share_bps between 0 and 10000),
  add column to_is_shareholder boolean;

create or replace function app.booking_vehicle_swap_terms() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  t record;
begin
  select * into t from app.vehicle_split_terms(new.to_vehicle_id, app.local_date(new.swapped_at),
                                               (select b.booking_type::text from bookings b where b.id = new.booking_id));
  new.to_owner_id := coalesce(new.to_owner_id, t.owner_id);
  new.to_management_mode := coalesce(new.to_management_mode, t.management_mode);
  new.to_company_share_bps := coalesce(new.to_company_share_bps, t.company_share_bps);
  new.to_is_shareholder := coalesce(new.to_is_shareholder, t.is_shareholder);
  return new;
end $$;
create trigger booking_vehicle_swaps_terms before insert on booking_vehicle_swaps
  for each row execute function app.booking_vehicle_swap_terms();
update booking_vehicle_swaps w
   set (to_owner_id, to_management_mode, to_company_share_bps, to_is_shareholder) =
       (select t.owner_id, t.management_mode, t.company_share_bps, t.is_shareholder
          from bookings b, app.vehicle_split_terms(w.to_vehicle_id, app.local_date(w.swapped_at), b.booking_type::text) t
         where b.id = w.booking_id)
 where w.to_owner_id is null;

-- A charge line may be pinned to the car on which it arose (staff, or the Check-in assessment).
alter table booking_line_items add column arose_vehicle_id uuid references vehicles(id);

-- Whole Toronto-clock days from one instant to another (never negative).
create or replace function app.whole_days_between(p_from timestamptz, p_to timestamptz)
returns integer language sql stable as $$
  select greatest(floor(extract(epoch from ((p_to at time zone 'America/Toronto') - (p_from at time zone 'America/Toronto'))) / 86400), 0)::integer
$$;

-- The segments of a booking, in order: one per car the renter actually had. A swap counts
-- as a segment boundary only when it happened after the pickup time (a change of car before
-- pickup moves the whole booking: 0019's change flow and 0020's calendar). The first segment
-- carries the booking's own snapshot; each later one the replacement car's terms at the swap.
--
-- Billable days of each segment: the whole days completed before a swap belong to the car
-- that was swapped out; the day in which the swap happens, and every day after it, belong to
-- the replacement car ("the day of the swap counts for the new car"). The segments' days
-- always add up to the booking's billable days.
create or replace function app.booking_segments(p_booking uuid)
returns table (seq integer, vehicle_id uuid, owner_id uuid, management_mode management_mode, company_share_bps integer,
               is_shareholder boolean, starts_at timestamptz, ends_at timestamptz, days integer, is_last boolean)
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  w record;
  v_seq integer := 1;
  v_vehicle uuid; v_owner uuid; v_mode management_mode; v_share integer; v_sh boolean;
  v_start timestamptz;
  v_cum integer := 0;
  v_at integer;
  v_end timestamptz;
begin
  select * into b from bookings x where x.id = p_booking;
  if b.id is null then return; end if;
  v_end := coalesce(b.checked_in_at, b.return_at);
  v_start := b.pickup_at;
  v_owner := b.owner_id; v_mode := b.management_mode; v_share := b.company_share_bps; v_sh := b.is_shareholder_vehicle;
  v_vehicle := coalesce((select s.from_vehicle_id from booking_vehicle_swaps s
                          where s.booking_id = p_booking and s.swapped_at > b.pickup_at order by s.swapped_at, s.id limit 1), b.vehicle_id);
  for w in select s.* from booking_vehicle_swaps s
            where s.booking_id = p_booking and s.swapped_at > b.pickup_at order by s.swapped_at, s.id
  loop
    v_at := least(app.whole_days_between(b.pickup_at, w.swapped_at), b.billable_days);
    seq := v_seq; vehicle_id := v_vehicle; owner_id := v_owner; management_mode := v_mode; company_share_bps := v_share;
    is_shareholder := v_sh; starts_at := v_start; ends_at := w.swapped_at; days := greatest(v_at - v_cum, 0); is_last := false;
    return next;
    v_cum := greatest(v_at, v_cum);
    v_seq := v_seq + 1;
    v_vehicle := w.to_vehicle_id;
    v_owner := coalesce(w.to_owner_id, b.owner_id);
    v_mode := coalesce(w.to_management_mode, b.management_mode);
    v_share := coalesce(w.to_company_share_bps, b.company_share_bps);
    v_sh := coalesce(w.to_is_shareholder, b.is_shareholder_vehicle);
    v_start := w.swapped_at;
  end loop;
  seq := v_seq; vehicle_id := v_vehicle; owner_id := v_owner; management_mode := v_mode; company_share_bps := v_share;
  is_shareholder := v_sh; starts_at := v_start; ends_at := greatest(v_end, v_start); days := greatest(b.billable_days - v_cum, 0); is_last := true;
  return next;
end $$;

-- Kilometres over the allowance on each segment. The allowance is used up in the order the
-- cars were driven, so the overage arises on the car that was being driven once it ran out.
-- Odometers: pickup reading, then each completed swap-out (old car) and swap-in (new car)
-- report, then the return reading. Null when a reading is missing.
create or replace function app.segment_overage_km(p_booking uuid)
returns table (seq integer, km integer, overage_km integer)
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  s record;
  v_outs integer[];
  v_ins integer[];
  v_n integer;
  v_from integer;
  v_to integer;
  v_used integer := 0;
  v_allow integer;
  v_km integer;
begin
  select * into b from bookings x where x.id = p_booking;
  select count(*) into v_n from app.booking_segments(p_booking);
  select array_agg(c.odometer_km order by c.completed_at, c.id) into v_outs
    from condition_reports c where c.booking_id = p_booking and c.kind = 'swap_out' and c.completed_at is not null;
  select array_agg(c.odometer_km order by c.completed_at, c.id) into v_ins
    from condition_reports c where c.booking_id = p_booking and c.kind = 'swap_in' and c.completed_at is not null;
  if b.odometer_out_km is null or b.odometer_in_km is null
     or coalesce(cardinality(v_outs), 0) < v_n - 1 or coalesce(cardinality(v_ins), 0) < v_n - 1 then
    return;
  end if;
  v_allow := coalesce(b.km_allowance_total, 0);
  for s in select * from app.booking_segments(p_booking) order by 1 loop
    v_from := case when s.seq = 1 then b.odometer_out_km else v_ins[s.seq - 1] end;
    v_to := case when s.is_last then b.odometer_in_km else v_outs[s.seq] end;
    v_km := greatest(coalesce(v_to - v_from, 0), 0);
    seq := s.seq; km := v_km;
    overage_km := greatest(v_used + v_km - greatest(v_allow, v_used), 0);
    v_used := v_used + v_km;
    return next;
  end loop;
end $$;

-- An amount cut in proportion: the part of p_amount between cumulative weights p_lo and p_hi
-- out of p_sum. The parts of one amount always add up to it exactly.
create or replace function app.cut(p_amount bigint, p_lo bigint, p_hi bigint, p_sum bigint)
returns bigint language sql immutable as $$
  select case when coalesce(p_sum, 0) <= 0 then 0
              else (div(p_amount::numeric * p_hi, p_sum) - div(p_amount::numeric * p_lo, p_sum))::bigint end
$$;

-- How each charge line of a booking is shared between the cars of its segments
-- (one row per line and car, cumulative weights for app.cut):
--   rental charge and its discounts: by billable days of each car;
--   extra days after a late return: the car on which the rental ended;
--   mileage overage: the car on which the kilometres over the allowance were driven
--     (app.segment_overage_km), or the last car when a reading is missing;
--   any other line: the car it is pinned to (arose_vehicle_id), else the last car.
-- A line pinned to a car of the booking always goes to that car.
create or replace function app.booking_line_allocation(p_booking uuid)
returns table (line_id uuid, vehicle_id uuid, owner_id uuid, company_share_bps integer, management_mode management_mode,
               w_lo bigint, w_hi bigint, w_sum bigint)
language sql stable security definer set search_path = public, app as $$
  with seg as (
    select s.vehicle_id, min(s.seq) as ord, max(s.seq) as last_seq, sum(s.days) as days,
           (array_agg(s.owner_id order by s.seq))[1] as owner_id,
           (array_agg(s.company_share_bps order by s.seq))[1] as company_share_bps,
           (array_agg(s.management_mode order by s.seq))[1] as management_mode,
           bool_or(s.is_last) as is_last,
           coalesce(sum(o.overage_km), 0) as over_km
      from app.booking_segments(p_booking) s
      left join app.segment_overage_km(p_booking) o on o.seq = s.seq
     group by s.vehicle_id
  ),
  raw as (
    select li.id as line_id, seg.vehicle_id, seg.owner_id, seg.company_share_bps, seg.management_mode, seg.ord,
           case
             when li.arose_vehicle_id is not null and exists (select 1 from seg s2 where s2.vehicle_id = li.arose_vehicle_id)
               then case when seg.vehicle_id = li.arose_vehicle_id then 1 else 0 end
             when li.charge_type in ('rental_charge', 'non_refundable_discount', 'staff_discount', 'promo_discount') then seg.days
             when li.charge_type = 'mileage_overage' and (select sum(s3.over_km) from seg s3) > 0 then seg.over_km
             else case when seg.is_last then 1 else 0 end
           end::bigint as w
      from booking_line_items li cross join seg
     where li.booking_id = p_booking
  ),
  fixed as (
    -- nothing to weigh (a rental of no days on a car, no overage readings): the last car
    select r.line_id, r.vehicle_id, r.owner_id, r.company_share_bps, r.management_mode, r.ord,
           case when sum(r.w) over (partition by r.line_id) > 0 then r.w
                else case when r.vehicle_id = (select s4.vehicle_id from seg s4 where s4.is_last) then 1 else 0 end end as w
      from raw r
  )
  select f.line_id, f.vehicle_id, f.owner_id, f.company_share_bps, f.management_mode,
         coalesce(sum(f.w) over (partition by f.line_id order by f.ord rows between unbounded preceding and 1 preceding), 0)::bigint,
         (sum(f.w) over (partition by f.line_id order by f.ord rows between unbounded preceding and current row))::bigint,
         (sum(f.w) over (partition by f.line_id))::bigint
    from fixed f
$$;

-- The split of a booking, per car. For a booking that stayed on one car this is exactly the
-- split of 0016 and 0021. Amounts that belong to the booking as a whole (money collected,
-- refunded, charged back or withheld in a dispute) are shared in proportion to each car's
-- Owner Revenue before refunds, so every column still adds up to the booking.
create or replace function app.booking_split_parts(p_booking uuid)
returns table (vehicle_id uuid, owner_id uuid, company_share_bps integer, management_mode management_mode, ord integer,
               segment_days integer, segment_starts_at timestamptz, segment_ends_at timestamptz,
               rental_cents bigint, mileage_cents bigint, gross_cents bigint, company_only_cents bigint, pass_through_cents bigint,
               hst_cents bigint, uncollected_cents bigint, collected_cents bigint, refunded_cents bigint, chargeback_cents bigint,
               withheld_cents bigint)
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_collected bigint; v_refunded bigint; v_chargeback bigint; v_withheld bigint;
begin
  select coalesce(sum(p.amount_cents) filter (where p.kind in ('charge', 'capture') and p.purpose <> 'deposit'), 0)
    into v_collected from payments p where p.booking_id = p_booking and p.status = 'succeeded';
  select coalesce(sum(r.amount_cents), 0) into v_refunded
    from refunds r where r.booking_id = p_booking and r.status in ('approved', 'processing', 'paid');
  select coalesce(sum(d.owner_revenue_reversed_cents) filter (where d.status = 'lost'), 0),
         coalesce(sum(d.owner_revenue_withheld_cents) filter (where d.status in ('open', 'evidence_submitted')), 0)
    into v_chargeback, v_withheld from disputes d where d.booking_id = p_booking;

  return query
  with seg as (
    select s.vehicle_id, min(s.seq)::integer as ord, sum(s.days)::integer as days, min(s.starts_at) as starts_at, max(s.ends_at) as ends_at
      from app.booking_segments(p_booking) s group by s.vehicle_id
  ),
  alloc as (select * from app.booking_line_allocation(p_booking)),
  lines as (
    select a.vehicle_id, li.charge_type, li.revenue_class, li.charged_to_renter, li.id, li.payment_id,
           app.cut(li.amount_cents, a.w_lo, a.w_hi, a.w_sum) as amt,
           app.cut(li.hst_cents, a.w_lo, a.w_hi, a.w_sum) as hst,
           (select coalesce(sum(app.cut(ra.amount_cents, a.w_lo, a.w_hi, a.w_sum)), 0)
              from refund_allocations ra join refunds r on r.id = ra.refund_id and r.status in ('approved', 'processing', 'paid')
             where ra.line_item_id = li.id) as refunded
      from booking_line_items li join alloc a on a.line_id = li.id
     where li.booking_id = p_booking and li.voided_at is null
  ),
  per as (
    select seg.vehicle_id, seg.ord, seg.days, seg.starts_at, seg.ends_at,
           coalesce(sum(l.amt) filter (where l.charged_to_renter and l.charge_type in ('rental_charge', 'non_refundable_discount', 'staff_discount', 'promo_discount', 'late_return_extra_days')), 0)::bigint as rental,
           coalesce(sum(l.amt) filter (where l.charged_to_renter and l.charge_type = 'mileage_overage'), 0)::bigint as mileage,
           coalesce(sum(l.refunded) filter (where l.charge_type in ('rental_charge', 'non_refundable_discount', 'staff_discount', 'promo_discount', 'late_return_extra_days')), 0)::bigint as ref_rental,
           coalesce(sum(l.refunded) filter (where l.charge_type = 'mileage_overage'), 0)::bigint as ref_mileage,
           coalesce(sum(l.amt) filter (where l.charged_to_renter and l.revenue_class = 'company_only'), 0)::bigint as company,
           coalesce(sum(l.amt) filter (where l.charged_to_renter and l.revenue_class = 'pass_through'), 0)::bigint as pass,
           coalesce(sum(l.hst) filter (where l.charged_to_renter), 0)::bigint as hst,
           coalesce(sum(l.amt) filter (where l.charged_to_renter and l.revenue_class = 'owner_revenue' and not exists (
               select 1 from payments p where p.id = l.payment_id and p.status = 'succeeded')), 0)::bigint as uncollected
      from seg left join lines l on l.vehicle_id = seg.vehicle_id
     group by seg.vehicle_id, seg.ord, seg.days, seg.starts_at, seg.ends_at
  ),
  w as (
    select per.*, greatest(per.rental + per.mileage, 0) as wt,
           coalesce(sum(greatest(per.rental + per.mileage, 0)) over (order by per.ord rows between unbounded preceding and 1 preceding), 0)::bigint as lo,
           (sum(greatest(per.rental + per.mileage, 0)) over (order by per.ord rows between unbounded preceding and current row))::bigint as hi,
           (sum(greatest(per.rental + per.mileage, 0)) over ())::bigint as tot,
           count(*) over () as n, row_number() over (order by per.ord desc) as from_last
      from per
  ),
  w2 as (
    -- no Owner Revenue anywhere: the booking-wide amounts sit on the last car
    select w.*, case when w.tot > 0 then w.lo else 0 end as lo2,
           case when w.tot > 0 then w.hi when w.from_last = 1 then 1 else 0 end as hi2,
           case when w.tot > 0 then w.tot else 1 end as tot2
      from w
  )
  select w2.vehicle_id, a1.owner_id, a1.company_share_bps, a1.management_mode, w2.ord, w2.days, w2.starts_at, w2.ends_at,
         w2.rental - w2.ref_rental, w2.mileage - w2.ref_mileage, w2.rental + w2.mileage, w2.company, w2.pass, w2.hst, w2.uncollected,
         app.cut(v_collected, w2.lo2, w2.hi2, w2.tot2), app.cut(v_refunded, w2.lo2, w2.hi2, w2.tot2),
         app.cut(v_chargeback, w2.lo2, w2.hi2, w2.tot2), app.cut(v_withheld, w2.lo2, w2.hi2, w2.tot2)
    from w2
    cross join lateral (select s.owner_id, s.company_share_bps, s.management_mode from app.booking_segments(p_booking) s
                         where s.vehicle_id = w2.vehicle_id order by s.seq limit 1) a1
   order by w2.ord;
end $$;

-- booking_splits: one row per booking and car (a booking that stayed on one car keeps one row)
alter table booking_splits
  add column segment_days integer,
  add column segment_starts_at timestamptz,
  add column segment_ends_at timestamptz;
alter table booking_splits drop constraint booking_splits_pkey;
alter table booking_splits add constraint booking_splits_pkey primary key (booking_id, vehicle_id);
create index booking_splits_booking_idx on booking_splits (booking_id);
create index booking_splits_owner_statement_idx on booking_splits (owner_id, owner_statement_id);

-- The split, per segment. Same rules as 0007, 0016 and 0021 (kickback on the whole rental
-- charge, then Owner Revenue, Revenue Share and the Owner's payout), applied to each car's
-- part with that car's Owner and Revenue Share. A part already paid out is not rewritten:
-- the Owner's share of a later refund or chargeback goes on their next statement, as before.
create or replace function app.compute_booking_split(p_booking uuid)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  s booking_splits;
  p record;
  v_set program_settings;
  v_reason text;
  v_rental_total bigint := 0;
  v_kick_total bigint;
  v_kick bigint; v_rev bigint; v_share bigint; v_pay bigint;
  v_counts date; v_done boolean; v_cancelled boolean;
  v_prior bigint; v_delta bigint;
  v_lo bigint := 0;
  v_rental bigint;
  v_vehicles uuid[] := '{}';
begin
  select * into b from bookings where id = p_booking;
  if not found then raise exception 'Booking % not found', p_booking; end if;
  -- an Owner Booking has no Owner Revenue, kickback or payout
  if b.booking_type = 'owner' then
    delete from booking_splits where booking_id = p_booking and owner_statement_id is null;
    return;
  end if;
  v_set := app.settings(app.local_date(b.booked_at));
  v_cancelled := b.status in ('cancelled', 'no_show');
  v_done := b.status in ('returned', 'closed');

  -- the kickback is worked out on the whole rental charge, after refunds and chargebacks
  for p in select * from app.booking_split_parts(p_booking) loop
    v_rental_total := v_rental_total + greatest(p.rental_cents - p.chargeback_cents, 0);
  end loop;
  v_reason := app.kickback_ineligible_reason(p_booking);
  v_kick_total := public.calc_kickback(v_rental_total, v_reason is null, v_set.kickback_bps);

  -- a rental counts in the month it ends; rental charge kept on a cancellation, in the month of cancellation
  if v_cancelled then
    select app.local_date(received_at) into v_counts from booking_cancellations where booking_id = p_booking;
    v_counts := coalesce(v_counts, app.local_date(b.updated_at));
  else
    v_counts := app.local_date(coalesce(b.checked_in_at, b.return_at));
  end if;

  for p in select * from app.booking_split_parts(p_booking) order by ord loop
    -- Owner Revenue lost to a chargeback comes off the rental charge
    v_rental := greatest(p.rental_cents - p.chargeback_cents, 0);
    v_kick := app.cut(v_kick_total, v_lo, v_lo + v_rental, v_rental_total);
    if v_rental_total = 0 then v_kick := 0; end if;
    v_lo := v_lo + v_rental;
    select x.owner_revenue_cents, x.company_share_cents, x.owner_payout_cents into v_rev, v_share, v_pay
      from public.calc_split(v_rental, p.mileage_cents, v_kick, p.company_share_bps) x;
    v_vehicles := v_vehicles || p.vehicle_id;

    select * into s from booking_splits where booking_id = p_booking and vehicle_id = p.vehicle_id;
    if s.booking_id is not null and s.owner_statement_id is not null then
      -- already paid out: the Owner's share of the change goes on the next statement
      select coalesce(sum(amount_cents), 0) into v_prior from owner_deductions
       where booking_id = p_booking and vehicle_id = p.vehicle_id and kind in ('refund_share', 'chargeback_share') and status <> 'waived';
      v_delta := s.owner_payout_cents - v_pay - v_prior;
      if v_delta > 0 then
        insert into owner_deductions (owner_id, vehicle_id, kind, description, amount_cents, incurred_on, booking_id)
        values (s.owner_id, s.vehicle_id, case when p.chargeback_cents > 0 then 'chargeback_share' else 'refund_share' end,
                format('Booking %s: Owner''s share of a later %s', b.booking_number,
                       case when p.chargeback_cents > 0 then 'chargeback' else 'refund' end),
                v_delta, app.today(), p_booking);
      end if;
      update booking_splits set refunded_cents = p.refunded_cents, chargeback_cents = p.chargeback_cents, withheld_cents = p.withheld_cents
       where booking_id = p_booking and vehicle_id = p.vehicle_id;
    else
      insert into booking_splits as bs (booking_id, vehicle_id, owner_id, referrer_type, referrer_owner_id, referrer_staff_id,
          is_first_rental, kickback_base_cents, kickback_cents, rental_charge_cents, mileage_overage_cents,
          owner_revenue_cents, company_share_bps, company_share_cents, owner_payout_cents, company_only_cents,
          pass_through_cents, hst_cents, collected_cents, refunded_cents, chargeback_cents, withheld_cents,
          uncollected_cents, kickback_ineligible_reason, counts_on, payout_month, status, computed_at,
          segment_days, segment_starts_at, segment_ends_at)
      values (p_booking, p.vehicle_id, p.owner_id, b.referrer_type, b.referrer_owner_id, b.referrer_staff_id,
          v_reason is null, case when v_reason is null then v_rental else 0 end, v_kick, v_rental, p.mileage_cents,
          v_rev, p.company_share_bps, v_share, v_pay, p.company_only_cents,
          p.pass_through_cents, p.hst_cents, p.collected_cents, p.refunded_cents, p.chargeback_cents, p.withheld_cents,
          p.uncollected_cents, v_reason, v_counts, app.month_start(v_counts),
          case when b.status in ('closed', 'cancelled', 'no_show') then 'final' else 'provisional' end, now(),
          p.segment_days, p.segment_starts_at, p.segment_ends_at)
      on conflict (booking_id, vehicle_id) do update set
          owner_id = excluded.owner_id, referrer_type = excluded.referrer_type,
          referrer_owner_id = excluded.referrer_owner_id, referrer_staff_id = excluded.referrer_staff_id,
          is_first_rental = excluded.is_first_rental, kickback_base_cents = excluded.kickback_base_cents,
          kickback_cents = excluded.kickback_cents, rental_charge_cents = excluded.rental_charge_cents,
          mileage_overage_cents = excluded.mileage_overage_cents, owner_revenue_cents = excluded.owner_revenue_cents,
          company_share_bps = excluded.company_share_bps, company_share_cents = excluded.company_share_cents,
          owner_payout_cents = excluded.owner_payout_cents, company_only_cents = excluded.company_only_cents,
          pass_through_cents = excluded.pass_through_cents, hst_cents = excluded.hst_cents,
          collected_cents = excluded.collected_cents, refunded_cents = excluded.refunded_cents,
          chargeback_cents = excluded.chargeback_cents, withheld_cents = excluded.withheld_cents,
          uncollected_cents = excluded.uncollected_cents, kickback_ineligible_reason = excluded.kickback_ineligible_reason,
          counts_on = excluded.counts_on, payout_month = excluded.payout_month, status = excluded.status,
          computed_at = now(), segment_days = excluded.segment_days, segment_starts_at = excluded.segment_starts_at,
          segment_ends_at = excluded.segment_ends_at;
    end if;
  end loop;
  -- a part on a car the booking no longer has (worked out before a change), not paid out yet
  delete from booking_splits where booking_id = p_booking and owner_statement_id is null and not (vehicle_id = any (v_vehicles));

  -- the kickback record: one per booking, on the whole rental charge
  if v_kick_total > 0 then
    insert into referral_kickbacks as k (booking_id, renter_id, vehicle_id, referrer_type, referrer_owner_id, referrer_staff_id,
        base_cents, rate_bps, amount_cents, status, earned_on)
    values (p_booking, b.renter_id, b.vehicle_id, b.referrer_type, b.referrer_owner_id, b.referrer_staff_id,
        v_rental_total, v_set.kickback_bps, v_kick_total, case when v_done then 'earned' else 'pending' end,
        case when v_done then v_counts end)
    on conflict (booking_id) do update set
        base_cents = excluded.base_cents, amount_cents = excluded.amount_cents,
        status = case when k.status = 'paid' then 'paid' else excluded.status end,
        earned_on = coalesce(k.earned_on, excluded.earned_on)
      where k.status <> 'paid' or k.amount_cents = excluded.amount_cents;
  else
    -- reversed if the rental is refunded or charged back
    with rev as (
      update referral_kickbacks k
         set status = 'reversed', reversed_at = now(), reversal_reason = coalesce(v_reason, 'rental refunded or charged back')
       where k.booking_id = p_booking and k.status <> 'reversed'
      returning k.*, (select o.status from referral_kickbacks o where o.id = k.id) as was
    )
    insert into owner_deductions (owner_id, kind, description, amount_cents, incurred_on, booking_id)
    select rev.referrer_owner_id, 'kickback_reversal',
           format('Booking %s: Referral Kickback reversed', b.booking_number), rev.amount_cents, app.today(), p_booking
      from rev where rev.was = 'paid' and rev.referrer_owner_id is not null and rev.amount_cents > 0;
  end if;
end $$;

-- Owner Revenue raised after a part was paid out (0021, gap 2), per car.
create or replace function app.sync_later_owner_revenue(p_booking uuid)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  s booking_splits;
  b bookings;
  p record;
  v_pay bigint; v_ded bigint; v_cred bigint; v_delta bigint;
  v_id uuid;
  v_first uuid;
begin
  if not exists (select 1 from booking_splits x where x.booking_id = p_booking and x.owner_statement_id is not null) then
    return null;
  end if;
  select * into b from bookings where id = p_booking;
  -- nothing is credited while any Owner Revenue on the booking is still unpaid
  if exists (select 1 from booking_line_items li
              where li.booking_id = p_booking and li.voided_at is null and li.charged_to_renter and li.revenue_class = 'owner_revenue'
                and not exists (select 1 from payments py where py.id = li.payment_id and py.status = 'succeeded')) then
    return null;
  end if;
  for p in select * from app.booking_split_parts(p_booking) order by ord loop
    select * into s from booking_splits where booking_id = p_booking and vehicle_id = p.vehicle_id;
    continue when s.booking_id is null or s.owner_statement_id is null;
    select x.owner_payout_cents into v_pay
      from public.calc_split(greatest(p.rental_cents - p.chargeback_cents, 0), p.mileage_cents, s.kickback_cents, s.company_share_bps) x;
    select coalesce(sum(amount_cents), 0) into v_ded from owner_deductions
     where booking_id = p_booking and vehicle_id = p.vehicle_id and kind in ('refund_share', 'chargeback_share') and status <> 'waived';
    select coalesce(sum(amount_cents), 0) into v_cred from owner_credits
     where booking_id = p_booking and vehicle_id = p.vehicle_id and kind = 'later_rental_revenue' and status <> 'waived';
    v_delta := v_pay - (s.owner_payout_cents - v_ded + v_cred);
    if v_delta > 0 then
      insert into owner_credits (owner_id, vehicle_id, booking_id, kind, description, amount_cents, incurred_on)
      values (s.owner_id, s.vehicle_id, p_booking, 'later_rental_revenue',
              format('Booking %s: Owner''s share of charges billed after it was paid out', b.booking_number), v_delta, app.today())
      returning id into v_id;
      v_first := coalesce(v_first, v_id);
    end if;
  end loop;
  return v_first;
end $$;

-- The lines of a month for CarmaCars' statement (0021), each shared between the cars of its
-- booking's segments as the split shares it.
create or replace function app.company_month_lines(p_month date)
returns table (line_id uuid, vehicle_id uuid, owner_id uuid, booking_id uuid, charge_type text, revenue_class revenue_class,
               amount_cents bigint, hst_cents bigint, refunded_cents bigint, refunded_hst_cents bigint, net_cents bigint,
               company_share_bps integer)
language sql stable security definer set search_path = public, app as $$
  select l.id, a.vehicle_id, a.owner_id, bk.id, l.charge_type, l.revenue_class,
         app.cut(l.amount_cents, a.w_lo, a.w_hi, a.w_sum), app.cut(l.hst_cents, a.w_lo, a.w_hi, a.w_sum),
         app.cut(coalesce(ra.amt, 0)::bigint, a.w_lo, a.w_hi, a.w_sum), app.cut(coalesce(ra.hst, 0)::bigint, a.w_lo, a.w_hi, a.w_sum),
         app.cut(l.amount_cents, a.w_lo, a.w_hi, a.w_sum) - app.cut(coalesce(ra.amt, 0)::bigint, a.w_lo, a.w_hi, a.w_sum),
         coalesce((select sp.company_share_bps from booking_splits sp where sp.booking_id = l.booking_id and sp.vehicle_id = a.vehicle_id),
                  a.company_share_bps)
    from booking_line_items l
    join bookings bk on bk.id = l.booking_id
    left join booking_statements bs on bs.id = l.statement_id
    left join lateral (select min(sp.payout_month) as payout_month from booking_splits sp where sp.booking_id = l.booking_id) spl on true
    left join lateral (select sum(x.amount_cents) as amt, sum(x.hst_cents) as hst from refund_allocations x
                         join refunds r on r.id = x.refund_id and r.status in ('approved', 'processing', 'paid')
                        where x.line_item_id = l.id) ra on true
    join lateral (select * from app.booking_line_allocation(l.booking_id) al where al.line_id = l.id) a on true
   where l.voided_at is null and l.charged_to_renter and bk.booking_type <> 'owner'
     and coalesce(case when bs.kind = 'later_charge' then app.month_start(app.local_date(bs.issued_at)) end, spl.payout_month,
                  case when bk.status in ('returned', 'closed') then app.month_start(app.local_date(coalesce(bk.checked_in_at, bk.return_at))) end)
         = app.month_start(p_month)
     and a.w_hi > a.w_lo
$$;

-- Days of a month per car (0021), with rented days taken from the segments: a swapped
-- booking counts on each car only for the time that car was out.
create or replace function app.vehicle_month_days(p_vehicle uuid, p_month date)
returns table (in_program numeric, blocked numeric, rented numeric, owner_days numeric)
language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
  m0 date := app.month_start(p_month);
  m1 date := (app.month_start(p_month) + interval '1 month')::date;
  t0 timestamptz;
  t1 timestamptz;
  w tstzmultirange;
  v_end date;
begin
  select * into v from vehicles where id = p_vehicle;
  v_end := app.vehicle_fee_end(p_vehicle);
  if v.enrollment_date is null or v.enrollment_date >= m1 or (v_end is not null and v_end < m0) then
    return query select 0::numeric, 0::numeric, 0::numeric, 0::numeric; return;
  end if;
  t0 := app.local_midnight(greatest(m0, v.enrollment_date));
  t1 := app.local_midnight(least(m1, coalesce(v_end + 1, m1)));
  w := tstzmultirange(tstzrange(t0, t1, '[)'));
  return query
  with periods as (
    select b.booking_type,
           case when s.seq = 1 then coalesce(b.handed_over_at, b.pickup_at) else s.starts_at end as p_from,
           case when s.is_last then coalesce(b.checked_in_at, case when b.status = 'on_rent' then t1 else b.return_at end)
                else s.ends_at end as p_to
      from bookings b
      cross join lateral app.booking_segments(b.id) s
     where (b.vehicle_id = p_vehicle or exists (select 1 from booking_vehicle_swaps x
                                                where x.booking_id = b.id and (x.from_vehicle_id = p_vehicle or x.to_vehicle_id = p_vehicle)))
       and b.status in ('on_rent', 'returned', 'closed') and s.vehicle_id = p_vehicle
       and coalesce(b.handed_over_at, b.pickup_at) < t1
  )
  select
    (least(m1, coalesce(v_end + 1, m1)) - greatest(m0, v.enrollment_date))::numeric,
    app.multirange_days((select range_agg(tstzrange(k.starts_at, greatest(k.starts_at, coalesce(k.ends_at, t1)), '[)')) from vehicle_calendar_blocks k
                          where k.vehicle_id = p_vehicle and k.reason in ('service', 'repair', 'owner_unavailable', 'exit', 'turo_owner_use')
                            and k.starts_at < t1 and coalesce(k.ends_at, t1) > t0) * w),
    app.multirange_days((select range_agg(x.r) from (
        select tstzrange(pr.p_from, greatest(pr.p_from, pr.p_to), '[)') as r from periods pr where pr.booking_type <> 'owner'
        union all
        select tstzrange(t.starts_at, t.ends_at, '[)') from turo_trips t where t.vehicle_id = p_vehicle and t.starts_at < t1 and t.ends_at > t0) x) * w),
    app.multirange_days((select range_agg(tstzrange(pr.p_from, greatest(pr.p_from, pr.p_to), '[)'))
                           from periods pr where pr.booking_type = 'owner') * w);
end $$;

-- ====================================================================================
-- Functions created again with the same signature (each change is marked 0025)
-- ====================================================================================

-- booking_before_write
create or replace function app.booking_before_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
declare
  v vehicles;
  v_set program_settings;
  prev bookings;
  v_moved boolean := false;
  v_arranging constant text[] := array['requested', 'offered', 'tentative', 'pending_payment'];
begin
  v_set := app.settings(app.local_date(coalesce(new.booked_at, now())));
  -- the non-refundable discount is fixed: 10% off the rental charge only, never off fees
  if new.booking_type = 'non_refundable'
     and new.discount_cents <> public.calc_bps(new.rental_charge_cents, v_set.non_refundable_discount_bps) then
    raise exception 'The non-refundable discount is fixed at % basis points of the rental charge', v_set.non_refundable_discount_bps
      using errcode = '23514';
  end if;
  if tg_op = 'INSERT' then
    select * into v from vehicles where id = new.vehicle_id;
    -- snapshot of who owns the vehicle and how it is managed
    new.owner_id := coalesce(new.owner_id, v.owner_id);
    new.management_mode := coalesce(new.management_mode, v.management_mode);
    new.is_shareholder_vehicle := v.is_shareholder_owned;
    if new.company_share_bps is null then
      new.company_share_bps := case
        when new.booking_type = 'owner' then 0
        when v.is_shareholder_owned then v_set.shareholder_company_share_bps
        when v.management_mode = 'self_managed' then 0
        else coalesce((app.vehicle_terms(v.id, app.local_date(coalesce(new.booked_at, now())))).revenue_share_bps,
                      (select s.revenue_share_bps from vehicle_schedules s where s.vehicle_id = v.id and s.superseded_by is null)) end;
    end if;
    if new.booking_type = 'owner' then
      -- only the vehicle's Owner makes an Owner Booking
      if not exists (select 1 from renters r join owners o on o.user_id = r.user_id
                      where r.id = new.renter_id and o.id = v.owner_id)
         and (new.status::text = any (v_arranging) or new.status = 'confirmed') then
        raise exception 'An Owner Booking is made by the vehicle''s own Owner' using errcode = '23514';
      end if;
    elsif new.status::text = any (v_arranging) or new.status = 'confirmed' then
      if not coalesce(app.vehicle_bookable(new.vehicle_id), false) then
        raise exception 'Vehicle is not open for new bookings' using errcode = '23514';
      end if;
      if v.exit_date is not null and app.local_date(new.return_at) > v.exit_date then
        raise exception 'The booking would run past the vehicle''s Exit Date' using errcode = '23514';
      end if;
    end if;
    -- a renewal: same renter, made before the current rental ends
    if new.renews_booking_id is not null then
      select * into prev from bookings where id = new.renews_booking_id;
      if prev.renter_id <> new.renter_id then
        raise exception 'A renewal belongs to the same renter as the booking it renews' using errcode = '23514';
      end if;
      if (new.status::text = any (v_arranging) or new.status = 'confirmed') and new.booked_at > coalesce(prev.checked_in_at, prev.return_at) then
        raise exception 'A renewal is made before the current rental ends' using errcode = '23514';
      end if;
    end if;
    if new.status = 'requested' then
      new.requested_at := coalesce(new.requested_at, new.booked_at, now());
    end if;
    return new;
  end if;

  -- UPDATE
  -- an extension past 7 days in total: the card hold must be captured first
  if new.billable_days > old.billable_days
     and new.billable_days > (app.settings()).deposit_hold_max_days
     and exists (select 1 from deposits d where d.booking_id = new.id and d.method = 'card_hold' and d.status = 'held') then
    raise exception 'Total length is now over 7 days: capture the card hold as a charged Deposit first' using errcode = '23514';
  end if;

  -- a request moved to another vehicle takes that vehicle's owner, mode and Revenue Share
  if new.vehicle_id is distinct from old.vehicle_id and old.status in ('requested', 'tentative') and new.status = old.status then
    select * into v from vehicles where id = new.vehicle_id;
    new.owner_id := v.owner_id;
    new.management_mode := v.management_mode;
    new.is_shareholder_vehicle := v.is_shareholder_owned;
    new.company_share_bps := case
      when new.booking_type = 'owner' then 0
      when v.is_shareholder_owned then v_set.shareholder_company_share_bps
      when v.management_mode = 'self_managed' then 0
      else coalesce((app.vehicle_terms(v.id, app.local_date(coalesce(new.booked_at, now())))).revenue_share_bps,
                    (select s.revenue_share_bps from vehicle_schedules s where s.vehicle_id = v.id and s.superseded_by is null)) end;
    if new.booking_type = 'owner' then
      if not exists (select 1 from renters r join owners o on o.user_id = r.user_id
                      where r.id = new.renter_id and o.id = v.owner_id) then
        raise exception 'An Owner Booking is made by the vehicle''s own Owner' using errcode = '23514';
      end if;
    else
      if not coalesce(app.vehicle_bookable(new.vehicle_id), false) then
        raise exception 'Vehicle is not open for new bookings' using errcode = '23514';
      end if;
      if v.exit_date is not null and app.local_date(new.return_at) > v.exit_date then
        raise exception 'The booking would run past the vehicle''s Exit Date' using errcode = '23514';
      end if;
    end if;
  end if;

  -- 0025: a confirmed booking moved before pickup to another car (the renter agreed through the
  -- change flow or the calendar) becomes one segment on that car: it takes the car's Owner,
  -- management mode and Revenue Share. Its stored rates do not change.
  if new.vehicle_id is distinct from old.vehicle_id and old.status = 'confirmed' and new.status = 'confirmed'
     and new.booking_type <> 'owner' then
    select * into v from vehicles where id = new.vehicle_id;
    new.owner_id := v.owner_id;
    new.management_mode := v.management_mode;
    new.is_shareholder_vehicle := v.is_shareholder_owned;
    new.company_share_bps := (app.vehicle_split_terms(v.id, app.local_date(coalesce(new.booked_at, now())), new.booking_type::text)).company_share_bps;
    v_moved := true;
  end if;

  -- a booking always uses the rates stored on it
  if not (old.status::text = any (v_arranging))
     and (new.daily_rate_cents, new.weekend_rate_cents, new.weekly_rate_cents, new.monthly_rate_cents,
          new.km_allowance_per_day, new.overage_cents_per_km,
          case when v_moved then null else new.company_share_bps end, case when v_moved then null else new.owner_id end,
          case when v_moved then null else new.management_mode end)
         is distinct from
         (old.daily_rate_cents, old.weekend_rate_cents, old.weekly_rate_cents, old.monthly_rate_cents,
          old.km_allowance_per_day, old.overage_cents_per_km,
          case when v_moved then null else old.company_share_bps end, case when v_moved then null else old.owner_id end,
          case when v_moved then null else old.management_mode end) then
    raise exception 'The rates and split terms stored on a confirmed booking cannot change' using errcode = '23514';
  end if;

  -- an offer that is out is what the renter approves: its terms stand still until it is withdrawn
  if old.status in ('offered', 'pending_payment') and new.status = old.status and old.current_offer_version is not null
     and (new.vehicle_id, new.booking_type, new.pickup_at, new.return_at,
          new.daily_rate_cents, new.weekend_rate_cents, new.weekly_rate_cents, new.monthly_rate_cents,
          new.rental_charge_cents, new.discount_cents, new.staff_discount_cents, new.promo_discount_cents, new.promo_code_id,
          new.km_allowance_per_day, new.overage_cents_per_km, new.deposit_cents,
          new.pickup_method, new.return_method, new.pickup_place, new.return_place,
          new.bill_to, new.insurer_id, new.insurer_authorized_daily_rate_cents, new.insurer_authorized_days, new.insurer_authorized_until,
          new.total_due_at_booking_cents, new.insurer_share_cents, new.insurer_hst_cents)
         is distinct from
         (old.vehicle_id, old.booking_type, old.pickup_at, old.return_at,
          old.daily_rate_cents, old.weekend_rate_cents, old.weekly_rate_cents, old.monthly_rate_cents,
          old.rental_charge_cents, old.discount_cents, old.staff_discount_cents, old.promo_discount_cents, old.promo_code_id,
          old.km_allowance_per_day, old.overage_cents_per_km, old.deposit_cents,
          old.pickup_method, old.return_method, old.pickup_place, old.return_place,
          old.bill_to, old.insurer_id, old.insurer_authorized_daily_rate_cents, old.insurer_authorized_days, old.insurer_authorized_until,
          old.total_due_at_booking_cents, old.insurer_share_cents, old.insurer_hst_cents) then
    raise exception 'An offer has been sent: withdraw it (back to requested) before changing its terms' using errcode = '23514';
  end if;

  -- a bill that goes to the renter alone carries no insurer part
  if new.bill_to = 'renter' then
    new.insurer_share_cents := 0;
    new.insurer_hst_cents := 0;
  end if;

  -- the calendar switch: who and why, every time
  if new.blocks_calendar is distinct from old.blocks_calendar then
    if pg_catalog.current_setting('role', true) = 'authenticated' then
      new.blocks_calendar_changed_by := app.uid();
    end if;
    if new.blocks_calendar_changed_by is null or btrim(coalesce(new.blocks_calendar_reason, '')) = ''
       or new.blocks_calendar_reason is not distinct from old.blocks_calendar_reason then
      raise exception 'Changing the calendar switch needs who is changing it and a reason for this change' using errcode = '23514';
    end if;
    new.blocks_calendar_changed_at := now();
  end if;

  if new.status is distinct from old.status then
    if new.status = 'requested' then
      -- back with staff: the approval and the deadline of the earlier offer no longer stand
      new.offer_expires_at := null;
      new.offer_approved_version := null;
      new.offer_approved_at := null;
      new.offer_approved_by := null;
      new.requested_at := coalesce(new.requested_at, now());
    elsif new.status = 'offered' then
      if new.offer_expires_at is null or not exists (
           select 1 from booking_offers o
            where o.booking_id = new.id and o.version = new.current_offer_version and o.status = 'sent') then
        raise exception 'A booking is offered only by sending an offer' using errcode = '23514';
      end if;
    elsif new.status = 'pending_payment' then
      if old.status = 'offered' then
        if new.offer_approved_version is null or new.offer_approved_version is distinct from new.current_offer_version
           or not exists (select 1 from booking_offers o
                           where o.booking_id = new.id and o.version = new.current_offer_version and o.status = 'approved') then
          raise exception 'The renter must approve the current offer before signing and payment' using errcode = '23514';
        end if;
      elsif old.status = 'requested' and new.booking_type <> 'owner' then
        raise exception 'Only an Owner Booking goes to signing without an offer' using errcode = '23514';
      end if;
    elsif new.status = 'confirmed' then
      if not exists (select 1 from signature_requests s where s.id = new.signature_request_id and s.status = 'completed') then
        raise exception 'A booking is confirmed only when the agreement is signed' using errcode = '23514';
      end if;
      -- billed to an insurer with nothing due from the renter: there is no card payment to wait for
      if new.booking_type <> 'owner'
         and not (new.bill_to <> 'renter'
                  and new.total_due_at_booking_cents - new.insurer_share_cents - new.insurer_hst_cents <= 0)
         and not exists (
           select 1 from payments p where p.booking_id = new.id and p.purpose = 'booking_total'
              and p.kind = 'charge' and p.status = 'succeeded') then
        raise exception 'A booking is confirmed only when payment succeeds' using errcode = '23514';
      end if;
      if new.booking_type <> 'owner' and new.card_on_file_id is null then
        raise exception 'No saved card, no confirmed booking' using errcode = '23514';
      end if;
      new.confirmed_at := coalesce(new.confirmed_at, now());
    elsif new.status = 'on_rent' then
      if exists (select 1 from booking_drivers d where d.booking_id = new.id and d.identity_verified_on is null)
         or not exists (select 1 from booking_drivers d where d.booking_id = new.id and d.role = 'renter') then
        raise exception 'No car is released until every driver''s identity is verified' using errcode = '23514';
      end if;
      if new.booking_type <> 'owner' then
        if new.coverage_confirmed_at is null or not exists (
             select 1 from coverage_proofs c where c.booking_id = new.id and c.status = 'confirmed') then
          raise exception 'No car is released until a Coverage Option is confirmed' using errcode = '23514';
        end if;
        if new.deposit_cents > 0 and not exists (
             select 1 from deposits d where d.booking_id = new.id and d.status in ('held', 'captured')) then
          raise exception 'The Deposit is taken at pickup, before handover' using errcode = '23514';
        end if;
      end if;
      if not exists (select 1 from condition_reports c where c.booking_id = new.id and c.kind = 'pickup') then
        raise exception 'Handover needs the pickup Condition Report' using errcode = '23514';
      end if;
      new.handed_over_at := coalesce(new.handed_over_at, now());
    elsif new.status = 'returned' then
      if not exists (select 1 from condition_reports c where c.booking_id = new.id and c.kind = 'return') then
        raise exception 'Check-in needs the return Condition Report' using errcode = '23514';
      end if;
      new.checked_in_at := coalesce(new.checked_in_at, now());
    elsif new.status in ('cancelled', 'no_show') and old.status = 'confirmed' then
      if not exists (select 1 from booking_cancellations c where c.booking_id = new.id) then
        raise exception 'Log the cancellation (booking made, cancellation received, start) before cancelling' using errcode = '23514';
      end if;
    end if;
  end if;

  -- the car must be free whenever a booking starts to block it, or moves while blocking it
  if new.blocks_calendar and new.status in ('confirmed', 'on_rent')
     and (old.status not in ('confirmed', 'on_rent') or not old.blocks_calendar
          or new.vehicle_id is distinct from old.vehicle_id
          or new.pickup_at is distinct from old.pickup_at or new.return_at is distinct from old.return_at)
     and not app.vehicle_free_locked(new.vehicle_id, new.pickup_at, new.return_at, new.id) then
    raise exception 'The vehicle is not available for these dates: a confirmed booking or a calendar block overlaps'
      using errcode = '23P01';
  end if;
  return new;
end $function$;

-- preview_booking_change
create or replace function app.preview_booking_change(p_booking uuid, p_changes jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
declare
  b bookings;
  v2 vehicles;
  v_set program_settings := app.settings();
  ch jsonb := coalesce(p_changes, '{}'::jsonb);
  k text;
  v_vehicle uuid; v_pickup timestamptz; v_return timestamptz;
  v_problems jsonb := '[]'::jsonb;
  v_days integer;
  o record; n record;
  v_rental bigint;
  v_new jsonb;
  v_owned text[] := array['rental_charge', 'non_refundable_discount', 'staff_discount', 'promo_discount', 'delivery', 'pickup'];
  v_other bigint; v_other_hst bigint;
  v_sub bigint; v_hst bigint;
  v_available boolean := true;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if jsonb_typeof(ch) <> 'object' then raise exception 'Give the changes as a JSON object' using errcode = '22023'; end if;
  for k in select jsonb_object_keys(ch) loop
    if k not in ('pickup_at', 'return_at', 'vehicle_id') then
      raise exception 'Unknown change "%": a confirmed booking may change its dates or its car', k using errcode = '22023';
    end if;
  end loop;
  v_vehicle := coalesce((ch ->> 'vehicle_id')::uuid, b.vehicle_id);
  v_pickup := coalesce((ch ->> 'pickup_at')::timestamptz, b.pickup_at);
  v_return := coalesce((ch ->> 'return_at')::timestamptz, b.return_at);
  if v_return <= v_pickup then raise exception 'The return must be after the pickup' using errcode = '22023'; end if;
  if (v_vehicle, v_pickup, v_return) is not distinct from (b.vehicle_id, b.pickup_at, b.return_at) then
    v_problems := v_problems || jsonb_build_object('code', 'nothing_changes', 'message', 'These are the dates and the car the booking already has.');
  end if;
  if b.status <> 'confirmed' then
    v_problems := v_problems || jsonb_build_object('code', 'not_confirmed',
      'message', format('Booking %s is %s. A change request is for a confirmed booking that has not started.', b.booking_number, b.status));
  end if;
  if b.dates_provisional or b.bill_to <> 'renter' then
    v_problems := v_problems || jsonb_build_object('code', 'insurer_booking', 'message', 'A booking billed to an insurer is changed by staff.');
  end if;
  if exists (select 1 from booking_extensions e where e.booking_id = p_booking and e.status in ('requested', 'approved', 'confirmed')) then
    v_problems := v_problems || jsonb_build_object('code', 'has_extension', 'message', 'A booking with an extension is changed by staff.');
  end if;
  if v_pickup <> b.pickup_at and v_pickup < now() then
    v_problems := v_problems || jsonb_build_object('code', 'pickup_in_past', 'message', 'The new pickup time has already passed.');
  end if;
  v_days := public.calc_billable_days(v_pickup, v_return);
  if v_days > least(v_set.max_rental_days, 30) then
    v_problems := v_problems || jsonb_build_object('code', 'over_maximum_length',
      'message', format('A rental is %s days or less. A longer stay is a renewal.', least(v_set.max_rental_days, 30)));
    return jsonb_build_object('ok', false, 'problems', v_problems, 'booking_id', b.id);
  end if;
  if v_vehicle <> b.vehicle_id then
    select * into v2 from vehicles where id = v_vehicle;
    if v2.id is null then raise exception 'Vehicle not found' using errcode = '22023'; end if;
    if b.booking_type <> 'owner' and not coalesce(app.vehicle_bookable(v_vehicle), false) then
      v_problems := v_problems || jsonb_build_object('code', 'vehicle_not_bookable', 'message', 'That car is not open for bookings.');
    end if;
    -- 0025: a booking may move to another Owner's car once the renter agrees; it then takes that
    -- car's Owner, management mode and Revenue Share (app.booking_before_write). An Owner Booking
    -- stays on its Owner's own cars.
    if b.booking_type = 'owner' and v2.owner_id <> b.owner_id then
      v_problems := v_problems || jsonb_build_object('code', 'other_owner_vehicle',
        'message', 'An Owner Booking moves only to another car of the same Owner.');
    end if;
    if exists (select 1 from booking_drivers d where d.booking_id = p_booking
                  and app.age_band(app.age_on(d.date_of_birth, app.local_date(v_pickup))) = '18_to_20') and not v2.allows_18_to_20 then
      v_problems := v_problems || jsonb_build_object('code', 'vehicle_not_for_young_drivers',
        'message', format('That car is for drivers %s and over.', v_set.standard_min_age));
    end if;
  else
    select * into v2 from vehicles where id = b.vehicle_id;
  end if;
  if v2.exit_date is not null and app.local_date(v_return) > v2.exit_date then
    v_problems := v_problems || jsonb_build_object('code', 'vehicle_leaving', 'message', 'The car is not offered for the whole of these dates.');
  end if;
  if exists (select 1 from booking_drivers d where d.booking_id = p_booking
                and app.age_on(d.date_of_birth, app.local_date(v_pickup)) < v_set.min_renter_age) then
    v_problems := v_problems || jsonb_build_object('code', 'driver_under_minimum_age',
      'message', format('Every driver must be %s or older at pickup.', v_set.min_renter_age));
  end if;
  if b.blocks_calendar then
    v_available := app.vehicle_is_available(v_vehicle, v_pickup, v_return, b.id);
    if not v_available then
      v_problems := v_problems || jsonb_build_object('code', 'not_available', 'message', 'The car is not free for the whole of these dates.');
    end if;
  end if;

  -- the price after the change
  if b.booking_type = 'owner' then
    v_rental := 0;
  else
    select * into o from public.calc_rental_charge(b.pickup_at, b.billable_days, b.daily_rate_cents, b.weekend_rate_cents, b.weekly_rate_cents, b.monthly_rate_cents);
    select * into n from public.calc_rental_charge(v_pickup, v_days, b.daily_rate_cents, b.weekend_rate_cents, b.weekly_rate_cents, b.monthly_rate_cents);
    v_rental := greatest(0, b.rental_charge_cents + n.rental_charge_cents - o.rental_charge_cents);
  end if;
  v_new := app.price_lines(app.booking_price_spec(p_booking, ch || jsonb_build_object('rental_charge_cents', v_rental)));
  if b.request_details is not null then
    v_owned := v_owned || array['young_driver_18_20', 'young_driver_21_25', 'additional_driver', 'winter_tire', 'baby_seat', 'coverage_sold'];
  end if;
  -- lines staff entered by hand stay as they are
  select coalesce(sum(li.amount_cents), 0), coalesce(sum(li.hst_cents), 0) into v_other, v_other_hst
    from booking_line_items li
   where li.booking_id = p_booking and li.stage = 'booking' and li.charged_to_renter and li.voided_at is null
     and not li.charge_type = any (v_owned);
  v_sub := (v_new ->> 'subtotal_cents')::bigint + v_other;
  v_hst := (v_new ->> 'hst_cents')::bigint + v_other_hst;
  return jsonb_build_object('ok', jsonb_array_length(v_problems) = 0, 'problems', v_problems, 'booking_id', b.id, 'changes', ch,
    'before', jsonb_build_object('vehicle_id', b.vehicle_id, 'pickup_at', b.pickup_at, 'return_at', b.return_at, 'billable_days', b.billable_days,
                                 'rental_charge_cents', b.rental_charge_cents, 'subtotal_cents', b.subtotal_at_booking_cents,
                                 'hst_cents', b.hst_at_booking_cents, 'total_cents', b.total_due_at_booking_cents),
    'after', jsonb_build_object('vehicle_id', v_vehicle, 'pickup_at', v_pickup, 'return_at', v_return, 'billable_days', v_days,
                                'rental_charge_cents', v_rental, 'rate_applied', v_new ->> 'rate_applied',
                                'subtotal_cents', v_sub, 'hst_cents', v_hst, 'total_cents', v_sub + v_hst),
    'lines', (select coalesce(jsonb_agg((x.value - 'revenue_class' - 'sort_order') order by x.ord), '[]'::jsonb)
                from jsonb_array_elements(v_new -> 'lines') with ordinality x(value, ord)),
    'difference_cents', v_sub - b.subtotal_at_booking_cents, 'hst_cents', v_hst - b.hst_at_booking_cents,
    'total_difference_cents', (v_sub + v_hst) - b.total_due_at_booking_cents, 'available', v_available);
end $function$;

-- calendar_preview_change
create or replace function app.calendar_preview_change(p_booking uuid, p_changes jsonb, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
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
  v_out jsonb;
  v_19 jsonb;
  v_problem jsonb;
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
  elsif b.status = 'confirmed' and v_vehicle <> b.vehicle_id and b.booking_type = 'owner' and v.owner_id <> b.owner_id then
    v_refusal := 'An Owner Booking moves only to another vehicle of the same Owner';
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

  v_out := jsonb_build_object(
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

  -- one flow with the booking application (0019)
  if v_refusal is null and v_action = 'renter_approval' and b.bill_to = 'renter' then
    v_19 := app.preview_booking_change(p_booking, jsonb_strip_nulls(jsonb_build_object(
              'vehicle_id', case when v_vehicle <> b.vehicle_id then v_vehicle end,
              'pickup_at', case when v_pickup <> b.pickup_at then v_pickup end,
              'return_at', case when v_return <> b.return_at then v_return end)));
    select p into v_problem from jsonb_array_elements(v_19 -> 'problems') p
     where p ->> 'code' not in ('not_available', 'nothing_changes') limit 1;
    v_out := v_out || jsonb_build_object('flow', 'change_request', 'change_request_preview', v_19);
    if v_problem is not null then
      v_out := v_out || jsonb_build_object('refusal', v_problem ->> 'message', 'action', 'refused', 'renter_must_approve', false);
    else
      v_out := v_out || jsonb_build_object('difference_cents', v_19 -> 'total_difference_cents',
                                           'difference_before_hst_cents', v_19 -> 'difference_cents');
    end if;
  elsif v_refusal is null and v_action = 'extension' then
    v_19 := app.preview_extension(p_booking, v_return, p_now);
    select p into v_problem from jsonb_array_elements(v_19 -> 'problems') p
     where p ->> 'code' not in ('not_available') limit 1;
    v_out := v_out || jsonb_build_object('flow', 'extension', 'extension_preview', v_19);
    if v_problem is not null then
      v_out := v_out || jsonb_build_object('refusal', v_problem ->> 'message', 'action', 'refused', 'renter_must_approve', false);
    else
      v_out := v_out || jsonb_build_object('difference_cents', v_19 -> 'total_cents',
                                           'difference_before_hst_cents', (v_19 ->> 'rental_difference_cents')::bigint + (v_19 ->> 'fees_difference_cents')::bigint);
    end if;
  end if;
  return v_out;
end $function$;

-- build_owner_statement
create or replace function app.build_owner_statement(p_owner uuid, p_month date, p_by uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
declare
  v_month date := app.month_start(p_month);
  v_month_end date := (app.month_start(p_month) + interval '1 month - 1 day')::date;
  o owners;
  v_id uuid;
  v_status text;
  r record; inv record; other record;
  v_rev bigint; v_share bigint; v_withheld bigint; v_net bigint; v_avail bigint;
  v_take bigint; v_fee_part bigint; v_late_part bigint; v_need bigint;
  v_fees bigint; v_late bigint; v_costs bigint; v_refunds bigint;
  v_moved bigint := 0;
  v_kick bigint; v_hst bigint := 0; v_total bigint; v_payable bigint; v_net_all bigint;
  v_credits bigint; v_credits_all bigint := 0;
  v_prev owner_statements;
begin
  select * into o from owners where id = p_owner;
  if not found then raise exception 'Owner % not found', p_owner; end if;

  select id, status into v_id, v_status from owner_statements where owner_id = p_owner and statement_month = v_month and status <> 'void';
  if v_id is not null and v_status <> 'draft' then
    raise exception 'The % statement for this Owner is already %', to_char(v_month, 'YYYY-MM'), v_status using errcode = '23514';
  end if;
  if v_id is null then
    select * into v_prev from owner_statements where owner_id = p_owner and statement_month = v_month and status = 'void'
     order by version desc limit 1;
    insert into owner_statements (owner_id, statement_month, payout_date, built_by, version, supersedes_statement_id)
    values (p_owner, v_month, app.payout_date(v_month), p_by, coalesce(v_prev.version, 0) + 1, v_prev.id) returning id into v_id;
  else
    delete from owner_statement_lines where owner_statement_id = v_id;
    delete from owner_statement_vehicles where owner_statement_id = v_id;
    update owner_statements set built_at = now(), built_by = p_by, payout_date = app.payout_date(v_month) where id = v_id;
  end if;

  -- bring every finished booking's split up to date first
  -- (its own vehicles' bookings, and bookings on other vehicles whose renter this Owner referred)
  for r in select b.id from bookings b
            where (b.owner_id = p_owner or b.referrer_owner_id = p_owner
                   or exists (select 1 from booking_vehicle_swaps w where w.booking_id = b.id and w.to_owner_id = p_owner))
              and b.booking_type <> 'owner'
              and b.status in ('returned', 'closed', 'cancelled', 'no_show')
              and (not exists (select 1 from booking_splits s where s.booking_id = b.id and s.owner_statement_id is not null)
                   or exists (select 1 from booking_splits s where s.booking_id = b.id and s.owner_statement_id is null))
  loop
    perform app.compute_booking_split(r.id);
  end loop;
  -- Owner Revenue raised on bookings already paid out (gap 2)
  for r in select s.booking_id from booking_splits s join bookings b on b.id = s.booking_id
            where s.owner_id = p_owner and s.owner_statement_id is not null and b.status in ('returned', 'closed')
  loop
    perform app.sync_later_owner_revenue(r.booking_id);
  end loop;

  -- one block per vehicle with anything to show
  for r in
    select v.id as vehicle_id
      from vehicles v
     where v.owner_id = p_owner
       and (exists (select 1 from booking_splits s where s.vehicle_id = v.id and s.owner_id = p_owner
                      and s.owner_statement_id is null and s.payout_month <= v_month and s.status <> 'reversed' and s.uncollected_cents = 0)
         or exists (select 1 from turo_trips t where t.vehicle_id = v.id and t.owner_statement_id is null and t.statement_month <= v_month and t.received_at is not null)
         or exists (select 1 from owner_invoices i where i.vehicle_id = v.id and i.status in ('in_arrears', 'partially_deducted'))
         or exists (select 1 from owner_deductions d where d.vehicle_id = v.id and d.owner_id = p_owner and d.status = 'open' and d.incurred_on <= v_month_end)
         or exists (select 1 from owner_credits c where c.vehicle_id = v.id and c.owner_id = p_owner and c.status = 'open' and c.incurred_on <= v_month_end)
         -- every vehicle in the program during the month, even with nothing to show (gap 1)
         or (v.enrollment_date is not null and v.enrollment_date <= v_month_end
             and (app.vehicle_fee_end(v.id) is null or app.vehicle_fee_end(v.id) >= v_month)))
     order by v.fleet_number nulls last, v.created_at, v.id
  loop
    -- each rental ended (and each cancellation that kept part of the rental charge)
    insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, booking_id, starts_on, ends_on,
        rental_charge_cents, mileage_overage_cents, refunds_cents, chargebacks_cents, kickback_cents,
        owner_revenue_cents, revenue_share_cents, amount_cents)
    select v_id, r.vehicle_id, 'rental', 'Booking ' || b.booking_number, b.id,
           app.local_date(coalesce(s.segment_starts_at, b.pickup_at)), s.counts_on,
           s.rental_charge_cents, s.mileage_overage_cents, s.refunded_cents, s.chargeback_cents, s.kickback_cents,
           s.owner_revenue_cents, s.company_share_cents, s.owner_payout_cents
      from booking_splits s join bookings b on b.id = s.booking_id
     where s.vehicle_id = r.vehicle_id and s.owner_id = p_owner and s.owner_statement_id is null
       and s.payout_month <= v_month and s.status <> 'reversed' and s.uncollected_cents = 0
     order by s.counts_on, b.booking_number;

    -- each Turo trip: the split applies to the Turo Payout
    insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, turo_trip_id, starts_on, ends_on,
        turo_gross_cents, turo_fees_cents, owner_revenue_cents, revenue_share_cents, amount_cents)
    select v_id, r.vehicle_id, 'turo_trip', 'Turo trip ' || t.turo_trip_ref, t.id,
           app.local_date(t.starts_at), app.local_date(t.ends_at),
           t.gross_cents, t.turo_fees_cents, t.net_payout_cents, t.revenue_share_cents, t.owner_payout_cents
      from turo_trips t
     where t.vehicle_id = r.vehicle_id and t.owner_statement_id is null and t.statement_month <= v_month and t.received_at is not null;

    select coalesce(sum(owner_revenue_cents), 0), coalesce(sum(revenue_share_cents), 0), coalesce(sum(amount_cents), 0)
      into v_rev, v_share, v_net
      from owner_statement_lines where owner_statement_id = v_id and vehicle_id = r.vehicle_id and line_type in ('rental', 'turo_trip');

    -- Owner Revenue in dispute is withheld from the payout
    select coalesce(sum(least(s.withheld_cents, s.owner_payout_cents)), 0) into v_withheld
      from booking_splits s
     where s.vehicle_id = r.vehicle_id and s.owner_id = p_owner and s.owner_statement_id is null
       and s.payout_month <= v_month and s.status <> 'reversed' and s.uncollected_cents = 0 and s.withheld_cents > 0;
    if v_withheld > 0 then
      insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, amount_cents)
      values (v_id, r.vehicle_id, 'withheld', 'Owner Revenue in dispute, withheld', -v_withheld);
      v_net := v_net - v_withheld;
    end if;

    -- unpaid Fees and Late Fees after a failed retry: from this vehicle's revenue
    v_avail := greatest(v_net, 0);
    v_fees := 0; v_late := 0;
    for inv in select * from owner_invoices i
                where i.vehicle_id = r.vehicle_id and i.status in ('in_arrears', 'partially_deducted') and i.balance_cents > 0
                order by i.billing_date, i.invoice_number
    loop
      v_take := least(inv.balance_cents, v_avail);
      if v_take > 0 then
        -- Fees (with HST) are settled before the Late Fee
        v_fee_part := least(v_take, greatest(inv.fees_cents + inv.hst_cents - inv.paid_cents - inv.deducted_cents, 0));
        v_late_part := v_take - v_fee_part;
        insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, owner_invoice_id,
            fee_cents, late_fee_cents, amount_cents)
        values (v_id, r.vehicle_id, 'fees_deducted', 'Invoice ' || inv.invoice_number, inv.id, v_fee_part, v_late_part, -v_take);
        v_fees := v_fees + v_fee_part; v_late := v_late + v_late_part;
        v_avail := v_avail - v_take;
      end if;
    end loop;

    -- Owner costs CarmaCars paid, and the Owner's share of an earlier refund or chargeback
    insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, owner_deduction_id, booking_id, amount_cents)
    select v_id, r.vehicle_id,
           case when d.kind in ('refund_share', 'chargeback_share') then 'refund_or_chargeback' else 'owner_cost' end,
           d.description, d.id, d.booking_id, -d.amount_cents
      from owner_deductions d
     where d.vehicle_id = r.vehicle_id and d.owner_id = p_owner and d.status = 'open' and d.incurred_on <= v_month_end;
    select coalesce(-sum(amount_cents) filter (where line_type = 'owner_cost'), 0),
           coalesce(-sum(amount_cents) filter (where line_type = 'refund_or_chargeback'), 0)
      into v_costs, v_refunds
      from owner_statement_lines where owner_statement_id = v_id and vehicle_id = r.vehicle_id;

    -- Owner credits: Owner Revenue billed after the booking was paid out
    insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, owner_credit_id, booking_id, amount_cents)
    select v_id, r.vehicle_id, 'later_revenue', c.description, c.id, c.booking_id, c.amount_cents
      from owner_credits c
     where c.vehicle_id = r.vehicle_id and c.owner_id = p_owner and c.status = 'open' and c.incurred_on <= v_month_end;
    select coalesce(sum(amount_cents), 0) into v_credits
      from owner_statement_lines where owner_statement_id = v_id and vehicle_id = r.vehicle_id and line_type = 'later_revenue';
    v_credits_all := v_credits_all + v_credits;

    insert into owner_statement_vehicles (owner_statement_id, vehicle_id, owner_revenue_cents, revenue_share_cents,
        withheld_cents, net_earnings_cents, fees_deducted_cents, late_fees_deducted_cents,
        owner_costs_deducted_cents, refund_chargeback_deducted_cents, credits_cents, payable_cents)
    values (v_id, r.vehicle_id, v_rev, v_share, v_withheld, v_net, v_fees, v_late, v_costs, v_refunds, v_credits,
            v_net - v_fees - v_late - v_costs - v_refunds + v_credits);
  end loop;

  -- deductions not tied to a vehicle (a reversed kickback, an agreed amount)
  insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, owner_deduction_id, booking_id, amount_cents)
  select v_id, null, 'owner_cost', d.description, d.id, d.booking_id, -d.amount_cents
    from owner_deductions d
   where d.vehicle_id is null and d.owner_id = p_owner and d.status = 'open' and d.incurred_on <= v_month_end;

  -- Balance still left: a debt payable on demand, deducted from the Owner's other vehicles
  for inv in select i.*, i.balance_cents - coalesce((select -sum(l.amount_cents) from owner_statement_lines l
                                  where l.owner_statement_id = v_id and l.owner_invoice_id = i.id), 0) as still_owed
               from owner_invoices i
              where i.owner_id = p_owner and i.status in ('in_arrears', 'partially_deducted') and i.balance_cents > 0
              order by i.billing_date, i.invoice_number
  loop
    v_need := inv.still_owed;
    for other in select sv.vehicle_id,
                        sv.payable_cents - coalesce((select sum(-l.amount_cents) from owner_statement_lines l
                            where l.owner_statement_id = v_id and l.line_type = 'arrears_moved' and l.vehicle_id = sv.vehicle_id), 0) as free
                   from owner_statement_vehicles sv
                  where sv.owner_statement_id = v_id and sv.vehicle_id <> inv.vehicle_id
                  order by sv.payable_cents desc
    loop
      exit when v_need <= 0;
      v_take := least(v_need, greatest(other.free, 0));
      if v_take > 0 then
        insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, owner_invoice_id, from_vehicle_id, amount_cents)
        values (v_id, other.vehicle_id, 'arrears_moved', 'Arrears on invoice ' || inv.invoice_number, inv.id, inv.vehicle_id, -v_take);
        v_moved := v_moved + v_take;
        v_need := v_need - v_take;
      end if;
    end loop;
  end loop;

  -- Referral Kickbacks this Owner earned: paid with the next payout
  insert into owner_statement_lines (owner_statement_id, line_type, description, referral_kickback_id, booking_id,
      rental_charge_cents, amount_cents)
  select v_id, 'kickback_earned', 'Referral Kickback, booking ' || b.booking_number, k.id, k.booking_id, k.base_cents, k.amount_cents
    from referral_kickbacks k join bookings b on b.id = k.booking_id
   where k.referrer_owner_id = p_owner and k.status = 'earned' and k.owner_statement_id is null and k.earned_on <= v_month_end;
  select coalesce(sum(amount_cents), 0) into v_kick
    from owner_statement_lines where owner_statement_id = v_id and line_type = 'kickback_earned';

  select coalesce(sum(payable_cents), 0), coalesce(sum(net_earnings_cents), 0) into v_payable, v_net_all
    from owner_statement_vehicles where owner_statement_id = v_id;
  v_payable := v_payable - coalesce((select sum(-amount_cents) from owner_statement_lines
                                      where owner_statement_id = v_id and vehicle_id is null and line_type = 'owner_cost'), 0);

  -- HST is added only when the Owner's HST number is on file
  if o.hst_number is not null and btrim(o.hst_number) <> '' and v_net_all + v_credits_all > 0 then
    v_hst := public.calc_hst(v_net_all + v_credits_all, (app.settings(v_month)).hst_bps);
    insert into owner_statement_lines (owner_statement_id, line_type, description, amount_cents)
    values (v_id, 'hst_on_payout', 'HST on payout, registration ' || o.hst_number, v_hst);
  end if;
  if o.balance_carried_forward_cents <> 0 then
    insert into owner_statement_lines (owner_statement_id, line_type, description, amount_cents)
    values (v_id, 'balance_brought_forward', 'Balance brought forward', o.balance_carried_forward_cents);
  end if;

  v_total := v_payable - v_moved + v_kick + v_hst + o.balance_carried_forward_cents;

  update owner_statements st
     set owner_revenue_cents = coalesce((select sum(owner_revenue_cents) from owner_statement_vehicles where owner_statement_id = v_id), 0),
         revenue_share_cents = coalesce((select sum(revenue_share_cents) from owner_statement_vehicles where owner_statement_id = v_id), 0),
         net_earnings_cents = v_net_all,
         deductions_cents = coalesce((select sum(fees_deducted_cents + late_fees_deducted_cents + owner_costs_deducted_cents + refund_chargeback_deducted_cents)
                                        from owner_statement_vehicles where owner_statement_id = v_id), 0),
         vehicles_payable_cents = v_payable,
         credits_cents = v_credits_all,
         arrears_moved_cents = v_moved,
         kickbacks_earned_cents = v_kick,
         hst_on_payout_cents = v_hst,
         balance_brought_forward_cents = o.balance_carried_forward_cents,
         payout_cents = greatest(v_total, 0),
         balance_carried_forward_cents = least(v_total, 0),
         is_final = not exists (select 1 from vehicles v where v.owner_id = p_owner and v.status not in ('exited', 'total_loss', 'declined'))
   where st.id = v_id;
  return v_id;
end $function$;

-- approve_owner_statement
create or replace function app.approve_owner_statement(p_statement uuid, p_admin uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
declare
  st owner_statements;
  l record;
  v_payout uuid;
begin
  if not exists (select 1 from user_roles where user_id = p_admin and role = 'admin') then
    raise exception 'Only an Admin approves a payout run' using errcode = '42501';
  end if;
  select * into st from owner_statements where id = p_statement for update;
  if st.status <> 'draft' then
    raise exception 'Statement % is already %', st.statement_number, st.status using errcode = '23514';
  end if;

  for l in select owner_invoice_id, sum(-amount_cents) as taken
             from owner_statement_lines
            where owner_statement_id = p_statement and owner_invoice_id is not null
              and line_type in ('fees_deducted', 'arrears_moved')
            group by owner_invoice_id
  loop
    update owner_invoices
       set deducted_cents = deducted_cents + l.taken,
           status = case when balance_cents - l.taken <= 0 then 'deducted' else 'partially_deducted' end
     where id = l.owner_invoice_id;
  end loop;

  update owner_deductions d set status = 'deducted', owner_statement_id = p_statement
    from owner_statement_lines sl where sl.owner_statement_id = p_statement and sl.owner_deduction_id = d.id;
  update owner_credits c set status = 'credited', owner_statement_id = p_statement
    from owner_statement_lines sl where sl.owner_statement_id = p_statement and sl.owner_credit_id = c.id;
  update referral_kickbacks k set owner_statement_id = p_statement
    from owner_statement_lines sl where sl.owner_statement_id = p_statement and sl.referral_kickback_id = k.id;
  update booking_splits s set owner_statement_id = p_statement, status = case when s.status = 'provisional' then 'final' else s.status end
    from owner_statement_lines sl where sl.owner_statement_id = p_statement and sl.line_type = 'rental' and sl.booking_id = s.booking_id
     and sl.vehicle_id = s.vehicle_id;
  update turo_trips t set owner_statement_id = p_statement
    from owner_statement_lines sl where sl.owner_statement_id = p_statement and sl.turo_trip_id = t.id;
  update owners set balance_carried_forward_cents = st.balance_carried_forward_cents where id = st.owner_id;

  update owner_statements set status = 'approved', approved_by = p_admin, approved_at = now() where id = p_statement;

  if st.payout_cents > 0 then
    insert into payouts (payee_type, owner_id, kind, owner_statement_id, amount_cents, hst_cents, method,
                         scheduled_for, status, prepared_by, approved_by, approved_at)
    select 'owner', st.owner_id,
           case when not exists (select 1 from vehicles v where v.owner_id = st.owner_id and v.management_mode <> 'turo_only')
                then 'turo_only_statement' else 'owner_statement' end,
           p_statement, st.payout_cents, st.hst_on_payout_cents, o.payout_method,
           st.payout_date, 'approved', st.built_by, p_admin, now()
      from owners o where o.id = st.owner_id
    returning id into v_payout;
  else
    -- nothing to transfer: kickbacks earned were set against what the Owner owes
    update referral_kickbacks set status = 'paid', paid_at = now()
     where owner_statement_id = p_statement and status = 'earned';
  end if;
  return v_payout;
end $function$;

-- build_company_statement
create or replace function app.build_company_statement(p_month date, p_by uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
declare
  m0 date := app.month_start(p_month);
  m1 date := (app.month_start(p_month) + interval '1 month')::date;
  t0 timestamptz := app.local_midnight(app.month_start(p_month));
  t1 timestamptz := app.local_midnight((app.month_start(p_month) + interval '1 month')::date);
  v_id uuid;
  v_status text;
  v_cols text[] := app.company_statement_sum_columns();
  v_sums text;
  v_checks jsonb := '[]'::jsonb;
  v_problems text[] := '{}';
  c record;
  v_a bigint; v_b bigint; v_n bigint;
begin
  if p_by is not null and not app.user_runs_finance(p_by) then
    raise exception 'Finance or an Admin builds the company statement' using errcode = '42501';
  end if;
  select id, status into v_id, v_status from company_statements where statement_month = m0 for update;
  if v_status = 'final' then
    raise exception 'The company statement for % is final', to_char(m0, 'YYYY-MM') using errcode = '23514';
  end if;
  if v_id is null then
    insert into company_statements (statement_month, built_by) values (m0, p_by) returning id into v_id;
  else
    delete from company_statement_lines where statement_id = v_id;
    update company_statements set built_at = now(), built_by = p_by, version = version + 1 where id = v_id;
  end if;

  -- ---- vehicle level
  insert into company_statement_lines (statement_id, level, vehicle_id, owner_id, label, management_mode, billing_case,
      days_in_program, days_available, days_rented, owner_days, rentals_ended, billable_days,
      rental_revenue_cents, mileage_cents, kickbacks_cents, owner_revenue_cents, revenue_share_cents, owner_share_out_cents,
      discounts_cents, discounts_owner_cents, discounts_company_cents, company_fees_cents, company_fees_by_type,
      turo_gross_cents, turo_fees_cents, turo_revenue_share_cents, turo_extras_cents, turo_owner_cents,
      insurance_fees_cents, tracker_fees_cents, install_fees_cents, other_owner_fees_cents, prepaid_last_month_cents,
      owner_fees_hst_cents, owner_fees_collected_cents, owner_fees_deducted_cents, owner_fees_outstanding_cents, late_fees_cents,
      insurer_billed_cents, insurer_collected_cents, refunds_cents, chargebacks_cents, uncollected_cents,
      pass_through_in_cents, pass_through_out_cents, company_paid_tolls_cents,
      claim_money_in_cents, repairs_out_cents, claim_balance_cents, claim_surplus_cents, deposits_held_cents,
      hst_collected_cents, hst_refunded_cents, hst_paid_cents, processing_fees_cents, expenses_cents,
      cash_collected_cents, cash_refunded_cents)
  with lines as (select * from app.company_month_lines(m0)),
  veh as (
    select v.id, v.owner_id, coalesce(v.fleet_number, v.plate) as label, v.management_mode::text as mode, v.billing_case
      from vehicles v
     where (v.enrollment_date is not null and v.enrollment_date < m1 and coalesce(app.vehicle_fee_end(v.id), m0) >= m0)
        or v.id in (select s.vehicle_id from booking_splits s where s.payout_month = m0)
        or v.id in (select l.vehicle_id from lines l)
        or v.id in (select t.vehicle_id from turo_trips t where t.statement_month = m0)
        or v.id in (select e.vehicle_id from company_expenses e where e.expense_on >= m0 and e.expense_on < m1 and e.voided_at is null and e.vehicle_id is not null)
        or v.id in (select tt.vehicle_id from toll_tickets tt where tt.paid_by_company_at >= t0 and tt.paid_by_company_at < t1 and tt.vehicle_id is not null)
        or v.id in (select bk.vehicle_id from payments p join bookings bk on bk.id = p.booking_id
                     where p.status = 'succeeded' and p.processed_at >= t0 and p.processed_at < t1))
  select v_id, 'vehicle', veh.id, veh.owner_id, veh.label, veh.mode, veh.billing_case,
         d.in_program, greatest(d.in_program - d.blocked, 0), d.rented, d.owner_days, s.rentals, s.bdays,
         s.rental, s.mileage, s.kick, s.orev, s.share, s.opay,
         ln.disc, ln.disc_owner, ln.disc - ln.disc_owner, ln.fees,
         coalesce((select jsonb_object_agg(y.charge_type, y.amt) from (select l.charge_type, sum(l.net_cents) as amt from lines l
                    where l.vehicle_id = veh.id and l.revenue_class = 'company_only' group by l.charge_type) y), '{}'::jsonb),
         tr.gross, tr.fees, tr.share, tr.extras, tr.owner,
         oi.insurance, oi.tracker, oi.install, oi.other, oi.prepaid, oi.hst, oi.paid, oi.deducted, oi.outstanding, oi.late,
         ins.billed, ins.collected, rf.refunds, s.chargebacks, s.uncollected,
         ln.pass_in, tl.paid_out, tl.company_paid,
         cl.money_in, cl.repairs_out, cl.balance, cl.surplus, dp.held,
         ln.hst + oi.hst, ln.hst_ref, ex.hst, pf.fees, ex.amount,
         cash.collected, cash.refunded
    from veh
    cross join lateral app.vehicle_month_days(veh.id, m0) d
    cross join lateral (
      select count(*) filter (where b.status in ('returned', 'closed')) as rentals,
             coalesce(sum(coalesce(sp.segment_days, b.billable_days)) filter (where b.status in ('returned', 'closed')), 0)::integer as bdays,
             coalesce(sum(sp.rental_charge_cents), 0) as rental, coalesce(sum(sp.mileage_overage_cents), 0) as mileage,
             coalesce(sum(sp.kickback_cents), 0) as kick, coalesce(sum(sp.owner_revenue_cents), 0) as orev,
             coalesce(sum(sp.company_share_cents), 0) as share, coalesce(sum(sp.owner_payout_cents), 0) as opay,
             coalesce(sum(sp.chargeback_cents), 0) as chargebacks, coalesce(sum(sp.uncollected_cents), 0) as uncollected
        from booking_splits sp join bookings b on b.id = sp.booking_id
       where sp.vehicle_id = veh.id and sp.payout_month = m0 and sp.status <> 'reversed') s
    cross join lateral (
      select coalesce(sum(l.net_cents) filter (where l.revenue_class = 'company_only'), 0) as fees,
             coalesce(sum(l.net_cents) filter (where l.revenue_class = 'pass_through'), 0) as pass_in,
             coalesce(sum(l.hst_cents), 0) as hst, coalesce(sum(l.refunded_hst_cents), 0) as hst_ref,
             coalesce(-sum(l.amount_cents) filter (where l.charge_type in ('non_refundable_discount', 'staff_discount', 'promo_discount')), 0) as disc,
             coalesce(sum(public.calc_bps(-l.amount_cents, 10000 - coalesce(l.company_share_bps, 0)))
                        filter (where l.charge_type in ('non_refundable_discount', 'staff_discount', 'promo_discount')), 0) as disc_owner
        from lines l where l.vehicle_id = veh.id) ln
    cross join lateral (
      select coalesce(sum(t.gross_cents), 0) as gross, coalesce(sum(t.turo_fees_cents), 0) as fees,
             coalesce(sum(t.revenue_share_cents), 0) as share, coalesce(sum(t.company_extras_cents), 0) as extras,
             coalesce(sum(t.owner_payout_cents), 0) as owner
        from turo_trips t where t.vehicle_id = veh.id and t.statement_month = m0 and t.received_at is not null) tr
    cross join lateral (
      select coalesce(sum(il.amount_cents) filter (where il.kind in ('insurance_fee', 'first_month_insurance', 'prepaid_credit')), 0) as insurance,
             coalesce(sum(il.amount_cents) filter (where il.kind = 'tracker_fee'), 0) as tracker,
             coalesce(sum(il.amount_cents) filter (where il.kind = 'install_fee'), 0) as install,
             coalesce(sum(il.amount_cents) filter (where il.kind = 'adjustment'), 0) as other,
             coalesce(sum(il.amount_cents) filter (where il.kind = 'last_month_insurance'), 0) as prepaid,
             coalesce(sum(il.amount_cents) filter (where il.kind = 'late_fee'), 0) as late,
             coalesce((select sum(i.hst_cents) from owner_invoices i where i.vehicle_id = veh.id and i.status not in ('draft', 'void')
                         and ((i.kind = 'monthly' and i.period_month = m0) or (i.kind <> 'monthly' and i.billing_date >= m0 and i.billing_date < m1))), 0) as hst,
             coalesce((select sum(i.paid_cents) from owner_invoices i where i.vehicle_id = veh.id and i.status not in ('draft', 'void')
                         and ((i.kind = 'monthly' and i.period_month = m0) or (i.kind <> 'monthly' and i.billing_date >= m0 and i.billing_date < m1))), 0) as paid,
             coalesce((select sum(i.deducted_cents) from owner_invoices i where i.vehicle_id = veh.id and i.status not in ('draft', 'void')
                         and ((i.kind = 'monthly' and i.period_month = m0) or (i.kind <> 'monthly' and i.billing_date >= m0 and i.billing_date < m1))), 0) as deducted,
             coalesce((select sum(i.balance_cents) from owner_invoices i where i.vehicle_id = veh.id and i.status not in ('draft', 'void')
                         and ((i.kind = 'monthly' and i.period_month = m0) or (i.kind <> 'monthly' and i.billing_date >= m0 and i.billing_date < m1))), 0) as outstanding
        from owner_invoice_lines il join owner_invoices i on i.id = il.owner_invoice_id
       where i.vehicle_id = veh.id and i.status not in ('draft', 'void')
         and ((i.kind = 'monthly' and i.period_month = m0) or (i.kind <> 'monthly' and i.billing_date >= m0 and i.billing_date < m1))) oi
    cross join lateral (
      select coalesce(sum(ii.total_cents), 0) as billed, coalesce(sum(ii.paid_cents), 0) as collected
        from insurer_invoices ii join bookings b on b.id = ii.booking_id
       where b.vehicle_id = veh.id and ii.status <> 'draft' and ii.sent_at >= t0 and ii.sent_at < t1) ins
    cross join lateral (
      select coalesce(sum(r.amount_cents), 0) as refunds from refunds r join bookings b on b.id = r.booking_id
       where b.vehicle_id = veh.id and r.status = 'paid' and r.paid_at >= t0 and r.paid_at < t1) rf
    cross join lateral (
      select coalesce(sum(tt.amount_cents), 0) as paid_out, coalesce(sum(tt.amount_cents) filter (where tt.status = 'company_paid'), 0) as company_paid
        from toll_tickets tt where tt.vehicle_id = veh.id and tt.paid_by_company_at >= t0 and tt.paid_by_company_at < t1) tl
    cross join lateral (
      select coalesce(sum(e.amount_cents) filter (where e.direction = 'in' and e.entry_date >= m0 and e.entry_date < m1), 0) as money_in,
             coalesce(sum(e.amount_cents) filter (where e.direction = 'out' and e.entry_date >= m0 and e.entry_date < m1
                                                    and e.kind in ('repair', 'policy_deductible', 'towing', 'storage', 'appraisal', 'other_claim_cost')), 0) as repairs_out,
             coalesce(sum(case when e.direction = 'in' then e.amount_cents else -e.amount_cents end)
                        filter (where cm.status not in ('closed', 'withdrawn')), 0) as balance,
             coalesce((select sum(c2.company_result_cents) from claims c2 where c2.vehicle_id = veh.id and c2.settled_at >= t0 and c2.settled_at < t1), 0) as surplus
        from claims cm left join claim_ledger_entries e on e.claim_id = cm.id
       where cm.vehicle_id = veh.id) cl
    cross join lateral (
      select coalesce(sum(greatest(case when dd.method = 'charged' then dd.amount_cents else dd.captured_cents end - dd.applied_cents - dd.released_cents, 0)), 0) as held
        from deposits dd join bookings b on b.id = dd.booking_id
       where b.vehicle_id = veh.id and dd.status in ('held', 'captured')) dp
    cross join lateral (
      select coalesce(sum(e.amount_cents), 0) as amount, coalesce(sum(e.hst_cents), 0) as hst
        from company_expenses e where e.vehicle_id = veh.id and e.voided_at is null and e.expense_on >= m0 and e.expense_on < m1) ex
    cross join lateral (
      select coalesce(sum(pd.processor_fee_cents), 0) as fees
        from payments p join payment_processor_details pd on pd.payment_id = p.id
        left join bookings b on b.id = p.booking_id left join owner_invoices i on i.id = p.owner_invoice_id
       where coalesce(b.vehicle_id, i.vehicle_id) = veh.id and p.processed_at >= t0 and p.processed_at < t1) pf
    cross join lateral (
      select coalesce(sum(p.amount_cents) filter (where p.kind in ('charge', 'capture')), 0) as collected,
             coalesce(sum(p.amount_cents) filter (where p.kind = 'refund'), 0) as refunded
        from payments p left join bookings b on b.id = p.booking_id left join owner_invoices i on i.id = p.owner_invoice_id
       where coalesce(b.vehicle_id, i.vehicle_id) = veh.id and p.status = 'succeeded' and p.processed_at >= t0 and p.processed_at < t1) cash;

  -- ---- owner level: the vehicles summed, plus what belongs to the Owner as a whole
  select string_agg(format('coalesce(sum(l.%1$I), 0)', col), ', ') into v_sums from unnest(v_cols) col;
  execute format($f$
    insert into company_statement_lines (statement_id, level, owner_id, label, %1$s)
    select $1, 'owner', o.id, o.legal_name, %2$s
      from owners o left join company_statement_lines l on l.statement_id = $1 and l.level = 'vehicle' and l.owner_id = o.id
     where o.id in (select owner_id from company_statement_lines where statement_id = $1 and level = 'vehicle')
        or o.id in (select owner_id from owner_statements where statement_month = $2 and status <> 'void')
        or o.id in (select owner_id from payouts where owner_id is not null and status = 'paid' and paid_at >= $3 and paid_at < $4)
        or o.id in (select owner_id from company_expenses where owner_id is not null and vehicle_id is null and voided_at is null
                      and expense_on >= $2 and expense_on < $5)
     group by o.id, o.legal_name$f$, array_to_string(v_cols, ', '), v_sums)
  using v_id, m0, t0, t1, m1;
  update company_statement_lines l
     set owner_payout_cents = coalesce(st.payout_cents, 0), owner_deductions_cents = coalesce(st.deductions_cents, 0),
         kickbacks_earned_cents = coalesce(st.kickbacks_earned_cents, 0),
         hst_paid_cents = l.hst_paid_cents + coalesce(st.hst_on_payout_cents, 0) + coalesce(oe.hst, 0),
         expenses_cents = l.expenses_cents + coalesce(oe.amount, 0),
         cash_paid_out_cents = coalesce((select sum(p.amount_cents) from payouts p where p.owner_id = l.owner_id and p.status = 'paid'
                                           and p.paid_at >= t0 and p.paid_at < t1), 0)
    from (select o.id from owners o) oo
    left join owner_statements st on st.owner_id = oo.id and st.statement_month = m0 and st.status <> 'void'
    left join lateral (select sum(e.amount_cents) as amount, sum(e.hst_cents) as hst from company_expenses e
                        where e.owner_id = oo.id and e.vehicle_id is null and e.voided_at is null and e.expense_on >= m0 and e.expense_on < m1) oe on true
   where l.statement_id = v_id and l.level = 'owner' and l.owner_id = oo.id;

  -- ---- total: the owners summed, plus what belongs to no Owner
  execute format($f$
    insert into company_statement_lines (statement_id, level, label, %1$s)
    select $1, 'total', 'Total', %2$s from company_statement_lines l where l.statement_id = $1 and l.level = 'owner'$f$,
    array_to_string(v_cols, ', '), v_sums)
  using v_id;
  update company_statement_lines l
     set investor_returns_cents = coalesce((select sum(r.return_cents) from investment_returns r where r.return_month = m0), 0),
         expenses_cents = l.expenses_cents + coalesce((select sum(e.amount_cents) from company_expenses e where e.vehicle_id is null and e.owner_id is null
                                                        and e.voided_at is null and e.expense_on >= m0 and e.expense_on < m1), 0),
         hst_paid_cents = l.hst_paid_cents + coalesce((select sum(e.hst_cents) from company_expenses e where e.vehicle_id is null and e.owner_id is null
                                                        and e.voided_at is null and e.expense_on >= m0 and e.expense_on < m1), 0),
         cash_paid_out_cents = l.cash_paid_out_cents + coalesce((select sum(p.amount_cents) from payouts p where p.payee_type <> 'owner' and p.status = 'paid'
                                                                   and p.paid_at >= t0 and p.paid_at < t1), 0),
         cash_collected_cents = l.cash_collected_cents + coalesce((select sum(p.amount_cents) from payments p
                                   where p.status = 'succeeded' and p.kind in ('charge', 'capture') and p.processed_at >= t0 and p.processed_at < t1
                                     and p.booking_id is null and p.owner_invoice_id is null), 0)
   where l.statement_id = v_id and l.level = 'total';

  -- ---- derived figures on every line
  update company_statement_lines l
     set company_fees_by_type = case when l.level = 'vehicle' then l.company_fees_by_type else coalesce((
           select jsonb_object_agg(k, s) from (select e.key as k, sum(e.value::bigint) as s
             from company_statement_lines x, jsonb_each_text(x.company_fees_by_type) e
            where x.statement_id = v_id and x.level = 'vehicle' and (l.level = 'total' or x.owner_id = l.owner_id) group by e.key) z), '{}'::jsonb) end,
         company_net_cents = l.revenue_share_cents + l.turo_revenue_share_cents + l.turo_extras_cents + l.company_fees_cents
                           + l.insurance_fees_cents + l.tracker_fees_cents + l.install_fees_cents + l.other_owner_fees_cents + l.late_fees_cents
                           + l.claim_surplus_cents - l.processing_fees_cents - l.company_paid_tolls_cents - l.expenses_cents - l.investor_returns_cents,
         utilization_bps = case when l.days_available > 0 then round(l.days_rented / l.days_available * 10000) else 0 end,
         avg_daily_rate_cents = case when l.billable_days > 0 then round(l.rental_revenue_cents::numeric / l.billable_days) else 0 end,
         revpad_cents = case when l.days_available > 0 then round(l.rental_revenue_cents / l.days_available) else 0 end
   where l.statement_id = v_id;

  -- ---- reconciliation
  -- 1 and 2: vehicles sum to owners, owners sum to the total (columns the owner and total levels do not add to)
  for c in select unnest(array['rental_revenue_cents', 'revenue_share_cents', 'owner_share_out_cents', 'company_fees_cents',
                               'pass_through_in_cents', 'insurance_fees_cents', 'late_fees_cents', 'refunds_cents', 'turo_revenue_share_cents']) as col
  loop
    execute format('select coalesce(sum(%1$I) filter (where level = ''vehicle''), 0), coalesce(sum(%1$I) filter (where level = ''owner''), 0),
                           coalesce(sum(%1$I) filter (where level = ''total''), 0) from company_statement_lines where statement_id = $1', c.col)
      into v_a, v_b, v_n using v_id;
    v_checks := v_checks || jsonb_build_object('check', 'vehicles_owners_total:' || c.col, 'vehicles', v_a, 'owners', v_b, 'total', v_n,
                                               'difference_cents', greatest(abs(v_a - v_b), abs(v_b - v_n)), 'ok', v_a = v_b and v_b = v_n);
    if not (v_a = v_b and v_b = v_n) then
      v_problems := v_problems || format('%s: vehicles %s, owners %s, total %s', c.col, v_a, v_b, v_n);
    end if;
  end loop;
  -- 3: the total against the source tables directly
  select coalesce(sum(rental_charge_cents), 0) into v_a from booking_splits where payout_month = m0 and status <> 'reversed';
  select rental_revenue_cents into v_b from company_statement_lines where statement_id = v_id and level = 'total';
  v_checks := v_checks || jsonb_build_object('check', 'rental_revenue_against_splits', 'expected', v_a, 'got', v_b, 'difference_cents', v_b - v_a, 'ok', v_a = v_b);
  if v_a <> v_b then v_problems := v_problems || format('rental revenue: splits %s, statement %s (difference %s)', v_a, v_b, v_b - v_a); end if;
  select coalesce(sum(net_cents) filter (where revenue_class = 'company_only'), 0) into v_a from app.company_month_lines(m0);
  select company_fees_cents into v_b from company_statement_lines where statement_id = v_id and level = 'total';
  v_checks := v_checks || jsonb_build_object('check', 'company_fees_against_lines', 'expected', v_a, 'got', v_b, 'difference_cents', v_b - v_a, 'ok', v_a = v_b);
  if v_a <> v_b then v_problems := v_problems || format('company fees: lines %s, statement %s (difference %s)', v_a, v_b, v_b - v_a); end if;
  -- 4: money in: every payment of the month is tied to a vehicle's booking or invoice
  select coalesce(sum(amount_cents), 0), count(*) into v_a, v_n from payments
   where status = 'succeeded' and kind in ('charge', 'capture') and processed_at >= t0 and processed_at < t1;
  select coalesce(sum(cash_collected_cents), 0) into v_b from company_statement_lines where statement_id = v_id and level = 'vehicle';
  v_checks := v_checks || jsonb_build_object('check', 'payments_against_vehicles', 'expected', v_a, 'got', v_b, 'difference_cents', v_a - v_b, 'ok', v_a = v_b);
  if v_a <> v_b then
    v_problems := v_problems || format('payments: %s collected in the month, %s tied to a vehicle; %s not tied to a booking or an owner invoice', v_a, v_b, v_a - v_b);
  end if;
  -- 5: refunds approved and paid against the refund payments made
  select coalesce(sum(amount_cents), 0) into v_a from refunds where status = 'paid' and paid_at >= t0 and paid_at < t1;
  select coalesce(sum(amount_cents), 0) into v_b from payments
   where status = 'succeeded' and kind = 'refund' and purpose <> 'deposit' and processed_at >= t0 and processed_at < t1;
  v_checks := v_checks || jsonb_build_object('check', 'refunds_against_refund_payments', 'expected', v_a, 'got', v_b, 'difference_cents', v_a - v_b, 'ok', v_a = v_b);
  if v_a <> v_b then v_problems := v_problems || format('refunds: %s recorded as paid, %s refunded by the processor (difference %s)', v_a, v_b, v_a - v_b); end if;
  -- 6: owner payouts paid in the month against their statements, and against the owner level
  select coalesce(sum(p.amount_cents), 0), coalesce(sum(st.payout_cents), 0) into v_a, v_b
    from payouts p join owner_statements st on st.id = p.owner_statement_id
   where p.status = 'paid' and p.paid_at >= t0 and p.paid_at < t1;
  v_checks := v_checks || jsonb_build_object('check', 'statement_payouts', 'expected', v_b, 'got', v_a, 'difference_cents', v_a - v_b, 'ok', v_a = v_b);
  if v_a <> v_b then v_problems := v_problems || format('owner payouts: %s paid, statements say %s (difference %s)', v_a, v_b, v_a - v_b); end if;
  select coalesce(sum(amount_cents), 0) into v_a from payouts where payee_type = 'owner' and status = 'paid' and paid_at >= t0 and paid_at < t1;
  select coalesce(sum(cash_paid_out_cents), 0) into v_b from company_statement_lines where statement_id = v_id and level = 'owner';
  v_checks := v_checks || jsonb_build_object('check', 'owner_payouts_against_owners', 'expected', v_a, 'got', v_b, 'difference_cents', v_a - v_b, 'ok', v_a = v_b);
  if v_a <> v_b then v_problems := v_problems || format('payouts to Owners: %s paid, %s on the owner lines', v_a, v_b); end if;

  update company_statements
     set checks = v_checks, ties_ok = cardinality(v_problems) = 0,
         tie_problems = case when cardinality(v_problems) > 0 then array_to_string(v_problems, '; ') end
   where id = v_id;
  if cardinality(v_problems) > 0 then
    perform app.raise_task(p_type => 'company_statement_tie',
        p_title => format('The %s company statement does not reconcile', to_char(m0, 'FMMonth YYYY')),
        p_detail => array_to_string(v_problems, '; '), p_related_table => 'company_statements', p_related_id => v_id,
        p_dedupe => 'company_statement_tie:' || v_id, p_created_by => p_by);
  else
    update tasks set status = 'done', completed_at = now(), completion_note = 'Reconciles after a rebuild'
     where related_table = 'company_statements' and related_id = v_id and task_type = 'company_statement_tie'
       and status in ('open', 'in_progress', 'waiting');
  end if;
  return v_id;
end $function$;

-- price_lines
create or replace function app.price_lines(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
declare
  v_type text := coalesce(p ->> 'booking_type', 'standard');
  v_pickup timestamptz := (p ->> 'pickup_at')::timestamptz;
  v_return timestamptz := (p ->> 'return_at')::timestamptz;
  v_hst integer := coalesce((p ->> 'hst_bps')::integer, 0);
  v_daily bigint := coalesce((p ->> 'daily_rate_cents')::bigint, 0);
  v_weekend bigint := coalesce((p ->> 'weekend_rate_cents')::bigint, 0);
  v_weekly bigint := coalesce((p ->> 'weekly_rate_cents')::bigint, 0);
  v_monthly bigint := coalesce((p ->> 'monthly_rate_cents')::bigint, 0);
  v_days integer;
  r record;
  v_uncapped bigint;
  v_capped boolean := false;
  v_rule text;
  v_rental bigint;
  v_discount bigint := 0;
  v_staff bigint := 0;
  v_promo bigint := 0;
  v_lines jsonb := '[]'::jsonb;
  d jsonb;
  t jsonb;
  v_code text;
  v_rate bigint;
  v_cap bigint;
  v_amt bigint;
  n integer;
  v_sub bigint;
  v_tax bigint;
begin
  if v_pickup is null or v_return is null or v_return <= v_pickup then
    raise exception 'The return must be after the pickup' using errcode = '22023';
  end if;
  v_days := public.calc_billable_days(v_pickup, v_return);
  -- (also refuses a length outside 1 to 30 days)
  select * into r from public.calc_rental_charge(v_pickup, v_days, v_daily, v_weekend, v_weekly, v_monthly);

  if v_type = 'owner' then
    -- an Owner Booking has no rental charge, fee or Deposit
    return jsonb_build_object('billable_days', v_days, 'rate_applied', 'none', 'daily_days', r.daily_days, 'weekend_days', r.weekend_days,
      'rate_rule', 'Owner Booking: nothing to pay', 'rate_capped', false, 'rental_charge_cents', 0,
      'non_refundable_discount_cents', 0, 'staff_discount_cents', 0, 'promo_discount_cents', 0,
      'lines', '[]'::jsonb, 'subtotal_cents', 0, 'hst_bps', v_hst, 'hst_cents', 0, 'total_cents', 0);
  end if;

  -- which rate applied, and whether its cap did (renter billing specification section 2)
  if r.rate_applied = 'daily' then
    v_uncapped := r.daily_days * v_daily + r.weekend_days * v_weekend;
    v_capped := v_uncapped > v_weekly;
    v_rule := concat_ws(' and ',
                case when r.daily_days > 0 then format('%s day%s at the daily rate', r.daily_days, case when r.daily_days = 1 then '' else 's' end) end,
                case when r.weekend_days > 0 then format('%s day%s at the weekend rate', r.weekend_days, case when r.weekend_days = 1 then '' else 's' end) end)
              || case when v_capped then ', capped at the weekly rate' else '' end;
  elsif r.rate_applied = 'weekly' then
    v_uncapped := round(v_weekly::numeric * v_days / 7)::bigint;
    v_capped := v_uncapped > v_monthly;
    v_rule := format('weekly rate divided by 7, times %s days', v_days) || case when v_capped then ', capped at the monthly rate' else '' end;
  else
    v_uncapped := v_monthly;
    v_rule := 'monthly rate';
  end if;

  v_rental := coalesce((p ->> 'rental_charge_cents')::bigint, r.rental_charge_cents);
  if (p ->> 'rental_charge_cents') is not null and v_rental <> r.rental_charge_cents then
    v_rule := 'rental charge set for this booking';
    v_capped := false;
  end if;
  if v_type = 'non_refundable' then
    v_discount := public.calc_bps(v_rental, coalesce((p ->> 'non_refundable_discount_bps')::integer, 0));
  end if;
  v_staff := coalesce((p ->> 'staff_discount_cents')::bigint, 0);
  if (p ->> 'promo_code_id') is not null then
    v_promo := coalesce(app.promo_discount_cents((p ->> 'promo_code_id')::uuid, v_rental - v_discount - v_staff), 0);
  end if;

  if v_rental <> 0 then
    v_lines := v_lines || app.price_line('rental_charge', 1, v_rental, v_rental, v_hst, null, null,
      jsonb_build_object('rate_applied', r.rate_applied, 'rate_rule', v_rule, 'capped', v_capped, 'billable_days', v_days,
                         'daily_days', r.daily_days, 'weekend_days', r.weekend_days));
  end if;
  if v_discount <> 0 then
    v_lines := v_lines || app.price_line('non_refundable_discount', 1, -v_discount, -v_discount, v_hst);
  end if;
  if v_staff <> 0 then
    v_lines := v_lines || app.price_line('staff_discount', 1, -v_staff, -v_staff, v_hst);
  end if;
  if v_promo <> 0 then
    v_lines := v_lines || app.price_line('promo_discount', 1, -v_promo, -v_promo, v_hst);
  end if;
  v_amt := coalesce((p ->> 'delivery_fee_cents')::bigint, 0);
  if v_amt <> 0 then
    v_lines := v_lines || app.price_line('delivery', 1, v_amt, v_amt, v_hst, null, null, p -> 'delivery_detail');
  end if;
  v_amt := coalesce((p ->> 'pickup_fee_cents')::bigint, 0);
  if v_amt <> 0 then
    v_lines := v_lines || app.price_line('pickup', 1, v_amt, v_amt, v_hst, null, null, p -> 'pickup_detail');
  end if;

  if coalesce((p ->> 'managed')::boolean, false) then
    -- per driver: the young driver fee of their age band, and the additional driver fee;
    -- each is per day up to its cap per rental
    for d in select value from jsonb_array_elements(coalesce(p -> 'drivers', '[]'::jsonb)) loop
      if d ->> 'age_band' in ('18_to_20', '21_to_25') then
        v_code := case d ->> 'age_band' when '18_to_20' then 'young_driver_18_20' else 'young_driver_21_25' end;
        t := p -> 'fee_terms' -> v_code;
        v_rate := app.fee_per_day(t, v_daily);
        v_cap := (t ->> 'cap_cents')::bigint;
        if coalesce(v_rate, 0) > 0 then
          v_amt := public.calc_capped_per_day(v_rate, v_days, v_cap);
          v_lines := v_lines || app.price_line(v_code, v_days, v_rate, v_amt, v_hst,
            (select f.label || coalesce(': ' || nullif(d ->> 'name', ''), '') from fee_types f where f.code = v_code),
            (d ->> 'driver_id')::uuid,
            jsonb_build_object('driver_name', d ->> 'name', 'age_band', d ->> 'age_band', 'per_day_cents', v_rate, 'cap_cents', v_cap,
                               'capped', v_amt < v_rate * v_days));
        end if;
      end if;
      if d ->> 'role' = 'additional' then
        t := p -> 'fee_terms' -> 'additional_driver';
        v_rate := app.fee_per_day(t, v_daily);
        v_cap := (t ->> 'cap_cents')::bigint;
        if coalesce(v_rate, 0) > 0 then
          v_amt := public.calc_capped_per_day(v_rate, v_days, v_cap);
          v_lines := v_lines || app.price_line('additional_driver', v_days, v_rate, v_amt, v_hst,
            (select f.label || coalesce(': ' || nullif(d ->> 'name', ''), '') from fee_types f where f.code = 'additional_driver'),
            (d ->> 'driver_id')::uuid,
            jsonb_build_object('driver_name', d ->> 'name', 'per_day_cents', v_rate, 'cap_cents', v_cap, 'capped', v_amt < v_rate * v_days));
        end if;
      end if;
    end loop;
    -- extras
    if coalesce((p -> 'extras' ->> 'winter_tire')::boolean, false) then
      t := p -> 'fee_terms' -> 'winter_tire';
      v_rate := app.fee_per_day(t, v_daily);
      v_cap := (t ->> 'cap_cents')::bigint;
      if coalesce(v_rate, 0) > 0 then
        v_amt := public.calc_capped_per_day(v_rate, v_days, v_cap);
        v_lines := v_lines || app.price_line('winter_tire', v_days, v_rate, v_amt, v_hst, null, null,
          jsonb_build_object('per_day_cents', v_rate, 'cap_cents', v_cap, 'capped', v_amt < v_rate * v_days));
      end if;
    end if;
    n := coalesce((p -> 'extras' ->> 'baby_seats')::integer, 0);
    if n > 0 then
      t := p -> 'fee_terms' -> 'baby_seat';
      v_rate := app.fee_per_day(t, v_daily);
      v_cap := (t ->> 'cap_cents')::bigint;
      if coalesce(v_rate, 0) > 0 then
        v_amt := public.calc_capped_per_day(v_rate, v_days, v_cap, n);
        v_lines := v_lines || app.price_line('baby_seat', n, public.calc_capped_per_day(v_rate, v_days, v_cap), v_amt, v_hst, null, null,
          jsonb_build_object('seats', n, 'per_day_cents', v_rate, 'cap_cents', v_cap, 'capped', v_amt < v_rate * v_days * n));
      end if;
    end if;
    -- coverage bought through CarmaCars: a line only once an Admin has set its price
    -- 0025: its price is set per booking (a staff term), else the default table by car and the
    -- renter's age band (app.coverage_term); per day or for the booking; no line until priced
    if (p ->> 'coverage_option') = '3' then
      t := p -> 'fee_terms' -> 'coverage_sold';
      v_rate := app.fee_per_day(t, v_daily);
      if coalesce(v_rate, 0) > 0 then
        if coalesce((t ->> 'per_day')::boolean, false) then
          v_lines := v_lines || app.price_line('coverage_sold', v_days, v_rate, v_rate * v_days, v_hst, null, null,
            jsonb_build_object('per_day_cents', v_rate, 'source', t ->> 'source'));
        else
          v_lines := v_lines || app.price_line('coverage_sold', 1, v_rate, v_rate, v_hst, null, null,
            jsonb_build_object('source', t ->> 'source'));
        end if;
      end if;
    end if;
  end if;

  select coalesce(jsonb_agg(x.value order by (x.value ->> 'sort_order')::integer, x.ord), '[]'::jsonb),
         coalesce(sum((x.value ->> 'amount_cents')::bigint), 0), coalesce(sum((x.value ->> 'hst_cents')::bigint), 0)
    into v_lines, v_sub, v_tax
    from jsonb_array_elements(v_lines) with ordinality x(value, ord);

  return jsonb_build_object('billable_days', v_days, 'rate_applied', r.rate_applied, 'daily_days', r.daily_days, 'weekend_days', r.weekend_days,
    'rate_rule', v_rule, 'rate_capped', v_capped, 'rental_charge_cents', v_rental,
    'non_refundable_discount_cents', v_discount, 'staff_discount_cents', v_staff, 'promo_discount_cents', v_promo,
    'lines', v_lines, 'subtotal_cents', v_sub, 'hst_bps', v_hst, 'hst_cents', v_tax, 'total_cents', v_sub + v_tax);
end $function$;

-- price_quote
create or replace function app.price_quote(p_vehicle uuid, p_pickup timestamp with time zone, p_return timestamp with time zone, p_options jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
declare
  o jsonb := coalesce(p_options, '{}'::jsonb);
  v vehicles;
  rc rate_cards;
  v_set program_settings := app.settings();
  v_type text := coalesce(o ->> 'booking_type', 'standard');
  v_on date := app.local_date(p_pickup);
  v_drivers jsonb := '[]'::jsonb;
  v_problems jsonb := '[]'::jsonb;
  d jsonb;
  i integer := 0;
  v_age integer;
  v_band text;
  v_role text;
  v_additional integer := 0;
  v_terms jsonb;
  v_promo_id uuid;
  v_promo_problem text;
  v_cover integer := (o ->> 'coverage_option')::integer;
  v_cover_price bigint;
  v_seats integer := coalesce((o -> 'extras' ->> 'baby_seats')::integer, 0);
  v_out jsonb;
  v_days integer;
  v_cover_term jsonb;
  v_delivery jsonb;
  v_return_fee jsonb;
begin
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then raise exception 'Vehicle not found' using errcode = '22023'; end if;
  if v_type not in ('standard', 'non_refundable') then
    raise exception 'A quote is for a standard or a non-refundable booking' using errcode = '22023';
  end if;
  select * into rc from rate_cards r
   where r.vehicle_id = p_vehicle and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now());
  if rc.id is null then raise exception 'This vehicle has no rates set' using errcode = '23514'; end if;

  for d in select value from jsonb_array_elements(case when jsonb_typeof(o -> 'drivers') = 'array' then o -> 'drivers' else '[]'::jsonb end) loop
    i := i + 1;
    v_role := coalesce(d ->> 'role', case when i = 1 then 'renter' else 'additional' end);
    v_age := case when (d ->> 'date_of_birth') is not null then app.age_on((d ->> 'date_of_birth')::date, v_on) else (d ->> 'age')::integer end;
    v_band := case when v_age is not null then app.age_band(v_age) else coalesce(d ->> 'age_band', '26_plus') end;
    if v_role = 'additional' then v_additional := v_additional + 1; end if;
    if v_age is not null and v_age < v_set.min_renter_age then
      v_problems := v_problems || jsonb_build_object('code', 'driver_under_minimum_age', 'driver', i,
        'message', format('Every driver must be %s or older at pickup.', v_set.min_renter_age));
    elsif v_band = '18_to_20' and not v.allows_18_to_20 then
      v_problems := v_problems || jsonb_build_object('code', 'vehicle_not_for_young_drivers', 'driver', i,
        'message', format('This car is for drivers %s and over.', v_set.standard_min_age));
    end if;
    v_drivers := v_drivers || jsonb_build_object('driver_id', d ->> 'driver_id', 'role', v_role, 'name', d ->> 'name', 'age', v_age, 'age_band', v_band);
  end loop;
  if i = 0 then
    v_drivers := jsonb_build_array(jsonb_build_object('role', 'renter', 'age_band', '26_plus', 'assumed', true));
  end if;
  if v_additional > v_set.max_additional_drivers then
    v_problems := v_problems || jsonb_build_object('code', 'too_many_additional_drivers',
      'message', format('A booking may name up to %s additional drivers.', v_set.max_additional_drivers));
  end if;
  if v_seats > v_set.max_baby_seats then
    v_problems := v_problems || jsonb_build_object('code', 'too_many_baby_seats',
      'message', format('A booking may ask for up to %s baby seats.', v_set.max_baby_seats));
  end if;
  if v.exit_date is not null and app.local_date(p_return) > v.exit_date then
    v_problems := v_problems || jsonb_build_object('code', 'vehicle_leaving', 'message', 'This car is not offered for the whole of these dates.');
  end if;

  select coalesce(jsonb_object_agg(c.code, jsonb_build_object('amount_cents', t.amount_cents, 'cap_cents', t.cap_cents, 'percent_bps', t.percent_bps, 'source', t.source)), '{}'::jsonb)
    into v_terms
    from unnest(array['young_driver_18_20', 'young_driver_21_25', 'additional_driver', 'winter_tire', 'baby_seat', 'coverage_sold']) c(code)
    cross join lateral app.fee_term(c.code, p_vehicle, app.today()) t;
  -- 0025: coverage through CarmaCars is sold; its default price comes from the table by car and
  -- the renter's age band, and when none applies the quote says it is priced in the offer
  v_cover_term := app.coverage_term(p_vehicle, coalesce(v_drivers -> 0 ->> 'age_band', '26_plus'), app.today(), v_terms -> 'coverage_sold');
  if v_cover_term is not null then
    v_terms := jsonb_set(v_terms, '{coverage_sold}', v_cover_term);
  end if;
  v_cover_price := app.fee_per_day(v_terms -> 'coverage_sold', rc.daily_rate_cents);
  v_delivery := app.delivery_fee(p_vehicle, 'pickup', case when o ->> 'pickup_method' = 'delivered' then coalesce(o -> 'pickup_location', '{}'::jsonb) else '{"kind": "our_location"}'::jsonb end);
  v_return_fee := app.delivery_fee(p_vehicle, 'return', case when o ->> 'return_method' = 'picked_up' then coalesce(o -> 'return_location', '{}'::jsonb) else '{"kind": "our_location"}'::jsonb end);

  if nullif(btrim(o ->> 'promo_code'), '') is not null then
    v_promo_problem := app.promo_code_problem(o ->> 'promo_code', app.my_renter_id());
    if v_promo_problem is null then
      select id into v_promo_id from promo_codes where code = upper(btrim(o ->> 'promo_code'));
    end if;
  end if;

  v_out := app.price_lines(jsonb_build_object(
    'vehicle_id', p_vehicle, 'pickup_at', p_pickup, 'return_at', p_return, 'booking_type', v_type, 'hst_bps', v_set.hst_bps,
    'daily_rate_cents', rc.daily_rate_cents, 'weekend_rate_cents', rc.weekend_rate_cents,
    'weekly_rate_cents', rc.weekly_rate_cents, 'monthly_rate_cents', rc.monthly_rate_cents,
    'non_refundable_discount_bps', v_set.non_refundable_discount_bps, 'promo_code_id', v_promo_id,
    'delivery_fee_cents', (v_delivery ->> 'fee_cents')::bigint, 'delivery_detail', v_delivery,
    'pickup_fee_cents', (v_return_fee ->> 'fee_cents')::bigint, 'pickup_detail', v_return_fee,
    'managed', true, 'drivers', v_drivers, 'extras', coalesce(o -> 'extras', '{}'::jsonb),
    'coverage_option', v_cover, 'fee_terms', v_terms));
  v_days := (v_out ->> 'billable_days')::integer;
  if v_days > v_set.max_rental_days then
    raise exception 'A rental transaction is 1 to % days; % requested. Longer stays renew with a new booking.', v_set.max_rental_days, v_days
      using errcode = '22023';
  end if;

  return (v_out - 'lines') || jsonb_build_object(
    'vehicle_id', p_vehicle, 'pickup_at', p_pickup, 'return_at', p_return, 'booking_type', v_type, 'currency', 'CAD',
    -- the visitor sees each line and its tax, not which part belongs to whom
    'lines', (select coalesce(jsonb_agg((x.value - 'revenue_class' - 'sort_order') order by x.ord), '[]'::jsonb)
                from jsonb_array_elements(v_out -> 'lines') with ordinality x(value, ord)),
    'rates', jsonb_build_object('rate_card_id', rc.id, 'daily_rate_cents', rc.daily_rate_cents, 'weekend_rate_cents', rc.weekend_rate_cents,
                                'weekly_rate_cents', rc.weekly_rate_cents, 'monthly_rate_cents', rc.monthly_rate_cents),
    'total_due_at_booking_cents', (v_out ->> 'total_cents')::bigint,
    'deposit_cents', rc.deposit_cents,
    'deposit_method', public.calc_deposit_method(v_days, v_set.deposit_hold_max_days),
    'km_allowance_per_day', rc.km_allowance_per_day, 'km_allowance_total', rc.km_allowance_per_day * v_days,
    'overage_cents_per_km', rc.overage_cents_per_km,
    'coverage', jsonb_build_object('option', v_cover, 'sold_by_carmacars_available', true,
                                   'sold_by_carmacars_price_cents', v_cover_price,
                                   'sold_by_carmacars_per_day', coalesce((v_terms -> 'coverage_sold' ->> 'per_day')::boolean, false),
                                   'priced_in_offer', coalesce(v_cover_price, 0) = 0,
                                   'price_note', case when coalesce(v_cover_price, 0) = 0 then 'Priced in your offer' end,
                                   'note', 'Proof of coverage is confirmed after booking and before pickup.'),
    'delivery', jsonb_build_object('pickup', v_delivery, 'return', v_return_fee),
    'promo', case when nullif(btrim(o ->> 'promo_code'), '') is not null
                  then jsonb_build_object('code', upper(btrim(o ->> 'promo_code')), 'applied', v_promo_id is not null, 'problem', v_promo_problem) end,
    'drivers', v_drivers,
    'available', app.vehicle_is_available(p_vehicle, p_pickup, p_return),
    'problems', v_problems);
end $function$;

-- booking_price_spec
create or replace function app.booking_price_spec(p_booking uuid, p_changes jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
declare
  b bookings;
  rc rate_cards;
  v_set program_settings;
  v_on date;
  v_vehicle uuid;
  v_pickup timestamptz;
  v_return timestamptz;
  v_delivery bigint;
  v_pickup_fee bigint;
  v_drivers jsonb;
  v_terms jsonb;
  v_ddet jsonb;
  v_pdet jsonb;
  v_cov jsonb;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  v_on := app.local_date(b.booked_at);
  v_set := app.settings(v_on);
  v_vehicle := coalesce((p_changes ->> 'vehicle_id')::uuid, b.vehicle_id);
  v_pickup := coalesce((p_changes ->> 'pickup_at')::timestamptz, b.pickup_at);
  v_return := coalesce((p_changes ->> 'return_at')::timestamptz, b.return_at);
  select * into rc from rate_cards r
   where r.vehicle_id = v_vehicle and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now());

  -- delivery and pickup: the fee already on the booking if there is one (staff may have set
  -- it), otherwise the rate card's; none when the booking does not call for it
  select li.amount_cents into v_delivery from booking_line_items li
   where li.booking_id = p_booking and li.charge_type = 'delivery' and li.stage = 'booking' and li.voided_at is null
   order by li.created_at, li.id limit 1;
  select li.amount_cents into v_pickup_fee from booking_line_items li
   where li.booking_id = p_booking and li.charge_type = 'pickup' and li.stage = 'booking' and li.voided_at is null
   order by li.created_at, li.id limit 1;
  v_delivery := case when b.pickup_method <> 'delivered' then 0 else coalesce(v_delivery, rc.delivery_fee_cents, 0) end;
  v_pickup_fee := case when b.return_method <> 'picked_up' then 0 else coalesce(v_pickup_fee, rc.pickup_fee_cents, 0) end;
  -- 0025: a delivery with its distance or an airport is priced by app.delivery_fee; an amount
  -- staff set for this booking (booking fee term) wins
  if b.pickup_method = 'delivered' and (b.pickup_distance_km is not null or b.pickup_airport_id is not null) then
    v_ddet := app.delivery_fee(v_vehicle, 'pickup', jsonb_build_object('kind', b.pickup_location_kind, 'distance_km', b.pickup_distance_km,
                                                                       'airport_id', b.pickup_airport_id));
    v_delivery := (v_ddet ->> 'fee_cents')::bigint;
  end if;
  if b.return_method = 'picked_up' and (b.return_distance_km is not null or b.return_airport_id is not null) then
    v_pdet := app.delivery_fee(v_vehicle, 'return', jsonb_build_object('kind', b.return_location_kind, 'distance_km', b.return_distance_km,
                                                                       'airport_id', b.return_airport_id));
    v_pickup_fee := (v_pdet ->> 'fee_cents')::bigint;
  end if;
  if b.pickup_method = 'delivered' then
    v_delivery := coalesce((select t.amount_cents from booking_fee_terms t where t.booking_id = p_booking and t.fee_type_code = 'delivery'), v_delivery);
  end if;
  if b.return_method = 'picked_up' then
    v_pickup_fee := coalesce((select t.amount_cents from booking_fee_terms t where t.booking_id = p_booking and t.fee_type_code = 'pickup'), v_pickup_fee);
  end if;
  v_delivery := coalesce(v_delivery, 0);
  v_pickup_fee := coalesce(v_pickup_fee, 0);

  select coalesce(jsonb_agg(jsonb_build_object('driver_id', d.driver_id, 'role', d.role, 'name', d.full_name,
                    'age_band', app.age_band(app.age_on(d.date_of_birth, app.local_date(v_pickup))))
                  order by d.role desc, d.full_name, d.id), '[]'::jsonb)
    into v_drivers from booking_drivers d where d.booking_id = p_booking;
  select coalesce(jsonb_object_agg(c.code, jsonb_build_object('amount_cents', t.amount_cents, 'cap_cents', t.cap_cents, 'percent_bps', t.percent_bps, 'source', t.source)), '{}'::jsonb)
    into v_terms
    from unnest(array['young_driver_18_20', 'young_driver_21_25', 'additional_driver', 'winter_tire', 'baby_seat', 'coverage_sold']) c(code)
    cross join lateral app.fee_term(c.code, v_vehicle, v_on, p_booking) t;
  -- coverage sold: the booking's own price, else the default table for the renter's age band
  if (v_terms -> 'coverage_sold' ->> 'amount_cents') is null then
    v_cov := app.coverage_term(v_vehicle,
               coalesce((select x ->> 'age_band' from jsonb_array_elements(v_drivers) x where x ->> 'role' = 'renter' limit 1), '26_plus'),
               v_on, v_terms -> 'coverage_sold');
    if v_cov is not null then v_terms := jsonb_set(v_terms, '{coverage_sold}', v_cov); end if;
  end if;

  return jsonb_build_object(
    'vehicle_id', v_vehicle, 'pickup_at', v_pickup, 'return_at', v_return, 'booking_type', b.booking_type, 'hst_bps', b.hst_bps,
    'daily_rate_cents', b.daily_rate_cents, 'weekend_rate_cents', b.weekend_rate_cents,
    'weekly_rate_cents', b.weekly_rate_cents, 'monthly_rate_cents', b.monthly_rate_cents,
    'rental_charge_cents', case when (p_changes ->> 'rental_charge_cents') is not null then (p_changes ->> 'rental_charge_cents')::bigint
                                when coalesce((p_changes ->> 'recompute_rental')::boolean, false) then null
                                when v_pickup = b.pickup_at and v_return = b.return_at then b.rental_charge_cents end,
    'non_refundable_discount_bps', v_set.non_refundable_discount_bps,
    'staff_discount_cents', b.staff_discount_cents, 'promo_code_id', b.promo_code_id,
    'delivery_fee_cents', v_delivery, 'pickup_fee_cents', v_pickup_fee, 'delivery_detail', v_ddet, 'pickup_detail', v_pdet,
    'managed', b.request_details is not null or coalesce((p_changes ->> 'managed')::boolean, false),
    'drivers', v_drivers, 'extras', coalesce(b.request_details -> 'extras', '{}'::jsonb),
    'coverage_option', b.coverage_option, 'fee_terms', v_terms);
end $function$;

-- submit_booking_request
create or replace function public.submit_booking_request(p_request jsonb, p_ip inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_user uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO 'public', 'app'
AS $function$
  select app.submit_booking_request(p_request, p_ip, p_user_agent, p_user)
$function$;

create or replace function app.submit_booking_request(p_request jsonb, p_ip inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_user uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
declare
  q jsonb := coalesce(p_request, '{}'::jsonb);
  r jsonb := coalesce(p_request -> 'renter', '{}'::jsonb);
  c jsonb := coalesce(p_request -> 'consents', '{}'::jsonb);
  v_set program_settings := app.settings();
  v_key text := btrim(coalesce(p_request ->> 'request_key', ''));
  b bookings;
  v vehicles;
  u users;
  rn renters;
  dr drivers;
  v_vehicle uuid := (p_request ->> 'vehicle_id')::uuid;
  v_pickup timestamptz := (p_request ->> 'pickup_at')::timestamptz;
  v_return timestamptz := (p_request ->> 'return_at')::timestamptz;
  v_type text := coalesce(p_request ->> 'booking_type', 'standard');
  v_pickup_method text := coalesce(p_request ->> 'pickup_method', 'collected');
  v_return_method text := coalesce(p_request ->> 'return_method', 'returned');
  v_note text := nullif(btrim(coalesce(p_request ->> 'note', '')), '');
  v_cover integer := (p_request ->> 'coverage_option')::integer;
  v_seats integer := coalesce((p_request -> 'extras' ->> 'baby_seats')::integer, 0);
  v_email text := lower(btrim(coalesce(p_request -> 'renter' ->> 'email', '')));
  v_name text := nullif(btrim(coalesce(p_request -> 'renter' ->> 'full_name', '')), '');
  v_mobile text := nullif(btrim(coalesce(p_request -> 'renter' ->> 'mobile', '')), '');
  v_dob date := (p_request -> 'renter' ->> 'date_of_birth')::date;
  v_class text := upper(nullif(btrim(coalesce(p_request -> 'renter' ->> 'licence_class', '')), ''));
  v_issuer text := nullif(btrim(coalesce(p_request -> 'renter' ->> 'licence_issuer', '')), '');
  v_on date;
  v_days integer;
  v_age integer;
  v_band text;
  v_new_account boolean := false;
  v_uid uuid;
  v_review boolean := false;
  v_differ boolean := false;
  v_conflict boolean;
  v_promo_problem text;
  v_booking uuid;
  v_adds jsonb := case when jsonb_typeof(p_request -> 'additional_drivers') = 'array' then p_request -> 'additional_drivers' else '[]'::jsonb end;
  a jsonb;
  v_a_name text; v_a_dob date; v_a_email text; v_a_class text; v_a_issuer text; v_a_age integer;
  v_driver uuid;
  v_drivers_kept jsonb := '[]'::jsonb;
  v_names text[] := '{}';
  v_details jsonb;
begin
  -- the key, and a second submit
  if length(v_key) not between 8 and 100 then
    raise exception 'A request needs its request key (8 to 100 characters)' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('carmacars:booking_request:' || v_key, 0));
  select * into b from bookings where request_key = v_key;
  if b.id is not null then
    return jsonb_build_object('ok', true, 'created', false, 'booking_id', b.id, 'booking_number', b.booking_number,
                              'status', b.status, 'renter_id', b.renter_id);
  end if;

  -- spam: so many requests an hour from one network address
  if p_ip is not null and not app.rate_limit('booking_request:ip:' || host(p_ip), v_set.booking_request_hourly_limit, interval '1 hour') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited',
                              'message', 'Too many requests from this connection. Please try again later or call us.');
  end if;

  -- the trip
  if v_vehicle is null or not exists (select 1 from public_vehicle_listings l where l.vehicle_id = v_vehicle) then
    raise exception 'This car is not available to book' using errcode = '23514';
  end if;
  select * into v from vehicles where id = v_vehicle;
  if v_pickup is null or v_return is null or v_return <= v_pickup then
    raise exception 'The return must be after the pickup' using errcode = '22023';
  end if;
  if v_pickup < now() + make_interval(mins => v_set.booking_min_notice_minutes) then
    raise exception 'The pickup must be at least % minutes from now', v_set.booking_min_notice_minutes using errcode = '22023';
  end if;
  v_days := public.calc_billable_days(v_pickup, v_return);
  if v_days > v_set.max_rental_days then
    raise exception 'A rental transaction is 1 to % days; % requested. Longer stays renew with a new booking.', v_set.max_rental_days, v_days
      using errcode = '22023';
  end if;
  if v_type not in ('standard', 'non_refundable') then
    raise exception 'A request is for a standard or a non-refundable booking' using errcode = '22023';
  end if;
  if v_pickup_method not in ('collected', 'delivered') or v_return_method not in ('returned', 'picked_up') then
    raise exception 'Unknown pickup or return method' using errcode = '22023';
  end if;
  if v_pickup_method = 'delivered' and nullif(btrim(coalesce(p_request ->> 'pickup_place', '')), '') is null then
    raise exception 'A delivery needs its address' using errcode = '22023';
  end if;
  if v_return_method = 'picked_up' and nullif(btrim(coalesce(p_request ->> 'return_place', '')), '') is null then
    raise exception 'A pickup at the end of the rental needs its address' using errcode = '22023';
  end if;
  if length(coalesce(v_note, '')) > v_set.request_note_max_chars then
    raise exception 'The note is too long (at most % characters)', v_set.request_note_max_chars using errcode = '22023';
  end if;
  if v_seats < 0 or v_seats > v_set.max_baby_seats then
    raise exception 'A booking may ask for up to % baby seats', v_set.max_baby_seats using errcode = '22023';
  end if;
  if v_cover is null or v_cover not in (1, 2, 3) then
    raise exception 'Choose how damage to the car will be covered (option 1, 2 or 3)' using errcode = '22023';
  end if;

  -- the consents that are a condition of asking
  if not coalesce((c -> 'terms' ->> 'accepted')::boolean, false) or nullif(c -> 'terms' ->> 'version', '') is null
     or nullif(c -> 'terms' ->> 'text', '') is null then
    raise exception 'The Terms of Use must be accepted, with the version and wording shown' using errcode = '22023';
  end if;
  if not coalesce((c -> 'privacy' ->> 'accepted')::boolean, false) or nullif(c -> 'privacy' ->> 'version', '') is null
     or nullif(c -> 'privacy' ->> 'text', '') is null then
    raise exception 'The Privacy Policy must be accepted, with the version and wording shown' using errcode = '22023';
  end if;
  if coalesce((c -> 'marketing' ->> 'opted_in')::boolean, false)
     and (nullif(c -> 'marketing' ->> 'version', '') is null or nullif(c -> 'marketing' ->> 'text', '') is null) then
    raise exception 'A marketing opt-in is recorded with the version and wording shown' using errcode = '22023';
  end if;

  -- who is asking (read only, so that a limit below can refuse with nothing written)
  if p_user is not null then
    select * into u from users where id = p_user;
    if u.id is null then raise exception 'Unknown user' using errcode = '22023'; end if;
  else
    if v_email = '' or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
      raise exception 'A valid email address is needed' using errcode = '22023';
    end if;
    select * into u from users where lower(email) = v_email;
  end if;
  if u.id is not null then
    if u.status not in ('active', 'invited') then
      raise exception 'We could not take this request online. Please contact us.' using errcode = '23514';
    end if;
    select * into rn from renters where user_id = u.id;
    if rn.id is not null then
      select * into dr from drivers where renter_id = rn.id and is_account_holder;
      if (select count(*) from bookings o where o.renter_id = rn.id and o.status in ('requested', 'offered', 'pending_payment'))
         >= v_set.booking_open_request_limit then
        return jsonb_build_object('ok', false, 'error', 'too_many_open_requests',
          'message', format('You already have %s requests open. Finish or withdraw one first, or call us.', v_set.booking_open_request_limit));
      end if;
    end if;
  end if;

  -- the renter as a driver: what we hold wins over what an unsigned-in visitor typed
  v_name := coalesce(dr.full_name, rn.legal_name, v_name, u.full_name);
  if dr.id is not null and v_dob is not null and v_dob <> dr.date_of_birth and p_user is null then v_differ := true; end if;
  v_dob := coalesce(dr.date_of_birth, rn.date_of_birth, v_dob);
  v_mobile := coalesce(v_mobile, rn.mobile, u.phone);
  if v_name is null or v_dob is null then
    raise exception 'The renter''s full legal name and date of birth are needed' using errcode = '22023';
  end if;
  if v_mobile is null then
    raise exception 'A mobile number is needed' using errcode = '22023';
  end if;
  v_on := app.local_date(v_pickup);
  v_age := app.age_on(v_dob, v_on);
  if v_age < v_set.min_renter_age then
    raise exception 'Every driver must be % or older at pickup', v_set.min_renter_age using errcode = '23514';
  end if;
  v_band := app.age_band(v_age);
  if v_band = '18_to_20' and not v.allows_18_to_20 then
    raise exception 'This car is for drivers % and over', v_set.standard_min_age using errcode = '23514';
  end if;
  -- the licence: a class we accept, or one from elsewhere for staff to confirm. What is on file wins.
  v_class := coalesce(upper(dr.licence_class), v_class);
  v_issuer := coalesce(dr.licence_issuer, v_issuer);
  if v_class is null then
    raise exception 'The licence class is needed' using errcode = '22023';
  elsif not v_class = any (select upper(x) from unnest(v_set.accepted_licence_classes) x) then
    if v_class = 'OTHER' and v_set.other_licence_for_review and v_issuer is not null then
      v_review := true;
    else
      raise exception 'A class % licence is needed, or an equivalent from another province or country with its issuer',
        array_to_string(v_set.accepted_licence_classes, ' or ') using errcode = '23514';
    end if;
  end if;

  -- additional drivers
  if jsonb_array_length(v_adds) > v_set.max_additional_drivers then
    raise exception 'A booking may name up to % additional drivers', v_set.max_additional_drivers using errcode = '22023';
  end if;
  v_names := array[lower(regexp_replace(v_name, '\s+', ' ', 'g')) || '|' || v_dob];
  for a in select value from jsonb_array_elements(v_adds) loop
    v_a_name := nullif(btrim(coalesce(a ->> 'full_name', '')), '');
    v_a_dob := (a ->> 'date_of_birth')::date;
    v_a_email := lower(nullif(btrim(coalesce(a ->> 'email', '')), ''));
    v_a_class := upper(nullif(btrim(coalesce(a ->> 'licence_class', '')), ''));
    if v_a_name is null or v_a_dob is null or v_a_email is null then
      raise exception 'Each additional driver needs a full name, a date of birth and an email address' using errcode = '22023';
    end if;
    v_a_age := app.age_on(v_a_dob, v_on);
    if v_a_age < v_set.min_renter_age then
      raise exception 'Every driver must be % or older at pickup', v_set.min_renter_age using errcode = '23514';
    end if;
    if app.age_band(v_a_age) = '18_to_20' and not v.allows_18_to_20 then
      raise exception 'This car is for drivers % and over', v_set.standard_min_age using errcode = '23514';
    end if;
    if v_a_class is not null and not v_a_class = any (select upper(x) from unnest(v_set.accepted_licence_classes) x) then
      if v_a_class = 'OTHER' and v_set.other_licence_for_review and nullif(btrim(coalesce(a ->> 'licence_issuer', '')), '') is not null then
        v_review := true;
      else
        raise exception 'A class % licence is needed, or an equivalent from another province or country with its issuer',
          array_to_string(v_set.accepted_licence_classes, ' or ') using errcode = '23514';
      end if;
    end if;
    if (lower(regexp_replace(v_a_name, '\s+', ' ', 'g')) || '|' || v_a_dob) = any (v_names) then
      raise exception 'The same driver is named twice' using errcode = '22023';
    end if;
    v_names := v_names || (lower(regexp_replace(v_a_name, '\s+', ' ', 'g')) || '|' || v_a_dob);
  end loop;

  -- ---- from here on the request is written
  if u.id is null then
    v_uid := coalesce((r ->> 'user_id')::uuid, gen_random_uuid());
    insert into users (id, email, phone, full_name) values (v_uid, v_email, v_mobile, v_name) returning * into u;
    v_new_account := true;
  end if;
  insert into user_roles (user_id, role) values (u.id, 'renter') on conflict do nothing;
  if rn.id is null then
    insert into renters (user_id, legal_name, date_of_birth, mobile, email)
    values (u.id, v_name, v_dob, v_mobile, u.email) returning * into rn;
  else
    update renters set mobile = case when p_user is not null then v_mobile else coalesce(mobile, v_mobile) end,
                       date_of_birth = coalesce(date_of_birth, v_dob), email = coalesce(email, u.email)
     where id = rn.id returning * into rn;
  end if;
  if dr.id is null then
    insert into drivers (renter_id, is_account_holder, user_id, full_name, date_of_birth, licence_class, licence_issuer, mobile, email)
    values (rn.id, true, u.id, v_name, v_dob, v_class, v_issuer, v_mobile, u.email) returning * into dr;
  elsif dr.licence_class is null then
    update drivers set licence_class = v_class, licence_issuer = coalesce(licence_issuer, v_issuer) where id = dr.id returning * into dr;
  end if;

  v_conflict := not app.vehicle_is_available(v_vehicle, v_pickup, v_return);
  v_booking := app.request_booking(rn.id, v_vehicle, v_pickup, v_return, v_type::booking_type, v_note, 'web', u.id,
                                   nullif(btrim(coalesce(p_request ->> 'referred_by_code', '')), ''), null,
                                   v_pickup_method, v_return_method,
                                   nullif(btrim(coalesce(p_request ->> 'pickup_place', '')), ''),
                                   nullif(btrim(coalesce(p_request ->> 'return_place', '')), ''));

  -- drivers on the booking, as they will be printed in the agreement's summary
  insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, licence_number, licence_class, licence_issuer,
                               licence_expiry, age_at_pickup, age_band)
  values (v_booking, dr.id, 'renter', dr.full_name, dr.date_of_birth, dr.licence_number, dr.licence_class, dr.licence_issuer,
          dr.licence_expiry, v_age, v_band);
  v_drivers_kept := jsonb_build_array(jsonb_build_object('role', 'renter', 'full_name', dr.full_name, 'age_band', v_band));
  for a in select value from jsonb_array_elements(v_adds) loop
    v_a_name := btrim(a ->> 'full_name');
    v_a_dob := (a ->> 'date_of_birth')::date;
    v_a_email := lower(btrim(a ->> 'email'));
    v_a_class := upper(nullif(btrim(coalesce(a ->> 'licence_class', '')), ''));
    v_a_issuer := nullif(btrim(coalesce(a ->> 'licence_issuer', '')), '');
    v_a_age := app.age_on(v_a_dob, v_on);
    select d.id into v_driver from drivers d
     where d.renter_id = rn.id and not d.is_account_holder and d.date_of_birth = v_a_dob
       and lower(regexp_replace(d.full_name, '\s+', ' ', 'g')) = lower(regexp_replace(v_a_name, '\s+', ' ', 'g'))
     order by d.created_at limit 1;
    if v_driver is null then
      insert into drivers (renter_id, full_name, date_of_birth, licence_class, licence_issuer, email)
      values (rn.id, v_a_name, v_a_dob, v_a_class, v_a_issuer, v_a_email) returning id into v_driver;
    else
      update drivers set email = coalesce(email, v_a_email), licence_class = coalesce(licence_class, v_a_class),
                         licence_issuer = coalesce(licence_issuer, v_a_issuer) where id = v_driver;
    end if;
    insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, licence_number, licence_class, licence_issuer,
                                 licence_expiry, age_at_pickup, age_band)
    select v_booking, d.id, 'additional', d.full_name, d.date_of_birth, d.licence_number, d.licence_class, d.licence_issuer,
           d.licence_expiry, v_a_age, app.age_band(v_a_age)
      from drivers d where d.id = v_driver;
    v_drivers_kept := v_drivers_kept || jsonb_build_object('role', 'additional', 'full_name', v_a_name, 'age_band', app.age_band(v_a_age));
  end loop;

  -- the fee terms of this booking, as they stand today: a later change to a default does not move this price
  insert into booking_fee_terms (booking_id, fee_type_code, amount_cents, cap_cents, percent_bps, source)
  select v_booking, x.code, t.amount_cents, t.cap_cents, t.percent_bps, t.source
    from unnest(array['young_driver_18_20', 'young_driver_21_25', 'additional_driver', 'winter_tire', 'baby_seat', 'coverage_sold']) x(code)
    cross join lateral public.effective_fee(x.code, v_vehicle, app.today()) t
  on conflict (booking_id, fee_type_code) do nothing;

  -- the request as sent. Dates of birth, licence details and other people's contact details are
  -- not copied here: they are on the driver records, which fewer staff may read.
  v_details := (q - 'details' - 'consents' - 'renter' - 'additional_drivers' - 'request_key')
    || coalesce(case when jsonb_typeof(q -> 'details') = 'object' then q -> 'details' end, '{}'::jsonb)
    || jsonb_build_object(
         'submitted_at', now(), 'drivers', v_drivers_kept,
         'extras', jsonb_build_object('winter_tire', coalesce((q -> 'extras' ->> 'winter_tire')::boolean, false), 'baby_seats', v_seats),
         'coverage_option', v_cover,
         'terms_version', c -> 'terms' ->> 'version', 'terms_accepted_at', now(),
         'privacy_version', c -> 'privacy' ->> 'version',
         'marketing_opt_in', coalesce((c -> 'marketing' ->> 'opted_in')::boolean, false),
         'conflict_at_submit', v_conflict, 'licence_needs_review', v_review,
         'details_differ_from_record', v_differ, 'new_account', v_new_account);
  update bookings set request_key = v_key, request_details = v_details, coverage_option = v_cover where id = v_booking;
  -- 0025: where the car is handed over and returned, the delivery distance the server measured, an airport
  perform app.apply_booking_places(v_booking, p_request);
  perform app.reprice_booking(v_booking);

  -- a promo code that cannot be used does not stop the request: the reason is kept and returned
  if nullif(btrim(coalesce(p_request ->> 'promo_code', '')), '') is not null then
    v_promo_problem := app.promo_code_problem(p_request ->> 'promo_code', rn.id, v_booking);
    if v_promo_problem is null then
      perform app.apply_promo_code(v_booking, p_request ->> 'promo_code', u.id);
    else
      update bookings set request_details = request_details || jsonb_build_object('promo_problem', v_promo_problem) where id = v_booking;
    end if;
  end if;

  -- consents: each its own row, with the wording shown, its version, when, and from where
  insert into consents (user_id, driver_id, booking_id, consent_code, text_version, text_shown, ip_address, user_agent)
  values (u.id, dr.id, v_booking, 'terms_of_use', c -> 'terms' ->> 'version', c -> 'terms' ->> 'text', p_ip, p_user_agent),
         (u.id, dr.id, v_booking, 'privacy_policy', c -> 'privacy' ->> 'version', c -> 'privacy' ->> 'text', p_ip, p_user_agent);
  if coalesce((c -> 'marketing' ->> 'opted_in')::boolean, false) then
    insert into consents (user_id, driver_id, booking_id, consent_code, text_version, text_shown, ip_address, user_agent)
    values (u.id, dr.id, v_booking, 'marketing', c -> 'marketing' ->> 'version', c -> 'marketing' ->> 'text', p_ip, p_user_agent);
    update users set marketing_opt_in = true, marketing_opt_in_at = coalesce(marketing_opt_in_at, now()), marketing_unsubscribed_at = null
     where id = u.id and not marketing_opt_in;
  end if;

  if rn.is_blocked then
    insert into tasks (queue, task_type, title, detail, procedure_no, priority, booking_id, vehicle_id, renter_id)
    select 'admin', 'blocked_renter_request', format('Request %s is from a blocked customer', o.booking_number),
           'The customer was shown the normal confirmation. Decide whether to decline the request.', 1, 'high', o.id, o.vehicle_id, o.renter_id
      from bookings o where o.id = v_booking;
  end if;

  select * into b from bookings where id = v_booking;
  return jsonb_build_object('ok', true, 'created', true, 'booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status,
    'renter_id', rn.id, 'user_id', u.id, 'new_account', v_new_account, 'conflict_at_submit', v_conflict,
    'licence_needs_review', v_review, 'promo_problem', v_promo_problem,
    'total_due_at_booking_cents', b.total_due_at_booking_cents, 'deposit_cents', b.deposit_cents);
end $function$;

-- search_available
create or replace function public.search_available(p_pickup timestamp with time zone, p_return timestamp with time zone, p_filters jsonb DEFAULT '{}'::jsonb)
 RETURNS TABLE(vehicle_id uuid, slug text, vehicle_year smallint, make text, model text, vehicle_class text, seats smallint, transmission text, fuel text, allows_18_to_20 boolean, daily_rate_cents bigint, billable_days integer, rental_charge_cents bigint, subtotal_cents bigint, hst_cents bigint, total_cents bigint, deposit_cents bigint)
 LANGUAGE sql
 SET search_path TO 'public', 'app'
AS $function$
  select * from app.search_available(p_pickup, p_return, p_filters)
$function$;

create or replace function app.search_available(p_pickup timestamp with time zone, p_return timestamp with time zone, p_filters jsonb DEFAULT '{}'::jsonb)
 RETURNS TABLE(vehicle_id uuid, slug text, vehicle_year smallint, make text, model text, vehicle_class text, seats smallint, transmission text, fuel text, allows_18_to_20 boolean, daily_rate_cents bigint, billable_days integer, rental_charge_cents bigint, subtotal_cents bigint, hst_cents bigint, total_cents bigint, deposit_cents bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
#variable_conflict use_column
declare
  f jsonb := coalesce(p_filters, '{}'::jsonb);
  v_set program_settings := app.settings();
  v_days integer;
begin
  perform app.public_rate_check('search');
  if p_pickup is null or p_return is null or p_return <= p_pickup then
    raise exception 'The return must be after the pickup' using errcode = '22023';
  end if;
  v_days := public.calc_billable_days(p_pickup, p_return);
  if v_days > v_set.max_rental_days then
    raise exception 'A rental transaction is 1 to % days; % requested. Longer stays renew with a new booking.', v_set.max_rental_days, v_days
      using errcode = '22023';
  end if;
  return query
    select q.vehicle_id, q.slug, q.year, q.make, q.model, q.class, q.seats, q.transmission, q.fuel, q.allows_18_to_20, q.daily_rate_cents,
           (q.quote ->> 'billable_days')::integer, (q.quote ->> 'rental_charge_cents')::bigint, (q.quote ->> 'subtotal_cents')::bigint,
           (q.quote ->> 'hst_cents')::bigint, (q.quote ->> 'total_cents')::bigint, q.deposit_cents
      from (select l.vehicle_id, l.slug, l.year, l.make, l.model, l.class::text as class, l.seats, l.transmission, l.fuel::text as fuel,
                   l.allows_18_to_20, l.daily_rate_cents, l.deposit_cents,
                   app.price_quote(l.vehicle_id, p_pickup, p_return, coalesce(f -> 'options', '{}'::jsonb)) as quote
              from public_vehicle_listings l
              join vehicles v on v.id = l.vehicle_id
             where app.vehicle_is_available(l.vehicle_id, p_pickup, p_return)
               and (v.exit_date is null or app.local_date(p_return) <= v.exit_date)
               and ((f ->> 'class') is null or app.vehicle_in_classes(l.vehicle_id, array[f ->> 'class']))
               and (jsonb_typeof(f -> 'classes') is distinct from 'array'
                    or app.vehicle_in_classes(l.vehicle_id, array(select jsonb_array_elements_text(f -> 'classes'))))
               and ((f ->> 'seats_min') is null or l.seats >= (f ->> 'seats_min')::integer)
               and ((f ->> 'transmission') is null or lower(l.transmission) = lower(f ->> 'transmission'))
               and ((f ->> 'fuel') is null or l.fuel::text = f ->> 'fuel')
               and ((f ->> 'make') is null or lower(l.make) = lower(f ->> 'make'))
               and (not coalesce((f ->> 'young')::boolean, false) or l.allows_18_to_20)
               and ((f ->> 'max_daily_rate_cents') is null or l.daily_rate_cents <= (f ->> 'max_daily_rate_cents')::bigint)) q
     where (f ->> 'max_total_cents') is null or (q.quote ->> 'total_cents')::bigint <= (f ->> 'max_total_cents')::bigint
     order by (q.quote ->> 'total_cents')::bigint, q.slug, q.vehicle_id;
end $function$;

-- public_listing_row
create or replace function app.public_listing_row(p_vehicle uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
  select jsonb_build_object(
    'vehicle_id', v.id, 'slug', l.slug, 'path', '/cars/' || l.slug,
    'canonical_path', '/cars/' || coalesce((select c.slug from vehicle_listings c where c.vehicle_id = l.canonical_vehicle_id), l.slug),
    'headline', l.headline, 'year', v.year, 'make', v.make, 'model', v.model, 'trim', v.trim, 'colour', v.colour,
    'fuel', v.fuel, 'class', v.class, 'classes', app.vehicle_class_list(v.id), 'body_style', coalesce(l.body_style, v.body_type), 'seats', l.seats,
    'transmission', l.transmission, 'doors', l.doors, 'drivetrain', l.drivetrain, 'luggage', l.luggage,
    'home_area', l.home_area, 'allows_18_to_20', v.allows_18_to_20, 'is_featured', l.is_featured,
    'taking_requests', l.status = 'published' and pv.vehicle_id is not null,
    'model_hub_path', app.model_hub_path(v.make, v.model),
    'daily_rate_cents', rc.daily_rate_cents, 'weekend_rate_cents', rc.weekend_rate_cents, 'weekly_rate_cents', rc.weekly_rate_cents,
    'monthly_rate_cents', rc.monthly_rate_cents, 'km_allowance_per_day', rc.km_allowance_per_day,
    'overage_cents_per_km', rc.overage_cents_per_km, 'deposit_cents', rc.deposit_cents,
    'delivery_fee_cents', rc.delivery_fee_cents, 'pickup_fee_cents', rc.pickup_fee_cents,
    'cover', (select jsonb_build_object('path', ph.processed_path, 'variants', ph.variants, 'alt', ph.alt_text)
                from vehicle_photos ph where ph.vehicle_id = v.id and ph.is_cover and ph.is_public and ph.status = 'approved'
                 and ph.replaced_at is null limit 1),
    'published_at', l.first_published_at, 'updated_at', l.content_updated_at)
    from vehicle_listings l join vehicles v on v.id = l.vehicle_id
    left join public_vehicle_listings pv on pv.vehicle_id = v.id
    left join rate_cards rc on rc.vehicle_id = v.id and rc.effective_from <= now() and (rc.effective_to is null or rc.effective_to > now())
   where l.vehicle_id = p_vehicle and l.status in ('published', 'paused') and v.management_mode <> 'turo_only'
$function$;

-- public_fleet
create or replace function app.public_fleet(p_filters jsonb DEFAULT '{}'::jsonb)
 RETURNS SETOF jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
  select r from (
    select app.public_listing_row(l.vehicle_id) r, l.is_featured, l.first_published_at
      from vehicle_listings l join vehicles v on v.id = l.vehicle_id
     where l.status = 'published' and v.management_mode <> 'turo_only'
       and (p_filters ->> 'class' is null or app.vehicle_in_classes(v.id, array[p_filters ->> 'class']))
       and (jsonb_typeof(p_filters -> 'classes') is distinct from 'array'
            or app.vehicle_in_classes(v.id, array(select jsonb_array_elements_text(p_filters -> 'classes'))))
       and (p_filters ->> 'make' is null or app.slugify(v.make) = app.slugify(p_filters ->> 'make'))
       and (p_filters ->> 'model' is null or app.slugify(v.model) = app.slugify(p_filters ->> 'model'))
       and (p_filters ->> 'fuel' is null or v.fuel::text = p_filters ->> 'fuel')
       and (p_filters ->> 'body_style' is null or lower(coalesce(l.body_style, v.body_type)) = lower(p_filters ->> 'body_style'))
       and (not coalesce((p_filters ->> 'featured')::boolean, false) or l.is_featured)) q
   where r is not null
   order by q.is_featured desc, (r ->> 'daily_rate_cents')::bigint nulls last, q.first_published_at
$function$;

-- public_site_settings
create or replace function app.public_site_settings()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
  select jsonb_build_object(
    'brand_name', s.brand_name, 'site_url', s.site_url, 'tagline', s.tagline,
    'logo', jsonb_build_object('light', s.logo_light_file_key, 'dark', s.logo_dark_file_key, 'width', s.logo_width,
                               'height', s.logo_height, 'alt', s.logo_alt, 'wordmark', s.wordmark_text),
    'favicon', s.favicon_file_key, 'og_image', s.og_image_file_key,
    'city', s.city, 'region', s.region, 'service_area', s.service_area,
    'delivery_area_text', s.delivery_area_text, 'delivery_areas', s.delivery_areas, 'airport_delivery', s.airport_delivery,
    'phone', s.phone, 'whatsapp', s.whatsapp, 'roadside_phone', s.roadside_phone,
    'phone_display', s.phone_display, 'whatsapp_display', s.whatsapp_display, 'roadside_phone_display', s.roadside_phone_display,
    'handover_any_time', s.handover_any_time, 'google_place_id', s.google_place_id,
    'listing_time_promise', s.listing_time_promise, 'featured_mode', s.featured_mode,
    'public_email', s.public_email, 'owners_email', s.owners_email, 'mailing_address', s.mailing_address,
    'street_address', case when s.show_street_address then s.street_address end,
    'opening_hours_text', s.opening_hours_text, 'opening_hours', ps.opening_hours, 'handover_slots', to_jsonb(s.handover_slots),
    'social_links', s.social_links, 'review_source', s.review_source, 'reply_wording', s.reply_wording,
    'seo', jsonb_build_object('default_title', s.seo_default_title, 'title_suffix', s.seo_title_suffix,
                              'default_description', s.seo_default_description),
    'hst_number', ps.company_hst_number, 'updated_at', s.updated_at)
    from site_settings s cross join app.settings() ps
   where s.singleton
$function$;

-- The Owner's view of their bookings (0016): one row per booking and car, so the Owner of a
-- replacement car sees their part of a swapped booking and the first Owner sees theirs.
create or replace view owner_bookings as
 select b.id, b.booking_number, b.booking_type, b.status,
        coalesce(s.vehicle_id, b.vehicle_id) as vehicle_id,
        b.management_mode, b.pickup_at, b.return_at, b.pickup_place, b.return_place, b.billable_days,
        b.handed_over_at, b.checked_in_at,
        case when s.booking_id is not null and s.segment_days is distinct from b.billable_days then s.rental_charge_cents
             else b.rental_charge_cents - b.discount_cents - b.staff_discount_cents - b.promo_discount_cents end as rental_charge_cents,
        case when b.management_mode = 'self_managed' or b.booking_type = 'owner' then r.legal_name end as renter_name,
        case when b.management_mode = 'self_managed' or b.booking_type = 'owner' then r.mobile end as renter_mobile,
        s.mileage_overage_cents, s.kickback_cents, s.owner_revenue_cents, s.company_share_cents, s.owner_payout_cents,
        s.payout_month, b.blocks_calendar, b.dates_provisional
   from bookings b
   join renters r on r.id = b.renter_id
   left join booking_splits s on s.booking_id = b.id
  where app.is_my_owner(coalesce(s.owner_id, b.owner_id))
    and b.status::text <> all (array['requested', 'offered', 'tentative', 'expired', 'declined']);

-- =====================================================================================
-- 2. Expired offers: closed, and back to staff (decision 2)
-- =====================================================================================
insert into status_transitions (entity, from_status, to_status, note) values
  ('booking', 'offered', 'expired', 'the offer passed its expiry without an answer: the request is closed and staff decide (0025)'),
  ('booking', 'expired', 'requested', 'staff reopened an expired request to offer it again (0025)')
on conflict do nothing;
update status_transitions set note = 'the renter asked for a change, staff withdrew the offer, or another booking took the car'
 where entity = 'booking' and from_status = 'offered' and to_status = 'requested';

alter table booking_events drop constraint if exists booking_events_kind_check;
alter table booking_events add constraint booking_events_kind_check check (kind = any (array[
  'adjusted', 'agreement_completed', 'agreement_opened', 'agreement_signed', 'agreement_voided', 'booking_change',
  'calendar_switch', 'cancelled', 'change_requested', 'confirmed', 'declined', 'deposit_waived', 'extension',
  'info_replied', 'info_requested', 'offer_approved', 'offer_expired', 'offer_sent', 'offer_withdrawn', 'payment_refused',
  'promo_applied', 'promo_removed', 'pushed_back', 'requested', 'verification', 'reopened', 'review_request']));

update task_rules
   set title = 'The offer expired without an answer',
       completion_rule = null,
       description = 'The request is closed (expired). Re-offer it with app.reopen_expired_request and a new offer, or leave it closed and complete the task.'
 where task_type = 'offer_expired';
insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description)
select 'offer_expired', 'cs', 'The offer expired without an answer', 'normal', 'opening_minutes', 120, 1, null,
       'The request is closed (expired). Re-offer it with app.reopen_expired_request and a new offer, or leave it closed and complete the task.'
 where not exists (select 1 from task_rules where task_type = 'offer_expired');

-- An offer not answered by its expiry: the offer is marked expired, the booking becomes
-- `expired` (it no longer goes back to `requested`, 0016's decision), the history says so
-- (which sends renter_offer_expired once, 0023), and customer service gets a task to re-offer
-- or leave it closed.
create or replace function app.expire_offers(p_now timestamptz default now())
returns integer language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  n integer := 0;
begin
  for r in select b.id, b.booking_number, b.current_offer_version, b.vehicle_id, b.renter_id, b.offer_expires_at
             from bookings b
            where b.status = 'offered' and b.offer_expires_at <= p_now
            order by b.offer_expires_at, b.id
            for update skip locked
  loop
    update booking_offers set status = 'expired', responded_at = p_now
     where booking_id = r.id and version = r.current_offer_version and status = 'sent';
    update bookings set status = 'expired', offer_expires_at = null where id = r.id;
    perform app.log_booking_event(r.id, 'offer_expired', 'offered', 'expired', r.current_offer_version,
      format('Offer version %s was not answered by %s (Toronto). The request is closed; staff may reopen it and offer again.',
             r.current_offer_version, to_char(r.offer_expires_at at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI')), null, 'system');
    perform app.raise_task(p_type => 'offer_expired',
        p_title => format('Booking %s: the offer expired without an answer', r.booking_number),
        p_detail => 'The request is closed. Reopen it and send a new offer, or leave it closed.',
        p_booking => r.id, p_vehicle => r.vehicle_id, p_renter => r.renter_id,
        p_dedupe => format('offer_expired:%s:v%s', r.id, r.current_offer_version));
    n := n + 1;
  end loop;
  return n;
end $$;

-- Staff reopen an expired request: back to `requested`, then the normal offer flow.
create or replace function app.reopen_expired_request(p_booking uuid, p_by uuid, p_note text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
begin
  if p_by is null or not app.user_is_staff(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if b.status <> 'expired' or b.current_offer_version is null then
    raise exception 'Booking % is %: only a request whose offer expired is reopened', b.booking_number, b.status using errcode = '23514';
  end if;
  update bookings set status = 'requested' where id = p_booking;
  perform app.log_booking_event(p_booking, 'reopened', 'expired', 'requested', b.current_offer_version,
    coalesce(nullif(btrim(p_note), ''), 'Reopened by staff to offer again'), p_by);
  perform app.resolve_tasks(array['offer_expired'], p_booking, null, 'Request reopened');
end $$;

-- =====================================================================================
-- 4. Review requests: held for a staff decision when a booking had a problem (decision 11)
-- =====================================================================================
alter table site_settings add constraint site_settings_google_place_id_check
  check (google_place_id is null or google_place_id ~ '^[A-Za-z0-9_-]{10,200}$');

create table review_request_decisions (
  booking_id   uuid primary key references bookings(id) on delete cascade,
  problems     text[] not null,
  status       text not null default 'pending' check (status in ('pending', 'send', 'skip')),
  task_id      uuid references tasks(id),
  decided_by   uuid references users(id),
  decided_at   timestamptz,
  note         text,
  sent_at      timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  check ((status = 'pending') = (decided_at is null))
);

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description)
values ('review_request_decision', 'cs', 'Decide whether to ask for a review', 'normal', 'business_days', 1, null, null,
        'The booking had a problem (an incident, a dispute, an unpaid balance or a damage charge), so the review request was not sent. Answer yes to send it or no to leave it.')
on conflict (task_type) do nothing;

-- What makes a closed booking a problem booking: an incident (open or past), a dispute, an
-- unpaid balance, or a damage charge.
create or replace function app.booking_review_problems(p_booking uuid) returns text[]
language sql stable security definer set search_path = public, app as $$
  select array_remove(array[
    case when exists (select 1 from incidents i where i.booking_id = p_booking) then 'incident' end,
    case when exists (select 1 from disputes d where d.booking_id = p_booking) then 'dispute' end,
    case when app.ntf_booking_balance(p_booking) > 0 then 'unpaid_balance' end,
    case when exists (select 1 from booking_line_items li where li.booking_id = p_booking and li.voided_at is null
                         and li.charge_type in ('damage_at_cost', 'deductible', 'loss_of_use'))
           or exists (select 1 from damage_intakes di where di.booking_id = p_booking and di.status <> 'void')
         then 'damage_charge' end], null)
$$;

create or replace function app.hold_review_request(p_booking uuid) returns boolean
language plpgsql security definer set search_path = public, app as $$
declare
  v_problems text[] := app.booking_review_problems(p_booking);
  b bookings;
  v_task uuid;
begin
  if cardinality(v_problems) = 0 then return false; end if;
  if exists (select 1 from review_request_decisions d where d.booking_id = p_booking) then return true; end if;
  select * into b from bookings where id = p_booking;
  v_task := app.raise_task(p_type => 'review_request_decision',
      p_title => format('Booking %s: send the review request?', b.booking_number),
      p_detail => format('The booking had: %s. The review request is sent only if you answer yes.', array_to_string(v_problems, ', ')),
      p_booking => p_booking, p_vehicle => b.vehicle_id, p_renter => b.renter_id,
      p_related_table => 'review_request_decisions', p_related_id => p_booking,
      p_dedupe => 'review_request_decision:' || p_booking);
  insert into review_request_decisions (booking_id, problems, task_id) values (p_booking, v_problems, v_task)
  on conflict (booking_id) do nothing;
  return true;
end $$;

-- when a booking closes with a problem, the decision is opened at once
create or replace function app.review_request_on_close() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status = 'closed' and old.status is distinct from 'closed' and new.booking_type <> 'owner' then
    perform app.hold_review_request(new.id);
  end if;
  return null;
end $$;
create trigger bookings_review_request_hold after update of status on bookings
  for each row execute function app.review_request_on_close();

-- the automatic review request (0023's follow-up job) is not recorded, so not sent, for a
-- problem booking unless staff said yes
create or replace function app.review_request_guard() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  d review_request_decisions;
begin
  if new.code <> 'renter_review_request' or new.booking_id is null then return new; end if;
  select * into d from review_request_decisions where booking_id = new.booking_id;
  if d.status = 'send' then return new; end if;
  if d.booking_id is not null or app.hold_review_request(new.booking_id) then
    return null;
  end if;
  return new;
end $$;
create trigger marketing_sends_review_guard before insert on marketing_sends
  for each row execute function app.review_request_guard();

-- Customer service (or an Admin) answers: yes sends the review request now (once, with the
-- renter's implied consent as for every review request); no leaves it unsent.
create or replace function app.decide_review_request(p_booking uuid, p_by uuid, p_send boolean, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  d review_request_decisions;
  b bookings;
  v_user uuid;
  v_sent boolean := false;
  v_reason text;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs')) then
    raise exception 'Customer service or an Admin decides' using errcode = '42501';
  end if;
  select * into d from review_request_decisions where booking_id = p_booking for update;
  if d.booking_id is null then raise exception 'No review request is waiting for a decision on this booking' using errcode = '23514'; end if;
  if d.status <> 'pending' then raise exception 'Already decided: %', d.status using errcode = '23514'; end if;
  select * into b from bookings where id = p_booking;
  select r.user_id into v_user from renters r where r.id = b.renter_id;
  update review_request_decisions set status = case when p_send then 'send' else 'skip' end, decided_by = p_by, decided_at = now(),
         note = p_note where booking_id = p_booking;
  if p_send then
    if exists (select 1 from reviews x where x.booking_id = p_booking) then
      v_reason := 'already reviewed';
    elsif not app.has_marketing_consent(v_user, 'implied') then
      v_reason := 'the renter does not accept these emails';
    else
      insert into marketing_sends (code, booking_id, renter_id, user_id) values ('renter_review_request', p_booking, b.renter_id, v_user)
      on conflict (code, booking_id) do nothing;
      perform app.ntf_emit('renter_review_request', 'booking', p_booking, 'closed', jsonb_build_object('booking_id', p_booking));
      update review_request_decisions set sent_at = now() where booking_id = p_booking;
      v_sent := true;
    end if;
  end if;
  perform app.log_booking_event(p_booking, 'review_request', b.status::text, b.status::text, b.current_offer_version,
    case when p_send then 'Staff said yes to the review request' else 'Staff said no to the review request' end
      || coalesce(': ' || nullif(btrim(p_note), ''), ''), p_by);
  perform app.resolve_tasks(array['review_request_decision'], p_booking, null, case when p_send then 'Yes' else 'No' end);
  return jsonb_build_object('sent', v_sent, 'reason', v_reason);
end $$;

-- The email catalogue (emails/catalogue.json, rebuilt) describes both events as they now work.
update notification_catalogue
   set trigger_text = 'The offers-expire job (every 5 minutes, app.expire_offers) marks the current booking_offers row expired because offer_expires_at passed without approval. The booking becomes expired (the request is closed), and customer service gets an offer_expired task to reopen it with a new offer or leave it closed. Sent once per offer version.',
       emitted_by = 'booking_events_notify (0023), from app.expire_offers (0025)'
 where code = 'renter_offer_expired';
update notification_catalogue
   set trigger_text = '2 days after booking status becomes closed. Only if the renter has not unsubscribed and no review exists for it. A booking that had a problem (an incident, a dispute, an unpaid balance or a damage charge) is held for a staff decision (review_request_decision task): only a yes sends it, at once. Relies on the existing business relationship for consent, so it carries the unsubscribe link and mailing address.',
       emitted_by = 'app.notify_followups (0023); app.decide_review_request on a yes (0025)'
 where code = 'renter_review_request';

-- =====================================================================================
-- 5. Cookie consent (decision 14)
-- =====================================================================================
alter table consents drop constraint if exists consents_consent_code_check;
alter table consents add constraint consents_consent_code_check check (consent_code = any (array[
  'analytics_cookies', 'necessary_cookies', 'card_authorization', 'electronic_signature', 'identity_verification',
  'marketing', 'owner_tracking', 'privacy_policy', 'terms_of_use', 'tracking_disabling']));

create table cookie_consents (
  id               uuid primary key default gen_random_uuid(),
  visitor_id       text not null check (visitor_id ~ '^[A-Za-z0-9_-]{8,128}$'),
  user_id          uuid references users(id),
  choice           text not null check (choice in ('accept_all', 'necessary_only', 'custom')),
  analytics        boolean not null,
  consent_codes    text[] not null,
  wording_version  text not null check (length(btrim(wording_version)) between 1 and 64),
  recorded_at      timestamptz not null default now(),
  user_agent       text
);
create index cookie_consents_visitor_idx on cookie_consents (visitor_id, recorded_at desc);

-- The banner's answer, kept as given: the anonymous visitor id (from the browser), the
-- choice, the wording version shown and the time. Necessary cookies are always on; analytics
-- only with consent. A signed-in user's choice is also written to consents.
create or replace function app.record_cookie_choice(p_visitor_id text, p_choice text, p_wording_version text,
                                                    p_analytics boolean default null, p_user_agent text default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  v_analytics boolean := case p_choice when 'accept_all' then true when 'necessary_only' then false else coalesce(p_analytics, false) end;
  v_codes text[];
  v_user uuid := app.uid();
  v_id uuid;
begin
  perform app.public_rate_check('cookie_choice');
  if p_choice not in ('accept_all', 'necessary_only', 'custom') then
    raise exception 'Unknown choice %', p_choice using errcode = '22023';
  end if;
  v_codes := case when v_analytics then array['necessary_cookies', 'analytics_cookies'] else array['necessary_cookies'] end;
  insert into cookie_consents (visitor_id, user_id, choice, analytics, consent_codes, wording_version, user_agent)
  values (p_visitor_id, v_user, p_choice, v_analytics, v_codes, btrim(p_wording_version), left(p_user_agent, 300))
  returning id into v_id;
  if v_user is not null and v_analytics then
    insert into consents (user_id, consent_code, text_version, text_shown, user_agent)
    values (v_user, 'analytics_cookies', btrim(p_wording_version), 'Cookie banner, version ' || btrim(p_wording_version), left(p_user_agent, 300));
  end if;
  return jsonb_build_object('ok', true, 'id', v_id, 'analytics', v_analytics, 'consent_codes', to_jsonb(v_codes));
end $$;

create or replace function app.cookie_choice(p_visitor_id text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('choice', c.choice, 'analytics', c.analytics, 'wording_version', c.wording_version, 'recorded_at', c.recorded_at)
    from cookie_consents c where c.visitor_id = p_visitor_id order by c.recorded_at desc, c.id desc limit 1
$$;

-- public wrappers (the API exposes public only); invoker, like 0019 and 0022
create or replace function public.record_cookie_choice(p_visitor_id text, p_choice text, p_wording_version text,
                                                       p_analytics boolean default null, p_user_agent text default null)
returns jsonb language sql set search_path = public, app as $$
  select app.record_cookie_choice(p_visitor_id, p_choice, p_wording_version, p_analytics, p_user_agent)
$$;
create or replace function public.cookie_choice(p_visitor_id text) returns jsonb
language sql set search_path = public, app as $$ select app.cookie_choice(p_visitor_id) $$;
create or replace function public.vehicle_classes() returns jsonb
language sql set search_path = public, app as $$ select app.public_vehicle_classes() $$;
create or replace function public.featured_cars(p_limit integer default 6) returns setof jsonb
language sql set search_path = public, app as $$ select * from app.public_featured_cars(p_limit) $$;

-- =====================================================================================
-- 6. Row-level security, privileges, audit
-- =====================================================================================
do $$
declare t text;
begin
  foreach t in array array['vehicle_classes', 'vehicle_class_links', 'deposit_tiers', 'km_allowance_choices', 'coverage_prices',
                           'airports', 'email_aliases', 'email_reply_to', 'review_request_decisions', 'cookie_consents']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
    execute format('revoke all on %I from public, anon, authenticated', t);
  end loop;
end $$;

-- reference lists: every staff member reads; fleet keeps the class links; the server writes the rest
create policy staff_read on vehicle_classes for select to authenticated using (app.user_is_staff(app.uid()));
create policy staff_read on vehicle_class_links for select to authenticated using (app.user_is_staff(app.uid()));
create policy owner_read on vehicle_class_links for select to authenticated
  using (exists (select 1 from vehicles v where v.id = vehicle_id and app.is_my_owner(v.owner_id)));
create policy staff_read on deposit_tiers for select to authenticated using (app.user_is_staff(app.uid()));
create policy staff_read on km_allowance_choices for select to authenticated using (app.user_is_staff(app.uid()));
create policy staff_read on coverage_prices for select to authenticated using (app.is_admin() or app.va_has('cs', 'finance', 'fleet'));
create policy staff_read on airports for select to authenticated using (app.user_is_staff(app.uid()));
create policy staff_read on email_aliases for select to authenticated using (app.user_is_staff(app.uid()));
create policy staff_read on email_reply_to for select to authenticated using (app.user_is_staff(app.uid()));
create policy cs_read on review_request_decisions for select to authenticated using (app.va_has('cs'));
grant select on vehicle_classes, vehicle_class_links, deposit_tiers, km_allowance_choices, coverage_prices, airports,
                email_aliases, email_reply_to, review_request_decisions to authenticated;
grant insert, update on vehicle_classes, deposit_tiers, km_allowance_choices, coverage_prices, airports,
                        email_aliases, email_reply_to to authenticated;   -- admin_all decides who
-- cookie_consents: written by the function only; an Admin reads (admin_all)
grant select on cookie_consents to authenticated;
grant all on vehicle_classes, vehicle_class_links, deposit_tiers, km_allowance_choices, coverage_prices, airports,
             email_aliases, email_reply_to, review_request_decisions, cookie_consents to service_role;

-- functions: revoked, then granted
do $$
declare f text;
begin
  foreach f in array array[
    'app.vehicle_split_terms(uuid, date, text)', 'app.vehicle_free_locked(uuid, timestamptz, timestamptz, uuid)',
    'app.booking_vehicle_swap_terms()', 'app.whole_days_between(timestamptz, timestamptz)', 'app.booking_segments(uuid)',
    'app.segment_overage_km(uuid)', 'app.cut(bigint, bigint, bigint, bigint)', 'app.booking_line_allocation(uuid)',
    'app.booking_split_parts(uuid)', 'app.fee_per_day(jsonb, bigint)', 'app.vehicle_class_link_main()',
    'app.vehicle_class_list(uuid)', 'app.vehicle_in_classes(uuid, text[])', 'app.public_vehicle_classes()',
    'app.set_vehicle_classes(uuid, uuid, text[])', 'app.propose_listing_classes(uuid, text[])',
    'app.review_listing_classes(uuid, uuid, boolean, text[])', 'app.rate_card_choices()',
    'app.set_vehicle_deposit(uuid, uuid, bigint, timestamptz)', 'app.coverage_term(uuid, text, date, jsonb)',
    'app.set_coverage_price(uuid, uuid, bigint, text)',
    'app.distance_km(numeric, numeric, numeric, numeric)', 'app.delivery_fee(uuid, text, jsonb)',
    'app.apply_booking_places(uuid, jsonb)', 'app.set_booking_places(uuid, uuid, jsonb)', 'app.site_setup_problems()',
    'app.public_featured_cars(integer)', 'app.email_reply_to_for(text, text)', 'app.outbox_reply_to()',
    'app.reopen_expired_request(uuid, uuid, text)', 'app.booking_review_problems(uuid)', 'app.hold_review_request(uuid)',
    'app.review_request_on_close()', 'app.review_request_guard()', 'app.decide_review_request(uuid, uuid, boolean, text)',
    'app.record_cookie_choice(text, text, text, boolean, text)', 'app.cookie_choice(text)',
    'public.record_cookie_choice(text, text, text, boolean, text)', 'public.cookie_choice(text)',
    'public.vehicle_classes()', 'public.featured_cars(integer)']
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
-- the public site reads, helpers they use, and the cookie banner (anonymous visitors too)
grant execute on function app.vehicle_class_list(uuid), app.vehicle_in_classes(uuid, text[]), app.public_vehicle_classes(),
                          app.public_featured_cars(integer), app.record_cookie_choice(text, text, text, boolean, text), app.cookie_choice(text),
                          public.record_cookie_choice(text, text, text, boolean, text), public.cookie_choice(text),
                          public.vehicle_classes(), public.featured_cars(integer)
  to anon, authenticated;
-- staff screens
grant execute on function app.rate_card_choices(), app.site_setup_problems() to authenticated;

select app.attach_audit();
