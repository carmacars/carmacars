-- 0250: choices drive charges (Release 24, docs/changes/2026-11-04-send-an-offer-one-flow.md). Numbered 0250 so it never
-- clashes with a parallel branch at 0242 and up.
--
-- The owner: "if the delivery is removed in one spot, the charge for it has to be manually removed in another spot".
-- A fee set by hand (0132, booking_line_overrides and the line_overrides of a quote, an offer or a rental entered) was
-- added as a line of its own when the price had no line of that key ("a Protection Plan or delivery fee not priced"),
-- even when the choice that makes the line was gone: a delivery fee with the car handed over at our location, a
-- Protection Plan price with option 1, a young driver fee for a renter of 30, a winter tire with no winter tire.
--
-- 1. app.line_overrides_live(spec): the fees set by hand whose choice is still chosen. The delivery fee only with a
--    delivery or an airport for the pickup, the collection fee (pickup) only with one for the return, the Protection
--    Plan only with option 3, a young driver fee only with a driver of that age band (or an age not known), the
--    additional driver fee only with an additional driver. The price (app.price_lines) takes only these, so a fee set by
--    hand never outlives its choice, in a quote, an offer, a rental entered or a booking repriced.
-- 2. A winter tire or a baby seat set by hand changes its line; it never makes one (the add-on or the extra does).
-- 3. The booking's price spec says how the car is handed over and taken back (pickup_delivered, return_collected), so a
--    delivery with no distance yet (no fee priced) still takes a fee typed by hand.
-- 4. A fee set by hand on a booking is deleted when its choice goes (the place changed to our location, the coverage
--    changed from option 3, the add-on cancelled), so choosing it again starts from the automatic amount.
-- The pricing itself is unchanged: a fee whose choice is chosen is priced exactly as before.

