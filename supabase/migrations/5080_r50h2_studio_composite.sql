-- 5080 (R50 hotfix 2, docs/changes/2026-11-25-r50-hotfix2-photos.md): the studio renders, rebuilt so a paid render can pass.
-- What was wrong (the code, not the switch):
--   1. The prompt asked Gemini to paint the car into the background plate, and the gate (web studio-gate.ts, 3701) then
--      measured the wall, the floor and a contact shadow against that plate: an image model redraws the whole frame, and
--      the worker compared the render cropped onto its target with the plate not cropped, so the compared regions were not
--      the same part of the room. The check also let a nose "camera" through that the gate then refused. Each refusal came
--      after the image and the check were paid.
--   2. The render chain (r48 AN) dropped the check-in and check-out photos before Gemini but the words still numbered them,
--      so the composition drawing and the stock photo were taken for the car; a car with only those photos got nothing.
--      Its first step (Workers AI image-to-image) could not make the asked view and spent a try of every view.
--   3. The check not answering was a free wait that made the image again (and paid it again), up to 8 times a try.
--   4. Gemini's cost was never counted: every call was recorded at 0 and the photo budget did not hold photo_r45 steps.
--   5. The connector's photo_standard failed on every call (3870: one ")" too many in app.comms_listing_files).
-- Now (standard r48.4): Gemini makes the car alone on a flat key colour from the car's listing photos, else its check-in
-- and check-out photos; the site keys it out and puts it on its own drawn dealership with the CarmaCars sign and the car's
-- name, the same place for every car of a view. The gate checks what the words ask (the key, the whole car) before the paid
-- check. The views are shown in the sample photos' order, then the car's real outside photos, each cut out on the same
-- dealership. Each Gemini call costs listing_showroom_ai_call_microusd in provider_calls (the photo budget holds the steps);
-- a photo gets at most listing_photo_r48_daily_tries image calls a day; a refused view waits longer each time; and when the
-- image calls per passed render pass listing_photo_r48_max_calls_per_pass the studio pauses for a day and alerts the Admins.
-- Tests: supabase/tests/99_r50h2_studio_composite.sql. SCHEMA_MARKER 5080. No applied migration is edited.
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
  if position(p_old in d) = 0 then raise exception '5080: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 0. the connector's photo_standard reads again (3870)
create or replace function app.comms_listing_files(v jsonb) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select case when jsonb_typeof(v -> 'cars') <> 'array' or jsonb_array_length(v -> 'cars') <> 1 then v else v || jsonb_build_object('cars', jsonb_build_array((v -> 'cars' -> 0) || jsonb_build_object('images', (
    select coalesce(jsonb_agg(jsonb_build_object('photo_id', ph.id, 'shot', ph.shot_type, 'public', ph.is_public, 'cover', ph.is_cover, 'status', ph.status, 'ai_generated', ph.ai_generated,
             'image', app.comms_file('vehicle-originals', ph.original_path, coalesce(ph.shot_type, 'photo') || '-' || ph.sort_order || '.jpg'))
             order by ph.sort_order, ph.id), '[]'::jsonb)
      from vehicle_photos ph where ph.vehicle_id = ((v -> 'cars' -> 0) ->> 'vehicle_id')::uuid and ph.replaced_at is null and ph.status <> 'rejected')))) end
$$;

-- ================================================================ 1. the settings and the call record
alter table program_settings
  add column if not exists listing_showroom_ai_call_microusd bigint not null default 39000 check (listing_showroom_ai_call_microusd between 0 and 10000000),
  add column if not exists listing_photo_r48_daily_tries integer not null default 3 check (listing_photo_r48_daily_tries between 1 and 20),
  add column if not exists listing_photo_r48_max_calls_per_pass integer not null default 8 check (listing_photo_r48_max_calls_per_pass between 2 and 100),
  add column if not exists listing_photo_r48_extras integer not null default 6 check (listing_photo_r48_extras between 0 and 20),
  add column if not exists listing_photo_r48_paused_at timestamptz,
  add column if not exists listing_photo_r48_pause_why text check (listing_photo_r48_pause_why is null or length(listing_photo_r48_pause_why) <= 300);
