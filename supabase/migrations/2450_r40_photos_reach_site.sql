-- 2450_r40_photos_reach_site.sql (release 40)
-- Owner, Nov 12: "not a single car has real photos yet". About 20 listings imported from Google Drive stood at "Processing
-- photos" for 15 hours and more, and the published ones still showed the sample photos. The reasons, and what changes:
--   1. The worker's job context (app.listing_job_context) had become seven SQL wrappers of the form
--      "select case when x ... then x else jsonb_set(x, ...) end from (select inner(p_job) x) q": Postgres inlines the
--      subquery, so every mention of x ran the inner wrapper again (3 to 4 times a layer, the trap 0099 fixed for the public
--      pages). 2400 added the seventh layer: one job's context took over 20 seconds, so a claim of four jobs outlasted the
--      worker's run (the cron's /api/jobs/listing, the e2e test's 90 seconds). Now one PL/pgSQL function that reads the base
--      context once and adds each layer's fields (0073 model, 0567 watermark, 0568 enhance, 0700 cover and file name,
--      0990 scene, 2400 room and cut-out settings), with the same answer.
--      The site's own wrappers of 2100 (public_listing_photos_pre2200, public_listing_row) had the same form: written once.
--   2. The day's photo budget (0032's claim) held every photo step, also the ones made in the Worker for nothing: the sizes
--      (resize: local since r35 unless Program settings listing_cf_transformations) and the steps queued again with
--      local_only by "Process photos without the resize service" (2372). Those are claimed whatever the budget. A job whose
--      worker stopped and that has used its attempts is no longer claimed again (the sweep, 0024, fails it).
--   3. A photo finished after its listing went live (published by Publish now or automatically, 0070, while the import was
--      still running) stayed "processed": only the intake's own approval (0022) marks photos approved, and an intake that is
--      published is never advanced again. The site reads approved photos only, so it showed the samples. Now a processed
--      photo of a live listing whose intake was approved or published is approved when it is finished
--      (app.listing_photos_approve_live); an intake still running approves its photos itself when its last step is done. The rules that keep a photo private stay: an unchecked plate (0070, 0661) and a flagged watermark (0566);
--      such a photo goes on the site by itself once its plate is covered or marked "no plate visible".
--   4. "Process photos without the resize service" (2372) left out published listings and steps waiting in the queue (held
--      by the budget): now every listing not cancelled, every failed, waiting or stopped photo step of a current photo.
--   5. The car's cover on the site: the photo marked cover (the front-left shot) when it is public, else the first approved
--      public photo (app.cover_photo, 2100), so a car whose photos were all filed "Other detail" (the sorter could not see
--      them, see web/src/server/drive-import.ts) or whose front-left plate is not checked yet still has a real cover.
--   6. The listing review's photo problems (app.listing_photo_problems, advisory since 0070) no longer name the 14 shots one
--      by one (0566 made no named shot required) and say "No cover photo" only when the car has no approved public photo.
--   7. Once, here: every stuck photo step queued again (as 4), the processed photos of live listings approved (as 3), and
--      the intakes moved on.
-- No applied migration is edited.
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

