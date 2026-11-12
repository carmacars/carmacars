-- 2530_r41_plates_auto.sql (release 41, docs/changes/2026-11-12-r41-plates-auto.md)
-- The owner, Nov 12: every listing photo must have its licence plate covered or be marked "No plate visible" before it
-- goes public (0070, 0661), and with about 85 cars of 10 to 30 photos each nobody can check them by hand. Also "Cover the
-- plate" did nothing on the Admin listing review. No applied migration is edited.
--   1. The plate is checked by itself (Program settings plate_auto_enabled, on): every current photo whose plate is not
--      checked gets a listing job "plate_auto" (the lowest priority of the queue, after every other step). The worker
--      (web/src/features/listing/worker.ts plateAuto) asks the vision model through the same gate as the marks
--      (server_photo_mark_gate: Workers AI, within the day's free AI share) where the plates are, then
--        * a plate found (confidence >= plate_auto_cover_min): the same cover as "Cover the plate" (the CARMA plate, the front
--          plate edited out) on a new public file; the uncovered file is kept privately (uncovered_path); covered;
--        * the model sure no plate is visible (>= plate_auto_clear_min), or an inside or detail shot where it sees none:
--          not_visible;
--        * unsure: left "Plate not checked" for a person.
--      Each decision is kept on the photo (vehicle_photos.plate_auto: who 'auto', the decision, the confidence, the model,
--      the file it was made for, the files before) and shown on the listing review with one-click undo.
--      The day's AI share used up: the job waits an hour without using an attempt.
--   2. Undo (photo_plate_auto_undo): a cover made by itself is taken off (the uncovered file goes back on the photo, its
--      sizes made again) and the photo is "Plate not checked" again, or "No plate visible" when the person says so; a
--      "No plate visible" made by itself goes back to "Plate not checked". An undone photo is not checked by itself again
--      until its file changes.
--   3. "Cover the plate" saved nothing with the CARMA plate (the default style since 1056): photo_plate_record still
--      allowed only cover, pixelate or blur. It now takes carma too.
--   4. Once (2531): every photo whose plate is not checked is queued, and the Lamborghini Urus front-left photo wrongly marked
--      "No plate visible" by hand on Nov 12 is "Plate not checked" again, so the check covers it.
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

-- ================================================================ 1. settings, the record, the job kind
alter table program_settings
  add column if not exists plate_auto_enabled boolean not null default true,
  add column if not exists plate_auto_cover_min smallint not null default 55 check (plate_auto_cover_min between 1 and 100),
  add column if not exists plate_auto_clear_min smallint not null default 85 check (plate_auto_clear_min between 1 and 100);
comment on column program_settings.plate_auto_enabled is 'Check the licence plate on every listing photo by itself (2530): covered when the vision model finds one, "No plate visible" when it is sure there is none, left for a person otherwise';
comment on column program_settings.plate_auto_cover_min is 'Automatic plate check: the model''s confidence (0 to 100) needed to cover a plate by itself';
comment on column program_settings.plate_auto_clear_min is 'Automatic plate check: the model''s confidence (0 to 100) needed to mark an outside photo "No plate visible" by itself';

alter table vehicle_photos add column if not exists plate_auto jsonb check (plate_auto is null or jsonb_typeof(plate_auto) = 'object');
comment on column vehicle_photos.plate_auto is 'The automatic plate check (2530): who (auto), decision (covered, not_visible, unsure), confidence, model, at, path (the file it was made for), prev_path and prev_variants (the files before a cover), boxes; undone, undone_by, undone_at once a person undid it';

alter table listing_jobs drop constraint if exists listing_jobs_kind_check;
alter table listing_jobs add constraint listing_jobs_kind_check check (kind in ('decode_vin', 'draft_copy', 'process_photo', 'resize', 'publish', 'marketing_photo', 'plate_redo',
  'cover_model', 'cover_flyer', 'angle_make', 'plate_auto'));

-- ================================================================ 2. which photos, and the queue
-- A current, processed public photo of a real car whose plate nobody checked, not already looked at for this file
-- (an unsure answer or an undo stays until the file changes).
create function app.plate_auto_due(ph vehicle_photos) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((app.settings()).plate_auto_enabled, false)
     and ph.plate_status = 'unchecked' and ph.replaced_at is null and ph.processed_path is not null and ph.status in ('processed', 'approved')
     and exists (select 1 from listing_shot_types st where st.code = ph.shot_type and st.is_public)
     and not exists (select 1 from vehicles v where v.id = ph.vehicle_id and coalesce(v.is_sample, false))
     and not (ph.plate_auto is not null and ph.plate_auto ->> 'path' is not distinct from ph.processed_path
              and (coalesce((ph.plate_auto ->> 'undone')::boolean, false) or ph.plate_auto ->> 'decision' = 'unsure'))
$$;

-- p_photo: one photo; p_vehicle: one car; neither: every photo due. Returns how many jobs were queued (an open job is kept).
create function app.plate_auto_queue(p_photo uuid default null, p_vehicle uuid default null) returns integer
language plpgsql security definer set search_path = public, app as $$
declare r record; n integer := 0; v_intake uuid; v_job uuid; ps program_settings := app.settings();
begin
  for r in
    select ph.*, st.rebackground as outside
      from vehicle_photos ph join listing_shot_types st on st.code = ph.shot_type
     where (p_photo is null or ph.id = p_photo) and (p_vehicle is null or ph.vehicle_id = p_vehicle) and app.plate_auto_due(ph)
       and not exists (select 1 from listing_jobs j where j.vehicle_photo_id = ph.id and j.kind = 'plate_auto' and j.status in ('queued', 'running'))
     order by ph.vehicle_id, ph.sort_order
  loop
    v_intake := coalesce(r.intake_id, (select i.id from listing_intakes i where i.vehicle_id = r.vehicle_id order by i.created_at desc limit 1));
    continue when v_intake is null;
    v_job := app.enqueue_listing_job(v_intake, 'plate_auto', r.id, jsonb_build_object('plate', jsonb_build_object(
      'photo_id', r.id, 'vehicle_id', r.vehicle_id, 'shot_type', r.shot_type, 'source', r.processed_path, 'inside', not coalesce(r.outside, false),
      'end', case when r.shot_type like 'front%' then 'front' else 'rear' end, 'uncovered_path', r.uncovered_path,
      -- the model sees a smaller size when the photo has one (about 1,000 px wide is plenty to find a plate)
      'detect_path', (select v ->> 'path' from jsonb_array_elements(coalesce(r.variants, '[]'::jsonb)) v
                       where (v ->> 'width') ~ '^\d+$' and (v ->> 'width')::integer between 640 and 1600 order by abs((v ->> 'width')::integer - 1024) limit 1),
      'widths', coalesce((select jsonb_agg((v ->> 'width')::integer) from jsonb_array_elements(coalesce(r.variants, '[]'::jsonb)) v where (v ->> 'width') ~ '^\d+$'), '[]'::jsonb),
      'cover_min', ps.plate_auto_cover_min, 'clear_min', ps.plate_auto_clear_min)));
    -- the lowest priority: after every other step queued now
    update listing_jobs set next_attempt_at = greatest(next_attempt_at, now() + interval '1 minute') where id = v_job and status = 'queued' and attempts = 0;
    n := n + 1;
  end loop;
  return n;
end $$;

-- a photo that becomes due (processed, made again, its plate check reset) is queued at once
create function app.vehicle_photo_plate_auto() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if app.plate_auto_due(new) and (tg_op = 'INSERT' or old.processed_path is distinct from new.processed_path or old.status is distinct from new.status
                                  or old.plate_status is distinct from new.plate_status or old.replaced_at is distinct from new.replaced_at) then
    perform app.plate_auto_queue(new.id);
  end if;
  return null;
end $$;
drop trigger if exists vehicle_photos_plate_auto on vehicle_photos;
create trigger vehicle_photos_plate_auto after insert or update of processed_path, status, plate_status, replaced_at on vehicle_photos
  for each row execute function app.vehicle_photo_plate_auto();

-- ================================================================ 3. the worker's decision
-- p: photo_id, path (the file the model saw: still the photo's file, or nothing is changed), decision (covered | not_visible
-- | unsure), confidence, model, boxes; for covered also processed_path, variants, uncovered_path, width, height, byte_size.
-- Returns applied, and for a cover the files it replaced (the worker takes them off the public bucket) or, when not applied,
-- nothing to remove but its own new files.
create function app.plate_auto_apply(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ph vehicle_photos;
  v_dec text := p ->> 'decision';
  v_rec jsonb;
  b jsonb;
  v_intake uuid;
begin
  select * into ph from vehicle_photos where id = nullif(p ->> 'photo_id', '')::uuid for update;
  if ph.id is null then return jsonb_build_object('applied', false, 'reason', 'gone'); end if;
  if v_dec not in ('covered', 'not_visible', 'unsure') then raise exception 'A decision is covered, not_visible or unsure' using errcode = '22023'; end if;
  -- a person decided since, the file changed, or the photo was replaced: nothing is changed
  if ph.plate_status <> 'unchecked' or ph.replaced_at is not null or ph.processed_path is distinct from (p ->> 'path') then
    return jsonb_build_object('applied', false, 'reason', 'changed');
  end if;
  v_rec := jsonb_build_object('who', 'auto', 'decision', v_dec, 'confidence', case when (p ->> 'confidence') ~ '^\d+(\.\d+)?$' then round((p ->> 'confidence')::numeric) end,
    'model', left(p ->> 'model', 120), 'at', now(), 'path', ph.processed_path, 'boxes', coalesce(p -> 'boxes', '[]'::jsonb));
  if v_dec = 'covered' then
    if jsonb_typeof(p -> 'boxes') is distinct from 'array' or jsonb_array_length(p -> 'boxes') = 0 then raise exception 'A cover needs its boxes' using errcode = '22023'; end if;
    for b in select * from jsonb_array_elements(p -> 'boxes') loop
      if (b ->> 'x')::numeric < 0 or (b ->> 'y')::numeric < 0 or (b ->> 'w')::numeric <= 0 or (b ->> 'h')::numeric <= 0
         or (b ->> 'x')::numeric + (b ->> 'w')::numeric > 1.0001 or (b ->> 'y')::numeric + (b ->> 'h')::numeric > 1.0001 then
        raise exception 'A box is outside the photo' using errcode = '22023';
      end if;
    end loop;
    if coalesce(p ->> 'processed_path', '') !~ ('^vehicles/' || ph.vehicle_id || '/') then raise exception 'The covered file is not this car''s' using errcode = '22023'; end if;
    update vehicle_photos set plate_status = 'covered', plate_boxes = p -> 'boxes', plate_style = 'carma', plate_checked_by = null, plate_checked_at = now(),
           processed_path = p ->> 'processed_path', variants = coalesce(p -> 'variants', '[]'::jsonb),
           width = case when (p ->> 'width') ~ '^[0-9]+$' then (p ->> 'width')::integer else width end,
           height = case when (p ->> 'height') ~ '^[0-9]+$' then (p ->> 'height')::integer else height end,
           byte_size = case when (p ->> 'byte_size') ~ '^[0-9]+$' then (p ->> 'byte_size')::bigint else byte_size end,
           mime_type = 'image/jpeg', uncovered_path = coalesce(uncovered_path, nullif(p ->> 'uncovered_path', '')),
           plate_auto = v_rec || jsonb_build_object('path', p ->> 'processed_path', 'prev_path', ph.processed_path, 'prev_variants', coalesce(ph.variants, '[]'::jsonb),
                                                    'uncovered', nullif(p ->> 'uncovered_path', ''))
     where id = ph.id;
    -- a photo covered before its sizes were made: they are made from the covered file
    if jsonb_array_length(coalesce(p -> 'variants', '[]'::jsonb)) = 0 then
      v_intake := coalesce(ph.intake_id, (select i.id from listing_intakes i where i.vehicle_id = ph.vehicle_id order by i.created_at desc limit 1));
      if v_intake is not null then perform app.enqueue_listing_job(v_intake, 'resize', ph.id, '{}'::jsonb); end if;
    end if;
    return jsonb_build_object('applied', true, 'previous', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
      select ph.processed_path x union select v ->> 'path' from jsonb_array_elements(coalesce(ph.variants, '[]'::jsonb)) v) q where x is not null and x <> (p ->> 'processed_path')));
  elsif v_dec = 'not_visible' then
    update vehicle_photos set plate_status = 'not_visible', plate_boxes = '[]'::jsonb, plate_style = null, plate_checked_by = null, plate_checked_at = now(), plate_auto = v_rec where id = ph.id;
  else
    update vehicle_photos set plate_auto = v_rec where id = ph.id;
  end if;
  return jsonb_build_object('applied', true, 'previous', '[]'::jsonb);
