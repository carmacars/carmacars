-- 0660_studio_framing_plates.sql
-- Release 31 (docs/changes/2026-11-07-studio-framing-plates.md), two bugs seen on the four Mercedes listings:
--   1. Framing: the worker's new preset studio_v4 (web/src/features/listing/subject-frame.ts) finds the car at a firm
--      alpha, so the segmenter's haze and the floor's reflection no longer make the car a quarter of the width, floating
--      above the floor; no model name is lettered behind a real car. Photos made before are framed again only when staff
--      ask: Listings > a listing > Photos > "Frame the outside photos again" (app.listing_photos_reframe below).
--   2. Plate box: the suggestion was asked on the photo as it was while the photo was being made again (its file keeps
--      its name, so the review still showed and sent the old framing), and kept when the new photo landed: the box then
--      sat beside the plate. Now a suggestion is not stored while the photo is being made, a new outside photo clears the
--      suggestion it had, and the suggestions older than their photo are cleared here once (asked again when the review
--      opens).

do $$ begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname = 'worker_listing_result_pre0660') then
    alter function app.worker_listing_result(uuid, jsonb) rename to worker_listing_result_pre0660;
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname = 'door_pre0660') then
    alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0660;
  end if;
end $$;

-- ================================================================ 2. a new outside photo drops the suggestion made on the old one
create or replace function app.worker_listing_result(p_job uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare j listing_jobs; r jsonb;
begin
  select * into j from listing_jobs where id = p_job;
  r := app.worker_listing_result_pre0660(p_job, p);
  if j.kind = 'process_photo' and j.vehicle_photo_id is not null and coalesce((p ->> 'ok')::boolean, false)
     and coalesce(p -> 'output' ->> 'preset_version', '') like 'studio%' then
    update vehicle_photos set plate_suggestion = null,
           plate_boxes = case when plate_status = 'unchecked' then '[]'::jsonb else plate_boxes end
     where id = j.vehicle_photo_id;
  end if;
  return r;
end $$;

-- no suggestion is kept while the photo is being made again: it would be on the photo as it was
create or replace function app.photo_plate_suggestion(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet', 'cs')) then
    raise exception 'Fleet, customer service or an Admin edits listing photos' using errcode = '42501';
  end if;
  if exists (select 1 from listing_jobs j where j.vehicle_photo_id = (p ->> 'photo')::uuid and j.kind = 'process_photo' and j.status in ('queued', 'running')) then
    return jsonb_build_object('ok', true, 'stored', false, 'reason', 'The photo is being made again');
  end if;
  update vehicle_photos set plate_suggestion = p -> 'suggestion' where id = (p ->> 'photo')::uuid;
  return jsonb_build_object('ok', true, 'stored', true);
end $$;

-- the suggestions already kept that are older than their photo (asked on the photo as it was), once
update vehicle_photos ph set plate_suggestion = null
 where ph.plate_status = 'unchecked' and ph.plate_suggestion is not null
   and exists (select 1 from listing_jobs j where j.vehicle_photo_id = ph.id and j.kind = 'process_photo' and j.status = 'succeeded'
                  and j.finished_at > coalesce(case when ph.plate_suggestion ->> 'at' ~ '^\d{4}-\d{2}-\d{2}T' then (ph.plate_suggestion ->> 'at')::timestamptz end, '-infinity'::timestamptz));

-- ================================================================ 1. a listing's outside photos framed again, when staff ask
-- Every outside photo of the car not framed with p.preset (default studio_v4; p.all: every one) is made again: off the
-- site until approved again, its plate checked again on the new file (the old boxes and suggestion do not fit it).
create or replace function app.listing_photos_reframe(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_vehicle uuid; v_preset text := coalesce(nullif(p ->> 'preset', ''), 'studio_v4'); v_all boolean := coalesce((p ->> 'all')::boolean, false);
        r record; n integer := 0;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet', 'cs')) then
    raise exception 'Fleet, customer service or an Admin edits listing photos' using errcode = '42501';
  end if;
  v_vehicle := coalesce((p ->> 'vehicle')::uuid, (select i.vehicle_id from listing_intakes i where i.id = (p ->> 'intake')::uuid));
  if v_vehicle is null then raise exception 'Unknown listing' using errcode = 'P0002'; end if;
  for r in
    select ph.id, ph.intake_id from vehicle_photos ph join listing_shot_types s on s.code = ph.shot_type
     where ph.vehicle_id = v_vehicle and ph.replaced_at is null and ph.status <> 'rejected' and ph.intake_id is not null
       and s.rebackground and s.is_public and (v_all or coalesce(ph.preset_version, '') <> v_preset)
       and not exists (select 1 from listing_jobs j where j.vehicle_photo_id = ph.id and j.kind = 'process_photo' and j.status in ('queued', 'running'))
  loop
    update vehicle_photos set background_status = 'pending', is_public = false, plate_status = 'unchecked', plate_boxes = '[]'::jsonb,
           plate_suggestion = null, uncovered_path = null
     where id = r.id;
    perform app.enqueue_listing_job(r.intake_id, 'process_photo', r.id);
    n := n + 1;
  end loop;
  return jsonb_build_object('vehicle', v_vehicle, 'queued', n);
end $$;

create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'ops_do' and p_name = 'listing_photos_reframe' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.listing_photos_reframe(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre0660(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ privileges
do $$
declare g text;
begin
  execute 'revoke all on function app.door(uuid, text, text, text, jsonb) from public, anon, authenticated';
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.door_pre0660(uuid, text, text, text, jsonb)', 'execute') then
      execute format('grant execute on function app.door(uuid, text, text, text, jsonb) to %I', g);
    end if;
  end loop;
end $$;
revoke all on function app.listing_photos_reframe(uuid, jsonb), app.photo_plate_suggestion(uuid, jsonb), app.worker_listing_result(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.listing_photos_reframe(uuid, jsonb), app.photo_plate_suggestion(uuid, jsonb), app.worker_listing_result(uuid, jsonb) to service_role;
