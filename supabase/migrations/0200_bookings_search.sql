-- 0200: bookings search (Release 21, item 1). SCHEMA_MARKER 0200. docs/changes/2026-10-31-bookings-search.md.
--   One search for Admin and staff: a booking number (CC-1042, cc1042 or 1042), the renter's or a driver's name, an email,
--   a phone number (any format), a plate (any spacing) or a car code. app.bookings_search answers through the staff door
--   (ops_read 'bookings_search'); Admin > Bookings and the staff portal's Bookings use it.
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

-- p: q (2 characters or more for an Admin, 3 for staff; a staff search is logged), status (optional), limit (1 to 200, 50 by default).
-- Returns the bookings found, newest pickup first: id, booking_number, status, vehicle_name, car_code, plate, renter_name,
-- renter_email, pickup_at, return_at, matched (what matched: number, renter, driver, email, phone, plate, car_code).
create function app.bookings_search(p_user uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  q text := left(btrim(coalesce(p ->> 'q', '')), 80);
  l text;
  n text;
  d text;
  v_code uuid;
  v_status text := nullif(btrim(coalesce(p ->> 'status', '')), '');
  v_limit integer := least(greatest(coalesce(nullif(p ->> 'limit', '')::integer, 50), 1), 200);
  v_admin boolean := app.user_is_admin(p_user);
  v_out jsonb;
begin
  if p_user is null or not (app.user_is_admin(p_user) or app.user_is_staff(p_user)) then
    raise exception 'Only staff search bookings' using errcode = '42501';
  end if;
  if length(q) < 2 then return '[]'::jsonb; end if;
  if not v_admin and length(q) < 3 then return '[]'::jsonb; end if;
  l := '%' || replace(replace(replace(lower(q), '\', '\\'), '%', '\%'), '_', '\_') || '%';
  n := upper(regexp_replace(q, '[^A-Za-z0-9]', '', 'g'));
  d := regexp_replace(q, '\D', '', 'g');
  v_code := app.vehicle_by_code(q);
  v_out := coalesce((select jsonb_agg(x order by x ->> 'pickup_at' desc) from (
    select jsonb_build_object('id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'vehicle_name', app.vehicle_name(b.vehicle_id),
             'car_code', v.car_code, 'plate', v.plate, 'renter_name', r.legal_name, 'renter_email', case when v_admin then r.email end,
             'pickup_at', b.pickup_at, 'return_at', b.return_at,
             'matched', case
               when n <> '' and upper(regexp_replace(b.booking_number, '[^A-Za-z0-9]', '', 'g')) like '%' || n || '%' then 'number'
               when lower(coalesce(r.legal_name, '')) like l then 'renter'
               when lower(coalesce(r.email, '')) like l then 'email'
               when length(d) >= 4 and regexp_replace(coalesce(r.mobile, ''), '\D', '', 'g') like '%' || d || '%' then 'phone'
               when v.id = v_code or (length(n) >= 2 and upper(coalesce(v.car_code, '')) = n) then 'car_code'
               when length(n) >= 3 and upper(regexp_replace(coalesce(v.plate, ''), '[^A-Za-z0-9]', '', 'g')) like '%' || n || '%' then 'plate'
               else 'driver' end) x
      from bookings b
      left join renters r on r.id = b.renter_id
      left join vehicles v on v.id = b.vehicle_id
     where (v_status is null or b.status::text = v_status)
       and ((n <> '' and upper(regexp_replace(b.booking_number, '[^A-Za-z0-9]', '', 'g')) like '%' || n || '%')
         or lower(coalesce(r.legal_name, '')) like l
         or lower(coalesce(r.email, '')) like l
         or (length(d) >= 4 and regexp_replace(coalesce(r.mobile, ''), '\D', '', 'g') like '%' || d || '%')
         or (v_code is not null and v.id = v_code)
         or (length(n) >= 2 and upper(coalesce(v.car_code, '')) = n)
         or (length(n) >= 3 and upper(regexp_replace(coalesce(v.plate, ''), '[^A-Za-z0-9]', '', 'g')) like '%' || n || '%')
         or exists (select 1 from booking_drivers bd left join drivers dr on dr.id = bd.driver_id
                     where bd.booking_id = b.id and lower(coalesce(bd.full_name, dr.full_name, '')) like l))
     order by b.pickup_at desc
     limit v_limit) s), '[]'::jsonb);
  -- staff searches are logged like Find a renter (05-va.md 4.4); staff see no email address in the results
  if not v_admin then
    insert into data_access_log (user_id, action, query, results) values (p_user, 'search', 'bookings: ' || q, jsonb_array_length(v_out));
  end if;
  return v_out;
end $$;
comment on function app.bookings_search(uuid, jsonb) is 'Bookings by number, renter or driver name, email, phone, plate or car code (0200); staff and Admins.';

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0200;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'ops_read' and p_name = 'bookings_search' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.bookings_search(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre0200(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0200(uuid, text, text, text, jsonb)'::regprocedure);

revoke all on function app.bookings_search(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.bookings_search(uuid, jsonb) to service_role;
revoke all on function app.door_pre0200(uuid, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function app.door_pre0200(uuid, text, text, text, jsonb) to service_role;
