-- 2842_r45_photo_admin.sql
-- Release 45: the photo standard in Admin (Listings, and Fleet's Listings): per car, its photos at the standard out of all,
-- the angles generated, the photos flagged, when it was last worked on; "Redo this car now" and "Redo every car".
--   ops_read / va_read photo_r45_fleet: the cars (newest listed first) and the day's Gemini use.
--   ops_do / va_do photo_r45_redo {vehicle}: every photo of the car made again at r45.1 now (also those at the standard),
--     its missing angles generated; {all: true}: every car's photos marked to be made again, the job does them over the
--     next hours (newest listed cars first), the first batch queued at once.
--   ops_do photo_showroom {action gemini} ("Redo photos with Gemini", "Redo every car with Gemini") does the same now.
-- Admin and fleet staff.
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

-- every car: an Admin or fleet; one car: also customer service (as Redo photos with Gemini before)
create function app.photo_r45_may(p_by uuid, p_all boolean default true) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_by is not null and (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet') or (not p_all and app.user_va_has(p_by, 'cs')))
$$;

create function app.photo_r45_fleet_read(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare ps program_settings := app.settings();
begin
  if not app.photo_r45_may(p_by) then raise exception 'An Admin or fleet sees the photo standard' using errcode = '42501'; end if;
  return jsonb_build_object('spec', app.photo_spec(), 'auto', coalesce(ps.listing_photo_r45_auto, true) and coalesce(ps.listing_showroom_ai, false),
    'daily', ps.listing_showroom_ai_daily, 'reserve', ps.listing_photo_r45_reserve, 'left_today', app.photo_gemini_left(0), 'waiting', app.photo_r45_outstanding(),
    'cars', coalesce((select jsonb_agg(x.o order by x.listed_at desc, x.id) from (
      select c.vehicle_id as id, c.listed_at, jsonb_build_object('id', c.vehicle_id, 'name', app.vehicle_name(c.vehicle_id), 'fleet_number', v.fleet_number,
        'total', count(ph.id) filter (where app.photo_r45_applies(ph)),
        'at_standard', count(ph.id) filter (where app.photo_r45_applies(ph) and ph.r45 ->> 'spec' = app.photo_spec() and ph.r45 ->> 'state' = 'done'),
        'generated', count(ph.id) filter (where app.photo_r45_applies(ph) and ph.ai_generated and ph.r45 ->> 'state' = 'done'),
        'flagged', count(ph.id) filter (where app.photo_r45_applies(ph) and ph.r45 ->> 'state' = 'flagged'),
        'queued', count(ph.id) filter (where app.photo_r45_applies(ph) and ph.r45 ->> 'state' = 'queued'),
        'missing', (select count(*) from app.photo_r45_missing(c.vehicle_id)),
        'last_run', max((ph.r45 ->> 'at')::timestamptz),
        'primary', app.vehicle_primary_state(c.vehicle_id), 'done', app.photo_r45_car_done(c.vehicle_id)) as o
        from app.photo_r45_cars() c join vehicles v on v.id = c.vehicle_id
        left join vehicle_photos ph on ph.vehicle_id = c.vehicle_id and ph.replaced_at is null
       group by c.vehicle_id, c.listed_at, v.fleet_number) x), '[]'::jsonb));
end $$;

-- p: vehicle | all
create function app.photo_r45_redo(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_vehicle uuid := nullif(p ->> 'vehicle', '')::uuid; v_all boolean := coalesce((p ->> 'all')::boolean, false); x jsonb; n integer;
begin
  if not app.photo_r45_may(p_by, v_all) then
    raise exception '%', case when v_all then 'An Admin or fleet redoes every car''s photos' else 'An Admin, Fleet, customer service redo a car''s photos' end using errcode = '42501';
  end if;
  if not coalesce((app.settings()).listing_showroom_ai, false) then
    raise exception 'Gemini is switched off (Program settings, listing showroom AI). Switch it on first: the photos were not changed.' using errcode = '23514';
  end if;
  if v_all then
    -- every photo of every car made again at r45.1 (also those at it: asked), by the job, newest listed cars first
    update vehicle_photos ph set r45 = coalesce(ph.r45, '{}'::jsonb) || jsonb_build_object('state', 'redo', 'tries', 0, 'at', now())
     where app.photo_r45_applies(ph) and coalesce(ph.r45 ->> 'state', '') <> 'queued';
    get diagnostics n = row_count;
    perform app.job_photo_r45();
    return jsonb_build_object('action', 'gemini', 'all', true, 'queued', app.photo_r45_outstanding(), 'resorting', 0, 'sharpened', 0,
      'waiting', n, 'left_today', app.photo_gemini_left(0), 'spec', app.photo_spec());
  end if;
  if v_vehicle is null or not exists (select 1 from vehicles where id = v_vehicle) then raise exception 'Unknown car' using errcode = 'P0002'; end if;
  perform app.photo_adopt_intake(v_vehicle);
  x := app.photo_r45_plan(p_by, v_vehicle, 60, true);
  -- now, ahead of the fleet's photos
  update listing_jobs set next_attempt_at = now() - interval '1 minute'
   where vehicle_id = v_vehicle and kind = 'photo_r45' and status = 'queued';
  return jsonb_build_object('action', 'gemini', 'vehicle', v_vehicle, 'queued', (x ->> 'queued')::integer, 'generating', (x ->> 'generating')::integer,
    'resorting', 0, 'spec', app.photo_spec());
end $$;

-- "Redo photos with Gemini" (a car) and "Redo every car with Gemini": the r45 redo (made from the original, not the cut-out)
alter function app.photo_showroom(uuid, jsonb) rename to photo_showroom_pre2842;
create function app.photo_showroom(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if coalesce(p ->> 'action', '') = 'gemini' and nullif(p ->> 'photo', '') is null
     and (coalesce((p ->> 'all')::boolean, false) or nullif(p ->> 'vehicle', '') is not null) then
    return app.photo_r45_redo(p_by, p);
  end if;
  if coalesce(p ->> 'action', '') = 'gemini' and nullif(p ->> 'photo', '') is not null then
    if not app.photo_r45_may(p_by, false) then raise exception 'An Admin, Fleet, customer service redo a car''s photos' using errcode = '42501'; end if;
    return jsonb_build_object('action', 'gemini', 'queued', case when app.photo_r45_queue(p_by, (p ->> 'photo')::uuid, true) then 1 else 0 end, 'resorting', 0);
  end if;
  return app.photo_showroom_pre2842(p_by, p);
end $$;
select pg_temp.copy_grants('app.photo_showroom(uuid, jsonb)'::regprocedure, 'app.photo_showroom_pre2842(uuid, jsonb)'::regprocedure);

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2842;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call in ('ops_read', 'va_read') and p_name = 'photo_r45_fleet') or (p_call in ('ops_do', 'va_do') and p_name = 'photo_r45_redo') then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    p := coalesce(p, '{}'::jsonb) - '_va';
    return case p_name when 'photo_r45_fleet' then app.photo_r45_fleet_read(p_user, p) else app.photo_r45_redo(p_user, p) end;
  end if;
  return app.door_pre2842(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2842(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['photo_r45_may', 'photo_r45_fleet_read', 'photo_r45_redo', 'photo_showroom_pre2842', 'door_pre2842'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
