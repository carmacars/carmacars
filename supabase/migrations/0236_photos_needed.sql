-- 0236: real photos for every car: the cars still on sample photos, and the handover photos as listing photos
-- (docs/changes/2026-11-03-photos-needed.md). The owner: "we need photos of each car, is the ai photo editor working?"
-- The studio editor (0022, 0073: Cloudflare Images cuts the car out and puts it on the CarmaCars studio backdrop) is built
-- and wired, but it has never had a photo to work on: no listing photo was ever uploaded (Settings > Usage: 0 image
-- transformations), and 75 real cars show sample photos.
--
-- 1. app.photos_needed: each real car still on sample photos (app.vehicles_using_sample_photos, 0065), with its newest
--    condition report that has photos of the listing's shots (the check-out and check-in photos field staff take at every
--    handover), how many of the listing's shots it covers, and its listing intake in progress. Admins, fleet and field
--    staff read it (ops_read photos_needed).
-- 2. app.handover_listing_photos: the newest such report's photos, one per listing shot (the eight sides and corners, the
--    seats, the trunk; the instrument cluster as the dashboard and the odometer; a front wheel as the wheel). The site
--    copies each into the car's listing intake (web/src/server/actions/listing.ts listingFromHandover), as if taken on the
--    capture screen, and submits it when every required shot is there: the studio editor then runs on them and the
--    listing review follows as usual (an Admin approves before they replace the samples).
-- No applied migration is edited.

create or replace function app.handover_shot_map() returns table (handover_shot text, listing_shot text, pref integer)
language sql immutable as $$
  values ('front_left', 'front_left', 1), ('front', 'front', 1), ('left', 'left', 1), ('rear_left', 'rear_left', 1), ('rear', 'rear', 1),
         ('rear_right', 'rear_right', 1), ('right', 'right', 1), ('front_right', 'front_right', 1), ('front_seats', 'front_seats', 1),
         ('rear_seats', 'rear_seats', 1), ('trunk', 'trunk', 1), ('instrument_cluster', 'dashboard', 2), ('dashboard', 'dashboard', 1),
         ('instrument_cluster', 'odometer', 1), ('odometer', 'odometer', 1), ('wheel_front_left', 'wheel', 1), ('wheel_front_right', 'wheel', 2), ('wheel', 'wheel', 1)
$$;

-- the newest condition report of a car with photos of the listing's shots, and the photo for each shot
create or replace function app.handover_listing_set(p_vehicle uuid)
returns table (report_id uuid, performed_at timestamptz, shot_type text, bucket text, path text, width integer, height integer)
language sql stable security definer set search_path = public, app as $$
  with rep as (
    select c.id, c.performed_at from condition_reports c
     where c.vehicle_id = p_vehicle and c.booking_id is not null
       and exists (select 1 from condition_report_photos ph join app.handover_shot_map() m on m.handover_shot = ph.shot
                    where ph.condition_report_id = c.id and ph.damage_id is null and ph.storage_bucket = 'condition-photos')
     order by c.performed_at desc limit 1)
  select distinct on (m.listing_shot) rep.id, rep.performed_at, m.listing_shot, ph.storage_bucket, ph.storage_path, ph.width, ph.height
    from rep join condition_report_photos ph on ph.condition_report_id = rep.id
    join app.handover_shot_map() m on m.handover_shot = ph.shot
   where ph.damage_id is null and ph.storage_bucket = 'condition-photos'
   order by m.listing_shot, m.pref, ph.taken_at desc
$$;

create or replace function app.photos_needed(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not (app.user_is_admin(p_user) or app.user_va_has(p_user, 'fleet') or app.user_is_field(p_user)) then
    raise exception 'Admins, fleet and field staff see the cars that need photos' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'required', (select count(*) from listing_shot_types where required),
    'cars', coalesce((select jsonb_agg(x order by (x ->> 'handover_shots')::integer desc, x ->> 'name') from (
      select jsonb_build_object('vehicle_id', v.id, 'name', app.vehicle_name(v.id), 'fleet_number', v.fleet_number, 'status', v.status, 'listing_status', u.listing_status,
               'handover_at', (select max(h.performed_at) from app.handover_listing_set(v.id) h),
               'handover_shots', (select count(*) from app.handover_listing_set(v.id) h),
               'handover_required', (select count(*) from app.handover_listing_set(v.id) h join listing_shot_types t on t.code = h.shot_type and t.required),
               'intake', (select jsonb_build_object('id', i.id, 'state', i.state) from listing_intakes i
                           where i.vehicle_id = v.id and i.state not in ('published', 'failed', 'cancelled') order by i.created_at desc limit 1)) x
        from app.vehicles_using_sample_photos() u join vehicles v on v.id = u.vehicle_id
       where not coalesce(v.is_sample, false)) y), '[]'::jsonb));
end $$;

create or replace function app.handover_listing_photos(p_user uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v uuid := nullif(p ->> 'vehicle', '')::uuid;
begin
  if not (app.user_is_admin(p_user) or app.user_va_has(p_user, 'fleet')) then
    raise exception 'An Admin or fleet uses the handover photos for the listing' using errcode = '42501';
  end if;
  return jsonb_build_object('vehicle_id', v, 'photos', coalesce((select jsonb_agg(jsonb_build_object('shot_type', h.shot_type, 'bucket', h.bucket, 'path', h.path,
             'width', h.width, 'height', h.height, 'report_id', h.report_id, 'performed_at', h.performed_at) order by h.shot_type)
             from app.handover_listing_set(v) h), '[]'::jsonb));
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0236;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'ops_read' and p_name in ('photos_needed', 'handover_listing_photos') then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'photos_needed' then app.photos_needed(p_user) else app.handover_listing_photos(p_user, coalesce(p, '{}'::jsonb)) end;
  end if;
  return app.door_pre0236(p_user, p_aal, p_call, p_name, p);
end $$;
do $$
declare g text;
begin
  execute 'revoke all on function app.door(uuid, text, text, text, jsonb) from public, anon, authenticated';
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.door_pre0236(uuid, text, text, text, jsonb)'::regprocedure, 'execute') then
      execute format('grant execute on function app.door(uuid, text, text, text, jsonb) to %I', g);
    end if;
  end loop;
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('handover_shot_map', 'handover_listing_set', 'photos_needed', 'handover_listing_photos', 'door_pre0236') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
