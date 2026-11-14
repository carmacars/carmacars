-- 2780_r44_photo_spec.sql
-- Release 44. The owner (Nov 13), on the listing photos made with Gemini: (1) the backgrounds of the outside photos are not
-- replaced; (2) the plate's text is drawn somewhere random on the photo instead of on the plate; (3) the first photo is not
-- the same kind of shot on every car; (4) the interiors are blurred with the focus on the steering wheel. "Just use Gemini."
-- The web side (features/listing: showroom.ts, worker.ts, window-check.ts, plate-auto.ts) changes the words, the background
-- replacement and the plate check; this migration:
--   1. app.photo_spec(): the listing photo standard ('r44.1', the same as PHOTO_SPEC in showroom.ts). Each photo records the
--      standard it was made under (vehicle_photos.showroom.spec), so a photo made before is made again instead of the owner
--      reading "nothing to redo"; vehicle_photos.photo_spec_tried: the standard it was last queued for by itself (once each).
--   2. Photos filed as "Other detail" (the sorter could not read them, or a Drive import before r40) are sorted again by the
--      vision model, Gemini first (job photo_resort). A whole outside view is filed under its shot (the front three-quarter,
--      front_left, becomes the car's primary photo by 2690's rule) and made in the showroom; anything else stays a detail.
--      This is why 22 cars kept "Primary photo is not exterior" with nothing to redo: their outside photos were details.
--   3. "Redo photos with Gemini" on a car: also its photos with no listing attached (they were skipped) and its detail photos
--      sorted again; on every car at once (Admin, Fleet): every outside photo made under an older standard, within the day's
--      Gemini allowance. The segmenter's own mask sent again is scored like a new one (auto_mask), so a poor one gets its
--      background replaced by Gemini instead of being placed as it is.
--   4. A step stopped by Gemini's daily limit or a quota (gemini_wait) is queued again when Gemini may be asked: tomorrow, or
--      in an hour. A redo of the whole fleet finishes over the next days by itself.
--   5. app.job_photo_spec (every 20 minutes, Program settings listing_photo_spec_auto, on by default): the same upgrade a few
--      photos at a time, the primary photos first, keeping a reserve of the day's Gemini calls for new photos; the blurred
--      interiors (windows_blur_v1) are made again sharp; detail photos are sorted again.
-- No applied migration is edited: functions are wrapped (_pre2780).
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

-- ================================================================ 1. the standard
create function app.photo_spec() returns text language sql immutable parallel safe as $$ select 'r44.1'::text $$;
comment on function app.photo_spec() is 'The listing photo standard (2780): equal to PHOTO_SPEC in web/src/features/listing/showroom.ts. Raise both together; every outside photo made under another one is made again.';

alter table vehicle_photos
  add column if not exists photo_spec_tried text,
  add column if not exists resort jsonb;
comment on column vehicle_photos.photo_spec_tried is 'The photo standard (app.photo_spec) this photo was last queued for by the upgrade (2780), so each photo is tried once a standard.';
comment on column vehicle_photos.resort is 'A detail photo sorted again (2780): decision (sorted, unsure, deferred), shot, filed_as, model, spec, at.';

alter table program_settings add column if not exists listing_photo_spec_auto boolean not null default true;
comment on column program_settings.listing_photo_spec_auto is 'Listing photos (2780): photos made under an older photo standard are made again by themselves a few at a time (Gemini, within its daily allowance, keeping 10 calls a day for new photos); detail photos are sorted again; blurred interiors made sharp.';

alter table listing_jobs drop constraint if exists listing_jobs_kind_check;
alter table listing_jobs add constraint listing_jobs_kind_check check (kind in ('decode_vin', 'draft_copy', 'process_photo', 'resize', 'publish', 'marketing_photo', 'plate_redo',
  'cover_model', 'cover_flyer', 'angle_make', 'plate_auto', 'photo_resort'));

