-- 1053_r35s2_marketing_scenes.sql
-- Release 35, part S2 (docs/changes/2026-11-08-r35-showroom-v2-shift-jobs.md): scenes for the marketing copies of a car's
-- photos. The owner: "there should be a variety of backgrounds to choose from when we use the photos for marketplace listings".
-- The website keeps the dark showroom; a marketing set is extra, never replaces a website photo. No applied migration is edited.
--   1. Program settings marketing_scenes: the scenes staff choose from (code, label, how it is made, the image model's words
--      for the place). Seven to start: the dark showroom and a plain white studio (made by the site when the image model is not
--      there), a bright modern showroom, a city street at night, the Toronto skyline and waterfront, a modern parking garage
--      and an open scenic road (photographic: they need the image model, else the photo says "needs the image model").
--   2. vehicle_marketing_photos: one marketing copy of an outside photo in a scene (made, needs the image model, failed), a
--      set at a time per car. ops_do marketing_set {vehicle, scene | 'mix'} (Admin, Fleet, customer service or Sales) makes a
--      set from every outside photo with a kept cut-out: one scene for all, or "mix" (the scenes in turn across the photos).
--      The worker makes each (listing_jobs kind marketing_photo): the image model first (the car's own pixels kept, the plate
--      never shown), then the site's own scene where there is one. ops_read marketing_photos {vehicle}: the newest set.
--   3. The Marketplace kit's ZIP takes the newest set with ?set=scenes.
--   4. A scene can carry a photo of the real place (a car photo's original, or an uploaded photo): the image model is shown it
--      with the car and asked to put the car in that same place. "Brick building" (the place the owner photographed his own
--      cars) picks its photo by itself (app.marketing_auto_reference: an outside photo as taken of a shareholder's own car,
--      Mercedes-Benz first, the widest framing); an Admin can change it on Settings > Program > Marketing scenes (the
--      shareholders' cars' photos listed first, or an upload). Until any such photo exists it is left out of "mix".
--      "Highway" and the others work from their words alone.
-- SCHEMA_MARKER 1053.
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

-- ================================================================ 1. the scenes
alter table program_settings add column if not exists marketing_scenes jsonb not null default $j$[
  {"code": "showroom_dark", "label": "Dark showroom (the website's)", "made": "local", "place": "a modern, minimal, dark car dealership showroom at night: a charcoal back wall with a slatted walnut panel between two vertical LED strips, recessed linear lights in the ceiling, a polished dark epoxy floor with soft reflections"},
  {"code": "studio_white", "label": "Plain white studio", "made": "local", "place": "a seamless, plain white photo studio with soft even light, a light grey floor fading into a white wall, a soft shadow under the car"},
  {"code": "showroom_bright", "label": "Bright modern showroom", "made": "photo", "place": "a bright, modern car dealership showroom in daylight: floor-to-ceiling glass, white walls, a polished light grey floor with soft reflections"},
  {"code": "city_night", "label": "City street at night", "made": "photo", "place": "a downtown city street at night after light rain, glowing shop windows and street lights softly out of focus, wet asphalt with reflections"},
  {"code": "toronto_waterfront", "label": "Toronto skyline and waterfront", "made": "photo", "place": "a waterfront promenade in Toronto at golden hour, the city skyline with the CN Tower across the water behind the car, clean pavement"},
  {"code": "parking_garage", "label": "Modern parking garage", "made": "photo", "place": "a clean, modern concrete parking garage with linear ceiling lights and painted lines on a smooth grey floor"},
  {"code": "highway", "label": "Highway", "made": "photo", "place": "the paved shoulder of an open Ontario highway in soft morning light, the lanes running away behind the car, green fields and a wide sky"},
  {"code": "scenic_road", "label": "Scenic road", "made": "photo", "place": "an open two-lane road through green Ontario countryside in soft morning light, the road curving away behind the car"},
  {"code": "brick_building", "label": "Brick building", "made": "photo", "needs_reference": true, "reference": null, "auto_reference": "shareholder_wide", "place": "the same place as in the reference photo: in front of the same brick building, on the same ground, in the same light"}
]$j$::jsonb;
alter table program_settings drop constraint if exists program_settings_marketing_scenes_check;
alter table program_settings add constraint program_settings_marketing_scenes_check check (
  jsonb_typeof(marketing_scenes) = 'array' and jsonb_array_length(marketing_scenes) between 1 and 20
  and jsonb_path_match(marketing_scenes, '$[*].code like_regex "^[a-z0-9_]{2,40}$"') is not false
  and not jsonb_path_exists(marketing_scenes, '$[*] ? (!exists(@.code) || !exists(@.label) || !(@.made == "local" || @.made == "photo"))'));
comment on column program_settings.marketing_scenes is 'Marketing photo scenes (1053): each {code, label, made: local (the site makes it when the image model is not there: showroom_dark, studio_white) or photo (needs the image model), place: the image model''s words for the place, reference: {photo, path} a photo of the real place the image model is shown (picked or uploaded on Program settings), needs_reference: not used until one is picked}. Marketing copies never replace the website photos.';

-- ================================================================ 2. the marketing copies
create table vehicle_marketing_photos (
  id          uuid primary key default gen_random_uuid(),
  set_id      uuid not null,
  vehicle_id  uuid not null references vehicles (id),
  photo_id    uuid not null references vehicle_photos (id),
  scene       text not null check (scene ~ '^[a-z0-9_]{2,40}$'),
  sort        integer not null default 0,
  status      text not null default 'queued' check (status in ('queued', 'made', 'needs_gemini', 'failed')),
  path        text,
  provider    text,
  note        text check (note is null or length(note) <= 300),
  job_id      uuid references listing_jobs (id),
  created_by  uuid references users (id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (status <> 'made' or path is not null)
);
comment on table vehicle_marketing_photos is 'Marketing copies of a car''s outside photos in a chosen scene (1053), for Marketplace and social posts; never the website''s photos. The newest set of a car is the one shown and downloaded.';
create index vehicle_marketing_photos_vehicle on vehicle_marketing_photos (vehicle_id, created_at desc);
create trigger vehicle_marketing_photos_updated before update on vehicle_marketing_photos for each row execute function app.set_updated_at();
create trigger audit_vehicle_marketing_photos after insert or update or delete on vehicle_marketing_photos for each row execute function app.audit_row();
alter table vehicle_marketing_photos enable row level security;
create policy admin_all on vehicle_marketing_photos for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on vehicle_marketing_photos from public, anon, authenticated;
grant select on vehicle_marketing_photos to authenticated;
grant all on vehicle_marketing_photos to service_role;

alter table listing_jobs drop constraint if exists listing_jobs_kind_check;
alter table listing_jobs add constraint listing_jobs_kind_check check (kind in ('decode_vin', 'draft_copy', 'process_photo', 'resize', 'publish', 'marketing_photo'));

create function app.marketing_may(p_by uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet', 'cs') or app.user_va_has(p_by, 'sales')
$$;

-- the private file of a scene's reference: a car photo's original, or an uploaded photo of the place
create function app.marketing_reference_path(p_ref jsonb) returns text
language sql stable security definer set search_path = public, app as $$
  select case when p_ref is null or jsonb_typeof(p_ref) <> 'object' then null
              when nullif(p_ref ->> 'photo', '') is not null then (select ph.original_path from vehicle_photos ph where ph.id = (p_ref ->> 'photo')::uuid)
              when (p_ref ->> 'path') ~ '^site/scenes/[a-z0-9_]{2,40}-[0-9a-f-]{36}\.(jpg|png)$' then p_ref ->> 'path' end
$$;

-- the photo of the place where the owner photographed his own cars, picked by itself (an Admin can change it): an outside photo
-- as taken (its background never removed: the original file) of a shareholder's own car, Mercedes-Benz first (the owner's
-- fleet), then the widest framing (the widest aspect, then the most pixels across), then the oldest
create function app.marketing_auto_reference() returns uuid
language sql stable security definer set search_path = public, app as $$
  select ph.id from vehicle_photos ph join vehicles v on v.id = ph.vehicle_id join owners o on o.id = v.owner_id
    join listing_shot_types st on st.code = ph.shot_type
   where (o.is_shareholder or coalesce(v.is_shareholder_owned, false)) and not coalesce(v.is_sample, false)
     and st.rebackground and ph.original_path is not null and ph.replaced_at is null and ph.status <> 'rejected'
   order by (v.make ilike 'mercedes%') desc, (ph.width::numeric / nullif(ph.height, 0)) desc nulls last, ph.width desc nulls last, ph.created_at, ph.id
   limit 1
$$;

-- a scene's reference file: the one chosen, else (a scene marked so) the one picked by itself
create function app.marketing_scene_path(p_scene jsonb) returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce(app.marketing_reference_path(p_scene -> 'reference'),
    case when p_scene ->> 'auto_reference' = 'shareholder_wide' then (select ph.original_path from vehicle_photos ph where ph.id = app.marketing_auto_reference()) end)
$$;

-- Admin: choose a scene's reference (p: code, and photo or path; clear) and what to choose from: the photos of the
-- shareholders' cars first (a person picks the one of the place; nothing is guessed here)
create function app.marketing_scene_reference(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_code text := p ->> 'code';
  v_ref jsonb;
  v_id uuid := (select id from app.settings());
  v_scenes jsonb;
begin
  if not app.user_is_admin(p_by) then raise exception 'An Admin chooses a scene''s reference photo' using errcode = '42501'; end if;
  select marketing_scenes into v_scenes from program_settings where id = v_id for update;
  if not exists (select 1 from jsonb_array_elements(v_scenes) x where x ->> 'code' = v_code) then raise exception 'Unknown scene' using errcode = 'P0002'; end if;
  if coalesce((p ->> 'clear')::boolean, false) then v_ref := null;
  elsif nullif(p ->> 'photo', '') is not null then
    if not exists (select 1 from vehicle_photos ph where ph.id = (p ->> 'photo')::uuid and ph.original_path is not null) then raise exception 'Unknown photo' using errcode = 'P0002'; end if;
    v_ref := jsonb_build_object('photo', p ->> 'photo');
  else
    v_ref := jsonb_build_object('path', p ->> 'path');
    if app.marketing_reference_path(v_ref) is null then raise exception 'The upload is not one of ours' using errcode = '22023'; end if;
  end if;
  update program_settings set marketing_scenes = (select jsonb_agg(case when x ->> 'code' = v_code then x || jsonb_build_object('reference', v_ref) else x end order by k)
                                                     from jsonb_array_elements(v_scenes) with ordinality t(x, k))
   where id = v_id;
  return jsonb_build_object('code', v_code, 'reference', v_ref);
end $$;

create function app.marketing_scene_refs(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.user_is_admin(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  return jsonb_build_object(
    'scenes', coalesce((select jsonb_agg(jsonb_build_object('code', x ->> 'code', 'label', x ->> 'label', 'made', x ->> 'made', 'needs_reference', coalesce((x ->> 'needs_reference')::boolean, false),
                          'reference', x -> 'reference', 'ready', app.marketing_scene_path(x) is not null,
                          'auto', app.marketing_reference_path(x -> 'reference') is null and app.marketing_scene_path(x) is not null,
                          'auto_photo', case when x ->> 'auto_reference' = 'shareholder_wide' then app.marketing_auto_reference() end) order by k)
                         from jsonb_array_elements((app.settings()).marketing_scenes) with ordinality t(x, k)), '[]'::jsonb),
    'photos', coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'vehicle', q.vname, 'owner', q.oname, 'shareholder', q.sh, 'shot', q.shot_type) order by q.sh desc, q.oname, q.vname, q.sort_order)
                         from (select ph.id, ph.shot_type, ph.sort_order, app.vehicle_name(v.id) as vname, coalesce(o.legal_name, '') as oname, coalesce(o.is_shareholder, false) as sh
                                 from vehicle_photos ph join vehicles v on v.id = ph.vehicle_id left join owners o on o.id = v.owner_id
                                where ph.original_path is not null and ph.replaced_at is null and ph.status <> 'rejected' and not coalesce(v.is_sample, false)
                                order by coalesce(o.is_shareholder, false) desc, coalesce(o.legal_name, ''), ph.vehicle_id, ph.sort_order limit 80) q), '[]'::jsonb));
end $$;

-- p: vehicle, scene (a code of marketing_scenes, or mix)
create function app.marketing_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_vehicle uuid := nullif(p ->> 'vehicle', '')::uuid;
  v_scene text := coalesce(nullif(btrim(p ->> 'scene'), ''), 'mix');
  v_scenes jsonb := (app.settings()).marketing_scenes;
  v_set uuid := gen_random_uuid();
  v_intake uuid;
  r record;
  s jsonb;
  n integer := 0;
  v_id uuid;
  v_job uuid;
begin
  if not app.marketing_may(p_by) then raise exception 'An Admin, Fleet, customer service or Sales makes marketing photos' using errcode = '42501'; end if;
  if v_vehicle is null or not exists (select 1 from vehicles where id = v_vehicle) then raise exception 'Unknown car' using errcode = 'P0002'; end if;
  if v_scene <> 'mix' and not exists (select 1 from jsonb_array_elements(v_scenes) x where x ->> 'code' = v_scene) then
    raise exception 'Unknown scene: choose one of the list in Program settings' using errcode = '22023';
  end if;
  -- a scene that needs a photo of the real place is used once one is chosen (in "mix", left out until then)
  v_scenes := coalesce((select jsonb_agg(x || jsonb_build_object('reference_path', app.marketing_scene_path(x)))
                          from jsonb_array_elements(v_scenes) x
                         where not coalesce((x ->> 'needs_reference')::boolean, false) or app.marketing_scene_path(x) is not null), '[]'::jsonb);
  if v_scene <> 'mix' and not exists (select 1 from jsonb_array_elements(v_scenes) x where x ->> 'code' = v_scene) then
    raise exception 'Choose the reference photo of this scene first (Settings > Program > Marketing scenes)' using errcode = '23514';
  end if;
  if jsonb_array_length(v_scenes) = 0 then raise exception 'No scene is ready' using errcode = '23514'; end if;
  if exists (select 1 from vehicle_marketing_photos m where m.vehicle_id = v_vehicle and m.status = 'queued' and m.created_at > now() - interval '30 minutes') then
    raise exception 'A marketing set of this car is being made now. Try again in a few minutes.' using errcode = '23514';
  end if;
  v_intake := (select i.id from listing_intakes i where i.vehicle_id = v_vehicle order by i.created_at desc limit 1);
  if v_intake is null then raise exception 'This car has no listing photos yet' using errcode = '23514'; end if;
  for r in
    select ph.id, ph.cutout, ph.shot_type, row_number() over (order by ph.is_cover desc, ph.sort_order, ph.created_at) - 1 as k
      from vehicle_photos ph join listing_shot_types st on st.code = ph.shot_type
     where ph.vehicle_id = v_vehicle and ph.replaced_at is null and ph.status <> 'rejected' and st.rebackground and st.is_public
       and coalesce(nullif(ph.cutout ->> 'mask', ''), nullif(ph.cutout ->> 'auto_mask', '')) is not null
     order by ph.is_cover desc, ph.sort_order, ph.created_at
     limit 12
  loop
    s := case when v_scene = 'mix' then v_scenes -> (r.k % jsonb_array_length(v_scenes))::integer
              else (select x from jsonb_array_elements(v_scenes) x where x ->> 'code' = v_scene limit 1) end;
    insert into vehicle_marketing_photos (set_id, vehicle_id, photo_id, scene, sort, created_by)
    values (v_set, v_vehicle, r.id, s ->> 'code', r.k, p_by) returning id into v_id;
    v_job := app.enqueue_listing_job(v_intake, 'marketing_photo', null, jsonb_build_object('marketing', jsonb_build_object(
      'id', v_id, 'vehicle_id', v_vehicle, 'photo_id', r.id, 'scene', s ->> 'code', 'label', s ->> 'label', 'made', s ->> 'made', 'place', s ->> 'place',
      'mask', coalesce(nullif(r.cutout ->> 'mask', ''), r.cutout ->> 'auto_mask'), 'adjust', coalesce(r.cutout -> 'adjust', '{}'::jsonb),
      'reference', s ->> 'reference_path')));
    update vehicle_marketing_photos set job_id = v_job where id = v_id;
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'No outside photo of this car has a kept cut-out yet: make its listing photos first' using errcode = '23514'; end if;
  return jsonb_build_object('set', v_set, 'queued', n, 'scene', v_scene);
end $$;

-- the newest set of a car, with the scenes to choose from
create function app.marketing_photos(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_vehicle uuid := nullif(p ->> 'vehicle', '')::uuid;
  v_set uuid;
begin
  if not app.marketing_may(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select m.set_id into v_set from vehicle_marketing_photos m where m.vehicle_id = v_vehicle order by m.created_at desc limit 1;
  return jsonb_build_object('vehicle', v_vehicle, 'set', v_set,
    'scenes', coalesce((select jsonb_agg(jsonb_build_object('code', x ->> 'code', 'label', x ->> 'label', 'made', x ->> 'made')) from jsonb_array_elements((app.settings()).marketing_scenes) x), '[]'::jsonb),
    'photos', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'photo_id', m.photo_id, 'scene', m.scene, 'status', m.status, 'path', m.path, 'provider', m.provider,
                          'note', m.note, 'shot', ph.shot_type, 'created_at', m.created_at) order by m.sort)
                         from vehicle_marketing_photos m join vehicle_photos ph on ph.id = m.photo_id where m.set_id = v_set), '[]'::jsonb));
