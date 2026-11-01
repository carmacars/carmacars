-- 0360_lead_time_pricing.sql
-- Lead-time pricing (docs/changes/2026-11-06-lead-time-and-partner-pricing.md). The owner: "cars booked ahead of time
-- should be slightly cheaper than booking last minute, there should be a premium for booking last minute."
--
--   1. Program settings: lead_time_enabled (on), lead_time_tiers (pickup under 24 hours +15%, 24 to 72 hours +10%,
--      3 to 13 days 0%, 14 days or more -5%), lead_time_insurer (off: a booking billed to an insurer is not adjusted).
--      Each tier is {from_hours, bps}: it applies from that many hours before pickup until the next tier starts.
--   2. Per car (vehicles.lead_time_mode): follow Program settings, off for this car, or its own tiers.
--   3. The hours ahead are counted on Toronto clocks, from the moment of the quote or the request to the pickup.
--   4. A percentage of the rental charge only, before tax: one line of its own ("Short-notice pricing +10%", "Booked
--      ahead -5%"), never on fees, the deposit or add-ons. The non-refundable discount, a staff discount and a promo
--      code are still worked out on the rental charge from the rates, as before.
--   5. Locked: the quote works it out now; a request locks the percentage on the booking (bookings.lead_time_bps), so
--      the offer, a date change and the payment keep it. Staff override it on the booking (a percentage, or none); a
--      price typed by hand replaces it. Rentals added by hand, Owner Bookings and placeholders are not adjusted.
--   6. Owner revenue, commissions and the partner split count the line with the rental charge, as they count the
--      discounts.
-- No applied migration is edited: functions that change are wrapped (_pre0360) or patched in place with
-- pg_temp.patch_fn, which refuses when the text it changes is not found.

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0360: the text to change was not found in %: %', p_sig, left(p_old, 160);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the tiers and where they are set
create or replace function app.lead_time_tiers_ok(p jsonb) returns boolean
language plpgsql immutable as $$
declare
  e jsonb;
  v_prev numeric := -1;
  n integer := 0;
begin
  if p is null or jsonb_typeof(p) <> 'array' or jsonb_array_length(p) not between 1 and 8 then return false; end if;
  for e in select value from jsonb_array_elements(p) loop
    n := n + 1;
    if jsonb_typeof(e) <> 'object' or jsonb_typeof(e -> 'from_hours') <> 'number' or jsonb_typeof(e -> 'bps') <> 'number' then return false; end if;
    if (e ->> 'from_hours')::numeric <> trunc((e ->> 'from_hours')::numeric) or (e ->> 'bps')::numeric <> trunc((e ->> 'bps')::numeric) then return false; end if;
    if n = 1 and (e ->> 'from_hours')::numeric <> 0 then return false; end if;
    if (e ->> 'from_hours')::numeric <= v_prev or (e ->> 'from_hours')::numeric > 8784 then return false; end if;
    if (e ->> 'bps')::numeric not between -5000 and 5000 then return false; end if;
    v_prev := (e ->> 'from_hours')::numeric;
  end loop;
  return true;
end $$;

alter table program_settings
  add column if not exists lead_time_enabled boolean not null default true,
  add column if not exists lead_time_tiers jsonb not null
    default '[{"from_hours": 0, "bps": 1500}, {"from_hours": 24, "bps": 1000}, {"from_hours": 72, "bps": 0}, {"from_hours": 336, "bps": -500}]'::jsonb,
  add column if not exists lead_time_insurer boolean not null default false;
alter table program_settings drop constraint if exists program_settings_lead_time_tiers_ok;
alter table program_settings add constraint program_settings_lead_time_tiers_ok check (app.lead_time_tiers_ok(lead_time_tiers));
comment on column program_settings.lead_time_enabled is 'Lead-time pricing (0360): the rental charge is adjusted by how far ahead of pickup the car is booked. Off: no adjustment on any car.';
comment on column program_settings.lead_time_tiers is 'Lead-time tiers (0360), in order: [{from_hours, bps}], the first from 0 hours. A tier applies from that many hours before pickup (Toronto clocks) until the next. bps: +1500 = 15% more, -500 = 5% less.';
comment on column program_settings.lead_time_insurer is 'Lead-time pricing on bookings billed to an insurer (0360). Off by default: an insurer pays its own rate.';

alter table vehicles
  add column if not exists lead_time_mode text not null default 'program',
  add column if not exists lead_time_tiers jsonb;
alter table vehicles drop constraint if exists vehicles_lead_time_mode;
alter table vehicles add constraint vehicles_lead_time_mode check (lead_time_mode in ('program', 'off', 'own')
  and (lead_time_mode <> 'own' or app.lead_time_tiers_ok(lead_time_tiers)));
comment on column vehicles.lead_time_mode is 'Lead-time pricing on this car (0360): program (the tiers in Program settings), off (never adjusted), own (vehicles.lead_time_tiers).';
comment on column vehicles.lead_time_tiers is 'This car''s own lead-time tiers when lead_time_mode is own (0360), as program_settings.lead_time_tiers.';

alter table bookings
  add column if not exists lead_time_bps integer check (lead_time_bps between -5000 and 5000),
  add column if not exists lead_time_hours numeric(10, 2),
  add column if not exists lead_time_locked_at timestamptz,
  add column if not exists lead_time_source text check (lead_time_source in ('auto', 'staff'));
comment on column bookings.lead_time_bps is 'The lead-time adjustment locked on this booking (0360), a percentage of the rental charge in basis points; empty: none. Set when the request came in, or by staff.';
comment on column bookings.lead_time_hours is 'How many hours before pickup (Toronto clocks) the booking was requested, when the lead-time tier was locked (0360)';
comment on column bookings.lead_time_source is 'auto: the tier when the request came in; staff: set on the booking by staff (0360)';

-- the line: a percentage of the rental charge, owner revenue like the rental charge, taxed like it
insert into fee_types (code, label, family, unit, per_what, revenue_class, hst_applies, stage, refundable_by_tier, change_default, change_vehicle,
                       change_booking, in_master_spec, sort_order, gl_account)
select 'lead_time', 'Lead-time pricing: short notice or booked ahead, a percentage of the rental charge', 'rental', 'percent', 'rental',
       f.revenue_class, f.hst_applies, 'booking', f.refundable_by_tier, false, false, false, false, 15, f.gl_account
  from fee_types f where f.code = 'rental_charge'
on conflict (code) do nothing;

-- ================================================================ 2. the money
-- Hours from p_at to the pickup on Toronto clocks (a pickup at 10:00 two weeks later is 336 hours ahead, whether or not
-- the clocks changed in between).
create or replace function app.lead_time_hours(p_pickup timestamptz, p_at timestamptz default now()) returns numeric
language sql immutable as $$
  select round((extract(epoch from ((p_pickup at time zone 'America/Toronto') - (p_at at time zone 'America/Toronto'))) / 3600.0)::numeric, 2)
$$;

-- The tier for so many hours ahead: the last one whose from_hours is at or below them (a pickup already passed: the
-- first tier).
create or replace function app.lead_time_tier(p_tiers jsonb, p_hours numeric) returns jsonb
language sql immutable as $$
  select coalesce((select e.value from jsonb_array_elements(p_tiers) with ordinality e(value, ord)
                    where (e.value ->> 'from_hours')::numeric <= greatest(p_hours, 0)
                    order by (e.value ->> 'from_hours')::numeric desc limit 1),
                  '{"from_hours": 0, "bps": 0}'::jsonb)
$$;

-- What lead-time pricing gives a car for a pickup, asked at p_at: {bps, hours, from_hours, source}. source: program, car
-- (its own tiers), off (Program settings) or car_off (this car).
create or replace function app.lead_time_for(p_vehicle uuid, p_pickup timestamptz, p_at timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings(app.local_date(p_at));
  v vehicles;
  h numeric := app.lead_time_hours(p_pickup, p_at);
  t jsonb;
begin
  select * into v from vehicles where id = p_vehicle;
  if not coalesce(s.lead_time_enabled, false) then
    return jsonb_build_object('bps', 0, 'hours', h, 'from_hours', null, 'source', 'off');
  end if;
  if v.lead_time_mode = 'off' then
    return jsonb_build_object('bps', 0, 'hours', h, 'from_hours', null, 'source', 'car_off');
  end if;
  t := app.lead_time_tier(case when v.lead_time_mode = 'own' then v.lead_time_tiers else s.lead_time_tiers end, h);
  return jsonb_build_object('bps', (t ->> 'bps')::integer, 'hours', h, 'from_hours', (t ->> 'from_hours')::numeric,
                            'source', case when v.lead_time_mode = 'own' then 'car' else 'program' end);
end $$;

-- The line's words: "Short-notice pricing +10%" or "Booked ahead −5%" (a minus sign, not a dash).
create or replace function app.lead_time_text(p_bps integer) returns text
language sql immutable as $$
  select case when coalesce(p_bps, 0) > 0 then 'Short-notice pricing +' || app.fmt_pct(p_bps)
              when coalesce(p_bps, 0) < 0 then 'Booked ahead ' || chr(8722) || app.fmt_pct(-p_bps)
              else 'No lead-time adjustment' end
$$;

-- price_lines: the lead-time line after the rental charge. p.lead_time_bps is what the caller locked (a quote: now; a
-- booking: its own). Not on an Owner Booking, not on a rental charge of zero, not on a booking billed to an insurer
-- unless Program settings say so. Never takes the rental below zero after the discounts.
alter function app.price_lines(jsonb) rename to price_lines_pre0360;
create function app.price_lines(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.price_lines_pre0360(p);
  v_bps integer := coalesce(nullif(p ->> 'lead_time_bps', '')::integer, 0);
  v_rental bigint := coalesce((v ->> 'rental_charge_cents')::bigint, 0);
  v_left bigint;
  v_amt bigint;
  v_hst integer := coalesce((p ->> 'hst_bps')::integer, 0);
  v_lines jsonb;
  v_sub bigint;
  v_tax bigint;
  v_none jsonb := jsonb_build_object('lead_time_bps', 0, 'lead_time_cents', 0, 'lead_time_label', null);
begin
  if coalesce(p ->> 'booking_type', 'standard') = 'owner' or v_bps = 0 or v_rental <= 0 then return v || v_none; end if;
  if coalesce((p ->> 'insurer_billed')::boolean, false) and not coalesce((app.settings()).lead_time_insurer, false) then return v || v_none; end if;
  v_left := v_rental - coalesce((v ->> 'non_refundable_discount_cents')::bigint, 0) - coalesce((v ->> 'staff_discount_cents')::bigint, 0)
            - coalesce((v ->> 'promo_discount_cents')::bigint, 0);
  v_amt := greatest(public.calc_bps(v_rental, v_bps), -greatest(v_left, 0));
  if v_amt = 0 then return v || v_none; end if;
  select coalesce(jsonb_agg(x.value order by (x.value ->> 'sort_order')::integer, x.ord), '[]'::jsonb),
         coalesce(sum((x.value ->> 'amount_cents')::bigint), 0), coalesce(sum((x.value ->> 'hst_cents')::bigint), 0)
    into v_lines, v_sub, v_tax
    from jsonb_array_elements(coalesce(v -> 'lines', '[]'::jsonb)
           || jsonb_build_array(app.price_line('lead_time', 1, v_amt, v_amt, v_hst, app.lead_time_text(v_bps), null,
                                               jsonb_build_object('bps', v_bps, 'kind', case when v_bps > 0 then 'short_notice' else 'booked_ahead' end,
                                                                  'hours', nullif(p ->> 'lead_time_hours', '')::numeric))))
         with ordinality x(value, ord);
  return v || jsonb_build_object('lines', v_lines, 'subtotal_cents', v_sub, 'hst_cents', v_tax, 'total_cents', v_sub + v_tax,
                                 'lead_time_bps', v_bps, 'lead_time_cents', v_amt, 'lead_time_label', app.lead_time_text(v_bps));
end $$;

-- A quote's percentage: staff may name one (app.staff_pricing), a price typed by staff has none, a rental added by hand
-- has none ('lead_time': 'none'); otherwise the tier for a request made now.
create or replace function app.quote_lead_time(p_vehicle uuid, p_pickup timestamptz, o jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_staff boolean := coalesce(current_setting('app.staff_pricing', true), '') = 'on';
begin
  if coalesce(o ->> 'booking_type', 'standard') = 'owner' or coalesce(o ->> 'lead_time', '') = 'none'
     or (v_staff and nullif(o ->> 'staff_rental_charge_cents', '') is not null) then
    return jsonb_build_object('bps', 0, 'hours', app.lead_time_hours(p_pickup), 'source', 'none');
  end if;
  if v_staff and nullif(o ->> 'lead_time_bps', '') is not null then
    return jsonb_build_object('bps', least(greatest((o ->> 'lead_time_bps')::integer, -5000), 5000), 'hours', app.lead_time_hours(p_pickup), 'source', 'staff');
  end if;
  return app.lead_time_for(p_vehicle, p_pickup, now());
end $$;

select pg_temp.patch_fn('app.price_quote(uuid, timestamptz, timestamptz, jsonb)'::regprocedure,
  $o$'non_refundable_discount_bps', v_set.non_refundable_discount_bps, 'promo_code_id', v_promo_id,$o$,
  $n$'non_refundable_discount_bps', v_set.non_refundable_discount_bps, 'promo_code_id', v_promo_id,
    'lead_time_bps', (app.quote_lead_time(p_vehicle, p_pickup, o) ->> 'bps')::integer,   -- 0360
    'lead_time_hours', app.lead_time_hours(p_pickup),$n$);
-- a rental added by hand is priced by staff: no automatic adjustment (its booking is not locked either)
select pg_temp.patch_fn('app.manual_rental_quote_0058(uuid, jsonb)'::regprocedure,
  $o$'staff_rental_charge_cents', nullif(p ->> 'rental_charge_cents', ''),$o$,
  $n$'lead_time', 'none', 'staff_rental_charge_cents', nullif(p ->> 'rental_charge_cents', ''),$n$);
-- the fleet's price for chosen dates (the cards) is the rental charge with its adjustment
select pg_temp.patch_fn('app.search_available(timestamptz, timestamptz, jsonb)'::regprocedure,
  $o$(q.quote ->> 'rental_charge_cents')::bigint, (q.quote ->> 'subtotal_cents')::bigint,$o$,
  $n$(q.quote ->> 'rental_charge_cents')::bigint + coalesce((q.quote ->> 'lead_time_cents')::bigint, 0), (q.quote ->> 'subtotal_cents')::bigint,$n$);

-- A booking's price uses the percentage it locked; a price typed by hand (custom price, or a rental charge given for a
-- preview) has none.
alter function app.booking_price_spec(uuid, jsonb) rename to booking_price_spec_pre0360;
create function app.booking_price_spec(p_booking uuid, p_changes jsonb default '{}'::jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.booking_price_spec_pre0360(p_booking, p_changes) || jsonb_build_object(
           'lead_time_bps', case when b.custom_price_at is not null or b.price_tax is not null or (p_changes ->> 'rental_charge_cents') is not null then 0
                                 else coalesce(b.lead_time_bps, 0) end,
           'lead_time_hours', b.lead_time_hours)
    from bookings b where b.id = p_booking
$$;

-- ================================================================ 3. locked on the request
-- A request (status requested, not an Owner Booking or a placeholder) locks the tier of the moment it is made.
create or replace function app.bookings_lead_time_lock() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  l jsonb;
begin
  if new.booking_type::text <> 'owner' and new.status::text = 'requested' and new.lead_time_source is null
     and not coalesce(new.is_placeholder, false) and new.pickup_at is not null then
    l := app.lead_time_for(new.vehicle_id, new.pickup_at, coalesce(new.booked_at, now()));
    new.lead_time_bps := nullif((l ->> 'bps')::integer, 0);
    new.lead_time_hours := (l ->> 'hours')::numeric;
    new.lead_time_locked_at := now();
    new.lead_time_source := 'auto';
  end if;
  return new;
end $$;
drop trigger if exists bookings_lead_time_lock on bookings;
create trigger bookings_lead_time_lock before insert on bookings for each row execute function app.bookings_lead_time_lock();

-- Staff set the percentage on a request (an offer out is edited in place, which reopens it first): a number (basis points, 0 for none) or empty (back
-- to the tier when the request came in). The price follows at once.
create or replace function app.booking_lead_time_set(p_by uuid, p_booking uuid, p_bps integer, p_auto boolean default false) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  l jsonb;
begin
  if not (app.user_is_admin(p_by) or app.user_is_staff(p_by)) then raise exception 'Staff set the price of a booking' using errcode = '42501'; end if;
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.status::text in ('offered', 'pending_payment') then
    raise exception 'Booking % has an offer out: edit the offer to change its price', b.booking_number using errcode = '23514';
  end if;
  if b.status::text not in ('requested', 'tentative') then
    raise exception 'Booking % is %: its price is settled', b.booking_number, b.status using errcode = '23514';
  end if;
  if b.booking_type::text = 'owner' then raise exception 'An Owner Booking has no rental charge' using errcode = '22023'; end if;
  if p_auto then
    l := app.lead_time_for(b.vehicle_id, b.pickup_at, coalesce(b.requested_at, b.booked_at, b.created_at));
    update bookings set lead_time_bps = nullif((l ->> 'bps')::integer, 0), lead_time_hours = (l ->> 'hours')::numeric,
           lead_time_locked_at = now(), lead_time_source = 'auto' where id = b.id;
  else
    if p_bps is null or p_bps not between -5000 and 5000 then raise exception 'The lead-time adjustment is between -50%% and +50%%' using errcode = '22023'; end if;
    update bookings set lead_time_bps = nullif(p_bps, 0), lead_time_locked_at = now(), lead_time_source = 'staff' where id = b.id;
  end if;
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
    format('Lead-time pricing set by staff: %s', app.lead_time_text((select x.lead_time_bps from bookings x where x.id = b.id))), p_by, 'staff');
  perform app.sync_booking_price(b.id);
  select * into b from bookings where id = b.id;
  return jsonb_build_object('booking_id', b.id, 'lead_time_bps', b.lead_time_bps, 'lead_time_source', b.lead_time_source,
                            'total_due_at_booking_cents', b.total_due_at_booking_cents);
end $$;

-- The review screen and an offer edited in place: "lead_time": {"bps": n} or {"auto": true}.
alter function app.admin_apply_booking_edit(uuid, uuid, jsonb) rename to admin_apply_booking_edit_pre0360;
create function app.admin_apply_booking_edit(p_admin uuid, p_booking uuid, p jsonb) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.admin_apply_booking_edit_pre0360(p_admin, p_booking, p - 'lead_time');
  if jsonb_typeof(p -> 'lead_time') = 'object' then
    perform app.booking_lead_time_set(p_admin, p_booking, nullif(p -> 'lead_time' ->> 'bps', '')::integer,
                                      coalesce((p -> 'lead_time' ->> 'auto')::boolean, false));
  end if;
end $$;

-- ================================================================ 4. the line counts with the rental charge
-- every list of the lines that make the rental (owner revenue, commissions, payments tied to the rental, the parts of a
-- moved booking, the lines a booking's price owns)
do $$
declare
  f text;
begin
  foreach f in array array['app.sync_booking_price(uuid)', 'app.preview_booking_change(uuid, jsonb)', 'app.commission_line_types()',
                           'app.booking_split_parts(uuid)', 'app.booking_line_allocation(uuid)', 'app.booking_part_open_raw(uuid, text)',
                           'app.booking_tie_lines_raw(uuid, text, uuid)'] loop
    perform pg_temp.patch_fn(f::regprocedure, $o$'rental_charge', 'non_refundable_discount'$o$, $n$'rental_charge', 'lead_time', 'non_refundable_discount'$n$);
  end loop;
end $$;
-- never a fee set by hand
select pg_temp.patch_fn('app.apply_line_overrides(jsonb, jsonb, integer)'::regprocedure,
  $o$('rental_charge', 'non_refundable_discount', 'promo_discount'$o$, $n$('rental_charge', 'lead_time', 'non_refundable_discount', 'promo_discount'$n$);
-- never listed as a fee on the site, never a fee term of its own
select pg_temp.patch_fn('app.public_site_facts()'::regprocedure,
  $o$where f.code not in ('rental_charge', 'staff_discount'$o$, $n$where f.code not in ('rental_charge', 'lead_time', 'staff_discount'$n$);
select pg_temp.patch_fn('app.snapshot_booking_fee_terms(uuid)'::regprocedure,
  $o$code not in ('rental_charge', 'referral_kickback')$o$, $n$code not in ('rental_charge', 'lead_time', 'referral_kickback')$n$);
-- its words follow its percentage when staff change it
select pg_temp.patch_fn('app.put_price_line(uuid, jsonb)'::regprocedure,
  $o$     or ((v_ba is not null or v_line.charge_type = any (app.insurer_fee_codes())) and v_line.description is distinct from p_line ->> 'description')$o$,
  $n$     or (v_line.charge_type = 'lead_time' and v_line.description is distinct from p_line ->> 'description')
     or ((v_ba is not null or v_line.charge_type = any (app.insurer_fee_codes())) and v_line.description is distinct from p_line ->> 'description')$n$);
select pg_temp.patch_fn('app.put_price_line(uuid, jsonb)'::regprocedure,
  $o$description = case when v_ba is not null or charge_type = any (app.insurer_fee_codes()) then p_line ->> 'description'$o$,
  $n$description = case when charge_type = 'lead_time' or v_ba is not null or charge_type = any (app.insurer_fee_codes()) then p_line ->> 'description'$n$);

-- ================================================================ 5. per car in Admin
create or replace function app.vehicle_lead_time_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  v_mode text := coalesce(nullif(p ->> 'mode', ''), 'program');
  v_tiers jsonb := case when jsonb_typeof(p -> 'tiers') = 'array' then p -> 'tiers' end;
begin
  perform app.assert_admin(p_by);
  select * into v from vehicles where id = coalesce(nullif(p ->> 'vehicle_id', ''), p ->> 'vehicle')::uuid for update;
  if v.id is null then raise exception 'Vehicle not found' using errcode = 'P0002'; end if;
  if v_mode not in ('program', 'off', 'own') then raise exception 'Choose Program settings, off, or its own tiers' using errcode = '22023'; end if;
  if v_mode = 'own' and not app.lead_time_tiers_ok(v_tiers) then
    raise exception 'Each tier needs its hours before pickup (the first from 0, then higher) and a percentage between -50%% and +50%%' using errcode = '22023';
  end if;
  update vehicles set lead_time_mode = v_mode, lead_time_tiers = case when v_mode = 'own' then v_tiers else lead_time_tiers end where id = v.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'vehicle_lead_time', 'vehicles', v.id::text, jsonb_build_object('mode', v_mode, 'tiers', v_tiers));
  return jsonb_build_object('vehicle_id', v.id, 'lead_time_mode', v_mode, 'lead_time_tiers', case when v_mode = 'own' then v_tiers else v.lead_time_tiers end);
end $$;

-- the car's page in Admin shows Program settings' tiers beside its own choice
alter function app.admin_vehicle(uuid) rename to admin_vehicle_pre0360;
create function app.admin_vehicle(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.admin_vehicle_pre0360(p_vehicle) || jsonb_build_object('lead_time_program',
           jsonb_build_object('enabled', s.lead_time_enabled, 'tiers', s.lead_time_tiers))
    from app.settings() s
$$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0360;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'admin_do' and p_name = 'vehicle_lead_time' then
    perform app.door_begin(p_user, p_aal);
    return app.vehicle_lead_time_save(p_user, p);
  end if;
  if p_call = 'admin_do' and p_name = 'booking_lead_time' then
    perform app.door_begin(p_user, p_aal);
    return app.booking_lead_time_set(p_user, coalesce(nullif(p ->> 'booking_id', ''), p ->> 'booking')::uuid,
                                     nullif(p ->> 'bps', '')::integer, coalesce((p ->> 'auto')::boolean, false));
  end if;
  return app.door_pre0360(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ privileges
do $$
declare
  g text;
  pair text[];
begin
  foreach pair slice 1 in array array[
      array['app.price_lines(jsonb)', 'app.price_lines_pre0360(jsonb)'],
      array['app.booking_price_spec(uuid, jsonb)', 'app.booking_price_spec_pre0360(uuid, jsonb)'],
      array['app.admin_apply_booking_edit(uuid, uuid, jsonb)', 'app.admin_apply_booking_edit_pre0360(uuid, uuid, jsonb)'],
      array['app.admin_vehicle(uuid)', 'app.admin_vehicle_pre0360(uuid)'],
      array['app.door(uuid, text, text, text, jsonb)', 'app.door_pre0360(uuid, text, text, text, jsonb)']] loop
    execute format('revoke all on function %s from public, anon, authenticated', pair[1]);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, pair[2]::regprocedure, 'execute') then execute format('grant execute on function %s to %I', pair[1], g); end if;
    end loop;
    execute format('revoke all on function %s from public, anon, authenticated', pair[2]);
    execute format('grant execute on function %s to service_role', pair[2]);
  end loop;
end $$;
revoke all on function app.lead_time_for(uuid, timestamptz, timestamptz), app.quote_lead_time(uuid, timestamptz, jsonb), app.bookings_lead_time_lock(),
  app.booking_lead_time_set(uuid, uuid, integer, boolean), app.vehicle_lead_time_save(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.lead_time_for(uuid, timestamptz, timestamptz), app.quote_lead_time(uuid, timestamptz, jsonb), app.bookings_lead_time_lock(),
  app.booking_lead_time_set(uuid, uuid, integer, boolean), app.vehicle_lead_time_save(uuid, jsonb) to service_role;
-- the pure helpers (no data) are used by the checks and the price on every path
grant execute on function app.lead_time_tiers_ok(jsonb), app.lead_time_hours(timestamptz, timestamptz), app.lead_time_tier(jsonb, numeric),
  app.lead_time_text(integer) to anon, authenticated, service_role;