-- the Gemini image calls left today (the showroom gate's own count), less a reserve for new photos
create function app.photo_gemini_left(p_reserve integer default 0) returns integer
language sql stable security definer set search_path = public, app as $$
  select greatest(0, coalesce((app.settings()).listing_showroom_ai_daily, 0) - p_reserve
                     - (select count(*)::integer from provider_calls c where c.purpose = 'listing_showroom' and c.created_at >= app.local_midnight(app.local_date(now()))))
$$;

-- one outside photo queued again in the showroom with Gemini as the only engine; the version before is kept
create function app.photo_gemini_queue(p_by uuid, p_photo uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare ph vehicle_photos;
begin
  select * into ph from vehicle_photos where id = p_photo;
  perform app.photo_scene_queue(p_by, ph.id, 'showroom', 'showroom_redo');
  update listing_jobs j set input = j.input || jsonb_build_object('engine', 'gemini')
         || case when nullif(ph.cutout ->> 'mask', '') is null and nullif(ph.cutout ->> 'auto_mask', '') is not null then jsonb_build_object('auto_mask', true) else '{}'::jsonb end
   where j.vehicle_photo_id = ph.id and j.kind = 'process_photo' and j.status = 'queued';
  update vehicle_photos set photo_spec_tried = app.photo_spec() where id = ph.id;
end $$;

-- the car's newest listing, for a photo that has none (a photo added outside a listing was skipped by every redo)
create function app.photo_adopt_intake(p_vehicle uuid) returns integer
language plpgsql security definer set search_path = public, app as $$
declare v_intake uuid := (select i.id from listing_intakes i where i.vehicle_id = p_vehicle order by i.created_at desc limit 1); n integer;
begin
  if v_intake is null then return 0; end if;
  update vehicle_photos set intake_id = v_intake where vehicle_id = p_vehicle and intake_id is null and replaced_at is null and status <> 'rejected';
  get diagnostics n = row_count;
  return n;
end $$;

-- a detail photo sorted again (job photo_resort); false when it is not one to sort or is being sorted
create function app.photo_resort_queue(p_by uuid, p_photo uuid) returns boolean
language plpgsql security definer set search_path = public, app as $$
declare ph vehicle_photos; v_intake uuid;
begin
  select * into ph from vehicle_photos where id = p_photo;
  if ph.id is null or ph.shot_type <> 'other' or ph.replaced_at is not null or ph.status = 'rejected' or nullif(ph.original_path, '') is null
     or coalesce(ph.resort ->> 'spec', '') = app.photo_spec() then return false; end if;
  v_intake := coalesce(ph.intake_id, (select i.id from listing_intakes i where i.vehicle_id = ph.vehicle_id order by i.created_at desc limit 1));
  if v_intake is null then return false; end if;
  if exists (select 1 from listing_jobs j where j.vehicle_photo_id = ph.id and j.kind = 'photo_resort' and j.status in ('queued', 'running')) then return false; end if;
  perform app.enqueue_listing_job(v_intake, 'photo_resort', ph.id, jsonb_build_object('resort', jsonb_build_object(
    'photo_id', ph.id, 'vehicle_id', ph.vehicle_id, 'source', ph.original_path), 'by', p_by));
  update vehicle_photos set resort = jsonb_build_object('decision', 'queued', 'spec', app.photo_spec(), 'at', now()) where id = ph.id;
  return true;
end $$;

-- the outside photos to make again under the standard: on the site's background, made, with a listing, not being made
create function app.photo_spec_due(p_vehicle uuid default null) returns setof vehicle_photos
language sql stable security definer set search_path = public, app as $$
  select x.* from vehicle_photos x join listing_shot_types s on s.code = x.shot_type join vehicles c on c.id = x.vehicle_id
   where (p_vehicle is null or x.vehicle_id = p_vehicle) and not coalesce(c.is_sample, false)
     and x.replaced_at is null and x.status <> 'rejected' and x.intake_id is not null and s.rebackground and s.is_public and x.processed_path is not null
     and coalesce(x.showroom ->> 'spec', '') <> app.photo_spec()
     and not exists (select 1 from listing_jobs j where j.vehicle_photo_id = x.id and j.kind = 'process_photo' and j.status in ('queued', 'running'))
   order by app.photo_rank(x.shot_type), x.is_cover desc, x.vehicle_id, x.sort_order, x.id
$$;

-- ================================================================ 2. the upgrade (Redo every car with Gemini, and the job)
-- p_auto: the job: each photo once a standard, only photos that stay on the site while made (a kept mask), 10 calls kept back
create function app.photo_spec_upgrade(p_by uuid, p_limit integer, p_auto boolean default false) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_left integer := least(greatest(coalesce(p_limit, 0), 0), app.photo_gemini_left(case when p_auto then 10 else 0 end));
        r record; n integer := 0; v_sorting integer := 0; v_sharp integer := 0; v_due integer;
begin
  for r in select d.id from app.photo_spec_due(null) d
            where not p_auto or (coalesce(d.photo_spec_tried, '') <> app.photo_spec()
                                 and coalesce(nullif(d.cutout ->> 'mask', ''), nullif(d.cutout ->> 'auto_mask', '')) is not null)
            limit v_left loop
    perform app.photo_gemini_queue(p_by, r.id);
    n := n + 1;
  end loop;
  -- detail photos sorted again: the cars whose first photo is not an outside one first
  for r in select x.id from vehicle_photos x join vehicles c on c.id = x.vehicle_id
            where x.shot_type = 'other' and x.replaced_at is null and x.status <> 'rejected' and not coalesce(c.is_sample, false)
              and coalesce(x.resort ->> 'spec', '') <> app.photo_spec()
            order by (app.vehicle_primary_state(x.vehicle_id) <> 'exterior') desc, x.vehicle_id, x.sort_order
            limit case when p_auto then 6 else 60 end loop
    if app.photo_resort_queue(p_by, r.id) then v_sorting := v_sorting + 1; end if;
  end loop;
  -- interiors blurred behind their windows (before r44) made again from the original, sharp
  for r in select x.id, x.intake_id from vehicle_photos x join vehicles c on c.id = x.vehicle_id
            where x.preset_version = 'windows_blur_v1' and x.replaced_at is null and x.status <> 'rejected' and x.intake_id is not null and not coalesce(c.is_sample, false)
              and not exists (select 1 from listing_jobs j where j.vehicle_photo_id = x.id and j.kind = 'process_photo' and j.status in ('queued', 'running'))
            limit case when p_auto then 6 else 60 end loop
    perform app.enqueue_listing_job(r.intake_id, 'process_photo', r.id, jsonb_build_object('sharp', app.photo_spec()));
    v_sharp := v_sharp + 1;
  end loop;
  select count(*) into v_due from app.photo_spec_due(null);
  return jsonb_build_object('action', 'gemini', 'all', true, 'queued', n, 'resorting', v_sorting, 'sharpened', v_sharp,
    'waiting', greatest(v_due, 0), 'left_today', app.photo_gemini_left(0), 'spec', app.photo_spec());
end $$;

create function app.job_photo_spec() returns text
language plpgsql security definer set search_path = public, app as $$
declare ps program_settings := app.settings(); r jsonb;
begin
  if not coalesce(ps.listing_photo_spec_auto, true) or not coalesce(ps.listing_showroom_ai, false) then return 'off'; end if;
  r := app.photo_spec_upgrade(null, 4, true);
  return format('%s photo(s) queued, %s sorting, %s made sharp, %s waiting', r ->> 'queued', r ->> 'resorting', r ->> 'sharpened', r ->> 'waiting');
end $$;

-- ================================================================ 3. "Redo photos with Gemini"
alter function app.photo_showroom(uuid, jsonb) rename to photo_showroom_pre2780;
create function app.photo_showroom(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_action text := coalesce(nullif(p ->> 'action', ''), 'apply'); v_all boolean := coalesce((p ->> 'all')::boolean, false);
        v_vehicle uuid := nullif(p ->> 'vehicle', '')::uuid; v_out jsonb; r record; v_sorting integer := 0; v_adopted integer := 0;
begin
  if v_action <> 'gemini' then return app.photo_showroom_pre2780(p_by, p); end if;
  if v_all then
    if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet')) then
      raise exception 'An Admin or fleet redoes every car with Gemini' using errcode = '42501';
    end if;
    if not coalesce((app.settings()).listing_showroom_ai, false) then
      raise exception 'Gemini is switched off (Program settings, listing showroom AI). Switch it on first: the photos were not changed.' using errcode = '23514';
    end if;
    return app.photo_spec_upgrade(p_by, coalesce(nullif(p ->> 'limit', '')::integer, 100000), false);
  end if;
  -- one car: its photos added outside a listing take the car's newest listing first (they were skipped before)
  if v_vehicle is not null and nullif(p ->> 'photo', '') is null and (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet', 'cs')) then
    v_adopted := app.photo_adopt_intake(v_vehicle);
  end if;
  v_out := app.photo_showroom_pre2780(p_by, p);
  -- the jobs just queued: the standard, and the segmenter's own mask scored again
  update listing_jobs j set input = j.input || jsonb_build_object('auto_mask', true)
    from vehicle_photos ph
   where ph.id = j.vehicle_photo_id and j.kind = 'process_photo' and j.status = 'queued' and j.input ->> 'engine' = 'gemini'
     and (ph.vehicle_id = v_vehicle or ph.id = nullif(p ->> 'photo', '')::uuid)
     and nullif(ph.cutout ->> 'mask', '') is null and nullif(ph.cutout ->> 'auto_mask', '') is not null;
  update vehicle_photos ph set photo_spec_tried = app.photo_spec()
   where (ph.vehicle_id = v_vehicle or ph.id = nullif(p ->> 'photo', '')::uuid)
     and exists (select 1 from listing_jobs j where j.vehicle_photo_id = ph.id and j.kind = 'process_photo' and j.status = 'queued' and j.input ->> 'engine' = 'gemini');
  -- the car's detail photos sorted again: an outside view among them is filed under its shot and made in the showroom
  if v_vehicle is not null and nullif(p ->> 'photo', '') is null then
    for r in select x.id from vehicle_photos x where x.vehicle_id = v_vehicle and x.shot_type = 'other' and x.replaced_at is null and x.status <> 'rejected' loop
      if app.photo_resort_queue(p_by, r.id) then v_sorting := v_sorting + 1; end if;
    end loop;
  end if;
  return v_out || jsonb_build_object('resorting', v_sorting, 'adopted', v_adopted, 'spec', app.photo_spec());
end $$;
select pg_temp.copy_grants('app.photo_showroom(uuid, jsonb)'::regprocedure, 'app.photo_showroom_pre2780(uuid, jsonb)'::regprocedure);

-- ================================================================ 4. the worker's answers
alter function app.worker_listing_result(uuid, jsonb) rename to worker_listing_result_pre2780;
create function app.worker_listing_result(p_job uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare j listing_jobs; r jsonb; v_ok boolean := coalesce((p ->> 'ok')::boolean, false); v_out jsonb := coalesce(p -> 'output', '{}'::jsonb);
        v_res jsonb := p #> '{output,resort}'; v_shot text; v_new text; ph vehicle_photos; v_wait text := p #>> '{output,gemini_wait}'; v_by uuid;
begin
  select * into j from listing_jobs where id = p_job;
  r := app.worker_listing_result_pre2780(p_job, p);

  -- the standard a photo was made under, and how (swap: its background replaced by Gemini from the original)
  if j.kind = 'process_photo' and v_ok and jsonb_typeof(v_out -> 'showroom') = 'object' then
    update vehicle_photos set showroom = coalesce(showroom, '{}'::jsonb)
           || jsonb_strip_nulls(jsonb_build_object('spec', left(v_out -> 'showroom' ->> 'spec', 20), 'mode', left(v_out -> 'showroom' ->> 'mode', 20)))
     where id = j.vehicle_photo_id;
  end if;

  -- Gemini's daily limit or a quota: the same step again when Gemini may be asked (the photo was left as it was)
  if j.kind = 'process_photo' and not v_ok and v_wait in ('limit', 'quota') and j.input ->> 'engine' = 'gemini' then
    update listing_jobs set status = 'queued', attempts = 0, error = left('Waiting for Gemini (' || v_wait || '): ' || coalesce(p ->> 'error', ''), 500),
           next_attempt_at = case when v_wait = 'limit' then app.local_midnight(app.local_date(now()) + 1) + interval '15 minutes' else now() + interval '1 hour' end,
           locked_at = null, locked_by = null, finished_at = null
     where id = p_job and status = 'failed'
       and not exists (select 1 from listing_jobs o where o.id <> p_job and o.vehicle_photo_id = j.vehicle_photo_id and o.kind = 'process_photo' and o.status in ('queued', 'running'));
  end if;

  if j.kind = 'photo_resort' then
    select * into ph from vehicle_photos where id = j.vehicle_photo_id for update;
    if not v_ok or ph.id is null then return r; end if;
    if v_res ->> 'decision' = 'deferred' then
      -- the model may not be asked now: again in an hour
      update listing_jobs set status = 'queued', attempts = greatest(attempts - 1, 0), next_attempt_at = now() + interval '1 hour',
             locked_at = null, locked_by = null, finished_at = null, error = null
       where id = p_job and not exists (select 1 from listing_jobs o where o.id <> p_job and o.vehicle_photo_id = j.vehicle_photo_id and o.kind = 'photo_resort' and o.status in ('queued', 'running'));
      return r;
    end if;
    v_shot := v_res ->> 'shot';
    if v_res ->> 'decision' = 'sorted' and ph.shot_type = 'other' and ph.replaced_at is null and ph.status <> 'rejected'
       and v_shot in ('front_left', 'front', 'left', 'rear_left', 'rear', 'rear_right', 'right', 'front_right') then
      -- an outside view of the whole car: its shot when the car has none yet, else an extra outside photo
      v_new := case when app.angle_taken(ph.vehicle_id, v_shot) then 'exterior_more' else v_shot end;
      v_by := nullif(j.input ->> 'by', '')::uuid;
      update vehicle_photos x set shot_type = v_new, angle = coalesce((select s.photo_angle from listing_shot_types s where s.code = v_new), x.angle), scene = 'showroom',
             intake_id = coalesce(x.intake_id, j.intake_id),
             resort = jsonb_build_object('decision', 'sorted', 'shot', v_shot, 'filed_as', v_new, 'model', left(p ->> 'provider', 80), 'spec', app.photo_spec(), 'at', now())
       where x.id = ph.id;
      -- made in the showroom by the usual step (Gemini on top when it may be asked, its background replaced when the cut-out
      -- is poor); the version before is kept
      if not exists (select 1 from listing_jobs o where o.vehicle_photo_id = ph.id and o.kind = 'process_photo' and o.status in ('queued', 'running')) then
        perform app.photo_scene_queue(v_by, ph.id, 'showroom', 'showroom_redo');
        update vehicle_photos set photo_spec_tried = app.photo_spec() where id = ph.id;
      end if;
    else
      update vehicle_photos set resort = jsonb_build_object('decision', coalesce(left(v_res ->> 'decision', 20), 'unsure'), 'shot', left(v_shot, 40),
             'model', left(p ->> 'provider', 80), 'spec', app.photo_spec(), 'at', now())
       where id = ph.id;
    end if;
  end if;
  return r;
end $$;
select pg_temp.copy_grants('app.worker_listing_result(uuid, jsonb)'::regprocedure, 'app.worker_listing_result_pre2780(uuid, jsonb)'::regprocedure);

-- ================================================================ 5. the job
do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-photo-spec', '7,27,47 * * * *', 'select app.job_photo_spec()');
  end if;
end $$;

-- ================================================================ privileges
revoke all on function app.photo_spec(), app.photo_gemini_left(integer), app.photo_gemini_queue(uuid, uuid), app.photo_adopt_intake(uuid),
  app.photo_resort_queue(uuid, uuid), app.photo_spec_due(uuid), app.photo_spec_upgrade(uuid, integer, boolean), app.job_photo_spec(),
  app.photo_showroom_pre2780(uuid, jsonb), app.worker_listing_result_pre2780(uuid, jsonb)
  from public, anon, authenticated;
grant execute on function app.photo_spec(), app.photo_gemini_left(integer), app.photo_gemini_queue(uuid, uuid), app.photo_adopt_intake(uuid),
  app.photo_resort_queue(uuid, uuid), app.photo_spec_due(uuid), app.photo_spec_upgrade(uuid, integer, boolean), app.job_photo_spec()
  to service_role;
