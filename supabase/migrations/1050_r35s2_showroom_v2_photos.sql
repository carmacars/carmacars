-- 1050_r35s2_showroom_v2_photos.sql
-- Release 35, part S2 (docs/changes/2026-11-08-r35-showroom-v2-shift-jobs.md): the showroom made to look like a real dark
-- dealership, and listing photos that no longer depend on Cloudflare Image Transformations. No applied migration is edited.
--   1. The showroom's preset is studio_showroom_v2 (web/src/features/listing/showroom.ts): "Apply showroom" (one car or every
--      car) and Frame again make the photos still on v1 again. The image model's daily limit default is 100 (was 25); the
--      hour's back-off after a quota answer and the hard stop at the limit stay (0990's gate).
--   2. Program settings listing_cf_transformations (off): the photo steps are made locally by the worker (resize, framing,
--      interiors, touch-up, sizes); Cloudflare is asked only for the cut-out and a HEIC photo, or for everything when this is
--      on (any quota or outage answer falls back to the local steps). public.server_listing_image_mode tells the worker.
--   3. Failed photos are made again: listing_jobs.retry_queued_at marks a failed photo job for the retry job
--      (app.job_photo_retry, every 10 minutes, oldest first, 6 a run); the intake leaves Failed once none of its photo jobs is
--      failed. ops_do photo_retry_failed {intake | all} (Admin or Fleet) marks them: "Retry failed photos" on Admin > Listings.
--      Every photo job failed now is marked once, here.
--   4. The cut-out editor's context names the photo's scene (the showroom is edited on the showroom, where it places the car).
-- SCHEMA_MARKER 1053 (with 1051 to 1053).
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

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text, p_times integer) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if (length(d) - length(replace(d, p_old, ''))) / length(p_old) <> p_times then raise exception '1050: the text to change was not found % times in %', p_times, p_sig; end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the showroom v2
select pg_temp.patch_fn('app.listing_photos_reframe(uuid, jsonb)'::regprocedure, '''studio_showroom_v1''', '''studio_showroom_v2''', 1);
select pg_temp.patch_fn('app.photo_showroom(uuid, jsonb)'::regprocedure, '''studio_showroom_v1''', '''studio_showroom_v2''', 1);

alter table program_settings alter column listing_showroom_ai_daily set default 100;
update program_settings set listing_showroom_ai_daily = 100 where listing_showroom_ai_daily = 25;
comment on column program_settings.listing_showroom_ai_daily is 'Showroom photos: at most this many image model calls a Toronto day (a hard stop; then the free showroom is used; 100 by default since 1050). 0 never asks it.';

-- ================================================================ 2. local photo steps
alter table program_settings add column if not exists listing_cf_transformations boolean not null default false;
comment on column program_settings.listing_cf_transformations is 'Listing photos (1050): off, the photo steps are made by the site itself and Cloudflare Image Transformations are asked only for the cut-out (and a HEIC photo); on, Cloudflare makes every step (a quota or outage answer still falls back to the site''s own).';

create function public.server_listing_image_mode() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('cf_transformations', coalesce((app.settings()).listing_cf_transformations, false))
$$;

-- ================================================================ 3. failed photos made again
alter table listing_jobs add column if not exists retry_queued_at timestamptz;
comment on column listing_jobs.retry_queued_at is 'A failed photo job marked to be made again by the retry job (1050: app.job_photo_retry); cleared when it is queued.';
create index if not exists listing_jobs_retry_queued on listing_jobs (created_at) where retry_queued_at is not null;

