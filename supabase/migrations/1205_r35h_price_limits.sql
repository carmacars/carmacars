-- 1205_r35h_price_limits.sql
-- Release 35, part H: owner price limits for dynamic pricing. The owner: "each owner (and per car) can set a minimum and
-- maximum daily rate ... dynamic pricing, promo codes and staff offers never go below the minimum or above the maximum
-- without an admin override".
--
--   1. owners.price_min_daily_cents / price_max_daily_cents: the owner's limits for every car; vehicles.price_min_daily_cents
--      / price_max_daily_cents: one car's own, used before the owner's (field by field). Empty is no limit. A minimum is
--      never above the maximum in force on any car (checked when either is saved).
--   2. Who sets them: the owner in the owner portal (every car, or one of their cars) and an Admin (any owner or car). Each
--      change is in the audit log with who, before and after. Fleet and customer service read them on the car (read only).
--   3. The money: the rental net of lead-time pricing (short notice or booked ahead), the non-refundable discount, a staff
--      discount, a promo code and a price typed by staff, divided by the billable days, stays between the limits. When it
--      falls outside, one line of its own (price_limit, "Minimum daily rate for this car" / "Maximum daily rate for this
--      car") brings it back to the limit; it counts with the rental charge (owner revenue, commissions, the split, refunds)
--      and is taxed like it. Never on an Owner Booking or a booking billed to an insurer (the insurer pays its own rate).
--   4. The Admin override: bookings.price_limit_override, set by an Admin only, on a request (an offer out is edited in
--      place), with a reason; logged on the booking and in the audit log. With it the booking is priced without the limits.
--      Off again: the limits apply at once.
--   5. Quotes and the cars list (search_available) show the price with the line.
-- No applied migration is edited: functions that change are wrapped (_pre1205) or patched in place with pg_temp.patch_fn,
-- which refuses when the text it changes is not found.
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '1205: the text to change was not found in %: %', p_sig, left(p_old, 160);
  end if;
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
  execute format('revoke all on function %s from public, anon, authenticated', p_old);
  execute format('grant execute on function %s to service_role', p_old);
end $$;

-- ================================================================ 1. the limits
alter table owners
  add column if not exists price_min_daily_cents bigint check (price_min_daily_cents > 0),
  add column if not exists price_max_daily_cents bigint check (price_max_daily_cents > 0);
alter table owners drop constraint if exists owners_price_limits_order;
alter table owners add constraint owners_price_limits_order check (price_min_daily_cents is null or price_max_daily_cents is null or price_min_daily_cents <= price_max_daily_cents);
comment on column owners.price_min_daily_cents is 'Price limits (1205): the lowest daily rate (cents) any car of this owner is rented at after lead-time pricing, discounts and promo codes. Empty: no minimum. A car''s own comes first.';
comment on column owners.price_max_daily_cents is 'Price limits (1205): the highest daily rate (cents) any car of this owner is rented at. Empty: no maximum. A car''s own comes first.';

alter table vehicles
  add column if not exists price_min_daily_cents bigint check (price_min_daily_cents > 0),
  add column if not exists price_max_daily_cents bigint check (price_max_daily_cents > 0);
alter table vehicles drop constraint if exists vehicles_price_limits_order;
alter table vehicles add constraint vehicles_price_limits_order check (price_min_daily_cents is null or price_max_daily_cents is null or price_min_daily_cents <= price_max_daily_cents);
comment on column vehicles.price_min_daily_cents is 'Price limits (1205): this car''s lowest daily rate (cents), before its owner''s. Empty: the owner''s, or none.';
comment on column vehicles.price_max_daily_cents is 'Price limits (1205): this car''s highest daily rate (cents), before its owner''s. Empty: the owner''s, or none.';

alter table bookings
  add column if not exists price_limit_override boolean not null default false,
  add column if not exists price_limit_override_by uuid references users(id),
  add column if not exists price_limit_override_at timestamptz,
  add column if not exists price_limit_override_reason text;
comment on column bookings.price_limit_override is 'Price limits (1205): an Admin allowed this booking a price outside its car''s daily minimum and maximum (reason, who and when beside it).';

-- the line: owner revenue and tax like the rental charge
insert into fee_types (code, label, family, unit, per_what, revenue_class, hst_applies, stage, refundable_by_tier, change_default, change_vehicle,
                       change_booking, in_master_spec, sort_order, gl_account)
select 'price_limit', 'Price limits: the rental brought back to the car''s daily minimum or maximum', 'rental', 'flat', 'rental',
       f.revenue_class, f.hst_applies, 'booking', f.refundable_by_tier, false, false, false, false, 16, f.gl_account
  from fee_types f where f.code = 'rental_charge'
on conflict (code) do nothing;

-- The limits in force on a car: {min_daily_cents, max_daily_cents, min_from, max_from} (from: car, owner or empty).
create or replace function app.price_limits_for(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
           'min_daily_cents', coalesce(v.price_min_daily_cents, o.price_min_daily_cents),
           'max_daily_cents', coalesce(v.price_max_daily_cents, o.price_max_daily_cents),
           'min_from', case when v.price_min_daily_cents is not null then 'car' when o.price_min_daily_cents is not null then 'owner' end,
           'max_from', case when v.price_max_daily_cents is not null then 'car' when o.price_max_daily_cents is not null then 'owner' end)
    from vehicles v left join owners o on o.id = v.owner_id
   where v.id = p_vehicle
$$;

-- The line's words.
create or replace function app.price_limit_text(p_cents bigint) returns text
language sql immutable as $$
  select case when coalesce(p_cents, 0) > 0 then 'Minimum daily rate for this car' when coalesce(p_cents, 0) < 0 then 'Maximum daily rate for this car' else 'Within the car''s price limits' end
$$;

-- ================================================================ 2. the money
-- price_lines: after every rental line (rental charge, lead-time pricing, the discounts, a promo code), the rental a day is
-- held between the car's limits by one price_limit line. p.price_limit_override (a booking an Admin allowed) skips it.
alter function app.price_lines(jsonb) rename to price_lines_pre1205;
create function app.price_lines(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.price_lines_pre1205(p);
  v_none jsonb := jsonb_build_object('price_limit_cents', 0, 'price_limit_label', null);
  l jsonb;
  v_days integer := greatest(coalesce((v ->> 'billable_days')::integer, 1), 1);
  v_net bigint;
  v_lo bigint;
  v_hi bigint;
  v_amt bigint := 0;
  v_hst integer := coalesce((p ->> 'hst_bps')::integer, 0);
  v_lines jsonb;
  v_sub bigint;
  v_tax bigint;
begin
  if coalesce(p ->> 'booking_type', 'standard') = 'owner' or nullif(p ->> 'vehicle_id', '') is null
     or coalesce((p ->> 'price_limit_override')::boolean, false) or coalesce((p ->> 'insurer_billed')::boolean, false) then
    return v || v_none;
  end if;
  l := app.price_limits_for((p ->> 'vehicle_id')::uuid);
  v_lo := (l ->> 'min_daily_cents')::bigint;
  v_hi := (l ->> 'max_daily_cents')::bigint;
  if l is null or (v_lo is null and v_hi is null) then return v || v_none; end if;
  select coalesce(sum((x.value ->> 'amount_cents')::bigint), 0) into v_net
    from jsonb_array_elements(coalesce(v -> 'lines', '[]'::jsonb)) x(value)
   where x.value ->> 'charge_type' in ('rental_charge', 'lead_time', 'non_refundable_discount', 'staff_discount', 'promo_discount', 'discount');
  if v_net <= 0 and not exists (select 1 from jsonb_array_elements(coalesce(v -> 'lines', '[]'::jsonb)) x(value) where x.value ->> 'charge_type' = 'rental_charge') then
    return v || v_none;   -- nothing rented (a fee-only spec)
  end if;
  if v_lo is not null and v_net < v_lo * v_days then v_amt := v_lo * v_days - v_net;
  elsif v_hi is not null and v_net > v_hi * v_days then v_amt := v_hi * v_days - v_net;
  end if;
  if v_amt = 0 then return v || v_none || jsonb_build_object('price_limits', l); end if;
  select coalesce(jsonb_agg(x.value order by (x.value ->> 'sort_order')::integer, x.ord), '[]'::jsonb),
         coalesce(sum((x.value ->> 'amount_cents')::bigint), 0), coalesce(sum((x.value ->> 'hst_cents')::bigint), 0)
    into v_lines, v_sub, v_tax
    from jsonb_array_elements(coalesce(v -> 'lines', '[]'::jsonb)
           || jsonb_build_array(app.price_line('price_limit', 1, v_amt, v_amt, v_hst, app.price_limit_text(v_amt), null,
                                               jsonb_build_object('kind', case when v_amt > 0 then 'minimum' else 'maximum' end, 'days', v_days,
                                                                  'limit_cents', case when v_amt > 0 then v_lo else v_hi end,
                                                                  'from', case when v_amt > 0 then l ->> 'min_from' else l ->> 'max_from' end,
                                                                  'rental_before_cents', v_net))))
         with ordinality x(value, ord);
  return v || jsonb_build_object('lines', v_lines, 'subtotal_cents', v_sub, 'hst_cents', v_tax, 'total_cents', v_sub + v_tax,
                                 'price_limit_cents', v_amt, 'price_limit_label', app.price_limit_text(v_amt), 'price_limits', l);
end $$;
select pg_temp.copy_grants('app.price_lines(jsonb)'::regprocedure, 'app.price_lines_pre1205(jsonb)'::regprocedure);

-- a booking's price carries its override
alter function app.booking_price_spec(uuid, jsonb) rename to booking_price_spec_pre1205;
create function app.booking_price_spec(p_booking uuid, p_changes jsonb default '{}'::jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.booking_price_spec_pre1205(p_booking, p_changes) || jsonb_build_object('price_limit_override', coalesce(b.price_limit_override, false))
    from bookings b where b.id = p_booking
$$;
select pg_temp.copy_grants('app.booking_price_spec(uuid, jsonb)'::regprocedure, 'app.booking_price_spec_pre1205(uuid, jsonb)'::regprocedure);

-- the cars list for chosen dates: the rental with its adjustments
select pg_temp.patch_fn('app.search_available(timestamptz, timestamptz, jsonb)'::regprocedure,
  $o$(q.quote ->> 'rental_charge_cents')::bigint + coalesce((q.quote ->> 'lead_time_cents')::bigint, 0),$o$,
  $n$(q.quote ->> 'rental_charge_cents')::bigint + coalesce((q.quote ->> 'lead_time_cents')::bigint, 0) + coalesce((q.quote ->> 'price_limit_cents')::bigint, 0),$n$);

-- every list of the lines that make the rental counts the line with the rental charge (as 0360 did for lead_time)
do $$
declare
  f text;
begin
  foreach f in array array['app.sync_booking_price(uuid)', 'app.preview_booking_change(uuid, jsonb)', 'app.commission_line_types()',
                           'app.booking_split_parts(uuid)', 'app.booking_line_allocation(uuid)', 'app.booking_part_open_raw(uuid, text)',
                           'app.booking_tie_lines_raw(uuid, text, uuid)', 'app.apply_line_overrides(jsonb, jsonb, integer)',
                           'app.public_site_facts()', 'app.snapshot_booking_fee_terms(uuid)', 'app.compute_booking_split_pre0156(uuid)',
                           'app.preview_extension_pre1201(uuid, timestamptz, timestamptz)'] loop
    perform pg_temp.patch_fn(f::regprocedure, $o$'lead_time'$o$, $n$'lead_time', 'price_limit'$n$);
  end loop;
end $$;
-- its words follow its amount when the price is synced again
select pg_temp.patch_fn('app.put_price_line(uuid, jsonb)'::regprocedure,
  $o$(v_line.charge_type = 'lead_time' and$o$, $n$(v_line.charge_type in ('lead_time', 'price_limit') and$n$);
select pg_temp.patch_fn('app.put_price_line(uuid, jsonb)'::regprocedure,
  $o$when charge_type = 'lead_time' or$o$, $n$when charge_type in ('lead_time', 'price_limit') or$n$);

-- ================================================================ 3. setting the limits
-- p: {scope: owner | car, owner_id (Admin, scope owner), vehicle_id (scope car), min_daily_cents, max_daily_cents} (cents;
-- null or missing: no limit). The owner: their own record and their own cars; an Admin: anyone's. A minimum above the
-- maximum in force on any affected car is refused.
create or replace function app.price_limits_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_admin boolean := app.user_is_admin(p_by);
  v_scope text := coalesce(nullif(p ->> 'scope', ''), case when nullif(p ->> 'vehicle_id', '') is not null then 'car' else 'owner' end);
  v_owner uuid;
  v_vehicle uuid;
  v_min bigint := nullif(p ->> 'min_daily_cents', '')::bigint;
  v_max bigint := nullif(p ->> 'max_daily_cents', '')::bigint;
  v_before jsonb;
  v_bad text;
begin
  if v_scope not in ('owner', 'car') then raise exception 'Choose every car or one car' using errcode = '22023'; end if;
  if (v_min is not null and v_min <= 0) or (v_max is not null and v_max <= 0) then
    raise exception 'A limit is an amount above $0, or empty for no limit' using errcode = '22023';
  end if;
  if v_min is not null and v_max is not null and v_min > v_max then
    raise exception 'The minimum (%) is above the maximum (%)', app.money_text(v_min), app.money_text(v_max) using errcode = '22023';
  end if;
  if v_scope = 'car' then
    v_vehicle := nullif(p ->> 'vehicle_id', '')::uuid;
    select owner_id into v_owner from vehicles where id = v_vehicle;
    if v_vehicle is null or not exists (select 1 from vehicles where id = v_vehicle) then raise exception 'Vehicle not found' using errcode = 'P0002'; end if;
    if not v_admin and (v_owner is null or v_owner <> app.portal_owner_id(p_by)) then
      raise exception 'Only the car''s owner or an Admin sets its price limits' using errcode = '42501';
    end if;
    select jsonb_build_object('min_daily_cents', price_min_daily_cents, 'max_daily_cents', price_max_daily_cents) into v_before from vehicles where id = v_vehicle;
    -- the car's own against its owner's for the field it leaves empty
    select format('%s to %s', app.money_text(coalesce(v_min, o.price_min_daily_cents)), app.money_text(coalesce(v_max, o.price_max_daily_cents)))
      into v_bad from owners o where o.id = v_owner and coalesce(v_min, o.price_min_daily_cents) > coalesce(v_max, o.price_max_daily_cents);
    if v_bad is not null then
      raise exception 'The minimum would be above the maximum on this car (%, with the owner''s limits for every car)', v_bad using errcode = '22023';
    end if;
    update vehicles set price_min_daily_cents = v_min, price_max_daily_cents = v_max where id = v_vehicle;
  else
    v_owner := case when v_admin and nullif(p ->> 'owner_id', '') is not null then (p ->> 'owner_id')::uuid
                    when v_admin and nullif(p ->> 'vehicle_id', '') is not null then (select owner_id from vehicles where id = (p ->> 'vehicle_id')::uuid)
                    when v_admin then null
                    else app.portal_owner_id(p_by) end;
    if v_owner is null or not exists (select 1 from owners where id = v_owner) then raise exception 'Owner not found' using errcode = 'P0002'; end if;
    if not v_admin and nullif(p ->> 'owner_id', '') is not null and (p ->> 'owner_id')::uuid <> v_owner then
      raise exception 'Only the owner or an Admin sets these price limits' using errcode = '42501';
    end if;
    select jsonb_build_object('min_daily_cents', price_min_daily_cents, 'max_daily_cents', price_max_daily_cents) into v_before from owners where id = v_owner;
    select string_agg(app.vehicle_name(v.id), ', ' order by v.created_at) into v_bad
      from vehicles v where v.owner_id = v_owner and coalesce(v.price_min_daily_cents, v_min) > coalesce(v.price_max_daily_cents, v_max);
    if v_bad is not null then
      raise exception 'The minimum would be above the maximum on %: change that car''s own limits first', v_bad using errcode = '22023';
    end if;
    update owners set price_min_daily_cents = v_min, price_max_daily_cents = v_max where id = v_owner;
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'price_limits', case when v_scope = 'car' then 'vehicles' else 'owners' end, coalesce(v_vehicle, v_owner)::text, v_before,
          jsonb_build_object('min_daily_cents', v_min, 'max_daily_cents', v_max, 'by', case when v_admin then 'admin' else 'owner' end));
  return jsonb_build_object('scope', v_scope, 'owner_id', v_owner, 'vehicle_id', v_vehicle, 'min_daily_cents', v_min, 'max_daily_cents', v_max);
end $$;

-- One car's limits for the car page: its own, its owner's and the ones in force. Admin and staff (Fleet reads them).
create or replace function app.price_limits_read(p_by uuid, p_vehicle uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
  o owners;
begin
  if not app.user_is_staff(p_by) then raise exception 'Staff read a car''s price limits' using errcode = '42501'; end if;
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then raise exception 'Vehicle not found' using errcode = 'P0002'; end if;
  select * into o from owners where id = v.owner_id;
  return jsonb_build_object('vehicle_id', v.id, 'owner_id', o.id,
    'owner', jsonb_build_object('min_daily_cents', o.price_min_daily_cents, 'max_daily_cents', o.price_max_daily_cents),
    'car', jsonb_build_object('min_daily_cents', v.price_min_daily_cents, 'max_daily_cents', v.price_max_daily_cents),
    'effective', app.price_limits_for(v.id));
end $$;

-- The owner portal: their limits for every car and each car's own and in force.
create or replace function app.owner_price_limits(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'owner', jsonb_build_object('min_daily_cents', o.price_min_daily_cents, 'max_daily_cents', o.price_max_daily_cents),
    'cars', coalesce((select jsonb_agg(jsonb_build_object('vehicle_id', v.id, 'name', app.vehicle_name(v.id),
                        'car', jsonb_build_object('min_daily_cents', v.price_min_daily_cents, 'max_daily_cents', v.price_max_daily_cents),
                        'effective', app.price_limits_for(v.id)) order by v.created_at, v.id)
                        from vehicles v where v.owner_id = o.id and v.status not in ('declined')), '[]'::jsonb))
    from owners o where o.id = app.portal_owner_id(p_by)
$$;
create or replace function public.server_owner_price_limits(p_by uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.owner_price_limits(p_by) $$;
create or replace function public.server_owner_price_limits_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security invoker set search_path = public, app as $$
begin
  perform app.portal_owner_id(p_by);   -- an owner account, active
  return app.price_limits_save(p_by, (p - 'owner_id'));
end $$;

-- ================================================================ 4. the Admin override on a booking
create or replace function app.booking_price_limit_override(p_by uuid, p_booking uuid, p_on boolean, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin allows a price outside the car''s price limits' using errcode = '42501'; end if;
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.status::text in ('offered', 'pending_payment') then
    raise exception 'Booking % has an offer out: edit the offer to change its price', b.booking_number using errcode = '23514';
  end if;
  if b.status::text not in ('requested', 'tentative') then
    raise exception 'Booking % is %: its price is settled', b.booking_number, b.status using errcode = '23514';
  end if;
  if coalesce(p_on, false) and v_reason is null then raise exception 'Say why this booking may be priced outside the car''s limits' using errcode = '22023'; end if;
  if coalesce(p_on, false) = b.price_limit_override then
    return jsonb_build_object('booking_id', b.id, 'price_limit_override', b.price_limit_override, 'total_due_at_booking_cents', b.total_due_at_booking_cents);
  end if;
  update bookings set price_limit_override = coalesce(p_on, false), price_limit_override_by = p_by, price_limit_override_at = now(),
         price_limit_override_reason = case when coalesce(p_on, false) then left(v_reason, 500) end
   where id = b.id;
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
    case when coalesce(p_on, false) then format('Price limits: an Admin allowed a price outside the car''s limits (%s)', left(v_reason, 500))
         else 'Price limits: the car''s limits apply again' end, p_by, 'staff');
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'booking_price_limit_override', 'bookings', b.id::text, jsonb_build_object('price_limit_override', b.price_limit_override),
          jsonb_build_object('price_limit_override', coalesce(p_on, false), 'reason', v_reason));
  perform app.sync_booking_price(b.id);
  select * into b from bookings where id = b.id;
  return jsonb_build_object('booking_id', b.id, 'price_limit_override', b.price_limit_override, 'total_due_at_booking_cents', b.total_due_at_booking_cents);
end $$;

-- The review screen and an offer edited in place: "price_limit_override": {"on": true, "reason": "..."}.
alter function app.admin_apply_booking_edit(uuid, uuid, jsonb) rename to admin_apply_booking_edit_pre1205;
create function app.admin_apply_booking_edit(p_admin uuid, p_booking uuid, p jsonb) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if jsonb_typeof(p -> 'price_limit_override') = 'object' and coalesce((p -> 'price_limit_override' ->> 'on')::boolean, false) then
    -- allowed first, so the rest of the edit is priced without the limits
    perform app.booking_price_limit_override(p_admin, p_booking, true, p -> 'price_limit_override' ->> 'reason');
  end if;
  perform app.admin_apply_booking_edit_pre1205(p_admin, p_booking, p - 'price_limit_override');
  if jsonb_typeof(p -> 'price_limit_override') = 'object' and not coalesce((p -> 'price_limit_override' ->> 'on')::boolean, false) then
    perform app.booking_price_limit_override(p_admin, p_booking, false, null);
  end if;
end $$;
select pg_temp.copy_grants('app.admin_apply_booking_edit(uuid, uuid, jsonb)'::regprocedure, 'app.admin_apply_booking_edit_pre1205(uuid, uuid, jsonb)'::regprocedure);

-- ================================================================ 5. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1205;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'admin_do' and p_name = 'price_limits' then
    perform app.door_begin(p_user, p_aal);
    perform app.assert_admin(p_user);
    return app.price_limits_save(p_user, p);
  end if;
  if p_call = 'admin_do' and p_name = 'booking_price_limit' then
    perform app.door_begin(p_user, p_aal);
    return app.booking_price_limit_override(p_user, coalesce(nullif(p ->> 'booking_id', ''), p ->> 'booking')::uuid,
                                            coalesce((p ->> 'on')::boolean, false), p ->> 'reason');
  end if;
  if p_call = 'ops_read' and p_name = 'price_limits' then
    perform app.door_begin(p_user, p_aal);
    return app.price_limits_read(p_user, coalesce(nullif(p ->> 'vehicle_id', ''), p ->> 'vehicle')::uuid);
  end if;
  return app.door_pre1205(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre1205(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ privileges
revoke all on function app.price_limits_for(uuid), app.price_limits_save(uuid, jsonb), app.price_limits_read(uuid, uuid), app.owner_price_limits(uuid),
  app.booking_price_limit_override(uuid, uuid, boolean, text), public.server_owner_price_limits(uuid), public.server_owner_price_limits_save(uuid, jsonb)
  from public, anon, authenticated;
grant execute on function app.price_limits_for(uuid), app.price_limits_save(uuid, jsonb), app.price_limits_read(uuid, uuid), app.owner_price_limits(uuid),
  app.booking_price_limit_override(uuid, uuid, boolean, text), public.server_owner_price_limits(uuid), public.server_owner_price_limits_save(uuid, jsonb)
  to service_role;
grant execute on function app.price_limit_text(bigint) to anon, authenticated, service_role;
