-- 0990_r35p_showroom.sql
-- Release 35, part P (docs/changes/2026-11-08-r35-showroom-photos.md): the showroom scene for listing photos. The owner: "photos
-- look like they're taken in a dealership with the CarmaCars logo behind instead of a black background with the cars
-- floating; keep the dealership background very simple and dark; put the vehicle model behind the car in the first pic".
--   1. vehicle_photos.scene: 'showroom' (the dark showroom, web/src/features/listing/showroom.ts) or 'studio' (the black
--      studio; also NULL, every photo made before this). A new photo takes its car's scene (every angle of a car in the same
--      room); a car with no photo yet takes Program settings' listing_showroom (on). The job context names the scene; the
--      worker's preset is studio_showroom_v1 (a studio preset: the home hero and the plate rules treat it as one).
--   2. The image model (Google AI Studio, the Worker's GEMINI_API_KEY): Program settings listing_showroom_ai (on), its model
--      (listing_showroom_ai_model) and a hard daily limit (listing_showroom_ai_daily, 25). The worker asks the gate first
--      (server_showroom_ai_gate: off, the limit, or a quota answer in the last hour stop it; each call is counted before it
--      is made, so the limit holds with jobs side by side) and records the answer (server_showroom_ai_record). Every refusal
--      or error keeps the free local showroom and vehicle_photos.showroom says why.
--   3. ops_do photo_showroom {action apply | redo | undo; photo, vehicle or intake, or all}: apply puts a car's outside photos
--      in the showroom (all: every car, Admin or fleet), redo makes a photo again, undo takes a photo back to the version
--      before the showroom (or makes it again on the black studio when it never had one). The version before is kept
--      (vehicle_photo_versions, reason showroom), files get new names (edit_version), and the plate check carries over
--      when the car stays where it was (0700), else it is asked again before the photo is back on the site.
-- SCHEMA_MARKER 0991 (with the guides of 0991). No applied migration is edited; functions changed are wrapped (_pre0990).

-- ================================================================ settings and columns
alter table program_settings
  add column if not exists listing_showroom boolean not null default true,
  add column if not exists listing_showroom_ai boolean not null default true,
  add column if not exists listing_showroom_ai_model text not null default 'gemini-2.5-flash-image',
  add column if not exists listing_showroom_ai_daily integer not null default 25;
alter table program_settings drop constraint if exists program_settings_listing_showroom_ai_model_check;
alter table program_settings add constraint program_settings_listing_showroom_ai_model_check check (listing_showroom_ai_model ~ '^[a-z0-9][a-z0-9.-]{2,80}$');
alter table program_settings drop constraint if exists program_settings_listing_showroom_ai_daily_check;
alter table program_settings add constraint program_settings_listing_showroom_ai_daily_check check (listing_showroom_ai_daily between 0 and 500);
comment on column program_settings.listing_showroom is 'Showroom photos (0990): a car''s new outside photos are put in the dark CarmaCars showroom (the logo on the wall, the model''s name behind the car on the cover) instead of the black studio. A car keeps the scene of its photos so every angle matches.';
comment on column program_settings.listing_showroom_ai is 'Showroom photos: an image model makes the showroom look photographed when GEMINI_API_KEY is set in the Worker. Off, or past the daily limit: the free showroom made by the site.';
comment on column program_settings.listing_showroom_ai_model is 'Showroom photos: the image model asked (Google AI Studio model name).';
comment on column program_settings.listing_showroom_ai_daily is 'Showroom photos: at most this many image model calls a Toronto day (a hard stop; then the free showroom is used). 0 never asks it.';

alter table vehicle_photos
  add column if not exists scene text,
  add column if not exists showroom jsonb;
alter table vehicle_photos drop constraint if exists vehicle_photos_scene_check;
alter table vehicle_photos add constraint vehicle_photos_scene_check check (scene is null or scene in ('studio', 'showroom'));
comment on column vehicle_photos.scene is 'The scene of an outside photo (0990): showroom (the dark CarmaCars showroom) or studio (the black studio; NULL is studio, every photo made before 0990).';
comment on column vehicle_photos.showroom is 'How the showroom photo was made (0990): provider (local, the free composite, or ai, the image model), model, note (why the free one was used), at.';

comment on column vehicle_photo_versions.reason is 'Why the version was kept: cutout_edit (0700), showroom (before the showroom was applied: Back to the original restores it), showroom_redo, showroom_undo (0990).';

-- a new photo takes the scene of its car's photos; a car with none takes Program settings
create or replace function app.vehicle_photo_scene_default() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.scene is null then
    new.scene := coalesce(
      (select coalesce(x.scene, 'studio') from vehicle_photos x join listing_shot_types s on s.code = x.shot_type
        where x.vehicle_id = new.vehicle_id and x.id <> new.id and x.replaced_at is null and x.status <> 'rejected' and s.rebackground
        order by x.created_at desc limit 1),
      case when coalesce((app.settings()).listing_showroom, true) then 'showroom' else 'studio' end);
  end if;
  return new;
end $$;
drop trigger if exists vehicle_photos_scene_default on vehicle_photos;
create trigger vehicle_photos_scene_default before insert on vehicle_photos for each row execute function app.vehicle_photo_scene_default();

-- ================================================================ the job context and the result
do $$ begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname = 'listing_job_context_pre0990') then
    alter function app.listing_job_context(uuid) rename to listing_job_context_pre0990;
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname = 'worker_listing_result_pre0990') then
    alter function app.worker_listing_result(uuid, jsonb) rename to worker_listing_result_pre0990;
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname = 'door_pre0990') then
    alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0990;
  end if;
