-- 1201_r35h_extension_all_in.sql
-- Release 35, part H (docs/changes/2026-11-09-r35-offer-pricing-extensions-coverage.md), item 2.
-- The owner: "when renters extend, it should be based on the rates they're already paying (including all fees and taxes)
-- but averaged out per day for each day that they extend".
--   An extension costs the booking's all-in price a day for each added day: the total charged for the booked period (the
--   rental after its discounts, every fee, one-time fees included, and HST: total_due_at_booking_cents) divided by its
--   booked days. Added time under a whole day keeps the hourly rule (the hourly late fee for each started hour, with HST),
--   never more than an all-in day. No extension discount (the 0480 day discount, 0% since 1066, and the 10% off a few
--   hours are no longer applied). It replaces 1066's rule (the rental at the booked rate and per-trip fees scaled).
--   Paths: app.preview_extension (the renter's Extend page, its six offers, a date picked, the calendar's extension,
--   approval, payment: all read it) and staff making a confirmed or on-trip booking longer (app.booking_staff_edit, the
--   Money tab's Edit). A payment plan's next period and provisional dates (app.admin_apply_booking_edit) keep 1066's
--   same rate: they are not an extension the renter asks for.
--   The line: one "Extension: N days at $X/day (all-in)" line, tax included. Its HST is the booked period's share of HST
--   (hst_at_booking / total_due_at_booking), so the books split it as the booking was split and never add HST on top.
--   Late returns are unchanged (the daily cost of each extra day plus the hourly late fee).
--   An insurer-billed booking (bill_to not the renter) and an Owner Booking keep their pricing.
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

-- the booked period's all-in price: what the renter was charged for it (tax included), its HST and its days
create function app.booking_all_in(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with l as (
    select coalesce(sum(x.amount_cents + x.hst_cents), 0)::bigint as total, coalesce(sum(x.hst_cents), 0)::bigint as hst
      from booking_line_items x
     where x.booking_id = p_booking and x.stage = 'booking' and x.voided_at is null and x.charged_to_renter and x.extension_id is null),
  d as (
    select greatest(coalesce(b.billable_days, 0) - coalesce((select sum(e.new_days - e.previous_days) from booking_extensions e
                                                               where e.booking_id = b.id and e.status = 'confirmed'), 0), 1) as days
      from bookings b where b.id = p_booking)
  select jsonb_build_object('total_cents', l.total, 'hst_cents', l.hst, 'days', d.days, 'per_day_cents', round(l.total::numeric / d.days)::bigint)
    from l, d
$$;
comment on function app.booking_all_in(uuid) is 'The booked period''s all-in price (1201): total charged with HST, its HST, its days and the price a day; extensions are charged at that price a day.';

-- the price of added time at the all-in rate: whole days at the price a day, the hours left at the hourly rule (never
-- more than a day); the HST share of the booked period. p_secs: the time added.
create function app.extension_all_in(p_booking uuid, p_secs numeric) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  a jsonb := app.booking_all_in(p_booking);
  v_total bigint := (a ->> 'total_cents')::bigint;
  v_hst_all bigint := (a ->> 'hst_cents')::bigint;
  v_days integer := (a ->> 'days')::integer;
  v_day bigint := (a ->> 'per_day_cents')::bigint;
  v_whole integer := floor(greatest(p_secs, 0) / 86400)::integer;
  v_hours integer;
  v_hourly bigint;
  v_hours_pre bigint;
  v_part_total bigint := 0;
  v_part_hst bigint := 0;
  v_days_total bigint;
  v_days_hst bigint;
  v_capped boolean := false;
  v_sum bigint;
  v_hst bigint;
  v_desc text;
begin
  select * into b from bookings where id = p_booking;
  v_hours := ceil(round(greatest(p_secs - v_whole * 86400, 0)) / 3600.0)::integer;
  if v_hours >= 24 then v_whole := v_whole + 1; v_hours := 0; end if;
  v_days_total := round(v_total::numeric * v_whole / v_days)::bigint;
  v_days_hst := case when v_total > 0 then round(v_days_total::numeric * v_hst_all / v_total)::bigint else 0 end;
  if v_hours > 0 then
    v_hourly := coalesce(app.late_fee_hourly_cents(p_booking), 0);
    v_hours_pre := v_hourly * v_hours;
    if v_hourly <= 0 or v_hours_pre + public.calc_hst(v_hours_pre, b.hst_bps) >= v_day then
      v_capped := true;
      v_part_total := v_day;
      v_part_hst := case when v_total > 0 then round(v_day::numeric * v_hst_all / v_total)::bigint else 0 end;
    else
      v_part_total := v_hours_pre + public.calc_hst(v_hours_pre, b.hst_bps);
      v_part_hst := public.calc_hst(v_hours_pre, b.hst_bps);
    end if;
  end if;
  v_sum := v_days_total + v_part_total;
  v_hst := v_days_hst + v_part_hst;
  v_desc := case
    when v_whole > 0 then format('Extension: %s %s at %s/day (all-in)', v_whole, case when v_whole = 1 then 'day' else 'days' end, app.fmt_money(v_day))
         || case when v_hours > 0 then format(' and %s %s', v_hours, case when v_hours = 1 then 'hour' else 'hours' end)
                                    || case when v_capped then ' (one more day)' else ' at the hourly rate' end else '' end
    when v_capped then format('Extension: %s %s, charged as 1 day at %s/day (all-in)', v_hours, case when v_hours = 1 then 'hour' else 'hours' end, app.fmt_money(v_day))
    else format('Extension: %s %s at the hourly rate (HST included)', v_hours, case when v_hours = 1 then 'hour' else 'hours' end) end;
  return jsonb_build_object('total_cents', v_sum, 'hst_cents', v_hst, 'amount_cents', v_sum - v_hst, 'per_day_cents', v_day,
    'whole_days', v_whole, 'hours', v_hours, 'hours_capped', v_capped, 'hourly_cents', v_hourly,
    'booked_total_cents', v_total, 'booked_hst_cents', v_hst_all, 'booked_days', v_days, 'description', v_desc,
    -- the one line: tax included, its HST the booked period's share (never HST on top of the all-in price)
    'line', app.price_line('rental_charge', greatest(v_whole, 1), v_day, v_sum - v_hst, b.hst_bps, v_desc, null,
              jsonb_build_object('all_in', true, 'per_day_cents', v_day, 'days', v_whole, 'hours', v_hours, 'tax_included_cents', v_sum,
                                 'booked_total_cents', v_total, 'booked_days', v_days))
            || jsonb_build_object('hst_cents', v_hst, 'hst_applies', v_hst <> 0, 'price_tax', 'included'));
end $$;

-- ================================================================ the renter's extension (and every path that reads its price)
alter function app.preview_extension(uuid, timestamptz, timestamptz) rename to preview_extension_pre1201;
create function app.preview_extension(p_booking uuid, p_new_return timestamptz, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.preview_extension_pre1201(p_booking, p_new_return, p_now);
  b bookings;
  x jsonb;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null or b.booking_type = 'owner' or b.bill_to <> 'renter' or (v ->> 'new_days') is null
     or p_new_return is null or p_new_return <= b.return_at then return v; end if;
  x := app.extension_all_in(p_booking, extract(epoch from (p_new_return - b.return_at)));
  return v || jsonb_build_object(
    'lines', jsonb_build_array(x -> 'line'),
    'pricing', case when (x ->> 'whole_days')::integer = 0 and not (x ->> 'hours_capped')::boolean then 'short' else 'days' end,
    'all_in', true, 'per_day_cents', (x ->> 'per_day_cents')::bigint, 'added_whole_days', (x ->> 'whole_days')::integer, 'added_part_hours', (x ->> 'hours')::integer,
    'booked_total_cents', (x ->> 'booked_total_cents')::bigint, 'booked_days', (x ->> 'booked_days')::integer,
    'rental_difference_cents', (x ->> 'amount_cents')::bigint, 'new_rental_charge_cents', b.rental_charge_cents + (x ->> 'amount_cents')::bigint,
    'fees_difference_cents', 0, 'hst_cents', (x ->> 'hst_cents')::bigint, 'total_cents', (x ->> 'total_cents')::bigint,
    'regular_rental_cents', (x ->> 'amount_cents')::bigint, 'regular_total_cents', (x ->> 'total_cents')::bigint, 'save_cents', 0,
    'discount_bps', 0, 'same_rate', true, 'tax_included', true);
end $$;
select pg_temp.copy_grants('app.preview_extension(uuid, timestamptz, timestamptz)'::regprocedure, 'app.preview_extension_pre1201(uuid, timestamptz, timestamptz)'::regprocedure);

-- the six offers say the price a day too (the renter sees it before paying)
alter function app.extension_offers(uuid, timestamptz) rename to extension_offers_pre1201;
create function app.extension_offers(p_booking uuid, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.extension_offers_pre1201(p_booking, p_now);
  b bookings;
begin
  select * into b from bookings where id = p_booking;
  if v is null or b.id is null or b.booking_type = 'owner' or b.bill_to <> 'renter' then return v; end if;
  return v || jsonb_build_object('per_day_cents', (app.booking_all_in(p_booking) ->> 'per_day_cents')::bigint, 'all_in', true, 'discount_bps', 0, 'short_discount_bps', 0);
end $$;
select pg_temp.copy_grants('app.extension_offers(uuid, timestamptz)'::regprocedure, 'app.extension_offers_pre1201(uuid, timestamptz)'::regprocedure);

-- ================================================================ staff making a live booking longer
-- the target: the booked period's all-in total plus the all-in price of the added time. The per-trip fees stay as booked,
-- the rental charge is solved in dry runs so the booking's new total is the target (to the cent where rounding allows).
create function app.extension_all_in_target(p_booking uuid, p_new_return timestamptz) returns bigint
language sql stable security definer set search_path = public, app as $$
  select (app.booking_all_in(b.id) ->> 'total_cents')::bigint + (app.extension_all_in(b.id, extract(epoch from (p_new_return - b.return_at))) ->> 'total_cents')::bigint
    from bookings b where b.id = p_booking
$$;

-- a dry run of a staff edit with a given rental charge: the total it would give (nothing is kept)
create function app.ext_staff_trial(p_kind text, p_by uuid, p_booking uuid, p jsonb, p_rental bigint, p_fees jsonb) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  v_total bigint;
begin
  begin
    perform app.ext_staff_apply(p_kind, p_by, p_booking, p, p_rental, p_fees, 'trial');
    select total_due_at_booking_cents into v_total from bookings where id = p_booking;
    raise exception using errcode = 'P0001', message = 'all-in-dry-run';
  exception when others then
    if sqlerrm <> 'all-in-dry-run' then raise; end if;
  end;
  return v_total;
end $$;

-- the edit itself, with the rental charge given (before tax) and the per-trip fees kept as booked
create function app.ext_staff_apply(p_kind text, p_by uuid, p_booking uuid, p jsonb, p_rental bigint, p_fees jsonb, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c jsonb := coalesce(p -> 'changes', '{}'::jsonb);
begin
  if p_kind = 'staff_edit' then
    return app.booking_staff_edit_pre1066(p_by, p || jsonb_build_object('changes', c || jsonb_build_object('rental_charge_cents', p_rental),
      'lines', coalesce(p_fees, '{}'::jsonb) || coalesce(case when jsonb_typeof(p -> 'lines') = 'object' then p -> 'lines' end, '{}'::jsonb),
      'reason', coalesce(nullif(btrim(coalesce(p ->> 'reason', '')), ''), p_reason)));
  end if;
  raise exception 'Unknown edit %', p_kind;
end $$;

-- the rental charge that makes the longer booking's total the target: two dry runs (the rental as booked, then with the
-- difference before tax), then the line through them (a non-refundable discount, a promo or HST rounding move it)
create function app.ext_staff_solve(p_kind text, p_by uuid, p_booking uuid, p jsonb, p_target bigint, p_fees jsonb) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  t0 bigint;
  t1 bigint;
  r1 bigint;
  r bigint;
  k integer;
begin
  select * into b from bookings where id = p_booking;
  t0 := app.ext_staff_trial(p_kind, p_by, p_booking, p, b.rental_charge_cents, p_fees);
  r1 := b.rental_charge_cents + round((p_target - t0) * 10000.0 / (10000 + b.hst_bps))::bigint;
  t1 := app.ext_staff_trial(p_kind, p_by, p_booking, p, r1, p_fees);
  r := case when t1 = p_target or t1 = t0 then r1 else r1 + round((p_target - t1)::numeric * (r1 - b.rental_charge_cents) / (t1 - t0))::bigint end;
  -- to the cent where the rounding allows
  if r <> r1 then
    for k in 0 .. 2 loop
      t1 := app.ext_staff_trial(p_kind, p_by, p_booking, p, r, p_fees);
      exit when t1 = p_target;
      r := r + case when t1 < p_target then 1 else -1 end;
    end loop;
  end if;
  return greatest(r, 0);
end $$;

alter function app.booking_staff_edit(uuid, jsonb) rename to booking_staff_edit_pre1201;
create function app.booking_staff_edit(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  c jsonb := coalesce(p -> 'changes', '{}'::jsonb);
  v_to timestamptz;
  v_target bigint;
  v_fees jsonb;
begin
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
  v_to := nullif(c ->> 'return_at', '')::timestamptz;
  if b.id is null or b.booking_type = 'owner' or b.bill_to <> 'renter' or b.status::text not in ('confirmed', 'on_rent')
     or v_to is null or v_to <= b.return_at or (c ? 'pickup_at' and nullif(c ->> 'pickup_at', '')::timestamptz is distinct from b.pickup_at)
     or nullif(c ->> 'rental_charge_cents', '') is not null or coalesce(b.billable_days, 0) = 0
     or app.booking_edit_refusal(p_by, b) is not null then
    return app.booking_staff_edit_pre1201(p_by, p);
  end if;
  v_target := app.extension_all_in_target(b.id, v_to);
  select coalesce(jsonb_object_agg(x.charge_type, x.amount_cents), '{}'::jsonb) into v_fees from app.booking_per_trip_fees(b.id) x;
  return app.ext_staff_apply('staff_edit', p_by, b.id, p, app.ext_staff_solve('staff_edit', p_by, b.id, p, v_target, v_fees), v_fees,
    format('Extended at the booking''s all-in price a day (%s/day, HST included)', app.fmt_money((app.booking_all_in(b.id) ->> 'per_day_cents')::bigint)));
end $$;
select pg_temp.copy_grants('app.booking_staff_edit(uuid, jsonb)'::regprocedure, 'app.booking_staff_edit_pre1201(uuid, jsonb)'::regprocedure);

-- no extension discount: the settings stay for the record, unused (and 0)
update program_settings set extension_discount_bps = 0, extension_short_discount_bps = 0;
alter table program_settings alter column extension_short_discount_bps set default 0;
comment on column program_settings.extension_discount_bps is 'Unused since 1201: an extension costs the booking''s all-in price a day, with no discount.';
comment on column program_settings.extension_short_discount_bps is 'Unused since 1201: added hours cost the hourly late fee with HST, never more than an all-in day, with no discount.';

-- the public FAQ says the rule
update site_content_blocks set data = replace(data::text,
    'A day or more costs the same a day as your booking, with per-trip fees for the added days at the same rate, and a few hours are {{extShortDisc}} off the late fee.',
    'Each added day costs your booking''s all-in price a day (what you paid for the booking, fees and HST included, divided by its days), and a few hours cost the hourly late fee, never more than a day.')::jsonb,
    updated_at = now()
 where kind = 'faq' and data::text like '%a few hours are {{extShortDisc}} off the late fee.%';

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['booking_all_in', 'extension_all_in', 'extension_all_in_target', 'extension_offers_pre1201', 'ext_staff_trial', 'ext_staff_apply', 'ext_staff_solve', 'preview_extension_pre1201',
                                                               'booking_staff_edit_pre1201'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