end $$;

-- the worker's answer: the marketing copy made (or why not); nothing on the website changes
alter function app.worker_listing_result(uuid, jsonb) rename to worker_listing_result_pre1053;
create function app.worker_listing_result(p_job uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare j listing_jobs; r jsonb; m jsonb := p #> '{output,marketing}';
begin
  select * into j from listing_jobs where id = p_job;
  r := app.worker_listing_result_pre1053(p_job, p);
  if j.kind = 'marketing_photo' then
    update vehicle_marketing_photos x
       set status = case when not coalesce((p ->> 'ok')::boolean, false) then case when coalesce((p ->> 'retryable')::boolean, true) and (select status from listing_jobs where id = p_job) <> 'failed' then 'queued' else 'failed' end
                         when m ->> 'status' in ('made', 'needs_gemini', 'failed') and (m ->> 'status' <> 'made' or nullif(m ->> 'path', '') is not null) then m ->> 'status' else 'failed' end,
           path = case when m ->> 'status' = 'made' then nullif(m ->> 'path', '') end,
           provider = left(m ->> 'provider', 40), note = left(coalesce(m ->> 'note', case when not coalesce((p ->> 'ok')::boolean, false) then p ->> 'error' end), 300)
     where x.id = coalesce(nullif(m ->> 'id', '')::uuid, nullif(j.input #>> '{marketing,id}', '')::uuid);
  end if;
  return r;
end $$;
select pg_temp.copy_grants('app.worker_listing_result(uuid, jsonb)'::regprocedure, 'app.worker_listing_result_pre1053(uuid, jsonb)'::regprocedure);

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1053;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_do', 'va_do') and p_name = 'marketing_set' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.marketing_set(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  if p_call = 'ops_do' and p_name = 'marketing_scene_reference' then
    perform app.door_begin(p_user, p_aal);
    return app.marketing_scene_reference(p_user, p);
  end if;
  if p_call = 'ops_read' and p_name = 'marketing_scene_refs' then
    perform app.door_begin(p_user, p_aal);
    return app.marketing_scene_refs(p_user);
  end if;
  if p_call in ('ops_read', 'va_read') and p_name = 'marketing_photos' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.marketing_photos(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre1053(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre1053(uuid, text, text, text, jsonb)'::regprocedure);

revoke all on function app.marketing_auto_reference(), app.marketing_scene_path(jsonb) from public, anon, authenticated;
grant execute on function app.marketing_auto_reference(), app.marketing_scene_path(jsonb) to service_role;
revoke all on function app.marketing_reference_path(jsonb), app.marketing_scene_reference(uuid, jsonb), app.marketing_scene_refs(uuid) from public, anon, authenticated;
grant execute on function app.marketing_reference_path(jsonb), app.marketing_scene_reference(uuid, jsonb), app.marketing_scene_refs(uuid) to service_role;
revoke all on function app.marketing_may(uuid), app.marketing_set(uuid, jsonb), app.marketing_photos(uuid, jsonb), app.door_pre1053(uuid, text, text, text, jsonb),
  app.worker_listing_result_pre1053(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.marketing_may(uuid), app.marketing_set(uuid, jsonb), app.marketing_photos(uuid, jsonb), app.door_pre1053(uuid, text, text, text, jsonb),
  app.worker_listing_result_pre1053(uuid, jsonb) to service_role;
