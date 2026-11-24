-- 3700 (release 50, photos): why the live cars still showed the drawn sample photos, and the fixes.
-- The audit (Nov 24, photo_standard over the whole live fleet): no car had a single studio render on the site (r48 done 0,
-- cover_studio 0, ai_angles 0), most cars' covers were the drawn sample of their model, and 18 published cars with real
-- photos had an empty gallery (the car page showed a grey box). Four causes, all in the database:
--   1. A render that never finishes loops for ever. When the worker does not answer within the lock time, the sweep (0024)
--      fails the step through app.fail_listing_job, which 2840 never sees: no try is counted and the photo stays
--      'queued' with no step, so app.photo_r48_queue (2900) queues it again with fresh attempts, and so on. Twelve such
--      steps fill the batch (listing_photo_r45_batch) and nothing else is ever queued. Now that timeout counts as a try
--      (2840's rule: flagged after three, with the reason, on Photo standard), and the batch frees itself.
--   2. A render refused by the check goes to 'redo', and photo_r48_queue reset the tries of a 'redo' row to 0: a view the
--      check always refuses was never flagged either. Now only 'done' and 'flagged' (or Make again) start the tries again.
--   3. A real photo left 'queued' with no step (a step lost or failed) is never due again (2840 photo_r45_due): it is put
--      back to 'redo' by the job.
--   4. Photos filed as "Other detail" (the sorter could not read them, or an import) are never sorted again since 2840
--      removed job_photo_spec (2780's re-sort). A car whose photos are all details has no outside photo, so 2890 showed no
--      gallery at all. Now the job sorts them again (cars with no outside cover first, a few each run); they are the
--      references the studio renders are made from. (What the site shows: 3701, studio renders only.)
-- Also: the connector's photo_standard reports the cover as 'studio' when the listing's cover is a render (3150 made the
-- side profile the cover; the report still looked for the front three-quarter only).
-- Tests: supabase/tests/99_r50ph_photo_loops.sql. SCHEMA_MARKER 3700. No applied migration is edited.
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

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '3700: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. a step that timed out counts as a try
alter function app.fail_listing_job(uuid, text, boolean, text, bigint, timestamptz) rename to fail_listing_job_pre3700;
create function app.fail_listing_job(p_job uuid, p_error text, p_retryable boolean default true, p_provider text default null,
                                     p_cost_microusd bigint default 0, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare j listing_jobs; r jsonb; v_tries integer;
begin
  select * into j from listing_jobs where id = p_job;
  r := app.fail_listing_job_pre3700(p_job, p_error, p_retryable, p_provider, p_cost_microusd, p_now);
  -- only the sweep's timeout (0024): a failure the worker reported goes through worker_listing_result (2840), which counts it
  if j.kind = 'photo_r45' and coalesce(p_error, '') like 'The worker did not finish%'
     and (select x.status from listing_jobs x where x.id = p_job) = 'failed' then
    select coalesce((ph.r45 ->> 'tries')::integer, 0) + 1 into v_tries from vehicle_photos ph where ph.id = j.vehicle_photo_id;
    update vehicle_photos ph set
           r45 = coalesce(ph.r45, '{}'::jsonb) || jsonb_build_object('tries', v_tries, 'at', p_now, 'why', 'the photo step did not finish in time (' || v_tries || ' of 3)',
                   'reasons', '["timed_out"]'::jsonb, 'state', case when v_tries >= 3 then 'flagged' when ph.r48 then 'queued' else 'redo' end),
           quality_flags = case when v_tries >= 3 and not (ph.quality_flags ? 'r45_flagged') then ph.quality_flags || '["r45_flagged"]'::jsonb else ph.quality_flags end,
           -- a generated view that never finished stays off the site; a real photo stays on the site as it was (2890)
           is_public = case when v_tries >= 3 and coalesce(ph.ai_generated, false) then false else ph.is_public end
     where ph.id = j.vehicle_photo_id and ph.replaced_at is null;
  end if;
  return r;
end $$;
select pg_temp.copy_grants('app.fail_listing_job(uuid, text, boolean, text, bigint, timestamptz)'::regprocedure,
                           'app.fail_listing_job_pre3700(uuid, text, boolean, text, bigint, timestamptz)'::regprocedure);
revoke all on function app.fail_listing_job_pre3700(uuid, text, boolean, text, bigint, timestamptz) from public, anon, authenticated;
grant execute on function app.fail_listing_job_pre3700(uuid, text, boolean, text, bigint, timestamptz) to service_role;

-- ================================================================ 2. a refused render keeps its tries
select pg_temp.patch_fn('app.photo_r48_queue(uuid, uuid, text, boolean)'::regprocedure,
  $q$when p_force or coalesce(ph.r45 ->> 'state', '') in ('redo', 'done', 'flagged')$q$,
  $q$when p_force or coalesce(ph.r45 ->> 'state', '') in ('done', 'flagged')$q$);

-- ================================================================ 3 and 4. the job: stranded photos due again, details sorted again
alter function app.job_photo_r48() rename to job_photo_r48_pre3700;
create function app.job_photo_r48() returns text
language plpgsql security definer set search_path = public, app as $$
declare ps program_settings := app.settings(); v_stranded integer := 0; v_sorting integer := 0; r record;
begin
  -- a real photo queued with no step (lost, or failed before 3700) is made again later (photo_r45_due skips 'queued')
  with x as (
    update vehicle_photos ph set r45 = ph.r45 || jsonb_build_object('state', 'redo')
     where ph.replaced_at is null and not ph.r48 and coalesce(ph.r45 ->> 'state', '') = 'queued'
       and coalesce((ph.r45 ->> 'at')::timestamptz, ph.created_at) < now() - interval '1 hour'
       and not exists (select 1 from listing_jobs j where j.vehicle_photo_id = ph.id and j.kind in ('photo_r45', 'process_photo') and j.status in ('queued', 'running'))
    returning 1)
  select count(*) into v_stranded from x;
  -- detail photos sorted again by the vision model: the published cars with no outside cover first (a few each run)
  if coalesce(ps.listing_photo_r48_auto, true) and coalesce(ps.listing_showroom_ai, false) then
    for r in select ph.id from vehicle_photos ph join vehicles v on v.id = ph.vehicle_id
              where ph.shot_type = 'other' and ph.replaced_at is null and ph.status <> 'rejected' and not coalesce(v.is_sample, false)
                and v.retired_at is null and nullif(ph.original_path, '') is not null
                and coalesce(ph.resort ->> 'spec', '') <> app.photo_spec()
              order by (app.cover_photo(ph.vehicle_id)).id is null desc,
                       exists (select 1 from vehicle_listings l where l.vehicle_id = ph.vehicle_id and l.status = 'published') desc,
                       ph.vehicle_id, ph.sort_order, ph.created_at
              limit 8 loop
      if app.photo_resort_queue(null, r.id) then v_sorting := v_sorting + 1; end if;
    end loop;
  end if;
  return app.job_photo_r48_pre3700()
      || case when v_sorting > 0 then format('; %s detail photo(s) sorted again', v_sorting) else '' end
      || case when v_stranded > 0 then format('; %s stranded photo(s) due again', v_stranded) else '' end;
end $$;
select pg_temp.copy_grants('app.job_photo_r48()'::regprocedure, 'app.job_photo_r48_pre3700()'::regprocedure);
revoke all on function app.job_photo_r48_pre3700() from public, anon, authenticated;
grant execute on function app.job_photo_r48_pre3700() to service_role;

-- ================================================================ 5. the connector: a rendered cover is a studio cover
alter function app.photo_standard_car(uuid) rename to photo_standard_car_pre3700;
create function app.photo_standard_car(p_vehicle uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare x jsonb := app.photo_standard_car_pre3700(p_vehicle); rw jsonb;
begin
  if x is null then return null; end if;
  rw := app.public_listing_row_live(p_vehicle);
  return x || jsonb_build_object(
    'cover', case when coalesce((rw #>> '{cover,generated}')::boolean, false) then 'studio' else x ->> 'cover' end,
    'resorting', (select count(*) from vehicle_photos ph where ph.vehicle_id = p_vehicle and ph.shot_type = 'other' and ph.replaced_at is null
                    and ph.status <> 'rejected' and ph.resort ->> 'decision' = 'queued'),
    'details_unsorted', (select count(*) from vehicle_photos ph where ph.vehicle_id = p_vehicle and ph.shot_type = 'other' and ph.replaced_at is null
                           and ph.status <> 'rejected'));
end $$;
select pg_temp.copy_grants('app.photo_standard_car(uuid)'::regprocedure, 'app.photo_standard_car_pre3700(uuid)'::regprocedure);
revoke all on function app.photo_standard_car_pre3700(uuid) from public, anon, authenticated;
grant execute on function app.photo_standard_car_pre3700(uuid) to service_role;

-- ================================================================ once: the listing cache holds the new galleries (published cars)
-- (the renders stuck in the loop need nothing here: from now on each timeout counts, and the job queues them again)
do $$
begin
  perform app.listing_cache_refresh(array(select l.vehicle_id from vehicle_listings l join vehicles v on v.id = l.vehicle_id
                                           where l.status = 'published' and not coalesce(v.is_sample, false)));
exception when undefined_function then null;
end $$;
