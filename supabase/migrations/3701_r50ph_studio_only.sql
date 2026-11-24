-- 3701 (release 50, photos): one look, enforced. The owner (Nov 24): "Some of the backgrounds for the photos aren't
-- consistent... makes us look like AI slop. And you still aren't doing the consistent angles using AI."
--   1. Standard r48.3 (web/src/features/listing/r48.ts R48_SPEC): every outside view of every car stands in the scene's ONE
--      background plate (family 'side', the camera square to the back wall), and every render passes the studio gate
--      (web/src/features/listing/studio-gate.ts): the car cropped onto its view's exact target (size, centre, floor line),
--      then measured against the plate (wall, floor, contact shadow) and checked for the view and direction. The worker
--      records the gate's verdict in output.r45.gate; it is kept on the photo (vehicle_photos.r45 -> 'gate'). A render the
--      gate refuses is made again with the reasons (2840: three tries), then flagged for an Admin with them.
--   2. The public pages show only studio renders that passed the gate at the current standard (app.photo_render_live):
--      the car page, search cards, landing and SEO pages, partner feeds and the channel API, the sitemap's image tags and
--      the Open Graph image all read app.public_listing_photos / app.public_listing_row. No raw owner photo, no drawn
--      sample, no other car's photo is ever public. A car with no passed render (and every example car) shows one neutral
--      "Photos coming soon" photo: the scene's empty plate (or /studio/coming-soon.jpg until a plate is made), marked
--      placeholder (and sample, so feeds and the sitemap leave it out).
--   3. Every render made before r48.3 is put through the studio gate as it is (one check, no new render; job photo_r45 with
--      input r45.regate): kept when it passes, made again only when it fails. Until its check is in it stays on the site,
--      so the site never turns to "Photos coming soon" while the fleet is checked. The queue goes by demand: the trending
--      cars first, the bookable ones first among cars as viewed (app.photo_r48_cars), and the backlog runs faster (a larger queue, a few small batches
--      a Worker run), always within Gemini's daily limit less the reserve.
--   4. Admin and Fleet: the studio grid (ops_read photo_r48_grid): every published car's nine views side by side with the
--      gate's verdict, so drift is obvious.
-- Tests: supabase/tests/99_r50ph_studio_only.sql; web studio-gate.test.ts, r48.test.ts. SCHEMA_MARKER 3701.
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
  if position(p_old in d) = 0 then raise exception '3701: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the standard: r48.3, one plate for every outside view
create or replace function app.photo_r48_spec() returns text language sql immutable parallel safe as $$ select 'r48.3'::text $$;
comment on function app.photo_r48_spec() is 'The r48 photo standard (2900; r48.3 since 3701), equal to R48_SPEC in web/src/features/listing/r48.ts.';
create or replace function app.photo_r48_family(p_shot text) returns text language sql immutable parallel safe as $$
  select case when p_shot in ('front_left', 'front', 'left', 'rear_left', 'rear') then 'side' end
$$;
comment on function app.photo_r48_family(text) is 'The background plate of a view (3701): the one ''side'' plate of the scene for every outside view, so every view of every car stands in the same room; none inside.';

