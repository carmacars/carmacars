-- 0566_listing_photos_any_order.sql
-- Release 28 (docs/changes/2026-11-06-r28-platform.md, B8; the owner: "take 20 photos, not every photo in a defined
-- position, the background removed on every photo"):
--   1. No named shot is required any more. A listing is complete with at least 10 photos that can go on the site and an
--      outside photo for the cover (app.listing_missing_shots, which every step, the submit and the publish already ask).
--      "More outside photos" and "Other detail" take up to 30 each.
--   2. "Add photos" on the listing sends many photos at once with the shot "auto": the server asks the vision model which
--      shot each is (photo_sort, the live AI share, within the day's allowance) and files it there, or with the extra
--      outside or detail photos when that shot is taken or the model cannot say. Outside photos get the studio as before
--      (rebackground); inside and detail photos are kept as taken and cleaned.
--   3. A photo the model sees a watermark, a logo or caption text on (another site's corner mark, "Mercedes-Benz CLA-Class
--      2020") is flagged (quality_flags "watermark") and never public until a person clears the flag or replaces it.
--   4. The photos already on cars not yet published are processed again under these rules (one job each).

-- ================================================================ 1. any order
update listing_shot_types set required = false where required;
alter table listing_shot_types drop constraint if exists listing_shot_types_max_count_check;
alter table listing_shot_types add constraint listing_shot_types_max_count_check check (max_count between 1 and 30);
update listing_shot_types set max_count = 30 where code in ('other', 'exterior_more') and max_count < 30;
comment on column program_settings.listing_min_photos is 'Photos a listing needs before it is complete (0022; 0566: the only rule, with no named shot required): photos that can go on the site (not the odometer or other private shots), one of them outside for the cover.';

create or replace function app.listing_missing_shots(p_vehicle uuid) returns text[]
language sql stable security definer set search_path = public, app as $$
  with ph as (
    select p.shot_type, s.rebackground
      from vehicle_photos p join listing_shot_types s on s.code = p.shot_type
     where p.vehicle_id = p_vehicle and p.replaced_at is null and p.status <> 'rejected' and s.is_public
       and not coalesce(p.quality_flags ? 'watermark', false))
  select array_remove(array[
    case when (select count(*) from ph) < (app.settings()).listing_min_photos
         then format('At least %s photos (%s so far)', (app.settings()).listing_min_photos, (select count(*) from ph)) end,
    case when not exists (select 1 from ph where ph.rebackground) then 'An outside photo of the car for the cover' end], null)
$$;

-- ================================================================ 2. the sorter's gate and record (purpose photo_sort)
create or replace function app.ai_tier(p_purpose text) returns text
language sql immutable as $$
  select case when p_purpose = 'staff_assistant' then 'assistant'
              when p_purpose in ('chat', 'phone_draft', 'phone_summary', 'toll_read', 'plate_detect', 'guide_review', 'permit_read',
                                 'interview_transcribe', 'interview_followup', 'vin_read', 'photo_sort') then 'live'
              else 'background' end
$$;
do $$ begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname = 'ai_feature_label_pre0566') then
    alter function app.ai_feature_label(text) rename to ai_feature_label_pre0566;
  end if;
end $$;
create or replace function app.ai_feature_label(p_purpose text) returns text
language sql immutable as $$
  select case p_purpose when 'photo_sort' then 'Listing photo sorter' else app.ai_feature_label_pre0566(p_purpose) end
$$;

create or replace function app.photo_sort_gate(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare b jsonb := app.ai_vision_budget(now()); a jsonb;
begin
  if p_by is null or not exists (select 1 from users u where u.id = p_by and u.status = 'active') then raise exception 'Not permitted' using errcode = '42501'; end if;
  if not coalesce((b ->> 'enabled')::boolean, false) then return b || jsonb_build_object('allowed', false); end if;
  if (b ->> 'all_used')::bigint >= (b ->> 'all_limit')::bigint then return b || jsonb_build_object('allowed', false); end if;
  a := app.ai_allow('photo_sort', 120);
  return b || jsonb_build_object('allowed', coalesce((a ->> 'ok')::boolean, false));
end $$;

create or replace function app.photo_sort_record(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  insert into provider_calls (provider, purpose, ok, error, duration_ms, cost_microusd, units, unit)
  values (left(coalesce(p ->> 'model', 'workers-ai'), 120), 'photo_sort', coalesce((p ->> 'ok')::boolean, false), left(p ->> 'error', 500),
          greatest(coalesce((p ->> 'duration_ms')::integer, 0), 0), 0, greatest(coalesce((p ->> 'neurons')::integer, 0), 0), 'neurons');
  if coalesce((p ->> 'watermark')::boolean, false) and (p ->> 'photo_id') is not null then
    update vehicle_photos set quality_flags = case when quality_flags ? 'watermark' then quality_flags else coalesce(quality_flags, '[]'::jsonb) || '["watermark"]'::jsonb end,
           is_public = false
     where id = (p ->> 'photo_id')::uuid;
  end if;
  return jsonb_build_object('ok', true);
end $$;
create or replace function public.server_photo_sort_gate(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.photo_sort_gate(p_by) $$;
create or replace function public.server_photo_sort_record(p_by uuid, p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.photo_sort_record(p_by, p) $$;
revoke all on function app.photo_sort_gate(uuid), app.photo_sort_record(uuid, jsonb), public.server_photo_sort_gate(uuid), public.server_photo_sort_record(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.server_photo_sort_gate(uuid), public.server_photo_sort_record(uuid, jsonb) to service_role;

-- ================================================================ 3. a flagged watermark keeps the photo off the site
create or replace function app.vehicle_photos_watermark_guard() returns trigger
language plpgsql as $$
begin
  if new.is_public and coalesce(new.quality_flags ? 'watermark', false) then new.is_public := false; end if;
  return new;
end $$;
drop trigger if exists vehicle_photos_watermark_guard on vehicle_photos;
create trigger vehicle_photos_watermark_guard before insert or update on vehicle_photos for each row execute function app.vehicle_photos_watermark_guard();

-- ================================================================ 4. the photos of cars not yet published, processed again
do $$
declare r record; n integer := 0;
begin
  for r in
    select p.id, p.intake_id from vehicle_photos p
      join listing_shot_types s on s.code = p.shot_type
      join vehicle_listings l on l.vehicle_id = p.vehicle_id
      join vehicles v on v.id = p.vehicle_id
     where l.status in ('draft', 'ready') and not coalesce(v.is_sample, false) and p.replaced_at is null and p.status <> 'rejected'
       and p.intake_id is not null and s.rebackground and (p.background_status <> 'done' or coalesce(p.preset_version, '') not like 'studio%')
       and not exists (select 1 from listing_jobs j where j.vehicle_photo_id = p.id and j.kind = 'process_photo' and j.status in ('queued', 'running'))
  loop
    update vehicle_photos set background_status = 'pending' where id = r.id;
    perform app.enqueue_listing_job(r.intake_id, 'process_photo', r.id);
    n := n + 1;
  end loop;
  raise notice '0566: % photos queued to be processed again', n;
end $$;

-- the server may run every function of the app schema (suites 06, 08 and 09)
do $g$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and not has_function_privilege('service_role', p.oid, 'execute') loop
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $g$;
