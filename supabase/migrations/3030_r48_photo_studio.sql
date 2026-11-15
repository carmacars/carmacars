-- 3030 (release 48, photo standard r48.2): one studio set per car, the same on every surface, and a pipeline that finishes.
-- The owner (Nov 15): the first photos on the site are not in the same angle; some cards show a photo without its background
-- changed while the car page shows the edited ones; not every angle was generated. "The AI thing with Gemini is supposed to
-- be able to generate the photos of the vehicles in every single angle when the pictures aren't available. And even when
-- they are available, if they're not exactly in the correct angle ... it should just generate it to be in that angle so that
-- all of the photos look like they've been taken exactly the same way in like a studio." Then: the covers in the exact angle
-- and direction of the sample covers, a realistic background that really changes, the same cover everywhere, and the
-- Marketplace set made from the same photos (with lifestyle shots).
--
-- Why nothing was generated (live: 0 AI views in the fleet, most cars never run):
--   a. app.job_photo_r48 queues only while fewer than listing_photo_r45_batch (12) photo steps wait; 12 older steps of one car
--      waited forever, so the job never queued anything. Their check call failed (the worker answered "the check could not
--      be asked now", filed as a quota wait: queued again every 10 minutes, no try counted, never ending).
--   b. Gemini refused calls from some of Cloudflare's data centres ("User location is not supported for the API use"); that
--      was filed as a refusal of the photo. The web now sends such a call again through the company server's relay
--      (web/src/integrations/photos/gemini-route.ts, Kong /gemini/), and the worker files a failure that is not the photo's
--      (location, time-out, network, model) as wait "retry".
-- What changes:
--   1. Scenes: Program settings listing_photo_scene (the fleet's scene, default showroom_dark: the dark dealership with the
--      CarmaCars sign; on the cover also the model's name on the wall behind the car) and vehicles.photo_scene (a car's own
--      choice): any code of marketing_scenes (highway, brick building, ...). The background plates are per scene and family.
--   2. Spec r48.2: every r48 view made again (the version on the site stays until the new one passes). The job context adds
--      the scene, the scene's plate and the tries made; a car with no photo gets its outside views from the stock photo of
--      its model.
--   3. The job: the cars with the most views first (app.fleet_trend), then the published ones, then the newest listed; only the steps due within 10
--      minutes count against the batch; on by default. Wait "retry": queued again after 10 minutes, doubling up to 6 hours,
--      no try counted; after 8 such waits it counts as a try (so a photo that always fails is flagged, never stuck).
--   4. One source of truth for public photos: once a car's generated front three-quarter is approved, its public photos are
--      its generated set only, in the standard order, the front three-quarter the cover (no real, edited or sample photo
--      mixed in, no made cover in front); the listing row's cover is the gallery's first photo, so the home page, search,
--      cards, the car page, partner feeds and the sitemap's image tags show the same photo. The sitemap reads the gallery.
--   5. Admin: per car the standard set beside the originals of each angle (ops_read photo_r48_set), make one angle again,
--      take a generated view off the site or put it back (ops_do photo_r48_angle), the car's scene (ops_do photo_r48_scene);
--      the plates per scene (photo_r48_plate {scene}); the fleet's progress with the days left at the daily limit.
--   6. The connector's photo_standard: spec r48.2, auto is the r48 job's switch, each car's cover is "studio" when it is the
--      generated front three-quarter, its scene and its generated set; totals count studio covers.
--   7. Marketing set (Marketplace, social): made from the studio set when the car has one (marketing-studio.ts): each
--      outside view moved into the scene; up to 3 lifestyle shots (p.lifestyle, 2 by default), marked AI-generated.
-- SCHEMA_MARKER 3030. docs/changes/2026-11-14-r48-photo-studio.md.
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
  if position(p_old in d) = 0 then raise exception '3030: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. scenes, plates per scene
alter table program_settings add column if not exists listing_photo_scene text not null default 'showroom_dark'
  check (listing_photo_scene ~ '^[a-z0-9_]{2,40}$');
comment on column program_settings.listing_photo_scene is 'Listing photos (3030): the scene every car''s studio set stands in unless the car has its own (a code of marketing_scenes; showroom_dark, the dark dealership with the CarmaCars sign, by default).';
alter table vehicles add column if not exists photo_scene text check (photo_scene is null or photo_scene ~ '^[a-z0-9_]{2,40}$');
comment on column vehicles.photo_scene is 'Listing photos (3030): this car''s scene for its studio set (a code of marketing_scenes); null: Program settings listing_photo_scene.';
-- on by default (the owner: turn the automatic run on)
alter table program_settings alter column listing_photo_r48_auto set default true;
update program_settings set listing_photo_r48_auto = true where not listing_photo_r48_auto;

alter table listing_r48_plates add column if not exists scene text not null default 'showroom_dark' check (scene ~ '^[a-z0-9_]{2,40}$');
comment on column listing_r48_plates.scene is 'The scene of the plate (3030): showroom_dark (the dark dealership with the CarmaCars sign) or another code of marketing_scenes.';
-- the plates made before were bright showrooms (the look the owner turned down): kept under that scene, never the default
update listing_r48_plates set scene = 'showroom_bright';
alter table listing_r48_plates drop constraint listing_r48_plates_pkey;
alter table listing_r48_plates add primary key (scene, family);

alter table vehicle_marketing_photos add column if not exists lifestyle text check (lifestyle is null or lifestyle ~ '^[a-z_]{2,20}$');
alter table vehicle_marketing_photos add column if not exists ai_generated boolean not null default false;
comment on column vehicle_marketing_photos.lifestyle is 'A lifestyle shot (3030): the pose (beside, door, driver, walking) of the adult model added by Gemini; null for the car alone.';
-- one marketing step runs at a time per listing (listing_jobs_one_open): each copy keeps its step's input and the next is
-- queued when one finishes (app.marketing_next). Before, every copy of a set pointed at the one step and the rest never ran.
alter table vehicle_marketing_photos add column if not exists job_input jsonb check (job_input is null or jsonb_typeof(job_input) = 'object');
comment on column vehicle_marketing_photos.job_input is 'The marketing step of this copy (3030), queued when the step before it finishes (app.marketing_next).';
comment on column vehicle_marketing_photos.ai_generated is 'Made by Gemini from the car''s studio set (3030): shown as AI-generated to staff.';

-- the scene of a car: its entry of marketing_scenes (with the path of its photo of the real place), the dark dealership when
-- the code is unknown
create function app.photo_r48_scene(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with c as (select coalesce((select v.photo_scene from vehicles v where v.id = p_vehicle), (app.settings()).listing_photo_scene, 'showroom_dark') code)
  select coalesce(
    (select jsonb_build_object('code', x ->> 'code', 'label', x ->> 'label', 'place', x ->> 'place', 'reference_path', app.marketing_scene_path(x))
       from c, jsonb_array_elements((app.settings()).marketing_scenes) x where x ->> 'code' = c.code limit 1),
    jsonb_build_object('code', 'showroom_dark', 'label', 'Dark showroom', 'place', null, 'reference_path', null))
$$;
create function app.photo_r48_scene_code(p_vehicle uuid) returns text
language sql stable security definer set search_path = public, app as $$ select app.photo_r48_scene(p_vehicle) ->> 'code' $$;

-- ================================================================ 2. the standard r48.2, the job context
select pg_temp.patch_fn('app.photo_r48_spec()'::regprocedure, $q$select 'r48.1'::text$q$, $q$select 'r48.2'::text$q$);
-- every view made again to r48.2 (the version on the site stays until the new one passes)
update vehicle_photos set r45 = coalesce(r45, '{}'::jsonb) - 'reasons' - 'why' || jsonb_build_object('state', 'redo', 'tries', 0, 'at', now())
 where r48 and replaced_at is null and coalesce(r45 ->> 'state', '') in ('done', 'flagged');

select pg_temp.patch_fn('app.listing_job_context(uuid)'::regprocedure,
  $q$'plate', (select p.path from listing_r48_plates p where p.family = v_fam),$q$,
  $q$'plate', (select p.path from listing_r48_plates p where p.family = v_fam and p.scene = app.photo_r48_scene_code(ph.vehicle_id)),
    'scene', app.photo_r48_scene(ph.vehicle_id), 'tries', coalesce((ph.r45 ->> 'tries')::integer, 0),$q$);

-- a car with no photo: its outside views from the stock photo of its model
select pg_temp.patch_fn('app.photo_r48_queue(uuid, uuid, text, boolean)'::regprocedure,
  $q$if jsonb_array_length(v_refs) = 0 then return null; end if;$q$,
  $q$if jsonb_array_length(v_refs) = 0 and (not app.photo_is_exterior(p_shot) or app.photo_r48_stock(p_vehicle) is null) then return null; end if;$q$);

-- a plate the worker made is kept under its scene
select pg_temp.patch_fn('app.worker_listing_result(uuid, jsonb)'::regprocedure,
  $q$insert into listing_r48_plates (family, path, source, model, "check") values (v ->> 'family', v ->> 'path', 'gemini', left(v ->> 'model', 80), case when jsonb_typeof(v -> 'check') = 'object' then v -> 'check' end)
    on conflict (family) do nothing;$q$,
  $q$insert into listing_r48_plates (scene, family, path, source, model, "check") values (coalesce(nullif(v ->> 'scene', ''), 'showroom_dark'), v ->> 'family', v ->> 'path', 'gemini', left(v ->> 'model', 80), case when jsonb_typeof(v -> 'check') = 'object' then v -> 'check' end)
    on conflict (scene, family) do nothing;$q$);

-- ================================================================ 3. the worker's "retry": a growing wait, never stuck
alter function app.worker_listing_result(uuid, jsonb) rename to worker_listing_result_pre3030;
create function app.worker_listing_result(p_job uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare j listing_jobs; v_waits integer; r jsonb;
begin
  select * into j from listing_jobs where id = p_job;
  if coalesce(p #>> '{output,r45,wait}', '') <> 'retry' then
    r := app.worker_listing_result_pre3030(p_job, p);
    if j.kind = 'marketing_photo' then perform app.marketing_next(j.vehicle_id); end if;
    return r;
  end if;
  v_waits := coalesce((select (ph.r45 ->> 'waits')::integer from vehicle_photos ph where ph.id = j.vehicle_photo_id), 0) + 1;
  if j.kind <> 'photo_r45' or v_waits > 8 then
    -- the eighth wait in a row counts as a try (filed as a refusal)
    update vehicle_photos set r45 = coalesce(r45, '{}'::jsonb) || jsonb_build_object('waits', 0) where id = j.vehicle_photo_id;
    return app.worker_listing_result_pre3030(p_job, jsonb_set(p, '{output,r45}', (p #> '{output,r45}') - 'wait'));
  end if;
  r := app.worker_listing_result_pre3030(p_job, jsonb_set(p, '{output,r45,wait}', '"quota"'));
  update listing_jobs set next_attempt_at = now() + least(interval '10 minutes' * power(2, v_waits - 1), interval '6 hours')
   where vehicle_photo_id = j.vehicle_photo_id and kind = 'photo_r45' and status = 'queued';
  update vehicle_photos set r45 = coalesce(r45, '{}'::jsonb) || jsonb_build_object('waits', v_waits, 'waiting', 'retry') where id = j.vehicle_photo_id;
  return r;
end $$;
select pg_temp.copy_grants('app.worker_listing_result(uuid, jsonb)'::regprocedure, 'app.worker_listing_result_pre3030(uuid, jsonb)'::regprocedure);

-- ================================================================ 4. the job: most viewed first, only due steps fill the batch
alter function app.photo_r48_cars() rename to photo_r48_cars_pre3030;
create function app.photo_r48_cars() returns table (vehicle_id uuid, listed_at timestamptz)
language sql stable security definer set search_path = public, app as $$
  select v.id, coalesce((select max(i.created_at) from listing_intakes i where i.vehicle_id = v.id), v.created_at)
    from vehicles v
   where not v.is_sample and v.retired_at is null
     and (exists (select 1 from vehicle_photos ph where ph.vehicle_id = v.id and not ph.ai_generated and ph.replaced_at is null and ph.status <> 'rejected')
          or exists (select 1 from condition_reports r join condition_report_photos p on p.condition_report_id = r.id
                      where r.vehicle_id = v.id and app.photo_r48_handover_shot(p.shot, p.angle) is not null)
          or (exists (select 1 from vehicle_listings l where l.vehicle_id = v.id and l.status in ('published', 'paused')) and app.photo_r48_stock(v.id) is not null))
   order by coalesce((select t.score from app.fleet_trend t where t.vehicle_id = v.id), 0) desc,
            exists (select 1 from vehicle_listings l where l.vehicle_id = v.id and l.status = 'published') desc, 2 desc, v.id
$$;

-- the photo steps due now or soon (a step waiting for tomorrow or for a long retry does not hold the batch)
create function app.photo_r48_due() returns integer
language sql stable security definer set search_path = public, app as $$
  select count(*)::integer from listing_jobs j
   where j.kind = 'photo_r45' and (j.status = 'running' or (j.status = 'queued' and j.next_attempt_at <= now() + interval '10 minutes'))
$$;

alter function app.job_photo_r48() rename to job_photo_r48_pre3030;
create function app.job_photo_r48() returns text
language plpgsql security definer set search_path = public, app as $$
declare ps program_settings := app.settings(); v_room integer; r record; n integer := 0; v_pass integer; v_shot text; v_cars integer := 0; v_car boolean; v_due integer := app.photo_r48_due();
begin
  -- a marketing set whose step was lost goes on
  perform app.marketing_next(x.vehicle_id) from (select distinct m.vehicle_id from vehicle_marketing_photos m where m.status = 'queued' and m.job_id is null and m.job_input is not null) x;
  if not coalesce(ps.listing_photo_r48_auto, true) or not coalesce(ps.listing_showroom_ai, false) then return 'off'; end if;
  v_room := least(greatest(coalesce(ps.listing_photo_r45_batch, 12) - v_due, 0),
                  greatest(app.photo_gemini_left(coalesce(ps.listing_photo_r45_reserve, 50)) - v_due, 0));
  if v_room = 0 then return 'full or waiting for Gemini'; end if;
  -- the front three-quarter of every car first (the cover), then the other angles in the site's order
  for v_pass in 1..2 loop
    for r in select c.vehicle_id from app.photo_r48_cars() c loop
      exit when n >= v_room;
      v_car := false;
      foreach v_shot in array case when v_pass = 1 then array['front_left'] else (app.photo_r45_angles())[2:] end loop
        exit when n >= v_room;
        if app.photo_r48_queue(null, r.vehicle_id, v_shot, false) is not null then n := n + 1; v_car := true; end if;
      end loop;
      if v_car then v_cars := v_cars + 1; end if;
    end loop;
  end loop;
  return format('%s r48 view(s) queued (%s car step(s))', n, v_cars);
end $$;

-- the steps that waited on the check with no end (2840's quota wait, every 10 minutes): due now, their waits counted
update listing_jobs j set next_attempt_at = now()
 where j.kind = 'photo_r45' and j.status = 'queued' and coalesce(j.error, '') like 'Waiting for Gemini%';

-- ================================================================ 5. one source of truth for the public photos
-- the car's approved generated front three-quarter (its studio cover), null when it has none yet
create function app.photo_r48_cover(p_vehicle uuid) returns vehicle_photos
language sql stable security definer set search_path = public, app as $$
  select ph.* from vehicle_photos ph
   where ph.vehicle_id = p_vehicle and ph.r48 and ph.shot_type = 'front_left' and ph.replaced_at is null and ph.status = 'approved' and ph.is_public
     and ph.processed_path is not null
   order by ph.created_at desc limit 1
$$;

alter function app.public_listing_photos(uuid) rename to public_listing_photos_pre3030;
create function app.public_listing_photos(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when (app.photo_r48_cover(p_vehicle)).id is null then app.public_listing_photos_pre3030(p_vehicle)
    else (select coalesce(jsonb_agg(jsonb_build_object('path', ph.processed_path, 'variants', coalesce(ph.variants, '[]'::jsonb),
                   'alt', coalesce(nullif(ph.alt_text, ''), app.vehicle_name(p_vehicle) || ', ' || lower(st.label)),
                   'width', ph.width, 'height', ph.height, 'shot', ph.shot_type, 'label', st.label, 'is_cover', ph.shot_type = 'front_left', 'generated', true)
                   order by array_position(app.photo_r45_angles(), ph.shot_type)), '[]'::jsonb)
            from (select distinct on (x.shot_type) x.* from vehicle_photos x
                   where x.vehicle_id = p_vehicle and x.r48 and x.replaced_at is null and x.status = 'approved' and x.is_public and x.processed_path is not null
                   order by x.shot_type, x.created_at desc) ph
            join listing_shot_types st on st.code = ph.shot_type) end
$$;
select pg_temp.copy_grants('app.public_listing_photos(uuid)'::regprocedure, 'app.public_listing_photos_pre3030(uuid)'::regprocedure);

-- the listing row (the listing cache, the fleet, search, the home page, cards): its cover is the gallery's first photo
alter function app.public_listing_row_live(uuid) rename to public_listing_row_live_pre3030;
create function app.public_listing_row_live(p_vehicle uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare r jsonb := app.public_listing_row_live_pre3030(p_vehicle); g jsonb;
begin
  if r is null then return null; end if;
  g := app.public_listing_photos(p_vehicle) -> 0;
  if g is not null and nullif(g ->> 'path', '') is not null and not coalesce((g ->> 'sample')::boolean, false) then
    r := r || jsonb_build_object('cover', jsonb_build_object('path', g ->> 'path', 'variants', coalesce(g -> 'variants', '[]'::jsonb),
                                   'alt', coalesce(g ->> 'alt', r #>> '{cover,alt}', app.vehicle_name(p_vehicle))), 'sample_photos', false);
  end if;
  return r;
end $$;
select pg_temp.copy_grants('app.public_listing_row_live(uuid)'::regprocedure, 'app.public_listing_row_live_pre3030(uuid)'::regprocedure);

alter function app.public_listing_row(uuid) rename to public_listing_row_pre3030;
create function app.public_listing_row(p_vehicle uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare r jsonb := app.public_listing_row_pre3030(p_vehicle); c vehicle_photos;
begin
  if r is null then return null; end if;
  -- the studio cover replaces a made cover (with a model, the flyer) and any older cover
  c := app.photo_r48_cover(p_vehicle);
  if c.id is not null then
    r := r || jsonb_build_object('cover', jsonb_build_object('path', c.processed_path, 'variants', coalesce(c.variants, '[]'::jsonb),
                                   'alt', coalesce(nullif(c.alt_text, ''), r #>> '{cover,alt}', app.vehicle_name(p_vehicle))), 'sample_photos', false);
  end if;
  return r;
end $$;
select pg_temp.copy_grants('app.public_listing_row(uuid)'::regprocedure, 'app.public_listing_row_pre3030(uuid)'::regprocedure);

-- the sitemap's image tags: the gallery itself
select pg_temp.patch_fn('app.public_sitemap_rows()'::regprocedure,
  $q$case when s.kind = 'car' then (select coalesce(jsonb_agg(jsonb_build_object('loc', ph.processed_path, 'title', ph.alt_text) order by ph.is_cover desc, st.seq), '[]'::jsonb)
                                         from vehicle_listings l join vehicle_photos ph on ph.vehicle_id = l.vehicle_id
                                         left join listing_shot_types st on st.code = ph.shot_type
                                        where '/cars/' || l.slug = s.path and ph.is_public and ph.status = 'approved' and ph.replaced_at is null
                                          and ph.processed_path is not null) end$q$,
  $q$case when s.kind = 'car' then (select coalesce(jsonb_agg(jsonb_build_object('loc', e ->> 'path', 'title', e ->> 'alt') order by k), '[]'::jsonb)
                                         from (select l.vehicle_id from vehicle_listings l where '/cars/' || l.slug = s.path limit 1) l,
                                              jsonb_array_elements(app.public_listing_photos(l.vehicle_id)) with ordinality t(e, k)
                                        where nullif(e ->> 'path', '') is not null and not coalesce((e ->> 'sample')::boolean, false)) end$q$);

-- the listing cache holds the new covers now
do $$
declare v uuid;
begin
  for v in select distinct ph.vehicle_id from vehicle_photos ph where ph.r48 and ph.status = 'approved' and ph.is_public loop
    perform app.listing_cache_refresh(v);
  end loop;
exception when undefined_function then null;
end $$;

-- ================================================================ 6. Admin: the set of a car, one angle, the scene, the plates
-- per car: the standard set beside the originals of each angle
create function app.photo_r48_set(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_vehicle uuid := nullif(p ->> 'vehicle', '')::uuid;
begin
  if not app.photo_r45_may(p_by) then raise exception 'An Admin or fleet sees the photo standard' using errcode = '42501'; end if;
  if v_vehicle is null or not exists (select 1 from vehicles where id = v_vehicle) then raise exception 'Unknown car' using errcode = 'P0002'; end if;
  return jsonb_build_object('vehicle', v_vehicle, 'name', app.vehicle_name(v_vehicle), 'spec', app.photo_r48_spec(),
    'scene', app.photo_r48_scene_code(v_vehicle), 'own_scene', (select v.photo_scene from vehicles v where v.id = v_vehicle),
    'fleet_scene', (app.settings()).listing_photo_scene,
    'scenes', coalesce((select jsonb_agg(jsonb_build_object('code', x ->> 'code', 'label', x ->> 'label')) from jsonb_array_elements((app.settings()).marketing_scenes) x), '[]'::jsonb),
    'studio_cover', (app.photo_r48_cover(v_vehicle)).id is not null,
    'angles', (select jsonb_agg(jsonb_build_object('shot', a, 'label', coalesce(st.label, a),
        'generated', (select jsonb_build_object('id', g.id, 'path', g.processed_path, 'state', g.r45 ->> 'state', 'public', g.is_public and g.status = 'approved',
                        'why', g.r45 ->> 'why', 'reasons', g.r45 -> 'reasons', 'tries', g.r45 -> 'tries', 'at', g.r45 ->> 'at', 'waiting', g.r45 ->> 'waiting',
                        'scene', g.showroom ->> 'scene', 'hidden', coalesce((g.r45 ->> 'hidden')::boolean, false))
                        from vehicle_photos g where g.vehicle_id = v_vehicle and g.r48 and g.shot_type = a and g.replaced_at is null order by g.created_at desc limit 1),
        'originals', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'path', o.processed_path, 'public', o.is_public and o.status = 'approved', 'ai', o.ai_generated)
                                order by o.is_cover desc, o.sort_order, o.created_at)
                                from vehicle_photos o where o.vehicle_id = v_vehicle and not o.r48 and o.shot_type = a and o.replaced_at is null and o.status <> 'rejected'), '[]'::jsonb))
        order by k)
      from unnest(app.photo_r45_angles()) with ordinality u(a, k) left join listing_shot_types st on st.code = u.a));
end $$;

-- one angle: redo (made again; the version on the site stays until the new one passes), hide (taken off the site), show
-- (a made view put back on the site)
create function app.photo_r48_angle(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_vehicle uuid := nullif(p ->> 'vehicle', '')::uuid; v_shot text := p ->> 'shot'; v_do text := coalesce(p ->> 'action', 'redo'); ph vehicle_photos; v_id uuid;
begin
  if not app.photo_r45_may(p_by) then raise exception 'An Admin or fleet changes the photo standard' using errcode = '42501'; end if;
  if v_vehicle is null or not (coalesce(v_shot, '') = any (app.photo_r45_angles())) then raise exception 'Choose the car and one of the standard angles' using errcode = '22023'; end if;
  if v_do not in ('redo', 'hide', 'show') then raise exception 'redo, hide or show' using errcode = '22023'; end if;
  if v_do = 'redo' then
    v_id := app.photo_r48_queue(p_by, v_vehicle, v_shot, true);
    if v_id is null then raise exception 'This angle cannot be made now: it is being made, or the car has no photo to make it from' using errcode = '23514'; end if;
    update listing_jobs set next_attempt_at = now() - interval '1 minute' where vehicle_photo_id = v_id and kind = 'photo_r45' and status = 'queued';
    return jsonb_build_object('queued', v_id);
  end if;
  select * into ph from vehicle_photos where vehicle_id = v_vehicle and r48 and shot_type = v_shot and replaced_at is null order by created_at desc limit 1 for update;
  if ph.id is null or ph.processed_path is null then raise exception 'No generated view of this angle yet' using errcode = 'P0002'; end if;
  update vehicle_photos set is_public = (v_do = 'show'), status = case when v_do = 'show' then 'approved' else status end,
         approved_at = case when v_do = 'show' then coalesce(approved_at, now()) else approved_at end,
         r45 = coalesce(r45, '{}'::jsonb) || jsonb_build_object('hidden', v_do = 'hide', 'state', case when v_do = 'show' then 'done' else coalesce(r45 ->> 'state', 'done') end,
               'by', p_by, 'decided_at', now())
   where id = ph.id;
  return jsonb_build_object(v_do, ph.id);
end $$;

-- the car's scene ({vehicle, scene | null}): its outside views made again in it
create function app.photo_r48_set_scene(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_vehicle uuid := nullif(p ->> 'vehicle', '')::uuid; v_scene text := nullif(btrim(coalesce(p ->> 'scene', '')), ''); a text; n integer := 0;
begin
  if not app.photo_r45_may(p_by) then raise exception 'An Admin or fleet changes the photo standard' using errcode = '42501'; end if;
  if v_vehicle is null or not exists (select 1 from vehicles where id = v_vehicle) then raise exception 'Unknown car' using errcode = 'P0002'; end if;
  if v_scene is not null and not exists (select 1 from jsonb_array_elements((app.settings()).marketing_scenes) x where x ->> 'code' = v_scene) then
    raise exception 'Unknown scene: choose one of the list in Program settings' using errcode = '22023';
  end if;
  update vehicles set photo_scene = v_scene where id = v_vehicle;
  foreach a in array app.photo_r45_angles() loop
    if app.photo_is_exterior(a) and app.photo_r48_queue(p_by, v_vehicle, a, true) is not null then n := n + 1; end if;
  end loop;
  return jsonb_build_object('scene', app.photo_r48_scene_code(v_vehicle), 'queued', n);
end $$;

-- the plates per scene: read every scene's; set one from an upload ({scene, family: front|side|rear|all, path}); clear one
alter function app.photo_r48_plates(uuid, jsonb) rename to photo_r48_plates_pre3030;
create function app.photo_r48_plates(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare f text := coalesce(p ->> 'family', ''); v_path text := p ->> 'path'; v_scene text := coalesce(nullif(p ->> 'scene', ''), (app.settings()).listing_photo_scene, 'showroom_dark');
begin
  if p_by is null or not app.user_is_admin(p_by) then raise exception 'An Admin sets the background plates' using errcode = '42501'; end if;
  if v_scene !~ '^[a-z0-9_]{2,40}$' then raise exception 'Unknown scene' using errcode = '22023'; end if;
  if f <> '' then
    if f not in ('front', 'side', 'rear', 'all') then raise exception 'Unknown plate: front, side, rear or all' using errcode = '22023'; end if;
    if coalesce((p ->> 'clear')::boolean, false) then
      delete from listing_r48_plates where scene = v_scene and (family = f or f = 'all');
    else
      if coalesce(v_path, '') !~ '^site/r48/plates/[a-z0-9-]+\.(jpg|png)$' then raise exception 'The plate''s file is not valid' using errcode = '22023'; end if;
      insert into listing_r48_plates (scene, family, path, source, made_by, made_at)
      select v_scene, x, v_path, 'admin', p_by, now() from unnest(case when f = 'all' then array['front', 'side', 'rear'] else array[f] end) x
      on conflict (scene, family) do update set path = excluded.path, source = 'admin', model = null, "check" = null, made_by = p_by, made_at = now();
    end if;
  end if;
  return jsonb_build_object('scene', v_scene, 'fleet_scene', (app.settings()).listing_photo_scene,
    'scenes', coalesce((select jsonb_agg(jsonb_build_object('code', x ->> 'code', 'label', x ->> 'label')) from jsonb_array_elements((app.settings()).marketing_scenes) x), '[]'::jsonb),
    'plates', coalesce((select jsonb_agg(jsonb_build_object('scene', l.scene, 'family', l.family, 'path', l.path, 'source', l.source, 'made_at', l.made_at,
      'issues', l."check" -> 'issues') order by l.scene, array_position(array['front', 'side', 'rear'], l.family)) from listing_r48_plates l), '[]'::jsonb));
end $$;

-- the fleet's progress (Photo standard): views made of all, and the days left at Gemini's daily limit (about 1.4 calls a view
-- with the refusals made again)
alter function app.photo_r45_fleet_read(uuid, jsonb) rename to photo_r45_fleet_read_pre3030;
create function app.photo_r45_fleet_read(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare x jsonb := app.photo_r45_fleet_read_pre3030(p_by, p); ps program_settings := app.settings(); v_all integer; v_done integer; v_flag integer; v_day integer;
begin
  select coalesce(sum((c #>> '{r48,angles}')::integer), 0), coalesce(sum((c #>> '{r48,done}')::integer), 0), coalesce(sum((c #>> '{r48,flagged}')::integer), 0)
    into v_all, v_done, v_flag from jsonb_array_elements(coalesce(x -> 'cars', '[]'::jsonb)) c;
  v_day := greatest(coalesce(ps.listing_showroom_ai_daily, 0) - coalesce(ps.listing_photo_r45_reserve, 50), 1);
  return x || jsonb_build_object('r48_spec', app.photo_r48_spec(), 'scene', ps.listing_photo_scene,
    'r48_fleet', jsonb_build_object('cars', jsonb_array_length(coalesce(x -> 'cars', '[]'::jsonb)), 'views', v_all, 'done', v_done, 'flagged', v_flag,
      'left', greatest(v_all - v_done - v_flag, 0), 'per_day', v_day,
      'days', ceil(greatest(v_all - v_done - v_flag, 0) * 1.4 / v_day)::integer,
      'studio_covers', (select count(*) from jsonb_array_elements(coalesce(x -> 'cars', '[]'::jsonb)) c where (app.photo_r48_cover((c ->> 'id')::uuid)).id is not null)));
end $$;
select pg_temp.copy_grants('app.photo_r45_fleet_read(uuid, jsonb)'::regprocedure, 'app.photo_r45_fleet_read_pre3030(uuid, jsonb)'::regprocedure);

-- ================================================================ 7. the connector's photo_standard
alter function app.photo_standard_car(uuid) rename to photo_standard_car_pre3030;
create function app.photo_standard_car(p_vehicle uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare x jsonb := app.photo_standard_car_pre3030(p_vehicle); c vehicle_photos := app.photo_r48_cover(p_vehicle); g jsonb;
begin
  if x is null then return null; end if;
  g := app.photo_r48_car(p_vehicle);
  return x || jsonb_build_object(
    'cover', case when c.id is not null then 'studio' else x ->> 'cover' end,
    'scene', app.photo_r48_scene_code(p_vehicle),
    'ai_angles', (select count(*) from vehicle_photos ph where ph.vehicle_id = p_vehicle and ph.replaced_at is null and ph.ai_generated
                    and ph.status = 'approved' and ph.is_public and ph.processed_path is not null),
    'ai_angle_shots', coalesce((select jsonb_agg(distinct ph.shot_type) from vehicle_photos ph where ph.vehicle_id = p_vehicle and ph.replaced_at is null and ph.ai_generated
                                  and ph.status = 'approved' and ph.is_public and ph.processed_path is not null), '[]'::jsonb),
    'missing_angles', coalesce((select jsonb_agg(a order by k) from unnest(app.photo_r45_angles()) with ordinality u(a, k)
                                 where not exists (select 1 from vehicle_photos ph where ph.vehicle_id = p_vehicle and ph.r48 and ph.shot_type = a and ph.replaced_at is null
                                                     and ph.status = 'approved' and ph.is_public)), '[]'::jsonb),
    'r48', g || jsonb_build_object('spec', app.photo_r48_spec(),
             'waiting_retry', (select count(*) from vehicle_photos ph where ph.vehicle_id = p_vehicle and ph.r48 and ph.replaced_at is null and ph.r45 ->> 'waiting' = 'retry'),
             'flagged', coalesce((select jsonb_agg(jsonb_build_object('shot', ph.shot_type, 'why', ph.r45 ->> 'why', 'reasons', ph.r45 -> 'reasons')) from vehicle_photos ph
                                   where ph.vehicle_id = p_vehicle and ph.r48 and ph.replaced_at is null and ph.r45 ->> 'state' = 'flagged'), '[]'::jsonb)),
    'last_run', coalesce(g ->> 'last_run', x ->> 'last_run'));
end $$;

alter function app.photo_standard_read(uuid, jsonb) rename to photo_standard_read_pre3030;
create function app.photo_standard_read(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare x jsonb := app.photo_standard_read_pre3030(p_by, p); ps program_settings := app.settings();
begin
  return x || jsonb_build_object('spec', app.photo_r48_spec(), 'r45_spec', x ->> 'spec', 'scene', ps.listing_photo_scene,
    'auto', coalesce(ps.listing_photo_r48_auto, true) and coalesce(ps.listing_showroom_ai, false),
    'gemini', (x -> 'gemini') || jsonb_build_object('due', app.photo_r48_due()),
    'totals', (x -> 'totals') || (select jsonb_build_object('cover_studio', count(*) filter (where c ->> 'cover' = 'studio'),
                 'ai_angles', coalesce(sum((c ->> 'ai_angles')::integer), 0), 'missing_angles', coalesce(sum(jsonb_array_length(c -> 'missing_angles')), 0))
               from jsonb_array_elements(coalesce(x -> 'cars', '[]'::jsonb)) c));
end $$;

-- ================================================================ 8. the marketing set from the studio set, with lifestyle shots
-- the next copy of a car's marketing set to make, when no marketing step of its listing is open (one at a time)
create function app.marketing_next(p_vehicle uuid) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare m vehicle_marketing_photos; v_job uuid; v_intake uuid;
begin
  select * into m from vehicle_marketing_photos x
   where x.vehicle_id = p_vehicle and x.status = 'queued' and x.job_id is null and x.job_input is not null
   order by x.created_at, x.sort limit 1 for update skip locked;
  if m.id is null then return null; end if;
  v_intake := nullif(m.job_input ->> 'intake', '')::uuid;
  if v_intake is null or exists (select 1 from listing_jobs j where j.intake_id = v_intake and j.kind = 'marketing_photo' and j.status in ('queued', 'running')) then return null; end if;
  v_job := app.enqueue_listing_job(v_intake, 'marketing_photo', null, m.job_input - 'intake');
  update vehicle_marketing_photos set job_id = v_job where id = m.id;
  return v_job;
end $$;

alter function app.marketing_set(uuid, jsonb) rename to marketing_set_pre3030;
create function app.marketing_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_vehicle uuid := nullif(p ->> 'vehicle', '')::uuid;
  v_scene text := coalesce(nullif(btrim(p ->> 'scene'), ''), 'mix');
  v_life integer := least(greatest(coalesce(nullif(p ->> 'lifestyle', '')::integer, 2), 0), 3);
  v_scenes jsonb;
  v_set uuid := gen_random_uuid();
  v_intake uuid;
  v_own text;
  r record;
  s jsonb;
  n integer := 0;
  k integer := 0;
  v_id uuid;
  v_job uuid;
  v_model text;
  v_pid uuid; v_pshot text; v_ppath text;
  v_poses text[] := array['beside', 'door', 'driver', 'walking'];
  v_outfits text[] := array['a fitted black cocktail dress with heels and sunglasses', 'an elegant satin evening dress with heels',
                            'a stylish going-out outfit: tailored trousers, a fitted top and a blazer, heels and sunglasses'];
begin
  if not app.marketing_may(p_by) then raise exception 'An Admin, Fleet, customer service or Sales makes marketing photos' using errcode = '42501'; end if;
  if v_vehicle is null or (app.photo_r48_cover(v_vehicle)).id is null then return app.marketing_set_pre3030(p_by, p - 'lifestyle'); end if;
  v_scenes := coalesce((select jsonb_agg(x || jsonb_build_object('reference_path', app.marketing_scene_path(x)))
                          from jsonb_array_elements((app.settings()).marketing_scenes) x
                         where not coalesce((x ->> 'needs_reference')::boolean, false) or app.marketing_scene_path(x) is not null), '[]'::jsonb);
  if v_scene <> 'mix' and not exists (select 1 from jsonb_array_elements(v_scenes) x where x ->> 'code' = v_scene) then
    raise exception 'Unknown scene, or its reference photo is not chosen yet (Settings > Program > Marketing scenes)' using errcode = '22023';
  end if;
  if jsonb_array_length(v_scenes) = 0 then raise exception 'No scene is ready' using errcode = '23514'; end if;
  if exists (select 1 from vehicle_marketing_photos m where m.vehicle_id = v_vehicle and m.status = 'queued' and m.created_at > now() - interval '30 minutes') then
    raise exception 'A marketing set of this car is being made now. Try again in a few minutes.' using errcode = '23514';
  end if;
  v_intake := (select i.id from listing_intakes i where i.vehicle_id = v_vehicle order by i.created_at desc limit 1);
  v_own := app.photo_r48_scene_code(v_vehicle);
  v_model := (select v.model from vehicles v where v.id = v_vehicle);
  -- the car alone: each approved outside view of its studio set, in the standard order (the cover first)
  for r in
    select x.* from (select distinct on (ph.shot_type) ph.id, ph.shot_type, ph.processed_path from vehicle_photos ph
                      where ph.vehicle_id = v_vehicle and ph.r48 and ph.replaced_at is null and ph.status = 'approved' and ph.is_public and ph.processed_path is not null
                        and app.photo_is_exterior(ph.shot_type)
                      order by ph.shot_type, ph.created_at desc) x
     order by array_position(app.photo_r45_angles(), x.shot_type)
  loop
    s := case when v_scene = 'mix' then v_scenes -> (k % jsonb_array_length(v_scenes)) else (select x from jsonb_array_elements(v_scenes) x where x ->> 'code' = v_scene limit 1) end;
    insert into vehicle_marketing_photos (set_id, vehicle_id, photo_id, scene, sort, created_by, ai_generated)
    values (v_set, v_vehicle, r.id, s ->> 'code', k, p_by, true) returning id into v_id;
    update vehicle_marketing_photos set job_input = jsonb_build_object('intake', v_intake, 'marketing', jsonb_build_object(
      'id', v_id, 'vehicle_id', v_vehicle, 'photo_id', r.id, 'scene', s ->> 'code', 'label', s ->> 'label', 'made', s ->> 'made', 'place', s ->> 'place',
      'mask', null, 'adjust', null, 'reference', s ->> 'reference_path',
      'studio', jsonb_build_object('path', r.processed_path, 'shot', r.shot_type, 'cover', r.shot_type = 'front_left', 'model', v_model, 'same', s ->> 'code' = v_own,
        'plate', (select l.path from listing_r48_plates l where l.scene = s ->> 'code' and l.family = app.photo_r48_family(r.shot_type)), 'pose', null, 'outfit', null)))
     where id = v_id;
    k := k + 1; n := n + 1;
  end loop;
  -- the lifestyle shots: the cover's view (the side profile when there is no cover) with one adult model, after the car alone
  for i in 1..v_life loop
    v_pid := null;
    select ph.id, ph.shot_type, ph.processed_path into v_pid, v_pshot, v_ppath from vehicle_photos ph
     where ph.vehicle_id = v_vehicle and ph.r48 and ph.replaced_at is null and ph.status = 'approved' and ph.is_public and ph.processed_path is not null
       and ph.shot_type in ('front_left', 'left')
     order by ph.shot_type = case when i = 4 then 'left' else 'front_left' end desc, ph.created_at desc limit 1;
    exit when v_pid is null;
    s := case when v_scene = 'mix' then v_scenes -> ((k + i) % jsonb_array_length(v_scenes)) else (select x from jsonb_array_elements(v_scenes) x where x ->> 'code' = v_scene limit 1) end;
    insert into vehicle_marketing_photos (set_id, vehicle_id, photo_id, scene, sort, created_by, ai_generated, lifestyle)
    values (v_set, v_vehicle, v_pid, s ->> 'code', 100 + i, p_by, true, v_poses[i]) returning id into v_id;
    update vehicle_marketing_photos set job_input = jsonb_build_object('intake', v_intake, 'marketing', jsonb_build_object(
      'id', v_id, 'vehicle_id', v_vehicle, 'photo_id', v_pid, 'scene', s ->> 'code', 'label', s ->> 'label', 'made', 'photo', 'place', s ->> 'place',
      'mask', null, 'adjust', null, 'reference', s ->> 'reference_path',
      'studio', jsonb_build_object('path', v_ppath, 'shot', v_pshot, 'cover', false, 'model', v_model, 'same', s ->> 'code' = v_own,
        'plate', (select l.path from listing_r48_plates l where l.scene = s ->> 'code' and l.family = app.photo_r48_family(v_pshot)),
        'pose', v_poses[i], 'outfit', v_outfits[1 + ((i - 1) % 3)])))
     where id = v_id;
    n := n + 1;
  end loop;
  if n = 0 then return app.marketing_set_pre3030(p_by, p - 'lifestyle'); end if;
  perform app.marketing_next(v_vehicle);
  return jsonb_build_object('set', v_set, 'queued', n, 'scene', v_scene, 'studio', true, 'lifestyle', v_life);
end $$;

alter function app.marketing_photos(uuid, jsonb) rename to marketing_photos_pre3030;
create function app.marketing_photos(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare x jsonb := app.marketing_photos_pre3030(p_by, p);
begin
  return x || jsonb_build_object('photos', coalesce((select jsonb_agg(e || jsonb_build_object('lifestyle', m.lifestyle, 'ai_generated', coalesce(m.ai_generated, false)) order by k)
                                    from jsonb_array_elements(coalesce(x -> 'photos', '[]'::jsonb)) with ordinality t(e, k)
                                    left join vehicle_marketing_photos m on m.id = (e ->> 'id')::uuid), '[]'::jsonb),
    'studio', nullif(p ->> 'vehicle', '') is not null and (app.photo_r48_cover((p ->> 'vehicle')::uuid)).id is not null);
end $$;

-- ================================================================ 9. the doors
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre3030;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call = 'ops_read' and p_name = 'photo_r48_set') or (p_call = 'ops_do' and p_name in ('photo_r48_angle', 'photo_r48_scene')) then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'photo_r48_set' then app.photo_r48_set(p_user, coalesce(p, '{}'::jsonb))
                       when 'photo_r48_angle' then app.photo_r48_angle(p_user, coalesce(p, '{}'::jsonb))
                       else app.photo_r48_set_scene(p_user, coalesce(p, '{}'::jsonb)) end;
  end if;
  if p_call = 'ops_read' and p_name = 'photo_r48_plates' then
    perform app.door_begin(p_user, p_aal);
    return app.photo_r48_plates(p_user, jsonb_build_object('scene', p ->> 'scene'));
  end if;
  return app.door_pre3030(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre3030(uuid, text, text, text, jsonb)'::regprocedure);

select pg_temp.copy_grants('app.photo_r48_cars()'::regprocedure, 'app.photo_r48_cars_pre3030()'::regprocedure);
select pg_temp.copy_grants('app.job_photo_r48()'::regprocedure, 'app.job_photo_r48_pre3030()'::regprocedure);
select pg_temp.copy_grants('app.photo_r48_plates(uuid, jsonb)'::regprocedure, 'app.photo_r48_plates_pre3030(uuid, jsonb)'::regprocedure);
select pg_temp.copy_grants('app.photo_standard_car(uuid)'::regprocedure, 'app.photo_standard_car_pre3030(uuid)'::regprocedure);
select pg_temp.copy_grants('app.photo_standard_read(uuid, jsonb)'::regprocedure, 'app.photo_standard_read_pre3030(uuid, jsonb)'::regprocedure);
select pg_temp.copy_grants('app.marketing_set(uuid, jsonb)'::regprocedure, 'app.marketing_set_pre3030(uuid, jsonb)'::regprocedure);
select pg_temp.copy_grants('app.marketing_photos(uuid, jsonb)'::regprocedure, 'app.marketing_photos_pre3030(uuid, jsonb)'::regprocedure);

-- ================================================================ privileges
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['photo_r48_scene', 'photo_r48_scene_code', 'photo_r48_due', 'photo_r48_cover', 'photo_r48_set', 'photo_r48_angle',
              'photo_r48_set_scene', 'marketing_next', 'photo_r48_cars_pre3030', 'job_photo_r48_pre3030', 'photo_r48_plates_pre3030',
              'worker_listing_result_pre3030', 'public_listing_photos_pre3030', 'public_listing_row_live_pre3030', 'public_listing_row_pre3030',
              'photo_r45_fleet_read_pre3030', 'photo_standard_car_pre3030', 'photo_standard_read_pre3030',
              'marketing_set_pre3030', 'marketing_photos_pre3030', 'door_pre3030'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