-- a render on the site: made at the current standard, passed the check and the studio gate, approved and public
create function app.photo_render_live(ph vehicle_photos) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select ph.r48 and ph.replaced_at is null and ph.status = 'approved' and ph.is_public and nullif(ph.processed_path, '') is not null
     and ph.processed_path !~ '^/' and coalesce(ph.r45 ->> 'state', '') <> 'flagged'
     and ((coalesce((ph.r45 #>> '{gate,pass}')::boolean, false) and ph.r45 #>> '{gate,spec}' = app.photo_r48_spec())
          -- a render made before r48.3 stays on the site until its check in place (section 3) gives the verdict
          or (ph.r45 ? 'regate' and ph.r45 -> 'gate' is null and coalesce(ph.r45 ->> 'state', '') in ('done', 'queued')))
     and ph.shot_type = any (app.photo_render_order())
$$;
comment on function app.photo_render_live(vehicle_photos) is 'Release 50 (3701): a studio render the public may see: made to the current standard, passed the check and the studio gate (r45.gate), approved, on the site; or made before r48.3 and still waiting for its check in place (r45.regate).';

-- the worker's verdict of the gate kept on the photo (2840 keeps only some keys of output.r45)
alter function app.worker_listing_result(uuid, jsonb) rename to worker_listing_result_pre3701;
create function app.worker_listing_result(p_job uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare j listing_jobs; r jsonb; g jsonb := p #> '{output,r45,gate}';
begin
  select * into j from listing_jobs where id = p_job;
  r := app.worker_listing_result_pre3701(p_job, p);
  -- a render checked in place (section 3) and refused: off the site and made again from the start (its tries start over;
  -- the step 2840 queues again with the reasons would only check the same image again, so it is dropped); a check that
  -- only waits (Gemini's limit, a retry) keeps it on the site
  if j.kind = 'photo_r45' and coalesce(j.input #>> '{r45,regate}', '') = 'true' and jsonb_typeof(p #> '{output,r45}') = 'object'
     and not coalesce((p #>> '{output,r45,pass}')::boolean, false) and coalesce(p #>> '{output,r45,wait}', p #>> '{output,gemini_wait}') is null then
    delete from listing_jobs x where x.vehicle_photo_id = j.vehicle_photo_id and x.kind = 'photo_r45' and x.status = 'queued' and x.id <> j.id
       and coalesce(x.input #>> '{r45,regate}', '') = 'true';
    update vehicle_photos ph set r45 = (coalesce(ph.r45, '{}'::jsonb) - 'regate')
             || case when jsonb_typeof(g) = 'object' then '{}'::jsonb
                     else jsonb_build_object('gate', jsonb_build_object('pass', false, 'spec', app.photo_r48_spec(),
                            'reasons', jsonb_build_array(left(coalesce(p #>> '{output,r45,why}', 'refused'), 200)), 'measures', '{}'::jsonb, 'at', now())) end
             || jsonb_build_object('state', 'redo', 'tries', 0, 'at', now())
     where ph.id = j.vehicle_photo_id and ph.r48;
  end if;
  if j.kind = 'photo_r45' and jsonb_typeof(g) = 'object' then
    update vehicle_photos ph set r45 = coalesce(ph.r45, '{}'::jsonb) || jsonb_build_object('gate', jsonb_build_object(
             'pass', coalesce((g ->> 'pass')::boolean, false), 'spec', left(g ->> 'spec', 20),
             'reasons', case when jsonb_typeof(g -> 'reasons') = 'array' then g -> 'reasons' else '[]'::jsonb end,
             'measures', case when jsonb_typeof(g -> 'measures') = 'object' then g -> 'measures' else '{}'::jsonb end, 'at', now()))
     where ph.id = j.vehicle_photo_id and ph.r48;
    begin perform app.listing_cache_refresh(array[j.vehicle_id]); exception when others then null; end;
  end if;
  return r;
end $$;
select pg_temp.copy_grants('app.worker_listing_result(uuid, jsonb)'::regprocedure, 'app.worker_listing_result_pre3701(uuid, jsonb)'::regprocedure);
revoke all on function app.worker_listing_result_pre3701(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.worker_listing_result_pre3701(uuid, jsonb) to service_role;

-- the studio cover (the home hero's turns, the connector, the Admin): the first live render in the site's order
create or replace function app.photo_r48_cover(p_vehicle uuid) returns vehicle_photos
language sql stable security definer set search_path = public, app, pg_temp as $$
  select ph.* from vehicle_photos ph
   where ph.vehicle_id = p_vehicle and app.photo_render_live(ph)
   order by array_position(app.photo_render_order(), ph.shot_type), ph.created_at desc limit 1
$$;

-- ================================================================ 2. the public photos: live renders only, else one placeholder
create function app.photo_placeholder(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('path', coalesce((select p.path from listing_r48_plates p
                                               where p.family = 'side' and p.scene = coalesce(app.photo_r48_scene_code(p_vehicle), 'showroom_dark') limit 1),
                                             '/studio/coming-soon.jpg'),
           'variants', '[]'::jsonb, 'width', 1800, 'height', 1200, 'shot', 'placeholder', 'label', 'Photos coming soon',
           'alt', coalesce(app.vehicle_name(p_vehicle), 'Car') || ': photos coming soon', 'is_cover', true, 'sample', true, 'placeholder', true)
$$;
comment on function app.photo_placeholder(uuid) is 'Release 50 (3701): the one photo of a car with no passed studio render: the scene''s empty plate, "Photos coming soon" (marked placeholder and sample: feeds and the sitemap leave it out).';

alter function app.public_listing_photos(uuid) rename to public_listing_photos_pre3701;
create function app.public_listing_photos(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  with r as (
    select distinct on (x.shot_type) x.* from vehicle_photos x
     where x.vehicle_id = p_vehicle and app.photo_render_live(x)
       and not coalesce((select v.is_sample from vehicles v where v.id = p_vehicle), true)
     order by x.shot_type, x.created_at desc
  ), g as (
    select jsonb_build_object('path', r.processed_path, 'variants', coalesce(r.variants, '[]'::jsonb),
             'alt', app.vehicle_name(p_vehicle) || ', ' || lower(coalesce(st.label, r.shot_type)),
             'width', coalesce(r.width, 1800), 'height', coalesce(r.height, 1200), 'shot', r.shot_type, 'label', coalesce(st.label, r.shot_type),
             'generated', true) j,
           array_position(app.photo_render_order(), r.shot_type) k
      from r left join listing_shot_types st on st.code = r.shot_type
  )
  select case
    -- no outside render passed yet: the placeholder alone, never a mixed set
    when not exists (select 1 from g where app.photo_is_exterior(g.j ->> 'shot')) then jsonb_build_array(app.photo_placeholder(p_vehicle))
    else (select jsonb_agg(g.j || jsonb_build_object('is_cover', g.k = (select min(k) from g)) order by g.k) from g) end
$$;
select pg_temp.copy_grants('app.public_listing_photos(uuid)'::regprocedure, 'app.public_listing_photos_pre3701(uuid)'::regprocedure);
revoke all on function app.public_listing_photos_pre3701(uuid) from public, anon, authenticated;
grant execute on function app.public_listing_photos_pre3701(uuid) to service_role;

-- the listing row (cache, search, cards, feeds, OG): its cover is the gallery's first photo, always
create function app.photo_row_cover(p_vehicle uuid, r jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare g jsonb; c jsonb; v_place boolean;
begin
  if r is null then return null; end if;
  g := app.public_listing_photos(p_vehicle);
  c := g -> 0;
  v_place := coalesce((c ->> 'placeholder')::boolean, false);
  return r || jsonb_build_object(
    'cover', jsonb_build_object('path', c ->> 'path', 'variants', coalesce(c -> 'variants', '[]'::jsonb), 'alt', c ->> 'alt', 'shot', c ->> 'shot', 'width', (c ->> 'width')::integer, 'height', (c ->> 'height')::integer,
               'generated', not v_place, 'placeholder', v_place, 'sample', v_place,
               -- the drive-off cutout only when it was cut from this very render (never from an owner's photo)
               'cutout', (select app.photo_side_cutout(p_vehicle) from site_cutouts k
                           where not v_place and k.vehicle_id = p_vehicle and k.shot = 'left' and k.source_path = c ->> 'path' limit 1)),
    'sample_photos', v_place, 'placeholder', v_place,
    'rendered', case when v_place then 0 else jsonb_array_length(g) end);
end $$;
comment on function app.photo_row_cover(uuid, jsonb) is 'Release 50 (3701): the listing row''s cover is the gallery''s first photo (a passed studio render, else the placeholder).';

alter function app.public_listing_row_live(uuid) rename to public_listing_row_live_pre3701;
create function app.public_listing_row_live(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select app.photo_row_cover(p_vehicle, app.public_listing_row_live_pre3701(p_vehicle))
$$;
select pg_temp.copy_grants('app.public_listing_row_live(uuid)'::regprocedure, 'app.public_listing_row_live_pre3701(uuid)'::regprocedure);

alter function app.public_listing_row(uuid) rename to public_listing_row_pre3701;
create function app.public_listing_row(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select app.photo_row_cover(p_vehicle, app.public_listing_row_pre3701(p_vehicle))
$$;
select pg_temp.copy_grants('app.public_listing_row(uuid)'::regprocedure, 'app.public_listing_row_pre3701(uuid)'::regprocedure);

-- the channel API (2304) leaves the placeholder out, as the feeds (0216) and the sitemap (3030) do
select pg_temp.patch_fn('app.channel_vehicle_json(uuid, text)'::regprocedure,
  $q$where coalesce(e ->> 'path', '') <> '' and k <= 12$q$,
  $q$where coalesce(e ->> 'path', '') <> '' and not coalesce((e ->> 'sample')::boolean, false) and k <= 12$q$);

-- ================================================================ 2b. every other surface: the hero, the sections, the card cutouts, emails
-- Why the hero and the home sections never showed the renders: they used app.site_cutouts (3080), cut by rembg from the
-- first photo app.site_cutout_source found: a render when there was one (there never was), else an owner's photo, a check-in
-- photo or the stock photo of the model, then stood on a drawn plate. The web now shows the gated renders themselves there
-- (components/SlotCars.tsx, from app.site_studio_covers = app.photo_r48_cover, live renders only); the cutouts (still used by
-- the cards' drive-off) are made only from a live render, and only those are public.
create or replace function app.site_cutout_source(p_vehicle uuid, p_shot text default 'left') returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('kind', 'studio', 'bucket', 'vehicle-public', 'path', ph.processed_path, 'facing', app.site_cutout_facing(ph.shot_type))
    from vehicle_photos ph
   where ph.vehicle_id = p_vehicle and ph.shot_type = p_shot and app.photo_render_live(ph)
   order by ph.created_at desc limit 1
$$;
create or replace function app.site_cutouts(p_shot text default 'left', p_limit integer default 12) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(jsonb_agg(x.j order by x.o), '[]'::jsonb) from (
    select jsonb_build_object('vehicle_id', k.vehicle_id, 'path', k.path, 'width', k.width, 'height', k.height, 'facing', k.facing,
             'kind', k.source_kind, 'alt', app.vehicle_name(k.vehicle_id)) j, c.o
      from app.site_cutout_cars() c join site_cutouts k on k.vehicle_id = c.vehicle_id and k.shot = p_shot
     where k.path is not null
       and exists (select 1 from vehicle_photos ph where ph.vehicle_id = k.vehicle_id and ph.processed_path = k.source_path and app.photo_render_live(ph))
     order by c.o limit least(greatest(coalesce(p_limit, 12), 1), 24)) x
$$;

-- the car picture of every email (vehicle_image_url): the car's first live render, else none (the template shows the
-- car's name panel); never an owner's own photo
select pg_temp.patch_fn('app.ntf_vehicle_pre0827(uuid)'::regprocedure,
  $q$where ph.vehicle_id = v.id and ph.is_public and ph.status = 'approved' and ph.replaced_at is null$q$,
  $q$where ph.vehicle_id = v.id and app.photo_render_live(ph) and app.photo_r48_family(ph.shot_type) = 'side'$q$);
select pg_temp.patch_fn('app.ntf_vehicle_pre0827(uuid)'::regprocedure,
  $q$order by ph.is_cover desc, ph.sort_order limit 1$q$,
  $q$order by array_position(app.photo_render_order(), ph.shot_type), ph.created_at desc limit 1$q$);

-- ================================================================ 3. every render made before r48.3 is checked in place
-- made renders: kept on the site and put through the studio gate as they are (made again only when refused); flagged
-- ones (never on the site) are made again
update vehicle_photos set r45 = coalesce(r45, '{}'::jsonb) - 'gate' || jsonb_build_object('regate', now())
 where r48 and replaced_at is null and coalesce(r45 ->> 'state', '') = 'done'
   and coalesce(r45 #>> '{gate,spec}', '') <> app.photo_r48_spec();
update vehicle_photos set r45 = coalesce(r45, '{}'::jsonb) - 'reasons' - 'why' || jsonb_build_object('state', 'redo', 'tries', 0, 'at', now())
 where r48 and replaced_at is null and coalesce(r45 ->> 'state', '') = 'flagged'
   and coalesce(r45 #>> '{gate,spec}', '') <> app.photo_r48_spec();

-- the queue by demand: the trending cars (3030), and among cars as viewed the bookable ones (published and available) first
select pg_temp.patch_fn('app.photo_r48_cars()'::regprocedure,
  $q$order by coalesce((select t.score from app.fleet_trend t where t.vehicle_id = v.id), 0) desc,$q$,
  $q$order by coalesce((select t.score from app.fleet_trend t where t.vehicle_id = v.id), 0) desc,
            (v.status = 'available' and exists (select 1 from vehicle_listings l where l.vehicle_id = v.id and l.status = 'published')) desc,$q$);
alter function app.photo_r48_cars() set search_path = public, app, pg_temp;

-- a check in place: the render's own step (photo_r45, input r45.regate), in the order of photo_r48_cars and the site's views
create function app.photo_r48_regate_queue(p_limit integer) returns integer
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare r record; n integer := 0;
begin
  if coalesce(p_limit, 0) <= 0 then return 0; end if;
  for r in select ph.id, ph.vehicle_id, ph.shot_type from vehicle_photos ph
             join app.photo_r48_cars() with ordinality c(vehicle_id, listed_at, o) on c.vehicle_id = ph.vehicle_id
            where ph.r48 and ph.replaced_at is null and ph.r45 ? 'regate' and ph.r45 -> 'gate' is null and ph.r45 ->> 'state' = 'done'
              and not exists (select 1 from listing_jobs j where j.vehicle_photo_id = ph.id and j.kind = 'photo_r45' and j.status in ('queued', 'running'))
            order by c.o, array_position(app.photo_render_order(), ph.shot_type)
            limit p_limit loop
    update vehicle_photos set r45 = r45 || jsonb_build_object('state', 'queued', 'at', now()) where id = r.id;
    perform app.enqueue_listing_job(app.photo_r48_intake(r.vehicle_id), 'photo_r45', r.id,
      jsonb_build_object('r45', jsonb_build_object('mode', 'r48', 'regate', true, 'car', app.photo_r45_car(r.vehicle_id), 'shot', r.shot_type), 'by', null));
    n := n + 1;
  end loop;
  return n;
end $$;
comment on function app.photo_r48_regate_queue(integer) is 'Release 50 (3701): queues up to p_limit checks in place of renders made before r48.3 (kept when the studio gate passes them, made again when it refuses), bookable and trending cars first.';

-- the job: the checks in place first (one Gemini check each, no image made), within the same room as the renders
alter function app.job_photo_r48() rename to job_photo_r48_pre3701;
create function app.job_photo_r48() returns text
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare ps program_settings := app.settings(); v_room integer; v_due integer := app.photo_r48_due(); n integer := 0;
begin
  if coalesce(ps.listing_photo_r48_auto, true) and coalesce(ps.listing_showroom_ai, false) then
    v_room := least(greatest(coalesce(ps.listing_photo_r45_batch, 12) - v_due, 0),
                    greatest(app.photo_gemini_left(coalesce(ps.listing_photo_r45_reserve, 50)) - v_due, 0));
    n := app.photo_r48_regate_queue(v_room);
  end if;
  return app.job_photo_r48_pre3701() || case when n > 0 then format('; %s render(s) checked in place', n) else '' end;
end $$;
select pg_temp.copy_grants('app.job_photo_r48()'::regprocedure, 'app.job_photo_r48_pre3701()'::regprocedure);

-- the backlog runs faster: a larger queue (still within Gemini's daily limit less the reserve, app.photo_gemini_left)
update program_settings set listing_photo_r45_batch = 24 where listing_photo_r45_batch < 24;

-- ================================================================ 4. the studio grid (Admin and Fleet)
create function app.photo_r48_grid(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare v_limit integer := least(greatest(coalesce(nullif(p ->> 'limit', '')::integer, 40), 1), 200);
        v_offset integer := greatest(coalesce(nullif(p ->> 'offset', '')::integer, 0), 0);
begin
  if not app.photo_r45_may(p_by) then raise exception 'An Admin or fleet sees the studio grid' using errcode = '42501'; end if;
  return jsonb_build_object('spec', app.photo_r48_spec(), 'order', to_jsonb(app.photo_render_order()),
    'total', (select count(*) from vehicles v join vehicle_listings l on l.vehicle_id = v.id and l.status = 'published'
               where not coalesce(v.is_sample, false) and v.retired_at is null),
    'cars', coalesce((select jsonb_agg(c.j order by c.o) from (
      select row_number() over (order by v.fleet_number nulls last, v.id) o,
             jsonb_build_object('vehicle', v.id, 'name', app.vehicle_name(v.id), 'fleet_number', v.fleet_number,
               'live', (select count(*) from vehicle_photos x where x.vehicle_id = v.id and app.photo_render_live(x)),
               'views', (select jsonb_agg(jsonb_build_object('shot', a,
                   'path', g.processed_path, 'live', coalesce(app.photo_render_live(g), false), 'state', g.r45 ->> 'state', 'tries', g.r45 -> 'tries',
                   'gate', g.r45 -> 'gate', 'why', g.r45 ->> 'why', 'reasons', g.r45 -> 'reasons') order by k)
                 from unnest(app.photo_render_order()) with ordinality u(a, k)
                 left join lateral (select x.* from vehicle_photos x where x.vehicle_id = v.id and x.r48 and x.shot_type = u.a and x.replaced_at is null
                                     order by x.created_at desc limit 1) g on true)) j
        from vehicles v join vehicle_listings l on l.vehicle_id = v.id and l.status = 'published'
       where not coalesce(v.is_sample, false) and v.retired_at is null
       order by v.fleet_number nulls last, v.id limit v_limit offset v_offset) c), '[]'::jsonb));
end $$;
comment on function app.photo_r48_grid(uuid, jsonb) is 'Release 50 (3701): every published car''s nine studio views side by side with the gate''s verdict (Admin and Fleet: Photo standard, Studio grid).';

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre3701;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if p_call = 'ops_read' and p_name = 'photo_r48_grid' then
    perform app.door_begin(p_user, p_aal);
    return app.photo_r48_grid(p_user, coalesce(p, '{}'::jsonb));
  end if;
  return app.door_pre3701(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre3701(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['photo_render_live', 'photo_placeholder', 'photo_row_cover', 'photo_r48_grid', 'door_pre3701', 'photo_r48_regate_queue', 'job_photo_r48_pre3701'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- the listing cache holds the studio-only galleries and covers now
do $$
begin
  perform app.listing_cache_refresh(array(select l.vehicle_id from vehicle_listings l where l.status in ('published', 'paused')));
  -- the landing, area and class pages keep a snapshot of their cars (0068): taken again now, with the new covers
  perform app.seo_snapshot_refresh();
exception when undefined_function then null;
end $$;
