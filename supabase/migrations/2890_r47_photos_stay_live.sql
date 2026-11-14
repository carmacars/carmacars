-- 2890 (release 47): a real photo stays on the site while its new Gemini version is not ready or not accepted.
--
-- 2840 took a car's real photo off the site (is_public = false) once its Gemini remake was refused or failed three times. A
-- remake can fail for reasons that have nothing to do with the photo itself (the model's answer, the strict second check),
-- and every refused photo of a car left it with no photo of its own: the site then showed the drawn sample of the model.
-- Now:
--   1. A refused or failed remake of a REAL photo keeps the photo as it was, on the site as before; it is flagged (r45 state
--      'flagged', quality flag r45_flagged) for Photo standard and made again later by Redo. Only a generated (AI) angle
--      that fails stays off the site, as it has no version before.
--   2. Once: every real photo 2840 took off the site this way is put back, when it is approved, has its file, and its plate
--      was checked (covered or not visible), the same rule the site uses for any public photo.
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

create function app.photo_r45_keep_live(p_photo uuid) returns void
language sql security definer set search_path = public, app as $$
  update vehicle_photos ph set is_public = true
   where ph.id = p_photo and not ph.is_public and not coalesce(ph.ai_generated, false) and ph.replaced_at is null
     and ph.status = 'approved' and ph.processed_path is not null and ph.plate_status in ('covered', 'not_visible')
     and coalesce(ph.r45 ->> 'state', '') = 'flagged'
     and coalesce((select st.is_public from listing_shot_types st where st.code = ph.shot_type), false)
$$;
comment on function app.photo_r45_keep_live(uuid) is 'r47 (2890): a real photo whose Gemini remake was refused or failed stays on the site as it was (approved, with its file and a checked plate).';
revoke all on function app.photo_r45_keep_live(uuid) from public, anon, authenticated;
grant execute on function app.photo_r45_keep_live(uuid) to service_role;

alter function app.worker_listing_result(uuid, jsonb) rename to worker_listing_result_pre2890;
create function app.worker_listing_result(p_job uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb := app.worker_listing_result_pre2890(p_job, p);
  v_photo uuid := (select j.vehicle_photo_id from listing_jobs j where j.id = p_job and j.kind in ('photo_r45', 'process_photo'));
begin
  if v_photo is not null then perform app.photo_r45_keep_live(v_photo); end if;
  return r;
end $$;
select pg_temp.copy_grants('app.worker_listing_result(uuid, jsonb)'::regprocedure, 'app.worker_listing_result_pre2890(uuid, jsonb)'::regprocedure);
revoke all on function app.worker_listing_result_pre2890(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.worker_listing_result_pre2890(uuid, jsonb) to service_role;

-- 2. once: the real photos already taken off the site
do $$
declare n integer;
begin
  with x as (
    update vehicle_photos ph set is_public = true
     where not ph.is_public and not coalesce(ph.ai_generated, false) and ph.replaced_at is null
       and ph.status = 'approved' and ph.processed_path is not null and ph.plate_status in ('covered', 'not_visible')
       and coalesce(ph.r45 ->> 'state', '') = 'flagged'
       and coalesce((select st.is_public from listing_shot_types st where st.code = ph.shot_type), false)
    returning 1)
  select count(*) into n from x;
  raise notice '2890: % real photo(s) put back on the site', n;
end $$;

-- 3. the first outside photo leads, wherever it sits: 2841 looked only at the single first photo (the cover, else the
--    lowest sort order) and, when that one was an inside photo, showed no cover and no gallery at all, though the car had
--    outside photos further down. Now the cover is the first outside photo by the standard order (2841's photo_rank), and
--    the gallery is put in that order (outside, then inside, then the rest), so it is empty only when the car has no
--    outside photo at all.
create or replace function app.cover_photo(p_vehicle uuid) returns vehicle_photos
language sql stable security definer set search_path = public, app as $$
  select ph.* from vehicle_photos ph join listing_shot_types st on st.code = ph.shot_type
   where ph.vehicle_id = p_vehicle and ph.replaced_at is null and ph.status = 'approved' and ph.is_public and st.is_public and ph.processed_path is not null
     and app.photo_is_exterior(ph.shot_type)
   order by app.photo_rank(ph.shot_type), ph.is_cover desc, ph.sort_order, ph.created_at limit 1
$$;

create or replace function app.public_listing_photos(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with ph as (select coalesce(app.public_listing_photos_pre2841(p_vehicle), '[]'::jsonb) as a),
       s as (select coalesce(jsonb_agg(t.e order by app.photo_rank(t.e ->> 'shot'), t.n), '[]'::jsonb) as a
               from ph, jsonb_array_elements(ph.a) with ordinality t(e, n))
  select case when jsonb_array_length(s.a) = 0 or app.photo_is_exterior(s.a -> 0 ->> 'shot')
                   or not exists (select 1 from listing_shot_types st where st.code = s.a -> 0 ->> 'shot') then s.a else '[]'::jsonb end
    from s
$$;

-- the flag of Admin > Cars and the publish guard: an inside photo is "first" only when the car has no outside photo at all
create or replace function app.vehicle_primary_state(p_vehicle uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case when (select c.id from app.cover_photo(p_vehicle) c) is not null then 'exterior'
              when (select c.id from app.cover_photo_pre2841(p_vehicle) c) is null then 'none'
              else 'not_exterior' end
$$;

-- a flagged real photo still on the site is that angle's photo: no generated view is made beside it (two of one angle)
create or replace function app.photo_r45_missing(p_vehicle uuid) returns setof text
language sql stable security definer set search_path = public, app as $$
  select a from unnest(app.photo_r45_angles()) with ordinality u(a, k)
   where not exists (select 1 from vehicle_photos ph where ph.vehicle_id = p_vehicle and ph.shot_type = u.a and ph.replaced_at is null
                       and ph.status <> 'rejected'
                       and (coalesce(ph.r45 ->> 'state', '') <> 'flagged' or (ph.is_public and not coalesce(ph.ai_generated, false))))
   order by k
$$;