-- ================================================================ 1. the job context, read once
alter function app.listing_job_context(uuid) rename to listing_job_context_pre2450;
create function app.listing_job_context(p_job uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.listing_job_context_pre0073(p_job);
  ph vehicle_photos;
  s program_settings := app.settings();
begin
  if x is null or jsonb_typeof(x) <> 'object' then return x; end if;
  if jsonb_typeof(x -> 'photo') = 'object' then
    select * into ph from vehicle_photos where id = (x -> 'photo' ->> 'id')::uuid;
    x := jsonb_set(x, '{photo}', (x -> 'photo') || jsonb_build_object(
      'model', (select v.model from vehicles v where v.id = (x ->> 'vehicle_id')::uuid),                          -- 0073
      'watermark', coalesce(ph.quality_flags ? 'watermark', false),                                               -- 0567
      'enhance', coalesce(s.listing_photo_enhance, true) and not coalesce(ph.enhance_off, false),                 -- 0568
      'is_cover', coalesce(ph.is_cover, false),                                                                   -- 0700
      'file_base', (x -> 'photo' ->> 'file_base') || case when coalesce(ph.edit_version, 0) > 0 then '-v' || ph.edit_version else '' end,
      'scene', coalesce(ph.scene, 'studio')));                                                                    -- 0990
  end if;
  return x || jsonb_build_object(                                                                                -- 2400
    'background', app.showroom_background_for(nullif(x ->> 'vehicle_id', '')::uuid),
    'cutout', jsonb_build_object('car_width', s.listing_showroom_car_width, 'min_quality', s.listing_cutout_min_quality));
end $$;
select pg_temp.copy_grants('app.listing_job_context(uuid)'::regprocedure, 'app.listing_job_context_pre2450(uuid)'::regprocedure);

-- the site's covers (2100's wrapper, named public_listing_photos_pre2200 since 2200): the wrapped function once
create or replace function app.public_listing_photos_pre2200(p_vehicle uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  ph jsonb := app.public_listing_photos_pre2100(p_vehicle);
  c record;
begin
  select * into c from app.listing_cover_shown(p_vehicle) s where s.id is not null;
  if c.id is null then return ph; end if;
  return jsonb_build_array(jsonb_build_object('path', c.path, 'variants', '[]'::jsonb, 'width', c.width, 'height', c.height, 'shot', 'cover_' || c.style,
           'label', case c.style when 'model' then 'Cover' else 'Offer' end, 'is_cover', true,
           'alt', coalesce((ph -> 0 ->> 'alt'), app.vehicle_name(p_vehicle))))
      -- the plain cover stays in the gallery, right after the made one
      || coalesce((select jsonb_agg(e || jsonb_build_object('is_cover', false)) from jsonb_array_elements(ph) with ordinality t(e, k) where k = 1 and coalesce((e ->> 'is_cover')::boolean, false)), '[]'::jsonb)
      || coalesce((select jsonb_agg(e order by k) from jsonb_array_elements(ph) with ordinality t(e, k) where k > 1 or not coalesce((e ->> 'is_cover')::boolean, false)), '[]'::jsonb);
end $$;

-- 5: the cover fallback is part of the live row (app.public_listing_row_live), so the listing cache (0102) holds it and
-- the fleet, the car page and the cache all give the same row; the cache refreshes on every vehicle_photos change.
alter function app.public_listing_row_live(uuid) rename to public_listing_row_live_pre2450;
create function app.public_listing_row_live(p_vehicle uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  r jsonb := app.public_listing_row_live_pre2450(p_vehicle);
  ph vehicle_photos;
begin
  if r is null then return null; end if;
  -- no public cover photo while the car has an approved public photo: that photo is the cover, not a sample
  if coalesce((r ->> 'sample_photos')::boolean, false) then
    ph := app.cover_photo(p_vehicle);
    if ph.id is not null then
      r := r || jsonb_build_object('cover', jsonb_build_object('path', ph.processed_path, 'variants', ph.variants, 'alt', coalesce(ph.alt_text, app.vehicle_name(p_vehicle))),
                                   'sample_photos', false);
    end if;
  end if;
  return r;
end $$;
select pg_temp.copy_grants('app.public_listing_row_live(uuid)'::regprocedure, 'app.public_listing_row_live_pre2450(uuid)'::regprocedure);

alter function app.public_listing_row(uuid) rename to public_listing_row_pre2450;
create function app.public_listing_row(p_vehicle uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  r jsonb := app.public_listing_row_pre2100(p_vehicle);
  c record;
begin
  if r is null then return null; end if;
  -- 2100: a made cover (with a model, or the flyer) first when the listing's style asks for one and it is current
  select * into c from app.listing_cover_shown(p_vehicle) s where s.id is not null;
  if c.id is not null then
    r := r || jsonb_build_object('cover', jsonb_build_object('path', c.path, 'variants', '[]'::jsonb, 'alt', coalesce(r #>> '{cover,alt}', app.vehicle_name(p_vehicle))));
  end if;
  return r;
end $$;
select pg_temp.copy_grants('app.public_listing_row(uuid)'::regprocedure, 'app.public_listing_row_pre2450(uuid)'::regprocedure);

-- ================================================================ 2. the claim: local photo work is never held by the budget
alter function app.worker_claim_listing_jobs(text, integer, timestamptz) rename to worker_claim_listing_jobs_pre2450;
create function app.worker_claim_listing_jobs(p_worker text, p_limit integer default 4, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  bud jsonb := app.listing_budget(p_now);
  v_photo_ok boolean := (bud ->> 'photo_spent_microusd')::bigint < ps.photo_daily_budget_microusd;
  v_ai_ok boolean := (bud ->> 'ai_neurons_today')::numeric < ps.listing_ai_daily_neurons;
  v_cf boolean := coalesce(ps.listing_cf_transformations, false);
  j listing_jobs;
  v_out jsonb := '[]'::jsonb;
begin
  for j in
    select * from listing_jobs x
     where ((x.status = 'queued' and x.next_attempt_at <= p_now)
            or (x.status = 'running' and x.locked_at < p_now - make_interval(mins => ps.listing_job_lock_minutes) and x.attempts < x.max_attempts))
       and (x.kind not in ('process_photo', 'resize') or v_photo_ok
            or coalesce((x.input ->> 'local_only')::boolean, false) or (x.kind = 'resize' and not v_cf))
       and (x.kind <> 'draft_copy' or (v_ai_ok and not exists (
             select 1 from listing_jobs d where d.intake_id = x.intake_id and d.kind = 'decode_vin' and d.status in ('queued', 'running'))))
     order by case x.kind when 'decode_vin' then 0 when 'draft_copy' then 1 when 'process_photo' then 2 else 3 end, x.next_attempt_at, x.created_at
     limit greatest(coalesce(p_limit, 1), 1)
     for update skip locked
  loop
    update listing_jobs set status = 'running', locked_at = p_now, locked_by = p_worker, attempts = attempts + 1,
           started_at = coalesce(started_at, p_now)
     where id = j.id returning * into j;
    if j.photo_job_id is not null then
      update photo_jobs set status = 'processing', started_at = coalesce(started_at, p_now), attempts = j.attempts where id = j.photo_job_id;
      update vehicle_photos set status = 'processing',
             background_status = case when background_status = 'pending' then 'processing' else background_status end
       where id = j.vehicle_photo_id and status = 'uploaded';
    end if;
    v_out := v_out || jsonb_build_array(app.listing_job_context(j.id));
  end loop;
  return jsonb_build_object('jobs', v_out, 'budget', bud,
    'held', jsonb_build_object('photos', not v_photo_ok, 'copy', not v_ai_ok),
    'due', (select count(*) from listing_jobs where status = 'queued' and next_attempt_at <= p_now));
end $$;
select pg_temp.copy_grants('app.worker_claim_listing_jobs(text, integer, timestamptz)'::regprocedure, 'app.worker_claim_listing_jobs_pre2450(text, integer, timestamptz)'::regprocedure);

-- ================================================================ 3. a live listing's finished photos are approved
-- The processed current photos of a car whose listing is published or paused, from an intake that was approved or
-- published (an intake still running approves its photos itself when it finishes, 0022; one waiting for a review, the
-- reviewer): approved, public as their shot allows. The plate rule (0070, 0661) and the
-- watermark guard (0566) are triggers: a photo whose plate is not checked or that shows a mark stays private.
create function app.listing_photos_approve_live(p_vehicle uuid) returns integer
language plpgsql security definer set search_path = public, app as $$
declare n integer;
begin
  if not exists (select 1 from vehicle_listings l where l.vehicle_id = p_vehicle and l.status in ('published', 'paused')) then return 0; end if;
  update vehicle_photos ph set status = 'approved',
         approved_by = coalesce(ph.approved_by, (select i.started_by from listing_intakes i where i.id = ph.intake_id)),
         approved_at = coalesce(ph.approved_at, now()), is_public = st.is_public,
         alt_text = coalesce(ph.alt_text, app.photo_alt_text(ph.vehicle_id, ph.shot_type))
    from listing_shot_types st
   where st.code = ph.shot_type and ph.vehicle_id = p_vehicle and ph.replaced_at is null
     and ph.status = 'processed' and ph.processed_path is not null
     and exists (select 1 from listing_intakes i where i.id = ph.intake_id and i.state in ('approved', 'published'));
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function app.listing_photos_approve_live(uuid) from public, anon, authenticated;
grant execute on function app.listing_photos_approve_live(uuid) to service_role;

alter function app.worker_listing_result(uuid, jsonb) rename to worker_listing_result_pre2450;
create function app.worker_listing_result(p_job uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare j listing_jobs; r jsonb;
begin
  select * into j from listing_jobs where id = p_job;
  r := app.worker_listing_result_pre2450(p_job, p);
  if j.kind in ('process_photo', 'resize') and coalesce((p ->> 'ok')::boolean, false) then
    perform app.listing_photos_approve_live(j.vehicle_id);
  end if;
  return r;
end $$;
select pg_temp.copy_grants('app.worker_listing_result(uuid, jsonb)'::regprocedure, 'app.worker_listing_result_pre2450(uuid, jsonb)'::regprocedure);

-- ================================================================ 4. every stuck photo step queued again, made here
-- One step per photo and kind (listing_jobs_one_open): a waiting one first, else the newest failed or stopped one; never a
-- step of a photo replaced since, nor one a later step of the same photo did already, nor one a worker runs now.
create function app.listing_photos_requeue_local(p_vehicle uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_jobs integer := 0; v_intakes integer := 0; v_zero constant uuid := '00000000-0000-0000-0000-000000000000';
begin
  with cand as (
    select distinct on (j.intake_id, j.kind, coalesce(j.vehicle_photo_id, v_zero)) j.id
      from listing_jobs j join listing_intakes i on i.id = j.intake_id
      left join vehicle_photos ph on ph.id = j.vehicle_photo_id
     where j.kind in ('process_photo', 'resize') and i.state <> 'cancelled' and (p_vehicle is null or i.vehicle_id = p_vehicle)
       and (j.vehicle_photo_id is null or (ph.id is not null and ph.replaced_at is null and ph.status <> 'rejected'))
       and (j.status in ('failed', 'queued') or (j.status = 'running' and j.locked_at < now() - interval '30 minutes'))
       and not exists (select 1 from listing_jobs o where o.id <> j.id and o.intake_id = j.intake_id and o.kind = j.kind
                         and coalesce(o.vehicle_photo_id, v_zero) = coalesce(j.vehicle_photo_id, v_zero)
                         and ((o.status = 'running' and o.locked_at >= now() - interval '30 minutes')
                              or (o.status = 'succeeded' and o.created_at > j.created_at)))
     order by j.intake_id, j.kind, coalesce(j.vehicle_photo_id, v_zero), (j.status <> 'failed') desc, j.created_at desc, j.id desc
  ), picked as (
    select j.id from listing_jobs j where j.id in (select id from cand) for update of j
  ), upd as (
    update listing_jobs j set status = 'queued', attempts = 0, next_attempt_at = now(), error = null, finished_at = null, locked_at = null, locked_by = null,
           input = coalesce(j.input, '{}'::jsonb) || jsonb_build_object('local_only', true)
      from picked where j.id = picked.id
    returning j.intake_id, j.photo_job_id, j.vehicle_photo_id, j.kind
  ), pj as (
    update photo_jobs p set status = 'queued', attempts = 0, next_attempt_at = now(), error = null, finished_at = null
      from upd where p.id = upd.photo_job_id and p.status in ('failed', 'queued', 'running', 'processing')
    returning p.id
  ), vp as (
    update vehicle_photos v set background_status = 'pending', status = case when v.status = 'processing' then 'uploaded' else v.status end
      from upd where v.id = upd.vehicle_photo_id and upd.kind = 'process_photo' and (v.background_status in ('failed', 'processing') or v.status = 'processing')
    returning v.id
  ), it as (
    update listing_intakes i set state = 'processing_photos', reason = null, failed_at = null, retries = retries + 1
     where i.id in (select intake_id from upd) and i.state = 'failed'
    returning i.id
  )
  select (select count(*) from upd), (select count(distinct intake_id) from upd) into v_jobs, v_intakes;
  return jsonb_build_object('steps', v_jobs, 'listings', v_intakes);
end $$;
revoke all on function app.listing_photos_requeue_local(uuid) from public, anon, authenticated;
grant execute on function app.listing_photos_requeue_local(uuid) to service_role;

alter function app.listing_photos_reprocess_local(uuid) rename to listing_photos_reprocess_local_pre2450;
create function app.listing_photos_reprocess_local(p_by uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare r jsonb;
begin
  perform app.assert_admin(p_by);
  r := app.listing_photos_requeue_local(null);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'listing_photos_reprocess_local', 'listing_jobs', null, r);
  return r;
end $$;
select pg_temp.copy_grants('app.listing_photos_reprocess_local(uuid)'::regprocedure, 'app.listing_photos_reprocess_local_pre2450(uuid)'::regprocedure);

-- ================================================================ 6. the review's photo problems
alter function app.listing_photo_problems(uuid) rename to listing_photo_problems_pre2450;
create function app.listing_photo_problems(p_vehicle uuid) returns text[]
language plpgsql stable security definer set search_path = public, app as $$
declare v text[] := app.listing_photo_problems_pre2450(p_vehicle);
begin
  return coalesce((select array_agg(x order by o) from unnest(v) with ordinality u(x, o)
                    where x not like '% photo is not processed and approved'
                      and not (x = 'No cover photo' and (app.cover_photo(p_vehicle)).id is not null)), '{}');
end $$;
select pg_temp.copy_grants('app.listing_photo_problems(uuid)'::regprocedure, 'app.listing_photo_problems_pre2450(uuid)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('listing_job_context_pre2450', 'public_listing_row_pre2450', 'public_listing_row_live_pre2450', 'worker_claim_listing_jobs_pre2450',
              'worker_listing_result_pre2450', 'listing_photos_reprocess_local_pre2450', 'listing_photo_problems_pre2450') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ================================================================ 7. once: the stuck listings move on
do $$
declare r jsonb; v record; n integer := 0; i record;
begin
  r := app.listing_photos_requeue_local(null);
  for v in select l.vehicle_id from vehicle_listings l join vehicles c on c.id = l.vehicle_id
            where l.status in ('published', 'paused') and not coalesce(c.is_sample, false) loop
    n := n + app.listing_photos_approve_live(v.vehicle_id);
  end loop;
  for i in select id from listing_intakes where state in ('processing_photos', 'drafting', 'decoding') loop
    perform app.advance_listing_intake(i.id);
  end loop;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (null, 'listing_photos_reprocess_local', 'listing_jobs', null, r || jsonb_build_object('approved_live', n, 'by', 'migration 2450'));
  raise notice '2450: % photo steps of % listings queued again, % photos of live listings approved', r ->> 'steps', r ->> 'listings', n;
end $$;

-- every car's cached row again, with the cover of 5
select app.listing_cache_refresh_all();
