-- 0066_add_ons.sql
-- Add-ons (the owner's request of October 19, 2026; docs/changes/2026-10-19-add-ons.md): things renters buy with a
-- rental, such as flowers, a baby seat, a chauffeur or a prepaid full tank.
--   1. The catalogue (`addons`): name, short description, optional photo, price and pricing unit (per trip, per day
--      with an optional most days and most per trip, per hour with a minimum), a price by car class or body type,
--      HST on or off, active, which cars (all by default; classes, cars, cars left out, fuel types left out, months),
--      notice needed, stock for physical items checked across overlapping bookings, staff confirmation, a Fleet
--      task to get it ready, refunds after the notice, order. Admin > Settings > Add-ons; Fleet sets stock.
--      Seeded ACTIVE with the owner's prices (his change of October 19: less work for the Admin). The two extras
--      that already existed (baby seat and winter tires) are now catalogue add-ons, not a second copy.
--   2. On a booking (`booking_addons`): chosen in the request, on the car page, by staff in an offer or a rental
--      added by hand, or bought from the renter portal after booking until a cutoff before pickup. Each is one
--      booking line priced from a snapshot of the catalogue, so a later price change does not move a booking.
--   3. Money: add-on lines are CarmaCars' own revenue (revenue class company_only, account 4150 Add-ons), never
--      Owner Revenue or a partner's share, never in a commission or kickback base (those stay on the rental charge
--      after discounts). The company statement shows Add-ons as its own income line. A cancellation refunds them
--      by the booking's tier, except an add-on marked non-refundable once its notice has started.
--   4. Staff: the Fleet task for items to prepare (flowers, chauffeur), the field handover lists what goes in the
--      car (and the prepaid fuel note), a chauffeur waits for staff confirmation.
-- Nothing here creates a task for the owner. No applied migration is edited.

-- A function patched in place: the text must be found, or the migration stops (so a change by another migration
-- to the same function is noticed instead of overwritten).
create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception 'add-ons: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. accounts, fee type, settings
insert into gl_accounts (code, name, account_type, note)
values ('4150', 'Add-ons', 'revenue', 'added in 0066: items and services renters buy with a rental (CarmaCars'' own revenue)')
on conflict (code) do nothing;

insert into fee_types (code, label, family, unit, per_what, revenue_class, hst_applies, stage, refundable_by_tier, in_master_spec, sort_order, gl_account)
values ('addon', 'Add-on', 'fee', 'flat', 'item', 'company_only', true, 'booking', true, false, 115, '4150')
on conflict (code) do nothing;
-- the extras that were already sold are add-ons now: their revenue goes to the same account
update fee_types set gl_account = '4150' where code in ('baby_seat', 'winter_tire');

alter table payments drop constraint payments_purpose_check;
alter table payments add constraint payments_purpose_check check (purpose = any (array['booking_total', 'deposit', 'extension', 'post_rental',
  'toll_ticket', 'damage', 'deductible', 'owner_upfront', 'owner_fees', 'other', 'addon']));
alter table refunds drop constraint refunds_reason_check;
alter table refunds add constraint refunds_reason_check check (reason = any (array['cancellation', 'carmacars_cancelled', 'driver_not_verifiable',
  'pricing_error', 'breakdown_unused_days', 'goodwill', 'duplicate', 'other', 'addon_removed']));

alter table program_settings
  add column if not exists addon_portal_cutoff_hours integer not null default 24 check (addon_portal_cutoff_hours between 0 and 336);
comment on column program_settings.addon_portal_cutoff_hours is 'Add-ons (0066): renters may add add-ons from their portal until this many hours before pickup (or the add-on''s own notice, if longer).';

-- ================================================================ 2. the catalogue
create table addons (
  id                        uuid primary key default gen_random_uuid(),
  code                      text not null unique check (code ~ '^[a-z0-9_]{2,40}$'),
  name                      text not null check (length(btrim(name)) between 1 and 80),
  description               text check (length(description) <= 300),
  photo_path                text check (length(photo_path) <= 300),
  fee_type_code             text not null default 'addon' references fee_types (code),
  pricing_unit              text not null check (pricing_unit in ('per_trip', 'per_day', 'per_hour')),
  price_cents               bigint check (price_cents >= 0),
  price_overrides           jsonb not null default '[]'::jsonb check (jsonb_typeof(price_overrides) = 'array'),
  max_days                  integer check (max_days between 1 and 365),
  cap_cents                 bigint check (cap_cents >= 0),
  min_hours                 numeric(5, 2) check (min_hours > 0 and min_hours <= 24),
  hst_applies               boolean not null default true,
  active                    boolean not null default true,
  vehicle_classes           vehicle_class[] not null default '{}',
  vehicle_ids               uuid[] not null default '{}',
  excluded_vehicle_ids      uuid[] not null default '{}',
  excluded_fuel_types       fuel_type[] not null default '{}',
  available_months          integer[] not null default '{}',
  lead_time_hours           integer not null default 0 check (lead_time_hours between 0 and 336),
  stock_count               integer check (stock_count >= 0),
  max_per_booking           integer not null default 1 check (max_per_booking between 1 and 20),
  needs_confirmation        boolean not null default false,
  needs_prep                boolean not null default false,
  prep_note                 text check (length(prep_note) <= 300),
  handover_note             text check (length(handover_note) <= 300),
  prepaid_fuel              boolean not null default false,
  non_refundable_after_lead boolean not null default false,
  sort_order                integer not null default 100,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  updated_by                uuid references users (id),
  check (not active or price_cents is not null),
  check (pricing_unit = 'per_day' or max_days is null),
  check (pricing_unit = 'per_hour' or min_hours is null),
  check (available_months <@ array[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])
);
comment on table addons is 'Add-ons (0066): the catalogue of things renters buy with a rental. Admin > Settings > Add-ons; Fleet sets stock_count. Empty car lists mean every car.';
comment on column addons.price_overrides is 'Prices by car: [{"classes": ["suv"], "body_types": ["van"], "price_cents": 11000}], the first that matches the car wins; otherwise price_cents.';
comment on column addons.cap_cents is 'Per day or per hour: the most one item costs per rental.';
comment on column addons.stock_count is 'Physical items: how many CarmaCars has. Checked across overlapping bookings. Empty: not counted.';
comment on column addons.non_refundable_after_lead is 'Not refunded on a cancellation once its notice has started (for example flowers already ordered).';

-- a booking's add-ons, each with the price as it was when added
create table booking_addons (
  id                 uuid primary key default gen_random_uuid(),
  booking_id         uuid not null references bookings (id) on delete cascade,
  addon_id           uuid not null references addons (id),
  quantity           integer not null default 1 check (quantity between 1 and 20),
  hours              numeric(5, 2) check (hours > 0 and hours <= 24),
  name               text not null,
  fee_type_code      text not null references fee_types (code),
  pricing_unit       text not null check (pricing_unit in ('per_trip', 'per_day', 'per_hour')),
  unit_price_cents   bigint not null check (unit_price_cents >= 0),
  max_days           integer,
  cap_cents          bigint,
  min_hours          numeric(5, 2),
  hst_applies        boolean not null,
  status             text not null default 'confirmed' check (status in ('pending', 'confirmed', 'cancelled', 'declined')),
  added_via          text not null check (added_via in ('request', 'offer', 'manual', 'quote', 'portal', 'staff', 'migrated')),
  added_by           uuid references users (id),
  added_at           timestamptz not null default now(),
  confirmed_by       uuid references users (id),
  confirmed_at       timestamptz,
  cancelled_by       uuid references users (id),
  cancelled_at       timestamptz,
  cancel_reason      text,
  after_booking      boolean not null default false,
  payment_id         uuid references payments (id),
  line_item_id       uuid references booking_line_items (id),
  kept_on_cancel     boolean not null default false,
  check ((status in ('cancelled', 'declined')) = (cancelled_at is not null))
);
create unique index booking_addons_one_live on booking_addons (booking_id, addon_id) where status in ('pending', 'confirmed');
create index booking_addons_addon_idx on booking_addons (addon_id) where status in ('pending', 'confirmed');
comment on table booking_addons is 'Add-ons (0066) on a booking: the price snapshot, who added it and how, pending staff confirmation, bought after booking (its own payment), kept on a cancellation.';

alter table booking_line_items add column booking_addon_id uuid references booking_addons (id);
create index booking_line_items_addon_idx on booking_line_items (booking_addon_id) where booking_addon_id is not null;

do $$
declare t text;
begin
  foreach t in array array['addons', 'booking_addons'] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
    execute format('create trigger audit_%s after insert or update or delete on %I for each row execute function app.audit_row()', t, t);
  end loop;
end $$;
create policy staff_read on addons for select to authenticated using (app.is_va());
create policy staff_read on booking_addons for select to authenticated using (app.va_has('cs', 'finance', 'fleet', 'sales'));
create policy renter_read on booking_addons for select to authenticated using (app.is_my_booking(booking_id) and status in ('pending', 'confirmed'));
revoke all on addons, booking_addons from anon;
grant select on addons, booking_addons to authenticated;

create or replace function app.addons_touch() returns trigger
language plpgsql as $$ begin new.updated_at := now(); return new; end $$;
create trigger addons_touch before update on addons for each row execute function app.addons_touch();

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, description) values
  ('addon_prep', 'fleet', 'Get an add-on ready', 'normal', 'opening_minutes', 240, 'An add-on needs preparing before pickup (flowers to order, a chauffeur to book): do it and mark the task done'),
  ('addon_confirm', 'cs', 'Confirm an add-on', 'high', 'opening_minutes', 120, 'A renter asked for an add-on that needs our confirmation: confirm or decline it on the booking'),
  ('addon_payment', 'finance', 'Collect an add-on payment', 'normal', 'opening_minutes', 480, 'An add-on was added after booking and the renter has no card on file: collect the payment and record it on the booking'),
  ('addon_stock', 'fleet', 'Not enough of an add-on', 'urgent', 'opening_minutes', 60, 'A confirmed booking has an add-on with no stock left for its dates: find another or tell the renter')
on conflict (task_type) do update set queue = excluded.queue, title = excluded.title, priority = excluded.priority,
  due_kind = excluded.due_kind, due_amount = excluded.due_amount, description = excluded.description;