comment on column program_settings.listing_showroom_ai_call_microusd is 'Listing photos (5080): what one image made by the image model costs, in micro-dollars (gemini-2.5-flash-image: 0.039 USD an image at Google''s list price). Each call made is recorded at it, so the daily photo budget (photo_daily_budget_microusd) holds the studio steps.';
comment on column program_settings.listing_photo_r48_daily_tries is 'Listing photos (5080): the most image calls one photo gets in a day; the next waits for tomorrow.';
comment on column program_settings.listing_photo_r48_max_calls_per_pass is 'Listing photos (5080): the cost guard. When the image calls of the studio views in the last 24 hours are more than this many for each view that passed (and at least 3 times this many in all), the studio pauses for a day and the Admins are alerted.';
comment on column program_settings.listing_photo_r48_extras is 'Listing photos (5080): how many of a car''s real outside photos are cut out on the dealership and shown after its standard views.';
comment on column program_settings.listing_photo_r48_paused_at is 'Listing photos (5080): set by the cost guard when the studio paused (it starts again 24 hours later); clear it to start again now.';
comment on column program_settings.listing_photo_r48_pause_why is 'Listing photos (5080): why the cost guard paused the studio (the calls, the passed views and the spend).';

alter table provider_calls add column if not exists vehicle_photo_id uuid references vehicle_photos (id) on delete set null;
create index if not exists provider_calls_vehicle_photo on provider_calls (vehicle_photo_id, created_at) where vehicle_photo_id is not null;
comment on column provider_calls.vehicle_photo_id is 'Listing photos (5080): the photo an image call was made for (the cap per photo a day, the cost guard).';

