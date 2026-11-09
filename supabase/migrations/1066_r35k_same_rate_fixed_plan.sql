-- 1066_r35k_same_rate_fixed_plan.sql
-- Release 35, part K (docs/changes/2026-11-09-r35-same-rate-plans-location.md).
--   1. The owner's rule (item 10): a booking made longer (Edit dates, a renter's extension, a weekly or monthly plan rolling
--      on) is charged for the added time at exactly the effective rate of the booked period: the rental per day after its
--      discounts, and every per-trip fee (the Protection Plan, a typed price) scaled with the length. Per-day fees (young
--      driver, additional driver, seats) already count per day. One-time fees (delivery, pickup, an add-on item) never scale.
--      $525.45 a week stays $525.45 for each added week. Paths: app.admin_apply_booking_edit (Edit dates, and the plan's
--      next period, which moves the return the same way), app.booking_staff_edit (Edit on the booking) and app.preview_extension (the renter's extension, its offers,
--      approval and the calendar move all read it). Hours added (under a day) keep the hourly extension price.
--   2. A fixed amount per plan payment (item 13): Change the plan takes an Admin's fixed amount; every payment is that
--      amount and the last takes the remainder. The booking total and the payments made never change.
-- No applied migration is edited: both functions are wrapped; app.booking_pay_schedule is patched.
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '1066: the text to change was not found in %: %', p_sig, left(p_old, 120); end if;
  execute replace(d, p_old, p_new);
end $$;
create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. the same rate
-- the per-trip fee lines of a booking (the ones that scale with its length): flat fees for the rental, never delivery,
-- pickup or an add-on item; the extension lines left out
create function app.booking_per_trip_fees(p_booking uuid) returns table (charge_type text, amount_cents bigint)
language sql stable security definer set search_path = public, app as $$
  select l.charge_type, sum(l.amount_cents)::bigint
    from booking_line_items l join fee_types f on f.code = l.charge_type
   where l.booking_id = p_booking and l.voided_at is null and l.extension_id is null and l.charged_to_renter
     and f.stage = 'booking' and f.family = 'fee' and f.unit = 'flat' and f.per_what = 'rental'
     and l.charge_type not in ('delivery', 'pickup')
   group by l.charge_type
$$;

