-- 3041 (release 48): every staff member sees where the cars are; each owner sees where their own cars are.
-- The owner (Nov 15): "CarmaCars all staff should be able to see the location of the cars when the trackers are in place.
-- And car owners should be able to see the location of their own vehicles."
--   1. Staff: Fleet tracking was for Admins and fleet staff (field staff: the cars of their jobs). Every staff member
--      (customer service, Sales, Fleet, Finance, field, Admin) now reads the whole fleet's positions and trips
--      (app.tracker_fleet, app.tracker_trip_path), read only: the trackers, their settings and marking alerts as seen stay
--      Admin's and Fleet's (app.tracker_alert_ack), and a non-fleet read carries no device details. One car's position for
--      the vehicle and booking pages: app.tracker_car ({vehicle} or {booking}).
--   2. Owners: app.owner_car_location ({vehicle, days}): the last position and the trips of one of the owner's own cars, the
--      location only (no booking, renter or booking dates, so a booking hidden from the owner stays hidden), each trip with
--      where it started and ended. Another owner's car is refused. The position history (tracker_points) is also readable by the
--      car's owner under row level security (owner_read), and by every staff member (staff_read).
--   3. The privacy policy names who sees the location (CarmaCars staff and the car's owner); the rental agreement says the
--      same (docs/source/v2_rental.md, new template version). The lawyer's review is on the owner's setup list
--      (app.owner_steps, key tracker_visibility) until legal.meta carries tracker_visibility_reviewed.
-- SCHEMA_MARKER 3041. docs/changes/2026-11-14-r48-car-location.md.
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

-- ================================================================ 1. staff: every role reads, Admin and Fleet manage
-- who reads the fleet's positions: Admins, every active staff member (any function), field staff
create function app.tracker_reader(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_user is not null and (app.user_is_admin(p_user) or app.user_is_staff(p_user) or app.user_is_field(p_user))
$$;
-- who manages: Admins (the trackers, settings), Admins and fleet staff (alerts), as before
create function app.tracker_fleet_staff(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_user is not null and (app.user_is_admin(p_user) or app.user_va_has(p_user, 'fleet'))
$$;

create or replace function app.tracker_assert(p_user uuid, p_manage boolean) returns void
language plpgsql stable security definer set search_path = public, app as $$
begin
  if app.user_is_admin(p_user) then return; end if;
  if not p_manage and app.tracker_reader(p_user) then return; end if;
  raise exception '%', case when p_manage then 'Only an Admin can change the trackers' else 'Car locations are for CarmaCars staff' end using errcode = '42501';
end $$;

alter function app.tracker_fleet(uuid, jsonb) rename to tracker_fleet_pre3041;
create function app.tracker_fleet(p_user uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v jsonb;
begin
  if app.tracker_fleet_staff(p_user) then return app.tracker_fleet_pre3041(p_user, p) || jsonb_build_object('read_only', false); end if;
  perform app.tracker_assert(p_user, false);
  -- every other staff member: the whole fleet, read only, without the devices' details or the trackers not on a car
  v := app.tracker_fleet_pre0500(p_user, p);
  return v || jsonb_build_object('scope', 'staff', 'read_only', true, 'unpaired', '[]'::jsonb,
    'cars', coalesce((select jsonb_agg(c || jsonb_build_object('device', case when jsonb_typeof(c -> 'device') = 'object'
                                                                         then jsonb_build_object('id', c #> '{device,id}') end))
                        from jsonb_array_elements(v -> 'cars') c), '[]'::jsonb),
    'settings', (v -> 'settings') - 'key_hint' - 'key_set_at');
end $$;
select pg_temp.copy_grants('app.tracker_fleet(uuid, jsonb)'::regprocedure, 'app.tracker_fleet_pre3041(uuid, jsonb)'::regprocedure);

alter function app.tracker_trip_path(uuid, jsonb) rename to tracker_trip_path_pre3041;
create function app.tracker_trip_path(p_user uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.tracker_assert(p_user, false);
  return app.tracker_trip_path_pre0500(p_user, p);
end $$;
select pg_temp.copy_grants('app.tracker_trip_path(uuid, jsonb)'::regprocedure, 'app.tracker_trip_path_pre3041(uuid, jsonb)'::regprocedure);

alter function app.tracker_alert_ack(uuid, jsonb) rename to tracker_alert_ack_pre3041;
create function app.tracker_alert_ack(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if not app.tracker_fleet_staff(p_user) then
    raise exception 'Only Admins and fleet staff mark tracker alerts as seen' using errcode = '42501';
  end if;
  return app.tracker_alert_ack_pre3041(p_user, p);
end $$;
select pg_temp.copy_grants('app.tracker_alert_ack(uuid, jsonb)'::regprocedure, 'app.tracker_alert_ack_pre3041(uuid, jsonb)'::regprocedure);

-- one car's position (the vehicle and booking pages): {vehicle} or {booking} (a booking number); tracker false when the
-- car has no tracker installed
create function app.car_position(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('vehicle_id', v.id, 'name', app.vehicle_name(v.id), 'tracker', d.id is not null,
    'pos', case when ts.reported_at is not null and ts.latitude is not null then jsonb_build_object('lat', ts.latitude::float8, 'lng', ts.longitude::float8,
             'at', ts.reported_at, 'speed', ts.speed_kmh::float8, 'ignition', ts.ignition_on,
             'moving', ts.reported_at > now() - interval '15 minutes' and coalesce(ts.speed_kmh, 0) >= 3) end)
    from vehicles v
    left join tracker_devices d on d.vehicle_id = v.id and d.status = 'installed'
    left join tracker_status ts on ts.tracker_device_id = d.id and ts.reported_at > '-infinity'
   where v.id = p_vehicle
   order by ts.reported_at desc nulls last limit 1
$$;
create function app.tracker_car(p_user uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_vehicle uuid;
begin
  perform app.tracker_assert(p_user, false);
  v_vehicle := coalesce(nullif(p ->> 'vehicle', '')::uuid, (select b.vehicle_id from bookings b where b.booking_number = nullif(p ->> 'booking', '')));
  if v_vehicle is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  return app.car_position(v_vehicle);
end $$;

-- ================================================================ 2. owners: their own cars, the location only
create function app.owner_car_location(p_user uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_vehicle uuid := nullif(p ->> 'vehicle', '')::uuid; v_days integer := least(greatest(coalesce((p ->> 'days')::integer, 30), 1), 90);
begin
  if v_vehicle is null or not app.user_owns_vehicle(p_user, v_vehicle) then
    raise exception 'Only the owner of this car sees where it is' using errcode = '42501';
  end if;
  -- trips: when, how far and from where to where; never the booking, the renter or the booking dates
  return app.car_position(v_vehicle) || jsonb_build_object('days', v_days,
    'trips', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'started_at', t.started_at, 'ended_at', t.ended_at, 'km', t.km::float8,
                 'from', case when t.start_lat is not null then jsonb_build_object('lat', t.start_lat::float8, 'lng', t.start_lng::float8) end,
                 'to', case when t.end_lat is not null then jsonb_build_object('lat', t.end_lat::float8, 'lng', t.end_lng::float8) end) order by t.started_at desc)
               from (select * from tracker_trips x where x.vehicle_id = v_vehicle and x.started_at > now() - make_interval(days => v_days)
                      order by x.started_at desc limit 50) t), '[]'::jsonb));
end $$;

-- row level security: the position history, to every staff member and to the car's own owner
create policy staff_read on tracker_points for select to authenticated using (app.is_staff() or app.is_field());
create policy owner_read on tracker_points for select to authenticated using (app.owns_vehicle(vehicle_id));

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre3041;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'ops_read' and p_name in ('tracker_car', 'owner_car_location') then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'tracker_car' then app.tracker_car(p_user, coalesce(p, '{}'::jsonb) - '_va')
                       else app.owner_car_location(p_user, coalesce(p, '{}'::jsonb)) end;
  end if;
  return app.door_pre3041(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre3041(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 3. who sees the location, in the privacy policy; the lawyer's review
update site_content_blocks
   set body = replace(body, 'The vehicle''s owner can see the vehicle''s location during your rental.',
     'The vehicle''s location is visible to CarmaCars staff (to run the fleet and help you) and to the vehicle''s owner, during your rental and at any other time. Staff and owners see the location only; an owner does not see your name or your booking unless the owner manages the rental.')
 where block_key = 'legal.privacy' and body like '%The vehicle''s owner can see the vehicle''s location during your rental.%';
update site_content_blocks
   set body = replace(body, '- **Vehicle owners.** The owner of a vehicle can see its location during your rental, its status and its booking dates.',
     '- **CarmaCars staff.** Our staff see each vehicle''s location and trips, read only, to run the fleet and help you.' || chr(10) || '- **Vehicle owners.** The owner of a vehicle can see its location during your rental, its status and its booking dates.')
 where block_key = 'legal.privacy' and body like '%- **Vehicle owners.** The owner of a vehicle can see its location during your rental, its status and its booking dates.%'
   and body not like '%- **CarmaCars staff.** Our staff see each vehicle''s location%';
update site_content_blocks set data = data || jsonb_build_object('last_updated', 'November 15, 2026')
 where block_key = 'legal.meta' and coalesce(data ->> 'last_updated', '') <> 'November 15, 2026'
   and exists (select 1 from site_content_blocks b where b.block_key = 'legal.privacy' and b.body like '%visible to CarmaCars staff (to run the fleet and help you)%');

alter function app.owner_steps() rename to owner_steps_pre3041;
create function app.owner_steps() returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v jsonb := app.owner_steps_pre3041();
begin
  if not exists (select 1 from site_content_blocks b where b.block_key = 'legal.meta' and nullif(b.data ->> 'tracker_visibility_reviewed', '') is not null) then
    v := v || jsonb_build_array(jsonb_build_object('key', 'tracker_visibility', 'feature', 'Car locations seen by all staff and by owners (release 48)',
      'step', 'Lawyer: review the new wording in the privacy policy (section 2, Tracker data and Who we share with) and the rental agreement (section 12.1 and consent 1): CarmaCars staff of every role and the car''s owner see the car''s location and trips, read only, during and outside rentals; owners see the location only. Enrollment Agreement 5.2 may need the same. Then in Admin > Site content, legal.meta, set tracker_visibility_reviewed to the review date.'));
  end if;
  return v;
end $$;
select pg_temp.copy_grants('app.owner_steps()'::regprocedure, 'app.owner_steps_pre3041()'::regprocedure);

-- ================================================================ privileges
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['tracker_reader', 'tracker_fleet_staff', 'tracker_fleet_pre3041', 'tracker_trip_path_pre3041',
              'tracker_alert_ack_pre3041', 'car_position', 'tracker_car', 'owner_car_location', 'door_pre3041', 'owner_steps_pre3041'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
