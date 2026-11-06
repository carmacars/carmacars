-- 0568_listing_photo_enhance.sql
-- Release 28 (docs/changes/2026-11-06-r28-platform.md, B9): a light automatic touch-up on every listing photo, on by
-- default (web/src/features/listing/enhance.ts works out the values per photo; Cloudflare applies them last).
--   1. program_settings.listing_photo_enhance (Admin > Settings > Listings, "Auto-enhance listing photos"), on.
--   2. vehicle_photos.enhance (the values used, or null: not touched up) and enhance_off (the photo's "Use original
--      colours" in the listing review). The uploaded original is always kept in the private originals as before.
--   3. The job's context says photo.enhance (the setting on and the photo not switched off); the result stores the values.
--   4. ops_do photo_enhance_set {photo, off}: who edits listing photos (an Admin, fleet, customer service) switches a photo's
--      touch-up; the photo is processed again (off the site until approved again, its plate checked again when outside).
-- The photos 0567 queued (the four Mercedes listings) are claimed after this, so they are touched up as well.

alter table program_settings add column if not exists listing_photo_enhance boolean not null default true;
comment on column program_settings.listing_photo_enhance is 'Auto-enhance listing photos: a light touch-up (exposure, levels, a little contrast and saturation, mild sharpening) on every photo the listing worker makes (0568). Never a colour shift or smoothing.';
alter table vehicle_photos
  add column if not exists enhance jsonb,
  add column if not exists enhance_off boolean not null default false;
comment on column vehicle_photos.enhance is 'The touch-up values the listing worker applied (0568, enhance.ts: brightness, contrast, gamma, saturation, sharpen); null: none.';
comment on column vehicle_photos.enhance_off is 'Use original colours: this photo is made without the touch-up (0568).';

do $$ begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname = 'listing_job_context_pre0568') then
    alter function app.listing_job_context(uuid) rename to listing_job_context_pre0568;
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname = 'worker_listing_result_pre0568') then
    alter function app.worker_listing_result(uuid, jsonb) rename to worker_listing_result_pre0568;
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname = 'door_pre0568') then
    alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0568;
  end if;
end $$;

create or replace function app.listing_job_context(p_job uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when x -> 'photo' is null or jsonb_typeof(x -> 'photo') <> 'object' then x
              else jsonb_set(x, '{photo,enhance}', to_jsonb(coalesce((app.settings()).listing_photo_enhance, true)
                     and not coalesce((select ph.enhance_off from vehicle_photos ph where ph.id = (x -> 'photo' ->> 'id')::uuid), false))) end
    from (select app.listing_job_context_pre0568(p_job) x) q
$$;

create or replace function app.worker_listing_result(p_job uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare j listing_jobs; r jsonb;
begin
  select * into j from listing_jobs where id = p_job;
  r := app.worker_listing_result_pre0568(p_job, p);
  if j.kind = 'process_photo' and j.vehicle_photo_id is not null and coalesce((p ->> 'ok')::boolean, false) then
    update vehicle_photos set enhance = case when jsonb_typeof(p -> 'output' -> 'enhance') = 'object' then p -> 'output' -> 'enhance' end
     where id = j.vehicle_photo_id;
  end if;
  return r;
end $$;

-- ================================================================ 4. a photo's touch-up switched in the listing review
create or replace function app.photo_enhance_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare ph vehicle_photos; s listing_shot_types; v_off boolean := coalesce((p ->> 'off')::boolean, false);
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet', 'cs')) then
    raise exception 'Fleet, customer service or an Admin edits listing photos' using errcode = '42501';
  end if;
  select * into ph from vehicle_photos where id = (p ->> 'photo')::uuid for update;
  if ph.id is null or ph.replaced_at is not null then raise exception 'That photo is not current' using errcode = 'P0002'; end if;
  if ph.enhance_off = v_off then return jsonb_build_object('photo', ph.id, 'enhance_off', v_off, 'queued', false); end if;
  select * into s from listing_shot_types where code = ph.shot_type;
  update vehicle_photos set enhance_off = v_off where id = ph.id;
  if ph.intake_id is null or not coalesce(s.is_public, false) then
    return jsonb_build_object('photo', ph.id, 'enhance_off', v_off, 'queued', false);
  end if;
  -- made again: off the site until approved again; an outside photo's plate is checked again on the new file
  update vehicle_photos set is_public = false,
         background_status = case when s.rebackground then 'pending' else background_status end,
         plate_status = case when s.rebackground then 'unchecked' else plate_status end,
         plate_boxes = case when s.rebackground then '[]'::jsonb else plate_boxes end,
         plate_suggestion = case when s.rebackground then null else plate_suggestion end,
         uncovered_path = case when s.rebackground then null else uncovered_path end
   where id = ph.id;
  perform app.enqueue_listing_job(ph.intake_id, 'process_photo', ph.id);
  return jsonb_build_object('photo', ph.id, 'enhance_off', v_off, 'queued', true);
end $$;

create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'ops_do' and p_name = 'photo_enhance_set' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.photo_enhance_set(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre0568(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ privileges
do $$
declare g text;
begin
  execute 'revoke all on function app.door(uuid, text, text, text, jsonb) from public, anon, authenticated';
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.door_pre0568(uuid, text, text, text, jsonb)', 'execute') then
      execute format('grant execute on function app.door(uuid, text, text, text, jsonb) to %I', g);
    end if;
  end loop;
end $$;
revoke all on function app.photo_enhance_set(uuid, jsonb), app.listing_job_context(uuid), app.worker_listing_result(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.photo_enhance_set(uuid, jsonb), app.listing_job_context(uuid), app.worker_listing_result(uuid, jsonb) to service_role;
