-- 2792 (release 44, part A): the fleet's availability for a date range, for everyone who books cars.
-- The owner: Sales must see at a glance which cars are free for the customer's dates. va_read / admin_read
-- fleet_availability (Admins, customer service, Sales and fleet) answers, for the dates asked, every car in the fleet:
-- Available or Not available with the reasons in plain words (booked, on rent, payment due, placeholder, maintenance,
-- blocked, out of service, leaving the fleet) and the next date it is free for the same length of rental (within 120
-- days); offers and requests out on a free car are shown as a note (they do not hold the car). The rule is the one the
-- booking itself checks (app.vehicle_is_available, with the turnaround), so the view never says free when a booking
-- would be refused. No renter is named: the reasons carry the booking number at most, so Sales sees nothing masked
-- elsewhere. SCHEMA_MARKER 2792.
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

create or replace function app.fleet_availability(p_user uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_from timestamptz;
  v_to timestamptz;
  v_len interval;
  v_class text := nullif(btrim(coalesce(p ->> 'class', '')), '');
  v_seats integer := nullif(p ->> 'seats_min', '')::integer;
  v_max bigint := nullif(p ->> 'max_daily_rate_cents', '')::bigint;
begin
  if not (app.user_is_admin(p_user) or app.user_va_has(p_user, 'cs', 'sales', 'fleet')) then
    raise exception 'The fleet''s availability is for Admins, customer service, Sales and fleet' using errcode = '42501';
  end if;
  begin
    v_from := (p ->> 'from')::timestamptz; v_to := (p ->> 'to')::timestamptz;
  exception when others then raise exception 'Choose the pickup and the return' using errcode = '22023'; end;
  if v_from is null or v_to is null or v_to <= v_from then raise exception 'The return must be after the pickup' using errcode = '22023'; end if;
  if v_to - v_from > interval '400 days' then raise exception 'Choose at most 400 days' using errcode = '22023'; end if;
  v_len := v_to - v_from;
  return jsonb_build_object('from', v_from, 'to', v_to, 'cars', coalesce((
    select jsonb_agg(c order by (c ->> 'available')::boolean desc, (c ->> 'daily_rate_cents')::bigint nulls last, c ->> 'label')
      from (
        select jsonb_build_object(
                 'id', v.id, 'label', concat_ws(' ', v.year, v.make, v.model), 'fleet_number', v.fleet_number, 'plate', v.plate,
                 'class', v.class::text, 'seats', l.seats, 'daily_rate_cents', l.daily_rate_cents, 'listed', l.vehicle_id is not null,
                 'available', ok.free,
                 'reasons', coalesce(r.items, '[]'::jsonb),
                 'next_free', case when ok.free then v_from else nf.at end) as c
          from vehicles v
          left join public_vehicle_listings l on l.vehicle_id = v.id
          cross join lateral (select v.status not in ('out_of_service', 'exit_notice')
                                     and (v.exit_date is null or app.local_date(v_to) <= v.exit_date)
                                     and app.vehicle_is_available(v.id, v_from, v_to)
                                     and not exists (select 1 from bookings b where b.vehicle_id = v.id and app.booking_is_placeholder(b.id)
                                                       and b.status::text not in ('cancelled', 'declined', 'expired', 'closed', 'returned', 'no_show')
                                                       and b.pickup_at < v_to and b.return_at > v_from) as free) ok
          cross join lateral (
            select jsonb_agg(x order by x ->> 'from') as items from (
              select jsonb_build_object('kind', case when app.booking_is_placeholder(b.id) then 'placeholder' when b.status::text = 'on_rent' then 'on_rent'
                                                     when b.status::text in ('confirmed', 'pending_payment') then 'booked' when b.status::text = 'tentative' then 'hold' else 'offer' end,
                       'label', case when app.booking_is_placeholder(b.id) then 'Placeholder (held)'
                                     when b.status::text = 'on_rent' then 'On rent'
                                     when b.status::text = 'confirmed' then 'Booked'
                                     when b.status::text = 'pending_payment' then 'Booked, payment due'
                                     when b.status::text = 'offered' then 'Offer out (does not hold the car)'
                                     when b.status::text = 'tentative' then 'Short hold while the renter decides'
                                     else 'Request (does not hold the car)' end,
                       'booking', b.booking_number, 'from', b.pickup_at, 'to', b.return_at) as x
                from bookings b
               where b.vehicle_id = v.id and b.pickup_at < v_to and b.return_at > v_from
                 and b.status::text in ('requested', 'offered', 'tentative', 'pending_payment', 'confirmed', 'on_rent')
              union all
              select jsonb_build_object('kind', case when k.reason in ('service', 'repair', 'cleaning') then 'maintenance' else 'blocked' end,
                       'label', case k.reason when 'service' then 'Maintenance: service' when 'repair' then 'Maintenance: repair' when 'cleaning' then 'Cleaning'
                                              when 'owner_unavailable' then 'Blocked: owner unavailable' when 'exit' then 'Leaving the fleet'
                                              when 'turo_owner_use' then 'Blocked: another platform or the owner' else 'Blocked' end,
                       'booking', null, 'from', k.starts_at, 'to', k.ends_at) as x
                from vehicle_calendar_blocks k
               where k.vehicle_id = v.id and k.removed_at is null and k.starts_at < v_to and (k.ends_at is null or k.ends_at > v_from)
                 and (k.booking_id is null or not exists (select 1 from bookings b2 where b2.id = k.booking_id))
              union all
              select jsonb_build_object('kind', 'out_of_service', 'label', case v.status when 'exit_notice' then 'Leaving the fleet' else 'Out of service' end,
                       'booking', null, 'from', null, 'to', null)
               where v.status in ('out_of_service', 'exit_notice')
              union all
              select jsonb_build_object('kind', 'exit', 'label', 'Leaves the fleet ' || to_char(v.exit_date, 'Mon DD'), 'booking', null, 'from', v.exit_date, 'to', null)
               where v.exit_date is not null and app.local_date(v_to) > v.exit_date) y) r
          cross join lateral (
            -- the next start, from the pickup asked, at which the same length is free: the pickup itself, or the end of
            -- something that holds the car (rounded up to the hour), whichever comes first
            select min(t) as at from (
              select date_trunc('hour', e + interval '59 minutes') as t from (
                select b.return_at + make_interval(mins => app.turnaround_minutes(v.id)) as e from bookings b
                 where b.vehicle_id = v.id and b.return_at > v_from and b.pickup_at < v_from + interval '120 days'
                   and b.status::text in ('pending_payment', 'confirmed', 'on_rent')
                union all
                select k.ends_at from vehicle_calendar_blocks k
                 where k.vehicle_id = v.id and k.removed_at is null and k.ends_at is not null and k.ends_at > v_from and k.starts_at < v_from + interval '120 days') ends
            ) cand
             where not ok.free and v.status not in ('out_of_service', 'exit_notice') and t >= v_from
               and app.vehicle_is_available(v.id, t, t + v_len)
               and (v.exit_date is null or app.local_date(t + v_len) <= v.exit_date)) nf
         where v.status::text not in ('onboarding', 'exited', 'declined', 'total_loss')
           and (v_class is null or v.class::text = v_class or app.vehicle_in_classes(v.id, array[v_class]))
           and (v_seats is null or coalesce(l.seats, 0) >= v_seats)
           and (v_max is null or l.daily_rate_cents <= v_max)) q), '[]'::jsonb));
end $$;
comment on function app.fleet_availability(uuid, jsonb) is '2792: every car of the fleet for a pickup and a return: available or not, the reasons and the next free start for the same length. Admins, customer service, Sales and fleet.';

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2792;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('admin_read', 'va_read') and p_name = 'fleet_availability' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.fleet_availability(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre2792(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2792(uuid, text, text, text, jsonb)'::regprocedure);

revoke all on function app.fleet_availability(uuid, jsonb), app.door_pre2792(uuid, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function app.fleet_availability(uuid, jsonb), app.door_pre2792(uuid, text, text, text, jsonb) to service_role;