create or replace function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0250: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the fees set by hand whose choice is chosen
create or replace function app.line_overrides_live(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_over jsonb := case when jsonb_typeof(p -> 'line_overrides') = 'object' then p -> 'line_overrides' else '{}'::jsonb end;
  v_drivers jsonb := case when jsonb_typeof(p -> 'drivers') = 'array' then p -> 'drivers' else null end;
  v_out jsonb := '{}'::jsonb;
  k text;
  v_live boolean;
  v_unknown_age boolean;
begin
  if v_over = '{}'::jsonb then return v_over; end if;
  -- a driver whose age is not known (assumed, or no date of birth): a young driver fee typed by hand is kept
  v_unknown_age := v_drivers is null or jsonb_array_length(v_drivers) = 0
    or exists (select 1 from jsonb_array_elements(v_drivers) d where coalesce((d ->> 'assumed')::boolean, false) or d ->> 'age_band' is null);
  for k in select x from jsonb_object_keys(v_over) x loop
    v_live := case
      when k = 'delivery' then case
        when p ? 'pickup_delivered' then coalesce((p ->> 'pickup_delivered')::boolean, false)
        when jsonb_typeof(p -> 'delivery_detail') = 'object' then coalesce(p -> 'delivery_detail' ->> 'kind', 'delivery') in ('delivery', 'airport')
        else true end
      when k = 'pickup' then case
        when p ? 'return_collected' then coalesce((p ->> 'return_collected')::boolean, false)
        when jsonb_typeof(p -> 'pickup_detail') = 'object' then coalesce(p -> 'pickup_detail' ->> 'kind', 'delivery') in ('delivery', 'airport')
        else true end
      when k = 'coverage_sold' then not (p ? 'coverage_option') or coalesce(p ->> 'coverage_option', '') = '3'
      when k in ('young_driver_18_20', 'young_driver_21_25') then v_unknown_age
        or exists (select 1 from jsonb_array_elements(v_drivers) d where d ->> 'age_band' = replace(substr(k, 14), '_', '_to_'))
      when k = 'additional_driver' then v_drivers is null
        or exists (select 1 from jsonb_array_elements(v_drivers) d where d ->> 'role' = 'additional')
      else true end;
    if v_live then v_out := v_out || jsonb_build_object(k, v_over -> k); end if;
  end loop;
  return v_out;
end $$;
comment on function app.line_overrides_live(jsonb) is
  'The fees set by hand of a price spec whose choice is still chosen (0250): delivery and collection with a delivery or an airport, the Protection Plan with option 3, a young driver fee with a driver of that band, the additional driver fee with an additional driver. app.price_lines takes only these.';
revoke all on function app.line_overrides_live(jsonb) from public, anon, authenticated;
grant execute on function app.line_overrides_live(jsonb) to service_role;

select pg_temp.patch_fn('app.price_lines_pre0191(jsonb)'::regprocedure,
  $o$    v_lines := app.apply_line_overrides(v_lines, p -> 'line_overrides', v_hst);$o$,
  $n$    v_lines := app.apply_line_overrides(v_lines, app.line_overrides_live(p), v_hst);   -- 0250: only while the choice is chosen$n$);

-- ================================================================ 2. an add-on's charge set by hand never makes a line
select pg_temp.patch_fn('app.apply_line_overrides(jsonb, jsonb, integer)'::regprocedure,
  $o$f.code not in ('rental_charge', 'non_refundable_discount', 'promo_discount', 'staff_discount', 'addon')$o$,
  $n$f.code not in ('rental_charge', 'non_refundable_discount', 'promo_discount', 'staff_discount', 'addon', 'winter_tire', 'baby_seat')$n$);

-- ================================================================ 3. the booking's spec says how the car is handed over
create or replace function app.booking_price_spec(p_booking uuid, p_changes jsonb default '{}'::jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.booking_price_spec_pre0191(p_booking, p_changes) || jsonb_build_object(
           'insurer_billed', app.booking_bills_insurer(b),
           'insurer_fees', coalesce((select jsonb_object_agg(f.fee_type_code, f.rate_cents) from booking_insurer_fees f where f.booking_id = p_booking), '{}'::jsonb),
           -- 0250: the choices the fees set by hand depend on
           'pickup_delivered', b.pickup_method = 'delivered', 'return_collected', b.return_method = 'picked_up')
    from bookings b where b.id = p_booking
$$;

-- ================================================================ 4. a fee set by hand on a booking goes with its choice
create or replace function app.line_overrides_follow_choices() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if tg_table_name = 'bookings' then
    delete from booking_line_overrides o where o.booking_id = new.id and (
         (o.line_key = 'delivery' and new.pickup_method is distinct from 'delivered')
      or (o.line_key = 'pickup' and new.return_method is distinct from 'picked_up')
      or (o.line_key = 'coverage_sold' and new.coverage_option is distinct from 3));
    return new;
  end if;
  -- booking_addons: cancelled, declined or deleted, and no other live row of the same add-on on the booking
  if tg_op = 'DELETE' or new.status in ('cancelled', 'declined') then
    delete from booking_line_overrides o
     where o.booking_id = coalesce(new.booking_id, old.booking_id)
       and o.line_key = 'addon:' || (select a.code from addons a where a.id = coalesce(new.addon_id, old.addon_id))
       and not exists (select 1 from booking_addons x where x.booking_id = coalesce(new.booking_id, old.booking_id) and x.addon_id = coalesce(new.addon_id, old.addon_id)
                         and x.status not in ('cancelled', 'declined') and x.id <> coalesce(new.id, old.id));
  end if;
  return coalesce(new, old);
end $$;
revoke all on function app.line_overrides_follow_choices() from public, anon, authenticated;
grant execute on function app.line_overrides_follow_choices() to service_role;

drop trigger if exists bookings_line_overrides_follow on bookings;
create trigger bookings_line_overrides_follow after update of pickup_method, return_method, coverage_option on bookings
  for each row when (old.pickup_method is distinct from new.pickup_method or old.return_method is distinct from new.return_method
                     or old.coverage_option is distinct from new.coverage_option)
  execute function app.line_overrides_follow_choices();
drop trigger if exists booking_addons_line_overrides_follow on booking_addons;
create trigger booking_addons_line_overrides_follow after update of status or delete on booking_addons
  for each row execute function app.line_overrides_follow_choices();
