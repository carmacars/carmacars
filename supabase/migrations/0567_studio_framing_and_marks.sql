-- 0567_studio_framing_and_marks.sql
-- Release 28 (docs/changes/2026-11-06-r28-platform.md, B8, the production bugs of Nov 6):
--   1. Studio photos framed again (worker preset studio_v3, web/src/features/listing/subject-frame.ts): the car cropped to
--      its own edges and drawn at about 80% of the frame's width with its wheels on the floor line and a contact shadow;
--      the pieces of the cut-out away from the car (another site's corner mark, a caption) are left out.
--   2. A mark on an inside or detail photo: the worker asks the vision model where it is and cuts the edge band holding it
--      off. The job's context says whether the photo is flagged "watermark" (photo.watermark); the result clears the flag
--      when the worker says the mark is gone (output.watermark_removed) and keeps it otherwise (the result's flags list
--      used to replace the photo's flags, which dropped the flag of 0566).
--   3. The photos of the four Mercedes listings, and the outside photos of every car not yet published that were framed
--      the old way and have no plate covered yet, are processed again (one job each; idempotent). A photo processed again
--      leaves the site until it is approved again, and its plate is checked again (the old boxes were drawn on the old
--      framing), so no plate shows in between.

-- ================================================================ 2. the job's context and its result
do $$ begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname = 'listing_job_context_pre0567') then
    alter function app.listing_job_context(uuid) rename to listing_job_context_pre0567;
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname = 'worker_listing_result_pre0567') then
    alter function app.worker_listing_result(uuid, jsonb) rename to worker_listing_result_pre0567;
  end if;
end $$;

