-- 5142 (R50 hotfix 2, docs/changes/2026-11-27-r50-hotfix2-ops.md): the winter tire fee, per rental.
-- The owner (Nov 27): the winter tire fee must be editable on each rental, insurer-billed rentals too.
-- Before: winter tires were an add-on with the add-on's price a day and cap (Program settings > Add-ons) copied onto the
-- booking when it was added; a rental's own price was only reachable by overriding the whole line, and an insurer rental
-- entered without the add-on had no way to carry it.
-- Now: app.booking_winter_tire_set (the door's ops_do winter_tire_set; 5144 wires it) sets a rental's winter tires: the rate a
-- day (rate_cents sent as 0 or null removes them; the cap alone changes only the cap) and, optionally, the cap for the rental. It adds the add-on when the rental has none, keeps its
-- rate and cap on the booking's add-on (booking_addons, which prices the line: rate x days up to the cap), reprices the
-- booking and the insurer's share, and writes the change with who and why to the booking's fee changes and history: a money
-- record is never changed silently. (booking_fee_terms is not used: a term set on one booking is an Admin's price override.) On an insurer-billed rental the line is
-- one of the charges the insurer's invoice lists (app.insurer_fee_items); the invoice itself is edited on the insurance page.
-- The renter of a rental they pay is told (renter_winter_tire_changed, 5145).
-- Who: an Admin, Finance, or staff while Program settings let them change fees (as every fee change). When: until the
-- booking is closed (not cancelled, declined, expired or a no-show). No applied migration is edited. SCHEMA_MARKER 5142.
set local check_function_bodies = off;

create function app.booking_winter_tire_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  b bookings;
  a addons;
  ba booking_addons;
  v_rate bigint := case when jsonb_typeof(p -> 'rate_cents') = 'number' then (p ->> 'rate_cents')::numeric::bigint end;
  v_cap bigint := case when jsonb_typeof(p -> 'cap_cents') = 'number' then (p ->> 'cap_cents')::numeric::bigint end;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_before bigint;
  v_after bigint;
  v_total0 bigint;
  v_rate0 bigint;
  v_change uuid;
begin
  if not (app.may_edit_fees(p_by) or app.user_runs_finance(p_by)) then
    raise exception 'Only an Admin, Finance, or staff while Program settings let them change fees, changes the winter tire fee' using errcode = '42501';
  end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.booking_type::text = 'owner' then raise exception 'An Owner Booking has no winter tire fee' using errcode = '23514'; end if;
  if b.status::text in ('cancelled', 'declined', 'expired', 'no_show', 'closed') then
    raise exception 'Booking % is %: its fees no longer change here', b.booking_number, replace(b.status::text, '_', ' ') using errcode = '23514';
  end if;
  if (p ? 'rate_cents') and jsonb_typeof(p -> 'rate_cents') not in ('number', 'null') or v_rate < 0 or v_rate > 100000 then
    raise exception 'Type the winter tire rate a day in dollars and cents, up to $1,000 (0 removes them)' using errcode = '22023';
  end if;
  if v_cap is not null and (v_cap < 0 or v_cap > 1000000) then raise exception 'The cap is a number of cents, up to $10,000' using errcode = '22023'; end if;
  if v_reason is null then raise exception 'Say why the winter tire fee changes (it is kept with the booking)' using errcode = '22023'; end if;
  select * into a from addons where code = 'winter_tire';
  if a.id is null then raise exception 'The winter tire add-on is not set up (Program settings > Add-ons)' using errcode = 'P0002'; end if;
  select * into ba from booking_addons where booking_id = b.id and addon_id = a.id and status in ('pending', 'confirmed') for update;
  v_before := app.booking_line_key_cents(b.id, 'addon:winter_tire');
  v_rate0 := ba.unit_price_cents;
  v_total0 := b.total_due_at_booking_cents;

  if not (p ? 'rate_cents') and not (p ? 'cap_cents') then raise exception 'Send the rate a day, the cap, or both' using errcode = '22023'; end if;
  if not (p ? 'rate_cents') then
    -- the cap alone (review fix): the rate stays as it is; the tires are removed only when rate_cents is sent as 0 or null
    if ba.id is null then raise exception 'Booking % has no winter tires: set the rate a day first', b.booking_number using errcode = '23514'; end if;
    v_rate := ba.unit_price_cents;
    update booking_addons set cap_cents = v_cap where id = ba.id;
  elsif coalesce(v_rate, 0) = 0 then
    if ba.id is null then return jsonb_build_object('ok', true, 'booking_number', b.booking_number, 'changed', false, 'rate_cents', null); end if;
    update booking_addons set status = 'cancelled', cancelled_at = now(), cancelled_by = p_by, cancel_reason = left('Winter tires removed: ' || v_reason, 300)
     where id = ba.id;
  else
    if ba.id is null then
      insert into booking_addons (booking_id, addon_id, quantity, name, fee_type_code, pricing_unit, unit_price_cents, max_days, cap_cents, min_hours,
                                  hst_applies, status, added_via, added_by, confirmed_by, confirmed_at)
      values (b.id, a.id, 1, a.name, a.fee_type_code, a.pricing_unit, v_rate, a.max_days, coalesce(v_cap, a.cap_cents), a.min_hours,
              a.hst_applies, 'confirmed', 'staff', p_by, p_by, now());
    else
      update booking_addons set unit_price_cents = v_rate, cap_cents = case when p ? 'cap_cents' then v_cap else cap_cents end,
             status = 'confirmed', confirmed_by = coalesce(confirmed_by, p_by), confirmed_at = coalesce(confirmed_at, now())
       where id = ba.id;
    end if;
  end if;
  perform app.addons_sync_extras(b.id);
  perform app.sync_booking_price(b.id);
  v_after := app.booking_line_key_cents(b.id, 'addon:winter_tire');
  select * into b from bookings where id = b.id;
  insert into booking_fee_changes (booking_id, line_key, label, before_cents, after_cents, reason, booking_status, changed_by)
  values (b.id, 'addon:winter_tire', 'Winter tires', v_before, v_after, v_reason, b.status::text, p_by)
  returning id into v_change;
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, b.current_offer_version,
    format('Winter tires: %s a day to %s a day (%s for the rental to %s). %s', coalesce(app.fmt_money(v_rate0), 'none'), coalesce(app.fmt_money(nullif(v_rate, 0)), 'none'),
           coalesce(app.fmt_money(v_before), 'none'), coalesce(app.fmt_money(v_after), 'none'), v_reason),
    p_by, 'staff', jsonb_build_object('fee_changes', jsonb_build_array(jsonb_build_object('key', 'addon:winter_tire', 'label', 'Winter tires', 'before_cents', v_before, 'after_cents', v_after)),
                                      'total_before_cents', v_total0, 'total_after_cents', b.total_due_at_booking_cents));
  if not app.booking_bills_insurer(b) and v_before is distinct from v_after and b.status::text not in ('requested', 'tentative') then
    perform app.ntf_emit('renter_winter_tire_changed', 'booking', b.id, 'winter:' || v_change,
      jsonb_build_object('booking_id', b.id, 'renter_id', b.renter_id, 'booking_number', b.booking_number,
                         'winter_rate', coalesce(app.fmt_money(nullif(v_rate, 0)), 'none'), 'winter_before', coalesce(app.fmt_money(v_before), 'none'),
                         'winter_after', coalesce(app.fmt_money(v_after), 'none'), 'total_text', app.fmt_money(b.total_due_at_booking_cents)));
  end if;
  return jsonb_build_object('ok', true, 'booking_number', b.booking_number, 'changed', v_before is distinct from v_after, 'rate_cents', nullif(v_rate, 0),
                            'before_cents', v_before, 'after_cents', v_after, 'total_before_cents', v_total0, 'total_cents', b.total_due_at_booking_cents,
                            'insurer_share_cents', b.insurer_share_cents);
end $$;
comment on function app.booking_winter_tire_set(uuid, jsonb) is 'R50 hotfix 2 (5142): a rental''s winter tire rate a day (and cap), insurer rentals too; recorded with who and why, the booking repriced.';
revoke all on function app.booking_winter_tire_set(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.booking_winter_tire_set(uuid, jsonb) to service_role;