-- ================================================================ 3. the starter set (active, the owner's prices)
-- The two extras already sold become the first add-ons (same fee codes, so their lines and history carry on).
insert into addons (code, name, description, fee_type_code, pricing_unit, price_cents, max_days, cap_cents, min_hours, hst_applies, active,
                    vehicle_classes, excluded_fuel_types, available_months, lead_time_hours, stock_count, max_per_booking,
                    needs_confirmation, needs_prep, prep_note, handover_note, prepaid_fuel, non_refundable_after_lead, price_overrides, sort_order)
values
  ('flowers', 'Flowers', 'A fresh bouquet waiting in the car.', 'addon', 'per_trip', 15000, null, null, null, true, true,
   '{}', '{}', '{}', 24, null, 1, false, true, 'Order the bouquet and put it in the car before pickup.', 'Put the bouquet on the front passenger seat.', false, true, '[]', 10),
  ('baby_seat', 'Baby seat (rear-facing)', 'Rear-facing infant seat. You install it and check it suits your child.', 'baby_seat', 'per_day', 1500, null, 7500, null, true, true,
   '{}', '{}', '{}', 0, 2, 2, false, false, null, 'Put the baby seat in the car (not installed).', false, false, '[]', 20),
  ('child_seat', 'Child seat', 'Forward-facing child seat. You install it and check it suits your child.', 'addon', 'per_day', 1500, null, 7500, null, true, true,
   '{}', '{}', '{}', 0, 2, 2, false, false, null, 'Put the child seat in the car (not installed).', false, false, '[]', 30),
  ('booster_seat', 'Booster seat', 'Booster seat for older children.', 'addon', 'per_day', 1000, null, 5000, null, true, true,
   '{}', '{}', '{}', 0, 2, 2, false, false, null, 'Put the booster seat in the car.', false, false, '[]', 40),
  ('chauffeur', 'Chauffeur', 'A professional driver for your trip, by the hour.', 'addon', 'per_hour', 4500, null, null, 3, true, true,
   '{}', '{}', '{}', 24, null, 1, true, true, 'Book a chauffeur for the hours asked and send the renter their name.', 'A chauffeur drives this booking: check with Fleet who and when.', false, true, '[]', 50),
  ('umbrella', 'Umbrella', 'A full-size umbrella in the car.', 'addon', 'per_trip', 500, null, null, null, true, true,
   '{}', '{}', '{}', 0, 4, 1, false, false, null, 'Put an umbrella in the car.', false, false, '[]', 60),
  ('phone_charger', 'Phone charger', 'A charging cable with USB-C and Lightning ends.', 'addon', 'per_trip', 500, null, null, null, true, true,
   '{}', '{}', '{}', 0, 4, 1, false, false, null, 'Put a phone charger (USB-C and Lightning) in the car.', false, false, '[]', 70),
  ('full_tank', 'Full tank of gas (prepaid)', 'We fill it up for you. Return the car at any fuel level, with no fuel charge.', 'addon', 'per_trip', 8500, null, null, null, true, true,
   '{}', '{electric}', '{}', 0, null, 1, false, false, null, 'Prepaid fuel: the renter may return the car at any fuel level. Do not charge for fuel.', true, false,
   '[{"classes": ["suv", "premium", "luxury", "exotic"], "price_cents": 11000}, {"body_types": ["van", "minivan"], "price_cents": 11000}]', 80),
  ('winter_tire', 'Winter tires', 'Winter tires for the rental, October to April, subject to availability for the car.', 'winter_tire', 'per_day', 1500, null, 15000, null, true, true,
   '{}', '{}', '{10, 11, 12, 1, 2, 3, 4}', 0, null, 1, false, false, null, 'Winter tires on this booking: check they are on the car.', false, false, '[]', 90);

-- the existing baby seat and winter tire fee defaults follow the catalogue from today (the Schedule of Fees and the site
-- facts read them); bookings keep the terms they were priced with
insert into fee_defaults (fee_type_code, amount_cents, cap_cents, note, effective_from)
select 'baby_seat', 1500, 7500, 'per day, per seat; cap per rental (add-on, 0066)', app.today()
 where not exists (select 1 from fee_defaults where fee_type_code = 'baby_seat' and vehicle_class is null and effective_from = app.today());
update fee_defaults set effective_to = app.today()
 where fee_type_code = 'baby_seat' and vehicle_class is null and effective_from < app.today() and (effective_to is null or effective_to > app.today());

-- ================================================================ 4. pricing
create or replace function app.addon_applies(a addons, v vehicles, p_at timestamptz) returns boolean
language sql stable security definer set search_path = public, app as $$
  select (cardinality(a.vehicle_classes) = 0 or v.class = any (a.vehicle_classes))
     and (cardinality(a.vehicle_ids) = 0 or v.id = any (a.vehicle_ids))
     and not (v.id = any (a.excluded_vehicle_ids))
     and not (v.fuel is not null and v.fuel = any (a.excluded_fuel_types))
     and (cardinality(a.available_months) = 0 or p_at is null
          or extract(month from app.local_date(p_at))::integer = any (a.available_months))
$$;

create or replace function app.addon_unit_price(a addons, v vehicles) returns bigint
language sql stable security definer set search_path = public, app as $$
  select coalesce((
    select (o.value ->> 'price_cents')::bigint
      from jsonb_array_elements(a.price_overrides) with ordinality o(value, ord)
     where (o.value ->> 'price_cents') is not null
       and (jsonb_typeof(o.value -> 'classes') is distinct from 'array' or jsonb_array_length(o.value -> 'classes') = 0
            or v.class::text in (select jsonb_array_elements_text(o.value -> 'classes')))
       and (jsonb_typeof(o.value -> 'body_types') is distinct from 'array' or jsonb_array_length(o.value -> 'body_types') = 0
            or exists (select 1 from jsonb_array_elements_text(o.value -> 'body_types') t
                        where lower(coalesce(v.body_type, '')) like '%' || lower(t) || '%'))
       and (jsonb_array_length(coalesce(o.value -> 'classes', '[]')) > 0 or jsonb_array_length(coalesce(o.value -> 'body_types', '[]')) > 0)
     order by o.ord limit 1), a.price_cents)
$$;

-- one item's price for the rental: per trip; per day (at most max_days, at most cap); per hour (at least min_hours, at most cap)
create or replace function app.addon_item_cents(p_unit text, p_price bigint, p_days integer, p_hours numeric, p_max_days integer, p_cap bigint, p_min_hours numeric)
returns bigint language sql immutable as $$
  select case
    when p_unit = 'per_day' then least(p_price * least(greatest(coalesce(p_days, 1), 1), coalesce(p_max_days, greatest(coalesce(p_days, 1), 1))), coalesce(p_cap, 9223372036854775807))
    when p_unit = 'per_hour' then least(round(p_price * greatest(coalesce(p_hours, p_min_hours, 1), coalesce(p_min_hours, 0)))::bigint, coalesce(p_cap, 9223372036854775807))
    else p_price end
$$;

-- the price line of one add-on (a selection: the snapshot fields), in app.price_line's shape
create or replace function app.addon_line(s jsonb, p_days integer, p_hst_bps integer) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_qty integer := greatest(coalesce((s ->> 'quantity')::integer, 1), 1);
  v_each bigint;
  v_amt bigint;
  v_hst boolean := coalesce((s ->> 'hst_applies')::boolean, true);
  v_unit text := s ->> 'pricing_unit';
  v_hours numeric := coalesce((s ->> 'hours')::numeric, (s ->> 'min_hours')::numeric);
  v_desc text;
begin
  v_each := app.addon_item_cents(v_unit, (s ->> 'unit_price_cents')::bigint, p_days, v_hours, (s ->> 'max_days')::integer,
                                 (s ->> 'cap_cents')::bigint, (s ->> 'min_hours')::numeric);
  v_amt := v_each * v_qty;
  v_desc := (s ->> 'name') || case when v_qty > 1 then ' x ' || v_qty else '' end
         || case v_unit when 'per_hour' then ', ' || trim(trailing '.' from trim(trailing '0' from v_hours::text)) || ' hours'
                        when 'per_day' then ', ' || least(p_days, coalesce((s ->> 'max_days')::integer, p_days)) || case when least(p_days, coalesce((s ->> 'max_days')::integer, p_days)) = 1 then ' day' else ' days' end
                        else '' end
         || case when s ->> 'status' = 'pending' then ' (to be confirmed)' else '' end;
  return jsonb_build_object('charge_type', coalesce(s ->> 'fee_type_code', 'addon'), 'label', s ->> 'name', 'description', v_desc,
    'quantity', v_qty, 'unit_amount_cents', v_each, 'amount_cents', v_amt, 'hst_applies', v_hst,
    'hst_cents', case when v_hst then public.calc_hst(v_amt, p_hst_bps) else 0 end,
    'revenue_class', 'company_only', 'driver_id', null, 'booking_addon_id', s ->> 'booking_addon_id',
    'detail', jsonb_strip_nulls(jsonb_build_object('addon_id', s ->> 'addon_id', 'code', s ->> 'code', 'pricing_unit', v_unit,
                'unit_price_cents', (s ->> 'unit_price_cents')::bigint, 'hours', case when v_unit = 'per_hour' then v_hours end,
                'cap_cents', (s ->> 'cap_cents')::bigint, 'max_days', (s ->> 'max_days')::integer, 'status', s ->> 'status',
                'booking_addon_id', s ->> 'booking_addon_id',
                'capped', case when (s ->> 'cap_cents') is not null and v_unit in ('per_day', 'per_hour')
                               then v_each < app.addon_item_cents(v_unit, (s ->> 'unit_price_cents')::bigint, p_days, v_hours, (s ->> 'max_days')::integer, null, (s ->> 'min_hours')::numeric) end)),
    'sort_order', coalesce((select f.sort_order from fee_types f where f.code = coalesce(s ->> 'fee_type_code', 'addon')), 115));
end $$;

-- how many of an add-on other bookings hold over these dates (bookings that hold the car)
create or replace function app.addon_held(p_addon uuid, p_from timestamptz, p_to timestamptz, p_exclude uuid default null) returns integer
language sql stable security definer set search_path = public, app as $$
  select coalesce(sum(ba.quantity), 0)::integer
    from booking_addons ba join bookings b on b.id = ba.booking_id
   where ba.addon_id = p_addon and ba.status in ('pending', 'confirmed')
     and b.id is distinct from p_exclude
     and b.status in ('tentative', 'pending_payment', 'confirmed', 'on_rent')
     and b.pickup_at < p_to
     and (case when b.status = 'on_rent' then greatest(b.return_at, now()) else b.return_at end) > p_from
$$;

-- legacy extras ({"winter_tire": true, "baby_seats": 2}) as add-on choices
create or replace function app.addons_input(o jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := case when jsonb_typeof(o -> 'addons') = 'array' then o -> 'addons' else '[]'::jsonb end;
  v_codes text[];
  n integer;
begin
  select coalesce(array_agg(coalesce(x ->> 'code', (select a.code from addons a where a.id::text = x ->> 'addon_id'))), '{}') into v_codes
    from jsonb_array_elements(v) x;
  n := coalesce((o -> 'extras' ->> 'baby_seats')::integer, 0);
  if n > 0 and not 'baby_seat' = any (v_codes) then v := v || jsonb_build_object('code', 'baby_seat', 'quantity', n); end if;
  if coalesce((o -> 'extras' ->> 'winter_tire')::boolean, false) and not 'winter_tire' = any (v_codes) then
    v := v || jsonb_build_object('code', 'winter_tire', 'quantity', 1);
  end if;
  return v;
end $$;

-- The add-ons asked for, checked and priced for a car and dates: {"items": [...], "problems": [...]}.
-- p_channel: 'renter' (the website and the renter portal: notice is enforced) or 'staff'.
-- p_strict raises the first problem instead of listing it.
create or replace function app.addons_resolve(p_vehicle uuid, p_pickup timestamptz, p_return timestamptz, p_input jsonb,
                                              p_channel text default 'renter', p_booking uuid default null, p_strict boolean default false)
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
  b bookings;
  e jsonb;
  a addons;
  ex booking_addons;
  v_items jsonb := '[]'::jsonb;
  v_problems jsonb := '[]'::jsonb;
  v_qty integer;
  v_hours numeric;
  v_free integer;
  v_msg text;
  v_code text;
  v_seen uuid[] := '{}';
  v_fresh boolean;
begin
  select * into v from vehicles where id = p_vehicle;
  if p_booking is not null then select * into b from bookings where id = p_booking; end if;
  for e in select value from jsonb_array_elements(case when jsonb_typeof(p_input) = 'array' then p_input else '[]'::jsonb end) loop
    a := null; ex := null; v_msg := null; v_code := null;
    select * into a from addons x where x.id::text = e ->> 'addon_id' or x.code = e ->> 'code' limit 1;
    v_qty := coalesce(nullif(e ->> 'quantity', '')::integer, 1);
    if a.id is null then
      v_code := 'addon_unknown'; v_msg := 'That add-on is not offered.';
    elsif v_qty < 1 or a.id = any (v_seen) then
      continue;
    else
      v_seen := v_seen || a.id;
      if p_booking is not null then
        select * into ex from booking_addons x where x.booking_id = p_booking and x.addon_id = a.id and x.status in ('pending', 'confirmed');
      end if;
      v_hours := case when a.pricing_unit = 'per_hour' then coalesce(nullif(e ->> 'hours', '')::numeric, ex.hours, a.min_hours, 1) end;
      if not a.active and ex.id is null then
        v_code := 'addon_inactive'; v_msg := format('%s is not offered at the moment.', a.name);
      elsif ex.id is null and not app.addon_applies(a, v, p_pickup) then
        v_code := 'addon_not_for_car'; v_msg := format('%s is not offered for this car or these dates.', a.name);
      elsif v_qty > a.max_per_booking then
        v_code := 'addon_too_many'; v_msg := format('%s: at most %s on one booking.', a.name, a.max_per_booking);
      elsif a.pricing_unit = 'per_hour' and v_hours < coalesce(a.min_hours, 0) then
        v_code := 'addon_min_hours'; v_msg := format('%s is booked for at least %s hours.', a.name, trim(trailing '.' from trim(trailing '0' from a.min_hours::text)));
      elsif p_channel = 'renter' and a.lead_time_hours > 0 and p_pickup < now() + make_interval(hours => a.lead_time_hours)
            and (ex.id is null or v_qty > ex.quantity) then
        v_code := 'addon_notice'; v_msg := format('%s needs %s hours'' notice before pickup.', a.name, a.lead_time_hours);
      elsif a.stock_count is not null then
        v_free := a.stock_count - app.addon_held(a.id, p_pickup, p_return, p_booking);
        if v_qty > v_free then
          v_code := 'addon_no_stock';
          v_msg := case when v_free <= 0 then format('%s: none left for these dates.', a.name)
                        else format('%s: only %s left for these dates.', a.name, v_free) end;
        end if;
      end if;
    end if;
    if v_msg is not null then
      if p_strict then raise exception '%', v_msg using errcode = '23514'; end if;
      v_problems := v_problems || jsonb_build_object('code', v_code, 'addon', coalesce(a.code, e ->> 'code'), 'message', v_msg);
      continue;
    end if;
    -- the price: the booking's snapshot once it is past the request, otherwise today's catalogue
    v_fresh := ex.id is null or b.id is null or b.status in ('requested', 'tentative');
    v_items := v_items || jsonb_build_object(
      'addon_id', a.id, 'code', a.code, 'name', case when v_fresh then a.name else ex.name end,
      'fee_type_code', case when v_fresh then a.fee_type_code else ex.fee_type_code end,
      'pricing_unit', case when v_fresh then a.pricing_unit else ex.pricing_unit end,
      'unit_price_cents', case when v_fresh then app.addon_unit_price(a, v) else ex.unit_price_cents end,
      'max_days', case when v_fresh then a.max_days else ex.max_days end,
      'cap_cents', case when v_fresh then a.cap_cents else ex.cap_cents end,
      'min_hours', case when v_fresh then a.min_hours else ex.min_hours end,
      'hst_applies', case when v_fresh then a.hst_applies else ex.hst_applies end,
      'quantity', v_qty, 'hours', v_hours, 'needs_confirmation', a.needs_confirmation, 'lead_time_hours', a.lead_time_hours,
      'status', coalesce(ex.status, case when a.needs_confirmation and p_channel = 'renter' then 'pending' else 'confirmed' end),
      'booking_addon_id', ex.id, 'sort_order', a.sort_order);
  end loop;
  return jsonb_build_object('items', (select coalesce(jsonb_agg(x.value order by (x.value ->> 'sort_order')::integer, x.ord), '[]'::jsonb)
                                       from jsonb_array_elements(v_items) with ordinality x(value, ord)),
                            'problems', v_problems);
end $$;

-- what a booking's add-ons price as (the spec for app.price_lines)
create or replace function app.booking_addons_spec(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('booking_addon_id', ba.id, 'addon_id', ba.addon_id, 'code', a.code, 'name', ba.name,
           'fee_type_code', ba.fee_type_code, 'pricing_unit', ba.pricing_unit, 'unit_price_cents', ba.unit_price_cents, 'max_days', ba.max_days,
           'cap_cents', ba.cap_cents, 'min_hours', ba.min_hours, 'hst_applies', ba.hst_applies, 'quantity', ba.quantity, 'hours', ba.hours,
           'status', ba.status) order by a.sort_order, ba.added_at), '[]'::jsonb)
    from booking_addons ba join addons a on a.id = ba.addon_id
   where ba.booking_id = p_booking and ba.status in ('pending', 'confirmed')
     and (not ba.after_booking or ba.line_item_id is not null)
$$;

-- app.price_lines: add-on lines; the old extras only for a spec without add-ons (none is built that way any more)
select pg_temp.patch_fn('app.price_lines(jsonb)'::regprocedure,
  $o$    -- extras
    if coalesce((p -> 'extras' ->> 'winter_tire')::boolean, false) then$o$,
  $n$    -- extras (0066: add-ons price these now; the extras only for a spec without add-ons)
    if not (p ? 'addons') and coalesce((p -> 'extras' ->> 'winter_tire')::boolean, false) then$n$);
select pg_temp.patch_fn('app.price_lines(jsonb)'::regprocedure,
  $o$    n := coalesce((p -> 'extras' ->> 'baby_seats')::integer, 0);$o$,
  $n$    n := case when p ? 'addons' then 0 else coalesce((p -> 'extras' ->> 'baby_seats')::integer, 0) end;$n$);
select pg_temp.patch_fn('app.price_lines(jsonb)'::regprocedure,
  $o$  select coalesce(jsonb_agg(x.value order by (x.value ->> 'sort_order')::integer, x.ord), '[]'::jsonb),$o$,
  $n$  -- add-ons (0066): one line each, from the booking's snapshot or today's catalogue
  for d in select value from jsonb_array_elements(case when jsonb_typeof(p -> 'addons') = 'array' then p -> 'addons' else '[]'::jsonb end) loop
    v_lines := v_lines || app.addon_line(d, v_days, v_hst);
  end loop;

  select coalesce(jsonb_agg(x.value order by (x.value ->> 'sort_order')::integer, x.ord), '[]'::jsonb),$n$);

-- a booking's price: its add-ons
select pg_temp.patch_fn('app.booking_price_spec(uuid, jsonb)'::regprocedure,
  $o$'drivers', v_drivers, 'extras', coalesce(b.request_details -> 'extras', '{}'::jsonb),$o$,
  $n$'drivers', v_drivers, 'extras', coalesce(b.request_details -> 'extras', '{}'::jsonb), 'addons', app.booking_addons_spec(p_booking),$n$);

-- the quote (car page, request, rentals added by hand): add-ons asked for, with their problems
select pg_temp.patch_fn('app.price_quote(uuid, timestamptz, timestamptz, jsonb)'::regprocedure,
  $o$  v_return_fee jsonb;
begin$o$,
  $n$  v_return_fee jsonb;
  v_addq jsonb;
begin$n$);
select pg_temp.patch_fn('app.price_quote(uuid, timestamptz, timestamptz, jsonb)'::regprocedure,
  $o$  v_out := app.price_lines(jsonb_build_object($o$,
  $n$  -- 0066: add-ons (the old extras read as add-ons)
  v_addq := app.addons_resolve(p_vehicle, p_pickup, p_return, app.addons_input(o), coalesce(nullif(o ->> 'addon_channel', ''), 'renter'), null, false);
  v_problems := v_problems || coalesce(v_addq -> 'problems', '[]'::jsonb);
  v_out := app.price_lines(jsonb_build_object($n$);
select pg_temp.patch_fn('app.price_quote(uuid, timestamptz, timestamptz, jsonb)'::regprocedure,
  $o$'managed', true, 'drivers', v_drivers, 'extras', coalesce(o -> 'extras', '{}'::jsonb),$o$,
  $n$'managed', true, 'drivers', v_drivers, 'extras', coalesce(o -> 'extras', '{}'::jsonb), 'addons', coalesce(v_addq -> 'items', '[]'::jsonb),$n$);
select pg_temp.patch_fn('app.price_quote(uuid, timestamptz, timestamptz, jsonb)'::regprocedure,
  $o$    'problems', v_problems);$o$,
  $n$    'problems', v_problems,
    'addons', coalesce(v_addq -> 'items', '[]'::jsonb));$n$);
-- the public quote is the renter's: the staff channel only through the staff screens
select pg_temp.patch_fn('app.quote_booking(uuid, timestamptz, timestamptz, jsonb)'::regprocedure,
  $o$  return app.price_quote(p_vehicle, p_pickup, p_return, p_options);$o$,
  $n$  return app.price_quote(p_vehicle, p_pickup, p_return, coalesce(p_options, '{}'::jsonb) - 'addon_channel');$n$);
-- a rental added by hand: its quote with the add-ons, as staff
select pg_temp.patch_fn('app.manual_rental_quote_0058(uuid, jsonb)'::regprocedure,
  $o$'drivers', coalesce(p -> 'drivers', '[]'::jsonb), 'extras', coalesce(p -> 'extras', '{}'::jsonb),$o$,
  $n$'drivers', coalesce(p -> 'drivers', '[]'::jsonb), 'extras', coalesce(p -> 'extras', '{}'::jsonb),
               'addons', coalesce(p -> 'addons', '[]'::jsonb), 'addon_channel', 'staff',$n$);

-- the price lines, one per add-on (matched by its booking add-on, not only by fee code)
create or replace function app.put_price_line(p_booking uuid, p_line jsonb) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_line booking_line_items;
  v_driver uuid := (p_line ->> 'driver_id')::uuid;
  v_ba uuid := nullif(p_line ->> 'booking_addon_id', '')::uuid;
  v_id uuid;
begin
  select * into v_line from booking_line_items
   where booking_id = p_booking and charge_type = p_line ->> 'charge_type' and stage = 'booking' and voided_at is null
     and driver_id is not distinct from v_driver and booking_addon_id is not distinct from v_ba
   order by created_at, id limit 1;
  if v_line.id is null then
    insert into booking_line_items (booking_id, charge_type, description, quantity, unit_amount_cents, amount_cents,
                                    hst_applies, hst_cents, revenue_class, stage, driver_id, booking_addon_id)
    values (p_booking, p_line ->> 'charge_type', p_line ->> 'description', (p_line ->> 'quantity')::numeric,
            (p_line ->> 'unit_amount_cents')::bigint, (p_line ->> 'amount_cents')::bigint,
            (p_line ->> 'hst_applies')::boolean, (p_line ->> 'hst_cents')::bigint, (p_line ->> 'revenue_class')::revenue_class,
            'booking', v_driver, v_ba)
    returning id into v_id;
    return v_id;
  end if;
  if (v_line.amount_cents, v_line.hst_cents, v_line.unit_amount_cents, v_line.quantity, v_line.hst_applies)
     is distinct from ((p_line ->> 'amount_cents')::bigint, (p_line ->> 'hst_cents')::bigint,
                       (p_line ->> 'unit_amount_cents')::bigint, (p_line ->> 'quantity')::numeric(12, 3), (p_line ->> 'hst_applies')::boolean)
     or (v_ba is not null and v_line.description is distinct from p_line ->> 'description') then
    update booking_line_items
       set unit_amount_cents = (p_line ->> 'unit_amount_cents')::bigint, amount_cents = (p_line ->> 'amount_cents')::bigint,
           quantity = (p_line ->> 'quantity')::numeric, hst_cents = (p_line ->> 'hst_cents')::bigint, hst_applies = (p_line ->> 'hst_applies')::boolean,
           description = case when v_ba is not null then p_line ->> 'description' else description end
     where id = v_line.id;
  end if;
  return v_line.id;
end $$;

-- the booking's add-on lines are always the pricing's own; each add-on keeps a link to its line
select pg_temp.patch_fn('app.sync_booking_price(uuid)'::regprocedure,
  $o$  v_owned text[] := array['rental_charge', 'non_refundable_discount', 'staff_discount', 'promo_discount', 'delivery', 'pickup'];$o$,
  $n$  v_owned text[] := array['rental_charge', 'non_refundable_discount', 'staff_discount', 'promo_discount', 'delivery', 'pickup', 'addon', 'baby_seat', 'winter_tire'];$n$);
select pg_temp.patch_fn('app.sync_booking_price(uuid)'::regprocedure,
  $o$       and charge_type = any (v_owned) and id <> all (v_keep);$o$,
  $n$       and charge_type = any (v_owned) and id <> all (v_keep);
    update booking_addons ba set line_item_id = li.id
      from booking_line_items li
     where ba.booking_id = p_booking and li.booking_id = p_booking and li.booking_addon_id = ba.id and li.voided_at is null
       and ba.line_item_id is distinct from li.id;$n$);

-- ================================================================ 5. existing baby seat and winter tire lines become add-ons
do $$
declare
  l record;
  v_ba uuid;
  a addons;
begin
  for l in select li.*, b.vehicle_id, b.status as b_status from booking_line_items li join bookings b on b.id = li.booking_id
            where li.charge_type in ('baby_seat', 'winter_tire') and li.stage = 'booking' and li.voided_at is null and li.booking_addon_id is null loop
    select * into a from addons where code = l.charge_type;
    insert into booking_addons (booking_id, addon_id, quantity, name, fee_type_code, pricing_unit, unit_price_cents, cap_cents, hst_applies,
                                status, added_via, added_at, line_item_id)
    select l.booking_id, a.id, case when l.charge_type = 'baby_seat' then greatest(l.quantity::integer, 1) else 1 end, a.name, l.charge_type, 'per_day',
           coalesce((select t.amount_cents from booking_fee_terms t where t.booking_id = l.booking_id and t.fee_type_code = l.charge_type),
                    case l.charge_type when 'baby_seat' then 1200 else 1500 end),
           coalesce((select t.cap_cents from booking_fee_terms t where t.booking_id = l.booking_id and t.fee_type_code = l.charge_type),
                    case l.charge_type when 'baby_seat' then 7000 else 15000 end),
           l.hst_applies, 'confirmed', 'migrated', l.created_at, l.id
    on conflict do nothing
    returning id into v_ba;
    if v_ba is not null then update booking_line_items set booking_addon_id = v_ba where id = l.id; end if;
    v_ba := null;
  end loop;
end $$;

-- ================================================================ 6. add-ons on a booking
create or replace function app.addons_sync_extras(p_booking uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_seats integer;
  v_winter boolean;
begin
  select coalesce(sum(ba.quantity) filter (where a.code = 'baby_seat'), 0), coalesce(bool_or(a.code = 'winter_tire'), false)
    into v_seats, v_winter
    from booking_addons ba join addons a on a.id = ba.addon_id
   where ba.booking_id = p_booking and ba.status in ('pending', 'confirmed');
  perform set_config('app.addons_syncing', 'on', true);
  update bookings set request_details = jsonb_set(request_details, '{extras}',
           coalesce(request_details -> 'extras', '{}'::jsonb) || jsonb_build_object('winter_tire', v_winter, 'baby_seats', v_seats))
   where id = p_booking and request_details is not null
     and (coalesce((request_details -> 'extras' ->> 'baby_seats')::integer, 0), coalesce((request_details -> 'extras' ->> 'winter_tire')::boolean, false))
         is distinct from (v_seats, v_winter);
  perform set_config('app.addons_syncing', '', true);
end $$;

-- Set a booking's add-ons to the list given (one entry per add-on; an add-on left out is removed). p_via says
-- who: 'request' (the website), 'offer' and 'staff' (staff on a request or offer), 'manual', 'quote'.
-- p_price false: the caller prices the booking itself (a booking being created).
create or replace function app.booking_addons_set(p_booking uuid, p_by uuid, p_input jsonb, p_via text default 'offer', p_price boolean default true)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  r jsonb;
  i jsonb;
  v_keep uuid[] := '{}';
  v_id uuid;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking using errcode = 'P0002'; end if;
  if p_by is not null and not app.user_is_sales_staff(p_by) then
    raise exception 'Only staff change the add-ons of a booking' using errcode = '42501';
  end if;
  if p_price and not (b.status in ('requested', 'tentative') or (b.dates_provisional and b.status in ('confirmed', 'on_rent'))) then
    raise exception 'Booking % is %: add or remove an add-on one at a time on the booking', b.booking_number, b.status using errcode = '23514';
  end if;
  if b.booking_type = 'owner' and jsonb_array_length(coalesce(p_input, '[]'::jsonb)) > 0 then
    raise exception 'An Owner Booking has no add-ons' using errcode = '23514';
  end if;
  r := app.addons_resolve(b.vehicle_id, b.pickup_at, b.return_at, coalesce(p_input, '[]'::jsonb),
                          case when p_via = 'request' then 'renter' else 'staff' end, b.id, true);
  for i in select value from jsonb_array_elements(r -> 'items') loop
    v_id := nullif(i ->> 'booking_addon_id', '')::uuid;
    if v_id is null then
      insert into booking_addons (booking_id, addon_id, quantity, hours, name, fee_type_code, pricing_unit, unit_price_cents, max_days, cap_cents,
                                  min_hours, hst_applies, status, added_via, added_by, confirmed_by, confirmed_at)
      values (b.id, (i ->> 'addon_id')::uuid, (i ->> 'quantity')::integer, (i ->> 'hours')::numeric, i ->> 'name', i ->> 'fee_type_code',
              i ->> 'pricing_unit', (i ->> 'unit_price_cents')::bigint, (i ->> 'max_days')::integer, (i ->> 'cap_cents')::bigint,
              (i ->> 'min_hours')::numeric, (i ->> 'hst_applies')::boolean, i ->> 'status', p_via, p_by,
              case when i ->> 'status' = 'confirmed' then p_by end, case when i ->> 'status' = 'confirmed' then now() end)
      returning id into v_id;
    else
      update booking_addons
         set quantity = (i ->> 'quantity')::integer, hours = (i ->> 'hours')::numeric, name = i ->> 'name', fee_type_code = i ->> 'fee_type_code',
             pricing_unit = i ->> 'pricing_unit', unit_price_cents = (i ->> 'unit_price_cents')::bigint, max_days = (i ->> 'max_days')::integer,
             cap_cents = (i ->> 'cap_cents')::bigint, min_hours = (i ->> 'min_hours')::numeric, hst_applies = (i ->> 'hst_applies')::boolean,
             -- staff keeping an add-on that waited for confirmation confirm it
             status = case when status = 'pending' and p_via in ('offer', 'staff', 'manual') then 'confirmed' else status end,
             confirmed_by = case when status = 'pending' and p_via in ('offer', 'staff', 'manual') then p_by else confirmed_by end,
             confirmed_at = case when status = 'pending' and p_via in ('offer', 'staff', 'manual') then now() else confirmed_at end
       where id = v_id
         and (quantity, hours, unit_price_cents, status) is distinct from ((i ->> 'quantity')::integer, (i ->> 'hours')::numeric,
              (i ->> 'unit_price_cents')::bigint, case when status = 'pending' and p_via in ('offer', 'staff', 'manual') then 'confirmed' else status end);
    end if;
    v_keep := v_keep || v_id;
  end loop;
  update booking_addons set status = 'cancelled', cancelled_at = now(), cancelled_by = p_by, cancel_reason = 'Removed'
   where booking_id = b.id and status in ('pending', 'confirmed') and not after_booking and id <> all (v_keep);
  perform app.addons_sync_extras(b.id);
  if p_price then perform app.sync_booking_price(b.id); end if;
  return app.booking_addons_json(b.id);
end $$;

create or replace function app.booking_addons_json(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', ba.id, 'addon_id', ba.addon_id, 'code', a.code, 'name', ba.name, 'quantity', ba.quantity,
           'hours', ba.hours, 'pricing_unit', ba.pricing_unit, 'unit_price_cents', ba.unit_price_cents, 'cap_cents', ba.cap_cents, 'max_days', ba.max_days,
           'min_hours', ba.min_hours, 'status', ba.status, 'added_via', ba.added_via, 'after_booking', ba.after_booking,
           'paid', ba.payment_id is not null or (not ba.after_booking and b.confirmed_at is not null),
           'amount_cents', li.amount_cents, 'hst_cents', li.hst_cents, 'line_item_id', li.id,
           'needs_prep', a.needs_prep, 'needs_confirmation', a.needs_confirmation, 'prepaid_fuel', a.prepaid_fuel,
           'handover_note', a.handover_note, 'prep_note', a.prep_note, 'photo_path', a.photo_path, 'kept_on_cancel', ba.kept_on_cancel)
           order by a.sort_order, ba.added_at), '[]'::jsonb)
    from booking_addons ba join addons a on a.id = ba.addon_id join bookings b on b.id = ba.booking_id
    left join booking_line_items li on li.id = ba.line_item_id and li.voided_at is null
   where ba.booking_id = p_booking and ba.status in ('pending', 'confirmed')
$$;

-- bookings created by the request, a rental added by hand or a staff quote: the add-ons asked for, from the context
-- the wrapper set (app.addons_pending), and the old extras kept in step with the add-ons both ways
create or replace function app.bookings_addons_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_pending text := nullif(current_setting('app.addons_pending', true), '');
  v_input jsonb;
  v_have jsonb;
  v_want jsonb;
begin
  if coalesce(current_setting('app.addons_syncing', true), '') = 'on' then return null; end if;
  if tg_op = 'INSERT' and v_pending is not null then
    perform set_config('app.addons_pending', '', true);
    perform app.booking_addons_set(new.id, null, v_pending::jsonb -> 'items', coalesce(v_pending::jsonb ->> 'via', 'request'), false);
    return null;
  end if;
  if new.request_details is null or not (new.request_details ? 'extras') then return null; end if;
  if tg_op = 'UPDATE' and old.request_details -> 'extras' is not distinct from new.request_details -> 'extras' then return null; end if;
  -- the old extras changed by a flow that knows only them (a change request, an older caller)
  v_want := jsonb_build_object('baby_seat', coalesce((new.request_details -> 'extras' ->> 'baby_seats')::integer, 0),
                               'winter_tire', case when coalesce((new.request_details -> 'extras' ->> 'winter_tire')::boolean, false) then 1 else 0 end);
  select jsonb_build_object('baby_seat', coalesce(sum(ba.quantity) filter (where a.code = 'baby_seat'), 0),
                            'winter_tire', coalesce(sum(ba.quantity) filter (where a.code = 'winter_tire'), 0))
    into v_have from booking_addons ba join addons a on a.id = ba.addon_id
   where ba.booking_id = new.id and ba.status in ('pending', 'confirmed');
  if v_have = v_want then return null; end if;
  select coalesce(jsonb_agg(jsonb_build_object('addon_id', ba.addon_id, 'quantity', ba.quantity, 'hours', ba.hours)), '[]'::jsonb) into v_input
    from booking_addons ba join addons a on a.id = ba.addon_id
   where ba.booking_id = new.id and ba.status in ('pending', 'confirmed') and not ba.after_booking and a.code not in ('baby_seat', 'winter_tire');
  if (v_want ->> 'baby_seat')::integer > 0 then v_input := v_input || jsonb_build_object('code', 'baby_seat', 'quantity', (v_want ->> 'baby_seat')::integer); end if;
  if (v_want ->> 'winter_tire')::integer > 0 then v_input := v_input || jsonb_build_object('code', 'winter_tire', 'quantity', 1); end if;
  perform app.booking_addons_set(new.id, null, v_input, case when new.source = 'web' then 'request' else 'staff' end, false);
  return null;
end $$;
create trigger bookings_addons_insert after insert on bookings for each row execute function app.bookings_addons_after();
create trigger bookings_addons_extras after update of request_details on bookings for each row execute function app.bookings_addons_after();

-- the creating functions take "addons": [{"addon_id" or "code", "quantity", "hours"}]
create or replace function app.addons_context_begin(p jsonb, p_via text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_in jsonb := app.addons_input(p);
  v_seats integer := 0;
  v_winter boolean := false;
  e jsonb;
  v_code text;
begin
  for e in select value from jsonb_array_elements(v_in) loop
    v_code := coalesce(e ->> 'code', (select a.code from addons a where a.id::text = e ->> 'addon_id'));
    if v_code = 'baby_seat' then v_seats := coalesce(nullif(e ->> 'quantity', '')::integer, 1); end if;
    if v_code = 'winter_tire' and coalesce(nullif(e ->> 'quantity', '')::integer, 1) > 0 then v_winter := true; end if;
  end loop;
  perform set_config('app.addons_pending', jsonb_build_object('items', v_in, 'via', p_via)::text, true);
  -- the old extras say the same, for the request's record and the flows that read them
  return (coalesce(p, '{}'::jsonb) - 'addons') || jsonb_build_object('extras', coalesce(p -> 'extras', '{}'::jsonb)
           || jsonb_build_object('winter_tire', v_winter, 'baby_seats', v_seats));
end $$;

alter function app.submit_booking_request(jsonb, inet, text, uuid) rename to submit_booking_request_pre0066;
create or replace function app.submit_booking_request(p_request jsonb, p_ip inet default null, p_user_agent text default null, p_user uuid default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb;
begin
  v_out := app.submit_booking_request_pre0066(app.addons_context_begin(p_request, 'request'), p_ip, p_user_agent, p_user);
  perform set_config('app.addons_pending', '', true);
  return v_out;
end $$;

alter function app.manual_rental_create(uuid, jsonb) rename to manual_rental_create_pre0066;
create or replace function app.manual_rental_create(p_by uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb;
begin
  v_out := app.manual_rental_create_pre0066(p_by, app.addons_context_begin(p, 'manual'));
  perform set_config('app.addons_pending', '', true);
  return v_out;
end $$;

alter function app.staff_quote_request(uuid, jsonb) rename to staff_quote_request_pre0066;
create or replace function app.staff_quote_request(p_by uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb;
begin
  v_out := app.staff_quote_request_pre0066(p_by, app.addons_context_begin(p, 'quote'));
  perform set_config('app.addons_pending', '', true);
  return v_out;
end $$;

-- the offer and review screen (Admin and assistants): "addons" with the other changes
alter function app.admin_apply_booking_edit(uuid, uuid, jsonb) rename to admin_apply_booking_edit_pre0066;
create or replace function app.admin_apply_booking_edit(p_admin uuid, p_booking uuid, p jsonb)
returns void language plpgsql security definer set search_path = public, app as $$
begin
  perform app.admin_apply_booking_edit_pre0066(p_admin, p_booking, p);
  if jsonb_typeof(p -> 'addons') = 'array' then
    perform app.booking_addons_set(p_booking, p_admin, p -> 'addons', 'offer', true);
  end if;
end $$;

alter function app.admin_booking_json(uuid) rename to admin_booking_json_pre0066;
create or replace function app.admin_booking_json(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.admin_booking_json_pre0066(p_booking) || jsonb_build_object('addons', app.booking_addons_json(p_booking))
$$;

-- ================================================================ 7. after booking: the renter portal, staff confirm and remove
create or replace function app.addon_charge_facts(p_row uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  ba booking_addons;
  b bookings;
  l jsonb;
begin
  select * into ba from booking_addons where id = p_row;
  select * into b from bookings where id = ba.booking_id;
  l := app.addon_line(app.booking_addons_spec_row(ba.id), b.billable_days, b.hst_bps);
  return jsonb_build_object('booking_addon_id', ba.id, 'booking_id', b.id, 'booking_number', b.booking_number, 'name', ba.name, 'status', ba.status,
    'amount_cents', (l ->> 'amount_cents')::bigint + (l ->> 'hst_cents')::bigint, 'subtotal_cents', (l ->> 'amount_cents')::bigint,
    'hst_cents', (l ->> 'hst_cents')::bigint, 'paid', ba.payment_id is not null or ba.line_item_id is not null,
    'card', (select jsonb_build_object('method_id', s.processor_method_id, 'customer_id', s.processor_customer_id, 'brand', pm.card_brand, 'last4', pm.card_last4)
               from payment_methods pm join payment_method_secrets s on s.payment_method_id = pm.id
              where pm.id = b.card_on_file_id and s.processor_method_id is not null));
end $$;

create or replace function app.booking_addons_spec_row(p_row uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('booking_addon_id', ba.id, 'addon_id', ba.addon_id, 'code', a.code, 'name', ba.name, 'fee_type_code', ba.fee_type_code,
           'pricing_unit', ba.pricing_unit, 'unit_price_cents', ba.unit_price_cents, 'max_days', ba.max_days, 'cap_cents', ba.cap_cents,
           'min_hours', ba.min_hours, 'hst_applies', ba.hst_applies, 'quantity', ba.quantity, 'hours', ba.hours, 'status', 'confirmed')
    from booking_addons ba join addons a on a.id = ba.addon_id where ba.id = p_row
$$;

-- the renter adds an add-on to a confirmed booking (until the cutoff): one waiting for staff is only asked for; the
-- others return what to charge on the Card on File
create or replace function app.booking_addon_buy(p_booking uuid, p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  a addons;
  s program_settings := app.settings();
  r jsonb;
  i jsonb;
  v_id uuid;
  v_until timestamptz;
begin
  perform app.assert_booking_renter(p_booking, p_by);
  select * into b from bookings where id = p_booking for update;
  if b.status <> 'confirmed' or b.booking_type = 'owner' then
    raise exception 'Add-ons are added to a confirmed booking before pickup' using errcode = '23514';
  end if;
  select * into a from addons where id::text = p ->> 'addon_id' or code = p ->> 'code' limit 1;
  if a.id is null or not a.active then raise exception 'That add-on is not offered at the moment' using errcode = '23514'; end if;
  v_until := b.pickup_at - make_interval(hours => greatest(s.addon_portal_cutoff_hours, a.lead_time_hours));
  if now() > v_until then
    raise exception '% could be added until %. Call us and we will see what we can do.', a.name, app.fmt_at(v_until) using errcode = '23514';
  end if;
  if exists (select 1 from booking_addons x where x.booking_id = b.id and x.addon_id = a.id and x.status in ('pending', 'confirmed')) then
    raise exception '% is already on this booking. Message us to change it.', a.name using errcode = '23514';
  end if;
  r := app.addons_resolve(b.vehicle_id, b.pickup_at, b.return_at,
         jsonb_build_array(jsonb_build_object('addon_id', a.id, 'quantity', coalesce(nullif(p ->> 'quantity', '')::integer, 1), 'hours', p -> 'hours')),
         'renter', b.id, true);
  i := r -> 'items' -> 0;
  insert into booking_addons (booking_id, addon_id, quantity, hours, name, fee_type_code, pricing_unit, unit_price_cents, max_days, cap_cents,
                              min_hours, hst_applies, status, added_via, added_by, after_booking, confirmed_at)
  values (b.id, a.id, (i ->> 'quantity')::integer, (i ->> 'hours')::numeric, i ->> 'name', i ->> 'fee_type_code', i ->> 'pricing_unit',
          (i ->> 'unit_price_cents')::bigint, (i ->> 'max_days')::integer, (i ->> 'cap_cents')::bigint, (i ->> 'min_hours')::numeric,
          (i ->> 'hst_applies')::boolean, case when a.needs_confirmation then 'pending' else 'confirmed' end, 'portal', p_by, true,
          case when not a.needs_confirmation then now() end)
  returning id into v_id;
  if a.needs_confirmation then
    perform app.raise_task(p_type => 'addon_confirm', p_title => format('Confirm %s for %s', a.name, b.booking_number),
      p_detail => format('The renter asked for %s after booking. Confirm it (the card on file is charged) or decline it.', a.name),
      p_booking => b.id, p_renter => b.renter_id, p_related_table => 'booking_addons', p_related_id => v_id,
      p_dedupe => 'addon_confirm:' || v_id);
  end if;
  return app.addon_charge_facts(v_id);
end $$;

-- an add-on bought after booking is paid: the payment and its line (p_processor null: no card; the line waits unpaid
-- and Finance collects it)
create or replace function app.booking_addon_paid(p_row uuid, p_by uuid, p_processor jsonb, p_amount_cents bigint) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ba booking_addons;
  b bookings;
  l jsonb;
  v_pay uuid;
  v_line uuid;
  v_total bigint;
begin
  if p_processor = 'null'::jsonb then p_processor := null; end if;
  select * into ba from booking_addons where id = p_row for update;
  if ba.id is null then raise exception 'Add-on not found' using errcode = 'P0002'; end if;
  select * into b from bookings where id = ba.booking_id for update;
  if p_by is not null and not (app.is_booking_renter(b.id, p_by) or app.user_is_staff(p_by)) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if ba.line_item_id is not null then
    return jsonb_build_object('ok', true, 'already', true, 'booking_addon_id', ba.id, 'payment_id', ba.payment_id);
  end if;
  if ba.status <> 'confirmed' or not ba.after_booking then
    return jsonb_build_object('ok', false, 'message', 'This add-on is not waiting for payment.');
  end if;
  l := app.addon_line(app.booking_addons_spec_row(ba.id), b.billable_days, b.hst_bps);
  v_total := (l ->> 'amount_cents')::bigint + (l ->> 'hst_cents')::bigint;
  if p_processor is not null then
    if p_amount_cents is distinct from v_total then
      return jsonb_build_object('ok', false, 'reason', 'amount_mismatch', 'message', 'The amount does not equal the price of the add-on.', 'action', 'refund_payment');
    end if;
    insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, payment_method_id, processed_at, created_by)
    values (b.id, b.renter_id, 'addon', 'charge', 'card', v_total, 'succeeded', b.card_on_file_id, now(), p_by)
    returning id into v_pay;
    insert into payment_processor_details (payment_id, processor, processor_payment_id, processor_charge_id, receipt_url)
    values (v_pay, coalesce(nullif(p_processor ->> 'processor', ''), 'stripe'), nullif(p_processor ->> 'payment_id', ''), p_processor ->> 'charge_id', p_processor ->> 'receipt_url');
  end if;
  insert into booking_line_items (booking_id, charge_type, description, quantity, unit_amount_cents, amount_cents, hst_applies, hst_cents,
                                  revenue_class, stage, payment_id, booking_addon_id, created_by)
  values (b.id, l ->> 'charge_type', l ->> 'description', (l ->> 'quantity')::numeric, (l ->> 'unit_amount_cents')::bigint, (l ->> 'amount_cents')::bigint,
          (l ->> 'hst_applies')::boolean, (l ->> 'hst_cents')::bigint, 'company_only', 'booking', v_pay, ba.id, p_by)
  returning id into v_line;
  update booking_addons set payment_id = v_pay, line_item_id = v_line where id = ba.id;
  if v_pay is null then
    perform app.raise_task(p_type => 'addon_payment', p_title => format('Collect %s for %s (%s)', app.fmt_money(v_total), ba.name, b.booking_number),
      p_detail => 'The renter has no card on file. Ask them to pay and record the payment on the booking.',
      p_booking => b.id, p_renter => b.renter_id, p_related_table => 'booking_addons', p_related_id => ba.id, p_dedupe => 'addon_payment:' || ba.id);
  end if;
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null, format('Add-on added: %s', ba.name), p_by, null,
    jsonb_build_object('addon', ba.name, 'booking_addon_id', ba.id, 'payment_id', v_pay, 'total_cents', v_total));
  return jsonb_build_object('ok', true, 'booking_addon_id', ba.id, 'payment_id', v_pay, 'line_item_id', v_line, 'total_cents', v_total);
end $$;

-- the card was declined: the add-on is not added
create or replace function app.booking_addon_failed(p_row uuid, p_by uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  update booking_addons set status = 'cancelled', cancelled_at = now(), cancelled_by = p_by, cancel_reason = coalesce(nullif(p_reason, ''), 'The card was declined')
   where id = p_row and after_booking and line_item_id is null and status in ('pending', 'confirmed')
     and (p_by is null or app.is_booking_renter(booking_id, p_by) or app.user_is_staff(p_by));
end $$;

-- staff confirm or decline an add-on that waits for confirmation
create or replace function app.booking_addon_confirm(p_by uuid, p_row uuid, p_ok boolean, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ba booking_addons;
  b bookings;
begin
  if not app.user_is_staff(p_by) then raise exception 'Only staff confirm an add-on' using errcode = '42501'; end if;
  select * into ba from booking_addons where id = p_row for update;
  if ba.id is null or ba.status <> 'pending' then raise exception 'This add-on is not waiting for confirmation' using errcode = '23514'; end if;
  select * into b from bookings where id = ba.booking_id;
  if p_ok then
    update booking_addons set status = 'confirmed', confirmed_by = p_by, confirmed_at = now() where id = ba.id;
  else
    update booking_addons set status = 'declined', cancelled_at = now(), cancelled_by = p_by, cancel_reason = coalesce(nullif(btrim(p_note), ''), 'Declined by staff')
     where id = ba.id;
  end if;
  perform app.resolve_tasks(array['addon_confirm'], b.id, p_by, case when p_ok then 'Confirmed' else 'Declined' end, false);
  -- on a request or offer the price follows at once
  if not ba.after_booking and (b.status in ('requested', 'tentative') or (b.dates_provisional and b.status in ('confirmed', 'on_rent'))) then
    perform app.sync_booking_price(b.id);
  end if;
  return app.addon_charge_facts(ba.id) || jsonb_build_object('charge_now', p_ok and ba.after_booking);
end $$;

-- staff remove an add-on from a booking: unpaid, its line is voided; paid, a refund for it awaits approval
create or replace function app.booking_addon_remove(p_by uuid, p_row uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ba booking_addons;
  b bookings;
  li booking_line_items;
  v_paid boolean;
  v_pay uuid;
  v_refund uuid;
begin
  if not app.user_is_staff(p_by) then raise exception 'Only staff remove an add-on' using errcode = '42501'; end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give the reason' using errcode = '22023'; end if;
  select * into ba from booking_addons where id = p_row for update;
  if ba.id is null or ba.status not in ('pending', 'confirmed') then raise exception 'This add-on is not on the booking' using errcode = '23514'; end if;
  select * into b from bookings where id = ba.booking_id for update;
  if b.status in ('requested', 'tentative') then
    update booking_addons set status = 'cancelled', cancelled_at = now(), cancelled_by = p_by, cancel_reason = p_reason where id = ba.id;
    perform app.addons_sync_extras(b.id);
    perform app.sync_booking_price(b.id);
    return jsonb_build_object('ok', true, 'refund_id', null);
  end if;
  if b.status not in ('offered', 'pending_payment', 'confirmed', 'on_rent') then
    raise exception 'Booking % is %', b.booking_number, b.status using errcode = '23514';
  end if;
  if b.status in ('offered', 'pending_payment') then
    raise exception 'An offer is out: withdraw it to change the add-ons' using errcode = '23514';
  end if;
  select * into li from booking_line_items where id = ba.line_item_id and voided_at is null;
  v_paid := li.id is not null and (li.payment_id is not null or not ba.after_booking);
  update booking_addons set status = 'cancelled', cancelled_at = now(), cancelled_by = p_by, cancel_reason = p_reason where id = ba.id;
  perform app.addons_sync_extras(b.id);
  if li.id is not null and not v_paid then
    update booking_line_items set voided_at = now(), voided_by = p_by, void_reason = 'Add-on removed: ' || p_reason where id = li.id;
    perform app.resolve_tasks(array['addon_payment'], b.id, p_by, 'Add-on removed', true);
  elsif v_paid then
    v_pay := coalesce(li.payment_id, (select p.id from payments p where p.booking_id = b.id and p.purpose = 'booking_total' and p.kind = 'charge'
                                        and p.status = 'succeeded' order by p.processed_at desc nulls last limit 1));
    insert into refunds (booking_id, payment_id, reason, refund_bps, amount_cents, status, requested_by, note)
    values (b.id, v_pay, 'addon_removed', 10000, li.amount_cents + li.hst_cents, 'pending_approval', p_by, 'Add-on removed: ' || ba.name || '. ' || p_reason)
    returning id into v_refund;
    insert into refund_allocations (refund_id, line_item_id, amount_cents, hst_cents) values (v_refund, li.id, li.amount_cents, li.hst_cents);
  end if;
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null, format('Add-on removed: %s. %s', ba.name, p_reason), p_by, 'staff',
    jsonb_build_object('addon', ba.name, 'booking_addon_id', ba.id, 'refund_id', v_refund));
  return jsonb_build_object('ok', true, 'refund_id', v_refund);
end $$;

-- ================================================================ 8. tasks: prepare, confirm, stock
create or replace function app.addon_prep_task(p_row uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  ba booking_addons;
  a addons;
  b bookings;
begin
  select * into ba from booking_addons where id = p_row;
  select * into a from addons where id = ba.addon_id;
  select * into b from bookings where id = ba.booking_id;
  if not a.needs_prep or ba.status <> 'confirmed' or b.status not in ('confirmed', 'on_rent') then return; end if;
  if ba.after_booking and ba.line_item_id is null then return; end if;
  perform app.raise_task(p_type => 'addon_prep',
    p_title => format('Get ready: %s for %s, %s', ba.name || case when ba.pricing_unit = 'per_hour' then ' (' || trim(trailing '.' from trim(trailing '0' from coalesce(ba.hours, ba.min_hours, 1)::text)) || ' hours)' else '' end,
                      b.booking_number, app.fmt_at(b.pickup_at)),
    p_detail => coalesce(a.prep_note, 'Prepare it before pickup.'), p_booking => b.id, p_vehicle => b.vehicle_id, p_renter => b.renter_id,
    p_related_table => 'booking_addons', p_related_id => ba.id,
    p_due_at => greatest(now(), b.pickup_at - make_interval(hours => greatest(a.lead_time_hours, 2))),
    p_dedupe => 'addon_prep:' || ba.id);
end $$;

create or replace function app.booking_addons_row_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status = 'confirmed' then
    perform app.addon_prep_task(new.id);
  elsif new.status in ('cancelled', 'declined') and (tg_op = 'INSERT' or old.status in ('pending', 'confirmed')) then
    update tasks set status = 'cancelled', completed_at = now(), completed_by = new.cancelled_by, completion_note = 'Add-on removed'
     where dedupe_key in ('addon_prep:' || new.id, 'addon_confirm:' || new.id) and status in ('open', 'in_progress', 'waiting');
  end if;
  return null;
end $$;
create trigger booking_addons_row_after after insert or update of status, line_item_id on booking_addons
  for each row execute function app.booking_addons_row_after();

-- the booking's own steps: an offer sent confirms what waited; a confirmed booking gets its prep tasks and a stock
-- check; a booking that ends early takes its add-on tasks with it
create or replace function app.bookings_addons_status() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  ba record;
begin
  if new.status = old.status then return null; end if;
  if new.status = 'offered' then
    update booking_addons set status = 'confirmed', confirmed_at = now(), confirmed_by = coalesce(confirmed_by, app.uid())
     where booking_id = new.id and status = 'pending' and not after_booking;
  elsif new.status = 'confirmed' then
    for ba in select x.id, x.quantity, x.name, a.stock_count, a.id as addon_id from booking_addons x join addons a on a.id = x.addon_id
               where x.booking_id = new.id and x.status = 'confirmed' loop
      perform app.addon_prep_task(ba.id);
      if ba.stock_count is not null and ba.quantity + app.addon_held(ba.addon_id, new.pickup_at, new.return_at, new.id) > ba.stock_count then
        perform app.raise_task(p_type => 'addon_stock', p_title => format('Not enough %s for %s', ba.name, new.booking_number),
          p_detail => format('%s has %s in stock and more are booked over these dates. Find another or tell the renter.', ba.name, ba.stock_count),
          p_booking => new.id, p_vehicle => new.vehicle_id, p_dedupe => 'addon_stock:' || ba.id);
      end if;
    end loop;
  elsif new.status in ('cancelled', 'no_show', 'declined', 'expired') then
    perform app.resolve_tasks(array['addon_prep', 'addon_confirm', 'addon_stock'], new.id, null, 'The booking ended', true);
  end if;
  return null;
end $$;
create trigger bookings_addons_status after update of status on bookings for each row execute function app.bookings_addons_status();

-- ================================================================ 9. money: cancellation, refunds, commission base, statements
-- paid add-ons count in what the renter paid
select pg_temp.patch_fn('app.booking_paid_cents(uuid)'::regprocedure,
  $o$p.purpose in ('booking_total', 'extension')$o$, $n$p.purpose in ('booking_total', 'extension', 'addon')$n$);

-- an add-on removed and refunded never changes a commission (the base is the rental charge)
select pg_temp.patch_fn('app.sales_revenue_cents(uuid)'::regprocedure,
  $o$where q.refund_id = r.id);$o$, $n$where q.refund_id = r.id) and r.reason <> 'addon_removed';$n$);
select pg_temp.patch_fn('app.commission_base_cents(uuid)'::regprocedure,
  $o$where q.refund_id = r.id);$o$, $n$where q.refund_id = r.id) and r.reason <> 'addon_removed';$n$);

-- the add-ons a cancellation at p_at keeps: marked non-refundable after their notice, paid, notice started; never when
-- CarmaCars cancels
create or replace function app.addons_kept_on_cancel(p_booking uuid, p_at timestamptz, p_reason text) returns table (booking_addon_id uuid, kept_cents bigint)
language sql stable security definer set search_path = public, app as $$
  select ba.id, li.amount_cents + li.hst_cents
    from booking_addons ba join addons a on a.id = ba.addon_id join bookings b on b.id = ba.booking_id
    join booking_line_items li on li.id = ba.line_item_id and li.voided_at is null
   where ba.booking_id = p_booking and ba.status = 'confirmed' and a.non_refundable_after_lead
     and coalesce(p_reason, 'renter_request') not in ('carmacars_no_vehicle', 'driver_not_verifiable')
     and p_at >= b.pickup_at - make_interval(hours => a.lead_time_hours)
     and (li.payment_id is not null or not ba.after_booking)
$$;

alter function app.preview_cancellation(uuid, timestamptz, text) rename to preview_cancellation_pre0066;
create or replace function app.preview_cancellation(p_booking uuid, p_at timestamptz default now(), p_reason text default 'renter_request')
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.preview_cancellation_pre0066(p_booking, p_at, p_reason);
  b bookings;
  v_kept bigint;
  r record;
  v_received timestamptz;
begin
  select coalesce(sum(k.kept_cents), 0) into v_kept from app.addons_kept_on_cancel(p_booking, p_at, p_reason) k;
  if v_kept = 0 then return v || jsonb_build_object('addons_kept_cents', 0, 'paid_cents', (v ->> 'total_paid_cents')::bigint); end if;
  select * into b from bookings where id = p_booking;
  v_received := (v ->> 'received_at')::timestamptz;
  -- the tier applies to what can be refunded; the kept add-ons are retained in full
  select * into r from public.calc_cancellation((v ->> 'booking_made_at')::timestamptz, v_received, b.pickup_at, b.booking_type = 'non_refundable',
                                                greatest((v ->> 'total_paid_cents')::bigint - v_kept, 0),
                                                p_reason in ('carmacars_no_vehicle', 'driver_not_verifiable'));
  return v || jsonb_build_object('paid_cents', (v ->> 'total_paid_cents')::bigint,
    'total_paid_cents', greatest((v ->> 'total_paid_cents')::bigint - v_kept, 0),
    'refund_cents', r.refund_cents, 'retained_cents', r.retained_cents + v_kept, 'addons_kept_cents', v_kept,
    'addons_kept', (select coalesce(jsonb_agg(ba.name), '[]'::jsonb) from app.addons_kept_on_cancel(p_booking, p_at, p_reason) k
                      join booking_addons ba on ba.id = k.booking_addon_id));
end $$;

create or replace function app.booking_cancellations_addons() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  update booking_addons set kept_on_cancel = true
   where id in (select k.booking_addon_id from app.addons_kept_on_cancel(new.booking_id, new.received_at, new.reason) k);
  return null;
end $$;
create trigger booking_cancellations_addons after insert on booking_cancellations for each row execute function app.booking_cancellations_addons();

-- the refund of a cancellation leaves out the add-ons it keeps
select pg_temp.patch_fn('app.allocate_refund(uuid)'::regprocedure,
  $o$     and li.charged_to_renter and li.voided_at is null;$o$,
  $n$     and li.charged_to_renter and li.voided_at is null
     and not exists (select 1 from booking_addons ba where ba.id = li.booking_addon_id and ba.kept_on_cancel);$n$);

-- prepaid fuel: no fuel charge at check-in
create or replace function app.booking_has_prepaid_fuel(p_booking uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from booking_addons ba join addons a on a.id = ba.addon_id
                  where ba.booking_id = p_booking and ba.status = 'confirmed' and a.prepaid_fuel)
$$;
select pg_temp.patch_fn('app.assess_check_in(uuid, jsonb, uuid)'::regprocedure,
  $o$    if coalesce((f ->> 'no_fuel_charge')::boolean, false) or v_short = 0 then$o$,
  $n$    if coalesce((f ->> 'no_fuel_charge')::boolean, false) or v_short = 0 or app.booking_has_prepaid_fuel(p_booking) then$n$);

-- the company statement: Add-ons as its own income line
select pg_temp.patch_fn('app.company_statement_sections(date)'::regprocedure,
  $o$    app.csr('Coverage sold', (v_fees ->> '4110')::bigint, '4110'),$o$,
  $n$    app.csr('Add-ons', (v_fees ->> '4150')::bigint, '4150'),
    app.csr('Coverage sold', (v_fees ->> '4110')::bigint, '4110'),$n$);

-- ================================================================ 10. reads: field staff, the renter, the catalogue
alter function app.field_read(uuid, text, jsonb) rename to field_read_pre0066;
create or replace function app.field_read(p_user uuid, p_what text, p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  x jsonb := app.field_read_pre0066(p_user, p_what, p);
  v_b uuid;
begin
  if p_what = 'job' and x is not null and (x #>> '{booking,id}') is not null then
    v_b := (x #>> '{booking,id}')::uuid;
    x := jsonb_set(x, '{booking,addons}', coalesce((select jsonb_agg(jsonb_build_object('name', i ->> 'name', 'quantity', (i ->> 'quantity')::integer,
                 'hours', i -> 'hours', 'status', i ->> 'status', 'handover_note', i ->> 'handover_note', 'prepaid_fuel', (i ->> 'prepaid_fuel')::boolean))
               from jsonb_array_elements(app.booking_addons_json(v_b)) i where i ->> 'status' = 'confirmed'), '[]'::jsonb));
    x := jsonb_set(x, '{booking,prepaid_fuel}', to_jsonb(app.booking_has_prepaid_fuel(v_b)));
  end if;
  return x;
end $$;

-- the add-ons offered for a car (and dates, for what is left): the car page, the request, the portal
create or replace function app.addons_for_car(p_vehicle uuid, p_pickup timestamptz default null, p_return timestamptz default null, p_booking uuid default null)
returns jsonb language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'code', a.code, 'name', a.name, 'description', a.description, 'photo_path', a.photo_path,
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

create or replace function public.addons_for_car(p_vehicle uuid, p_pickup timestamptz default null, p_return timestamptz default null)
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
begin
  if coalesce(pg_catalog.current_setting('role', true), '') in ('anon', 'authenticated') and not app.is_staff()
     and not exists (select 1 from public_vehicle_listings l where l.vehicle_id = p_vehicle) then
    return '[]'::jsonb;
  end if;
  return app.addons_for_car(p_vehicle, p_pickup, p_return, null);
end $$;

-- the renter's booking: its add-ons, what they may still add and until when
create or replace function app.my_booking_addons(p_booking uuid, p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  s program_settings := app.settings();
begin
  perform app.assert_booking_renter(p_booking, p_by);
  select * into b from bookings where id = p_booking;
  return jsonb_build_object('items', app.booking_addons_json(b.id),
    'can_add', b.status = 'confirmed' and b.booking_type <> 'owner' and now() < b.pickup_at - make_interval(hours => s.addon_portal_cutoff_hours),
    'cutoff_hours', s.addon_portal_cutoff_hours, 'add_until', b.pickup_at - make_interval(hours => s.addon_portal_cutoff_hours),
    'options', case when b.status = 'confirmed' then
                 (select coalesce(jsonb_agg(o || jsonb_build_object('add_until', b.pickup_at - make_interval(hours => greatest(s.addon_portal_cutoff_hours, (o ->> 'lead_time_hours')::integer)))), '[]'::jsonb)
                    from jsonb_array_elements(app.addons_for_car(b.vehicle_id, b.pickup_at, b.return_at, b.id)) o
                   where not exists (select 1 from booking_addons x where x.booking_id = b.id and x.addon_id = (o ->> 'id')::uuid and x.status in ('pending', 'confirmed')))
               else '[]'::jsonb end,
    'days', b.billable_days, 'hst_bps', b.hst_bps,
    'card', (select jsonb_build_object('brand', pm.card_brand, 'last4', pm.card_last4) from payment_methods pm where pm.id = b.card_on_file_id));
end $$;

-- the renter's actions (the portal's server actions, service role; p_by is the renter)
create or replace function public.server_my_booking_addons(p_booking uuid, p_by uuid) returns jsonb
language sql security definer set search_path = public, app as $$ select app.my_booking_addons(p_booking, p_by) $$;
create or replace function public.server_booking_addon_buy(p_booking uuid, p_by uuid, p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.booking_addon_buy(p_booking, p_by, p) $$;
create or replace function public.server_booking_addon_paid(p_row uuid, p_by uuid, p_processor jsonb, p_amount_cents bigint) returns jsonb
language sql security definer set search_path = public, app as $$ select app.booking_addon_paid(p_row, p_by, p_processor, p_amount_cents) $$;
create or replace function public.server_booking_addon_failed(p_row uuid, p_by uuid, p_reason text) returns void
language sql security definer set search_path = public, app as $$ select app.booking_addon_failed(p_row, p_by, p_reason) $$;

-- ================================================================ 11. Admin > Settings > Add-ons, and Fleet's stock
create or replace function app.addons_admin_read(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not (app.user_is_admin(p_user) or app.user_is_staff(p_user) or app.user_is_field(p_user)) then
    raise exception 'Add-ons are for staff' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'may_edit', app.user_is_admin(p_user), 'may_stock', app.user_runs_fleet(p_user),
    'cutoff_hours', (app.settings()).addon_portal_cutoff_hours,
    'classes', (select coalesce(jsonb_agg(c order by c), '[]'::jsonb) from unnest(enum_range(null::vehicle_class)) c),
    'fuel_types', (select coalesce(jsonb_agg(f order by f), '[]'::jsonb) from unnest(enum_range(null::fuel_type)) f),
    'vehicles', (select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id), 'plate', v.plate) order by v.make, v.model), '[]'::jsonb)
                   from vehicles v where v.retired_at is null),
    'addons', (select coalesce(jsonb_agg(to_jsonb(a) || jsonb_build_object(
                 'booked_next_30_days', (select coalesce(sum(ba.quantity), 0) from booking_addons ba join bookings b on b.id = ba.booking_id
                                          where ba.addon_id = a.id and ba.status in ('pending', 'confirmed') and b.status in ('confirmed', 'on_rent')
                                            and b.pickup_at < now() + interval '30 days' and b.return_at > now()),
                 'out_now', case when a.stock_count is null then null else app.addon_held(a.id, now(), now() + interval '1 minute') end)
                 order by a.sort_order, a.name), '[]'::jsonb) from addons a));
end $$;

create or replace function app.addon_save(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a addons;
  v_admin boolean := app.user_is_admin(p_user);
  v_id uuid := nullif(p ->> 'id', '')::uuid;
  v_keys text[] := array['name', 'description', 'photo_path', 'pricing_unit', 'price_cents', 'price_overrides', 'max_days', 'cap_cents', 'min_hours',
                         'hst_applies', 'active', 'vehicle_classes', 'vehicle_ids', 'excluded_vehicle_ids', 'excluded_fuel_types', 'available_months',
                         'lead_time_hours', 'stock_count', 'max_per_booking', 'needs_confirmation', 'needs_prep', 'prep_note', 'handover_note',
                         'prepaid_fuel', 'non_refundable_after_lead', 'sort_order'];
  k text;
  r jsonb;
begin
  if not v_admin then
    if not app.user_runs_fleet(p_user) then raise exception 'Add-ons are set by an Admin' using errcode = '42501'; end if;
    -- Fleet: stock only
    if v_id is null or exists (select 1 from jsonb_object_keys(p - 'id') x where x <> 'stock_count') then
      raise exception 'Fleet changes the stock of an add-on; the rest is set by an Admin' using errcode = '42501';
    end if;
  end if;
  if v_id is null then
    if nullif(btrim(coalesce(p ->> 'name', '')), '') is null then raise exception 'Give the add-on a name' using errcode = '22023'; end if;
    insert into addons (code, name, pricing_unit, price_cents, active, updated_by)
    values (coalesce(nullif(p ->> 'code', ''), left(trim(both '_' from regexp_replace(lower(p ->> 'name'), '[^a-z0-9]+', '_', 'g')), 30) || '_' || substr(md5(random()::text), 1, 4)),
            btrim(p ->> 'name'), coalesce(nullif(p ->> 'pricing_unit', ''), 'per_trip'), nullif(p ->> 'price_cents', '')::bigint,
            false, p_user)
    returning * into a;
  else
    select * into a from addons where id = v_id for update;
    if a.id is null then raise exception 'Add-on not found' using errcode = 'P0002'; end if;
  end if;
  -- every key given, through jsonb_populate_record so the column types and checks apply
  r := to_jsonb(a);
  foreach k in array v_keys loop
    if p ? k then r := jsonb_set(r, array[k], case when p -> k = '""'::jsonb then 'null'::jsonb else p -> k end); end if;
  end loop;
  if (r ->> 'pricing_unit') <> 'per_day' then r := jsonb_set(r, '{max_days}', 'null'); end if;
  if (r ->> 'pricing_unit') <> 'per_hour' then r := jsonb_set(r, '{min_hours}', 'null'); end if;
  if coalesce((r ->> 'active')::boolean, false) and (r ->> 'price_cents') is null then
    raise exception 'Set a price before turning it on' using errcode = '22023';
  end if;
  update addons x set (name, description, photo_path, pricing_unit, price_cents, price_overrides, max_days, cap_cents, min_hours, hst_applies, active,
                       vehicle_classes, vehicle_ids, excluded_vehicle_ids, excluded_fuel_types, available_months, lead_time_hours, stock_count,
                       max_per_booking, needs_confirmation, needs_prep, prep_note, handover_note, prepaid_fuel, non_refundable_after_lead, sort_order, updated_by)
    = (select y.name, nullif(btrim(y.description), ''), nullif(btrim(y.photo_path), ''), y.pricing_unit, y.price_cents, y.price_overrides, y.max_days, y.cap_cents,
              y.min_hours, y.hst_applies, y.active, y.vehicle_classes, y.vehicle_ids, y.excluded_vehicle_ids, y.excluded_fuel_types, y.available_months,
              y.lead_time_hours, y.stock_count, y.max_per_booking, y.needs_confirmation, y.needs_prep, nullif(btrim(y.prep_note), ''),
              nullif(btrim(y.handover_note), ''), y.prepaid_fuel, y.non_refundable_after_lead, y.sort_order, p_user
         from jsonb_populate_record(null::addons, r) y)
   where x.id = a.id
  returning * into a;
  return to_jsonb(a);
end $$;

-- the doors: Admin and staff screens
create or replace function app.ops0066(p_user uuid, p_call text, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  case p_name
  when 'addons' then return app.addons_admin_read(p_user);
  when 'addon_save' then return app.addon_save(p_user, p);
  when 'addons_for_car' then
    if not app.user_is_sales_staff(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
    return app.addons_for_car((p ->> 'vehicle_id')::uuid, nullif(p ->> 'pickup_at', '')::timestamptz, nullif(p ->> 'return_at', '')::timestamptz,
                              nullif(p ->> 'booking', '')::uuid);
  when 'booking_addon_confirm' then return app.booking_addon_confirm(p_user, (p ->> 'id')::uuid, coalesce((p ->> 'ok')::boolean, true), p ->> 'note');
  when 'booking_addon_remove' then return app.booking_addon_remove(p_user, (p ->> 'id')::uuid, p ->> 'reason');
  when 'booking_addon_paid' then return app.booking_addon_paid((p ->> 'id')::uuid, p_user, p -> 'processor', nullif(p ->> 'amount_cents', '')::bigint);
  when 'booking_addon_failed' then perform app.booking_addon_failed((p ->> 'id')::uuid, p_user, p ->> 'reason'); return jsonb_build_object('ok', true);
  else raise exception 'Unknown action %', p_name using errcode = '22023';
  end case;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0066;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
begin
  if (p_call in ('va_read', 'admin_read', 'ops_read', 'field_read') and p_name in ('addons', 'addons_for_car'))
     or (p_call in ('va_do', 'admin_do', 'ops_do') and p_name in ('addon_save', 'booking_addon_confirm', 'booking_addon_remove', 'booking_addon_paid', 'booking_addon_failed')) then
    if p_ ? '_va' then perform set_config('app.va_active', coalesce(p_ ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.ops0066(p_user, p_call, p_name, p_ - '_va');
  end if;
  return app.door_pre0066(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ 12. privileges
-- Each renamed function keeps its privileges; the function in its place gets the same.
do $$
declare
  r record;
  v_new regprocedure;
  g text;
begin
  for r in select p.oid, m.new_name, oidvectortypes(p.proargtypes) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             join (values ('door_pre0066', 'door'), ('submit_booking_request_pre0066', 'submit_booking_request'),
                          ('manual_rental_create_pre0066', 'manual_rental_create'), ('staff_quote_request_pre0066', 'staff_quote_request'),
                          ('admin_apply_booking_edit_pre0066', 'admin_apply_booking_edit'), ('admin_booking_json_pre0066', 'admin_booking_json'),
                          ('preview_cancellation_pre0066', 'preview_cancellation'), ('field_read_pre0066', 'field_read')) m(old_name, new_name)
               on m.old_name = p.proname
            where n.nspname = 'app' loop
    v_new := format('app.%I(%s)', r.new_name, r.args)::regprocedure;
    execute format('revoke all on function %s from public, anon, authenticated', v_new);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['addon_applies', 'addon_unit_price', 'addon_item_cents', 'addon_line', 'addon_held', 'addons_input',
              'addons_resolve', 'booking_addons_spec', 'booking_addons_spec_row', 'addons_sync_extras', 'booking_addons_set', 'booking_addons_json',
              'bookings_addons_after', 'addons_context_begin', 'addon_charge_facts', 'booking_addon_buy', 'booking_addon_paid', 'booking_addon_failed',
              'booking_addon_confirm', 'booking_addon_remove', 'addon_prep_task', 'booking_addons_row_after', 'bookings_addons_status',
              'addons_kept_on_cancel', 'booking_cancellations_addons', 'booking_has_prepaid_fuel', 'addons_for_car', 'my_booking_addons',
              'addons_admin_read', 'addon_save', 'ops0066', 'addons_touch', 'submit_booking_request_pre0066', 'manual_rental_create_pre0066',
              'staff_quote_request_pre0066', 'admin_apply_booking_edit_pre0066', 'admin_booking_json_pre0066', 'preview_cancellation_pre0066',
              'field_read_pre0066', 'door_pre0066']))
        or (n.nspname = 'public' and p.proname = any (array['server_my_booking_addons', 'server_booking_addon_buy', 'server_booking_addon_paid',
              'server_booking_addon_failed']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
  execute 'revoke all on function public.addons_for_car(uuid, timestamptz, timestamptz) from public';
  execute 'grant execute on function public.addons_for_car(uuid, timestamptz, timestamptz) to anon, authenticated, service_role';
end $$;


-- ================================================================ 13. the guides for this release
create or replace function app.guide_release_addons(p_portal text, p_slug text, p_kind text, p_after text, p_base_md text, p_title text, p_blurb text,
                                                    p_md text, p_html text) returns text
language sql security definer set search_path = public, app as $$
  select app.guide_release_section(p_portal, p_slug, p_kind, p_after, p_base_md, p_title, p_blurb, p_md, p_html)
$$;
revoke all on function app.guide_release_addons(text, text, text, text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function app.guide_release_addons(text, text, text, text, text, text, text, text, text) to service_role;

-- GUIDES ADD-ONS START (generated by supabase/seed/add_ons_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_addons('renter', 'find-a-car-and-send-a-request', 'chapter', 'start-here', 'Every booking starts as a request. A person checks the car and the price, then sends you an offer. Nothing is charged until you approve, sign and pay.

:::flow
Request | You pick a car and dates
Offer | We confirm the price
Sign | The rental agreement
Pay | Your card is authorized
Verify | Licence, selfie, coverage
Pick up | We hand over the keys
:::

## Find a car

Start on carmacars.ca. You do not need to sign in to look around.

1. Go to `carmacars.ca` and press **Find a car**.
2. Add your pickup and return dates. The list then shows the cars that are free and what the whole trip costs.
3. Narrow the list with Filters: type, seats, transmission and daily rate.
4. Open a car to see its photos, rates, what is included and its own calendar.

![](/guides/img/public-02-cars-desktop-b6cd4fb8.jpg "desktop; size: 1440 880; address: carmacars.ca/cars; pins: 1 86.1 4.0, 2 11.1 56.8, 3 3.0 82.3, 4 34.0 87.5")

## Choose your dates on the car page

1. Under Dates and price, tap your pickup date, then your return date. Hatched days are already booked.
2. Choose the Pickup time and the Return time.
3. Want it brought to you? Tick **Deliver it to me** or **Pick it up from me at the end**.
4. Check Your estimate, then press **Request to book**.

![](/guides/img/public-03-car-page-desktop-73be4d63.jpg "desktop; size: 1120 760; address: carmacars.ca/cars/bmw-330i; pins: 1 24.4 39.7, 2 12.9 68.2, 3 3.0 76.2, 4 97.0 50.0")

> Watch out: A request does not hold the car. The car is booked only once you approve the offer, sign and pay.

## Send your request

The request has four short steps. Your answers are saved as you go, so you can come back.

1. Step 1, Dates and delivery: check the car and tap your dates in the calendar.
2. Set the Pickup time and Return time. Any time, day or night, with at least 2 hours of notice.
3. Your request, on the right, shows the estimated total as you go.

![](/guides/img/public-04-book-1-trip-desktop-63a3738b.jpg "desktop; size: 1440 1002; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 1 9.2 67.1, 2 15.3 91.0, 3 91.1 54.7")

4. Choose where you get the car: **At our location**, **Deliver it to an address** or **At the airport**. Then choose where you return it.
5. Press **Continue to driver details**.

![](/guides/img/public-04-book-1-trip-desktop-befba4f6.jpg "desktop; size: 760 942; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 4 5.3 26.2, 5 61.8 93.3")

6. Step 2, The driver: fill in your first and last name, email, mobile number and date of birth.
7. Someone else will drive too? Add them under Additional drivers. Each needs a G2 or G licence and signs the agreement.
8. Press **Continue to licence**.

![](/guides/img/public-05-book-2-driver-desktop-7b572499.jpg "desktop; size: 980 1032; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 6 30.6 21.1, 7 30.6 64.8, 8 55.6 88.0")

9. Step 3: choose your Licence class, for example Ontario G2.
10. Choose how the car is covered: Option 1 (OPCF 27 on your own auto policy), Option 2 (rental coverage on your credit card) or Option 3 (the CarmaCars Protection Plan). You can change this any time before pickup.
11. Choose the Booking type: Standard, or Non-refundable for 10% off with no refund.
12. Add extras such as Winter tires or Baby seats, and anything we should know.
13. Press **Review request**.

![](/guides/img/public-06-book-3-licence-desktop-22bb144e.jpg "desktop; size: 760 1452; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 9 61.8 11.2, 10 92.1 32.2, 11 92.1 50.4, 12 92.1 66.9, 13 71.7 97.0")

14. Step 4, Check it and send: read every line. Use Edit beside a line to change it.
15. Tick the box to confirm you are 18 or older and agree to the Terms of use and Privacy policy.
16. Press **Send request**. Nothing is charged and no card is needed.

![](/guides/img/public-07-book-4-review-desktop-005f4c0b.jpg "desktop; size: 760 492; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 14 92.1 24.8, 15 3.9 59.3, 16 73.7 89.0")

17. The confirmation shows your request number, for example CC-10021. Keep it for any question.
18. A person checks the calendar, your dates and your place, usually within 2 hours, day or night. Your offer arrives by email and in Trips.

![](/guides/img/public-08-book-5-sent-phone-14a99ccf.jpg "phone; size: 390 755; pins: 17 32.8 12.3")

## Ask in the chat

The chat button sits in the corner of every page.

1. Press it and write your question: a car, your dates, the price, how booking works. The CarmaCars assistant answers right away with prices from our booking system.
2. Want a person? Press **Talk to a person**. When our team is away, leave your name and email or phone with **Send my details** and tick "Email me a copy of this chat".
3. Press **End chat** when you are done. If you gave your email, a copy of the chat arrives by email.

A price in the chat is for the dates you asked. Nothing is booked until you approve an offer, sign and pay.
', 'Find a car and send a request', 'Search the fleet, pick dates and add-ons, and send a request in five short steps.',
  'Every booking starts as a request. A person checks the car and the price, then sends you an offer. Nothing is charged until you approve, sign and pay.

:::flow
Request | You pick a car and dates
Offer | We confirm the price
Sign | The rental agreement
Pay | Your card is authorized
Verify | Licence, selfie, coverage
Pick up | We hand over the keys
:::

## Find a car

Start on carmacars.ca. You do not need to sign in to look around.

1. Go to `carmacars.ca` and press **Find a car**.
2. Add your pickup and return dates. The list then shows the cars that are free and what the whole trip costs.
3. Narrow the list with Filters: type, seats, transmission and daily rate.
4. Open a car to see its photos, rates, what is included and its own calendar.

![](/guides/img/public-02-cars-desktop-b6cd4fb8.jpg "desktop; size: 1440 880; address: carmacars.ca/cars; pins: 1 86.1 4.0, 2 11.1 56.8, 3 3.0 82.3, 4 34.0 87.5")

## Choose your dates on the car page

1. Under Dates and price, tap your pickup date, then your return date. Hatched days are already booked.
2. Choose the Pickup time and the Return time.
3. Want it brought to you? Tick **Deliver it to me** or **Pick it up from me at the end**. Open Add-ons to add a baby seat, flowers, a full tank and more.
4. Check Your estimate, then press **Request to book**. The add-ons you chose come with you.

![](/guides/img/public-03-car-page-desktop-73be4d63.jpg "desktop; size: 1120 760; address: carmacars.ca/cars/bmw-330i; pins: 1 24.4 39.7, 2 12.9 68.2, 3 3.0 76.2, 4 97.0 50.0")

> Watch out: A request does not hold the car. The car is booked only once you approve the offer, sign and pay.

## Send your request

The request has five short steps. Your answers are saved as you go, so you can come back.

1. Step 1, Dates and delivery: check the car and tap your dates in the calendar.
2. Set the Pickup time and Return time. Any time, day or night, with at least 2 hours of notice.
3. Your request, on the right, shows the estimated total as you go.

![](/guides/img/public-04-book-1-trip-desktop-63a3738b.jpg "desktop; size: 1440 1002; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 1 9.2 67.1, 2 15.3 91.0, 3 91.1 54.7")

4. Choose where you get the car: **At our location**, **Deliver it to an address** or **At the airport**. Then choose where you return it.
5. Press **Continue to driver details**.

![](/guides/img/public-04-book-1-trip-desktop-befba4f6.jpg "desktop; size: 760 942; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 4 5.3 26.2, 5 61.8 93.3")

6. Step 2, The driver: fill in your first and last name, email, mobile number and date of birth.
7. Someone else will drive too? Add them under Additional drivers. Each needs a G2 or G licence and signs the agreement.
8. Press **Continue to licence**.

![](/guides/img/public-05-book-2-driver-desktop-7b572499.jpg "desktop; size: 980 1032; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 6 30.6 21.1, 7 30.6 64.8, 8 55.6 88.0")

9. Step 3: choose your Licence class, for example Ontario G2.
10. Choose how the car is covered: Option 1 (OPCF 27 on your own auto policy), Option 2 (rental coverage on your credit card) or Option 3 (the CarmaCars Protection Plan). You can change this any time before pickup.
11. Choose the Booking type: Standard, or Non-refundable for 10% off with no refund.
12. Add anything we should know in the notes, for example a flight number.
13. Press **Continue to add-ons**. Step 4, Add-ons: tick what you want (see Add-ons below), then press **Review request**.

![](/guides/img/public-06-book-3-licence-desktop-22bb144e.jpg "desktop; size: 760 1452; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 9 61.8 11.2, 10 92.1 32.2, 11 92.1 50.4, 12 92.1 66.9, 13 71.7 97.0")

14. Step 5, Check it and send: read every line. Use Edit beside a line to change it.
15. Tick the box to confirm you are 18 or older and agree to the Terms of use and Privacy policy.
16. Press **Send request**. Nothing is charged and no card is needed.

![](/guides/img/public-07-book-4-review-desktop-005f4c0b.jpg "desktop; size: 760 492; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 14 92.1 24.8, 15 3.9 59.3, 16 73.7 89.0")

17. The confirmation shows your request number, for example CC-10021. Keep it for any question.
18. A person checks the calendar, your dates and your place, usually within 2 hours, day or night. Your offer arrives by email and in Trips.

![](/guides/img/public-08-book-5-sent-phone-14a99ccf.jpg "phone; size: 390 755; pins: 17 32.8 12.3")

## Add-ons

Extras for your trip, such as a baby seat, a child or booster seat, flowers waiting in the car, a chauffeur, an umbrella, a phone charger or a full tank of gas.

1. On the car page (under Add-ons) or in step 4 of the request, tick an add-on or use + and − for seats. The estimate shows the price at once.
2. Each add-on shows its price: a trip, a day (with the most for a trip) or an hour. HST is added.
3. Some need notice, for example flowers need 24 hours. Seats and other items show how many are left for your dates.
4. A chauffeur is confirmed by our team in your offer.

With a full tank of gas (prepaid) you can return the car at any fuel level, with no fuel charge.

## Ask in the chat

The chat button sits in the corner of every page.

1. Press it and write your question: a car, your dates, the price, how booking works. The CarmaCars assistant answers right away with prices from our booking system.
2. Want a person? Press **Talk to a person**. When our team is away, leave your name and email or phone with **Send my details** and tick "Email me a copy of this chat".
3. Press **End chat** when you are done. If you gave your email, a copy of the chat arrives by email.

A price in the chat is for the dates you asked. Nothing is booked until you approve an offer, sign and pay.
',
  '<p class="gd-p">Every booking starts as a request. A person checks the car and the price, then sends you an offer. Nothing is charged until you approve, sign and pay.</p><ol class="gd-flow"><li><b>1</b><span>Request</span><em>You pick a car and dates</em></li><li><b>2</b><span>Offer</span><em>We confirm the price</em></li><li><b>3</b><span>Sign</span><em>The rental agreement</em></li><li><b>4</b><span>Pay</span><em>Your card is authorized</em></li><li><b>5</b><span>Verify</span><em>Licence, selfie, coverage</em></li><li><b>6</b><span>Pick up</span><em>We hand over the keys</em></li></ol><section class="gd-task" id="find-a-car-and-send-a-request-find-a-car" data-gd-task><h2 class="gd-h2">Find a car</h2><p class="gd-p">Start on carmacars.ca. You do not need to sign in to look around.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Go to <span class="gd-url">carmacars.ca</span> and press <b class="gd-ui">Find a car</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Add your pickup and return dates. The list then shows the cars that are free and what the whole trip costs.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Narrow the list with Filters: type, seats, transmission and daily rate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Open a car to see its photos, rates, what is included and its own calendar.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/cars</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/880"><img src="/guides/img/public-02-cars-desktop-b6cd4fb8.jpg" alt="" loading="lazy" decoding="async" width="1440" height="880"><span class="gd-pin" style="left:86.1%;top:4%" aria-hidden="true">1</span><span class="gd-pin" style="left:11.1%;top:56.8%" aria-hidden="true">2</span><span class="gd-pin" style="left:3%;top:82.3%" aria-hidden="true">3</span><span class="gd-pin" style="left:34%;top:87.5%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="find-a-car-and-send-a-request-choose-your-dates-on-the-car-page" data-gd-task><h2 class="gd-h2">Choose your dates on the car page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Under Dates and price, tap your pickup date, then your return date. Hatched days are already booked.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the Pickup time and the Return time.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Want it brought to you? Tick <b class="gd-ui">Deliver it to me</b> or <b class="gd-ui">Pick it up from me at the end</b>. Open Add-ons to add a baby seat, flowers, a full tank and more.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Check Your estimate, then press <b class="gd-ui">Request to book</b>. The add-ons you chose come with you.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/cars/bmw-330i</span></div><div class="gd-imgwrap" style="aspect-ratio:1120/760"><img src="/guides/img/public-03-car-page-desktop-73be4d63.jpg" alt="" loading="lazy" decoding="async" width="1120" height="760"><span class="gd-pin" style="left:24.4%;top:39.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:12.9%;top:68.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:3%;top:76.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:97%;top:50%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>A request does not hold the car. The car is booked only once you approve the offer, sign and pay.</div></aside></section><section class="gd-task" id="find-a-car-and-send-a-request-send-your-request" data-gd-task><h2 class="gd-h2">Send your request</h2><p class="gd-p">The request has five short steps. Your answers are saved as you go, so you can come back.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Step 1, Dates and delivery: check the car and tap your dates in the calendar.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Set the Pickup time and Return time. Any time, day or night, with at least 2 hours of notice.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Your request, on the right, shows the estimated total as you go.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1002"><img src="/guides/img/public-04-book-1-trip-desktop-63a3738b.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1002"><span class="gd-pin" style="left:9.2%;top:67.1%" aria-hidden="true">1</span><span class="gd-pin" style="left:15.3%;top:91%" aria-hidden="true">2</span><span class="gd-pin" style="left:91.1%;top:54.7%" aria-hidden="true">3</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="4"><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Choose where you get the car: <b class="gd-ui">At our location</b>, <b class="gd-ui">Deliver it to an address</b> or <b class="gd-ui">At the airport</b>. Then choose where you return it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Continue to driver details</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:760/942"><img src="/guides/img/public-04-book-1-trip-desktop-befba4f6.jpg" alt="" loading="lazy" decoding="async" width="760" height="942"><span class="gd-pin" style="left:5.3%;top:26.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:61.8%;top:93.3%" aria-hidden="true">5</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="6"><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Step 2, The driver: fill in your first and last name, email, mobile number and date of birth.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Someone else will drive too? Add them under Additional drivers. Each needs a G2 or G licence and signs the agreement.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Press <b class="gd-ui">Continue to licence</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:980/1032"><img src="/guides/img/public-05-book-2-driver-desktop-7b572499.jpg" alt="" loading="lazy" decoding="async" width="980" height="1032"><span class="gd-pin" style="left:30.6%;top:21.1%" aria-hidden="true">6</span><span class="gd-pin" style="left:30.6%;top:64.8%" aria-hidden="true">7</span><span class="gd-pin" style="left:55.6%;top:88%" aria-hidden="true">8</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="9"><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Step 3: choose your Licence class, for example Ontario G2.</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Choose how the car is covered: Option 1 (OPCF 27 on your own auto policy), Option 2 (rental coverage on your credit card) or Option 3 (the CarmaCars Protection Plan). You can change this any time before pickup.</div></li><li><span class="gd-n" aria-hidden="true">11</span><div class="gd-t">Choose the Booking type: Standard, or Non-refundable for 10% off with no refund.</div></li><li><span class="gd-n" aria-hidden="true">12</span><div class="gd-t">Add anything we should know in the notes, for example a flight number.</div></li><li><span class="gd-n" aria-hidden="true">13</span><div class="gd-t">Press <b class="gd-ui">Continue to add-ons</b>. Step 4, Add-ons: tick what you want (see Add-ons below), then press <b class="gd-ui">Review request</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:760/1452"><img src="/guides/img/public-06-book-3-licence-desktop-22bb144e.jpg" alt="" loading="lazy" decoding="async" width="760" height="1452"><span class="gd-pin" style="left:61.8%;top:11.2%" aria-hidden="true">9</span><span class="gd-pin" style="left:92.1%;top:32.2%" aria-hidden="true">10</span><span class="gd-pin" style="left:92.1%;top:50.4%" aria-hidden="true">11</span><span class="gd-pin" style="left:92.1%;top:66.9%" aria-hidden="true">12</span><span class="gd-pin" style="left:71.7%;top:97%" aria-hidden="true">13</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="14"><li><span class="gd-n" aria-hidden="true">14</span><div class="gd-t">Step 5, Check it and send: read every line. Use Edit beside a line to change it.</div></li><li><span class="gd-n" aria-hidden="true">15</span><div class="gd-t">Tick the box to confirm you are 18 or older and agree to the Terms of use and Privacy policy.</div></li><li><span class="gd-n" aria-hidden="true">16</span><div class="gd-t">Press <b class="gd-ui">Send request</b>. Nothing is charged and no card is needed.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:760/492"><img src="/guides/img/public-07-book-4-review-desktop-005f4c0b.jpg" alt="" loading="lazy" decoding="async" width="760" height="492"><span class="gd-pin" style="left:92.1%;top:24.8%" aria-hidden="true">14</span><span class="gd-pin" style="left:3.9%;top:59.3%" aria-hidden="true">15</span><span class="gd-pin" style="left:73.7%;top:89%" aria-hidden="true">16</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol" start="17"><li><span class="gd-n" aria-hidden="true">17</span><div class="gd-t">The confirmation shows your request number, for example CC-10021. Keep it for any question.</div></li><li><span class="gd-n" aria-hidden="true">18</span><div class="gd-t">A person checks the calendar, your dates and your place, usually within 2 hours, day or night. Your offer arrives by email and in Trips.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/755"><img src="/guides/img/public-08-book-5-sent-phone-14a99ccf.jpg" alt="" loading="lazy" decoding="async" width="390" height="755"><span class="gd-pin" style="left:32.8%;top:12.3%" aria-hidden="true">17</span></div></div></figure></div></section><section class="gd-task" id="find-a-car-and-send-a-request-add-ons" data-gd-task><h2 class="gd-h2">Add-ons</h2><p class="gd-p">Extras for your trip, such as a baby seat, a child or booster seat, flowers waiting in the car, a chauffeur, an umbrella, a phone charger or a full tank of gas.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On the car page (under Add-ons) or in step 4 of the request, tick an add-on or use + and − for seats. The estimate shows the price at once.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each add-on shows its price: a trip, a day (with the most for a trip) or an hour. HST is added.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Some need notice, for example flowers need 24 hours. Seats and other items show how many are left for your dates.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A chauffeur is confirmed by our team in your offer.</div></li></ol></div><p class="gd-p">With a full tank of gas (prepaid) you can return the car at any fuel level, with no fuel charge.</p></section><section class="gd-task" id="find-a-car-and-send-a-request-ask-in-the-chat" data-gd-task><h2 class="gd-h2">Ask in the chat</h2><p class="gd-p">The chat button sits in the corner of every page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press it and write your question: a car, your dates, the price, how booking works. The CarmaCars assistant answers right away with prices from our booking system.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Want a person? Press <b class="gd-ui">Talk to a person</b>. When our team is away, leave your name and email or phone with <b class="gd-ui">Send my details</b> and tick &quot;Email me a copy of this chat&quot;.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">End chat</b> when you are done. If you gave your email, a copy of the chat arrives by email.</div></li></ol></div><p class="gd-p">A price in the chat is for the dates you asked. Nothing is booked until you approve an offer, sign and pay.</p></section>');
select app.guide_release_addons('renter', 'before-pickup', 'chapter', 'sign-and-pay', 'Your booking is confirmed. A few things are left: your licence photos, a selfie and proof of coverage, a signature from each additional driver, and the deposit.

## Your booking page

1. Open **Trips**, then your booking. The status is at the top, for example Confirmed.
2. The red card tells you what is still needed before pickup.
3. Progress shows each stage, from Request sent to Statement.
4. Need something else? holds **Licence and coverage**, **Ask to change dates**, **Cancel booking** and **Extend**.

![](/guides/img/renter-08-booking-confirmed-desktop-125011fd.jpg "desktop; size: 1440 1032; address: carmacars.ca/account/bookings/CC-10057; pins: 1 15.6 9.1, 2 18.1 36.5, 3 8.1 56.8, 4 96.5 79.9")

## Upload your licence, selfie and coverage

Do this at least 24 hours before pickup. It takes a few minutes with your phone.

1. On your booking, press **Upload documents** (or **Licence and coverage**).
2. Licence, front: lay the licence on a dark surface with all four corners visible. Press **Take photo**.
3. Licence, back: do the same for the back.
4. Selfie with your licence: hold the licence beside your face, then press **Take selfie**.
5. Coverage for damage to the car: add what your option asks for, then press **Upload proof**.

![](/guides/img/renter-09-verify-desktop-d20f668d.jpg "desktop; size: 1440 1232; address: carmacars.ca/account/bookings/CC-10057/verify; pins: 2 18.5 65.3, 3 50.0 63.6, 4 81.2 63.6, 5 50.0 95.3")

> Tip: For Option 1, add the policy page or insurer letter that shows OPCF 27. For Option 2 (your credit card coverage), add the card issuer, the last four digits and the card benefits certificate; it must be the card you paid with. For Option 3, we send the Protection Plan''s terms and activate it once it is paid. We delete licence and face photos 90 days after your rental ends.

## Additional drivers

Each additional driver signs the agreement with their own link.

1. When the agreement is ready, each driver with an email gets their own signing link.
2. On your booking, press **Copy their signing link** to send it yourself, or **Send a new link**.
3. Each driver adds their own licence photos and selfie, like you did.

> Watch out: Signing links expire after 72 hours. A new link ends the older one, so always send the newest.

## What to bring to pickup

- Your original licence. A photo is not enough.
- The card you paid with. The deposit is taken on it about an hour before pickup.
- A few minutes to walk around the car with us. We photograph it together.
', 'Before pickup', 'Upload your licence and coverage, send driver links, and know what to bring.',
  'Your booking is confirmed. A few things are left: your licence photos, a selfie and proof of coverage, a signature from each additional driver, and the deposit.

## Your booking page

1. Open **Trips**, then your booking. The status is at the top, for example Confirmed.
2. The red card tells you what is still needed before pickup.
3. Progress shows each stage, from Request sent to Statement.
4. Need something else? holds **Licence and coverage**, **Ask to change dates**, **Cancel booking** and **Extend**.

![](/guides/img/renter-08-booking-confirmed-desktop-125011fd.jpg "desktop; size: 1440 1032; address: carmacars.ca/account/bookings/CC-10057; pins: 1 15.6 9.1, 2 18.1 36.5, 3 8.1 56.8, 4 96.5 79.9")

## Upload your licence, selfie and coverage

Do this at least 24 hours before pickup. It takes a few minutes with your phone.

1. On your booking, press **Upload documents** (or **Licence and coverage**).
2. Licence, front: lay the licence on a dark surface with all four corners visible. Press **Take photo**.
3. Licence, back: do the same for the back.
4. Selfie with your licence: hold the licence beside your face, then press **Take selfie**.
5. Coverage for damage to the car: add what your option asks for, then press **Upload proof**.

![](/guides/img/renter-09-verify-desktop-d20f668d.jpg "desktop; size: 1440 1232; address: carmacars.ca/account/bookings/CC-10057/verify; pins: 2 18.5 65.3, 3 50.0 63.6, 4 81.2 63.6, 5 50.0 95.3")

> Tip: For Option 1, add the policy page or insurer letter that shows OPCF 27. For Option 2 (your credit card coverage), add the card issuer, the last four digits and the card benefits certificate; it must be the card you paid with. For Option 3, we send the Protection Plan''s terms and activate it once it is paid. We delete licence and face photos 90 days after your rental ends.

## Additional drivers

Each additional driver signs the agreement with their own link.

1. When the agreement is ready, each driver with an email gets their own signing link.
2. On your booking, press **Copy their signing link** to send it yourself, or **Send a new link**.
3. Each driver adds their own licence photos and selfie, like you did.

> Watch out: Signing links expire after 72 hours. A new link ends the older one, so always send the newest.

## Add something to your trip

Until 24 hours before pickup (or the notice an add-on needs), add add-ons from your booking.

1. On your booking, under Add-ons, press **Add something to your trip**.
2. Tick the add-on you want. Its price shows below.
3. Press **Add and pay**. It is charged at once on the card you paid with, and shows on your booking and receipt.
4. A chauffeur needs our confirmation: press **Ask for it**. We confirm it and charge your card then.

> Tip: If you cancel, add-ons are refunded like the rest of your booking. Flowers and a chauffeur are not refunded once their notice before pickup has started.

## What to bring to pickup

- Your original licence. A photo is not enough.
- The card you paid with. The deposit is taken on it about an hour before pickup.
- A few minutes to walk around the car with us. We photograph it together.
',
  '<p class="gd-p">Your booking is confirmed. A few things are left: your licence photos, a selfie and proof of coverage, a signature from each additional driver, and the deposit.</p><section class="gd-task" id="before-pickup-your-booking-page" data-gd-task><h2 class="gd-h2">Your booking page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Trips</b>, then your booking. The status is at the top, for example Confirmed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The red card tells you what is still needed before pickup.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Progress shows each stage, from Request sent to Statement.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Need something else? holds <b class="gd-ui">Licence and coverage</b>, <b class="gd-ui">Ask to change dates</b>, <b class="gd-ui">Cancel booking</b> and <b class="gd-ui">Extend</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10057</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1032"><img src="/guides/img/renter-08-booking-confirmed-desktop-125011fd.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1032"><span class="gd-pin" style="left:15.6%;top:9.1%" aria-hidden="true">1</span><span class="gd-pin" style="left:18.1%;top:36.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:8.1%;top:56.8%" aria-hidden="true">3</span><span class="gd-pin" style="left:96.5%;top:79.9%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="before-pickup-upload-your-licence-selfie-and-coverage" data-gd-task><h2 class="gd-h2">Upload your licence, selfie and coverage</h2><p class="gd-p">Do this at least 24 hours before pickup. It takes a few minutes with your phone.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On your booking, press <b class="gd-ui">Upload documents</b> (or <b class="gd-ui">Licence and coverage</b>).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Licence, front: lay the licence on a dark surface with all four corners visible. Press <b class="gd-ui">Take photo</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Licence, back: do the same for the back.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Selfie with your licence: hold the licence beside your face, then press <b class="gd-ui">Take selfie</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Coverage for damage to the car: add what your option asks for, then press <b class="gd-ui">Upload proof</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10057/verify</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1232"><img src="/guides/img/renter-09-verify-desktop-d20f668d.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1232"><span class="gd-pin" style="left:18.5%;top:65.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:50%;top:63.6%" aria-hidden="true">3</span><span class="gd-pin" style="left:81.2%;top:63.6%" aria-hidden="true">4</span><span class="gd-pin" style="left:50%;top:95.3%" aria-hidden="true">5</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>For Option 1, add the policy page or insurer letter that shows OPCF 27. For Option 2 (your credit card coverage), add the card issuer, the last four digits and the card benefits certificate; it must be the card you paid with. For Option 3, we send the Protection Plan&#39;s terms and activate it once it is paid. We delete licence and face photos 90 days after your rental ends.</div></aside></section><section class="gd-task" id="before-pickup-additional-drivers" data-gd-task><h2 class="gd-h2">Additional drivers</h2><p class="gd-p">Each additional driver signs the agreement with their own link.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">When the agreement is ready, each driver with an email gets their own signing link.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">On your booking, press <b class="gd-ui">Copy their signing link</b> to send it yourself, or <b class="gd-ui">Send a new link</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each driver adds their own licence photos and selfie, like you did.</div></li></ol></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Signing links expire after 72 hours. A new link ends the older one, so always send the newest.</div></aside></section><section class="gd-task" id="before-pickup-add-something-to-your-trip" data-gd-task><h2 class="gd-h2">Add something to your trip</h2><p class="gd-p">Until 24 hours before pickup (or the notice an add-on needs), add add-ons from your booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On your booking, under Add-ons, press <b class="gd-ui">Add something to your trip</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Tick the add-on you want. Its price shows below.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Add and pay</b>. It is charged at once on the card you paid with, and shows on your booking and receipt.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A chauffeur needs our confirmation: press <b class="gd-ui">Ask for it</b>. We confirm it and charge your card then.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>If you cancel, add-ons are refunded like the rest of your booking. Flowers and a chauffeur are not refunded once their notice before pickup has started.</div></aside></section><section class="gd-task" id="before-pickup-what-to-bring-to-pickup" data-gd-task><h2 class="gd-h2">What to bring to pickup</h2><ul class="gd-ul"><li>Your original licence. A photo is not enough.</li><li>The card you paid with. The deposit is taken on it about an hour before pickup.</li><li>A few minutes to walk around the car with us. We photograph it together.</li></ul></section>');
select app.guide_release_addons('admin', 'add-ons', 'chapter', 'settings', null, 'Add-ons', 'The catalogue, prices, which cars, notice, stock, confirmation and the money.',
  'Add-ons are things renters buy with a rental. They are on, with prices set, from the start: change any of them when you want.

## The catalogue

Open **Settings** > **Add-ons**.

1. Each add-on shows its price, whether it is on, the notice it needs, its stock and how many are booked in the next 30 days.
2. Press **Edit** to change it: name, short description, price, Priced (per trip, per day or per hour), the most per trip, the most days, the minimum hours, HST.
3. Price by car: one line each, such as suv premium = 110 or body:van = 110. The first that matches the car wins.
4. Which cars: only some classes, only some cars, cars left out, fuel types left out (prepaid fuel is not for electric cars), months (winter tires October to April).
5. Notice needed in hours, In stock for physical items, the most on one booking, staff confirmation (a chauffeur), a Fleet task to get it ready (flowers, a chauffeur), and Not refunded once its notice has started.
6. Press **Save**. Add a photo with **Add a photo**. **Add an add-on** at the bottom adds a new one; it stays off until it has a price.

| Add-on | As set at launch |
| --- | --- |
| Flowers | $150 a trip, 24 hours notice, Fleet prepares |
| Baby seat (rear-facing), Child seat | $15 a day, up to $75 a trip, 2 in stock each |
| Booster seat | $10 a day, up to $50 a trip, 2 in stock |
| Chauffeur | $45 an hour, 3 hours minimum, staff confirm, 24 hours notice |
| Umbrella, Phone charger | $5 a trip, 4 in stock each |
| Full tank of gas (prepaid) | $85 a trip; $110 for SUVs, vans and premium cars; not for electric cars |
| Winter tires | $15 a day, up to $150, October to April |

## Where renters and staff see them

- The car page (Add-ons, priced live) and step 4 of the request.
- Offers and rentals added by hand: staff tick them; a chauffeur is confirmed with the offer.
- The renter portal: add one until 24 hours before pickup (Program settings, addon_portal_cutoff_hours) or the add-on''s own notice, charged on the card on file.
- The agreement summary, the offer, the receipt and the statement list each add-on as a line.
- Field staff see what to put in the car on the handover, and the prepaid fuel note.

## The money

- Add-on revenue is CarmaCars'' own: never Owner Revenue or a partner''s share, and never in a commission or kickback base.
- The company statement shows Add-ons as its own income line (account 4150).
- A cancellation refunds add-ons by the booking''s tier, except one marked Not refunded once its notice has started.
- Removing a paid add-on after booking creates a refund for it, waiting for approval.
',
  '<p class="gd-p">Add-ons are things renters buy with a rental. They are on, with prices set, from the start: change any of them when you want.</p><section class="gd-task" id="add-ons-the-catalogue" data-gd-task><h2 class="gd-h2">The catalogue</h2><p class="gd-p">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Add-ons</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each add-on shows its price, whether it is on, the notice it needs, its stock and how many are booked in the next 30 days.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Edit</b> to change it: name, short description, price, Priced (per trip, per day or per hour), the most per trip, the most days, the minimum hours, HST.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Price by car: one line each, such as suv premium = 110 or body:van = 110. The first that matches the car wins.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Which cars: only some classes, only some cars, cars left out, fuel types left out (prepaid fuel is not for electric cars), months (winter tires October to April).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Notice needed in hours, In stock for physical items, the most on one booking, staff confirmation (a chauffeur), a Fleet task to get it ready (flowers, a chauffeur), and Not refunded once its notice has started.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Press <b class="gd-ui">Save</b>. Add a photo with <b class="gd-ui">Add a photo</b>. <b class="gd-ui">Add an add-on</b> at the bottom adds a new one; it stays off until it has a price.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Add-on</th><th scope="col">As set at launch</th></tr></thead><tbody><tr><td>Flowers</td><td>$150 a trip, 24 hours notice, Fleet prepares</td></tr><tr><td>Baby seat (rear-facing), Child seat</td><td>$15 a day, up to $75 a trip, 2 in stock each</td></tr><tr><td>Booster seat</td><td>$10 a day, up to $50 a trip, 2 in stock</td></tr><tr><td>Chauffeur</td><td>$45 an hour, 3 hours minimum, staff confirm, 24 hours notice</td></tr><tr><td>Umbrella, Phone charger</td><td>$5 a trip, 4 in stock each</td></tr><tr><td>Full tank of gas (prepaid)</td><td>$85 a trip; $110 for SUVs, vans and premium cars; not for electric cars</td></tr><tr><td>Winter tires</td><td>$15 a day, up to $150, October to April</td></tr></tbody></table></div></section><section class="gd-task" id="add-ons-where-renters-and-staff-see-them" data-gd-task><h2 class="gd-h2">Where renters and staff see them</h2><ul class="gd-ul"><li>The car page (Add-ons, priced live) and step 4 of the request.</li><li>Offers and rentals added by hand: staff tick them; a chauffeur is confirmed with the offer.</li><li>The renter portal: add one until 24 hours before pickup (Program settings, addon_portal_cutoff_hours) or the add-on&#39;s own notice, charged on the card on file.</li><li>The agreement summary, the offer, the receipt and the statement list each add-on as a line.</li><li>Field staff see what to put in the car on the handover, and the prepaid fuel note.</li></ul></section><section class="gd-task" id="add-ons-the-money" data-gd-task><h2 class="gd-h2">The money</h2><ul class="gd-ul"><li>Add-on revenue is CarmaCars&#39; own: never Owner Revenue or a partner&#39;s share, and never in a commission or kickback base.</li><li>The company statement shows Add-ons as its own income line (account 4150).</li><li>A cancellation refunds add-ons by the booking&#39;s tier, except one marked Not refunded once its notice has started.</li><li>Removing a paid add-on after booking creates a refund for it, waiting for approval.</li></ul></section>');
select app.guide_release_addons('va', 'add-ons', 'chapter', 'live-visitors-and-live-chat', null, 'Add-ons', 'Add-ons in offers and rentals, confirming a chauffeur, Fleet tasks and stock.',
  'Renters buy add-ons with a rental: seats, flowers, a chauffeur, an umbrella, a phone charger, a full tank. You add them in offers and rentals, confirm the ones that need it, and Fleet keeps the stock.

## In an offer or a rental you add

1. On the review screen of a request, under Add-ons, tick or count what the renter wants. The price on the right follows. Choose the hours for a chauffeur.
2. Add-ons the renter asked for are already ticked. One waiting for confirmation (a chauffeur) is confirmed when you keep it and send the offer; untick it to remove it.
3. In **Bookings** > **Add a rental**, the Add-ons list sits under The rental: tick them before you press **Check the calendar and the price**.
4. Notice is yours to judge: you may add flowers with less than 24 hours if Fleet can do it.

## After booking

1. The booking page shows the add-ons, paid or not, and any waiting for confirmation.
2. A renter asked for a chauffeur from their portal: you get a task. Press **Confirm and charge** (the card on file is charged) or **Decline**.
3. Press **Remove** and give the reason to take one off. Unpaid, it goes; paid, a refund for it waits for approval.

## Fleet: tasks and stock

Flowers and a chauffeur give Fleet a task to get them ready, due before pickup by their notice.

1. Open **Cars** > **Add-ons**. Each add-on shows its price, its notice and how many are booked in the next 30 days.
2. For seats, umbrellas and chargers, type how many we have under In stock and press **Save**. Renters cannot ask for more than are free for their dates.
3. A confirmed booking with more than we have gives you an urgent task: find another or tell the renter.

Add-on revenue is CarmaCars'' own. It is never in a commission: your commission stays on the rental charge.
',
  '<p class="gd-p">Renters buy add-ons with a rental: seats, flowers, a chauffeur, an umbrella, a phone charger, a full tank. You add them in offers and rentals, confirm the ones that need it, and Fleet keeps the stock.</p><section class="gd-task" id="add-ons-in-an-offer-or-a-rental-you-add" data-gd-task><h2 class="gd-h2">In an offer or a rental you add</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On the review screen of a request, under Add-ons, tick or count what the renter wants. The price on the right follows. Choose the hours for a chauffeur.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Add-ons the renter asked for are already ticked. One waiting for confirmation (a chauffeur) is confirmed when you keep it and send the offer; untick it to remove it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">In <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Add a rental</b>, the Add-ons list sits under The rental: tick them before you press <b class="gd-ui">Check the calendar and the price</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Notice is yours to judge: you may add flowers with less than 24 hours if Fleet can do it.</div></li></ol></div></section><section class="gd-task" id="add-ons-after-booking" data-gd-task><h2 class="gd-h2">After booking</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The booking page shows the add-ons, paid or not, and any waiting for confirmation.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">A renter asked for a chauffeur from their portal: you get a task. Press <b class="gd-ui">Confirm and charge</b> (the card on file is charged) or <b class="gd-ui">Decline</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Remove</b> and give the reason to take one off. Unpaid, it goes; paid, a refund for it waits for approval.</div></li></ol></div></section><section class="gd-task" id="add-ons-fleet-tasks-and-stock" data-gd-task><h2 class="gd-h2">Fleet: tasks and stock</h2><p class="gd-p">Flowers and a chauffeur give Fleet a task to get them ready, due before pickup by their notice.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Add-ons</b>. Each add-on shows its price, its notice and how many are booked in the next 30 days.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">For seats, umbrellas and chargers, type how many we have under In stock and press <b class="gd-ui">Save</b>. Renters cannot ask for more than are free for their dates.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A confirmed booking with more than we have gives you an urgent task: find another or tell the renter.</div></li></ol></div><p class="gd-p">Add-on revenue is CarmaCars&#39; own. It is never in a commission: your commission stays on the rental charge.</p></section>');
select app.guide_release_addons('field', 'a-handover', 'chapter', 'my-jobs', 'You give the renter the keys only after every check passes. The steps guide you one by one: press Next after each, Back to go back.

## Before you start: the ready check

The first step lists what must be done before the car can go: signed, paid, ID checked, deposit.

1. Each line should show a green tick: identity verified, coverage confirmed, additional drivers accepted, the booking holds the calendar, deposit taken.
2. All green? Press **Next**.
3. Anything not ready? Press **Stop: do not release the car** and call the office.

![](/guides/img/field-21-handover-01-ready-phone-5ac4e7df.jpg "phone; size: 390 995; pins: 1 93.6 71.9, 2 76.9 98.0")

> Watch out: Never hand over keys if the ready check fails, the renter does not match the photo on file, or they do not have their original licence or the card on file. Stop and call us.

## The steps, one by one

:::phones
1. Car ready: fuel full or charged 80%, clean, extras in. **Yes** or **No**, with a note for Fleet. ![](/guides/img/field-22-handover-02-car-ready-phone-7fef7a1d.jpg "phone; size: 390 385")
2. Is this the renter? Compare the person with the name and photo on file. ![](/guides/img/field-23-handover-03-renter-phone-b718388d.jpg "phone; size: 390 325")
3. Original licence: name, photo and expiry match. A photo of a licence is not enough. ![](/guides/img/field-24-handover-04-licence-phone-3a13ae57.jpg "phone; size: 390 405")
4. Card on File: you have seen the physical card with the same last four digits, in the renter''s name. ![](/guides/img/field-25-handover-05-card-phone-bb24ccc4.jpg "phone; size: 390 265")
5. Odometer: type the reading in km. ![](/guides/img/field-26-handover-06-odometer-phone-9234054f.jpg "phone; size: 390 265")
6. Fuel or charge: slide to the level on the gauge. ![](/guides/img/field-27-handover-07-fuel-phone-a5dec192.jpg "phone; size: 390 275")
:::

:::phones
7. Keys: how many keys and fobs you hand over. Use **+** and **−**. ![](/guides/img/field-28-handover-08-keys-phone-8de46c31.jpg "phone; size: 390 235")
8. Photo set: 19 photos in order. **Take** each one; **Retake** if needed. ![](/guides/img/field-29-handover-09-photos-phone-4a0e3d9c.jpg "phone; size: 390 405")
9. Damage: tap the car diagram where it is, choose Where and Type, then **Add the damage**. ![](/guides/img/field-30-handover-10-damage-phone-923e28fe.jpg "phone; size: 390 605")
10. Tracker: it should say in place and reporting. **Check again** if not. ![](/guides/img/field-31-handover-11-tracker-phone-0107b84a.jpg "phone; size: 390 295")
11. Renter reviews: the renter reads the summary of odometer, fuel, keys, photos and damage. ![](/guides/img/field-32-handover-12-summary-phone-96736994.jpg "phone; size: 390 365")
12. Signatures: the renter signs, then you. **Use this signature** for each. ![](/guides/img/field-33-handover-13-signatures-phone-537ff2e3.jpg "phone; size: 390 405")
:::

13. Press **Hand over the keys**. You see "Handed over. The rental has started."

> Tip: The photo count shows "19 of 19 photos taken · all uploaded" when the set is complete. The first photo must show the plate. Open circles on the damage diagram were recorded before; add only what is new.
', 'A handover', 'The ready check, ID, card, odometer, photos, damage, signatures and the keys.',
  'You give the renter the keys only after every check passes. The steps guide you one by one: press Next after each, Back to go back.

## Before you start: the ready check

The first step lists what must be done before the car can go: signed, paid, ID checked, deposit.

1. Each line should show a green tick: identity verified, coverage confirmed, additional drivers accepted, the booking holds the calendar, deposit taken.
2. All green? Press **Next**.
3. Anything not ready? Press **Stop: do not release the car** and call the office.

![](/guides/img/field-21-handover-01-ready-phone-5ac4e7df.jpg "phone; size: 390 995; pins: 1 93.6 71.9, 2 76.9 98.0")

> Watch out: Never hand over keys if the ready check fails, the renter does not match the photo on file, or they do not have their original licence or the card on file. Stop and call us.

## The steps, one by one

:::phones
1. Car ready: fuel full or charged 80%, clean, extras in. **Yes** or **No**, with a note for Fleet. ![](/guides/img/field-22-handover-02-car-ready-phone-7fef7a1d.jpg "phone; size: 390 385")
2. Is this the renter? Compare the person with the name and photo on file. ![](/guides/img/field-23-handover-03-renter-phone-b718388d.jpg "phone; size: 390 325")
3. Original licence: name, photo and expiry match. A photo of a licence is not enough. ![](/guides/img/field-24-handover-04-licence-phone-3a13ae57.jpg "phone; size: 390 405")
4. Card on File: you have seen the physical card with the same last four digits, in the renter''s name. ![](/guides/img/field-25-handover-05-card-phone-bb24ccc4.jpg "phone; size: 390 265")
5. Odometer: type the reading in km. ![](/guides/img/field-26-handover-06-odometer-phone-9234054f.jpg "phone; size: 390 265")
6. Fuel or charge: slide to the level on the gauge. ![](/guides/img/field-27-handover-07-fuel-phone-a5dec192.jpg "phone; size: 390 275")
:::

:::phones
7. Keys: how many keys and fobs you hand over. Use **+** and **−**. ![](/guides/img/field-28-handover-08-keys-phone-8de46c31.jpg "phone; size: 390 235")
8. Photo set: 19 photos in order. **Take** each one; **Retake** if needed. ![](/guides/img/field-29-handover-09-photos-phone-4a0e3d9c.jpg "phone; size: 390 405")
9. Damage: tap the car diagram where it is, choose Where and Type, then **Add the damage**. ![](/guides/img/field-30-handover-10-damage-phone-923e28fe.jpg "phone; size: 390 605")
10. Tracker: it should say in place and reporting. **Check again** if not. ![](/guides/img/field-31-handover-11-tracker-phone-0107b84a.jpg "phone; size: 390 295")
11. Renter reviews: the renter reads the summary of odometer, fuel, keys, photos and damage. ![](/guides/img/field-32-handover-12-summary-phone-96736994.jpg "phone; size: 390 365")
12. Signatures: the renter signs, then you. **Use this signature** for each. ![](/guides/img/field-33-handover-13-signatures-phone-537ff2e3.jpg "phone; size: 390 405")
:::

13. Press **Hand over the keys**. You see "Handed over. The rental has started."

## Add-ons to put in the car

A booking may come with add-ons: a baby seat, a child or booster seat, flowers, an umbrella, a phone charger or a prepaid full tank.

1. Open the job. Under Put in the car you see each add-on, how many, and what to do (for example "Put the bouquet on the front passenger seat").
2. Put every item in the car before the handover. The Car ready step lists them again.
3. Prepaid fuel: the renter may return the car at any fuel level. Do not charge for fuel at the return.
4. A chauffeur on the booking: Fleet tells you who drives and when.

> Tip: An item missing? Write it in the note for Fleet on the Car ready step and call the office before the handover.

> Tip: The photo count shows "19 of 19 photos taken · all uploaded" when the set is complete. The first photo must show the plate. Open circles on the damage diagram were recorded before; add only what is new.
',
  '<p class="gd-p">You give the renter the keys only after every check passes. The steps guide you one by one: press Next after each, Back to go back.</p><section class="gd-task" id="a-handover-before-you-start-the-ready-check" data-gd-task><h2 class="gd-h2">Before you start: the ready check</h2><p class="gd-p">The first step lists what must be done before the car can go: signed, paid, ID checked, deposit.</p><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each line should show a green tick: identity verified, coverage confirmed, additional drivers accepted, the booking holds the calendar, deposit taken.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">All green? Press <b class="gd-ui">Next</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Anything not ready? Press <b class="gd-ui">Stop: do not release the car</b> and call the office.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/995"><img src="/guides/img/field-21-handover-01-ready-phone-5ac4e7df.jpg" alt="" loading="lazy" decoding="async" width="390" height="995"><span class="gd-pin" style="left:93.6%;top:71.9%" aria-hidden="true">1</span><span class="gd-pin" style="left:76.9%;top:98%" aria-hidden="true">2</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Never hand over keys if the ready check fails, the renter does not match the photo on file, or they do not have their original licence or the card on file. Stop and call us.</div></aside></section><section class="gd-task" id="a-handover-the-steps-one-by-one" data-gd-task><h2 class="gd-h2">The steps, one by one</h2><div class="gd-phones"><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">1</span><div>Car ready: fuel full or charged 80%, clean, extras in. <b class="gd-ui">Yes</b> or <b class="gd-ui">No</b>, with a note for Fleet.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/385"><img src="/guides/img/field-22-handover-02-car-ready-phone-7fef7a1d.jpg" alt="" loading="lazy" decoding="async" width="390" height="385"></div></div></figure></div><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">2</span><div>Is this the renter? Compare the person with the name and photo on file.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/325"><img src="/guides/img/field-23-handover-03-renter-phone-b718388d.jpg" alt="" loading="lazy" decoding="async" width="390" height="325"></div></div></figure></div><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">3</span><div>Original licence: name, photo and expiry match. A photo of a licence is not enough.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/405"><img src="/guides/img/field-24-handover-04-licence-phone-3a13ae57.jpg" alt="" loading="lazy" decoding="async" width="390" height="405"></div></div></figure></div><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">4</span><div>Card on File: you have seen the physical card with the same last four digits, in the renter&#39;s name.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/265"><img src="/guides/img/field-25-handover-05-card-phone-bb24ccc4.jpg" alt="" loading="lazy" decoding="async" width="390" height="265"></div></div></figure></div><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">5</span><div>Odometer: type the reading in km.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/265"><img src="/guides/img/field-26-handover-06-odometer-phone-9234054f.jpg" alt="" loading="lazy" decoding="async" width="390" height="265"></div></div></figure></div><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">6</span><div>Fuel or charge: slide to the level on the gauge.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/275"><img src="/guides/img/field-27-handover-07-fuel-phone-a5dec192.jpg" alt="" loading="lazy" decoding="async" width="390" height="275"></div></div></figure></div></div><div class="gd-phones"><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">7</span><div>Keys: how many keys and fobs you hand over. Use <b class="gd-ui">+</b> and <b class="gd-ui">−</b>.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/235"><img src="/guides/img/field-28-handover-08-keys-phone-8de46c31.jpg" alt="" loading="lazy" decoding="async" width="390" height="235"></div></div></figure></div><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">8</span><div>Photo set: 19 photos in order. <b class="gd-ui">Take</b> each one; <b class="gd-ui">Retake</b> if needed.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/405"><img src="/guides/img/field-29-handover-09-photos-phone-4a0e3d9c.jpg" alt="" loading="lazy" decoding="async" width="390" height="405"></div></div></figure></div><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">9</span><div>Damage: tap the car diagram where it is, choose Where and Type, then <b class="gd-ui">Add the damage</b>.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/605"><img src="/guides/img/field-30-handover-10-damage-phone-923e28fe.jpg" alt="" loading="lazy" decoding="async" width="390" height="605"></div></div></figure></div><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">10</span><div>Tracker: it should say in place and reporting. <b class="gd-ui">Check again</b> if not.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/295"><img src="/guides/img/field-31-handover-11-tracker-phone-0107b84a.jpg" alt="" loading="lazy" decoding="async" width="390" height="295"></div></div></figure></div><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">11</span><div>Renter reviews: the renter reads the summary of odometer, fuel, keys, photos and damage.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/365"><img src="/guides/img/field-32-handover-12-summary-phone-96736994.jpg" alt="" loading="lazy" decoding="async" width="390" height="365"></div></div></figure></div><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">12</span><div>Signatures: the renter signs, then you. <b class="gd-ui">Use this signature</b> for each.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/405"><img src="/guides/img/field-33-handover-13-signatures-phone-537ff2e3.jpg" alt="" loading="lazy" decoding="async" width="390" height="405"></div></div></figure></div></div><div class="gd-stepblock"><ol class="gd-ol" start="13"><li><span class="gd-n" aria-hidden="true">13</span><div class="gd-t">Press <b class="gd-ui">Hand over the keys</b>. You see &quot;Handed over. The rental has started.&quot;</div></li></ol></div></section><section class="gd-task" id="a-handover-add-ons-to-put-in-the-car" data-gd-task><h2 class="gd-h2">Add-ons to put in the car</h2><p class="gd-p">A booking may come with add-ons: a baby seat, a child or booster seat, flowers, an umbrella, a phone charger or a prepaid full tank.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the job. Under Put in the car you see each add-on, how many, and what to do (for example &quot;Put the bouquet on the front passenger seat&quot;).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Put every item in the car before the handover. The Car ready step lists them again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Prepaid fuel: the renter may return the car at any fuel level. Do not charge for fuel at the return.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A chauffeur on the booking: Fleet tells you who drives and when.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>An item missing? Write it in the note for Fleet on the Car ready step and call the office before the handover.</div></aside><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The photo count shows &quot;19 of 19 photos taken · all uploaded&quot; when the set is complete. The first photo must show the plate. Open circles on the damage diagram were recorded before; add only what is new.</div></aside></section>');
-- GUIDES ADD-ONS END