create or replace function app.listing_job_context(p_job uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when x -> 'photo' is null or jsonb_typeof(x -> 'photo') <> 'object' then x
              else jsonb_set(x, '{photo,watermark}', to_jsonb(coalesce((select ph.quality_flags ? 'watermark' from vehicle_photos ph where ph.id = (x -> 'photo' ->> 'id')::uuid), false))) end
    from (select app.listing_job_context_pre0567(p_job) x) q
$$;

create or replace function app.worker_listing_result(p_job uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  j listing_jobs;
  v_flagged boolean := false;
  r jsonb;
begin
  select * into j from listing_jobs where id = p_job;
  if j.kind = 'process_photo' and j.vehicle_photo_id is not null then
    select coalesce(ph.quality_flags ? 'watermark', false) into v_flagged from vehicle_photos ph where ph.id = j.vehicle_photo_id;
  end if;
  r := app.worker_listing_result_pre0567(p_job, p);
  if coalesce(v_flagged, false) and coalesce((p ->> 'ok')::boolean, false) then
    if coalesce((p -> 'output' ->> 'watermark_removed')::boolean, false) then
      -- the mark is gone: the photo counts again and goes public when it is approved (as any processed photo)
      update vehicle_photos set quality_flags = quality_flags - 'watermark' where id = j.vehicle_photo_id;
    else
      update vehicle_photos set quality_flags = case when quality_flags ? 'watermark' then quality_flags else quality_flags || '["watermark"]'::jsonb end,
             is_public = false
       where id = j.vehicle_photo_id;
    end if;
  end if;
  return r;
end $$;

-- ================================================================ the mark finder's gate and record (no person: the worker)
create or replace function app.photo_mark_gate() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare b jsonb := app.ai_vision_budget(now()); a jsonb;
begin
  if not coalesce((b ->> 'enabled')::boolean, false) then return b || jsonb_build_object('allowed', false); end if;
  if (b ->> 'all_used')::bigint >= (b ->> 'all_limit')::bigint then return b || jsonb_build_object('allowed', false); end if;
  a := app.ai_allow('photo_sort', 120);
  return b || jsonb_build_object('allowed', coalesce((a ->> 'ok')::boolean, false));
end $$;

create or replace function app.photo_mark_record(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  insert into provider_calls (provider, purpose, ok, error, duration_ms, cost_microusd, units, unit)
  values (left(coalesce(p ->> 'model', 'workers-ai'), 120), 'photo_sort', coalesce((p ->> 'ok')::boolean, false), null,
          greatest(coalesce((p ->> 'duration_ms')::integer, 0), 0), 0, greatest(coalesce((p ->> 'neurons')::integer, 0), 0), 'neurons');
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.server_photo_mark_gate() returns jsonb
language sql volatile security definer set search_path = public, app as $$ select app.photo_mark_gate() $$;
create or replace function public.server_photo_mark_record(p jsonb) returns jsonb
language sql volatile security definer set search_path = public, app as $$ select app.photo_mark_record(p) $$;

revoke all on function app.photo_mark_gate(), app.photo_mark_record(jsonb), public.server_photo_mark_gate(), public.server_photo_mark_record(jsonb),
                       app.listing_job_context(uuid), app.worker_listing_result(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.photo_mark_gate(), app.photo_mark_record(jsonb), public.server_photo_mark_gate(), public.server_photo_mark_record(jsonb),
                          app.listing_job_context(uuid), app.worker_listing_result(uuid, jsonb) to service_role;

-- ================================================================ 3. processed again
create or replace function app.studio_v3_requeue() returns integer
language plpgsql security definer set search_path = public, app as $$
declare r record; n integer := 0;
begin
  for r in
    select p.id, p.intake_id, s.rebackground, s.is_public as shot_public,
           (left(v.id::text, 8) = any (array['a797ab50', '44b2d7f8', 'a584d253', '4a3f1606'])
             or left(l.id::text, 8) = any (array['a797ab50', '44b2d7f8', 'a584d253', '4a3f1606'])) as named
      from vehicle_photos p
      join listing_shot_types s on s.code = p.shot_type
      join vehicles v on v.id = p.vehicle_id
      left join vehicle_listings l on l.vehicle_id = p.vehicle_id
     where not coalesce(v.is_sample, false) and p.replaced_at is null and p.status <> 'rejected' and p.intake_id is not null
       and not exists (select 1 from listing_jobs j where j.vehicle_photo_id = p.id and j.kind = 'process_photo' and j.status in ('queued', 'running'))
       and (
         -- the four Mercedes listings: every photo that can go on the site, once
         ((left(v.id::text, 8) = any (array['a797ab50', '44b2d7f8', 'a584d253', '4a3f1606'])
             or left(l.id::text, 8) = any (array['a797ab50', '44b2d7f8', 'a584d253', '4a3f1606']))
          and s.is_public and (case when s.rebackground then coalesce(p.preset_version, '') <> 'studio_v3' else not exists (select 1 from listing_jobs j where j.vehicle_photo_id = p.id and j.kind = 'process_photo' and j.output ? 'watermark_removed') end))
         -- any car not yet published: an outside photo framed the old way whose plate nobody has covered yet
         or (l.status in ('draft', 'ready') and s.rebackground and p.background_status = 'done' and p.preset_version like 'studio%'
             and p.preset_version <> 'studio_v3' and p.plate_status = 'unchecked'))
  loop
    update vehicle_photos set background_status = case when r.rebackground then 'pending' else background_status end,
           is_public = false,
           -- the plate is checked again on the new framing (the old boxes do not fit it)
           plate_status = case when r.rebackground then 'unchecked' else plate_status end,
           plate_boxes = case when r.rebackground then '[]'::jsonb else plate_boxes end,
           plate_suggestion = case when r.rebackground then null else plate_suggestion end,
           uncovered_path = case when r.rebackground then null else uncovered_path end,
           -- an inside or detail photo of the four: checked for a mark (the worker clears the flag when there is none
           -- or it was cut off; its job's output then says watermark_removed, which keeps this from running twice)
           quality_flags = case when r.named and not r.rebackground and not quality_flags ? 'watermark'
                                then quality_flags || '["watermark"]'::jsonb else quality_flags end
     where id = r.id;
    perform app.enqueue_listing_job(r.intake_id, 'process_photo', r.id);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function app.studio_v3_requeue() from public, anon, authenticated;
grant execute on function app.studio_v3_requeue() to service_role;

do $$ begin raise notice '0567: % photos queued to be processed again', app.studio_v3_requeue(); end $$;
