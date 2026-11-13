-- 2690_r43_primary_photo.sql
-- Release 43. The owner: "on the live site some cars show an interior photo as the first photo. The primary (first) photo of
-- every listing must be the exterior shot at the standard angle (the front three-quarter, on the dealership showroom
-- background). The Mercedes CLA had its photos edited by the Cloudflare editor, poorly: re-edit it with Gemini."
--   1. app.photo_rank(shot_type): the one rule. front_left (the standard angle) 0, then front_right, front, rear_left,
--      rear_right, left, right, rear, exterior_more; every other shot (dashboard, seats, trunk, wheel, other detail) 20, so an
--      inside photo is never ahead of an outside one. web/src/lib/photo-order.ts holds the same ranks for code that sorts a list.
--   2. The order is fixed at the source: app.cover_photo (the car's cover; the fallback of the live row) and the site's photo
--      list (app.public_listing_photos_0022, under every wrapper of 0054, 2100, 2200 and 2450) order by the rank first, then
--      the photo marked cover, then sort_order. The OG image, the cards, the feeds and the channels read those lists.
--   3. vehicle_photos.is_cover follows the rule by itself (trigger vehicle_photos_primary_sync): after a photo is added, made,
--      approved, made public, replaced or reordered, the car's best-ranked outside photo is the one marked cover and the
--      others are not. Every surface that reads is_cover (the cards, the fleet board, the tracker, the live map, the home
--      hero, the review, the lettering of the model name on the cover) therefore agrees with the site. A car with no outside
--      photo is left as it is.
--   4. The data: every car whose first photo was not its best outside photo is put right (is_cover, sort_order), once.
--   5. app.vehicle_primary_state(vehicle): exterior, not_exterior (the photo the site shows first is an inside one: its best
--      outside photo is not on the site yet, or there is none) or none. Admin > Cars (admin_read 'vehicles') carries it
--      (primary_photo, primary_not_exterior); the list has the flag and the filter "Primary photo is not exterior".
--   6. ops_do photo_showroom {action gemini; vehicle or photo}: "Redo photos with Gemini". Every outside photo of the car is
--      made again in the showroom with the image model (Gemini) as the only engine: the job carries engine gemini and the
--      worker (features/listing/worker.ts) fails it, leaving the photo as it was, when Gemini is not set up, refuses, is over
--      its daily limit or changes the car: never the free showroom, never the Cloudflare composite, never the unprocessed
--      original (those stay private). Refused at once when Program settings' listing_showroom_ai is off.
-- SCHEMA_MARKER 2690. No applied migration is edited: functions are patched in place (pg_temp.patch_fn) or wrapped.
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
  if position(p_old in d) = 0 then raise exception '2690: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the rule
create function app.photo_rank(p_shot text) returns integer
language sql immutable parallel safe as $$
  select case when p_shot like 'cover\_%' then -1
              else coalesce(array_position(array['front_left', 'front_right', 'front', 'rear_left', 'rear_right', 'left', 'right', 'rear', 'exterior_more'], p_shot) - 1, 20) end
$$;
comment on function app.photo_rank(text) is 'Which photo of a car is first (2690): the front three-quarter (front_left) 0, the other outside shots 1 to 8, anything inside or a detail 20; a made cover (cover_...) -1. Same ranks as web/src/lib/photo-order.ts.';
revoke all on function app.photo_rank(text) from public, anon, authenticated;
grant execute on function app.photo_rank(text) to service_role;

-- the car's best outside photo (for the cover mark): the rank, then the photo marked cover, then one that is on the site, then the order
create function app.primary_photo(p_vehicle uuid) returns vehicle_photos
language sql stable security definer set search_path = public, app as $$
  select ph.* from vehicle_photos ph
   where ph.vehicle_id = p_vehicle and ph.replaced_at is null and ph.status <> 'rejected' and app.photo_rank(ph.shot_type) between 0 and 8
   order by app.photo_rank(ph.shot_type), (ph.status = 'approved' and ph.is_public and ph.processed_path is not null) desc, ph.is_cover desc, ph.sort_order, ph.created_at, ph.id
   limit 1
$$;
comment on function app.primary_photo(uuid) is 'The car''s best outside photo, the one marked cover (2690); no row when the car has no outside photo.';
revoke all on function app.primary_photo(uuid) from public, anon, authenticated;
grant execute on function app.primary_photo(uuid) to service_role;

-- ================================================================ 2. the order at the source
select pg_temp.patch_fn('app.cover_photo(uuid)'::regprocedure,
  'order by ph.is_cover desc, ph.sort_order, ph.created_at limit 1',
  'order by app.photo_rank(ph.shot_type), ph.is_cover desc, ph.sort_order, ph.created_at, ph.id limit 1');
select pg_temp.patch_fn('app.public_listing_photos_0022(uuid)'::regprocedure,
  'order by ph.is_cover desc, ph.sort_order), ''[]''::jsonb)',
  'order by app.photo_rank(st.code), ph.is_cover desc, ph.sort_order, ph.created_at, ph.id), ''[]''::jsonb)');

-- ================================================================ 3. is_cover follows the rule
create function app.vehicle_photos_primary_sync() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare v_primary uuid := (app.primary_photo(new.vehicle_id)).id;
begin
  -- a car with no outside photo keeps its marks; the second round (the update below) finds nothing to change
  if v_primary is not null then
    update vehicle_photos x set is_cover = (x.id = v_primary)
     where x.vehicle_id = new.vehicle_id and x.is_cover is distinct from (x.id = v_primary);
  end if;
  return null;
end $$;
revoke all on function app.vehicle_photos_primary_sync() from public, anon, authenticated;
grant execute on function app.vehicle_photos_primary_sync() to service_role;
drop trigger if exists vehicle_photos_primary_sync on vehicle_photos;
create trigger vehicle_photos_primary_sync after insert or update of is_cover, shot_type, status, is_public, processed_path, replaced_at, sort_order
  on vehicle_photos for each row execute function app.vehicle_photos_primary_sync();

-- ================================================================ 4. the data, once
-- sort_order: a car whose first photo (by sort_order) is not its best outside photo is numbered again by the rule
with cars as (
  select ph.vehicle_id from vehicle_photos ph
   where ph.replaced_at is null and app.photo_rank(ph.shot_type) between 0 and 8 group by ph.vehicle_id
), bad as (
  select c.vehicle_id from cars c
   where (select x.id from vehicle_photos x where x.vehicle_id = c.vehicle_id and x.replaced_at is null order by x.sort_order, x.created_at, x.id limit 1)
         is distinct from (app.primary_photo(c.vehicle_id)).id
), numbered as (
  select ph.id, row_number() over (partition by ph.vehicle_id order by app.photo_rank(ph.shot_type), ph.is_cover desc, ph.sort_order, ph.created_at, ph.id) - 1 as n
    from vehicle_photos ph join bad b on b.vehicle_id = ph.vehicle_id where ph.replaced_at is null
)
update vehicle_photos ph set sort_order = nu.n from numbered nu where nu.id = ph.id and ph.sort_order is distinct from nu.n;
-- is_cover: the best outside photo, for every car that has one
update vehicle_photos ph set is_cover = (ph.id = (app.primary_photo(ph.vehicle_id)).id)
 where ph.vehicle_id in (select x.vehicle_id from vehicle_photos x where x.replaced_at is null and app.photo_rank(x.shot_type) between 0 and 8)
   and ph.is_cover is distinct from (ph.id = (app.primary_photo(ph.vehicle_id)).id);

-- ================================================================ 5. the flag in Admin > Cars
create function app.vehicle_primary_state(p_vehicle uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case when cp.id is null then 'none' when app.photo_rank(cp.shot_type) between 0 and 8 then 'exterior' else 'not_exterior' end
    from app.cover_photo(p_vehicle) cp
$$;
comment on function app.vehicle_primary_state(uuid) is 'The photo the site shows first for a car (2690): exterior, not_exterior (an inside photo is shown first) or none.';
revoke all on function app.vehicle_primary_state(uuid) from public, anon, authenticated;
grant execute on function app.vehicle_primary_state(uuid) to service_role;

alter function app.admin_read(uuid, text, jsonb) rename to admin_read_pre2690;
create function app.admin_read(p_admin uuid, p_what text, p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb := app.admin_read_pre2690(p_admin, p_what, p);
begin
  if p_what = 'vehicles' and jsonb_typeof(v_out) = 'array' then
    return (select coalesce(jsonb_agg(e.x || jsonb_build_object('primary_photo', s.state, 'primary_not_exterior', s.state = 'not_exterior') order by e.ord), '[]'::jsonb)
              from jsonb_array_elements(v_out) with ordinality e(x, ord)
              cross join lateral (select app.vehicle_primary_state((e.x ->> 'id')::uuid) as state) s);
  end if;
  return v_out;
end $$;
select pg_temp.copy_grants('app.admin_read(uuid, text, jsonb)'::regprocedure, 'app.admin_read_pre2690(uuid, text, jsonb)'::regprocedure);

-- ================================================================ 6. "Redo photos with Gemini"
select pg_temp.patch_fn('app.photo_showroom(uuid, jsonb)'::regprocedure,
  'if v_action not in (''apply'', ''redo'', ''undo'') then raise exception ''Unknown showroom action'' using errcode = ''22023''; end if;',
  'if v_action not in (''apply'', ''redo'', ''undo'', ''gemini'') then raise exception ''Unknown showroom action'' using errcode = ''22023''; end if;
  if v_action = ''gemini'' and not coalesce((app.settings()).listing_showroom_ai, false) then
    raise exception ''Gemini is switched off (Program settings, listing showroom AI). Switch it on first: the photos were not changed.'' using errcode = ''23514'';
  end if;');
select pg_temp.patch_fn('app.photo_showroom(uuid, jsonb)'::regprocedure,
  'and (v_action = ''redo'' or coalesce(x.scene, ''studio'')',
  'and (v_action in (''redo'', ''gemini'') or coalesce(x.scene, ''studio'')');
select pg_temp.patch_fn('app.photo_showroom(uuid, jsonb)'::regprocedure,
  'perform app.photo_scene_queue(p_by, r.id, ''showroom'', case when v_action = ''redo'' then ''showroom_redo'' else ''showroom'' end);',
  'perform app.photo_scene_queue(p_by, r.id, ''showroom'', case when v_action in (''redo'', ''gemini'') then ''showroom_redo'' else ''showroom'' end);
    -- 2690: Gemini is the only engine of this step (the worker fails it, leaving the photo as it was, rather than fall back)
    if v_action = ''gemini'' then
      update listing_jobs j set input = j.input || jsonb_build_object(''engine'', ''gemini'')
       where j.vehicle_photo_id = r.id and j.kind = ''process_photo'' and j.status = ''queued'';
    end if;');