end $$;
create function public.server_plate_auto_apply(p jsonb) returns jsonb
language sql volatile security definer set search_path = public, app as $$ select app.plate_auto_apply(p) $$;

-- a plate_auto job whose model could not be asked (the day's AI share used, the model off) waits an hour, attempts unused
alter function app.worker_listing_result(uuid, jsonb) rename to worker_listing_result_pre2530;
create function app.worker_listing_result(p_job uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare j listing_jobs; r jsonb;
begin
  select * into j from listing_jobs where id = p_job;
  r := app.worker_listing_result_pre2530(p_job, p);
  if j.kind = 'plate_auto' and coalesce((p ->> 'ok')::boolean, false) and p #>> '{output,plate_auto,decision}' = 'deferred' then
    update listing_jobs set status = 'queued', attempts = greatest(attempts - 1, 0), next_attempt_at = now() + interval '1 hour',
           locked_at = null, locked_by = null, finished_at = null, error = null
     where id = p_job and not exists (select 1 from listing_jobs o where o.id <> p_job and o.vehicle_photo_id = j.vehicle_photo_id and o.kind = 'plate_auto' and o.status in ('queued', 'running'));
  end if;
  return r;
end $$;
select pg_temp.copy_grants('app.worker_listing_result(uuid, jsonb)'::regprocedure, 'app.worker_listing_result_pre2530(uuid, jsonb)'::regprocedure);

-- the claim (2450's, with plate_auto after every other step)
alter function app.worker_claim_listing_jobs(text, integer, timestamptz) rename to worker_claim_listing_jobs_pre2530;
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
     order by case x.kind when 'decode_vin' then 0 when 'draft_copy' then 1 when 'process_photo' then 2 when 'plate_auto' then 4 else 3 end, x.next_attempt_at, x.created_at
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
select pg_temp.copy_grants('app.worker_claim_listing_jobs(text, integer, timestamptz)'::regprocedure, 'app.worker_claim_listing_jobs_pre2530(text, integer, timestamptz)'::regprocedure);

-- ================================================================ 4. a person: the CARMA plate saves; undo
-- photo_plate_record (0042) allowed cover, pixelate or blur only, so "Cover the plate" with the default CARMA plate (1056)
-- was refused ("Choose cover, pixelate or blur"). A person's decision replaces an automatic one (plate_checked_by is theirs).
alter function app.photo_plate_record(uuid, jsonb) rename to photo_plate_record_pre2530;
create function app.photo_plate_record(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_carma boolean := p ->> 'status' = 'covered' and p ->> 'style' = 'carma'; r jsonb;
begin
  r := app.photo_plate_record_pre2530(p_by, case when v_carma then jsonb_set(p, '{style}', '"cover"') else p end);
  if v_carma then
    update vehicle_photos set plate_style = 'carma' where id = (p ->> 'photo')::uuid;
    r := jsonb_set(r, '{photo}', (select to_jsonb(x) from vehicle_photos x where x.id = (p ->> 'photo')::uuid));
  end if;
  return r;
end $$;
select pg_temp.copy_grants('app.photo_plate_record(uuid, jsonb)'::regprocedure, 'app.photo_plate_record_pre2530(uuid, jsonb)'::regprocedure);

-- p: photo, to (unchecked | not_visible), processed_path (an automatic cover: the uncovered file written back to the public
-- bucket by /api/listing/plate). Returns the photo and, for a cover, the covered files to take off the public bucket.
create function app.photo_plate_auto_undo(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ph vehicle_photos;
  v_to text := coalesce(nullif(p ->> 'to', ''), 'unchecked');
  v_prev jsonb := '[]'::jsonb;
  v_intake uuid;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet', 'cs')) then
    raise exception 'Fleet, customer service or an Admin edits listing photos' using errcode = '42501';
  end if;
  if v_to not in ('unchecked', 'not_visible') then raise exception 'Undo to "Plate not checked" or "No plate visible"' using errcode = '22023'; end if;
  select * into ph from vehicle_photos where id = nullif(p ->> 'photo', '')::uuid for update;
  if ph.id is null or ph.replaced_at is not null then raise exception 'That photo is not current' using errcode = 'P0002'; end if;
  if ph.plate_auto is null or ph.plate_auto ->> 'who' <> 'auto' or ph.plate_checked_by is not null or coalesce((ph.plate_auto ->> 'undone')::boolean, false)
     or ph.plate_status = 'unchecked' or ph.plate_auto ->> 'path' is distinct from ph.processed_path then
    raise exception 'This photo''s plate was not checked automatically (or a person already changed it)' using errcode = '23514';
  end if;
  if ph.plate_status = 'covered' then
    if coalesce(p ->> 'processed_path', '') !~ ('^vehicles/' || ph.vehicle_id || '/') then raise exception 'The uncovered file is not this car''s' using errcode = '22023'; end if;
    v_prev := (select coalesce(jsonb_agg(x), '[]'::jsonb) from (select ph.processed_path x union select v ->> 'path' from jsonb_array_elements(coalesce(ph.variants, '[]'::jsonb)) v) q where x is not null);
    update vehicle_photos set processed_path = p ->> 'processed_path', variants = '[]'::jsonb, plate_boxes = '[]'::jsonb, plate_style = null where id = ph.id;
    -- the smaller sizes of the uncovered file, made again
    v_intake := coalesce(ph.intake_id, (select i.id from listing_intakes i where i.vehicle_id = ph.vehicle_id order by i.created_at desc limit 1));
    if v_intake is not null then perform app.enqueue_listing_job(v_intake, 'resize', ph.id, '{}'::jsonb); end if;
  end if;
  update vehicle_photos set plate_status = v_to,
         plate_checked_by = case when v_to = 'not_visible' then p_by end, plate_checked_at = case when v_to = 'not_visible' then now() end,
         plate_auto = plate_auto || jsonb_build_object('undone', true, 'undone_by', p_by, 'undone_at', now(), 'path', coalesce(p ->> 'processed_path', ph.processed_path))
   where id = ph.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'photo_plate_auto_undo', 'vehicle_photos', ph.id, jsonb_build_object('was', ph.plate_status, 'to', v_to, 'auto', ph.plate_auto));
  return jsonb_build_object('photo', (select to_jsonb(x) from vehicle_photos x where x.id = ph.id), 'previous', v_prev);
end $$;

-- the editor's and the save route's context carries the automatic decision (the undo needs its kept file)
alter function app.photo_plate_context(uuid, uuid) rename to photo_plate_context_pre2530;
create function app.photo_plate_context(p_by uuid, p_photo uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  return app.photo_plate_context_pre2530(p_by, p_photo) || jsonb_build_object('plate_auto', (select plate_auto from vehicle_photos where id = p_photo),
    'plate_checked_by', (select plate_checked_by from vehicle_photos where id = p_photo));
end $$;
select pg_temp.copy_grants('app.photo_plate_context(uuid, uuid)'::regprocedure, 'app.photo_plate_context_pre2530(uuid, uuid)'::regprocedure);

-- the review: whether the check runs by itself, and how many photos of the car wait for it
alter function app.listing_plates(uuid, uuid) rename to listing_plates_pre2530;
create function app.listing_plates(p_by uuid, p_vehicle uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  return app.listing_plates_pre2530(p_by, p_vehicle) || jsonb_build_object(
    'auto', coalesce((app.settings()).plate_auto_enabled, false) and (app.settings()).ai_vision_enabled,
    'auto_waiting', (select count(*) from listing_jobs j where j.vehicle_id = p_vehicle and j.kind = 'plate_auto' and j.status in ('queued', 'running')));
end $$;
select pg_temp.copy_grants('app.listing_plates(uuid, uuid)'::regprocedure, 'app.listing_plates_pre2530(uuid, uuid)'::regprocedure);

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2530;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_do', 'va_do') and p_name = 'photo_plate_auto_undo' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.photo_plate_auto_undo(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre2530(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2530(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['plate_auto_due', 'plate_auto_queue', 'vehicle_photo_plate_auto', 'plate_auto_apply', 'photo_plate_auto_undo',
              'worker_listing_result_pre2530', 'worker_claim_listing_jobs_pre2530', 'photo_plate_record_pre2530', 'listing_plates_pre2530', 'door_pre2530',
              'photo_plate_context_pre2530']))
        or (n.nspname = 'public' and p.proname = 'server_plate_auto_apply')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