-- the photo budget holds the studio steps too (2530 held only the upload steps)
select pg_temp.patch_fn('app.worker_claim_listing_jobs(text, integer, timestamptz)'::regprocedure,
  $q$and (x.kind not in ('process_photo', 'resize') or v_photo_ok$q$,
  $q$and (x.kind not in ('process_photo', 'resize', 'photo_r45') or v_photo_ok$q$);

-- ================================================================ 2. the image model's gate: the pause, the cap a photo, the cost
create or replace function app.showroom_ai_gate(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare ps program_settings := app.settings(); v_used integer; v_id uuid; v_photo uuid := nullif(p ->> 'photo_id', '')::uuid; ph vehicle_photos; v_mine integer;
begin
  if not coalesce(ps.listing_showroom_ai, false) then return jsonb_build_object('allowed', false, 'reason', 'off'); end if;
  select * into ph from vehicle_photos where id = v_photo;
  -- the studio paused by the cost guard: its views wait (a wait, never a try)
  if coalesce(ph.r48, false) and ps.listing_photo_r48_paused_at > now() - interval '24 hours' then
    return jsonb_build_object('allowed', false, 'reason', 'limit', 'scope', 'paused');
  end if;
  -- one gate at a time: the count and the call it allows are one step, so jobs side by side never pass the limit
  perform pg_advisory_xact_lock(hashtext('carmacars_showroom_ai'));
  if exists (select 1 from provider_calls c where c.purpose = 'listing_showroom' and not c.ok and c.error like 'quota%' and c.created_at > now() - interval '10 minutes') then
    return jsonb_build_object('allowed', false, 'reason', 'quota');
  end if;
  select count(*) into v_used from provider_calls c where c.purpose = 'listing_showroom' and c.created_at >= app.local_midnight(app.local_date(now()));
  if v_used >= ps.listing_showroom_ai_daily then
    return jsonb_build_object('allowed', false, 'reason', 'limit', 'used', v_used, 'limit', ps.listing_showroom_ai_daily);
  end if;
  -- the cap a photo a day: the same view is never made over and over
  if v_photo is not null then
    select count(*) into v_mine from provider_calls c where c.vehicle_photo_id = v_photo and c.purpose = 'listing_showroom' and c.created_at >= app.local_midnight(app.local_date(now()));
    if v_mine >= ps.listing_photo_r48_daily_tries then
      return jsonb_build_object('allowed', false, 'reason', 'limit', 'scope', 'photo', 'used', v_mine, 'limit', ps.listing_photo_r48_daily_tries);
    end if;
  end if;
  insert into provider_calls (provider, purpose, ok, error, duration_ms, cost_microusd, units, unit, vehicle_id, vehicle_photo_id)
  values (left('google-ai:' || ps.listing_showroom_ai_model, 120), 'listing_showroom', false, 'started', 0, 0, 1, 'requests', ph.vehicle_id, ph.id)
  returning id into v_id;
  return jsonb_build_object('allowed', true, 'model', ps.listing_showroom_ai_model, 'call_id', v_id, 'used', v_used + 1, 'limit', ps.listing_showroom_ai_daily);
end $$;

-- an image made is paid: its cost recorded (a refusal or an error is not billed by Google)
create or replace function app.showroom_ai_record(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  update provider_calls set ok = coalesce((p ->> 'ok')::boolean, false), error = left(nullif(p ->> 'error', ''), 300),
         duration_ms = greatest(coalesce((p ->> 'duration_ms')::integer, 0), 0),
         cost_microusd = case when coalesce((p ->> 'ok')::boolean, false) then (app.settings()).listing_showroom_ai_call_microusd else 0 end
   where id = nullif(p ->> 'call_id', '')::uuid and purpose = 'listing_showroom';
  return jsonb_build_object('ok', found);
end $$;

-- ================================================================ 3. the standard r48.4, the order, the references
create or replace function app.photo_r48_spec() returns text language sql immutable parallel safe as $$ select 'r48.4'::text $$;
comment on function app.photo_r48_spec() is 'The r48 photo standard (2900; r48.4 since 5080: the car keyed and put on the site''s drawn dealership), equal to R48_SPEC in web/src/features/listing/r48.ts.';

-- the sample photos' order (web/src/features/car/studio.ts SHOTS: lead, side, rear34, front, rear, dash, seats), then the
-- two views the samples have no drawing of
create or replace function app.photo_render_order() returns text[] language sql immutable parallel safe as $$
  select array['front_left', 'left', 'rear_left', 'front', 'rear', 'dashboard', 'front_seats', 'rear_seats', 'trunk']
$$;
comment on function app.photo_render_order() is 'R50 hotfix 2 (5080): the order of a car''s studio views on the site, the sample photos'' order (features/car/studio.ts SHOTS): front three-quarter (the cover), side profile, rear three-quarter, front, rear, dashboard, front seats, then rear seats and trunk. The car''s real outside photos, cut out on the same dealership, follow.';

-- the job makes the cover of every car first, then its second view, then the rest, in that order (3150 named the side
-- profile and the front three-quarter)
select pg_temp.patch_fn('app.job_photo_r48_pre3152()'::regprocedure,
  $q$case v_pass when 1 then array['left'] when 2 then array['front_left'] else v_order[3:] end$q$,
  $q$case v_pass when 1 then v_order[1:1] when 2 then v_order[2:2] else v_order[3:] end$q$);

-- The references of one view: the car's listing photos on the view's side (outside or inside), the same angle first; when it
-- has none on that side, its newest check-in, check-out and field job photos of that side; then its listing photos of the
-- other side (its colour and trim), or, with no listing photo at all, the other side's check-in photos. At most 6.
create or replace function app.photo_r48_refs(p_vehicle uuid, p_shot text) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  with real as (
    select ph.original_path as path, ph.shot_type as shot, ph.created_at,
           (ph.shot_type = p_shot) as same, (app.photo_is_exterior(ph.shot_type) = app.photo_is_exterior(p_shot)) as side
      from vehicle_photos ph join listing_shot_types st on st.code = ph.shot_type and st.is_public
     where ph.vehicle_id = p_vehicle and not ph.ai_generated and ph.replaced_at is null and ph.status <> 'rejected' and nullif(ph.original_path, '') is not null),
  hand as (
    select p.storage_bucket as bucket, p.storage_path as path, app.photo_r48_handover_shot(p.shot, p.angle) as shot, r.performed_at
      from condition_reports r join condition_report_photos p on p.condition_report_id = r.id
     where r.vehicle_id = p_vehicle and app.photo_r48_handover_shot(p.shot, p.angle) is not null and nullif(p.storage_path, '') is not null),
  has as (select exists (select 1 from real where side) as side_real, exists (select 1 from real) as any_real),
  pick as (
    select 'vehicle-originals' as bucket, path, shot, 'listing' as src, case when side then 0 else 2 end as grp,
           row_number() over (order by same desc, app.photo_rank(shot), created_at desc, path) as k
      from real
    union all
    select h.bucket, h.path, h.shot, 'handover', case when (app.photo_is_exterior(h.shot) = app.photo_is_exterior(p_shot)) then 1 else 3 end,
           row_number() over (order by h.shot = p_shot desc, (h.shot = 'wheel'), h.performed_at desc, app.photo_rank(h.shot), h.path)
      from hand h, has
     where case when (app.photo_is_exterior(h.shot) = app.photo_is_exterior(p_shot)) then not has.side_real else not has.any_real end)
  select coalesce(jsonb_agg(jsonb_build_object('bucket', bucket, 'path', path, 'shot', shot, 'from', src) order by grp, k), '[]'::jsonb)
    from (select * from pick order by grp, k limit 6) x
$$;

-- ================================================================ 4. every render made before r48.4 is made again
-- a render of an older standard is never live (photo_render_live: the gate's spec); the "check in place" of 3701 is over
-- (its refusal started the tries again, a loop under r48.4): its marks and its queued steps are taken off
update listing_jobs set input = input #- '{r45,regate}'
 where kind = 'photo_r45' and status = 'queued' and coalesce(input #>> '{r45,regate}', '') = 'true';
update vehicle_photos set r45 = (coalesce(r45, '{}'::jsonb) - 'regate' - 'reasons' - 'why') || jsonb_build_object('state', 'redo', 'tries', 0, 'at', now())
 where r48 and replaced_at is null and coalesce(r45 #>> '{gate,spec}', '') <> 'r48.4' and coalesce(r45 ->> 'state', '') in ('done', 'flagged', 'redo');
update vehicle_photos set r45 = r45 - 'regate' where r48 and r45 ? 'regate';
create or replace function app.photo_r48_regate_queue(p_limit integer) returns integer
language sql stable security definer set search_path = public, app, pg_temp as $$ select 0 $$;
comment on function app.photo_r48_regate_queue(integer) is 'R50 hotfix 2 (5080): no check in place any more (a render before r48.4 is made again); kept because job_photo_r48_pre3701 calls it.';

-- a refused view waits longer each time (20 minutes, then an hour), within the cap a day; the regate refusal of 3701 no longer
-- starts the tries again (no step carries regate since this migration)
alter function app.worker_listing_result(uuid, jsonb) rename to worker_listing_result_pre5080;
create function app.worker_listing_result(p_job uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare j listing_jobs; r jsonb; ph vehicle_photos;
begin
  select * into j from listing_jobs where id = p_job;
  r := app.worker_listing_result_pre5080(p_job, p);
  if j.kind = 'photo_r45' and jsonb_typeof(p #> '{output,r45}') = 'object' and not coalesce((p #>> '{output,r45,pass}')::boolean, false)
     and coalesce(p #>> '{output,r45,wait}', p #>> '{output,gemini_wait}') is null then
    select * into ph from vehicle_photos where id = j.vehicle_photo_id;
    if ph.r48 and ph.r45 ->> 'state' = 'queued' then
      update listing_jobs set next_attempt_at = now() + interval '20 minutes' * power(3, greatest(coalesce((ph.r45 ->> 'tries')::integer, 1), 1) - 1)
       where vehicle_photo_id = ph.id and kind = 'photo_r45' and status = 'queued';
    end if;
  end if;
  return r;
end $$;
select pg_temp.copy_grants('app.worker_listing_result(uuid, jsonb)'::regprocedure, 'app.worker_listing_result_pre5080(uuid, jsonb)'::regprocedure);

-- ================================================================ 5. the car's real outside photos after its views
insert into listing_shot_types (code, label, seq, required, is_public, rebackground, is_cover, max_count, photo_angle, is_active)
values ('studio_extra', 'Photo', 900, false, false, false, false, 20, 'other', false)
on conflict (code) do nothing;
alter table vehicle_photos add column if not exists r48_source uuid references vehicle_photos (id) on delete cascade;
create index if not exists vehicle_photos_r48_source on vehicle_photos (r48_source) where r48_source is not null;
comment on column vehicle_photos.r48_source is 'R50 hotfix 2 (5080): a studio extra (shot studio_extra): the car''s real outside photo it was cut out from and put on the dealership.';

-- a studio view the public may see: made at the current standard, passed, approved, on the site; a standard view or an extra
create or replace function app.photo_render_live(ph vehicle_photos) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select ph.r48 and ph.replaced_at is null and ph.status = 'approved' and ph.is_public and nullif(ph.processed_path, '') is not null
     and ph.processed_path !~ '^/' and coalesce(ph.r45 ->> 'state', '') <> 'flagged'
     and coalesce((ph.r45 #>> '{gate,pass}')::boolean, false) and ph.r45 #>> '{gate,spec}' = app.photo_r48_spec()
     and (ph.shot_type = any (app.photo_render_order()) or (ph.shot_type = 'studio_extra' and ph.r48_source is not null))
$$;
comment on function app.photo_render_live(vehicle_photos) is 'R50 hotfix 2 (5080): a studio view the public may see: made to the current standard (r48.4), passed the check and the gate, approved, on the site; a standard view or a real photo cut out on the dealership (studio_extra).';

-- the car's real outside photos to cut out: once its standard views are all made or flagged and one outside view is live
create function app.photo_r48_extra_queue(p_vehicle uuid, p_room integer) returns integer
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare ps program_settings := app.settings(); s record; n integer := 0; v_intake uuid; v_id uuid; v_have integer;
begin
  if coalesce(p_room, 0) <= 0 or ps.listing_photo_r48_extras <= 0 then return 0; end if;
  if coalesce((select v.is_sample from vehicles v where v.id = p_vehicle), true) then return 0; end if;
  if not app.photo_r48_car_done(p_vehicle) or not app.photo_has_live_render(p_vehicle) then return 0; end if;
  select count(*) into v_have from vehicle_photos x where x.vehicle_id = p_vehicle and x.shot_type = 'studio_extra' and x.replaced_at is null;
  for s in select ph.id, ph.original_path, ph.shot_type, ph.sort_order from vehicle_photos ph join listing_shot_types st on st.code = ph.shot_type and st.is_public
            where ph.vehicle_id = p_vehicle and not ph.ai_generated and ph.replaced_at is null and ph.status <> 'rejected' and nullif(ph.original_path, '') is not null
              and app.photo_is_exterior(ph.shot_type)
              and not exists (select 1 from vehicle_photos x where x.r48_source = ph.id and x.replaced_at is null)
            order by ph.sort_order, ph.created_at, ph.id
            limit least(p_room, greatest(ps.listing_photo_r48_extras - v_have, 0)) loop
    v_intake := coalesce(v_intake, app.photo_r48_intake(p_vehicle));
    insert into vehicle_photos (vehicle_id, intake_id, angle, shot_type, original_path, status, is_public, background_status, ai_generated, r48, r48_source, sort_order, scene, r45)
    values (p_vehicle, v_intake, 'other', 'studio_extra', s.original_path, 'processing', false, 'processing', true, true, s.id, 100 + coalesce(s.sort_order, 0), 'showroom',
            jsonb_build_object('state', 'queued', 'spec', app.photo_r48_spec(), 'tries', 0, 'at', now()))
    returning id into v_id;
    perform app.enqueue_listing_job(v_intake, 'photo_r45', v_id,
      jsonb_build_object('r45', jsonb_build_object('mode', 'r48', 'extra', true, 'car', app.photo_r45_car(p_vehicle), 'shot', 'studio_extra'), 'by', null));
    n := n + 1;
  end loop;
  return n;
end $$;
comment on function app.photo_r48_extra_queue(uuid, integer) is 'R50 hotfix 2 (5080): queues up to p_room of the car''s real outside photos (at most listing_photo_r48_extras in all) to be cut out on the dealership, once its standard views are done or flagged and one is live.';

-- the extra's step: its one real photo is the reference (no drawing, no stock photo)
alter function app.listing_job_context(uuid) rename to listing_job_context_pre5080;
create function app.listing_job_context(p_job uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare x jsonb := app.listing_job_context_pre5080(p_job); s vehicle_photos;
begin
  if x is null or jsonb_typeof(x) <> 'object' or x ->> 'kind' <> 'photo_r45' or coalesce(x #>> '{input,r45,extra}', '') <> 'true' then return x; end if;
  select src.* into s from listing_jobs j join vehicle_photos ph on ph.id = j.vehicle_photo_id join vehicle_photos src on src.id = ph.r48_source where j.id = p_job;
  return jsonb_set(x, '{input,r45}', ((x #> '{input,r45}') - 'guide' - 'stock' - 'plate' - 'family' - 'scene') || jsonb_build_object(
    'shot', 'studio_extra', 'refs', case when s.id is null then '[]'::jsonb
      else jsonb_build_array(jsonb_build_object('bucket', 'vehicle-originals', 'path', s.original_path, 'shot', s.shot_type, 'from', 'listing')) end));
end $$;
select pg_temp.copy_grants('app.listing_job_context(uuid)'::regprocedure, 'app.listing_job_context_pre5080(uuid)'::regprocedure);

-- the gallery: the live views in the sample order, then the live extras in the order of their photos; no live outside view:
-- the photos as before release 50 (5064)
create or replace function app.public_listing_photos(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  with r as (
    select distinct on (x.shot_type) x.* from vehicle_photos x
     where x.vehicle_id = p_vehicle and app.photo_render_live(x) and x.shot_type <> 'studio_extra'
       and not coalesce((select v.is_sample from vehicles v where v.id = p_vehicle), true)
     order by x.shot_type, x.created_at desc
  ), e as (
    select x.* from vehicle_photos x join vehicle_photos src on src.id = x.r48_source and src.replaced_at is null and src.status <> 'rejected'
     where x.vehicle_id = p_vehicle and x.shot_type = 'studio_extra' and app.photo_render_live(x)
  ), g as (
    select jsonb_build_object('path', r.processed_path, 'variants', coalesce(r.variants, '[]'::jsonb),
             'alt', app.vehicle_name(p_vehicle) || ', ' || lower(coalesce(st.label, r.shot_type)),
             'width', coalesce(r.width, 1800), 'height', coalesce(r.height, 1200), 'shot', r.shot_type, 'label', coalesce(st.label, r.shot_type),
             'generated', true) j,
           array_position(app.photo_render_order(), r.shot_type)::bigint k
      from r left join listing_shot_types st on st.code = r.shot_type
    union all
    select jsonb_build_object('path', e.processed_path, 'variants', coalesce(e.variants, '[]'::jsonb), 'alt', app.vehicle_name(p_vehicle) || ', photo',
             'width', coalesce(e.width, 1800), 'height', coalesce(e.height, 1200), 'shot', 'studio_extra', 'label', 'Photo', 'generated', true),
           100 + row_number() over (order by e.sort_order, e.created_at, e.id)
      from e
  )
  select case
    when not app.photo_has_live_render(p_vehicle) then
      coalesce(nullif(app.photo_fallback_gallery(p_vehicle), '[]'::jsonb), jsonb_build_array(app.photo_placeholder(p_vehicle)))
    else (select jsonb_agg(g.j || jsonb_build_object('is_cover', g.k = (select min(k) from g)) order by g.k) from g) end
$$;

-- a car's progress counts its standard views only (its extras are on top)
create or replace function app.photo_r48_car(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('angles', cardinality(app.photo_r45_angles()),
    'done', count(*) filter (where ph.r45 ->> 'state' = 'done'),
    'flagged', count(*) filter (where ph.r45 ->> 'state' = 'flagged'),
    'queued', count(*) filter (where ph.r45 ->> 'state' in ('queued', 'redo')),
    'handover_refs', exists (select 1 from jsonb_array_elements(app.photo_r48_refs(p_vehicle, 'front_left')) e where e ->> 'from' = 'handover'),
    'last_run', max((ph.r45 ->> 'at')::timestamptz))
    from vehicle_photos ph where ph.vehicle_id = p_vehicle and ph.r48 and ph.replaced_at is null and ph.shot_type = any (app.photo_r45_angles())
$$;

-- the cards' drive-off rides on the cover: the cutout of the cover's own view (the front three-quarter since 5080; 5030 cut the
-- side profile only, which is no longer the cover). server/site-cutouts.ts asks app.site_cutouts_due for the cover's view.
create function app.photo_shot_cutout(p_vehicle uuid, p_shot text) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('path', k.path, 'width', k.width, 'height', k.height, 'facing', k.facing, 'kind', k.kind)
         || case when k.kind = 'matte' then jsonb_build_object('plate', k.plate_path, 'box', k.box) else '{}'::jsonb end
    from site_cutouts k where k.vehicle_id = p_vehicle and k.shot = p_shot and nullif(k.path, '') is not null
$$;
select pg_temp.patch_fn('app.photo_row_cover(uuid, jsonb)'::regprocedure,
  $q$'cutout', (select app.photo_side_cutout(p_vehicle) from site_cutouts k
                           where not v_place and k.vehicle_id = p_vehicle and k.shot = 'left' and k.source_path = c ->> 'path' limit 1)),$q$,
  $q$'cutout', (select app.photo_shot_cutout(p_vehicle, k.shot) from site_cutouts k
                           where not v_place and k.vehicle_id = p_vehicle and k.shot = c ->> 'shot' and k.source_path = c ->> 'path' limit 1)),$q$);

-- ================================================================ 6. the cost guard
insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort) values
  ('photo_studio_paused', 'The studio photos paused: too many Gemini calls for each view that passed', 'System', '{admin}', 'urgent', 'alerts', true, false,
   'Listing photos (5080): the image calls of the last 24 hours went past listing_photo_r48_max_calls_per_pass for each passed view. The studio waits a day (or until listing_photo_r48_paused_at is cleared in Program settings).', 170)
on conflict (rule) do nothing;

-- the alert opens a list (Listings > Photo standard), not one record
alter function app.alert_entity_kind(text) rename to alert_entity_kind_pre5080;
create function app.alert_entity_kind(p_entity text) returns text
language sql immutable security definer set search_path = public, app, pg_temp as $$
  select case when p_entity = 'photo_studio' then 'list' else app.alert_entity_kind_pre5080(p_entity) end
$$;
select pg_temp.copy_grants('app.alert_entity_kind(text)'::regprocedure, 'app.alert_entity_kind_pre5080(text)'::regprocedure);

-- the last 24 hours of the studio views: the image calls paid, the views passed, the spend; pauses the studio and alerts the
-- Admins when the calls per passed view are abnormal
create function app.photo_r48_cost_guard() returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare ps program_settings := app.settings(); v_calls integer; v_spend bigint; v_pass integer; v_why text; v_paused boolean;
begin
  select count(*), coalesce(sum(c.cost_microusd), 0) into v_calls, v_spend
    from provider_calls c join vehicle_photos ph on ph.id = c.vehicle_photo_id and ph.r48
   where c.purpose = 'listing_showroom' and c.ok and c.created_at > now() - interval '24 hours';
  select count(*) into v_pass from vehicle_photos ph
   where ph.r48 and coalesce((ph.r45 #>> '{gate,pass}')::boolean, false) and ph.r45 #>> '{gate,spec}' = app.photo_r48_spec()
     and (ph.r45 #>> '{gate,at}')::timestamptz > now() - interval '24 hours';
  v_paused := coalesce(ps.listing_photo_r48_paused_at > now() - interval '24 hours', false);
  if not v_paused and v_calls >= 3 * ps.listing_photo_r48_max_calls_per_pass and v_calls > v_pass * ps.listing_photo_r48_max_calls_per_pass then
    v_why := format('%s image calls (%s) in 24 hours for %s passed view%s: more than %s a view', v_calls, app.fmt_money(v_spend / 10000) || ' USD', v_pass,
                    case when v_pass = 1 then '' else 's' end, ps.listing_photo_r48_max_calls_per_pass);
    update program_settings set listing_photo_r48_paused_at = now(), listing_photo_r48_pause_why = left(v_why, 300)
     where listing_photo_r48_paused_at is null or listing_photo_r48_paused_at <= now() - interval '24 hours';
    perform app.staff_alert('photo_studio_paused', 'photo_studio', null, to_char(now(), 'YYYYMMDDHH24'), 'Studio photos paused for a day',
      v_why || '. Listings > Photo standard shows the refusals.', jsonb_build_object('path_admin', '/admin/listings'));
    v_paused := true;
  end if;
  return jsonb_build_object('calls', v_calls, 'passed', v_pass, 'spend_microusd', v_spend, 'max_per_pass', ps.listing_photo_r48_max_calls_per_pass,
    'paused', v_paused, 'paused_at', case when v_paused then coalesce((app.settings()).listing_photo_r48_paused_at, now()) end,
    'why', case when v_paused then coalesce(v_why, (app.settings()).listing_photo_r48_pause_why) end);
end $$;
comment on function app.photo_r48_cost_guard() is 'R50 hotfix 2 (5080): the studio''s image calls, passed views and spend of the last 24 hours; pauses the studio for a day and alerts the Admins (photo_studio_paused) when the calls per passed view pass listing_photo_r48_max_calls_per_pass.';

-- the job: the guard first; paused, nothing is queued; then the views as before, then the extras within the room left
alter function app.job_photo_r48() rename to job_photo_r48_pre5080;
create function app.job_photo_r48() returns text
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare ps program_settings := app.settings(); g jsonb := app.photo_r48_cost_guard(); v_out text; v_room integer; n integer := 0; r record;
begin
  if coalesce((g ->> 'paused')::boolean, false) then return 'paused by the cost guard: ' || coalesce(g ->> 'why', ''); end if;
  v_out := app.job_photo_r48_pre5080();
  if coalesce(ps.listing_photo_r48_auto, true) and coalesce(ps.listing_showroom_ai, false) then
    v_room := least(greatest(coalesce(ps.listing_photo_r45_batch, 12) - app.photo_r48_due(), 0),
                    greatest(app.photo_gemini_left(coalesce(ps.listing_photo_r45_reserve, 50)) - app.photo_r48_due(), 0));
    for r in select c.vehicle_id from app.photo_r48_cars() c loop
      exit when n >= v_room;
      n := n + app.photo_r48_extra_queue(r.vehicle_id, v_room - n);
    end loop;
  end if;
  return v_out || case when n > 0 then format('; %s real photo(s) to cut out', n) else '' end;
end $$;
select pg_temp.copy_grants('app.job_photo_r48()'::regprocedure, 'app.job_photo_r48_pre5080()'::regprocedure);

-- Photo standard (Admin and Fleet): the guard's numbers and the pause
alter function app.photo_r45_fleet_read(uuid, jsonb) rename to photo_r45_fleet_read_pre5080;
create function app.photo_r45_fleet_read(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare x jsonb := app.photo_r45_fleet_read_pre5080(p_by, p); ps program_settings := app.settings(); v_calls integer; v_spend bigint; v_pass integer;
begin
  if x is null then return x; end if;
  select count(*), coalesce(sum(c.cost_microusd), 0) into v_calls, v_spend from provider_calls c join vehicle_photos ph on ph.id = c.vehicle_photo_id and ph.r48
   where c.purpose = 'listing_showroom' and c.ok and c.created_at > now() - interval '24 hours';
  select count(*) into v_pass from vehicle_photos ph where ph.r48 and coalesce((ph.r45 #>> '{gate,pass}')::boolean, false) and ph.r45 #>> '{gate,spec}' = app.photo_r48_spec()
     and (ph.r45 #>> '{gate,at}')::timestamptz > now() - interval '24 hours';
  return x || jsonb_build_object('r48_cost', jsonb_build_object('calls', v_calls, 'passed', v_pass, 'spend_microusd', v_spend, 'max_per_pass', ps.listing_photo_r48_max_calls_per_pass,
    'daily_tries', ps.listing_photo_r48_daily_tries, 'paused_at', case when ps.listing_photo_r48_paused_at > now() - interval '24 hours' then ps.listing_photo_r48_paused_at end,
    'why', case when ps.listing_photo_r48_paused_at > now() - interval '24 hours' then ps.listing_photo_r48_pause_why end));
end $$;
select pg_temp.copy_grants('app.photo_r45_fleet_read(uuid, jsonb)'::regprocedure, 'app.photo_r45_fleet_read_pre5080(uuid, jsonb)'::regprocedure);

-- ================================================================ privileges (the functions replaced in place keep theirs)
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['photo_r48_extra_queue', 'photo_r48_cost_guard', 'photo_shot_cutout', 'worker_listing_result_pre5080', 'listing_job_context_pre5080',
              'job_photo_r48_pre5080', 'photo_r45_fleet_read_pre5080'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- the listing cache and the landing pages' snapshots: the renders of the older standard are off the site now
do $$
begin
  perform app.listing_cache_refresh(array(select l.vehicle_id from vehicle_listings l where l.status in ('published', 'paused')));
  perform app.seo_snapshot_refresh();
exception when undefined_function then null;
end $$;