-- the rental per day of the booked period, after its discounts (the rental family's lines over the billable days)
create function app.booking_rental_per_day(p_booking uuid) returns numeric
language sql stable security definer set search_path = public, app as $$
  select sum(l.amount_cents)::numeric / greatest(max(b.billable_days), 1)
    from bookings b join booking_line_items l on l.booking_id = b.id and l.voided_at is null and l.extension_id is null and l.charged_to_renter
    join fee_types f on f.code = l.charge_type and f.stage = 'booking' and f.family = 'rental'
   where b.id = p_booking
$$;

alter function app.admin_apply_booking_edit(uuid, uuid, jsonb) rename to admin_apply_booking_edit_pre1066;
create function app.admin_apply_booking_edit(p_admin uuid, p_booking uuid, p jsonb) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  b0 bookings;
  b1 bookings;
  v_fees jsonb;
  v_ratio numeric;
begin
  select * into b0 from bookings where id = p_booking;
  select coalesce(jsonb_object_agg(x.charge_type, x.amount_cents), '{}'::jsonb) into v_fees from app.booking_per_trip_fees(p_booking) x;
  perform app.admin_apply_booking_edit_pre1066(p_admin, p_booking, p);
  select * into b1 from bookings where id = p_booking;
  -- the dates changed the length of a booking already priced, and this edit typed no price of its own: the same rate
  if b0.status::text in ('pending_payment', 'confirmed', 'on_rent') and b0.booking_type <> 'owner' and coalesce(b0.billable_days, 0) > 0
     and b1.billable_days is distinct from b0.billable_days
     and not (coalesce(p -> 'changes', '{}'::jsonb) ? 'rental_charge_cents') and not (p ? 'line_overrides') then
    v_ratio := b1.billable_days::numeric / b0.billable_days;
    perform app.admin_apply_booking_edit_pre1066(p_admin, p_booking, jsonb_strip_nulls(jsonb_build_object(
      'changes', jsonb_build_object('rental_charge_cents', round(b0.rental_charge_cents * v_ratio)::bigint, 'price_tax', 'plus',
                                    'price_reason', format('Same rate as the booked period (%s to %s days)', b0.billable_days, b1.billable_days)),
      'line_overrides', case when v_fees <> '{}'::jsonb then (select jsonb_object_agg(k, round((v #>> '{}')::numeric * v_ratio)::bigint) from jsonb_each(v_fees) e(k, v)) end,
      'fee_reason', case when v_fees <> '{}'::jsonb then 'Same rate as the booked period: per-trip fees scaled with the length' end)));
    perform app.log_booking_event(p_booking, 'adjusted', b1.status::text, b1.status::text, null,
      format('Length changed from %s to %s days: the rental and the per-trip fees kept the booked period''s rate', b0.billable_days, b1.billable_days), p_admin, 'staff',
      jsonb_build_object('same_rate', true, 'ratio', v_ratio));
  end if;
end $$;
select pg_temp.copy_grants('app.admin_apply_booking_edit(uuid, uuid, jsonb)'::regprocedure, 'app.admin_apply_booking_edit_pre1066(uuid, uuid, jsonb)'::regprocedure);

-- Edit dates on a booking (booking_staff_edit, the Money tab's Edit): the length changed and no price typed: the rental keeps
-- the booked period's rate (it was repriced from the rate card), and each per-trip fee scales with the length
alter function app.booking_staff_edit(uuid, jsonb) rename to booking_staff_edit_pre1066;
create function app.booking_staff_edit(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  c jsonb := coalesce(p -> 'changes', '{}'::jsonb);
  v_days integer;
  v_ratio numeric;
  v_lines jsonb := coalesce(case when jsonb_typeof(p -> 'lines') = 'object' then p -> 'lines' end, '{}'::jsonb);
  x record;
begin
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
  if b.id is not null and b.booking_type <> 'owner' and coalesce(b.billable_days, 0) > 0 and (c ? 'pickup_at' or c ? 'return_at') and nullif(c ->> 'rental_charge_cents', '') is null then
    v_days := public.calc_billable_days(coalesce(nullif(c ->> 'pickup_at', '')::timestamptz, b.pickup_at), coalesce(nullif(c ->> 'return_at', '')::timestamptz, b.return_at));
    if v_days <> b.billable_days then
      v_ratio := v_days::numeric / b.billable_days;
      c := c || jsonb_build_object('rental_charge_cents', round(b.rental_charge_cents * v_ratio)::bigint);
      for x in select * from app.booking_per_trip_fees(b.id) loop
        if not v_lines ? x.charge_type then v_lines := v_lines || jsonb_build_object(x.charge_type, round(x.amount_cents * v_ratio)::bigint); end if;
      end loop;
      p := p || jsonb_build_object('changes', c, 'lines', v_lines,
        'reason', coalesce(nullif(btrim(coalesce(p ->> 'reason', '')), ''), format('Same rate as the booked period (%s to %s days)', b.billable_days, v_days)));
    end if;
  end if;
  return app.booking_staff_edit_pre1066(p_by, p);
end $$;
select pg_temp.copy_grants('app.booking_staff_edit(uuid, jsonb)'::regprocedure, 'app.booking_staff_edit_pre1066(uuid, jsonb)'::regprocedure);

-- an extension of whole days: the rental per day after discounts, plus each per-trip fee scaled, plus the per-day fees
alter function app.preview_extension(uuid, timestamptz, timestamptz) rename to preview_extension_pre1066;
create function app.preview_extension(p_booking uuid, p_new_return timestamptz, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.preview_extension_pre1066(p_booking, p_new_return, p_now);
  b bookings;
  v_added integer;
  v_rental bigint;
  v_lines jsonb;
  x record;
  v_fees bigint;
  v_hst bigint;
  v_regular bigint;
  -- an extension offer's discount of a day or more: Program settings extension_discount_bps, 0 since 1066 (an extension never lowers the rate)
  v_bps integer := case when coalesce((v ->> 'offer')::boolean, false) and v ->> 'pricing' = 'days' then (app.settings()).extension_discount_bps else 0 end;
  v_reg_hst bigint;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null or b.booking_type = 'owner' or coalesce(v ->> 'pricing', '') not in ('days', 'regular') or coalesce(b.billable_days, 0) = 0 then return v; end if;
  v_added := (v ->> 'new_days')::integer - b.billable_days;
  if v_added <= 0 then return v; end if;
  -- the booked rate; an extension offer's discount (0480) still comes off it, the booked rate shown as the regular price
  v_regular := round(coalesce(app.booking_rental_per_day(p_booking), b.daily_rate_cents) * v_added)::bigint;
  v_rental := round(v_regular * (10000 - v_bps) / 10000.0)::bigint;
  -- the per-day fees as computed; the rental and its discounts replaced by the booked rate
  select coalesce(jsonb_agg(l), '[]'::jsonb) into v_lines from jsonb_array_elements(v -> 'lines') l
   where l ->> 'charge_type' not in ('rental_charge', 'non_refundable_discount', 'promo_discount', 'staff_discount', 'lead_time');
  v_lines := jsonb_build_array(app.price_line('rental_charge', v_added, round(v_rental::numeric / v_added)::bigint, v_rental, b.hst_bps,
               format('Extension: %s added %s at the booked rate', v_added, case when v_added = 1 then 'day' else 'days' end), null,
               jsonb_build_object('same_rate', true))) || v_lines;
  for x in select * from app.booking_per_trip_fees(p_booking) loop
    v_lines := v_lines || app.price_line(x.charge_type, 1, round(x.amount_cents::numeric * v_added / b.billable_days)::bigint,
                 round(x.amount_cents::numeric * v_added / b.billable_days)::bigint, b.hst_bps,
                 format('%s for the added time, at the booked rate', (select f.label from fee_types f where f.code = x.charge_type)));
  end loop;
  select coalesce(sum((l ->> 'amount_cents')::bigint) filter (where l ->> 'charge_type' <> 'rental_charge'), 0), coalesce(sum((l ->> 'hst_cents')::bigint), 0)
    into v_fees, v_hst from jsonb_array_elements(v_lines) l;
  v_reg_hst := v_hst - coalesce((select (l ->> 'hst_cents')::bigint from jsonb_array_elements(v_lines) l where l ->> 'charge_type' = 'rental_charge' limit 1), 0)
               + (app.price_line('rental_charge', 1, v_regular, v_regular, b.hst_bps, null, null, null) ->> 'hst_cents')::bigint;
  return v || jsonb_build_object('lines', v_lines, 'rental_difference_cents', v_rental, 'new_rental_charge_cents', b.rental_charge_cents + v_rental,
    'fees_difference_cents', v_fees, 'hst_cents', v_hst, 'total_cents', v_rental + v_fees + v_hst, 'regular_rental_cents', v_regular,
    'regular_total_cents', v_regular + v_fees + v_reg_hst, 'save_cents', (v_regular + v_fees + v_reg_hst) - (v_rental + v_fees + v_hst),
    'discount_bps', v_bps, 'same_rate', true);
end $$;
select pg_temp.copy_grants('app.preview_extension(uuid, timestamptz, timestamptz)'::regprocedure, 'app.preview_extension_pre1066(uuid, timestamptz, timestamptz)'::regprocedure);

-- the owner's rule: an extension never lowers the booked rate. The offer's discount of a day or more stays a Program setting, now 0%
alter table program_settings alter column extension_discount_bps set default 0;
update program_settings set extension_discount_bps = 0 where id = (app.settings()).id;
comment on column program_settings.extension_discount_bps is 'Extension of a day or more: this share off the booked rate for the added days (1066: default 0%, an extension costs the same a day as the booking).';
-- the public FAQ no longer promises a discount on a day or more
update site_content_blocks set data = replace(data::text, 'A day or more is {{extDisc}} off the regular rate, and a few hours are {{extShortDisc}} off the late fee.', 'A day or more costs the same a day as your booking, with per-trip fees for the added days at the same rate, and a few hours are {{extShortDisc}} off the late fee.')::jsonb, updated_at = now()
 where kind = 'faq' and data::text like '%{{extDisc}} off the regular rate%';

-- ================================================================ 2. a fixed amount per plan payment
alter table bookings add column if not exists pay_fixed_cents bigint check (pay_fixed_cents is null or pay_fixed_cents > 0);
comment on column bookings.pay_fixed_cents is 'Payment plan (1066): an Admin''s fixed amount per payment; the last payment takes the remainder. The total never changes.';

select pg_temp.patch_fn('app.booking_pay_schedule(uuid, timestamptz)'::regprocedure,
  'v_amt := case when i = v_n then v_owed - v_cum else round(v_owed * extract(epoch from v_end - v_start) / v_total_s)::bigint end;',
  'v_amt := case when i = v_n then v_owed - v_cum when b.pay_fixed_cents is not null then least(b.pay_fixed_cents, v_owed - v_cum)
                 else round(v_owed * extract(epoch from v_end - v_start) / v_total_s)::bigint end;');
select pg_temp.patch_fn('app.booking_pay_schedule(uuid, timestamptz)'::regprocedure,
  '''plan'', v_plan, ''set'', b.pay_every is not null,', '''plan'', v_plan, ''set'', b.pay_every is not null, ''fixed_cents'', b.pay_fixed_cents,');

alter function app.booking_pay_every_set(uuid, jsonb) rename to booking_pay_every_set_pre1066;
create function app.booking_pay_every_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb;
  v_fixed bigint := nullif(p ->> 'fixed_cents', '')::bigint;
  b bookings;
begin
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
  if v_fixed is not null and not app.user_is_admin(p_by) then raise exception 'Only an Admin sets a fixed amount per payment' using errcode = '42501'; end if;
  if v_fixed is not null and coalesce(p ->> 'pay_every', '') not in ('weekly', 'biweekly', 'monthly') then
    raise exception 'A fixed amount is for a weekly, every 2 weeks or monthly plan' using errcode = '22023';
  end if;
  v := app.booking_pay_every_set_pre1066(p_by, p - 'fixed_cents');
  if b.id is not null and (v_fixed is distinct from b.pay_fixed_cents) and (v_fixed is not null or app.user_is_admin(p_by)) then
    update bookings set pay_fixed_cents = v_fixed where id = b.id;
    perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
      case when v_fixed is null then 'Payment plan: the fixed amount per payment removed' else format('Payment plan: %s per payment, the last one the remainder', app.fmt_money(v_fixed)) end,
      p_by, 'staff', jsonb_build_object('pay_fixed_cents', v_fixed));
    v := v || jsonb_build_object('changed', true, 'pay', app.booking_pay_schedule(b.id));
  end if;
  return v;
end $$;
select pg_temp.copy_grants('app.booking_pay_every_set(uuid, jsonb)'::regprocedure, 'app.booking_pay_every_set_pre1066(uuid, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['booking_per_trip_fees', 'booking_rental_per_day', 'admin_apply_booking_edit_pre1066', 'booking_staff_edit_pre1066', 'preview_extension_pre1066', 'booking_pay_every_set_pre1066'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