end $$;

create function app.listing_job_context(p_job uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when x -> 'photo' is null or jsonb_typeof(x -> 'photo') <> 'object' then x
              else jsonb_set(x, '{photo,scene}', to_jsonb(coalesce(ph.scene, 'studio'))) end
    from (select app.listing_job_context_pre0990(p_job) x) q
    left join vehicle_photos ph on ph.id = (q.x -> 'photo' ->> 'id')::uuid
$$;

create function app.worker_listing_result(p_job uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare j listing_jobs; r jsonb; v_out jsonb := coalesce(p -> 'output', '{}'::jsonb);
begin
  select * into j from listing_jobs where id = p_job;
  r := app.worker_listing_result_pre0990(p_job, p);
  if j.kind = 'process_photo' and j.vehicle_photo_id is not null and coalesce((p ->> 'ok')::boolean, false)
     and not coalesce((j.input ->> 'mask_only')::boolean, false) then
    if jsonb_typeof(v_out -> 'showroom') = 'object' then
      update vehicle_photos set showroom = jsonb_build_object('provider', coalesce(v_out -> 'showroom' ->> 'provider', 'local'), 'model', v_out -> 'showroom' ->> 'model',
               'note', v_out -> 'showroom' ->> 'note', 'reason', v_out -> 'showroom' ->> 'reason', 'at', now())
       where id = j.vehicle_photo_id;
    elsif coalesce(v_out ->> 'preset_version', '') <> '' then
      update vehicle_photos set showroom = null where id = j.vehicle_photo_id and showroom is not null;
    end if;
  end if;
  return r;
end $$;

-- 0700's "frame again": each photo compared with the preset of its own scene (a showroom photo is not made again for nothing);
-- a preset named by the caller is compared as given, as before
create or replace function app.listing_photos_reframe(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_vehicle uuid; v_preset text := coalesce(nullif(p ->> 'preset', ''), 'studio_v5'); v_all boolean := coalesce((p ->> 'all')::boolean, false);
        r record; n integer := 0;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet', 'cs')) then
    raise exception 'Fleet, customer service or an Admin edits listing photos' using errcode = '42501';
  end if;
  v_vehicle := coalesce((p ->> 'vehicle')::uuid, (select i.vehicle_id from listing_intakes i where i.id = (p ->> 'intake')::uuid));
  if v_vehicle is null then raise exception 'Unknown listing' using errcode = 'P0002'; end if;
  for r in
    select ph.id, ph.intake_id, ph.cutout from vehicle_photos ph join listing_shot_types s on s.code = ph.shot_type
     where ph.vehicle_id = v_vehicle and ph.replaced_at is null and ph.status <> 'rejected' and ph.intake_id is not null
       and s.rebackground and s.is_public
       and (v_all or coalesce(ph.preset_version, '') <> case when ph.scene = 'showroom' and nullif(p ->> 'preset', '') is null then 'studio_showroom_v1' else v_preset end)
       and not exists (select 1 from listing_jobs j where j.vehicle_photo_id = ph.id and j.kind = 'process_photo' and j.status in ('queued', 'running'))
  loop
    update vehicle_photos set background_status = 'pending', is_public = false, plate_status = 'unchecked', plate_boxes = '[]'::jsonb,
           plate_suggestion = null, uncovered_path = null, plate_carry = null, reframed_at = now()
     where id = r.id;
    perform app.enqueue_listing_job(r.intake_id, 'process_photo', r.id,
      case when nullif(r.cutout ->> 'mask', '') is not null
           then jsonb_build_object('edit', jsonb_build_object('cutout_path', r.cutout ->> 'mask', 'adjust', coalesce(r.cutout -> 'adjust', '{}'::jsonb), 'reframe', true))
           else '{}'::jsonb end);
    n := n + 1;
  end loop;
  return jsonb_build_object('vehicle', v_vehicle, 'queued', n);
end $$;

-- ================================================================ the image model's gate and record (no person: the worker)
create function app.showroom_ai_gate(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare ps program_settings := app.settings(); v_used integer; v_id uuid;
begin
  if not coalesce(ps.listing_showroom_ai, false) then return jsonb_build_object('allowed', false, 'reason', 'off'); end if;
  -- one gate at a time: the count and the call it allows are one step, so jobs side by side never pass the limit
  perform pg_advisory_xact_lock(hashtext('carmacars_showroom_ai'));
  if exists (select 1 from provider_calls c where c.purpose = 'listing_showroom' and not c.ok and c.error like 'quota%' and c.created_at > now() - interval '1 hour') then
    return jsonb_build_object('allowed', false, 'reason', 'quota');
  end if;
  select count(*) into v_used from provider_calls c where c.purpose = 'listing_showroom' and c.created_at >= app.local_midnight(app.local_date(now()));
  if v_used >= ps.listing_showroom_ai_daily then
    return jsonb_build_object('allowed', false, 'reason', 'limit', 'used', v_used, 'limit', ps.listing_showroom_ai_daily);
  end if;
  insert into provider_calls (provider, purpose, ok, error, duration_ms, cost_microusd, units, unit, vehicle_id)
  values (left('google-ai:' || ps.listing_showroom_ai_model, 120), 'listing_showroom', false, 'started', 0, 0, 1, 'requests',
          (select ph.vehicle_id from vehicle_photos ph where ph.id = nullif(p ->> 'photo_id', '')::uuid))
  returning id into v_id;
  return jsonb_build_object('allowed', true, 'model', ps.listing_showroom_ai_model, 'call_id', v_id, 'used', v_used + 1, 'limit', ps.listing_showroom_ai_daily);
end $$;

create function app.showroom_ai_record(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  update provider_calls set ok = coalesce((p ->> 'ok')::boolean, false), error = left(nullif(p ->> 'error', ''), 300),
         duration_ms = greatest(coalesce((p ->> 'duration_ms')::integer, 0), 0)
   where id = nullif(p ->> 'call_id', '')::uuid and purpose = 'listing_showroom';
  return jsonb_build_object('ok', found);
end $$;

create function public.server_showroom_ai_gate(p jsonb default '{}'::jsonb) returns jsonb
language sql volatile security definer set search_path = public, app as $$ select app.showroom_ai_gate(p) $$;
create function public.server_showroom_ai_record(p jsonb) returns jsonb
language sql volatile security definer set search_path = public, app as $$ select app.showroom_ai_record(p) $$;

-- ================================================================ staff: apply, redo, undo
-- one photo into the showroom (or back to the studio): the version before kept, a new file name, made again from its cut-out
create function app.photo_scene_queue(p_by uuid, p_photo uuid, p_scene text, p_reason text) returns void
language plpgsql security definer set search_path = public, app as $$
declare ph vehicle_photos; v_mask text;
begin
  select * into ph from vehicle_photos where id = p_photo for update;
  insert into vehicle_photo_versions (photo_id, version, processed_path, variants, preset_version, uncovered_path, plate_status, plate_boxes, plate_style, cutout, reason, created_by)
  values (ph.id, ph.edit_version, ph.processed_path, ph.variants, ph.preset_version, ph.uncovered_path, ph.plate_status, ph.plate_boxes, ph.plate_style, ph.cutout, p_reason, p_by)
  on conflict (photo_id, version) do nothing;
  v_mask := coalesce(nullif(ph.cutout ->> 'mask', ''), nullif(ph.cutout ->> 'auto_mask', ''));
  update vehicle_photos set edit_version = edit_version + 1, scene = p_scene, showroom = null where id = ph.id;
  if v_mask is not null then
    -- from the kept cut-out (no new background removal): 0700's edit rules, so the plate check carries over when the car
    -- stays where it was, and the photo stays on the site while it is made
    perform app.enqueue_listing_job(ph.intake_id, 'process_photo', ph.id, jsonb_build_object('scene', p_scene,
      'edit', jsonb_build_object('cutout_path', v_mask, 'adjust', coalesce(ph.cutout -> 'adjust', '{}'::jsonb))));
  else
    -- a photo made before the cut-out was kept: cut out again, off the site until its plate is checked (0661)
    update vehicle_photos set background_status = 'pending', is_public = false, plate_status = 'unchecked', plate_boxes = '[]'::jsonb,
           plate_suggestion = null, uncovered_path = null, plate_carry = null, reframed_at = now()
     where id = ph.id;
    perform app.enqueue_listing_job(ph.intake_id, 'process_photo', ph.id, jsonb_build_object('scene', p_scene));
  end if;
end $$;

create function app.photo_showroom(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_action text := coalesce(nullif(p ->> 'action', ''), 'apply'); v_all boolean := coalesce((p ->> 'all')::boolean, false);
        v_photo uuid := nullif(p ->> 'photo', '')::uuid; v_vehicle uuid; ph vehicle_photos; v vehicle_photo_versions; r record; n integer := 0; v_set integer := 0;
        v_back boolean;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet', 'cs')) then
    raise exception 'Fleet, customer service or an Admin edits listing photos' using errcode = '42501';
  end if;
  if v_action not in ('apply', 'redo', 'undo') then raise exception 'Unknown showroom action' using errcode = '22023'; end if;
  if v_all and not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet')) then
    raise exception 'An Admin or fleet puts every car in the showroom' using errcode = '42501';
  end if;
  if v_all and v_action <> 'apply' then raise exception 'Every car at once is for Apply only' using errcode = '22023'; end if;
  if not v_all and v_photo is null then
    v_vehicle := coalesce(nullif(p ->> 'vehicle', '')::uuid, (select i.vehicle_id from listing_intakes i where i.id = nullif(p ->> 'intake', '')::uuid));
    if v_vehicle is null or not exists (select 1 from vehicles where id = v_vehicle) then raise exception 'Unknown car' using errcode = 'P0002'; end if;
  end if;
  if v_action in ('redo', 'undo') and v_photo is null then raise exception 'Choose the photo' using errcode = '22023'; end if;

  if v_photo is not null then
    select * into ph from vehicle_photos where id = v_photo;
    if ph.id is null then raise exception 'Unknown photo' using errcode = 'P0002'; end if;
    if not exists (select 1 from listing_shot_types s where s.code = ph.shot_type and s.rebackground and s.is_public)
       or ph.replaced_at is not null or ph.status = 'rejected' or ph.intake_id is null then
      raise exception 'Only an outside photo on the site''s background goes in the showroom' using errcode = '23514';
    end if;
    if exists (select 1 from listing_jobs j where j.vehicle_photo_id = ph.id and j.kind = 'process_photo' and j.status in ('queued', 'running')) then
      raise exception 'The photo is being made now. Try again in a minute.' using errcode = '23514';
    end if;
  end if;

  if v_action = 'undo' then
    select * into v from vehicle_photo_versions x where x.photo_id = ph.id and x.reason = 'showroom' and x.processed_path is not null
     order by x.version desc limit 1;
    if v.id is null then
      -- made in the showroom from the start: made again on the black studio
      perform app.photo_scene_queue(p_by, ph.id, 'studio', 'showroom_undo');
      return jsonb_build_object('photo', ph.id, 'action', 'undo', 'queued', 1, 'restored', false);
    end if;
    -- the version before the showroom, as it was (its files were kept); on the site again when its plate was checked
    insert into vehicle_photo_versions (photo_id, version, processed_path, variants, preset_version, uncovered_path, plate_status, plate_boxes, plate_style, cutout, reason, created_by)
    values (ph.id, ph.edit_version, ph.processed_path, ph.variants, ph.preset_version, ph.uncovered_path, ph.plate_status, ph.plate_boxes, ph.plate_style, ph.cutout, 'showroom_undo', p_by)
    on conflict (photo_id, version) do nothing;
    v_back := v.plate_status in ('covered', 'not_visible')
              and (ph.status = 'approved' or exists (select 1 from vehicle_listings l where l.vehicle_id = ph.vehicle_id and l.status in ('published', 'paused')));
    update vehicle_photos set processed_path = v.processed_path, variants = v.variants, preset_version = v.preset_version, uncovered_path = v.uncovered_path,
           plate_status = v.plate_status, plate_boxes = coalesce(v.plate_boxes, '[]'::jsonb), plate_style = v.plate_style, cutout = v.cutout,
           plate_carry = null, plate_suggestion = null, scene = 'studio', showroom = null, edit_version = edit_version + 1, background_status = 'done',
           status = case when v_back then 'approved' else status end,
           is_public = case when v_back then coalesce((select s.is_public from listing_shot_types s where s.code = ph.shot_type), false) else false end
     where id = ph.id;
    return jsonb_build_object('photo', ph.id, 'action', 'undo', 'queued', 0, 'restored', true, 'public', v_back);
  end if;

  for r in
    select x.id from vehicle_photos x join listing_shot_types s on s.code = x.shot_type join vehicles c on c.id = x.vehicle_id
     where (case when v_photo is not null then x.id = v_photo when v_all then true else x.vehicle_id = v_vehicle end)
       and not coalesce(c.is_sample, false) and x.replaced_at is null and x.status <> 'rejected' and x.intake_id is not null
       and s.rebackground and s.is_public and x.processed_path is not null
       and (v_action = 'redo' or coalesce(x.scene, 'studio') <> 'showroom' or coalesce(x.preset_version, '') <> 'studio_showroom_v1')
       and not exists (select 1 from listing_jobs j where j.vehicle_photo_id = x.id and j.kind = 'process_photo' and j.status in ('queued', 'running'))
     order by x.vehicle_id, x.sort_order
  loop
    perform app.photo_scene_queue(p_by, r.id, 'showroom', case when v_action = 'redo' then 'showroom_redo' else 'showroom' end);
    n := n + 1;
  end loop;
  -- the car's photos not made yet take the showroom too (every angle in the same room)
  if v_action = 'apply' and v_photo is null then
    update vehicle_photos x set scene = 'showroom'
     where (v_all or x.vehicle_id = v_vehicle) and x.replaced_at is null and coalesce(x.scene, 'studio') <> 'showroom'
       and not exists (select 1 from vehicles c where c.id = x.vehicle_id and coalesce(c.is_sample, false));
    get diagnostics v_set = row_count;
  end if;
  return jsonb_build_object('vehicle', v_vehicle, 'photo', v_photo, 'all', v_all, 'action', v_action, 'queued', n, 'scene_set', v_set);
end $$;

create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_do', 'va_do') and p_name = 'photo_showroom' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.photo_showroom(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre0990(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ privileges
do $$
declare r record; v_new regprocedure; g text;
begin
  for r in select p.oid, m.new_name, oidvectortypes(p.proargtypes) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             join (values ('listing_job_context_pre0990', 'listing_job_context'), ('worker_listing_result_pre0990', 'worker_listing_result'),
                          ('door_pre0990', 'door')) m(old_name, new_name) on m.old_name = p.proname
            where n.nspname = 'app' loop
    v_new := format('app.%I(%s)', r.new_name, r.args)::regprocedure;
    execute format('revoke all on function %s from public, anon, authenticated', v_new);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;
revoke all on function app.vehicle_photo_scene_default(), app.listing_photos_reframe(uuid, jsonb), app.showroom_ai_gate(jsonb), app.showroom_ai_record(jsonb),
  app.photo_scene_queue(uuid, uuid, text, text), app.photo_showroom(uuid, jsonb), public.server_showroom_ai_gate(jsonb), public.server_showroom_ai_record(jsonb)
  from public, anon, authenticated;
grant execute on function app.vehicle_photo_scene_default(), app.listing_photos_reframe(uuid, jsonb), app.showroom_ai_gate(jsonb), app.showroom_ai_record(jsonb),
  app.photo_scene_queue(uuid, uuid, text, text), app.photo_showroom(uuid, jsonb), public.server_showroom_ai_gate(jsonb), public.server_showroom_ai_record(jsonb)
  to service_role;