create function app.photo_retry_queue(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_all boolean := coalesce((p ->> 'all')::boolean, false); v_intake uuid := nullif(p ->> 'intake', '')::uuid; n integer;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet')) then
    raise exception 'An Admin or Fleet retries failed photos' using errcode = '42501';
  end if;
  if not v_all and (v_intake is null or not exists (select 1 from listing_intakes i where i.id = v_intake)) then
    raise exception 'Unknown listing' using errcode = 'P0002';
  end if;
  update listing_jobs set retry_queued_at = now()
   where status = 'failed' and kind in ('process_photo', 'resize') and retry_queued_at is null and (v_all or intake_id = v_intake);
  get diagnostics n = row_count;
  return jsonb_build_object('queued', n, 'intake', v_intake, 'all', v_all);
end $$;

-- a few each run, oldest first: each back in the queue with fresh attempts; the intake leaves Failed when none is failed
create function app.job_photo_retry(p_now timestamptz default now(), p_limit integer default 6) returns text
language plpgsql security definer set search_path = public, app as $$
declare j listing_jobs; n integer := 0; v_back integer := 0;
begin
  update listing_jobs set retry_queued_at = null where retry_queued_at is not null and status <> 'failed';
  for j in select * from listing_jobs x where x.retry_queued_at is not null and x.status = 'failed' order by x.created_at, x.id limit greatest(p_limit, 1) for update skip locked loop
    if exists (select 1 from listing_jobs x where x.intake_id = j.intake_id and x.kind = j.kind and x.vehicle_photo_id is not distinct from j.vehicle_photo_id
                 and x.status in ('queued', 'running')) then
      -- the photo is being made again already
      update listing_jobs set retry_queued_at = null where id = j.id;
    elsif exists (select 1 from listing_jobs x where x.intake_id = j.intake_id and x.kind = j.kind and x.vehicle_photo_id is not distinct from j.vehicle_photo_id
                    and x.status = 'succeeded' and x.created_at > j.created_at) then
      -- made since by a newer job: this one no longer holds the listing in Failed
      update listing_jobs set status = 'cancelled', retry_queued_at = null, error = left(coalesce(error, '') || ' (made since by a newer job)', 500) where id = j.id;
    else
      update listing_jobs set status = 'queued', attempts = 0, next_attempt_at = p_now, error = null, finished_at = null, locked_at = null, retry_queued_at = null where id = j.id;
      update photo_jobs set status = 'queued', attempts = 0, next_attempt_at = p_now, error = null, finished_at = null where id = j.photo_job_id;
      if j.kind = 'process_photo' then
        update vehicle_photos set background_status = 'pending' where id = j.vehicle_photo_id and background_status = 'failed';
      end if;
      n := n + 1;
    end if;
    if not exists (select 1 from listing_jobs x where x.intake_id = j.intake_id and x.status = 'failed' and x.kind in ('process_photo', 'resize', 'publish')) then
      update listing_intakes set retries = retries + 1, reason = null, failed_at = null, state = 'processing_photos' where id = j.intake_id and state = 'failed';
      if found then v_back := v_back + 1; perform app.advance_listing_intake(j.intake_id); end if;
    end if;
  end loop;
  return format('%s failed photo(s) queued again, %s listing(s) out of Failed', n, v_back);
end $$;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-photo-retry', '*/10 * * * *', 'select app.job_photo_retry()');
  end if;
end $$;

-- every photo job failed now (the quota of the image service on Nov 8): marked once for the retry job
update listing_jobs set retry_queued_at = now() where status = 'failed' and kind in ('process_photo', 'resize') and retry_queued_at is null;

-- ================================================================ 4. the cut-out editor knows the scene
alter function app.photo_cutout_context(uuid, jsonb) rename to photo_cutout_context_pre1050;
create function app.photo_cutout_context(p_by uuid, p jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.photo_cutout_context_pre1050(p_by, p) || jsonb_build_object('scene', coalesce((select ph.scene from vehicle_photos ph where ph.id = (p ->> 'photo')::uuid), 'studio'))
$$;
select pg_temp.copy_grants('app.photo_cutout_context(uuid, jsonb)'::regprocedure, 'app.photo_cutout_context_pre1050(uuid, jsonb)'::regprocedure);

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1050;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_do', 'va_do') and p_name = 'photo_retry_failed' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.photo_retry_queue(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre1050(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre1050(uuid, text, text, text, jsonb)'::regprocedure);

revoke all on function app.photo_retry_queue(uuid, jsonb), app.job_photo_retry(timestamptz, integer), app.door_pre1050(uuid, text, text, text, jsonb),
  app.photo_cutout_context_pre1050(uuid, jsonb), public.server_listing_image_mode() from public, anon, authenticated;
grant execute on function app.photo_retry_queue(uuid, jsonb), app.job_photo_retry(timestamptz, integer), app.door_pre1050(uuid, text, text, text, jsonb),
  app.photo_cutout_context_pre1050(uuid, jsonb), public.server_listing_image_mode() to service_role;
